#!/bin/bash
# verify-before-stop.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers the mandatory QA gate
# Stop hook: allow when no changes / when QA approved, block when changes
# require review, block on cross-repo mismatch, allow user_interrupt /
# max_turns / stop_hook_active.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent (CI runner, BD_SHIM_ONLY=1).
# The "QA-approved -> allow" and cross-repo guard scenarios both require
# seeding bd state (qa-approved label, current-task repo fingerprint); we
# skip the whole spec rather than expose partial coverage in CI.
bd_required_or_skip

VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
QG="$FIXTURE/.claude/scripts/qa-gate.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# 1. No changed files, no task -> {} (allow).
OUT=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS")
assert_empty_envelope "vbs: no changes allowed" "$OUT"

# 2. stop_hook_active=true -> {} (circuit breaker, AgentLint H3).
printf '/path/changed.ts\n' > "$TRACK/changed-files.txt"
OUT=$(printf '%s' '{"stop_reason":"end_turn","stop_hook_active":true}' | bash "$VBS")
assert_empty_envelope "vbs: stop_hook_active=true bypasses" "$OUT"

# 3. user_interrupt -> {} (don't block).
OUT=$(printf '%s' '{"stop_reason":"user_interrupt"}' | bash "$VBS")
assert_empty_envelope "vbs: user_interrupt allowed" "$OUT"

# 4. max_turns -> {} (don't block).
OUT=$(printf '%s' '{"stop_reason":"max_turns"}' | bash "$VBS")
assert_empty_envelope "vbs: max_turns allowed" "$OUT"

# 5. Changed files + no task -> block with the "no active task" hint.
printf '/path/changed.ts\n' > "$TRACK/changed-files.txt"
bash "$CT" clear
OUT=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS")
assert_decision "vbs: changes + no task -> block" "$OUT" "block"
REASON=$(printf '%s' "$OUT" | jq -r '.reason // empty')
assert_match "vbs: reason mentions no active task" \
    "No active Beads task detected" "$REASON"

# 5a. claude-workflow-plugin-366.9: the EMITTED Task("@qa", ...)
# delegation block must carry the impact_of cue so QA's task prompt
# surfaces it at the top of its working memory. Pre-366.9 (Phase B
# run 3) the template enumerated tests/journeys/failure-modes only and
# QA never reached for impact_of even though all 7 code-graph tools
# were structurally available — fixed by inserting an unconditional
# FIRST checklist item naming impact_of and code-graph. Assert against
# the live emission, not against the source, so a future refactor that
# accidentally bypasses the rendering path (e.g. by templating the
# checklist elsewhere) is still caught.
assert_contains "vbs: QA-required block emits impact_of cue (366.9)" \
    "impact_of" "$REASON"
assert_contains "vbs: QA-required block names code-graph MCP (366.9)" \
    "code-graph" "$REASON"

# 6. Changed files + task qa-approved -> {} (allow). Need bd-real task.
TID=$(cd "$FIXTURE" && bd create "Approved-path task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID" >/dev/null
bash "$QG" approve "$TID" "Component-spec auto-approve" >/dev/null
# qa-gate approve clears current-task; the gate path requires CURRENT_TASK
# to be set for the QA-approved short-circuit. Re-set it.
bash "$CT" set "$TID"
# Re-seed changed-files (approve wipes the legacy tracking too).
printf '/path/changed.ts\n' > "$TRACK/changed-files.txt"
# Run vbs and discard stderr (bd update prints "✓ Updated issue ..." on
# stdout/stderr during the post-approval bd update --status closed call;
# we only care about the FINAL JSON envelope).
RAW=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1)
# The envelope is the LAST JSON-shaped line. Find it.
OUT=$(printf '%s' "$RAW" | tail -1)
COMPACT=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null || echo "NOT_JSON")
# Accept either `{}` or a hookSpecificOutput envelope. As long as there's
# no `decision: block`, we're allowing.
if [ "$COMPACT" = "{}" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "vbs: changes + qa-approved -> allow (clean)"
else
    HAS_DECISION=$(printf '%s' "$COMPACT" | jq -r 'has("decision")' 2>/dev/null || echo "true")
    if [ "$HAS_DECISION" = "false" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "vbs: changes + qa-approved -> allow (note-shaped)"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("vbs: qa-approved unexpectedly blocked")
        printf '  FAIL: vbs: qa-approved unexpectedly blocked: %s\n' "$COMPACT"
    fi
fi

# 7. Cross-repo (I8): different recorded repo than cwd -> block with the
# 3-option recovery prose. Spoof by writing a fake current-task.repo file
# pointing somewhere clearly different from $FIXTURE.
TID2=$(cd "$FIXTURE" && bd create "Cross-repo task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$CT" set "$TID2"
# Initialize the fixture as a git repo so detect_cross_repo has a current
# toplevel to compare against. Without this, get_current_repo_root returns
# empty and the comparison is silently skipped (the gate degrades to
# legacy single-repo behaviour).
(cd "$FIXTURE" && git init -q 2>/dev/null) || true
# Spoof a recorded repo that differs from the cwd's actual toplevel.
printf '/some/other/repo\n' > "$TRACK/current-task.repo"
printf '/path/cross-repo-file.ts\n' > "$TRACK/changed-files.txt"
OUT=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS")
assert_decision "vbs: cross-repo blocks" "$OUT" "block"
REASON=$(printf '%s' "$OUT" | jq -r '.reason // empty')
assert_contains "vbs: cross-repo reason mentions cross-repo" "Cross-repo" "$REASON"
assert_match "vbs: cross-repo lists 3 numbered recovery options" \
    "^[[:space:]]+1\\." "$REASON"
assert_match "vbs: cross-repo option 2" "^[[:space:]]+2\\." "$REASON"
assert_match "vbs: cross-repo option 3" "^[[:space:]]+3\\." "$REASON"

# 8. F1 doc-only fast path: changed file is a markdown doc -> auto-approve
# (no block). We use a fresh task to avoid label state from above.
# First clear cross-repo spoof.
rm -f "$TRACK/current-task.repo"
bash "$CT" clear
TID_DOC=$(cd "$FIXTURE" && bd create "Doc-only fast path task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID_DOC" >/dev/null
# After enter, current-task is set. Now provide ONLY doc-paths in the
# changed list.
printf 'README.md\ndocs/architecture.md\n' > "$TRACK/changed-files.txt"
# Capture stdout+stderr (bd update output bleeds into stdout); the JSON
# envelope is on the last line.
RAW=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1)
OUT=$(printf '%s' "$RAW" | tail -1)
# Doc-only path returns {} after auto-approving via qa-gate.
assert_empty_envelope "vbs: F1 doc-only auto-approve" "$OUT"

# 9. Test/lint failure: shim a test command that exits 1. We achieve this
# by replacing detect-stack.sh (a symlink) with a stub that emits a
# test_cmd we know will fail. Approach: write a stack stub at the same
# path, ensuring it overrides the symlink.
rm -f "$FIXTURE/.claude/scripts/detect-stack.sh"
cat > "$FIXTURE/.claude/scripts/detect-stack.sh" <<'STUB'
#!/bin/bash
# Test-time stack detector: report `npm test` as the test command, which
# we'll shim to exit 1, and no lint/type so the path stays fast.
printf '{"runner":"npm","test_cmd":"npm test","lint_cmd":"","type_cmd":""}\n'
STUB
chmod +x "$FIXTURE/.claude/scripts/detect-stack.sh"

# Shim npm to exit 1 on `npm test`.
mk_shim "npm" "$FIXTURE" 1 "npm test failed: 1 test failing" >/dev/null

# Re-seed: clear approved state, set up a fresh task with code changes.
bash "$CT" clear
TID_FAIL=$(cd "$FIXTURE" && bd create "Test fail path task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID_FAIL" >/dev/null
# Use a NON-doc-only path so we exercise the test pass.
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"
OUT=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS")
assert_decision "vbs: failing tests -> block" "$OUT" "block"
REASON=$(printf '%s' "$OUT" | jq -r '.reason // empty')
assert_contains "vbs: block reason mentions test output" \
    "Tests failing" "$REASON"
assert_match "vbs: reason mentions runner=npm" "runner: npm" "$REASON"

# 10. Mutation-test kill (C.3 survivor id 12, line 657): a non-escalated
# Stop with a failing TEST_CMD MUST genuinely run the suite, NOT take the
# cache-replay branch. The mutant `if [ "$QA_ESCALATED" != "true" ]; then`
# inverted the escalated-state check so every non-escalated Stop replayed
# the (empty) cache, leaving the runner at "none" and FAILED_CHECKS empty
# — the gate then degraded to the "QA approval required ... technical
# checks passed" path. Verdict: .claude/.mutation-runs/20260612T063107Z/verdict.json id=12.
#
# Evidence the suite GENUINELY ran (vs cache-replay):
#   (a) last-test-rc.<TID> exists and is non-empty (suite ran -> rc persisted).
#   (b) last-test-output.log exists and is non-empty (capture from runner).
#   (c) last-runner.<TID> contains "npm" (not "none" from the replay default).
#   (d) FAILED_CHECKS rendering carries "Tests failing" + "runner: npm".
#   (e) Block reason MUST NOT carry "QA approval required" / "technical
#       checks passed" — those are the symptoms of the cache-replay branch
#       being taken on a non-escalated task.
#
# These assertions are redundant with #9's existing kill on the wording,
# but they document the invariant ("suite genuinely runs when not
# escalated") so future refactors that bypass detect-stack via a
# different control-flow path are still caught.
#
# Reuse TID_FAIL state from #9 (npm shim still exits 1; tracking-files
# from #9 already written by the original run). Re-derive expectations
# from the on-disk tracking artifacts.
SAN_FAIL=$(printf '%s' "$TID_FAIL" | tr -c 'A-Za-z0-9._-' '_')
LAST_RC_FILE="$TRACK/last-test-rc.$SAN_FAIL"
LAST_RUN_FILE="$TRACK/last-runner.$SAN_FAIL"
LAST_LOG_FILE="$TRACK/last-test-output.log"

assert_eq "vbs: suite ran -> last-test-rc.<TID> exists (mut 12 kill)" \
    "yes" "$([ -s "$LAST_RC_FILE" ] && echo yes || echo no)"
LAST_RC=$(cat "$LAST_RC_FILE" 2>/dev/null || echo "")
# Sanity: shim exits 1, so rc must be non-zero and not empty.
assert_eq "vbs: suite ran -> last-test-rc carries shim exit=1" \
    "1" "$LAST_RC"
assert_eq "vbs: suite ran -> last-test-output.log exists" \
    "yes" "$([ -s "$LAST_LOG_FILE" ] && echo yes || echo no)"
assert_eq "vbs: suite ran -> last-runner.<TID> exists" \
    "yes" "$([ -s "$LAST_RUN_FILE" ] && echo yes || echo no)"
LAST_RUN=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")
assert_eq "vbs: suite ran -> last-runner is 'npm' (NOT 'none' from replay)" \
    "npm" "$LAST_RUN"

# Negative-shape assertions on the block reason: under the mutant the
# control-flow falls into the QA-required path. These two strings ONLY
# appear there.
NOT_QA_REQ=$(printf '%s' "$REASON" | grep -c 'QA approval required' || true)
NOT_QA_REQ=$(printf '%s' "$NOT_QA_REQ" | tr -d '[:space:]')
assert_eq "vbs: failing tests block reason MUST NOT say 'QA approval required'" \
    "0" "$NOT_QA_REQ"
NOT_TECH_OK=$(printf '%s' "$REASON" | grep -c 'technical checks passed' || true)
NOT_TECH_OK=$(printf '%s' "$NOT_TECH_OK" | tr -d '[:space:]')
assert_eq "vbs: failing tests block reason MUST NOT say 'technical checks passed'" \
    "0" "$NOT_TECH_OK"

# 10a. Direct proof: the npm shim was invoked at least once during this
# Stop. The shim records each invocation to bin/npm.log; a present log
# with at least one line means detect-stack -> run_with_timeout actually
# fired the configured TEST_CMD. Cache-replay never reaches this code.
NPM_LOG_F="$FIXTURE/bin/npm.log"
assert_eq "vbs: npm shim invoked (suite ran, NOT replayed)" \
    "yes" "$([ -s "$NPM_LOG_F" ] && echo yes || echo no)"

# ===========================================================================
# claude-workflow-plugin-llh.3 (G2.gate-friction) — false-block repros.
#
# Production evidence (build sessions 2026-06-12): the Stop hook blocked
# with "0 file(s) changed - all require QA review" + empty Files list while
# the J18 diff_summary showed ONLY beads-state or transient-fixture paths:
#   case 1: `.beads/issues.jsonl | 2 +-`   (a qa-gate-enter LABEL write —
#           beads state, not code)
#   case 2: `fixtures/node-react-auth/fixture.yaml | 28 ----` (transient
#           mid-live-run state the run's own restore reverted minutes later)
#   case 3: `fixtures/node-react-auth/.beads/issues.jsonl | 13 ----`
#
# Root cause (changed_files-vs-diff_summary divergence): the gate-fires flag
# CODE_CHANGES_DETECTED is set by the git-status fallback, which keeps any
# path passing is_tracked_change — and the denylist does NOT exclude
# beads-state files (.beads/*.jsonl, beads.db) or gate-bookkeeping
# (.qa-tracking/*). Meanwhile CHANGE_COUNT / Files-changed read from the
# (empty) changed-files.txt and diff_summary reads RAW git diff. Three
# disagreeing sources => the self-contradictory "0 files but still blocks"
# payload.
#
# These are written FAILING-FIRST (red before the fast-path extension): the
# pre-fix script BLOCKS on all three; the fix makes the hook ALLOW. A fresh
# task is entered for each so the auto-approve path (the F1-style branch) is
# exercised the way production case 1 hit it (gate-entered task).
#
# A fresh fixture isolates git state from the detect-stack/npm shimming the
# earlier cases left behind.
mk_fixture
FIXTURE2="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS2="$FIXTURE2/.claude/scripts/verify-before-stop.sh"
QG2="$FIXTURE2/.claude/scripts/qa-gate.sh"
CT2="$FIXTURE2/.claude/scripts/current-task.sh"
TRACK2="$FIXTURE2/.claude/.qa-tracking"

# Init the fixture as a git repo so the git-status fallback + diff_summary
# (raw git diff) both have something to read — this is the surface the bug
# lives on. Commit a baseline so subsequent edits show as modifications.
(cd "$FIXTURE2" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

# Helper: run the gate once and return the FINAL JSON envelope line. The
# post-approval `bd update --status closed` prints to stdout/stderr; the
# envelope is the last JSON-shaped line.
run_vbs2() {
    printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS2" 2>&1 | tail -1
}

# --- Repro 1: beads-only diff -------------------------------------------
# git diff shows ONLY .beads/issues.jsonl changed; changed-files.txt is
# empty (post-edit never tracks beads writes). A gate-entered task exists
# (mirrors production case 1: the dirty beads file IS the enter label-write).
# Assert: ALLOW. Pre-fix this BLOCKS (red).
TID_BEADS=$(cd "$FIXTURE2" && bd create "beads-only diff task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG2" enter "$TID_BEADS" >/dev/null
: > "$TRACK2/changed-files.txt"   # empty tracking — beads write was untracked
# Dirty ONLY the beads-state file relative to HEAD.
printf '{"id":"%s","label":"qa-gate-entered"}\n' "$TID_BEADS" > "$FIXTURE2/.beads/issues.jsonl"
OUT_BEADS=$(run_vbs2)
assert_empty_envelope "vbs-llh3: beads-only diff -> ALLOW (case 1)" "$OUT_BEADS"

# --- Repro 2: empty change-set after denylist ----------------------------
# changed-files.txt lists ONLY a denylisted path (pnpm-lock.yaml); git diff
# is otherwise clean for tracked code. Assert: ALLOW. Pre-fix this is the
# exact "0 file(s) changed - all require QA review" production payload (the
# fallback trips on the lockfile/beads churn while CHANGE_COUNT reads 0).
TID_EMPTY=$(cd "$FIXTURE2" && bd create "empty-post-denylist task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG2" enter "$TID_EMPTY" >/dev/null
printf 'pnpm-lock.yaml\n' > "$TRACK2/changed-files.txt"
# Make the lockfile actually dirty so the change-set is non-empty PRE-denylist
# but empty POST-denylist; leave no real source dirty.
printf 'lockfile-churn\n' > "$FIXTURE2/pnpm-lock.yaml"
OUT_EMPTY=$(run_vbs2)
assert_empty_envelope "vbs-llh3: empty-after-denylist change-set -> ALLOW (case 2-shape)" "$OUT_EMPTY"

# --- Repro 3: transient fixture-internal paths ---------------------------
# Paths that are dirty during a live e2e run but are harness-internal
# transient state, never code under review: an e2e fixture's nested
# .beads/issues.jsonl (case 3) and a .claude/worktrees/ path. Assert: ALLOW.
# Pre-fix this BLOCKS because neither is denylisted.
TID_TRANSIENT=$(cd "$FIXTURE2" && bd create "transient fixture paths task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG2" enter "$TID_TRANSIENT" >/dev/null
# Drive these through the TRACKING_FILE path (post-edit recorded them) so the
# repro doesn't depend on actually scaffolding a nested fixture git tree.
{
    printf '%s\n' '.claude/tests/e2e/fixtures/node-react-auth/.beads/issues.jsonl'
    printf '%s\n' '.claude/worktrees/wt-1/src/handler.ts'
} > "$TRACK2/changed-files.txt"
OUT_TRANSIENT=$(run_vbs2)
assert_empty_envelope "vbs-llh3: transient fixture-internal paths -> ALLOW (case 3)" "$OUT_TRANSIENT"

# --- Anti-overreach guard: mixed diff MUST still block -------------------
# A change-set with beads state AND one real source file is a REAL code
# change. The fast-path extension must NOT swallow it — the qa-approved-only
# release rule is untouched for any real code path. Assert: BLOCK.
TID_MIXED=$(cd "$FIXTURE2" && bd create "mixed diff task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG2" enter "$TID_MIXED" >/dev/null
bd label add "$TID_MIXED" qa-pending >/dev/null 2>&1
{
    printf '%s\n' '.beads/issues.jsonl'
    printf '%s\n' 'src/handler.ts'
} > "$TRACK2/changed-files.txt"
OUT_MIXED=$(run_vbs2)
assert_decision "vbs-llh3: mixed (beads + source) diff STILL blocks (anti-overreach)" \
    "$OUT_MIXED" "block"

# ===========================================================================
# META-TEST (anti-overreach): revert the fast-path extension in a COPY of
# verify-before-stop.sh and prove repros 1-2 go RED again, while the
# mixed-diff case keeps blocking. This proves the new ALLOW assertions are
# load-bearing on the fast-path code (not passing for some incidental
# reason) AND that the guard against over-approving a mixed diff is real.
#
# We neutralize the fast-path extension by deleting the function that
# classifies a change-set as fast-path-eligible (is_fastpath_only_change),
# forcing it to always report "not eligible" — i.e., the pre-fix behaviour.
mk_fixture
FIXTURE_MM="$COMPONENT_FIXTURE_PATH"
VBS_MM="$FIXTURE_MM/.claude/scripts/verify-before-stop.sh"
QG_MM="$FIXTURE_MM/.claude/scripts/qa-gate.sh"
TRACK_MM="$FIXTURE_MM/.claude/.qa-tracking"
(cd "$FIXTURE_MM" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

# Build the mutated copy: override is_fastpath_only_change to ALWAYS return
# 1 (never eligible) — the pre-fix world. We append the override AFTER the
# real definition so it wins (later definition shadows earlier in bash).
PLUGIN_VBS_MM=$(readlink "$VBS_MM")
rm "$VBS_MM"
# Copy the real script, then append a shadowing override of the classifier
# right before the main-flow `INPUT=$(cat)` line would have consumed stdin.
# Appending at end-of-file is too late (the function is called mid-script),
# so we insert the override immediately after the function's closing brace.
awk '
    { print }
    /^is_fastpath_only_change\(\) \{$/ { seen=1 }
    seen && /^\}$/ && !done {
        print ""
        print "# META-TEST override: neutralize the fast-path extension."
        print "is_fastpath_only_change() { return 1; }"
        done=1
    }
' "$PLUGIN_VBS_MM" > "$VBS_MM"
chmod +x "$VBS_MM"

run_vbs_mm() {
    printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS_MM" 2>&1 | tail -1
}

# META repro 1: beads-only -> now BLOCKS under the neutralized fast path.
TID_MM1=$(cd "$FIXTURE_MM" && bd create "meta beads-only" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_MM" enter "$TID_MM1" >/dev/null
bd label add "$TID_MM1" qa-pending >/dev/null 2>&1
: > "$TRACK_MM/changed-files.txt"
printf '{"id":"%s"}\n' "$TID_MM1" > "$FIXTURE_MM/.beads/issues.jsonl"
OUT_MM1=$(run_vbs_mm)
assert_decision "META vbs-llh3: beads-only goes RED (blocks) when fast path neutralized" \
    "$OUT_MM1" "block"

# META mixed-diff: still blocks (anti-overreach guard holds regardless).
TID_MM2=$(cd "$FIXTURE_MM" && bd create "meta mixed" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_MM" enter "$TID_MM2" >/dev/null
bd label add "$TID_MM2" qa-pending >/dev/null 2>&1
{
    printf '%s\n' '.beads/issues.jsonl'
    printf '%s\n' 'src/handler.ts'
} > "$TRACK_MM/changed-files.txt"
OUT_MM2=$(run_vbs_mm)
assert_decision "META vbs-llh3: mixed diff blocks regardless of fast path" \
    "$OUT_MM2" "block"

[ "$FAIL" -eq 0 ]

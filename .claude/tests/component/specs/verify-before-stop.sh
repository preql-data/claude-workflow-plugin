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
# V3 (jio.1) MIGRATION: BOTH ends of this flow now demand an independent
# review — approve refuses without the artifact, and the Stop hook re-runs the
# same predicate before releasing. Seed the real records (backend implementer
# + qa-claude review, no findings) so the release path under test is reachable.
seed_review_records "$TID"
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

# 6a. claude-workflow-plugin-llh.20: the approved-path Stop hook STDOUT must
# be a single valid-JSON envelope — NOT `✓ Updated issue: <id>\n{}`.
#
# The post-approval `bd update --status closed` prints a `✓ Updated issue: <id>`
# banner to STDOUT on success. Pre-llh.20 the call silenced only stderr
# (`2>/dev/null`), so that banner leaked onto the hook's stdout and prefixed
# the `{}` verdict. Per the Claude Code hooks contract the hook's stdout must
# be a JSON object; raw text before it means `jq` over the WHOLE stdout fails
# and Claude silently ignores the verdict (the documented "raw text -> Claude
# ignores output" antipattern). The fix routes the bd close's STDOUT to
# /dev/null too (`>/dev/null 2>&1`).
#
# This assertion captures STDOUT ONLY (2>/dev/null, NO `tail -1` salvage) and
# requires the whole thing to parse as JSON with no `✓` / "Updated issue"
# prefix. Written failing-first: pre-fix the raw stdout is
# `✓ Updated issue: <id>\n{}`, which fails `jq -e .`.
#
# Fresh task + empty-test detect-stack stub so the approved short-circuit is
# reached fast and in isolation from case 6's post-close state.
TID_STDOUT=$(cd "$FIXTURE" && bd create "Approved-path stdout (llh.20)" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
# Stub detect-stack to report an empty test_cmd (skip the test pass; stays fast
# and keeps the change-set non-doc so the approved path — not the F1 doc fast
# path — closes the task). Saved/restored around this case so later cases
# (which install their own detect-stack stub) are unaffected.
DS_REAL=$(readlink "$FIXTURE/.claude/scripts/detect-stack.sh" 2>/dev/null || printf '%s' "$FIXTURE/.claude/scripts/detect-stack.sh")
rm -f "$FIXTURE/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$FIXTURE/.claude/scripts/detect-stack.sh"
chmod +x "$FIXTURE/.claude/scripts/detect-stack.sh"
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"
bash "$QG" enter "$TID_STDOUT" >/dev/null 2>&1
bash "$CT" set "$TID_STDOUT"
seed_review_records "$TID_STDOUT"   # V3 (jio.1) MIGRATION (approve + release)
bash "$QG" approve "$TID_STDOUT" "reviewed; ships safely" >/dev/null 2>&1
# approve clears current-task + truncates changed-files; restore both to the
# approved change-set so the legit Stop fires against the same reviewed files.
bash "$CT" set "$TID_STDOUT"
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"
# Capture STDOUT ONLY — discard stderr, take the WHOLE thing (no tail).
STDOUT_ONLY=$(printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' | bash "$VBS" 2>/dev/null)
# (1) The whole stdout must be valid JSON. This is the load-bearing llh.20
#     assertion: pre-fix the banner makes `jq -e .` over the whole stdout fail.
if printf '%s' "$STDOUT_ONLY" | jq -e . >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "vbs-llh20: approved-path stdout is valid JSON (whole stdout, no tail salvage)"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("vbs-llh20: approved-path stdout NOT valid JSON")
    printf '  FAIL: vbs-llh20: approved-path stdout NOT valid JSON: [%s]\n' "$STDOUT_ONLY"
fi
# (2) The stdout must not carry the `✓` banner prefix nor the "Updated issue"
#     text — a belt-and-braces guard that names the exact pollution source.
STDOUT_HAS_CHECK=$(printf '%s' "$STDOUT_ONLY" | grep -c 'Updated issue' || true)
STDOUT_HAS_CHECK=$(printf '%s' "$STDOUT_HAS_CHECK" | tr -d '[:space:]')
assert_eq "vbs-llh20: approved-path stdout carries no 'Updated issue' bd banner" \
    "0" "$STDOUT_HAS_CHECK"
# (3) And it is a RELEASING verdict — no `decision` key at all.
#
# RETARGETED, not weakened (claude-workflow-plugin-qzv). This used to assert the
# stdout parsed to exactly `{}`, and its own comment said "the clean approved
# verdict IN THIS FIXTURE" — i.e. it was already a fixture-shape claim, and its
# sibling case 6 above deliberately accepts either `{}` or a note-shaped envelope.
# qzv removed the `bd update --status closed` call from this path (an approval binds
# a CHANGE SET; closing is a claim about the TASK) and replaced the side effect with
# an in-band note naming the close command, so the release now emits a
# hookSpecificOutput envelope here.
#
# Note what that does to llh.20's own force: this case exists BECAUSE that bd call
# printed a `✓ Updated issue` banner onto stdout, so the pollution source is gone
# rather than tolerated. Assertions (1) and (2) — whole stdout is valid JSON, no
# banner text — are untouched and are the load-bearing pair. (3) now asserts the
# property that actually matters on a release path, "it does not block", plus the
# replacement affordance, which is strictly more than a shape equality was.
if printf '%s' "$STDOUT_ONLY" | jq -e 'has("decision") | not' >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "vbs-llh20: approved-path stdout is a RELEASING verdict (no decision key)"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("vbs-llh20: approved-path stdout is not a releasing verdict")
    printf '  FAIL: vbs-llh20: approved-path stdout is not a releasing verdict: [%s]\n' "$STDOUT_ONLY"
fi
assert_contains "vbs-llh20: ...and it names the close as the caller's decision (qzv replaced the side effect)" \
    "did NOT close it" "$(printf '%s' "$STDOUT_ONLY" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
# Restore the original detect-stack symlink for the cases that follow.
rm -f "$FIXTURE/.claude/scripts/detect-stack.sh"
ln -sf "$DS_REAL" "$FIXTURE/.claude/scripts/detect-stack.sh" 2>/dev/null || true

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
# 94d: account for this fixture's INCIDENTAL dirt so the change set really is
# only the two doc paths above. The `git init` at case 7 left every file in the
# fixture untracked, and `bd init` scaffolded `.gitignore`, `CLAUDE.md` and
# `AGENTS.md` on top — so without a baseline the reconciler correctly reads
# `.gitignore` as this session's work, DOC_ONLY goes false, and F1 never gets its
# chance. See baseline_incidental_dirt in lib/fixture.sh for why the fixture (not
# the reconciler) is what is wrong there.
baseline_incidental_dirt "$FIXTURE"
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
# claude-workflow-plugin-llh.17 (G2.gate-friction residual) — e2e fixture
# script/beads churn must NOT false-block the ORCHESTRATOR's Stop gate.
#
# Production evidence (observed 5x): during `make test-live`, runFixture syncs
# the canonical hook scripts into fixtures/<f>/.claude/scripts/ (llh.8
# run-start sync) and the live run mutates the fixture's own .beads/ ledger.
# The orchestrator session driving the run then fires its Stop hook while those
# fixture paths are dirty. changed-files.txt is EMPTY (post-edit never tracked
# the sync), so the gate falls through to the git-status fallback, which keeps
# any path passing is_tracked_change — and the denylist did NOT exclude
# fixture-internal .claude/scripts/ or .beads/. Result: a self-contradictory
# "QA approval required" block whose diff is purely harness-internal transient
# state the run's own teardown reverts minutes later.
#
# These repros drive the GIT-STATUS FALLBACK path specifically (empty
# changed-files.txt + a dirty fixture-internal path in git), which is the
# surface the orchestrator-session false-block lives on — distinct from the
# llh.3 repro-3 above, which drove transient paths through the TRACKING_FILE.
# Written FAILING-FIRST: pre-fix (no fixtures alternative in DENYLIST_REGEX)
# these BLOCK; the fix makes the hook ALLOW.
#
# A fresh git fixture with a NESTED e2e-fixture scripts tree so git-status has
# a real fixture-internal path to report.
mk_fixture
FIXTURE_FX="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_FX="$FIXTURE_FX/.claude/scripts/verify-before-stop.sh"
CT_FX="$FIXTURE_FX/.claude/scripts/current-task.sh"
TRACK_FX="$FIXTURE_FX/.claude/.qa-tracking"
# Build a nested e2e-fixture tree inside the component fixture and commit a
# baseline so subsequent edits show as modifications in git-status.
NESTED_SCRIPTS="$FIXTURE_FX/.claude/tests/e2e/fixtures/node-react-auth/.claude/scripts"
NESTED_BEADS="$FIXTURE_FX/.claude/tests/e2e/fixtures/node-react-auth/.beads"
NESTED_YAML="$FIXTURE_FX/.claude/tests/e2e/fixtures/node-react-auth/fixture.yaml"
mkdir -p "$NESTED_SCRIPTS" "$NESTED_BEADS"
printf '#!/bin/bash\n# canonical-synced qa-gate (baseline)\n' > "$NESTED_SCRIPTS/qa-gate.sh"
printf '{"id":"fixture-task","status":"open"}\n' > "$NESTED_BEADS/issues.jsonl"
printf 'name: node-react-auth\ninvariants: []\n' > "$NESTED_YAML"
(cd "$FIXTURE_FX" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

run_vbs_fx() {
    printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS_FX" 2>&1 | tail -1
}

# --- Repro 1: dirty fixture-internal SCRIPT churn (the llh.8 run-start sync) ---
# changed-files.txt empty; git-status shows ONLY the synced fixture script
# dirtied. Assert: ALLOW. Pre-fix this is the exact orchestrator-session
# false-block.
bash "$CT_FX" clear
: > "$TRACK_FX/changed-files.txt"
printf '#!/bin/bash\n# canonical-synced qa-gate (MUTATED by live run sync)\n' > "$NESTED_SCRIPTS/qa-gate.sh"
OUT_FX_SCRIPT=$(run_vbs_fx)
assert_empty_envelope "vbs-llh17: fixture-internal script churn (git fallback) -> ALLOW" \
    "$OUT_FX_SCRIPT"

# --- Repro 2: dirty fixture-internal .beads churn -------------------------
# Restore the script, dirty the fixture's own beads ledger instead. Assert:
# ALLOW (fixture-internal beads is transient test state, not the project's
# audit-trail beads).
printf '#!/bin/bash\n# canonical-synced qa-gate (baseline)\n' > "$NESTED_SCRIPTS/qa-gate.sh"
printf '{"id":"fixture-task","status":"closed"}\n' > "$NESTED_BEADS/issues.jsonl"
: > "$TRACK_FX/changed-files.txt"
OUT_FX_BEADS=$(run_vbs_fx)
assert_empty_envelope "vbs-llh17: fixture-internal .beads churn (git fallback) -> ALLOW" \
    "$OUT_FX_BEADS"

# --- ANTI-OVERREACH 1: a REAL plugin-source change still BLOCKS -----------
# Restore the fixture paths; dirty a REAL plugin-source file at the project
# root instead. The fixtures denylist alternative must NOT swallow this — it
# is a genuine orchestrator-visible change with no active task, so the
# QA-required block must still fire. Assert: BLOCK.
printf '{"id":"fixture-task","status":"open"}\n' > "$NESTED_BEADS/issues.jsonl"
mkdir -p "$FIXTURE_FX/src"
printf 'export const x = 1;\n' > "$FIXTURE_FX/src/real-source.ts"
bash "$CT_FX" clear
: > "$TRACK_FX/changed-files.txt"
OUT_FX_REAL=$(run_vbs_fx)
assert_decision "vbs-llh17 anti-overreach: REAL plugin-source change STILL blocks (git fallback)" \
    "$OUT_FX_REAL" "block"
rm -f "$FIXTURE_FX/src/real-source.ts"

# --- ANTI-OVERREACH 2: a fixture DELIVERABLE (fixture.yaml) still BLOCKS ---
# The denylist is scoped to the fixtures' .claude/scripts + .beads subtrees.
# A change to the fixture's OWN deliverable (fixture.yaml, src/, the scenario
# prompt) is reviewable intent and must NOT be denylisted. Assert: BLOCK.
printf 'name: node-react-auth\ninvariants: [stop-requires-approval]\n' > "$NESTED_YAML"
bash "$CT_FX" clear
: > "$TRACK_FX/changed-files.txt"
OUT_FX_YAML=$(run_vbs_fx)
assert_decision "vbs-llh17 anti-overreach: fixture DELIVERABLE (fixture.yaml) STILL blocks" \
    "$OUT_FX_YAML" "block"
# Restore the deliverable so the tree is clean for any later reuse.
printf 'name: node-react-auth\ninvariants: []\n' > "$NESTED_YAML"

# --- META-TEST: prove the fixtures-denylist ALLOW assertions are load-bearing.
# Strip the fixtures alternative from the DENYLIST REGEX (the pre-llh.17
# world) and re-run repro 1. The fixture-script-churn case must then BLOCK —
# proving the ALLOW assertion above is sensitive to the denylist extension,
# not passing for some incidental reason. Pattern-anchored python strip over
# the unique fixtures sub-pattern; never a line number.
#
# 3mg.1 CHANGED WHAT IS MUTATED, not the force of the assertion. The regex
# moved out of verify-before-stop.sh into the shared
# `.claude/scripts/workflow-denylist.sh`, so the mutation now targets the LIB
# — which is exactly right: the lib is the single definition all three
# consumers read. We overwrite the FIXTURE's symlink with a mutated regular
# file (rm first, so the edit can never reach the real plugin script through
# the link) and run the UNMODIFIED hook against it, then restore the symlink.
DENYLIST_LIB_FX="$FIXTURE_FX/.claude/scripts/workflow-denylist.sh"
REAL_DENYLIST_FX=$(readlink "$DENYLIST_LIB_FX" || printf '%s' "$DENYLIST_LIB_FX")
rm -f "$DENYLIST_LIB_FX"
FIXTURES_ALT='|(^|/)\.claude/tests/e2e/fixtures/[^/]+/(\.claude/(scripts|beads)|\.beads)/' \
    REAL_DENYLIST_FX="$REAL_DENYLIST_FX" DENYLIST_LIB_FX="$DENYLIST_LIB_FX" python3 - <<'PYEOF'
import io, os
real = os.environ["REAL_DENYLIST_FX"]; out = os.environ["DENYLIST_LIB_FX"]; alt = os.environ["FIXTURES_ALT"]
with io.open(real, "r", encoding="utf-8") as f:
    s = f.read()
if alt not in s:
    raise SystemExit("META precondition failed: fixtures alternative not found in workflow-denylist.sh")
s = s.replace(alt, "", 1)
with io.open(out, "w", encoding="utf-8") as f:
    f.write(s)
PYEOF
chmod +x "$DENYLIST_LIB_FX"
# Confirm the alternative was actually removed from the mutated lib. Anchor on
# the regex-only token `fixtures/[^/]+/` (the `[^/]+` bracket-class appears
# ONLY in WORKFLOW_DENYLIST_REGEX, never in the prose header that also
# mentions "tests/e2e/fixtures") so the precondition checks the LOAD-BEARING
# regex, not the doc comment.
FX_MUT_STRIPPED=$(grep -cF 'fixtures/[^/]+/' "$DENYLIST_LIB_FX" || true)
FX_MUT_STRIPPED=$(printf '%s' "$FX_MUT_STRIPPED" | tr -d '[:space:]')
assert_eq "vbs-llh17 META: fixtures denylist alternative stripped from the lib (regex token gone)" \
    "0" "$FX_MUT_STRIPPED"
# And the lib is still a VALID lib — otherwise the hook would take the
# missing-denylist fail-closed arm and BLOCK for the wrong reason, turning
# the assertion below into a false pass.
FX_MUT_STILL_DEFINES=$(grep -c '^WORKFLOW_DENYLIST_REGEX=' "$DENYLIST_LIB_FX" || true)
FX_MUT_STILL_DEFINES=$(printf '%s' "$FX_MUT_STILL_DEFINES" | tr -d '[:space:]')
assert_eq "vbs-llh17 META: mutated lib still defines WORKFLOW_DENYLIST_REGEX (block is not the missing-lib arm)" \
    "1" "$FX_MUT_STILL_DEFINES"
bash "$CT_FX" clear
: > "$TRACK_FX/changed-files.txt"
printf '#!/bin/bash\n# synced qa-gate (mutated again)\n' > "$NESTED_SCRIPTS/qa-gate.sh"
OUT_FX_MUT=$(run_vbs_fx)
assert_decision "vbs-llh17 META: with fixtures denylist stripped, fixture-script churn BLOCKS (ALLOW assertion WOULD fail)" \
    "$OUT_FX_MUT" "block"
REASON_FX_MUT=$(printf '%s' "$OUT_FX_MUT" | jq -r '.reason // empty')
assert_contains "vbs-llh17 META: the block is the QA-review block, not the missing-denylist block" \
    "QA approval required" "$REASON_FX_MUT"
# Restore the real lib symlink + the baseline script.
rm -f "$DENYLIST_LIB_FX"
ln -sf "$REAL_DENYLIST_FX" "$DENYLIST_LIB_FX"
printf '#!/bin/bash\n# canonical-synced qa-gate (baseline)\n' > "$NESTED_SCRIPTS/qa-gate.sh"

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

# ===========================================================================
# Mutation-survivor kills (G2.6ix / claude-workflow-plugin-llh.5).
#
# Two gaps the C.3 sweep (task claude-workflow-plugin-6ix) left, re-confirmed
# surviving against the CURRENT code by the re-sweep
# (.claude/.mutation-runs/20260613T102846Z):
#
#   A. Lint / type-check block-reason wording (original survivors id16-19):
#      no spec ever configured a FAILING lint_cmd or type_cmd, so the mutants
#      flipping `lint_rc -ne 0` / `type_rc -ne 0` (bullet vanishes) and
#      `lint_rc = 124` / `type_rc = 124` (rc=1 mislabelled "timed out") all
#      survived. The escalation-binding spec covers the TEST bullet wording;
#      this covers lint + type.
#
#   B. No-active-task beads/empty fast-path (NEW survivor introduced by the
#      llh.3 fast-path code at the `FASTPATH_CLASS = "beads-state"` elif): the
#      existing llh.3 repros all enter a task first, so the "no task +
#      beads-only change-set -> ALLOW" sub-branch was uncovered. Negating
#      `[ "$FASTPATH_CLASS" = "beads-state" ]` made a no-task beads-only Stop
#      fall through to a QA-required block instead of allowing.
#
# Fresh fixture: a detect-stack stub that reports a passing (empty) test_cmd
# plus shimmable lint/type commands, and a git repo so the no-task fast-path
# git fallback has something to read.
mk_fixture
FIXTURE3="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS3="$FIXTURE3/.claude/scripts/verify-before-stop.sh"
QG3="$FIXTURE3/.claude/scripts/qa-gate.sh"
CT3="$FIXTURE3/.claude/scripts/current-task.sh"
TRACK3="$FIXTURE3/.claude/.qa-tracking"

# detect-stack stub: empty test (skips the test pass -> stays fast and keeps
# the test bullet out of the way), failing-capable lint + type via shims.
rm -f "$FIXTURE3/.claude/scripts/detect-stack.sh"
cat > "$FIXTURE3/.claude/scripts/detect-stack.sh" <<'STUB'
#!/bin/bash
printf '{"runner":"npm","test_cmd":"","lint_cmd":"mylint","type_cmd":"mytype"}\n'
STUB
chmod +x "$FIXTURE3/.claude/scripts/detect-stack.sh"

# --- A. lint + type wording (ids 16-19) -----------------------------------
# Shim mylint + mytype to exit 1 (a genuine assertion-class failure, NOT a
# 124 timeout). The block reason must carry the exit-1 bullets and must NOT
# carry the timeout wording.
printf '#!/bin/bash\nexit 1\n' > "$FIXTURE3/bin/mylint"; chmod +x "$FIXTURE3/bin/mylint"
printf '#!/bin/bash\nexit 1\n' > "$FIXTURE3/bin/mytype"; chmod +x "$FIXTURE3/bin/mytype"
TID_LT=$(cd "$FIXTURE3" && bd create "lint/type wording" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG3" enter "$TID_LT" >/dev/null
bd label add "$TID_LT" qa-pending >/dev/null 2>&1
printf 'src/handler.ts\n' > "$TRACK3/changed-files.txt"
OUT_LT=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS3" 2>&1 | tail -1)
assert_decision "vbs mut16-19: failing lint+type blocks" "$OUT_LT" "block"
REASON_LT=$(printf '%s' "$OUT_LT" | jq -r '.reason // empty')
# id16: failing lint MUST produce the exit-1 bullet (mutant -eq drops it).
assert_contains "vbs mut16: failing lint renders 'Lint errors (exit 1)'" \
    "Lint errors (exit 1)" "$REASON_LT"
# id17: rc=1 lint must NOT be mislabelled as a timeout (mutant != 124).
LT_LINT_TIMEOUT=$(printf '%s' "$REASON_LT" | grep -c 'Lint timed out' || true)
LT_LINT_TIMEOUT=$(printf '%s' "$LT_LINT_TIMEOUT" | tr -d '[:space:]')
assert_eq "vbs mut17: rc=1 lint is NOT rendered as 'Lint timed out'" "0" "$LT_LINT_TIMEOUT"
# id18: failing type MUST produce the exit-1 bullet (mutant -eq drops it).
assert_contains "vbs mut18: failing type renders 'Type-check failing (exit 1)'" \
    "Type-check failing (exit 1)" "$REASON_LT"
# id19: rc=1 type must NOT be mislabelled as a timeout (mutant != 124).
LT_TYPE_TIMEOUT=$(printf '%s' "$REASON_LT" | grep -c 'Type-check timed out' || true)
LT_TYPE_TIMEOUT=$(printf '%s' "$LT_TYPE_TIMEOUT" | tr -d '[:space:]')
assert_eq "vbs mut19: rc=1 type is NOT rendered as 'Type-check timed out'" "0" "$LT_TYPE_TIMEOUT"

# --- B. no-active-task beads-state fast-path (NEW survivor, line ~677) -----
# A beads-only change-set with NO active task must ALLOW ({}). The mutant
# negating `[ "$FASTPATH_CLASS" = "beads-state" ]` would fall through to a
# QA-required block. Drive a beads-only tracked change-set and clear the task.
bash "$CT3" clear
printf '%s\n' '.beads/issues.jsonl' > "$TRACK3/changed-files.txt"
OUT_NTBS=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS3" 2>&1 | tail -1)
assert_empty_envelope "vbs mut(line677): no-task beads-only change-set -> ALLOW" "$OUT_NTBS"

# --- META-TEST: prove the lint-wording assertion is load-bearing ----------
# Build a copy of verify-before-stop.sh with the lint_rc guard mutated
# (-ne 0 -> -eq 0) so a failing lint produces NO bullet, and re-run the
# lint scenario. The "Lint errors (exit 1)" assertion must then FAIL — i.e.
# the bullet must be ABSENT — proving the assertion catches the regression.
#
# Anchor the mutation by the guard's UNIQUE text (`lint_rc" -ne 0`, which
# occurs exactly once), NOT an absolute line number. Pattern-anchoring keeps
# this META-TEST stable when unrelated edits shift line numbers — the llh.20
# fix added comment lines to the two `bd update --status closed` close paths,
# moving this guard 882->890, the kind of drift that used to silently un-land
# a fixed-line mutation (same lesson the truncation META-TEST below records).
# It still mutates the SAME guard, so the assertion is identical in force.
#
# 3mg.1: the mutant copy lives in the fixture's `.claude/scripts/`, NOT the
# fixture root. verify-before-stop.sh now loads `workflow-denylist.sh` from
# its OWN directory (BASH_SOURCE-relative) and BLOCKS with the
# "shared path denylist is missing" reason when it cannot. A copy parked
# outside scripts/ would take that arm and satisfy this assertion's
# "the lint bullet vanished" check for entirely the wrong reason.
REAL_VBS3=$(readlink "$VBS3" || printf '%s' "$VBS3")
VBS3_MUT="$FIXTURE3/.claude/scripts/vbs-lintmut.sh"
awk '/lint_rc" -ne 0/ {print "        if [ \"$lint_rc\" -eq 0 ]; then"; next} {print}' \
    "$REAL_VBS3" > "$VBS3_MUT"
chmod +x "$VBS3_MUT"
VBS3_MUT_LANDED=$(grep -c 'lint_rc" -eq 0' "$VBS3_MUT" || true)
VBS3_MUT_LANDED=$(printf '%s' "$VBS3_MUT_LANDED" | tr -d '[:space:]')
assert_eq "vbs META: lint-guard mutation applied to copy (pattern-anchored)" "1" "$VBS3_MUT_LANDED"
TID_LTM=$(cd "$FIXTURE3" && bd create "lint wording meta" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG3" enter "$TID_LTM" >/dev/null
bd label add "$TID_LTM" qa-pending >/dev/null 2>&1
printf 'src/handler.ts\n' > "$TRACK3/changed-files.txt"
OUT_LTM=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS3_MUT" 2>&1 | tail -1)
REASON_LTM=$(printf '%s' "$OUT_LTM" | jq -r '.reason // empty')
LTM_HAS_LINT=$(printf '%s' "$REASON_LTM" | grep -c 'Lint errors (exit 1)' || true)
LTM_HAS_LINT=$(printf '%s' "$LTM_HAS_LINT" | tr -d '[:space:]')
assert_eq "vbs META: under lint-guard mutant the 'Lint errors (exit 1)' bullet VANISHES (mut16 assertion WOULD fail)" \
    "0" "$LTM_HAS_LINT"
# Discriminator (3mg.1): the bullet must be absent because the guard was
# mutated, NOT because the mutant fell into the missing-denylist fail-closed
# arm (whose reason contains none of the check bullets either).
LTM_NOT_DENYLIST=$(printf '%s' "$REASON_LTM" | grep -c 'shared path denylist is missing' || true)
LTM_NOT_DENYLIST=$(printf '%s' "$LTM_NOT_DENYLIST" | tr -d '[:space:]')
assert_eq "vbs META: lint mutant ran the real gate (not the missing-denylist arm)" \
    "0" "$LTM_NOT_DENYLIST"

# --- changed-files truncation at >15 (QA-required path, line ~1016) -------
# Re-sweep survivor (exposed once the per-file cap was raised past line 884):
# the F1 mutant `CHANGE_COUNT -gt 15 -> -le 15` inverts the file-list
# truncation. With >15 tracked files the original shows the first 15 plus an
# "...and N more files" line; the mutant takes the else branch and dumps the
# FULL list (no truncation marker). Drive 20 tracked files with NO active task
# (clean QA-required block) and assert the truncation marker is present.
mk_fixture
FIXTURE4="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS4="$FIXTURE4/.claude/scripts/verify-before-stop.sh"
CT4="$FIXTURE4/.claude/scripts/current-task.sh"
TRACK4="$FIXTURE4/.claude/.qa-tracking"
# 20 unique tracked source files -> CHANGE_COUNT=20 (>15).
awk 'BEGIN{for(i=1;i<=20;i++)print "src/mod"i".ts"}' > "$TRACK4/changed-files.txt"
bash "$CT4" clear
OUT_TRUNC=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS4" 2>&1 | tail -1)
assert_decision "vbs mut1016: 20 changed files + no task -> block" "$OUT_TRUNC" "block"
REASON_TRUNC=$(printf '%s' "$OUT_TRUNC" | jq -r '.reason // empty')
# id1016: the truncation marker MUST appear (>15 triggers head -15 + "more files").
assert_contains "vbs mut1016: >15 changed files truncates with '...and N more files'" \
    "more files" "$REASON_TRUNC"
# Specifically "...and 5 more files" (20 - 15).
assert_contains "vbs mut1016: truncation reports the correct overflow count (20-15=5)" \
    "and 5 more files" "$REASON_TRUNC"

# --- META-TEST: prove the truncation assertion is load-bearing ------------
# Anchor the mutation by the guard's UNIQUE text, not an absolute line number:
# the `CHANGE_COUNT" -gt 15` guard appears exactly once, and pattern-anchoring
# keeps this META-TEST stable when unrelated edits shift line numbers (the
# llh.18 re-work added comment lines above this guard, moving it 1131->1153 —
# the kind of drift that used to silently un-land the mutation). It still
# mutates the SAME guard (`-gt 15` -> `-le 15`), so the assertion is identical
# in force.
#
# 3mg.1: the copy lives in the fixture's `.claude/scripts/` for the same
# reason as the lint mutant above — a hook parked outside scripts/ can no
# longer find its `workflow-denylist.sh` sibling and blocks on THAT instead,
# which would make "the truncation marker vanished" trivially true.
REAL_VBS4=$(readlink "$VBS4" || printf '%s' "$VBS4")
VBS4_MUT="$FIXTURE4/.claude/scripts/vbs-truncmut.sh"
awk '/CHANGE_COUNT" -gt 15/ {print "        if [ \"$CHANGE_COUNT\" -le 15 ]; then"; next} {print}' \
    "$REAL_VBS4" > "$VBS4_MUT"
chmod +x "$VBS4_MUT"
VBS4_MUT_LANDED=$(grep -c 'CHANGE_COUNT" -le 15' "$VBS4_MUT" || true)
VBS4_MUT_LANDED=$(printf '%s' "$VBS4_MUT_LANDED" | tr -d '[:space:]')
assert_eq "vbs META: truncation guard mutation applied to copy (pattern-anchored)" "1" "$VBS4_MUT_LANDED"
bash "$CT4" clear
awk 'BEGIN{for(i=1;i<=20;i++)print "src/mod"i".ts"}' > "$TRACK4/changed-files.txt"
REASON_TRUNCM=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS4_MUT" 2>&1 | tail -1 | jq -r '.reason // empty')
TRUNCM_MORE=$(printf '%s' "$REASON_TRUNCM" | grep -c 'more files' || true)
TRUNCM_MORE=$(printf '%s' "$TRUNCM_MORE" | tr -d '[:space:]')
assert_eq "vbs META: under -le 15 mutant the truncation marker VANISHES (mut1016 assertion WOULD fail)" \
    "0" "$TRUNCM_MORE"
# Discriminator (3mg.1): the marker is absent because the guard was inverted
# and the FULL list printed — not because the mutant blocked on a missing
# denylist before ever rendering a file list.
TRUNCM_LISTED=$(printf '%s' "$REASON_TRUNCM" | grep -q 'src/mod20\.ts' && echo yes || echo no)
assert_eq "vbs META: trunc mutant printed the FULL file list (ran the real gate)" \
    "yes" "$TRUNCM_LISTED"

# ===========================================================================
# claude-workflow-plugin-llh.18 (red-team P0/P1) — change-set-bound approval.
#
# The headline falsification: verify-before-stop.sh used to RELEASE on the
# qa-approved LABEL alone (GATE_STATUS == approved == has_label qa-approved).
# That label is forgeable by any agent (`bd label add <task> qa-approved`,
# bypassing qa-gate.sh approve's impact-report refusal / audit comment /
# rubric — P0) and is never bound to the tracked changed files (approve a
# trivial decoy, redirect current-task, ship unrelated code — P1).
#
# The fix: release now requires BOTH the qa-approved label AND a
# tamper-evident `QA-GATE APPROVED change_set_hash=<h>` record (written only
# by qa-gate.sh approve) whose <h> matches the CURRENT change-set hash. This
# blocks the forged bare label (no record), the decoy redirect (record's hash
# != current change-set), and post-approval edits (current hash drifted).
#
# Written FAILING-FIRST: against the pre-fix script the forged-label and
# decoy-redirect cases ALLOW (red); the captured repro is on the Beads task.
#
# Fresh fixture: a real git repo + a passing (empty) test command so the
# QA-approval path is reached without the test/lint pass interfering.
mk_fixture
FIXTURE_CSB="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_CSB="$FIXTURE_CSB/.claude/scripts/verify-before-stop.sh"
QG_CSB="$FIXTURE_CSB/.claude/scripts/qa-gate.sh"
CT_CSB="$FIXTURE_CSB/.claude/scripts/current-task.sh"
IR_CSB="$FIXTURE_CSB/.claude/scripts/impact-report.sh"
TRACK_CSB="$FIXTURE_CSB/.claude/.qa-tracking"
(cd "$FIXTURE_CSB" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true
# detect-stack stub: empty test_cmd so the test pass is skipped (stays fast,
# keeps the change-set non-doc so the F1 fast path does NOT swallow it).
rm -f "$FIXTURE_CSB/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$FIXTURE_CSB/.claude/scripts/detect-stack.sh"
chmod +x "$FIXTURE_CSB/.claude/scripts/detect-stack.sh"

csb_decision() {
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | bash "$VBS_CSB" 2>/dev/null | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null
}

# --- Repro P0: forged bare label -> BLOCK (currently red pre-fix) ----------
TID_P0=$(cd "$FIXTURE_CSB" && bd create "forged-label P0" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
printf 'src/handler.ts\n' > "$TRACK_CSB/changed-files.txt"
bash "$QG_CSB" enter "$TID_P0" >/dev/null 2>&1
bash "$CT_CSB" set "$TID_P0"
# Control: entered, no approval -> block.
assert_eq "vbs-llh18: P0 control (entered, no approval) blocks" "block" "$(csb_decision)"
# Forge the label WITHOUT going through qa-gate.sh approve.
bd label add "$TID_P0" qa-approved >/dev/null 2>&1
# Sanity: the gate's status now reports approved (the forgeable signal).
P0_STATUS=$(bash "$QG_CSB" status "$TID_P0" | jq -r '.status' 2>/dev/null)
assert_eq "vbs-llh18: P0 bare label flips qa-gate status to approved (the forgeable signal)" \
    "approved" "$P0_STATUS"
# THE failing-first assertion: a forged bare label must NOT release.
assert_eq "vbs-llh18: P0 forged bare label -> BLOCK (no change-set-bound record)" \
    "block" "$(csb_decision)"
# The block reason must name the exact failure mode + correct remediation.
P0_REASON=$(printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
    | bash "$VBS_CSB" 2>/dev/null | tail -1 | jq -r '.reason // empty')
assert_contains "vbs-llh18: P0 reason explains no change-set-bound record matches" \
    "no change-set-bound approval record matches" "$P0_REASON"
assert_contains "vbs-llh18: P0 reason steers to qa-gate.sh approve, not a bare label add" \
    "not a bare label add" "$P0_REASON"

# --- Positive: legit qa-gate.sh approve -> RELEASE -------------------------
TID_POS=$(cd "$FIXTURE_CSB" && bd create "legit approve release" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
printf 'src/handler.ts\n' > "$TRACK_CSB/changed-files.txt"
bash "$QG_CSB" enter "$TID_POS" >/dev/null 2>&1   # generates a fresh impact report for this change-set
bash "$CT_CSB" set "$TID_POS"
assert_eq "vbs-llh18: positive control (entered, not approved) blocks" "block" "$(csb_decision)"
# V3 (jio.1) MIGRATION: seed the independent-review records so both approve
# and the Stop hook's review-discipline re-check are satisfied; the case under
# test is still the change-set BINDING.
seed_review_records "$TID_POS" "qa-claude" "backend" "$FIXTURE_CSB"
# claude-workflow-plugin-rqer (v5 D2): capture the FULL tracker verbatim
# BEFORE approve. seed_review_records already reconciled its canonical
# artifact into it (AC-4), so this is exactly the set approve is about to
# bind — and a `reconcile-tracker` call AFTER approve cannot recover it:
# approve's own baseline refresh is a FULL, unconditional snapshot of
# everything dirty at that instant (0wk.2 — "everything dirty right now has
# been reviewed"), so a later reconcile finds the artifact (and any other
# incidental fixture dirt an earlier `enter` already swept in, here
# .claude/scripts/detect-stack.sh) ALREADY BASELINED and adds nothing back —
# measured directly: the "restore src/handler.ts, then reconcile" shape
# recomputed a DIFFERENT hash than the one approve just bound.
POS_TRACKER_SNAPSHOT=$(cat "$TRACK_CSB/changed-files.txt" 2>/dev/null)
# Legit approve writes the change-set-bound record.
POS_APPROVE=$(bash "$QG_CSB" approve "$TID_POS" "reviewed; ships safely" 2>&1)
assert_json_field "vbs-llh18: legit approve succeeds" "$POS_APPROVE" '.status' "approved"
assert_contains "vbs-llh18: approve obs reports the change-set-bound record" \
    "change-set-bound approval record written" "$POS_APPROVE"
# approve clears current-task + truncates changed-files; restore both to the
# approved change-set (the legit Stop fires against the same reviewed files).
bash "$CT_CSB" set "$TID_POS"
printf '%s\n' "$POS_TRACKER_SNAPSHOT" > "$TRACK_CSB/changed-files.txt"
# Direct proof the record carries the hash --hash-only computes for the
# RESTORED change-set. Captured BEFORE the release assertion below, because
# the RELEASE path runs vbs's QA-approved cleanup (it rm's changed-files.txt),
# after which --hash-only would return the empty-set hash.
POS_CUR_HASH=$(CLAUDE_PROJECT_DIR="$FIXTURE_CSB" bash "$IR_CSB" --hash-only 2>/dev/null || echo "")
POS_REC_HASH=$(bd_show_with_comments "$TID_POS" "$FIXTURE_CSB" \
    | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text
             | select(test("QA-GATE APPROVED .*change_set_hash="))
             | capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h' 2>/dev/null | head -1)
assert_eq "vbs-llh18: recorded change_set_hash == --hash-only of the approved change-set" \
    "$POS_CUR_HASH" "$POS_REC_HASH"
assert_eq "vbs-llh18: positive legit approve -> RELEASE (matching record)" \
    "ALLOW" "$(csb_decision)"

# --- Hash-mismatch: edit a tracked file after approval -> re-BLOCK ----------
# Reuse the approved TID_POS; introduce a NEW tracked file so the current
# change-set hash drifts away from the recorded one.
printf 'src/handler.ts\nsrc/added-after-approval.ts\n' > "$TRACK_CSB/changed-files.txt"
bash "$CT_CSB" set "$TID_POS"
assert_eq "vbs-llh18: post-approval edit (hash drift) -> BLOCK (re-review)" \
    "block" "$(csb_decision)"

# --- Repro P1: decoy-task redirect -> BLOCK (currently red pre-fix) ---------
# Approve a trivial DECOY (its own change-set), redirect current-task to it,
# then ship a DIFFERENT, unreviewed change-set. The decoy's record carries the
# decoy's hash, which will not match the shipping change-set.
TID_REAL=$(cd "$FIXTURE_CSB" && bd create "P1 real unreviewed" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
printf 'src/secret-feature.ts\n' > "$TRACK_CSB/changed-files.txt"
bash "$QG_CSB" enter "$TID_REAL" >/dev/null 2>&1
bash "$CT_CSB" set "$TID_REAL"
assert_eq "vbs-llh18: P1 real unreviewed change blocks first" "block" "$(csb_decision)"
# Legitimately approve a decoy with a DIFFERENT change-set.
TID_DECOY=$(cd "$FIXTURE_CSB" && bd create "P1 trivial decoy" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
printf 'src/trivial-decoy.ts\n' > "$TRACK_CSB/changed-files.txt"
bash "$QG_CSB" enter "$TID_DECOY" >/dev/null 2>&1
seed_review_records "$TID_DECOY" "qa-claude" "backend" "$FIXTURE_CSB"   # V3 (jio.1) MIGRATION
bash "$QG_CSB" approve "$TID_DECOY" "decoy reviewed (trivial)" >/dev/null 2>&1
assert_eq "vbs-llh18: P1 decoy genuinely approved" "approved" \
    "$(bash "$QG_CSB" status "$TID_DECOY" | jq -r '.status' 2>/dev/null)"
# Redirect current-task to the decoy, restore the REAL unreviewed change-set.
bash "$CT_CSB" set "$TID_DECOY"
printf 'src/secret-feature.ts\n' > "$TRACK_CSB/changed-files.txt"
# THE failing-first assertion: the decoy's approval must not release the
# unrelated, unreviewed change-set.
assert_eq "vbs-llh18: P1 decoy redirect -> BLOCK (record hash != shipping change-set)" \
    "block" "$(csb_decision)"

# ===========================================================================
# llh.18 re-work — fail-OPEN regression on MISSING impact-report.sh.
#
# QA BLOCK (bd note 355): verify-before-stop.sh:~1060
#   CURRENT_CS_HASH=$(current_change_set_hash)
# runs under `set -e` (line 25). current_change_set_hash() returns 1 when
# impact-report.sh is MISSING (`[ -f "$IMPACT_REPORT_SCRIPT" ] || { printf '';
# return 1; }`). A bare command-substitution ASSIGNMENT whose RHS exits
# non-zero trips `set -e` -> the whole script ABORTS with empty stdout +
# exit 1. Per the hooks contract only exit 2 / a JSON `decision:block`
# blocks a Stop; exit 1 with no envelope is a NON-blocking error -> Claude
# ALLOWS the Stop (FAIL-OPEN). The intended fail-closed branch the implementer
# wrote (the `if [ -z "$CURRENT_CS_HASH" ]` arm of LABEL_WITHOUT_RECORD) is
# UNREACHABLE in this sub-case because the abort happens at the assignment.
#
# ASYMMETRY that proves it's this exact mechanism (not a different missing-dep
# failure): the PRESENT-BUT-FAILING case fails CLOSED correctly — the existing
# P0/decoy/hash-drift cases above all exercise a present impact-report.sh whose
# helper bodies end in `|| printf ''` (rc 0) so the empty hash reaches the
# LABEL_WITHOUT_RECORD block. Only the MISSING-script case (no `|| ...` guard
# at the call site) aborts. The producer (qa-gate.sh approve) REFUSES (exit 2)
# when impact-report.sh is missing, so the consumer's fail-open is a
# producer/consumer inconsistency too.
#
# Exploit (re-opens the very P0 this task fixes, one line): an agent with
# shell runs `rm .claude/scripts/impact-report.sh` then a bare
# `bd label add <task> qa-approved` -> the Stop fails open -> unreviewed code
# ships. It also silently disables gating in any partial-install /
# code-graph-absent environment that lacks impact-report.sh: a genuine
# post-approval edit there fails to re-block.
#
# Written FAILING-FIRST: against the pre-fix script this assertion is RED
# (the gate aborts -> ALLOW, not block). The fix
# (`CURRENT_CS_HASH=$(current_change_set_hash) || true`) lets the missing-script
# case fall into the existing fail-closed LABEL_WITHOUT_RECORD branch -> block.
#
# Fresh fixture so the deletion of impact-report.sh can't disturb the other
# llh.18 cases above (they share FIXTURE_CSB, whose impact-report.sh must stay
# intact for the positive-release / hash-drift / decoy assertions).
mk_fixture
FIXTURE_MISS="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_MISS="$FIXTURE_MISS/.claude/scripts/verify-before-stop.sh"
QG_MISS="$FIXTURE_MISS/.claude/scripts/qa-gate.sh"
CT_MISS="$FIXTURE_MISS/.claude/scripts/current-task.sh"
IR_MISS="$FIXTURE_MISS/.claude/scripts/impact-report.sh"
TRACK_MISS="$FIXTURE_MISS/.claude/.qa-tracking"
(cd "$FIXTURE_MISS" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true
# detect-stack stub: empty test_cmd (skip the test pass; keep the change-set
# non-doc so the F1 fast path does NOT swallow it before the approved-path).
rm -f "$FIXTURE_MISS/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$FIXTURE_MISS/.claude/scripts/detect-stack.sh"
chmod +x "$FIXTURE_MISS/.claude/scripts/detect-stack.sh"

# decision-or-abort helper: capture the FINAL JSON line AND distinguish the
# three outcomes precisely so the evidence is unambiguous:
#   "block"   -> emitted {"decision":"block",...}     (FAIL-CLOSED, correct)
#   "ALLOW"   -> emitted {} / a note envelope          (allowed the Stop)
#   "ABORT"   -> empty stdout + non-zero exit (set -e abort = the bug symptom)
# Both ALLOW and ABORT are fail-open; only "block" is correct here.
miss_decision() {
    local raw rc dec
    raw=$(printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | bash "$VBS_MISS" 2>/dev/null)
    rc=$?
    local last
    last=$(printf '%s' "$raw" | tail -1)
    if [ -z "$last" ]; then
        # Empty stdout. If the process also exited non-zero, that is the
        # set -e abort (fail-open). Name it distinctly.
        if [ "$rc" -ne 0 ]; then printf 'ABORT'; else printf 'ALLOW'; fi
        return
    fi
    dec=$(printf '%s' "$last" | jq -r '.decision // "ALLOW"' 2>/dev/null || printf 'ALLOW')
    printf '%s' "$dec"
}

# Build a legit, change-set-bound approval (record present, hash matches), so
# we isolate the variable under test to "impact-report.sh present vs missing"
# and nothing else. With the script PRESENT this releases (sanity check).
TID_MISS=$(cd "$FIXTURE_MISS" && bd create "missing impact-report fail-closed" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
printf 'src/handler.ts\n' > "$TRACK_MISS/changed-files.txt"
bash "$QG_MISS" enter "$TID_MISS" >/dev/null 2>&1     # generates the impact report
seed_review_records "$TID_MISS" "qa-claude" "backend" "$FIXTURE_MISS"   # V3 (jio.1) MIGRATION
# claude-workflow-plugin-rqer (v5 D2): capture the FULL tracker verbatim
# BEFORE approve — see the vbs-llh18 note above for why a POST-approve
# `reconcile-tracker` cannot recover it (approve's own baseline refresh
# consumes the "newness" of everything dirty at that instant).
MISS_TRACKER_SNAPSHOT=$(cat "$TRACK_MISS/changed-files.txt" 2>/dev/null)
bash "$QG_MISS" approve "$TID_MISS" "reviewed; ships safely" >/dev/null 2>&1
# approve clears current-task + truncates changed-files; restore both to the
# approved change-set so the legit Stop fires against the same reviewed files.
bash "$CT_MISS" set "$TID_MISS"
printf '%s\n' "$MISS_TRACKER_SNAPSHOT" > "$TRACK_MISS/changed-files.txt"
# Sanity: with impact-report.sh PRESENT, the matching record releases.
assert_eq "vbs-llh18-miss: sanity — legit approve releases while impact-report.sh present" \
    "ALLOW" "$(miss_decision)"

# Now HIDE impact-report.sh. The label + matching record are untouched; the
# ONLY change is the script the gate needs to recompute the current hash.
# Re-seed the change-set (the sanity release above ran vbs's QA-approved
# cleanup, which rm's changed-files.txt).
bash "$CT_MISS" set "$TID_MISS"
printf 'src/handler.ts\n' > "$TRACK_MISS/changed-files.txt"
MISS_REAL_IR=$(readlink "$IR_MISS" 2>/dev/null || printf '%s' "$IR_MISS")
rm -f "$IR_MISS"
# Prove the precondition: the script the gate calls is genuinely gone.
assert_eq "vbs-llh18-miss: precondition — impact-report.sh is absent" \
    "absent" "$([ -e "$IR_MISS" ] && echo present || echo absent)"

# THE failing-first assertion: a MISSING impact-report.sh must FAIL CLOSED
# (decision:block), NOT fail open. Pre-fix this is RED — the gate aborts under
# set -e (miss_decision returns ABORT) instead of emitting a block envelope.
assert_eq "vbs-llh18-miss: MISSING impact-report.sh -> FAIL-CLOSED (decision:block, not abort/allow)" \
    "block" "$(miss_decision)"
# The block reason must name the exact failure mode (the dead-code branch the
# fix makes reachable): hash could not be recomputed because the script is gone.
MISS_REASON=$(printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
    | bash "$VBS_MISS" 2>/dev/null | tail -1 | jq -r '.reason // empty' 2>/dev/null || printf '')
assert_contains "vbs-llh18-miss: block reason explains the hash could not be recomputed" \
    "could not be recomputed" "$MISS_REASON"

# Restore impact-report.sh for any later cases that reuse the symlink target
# (defensive; this fixture isn't reused below, but keep the tree consistent).
ln -sf "$MISS_REAL_IR" "$IR_MISS" 2>/dev/null || true

# ===========================================================================
# META-TEST (llh.18): prove the hash-match check is LOAD-BEARING.
#
# Neutralize ONLY the new check by shadowing task_has_matching_approval_record
# so it always reports a match (return 0) — i.e., the pre-fix world where
# label-presence alone releases. Under that shadow the forged-bare-label case
# must RELEASE again, so the "P0 forged label -> BLOCK" assertion above WOULD
# fail. That demonstrates the assertion is sensitive to the new check, not
# passing for some incidental reason.
mk_fixture
FIXTURE_MM18="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_MM18="$FIXTURE_MM18/.claude/scripts/verify-before-stop.sh"
QG_MM18="$FIXTURE_MM18/.claude/scripts/qa-gate.sh"
CT_MM18="$FIXTURE_MM18/.claude/scripts/current-task.sh"
TRACK_MM18="$FIXTURE_MM18/.claude/.qa-tracking"
(cd "$FIXTURE_MM18" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true
rm -f "$FIXTURE_MM18/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$FIXTURE_MM18/.claude/scripts/detect-stack.sh"
chmod +x "$FIXTURE_MM18/.claude/scripts/detect-stack.sh"
# Build the shadowed copy: append an override of the matcher AFTER its real
# definition (later definition wins in bash) but BEFORE the main flow consumes
# stdin. Insert immediately after the function's closing brace.
PLUGIN_VBS_MM18=$(readlink "$VBS_MM18" || printf '%s' "$VBS_MM18")
rm -f "$VBS_MM18"
awk '
    { print }
    /^task_has_matching_approval_record\(\) \{$/ { seen=1 }
    seen && /^\}$/ && !done {
        print ""
        print "# META-TEST override (llh.18): neutralize the change-set-bound check."
        print "task_has_matching_approval_record() { return 0; }"
        done=1
    }
' "$PLUGIN_VBS_MM18" > "$VBS_MM18"
chmod +x "$VBS_MM18"
# Sanity: the override landed.
MM18_LANDED=$(grep -c 'META-TEST override (llh.18)' "$VBS_MM18" || true)
MM18_LANDED=$(printf '%s' "$MM18_LANDED" | tr -d '[:space:]')
assert_eq "vbs META-llh18: matcher override applied to copy" "1" "$MM18_LANDED"
# Forge a bare label under the neutralized check.
TID_MM18=$(cd "$FIXTURE_MM18" && bd create "meta forged label" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
printf 'src/handler.ts\n' > "$TRACK_MM18/changed-files.txt"
bash "$QG_MM18" enter "$TID_MM18" >/dev/null 2>&1
bash "$CT_MM18" set "$TID_MM18"
bd label add "$TID_MM18" qa-approved >/dev/null 2>&1   # forged bare label
# V3 (jio.1) MIGRATION: the release path now has TWO independent gates — the
# llh.18 change-set binding (neutralized above) and the review-discipline
# re-check. Seed clean review records so the ONLY thing this META isolates is
# still the binding check; without this the forged label would block for the
# review reason and the META would prove nothing about llh.18.
seed_review_records "$TID_MM18" "qa-claude" "backend" "$FIXTURE_MM18"
MM18_DEC=$(printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
    | bash "$VBS_MM18" 2>/dev/null | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null)
# Under the neutralized check the forged label RELEASES (the P0 assertion
# above would FAIL against this copy) — proving the check is load-bearing.
assert_eq "vbs META-llh18: with hash-match check neutralized, forged label RELEASES (P0 assertion WOULD fail)" \
    "ALLOW" "$MM18_DEC"

# ===========================================================================
# claude-workflow-plugin-qzv — THE F1 CHANGE-SET BINDING.
#
# THE DEFECT. F1's verdict is a statement about a CHANGE SET ("no reviewable
# source changed"). Its `qa-approved` label is a statement about a TASK ("this
# task's work is approved"). Those are different propositions, and any doc-only
# Stop that lands while a task is open converts the first into the second.
# Reproduced live FOUR times, the last on the v4.1.0 release task itself
# (`claude-workflow-plugin-uvk`, 2026-07-30): 22 seconds after the release
# implementer was spawned and before it had written anything, F1 recorded
# `QA-GATE APPROVED change_set_hash=9942b2bd reviewed_by=none` over the PREVIOUS
# task's doc-only change set and closed the task. The clean reproduction on
# `claude-workflow-plugin-0fc` is the shape these legs drive: gate entered
# 15:44:00Z, `IMPLEMENTER: role=devops` posted at 15:44:59Z, F1 stamped an
# approval at 15:46:39Z.
#
# THE PREDICATE UNDER TEST. F1 may auto-approve only when no
# `IMPLEMENTER: role=… task=… at <ts>` record on the active task is at-or-newer
# than the most recent `QA-GATE: entered at <ts>`. Both grammars are single-line
# ISO-8601-UTC, so the comparison is lexicographic; both timestamps come from
# `review-check.sh gate`'s envelope (`cycle_opened_ts` / `latest_implementer_ts`)
# rather than from a second parser in the Stop hook.
#
# THE TWO ANTI-OVERREACH CONSTRAINTS, each with its own leg below:
#   - Leg 3: NO implementer record must still APPROVE. Doc-only work is
#     orchestrator-authored and never gets an IMPLEMENTER record, so requiring
#     one would deadlock every documentation commit.
#   - Legs 4/5/6: when the predicate CANNOT BE ESTABLISHED the gate must fall
#     through to the QA-required block NAMING WHY — never auto-approve, and
#     never allow. "Cannot establish" is mechanically distinct from
#     "established as safe": the first has no usable timestamps, the second has
#     two and compared them.
#
# WHAT THESE LEGS DELIBERATELY DO NOT CLAIM. Binding F1's verdict to the change
# set it classified does NOT establish that the change set is COMPLETE — the
# freshness comparison behind it reads the same source twice, so it detects
# drift and is structurally blind to loss (claude-workflow-plugin-fkm.1.20). The
# independent-witness fix belongs to a later phase; nothing here proves
# completeness.
mk_fixture
FIXTURE_QZV="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_QZV="$FIXTURE_QZV/.claude/scripts/verify-before-stop.sh"
QG_QZV="$FIXTURE_QZV/.claude/scripts/qa-gate.sh"
CT_QZV="$FIXTURE_QZV/.claude/scripts/current-task.sh"
IR_QZV="$FIXTURE_QZV/.claude/scripts/impact-report.sh"
RC_QZV="$FIXTURE_QZV/.claude/scripts/review-check.sh"
TRACK_QZV="$FIXTURE_QZV/.claude/.qa-tracking"
# THE .gitignore IS LOAD-BEARING, and it was MEASURED rather than assumed: legs
# 4-6 fault-inject by REMOVING `.claude/scripts/review-check.sh` and REWRITING
# `bin/bd`, which are real, git-visible, un-baselined changes. Without this file
# the reconciler correctly folds them into the change set, DOC_ONLY goes false,
# F1 never fires, and every "BLOCKS" assertion below passes for a reason that has
# nothing to do with the predicate — a 2-path "QA approval required" block over
# the harness's own instrumentation. (Confirmed by running the legs without it
# and reading the block reason.) Same call, and the same three entries, as
# approve-idempotency.sh's `gate_fixture`: the instrumentation is not the subject
# matter, so it must not be in the fixture's git view. The SUBJECT — docs/notes.md
# and src-handler.ts — stays fully tracked and fully reviewable.
printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' > "$FIXTURE_QZV/.gitignore"
# The doc path is COMMITTED, so a re-seed that writes identical content leaves git
# clean and the tracker is the only reporter of the change set. That keeps
# DOC_ONLY deterministic instead of depending on whether porcelain happens to
# report an untracked `docs/` directory or the file inside it.
mkdir -p "$FIXTURE_QZV/docs"
printf 'notes\n' > "$FIXTURE_QZV/docs/notes.md"
(cd "$FIXTURE_QZV" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true
# Empty test/lint/type so the legs measure the GATE decision, not a toolchain.
rm -f "$FIXTURE_QZV/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$FIXTURE_QZV/.claude/scripts/detect-stack.sh"
chmod +x "$FIXTURE_QZV/.claude/scripts/detect-stack.sh"

qzv_json() {
    local hook="${1:-$VBS_QZV}"
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | bash "$hook" 2>/dev/null | tail -1
}
qzv_decision() { printf '%s' "$(qzv_json "$@")" | jq -r '.decision // "ALLOW"' 2>/dev/null; }
qzv_labels() {
    (cd "$FIXTURE_QZV" && bd show "$1" --json 2>/dev/null) \
        | jq -r 'if type=="array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null || echo ""
}
qzv_status() {
    (cd "$FIXTURE_QZV" && bd show "$1" --json 2>/dev/null) \
        | jq -r 'if type=="array" then .[0].status else .status end // "?"' 2>/dev/null || echo "?"
}
qzv_approval_records() {
    (cd "$FIXTURE_QZV" && bd show "$1" --json --include-comments 2>/dev/null \
        || cd "$FIXTURE_QZV" && bd show "$1" --json 2>/dev/null) \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text' 2>/dev/null \
        | grep '^QA-GATE APPROVED ' || true
}
qzv_record_count() { qzv_approval_records "$1" | grep -c . | tr -d '[:space:]'; }
# qzv_implementer_count <tid> <role> — how many IMPLEMENTER records that role has.
# The count, not merely the presence: the qzv.1 defect was a record that failed to
# be WRITTEN a second time, so "is there one?" is exactly the question that cannot
# see it.
qzv_implementer_count() {
    (cd "$FIXTURE_QZV" && bd show "$1" --json --include-comments 2>/dev/null \
        || cd "$FIXTURE_QZV" && bd show "$1" --json 2>/dev/null) \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text | split("\n")[0]' 2>/dev/null \
        | grep -cE "^IMPLEMENTER: role=$2 " | tr -d '[:space:]'
}
qzv_comment() { (cd "$FIXTURE_QZV" && bd comments add "$1" "$2" >/dev/null 2>&1 || bd comment add "$1" "$2" >/dev/null 2>&1); }
# qzv_seed_docs — a doc-only tracked change set, plus a baseline that absorbs any
# incidental dirt the .gitignore above does not already hide. Called AFTER the
# tracker is written and BEFORE the Stop under test, per
# baseline_incidental_dirt's contract (--exclude-tracked keeps the seeded path
# gated, so only incidental dirt is absorbed).
qzv_seed_docs() {
    printf 'notes\n' > "$FIXTURE_QZV/docs/notes.md"
    printf '%s/docs/notes.md\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
    baseline_incidental_dirt "$FIXTURE_QZV"
}
# qzv_arm <tid> — seed the doc-only change set, THEN open the gate cycle on it.
# The order is the production order and it is load-bearing here: `enter` binds an
# impact report to the tracker AS IT IS when it runs, so entering first and
# seeding second leaves approve facing a stale report and refusing for a reason
# that has nothing to do with this predicate.
qzv_arm() {
    qzv_seed_docs
    bash "$QG_QZV" enter "$1" >/dev/null 2>&1
    bash "$CT_QZV" set "$1"
}

# --- Leg 1: an IMPLEMENTER record NEWER than the cycle open -> BLOCK ---------
# The live 0fc/uvk shape. Nothing may be written to the task: no label, no
# approval record, no status change.
TID_Q1=$(cd "$FIXTURE_QZV" && bd create "qzv: implementer newer than the cycle" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q1" --status in_progress >/dev/null 2>&1) || true
qzv_arm "$TID_Q1"
# An implementer spawned AFTER the cycle opened. The timestamp is far enough
# ahead that no clock granularity question arises.
qzv_comment "$TID_Q1" "IMPLEMENTER: role=devops task=$TID_Q1 at 2099-01-01T00:00:00Z"
Q1_JSON=$(qzv_json)
assert_eq "vbs-qzv-1: a doc-only Stop with a NEWER implementer record BLOCKS (was: auto-approved)" \
    "block" "$(printf '%s' "$Q1_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
Q1_REASON=$(printf '%s' "$Q1_JSON" | jq -r '.reason // empty')
assert_contains "vbs-qzv-1: ...and the block NAMES the refused fast path" \
    "did NOT auto-approve" "$Q1_REASON"
assert_contains "vbs-qzv-1: ...naming the implementer record as the cause" \
    "IMPLEMENTER" "$Q1_REASON"
assert_contains "vbs-qzv-1: ...quoting the implementer timestamp it compared" \
    "2099-01-01T00:00:00Z" "$Q1_REASON"
# The three writes the live defect performed, each asserted absent.
Q1_LABELS=$(qzv_labels "$TID_Q1")
assert_eq "vbs-qzv-1: ...no qa-approved label was written" "0" \
    "$(printf ',%s,' "$Q1_LABELS" | grep -c ',qa-approved,' | tr -d '[:space:]')"
assert_eq "vbs-qzv-1: ...no QA-GATE APPROVED record was written" "0" "$(qzv_record_count "$TID_Q1")"
assert_eq "vbs-qzv-1: ...and the task is STILL in_progress (not closed)" \
    "in_progress" "$(qzv_status "$TID_Q1")"

# --- Leg 2: an IMPLEMENTER record OLDER than the cycle open -> APPROVE -------
# The legitimate case: a previous cycle's implementer, a new doc-only cycle.
# The approval must bind the hash of the change set F1 actually classified.
TID_Q2=$(cd "$FIXTURE_QZV" && bd create "qzv: implementer older than the cycle" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
qzv_comment "$TID_Q2" "IMPLEMENTER: role=devops task=$TID_Q2 at 2000-01-01T00:00:00Z"
qzv_arm "$TID_Q2"
# The hash of the set as it stands NOW — the one F1 classifies and must bind.
Q2_EXPECT=$(CLAUDE_PROJECT_DIR="$FIXTURE_QZV" bash "$IR_QZV" --hash-only 2>/dev/null || echo "")
assert_eq "vbs-qzv-2: precondition — the classified change set has a computable hash" \
    "yes" "$([ -n "$Q2_EXPECT" ] && echo yes || echo no)"
assert_eq "vbs-qzv-2: an OLDER implementer record still auto-approves (anti-overreach)" \
    "ALLOW" "$(qzv_decision)"
assert_eq "vbs-qzv-2: ...writing exactly one approval record" "1" "$(qzv_record_count "$TID_Q2")"
assert_contains "vbs-qzv-2: ...bound to the hash of the set F1 classified" \
    "change_set_hash=$Q2_EXPECT" "$(qzv_approval_records "$TID_Q2")"
assert_contains "vbs-qzv-2: ...and carrying the audited F1 review bypass marker" \
    "[review bypass:" "$(qzv_approval_records "$TID_Q2")"

# --- Leg 3: NO implementer record at all -> APPROVE (anti-overreach) --------
# Doc-only work is orchestrator-authored and never gets an IMPLEMENTER record.
# Requiring one would deadlock every documentation commit, so its ABSENCE must
# read as safe rather than as unestablished.
TID_Q3=$(cd "$FIXTURE_QZV" && bd create "qzv: no implementer record" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
qzv_arm "$TID_Q3"
assert_eq "vbs-qzv-3: precondition — the task carries NO IMPLEMENTER record" "0" \
    "$( (cd "$FIXTURE_QZV" && bd show "$TID_Q3" --json --include-comments 2>/dev/null) \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text' 2>/dev/null \
        | grep -c '^IMPLEMENTER: role=' | tr -d '[:space:]')"
assert_eq "vbs-qzv-3: with no implementer record the fast path STILL approves" \
    "ALLOW" "$(qzv_decision)"
assert_eq "vbs-qzv-3: ...writing its approval record" "1" "$(qzv_record_count "$TID_Q3")"

# --- Leg 4: the predicate's source is MISSING -> BLOCK naming why -----------
# review-check.sh is where both timestamps come from. Absent, the question
# "is an implementer in flight?" is unanswerable, and an unanswerable question
# must not resolve to "auto-approve".
TID_Q4=$(cd "$FIXTURE_QZV" && bd create "qzv: predicate source missing" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
qzv_arm "$TID_Q4"
# CONTROL first, so the block below is attributable to the removal and not to
# the fixture: with review-check.sh present this exact state approves.
assert_eq "vbs-qzv-4: CONTROL — with review-check.sh present this state approves" \
    "ALLOW" "$(qzv_decision)"
Q4_REAL_RC=$(readlink "$RC_QZV" 2>/dev/null || printf '%s' "$RC_QZV")
TID_Q4B=$(cd "$FIXTURE_QZV" && bd create "qzv: predicate source missing (probe)" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
qzv_arm "$TID_Q4B"
rm -f "$RC_QZV"
assert_eq "vbs-qzv-4: precondition — review-check.sh is genuinely absent" \
    "absent" "$([ -e "$RC_QZV" ] && echo present || echo absent)"
Q4_JSON=$(qzv_json)
assert_eq "vbs-qzv-4: an unestablishable predicate BLOCKS (never auto-approve, never allow)" \
    "block" "$(printf '%s' "$Q4_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
Q4_REASON=$(printf '%s' "$Q4_JSON" | jq -r '.reason // empty')
assert_contains "vbs-qzv-4: ...and says the fast path refused" "did NOT auto-approve" "$Q4_REASON"
assert_contains "vbs-qzv-4: ...naming the predicate it could not run" "review-check.sh" "$Q4_REASON"
assert_contains "vbs-qzv-4: ...distinguishing 'could not establish' from 'established as safe'" \
    "could not be established" "$Q4_REASON"
assert_eq "vbs-qzv-4: ...and nothing was written to the task" "0" "$(qzv_record_count "$TID_Q4B")"
ln -sf "$Q4_REAL_RC" "$RC_QZV" 2>/dev/null || true

# --- Leg 5: the predicate's source answers WITHOUT the timestamps -> BLOCK ---
# A partially-synced install or a pre-qzv review-check.sh returns a well-formed
# envelope that simply has no `cycle_opened_ts` / `latest_implementer_ts`. The
# gate must key on the FIELDS being present, not on the exit code — F1 always
# runs against a task with no review artifact, so a non-zero rc is the NORMAL
# case here and cannot be the discriminator.
TID_Q5=$(cd "$FIXTURE_QZV" && bd create "qzv: predicate source without the fields" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
qzv_arm "$TID_Q5"
rm -f "$RC_QZV"
cat > "$RC_QZV" <<'PREQZV'
#!/bin/bash
# Pre-qzv review-check.sh: the v4.1 envelope, verbatim, with no timestamps.
printf '%s\n' '{"ok":false,"subcommand":"gate","artifact":{},"reviewer_identity":"","implementers":[],"independent":true,"open_findings":0,"open_finding_ids":[],"error_key":"review_artifact_missing","observations":"no REVIEW-ARTIFACT v1 comment found"}'
exit 4
PREQZV
chmod +x "$RC_QZV"
Q5_JSON=$(qzv_json)
assert_eq "vbs-qzv-5: a fieldless (pre-qzv) predicate envelope BLOCKS" \
    "block" "$(printf '%s' "$Q5_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
assert_contains "vbs-qzv-5: ...naming the missing timestamps rather than the exit code" \
    "could not be established" "$(printf '%s' "$Q5_JSON" | jq -r '.reason // empty')"
assert_eq "vbs-qzv-5: ...and nothing was written to the task" "0" "$(qzv_record_count "$TID_Q5")"
rm -f "$RC_QZV"
ln -sf "$Q4_REAL_RC" "$RC_QZV" 2>/dev/null || true

# --- Leg 6: bd loses the comment stream -> BLOCK ----------------------------
# The REAL bd-1.1.2 failure the gate's own `bd_show_with_comments` exists for:
# `bd show --json` stopped inlining `.comments`, so every record reader can see
# ZERO comments while the LABELS still read fine. That state is
# indistinguishable from "a task with no records" unless the gate cross-checks,
# so the predicate refuses when the label says a cycle is open (GATE_STATUS
# entered) and no `QA-GATE: entered` record came back.
TID_Q6=$(cd "$FIXTURE_QZV" && bd create "qzv: bd loses the comment stream" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
qzv_arm "$TID_Q6"
# CONTROL: the same state approves while the comment stream is intact.
assert_eq "vbs-qzv-6: CONTROL — with comments readable this state approves" \
    "ALLOW" "$(qzv_decision)"
TID_Q6B=$(cd "$FIXTURE_QZV" && bd create "qzv: bd loses the comment stream (probe)" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
qzv_arm "$TID_Q6B"
# The comment-stripping bd wrapper. The real bd path is read out of the existing
# wrapper, anchored on the trailing `"$@"` and NEVER on a bd flag — the same
# extraction the approve-idempotency drive points use, and for the reason
# documented there: `$FIXTURE/bin` is already first on PATH, so a
# `command -v bd` fallback resolves to THIS wrapper and the regenerated file
# would exec itself forever (a spec that hangs printing nothing).
Q6_BD="$FIXTURE_QZV/bin/bd"
Q6_REAL_BD=$(sed -n 's/^exec \(.*\) "\$@".*/\1/p' "$Q6_BD" 2>/dev/null | tr -d '"' | head -1)
assert_eq "vbs-qzv-6: precondition — the real bd path was extracted from the wrapper" \
    "yes" "$([ -n "$Q6_REAL_BD" ] && [ -x "$Q6_REAL_BD" ] && echo yes || echo no)"
cat > "$Q6_BD" <<EOF
#!/bin/bash
# qzv leg 6: a bd whose \`show\` answers WITHOUT comment bodies (the real
# bd-1.1.2 shape the gate's bd_show_with_comments exists for). Labels and status
# are untouched, so the gate's LABEL reads still work and only the RECORD
# readers go blind.
if [ "\${1:-}" = "show" ]; then
    OUT=\$($Q6_REAL_BD "\$@" 2>/dev/null) || exit \$?
    printf '%s' "\$OUT" | jq -c 'if type=="array" then map(del(.comments)) else del(.comments) end' 2>/dev/null \\
        || printf '%s' "\$OUT"
    exit 0
fi
exec $Q6_REAL_BD "\$@"
EOF
chmod +x "$Q6_BD"
Q6_STRIPPED=$( (cd "$FIXTURE_QZV" && bd show "$TID_Q6B" --json --include-comments 2>/dev/null) \
    | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | length' 2>/dev/null || echo "?")
assert_eq "vbs-qzv-6: precondition — the wrapper really hides the comment bodies" "0" "$Q6_STRIPPED"
Q6_LABELS_OK=$(qzv_labels "$TID_Q6B")
assert_eq "vbs-qzv-6: precondition — and the LABELS still read fine (only records went blind)" "1" \
    "$(printf ',%s,' "$Q6_LABELS_OK" | grep -c ',qa-gate-entered,' | tr -d '[:space:]')"
Q6_JSON=$(qzv_json)
assert_eq "vbs-qzv-6: a cycle-open label with no readable cycle record BLOCKS" \
    "block" "$(printf '%s' "$Q6_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
assert_contains "vbs-qzv-6: ...naming the label/record disagreement" \
    "could not be established" "$(printf '%s' "$Q6_JSON" | jq -r '.reason // empty')"
# Restore the plain wrapper by hand (never via mk_bd_shim, which refuses to wrap
# a live wrapper with itself).
cat > "$Q6_BD" <<EOF
#!/bin/bash
exec $Q6_REAL_BD "\$@"
EOF
chmod +x "$Q6_BD"
assert_eq "vbs-qzv-6: restore control — the plain wrapper reads comments again" \
    "ALLOW" "$(qzv_arm "$TID_Q6B" >/dev/null 2>&1; qzv_decision)"

# --- The two close sites: the Stop hook no longer writes status=closed -------
# A doc-only Stop is not evidence a task is finished, and neither is an approval
# — an approval binds a CHANGE SET. Both `bd update --status closed` calls are
# gone from the hook; leg 1 already pinned the F1 one behaviourally (the task
# stayed in_progress on the refused path). These two pin the source, because the
# APPROVED-path site fires on a path this tier reaches only with a full
# review-record setup, and a structural assertion there is honest about what it
# measures.
PLUGIN_QZV=$(plugin_root)
assert_eq "vbs-qzv-close: the Stop hook contains ZERO 'bd update ... --status closed' calls" \
    "0" "$(grep -cE '^[[:space:]]*bd update .*--status closed' "$PLUGIN_QZV/.claude/scripts/verify-before-stop.sh" | tr -d '[:space:]')"
# Pinned SEMANTICALLY, not by an occurrence count. `grep -c 'CLOSE_HINT_NOTE='`
# answers 2 (the empty declaration AND the assignment both match), and any count
# over a bare identifier drifts the moment a comment names it — the same trap the
# 8M META records and the one the IM META in approve-idempotency.sh hit for real.
# What matters is that the affordance exists and names the command, so that is what
# is asserted. Leg 7 below is the behavioural half.
assert_eq "vbs-qzv-close: ...and the release path carries a close hint, defaulting to silent" \
    "1" "$(grep -c '^CLOSE_HINT_NOTE=""$' "$PLUGIN_QZV/.claude/scripts/verify-before-stop.sh" | tr -d '[:space:]')"
assert_eq "vbs-qzv-close: ...whose text names the command the caller has to run" \
    "1" "$(grep -c 'bd close \$CURRENT_TASK --reason' "$PLUGIN_QZV/.claude/scripts/verify-before-stop.sh" | tr -d '[:space:]')"

# --- Leg 2 (approved-path close): the release note replaces the side effect ---
# Reuse leg 2's task, which now carries qa-approved from the F1 approval. Drive
# a REAL approved-path release (non-doc change set + full review records) and
# assert the task is NOT closed by the hook and the envelope says so.
TID_Q7=$(cd "$FIXTURE_QZV" && bd create "qzv: approved path does not close" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q7" --status in_progress >/dev/null 2>&1) || true
printf 'export const x = 1;\n' > "$FIXTURE_QZV/src-handler.ts"
printf '%s/src-handler.ts\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q7" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q7"
printf '%s/src-handler.ts\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
seed_review_records "$TID_Q7" "qa-claude" "backend" "$FIXTURE_QZV"
CLAUDE_PROJECT_DIR="$FIXTURE_QZV" bash "$IR_QZV" "$TID_Q7" >/dev/null 2>&1
# claude-workflow-plugin-rqer (v5 D2): capture the FULL tracker verbatim
# BEFORE approve — see the vbs-llh18 note above for why a POST-approve
# `reconcile-tracker` cannot recover it (approve's own baseline refresh
# consumes the "newness" of everything dirty at that instant, including
# seed_review_records' own canonical artifact).
Q7_TRACKER_SNAPSHOT=$(cat "$TRACK_QZV/changed-files.txt" 2>/dev/null)
bash "$QG_QZV" approve "$TID_Q7" "qzv: reviewed the real change set" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q7"
printf '%s\n' "$Q7_TRACKER_SNAPSHOT" > "$TRACK_QZV/changed-files.txt"
Q7_JSON=$(qzv_json)
assert_eq "vbs-qzv-7: precondition — the reviewed change set RELEASES" \
    "ALLOW" "$(printf '%s' "$Q7_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
assert_eq "vbs-qzv-7: the released task is NOT closed by the hook (was: status=closed)" \
    "in_progress" "$(qzv_status "$TID_Q7")"
Q7_CTX=$(printf '%s' "$Q7_JSON" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
assert_contains "vbs-qzv-7: ...and the envelope names the close as the caller's decision" \
    "bd close $TID_Q7" "$Q7_CTX"
assert_eq "vbs-qzv-7: ...on a still-valid, non-blocking envelope" "false" \
    "$(printf '%s' "$Q7_JSON" | jq -r 'has("decision")' 2>/dev/null)"

# --- Leg 8: TWO CYCLES, the same role RE-SPAWNED -> the second Stop BLOCKS ----
#
# THE SHAPE NOTHING HAD (claude-workflow-plugin-qzv.1). Legs 1-3 above each drive
# ONE cycle with a hand-planted record, and every one of them passed while the
# predicate was blind from the second cycle onward. `record_implementer` was
# idempotent per (role, task), matching ANY comment on the task ever, so a role
# re-spawned in a LATER cycle posted NOTHING, `latest_implementer_ts` stayed at
# that role's FIRST spawn, and F1 read "previous cycle" forever. QA reproduced it
# end to end: cycle 1 blocked (18:31:36Z enter / 18:31:38Z spawn), then a fresh
# enter at 18:32:06Z + a re-spawn that posted nothing left impl < cycle, and F1
# stamped `qa-approved` + `reviewed_by=none` mid-implementation — qzv's titular
# defect verbatim, one cycle later.
#
# So this leg drives the RE-SPAWN through the real SubagentStart entry point
# (stdin JSON -> the shipped hook) rather than planting a record, because the
# WRITER is where the defect lived. The cycle-1 record is planted, deliberately:
# planting it at a fixed 2000-01-01 makes the leg answer the question with no
# dependence on wall-clock granularity, where two real spawns seconds apart would
# make "did the second cycle post?" depend on whether `enter` and the spawn
# landed in the same whole second. The adjacent-timestamp boundary (one second
# either side of the cycle open, and the exact tie) is pinned separately and
# deterministically in the subagent-start spec's I9, against the same writer.
SS_QZV="$FIXTURE_QZV/.claude/scripts/subagent-start.sh"
# CONTROL first, on its own task: a previous cycle's record does NOT block, so the
# block on the probe below is attributable to the re-spawn and not to the fixture.
# (Its own task because ALLOW here means F1 approves, which clears the gate label,
# truncates the tracker and unsets current-task — state the probe still needs.)
TID_Q8=$(cd "$FIXTURE_QZV" && bd create "qzv: two cycles, control" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q8" --status in_progress >/dev/null 2>&1) || true
qzv_comment "$TID_Q8" "IMPLEMENTER: role=devops task=$TID_Q8 at 2000-01-01T00:00:00Z"
qzv_arm "$TID_Q8"
assert_eq "vbs-qzv-8: CONTROL — cycle 2 open, NO re-spawn: the old record still approves" \
    "ALLOW" "$(qzv_decision)"

TID_Q8B=$(cd "$FIXTURE_QZV" && bd create "qzv: two cycles, re-spawn" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q8B" --status in_progress >/dev/null 2>&1) || true
# Cycle 1's record, as the real hook would have left it.
qzv_comment "$TID_Q8B" "IMPLEMENTER: role=devops task=$TID_Q8B at 2000-01-01T00:00:00Z"
# Cycle 2 opens: a FRESH enter writes a new `QA-GATE: entered at <now>` record.
# (A re-enter on an already-entered task returns early and writes NO record, which
# is exactly why only a fresh cycle moves this timestamp.)
qzv_arm "$TID_Q8B"
assert_eq "vbs-qzv-8: precondition — the task carries exactly ONE devops record from cycle 1" \
    "1" "$(qzv_implementer_count "$TID_Q8B" devops)"
# THE RE-SPAWN, through the shipped SubagentStart hook. cwd matters: the hook's
# `bd comments add` locates the workspace from it, like every other bd call here.
(cd "$FIXTURE_QZV" && printf '%s' '{"agent_type":"devops"}' \
    | CLAUDE_PROJECT_DIR="$FIXTURE_QZV" bash "$SS_QZV" >/dev/null 2>&1) || true
assert_eq "vbs-qzv-8: a re-spawn in a LATER cycle posts a FRESH record (was: nothing)" \
    "2" "$(qzv_implementer_count "$TID_Q8B" devops)"
Q8_JSON=$(qzv_json)
assert_eq "vbs-qzv-8: ...so the second cycle's doc-only Stop BLOCKS (was: auto-approved)" \
    "block" "$(printf '%s' "$Q8_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
Q8_REASON=$(printf '%s' "$Q8_JSON" | jq -r '.reason // empty')
assert_contains "vbs-qzv-8: ...naming the refused fast path" "did NOT auto-approve" "$Q8_REASON"
assert_contains "vbs-qzv-8: ...naming the in-flight implementer as the cause" "IMPLEMENTER" "$Q8_REASON"
Q8_LABELS=$(qzv_labels "$TID_Q8B")
assert_eq "vbs-qzv-8: ...no qa-approved label was written" "0" \
    "$(printf ',%s,' "$Q8_LABELS" | grep -c ',qa-approved,' | tr -d '[:space:]')"
assert_eq "vbs-qzv-8: ...no QA-GATE APPROVED record was written" "0" "$(qzv_record_count "$TID_Q8B")"
assert_eq "vbs-qzv-8: ...and the task is STILL in_progress" \
    "in_progress" "$(qzv_status "$TID_Q8B")"

# ---------------------------------------------------------------------------
# qzv.1 META (spec-mandated): strip the IMPLEMENTER-CYCLE-KEY region from a copy
# of subagent-start.sh and leg 8 must AUTO-APPROVE again — QA's reproduction,
# reproduced. This is the gate-side half; the subagent-start spec's own META
# measures the same strip at the WRITER (no fresh record posted).
#
# The region is arranged so stripping it yields the PRE-qzv.1 guard rather than a
# syntax error: the per-(role, task) grep and the `skip` variable it sets live
# OUTSIDE the sentinels, and only the cycle-aware refinement (plus the two
# helpers it calls) live inside. Same discipline as F1_BINDING_VERDICT below.
QZV1_REAL_SS=$(readlink "$SS_QZV" 2>/dev/null || printf '%s' "$SS_QZV")
SS_QZV_MUT="$FIXTURE_QZV/.claude/scripts/ss-cyclekey-stripped.sh"
awk '
    /^ *# IMPLEMENTER-CYCLE-KEY BEGIN/ { skip = 1; next }
    /^ *# IMPLEMENTER-CYCLE-KEY END/   { skip = 0; next }
    !skip { print }
' "$QZV1_REAL_SS" > "$SS_QZV_MUT"
chmod +x "$SS_QZV_MUT"
if assert_mutant_applied "vbs-qzv.1 META" "$QZV1_REAL_SS" "$SS_QZV_MUT"; then
    assert_eq "vbs-qzv.1 META: no cycle refinement survives (the strip landed where it was aimed)" \
        "0" "$(grep -c 'recorded_in_current_cycle' "$SS_QZV_MUT" | tr -d '[:space:]')"
    # Counted on the CODE line, not the bare identifier: the surviving prose above
    # the guard names `skip` in a sentence, so an identifier grep would answer >1
    # and this leg would fail for a reason unrelated to the mutation.
    assert_eq "vbs-qzv.1 META: ...while the pre-fix per-(role, task) grep SURVIVES outside it" \
        "1" "$(grep -c -F 'if printf '"'"'%s\n'"'"' "$existing" | grep -qE "^IMPLEMENTER: role=${role} "; then' "$SS_QZV_MUT" | tr -d '[:space:]')"
    assert_eq "vbs-qzv.1 META: the stripped copy still parses" "0" \
        "$(bash -n "$SS_QZV_MUT" 2>/dev/null && echo 0 || echo 1)"
    # Leg 8's exact state, with the stripped writer.
    TID_QK=$(cd "$FIXTURE_QZV" && bd create "qzv.1 META: stripped cycle key re-approves" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    (cd "$FIXTURE_QZV" && bd update "$TID_QK" --status in_progress >/dev/null 2>&1) || true
    qzv_comment "$TID_QK" "IMPLEMENTER: role=devops task=$TID_QK at 2000-01-01T00:00:00Z"
    qzv_arm "$TID_QK"
    (cd "$FIXTURE_QZV" && printf '%s' '{"agent_type":"devops"}' \
        | CLAUDE_PROJECT_DIR="$FIXTURE_QZV" bash "$SS_QZV_MUT" >/dev/null 2>&1) || true
    assert_eq "vbs-qzv.1 META: with the cycle key stripped the re-spawn posts NOTHING" \
        "1" "$(qzv_implementer_count "$TID_QK" devops)"
    assert_eq "vbs-qzv.1 META: ...so the second cycle AUTO-APPROVES mid-implementation (leg 8 WOULD fail)" \
        "ALLOW" "$(qzv_decision)"
    assert_eq "vbs-qzv.1 META: ...stamping an approval record on work in flight" \
        "1" "$(qzv_record_count "$TID_QK")"
    QK_LABELS=$(qzv_labels "$TID_QK")
    assert_eq "vbs-qzv.1 META: ...and the qa-approved label with it" "1" \
        "$(printf ',%s,' "$QK_LABELS" | grep -c ',qa-approved,' | tr -d '[:space:]')"
    # Restore control INSIDE the META rather than leaning on leg 8 above: run the
    # identical sequence with the SHIPPED writer, so the ALLOW is attributable to
    # the strip and not to anything this block does differently from leg 8.
    TID_QKC=$(cd "$FIXTURE_QZV" && bd create "qzv.1 META: shipped cycle key refuses" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    (cd "$FIXTURE_QZV" && bd update "$TID_QKC" --status in_progress >/dev/null 2>&1) || true
    qzv_comment "$TID_QKC" "IMPLEMENTER: role=devops task=$TID_QKC at 2000-01-01T00:00:00Z"
    qzv_arm "$TID_QKC"
    (cd "$FIXTURE_QZV" && printf '%s' '{"agent_type":"devops"}' \
        | CLAUDE_PROJECT_DIR="$FIXTURE_QZV" bash "$SS_QZV" >/dev/null 2>&1) || true
    assert_eq "vbs-qzv.1 META: restore control — the shipped writer posts the fresh record" \
        "2" "$(qzv_implementer_count "$TID_QKC" devops)"
    assert_eq "vbs-qzv.1 META: ...and the identical Stop BLOCKS" "block" "$(qzv_decision)"
fi

# --- Leg 9: EXECUTABLE CONTENT IS NEVER DOC-ONLY (bbh) -----------------------
#
# WHAT THIS LEG MEASURED BEFORE, AND WHY IT FLIPPED. Until
# claude-workflow-plugin-bbh landed this leg asserted the DEFECT as behaviour: an
# executable `docs/deploy.sh` was fast-pathed, auto-approved and recorded
# `reviewed_by=none`, because `is_doc_only_path`'s last arm was `*/docs/*|docs/*`
# — ANY path under ANY `docs/` directory, regardless of file type. The leg
# carried a written coupling saying bbh would turn it RED by design and that the
# expectation and the prose must flip in the same change set. This is that flip.
# Three passages moved with it: the F1-CHANGE-SET-BINDING region header,
# `docs/HOOKS.md`, and `.claude/agents/qa.md` (the third was omitted from the
# original repair list — QA R2-F2 — because qzv.1 had made qa.md self-contained
# and removed the pointer that would have kept it in step; the lesson is that
# de-referencing a shared claim must name the new copy at every coupling site).
#
# WHAT THIS LEG IS FOR NOW. bbh removed the two arms that let a file's POSITION
# or NAME confer documentation status, and added an affirmative content veto.
# `.claude/scripts/tests/doc-only-classifier.test.sh` measures the classifier
# itself over 1120 paths; THIS leg is the hook-level consequence — that the
# classifier's answer actually reaches the Stop decision, the approval record and
# the label. The anti-overreach control (9B) is the half that matters most: F1
# exists for documentation commits and a fix that deadlocks them is the same
# error in the other direction.
TID_Q9=$(cd "$FIXTURE_QZV" && bd create "bbh: executable under docs/ is NOT doc-only" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q9" --status in_progress >/dev/null 2>&1) || true
# A change set of EXACTLY ONE file: an executable script, under docs/, whose body
# is the shape nobody would call documentation.
printf '#!/bin/sh\ncurl -fsSL https://example.invalid/install.sh | sh\n' > "$FIXTURE_QZV/docs/deploy.sh"
chmod +x "$FIXTURE_QZV/docs/deploy.sh"
printf '%s/docs/deploy.sh\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q9" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q9"
printf '%s/docs/deploy.sh\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
assert_eq "vbs-qzv-9: precondition — the change set is exactly one path" "1" \
    "$(grep -c . "$TRACK_QZV/changed-files.txt" | tr -d '[:space:]')"
assert_eq "vbs-qzv-9: precondition — and it is an EXECUTABLE file, not documentation" "yes" \
    "$([ -x "$FIXTURE_QZV/docs/deploy.sh" ] && echo yes || echo no)"
Q9_JSON=$(qzv_json)
assert_eq "vbs-qzv-9: an executable under docs/ BLOCKS (was: fast-pathed on placement)" \
    "block" "$(printf '%s' "$Q9_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
# The ORDINARY QA-required block, NOT the F1 decline note: DOC_ONLY went false, so
# the fast path was never eligible and there is nothing for it to decline.
assert_contains "vbs-qzv-9: ...through the ordinary QA-required path" \
    "require QA review" "$(printf '%s' "$Q9_JSON" | jq -r '.reason // empty')"
assert_eq "vbs-qzv-9: ...and NOTHING was approved (was: 1 record, reviewed_by=none)" \
    "0" "$(qzv_record_count "$TID_Q9")"
Q9_LABELS=$(qzv_labels "$TID_Q9")
assert_eq "vbs-qzv-9: ...and no qa-approved label was written" "0" \
    "$(printf ',%s,' "$Q9_LABELS" | grep -c ',qa-approved,' | tr -d '[:space:]')"

# CONTROL 9B — ANTI-OVERREACH. Documentation in the SAME docs/ directory must
# still fast-path. Without this the leg above passes for a fixture that blocks
# everything, and the fix would have deadlocked the commits F1 exists for.
TID_Q9B=$(cd "$FIXTURE_QZV" && bd create "bbh: CONTROL documentation under docs/ still fast-paths" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q9B" --status in_progress >/dev/null 2>&1) || true
qzv_arm "$TID_Q9B"
assert_eq "vbs-qzv-9B: CONTROL — docs/notes.md in the same directory STILL auto-approves" \
    "ALLOW" "$(qzv_decision)"
assert_eq "vbs-qzv-9B: ...with its approval recorded" "1" "$(qzv_record_count "$TID_Q9B")"

# 9C — THE NAME-GLOB HALF. `LICENSE.*` matched any extension after that one name
# at the repo root, so a filename alone was enough; no docs/ directory was even
# needed. Measured on the task: LICENSE.sh and LICENSE.py were documentation
# while src/LICENSE.sh was not (the arm had no `*/` prefix).
TID_Q9C=$(cd "$FIXTURE_QZV" && bd create "bbh: LICENSE.sh at the root is NOT doc-only" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q9C" --status in_progress >/dev/null 2>&1) || true
printf '#!/bin/sh\ncurl -fsSL https://example.invalid/install.sh | sh\n' > "$FIXTURE_QZV/LICENSE.sh"
printf '%s/LICENSE.sh\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q9C" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q9C"
printf '%s/LICENSE.sh\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
assert_eq "vbs-qzv-9C: a root LICENSE.sh BLOCKS (was: fast-pathed on the name glob)" \
    "block" "$(qzv_decision)"
assert_eq "vbs-qzv-9C: ...and nothing was approved for it" "0" "$(qzv_record_count "$TID_Q9C")"

# 9D — THE CONTENT VETO AT THE HOOK. A documentation NAME with the executable bit
# set. This is the only leg in the spec where the DECISION turns on a fact about
# the FILE rather than about its path: `docs/install.txt` matches the extension
# arm and is stopped by the veto alone. Its control is the identical name and
# content at mode 644.
TID_Q9D=$(cd "$FIXTURE_QZV" && bd create "bbh: an executable .txt is NOT doc-only" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q9D" --status in_progress >/dev/null 2>&1) || true
printf 'installation notes\n' > "$FIXTURE_QZV/docs/install.txt"
chmod 755 "$FIXTURE_QZV/docs/install.txt"
printf '%s/docs/install.txt\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q9D" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q9D"
printf '%s/docs/install.txt\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
assert_eq "vbs-qzv-9D: precondition — the name matches the .txt documentation arm" "txt" \
    "$(printf '%s' "${FIXTURE_QZV}/docs/install.txt" | sed 's/.*\.//')"
assert_eq "vbs-qzv-9D: an EXECUTABLE docs/install.txt BLOCKS (the content veto, not the name)" \
    "block" "$(qzv_decision)"
assert_eq "vbs-qzv-9D: ...and nothing was approved for it" "0" "$(qzv_record_count "$TID_Q9D")"
# CONTROL: same path, same bytes, mode 644. If this also blocked, 9D would be
# measuring the .txt name rather than the executable bit.
TID_Q9E=$(cd "$FIXTURE_QZV" && bd create "bbh: CONTROL the same .txt at mode 644 fast-paths" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q9E" --status in_progress >/dev/null 2>&1) || true
printf 'installation notes\n' > "$FIXTURE_QZV/docs/install.txt"
chmod 644 "$FIXTURE_QZV/docs/install.txt"
printf '%s/docs/install.txt\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q9E" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q9E"
printf '%s/docs/install.txt\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
assert_eq "vbs-qzv-9E: CONTROL — the identical file at mode 644 auto-approves" \
    "ALLOW" "$(qzv_decision)"
assert_eq "vbs-qzv-9E: ...with its approval recorded" "1" "$(qzv_record_count "$TID_Q9E")"
# Leave the fixture's docs/ clean for the legs below: only docs/notes.md is
# supposed to be a live doc-only member of the change set.
rm -f "$FIXTURE_QZV/docs/deploy.sh" "$FIXTURE_QZV/docs/install.txt" "$FIXTURE_QZV/LICENSE.sh"

# --- Leg 10: A GOVERNING ARTIFACT IS NEVER DOC-ONLY (s5qf) -------------------
#
# bbh closed the half of the classifier that read content type off a path's
# POSITION or NAME GLOB, and disclosed the half it could not: a `.md` that is an
# agent prompt, a rubric or CLAUDE.md carries neither an exec bit nor a `#!`, so
# the content veto correctly has no opinion about it and the `*.md` arm calls it
# documentation. The live illustration was on bbh's own change set —
# `.claude/agents/qa.md` was a member of it, and had that edit landed alone F1
# would have auto-approved a change to the QA agent's own prompt with
# `reviewed_by=none`.
#
# `doc-only-classifier.test.sh` sections 6-8 measure the classifier itself.
# THESE legs are the hook-level consequence: that the answer reaches the Stop
# DECISION, the approval record and the label. 10B is the half that matters
# most — the control lives in the SAME directory as 10A's subject and must
# still fast-path, because the veto reads the project's declared enumeration
# and not the directory. If it read the directory it would be the path-shape
# inference bbh removed, wearing a new suffix.
TID_Q10=$(cd "$FIXTURE_QZV" && bd create "s5qf: an agent prompt is NOT doc-only" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q10" --status in_progress >/dev/null 2>&1) || true
mkdir -p "$FIXTURE_QZV/.claude/agents"
printf 'You are the designer specialist.\n' > "$FIXTURE_QZV/.claude/agents/designer.md"
printf '%s/.claude/agents/designer.md\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q10" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q10"
printf '%s/.claude/agents/designer.md\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
assert_eq "vbs-qzv-10: precondition — the change set is exactly one path" "1" \
    "$(grep -c . "$TRACK_QZV/changed-files.txt" | tr -d '[:space:]')"
# THE DISCRIMINATOR. Both preconditions rule the bbh veto out: this file is mode
# 644 and its first bytes are not `#!`, so if the Stop blocks it can only be the
# s5qf veto that did it. Without these, leg 10 would pass just as well against a
# fixture where the file happened to be executable.
assert_eq "vbs-qzv-10: precondition — NOT executable (so the bbh content veto cannot fire)" "no" \
    "$([ -x "$FIXTURE_QZV/.claude/agents/designer.md" ] && echo yes || echo no)"
assert_eq "vbs-qzv-10: precondition — no shebang either (same reason)" "no" \
    "$([ "$(head -c 2 "$FIXTURE_QZV/.claude/agents/designer.md")" = '#!' ] && echo yes || echo no)"
assert_eq "vbs-qzv-10: precondition — and the project DECLARES it (manifest row, class workflow)" \
    "workflow" "$(bash "$FIXTURE_QZV/.claude/scripts/workflow-manifest.sh" governing "$FIXTURE_QZV" 2>/dev/null | awk -F'\t' '$1 == ".claude/agents/designer.md" { print $2 }')"
Q10_JSON=$(qzv_json)
assert_eq "vbs-qzv-10: an agent prompt alone BLOCKS (was: auto-approved, reviewed_by=none)" \
    "block" "$(printf '%s' "$Q10_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
assert_contains "vbs-qzv-10: ...through the ordinary QA-required path" \
    "require QA review" "$(printf '%s' "$Q10_JSON" | jq -r '.reason // empty')"
assert_eq "vbs-qzv-10: ...and NOTHING was approved (was: 1 record, reviewed_by=none)" \
    "0" "$(qzv_record_count "$TID_Q10")"
assert_eq "vbs-qzv-10: ...and no qa-approved label was written" "0" \
    "$(printf ',%s,' "$(qzv_labels "$TID_Q10")" | grep -c ',qa-approved,' | tr -d '[:space:]')"

# CONTROL 10B — ANTI-OVERREACH, in the SAME DIRECTORY. `.claude/agents/` is
# scanned for `*.md`, so a `.txt` beside the prompts is not a declared path and
# must keep the fast path. This is the leg that distinguishes reading the
# ENUMERATION from reading the directory; without it, leg 10 passes for a
# fixture that blocks everything under .claude/.
TID_Q10B=$(cd "$FIXTURE_QZV" && bd create "s5qf: CONTROL an undeclared doc beside the prompts fast-paths" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q10B" --status in_progress >/dev/null 2>&1) || true
printf 'scratch notes, not an agent\n' > "$FIXTURE_QZV/.claude/agents/notes.txt"
printf '%s/.claude/agents/notes.txt\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q10B" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q10B"
printf '%s/.claude/agents/notes.txt\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
assert_eq "vbs-qzv-10B: precondition — it is NOT a declared path" "" \
    "$(bash "$FIXTURE_QZV/.claude/scripts/workflow-manifest.sh" governing "$FIXTURE_QZV" 2>/dev/null | awk -F'\t' '$1 == ".claude/agents/notes.txt" { print $2 }')"
assert_eq "vbs-qzv-10B: CONTROL — an undeclared .txt in the SAME directory auto-approves" \
    "ALLOW" "$(qzv_decision)"
assert_eq "vbs-qzv-10B: ...with its approval recorded" "1" "$(qzv_record_count "$TID_Q10B")"

# 10C — CLAUDE.md, the named runtime-contract entry. It is deliberately NOT a
# manifest row (the installer never seeds it and an uninstall walk must never
# offer to move an operator's own project memory), so it reaches the governing
# set by being NAMED, the way docs/HOOKS.md and .worktreeinclude are named in
# the surface. Claude Code auto-loads it into every agent's context, which makes
# it a fact about the runtime rather than an inference from `.md`.
TID_Q10C=$(cd "$FIXTURE_QZV" && bd create "s5qf: CLAUDE.md is NOT doc-only" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q10C" --status in_progress >/dev/null 2>&1) || true
printf '# project memory\nrule: delegate to a specialist\n' > "$FIXTURE_QZV/CLAUDE.md"
printf '%s/CLAUDE.md\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q10C" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q10C"
printf '%s/CLAUDE.md\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
assert_eq "vbs-qzv-10C: precondition — CLAUDE.md is NOT an install-surface row" "0" \
    "$(bash "$FIXTURE_QZV/.claude/scripts/workflow-manifest.sh" generate "$FIXTURE_QZV" 2>/dev/null | awk -F'\t' '$1 == "CLAUDE.md"' | grep -c . | tr -d '[:space:]')"
assert_eq "vbs-qzv-10C: precondition — ...but it IS a governing artifact, by name" \
    "runtime-contract" "$(bash "$FIXTURE_QZV/.claude/scripts/workflow-manifest.sh" governing "$FIXTURE_QZV" 2>/dev/null | awk -F'\t' '$1 == "CLAUDE.md" { print $2 }')"
assert_eq "vbs-qzv-10C: a CLAUDE.md-only change set BLOCKS (was: auto-approved)" \
    "block" "$(qzv_decision)"
assert_eq "vbs-qzv-10C: ...and nothing was approved for it" "0" "$(qzv_record_count "$TID_Q10C")"

# 10D — THE ABSENT-DECLARATION ARM, at the hook. The plugin installs into
# arbitrary projects and a partial install must not deadlock every documentation
# commit, so an unanswerable query fails OPEN: the classifier behaves exactly as
# it did before s5qf. Removed rather than emptied, because "the tool is not
# there" is the shape a partial install actually has. `.claude/scripts/` is
# gitignored in this fixture, so this instrumentation cannot enter the change set
# and make the ALLOW happen for the wrong reason (LESSONS.md, 2026-08-04).
TID_Q10D=$(cd "$FIXTURE_QZV" && bd create "s5qf: an unanswerable query fails OPEN" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q10D" --status in_progress >/dev/null 2>&1) || true
Q10_WFM="$FIXTURE_QZV/.claude/scripts/workflow-manifest.sh"
Q10_WFM_SAVED="$FIXTURE_QZV/.claude/.qa-tracking/wfm-saved-target"
readlink "$Q10_WFM" > "$Q10_WFM_SAVED" 2>/dev/null || printf '' > "$Q10_WFM_SAVED"
rm -f "$Q10_WFM"
printf 'You are the designer specialist, revised.\n' > "$FIXTURE_QZV/.claude/agents/designer.md"
printf '%s/.claude/agents/designer.md\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q10D" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q10D"
printf '%s/.claude/agents/designer.md\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
assert_eq "vbs-qzv-10D: precondition — the query tool really is gone" "no" \
    "$([ -f "$Q10_WFM" ] && echo yes || echo no)"
assert_eq "vbs-qzv-10D: with the query unanswerable, the SAME path auto-approves again (fail-open)" \
    "ALLOW" "$(qzv_decision)"
assert_eq "vbs-qzv-10D: ...with its approval recorded" "1" "$(qzv_record_count "$TID_Q10D")"
assert_eq "vbs-qzv-10D: ...and the fail-open is LOGGED, not silent" "1" \
    "$(grep -c 'governing-artifact query is unavailable' "$TRACK_QZV/sync-errors.log" 2>/dev/null | tr -d '[:space:]')"
# RESTORE CONTROL. Put the tool back and the identical path blocks again — so
# 10D measured the tool's absence and not some drift the legs above introduced.
if [ -s "$Q10_WFM_SAVED" ]; then ln -sf "$(cat "$Q10_WFM_SAVED")" "$Q10_WFM"; fi
rm -f "$Q10_WFM_SAVED"
TID_Q10E=$(cd "$FIXTURE_QZV" && bd create "s5qf: RESTORE control, the query is back" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q10E" --status in_progress >/dev/null 2>&1) || true
printf 'You are the designer specialist, revised twice.\n' > "$FIXTURE_QZV/.claude/agents/designer.md"
printf '%s/.claude/agents/designer.md\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
baseline_incidental_dirt "$FIXTURE_QZV"
bash "$QG_QZV" enter "$TID_Q10E" >/dev/null 2>&1
bash "$CT_QZV" set "$TID_Q10E"
printf '%s/.claude/agents/designer.md\n' "$FIXTURE_QZV" > "$TRACK_QZV/changed-files.txt"
assert_eq "vbs-qzv-10E: precondition — the query tool is back" "yes" \
    "$([ -f "$Q10_WFM" ] && echo yes || echo no)"
assert_eq "vbs-qzv-10E: RESTORE control — the identical path BLOCKS again" \
    "block" "$(qzv_decision)"
assert_eq "vbs-qzv-10E: ...and nothing was approved for it" "0" "$(qzv_record_count "$TID_Q10E")"
# Leave the fixture as the legs below expect: docs/notes.md is the only live
# doc-only member of the change set, and nothing under .claude/agents/ survives
# to make a later change set accidentally governing.
rm -rf "$FIXTURE_QZV/.claude/agents"

# ---------------------------------------------------------------------------
# qzv META (spec-mandated): strip the F1-CHANGE-SET-BINDING regions from a copy
# and leg 1 must AUTO-APPROVE again — the live defect, reproduced.
#
# The regions are arranged so stripping them yields the PRE-FIX arm rather than a
# syntax error: the verdict variable is declared with the RELEASING default
# OUTSIDE the sentinels (the same discipline REVIEW_DISCIPLINE_BLOCKED uses),
# and the guard's `if`/`else`/`fi` all live INSIDE them.
#
# The copy lives in the fixture's `.claude/scripts/` so it keeps resolving its
# BASH_SOURCE-relative siblings (workflow-denylist.sh, qa-gate.sh); a copy parked
# elsewhere blocks on the missing-denylist arm and would satisfy "leg 1 blocked"
# for entirely the wrong reason. Anchored patterns (`^ *#`) for the same reason
# the 8M META uses them: unanchored, a prose line naming the sentinel mid-sentence
# starts the excision early.
QZV_REAL_VBS=$(readlink "$VBS_QZV" 2>/dev/null || printf '%s' "$VBS_QZV")
VBS_QZV_MUT="$FIXTURE_QZV/.claude/scripts/vbs-qzv-stripped.sh"
awk '
    /^ *# F1-CHANGE-SET-BINDING BEGIN/ { skip = 1; next }
    /^ *# F1-CHANGE-SET-BINDING END/   { skip = 0; next }
    !skip { print }
' "$QZV_REAL_VBS" > "$VBS_QZV_MUT"
chmod +x "$VBS_QZV_MUT"
# THE GUARD FIRST: a strip that matched nothing leaves a byte-identical copy, and
# then every leg below measures the SHIPPED hook while reporting on a mutant.
if assert_mutant_applied "vbs-qzv META" "$QZV_REAL_VBS" "$VBS_QZV_MUT"; then
    assert_eq "vbs-qzv META: no F1_BINDING_VERDICT guard survives (the strip landed where it was aimed)" \
        "0" "$(grep -c 'F1_BINDING_VERDICT" = "safe"' "$VBS_QZV_MUT" | tr -d '[:space:]')"
    assert_eq "vbs-qzv META: ...while the releasing DEFAULT survives outside the region" "1" \
        "$(grep -c '^F1_BINDING_VERDICT=safe$' "$VBS_QZV_MUT" | tr -d '[:space:]')"
    assert_eq "vbs-qzv META: the stripped copy still parses" "0" \
        "$(bash -n "$VBS_QZV_MUT" 2>/dev/null && echo 0 || echo 1)"
    # Leg 1's exact state, against the stripped copy.
    TID_QM=$(cd "$FIXTURE_QZV" && bd create "qzv META: stripped guard auto-approves" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    (cd "$FIXTURE_QZV" && bd update "$TID_QM" --status in_progress >/dev/null 2>&1) || true
    qzv_arm "$TID_QM"
    qzv_comment "$TID_QM" "IMPLEMENTER: role=devops task=$TID_QM at 2099-01-01T00:00:00Z"
    assert_eq "vbs-qzv META: with the binding stripped, the in-flight implementer's task is AUTO-APPROVED (leg 1 WOULD fail)" \
        "ALLOW" "$(qzv_decision "$VBS_QZV_MUT")"
    assert_eq "vbs-qzv META: ...stamping an approval record on work that does not exist" \
        "1" "$(qzv_record_count "$TID_QM")"
    QM_LABELS=$(qzv_labels "$TID_QM")
    assert_eq "vbs-qzv META: ...and the qa-approved label with it" "1" \
        "$(printf ',%s,' "$QM_LABELS" | grep -c ',qa-approved,' | tr -d '[:space:]')"
    # Restore control: the SHIPPED hook refuses the identical state.
    TID_QMC=$(cd "$FIXTURE_QZV" && bd create "qzv META: shipped guard refuses" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    (cd "$FIXTURE_QZV" && bd update "$TID_QMC" --status in_progress >/dev/null 2>&1) || true
    qzv_arm "$TID_QMC"
    qzv_comment "$TID_QMC" "IMPLEMENTER: role=devops task=$TID_QMC at 2099-01-01T00:00:00Z"
    assert_eq "vbs-qzv META: restore control — the shipped hook refuses the identical state" \
        "block" "$(qzv_decision)"
fi

# ---------------------------------------------------------------------------
# Legs 10-11 + META: A REFUSED APPROVAL MUST BLOCK AND KEEP THE CHANGE SET
# (claude-workflow-plugin-qzv.3)
# ---------------------------------------------------------------------------
#
# THE DEFECT, measured against the shipped scripts before the fix. The F1 arm ran
#
#     "$QA_GATE" approve … >/dev/null 2>&1 || log_sync_error "…"
#
# and then fell straight through to the `rm -f` cleanup and `echo "{}"; exit 0`.
# Every non-zero approve was therefore logged and ignored. With
# `.claude/scripts/impact-report.sh` removed — a partially-synced install, the
# same degradation class legs 4/5/6 already model for review-check.sh — a
# doc-only Stop on an entered task produced:
#
#     Stop decision            : ALLOW  (bare {})
#     QA-GATE APPROVED records : 0
#     changed-files.txt        : WIPED
#     current-task             : survives
#     sync-errors.log          : "qa-gate approve failed … no approval was recorded"
#
# i.e. the gate released a change set, recorded no approval for it, and destroyed
# the tracker that named it. The wipe is what makes the failure self-erasing
# rather than merely silent, and it is why leg 10's tracker assertion is not
# decoration: a block whose recovery needs the change set, delivered over a wiped
# change set, is unrecoverable.
#
# SECOND DEFECT, on the same path and fixed in the same change set (leg 11).
# `qa-gate.sh` runs under `set -e`, `compute_change_set_hash` returns 1 when
# impact-report.sh is missing, and cmd_approve assigned from it with no `||`
# guard — so the assignment aborted the script three lines above the
# `impact_report_unverifiable` refusal written for exactly that condition. Two-arm
# control against the shipped script: `set -e` gave rc=1 with EMPTY stdout and
# EMPTY stderr, the same call under `set +e` gave rc=2 with the error_key. Fixing
# only that buys nothing an operator can see (the hook discarded both streams);
# fixing only the hook leaves it blocking on an approve that explains nothing.

Q10_REAL_IR=$(readlink "$IR_QZV" 2>/dev/null || printf '%s' "$IR_QZV")

# --- Leg 10: the hook. approve REFUSES -> block, tracker SURVIVES ------------
# CONTROL first, on its own task, so the block below is attributable to the
# removal and not to the fixture. (Its own task because ALLOW means F1 approves,
# which clears the gate label, truncates the tracker and unsets current-task.)
TID_Q10=$(cd "$FIXTURE_QZV" && bd create "qzv.3: approve refusal, control" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q10" --status in_progress >/dev/null 2>&1) || true
qzv_arm "$TID_Q10"
assert_eq "vbs-qzv.3-10: CONTROL — with impact-report.sh present this state auto-approves" \
    "ALLOW" "$(qzv_decision)"

TID_Q10B=$(cd "$FIXTURE_QZV" && bd create "qzv.3: approve refusal, probe" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q10B" --status in_progress >/dev/null 2>&1) || true
# ARM the cycle while impact-report.sh is STILL PRESENT, so `enter` writes the
# artifact. Removing the script first would make approve refuse with
# impact_report_MISSING instead, which is a different refusal reached without
# ever calling compute_change_set_hash — the leg would then pass for a reason
# that has nothing to do with either defect.
qzv_arm "$TID_Q10B"
assert_eq "vbs-qzv.3-10: precondition — enter wrote the impact-report artifact" "yes" \
    "$(ls "$TRACK_QZV"/impact-report-*.json >/dev/null 2>&1 && echo yes || echo no)"
rm -f "$IR_QZV"
assert_eq "vbs-qzv.3-10: precondition — impact-report.sh is genuinely absent" "absent" \
    "$([ -e "$IR_QZV" ] && echo present || echo absent)"
assert_eq "vbs-qzv.3-10: precondition — the tracker names the change set going in" "1" \
    "$(grep -c . "$TRACK_QZV/changed-files.txt" 2>/dev/null | tr -d '[:space:]')"
Q10_JSON=$(qzv_json)
assert_eq "vbs-qzv.3-10: a REFUSED approve BLOCKS the Stop (was: ALLOW, bare {})" \
    "block" "$(printf '%s' "$Q10_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
Q10_REASON=$(printf '%s' "$Q10_JSON" | jq -r '.reason // empty')
assert_contains "vbs-qzv.3-10: ...naming the refusal rather than releasing silently" \
    "qa-gate.sh approve\` REFUSED" "$Q10_REASON"
assert_contains "vbs-qzv.3-10: ...carrying approve's error_key so the block is actionable" \
    "impact_report_unverifiable" "$Q10_REASON"
assert_contains "vbs-qzv.3-10: ...and approve's own observations, not a bare 'approve failed'" \
    "cannot recompute the current change-set hash" "$Q10_REASON"
assert_contains "vbs-qzv.3-10: ...and the exit status it refused with" \
    "approve exit: 2" "$Q10_REASON"
assert_eq "vbs-qzv.3-10: ...nothing was approved" "0" "$(qzv_record_count "$TID_Q10B")"
Q10_LABELS=$(qzv_labels "$TID_Q10B")
assert_eq "vbs-qzv.3-10: ...no qa-approved label was written" "0" \
    "$(printf ',%s,' "$Q10_LABELS" | grep -c ',qa-approved,' | tr -d '[:space:]')"
# THE HALF QA'S WRITE-UP MISSED: the cleanup ran on the failure path too, so the
# refusal cost the change set as well as the approval.
assert_eq "vbs-qzv.3-10: THE CHANGE SET SURVIVES the refusal (was: changed-files.txt WIPED)" \
    "1" "$(grep -c . "$TRACK_QZV/changed-files.txt" 2>/dev/null | tr -d '[:space:]')"
# Read through the canonical helper rather than cat-ing the file: the pointer's
# on-disk shape is current-task.sh's business, and QA's round-8 refinement to the
# filing (current-task SURVIVES the failure path; only changed-files.txt was
# wiped) is the fact this pins.
assert_eq "vbs-qzv.3-10: ...and current-task still names the task (it always survived; only the tracker did not)" \
    "$TID_Q10B" "$(bash "$CT_QZV" get 2>/dev/null | tr -d '[:space:]')"
ln -sf "$Q10_REAL_IR" "$IR_QZV" 2>/dev/null || true

# --- Leg 11: approve itself. The refusal is REACHABLE under set -e -----------
# This leg fails RED against the shipped script as it stood: rc=1, stdout empty,
# stderr empty, no envelope at all.
TID_Q11=$(cd "$FIXTURE_QZV" && bd create "qzv.3: approve refusal is reachable" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q11" --status in_progress >/dev/null 2>&1) || true
qzv_arm "$TID_Q11"
rm -f "$IR_QZV"
Q11_RC=0
Q11_OUT=$(bash "$QG_QZV" approve "$TID_Q11" \
    --no-review "F1 doc-only fast path: no reviewable source changed" \
    --no-completion "F1 doc-only fast path: no specialist, no completion payload" \
    "spec: the F1 approval, by hand" 2>&1) || Q11_RC=$?
assert_eq "vbs-qzv.3-11: approve exits 2, the documented refusal code (was: 1, an errexit abort)" \
    "2" "$Q11_RC"
assert_eq "vbs-qzv.3-11: ...with a PARSEABLE envelope (was: empty stdout AND empty stderr)" \
    "yes" "$(printf '%s' "$Q11_OUT" | jq -e 'type == "object"' >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "vbs-qzv.3-11: ...naming the refusal that was dead code under set -e" \
    "impact_report_unverifiable" "$(printf '%s' "$Q11_OUT" | jq -r '.error_key // "(none)"' 2>/dev/null)"
assert_eq "vbs-qzv.3-11: ...and nothing was approved" "0" "$(qzv_record_count "$TID_Q11")"

# 11B: the SECOND unguarded assignment, reached only through the audited
# --no-impact-report bypass — the exit an operator is told to take when the
# artifact is unavailable, which was itself unusable in that exact situation
# (rc=1, empty output, 0 records). It must now succeed and say the binding is
# missing rather than dying.
TID_Q11B=$(cd "$FIXTURE_QZV" && bd create "qzv.3: the impact bypass works when the script is gone" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q11B" --status in_progress >/dev/null 2>&1) || true
ln -sf "$Q10_REAL_IR" "$IR_QZV" 2>/dev/null || true
qzv_arm "$TID_Q11B"
rm -f "$IR_QZV"
Q11B_RC=0
Q11B_OUT=$(bash "$QG_QZV" approve "$TID_Q11B" \
    --no-impact-report "spec: the artifact cannot be recomputed here" \
    --no-review "F1 doc-only fast path: no reviewable source changed" \
    --no-completion "F1 doc-only fast path: no specialist, no completion payload" \
    "spec: the audited bypass" 2>&1) || Q11B_RC=$?
assert_eq "vbs-qzv.3-11B: the --no-impact-report bypass SUCCEEDS with the script absent (was: rc=1, empty)" \
    "0" "$Q11B_RC"
assert_eq "vbs-qzv.3-11B: ...recording the approval it was asked for (was: 0 records)" \
    "1" "$(qzv_record_count "$TID_Q11B")"
assert_contains "vbs-qzv.3-11B: ...while SAYING the change-set binding is missing rather than faking one" \
    "WITHOUT a change-set binding" "$(printf '%s' "$Q11B_OUT" | jq -r '.observations // empty' 2>/dev/null)"
ln -sf "$Q10_REAL_IR" "$IR_QZV" 2>/dev/null || true

# --- Leg 12: the SUCCESS path's stdout is still exactly `{}` -----------------
# The regression this change could most plausibly have introduced. qzv.3 stopped
# sending approve's stdout to /dev/null and started CAPTURING it; if any of it
# reached the hook's own stdout, the whole output stops being a JSON object and
# Claude silently ignores the verdict — the llh.20 antipattern, on the
# most-travelled path in the gate. Section 6a pins that property for the
# APPROVED path; this is the F1 fast path's own copy, and it reads the WHOLE
# stdout with no `tail -1` salvage, exactly as 6a does, because a salvage would
# hide the very thing it is looking for.
TID_Q12=$(cd "$FIXTURE_QZV" && bd create "qzv.3: F1 success stdout is a bare envelope" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q12" --status in_progress >/dev/null 2>&1) || true
qzv_arm "$TID_Q12"
Q12_RAW=$(printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' | bash "$VBS_QZV" 2>/dev/null)
assert_eq "vbs-qzv.3-12: the F1 success path's WHOLE stdout is exactly '{}' (no captured approve output leaked)" \
    "{}" "$Q12_RAW"
assert_eq "vbs-qzv.3-12: ...and it parses as JSON without tail salvage" "yes" \
    "$(printf '%s' "$Q12_RAW" | jq -e . >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "vbs-qzv.3-12: ...over a real auto-approval, not an empty run" "1" \
    "$(qzv_record_count "$TID_Q12")"

# --- Leg 13: approve fails with NO parseable envelope ------------------------
# The arm that used to be the NORMAL shape of this failure rather than an edge
# case: under the pre-qzv.3 qa-gate.sh, `approve` died on an unguarded
# `current_hash=$(compute_change_set_hash)` and emitted rc=1 with EMPTY stdout
# AND EMPTY stderr. That is fixed at the source (leg 11), so this arm now covers
# an OLDER qa-gate.sh on disk or an outright crash — and it must still block and
# still say something, rather than printing an empty "approve reported:" section.
# Driven with a stub so the shape is exact and does not depend on any refusal.
TID_Q13=$(cd "$FIXTURE_QZV" && bd create "qzv.3: approve fails with no envelope" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_QZV" && bd update "$TID_Q13" --status in_progress >/dev/null 2>&1) || true
qzv_arm "$TID_Q13"
Q13_REAL_QG=$(readlink "$QG_QZV" 2>/dev/null || printf '%s' "$QG_QZV")
rm -f "$QG_QZV"
# `status` must keep answering `entered` — the F1 arm reads it to decide
# eligibility, and a stub that failed there would take the arm out of play and
# the leg would pass without ever reaching the branch under test.
cat > "$QG_QZV" <<'Q13STUB'
#!/bin/bash
case "${1:-}" in
    status) printf '{"ok":true,"subcommand":"status","status":"entered"}\n'; exit 0 ;;
    enter)  printf '{"ok":true,"subcommand":"enter"}\n'; exit 0 ;;
    approve) exit 1 ;;
    reconcile-tracker) printf '{"ok":true,"added":0,"subtracted":0}\n'; exit 0 ;;
    *) printf '{"ok":true}\n'; exit 0 ;;
esac
Q13STUB
chmod +x "$QG_QZV"
Q13_JSON=$(qzv_json)
assert_eq "vbs-qzv.3-13: an approve that fails with NO envelope still BLOCKS" \
    "block" "$(printf '%s' "$Q13_JSON" | jq -r '.decision // "ALLOW"' 2>/dev/null)"
Q13_REASON=$(printf '%s' "$Q13_JSON" | jq -r '.reason // empty')
assert_contains "vbs-qzv.3-13: ...saying the output was unparseable rather than printing an empty section" \
    "no parseable JSON envelope" "$Q13_REASON"
assert_contains "vbs-qzv.3-13: ...and naming the empty-output case explicitly" \
    "approve wrote nothing to stdout or stderr" "$Q13_REASON"
assert_eq "vbs-qzv.3-13: ...and the change set survives here too" "1" \
    "$(grep -c . "$TRACK_QZV/changed-files.txt" 2>/dev/null | tr -d '[:space:]')"
rm -f "$QG_QZV"
ln -sf "$Q13_REAL_QG" "$QG_QZV" 2>/dev/null || true

# ---------------------------------------------------------------------------
# qzv.3 META (spec-mandated): strip the F1-APPROVE-REFUSAL region from a copy and
# leg 10 must RELEASE again, over a WIPED tracker — the live defect, reproduced.
#
# The region is arranged so stripping it yields the PRE-qzv.3 arm rather than a
# syntax error: the capture, the rc variable and the sync-error log line live
# OUTSIDE the sentinels with the releasing default, and only the block guard
# lives inside. Same discipline as F1_BINDING_VERDICT above. The copy lives in
# the fixture's .claude/scripts/ so it keeps resolving its BASH_SOURCE-relative
# siblings; a copy parked elsewhere blocks on the missing-denylist arm and would
# satisfy "leg 10 released" for entirely the wrong reason.
QZV3_REAL_VBS=$(readlink "$VBS_QZV" 2>/dev/null || printf '%s' "$VBS_QZV")
VBS_QZV3_MUT="$FIXTURE_QZV/.claude/scripts/vbs-qzv3-stripped.sh"
awk '
    /^ *# F1-APPROVE-REFUSAL BEGIN/ { skip = 1; next }
    /^ *# F1-APPROVE-REFUSAL END/   { skip = 0; next }
    !skip { print }
' "$QZV3_REAL_VBS" > "$VBS_QZV3_MUT"
chmod +x "$VBS_QZV3_MUT"
if assert_mutant_applied "vbs-qzv.3 META" "$QZV3_REAL_VBS" "$VBS_QZV3_MUT"; then
    assert_eq "vbs-qzv.3 META: no block guard survives (the strip landed where it was aimed)" \
        "0" "$(grep -c 'F1_APPROVE_KEY=' "$VBS_QZV3_MUT" | tr -d '[:space:]')"
    assert_eq "vbs-qzv.3 META: ...nor the block reason it composes" "0" \
        "$(grep -c 'QA gate cannot release' "$VBS_QZV3_MUT" | tr -d '[:space:]')"
    assert_eq "vbs-qzv.3 META: ...while the releasing DEFAULT survives outside the region" "1" \
        "$(grep -c '^                F1_APPROVE_RC=0$' "$VBS_QZV3_MUT" | tr -d '[:space:]')"
    assert_eq "vbs-qzv.3 META: ...and so does the pre-fix sync-error line" "1" \
        "$(grep -c 'no approval was recorded' "$VBS_QZV3_MUT" | tr -d '[:space:]')"
    assert_eq "vbs-qzv.3 META: the stripped copy still parses" "0" \
        "$(bash -n "$VBS_QZV3_MUT" 2>/dev/null && echo 0 || echo 1)"
    # Leg 10's exact state, against the stripped copy.
    TID_QW=$(cd "$FIXTURE_QZV" && bd create "qzv.3 META: stripped guard releases" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    (cd "$FIXTURE_QZV" && bd update "$TID_QW" --status in_progress >/dev/null 2>&1) || true
    ln -sf "$Q10_REAL_IR" "$IR_QZV" 2>/dev/null || true
    qzv_arm "$TID_QW"
    rm -f "$IR_QZV"
    assert_eq "vbs-qzv.3 META: with the guard stripped, a REFUSED approve RELEASES the Stop (leg 10 WOULD fail)" \
        "ALLOW" "$(qzv_decision "$VBS_QZV3_MUT")"
    assert_eq "vbs-qzv.3 META: ...having approved nothing" "0" "$(qzv_record_count "$TID_QW")"
    assert_eq "vbs-qzv.3 META: ...and DESTROYED the change set on the way out" "WIPED" \
        "$([ -f "$TRACK_QZV/changed-files.txt" ] && echo present || echo WIPED)"
    # Restore control INSIDE the META rather than leaning on leg 10: run the
    # identical sequence with the SHIPPED hook, so the ALLOW is attributable to
    # the strip and not to anything this block does differently.
    TID_QWC=$(cd "$FIXTURE_QZV" && bd create "qzv.3 META: shipped guard blocks" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    (cd "$FIXTURE_QZV" && bd update "$TID_QWC" --status in_progress >/dev/null 2>&1) || true
    ln -sf "$Q10_REAL_IR" "$IR_QZV" 2>/dev/null || true
    qzv_arm "$TID_QWC"
    rm -f "$IR_QZV"
    assert_eq "vbs-qzv.3 META: restore control — the shipped hook BLOCKS the identical state" \
        "block" "$(qzv_decision)"
    assert_eq "vbs-qzv.3 META: ...and keeps the change set" "1" \
        "$(grep -c . "$TRACK_QZV/changed-files.txt" 2>/dev/null | tr -d '[:space:]')"
    ln -sf "$Q10_REAL_IR" "$IR_QZV" 2>/dev/null || true
fi

[ "$FAIL" -eq 0 ]

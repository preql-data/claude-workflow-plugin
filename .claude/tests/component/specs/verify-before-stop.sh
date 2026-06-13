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
# (3) And it parses to exactly {} (the clean approved verdict in this fixture).
STDOUT_COMPACT=$(printf '%s' "$STDOUT_ONLY" | jq -c '.' 2>/dev/null || echo "NOT_JSON")
assert_eq "vbs-llh20: approved-path stdout is exactly the {} verdict" \
    "{}" "$STDOUT_COMPACT"
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
# Build a COPY of verify-before-stop.sh with the fixtures alternative stripped
# from DENYLIST_REGEX (the pre-llh.17 world) and re-run repro 1. The
# fixture-script-churn case must then BLOCK — proving the ALLOW assertion above
# is sensitive to the denylist extension, not passing for some incidental
# reason. Pattern-anchored python strip over the unique fixtures sub-pattern.
REAL_VBS_FX=$(readlink "$VBS_FX" || printf '%s' "$VBS_FX")
VBS_FX_MUT="$FIXTURE_FX/vbs-fxmut.sh"
FIXTURES_ALT='|(^|/)\.claude/tests/e2e/fixtures/[^/]+/(\.claude/(scripts|beads)|\.beads)/' \
    REAL_VBS_FX="$REAL_VBS_FX" VBS_FX_MUT="$VBS_FX_MUT" python3 - <<'PYEOF'
import io, os
real = os.environ["REAL_VBS_FX"]; out = os.environ["VBS_FX_MUT"]; alt = os.environ["FIXTURES_ALT"]
with io.open(real, "r", encoding="utf-8") as f:
    s = f.read()
if alt not in s:
    raise SystemExit("META precondition failed: fixtures alternative not found in script under test")
s = s.replace(alt, "", 1)
with io.open(out, "w", encoding="utf-8") as f:
    f.write(s)
PYEOF
chmod +x "$VBS_FX_MUT"
# Confirm the alternative was actually removed from the copy. Anchor on the
# regex-only token `fixtures/[^/]+/` (the `[^/]+` bracket-class appears ONLY
# in the DENYLIST_REGEX line, never in the prose comment that also mentions
# "tests/e2e/fixtures") so the precondition checks the LOAD-BEARING regex,
# not the doc comment.
FX_MUT_STRIPPED=$(grep -cF 'fixtures/[^/]+/' "$VBS_FX_MUT" || true)
FX_MUT_STRIPPED=$(printf '%s' "$FX_MUT_STRIPPED" | tr -d '[:space:]')
assert_eq "vbs-llh17 META: fixtures denylist alternative stripped from copy (regex token gone)" \
    "0" "$FX_MUT_STRIPPED"
run_vbs_fx_mut() {
    printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS_FX_MUT" 2>&1 | tail -1
}
bash "$CT_FX" clear
: > "$TRACK_FX/changed-files.txt"
printf '#!/bin/bash\n# synced qa-gate (mutated again)\n' > "$NESTED_SCRIPTS/qa-gate.sh"
OUT_FX_MUT=$(run_vbs_fx_mut)
assert_decision "vbs-llh17 META: with fixtures denylist stripped, fixture-script churn BLOCKS (ALLOW assertion WOULD fail)" \
    "$OUT_FX_MUT" "block"
# Restore baseline script.
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
REAL_VBS3=$(readlink "$VBS3" || printf '%s' "$VBS3")
VBS3_MUT="$FIXTURE3/vbs-lintmut.sh"
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
REAL_VBS4=$(readlink "$VBS4" || printf '%s' "$VBS4")
VBS4_MUT="$FIXTURE4/vbs-truncmut.sh"
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
# Legit approve writes the change-set-bound record.
POS_APPROVE=$(bash "$QG_CSB" approve "$TID_POS" "reviewed; ships safely" 2>&1)
assert_json_field "vbs-llh18: legit approve succeeds" "$POS_APPROVE" '.status' "approved"
assert_contains "vbs-llh18: approve obs reports the change-set-bound record" \
    "change-set-bound approval record written" "$POS_APPROVE"
# approve clears current-task + truncates changed-files; restore both to the
# approved change-set (the legit Stop fires against the same reviewed files).
bash "$CT_CSB" set "$TID_POS"
printf 'src/handler.ts\n' > "$TRACK_CSB/changed-files.txt"
# Direct proof the record carries the hash --hash-only computes for the
# RESTORED change-set. Captured BEFORE the release assertion below, because
# the RELEASE path runs vbs's QA-approved cleanup (it rm's changed-files.txt),
# after which --hash-only would return the empty-set hash.
POS_CUR_HASH=$(CLAUDE_PROJECT_DIR="$FIXTURE_CSB" bash "$IR_CSB" --hash-only 2>/dev/null || echo "")
POS_REC_HASH=$(cd "$FIXTURE_CSB" && bd show "$TID_POS" --json 2>/dev/null \
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
bash "$QG_MISS" approve "$TID_MISS" "reviewed; ships safely" >/dev/null 2>&1
# approve clears current-task + truncates changed-files; restore both to the
# approved change-set so the legit Stop fires against the same reviewed files.
bash "$CT_MISS" set "$TID_MISS"
printf 'src/handler.ts\n' > "$TRACK_MISS/changed-files.txt"
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
MM18_DEC=$(printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
    | bash "$VBS_MM18" 2>/dev/null | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null)
# Under the neutralized check the forged label RELEASES (the P0 assertion
# above would FAIL against this copy) — proving the check is load-bearing.
assert_eq "vbs META-llh18: with hash-match check neutralized, forged label RELEASES (P0 assertion WOULD fail)" \
    "ALLOW" "$MM18_DEC"

[ "$FAIL" -eq 0 ]

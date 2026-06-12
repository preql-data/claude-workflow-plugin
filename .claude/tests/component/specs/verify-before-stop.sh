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

[ "$FAIL" -eq 0 ]

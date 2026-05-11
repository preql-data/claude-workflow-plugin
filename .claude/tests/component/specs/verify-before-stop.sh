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

[ "$FAIL" -eq 0 ]

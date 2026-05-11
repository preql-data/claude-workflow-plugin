#!/bin/bash
# qa-gate.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers B1/D1/J2/F3/F4: the
# Beads-backed QA gate lifecycle (enter -> approve|block, idempotent
# status, side-effects on current-task and iteration counters).

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent (CI runner, BD_SHIM_ONLY=1).
# Every step of this spec talks to bd — seed task, enter/approve/block,
# status read — so there's no useful partial coverage without it.
bd_required_or_skip

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# Seed a task to operate on.
TID=$(cd "$FIXTURE" && bd create "QA gate test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
assert_match "qa-gate: seed task created" '^[a-z0-9-]+\.' "$TID"

# 1. status on a fresh task -> not-entered.
OUT=$(bash "$QG" status "$TID")
assert_json_field "qa-gate: status=not-entered initially" "$OUT" '.status' "not-entered"
assert_json_field "qa-gate: subcommand=status" "$OUT" '.subcommand' "status"

# 2. enter -> qa-gate-entered label + current-task persisted (F3).
OUT=$(bash "$QG" enter "$TID")
assert_json_field "qa-gate: enter ok=true" "$OUT" '.ok' "true"
assert_json_field "qa-gate: enter status=entered" "$OUT" '.status' "entered"
# current-task helper file populated.
PERSISTED=$(bash "$CT" get)
assert_eq "qa-gate: enter persisted current-task" "$TID" "$PERSISTED"
# Label present on the task.
LABELS=$(cd "$FIXTURE" && bd show "$TID" --json 2>/dev/null | jq -r 'if type == "array" then .[0].labels else .labels end | join(",")')
assert_contains "qa-gate: qa-gate-entered label set" "qa-gate-entered" "$LABELS"

# 3. status now reads `entered`.
OUT=$(bash "$QG" status "$TID")
assert_json_field "qa-gate: status=entered after enter" "$OUT" '.status' "entered"

# 4. Re-entering is idempotent. The script must still report `entered`
# without erroring.
OUT=$(bash "$QG" enter "$TID")
assert_json_field "qa-gate: re-enter idempotent" "$OUT" '.status' "entered"

# 5. block -> qa-blocked label, qa-gate-entered preserved.
OUT=$(bash "$QG" block "$TID" "Missing tests for the new path")
assert_json_field "qa-gate: block ok=true" "$OUT" '.ok' "true"
assert_json_field "qa-gate: block status=blocked" "$OUT" '.status' "blocked"
LABELS=$(cd "$FIXTURE" && bd show "$TID" --json 2>/dev/null | jq -r 'if type == "array" then .[0].labels else .labels end | join(",")')
assert_contains "qa-gate: qa-blocked label set" "qa-blocked" "$LABELS"
assert_contains "qa-gate: qa-gate-entered preserved on block" "qa-gate-entered" "$LABELS"

# 6. status now reads `blocked` (precedence: approved > blocked > entered).
OUT=$(bash "$QG" status "$TID")
assert_json_field "qa-gate: status=blocked after block" "$OUT" '.status' "blocked"

# 7. Seed a SECOND task to test approve atomicity from a clean state.
TID2=$(cd "$FIXTURE" && bd create "QA approve test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID2" >/dev/null
# Add the pending label by hand so the approve path exercises all three
# label removals.
(cd "$FIXTURE" && bd label add "$TID2" qa-pending >/dev/null 2>&1)

# 8. approve -> +qa-approved, -qa-gate-entered, -qa-pending, current-task cleared.
OUT=$(bash "$QG" approve "$TID2" "Looks good after review")
assert_json_field "qa-gate: approve ok=true" "$OUT" '.ok' "true"
assert_json_field "qa-gate: approve status=approved" "$OUT" '.status' "approved"
LABELS=$(cd "$FIXTURE" && bd show "$TID2" --json 2>/dev/null | jq -r 'if type == "array" then .[0].labels else .labels end | join(",")')
assert_contains "qa-gate: qa-approved label set" "qa-approved" "$LABELS"
# qa-gate-entered should be removed.
ENTERED_PRESENT=$(printf '%s' ",$LABELS," | grep -c ',qa-gate-entered,' || true)
ENTERED_PRESENT=$(printf '%s' "$ENTERED_PRESENT" | tr -d '[:space:]')
assert_eq "qa-gate: qa-gate-entered removed after approve" "0" "$ENTERED_PRESENT"
PENDING_PRESENT=$(printf '%s' ",$LABELS," | grep -c ',qa-pending,' || true)
PENDING_PRESENT=$(printf '%s' "$PENDING_PRESENT" | tr -d '[:space:]')
assert_eq "qa-gate: qa-pending removed after approve" "0" "$PENDING_PRESENT"
# current-task cleared by approve.
CLEARED=$(bash "$CT" get)
assert_eq "qa-gate: current-task cleared after approve" "" "$CLEARED"

# 9. Re-approving is idempotent (the label is already set).
OUT=$(bash "$QG" approve "$TID2" "Same approval")
assert_json_field "qa-gate: re-approve idempotent" "$OUT" '.status' "approved"

# 10. F4: approve wipes iteration counter files. Plant a fake counter
# under the per-task path on a FRESH task (re-approving an already-approved
# task short-circuits to idempotent no-op and skips the wipe).
TID_F4=$(cd "$FIXTURE" && bd create "F4 cleanup test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID_F4" >/dev/null
SANITIZED=$(printf '%s' "$TID_F4" | tr -c 'A-Za-z0-9._-' '_')
COUNTER="$TRACK/iteration-count.$SANITIZED"
printf '3\n' > "$COUNTER"
assert_eq "qa-gate: pre-condition counter planted" "0" \
    "$([ -s "$COUNTER" ] && echo 0 || echo 1)"
bash "$QG" approve "$TID_F4" "Trigger F4 cleanup" >/dev/null
assert_eq "qa-gate: approve wipes per-task iteration counter" "1" \
    "$([ -s "$COUNTER" ] && echo 0 || echo 1)"

# 11. usage error: missing args -> rc=1.
RC=0
bash "$QG" 2>/dev/null || RC=$?
assert_eq "qa-gate: empty subcommand exits 1" "1" "$RC"

# 12. E8 memory bridge: block writes a feedback file under
# $HOME/.claude/projects/<slug>/memory/qa-block-*.md. Use a per-test HOME
# so we don't pollute the real one.
TEST_HOME=$(mktemp -d -t cwp-qg-home.XXXXXX)
SLUG=$(printf '%s' "$FIXTURE" | sed -e 's|/|-|g')
MEM_DIR="$TEST_HOME/.claude/projects/${SLUG}/memory"
TID3=$(cd "$FIXTURE" && bd create "QA memory bridge test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
HOME="$TEST_HOME" bash "$QG" block "$TID3" "Repeated null check bug" >/dev/null
MEM_COUNT=$(ls "$MEM_DIR"/qa-block-*.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "qa-gate: E8 memory file written on block" "1" "$MEM_COUNT"
# Cleanup.
rm -rf "$TEST_HOME"

[ "$FAIL" -eq 0 ]

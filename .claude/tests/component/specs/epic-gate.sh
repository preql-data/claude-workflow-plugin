#!/bin/bash
# epic-gate.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers B2 / J19 (Phase 4):
# epic-level gate that decides pass / defer / block based on sibling QA
# state, plus shared-files intersection across in-progress siblings.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
EG="$FIXTURE/.claude/scripts/epic-gate.sh"

# Helper: extract a Beads task id from `bd create --json` output, normalised.
bd_create_id() {
    cd "$FIXTURE" && bd create "$@" --json 2>/dev/null | jq -r '.id // empty'
}

# 1. Seed: epic with 2 sub-tasks (no QA labels yet).
EPIC=$(bd_create_id "Epic parent" -t epic -p 1)
assert_match "epic-gate: epic created" '^[a-z0-9-]+\.' "$EPIC"

SUB1=$(bd_create_id "Sub task 1" -t task -p 1 --deps "parent-child:$EPIC")
SUB2=$(bd_create_id "Sub task 2" -t task -p 1 --deps "parent-child:$EPIC")
assert_match "epic-gate: sub1 created" '^[a-z0-9-]+\.' "$SUB1"
assert_match "epic-gate: sub2 created" '^[a-z0-9-]+\.' "$SUB2"

# 2. check on an epic with two open sub-tasks (no QA labels) -> defer
# (the "other" bucket / open sub-tasks).
OUT=$(bash "$EG" check "$EPIC")
DECISION=$(printf '%s' "$OUT" | jq -r '.decision // empty')
assert_match "epic-gate: defer when sub-tasks open w/o QA labels" \
    '^(defer|block)$' "$DECISION"
assert_json_field "epic-gate: check ok" "$OUT" '.ok' "true"
assert_json_field "epic-gate: check returned epic id" "$OUT" '.epic_id' "$EPIC"

# 3. Approve both sub-tasks (set qa-approved label directly), check again
# -> pass.
(cd "$FIXTURE" && bd label add "$SUB1" qa-approved >/dev/null 2>&1)
(cd "$FIXTURE" && bd label add "$SUB2" qa-approved >/dev/null 2>&1)
OUT=$(bash "$EG" check "$EPIC")
assert_json_field "epic-gate: all approved -> pass" "$OUT" '.decision' "pass"

# 4. Block one sub-task -> block. Must REMOVE qa-approved first (the
# precedence in qa_state_of is approved > blocked, so a task with both
# labels reports approved).
(cd "$FIXTURE" && bd label remove "$SUB1" qa-approved >/dev/null 2>&1)
(cd "$FIXTURE" && bd label add "$SUB1" qa-blocked >/dev/null 2>&1)
OUT=$(bash "$EG" check "$EPIC")
assert_json_field "epic-gate: any blocked -> block" "$OUT" '.decision' "block"

# 5. Remove blocked, add qa-pending sibling -> defer.
(cd "$FIXTURE" && bd label remove "$SUB1" qa-blocked >/dev/null 2>&1)
(cd "$FIXTURE" && bd label add "$SUB1" qa-pending >/dev/null 2>&1)
(cd "$FIXTURE" && bd label remove "$SUB1" qa-approved >/dev/null 2>&1)
OUT=$(bash "$EG" check "$EPIC")
DEC=$(printf '%s' "$OUT" | jq -r '.decision')
# pending OR entered -> defer; epic still has SUB2 approved.
assert_eq "epic-gate: pending sibling -> defer" "defer" "$DEC"

# 6. siblings subcommand returns the list (excluding the queried task).
OUT=$(bash "$EG" siblings "$SUB1")
assert_json_field "epic-gate: siblings returns ok" "$OUT" '.ok' "true"
SIB_COUNT=$(printf '%s' "$OUT" | jq '.siblings | length')
assert_eq "epic-gate: siblings count=1 (excludes self)" "1" "$SIB_COUNT"
# sibling id must be SUB2.
SIB_FIRST_ID=$(printf '%s' "$OUT" | jq -r '.siblings[0].id')
assert_eq "epic-gate: sibling id matches SUB2" "$SUB2" "$SIB_FIRST_ID"

# 7. siblings on a parent-less task -> empty siblings array, null epic.
LONE=$(bd_create_id "Lone task no parent" -t task -p 2)
OUT=$(bash "$EG" siblings "$LONE")
LONE_SIB_COUNT=$(printf '%s' "$OUT" | jq '.siblings | length')
assert_eq "epic-gate: parentless task has 0 siblings" "0" "$LONE_SIB_COUNT"
LONE_EPIC=$(printf '%s' "$OUT" | jq -r '.epic_id // "null"')
assert_eq "epic-gate: parentless task epic_id null" "null" "$LONE_EPIC"

# 8. shared-files subcommand: with no notes-embedded JSON, intersections=[].
OUT=$(bash "$EG" shared-files "$SUB1")
INT_COUNT=$(printf '%s' "$OUT" | jq '.intersections | length')
assert_eq "epic-gate: shared-files no-notes -> 0 intersections" "0" "$INT_COUNT"
assert_json_field "epic-gate: shared-files ok" "$OUT" '.ok' "true"

# 9. usage error.
RC=0
bash "$EG" 2>/dev/null || RC=$?
assert_eq "epic-gate: empty subcommand exits 1" "1" "$RC"

# 10. Unknown subcommand exits non-zero.
RC=0
bash "$EG" nonsense "$EPIC" 2>/dev/null || RC=$?
assert_eq "epic-gate: unknown subcommand exits non-zero" "1" "$RC"

[ "$FAIL" -eq 0 ]

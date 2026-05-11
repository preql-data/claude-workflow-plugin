#!/bin/bash
# tech-debt.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers J22 (Phase 4): the
# TECHNICAL_DEBT.md helper that lets the QA agent defer findings as
# table rows AND (with --bd-task) opens a tracking Beads task.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
TD="$FIXTURE/.claude/scripts/tech-debt.sh"
DEBT="$FIXTURE/TECHNICAL_DEBT.md"

# 1. First `add` creates TECHNICAL_DEBT.md with header.
OUT=$(bash "$TD" add medium "src/foo.ts:42" "30m" "Missing null check")
assert_eq "tech-debt: TECHNICAL_DEBT.md created" "0" \
    "$([ -f "$DEBT" ] && echo 0 || echo 1)"
assert_match "tech-debt: file has table header" \
    'severity.*file:line' "$(cat "$DEBT")"
assert_match "tech-debt: row 1 written" \
    'Missing null check' "$(cat "$DEBT")"
assert_json_field "tech-debt: add returns ok=true" "$OUT" '.ok' "true"
assert_json_field "tech-debt: subcommand=add" "$OUT" '.subcommand' "add"
assert_json_field "tech-debt: severity recorded" "$OUT" '.row.severity' "medium"

# 2. Second `add` (different finding) appends row.
bash "$TD" add high "src/bar.ts:10" "1h" "Race condition in cache" >/dev/null
LINES=$(grep -c 'Race condition in cache' "$DEBT")
assert_eq "tech-debt: second row appended" "1" "$LINES"

# 3. NB: the script does NOT do dedup — each `add` appends. This is by
# design (each call is a discrete event with its own timestamp). We
# verify by adding the SAME finding twice and confirming the row count
# rises to 2.
bash "$TD" add low "src/baz.ts:7" "S" "Duplicate finding to confirm append" >/dev/null
bash "$TD" add low "src/baz.ts:7" "S" "Duplicate finding to confirm append" >/dev/null
DUP_COUNT=$(grep -c 'Duplicate finding to confirm append' "$DEBT")
assert_eq "tech-debt: duplicate adds both written (no implicit dedup)" "2" "$DUP_COUNT"

# 4. `list` echoes the file contents (no decoration).
LISTING=$(bash "$TD" list)
assert_contains "tech-debt: list echoes header" "severity" "$LISTING"
assert_contains "tech-debt: list echoes row" "Missing null check" "$LISTING"

# 5. Missing args -> usage error (rc=1).
RC=0
bash "$TD" add medium 2>/dev/null || RC=$?
assert_eq "tech-debt: missing args exits 1" "1" "$RC"

# 6. Pipe character in description is sanitized (`|` -> `/`) so it
# doesn't break the markdown table.
bash "$TD" add medium "src/qux.ts:5" "M" "Bad code | think | hard" >/dev/null
assert_match "tech-debt: pipe characters sanitized" \
    'Bad code / think / hard' "$(cat "$DEBT")"

# 7. With --bd-task, a Beads task is created. Need an active task for the
# blocks-dep link.
CT="$FIXTURE/.claude/scripts/current-task.sh"
PARENT_TID=$(cd "$FIXTURE" && bd create "Active parent task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$CT" set "$PARENT_TID"
OUT=$(bash "$TD" add medium "src/quux.ts:11" "2h" "Refactor login flow" --bd-task)
BD_ID=$(printf '%s' "$OUT" | jq -r '.bd_task_id // empty')
assert_match "tech-debt: --bd-task creates a Beads task id" \
    '^[a-z0-9-]+\.' "$BD_ID"

# 8. The created task has --deps blocks:<parent>. We confirm by listing
# the task's dependencies. (bd show emits text; we grep for the parent id.)
DEPS=$(cd "$FIXTURE" && bd show "$BD_ID" 2>/dev/null || echo "")
assert_contains "tech-debt: bd task linked back to parent (blocks)" \
    "$PARENT_TID" "$DEPS"

[ "$FAIL" -eq 0 ]

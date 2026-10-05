#!/bin/bash
# tech-debt.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers J22 (Phase 4): the
# TECHNICAL_DEBT.md helper that lets the QA agent defer findings as
# table rows AND (with --bd-task) opens a tracking Beads task.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent (CI runner, BD_SHIM_ONLY=1).
# Later scenarios exercise the `--bd-task` flag, which opens a tracking
# Beads task and writes its id back into TECHNICAL_DEBT.md. The TECH_DEBT
# scenarios without bd are not separable from the spec's overall pass/fail
# verdict, so we skip the whole spec when bd is missing.
bd_required_or_skip

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
    "$BD_ID_RE" "$BD_ID"

# 8. The created task is linked back to the active task with a `blocks` edge.
#
# STRENGTHENED (claude-workflow-plugin-fkm.1.1). This used to grep the plain
# text of `bd show` for $PARENT_TID via assert_contains. Two problems: the
# needle is unguarded, and `grep -qF -- ""` matches ANY input — so if
# PARENT_TID ever came back empty the assertion passed while proving nothing.
# It is now read from the STRUCTURED .dependencies array, with the parent id
# pinned non-empty first, so neither an empty needle nor a text-format change
# can fake it.
#
# What it guards: tech-debt.sh used to pass `bd create --deps blocks:<active>`.
# bd 1.1.2 still accepts that flag and records the edge BACKWARDS (exit 0, the
# BLOCKER ends up depending on the new task — bd-compat pin #4 asserts the
# inversion directly),
# so the link vanished while the JSON kept claiming "created with blocks
# dependency on the active task". The script now issues an explicit
# `bd dep add`, and this asserts the edge really lands.
assert_match "tech-debt: precondition — the active parent id is a real id (guards the needle below)" \
    "$BD_ID_RE" "$PARENT_TID"
DEP_IDS=$(cd "$FIXTURE" && bd show "$BD_ID" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.dependencies // [])[] | .id' 2>/dev/null || echo "")
assert_contains "tech-debt: bd task linked back to parent (blocks)" \
    "$PARENT_TID" "$DEP_IDS"
DEP_KIND=$(cd "$FIXTURE" && bd show "$BD_ID" --json 2>/dev/null \
    | jq -r --arg p "$PARENT_TID" 'if type=="array" then .[0] else . end
             | (.dependencies // [])[] | select(.id == $p) | .dependency_type' 2>/dev/null || echo "")
assert_eq "tech-debt: ...and the edge is a 'blocks' edge, not some other kind" "blocks" "$DEP_KIND"
assert_json_field "tech-debt: ...and the JSON says so only because it is true" \
    "$OUT" '.observations' \
    "Row appended; Beads task $BD_ID created with blocks dependency on the active task."

# 8b. CONTROL — the assertion above must be able to FAIL. With no active task
# there is nothing to link to, so the same read must come back empty. Without
# this, a bd whose `dependencies` array always echoed something would satisfy 8
# forever.
bash "$CT" clear >/dev/null 2>&1 || true
OUT_NODEP=$(bash "$TD" add low "src/nodep.ts:1" "1h" "No active task" --bd-task)
BD_ID_NODEP=$(printf '%s' "$OUT_NODEP" | jq -r '.bd_task_id // empty')
assert_match "tech-debt 8b: CONTROL task created" "$BD_ID_RE" "$BD_ID_NODEP"
DEP_IDS_NODEP=$(cd "$FIXTURE" && bd show "$BD_ID_NODEP" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.dependencies // [])[] | .id' 2>/dev/null || echo "")
assert_eq "tech-debt 8b: CONTROL — with no active task the new task has NO dependencies" \
    "" "$DEP_IDS_NODEP"
assert_contains "tech-debt 8b: ...and the JSON does NOT claim a dependency it did not record" \
    "NO blocks dependency was recorded" "$OUT_NODEP"

[ "$FAIL" -eq 0 ]

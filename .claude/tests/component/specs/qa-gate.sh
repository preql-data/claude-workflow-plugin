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

# ===========================================================================
# Mechanical impact-report gate (G2.n6d / claude-workflow-plugin-llh.2).
#
# Background: across 4 paid live runs the QA agent made ZERO impact_of
# calls regardless of prompt strength (bd show claude-workflow-plugin-n6d).
# The fix makes the impact analysis a deterministic ARTIFACT:
#   - `qa-gate.sh enter` invokes impact-report.sh (tolerant) which writes
#     .qa-tracking/impact-report-<task-id>.json. In this fixture the
#     code-graph server is absent (no .claude/mcp/), so the artifact
#     degrades to server:"absent" + impact:null per file — but it EXISTS.
#   - `qa-gate.sh approve` REFUSES (exit 2, structured error) when the
#     artifact is missing OR its change_set_hash doesn't match the
#     current changed-files list (stale report = no report).
#   - Bypass: `--no-impact-report '<reason>'` — approval proceeds, the
#     reason lands in the approval comment AND as an impact-bypass note
#     in the gate JSON observations.
#   - server:"absent" reports are ACCEPTED (documented degradation); the
#     refusal is only for missing/invalid/stale artifacts.
#
# These assertions were written FAILING-FIRST: against the pre-fix
# qa-gate.sh, 13 fails (no artifact generated on enter) and 14/15 fail
# because approve succeeds where it must refuse. The captured red run is
# recorded on the Beads task.
# ===========================================================================

IR_SCRIPT="$FIXTURE/.claude/scripts/impact-report.sh"
report_path_for() {
    # Mirror qa-gate.sh's sanitize (tr -c 'A-Za-z0-9._-' '_').
    printf '%s/impact-report-%s.json' "$TRACK" \
        "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# 13. enter generates the impact-report artifact (server-absent shape).
TID_IR1=$(cd "$FIXTURE" && bd create "impact-report enter generation" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/seeded-change.ts\n' > "$TRACK/changed-files.txt"
bash "$QG" enter "$TID_IR1" >/dev/null
IR1_REPORT=$(report_path_for "$TID_IR1")
assert_eq "impact-report: enter writes the artifact" "0" \
    "$([ -f "$IR1_REPORT" ] && echo 0 || echo 1)"
IR1_JSON=$(cat "$IR1_REPORT" 2>/dev/null || echo "{}")
assert_json_field "impact-report: server=absent in fixture (no .claude/mcp)" \
    "$IR1_JSON" '.server' "absent"
IR1_FILE0=$(printf '%s' "$IR1_JSON" | jq -r '.files[0].file // empty' 2>/dev/null || echo "")
assert_eq "impact-report: changed file listed in files[]" \
    "src/seeded-change.ts" "$IR1_FILE0"
IR1_IMPACT0=$(printf '%s' "$IR1_JSON" | jq -r '.files[0].impact' 2>/dev/null || echo "?")
assert_eq "impact-report: per-file impact=null when server absent" \
    "null" "$IR1_IMPACT0"
# change_set_hash matches the canonical helper output (--hash-only).
IR1_HASH_RECORDED=$(printf '%s' "$IR1_JSON" | jq -r '.change_set_hash // empty' 2>/dev/null || echo "")
IR1_HASH_CURRENT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR_SCRIPT" --hash-only 2>/dev/null || echo "(script missing)")
assert_eq "impact-report: change_set_hash matches --hash-only" \
    "$IR1_HASH_CURRENT" "$IR1_HASH_RECORDED"

# 14. approve REFUSES (exit 2, structured error) when the artifact is
# missing. THE failing-first assertion: pre-fix, approve succeeds here.
rm -f "$IR1_REPORT"
IR1_RC=0
IR1_OUT=$(bash "$QG" approve "$TID_IR1" "Approve without artifact must refuse" 2>/dev/null) || IR1_RC=$?
assert_eq "impact-report: approve refuses without artifact (rc=2)" "2" "$IR1_RC"
# NB: assert_json_field can't assert a literal `false` (its `// empty`
# jq fallback swallows false), so match the envelope text directly.
assert_contains "impact-report: refusal ok=false" '"ok":false' "$IR1_OUT"
assert_json_field "impact-report: refusal error_key=impact_report_missing" \
    "$IR1_OUT" '.error_key' "impact_report_missing"
assert_contains "impact-report: refusal names the artifact path" \
    "impact-report-" "$IR1_OUT"
assert_contains "impact-report: refusal names the regenerate command" \
    "impact-report.sh" "$IR1_OUT"
assert_contains "impact-report: refusal names the bypass flag" \
    "--no-impact-report" "$IR1_OUT"
# Refusal must not have flipped any labels.
IR1_LABELS=$(cd "$FIXTURE" && bd show "$TID_IR1" --json 2>/dev/null | jq -r 'if type == "array" then .[0].labels else .labels end | join(",")')
IR1_APPROVED=$(printf '%s' ",$IR1_LABELS," | grep -c ',qa-approved,' || true)
IR1_APPROVED=$(printf '%s' "$IR1_APPROVED" | tr -d '[:space:]')
assert_eq "impact-report: refusal leaves qa-approved unset" "0" "$IR1_APPROVED"

# 15. approve refuses on STALE hash (changed-files mutated after the
# report was generated), and a regenerate clears the refusal.
TID_IR2=$(cd "$FIXTURE" && bd create "impact-report stale hash" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/first-edit.ts\n' > "$TRACK/changed-files.txt"
bash "$QG" enter "$TID_IR2" >/dev/null
printf 'src/second-edit-after-report.ts\n' >> "$TRACK/changed-files.txt"
IR2_RC=0
IR2_OUT=$(bash "$QG" approve "$TID_IR2" "Approve with stale artifact must refuse" 2>/dev/null) || IR2_RC=$?
assert_eq "impact-report: approve refuses on stale hash (rc=2)" "2" "$IR2_RC"
assert_json_field "impact-report: stale refusal error_key=impact_report_stale" \
    "$IR2_OUT" '.error_key' "impact_report_stale"
# Regenerate -> approve proceeds (server-absent report ACCEPTED).
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR_SCRIPT" "$TID_IR2" >/dev/null 2>&1 || true
IR2B_RC=0
IR2B_OUT=$(bash "$QG" approve "$TID_IR2" "Approve after regenerate" 2>/dev/null) || IR2B_RC=$?
assert_eq "impact-report: approve succeeds after regenerate (rc=0)" "0" "$IR2B_RC"
assert_json_field "impact-report: server-absent report accepted (status=approved)" \
    "$IR2B_OUT" '.status' "approved"
assert_contains "impact-report: approve observations record hash verification" \
    "impact-report verified" "$IR2B_OUT"

# 16. bypass: --no-impact-report '<reason>' approves despite a missing
# artifact; the reason lands in observations AND the approval comment.
TID_IR3=$(cd "$FIXTURE" && bd create "impact-report bypass" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/bypass-edit.ts\n' > "$TRACK/changed-files.txt"
bash "$QG" enter "$TID_IR3" >/dev/null
rm -f "$(report_path_for "$TID_IR3")"
IR3_RC=0
IR3_OUT=$(bash "$QG" approve "$TID_IR3" --no-impact-report "emergency: server bin quarantined by ops" "Bypass-path approval" 2>/dev/null) || IR3_RC=$?
assert_eq "impact-report: bypass approve succeeds (rc=0)" "0" "$IR3_RC"
assert_json_field "impact-report: bypass status=approved" "$IR3_OUT" '.status' "approved"
assert_contains "impact-report: bypass note in gate JSON observations" \
    "impact-bypass" "$IR3_OUT"
assert_contains "impact-report: bypass reason in gate JSON observations" \
    "emergency: server bin quarantined by ops" "$IR3_OUT"
IR3_CMT=$(cd "$FIXTURE" && bd show "$TID_IR3" --json 2>/dev/null \
    | jq -r 'if type == "array" then .[0].comments else .comments end // [] | map(select(.text | test("impact-report bypass"))) | length' 2>/dev/null || echo "0")
assert_eq "impact-report: bypass reason recorded in approval comment" "1" "$IR3_CMT"

# 17. META-TEST: strip the sentinel-wrapped refusal block from a copy of
# qa-gate.sh -> the approve-refusal assertion MUST fail under the copy
# (approve succeeds without the artifact). Proves the refusal block is
# load-bearing, not theatre. Mirrors qa-gate-baseline.sh Spec H.
REAL_QG=$(readlink "$QG" || printf '%s' "$QG")
QG_STRIPPED="$FIXTURE/qa-gate-stripped.sh"
STRIP_RC=0
awk '
    /# IMPACT-REPORT-REFUSAL BEGIN/ { skipping=1; found=1; next }
    /# IMPACT-REPORT-REFUSAL END/ { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$REAL_QG" > "$QG_STRIPPED" || STRIP_RC=$?
chmod +x "$QG_STRIPPED"
assert_eq "impact-report META: refusal sentinels present in qa-gate.sh" "0" "$STRIP_RC"
if [ "$STRIP_RC" -eq 0 ]; then
    TID_IR4=$(cd "$FIXTURE" && bd create "impact-report META strip" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    printf 'src/meta-edit.ts\n' > "$TRACK/changed-files.txt"
    bash "$QG" enter "$TID_IR4" >/dev/null
    rm -f "$(report_path_for "$TID_IR4")"
    IR4_RC=0
    IR4_OUT=$(bash "$QG_STRIPPED" approve "$TID_IR4" "Stripped copy must NOT refuse" 2>/dev/null) || IR4_RC=$?
    # Under the stripped copy the refusal disappears: approve succeeds.
    # (I.e., test 14's "rc=2" assertion would FAIL against this copy.)
    assert_eq "impact-report META: stripped copy approves without artifact (rc=0)" \
        "0" "$IR4_RC"
    assert_json_field "impact-report META: stripped copy status=approved" \
        "$IR4_OUT" '.status' "approved"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("impact-report META: could not run strip meta-test (sentinels missing)")
    printf '  FAIL: impact-report META: sentinels missing — strip meta-test skipped\n'
fi

[ "$FAIL" -eq 0 ]

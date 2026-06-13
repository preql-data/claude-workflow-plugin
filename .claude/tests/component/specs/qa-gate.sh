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

# ===========================================================================
# Mutation-survivor kill (G2.6ix / claude-workflow-plugin-llh.5).
#
# generate_impact_report's success guard (qa-gate.sh ~line 245):
#   if [ "$rc" -eq 0 ] && [ -s "$report" ]; then ... "Impact report generated"
# Re-sweep (.claude/.mutation-runs/20260613T102846Z) surfaced the F1 mutant
# `rc -ne 0` as a survivor: when impact-report.sh SUCCEEDS, the mutant skips
# the success branch and sets IMPACT_REPORT_OBS to the "impact-report.sh
# failed" WARNING even though the report WAS written — a misreport on enter's
# observation surface. The existing tests assert the artifact EXISTS but never
# assert enter's observation TEXT, so the mutant survived. Kill it by asserting
# enter's success observation on the (server-absent) happy path.
TID_GIR=$(cd "$FIXTURE" && bd create "generate_impact_report success obs" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/gir-edit.ts\n' > "$TRACK/changed-files.txt"
GIR_OUT=$(bash "$QG" enter "$TID_GIR" 2>/dev/null)
GIR_OBS=$(printf '%s' "$GIR_OUT" | jq -r '.observations // ""')
# Sanity: the artifact really was generated (so we're on the success path).
assert_eq "qa-gate mut(gen-impact L245): artifact present after enter (success path)" "0" \
    "$([ -f "$(report_path_for "$TID_GIR")" ] && echo 0 || echo 1)"
# id(L245): the success observation MUST report generation, NOT the failure WARNING.
assert_contains "qa-gate mut(gen-impact L245): enter obs reports 'Impact report generated' on success" \
    "Impact report generated" "$GIR_OBS"
GIR_FALSE_WARN=$(printf '%s' "$GIR_OBS" | grep -c 'impact-report.sh failed' || true)
GIR_FALSE_WARN=$(printf '%s' "$GIR_FALSE_WARN" | tr -d '[:space:]')
assert_eq "qa-gate mut(gen-impact L245): enter obs does NOT falsely warn 'failed' on success" \
    "0" "$GIR_FALSE_WARN"

# --- write_current_task helper-success guard (qa-gate.sh ~line 83) --------
# `if [ "$helper_rc" -eq 0 ] && [ -s ".../current-task" ]; then return 0; fi`
# Re-sweep survivor: the F1 mutant `helper_rc -ne 0` makes a SUCCESSFUL
# current-task.sh helper call skip the early return, so write_current_task
# logs a spurious "falling back to direct write" sync-error and does a
# redundant write. The file still lands (so existing tests pass), but the
# audit trail gains a false fallback record. Kill it: with a WORKING helper,
# sync-errors.log must NOT carry the fallback line.
TID_WCT=$(cd "$FIXTURE" && bd create "write_current_task helper-success" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
# Fresh sync-errors.log for a clean read.
: > "$TRACK/sync-errors.log"
bash "$QG" enter "$TID_WCT" >/dev/null 2>&1
# Sanity: helper path works in this fixture (current-task is written).
WCT_FILE_OK=$([ -s "$TRACK/current-task" ] && echo yes || echo no)
assert_eq "qa-gate mut(wct L83): current-task written (helper-success path exercised)" "yes" "$WCT_FILE_OK"
WCT_FELLBACK=$(grep -c 'falling back to direct write' "$TRACK/sync-errors.log" 2>/dev/null || true)
WCT_FELLBACK=$(printf '%s' "$WCT_FELLBACK" | tr -d '[:space:]')
assert_eq "qa-gate mut(wct L83): working helper does NOT log a spurious 'falling back' fallback" \
    "0" "$WCT_FELLBACK"

# --- write_current_task fallback-success guard (qa-gate.sh ~line 91) ------
# `if [ "$fallback_rc" -ne 0 ] || [ ! -s ".../current-task" ]; then return 1`
# Re-sweep survivor: the F1 mutant `fallback_rc -eq 0` makes a SUCCESSFUL
# direct-write fallback return 1 (false failure), so enter reports the
# "hooks will see no active task" WARNING even though current-task WAS
# written. Reaching the fallback needs the current-task.sh HELPER to FAIL
# first. qa-gate.sh resolves the helper at $PROJECT_DIR/.claude/scripts/
# current-task.sh, so we replace THAT symlink with a broken stub (exit 1,
# writes nothing) in a dedicated fixture, then assert: file written AND no
# false "no active task" warning.
mk_fixture
FIXTURE_FB="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
QG_FB="$FIXTURE_FB/.claude/scripts/qa-gate.sh"
TRACK_FB="$FIXTURE_FB/.claude/.qa-tracking"
# Replace the helper the gate actually invokes with a broken stub. Removing
# the symlink and writing a real file shadows the plugin's current-task.sh.
rm -f "$FIXTURE_FB/.claude/scripts/current-task.sh"
printf '#!/bin/bash\nexit 1\n' > "$FIXTURE_FB/.claude/scripts/current-task.sh"
chmod +x "$FIXTURE_FB/.claude/scripts/current-task.sh"
TID_FB=$(cd "$FIXTURE_FB" && bd create "write_current_task fallback-success" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
: > "$TRACK_FB/current-task"   # start empty so the fallback write is observable
FB_OUT=$(bash "$QG_FB" enter "$TID_FB" 2>/dev/null)
FB_OBS=$(printf '%s' "$FB_OUT" | jq -r '.observations // ""')
# Sanity: even via the broken helper, the direct-write fallback lands the file.
FB_FILE_OK=$([ -s "$TRACK_FB/current-task" ] && echo yes || echo no)
assert_eq "qa-gate mut(wct L91): broken helper -> fallback still writes current-task" "yes" "$FB_FILE_OK"
# id(L91): a SUCCESSFUL fallback must NOT report the 'no active task' failure.
FB_FALSE_WARN=$(printf '%s' "$FB_OBS" | grep -c 'hooks will see no active task' || true)
FB_FALSE_WARN=$(printf '%s' "$FB_FALSE_WARN" | tr -d '[:space:]')
assert_eq "qa-gate mut(wct L91): successful fallback does NOT falsely warn 'no active task'" \
    "0" "$FB_FALSE_WARN"

# ===========================================================================
# cmd_enter escalation/rubric label-cleanup cluster (G2.6ix / llh.5).
#
# Re-sweep (.claude/.mutation-runs/20260613T112947Z and ...102846Z) surfaced a
# CLUSTER of F1 survivors in cmd_enter's `was_escalated/was_deferred/
# was_rubric_satisfied` guards: lines ~396 (functional remove_escalation_
# labels), ~410 (functional remove_rubric_satisfied), ~426/429 (re-enter
# observation text), ~478/481 (new-enter observation text). escalation-binding's
# esc-resume re-enters a task carrying qa-DEFERRED, so the `|| [ was_deferred
# = 1 ]` clause short-circuits the guards true regardless of the FIRST clause's
# polarity — the qa-ESCALATED-only and rubric-satisfied isolations were never
# exercised. We isolate each clause:
#   - re-enter a task carrying ONLY qa-escalated  -> kills 396 (functional) + 426 (obs)
#   - re-enter a task carrying rubric-satisfied   -> kills 410 (functional) + 429 (obs)
#   - FRESH-enter a task pre-carrying qa-escalated + rubric-satisfied (no
#     qa-gate-entered yet) -> kills 478 + 481 (new-enter obs)
mk_fixture
FIXTURE_CL="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
QG_CL="$FIXTURE_CL/.claude/scripts/qa-gate.sh"
labels_join() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null || echo ""
}
has_lbl() { printf '%s' ",$(labels_join "$1")," | grep -q ",$2,"; }

# --- 396 (functional) + 426 (obs): re-enter w/ ONLY qa-escalated ----------
TID_ESC=$(cd "$FIXTURE_CL" && bd create "enter-clear qa-escalated" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_CL" enter "$TID_ESC" >/dev/null 2>&1          # sets qa-gate-entered (so the re-enter is idempotent path)
bd label add "$TID_ESC" qa-escalated >/dev/null 2>&1     # ONLY qa-escalated, NOT qa-deferred
ESC_OUT=$(bash "$QG_CL" enter "$TID_ESC" 2>/dev/null)    # re-enter
ESC_OBS=$(printf '%s' "$ESC_OUT" | jq -r '.observations // ""')
# id396 (functional): qa-escalated MUST be cleared by the re-enter.
ESC_STILL=$(has_lbl "$TID_ESC" "qa-escalated" && echo present || echo cleared)
assert_eq "qa-gate mut(enter L396): re-enter clears a qa-escalated-only task's escalation label" \
    "cleared" "$ESC_STILL"
# id426 (obs): the re-enter observation reports the escalation clear.
assert_contains "qa-gate mut(enter L426): re-enter obs reports 'cleared prior escalation labels'" \
    "cleared prior escalation labels" "$ESC_OBS"

# --- 410 (functional) + 429 (obs): re-enter w/ rubric-satisfied -----------
TID_RUB=$(cd "$FIXTURE_CL" && bd create "enter-clear rubric-satisfied" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_CL" enter "$TID_RUB" >/dev/null 2>&1
bd label add "$TID_RUB" rubric-satisfied >/dev/null 2>&1
RUB_OUT=$(bash "$QG_CL" enter "$TID_RUB" 2>/dev/null)
RUB_OBS=$(printf '%s' "$RUB_OUT" | jq -r '.observations // ""')
# id410 (functional): rubric-satisfied MUST be cleared by the re-enter.
RUB_STILL=$(has_lbl "$TID_RUB" "rubric-satisfied" && echo present || echo cleared)
assert_eq "qa-gate mut(enter L410): re-enter clears a stale rubric-satisfied label" \
    "cleared" "$RUB_STILL"
# id429 (obs): the re-enter observation reports the rubric clear.
assert_contains "qa-gate mut(enter L429): re-enter obs reports 'cleared stale rubric-satisfied'" \
    "cleared stale rubric-satisfied" "$RUB_OBS"

# --- 478 + 481 (new-enter obs): FRESH enter w/ labels pre-set -------------
# Pre-set qa-escalated + rubric-satisfied WITHOUT entering (no qa-gate-entered)
# so the first enter takes the NEW path and emits the extra_obs trailer.
TID_NE=$(cd "$FIXTURE_CL" && bd create "new-enter clears labels" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bd label add "$TID_NE" qa-escalated >/dev/null 2>&1
bd label add "$TID_NE" rubric-satisfied >/dev/null 2>&1
NE_OUT=$(bash "$QG_CL" enter "$TID_NE" 2>/dev/null)
NE_OBS=$(printf '%s' "$NE_OUT" | jq -r '.observations // ""')
# id478 (new-enter escalation obs).
assert_contains "qa-gate mut(enter L478): new-enter obs reports 'cleared prior escalation labels'" \
    "cleared prior escalation labels" "$NE_OBS"
# id481 (new-enter rubric obs).
assert_contains "qa-gate mut(enter L481): new-enter obs reports 'cleared stale rubric-satisfied'" \
    "cleared stale rubric-satisfied" "$NE_OBS"

# --- META-TEST: prove the L396 functional assertion is load-bearing -------
# Mutate line 396's guard to `was_escalated != "1"` in a copy, re-run the
# qa-escalated-only re-enter; the label must then remain (so the L396
# assertion would FAIL), confirming sensitivity.
REAL_QG_CL=$(readlink "$QG_CL" || printf '%s' "$QG_CL")
QG_CL_MUT="$FIXTURE_CL/qa-gate-enter396mut.sh"
awk 'NR==408 && /was_escalated" = "1"/ {print "    if [ \"$was_escalated\" != \"1\" ] || [ \"$was_deferred\" = \"1\" ]; then"; next} {print}' \
    "$REAL_QG_CL" > "$QG_CL_MUT"
chmod +x "$QG_CL_MUT"
QG_CL_MUT_LANDED=$(sed -n '408p' "$QG_CL_MUT" | grep -c 'was_escalated" != "1"' || true)
QG_CL_MUT_LANDED=$(printf '%s' "$QG_CL_MUT_LANDED" | tr -d '[:space:]')
assert_eq "qa-gate META: L396 guard mutation applied to copy" "1" "$QG_CL_MUT_LANDED"
TID_META396=$(cd "$FIXTURE_CL" && bd create "meta L396" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
CLAUDE_PROJECT_DIR="$FIXTURE_CL" bash "$QG_CL_MUT" enter "$TID_META396" >/dev/null 2>&1
bd label add "$TID_META396" qa-escalated >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$FIXTURE_CL" bash "$QG_CL_MUT" enter "$TID_META396" >/dev/null 2>&1
META396_STILL=$(has_lbl "$TID_META396" "qa-escalated" && echo present || echo cleared)
assert_eq "qa-gate META: under L396 mutant a qa-escalated-only re-enter leaves the label (L396 assertion WOULD fail)" \
    "present" "$META396_STILL"

# --- approve Step-3 rollback guard (qa-gate.sh ~line 680) -----------------
# `if [ "$removed_entered" = "1" ]; then add_label qa-gate-entered; fi`
# Re-sweep survivor: this branch only runs on the approve ROLLBACK path —
# when removing qa-pending fails after qa-gate-entered was already removed.
# The original re-adds qa-gate-entered to restore the pre-approve state; the
# F1 mutant `!= "1"` skips the re-add, leaving the task with NEITHER
# qa-gate-entered NOR qa-approved (a corrupt lifecycle state) after a failed
# approve. No test induced a mid-approve bd failure, so it survived. We inject
# it: a bd shim that fails ONLY `label remove <tid> qa-pending`, forcing the
# Step-3 rollback, then assert qa-gate-entered is restored.
mk_fixture
FIXTURE_RB="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
QG_RB="$FIXTURE_RB/.claude/scripts/qa-gate.sh"
TRACK_RB="$FIXTURE_RB/.claude/.qa-tracking"
# Selective bd shim: delegate to the real bd EXCEPT `label remove ... qa-pending`
# which exits 1. Overwrites the fixture's bd shim (same bin/ dir, on PATH).
REAL_BD_RB=$(command -v bd)
# command -v bd here resolves the fixture shim; read the real bd it wraps.
REAL_BD_RB=$(sed -n 's/^exec \(.*\) --no-daemon.*/\1/p' "$FIXTURE_RB/bin/bd" 2>/dev/null | tr -d '"' | head -1)
[ -z "$REAL_BD_RB" ] && REAL_BD_RB=$(command -v bd)
cat > "$FIXTURE_RB/bin/bd" <<EOF
#!/bin/bash
if [ "\$1" = "label" ] && [ "\$2" = "remove" ] && [ "\$4" = "qa-pending" ]; then exit 1; fi
exec $REAL_BD_RB --no-daemon "\$@"
EOF
chmod +x "$FIXTURE_RB/bin/bd"
TID_RB=$(cd "$FIXTURE_RB" && bd create "approve rollback" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/rb-edit.ts\n' > "$TRACK_RB/changed-files.txt"
bash "$QG_RB" enter "$TID_RB" >/dev/null 2>&1   # sets qa-gate-entered (+ generates impact report)
bd label add "$TID_RB" qa-pending >/dev/null 2>&1
# approve: add qa-approved OK, remove qa-gate-entered OK, remove qa-pending FAILS -> rollback -> exit 3.
RB_RC=0
bash "$QG_RB" approve "$TID_RB" "trigger Step-3 rollback" >/dev/null 2>&1 || RB_RC=$?
assert_eq "qa-gate mut(approve-rollback L680): failed approve exits 3 (atomic rollback)" "3" "$RB_RC"
# id680: the rollback MUST re-add qa-gate-entered (restore pre-approve state).
RB_ENTERED=$(has_lbl "$TID_RB" "qa-gate-entered" && echo present || echo absent)
assert_eq "qa-gate mut(approve-rollback L680): rollback re-adds qa-gate-entered (state restored)" \
    "present" "$RB_ENTERED"
# And qa-approved must NOT remain (it was rolled back).
RB_APPROVED=$(has_lbl "$TID_RB" "qa-approved" && echo present || echo absent)
assert_eq "qa-gate mut(approve-rollback L680): qa-approved rolled back" "absent" "$RB_APPROVED"

# ===========================================================================
# Change-set-bound approval record (G2 red-team / claude-workflow-plugin-llh.18).
#
# approve must write a TAMPER-EVIDENT record carrying the change_set_hash of
# the approved change-set — the binding that lets verify-before-stop.sh
# distinguish a real qa-gate.sh approve from a forged bare `bd label add
# qa-approved`. The hash MUST equal impact-report.sh --hash-only of the
# change-set that was current at approve time.
mk_fixture
FIXTURE_BIND="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
QG_BIND="$FIXTURE_BIND/.claude/scripts/qa-gate.sh"
IR_BIND="$FIXTURE_BIND/.claude/scripts/impact-report.sh"
TRACK_BIND="$FIXTURE_BIND/.claude/.qa-tracking"
bind_hash_of_record() {
    bd show "$1" --json 2>/dev/null \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text
                 | select(test("QA-GATE APPROVED .*change_set_hash="))
                 | capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h' 2>/dev/null | head -1
}
TID_BIND=$(cd "$FIXTURE_BIND" && bd create "approve writes bound record" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/bound-change.ts\n' > "$TRACK_BIND/changed-files.txt"
bash "$QG_BIND" enter "$TID_BIND" >/dev/null 2>&1   # generates a fresh impact report
# Capture the EXPECTED hash BEFORE approve runs — approve truncates
# changed-files.txt as a last step (0wk.2), so a post-approve --hash-only
# would return the empty-set hash, not the approved change-set's.
BIND_EXP_HASH=$(CLAUDE_PROJECT_DIR="$FIXTURE_BIND" bash "$IR_BIND" --hash-only 2>/dev/null || echo "")
BIND_OUT=$(bash "$QG_BIND" approve "$TID_BIND" "reviewed; binding test" 2>/dev/null)
assert_json_field "qa-gate llh18: approve succeeds (fresh report)" "$BIND_OUT" '.status' "approved"
# The approval comment carries a change_set_hash token.
BIND_REC_HASH=$(bind_hash_of_record "$TID_BIND")
assert_eq "qa-gate llh18: approve wrote a change_set_hash record" "0" \
    "$([ -n "$BIND_REC_HASH" ] && echo 0 || echo 1)"
# And that recorded hash equals the canonical --hash-only of the change-set
# that was current at approve time.
assert_eq "qa-gate llh18: recorded change_set_hash == impact-report.sh --hash-only (at approve time)" \
    "$BIND_EXP_HASH" "$BIND_REC_HASH"
# approve's observations surface the binding.
assert_contains "qa-gate llh18: approve obs reports the change-set binding" \
    "change-set-bound approval record written" "$BIND_OUT"

# Bypass path (--no-impact-report) still binds: the hash is the current
# change-set's, recorded even though the impact-report refusal was waived.
TID_BIND_BP=$(cd "$FIXTURE_BIND" && bd create "bypass still binds" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/bypass-bound.ts\n' > "$TRACK_BIND/changed-files.txt"
bash "$QG_BIND" enter "$TID_BIND_BP" >/dev/null 2>&1
rm -f "$TRACK_BIND/impact-report-$(printf '%s' "$TID_BIND_BP" | tr -c 'A-Za-z0-9._-' '_').json"
# Capture the expected hash before approve truncates the tracker.
BP_EXP_HASH=$(CLAUDE_PROJECT_DIR="$FIXTURE_BIND" bash "$IR_BIND" --hash-only 2>/dev/null || echo "")
BP_OUT=$(bash "$QG_BIND" approve "$TID_BIND_BP" --no-impact-report "ops emergency" "bypass approval" 2>/dev/null)
assert_json_field "qa-gate llh18: bypass approve succeeds" "$BP_OUT" '.status' "approved"
BP_REC_HASH=$(bind_hash_of_record "$TID_BIND_BP")
assert_eq "qa-gate llh18: bypass path still writes a matching change_set_hash record" \
    "$BP_EXP_HASH" "$BP_REC_HASH"

[ "$FAIL" -eq 0 ]

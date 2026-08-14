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
assert_match "qa-gate: seed task created" "$BD_ID_RE" "$TID"

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
# V3 (jio.1) MIGRATION: approve now REFUSES without an independent review
# artifact. Seed the real flow (backend implementer + qa-claude review, no
# findings) so this case still exercises the LABEL atomicity it was written
# for rather than dying at the new refusal.
seed_review_records "$TID2"

# 8. approve -> +qa-approved, -qa-gate-entered, -qa-pending, current-task cleared.
OUT=$(bash "$QG" approve "$TID2" "Looks good after review")
assert_json_field "qa-gate: approve ok=true" "$OUT" '.ok' "true"
assert_json_field "qa-gate: approve status=approved" "$OUT" '.status' "approved"
# V3 (jio.1): the approval names its reviewer, in the JSON and the record.
assert_contains "qa-gate: approve obs names the verified reviewer (V3)" \
    "independent review verified (reviewed_by=qa-claude" "$OUT"
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
seed_review_records "$TID_F4"    # V3 (jio.1) MIGRATION: approve needs a review artifact
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
# V3 (jio.1) MIGRATION: seeded AFTER the regenerate so the artifact's
# reviewed_hash matches the change-set this approval binds (no staleness
# warning); the case under test is still the impact-report freshness one.
seed_review_records "$TID_IR2"
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
# V3 (jio.1) MIGRATION: the case under test is the IMPACT bypass, so satisfy
# the (independent) review requirement legitimately rather than stacking a
# second bypass on top of it.
seed_review_records "$TID_IR3"
IR3_RC=0
IR3_OUT=$(bash "$QG" approve "$TID_IR3" --no-impact-report "emergency: server bin quarantined by ops" "Bypass-path approval" 2>/dev/null) || IR3_RC=$?
assert_eq "impact-report: bypass approve succeeds (rc=0)" "0" "$IR3_RC"
assert_json_field "impact-report: bypass status=approved" "$IR3_OUT" '.status' "approved"
assert_contains "impact-report: bypass note in gate JSON observations" \
    "impact-bypass" "$IR3_OUT"
assert_contains "impact-report: bypass reason in gate JSON observations" \
    "emergency: server bin quarantined by ops" "$IR3_OUT"
IR3_CMT=$(bd_show_with_comments "$TID_IR3" "$FIXTURE" \
    | jq -r 'if type == "array" then .[0].comments else .comments end // [] | map(select(.text | test("impact-report bypass"))) | length' 2>/dev/null || echo "0")
assert_eq "impact-report: bypass reason recorded in approval comment" "1" "$IR3_CMT"

# 17. META-TEST: strip the sentinel-wrapped refusal block from a copy of
# qa-gate.sh -> the approve-refusal assertion MUST fail under the copy
# (approve succeeds without the artifact). Proves the refusal block is
# load-bearing, not theatre. Mirrors qa-gate-baseline.sh Spec H.
REAL_QG=$(readlink "$QG" || printf '%s' "$QG")
# The copy lives in the fixture's `.claude/scripts/` — NOT the fixture root.
# Since 94d qa-gate.sh loads `workflow-denylist.sh` from its OWN directory
# (BASH_SOURCE-relative), so a copy parked anywhere else has no denylist,
# reconcile_tracker refuses, and approve exits 2 for a reason unrelated to the
# region under test. Same constraint the post-edit.sh spec's META documents.
QG_STRIPPED="$FIXTURE/.claude/scripts/qa-gate-stripped.sh"
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
    # V3 (jio.1) MIGRATION: the stripped copy loses ONLY the impact-report
    # refusal — its review-separation block is intact — so the review records
    # still have to be real for this META to isolate the impact sentinel.
    seed_review_records "$TID_IR4"
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
# TEXT-anchored (not line-number): mutate the FIRST occurrence of the functional
# escalation guard so this survives unrelated line shifts elsewhere in
# qa-gate.sh (e.g. the Phase V2 record-writer additions). The first match is the
# remove_escalation_labels guard in cmd_enter; the later occurrences (the
# re-enter obs + the new-enter path) are intentionally left intact.
awk 'guard_done!=1 && /was_escalated" = "1"/ {print "    if [ \"$was_escalated\" != \"1\" ] || [ \"$was_deferred\" = \"1\" ]; then"; guard_done=1; next} {print}' \
    "$REAL_QG_CL" > "$QG_CL_MUT"
chmod +x "$QG_CL_MUT"
QG_CL_MUT_LANDED=$(grep -c 'was_escalated" != "1"' "$QG_CL_MUT" || true)
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
# Anchored on the trailing `"$@"`, NOT on a bd flag: the wrapper ended
# `--no-daemon "$@"` until bd 1.1.2 removed that flag, and a pattern keyed to it
# returns empty on the new wrapper — which sends the fallback below to
# `command -v bd`, i.e. THIS shim, producing a wrapper that execs itself
# forever (a silent hang, not a failure). See lib/shim.sh's gz3 guard.
REAL_BD_RB=$(sed -n 's/^exec \(.*\) "\$@".*/\1/p' "$FIXTURE_RB/bin/bd" 2>/dev/null | tr -d '"' | head -1)
[ -z "$REAL_BD_RB" ] && REAL_BD_RB=$(command -v bd)
cat > "$FIXTURE_RB/bin/bd" <<EOF
#!/bin/bash
if [ "\$1" = "label" ] && [ "\$2" = "remove" ] && [ "\$4" = "qa-pending" ]; then exit 1; fi
exec $REAL_BD_RB "\$@"
EOF
chmod +x "$FIXTURE_RB/bin/bd"
TID_RB=$(cd "$FIXTURE_RB" && bd create "approve rollback" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/rb-edit.ts\n' > "$TRACK_RB/changed-files.txt"
bash "$QG_RB" enter "$TID_RB" >/dev/null 2>&1   # sets qa-gate-entered (+ generates impact report)
bd label add "$TID_RB" qa-pending >/dev/null 2>&1
# V3 (jio.1) MIGRATION: the rollback only happens at Step 3, so approve has to
# get PAST both refusals first — seed the review records.
seed_review_records "$TID_RB" "qa-claude" "backend" "$FIXTURE_RB"
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
    bd_show_with_comments "$1" \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text
                 | select(test("QA-GATE APPROVED .*change_set_hash="))
                 | capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h' 2>/dev/null | head -1
}
TID_BIND=$(cd "$FIXTURE_BIND" && bd create "approve writes bound record" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/bound-change.ts\n' > "$TRACK_BIND/changed-files.txt"
bash "$QG_BIND" enter "$TID_BIND" >/dev/null 2>&1   # generates a fresh impact report
seed_review_records "$TID_BIND" "qa-claude" "backend" "$FIXTURE_BIND"   # V3 (jio.1) MIGRATION
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
seed_review_records "$TID_BIND_BP" "qa-claude" "backend" "$FIXTURE_BIND"   # V3 (jio.1) MIGRATION
# Capture the expected hash before approve truncates the tracker.
BP_EXP_HASH=$(CLAUDE_PROJECT_DIR="$FIXTURE_BIND" bash "$IR_BIND" --hash-only 2>/dev/null || echo "")
BP_OUT=$(bash "$QG_BIND" approve "$TID_BIND_BP" --no-impact-report "ops emergency" "bypass approval" 2>/dev/null)
assert_json_field "qa-gate llh18: bypass approve succeeds" "$BP_OUT" '.status' "approved"
BP_REC_HASH=$(bind_hash_of_record "$TID_BIND_BP")
assert_eq "qa-gate llh18: bypass path still writes a matching change_set_hash record" \
    "$BP_EXP_HASH" "$BP_REC_HASH"

# ===========================================================================
# THE TRACKER-RECONCILE REFUSAL — error_key=tracker_unreconcilable
# (claude-workflow-plugin-94d; closes QA finding R2-F3).
#
# 94d added a hard refusal with NO bypass flag and shipped it with ZERO
# assertions at any of the three test layers, while its happy path
# (`reconcile-tracker` succeeding) appears in six specs. That asymmetry is the
# dangerous kind: a regression turning `return 1` into `return 0` would be
# SILENT — every happy-path spec stays green and the gate approves against a
# tracker it could not reconcile, which is exactly the P1 this task exists to
# close. So the refusal is asserted here, on both emitters, plus the two
# properties that make it worth having:
#
#   NO BYPASS.   `--no-impact-report` waives an ANALYSIS whose degradation is
#                documented. There is no comparable degraded mode for "we do not
#                know which files changed", so the flag must NOT reach this.
#   ORDERING.    reconcile runs BEFORE the impact-report refusal, deliberately:
#                the freshness check compares the report's hash against the
#                CURRENT one, and the reconcile is what makes "current" mean the
#                git-visible change set. With BOTH degraded, the error_key must
#                still be tracker_unreconcilable — if it were
#                impact_report_stale, the ordering had silently inverted.
#
# ONE VARIABLE. The cycle below is fully legitimate and READY to approve — a
# tracked change, a fresh impact report from `enter`, real review records — and
# then exactly one thing is removed: the shared denylist lib the reconcile needs
# to know which paths belong in the tracker. qa-gate.sh resolves it
# BASH_SOURCE-relative, so deleting the fixture's copy is a clean seam. The
# restore leg at the end puts it back and re-approves, which is what proves the
# refusal is caused by the missing lib rather than by anything else in the setup.
# ===========================================================================
mk_fixture
FIXTURE_TU="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
QG_TU="$FIXTURE_TU/.claude/scripts/qa-gate.sh"
TRACK_TU="$FIXTURE_TU/.claude/.qa-tracking"
LIB_TU="$FIXTURE_TU/.claude/scripts/workflow-denylist.sh"
tu_labels() {
    (cd "$FIXTURE_TU" && bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null) || echo ""
}
tu_report_for() {
    printf '%s/impact-report-%s.json' "$TRACK_TU" \
        "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

assert_eq "tracker-unreconcilable: the fixture lib is a symlink to the real plugin lib" "yes" \
    "$([ -L "$LIB_TU" ] && echo yes || echo no)"

TID_TU=$(cd "$FIXTURE_TU" && bd create "tracker reconcile refusal" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/tu-change.ts\n' > "$TRACK_TU/changed-files.txt"
bash "$QG_TU" enter "$TID_TU" >/dev/null 2>&1
seed_review_records "$TID_TU" "qa-claude" "backend" "$FIXTURE_TU"
assert_eq "tracker-unreconcilable: precondition — a fresh impact report exists" "0" \
    "$([ -f "$(tu_report_for "$TID_TU")" ] && echo 0 || echo 1)"

# --- THE ONE CHANGE -------------------------------------------------------
LIB_TU_REAL=$(readlink "$LIB_TU" 2>/dev/null || printf '%s' "$LIB_TU")
rm -f "$LIB_TU"
assert_eq "tracker-unreconcilable: the shared denylist lib is now absent" "gone" \
    "$([ -e "$LIB_TU" ] && echo present || echo gone)"

# 1. The subcommand form refuses (exit 2). This is the entry point
#    verify-before-stop.sh calls, so its rc IS the Stop hook's block trigger.
TU_SUB_RC=0
TU_SUB_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_TU" bash "$QG_TU" reconcile-tracker 2>/dev/null) || TU_SUB_RC=$?
assert_eq "tracker-unreconcilable: reconcile-tracker refuses with exit 2" "2" "$TU_SUB_RC"
# NB: assert_json_field cannot assert a literal `false` (its `// empty` jq
# fallback swallows it) — same workaround test 14 above documents.
assert_contains "tracker-unreconcilable: reconcile-tracker ok=false" '"ok":false' "$TU_SUB_OUT"
assert_json_field "tracker-unreconcilable: reconcile-tracker error_key" \
    "$TU_SUB_OUT" '.error_key' "tracker_unreconcilable"
assert_contains "tracker-unreconcilable: ...and the reason names the missing filter" \
    "workflow-denylist.sh" "$TU_SUB_OUT"
assert_contains "tracker-unreconcilable: ...and says callers must refuse to proceed" \
    "refuse to proceed" "$TU_SUB_OUT"

# 2. approve refuses with the SAME key — and writes NOTHING.
TU_AP_RC=0
TU_AP_OUT=$(bash "$QG_TU" approve "$TID_TU" "must not approve an unprovable change set" 2>/dev/null) || TU_AP_RC=$?
assert_eq "tracker-unreconcilable: approve refuses with exit 2" "2" "$TU_AP_RC"
assert_json_field "tracker-unreconcilable: approve error_key=tracker_unreconcilable" \
    "$TU_AP_OUT" '.error_key' "tracker_unreconcilable"
assert_contains "tracker-unreconcilable: approve's reason says the change set is unprovable" \
    "unprovable" "$TU_AP_OUT"
assert_contains "tracker-unreconcilable: ...and states there is no bypass flag" \
    "no bypass flag" "$TU_AP_OUT"
# THE PROPERTY THAT MATTERS: fail-closed. No label, no record.
assert_not_contains "tracker-unreconcilable: qa-approved was NOT added" \
    "qa-approved" "$(tu_labels "$TID_TU")"
TU_RECORDS=$(bd_show_with_comments "$TID_TU" "$FIXTURE_TU" \
    | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | map(.text) | join("\n")' 2>/dev/null)
assert_not_contains "tracker-unreconcilable: no QA-GATE APPROVED record was written" \
    "QA-GATE APPROVED" "$TU_RECORDS"

# 3. NO BYPASS: --no-impact-report does not waive it. If this ever returns
#    approved, the flag has grown a second meaning it was never given.
TU_BP_RC=0
TU_BP_OUT=$(bash "$QG_TU" approve "$TID_TU" --no-impact-report "ops emergency" "bypass must not cover this" 2>/dev/null) || TU_BP_RC=$?
assert_eq "tracker-unreconcilable: --no-impact-report still refuses (exit 2, NO bypass)" "2" "$TU_BP_RC"
assert_json_field "tracker-unreconcilable: ...with the same error_key" \
    "$TU_BP_OUT" '.error_key' "tracker_unreconcilable"
assert_not_contains "tracker-unreconcilable: ...and did NOT report approved" \
    "\"status\":\"approved\"" "$TU_BP_OUT"

# 4. ORDERING: with the impact report ALSO gone, the reconcile refusal still
#    wins. A tracker_unreconcilable answer here means reconcile ran first.
rm -f "$(tu_report_for "$TID_TU")"
TU_ORD_RC=0
TU_ORD_OUT=$(bash "$QG_TU" approve "$TID_TU" "both degraded at once" 2>/dev/null) || TU_ORD_RC=$?
assert_eq "tracker-unreconcilable: both degraded -> still exit 2" "2" "$TU_ORD_RC"
assert_json_field "tracker-unreconcilable: both degraded -> reconcile refusal WINS (ordering)" \
    "$TU_ORD_OUT" '.error_key' "tracker_unreconcilable"
assert_not_contains "tracker-unreconcilable: ...NOT impact_report_stale (would mean the order inverted)" \
    "impact_report_stale" "$TU_ORD_OUT"

# 5. ANTI-OVERREACH: a usage error is still a usage error, not a refusal. If
#    every non-zero path reported tracker_unreconcilable the assertions above
#    would pass for the wrong reason.
TU_FLAG_RC=0
TU_FLAG_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_TU" bash "$QG_TU" reconcile-tracker --nonsense 2>/dev/null) || TU_FLAG_RC=$?
assert_eq "tracker-unreconcilable: an unknown flag is exit 1, not the refusal" "1" "$TU_FLAG_RC"
assert_json_field "tracker-unreconcilable: ...with error_key=unknown_flag" \
    "$TU_FLAG_OUT" '.error_key' "unknown_flag"

# --- RESTORE + CONTROL: the missing lib was the cause ----------------------
# Nothing else about the cycle changes. `enter` regenerates the report deleted
# in leg 4; the review records are re-seeded because `enter` resets iteration
# state. If this leg did not go green, every refusal above could be an artefact
# of the setup rather than of the removal.
ln -sf "$LIB_TU_REAL" "$LIB_TU"
assert_eq "tracker-unreconcilable CONTROL: the lib is back" "present" \
    "$([ -e "$LIB_TU" ] && echo present || echo gone)"
printf 'src/tu-change.ts\n' > "$TRACK_TU/changed-files.txt"
bash "$QG_TU" enter "$TID_TU" >/dev/null 2>&1
seed_review_records "$TID_TU" "qa-claude" "backend" "$FIXTURE_TU"
TU_OK_RC=0
TU_OK_OUT=$(bash "$QG_TU" approve "$TID_TU" "reviewed; the reconcile can run again" 2>/dev/null) || TU_OK_RC=$?
assert_eq "tracker-unreconcilable CONTROL: the SAME approve now succeeds (rc=0)" "0" "$TU_OK_RC"
assert_json_field "tracker-unreconcilable CONTROL: status=approved" "$TU_OK_OUT" '.status' "approved"
assert_contains "tracker-unreconcilable CONTROL: and the observations report a reconcile ran" \
    "tracker reconcile" "$TU_OK_OUT"

# 6. THE DOCUMENTED NO-OP, so the refusal is not over-broad: on a NON-git tree
#    there is no delta to reconcile against and reconcile-tracker succeeds.
#    (The component fixture is not a git repo unless a spec makes it one.)
assert_eq "tracker-unreconcilable: the fixture is NOT a git repo (isolates the no-op arm)" \
    "no" "$(git -C "$FIXTURE_TU" rev-parse --git-dir >/dev/null 2>&1 && echo yes || echo no)"
TU_NG_RC=0
TU_NG_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_TU" bash "$QG_TU" reconcile-tracker 2>/dev/null) || TU_NG_RC=$?
assert_eq "tracker-unreconcilable: non-git tree is a NO-OP, rc=0 (not a refusal)" "0" "$TU_NG_RC"
assert_json_field "tracker-unreconcilable: ...and reports ok=true" "$TU_NG_OUT" '.ok' "true"
assert_contains "tracker-unreconcilable: ...naming why (no git-visible delta)" \
    "not a git checkout" "$TU_NG_OUT"

# ===========================================================================
# THE TERMINAL-LABEL TRANSITION — 8zi, l1r.3, jue.
#
# THREE FILED DEFECTS, ONE STATE MODEL. They are tested together because the
# first two cannot be tested apart:
#
#   8zi   approve did not clear a prior cycle's qa-blocked, so a
#         block -> fix -> approve round trip ended with BOTH terminal labels set.
#         Observed live four times (uvk, q7n, 94d, and qzv.1 — where the gate's
#         own reviewer removed the label BY HAND mid-approval and said so).
#   l1r.3 remove_label was a bare `bd label remove ... >/dev/null 2>&1`. MEASURED
#         on bd 1.1.2, that command exits 0 for a label the task never had AND
#         for a task id that does not exist. So every rollback in qa-gate.sh that
#         branched on it was decorative, INCLUDING the ones 8zi's fix adds. This
#         is why the removal verifies first and why it is asserted directly.
#   jue   enter did not clear a prior cycle's qa-approved, so a label-polling
#         reader read a previous cycle's verdict as a verdict on new commits.
#
# WHAT EACH LEG BUYS, and the discipline behind the shape of these assertions:
# the reason 8zi survived four live sightings is that the existing coverage
# asserted the PRESENCE of qa-approved after an approve. Presence is satisfiable
# by a task carrying every label in the lifecycle at once. So every leg below
# asserts the COMPLETE final label set, byte-for-byte, never a substring.
#
# bd's own ordering makes that a set comparison: MEASURED on bd 1.1.2, labels come
# back sorted, and a remove-then-re-add reproduces the identical joined string.
# ===========================================================================
# depoison_bd <fixture-root> — point this fixture's bd wrapper at the REAL bd.
#
# A MEASURED HARNESS HAZARD, not a precaution. mk_fixture prepends <root>/bin to
# PATH, and mk_bd_shim builds each wrapper from `command -v bd` — which, once any
# earlier fixture in the same spec shell has REPLACED its own bin/bd, resolves to
# that replacement. The new fixture is then generated as
# `exec <other-fixture>/bin/bd "$@"` and INHERITS the other section's selective
# failure. Directly observed while diagnosing this section: with fixture A's
# wrapper replaced by a shim that fails `label remove <tid> qa-pending`, a fixture
# B created afterwards returns rc=1 from that same removal and the label survives.
#
# THE POISONER IN THIS SPEC is the pre-existing approve Step-3 rollback section
# above, whose shim fails exactly `label remove ... qa-pending`. It stayed latent
# for two later sections because neither removed qa-pending — and this section's
# whole subject is a sweep that does. The resulting symptom is indistinguishable
# from a real defect: approve exits 3 because the removal genuinely did not happen
# and remove_label's read-back correctly refuses to claim it did.
#
# Which is the reason this helper exists rather than a loosened check: the
# verification was right and the FIXTURE was lying. Follow the `exec <path> "$@"`
# chain to the binary at the end of it and write a one-hop wrapper, so the shims
# installed further down sit directly on top of a real bd.
#
# Filed as a harness defect in its own right; fixing mk_bd_shim to resolve the
# chain would remove the trap for every future spec, but that is a shared-harness
# change needing a full-tier run, not a change this spec can validate.
depoison_bd() {
    # One `local` per line, deliberately: this tier runs under `bash -u`, and bash
    # expands every word of a `local` command BEFORE binding any of them, so
    # `local root="$1" p="$root/bin/bd"` reads an unbound $root and aborts the spec.
    local root="$1"
    local p="$root/bin/bd"
    local next=""
    local guard=0
    while [ -f "$p" ] && [ "$guard" -lt 16 ]; do
        next=$(sed -n 's/^exec \(.*\) "\$@".*/\1/p' "$p" 2>/dev/null | tr -d "\"'" | head -1)
        [ -n "$next" ] || break
        p="$next"
        guard=$((guard + 1))
    done
    [ -n "$p" ] && [ -x "$p" ] || return 1
    printf '#!/bin/bash\nexec %q "$@"\n' "$p" > "$root/bin/bd"
    chmod +x "$root/bin/bd"
}
# bd_wrapper_state <root> — "clean" when the wrapper execs something outside any
# component fixture, "poisoned" when it chains into another fixture's shim.
bd_wrapper_state() {
    grep '^exec' "$1/bin/bd" 2>/dev/null | grep -q 'component-fixture' \
        && echo poisoned || echo clean
}

mk_fixture
FIXTURE_TL="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
assert_eq "8zi-0: the inherited bd wrapper IS poisoned by an earlier section (the hazard is real, not hypothetical)" \
    "poisoned" "$(bd_wrapper_state "$FIXTURE_TL")"
depoison_bd "$FIXTURE_TL"
assert_eq "8zi-0: ...and this section's wrapper now execs a real bd" \
    "clean" "$(bd_wrapper_state "$FIXTURE_TL")"
QG_TL="$FIXTURE_TL/.claude/scripts/qa-gate.sh"
QG_TL_REAL=$(readlink "$QG_TL" 2>/dev/null || printf '%s' "$QG_TL")
TRACK_TL="$FIXTURE_TL/.claude/.qa-tracking"

# labels_in <root> <tid> — the comma-joined set, in bd's own (sorted) order.
labels_in() {
    (cd "$1" && bd show "$2" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null) \
        || echo ""
}
tl_labels() { labels_in "$FIXTURE_TL" "$1"; }
# tl_new <title> -> a fresh task id in FIXTURE_TL.
tl_new() {
    (cd "$FIXTURE_TL" && bd create "$1" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
}
# tl_add <tid> <label>...
tl_add() {
    local t="$1"; shift
    local l
    for l in "$@"; do (cd "$FIXTURE_TL" && bd label add "$t" "$l" >/dev/null 2>&1) || true; done
}
tl_del() {
    local t="$1"; shift
    local l
    for l in "$@"; do (cd "$FIXTURE_TL" && bd label remove "$t" "$l" >/dev/null 2>&1) || true; done
}
# tl_arm <tid> <changed-file> — the state approve REQUIRES: a tracked change, a
# fresh impact report (written by enter), and real review records. Without all
# three approve refuses at an unrelated gate and the leg measures nothing.
tl_arm() {
    printf '%s\n' "$2" > "$TRACK_TL/changed-files.txt"
    bash "$QG_TL" enter "$1" >/dev/null 2>&1 || true
    seed_review_records "$1" "qa-claude" "backend" "$FIXTURE_TL"
}

# --- 8zi-1: the live y4a.13 five-label shape -------------------------------
# Not a hypothetical seed. `bd show claude-workflow-plugin-y4a.13` carries
# exactly this set today: devops, qa-approved, qa-blocked, qa-gate-entered,
# qa-pending — both terminal labels and both in-flight labels on one task.
TID_TL1=$(tl_new "8zi: the y4a.13 five-label shape")
tl_arm "$TID_TL1" "src/8zi-a.ts"
# enter arms rubric-pending; y4a.13 predates Phase A, so drop it to seed the
# recorded shape EXACTLY rather than approximately.
tl_del "$TID_TL1" rubric-pending
tl_add "$TID_TL1" devops qa-pending qa-blocked qa-approved
assert_eq "8zi-1: seeded the live y4a.13 five-label shape" \
    "devops,qa-approved,qa-blocked,qa-gate-entered,qa-pending" "$(tl_labels "$TID_TL1")"
TL1_RC=0
TL1_OUT=$(bash "$QG_TL" approve "$TID_TL1" "8zi: one approve must end the whole cycle" 2>/dev/null) || TL1_RC=$?
assert_eq "8zi-1: approve succeeds (rc=0)" "0" "$TL1_RC"
assert_json_field "8zi-1: status=approved" "$TL1_OUT" '.status' "approved"
# THE ASSERTION 8zi survived four sightings for want of: the FULL final set.
assert_eq "8zi-1: final label set is EXACTLY {devops,qa-approved} — qa-blocked is GONE" \
    "devops,qa-approved" "$(tl_labels "$TID_TL1")"
TL1_OBS=$(printf '%s' "$TL1_OUT" | jq -r '.observations // ""')
assert_contains "8zi-1: the envelope names the labels the sweep cleared" \
    "cycle labels cleared:" "$TL1_OBS"
assert_contains "8zi-1: ...and qa-blocked is among them" "qa-blocked" "$TL1_OBS"
# THE ENVELOPE TOKENS. Pinned here because the 8zi sweep rewrote the code that
# emits them, and because a full-tree search for either literal found NO consumer
# anywhere — not a spec, not a doc, not an agent prompt, not a hook; only this
# emitter and its synced fixture copies. The plan's claim that "specs and
# operators grep them" is false for specs, so until this assertion existed
# nothing would have caught their removal. Operator-facing output stability is
# the real reason to keep them; this is the mechanism that keeps them.
assert_contains "8zi-1: the approve envelope still carries the literal 'removed qa-gate-entered=' token" \
    "removed qa-gate-entered=1" "$TL1_OUT"
assert_contains "8zi-1: ...and the literal 'qa-pending=' token, with the same counter semantics" \
    "qa-pending=1" "$TL1_OUT"
# status precedence resolved the old contradiction to `approved`, so it was never
# the symptom — the label set was. It must still read approved.
assert_json_field "8zi-1: status still reads approved" \
    "$(bash "$QG_TL" status "$TID_TL1")" '.status' "approved"

# --- 8zi-2: rubric-satisfied is NOT swept ---------------------------------
# The complement of 8zi-1, and the half that would make this fix a regression if
# it were wrong: rubric-satisfied is the audit trail of the grader verdict that
# backed the approval. It is deliberately absent from QA_CYCLE_LABELS, so the
# sweep cannot reach it even if a future call site asked.
TID_TL2=$(tl_new "8zi: rubric-satisfied survives the sweep")
tl_arm "$TID_TL2" "src/8zi-b.ts"
tl_add "$TID_TL2" devops qa-blocked rubric-satisfied
assert_eq "8zi-2: seeded a blocked task with BOTH rubric labels" \
    "devops,qa-blocked,qa-gate-entered,rubric-pending,rubric-satisfied" \
    "$(tl_labels "$TID_TL2")"
TL2_OUT=$(bash "$QG_TL" approve "$TID_TL2" "8zi: keep the verdict, clear the cycle" 2>/dev/null)
assert_json_field "8zi-2: approve succeeds" "$TL2_OUT" '.status' "approved"
assert_eq "8zi-2: rubric-PENDING swept, rubric-SATISFIED kept, qa-blocked gone" \
    "devops,qa-approved,rubric-satisfied" "$(tl_labels "$TID_TL2")"
assert_contains "8zi-2: ...and the envelope still calls it the audit trail" \
    "rubric-satisfied preserved (audit trail)" "$TL2_OUT"

# --- 8zi-3: the block leg, and the fail-OPEN twin -------------------------
# 8zi's own direction (a surviving qa-blocked) is fail-closed noise: every label
# reader in the tree tests qa-approved FIRST — cmd_status, epic-gate.sh's
# qa_state_of, and statusline.sh's two readers — so the contradiction resolves to
# `approved` and nothing releases wrongly. The REVERSE direction is not cosmetic:
# a block that leaves a prior qa-approved standing makes all four readers report
# a BLOCKED task as APPROVED. That is why block gets the sweep too.
#
# Both halves in one leg, per the prose rule: what block clears AND what it
# preserves. Clearing more than qa-approved would break the documented "Keeps
# qa-gate-entered" contract and silently end the rubric loop mid-cycle.
TID_TL3=$(tl_new "8zi: block clears qa-approved and nothing else")
bash "$QG_TL" enter "$TID_TL3" >/dev/null 2>&1
tl_add "$TID_TL3" devops qa-pending qa-approved
assert_eq "8zi-3: seeded a stale qa-approved on top of an OPEN cycle" \
    "devops,qa-approved,qa-gate-entered,qa-pending,rubric-pending" "$(tl_labels "$TID_TL3")"
assert_json_field "8zi-3: precondition — status reads APPROVED on a task about to be blocked" \
    "$(bash "$QG_TL" status "$TID_TL3")" '.status' "approved"
TL3_OUT=$(bash "$QG_TL" block "$TID_TL3" "8zi: a block must not leave an approval standing" 2>/dev/null)
assert_json_field "8zi-3: block status=blocked" "$TL3_OUT" '.status' "blocked"
assert_eq "8zi-3: block clears qa-approved — and every in-flight label SURVIVES" \
    "devops,qa-blocked,qa-gate-entered,qa-pending,rubric-pending" "$(tl_labels "$TID_TL3")"
assert_contains "8zi-3: the block envelope reports the cleared prior approval" \
    "cleared a prior cycle's [qa-approved]" "$TL3_OUT"
assert_contains "8zi-3: ...and still records that qa-gate-entered is preserved" \
    "qa-gate-entered preserved if present" "$TL3_OUT"
# THE FAIL-OPEN, closed: the same status read now reports blocked.
assert_json_field "8zi-3: status now reads BLOCKED (it read approved one line above)" \
    "$(bash "$QG_TL" status "$TID_TL3")" '.status' "blocked"

# --- jue-4a: enter clears a prior approval — the FRESH arm ----------------
TID_TL4=$(tl_new "jue: enter clears a prior cycle's approval (fresh arm)")
tl_arm "$TID_TL4" "src/jue-a.ts"
tl_add "$TID_TL4" devops
tl_del "$TID_TL4" rubric-pending
bash "$QG_TL" approve "$TID_TL4" "jue: first cycle's approval" >/dev/null 2>&1
assert_eq "jue-4a: precondition — approve left qa-approved and cleared qa-gate-entered" \
    "devops,qa-approved" "$(tl_labels "$TID_TL4")"
TL4_OUT=$(bash "$QG_TL" enter "$TID_TL4" 2>/dev/null)
assert_json_field "jue-4a: the re-enter succeeds" "$TL4_OUT" '.status' "entered"
assert_eq "jue-4a: the FRESH arm clears the prior cycle's qa-approved" \
    "devops,qa-gate-entered,rubric-pending" "$(tl_labels "$TID_TL4")"
assert_contains "jue-4a: ...and the envelope gives the fresh arm's reason" \
    "a fresh gate cycle supersedes the previous cycle's approval" "$TL4_OUT"

# --- jue-4b: enter clears a prior approval — the EARLY-RETURN arm ---------
# The arm the brief flags as the trap: it returns before the fresh-cycle code and
# writes NO cycle record. Combined with rmz (bd 1.1.2 `create --parent` inherits
# every gate label, transitively) a task can be BORN carrying qa-gate-entered and
# never be entered at all — qzv.2 is in that state today. So this seed is the real
# provenance, not a contrivance: labels applied without any enter having run.
TID_TL4B=$(tl_new "jue: enter clears a prior approval (early-return arm)")
tl_add "$TID_TL4B" devops qa-gate-entered qa-approved
assert_eq "jue-4b: seeded the rmz inheritance shape — entered-looking, never entered" \
    "devops,qa-approved,qa-gate-entered" "$(tl_labels "$TID_TL4B")"
TL4B_OUT=$(bash "$QG_TL" enter "$TID_TL4B" 2>/dev/null)
assert_json_field "jue-4b: the enter succeeds" "$TL4B_OUT" '.status' "entered"
assert_contains "jue-4b: ...and takes the early-return arm" \
    "qa-gate-entered already set" "$TL4B_OUT"
assert_eq "jue-4b: the EARLY-RETURN arm clears qa-approved too" \
    "devops,qa-gate-entered,rubric-pending" "$(tl_labels "$TID_TL4B")"
# The two arms give DIFFERENT reasons, and the difference is the finding: this
# pair is unreachable through the gate's own transitions, so it did not come from
# an approve of the open cycle.
assert_contains "jue-4b: ...for the early-return arm's OWN reason, not the fresh arm's" \
    "unreachable through the gate's own transitions" "$TL4B_OUT"

# ---------------------------------------------------------------------------
# 8zi-META: strip the TERMINAL-LABEL-SWEEP regions -> qa-blocked survives.
#
# The sentinel regions contain ONLY the delta — one `sweep_clear+=(qa-blocked)` in
# approve and one `block_clear+=(qa-approved)` in block. The unified function and
# its snapshot/restore sit OUTSIDE them deliberately, on the same discipline as
# worktree_field's empty default: a strip must leave a copy that still performs a
# coherent PRE-8zi approve. Had the function been inside, the stripped copy could
# not approve at all and "qa-blocked survived" would pass for the wrong reason.
#
# So this META asserts three things, and the middle one is what makes the other
# two mean anything: the stripped copy still approves, it STILL removes
# qa-gate-entered and qa-pending, and qa-blocked SURVIVES.
# ---------------------------------------------------------------------------
QG_TL_NOSWEEP="$FIXTURE_TL/.claude/scripts/qa-gate-nosweep.sh"
NOSWEEP_RC=0
# Anchored `^ *#` for the reason QA finding R4-F5 gives: unanchored, the pattern
# matches the sentinel name anywhere on a line, so a prose line quoting it
# mid-sentence starts the excision early and deletes real code above the region.
# This spec's own header quotes the region name, and so does qa-gate.sh's.
awk '
    /^ *# TERMINAL-LABEL-SWEEP BEGIN/ { skip = 1; found = 1; next }
    /^ *# TERMINAL-LABEL-SWEEP END/   { skip = 0; next }
    !skip { print }
    END { if (!found) exit 7 }
' "$QG_TL_REAL" > "$QG_TL_NOSWEEP" || NOSWEEP_RC=$?
chmod +x "$QG_TL_NOSWEEP" 2>/dev/null || true
assert_eq "8zi-META: the TERMINAL-LABEL-SWEEP sentinels are present in qa-gate.sh" "0" "$NOSWEEP_RC"
if assert_mutant_applied "8zi-META" "$QG_TL_REAL" "$QG_TL_NOSWEEP"; then
    NOSWEEP_PARSE=0
    bash -n "$QG_TL_NOSWEEP" 2>/dev/null || NOSWEEP_PARSE=$?
    assert_eq "8zi-META: the stripped copy still parses (it must fail for the reason under test)" \
        "0" "$NOSWEEP_PARSE"
    TID_MS=$(tl_new "8zi META: stripped copy leaves qa-blocked")
    printf 'src/8zi-meta.ts\n' > "$TRACK_TL/changed-files.txt"
    bash "$QG_TL" enter "$TID_MS" >/dev/null 2>&1
    seed_review_records "$TID_MS" "qa-claude" "backend" "$FIXTURE_TL"
    tl_del "$TID_MS" rubric-pending
    tl_add "$TID_MS" devops qa-pending qa-blocked
    assert_eq "8zi-META: seeded the same shape 8zi-1 approves cleanly" \
        "devops,qa-blocked,qa-gate-entered,qa-pending" "$(tl_labels "$TID_MS")"
    MS_RC=0
    MS_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_TL" bash "$QG_TL_NOSWEEP" approve "$TID_MS" \
        "stripped copy must still approve" 2>/dev/null) || MS_RC=$?
    # NON-VACUITY: the stripped copy is a working pre-8zi approve, not a broken one.
    assert_eq "8zi-META: the stripped copy STILL approves (rc=0) — the strip removed the sweep, not approve" \
        "0" "$MS_RC"
    assert_json_field "8zi-META: ...reporting status=approved" "$MS_OUT" '.status' "approved"
    # ISOLATION: everything the pre-8zi approve cleared, it still clears.
    assert_contains "8zi-META: ...and still removes qa-gate-entered and qa-pending" \
        "removed qa-gate-entered=1 qa-pending=1" "$MS_OUT"
    # THE DEFECT, reproduced: 8zi-1's exact-set assertion WOULD fail here.
    assert_eq "8zi-META: qa-blocked SURVIVES the stripped approve (8zi-1 WOULD fail)" \
        "devops,qa-approved,qa-blocked" "$(tl_labels "$TID_MS")"
    # The block half of the same delta: the stripped copy leaves the approval
    # standing, so the fail-open 8zi-3 closes comes back.
    TID_MSB=$(tl_new "8zi META: stripped block leaves qa-approved")
    tl_add "$TID_MSB" devops qa-approved
    CLAUDE_PROJECT_DIR="$FIXTURE_TL" bash "$QG_TL_NOSWEEP" block "$TID_MSB" \
        "stripped copy must not clear the approval" >/dev/null 2>&1 || true
    assert_eq "8zi-META: the stripped block leaves qa-approved set alongside qa-blocked" \
        "devops,qa-approved,qa-blocked" "$(tl_labels "$TID_MSB")"
    assert_json_field "8zi-META: ...so status reports APPROVED on a blocked task (8zi-3 WOULD fail)" \
        "$(CLAUDE_PROJECT_DIR="$FIXTURE_TL" bash "$QG_TL_NOSWEEP" status "$TID_MSB")" \
        '.status' "approved"
fi

# ---------------------------------------------------------------------------
# jue-META: revert cmd_enter's qa-approved clear -> the label survives an enter.
# ---------------------------------------------------------------------------
QG_TL_NOJUE="$FIXTURE_TL/.claude/scripts/qa-gate-nojue.sh"
NOJUE_RC=0
awk '
    /^        if remove_label "\$tid" "qa-approved"; then$/ {
        print "        if false; then"; found = 1; next
    }
    { print }
    END { if (!found) exit 7 }
' "$QG_TL_REAL" > "$QG_TL_NOJUE" || NOJUE_RC=$?
chmod +x "$QG_TL_NOJUE" 2>/dev/null || true
assert_eq "jue-META: the enter-side clear was located and mutated" "0" "$NOJUE_RC"
if assert_mutant_applied "jue-META" "$QG_TL_REAL" "$QG_TL_NOJUE"; then
    NOJUE_PARSE=0
    bash -n "$QG_TL_NOJUE" 2>/dev/null || NOJUE_PARSE=$?
    assert_eq "jue-META: the mutated copy still parses" "0" "$NOJUE_PARSE"
    TID_MJ=$(tl_new "jue META: mutant leaves qa-approved")
    tl_add "$TID_MJ" devops qa-gate-entered qa-approved
    CLAUDE_PROJECT_DIR="$FIXTURE_TL" bash "$QG_TL_NOJUE" enter "$TID_MJ" >/dev/null 2>&1 || true
    assert_eq "jue-META: under the mutant a prior qa-approved SURVIVES the enter (4a/4b WOULD fail)" \
        "devops,qa-approved,qa-gate-entered,rubric-pending" "$(tl_labels "$TID_MJ")"
fi

# ===========================================================================
# l1r.3 — the removal that verifies.
#
# A SEPARATE FIXTURE because the seam is a bd shim, and it is the one that must
# not leak into any other leg: `bd label remove` exits 0 and does nothing. That is
# not a contrived failure, it is the SHAPE l1r.3 records (a removal that reports
# success and did not happen) reproduced deterministically. The bd-level cause in
# l1r.3's own reproduction is a stale-JSONL auto-import; this shim reproduces the
# observable, which is what a test can assert on.
# ===========================================================================
mk_fixture
FIXTURE_L13="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
depoison_bd "$FIXTURE_L13"
assert_eq "l1r.3-6: this fixture's bd wrapper execs a real bd (so the shim below is the ONLY seam)" \
    "clean" "$(bd_wrapper_state "$FIXTURE_L13")"
QG_L13="$FIXTURE_L13/.claude/scripts/qa-gate.sh"
QG_L13_REAL=$(readlink "$QG_L13" 2>/dev/null || printf '%s' "$QG_L13")
TRACK_L13="$FIXTURE_L13/.claude/.qa-tracking"

# A dispatch-stripped copy, so remove_label can be called DIRECTLY. It lives in
# .claude/scripts/ because qa-gate.sh resolves workflow-denylist.sh relative to
# its own BASH_SOURCE; a copy parked elsewhere takes a degraded path.
QG_L13_LIB="$FIXTURE_L13/.claude/scripts/qa-gate-lib.sh"
L13_LIB_RC=0
awk '/^SUB="\$\{1:-\}"$/ { found = 1; exit } { print } END { if (!found) exit 7 }' \
    "$QG_L13_REAL" > "$QG_L13_LIB" || L13_LIB_RC=$?
assert_eq "l1r.3-6: the dispatch anchor was found (sourceable copy built)" "0" "$L13_LIB_RC"
L13_LIB_PARSE=0
bash -n "$QG_L13_LIB" 2>/dev/null || L13_LIB_PARSE=$?
assert_eq "l1r.3-6: the sourceable copy parses" "0" "$L13_LIB_PARSE"

TID_L13=$(cd "$FIXTURE_L13" && bd create "l1r.3: remove_label verifies" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
(cd "$FIXTURE_L13" && bd label add "$TID_L13" qa-blocked >/dev/null 2>&1) || true

# CONTROL first — the other half of the claim. With a WORKING bd, remove_label
# must return ZERO and the label must be gone. Without this leg "returns
# non-zero" is satisfiable by a function that always fails.
L13_OK_RC=0
( CLAUDE_PROJECT_DIR="$FIXTURE_L13"; . "$QG_L13_LIB" >/dev/null 2>&1
  remove_label "$TID_L13" "qa-blocked" ) >/dev/null 2>&1 || L13_OK_RC=$?
assert_eq "l1r.3-6b CONTROL: remove_label returns 0 when the removal really happens" "0" "$L13_OK_RC"
assert_eq "l1r.3-6b CONTROL: ...and the label is actually gone" "" "$(labels_in "$FIXTURE_L13" "$TID_L13")"

# --- THE ONE CHANGE: bd's removals now exit 0 and do nothing ---------------
REAL_BD_L13=$(sed -n 's/^exec \(.*\) "\$@".*/\1/p' "$FIXTURE_L13/bin/bd" 2>/dev/null | tr -d '"' | head -1)
[ -z "$REAL_BD_L13" ] && REAL_BD_L13=$(command -v bd)
cat > "$FIXTURE_L13/bin/bd" <<EOF
#!/bin/bash
# l1r.3 shim: report success for every label removal, perform none of them.
if [ "\$1" = "label" ] && [ "\$2" = "remove" ]; then exit 0; fi
exec $REAL_BD_L13 "\$@"
EOF
chmod +x "$FIXTURE_L13/bin/bd"
(cd "$FIXTURE_L13" && bd label add "$TID_L13" qa-blocked >/dev/null 2>&1) || true
assert_eq "l1r.3-6a: precondition — the label is back and the shim is installed" \
    "qa-blocked" "$(labels_in "$FIXTURE_L13" "$TID_L13")"
L13_BAD_RC=0
( CLAUDE_PROJECT_DIR="$FIXTURE_L13"; . "$QG_L13_LIB" >/dev/null 2>&1
  remove_label "$TID_L13" "qa-blocked" ) >/dev/null 2>&1 || L13_BAD_RC=$?
assert_eq "l1r.3-6a: remove_label returns NON-ZERO when bd's removal silently no-ops" \
    "nonzero" "$([ "$L13_BAD_RC" -ne 0 ] && echo nonzero || echo zero)"
assert_eq "l1r.3-6a: ...because the label is still there" \
    "qa-blocked" "$(labels_in "$FIXTURE_L13" "$TID_L13")"

# --- l1r.3-6c: and therefore approve REFUSES instead of lying -------------
# The end-to-end consequence, and the reason this defect had to be fixed before
# 8zi's sweep: with an unverified removal, approve reported
# `removed qa-gate-entered=1` for a removal that never happened.
TID_L13B=$(cd "$FIXTURE_L13" && bd create "l1r.3: approve refuses on an unprovable removal" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/l1r3.ts\n' > "$TRACK_L13/changed-files.txt"
CLAUDE_PROJECT_DIR="$FIXTURE_L13" bash "$QG_L13" enter "$TID_L13B" >/dev/null 2>&1 || true
seed_review_records "$TID_L13B" "qa-claude" "backend" "$FIXTURE_L13"
L13C_RC=0
L13C_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_L13" bash "$QG_L13" approve "$TID_L13B" \
    "l1r.3: the sweep cannot be proven" 2>/dev/null) || L13C_RC=$?
assert_eq "l1r.3-6c: approve exits 3 when a sweep removal cannot be proven" "3" "$L13C_RC"
# assert_CONTAINS, not assert_json_field, and the reason is a harness constraint
# worth stating so nobody "fixes" the envelope: assert_json_field extracts with
# `jq -r '<path> // empty'`, and jq's `//` treats FALSE exactly like absent — so
# `.ok // empty` on {"ok":false,...} prints nothing and the comparison can never
# see `false`. Verified directly. Every existing assert_json_field '.ok' leg in
# this file asserts "true" for that reason, and the refusal legs above already use
# this same '"ok":false' substring form.
assert_contains "l1r.3-6c: ...reporting ok=false" '"ok":false' "$L13C_OUT"
assert_contains "l1r.3-6c: ...and naming the label it could not remove" \
    "failed to remove qa-gate-entered" "$L13C_OUT"
# HONEST RESIDUAL, asserted rather than left implicit: with removals broken the
# rollback cannot undo its own add either, so it SAYS SO instead of claiming a
# clean restore. (The approval record is append-only and already written, which is
# why this is exit 3 plus a loud envelope rather than a silent recovery.)
assert_contains "l1r.3-6c: ...and admits the rollback itself could not complete" \
    "the restore itself did not complete" "$L13C_OUT"
# The false claim must be ABSENT: no success envelope, no removal counters.
L13C_FALSE=$(printf '%s' "$L13C_OUT" | grep -c 'removed qa-gate-entered=1' || true)
assert_eq "l1r.3-6c: ...and never reports 'removed qa-gate-entered=1' for a removal that did not happen" \
    "0" "$(printf '%s' "$L13C_FALSE" | tr -d '[:space:]')"

# --- l1r.3-META: revert the verification -> approve lies again ------------
QG_L13_MUT="$FIXTURE_L13/.claude/scripts/qa-gate-noverify.sh"
L13M_RC=0
awk '
    /^    ! has_label "\$1" "\$2"$/ { print "    return 0"; found = 1; next }
    { print }
    END { if (!found) exit 7 }
' "$QG_L13_REAL" > "$QG_L13_MUT" || L13M_RC=$?
chmod +x "$QG_L13_MUT" 2>/dev/null || true
assert_eq "l1r.3-META: the read-back was located and reverted to the bare form" "0" "$L13M_RC"
if assert_mutant_applied "l1r.3-META" "$QG_L13_REAL" "$QG_L13_MUT"; then
    L13M_PARSE=0
    bash -n "$QG_L13_MUT" 2>/dev/null || L13M_PARSE=$?
    assert_eq "l1r.3-META: the mutated copy still parses" "0" "$L13M_PARSE"
    TID_L13M=$(cd "$FIXTURE_L13" && bd create "l1r.3 META: unverified removal" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    printf 'src/l1r3m.ts\n' > "$TRACK_L13/changed-files.txt"
    CLAUDE_PROJECT_DIR="$FIXTURE_L13" bash "$QG_L13" enter "$TID_L13M" >/dev/null 2>&1 || true
    seed_review_records "$TID_L13M" "qa-claude" "backend" "$FIXTURE_L13"
    L13M_APRC=0
    L13M_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_L13" bash "$QG_L13_MUT" approve "$TID_L13M" \
        "unverified removals report success" 2>/dev/null) || L13M_APRC=$?
    assert_eq "l1r.3-META: under the bare removal approve SUCCEEDS (6c WOULD fail)" "0" "$L13M_APRC"
    assert_contains "l1r.3-META: ...and falsely reports 'removed qa-gate-entered=1'" \
        "removed qa-gate-entered=1" "$L13M_OUT"
    assert_eq "l1r.3-META: ...while qa-gate-entered is demonstrably still on the task" \
        "present" \
        "$(printf '%s' ",$(labels_in "$FIXTURE_L13" "$TID_L13M")," | grep -q ',qa-gate-entered,' && echo present || echo absent)"
fi

# ===========================================================================
# 8zi-5 — the rollback: byte-identical restoration, exit 3.
#
# A THIRD fixture, with a NARROWER shim: only `label remove <tid> qa-pending`
# fails. In approve's sweep order (qa-gate-entered, qa-pending, qa-escalated,
# qa-deferred, rubric-pending, qa-blocked) that is the SECOND removal, so the
# transition is genuinely PART-APPLIED when it fails — qa-approved added,
# qa-gate-entered removed — and the restore has to undo both directions.
# ===========================================================================
mk_fixture
FIXTURE_RL="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
depoison_bd "$FIXTURE_RL"
assert_eq "8zi-5: this fixture's bd wrapper execs a real bd (so qa-pending is the ONLY failing removal)" \
    "clean" "$(bd_wrapper_state "$FIXTURE_RL")"
QG_RL="$FIXTURE_RL/.claude/scripts/qa-gate.sh"
TRACK_RL="$FIXTURE_RL/.claude/.qa-tracking"
# Anchored on the trailing `"$@"`, NOT on a bd flag: the wrapper ended
# `--no-daemon "$@"` until bd 1.1.2 removed that flag, and a pattern keyed to it
# returns empty on the new wrapper — which sends the fallback to `command -v bd`,
# i.e. THIS shim, producing a wrapper that execs itself forever (a silent hang).
REAL_BD_RL=$(sed -n 's/^exec \(.*\) "\$@".*/\1/p' "$FIXTURE_RL/bin/bd" 2>/dev/null | tr -d '"' | head -1)
[ -z "$REAL_BD_RL" ] && REAL_BD_RL=$(command -v bd)
cat > "$FIXTURE_RL/bin/bd" <<EOF
#!/bin/bash
if [ "\$1" = "label" ] && [ "\$2" = "remove" ] && [ "\$4" = "qa-pending" ]; then exit 1; fi
exec $REAL_BD_RL "\$@"
EOF
chmod +x "$FIXTURE_RL/bin/bd"

TID_RL=$(cd "$FIXTURE_RL" && bd create "8zi: mid-sweep failure restores exactly" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/8zi-rb.ts\n' > "$TRACK_RL/changed-files.txt"
CLAUDE_PROJECT_DIR="$FIXTURE_RL" bash "$QG_RL" enter "$TID_RL" >/dev/null 2>&1 || true
seed_review_records "$TID_RL" "qa-claude" "backend" "$FIXTURE_RL"
for l in devops qa-pending qa-blocked; do
    (cd "$FIXTURE_RL" && bd label add "$TID_RL" "$l" >/dev/null 2>&1) || true
done
# THE SNAPSHOT, captured from bd rather than hardcoded — this is the exact string
# the restore has to reproduce.
RL_SNAP=$(labels_in "$FIXTURE_RL" "$TID_RL")
assert_contains "8zi-5: the pre-call set contains qa-gate-entered (the sweep will remove it first)" \
    "qa-gate-entered" "$RL_SNAP"
assert_eq "8zi-5: ...and does NOT contain qa-approved (the restore must undo the add too)" "0" \
    "$(printf '%s' ",$RL_SNAP," | grep -c ',qa-approved,' | tr -d '[:space:]')"
RL_RC=0
RL_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_RL" bash "$QG_RL" approve "$TID_RL" \
    "8zi: force a mid-sweep failure" 2>/dev/null) || RL_RC=$?
assert_eq "8zi-5: a mid-sweep removal failure exits 3" "3" "$RL_RC"
# See the l1r.3-6c note: jq's `//` cannot distinguish false from absent.
assert_contains "8zi-5: ...reporting ok=false" '"ok":false' "$RL_OUT"
assert_contains "8zi-5: ...naming the label it could not remove" \
    "failed to remove qa-pending" "$RL_OUT"
assert_contains "8zi-5: ...and claiming an exact restore" \
    "pre-call label set restored exactly" "$RL_OUT"
# THE ASSERTION: byte-identical, not set-equivalent-by-eye.
assert_eq "8zi-5: the pre-call label set is restored BYTE-IDENTICALLY" \
    "$RL_SNAP" "$(labels_in "$FIXTURE_RL" "$TID_RL")"
# CONTROL: the shim is the cause. The SAME approve on a task with no qa-pending
# never reaches the failing removal and succeeds.
TID_RLC=$(cd "$FIXTURE_RL" && bd create "8zi: rollback control" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf 'src/8zi-rb.ts\n' > "$TRACK_RL/changed-files.txt"
CLAUDE_PROJECT_DIR="$FIXTURE_RL" bash "$QG_RL" enter "$TID_RLC" >/dev/null 2>&1 || true
seed_review_records "$TID_RLC" "qa-claude" "backend" "$FIXTURE_RL"
(cd "$FIXTURE_RL" && bd label add "$TID_RLC" devops >/dev/null 2>&1) || true
(cd "$FIXTURE_RL" && bd label add "$TID_RLC" qa-blocked >/dev/null 2>&1) || true
RLC_RC=0
RLC_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_RL" bash "$QG_RL" approve "$TID_RLC" \
    "8zi: no qa-pending, no failing removal" 2>/dev/null) || RLC_RC=$?
assert_eq "8zi-5 CONTROL: with no qa-pending to remove, the SAME shim lets approve succeed" \
    "0" "$RLC_RC"
assert_json_field "8zi-5 CONTROL: ...status=approved" "$RLC_OUT" '.status' "approved"
assert_eq "8zi-5 CONTROL: ...and the sweep still cleared qa-blocked" \
    "devops,qa-approved" "$(labels_in "$FIXTURE_RL" "$TID_RLC")"

# ===========================================================================
# P7 — the completion contract at approve (claude-workflow-plugin-qbhw).
#
# Three pieces, one gate: `review-check.sh validate-completion` is the ONE
# validator, `qa-gate.sh completion-record` is the record writer that calls it
# as a subprocess, and cmd_approve REFUSES without the record it writes.
#
# A SEPARATE FIXTURE, because every other section in this file now gets a
# completion record for free (lib/fixture.sh's seed_review_records seeds one),
# and the legs below need tasks that deliberately DO NOT have one. The seeding
# here therefore composes the REAL writers directly — the same thing
# arbitration-acceptance.sh and review-separation.test.sh do when they need
# per-record control. Using the real writers rather than hand-built comments is
# what makes a grammar change break these legs loudly.
# ===========================================================================
mk_fixture
FIXTURE_P7="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
QG_P7="$FIXTURE_P7/.claude/scripts/qa-gate.sh"
RC_P7="$FIXTURE_P7/.claude/scripts/review-check.sh"
IR_P7="$FIXTURE_P7/.claude/scripts/impact-report.sh"
TRACK_P7="$FIXTURE_P7/.claude/.qa-tracking"

p7_new() {   # p7_new <title> <changed-file> -> tid, staged + entered
    local tid
    tid=$(cd "$FIXTURE_P7" && bd create "$1" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    printf '%s\n' "$2" > "$TRACK_P7/changed-files.txt"
    CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" enter "$tid" >/dev/null 2>&1
    printf '%s' "$tid"
}
p7_seed_review() {   # implementer + independent clean artifact, NO completion record
    local tid="$1" h art
    h=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$IR_P7" --hash-only 2>/dev/null || echo "")
    [ -z "$h" ] && h="unverified"
    (cd "$FIXTURE_P7" && bd comments add "$tid" \
        "IMPLEMENTER: role=backend task=$tid at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1)
    art="$TRACK_P7/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"qa-claude","reviewer_model":"m","reviewer_pin":"m","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"traced","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
        "$tid" "$h" > "$art"
    CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" review-record "$tid" --file "$art" >/dev/null 2>&1
}
p7_settle() {   # absorb incidental fixture dirt, then refresh the report for the CURRENT set
    baseline_incidental_dirt "$FIXTURE_P7"
    CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$IR_P7" "$1" >/dev/null 2>&1 || true
}
p7_payload() {  # p7_payload <tid> <files-json> -> path
    local tid="$1" files="$2" p
    p="$TRACK_P7/p7-payload-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    # model/pin (46w9): required transport keys alongside role now — see
    # validate-completion's missing_key:model/missing_key:pin checks.
    printf '{"task_id":"%s","role":"backend","model":"seeded","pin":"seeded","files_changed":%s,"tests_added":["t.sh::a"],"decisions":["d"],"blockers":[],"llm_observations":"o","context_coverage":"c"}\n' \
        "$tid" "$files" > "$p"
    printf '%s' "$p"
}

# --- P7-1: a valid payload RECORDS, and the task then APPROVES -------------
TID_P7A=$(p7_new "P7: valid payload" "src/p7a.ts")
p7_seed_review "$TID_P7A"
P7A_PAY=$(p7_payload "$TID_P7A" '["src/p7a.ts"]')
P7A_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7A" --file "$P7A_PAY" 2>/dev/null)
assert_json_field "P7-1: completion-record ok=true" "$P7A_OUT" '.ok' "true"
assert_json_field "P7-1: completion-record status=recorded" "$P7A_OUT" '.status' "recorded"
# The record grammar, byte-exact through the machine prefix.
P7A_REC=$(bd_show_with_comments "$TID_P7A" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep '^COMPLETION v1 ' | tail -1)
# model=/pin= (46w9) sit between role= and fields=, same position the
# writer's comment_text builds them at.
assert_match "P7-1: the record matches the COMPLETION v1 grammar" \
    '^COMPLETION v1 task=[A-Za-z0-9._-]+ role=backend model=seeded pin=seeded fields=[A-Za-z0-9._,+-]+ payload_sha=[A-Za-z0-9._+-]+ at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: 1 file\(s\), 1 test\(s\)$' \
    "$P7A_REC"
# payload_sha binds the PERSISTED artifact: recompute it independently.
# The artifact is keyed on task AND role (QA R1-F4): task-keyed storage let a
# second contract on the same task overwrite the first, and the file list the
# completeness cross-check reads is what got overwritten. Asserting the
# role-suffixed name here is not incidental — it is that fix, pinned.
P7A_PERSISTED="$TRACK_P7/completion-$(printf '%s' "$TID_P7A" | tr -c 'A-Za-z0-9._-' '_')-backend.json"
assert_eq "P7-1: the validated payload was persisted under its role-keyed name" "0" \
    "$([ -f "$P7A_PERSISTED" ] && echo 0 || echo 1)"
P7A_RECSHA=$(printf '%s' "$P7A_REC" | grep -oE 'payload_sha=[A-Za-z0-9._+-]+' | head -1 | cut -d= -f2-)
P7A_DISKSHA=$(shasum -a 256 "$P7A_PERSISTED" 2>/dev/null | awk '{print $1}')
assert_eq "P7-1: payload_sha is the digest of the persisted artifact (recomputed independently)" \
    "$P7A_DISKSHA" "$P7A_RECSHA"
p7_settle "$TID_P7A"
P7A_ARC=0
P7A_AOUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" approve "$TID_P7A" "contract recorded" 2>/dev/null) || P7A_ARC=$?
assert_eq "P7-1: approve SUCCEEDS once the contract is recorded (rc=0)" "0" "$P7A_ARC"
assert_json_field "P7-1: ...status=approved" "$P7A_AOUT" '.status' "approved"
assert_contains "P7-1: ...and the envelope names the verified contract" \
    "completion contract verified (role=backend" "$P7A_AOUT"
assert_contains "P7-1: ...and the completeness cross-check PASSED" \
    "completeness cross-check PASSED" "$P7A_AOUT"

# --- P7-2: the ONE validator rejects a payload missing a canonical field ---
TID_P7B=$(p7_new "P7: missing context_coverage" "src/p7b.ts")
P7B_PAY="$TRACK_P7/p7b.json"
printf '{"task_id":"%s","role":"backend","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o"}\n' \
    "$TID_P7B" > "$P7B_PAY"
P7B_RC=0
P7B_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7B" --file "$P7B_PAY" 2>/dev/null) || P7B_RC=$?
assert_eq "P7-2: completion-record refuses a payload missing context_coverage (rc=1)" "1" "$P7B_RC"
assert_json_field "P7-2: error_key=missing_key:context_coverage" \
    "$P7B_OUT" '.error_key' "missing_key:context_coverage"
assert_contains "P7-2: the refusal names the ONE validator it came from" \
    "review-check.sh" "$P7B_OUT"
# Same verdict from the validator called DIRECTLY — the writer carries no
# second schema, so both entry points must agree.
P7B_DRC=0
P7B_DOUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$RC_P7" validate-completion "$P7B_PAY" 2>/dev/null) || P7B_DRC=$?
assert_eq "P7-2: review-check.sh validate-completion agrees (rc=4)" "4" "$P7B_DRC"
assert_json_field "P7-2: ...with the same error_key" \
    "$P7B_DOUT" '.error_key' "missing_key:context_coverage"
# No record was written for a rejected payload.
P7B_RECS=$(bd_show_with_comments "$TID_P7B" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '^COMPLETION v1 ' | tr -d '[:space:]')
assert_eq "P7-2: a rejected payload writes NO record" "0" "$P7B_RECS"

# --- P7-2b/2c: the ONE validator rejects a payload missing model / pin -----
# 46w9: model/pin are required transport keys alongside role (see
# validate-completion's missing_key:model/missing_key:pin checks and
# completion_payload_path_for's header). Zero coverage existed for either
# branch before this leg — P7-1..P7-4d all built payloads with both fields
# already present, so a copy-paste that wired the has-check for one field but
# not the other would have shipped invisibly.
TID_P7B2=$(p7_new "P7: missing model" "src/p7b2.ts")
P7B2_PAY="$TRACK_P7/p7b2.json"
printf '{"task_id":"%s","role":"backend","pin":"m","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c"}\n' \
    "$TID_P7B2" > "$P7B2_PAY"
P7B2_RC=0
P7B2_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7B2" --file "$P7B2_PAY" 2>/dev/null) || P7B2_RC=$?
assert_eq "P7-2b: completion-record refuses a payload missing model (rc=1)" "1" "$P7B2_RC"
assert_json_field "P7-2b: error_key=missing_key:model" \
    "$P7B2_OUT" '.error_key' "missing_key:model"
P7B2_DRC=0
CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$RC_P7" validate-completion "$P7B2_PAY" >/dev/null 2>&1 || P7B2_DRC=$?
assert_eq "P7-2b: review-check.sh validate-completion agrees (rc=4)" "4" "$P7B2_DRC"
P7B2_RECS=$(bd_show_with_comments "$TID_P7B2" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '^COMPLETION v1 ' | tr -d '[:space:]')
assert_eq "P7-2b: a rejected payload writes NO record" "0" "$P7B2_RECS"

TID_P7B3=$(p7_new "P7: missing pin" "src/p7b3.ts")
P7B3_PAY="$TRACK_P7/p7b3.json"
printf '{"task_id":"%s","role":"backend","model":"m","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c"}\n' \
    "$TID_P7B3" > "$P7B3_PAY"
P7B3_RC=0
P7B3_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7B3" --file "$P7B3_PAY" 2>/dev/null) || P7B3_RC=$?
assert_eq "P7-2c: completion-record refuses a payload missing pin (rc=1)" "1" "$P7B3_RC"
assert_json_field "P7-2c: error_key=missing_key:pin" \
    "$P7B3_OUT" '.error_key' "missing_key:pin"
P7B3_DRC=0
CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$RC_P7" validate-completion "$P7B3_PAY" >/dev/null 2>&1 || P7B3_DRC=$?
assert_eq "P7-2c: review-check.sh validate-completion agrees (rc=4)" "4" "$P7B3_DRC"
P7B3_RECS=$(bd_show_with_comments "$TID_P7B3" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '^COMPLETION v1 ' | tr -d '[:space:]')
assert_eq "P7-2c: a rejected payload writes NO record" "0" "$P7B3_RECS"

# --- P7-2d/2e: model/pin values failing the model-id character class ------
# The WIDER class (letters, digits, ., -, :, /, [, ]) still excludes a space,
# so a self-reported model string containing one (a plausible slip — e.g.
# copy-pasting a sentence instead of an id) is rejected rather than silently
# truncated or split.
TID_P7B4=$(p7_new "P7: model fails the character class" "src/p7b4.ts")
P7B4_PAY="$TRACK_P7/p7b4.json"
printf '{"task_id":"%s","role":"backend","model":"claude opus","pin":"m","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c"}\n' \
    "$TID_P7B4" > "$P7B4_PAY"
P7B4_RC=0
P7B4_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7B4" --file "$P7B4_PAY" 2>/dev/null) || P7B4_RC=$?
assert_eq "P7-2d: completion-record refuses a model value with a space (rc=1)" "1" "$P7B4_RC"
assert_json_field "P7-2d: error_key=field_invalid_chars:model" \
    "$P7B4_OUT" '.error_key' "field_invalid_chars:model"
P7B4_RECS=$(bd_show_with_comments "$TID_P7B4" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '^COMPLETION v1 ' | tr -d '[:space:]')
assert_eq "P7-2d: a rejected payload writes NO record" "0" "$P7B4_RECS"

TID_P7B5=$(p7_new "P7: pin fails the character class" "src/p7b5.ts")
P7B5_PAY="$TRACK_P7/p7b5.json"
printf '{"task_id":"%s","role":"backend","model":"m","pin":"claude opus","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c"}\n' \
    "$TID_P7B5" > "$P7B5_PAY"
P7B5_RC=0
P7B5_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7B5" --file "$P7B5_PAY" 2>/dev/null) || P7B5_RC=$?
assert_eq "P7-2e: completion-record refuses a pin value with a space (rc=1)" "1" "$P7B5_RC"
assert_json_field "P7-2e: error_key=field_invalid_chars:pin" \
    "$P7B5_OUT" '.error_key' "field_invalid_chars:pin"
P7B5_RECS=$(bd_show_with_comments "$TID_P7B5" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '^COMPLETION v1 ' | tr -d '[:space:]')
assert_eq "P7-2e: a rejected payload writes NO record" "0" "$P7B5_RECS"
# Restore control: the SAME two payloads with a legal model/pin RECORD.
TID_P7B4C=$(p7_new "P7: model/pin restore control" "src/p7b4c.ts")
P7B4C_PAY="$TRACK_P7/p7b4c.json"
printf '{"task_id":"%s","role":"backend","model":"claude-opus-5[1m]","pin":"claude-opus-5","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c"}\n' \
    "$TID_P7B4C" > "$P7B4C_PAY"
P7B4C_RC=0
P7B4C_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7B4C" --file "$P7B4C_PAY" 2>/dev/null) || P7B4C_RC=$?
assert_eq "P7-2f: RESTORE CONTROL — a bracket-suffixed real model id and a plain pin both record (rc=0)" \
    "0" "$P7B4C_RC"
assert_json_field "P7-2f: ...ok=true" "$P7B4C_OUT" '.ok' "true"

# --- P7-3: a control character in a grammar-bearing scalar (layer 1) -------
# The vg8 class: role is embedded verbatim in a ONE-LINE record, so a newline
# splits it and every later token lands on a line no reader parses.
TID_P7C=$(p7_new "P7: newline in role" "src/p7c.ts")
P7C_PAY="$TRACK_P7/p7c.json"
# model/pin (46w9): present and valid, so the has-checks pass and the control
# character in `role` is what the validator actually trips over.
printf '{"task_id":"%s","role":"back\\nend","model":"m","pin":"m","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c"}\n' \
    "$TID_P7C" > "$P7C_PAY"
P7C_RC=0
P7C_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7C" --file "$P7C_PAY" 2>/dev/null) || P7C_RC=$?
assert_eq "P7-3: a newline in role is refused (rc=1)" "1" "$P7C_RC"
assert_json_field "P7-3: error_key=scalar_contains_control_char:role" \
    "$P7C_OUT" '.error_key' "scalar_contains_control_char:role"

# --- P7-4: THE INJECTION. A crafted role of the form
#     `backend fields=x payload_sha=deadbeef at 1999-01-01T00:00:00Z: 99 file(s), 99 test(s)`
#     would relocate the record's own `: ` boundary, so a reader parsing the
#     machine prefix would take the ATTACKER's counts and digest instead of the
#     real ones — the claude-workflow-plugin-bjx class, reproduced.
#     It carries NO control character, so layer 1 passes it; the writer's
#     character class is what closes it. -----------------------------------
TID_P7D=$(p7_new "P7: role injection" "src/p7d.ts")
P7D_PAY="$TRACK_P7/p7d.json"
P7D_EVIL='backend fields=x payload_sha=deadbeef at 1999-01-01T00:00:00Z: 99 file(s), 99 test(s)'
# model/pin (46w9): valid values, so the injection under test is isolated to
# `role` — a missing/invalid model or pin would trip a DIFFERENT check first.
printf '{"task_id":"%s","role":"%s","model":"m","pin":"m","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c"}\n' \
    "$TID_P7D" "$P7D_EVIL" > "$P7D_PAY"
# It really is control-char-free, i.e. layer 1 cannot be what stops it.
P7D_VRC=0
CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$RC_P7" validate-completion "$P7D_PAY" >/dev/null 2>&1 || P7D_VRC=$?
assert_eq "P7-4: the crafted role passes the SCHEMA (so the char class is what closes it)" \
    "0" "$P7D_VRC"
P7D_RC=0
P7D_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7D" --file "$P7D_PAY" 2>/dev/null) || P7D_RC=$?
assert_eq "P7-4: role='backend fields=x payload_sha=deadbeef at 1999-01-01T00:00:00Z: 99 file(s), 99 test(s)' is REJECTED by the char class (rc=1)" \
    "1" "$P7D_RC"
assert_json_field "P7-4: ...error_key=role_invalid_chars" "$P7D_OUT" '.error_key' "role_invalid_chars"
assert_contains "P7-4: ...rejected, NOT sanitised" "Rejected, not sanitised" "$P7D_OUT"
P7D_RECS=$(bd_show_with_comments "$TID_P7D" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '^COMPLETION v1 ' | tr -d '[:space:]')
assert_eq "P7-4: ...and no forged record reached the task" "0" "$P7D_RECS"
# The same class over a payload KEY NAME, which is equally caller-controlled
# and is comma-joined into `fields=`.
TID_P7D2=$(p7_new "P7: key-name injection" "src/p7d2.ts")
P7D2_PAY="$TRACK_P7/p7d2.json"
printf '{"task_id":"%s","role":"backend","model":"m","pin":"m","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c","evil at 1999: 0 file(s)":"x"}\n' \
    "$TID_P7D2" > "$P7D2_PAY"
P7D2_RC=0
P7D2_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7D2" --file "$P7D2_PAY" 2>/dev/null) || P7D2_RC=$?
assert_eq "P7-4b: a payload KEY NAME carrying the same shape is rejected too (rc=1)" "1" "$P7D2_RC"
assert_json_field "P7-4b: ...error_key=field_name_invalid_chars" \
    "$P7D2_OUT" '.error_key' "field_name_invalid_chars"

# --- P7-4c/4d: QA R1-F1 — the guard must inspect the bytes that are WRITTEN.
# P7-4b passed against the BROKEN implementation because its shape carried
# neither a comma nor a glob metacharacter. These two legs are the shapes that
# did not. Both were reproduced against the pre-fix script before the fix
# landed. ------------------------------------------------------------------
#
# 4c — COMMA, deterministic, no adversary required. The csv was built with jq's
# join(",") and then "validated" by re-splitting it on IFS=','; a key literally
# named `a,b` split into two legal words, so the guard never saw the comma, and
# the record was written from the untouched original: `fields=...,a,b`, one key
# rendered as two members.
TID_P7C2=$(p7_new "P7: comma in a key name" "src/p7c2.ts")
P7C2_PAY="$TRACK_P7/p7c2.json"
printf '{"task_id":"%s","role":"backend","model":"m","pin":"m","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c","a,b":"x"}\n' \
    "$TID_P7C2" > "$P7C2_PAY"
P7C2_RC=0
P7C2_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7C2" --file "$P7C2_PAY" 2>/dev/null) || P7C2_RC=$?
assert_eq "P7-4c: a key name containing a COMMA is rejected (pre-fix: ok=true, and the record read fields=...,a,b)" \
    "1" "$P7C2_RC"
assert_json_field "P7-4c: ...error_key=field_name_invalid_chars" \
    "$P7C2_OUT" '.error_key' "field_name_invalid_chars"
P7C2_RECS=$(bd_show_with_comments "$TID_P7C2" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '^COMPLETION v1 ' | tr -d '[:space:]')
assert_eq "P7-4c: ...and no record with a split csv reached the task" "0" "$P7C2_RECS"

# 4d — GLOB, and the assertion is CWD-INDEPENDENCE rather than mere rejection.
# The unquoted expansion also performed pathname expansion, so `[c]lean1`
# expanded to `clean1` (legal, brackets still written to the record) when a file
# of that name sat in the process's working directory, and was rejected when it
# did not. Same payload, opposite verdicts, decided by unrelated files. So this
# runs the SAME payload from two directories and asserts the two verdicts AGREE
# — a leg that merely asserted "rejected" would have passed pre-fix whenever it
# happened to run somewhere without the decoy.
TID_P7D3=$(p7_new "P7: glob metachar in a key name" "src/p7d3.ts")
P7D3_PAY="$TRACK_P7/p7d3.json"
printf '{"task_id":"%s","role":"backend","model":"m","pin":"m","files_changed":[],"tests_added":[],"decisions":[],"blockers":[],"llm_observations":"o","context_coverage":"c","[c]lean1":"x"}\n' \
    "$TID_P7D3" > "$P7D3_PAY"
mkdir -p "$FIXTURE_P7/globdir-with" "$FIXTURE_P7/globdir-without"
: > "$FIXTURE_P7/globdir-with/clean1"          # the decoy the glob would expand to
P7D3_WITH_RC=0
P7D3_WITH=$( (cd "$FIXTURE_P7/globdir-with" && CLAUDE_PROJECT_DIR="$FIXTURE_P7" \
    bash "$QG_P7" completion-record "$TID_P7D3" --file "$P7D3_PAY" 2>/dev/null) ) || P7D3_WITH_RC=$?
P7D3_WITHOUT_RC=0
P7D3_WITHOUT=$( (cd "$FIXTURE_P7/globdir-without" && CLAUDE_PROJECT_DIR="$FIXTURE_P7" \
    bash "$QG_P7" completion-record "$TID_P7D3" --file "$P7D3_PAY" 2>/dev/null) ) || P7D3_WITHOUT_RC=$?
assert_eq "P7-4d: the verdict is the SAME from a CWD holding the glob's target and from one that does not (pre-fix: 0 vs 1)" \
    "$P7D3_WITHOUT_RC" "$P7D3_WITH_RC"
assert_eq "P7-4d: ...and that shared verdict is REJECT (rc=1)" "1" "$P7D3_WITH_RC"
assert_json_field "P7-4d: ...error_key=field_name_invalid_chars, decoy present" \
    "$P7D3_WITH" '.error_key' "field_name_invalid_chars"
assert_json_field "P7-4d: ...error_key=field_name_invalid_chars, decoy absent" \
    "$P7D3_WITHOUT" '.error_key' "field_name_invalid_chars"

# --- P7-5: no record -> approve REFUSES ------------------------------------
TID_P7E=$(p7_new "P7: approve without a contract" "src/p7e.ts")
p7_seed_review "$TID_P7E"
p7_settle "$TID_P7E"
P7E_RC=0
P7E_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" approve "$TID_P7E" "ship it" 2>/dev/null) || P7E_RC=$?
assert_eq "P7-5: approve refuses with no COMPLETION record (rc=2)" "2" "$P7E_RC"
assert_contains "P7-5: ...ok=false" '"ok":false' "$P7E_OUT"
assert_json_field "P7-5: ...error_key=completion_record_missing" \
    "$P7E_OUT" '.error_key' "completion_record_missing"
assert_contains "P7-5: ...the remediation names completion-record" \
    "qa-gate.sh completion-record" "$P7E_OUT"
assert_contains "P7-5: ...and names the audited bypass" "--no-completion" "$P7E_OUT"
# A refused approve is a no-op on labels (same discipline as every other refusal).
P7E_LBL=$(cd "$FIXTURE_P7" && bd show "$TID_P7E" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0].labels else .labels end // [] | join(",")')
assert_eq "P7-5: the refusal leaves qa-approved unset" "0" \
    "$(printf '%s' ",$P7E_LBL," | grep -c ',qa-approved,' | tr -d '[:space:]')"

# --- P7-6: --no-completion '' exits 1; with a reason it approves -----------
P7F_RC=0
P7F_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" approve "$TID_P7E" --no-completion "" "s" 2>/dev/null) || P7F_RC=$?
assert_eq "P7-6: --no-completion with an empty reason exits 1" "1" "$P7F_RC"
assert_json_field "P7-6: ...error_key=bypass_reason_required" \
    "$P7F_OUT" '.error_key' "bypass_reason_required"
P7G_RC=0
P7G_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" approve "$TID_P7E" \
    --no-completion "F1 doc-only fast path: no specialist, no completion payload" \
    "bypassed approval" 2>/dev/null) || P7G_RC=$?
assert_eq "P7-6: ...with a reason, the SAME task approves (rc=0)" "0" "$P7G_RC"
assert_contains "P7-6: ...the reason lands in the envelope" \
    "completion-bypass: F1 doc-only fast path" "$P7G_OUT"
P7G_CMT=$(bd_show_with_comments "$TID_P7E" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '\[completion bypass:' | tr -d '[:space:]')
assert_eq "P7-6: ...and in the durable approval record" "1" "$P7G_CMT"

# --- P7-7: fkm.1.20 — the completeness cross-check REPORTS the 94d.1 shape -
# 94d.1 measured: eight files declared by the implementer's own F7 contract, a
# tracker rebuilt to a subset, and approve's freshness check passing VACUOUSLY
# because both of its numbers described the shrunken set. Here the declaration
# is the independent witness, and the delta is reported rather than hidden.
TID_P7H=$(p7_new "P7: short change set" "src/p7h-one.ts")
printf 'src/p7h-one.ts\nsrc/p7h-two.ts\n' > "$TRACK_P7/changed-files.txt"
p7_seed_review "$TID_P7H"
P7H_PAY=$(p7_payload "$TID_P7H" '["src/p7h-one.ts","src/p7h-two.ts","src/p7h-three.ts","src/p7h-four.ts","src/p7h-five.ts","src/p7h-six.ts","src/p7h-seven.ts","src/p7h-eight.ts"]')
CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7H" --file "$P7H_PAY" >/dev/null 2>&1
p7_settle "$TID_P7H"
P7H_RC=0
P7H_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" approve "$TID_P7H" "approve over a short set" 2>/dev/null) || P7H_RC=$?
# REPORTS, does not refuse — see completion_files_crosscheck's header for the
# four reasons. The value is the visibility, which is what 94d.1 lacked.
assert_eq "P7-7: a provably short change set still APPROVES (the check reports)" "0" "$P7H_RC"
assert_contains "P7-7: ...and the envelope reports the 94d.1 arithmetic" \
    "declared=8 bound=2 matched=2 missing=6" "$P7H_OUT"
assert_contains "P7-7: ...names the missing paths" "src/p7h-eight.ts" "$P7H_OUT"
P7H_CMT=$(bd_show_with_comments "$TID_P7H" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '\[completion cross-check: 6 of 8 declared file(s) absent' | tr -d '[:space:]')
assert_eq "P7-7: ...and the DURABLE approval record carries the finding" "1" "$P7H_CMT"

# --- P7-7b: QA R1-F4 — a QA contract recorded on the SAME task must not
# disarm the check. THE REGRESSION LEG. P7-7 above passes on the broken
# implementation too, because no QA record follows it in that fixture; this one
# is the shape the release's own qa.md flow produces, and pre-fix it turned the
# 6-of-8 WARNING into an affirmative "PASSED — every one of the 0 declared
# file(s)" with NO token in the durable record at all. ---------------------
TID_P7I=$(p7_new "P7: QA contract must not disarm the cross-check" "src/p7i-one.ts")
printf 'src/p7i-one.ts\nsrc/p7i-two.ts\n' > "$TRACK_P7/changed-files.txt"
p7_seed_review "$TID_P7I"
P7I_IMPL=$(p7_payload "$TID_P7I" '["src/p7i-one.ts","src/p7i-two.ts","src/p7i-three.ts","src/p7i-four.ts","src/p7i-five.ts","src/p7i-six.ts","src/p7i-seven.ts","src/p7i-eight.ts"]')
CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7I" --file "$P7I_IMPL" >/dev/null 2>&1
# QA's own contract, recorded AFTER — files_changed [] because QA verifies
# rather than authors, which is exactly why reading it as the witness is wrong.
P7I_QA="$TRACK_P7/p7i-qa.json"
printf '{"task_id":"%s","role":"qa","model":"m","pin":"m","files_changed":[],"tests_added":[],"decisions":["reviewed"],"blockers":[],"llm_observations":"o","context_coverage":"c","approved":true,"files_verified":["src/p7i-one.ts"]}\n' \
    "$TID_P7I" > "$P7I_QA"
CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7I" --file "$P7I_QA" >/dev/null 2>&1
# The artifacts must COEXIST — task-keyed storage let the second write clobber
# the first, which is half the defect.
assert_eq "P7-7b: the implementer's payload artifact survives QA recording its own" "0" \
    "$([ -f "$TRACK_P7/completion-$(printf '%s' "$TID_P7I" | tr -c 'A-Za-z0-9._-' '_')-backend.json" ] && echo 0 || echo 1)"
assert_eq "P7-7b: ...and QA's is a SEPARATE artifact, not an overwrite" "0" \
    "$([ -f "$TRACK_P7/completion-$(printf '%s' "$TID_P7I" | tr -c 'A-Za-z0-9._-' '_')-qa.json" ] && echo 0 || echo 1)"
p7_settle "$TID_P7I"
P7I_RC=0
P7I_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" approve "$TID_P7I" "QA recorded after the implementer" 2>/dev/null) || P7I_RC=$?
assert_eq "P7-7b: approve still succeeds" "0" "$P7I_RC"
# THE ASSERTION: the arithmetic is the IMPLEMENTER's, not QA's empty list.
assert_contains "P7-7b: the cross-check reads the IMPLEMENTER's declaration (pre-fix: 'every one of the 0 declared file(s)')" \
    "declared=8" "$P7I_OUT"
assert_contains "P7-7b: ...reporting the real 6-of-8 shortfall" \
    "missing=6" "$P7I_OUT"
P7I_FALSEPASS=$(printf '%s' "$P7I_OUT" | grep -c 'cross-check PASSED' || true)
assert_eq "P7-7b: ...and NEVER reports an affirmative PASS over a short set" \
    "0" "$(printf '%s' "$P7I_FALSEPASS" | tr -d '[:space:]')"
P7I_CMT=$(bd_show_with_comments "$TID_P7I" "$FIXTURE_P7" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | .[].text' \
    | grep -c '\[completion cross-check: 6 of 8 declared file(s) absent' | tr -d '[:space:]')
assert_eq "P7-7b: ...and the durable record carries the token (pre-fix: none at all)" "1" "$P7I_CMT"

# --- P7-7c: a task with ONLY a reviewer contract reports UNESTABLISHED, never
# a PASS. The fail-safe direction of the implementer-role allowlist: an
# unrecognised role must degrade to "I could not check", because degrading to
# "PASSED" is the defect above wearing a different hat. -------------------
TID_P7J=$(p7_new "P7: only a reviewer contract" "src/p7j.ts")
p7_seed_review "$TID_P7J"
P7J_QA="$TRACK_P7/p7j-qa.json"
printf '{"task_id":"%s","role":"qa","model":"m","pin":"m","files_changed":[],"tests_added":[],"decisions":["reviewed"],"blockers":[],"llm_observations":"o","context_coverage":"c"}\n' \
    "$TID_P7J" > "$P7J_QA"
CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" completion-record "$TID_P7J" --file "$P7J_QA" >/dev/null 2>&1
p7_settle "$TID_P7J"
P7J_RC=0
P7J_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" approve "$TID_P7J" "reviewer contract only" 2>/dev/null) || P7J_RC=$?
assert_eq "P7-7c: the reviewer's contract still satisfies the REFUSAL (approve proceeds)" "0" "$P7J_RC"
assert_contains "P7-7c: ...but the cross-check reports UNESTABLISHED, not PASSED" \
    "completeness cross-check UNESTABLISHED" "$P7J_OUT"
assert_contains "P7-7c: ...and names the roles it did find, so the degradation is diagnosable" \
    "roles seen: qa" "$P7J_OUT"

# --- P7-META: strip the sentinels -> approve succeeds with NO record -------
# The falsifiable form of "this refusal is what enforces the contract". The copy
# lives in the fixture's .claude/scripts/ because qa-gate.sh loads
# workflow-denylist.sh relative to its OWN directory (see the impact-report META
# above): a copy parked elsewhere has no denylist, reconcile_tracker refuses,
# and approve exits 2 for a reason unrelated to the region under test.
QG_P7_REAL=$(readlink "$QG_P7" 2>/dev/null || printf '%s' "$QG_P7")
QG_P7_STRIPPED="$FIXTURE_P7/.claude/scripts/qa-gate-nocompletion.sh"
P7M_STRIP_RC=0
awk '
    /^ *# COMPLETION-CONTRACT-REFUSAL BEGIN/ { skip = 1; found = 1; next }
    /^ *# COMPLETION-CONTRACT-REFUSAL END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$QG_P7_REAL" > "$QG_P7_STRIPPED" || P7M_STRIP_RC=$?
chmod +x "$QG_P7_STRIPPED" 2>/dev/null || true
assert_eq "P7-META: the COMPLETION-CONTRACT-REFUSAL sentinels are present in qa-gate.sh" \
    "0" "$P7M_STRIP_RC"
if assert_mutant_applied "P7-META" "$QG_P7_REAL" "$QG_P7_STRIPPED"; then
    P7M_PARSE=0
    bash -n "$QG_P7_STRIPPED" 2>/dev/null || P7M_PARSE=$?
    assert_eq "P7-META: the stripped copy still parses (it must fail for the reason under test)" \
        "0" "$P7M_PARSE"
    TID_P7M=$(p7_new "P7 META: stripped copy approves without a contract" "src/p7m.ts")
    p7_seed_review "$TID_P7M"
    p7_settle "$TID_P7M"
    # CONTROL: the SHIPPED script refuses this exact task.
    P7M_SRC_RC=0
    CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7" approve "$TID_P7M" "control" >/dev/null 2>&1 || P7M_SRC_RC=$?
    assert_eq "P7-META CONTROL: the shipped copy refuses this task (rc=2)" "2" "$P7M_SRC_RC"
    # THE MUTANT: without the region, the same task approves.
    P7M_RC=0
    P7M_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE_P7" bash "$QG_P7_STRIPPED" approve "$TID_P7M" \
        "stripped copy must NOT refuse" 2>/dev/null) || P7M_RC=$?
    assert_eq "P7-META: the stripped copy approves with NO completion record (P7-5 WOULD fail)" \
        "0" "$P7M_RC"
    assert_json_field "P7-META: ...status=approved" "$P7M_OUT" '.status' "approved"
    # NON-VACUITY: the stripped copy is a working pre-P7 approve, not a broken
    # one — it still writes a coherent, change-set-bound approval record.
    assert_contains "P7-META: ...and still writes a change-set-bound record" \
        "change-set-bound approval record written" "$P7M_OUT"
fi

[ "$FAIL" -eq 0 ]

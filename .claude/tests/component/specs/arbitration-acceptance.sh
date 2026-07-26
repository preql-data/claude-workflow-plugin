#!/bin/bash
# arbitration-acceptance.sh — L2 ACCEPTANCE SCENARIOS for the V3 arbitration
# decision flow (v4.0.0 Phase V3 / claude-workflow-plugin-jio.2).
#
# WHAT THIS ADDS OVER THE SHIPPED SPECS. jio.1 already proves the MECHANICS
# per error_key, and this spec deliberately does not restate them:
#   - L1 review-separation.test.sh   : approve refuses per error_key
#                                      (missing / not-independent / open),
#                                      resolve-finding and overrule clear it,
#                                      the --no-review bypass, fail-closed,
#                                      and the sentinel-strip META.
#   - L2 verify-review-discipline.sh : the STOP end — a post-approval finding
#                                      re-arms the gate, an overrule releases,
#                                      the [review bypass:] marker releases,
#                                      missing helper blocks, sentinel META.
#
# jio.2's question is different and unasked by either: given a DISPUTED
# finding, does the ORCHESTRATOR's arbitration DECISION drive the outcome the
# prompt (orchestrator.md section 5d) promises — end to end, across BOTH gate
# ends, on ONE task, with the decision as the only variable?
#
#   A1  self-review seeded (reviewer == implementer)  -> approve REFUSES
#                                                        reviewer_not_independent,
#                                                        and Stop does NOT release
#   A2  independent reviewer, at-threshold finding    -> approve REFUSES
#       DISPUTED by the specialist                       unresolved_findings (by id)
#   A3  arbitrate SUSTAIN (dispute considered, upheld) -> approve STILL REFUSES;
#                                                        the audit record is on file
#   A4  arbitrate OVERRULE (latest decision wins)      -> approve PASSES and the
#                                                        Stop hook RELEASES
#   A5  the audit trail survives: sustain AND overrule are both readable, the
#       approval names the independent reviewer, and the rationale text (which
#       section 5d requires to cite BOTH positions) is preserved verbatim
#   A6  the OTHER legitimate resolution — resolve-finding with fix+test
#       evidence — clears an equivalent dispute WITHOUT any arbitration, so the
#       two paths in section 5d are both real
#
# Every record is written by the REAL writers (qa-gate.sh review-record /
# arbitrate / resolve-finding, bd comments add for the IMPLEMENTER record
# subagent-start.sh emits). No hand-crafted comment text: if a grammar moves,
# this spec breaks loudly instead of asserting against a dead shape.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
IR="$FIXTURE/.claude/scripts/impact-report.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

(cd "$FIXTURE" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

# detect-stack stub with empty commands: skip the (slow) test/lint/type pass so
# each Stop reaches the release predicate directly.
rm -f "$FIXTURE/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$FIXTURE/.claude/scripts/detect-stack.sh"
chmod +x "$FIXTURE/.claude/scripts/detect-stack.sh"

comments_of() {
    bd show "$1" --json 2>/dev/null \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' \
        2>/dev/null || echo ""
}

# stop_decision — run the REAL Stop hook and print `block` or `ALLOW`.
stop_decision() {
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | bash "$VBS" 2>/dev/null | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null
}

# restage <tid> <file> — re-arm "this change-set belongs to this task" (the
# release path clears the tracker and current-task on every allow).
restage() {
    bash "$CT" set "$1" >/dev/null 2>&1
    printf '%s\n' "$2" > "$TRACK/changed-files.txt"
}

# record_artifact <tid> <iteration> <reviewer> <findings-json> — the REAL
# writer, which re-validates through review-check.sh.
record_artifact() {
    local tid="$1" iter="$2" reviewer="$3" findings="$4" verdict="approve"
    [ "$findings" != "[]" ] && verdict="findings"
    local hash art
    hash=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" --hash-only 2>/dev/null || echo "")
    [ -z "$hash" ] && hash="unverified"
    art="$TRACK/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r$iter.json"
    mkdir -p "$TRACK" 2>/dev/null || true
    cat > "$art" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"$reviewer","reviewer_model":"test-model","reviewed_hash":"$hash","risk_threshold":"high","stop_condition":"every acceptance criterion traced to a test","verdict":"$verdict","findings":$findings,"iterations":$iter,"stopped_by":"verdict"}
JSON
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" review-record "$tid" --file "$art" >/dev/null 2>&1
}

# new_task <title> <changed-file> <impl-role> — create + stage + enter the gate
# (enter generates the impact report so the EARLIER impact-freshness refusal
# never masks the review refusal under test), then record the implementer.
new_task() {
    local title="$1" file="$2" role="$3" tid
    tid=$(cd "$FIXTURE" && bd create "$title" -t task -p 1 -l "$role,qa-pending" --json 2>/dev/null | jq -r '.id // empty')
    printf '%s\n' "$file" > "$TRACK/changed-files.txt"
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" enter "$tid" >/dev/null 2>&1
    (cd "$FIXTURE" && bd comments add "$tid" \
        "IMPLEMENTER: role=$role task=$tid at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1)
    printf '%s' "$tid"
}

# The disputed finding, verbatim across A2-A4 (only the decision changes).
DISPUTE_FINDING='[{"id":"R1-F1","severity":"high","location":"src/checkout.ts:88","evidence":"the retry loop re-posts the charge when the gateway times out","description":"possible double-charge on gateway timeout"}]'

# ---------------------------------------------------------------------------
echo ""
echo "=== A1: SELF-REVIEW — the implementer reviews its own work ==="
#
# The acceptance framing of jio.1's 1.2 refusal: an agent that reviews itself
# cannot reach a release, at EITHER gate end.
TID_SELF=$(new_task "arbitration: self-review" "src/self.ts" "backend")
record_artifact "$TID_SELF" 1 "backend" "[]"
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$TID_SELF" "self-reviewed; shipping" 2>/dev/null) || RC=$?
assert_eq "A1: approve REFUSES a self-review (exit 4)" "4" "$RC"
assert_json_field "A1: error_key names the independence rule" \
    "$OUT" '.error_key' "reviewer_not_independent"
# NB: assert_json_field cannot express this one — jq's `.ok // empty`
# alternative treats `false` as absent, so a false-valued field always reads
# empty. Match the raw envelope instead (same shape the L1 specs assert).
assert_contains "A1: the refusal is not an approval (ok=false)" '"ok":false' "$OUT"
LBL=$(cd "$FIXTURE" && bd show "$TID_SELF" --json 2>/dev/null | jq -r '(if type=="array" then .[0] else . end).labels | join(",")')
assert_not_contains "A1: the refused approve set no qa-approved label" "qa-approved" "$LBL"
restage "$TID_SELF" "src/self.ts"
assert_eq "A1: Stop does NOT release an unapproved self-reviewed task" "block" "$(stop_decision)"

# ---------------------------------------------------------------------------
echo ""
echo "=== A2: a DISPUTED at-threshold finding blocks the gate ==="
#
# Independent reviewer (qa-claude) vs backend implementer. The specialist
# DISPUTES the finding in its F7 `decisions` — which changes nothing
# mechanically: while the finding is neither resolved nor arbitrated, the gate
# is shut. That is what forces the orchestrator to actually adjudicate.
TID=$(new_task "arbitration: disputed finding" "src/checkout.ts" "backend")
record_artifact "$TID" 1 "qa-claude" "$DISPUTE_FINDING"
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$TID" "specialist disputes the finding; shipping anyway" 2>/dev/null) || RC=$?
assert_eq "A2: approve REFUSES while the dispute is unresolved (exit 4)" "4" "$RC"
assert_json_field "A2: error_key=unresolved_findings" \
    "$OUT" '.error_key' "unresolved_findings"
assert_contains "A2: the refusal names the disputed finding id" "R1-F1" "$OUT"
assert_contains "A2: the refusal offers the RESOLVE path (evidence-before-fix)" \
    "qa-gate.sh resolve-finding" "$OUT"
assert_contains "A2: the refusal offers the ARBITRATE path" \
    "arbitrate" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== A3: arbitrate SUSTAIN — considered, upheld, still blocking ==="
#
# `sustain` is NOT a release valve. It records that the orchestrator read both
# positions and sided with the reviewer; the finding stays open and the
# implementer must actually resolve it. If sustain cleared the count, "the
# dispute was heard" would be indistinguishable from "the dispute was right",
# and every arbitration would be a rubber stamp.
SUSTAIN_RATIONALE="reviewer position: the retry re-posts the charge on a gateway timeout (src/checkout.ts:88, evidence in R1-F1). Specialist position: the gateway is idempotent per its docs. Decision: SUSTAIN — the idempotency key is not set on the retry path, so the vendor guarantee does not apply here; fix and cover it with a test."
ARB_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" arbitrate "$TID" R1-F1 sustain "$SUSTAIN_RATIONALE" 2>/dev/null)
assert_json_field "A3: arbitrate sustain is recorded" "$ARB_OUT" '.status' "arbitrated"
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$TID" "dispute was arbitrated" 2>/dev/null) || RC=$?
assert_eq "A3: SUSTAIN does NOT clear the finding — approve still refuses (exit 4)" "4" "$RC"
assert_json_field "A3: error_key is still unresolved_findings" \
    "$OUT" '.error_key' "unresolved_findings"
assert_contains "A3: the same finding id is still counted open" "R1-F1" "$OUT"
restage "$TID" "src/checkout.ts"
assert_eq "A3: Stop does not release on a sustained dispute" "block" "$(stop_decision)"

# ---------------------------------------------------------------------------
echo ""
echo "=== A4: arbitrate OVERRULE — the decision clears the gate ==="
#
# The LATEST decision wins, so the earlier sustain does not pin the finding
# open forever: an orchestrator that reverses itself on new evidence is doing
# arbitration correctly. Overrule is the only place in the flow where a
# finding is dismissed without a fix, and it costs a written rationale.
OVERRULE_RATIONALE="reviewer position: possible double-charge on gateway timeout (R1-F1, src/checkout.ts:88). Specialist position (F7 decisions): the retry now sends the idempotency key introduced in this same change set, so a re-post is a no-op at the gateway. Decision: OVERRULE — verified the key is set on the retry path; the reviewer's evidence predates that hunk. Follow-up: contract test filed."
ARB_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" arbitrate "$TID" R1-F1 overrule "$OVERRULE_RATIONALE" 2>/dev/null)
assert_json_field "A4: arbitrate overrule is recorded" "$ARB_OUT" '.status' "arbitrated"
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$TID" "finding overruled with a rationale citing both positions" 2>/dev/null) || RC=$?
assert_eq "A4: after OVERRULE approve succeeds (exit 0)" "0" "$RC"
assert_json_field "A4: status=approved" "$OUT" '.status' "approved"
assert_contains "A4: approval observations name the independent reviewer" \
    "independent review verified (reviewed_by=qa-claude" "$OUT"
restage "$TID" "src/checkout.ts"
assert_eq "A4: the Stop hook RELEASES the arbitrated task" "ALLOW" "$(stop_decision)"

# ---------------------------------------------------------------------------
echo ""
echo "=== A5: the audit trail is complete and legible ==="
#
# Both decisions stay on file — an overrule does not erase the sustain that
# preceded it. A reader reconstructs the whole adjudication from the comments.
TRAIL=$(comments_of "$TID")
assert_contains "A5: the SUSTAIN record survives" "ARBITRATION R1-F1 decision=sustain" "$TRAIL"
assert_contains "A5: the OVERRULE record is on file" "ARBITRATION R1-F1 decision=overrule" "$TRAIL"
assert_contains "A5: the sustain rationale cites the REVIEWER's position" \
    "reviewer position: the retry re-posts the charge" "$TRAIL"
assert_contains "A5: the overrule rationale cites the SPECIALIST's position" \
    "Specialist position (F7 decisions): the retry now sends the idempotency key" "$TRAIL"
APPROVAL=$(printf '%s\n' "$TRAIL" | grep '^QA-GATE APPROVED' | tail -1)
assert_contains "A5: the approval record names the reviewer it cleared under" \
    "reviewed_by=qa-claude" "$APPROVAL"
assert_not_contains "A5: the approval is NOT an audited bypass (the gate really passed)" \
    "[review bypass:" "$APPROVAL"

# ---------------------------------------------------------------------------
echo ""
echo "=== A6: RESOLVE with evidence — the other legitimate path ==="
#
# Section 5d offers two ways to clear a finding. A4 proved arbitration; this
# proves the evidence path on an equivalent dispute, with NO arbitration
# record anywhere — so neither path secretly depends on the other.
TID_FIX=$(new_task "arbitration: resolved instead" "src/refund.ts" "backend")
record_artifact "$TID_FIX" 1 "qa-claude" \
    '[{"id":"R1-F1","severity":"critical","location":"src/refund.ts:12","evidence":"refund amount is read from the client payload","description":"client-controlled refund amount"}]'
RC=0
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$TID_FIX" "control: still open" >/dev/null 2>&1 || RC=$?
assert_eq "A6: control — the finding blocks before the fix (exit 4)" "4" "$RC"

# Both refs are mandatory: evidence-before-fix expressed as a record.
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" resolve-finding "$TID_FIX" R1-F1 \
    --fix "src/refund.ts:12" --test "" "no covering test" 2>/dev/null) || RC=$?
assert_eq "A6: resolve-finding REFUSES without a --test reference (exit 1)" "1" "$RC"
assert_json_field "A6: error_key=empty_test" "$OUT" '.error_key' "empty_test"

CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" resolve-finding "$TID_FIX" R1-F1 \
    --fix "src/refund.ts:12 (amount now read from the ledger)" \
    --test "tests/refund.test.sh::rejects-client-amount" \
    "refund amount is authoritative server-side" >/dev/null 2>&1
# Resolving CHANGES FILES, so the change-set legitimately moves: re-stage and
# regenerate the impact report exactly as the real loop does.
printf 'src/refund.ts\ntests/refund.test.sh\n' > "$TRACK/changed-files.txt"
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" "$TID_FIX" >/dev/null 2>&1 || true
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$TID_FIX" "finding resolved with fix + covering test" 2>/dev/null) || RC=$?
assert_eq "A6: after resolve-finding approve succeeds (exit 0)" "0" "$RC"
assert_json_field "A6: status=approved" "$OUT" '.status' "approved"
FIX_TRAIL=$(comments_of "$TID_FIX")
assert_contains "A6: the resolution record carries BOTH refs" \
    "fix=src/refund.ts:12 (amount now read from the ledger) test=tests/refund.test.sh::rejects-client-amount" \
    "$FIX_TRAIL"
assert_not_contains "A6: no arbitration was needed on this path" \
    "ARBITRATION" "$FIX_TRAIL"

[ "$FAIL" -eq 0 ]

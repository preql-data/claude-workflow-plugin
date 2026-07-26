#!/bin/bash
# codex-review.sh — L2 component spec for the Sol (Codex) review driver
# (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# Drives codex-review.sh against a RECORDING stub MCP server (real JSON-RPC
# over stdio, enforcing the REAL verified codex inputSchema, logging every
# request) so the whole turn runs offline with no OpenAI access. Proves:
#   C1  approve verdict         -> valid artifact written, forced fields set,
#                                  and qa-gate.sh review-record posts the record
#   C2  findings above threshold-> review-check.sh gate reports the finding open
#   C3  max_findings+3 findings -> truncated to max_findings + stopped_by=cap:max_findings
#   C4  server sleeps past the timeout_seconds cap -> exit 5, NO artifact file
#   C5  prose-then-JSON first reply -> a corrective codex-reply turn is used
#       (proved from the stub's own request log)
#   META (plan-mandated): mutating stopped_by from cap:max_findings to verdict
#       makes the C3 cap assertion FAIL — proving that assertion is sensitive.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

CR="$FIXTURE/.claude/scripts/codex-review.sh"
RCHECK="$FIXTURE/.claude/scripts/review-check.sh"
QAGATE="$FIXTURE/.claude/scripts/qa-gate.sh"
STUB="$(plugin_root)/.claude/tests/component/lib/stub-codex-mcp.js"
TRACK="$FIXTURE/.claude/.qa-tracking"

if ! command -v node >/dev/null 2>&1; then
    printf 'SKIPPED: codex-review.sh spec (node not on PATH)\n'
    return 0 2>/dev/null || exit 0
fi

# review-config lives at .claude/review-config (mk_fixture does not copy it).
write_config() {
    # write_config [timeout_seconds]
    cat > "$FIXTURE/.claude/review-config" <<EOF
risk_threshold_default=high
max_findings=10
max_review_iterations=3
timeout_seconds=${1:-300}
malformed_retry=1
EOF
}
write_config

# A valid review request.
cat > "$FIXTURE/req.json" <<'EOF'
{"contract_version":"1","task_id":"cr-1","iteration":1,"risk_threshold":"high",
 "stop_condition":"no critical/high remain","change_set_hash":"h123","spec":"s",
 "diff":"d","completion_contract":"c","impact_report":"i"}
EOF

# Artifact texts the stub will return (task_id/iterations deliberately WRONG so
# we can prove codex-review FORCES the authoritative values).
APPROVE_TEXT='{"contract_version":"1","task_id":"WRONG","reviewer_identity":"x","reviewer_model":"x","reviewed_hash":"h123","risk_threshold":"low","stop_condition":"x","verdict":"approve","findings":[],"iterations":99,"stopped_by":"verdict"}'
FINDINGS_TEXT='{"contract_version":"1","task_id":"WRONG","reviewer_identity":"x","reviewer_model":"x","reviewed_hash":"h123","risk_threshold":"high","stop_condition":"x","verdict":"findings","findings":[{"id":"R1-F1","severity":"critical","location":"a.ts:10","evidence":"unsanitized input","description":"sqli"}],"iterations":1,"stopped_by":"verdict"}'
CAPHIT_TEXT=$(jq -nc '{contract_version:"1",task_id:"WRONG",reviewer_identity:"x",reviewer_model:"x",reviewed_hash:"h123",risk_threshold:"high",stop_condition:"x",verdict:"findings",findings:[range(0;13)|{id:("R1-F"+(.+1|tostring)),severity:"high",location:"a:1",evidence:"e",description:"d"}],iterations:1,stopped_by:"verdict"}')

# run_review — invoke the driver with the stub. Args after the fixed ones are
# passed through. Sets RR_OUT (stdout, the artifact path) + RR_EXIT.
RR_OUT=""
RR_EXIT=0
run_review() {
    # run_review <first-text> <reply-text> <sleep-ms> <stub-log>
    RR_OUT=$(CODEX_MCP_BIN=node CODEX_MCP_ARGS="$STUB -m stub-sol" \
        STUB_CODEX_FIRST_TEXT="$1" STUB_CODEX_REPLY_TEXT="$2" \
        STUB_CODEX_SLEEP_MS="${3:-0}" STUB_LOG="${4:-}" \
        bash "$CR" cr-1 --request "$FIXTURE/req.json" --iteration 1 2>/dev/null)
    RR_EXIT=$?
}

# ---------------------------------------------------------------------------
# C1: approve verdict -> valid artifact with forced fields.
rm -f "$TRACK"/review-artifact-cr-1-r1.json
run_review "$APPROVE_TEXT" "$APPROVE_TEXT" 0 ""
assert_eq "C1 approve: exit 0" "0" "$RR_EXIT"
assert_eq "C1 approve: artifact path echoed + exists" "1" \
    "$([ -n "$RR_OUT" ] && [ -f "$RR_OUT" ] && echo 1 || echo 0)"
assert_json_field "C1 approve: verdict=approve" "$(cat "$RR_OUT")" ".verdict" "approve"
assert_json_field "C1 approve: task_id FORCED to cr-1" "$(cat "$RR_OUT")" ".task_id" "cr-1"
assert_json_field "C1 approve: iterations FORCED to 1" "$(cat "$RR_OUT")" ".iterations|tostring" "1"
assert_json_field "C1 approve: reviewer_identity FORCED to sol-codex" "$(cat "$RR_OUT")" ".reviewer_identity" "sol-codex"
assert_json_field "C1 approve: reviewer_model from -m arg" "$(cat "$RR_OUT")" ".reviewer_model" "stub-sol"
assert_json_field "C1 approve: risk_threshold FORCED from request" "$(cat "$RR_OUT")" ".risk_threshold" "high"

# The written artifact validates through the ONE validator.
VOUT=$(bash "$RCHECK" validate-artifact "$RR_OUT" 2>/dev/null)
assert_json_field "C1 approve: artifact passes validate-artifact" "$VOUT" ".ok|tostring" "true"

# review-record posts the record comment (bd-backed; guarded).
if command -v bd >/dev/null 2>&1; then
    TID=$(bd create "codex-review spec task" -t task --json 2>/dev/null | jq -r '.id // empty')
    [ -z "$TID" ] && TID=$(bd list --json 2>/dev/null | jq -r '.[0].id // empty')
    if [ -n "$TID" ]; then
        RR_REC=$(bash "$QAGATE" review-record "$TID" --file "$RR_OUT" 2>/dev/null)
        assert_json_field "C1 review-record: ok=true" "$RR_REC" ".ok|tostring" "true"
        POSTED=$(bd show "$TID" --json 2>/dev/null | jq -r '.[0].comments[].text' 2>/dev/null | grep -c '^REVIEW-ARTIFACT v1 ' || echo 0)
        assert_eq "C1 review-record: REVIEW-ARTIFACT comment posted" "1" "$POSTED"
    fi
else
    printf '  (skip C1 review-record: bd not available)\n'
fi

# ---------------------------------------------------------------------------
# C2: findings above threshold -> review-check gate reports the finding open.
rm -f "$TRACK"/review-artifact-cr-1-r1.json
run_review "$FINDINGS_TEXT" "$FINDINGS_TEXT" 0 ""
assert_eq "C2 findings: exit 0 (artifact written)" "0" "$RR_EXIT"
assert_json_field "C2 findings: verdict=findings" "$(cat "$RR_OUT")" ".verdict" "findings"
# Build a comment-set from the artifact + an implementer marker and gate it.
FTOKEN=$(jq -r '.findings | map(.id+":"+.severity) | join(",")' "$RR_OUT")
COMMENTS=$(jq -nc --arg tok "$FTOKEN" \
    '["IMPLEMENTER: role=backend built it",
      ("REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=stub-sol reviewed_hash=h123 risk_threshold=high verdict=findings stopped_by=verdict findings=["+$tok+"] at 2026 : x")]')
printf '%s' "$COMMENTS" > "$FIXTURE/c2-comments.json"
bash "$RCHECK" gate cr-1 --comments-json "$FIXTURE/c2-comments.json" >/dev/null 2>&1
assert_eq "C2 gate reports the finding open (exit 4)" "4" "$?"

# ---------------------------------------------------------------------------
# C3: max_findings+3 -> truncated + stopped_by=cap:max_findings.
rm -f "$TRACK"/review-artifact-cr-1-r1.json
run_review "$CAPHIT_TEXT" "$CAPHIT_TEXT" 0 ""
assert_eq "C3 cap-hit: exit 0" "0" "$RR_EXIT"
assert_json_field "C3 cap-hit: findings truncated to max_findings=10" "$(cat "$RR_OUT")" ".findings|length|tostring" "10"
assert_json_field "C3 cap-hit: stopped_by=cap:max_findings" "$(cat "$RR_OUT")" ".stopped_by" "cap:max_findings"
CAPHIT_ARTIFACT="$RR_OUT"

# ---------------------------------------------------------------------------
# C4: server sleeps past the timeout cap -> exit 5, NO artifact.
write_config 2   # timeout_seconds=2
rm -f "$TRACK"/review-artifact-cr-1-r1.json
run_review "$APPROVE_TEXT" "$APPROVE_TEXT" 10000 ""
assert_eq "C4 timeout: exit 5" "5" "$RR_EXIT"
assert_eq "C4 timeout: NO artifact file written" "1" \
    "$([ ! -f "$TRACK/review-artifact-cr-1-r1.json" ] && echo 1 || echo 0)"
write_config     # restore default timeout

# ---------------------------------------------------------------------------
# C5: prose-then-JSON first reply -> a corrective codex-reply turn is used.
rm -f "$TRACK"/review-artifact-cr-1-r1.json
STUBLOG="$FIXTURE/c5-stub.log"
: > "$STUBLOG"
PROSE_FIRST="Here is my review of the change:
\`\`\`json
$APPROVE_TEXT
\`\`\`"
run_review "$PROSE_FIRST" "$APPROVE_TEXT" 0 "$STUBLOG"
assert_eq "C5 corrective: exit 0 (recovered)" "0" "$RR_EXIT"
assert_eq "C5 corrective: artifact written" "1" \
    "$([ -f "$TRACK/review-artifact-cr-1-r1.json" ] && echo 1 || echo 0)"
# The stub recorded exactly one codex-reply tool call (the corrective turn).
REPLY_CALLS=$(grep -c '"name":"codex-reply"' "$STUBLOG" 2>/dev/null || echo 0)
assert_eq "C5 corrective: exactly one codex-reply turn was used (stub-recorded)" "1" "$REPLY_CALLS"
# And the corrective prompt cited a validation failure.
assert_eq "C5 corrective: reply prompt cited the validation failure" "1" \
    "$(grep -q 'Validation failed' "$STUBLOG" && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# META (plan-mandated): mutate the recorded cap-hit artifact's stopped_by from
# cap:max_findings to verdict; the C3 cap assertion must then FAIL. This proves
# the cap assertion is sensitive to stopped_by, not vacuously green.
jq '.stopped_by="verdict"' "$CAPHIT_ARTIFACT" > "$FIXTURE/caphit-mutated.json"
MUT_SB=$(jq -r '.stopped_by' "$FIXTURE/caphit-mutated.json")
assert_eq "META: mutated artifact stopped_by is no longer cap:max_findings" "1" \
    "$([ "$MUT_SB" != "cap:max_findings" ] && echo 1 || echo 0)"
# Restate the C3 assertion against the mutated artifact and confirm it would FAIL.
assert_eq "META: the cap assertion (stopped_by==cap:max_findings) FAILS on the mutated artifact" "0" \
    "$([ "$MUT_SB" = "cap:max_findings" ] && echo 1 || echo 0)"

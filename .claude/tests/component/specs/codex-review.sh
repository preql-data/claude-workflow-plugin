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
#   C6  an envelope LARGER than the host's argv limit is marshalled and actually
#       DELIVERED (claude-workflow-plugin-fkm.1.12) — self-calibrating, so it can
#       never go vacuously green on a host with a roomier ARG_MAX
#   C7  an UNBUILDABLE frame fails FAST with a named error and sends NOTHING,
#       instead of writing a blank frame and waiting out the whole budget
#   META (plan-mandated): mutating stopped_by from cap:max_findings to verdict
#       makes the C3 cap assertion FAIL — proving that assertion is sensitive.
#   META (fkm.1.12): excising the sentinel-delimited FRAME GUARD inverts every
#       C7 assertion — reproducing the production hang on demand.
#
# C6/C7 and the fkm.1.12 META need NO Codex server and NO spend: the whole defect
# is upstream of the transport, and the stub's request log is the delivery proof.

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
        POSTED=$(bd_show_with_comments "$TID" | jq -r '.[0].comments[].text' 2>/dev/null | grep -c '^REVIEW-ARTIFACT v1 ' || echo 0)
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
#
# NOTE: $CAPHIT_ARTIFACT is a PATH, and C4/C5 both rewrite that path, so this
# block must stay adjacent to the cr-1 legs it reads from. The fkm.1.12 legs
# below therefore run on task id cr-2 and never touch cr-1's artifact.
jq '.stopped_by="verdict"' "$CAPHIT_ARTIFACT" > "$FIXTURE/caphit-mutated.json"
MUT_SB=$(jq -r '.stopped_by' "$FIXTURE/caphit-mutated.json")
assert_eq "META: mutated artifact stopped_by is no longer cap:max_findings" "1" \
    "$([ "$MUT_SB" != "cap:max_findings" ] && echo 1 || echo 0)"
# Restate the C3 assertion against the mutated artifact and confirm it would FAIL.
assert_eq "META: the cap assertion (stopped_by==cap:max_findings) FAILS on the mutated artifact" "0" \
    "$([ "$MUT_SB" = "cap:max_findings" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# run_driver — like run_review, but parameterised on the SCRIPT and the REQUEST
# so the fkm.1.12 legs can drive mutated copies of the driver without disturbing
# C1-C5. Sets RD_OUT (stdout), RD_EXIT, RD_ERR (stderr text) and RD_SECS (integer
# wall seconds; $SECONDS rather than `date +%s%N`, which BSD date lacks).
#
# TASK ID cr-2, deliberately: every cr-1 leg above shares one artifact path, and
# the C3 META reads that path AFTER C5 rewrites it. Driving cr-2 keeps these legs
# from deleting a file another assertion depends on, whatever the run order.
GUARD_TID="cr-2"
GUARD_ART="$TRACK/review-artifact-$GUARD_TID-r1.json"
RD_OUT=""
RD_EXIT=0
RD_ERR=""
RD_SECS=0
run_driver() {
    # run_driver <script> <request-file> <stub-log> <first-text>
    local script="$1" req="$2" log="$3" text="$4" errf s
    errf="$FIXTURE/rd-stderr.txt"
    : > "$log" 2>/dev/null || true
    s=$SECONDS
    RD_OUT=$(CODEX_MCP_BIN=node CODEX_MCP_ARGS="$STUB -m stub-sol" \
        STUB_CODEX_FIRST_TEXT="$text" STUB_CODEX_REPLY_TEXT="$text" \
        STUB_LOG="$log" \
        bash "$script" "$GUARD_TID" --request "$req" --iteration 1 2>"$errf")
    RD_EXIT=$?
    RD_SECS=$(( SECONDS - s ))
    RD_ERR=$(cat "$errf" 2>/dev/null)
}

# The small request the C7 / META legs drive, derived from req.json so there is
# ONE source of truth for the request shape.
jq -c --arg t "$GUARD_TID" '.task_id=$t' "$FIXTURE/req.json" > "$FIXTURE/req-guard.json"

# ---------------------------------------------------------------------------
# C6: an envelope LARGER than the host's argv limit is marshalled and DELIVERED.
#
# The driver used to build the tools/call frame with `jq --arg p "$ENVELOPE"`,
# putting the ENTIRE review request on jq's command line. Any change set whose
# envelope exceeded the argv limit died at execve with E2BIG, leaving $CALL empty
# — and since `printf '%s\n' "" >&3` returns 0, the driver wrote a BLANK frame,
# the server skipped it, and wait_id waited out the whole timeout_seconds budget
# for a reply to a request that was never sent. Measured in production at 45
# minutes presenting as a paid review in progress (fkm.1.12).
ARGMAX=$(getconf ARG_MAX 2>/dev/null || echo 1048576)
printf '%s' "$ARGMAX" | grep -qE '^[0-9]+$' || ARGMAX=1048576
OVERSIZE=$(( ARGMAX + 32768 ))
if [ "$ARGMAX" -gt 8388608 ]; then
    # Refuse to run a VACUOUS leg. On a host with a pathological ARG_MAX the
    # payload needed to clear it would dominate the suite's runtime; skipping
    # loudly beats asserting nothing quietly.
    printf '  (skip C6: getconf ARG_MAX=%s is too large to probe cheaply)\n' "$ARGMAX"
else
    # An OVERSIZE-byte JSON-safe payload built by pure-bash string doubling — no
    # /dev/zero, no `tr` NUL handling, and no argv anywhere (printf is a builtin,
    # so the generator is not subject to the very limit under test).
    BIGPAD="xxxxxxxxxxxxxxxx"
    while [ "${#BIGPAD}" -lt "$OVERSIZE" ]; do BIGPAD="$BIGPAD$BIGPAD"; done
    BIGPAD="${BIGPAD:0:$OVERSIZE}"

    BIGREQ="$FIXTURE/req-oversize.json"
    {
        printf '%s' '{"contract_version":"1","task_id":"cr-2","iteration":1,'
        printf '%s' '"risk_threshold":"high","stop_condition":"no critical/high remain",'
        printf '%s' '"change_set_hash":"h123","spec":"s","completion_contract":"c",'
        printf '%s' '"impact_report":"i","diff":"'
        printf '%s' "$BIGPAD"
        printf '%s' '"}'
    } > "$BIGREQ"

    BIGREQ_BYTES=$(wc -c < "$BIGREQ" 2>/dev/null | tr -d '[:space:]')
    assert_eq "C6 fixture: the request exceeds getconf ARG_MAX=$ARGMAX (${BIGREQ_BYTES:-0} bytes)" "1" \
        "$([ "${BIGREQ_BYTES:-0}" -gt "$ARGMAX" ] && echo 1 || echo 0)"
    assert_eq "C6 fixture: the oversize request is valid JSON" "1" \
        "$(jq -e . "$BIGREQ" >/dev/null 2>&1 && echo 1 || echo 0)"
    # Size is a TRANSPORT property, not a schema one: the request the driver
    # choked on was perfectly valid, which is why exit 4 would be the wrong code.
    BIGVR=$(bash "$RCHECK" validate-request "$BIGREQ" 2>/dev/null)
    assert_json_field "C6 fixture: the oversize request PASSES validate-request" \
        "$BIGVR" ".ok|tostring" "true"

    # CALIBRATION — the assertion that keeps this leg honest. The OLD argv form
    # must GENUINELY fail on this payload on THIS host. If it ever starts
    # succeeding, C6 proves nothing and OVERSIZE needs raising. (Linux caps a
    # SINGLE argument at MAX_ARG_STRLEN = 128KB, far below its ARG_MAX, so sizing
    # off getconf ARG_MAX clears the real limit on both platforms.)
    ARGV_PROBE=$(jq -nc --arg p "$BIGPAD" '{p:$p}' 2>/dev/null || true)
    assert_eq "C6 calibration: the OLD --arg argv form genuinely fails on this payload" "1" \
        "$([ -z "$ARGV_PROBE" ] && echo 1 || echo 0)"

    write_config 30
    rm -f "$GUARD_ART"
    C6LOG="$FIXTURE/c6-stub.log"
    run_driver "$CR" "$BIGREQ" "$C6LOG" "$APPROVE_TEXT"
    assert_eq "C6 oversize: exit 0 — the frame marshalled instead of dying at execve" "0" "$RD_EXIT"
    assert_eq "C6 oversize: artifact path echoed + exists" "1" \
        "$([ -n "$RD_OUT" ] && [ -f "$RD_OUT" ] && echo 1 || echo 0)"
    # DETERMINISTIC delivery proof, no timing involved: the stub logs only frames
    # it actually PARSED and it skips blank lines, so a tools/call entry can exist
    # ONLY if a real frame crossed the transport intact.
    assert_contains "C6 oversize: a tools/call frame reached the server" \
        '"method":"tools/call"' "$(cat "$C6LOG" 2>/dev/null)"
    DELIVERED=$(jq -r 'select(.method=="tools/call" and .params.name=="codex")
        | .params.arguments.prompt | length' "$C6LOG" 2>/dev/null | head -1)
    assert_eq "C6 oversize: the server received the WHOLE prompt (${DELIVERED:-0} chars > ARG_MAX $ARGMAX)" "1" \
        "$([ "${DELIVERED:-0}" -gt "$ARGMAX" ] && echo 1 || echo 0)"
    assert_eq "C6 oversize: returned in ${RD_SECS}s against a 30s budget (never waited for the deadline)" "1" \
        "$([ "$RD_SECS" -lt 10 ] && echo 1 || echo 0)"
    write_config
fi

# ---------------------------------------------------------------------------
# C7: an UNBUILDABLE frame fails FAST with the named error and sends NOTHING.
#
# The FRAME GUARD is the second half of fkm.1.12 and it is NOT redundant with the
# --rawfile fix: send_frame cannot detect an empty $CALL on its own, because
# `printf '%s\n' "" >&3` succeeds. Proved on a MUTATED copy of the canonical
# driver whose --rawfile source points at a file that is not there, so the REAL
# jq invocation fails exactly the way a failed marshal does in production.
MUT="$FIXTURE/codex-review-badframe.sh"
sed 's|--rawfile p "$ENVELOPE_FILE"|--rawfile p "$WORK/no-such-envelope.txt"|' \
    "$(plugin_root)/.claude/scripts/codex-review.sh" > "$MUT"
assert_eq "C7 mutation applied: the frame build now reads a nonexistent envelope" "1" \
    "$(grep -c 'no-such-envelope' "$MUT" 2>/dev/null | tr -d '[:space:]')"
assert_eq "C7 mutation: the mutated copy still parses as bash" "1" \
    "$(bash -n "$MUT" 2>/dev/null && echo 1 || echo 0)"

write_config 30
rm -f "$GUARD_ART"
C7LOG="$FIXTURE/c7-stub.log"
run_driver "$MUT" "$FIXTURE/req-guard.json" "$C7LOG" "$APPROVE_TEXT"
assert_eq "C7 guard: exit 5 — no artifact, caller degrades to the Claude lane" "5" "$RD_EXIT"
assert_contains "C7 guard: names the MARSHALLING failure, not a timeout" \
    "could not marshal the codex tool call" "$RD_ERR"
assert_contains "C7 guard: tells the operator nothing was sent (so nothing was billed)" \
    "nothing was sent, no artifact" "$RD_ERR"
assert_eq "C7 guard: NO artifact written" "1" \
    "$([ ! -f "$GUARD_ART" ] && echo 1 || echo 0)"
assert_not_contains "C7 guard: no frame reached the server — no blank write" \
    '"method":"tools/call"' "$(cat "$C7LOG" 2>/dev/null)"
assert_eq "C7 guard: failed FAST — ${RD_SECS}s against a 30s budget" "1" \
    "$([ "$RD_SECS" -lt 10 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# META (fkm.1.12): excise the sentinel-delimited FRAME GUARD from that same
# mutated copy. Every C7 assertion must INVERT — the driver writes a blank frame,
# the server skips it, and wait_id burns the ENTIRE timeout_seconds budget
# reporting a timeout for a request that was never sent. This reproduces the
# production defect on demand and proves C7 is sensitive to the guard's presence
# rather than vacuously green.
MUT_NOGUARD="$FIXTURE/codex-review-badframe-noguard.sh"
awk '/^# FRAME-GUARD BEGIN \(/{skip=1} !skip{print} /^# FRAME-GUARD END \(/{skip=0}' \
    "$MUT" > "$MUT_NOGUARD"
assert_eq "META: the FRAME-GUARD block is gone from the no-guard copy" "0" \
    "$(grep -c 'FRAME-GUARD' "$MUT_NOGUARD" 2>/dev/null | tr -d '[:space:]')"
assert_eq "META: excising the guard actually removed lines" "1" \
    "$([ "$(wc -l < "$MUT")" -gt "$(wc -l < "$MUT_NOGUARD")" ] && echo 1 || echo 0)"
assert_eq "META: the no-guard copy still parses as bash" "1" \
    "$(bash -n "$MUT_NOGUARD" 2>/dev/null && echo 1 || echo 0)"
assert_eq "META: the no-guard copy still reaches send_frame" "1" \
    "$(grep -cF 'send_frame "$CALL"' "$MUT_NOGUARD" 2>/dev/null | tr -d '[:space:]')"

# A SMALL budget here: this leg must PAY for the hang it proves, so keep it cheap.
write_config 3
rm -f "$GUARD_ART"
METALOG="$FIXTURE/meta-stub.log"
run_driver "$MUT_NOGUARD" "$FIXTURE/req-guard.json" "$METALOG" "$APPROVE_TEXT"
# This is WHY the defect survived: the exit code is identical either way, so the
# caller cannot tell a 45-minute phantom review from a genuine server timeout.
assert_eq "META: without the guard the exit code is UNCHANGED (5) — invisible to the caller" "5" "$RD_EXIT"
assert_not_contains "META: without the guard the marshalling failure is NEVER named" \
    "could not marshal the codex tool call" "$RD_ERR"
assert_contains "META: without the guard it misreports a wall-clock timeout instead" \
    "exceeded 3s wall-clock budget" "$RD_ERR"
assert_eq "META: without the guard it burned the WHOLE 3s budget (${RD_SECS}s) on a request never sent" "1" \
    "$([ "$RD_SECS" -ge 3 ] && echo 1 || echo 0)"
assert_not_contains "META: and still no frame reached the server" \
    '"method":"tools/call"' "$(cat "$METALOG" 2>/dev/null)"
write_config


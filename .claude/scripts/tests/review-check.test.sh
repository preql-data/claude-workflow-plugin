#!/bin/bash
# review-check.test.sh — L1 unit fixture for .claude/scripts/review-check.sh
# (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# review-check.sh is the ONE reviewer-record validator + counter. This tier
# pins the two schema validators:
#   1. validate-request — the request-envelope schema (mandatory-non-empty
#      risk_threshold / stop_condition with their dedicated error keys, enum,
#      and generic missing_key:<k>).
#   2. validate-artifact — the full artifact schema matrix (missing_key,
#      verdict/ stopped_by enums, per-finding shape, id grammar, severity enum).
#   3. META (required by the plan): a checker copy with the mandatory-field
#      guard STRIPPED must PASS a fixture the real checker REJECTS — proving the
#      guard is load-bearing, not vacuous.
#
# The gate/count predicate is covered separately in review-count.test.sh.
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
RCHECK="$PROJECT_DIR/.claude/scripts/review-check.sh"

if [ ! -f "$RCHECK" ]; then
    printf 'review-check.test: script under test missing: %s\n' "$RCHECK" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    printf 'review-check.test: jq is required\n' >&2
    exit 2
fi

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

WORK=$(mktemp -d -t review-check-test.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# run_rc <args...> -> sets RC_OUT (stdout) + RC_EXIT (exit code).
RC_OUT=""
RC_EXIT=0
run_rc() {
    RC_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RCHECK" "$@" 2>/dev/null)
    RC_EXIT=$?
}
ekey_of() { printf '%s' "$1" | jq -r '.error_key // ""' 2>/dev/null || echo ""; }

# A valid request + artifact used as the mutation base.
VALID_REQ='{"contract_version":"1","task_id":"t-1","iteration":1,"risk_threshold":"high","stop_condition":"no critical/high remain","change_set_hash":"h","spec":"s","diff":"d","completion_contract":"c","impact_report":"i"}'
VALID_ART='{"contract_version":"1","task_id":"t-1","reviewer_identity":"sol-codex","reviewer_model":"m","reviewed_hash":"h","risk_threshold":"high","stop_condition":"x","verdict":"findings","findings":[{"id":"R1-F1","severity":"high","location":"a.ts:1","evidence":"e","description":"d"}],"iterations":1,"stopped_by":"verdict"}'

# ---------------------------------------------------------------------------
echo "=== Section 1: validate-request ==="

printf '%s' "$VALID_REQ" > "$WORK/req_ok.json"
run_rc validate-request "$WORK/req_ok.json"
assert_eq "req valid: exit 0" "0" "$RC_EXIT"
assert_eq "req valid: ok=true" "true" "$(printf '%s' "$RC_OUT" | jq -r '.ok')"

printf '%s' "$VALID_REQ" | jq 'del(.risk_threshold)' > "$WORK/req_nort.json"
run_rc validate-request "$WORK/req_nort.json"
assert_eq "req missing risk_threshold: exit 4" "4" "$RC_EXIT"
assert_eq "req missing risk_threshold: error_key" "missing_risk_threshold" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_REQ" | jq 'del(.stop_condition)' > "$WORK/req_nosc.json"
run_rc validate-request "$WORK/req_nosc.json"
assert_eq "req missing stop_condition: exit 4" "4" "$RC_EXIT"
assert_eq "req missing stop_condition: error_key" "missing_stop_condition" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_REQ" | jq '.risk_threshold="banana"' > "$WORK/req_badenum.json"
run_rc validate-request "$WORK/req_badenum.json"
assert_eq "req bad enum: exit 4" "4" "$RC_EXIT"
assert_eq "req bad enum: error_key" "risk_threshold_invalid_enum" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_REQ" | jq 'del(.change_set_hash)' > "$WORK/req_nokey.json"
run_rc validate-request "$WORK/req_nokey.json"
assert_eq "req missing generic key: exit 4" "4" "$RC_EXIT"
assert_eq "req missing generic key: error_key" "missing_key:change_set_hash" "$(ekey_of "$RC_OUT")"

printf 'not json{' > "$WORK/req_badjson.json"
run_rc validate-request "$WORK/req_badjson.json"
assert_eq "req invalid json: exit 4" "4" "$RC_EXIT"
assert_eq "req invalid json: error_key" "invalid_json" "$(ekey_of "$RC_OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: validate-artifact matrix ==="

printf '%s' "$VALID_ART" > "$WORK/art_ok.json"
run_rc validate-artifact "$WORK/art_ok.json"
assert_eq "art valid: exit 0" "0" "$RC_EXIT"
assert_eq "art valid: ok=true" "true" "$(printf '%s' "$RC_OUT" | jq -r '.ok')"

printf '%s' "$VALID_ART" | jq 'del(.stopped_by)' > "$WORK/art_nokey.json"
run_rc validate-artifact "$WORK/art_nokey.json"
assert_eq "art missing key: error_key" "missing_key:stopped_by" "$(ekey_of "$RC_OUT")"
assert_eq "art missing key: exit 4" "4" "$RC_EXIT"

printf '%s' "$VALID_ART" | jq '.verdict="maybe"' > "$WORK/art_badverdict.json"
run_rc validate-artifact "$WORK/art_badverdict.json"
assert_eq "art bad verdict: error_key" "verdict_invalid_enum" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.stopped_by="cap:whatever"' > "$WORK/art_badstopped.json"
run_rc validate-artifact "$WORK/art_badstopped.json"
assert_eq "art bad stopped_by: error_key" "stopped_by_invalid_enum" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.findings[0].id="F1"' > "$WORK/art_badid.json"
run_rc validate-artifact "$WORK/art_badid.json"
assert_eq "art malformed finding id: error_key" "finding_id_malformed" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.findings[0].severity="spicy"' > "$WORK/art_badsev.json"
run_rc validate-artifact "$WORK/art_badsev.json"
assert_eq "art bad severity: error_key" "severity_invalid_enum" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq 'del(.findings[0].evidence)' > "$WORK/art_noevidence.json"
run_rc validate-artifact "$WORK/art_noevidence.json"
assert_eq "art finding missing evidence: error_key" "finding_item_invalid:missing_evidence" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.findings=["not-an-object"]' > "$WORK/art_finding_notobj.json"
run_rc validate-artifact "$WORK/art_finding_notobj.json"
assert_eq "art finding not object: error_key" "finding_item_invalid:not_object" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.findings="nope"' > "$WORK/art_findings_notarray.json"
run_rc validate-artifact "$WORK/art_findings_notarray.json"
assert_eq "art findings not array: error_key" "finding_item_invalid:not_array" "$(ekey_of "$RC_OUT")"

# approve with empty findings is valid (the common no-findings case).
printf '%s' "$VALID_ART" | jq '.verdict="approve" | .findings=[]' > "$WORK/art_approve.json"
run_rc validate-artifact "$WORK/art_approve.json"
assert_eq "art approve empty findings: exit 0" "0" "$RC_EXIT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2b: control characters in grammar-bearing scalars (vg8) ==="
# DEFECT CLASS (claude-workflow-plugin-vg8): a schema-VALID artifact whose
# header scalar carries an embedded newline is embedded verbatim by
# qa-gate.sh review-record into the ONE-LINE record comment. The newline splits
# the record, pushing findings=[...] onto line 2, and the gate's first-line read
# then reports ZERO open findings — silently suppressing a real critical
# finding. Layer 1 of the fix: reject control chars in every scalar that the
# record grammar embeds.

printf '%s' "$VALID_ART" | jq '.reviewed_hash="h\nEVIL-SECOND-LINE"' > "$WORK/art_nl_hash.json"
run_rc validate-artifact "$WORK/art_nl_hash.json"
assert_eq "art newline in reviewed_hash: exit 4" "4" "$RC_EXIT"
assert_eq "art newline in reviewed_hash: error_key" "scalar_contains_control_char:reviewed_hash" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.reviewer_identity="sol\rcodex"' > "$WORK/art_cr_rev.json"
run_rc validate-artifact "$WORK/art_cr_rev.json"
assert_eq "art CR in reviewer_identity: error_key" "scalar_contains_control_char:reviewer_identity" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.reviewer_model="m\tspoof"' > "$WORK/art_tab_model.json"
run_rc validate-artifact "$WORK/art_tab_model.json"
assert_eq "art tab in reviewer_model: error_key" "scalar_contains_control_char:reviewer_model" "$(ekey_of "$RC_OUT")"

# A finding id/severity also enters the record (the findings=[...] token): a
# newline there would break the token's closing bracket and suppress the count.
printf '%s' "$VALID_ART" | jq '.findings[0].id="R1-F1\nR9-F9"' > "$WORK/art_nl_fid.json"
run_rc validate-artifact "$WORK/art_nl_fid.json"
assert_eq "art newline in finding id: exit 4" "4" "$RC_EXIT"
assert_eq "art newline in finding id: error_key" "scalar_contains_control_char:findings[].id" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.findings[0].severity="hi\ngh"' > "$WORK/art_nl_fsev.json"
run_rc validate-artifact "$WORK/art_nl_fsev.json"
assert_eq "art newline in finding severity: error_key" "scalar_contains_control_char:findings[].severity" "$(ekey_of "$RC_OUT")"

# PRECISION: the free-form prose fields (location/evidence/description) never
# enter the one-line record, so a multi-line description from a real reviewer
# must still be ACCEPTED. A blanket control-char ban would reject legitimate
# Sol output and burn a corrective retry for no safety gain.
printf '%s' "$VALID_ART" | jq '.findings[0].description="line one\nline two"' > "$WORK/art_nl_desc.json"
run_rc validate-artifact "$WORK/art_nl_desc.json"
assert_eq "art newline in free-form description: still ACCEPTED (exit 0)" "0" "$RC_EXIT"
printf '%s' "$VALID_ART" | jq '.findings[0].evidence="saw:\n  foo()"' > "$WORK/art_nl_ev.json"
run_rc validate-artifact "$WORK/art_nl_ev.json"
assert_eq "art newline in free-form evidence: still ACCEPTED (exit 0)" "0" "$RC_EXIT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: META — the mandatory-field guard is load-bearing ==="
# Build a checker copy with the MANDATORY-NONEMPTY guard block stripped. A
# fixture that is otherwise valid but MISSING stop_condition (valid enum
# risk_threshold, so the enum check after the block still passes) must:
#   - be REJECTED by the real checker (missing_stop_condition, exit 4), and
#   - PASS the stripped checker (exit 0).
# If the stripped copy still rejected it, the guard would be vacuous.
STRIPPED="$WORK/review-check-stripped.sh"
awk '
    /# MANDATORY-NONEMPTY-START/ {skip=1; next}
    /# MANDATORY-NONEMPTY-END/   {skip=0; next}
    skip!=1 {print}
' "$RCHECK" > "$STRIPPED"
chmod +x "$STRIPPED"

# Sanity: the strip actually removed lines (the guard block existed).
REAL_LINES=$(wc -l < "$RCHECK" | tr -d ' ')
STRIP_LINES=$(wc -l < "$STRIPPED" | tr -d ' ')
assert_eq "META: strip removed the guard block (fewer lines)" "1" \
    "$([ "$STRIP_LINES" -lt "$REAL_LINES" ] && echo 1 || echo 0)"
# Sanity: the stripped copy is still syntactically valid bash.
assert_eq "META: stripped checker parses" "0" \
    "$(bash -n "$STRIPPED" 2>/dev/null && echo 0 || echo 1)"

# The bad fixture: valid risk_threshold, MISSING stop_condition.
printf '%s' "$VALID_REQ" | jq 'del(.stop_condition)' > "$WORK/meta_bad.json"

run_rc validate-request "$WORK/meta_bad.json"
assert_eq "META: REAL checker rejects the bad fixture (exit 4)" "4" "$RC_EXIT"
assert_eq "META: REAL checker names missing_stop_condition" "missing_stop_condition" "$(ekey_of "$RC_OUT")"

STRIP_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STRIPPED" validate-request "$WORK/meta_bad.json" 2>/dev/null)
STRIP_EXIT=$?
assert_eq "META: STRIPPED checker PASSES the bad fixture (exit 0) -> guard is load-bearing" "0" "$STRIP_EXIT"
assert_eq "META: STRIPPED checker reports ok=true" "true" "$(printf '%s' "$STRIP_OUT" | jq -r '.ok')"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

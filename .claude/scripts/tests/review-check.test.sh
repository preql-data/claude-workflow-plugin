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
VALID_REQ='{"contract_version":"1","task_id":"t-1","iteration":1,"risk_threshold":"high","stop_condition":"no critical/high remain","change_set_hash":"cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe","spec":"s","diff":"d","completion_contract":"c","impact_report":"i"}'
VALID_ART='{"contract_version":"1","task_id":"t-1","reviewer_identity":"sol-codex","reviewer_model":"m","reviewer_pin":"m","reviewed_hash":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef","risk_threshold":"high","stop_condition":"x","verdict":"findings","findings":[{"id":"R1-F1","severity":"high","location":"a.ts:1","evidence":"e","description":"d"}],"iterations":1,"stopped_by":"verdict"}'

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
echo "=== Section 1b: change_set_hash SHAPE guard (claude-workflow-plugin-wob2 R1-F2) ==="
# THE GAP THIS CLOSES: independent review round 1 of wob2 (R1-F2) measured
# that codex-review.sh's FORCED-field expression did not force reviewed_hash,
# and that change_set_hash had NO shape check on the REQUEST schema at all —
# VALID_REQ itself carried "change_set_hash":"h" and validated. A malformed
# change_set_hash could therefore reach a paid Sol turn and only be refused
# AFTER the spend, once cmd_validate_artifact's reviewed_hash_unusable check
# saw the (now-forced) value. This closes the gap at the earliest boundary:
# the REQUEST itself.
REQ_HASH64=$(printf 'e%.0s' $(seq 1 64))
REQ_HASH63=$(printf 'e%.0s' $(seq 1 63))
assert_eq "1b setup: REQ_HASH64 (control) is exactly 64 chars" "64" "${#REQ_HASH64}"
assert_eq "1b setup: REQ_HASH63 is exactly 63 chars" "63" "${#REQ_HASH63}"

printf '%s' "$VALID_REQ" | jq --arg h "$REQ_HASH63" '.change_set_hash=$h' > "$WORK/req_csh_short.json"
run_rc validate-request "$WORK/req_csh_short.json"
assert_eq "1b change_set_hash 63 hex chars (too short): exit 4" "4" "$RC_EXIT"
assert_eq "1b change_set_hash 63 hex chars: error_key" "change_set_hash_unusable" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_REQ" | jq '.change_set_hash=""' > "$WORK/req_csh_empty.json"
run_rc validate-request "$WORK/req_csh_empty.json"
assert_eq "1b change_set_hash empty string: exit 4" "4" "$RC_EXIT"
assert_eq "1b change_set_hash empty string: error_key" "change_set_hash_unusable" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_REQ" | jq '.change_set_hash="DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"' > "$WORK/req_csh_upper.json"
run_rc validate-request "$WORK/req_csh_upper.json"
assert_eq "1b change_set_hash UPPERCASE (64 chars, wrong case): exit 4" "4" "$RC_EXIT"
assert_eq "1b change_set_hash uppercase: error_key" "change_set_hash_unusable" "$(ekey_of "$RC_OUT")"

# SYMMETRY WITH reviewed_hash, reversing round 1's own exemption
# (claude-workflow-plugin-wob2 R2-F3). Round 1 shipped this arm ACCEPTING the
# SHA-256 empty-content sentinel, reasoning that a genuinely empty change set
# must still reach the review flow; independent review round 2 traced that
# path end to end and found the exemption never delivered that outcome (a
# sentinel request still spent a paid review turn and only failed one step
# later, at the artifact recorder) — the exact pre-spend waste this guard
# exists to prevent. The sentinel is now refused HERE too, same error_key as
# the shape arms, so a genuinely empty (or wholly-denylisted) change set is
# caught before any spend rather than after one.
SENTINEL_HASH_1B="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
printf '%s' "$VALID_REQ" | jq --arg h "$SENTINEL_HASH_1B" '.change_set_hash=$h' > "$WORK/req_csh_sentinel.json"
run_rc validate-request "$WORK/req_csh_sentinel.json"
assert_eq "1b change_set_hash SENTINEL is now REFUSED (exit 4) -- symmetric with reviewed_hash, no more pre-artifact spend on a degenerate request" \
    "4" "$RC_EXIT"
assert_eq "1b change_set_hash SENTINEL: error_key" "change_set_hash_unusable" "$(ekey_of "$RC_OUT")"

# Discriminator: the unmodified VALID_REQ still passes.
run_rc validate-request "$WORK/req_ok.json"
assert_eq "1b discriminator: unmutated VALID_REQ still exit 0" "0" "$RC_EXIT"

# META (pairing requirement): a checker copy with CHANGE-SET-HASH-GUARD
# stripped must ACCEPT the exact shape-bad fixture above.
CSHGUARD_STRIPPED="$WORK/review-check-nocshguard.sh"
awk '
    /# CHANGE-SET-HASH-GUARD-START/ {skip=1; next}
    /# CHANGE-SET-HASH-GUARD-END/   {skip=0; next}
    skip!=1 {print}
' "$RCHECK" > "$CSHGUARD_STRIPPED"
chmod +x "$CSHGUARD_STRIPPED"

CSH_REAL_LINES=$(wc -l < "$RCHECK" | tr -d ' ')
CSH_STRIP_LINES=$(wc -l < "$CSHGUARD_STRIPPED" | tr -d ' ')
assert_eq "1b META: strip removed the guard block (fewer lines)" "1" \
    "$([ "$CSH_STRIP_LINES" -lt "$CSH_REAL_LINES" ] && echo 1 || echo 0)"
assert_eq "1b META: stripped checker parses" "0" \
    "$(bash -n "$CSHGUARD_STRIPPED" 2>/dev/null && echo 0 || echo 1)"

CSH_STRIP_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$CSHGUARD_STRIPPED" validate-request "$WORK/req_csh_short.json" 2>/dev/null)
CSH_STRIP_EXIT=$?
assert_eq "1b META: STRIPPED checker WRONGLY accepts a 63-hex change_set_hash (exit 0) -> guard is load-bearing" \
    "0" "$CSH_STRIP_EXIT"
assert_eq "1b META: stripped checker reports ok=true" "true" \
    "$(printf '%s' "$CSH_STRIP_OUT" | jq -r '.ok')"
run_rc validate-request "$WORK/req_csh_short.json"
assert_eq "1b META: REAL checker still rejects the same fixture (exit 4)" "4" "$RC_EXIT"

# Bonus confirmation: the SAME stripped copy also wrongly accepts the
# sentinel fixture -- the whole guard was removed, sentinel arm included, not
# merely the shape half of it.
CSH_STRIP_SENTINEL_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$CSHGUARD_STRIPPED" validate-request "$WORK/req_csh_sentinel.json" 2>/dev/null)
assert_eq "1b META bonus: STRIPPED checker also wrongly accepts the sentinel (whole guard removed, not half of it)" \
    "true" "$(printf '%s' "$CSH_STRIP_SENTINEL_OUT" | jq -r '.ok')"
run_rc validate-request "$WORK/req_csh_sentinel.json"
assert_eq "1b META bonus: REAL checker still rejects the sentinel fixture (exit 4)" "4" "$RC_EXIT"

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
echo "=== Section 2c: iterations type + integer guard (claude-workflow-plugin-k6re R11-F1) ==="
# MEASURED defect (R11-F1, independent review round 11 of claude-workflow-
# plugin-i8cx): the has()-only check in Section 2 accepted ANY value under
# `iterations` as long as the key was present. qa-gate.sh cmd_review_record
# then read it back with `jq -r '.iterations'` and interpolated the result
# VERBATIM into the REVIEW-ARTIFACT record's machine prefix as
# `iteration=$iter` -- and the selector (review-count.test.sh section 11)
# refuses its ENTIRE candidate set forever on one unparseable iteration=
# token, with no recovery, because bd comments are append-only. This section
# pins the writer-side half of the fix: reject before that record is ever
# written. The selector-side recovery half is pinned separately in
# review-count.test.sh section 11.9.

printf '%s' "$VALID_ART" | jq '.iterations=1.5' > "$WORK/art_iter_decimal.json"
run_rc validate-artifact "$WORK/art_iter_decimal.json"
assert_eq "art iterations=1.5: exit 4" "4" "$RC_EXIT"
assert_eq "art iterations=1.5: error_key=iterations_not_integer" "iterations_not_integer" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.iterations="oops"' > "$WORK/art_iter_string.json"
run_rc validate-artifact "$WORK/art_iter_string.json"
assert_eq "art iterations=\"oops\" (non-numeric string): exit 4" "4" "$RC_EXIT"
assert_eq "art iterations=\"oops\": error_key=iterations_not_number (type checked before shape)" \
    "iterations_not_number" "$(ekey_of "$RC_OUT")"

# 1e3: THIS jq version renders the JSON literal back out as "1E+3", not
# "1000" (verified directly against the installed jq, not assumed — see the
# comment on the guard itself). Pinned here so a jq upgrade that changes this
# normalisation is caught by a red assertion rather than silently accepted.
printf '%s' "$VALID_ART" | jq '.iterations=1e3' > "$WORK/art_iter_exp.json"
run_rc validate-artifact "$WORK/art_iter_exp.json"
assert_eq "art iterations=1e3: exit 4" "4" "$RC_EXIT"
assert_eq "art iterations=1e3: error_key=iterations_not_integer (non-normalised exponent form)" \
    "iterations_not_integer" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.iterations=-3' > "$WORK/art_iter_neg.json"
run_rc validate-artifact "$WORK/art_iter_neg.json"
assert_eq "art iterations=-3: error_key=iterations_not_integer" "iterations_not_integer" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.iterations=null' > "$WORK/art_iter_null.json"
run_rc validate-artifact "$WORK/art_iter_null.json"
assert_eq "art iterations=null: error_key=iterations_not_number" "iterations_not_number" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.iterations=true' > "$WORK/art_iter_bool.json"
run_rc validate-artifact "$WORK/art_iter_bool.json"
assert_eq "art iterations=true: error_key=iterations_not_number" "iterations_not_number" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.iterations=[1,2]' > "$WORK/art_iter_array.json"
run_rc validate-artifact "$WORK/art_iter_array.json"
assert_eq "art iterations=[1,2] (array, jq -r would print MULTI-LINE): error_key=iterations_not_number" \
    "iterations_not_number" "$(ekey_of "$RC_OUT")"

# Boundary: 0 is a non-negative integer, same convention as the RUBRIC
# iteration check (qa-gate.sh cmd_grade_record) this guard mirrors.
printf '%s' "$VALID_ART" | jq '.iterations=0' > "$WORK/art_iter_zero.json"
run_rc validate-artifact "$WORK/art_iter_zero.json"
assert_eq "art iterations=0: exit 0 (boundary: non-negative integer)" "0" "$RC_EXIT"

# ITERATIONS SAFE-MAGNITUDE GUARD (claude-workflow-plugin-k6re, R1-F1).
# MEASURED defect (independent review round 1, reviewed_hash
# 5a3e65de46593b76cea7c11b4717cf7888c48b50d0e84f7467bd9961b889bb1c): the
# guard above confirms SHAPE (type=number, string form matches ^[0-9]+$) but
# never MAGNITUDE. This host's jq (1.8.1) round-trips `.iterations` exactly
# even past 2^53 (verified below, 2c-mag-0), so this is not about THIS jq
# losing precision -- it is about the value being nonsense for any real
# review round, and every OTHER consumer of this JSON not sharing this
# host's exact jq behaviour (JavaScript, many JSON libraries, and this same
# file's own selector -- see review-count.test.sh section 11.10 -- all read
# JSON numbers as an IEEE-754 double). The bound is 9007199254740991
# (2^53-1, Number.MAX_SAFE_INTEGER): the largest integer for which N and N+1
# are both exactly representable and distinguishable as a double.
printf '%s' "$VALID_ART" | jq '.iterations=9007199254740991' > "$WORK/art_iter_bound_ok.json"
run_rc validate-artifact "$WORK/art_iter_bound_ok.json"
assert_eq "art iterations=9007199254740991 (exactly 2^53-1): exit 0 (boundary is INCLUSIVE)" "0" "$RC_EXIT"

printf '%s' "$VALID_ART" | jq '.iterations=9007199254740992' > "$WORK/art_iter_bound_bad.json"
run_rc validate-artifact "$WORK/art_iter_bound_bad.json"
assert_eq "art iterations=9007199254740992 (2^53-1 + 1): exit 4" "4" "$RC_EXIT"
assert_eq "art iterations=9007199254740992: error_key=iterations_exceeds_safe_bound" \
    "iterations_exceeds_safe_bound" "$(ekey_of "$RC_OUT")"

# The finding's own example value (R1-F1's evidence cites this exact
# number as the one the selector could not distinguish from the bound).
printf '%s' "$VALID_ART" | jq '.iterations=9007199254740993' > "$WORK/art_iter_r1f1.json"
run_rc validate-artifact "$WORK/art_iter_r1f1.json"
assert_eq "art iterations=9007199254740993 (the R1-F1 finding's own example): exit 4" "4" "$RC_EXIT"
assert_eq "art iterations=9007199254740993: error_key=iterations_exceeds_safe_bound" \
    "iterations_exceeds_safe_bound" "$(ekey_of "$RC_OUT")"

# A legitimately large-but-sane value (nowhere near a real review count, but
# nowhere near the representability bound either) must still pass -- the
# guard rejects magnitude that is UNSAFE, never magnitude that is merely
# large relative to typical single/double-digit review round counts.
printf '%s' "$VALID_ART" | jq '.iterations=999999999999999' > "$WORK/art_iter_large_sane.json"
run_rc validate-artifact "$WORK/art_iter_large_sane.json"
assert_eq "art iterations=999999999999999 (large but safely representable): exit 0" "0" "$RC_EXIT"

# 2c-mag-0 PLATFORM FACT this whole guard is measured against: THIS jq
# preserves the R1-F1 example value exactly on a bare pass-through (proving
# the guard is not compensating for jq's own precision loss, and pinning
# the fact so a future jq change that stops preserving it is caught by a
# red assertion here rather than silently changing what this guard means).
assert_eq "2c-mag-0 platform fact: this jq round-trips 9007199254740993 exactly (no precision loss at THIS layer)" \
    "9007199254740993" "$(printf '{"iterations":9007199254740993}' | jq -r '.iterations')"

# DISCRIMINATOR: the unmodified VALID_ART (iterations=1) still passes,
# proving the assertions above fail because of the specific mutation, not
# because Section 2c broke validate-artifact generally.
run_rc validate-artifact "$WORK/art_ok.json"
assert_eq "art iterations=1 (control, from Section 2): still exit 0" "0" "$RC_EXIT"

# META (required by .claude/tests/README.md's pairing requirement): a
# checker copy with the ITERATIONS-GUARD stripped must ACCEPT the exact
# fixture Section 2c rejects above, proving the guard is load-bearing.
ITER_STRIPPED="$WORK/review-check-noiterguard.sh"
awk '
    /# ITERATIONS-GUARD-START/ {skip=1; next}
    /# ITERATIONS-GUARD-END/   {skip=0; next}
    skip!=1 {print}
' "$RCHECK" > "$ITER_STRIPPED"
chmod +x "$ITER_STRIPPED"

ITER_REAL_LINES=$(wc -l < "$RCHECK" | tr -d ' ')
ITER_STRIP_LINES=$(wc -l < "$ITER_STRIPPED" | tr -d ' ')
assert_eq "META iterations-guard: strip removed the guard block (fewer lines)" "1" \
    "$([ "$ITER_STRIP_LINES" -lt "$ITER_REAL_LINES" ] && echo 1 || echo 0)"
assert_eq "META iterations-guard: stripped checker parses" "0" \
    "$(bash -n "$ITER_STRIPPED" 2>/dev/null && echo 0 || echo 1)"

ITER_STRIP_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$ITER_STRIPPED" validate-artifact "$WORK/art_iter_decimal.json" 2>/dev/null)
ITER_STRIP_EXIT=$?
assert_eq "META iterations-guard: STRIPPED checker WRONGLY accepts iterations=1.5 (exit 0) -> guard is load-bearing" \
    "0" "$ITER_STRIP_EXIT"
assert_eq "META iterations-guard: stripped checker reports ok=true" "true" \
    "$(printf '%s' "$ITER_STRIP_OUT" | jq -r '.ok')"
# Discriminator half: the REAL (unstripped) checker still rejects the same
# fixture, so the META result above is attributable to the strip and
# nothing else.
run_rc validate-artifact "$WORK/art_iter_decimal.json"
assert_eq "META iterations-guard: REAL checker still rejects the same fixture (exit 4)" "4" "$RC_EXIT"

# META, MAGNITUDE LEG (claude-workflow-plugin-k6re, R1-F1): the SAME strip
# (ITER-GUARD-START/END brackets the magnitude check too, since it was
# added inside that sentinel region) must ALSO wrongly accept the
# out-of-bound fixture -- the required negative control specifically for
# the magnitude guard, not just the pre-existing shape guard it shares a
# sentinel region with.
ITER_STRIP_MAG_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$ITER_STRIPPED" validate-artifact "$WORK/art_iter_r1f1.json" 2>/dev/null)
ITER_STRIP_MAG_EXIT=$?
assert_eq "META magnitude-guard: STRIPPED checker WRONGLY accepts iterations=9007199254740993 (exit 0) -> guard is load-bearing" \
    "0" "$ITER_STRIP_MAG_EXIT"
assert_eq "META magnitude-guard: stripped checker reports ok=true" "true" \
    "$(printf '%s' "$ITER_STRIP_MAG_OUT" | jq -r '.ok')"
# Discriminator half: the REAL (unstripped) checker still rejects the same
# out-of-bound fixture.
run_rc validate-artifact "$WORK/art_iter_r1f1.json"
assert_eq "META magnitude-guard: REAL checker still rejects the same fixture (exit 4)" "4" "$RC_EXIT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2d: reviewed_hash SHAPE guard (claude-workflow-plugin-wob2 R1-F1) ==="
# THE GAP THIS CLOSES: independent review round 1 of wob2 measured that
# exactly ONE shipped assertion anywhere in this suite names
# reviewed_hash_unusable (impact-report.test.sh:834), and it exercises only
# the SENTINEL arm (the SHA-256 empty-content digest). The SHAPE arm --
# wrong length, illegal characters, a non-hex-string value, an empty
# string, or an outright absent key -- had zero coverage. Six direct legs
# below, one per shape failure mode, each a plain jq mutation of VALID_ART
# matching this file's own established Section 2 style, followed by a META
# that proves the whole REVIEWED-HASH-GUARD block in review-check.sh is
# load-bearing (not merely that SOME unrelated check happens to reject
# these fixtures).
#
# Lengths are derived programmatically, never hand-counted: a 64-character
# literal is exactly the kind of value a human miscounts by eye, which is
# how the original defect (L2) escaped review for as long as it did.
HASH64=$(printf 'd%.0s' $(seq 1 64))
HASH63=$(printf 'd%.0s' $(seq 1 63))
HASH65=$(printf 'd%.0s' $(seq 1 65))
assert_eq "2d setup: HASH64 (control) is exactly 64 chars" "64" "${#HASH64}"
assert_eq "2d setup: HASH63 is exactly 63 chars" "63" "${#HASH63}"
assert_eq "2d setup: HASH65 is exactly 65 chars" "65" "${#HASH65}"

printf '%s' "$VALID_ART" | jq --arg h "$HASH63" '.reviewed_hash=$h' > "$WORK/art_hash_63.json"
run_rc validate-artifact "$WORK/art_hash_63.json"
assert_eq "2d reviewed_hash 63 hex chars (too short): exit 4" "4" "$RC_EXIT"
assert_eq "2d reviewed_hash 63 hex chars: error_key" "reviewed_hash_unusable" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq --arg h "$HASH65" '.reviewed_hash=$h' > "$WORK/art_hash_65.json"
run_rc validate-artifact "$WORK/art_hash_65.json"
assert_eq "2d reviewed_hash 65 hex chars (too long): exit 4" "4" "$RC_EXIT"
assert_eq "2d reviewed_hash 65 hex chars: error_key" "reviewed_hash_unusable" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.reviewed_hash="DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"' > "$WORK/art_hash_upper.json"
run_rc validate-artifact "$WORK/art_hash_upper.json"
assert_eq "2d reviewed_hash UPPERCASE (64 chars, wrong case): exit 4" "4" "$RC_EXIT"
assert_eq "2d reviewed_hash uppercase: error_key" "reviewed_hash_unusable" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.reviewed_hash=12345' > "$WORK/art_hash_number.json"
run_rc validate-artifact "$WORK/art_hash_number.json"
assert_eq "2d reviewed_hash is a JSON number, not a string: exit 4" "4" "$RC_EXIT"
assert_eq "2d reviewed_hash non-string (jq -r coerces the number 12345 to the 5-char string \"12345\", wrong length): error_key" \
    "reviewed_hash_unusable" "$(ekey_of "$RC_OUT")"

printf '%s' "$VALID_ART" | jq '.reviewed_hash=""' > "$WORK/art_hash_empty.json"
run_rc validate-artifact "$WORK/art_hash_empty.json"
assert_eq "2d reviewed_hash empty string: exit 4" "4" "$RC_EXIT"
assert_eq "2d reviewed_hash empty string: error_key" "reviewed_hash_unusable" "$(ekey_of "$RC_OUT")"

# Absent key is caught by the GENERIC has() loop (pre-existing, already
# pinned for a different field by Section 2's own "art missing key" leg
# above) rather than by REVIEWED-HASH-GUARD itself -- a DIFFERENT error_key,
# named explicitly here so the distinction is measured, not assumed.
printf '%s' "$VALID_ART" | jq 'del(.reviewed_hash)' > "$WORK/art_hash_absent.json"
run_rc validate-artifact "$WORK/art_hash_absent.json"
assert_eq "2d reviewed_hash key absent: exit 4" "4" "$RC_EXIT"
assert_eq "2d reviewed_hash key absent: error_key is the GENERIC missing_key, not reviewed_hash_unusable" \
    "missing_key:reviewed_hash" "$(ekey_of "$RC_OUT")"

# Discriminator: the unmodified VALID_ART (well-formed reviewed_hash) still
# passes, proving the six assertions above fail because of their specific
# mutation, not because Section 2d broke validate-artifact generally.
run_rc validate-artifact "$WORK/art_ok.json"
assert_eq "2d discriminator: unmutated VALID_ART still exit 0" "0" "$RC_EXIT"

# META (claude-workflow-plugin-wob2 R1-F1 pairing requirement): a checker
# copy with REVIEWED-HASH-GUARD stripped must ACCEPT the exact shape-bad
# fixture Section 2d rejects above, proving the guard -- not some unrelated
# check -- is what refuses it.
RHGUARD_STRIPPED="$WORK/review-check-norhguard.sh"
awk '
    /# REVIEWED-HASH-GUARD-START/ {skip=1; next}
    /# REVIEWED-HASH-GUARD-END/   {skip=0; next}
    skip!=1 {print}
' "$RCHECK" > "$RHGUARD_STRIPPED"
chmod +x "$RHGUARD_STRIPPED"

RH_REAL_LINES=$(wc -l < "$RCHECK" | tr -d ' ')
RH_STRIP_LINES=$(wc -l < "$RHGUARD_STRIPPED" | tr -d ' ')
assert_eq "2d META: strip removed the guard block (fewer lines)" "1" \
    "$([ "$RH_STRIP_LINES" -lt "$RH_REAL_LINES" ] && echo 1 || echo 0)"
assert_eq "2d META: stripped checker parses" "0" \
    "$(bash -n "$RHGUARD_STRIPPED" 2>/dev/null && echo 0 || echo 1)"

RH_STRIP_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RHGUARD_STRIPPED" validate-artifact "$WORK/art_hash_63.json" 2>/dev/null)
RH_STRIP_EXIT=$?
assert_eq "2d META: STRIPPED checker WRONGLY accepts a 63-hex reviewed_hash (exit 0) -> guard is load-bearing" \
    "0" "$RH_STRIP_EXIT"
assert_eq "2d META: stripped checker reports ok=true" "true" \
    "$(printf '%s' "$RH_STRIP_OUT" | jq -r '.ok')"
# Discriminator half: the REAL (unstripped) checker still rejects the same
# fixture, so the META result above is attributable to the strip and
# nothing else.
run_rc validate-artifact "$WORK/art_hash_63.json"
assert_eq "2d META: REAL checker still rejects the same fixture (exit 4)" "4" "$RC_EXIT"

# Bonus confirmation (not required to close R1-F1 -- the SENTINEL arm
# already has a shipped leg at impact-report.test.sh:834 -- but since the
# stripped copy already exists, this costs nothing and confirms the strip
# removed the WHOLE guard, sentinel arm included, not merely the shape half).
SENTINEL_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
printf '%s' "$VALID_ART" | jq --arg h "$SENTINEL_HASH" '.reviewed_hash=$h' > "$WORK/art_hash_sentinel.json"
run_rc validate-artifact "$WORK/art_hash_sentinel.json"
assert_eq "2d sentinel arm (bonus, already covered at impact-report.test.sh:834): REAL checker rejects" \
    "reviewed_hash_unusable" "$(ekey_of "$RC_OUT")"
RH_STRIP_SENTINEL_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RHGUARD_STRIPPED" validate-artifact "$WORK/art_hash_sentinel.json" 2>/dev/null)
assert_eq "2d META bonus: STRIPPED checker also wrongly accepts the sentinel (whole guard removed, not half of it)" \
    "true" "$(printf '%s' "$RH_STRIP_SENTINEL_OUT" | jq -r '.ok')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2e: artifact-schema risk_threshold enum (claude-workflow-plugin-wob2 R1-F1) ==="
# THE GAP THIS CLOSES: Section 1 already pins risk_threshold_invalid_enum for
# the REQUEST schema ("req bad enum", above). validate-artifact has its OWN,
# separate risk_threshold_invalid_enum check (ARTIFACT-RISK-THRESHOLD-GUARD)
# -- same error_key spelling, but a DIFFERENT schema, reached only via
# validate-artifact -- and independent review round 1 of wob2 measured zero
# shipped assertions naming it on THIS schema; the one existing "bad enum"
# leg is a request-schema fixture (VALID_REQ) and cannot exercise the
# artifact-schema branch, which lives in a different function entirely.
printf '%s' "$VALID_ART" | jq '.risk_threshold="nonsense"' > "$WORK/art_badrt.json"
run_rc validate-artifact "$WORK/art_badrt.json"
assert_eq "2e artifact risk_threshold bad enum: exit 4" "4" "$RC_EXIT"
assert_eq "2e artifact risk_threshold bad enum: error_key" "risk_threshold_invalid_enum" "$(ekey_of "$RC_OUT")"

# Discriminator: the unmodified VALID_ART still passes.
run_rc validate-artifact "$WORK/art_ok.json"
assert_eq "2e discriminator: unmutated VALID_ART still exit 0" "0" "$RC_EXIT"

# META: a checker copy with ARTIFACT-RISK-THRESHOLD-GUARD stripped must
# ACCEPT the exact fixture above, proving the guard is load-bearing.
RTGUARD_STRIPPED="$WORK/review-check-nortguard.sh"
awk '
    /# ARTIFACT-RISK-THRESHOLD-GUARD-START/ {skip=1; next}
    /# ARTIFACT-RISK-THRESHOLD-GUARD-END/   {skip=0; next}
    skip!=1 {print}
' "$RCHECK" > "$RTGUARD_STRIPPED"
chmod +x "$RTGUARD_STRIPPED"

RT_REAL_LINES=$(wc -l < "$RCHECK" | tr -d ' ')
RT_STRIP_LINES=$(wc -l < "$RTGUARD_STRIPPED" | tr -d ' ')
assert_eq "2e META: strip removed the guard block (fewer lines)" "1" \
    "$([ "$RT_STRIP_LINES" -lt "$RT_REAL_LINES" ] && echo 1 || echo 0)"
assert_eq "2e META: stripped checker parses" "0" \
    "$(bash -n "$RTGUARD_STRIPPED" 2>/dev/null && echo 0 || echo 1)"

RT_STRIP_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RTGUARD_STRIPPED" validate-artifact "$WORK/art_badrt.json" 2>/dev/null)
RT_STRIP_EXIT=$?
assert_eq "2e META: STRIPPED checker WRONGLY accepts risk_threshold=nonsense (exit 0) -> guard is load-bearing" \
    "0" "$RT_STRIP_EXIT"
assert_eq "2e META: stripped checker reports ok=true" "true" \
    "$(printf '%s' "$RT_STRIP_OUT" | jq -r '.ok')"
run_rc validate-artifact "$WORK/art_badrt.json"
assert_eq "2e META: REAL checker still rejects the same fixture (exit 4)" "4" "$RC_EXIT"

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
echo "=== Section 4: the ISO-8601 timestamp extraction has TWO carriers (qzv.1) ==="
# This script owns the record grammars and defines the ONE timestamp extraction
# (`max_record_ts`). `subagent-start.sh` — the sole WRITER of the IMPLEMENTER
# grammar — carries a second copy, and it has to: its cycle-keyed idempotency
# decision is PER-ROLE, and nothing in `gate`'s envelope is per-role
# (`latest_implementer_ts` is the max across every role, so reusing it would
# suppress one role's record because another had already posted this cycle, and
# the implementer SET is what makes `approve` refuse a self-review).
#
# The COUPLING that matters is that both carriers agree on what a timestamp is:
# if the writer's notion of "current cycle" diverges from the predicate's, the
# writer under-posts and claude-workflow-plugin-qzv.1 comes straight back. The
# behavioural pin is the two-cycle leg in the verify-before-stop component spec;
# this is the structural one, and it fails EARLY and by name instead of late and
# diffusely. Anchored on the literals, never on line numbers.
SUBAGENT_START="$PROJECT_DIR/.claude/scripts/subagent-start.sh"
assert_eq "qzv.1 coupling: subagent-start.sh exists to compare against" "1" \
    "$([ -f "$SUBAGENT_START" ] && echo 1 || echo 0)"
ISO_RE_LINE="QZV_ISO_UTC_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'"
assert_eq "qzv.1 coupling: review-check.sh defines the ISO-8601-UTC literal exactly once" "1" \
    "$(grep -c -x -F "$ISO_RE_LINE" "$RCHECK" | tr -d '[:space:]')"
assert_eq "qzv.1 coupling: subagent-start.sh defines the SAME literal, byte for byte" "1" \
    "$(grep -c -x -F "$ISO_RE_LINE" "$SUBAGENT_START" | tr -d '[:space:]')"
# The extraction itself: end-of-line anchored, so a date-shaped token inside a
# free-text summary cannot be read as the record's stamp. Both carriers must
# anchor the same way — an unanchored copy would read a DIFFERENT timestamp off
# the same line and the two would disagree without either looking wrong.
#
# The needle deliberately STOPS before the line-continuation backslash. Including
# it would make this leg fail when someone reflows the pipeline, which has nothing
# to do with the property being pinned. Single-quoted on purpose: `$QZV_ISO_UTC_RE`
# must stay LITERAL, because that is how it appears in both files.
# shellcheck disable=SC2016
EXTRACT_LINE='| grep -oE " at $QZV_ISO_UTC_RE\$" 2>/dev/null'
assert_eq "qzv.1 coupling: review-check.sh anchors the extraction at end-of-line" "1" \
    "$(grep -c -F "$EXTRACT_LINE" "$RCHECK" | tr -d '[:space:]')"
assert_eq "qzv.1 coupling: subagent-start.sh anchors it identically" "1" \
    "$(grep -c -F "$EXTRACT_LINE" "$SUBAGENT_START" | tr -d '[:space:]')"
# Both carriers must also keep the THREE-answer contract, because collapsing
# 'unparseable' into '' is the one drift that flips a refusal into an approval:
# "no record" is safe, "a record I cannot read" is not.
#
# i8cx wave 2: review-check.sh's count moved from 1 to 2 (a SECOND, legitimate
# `printf 'unparseable'` site, guarding a file-read failure in the grep that
# materialises `lines` -- see max_record_ts's header). subagent-start.sh's
# sibling extraction, max_record_ts_in, stays at 1 and is NOT expected to grow
# a matching branch: it reads an already-in-memory string via
# `printf '%s\n' "$1" | grep -E "$2"`, never a file, so it structurally cannot
# hit the failure mode the new review-check.sh branch guards against (same
# "printf-producer, cannot meaningfully fail" reasoning the i8cx audit applies
# throughout). The counts diverging is the expected shape now, not a drift the
# coupling this section pins should paper over — what both files still share,
# and what this pair of assertions actually verifies, is that EACH can still
# reach 'unparseable' at least once (>= 1), the property the comment above
# names.
assert_eq "qzv.1 coupling: review-check.sh still distinguishes unparseable from absent (2 sites since i8cx wave 2 — see comment above)" "2" \
    "$(grep -c "printf 'unparseable'" "$RCHECK" | tr -d '[:space:]')"
assert_eq "qzv.1 coupling: subagent-start.sh still distinguishes unparseable from absent" "1" \
    "$(grep -c "printf 'unparseable'" "$SUBAGENT_START" | tr -d '[:space:]')"

# META for section 4. A substring assertion that has never been seen to MISS is
# indistinguishable from one whose needle matches something broader than intended,
# so drive the needle against a line carrying the ONE difference that matters —
# the `\$` end-of-line anchor removed — and require it not to match. A whole
# stripped copy of the script is not needed for that, and building one by `sed`ing
# a regex out of a regex was fragile in a way this is not.
# DERIVED from the needle rather than written out a second time: a hand-copied
# counterexample can drift into being a counterexample to something else, and then
# this META passes while proving nothing. Removing `\$` from before the closing
# quote is exactly the loss of the anchor and nothing else.
LOOSENED_LINE=${EXTRACT_LINE/'\$"'/'"'}
LOOSENED="$WORK/loosened-anchor.txt"
printf '%s\n' "$LOOSENED_LINE" > "$LOOSENED"
assert_eq "qzv.1 coupling META: de-anchoring the needle actually changed it" "changed" \
    "$([ "$LOOSENED_LINE" != "$EXTRACT_LINE" ] && echo changed || echo same)"
assert_eq "qzv.1 coupling META: ...and the anchored needle does NOT match the de-anchored line (the legs above can MISS)" "0" \
    "$(grep -c -F "$EXTRACT_LINE" "$LOOSENED" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

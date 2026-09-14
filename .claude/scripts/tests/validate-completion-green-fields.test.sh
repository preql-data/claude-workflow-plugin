#!/bin/bash
# validate-completion-green-fields.test.sh — v5 D5 piece 3
# (claude-workflow-plugin-fkm.7 D5): the four green-to-green completion
# contract fields — unit_id, design_hash, green_before, green_after — as
# enforced by `review-check.sh validate-completion`'s GREEN-FIELDS-VALIDATION
# region.
#
# THE CONTRACT UNDER TEST, stated once so every assertion below reads as a
# consequence of it rather than a fact on its own: the four fields APPEND
# after the canonical seven (task_id, files_changed, tests_added, decisions,
# blockers, llm_observations, context_coverage) and are REQUIRED on every
# completion payload regardless of role. unit_id / design_hash MAY be empty
# (not bound to a design unit is a real, legal answer); design_hash present
# with unit_id empty is refused (design_hash_without_unit_id) — a design
# artifact hash with no unit to bind it to is not a coherent claim — but the
# REVERSE (unit_id present, design_hash empty) is legal, because spec
# injection is best-effort and can legitimately fail to record even on
# genuinely unit-bound work. green_before/green_after are a closed
# three-value enum: green | red | none.
#
# THIS FILE NEEDS NO bd/Beads FIXTURE. review-check.sh validate-completion is
# a pure, stateless JSON validator with no bd calls anywhere in it — every
# assertion below drives the SHIPPED script directly against a crafted
# payload file. The one exception is the META-TEST at the end, which drives
# a MUTATED COPY (never the live repo file) to prove the new checks are not
# vacuous.
#
# Sections:
#   1. RESTORE CONTROLS — the shapes that must pass, so every refusal below
#      is attributable to the ONE field under test, not to some other defect
#   2. Missing-key refusals, one per new field, distinguishable error_keys
#   3. Precedence — an EXISTING required-field defect (bad model) is reported
#      before a NEW one (missing unit_id), because the new checks run LAST
#   4. Type errors — wrong JSON type for each of the four fields
#   5. Value errors — unit_id/design_hash character class, green_before/
#      green_after enum membership
#   6. design_hash_without_unit_id — the one asymmetric cross-field rule,
#      both directions (refused one way, legal the other)
#   7. META-TEST: strip the GREEN-FIELDS-VALIDATION region from a COPY —
#      the four fields become undeclared and unchecked; a payload entirely
#      missing them (which would otherwise let a specialist write
#      "green_before":"green" with nothing checking its shape, let alone
#      whether it reflects a real run) is WRONGLY accepted by the mutant and
#      correctly refused by the shipped script
#
# Exit codes:
#   0  every assertion passed
#   1  at least one assertion failed
#
# Usage:
#   bash .claude/scripts/tests/validate-completion-green-fields.test.sh

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

PLUGIN_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
RC="$PLUGIN_DIR/.claude/scripts/review-check.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not on PATH."
    exit 2
fi
if [ ! -f "$RC" ]; then
    echo "review-check.sh not found at $RC"
    exit 2
fi

WORKDIR=$(mktemp -d -t validate-completion-green-fields.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# payload <extra-json-fields> -> path. Builds a well-formed BASE payload
# (the canonical seven + role/model/pin, all valid) and merges in whatever
# the caller passes as additional/overriding top-level keys, so every test
# below isolates the ONE field it is about.
payload() {
    local extra="$1" out="$WORKDIR/p-$RANDOM$RANDOM.json"
    # criteria_tests:{} is in the BASE, not overridden per test, for the
    # same reason role/model/pin are: this file is about the FOUR green
    # fields, not about criteria_tests (v5 D5 piece 4, which has its own
    # dedicated file, validate-completion-criteria-tests.test.sh) — {} is
    # always schema-legal regardless of what unit_id/design_hash this
    # payload's own $extra sets, so it cannot mask or interact with any
    # assertion below.
    jq -n --argjson extra "$extra" '
        {task_id:"t-1", files_changed:[], tests_added:[], decisions:[],
         blockers:[], llm_observations:"x", context_coverage:"y",
         role:"devops", model:"m", pin:"m", criteria_tests:{}} + $extra
    ' > "$out"
    printf '%s' "$out"
}

run_vc() {
    bash "$RC" validate-completion "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "=== Section 1: restore controls — the shapes that must pass ==="

P_FULL=$(payload '{"unit_id":"U-2","design_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","green_before":"green","green_after":"red"}')
OUT=$(run_vc "$P_FULL"); RC_A=$?
assert_eq "1.1 fully valid, unit-bound payload: rc=0" "0" "$RC_A"
assert_eq "1.1 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"

P_UNBOUND=$(payload '{"unit_id":"","design_hash":"","green_before":"none","green_after":"none"}')
OUT=$(run_vc "$P_UNBOUND"); RC_A=$?
assert_eq "1.2 unbound payload (empty unit_id/design_hash, none/none): rc=0" "0" "$RC_A"
assert_eq "1.2 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: missing-key refusals, one per new field ==="

for field in unit_id design_hash green_before green_after; do
    FULL='{"unit_id":"","design_hash":"","green_before":"none","green_after":"none"}'
    STRIPPED=$(printf '%s' "$FULL" | jq -c --arg f "$field" 'del(.[$f])')
    P=$(payload "$STRIPPED")
    OUT=$(run_vc "$P"); RC_A=$?
    assert_eq "2.$field: missing $field refuses (rc=4)" "4" "$RC_A"
    assert_eq "2.$field: ...error_key=missing_key:$field" \
        "missing_key:$field" "$(printf '%s' "$OUT" | jq -r '.error_key')"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: precedence — an EXISTING defect is reported before a NEW one ==="

# model carries a space (fails the PRE-EXISTING model-id character class) AND
# unit_id is entirely absent (would fail the NEW required-key check). The new
# checks run LAST (GREEN-FIELDS-VALIDATION sits after every existing check in
# the function body), so the existing defect must win.
P_PRECEDENCE=$(jq -n '
    {task_id:"t-1", files_changed:[], tests_added:[], decisions:[],
     blockers:[], llm_observations:"x", context_coverage:"y",
     role:"devops", model:"claude opus", pin:"m",
     design_hash:"", green_before:"none", green_after:"none"}
' > "$WORKDIR/precedence.json"; printf '%s' "$WORKDIR/precedence.json")
OUT=$(run_vc "$P_PRECEDENCE"); RC_A=$?
assert_eq "3.1 malformed model + missing unit_id: rc=4" "4" "$RC_A"
assert_eq "3.1 ...the EXISTING model check wins (error_key=field_invalid_chars:model, NOT missing_key:unit_id)" \
    "field_invalid_chars:model" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: type errors ==="

P_UIDTYPE=$(payload '{"unit_id":123,"design_hash":"","green_before":"none","green_after":"none"}')
OUT=$(run_vc "$P_UIDTYPE"); RC_A=$?
assert_eq "4.1 unit_id as a number: rc=4" "4" "$RC_A"
assert_eq "4.1 ...error_key=field_type_invalid:unit_id" \
    "field_type_invalid:unit_id" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_DHTYPE=$(payload '{"unit_id":"","design_hash":true,"green_before":"none","green_after":"none"}')
OUT=$(run_vc "$P_DHTYPE"); RC_A=$?
assert_eq "4.2 design_hash as a boolean: rc=4" "4" "$RC_A"
assert_eq "4.2 ...error_key=field_type_invalid:design_hash" \
    "field_type_invalid:design_hash" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_GBTYPE=$(payload '{"unit_id":"","design_hash":"","green_before":true,"green_after":"none"}')
OUT=$(run_vc "$P_GBTYPE"); RC_A=$?
assert_eq "4.3 green_before as a boolean (the natural mistake — 'green' sounds like a bool): rc=4" "4" "$RC_A"
assert_eq "4.3 ...error_key=field_type_invalid:green_before" \
    "field_type_invalid:green_before" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_GATYPE=$(payload '{"unit_id":"","design_hash":"","green_before":"none","green_after":0}')
OUT=$(run_vc "$P_GATYPE"); RC_A=$?
assert_eq "4.4 green_after as a number: rc=4" "4" "$RC_A"
assert_eq "4.4 ...error_key=field_type_invalid:green_after" \
    "field_type_invalid:green_after" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: value errors ==="

P_UIDCHARS=$(payload '{"unit_id":"U 2","design_hash":"","green_before":"none","green_after":"none"}')
OUT=$(run_vc "$P_UIDCHARS"); RC_A=$?
assert_eq "5.1 unit_id with a space: rc=4" "4" "$RC_A"
assert_eq "5.1 ...error_key=field_invalid_chars:unit_id" \
    "field_invalid_chars:unit_id" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_DHSHORT=$(payload '{"unit_id":"","design_hash":"deadbeef","green_before":"none","green_after":"none"}')
OUT=$(run_vc "$P_DHSHORT"); RC_A=$?
assert_eq "5.2 design_hash too short (not 64 hex): rc=4" "4" "$RC_A"
assert_eq "5.2 ...error_key=field_invalid_chars:design_hash" \
    "field_invalid_chars:design_hash" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_GBENUM=$(payload '{"unit_id":"","design_hash":"","green_before":"YES","green_after":"none"}')
OUT=$(run_vc "$P_GBENUM"); RC_A=$?
assert_eq "5.3 green_before='YES' (not in the enum): rc=4" "4" "$RC_A"
assert_eq "5.3 ...error_key=field_invalid_enum:green_before" \
    "field_invalid_enum:green_before" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_GAENUM=$(payload '{"unit_id":"","design_hash":"","green_before":"none","green_after":"pass"}')
OUT=$(run_vc "$P_GAENUM"); RC_A=$?
assert_eq "5.4 green_after='pass' (not in the enum): rc=4" "4" "$RC_A"
assert_eq "5.4 ...error_key=field_invalid_enum:green_after" \
    "field_invalid_enum:green_after" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: design_hash_without_unit_id — the asymmetric cross-field rule ==="

DH64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

P_HASHNOUNIT=$(payload "{\"unit_id\":\"\",\"design_hash\":\"$DH64\",\"green_before\":\"none\",\"green_after\":\"none\"}")
OUT=$(run_vc "$P_HASHNOUNIT"); RC_A=$?
assert_eq "6.1 design_hash present, unit_id empty: REFUSED (rc=4)" "4" "$RC_A"
assert_eq "6.1 ...error_key=design_hash_without_unit_id" \
    "design_hash_without_unit_id" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# RESTORE CONTROL, the other direction: unit_id present, design_hash empty is
# LEGAL (spec injection is best-effort and can fail to record on genuinely
# unit-bound work) — this must NOT be refused, or the asymmetry is not real.
P_UNITNOHASH=$(payload '{"unit_id":"U-9","design_hash":"","green_before":"green","green_after":"green"}')
OUT=$(run_vc "$P_UNITNOHASH"); RC_A=$?
assert_eq "6.2 CONTROL: unit_id present, design_hash empty is LEGAL (rc=0)" "0" "$RC_A"
assert_eq "6.2 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"

# ---------------------------------------------------------------------------
echo ""
echo "=== META-TEST: strip GREEN-FIELDS-VALIDATION from a COPY -> a payload"
echo "missing all four fields is WRONGLY accepted by the mutant, and correctly"
echo "refused by the shipped script =================================="

META_RC="$WORKDIR/review-check-stripped.sh"
STRIP_RC=0
awk '
    /^ *# GREEN-FIELDS-VALIDATION BEGIN/ { skip = 1; found = 1; next }
    /^ *# GREEN-FIELDS-VALIDATION END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$RC" > "$META_RC" || STRIP_RC=$?
chmod +x "$META_RC" 2>/dev/null || true

assert_eq "META.1 the sentinels were found and the strip ran cleanly (rc=0)" "0" "$STRIP_RC"

# Non-vacuity: the mutant is genuinely shorter (the strip removed real
# lines), and it still parses.
SHIPPED_LINES=$(wc -l < "$RC" | tr -d '[:space:]')
STRIPPED_LINES=$(wc -l < "$META_RC" | tr -d '[:space:]')
assert_eq "META.2 non-vacuity: the mutant copy is shorter than the shipped script" \
    "shorter" "$([ "$STRIPPED_LINES" -lt "$SHIPPED_LINES" ] && echo shorter || echo same-or-longer)"
BASH_N_RC=0
bash -n "$META_RC" 2>/dev/null || BASH_N_RC=$?
assert_eq "META.3 the mutant still parses (bash -n rc=0)" "0" "$BASH_N_RC"

# A payload with NO trace of the four new fields at all — the shape a
# specialist would submit if nothing ever required them, which is exactly
# the pre-piece-3 world this META-TEST reconstructs. criteria_tests:{} IS
# included (unlike unit_id/design_hash/green_before/green_after, which
# this payload deliberately omits): this META-TEST isolates
# GREEN-FIELDS-VALIDATION specifically, and CRITERIA-TESTS-VALIDATION (v5
# D5 piece 4) is a SEPARATE, later region this strip does not touch — an
# unrelated missing_key:criteria_tests refusal on the mutant would prove
# nothing about the region actually under test here.
P_NOFIELDS=$(jq -n '
    {task_id:"t-1", files_changed:[], tests_added:[], decisions:[],
     blockers:[], llm_observations:"x", context_coverage:"y",
     role:"devops", model:"m", pin:"m", criteria_tests:{}}
' > "$WORKDIR/nofields.json"; printf '%s' "$WORKDIR/nofields.json")

MUTANT_OUT=$(bash "$META_RC" validate-completion "$P_NOFIELDS" 2>/dev/null); MUTANT_RC=$?
assert_eq "META.4 SPECIFIC MISBEHAVIOUR: the mutant accepts a payload with NO green-to-green fields at all (rc=0)" \
    "0" "$MUTANT_RC"
assert_eq "META.4 ...ok=true on the mutant" "true" "$(printf '%s' "$MUTANT_OUT" | jq -r '.ok')"

SHIPPED_OUT=$(bash "$RC" validate-completion "$P_NOFIELDS" 2>/dev/null); SHIPPED_RC=$?
assert_eq "META.5 RESTORE CONTROL: the SAME payload against the shipped script refuses (rc=4)" \
    "4" "$SHIPPED_RC"
assert_eq "META.5 ...error_key=missing_key:unit_id" \
    "missing_key:unit_id" "$(printf '%s' "$SHIPPED_OUT" | jq -r '.error_key')"

# The mechanical half of "stub the suite result to claim green while red":
# on the mutant, a payload that OUTRIGHT CLAIMS green_before="green" (typed,
# well-formed, spelled correctly) is accepted with NOTHING checking that
# claim's shape at all once the region is gone — precisely the gap this
# piece closes. The shipped script still enforces the shape (though, as
# section 1 already showed, a well-formed claim of "green" is accepted on
# its face — TRUTH is never this validator's job, only SHAPE; see the
# region's own header).
P_CLAIMGREEN_NOOTHERFIELDS=$(jq -n '
    {task_id:"t-1", files_changed:[], tests_added:[], decisions:[],
     blockers:[], llm_observations:"x", context_coverage:"y",
     role:"devops", model:"m", pin:"m", criteria_tests:{}, green_before:"green"}
' > "$WORKDIR/claimgreen.json"; printf '%s' "$WORKDIR/claimgreen.json")
MUTANT_CG_RC=0
bash "$META_RC" validate-completion "$P_CLAIMGREEN_NOOTHERFIELDS" >/dev/null 2>&1 || MUTANT_CG_RC=$?
assert_eq "META.6 the mutant accepts a bare green_before=\"green\" claim with unit_id/design_hash/green_after entirely undeclared (rc=0)" \
    "0" "$MUTANT_CG_RC"
SHIPPED_CG_RC=0
bash "$RC" validate-completion "$P_CLAIMGREEN_NOOTHERFIELDS" >/dev/null 2>&1 || SHIPPED_CG_RC=$?
assert_eq "META.6 ...while the shipped script still refuses (rc=4) — the very check this META-TEST proves is load-bearing" \
    "4" "$SHIPPED_CG_RC"

# --- Summary -------------------------------------------------------------

printf '\nTotal: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    printf 'Failed assertions:\n'
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

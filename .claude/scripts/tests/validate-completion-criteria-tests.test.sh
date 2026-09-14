#!/bin/bash
# validate-completion-criteria-tests.test.sh — v5 D5 piece 4
# (claude-workflow-plugin-fkm.7 D5): the `criteria_tests` completion
# contract field, as enforced by `review-check.sh validate-completion`'s
# CRITERIA-TESTS-VALIDATION region. Sibling to validate-completion-green-
# fields.test.sh (piece 3), which covers unit_id/design_hash/green_before/
# green_after — deliberately a SEPARATE file rather than an extension of
# that one, matching this arc's own discipline of one independently
# strippable region per feature getting one independently runnable spec.
#
# THE CONTRACT UNDER TEST. `criteria_tests` maps a design unit's
# acceptance-criterion ids to the array of `tests_added` entries that
# cover them: `{"U3-1": ["path::label"], "U3-2": [...]}`. It is REQUIRED on
# every completion payload (missing_key:criteria_tests otherwise) but `{}`
# is ALWAYS legal — even when `unit_id` is non-empty — because
# COMPLETENESS (does the map cover every criterion the bound unit actually
# declares) is not a fact this schema-only validator can establish; that is
# `qa-gate.sh design-unit-align`'s job (see design-unit-align.test.sh),
# which has the design artifact in hand and this validator never does.
# What THIS layer enforces is SHAPE plus ONE cross-field rule: every
# key is a non-empty string, every value a non-empty array of non-empty
# strings, a non-empty map requires a non-empty `unit_id`
# (`criteria_tests_without_unit_id` — the same one-directional shape
# `design_hash_without_unit_id` already enforces), and every referenced
# string must ALSO appear, byte-for-byte, in this SAME payload's
# `tests_added` array (`criteria_test_ref_not_declared`) — the cheapest
# defense against this arc's own defect family: a criterion id "merely
# appearing in a passing assertion label is a mention mistaken for a test".
#
# THIS FILE NEEDS NO bd/Beads FIXTURE, for the identical reason validate-
# completion-green-fields.test.sh needs none: review-check.sh validate-
# completion is a pure, stateless JSON validator with no bd calls anywhere
# in it.
#
# Sections:
#   1  RESTORE CONTROLS — the shapes that must pass
#   2  missing_key:criteria_tests
#   3  type errors — criteria_tests itself, and its keys/values
#   4  criteria_tests_without_unit_id — the one-directional cross-field rule,
#      both directions (refused one way, legal the other)
#   5  criteria_test_ref_not_declared — the tests_added cross-reference
#   6  META-TEST: strip the CRITERIA-TESTS-VALIDATION region from a COPY —
#      criteria_tests becomes undeclared and unchecked; a payload entirely
#      missing it (or carrying an invented, undeclared reference) is
#      WRONGLY accepted by the mutant and correctly refused by the shipped
#      script
#
# Exit codes:
#   0  every assertion passed
#   1  at least one assertion failed
#
# Usage:
#   bash .claude/scripts/tests/validate-completion-criteria-tests.test.sh

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

WORKDIR=$(mktemp -d -t validate-completion-criteria-tests.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# payload <extra-json-fields> -> path. Builds a well-formed BASE payload
# (the canonical seven + role/model/pin + the four v5 D5 piece 3 fields, all
# valid) and merges in whatever the caller passes as additional/overriding
# top-level keys, so every test below isolates the ONE field it is about —
# criteria_tests and, where relevant, tests_added.
payload() {
    local extra="$1" out="$WORKDIR/p-$RANDOM$RANDOM.json"
    jq -n --argjson extra "$extra" '
        {task_id:"t-1", files_changed:[], tests_added:[], decisions:[],
         blockers:[], llm_observations:"x", context_coverage:"y",
         role:"devops", model:"m", pin:"m",
         unit_id:"", design_hash:"", green_before:"none", green_after:"none"} + $extra
    ' > "$out"
    printf '%s' "$out"
}

run_vc() {
    bash "$RC" validate-completion "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "=== Section 1: restore controls — the shapes that must pass ==="

P_EMPTY_UNBOUND=$(payload '{"criteria_tests":{}}')
OUT=$(run_vc "$P_EMPTY_UNBOUND"); RC_A=$?
assert_eq "1.1 empty criteria_tests, unbound (unit_id empty): rc=0" "0" "$RC_A"
assert_eq "1.1 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"

P_EMPTY_BOUND=$(payload '{"unit_id":"U1","criteria_tests":{}}')
OUT=$(run_vc "$P_EMPTY_BOUND"); RC_A=$?
assert_eq "1.2 empty criteria_tests, BOUND (unit_id set): still rc=0 — completeness is design-unit-align's job, not this validator's" "0" "$RC_A"
assert_eq "1.2 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"

P_FULL=$(payload '{"unit_id":"U1","tests_added":["a.test.sh::case one","a.test.sh::case two"],"criteria_tests":{"U1-1":["a.test.sh::case one"],"U1-2":["a.test.sh::case one","a.test.sh::case two"]}}')
OUT=$(run_vc "$P_FULL"); RC_A=$?
assert_eq "1.3 a fully valid, multi-criterion, multi-ref payload: rc=0" "0" "$RC_A"
assert_eq "1.3 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: missing_key:criteria_tests ==="

P_MISSING=$(jq -n '
    {task_id:"t-1", files_changed:[], tests_added:[], decisions:[],
     blockers:[], llm_observations:"x", context_coverage:"y",
     role:"devops", model:"m", pin:"m",
     unit_id:"", design_hash:"", green_before:"none", green_after:"none"}
' > "$WORKDIR/missing.json"; printf '%s' "$WORKDIR/missing.json")
OUT=$(run_vc "$P_MISSING"); RC_A=$?
assert_eq "2.1 criteria_tests entirely absent: rc=4" "4" "$RC_A"
assert_eq "2.1 ...error_key=missing_key:criteria_tests" \
    "missing_key:criteria_tests" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# Precedence: an EXISTING defect (bad model) is reported before this NEW
# one, because CRITERIA-TESTS-VALIDATION runs LAST in the function body —
# same shape as validate-completion-green-fields.test.sh Section 3.
P_PRECEDENCE=$(jq -n '
    {task_id:"t-1", files_changed:[], tests_added:[], decisions:[],
     blockers:[], llm_observations:"x", context_coverage:"y",
     role:"devops", model:"claude opus", pin:"m",
     unit_id:"", design_hash:"", green_before:"none", green_after:"none"}
' > "$WORKDIR/precedence.json"; printf '%s' "$WORKDIR/precedence.json")
OUT=$(run_vc "$P_PRECEDENCE"); RC_A=$?
assert_eq "2.2 malformed model + missing criteria_tests: rc=4" "4" "$RC_A"
assert_eq "2.2 ...the EXISTING model check wins (error_key=field_invalid_chars:model, NOT missing_key:criteria_tests)" \
    "field_invalid_chars:model" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: type errors ==="

P_NOTOBJ=$(payload '{"criteria_tests":[]}')
OUT=$(run_vc "$P_NOTOBJ"); RC_A=$?
assert_eq "3.1 criteria_tests as an array, not an object: rc=4" "4" "$RC_A"
assert_eq "3.1 ...error_key=field_type_invalid:criteria_tests" \
    "field_type_invalid:criteria_tests" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_NOTOBJ2=$(payload '{"criteria_tests":"U1-1"}')
OUT=$(run_vc "$P_NOTOBJ2"); RC_A=$?
assert_eq "3.2 criteria_tests as a string: rc=4" "4" "$RC_A"
assert_eq "3.2 ...error_key=field_type_invalid:criteria_tests" \
    "field_type_invalid:criteria_tests" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_EMPTYKEY=$(payload '{"unit_id":"U1","criteria_tests":{"":["a.sh::x"]},"tests_added":["a.sh::x"]}')
OUT=$(run_vc "$P_EMPTYKEY"); RC_A=$?
assert_eq "3.3 an empty-string criterion id key: rc=4" "4" "$RC_A"
assert_eq "3.3 ...error_key=criteria_tests_key_empty" \
    "criteria_tests_key_empty" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_VALNOTARR=$(payload '{"unit_id":"U1","criteria_tests":{"U1-1":"a.sh::x"}}')
OUT=$(run_vc "$P_VALNOTARR"); RC_A=$?
assert_eq "3.4 a criterion value that is a string, not an array: rc=4 (must not crash)" "4" "$RC_A"
assert_eq "3.4 ...error_key=criteria_tests_value_type_invalid:U1-1" \
    "criteria_tests_value_type_invalid:U1-1" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_VALEMPTY=$(payload '{"unit_id":"U1","criteria_tests":{"U1-1":[]}}')
OUT=$(run_vc "$P_VALEMPTY"); RC_A=$?
assert_eq "3.5 a criterion value that is an empty array: rc=4" "4" "$RC_A"
assert_eq "3.5 ...error_key=criteria_tests_value_empty:U1-1" \
    "criteria_tests_value_empty:U1-1" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_ITEMTYPE=$(payload '{"unit_id":"U1","criteria_tests":{"U1-1":[1]}}')
OUT=$(run_vc "$P_ITEMTYPE"); RC_A=$?
assert_eq "3.6 a test reference that is a number, not a string: rc=4" "4" "$RC_A"
assert_eq "3.6 ...error_key=criteria_tests_value_item_type_invalid:U1-1" \
    "criteria_tests_value_item_type_invalid:U1-1" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_ITEMEMPTY=$(payload '{"unit_id":"U1","criteria_tests":{"U1-1":["   "]}}')
OUT=$(run_vc "$P_ITEMEMPTY"); RC_A=$?
assert_eq "3.7 a test reference that is whitespace-only: rc=4" "4" "$RC_A"
assert_eq "3.7 ...error_key=criteria_tests_value_item_empty:U1-1" \
    "criteria_tests_value_item_empty:U1-1" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: criteria_tests_without_unit_id — the one-directional rule ==="

P_NOUID=$(payload '{"unit_id":"","criteria_tests":{"U1-1":["a.sh::x"]},"tests_added":["a.sh::x"]}')
OUT=$(run_vc "$P_NOUID"); RC_A=$?
assert_eq "4.1 non-empty criteria_tests, empty unit_id: REFUSED (rc=4)" "4" "$RC_A"
assert_eq "4.1 ...error_key=criteria_tests_without_unit_id" \
    "criteria_tests_without_unit_id" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_UIDNOCT=$(payload '{"unit_id":"U1","criteria_tests":{}}')
OUT=$(run_vc "$P_UIDNOCT"); RC_A=$?
assert_eq "4.2 CONTROL: unit_id present, criteria_tests empty is LEGAL (rc=0) — the reverse pairing" "0" "$RC_A"
assert_eq "4.2 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: criteria_test_ref_not_declared — the tests_added cross-reference ==="

P_UNDECLARED=$(payload '{"unit_id":"U1","tests_added":["a.sh::real one"],"criteria_tests":{"U1-1":["a.sh::not in tests_added"]}}')
OUT=$(run_vc "$P_UNDECLARED"); RC_A=$?
assert_eq "5.1 a criteria_tests ref absent from tests_added: rc=4" "4" "$RC_A"
assert_eq "5.1 ...error_key names the exact undeclared reference" \
    "criteria_test_ref_not_declared:a.sh::not in tests_added" "$(printf '%s' "$OUT" | jq -r '.error_key')"

P_DECLARED=$(payload '{"unit_id":"U1","tests_added":["a.sh::real one","a.sh::real two"],"criteria_tests":{"U1-1":["a.sh::real one","a.sh::real two"]}}')
OUT=$(run_vc "$P_DECLARED"); RC_A=$?
assert_eq "5.2 CONTROL: every criteria_tests ref IS in tests_added: rc=0" "0" "$RC_A"
assert_eq "5.2 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"

# Same reference cited by TWO criteria is legal — tests_added membership is
# a SET check, not a one-ref-one-criterion check.
P_SHARED=$(payload '{"unit_id":"U1","tests_added":["a.sh::covers both"],"criteria_tests":{"U1-1":["a.sh::covers both"],"U1-2":["a.sh::covers both"]}}')
OUT=$(run_vc "$P_SHARED"); RC_A=$?
assert_eq "5.3 the SAME test_ref cited by two different criteria: legal (rc=0)" "0" "$RC_A"
assert_eq "5.3 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"

# ---------------------------------------------------------------------------
echo ""
echo "=== META-TEST: strip CRITERIA-TESTS-VALIDATION from a COPY -> a payload"
echo "with no criteria_tests at all, or an invented undeclared reference, is"
echo "WRONGLY accepted by the mutant and correctly refused by the shipped"
echo "script =================================================================="

META_RC="$WORKDIR/review-check-stripped.sh"
STRIP_RC=0
awk '
    /^ *# CRITERIA-TESTS-VALIDATION BEGIN/ { skip = 1; found = 1; next }
    /^ *# CRITERIA-TESTS-VALIDATION END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$RC" > "$META_RC" || STRIP_RC=$?
chmod +x "$META_RC" 2>/dev/null || true

assert_eq "META.1 the sentinels were found and the strip ran cleanly (rc=0)" "0" "$STRIP_RC"

SHIPPED_LINES=$(wc -l < "$RC" | tr -d '[:space:]')
STRIPPED_LINES=$(wc -l < "$META_RC" | tr -d '[:space:]')
assert_eq "META.2 non-vacuity: the mutant copy is shorter than the shipped script" \
    "shorter" "$([ "$STRIPPED_LINES" -lt "$SHIPPED_LINES" ] && echo shorter || echo same-or-longer)"
BASH_N_RC=0
bash -n "$META_RC" 2>/dev/null || BASH_N_RC=$?
assert_eq "META.3 the mutant still parses (bash -n rc=0)" "0" "$BASH_N_RC"

# A payload with NO criteria_tests key at all — the pre-piece-4 shape.
P_NOFIELD=$(jq -n '
    {task_id:"t-1", files_changed:[], tests_added:[], decisions:[],
     blockers:[], llm_observations:"x", context_coverage:"y",
     role:"devops", model:"m", pin:"m",
     unit_id:"", design_hash:"", green_before:"none", green_after:"none"}
' > "$WORKDIR/nofield.json"; printf '%s' "$WORKDIR/nofield.json")

MUTANT_OUT=$(bash "$META_RC" validate-completion "$P_NOFIELD" 2>/dev/null); MUTANT_RC=$?
assert_eq "META.4 SPECIFIC MISBEHAVIOUR: the mutant accepts a payload with NO criteria_tests field at all (rc=0)" \
    "0" "$MUTANT_RC"
assert_eq "META.4 ...ok=true on the mutant" "true" "$(printf '%s' "$MUTANT_OUT" | jq -r '.ok')"

SHIPPED_OUT=$(bash "$RC" validate-completion "$P_NOFIELD" 2>/dev/null); SHIPPED_RC=$?
assert_eq "META.5 RESTORE CONTROL: the SAME payload against the shipped script refuses (rc=4)" \
    "4" "$SHIPPED_RC"
assert_eq "META.5 ...error_key=missing_key:criteria_tests" \
    "missing_key:criteria_tests" "$(printf '%s' "$SHIPPED_OUT" | jq -r '.error_key')"

# The mechanical half of "a mention mistaken for a test": on the mutant, a
# payload naming an INVENTED test reference (not in tests_added, not even
# a real convention) is accepted with NOTHING checking it — precisely the
# gap this piece closes.
P_INVENTED=$(jq -n '
    {task_id:"t-1", files_changed:[], tests_added:[], decisions:[],
     blockers:[], llm_observations:"x", context_coverage:"y",
     role:"devops", model:"m", pin:"m",
     unit_id:"U1", design_hash:"", green_before:"none", green_after:"none",
     criteria_tests:{"U1-1":["nonexistent.sh::completely invented"]}}
' > "$WORKDIR/invented.json"; printf '%s' "$WORKDIR/invented.json")
MUTANT_INV_RC=0
bash "$META_RC" validate-completion "$P_INVENTED" >/dev/null 2>&1 || MUTANT_INV_RC=$?
assert_eq "META.6 the mutant accepts an INVENTED, undeclared test reference (rc=0)" \
    "0" "$MUTANT_INV_RC"
SHIPPED_INV_RC=0
bash "$RC" validate-completion "$P_INVENTED" >/dev/null 2>&1 || SHIPPED_INV_RC=$?
assert_eq "META.6 ...while the shipped script still refuses it (rc=4) — the very check this META-TEST proves is load-bearing" \
    "4" "$SHIPPED_INV_RC"

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

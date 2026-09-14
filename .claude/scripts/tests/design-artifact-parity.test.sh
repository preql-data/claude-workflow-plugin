#!/bin/bash
# design-artifact-parity.test.sh — v5 D5 piece 4 (claude-workflow-plugin-
# fkm.7, ez9h). Two disagreeing design-artifact path resolvers, closed.
#
# THE DEFECT. qa-gate.sh's `design_artifact_path_for` is the ONE physical
# resolver: it is the WRITER (cmd_design_record's own derived path) and
# every OTHER reader in that file (compute_design_satisfied, cmd_design_
# conform, cmd_spec_injection_status, compute_design_conflict_open) all
# resolve a design_task's mirrored artifact through it. subagent-start.sh's
# `inject_unit_spec` used to build the SAME path a SECOND way, raw:
# `"$PROJECT_DIR/docs/specs/${design_task}.md"` — no sanitisation at all.
# design_task's own grammar (latest_design_unit_binding's capture, this
# file's identical one) allows `[A-Za-z0-9._+-]+` — note the `+` —
# while design_artifact_path_for replaces every character OUTSIDE
# `[A-Za-z0-9._-]` (no `+`) with `_`. A design_task containing a `+`
# therefore resolved to TWO DIFFERENT FILENAMES depending on which side
# read it, and subagent-start.sh's raw construction pointed at a file that
# does not exist on disk (the real artifact lives at the sanitised path),
# so spec injection degraded on EVERY spawn for such a design_task — a
# real, reachable defect, not a hypothetical one.
#
# THE FIX: subagent-start.sh now resolves the artifact through its OWN
# `resolve_design_artifact_path`, whose `tr` invocation is REQUIRED to
# stay byte-identical to qa-gate.sh's `design_artifact_path_for`. This
# spec is the parity check that makes a future divergence between the two
# a failure here rather than a silent, spawn-time degradation discovered
# only by reading logs.
#
# THE FUNCTIONS UNDER TEST ARE EXTRACTED FROM THE SHIPPED SCRIPTS by awk,
# never re-typed here — a copy of either sanitiser in this file would be a
# THIRD implementation, free to drift from both, which is the exact defect
# class this spec exists to close.
#
# Sections:
#   1  extraction + self-check (the extraction is the test's own dependency)
#   2  SOURCE-LEVEL PARITY: the two `tr` invocations are byte-identical
#      strings, extracted independently from each shipped script
#   3  BEHAVIOURAL PARITY, RUNNING BOTH SHIPPED FUNCTIONS: a cross-product of
#      design_task values (ordinary ids, and the `+`-bearing id that is the
#      whole defect) produces the IDENTICAL resolved path from both
#   4  META: a copy of subagent-start.sh's resolver reverted to the OLD raw
#      construction DISAGREES with qa-gate.sh's on the `+`-bearing id (the
#      specific misbehaviour this spec exists to catch), while the SHIPPED
#      resolver (section 3) does not — a restore control over the same input
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
QG="$PROJECT_DIR/.claude/scripts/qa-gate.sh"
SAS="$PROJECT_DIR/.claude/scripts/subagent-start.sh"

if [ ! -f "$QG" ]; then
    printf 'design-artifact-parity.test: script under test missing: %s\n' "$QG" >&2
    exit 2
fi
if [ ! -f "$SAS" ]; then
    printf 'design-artifact-parity.test: script under test missing: %s\n' "$SAS" >&2
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

WORK=$(mktemp -d -t design-artifact-parity.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "=== Section 1: extraction ==="
# ---------------------------------------------------------------------------

QG_LIB="$WORK/qg-resolver.sh"
awk '/^design_artifact_path_for\(\) \{/,/^\}/' "$QG" > "$QG_LIB"
assert_eq "1.1 the qa-gate.sh extraction defines design_artifact_path_for" "1" \
    "$(grep -c '^design_artifact_path_for() {$' "$QG_LIB" | tr -d '[:space:]')"
assert_eq "1.2 the qa-gate.sh extraction parses" "0" \
    "$(bash -n "$QG_LIB" 2>/dev/null && echo 0 || echo 1)"

SAS_LIB="$WORK/sas-resolver.sh"
awk '/^resolve_design_artifact_path\(\) \{/,/^\}/' "$SAS" > "$SAS_LIB"
assert_eq "1.3 the subagent-start.sh extraction defines resolve_design_artifact_path" "1" \
    "$(grep -c '^resolve_design_artifact_path() {$' "$SAS_LIB" | tr -d '[:space:]')"
assert_eq "1.4 the subagent-start.sh extraction parses" "0" \
    "$(bash -n "$SAS_LIB" 2>/dev/null && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: SOURCE-LEVEL PARITY — the two tr invocations agree ==="
# ---------------------------------------------------------------------------

# Anchored on the exact sanitiser text, never on a line number. If either
# script's character class changes without the other's, this line stops
# matching and the extraction below returns empty — caught by 2.1/2.2
# before the comparison in 2.3 could pass vacuously.
TR_NEEDLE="tr -c 'A-Za-z0-9._-' '_'"

QG_TR_COUNT=$(grep -cF "$TR_NEEDLE" "$QG_LIB" | tr -d '[:space:]')
SAS_TR_COUNT=$(grep -cF "$TR_NEEDLE" "$SAS_LIB" | tr -d '[:space:]')
assert_eq "2.1 qa-gate.sh's extracted resolver carries the sanitiser exactly once" "1" "$QG_TR_COUNT"
assert_eq "2.2 subagent-start.sh's extracted resolver carries the sanitiser exactly once" "1" "$SAS_TR_COUNT"

QG_TR_LINE=$(grep -F "$TR_NEEDLE" "$QG_LIB" | sed 's/^[[:space:]]*//')
SAS_TR_LINE=$(grep -F "$TR_NEEDLE" "$SAS_LIB" | sed 's/^[[:space:]]*//')
assert_eq "2.3 the two sanitiser lines are byte-identical after stripping leading indentation" \
    "$QG_TR_LINE" "$SAS_TR_LINE"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: BEHAVIOURAL PARITY — running BOTH shipped functions ==="
# ---------------------------------------------------------------------------

# run_qg_resolver <project-dir> <design-task> -> the path qa-gate.sh's
# design_artifact_path_for resolves. DESIGN_SPEC_SUBDIR is set to the exact
# literal that function reads (qa-gate.sh:8829, DESIGN_SPEC_SUBDIR="docs/specs")
# — reproduced here rather than sourced, because sourcing the constant would
# require sourcing everything above it in the file.
run_qg_resolver() {
    local pdir="$1" dtask="$2"
    bash -c '
        set -u
        PROJECT_DIR="$1"
        DESIGN_SPEC_SUBDIR="docs/specs"
        . "$2"
        design_artifact_path_for "$3"
    ' _ "$pdir" "$QG_LIB" "$dtask"
}

# run_sas_resolver <project-dir> <design-task> -> the path subagent-start.sh's
# resolve_design_artifact_path resolves.
run_sas_resolver() {
    local pdir="$1" dtask="$2"
    bash -c '
        set -u
        PROJECT_DIR="$1"
        . "$2"
        resolve_design_artifact_path "$3"
    ' _ "$pdir" "$SAS_LIB" "$dtask"
}

# The cross-product: ordinary ids (the common case, must keep working
# identically), PLUS the `+`-bearing id that IS the defect — a real,
# grammar-legal design_task shape (latest_design_unit_binding's own
# capture class is [A-Za-z0-9._+-]+), not a contrived edge case.
DESIGN_TASKS=(
    "claude-workflow-plugin-fkm"
    "claude-workflow-plugin-fkm.7"
    "E-DESIGN"
    "a+b"
    "claude-workflow-plugin-a+b.3"
    "++weird+.+id++"
)

for dt in "${DESIGN_TASKS[@]}"; do
    qg_path=$(run_qg_resolver "/proj" "$dt")
    sas_path=$(run_sas_resolver "/proj" "$dt")
    assert_eq "3.$dt: both resolvers agree for design_task='$dt'" "$qg_path" "$sas_path"
done

# The specific defect, named explicitly rather than left implicit in the
# loop above: for the `+`-bearing id, confirm BOTH sides actually sanitised
# the `+` away (proving this is a REAL behavioural check, not a vacuous
# comparison of two empty strings or two untouched inputs).
PLUS_QG=$(run_qg_resolver "/proj" "a+b")
PLUS_SAS=$(run_sas_resolver "/proj" "a+b")
assert_eq "3b NON-VACUITY: qa-gate.sh's resolver actually sanitised the '+' (no '+' in the resolved path)" \
    "0" "$(printf '%s' "$PLUS_QG" | grep -c '+' | tr -d '[:space:]')"
assert_eq "3c NON-VACUITY: subagent-start.sh's resolver actually sanitised the '+' too" \
    "0" "$(printf '%s' "$PLUS_SAS" | grep -c '+' | tr -d '[:space:]')"
assert_eq "3d ...and the resolved path is the expected sanitised filename" \
    "/proj/docs/specs/a_b.md" "$PLUS_QG"

# ---------------------------------------------------------------------------
echo ""
echo "=== META-TEST: a resolver reverted to the OLD raw construction DISAGREES"
echo "    on the '+'-bearing id — the specific misbehaviour this spec exists"
echo "    to catch, with the shipped resolver (Section 3) as the restore control"
# ---------------------------------------------------------------------------

# The OLD, pre-fix subagent-start.sh shape: no sanitiser, direct
# interpolation. Written here as a STANDALONE reproduction (not extracted
# from any file — there is nothing left in the shipped tree to extract, by
# construction of the fix), matching what ez9h's own description of the
# pre-fix line named verbatim: `"$PROJECT_DIR/docs/specs/${design_task}.md"`.
OLD_RAW_LIB="$WORK/old-raw-resolver.sh"
cat > "$OLD_RAW_LIB" <<'MUTANT'
resolve_design_artifact_path() {
    printf '%s/docs/specs/%s.md' "$PROJECT_DIR" "$1"
}
MUTANT

assert_eq "META.1 NON-VACUITY: the old-raw mutant is a real, different file (not empty)" \
    "1" "$([ -s "$OLD_RAW_LIB" ] && echo 1 || echo 0)"
assert_eq "META.2 ...and it parses" "0" \
    "$(bash -n "$OLD_RAW_LIB" 2>/dev/null && echo 0 || echo 1)"
assert_eq "META.3 ...and it genuinely carries no sanitiser (the mutation is real, not a no-op copy)" \
    "0" "$(grep -c "tr -c" "$OLD_RAW_LIB" | tr -d '[:space:]')"

run_old_raw_resolver() {
    local pdir="$1" dtask="$2"
    bash -c '
        set -u
        PROJECT_DIR="$1"
        . "$2"
        resolve_design_artifact_path "$3"
    ' _ "$pdir" "$OLD_RAW_LIB" "$dtask"
}

OLD_RAW_PLUS=$(run_old_raw_resolver "/proj" "a+b")
assert_eq "META.4 SPECIFIC MISBEHAVIOUR: the old-raw mutant does NOT sanitise the '+' (it survives into the path)" \
    "1" "$(printf '%s' "$OLD_RAW_PLUS" | grep -c '+' | tr -d '[:space:]')"
assert_eq "META.5 ...so the mutant DISAGREES with qa-gate.sh's own resolver on the exact input that is the defect" \
    "no" "$([ "$OLD_RAW_PLUS" = "$PLUS_QG" ] && echo yes || echo no)"
assert_eq "META.5b ...naming the actual two paths, so the disagreement is legible" \
    "/proj/docs/specs/a+b.md != /proj/docs/specs/a_b.md" \
    "$OLD_RAW_PLUS != $PLUS_QG"

# RESTORE CONTROL: the SHIPPED resolver (already proven in Section 3) DOES
# agree on the identical input — the disagreement above is caused by the
# mutation, not by some property of the input itself or of this harness.
assert_eq "META.6 RESTORE CONTROL: the SHIPPED subagent-start.sh resolver agrees with qa-gate.sh on the SAME '+' input" \
    "yes" "$([ "$PLUS_SAS" = "$PLUS_QG" ] && echo yes || echo no)"

# --- Summary ---------------------------------------------------------------

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

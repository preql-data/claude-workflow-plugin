#!/bin/bash
# judge-calibration.test.sh — Phase C.2 (claude-workflow-plugin-n45.2).
#
# Asserts:
#
#   1. judge-gate.sh math is correct on synthetic verdict files.
#      Two crafted verdicts: one passes at 0.85, one fails at 0.7.
#      Exact arithmetic asserted (TP/FP/FN/TN counts + precision string).
#   2. calibration-set.json validates:
#      - is a JSON object with `calibration` array length >= 20.
#      - all 8 fault classes appear (or documented absence in
#        `fault_class_coverage.notes`).
#      - every entry has ground_truth in {equivalent, genuine}.
#      - every entry has a non-empty label_rationale.
#      - >= 5 equivalents.
#   3. judge.md frontmatter is correct:
#      - tools is the read-only set (Read, Grep, Glob, LS — NO Bash/Write/Task).
#      - judge.md is registered in plugin.json agents[].
#
#   4. META-TESTs (canaries the spec calls out as required for every
#      new behaviour):
#      4a. Corrupt a verdict id (not in calibration) -> gate errors
#          loudly with exit 2, not a silent skip.
#      4b. Flip a ground_truth in a temp copy of calibration -> precision
#          changes (sensitivity proof).
#      4c. The judge-gate.sh threshold knob is read from mutation.conf;
#          override via --threshold actually changes the verdict.
#
# Conventions mirror the rest of .claude/scripts/tests/* —
# plain bash, `set -u`, assert helpers, trailing summary, tempdir fixtures.
#
# Exit codes:
#   0  every assertion passed
#   1  at least one assertion failed
#   2  invocation error (missing files, no jq)

# shellcheck disable=SC2317
# Same rationale as the sibling tests: assert_* helpers and scenario bodies
# are reached via control flow the static analyzer can't follow.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
JUDGE_GATE="$PROJECT_DIR/.claude/tests/mutation/judge-gate.sh"
CALIBRATION="$PROJECT_DIR/.claude/tests/mutation/calibration/calibration-set.json"
JUDGE_MD="$PROJECT_DIR/.claude/agents/judge.md"
MANIFEST="$PROJECT_DIR/.claude-plugin/plugin.json"
MUTATION_CONF="$PROJECT_DIR/.claude/tests/mutation/mutation.conf"

if ! command -v jq >/dev/null 2>&1; then
    printf 'judge-calibration: jq is required but not on PATH\n' >&2
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
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle: %s\n' "$name" "$needle"
        printf '    haystack(first 4 lines):\n%s\n' \
            "$(printf '%s' "$haystack" | head -4 | sed 's/^/      /')"
    fi
}

# Build a matching calibration file. Args: <out-path> <truths...> where
# truths is a space-separated list of "g" (genuine) or "e" (equivalent),
# one per id. We start at id 1 and walk left-to-right.
build_calibration() {
    local out="$1"; shift
    {
        printf '{"contract_version":"1","calibration":['
        local first=1 i=1 t
        for t in "$@"; do
            [ "$first" = "1" ] && first=0 || printf ','
            local truth
            case "$t" in
                g) truth="genuine" ;;
                e) truth="equivalent" ;;
                *) truth="genuine" ;;
            esac
            printf '{"id":%d,"fault":"F1","target":"x","line":1,"rationale":"x","orig":"x","mut":"x","status":"SURVIVED","ground_truth":"%s","label_rationale":"L1 fixture"}' \
                "$i" "$truth"
            i=$((i + 1))
        done
        printf ']}'
    } > "$out"
}

TEMP_DIRS=()
# shellcheck disable=SC2329  # invoked via trap.
cleanup_all() {
    local d
    for d in "${TEMP_DIRS[@]:-}"; do
        [ -z "$d" ] && continue
        rm -rf "$d"
    done
}
trap cleanup_all EXIT INT TERM

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: judge-gate.sh math — passing 0.85 verdict ==="

FIX1=$(mktemp -d -t judge-calibration-pass.XXXXXX)
TEMP_DIRS+=("$FIX1")

# Build a calibration with 14 entries: 9 truth=genuine, 5 truth=equivalent.
# Build a verdict where judge calls 10 genuine (the 9 true-genuine + 1 of
# the 5 true-equivalent) and 4 equivalent (the remaining 4 true-equivalent).
#
#   TP = 9 (judge=g, truth=g)
#   FP = 1 (judge=g, truth=e)
#   FN = 0 (judge=e, truth=g)
#   TN = 4 (judge=e, truth=e)
#   precision = 9 / (9 + 1) = 0.9000  (passes 0.8 threshold)
#   recall    = 9 / (9 + 0) = 1.0000

# Calibration: ids 1-9 = genuine, ids 10-14 = equivalent.
build_calibration "$FIX1/calibration-pass.json" g g g g g g g g g e e e e e

# Verdict: judge marks ids 1-10 as genuine (the 1 wrong: id 10 is truly equivalent),
# ids 11-14 as equivalent.
# We can't use build_verdict directly because it doesn't allow mixed ordering;
# craft inline.
cat > "$FIX1/verdict-pass.json" <<'JSON'
{
  "contract_version": "1",
  "verdicts": [
    {"id": 1,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 2,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 3,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 4,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 5,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 6,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 7,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 8,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 9,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 10, "classification": "genuine",    "confidence": 0.6,  "justification": "L1 fixture (FP)"},
    {"id": 11, "classification": "equivalent", "confidence": 0.8,  "justification": "L1 fixture"},
    {"id": 12, "classification": "equivalent", "confidence": 0.8,  "justification": "L1 fixture"},
    {"id": 13, "classification": "equivalent", "confidence": 0.8,  "justification": "L1 fixture"},
    {"id": 14, "classification": "equivalent", "confidence": 0.8,  "justification": "L1 fixture"}
  ]
}
JSON

if bash "$JUDGE_GATE" \
    --verdict "$FIX1/verdict-pass.json" \
    --calibration "$FIX1/calibration-pass.json" \
    --quiet >/dev/null 2>&1; then
    rc_pass=0
else
    rc_pass=$?
fi
assert_eq "pass verdict: exit code 0" "0" "$rc_pass"

REPORT_PASS="$FIX1/calibration-report.json"
[ -f "$REPORT_PASS" ] && rc=0 || rc=1
assert_eq "pass verdict: report written to disk" "0" "$rc"

assert_eq "pass verdict: TP == 9" "9" "$(jq -r '.confusion.TP' "$REPORT_PASS")"
assert_eq "pass verdict: FP == 1" "1" "$(jq -r '.confusion.FP' "$REPORT_PASS")"
assert_eq "pass verdict: FN == 0" "0" "$(jq -r '.confusion.FN' "$REPORT_PASS")"
assert_eq "pass verdict: TN == 4" "4" "$(jq -r '.confusion.TN' "$REPORT_PASS")"
assert_eq "pass verdict: precision == 0.9" "0.9" "$(jq -r '.precision' "$REPORT_PASS")"
assert_eq "pass verdict: recall    == 1"   "1"   "$(jq -r '.recall' "$REPORT_PASS")"
# Note: jq -r emits 0.9 for 0.9000 and 1 for 1.0000 after `| tonumber`
# normalization in the report builder. We assert against the canonical
# JSON-numeric form, not the awk-printf string.
assert_eq "pass verdict: gate_verdict == passed" "passed" \
    "$(jq -r '.gate_verdict' "$REPORT_PASS")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: judge-gate.sh math — failing 0.7 verdict ==="

FIX2=$(mktemp -d -t judge-calibration-fail.XXXXXX)
TEMP_DIRS+=("$FIX2")

# Calibration: same 9/5 split.
build_calibration "$FIX2/calibration-fail.json" g g g g g g g g g e e e e e

# Verdict: judge marks ids 1-10 + ids 11,12 as genuine (12 genuine total —
# 9 TP + 3 FP), ids 13,14 as equivalent (2 TN; 0 FN — since all 9 true-
# genuines were correctly called genuine).
#   TP = 9  (the 9 truly-genuine all called genuine)
#   FP = 3  (the 3 equivalents called genuine)
#   FN = 0
#   TN = 2
#   precision = 9 / (9 + 3) = 0.7500  (FAILS 0.8 threshold)
#   recall    = 9 / (9 + 0) = 1.0000

cat > "$FIX2/verdict-fail.json" <<'JSON'
{
  "contract_version": "1",
  "verdicts": [
    {"id": 1,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 2,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 3,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 4,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 5,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 6,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 7,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 8,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 9,  "classification": "genuine",    "confidence": 0.95, "justification": "L1 fixture"},
    {"id": 10, "classification": "genuine",    "confidence": 0.6,  "justification": "L1 fixture (FP)"},
    {"id": 11, "classification": "genuine",    "confidence": 0.6,  "justification": "L1 fixture (FP)"},
    {"id": 12, "classification": "genuine",    "confidence": 0.6,  "justification": "L1 fixture (FP)"},
    {"id": 13, "classification": "equivalent", "confidence": 0.8,  "justification": "L1 fixture"},
    {"id": 14, "classification": "equivalent", "confidence": 0.8,  "justification": "L1 fixture"}
  ]
}
JSON

if bash "$JUDGE_GATE" \
    --verdict "$FIX2/verdict-fail.json" \
    --calibration "$FIX2/calibration-fail.json" \
    --quiet >/dev/null 2>&1; then
    rc_fail=0
else
    rc_fail=$?
fi
assert_eq "fail verdict: exit code 1 (precision < threshold)" "1" "$rc_fail"

REPORT_FAIL="$FIX2/calibration-report.json"
assert_eq "fail verdict: TP == 9"  "9"  "$(jq -r '.confusion.TP' "$REPORT_FAIL")"
assert_eq "fail verdict: FP == 3"  "3"  "$(jq -r '.confusion.FP' "$REPORT_FAIL")"
assert_eq "fail verdict: FN == 0"  "0"  "$(jq -r '.confusion.FN' "$REPORT_FAIL")"
assert_eq "fail verdict: TN == 2"  "2"  "$(jq -r '.confusion.TN' "$REPORT_FAIL")"
assert_eq "fail verdict: precision == 0.75" "0.75" "$(jq -r '.precision' "$REPORT_FAIL")"
assert_eq "fail verdict: gate_verdict == failed" "failed" \
    "$(jq -r '.gate_verdict' "$REPORT_FAIL")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: real calibration-set.json validates ==="

[ -f "$CALIBRATION" ] && rc=0 || rc=1
assert_eq "calibration: file exists" "0" "$rc"

CALIB_LEN=$(jq -r '.calibration | length' "$CALIBRATION")
[ "$CALIB_LEN" -ge 20 ] && rc=0 || rc=1
assert_eq "calibration: at least 20 entries (have $CALIB_LEN)" "0" "$rc"

EQUIV_COUNT=$(jq -r '[.calibration[] | select(.ground_truth == "equivalent")] | length' "$CALIBRATION")
[ "$EQUIV_COUNT" -ge 5 ] && rc=0 || rc=1
assert_eq "calibration: at least 5 equivalents (have $EQUIV_COUNT)" "0" "$rc"

# Every entry must have ground_truth in the enum.
BAD_TRUTH=$(jq -r '[.calibration[] | select(.ground_truth != "equivalent" and .ground_truth != "genuine")] | length' "$CALIBRATION")
assert_eq "calibration: every entry has ground_truth in {equivalent, genuine}" "0" "$BAD_TRUTH"

# Every entry must have a non-empty label_rationale.
BAD_RATIONALE=$(jq -r '[.calibration[] | select(.label_rationale == null or .label_rationale == "")] | length' "$CALIBRATION")
assert_eq "calibration: every entry has non-empty label_rationale" "0" "$BAD_RATIONALE"

# Every entry must have id (number), fault (string), target (string),
# line (number), orig (string), mut (string).
BAD_SHAPE=$(jq -r '[.calibration[]
    | select(
        (.id          | type) != "number"   or
        (.fault       | type) != "string"   or
        (.target      | type) != "string"   or
        (.line        | type) != "number"   or
        (.orig        | type) != "string"   or
        (.mut         | type) != "string"
    )] | length' "$CALIBRATION")
assert_eq "calibration: every entry has the survivor-shape fields (id/fault/target/line/orig/mut)" "0" "$BAD_SHAPE"

# All 8 fault classes present (or notes document absence).
for fid in F1 F2 F3 F4 F5 F6 F7 F8; do
    count=$(jq -r --arg f "$fid" '[.calibration[] | select(.fault == $f)] | length' "$CALIBRATION")
    if [ "$count" -ge 1 ]; then
        rc=0
    else
        # Allow absence only when explicitly documented in the notes block.
        notes=$(jq -r '.fault_class_coverage.notes // ""' "$CALIBRATION")
        if printf '%s' "$notes" | grep -qE "\\b$fid\\b"; then
            rc=0
            printf '    (note: %s absent; documented in fault_class_coverage.notes)\n' "$fid"
        else
            rc=1
        fi
    fi
    assert_eq "calibration: fault class $fid represented (or absence documented)" "0" "$rc"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: judge.md frontmatter and manifest registration ==="

[ -f "$JUDGE_MD" ] && rc=0 || rc=1
assert_eq "judge.md: file exists" "0" "$rc"

# Tools line must contain ONLY read-only tools. We grep the frontmatter
# region for the tools: line and check the contents.
JUDGE_TOOLS=$(awk '/^---$/{n++; if (n>=2) exit; next} n==1 && /^tools:/{sub(/^tools:[[:space:]]*/, ""); print}' "$JUDGE_MD")
assert_eq "judge.md: tools line found" \
    "found" \
    "$([ -n "$JUDGE_TOOLS" ] && echo found || echo missing)"

# The set is the READ-ONLY surface: Read, Grep, Glob, LS. Anything else
# (Bash, Write, Edit, MultiEdit, Task, WebFetch, WebSearch, AskUserQuestion,
# mcp__*) is forbidden — the judge is purely read-only by design.
FORBIDDEN_PATTERNS="Bash Write Edit MultiEdit Task WebFetch WebSearch AskUserQuestion mcp__"
for pat in $FORBIDDEN_PATTERNS; do
    if printf '%s' "$JUDGE_TOOLS" | grep -qw -- "$pat"; then
        rc=1
    else
        rc=0
    fi
    assert_eq "judge.md: tools does NOT include $pat (read-only enforced)" "0" "$rc"
done

# Positive: must include the four read-only tools.
for needed in Read Grep Glob LS; do
    if printf '%s' "$JUDGE_TOOLS" | grep -qw -- "$needed"; then
        rc=0
    else
        rc=1
    fi
    assert_eq "judge.md: tools includes $needed" "0" "$rc"
done

# Registration in plugin.json agents[].
JUDGE_REGISTERED=$(jq -r '.agents[]?' "$MANIFEST" 2>/dev/null | grep -F 'judge.md' | head -1)
if [ -n "$JUDGE_REGISTERED" ]; then
    rc=0
else
    rc=1
fi
assert_eq "judge.md: registered in plugin.json agents[]" "0" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: META-TEST 1 — corrupted verdict id errors loudly ==="
#
# A judge that returns a verdict for an id absent from the calibration
# set MUST surface that as a structured error (exit 2), not silently skip
# the row and compute precision on a partial join. Without this guard a
# corrupted run could mask half the survivors and still report 1.0
# precision on the remaining 2 — a silent disaster.

FIX_META1=$(mktemp -d -t judge-calibration-meta1.XXXXXX)
TEMP_DIRS+=("$FIX_META1")

build_calibration "$FIX_META1/calibration.json" g g e
cat > "$FIX_META1/verdict-corrupt.json" <<'JSON'
{
  "contract_version": "1",
  "verdicts": [
    {"id": 1,   "classification": "genuine",    "confidence": 0.95, "justification": "x"},
    {"id": 999, "classification": "genuine",    "confidence": 0.95, "justification": "x"},
    {"id": 3,   "classification": "equivalent", "confidence": 0.95, "justification": "x"}
  ]
}
JSON

# Capture stderr for the diagnostic check.
META_OUT=$(bash "$JUDGE_GATE" \
    --verdict "$FIX_META1/verdict-corrupt.json" \
    --calibration "$FIX_META1/calibration.json" \
    --quiet 2>&1 1>/dev/null) && META_RC=$? || META_RC=$?

assert_eq "META 1: corrupt id exits 2" "2" "$META_RC"
assert_contains "META 1: error names 'verdict ids absent from calibration'" \
    "verdict ids absent from calibration" "$META_OUT"
assert_contains "META 1: error includes the corrupt id 999" \
    "999" "$META_OUT"
# And — crucially — no report file should be written for a failed input
# validation, so a downstream consumer cannot pick up stale state.
[ ! -f "$FIX_META1/calibration-report.json" ] && rc=0 || rc=1
assert_eq "META 1: no report written on corrupt id (no silent skip)" "0" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: META-TEST 2 — flipping a ground_truth changes precision ==="
#
# Build a baseline (calibration A, verdict V) producing precision P_A,
# then flip ONE ground_truth in a copy of calibration to A' and rerun
# with the SAME verdict V; assert precision shifts to P_A' != P_A.
# This proves the gate's math is actually sensitive to the truth labels
# — a regression where the join ignored ground_truth (e.g., always
# computed TP from classification alone) would NOT shift the precision
# when we flip the truth, and this test would fail.

FIX_META2=$(mktemp -d -t judge-calibration-meta2.XXXXXX)
TEMP_DIRS+=("$FIX_META2")

# Baseline: 4 entries — 2 truth=g, 2 truth=e. Verdict: all called genuine.
# TP=2, FP=2, precision = 2/4 = 0.5.
build_calibration "$FIX_META2/calibration-A.json"  g g e e
cat > "$FIX_META2/verdict-V.json" <<'JSON'
{
  "contract_version": "1",
  "verdicts": [
    {"id": 1, "classification": "genuine", "confidence": 0.9, "justification": "x"},
    {"id": 2, "classification": "genuine", "confidence": 0.9, "justification": "x"},
    {"id": 3, "classification": "genuine", "confidence": 0.9, "justification": "x"},
    {"id": 4, "classification": "genuine", "confidence": 0.9, "justification": "x"}
  ]
}
JSON

bash "$JUDGE_GATE" \
    --verdict "$FIX_META2/verdict-V.json" \
    --calibration "$FIX_META2/calibration-A.json" \
    --report "$FIX_META2/report-A.json" \
    --quiet >/dev/null 2>&1 || true

P_A=$(jq -r '.precision' "$FIX_META2/report-A.json")
assert_eq "META 2 baseline: precision A == 0.5 (2 truth-genuine out of 4 verdicts)" "0.5" "$P_A"

# Flip: change id 3 from equivalent -> genuine. Now 3 truths genuine, 1 truth equivalent.
# TP=3, FP=1, precision = 3/4 = 0.75.
build_calibration "$FIX_META2/calibration-Aprime.json" g g g e
bash "$JUDGE_GATE" \
    --verdict "$FIX_META2/verdict-V.json" \
    --calibration "$FIX_META2/calibration-Aprime.json" \
    --report "$FIX_META2/report-Aprime.json" \
    --quiet >/dev/null 2>&1 || true

P_APRIME=$(jq -r '.precision' "$FIX_META2/report-Aprime.json")
assert_eq "META 2 sensitivity: precision A' == 0.75 (one ground_truth flipped e->g)" "0.75" "$P_APRIME"

# Critical META assertion: the two precisions MUST differ. If they're
# equal, the gate is ignoring ground_truth and the precision-test is
# vacuous.
if [ "$P_A" != "$P_APRIME" ]; then
    rc=0
else
    rc=1
fi
assert_eq "META 2: P_A differs from P_A' — gate IS sensitive to ground_truth" "0" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: threshold knob — mutation.conf + --threshold override ==="
#
# mutation.conf declares JUDGE_PRECISION_MIN=0.8 (the default).
# We assert the gate reads it, and that --threshold overrides it.

THR_FROM_CONF=$(grep -E '^JUDGE_PRECISION_MIN=' "$MUTATION_CONF" \
    | head -1 | cut -d= -f2 | tr -d '[:space:]')
assert_eq "mutation.conf: JUDGE_PRECISION_MIN is set" "0.8" "$THR_FROM_CONF"

# With --threshold 0.9, the 0.75 verdict from Section 6 (calibration A')
# fails. With --threshold 0.5, it passes. This is the override path.
FIX_META3=$(mktemp -d -t judge-calibration-thr.XXXXXX)
TEMP_DIRS+=("$FIX_META3")

cp "$FIX_META2/calibration-Aprime.json" "$FIX_META3/c.json"
cp "$FIX_META2/verdict-V.json" "$FIX_META3/v.json"

if bash "$JUDGE_GATE" \
    --verdict "$FIX_META3/v.json" \
    --calibration "$FIX_META3/c.json" \
    --threshold 0.5 \
    --quiet >/dev/null 2>&1; then
    rc_thr_low=0
else
    rc_thr_low=$?
fi
assert_eq "threshold override: 0.75 verdict passes when --threshold 0.5" "0" "$rc_thr_low"

if bash "$JUDGE_GATE" \
    --verdict "$FIX_META3/v.json" \
    --calibration "$FIX_META3/c.json" \
    --threshold 0.9 \
    --quiet >/dev/null 2>&1; then
    rc_thr_high=0
else
    rc_thr_high=$?
fi
assert_eq "threshold override: 0.75 verdict fails when --threshold 0.9" "1" "$rc_thr_high"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: judge-gate rejects malformed verdict shapes ==="
#
# A judge that emits a classification outside the enum MUST be rejected.
# Otherwise the precision calc treats the bad string as 'equivalent' (the
# default branch in jq), masking the failure.

FIX_BAD=$(mktemp -d -t judge-calibration-bad.XXXXXX)
TEMP_DIRS+=("$FIX_BAD")

build_calibration "$FIX_BAD/calibration.json" g

# Bad classification string.
cat > "$FIX_BAD/verdict-bad-class.json" <<'JSON'
{
  "contract_version": "1",
  "verdicts": [
    {"id": 1, "classification": "unsure", "confidence": 0.5, "justification": "x"}
  ]
}
JSON

if bash "$JUDGE_GATE" \
    --verdict "$FIX_BAD/verdict-bad-class.json" \
    --calibration "$FIX_BAD/calibration.json" \
    --quiet >/dev/null 2>&1; then
    rc_bad_class=0
else
    rc_bad_class=$?
fi
assert_eq "malformed: 'unsure' classification exits 2" "2" "$rc_bad_class"

# Missing id field.
cat > "$FIX_BAD/verdict-no-id.json" <<'JSON'
{
  "contract_version": "1",
  "verdicts": [
    {"classification": "genuine", "confidence": 0.9, "justification": "x"}
  ]
}
JSON

if bash "$JUDGE_GATE" \
    --verdict "$FIX_BAD/verdict-no-id.json" \
    --calibration "$FIX_BAD/calibration.json" \
    --quiet >/dev/null 2>&1; then
    rc_no_id=0
else
    rc_no_id=$?
fi
assert_eq "malformed: missing id field exits 2" "2" "$rc_no_id"

# Top-level not an object.
echo "[]" > "$FIX_BAD/verdict-array.json"
if bash "$JUDGE_GATE" \
    --verdict "$FIX_BAD/verdict-array.json" \
    --calibration "$FIX_BAD/calibration.json" \
    --quiet >/dev/null 2>&1; then
    rc_array=0
else
    rc_array=$?
fi
assert_eq "malformed: top-level array exits 2" "2" "$rc_array"

# Garbage (not JSON at all).
echo "not json at all" > "$FIX_BAD/verdict-garbage.json"
if bash "$JUDGE_GATE" \
    --verdict "$FIX_BAD/verdict-garbage.json" \
    --calibration "$FIX_BAD/calibration.json" \
    --quiet >/dev/null 2>&1; then
    rc_garbage=0
else
    rc_garbage=$?
fi
assert_eq "malformed: non-JSON exits 2" "2" "$rc_garbage"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9: judge-gate handles undefined precision (zero genuine predictions) ==="
#
# When the judge predicts EVERYTHING as equivalent, precision is
# undefined (0/0). The gate must surface this as a distinct exit code
# (3) rather than silently treating undefined as either pass or fail.

FIX_UNDEF=$(mktemp -d -t judge-calibration-undef.XXXXXX)
TEMP_DIRS+=("$FIX_UNDEF")

build_calibration "$FIX_UNDEF/calibration.json" g g e e
cat > "$FIX_UNDEF/verdict-all-equiv.json" <<'JSON'
{
  "contract_version": "1",
  "verdicts": [
    {"id": 1, "classification": "equivalent", "confidence": 0.5, "justification": "x"},
    {"id": 2, "classification": "equivalent", "confidence": 0.5, "justification": "x"},
    {"id": 3, "classification": "equivalent", "confidence": 0.5, "justification": "x"},
    {"id": 4, "classification": "equivalent", "confidence": 0.5, "justification": "x"}
  ]
}
JSON

if bash "$JUDGE_GATE" \
    --verdict "$FIX_UNDEF/verdict-all-equiv.json" \
    --calibration "$FIX_UNDEF/calibration.json" \
    --quiet >/dev/null 2>&1; then
    rc_undef=0
else
    rc_undef=$?
fi
assert_eq "undefined precision: exit code 3" "3" "$rc_undef"

REPORT_UNDEF="$FIX_UNDEF/calibration-report.json"
assert_eq "undefined precision: gate_verdict == undefined" \
    "undefined" "$(jq -r '.gate_verdict' "$REPORT_UNDEF")"
assert_eq "undefined precision: precision is null in report" \
    "null" "$(jq -r '.precision' "$REPORT_UNDEF")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 10: judge.md spawn-directive freedom (lesson 4) ==="
#
# The no-nested-spawn rule applies to judge.md too — a subagent must not
# instruct itself to spawn another subagent. Sentinel check: judge.md
# must not contain a Task(subagent_type=...) directive. The
# no-nested-spawn-instructions.test.sh enforces this for the full set;
# we add an in-test sanity probe here so a future edit to judge.md that
# accidentally re-nests fails one of TWO tests, not just one.

if grep -qE '^[[:space:]]*Task\([^)]*subagent_type[[:space:]]*=' "$JUDGE_MD"; then
    rc=1
else
    rc=0
fi
assert_eq "judge.md: no Task(subagent_type=...) spawn directive" "0" "$rc"

if grep -qE '^[[:space:]]*Task\([[:space:]]*"@[A-Za-z]+"' "$JUDGE_MD"; then
    rc=1
else
    rc=0
fi
assert_eq "judge.md: no Task(@role) spawn shorthand" "0" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf 'Passed: %d\n' "$PASS"
printf 'Failed: %d\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0

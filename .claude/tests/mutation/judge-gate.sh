#!/bin/bash
# judge-gate.sh — Phase C.2 (claude-workflow-plugin-n45.2) calibration
# gate for the LLM mutation judge.
#
# Joins a verdict.json (the judge's strict-JSON output) against
# calibration-set.json (the hand-labeled ground truth) and computes:
#
#   precision = TP / (TP + FP)
#       where  TP = mutants judge classified `genuine` AND ground_truth `genuine`
#              FP = mutants judge classified `genuine` BUT ground_truth `equivalent`
#
#   recall    = TP / (TP + FN)
#       where  FN = mutants judge classified `equivalent` BUT ground_truth `genuine`
#
# The gate's job is precision. The C.2 design bias is precision over
# recall: missing an equivalent (a false-genuine) wastes one C.3 follow-up;
# missing a genuine (a false-equivalent) buries a real regression.
# JUDGE_PRECISION_MIN (mutation.conf; default 0.8) is the minimum
# precision required to flip the calibration verdict to "passed".
# Recall is reported alongside but is not a gating threshold.
#
# Inputs:
#   --verdict <path>      Path to verdict.json (the judge subagent's output).
#                         Required.
#   --calibration <path>  Path to calibration-set.json (hand-labeled truth).
#                         Default: $SCRIPT_DIR/calibration/calibration-set.json.
#   --report <path>       Path to write the calibration report JSON.
#                         Default: same directory as the verdict file, named
#                         calibration-report.json.
#   --conf <path>         Path to mutation.conf for JUDGE_PRECISION_MIN.
#                         Default: $SCRIPT_DIR/mutation.conf.
#   --threshold <float>   Override JUDGE_PRECISION_MIN for this invocation.
#   --quiet               Suppress the human-readable summary on stdout.
#   --help / -h           Print usage.
#
# Output:
#   - calibration-report.json on disk with the joined truth table,
#     precision, recall, threshold, and pass/fail verdict.
#   - Human-readable summary on stdout (unless --quiet).
#
# Exit codes:
#   0  precision >= threshold (calibration passed)
#   1  precision <  threshold (calibration failed)
#   2  invocation / input error (missing file, malformed JSON, unknown ids)
#   3  precision is undefined (zero genuine predictions from the judge)
#
# Notes:
#   - We refuse to silently skip an id mismatch between verdict and
#     calibration. If the judge returns a verdict for an id not in the
#     calibration set, OR a calibration entry has no matching verdict,
#     we exit 2 with a structured error naming the offending ids. This
#     prevents the gate from silently masking a corrupted run.
#   - The script is jq-based and bash-portable. shellcheck-clean.

set -u

# ---------------------------------------------------------------------------
# Bootstrap

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

VERDICT_PATH=""
CALIBRATION_PATH="$SCRIPT_DIR/calibration/calibration-set.json"
REPORT_PATH=""
CONF_PATH="$SCRIPT_DIR/mutation.conf"
THRESHOLD_OVERRIDE=""
QUIET=0

usage() {
    cat >&2 <<'USAGE'
Usage: judge-gate.sh --verdict <path> [options]

Options:
  --verdict <path>      Path to verdict.json (the judge's output).  [required]
  --calibration <path>  Path to calibration-set.json (hand-labeled truth).
                        Default: <script_dir>/calibration/calibration-set.json
  --report <path>       Path to write calibration-report.json on disk.
                        Default: alongside the verdict file.
  --conf <path>         Path to mutation.conf (read JUDGE_PRECISION_MIN).
                        Default: <script_dir>/mutation.conf
  --threshold <float>   Override JUDGE_PRECISION_MIN for this invocation.
  --quiet               Suppress the human-readable summary on stdout.
  --help / -h           Print this usage.

Exit codes:
  0   precision >= threshold (calibration passed)
  1   precision <  threshold (calibration failed)
  2   invocation / input error (missing file, malformed JSON, unknown ids)
  3   precision is undefined (zero genuine predictions from the judge)

See .claude/tests/mutation/README.md (judge-seam / calibration procedure)
for the full contract and the root-orchestrated invocation flow.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --verdict)     VERDICT_PATH="${2:-}"; shift 2 || true ;;
        --calibration) CALIBRATION_PATH="${2:-}"; shift 2 || true ;;
        --report)      REPORT_PATH="${2:-}"; shift 2 || true ;;
        --conf)        CONF_PATH="${2:-}"; shift 2 || true ;;
        --threshold)   THRESHOLD_OVERRIDE="${2:-}"; shift 2 || true ;;
        --quiet)       QUIET=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)
            printf 'judge-gate.sh: unknown arg: %s\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    printf 'judge-gate.sh: jq is required but not on PATH\n' >&2
    exit 2
fi

if [ -z "$VERDICT_PATH" ]; then
    printf 'judge-gate.sh: --verdict <path> is required\n' >&2
    usage
    exit 2
fi

if [ ! -f "$VERDICT_PATH" ]; then
    printf 'judge-gate.sh: verdict file does not exist: %s\n' "$VERDICT_PATH" >&2
    exit 2
fi

if [ ! -f "$CALIBRATION_PATH" ]; then
    printf 'judge-gate.sh: calibration file does not exist: %s\n' "$CALIBRATION_PATH" >&2
    exit 2
fi

# Resolve threshold. Precedence: --threshold > mutation.conf > built-in default.
THRESHOLD=""
if [ -n "$THRESHOLD_OVERRIDE" ]; then
    THRESHOLD="$THRESHOLD_OVERRIDE"
elif [ -f "$CONF_PATH" ]; then
    # mutation.conf is shell-sourceable; we grep the value instead of
    # sourcing it so we don't pollute this script's environment with
    # other config values (and so a malicious conf can't run arbitrary
    # code in this gate).
    THRESHOLD=$(grep -E '^JUDGE_PRECISION_MIN=' "$CONF_PATH" 2>/dev/null \
        | head -1 | cut -d= -f2 | tr -d '"[:space:]')
fi
THRESHOLD="${THRESHOLD:-0.8}"

# Resolve report path. Default: alongside the verdict file.
if [ -z "$REPORT_PATH" ]; then
    REPORT_PATH="$(dirname "$VERDICT_PATH")/calibration-report.json"
fi

# ---------------------------------------------------------------------------
# Validate inputs

# Verdict must be a JSON object with a `verdicts` array.
if ! jq -e 'type == "object" and (.verdicts | type) == "array"' \
        "$VERDICT_PATH" >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # literal backticks in human-readable message.
    printf 'judge-gate.sh: verdict file is not a JSON object with a `verdicts` array: %s\n' \
        "$VERDICT_PATH" >&2
    exit 2
fi

# Calibration must be a JSON object with a `calibration` array.
if ! jq -e 'type == "object" and (.calibration | type) == "array"' \
        "$CALIBRATION_PATH" >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # literal backticks in human-readable message.
    printf 'judge-gate.sh: calibration file is not a JSON object with a `calibration` array: %s\n' \
        "$CALIBRATION_PATH" >&2
    exit 2
fi

# Each verdict item must carry id (int) + classification ("equivalent" or
# "genuine"). We reject upfront so the precision/recall math never sees
# malformed input.
VERDICT_BAD=$(jq -r '
    .verdicts
    | map(
        if type != "object" then "item_not_object"
        elif (has("id") and (.id | type == "number")) | not then "missing_or_bad_id"
        elif (has("classification") and (.classification | type == "string")) | not then "missing_or_bad_classification"
        elif (.classification != "equivalent" and .classification != "genuine") then "classification_not_enum"
        else "ok"
        end
    )
    | map(select(. != "ok"))
    | .[0] // ""
' "$VERDICT_PATH" 2>/dev/null)
if [ -n "$VERDICT_BAD" ]; then
    printf 'judge-gate.sh: verdict file contains a malformed item: %s\n' "$VERDICT_BAD" >&2
    printf '  Each verdicts[] item must be {id:number, classification:"equivalent"|"genuine", ...}\n' >&2
    exit 2
fi

# Each calibration item must carry id (int) + ground_truth ("equivalent" or
# "genuine"). Same rejection: malformed truth data breaks the gate quietly
# otherwise.
CALIB_BAD=$(jq -r '
    .calibration
    | map(
        if type != "object" then "item_not_object"
        elif (has("id") and (.id | type == "number")) | not then "missing_or_bad_id"
        elif (has("ground_truth") and (.ground_truth | type == "string")) | not then "missing_or_bad_ground_truth"
        elif (.ground_truth != "equivalent" and .ground_truth != "genuine") then "ground_truth_not_enum"
        else "ok"
        end
    )
    | map(select(. != "ok"))
    | .[0] // ""
' "$CALIBRATION_PATH" 2>/dev/null)
if [ -n "$CALIB_BAD" ]; then
    printf 'judge-gate.sh: calibration file contains a malformed item: %s\n' "$CALIB_BAD" >&2
    printf '  Each calibration[] item must be {id:number, ground_truth:"equivalent"|"genuine", ...}\n' >&2
    exit 2
fi

# Set-equality check on the id sets. We refuse to silently skip mismatches
# — a missing or extra id is a sign the verdict was produced against a
# different calibration set or a corrupted run, and the gate must surface
# that rather than computing precision on a partial join.
ID_DIAG=$(jq -n \
    --slurpfile v "$VERDICT_PATH" \
    --slurpfile c "$CALIBRATION_PATH" \
    '
    ($v[0].verdicts | map(.id)) as $vids
    | ($c[0].calibration | map(.id)) as $cids
    | {
        verdict_extra: ($vids - $cids),
        calibration_unmatched: ($cids - $vids)
    }
    ')
EXTRA=$(printf '%s' "$ID_DIAG" | jq -r '.verdict_extra | length')
UNMATCHED=$(printf '%s' "$ID_DIAG" | jq -r '.calibration_unmatched | length')
if [ "$EXTRA" -ne 0 ] || [ "$UNMATCHED" -ne 0 ]; then
    printf 'judge-gate.sh: verdict / calibration id sets do not match.\n' >&2
    printf '  verdict ids absent from calibration:      %s\n' \
        "$(printf '%s' "$ID_DIAG" | jq -c '.verdict_extra')" >&2
    printf '  calibration ids absent from verdict:      %s\n' \
        "$(printf '%s' "$ID_DIAG" | jq -c '.calibration_unmatched')" >&2
    printf '  Re-run the judge against the matching calibration set, or update calibration-set.json.\n' >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Join + compute precision / recall.
#
# The join keys on .id; we already validated id-set equality, so every
# row matches exactly once. We compute the 2x2 confusion matrix:
#
#                          ground_truth
#                       genuine     equivalent
#   judge "genuine"        TP            FP
#   judge "equivalent"     FN            TN
#
# precision = TP / (TP + FP)   — fraction of judge's "genuine" calls that are truly genuine
# recall    = TP / (TP + FN)   — fraction of true genuine the judge caught

MATRIX_JSON=$(jq -n \
    --slurpfile v "$VERDICT_PATH" \
    --slurpfile c "$CALIBRATION_PATH" \
    '
    ($c[0].calibration | map({id, ground_truth, fault, target, line}))    as $truth
    | ($v[0].verdicts | map({id, classification, confidence: (.confidence // null), justification: (.justification // "")})) as $pred
    | ($truth | map({(.id|tostring): .}) | add) as $truth_by_id
    | ($pred  | map({(.id|tostring): .}) | add) as $pred_by_id
    | ([$truth_by_id, $pred_by_id] | add | keys_unsorted) as $all_keys
    | [
        $truth | map(
            . as $t
            | $pred_by_id[$t.id|tostring] as $p
            | {
                id: $t.id,
                fault: $t.fault,
                target: $t.target,
                line: $t.line,
                ground_truth: $t.ground_truth,
                classification: $p.classification,
                confidence: $p.confidence,
                justification: $p.justification,
                outcome:
                    (if $p.classification == "genuine" and $t.ground_truth == "genuine" then "TP"
                     elif $p.classification == "genuine" and $t.ground_truth == "equivalent" then "FP"
                     elif $p.classification == "equivalent" and $t.ground_truth == "genuine" then "FN"
                     else "TN" end)
            }
        )
    ] | first as $joined
    | ($joined | map(select(.outcome == "TP")) | length) as $tp
    | ($joined | map(select(.outcome == "FP")) | length) as $fp
    | ($joined | map(select(.outcome == "FN")) | length) as $fn
    | ($joined | map(select(.outcome == "TN")) | length) as $tn
    | {
        joined: $joined,
        confusion: { TP: $tp, FP: $fp, FN: $fn, TN: $tn },
        counts: {
            verdict_total: ($joined | length),
            judge_genuine: ($tp + $fp),
            judge_equivalent: ($tn + $fn),
            truth_genuine: ($tp + $fn),
            truth_equivalent: ($fp + $tn)
        }
    }
    ')

TP=$(printf '%s' "$MATRIX_JSON" | jq -r '.confusion.TP')
FP=$(printf '%s' "$MATRIX_JSON" | jq -r '.confusion.FP')
FN=$(printf '%s' "$MATRIX_JSON" | jq -r '.confusion.FN')
TN=$(printf '%s' "$MATRIX_JSON" | jq -r '.confusion.TN')

# Precision and recall — guarded for divide-by-zero.
# precision = TP / (TP + FP); undefined when TP+FP == 0 (judge made zero genuine predictions).
# recall    = TP / (TP + FN); undefined when TP+FN == 0 (no truly-genuine entries in calibration).
PRECISION=""
RECALL=""

JUDGE_GENUINE_TOTAL=$((TP + FP))
TRUTH_GENUINE_TOTAL=$((TP + FN))

# Use jq's native arithmetic for the divide (rather than awk's printf
# "%.4f") so the JSON report carries the canonical numeric form (e.g.,
# 0.75 not "0.7500"). The display summary still uses awk for the
# terminal-friendly fixed-4-digit rendering.
if [ "$JUDGE_GENUINE_TOTAL" -gt 0 ]; then
    PRECISION=$(jq -n --argjson t "$TP" --argjson g "$JUDGE_GENUINE_TOTAL" '$t / $g')
fi
if [ "$TRUTH_GENUINE_TOTAL" -gt 0 ]; then
    RECALL=$(jq -n --argjson t "$TP" --argjson g "$TRUTH_GENUINE_TOTAL" '$t / $g')
fi

# Decide pass/fail. Precision-only gate (per design bias precision >
# recall). Undefined precision is a separate exit code; a meaningful
# threshold compare requires a defined numerator.
GATE_VERDICT=""
EXIT_CODE=0
if [ -z "$PRECISION" ]; then
    GATE_VERDICT="undefined"
    EXIT_CODE=3
else
    PASSES=$(awk -v p="$PRECISION" -v t="$THRESHOLD" 'BEGIN { print (p + 0 >= t + 0) ? 1 : 0 }')
    if [ "$PASSES" = "1" ]; then
        GATE_VERDICT="passed"
        EXIT_CODE=0
    else
        GATE_VERDICT="failed"
        EXIT_CODE=1
    fi
fi

# ---------------------------------------------------------------------------
# Emit report.

# Build the structured report. We include the joined table verbatim so a
# C.3 consumer can read per-row outcomes without re-joining; we include the
# threshold + verdict so the audit trail records what the gate compared.
REPORT_JSON=$(jq -n \
    --argjson matrix "$MATRIX_JSON" \
    --argjson precision "${PRECISION:-null}" \
    --argjson recall    "${RECALL:-null}" \
    --arg threshold "$THRESHOLD" \
    --arg verdict   "$GATE_VERDICT" \
    --arg verdict_path "$VERDICT_PATH" \
    --arg calibration_path "$CALIBRATION_PATH" \
    '
    {
        contract_version: "1",
        verdict_path: $verdict_path,
        calibration_path: $calibration_path,
        threshold: ($threshold | tonumber),
        precision: $precision,
        recall:    $recall,
        gate_verdict: $verdict,
        confusion: $matrix.confusion,
        counts: $matrix.counts,
        per_mutant: $matrix.joined
    }
    ')

printf '%s\n' "$REPORT_JSON" > "$REPORT_PATH"

# Human-readable summary on stdout. The summary is what a developer sees
# in the terminal; the JSON report is the persisted audit trail.
if [ "$QUIET" -ne 1 ]; then
    {
        printf 'Calibration report (judge-gate.sh)\n'
        printf '  verdict file:        %s\n' "$VERDICT_PATH"
        printf '  calibration file:    %s\n' "$CALIBRATION_PATH"
        printf '  threshold:           %s (JUDGE_PRECISION_MIN)\n' "$THRESHOLD"
        printf '\n'
        printf '  confusion matrix:\n'
        printf '    TP (judge genuine, truth genuine):      %d\n' "$TP"
        printf '    FP (judge genuine, truth equivalent):   %d\n' "$FP"
        printf '    FN (judge equivalent, truth genuine):   %d\n' "$FN"
        printf '    TN (judge equivalent, truth equivalent):%d\n' "$TN"
        printf '\n'
        if [ -n "$PRECISION" ]; then
            # Render with 4-decimal precision for the terminal display only
            # (the JSON report carries the canonical numeric form).
            printf '  precision:           %s\n' \
                "$(awk -v p="$PRECISION" 'BEGIN { printf "%.4f", p + 0 }')"
        else
            printf '  precision:           undefined (judge made zero genuine predictions)\n'
        fi
        if [ -n "$RECALL" ]; then
            printf '  recall:              %s\n' \
                "$(awk -v r="$RECALL" 'BEGIN { printf "%.4f", r + 0 }')"
        else
            printf '  recall:              undefined (calibration has zero truly-genuine entries)\n'
        fi
        printf '\n'
        case "$GATE_VERDICT" in
            passed)   printf '  GATE VERDICT: PASSED (precision >= threshold)\n' ;;
            failed)   printf '  GATE VERDICT: FAILED (precision <  threshold)\n' ;;
            undefined)printf '  GATE VERDICT: UNDEFINED (precision is undefined; rerun the judge on a non-empty survivor set)\n' ;;
        esac
        printf '\n'
        printf '  report written:      %s\n' "$REPORT_PATH"
    }
fi

exit "$EXIT_CODE"

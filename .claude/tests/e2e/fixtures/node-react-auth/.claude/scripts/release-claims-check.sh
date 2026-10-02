#!/bin/bash
# release-claims-check.sh — claude-workflow-plugin-38cd (v5.0.0 finishing pass).
#
# WHY THIS EXISTS. Across QA rounds 2-5 of the v5.0.0 release text, the single
# dominant finding class was one shape: a correction landed on some surfaces and
# not all, so a figure or a verdict that had MOVED went on being asserted
# somewhere else. It happened four rounds running, and the fourth instance
# (R5-F1) was a live present-tense tally sentence that ONE COMMIT updated for
# `DP4`'s verdict move and left stale for `DP9`'s. The lesson was written into
# LESSONS.md after round 3 and the failure recurred twice more, which is the
# whole argument for this file: a rule an author must remember is not a control.
# This turns "sweep every surface for the proposition" into a mechanism.
#
# WHAT IT CHECKS, deliberately narrow (the operator's scope: "the tally sequence
# and verdicts cited by row id, no prose parsing beyond that"):
#
#   1. TABLE     — the tally table's per-status counts equal the counts derived
#                  from the ledger's own rows.
#   2. TOKENS    — every tally-shaped token (`A / B / C / D` or `A / B / C / D /
#                  E`) on any surface equals the derived tally, unless exempt.
#   3. CITATIONS — every line that names a row id AND a verdict word agrees with
#                  that row's actual verdict.
#
# THE LEDGER'S OWN ROWS ARE THE AUTHORITY. Everything else -- the tally table,
# ledger prose, CHANGELOG, README, the announcement draft -- is a restatement,
# and a restatement that disagrees is what this refuses. The rows are read from
# the LAST `## vX.Y.Z claims ledger` section, because earlier sections are
# frozen prior releases whose (correct) tallies must not be compared against
# the current one.
#
# EXEMPTIONS, both explicit and both machine-readable. Historical figures are
# legitimate and this file must not force them to be deleted:
#
#   <!-- TALLY-HISTORY BEGIN -->  …  <!-- TALLY-HISTORY END -->
#       A block whose tally tokens are a RECORD OF MOVEMENT, not a claim about
#       the present. Movement histories and superseded paragraphs live here.
#
#   <token><!-- tally-xref -->
#       An inline cross-reference to ANOTHER release's tally.
#
#       IT EXEMPTS THE WHOLE LINE, NOT JUST THE CROSS-REFERENCED TOKEN. Put a
#       live figure on the same line as this marker and the live figure stops
#       being checked, silently, with the run still reporting "OK: every
#       surface agrees". So: keep a cross-reference on its own line, and never
#       add this marker to a line that also states the current tally.
#
#       (An earlier version of this comment claimed the opposite -- that a line
#       could carry both and still be checked for the live one -- and then, in
#       the same sentence, said the marker exempts the LINE. The first half was
#       false and measurably so. It is corrected here rather than quietly
#       replaced because an author who trusted it would lose coverage on
#       exactly the defect class this file exists to catch.)
#
# A stale figure inside a history block is not a defect; a stale figure outside
# one is exactly R5-F1.
#
# Usage:
#   release-claims-check.sh [--ledger <path>] [--surface <path>]... [--json]
#
#   --ledger   the claims ledger (default: docs/RELEASE_AUDIT.md). Also checked
#              as a surface -- its own prose restates its own table.
#   --surface  an additional file to check (repeatable). Missing files are
#              reported and are an error: a surface that silently vanished is
#              how a check stops checking.
#   --json     one-line JSON envelope instead of human output.
#
# Exit: 0 all surfaces agree · 1 at least one disagreement · 2 usage/infra.
#
# BOTH CHECKERS TAKE A FILE so release-claims-check.test.sh can drive fixture
# copies with a seeded stale tally and a seeded stale verdict through
# byte-identical logic -- the assertion and its sensitivity proof are the same
# code path, which is the pairing requirement's leg 4 (.claude/tests/README.md).

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

LEDGER=""
SURFACES=()
JSON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ledger)  LEDGER="${2:-}"; shift 2 ;;
        --surface) SURFACES+=("${2:-}"); shift 2 ;;
        --json)    JSON=1; shift ;;
        -h|--help)
            # Print the header comment and STOP AT THE FIRST CODE LINE, rather
            # than a fixed line count. The fixed count was `1,60p`, tuned when
            # the header ended at :58; the R6-F2 correction grew the header by
            # nine lines and `--help` silently began truncating mid-sentence,
            # dropping the --surface semantics, --json, and the exit contract.
            # A magic number here is a second thing to keep in step with the
            # header, and the whole point of this file is that things kept in
            # step by hand drift. Self-adjusting means it cannot recur.
            awk 'NR == 1 { next }
                 /^#/    { sub(/^# ?/, ""); print; next }
                 /^$/    { print; next }
                          { exit }' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) printf 'release-claims-check.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "$LEDGER" ] || LEDGER="$PROJECT_DIR/docs/RELEASE_AUDIT.md"

if [ ! -f "$LEDGER" ]; then
    printf 'release-claims-check.sh: ledger not found: %s\n' "$LEDGER" >&2
    exit 2
fi

# The four statuses are matched LONGEST FIRST wherever they are matched below
# (see check_citations' alternation order and its last-wins scan). PROVEN is a
# prefix of PROVEN-WITH-CAVEAT, so a shortest-first match would classify every
# caveated row as PROVEN and the tally would be wrong in the FLATTERING
# direction -- the exact error class this file exists to catch.

FAILURES=()

# ---------------------------------------------------------------------------
# ledger_rows <file> — emit "<row-id> <verdict>" for the LAST claims-ledger
# section. A row is `| DP<n> | … | <VERDICT> |` on one line; the verdict is the
# final pipe-delimited cell.
ledger_rows() {
    local f="$1"
    awk '
        /^## v[0-9]+\.[0-9]+\.[0-9]+ claims ledger/ { start = NR }
        { line[NR] = $0 }
        END {
            if (start == 0) exit 0
            for (i = start; i <= NR; i++) print line[i]
        }
    ' "$f" | awk -F'|' '
        /^\| *[A-Z]+[0-9]+ *\|/ {
            id = $2; gsub(/^ +| +$/, "", id)
            v  = $(NF-1); gsub(/^ +| +$/, "", v)
            if (v ~ /^(PROVEN|PROVEN-WITH-CAVEAT|NOT-PROVEN|REMOVED)$/) print id, v
        }
    '
}

# compute_tally <file> — "<proven> <caveat> <notproven> <removed> <total>"
compute_tally() {
    local f="$1"
    ledger_rows "$f" | awk '
        { c[$2]++; n++ }
        END {
            printf "%d %d %d %d %d\n",
                c["PROVEN"]+0, c["PROVEN-WITH-CAVEAT"]+0,
                c["NOT-PROVEN"]+0, c["REMOVED"]+0, n+0
        }
    '
}

# strip_exempt <file> [current-section-only] — emit "<lineno>:<text>" for lines
# OUTSIDE history blocks and without an inline xref marker. Line-granular on
# purpose: a tally token and its exemption marker are authored together on one
# line, and a sub-line span would mean parsing prose, which this file does not
# do.
#
# With a non-empty second argument, emit only lines from the LAST
# `## vX.Y.Z claims ledger` heading onward. Prior sections are FROZEN releases
# whose own (correct) tallies would otherwise be compared against the current
# one -- the first run of this checker reported eleven such false positives,
# including v4.0.0's `51 / 47 / 0 / 23` and v4.1.0's `13 / 3 / 0 / 0 / 16`.
strip_exempt() {
    local f="$1" current_only="${2:-}"
    awk -v cur="$current_only" '
        cur != "" && /^## v[0-9]+\.[0-9]+\.[0-9]+ claims ledger/ { start = NR }
        { line[NR] = $0 }
        END {
            from = (cur != "" && start > 0) ? start : 1
            for (i = from; i <= NR; i++) {
                if (line[i] ~ /<!-- *TALLY-HISTORY +BEGIN *-->/) { hist = 1; continue }
                if (line[i] ~ /<!-- *TALLY-HISTORY +END *-->/)   { hist = 0; continue }
                if (hist) continue
                if (line[i] ~ /<!-- *tally-xref *-->/) continue
                printf "%d:%s\n", i, line[i]
            }
        }
    ' "$f"
}

# ---------------------------------------------------------------------------
# CHECK 1 — the tally table's counts equal the derived counts.
check_table() {
    local f="$1" p="$2" c="$3" n="$4" r="$5"
    local want got status
    for status in "PROVEN-WITH-CAVEAT" "NOT-PROVEN" "REMOVED" "PROVEN"; do
        case "$status" in
            PROVEN)             want="$p" ;;
            PROVEN-WITH-CAVEAT) want="$c" ;;
            NOT-PROVEN)         want="$n" ;;
            REMOVED)            want="$r" ;;
        esac
        # The LAST such table row in the file is the current section's.
        got=$(grep -oE "^\| *${status} *\| *[0-9]+ *\|" "$f" | tail -1 \
              | grep -oE '[0-9]+' | tail -1)
        [ -n "$got" ] || continue
        if [ "$got" != "$want" ]; then
            FAILURES+=("TABLE: tally table says ${status}=${got}, ledger rows give ${want} ($f)")
        fi
    done
}

# CHECK 2 — every non-exempt tally token equals the derived tally.
#
# A TALLY TOKEN IS THE FIVE-GROUP FORM ONLY (`P / C / N / R / T`). The
# four-group form is not distinguishable from ordinary slash-separated numbers
# in this corpus -- the first run matched exit-code lists (`0/1/2/3`), doctor
# check ranges (`0/20/21/22`) and task-id runs (`llh.18/19/20/21`), none of
# which are tallies. Five groups with a trailing total is the canonical shape
# every real tally in these documents uses, so the narrow pattern loses nothing
# and the broad one was mostly noise. Where a live sentence used the four-group
# form it was normalised to carry its total, rather than widening the pattern.
#
# ONE awk PASS PER FILE, not a grep per line. The first working version spawned
# two subprocesses for each of ~6,500 lines across four surfaces and took long
# enough to trip a 400s command bound -- a check nobody will wait for is a check
# that gets disabled.
check_tokens() {
    local f="$1" p="$2" c="$3" n="$4" r="$5" t="$6" scope="$7"
    local base; base=$(basename "$f")
    local out
    out=$(strip_exempt "$f" "$scope" | awk -v want="${p}/${c}/${n}/${r}/${t}" -v base="$base" -v pretty="${p} / ${c} / ${n} / ${r} / ${t}" '
        {
            lineno = $0; sub(/:.*/, "", lineno)
            text   = $0; sub(/^[0-9]+:/, "", text)
            rest = text
            while (match(rest, /[0-9]+ ?\/ ?[0-9]+ ?\/ ?[0-9]+ ?\/ ?[0-9]+ ?\/ ?[0-9]+/)) {
                tok = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                norm = tok; gsub(/ /, "", norm)
                if (norm != want)
                    printf "TOKEN: %s:%s states '"'"'%s'"'"', ledger rows give '"'"'%s'"'"'\n", base, lineno, tok, pretty
            }
        }
    ')
    [ -z "$out" ] || while IFS= read -r m; do FAILURES+=("$m"); done <<<"$out"
}

# CHECK 3 — every ADJACENT row-id/verdict citation agrees with that row.
#
# THE TIGHT FORM ONLY: `` `DPn`, VERDICT `` -- the row id in backticks, an
# optional comma, an optional copula, then the verdict, with nothing else
# between. That is the form a cross-reference actually takes in these documents
# ("(`DP4`, PROVEN-WITH-CAVEAT as of 2026-09-30)"), and restricting to it is
# what keeps this a citation check rather than a prose parser.
#
# WHY NOT "a row id and a verdict anywhere on the same line": the first run of
# this checker raised nine such hits and every one was legitimate history --
# "`DP5` WAS NOT-PROVEN and always had been", "`DP17` was withdrawn ... to reach
# zero NOT-PROVEN", and movement statements of the form "PROVEN -> PROVEN-WITH-
# CAVEAT" whose left side is the OLD verdict by construction. A check that fires
# on correct prose trains its reader to ignore it, which is worse than no check.
#
# The ledger's own rows are skipped: they ARE the authority, not a restatement.
check_citations() {
    local f="$1" rowsfile="$2" scope="$3"
    local base; base=$(basename "$f")
    local out
    out=$(strip_exempt "$f" "$scope" | awk -v base="$base" -v rowsfile="$rowsfile" '
        BEGIN {
            while ((getline ln < rowsfile) > 0) {
                split(ln, a, " ")
                if (a[1] != "") actual[a[1]] = a[2]
            }
            close(rowsfile)
        }
        {
            lineno = $0; sub(/:.*/, "", lineno)
            text   = $0; sub(/^[0-9]+:/, "", text)
            if (text ~ /^\| [A-Z]+[0-9]+ \|/) next   # a ledger row: the authority
            rest = text
            # The optional `-> VERDICT` tail makes a MOVEMENT STATEMENT parse
            # correctly. "`DP3` PROVEN -> PROVEN-WITH-CAVEAT" cites the row as
            # its NEW verdict; the left side is the OLD one by construction, and
            # reading it raised a false positive on a correct sentence.
            # The separator is "any 1-4 non-alphanumerics" rather than a literal
            # arrow: the documents use U+2192, and a \342\206\222 octal escape in
            # a regex literal is not portable across the awks this repo runs on
            # (it silently failed to match on the BSD awk of the dev host, which
            # is indistinguishable from "no movement statements present").
            while (match(rest, /`DP[0-9]+`,? +(is +|was +|now +|remains +)?(PROVEN-WITH-CAVEAT|NOT-PROVEN|REMOVED|PROVEN)( *[^A-Za-z0-9]{1,4} *(PROVEN-WITH-CAVEAT|NOT-PROVEN|REMOVED|PROVEN))?/)) {
                hit  = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                id = hit; sub(/^`/, "", id); sub(/`.*/, "", id)
                # LAST verdict in the hit wins -- see the movement note above.
                cited = ""; scan = hit
                while (match(scan, /PROVEN-WITH-CAVEAT|NOT-PROVEN|REMOVED|PROVEN/)) {
                    cited = substr(scan, RSTART, RLENGTH)
                    scan  = substr(scan, RSTART + RLENGTH)
                }
                if (id in actual && cited != "" && cited != actual[id])
                    printf "CITATION: %s:%s cites %s as %s, ledger row says %s\n", base, lineno, id, cited, actual[id]
            }
        }
    ')
    [ -z "$out" ] || while IFS= read -r m; do FAILURES+=("$m"); done <<<"$out"
}

# ---------------------------------------------------------------------------
read -r P C N R T <<<"$(compute_tally "$LEDGER")"

if [ "${T:-0}" -eq 0 ]; then
    printf 'release-claims-check.sh: no claims-ledger rows found in %s\n' "$LEDGER" >&2
    exit 2
fi

ROWS_TMP=$(mktemp) || exit 2
trap 'rm -f "$ROWS_TMP"' EXIT
ledger_rows "$LEDGER" > "$ROWS_TMP"

ALL=("$LEDGER")
for s in ${SURFACES+"${SURFACES[@]}"}; do
    if [ ! -f "$s" ]; then
        FAILURES+=("SURFACE: named surface does not exist: $s")
        continue
    fi
    ALL+=("$s")
done

# The LEDGER is scanned from its current section only; every other surface is
# scanned whole, because a surface that carries no frozen prior-release ledger
# has no legitimate reason to state a different tally anywhere in it.
check_table "$LEDGER" "$P" "$C" "$N" "$R"
for f in "${ALL[@]}"; do
    if [ "$f" = "$LEDGER" ]; then scope="current"; else scope=""; fi
    check_tokens "$f" "$P" "$C" "$N" "$R" "$T" "$scope"
    check_citations "$f" "$ROWS_TMP" "$scope"
done

if [ "$JSON" -eq 1 ]; then
    printf '{"ok":%s,"tally":{"proven":%d,"proven_with_caveat":%d,"not_proven":%d,"removed":%d,"total":%d},"surfaces":%d,"failures":[' \
        "$([ ${#FAILURES[@]} -eq 0 ] && echo true || echo false)" \
        "$P" "$C" "$N" "$R" "$T" "${#ALL[@]}"
    first=1
    for m in ${FAILURES+"${FAILURES[@]}"}; do
        [ $first -eq 1 ] || printf ','
        printf '%s' "$(printf '%s' "$m" | jq -Rs . 2>/dev/null || printf '"%s"' "$m")"
        first=0
    done
    printf ']}\n'
else
    printf 'release-claims-check: ledger rows give %d PROVEN / %d PROVEN-WITH-CAVEAT / %d NOT-PROVEN / %d REMOVED / %d total\n' \
        "$P" "$C" "$N" "$R" "$T"
    printf 'checked %d surface(s)\n' "${#ALL[@]}"
    if [ ${#FAILURES[@]} -eq 0 ]; then
        printf 'OK: every surface agrees with the ledger rows.\n'
    else
        printf '\n%d DISAGREEMENT(S):\n' "${#FAILURES[@]}"
        for m in "${FAILURES[@]}"; do printf '  %s\n' "$m"; done
        printf '\nThe ledger ROWS are the authority. Fix the restatement, not the rows --\n'
        printf 'unless a row verdict genuinely moved, in which case re-run every surface.\n'
        printf 'A legitimately historical figure belongs inside a TALLY-HISTORY block,\n'
        printf 'and a reference to another release'"'"'s tally takes an inline tally-xref marker.\n'
    fi
fi

[ ${#FAILURES[@]} -eq 0 ] || exit 1
exit 0

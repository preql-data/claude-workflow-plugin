#!/bin/bash
# release-claims-check.test.sh — claude-workflow-plugin-38cd (v5.0.0 finishing
# pass). L1 spec for .claude/scripts/release-claims-check.sh.
#
# WHAT THE GUARD IS FOR. Rounds 2-5 of the v5.0.0 release-text review produced
# one dominant finding class: a figure or verdict that had MOVED went on being
# asserted on a surface nobody re-swept. Four rounds running. The fourth
# instance landed AFTER the lesson describing it was written into LESSONS.md,
# in the same commit that added it -- which is the argument for a mechanism
# rather than a rule: one commit updated a live tally sentence for `DP4`'s
# verdict move and left it stale for `DP9`'s.
#
# PAIRING (.claude/tests/README.md "The pairing requirement"). This spec is the
# negative control for that guard, and it reaches leg 4 -- the one the census
# found document checks never reach -- because THE ARTIFACT UNDER TEST IS AN
# EXECUTABLE. Every assertion below drives the shipped release-claims-check.sh;
# none of them compares markdown bytes.
#
#   Leg 1 non-vacuity    each mutation is proved to have landed, by diffing the
#                        fixture against its source and refusing to proceed if
#                        the substitution matched nothing (a sed that changed
#                        nothing yields a "mutant" identical to the original,
#                        and a control over an unmutated artifact passes for
#                        the wrong reason).
#   Leg 2 misbehaviour   the mutant is asserted to fail IN THE WAY THE GUARD
#                        PREVENTS, by error class (TOKEN: / CITATION:), not
#                        merely to exit non-zero.
#   Leg 3 restore        the unmutated ledger, same call shape, exits 0.
#   Leg 4 execution      all of the above run the shipped script.
#
# Section 4 is the control ON THE EXEMPTION. A history-block escape hatch that
# nothing tests is a way to silence the guard by wrapping the whole file, so
# there is an assertion that the SAME stale token fires outside a block and is
# exempt inside one. Without it the exemption is an unchecked bypass, which is
# the defect family this release exists to refuse.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CHECKER="$PROJECT_DIR/.claude/scripts/release-claims-check.sh"
LEDGER="$PROJECT_DIR/docs/RELEASE_AUDIT.md"

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
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*)
            PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name" ;;
        *)
            FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
            printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' \
                "$name" "$needle" "${hay:0:400}" ;;
    esac
}

# mutate <src> <dst> <sed-expr> <label> — apply the mutation and PROVE it landed.
# Leg 1: a mutation that matched nothing is the classic false pair, so this
# refuses (exit 7, mirroring approve-idempotency.sh F3's convention) rather than
# quietly producing a mutant identical to the original.
mutate() {
    local src="$1" dst="$2" expr="$3" label="$4"
    sed "$expr" "$src" > "$dst"
    if cmp -s "$src" "$dst"; then
        printf '  FATAL: mutation did not land (%s) — the fixture is identical to the source.\n' "$label" >&2
        printf '         A control over an unmutated artifact passes for the wrong reason.\n' >&2
        exit 7
    fi
}

TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT

printf '=== release-claims-check.test.sh ===\n'

# --- 0. Preconditions ----------------------------------------------------
printf '\n[0] preconditions\n'
[ -x "$CHECKER" ] || chmod +x "$CHECKER" 2>/dev/null
assert_eq "checker exists" "yes" "$([ -f "$CHECKER" ] && echo yes || echo no)"
assert_eq "checker is syntactically valid" "0" \
    "$(bash -n "$CHECKER" >/dev/null 2>&1; echo $?)"
assert_eq "ledger exists" "yes" "$([ -f "$LEDGER" ] && echo yes || echo no)"

# --- 1. Leg 3: restore control ------------------------------------------
# The shipped ledger and the shipped release surfaces agree. This is also the
# assertion that keeps the release text honest on every future run.
printf '\n[1] restore control — shipped tree is consistent\n'
out_clean=$(bash "$CHECKER" --ledger "$LEDGER" \
    --surface "$PROJECT_DIR/CHANGELOG.md" \
    --surface "$PROJECT_DIR/README.md" 2>&1)
rc_clean=$?
assert_eq "shipped surfaces agree with the ledger rows (rc)" "0" "$rc_clean"
assert_contains "clean run says so explicitly" "OK: every surface agrees" "$out_clean"

# The derived tally is reported, so a reader of CI output can see the number the
# whole release decision is read off without opening the ledger.
assert_contains "clean run reports the derived tally" "ledger rows give" "$out_clean"

# --- 2. Seeded STALE TALLY ----------------------------------------------
# This is R5-F1 reproduced exactly: a live, present-tense tally sentence left
# behind after a verdict moved. The mutation transposes the first two counts,
# which is precisely the shape the real defect took (9/8 left standing where the
# rows had become 8/9).
printf '\n[2] seeded stale tally — the R5-F1 shape\n'
read -r P C N R T <<<"$(
    awk '/^## v[0-9]+\.[0-9]+\.[0-9]+ claims ledger/ { s = NR } { l[NR] = $0 }
         END { for (i = s; i <= NR; i++) print l[i] }' "$LEDGER" \
    | awk -F'|' '/^\| *[A-Z]+[0-9]+ *\|/ {
          v = $(NF-1); gsub(/^ +| +$/, "", v)
          if (v ~ /^(PROVEN|PROVEN-WITH-CAVEAT|NOT-PROVEN|REMOVED)$/) c[v]++
          n++
      } END { printf "%d %d %d %d %d\n", c["PROVEN"]+0, c["PROVEN-WITH-CAVEAT"]+0, c["NOT-PROVEN"]+0, c["REMOVED"]+0, n+0 }'
)"
assert_eq "derived tally is internally consistent (P+C+N+R == total)" \
    "$T" "$(( P + C + N + R ))"

STALE_TALLY="$TMP/ledger-stale-tally.md"
mutate "$LEDGER" "$STALE_TALLY" \
    "s#THE CURRENT STATEMENT: the split is \`${P} / ${C} / ${N} / ${R} / ${T}\`#THE CURRENT STATEMENT: the split is \`${C} / ${P} / ${N} / ${R} / ${T}\`#" \
    "stale tally"

out_tally=$(bash "$CHECKER" --ledger "$STALE_TALLY" 2>&1)
rc_tally=$?
assert_eq "stale tally FAILS (rc)" "1" "$rc_tally"
assert_contains "stale tally fails as a TOKEN disagreement" "TOKEN:" "$out_tally"
assert_contains "the failure names the stale figure" "${C} / ${P} / ${N} / ${R} / ${T}" "$out_tally"
assert_contains "the failure names the authoritative figure" \
    "ledger rows give '${P} / ${C} / ${N} / ${R} / ${T}'" "$out_tally"

# --- 3. Seeded STALE VERDICT --------------------------------------------
# A cross-reference that cites a row's OLD verdict after the row moved. Seeded
# on DP4, which the release text cites by id in the tight `(`DPn`, VERDICT)`
# form the checker recognises.
printf '\n[3] seeded stale verdict — a citation left behind\n'
STALE_VERDICT="$TMP/ledger-stale-verdict.md"
# shellcheck disable=SC2016  # single quotes are required: the sed expression
# contains backticks, which must reach sed literally rather than being run as
# command substitution by the shell.
mutate "$LEDGER" "$STALE_VERDICT" \
    's#(`DP4`, PROVEN-WITH-CAVEAT#(`DP4`, PROVEN#' \
    "stale verdict"

out_verdict=$(bash "$CHECKER" --ledger "$STALE_VERDICT" 2>&1)
rc_verdict=$?
assert_eq "stale verdict FAILS (rc)" "1" "$rc_verdict"
assert_contains "stale verdict fails as a CITATION disagreement" "CITATION:" "$out_verdict"
assert_contains "the failure names the row" "DP4" "$out_verdict"
assert_contains "the failure names the true verdict" \
    "ledger row says PROVEN-WITH-CAVEAT" "$out_verdict"

# --- 4. Control ON THE EXEMPTION ----------------------------------------
# The history block must exempt a stale figure, and must NOT be a way to silence
# the guard generally. Same stale token, two placements, opposite outcomes.
printf '\n[4] the exemption is scoped, not a blanket off-switch\n'
EXEMPT_OK="$TMP/ledger-exempt.md"
mutate "$LEDGER" "$EXEMPT_OK" \
    "s#THE CURRENT STATEMENT: the split is \`${P} / ${C} / ${N} / ${R} / ${T}\`#<!-- TALLY-HISTORY BEGIN -->\nOnce upon a time the split was \`${C} / ${P} / ${N} / ${R} / ${T}\`.\n<!-- TALLY-HISTORY END -->\nTHE CURRENT STATEMENT: the split is \`${P} / ${C} / ${N} / ${R} / ${T}\`#" \
    "wrapped historical figure"

out_exempt=$(bash "$CHECKER" --ledger "$EXEMPT_OK" 2>&1)
rc_exempt=$?
assert_eq "a stale figure INSIDE a history block is exempt (rc)" "0" "$rc_exempt"
assert_contains "the exempt run reports a clean sweep, not a suppressed one" \
    "OK: every surface agrees" "$out_exempt"

# ...and the identical token outside one still fires. Section 2 already proved
# that, so this asserts the PAIR rather than re-deriving it: same token, exempt
# in 4, fatal in 2.
assert_eq "the SAME token outside a block is fatal (section 2 rc)" "1" "$rc_tally"

# --- 5. A missing surface is an error, not a silent skip -----------------
# A surface that vanished is how a sweep stops sweeping while still exiting 0.
printf '\n[5] a named surface that does not exist is an error\n'
out_missing=$(bash "$CHECKER" --ledger "$LEDGER" --surface "$TMP/does-not-exist.md" 2>&1)
rc_missing=$?
assert_eq "missing surface FAILS (rc)" "1" "$rc_missing"
assert_contains "missing surface is named" "SURFACE:" "$out_missing"

# --- 6. JSON envelope ----------------------------------------------------
printf '\n[6] --json envelope\n'
out_json=$(bash "$CHECKER" --ledger "$LEDGER" --json 2>&1)
assert_eq "json is parseable" "0" "$(printf '%s' "$out_json" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "json reports ok:true on the shipped ledger" "true" \
    "$(printf '%s' "$out_json" | jq -r '.ok')"
assert_eq "json carries the derived total" "$T" \
    "$(printf '%s' "$out_json" | jq -r '.tally.total')"

# --- 7. --help renders through the exit contract --------------------------
# R7-F1: the help window was `sed -n '1,60p'`, tuned when the header ended at
# :58. A later correction grew the header by nine lines and --help began
# truncating mid-sentence, dropping the --surface semantics, the --json
# description and the exit contract -- silently, with rc=0. Nothing asserted on
# the help contract, so nothing caught it. These assertions are that contract.
#
# WHAT THEY DO AND DO NOT COVER, stated precisely because an earlier version of
# this paragraph overstated it (QA round 8, R8-F1/R8-F2). Four of the five
# strings below sit at header lines 62-67 and DO fail under the truncation this
# section is named for -- each was verified individually against a rebuilt
# pre-fix copy, not in aggregate. The fifth (`IT EXEMPTS THE WHOLE LINE`, header
# line 41) SURVIVES that truncation and is not a control for it; it guards a
# different property -- that the R6-F2 correction still reaches a reader at all.
#
# THE RESIDUAL, NOT CLOSED HERE: because the highest pinned string is at :67,
# this section detects truncation that REACHES :67 and not growth PAST it. A
# window ending anywhere from :67 to the header's last line leaves every
# assertion in this section green while the closing paragraph is cut. Closing
# that needs an assertion derived from the header's actual last line rather than
# from a pinned string; an attempt at one was removed here because it read the
# script's SOURCE and never ran --help, passing even when --help emitted zero
# bytes -- the false-pair shape .claude/tests/README.md describes. Tracked in
# claude-workflow-plugin-8bbw.
#
# NO ASSERTION COUNT IS STATED ABOVE, deliberately. An earlier version of this
# paragraph said "all seven green"; the remedy that produced it deleted one
# assertion, leaving six, and the stale figure survived into the very paragraph
# that opens by claiming to state things precisely (QA round 9, R9-F1). A count
# here is derivable from the code six lines below and has to be kept in step by
# hand, which is the drift this whole file exists to catch. So it is not stated.
printf '\n[7] --help renders through the exit contract\n'
out_help=$(bash "$CHECKER" --help 2>&1)
rc_help=$?
assert_eq "--help exits 0" "0" "$rc_help"
# Matched on a single line: the sentence wraps in the header, so a phrase
# spanning the break never appears contiguously in the rendered output.
assert_contains "--help documents --surface" \
    "an additional file to check (repeatable)" "$out_help"
assert_contains "--help says a missing surface is an error" \
    "a surface that silently vanished" "$out_help"
assert_contains "--help documents --json" "one-line JSON envelope" "$out_help"
assert_contains "--help carries the exit contract (the HIGHEST line this section pins)" \
    "Exit: 0 all surfaces agree" "$out_help"
assert_contains "--help carries the tally-xref line-granularity warning (R6-F2)" \
    "IT EXEMPTS THE WHOLE LINE" "$out_help"

# --- Summary -------------------------------------------------------------
if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

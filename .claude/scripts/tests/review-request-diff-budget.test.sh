#!/bin/bash
# review-request-diff-budget.test.sh — claude-workflow-plugin-wuu8 R1-F4,
# found on claude-workflow-plugin-gytz QA round 1: a REAL packet (not a
# synthetic one) measured 286,308 bytes against a 100,000-byte cap, with
# diff_bytes=225,929-226,467 alone already 2.26x the cap — the impact-report
# fix (wuu8, this same task) had taken THAT field from 98.5% of an earlier
# packet down to 0.5% of this one, and the uncapped diff simply became the
# next thing to dominate once it stopped being hidden.
#
# THE FIX under test: review_request_diff_text now takes an explicit byte
# budget and, when the real diff exceeds it, makes a DISCLOSED, whole-file
# choice about what to include — never a mid-file truncation, which would
# show a reviewer an incomplete hunk with no marker that anything followed
# it. Files are classified into three priority tiers (review_request_diff_
# tier) and considered smallest-first within a tier so more COMPLETE files
# fit inside the budget. Every omission is named in the rendered `.diff`
# text itself (path + byte count + tier), and a packet that was NOT cut
# carries a distinct, equally explicit "DIFF COMPLETE" statement — so
# "this diff is complete" and "this diff was cut, and by how much" are both
# stated in-band, never left to a log a reviewer never sees.
#
# PAIRING (`.claude/tests/README.md`): every section below is a mutation or
# a real-vs-synthetic contrast, non-vacuity-checked, naming the specific
# misbehaviour it prevents, with at least one leg driving the real, shipped
# `qa-gate.sh review-request-build` as a subprocess. Section B extracts
# `review_request_diff_tier` from the SHIPPED script by awk (the same
# technique `doc-only-classifier.test.sh` already uses for `is_doc_only_
# path`), so the classifier under test is the shipped definition, never a
# re-typed copy free to drift. Section F is the coordinator's own named
# META-TEST.
#
# Exit codes: 0 all assertions passed | 1 one or more failed | 2 harness error.

set -u
trap '' PIPE

PASS=0
FAIL=0
FAILED_TESTS=()
KEEP_FIXTURE="${KEEP_FIXTURE:-0}"
[ "${1:-}" = "--keep" ] && KEEP_FIXTURE=1

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' "$name" "$needle" "$haystack"
    fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle (should be ABSENT): %s\n' "$name" "$needle"
    else
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    fi
}
assert_le() {
    local name="$1" a="$2" b="$3"
    if [ "$a" -le "$b" ] 2>/dev/null; then
        PASS=$((PASS + 1)); printf '  PASS: %s (%s <= %s)\n' "$name" "$a" "$b"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected %s <= %s\n' "$name" "$a" "$b"
    fi
}
assert_ne() {
    local name="$1" not_expected="$2" actual="$3"
    if [ "$not_expected" != "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    not-expected: %s\n    actual:       %s\n' "$name" "$not_expected" "$actual"
    fi
}

# ---------------------------------------------------------------------------
# Fixture -- same conventions as review-request-build.test.sh (mktemp, never
# under the harness's own /tmp/claude-<session>/ scratchpad, which is itself
# denylisted and would silently empty every "changed" file in the fixture).

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t review-request-diff-budget.XXXXXX)
TEST_HOME=$(mktemp -d -t review-request-diff-budget-home.XXXXXX)

# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\nTest HOME: %s\n' "$FIXTURE" "$TEST_HOME"
    else
        chmod -R u+rwX "$FIXTURE" 2>/dev/null || true
        rm -rf "$FIXTURE" "$TEST_HOME"
    fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" "$FIXTURE/.beads" \
    "$FIXTURE/bin" "$FIXTURE/src" "$FIXTURE/.claude/agents" "$FIXTURE/docs" \
    "$TEST_HOME/.claude/projects"

cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

if ! command -v bd >/dev/null 2>&1; then echo "bd CLI not on PATH"; exit 2; fi
if ! command -v jq >/dev/null 2>&1; then echo "jq not on PATH"; exit 2; fi
if ! command -v git >/dev/null 2>&1; then echo "git not on PATH"; exit 2; fi

REAL_BD=$(command -v bd)
cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"
export PATH="$FIXTURE/bin:$PATH"

( cd "$FIXTURE" && git init -q && git config user.email t@t.com && git config user.name t )
cd "$FIXTURE" && bd init >/dev/null 2>&1
export CLAUDE_PROJECT_DIR="$FIXTURE"
export HOME="$TEST_HOME"

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
SPEC_FILE="$FIXTURE/.claude/.qa-tracking/.rrdb-spec.txt"
printf 'SPEC: review-request-diff-budget.test.sh fixture spec.\n' > "$SPEC_FILE"

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }
new_task() { bd create "$1" -t task --json 2>/dev/null | jq -r '.id // .issue.id // empty'; }
seed_completion() {
    local tid="$1" files_json="$2"
    bd comments add "$tid" "IMPLEMENTER: role=devops task=$tid at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
    local payload="$FIXTURE/.claude/.qa-tracking/.rrdb-completion-$$-$RANDOM.json"
    jq -n --arg tid "$tid" --argjson files "$files_json" '
        {task_id:$tid, files_changed:$files, tests_added:["t"], decisions:["d"],
         blockers:[], llm_observations:"seeded", context_coverage:"seeded",
         role:"devops", model:"m", pin:"m", unit_id:"", design_hash:"",
         green_before:"none", green_after:"none", criteria_tests:{}}
    ' > "$payload"
    bash "$QG" completion-record "$tid" --file "$payload" >/dev/null 2>&1
    rm -f "$payload" 2>/dev/null || true
}
set_tracker() {
    local TRACKING="$FIXTURE/.claude/.qa-tracking/changed-files.txt"
    : > "$TRACKING"
    local f
    for f in "$@"; do printf '%s\n' "$f" >> "$TRACKING"; done
}
# repeat_line <n> <text> -- n copies of text, one per line, for building a
# large-but-controlled synthetic file body.
repeat_line() {
    local n="$1" text="$2" i=0
    for ((i = 0; i < n; i++)); do printf '%s\n' "$text"; done
}
# real_diff_bytes <path> -- the byte size of <path>'s own `git diff HEAD`,
# measured EXACTLY the way review_request_diff_text itself measures it
# (capture into a variable via command substitution FIRST -- which strips
# any trailing newline -- then measure THAT string with printf | wc -c),
# not `git diff ... | wc -c` directly, which counts a trailing newline the
# function's own measurement does not see. Using a different methodology
# than the code under test produced a spurious 1-3 byte mismatch the first
# time this file ran; this helper is the fix, not a tolerance widened to
# paper over it.
real_diff_bytes() {
    local out=""
    out=$(cd "$FIXTURE" && git diff --no-ext-diff --no-textconv HEAD -- "$1" 2>/dev/null)
    printf '%s' "$out" | wc -c | tr -d '[:space:]'
}

echo "=== Fixture: $FIXTURE ==="
echo "=== git: $(git --version), DEVELOPER_DIR=${DEVELOPER_DIR:-<unset>} ==="

# ===========================================================================
# SECTION B — review_request_diff_tier, extracted from the SHIPPED script by
# awk (the same technique doc-only-classifier.test.sh already uses for
# is_doc_only_path), so the classifier under test is the shipped definition.

echo
echo "--- SECTION B: tier classifier (extracted from the shipped script) ---"

TIER_SRC="$FIXTURE/.claude/.qa-tracking/.rrdb-tier-extract.sh"
awk '/^review_request_diff_tier\(\) \{/,/^\}/' "$PLUGIN_DIR/.claude/scripts/qa-gate.sh" > "$TIER_SRC"
assert_ne "B.0 non-vacuity: the extraction is non-empty" "" "$(cat "$TIER_SRC" 2>/dev/null)"
bash -n "$TIER_SRC"
assert_eq "B.0b non-vacuity: the extraction parses as valid bash" "0" "$?"

tier_of() {
    # shellcheck disable=SC1090  # dynamically-extracted source, by design
    ( . "$TIER_SRC"; review_request_diff_tier "$1" )
}

assert_eq "B.1 a plain shipped script is tier 1 (source)" "1" "$(tier_of '.claude/scripts/qa-gate.sh')"
assert_eq "B.2 a .test.sh file under scripts/tests/ is tier 2" "2" "$(tier_of '.claude/scripts/tests/foo.test.sh')"
assert_eq "B.3 a bare test/ path component is tier 2 (generic, ecosystem-agnostic)" "2" "$(tier_of 'src/test/unit_test.py')"
assert_eq "B.4 a __tests__ directory (JS convention) is tier 2" "2" "$(tier_of 'src/__tests__/App.test.js')"
assert_eq "B.5 a README.md (generic doc) is tier 3" "3" "$(tier_of 'README.md')"
assert_eq "B.6 a docs/ path is tier 3" "3" "$(tier_of 'docs/guide.txt')"
assert_eq "B.7 a package-lock-style file is tier 3" "3" "$(tier_of 'package-lock.json')"
assert_eq "B.8 THE FIX: an agent prompt (.claude/agents/*.md) is tier 1, NOT tier 3 like a generic .md" \
    "1" "$(tier_of '.claude/agents/qa.md')"
assert_eq "B.9 THE FIX: .claude/hooks.json is tier 1, NOT tier 3 like a generic .json" \
    "1" "$(tier_of '.claude/hooks.json')"
assert_eq "B.10 THE FIX: .claude/settings.json is tier 1" "1" "$(tier_of '.claude/settings.json')"
assert_eq "B.11 an UNRECOGNISED language's real source defaults to tier 1 (portability)" \
    "1" "$(tier_of 'lib/whatever.rs')"

# ===========================================================================
# SECTION C — below budget: the WHOLE diff is included, unchanged from
# before this fix, with an explicit "DIFF COMPLETE" statement.

echo
echo "--- SECTION C: below budget -- complete diff, explicitly marked complete ---"

echo "line 1" > "$FIXTURE/src/a.sh"
( cd "$FIXTURE" && git add -A && git commit -q -m "C: initial commit" )
TID_C=$(new_task "section C task")
seed_completion "$TID_C" '["src/a.sh"]'
printf 'line 1\nCHANGED-C\n' > "$FIXTURE/src/a.sh"
set_tracker "$FIXTURE/src/a.sh"

REQ_C="$FIXTURE/.claude/.qa-tracking/review-request-$TID_C.json"
C_OUT=$(bash "$QG" review-request-build "$TID_C" --iteration 1 --stop-condition "C" --spec-file "$SPEC_FILE" 2>&1)
assert_eq "C.1 review-request-build succeeds under budget" "0" "$?"
assert_eq "C.1b ok:true" "true" "$(json_field '.ok' "$C_OUT")"
assert_eq "C.1c diff_omitted_files:0 on the envelope" "0" "$(json_field '.diff_omitted_files' "$C_OUT")"
C_DIFF=$(json_field '.diff' "$(cat "$REQ_C" 2>/dev/null)")
assert_contains "C.2 the real changed line is present" "CHANGED-C" "$C_DIFF"
assert_contains "C.3 an explicit DIFF COMPLETE statement is present" "DIFF COMPLETE" "$C_DIFF"
assert_not_contains "C.4 NEGATIVE CONTROL: no truncation notice on an uncut packet" "DIFF TRUNCATED" "$C_DIFF"
assert_not_contains "C.4b NEGATIVE CONTROL: no OMITTED marker on an uncut packet" "OMITTED ENTIRELY" "$C_DIFF"

# ===========================================================================
# SECTION D — above budget: a disclosed, whole-file elision, with an exact
# accounting a test can check independent of parsing the rendered text.

echo
echo "--- SECTION D: above budget -- disclosed elision, exact accounting ---"

TID_D=$(new_task "section D task")
seed_completion "$TID_D" '["src/big.sh","src/small.sh"]'
# ASYMMETRIC sizes on purpose (QA round 2, R2 "half two"): a big.sh
# (~60KB) and a small.sh (~25KB), sized so EITHER fits the budget alone
# but NOT both together -- a fixture that can actually tell largest-first
# and smallest-first APART. The original round-1 fixture used two
# byte-identical files and could not distinguish the two policies at all
# (confirmed directly: all 52 assertions still passed after the ordering
# was silently reverted during development of this fix, which is exactly
# the kind of false confidence a real QA packet caught and this fixture
# now closes).
{ echo "#!/bin/bash"; repeat_line 800 "echo 'line of content for big'"; } > "$FIXTURE/src/big.sh"
{ echo "#!/bin/bash"; repeat_line 330 "echo 'line of content for small'"; } > "$FIXTURE/src/small.sh"
( cd "$FIXTURE" && git add -A && git commit -q -m "D: baseline" )
{ echo "#!/bin/bash"; repeat_line 800 "echo 'line of content for big CHANGED'"; } > "$FIXTURE/src/big.sh"
{ echo "#!/bin/bash"; repeat_line 330 "echo 'line of content for small CHANGED'"; } > "$FIXTURE/src/small.sh"
set_tracker "$FIXTURE/src/big.sh" "$FIXTURE/src/small.sh"

REAL_BIG=$(real_diff_bytes src/big.sh)
REAL_SMALL=$(real_diff_bytes src/small.sh)
REAL_TOTAL=$((REAL_BIG + REAL_SMALL))
# Non-vacuity for the fixture ITSELF: big alone must fit comfortably inside
# a realistic budget, small alone must ALSO fit, and the two TOGETHER must
# not -- otherwise this section could not discriminate between orderings
# at all (see the block comment above for why this matters specifically).
SHIPPED_DIFF_TARGET_D=$(grep -E '^REVIEW_REQUEST_DIFF_TARGET_BYTES=' "$PLUGIN_DIR/.claude/scripts/qa-gate.sh" | head -1 | cut -d= -f2)
assert_eq "D.0a fixture sanity: big ALONE is comfortably UNDER the shipped diff target" \
    "fits" "$([ "$REAL_BIG" -lt "$((SHIPPED_DIFF_TARGET_D - 15000))" ] && echo fits || echo does-not-fit)"
assert_eq "D.0b fixture sanity: small ALONE is comfortably UNDER the shipped diff target" \
    "fits" "$([ "$REAL_SMALL" -lt "$((SHIPPED_DIFF_TARGET_D - 15000))" ] && echo fits || echo does-not-fit)"
assert_eq "D.0c fixture sanity: big+small TOGETHER exceeds the shipped diff target" \
    "exceeds" "$([ "$REAL_TOTAL" -gt "$SHIPPED_DIFF_TARGET_D" ] && echo exceeds || echo does-not-exceed)"

REQ_D="$FIXTURE/.claude/.qa-tracking/review-request-$TID_D.json"
# review-request-build computes its OWN diff budget internally (target
# ceiling minus the real, measured sizes of spec/completion_contract/
# impact_report) -- there is no flag to inject a budget directly, by
# design (see cmd_review_request_build's own header). The fixture's files
# are sized well past that internally-computed budget so the over-budget
# path is genuinely exercised, not assumed.
D_OUT=$(bash "$QG" review-request-build "$TID_D" --iteration 1 --stop-condition "D" --spec-file "$SPEC_FILE" \
    --completion-contract-file "$FIXTURE/.claude/.qa-tracking/completion-$TID_D-devops.json" 2>&1)
assert_eq "D.1 review-request-build succeeds over budget (degrades, does not fail)" "0" "$?"
D_TOTAL=$(json_field '.diff_total_bytes' "$D_OUT")
D_INC_BYTES=$(json_field '.diff_included_bytes' "$D_OUT")
D_OM_BYTES=$(json_field '.diff_omitted_bytes' "$D_OUT")
D_OM_FILES=$(json_field '.diff_omitted_files' "$D_OUT")

# D.2 NON-VACUITY: the real, independently-measured total agrees with the
# function's own accounting -- proves the "total" figure is not a made-up
# number decoupled from what git actually reports.
assert_eq "D.2 non-vacuity: independently-measured total diff bytes matches the envelope's diff_total_bytes" \
    "$REAL_TOTAL" "$D_TOTAL"
# D.3 THE CORE INVARIANT: included + omitted == total, exactly.
assert_eq "D.3 THE ACCOUNTING INVARIANT: included_bytes + omitted_bytes == total_bytes" \
    "$D_TOTAL" "$((D_INC_BYTES + D_OM_BYTES))"
assert_ne "D.4 something WAS actually omitted (the budget genuinely bound)" "0" "$D_OM_FILES"

D_DIFF=$(json_field '.diff' "$(cat "$REQ_D" 2>/dev/null)")
# Captured HERE, not lazily in Section E below: a later subsection (D3)
# commits a new HEAD, and `git diff HEAD -- src/big.sh` computed AFTER that
# commit would diff against the WRONG baseline (measured happening on this
# file's own earlier draft, for the same underlying reason section F's
# fixture needed a full regeneration rather than a one-line append).
D_BIG_STANDALONE=$(cd "$FIXTURE" && git diff --no-ext-diff --no-textconv HEAD -- src/big.sh)
assert_contains "D.6 the truncation notice is present" "DIFF TRUNCATED FOR SIZE" "$D_DIFF"
assert_contains "D.7 the omitted-file list names src/small.sh with a real byte count" \
    "src/small.sh (${REAL_SMALL} bytes" "$D_DIFF"
# D.7b/c THE FIX ITSELF, asserted directly: LARGEST-first means big.sh (the
# more substantial file) is the one shown, and small.sh (the less
# substantial one) is the one left out -- the reverse of what this
# function's first shipped version (smallest-first) would have done on
# this exact fixture. QA round 2's whole finding was that the OLD policy
# would get this backwards on a real packet; this fixture is built
# specifically so that claim is checkable by grep, not just by citation.
assert_contains "D.7b THE FIX: big.sh (the MORE substantial file) is the one INCLUDED" \
    "line of content for big CHANGED" "$D_DIFF"
assert_not_contains "D.7c THE FIX: small.sh (the LESS substantial file) is NOT in the rendered diff" \
    "line of content for small CHANGED" "$D_DIFF"
assert_contains "D.8 the notice states the completeness verdict plainly" "this diff is INCOMPLETE" "$D_DIFF"
D_REQ_BYTES=$(wc -c < "$REQ_D" | tr -d '[:space:]')
assert_le "D.9 THE POINT OF THE FIX: the assembled request stays under the 100000-byte cap despite ${REAL_TOTAL} bytes of real diff content existing" \
    "$D_REQ_BYTES" "100000"

# D.10-D.13: NEGATIVE CONTROL -- reproduce the FIRST-SHIPPED (smallest-first)
# ordering as a mutant and prove it gets THIS EXACT fixture backwards: small
# included, big omitted. This is QA round 2's own finding, reproduced on
# demand rather than merely cited, with a restore control proving the
# shipped script still gets it right on the identical input.
MUTANT_ORDER_QG="$FIXTURE/.claude/scripts/qa-gate-order-mutant.sh"
cp "$FIXTURE/.claude/scripts/qa-gate.sh" "$MUTANT_ORDER_QG"
# Matched on the DISTINGUISHING SUFFIX only (-k2,2nr -k3,3), not the whole
# line: the full line embeds a literal apostrophe ($(printf '\t')), which a
# single-quoted grep pattern cannot represent without bash's clunky
# '...'\''...' escape, and getting that wrong once already produced a
# grep pattern matching a DIFFERENT apostrophe count than the source file
# actually has (D.10 failed vacuously against 0 real occurrences on this
# file's own first attempt) -- rather than fix the escaping, match the
# short, apostrophe-free tail that already uniquely identifies the sort
# key, exactly as the sed mutation two lines below already does.
BEFORE_ORDER=$(grep -c -- '-k2,2nr -k3,3)$' "$MUTANT_ORDER_QG")
assert_eq "D.10 non-vacuity: the shipped largest-first sort key exists exactly once before mutation" "1" "$BEFORE_ORDER"
sed -e 's/-k2,2nr -k3,3)$/-k2,2n -k3,3)/' "$FIXTURE/.claude/scripts/qa-gate.sh" > "$MUTANT_ORDER_QG"
chmod +x "$MUTANT_ORDER_QG"
AFTER_ORDER=$(grep -c -- '-k2,2n -k3,3)$' "$MUTANT_ORDER_QG")
AFTER_ORDER_NO_R=$(grep -c -- '-k2,2nr -k3,3)$' "$MUTANT_ORDER_QG")
assert_eq "D.11 non-vacuity: the mutation landed (reverted to smallest-first)" "1" "$AFTER_ORDER"
assert_eq "D.11b non-vacuity: the largest-first form is GONE from the mutant" "0" "$AFTER_ORDER_NO_R"
bash -n "$MUTANT_ORDER_QG"
assert_eq "D.11c non-vacuity: the mutant still parses as valid bash" "0" "$?"

TID_D2=$(new_task "section D negative-control task")
seed_completion "$TID_D2" '["src/big.sh","src/small.sh"]'
set_tracker "$FIXTURE/src/big.sh" "$FIXTURE/src/small.sh"
D2_OUT=$(bash "$MUTANT_ORDER_QG" review-request-build "$TID_D2" --iteration 1 --stop-condition "D negative control" --spec-file "$SPEC_FILE" \
    --completion-contract-file "$FIXTURE/.claude/.qa-tracking/completion-$TID_D2-devops.json" 2>&1)
assert_eq "D.12 the mutant still runs to completion (degrades, does not crash)" "0" "$?"
# D.12b-d: examine the CONTROL'S OWN OUTPUT directly, not only the rendered
# diff text below -- a negative control whose structured envelope is never
# read is not actually a control, only a captured-and-ignored variable.
# These corroborate D.13/D.13b through a COMPLETELY different mechanism
# (the JSON fields the mutant itself reports) rather than restating the
# same grep a second time.
assert_eq "D.12b the mutant's own envelope reports ok:true (it degraded, not crashed)" \
    "true" "$(json_field '.ok' "$D2_OUT")"
assert_eq "D.12c the mutant's own envelope reports exactly 1 file included" \
    "1" "$(json_field '.diff_included_files' "$D2_OUT")"
assert_eq "D.12d the mutant's own envelope reports exactly 1 file omitted" \
    "1" "$(json_field '.diff_omitted_files' "$D2_OUT")"
REQ_D2="$FIXTURE/.claude/.qa-tracking/review-request-$TID_D2.json"
D2_DIFF=$(json_field '.diff' "$(cat "$REQ_D2" 2>/dev/null)")
assert_contains "D.13 SPECIFIC MISBEHAVIOUR: under the REVERTED (smallest-first) mutant, small.sh is INCLUDED instead" \
    "line of content for small CHANGED" "$D2_DIFF"
assert_not_contains "D.13b ...and big.sh -- the more substantial file -- is OMITTED instead, reproducing QA's exact finding" \
    "line of content for big CHANGED" "$D2_DIFF"
rm -f "$MUTANT_ORDER_QG"

# D.14-D.16: the elision instruction, both variants (QA round 2, "half two"'s
# second change). big.sh is tier 1 (a plain .sh source file) so Section D's
# own over-budget case above already has a tier-1 omission if big.sh were
# the one left out -- but D.7b/c prove big.sh is the one KEPT here. Build a
# DEDICATED small fixture where the omitted file is tier 1, and a second
# where every omission is tier 2/3 only, so both instruction branches are
# exercised on purpose rather than by accident of which section happens to
# omit what.
TID_D3=$(new_task "section D tier1-instruction task")
mkdir -p "$FIXTURE/src/tests"
seed_completion "$TID_D3" '["src/big.sh","src/tests/small.test.sh"]'
{ echo "#!/bin/bash"; repeat_line 330 "echo 'small test line'"; } > "$FIXTURE/src/tests/small.test.sh"
( cd "$FIXTURE" && git add -A && git commit -q -m "D3: baseline" )
{ echo "#!/bin/bash"; repeat_line 800 "echo 'line of content for big CHANGED AGAIN'"; } > "$FIXTURE/src/big.sh"
{ echo "#!/bin/bash"; repeat_line 330 "echo 'small test line CHANGED'"; } > "$FIXTURE/src/tests/small.test.sh"
set_tracker "$FIXTURE/src/big.sh" "$FIXTURE/src/tests/small.test.sh"
D3_OUT=$(bash "$QG" review-request-build "$TID_D3" --iteration 1 --stop-condition "D3" --spec-file "$SPEC_FILE" \
    --completion-contract-file "$FIXTURE/.claude/.qa-tracking/completion-$TID_D3-devops.json" 2>&1)
assert_eq "D.14 setup: review-request-build succeeds" "0" "$?"
assert_eq "D.14b setup: the envelope reports ok:true" "true" "$(json_field '.ok' "$D3_OUT")"
# D.14c non-vacuity for D.15 below: something must ACTUALLY be omitted in
# this fixture, or "no tier-1 file was omitted" would be vacuously true
# for the wrong reason (nothing omitted at all, not "only non-tier-1
# omitted") and D.15b would then be asserting text that was never reached
# on its own merits.
assert_ne "D.14c non-vacuity: at least one file really was omitted (precondition for D.15/D.15b to test what they claim)" \
    "0" "$(json_field '.diff_omitted_files' "$D3_OUT")"
REQ_D3="$FIXTURE/.claude/.qa-tracking/review-request-$TID_D3.json"
D3_DIFF=$(json_field '.diff' "$(cat "$REQ_D3" 2>/dev/null)")
# big.sh (tier 1) fits the budget on its own (largest-first); the tier-2
# test file is the one crowded out here -- a NON-tier-1 omission, so the
# SOFTER instruction branch should fire.
assert_not_contains "D.15 no tier-1 file was actually omitted in this fixture (precondition for the soft-branch assertion below)" \
    "MUST NOT return verdict" "$D3_DIFF"
assert_contains "D.15b the SOFT instruction branch fires for a tests-only omission" \
    "you may still verdict:\"approve\" for the assessed source content" "$D3_DIFF"

# The STRONG branch was already exercised for real in Section D's own main
# case above (D_DIFF, where small.sh -- assert it really is tier-1-shaped
# by construction: a plain .sh file directly under src/, matching review_
# request_diff_tier's own tier-1 default) is the omission.
assert_contains "D.16 THE STRONG instruction branch already fired in D's own main case (a tier-1 omission)" \
    "MUST NOT return verdict:\"approve\"" "$D_DIFF"
assert_contains "D.16b it names the obligation to record a finding and set verdict findings instead" \
    "set verdict:\"findings\"" "$D_DIFF"

# ===========================================================================
# SECTION E — never a partial single-file cut.

echo
echo "--- SECTION E: an included file is byte-identical to its own standalone diff; a lone oversized file is wholly omitted, never partially shown ---"

# E.1: the INCLUDED small file's rendered content is the exact, complete
# standalone diff for that file -- not a truncated fragment of it.
assert_contains "E.1 the included file's FULL standalone diff appears verbatim (not a fragment)" \
    "$D_BIG_STANDALONE" "$D_DIFF"

# E.2: a SINGLE file whose own diff exceeds the ENTIRE budget on its own is
# wholly omitted -- never shown as a truncated partial hunk.
TID_E=$(new_task "section E task")
seed_completion "$TID_E" '["src/huge.sh"]'
echo "#!/bin/bash" > "$FIXTURE/src/huge.sh"
( cd "$FIXTURE" && git add -A && git commit -q -m "E: baseline" )
{ echo "#!/bin/bash"; repeat_line 3000 "echo 'huge single file content line'"; } > "$FIXTURE/src/huge.sh"
set_tracker "$FIXTURE/src/huge.sh"
REAL_HUGE=$(real_diff_bytes src/huge.sh)

E_OUT=$(bash "$QG" review-request-build "$TID_E" --iteration 1 --stop-condition "E" --spec-file "$SPEC_FILE" \
    --completion-contract-file "$FIXTURE/.claude/.qa-tracking/completion-$TID_E-devops.json" 2>&1)
# E.2 non-vacuity: the single file really is bigger than the shipped diff
# target on its own (extracted from the shipped script, not re-typed, so a
# future change to the constant cannot silently desync this assertion).
SHIPPED_DIFF_TARGET=$(grep -E '^REVIEW_REQUEST_DIFF_TARGET_BYTES=' "$PLUGIN_DIR/.claude/scripts/qa-gate.sh" | head -1 | cut -d= -f2)
assert_eq "E.2 non-vacuity: the single file (${REAL_HUGE}B) really exceeds the shipped diff target (${SHIPPED_DIFF_TARGET}B) on its own" \
    "0" "$([ "$REAL_HUGE" -gt "$SHIPPED_DIFF_TARGET" ] 2>/dev/null && echo 0 || echo 1)"
REQ_E="$FIXTURE/.claude/.qa-tracking/review-request-$TID_E.json"
E_DIFF=$(json_field '.diff' "$(cat "$REQ_E" 2>/dev/null)")
E_OM_FILES=$(json_field '.diff_omitted_files' "$E_OUT")
E_INC_FILES=$(json_field '.diff_included_files' "$E_OUT")
assert_eq "E.3 the lone huge file is wholly OMITTED (0 included), never partially shown" "0" "$E_INC_FILES"
assert_eq "E.3b exactly one file omitted" "1" "$E_OM_FILES"
assert_contains "E.4 it is named with its real, full byte count in the omitted list" \
    "src/huge.sh (${REAL_HUGE} bytes" "$E_DIFF"
assert_not_contains "E.5 no fragment of its content leaked into the rendered diff" \
    "huge single file content line" "$E_DIFF"

# ===========================================================================
# SECTION F — META-TEST (the coordinator's own instruction): stub the
# elision accounting to always report zero omitted, and prove the
# independent invariant check catches the lie.

echo
echo "--- SECTION F: META-TEST -- a stubbed zero-omitted claim is caught ---"

MUTANT_QG="$FIXTURE/.claude/scripts/qa-gate-mutant.sh"
cp "$FIXTURE/.claude/scripts/qa-gate.sh" "$MUTANT_QG"
# shellcheck disable=SC2016  # single-quoted on purpose: matching the shipped source's LITERAL text, not expanding this test's own variables.
BEFORE_STUB=$(grep -c '^    REVIEW_REQUEST_DIFF_OMITTED_COUNT=${#omitted\[@\]}$' "$MUTANT_QG")
assert_eq "F.0 non-vacuity: the target line exists exactly once in the shipped script before mutation" \
    "1" "$BEFORE_STUB"
# Mutate: force the reported omitted count/bytes to a hardcoded zero AFTER
# they are computed, regardless of what pass 2 actually found -- the
# "accounting lies" shape the coordinator's META-TEST asks for.
awk '
    { print }
    /^    REVIEW_REQUEST_DIFF_OMITTED_BYTES=\$\(\(REVIEW_REQUEST_DIFF_TOTAL_BYTES - running\)\)$/ {
        print "    REVIEW_REQUEST_DIFF_OMITTED_COUNT=0  # MUTANT: always claims zero omitted"
        print "    REVIEW_REQUEST_DIFF_OMITTED_BYTES=0  # MUTANT: always claims zero omitted"
    }
' "$FIXTURE/.claude/scripts/qa-gate.sh" > "$MUTANT_QG"
chmod +x "$MUTANT_QG"
AFTER_STUB=$(grep -c 'MUTANT: always claims zero omitted' "$MUTANT_QG")
assert_eq "F.1 non-vacuity: the mutation landed (2 lines added)" "2" "$AFTER_STUB"
bash -n "$MUTANT_QG"
assert_eq "F.1b non-vacuity: the mutant still parses as valid bash" "0" "$?"

# Earlier baseline commits in this file (Section D3's included) absorbed
# previous uncommitted big.sh/small.sh content into HEAD -- a ONE-LINE
# append here would diff only that one line against the ALREADY-COMMITTED
# large content, not reproduce a large uncommitted diff (measured happening
# on this file's own first draft). Regenerate the FULL content again,
# distinctly different from what is now in HEAD, so there is a genuinely
# large uncommitted diff once more. Verified by F.0c below, not assumed.
{ echo "#!/bin/bash"; repeat_line 800 "echo 'line of content for big FSECTION'"; } > "$FIXTURE/src/big.sh"
{ echo "#!/bin/bash"; repeat_line 330 "echo 'line of content for small FSECTION'"; } > "$FIXTURE/src/small.sh"

TID_F=$(new_task "section F task")
seed_completion "$TID_F" '["src/big.sh","src/small.sh"]'
set_tracker "$FIXTURE/src/big.sh" "$FIXTURE/src/small.sh"

F_REAL_BIG=$(real_diff_bytes src/big.sh)
F_REAL_SMALL=$(real_diff_bytes src/small.sh)
F_REAL_TOTAL=$((F_REAL_BIG + F_REAL_SMALL))
assert_eq "F.0c fixture sanity (re-checked after the re-touch, not assumed): the combined diff still exceeds the shipped diff target" \
    "exceeds" "$([ "$F_REAL_TOTAL" -gt "$SHIPPED_DIFF_TARGET_D" ] && echo exceeds || echo does-not-exceed)"

F_OUT=$(bash "$MUTANT_QG" review-request-build "$TID_F" --iteration 1 --stop-condition "F" --spec-file "$SPEC_FILE" \
    --completion-contract-file "$FIXTURE/.claude/.qa-tracking/completion-$TID_F-devops.json" 2>&1)
F_TOTAL=$(json_field '.diff_total_bytes' "$F_OUT")
F_INC_BYTES=$(json_field '.diff_included_bytes' "$F_OUT")
F_OM_BYTES=$(json_field '.diff_omitted_bytes' "$F_OUT")
F_OM_FILES=$(json_field '.diff_omitted_files' "$F_OUT")

assert_eq "F.2 SPECIFIC MISBEHAVIOUR: the mutant's own envelope claims zero omitted files" "0" "$F_OM_FILES"
assert_eq "F.2b ...and zero omitted bytes" "0" "$F_OM_BYTES"
# F.3 THE CATCH: the SAME independent invariant Section D used (included +
# omitted == total) is now VIOLATED by the mutant's own numbers, because
# included_bytes alone cannot equal total_bytes when files were genuinely
# left out of the rendered text -- proving a caller who checks this
# invariant (rather than trusting the omitted-count field by itself) is
# NOT fooled by the stub, even though the stub fooled the field itself.
assert_ne "F.3 META-TEST CATCH: included_bytes + omitted_bytes(=0, stubbed) does NOT equal total_bytes -- the invariant check catches the lie the stubbed field alone would not" \
    "$F_TOTAL" "$((F_INC_BYTES + F_OM_BYTES))"
# F.4 RESTORE CONTROL: the SAME inputs through the SHIPPED (unmutated)
# script satisfy the invariant exactly, as Section D already proved
# generally -- restated here against THIS section's own fixture so the
# contrast is against identical inputs, not merely a different section.
TID_F2=$(new_task "section F restore task")
seed_completion "$TID_F2" '["src/big1.sh","src/big2.sh","src/small.sh"]'
set_tracker "$FIXTURE/src/big1.sh" "$FIXTURE/src/big2.sh" "$FIXTURE/src/small.sh"
F2_OUT=$(bash "$QG" review-request-build "$TID_F2" --iteration 1 --stop-condition "F restore" --spec-file "$SPEC_FILE" \
    --completion-contract-file "$FIXTURE/.claude/.qa-tracking/completion-$TID_F2-devops.json" 2>&1)
F2_TOTAL=$(json_field '.diff_total_bytes' "$F2_OUT")
F2_INC_BYTES=$(json_field '.diff_included_bytes' "$F2_OUT")
F2_OM_BYTES=$(json_field '.diff_omitted_bytes' "$F2_OUT")
assert_eq "F.4 RESTORE: the shipped (unmutated) script's own accounting satisfies the invariant" \
    "$F2_TOTAL" "$((F2_INC_BYTES + F2_OM_BYTES))"
rm -f "$MUTANT_QG"

# ===========================================================================
# SECTION G — regression: exit 7 does not regress for a packet that SHOULD
# still refuse (this fix bounds the DIFF specifically; an oversized
# completion_contract on its own is a different field this fix does not
# touch, and the existing cap must still catch it).

echo
echo "--- SECTION G: regression -- a genuinely oversized packet still refuses ---"

TID_G=$(new_task "section G task")
seed_completion "$TID_G" '["src/small.sh"]'
set_tracker "$FIXTURE/src/small.sh"
HUGE_CC="$FIXTURE/.claude/.qa-tracking/.rrdb-huge-cc.json"
python3 -c "
import json
print(json.dumps({'task_id':'placeholder','files_changed':[],'tests_added':[],
  'decisions':['x'*150000],'blockers':[],'llm_observations':'y','context_coverage':'z',
  'role':'devops','model':'m','pin':'m','unit_id':'','design_hash':'',
  'green_before':'none','green_after':'none','criteria_tests':{}}))
" > "$HUGE_CC"
G_OUT=$(bash "$QG" review-request-build "$TID_G" --iteration 1 --stop-condition "G" --spec-file "$SPEC_FILE" \
    --completion-contract-file "$HUGE_CC" 2>&1)
assert_eq "G.1 review-request-build itself still succeeds (assembly does not refuse; the CONSUMER does)" \
    "0" "$?"
assert_eq "G.1b ok:true on the assembly's own envelope" "true" "$(json_field '.ok' "$G_OUT")"
REQ_G="$FIXTURE/.claude/.qa-tracking/review-request-$TID_G.json"
G_BYTES=$(wc -c < "$REQ_G" | tr -d '[:space:]')
assert_eq "G.2 non-vacuity: the assembled request (${G_BYTES}B) really is oversized (a huge completion_contract this fix does not touch)" \
    "oversized" "$([ "$G_BYTES" -gt 100000 ] 2>/dev/null && echo oversized || echo not-oversized)"

mkdir -p "$FIXTURE/.claude"
{
    echo "risk_threshold_default=high"
    echo "max_findings=10"
    echo "max_review_iterations=3"
    echo "timeout_seconds=5"
    echo "malformed_retry=1"
    echo "max_request_bytes=100000"
} > "$FIXTURE/.claude/review-config"
G_ERR=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/codex-review.sh" "$TID_G" --request "$REQ_G" --iteration 1 2>&1 >/dev/null)
G_RC=$?
assert_eq "G.3 REGRESSION GUARD: the downstream consumer still exits 7 for a genuinely oversized packet" "7" "$G_RC"
assert_contains "G.3b refusal names max_request_bytes and the real byte count" "exceeding max_request_bytes=100000" "$G_ERR"

# ===========================================================================
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

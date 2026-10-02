#!/bin/bash
# beads-ledger.test.sh — pipefail hardening of the ledger-vs-database
# comparison chain (claude-workflow-plugin-i8cx, wave 2 group C).
#
# THE DEFECT CLASS. beads-ledger.sh sets `set -u` but never pipefail. Five
# internal pipelines report the LAST command's exit status, so a fallible
# upstream producer's failure was masked whenever the tail stage still
# succeeded on empty/partial input:
#
#   sha256_file()    shasum/sha256sum | awk '{print $1}'   -- awk is trivially
#                     successful even on a mid-write crash, so a partial hash
#                     line survives instead of the honest empty string.
#   count_lines()     wc -l < file | tr -d ' '              -- same shape.
#   record_meta()     jq -rR '...' | sort -k1,1             -- THE feeder for
#                     classify()'s per-record comparison. A crashing jq made
#                     $lm/$fm silently EMPTY, and an empty $lm compares as
#                     "every ledger record is accounted for" -- the exact
#                     verdict that authorises `export --apply` to DISCARD the
#                     ledger.
#   parse_failures()  jq '...' | grep -c . | tr -d ' '       -- the file's own
#                     "Integrity gate", first line of defence in classify().
#                     A crashing jq reported "0 bad lines" -- the SAME output
#                     a genuinely clean file produces -- bypassing the gate
#                     entirely rather than refusing on a partial view.
#   classify()'s      comm -23 <(cut ...) <(cut ...) | head -5 | tr '\n' ' '
#   ledger_only/       and  join ... | awk '...' | head -5 | tr '\n' ' '
#   unproven          `head -5` is a LIMITER (not intentional-nonzero: it
#                     exits 0 whether it reads all input or stops early), but
#                     a naive blanket pipefail over "producer | ... | head -5"
#                     would SIGPIPE the producer on any diff > 5 records --
#                     the measured trap ("seq | head -1" -> rc 141,
#                     nondeterministic by data size) applied to THIS file's
#                     own shape.
#
# THE FIX, per site: split the FALLIBLE PRODUCER into its own rc-checked step
# (sha256_file/count_lines: scoped `( set -o pipefail; ... )`; record_meta: a
# subshell whose own exit IS the function's, so the caller — classify() — now
# checks record_meta's return before trusting $lm/$fm; parse_failures: jq
# captured alone, BEFORE the intentional-nonzero `grep -c .` tail, which stays
# unwrapped exactly because it is expected to be 1 on the common "zero bad
# lines" case; ledger_only/unproven: the fallible producer (comm, or
# join|awk) is captured and rc-checked FIRST, `head -5` is applied AFTERWARDS
# to the already-materialised in-memory string, which can never SIGPIPE a
# process that has already exited).
#
# PAIRING (.claude/tests/README.md "The pairing requirement"): every section
# below drives the SHIPPED .claude/scripts/beads-ledger.sh as a subprocess
# (leg 4), against mutants copied FROM the canonical bytes with an explicit
# landed-where-aimed proof (leg 1), asserted to fail in the guard's SPECIFIC
# way (leg 2: the exact masquerade — a false "fresh"/"stale" reassurance, not
# just "different output"), with an unshimmed restore control (leg 3).
# Sections D/E (sha256_file/count_lines) additionally drive the EXTRACTED
# shipped function directly — see their headers for why cmd_check's own
# verdict does not observably move for those two (the pre-existing
# `[ -z "$fresh_sha" ]` guard and the natural hash-mismatch fallback into
# classify() already absorb their masked-failure shape at the cmd_check
# level; the fix is a real, defensible hardening of the FUNCTION's own
# contract — extracted-and-driven is the honest leg 4 for these two, stated
# rather than glossed).
#
# Needs: real bd (an ISOLATED fixture-local database — never the live
# project's; same convention as qa-gate-pipefail.test.sh / model-roles.test.sh
# section 11), jq, git, shasum or sha256sum. Exit: 0 all pass | 1 failures.

set -u

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
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %.400s\n' "$name" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    forbidden: %s\n    haystack:  %.400s\n' "$name" "$needle" "$haystack"
    else
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    fi
}

for tool in bd jq git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool not on PATH — this spec requires it."
        exit 1
    fi
done
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "neither shasum nor sha256sum on PATH — this spec requires one."
    exit 1
fi
REAL_JQ=$(command -v jq)
REAL_SHASUM=$(command -v shasum || command -v sha256sum)

PLUGIN_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
BL="$PLUGIN_DIR/.claude/scripts/beads-ledger.sh"

FIXTURE=$(mktemp -d -t beads-ledger-test.XXXXXX)
# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\n' "$FIXTURE"
    else
        chmod -R u+rwX "$FIXTURE" 2>/dev/null || true
        rm -rf "$FIXTURE"
    fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/bin" "$FIXTURE/repo"
cd "$FIXTURE/repo" || exit 2
git init -q .
bd init --skip-agents --skip-hooks >/dev/null 2>&1 || bd init >/dev/null 2>&1
export CLAUDE_PROJECT_DIR="$FIXTURE/repo"
export BEADS_LEDGER_PATH="$FIXTURE/repo/ledger.jsonl"

# One real fixture-local task (ISOLATED database — .beads/ under $FIXTURE,
# never the live project's; matches model-roles.test.sh section 11's
# isolation convention).
TID=$(bd create "fixture task for beads-ledger.test.sh" -t task --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null)
if [ -z "$TID" ]; then
    # 0.47.x bd's create does not support --json; fall back to a plain list.
    bd create "fixture task for beads-ledger.test.sh" -t task >/dev/null 2>&1
    TID=$(bd list --json 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null)
fi
[ -n "$TID" ] || { echo "harness error: could not create a fixture bd task"; exit 2; }

# --- SECTION 0: preconditions -----------------------------------------------
echo "--- Section 0: shipped guards exist, fault-injection markers are source-unique ---"
BL_SRC=$(cat "$BL")
# shellcheck disable=SC2016  # literal needles matched against source text, deliberately unexpanded
assert_contains "0.1 sha256_file carries the scoped-pipefail guard" \
    'out=$( set -o pipefail; shasum -a 256' "$BL_SRC"
# shellcheck disable=SC2016
assert_contains "0.2 count_lines carries the scoped-pipefail guard" \
    'out=$( set -o pipefail; wc -l < "$f"' "$BL_SRC"
assert_contains "0.3 record_meta runs inside a subshell whose exit code IS the function's" \
    '( set -o pipefail' "$BL_SRC"
# record_meta's jq PROGRAM (multi-line) carries "tojson"; parse_failures' jq
# PROGRAM carries "gsub(". Uniqueness is checked over each FUNCTION BODY (the
# jq invocation spans several physical lines), not file-wide — "tojson" also
# appears once in a prose comment above record_meta, which is irrelevant to
# the shim (the shim only inspects jq's own argv, never this file's source).
RM_BODY=$(sed -n '/^record_meta() {/,/^}/p' "$BL")
PF_BODY=$(sed -n '/^parse_failures() {/,/^}/p' "$BL")
assert_contains "0.4 record_meta's jq call carries the tojson marker" "tojson" "$RM_BODY"
assert_not_contains "0.4b ...and parse_failures' jq call does NOT (isolation holds)" "tojson" "$PF_BODY"
assert_contains "0.5 parse_failures' jq call carries the gsub( marker" "gsub(" "$PF_BODY"
assert_not_contains "0.5b ...and record_meta's jq call does NOT (isolation holds)" "gsub(" "$RM_BODY"
# shellcheck disable=SC2016
assert_contains "0.6 classify() checks record_meta's rc before trusting \$lm" \
    'if ! record_meta "$ledger" > "$lm"; then' "$BL_SRC"
# shellcheck disable=SC2016
assert_contains "0.7 ledger_only is built from an already-materialised string (head after capture)" \
    'ledger_only=$(printf '"'"'%s'"'"' "$comm_out" | head -5' "$BL_SRC"
# shellcheck disable=SC2016
assert_contains "0.8 unproven is built from an already-materialised string (head after capture)" \
    'unproven=$(printf '"'"'%s'"'"' "$ja_out" | head -5' "$BL_SRC"

# replace_function <src-file> <func-name> <replacement-body-file>
# Wholesale function replacement keyed on the signature line and the
# function's own column-0 closing brace — the qa-gate-pipefail.test.sh
# MUTANT B technique, applied here because the fix REPLACED a pipe shape
# rather than merely adding an early-exit guard, so there is no clean
# strip-to-nothing revert. Prints the spliced file to stdout.
replace_function() {
    local src="$1" fn="$2" bodyfile="$3"
    awk -v fn="$fn" -v bodyfile="$bodyfile" '
        BEGIN { skipping = 0 }
        $0 == fn "() {" {
            skipping = 1
            while ((getline line < bodyfile) > 0) print line
            next
        }
        skipping && /^}/ { skipping = 0; next }
        skipping { next }
        { print }
    ' "$src"
}

# The pre-i8cx bodies, verbatim — what record_meta/parse_failures looked
# like before this fix, for mutant construction below.
cat > "$FIXTURE/orig-record-meta.txt" <<'ORIGEOF'
record_meta() {
    [ -f "$1" ] || return 0
    jq -rR 'fromjson? | select(.id != null)
            | [ .id, ((.comments // []) | length), (.updated_at // ""), (. | tojson) ]
            | @tsv' "$1" 2>/dev/null | sort -k1,1
}
ORIGEOF
cat > "$FIXTURE/orig-parse-failures.txt" <<'ORIGEOF'
parse_failures() {
    [ -f "$1" ] || { printf '0'; return 0; }
    jq -rR 'select((. | gsub("^[[:space:]]+|[[:space:]]+$"; "")) != "")
            | if ((fromjson? | objects | .id?) // null) == null then "bad" else empty end' \
        "$1" 2>/dev/null | grep -c . | tr -d ' '
}
ORIGEOF

# --- SECTION A: record_meta masking -> classify() -> export's own warning --
echo
echo "--- Section A: a crashing jq inside record_meta() no longer produces a false 'safe to overwrite' ---"

# GENUINE ledger-ahead shape: the ledger carries a record no bd task ever
# had. This is the shape where record_meta("$ledger") failing is dangerous —
# comm -23 (step 2 of classify) can only find "records only in the ledger"
# when record_meta actually reads them; an EMPTY $lm makes comm find nothing,
# which then falls all the way through the join step (also empty on one
# side) to the DEFAULT "db-ahead" verdict, regardless of the true state. A
# db-ahead-shaped fixture (ledger matches db, db is merely richer) would NOT
# demonstrate this: it would coincidentally still resolve "safe" whether or
# not record_meta worked, since that IS the true state — the wrong
# methodology would get the wrong answer to the right conclusion by luck.
bd export -o "$FIXTURE/repo/ledger.jsonl" >/dev/null 2>&1
printf '{"id":"only-in-ledger-1","comments":[],"updated_at":"2026-01-01T00:00:00Z"}\n' >> "$FIXTURE/repo/ledger.jsonl"

mkdir -p "$FIXTURE/mutants"
MUT_RM="$FIXTURE/mutants/beads-ledger-mutA.sh"
replace_function "$BL" "record_meta" "$FIXTURE/orig-record-meta.txt" > "$MUT_RM"
chmod +x "$MUT_RM"
MUT_RM_BODY=$(sed -n '/^record_meta() {/,/^}/p' "$MUT_RM")
MUT_RM_HIT="miss"
if grep -qF 'set -o pipefail' <(sed -n '/^record_meta() {/,/^}/p' "$BL") \
    && ! printf '%s' "$MUT_RM_BODY" | grep -qF 'set -o pipefail' \
    && bash -n "$MUT_RM" 2>/dev/null; then
    MUT_RM_HIT="hit"
fi
assert_eq "A0 NON-VACUITY: mutant A landed (record_meta reverted to the pre-fix plain pipe, copy parses)" \
    "hit" "$MUT_RM_HIT"
assert_contains "A0b NON-VACUITY: the mutant's record_meta is byte-identical to the pre-fix body" \
    "$(cat "$FIXTURE/orig-record-meta.txt")" "$MUT_RM_BODY"

# Shim: jq fails ONLY when invoked with record_meta's own filter text
# (the "tojson" marker, asserted call-site-unique in Section 0). This
# isolates record_meta specifically — parse_failures (the earlier gate) is
# unaffected and still reports 0 bad lines honestly.
cat > "$FIXTURE/bin/jq" <<SHIMEOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in *tojson*) exit 9 ;; esac
done
exec ${REAL_JQ} "\$@"
SHIMEOF
chmod +x "$FIXTURE/bin/jq"

A_MUTANT=$(PATH="$FIXTURE/bin:$PATH" bash "$MUT_RM" export 2>&1)
assert_contains "A1 SPECIFIC MISBEHAVIOUR: mutant A (pre-fix shape) + the shim reproduces the false reassurance — offers --apply with NO data-loss warning" \
    "Re-run with --apply to overwrite" "$A_MUTANT"
assert_not_contains "A1b ...and the mutant's message never says WOULD BE LOST" \
    "WOULD BE LOST" "$A_MUTANT"

A_POST=$(PATH="$FIXTURE/bin:$PATH" bash "$BL" export 2>&1)
assert_contains "A2 THE FIX: same shim, SHIPPED script — refuses to call it safe" \
    "WOULD BE LOST" "$A_POST"

A_CHECK=$(PATH="$FIXTURE/bin:$PATH" bash "$BL" check --json 2>&1)
A_CHECK_STATUS=$(printf '%s' "$A_CHECK" | jq -r '.status' 2>/dev/null)
A_CHECK_OBS=$(printf '%s' "$A_CHECK" | jq -r '.observations' 2>/dev/null)
assert_eq "A4 THE FIX: cmd_check reports indeterminate, never a false 'fresh'/'stale'" \
    "indeterminate" "$A_CHECK_STATUS"
assert_contains "A3 ...and names the reason (jq/sort failed), not a fabricated verdict" \
    "could not read/parse the ledger" "$A_CHECK_OBS"

MUT_A_CHECK=$(PATH="$FIXTURE/bin:$PATH" bash "$MUT_RM" check --json 2>&1)
MUT_A_CHECK_STATUS=$(printf '%s' "$MUT_A_CHECK" | jq -r '.status' 2>/dev/null)
assert_eq "A5 SPECIFIC MISBEHAVIOUR at cmd_check: mutant A + shim reports 'stale' (db-ahead, exportable) over an UNREAD ledger" \
    "stale" "$MUT_A_CHECK_STATUS"

A_RESTORE=$(bash "$BL" export 2>&1)
assert_contains "A6 RESTORE CONTROL: shipped script, unshimmed (real jq) — the SAME real divergence is STILL correctly flagged" \
    "WOULD BE LOST" "$A_RESTORE"
assert_eq "A7 RESTORE CONTROL: shimmed-and-refused (A2) matches unshimmed-and-refused (A6) verbatim — the guard reports the TRUTH, not 'always refuse when touched'" \
    "$A_RESTORE" "$A_POST"

MUT_A_RESTORE=$(bash "$MUT_RM" export 2>&1)
assert_contains "A8 RESTORE CONTROL: even the MUTANT, unshimmed, is correct — the mutation only bites under the injected fault" \
    "WOULD BE LOST" "$MUT_A_RESTORE"

A_CHECK_CLEAN=$(bash "$BL" check --json 2>&1)
A_CHECK_CLEAN_STATUS=$(printf '%s' "$A_CHECK_CLEAN" | jq -r '.status' 2>/dev/null)
assert_eq "A9 happy-path control: unshimmed, the genuine ledger-ahead case still resolves 'ledger-ahead', not 'indeterminate'" \
    "ledger-ahead" "$A_CHECK_CLEAN_STATUS"

rm -f "$FIXTURE/bin/jq"

# --- SECTION B: parse_failures masking -> the Integrity gate itself --------
echo
echo "--- Section B: a crashing jq inside parse_failures() no longer reads as '0 bad lines' ---"

# Reset to a clean, KNOWN db-ahead shape (Section A left the ledger
# ledger-ahead; this section needs a genuine divergence of its OWN, and
# db-ahead exercises the record-level path parse_failures gates rather than
# re-using A's ledger-ahead state by accident).
bd export -o "$FIXTURE/repo/ledger.jsonl" >/dev/null 2>&1
bd comments add "$TID" "a second progress note" >/dev/null 2>&1

MUT_PF="$FIXTURE/mutants/beads-ledger-mutB.sh"
replace_function "$BL" "parse_failures" "$FIXTURE/orig-parse-failures.txt" > "$MUT_PF"
chmod +x "$MUT_PF"
MUT_PF_HIT="miss"
# shellcheck disable=SC2016  # literal needles, deliberately unexpanded
if grep -qF 'out=$(jq -rR' "$BL" \
    && ! grep -qF 'out=$(jq -rR' "$MUT_PF" \
    && bash -n "$MUT_PF" 2>/dev/null; then
    MUT_PF_HIT="hit"
fi
assert_eq "B0 NON-VACUITY: mutant B landed (parse_failures reverted to the pre-fix single pipe, copy parses)" \
    "hit" "$MUT_PF_HIT"

cat > "$FIXTURE/bin/jq" <<SHIMEOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in *'gsub('*) exit 9 ;; esac
done
exec ${REAL_JQ} "\$@"
SHIMEOF
chmod +x "$FIXTURE/bin/jq"

B_MUTANT=$(PATH="$FIXTURE/bin:$PATH" bash "$MUT_PF" check 2>&1)
assert_contains "B1 SPECIFIC MISBEHAVIOUR: mutant B (pre-fix shape) + the shim is read as the SAME 'stale' verdict a HEALTHY file gets — no integrity-gate refusal at all" \
    "the database is ahead" "$B_MUTANT"

B_POST=$(PATH="$FIXTURE/bin:$PATH" bash "$BL" check --json 2>&1)
B_POST_STATUS=$(printf '%s' "$B_POST" | jq -r '.status' 2>/dev/null)
assert_eq "B2 THE FIX: SHIPPED script now refuses (indeterminate) instead of certifying a partial view" \
    "indeterminate" "$B_POST_STATUS"
assert_contains "B3 ...naming the integrity-gate reason (unparseable line(s)), not silently substituting a count" \
    "not parseable records" "$(printf '%s' "$B_POST" | jq -r '.observations' 2>/dev/null)"

rm -f "$FIXTURE/bin/jq"

B_RESTORE=$(bash "$BL" check --json 2>&1)
B_RESTORE_STATUS=$(printf '%s' "$B_RESTORE" | jq -r '.status' 2>/dev/null)
assert_eq "B4 RESTORE CONTROL: shipped script, unshimmed — the same real state resolves 'stale' again (not 'always refuse')" \
    "stale" "$B_RESTORE_STATUS"

MUT_B_RESTORE=$(bash "$MUT_PF" check --json 2>&1)
MUT_B_RESTORE_STATUS=$(printf '%s' "$MUT_B_RESTORE" | jq -r '.status' 2>/dev/null)
assert_eq "B5 RESTORE CONTROL: even the MUTANT, unshimmed, is correct — the mutation only bites under the injected fault" \
    "stale" "$MUT_B_RESTORE_STATUS"

# --- SECTION C: large ledger-only diff — no spurious SIGPIPE/pipefail trip -
echo
echo "--- Section C: a diff > 5 records does not spuriously trip the comm/head or join/head restructuring ---"

# Clean reset first — a clean matching export, then 7 ledger-only additions,
# so the diff is exactly 7 ledger-only records and nothing left over from
# earlier sections.
bd export -o "$FIXTURE/repo/ledger.jsonl" >/dev/null 2>&1
for i in 1 2 3 4 5 6 7; do
    printf '{"id":"only-in-ledger-%d","comments":[],"updated_at":"2026-01-01T00:00:00Z"}\n' "$i" >> "$FIXTURE/repo/ledger.jsonl"
done
C_OUT=$(bash "$BL" check --json 2>&1)
C_STATUS=$(printf '%s' "$C_OUT" | jq -r '.status' 2>/dev/null)
assert_eq "C1 a 7-record ledger-only diff (> the head -5 cap) still resolves cleanly, never a SIGPIPE-shaped crash" \
    "ledger-ahead" "$C_STATUS"
assert_contains "C2 the observation still names exactly 5 of the 7 (head -5's own cap, unaffected by the restructuring)" \
    "only-in-ledger-5" "$(printf '%s' "$C_OUT" | jq -r '.observations' 2>/dev/null)"
assert_not_contains "C3 ...and does not silently claim all 7" \
    "only-in-ledger-6" "$(printf '%s' "$C_OUT" | jq -r '.observations' 2>/dev/null)"

# reset the ledger back to just the fixture task for the remaining sections
bd export -o "$FIXTURE/repo/ledger.jsonl" >/dev/null 2>&1

# --- SECTION D: sha256_file — extracted, driven directly --------------------
echo
echo "--- Section D: sha256_file never emits a plausible-looking partial hash on a mid-write failure ---"
echo "    (cmd_check's own verdict does not move for this site — see file header; this section drives the"
echo "     EXTRACTED shipped function, which is still leg 4: shipped bytes, not a re-typed copy.)"

SHA_FN="$FIXTURE/sha256_file.sh"
sed -n '/^sha256_file() {/,/^}/p' "$BL" > "$SHA_FN"
assert_eq "D1 NON-VACUITY: the extraction landed (function body is non-empty)" \
    "1" "$( [ -s "$SHA_FN" ] && echo 1 || echo 0 )"
bash -n "$SHA_FN" 2>/dev/null
assert_eq "D2 NON-VACUITY: the extracted copy parses" "0" "$?"

TARGET="$FIXTURE/repo/target-for-hash.txt"
printf 'hello world\n' > "$TARGET"

# A shim that prints a PLAUSIBLE-looking partial hash line, then fails —
# simulating shasum crashing mid-write (OOM, killed) rather than failing
# before printing anything (which was already the non-masked case).
cat > "$FIXTURE/bin/shasum" <<SHIMEOF
#!/bin/bash
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000dead" "\$2"
exit 9
SHIMEOF
chmod +x "$FIXTURE/bin/shasum"

# Non-vacuity probe: confirm the shim itself really does print the plausible
# partial hash before failing (i.e. this is testing a real hazard, not one
# that could never occur because the shim never prints anything).
D_SHIM_RAW=$(PATH="$FIXTURE/bin:$PATH" "$FIXTURE/bin/shasum" -a 256 "$TARGET" 2>/dev/null; true)
assert_contains "D3 NON-VACUITY: the shim genuinely emits a plausible-looking hash line before failing" \
    "0000000000000000000000000000000000000000000000000000000000dead" "$D_SHIM_RAW"

D_MUTANT_OUT=$(PATH="$FIXTURE/bin:$PATH" bash -c ". '$SHA_FN'; sha256_file '$TARGET'")
assert_eq "D4 THE FIX: the extracted (shipped) function discards it and returns EMPTY, never the partial hash" \
    "" "$D_MUTANT_OUT"

D_RESTORE=$(bash -c ". '$SHA_FN'; sha256_file '$TARGET'")
assert_eq "D5 RESTORE CONTROL: unshimmed, the extracted function returns a real 64-hex digest" \
    "64" "${#D_RESTORE}"
EXPECT_HASH=$($REAL_SHASUM -a 256 "$TARGET" 2>/dev/null | awk '{print $1}' || $REAL_SHASUM "$TARGET" 2>/dev/null | awk '{print $1}')
assert_eq "D6 ...and it is the CORRECT digest (matches the real tool directly)" \
    "$EXPECT_HASH" "$D_RESTORE"

rm -f "$FIXTURE/bin/shasum"

# --- SECTION E: count_lines — extracted, driven directly --------------------
echo
echo "--- Section E: count_lines never emits a garbled count from a failing wc/tr tail ---"

CL_FN="$FIXTURE/count_lines.sh"
sed -n '/^count_lines() {/,/^}/p' "$BL" > "$CL_FN"
assert_eq "E1 NON-VACUITY: the extraction landed" "1" "$( [ -s "$CL_FN" ] && echo 1 || echo 0 )"
bash -n "$CL_FN" 2>/dev/null
assert_eq "E2 NON-VACUITY: the extracted copy parses" "0" "$?"

CL_TARGET="$FIXTURE/repo/target-for-count.txt"
printf 'a\nb\nc\n' > "$CL_TARGET"
cat > "$FIXTURE/bin/wc" <<'SHIMEOF'
#!/bin/bash
exit 9
SHIMEOF
chmod +x "$FIXTURE/bin/wc"
E_MUTANT_OUT=$(PATH="$FIXTURE/bin:$PATH" bash -c ". '$CL_FN'; count_lines '$CL_TARGET'")
assert_eq "E3 THE FIX: a failing wc returns EMPTY (distinguishable from a real '0'), never a garbled digit string" \
    "" "$E_MUTANT_OUT"

E_RESTORE=$(bash -c ". '$CL_FN'; count_lines '$CL_TARGET'")
assert_eq "E4 RESTORE CONTROL: unshimmed, the real 3-line count comes back" "3" "$E_RESTORE"

rm -f "$FIXTURE/bin/wc"

# --- Summary -----------------------------------------------------------------
echo
echo "=== beads-ledger.test.sh: summary ==="
echo "Total: $((PASS + FAIL)), Passed: $PASS, Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
exit 0

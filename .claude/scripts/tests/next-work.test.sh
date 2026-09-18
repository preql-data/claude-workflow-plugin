#!/bin/bash
# next-work.test.sh — L1 unit fixture for claude-workflow-plugin-90av: the
# Stop hook's release path hands the session its next ready work instead of
# silently ending it.
#
# THE DEFECT, OPERATOR-REPORTED 2026-09-15 (verbatim): "make sure mechanisms
# for that continuous work are in place in the plugin itself, because it
# bothers me that you keep interrupting like that every time and not picking
# up the next tasks." verify-before-stop.sh always answered exactly one
# question ("may this session stop?") and the ordinary release path (QA
# approved, checks passing) always exited on bare `{}` or a note about an
# unrelated axis (the epic gate, an override, the close hint) — RELEASING
# and FINISHING were indistinguishable. Fixed by compute_next_work() and its
# two call sites in verify-before-stop.sh (search that file for
# "claude-workflow-plugin-90av"): a bounded `bd ready --parent <epic>` query
# that either blocks the Stop with a continuation directive (READY), lets
# the release proceed with an explicit "stopping is correct" sentence
# (NOTHING), or lets the release proceed with a loudly-named disclosure that
# denies being the NOTHING sentence (DEGRADED).
#
# FOUR CONSTRAINTS THIS FILE CHECKS, matching the task brief 1:1:
#   1. MUST NOT WEAKEN THE GATE — Section C's every release-leg sandbox
#      carries a genuine qa-approved + change-set-bound record; the new
#      block never fires without one (C1/C4/C6 all release; none of them
#      relaxes what "released" means).
#   2. MUST DISTINGUISH "NO READY WORK" FROM "COULD NOT COMPUTE READY WORK"
#      — Section A (A2 vs A3/A4/A5/A9), Section B's meta-test (B5), and
#      Section C's end-to-end cross-check (C2 vs C4) all assert this
#      directly: the NOTHING and DEGRADED headlines never share text.
#   3. MUST RESPECT stop_hook_active RE-ENTRY (AgentLint H3) — Section C5.
#   4. MUST BE BOUNDED, via run_with_timeout's own watchdog fallback
#      (claude-workflow-plugin-03tf), never timeout(1) — Section A5 drives
#      a real hang past a real (short) timeout and reads back rc=124.
#
# PAIRING (.claude/tests/README.md, "The pairing requirement"). Every guard
# below carries a mutation with an explicit non-vacuity leg, an assertion
# naming the specific misbehaviour it reproduces, a restore control, and at
# least one leg that OBSERVES THE SHIPPED ARTIFACT RUNNING:
#   Section A — extracted compute_next_work (+ its own dependencies,
#     scoped_log_nonce and run_with_timeout), driven directly against a
#     stubbed bd on PATH. This is "driving the shipped definition" per
#     .claude/tests/README.md's doc-only-classifier.test.sh precedent.
#   Section B — the mutation. Strips the sentinel-wrapped validation span
#     (NEXT-WORK-READY-VALIDATION) back to the naive pre-fix shape (any
#     read failure silently becomes "[]", identical to a genuine empty
#     queue) and proves the SPECIFIC MISBEHAVIOUR the brief names: a bd
#     failure renders as "stopping is correct". B5 is the literal
#     META-TEST the brief requires.
#   Section C — the REAL, unmodified verify-before-stop.sh, driven end to
#     end against a sandboxed project tree with a real qa-approved
#     change-set-bound record, exactly matching override-disclosure.test.
#     sh's own build_sandbox_release/run_stop_hook convention (reproduced
#     here, self-contained, per that file's own stated precedent, rather
#     than importing a file under concurrent edit elsewhere this session).
#
# Sections:
#   A   compute_next_work, extracted and driven directly: ready / nothing /
#       degraded (nonzero rc, malformed JSON, timeout) / blocked-only-queue
#       / bd missing / the direct meta cross-check (A9)
#   B   the mutation: strips NEXT-WORK-READY-VALIDATION; B3 is the specific
#       misbehaviour, B4 is the restore control, B5 is the META-TEST
#   C   the real Stop hook end to end: ready (block) / nothing (release,
#       negative control) / no active epic (silent) / degraded (release,
#       named) / stop_hook_active (exits 0, emits nothing) / blocked-only
#       queue at the full-hook level
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
VBS="$PROJECT_DIR/.claude/scripts/verify-before-stop.sh"
DENY="$PROJECT_DIR/.claude/scripts/workflow-denylist.sh"
CTH="$PROJECT_DIR/.claude/scripts/current-task.sh"
TREE_LEASE="$PROJECT_DIR/.claude/scripts/tree-lease.sh"
IMPACT="$PROJECT_DIR/.claude/scripts/impact-report.sh"

for f in "$VBS" "$DENY" "$IMPACT"; do
    if [ ! -f "$f" ]; then
        printf 'next-work.test: artifact under test missing: %s\n' "$f" >&2
        exit 2
    fi
done

REAL_GIT=$(command -v git) || {
    printf 'next-work.test: git not on PATH\n' >&2
    exit 2
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

# Counts rather than `grep -q`: a haystack piped into `grep -q` closes the
# pipe on first match, which can print a broken-pipe complaint mid-run on a
# large haystack (matching override-disclosure.test.sh / gate-claim-honesty.
# test.sh's own reasoning for the identical helper).
contains_count() {
    # Whitespace-normalising on BOTH sides rather than a raw `grep -F`:
    # NEXT_WORK_TEXT is deliberately hand-wrapped prose (the same
    # convention EPIC_DEFER_NOTE/CLOSE_HINT_NOTE already use throughout
    # verify-before-stop.sh), so a multi-word needle like `Stopping is
    # correct` can legitimately straddle a line break the shipped text
    # inserted for readability -- a plain `grep -F`, which never matches
    # across a newline, would report a real phrase as absent. Two distinct
    # encodings of "line break" both have to collapse to a single space:
    # a REAL newline byte (Section A/B's direct-capture output, `tr -s`'s
    # job) and the LITERAL two-character sequence backslash-n (Section C's
    # output: the Stop hook's own `jq -Rs .` JSON-encodes the same wrapped
    # prose, so the bytes captured from that stdout are backslash then 'n',
    # never a real newline, until something decodes the envelope -- which
    # these assertions deliberately do not do, to also stay honest about
    # asserting on the ACTUAL bytes Claude would receive). Measured
    # directly: C2.3 reported a real, present phrase as absent before this
    # `sed` pass existed, for exactly this reason. Normalising both sides
    # keeps this a content check rather than a line-shape-or-encoding
    # check; a needle's own internal newlines (none in this file) collapse
    # the same way the haystack's do, so the comparison stays symmetric.
    local needle hay
    needle=$(printf '%s' "$1" | sed 's/\\n/ /g' | tr -s '[:space:]' ' ')
    hay=$(printf '%s' "$2" | sed 's/\\n/ /g' | tr -s '[:space:]' ' ')
    printf '%s' "$hay" | grep -cF -- "$needle" 2>/dev/null || true
}

assert_contains() {
    local name="$1" needle="$2" hay="$3" n
    n=$(contains_count "$needle" "$hay" | tr -d '[:space:]')
    if [ "${n:-0}" -gt 0 ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected to CONTAIN: %s\n    actual: %s\n' "$name" "$needle" "$hay"
    fi
}

assert_absent() {
    local name="$1" needle="$2" hay="$3" n
    n=$(contains_count "$needle" "$hay" | tr -d '[:space:]')
    if [ "${n:-0}" -eq 0 ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected NOT to contain: %s (found %s time(s))\n' "$name" "$needle" "$n"
    fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/next-work.XXXXXX")
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# extract_region_fn <src> <fn-name> <out> — extract a top-level function
# definition by an EXACT string match on its signature line ("<fn-name>() {"
# through the matching top-level "}"). Reports a miss (exit 7) so a rename
# cannot turn this file into vacuous passes over an empty extraction
# (.claude/tests/README.md pairing part 1) — same convention as gate-claim-
# honesty.test.sh / override-disclosure.test.sh's own extract_region_fn.
extract_region_fn() {
    local src="$1" fn="$2" out="$3"
    awk -v sig="${fn}() {" '
        $0 == sig { inr = 1; found = 1 }
        inr { print }
        inr && /^}$/ { inr = 0 }
        END { if (!found) exit 7 }
    ' "$src" > "$out"
    local rc=$?
    return "$rc"
}

# ===========================================================================
# Section A: compute_next_work, extracted, driven directly
# ===========================================================================
printf -- '--- Section A: compute_next_work extracted and driven directly ---\n'

extract_region_fn "$VBS" "scoped_log_nonce" "$WORK/a-nonce.sh"
RC_A0_0=$?
extract_region_fn "$VBS" "run_with_timeout" "$WORK/a-rwt.sh"
RC_A0_1=$?
extract_region_fn "$VBS" "compute_next_work" "$WORK/a-cnw-shipped.sh"
RC_A0_2=$?
assert_eq "A0 non-vacuity: all three functions extracted from the shipped (fixed) script" "0 0 0" \
    "$RC_A0_0 $RC_A0_1 $RC_A0_2"
assert_contains "A0b non-vacuity: the shipped extraction carries the R-VALIDATION sentinel" \
    "NEXT-WORK-READY-VALIDATION-BEGIN" "$(cat "$WORK/a-cnw-shipped.sh")"
cat "$WORK/a-nonce.sh" "$WORK/a-rwt.sh" "$WORK/a-cnw-shipped.sh" > "$WORK/a-shipped.sh"
assert_eq "A0c the combined shipped extraction parses" "0" "$(bash -n "$WORK/a-shipped.sh" 2>/dev/null; echo $?)"

# write_bd_stub <bindir> — a bd stub controlled entirely by files under
# $NW_FIXTURE_DIR (an env var the driver exports before invoking), so one
# stub script serves every scenario below without being regenerated per
# case. `ready` prints a fixture-noise warning to stderr on every call,
# mirroring the REAL bd's own behaviour measured while building this fix
# (a clean JSON array on stdout, an unrelated "warning: beads.role not
# configured" line on stderr, every call) — proving compute_next_work's
# `2>/dev/null` on the inner command really does keep the parse clean
# rather than merely being asserted to.
write_bd_stub() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/bd" <<'BD'
#!/bin/bash
case "${1:-}" in
    show)
        cat "$NW_FIXTURE_DIR/show-response.json" 2>/dev/null
        exit 0
        ;;
    ready)
        printf 'warning: beads.role not configured (test fixture noise)\n' >&2
        if [ -f "$NW_FIXTURE_DIR/ready-sleep" ]; then
            sleep "$(cat "$NW_FIXTURE_DIR/ready-sleep")"
        fi
        if [ -f "$NW_FIXTURE_DIR/ready-response" ]; then
            cat "$NW_FIXTURE_DIR/ready-response"
        fi
        exit "$(cat "$NW_FIXTURE_DIR/ready-rc" 2>/dev/null || echo 0)"
        ;;
    *)
        exit 0
        ;;
esac
BD
    chmod +x "$bindir/bd"
}

# run_cnw <extraction-file> <fixture-dir> <epic> <siblings-json> <timeout-s>
# — sources the extraction in a fresh bash -c, calls compute_next_work, and
# prints DECISION plus a delimited TEXT block so the caller can assert on
# both without word-splitting swallowing the newlines NEXT_WORK_TEXT
# carries by design.
run_cnw() {
    local fnfile="$1" fixture="$2" epic="$3" sib="$4" to="$5"
    # NOT folded into the `local` statement above: bash expands every
    # right-hand side of a compound `local a=$1 b="$a/x"` BEFORE performing
    # any of the assignments, so `b` would see `a`'s PRE-statement value
    # (unset, under `set -u` -- an "a: unbound variable" error, not a quiet
    # wrong answer) rather than the one just assigned two tokens earlier.
    local bindir="$fixture/bin"
    mkdir -p "$fixture/qa-tracking"
    write_bd_stub "$bindir"
    NW_FIXTURE_DIR="$fixture" PATH="$bindir:$PATH" QA_TRACKING_DIR="$fixture/qa-tracking" \
        bash -c '
            NEXT_WORK_TIMEOUT_S="$4"
            . "$1"
            compute_next_work "tsk1" "$2" "$3"
            printf "DECISION=%s\n" "$NEXT_WORK_DECISION"
            printf "TEXT_BEGIN>>>\n%s\n<<<TEXT_END\n" "$NEXT_WORK_TEXT"
        ' _ "$fnfile" "$epic" "$sib" "$to"
}

decision_of() { printf '%s' "$1" | grep -m1 '^DECISION=' | cut -d= -f2; }

SIB_2OPEN='{"ok":true,"epic_id":"epic1","siblings":[{"id":"epic1-a","qa":"none","status":"open"},{"id":"epic1-b","qa":"approved","status":"in_progress"}]}'
SIB_2BLOCKED='{"ok":true,"epic_id":"epic1","siblings":[{"id":"epic1-c","qa":"none","status":"blocked"},{"id":"epic1-d","qa":"none","status":"blocked"}]}'

# --- A1: READY --------------------------------------------------------
A1_FIX="$WORK/a1"; mkdir -p "$A1_FIX"
printf '[{"id":"epic1-a","title":"Task A"},{"id":"epic1-b","title":"Task B"}]' > "$A1_FIX/ready-response"
OUT_A1=$(run_cnw "$WORK/a-shipped.sh" "$A1_FIX" "epic1" "$SIB_2OPEN" 5)
assert_eq "A1.0 decision=ready" "ready" "$(decision_of "$OUT_A1")"
assert_contains "A1.1 headline present" "NEXT-WORK: READY" "$OUT_A1"
assert_contains "A1.2 count is correct" "2 ready task(s)" "$OUT_A1"
assert_contains "A1.3 names the first task in the list" "epic1-a: Task A" "$OUT_A1"
assert_contains "A1.4 names the second task in the list" "epic1-b: Task B" "$OUT_A1"
assert_contains "A1.5 continuation directive present" "CONTINUATION DIRECTIVE" "$OUT_A1"
assert_contains "A1.6 directive names the first ready id" 'Delegate epic1-a ("Task A")' "$OUT_A1"
assert_contains "A1.7 epic children disclosure present" "Epic children: 2 remaining open" "$OUT_A1"

# --- A2: NOTHING --------------------------------------------------------
A2_FIX="$WORK/a2"; mkdir -p "$A2_FIX"
printf '[]' > "$A2_FIX/ready-response"
OUT_A2=$(run_cnw "$WORK/a-shipped.sh" "$A2_FIX" "epic1" "$SIB_2OPEN" 5)
assert_eq "A2.0 decision=nothing" "nothing" "$(decision_of "$OUT_A2")"
assert_contains "A2.1 headline present" "NEXT-WORK: NOTHING READY" "$OUT_A2"
assert_contains "A2.2 explicit stopping-is-correct sentence" "Stopping is correct" "$OUT_A2"
assert_absent "A2.3 DISCRIMINATOR: never claims DEGRADED" "DEGRADED" "$OUT_A2"
assert_absent "A2.4 no continuation directive" "CONTINUATION DIRECTIVE" "$OUT_A2"

# --- A3: DEGRADED via nonzero exit --------------------------------------
A3_FIX="$WORK/a3"; mkdir -p "$A3_FIX"
printf '1' > "$A3_FIX/ready-rc"
OUT_A3=$(run_cnw "$WORK/a-shipped.sh" "$A3_FIX" "epic1" "$SIB_2OPEN" 5)
assert_eq "A3.0 decision=degraded" "degraded" "$(decision_of "$OUT_A3")"
assert_contains "A3.1 headline present" "NEXT-WORK: DEGRADED" "$OUT_A3"
assert_contains "A3.2 names the escape: exit code" "bd ready exited 1" "$OUT_A3"
assert_contains "A3.3 error_key present" "error_key=next_work_ready_unavailable" "$OUT_A3"
assert_contains "A3.4 explicitly denies being the NOTHING sentence" "NOT a confirmation that no work is ready" "$OUT_A3"
assert_absent "A3.5 DISCRIMINATOR: never claims NOTHING READY" "NOTHING READY" "$OUT_A3"
assert_absent "A3.6 DISCRIMINATOR: never claims stopping is correct" "Stopping is correct" "$OUT_A3"

# --- A4: DEGRADED via malformed output ----------------------------------
A4_FIX="$WORK/a4"; mkdir -p "$A4_FIX"
printf 'this is not json' > "$A4_FIX/ready-response"
OUT_A4=$(run_cnw "$WORK/a-shipped.sh" "$A4_FIX" "epic1" "$SIB_2OPEN" 5)
assert_eq "A4.0 decision=degraded" "degraded" "$(decision_of "$OUT_A4")"
assert_contains "A4.1 names the escape: unparseable" "does not parse as a JSON array" "$OUT_A4"
assert_absent "A4.2 DISCRIMINATOR: never claims NOTHING READY" "NOTHING READY" "$OUT_A4"

# --- A5: DEGRADED via timeout (constraint 4: the watchdog fallback) -----
A5_FIX="$WORK/a5"; mkdir -p "$A5_FIX"
printf '4' > "$A5_FIX/ready-sleep"
printf '[{"id":"epic1-z","title":"should never be read"}]' > "$A5_FIX/ready-response"
START_A5=$(date +%s 2>/dev/null || echo 0)
OUT_A5=$(run_cnw "$WORK/a-shipped.sh" "$A5_FIX" "epic1" "$SIB_2OPEN" 1)
END_A5=$(date +%s 2>/dev/null || echo 0)
ELAPSED_A5=$((END_A5 - START_A5))
assert_eq "A5.0 decision=degraded" "degraded" "$(decision_of "$OUT_A5")"
assert_contains "A5.1 names the escape: timeout, with the advertised cap" "timed out after 1s" "$OUT_A5"
assert_absent "A5.2 DISCRIMINATOR: never claims NOTHING READY" "NOTHING READY" "$OUT_A5"
# Non-vacuity for the BOUND itself: this call must return well before the
# fixture's 4s sleep would have finished on its own (a 1s cap plus the
# watchdog's own ~2s grace, generously bounded at 8s here for host noise —
# still far under the 4s+ an unbounded wait would need).
assert_eq "A5.3 non-vacuity: the 1s cap actually bounded a 4s hang (elapsed < 8s)" "yes" \
    "$([ "$ELAPSED_A5" -lt 8 ] && echo yes || echo no)"

# --- A6: BLOCKED-ONLY QUEUE — bd ready already excludes them; the epic's
# remaining-children disclosure still counts them (that is disclosure, not
# a readiness claim), but the decision must be NOTHING, never READY.
# --------------------------------------------------------------------
A6_FIX="$WORK/a6"; mkdir -p "$A6_FIX"
printf '[]' > "$A6_FIX/ready-response"
OUT_A6=$(run_cnw "$WORK/a-shipped.sh" "$A6_FIX" "epic1" "$SIB_2BLOCKED" 5)
assert_eq "A6.0 blocked-only queue: decision=nothing, NEVER ready" "nothing" "$(decision_of "$OUT_A6")"
assert_contains "A6.1 the blocked siblings are still disclosed as epic children" "Epic children: 2 remaining open" "$OUT_A6"
assert_absent "A6.2 the blocked ids are never offered as a continuation target" "Delegate epic1-c" "$OUT_A6"
assert_absent "A6.3 ...nor the other one" "Delegate epic1-d" "$OUT_A6"

# --- A7: bd missing entirely ---------------------------------------------
A7_FIX="$WORK/a7"; mkdir -p "$A7_FIX/qa-tracking"
EMPTYBIN="$WORK/a7-emptybin"; mkdir -p "$EMPTYBIN"
OUT_A7=$(NW_FIXTURE_DIR="$A7_FIX" PATH="$EMPTYBIN:/usr/bin:/bin" QA_TRACKING_DIR="$A7_FIX/qa-tracking" \
    bash -c '
        NEXT_WORK_TIMEOUT_S=5
        . "$1"
        compute_next_work "tsk1" "$2" "$3"
        printf "DECISION=%s\n" "$NEXT_WORK_DECISION"
        printf "TEXT_BEGIN>>>\n%s\n<<<TEXT_END\n" "$NEXT_WORK_TEXT"
    ' _ "$WORK/a-shipped.sh" "epic1" "$SIB_2OPEN")
assert_eq "A7.0 decision=degraded when bd is not on PATH" "degraded" "$(decision_of "$OUT_A7")"
assert_contains "A7.1 names the escape: bd missing" "bd is not on PATH" "$OUT_A7"
assert_contains "A7.2 error_key present" "error_key=next_work_bd_missing" "$OUT_A7"

# --- A9: THE DIRECT META-TEST — nothing vs degraded must never share the
# headline that would let one be mistaken for the other.
# --------------------------------------------------------------------
assert_absent "A9.0 META: the NOTHING text (A2) never contains the DEGRADED headline" "NEXT-WORK: DEGRADED" "$OUT_A2"
assert_absent "A9.1 META: the DEGRADED text (A3) never contains the NOTHING headline" "NEXT-WORK: NOTHING READY" "$OUT_A3"
assert_absent "A9.2 META: the blocked-only NOTHING text (A6) never contains the DEGRADED headline either" "NEXT-WORK: DEGRADED" "$OUT_A6"

# ===========================================================================
# Section B: the mutation — strip NEXT-WORK-READY-VALIDATION back to the
# naive pre-fix shape (any read failure silently becomes "[]", the SAME
# literal an actually-empty queue produces) and prove the collapse.
# ===========================================================================
printf -- '\n--- Section B: mutation — the validation span is what keeps DEGRADED from collapsing into NOTHING ---\n'

awk '
    /--- NEXT-WORK-READY-VALIDATION-BEGIN/ {
        print
        print "    ready_ok=true"
        print "    ready_json=$(cat \"$out_log\" 2>/dev/null || echo \"[]\")"
        skip = 1
        next
    }
    /--- NEXT-WORK-READY-VALIDATION-END/ { skip = 0; print; next }
    skip { next }
    { print }
' "$WORK/a-cnw-shipped.sh" > "$WORK/b-cnw-mutant.sh"
assert_eq "B0.0 non-vacuity: the mutant differs from shipped (byte-for-byte)" "differs" \
    "$(diff -q "$WORK/a-cnw-shipped.sh" "$WORK/b-cnw-mutant.sh" >/dev/null 2>&1 && echo identical || echo differs)"
assert_absent "B0.1 non-vacuity: the mutant no longer validates JSON shape at all" \
    "jq -e 'type == \"array\"'" "$(cat "$WORK/b-cnw-mutant.sh")"
cat "$WORK/a-nonce.sh" "$WORK/a-rwt.sh" "$WORK/b-cnw-mutant.sh" > "$WORK/b-mutant.sh"
assert_eq "B0.2 the combined mutant parses" "0" "$(bash -n "$WORK/b-mutant.sh" 2>/dev/null; echo $?)"

# B3: SPECIFIC MISBEHAVIOUR — identical input to A3 (bd ready exits 1, no
# output), driven against the MUTANT. The brief's exact defect: a bd
# failure yielding an empty queue renders as "stopping is correct".
B3_FIX="$WORK/b3"; mkdir -p "$B3_FIX"
printf '1' > "$B3_FIX/ready-rc"
OUT_B3=$(run_cnw "$WORK/b-mutant.sh" "$B3_FIX" "epic1" "$SIB_2OPEN" 5)
assert_eq "B3.0 SPECIFIC MISBEHAVIOUR: mutant reads a bd failure as decision=nothing (WRONG)" "nothing" "$(decision_of "$OUT_B3")"
assert_contains "B3.1 ...and the mutant's OWN text claims stopping is correct over a call that actually failed" \
    "Stopping is correct" "$OUT_B3"
assert_absent "B3.2 ...never naming that anything failed" "DEGRADED" "$OUT_B3"

# B4: RESTORE CONTROL — the shipped (unmutated) extraction, a fresh healthy
# READY input, right beside the mutant's misbehaviour above.
B4_FIX="$WORK/b4"; mkdir -p "$B4_FIX"
printf '[{"id":"epic1-x","title":"Task X"}]' > "$B4_FIX/ready-response"
OUT_B4=$(run_cnw "$WORK/a-shipped.sh" "$B4_FIX" "epic1" "$SIB_2OPEN" 5)
assert_eq "B4.0 RESTORE CONTROL: shipped + healthy ready input, unmutated, still says ready" "ready" "$(decision_of "$OUT_B4")"
assert_contains "B4.1 ...and still names the task" "epic1-x: Task X" "$OUT_B4"

# B5: THE META-TEST, literally as specified in the task brief — "stub the
# ready-work lookup to always return empty and assert 'nothing ready' stays
# distinguishable from the degraded path. If both render identically the
# feature is worse than nothing, because it will confidently say 'done'."
# Drive the MUTANT with a genuinely-empty-healthy input (rc=0, "[]") AND the
# failing input (rc=1) side by side: on the mutant they must be IDENTICAL
# (proving the collapse is real); on the shipped code (already proven via
# A2/A3/A9 above) they are NOT. This is the side-by-side version of that
# same proof.
B5_HEALTHY_FIX="$WORK/b5-healthy"; mkdir -p "$B5_HEALTHY_FIX"
printf '[]' > "$B5_HEALTHY_FIX/ready-response"
B5_FAILING_FIX="$WORK/b5-failing"; mkdir -p "$B5_FAILING_FIX"
printf '1' > "$B5_FAILING_FIX/ready-rc"
OUT_B5_HEALTHY=$(run_cnw "$WORK/b-mutant.sh" "$B5_HEALTHY_FIX" "epic1" "$SIB_2OPEN" 5)
OUT_B5_FAILING=$(run_cnw "$WORK/b-mutant.sh" "$B5_FAILING_FIX" "epic1" "$SIB_2OPEN" 5)
assert_eq "B5.0 META-TEST: on the MUTANT, a genuine empty queue says decision=nothing" "nothing" "$(decision_of "$OUT_B5_HEALTHY")"
assert_eq "B5.1 META-TEST: on the MUTANT, a FAILED lookup ALSO says decision=nothing (the collapse)" "nothing" "$(decision_of "$OUT_B5_FAILING")"
assert_eq "B5.2 META-TEST: the two mutant decisions are the identical string (worse than nothing, per the brief)" \
    "$(decision_of "$OUT_B5_HEALTHY")" "$(decision_of "$OUT_B5_FAILING")"
# Contrast: the SAME two inputs against the SHIPPED code must disagree.
OUT_B5_SHIPPED_HEALTHY=$(run_cnw "$WORK/a-shipped.sh" "$B5_HEALTHY_FIX" "epic1" "$SIB_2OPEN" 5)
OUT_B5_SHIPPED_FAILING=$(run_cnw "$WORK/a-shipped.sh" "$B5_FAILING_FIX" "epic1" "$SIB_2OPEN" 5)
assert_eq "B5.3 META-TEST, THE FIX: shipped code says nothing for the healthy-empty input" "nothing" "$(decision_of "$OUT_B5_SHIPPED_HEALTHY")"
assert_eq "B5.4 META-TEST, THE FIX: shipped code says degraded for the SAME failing input the mutant collapsed" \
    "degraded" "$(decision_of "$OUT_B5_SHIPPED_FAILING")"

# ===========================================================================
# Section C: the REAL Stop hook, end to end
# ===========================================================================
printf -- '\n--- Section C: verify-before-stop.sh, driven for real, epic ready/nothing/degraded/no-epic/stop_hook_active/blocked-only ---\n'

# write_epic_gate_stub <path> — siblings/check/shared-files, with siblings'
# payload read from $NW_FIXTURE_DIR/siblings-response.json so each sandbox
# below can vary epic_id/siblings without a new script.
write_epic_gate_stub() {
    cat > "$1" <<'EG'
#!/bin/bash
case "${1:-}" in
    siblings)
        cat "$NW_FIXTURE_DIR/siblings-response.json" 2>/dev/null
        ;;
    check)
        printf '{"decision":"pass","observations":"fixture: all sub-tasks approved"}'
        ;;
    shared-files)
        printf '{"intersections":[]}'
        ;;
    *)
        exit 0
        ;;
esac
EG
    chmod +x "$1"
}

# build_sandbox_release <root> — a sandbox that releases: GATE_STATUS=
# approved (stubbed qa-gate.sh) plus a change-set-bound `QA-GATE APPROVED`
# record (stubbed `bd show`) whose change_set_hash is PRE-COMPUTED with the
# REAL, copied-in impact-report.sh — reproduced from override-disclosure.
# test.sh's own build_sandbox_release (that file's header explains why this
# is reproduced rather than imported: it is under concurrent edit elsewhere
# this session). `[review bypass:]`/`[design bypass:]` markers skip the
# review-/design-discipline re-checks, which are a different subsystem than
# this fix (claude-workflow-plugin-yrij: `reviewed_by=none` must be the
# literal bypass value the real writer produces, not an arbitrary string).
build_sandbox_release() {
    local root="$1" h
    mkdir -p "$root/.claude/scripts" "$root/.claude/.qa-tracking" "$root/notes" "$root/src" \
        "$root/.beads" "$root/bin" "$root/fixture"
    cp "$VBS" "$DENY" "$IMPACT" "$root/.claude/scripts/"
    [ -f "$CTH" ] && cp "$CTH" "$root/.claude/scripts/"
    [ -f "$TREE_LEASE" ] && cp "$TREE_LEASE" "$root/.claude/scripts/"
    cat > "$root/.claude/scripts/qa-gate.sh" <<'QG'
#!/bin/bash
case "${1:-}" in
  status) printf '{"status":"approved"}\n' ;;
  *) exit 0 ;;
esac
QG
    chmod +x "$root/.claude/scripts/qa-gate.sh"
    cat > "$root/.claude/scripts/detect-stack.sh" <<'DS'
#!/bin/bash
printf '%s' '{"runner":"npm","test_cmd":"true","lint_cmd":"","type_cmd":"","overrides":{"test":false,"lint":false,"type":false}}'
DS
    chmod +x "$root/.claude/scripts/detect-stack.sh"
    write_epic_gate_stub "$root/.claude/scripts/epic-gate.sh"
    printf '.claude/\nnotes/\nbin/\n.beads/\nfixture/\n' > "$root/.gitignore"
    ( cd "$root" \
        && "$REAL_GIT" init -q \
        && "$REAL_GIT" config user.email t@example.com \
        && "$REAL_GIT" config user.name t \
        && printf 'code\n' > src/app.ts \
        && "$REAL_GIT" add .gitignore src >/dev/null \
        && "$REAL_GIT" commit -qm init >/dev/null )
    printf 'x\n' > "$root/notes/impl.ts"
    printf '%s\n' "$root/notes/impl.ts" > "$root/.claude/.qa-tracking/changed-files.txt"
    printf 'tsk1\n' > "$root/.claude/.qa-tracking/current-task"
    h=$(CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null)
    printf '{"comments":[{"text":"QA-GATE APPROVED change_set_hash=%s reviewed_by=none [review bypass: test fixture, nothing to review] [design bypass: test fixture, no design phase]"}]}' \
        "$h" > "$root/fixture/show-response.json"
    write_bd_stub "$root/bin"
}

# run_stop_hook <root> <fixture-dir> [extra-stdin-json] — one real Stop
# fire, NW_FIXTURE_DIR exported so the sandboxed bd/epic-gate stubs can find
# their per-test fixtures. Matches override-disclosure.test.sh's own
# run_stop_hook(root, extra-PATH-dir) convention, generalised with the
# fixture-dir export this file's stubs need.
run_stop_hook() {
    local root="$1" fixture="$2" stdin_json="${3:-}"
    if [ -z "$stdin_json" ]; then
        stdin_json='{"stop_hook_active": false}'
    fi
    ( cd "$root" && printf '%s' "$stdin_json" \
        | NW_FIXTURE_DIR="$fixture" PATH="$root/bin:$PATH" CLAUDE_PROJECT_DIR="$root" \
          bash "$root/.claude/scripts/verify-before-stop.sh" 2>"$WORK/stderr.$$" )
}

# --- C1: READY end to end -------------------------------------------------
SBC1="$WORK/sbc1"
build_sandbox_release "$SBC1"
printf '{"ok":true,"epic_id":"epic1","siblings":[{"id":"epic1-a","qa":"none","status":"open"}]}' \
    > "$SBC1/fixture/siblings-response.json"
printf '[{"id":"epic1-a","title":"Task A"}]' > "$SBC1/fixture/ready-response"
OUT_C1=$(run_stop_hook "$SBC1" "$SBC1/fixture")
assert_contains "C1.0 THE FIX: real hook blocks to hand over the next task" '"decision":"block"' "$OUT_C1"
assert_contains "C1.1 the reason names this as a release, not a rejection" "This is NOT a QA rejection" "$OUT_C1"
assert_contains "C1.2 the headline is present" "NEXT-WORK: READY" "$OUT_C1"
assert_contains "C1.3 names the next task id" "Delegate epic1-a" "$OUT_C1"
assert_absent "C1.4 DISCRIMINATOR: this is not the ordinary QA-required block text" "QA approval required" "$OUT_C1"

# --- C2: NOTHING end to end (negative control) ----------------------------
SBC2="$WORK/sbc2"
build_sandbox_release "$SBC2"
printf '{"ok":true,"epic_id":"epic1","siblings":[{"id":"epic1-a","qa":"approved","status":"closed"}]}' \
    > "$SBC2/fixture/siblings-response.json"
printf '[]' > "$SBC2/fixture/ready-response"
OUT_C2=$(run_stop_hook "$SBC2" "$SBC2/fixture")
assert_absent "C2.0 NEGATIVE CONTROL: no block — the release genuinely proceeds" '"decision":"block"' "$OUT_C2"
assert_contains "C2.1 the release envelope is really present" "QA gate cleared" "$OUT_C2"
assert_contains "C2.2 the headline is present" "NEXT-WORK: NOTHING READY" "$OUT_C2"
assert_contains "C2.3 explicit stopping-is-correct sentence" "Stopping is correct" "$OUT_C2"

# --- C3: no active epic — the feature is silent (mirrors EPIC_DEFER_NOTE) -
SBC3="$WORK/sbc3"
build_sandbox_release "$SBC3"
printf '{"ok":true,"epic_id":null,"siblings":[]}' > "$SBC3/fixture/siblings-response.json"
printf '[{"id":"unrelated-1","title":"should never be reached"}]' > "$SBC3/fixture/ready-response"
OUT_C3=$(run_stop_hook "$SBC3" "$SBC3/fixture")
assert_absent "C3.0 no active epic: no block" '"decision":"block"' "$OUT_C3"
assert_absent "C3.1 no active epic: the feature never fires at all" "NEXT-WORK" "$OUT_C3"

# --- C4: DEGRADED end to end -----------------------------------------------
SBC4="$WORK/sbc4"
build_sandbox_release "$SBC4"
printf '{"ok":true,"epic_id":"epic1","siblings":[{"id":"epic1-a","qa":"none","status":"open"}]}' \
    > "$SBC4/fixture/siblings-response.json"
printf '1' > "$SBC4/fixture/ready-rc"
OUT_C4=$(run_stop_hook "$SBC4" "$SBC4/fixture")
assert_absent "C4.0 degraded still releases — no block" '"decision":"block"' "$OUT_C4"
assert_contains "C4.1 release envelope present" "QA gate cleared" "$OUT_C4"
assert_contains "C4.2 the headline is present" "NEXT-WORK: DEGRADED" "$OUT_C4"
assert_contains "C4.3 error_key present" "error_key=next_work_ready_unavailable" "$OUT_C4"
# END-TO-END META-TEST: C2 (nothing) and C4 (degraded) must never share
# their distinguishing headline.
assert_absent "C4.4 META (end-to-end): degraded output never claims NOTHING READY" "NOTHING READY" "$OUT_C4"
assert_absent "C4.5 META (end-to-end): nothing output (C2) never claims DEGRADED" "DEGRADED" "$OUT_C2"

# --- C5: stop_hook_active=true — constraint 3 ------------------------------
SBC5="$WORK/sbc5"
build_sandbox_release "$SBC5"
printf '{"ok":true,"epic_id":"epic1","siblings":[{"id":"epic1-a","qa":"none","status":"open"}]}' \
    > "$SBC5/fixture/siblings-response.json"
printf '[{"id":"epic1-a","title":"Task A"}]' > "$SBC5/fixture/ready-response"
OUT_C5=$(run_stop_hook "$SBC5" "$SBC5/fixture" '{"stop_hook_active": true}')
assert_eq "C5.0 stop_hook_active=true: emits exactly {} (no re-entry, no next-work text)" "{}" \
    "$(printf '%s' "$OUT_C5" | tr -d '[:space:]')"

# --- C6: blocked-only queue at the full-hook level -------------------------
SBC6="$WORK/sbc6"
build_sandbox_release "$SBC6"
printf '{"ok":true,"epic_id":"epic1","siblings":[{"id":"epic1-c","qa":"none","status":"blocked"},{"id":"epic1-d","qa":"none","status":"blocked"}]}' \
    > "$SBC6/fixture/siblings-response.json"
printf '[]' > "$SBC6/fixture/ready-response"
OUT_C6=$(run_stop_hook "$SBC6" "$SBC6/fixture")
assert_absent "C6.0 blocked-only queue: no block — never offered as ready" '"decision":"block"' "$OUT_C6"
assert_contains "C6.1 renders as NOTHING, not degraded" "NEXT-WORK: NOTHING READY" "$OUT_C6"
assert_contains "C6.2 the blocked siblings are disclosed as epic children" "Epic children: 2 remaining open" "$OUT_C6"
assert_absent "C6.3 the blocked ids never appear as a delegation target" "Delegate epic1-c" "$OUT_C6"

# ===========================================================================
printf '\n=== next-work.test.sh: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'Failed tests:\n'
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0

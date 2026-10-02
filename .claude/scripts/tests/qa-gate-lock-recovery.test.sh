#!/bin/bash
# qa-gate-lock-recovery.test.sh — claude-workflow-plugin-gsfd fix rounds 4
# and 5 (independent cross-family review, R4-F4 and R5-F3).
#
# Direct, executable tests of qa-gate.sh's wipe_iteration_state, EXTRACTED
# from the shipped script by awk (the scoped-log-dir.test.sh / run-with-
# timeout.test.sh convention: driving the shipped DEFINITION rather than a
# re-typed copy free to drift).
#
# THE DEFECTS THIS FILE GUARDS AGAINST:
#
#   R4-F4 (MEDIUM): the per-task cycle-generation counter is protected by
#   an `mkdir`-based lock with no built-in expiry. Before this fix, the
#   lock recorded no holder identity, so if a holder died (SIGKILL, a
#   crash) between acquiring it and releasing it, the lock directory was
#   left behind FOREVER — every later call spent its own ~1s budget
#   failing to acquire it, then proceeded with the read-modify-write
#   UNLOCKED, permanently, from that point on. Broader than the prior
#   comment's "extreme contention" framing disclosed: ONE interrupted
#   holder was enough, not sustained contention. Fixed with stale-lock
#   recovery: the winning `mkdir` now records its own pid inside the lock
#   directory; a waiter whose `mkdir` fails reads that pid and, if it is
#   no longer alive (`kill -0`), removes the stale lock and retries within
#   the SAME bounded loop rather than degrading. This does not need
#   pid-reuse-proof certainty the way tree-lease.sh's own lease identity
#   does — a false "still held" reading here only ever repeats the
#   PRE-fix bounded degradation for one call, never worse, while the
#   common case (a genuinely dead holder) now self-heals.
#
#   R5-F3 (MEDIUM): R4-F4 above only covers a holder that got far enough to
#   record a NUMERIC pid before dying. It missed the ACQUISITION-TO-OWNER-
#   RECORD WINDOW itself — a crash between the winning `mkdir` and its very
#   next line (the pid printf), or a printf that fails outright — which
#   leaves a lock directory with NO valid pid file (absent, or present but
#   empty/garbage). The pre-fix handling of that state was a bare no-op
#   (`''|*[!0-9]*) : ;;`): it neither recovered the lock nor reconsidered it
#   differently later, so an OWNERLESS lock persisted FOREVER — wider than
#   R4-F4's own fix, and the exact defect R4-F4 believed it had already
#   closed. Fixed by treating "no confirmable numeric owner" (whether via
#   an absent or an empty/garbage pid file) as reclaimable after exactly
#   one retry's grace — not on the first sighting, which would risk
#   stealing a lock a genuinely live holder is a few microseconds from
#   legitimately owning.
#
# ASSERTIONS
#   0. The awk extraction defines wipe_iteration_state and parses.
#   1. Baseline: a fresh call (no pre-existing lock) creates the
#      generation file at "1" and leaves no lock directory behind.
#   2. Stale-lock recovery: a lock directory is planted by hand with a
#      GENUINELY DEAD pid recorded inside it (spawned and waited on by
#      this spec, not guessed — see mk_dead_pid below) plus a pre-seeded
#      generation value. The shipped call must still land the correct
#      bump (pre-seeded + 1) and leave no lock directory behind
#      afterward — proving it self-healed rather than degrading.
#   3. Repeated crashes: the SAME stale-lock scenario, 5 consecutive
#      times, each with a freshly-spawned-and-reaped dead pid, checking
#      the generation counter increments by exactly 1 each time and the
#      lock is clean after every call — a race-shaped fix that recovers
#      once proves less than one that recovers every time.
#   META. The stale-lock recovery block is reverted to its pre-fix shape
#      (plain `mkdir`-or-retry, no pid recorded, no recovery) in a mutant
#      copy. The IDENTICAL stale-lock scenario is shown to leave the lock
#      directory behind PERMANENTLY (the bug's own exact symptom) —
#      proving this control discriminates fixed from unfixed.
#   4. R5-F3: a lock directory planted with NO pid file at all (the
#      acquisition-to-owner-record crash). The shipped call must still
#      self-heal — correct bump, no lock directory left behind.
#   5. R5-F3: the same window reached a different way — a lock directory
#      WITH a pid file present but EMPTY (an interrupted write). Same
#      self-heal requirement.
#   6. R5-F3 repeated: the no-pid-file scenario, 5 consecutive times,
#      confirming reliable self-heal rather than a one-off.
#   R5-F3 META. ONLY the R5-F3 branch (not the whole R4-F4 mechanism) is
#      reverted to its pre-fix bare no-op in a surgical mutant, located by
#      line number off two unique anchors rather than a hand-written
#      multi-line pattern. The IDENTICAL no-pid-file scenario is shown to
#      leave the lock directory behind PERMANENTLY, while the call itself
#      still bumps the generation correctly (matches the pre-fix disclosed
#      degradation — never worse, just unprotected against this race) —
#      proving this control discriminates fixed from unfixed for the
#      SPECIFIC R5-F3 property, independent of R4-F4's own coverage above.
#
# Exit codes:
#   0  every assertion passed
#   1  one or more assertions failed
#   2  invocation error (the shipped script is missing, or extraction failed)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
QAG="$PROJECT_DIR/.claude/scripts/qa-gate.sh"

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

if [ ! -f "$QAG" ]; then
    printf 'qa-gate-lock-recovery.test.sh: shipped script missing: %s\n' "$QAG" >&2
    exit 2
fi

WORK=$(mktemp -d -t qa-gate-lock-recovery-test.XXXXXX)
# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

SHIPPED_LIB="$WORK/shipped.sh"
awk '/^wipe_iteration_state\(\) \{/,/^\}/' "$QAG" > "$SHIPPED_LIB"

assert_eq "0.1 the extraction defines wipe_iteration_state" "1" \
    "$(grep -c '^wipe_iteration_state() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"
assert_eq "0.2 the extraction parses" "0" \
    "$(bash -n "$SHIPPED_LIB" 2>/dev/null && echo 0 || echo 1)"

# mk_dead_pid -- prints a pid that WAS real and is now GENUINELY dead:
# spawned, then waited on (reaped), not a guessed large number. Matches
# this whole fix arc's own "confirmed empirically, not assumed" standard,
# and mirrors tree-lease.sh's own tolerance for a false "still held"
# reading being bounded and never worse than the pre-fix behaviour (see
# this file's own header note) -- a PID recycled back to a real process in
# the sub-second window between reap and use is astronomically unlikely
# on a normal system, the same assumption this repo already relies on
# elsewhere.
mk_dead_pid() {
    ( exit 0 ) &
    local p=$!
    wait "$p" 2>/dev/null
    printf '%s' "$p"
}

# plant_stale_lock <tracking-dir> <sanitized-id> <gen-value> -- creates the
# lock directory by hand with a dead pid recorded inside, plus seeds the
# generation file, simulating a holder that crashed after mkdir but before
# ever releasing.
plant_stale_lock() {
    local dir="$1" sid="$2" genval="$3" deadpid
    deadpid=$(mk_dead_pid)
    mkdir -p "$dir"
    mkdir "$dir/qa-cycle-gen.$sid.lock"
    printf '%s' "$deadpid" > "$dir/qa-cycle-gen.$sid.lock/pid"
    printf '%s' "$genval" > "$dir/qa-cycle-gen.$sid"
}

# plant_stale_lock_noowner <tracking-dir> <sanitized-id> <gen-value> -- R5-F3
# scenario: the lock directory exists but NO pid file was ever written
# inside it, simulating a crash (or SIGKILL) between the winning `mkdir`
# succeeding and its very next line (the pid printf) ever running.
plant_stale_lock_noowner() {
    local dir="$1" sid="$2" genval="$3"
    mkdir -p "$dir"
    mkdir "$dir/qa-cycle-gen.$sid.lock"
    printf '%s' "$genval" > "$dir/qa-cycle-gen.$sid"
}

# plant_stale_lock_emptypid <tracking-dir> <sanitized-id> <gen-value> --
# R5-F3 scenario reached a different way: the pid file EXISTS but is empty,
# simulating a printf that opened/truncated the file and was then
# interrupted before writing its content.
plant_stale_lock_emptypid() {
    local dir="$1" sid="$2" genval="$3"
    mkdir -p "$dir"
    mkdir "$dir/qa-cycle-gen.$sid.lock"
    : > "$dir/qa-cycle-gen.$sid.lock/pid"
    printf '%s' "$genval" > "$dir/qa-cycle-gen.$sid"
}

# ---------------------------------------------------------------------------
# 1. Baseline: fresh call, no pre-existing lock.
QA_TRACKING_DIR="$WORK/qt-baseline"
mkdir -p "$QA_TRACKING_DIR"
(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    wipe_iteration_state "faketask1"
)
assert_eq "1a: a fresh call creates the generation file at 1 (0 + 1, no pre-existing state)" \
    "1" "$(cat "$QA_TRACKING_DIR/qa-cycle-gen.faketask1" 2>/dev/null || echo MISSING)"
assert_eq "1b: no lock directory is left behind after an uncontended call" \
    "no" "$([ -d "$QA_TRACKING_DIR/qa-cycle-gen.faketask1.lock" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 2. Stale-lock recovery: a crashed holder's lock, dead pid recorded, plus a
# pre-seeded generation value so the bump is independently checkable.
QA_TRACKING_DIR="$WORK/qt-stale"
plant_stale_lock "$QA_TRACKING_DIR" "faketask2" "5"
STALE_START=$(date +%s%N 2>/dev/null || date +%s)
(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    wipe_iteration_state "faketask2"
)
STALE_END=$(date +%s%N 2>/dev/null || date +%s)
assert_eq "2a: the bump lands correctly on top of a pre-seeded generation despite the stale lock (5 + 1)" \
    "6" "$(cat "$QA_TRACKING_DIR/qa-cycle-gen.faketask2" 2>/dev/null || echo MISSING)"
assert_eq "2b: the stale lock directory is GONE afterward (self-healed: detected dead, removed, reacquired, released its own)" \
    "no" "$([ -d "$QA_TRACKING_DIR/qa-cycle-gen.faketask2.lock" ] && echo yes || echo no)"
# Bounded-recovery sanity: this should self-heal within its first retry
# iteration (~0.1s sleep), nowhere near the ~1s full degraded-path budget.
# Not a hard timing assertion (shared-host scheduling noise), just a loose
# upper bound that would catch a regression back to "waits out the whole
# budget every time."
STALE_ELAPSED_OK="yes"
case "$STALE_START" in
    *[!0-9]*) STALE_ELAPSED_OK="skip" ;;
esac
if [ "$STALE_ELAPSED_OK" = "yes" ] && [ "${#STALE_START}" -gt 10 ]; then
    # nanosecond resolution available (GNU date / modern BSD date)
    STALE_MS=$(( (STALE_END - STALE_START) / 1000000 ))
    assert_eq "2c: recovery happened within a fraction of a second, not the full ~1s degraded budget" \
        "yes" "$([ "$STALE_MS" -lt 800 ] && echo yes || echo no)"
else
    printf '  SKIPPED: 2c (sub-second date resolution unavailable on this platform)\n'
fi

# ---------------------------------------------------------------------------
# 3. Repeated crashes: 5 consecutive stale-lock scenarios, each with a
# freshly spawned-and-reaped dead pid, confirming the counter increments
# by exactly 1 each time and the lock is clean after every single call —
# a race-shaped fix that recovers once proves less than one that recovers
# every time.
QA_TRACKING_DIR="$WORK/qt-repeat"
mkdir -p "$QA_TRACKING_DIR"
REPEAT_OK="yes"
REPEAT_DETAIL=""
i=1
while [ "$i" -le 5 ]; do
    plant_stale_lock "$QA_TRACKING_DIR" "faketaskrep" "$((i - 1))"
    (
        # shellcheck disable=SC1090
        . "$SHIPPED_LIB"
        wipe_iteration_state "faketaskrep"
    )
    GOT=$(cat "$QA_TRACKING_DIR/qa-cycle-gen.faketaskrep" 2>/dev/null || echo MISSING)
    if [ "$GOT" != "$i" ]; then
        REPEAT_OK="no"
        REPEAT_DETAIL="round $i: expected $i, got $GOT"
        break
    fi
    if [ -d "$QA_TRACKING_DIR/qa-cycle-gen.faketaskrep.lock" ]; then
        REPEAT_OK="no"
        REPEAT_DETAIL="round $i: lock directory not cleaned up"
        break
    fi
    i=$((i + 1))
done
assert_eq "3: five consecutive simulated crashes each correctly self-heal, generation incrementing sequentially (1,2,3,4,5)${REPEAT_DETAIL:+ -- $REPEAT_DETAIL}" \
    "yes" "$([ "$REPEAT_OK" = "yes" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# META: revert the stale-lock recovery to its pre-fix shape (plain mkdir
# retry, no pid recorded, no recovery) in a mutant copy, via awk (a
# single-line sed can't express a multi-line block swap). Anchored on the
# `for _gli in 1 2 3 4 5 6 7 8 9 10; do` line AND the loop's own matching
# `        done` (8-space indented, confirmed unique the same way, before
# relying on it), tracking entry/exit rather than a hardcoded line count to
# skip. R5-F3 (round 5) is exactly why the hardcoded-count shape this
# replaced was wrong to trust: that fix grew the loop body from 14 lines to
# 19, and the fixed `skip_remaining = 14` this awk script used to hard-code
# then stopped consuming the ORIGINAL loop partway through, leaking its own
# tail into the "mutant" after the 4-line replacement -- a real, measured
# regression in THIS control caught by re-running it after the R5-F3 change,
# not assumed safe because it worked before (the diff count read 17, not
# 13, and the resulting mutant failed `bash -n`). Anchoring on the loop's
# own boundaries instead of its current length means a future change to
# what is inside the loop cannot silently re-break this control the same way.
MUT_LIB="$WORK/mut.sh"
awk '
BEGIN { in_loop = 0 }
!in_loop && /for _gli in 1 2 3 4 5 6 7 8 9 10; do/ {
    print "        for _gli in 1 2 3 4 5 6 7 8 9 10; do"
    print "            mkdir \"$gen_lock\" 2>/dev/null && { gen_lock_held=\"yes\"; break; }"
    print "            sleep 0.1"
    print "        done"
    in_loop = 1
    next
}
in_loop && /^        done$/ { in_loop = 0; next }
in_loop { next }
{ print }
' "$SHIPPED_LIB" > "$MUT_LIB"
DIFF_MUT=$(diff "$SHIPPED_LIB" "$MUT_LIB" | grep -c '^[<>]')
assert_eq "META: the mutation landed as a real, meaningful block swap (non-vacuity; 19 lines out, 1 in — measured via diff at this change set, not assumed)" \
    "20" "$DIFF_MUT"
MUT_PARSE=0
bash -n "$MUT_LIB" 2>/dev/null || MUT_PARSE=$?
assert_eq "META: the mutant copy still parses" "0" "$MUT_PARSE"

QA_TRACKING_DIR="$WORK/qt-stale-mut"
plant_stale_lock "$QA_TRACKING_DIR" "faketask2mut" "5"
(
    # shellcheck disable=SC1090
    . "$MUT_LIB"
    wipe_iteration_state "faketask2mut"
)
assert_eq "META: WITHOUT stale-lock recovery, the identical crashed-holder scenario leaves the lock directory behind PERMANENTLY (the bug's own exact symptom, reproduced on demand)" \
    "yes" "$([ -d "$QA_TRACKING_DIR/qa-cycle-gen.faketask2mut.lock" ] && echo yes || echo no)"
assert_eq "META: the mutant still bumps the generation for THIS single call (matches the pre-fix disclosed degradation -- never worse, just unprotected against races)" \
    "6" "$(cat "$QA_TRACKING_DIR/qa-cycle-gen.faketask2mut" 2>/dev/null || echo MISSING)"

# ---------------------------------------------------------------------------
# 4. R5-F3: the acquisition-to-owner-record window, no pid file at all (the
# lock directory exists, nothing inside it -- a crash between the winning
# mkdir and its very next line, before this fix's own predecessor even had
# a chance to look for a numeric pid to check).
QA_TRACKING_DIR="$WORK/qt-noowner"
plant_stale_lock_noowner "$QA_TRACKING_DIR" "faketask4" "9"
(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    wipe_iteration_state "faketask4"
)
assert_eq "4a: the bump lands correctly despite a lock with NO pid file at all (9 + 1)" \
    "10" "$(cat "$QA_TRACKING_DIR/qa-cycle-gen.faketask4" 2>/dev/null || echo MISSING)"
assert_eq "4b: the ownerless lock directory is GONE afterward (self-healed, not left permanently)" \
    "no" "$([ -d "$QA_TRACKING_DIR/qa-cycle-gen.faketask4.lock" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 5. R5-F3: the same window reached a different way -- a pid file that
# EXISTS but is empty (an interrupted write landed the file, not its
# content). Must be recovered identically to the no-file case above.
QA_TRACKING_DIR="$WORK/qt-emptypid"
plant_stale_lock_emptypid "$QA_TRACKING_DIR" "faketask5" "2"
(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    wipe_iteration_state "faketask5"
)
assert_eq "5a: the bump lands correctly despite a lock with an EMPTY pid file (2 + 1)" \
    "3" "$(cat "$QA_TRACKING_DIR/qa-cycle-gen.faketask5" 2>/dev/null || echo MISSING)"
assert_eq "5b: the empty-pid lock directory is GONE afterward (self-healed, not left permanently)" \
    "no" "$([ -d "$QA_TRACKING_DIR/qa-cycle-gen.faketask5.lock" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 6. R5-F3 repeated: the no-pid-file scenario, 5 consecutive times -- a
# race-shaped fix that recovers once proves less than one that recovers
# every time (mirrors section 3's own reasoning for the R4-F4 case).
QA_TRACKING_DIR="$WORK/qt-noowner-repeat"
mkdir -p "$QA_TRACKING_DIR"
REPEAT6_OK="yes"
REPEAT6_DETAIL=""
i=1
while [ "$i" -le 5 ]; do
    plant_stale_lock_noowner "$QA_TRACKING_DIR" "faketaskrep6" "$((i - 1))"
    (
        # shellcheck disable=SC1090
        . "$SHIPPED_LIB"
        wipe_iteration_state "faketaskrep6"
    )
    GOT6=$(cat "$QA_TRACKING_DIR/qa-cycle-gen.faketaskrep6" 2>/dev/null || echo MISSING)
    if [ "$GOT6" != "$i" ]; then
        REPEAT6_OK="no"
        REPEAT6_DETAIL="round $i: expected $i, got $GOT6"
        break
    fi
    if [ -d "$QA_TRACKING_DIR/qa-cycle-gen.faketaskrep6.lock" ]; then
        REPEAT6_OK="no"
        REPEAT6_DETAIL="round $i: lock directory not cleaned up"
        break
    fi
    i=$((i + 1))
done
assert_eq "6: five consecutive no-pid-file crashes each correctly self-heal, generation incrementing sequentially (1,2,3,4,5)${REPEAT6_DETAIL:+ -- $REPEAT6_DETAIL}" \
    "yes" "$([ "$REPEAT6_OK" = "yes" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# R5-F3 META: revert ONLY the R5-F3 branch (not the whole R4-F4 mechanism
# the META above already covers) to its pre-fix bare no-op, in a surgical
# mutant located by line number off two anchors that are each independently
# unique in the shipped extraction -- a hand-written multi-line sed/awk
# pattern over this block's own nested quoting (a bash case pattern
# containing '', inside a printf, inside this test's own quoting) is exactly
# the kind of fragile-transcription risk this file's OTHER meta mutant
# avoids by anchoring on a single unique line instead; this one needs two
# (the branch's own pattern line, and the grace-check line six lines later)
# because the region being collapsed spans a comment block in between.
# -Fx (fixed string, whole-LINE match), not a bare substring grep: this
# exact case-pattern text is ALSO quoted verbatim in this function's own
# header comment above (documenting the pre-fix shape it replaced), so a
# plain substring search matches that prose FIRST and anchors on the wrong
# line entirely -- caught by actually running this section, not assumed
# correct because the pattern "looked" unique. -x requires the whole line
# to match nothing else on it, which the comment's copy (surrounded by a
# leading "# (\`" and trailing text) never satisfies.
R3_START=$(grep -Fxn "                ''|*[!0-9]*)" "$SHIPPED_LIB" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016  # single quotes intentional: this is a literal
# grep search pattern, not a string meant to expand $_gli here.
R3_GRACE=$(grep -nF '[ "$_gli" != "1" ]' "$SHIPPED_LIB" | head -1 | cut -d: -f1)
assert_eq "R5-F3 META precondition: the case-pattern anchor is found EXACTLY once as a whole line (non-vacuity: distinguishes the real code from this function's own header comment quoting the same text)" \
    "1" "$(grep -Fxc "                ''|*[!0-9]*)" "$SHIPPED_LIB" | tr -d '[:space:]')"
# shellcheck disable=SC2016  # single quotes intentional: literal search pattern.
assert_eq "R5-F3 META precondition: the grace-check anchor is found exactly once" \
    "1" "$(grep -Fc '[ "$_gli" != "1" ]' "$SHIPPED_LIB" | tr -d '[:space:]')"
R3_END=$((R3_GRACE + 1))
MUT2_LIB="$WORK/mut-r5f3.sh"
{
    sed -n "1,$((R3_START - 1))p" "$SHIPPED_LIB"
    printf '%s\n' "                ''|*[!0-9]*) : ;;"
    sed -n "$((R3_END + 1)),\$p" "$SHIPPED_LIB"
} > "$MUT2_LIB"
DIFF_MUT2=$(diff "$SHIPPED_LIB" "$MUT2_LIB" | grep -c '^[<>]')
assert_eq "R5-F3 META: the mutation landed as a real, meaningful block swap (non-vacuity; 7 lines out, 1 in)" \
    "8" "$DIFF_MUT2"
MUT2_PARSE=0
bash -n "$MUT2_LIB" 2>/dev/null || MUT2_PARSE=$?
assert_eq "R5-F3 META: the mutant copy still parses" "0" "$MUT2_PARSE"
# The R4-F4 mechanism (numeric dead-pid recovery) must be UNTOUCHED by this
# surgical revert -- confirmed directly rather than assumed, so this META
# is provably isolated to the R5-F3 property and not silently re-testing
# R4-F4's own coverage above.
# shellcheck disable=SC2016  # single quotes intentional: literal fixed
# string for grep -F, not a string meant to expand $_gl_holder/$gen_lock
# here -- an earlier draft of this line used backslash-escaped `\$` inside
# these same single quotes, which is a no-op in single-quote context (the
# backslash is not special there) and happened to still match only because
# grep's own BRE treats a bare `\$` as a literal dollar sign; -F removes
# that ambiguity entirely rather than relying on it.
assert_eq "R5-F3 META precondition: the R4-F4 branch (kill -0 dead-pid recovery) is untouched by this surgical mutant" \
    "1" "$(grep -Fc 'kill -0 "$_gl_holder" 2>/dev/null || rm -rf "$gen_lock"' "$MUT2_LIB" | tr -d '[:space:]')"

QA_TRACKING_DIR="$WORK/qt-noowner-mut"
plant_stale_lock_noowner "$QA_TRACKING_DIR" "faketask4mut" "9"
(
    # shellcheck disable=SC1090
    . "$MUT2_LIB"
    wipe_iteration_state "faketask4mut"
)
assert_eq "R5-F3 META: WITHOUT this fix, the identical no-pid-file scenario leaves the lock directory behind PERMANENTLY (the bug's own exact symptom, reproduced on demand)" \
    "yes" "$([ -d "$QA_TRACKING_DIR/qa-cycle-gen.faketask4mut.lock" ] && echo yes || echo no)"
assert_eq "R5-F3 META: the mutant still bumps the generation for THIS single call (matches the pre-fix disclosed degradation -- never worse, just unprotected against this race)" \
    "10" "$(cat "$QA_TRACKING_DIR/qa-cycle-gen.faketask4mut" 2>/dev/null || echo MISSING)"

printf '\nTotal: %d assertion(s)\n' "$((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

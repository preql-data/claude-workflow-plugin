#!/bin/bash
# runner-completeness.test.sh — the paired negative control for the L1 and L2
# runners' completeness lines (claude-workflow-plugin-a9hh, -mwrb).
#
# THE SUBJECT IS THE INSTRUMENT. Every discipline this repo has built — "read
# the completeness line, never the absence of FAIL"; "a measurement that did
# not happen must not look like one that passed" — is read through two
# runners: .claude/scripts/tests/run-tests.sh (L1) and
# .claude/tests/component/run.sh (L2). Their summary lines are CLAIMS, and
# a9hh measured the claims unfalsifiable: in CI-shaped environments six L1
# specs exited 0 having executed zero assertions (286 of 2461 assertions,
# 11.6% of the tier) and the line read `Total: 35  Passed: 35  Failed: 0` —
# byte-identical to a full run, rc=0. Deleting 20 of the spec files shrank the
# claim to match the shrunken world. And a spec that HANGS produces no line
# at all (mwrb, measured three times) — the one state "read the line" cannot
# answer.
#
# This spec is the four-part pair (.claude/tests/README.md, "The pairing
# requirement") for the floor and the outcome classification:
#   1. NON-VACUITY — mutations proven to land: fixtures that shrink the
#      discovered set / skip / hang / background-and-exit (state mutations,
#      observed hitting), and ELEVEN excision MUTANTS of the shipped runners —
#      L1 un-floored, L1 without the section refusal, L1 and L2 without the
#      survivor sweep, L1 and L2 without the telemetry disarm (R3-F1), L1
#      and L2 with the spec stdin redirect stripped (R3-F2), L1 without the
#      transcript-fail arm (R4-F2), L2 without the filter zero-match guard
#      (R4-F3/R5-F2), and L2 without its accounting (summary trap +
#      failed-accounting arms, excised together — R4-F1) — each verified
#      by awk found-check + byte-comparison + bash -n.
#   2. SPECIFIC MISBEHAVIOUR — each mutant prints the exact green line
#      (`Total: N  Passed: N  Failed: 0`, rc=0) over a world the shipped
#      runner refuses, naming the leg that catches it.
#   3. RESTORE CONTROL — the shipped runners, same call shape, full fixtures,
#      exiting 0 with the floor HELD (including a spec that backgrounds work
#      and REAPS it: concurrency is not the offence, leaving it live is).
#   4. EXECUTION — every leg DRIVES a shipped runner byte-for-byte from its
#      real path; nothing here greps a script's text to prove behaviour
#      (the one sed that reads EXPECTED_SPECS parameterises a fixture, it
#      proves nothing).
#
# Outcome contract pinned here (three outcomes, three reasons):
#   a skip is never a pass; a timeout is never a skip; a timeout is a FAILURE
#   with a distinct reason; a hung spec cannot hold a tier open (the tree is
#   killed, orphans included — even a `trap '' TERM` tree, R2-F3); a spec
#   that returns while background work from its group is still live is a
#   FAILURE, and the work is killed, not orphaned (R2-F2); a filter that
#   matches nothing is an invocation error, not a green run — in BOTH
#   runners (R4-F3/R5-F2); a FAIL: line in a transcript is a FAILURE no
#   matter what the exit code says (R4-F2); an early exit cannot convert a
#   failing spec into a skip, nor vanish executed assertions (R4-F1); an
#   interrupt reaps the active spec's whole tree, out-of-group descendants
#   included (R4-F4).

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

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle not found: %s\n' "$name" "$needle"
        # The haystack, truncated, so a failure names what the subject
        # ACTUALLY said (a bd reword used to redden 10.11/10.12 with no way
        # to see bd's real output short of re-running by hand). Every line
        # is prefixed '| ' so quoted runner output can never present a
        # line-initial PASS:/FAIL:/SKIPPED:/note: shape to the outer
        # runner's anchors.
        printf '%s\n' "$haystack" | head -12 | sed 's/^/    | /'
    fi
}

assert_absent() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle unexpectedly present: %s\n' "$name" "$needle"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    fi
}

PLUGIN_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
L1_RUNNER="$PLUGIN_DIR/.claude/scripts/tests/run-tests.sh"
L2_RUNNER="$PLUGIN_DIR/.claude/tests/component/run.sh"
L2_LIB="$PLUGIN_DIR/.claude/tests/component/lib"

WORK=$(mktemp -d -t runner-completeness.XXXXXX)

# ---------------------------------------------------------------------------
# PER-RUN ORPHAN TOKEN (R1-F2). The hang legs below have to ask "did the
# blocking child survive?", and the obvious probe — `pgrep -f 'sleep 31337'` —
# is MACHINE-GLOBAL: any other process on the host holding that literal turns
# this spec red, and the most likely such process is a SECOND CONCURRENT RUN
# OF THIS SAME TIER. That is routine here (orchestrator and QA both running
# L1), and LESSONS records the class four times (claude-workflow-plugin-1nz:
# live-repo assertions failing under any concurrent writer). It fails safe,
# but this spec is the trust anchor for both runners, and a control that cries
# wolf is a control people re-run instead of read.
#
# So the blocking child carries a token unique to THIS process, set as its
# argv[0] via `exec -a`, and the probes match the token. Same fix shape as the
# prior art one file over: impact-report.test.sh:314 scopes its orphan pgrep
# to the per-run fixture path.
#
# The decoy below is what makes that scoping a CHECKED property rather than an
# intention — see section 5.
HANG_TOKEN="rc-orphan-$$-$(date +%s)"
DECOY_PID=""
DECOY_PID_L2=""

# reap_respawn_orphans — claude-workflow-plugin-j7kk. The R6 respawn-pair
# legs further down (mk_respawn_pair / the int/cap/l2c legs) deliberately
# create a setsid'd shell PLUS a TERM-trap-spawned child that are, BY DESIGN,
# outside every process group this file or the runner it drives can reach by
# group-kill — that is the exact escapee shape those legs exist to reproduce.
# Each leg's own inline `pkill -9 -f` immediately after its assertions is the
# FAST path and is unchanged. This function is the SLOW path: called from the
# EXIT trap (below) so a leg that errors out, or a run interrupted (any
# signal SIGKILL cannot pre-empt) between "spawn" and its own pkill line,
# still cannot leave one of these alive after this file's process exits.
#
# Found necessary by direct observation, not by reasoning about the code in
# the abstract: nine such processes (three respawn pairs' worth, i.e. every
# tag, from three separate historical $WORK directories, none matching the
# run that found them) were discovered still resident — sleeping, ppid=1,
# ordinary group leaders — days after whatever run created them, which only
# fits an interrupted-before-its-own-cleanup run of this exact section (a
# hard-killed enclosing process is the one thing even this sweep cannot reach
# either, which is why the fast path per leg remains the primary defence and
# this is explicitly the second one, not a replacement for it).
#
# Patterns match on the SHARED prefix each tag's own pkill already uses
# (`$WORK/r6-outer-<tag>.sh`, `$HANG_TOKEN-resp-<tag>`) so one sweep call
# covers whichever tags got as far as spawning, however far the section got.
# `-f` matches the full command line, which survives the exec'd process even
# after `$WORK` is removed — this function never removes it itself, so it is
# safe to call standalone (see the pairing test right below it) as well as
# from cleanup(), which calls it before its own `rm -rf "$WORK"`.
reap_respawn_orphans() {
    if [ -n "${WORK:-}" ]; then
        pkill -9 -f "$WORK/r6-outer-" 2>/dev/null || true
    fi
    if [ -n "${HANG_TOKEN:-}" ]; then
        pkill -9 -f "$HANG_TOKEN-resp-" 2>/dev/null || true
    fi
    return 0
}

# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    [ -n "$DECOY_PID" ] && kill "$DECOY_PID" 2>/dev/null
    [ -n "$DECOY_PID_L2" ] && kill "$DECOY_PID_L2" 2>/dev/null
    reap_respawn_orphans
    [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pairing for reap_respawn_orphans, run NOW (before $WORK exists in earnest,
# and long before the R6 legs that motivate it) so a failure here is
# attributed to the sweep itself rather than to whatever fixture state the
# rest of the file has built up by the time section 12h runs.
#
# NEGATIVE CONTROL FIRST: spawn a decoy shaped exactly like an R6 orphan
# (setsid, argv matching both patterns) and show it is genuinely alive and
# that killing it by PID (not by the sweep) is possible — establishing the
# decoy is real before trusting anything the sweep reports about it.
# ---------------------------------------------------------------------------
if command -v perl >/dev/null 2>&1; then
    # The decoy lives under $WORK itself, matching the EXACT pattern
    # reap_respawn_orphans matches on the real R6 legs (`$WORK/r6-outer-`).
    REAP_TAG="reap-probe"
    REAP_OUTER_W="$WORK/r6-outer-$REAP_TAG.sh"
    printf '#!/bin/bash\nexec -a %s-resp-%s sleep 31607\n' "$HANG_TOKEN" "$REAP_TAG" \
        > "$WORK/reap-child-$REAP_TAG.sh"
    {
        printf '#!/bin/bash\n'
        printf 'trap '\''bash "%s/reap-child-%s.sh" &'\'' TERM\n' "$WORK" "$REAP_TAG"
        printf 'while :; do sleep 1; done\n'
    } > "$REAP_OUTER_W"
    perl -MPOSIX -e 'POSIX::setsid(); exec "bash",$ARGV[0]' "$REAP_OUTER_W" &
    disown 2>/dev/null || true
    REAP_SEEN="no"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$REAP_OUTER_W" >/dev/null 2>&1 && { REAP_SEEN="yes"; break; }
        sleep 1
    done
    assert_eq "reap-pair non-vacuity: the decoy outer shell is alive before the sweep runs" \
        "yes" "$REAP_SEEN"

    reap_respawn_orphans
    sleep 1
    assert_eq "reap-pair: reap_respawn_orphans kills the outer shell (the R6-shaped escapee)" \
        "gone" "$(pgrep -f "$REAP_OUTER_W" >/dev/null 2>&1 && echo alive || echo gone)"

    # RESTORE CONTROL / non-vacuity for the OTHER half: a process that does
    # NOT match either pattern must survive the sweep, or this function would
    # be a generic (and dangerous) kill-everything call rather than a
    # targeted one.
    perl -MPOSIX -e 'POSIX::setsid(); exec "sleep","31607"' &
    UNRELATED_PID=$!
    disown 2>/dev/null || true
    sleep 1
    reap_respawn_orphans
    sleep 1
    assert_eq "reap-pair CONTROL: an UNRELATED setsid'd process (matching neither pattern) survives the sweep" \
        "alive" "$(kill -0 "$UNRELATED_PID" 2>/dev/null && echo alive || echo gone)"
    kill -9 "$UNRELATED_PID" 2>/dev/null || true
else
    printf '  note: reap_respawn_orphans pairing SKIPPED - needs perl (same precondition as the R6 legs it protects)\n'
fi

# The floor constant, read out of the shipped runner to PARAMETERISE the
# fixtures below (this is sizing, not proof — the proof legs all RUN the
# runner). If the constant moves, the fixtures move with it.
#
# claude-workflow-plugin-gytz (second round): EXPECTED_SPECS stopped being a
# bare integer literal (`EXPECTED_SPECS=71`) and became a derived expression
# (`EXPECTED_SPECS=${#EXPECTED_SPEC_FILES[@]}`) — the OLD single-line regex
# below this comment used to anchor on `^EXPECTED_SPECS=([0-9]+)$` and would
# now silently match NOTHING (an integer-shaped RHS no longer exists in the
# source at all), so this reads the array's OWN declaration instead: every
# non-empty line strictly between the EXPECTED-SPEC-FILES sentinel pair is
# one declared spec name. L1_REAL_SPEC_NAMES (an actual bash array, not just
# a count) is kept too — sections 19 below build fixtures out of THIS repo's
# own real spec names, not synthetic stubs, specifically to exercise the
# manifest comparison meaningfully.
L1_REAL_SPEC_NAMES=()
while IFS= read -r __name; do
    L1_REAL_SPEC_NAMES+=("$__name")
done < <(awk '
    /^EXPECTED_SPEC_FILES=\($/ { infiles=1; next }
    infiles && /^\)$/            { exit }
    infiles && NF                { print }
' "$L1_RUNNER" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
EXPECTED=${#L1_REAL_SPEC_NAMES[@]}
if ! printf '%s' "$EXPECTED" | grep -qE '^[0-9]+$' || [ "$EXPECTED" -lt 2 ]; then
    printf 'FAIL: could not read EXPECTED_SPEC_FILES from %s (got %d name(s))\n' "$L1_RUNNER" "$EXPECTED"
    exit 1
fi

# EXPECTED_SPEC_FILES_STRICT=0, EXPORTED HERE, ONCE, FOR THE WHOLE SCRIPT.
# Discovered necessary fixing claude-workflow-plugin-gytz R2-F2: run-tests.sh's
# own default for this variable is 1 (strict — the completeness floor's
# identity comparison against EXPECTED_SPEC_FILES runs unconditionally and
# can fail the tier on its own; see that file's Environment: header and its
# COMPLETENESS-FLOOR block). That default is correct for every REAL
# invocation, but this spec's OWN sections — dozens of them, built across
# many rounds predating R2-F2 — drive $L1_RUNNER (or an L1-family mutant)
# against fixtures sized to $EXPECTED with GENERIC stub-NNN.sh names, to
# test UNRELATED runner mechanics (timeouts, signals, telemetry disarm,
# lease handling, ...), never claiming to model this repo's real spec
# inventory. Under the strict default, EVERY one of those fixtures breaches
# on "COUNTS MATCH but the SETS DO NOT" — proven by running the full suite
# once with the naive unconditional fix and watching failures start at
# section 1 and recur throughout, none of them anywhere near the R2-F2 fix
# itself. Exporting the OFF value here, ONCE, covers every subprocess this
# script spawns — through run_l1/run_l1_env_bdactor/run_l1_capped AND the
# many places that invoke $L1_RUNNER or a mutant directly — without
# touching each call site's own logic or renaming any fixture. The few
# sections that build REAL-named fixtures specifically to exercise the
# strict comparison (19a/19b/19e, 20a-20d) override back to ON at their own
# call site (`EXPECTED_SPEC_FILES_STRICT=1 <command>`), a plain prefix
# assignment that shadows this export for exactly that one command and its
# subprocess, then reverts — verified empirically, not assumed, before this
# was written this way: an exported base value, a prefix override on one
# call, a plain call after it, and the plain call sees the base value
# again, never the override.
export EXPECTED_SPEC_FILES_STRICT=0

# mk_l1_fixture <root> <n-passing-stubs> — a project root whose L1 tests dir
# holds exactly <n> fast, honestly-passing stubs (each emits one PASS: line).
mk_l1_fixture() {
    local root="$1" n="$2" i=1
    mkdir -p "$root/.claude/scripts/tests"
    while [ "$i" -le "$n" ]; do
        printf '#!/bin/bash\nprintf "  PASS: stub-%d ran\\n"\nexit 0\n' "$i" \
            > "$root/.claude/scripts/tests/stub-$(printf '%03d' "$i").sh"
        i=$((i + 1))
    done
}

run_l1() {
    # run_l1 <fixture-root> [runner-path] [args...] — drives a runner with the
    # fixture as project root. Captures stdout+stderr in RUN_OUT, rc in RUN_RC.
    #
    # STRICT_SECTIONS=0 IS PINNED, NOT INHERITED. This spec runs INSIDE the
    # tier, and the CI l1-unit job sets STRICT_SECTIONS=1 for the whole job —
    # so an unpinned call would take its verdict from the ambient environment
    # and the legs that mean "strict OFF" would go red in CI and green on a
    # laptop. Measured, not theorised: leg 8.5 failed exactly that way on the
    # first CI-shaped run of this file. The legs that mean "strict ON" set it
    # themselves, explicitly, at their own call site.
    #
    # EXPECTED_SPEC_FILES_STRICT is NOT pinned here, unlike STRICT_SECTIONS
    # above — it does not need to be. Nothing but this file's own top-level
    # `export EXPECTED_SPEC_FILES_STRICT=0` (see its header, right after
    # $EXPECTED is derived) ever sets it, so plain inheritance through the
    # command substitution below already gives every ordinary call the
    # legacy, count-only floor comparison its generic-named fixture needs.
    # The sections that need the real, strict comparison instead
    # (19a/19b/19e, built from real spec basenames via mk_l1_fixture_named)
    # override it at their own call site — `EXPECTED_SPEC_FILES_STRICT=1
    # run_l1 ...` — a plain prefix assignment that shadows the export for
    # exactly that one call and reverts after, same mechanism STRICT_SECTIONS
    # would use if any leg here needed strict sections AND legacy floor
    # semantics together (none currently do).
    local root="$1"; shift
    local runner="${1:-$L1_RUNNER}"; shift || true
    RUN_OUT=$(CLAUDE_PROJECT_DIR="$root" STRICT_SECTIONS=0 bash "$runner" "$@" 2>&1)
    RUN_RC=$?
}

# ===========================================================================
printf -- '--- 1. RESTORE CONTROL first: the shipped L1 runner, a full honest set, green with the floor HELD ---\n'
# ===========================================================================
FX_FULL="$WORK/l1-full"
mk_l1_fixture "$FX_FULL" "$EXPECTED"
run_l1 "$FX_FULL"
assert_eq "1.1 shipped runner over a full honest set exits 0" "0" "$RUN_RC"
assert_contains "1.2 completeness line is the full-set claim" \
    "Total: $EXPECTED  Passed: $EXPECTED  Failed: 0  Skipped: 0" "$RUN_OUT"
assert_contains "1.3 the floor reports HELD, naming both numbers" \
    "Completeness floor: HELD ($EXPECTED/$EXPECTED specs discovered and executed;" "$RUN_OUT"
assert_contains "1.4 per-spec elapsed is reported (mwrb: silence is attributable)" \
    "assertion(s) in" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 2. the floor: a shrunken discovered set makes the completeness claim FAIL ---\n'
# ===========================================================================
FX_SHRUNK="$WORK/l1-shrunk"
mk_l1_fixture "$FX_SHRUNK" "$((EXPECTED - 1))"
run_l1 "$FX_SHRUNK"
assert_eq "2.1 shipped runner over a shrunken set exits 1" "1" "$RUN_RC"
assert_contains "2.2 the breach names discovered vs expected" \
    "COMPLETENESS FLOOR BREACH: discovered $((EXPECTED - 1)) spec file(s), expected exactly $EXPECTED" "$RUN_OUT"
assert_contains "2.3 the completeness line itself still printed (the floor is what turned it red)" \
    "Total: $((EXPECTED - 1))  Passed: $((EXPECTED - 1))  Failed: 0" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 3. THE MUTANT: an un-floored runner prints the green line over the same shrunken set ---\n'
# This is the deception the floor exists to prevent, demonstrated on demand:
# the pre-a9hh runner scored by exit status alone and had no floor, so a
# shrunken (or unexecuted) set produced `Total: N  Passed: N  Failed: 0`,
# rc=0 — indistinguishable from a full green run. Check 2.1/2.2 is the leg
# that fails on the shipped runner; the mutant shows what a world without it
# reads like.
# ===========================================================================
MUT="$WORK/run-tests.unfloored.sh"
awk '
    /COMPLETENESS-FLOOR-BEGIN/ { skipping=1; found=1; next }
    /COMPLETENESS-FLOOR-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L1_RUNNER" > "$MUT"
AWK_RC=$?
assert_eq "3.1 MUTANT: the floor region was FOUND and excised (awk found-check)" "0" "$AWK_RC"
assert_eq "3.2 MUTANT: the mutant differs from the shipped runner (the excision landed)" \
    "differs" "$(cmp -s "$L1_RUNNER" "$MUT" && echo identical || echo differs)"
assert_eq "3.3 MUTANT: the mutant still parses (bash -n)" \
    "0" "$(bash -n "$MUT" 2>/dev/null; echo $?)"
run_l1 "$FX_SHRUNK" "$MUT"
assert_eq "3.4 SPECIFIC: the un-floored mutant exits 0 over the set the shipped runner refuses at 2.1" \
    "0" "$RUN_RC"
assert_contains "3.5 SPECIFIC: and prints the exact green claim the floor falsifies" \
    "Total: $((EXPECTED - 1))  Passed: $((EXPECTED - 1))  Failed: 0" "$RUN_OUT"
assert_absent "3.6 SPECIFIC: with no breach line anywhere in its output" \
    "COMPLETENESS FLOOR BREACH" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 4. a skip is a THIRD OUTCOME and never a pass ---\n'
# ===========================================================================
FX_SKIP="$WORK/l1-skip"
mk_l1_fixture "$FX_SKIP" "$((EXPECTED - 1))"
cat > "$FX_SKIP/.claude/scripts/tests/stub-skipper.sh" <<'EOF'
#!/bin/bash
echo "SKIPPED: stub-skipper.sh (deliberate: prerequisite absent)"
exit 0
EOF
run_l1 "$FX_SKIP"
assert_eq "4.1 a skip-to-exit-0 spec makes the tier exit 1" "1" "$RUN_RC"
assert_contains "4.2 the skip is counted as its own outcome, not a pass" \
    "Total: $EXPECTED  Passed: $((EXPECTED - 1))  Failed: 0  Skipped: 1" "$RUN_OUT"
assert_contains "4.3 the refusal says why in so many words" \
    "SKIP IS NOT A PASS" "$RUN_OUT"
assert_contains "4.4 the skipped spec is named with its own reason" \
    "stub-skipper.sh — SKIPPED: stub-skipper.sh (deliberate: prerequisite absent)" "$RUN_OUT"

# --- 4b. zero assertions with NO SKIPPED: line is still a skip, never a pass.
# This is the arm that catches the FUTURE spec whose skip shape nobody
# anticipated: exit 0 having measured nothing is the property, not the label.
FX_SILENT="$WORK/l1-silent"
mk_l1_fixture "$FX_SILENT" "$((EXPECTED - 1))"
printf '#!/bin/bash\nexit 0\n' > "$FX_SILENT/.claude/scripts/tests/stub-silent.sh"
run_l1 "$FX_SILENT"
assert_eq "4.5 exit-0-with-zero-assertions exits the tier 1 even without a SKIPPED: line" "1" "$RUN_RC"
assert_contains "4.6 and is classified with the zero-assertions reason" \
    "exited 0 with zero executed assertions and no SKIPPED: line" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 5. a hung spec: killed at the cap, FAILED with a distinct reason, never a skip (mwrb) ---\n'
# ===========================================================================
#
# THE DECOY (R1-F2). An unrelated process holding the machine-global literal
# `sleep 31337`, started OUTSIDE the fixture and kept alive across every orphan
# probe below. It stands in for the second concurrent tier run that used to
# turn this spec red. Two things make it a real control rather than decoration:
#   - the scoped probes must report "gone" WHILE it is provably alive (5.6,
#     7.9), so a probe that ever regresses to the bare literal fails here
#     instead of on somebody else's machine at 3am;
#   - 5.6b asserts the UNSCOPED form really does see it, so "gone" cannot be
#     green merely because nothing was there to find.
# One decoy per literal the two tiers use, so a regression to EITHER bare
# form is caught by the leg that guards it.
bash -c 'sleep 31337' &
DECOY_PID=$!
bash -c 'sleep 31338' &
DECOY_PID_L2=$!
# Off the job table: `kill` on a tracked job makes bash print a "Terminated"
# notice into this spec's own output, which is noise in a control whose job is
# to be read.
disown "$DECOY_PID" 2>/dev/null || true
disown "$DECOY_PID_L2" 2>/dev/null || true
FX_HANG="$WORK/l1-hang"
mk_l1_fixture "$FX_HANG" "$((EXPECTED - 1))"
cat > "$FX_HANG/.claude/scripts/tests/stub-hang.sh" <<EOF
#!/bin/bash
printf '  PASS: stub-hang emitted one assertion before wedging\n'
# A CHILD process does the blocking, so this also proves the watchdog kills
# the process TREE rather than the top-level bash alone (the real hang mode:
# a wedged bd/network call under the spec). Its argv[0] is this run's token,
# so the probe that looks for it cannot see anyone else's sleep.
bash -c "exec -a '$HANG_TOKEN-l1' sleep 31337"
exit 0
EOF
# Deliberately NEVER invoked without a tiny cap: if the cap were broken, an
# uncapped invocation would block this spec for the default 900s — the very
# hang under test. The 3s cap plus the sub-60s bound at 5.1 is the honest
# form of the assertion.
run_l1_capped() {
    local root="$1"
    RUN_OUT=$(CLAUDE_PROJECT_DIR="$root" SPEC_TIMEOUT_S=3 STRICT_SECTIONS=0 \
        bash "$L1_RUNNER" 2>&1)
    RUN_RC=$?
}
HANG_START=$(date +%s)
run_l1_capped "$FX_HANG"
HANG_ELAPSED=$(( $(date +%s) - HANG_START ))
assert_eq "5.1 the tier TERMINATES despite the hung spec (bounded: finished under 60s)" \
    "yes" "$([ "$HANG_ELAPSED" -lt 60 ] && echo yes || echo no)"
assert_eq "5.2 and the tier is RED" "1" "$RUN_RC"
assert_contains "5.3 the hung spec is FAILED with the distinct TIMEOUT reason" \
    "TIMEOUT: killed by the 3s per-spec cap" "$RUN_OUT"
assert_contains "5.4 a timeout is NEVER a skip (Skipped stays 0)" \
    "Total: $EXPECTED  Passed: $((EXPECTED - 1))  Failed: 1  Skipped: 0" "$RUN_OUT"
assert_contains "5.5 the summary carries the timeout tally distinctly (counted in Failed)" \
    "Timed out (counted in Failed): 1 spec(s) at the 3s per-spec cap" "$RUN_OUT"
sleep 1
assert_eq "5.6 the blocking CHILD did not survive as an orphan (the tree was killed)" \
    "gone" "$(pgrep -f "$HANG_TOKEN-l1" >/dev/null 2>&1 && echo alive || echo gone)"
# The two legs that make 5.6 mean what it says. Without 5.6a the probe could be
# green because the decoy died; without 5.6b it could be green because the
# probe is scoped to something nothing ever matches.
assert_eq "5.6a DECOY CONTROL: the unrelated 'sleep 31337' process is still alive right now" \
    "alive" "$(kill -0 "$DECOY_PID" 2>/dev/null && echo alive || echo dead)"
assert_eq "5.6b DECOY CONTROL: the MACHINE-GLOBAL form of the probe WOULD have called it alive (which is why 5.6 is scoped)" \
    "alive" "$(pgrep -f 'sleep 31337' >/dev/null 2>&1 && echo alive || echo gone)"

# --- 5b. a blocking child that IGNORES TERM (a9hh R2-F3). The leg above uses
# `sleep`, which honors TERM — Sol's R2-F3 named that precisely: a control
# whose child dies to the polite pass can never detect that the KILL
# escalation reaches only the (already dead) top-level pid. Reproduced before
# the fix: the tier reported TIMEOUT, red, correct — and the `trap '' TERM`
# child outlived the entire run, free to hold resources or mutate state under
# every later spec. SIG_IGN survives exec, so the token'd sleep below is
# genuinely TERM-immune, not merely TERM-slow.
#
# Since a9hh R6-F1 the watchdog is allowed to FINISH once its marker exists
# (pre-fix, the runner TERMed it the moment `wait` returned, so its KILL
# pass never matured on this path and the post-wait sweep was the layer
# that actually killed this child). Now the ESCALATION kills the immune
# child — and NAMES it first ('refused TERM, KILLed:'), which is what 5.9
# asserts: a kill an operator cannot attribute is R3-F1's 25-iteration hunt
# again. What reddens 5.8 today: delete escalate_kill's KILL stage (the
# loop after the re-walk plus the group KILL). What reddens 5.9: strip the
# refusers report from escalate_kill — the child still dies, silently.
# Both run by hand this round, both observed red (a9hh R6/R7 record).
FX_HANG_I="$WORK/l1-hang-immune"
mk_l1_fixture "$FX_HANG_I" "$((EXPECTED - 1))"
cat > "$FX_HANG_I/.claude/scripts/tests/zz-hang-immune.sh" <<EOF
#!/bin/bash
printf '  PASS: one assertion before wedging\n'
bash -c "trap '' TERM; exec -a '$HANG_TOKEN-l1i' sleep 31337"
exit 0
EOF
run_l1_capped "$FX_HANG_I"
assert_eq "5.7 a TERM-immune blocking child still ends as a red TIMEOUT (bounded, tier terminates)" \
    "1" "$RUN_RC"
sleep 1
assert_eq "5.8 and the TERM-immune child did NOT survive (group-wide KILL, not leader-only)" \
    "gone" "$(pgrep -f "$HANG_TOKEN-l1i" >/dev/null 2>&1 && echo alive || echo gone)"
assert_contains "5.9 the kill is REPORTED, not performed silently — the escalation names what refused TERM" \
    "refused TERM, KILLed:" "$RUN_OUT"

# --- 5c. the spec ITSELF ignores TERM (immune leader). This is the path
# where `wait` cannot return until something un-refusable reaches the leader
# — escalate_kill's KILL stage is what unblocks the runner. What reddens
# 5.10/5.12: delete that KILL stage (the post-re-walk loop plus the group
# KILL) — the runner then blocks in `wait` until the OUTER per-spec cap
# kills this whole control spec: a slow red, but red.
FX_HANG_L="$WORK/l1-hang-leader"
mk_l1_fixture "$FX_HANG_L" "$((EXPECTED - 1))"
cat > "$FX_HANG_L/.claude/scripts/tests/zz-hang-leader.sh" <<EOF
#!/bin/bash
trap '' TERM
printf '  PASS: one assertion before wedging\n'
bash -c "trap '' TERM; exec -a '$HANG_TOKEN-l1L' sleep 31337"
exit 0
EOF
LEADER_START=$(date +%s)
run_l1_capped "$FX_HANG_L"
LEADER_ELAPSED=$(( $(date +%s) - LEADER_START ))
assert_eq "5.10 a TERM-immune LEADER cannot hold the tier open (bounded: finished under 60s)" \
    "yes" "$([ "$LEADER_ELAPSED" -lt 60 ] && echo yes || echo no)"
assert_eq "5.11 and the tier is RED with the TIMEOUT reason" "1" "$RUN_RC"
sleep 1
assert_eq "5.12 the immune leader's immune child is gone too (the KILL was group-wide)" \
    "gone" "$(pgrep -f "$HANG_TOKEN-l1L" >/dev/null 2>&1 && echo alive || echo gone)"

# --- 5d. a spec that BACKGROUNDS its work and exits (a9hh R2-F2). `wait`
# returns when the top-level bash dies, and before the survivor sweep that
# was the END of the runner's knowledge: reproduced pre-fix, this exact
# fixture read `Passed: 36 ... Partial: 0`, rc=0, while the child was still
# alive after the tier returned and its `SKIPPED:` marker went into an
# UNLINKED output file — outcome and evidence both lost. The four-part pair:
# non-vacuity (5.18-5.20 mutant excision checks, plus 5.23 proving the
# fixture really does leave a live child), specific misbehaviour (5.21-5.23:
# the mutant prints the exact green line over the leak), restore control
# (5.24/5.25: a spec that backgrounds AND reaps is a clean PASS), execution
# (5.13-5.17 drive the SHIPPED runner byte-for-byte).
#
# What reddens 5.13-5.17: excise the SURVIVOR-SWEEP region from the shipped
# runner — that is not hypothetical, it is precisely what the mutant below
# demonstrates going green over the same fixture.
mk_bg_fixture() {
    # mk_bg_fixture <root> <token-suffix> — full honest set plus ONE spec
    # that prints a PASS, backgrounds a subshell (marker at +2s, then a
    # token'd 30s sleep), and exits 0 immediately. Sol's R2-F2 shape.
    local root="$1" tok="$2"
    mk_l1_fixture "$root" "$((EXPECTED - 1))"
    cat > "$root/.claude/scripts/tests/zz-background.sh" <<EOF
#!/bin/bash
printf '  PASS: the only foreground assertion ran\n'
( sleep 2
  printf 'SKIPPED: section 4 (needs a prerequisite nobody provisioned)\n'
  exec -a '$HANG_TOKEN-$tok' sleep 30 ) &
exit 0
EOF
}
FX_BG="$WORK/l1-background"
mk_bg_fixture "$FX_BG" "bg"
run_l1 "$FX_BG"
assert_eq "5.13 a spec that returns with live background work FAILS the tier" "1" "$RUN_RC"
assert_contains "5.14 with the reap-your-own-work reason on the spec's line" \
    "returned with 1 live background process(es)" "$RUN_OUT"
assert_contains "5.15 and the failure list names the offence a spec CAN avoid (returning over live work — not 'reap', which a ppid=1 non-child forbids, R3-F1)" \
    "a spec must end its background work before returning" "$RUN_OUT"
assert_contains "5.16 the summary counts it FAILED, not PASSED and not PARTIAL" \
    "Total: $EXPECTED  Passed: $((EXPECTED - 1))  Failed: 1  Skipped: 0  Partial: 0" "$RUN_OUT"
sleep 1
assert_eq "5.17 the backgrounded child did not survive (killed by the sweep, not orphaned)" \
    "gone" "$(pgrep -f "$HANG_TOKEN-bg" >/dev/null 2>&1 && echo alive || echo gone)"

# THE MUTANT: the same runner with the survivor sweep excised — the pre-R2-F2
# world, on demand. Non-vacuity first, then the deception.
MUT_W="$WORK/run-tests.no-sweep.sh"
awk '
    /SURVIVOR-SWEEP-BEGIN/ { skipping=1; found=1; next }
    /SURVIVOR-SWEEP-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L1_RUNNER" > "$MUT_W"
AWK_W_RC=$?
assert_eq "5.18 MUTANT: the sweep region was FOUND and excised (awk found-check)" "0" "$AWK_W_RC"
assert_eq "5.19 MUTANT: it differs from the shipped runner (the excision landed)" \
    "differs" "$(cmp -s "$L1_RUNNER" "$MUT_W" && echo identical || echo differs)"
assert_eq "5.20 MUTANT: and still parses (bash -n)" \
    "0" "$(bash -n "$MUT_W" 2>/dev/null; echo $?)"
FX_BGM="$WORK/l1-background-mutant"
mk_bg_fixture "$FX_BGM" "bgm"
run_l1 "$FX_BGM" "$MUT_W"
assert_eq "5.21 SPECIFIC: the sweep-less mutant exits 0 over the spec the shipped runner fails at 5.13" \
    "0" "$RUN_RC"
assert_contains "5.22 SPECIFIC: and prints the exact green claim (every spec Passed, Partial: 0)" \
    "Total: $EXPECTED  Passed: $EXPECTED  Failed: 0  Skipped: 0  Partial: 0" "$RUN_OUT"
# The escaped child takes its token argv only at +2s (sleep, marker write,
# THEN exec) — probe by polling for it to APPEAR, deadline well past that.
# An immediate probe races the exec and reads 'gone' about a live process.
MUT_ESCAPE="gone"
for _ in 1 2 3 4 5 6 7 8; do
    if pgrep -f "$HANG_TOKEN-bgm" >/dev/null 2>&1; then MUT_ESCAPE="alive"; break; fi
    sleep 1
done
assert_eq "5.23 SPECIFIC: while the child really did escape it (alive after the mutant returned — the leak 5.17 proves the shipped runner ends)" \
    "alive" "$MUT_ESCAPE"
pkill -9 -f "$HANG_TOKEN-bgm" 2>/dev/null
# RESTORE CONTROL: backgrounding is not the offence — leaving it unreaped is.
# A spec that spawns background work and WAITS for it is a clean PASS, so the
# sweep cannot cry wolf on the tier's legitimate concurrency.
FX_BGOK="$WORK/l1-background-reaped"
mk_l1_fixture "$FX_BGOK" "$((EXPECTED - 1))"
cat > "$FX_BGOK/.claude/scripts/tests/zz-background-reaped.sh" <<'EOF'
#!/bin/bash
( sleep 1; printf '  PASS: background leg ran\n' ) &
bg=$!
printf '  PASS: foreground leg ran\n'
wait "$bg"
exit 0
EOF
run_l1 "$FX_BGOK"
assert_eq "5.24 RESTORE CONTROL: a spec that backgrounds AND reaps its work is a clean PASS (rc=0)" \
    "0" "$RUN_RC"
assert_contains "5.25 ...with every spec green and nothing swept" \
    "Total: $EXPECTED  Passed: $EXPECTED  Failed: 0  Skipped: 0  Partial: 0" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 6. filter semantics: a subset is a subset, and an empty match is an error ---\n'
# ===========================================================================
run_l1 "$FX_FULL" "$L1_RUNNER" --filter 'stub-001'
assert_eq "6.1 a filtered run of one passing stub exits 0" "0" "$RUN_RC"
assert_contains "6.2 the floor is DISARMED on filtered runs, and says so" \
    "Completeness floor: DISARMED (--filter run" "$RUN_OUT"
run_l1 "$FX_FULL" "$L1_RUNNER" --filter 'zzz-matches-nothing'
assert_eq "6.3 a filter matching NOTHING is an invocation error (rc=2), not a green run" "2" "$RUN_RC"
assert_contains "6.4 and names the no-match" "matched no spec files" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 7. the L2 runner (component/run.sh): skips leave Passed, timeouts end hangs (mwrb) ---\n'
# ===========================================================================
mk_l2_fixture() {
    # mk_l2_fixture <root> — component layout with the SHIPPED lib files
    # copied in (the runner sources them by path before each spec).
    local root="$1"
    mkdir -p "$root/.claude/tests/component/specs" "$root/.claude/tests/component/lib"
    cp "$L2_LIB/assert.sh" "$L2_LIB/shim.sh" "$L2_LIB/hook-envelope.sh" \
        "$L2_LIB/fixture.sh" "$root/.claude/tests/component/lib/"
}

run_l2() {
    local root="$1"
    RUN_OUT=$(CLAUDE_PROJECT_DIR="$root" bash "$L2_RUNNER" 2>&1)
    RUN_RC=$?
}

FX_L2="$WORK/l2-skip"
mk_l2_fixture "$FX_L2"
cat > "$FX_L2/.claude/tests/component/specs/l2-stub-pass.sh" <<'EOF'
assert_eq "l2-stub-pass ran" "x" "x"
EOF
cat > "$FX_L2/.claude/tests/component/specs/l2-stub-skip.sh" <<'EOF'
printf 'SKIPPED: l2-stub-skip.sh (deliberate: prerequisite absent)\n'
exit 0
EOF
run_l2 "$FX_L2"
assert_eq "7.1 the L2 runner still exits 0 on skip (tier policy unchanged this round — see run.sh header)" \
    "0" "$RUN_RC"
assert_contains "7.2 but the skip LEFT the Passed column (a skip is not a pass)" \
    "Specs:      Total: 2  Passed: 1  Failed: 0  Skipped: 1" "$RUN_OUT"
assert_contains "7.3 and the completeness caveat names the executed subset" \
    "COMPLETENESS: 1 of 2 spec(s) skipped" "$RUN_OUT"
assert_contains "7.4 per-spec elapsed is reported" "in " "$RUN_OUT"

FX_L2H="$WORK/l2-hang"
mk_l2_fixture "$FX_L2H"
cat > "$FX_L2H/.claude/tests/component/specs/l2-stub-pass.sh" <<'EOF'
assert_eq "l2-stub-pass ran" "x" "x"
EOF
cat > "$FX_L2H/.claude/tests/component/specs/l2-stub-hang.sh" <<EOF
bash -c "exec -a '$HANG_TOKEN-l2' sleep 31338"
EOF
L2_START=$(date +%s)
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2H" SPEC_TIMEOUT_S=3 bash "$L2_RUNNER" 2>&1)
RUN_RC=$?
L2_ELAPSED=$(( $(date +%s) - L2_START ))
assert_eq "7.5 the L2 tier TERMINATES despite the hung spec (bounded: finished under 60s)" \
    "yes" "$([ "$L2_ELAPSED" -lt 60 ] && echo yes || echo no)"
assert_eq "7.6 and a timeout makes the L2 tier RED (never silent, never a pass)" "1" "$RUN_RC"
assert_contains "7.7 the hung spec is FAILED with the distinct TIMEOUT reason" \
    "TIMEOUT: killed by the 3s per-spec cap" "$RUN_OUT"
assert_contains "7.8 a timeout is never a skip in L2 either" \
    "Specs:      Total: 2  Passed: 1  Failed: 1  Skipped: 0" "$RUN_OUT"
sleep 1
assert_eq "7.9 the blocking child did not survive the L2 kill either" \
    "gone" "$(pgrep -f "$HANG_TOKEN-l2" >/dev/null 2>&1 && echo alive || echo gone)"
assert_eq "7.9a DECOY CONTROL: the unrelated 'sleep 31338' process is still alive right now" \
    "alive" "$(kill -0 "$DECOY_PID_L2" 2>/dev/null && echo alive || echo dead)"
assert_eq "7.9b DECOY CONTROL: the MACHINE-GLOBAL form WOULD have called it alive (which is why 7.9 is scoped)" \
    "alive" "$(pgrep -f 'sleep 31338' >/dev/null 2>&1 && echo alive || echo gone)"
kill "$DECOY_PID" 2>/dev/null
kill "$DECOY_PID_L2" 2>/dev/null
DECOY_PID=""
DECOY_PID_L2=""

# RESTORE CONTROL for the L2 legs: same runner, same call shape, no hang, no
# skip — green.
FX_L2G="$WORK/l2-green"
mk_l2_fixture "$FX_L2G"
cat > "$FX_L2G/.claude/tests/component/specs/l2-stub-pass.sh" <<'EOF'
assert_eq "l2-stub-pass ran" "x" "x"
EOF
run_l2 "$FX_L2G"
assert_eq "7.10 RESTORE CONTROL: the shipped L2 runner over an honest set is green" "0" "$RUN_RC"
assert_contains "7.11 with a clean completeness line" \
    "Specs:      Total: 1  Passed: 1  Failed: 0  Skipped: 0" "$RUN_OUT"

# --- 7b. L2 shares the R2-F2/R2-F3 mechanics with L1 — same wait-on-leader,
# same tree-snapshot kill shape — so it gets the same legs: reproduced pre-fix, an L2
# spec could background work past its exit and be PASSED while the child
# escaped, and a `trap '' TERM` child outlived the watchdog's leader-only
# KILL. Mutations that redden these: excise run.sh's SURVIVOR-SWEEP region
# (7.12-7.15 and the escape 7.20-7.22 demonstrates), or revert its watchdog
# escalation to a leader-only KILL and drop the sweep (7.16-7.18).
FX_L2BG="$WORK/l2-background"
mk_l2_fixture "$FX_L2BG"
cat > "$FX_L2BG/.claude/tests/component/specs/l2-stub-pass.sh" <<'EOF'
assert_eq "l2-stub-pass ran" "x" "x"
EOF
cat > "$FX_L2BG/.claude/tests/component/specs/l2-stub-bg.sh" <<EOF
assert_eq "one foreground assertion" "x" "x"
( sleep 2; printf 'SKIPPED: section 2 (prerequisite absent)\n'; exec -a '$HANG_TOKEN-l2bg' sleep 30 ) &
EOF
run_l2 "$FX_L2BG"
assert_eq "7.12 L2: a spec that returns with live background work FAILS the tier" "1" "$RUN_RC"
assert_contains "7.13 with the reap-your-own-work reason" \
    "returned with 1 live background process(es)" "$RUN_OUT"
assert_contains "7.14 counted FAILED, not PASSED" \
    "Specs:      Total: 2  Passed: 1  Failed: 1  Skipped: 0" "$RUN_OUT"
sleep 1
assert_eq "7.15 and the backgrounded child did not survive" \
    "gone" "$(pgrep -f "$HANG_TOKEN-l2bg" >/dev/null 2>&1 && echo alive || echo gone)"

FX_L2HI="$WORK/l2-hang-immune"
mk_l2_fixture "$FX_L2HI"
cat > "$FX_L2HI/.claude/tests/component/specs/l2-stub-pass.sh" <<'EOF'
assert_eq "l2-stub-pass ran" "x" "x"
EOF
cat > "$FX_L2HI/.claude/tests/component/specs/l2-stub-hang-immune.sh" <<EOF
assert_eq "one assertion before wedging" "x" "x"
bash -c "trap '' TERM; exec -a '$HANG_TOKEN-l2i' sleep 31338"
EOF
L2I_START=$(date +%s)
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2HI" SPEC_TIMEOUT_S=3 bash "$L2_RUNNER" 2>&1)
RUN_RC=$?
L2I_ELAPSED=$(( $(date +%s) - L2I_START ))
assert_eq "7.16 L2: a TERM-immune child cannot hold the tier open (bounded: under 60s)" \
    "yes" "$([ "$L2I_ELAPSED" -lt 60 ] && echo yes || echo no)"
assert_eq "7.17 and the tier is RED with the TIMEOUT reason" "1" "$RUN_RC"
sleep 1
assert_eq "7.18 the TERM-immune child did not survive the L2 kill (group-wide, not leader-only)" \
    "gone" "$(pgrep -f "$HANG_TOKEN-l2i" >/dev/null 2>&1 && echo alive || echo gone)"

# THE L2 MUTANT: run.sh with its survivor sweep excised — the pre-R2-F2 L2
# world, on demand, same non-vacuity checks as the L1 mutants.
MUT_L2W="$WORK/run.no-sweep.sh"
awk '
    /SURVIVOR-SWEEP-BEGIN/ { skipping=1; found=1; next }
    /SURVIVOR-SWEEP-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L2_RUNNER" > "$MUT_L2W"
AWK_L2W_RC=$?
assert_eq "7.19 L2 MUTANT: the sweep region was FOUND and excised (awk found-check)" "0" "$AWK_L2W_RC"
assert_eq "7.19a L2 MUTANT: it differs from the shipped runner and still parses" \
    "differs-0" "$(cmp -s "$L2_RUNNER" "$MUT_L2W" && echo identical || echo differs)-$(bash -n "$MUT_L2W" 2>/dev/null; echo $?)"
FX_L2BGM="$WORK/l2-background-mutant"
mk_l2_fixture "$FX_L2BGM"
cat > "$FX_L2BGM/.claude/tests/component/specs/l2-stub-pass.sh" <<'EOF'
assert_eq "l2-stub-pass ran" "x" "x"
EOF
cat > "$FX_L2BGM/.claude/tests/component/specs/l2-stub-bg.sh" <<EOF
assert_eq "one foreground assertion" "x" "x"
( sleep 2; printf 'SKIPPED: section 2 (prerequisite absent)\n'; exec -a '$HANG_TOKEN-l2bgm' sleep 30 ) &
EOF
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2BGM" bash "$MUT_L2W" 2>&1)
RUN_RC=$?
assert_eq "7.20 L2 SPECIFIC: the sweep-less mutant exits 0 over the spec the shipped runner fails at 7.12" \
    "0" "$RUN_RC"
assert_contains "7.21 L2 SPECIFIC: and prints the exact green claim" \
    "Specs:      Total: 2  Passed: 2  Failed: 0  Skipped: 0" "$RUN_OUT"
# Same appear-poll as 5.23: the token argv only exists after the child's
# +2s exec, so an immediate probe would read 'gone' about a live process.
L2_MUT_ESCAPE="gone"
for _ in 1 2 3 4 5 6 7 8; do
    if pgrep -f "$HANG_TOKEN-l2bgm" >/dev/null 2>&1; then L2_MUT_ESCAPE="alive"; break; fi
    sleep 1
done
assert_eq "7.22 L2 SPECIFIC: while the child really did escape it (alive after the mutant returned)" \
    "alive" "$L2_MUT_ESCAPE"
pkill -9 -f "$HANG_TOKEN-l2bgm" 2>/dev/null

# ===========================================================================
printf -- '\n--- 8. SECTION-level skips: the floor is spec-granular, and says so (a9hh R1-F1) ---\n'
# ===========================================================================
# The round-0 fix for a9hh shipped its own false green: the rewired l1-unit job
# printed `Total: 36  Passed: 36  Failed: 0  Skipped: 0` and `Completeness
# floor: HELD (36/36 specs discovered and executed)`, rc=0, while
# impact-report.test.sh executed 24 of its 39 assertions and printed `SKIPPED:
# section 4 (code-graph-mcp not installed ...)`. Every counter the runner had
# was spec-granular, so a skipped SECTION moved none of them. This section is
# the pair for the fix: the PARTIAL annotation, the qualified completeness
# line, and the STRICT_SECTIONS refusal.
#
# mk_partial_fixture <root> <spec-body-file-content...> is inlined per case
# rather than factored, because each case's POINT is the exact bytes the stub
# prints.
mk_marker_fixture() {
    # mk_marker_fixture <root> <marker-line> — a full honest set of stubs, with
    # ONE spec that emits assertions AND the given section-skip marker.
    #
    # The marker is passed as DATA (a file the stub cats), never interpolated
    # into the stub's source: several of the real markers below carry
    # parentheses, colons and slashes, and one round of shell-quoting a
    # fixture's payload is how a control quietly starts testing its own
    # escaping instead of the thing it names.
    local root="$1" marker="$2"
    mk_l1_fixture "$root" "$((EXPECTED - 1))"
    printf '%s\n' "$marker" > "$root/marker.txt"
    cat > "$root/.claude/scripts/tests/stub-partial.sh" <<'STUB'
#!/bin/bash
printf '  PASS: section 1 ran\n'
cat "$(dirname "$0")/../../../marker.txt"
printf '  PASS: section 5 ran\n'
exit 0
STUB
}

# --- 8a. RESTORE CONTROL FIRST: strict mode does NOT blanket-fail a clean run.
# Without this leg, every red below could be "STRICT_SECTIONS=1 fails
# everything" rather than "STRICT_SECTIONS=1 fails a skipped section".
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_FULL" STRICT_SECTIONS=1 bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "8.1 RESTORE CONTROL: a clean full set under STRICT_SECTIONS=1 is still green" "0" "$RUN_RC"
assert_contains "8.2 ...with Partial: 0" \
    "Total: $EXPECTED  Passed: $EXPECTED  Failed: 0  Skipped: 0  Partial: 0" "$RUN_OUT"
assert_contains "8.3 ...and the completeness line says so where the claim is made" \
    "specs discovered and executed; 0 skipped a section;" "$RUN_OUT"
assert_absent "8.4 ...and no refusal fires" "SECTION SKIPS ARE NOT COVERAGE" "$RUN_OUT"

# --- 8b. the marker fixture, strict OFF: reported and counted, tier still green.
FX_PARTIAL="$WORK/l1-partial"
mk_marker_fixture "$FX_PARTIAL" 'SKIPPED: section 4 (code-graph-mcp not installed under /nowhere)'
run_l1 "$FX_PARTIAL"
assert_eq "8.5 strict OFF: a section-skipping spec does not fail the tier (a laptop legitimately lacks prerequisites)" \
    "0" "$RUN_RC"
assert_contains "8.6 but it is COUNTED — Partial: 1, not folded into Passed silently" \
    "Total: $EXPECTED  Passed: $EXPECTED  Failed: 0  Skipped: 0  Partial: 1" "$RUN_OUT"
assert_contains "8.7 the spec is NAMED with its own marker text" \
    "stub-partial.sh — 1 section-level skip(s), 2 assertion(s) ran; first: SKIPPED: section 4 (code-graph-mcp not installed under /nowhere)" \
    "$RUN_OUT"
assert_contains "8.8 the per-spec line reads PASSED but INCOMPLETE, not PASSED" \
    "stub-partial.sh: PASSED but INCOMPLETE" "$RUN_OUT"
assert_contains "8.9 THE CLAIM IS QUALIFIED WHERE IT IS MADE (this is R1-F1's actual remedy)" \
    "specs discovered and executed — SPEC-granular; 1 of them skipped a SECTION" "$RUN_OUT"

# --- 8c. the assertion total moves when a section does, and the spec counts do
# not. This is the pair for the `Assertions executed:` line, modelled on the
# real thing: local 2501 vs CI 2486, same 36 specs, same green summary. The two
# fixtures differ ONLY in whether that one stub's fourth section ran — same
# stub, different data file — so anything that differs between the two runs is
# attributable to it.
PARTIAL_ASSERTS=$(printf '%s\n' "$RUN_OUT" | sed -n 's/^Assertions executed: \([0-9]*\)$/\1/p')
PARTIAL_COUNTS=$(printf '%s\n' "$RUN_OUT" | sed -n 's/^\(Total: [0-9]*  Passed: [0-9]*\) .*/\1/p')
FX_COMPLETE="$WORK/l1-complete"
mk_marker_fixture "$FX_COMPLETE" '  PASS: section 4 ran (prerequisite present)'
run_l1 "$FX_COMPLETE"
FULL_ASSERTS=$(printf '%s\n' "$RUN_OUT" | sed -n 's/^Assertions executed: \([0-9]*\)$/\1/p')
FULL_COUNTS=$(printf '%s\n' "$RUN_OUT" | sed -n 's/^\(Total: [0-9]*  Passed: [0-9]*\) .*/\1/p')
assert_eq "8.10 the SPEC counts are identical across the complete and section-skipping runs ($FULL_COUNTS)" \
    "$FULL_COUNTS" "$PARTIAL_COUNTS"
assert_eq "8.11 ...while the executed-assertion total MOVES, which is the whole point of printing it ($FULL_ASSERTS vs $PARTIAL_ASSERTS)" \
    "differs" "$([ -n "$FULL_ASSERTS" ] && [ "$FULL_ASSERTS" != "$PARTIAL_ASSERTS" ] && echo differs || echo identical)"
assert_contains "8.11a ...and the complete variant is Partial: 0 (the difference really is that one section)" \
    "Failed: 0  Skipped: 0  Partial: 0" "$RUN_OUT"

# --- 8d. strict ON: the same fixture is RED.
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_PARTIAL" STRICT_SECTIONS=1 bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "8.12 STRICT_SECTIONS=1: a skipped section makes the tier RED" "1" "$RUN_RC"
assert_contains "8.13 and the refusal says why in so many words" \
    "SECTION SKIPS ARE NOT COVERAGE" "$RUN_OUT"

# --- 8e. THE MUTANT: excise the refusal and the same world reads green.
MUT_S="$WORK/run-tests.no-section-refusal.sh"
awk '
    /SECTION-SKIP-REFUSAL-BEGIN/ { skipping=1; found=1; next }
    /SECTION-SKIP-REFUSAL-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L1_RUNNER" > "$MUT_S"
AWK_S_RC=$?
assert_eq "8.14 MUTANT: the refusal region was FOUND and excised (awk found-check)" "0" "$AWK_S_RC"
assert_eq "8.15 MUTANT: it differs from the shipped runner (the excision landed)" \
    "differs" "$(cmp -s "$L1_RUNNER" "$MUT_S" && echo identical || echo differs)"
assert_eq "8.16 MUTANT: and still parses (bash -n)" \
    "0" "$(bash -n "$MUT_S" 2>/dev/null; echo $?)"
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_PARTIAL" STRICT_SECTIONS=1 bash "$MUT_S" 2>&1)
RUN_RC=$?
assert_eq "8.17 SPECIFIC: without the refusal, the SAME strict run the shipped runner refuses at 8.12 exits 0" \
    "0" "$RUN_RC"
assert_absent "8.18 SPECIFIC: with no refusal line anywhere in its output" \
    "SECTION SKIPS ARE NOT COVERAGE" "$RUN_OUT"

# --- 8f. every marker shape the tier actually prints is recognised. A marker
# the runner cannot see is the whole bug, so this enumerates the four shapes
# in the specs today rather than trusting one example.
for shape in \
    'SKIPPED: section 4 (node not on PATH)' \
    '  SKIPPED: bd resolves under /usr/bin:/bin; cannot stage a bd-less run here' \
    '  SKIP: 4.53b mode-000 files are readable for this uid (root?)' \
    '  note: 6 SKIPPED - the v4.1.0 tag is not reachable here.'
do
    FX_SHAPE="$WORK/l1-shape-$(printf '%s' "$shape" | tr -cd 'a-zA-Z0-9' | cut -c1-16)"
    mk_marker_fixture "$FX_SHAPE" "$shape"
    RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_SHAPE" STRICT_SECTIONS=1 bash "$L1_RUNNER" 2>&1)
    RUN_RC=$?
    assert_eq "8.19 marker shape is seen: [$shape]" "1" "$RUN_RC"
done

# --- 8g. NO FALSE POSITIVES. The tier is full of assertion NAMES containing
# "skip" (workflow-doctor's whole section 4 is about --skip), and a detector
# that flagged those would be the cries-wolf control R1-F2 objects to. Every
# assertion line starts with PASS:/FAIL:, which is what the anchor relies on.
FX_NOISE="$WORK/l1-noise"
mk_l1_fixture "$FX_NOISE" "$((EXPECTED - 1))"
cat > "$FX_NOISE/.claude/scripts/tests/stub-noise.sh" <<'EOF'
#!/bin/bash
printf '  PASS: skip: a skipped check status is SKIP\n'
printf '  PASS: --help names the CWP_SKIP_MCP_DEPS environment form\n'
printf '=== Section 4: --skip counts as SKIPPED, never as passed ===\n'
printf '  FAIL-free tail mentioning SKIPPED for good measure\n'
exit 0
EOF
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_NOISE" STRICT_SECTIONS=1 bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "8.20 NO FALSE POSITIVE: assertion names and section headers containing 'skip' do not trip the detector" \
    "0" "$RUN_RC"
assert_contains "8.21 ...Partial stays 0 for that spec" \
    "Failed: 0  Skipped: 0  Partial: 0" "$RUN_OUT"

# --- 8g-bis (R3-F4). The predicate's note: half reads a spec's OUTPUT — a
# layer where SUBPROCESS text (git, bd, npm) also lands and where section 9's
# source scan structurally cannot see. Its zero-false-positive claim was
# carried by a comment and a hand measurement; these legs pin the two
# properties that make the claim safe, at the output layer, through the
# shipped runner:
#   PRECISION — the tier's real near-miss shapes (prose "Note also:" as
#   workflow-manifest.test.sh:778 prints it, judge-calibration's
#   parenthesised aside, a word merely ENDING in the four letters) stay
#   invisible: the anchor demands a line-initial "note" + colon.
#   LOUDNESS — git's detached-HEAD phrasing, the likeliest future subprocess
#   emission, IS flagged: a visible strict-red PARTIAL quoting the line.
#   That is the documented cost direction (run-tests.sh, SECTION_SKIP_RE
#   block): the a9hh family is silent greens, so a false partial that names
#   itself is the tripwire working — pinned here so the day a tool emits
#   one, the failure reads as this leg predicted rather than as a mystery.
FX_NEARMISS="$WORK/l1-nearmiss"
mk_l1_fixture "$FX_NEARMISS" "$((EXPECTED - 1))"
cat > "$FX_NEARMISS/.claude/scripts/tests/stub-nearmiss.sh" <<'EOF'
#!/bin/bash
printf '  PASS: section 1 ran\n'
printf '        Note also: shipped-docs rows are compared bytewise\n'
printf '  (note: a parenthesised aside is prose, not a marker)\n'
printf '  footnote: a word ending in the four letters is not the idiom\n'
exit 0
EOF
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_NEARMISS" STRICT_SECTIONS=1 bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "8.21a PRECISION at the OUTPUT layer (R3-F4): 'Note also:' / '(note:' / 'footnote:' shapes do not trip the note: half" \
    "0" "$RUN_RC"
assert_contains "8.21b ...Partial stays 0 over all three near-misses" \
    "Failed: 0  Skipped: 0  Partial: 0" "$RUN_OUT"
FX_GITNOTE="$WORK/l1-gitnote"
mk_marker_fixture "$FX_GITNOTE" "Note: switching to 'a1b2c3d'."
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_GITNOTE" STRICT_SECTIONS=1 bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "8.21c LOUD, NOT SILENT (R3-F4): a line-initial git-style switching notice in a spec's output is a strict-red PARTIAL" \
    "1" "$RUN_RC"
assert_contains "8.21d ...quoting the offending line verbatim in the PARTIAL list, so it is attributable in one read" \
    "first: Note: switching to 'a1b2c3d'." "$RUN_OUT"

# --- 8h. the flag itself fails CLOSED on a value it does not understand.
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_FULL" STRICT_SECTIONS=maybe bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "8.22 an unrecognised STRICT_SECTIONS value is an invocation error (rc=2), never a silent 'off'" \
    "2" "$RUN_RC"
assert_contains "8.23 ...and says what it accepts" "STRICT_SECTIONS must be" "$RUN_OUT"

# --- 8i. WIRING. The behaviour above only protects CI if CI asks for it. This
# reads the shipped workflow: a static check, deliberately last, and it proves
# only that the job is wired — legs 8.1-8.23 are what prove the wiring does
# anything. Same shape as workflow-doctor.test.sh's ci-floor legs.
CI_WF="$PLUGIN_DIR/.github/workflows/test.yml"
L1_JOB=$(awk '/^  l1-unit:/{c=1} c&&/^  [a-z0-9-]+:/&&!/^  l1-unit:/{c=0} c' "$CI_WF")
assert_eq "8.24 WIRING: the l1-unit job block was located in the shipped workflow" "yes" \
    "$([ -n "$L1_JOB" ] && echo yes || echo no)"
assert_contains "8.25 WIRING: l1-unit sets STRICT_SECTIONS (a section skip is red in the environment we control)" \
    'STRICT_SECTIONS: "1"' "$L1_JOB"
assert_contains "8.26 WIRING: l1-unit installs bd-mcp deps" \
    "working-directory: .claude/mcp/bd-mcp" "$L1_JOB"
assert_contains "8.27 WIRING: l1-unit installs code-graph-mcp deps (R1-F1: the 15 assertions impact-report.test.sh section 4 lost)" \
    "working-directory: .claude/mcp/code-graph-mcp" "$L1_JOB"
# ...and the Makefile target that CLAIMS to mirror CI. .claude/tests/README.md
# says in so many words that a green `make test-ci` means a green CI; without
# the flag on its L1 leg that sentence is false in the direction that costs a
# push, and nothing else in the tier would notice.
MK_TESTCI=$(awk '/^test-ci:/{c=1} c{print} c&&/^$/{c=0}' "$PLUGIN_DIR/Makefile")
assert_eq "8.28 WIRING: the test-ci recipe was located in the shipped Makefile" "yes" \
    "$([ -n "$MK_TESTCI" ] && echo yes || echo no)"
# shellcheck disable=SC2016  # `$(MAKE)` is MAKEFILE syntax being matched literally.
assert_contains "8.29 WIRING: test-ci runs its L1 leg with STRICT_SECTIONS=1 (it claims to mirror CI)" \
    'STRICT_SECTIONS=1 $(MAKE) --no-print-directory test' "$MK_TESTCI"

# ===========================================================================
printf -- '\n--- 9. the marker convention holds ACROSS THE TIER, not just in the runner ---\n'
# ===========================================================================
# Section 8 proves the runner sees the four marker shapes. That is worth
# exactly as much as the tier's willingness to print one — and when this leg
# was written, THREE arms did not: workflow-doctor.test.sh's META-TEST 3, 4
# and 5 each printed `  note: META-TEST N needs <prerequisite>...` with the
# word "Skipping" on a LATER line, which the runner's line-anchored match
# could not see. Three section-level skips, invisible to the instrument that
# exists to see them, found by asking the question rather than by any check.
#
# THE DIVISION OF LABOUR CHANGED AT R2-F1, and this section's job with it.
# The first cut fixed those three SITES and built this scan to hold the
# convention — but the scan read only directly quoted printf/echo literals,
# so the same two-line shape emitted through a heredoc was invisible to the
# scan AND to the runner's then skip-word-on-the-line match at once: the
# class survived its three instances (Sol, R2-F1; reproduced — Partial: 0,
# rc=0, strict). Detection therefore moved to where every emission mechanism
# converges: the RUNNER now counts ANY line-initial `note:` in a spec's
# OUTPUT as a marker, word or no word (9.5 drives exactly the shape that
# used to slip through, and expects red). This scan remains as the layer the
# runner structurally cannot provide — it reads arms that did NOT fire in
# this environment, and it keeps the marker legible to a human reading a log
# — widened to the second statically-readable mechanism: source lines that
# ARE the marker (heredoc/data bodies), not only literals handed to
# printf/echo. A mechanism assembled at runtime stays invisible here, which
# is now a bounded loss instead of a blind spot: wherever it fires, the
# runner sees it.
#
# It is a TEXT SCAN of sibling specs, which is a weaker kind of evidence than
# the rest of this file — so it is scoped narrowly (line-initial `note:`, the
# house idiom for "this leg could not be measured"), non-vacuity is asserted,
# and its own mutation is exercised below.
scan_bad_notes() {
    # scan_bad_notes <dir> — print every note: marker SOURCE in <dir>'s *.sh
    # that does NOT carry a skip word on the marker line, one per line.
    # Union of the two mechanisms a text scan can read: quoted printf/echo
    # literals, and lines that are themselves the marker (heredoc bodies).
    {
        grep -rhoiE "(printf|echo) +[\"'][[:space:]]*note:[^\"']*" "$1"/*.sh 2>/dev/null
        grep -rhiE '^[[:space:]]*note:' "$1"/*.sh 2>/dev/null
    } | grep -viE 'skip'
}
scan_all_notes() {
    {
        grep -rhoiE "(printf|echo) +[\"'][[:space:]]*note:[^\"']*" "$1"/*.sh 2>/dev/null
        grep -rhiE '^[[:space:]]*note:' "$1"/*.sh 2>/dev/null
    }
}

TESTS_DIR_REAL="$PLUGIN_DIR/.claude/scripts/tests"
ALL_NOTES=$(scan_all_notes "$TESTS_DIR_REAL" | grep -c . | tr -d ' ')
assert_eq "9.1 NON-VACUITY: the scan finds the tier's note: markers at all (found $ALL_NOTES)" \
    "yes" "$([ "${ALL_NOTES:-0}" -ge 4 ] && echo yes || echo no)"
BAD_NOTES=$(scan_bad_notes "$TESTS_DIR_REAL")
assert_eq "9.2 every note: marker in the shipped tier carries a skip word on the marker LINE (the human-legibility convention; the runner itself now sees any line-initial note:)" \
    "" "$BAD_NOTES"

# NEGATIVE CONTROL for 9.2: a fixture dir holding the exact shape that was
# wrong, proving 9.2 is capable of failing. Without this the leg is one
# regex typo away from being permanently, silently green.
#
# ALL the fixture specs are ASSEMBLED from variables rather than written as
# heredocs: a heredoc spelling out the bad marker verbatim would put that
# literal in THIS file — which the scan globs, and since R2-F1 it reads
# heredoc bodies too — and 9.2 would flag its own control. Same convention as
# workflow-doctor.test.sh's "every grep needle in this spec is indented, so
# the pattern cannot match itself"; it applies to COMMENTS here too, since
# the scan is a text scan and does not know what a comment is.
FX_NOTES="$WORK/notes-scan"
mkdir -p "$FX_NOTES"
BAD_MARKER='  note: META-TEST 4 needs node + node_modules to boot the server.'
GOOD_MARKER='  note: 6 SKIPPED - the tag is not reachable here.'
{
    printf '#!/bin/bash\n'
    printf "printf '%s\\\\n'\n" "$BAD_MARKER"
    printf "printf '        Run npm ci to enable it. Skipping.\\\\n'\n"
} > "$FX_NOTES/bad-note.test.sh"
{
    printf '#!/bin/bash\n'
    printf "printf '%s\\\\n'\n" "$GOOD_MARKER"
} > "$FX_NOTES/good-note.test.sh"
# The heredoc-emission control (R2-F1): a spec whose bad marker is a heredoc
# BODY line, the mechanism Sol demonstrated slipping past the literal-only
# scan. The generated file really contains `cat <<'MARKER'` with the marker
# as a body line — only THIS file's source stays clean of it.
{
    printf '#!/bin/bash\n'
    printf 'cat <<%s\n' "'MARKER'"
    printf '%s\n' "$BAD_MARKER"
    printf 'MARKER\n'
    printf "printf '        Run npm ci to enable it. Skipping.\\\\n'\n"
} > "$FX_NOTES/heredoc-note.test.sh"
assert_contains "9.3 CONTROL: the scan DOES flag the marker-line-without-skip shape (the real defect this found)" \
    "note: META-TEST 4 needs node" "$(scan_bad_notes "$FX_NOTES")"
assert_absent "9.4 CONTROL: ...and does not flag a correctly-marked one" \
    "note: 6 SKIPPED" "$(scan_bad_notes "$FX_NOTES")"
assert_eq "9.4a CONTROL (R2-F1): the heredoc-carried bad marker is flagged too — twice, once per emitting fixture" \
    "2" "$(scan_bad_notes "$FX_NOTES" | grep -c 'note: META-TEST 4 needs node')"
# ...and the demonstration that the widening was needed at all: the literal-
# only form of the scan — the shipped shape before R2-F1 — reads the same
# heredoc fixture and finds NOTHING. This is Sol's blind spot, kept on
# display so the next narrowing of the scan has to delete a failing control
# to happen.
OLD_SCAN_HITS=$(grep -rhoiE "(printf|echo) +[\"'][[:space:]]*note:[^\"']*" \
    "$FX_NOTES/heredoc-note.test.sh" 2>/dev/null | grep -viE 'skip' | grep -c .)
assert_eq "9.4b CONTROL (R2-F1): the pre-R2 literal-only scan is BLIND to the heredoc fixture (0 hits) — why the union above exists" \
    "0" "$OLD_SCAN_HITS"
# And the end-to-end statement, driven, not asserted about: the exact
# two-line shape from the finding — a note: line with NO skip word, the word
# arriving on the NEXT line, emitted as output — is SEEN by the shipped
# runner and fails a strict tier. Before R2-F1 this leg asserted rc=0, green:
# the runner demanded the word on the marker line and this shape was
# invisible. What reddens it now: narrowing SECTION_SKIP_RE's note: half back
# to requiring a same-line skip word.
FX_BADNOTE="$WORK/l1-badnote"
mk_marker_fixture "$FX_BADNOTE" "$BAD_MARKER"$'\n'"        Install deps to enable it. Skipping."
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_BADNOTE" STRICT_SECTIONS=1 bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "9.5 END TO END (R2-F1): the two-line marker — note: line, skip word only on the NEXT line — is now SEEN, and the strict tier is red" \
    "1" "$RUN_RC"
assert_contains "9.5a ...with the note line itself quoted as the spec's first marker" \
    "first: note: META-TEST 4 needs node" "$RUN_OUT"
FX_GOODNOTE="$WORK/l1-goodnote"
mk_marker_fixture "$FX_GOODNOTE" '  note: META-TEST 4 SKIPPED - it needs node + node_modules.'
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_GOODNOTE" STRICT_SECTIONS=1 bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "9.6 END TO END: the conventional shape (word on the marker line) is of course still seen, and the tier is red" \
    "1" "$RUN_RC"

# ===========================================================================
printf -- '\n--- 10. TELEMETRY DISARM: the sweep must never fire on a process a spec did not start (a9hh R3-F1) ---\n'
# ===========================================================================
# bd spawns `bd send-metrics` from ANY bd command when metrics are enabled —
# detached to ppid=1 WITHOUT setsid, so it stays in the SPEC'S process group,
# and a slow endpoint carries it past the sweep's grace: the sweep then kills
# an innocent spec for a process it never backgrounded and cannot wait for.
# Reproduced through the shipped pre-fix runner: 10/10 tier-red sweep firings
# with the endpoint blackholed, 0/25 idle (QA: 4/25 under load) — a 1-in-6
# CI flake wearing a leak detector's uniform. Fresh-HOME fixtures re-enable
# metrics implicitly (a HOME without ~/.config/bd defaults to ON, measured on
# bd 1.1.2, the version CI pins). Both runners therefore export
# BD_DISABLE_METRICS=1, which prevents the SPAWN itself (measured: 3/3
# in-group flushers without it, 0/3 with it, same fixture).
#
# These legs are the pair the R2 sweep never had: proof the sweep does NOT
# fire on a process the spec never created. The env probe is driven with the
# variable UNSET at the call site (env -u), so the leg proves the RUNNER
# establishes it — not the ambient environment (the 8.5 lesson: this spec
# runs inside the tier, whose runner now exports the very variable under
# test). What reddens 10.1/10.6: excising the TELEMETRY-DISARM region —
# exactly the mutation 10.2-10.5 and 10.7-10.10 perform and demonstrate.
FX_TD="$WORK/l1-telemetry"
mk_l1_fixture "$FX_TD" "$((EXPECTED - 1))"
cat > "$FX_TD/.claude/scripts/tests/stub-telemetry-env.sh" <<'EOF'
#!/bin/bash
if [ "${BD_DISABLE_METRICS:-}" = "1" ]; then
    printf '  PASS: BD_DISABLE_METRICS=1 is exported to specs\n'
    exit 0
fi
printf '  FAIL: BD_DISABLE_METRICS is not 1 in the spec environment (got "%s")\n' \
    "${BD_DISABLE_METRICS:-unset}"
exit 1
EOF
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_TD" STRICT_SECTIONS=0 \
    env -u BD_DISABLE_METRICS bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "10.1 the shipped L1 runner exports BD_DISABLE_METRICS=1 to specs even when the caller does not have it (rc=0)" \
    "0" "$RUN_RC"
assert_contains "10.1a ...and the probe spec testifies to it" \
    "BD_DISABLE_METRICS=1 is exported to specs" "$RUN_OUT"
MUT_TD="$WORK/run-tests.no-telemetry-disarm.sh"
awk '
    /TELEMETRY-DISARM-BEGIN/ { skipping=1; found=1; next }
    /TELEMETRY-DISARM-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L1_RUNNER" > "$MUT_TD"
AWK_TD_RC=$?
assert_eq "10.2 MUTANT: the telemetry-disarm region was FOUND and excised (awk found-check)" "0" "$AWK_TD_RC"
assert_eq "10.3 MUTANT: it differs from the shipped runner (the excision landed)" \
    "differs" "$(cmp -s "$L1_RUNNER" "$MUT_TD" && echo identical || echo differs)"
assert_eq "10.4 MUTANT: and still parses (bash -n)" \
    "0" "$(bash -n "$MUT_TD" 2>/dev/null; echo $?)"
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_TD" STRICT_SECTIONS=0 \
    env -u BD_DISABLE_METRICS bash "$MUT_TD" 2>&1)
RUN_RC=$?
assert_eq "10.5 SPECIFIC: with the disarm excised the SAME fixture goes red — this leg is what fires when the exemption is removed" \
    "1" "$RUN_RC"
assert_contains "10.5a ...with the probe naming the missing variable" \
    'BD_DISABLE_METRICS is not 1 in the spec environment' "$RUN_OUT"

# The L2 runner: same exemption, same pair.
FX_L2TD="$WORK/l2-telemetry"
mk_l2_fixture "$FX_L2TD"
cat > "$FX_L2TD/.claude/tests/component/specs/l2-telemetry-env.sh" <<'EOF'
assert_eq "BD_DISABLE_METRICS=1 is exported to L2 specs" "1" "${BD_DISABLE_METRICS:-unset}"
EOF
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2TD" env -u BD_DISABLE_METRICS bash "$L2_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "10.6 the shipped L2 runner exports BD_DISABLE_METRICS=1 to specs (rc=0)" "0" "$RUN_RC"
assert_contains "10.6a ...probe green" \
    "PASS: BD_DISABLE_METRICS=1 is exported to L2 specs" "$RUN_OUT"
MUT_L2TD="$WORK/run.no-telemetry-disarm.sh"
awk '
    /TELEMETRY-DISARM-BEGIN/ { skipping=1; found=1; next }
    /TELEMETRY-DISARM-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L2_RUNNER" > "$MUT_L2TD"
AWK_L2TD_RC=$?
assert_eq "10.7 L2 MUTANT: the telemetry-disarm region was FOUND and excised" "0" "$AWK_L2TD_RC"
assert_eq "10.8 L2 MUTANT: differs from the shipped runner and still parses" \
    "differs-0" "$(cmp -s "$L2_RUNNER" "$MUT_L2TD" && echo identical || echo differs)-$(bash -n "$MUT_L2TD" 2>/dev/null; echo $?)"
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2TD" env -u BD_DISABLE_METRICS bash "$MUT_L2TD" 2>&1)
RUN_RC=$?
assert_eq "10.9 L2 SPECIFIC: with the disarm excised the same fixture goes red" "1" "$RUN_RC"
assert_contains "10.10 ...with the probe reporting the variable unset" \
    "FAIL: BD_DISABLE_METRICS=1 is exported to L2 specs" "$RUN_OUT"

# The variable itself, verified against the INSTALLED bd — this is what turns
# a future bd renaming BD_DISABLE_METRICS into a deterministic red HERE
# instead of a 1-in-6 sweep flake in CI. Both calls run in a fresh HOME (no
# ~/.config/bd, the exact fixture shape that re-enables metrics); the
# without-var half runs in a THROWAWAY process group so any flusher it spawns
# lands outside this spec's group and cannot trip the tier sweep on us.
if command -v bd >/dev/null 2>&1; then
    BDPROBE_HOME=$(mktemp -d "$WORK/bdmetrics.XXXXXX")
    WITH_VAR=$(HOME="$BDPROBE_HOME" BD_DISABLE_METRICS=1 bd metrics 2>&1 | head -3)
    WITHOUT_VAR=$(HOME="$BDPROBE_HOME" env -u BD_DISABLE_METRICS \
        bash -c 'set -m; bd metrics & wait $!' 2>&1 | head -3)
    assert_contains "10.11 the installed bd honors BD_DISABLE_METRICS=1 (fresh HOME reports metrics OFF)" \
        "metrics: OFF" "$WITH_VAR"
    assert_contains "10.12 NEGATIVE CONTROL: without the variable the same fresh HOME reports ON (the variable is load-bearing, not decoration)" \
        "metrics: ON" "$WITHOUT_VAR"
else
    printf '  SKIPPED: bd not on PATH — cannot verify BD_DISABLE_METRICS against the installed bd (10.11/10.12 need it)\n'
fi

# ===========================================================================
printf -- '\n--- 11. STDIN: a spec must see EOF, never the runner'\''s stdin (a9hh R3-F2) ---\n'
# ===========================================================================
# set -m REVERSED the POSIX async default this spec's own runners used to
# rely on: with job control ON, a background job INHERITS the runner's stdin
# (bash sends async stdin to /dev/null only when job control is off).
# Reproduced pre-fix, both halves: a reader spec consumed a sentinel piped
# into the shipped runner, and under a pty a stdin-reading spec was
# SIGTTIN-stopped — state T at 8/8 samples, which `kill -0` reads as alive,
# so the watchdog burned the full cap and reported TIMEOUT over a spec that
# was not running (the mwrb wedge, in text that promised EOF). Both runners
# now redirect `< /dev/null` explicitly at the launch site. These legs pipe
# a sentinel into the RUNNER and let a reader spec testify to what reached
# it. What reddens 11.1/11.1a: stripping the redirect from the launch line —
# exactly the mutation 11.2-11.4 and the L2 twins perform and demonstrate.
STDIN_SENTINEL="RC-STDIN-SENTINEL-$$"
FX_STDIN="$WORK/l1-stdin"
mk_l1_fixture "$FX_STDIN" "$((EXPECTED - 1))"
cat > "$FX_STDIN/.claude/scripts/tests/stub-stdin-reader.sh" <<'EOF'
#!/bin/bash
if IFS= read -r line; then
    printf '  FAIL: stdin was readable — a spec consumed [%s]\n' "$line"
    exit 1
fi
printf '  PASS: stdin is EOF\n'
exit 0
EOF
RUN_OUT=$(printf '%s\n' "$STDIN_SENTINEL" \
    | CLAUDE_PROJECT_DIR="$FX_STDIN" STRICT_SECTIONS=0 bash "$L1_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "11.1 the shipped L1 runner gives a reader spec EOF even with the runner's stdin LOADED (rc=0)" \
    "0" "$RUN_RC"
assert_contains "11.1a ...the spec testifies to EOF" "stdin is EOF" "$RUN_OUT"
assert_absent "11.1b ...and the sentinel reached no spec" \
    "a spec consumed [$STDIN_SENTINEL]" "$RUN_OUT"
MUT_STDIN="$WORK/run-tests.stdin-inherit.sh"
awk '{
    if (index($0, "bash \"$test_file\"") && sub(/ < \/dev\/null/, "")) found=1
    print
} END { if (!found) exit 7 }' "$L1_RUNNER" > "$MUT_STDIN"
AWK_SI_RC=$?
assert_eq "11.2 MUTANT: the stdin redirect was FOUND on the launch line and stripped (awk found-check)" "0" "$AWK_SI_RC"
assert_eq "11.3 MUTANT: differs from the shipped runner and still parses" \
    "differs-0" "$(cmp -s "$L1_RUNNER" "$MUT_STDIN" && echo identical || echo differs)-$(bash -n "$MUT_STDIN" 2>/dev/null; echo $?)"
RUN_OUT=$(printf '%s\n' "$STDIN_SENTINEL" \
    | CLAUDE_PROJECT_DIR="$FX_STDIN" STRICT_SECTIONS=0 bash "$MUT_STDIN" 2>&1)
RUN_RC=$?
assert_eq "11.4 SPECIFIC: without the redirect the same fixture goes red — a spec read the runner's stdin" \
    "1" "$RUN_RC"
assert_contains "11.4a ...consuming the sentinel VERBATIM (the pre-fix world on display)" \
    "a spec consumed [$STDIN_SENTINEL]" "$RUN_OUT"

# The L2 runner: same redirect, same pair.
FX_L2SR="$WORK/l2-stdin"
mk_l2_fixture "$FX_L2SR"
cat > "$FX_L2SR/.claude/tests/component/specs/l2-stdin-reader.sh" <<'EOF'
if IFS= read -r line; then
    assert_eq "stdin must be EOF for L2 specs" "EOF" "consumed:$line"
else
    assert_eq "stdin is EOF for L2 specs" "x" "x"
fi
EOF
RUN_OUT=$(printf '%s\n' "$STDIN_SENTINEL" \
    | CLAUDE_PROJECT_DIR="$FX_L2SR" bash "$L2_RUNNER" 2>&1)
RUN_RC=$?
assert_eq "11.5 the shipped L2 runner gives a reader spec EOF with stdin loaded (rc=0)" "0" "$RUN_RC"
assert_contains "11.5a ...probe green" "PASS: stdin is EOF for L2 specs" "$RUN_OUT"
MUT_L2SI="$WORK/run.stdin-inherit.sh"
awk '{
    if (index($0, "\"$SPEC_OUT\" 2>&1 < /dev/null") && sub(/ < \/dev\/null/, "")) found=1
    print
} END { if (!found) exit 7 }' "$L2_RUNNER" > "$MUT_L2SI"
AWK_L2SI_RC=$?
assert_eq "11.6 L2 MUTANT: the stdin redirect was FOUND on the launch line and stripped" "0" "$AWK_L2SI_RC"
assert_eq "11.7 L2 MUTANT: differs from the shipped runner and still parses" \
    "differs-0" "$(cmp -s "$L2_RUNNER" "$MUT_L2SI" && echo identical || echo differs)-$(bash -n "$MUT_L2SI" 2>/dev/null; echo $?)"
RUN_OUT=$(printf '%s\n' "$STDIN_SENTINEL" \
    | CLAUDE_PROJECT_DIR="$FX_L2SR" bash "$MUT_L2SI" 2>&1)
RUN_RC=$?
assert_eq "11.8 L2 SPECIFIC: without the redirect the same fixture goes red" "1" "$RUN_RC"
assert_contains "11.8a ...with the reader consuming the sentinel" \
    "consumed:$STDIN_SENTINEL" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 12. accounting cannot be bypassed, filters cannot select nothing, interrupts cannot strand (a9hh R4/R5) ---\n'
# ===========================================================================
# Four fixes from one review round, each with its pair. The unifying defect:
# every one of them let the runner's verdict disagree with what actually
# happened — a FAIL converted to a SKIP (R4-F1), a FAIL swallowed by a grace
# window (R4-F2), a green run over zero selected specs (R4-F3/R5-F2), and an
# interrupt that stranded a descendant (R4-F4).

# The mktemp SHIM: legs 12.31 and 12.35-12.38 need to know the exact scratch
# dir a runner-under-test created, from OUTSIDE the runner. TMPDIR-scoping
# does not work (macOS BSD mktemp ignores $TMPDIR for the `-d -t` shape and
# the first draft of these legs passed vacuously — caught by their own
# reddening mutation), and listing the real temp dir is the machine-global
# probe R1-F2 banned. So the runner-under-test gets a PATH-prepended mktemp
# that logs what the real one created. The runner is still the shipped bytes,
# byte-for-byte; only tool resolution changes, which is ordinary PATH
# semantics.
SHIM_BIN="$WORK/shim-bin"
MKTEMP_LOG="$WORK/mktemp-calls.txt"
REAL_MKTEMP=$(command -v mktemp)
mkdir -p "$SHIM_BIN"
cat > "$SHIM_BIN/mktemp" <<SHIM
#!/bin/bash
out=\$("$REAL_MKTEMP" "\$@") || exit \$?
printf '%s\n' "\$out" >> "$MKTEMP_LOG"
printf '%s\n' "\$out"
SHIM
chmod +x "$SHIM_BIN/mktemp"

# --- 12a. L2 filter zero-match is an invocation error (R4-F3/R5-F2, the L2
# twin of leg 6.3). QA hit this for real: both runners filter with BRE grep,
# so the natural ERE alternation matched nothing and returned green in 0.16s.
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2G" bash "$L2_RUNNER" --filter 'zzz-matches-nothing' 2>&1)
RUN_RC=$?
assert_eq "12.1 an L2 filter matching NOTHING is an invocation error (rc=2), not a green run" "2" "$RUN_RC"
assert_contains "12.2 and names the no-match" "matched no spec files" "$RUN_OUT"
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2G" bash "$L2_RUNNER" --filter 'l2-stub-pass|zzz' 2>&1)
RUN_RC=$?
assert_eq "12.3 the BRE-vs-ERE trap QA hit — an alternation filter — is loud (rc=2), not silently green" "2" "$RUN_RC"
MUT_L2F="$WORK/run.no-filter-guard.sh"
awk '
    /FILTER-ZERO-MATCH-BEGIN/ { skipping=1; found=1; next }
    /FILTER-ZERO-MATCH-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L2_RUNNER" > "$MUT_L2F"
assert_eq "12.4 MUTANT: the filter-guard region was FOUND and excised, differs, and parses" \
    "0-differs-0" "$?-$(cmp -s "$L2_RUNNER" "$MUT_L2F" && echo identical || echo differs)-$(bash -n "$MUT_L2F" 2>/dev/null; echo $?)"
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2G" bash "$MUT_L2F" --filter 'zzz-matches-nothing' 2>&1)
RUN_RC=$?
assert_eq "12.5 SPECIFIC: the guard-less mutant exits 0 over the zero-match run the shipped runner refuses at 12.1" \
    "0" "$RUN_RC"
assert_contains "12.6 SPECIFIC: printing the green-over-nothing line" \
    "Specs:      Total: 0  Passed: 0  Failed: 0  Skipped: 0" "$RUN_OUT"

# --- 12b. L2 early-exit accounting (R4-F1). Reproduced on the pre-fix
# runner: a failing assertion followed by a skip gate's `exit 0`
# (bd_required_or_skip's exact mechanism) was classified SKIPPED, the
# aggregate read `Failed: 0`, and run.sh exited 0 — a real regression
# converted into a successful skip, reachable on the BD_SHIM_ONLY=1 CI path
# through post-edit.sh (assertions through line ~632, bd gate at 655).
FX_L2EE="$WORK/l2-early-exit"
mk_l2_fixture "$FX_L2EE"
cat > "$FX_L2EE/.claude/tests/component/specs/l2-fail-then-skip.sh" <<'EOF'
assert_eq "regression BEFORE the skip gate" "expected" "actual-broken"
printf 'SKIPPED: l2-fail-then-skip.sh (prerequisite absent — ad-hoc gate)\n'
exit 0
EOF
run_l2 "$FX_L2EE"
assert_eq "12.7 a failing assertion before an exit-0 skip gate FAILS the tier (was: SKIPPED, rc=0)" "1" "$RUN_RC"
assert_contains "12.8 with the bypassed-fail-gate reason on the spec's line" \
    "its summary counted 1 failed assertion(s)" "$RUN_OUT"
assert_contains "12.9 and the aggregate carries the failed assertion (was: Failed: 0)" \
    "Assertions: Passed: 0  Failed: 1" "$RUN_OUT"
FX_L2PE="$WORK/l2-pass-then-exit"
mk_l2_fixture "$FX_L2PE"
cat > "$FX_L2PE/.claude/tests/component/specs/l2-pass-then-skip.sh" <<'EOF'
assert_eq "measured before the gate" "x" "x"
printf 'SKIPPED: l2-pass-then-skip.sh (tail needs a prerequisite)\n'
exit 0
EOF
run_l2 "$FX_L2PE"
assert_eq "12.10 assertions that ran before a skip gate are COUNTED, not converted to a skip (rc=0)" "0" "$RUN_RC"
assert_contains "12.11 ...the spec is PASSED with its executed count — and QUALIFIED, because its transcript holds the marker (R7-F2)" \
    "l2-pass-then-skip.sh: PASSED but INCOMPLETE (1 assertion(s)" "$RUN_OUT"
assert_contains "12.12 ...and the aggregate holds the assertion (was: Passed: 0)" \
    "Assertions: Passed: 1  Failed: 0" "$RUN_OUT"
FX_L2EX="$WORK/l2-exec"
mk_l2_fixture "$FX_L2EX"
printf 'assert_eq "ran" "x" "x"\nexec true\n' > "$FX_L2EX/.claude/tests/component/specs/l2-exec.sh"
run_l2 "$FX_L2EX"
assert_eq "12.13 an exec-replacement that bypasses the summary is FAILED loudly, never SKIPPED" "1" "$RUN_RC"
assert_contains "12.14 ...naming the missing summary line" \
    "without a __SPEC_SUMMARY__ line" "$RUN_OUT"

# THE MUTANT: both accounting regions excised — the pre-fix world for the
# early-exit fixture, on demand. (The pre-fix runner emitted its summary
# inline at the wrapper's end, so this mutant matches it exactly on any
# EARLY-EXIT path — which is the path under test.)
MUT_L2ACC="$WORK/run.no-accounting.sh"
awk '
    /SUMMARY-TRAP-BEGIN/     { skipping=1; f1=1; next }
    /SUMMARY-TRAP-END/       { skipping=0; next }
    /FAILED-ACCOUNTING-BEGIN/ { skipping=1; f2=1; next }
    /FAILED-ACCOUNTING-END/   { skipping=0; next }
    !skipping { print }
    END { if (!(f1 && f2)) exit 7 }
' "$L2_RUNNER" > "$MUT_L2ACC"
assert_eq "12.15 MUTANT: both accounting regions FOUND and excised, differs, parses" \
    "0-differs-0" "$?-$(cmp -s "$L2_RUNNER" "$MUT_L2ACC" && echo identical || echo differs)-$(bash -n "$MUT_L2ACC" 2>/dev/null; echo $?)"
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2EE" bash "$MUT_L2ACC" 2>&1)
RUN_RC=$?
assert_eq "12.16 SPECIFIC: the mutant reads the SAME failing fixture as a green run (rc=0) — the R4-F1 deception on display" \
    "0" "$RUN_RC"
assert_contains "12.17 SPECIFIC: classifying the regression as SKIPPED with Failed: 0" \
    "Assertions: Passed: 0  Failed: 0" "$RUN_OUT"

# --- 12c. the transcript arm (R4-F2), L1. Reproduced pre-fix, both shapes:
# a background subshell's FAIL: landing inside the sweep's grace window was
# PASSED (rc=0, ASSERTS counted it, nothing read it), and a foreground spec
# printing FAIL: while exiting 0 was equally green. The arm closes the
# timing hole from the other side of the sweep: within-grace failures are
# caught by their transcript, beyond-grace work by the sweep — no duration
# of failing background work is green.
FX_TFAIL="$WORK/l1-transcript-fail"
mk_l1_fixture "$FX_TFAIL" "$((EXPECTED - 1))"
cat > "$FX_TFAIL/.claude/scripts/tests/zz-transcript-fail.sh" <<'EOF'
#!/bin/bash
printf 'PASS: foreground\n'
printf 'FAIL: printed but never carried by the exit code\n'
exit 0
EOF
run_l1 "$FX_TFAIL"
assert_eq "12.18 rc=0 over a FAIL: line in the transcript is a FAILURE (was: PASSED, tier green)" "1" "$RUN_RC"
assert_contains "12.19 ...naming the transcript/exit-code disagreement and quoting the line" \
    "FAIL: line(s) the exit code never carried" "$RUN_OUT"
FX_TBG="$WORK/l1-transcript-bg"
mk_l1_fixture "$FX_TBG" "$((EXPECTED - 1))"
cat > "$FX_TBG/.claude/scripts/tests/zz-bg-fail.sh" <<'EOF'
#!/bin/bash
printf 'PASS: foreground\n'
( sleep 0.3; printf 'FAIL: background regression inside the grace window\n' ) &
exit 0
EOF
run_l1 "$FX_TBG"
assert_eq "12.20 Sol's exact shape — a bg FAIL that dies inside the grace window — is RED (was: PASSED 2 assertions)" \
    "1" "$RUN_RC"
assert_contains "12.21 ...as a named FAILURE, whichever arm catches it" "zz-bg-fail.sh" \
    "$(printf '%s\n' "$RUN_OUT" | grep 'Failed tests:' -A3)"
# RESTORE: same fixture shape, failing line removed — background work that
# is REAPED and passes is a clean PASS (the arm cannot cry wolf on green
# concurrency).
FX_TOK="$WORK/l1-transcript-ok"
mk_l1_fixture "$FX_TOK" "$((EXPECTED - 1))"
cat > "$FX_TOK/.claude/scripts/tests/zz-bg-ok.sh" <<'EOF'
#!/bin/bash
printf 'PASS: foreground\n'
( sleep 0.3; printf 'PASS: background leg\n' ) &
wait
exit 0
EOF
run_l1 "$FX_TOK"
assert_eq "12.22 RESTORE CONTROL: reaped, passing background work is still a clean PASS" "0" "$RUN_RC"
MUT_TF="$WORK/run-tests.no-transcript-arm.sh"
awk '
    /TRANSCRIPT-FAIL-BEGIN/ { skipping=1; found=1; next }
    /TRANSCRIPT-FAIL-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L1_RUNNER" > "$MUT_TF"
assert_eq "12.23 MUTANT: the transcript-arm region FOUND and excised, differs, parses" \
    "0-differs-0" "$?-$(cmp -s "$L1_RUNNER" "$MUT_TF" && echo identical || echo differs)-$(bash -n "$MUT_TF" 2>/dev/null; echo $?)"
run_l1 "$FX_TFAIL" "$MUT_TF"
assert_eq "12.24 SPECIFIC: the arm-less mutant PASSES the spec whose transcript says FAIL (rc=0) — the pre-fix world" \
    "0" "$RUN_RC"
assert_contains "12.25 SPECIFIC: with the full green line over it" \
    "Total: $EXPECTED  Passed: $EXPECTED  Failed: 0" "$RUN_OUT"

# --- 12d. the transcript arm at L2: a backgrounded assert's FAIL++ dies with
# its subshell, its FAIL: line lands in the capture file, the summary says
# fail=0 — pre-fix that spec PASSED.
FX_L2BGF="$WORK/l2-bg-assert-fail"
mk_l2_fixture "$FX_L2BGF"
cat > "$FX_L2BGF/.claude/tests/component/specs/l2-bg-assert.sh" <<'EOF'
assert_eq "foreground green" "x" "x"
( assert_eq "background regression (counter dies with the subshell)" "a" "b" ) &
wait
EOF
run_l2 "$FX_L2BGF"
assert_eq "12.26 an L2 background assert failure is RED (was: PASSED, Failed: 0)" "1" "$RUN_RC"
assert_contains "12.27 ...via the transcript arm, since the summary never counted it" \
    "FAIL: line(s) the summary never counted" "$RUN_OUT"

# --- 12e. interrupts reap out-of-group descendants (R4-F4). Reproduced on
# Linux (ubuntu:24.04) against both pre-fix runners: a spec running
# `setsid sleep & wait` has a descendant OUTSIDE its process group on a live
# ppid chain; TERM to the runner ran a handler that signalled only the
# group, the runner exited 130, and the descendant survived. The fixed
# handler snapshots the ppid tree FIRST and TERM/KILLs both the tree and
# the group. What reddens 12.28-12.31: reverting on_interrupt to the
# group-only signals (run exactly that mutation by hand; the token probe
# below reads 'alive'). perl+POSIX provides a portable setsid (macOS ships
# no setsid(1)); if perl is genuinely absent this leg says so as a marker.
if command -v perl >/dev/null 2>&1; then
    FX_INT="$WORK/l1-interrupt"
    mk_l1_fixture "$FX_INT" "$((EXPECTED - 1))"
    cat > "$FX_INT/.claude/scripts/tests/zz-setsid-holder.sh" <<EOF
#!/bin/bash
printf '  PASS: probe launched\n'
perl -MPOSIX -e 'POSIX::setsid(); exec "bash","-c","exec -a $HANG_TOKEN-int sleep 31600"' &
wait
exit 0
EOF
    : > "$MKTEMP_LOG"
    PATH="$SHIM_BIN:$PATH" CLAUDE_PROJECT_DIR="$FX_INT" STRICT_SECTIONS=0 \
        bash "$L1_RUNNER" > "$WORK/int-l1.log" 2>&1 &
    INT_RPID=$!
    INT_SEEN="no"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if pgrep -f "$HANG_TOKEN-int" >/dev/null 2>&1; then INT_SEEN="yes"; break; fi
        sleep 1
    done
    assert_eq "12.28 the out-of-group descendant exists mid-spec (the interrupt has something to strand)" \
        "yes" "$INT_SEEN"
    kill -TERM "$INT_RPID" 2>/dev/null
    wait "$INT_RPID" 2>/dev/null
    INT_RC=$?
    sleep 2
    assert_eq "12.29 the interrupted runner exits 130" "130" "$INT_RC"
    assert_eq "12.30 and the out-of-group descendant did NOT survive it (was: stranded past exit)" \
        "gone" "$(pgrep -f "$HANG_TOKEN-int" >/dev/null 2>&1 && echo alive || echo gone)"
    INT_SCRATCH=$(head -1 "$MKTEMP_LOG" 2>/dev/null)
    assert_eq "12.31 and the interrupt path removed the scratch dir (finish ran, no EXIT trap involved): $INT_SCRATCH" \
        "gone" "$([ -n "$INT_SCRATCH" ] && [ ! -d "$INT_SCRATCH" ] && echo gone || echo present-or-unknown)"
    pkill -9 -f "$HANG_TOKEN-int" 2>/dev/null

    FX_L2INT="$WORK/l2-interrupt"
    mk_l2_fixture "$FX_L2INT"
    cat > "$FX_L2INT/.claude/tests/component/specs/l2-setsid-holder.sh" <<EOF
perl -MPOSIX -e 'POSIX::setsid(); exec "bash","-c","exec -a $HANG_TOKEN-l2int sleep 31600"' &
wait
EOF
    CLAUDE_PROJECT_DIR="$FX_L2INT" \
        bash "$L2_RUNNER" > "$WORK/int-l2.log" 2>&1 &
    INT_RPID2=$!
    INT_SEEN2="no"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if pgrep -f "$HANG_TOKEN-l2int" >/dev/null 2>&1; then INT_SEEN2="yes"; break; fi
        sleep 1
    done
    assert_eq "12.32 L2: the descendant exists mid-spec" "yes" "$INT_SEEN2"
    kill -TERM "$INT_RPID2" 2>/dev/null
    wait "$INT_RPID2" 2>/dev/null
    INT_RC2=$?
    sleep 2
    assert_eq "12.33 L2: interrupted runner exits 130" "130" "$INT_RC2"
    assert_eq "12.34 L2: the descendant did not survive either" \
        "gone" "$(pgrep -f "$HANG_TOKEN-l2int" >/dev/null 2>&1 && echo alive || echo gone)"
    pkill -9 -f "$HANG_TOKEN-l2int" 2>/dev/null
else
    printf '  SKIPPED: perl not on PATH — the portable-setsid interrupt legs (12.28-12.34) need it\n'
fi

# --- 12f. scratch lifecycle without an EXIT trap (R5-F1). Every terminal
# path of both runners must remove the scratch dir it created, because the
# cleanup no longer lives in a trap. THE PROBE IS AN mktemp SHIM, not a
# TMPDIR: macOS BSD mktemp IGNORES $TMPDIR for the `-d -t` shape these
# runners use (measured — the first draft of these legs TMPDIR-scoped the
# probe and passed VACUOUSLY on macOS; the no-rm reddening mutation exposed
# them). The shim logs the exact path the runner's own mktemp call created,
# then the leg asserts THAT path is gone after exit — run-scoped, no
# machine-global listing (R1-F2). The Linux half of the finding — bash 5.2
# firing a parent's EXIT trap inside forked children under load, deleting
# the scratch MID-TIER at 32-37/40 amplified — cannot be reproduced
# deterministically here; the structural fix is pinned by 12.39/12.40 (no
# EXIT trap to misfire) and the CI l1-unit/l2-component jobs run these
# runners on that platform every push.
life_scratch_after() {
    # life_scratch_after <runner> <root> [args...] — run the runner with the
    # mktemp shim on PATH; print 'gone' when the scratch it created no longer
    # exists, plus the runner's rc, as 'gone/rc'.
    local runner="$1" root="$2"; shift 2
    : > "$MKTEMP_LOG"
    PATH="$SHIM_BIN:$PATH" CLAUDE_PROJECT_DIR="$root" STRICT_SECTIONS=0 \
        bash "$runner" "$@" >/dev/null 2>&1
    local rc=$? scratch
    scratch=$(head -1 "$MKTEMP_LOG" 2>/dev/null)
    if [ -n "$scratch" ] && [ ! -d "$scratch" ]; then
        printf 'gone/%s' "$rc"
    else
        printf '%s/%s' "${scratch:-no-mktemp-call-logged}" "$rc"
    fi
}
assert_eq "12.35 L1 exit-0 path removes the scratch it created" \
    "gone/0" "$(life_scratch_after "$L1_RUNNER" "$FX_FULL")"
assert_eq "12.36 L1 floor-breach (exit 1) path removes the scratch" \
    "gone/1" "$(life_scratch_after "$L1_RUNNER" "$FX_SHRUNK")"
assert_eq "12.37 L1 zero-match (exit 2) path removes the scratch" \
    "gone/2" "$(life_scratch_after "$L1_RUNNER" "$FX_FULL" --filter zzz-none)"
assert_eq "12.38 L2 exit-0 path removes the scratch" \
    "gone/0" "$(life_scratch_after "$L2_RUNNER" "$FX_L2G")"
# The structural pin, with its control. This is a TEXT scan (the weaker kind
# of evidence — same caveat as section 9) and it exists because the failure
# it guards is nondeterministic: the runners must carry NO EXIT trap at all.
scan_exit_traps() { grep -cE '^[[:space:]]*trap[[:space:]]+[^-].*EXIT' "$1"; }
assert_eq "12.39 STRUCTURE: the L1 runner arms no EXIT trap (the R5-F1 machinery is gone, not guarded)" \
    "0" "$(scan_exit_traps "$L1_RUNNER")"
assert_eq "12.40 STRUCTURE: the L2 runner arms no EXIT trap outside the spec wrapper" \
    "1" "$(scan_exit_traps "$L2_RUNNER")"
# ^ the ONE match is the wrapper's summary trap INSIDE the bash -u -c string
#   (runs in the spec's process, which is fork-isolated from the runner and
#   already killable); the runner shell itself arms none.
FAKE_RUNNER="$WORK/fake-trap-runner.sh"
{
    printf '#!/bin/bash\n'
    printf 'trap cleanup_scratch EXIT\n'
} > "$FAKE_RUNNER"
assert_eq "12.41 CONTROL: the scan DOES count the pre-fix shape (a runner-level EXIT trap)" \
    "1" "$(scan_exit_traps "$FAKE_RUNNER")"

# --- 12g. the EXIT-trap chain convention across L2 specs. A spec that
# re-arms EXIT replaces the wrapper's summary trap; the runner scores the
# resulting summary-less exit-0 as FAILED (12.13/12.14 is the loud half —
# the ENFORCEMENT, verified by QA against real evasions), and this scan is
# the legible half only. WHAT IT COVERS, exactly (a9hh R7-F4 widened it
# from the canonical single-signal form, which was one of at least five
# ways to write the violation): `... EXIT` anywhere in the signal list,
# multi-signal forms (`EXIT INT`, `INT EXIT`), the numeric alias `0`, and
# trailing comments. WHAT IT CANNOT COVER: a signal spelled through a
# variable (`trap "..." "$SIG"`) is invisible to any static scan — that
# shape, and anything else exotic, is caught at runtime by the
# missing-summary FAILURE, which is the guarantee; this scan only makes
# the common forms cheap to catch early. Text scan with its own controls,
# section-9 style.
scan_unchained_traps() {
    grep -hE '^[[:space:]]*trap[[:space:]]+.*[[:space:]](EXIT|0)([[:space:]]|$)' "$1"/*.sh 2>/dev/null \
        | grep -vE '__spec_wrapper_exit|trap[[:space:]]+(-|--)[[:space:]]' \
        | grep -cv '^[[:space:]]*#'
}
REAL_SPECS_DIR="$PLUGIN_DIR/.claude/tests/component/specs"
assert_eq "12.42 every EXIT trap the scan can see in the shipped L2 specs chains __spec_wrapper_exit" \
    "0" "$(scan_unchained_traps "$REAL_SPECS_DIR")"
FX_TRAPSCAN="$WORK/trap-scan"
mkdir -p "$FX_TRAPSCAN"
BAD_TRAP_LINE='trap "rm -rf /somewhere" EXIT'
printf '#!/bin/bash\n%s\n' "$BAD_TRAP_LINE" > "$FX_TRAPSCAN/bad.sh"
printf '#!/bin/bash\ntrap "rm -rf /x; __spec_wrapper_exit" EXIT\n' > "$FX_TRAPSCAN/good.sh"
assert_eq "12.43 CONTROL: the scan flags an unchained spec-level EXIT trap (and not a chained one)" \
    "1" "$(scan_unchained_traps "$FX_TRAPSCAN")"
# The R7-F4 evasion shapes, one file each so a partial regression names the
# shape it lost. QA measured all four scoring 0 against the pre-widening
# scan while the canonical form scored 1; each is now individually pinned.
FX_TRAPEVADE="$WORK/trap-scan-evasions"
mkdir -p "$FX_TRAPEVADE/multi" "$FX_TRAPEVADE/leading" "$FX_TRAPEVADE/numeric" "$FX_TRAPEVADE/comment"
printf '#!/bin/bash\ntrap "rm -rf /x" EXIT INT\n'       > "$FX_TRAPEVADE/multi/spec.sh"
printf '#!/bin/bash\ntrap "rm -rf /x" INT EXIT\n'       > "$FX_TRAPEVADE/leading/spec.sh"
printf '#!/bin/bash\ntrap "rm -rf /x" 0\n'              > "$FX_TRAPEVADE/numeric/spec.sh"
printf '#!/bin/bash\ntrap "rm -rf /x" EXIT  # tidy\n'   > "$FX_TRAPEVADE/comment/spec.sh"
assert_eq "12.43a CONTROL: multi-signal EXIT INT no longer evades the scan (was: 0)" \
    "1" "$(scan_unchained_traps "$FX_TRAPEVADE/multi")"
assert_eq "12.43b CONTROL: INT EXIT (EXIT last) is flagged" \
    "1" "$(scan_unchained_traps "$FX_TRAPEVADE/leading")"
assert_eq "12.43c CONTROL: the numeric-0 alias no longer evades the scan (was: 0)" \
    "1" "$(scan_unchained_traps "$FX_TRAPEVADE/numeric")"
assert_eq "12.43d CONTROL: a trailing comment no longer evades the scan (was: 0)" \
    "1" "$(scan_unchained_traps "$FX_TRAPEVADE/comment")"
# Negative controls for the widening itself: a chained multi-signal trap, a
# trap RESET, and a RETURN trap (the one non-EXIT trap a shipped spec arms)
# must all stay invisible — the widened match must not have bought false
# positives. `exit 130`-style numerals must not read as the 0 alias.
FX_TRAPCLEAN="$WORK/trap-scan-clean"
mkdir -p "$FX_TRAPCLEAN"
{
    printf '#!/bin/bash\n'
    printf 'trap "rm -rf /x; __spec_wrapper_exit" EXIT INT\n'
    printf 'trap - EXIT\n'
    printf 'trap cleanup_paths RETURN 2>/dev/null || true\n'
    printf 'trap "exit 130" INT\n'
} > "$FX_TRAPCLEAN/spec.sh"
assert_eq "12.43e CONTROL: chained/reset/RETURN/numeral shapes stay invisible to the widened scan" \
    "0" "$(scan_unchained_traps "$FX_TRAPCLEAN")"

# --- 12h. a TERM handler that SPAWNS during the grace does not outlive the
# escalation (R6-F1). Sol's shape: a setsid'd shell whose TERM trap
# backgrounds a new child — the child is absent from the pre-TERM snapshot
# and outside the spec's group, so the single-snapshot escalation missed it
# (reproduced against the pre-fix runner on macOS AND Linux: interrupt path
# stranded the spawned child; the CAP path stranded the SHELL TOO, because
# the runner TERMed its own watchdog mid-grace and the KILL pass never ran).
# The fix is ONE bounded re-walk from live snapshot members plus letting a
# fired watchdog finish (marker-gated wait). The existing reaping mutations
# were run by hand in R6/R7 and observed red on exactly these legs: excising
# the RESNAPSHOT region reds 12.45 AND 12.46; reverting the marker-gated wait
# to the unconditional TERM reds 12.46 (and 5.9 — the truncated escalation
# never emits its refusers report). The R8-F1 attribution mutations are exact,
# and BOTH were run this round, in BOTH runners, each against the shipped
# spec: substituting `refused TERM, KILLed:` for `not in the TERM snapshot,
# KILLed:` (that is R8-F1 itself — a label claiming a signal the process never
# received), and substituting `discovered after TERM pass, KILLed:` (the FIRST
# attempt at fixing it — a label denying a signal the process demonstrably
# DID receive). MEASURED: each mutation reds exactly 12.46c, 12.47b and
# 12.47d, tier rc=1, with no other leg disturbed. They red the same three
# because each leg requires exactly one TRUE label and zero false ones for its
# uniquely identified process, and both substitutions make the true label
# absent. 12.44 is the existence probe, and 12.47c/12.47e — the controls that
# make 12.47d non-vacuous by observing the TERM and the kill themselves —
# stay green under both, which is what proves the reddening is about the
# ATTRIBUTION and not about the escalation having stopped working. Beyond one
# respawn —
# a handler that spawns and immediately dies — the escalation NAMES what it
# can still see rather than claiming a closed tree; chasing further is
# unwinnable in bash and is out of scope by R6 ruling.
if command -v perl >/dev/null 2>&1; then
    # The out-of-group shell + its trap-spawned child, one pair per leg so
    # pgrep tokens cannot cross-match.
    mk_respawn_pair() { # <tag> — writes $WORK/r6-outer-<tag>.sh and child
        local tag="$1"
        printf '#!/bin/bash\nexec -a %s-resp-%s sleep 31607\n' \
            "$HANG_TOKEN" "$tag" > "$WORK/r6-child-$tag.sh"
        {
            printf '#!/bin/bash\n'
            printf '# %s-shell-%s\n' "$HANG_TOKEN" "$tag"
            printf 'trap '\''bash "%s/r6-child-%s.sh" &'\'' TERM\n' "$WORK" "$tag"
            printf 'while :; do sleep 1; done\n'
        } > "$WORK/r6-outer-$tag.sh"
    }
    resp_probe() { # <tag> — alive|gone for the trap-spawned child
        pgrep -f "$HANG_TOKEN-resp-$1" >/dev/null 2>&1 && echo alive || echo gone
    }

    # L1 interrupt path.
    mk_respawn_pair int
    FX_RW1="$WORK/l1-respawn-int"
    mk_l1_fixture "$FX_RW1" "$((EXPECTED - 1))"
    cat > "$FX_RW1/.claude/scripts/tests/zz-respawn-holder.sh" <<EOF
#!/bin/bash
printf '  PASS: respawn probe launched\n'
perl -MPOSIX -e 'POSIX::setsid(); exec "bash","$WORK/r6-outer-int.sh"' &
wait
exit 0
EOF
    CLAUDE_PROJECT_DIR="$FX_RW1" STRICT_SECTIONS=0 \
        bash "$L1_RUNNER" > "$WORK/respawn-l1-int.log" 2>&1 &
    RW_RPID=$!
    RW_SEEN="no"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if pgrep -f "$WORK/r6-outer-int.sh" >/dev/null 2>&1; then RW_SEEN="yes"; break; fi
        sleep 1
    done
    assert_eq "12.44 the trap-armed out-of-group shell exists mid-spec (the escalation has something to miss)" \
        "yes" "$RW_SEEN"
    kill -TERM "$RW_RPID" 2>/dev/null
    wait "$RW_RPID" 2>/dev/null
    RW_RC=$?
    sleep 2
    assert_eq "12.45 interrupt: the child the TERM handler spawned DURING the grace did not survive (rc=$RW_RC; was: stranded past exit 130)" \
        "gone" "$(resp_probe int)"
    pkill -9 -f "$HANG_TOKEN-resp-int" 2>/dev/null
    pkill -9 -f "$WORK/r6-outer-int.sh" 2>/dev/null

    # L1 watchdog CAP path — additionally exercises the marker-gated wait:
    # pre-fix, the leader died at the polite TERM, `wait` returned, and the
    # runner TERMed the watchdog before its KILL pass — shell AND child
    # both survived the tier.
    mk_respawn_pair cap
    FX_RW2="$WORK/l1-respawn-cap"
    mk_l1_fixture "$FX_RW2" "$((EXPECTED - 1))"
    cat > "$FX_RW2/.claude/scripts/tests/zz-respawn-holder.sh" <<EOF
#!/bin/bash
printf '  PASS: respawn probe launched\n'
perl -MPOSIX -e 'POSIX::setsid(); exec "bash","$WORK/r6-outer-cap.sh"' &
wait
exit 0
EOF
    SPEC_TIMEOUT_S=4 CLAUDE_PROJECT_DIR="$FX_RW2" STRICT_SECTIONS=0 \
        bash "$L1_RUNNER" > "$WORK/respawn-l1-cap.log" 2>&1
    RW_RC=$?
    sleep 1
    assert_eq "12.46 cap: neither the trap-spawning shell nor its grace-window child survived the watchdog (was: BOTH outlived the tier)" \
        "gone/gone" "$(pgrep -f "$WORK/r6-outer-cap.sh" >/dev/null 2>&1 && echo alive || echo gone)/$(resp_probe cap)"
    assert_eq "12.46b ...and the tier failed the spec as a TIMEOUT (rc=1), never a pass" "1" "$RW_RC"
    RW_ATTR=$(grep -F "$HANG_TOKEN-resp-cap" "$WORK/respawn-l1-cap.log" 2>/dev/null || true)
    assert_eq "12.46c ...and the grace-window child — which was BORN after the TERM pass and never received one — is named by snapshot membership, never as a TERM refuser (R8-F1)" \
        "1/0" "$(printf '%s\n' "$RW_ATTR" | grep -cF 'not in the TERM snapshot, KILLed:')/$(printf '%s\n' "$RW_ATTR" | grep -cF 'refused TERM, KILLed:')"
    pkill -9 -f "$HANG_TOKEN-resp-cap" 2>/dev/null
    pkill -9 -f "$WORK/r6-outer-cap.sh" 2>/dev/null

    # L2 cap path — the mirrored escalation, through the mirrored runner.
    mk_respawn_pair l2c
    FX_RW3="$WORK/l2-respawn-cap"
    mk_l2_fixture "$FX_RW3"
    cat > "$FX_RW3/.claude/tests/component/specs/l2-respawn-holder.sh" <<EOF
perl -MPOSIX -e 'POSIX::setsid(); exec "bash","$WORK/r6-outer-l2c.sh"' &
wait
EOF
    SPEC_TIMEOUT_S=4 CLAUDE_PROJECT_DIR="$FX_RW3" \
        bash "$L2_RUNNER" > "$WORK/respawn-l2-cap.log" 2>&1
    RW_RC2=$?
    sleep 1
    assert_eq "12.47 L2 cap: shell and grace-window child both reaped (rc=$RW_RC2)" \
        "gone/gone" "$(pgrep -f "$WORK/r6-outer-l2c.sh" >/dev/null 2>&1 && echo alive || echo gone)/$(resp_probe l2c)"
    RW_ATTR2=$(grep -F "$HANG_TOKEN-resp-l2c" "$WORK/respawn-l2-cap.log" 2>/dev/null || true)
    assert_eq "12.47b L2 names its grace-window child by snapshot membership too, never as a TERM refuser (the mirrored R8-F1)" \
        "1/0" "$(printf '%s\n' "$RW_ATTR2" | grep -cF 'not in the TERM snapshot, KILLed:')/$(printf '%s\n' "$RW_ATTR2" | grep -cF 'refused TERM, KILLed:')"
    pkill -9 -f "$HANG_TOKEN-resp-l2c" 2>/dev/null
    pkill -9 -f "$WORK/r6-outer-l2c.sh" 2>/dev/null
else
    printf '  SKIPPED: perl not on PATH — the respawn escalation legs (12.44-12.47) need it\n'
fi

# --- 12h (cont.). THE OTHER POPULATION of that same non-snapshot line — found
# by reproducing R8-F1 rather than by reading about it. A process double-forked
# BEFORE the snapshot has ppid=1, so tree_pids cannot reach it; but it kept the
# spec's pgid, so the GROUP TERM did reach it and it is free to refuse. It is
# therefore absent from the snapshot AND a genuine TERM refuser — which is why
# the non-snapshot line states membership and nothing else. The first attempt
# at fixing R8-F1 labelled this line "discovered after TERM pass", which is
# R8-F1 inverted: it denies a signal-handling defect that IS there. Reproduced
# against the shipped escalation before this leg was written (`( bash x & )`
# from a spec, ppid=1 / pgid=spec, named as a post-TERM discovery).
#
# The orphan RECORDS its own TERM, so 12.47c OBSERVES delivery instead of
# arguing it, and 12.47d is then a check on a claim already known to be false
# under the old label. The escalation KILLs the group immediately after naming
# and the post-wait sweep only runs once the fired watchdog has finished, so
# the escalation's own group TERM is the only TERM that can have written that
# file. The process is identified by the PID it recorded — not by a pgrep
# literal — which is R1-F2's scoping discipline taken to its limit and also
# immune to the 160-column arg cut in name_group_members. No perl here: this
# shape needs no setsid, so these legs also cover the perl-less machine where
# 12.44-12.47 skip.
# What reddens 12.47d: restore either wrong label — `refused TERM, KILLed:`
# (R8-F1) or `discovered after TERM pass, KILLed:` (its inverse) — as the
# non-snapshot label in run-tests.sh. Both were run this round and both
# observed red here (0/0 and 0/1 respectively, against the required 1/0),
# alongside 12.46c and 12.47b, tier rc=1. What reddens 12.47c: drop the group
# TERM from escalate_kill — nothing else delivers a signal to a process that
# is off the ppid chain, so the delivery this leg observes disappears.
ORPH_MARK="$WORK/orphan-got-term"
ORPH_PIDF="$WORK/orphan-pid"
ORPH_SH="$WORK/r8-orphan.sh"
{
    printf '#!/bin/bash\n'
    printf 'printf "%%s" "$$" > "%s"\n' "$ORPH_PIDF"
    printf 'trap '\''printf t >> "%s"'\'' TERM\n' "$ORPH_MARK"
    # 0.2s, not 1s: bash defers a trap until the running foreground command
    # returns, and the escalation's grace is 2s. A 1s sleep leaves the record
    # of delivery racing the KILL pass on a loaded runner; 0.2s leaves it a
    # 10x margin. (Both runners already assume fractional sleep.)
    printf 'while :; do sleep 0.2; done\n'
} > "$ORPH_SH"
FX_ORPH="$WORK/l1-orphan-group"
mk_l1_fixture "$FX_ORPH" "$((EXPECTED - 1))"
cat > "$FX_ORPH/.claude/scripts/tests/zz-orphan-group.sh" <<EOF
#!/bin/bash
printf '  PASS: double-forked group member launched\n'
( bash "$ORPH_SH" & )
while :; do sleep 1; done
EOF
SPEC_TIMEOUT_S=4 CLAUDE_PROJECT_DIR="$FX_ORPH" STRICT_SECTIONS=0 \
    bash "$L1_RUNNER" > "$WORK/orphan-l1-cap.log" 2>&1
ORPH_RC=$?
sleep 1
ORPH_PID=$(cat "$ORPH_PIDF" 2>/dev/null || true)
assert_eq "12.47c the double-forked member ran and DID receive the group TERM (its own handler recorded it), under a tier the cap turned red" \
    "pid/term/1" "$([ -n "$ORPH_PID" ] && echo pid || echo nopid)/$([ -s "$ORPH_MARK" ] && echo term || echo noterm)/$ORPH_RC"
ORPH_ATTR=$(grep -E "KILLed: ${ORPH_PID:-none} " "$WORK/orphan-l1-cap.log" 2>/dev/null || true)
assert_eq "12.47d ...and the escalation names it by snapshot MEMBERSHIP — never as a post-TERM discovery, which would deny the TERM 12.47c just observed" \
    "1/0" "$(printf '%s\n' "$ORPH_ATTR" | grep -cF 'not in the TERM snapshot, KILLed:')/$(printf '%s\n' "$ORPH_ATTR" | grep -cF 'discovered after TERM pass, KILLed:')"
# `${ORPH_PID:-1}` for the PROBE only: an unrecorded pid must read "alive" and
# redden the leg rather than pass by vacuity. The teardown below is guarded
# instead of defaulted — `kill -9 1` under the root user CI actually runs as
# would signal the container's init, and a test that can kill its own runner
# is not a test.
assert_eq "12.47e ...and it did not outlive the tier (the KILL pass is group-wide, and it never left the group)" \
    "gone" "$(kill -0 "${ORPH_PID:-1}" 2>/dev/null && echo alive || echo gone)"
[ -n "$ORPH_PID" ] && kill -9 "$ORPH_PID" 2>/dev/null
true

# --- 12i. SIGHUP routes through the interrupt path (R7-F3). Untrapped, a
# closed terminal killed the runner at exit 129 with `finish` unreached —
# the scratch dir leaked 5/5 on BOTH pre-fix runners (measured macOS and
# Linux; the one abnormal-exit path an ordinary user actually hits). Now
# HUP is trapped alongside INT/TERM: cleanup runs, exit is 130. The mktemp
# SHIM is the probe, for 12f's reason. What reddens these: remove HUP from
# either trap line (the pre-fix state — run by hand, observed red).
hup_scratch_after() { # <runner> <root> — 'rc/gone|LEAKED' after HUP mid-tier
    local runner="$1" root="$2" rpid rc scratch
    : > "$MKTEMP_LOG"
    PATH="$SHIM_BIN:$PATH" CLAUDE_PROJECT_DIR="$root" STRICT_SECTIONS=0 \
        bash "$runner" >/dev/null 2>&1 &
    rpid=$!
    sleep 2
    kill -HUP "$rpid" 2>/dev/null
    wait "$rpid" 2>/dev/null
    rc=$?
    sleep 1
    scratch=$(head -1 "$MKTEMP_LOG" 2>/dev/null)
    if [ -n "$scratch" ] && [ ! -d "$scratch" ]; then
        printf '%s/gone' "$rc"
    else
        printf '%s/LEAKED:%s' "$rc" "${scratch:-no-mktemp-call-logged}"
    fi
}
FX_HUP1="$WORK/l1-hup"
mk_l1_fixture "$FX_HUP1" "$EXPECTED"
cat > "$FX_HUP1/.claude/scripts/tests/stub-001.sh" <<'EOF'
#!/bin/bash
printf '  PASS: slow stub holds the tier open\n'
sleep 6
EOF
assert_eq "12.48 L1: SIGHUP mid-tier cleans the scratch and exits via the interrupt path (was: rc=129, leaked 5/5)" \
    "130/gone" "$(hup_scratch_after "$L1_RUNNER" "$FX_HUP1")"
FX_HUP2="$WORK/l2-hup"
mk_l2_fixture "$FX_HUP2"
cat > "$FX_HUP2/.claude/tests/component/specs/l2-slow.sh" <<'EOF'
assert_eq "l2-slow ran" "x" "x"
sleep 6
EOF
assert_eq "12.49 L2: SIGHUP mid-tier cleans the scratch and exits via the interrupt path" \
    "130/gone" "$(hup_scratch_after "$L2_RUNNER" "$FX_HUP2")"

# --- 12j. the L2 PARTIAL annotation (R7-F2): a pass whose transcript holds
# a skip marker says so in every layer — verdict line (12.11 above), the
# Partial counter, the named list, and the completeness caveat. Measured
# need: under BD_SHIM_ONLY=1 CI, post-edit.sh was an unqualified
# `PASSED (101 assertion(s))` out of a 115-assertion full run — the a9hh
# section-skip defect one tier down, L1 grew the counter, L2 had none.
run_l2 "$FX_L2PE"
assert_contains "12.50 the pass-then-skip spec is COUNTED partial in the summary" \
    "Skipped: 0  Partial: 1" "$RUN_OUT"
assert_contains "12.51 the PARTIAL list names the spec AND quotes its marker" \
    "l2-pass-then-skip.sh — 1 skip marker(s), 1 assertion(s) ran; first: SKIPPED: l2-pass-then-skip.sh" "$RUN_OUT"
assert_contains "12.52 the completeness caveat carries the partial count" \
    "COMPLETENESS: 0 of 1 spec(s) skipped, 1 partial" "$RUN_OUT"
run_l2 "$FX_L2G"
assert_contains "12.53 CONTROL: a clean pass is NOT partial" \
    "Skipped: 0  Partial: 0" "$RUN_OUT"
# THE MUTANT: the L2-PARTIAL region excised — the R7-F2 world on demand.
MUT_L2PART="$WORK/run.no-partial.sh"
awk '
    /L2-PARTIAL-BEGIN/ { skipping=1; found=1; next }
    /L2-PARTIAL-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L2_RUNNER" > "$MUT_L2PART"
assert_eq "12.54 MUTANT: the L2-PARTIAL region FOUND and excised, differs, parses" \
    "0-differs-0" "$?-$(cmp -s "$L2_RUNNER" "$MUT_L2PART" && echo identical || echo differs)-$(bash -n "$MUT_L2PART" 2>/dev/null; echo $?)"
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2PE" bash "$MUT_L2PART" 2>&1)
RUN_RC=$?
assert_contains "12.55 SPECIFIC: the mutant reads the SAME fixture as an UNQUALIFIED pass with Partial: 0 — R7-F2 on display" \
    "l2-pass-then-skip.sh: PASSED (1 assertion(s)" "$RUN_OUT"
assert_contains "12.56 SPECIFIC: with a green Partial-free summary over it" \
    "Skipped: 0  Partial: 0" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 13. THE STORE CANARY: run-tests.sh fails a spec BY NAME when it (or a concurrent writer) moves the protected Beads store (claude-workflow-plugin-j7kk) ---\n'
# ===========================================================================
# THE STRUCTURAL GUARD, and why it had to be one. model-roles.test.sh — one of
# the shipped L1 runner's own 39 specs — was measured CAN-REACH(WRITE) against
# PRODUCTION: 417 repo-root-cwd bd calls in one run (186 comment, 151 show, 35
# create, 35 list, 10 --version), and store-side the task
# claude-workflow-plugin-ofd carried 9,937+ synthetic `MODEL SWITCH` comments
# before that spec's own isolation was fixed. The other 38 specs are isolated
# by SEVEN different, undeclared conventions (cd into a fixture store;
# explicit `bd -C <dir>`; a fixture bin/bd stub; a callee that cds itself; a
# store-independent subcommand; no bd call on the path at all) and nothing
# states which is required — so the NEXT spec author can reproduce exactly
# this defect. The canary is the fix for THAT: it fails, by name, any spec
# whose window leaves the production store's HEAD net-changed (R4-F3,
# independent review round 4: mere resolution to the production store is
# not what this detects — see section 13s below for the KNOWN LIMIT this
# contract accepts), regardless of which of the seven (or an eighth nobody
# has invented yet) a future spec omits.
#
# Fixture store, using the runner's OWN existing lever (CLAUDE_PROJECT_DIR) —
# no new env knob, and no need to contaminate production to prove the
# anti-contamination guard works.
if ! command -v bd >/dev/null 2>&1 || ! command -v dolt >/dev/null 2>&1; then
    printf '  SKIPPED: bd and/or dolt not on PATH — the store-canary legs (13a-13e) need both\n'
else
    FX_CANARY="$WORK/store-canary"
    FX_READONLY="$WORK/store-canary-readonly"
    mkdir -p "$FX_CANARY" "$FX_READONLY"
    # --database beads matches THIS repo's OWN embedded-Dolt layout
    # (.beads/embeddeddolt/beads/.dolt) — the subdirectory name is NOT a
    # fixed "beads" literal in general (a fresh `bd init` with no --database
    # names it after the CURRENT DIRECTORY: measured here, a fixture at
    # .../dryrun-fx defaulted to embeddeddolt/dryrun_fx/.dolt), so a fixture
    # built without this flag would silently DISARM every leg below — the
    # exact vacuity class this whole convention exists to catch. Explicit
    # here rather than assumed.
    ( cd "$FX_CANARY" && bd init --database beads --non-interactive >/dev/null 2>&1 )
    if [ ! -d "$FX_CANARY/.beads/embeddeddolt/beads/.dolt" ]; then
        printf '  SKIPPED: could not initialise a fixture Dolt store at .beads/embeddeddolt/beads/.dolt for the store-canary legs\n'
    else
        # Clone BEFORE any contamination, so the read-only control fixture
        # (13c) starts from the identical pristine state.
        cp -R "$FX_CANARY/.beads" "$FX_READONLY/.beads" 2>/dev/null

        mk_l1_fixture "$FX_CANARY" "$((EXPECTED - 1))"
        cat > "$FX_CANARY/.claude/scripts/tests/zz-contaminator.sh" <<'EOF'
#!/bin/bash
printf '  PASS: contaminator ran\n'
# Mechanism A (cd into the fixture store) — the ONLY way this bd call can
# reach THIS spec's own store rather than wherever run-tests.sh's cwd
# happens to be: bd resolves its store from cwd alone, never from
# CLAUDE_PROJECT_DIR (claude-workflow-plugin-j7kk census, section 1.0).
cd "$(dirname "$0")/../../.." && bd create "canary probe" -t task -p 4 >/dev/null 2>&1
exit 0
EOF

        mk_l1_fixture "$FX_READONLY" "$((EXPECTED - 1))"
        cat > "$FX_READONLY/.claude/scripts/tests/zz-reader.sh" <<'EOF'
#!/bin/bash
printf '  PASS: reader ran\n'
cd "$(dirname "$0")/../../.." && bd list --json >/dev/null 2>&1
exit 0
EOF

        sc_hash() {
            # sc_hash <fixture-root>
            ( cd "$1/.beads/embeddeddolt/beads" 2>/dev/null \
                && dolt sql -r csv -q "SELECT hashof('HEAD')" 2>/dev/null | tail -n1 )
        }

        # -----------------------------------------------------------------
        printf -- '\n--- 13a. NON-VACUITY: the STORE-CANARY sentinel regions were FOUND and excised (the ARM region, and BOTH per-spec occurrences) ---\n'
        # -----------------------------------------------------------------
        # The per-spec sentinel pair (STORE-CANARY-BEGIN/END) is deliberately
        # used TWICE in the shipped runner — once around the per-spec
        # SAMPLING (after the survivor sweep) and once around the VERDICT
        # elif (immediately before TRANSCRIPT-FAIL) — because the detection
        # and the classification live ~90 lines apart, separated by
        # unrelated TIMEOUT/rc/SURVIVOR_COUNT logic that must NOT be
        # touched. A single awk pass toggling on ANY matching BEGIN/END
        # excises both, restoring pre-guard behaviour byte-for-byte.
        assert_eq "13a.1 the ARM sentinel pair is present exactly once in the shipped runner" \
            "1 1" "$(grep -c 'STORE-CANARY-ARM-BEGIN' "$L1_RUNNER") $(grep -c 'STORE-CANARY-ARM-END' "$L1_RUNNER")"
        assert_eq "13a.2 the per-spec sentinel pair occurs exactly twice (sampling + verdict)" \
            "2 2" "$(grep -c 'STORE-CANARY-BEGIN' "$L1_RUNNER") $(grep -c 'STORE-CANARY-END' "$L1_RUNNER")"
        MUT_SC="$WORK/run-tests.no-canary.sh"
        awk '
            /STORE-CANARY-ARM-BEGIN/ { skipping=1; foundArm=1; next }
            /STORE-CANARY-ARM-END/   { skipping=0; next }
            /STORE-CANARY-BEGIN/     { skipping=1; foundSpec++; next }
            /STORE-CANARY-END/       { skipping=0; next }
            !skipping { print }
            END { if (!foundArm) exit 7; if (foundSpec != 2) exit 8 }
        ' "$L1_RUNNER" > "$MUT_SC"
        AWK_SC_RC=$?
        assert_eq "13a.3 MUTANT: both the ARM region and both per-spec occurrences were FOUND and excised (awk found-check)" "0" "$AWK_SC_RC"
        assert_eq "13a.4 MUTANT: the mutant differs from the shipped runner (the excision landed)" \
            "differs" "$(cmp -s "$L1_RUNNER" "$MUT_SC" && echo identical || echo differs)"
        assert_eq "13a.5 MUTANT: the mutant still parses (bash -n)" \
            "0" "$(bash -n "$MUT_SC" 2>/dev/null; echo $?)"
        # NOT a bare "STORE-CANARY absent from the mutant" check: the four
        # state vars (PROTECTED_STORE, STORE_CANARY_ARMED,
        # STORE_CANARY_DISARM_REASON, STORE_HASH_BEFORE) are DELIBERATELY
        # initialised OUTSIDE this sentinel, exactly like SURVIVOR_COUNT
        # above — so the excised mutant still runs under `set -u` and the
        # tail summary's DISARMED reprint (also outside any sentinel) still
        # fires safely instead of aborting on an unbound variable. What must
        # be gone is the ARM's OWN diagnostic — proof the DETECTION
        # mechanism, not merely its safe-default fallback text, was excised.
        assert_eq "13a.6 MUTANT: the ARM's own arm-time diagnostic is gone (the detection mechanism itself was excised, not just its tail-summary fallback)" \
            "0" "$(grep -c 'ARMED — watching' "$MUT_SC")"

        # -----------------------------------------------------------------
        printf -- '\n--- 13b. SPECIFIC MISBEHAVIOUR: with the canary excised, a contaminating spec is PASSED, unreported ---\n'
        # -----------------------------------------------------------------
        HASH_BEFORE_B=$(sc_hash "$FX_CANARY")
        run_l1 "$FX_CANARY" "$MUT_SC"
        HASH_AFTER_B=$(sc_hash "$FX_CANARY")
        assert_eq "13b.1 the fixture store's HEAD actually moved (the contaminator really did write — otherwise this leg proves nothing)" \
            "differs" "$([ "$HASH_BEFORE_B" != "$HASH_AFTER_B" ] && echo differs || echo same)"
        assert_eq "13b.2 the mutant runner exits 0 over the contaminating spec" "0" "$RUN_RC"
        assert_contains "13b.3 the mutant classifies the contaminating spec PASSED" \
            "zz-contaminator.sh: PASSED" "$RUN_OUT"
        assert_contains "13b.4 the mutant's summary says Failed: 0" \
            "Failed: 0" "$RUN_OUT"
        assert_eq "13b.5 no verdict line anywhere mentions the protected store" \
            "0" "$(printf '%s' "$RUN_OUT" | grep -c 'protected Beads store')"

        # -----------------------------------------------------------------
        printf -- '\n--- 13c. RESTORE CONTROL: the SHIPPED runner, a read-only spec, a pristine fixture store — green, unmoved, no false positive ---\n'
        # -----------------------------------------------------------------
        # The false-positive control: a canary that fires on an ORDINARY
        # READ would be a control nobody could leave armed (precedent: the
        # P-B stability measurement in run-tests.sh's own ARM block —
        # 12 consecutive bd reads, zero false positives).
        HASH_BEFORE_C=$(sc_hash "$FX_READONLY")
        run_l1 "$FX_READONLY"
        HASH_AFTER_C=$(sc_hash "$FX_READONLY")
        assert_eq "13c.1 RESTORE CONTROL: the shipped runner over a read-only fixture is green (rc=0)" "0" "$RUN_RC"
        assert_contains "13c.2 ...the reader spec PASSED" "zz-reader.sh: PASSED" "$RUN_OUT"
        assert_eq "13c.3 ...and the fixture store's HEAD did not move (no false positive on an ordinary read)" \
            "$HASH_BEFORE_C" "$HASH_AFTER_C"
        assert_absent "13c.4 ...with no contamination line anywhere in a clean run" \
            "protected Beads store" "$RUN_OUT"

        # -----------------------------------------------------------------
        printf -- '\n--- 13d. EXECUTION (the discriminator): the SHIPPED runner catches the SAME contaminator the mutant missed at 13b ---\n'
        # -----------------------------------------------------------------
        run_l1 "$FX_CANARY"
        assert_eq "13d.1 SPECIFIC: the shipped runner exits non-zero over the contaminating spec" "1" "$RUN_RC"
        assert_contains "13d.2 ...the failed-files entry NAMES the contaminating spec" \
            "zz-contaminator.sh" "$(printf '%s\n' "$RUN_OUT" | grep -A3 'Failed tests:')"
        assert_contains "13d.3 ...the verdict line names the fixture store path" \
            "$FX_CANARY/.beads" "$RUN_OUT"
        assert_contains "13d.4 ...and the printed detail names the bd verb that wrote" \
            "bd: create" "$RUN_OUT"

        # -----------------------------------------------------------------
        printf -- '\n--- 13e. DISARM: a target with .beads/ but no embedded-Dolt store DISARMS loudly, and the tier still exits 0 ---\n'
        # -----------------------------------------------------------------
        FX_NODOLT="$WORK/store-canary-no-dolt"
        mk_l1_fixture "$FX_NODOLT" "$EXPECTED"
        mkdir -p "$FX_NODOLT/.beads"
        run_l1 "$FX_NODOLT"
        assert_eq "13e.1 a target with .beads/ but no embedded Dolt store still exits 0 (nothing to contaminate)" "0" "$RUN_RC"
        assert_contains "13e.2 ...and says so LOUDLY, both inline and in the summary (DISARMED is never a silent pass)" \
            "STORE-CANARY: DISARMED" "$RUN_OUT"
        assert_eq "13e.3 ...printed exactly twice (arm time + summary reprint)" \
            "2" "$(printf '%s\n' "$RUN_OUT" | grep -c 'STORE-CANARY: DISARMED')"

        # -----------------------------------------------------------------
        printf -- '\n--- 13f. claude-workflow-plugin-j7kk R1-F2: a NON-DESCENDANT store move (rollback/reset class) is NOT silently read as 0 writes ---\n'
        # -----------------------------------------------------------------
        # `dolt log A..B` traverses "commits reachable from B, not from A" —
        # EMPTY whenever B is an ANCESTOR of A rather than a descendant reached
        # by NEW commits on top of it. The v65-to-v53 Dolt schema rollback
        # performed during this batch is the live example of the class; this
        # leg reproduces it synthetically with `dolt reset --hard` back to an
        # ancestor commit, confirmed against the real `dolt log` CLI (13f.1-3)
        # before any runner is involved.
        FX_ROLLBACK_MUT="$WORK/store-canary-rollback-mut"
        FX_ROLLBACK_SHIP="$WORK/store-canary-rollback-ship"
        mkdir -p "$FX_ROLLBACK_MUT"
        ( cd "$FX_ROLLBACK_MUT" && bd init --database beads --non-interactive >/dev/null 2>&1 )
        if [ ! -d "$FX_ROLLBACK_MUT/.beads/embeddeddolt/beads/.dolt" ]; then
            printf '  SKIPPED: could not initialise a fixture Dolt store for the 13f non-descendant leg\n'
        else
            RB_ANCESTOR=$(sc_hash "$FX_ROLLBACK_MUT")
            ( cd "$FX_ROLLBACK_MUT" && bd create "13f seed" -t task -p 4 >/dev/null 2>&1 )
            RB_DESCENDANT=$(sc_hash "$FX_ROLLBACK_MUT")
            assert_eq "13f.1 precondition: the seed commit really advanced HEAD (a descendant of the ancestor)" \
                "differs" "$([ "$RB_ANCESTOR" != "$RB_DESCENDANT" ] && echo differs || echo same)"
            RB_LOG_FORWARD=$(cd "$FX_ROLLBACK_MUT/.beads/embeddeddolt/beads" \
                && dolt log --oneline "$RB_ANCESTOR".."$RB_DESCENDANT" 2>/dev/null | wc -l | tr -d ' ')
            assert_eq "13f.2 precondition: the FORWARD range (ancestor..descendant) is non-empty (sanity: dolt log itself works here)" \
                "yes" "$([ "$RB_LOG_FORWARD" -gt 0 ] && echo yes || echo no)"
            RB_LOG_BACK=$(cd "$FX_ROLLBACK_MUT/.beads/embeddeddolt/beads" \
                && dolt log --oneline "$RB_DESCENDANT".."$RB_ANCESTOR" 2>/dev/null | wc -l | tr -d ' ')
            assert_eq "13f.3 precondition: the REVERSE range (descendant..ancestor) is EMPTY — the exact shape R1-F2 targets, confirmed before any runner is involved" \
                "0" "$RB_LOG_BACK"

            # Clone the SEEDED (descendant) state for the shipped-execution leg
            # BEFORE any rollback spec runs — the same clone-before-contamination
            # convention $FX_READONLY uses above, so both legs drive the
            # IDENTICAL starting state.
            mkdir -p "$FX_ROLLBACK_SHIP"
            cp -R "$FX_ROLLBACK_MUT/.beads" "$FX_ROLLBACK_SHIP/.beads"

            mk_l1_fixture "$FX_ROLLBACK_MUT" "$((EXPECTED - 1))"
            cat > "$FX_ROLLBACK_MUT/.claude/scripts/tests/zz-rollback.sh" <<EOF
#!/bin/bash
printf '  PASS: rollback spec ran\n'
cd "\$(dirname "\$0")/../../../.beads/embeddeddolt/beads" && dolt reset --hard $RB_ANCESTOR >/dev/null 2>&1
exit 0
EOF
            chmod +x "$FX_ROLLBACK_MUT/.claude/scripts/tests/zz-rollback.sh"

            mk_l1_fixture "$FX_ROLLBACK_SHIP" "$((EXPECTED - 1))"
            cat > "$FX_ROLLBACK_SHIP/.claude/scripts/tests/zz-rollback.sh" <<EOF
#!/bin/bash
printf '  PASS: rollback spec ran\n'
cd "\$(dirname "\$0")/../../../.beads/embeddeddolt/beads" && dolt reset --hard $RB_ANCESTOR >/dev/null 2>&1
exit 0
EOF
            chmod +x "$FX_ROLLBACK_SHIP/.claude/scripts/tests/zz-rollback.sh"

            # MUTANT: revert R1-F2 — the branch that escalates a well-formed
            # "0" to STORE_WRITES=1 is disabled, restoring the pre-fix
            # behaviour where a non-descendant move stays silently 0. The
            # condition this targets grew an OR-clause under R4-F2
            # (independent review round 4: STORE_WRITES_UNREADABLE, a
            # SEPARATE non-authoritative-count case — see 13v) sharing the
            # same `if`; `if false` disables the escalation in EITHER form,
            # which is what "restore the pre-fix behaviour" means here, and
            # is harmless to this leg specifically because a genuine
            # non-descendant `dolt reset --hard` (built below) is a
            # well-formed "0" read, never the UNREADABLE shape R4-F2 added.
            MUT_SC_NONDESC="$WORK/run-tests.no-nondescendant-fix.sh"
            # shellcheck disable=SC2016  # single-quoted on purpose: matching
            # literal source text in $L1_RUNNER, not expanding a variable.
            sed 's/if \[ "\$STORE_WRITES" = "0" \] || \[ "\$STORE_WRITES_UNREADABLE" = "1" \]; then/if false; then/' \
                "$L1_RUNNER" > "$MUT_SC_NONDESC"
            assert_eq "13f.4 MUTANT non-vacuity: the mutant differs from the shipped runner (the R1-F2 branch guard was excised)" \
                "differs" "$(cmp -s "$L1_RUNNER" "$MUT_SC_NONDESC" && echo identical || echo differs)"
            assert_eq "13f.5 MUTANT: still parses (bash -n)" \
                "0" "$(bash -n "$MUT_SC_NONDESC" 2>/dev/null; echo $?)"

            run_l1 "$FX_ROLLBACK_MUT" "$MUT_SC_NONDESC"
            assert_eq "13f.6 SPECIFIC MISBEHAVIOUR: under the pre-R1-F2 mutant, a non-descendant store move exits 0 (silently passed)" "0" "$RUN_RC"
            assert_contains "13f.7 ...the rollback spec is classified PASSED" \
                "zz-rollback.sh: PASSED" "$RUN_OUT"
            assert_eq "13f.8 ...and Failed: 0 (the move went completely unreported)" \
                "1" "$(printf '%s' "$RUN_OUT" | grep -c 'Failed: 0')"
            assert_eq "13f.9 ...no verdict line anywhere mentions the protected store (the exact silent-pass R1-F2 describes)" \
                "0" "$(printf '%s' "$RUN_OUT" | grep -c 'protected Beads store')"

            # EXECUTION (the discriminator): the SHIPPED runner, the IDENTICAL
            # rollback spec and starting state, catches it.
            run_l1 "$FX_ROLLBACK_SHIP"
            assert_eq "13f.10 EXECUTION: the SHIPPED runner exits non-zero over the SAME non-descendant move the mutant missed at 13f.6" "1" "$RUN_RC"
            assert_contains "13f.11 ...the failed-files entry NAMES the rollback spec" \
                "zz-rollback.sh" "$(printf '%s\n' "$RUN_OUT" | grep -A3 'Failed tests:')"
            assert_contains "13f.12 ...and the printed detail says NON-LINEAR rather than fabricating a commit count" \
                "NON-LINEAR" "$RUN_OUT"
        fi

        # -----------------------------------------------------------------
        printf -- '\n--- 13q. claude-workflow-plugin-gytz R3-F1 (HIGH), shape half: dolt_hash_looks_valid() is a POSITIVE allow-list, driven from the SHIPPED definition ---\n'
        # -----------------------------------------------------------------
        # Extracted from $L1_RUNNER by its own `name() {` .. `}` range, never
        # re-typed here -- same technique as doc-only-classifier.test.sh's
        # is_doc_only_path extraction, so the thing under test is the
        # shipped definition, free to drift only if this extraction breaks.
        SC_SHAPE_LIB="$WORK/dolt-hash-shape.sh"
        awk '/^dolt_hash_looks_valid\(\) \{/,/^\}/' "$L1_RUNNER" > "$SC_SHAPE_LIB"
        assert_eq "13q.1 the extraction defines dolt_hash_looks_valid" "1" \
            "$(grep -c '^dolt_hash_looks_valid() {$' "$SC_SHAPE_LIB")"
        assert_eq "13q.2 the extraction parses" "0" \
            "$(bash -n "$SC_SHAPE_LIB" 2>/dev/null; echo $?)"

        # sc_shape_check <value> -> "valid"/"invalid" via the SHIPPED
        # function, one bash per call so a value containing shell
        # metacharacters can never leak into this process.
        sc_shape_check() {
            bash -c '. "$1"; dolt_hash_looks_valid "$2" && echo valid || echo invalid' \
                -- "$SC_SHAPE_LIB" "$1"
        }

        # A REAL hash, sampled earlier in this same section (HASH_BEFORE_C,
        # 13c) -- the actual artifact this function has to accept, not a
        # hand-typed lookalike.
        assert_eq "13q.3 a REAL sampled dolt hash is accepted" \
            "valid" "$(sc_shape_check "$HASH_BEFORE_C")"
        assert_eq "13q.4 a SECOND, independently sampled real hash is also accepted (13q.3 was not a one-off)" \
            "valid" "$(sc_shape_check "$(sc_hash "$FX_READONLY")")"

        # The exact adversarial set R3-F1 named: empty output, the CSV
        # header echo (the pre-fix denylist's other explicit branch), NULL,
        # whitespace, a dolt error string, wrong length both directions, and
        # wrong alphabet -- every one of these is what "anything non-empty
        # that doesn't say hashof" used to accept as a valid baseline.
        assert_eq "13q.5 empty output is rejected" "invalid" "$(sc_shape_check '')"
        assert_eq "13q.6 the CSV header echo is rejected" "invalid" \
            "$(sc_shape_check "hashof('HEAD')")"
        assert_eq "13q.7 literal NULL is rejected" "invalid" "$(sc_shape_check 'NULL')"
        assert_eq "13q.8 whitespace is rejected" "invalid" "$(sc_shape_check '   ')"
        assert_eq "13q.9 a real dolt error string is rejected" "invalid" \
            "$(sc_shape_check "error on line 1 for query SELECT hashof('HEAD'): database not found")"
        assert_eq "13q.10 31 characters (one short) is rejected" "invalid" \
            "$(sc_shape_check '0123456789abcdefghijklmnopqrst')"
        assert_eq "13q.11 33 characters (one long) is rejected" "invalid" \
            "$(sc_shape_check '0123456789abcdefghijklmnopqrstuvw')"
        assert_eq "13q.12 uppercase (wrong case) is rejected" "invalid" \
            "$(sc_shape_check "$(printf '%s' "$HASH_BEFORE_C" | tr '[:lower:]' '[:upper:]')")"
        assert_eq "13q.13 32 characters using w/x/y/z (outside the confirmed [0-9a-v] alphabet) is rejected" \
            "invalid" "$(sc_shape_check 'wxyz56789abcdefghijklmnopqrstuv')"

        # -----------------------------------------------------------------
        printf -- '\n--- 13r. claude-workflow-plugin-gytz R3-F1 (HIGH): a FAILED after-snapshot FAILS the spec, never silently reads as "no change" ---\n'
        # -----------------------------------------------------------------
        FX_VANISH_MUT="$WORK/store-canary-vanish-mut"
        FX_VANISH_SHIP="$WORK/store-canary-vanish-ship"
        mkdir -p "$FX_VANISH_MUT"
        ( cd "$FX_VANISH_MUT" && bd init --database beads --non-interactive >/dev/null 2>&1 )
        if [ ! -d "$FX_VANISH_MUT/.beads/embeddeddolt/beads/.dolt" ]; then
            printf '  SKIPPED: could not initialise a fixture Dolt store for the 13r sample-failure leg\n'
        else
            # Clone BEFORE either spec runs, same convention as
            # $FX_ROLLBACK_MUT/$FX_ROLLBACK_SHIP in 13f: the vanish spec
            # DESTROYS its own .dolt metadata dir, a ONE-SHOT mutation, so
            # the mutant run and the shipped-execution run each need their
            # OWN untouched copy. (Reusing a single fixture across both
            # run_l1 calls was tried first and silently broke the SECOND
            # call's ARM step: the .dolt dir the first call already renamed
            # away stays gone, so the second run starts already DISARMED
            # rather than exercising the per-spec failure path at all.)
            mkdir -p "$FX_VANISH_SHIP"
            cp -R "$FX_VANISH_MUT/.beads" "$FX_VANISH_SHIP/.beads"

            mk_l1_fixture "$FX_VANISH_MUT" "$((EXPECTED - 1))"
            cat > "$FX_VANISH_MUT/.claude/scripts/tests/zz-vanish.sh" <<'EOF'
#!/bin/bash
printf '  PASS: vanish spec ran\n'
# R3-F1 pairing: make the AFTER-snapshot query itself FAIL (not merely find
# nothing) by hiding the store's OWN .dolt metadata dir after this spec has
# started running -- the cd into .../beads still succeeds (the directory is
# still there), but `dolt sql -q "SELECT hashof('HEAD')"` inside it exits
# non-zero with EMPTY stdout (confirmed directly against this dolt build:
# "error on line 1 for query SELECT hashof('HEAD'): database not found" on
# stderr, nothing on stdout), which is exactly the shape the pre-fix
# per-spec read treated as "no change" instead of "the sample failed".
DOLT_DIR="$(dirname "$0")/../../../.beads/embeddeddolt/beads/.dolt"
mv "$DOLT_DIR" "$DOLT_DIR.hidden-by-13r"
exit 0
EOF
            chmod +x "$FX_VANISH_MUT/.claude/scripts/tests/zz-vanish.sh"

            mk_l1_fixture "$FX_VANISH_SHIP" "$((EXPECTED - 1))"
            cat > "$FX_VANISH_SHIP/.claude/scripts/tests/zz-vanish.sh" <<'EOF'
#!/bin/bash
printf '  PASS: vanish spec ran\n'
DOLT_DIR="$(dirname "$0")/../../../.beads/embeddeddolt/beads/.dolt"
mv "$DOLT_DIR" "$DOLT_DIR.hidden-by-13r"
exit 0
EOF
            chmod +x "$FX_VANISH_SHIP/.claude/scripts/tests/zz-vanish.sh"

            # 1. NON-VACUITY: a single targeted line-flip neutralises ONLY
            #    the new "treat an invalid/failed sample as adverse" check,
            #    leaving the rc-capture and shape-validation MACHINERY that
            #    feeds it untouched -- this leg exercises that branch
            #    specifically (13a/13b already cover whole-mechanism
            #    excision).
            MUT_SC_NOSAMPLEFAIL="$WORK/run-tests.no-samplefail-fix.sh"
            # shellcheck disable=SC2016  # single-quoted on purpose: matching
            # literal source text in $L1_RUNNER, not expanding a variable.
            sed 's/if \[ "\$STORE_VALID_SAMPLE" != "1" \]; then/if false; then/' \
                "$L1_RUNNER" > "$MUT_SC_NOSAMPLEFAIL"
            assert_eq "13r.1 MUTANT non-vacuity: the mutant differs from the shipped runner (the R3-F1 branch guard was excised)" \
                "differs" "$(cmp -s "$L1_RUNNER" "$MUT_SC_NOSAMPLEFAIL" && echo identical || echo differs)"
            assert_eq "13r.2 MUTANT: still parses (bash -n)" \
                "0" "$(bash -n "$MUT_SC_NOSAMPLEFAIL" 2>/dev/null; echo $?)"

            # 2. SPECIFIC MISBEHAVIOUR: under the mutant, the vanish spec
            #    (which genuinely breaks the AFTER read) is PASSED,
            #    unreported -- "a measurement that did not happen is
            #    indistinguishable from one that passed", reproduced.
            run_l1 "$FX_VANISH_MUT" "$MUT_SC_NOSAMPLEFAIL"
            assert_eq "13r.3 MUTANT: the runner exits 0 despite the broken AFTER read" "0" "$RUN_RC"
            assert_contains "13r.4 MUTANT: the vanish spec is classified PASSED" \
                "zz-vanish.sh: PASSED" "$RUN_OUT"
            assert_contains "13r.5 MUTANT: the summary says Failed: 0" \
                "Failed: 0" "$RUN_OUT"
            assert_eq "13r.6 MUTANT: no verdict line anywhere names a sample failure (the exact silent-pass R3-F1 describes)" \
                "0" "$(printf '%s' "$RUN_OUT" | grep -c 'AFTER-sample failed')"

            # 3. RESTORE CONTROL: the shipped runner, a HEALTHY store, an
            #    ordinary read -- unaffected by this fix. Reuses $FX_READONLY
            #    (13c): its own store is already proven healthy and unmoved
            #    by a plain read.
            run_l1 "$FX_READONLY"
            assert_eq "13r.7 RESTORE CONTROL: the shipped runner over a healthy store and an ordinary read is still green (rc=0)" \
                "0" "$RUN_RC"
            assert_absent "13r.8 ...with no AFTER-sample-failure line anywhere (a working sample is not a failed one)" \
                "AFTER-sample failed" "$RUN_OUT"

            # 4. EXECUTION (the discriminator): the SHIPPED runner, the SAME
            #    broken read (its own never-yet-touched fixture copy), fails
            #    the spec LOUDLY and NAMES the sample failure rather than
            #    fabricating a "no change" verdict.
            run_l1 "$FX_VANISH_SHIP"
            assert_eq "13r.9 EXECUTION: the shipped runner exits non-zero over the spec that broke its own AFTER read" "1" "$RUN_RC"
            assert_contains "13r.10 ...the failed-files entry NAMES the vanish spec" \
                "zz-vanish.sh" "$(printf '%s\n' "$RUN_OUT" | grep -A3 'Failed tests:')"
            assert_contains "13r.11 ...and the failure explicitly names an AFTER-sample failure" \
                "AFTER-sample failed" "$RUN_OUT"
            assert_contains "13r.12 ...naming the exit status it captured off the query rather than a masked pipe result" \
                "exited rc=1" "$RUN_OUT"
        fi

        # -----------------------------------------------------------------
        printf -- '\n--- 13s. claude-workflow-plugin-gytz R3-F2: the corrected contract is NET HEAD CHANGED, and the KNOWN LIMIT (advance-then-restore) is real, not just claimed ---\n'
        # -----------------------------------------------------------------
        # The corrected wording, driven LIVE rather than grepped from source
        # (the pairing README: prose is only provable through the executable
        # whose behaviour it describes). Reuses $FX_READONLY (already proven
        # healthy) for the ARMED line, and re-runs $FX_CANARY (13d's already
        # -contaminated fixture -- one more commit there is harmless, it is
        # disposable scratch under $WORK) for the dedicated arm's headline.
        run_l1 "$FX_READONLY"
        assert_contains "13s.1 the ARMED line states the corrected NET HEAD CHANGED contract" \
            "a spec whose window leaves HEAD net-changed fails, by name" "$RUN_OUT"
        assert_absent "13s.2 ...and no longer claims to catch ANY advance (the R3-F2 overclaim)" \
            "any advance during a spec fails that spec" "$RUN_OUT"

        run_l1 "$FX_CANARY"
        assert_contains "13s.3 the dedicated arm's headline states a net change, not an unqualified advance" \
            "net HEAD change" "$RUN_OUT"

        # THE LIMIT ITSELF, characterised, not merely commented: an EXACT
        # round trip inside ONE spec's window -- H0 -> write -> back to
        # EXACTLY H0 -- nets to no change and is invisible by construction,
        # in contrast to 13f's non-descendant move (a DIFFERENT ancestor),
        # which IS caught. Same mechanics as 13f's own precondition checks,
        # confirmed against the real dolt CLI before any runner is involved.
        FX_ROUNDTRIP="$WORK/store-canary-roundtrip"
        mkdir -p "$FX_ROUNDTRIP"
        ( cd "$FX_ROUNDTRIP" && bd init --database beads --non-interactive >/dev/null 2>&1 )
        if [ ! -d "$FX_ROUNDTRIP/.beads/embeddeddolt/beads/.dolt" ]; then
            printf '  SKIPPED: could not initialise a fixture Dolt store for the 13s KNOWN-LIMIT leg\n'
        else
            RT_START=$(sc_hash "$FX_ROUNDTRIP")
            mk_l1_fixture "$FX_ROUNDTRIP" "$((EXPECTED - 1))"
            cat > "$FX_ROUNDTRIP/.claude/scripts/tests/zz-roundtrip.sh" <<EOF
#!/bin/bash
printf '  PASS: roundtrip spec ran\n'
cd "\$(dirname "\$0")/../../.." && bd create "13s seed" -t task -p 4 >/dev/null 2>&1
cd "\$(dirname "\$0")/../../../.beads/embeddeddolt/beads" && dolt reset --hard $RT_START >/dev/null 2>&1
exit 0
EOF
            chmod +x "$FX_ROUNDTRIP/.claude/scripts/tests/zz-roundtrip.sh"

            run_l1 "$FX_ROUNDTRIP"
            RT_END=$(sc_hash "$FX_ROUNDTRIP")
            assert_eq "13s.4 precondition: the fixture's OWN HEAD is exactly back where it started (a genuine round trip, not a near-miss)" \
                "$RT_START" "$RT_END"
            assert_eq "13s.5 KNOWN LIMIT, characterised: the SHIPPED runner exits 0 over an exact advance-then-restore inside one spec's window" \
                "0" "$RUN_RC"
            assert_contains "13s.6 ...the roundtrip spec is classified PASSED (net change is zero, exactly as the corrected NET HEAD CHANGED contract predicts)" \
                "zz-roundtrip.sh: PASSED" "$RUN_OUT"
            assert_absent "13s.7 ...and no verdict line mentions the protected store (contrast 13f.10, where a DIFFERENT-ancestor move IS caught)" \
                "protected Beads store" "$RUN_OUT"
        fi

        # -----------------------------------------------------------------
        printf -- '\n--- 13t. claude-workflow-plugin-gytz R3-F3 + R3-F4: the window is described honestly, and a sentinel is never reported as a counted commit ---\n'
        # -----------------------------------------------------------------
        # R3-F3: re-run 13d's own contaminating spec and check the corrected
        # wording -- "since the last confirmed sample", never "while it ran"
        # (which claimed a precision this sampling scheme does not have:
        # BEFORE is the PREVIOUS spec's own after-sample, so the window can
        # include a brief inter-spec bookkeeping gap this spec never ran).
        run_l1 "$FX_CANARY"
        assert_eq "13t.1 EXECUTION: still catches the contaminator (no regression from the R3-F3 wording change)" "1" "$RUN_RC"
        assert_contains "13t.2 R3-F3: the failure text says 'since the last confirmed sample'" \
            "since the last confirmed sample" "$RUN_OUT"
        assert_absent "13t.3 R3-F3: ...and no longer claims the tighter 'while it ran' precision" \
            "while it ran" "$RUN_OUT"
        assert_absent "13t.3b ...(the other pre-fix phrasing, 'while this spec ran')" \
            "while this spec ran" "$RUN_OUT"

        # R3-F4: a FRESH non-descendant-move fixture -- NOT a re-run of 13f's
        # own $FX_ROLLBACK_SHIP. That fixture's zz-rollback.sh already spent
        # its ONE-SHOT `dolt reset --hard $RB_ANCESTOR` at 13f.10; running
        # the SAME fixture through run_l1 a second time starts with HEAD
        # already sitting at $RB_ANCESTOR (the first run's own end state), so
        # the second reset is a no-op -- nothing moves, nothing to name, and
        # the assertions below would fail for a reason that has nothing to
        # do with the R3-F4 wording under test (caught by this leg's own
        # first run: rc=0, no NON-LINEAR anywhere, when it should have been
        # 1/present). Independently reproduces 13f's own construction, once,
        # purely to inspect the wording this round changed.
        FX_ROLLBACK_SHIP2="$WORK/store-canary-rollback-ship2"
        mkdir -p "$FX_ROLLBACK_SHIP2"
        ( cd "$FX_ROLLBACK_SHIP2" && bd init --database beads --non-interactive >/dev/null 2>&1 )
        if [ ! -d "$FX_ROLLBACK_SHIP2/.beads/embeddeddolt/beads/.dolt" ]; then
            printf '  SKIPPED: could not initialise a fixture Dolt store for the 13t R3-F4 wording leg\n'
        else
            RS2_ANCESTOR=$(sc_hash "$FX_ROLLBACK_SHIP2")
            ( cd "$FX_ROLLBACK_SHIP2" && bd create "13t seed" -t task -p 4 >/dev/null 2>&1 )
            mk_l1_fixture "$FX_ROLLBACK_SHIP2" "$((EXPECTED - 1))"
            cat > "$FX_ROLLBACK_SHIP2/.claude/scripts/tests/zz-rollback2.sh" <<EOF
#!/bin/bash
printf '  PASS: rollback2 spec ran\n'
cd "\$(dirname "\$0")/../../../.beads/embeddeddolt/beads" && dolt reset --hard $RS2_ANCESTOR >/dev/null 2>&1
exit 0
EOF
            chmod +x "$FX_ROLLBACK_SHIP2/.claude/scripts/tests/zz-rollback2.sh"

            run_l1 "$FX_ROLLBACK_SHIP2"
            assert_eq "13t.4 EXECUTION: still catches the non-descendant move (no regression from the R3-F4 wording change)" "1" "$RUN_RC"
            assert_contains "13t.5 R3-F4: the NON-LINEAR case is still named" "NON-LINEAR" "$RUN_OUT"
            assert_eq "13t.6 R3-F4: the sentinel is never reported as a counted commit ('1 commit(s)' does not appear anywhere)" \
                "0" "$(printf '%s' "$RUN_OUT" | grep -c '1 commit(s)')"
            assert_eq "13t.7 R3-F4: ...nor any other fabricated count alongside NON-LINEAR" \
                "0" "$(printf '%s\n' "$RUN_OUT" | grep -c 'NON-LINEAR.*commit(s)\|commit(s).*NON-LINEAR')"
        fi

        # R3-F4, the comment fix: "LOUD AND COUNTED" no longer appears
        # (nothing here counts a disarm event; it only prints, twice). This
        # one check is DECLARED UNPAIRED rather than dressed up as an
        # execution leg (.claude/tests/README.md, "The pairing
        # requirement"): the artifact is a comment's own accuracy about
        # itself, there is no runtime behaviour for it to diverge from, and
        # a check that read this paragraph and asserted its wording would be
        # exactly the false pair that convention warns about. The control
        # is a human rereading the comment at review time; this line only
        # catches the wording regressing back to the disproven claim.
        assert_eq "13t.8 R3-F4 comment fix (UNPAIRED, source-level): the shipped source no longer claims disarming is COUNTED" \
            "0" "$(grep -c 'LOUD AND COUNTED' "$L1_RUNNER")"

        # -----------------------------------------------------------------
        printf -- '\n--- 13u. claude-workflow-plugin-gytz R4-F1 (MEDIUM): a spec that BOTH moves the canary AND fails its own transcript is reported for BOTH reasons ---\n'
        # -----------------------------------------------------------------
        # Pre-fix, the two STORE-CANARY verdict arms sat ahead of
        # TRANSCRIPT-FAIL in one if/elif chain, so a spec red for a canary
        # reason AND its own FAIL: line(s) was reported for the canary
        # reason ONLY -- TRANSCRIPT-FAIL was never even reached for it.
        FX_CANARY_FAIL="$WORK/store-canary-and-transcript-fail"
        mkdir -p "$FX_CANARY_FAIL"
        ( cd "$FX_CANARY_FAIL" && bd init --database beads --non-interactive >/dev/null 2>&1 )
        if [ ! -d "$FX_CANARY_FAIL/.beads/embeddeddolt/beads/.dolt" ]; then
            printf '  SKIPPED: could not initialise a fixture Dolt store for the 13u canary+transcript leg\n'
        else
            mk_l1_fixture "$FX_CANARY_FAIL" "$((EXPECTED - 1))"
            cat > "$FX_CANARY_FAIL/.claude/scripts/tests/zz-contaminator-fail.sh" <<'EOF'
#!/bin/bash
printf '  PASS: contaminator-fail ran\n'
printf '  FAIL: this assertion was designed to fail\n'
cd "$(dirname "$0")/../../.." && bd create "13u seed" -t task -p 4 >/dev/null 2>&1
exit 0
EOF
            chmod +x "$FX_CANARY_FAIL/.claude/scripts/tests/zz-contaminator-fail.sh"

            # 1. NON-VACUITY: the merge fix has its own dedicated sentinel
            #    pair (STORE-CANARY-TRANSCRIPT-MERGE-BEGIN/END), present once
            #    inside EACH of the two STORE-CANARY verdict arms -- one awk
            #    pass excises both, same technique as 13a's whole-mechanism
            #    excision but scoped to only the new merge lines: detection
            #    itself (13a/13b) is untouched by this mutant.
            MUT_MERGE="$WORK/run-tests.no-transcript-merge.sh"
            awk '
                /STORE-CANARY-TRANSCRIPT-MERGE-BEGIN/ { skipping=1; found++; next }
                /STORE-CANARY-TRANSCRIPT-MERGE-END/   { skipping=0; next }
                !skipping { print }
                END { if (found != 2) exit 9 }
            ' "$L1_RUNNER" > "$MUT_MERGE"
            AWK_MERGE_RC=$?
            assert_eq "13u.1 MUTANT non-vacuity: both merge-fix occurrences were FOUND and excised (awk found-check)" \
                "0" "$AWK_MERGE_RC"
            assert_eq "13u.2 MUTANT: the mutant differs from the shipped runner (the excision landed)" \
                "differs" "$(cmp -s "$L1_RUNNER" "$MUT_MERGE" && echo identical || echo differs)"
            assert_eq "13u.3 MUTANT: the mutant still parses (bash -n)" \
                "0" "$(bash -n "$MUT_MERGE" 2>/dev/null; echo $?)"

            # 2. SPECIFIC MISBEHAVIOUR: under the mutant, the dual-reason spec
            #    is reported for the canary reason ONLY. The spec's own raw
            #    transcript is still echoed further up in the log (that is a
            #    DIFFERENT, unrelated code path -- `cat "$SPEC_OUT"` runs
            #    regardless of classification) so this checks the FAILED-
            #    TESTS SUMMARY entry specifically, the one place the merge
            #    fix actually changes, rather than the log as a whole.
            run_l1 "$FX_CANARY_FAIL" "$MUT_MERGE"
            assert_eq "13u.4 MUTANT: the runner still catches it (rc=1 -- the canary reason alone still reddens the tier)" \
                "1" "$RUN_RC"
            MUT_FT_BLOCK=$(printf '%s\n' "$RUN_OUT" | grep -A3 'Failed tests:')
            assert_contains "13u.5 MUTANT: the failed-tests entry carries the canary reason" \
                "the protected Beads store" "$MUT_FT_BLOCK"
            assert_absent "13u.6 MUTANT: ...but never says the transcript ALSO failed" \
                "ALSO holds" "$MUT_FT_BLOCK"
            assert_absent "13u.7 MUTANT: ...and never quotes the FAIL: line in that SAME entry (only in the raw transcript echo above it)" \
                "this assertion was designed to fail" "$MUT_FT_BLOCK"

            # 3. RESTORE CONTROL: the fix does not fabricate a transcript
            #    reason where none exists -- $FX_CANARY's own contaminator
            #    (13d) has no FAIL: line, so its entry must carry no "ALSO
            #    holds" fragment either.
            run_l1 "$FX_CANARY"
            assert_absent "13u.8 RESTORE CONTROL: a canary-only spec (no transcript FAIL:) gets no 'ALSO holds' fragment" \
                "ALSO holds" "$RUN_OUT"

            # 4. EXECUTION (the discriminator): the SHIPPED runner, the SAME
            #    dual-reason spec the mutant saw at 13u.4-13u.7, reports BOTH
            #    reasons in the SAME failed-tests entry.
            run_l1 "$FX_CANARY_FAIL"
            assert_eq "13u.9 EXECUTION: the shipped runner catches it (rc=1)" "1" "$RUN_RC"
            FT_BLOCK=$(printf '%s\n' "$RUN_OUT" | grep -A3 'Failed tests:')
            assert_contains "13u.10 EXECUTION: the failed-tests entry names the spec" \
                "zz-contaminator-fail.sh" "$FT_BLOCK"
            assert_contains "13u.11 EXECUTION: ...carries the canary reason" \
                "the protected Beads store" "$FT_BLOCK"
            assert_contains "13u.12 EXECUTION: ...AND carries the transcript reason, named" \
                "ALSO holds 1 FAIL: line(s)" "$FT_BLOCK"
            assert_contains "13u.13 EXECUTION: ...quoting the FAIL: line itself in that SAME entry, not just a count" \
                "this assertion was designed to fail" "$FT_BLOCK"
        fi

        # -----------------------------------------------------------------
        printf -- '\n--- 13v. claude-workflow-plugin-gytz R4-F2 (LOW): an UNREADABLE commit count is never reported as a fabricated "advanced by 1 commit(s)" ---\n'
        # -----------------------------------------------------------------
        # The empty/non-numeric case-guard sentinel (case "$STORE_WRITES" in
        # ''|*[!0-9]*) used to be indistinguishable, downstream, from a
        # genuine single-commit count -- only the literal "0" was routed to
        # the NON-LINEAR (non-authoritative-count) wording. Reachable when
        # the `cd` into the store directory fails between the successful
        # AFTER-hashof read and the STORE_WRITES `dolt log` read -- proven
        # here by making `wc -l` itself fail on its FIRST invocation (the
        # only `wc -l` call the shipped runner makes anywhere -- confirmed:
        # `grep -c 'wc -l' run-tests.sh` = 1), which empties the command
        # substitution the exact same way a failed `cd` would, without
        # needing to race a real filesystem disappearance.
        FX_LOGBREAK="$WORK/store-canary-logbreak"
        mkdir -p "$FX_LOGBREAK" "$FX_LOGBREAK/bin"
        ( cd "$FX_LOGBREAK" && bd init --database beads --non-interactive >/dev/null 2>&1 )
        if [ ! -d "$FX_LOGBREAK/.beads/embeddeddolt/beads/.dolt" ]; then
            printf '  SKIPPED: could not initialise a fixture Dolt store for the 13v unreadable-count leg\n'
        else
            REAL_WC=$(command -v wc)
            # A `wc` stub that fails ONLY the first `-l` call, then defers to
            # the real binary for anything else -- self-limiting via its own
            # marker file, so a bug elsewhere cannot make it fire twice.
            cat > "$FX_LOGBREAK/bin/wc" <<EOF
#!/bin/bash
if [ "\$1" = "-l" ] && [ ! -e "$FX_LOGBREAK/.wc-fired" ]; then
    : > "$FX_LOGBREAK/.wc-fired"
    cat >/dev/null
    exit 1
fi
exec "$REAL_WC" "\$@"
EOF
            chmod +x "$FX_LOGBREAK/bin/wc"

            mk_l1_fixture "$FX_LOGBREAK" "$((EXPECTED - 1))"
            cat > "$FX_LOGBREAK/.claude/scripts/tests/zz-logbreak.sh" <<'EOF'
#!/bin/bash
printf '  PASS: logbreak spec ran\n'
cd "$(dirname "$0")/../../.." && bd create "13v seed" -t task -p 4 >/dev/null 2>&1
exit 0
EOF
            chmod +x "$FX_LOGBREAK/.claude/scripts/tests/zz-logbreak.sh"

            # 1. NON-VACUITY: a single targeted line-flip neutralises ONLY
            #    the new STORE_WRITES_UNREADABLE routing, leaving the flag's
            #    own computation (the case-guard) untouched -- this leg
            #    exercises that routing specifically.
            MUT_LOGBREAK="$WORK/run-tests.no-unreadable-fix.sh"
            # shellcheck disable=SC2016  # single-quoted on purpose: matching
            # literal source text in $L1_RUNNER, not expanding a variable.
            sed 's/if \[ "\$STORE_WRITES" = "0" \] || \[ "\$STORE_WRITES_UNREADABLE" = "1" \]; then/if [ "$STORE_WRITES" = "0" ]; then/' \
                "$L1_RUNNER" > "$MUT_LOGBREAK"
            assert_eq "13v.1 MUTANT non-vacuity: the mutant differs from the shipped runner (the R4-F2 routing was excised)" \
                "differs" "$(cmp -s "$L1_RUNNER" "$MUT_LOGBREAK" && echo identical || echo differs)"
            assert_eq "13v.2 MUTANT: still parses (bash -n)" \
                "0" "$(bash -n "$MUT_LOGBREAK" 2>/dev/null; echo $?)"

            # 2. SPECIFIC MISBEHAVIOUR: under the mutant, an unreadable count
            #    is reported as a fabricated "advanced by 1 commit(s)".
            PATH="$FX_LOGBREAK/bin:$PATH" run_l1 "$FX_LOGBREAK" "$MUT_LOGBREAK"
            assert_eq "13v.3 precondition: wc -l really was intercepted exactly once (the fixture's own marker exists)" \
                "1" "$([ -e "$FX_LOGBREAK/.wc-fired" ] && echo 1 || echo 0)"
            assert_eq "13v.4 MUTANT: the runner still catches the move (rc=1 -- this is not a silent pass)" \
                "1" "$RUN_RC"
            assert_contains "13v.5 MUTANT: but fabricates a ONE-commit count for a read that never happened" \
                "advanced by 1 commit(s)" "$RUN_OUT"

            rm -f "$FX_LOGBREAK/.wc-fired"

            # 3. RESTORE CONTROL: the shipped fix, a GENUINE real count (no
            #    interception at all -- $FX_CANARY's own contaminator, one
            #    real commit) still says "advanced by 1 commit(s)" -- an
            #    actual count of one is not turned into something else by
            #    this fix.
            run_l1 "$FX_CANARY"
            assert_contains "13v.6 RESTORE CONTROL: a GENUINE single-commit advance is still reported as one commit" \
                "advanced by 1 commit(s)" "$RUN_OUT"

            # 4. EXECUTION (the discriminator): the SHIPPED runner, the SAME
            #    interception, never claims a fabricated count.
            PATH="$FX_LOGBREAK/bin:$PATH" run_l1 "$FX_LOGBREAK"
            assert_eq "13v.7 precondition: wc -l was intercepted exactly once again on this run" \
                "1" "$([ -e "$FX_LOGBREAK/.wc-fired" ] && echo 1 || echo 0)"
            assert_eq "13v.8 EXECUTION: the shipped runner still catches the move (rc=1)" "1" "$RUN_RC"
            assert_absent "13v.9 EXECUTION: ...without fabricating a commit count for a read that never happened" \
                "advanced by 1 commit(s)" "$RUN_OUT"
            assert_contains "13v.10 EXECUTION: ...naming the count as UNREADABLE instead" \
                "UNREADABLE" "$RUN_OUT"
        fi

        # -----------------------------------------------------------------
        printf -- '\n--- 13w. claude-workflow-plugin-gytz R4-F4 (LOW): dolt_hash_looks_valid is locale-proof -- an explicit character class, never a bracket RANGE ---\n'
        # -----------------------------------------------------------------
        # A bracket RANGE ([0-9a-v]) collates per LC_COLLATE; an EXPLICIT
        # enumeration does not. Rather than assert that in the abstract,
        # this finds a locale ACTUALLY INSTALLED on this host under which
        # bash 3.2's own `case` really does misclassify an uppercase letter
        # as inside [a-v] (a plain claim about glibc/ICU collation would be
        # exactly the un-evidenced kind of number this repo's own convention
        # refuses), and SKIPS itself honestly if none is found rather than
        # asserting anything on a host where the exposure cannot be shown.
        SC_LOCALE_HIT=""
        for _sc_loc in en_US.UTF-8 en_US.utf8 en_GB.UTF-8 en_GB.utf8 de_DE.UTF-8 de_DE.utf8; do
            if [ "$(LC_ALL="$_sc_loc" LC_COLLATE="$_sc_loc" bash -c 'case "A" in [a-v]) echo MATCH ;; *) echo no ;; esac' 2>/dev/null)" = "MATCH" ]; then
                SC_LOCALE_HIT="$_sc_loc"
                break
            fi
        done
        if [ -z "$SC_LOCALE_HIT" ]; then
            printf '  SKIPPED: no locale installed on this host demonstrates the [a-v] collation exposure (tried en_US/en_GB/de_DE in both UTF-8 spellings) -- not a fix regression, just an environment gap; 13q'"'"'s C-locale coverage of dolt_hash_looks_valid is unaffected\n'
        else
            printf "  precondition: LC_COLLATE=%s makes bash 3.2 on this host match case 'A' in [a-v])\n" "$SC_LOCALE_HIT"

            # 1. NON-VACUITY: revert JUST the explicit class back to the
            #    pre-fix range, everywhere it appears (the 32-times-repeated
            #    class on dolt_hash_looks_valid's one `case` line) -- same
            #    "restore the historical shape" technique section 14 uses.
            MUT_RANGE="$WORK/run-tests.range-not-explicit.sh"
            sed 's/\[0123456789abcdefghijklmnopqrstuv\]/[0-9a-v]/g' "$L1_RUNNER" > "$MUT_RANGE"
            assert_eq "13w.1 MUTANT non-vacuity: the mutant differs from the shipped runner (the explicit class was reverted to a range)" \
                "differs" "$(cmp -s "$L1_RUNNER" "$MUT_RANGE" && echo identical || echo differs)"
            assert_eq "13w.2 MUTANT: still parses (bash -n)" \
                "0" "$(bash -n "$MUT_RANGE" 2>/dev/null; echo $?)"

            SC_SHAPE_LIB_MUT="$WORK/dolt-hash-shape-mutant.sh"
            awk '/^dolt_hash_looks_valid\(\) \{/,/^\}/' "$MUT_RANGE" > "$SC_SHAPE_LIB_MUT"
            assert_eq "13w.3 MUTANT: the reverted extraction still parses on its own" \
                "0" "$(bash -n "$SC_SHAPE_LIB_MUT" 2>/dev/null; echo $?)"
            assert_eq "13w.4 MUTANT: the extracted function body differs from the shipped one (the revert reached the function under test, not just a comment)" \
                "differs" "$(cmp -s "$SC_SHAPE_LIB" "$SC_SHAPE_LIB_MUT" && echo identical || echo differs)"

            sc_shape_check_locale() {
                # sc_shape_check_locale <lib> <locale> <value> -> valid/invalid
                LC_ALL="$2" LC_COLLATE="$2" bash -c \
                    '. "$1"; dolt_hash_looks_valid "$2" && echo valid || echo invalid' \
                    -- "$1" "$3"
            }

            # An adversarial 32-character string: real dolt-hash SHAPE and
            # LENGTH, but ten of its characters are uppercase A-J -- every
            # one of which this host's own $SC_LOCALE_HIT collates as
            # falling inside [a-v] (empirically confirmed above: bd/dolt
            # itself never emits uppercase in a hash, so this string could
            # only reach here as a corrupted or attacker-influenced read).
            ADV_HASH="0123456789ABCDEFGHIJklmnopqrstuv"
            assert_eq "13w.5 precondition: the adversarial string really is 32 characters (the real-hash SHAPE this function gates on)" \
                "32" "${#ADV_HASH}"

            # 2. SPECIFIC MISBEHAVIOUR: under the mutant AND the confirmed
            #    locale, the adversarial uppercase-mixed string is WRONGLY
            #    accepted as looking like a valid dolt hash.
            assert_eq "13w.6 MUTANT: under $SC_LOCALE_HIT, the range-based mutant WRONGLY accepts the uppercase-mixed string" \
                "valid" "$(sc_shape_check_locale "$SC_SHAPE_LIB_MUT" "$SC_LOCALE_HIT" "$ADV_HASH")"

            # 3. RESTORE CONTROL: the SAME locale does not break the SHIPPED
            #    fix's acceptance of a genuine, real-shaped all-lowercase
            #    hash -- the fix is locale-proof in BOTH directions, not
            #    merely stricter.
            REAL_HASH="0123456789abcdefghijklmnopqrstuv"
            assert_eq "13w.7 RESTORE CONTROL: under the SAME locale, the SHIPPED fix still accepts a genuine real-shaped hash" \
                "valid" "$(sc_shape_check_locale "$SC_SHAPE_LIB" "$SC_LOCALE_HIT" "$REAL_HASH")"

            # 4. EXECUTION (the discriminator): the SHIPPED fix, the SAME
            #    locale, the SAME adversarial string the mutant accepted at
            #    13w.6 -- correctly rejected.
            assert_eq "13w.8 EXECUTION: under the SAME locale, the SHIPPED fix correctly REJECTS the uppercase-mixed string the mutant accepted" \
                "invalid" "$(sc_shape_check_locale "$SC_SHAPE_LIB" "$SC_LOCALE_HIT" "$ADV_HASH")"
        fi

        # -----------------------------------------------------------------
        printf -- '\n--- 13x. claude-workflow-plugin-gytz R4-F3 (LOW): the store-canary messages say what is known, never who caused it ---\n'
        # -----------------------------------------------------------------
        # R4-F3 is comment/message-only (independent review round 4): no
        # detection logic changed, so the two OUTPUT-text corrections below
        # are checked live against $RUN_OUT (the pairing README's stronger
        # form -- prose proven through the executable it describes), and the
        # two SOURCE-COMMENT corrections are checked the same UNPAIRED,
        # source-level way 13t.8 already establishes for this file: a human
        # rereading the comment is the control, this line only catches a
        # regression back to the disproven wording.
        run_l1 "$FX_CANARY"
        R4F3_FT_BLOCK=$(printf '%s\n' "$RUN_OUT" | grep -A3 'Failed tests:')
        assert_absent "13x.1 EXECUTION: the failed-tests entry no longer names the spec as having 'contaminated' the store" \
            "contaminated the protected Beads store" "$R4F3_FT_BLOCK"
        assert_contains "13x.2 EXECUTION: ...and instead says only what the two samples establish" \
            "moved, cause not established" "$R4F3_FT_BLOCK"
        assert_contains "13x.3 EXECUTION: ...while still stating the NET HEAD CHANGED contract (the R3-F2 wording is undisturbed)" \
            "net HEAD change" "$RUN_OUT"
        assert_eq "13x.4 SOURCE, UNPAIRED: 'contaminated the protected Beads store' no longer appears anywhere in the shipped source" \
            "0" "$(grep -c 'contaminated the protected Beads store' "$L1_RUNNER")"
        # The needle is split across two variables, and BOTH of the next two
        # legs use the split form (even the one grepping run-tests.sh) -- so
        # that 13x.6's self-scan of THIS file can never satisfy its own grep
        # by finding 13x.5's literal pattern text sitting a few lines above
        # it. Caught empirically: 13x.6 self-matched via exactly that route
        # before this split (grep -c returned 1, from 13x.5's own quoted
        # argument, not from any surviving overclaim). $0 is avoided for the
        # same self-reference reason PLUGIN_DIR exists for at the top of
        # this file -- a self-reference that survives any cwd change.
        R4F3_NEEDLE_A="fails ANY spec whose environment"
        R4F3_NEEDLE_B=" resolves"
        assert_eq "13x.5 SOURCE, UNPAIRED: the shipped source no longer claims detection fires on mere environment resolution (run-tests.sh)" \
            "0" "$(grep -c -- "${R4F3_NEEDLE_A}${R4F3_NEEDLE_B}" "$L1_RUNNER")"
        assert_eq "13x.6 SOURCE, UNPAIRED: ...nor does this spec's own header comment (the identical overclaim lived here too)" \
            "0" "$(grep -c -- "${R4F3_NEEDLE_A}${R4F3_NEEDLE_B}" "$PLUGIN_DIR/.claude/scripts/tests/runner-completeness.test.sh")"
        assert_eq "13x.7 SOURCE, UNPAIRED: the shipped source no longer claims a backgrounded write 'still counts' unconditionally" \
            "0" "$(grep -c 'a write from that backgrounded process still counts' "$L1_RUNNER")"

        # --- STORE-CANARY ATTRIBUTION TEST SECTIONS 13g-13p, 13j, 13k: -----
        # --- REMOVED (claude-workflow-plugin-gytz waiver ruling; recorded --
        # --- as a test-vacuity census instance, claude-workflow-plugin-tumg)
        # These sections exercised attribute_store_advance()'s self-vs-
        # external ATTRIBUTION decision (the STORE-CANARY-ATTRIBUTION
        # sentinel, DEPADD-PRECURSOR-SKIP, ACTOR-ISSUE-EXTRACT, and the
        # verify_actor_marker_took_effect self-check), all deleted from
        # run-tests.sh. Detection (13a-13f above; unaffected) needs no actor
        # at all — the operations a real spec's own writes perform
        # (comment/update/close/label) carry no actor on bd 1.3.0 at all,
        # measured 14+ trials (claude-workflow-plugin-u443), so this
        # mechanism could not fire in its own motivating case either; the
        # ~500 lines here were green only because the fixtures below
        # manufactured the one operation (`bd dep add`) that could reach it.
        # Replacement: SPEC ISOLATION (claude-workflow-plugin-h5lw).

        # SELF-PROTECTION PROPERTY: every fixture built above lives under
        # $WORK ($FX_CANARY, $FX_READONLY, $FX_NODOLT, $FX_ROLLBACK_MUT,
        # $FX_ROLLBACK_SHIP, $FX_ROLLBACK_SHIP2, $FX_VANISH_MUT,
        # $FX_VANISH_SHIP, $FX_ROUNDTRIP — all mktemp'd), never under the
        # real .beads/. If any leg above had
        # leaked to production, the OUTER canary — armed around THIS spec's
        # own run inside the tier that invoked it — would fail this file by
        # name the next time `make test` runs. The guard guards its own
        # control.
    fi
fi

# ===========================================================================
printf -- '\n--- 14. run.sh (L2) REFUSES stray positional/malformed args instead of silently running the FULL tier (claude-workflow-plugin-icn4 item 3, R1-F1) ---\n'
# ===========================================================================
# Pair for the ARG-PARSING region .claude/tests/component/run.sh grew for
# icn4 item 3. QA lost two full 45-spec tier runs to exactly this: a bare
# positional spec name, or `--filter` with no pattern, used to leave
# FILTER="" and fall through to a full, unfiltered run — each invocation
# silently contending with the other and with its own bd writes for an hour
# where a targeted 7-second run was intended. Review round 1 (R1-F1) found
# this shipped with neither a pairing nor an UNPAIRED declaration; this is
# the pairing, in the natural home the review itself pointed at. The four
# legs:
#   1 NON-VACUITY   the ARG-PARSING sentinel is found exactly once and
#                   REPLACED with the historical one-liner guard (quoted
#                   verbatim in run.sh's own header comment) — proven found,
#                   proven to differ from the shipped bytes, proven to still
#                   parse, and proven to CONTAIN the old shape while the new
#                   refusal messages are gone (not merely "differs" for some
#                   unrelated reason).
#   2 MISBEHAVIOUR  the mutant, given a bare positional OR a pattern-less
#                   --filter, silently runs the FULL fixture set (exit 0,
#                   every spec executed) — the exact contention QA hit.
#   3 RESTORE       the shipped run.sh, same two invocations, same fixture:
#                   exit 2, naming the bad argument, NOTHING executed; and,
#                   full circle, a VALID invocation against the same fixture
#                   still runs clean (the refusal is not a blanket
#                   regression against legitimate calls).
#   4 EXECUTION     leg 3 drives run.sh itself — real path, real bytes.
FX_ARGS="$WORK/l2-argparse"
mk_l2_fixture "$FX_ARGS"
cat > "$FX_ARGS/.claude/tests/component/specs/l2-argtest-a.sh" <<'EOF'
assert_eq "l2-argtest-a ran" "x" "x"
EOF
cat > "$FX_ARGS/.claude/tests/component/specs/l2-argtest-b.sh" <<'EOF'
assert_eq "l2-argtest-b ran" "x" "x"
EOF
cat > "$FX_ARGS/.claude/tests/component/specs/l2-argtest-c.sh" <<'EOF'
assert_eq "l2-argtest-c ran" "x" "x"
EOF

# -----------------------------------------------------------------
printf -- '\n--- 14a. NON-VACUITY: the ARG-PARSING region is found exactly once and replaced with the historical swallow shape ---\n'
# -----------------------------------------------------------------
assert_eq "14a.1 the ARG-PARSING sentinel pair is present exactly once in the shipped runner" \
    "1 1" "$(grep -c 'ARG-PARSING-BEGIN' "$L2_RUNNER") $(grep -c 'ARG-PARSING-END' "$L2_RUNNER")"

MUT_ARGS="$WORK/run.old-arg-swallow.sh"
awk '
/ARG-PARSING-BEGIN/ {
    found = 1
    skip = 1
    print "FILTER=\"\""
    print "if [ \"${1:-}\" = \"--filter\" ] && [ -n \"${2:-}\" ]; then"
    print "    FILTER=\"$2\""
    print "fi"
    next
}
/ARG-PARSING-END/ { skip = 0; next }
!skip { print }
END { if (!found) exit 7 }
' "$L2_RUNNER" > "$MUT_ARGS"
AWK_ARGS_RC=$?
assert_eq "14a.2 MUTANT: the ARG-PARSING region was FOUND and replaced (awk found-check)" "0" "$AWK_ARGS_RC"
assert_eq "14a.3 MUTANT: the mutant differs from the shipped runner (the replacement landed)" \
    "differs" "$(cmp -s "$L2_RUNNER" "$MUT_ARGS" && echo identical || echo differs)"
assert_eq "14a.4 MUTANT: the mutant still parses (bash -n)" \
    "0" "$(bash -n "$MUT_ARGS" 2>/dev/null; echo $?)"
# Prove the hit landed WHERE aimed, not merely "differs": the mutant carries
# the historical guard text verbatim, and the new refusal messages are gone.
# shellcheck disable=SC2016  # single-quoted on purpose: matching literal
# source text in $MUT_ARGS, not expanding a variable.
assert_eq "14a.5 MUTANT: carries the OLD one-liner guard verbatim (byte-for-byte, incl. 'if'/'then')" \
    "1" "$(grep -cF 'if [ "${1:-}" = "--filter" ] && [ -n "${2:-}" ]; then' "$MUT_ARGS")"
assert_eq "14a.6 MUTANT: none of the new refusal messages remain (the swallow, not a rewording, is under test)" \
    "0" "$(grep -cE 'unknown argument:|requires a <pattern> argument|unexpected extra argument' "$MUT_ARGS")"

# -----------------------------------------------------------------
printf -- '\n--- 14b. SPECIFIC MISBEHAVIOUR: the mutant silently runs the FULL fixture set over both swallow shapes QA hit ---\n'
# -----------------------------------------------------------------
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_ARGS" bash "$MUT_ARGS" reviewer-lane-degradation 2>&1)
RUN_RC=$?
assert_eq "14b.1 SPECIFIC: a bare positional (a spec name, not --filter) exits 0 under the mutant — the swallow" "0" "$RUN_RC"
assert_contains "14b.2 ...over the FULL fixture set, not a filtered one (all 3 specs, not a subset)" \
    "Specs:      Total: 3  Passed: 3  Failed: 0" "$RUN_OUT"

RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_ARGS" bash "$MUT_ARGS" --filter 2>&1)
RUN_RC=$?
assert_eq "14b.3 SPECIFIC: --filter with NO pattern also exits 0 under the mutant — the other swallow shape" "0" "$RUN_RC"
assert_contains "14b.4 ...also silently over the FULL fixture set" \
    "Specs:      Total: 3  Passed: 3  Failed: 0" "$RUN_OUT"

# -----------------------------------------------------------------
printf -- '\n--- 14c. RESTORE CONTROL + EXECUTION (leg 4, shared): the SHIPPED run.sh refuses both shapes before any spec executes ---\n'
# -----------------------------------------------------------------
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_ARGS" bash "$L2_RUNNER" reviewer-lane-degradation 2>&1)
RUN_RC=$?
assert_eq "14c.1 EXECUTION: the shipped runner refuses the SAME bare positional the mutant swallowed at 14b.1 (rc=2)" "2" "$RUN_RC"
assert_contains "14c.2 ...naming the offending argument" "unknown argument: reviewer-lane-degradation" "$RUN_OUT"
assert_eq "14c.3 ...and NOTHING executed (no spec banner anywhere in the output)" \
    "0" "$(printf '%s' "$RUN_OUT" | grep -cE '^=== l2-argtest-')"

RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_ARGS" bash "$L2_RUNNER" --filter 2>&1)
RUN_RC=$?
assert_eq "14c.4 EXECUTION: the shipped runner refuses --filter with no pattern (rc=2)" "2" "$RUN_RC"
assert_contains "14c.5 ...naming what's missing" "--filter requires a <pattern> argument" "$RUN_OUT"
assert_eq "14c.6 ...and NOTHING executed here either" \
    "0" "$(printf '%s' "$RUN_OUT" | grep -cE '^=== l2-argtest-')"

# RESTORE CONTROL, full circle: the SAME shipped runner, a VALID invocation
# (no args) against the SAME fixture, still runs cleanly — the refusal
# above is not a blanket regression against legitimate calls.
run_l2 "$FX_ARGS"
assert_eq "14c.7 RESTORE CONTROL: the shipped runner, called validly (no args), still runs the full set green" "0" "$RUN_RC"
assert_contains "14c.8 ...all three fixture specs executed" \
    "Specs:      Total: 3  Passed: 3  Failed: 0" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 15. DOLT TELEMETRY DISARM: the embedded engine'"'"'s OWN flusher, not just bd'"'"'s (claude-workflow-plugin-gsfd/7tfe) ---\n'
# ===========================================================================
# bd EMBEDS dolt; the embedded engine spawns ITS OWN telemetry flusher
# ("dolt send-metrics") that section 10's BD_DISABLE_METRICS=1 cannot reach —
# icn4's fix round measured the leaked survivor by name (ppid=1,
# /opt/homebrew/bin/dolt send-metrics) inside THIS FILE's own nested
# bd-calling fixtures. MEASURED DIRECTLY (gsfd, not inferred from `dolt
# config --help`): `dolt sql -r csv -q "SELECT hashof('HEAD')"` against a
# fresh fixture store spawned the flusher 4/4 trials with no local config,
# 0/4 once `dolt config --local --add metrics.disabled true` was set inside
# that store — see run-tests.sh's TELEMETRY-DISARM region for the full
# measurement. This section verifies the WIRING (does the shipped runner
# actually call the disarm against a real embedded-Dolt fixture store) and,
# separately, that the INSTALLED dolt genuinely honours the config key — the
# same split section 10.11/10.12 already uses for bd's own variable.
if ! command -v bd >/dev/null 2>&1 || ! command -v dolt >/dev/null 2>&1; then
    printf '  SKIPPED: bd and/or dolt not on PATH — the dolt-disarm legs (15.1-15.10) need both\n'
else
    dolt_cfg() {
        # dolt_cfg <fixture-root> -- prints metrics.disabled, or "unset"
        ( cd "$1/.beads/embeddeddolt/beads" 2>/dev/null \
            && dolt config --local --get metrics.disabled 2>/dev/null ) || printf 'unset'
    }

    FX_DOLT="$WORK/dolt-disarm"
    mkdir -p "$FX_DOLT"
    ( cd "$FX_DOLT" && bd init --database beads --non-interactive >/dev/null 2>&1 )
    if [ ! -d "$FX_DOLT/.beads/embeddeddolt/beads/.dolt" ]; then
        printf '  SKIPPED: could not initialise a fixture Dolt store for the dolt-disarm legs\n'
    else
        mk_l1_fixture "$FX_DOLT" "$((EXPECTED - 1))"
        printf '#!/bin/bash\nprintf "  PASS: dolt-disarm probe ran\\n"\nexit 0\n' \
            > "$FX_DOLT/.claude/scripts/tests/zz-dolt-probe.sh"
        assert_eq "15.1 fresh fixture store starts with no local metrics.disabled config" \
            "unset" "$(dolt_cfg "$FX_DOLT")"

        run_l1 "$FX_DOLT"
        assert_eq "15.2 the shipped L1 runner sets metrics.disabled=true on a real embedded-Dolt fixture store (rc=0)" \
            "0" "$RUN_RC"
        assert_eq "15.3 ...and the config landed exactly there, local-scoped" \
            "true" "$(dolt_cfg "$FX_DOLT")"
        assert_eq "15.3a ...never in the user's OWN global dolt config (unaffected by this run)" \
            "" "$(dolt config --global --get metrics.disabled 2>/dev/null)"

        # META-TEST: excise the SAME TELEMETRY-DISARM region section 10
        # mutates (the dolt-disarm addition lives inside it, beside bd's own
        # disarm per 7tfe's own recommendation) and prove a fresh fixture
        # store is left untouched.
        FX_DOLT2="$WORK/dolt-disarm-mut"
        mkdir -p "$FX_DOLT2"
        ( cd "$FX_DOLT2" && bd init --database beads --non-interactive >/dev/null 2>&1 )
        mk_l1_fixture "$FX_DOLT2" "$((EXPECTED - 1))"
        printf '#!/bin/bash\nprintf "  PASS: dolt-disarm probe ran\\n"\nexit 0\n' \
            > "$FX_DOLT2/.claude/scripts/tests/zz-dolt-probe.sh"
        MUT_DOLT="$WORK/run-tests.no-dolt-disarm.sh"
        awk '
            /TELEMETRY-DISARM-BEGIN/ { skipping=1; found=1; next }
            /TELEMETRY-DISARM-END/   { skipping=0; next }
            !skipping { print }
            END { if (!found) exit 7 }
        ' "$L1_RUNNER" > "$MUT_DOLT"
        assert_eq "15.4 MUTANT: the telemetry-disarm region was FOUND and excised (non-vacuity, shares the region with 10.2)" \
            "0-differs-0" "$?-$(cmp -s "$L1_RUNNER" "$MUT_DOLT" && echo identical || echo differs)-$(bash -n "$MUT_DOLT" 2>/dev/null; echo $?)"
        RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_DOLT2" STRICT_SECTIONS=0 bash "$MUT_DOLT" 2>&1)
        RUN_RC=$?
        assert_eq "15.5 SPECIFIC: with the disarm excised, a fresh fixture store's config is left at unset" \
            "unset" "$(dolt_cfg "$FX_DOLT2")"

        # The L2 runner: same exemption, same pair.
        FX_L2DOLT="$WORK/l2-dolt-disarm"
        mkdir -p "$FX_L2DOLT"
        ( cd "$FX_L2DOLT" && bd init --database beads --non-interactive >/dev/null 2>&1 )
        mk_l2_fixture "$FX_L2DOLT"
        run_l2 "$FX_L2DOLT"
        assert_eq "15.6 the shipped L2 runner ALSO sets metrics.disabled=true on a real embedded-Dolt fixture store" \
            "true" "$(dolt_cfg "$FX_L2DOLT")"
        MUT_L2DOLT="$WORK/run.no-dolt-disarm.sh"
        awk '
            /TELEMETRY-DISARM-BEGIN/ { skipping=1; found=1; next }
            /TELEMETRY-DISARM-END/   { skipping=0; next }
            !skipping { print }
            END { if (!found) exit 7 }
        ' "$L2_RUNNER" > "$MUT_L2DOLT"
        assert_eq "15.7 L2 MUTANT: the region was found, excised, differs, parses" \
            "0-differs-0" "$?-$(cmp -s "$L2_RUNNER" "$MUT_L2DOLT" && echo identical || echo differs)-$(bash -n "$MUT_L2DOLT" 2>/dev/null; echo $?)"
        FX_L2DOLT2="$WORK/l2-dolt-disarm-mut"
        mkdir -p "$FX_L2DOLT2"
        ( cd "$FX_L2DOLT2" && bd init --database beads --non-interactive >/dev/null 2>&1 )
        mk_l2_fixture "$FX_L2DOLT2"
        CLAUDE_PROJECT_DIR="$FX_L2DOLT2" bash "$MUT_L2DOLT" >/dev/null 2>&1
        assert_eq "15.8 L2 SPECIFIC: with the disarm excised, a fresh fixture store's config is left at unset" \
            "unset" "$(dolt_cfg "$FX_L2DOLT2")"
    fi

    # The variable itself, verified against the INSTALLED dolt — mirrors
    # 10.11/10.12's split exactly, for the same reason: this turns a future
    # dolt renaming/removing metrics.disabled into a deterministic red HERE
    # instead of a re-litigated manual investigation. Spawn-detection over a
    # real fixture store, same methodology as the hand measurement this
    # section's header cites (ps polled every 50ms for up to 3s after a real
    # `dolt sql` call, filtered to the genuine `dolt send-metrics` argv so
    # this polling harness's OWN argv cannot self-match).
    # claude-workflow-plugin-gsfd fix round 2 (R2-F7, sol-codex review):
    # MEASURED both ways by the orchestrator — this spec's 15.10 FAILED
    # under a contended acceptance run (a Stop-hook `make test` overlapping),
    # and the identical spec passed 5/5 idle. Sol confirmed the mechanism by
    # reading: every scan below matched ANY `dolt send-metrics` process
    # host-wide via `ps -axo args=`, with no attribution to the STORE this
    # call actually exercised — foreign Dolt activity elsewhere on a shared
    # box can make 15.10 falsely red (an unrelated flusher observed, misread
    # as this store's) and, symmetrically, could make 15.9 falsely green (an
    # unrelated flusher observed while THIS store's own spawn silently
    # regressed). The disarm mechanism itself is NOT in question — 15.1-15.8
    # already establish that — only this probe's ability to tell "this
    # store" apart from "some other Dolt activity" on the same host.
    #
    # Fix: attribute by TWO independent signals together, because neither
    # alone is enough --
    #   (1) cwd: a genuine flusher launched from `cd "$store" && dolt sql`
    #       inherits that cwd. Read via /proc/<pid>/cwd on Linux (the
    #       kernel's own resolved path) or `lsof -a -p <pid> -d cwd` on
    #       macOS (no /proc there at all) — measured directly on this
    #       (macOS) box: /proc absent, `lsof -a -p <pid> -d cwd -Fn` prints
    #       an `n`-prefixed absolute path line matching `cd store && pwd -P`
    #       exactly, and a DIFFERENT directory is correctly excluded.
    #   (2) newly observed: 15.9 and 15.10 exercise the IDENTICAL fixture
    #       store, so cwd ALONE cannot tell a slow-to-exit flusher 15.9's
    #       own call spawned apart from one 15.10's call spawns — both
    #       report the same cwd. A snapshot of every already-attributed pid
    #       is taken before THIS call's own `dolt sql` ever runs (after the
    #       pre-drain confirms none is left over); only a pid ABSENT from
    #       that snapshot can be this call's own.
    # A pid failing EITHER check is not this call's flusher and is ignored,
    # in both directions symmetrically (neither 15.9 nor 15.10 can be
    # fooled by it). String-membership via padded-space + `index()` mirrors
    # this repo's own established idiom for pid-set tests (run.sh's
    # escalate_kill), not a bash ARRAY — an EMPTY bash array under `set -u`
    # is itself a portability landmine on this box's bash 3.2 (measured:
    # `"${arr[@]}"` on a zero-element array raises "unbound variable" here,
    # even with the array declared; `"${arr[@]:-}"` avoids the error but
    # then iterates ONE spurious empty-string element instead of zero).
    #
    # DEGRADE HONESTLY when neither attribution tool is available (no
    # /proc, no lsof): rather than falling back to the unattributed
    # host-wide guess this fix removes, the probe returns a THIRD outcome,
    # "unattributable" — callers must not read that as "not-seen" (a silent
    # pass over a check that could not run is exactly the failure mode the
    # pairing convention in .claude/tests/README.md exists to catch).
    _dolt_send_metrics_argv_pids() {
        # Every live pid host-wide whose argv matches the flusher's own
        # invocation shape, one per line — unattributed by construction;
        # callers filter by cwd below. `rest` strips the leading pid+
        # whitespace `ps -axo pid=,args=` prepends before applying the
        # IDENTICAL pattern the pre-fix, unattributed scan used, so this
        # helper is a strict refinement (adds attribution) rather than a
        # different detector.
        # shellcheck disable=SC2009  # ps|grep, not pgrep -f: needs the same
        # explicit self-exclusion as the pre-fix scan above (our OWN grep's
        # argv otherwise contains the literal pattern text it searches for).
        ps -axo pid=,args= 2>/dev/null \
            | grep -vE 'grep|poll_for_dolt_flusher|_dolt_send_metrics' \
            | awk '{
                pid = $1
                rest = $0
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", rest)
                if (rest ~ /(^|\/)dolt send-metrics/) print pid
            }'
    }
    _dolt_pid_cwd() {
        local p="$1" out=""
        if [ -e "/proc/$p/cwd" ] 2>/dev/null; then
            out=$(readlink "/proc/$p/cwd" 2>/dev/null) || out=""
        fi
        if [ -z "$out" ] && command -v lsof >/dev/null 2>&1; then
            out=$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | tail -1)
        fi
        printf '%s' "$out"
    }
    _dolt_attribution_available() {
        [ -n "$(readlink "/proc/$$/cwd" 2>/dev/null)" ] && { printf 'yes'; return 0; }
        command -v lsof >/dev/null 2>&1 && { printf 'yes'; return 0; }
        printf 'no'
    }
    _dolt_send_metrics_pids_at() {
        local want="$1" p cwd
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            cwd=$(_dolt_pid_cwd "$p")
            [ -n "$cwd" ] && [ "$cwd" = "$want" ] && printf '%s\n' "$p"
        done < <(_dolt_send_metrics_argv_pids)
    }
    poll_for_dolt_flusher() {
        # poll_for_dolt_flusher <store-dir> -- prints "seen", "not-seen", or
        # "unattributable". PRE-DRAINS and POST-DRAINS on THIS store's own
        # attributed pids (waits until none is visible, bounded ~5s each),
        # so this call's own detection window has a confirmed-clear start
        # AND end for the SAME store two consecutive calls (15.9, 15.10)
        # both exercise. Measured directly while pairing this section: a
        # post-drain ALONE was not enough — 1 of 3 trials still
        # false-positived the negative control (15.10) on a lingering
        # flusher from the PRECEDING call — but pre-drain + post-drain
        # together read clean 5/5.
        #
        # R5-F5 fix (independent cross-family review, round 5): the SAMPLING
        # LOOP below (the one that sets hit="seen" and breaks) used to be the
        # ONLY place this function ever set `hit` — a fixed 3-second window
        # right after launching `dolt sql`. The post-drain loop already ran
        # the IDENTICAL `_dolt_send_metrics_pids_at` query on every iteration
        # (it has to, to know when to stop draining) but only ever asked "is
        # this list empty yet", never "is what I'm looking at actually a NEW,
        # non-baseline pid" -- so a flusher that spawned after the 3s window
        # closed, or during `wait "$bgpid"`, or that was ONLY ever visible
        # during the post-drain's own polling, was drained away in total
        # silence: the result stayed "not-seen" regardless of what the
        # post-drain had just spent up to 5 seconds watching. That made the
        # NEGATIVE CONTROL (15.10, which asserts "not-seen") able to pass
        # for the wrong reason -- a real spawn the config failed to suppress,
        # observed only outside the original 3s window, would still read
        # "not-seen". Fixed by running the SAME new-pid check the sampling
        # loop uses inside the post-drain loop too, so any attributed pid
        # this function observes ANYWHERE in its own lifetime -- sampling
        # window, post-drain window, doesn't matter which -- sets `hit`.
        # The drain-to-completion behaviour (bounded ~5s, breaks once the
        # list reads empty) is unchanged; this only adds an observation, not
        # a new wait.
        #
        # KNOWN RESIDUAL, disclosed rather than silently accepted -- and
        # LARGER than the polling granularity alone would suggest
        # (claude-workflow-plugin-gsfd R6-F3: the previous wording here named
        # only the smaller of the two blind spots below and so understated
        # the gap). Two distinct blind spots, not one:
        #   - a flusher that spawns AND fully exits inside the ~50ms gap
        #     BETWEEN two polls, in EITHER loop -- small, bounded by the
        #     poll interval itself;
        #   - a flusher that spawns AND fully exits ENTIRELY inside
        #     `wait "$bgpid"` below, where NOTHING polls at all -- bounded
        #     only by how long the launched `dolt sql` itself takes, which
        #     can be far longer than 50ms under a slow store.
        # Closing either needs an event-based mechanism (strace/dtrace/an
        # audit hook), not a tighter poll interval or a poll wedged into the
        # wait -- the latter is the same background-supervision shape this
        # task's own operator-directed collapse removed elsewhere (the lease
        # heartbeat), reappearing here, and is out of scope for this fix.
        local store="$1" i hit="" store_real p
        local baseline_ids new_ids

        if [ "$(_dolt_attribution_available)" != "yes" ]; then
            printf 'unattributable'
            return 0
        fi
        store_real=$(cd "$store" 2>/dev/null && pwd -P) || store_real="$store"

        for i in $(seq 1 100); do
            [ -z "$(_dolt_send_metrics_pids_at "$store_real")" ] && break
            sleep 0.05
        done
        baseline_ids=" $(_dolt_send_metrics_pids_at "$store_real" | tr '\n' ' ') "

        ( cd "$store" && dolt sql -r csv -q "SELECT hashof('HEAD')" >/dev/null 2>&1 ) &
        local bgpid=$!
        for i in $(seq 1 60); do
            p=$(_dolt_send_metrics_pids_at "$store_real")
            if [ -n "$p" ]; then
                new_ids=$(printf '%s\n' "$p" | awk -v base="$baseline_ids" 'index(base, " " $1 " ") == 0 { print; exit }')
                if [ -n "$new_ids" ]; then
                    hit="seen"
                    break
                fi
            fi
            sleep 0.05
        done
        wait "$bgpid" 2>/dev/null
        for i in $(seq 1 100); do
            p=$(_dolt_send_metrics_pids_at "$store_real")
            if [ -n "$p" ]; then
                new_ids=$(printf '%s\n' "$p" | awk -v base="$baseline_ids" 'index(base, " " $1 " ") == 0 { print; exit }')
                [ -n "$new_ids" ] && hit="seen"
            fi
            [ -z "$p" ] && break
            sleep 0.05
        done
        printf '%s' "${hit:-not-seen}"
    }
    FX_SPAWN="$WORK/dolt-spawn-probe"
    mkdir -p "$FX_SPAWN"
    ( cd "$FX_SPAWN" && bd init --database beads --non-interactive >/dev/null 2>&1 )
    if [ -d "$FX_SPAWN/.beads/embeddeddolt/beads/.dolt" ]; then
        if [ "$(_dolt_attribution_available)" != "yes" ]; then
            printf '  SKIPPED: neither /proc nor lsof is available on this host to attribute a dolt send-metrics pid to the fixture store -- 15.9/15.10 cannot run without falling back to the unattributed host-wide guess this fix removes (claude-workflow-plugin-gsfd R2-F7)\n'
        else
            WITHOUT_CFG=$(poll_for_dolt_flusher "$FX_SPAWN/.beads/embeddeddolt/beads")
            assert_eq "15.9 the installed dolt spawns its flusher against a fresh store with no local config" \
                "seen" "$WITHOUT_CFG"
            ( cd "$FX_SPAWN/.beads/embeddeddolt/beads" && dolt config --local --add metrics.disabled true >/dev/null 2>&1 )
            WITH_CFG=$(poll_for_dolt_flusher "$FX_SPAWN/.beads/embeddeddolt/beads")
            assert_eq "15.10 NEGATIVE CONTROL: with metrics.disabled=true set, the SAME call spawns nothing (the config key is load-bearing, not decoration)" \
                "not-seen" "$WITH_CFG"

            # META-TEST: the attribution primitive itself discriminates by
            # cwd — a REAL process whose argv matches the flusher's shape
            # but whose cwd is a DIFFERENT directory must be invisible to a
            # query for THIS store, proving 15.9/15.10 are not vacuously
            # trusting "any dolt send-metrics anywhere" the way the
            # pre-fix scan did. `exec -a` sets argv[0] directly (measured:
            # `ps -axo args=` then shows the literal spoofed command,
            # portable on bash 3.2+).
            FX_DOLT_FOREIGN_A="$WORK/dolt-attrib-a"
            FX_DOLT_FOREIGN_B="$WORK/dolt-attrib-b"
            mkdir -p "$FX_DOLT_FOREIGN_A" "$FX_DOLT_FOREIGN_B"
            ( cd "$FX_DOLT_FOREIGN_A" && exec -a "dolt send-metrics" sleep 4 ) &
            FAKE_PID=$!
            sleep 0.3
            REAL_A=$(cd "$FX_DOLT_FOREIGN_A" && pwd -P)
            REAL_B=$(cd "$FX_DOLT_FOREIGN_B" && pwd -P)
            assert_contains "META 15.9/15.10: the attributed-pid query DOES find a real argv-matching process at ITS OWN cwd (non-vacuity: the primitive can find something)" \
                "$FAKE_PID" "$(_dolt_send_metrics_pids_at "$REAL_A")"
            assert_eq "META 15.9/15.10: ...and does NOT attribute that SAME process to a DIFFERENT directory (specific misbehaviour the pre-fix host-wide scan could not avoid)" \
                "" "$(_dolt_send_metrics_pids_at "$REAL_B")"
            wait "$FAKE_PID" 2>/dev/null
        fi
    else
        printf '  SKIPPED: could not initialise a second fixture Dolt store for the spawn-detection legs (15.9/15.10)\n'
    fi

    # -----------------------------------------------------------------------
    # R5-F5 META-TEST (independent cross-family review, round 5): 15.10 above
    # is a NEGATIVE CONTROL (asserts "not-seen"), and poll_for_dolt_flusher's
    # own hit="seen" assignment lived ONLY inside its fixed ~3-second
    # sampling loop right after launching `dolt sql` — a flusher that became
    # attributable only AFTER that window (during `wait "$bgpid"`, or only
    # ever visible to the POST-DRAIN loop that already runs afterward anyway
    # to confirm the tree is clear) left `hit` unset, so the function
    # returned "not-seen" regardless of what the post-drain loop had just
    # spent up to 5 seconds watching. That let 15.10 pass for the wrong
    # reason: a real spawn the config failed to suppress, observed only
    # outside the original window, would STILL read "not-seen". Fixed by
    # running the identical new-pid check inside the post-drain loop too
    # (see poll_for_dolt_flusher's own header for the full account).
    #
    # Proven here WITHOUT depending on real dolt/process timing (which
    # would make the scenario itself racy to construct): a DETERMINISTIC,
    # call-counted stub replaces the pid-attribution primitive for the
    # DURATION of this test only, returning empty for exactly the number of
    # calls the shipped loops make before the post-drain phase begins (1
    # pre-drain + 1 baseline + 60 sampling-loop iterations = 62 — the
    # shipped constants this counts against, confirmed by reading the
    # function above), then a fake never-baseline pid from call 63 onward —
    # i.e. a signal that is by construction invisible to the sampling loop
    # and visible only from the post-drain loop's own first iteration.
    if [ "$(_dolt_attribution_available)" = "yes" ]; then
        R5F5_DBGFILE="$WORK/r5f5-stub-calls.count"
        R5F5_STUB_TRIGGER=62
        # Captures the REAL _dolt_send_metrics_pids_at (as bash itself
        # already parsed it, not a hand-retyped reproduction free to drift)
        # so it can be put back after this test overrides it below —
        # nothing later in this file calls any of these dolt-disarm
        # helpers (confirmed: section 16 onward never references them), so
        # restoration is not needed for correctness here, only as hygiene
        # against a future section being added to this same block.
        R5F5_REAL_PIDS_AT_SRC=$(declare -f _dolt_send_metrics_pids_at)
        _dolt_send_metrics_pids_at() {
            printf 'x' >> "$R5F5_DBGFILE"
            local n
            n=$(wc -c < "$R5F5_DBGFILE" | tr -d '[:space:]')
            if [ "$n" -gt "$R5F5_STUB_TRIGGER" ]; then
                printf '999999\n'
            fi
        }

        # Build the mutant: the SAME post-drain if-block that checks for a
        # new pid, removed wholesale (not just its inner two lines -- an
        # empty then-body between `if ... then` and `fi` is itself a
        # syntax error, caught while pairing this section), leaving the
        # drain-until-empty behaviour and everything else -- including the
        # SAMPLING loop's own, untouched, new-pid check -- byte-identical.
        # Derived from `declare -f`, i.e. from what bash itself already
        # parsed out of the shipped definition above, not a hand-retyped
        # copy; comments are not preserved by `declare -f` (a property of
        # that builtin, not a fidelity gap in this extraction), so
        # non-vacuity below is checked by CONTENT rather than a line-count
        # diff against the commented source.
        R5F5_MUT_SRC=$(declare -f poll_for_dolt_flusher | awk '
            NR==1 { sub(/poll_for_dolt_flusher/, "poll_for_dolt_flusher_pre_r5f5"); print; next }
            /wait "\$bgpid"/ { after=1; print; next }
            after && /^[[:space:]]*if \[ -n "\$p" \]; then$/ { inblock=1; next }
            inblock && /^[[:space:]]*fi;?$/ { inblock=0; next }
            inblock { next }
            { print }
        ')
        eval "$R5F5_MUT_SRC"
        R5F5_MUT_EVAL_RC=$?
        assert_eq "R5-F5 META precondition: the mutant evaluates without a syntax error (non-vacuity of the transform itself)" \
            "0" "$R5F5_MUT_EVAL_RC"
        assert_eq "R5-F5 META: the mutation landed (mutant keeps only the SAMPLING loop's new-pid check, not the post-drain one -- 1 occurrence, not 2)" \
            "1" "$(declare -f poll_for_dolt_flusher_pre_r5f5 | grep -c 'new_ids=.*index(base' | tr -d '[:space:]')"
        assert_eq "R5-F5 META precondition: the shipped function itself still carries BOTH occurrences (sanity on the pattern, not just the mutant)" \
            "2" "$(declare -f poll_for_dolt_flusher | grep -c 'new_ids=.*index(base' | tr -d '[:space:]')"

        R5F5_FAKE_STORE="$WORK/r5f5-nonexistent-store"
        : > "$R5F5_DBGFILE"
        R5F5_RESULT_FIXED=$(poll_for_dolt_flusher "$R5F5_FAKE_STORE" 2>/dev/null)
        assert_eq "R5-F5 META: the SHIPPED function reports 'seen' for a pid visible only from the post-drain phase onward (restore control -- this is the fix's own job)" \
            "seen" "$R5F5_RESULT_FIXED"

        : > "$R5F5_DBGFILE"
        R5F5_RESULT_MUT=$(poll_for_dolt_flusher_pre_r5f5 "$R5F5_FAKE_STORE" 2>/dev/null)
        assert_eq "R5-F5 META: WITHOUT the post-drain check, the IDENTICAL scenario reports 'not-seen' (the bug's own exact symptom -- a real spawn the config failed to suppress would silently pass the 15.10 negative control)" \
            "not-seen" "$R5F5_RESULT_MUT"

        # Restore the real implementation captured above (hygiene; see the
        # note above -- correctness of THIS test does not depend on it).
        eval "$R5F5_REAL_PIDS_AT_SRC"
        unset -f poll_for_dolt_flusher_pre_r5f5 2>/dev/null || true
        rm -f "$R5F5_DBGFILE"
    else
        printf '  SKIPPED: R5-F5 META needs pid attribution (/proc or lsof), neither available on this host\n'
    fi
fi

# ===========================================================================
printf -- '\n--- 16. LEASE CONFLICT NOTICE: a concurrent tier'"'"'s lease is named, not guessed (claude-workflow-plugin-gsfd/mrd2) ---\n'
# ===========================================================================
# "who owns this tree right now" as a READ (claude-workflow-plugin-9xl4/gsfd
# member 5): the shipped runners acquire a lease via tree-lease.sh and print
# a CONCURRENT-RUN NOTICE naming any other LIVE lease found at startup, so a
# red spec downstream of contention (mrd2: review-separation.test.sh reading
# real bd records perturbed by a concurrent L2 run) is attributable in one
# read instead of a re-run habit that eventually waves a real regression
# through. This does NOT eliminate the contention (mrd2's fuller fix —
# fixture-local bd workspaces for record-touching specs — remains open,
# larger work); it makes the contention NAMEABLE.
#
# _rct_accurate_started_at -- claude-workflow-plugin-gsfd fix round 1
# (R1-F2): tree-lease.sh's lease_conflicts now cross-checks a same-host
# ALIVE pid's recorded started_at against that pid's own MEASURED elapsed
# runtime (ps -o etime=), and treats a mismatch as pid reuse -> STALE (see
# tree-lease.sh's own header). This section's own fixtures fabricate a
# lease claiming owner_pid=$$ (THIS spec's own pid) with a bare
# `$(date +%s)` for started_at -- the FABRICATION MOMENT, not $$'s true OS
# start time. By the time section 16 runs, deep into this ~2700-line spec,
# $$ has been alive for minutes, comfortably exceeding the 5s matching
# tolerance, so the fabricated lease reads as pid-reuse (STALE) instead of
# LIVE and the CONCURRENT-RUN NOTICE this section exists to test stops
# firing -- not a defect in the notice mechanism, a stale fixture assumption
# the fix's own test file (tree-lease.test.sh) hit and fixed the identical
# way (self_started_at). Self-contained here (this file does not source
# tree-lease.sh) rather than re-sourcing a whole second library into an
# already-large, timing-sensitive spec for one helper.
_rct_accurate_started_at() {
    local now elapsed raw days=0 hh=0 mm ss
    now=$(date +%s)
    raw=$(ps -o etime= -p "$$" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$raw" ]; then
        printf '%s' "$now"
        return 0
    fi
    case "$raw" in
        *-*) days="${raw%%-*}"; raw="${raw#*-}" ;;
    esac
    case "$raw" in
        *:*:*) hh="${raw%%:*}"; raw="${raw#*:}" ;;
    esac
    mm="${raw%%:*}"
    ss="${raw#*:}"
    case "${days}${hh}${mm}${ss}" in
        ''|*[!0-9]*) printf '%s' "$now"; return 0 ;;
    esac
    elapsed=$((10#$days * 86400 + 10#$hh * 3600 + 10#$mm * 60 + 10#$ss))
    printf '%s' "$((now - elapsed))"
}
FX_LEASE="$WORK/lease-notice"
mk_l1_fixture "$FX_LEASE" "$((EXPECTED - 1))"
printf '#!/bin/bash\nprintf "  PASS: lease-notice probe ran\\n"\nexit 0\n' \
    > "$FX_LEASE/.claude/scripts/tests/zz-lease-probe.sh"
mkdir -p "$FX_LEASE/.claude/.qa-tracking/leases"
printf 'tier=L2\nlabel=a concurrent component run\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
    "$$" "$(hostname 2>/dev/null || echo h)" "$(_rct_accurate_started_at)" \
    > "$FX_LEASE/.claude/.qa-tracking/leases/lease.L2.preexisting"
run_l1 "$FX_LEASE"
assert_eq "16.1 the shipped L1 runner prints a CONCURRENT-RUN NOTICE when a live L2 lease already exists (rc=0)" \
    "0" "$RUN_RC"
assert_contains "16.2 ...naming the notice" "CONCURRENT-RUN NOTICE" "$RUN_OUT"
assert_contains "16.3 ...naming the OTHER tier and label" "tier=L2" "$RUN_OUT"

# RESTORE CONTROL: an otherwise-identical fixture with NO pre-existing lease
# prints no notice at all — the notice is conditioned on a genuine conflict,
# not printed unconditionally.
FX_LEASE_CLEAN="$WORK/lease-notice-clean"
mk_l1_fixture "$FX_LEASE_CLEAN" "$((EXPECTED - 1))"
printf '#!/bin/bash\nprintf "  PASS: lease-notice probe ran\\n"\nexit 0\n' \
    > "$FX_LEASE_CLEAN/.claude/scripts/tests/zz-lease-probe.sh"
run_l1 "$FX_LEASE_CLEAN"
assert_eq "16.4 RESTORE CONTROL: with no pre-existing lease, the shipped runner prints no notice" \
    "0" "$(printf '%s' "$RUN_OUT" | grep -c 'CONCURRENT-RUN NOTICE')"

# The notice must also correctly IGNORE a STALE lease (a dead pid) — it is
# not a conflict.
#
# ROUND 6 DESIGN COLLAPSE (claude-workflow-plugin-gsfd, operator-directed):
# this whole sub-section used to test R2-F1's UNCONFIRMED status — a dead
# pid read UNCONFIRMED on a FRESH mtime (surfaced as a distinctly-worded
# notice, never reclaimed) and only became STALE (never surfaced, and WAS
# auto-reclaimed by `lease_reclaim_stale` inside `lease_acquire`) once old
# enough. Both halves of that behaviour are gone: the lease is report-only
# now, `lease_acquire` no longer self-heals via `lease_reclaim_stale` at
# all, and the grammar collapsed to two values with no age threshold
# deciding either (see tree-lease.sh's own DESIGN COLLAPSE header). A dead
# pid reads STALE regardless of its lease file's mtime — fresh or ancient,
# identically — is never surfaced as a notice, and its file is left exactly
# where it was (nothing here ever deletes it automatically any more). The
# two legs below prove BOTH halves of that collapse directly rather than
# assume them: same dead-pid scenario at two different mtimes, proving age
# no longer changes the outcome, and proving neither one is auto-reclaimed
# — a real, measured regression from the pre-collapse version of this
# section (16.6 asserted the file WOULD be gone; it is not, by design) that
# re-running this file after the collapse caught, not assumed unaffected
# because the change looked confined to tree-lease.sh and qa-gate.sh.
FX_LEASE_DEAD="$WORK/lease-notice-stale"
mk_l1_fixture "$FX_LEASE_DEAD" "$((EXPECTED - 1))"
printf '#!/bin/bash\nprintf "  PASS: lease-notice probe ran\\n"\nexit 0\n' \
    > "$FX_LEASE_DEAD/.claude/scripts/tests/zz-lease-probe.sh"
mkdir -p "$FX_LEASE_DEAD/.claude/.qa-tracking/leases"
DEADPID=99999
while kill -0 "$DEADPID" 2>/dev/null; do DEADPID=$((DEADPID + 1)); done
LEASE_DEAD_FILE="$FX_LEASE_DEAD/.claude/.qa-tracking/leases/lease.L2.stale"
printf 'tier=L2\nlabel=a crashed component run\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
    "$DEADPID" "$(hostname 2>/dev/null || echo h)" "$(date +%s)" \
    > "$LEASE_DEAD_FILE"
touch -t 202001010000 "$LEASE_DEAD_FILE" 2>/dev/null || touch -d '2020-01-01' "$LEASE_DEAD_FILE" 2>/dev/null
run_l1 "$FX_LEASE_DEAD"
assert_eq "16.5 an ANCIENT-mtime dead-pid lease (STALE) is not reported as a conflict" \
    "0" "$(printf '%s' "$RUN_OUT" | grep -c 'CONCURRENT-RUN NOTICE')"
assert_eq "16.6 ...and the STALE lease file SURVIVES (report-only: nothing here auto-reclaims it any more, even when ancient)" \
    "yes" "$([ -f "$LEASE_DEAD_FILE" ] && echo yes || echo no)"

# Age-independence, proven rather than assumed: the IDENTICAL scenario at a
# FRESH mtime must behave EXACTLY the same as the ancient one above — no
# notice, file survives — because nothing left in this design treats age as
# a threshold for a dead-pid reading. This is the integration-level
# companion to tree-lease.test.sh's own unit-level coverage of the same
# invariant (round 6, section 3/4 there).
FX_LEASE_FRESH_DEAD="$WORK/lease-notice-fresh-dead"
mk_l1_fixture "$FX_LEASE_FRESH_DEAD" "$((EXPECTED - 1))"
printf '#!/bin/bash\nprintf "  PASS: lease-notice probe ran\\n"\nexit 0\n' \
    > "$FX_LEASE_FRESH_DEAD/.claude/scripts/tests/zz-lease-probe.sh"
mkdir -p "$FX_LEASE_FRESH_DEAD/.claude/.qa-tracking/leases"
DEADPID2=99999
while kill -0 "$DEADPID2" 2>/dev/null; do DEADPID2=$((DEADPID2 + 1)); done
LEASE_FRESH_DEAD_FILE="$FX_LEASE_FRESH_DEAD/.claude/.qa-tracking/leases/lease.L2.fresh-dead"
printf 'tier=L2\nlabel=a fresh dead-pid reading\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
    "$DEADPID2" "$(hostname 2>/dev/null || echo h)" "$(date +%s)" \
    > "$LEASE_FRESH_DEAD_FILE"
run_l1 "$FX_LEASE_FRESH_DEAD"
assert_eq "16.6b a FRESH-mtime dead-pid lease is ALSO not reported as a conflict (age never changes a dead-pid reading any more)" \
    "0" "$(printf '%s' "$RUN_OUT" | grep -c 'CONCURRENT-RUN NOTICE')"
assert_eq "16.6c ...and its lease file ALSO survives, identically to the ancient one above" \
    "yes" "$([ -f "$LEASE_FRESH_DEAD_FILE" ] && echo yes || echo no)"

# META-TEST: excise the LEASE-ACQUIRE region and prove the notice never
# fires even with a live conflicting lease present — the SPECIFIC
# misbehaviour this section exists to catch (silence over a real conflict).
MUT_LEASE="$WORK/run-tests.no-lease.sh"
awk '
    /LEASE-ACQUIRE-BEGIN/ { skipping=1; found=1; next }
    /LEASE-ACQUIRE-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L1_RUNNER" > "$MUT_LEASE"
assert_eq "16.7 MUTANT: the lease-acquire region was FOUND and excised, differs, parses" \
    "0-differs-0" "$?-$(cmp -s "$L1_RUNNER" "$MUT_LEASE" && echo identical || echo differs)-$(bash -n "$MUT_LEASE" 2>/dev/null; echo $?)"
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_LEASE" STRICT_SECTIONS=0 bash "$MUT_LEASE" 2>&1)
RUN_RC=$?
assert_eq "16.8 SPECIFIC: with lease-acquire excised, the SAME live-conflict fixture prints no notice at all" \
    "0" "$(printf '%s' "$RUN_OUT" | grep -c 'CONCURRENT-RUN NOTICE')"

# The L2 runner: same pair, other direction (an L1 lease already present).
FX_L2LEASE="$WORK/l2-lease-notice"
mk_l2_fixture "$FX_L2LEASE"
cat > "$FX_L2LEASE/.claude/tests/component/specs/l2-lease-stub.sh" <<'EOF'
assert_eq "l2-lease-stub ran" "x" "x"
EOF
mkdir -p "$FX_L2LEASE/.claude/.qa-tracking/leases"
printf 'tier=L1\nlabel=a concurrent unit run\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
    "$$" "$(hostname 2>/dev/null || echo h)" "$(_rct_accurate_started_at)" \
    > "$FX_L2LEASE/.claude/.qa-tracking/leases/lease.L1.preexisting"
run_l2 "$FX_L2LEASE"
assert_eq "16.9 the shipped L2 runner ALSO prints a CONCURRENT-RUN NOTICE when a live L1 lease exists" \
    "yes" "$(printf '%s' "$RUN_OUT" | grep -q 'CONCURRENT-RUN NOTICE' && echo yes || echo no)"
MUT_L2LEASE="$WORK/run.no-lease.sh"
awk '
    /LEASE-ACQUIRE-BEGIN/ { skipping=1; found=1; next }
    /LEASE-ACQUIRE-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$L2_RUNNER" > "$MUT_L2LEASE"
assert_eq "16.10 L2 MUTANT: the region was found, excised, differs, parses" \
    "0-differs-0" "$?-$(cmp -s "$L2_RUNNER" "$MUT_L2LEASE" && echo identical || echo differs)-$(bash -n "$MUT_L2LEASE" 2>/dev/null; echo $?)"
RUN_OUT=$(CLAUDE_PROJECT_DIR="$FX_L2LEASE" bash "$MUT_L2LEASE" 2>&1)
assert_eq "16.11 L2 SPECIFIC: with lease-acquire excised, the same live-conflict fixture prints no notice" \
    "0" "$(printf '%s' "$RUN_OUT" | grep -c 'CONCURRENT-RUN NOTICE')"

# ===========================================================================
printf -- '\n--- 17. FIXED /tmp PATH CENSUS: no L2 spec redirects to a literal /tmp/<name> shared across concurrent runs (claude-workflow-plugin-gsfd/jjen) ---\n'
# ===========================================================================
# jjen: specs/model-select.sh wrote FIXED /tmp/ms-*.err|out paths that two
# concurrent L2 runs clobbered — the only interlock anywhere in the tree was
# the orchestrator's own pgrep busy-guard, which stops a second run IT
# starts and nothing else. Fixed alongside code-graph-mcp.sh (two more
# occurrences of the identical shape, found by ENUMERATING every literal
# /tmp/ redirect across the WHOLE specs population rather than trusting the
# one file named in the task — the "denominator" convention LESSONS.md
# records after three consecutive completeness claims in this arc were
# falsified by the next sweep). This census is the STRUCTURAL guard against
# reintroduction jjen itself asked for: it does not fix a spec, it fails the
# tier when one writes a fixed shared /tmp path again.
#
# THE PREDICATE, and why it needs two stages. A REDIRECTION OPERATOR (>, >>,
# or 2>) immediately followed by a literal /tmp/<word> catches the genuine
# shape — but the specs population ALSO contains /tmp/<word> as plain TEST
# DATA: post-edit.sh feeds a JSON payload whose "command" field CONTAINS the
# text `printf x > /tmp/written-by-bash.ts` as a STRING, never executed,
# which the naive one-stage regex flags as a false positive (measured while
# building this census — the exact "do not count text to prove a claim
# about code" failure mode .claude/tests/README.md warns about). The second
# stage excludes any hit whose /tmp/path is followed by a literal `"` —
# every JSON-embedded false positive in this tree closes its string there,
# and no genuine UNQUOTED shell redirect target in this codebase's style is
# ever written with a trailing quote. denylist-shared.sh and
# failure-cross-repo.sh's OWN /tmp/... literals (classifier test DATA, never
# opened as real files) are excluded the same way the full-population run at
# 17.1 already demonstrates, without needing a per-file carve-out.
#
# claude-workflow-plugin-gsfd fix round 1 (R1-F7, sol-codex review) fixed two
# things here:
#   1. A QUOTED redirect target (`2>"/tmp/x"`) was missed TWICE OVER. Stage 1
#      required /tmp/ immediately after the operator+whitespace with no
#      quote in between, so `2>"/tmp/x"` never matched at all; even if it
#      had, stage 2's trailing-bare-quote filter (built for the JSON case)
#      would ALSO have excluded it, since a quoted target's closing quote
#      sits right after the path too. Fixed with a THIRD, separate pass
#      (below) for quoted targets specifically: an opening quote immediately
#      adjacent to the operator can only be produced by a real "quote this
#      one redirect target" idiom — the JSON false-positive shape in this
#      tree encodes the WHOLE shell command as one JSON string value, so its
#      one opening quote sits well BEFORE the operator, never adjacent to
#      it — so a quoted hit is always genuine, no further filter needed.
#   2. Enumeration failure read as clean. The original one-liner passed the
#      glob `"$1"/*.sh` straight to grep; a missing directory or a directory
#      with zero .sh files leaves that glob UNEXPANDED (nullglob is not on),
#      so grep received the literal, nonexistent pattern string as a
#      filename, failed on stderr (suppressed by 2>/dev/null), and this
#      function's own `return 0` swallowed grep's nonzero exit — a caller
#      checking only the (empty) OUTPUT saw something structurally
#      IDENTICAL to a genuinely clean population. Fixed by enumerating the
#      population explicitly and refusing (rc 3, stderr diagnostic) when it
#      is empty, rather than silently returning "".
#
# claude-workflow-plugin-gsfd fix round 2 (R2-F5, sol-codex review) fixed two
# more:
#   3. A SINGLE-quoted redirect target (`2>'/tmp/x'`) missed BOTH stage-1
#      passes — stage 1 (double-quoted) requires a literal `"`, stage 2
#      (bare) requires `/tmp/` with no quote character at all between it and
#      the operator, and a single quote satisfies neither. A FOURTH pass,
#      below, mirrors stage 1 exactly with the quote character swapped — the
#      identical R1-F7 reasoning applies unchanged (a single quote sitting
#      immediately after the operator is just as deliberate an idiom as a
#      double one, and this tree's one JSON false-positive shape can never
#      produce it, because JSON's own string delimiter is `"`, never `'`).
#   4. Enumeration succeeding with a NON-EMPTY population could still miss
#      real content silently: `find`'s own exit status was discarded by the
#      `< <(find ...)` process substitution (only the resulting file COUNT
#      was checked), so a `find` that errored partway through this
#      directory's listing after already emitting some names read as a
#      complete, clean enumeration. Separately, each grep pass suppressed
#      its own stderr and this function's unconditional `return 0` ignored
#      every grep's exit code — a population containing an UNREADABLE .sh
#      file (grep can list it via the directory's own permissions but
#      cannot open its content) silently scanned every OTHER file and
#      reported clean, never surfacing the one it could not read. Fixed by
#      routing `find` through a captured file instead of a process
#      substitution (the only way to observe its own exit status at all) and
#      by checking grep's own exit code isolated to each individual
#      invocation — 2 means "grep hit a read/open error", REGARDLESS of
#      whether it also found genuine matches in files it could read (0 = at
#      least one match, 1 = no match, 2 = error; documented behaviour on both
#      GNU and BSD grep, measured directly on this box's BSD grep with an
#      unreadable file mixed among matching and non-matching readable ones —
#      rc=2 in every combination). `find`'s own error is checked BEFORE the
#      zero-files check below, not after: an unreadable top-level directory
#      makes `find` fail AND return zero names, and the more specific
#      diagnosis ("find itself errored") is more informative than the
#      generic "nothing found" one when both are true simultaneously.
census_fixed_tmp_redirects() {
    local dir="$1"
    local -a files=()
    local find_rc=0 find_list=""
    if [ -d "$dir" ]; then
        find_list=$(mktemp -t census-find-list.XXXXXX 2>/dev/null) || find_list=""
        if [ -n "$find_list" ]; then
            find "$dir" -maxdepth 1 -type f -name '*.sh' -print0 > "$find_list" 2>/dev/null
            find_rc=$?
            while IFS= read -r -d '' f; do
                files+=("$f")
            done < "$find_list"
            rm -f "$find_list" 2>/dev/null
        else
            find_rc=1
        fi
    fi
    if [ "$find_rc" -ne 0 ]; then
        printf 'census_fixed_tmp_redirects: ENUMERATION FAILED -- find exited %s while listing %s (population may be partial or entirely unlisted, not scanned in full)\n' \
            "$find_rc" "$dir" >&2
        return 4
    fi
    if [ "${#files[@]}" -eq 0 ]; then
        printf 'census_fixed_tmp_redirects: ENUMERATION FAILED -- no .sh files found under %s\n' "$dir" >&2
        return 3
    fi
    # `-H` is load-bearing, not decoration: grep omits the filename prefix
    # by default when the argument list happens to expand to exactly ONE
    # file (a single-spec test fixture, as opposed to the real specs
    # population with dozens) — caught by 17.4 asserting the offending FILE
    # is named, not just the line.
    local hits="" out grep_rc
    out=$(grep -nHE '(>{1,2}|2>{1,2})[[:space:]]*"/tmp/[A-Za-z][A-Za-z0-9_.-]*"' "${files[@]}" 2>/dev/null)
    grep_rc=$?
    if [ "$grep_rc" -eq 2 ]; then
        printf 'census_fixed_tmp_redirects: a file under %s could not be read (grep error, double-quoted pass) -- population not fully scanned\n' "$dir" >&2
        return 5
    fi
    [ -n "$out" ] && hits="${hits}${out}
"
    out=$(grep -nHE "(>{1,2}|2>{1,2})[[:space:]]*'/tmp/[A-Za-z][A-Za-z0-9_.-]*'" "${files[@]}" 2>/dev/null)
    grep_rc=$?
    if [ "$grep_rc" -eq 2 ]; then
        printf 'census_fixed_tmp_redirects: a file under %s could not be read (grep error, single-quoted pass) -- population not fully scanned\n' "$dir" >&2
        return 5
    fi
    [ -n "$out" ] && hits="${hits}${out}
"
    out=$(grep -nHE '(>{1,2}|2>{1,2})[[:space:]]*/tmp/[A-Za-z]' "${files[@]}" 2>/dev/null)
    grep_rc=$?
    if [ "$grep_rc" -eq 2 ]; then
        printf 'census_fixed_tmp_redirects: a file under %s could not be read (grep error, bare pass) -- population not fully scanned\n' "$dir" >&2
        return 5
    fi
    if [ -n "$out" ]; then
        out=$(printf '%s\n' "$out" | grep -vE '/tmp/[A-Za-z0-9_.-]*"')
        [ -n "$out" ] && hits="${hits}${out}
"
    fi
    printf '%s' "$hits" | sed '/^$/d'
    return 0
}

SPECS_DIR_CENSUS="$PLUGIN_DIR/.claude/tests/component/specs"
CENSUS_17_1_OUT=$(census_fixed_tmp_redirects "$SPECS_DIR_CENSUS")
CENSUS_17_1_RC=$?
assert_eq "17.1 the shipped specs population has ZERO fixed /tmp redirects" \
    "" "$CENSUS_17_1_OUT"
assert_eq "17.1b ...and enumeration itself succeeded (loud distinguishing signal, not a coincidental empty result)" \
    "0" "$CENSUS_17_1_RC"

# Non-vacuity + specific misbehaviour: copy a KNOWN-CLEAN spec, reintroduce
# the exact historical shape, and prove the census catches it BY NAME.
FX_CENSUS="$WORK/tmp-census"
mkdir -p "$FX_CENSUS"
cp "$SPECS_DIR_CENSUS/model-select.sh" "$FX_CENSUS/model-select.sh"
# shellcheck disable=SC2016  # single quotes intentional: $MS must stay
# literal text appended to the fixture file, not expand in THIS shell.
printf '\nbash "$MS" apply 2>/tmp/reintroduced-probe.err >/dev/null\n' >> "$FX_CENSUS/model-select.sh"
bash -n "$FX_CENSUS/model-select.sh"
assert_eq "17.2 non-vacuity: the mutated copy still parses" "0" "$?"
CENSUS_HIT=$(census_fixed_tmp_redirects "$FX_CENSUS")
assert_contains "17.3 SPECIFIC: the census catches the reintroduced fixed path, by name" \
    "/tmp/reintroduced-probe.err" "$CENSUS_HIT"
assert_contains "17.4 ...and names the file it found it in" \
    "model-select.sh" "$CENSUS_HIT"

# RESTORE CONTROL: the SAME file, unmutated, in the SAME throwaway
# directory, is clean — the positive result at 17.3 is about the mutation,
# not an artefact of running the census over a copy rather than the original.
FX_CENSUS_CLEAN="$WORK/tmp-census-clean"
mkdir -p "$FX_CENSUS_CLEAN"
cp "$SPECS_DIR_CENSUS/model-select.sh" "$FX_CENSUS_CLEAN/model-select.sh"
assert_eq "17.5 RESTORE CONTROL: the unmutated copy is clean" \
    "" "$(census_fixed_tmp_redirects "$FX_CENSUS_CLEAN")"

# NEGATIVE CONTROL, the false-positive class this predicate exists to avoid:
# a copy of post-edit.sh (its JSON payload carries the "printf x > /tmp/..."
# STRING) must stay clean — proving the second grep stage is load-bearing,
# not decoration.
FX_CENSUS_JSON="$WORK/tmp-census-json"
mkdir -p "$FX_CENSUS_JSON"
cp "$SPECS_DIR_CENSUS/post-edit.sh" "$FX_CENSUS_JSON/post-edit.sh"
assert_eq "17.6 NEGATIVE CONTROL: post-edit.sh's JSON-payload /tmp/ STRING is not flagged" \
    "" "$(census_fixed_tmp_redirects "$FX_CENSUS_JSON")"
ONE_STAGE_HIT=$(grep -nE '(>{1,2}|2>{1,2})[[:space:]]*/tmp/[A-Za-z]' "$FX_CENSUS_JSON/post-edit.sh" 2>/dev/null)
assert_contains "17.7 ...confirming the ONE-STAGE regex alone WOULD have flagged it (the second stage is doing real work)" \
    "written-by-bash" "$ONE_STAGE_HIT"

# claude-workflow-plugin-gsfd R1-F7 fix (sol-codex review), leg 1: a QUOTED
# fixed /tmp redirect (`2>"/tmp/x"`) is the exact shape that was missed
# twice over before this fix (see census_fixed_tmp_redirects's own header).
# Non-vacuity + specific misbehaviour, same shape as 17.2-17.4 above.
FX_CENSUS_Q="$WORK/tmp-census-quoted"
mkdir -p "$FX_CENSUS_Q"
cp "$SPECS_DIR_CENSUS/model-select.sh" "$FX_CENSUS_Q/model-select.sh"
# shellcheck disable=SC2016  # single quotes intentional: $MS must stay
# literal text appended to the fixture file, not expand in THIS shell.
printf '\nbash "$MS" apply 2>"/tmp/quoted-reintroduced-probe.err" >/dev/null\n' >> "$FX_CENSUS_Q/model-select.sh"
bash -n "$FX_CENSUS_Q/model-select.sh"
assert_eq "17.8 non-vacuity: the quoted-redirect mutated copy still parses" "0" "$?"
CENSUS_Q_HIT=$(census_fixed_tmp_redirects "$FX_CENSUS_Q")
assert_contains "17.9 SPECIFIC: the census catches the reintroduced QUOTED fixed path, by name" \
    "/tmp/quoted-reintroduced-probe.err" "$CENSUS_Q_HIT"
assert_contains "17.10 ...and names the file it found it in" \
    "model-select.sh" "$CENSUS_Q_HIT"

# RESTORE CONTROL: the SAME file, unmutated, in the SAME throwaway
# directory, is clean — the positive result at 17.9 is about the quoted
# mutation, not an artefact of this new fixture directory.
FX_CENSUS_Q_CLEAN="$WORK/tmp-census-quoted-clean"
mkdir -p "$FX_CENSUS_Q_CLEAN"
cp "$SPECS_DIR_CENSUS/model-select.sh" "$FX_CENSUS_Q_CLEAN/model-select.sh"
assert_eq "17.11 RESTORE CONTROL: the unmutated copy (quoted-redirect fixture dir) is clean" \
    "" "$(census_fixed_tmp_redirects "$FX_CENSUS_Q_CLEAN")"

# NEGATIVE CONTROL for the quoted pass: post-edit.sh's JSON test data must
# still not be flagged even though its /tmp/ occurrence is followed
# (eventually) by other quoted text elsewhere on the line — the quoted-pass
# regex only fires when the OPENING quote is immediately adjacent to the
# operator, which the JSON shape never is (its one opening quote sits well
# before the operator, as part of the JSON value's own delimiter).
assert_eq "17.12 NEGATIVE CONTROL: post-edit.sh's JSON payload is not flagged by the quoted pass either" \
    "" "$(census_fixed_tmp_redirects "$FX_CENSUS_JSON")"

# ===========================================================================
# claude-workflow-plugin-gsfd R1-F7 fix, leg 2: an UNREADABLE population
# (missing directory, or a directory with zero .sh files) must be LOUDLY
# distinguishable from a genuinely CLEAN one — both used to print empty
# output with rc 0 under the original one-liner.
FX_CENSUS_MISSING="$WORK/tmp-census-does-not-exist"
CENSUS_MISSING_OUT=$(census_fixed_tmp_redirects "$FX_CENSUS_MISSING" 2>"$WORK/census-missing.stderr")
CENSUS_MISSING_RC=$?
assert_eq "17.13 a MISSING directory: output is empty (same shape a clean population would show)" \
    "" "$CENSUS_MISSING_OUT"
assert_eq "17.14 ...but the return code says ENUMERATION FAILED, not clean (the loud distinguishing signal)" \
    "3" "$CENSUS_MISSING_RC"
assert_contains "17.15 ...and stderr names what failed" \
    "ENUMERATION FAILED" "$(cat "$WORK/census-missing.stderr")"

FX_CENSUS_EMPTY="$WORK/tmp-census-empty-dir"
mkdir -p "$FX_CENSUS_EMPTY"
CENSUS_EMPTY_OUT=$(census_fixed_tmp_redirects "$FX_CENSUS_EMPTY" 2>"$WORK/census-empty.stderr")
CENSUS_EMPTY_RC=$?
assert_eq "17.16 an EXISTING but EMPTY (zero .sh files) directory: output is also empty" \
    "" "$CENSUS_EMPTY_OUT"
assert_eq "17.17 ...and ALSO reports ENUMERATION FAILED, not clean" \
    "3" "$CENSUS_EMPTY_RC"

# META-TEST: the historical, PRE-FIX predicate — a single grep piped over
# the UNEXPANDED glob, exactly as it shipped before this fix round — proves
# the specific misbehaviour: run against the IDENTICAL empty-directory
# fixture above, it returns EMPTY OUTPUT AND rc 0, indistinguishable from a
# genuinely clean population. The shipped predicate (17.16/17.17 above,
# same fixture) does not.
census_fixed_tmp_redirects_pre_fix() {
    grep -nHE '(>{1,2}|2>{1,2})[[:space:]]*/tmp/[A-Za-z]' "$1"/*.sh 2>/dev/null \
        | grep -vE '/tmp/[A-Za-z0-9_.-]*"'
    return 0
}
PRE_FIX_OUT=$(census_fixed_tmp_redirects_pre_fix "$FX_CENSUS_EMPTY")
PRE_FIX_RC=$?
assert_eq "META 17: the historical predicate, same empty-dir fixture, ALSO prints empty output" \
    "" "$PRE_FIX_OUT"
assert_eq "META 17: ...but reports rc 0 (clean) instead of enumeration failure — the specific misbehaviour this fix removes" \
    "0" "$PRE_FIX_RC"

# ===========================================================================
# claude-workflow-plugin-gsfd fix round 2 (R2-F5, sol-codex review), leg 1: a
# SINGLE-quoted fixed /tmp redirect (`2>'/tmp/x'`) — the shape the R1-F7 fix
# still missed, since neither its double-quoted pass nor its bare pass
# matches a single quote sitting between the operator and the path. Same
# non-vacuity + specific-misbehaviour + restore-control shape as legs 17.2-
# 17.4 (bare) and 17.8-17.11 (double-quoted) above.
FX_CENSUS_SQ="$WORK/tmp-census-single-quoted"
mkdir -p "$FX_CENSUS_SQ"
cp "$SPECS_DIR_CENSUS/model-select.sh" "$FX_CENSUS_SQ/model-select.sh"
# shellcheck disable=SC2016  # single quotes intentional: $MS must stay
# literal text appended to the fixture file, not expand in THIS shell.
printf '\nbash "$MS" apply 2>'"'"'/tmp/single-quoted-reintroduced-probe.err'"'"' >/dev/null\n' \
    >> "$FX_CENSUS_SQ/model-select.sh"
bash -n "$FX_CENSUS_SQ/model-select.sh"
assert_eq "17.18 non-vacuity: the single-quoted-redirect mutated copy still parses" "0" "$?"
assert_contains "17.18b non-vacuity: the mutation actually landed as a single-quoted target (not double)" \
    "2>'/tmp/single-quoted-reintroduced-probe.err'" "$(cat "$FX_CENSUS_SQ/model-select.sh")"
CENSUS_SQ_HIT=$(census_fixed_tmp_redirects "$FX_CENSUS_SQ")
assert_contains "17.19 SPECIFIC: the census catches the reintroduced SINGLE-quoted fixed path, by name (R1-F7's own fix could not)" \
    "/tmp/single-quoted-reintroduced-probe.err" "$CENSUS_SQ_HIT"
assert_contains "17.20 ...and names the file it found it in" \
    "model-select.sh" "$CENSUS_SQ_HIT"

# RESTORE CONTROL: the SAME file, unmutated, in the SAME throwaway
# directory, is clean.
FX_CENSUS_SQ_CLEAN="$WORK/tmp-census-single-quoted-clean"
mkdir -p "$FX_CENSUS_SQ_CLEAN"
cp "$SPECS_DIR_CENSUS/model-select.sh" "$FX_CENSUS_SQ_CLEAN/model-select.sh"
assert_eq "17.21 RESTORE CONTROL: the unmutated copy (single-quoted-redirect fixture dir) is clean" \
    "" "$(census_fixed_tmp_redirects "$FX_CENSUS_SQ_CLEAN")"

# NEGATIVE CONTROL: post-edit.sh's JSON test data still must not be flagged
# by the new single-quoted pass either — its one /tmp/ occurrence has no
# single quote adjacent to an operator at all.
assert_eq "17.22 NEGATIVE CONTROL: post-edit.sh's JSON payload is not flagged by the single-quoted pass either" \
    "" "$(census_fixed_tmp_redirects "$FX_CENSUS_JSON")"

# META-TEST: the R1-F7-fixed (but still R2-F5-broken) predicate — double-
# quoted + bare passes only, no single-quoted pass — run against the
# IDENTICAL single-quoted fixture above, reads clean. Proves 17.19 is
# genuinely about the fourth pass added in this round, not an artefact of
# the fixture.
census_fixed_tmp_redirects_pre_r2f5() {
    local dir="$1"
    grep -nHE '(>{1,2}|2>{1,2})[[:space:]]*"/tmp/[A-Za-z][A-Za-z0-9_.-]*"' "$dir"/*.sh 2>/dev/null
    grep -nHE '(>{1,2}|2>{1,2})[[:space:]]*/tmp/[A-Za-z]' "$dir"/*.sh 2>/dev/null \
        | grep -vE '/tmp/[A-Za-z0-9_.-]*"'
    return 0
}
assert_eq "META 17b: the pre-R2-F5 (R1-F7-only) predicate misses the single-quoted reintroduction entirely (specific misbehaviour)" \
    "" "$(census_fixed_tmp_redirects_pre_r2f5 "$FX_CENSUS_SQ")"

# ===========================================================================
# claude-workflow-plugin-gsfd fix round 2 (R2-F5, sol-codex review), leg 2:
# a population that ENUMERATES successfully (non-empty file list) but
# contains a file grep cannot READ must not report clean — the gap the
# original leg-2 fix (rc 3 on zero .sh files) did not close, because this
# population has files; the census just never looked at what reading one of
# them actually returned. `chmod 000` on the FILE (not the directory) is
# what forces this: `find` can still list an unreadable file by name via the
# PARENT directory's own permissions (measured directly, this box), so this
# is a population-content failure, not an enumeration one — the FILE-count
# check earlier in the function is not what catches it.
FX_CENSUS_UNREADABLE="$WORK/tmp-census-unreadable"
mkdir -p "$FX_CENSUS_UNREADABLE"
cp "$SPECS_DIR_CENSUS/model-select.sh" "$FX_CENSUS_UNREADABLE/model-select.sh"
printf '#!/bin/bash\n# unreadable by construction\n' > "$FX_CENSUS_UNREADABLE/unreadable-spec.sh"
chmod 000 "$FX_CENSUS_UNREADABLE/unreadable-spec.sh"
CENSUS_UNREADABLE_OUT=$(census_fixed_tmp_redirects "$FX_CENSUS_UNREADABLE" 2>"$WORK/census-unreadable.stderr")
CENSUS_UNREADABLE_RC=$?
chmod 644 "$FX_CENSUS_UNREADABLE/unreadable-spec.sh"
assert_eq "17.23 a population with an UNREADABLE .sh file does NOT report clean (rc, not 0)" \
    "nonzero" "$([ "$CENSUS_UNREADABLE_RC" -ne 0 ] && echo nonzero || echo zero)"
assert_eq "17.24 ...specifically rc 5 (grep read error), distinct from rc 3 (nothing enumerated) and rc 4 (find itself errored)" \
    "5" "$CENSUS_UNREADABLE_RC"
assert_contains "17.25 ...and stderr names the failure as an unreadable file, not a silent clean" \
    "could not be read" "$(cat "$WORK/census-unreadable.stderr")"
assert_eq "17.26 ...and no partial output leaked despite the OTHER (readable, clean) file in the same population" \
    "" "$CENSUS_UNREADABLE_OUT"

# META-TEST: the pre-R2-F5 predicate (rc 3 on empty population only, no
# per-pass grep-exit-code check) run against the IDENTICAL unreadable-file
# population reads clean at rc 0 — the specific misbehaviour this leg fixes.
census_fixed_tmp_redirects_pre_r2f5_unreadable_check() {
    local dir="$1"
    local -a files=()
    if [ -d "$dir" ]; then
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
    fi
    if [ "${#files[@]}" -eq 0 ]; then
        return 3
    fi
    {
        grep -nHE '(>{1,2}|2>{1,2})[[:space:]]*"/tmp/[A-Za-z][A-Za-z0-9_.-]*"' "${files[@]}" 2>/dev/null
        grep -nHE '(>{1,2}|2>{1,2})[[:space:]]*/tmp/[A-Za-z]' "${files[@]}" 2>/dev/null \
            | grep -vE '/tmp/[A-Za-z0-9_.-]*"'
    }
    return 0
}
chmod 000 "$FX_CENSUS_UNREADABLE/unreadable-spec.sh"
PRE_R2F5_UNREAD_OUT=$(census_fixed_tmp_redirects_pre_r2f5_unreadable_check "$FX_CENSUS_UNREADABLE")
PRE_R2F5_UNREAD_RC=$?
chmod 644 "$FX_CENSUS_UNREADABLE/unreadable-spec.sh"
assert_eq "META 17c: the pre-R2-F5 predicate reports the SAME unreadable population as rc 0 clean (specific misbehaviour)" \
    "0" "$PRE_R2F5_UNREAD_RC"
assert_eq "META 17c: ...with empty output too — indistinguishable from a genuinely clean population" \
    "" "$PRE_R2F5_UNREAD_OUT"

# ===========================================================================
# claude-workflow-plugin-gsfd fix round 2 (R2-F5, sol-codex review), leg 3:
# `find` itself failing is now observable and acted on, not silently
# discarded by the process-substitution shape this function used to read it
# through. Forced here by removing the TOP-LEVEL directory's own execute
# bit, so `find` cannot even open it (measured directly, this box: rc=1,
# "Permission denied", zero names printed) — the most reliably portable way
# to make `find` itself fail, as opposed to a per-file permission which
# `find` can still list by name via the parent directory (leg 2 above).
# This exercises the SAME code path leg 2's own header names for a genuinely
# PARTIAL listing (some names emitted, then a failure) — that exact shape
# needs `find` to fail mid-traversal, which this repo's filesystem semantics
# do not reproduce deterministically at `-maxdepth 1` (a per-file permission
# never stops `find` from listing the file's own name; only the CONTAINING
# directory's own permissions do, and removing those empties the listing
# entirely rather than truncating it) — so this leg proves the MECHANISM
# (find's own exit status is captured and acted on at all, ahead of and
# distinctly from the empty-population check) rather than the exact
# partial-listing shape, which is the part of R2-F5's finding this fix
# closes structurally without a fully deterministic repro for the
# partial-vs-total distinction.
FX_CENSUS_NOEXEC="$WORK/tmp-census-noexec"
mkdir -p "$FX_CENSUS_NOEXEC"
printf '#!/bin/bash\n' > "$FX_CENSUS_NOEXEC/spec.sh"
chmod 000 "$FX_CENSUS_NOEXEC"
CENSUS_NOEXEC_OUT=$(census_fixed_tmp_redirects "$FX_CENSUS_NOEXEC" 2>"$WORK/census-noexec.stderr")
CENSUS_NOEXEC_RC=$?
chmod 755 "$FX_CENSUS_NOEXEC"
assert_eq "17.27 a directory find itself cannot open reports rc 4 (find errored), NOT rc 3 (find ran clean, found nothing)" \
    "4" "$CENSUS_NOEXEC_RC"
assert_contains "17.28 ...and stderr says find itself failed, not a bare 'no files found'" \
    "find exited" "$(cat "$WORK/census-noexec.stderr")"
assert_eq "17.29 ...with no output leaked" \
    "" "$CENSUS_NOEXEC_OUT"

# ===========================================================================
# 18. LEASE-HEARTBEAT IN-PROCESS: DELETED (claude-workflow-plugin-gsfd,
# operator-directed, round 6 DESIGN COLLAPSE). This section covered the
# per-runner in-process heartbeat (18.1/18.2: does the lease's mtime advance
# during one long spec; 18.3/18.4: does it persist across many short specs'
# cumulative tier time) that both run-tests.sh and component/run.sh have
# since had removed entirely — neither runner touches a lease file's mtime
# mid-tier anymore, full stop, matching tree-lease.sh's own DESIGN COLLAPSE
# header ("nothing ever auto-removes a lease on the strength of its age, so
# there is nothing left for a heartbeat to protect"). Every mutant this
# section built targeted a literal that no longer exists in either shipped
# runner: mk_hb_mut_l1/l2's `sed` over `"$((_hb_now - _hb_mtime))" -ge 30`
# and mk_hb_persist_mut's awk transform over the heartbeat's own
# `if [ -n "$LEASE_FILE" ]; then` block both match nothing post-removal, so
# every "mutant" they built was byte-identical to the shipped file (the
# non-vacuity landing guards, e.g. "META 18.1: ... EXACTLY one line
# changed", would read 0 where 2 or 9 was required). Worse, the PRIMARY legs
# (18.1/18.2/18.3/18.4 proper, not just their METAs) asserted the shipped
# runners' lease mtime DOES advance mid-tier — that is no longer true of
# EITHER runner by design, so those legs would now fail red against
# genuinely correct, intended, current behaviour. Both failure shapes are
# the "guards absent code" defect this round exists to catch (R5-F2, same
# family), the second one specifically named in this task's own R5-F5-
# adjacent sweep instruction. Deleted with the mechanism rather than
# repaired, matching tree-lease.test.sh's own precedent for the identical
# situation elsewhere in this batch.

# ===========================================================================
printf -- '\n--- 19. claude-workflow-plugin-gytz (second round): EXPECTED_SPEC_FILES replaces the hand-integer EXPECTED_SPECS entirely, so an undeclared spec fails BY NAME instead of by drift ---\n'
# ===========================================================================
# THE HOLE RECURRED WITHIN ONE BATCH: EXPECTED_SPECS went 69 -> 71 (the
# gytz R1-F2 fix) and was ALREADY stale again at 71 vs a freshly-measured 72
# before that fix's own review round finished — a sibling task's spec
# landed in the gap. A bare integer bumped by whichever agent notices last
# is not a guard, it is a race with a human in the loop; this section pins
# the REPLACEMENT, not a bigger number.
#
# TWO THINGS THIS SECTION PROVES, both requested explicitly:
#   1. An undeclared spec FAILS, NAMED (19a/19b) — the shipped, UNMODIFIED
#      runner and its REAL, current manifest, not a synthetic stand-in.
#   2. The ONE SHAPE THIS MUST NEVER TAKE — the declaration silently
#      re-deriving itself from the same scan the runner uses to discover
#      specs, which makes the floor compare a set against itself — is both
#      STATICALLY forbidden (19c, a direct assertion on the shipped text)
#      and DEMONSTRATED dangerous (19d, a mutant that takes that shape and
#      is shown to swallow the exact defect this section exists to catch).
#
# WHY A REAL-NAMED FIXTURE, not another generic stub-NNN.sh set like every
# other fixture in this file: EXPECTED_SPEC_FILES is a NAME list, not a
# count, so a fixture built from arbitrary stub names can only ever
# demonstrate "the counts differ" (every OTHER section already does this,
# by construction, since none of their fixtures share names with this
# repo's real specs) — it can never demonstrate "the diff correctly named
# ONE genuinely new file among otherwise-matching ones", which is the
# actual capability under test here and the actual failure mode QA and the
# coordinator both hit. So 19a/19b build a fixture out of THIS repo's own
# L1_REAL_SPEC_NAMES (read once, above, from the shipped runner's own
# array) — trivial stub CONTENT, real NAMES — and run the genuinely
# unmodified $L1_RUNNER against it. No mutant is needed for this half: the
# code path under test is 100% shipped, unedited; only the fixture (data)
# varies, exactly like 13b/13j/13k already vary fixture data against the
# unmodified runner elsewhere in this file.
mk_l1_fixture_named() {
    # mk_l1_fixture_named <root> <name...> — like mk_l1_fixture, but named
    # after real spec basenames instead of stub-NNN.sh, so a run against
    # this fixture can be compared to EXPECTED_SPEC_FILES meaningfully.
    local root="$1"; shift
    mkdir -p "$root/.claude/scripts/tests"
    local n
    for n in "$@"; do
        printf '#!/bin/bash\nprintf "  PASS: %s ran\\n"\nexit 0\n' "$n" \
            > "$root/.claude/scripts/tests/$n"
    done
}

FX_MANIFEST="$WORK/expected-spec-files-manifest"
mk_l1_fixture_named "$FX_MANIFEST" "${L1_REAL_SPEC_NAMES[@]}"

# -----------------------------------------------------------------
printf -- '\n--- 19a. RESTORE CONTROL: a fixture matching the REAL manifest exactly is HELD, by the shipped, unmodified runner ---\n'
# -----------------------------------------------------------------
EXPECTED_SPEC_FILES_STRICT=1 run_l1 "$FX_MANIFEST"
assert_eq "19a.1 the shipped runner over an exact-manifest fixture exits 0" "0" "$RUN_RC"
assert_contains "19a.2 ...and the floor reads HELD" \
    "Completeness floor: HELD" "$RUN_OUT"
assert_absent "19a.3 ...with no breach text anywhere (the correctly-declared control the pairing requirement asks for)" \
    "COMPLETENESS FLOOR BREACH" "$RUN_OUT"

# -----------------------------------------------------------------
printf -- '\n--- 19b. PAIRING: ONE undeclared spec added to that SAME fixture FAILS, and the failure NAMES it ---\n'
# -----------------------------------------------------------------
cat > "$FX_MANIFEST/.claude/scripts/tests/zz-manifest-undeclared-probe.test.sh" <<'EOF'
#!/bin/bash
printf '  PASS: undeclared probe ran\n'
exit 0
EOF
EXPECTED_SPEC_FILES_STRICT=1 run_l1 "$FX_MANIFEST"
assert_eq "19b.1 SPECIFIC: the SAME shipped, unmutated runner now exits non-zero (rc=1, the completeness-floor breach path) over the identical fixture plus one undeclared file" \
    "1" "$RUN_RC"
assert_contains "19b.2 ...the breach line names the counts (73 discovered vs 72 declared, or whatever the manifest measures at the moment this runs)" \
    "COMPLETENESS FLOOR BREACH" "$RUN_OUT"
assert_contains "19b.3 ...and, this is the actual point of this leg, NAMES THE SPEC ITSELF, not just a number" \
    "zz-manifest-undeclared-probe.test.sh" "$(printf '%s\n' "$RUN_OUT" | grep -A5 'DISCOVERED but NOT in EXPECTED_SPEC_FILES')"
assert_contains "19b.4 ...under a heading that says what to do about it" \
    "DISCOVERED but NOT in EXPECTED_SPEC_FILES" "$RUN_OUT"
assert_absent "19b.5 ...and does NOT claim a spec is missing (only added, nothing removed, in this fixture)" \
    "in EXPECTED_SPEC_FILES but NOT discovered" "$RUN_OUT"

# -----------------------------------------------------------------
printf -- '\n--- 19c. STATIC GUARD: the shipped array is a pure literal — it must never compute itself from the same scan the runner uses to discover specs ---\n'
# -----------------------------------------------------------------
# Direct assertion on the SHIPPED text, not a mutant: this is the standing
# regression guard for "what must not happen", checked every time this
# spec runs, not only when someone happens to write the dangerous mutant in
# 19d. A pure literal contains none of these; a self-deriving version
# necessarily contains at least one.
ARRAY_BLOCK=$(sed -n '/^EXPECTED_SPEC_FILES=($/,/^)$/p' "$L1_RUNNER")
assert_eq "19c.1 the array block was actually captured (otherwise this leg is vacuous)" \
    "yes" "$([ -n "$ARRAY_BLOCK" ] && echo yes || echo no)"
# shellcheck disable=SC2016  # single-quoted on purpose: a literal grep
# pattern for '$(', not a variable expansion.
assert_eq "19c.2 no command substitution (\$() anywhere inside the declaration" \
    "0" "$(printf '%s' "$ARRAY_BLOCK" | grep -c '\$(')"
assert_eq "19c.3 no backtick command substitution either" \
    "0" "$(printf '%s' "$ARRAY_BLOCK" | grep -c '`')"
assert_eq "19c.4 no reference to \$TESTS_DIR (the live discovery directory) inside the declaration" \
    "0" "$(printf '%s' "$ARRAY_BLOCK" | grep -c 'TESTS_DIR')"
assert_eq "19c.5 no reference to \$PROJECT_DIR either" \
    "0" "$(printf '%s' "$ARRAY_BLOCK" | grep -c 'PROJECT_DIR')"
assert_eq "19c.6 no call to find(1) inside the declaration" \
    "0" "$(printf '%s' "$ARRAY_BLOCK" | grep -c 'find ')"

# -----------------------------------------------------------------
printf -- '\n--- 19d. META-TEST: a mutant that DOES self-derive the declaration from the discovery scan is shown to swallow an undeclared spec silently ---\n'
# -----------------------------------------------------------------
# THE DANGER 19c FORBIDS, SHOWN RATHER THAN ONLY STATED. If
# EXPECTED_SPEC_FILES were ever computed from the same $TESTS_DIR scan the
# TESTS array already uses, the floor would compare a set against itself —
# tautologically equal for ANY set, including one with an undeclared spec
# freshly added, which is exactly the vacuity this whole mechanism exists
# to eliminate.
BEGIN_LN=$(grep -n 'EXPECTED-SPEC-FILES-BEGIN' "$L1_RUNNER" | head -1 | cut -d: -f1)
END_LN=$(grep -n 'EXPECTED-SPEC-FILES-END' "$L1_RUNNER" | head -1 | cut -d: -f1)
assert_eq "19d.pre both sentinel line numbers were found (otherwise the splice below is vacuous)" \
    "yes" "$([ -n "$BEGIN_LN" ] && [ -n "$END_LN" ] && echo yes || echo no)"
MUT_SELFDERIVE="$WORK/run-tests.selfderive-expected.sh"
{
    sed -n "1,${BEGIN_LN}p" "$L1_RUNNER"
    cat <<'INJECT'
EXPECTED_SPEC_FILES=()
while IFS= read -r __self_derived_f; do
    EXPECTED_SPEC_FILES+=("$__self_derived_f")
done < <(find "$TESTS_DIR" -maxdepth 1 -type f -name '*.sh' ! -name 'run-tests.sh' -exec basename {} \; | sort)
INJECT
    sed -n "${END_LN},\$p" "$L1_RUNNER"
} > "$MUT_SELFDERIVE"
assert_eq "19d.1 MUTANT non-vacuity: the mutant differs from the shipped runner (the declaration was replaced)" \
    "differs" "$(cmp -s "$L1_RUNNER" "$MUT_SELFDERIVE" && echo identical || echo differs)"
assert_eq "19d.2 MUTANT: still parses (bash -n)" \
    "0" "$(bash -n "$MUT_SELFDERIVE" 2>/dev/null; echo $?)"

FX_VACUOUS="$WORK/expected-spec-files-vacuous"
mk_l1_fixture "$FX_VACUOUS" 3
run_l1 "$FX_VACUOUS" "$MUT_SELFDERIVE"
assert_eq "19d.3 precondition: the self-deriving mutant still exits 0 over an HONESTLY-matching 3-spec fixture (it has to agree with itself by construction — establishing this ISN'T already broken some other way before trusting 19d.4)" \
    "0" "$RUN_RC"
# Now add a fourth, undeclared-by-a-human spec and re-run the SAME mutant.
cat > "$FX_VACUOUS/.claude/scripts/tests/zz-vacuous-undeclared.sh" <<'EOF'
#!/bin/bash
printf '  PASS: vacuous-fixture undeclared spec ran\n'
exit 0
EOF
run_l1 "$FX_VACUOUS" "$MUT_SELFDERIVE"
assert_eq "19d.4 SPECIFIC MISBEHAVIOUR: the self-deriving mutant STILL exits 0 with a 4th, genuinely undeclared spec added — the floor cannot tell the difference, because its own declaration re-scanned the same directory and grew to match" \
    "0" "$RUN_RC"
assert_contains "19d.5 ...and reports the floor HELD, not breached — the exact silent vacuity this section exists to prevent" \
    "Completeness floor: HELD" "$RUN_OUT"
assert_absent "19d.6 ...with NO breach text anywhere, over a fixture that a correctly-declared (real, static) manifest would have caught" \
    "COMPLETENESS FLOOR BREACH" "$RUN_OUT"

# EXECUTION (the discriminator): the SAME 4-spec fixture, the SHIPPED
# (unmutated, statically-declared) runner — it cannot agree with a
# directory it never scans as its declaration, so it catches what the
# mutant above missed. (This uses stub-shaped names, not the real
# manifest, so it is expected to ALSO report the pre-existing count
# mismatch against the real 72; the point of this leg is narrower than
# 19b's: proving the self-derivation shape specifically is what went
# missing in the mutant, not re-proving 19b's naming behaviour again.)
run_l1 "$FX_VACUOUS"
assert_eq "19d.7 EXECUTION: the shipped, statically-declared runner exits non-zero over the SAME fixture the self-deriving mutant passed at 19d.4" \
    "1" "$RUN_RC"
assert_contains "19d.8 ...via the ordinary completeness floor, not a crash or an unrelated error" \
    "COMPLETENESS FLOOR BREACH" "$RUN_OUT"

# -----------------------------------------------------------------
printf -- '\n--- 19e. claude-workflow-plugin-gytz R2-F2: EQUAL CARDINALITY, DIFFERENT SET (the rename shape) is caught, not silently HELD ---\n'
# -----------------------------------------------------------------
# QA's own counterexample: declare {001,002,003}, discover {001,002,zz}. A
# cardinality-first gate (the ORIGINAL shape of this floor, before this
# leg) never even COMPUTES the set diff in this case, because the branch
# that computes it only ran after $TOTAL disagreed with $EXPECTED_SPECS —
# and here they agree (3 == 3). A file RENAME is exactly this: one name
# leaves, a different one arrives, the count never moves. Built with a
# SMALL, 3-name mutant declaration (not the real 72-entry manifest) so the
# fixture stays lightweight and the ONLY variable under test is the
# same-cardinality-different-set shape itself.
MUT_3NAME="$WORK/run-tests.3name-declared.sh"
BEGIN_LN_3=$(grep -n 'EXPECTED-SPEC-FILES-BEGIN' "$L1_RUNNER" | head -1 | cut -d: -f1)
END_LN_3=$(grep -n 'EXPECTED-SPEC-FILES-END' "$L1_RUNNER" | head -1 | cut -d: -f1)
assert_eq "19e.pre both sentinel line numbers were found (otherwise the splice below is vacuous)" \
    "yes" "$([ -n "$BEGIN_LN_3" ] && [ -n "$END_LN_3" ] && echo yes || echo no)"
{
    sed -n "1,${BEGIN_LN_3}p" "$L1_RUNNER"
    cat <<'INJECT3'
EXPECTED_SPEC_FILES=(
    rename-alpha.test.sh
    rename-beta.test.sh
    rename-gamma.test.sh
)
INJECT3
    sed -n "${END_LN_3},\$p" "$L1_RUNNER"
} > "$MUT_3NAME"
assert_eq "19e.1 fixture-sizing mutant non-vacuity: differs from the shipped runner" \
    "differs" "$(cmp -s "$L1_RUNNER" "$MUT_3NAME" && echo identical || echo differs)"
assert_eq "19e.2 fixture-sizing mutant: still parses (bash -n)" \
    "0" "$(bash -n "$MUT_3NAME" 2>/dev/null; echo $?)"

FX_RENAME="$WORK/expected-spec-files-rename"
mkdir -p "$FX_RENAME/.claude/scripts/tests"
for n in rename-alpha.test.sh rename-beta.test.sh; do
    printf '#!/bin/bash\nprintf "  PASS: %s ran\\n"\nexit 0\n' "$n" > "$FX_RENAME/.claude/scripts/tests/$n"
done
# rename-gamma.test.sh never lands; rename-delta.test.sh arrives instead —
# EQUAL cardinality (3 declared, 3 discovered), DIFFERENT set.
cat > "$FX_RENAME/.claude/scripts/tests/rename-delta.test.sh" <<'EOF'
#!/bin/bash
printf '  PASS: renamed-in spec ran\n'
exit 0
EOF
EXPECTED_SPEC_FILES_STRICT=1 run_l1 "$FX_RENAME" "$MUT_3NAME"
assert_eq "19e.3 SPECIFIC: the count-sized-correctly-but-renamed fixture still exits non-zero (the shape a cardinality-only floor would have missed)" \
    "1" "$RUN_RC"
assert_contains "19e.4 ...the breach line explicitly says counts MATCH but sets do NOT (not a fabricated count disagreement)" \
    "COUNTS MATCH but the SETS DO NOT" "$RUN_OUT"
assert_contains "19e.5 ...names the file that ARRIVED" \
    "rename-delta.test.sh" "$(printf '%s\n' "$RUN_OUT" | grep -A3 'DISCOVERED but NOT in EXPECTED_SPEC_FILES')"
assert_contains "19e.6 ...and names the file that LEFT, in the same verdict" \
    "rename-gamma.test.sh" "$(printf '%s\n' "$RUN_OUT" | grep -A3 'in EXPECTED_SPEC_FILES but NOT discovered')"

# -----------------------------------------------------------------
printf -- '\n--- 19e (continued). claude-workflow-plugin-gytz: the EXPECTED_SPEC_FILES_STRICT escape hatch discovered fixing R2-F2 is itself proven, not merely asserted to be harmless ---\n'
# -----------------------------------------------------------------
# R2-F2's fix (making the identity comparison above unconditional) broke
# ~30 of this file's OWN pre-existing sections, which build fixtures via
# mk_l1_fixture using generic, count-sized stub-NNN.sh names to test
# UNRELATED runner mechanics. run_l1 now defaults EXPECTED_SPEC_FILES_STRICT
# to 0 (legacy, count-only) for exactly that reason — see run_l1's own
# header. The three legs below are the pairing requirement for THAT fix,
# reusing 19e's own fixture and mutant so no new setup is needed:
#   - RESTORE CONTROL: the DEFAULT (nothing in the environment at all,
#     which is the only state a real invocation can ever be in) still
#     catches the SAME rename 19e.3-19e.6 just proved the strict path
#     catches — proving the escape hatch cannot be reached by accident.
#   - NON-VACUITY + SPECIFIC MISBEHAVIOUR: EXPECTED_SPEC_FILES_STRICT=0
#     (exactly what run_l1 now defaults every OTHER section in this file
#     to) silently re-opens the identical hole over the identical fixture
#     — proving the toggle is real and load-bearing, not a name nothing
#     reads.
RUN_OUT=$(env -u EXPECTED_SPEC_FILES_STRICT CLAUDE_PROJECT_DIR="$FX_RENAME" STRICT_SECTIONS=0 bash "$MUT_3NAME" 2>&1)
RUN_RC=$?
assert_eq "19e.7 RESTORE CONTROL: with EXPECTED_SPEC_FILES_STRICT completely UNSET (what every real invocation gets — run_l1 itself always sets SOME value, so this bypasses run_l1 to prove the true default), the rename is still caught" \
    "1" "$RUN_RC"
assert_contains "19e.8 ...via the same strict/default path, same message as 19e.4" \
    "COUNTS MATCH but the SETS DO NOT" "$RUN_OUT"

EXPECTED_SPEC_FILES_STRICT=0 run_l1 "$FX_RENAME" "$MUT_3NAME"
assert_eq "19e.9 NON-VACUITY/MISBEHAVIOUR: EXPECTED_SPEC_FILES_STRICT=0 (legacy count-only — run_l1's own default for every OTHER section in this file) reopens the exact R2-F2 hole on the SAME fixture and mutant: same cardinality, one file renamed, now HELD not BREACHED" \
    "0" "$RUN_RC"
assert_contains "19e.10 ...the floor claims HELD (the pre-R2-F2 deception QA's counterexample described)" \
    "Completeness floor: HELD" "$RUN_OUT"
assert_absent "19e.11 ...with no breach text anywhere — the identical fixture 19e.3 caught, silently passed" \
    "COMPLETENESS FLOOR BREACH" "$RUN_OUT"

# ===========================================================================
printf -- '\n--- 19f. claude-workflow-plugin-gytz R3-F2: LEGACY MODE names when it let a set mismatch through, never when it did not ---\n'
# ===========================================================================
# ANNOUNCE WHEN THE WEAKER MODE LETS SOMETHING THROUGH -- the same
# convention STRICT_SECTIONS already follows for a skipped section (named
# in the completeness line regardless of STRICT_SECTIONS_ON; that flag only
# decides whether it fails the run). 19f.b/19f.c reuse FX_RENAME/MUT_3NAME
# (19e's rename-shaped mismatch, built once at 4057-4064 and never mutated
# afterward — safe to reuse). 19f.a needs its OWN fixture rather than
# reusing FX_MANIFEST: 19b permanently added
# zz-manifest-undeclared-probe.test.sh to it, so by this point in the file
# FX_MANIFEST is 73 files against 72 declared and would breach under EITHER
# mode (a genuine count mismatch, not the identity-only gap this leg needs
# to isolate) — reusing it here would make 19f.a wrong, not merely
# redundant.
FX_LEGACY_HELD="$WORK/r3f2-legacy-exact-match"
mk_l1_fixture_named "$FX_LEGACY_HELD" "${L1_REAL_SPEC_NAMES[@]}"

# -----------------------------------------------------------------
printf -- '\n--- 19f.a RESTORE CONTROL: legacy mode over a fixture that GENUINELY matches carries no caveat ---\n'
# -----------------------------------------------------------------
EXPECTED_SPEC_FILES_STRICT=0 run_l1 "$FX_LEGACY_HELD"
assert_eq "19f.a1 legacy mode over an exact-match fixture still exits 0" "0" "$RUN_RC"
assert_contains "19f.a2 ...and the floor reads HELD" "Completeness floor: HELD" "$RUN_OUT"
assert_absent "19f.a3 ...with NO legacy-mode caveat (nothing was let through — byte-identical to strict on a clean run, the same property STRICT_SECTIONS has)" \
    "LEGACY MODE" "$RUN_OUT"

# -----------------------------------------------------------------
printf -- '\n--- 19f.b NON-VACUITY + SPECIFIC MISBEHAVIOUR: legacy mode over the SAME rename fixture 19e proved strict mode catches now carries the caveat, named ---\n'
# -----------------------------------------------------------------
EXPECTED_SPEC_FILES_STRICT=0 run_l1 "$FX_RENAME" "$MUT_3NAME"
assert_eq "19f.b1 legacy mode over the rename-shaped fixture exits 0 (HELD, not breached — this is the R2-F2 shape legacy mode is DESIGNED to tolerate)" \
    "0" "$RUN_RC"
assert_contains "19f.b2 ...the floor still reads HELD" "Completeness floor: HELD" "$RUN_OUT"
assert_contains "19f.b3 ...but now NAMES that legacy mode is why, not silent" \
    "LEGACY MODE (EXPECTED_SPEC_FILES_STRICT=0)" "$RUN_OUT"
assert_contains "19f.b4 ...specifically saying identity was not checked" \
    "spec-set IDENTITY was not" "$RUN_OUT"
assert_contains "19f.b5 ...and that it does not actually match" \
    "does not actually match EXPECTED_SPEC_FILES" "$RUN_OUT"

# -----------------------------------------------------------------
printf -- '\n--- 19f.c EXECUTION (the discriminator): strict mode over the SAME fixture never reaches HELD at all -- the caveat cannot fire where the breach already did ---\n'
# -----------------------------------------------------------------
EXPECTED_SPEC_FILES_STRICT=1 run_l1 "$FX_RENAME" "$MUT_3NAME"
assert_eq "19f.c1 EXECUTION: strict mode over the identical fixture breaches instead (rc=1, matching 19e.3)" \
    "1" "$RUN_RC"
assert_absent "19f.c2 ...never HELD" "Completeness floor: HELD" "$RUN_OUT"
assert_absent "19f.c3 ...and therefore never carries the legacy-mode caveat either — HELD and a mismatch cannot coexist under strict mode by construction" \
    "LEGACY MODE" "$RUN_OUT"

# --- SECTION 20 (arm-time actor-marker self-check tests): REMOVED ----------
# --- (claude-workflow-plugin-gytz waiver ruling; see the same tombstone ----
# --- above section 13's former 13g-13p/13j/13k for the full account). ------
# verify_actor_marker_took_effect() and the ARMED/ATTRIBUTION-DISABLED
# three-state wording it fed no longer exist in run-tests.sh — the canary
# is now ARMED or DISARMED, full stop. Nothing here to test.

# ===========================================================================
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

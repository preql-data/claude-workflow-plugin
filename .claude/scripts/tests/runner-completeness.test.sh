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

# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    [ -n "$DECOY_PID" ] && kill "$DECOY_PID" 2>/dev/null
    [ -n "$DECOY_PID_L2" ] && kill "$DECOY_PID_L2" 2>/dev/null
    [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

# The floor constant, read out of the shipped runner to PARAMETERISE the
# fixtures below (this is sizing, not proof — the proof legs all RUN the
# runner). If the constant moves, the fixtures move with it.
EXPECTED=$(sed -nE 's/^EXPECTED_SPECS=([0-9]+)$/\1/p' "$L1_RUNNER" | head -1)
if ! printf '%s' "$EXPECTED" | grep -qE '^[0-9]+$' || [ "$EXPECTED" -lt 2 ]; then
    printf 'FAIL: could not read EXPECTED_SPECS from %s (got "%s")\n' "$L1_RUNNER" "$EXPECTED"
    exit 1
fi

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

#!/bin/bash
# run-tests.sh — entry point for the plugin's local test suite.
#
# Each test file under this directory is a self-contained bash script. We
# invoke them sequentially, classify each into ONE of THREE OUTCOMES, and
# aggregate the verdict under a tier completeness floor:
#
#   PASSED  — exited 0 AND emitted at least one assertion line
#             (`PASS:`/`FAIL:`, the tier-wide convention every spec and the
#             CI META tally already use).
#   FAILED  — exited non-zero, OR was killed by the per-spec wall-clock cap,
#             OR returned while background work from its own process group was
#             still alive (a9hh R2-F2 — see the survivor sweep below: a spec
#             that exits before its work finishes can emit outcomes AFTER
#             classification, so nothing it printed can be read as complete),
#             OR exited 0 with a FAIL: line in its own transcript (a9hh
#             R4-F2 — a backgrounded assertion that fails inside the sweep's
#             grace window, or a spec whose exit-code plumbing is broken,
#             used to be PASSED over its own printed failure; see the
#             TRANSCRIPT-FAIL arm below).
#             A timeout is a FAILURE with a distinct reason — never a pass,
#             never a skip (claude-workflow-plugin-mwrb: a hung spec used to
#             stall the tier forever, and a tier that never finishes emits no
#             completeness line at all, which is the one state "read the
#             completeness line" cannot answer).
#   SKIPPED — exited 0 having executed ZERO assertions. A skip is a THIRD
#             OUTCOME and is never a pass (claude-workflow-plugin-a9hh: under
#             BD_SHIM_ONLY=1 CI, six specs exited 0 having run nothing, the
#             runner scored exit status alone, and the completeness line was
#             byte-identical to a full run — 286 of 2461 assertions, 11.6% of
#             the tier, green without ever executing).
#
# Three outcomes, three reasons: a skip must not be a pass, and a timeout
# must not be a skip.
#
# ...and ONE annotation, because those three are SPEC-GRANULAR:
#
#   PARTIAL — a PASSED spec that also printed a section-level skip marker, so
#             it measured only part of itself. This is not a fourth outcome
#             (the spec did run, and did pass what it ran); it is the
#             qualification the completeness line needs in order to be true.
#             a9hh round 1 shipped a fix whose own new claim — `36/36 specs
#             discovered and executed`, Skipped: 0, rc=0 — covered 15
#             unexecuted assertions, because impact-report.test.sh skipped
#             section 4 (the LIVE code-graph legs) when CI did not install
#             code-graph-mcp's node_modules. The runner could not see it: a
#             skipped SECTION moved no counter. Now it moves this one, it is
#             named in the completeness line, and under STRICT_SECTIONS=1 it
#             is red.
#
# Usage:
#   bash .claude/scripts/tests/run-tests.sh
#   bash .claude/scripts/tests/run-tests.sh --filter <pattern>   # subset run
#
# Environment:
#   SPEC_TIMEOUT_S — per-spec wall-clock cap in seconds (default 900). There
#             is deliberately no "0 disables it" arm: an unbounded spec is the
#             mwrb defect, not a configuration. macOS has no `timeout(1)`, so
#             the cap is a shell watchdog (poll + kill the spec's process
#             tree). Raise it when measuring under known contention (mrd2).
#   STRICT_SECTIONS — 1 makes a PARTIAL spec fail the tier. Set by the CI
#             l1-unit job, which provisions every prerequisite the tier's
#             section arms name (bd, node, both MCP servers' node_modules),
#             so a section skip THERE means a provisioning step was dropped
#             or a new arm was added without one. Unset by default because a
#             dev machine legitimately lacks some of them, and a control that
#             cries wolf is a control people stop reading. Accepted values:
#             1/yes/true and 0/no/false/unset; anything else is an invocation
#             error rather than a silent "off" (a strictness flag that fails
#             open is the a9hh defect wearing a different hat).
#
# STDIN: every spec is launched with its stdin EXPLICITLY redirected from
# /dev/null at the spawn site (a9hh R3-F2). This cannot be left to the POSIX
# async-command default, because `set -m` INVERTS it: bash redirects a
# background job's stdin to /dev/null only when job control is OFF — with it
# ON the job INHERITS the runner's stdin. Measured, both halves: a
# backgrounded `read` under set -m consumed a sentinel piped to this runner
# (under set +m it saw EOF), and under a terminal a spec that reads the
# inherited tty is stopped by SIGTTIN — state T at 8/8 samples, which
# `kill -0` reads as alive, so the watchdog burned the full per-spec cap and
# reported TIMEOUT over a spec that was not running (the mwrb wedge in a new
# coat). The explicit redirect restores the promise this paragraph makes: a
# future spec that expects an interactive stdin sees EOF at once — not a
# prompt, and not a stop. No spec reads stdin today;
# installer-flags.test.sh already redirects `</dev/null` at its own call
# sites. Paired control: runner-completeness.test.sh section 11 pipes a
# sentinel into this runner and fails if a spec can read it.
#
# PROCESS GROUPS: `set -m` below puts every spec (and the watchdog) in its OWN
# process group, pgid == the spec's pid (a9hh R2-F2/R2-F3). Two things need
# that kernel-maintained set: the watchdog's KILL escalation must reach a
# TERM-immune descendant (`trap '' TERM` survives the recursive TERM, and a
# KILL aimed only at the — already dead — top-level pid never reaches it), and
# the post-wait survivor sweep must be able to ask "did this spec leave
# anything running?" after the leader is gone, when a ppid walk from the dead
# leader finds nothing. Known limit, stated rather than hidden: a descendant
# that BOTH leaves the group (setsid) AND outlives its parent chain is
# invisible to the sweep and unreachable by the group kill — a double-forking
# daemon is out of any supervisor's reach short of a machine-global scan,
# which is exactly the kind of probe R1-F2 banned. bd's own daemon does this
# (setsid: pgid=self, ppid=1 — measured; out of the group, invisible here,
# shared machine infrastructure rather than a spec's leak). bd's TELEMETRY
# FLUSHER does NOT (a9hh R3-F1): `bd send-metrics` detaches to ppid=1 but
# KEEPS THE CALLER'S pgid — 61/61 in-group across QA's 25-minute census,
# 3/3 and 2-of-5 tier runs alive at sweep poll 0 here — so it lands inside
# the spec's group with a lifetime that crosses the sweep's grace whenever
# the endpoint is slow (reproduced through this runner: 10/10 sweep firings
# with the endpoint blackholed, 0/25 idle; QA saw 4/25 under load). The fix
# is the TELEMETRY-DISARM export below, which prevents the spawn at the
# source. An argv-pattern exemption in the sweep was REJECTED: argv is
# forgeable (`exec -a 'bd send-metrics'` would hide exactly the leak the
# sweep exists to catch), and excluding ppid==1 would delete the R2-F2
# detection outright — an escaped child is reparented to 1 the moment its
# spec exits.
#
# Side effects of set -m: a job reaped by a targeted `wait` right after its
# kill produces no notice; a job that dies while the runner is between
# commands MAY print a `[1]+ Done ...` line to the runner's stderr. That
# noise lands in the tier log only — spec output is captured by redirection
# at spawn, so no notice can reach a spec's classification. PROVENANCE, not
# assumption (R5-F3 — an earlier draft of this sentence claimed a Linux
# measurement nobody had taken): measured on macOS bash 3.2.57 (dev box,
# a9hh R2/R3 rounds) and on Linux bash 5.2.21 (ubuntu:24.04 container,
# 2026-08-10, this runner over a 36-spec fixture:
#   grep -cE '^\[[0-9]+\]' <tier-log>  ->  0 lines across 5 full tier runs;
# QA's independent bash 5.2.21 run also measured 0 across a full tier).
# Interactive ^C now needs forwarding (each spec group no longer shares the
# terminal's foreground group), hence the INT/TERM trap.
#
# Exit codes:
#   0 — every selected spec ran to completion and passed, and (on unfiltered
#       runs) the completeness floor held
#   1 — at least one spec failed, timed out, or skipped; the floor breached;
#       or (under STRICT_SECTIONS=1) a spec skipped a section
#   2 — invocation error (no tests found, filter matched nothing, missing jq,
#       unparseable SPEC_TIMEOUT_S or STRICT_SECTIONS)

set -u
# Job control ON: every background job — each spec, each watchdog — becomes
# its own process group. See the PROCESS GROUPS header note for why this is
# load-bearing (a9hh R2-F2/R2-F3) and what it costs.
set -m

# --- TELEMETRY-DISARM-BEGIN (a9hh R3-F1) ------------------------------------
# bd spawns a telemetry flusher (`bd send-metrics`) from ANY bd command when
# metrics are enabled, detached to ppid=1 WITHOUT setsid — it stays in the
# spec's process group, and when the metrics endpoint is slow it outlives the
# survivor sweep's grace, so the sweep kills the SPEC for a process it never
# started with &, cannot wait for, and cannot see. Fresh-HOME fixtures
# (qa-gate-grade-record, qa-gate-choose, phase5-synthetic-tests) re-enable
# metrics implicitly: a HOME with no ~/.config/bd defaults to ON — measured
# on bd 1.1.2, the version CI pins, where the exposure is WORST (fresh
# runner, no config, GitHub-to-endpoint latency). BD_DISABLE_METRICS=1
# prevents the SPAWN, not just the send (measured: 3/3 in-group flushers
# without it, 0/3 with it, same fixture), and as an exported variable it
# rides through any HOME a spec swaps in. Paired control:
# runner-completeness.test.sh section 10 drives a fixture spec through this
# runner that FAILS when this export is excised, and verifies the installed
# bd still honors the variable (so a bd that renames it goes red here, not
# in a 1-in-6 CI flake).
export BD_DISABLE_METRICS=1
# --- TELEMETRY-DISARM-END (a9hh R3-F1) ---------------------------------------

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
TESTS_DIR="$PROJECT_DIR/.claude/scripts/tests"

# ---------------------------------------------------------------------------
# THE TIER COMPLETENESS FLOOR — the expected size of the discovered spec set.
#
# THIS IS THE NEGATIVE CONTROL FOR THE COMPLETENESS LINE, and it is the
# pairing convention's first application (.claude/tests/README.md, "The
# pairing requirement — a new check ships with its negative control"). The
# summary this runner prints — `Total: N  Passed: N  Failed: 0` — is a CLAIM,
# and until a9hh nothing could make that claim fail while it was false:
# delete 20 of the spec files and the line read `Total: 16  Passed: 16
# Failed: 0` with exit 0, because the runner failed only on an EMPTY
# discovered set; skip a spec to exit 0 and it was counted PASSED. The floor
# is exactly the control the convention demands of every other check, applied
# to the instrument the whole tier is read through: a mutation of the world
# (a shrunken spec set, an unexecuted spec) must make the claim FAIL in the
# specific way it was previously false.
#
# When you add or remove a spec file, update EXPECTED_SPECS in the SAME
# change — the breach message below names this line on purpose. That touch is
# the tripwire working, not overhead: a spec-count move nobody meant is a
# coverage move nobody reviewed. (Same pattern as EXPECTED_ASSERTIONS=29 in
# evidence-before-fix.test.sh, one level up.)
#
# The floor is enforced only on UNFILTERED runs: --filter deliberately
# selects a subset, so the runner says the floor is disarmed rather than
# pretending the subset describes the tier. Skips still fail filtered runs —
# exit 0 always means "everything selected ran and passed".
# ---------------------------------------------------------------------------
EXPECTED_SPECS=37

# Per-spec wall-clock cap (seconds). HEADROOM IS 3.7x, NOT 5x. The earlier
# "~5x" here was sized against an idle-machine figure (review-separation 183s)
# that does not bound anything: a cap is only ever tested under load, and
# under load the same specs run half again as long.
#
# Measured across four full CI-shaped runs of this tier at 535c89a + this
# change set, on the same dev box, with this command over each run's log:
#   $ grep -oE '^--- [a-z0-9.-]+\.sh: PASSED[^(]*\([0-9]+ assertion\(s\) in [0-9]+s\)' <log> \
#       | sed -E 's/^--- ([^:]+).*in ([0-9]+)s\)/\2 \1/' | sort -rn | head -3
# Worst observed, in QA's independent run under heavy contention:
#   qa-gate-grade-record.test.sh 243s, review-separation.test.sh 228s,
#   qa-gate-choose.test.sh 120s. My own three runs, lighter load, peaked at
#   186s (review-separation); everything outside that top three is under 90s.
# 900/243 = 3.7x against the worst figure anyone has measured here.
#
# Deliberately NOT raised to restore a round multiple. ubuntu-latest is
# typically slower than this box, so the real CI margin is smaller again, and
# the number that matters is "comfortably above the slowest legitimate spec
# under contention", not the ratio. Only a genuine hang or severe
# environmental degradation (mwrb: five stale bd daemons made every bd call
# take >1s) should reach it — if a real spec ever does, raise this and say
# what you measured, do not delete the cap.
SPEC_TIMEOUT_S="${SPEC_TIMEOUT_S:-900}"
case "$SPEC_TIMEOUT_S" in
    ''|*[!0-9]*)
        printf 'run-tests.sh: SPEC_TIMEOUT_S must be a positive integer (got %s)\n' \
            "$SPEC_TIMEOUT_S" >&2
        exit 2 ;;
    0)
        printf 'run-tests.sh: SPEC_TIMEOUT_S=0 (no cap) is not offered — an unbounded spec is the mwrb defect\n' >&2
        exit 2 ;;
esac

# ---------------------------------------------------------------------------
# SECTION-LEVEL SKIP DETECTION (a9hh R1-F1) — the floor above is SPEC-granular.
#
# A spec that runs 24 of its 39 assertions and prints `SKIPPED: section 4
# (code-graph-mcp not installed ...)` exits 0, executes assertions, and is
# PASSED — and every summary line stays green while a documented section of
# the tier never ran. That is the a9hh defect one level down, and it is how
# a9hh's own fix round shipped a green `36/36 specs discovered and executed`
# over 15 unexecuted assertions.
#
# The regex is anchored at line start (leading whitespace allowed) because
# every assertion line begins with `PASS:` or `FAIL:`, so an assertion whose
# NAME contains "skip" cannot match it — and the tier is full of those
# (workflow-doctor's whole section 4 is about `--skip`). It covers the four
# marker shapes the tier prints:
#   `SKIPPED: section 4 (...)`          impact-report.test.sh
#   `  SKIPPED: <why>`                  installer-flags, mcp-deps-preserve,
#                                       workflow-manifest section 5
#   `  SKIP: 4.53b <why>`               gate-claim-honesty
#   `  note: 6 SKIPPED - <why>`         workflow-manifest 6/META 4,
#                                       workflow-doctor 5a/META-TEST 3,4,5
#
# ANY line-initial `note:` counts, with or without a skip word on the line
# (a9hh R2-F1). The first cut of this regex required the skip word on the
# note: line itself, and enforced that convention with a static scan of the
# tier's printf/echo literals — which meant a marker built any other way (a
# heredoc, a cat of a data file, a variable) could carry the exact two-line
# shape this detector was built for (`note: section 4 needs node` / skip word
# on the NEXT line) and be invisible to BOTH layers at once: the runtime
# match wanted the word on the line, the static scan only read quoted
# literals. Detection now keys on what the spec's OUTPUT says, where every
# emission mechanism converges: line-initial `note:` is the tier's reserved
# idiom for "this leg could not be measured". That nothing else prints one
# is a MEASUREMENT, not an assumption (a9hh R3-F4): over the full 36-spec
# CI-shaped tier log at this change set,
#   grep -cE '^[[:space:]]*[Nn][Oo][Tt][Ee]:' <tier-log>   ->  0
# — judge-calibration's parenthesised `(note: ...)` and workflow-manifest's
# prose "Note also:" do not START a line with `note:`, and every `git
# checkout` in the tier is the `-q -- <path>` form, so git's detached-HEAD
# "Note: switching ..." cannot reach a spec's stdout today. The measurement
# is re-taken every round; the PROPERTIES are pinned by legs
# (runner-completeness 8.21a-8.21d): the near-miss shapes stay invisible,
# and a line-initial `Note:` that one day DOES arrive through a subprocess
# is a loud PARTIAL quoting the line — red in strict CI on the PR that
# introduces it, attributable in one read — which is the safe direction.
# The a9hh family is all silent-green defects; a noisy false PARTIAL is the
# tripwire working.
#
# IF YOU ADD A SECTION ARM, PRINT ONE OF THE FOUR SHAPES ABOVE, skip word on
# the marker line — that is still the convention runner-completeness.test.sh
# section 9 enforces (its scan now reads heredoc bodies as well as quoted
# literals), because a marker a HUMAN cannot recognise as a skip while
# reading a log is still half the bug even when the runner counts it.
SECTION_SKIP_RE='^[[:space:]]*(SKIPPED|SKIP)[[:space:]:]|^[[:space:]]*[Nn][Oo][Tt][Ee]:'

STRICT_SECTIONS_ON=0
case "${STRICT_SECTIONS:-0}" in
    1|yes|true|YES|TRUE)  STRICT_SECTIONS_ON=1 ;;
    0|no|false|NO|FALSE|'') STRICT_SECTIONS_ON=0 ;;
    *)
        printf 'run-tests.sh: STRICT_SECTIONS must be 1/yes/true or 0/no/false (got %s)\n' \
            "$STRICT_SECTIONS" >&2
        printf '  Refused rather than defaulted to off: a strictness flag that fails open is\n' >&2
        printf '  the a9hh defect wearing a different hat.\n' >&2
        exit 2 ;;
esac

FILTER=""
if [ "${1:-}" = "--filter" ] && [ -n "${2:-}" ]; then
    FILTER="$2"
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'run-tests.sh: jq is required but not on PATH\n' >&2
    exit 2
fi

# Discover tests: any *.sh under tests/ that's NOT this runner itself.
# Avoid mapfile so we work on macOS bash 3.2.
TESTS=()
while IFS= read -r line; do
    TESTS+=("$line")
done < <(find "$TESTS_DIR" -maxdepth 1 -type f -name '*.sh' \
    ! -name 'run-tests.sh' | sort)

if [ ${#TESTS[@]} -eq 0 ]; then
    printf 'run-tests.sh: no test files found in %s\n' "$TESTS_DIR" >&2
    exit 2
fi

# Scratch dir for per-spec output capture. Output is captured to a FILE, not
# a pipe: a timed-out spec can leave orphaned children holding stdout, and a
# pipe reader would block on them forever — the exact hang the cap exists to
# end. The cost is that a spec's output prints when it finishes rather than
# streaming; the `=== name ===` banner prints up front so a silent long spec
# is attributable while it runs.
#
# THERE IS DELIBERATELY NO `trap ... EXIT` IN THIS RUNNER (a9hh R5-F1).
# The scratch dir used to be removed by an EXIT trap, and on Linux bash
# 5.2.21 (ubuntu:24.04, the CI platform family) that trap NONDETERMINISTICALLY
# FIRED INSIDE FORKED CHILDREN under load — the per-spec watchdog fork
# inherits the armed trap, and bash runs the parent's EXIT trap in the child
# before/despite the documented subshell trap reset. Each misfire ran
# `rm -rf "$RUN_SCRATCH"` MID-TIER: every later spec failed rc=1 with 0
# assertions ("cat: .../spec-out.N: No such file"), and the spec whose
# window the deletion hit was SKIPPED over an unlinked output file.
# NOT reproducible on macOS bash 3.2; also seen at 1/12 from a bind-mounted
# tree and 0/30 idle. Trap-body shapes were measured as a FACTORIAL — 40
# trials per variant, 36 trivial stubs, ubuntu:24.04 bash 5.2.21 aarch64,
# `docker run --cpus=1 -e LOAD=2` — by three independent builds (QA R5/R7,
# this file's R4/R5 + R6/R7 harness, and QA R9). These are the observed
# ranges across those three builds, not bounds; the full grid and commands
# are in the a9hh Beads record. Probe labels quote their bodies because the
# same statements in a different order produce a different result:
#   `rm -rf "$RUN_SCRATCH"`                         29-35/40 trials BAD
#   `[ "${BASHPID:-$$}" = "$$" ] || return 0; [ -n "$RUN_SCRATCH" ] && rm -rf "$RUN_SCRATCH"`
#                                                   28-37/40 BAD
#   `echo "entry dollar=$$ bashpid=${BASHPID:-na}" >> /h/traplog.txt; rm -rf "$RUN_SCRATCH"`
#                                                   27-32/40 BAD — the write
#                                                   records foreign BASHPIDs
#                                                   and masks nothing alone
#   `[ "${BASHPID:-$$}" = "$$" ] || exit 0; echo "entry dollar=$$ bashpid=${BASHPID:-na}" >> /h/traplog.txt; rm -rf "$RUN_SCRATCH"`
#                                                   25-35/40 BAD (R9: 186
#                                                   firings, 146 foreign
#                                                   immediately before rm)
#   `echo "entry dollar=$$ bashpid=${BASHPID:-na}" >> /h/traplog.txt; [ "${BASHPID:-$$}" = "$$" ] || exit 0; rm -rf "$RUN_SCRATCH"`
#                                                   0/25+0/25, 0/40, 0/40;
#                                                   109 and 48 foreign firings
#                                                   entered and were stopped
#   `echo "entry dollar=$$ bashpid=${BASHPID:-na}" >> /h/traplog.txt` (rm removed)
#                                                   0/40, 0/60 — no deleter,
#                                                   no deletion: QA's "the
#                                                   deleter IS the rm" was a
#                                                   CORRECT inference
#   NO EXIT trap at all (THIS runner)               0/40 + 0/12 bind-mount +
#                                                   0/12 re-verify, across
#                                                   three independent builds
# So: an in-trap WRITE alone never masks the defect; it records it at the
# baseline rate. Masking is ORDER-dependent, not combination-dependent: the
# BASHPID guard MISEVALUATES when it is the FIRST command of the trap body,
# and evaluates correctly when the byte-identical write precedes it. The two
# order-isolation builds read 35/40 and 28/40 BAD with guard first, versus
# 0/40 with write first in each. WHY first-command evaluation differs inside a
# misfiring child is NOT isolated (a bash-5.2 fork/trap internal, still
# unexplained — but the defect CAN be instrumented: the write variants log
# every misfire). What is established: the trap machinery misfires in
# forked children, guarding it is order-sensitive in a way nobody can
# explain, and the only configuration measured clean by every build is an
# EMPTY trap-space. Cleanup happens at the explicit terminal exits below
# (`finish`), so a child that wrongly executes leftover trap machinery has
# nothing to execute. Residual cost, stated: HUP, INT and TERM are trapped
# and clean (interrupt path — HUP added in R7 after QA measured the
# untrapped runner leaking the scratch 5/5 on the close-your-terminal path,
# exit 129, finish never reached); what still leaks one /tmp dir is a
# runner aborted by `set -u` mid-script (a runner BUG) or killed with
# SIGKILL, which no process can trap — a leak beats a tier that reds
# itself.
RUN_SCRATCH=$(mktemp -d -t l1-runner.XXXXXX)

# finish <code> — the ONLY place the scratch dir is removed, and the ONLY
# way this runner exits once the scratch exists. Never called from an EXIT
# trap (see the R5-F1 note above); on_interrupt calls it LAST, after its
# guard, so the interrupt path cleans up exactly once.
finish() {
    [ -n "$RUN_SCRATCH" ] && rm -rf "$RUN_SCRATCH"
    exit "$1"
}

# tree_pids <pid> — print <pid> and every live descendant, depth-first
# (children before parent), via a ppid walk. Portable across macOS and Linux
# ps; `timeout(1)` does not exist on stock macOS, and signalling only the
# spec's top-level bash leaves the blocking child (a wedged bd call, a
# never-returning fetch) alive.
#
# This is the SNAPSHOT both kill paths (watchdog cap, interrupt) operate on:
# TERM breaks ppid chains (a dead parent reparents survivors to init), so
# the set must be collected BEFORE the polite pass, not re-walked after it.
# The TERM loop over it is the POLITE first pass — it follows live ppid
# chains, so it reaches even a descendant that moved itself out of the
# spec's process group, but TERM is a request, and a child that ignores it
# (`trap '' TERM` survives exec as SIG_IGN) walks away untouched (a9hh
# R2-F3, reproduced: the old escalation then KILLed only the already-dead
# top-level pid, and the immune child outlived the whole tier). The KILL
# escalation after the grace is the STRONG pass — group-wide AND against
# this same snapshot (a9hh R4-F4: the group KILL alone misses a descendant
# that left the group), PLUS one re-walk from every snapshot member still
# alive (a9hh R6-F1: a TERM handler can SPAWN a new child during the grace;
# it is absent from the snapshot and outside the group, but while its
# parent lives the re-walk reaches it — reproduced with a setsid shell
# whose TERM trap backgrounds a sleep). KILL cannot be refused, but the SET
# it acts on is two bounded walks, NOT a closed world: a process that both
# leaves the group and outlives its parent chain before a walk reaches it
# (a double-forked daemon; a handler that spawns and immediately exits) is
# out of reach short of the machine-global scan R1-F2 banned. So no closed
# tree is CLAIMED — after the KILL pass, whatever the escalation can still
# see alive it NAMES (`survivor:` lines, same shape as the sweep's), and an
# honest boundary beats an unbounded chase. escalate_kill() below is the
# one implementation all four kill sites share.
tree_pids() {
    local pid="$1" kids k
    kids=$(ps -axo pid,ppid 2>/dev/null | awk -v p="$pid" '$2 == p { print $1 }')
    for k in $kids; do
        tree_pids "$k"
    done
    printf '%s\n' "$pid"
}

# escalate_kill <pid> <grace_s> — the ONE kill escalation every kill site
# uses (watchdog cap and interrupt, here and mirrored at L2). Sequence:
# snapshot the ppid tree, TERM the tree politely (reaches out-of-group
# descendants on live chains), TERM the group (catches a child forked
# mid-walk), wait the grace, RE-WALK from every snapshot member still
# alive, then KILL the union and the group. The re-walk is a9hh R6-F1: a
# TERM handler can spawn a NEW child during the grace — absent from the
# snapshot, outside the group — and while its parent lives, one bounded
# re-walk reaches it. One pass, deliberately never a loop: chasing a
# process that re-spawns faster than it can be walked is unwinnable in
# bash (that needs cgroups or PID namespaces), and every round of this arc
# has shown that adding machinery to these runners is how the next finding
# gets made. Whatever is still alive and visible after the KILL pass —
# snapshot, re-walk, or group — is printed as a `survivor:` line (stdout;
# the watchdog redirects it to a file the TIMEOUT verdict surfaces): a
# named survivor beats a claimed-clean tree that is not. The pid-recycling
# exposure of killing snapshot pids is bounded exactly like the sweep's:
# every pid in the union was OUR descendant less than a grace-window ago,
# and a full pid-space wrap inside that window is not a real machine.
# name_group_members <pid-list> <pgid> — one ps line (pid ppid pgid args,
# control bytes stripped, width-cut) per LIVE, non-zombie process that is
# either in the pid list or in the group. Zombies excluded for the sweep's
# reason — dead-but-unreaped can neither write nor leak.
name_group_members() {
    ps -axo pid=,ppid=,pgid=,stat=,args= 2>/dev/null \
        | awk -v want=" $(printf '%s' "$1" | tr '\n' ' ') " -v g="$2" '
            $4 !~ /^Z/ && (index(want, " " $1 " ") > 0 || $3 == g) {
                line = $1 " " $2 " " $3
                for (i = 5; i <= NF; i++) line = line " " $i
                print line
            }' \
        | LC_ALL=C tr -c '[:print:]\n\t' '?' | cut -c1-160
}

escalate_kill() {
    local pid="$1" grace="$2" doomed rewalk p visible initial_ids refusers outsiders survivors
    doomed=$(tree_pids "$pid")
    for p in $doomed; do
        kill -TERM "$p" 2>/dev/null
    done
    kill -TERM -- "-$pid" 2>/dev/null
    sleep "$grace"
    # rewalk initialised OUTSIDE the sentinel region (sweep-state convention):
    # the excised mutant must still run under set -u, behaving exactly like
    # the single-snapshot escalation that shipped before R6-F1.
    rewalk=""
    # --- RESNAPSHOT-BEGIN (a9hh R6-F1) ---------------------------------------
    for p in $doomed; do
        if kill -0 "$p" 2>/dev/null; then
            rewalk="$rewalk
$(tree_pids "$p")"
        fi
    done
    # --- RESNAPSHOT-END (a9hh R6-F1) -----------------------------------------
    # Name the live kill set BEFORE the kill, and attribute each line only as
    # far as this function can KNOW (a9hh R8-F1). It knows exactly one thing
    # about signal delivery: which pids were in the pre-TERM snapshot, because
    # it TERMed those itself. So split one ps snapshot on that and nothing
    # else — no extra signal, sleep, or process walk.
    #   IN the snapshot  — TERMed here, still alive a full grace later:
    #     "refused TERM" is then a fact about that process, not an inference.
    #   NOT in it        — TWO populations this function cannot tell apart:
    #     a process SPAWNED during the grace and found by the re-walk (never
    #     TERMed at all — R6-F1's shape), and a group member whose ppid chain
    #     broke BEFORE the snapshot (double-forked to ppid=1, so tree_pids
    #     cannot see it, but the group TERM reached it and it refused).
    #     Both were reproduced against this escalation, so the line states
    #     MEMBERSHIP and claims no signal either way. Naming them all
    #     "refused TERM" was R8-F1 — it sent a maintainer hunting a
    #     signal-handling defect that did not exist. Naming them all
    #     "discovered after TERM pass" is the same error inverted: it denies
    #     one that does. An honest "not in the snapshot" is the widest claim
    #     the available evidence supports, and the pid/ppid/pgid/args on the
    #     line are what an operator actually chases.
    # Leg 5.9 pins the refuser arm; 12.46c and 12.47c-e pin the other one from
    # BOTH of its populations.
    visible=$(name_group_members "$doomed
$rewalk" "$pid")
    initial_ids=" $(printf '%s' "$doomed" | tr '\n' ' ') "
    refusers=$(printf '%s\n' "$visible" \
        | awk -v initial="$initial_ids" 'index(initial, " " $1 " ") > 0')
    outsiders=$(printf '%s\n' "$visible" \
        | awk -v initial="$initial_ids" 'index(initial, " " $1 " ") == 0')
    for p in $doomed $rewalk; do
        kill -KILL "$p" 2>/dev/null
    done
    kill -KILL -- "-$pid" 2>/dev/null
    sleep 0.2
    # Name what could NOT be killed: any union member (or group member)
    # still alive and not a zombie even after the KILL pass.
    survivors=$(name_group_members "$doomed
$rewalk" "$pid")
    if [ -n "$refusers" ]; then
        printf '%s\n' "$refusers" | while IFS= read -r surv_line; do
            [ -n "$surv_line" ] && printf '    refused TERM, KILLed: %s\n' "$surv_line"
        done
    fi
    if [ -n "$outsiders" ]; then
        printf '%s\n' "$outsiders" | while IFS= read -r surv_line; do
            [ -n "$surv_line" ] && printf '    not in the TERM snapshot, KILLed: %s\n' "$surv_line"
        done
    fi
    if [ -n "$survivors" ]; then
        printf '%s\n' "$survivors" | while IFS= read -r surv_line; do
            [ -n "$surv_line" ] && printf '    survivor: %s\n' "$surv_line"
        done
    fi
    return 0
}

# Interrupt forwarding: with each spec in its own process group (set -m), a
# terminal ^C, a `make` TERM, or the SIGHUP of a closed terminal reaches
# the runner alone — before set -m the whole tier shared the foreground
# group and died together. Forward through escalate_kill so an interrupted
# run does not strand a half-finished spec tree (a9hh R4-F4, reproduced on
# Linux: `setsid sleep 600 & wait` left an out-of-group descendant alive
# past the pre-fix handler's group-only signals; R6-F1, reproduced both
# platforms: a TERM handler that SPAWNS during the grace outlived the
# single-snapshot escalation). 130 is the conventional 128+SIGINT exit,
# kept for TERM and HUP as well — the exit code names "interrupted", not
# which signal. HUP is trapped for the same reason INT/TERM are (a9hh
# R7-F3): untrapped, a closed terminal killed the runner at exit 129 with
# `finish` unreached, leaking the scratch dir 5/5 measured — the one
# abnormal-exit path an ordinary user actually hits.
CURRENT_SPEC_PGID=""
# shellcheck disable=SC2329  # invoked via trap.
on_interrupt() {
    # Fork-window guard (a9hh R5-F1): bash 5.2 can run a parent's trap inside
    # a freshly forked child. For INT/TERM that misfire was never observed
    # (0 foreign firings across every instrumented Linux soak, ~250+ window
    # children), but the guard costs one test: a child that is not the main
    # shell exits without touching the spec's group or the scratch dir.
    # On bash 3.2 (macOS) BASHPID does not exist and the guard is inert by
    # construction — the misfire is a bash-5 behaviour, measured only there.
    # NOTE the R5-F1 factorial above: a guard evaluated as the FIRST command
    # misevaluated only in EXIT traps; INT/TERM/HUP traps are reset in
    # children reliably (measured, 0 foreign firings), and this guard is a
    # belt, not the mechanism.
    [ "${BASHPID:-$$}" = "$$" ] || exit 130
    if [ -n "$CURRENT_SPEC_PGID" ]; then
        escalate_kill "$CURRENT_SPEC_PGID" 1
    fi
    finish 130
}
trap on_interrupt INT TERM HUP

TOTAL=0
PASS=0
FAIL=0
SKIP=0
PARTIAL=0
TIMEOUT_COUNT=0
ASSERTS_TOTAL=0
FAILED_FILES=()
SKIPPED_FILES=()
PARTIAL_FILES=()

for test_file in "${TESTS[@]}"; do
    base=$(basename "$test_file")
    if [ -n "$FILTER" ] && ! printf '%s' "$base" | grep -q "$FILTER"; then
        continue
    fi
    TOTAL=$((TOTAL + 1))
    printf '\n=== %s ===\n' "$base"

    SPEC_OUT="$RUN_SCRATCH/spec-out.$TOTAL"
    TIMEOUT_MARKER="$RUN_SCRATCH/spec-timeout.$TOTAL"
    START_S=$(date +%s)

    # `< /dev/null` is load-bearing (a9hh R3-F2): set -m makes a background
    # job inherit the runner's stdin — see the STDIN header note.
    bash "$test_file" > "$SPEC_OUT" 2>&1 < /dev/null &
    spec_pid=$!    # == the spec's process-group id, because set -m
    CURRENT_SPEC_PGID="$spec_pid"

    # Watchdog: poll once a second so it exits promptly when the spec does;
    # at the cap, write the marker FIRST (so a kill that races spec exit is
    # still classified), then run escalate_kill (a9hh R2-F3/R4-F4/R6-F1:
    # polite tree TERM, group TERM, grace, re-walk, KILL union + group,
    # NAME survivors — full story at the function). Survivor lines land in
    # a per-spec file the TIMEOUT verdict below surfaces. The group KILL is
    # what unblocks `wait` below when the spec ITSELF traps TERM.
    WD_SURVIVORS="$RUN_SCRATCH/wd-survivors.$TOTAL"
    (
        waited=0
        while [ "$waited" -lt "$SPEC_TIMEOUT_S" ]; do
            sleep 1
            waited=$((waited + 1))
            kill -0 "$spec_pid" 2>/dev/null || exit 0
        done
        : > "$TIMEOUT_MARKER"
        escalate_kill "$spec_pid" 2 > "$WD_SURVIVORS"
    ) &
    wd_pid=$!

    wait "$spec_pid"
    rc=$?
    # a9hh R6-F1: when the cap FIRED, let the watchdog FINISH its escalation
    # before reaping it. The pre-fix runner TERMed it here unconditionally,
    # and whenever the spec's leader died at the polite TERM (the common
    # case), `wait` returned and the TERM cut the watchdog down MID-GRACE —
    # its KILL pass never ran, so a TERM-catching descendant survived the
    # entire "escalation" (reproduced: a setsid shell with a TERM trap
    # outlived the tier, along with the child its trap spawned). Only the
    # no-timeout path still TERMs the watchdog, where it is only ever
    # sleeping out its poll loop.
    if [ -f "$TIMEOUT_MARKER" ]; then
        wait "$wd_pid" 2>/dev/null
    else
        kill -TERM "$wd_pid" 2>/dev/null
        wait "$wd_pid" 2>/dev/null
    fi
    ELAPSED_S=$(( $(date +%s) - START_S ))

    # Sweep state. Initialised OUTSIDE the sentinel region on purpose: the
    # paired control (runner-completeness.test.sh) excises the region from a
    # COPY to demonstrate the pre-sweep world, and that mutant must still run
    # under `set -u` — with the sweep gone these stay 0/empty and the runner
    # behaves exactly like the runner that shipped the R2-F2 false green.
    SURVIVOR_COUNT=0
    SURVIVOR_IDS=""
    LEAK_NOTE=""
    # --- SURVIVOR-SWEEP-BEGIN (a9hh R2-F2) -----------------------------------
    # THE SPEC IS DONE; ITS PROCESS GROUP MUST BE TOO. `wait` above returns
    # when the top-level bash exits — but a spec can background work and
    # exit 0, and then everything downstream of this point is a lie told
    # politely: the runner classifies on a partial transcript, removes the
    # output file, and the child writes its `SKIPPED:`/`FAIL:` line into an
    # unlinked inode while the summary says Partial: 0 (reproduced, Sol
    # R2-F2: Passed: 36, rc=0, marker lost, child alive after the tier
    # returned). So: poll the spec's group briefly — anything that finishes
    # dying (or finishes WRITING: the file still exists, so output landing
    # during the grace is counted below) gets its say — then kill what
    # remains and classify the spec FAILED. Zombies are excluded from the
    # scan: a dead-but-unreaped entry can neither write nor leak, and
    # counting one would fail specs for the reaper's latency, not their own
    # behaviour. The ps+awk shape matches tree_pids above: no new tools.
    #
    # The group id is the leader's pid, and the leader is dead — so a recycled
    # pgid is conceivable. Two things bound it: the scan runs microseconds to
    # ~2s after the leader died (a full pid-space wrap inside that window is
    # not a real machine), and the kill only fires when the scan FOUND
    # members, never blind.
    sweep_polls=0
    while :; do
        SURVIVORS=$(ps -axo pid=,pgid=,stat= 2>/dev/null \
            | awk -v g="$spec_pid" '$2 == g && $3 !~ /^Z/ { print $1 }')
        [ -z "$SURVIVORS" ] && break
        if [ "$sweep_polls" -ge 4 ]; then
            SURVIVOR_COUNT=$(printf '%s\n' "$SURVIVORS" | grep -c .)
            # Name what is about to be killed (best-effort — a member can die
            # between the scan and this ps). QA found R3-F1 only by
            # instrumenting a copy of this runner; the identity of a survivor
            # is the ONE fact that turns the next such flake from a
            # 25-iteration hunt into a one-line read.
            # Control bytes become '?' before the width cut: survivor args
            # are arbitrary argv, and raw ANSI in a CI log is exactly the
            # kind of noise that makes the one load-bearing line unreadable.
            SURVIVOR_IDS=$(ps -axo pid=,ppid=,pgid=,args= 2>/dev/null \
                | awk -v g="$spec_pid" '$3 == g' \
                | LC_ALL=C tr -c '[:print:]\n\t' '?' \
                | sed 's/^[[:space:]]*//' | cut -c1-160)
            kill -TERM -- "-$spec_pid" 2>/dev/null
            sleep 1
            kill -KILL -- "-$spec_pid" 2>/dev/null
            break
        fi
        sweep_polls=$((sweep_polls + 1))
        sleep 0.5
    done
    [ "$SURVIVOR_COUNT" -gt 0 ] && \
        LEAK_NOTE="; killed $SURVIVOR_COUNT process(es) its group left running"
    # --- SURVIVOR-SWEEP-END (a9hh R2-F2) --------------------------------------
    CURRENT_SPEC_PGID=""

    cat "$SPEC_OUT"

    # Assertion lines actually executed — the same `PASS:`/`FAIL:` shape the
    # CI META tally greps for. This is what makes "exited 0 having run
    # nothing" detectable at all.
    ASSERTS=$(grep -cE '^[[:space:]]*(PASS|FAIL):' "$SPEC_OUT" 2>/dev/null || true)
    case "$ASSERTS" in ''|*[!0-9]*) ASSERTS=0 ;; esac
    ASSERTS_TOTAL=$((ASSERTS_TOTAL + ASSERTS))

    # FAIL: lines specifically — same anchor as the ASSERTS count above, so
    # the two cannot disagree about what an assertion line is. Consumed by
    # the transcript arm below (a9hh R4-F2).
    FAIL_LINES=$(grep -cE '^[[:space:]]*FAIL:' "$SPEC_OUT" 2>/dev/null || true)
    case "$FAIL_LINES" in ''|*[!0-9]*) FAIL_LINES=0 ;; esac

    # Section-level skip markers (see SECTION_SKIP_RE). Counted for every
    # outcome, but only ANNOTATED on a spec that passed: a spec that failed,
    # timed out or skipped whole-file is already red for a louder reason.
    SECTION_SKIPS=$(grep -cE "$SECTION_SKIP_RE" "$SPEC_OUT" 2>/dev/null || true)
    case "$SECTION_SKIPS" in ''|*[!0-9]*) SECTION_SKIPS=0 ;; esac

    if [ -f "$TIMEOUT_MARKER" ]; then
        FAIL=$((FAIL + 1))
        TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
        # a9hh R6-F1/R8-F1: the watchdog NAMES what it KILLed, separating the
        # snapshot members that refused TERM from the ones it never TERMed and
        # cannot speak for, and — separately again — anything its escalation
        # could NOT kill. A timeout verdict that killed or stranded work must
        # say so, by name.
        WD_SURV_NOTE=""
        if [ -s "$WD_SURVIVORS" ]; then
            WD_KILLED_COUNT=$(grep -cE '    (refused TERM|not in the TERM snapshot), KILLed:' "$WD_SURVIVORS" 2>/dev/null)
            case "$WD_KILLED_COUNT" in ''|*[!0-9]*) WD_KILLED_COUNT=0 ;; esac
            WD_SURV_COUNT=$(grep -c '    survivor:' "$WD_SURVIVORS" 2>/dev/null)
            case "$WD_SURV_COUNT" in ''|*[!0-9]*) WD_SURV_COUNT=0 ;; esac
            [ "$WD_KILLED_COUNT" -gt 0 ] && \
                WD_SURV_NOTE="; $WD_KILLED_COUNT process(es) KILLed at escalation — named below"
            [ "$WD_SURV_COUNT" -gt 0 ] && \
                WD_SURV_NOTE="$WD_SURV_NOTE; $WD_SURV_COUNT process(es) SURVIVED the kill escalation — see survivor lines"
        fi
        FAILED_FILES+=("$base (TIMEOUT: killed by the ${SPEC_TIMEOUT_S}s per-spec cap after emitting $ASSERTS assertion(s)$LEAK_NOTE$WD_SURV_NOTE)")
        printf -- '--- %s: FAILED — TIMEOUT at the %ss per-spec cap (%s assertion(s) emitted in %ss; never a pass, never a skip%s%s) ---\n' \
            "$base" "$SPEC_TIMEOUT_S" "$ASSERTS" "$ELAPSED_S" "$LEAK_NOTE" "$WD_SURV_NOTE"
        [ -s "$WD_SURVIVORS" ] && cat "$WD_SURVIVORS"
    elif [ "$rc" -ne 0 ]; then
        FAIL=$((FAIL + 1))
        FAILED_FILES+=("$base (rc=$rc, $ASSERTS assertion(s) in ${ELAPSED_S}s$LEAK_NOTE)")
        printf -- '--- %s: FAILED rc=%s (%s assertion(s) in %ss%s) ---\n' \
            "$base" "$rc" "$ASSERTS" "$ELAPSED_S" "$LEAK_NOTE"
    elif [ "$SURVIVOR_COUNT" -gt 0 ]; then
        # Exited 0 while its process group still held live work. Never a
        # pass and never a mere annotation: the transcript this spec was
        # judged on was incomplete BY CONSTRUCTION (a late line can be a
        # FAIL:, a SKIPPED:, anything), so no classification of what it
        # printed so far can be trusted. The work was killed above; the
        # spec's defect is returning while it was still running. ("End",
        # not "reap": a survivor can be a ppid=1 non-child a tool the spec
        # called left behind — unwaitable, but preventable at the source,
        # which is what TELEMETRY-DISARM does for bd's flusher.)
        FAIL=$((FAIL + 1))
        FAILED_FILES+=("$base (exited 0 with $SURVIVOR_COUNT background process(es) still running — killed; a spec must end its background work before returning; $ASSERTS assertion(s) in ${ELAPSED_S}s)")
        printf -- '--- %s: FAILED — returned with %s live background process(es), killed (%s assertion(s) in %ss); its output ends wherever they were, so no outcome read from it is complete ---\n' \
            "$base" "$SURVIVOR_COUNT" "$ASSERTS" "$ELAPSED_S"
    # --- TRANSCRIPT-FAIL-BEGIN (a9hh R4-F2) ----------------------------------
    # rc=0 with a FAIL: line in the transcript is a FAILURE the exit code
    # never carried. Reproduced on the shipped pre-fix runner, both shapes:
    #   printf 'PASS: foreground\n'; ( sleep 1; printf 'FAIL: background\n' ) &
    #   exit 0
    # — the child dies INSIDE the sweep's grace window, so SURVIVOR_COUNT
    # stays 0, its FAIL: line lands in the still-linked output file, the
    # ASSERTS count reads 2, and the spec was PASSED with a FAIL: in its own
    # transcript (rc=0, tier green). The runner classified by exit status
    # alone; nothing anywhere read the FAIL: lines it was already counting.
    # This arm closes the timing hole from the other side: work that fails
    # and finishes within the grace is caught HERE by its transcript, work
    # that outlives the grace is caught ABOVE by the sweep — there is no
    # duration for which a failing background write is green. It also
    # catches the foreground spec whose own exit-code plumbing is broken
    # (printed FAIL: but exited 0), which is this task's defect class at
    # assertion granularity. Excising this region restores the pre-fix
    # runner byte-for-byte in behaviour — runner-completeness.test.sh
    # section 12 drives exactly that mutant and expects the deception.
    elif [ "$FAIL_LINES" -gt 0 ]; then
        FAIL=$((FAIL + 1))
        first_fail=$(grep -m1 -E '^[[:space:]]*FAIL:' "$SPEC_OUT" 2>/dev/null \
            | LC_ALL=C tr -c '[:print:]\n\t' '?' \
            | sed 's/^[[:space:]]*//' | cut -c1-160)
        FAILED_FILES+=("$base (exited 0 over $FAIL_LINES FAIL: line(s) in its own transcript — first: $first_fail)")
        printf -- '--- %s: FAILED — exited 0, but its transcript holds %s FAIL: line(s) the exit code never carried (%s assertion(s) in %ss) ---\n' \
            "$base" "$FAIL_LINES" "$ASSERTS" "$ELAPSED_S"
    # --- TRANSCRIPT-FAIL-END (a9hh R4-F2) --------------------------------------
    elif [ "$ASSERTS" -eq 0 ]; then
        # Exit 0 with zero executed assertions: the spec measured nothing.
        # Whatever it printed (a `SKIPPED:` line, or nothing at all), this is
        # never a pass — a measurement that did not happen must not look like
        # one that passed.
        SKIP=$((SKIP + 1))
        skip_reason=$(grep -m1 '^SKIPPED:' "$SPEC_OUT" 2>/dev/null || true)
        [ -z "$skip_reason" ] && skip_reason="exited 0 with zero executed assertions and no SKIPPED: line"
        SKIPPED_FILES+=("$base — $skip_reason")
        printf -- '--- %s: SKIPPED, not a pass (%ss) — %s ---\n' \
            "$base" "$ELAPSED_S" "$skip_reason"
    elif [ "$SECTION_SKIPS" -gt 0 ]; then
        # Passed what it ran, but did not run all of itself.
        PASS=$((PASS + 1))
        PARTIAL=$((PARTIAL + 1))
        first_marker=$(grep -m1 -E "$SECTION_SKIP_RE" "$SPEC_OUT" 2>/dev/null \
            | sed 's/^[[:space:]]*//' | cut -c1-160)
        PARTIAL_FILES+=("$base — $SECTION_SKIPS section-level skip(s), $ASSERTS assertion(s) ran; first: $first_marker")
        printf -- '--- %s: PASSED but INCOMPLETE (%s assertion(s) in %ss; %s section-level skip(s) — see PARTIAL below) ---\n' \
            "$base" "$ASSERTS" "$ELAPSED_S" "$SECTION_SKIPS"
    else
        PASS=$((PASS + 1))
        printf -- '--- %s: PASSED (%s assertion(s) in %ss) ---\n' \
            "$base" "$ASSERTS" "$ELAPSED_S"
    fi
    # Whatever the sweep killed, NAME it (pid ppid pgid args) under the
    # verdict line. Lives outside the sentinel region: with the sweep excised
    # SURVIVOR_IDS stays empty and this is a no-op, so the mutant still runs.
    if [ "$SURVIVOR_COUNT" -gt 0 ] && [ -n "$SURVIVOR_IDS" ]; then
        printf '%s\n' "$SURVIVOR_IDS" | while IFS= read -r survivor_line; do
            printf '    survivor: %s\n' "$survivor_line"
        done
    fi
    rm -f "$SPEC_OUT" "$TIMEOUT_MARKER" "$WD_SURVIVORS"
done

printf '\n=== Summary ===\n'
printf 'Total: %d  Passed: %d  Failed: %d  Skipped: %d  Partial: %d\n' \
    "$TOTAL" "$PASS" "$FAIL" "$SKIP" "$PARTIAL"
# The tier's executed-assertion total. Spec counts alone cannot distinguish a
# full run from one that lost a section — measured at a9hh round 1 (change set
# 5b47c019, tree 535c89a + that change): 2501 assertions locally against 2486
# in the CI shape, the same 36 specs, the same green summary line. So print the
# number that moves.
printf 'Assertions executed: %d\n' "$ASSERTS_TOTAL"
if [ "$TIMEOUT_COUNT" -gt 0 ]; then
    printf 'Timed out (counted in Failed): %d spec(s) at the %ss per-spec cap\n' \
        "$TIMEOUT_COUNT" "$SPEC_TIMEOUT_S"
fi

if [ "$FAIL" -gt 0 ]; then
    printf 'Failed tests:\n'
    for f in "${FAILED_FILES[@]}"; do
        printf '  - %s\n' "$f"
    done
fi
if [ "$SKIP" -gt 0 ]; then
    printf 'Skipped tests (NOT passes):\n'
    for f in "${SKIPPED_FILES[@]}"; do
        printf '  - %s\n' "$f"
    done
fi
if [ "$PARTIAL" -gt 0 ]; then
    printf 'PARTIAL — passed, but skipped a section (the completeness line below is spec-granular):\n'
    for f in "${PARTIAL_FILES[@]}"; do
        printf '  - %s\n' "$f"
    done
fi

# --- COMPLETENESS-FLOOR-BEGIN (a9hh) ---------------------------------------
# The negative control for the completeness line above (see the EXPECTED_SPECS
# block for the full framing). Sentinel-delimited so the paired control spec
# (runner-completeness.test.sh) can excise exactly this region from a COPY and
# demonstrate the deception it prevents: an un-floored runner prints a green
# `Total: N  Passed: N  Failed: 0` over a shrunken or unexecuted spec set.
# Do not rename the sentinels without updating that spec.
if [ -n "$FILTER" ]; then
    if [ "$TOTAL" -eq 0 ]; then
        printf 'run-tests.sh: --filter %s matched no spec files — nothing ran, so nothing passed\n' \
            "$FILTER" >&2
        finish 2
    fi
    printf 'Completeness floor: DISARMED (--filter run; this summary describes a subset, not the tier)\n'
else
    if [ "$TOTAL" -ne "$EXPECTED_SPECS" ]; then
        printf 'COMPLETENESS FLOOR BREACH: discovered %d spec file(s), expected exactly %d.\n' \
            "$TOTAL" "$EXPECTED_SPECS" >&2
        printf '  The completeness line above describes a DIFFERENT tier than the one this floor pins.\n' >&2
        printf '  If you added or removed a spec deliberately, update EXPECTED_SPECS in run-tests.sh\n' >&2
        printf '  in the same change. Otherwise, spec files have been lost and every summary since\n' >&2
        printf '  has been green over a shrunken set.\n' >&2
        finish 1
    fi
    # THE CLAIM, QUALIFIED WHERE IT IS MADE. "discovered and executed" is
    # SPEC-granular: it says every spec file ran, not that every section of
    # every spec ran. a9hh R1-F1 is what that distinction cost — this exact
    # line, reading 36/36 with Skipped: 0, over 15 assertions that never
    # executed. So the partial count and the assertion total travel with it.
    if [ "$PARTIAL" -gt 0 ]; then
        printf 'Completeness floor: HELD (%d/%d specs discovered and executed — SPEC-granular; %d of them skipped a SECTION, listed above; %d assertion(s) executed)\n' \
            "$TOTAL" "$EXPECTED_SPECS" "$PARTIAL" "$ASSERTS_TOTAL"
    else
        printf 'Completeness floor: HELD (%d/%d specs discovered and executed; 0 skipped a section; %d assertion(s) executed)\n' \
            "$TOTAL" "$EXPECTED_SPECS" "$ASSERTS_TOTAL"
    fi
fi

if [ "$SKIP" -gt 0 ]; then
    printf 'SKIP IS NOT A PASS: %d spec(s) executed zero assertions (listed above). The tier is red\n' "$SKIP" >&2
    printf '  until they run: install the missing prerequisite (each SKIPPED line names it) or\n' >&2
    printf '  remove the spec deliberately (and move the floor) — but do not read this run as green.\n' >&2
    finish 1
fi
# --- COMPLETENESS-FLOOR-END (a9hh) ------------------------------------------

# --- SECTION-SKIP-REFUSAL-BEGIN (a9hh R1-F1) --------------------------------
# The negative control for the PARTIAL annotation, in the same shape the floor
# uses: sentinel-delimited so runner-completeness.test.sh can excise exactly
# this region from a COPY and show what a runner without it reads like — a
# green tier, rc=0, in an environment that was supposed to be able to run
# every section. That is not hypothetical; it is what a9hh's own fix round
# shipped, and it is why the flag exists rather than a comment saying "check
# the PARTIAL list".
#
# Off by default ON PURPOSE. A dev machine legitimately lacks prerequisites
# some sections need, and a control that goes red on every laptop is a control
# people learn to ignore (R1-F2, and LESSONS' four instances of the same
# class). The environment we CONTROL — the CI l1-unit job — provisions all of
# them and sets STRICT_SECTIONS=1, so there the claim is enforced rather than
# asserted. runner-completeness.test.sh pins that wiring so dropping the env
# var from the workflow is itself caught.
if [ "$PARTIAL" -gt 0 ] && [ "$STRICT_SECTIONS_ON" -eq 1 ]; then
    printf 'SECTION SKIPS ARE NOT COVERAGE: %d spec(s) passed while skipping a section (listed above),\n' "$PARTIAL" >&2
    printf '  and STRICT_SECTIONS=1 says this environment is supposed to be able to run all of them.\n' >&2
    printf '  Either provision what the marker names (that is what the l1-unit job does for bd, node\n' >&2
    printf '  and BOTH MCP servers node_modules), or — if the section genuinely cannot run here —\n' >&2
    printf '  say so where the claim is made and take the section arm out of the strict environment.\n' >&2
    printf '  Do not read this run as full coverage: it is not.\n' >&2
    finish 1
fi
# --- SECTION-SKIP-REFUSAL-END (a9hh R1-F1) ----------------------------------

if [ "$FAIL" -gt 0 ]; then
    finish 1
fi

finish 0

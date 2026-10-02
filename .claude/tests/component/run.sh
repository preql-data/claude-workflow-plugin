#!/bin/bash
# run.sh - Component-tier test runner.
#
# Phase B (claude-workflow-plugin-0wk.11). Mirrors the L1 runner at
# .claude/scripts/tests/run-tests.sh but discovers specs under
# .claude/tests/component/specs/*.sh and pre-sources the lib/ helpers
# (assert.sh, shim.sh, hook-envelope.sh, fixture.sh) into each spec's
# shell so specs can call mk_fixture / mk_shim / assert_eq directly.
#
# OUTCOMES (a9hh/mwrb, paired by runner-completeness.test.sh in the L1 tier —
# three outcomes, three reasons):
#   PASSED  — the spec exited 0 and its __SPEC_SUMMARY__ shows at least one
#             assertion executed.
#   FAILED  — non-zero exit, OR killed by the per-spec wall-clock cap, OR
#             returned while background work from its own process group was
#             still alive (a9hh R2-F2; the L1 runner carries the full note —
#             a spec that exits before its work finishes can emit outcomes
#             after classification, so nothing it printed reads as complete),
#             OR exited 0 while its accounting says otherwise (a9hh R4-F1/
#             R4-F2, the FAILED-ACCOUNTING arms below): a summary counting
#             failed assertions, a FAIL: line in the transcript the summary
#             never counted, or no summary line at all. Before this arm a
#             spec whose failing assertion preceded its bd_required_or_skip
#             gate was scored SKIPPED with Failed: 0 and rc=0 — a real
#             regression converted into a successful skip, on the CI path.
#             A timeout is a FAILURE with a distinct reason, never a pass and
#             never a skip. Before mwrb this runner waited on a spec forever:
#             one wedged bd call held the tier for 75+ minutes, producing NO
#             completeness line at all — the one state "read the completeness
#             line" cannot answer. The cap ends the spec, names it, and lets
#             the tier finish RED.
#   SKIPPED — exited 0 with zero executed assertions AND a summary line
#             saying so (the wrapper's EXIT trap prints pass=0 fail=0 even
#             when bd_required_or_skip / net_required_or_skip exits early).
#             A skip LEAVES the Passed column: `Passed` counts only specs
#             that measured something. A spec that runs assertions and THEN
#             hits a skip gate is PASSED with its executed count — honest at
#             spec granularity, matching L1's spec-granular claim.
#
# EXIT SEMANTICS FOR SKIPS — deliberately still 0, and that is a documented
# gap, not an endorsement: in BD_SHIM_ONLY=1 CI, 37 of 44 specs skip, and
# failing on skips here means deciding that job's bd story first. a9hh's
# operator decision scoped the completeness FLOOR to the L1 tier; the L2
# floor (and installing bd in the l2-component job) is the recorded follow-up
# (claude-workflow-plugin-a9hh, closing notes). What changed NOW is honesty:
# a skip no longer inflates Passed, the summary carries a COMPLETENESS caveat
# naming the executed subset, and a timeout is a red, terminating outcome.
#
# Usage:
#   bash .claude/tests/component/run.sh
#   bash .claude/tests/component/run.sh --filter <pattern>
#
# Environment:
#   SPEC_TIMEOUT_S — per-spec wall-clock cap in seconds (default 3600; the
#             slowest legitimate spec measured to date is verify-before-stop
#             at 1680s under contention). No "0 disables it" arm — an
#             unbounded spec is the mwrb defect. macOS has no timeout(1);
#             this is a shell watchdog that kills the spec's process TREE.
#
# STDIN: every spec is launched with its stdin EXPLICITLY redirected from
# /dev/null at the spawn site (a9hh R3-F2). The POSIX async default cannot be
# relied on, because `set -m` INVERTS it: with job control ON a background
# job INHERITS the runner's stdin (measured — a backgrounded `read` consumed
# a sentinel piped to the runner; under a terminal a stdin-reading spec is
# SIGTTIN-stopped, state T, which `kill -0` reads as alive, so the watchdog
# would burn the full cap and report TIMEOUT over a spec that is not
# running). With the redirect, a spec that expects an interactive stdin sees
# EOF at once — not a prompt, and not a stop. The L1 runner carries the full
# note; runner-completeness.test.sh section 11 is the paired control for
# both runners.
#
# PROCESS GROUPS: `set -m` below gives every spec its own process group, the
# same mechanics as L1 and for the same findings (a9hh R2-F2/R2-F3): the
# watchdog's KILL escalation is group-wide AND walks the ppid tree — twice,
# the second walk catching what a TERM handler spawned during the grace
# (R6-F1) — so a TERM-immune or trap-spawning descendant dies with its tree
# where the walks can reach it, and whatever they cannot is NAMED as a
# `survivor:` line, never silently stranded. The post-wait survivor sweep
# fails a spec that returned while its group still held live work. The L1
# runner's PROCESS GROUPS and escalate_kill notes carry the full rationale,
# the measured set -m side effects, and the stated limits (double-fork;
# spawn-then-die during the grace); this runner mirrors them rather than
# restating them.
#
# SKIP-MARKER PARTIALS (a9hh R7-F2): a spec that runs assertions and THEN
# hits a skip gate is PASSED with its executed count (R4-F1) — but its
# transcript carries the skip marker, and a green verdict that measured
# only part of itself must say so. Measured on the BD_SHIM_ONLY=1 CI shape
# at change set 668b8d19 (cmd: BD_SHIM_ONLY=1 + bd off PATH, this runner):
# post-edit.sh was `PASSED (101 assertion(s))` out of a 115-assertion full
# run and reviewer-lane-degradation.sh `PASSED (4)` of 8, each with a
# line-initial `SKIPPED:` in its transcript and NEITHER named in any
# accounting. Such a pass is now counted `Partial:` and listed under the
# summary, L1's exact convention (SECTION_SKIP_RE ported verbatim; L1
# carries the full marker-shape catalogue and rationale). Whole-file skips
# are untouched — a zero-assertion exit-0 is SKIPPED before this check.
#
# Exit codes:
#   0  every executed spec passed (skips are reported, and reported loudly;
#      a partial pass is a pass with a named qualification, exactly as L1)
#   1  one or more specs failed or timed out
#   2  invocation error (no specs found, jq missing, a --filter that matched
#      no spec files — a9hh R4-F3/R5-F2: nothing ran, so nothing passed, and
#      green-in-0.16s is exactly what a reader takes as "that spec passes" —
#      OR an unrecognised argument shape: a bare positional, `--filter` with
#      no pattern, or trailing junk after a pattern. claude-workflow-plugin-
#      icn4 item 3: these used to fall through to FILTER="" and a silent
#      FULL run; QA lost two 45-spec tier runs to exactly that before this
#      refusal existed)

set -u
# Job control ON: each spec (and watchdog) becomes its own process group.
# Load-bearing for the group-wide kill and the survivor sweep — see the
# PROCESS GROUPS header note and the L1 runner it mirrors.
set -m

# Hoisted above TELEMETRY-DISARM (claude-workflow-plugin-gsfd), mirroring the
# same hoist in the L1 runner: the dolt-side disarm below needs $PROJECT_DIR.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"

# --- TELEMETRY-DISARM-BEGIN (a9hh R3-F1; extended claude-workflow-plugin-gsfd/7tfe) ---
# bd's telemetry flusher (`bd send-metrics`) detaches to ppid=1 WITHOUT
# setsid, so it stays in the spec's process group and — when the endpoint is
# slow — outlives the survivor sweep's grace, failing the spec for a process
# it never backgrounded and cannot wait for. A fixture HOME with no
# ~/.config/bd defaults metrics to ON (measured on bd 1.1.2, the version CI
# pins). BD_DISABLE_METRICS=1 prevents the SPAWN itself (measured: 3/3
# in-group flushers without it, 0/3 with it). The L1 runner carries the full
# rationale; runner-completeness.test.sh section 10 fails a fixture spec
# through THIS runner when this export is excised.
export BD_DISABLE_METRICS=1

# claude-workflow-plugin-gsfd (7tfe): bd EMBEDS dolt, and the embedded engine
# spawns ITS OWN telemetry flusher that the export above cannot reach.
# Byte-identical to the L1 runner's copy of this function as of this change
# (verified by hand via `diff` at authoring time) — see run-tests.sh's
# TELEMETRY-DISARM region for the driven measurement (4/4 spawns with no
# local config, 0/4 with `dolt config --local --add metrics.disabled true`
# set) and why this writes to an untracked, repo-scoped path rather than the
# user's global dolt config. KNOWN GAP: nothing structurally enforces the two
# copies staying identical if one is edited later without the other — unlike
# BD_DISABLE_METRICS=1 (a one-line export, cheap to eyeball), this is a
# multi-line function, and runner-completeness.test.sh does not currently
# assert byte-equality between them the way linux-tier-driver.test.sh does
# for ITS mirrored logic. Filed as a documented gap, not fixed here.
disarm_dolt_telemetry() {
    local store="$1"
    [ -d "$store/.dolt" ] || return 0
    command -v dolt >/dev/null 2>&1 || return 0
    ( cd "$store" && dolt config --local --add metrics.disabled true ) >/dev/null 2>&1 || true
    return 0
}
disarm_dolt_telemetry "$PROJECT_DIR/.beads/embeddeddolt/beads"
# --- TELEMETRY-DISARM-END (a9hh R3-F1 / claude-workflow-plugin-gsfd) ---------

# claude-workflow-plugin-gsfd (member 5, the lease): see the L1 runner's own
# comment for the full rationale (mirrored verbatim in spirit, not repeated).
TREE_LEASE_AVAILABLE=0
_TL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || _TL_DIR=""
if [ -n "$_TL_DIR" ] && [ -f "$_TL_DIR/../../scripts/tree-lease.sh" ]; then
    # shellcheck source=.claude/scripts/tree-lease.sh
    . "$_TL_DIR/../../scripts/tree-lease.sh" && TREE_LEASE_AVAILABLE=1
fi

COMPONENT_DIR="$PROJECT_DIR/.claude/tests/component"
LIB_DIR="$COMPONENT_DIR/lib"
SPECS_DIR="$COMPONENT_DIR/specs"

# ARG PARSING (claude-workflow-plugin-icn4 item 3). MUST REFUSE, never
# silently ignore: QA lost two full 45-spec tier runs to a bare positional
# spec name (e.g. `run.sh reviewer-lane-degradation` instead of `run.sh
# --filter reviewer-lane-degradation`) being silently swallowed by the old
# `[ "${1:-}" = "--filter" ] && [ -n "${2:-}" ]` guard, which left FILTER=""
# on ANY unrecognised shape (a bad positional, or `--filter` with no pattern)
# and let the runner fall through to a full, unfiltered run — turning a
# 7-second targeted intent into an hour of self-contention against a
# concurrent run and its own bd writes. Every unrecognised shape below is an
# invocation error (exit 2), matching this file's own documented "2 —
# invocation error" contract; none of them fall through to FILTER="".
#
# PAIRED at runner-completeness.test.sh section 14: reverting the sentinel
# region below to the old one-liner quoted above (byte-for-byte) reproduces
# the silent-full-run swallow against a fixture spec tree; the shipped
# region here refuses both shapes QA actually hit, before any spec executes.
# --- ARG-PARSING-BEGIN (claude-workflow-plugin-icn4 item 3) ------------------
FILTER=""
case "${1:-}" in
    '')
        # No arguments: full, unfiltered run — the documented default, not a
        # silent fallback. Also matches an explicit empty-string positional
        # (`run.sh ''`): vanishingly rare, and named here rather than left as
        # an unaddressed gap (icn4 R1-F3) — a caller's quoted variable that
        # expands to '' lands in this same arm, same full-run scope as no
        # args at all.
        ;;
    --filter)
        if [ -z "${2:-}" ]; then
            printf 'run.sh: --filter requires a <pattern> argument\n' >&2
            printf '  Usage: bash .claude/tests/component/run.sh [--filter <pattern>]\n' >&2
            exit 2
        fi
        FILTER="$2"
        if [ "$#" -gt 2 ]; then
            printf 'run.sh: unexpected extra argument(s) after --filter %s: %s\n' \
                "$FILTER" "${*:3}" >&2
            printf '  Usage: bash .claude/tests/component/run.sh [--filter <pattern>]\n' >&2
            exit 2
        fi
        ;;
    *)
        printf 'run.sh: unknown argument: %s\n' "$1" >&2
        printf '  A bare spec name is not a filter and is silently ignored by NOTHING here —\n' >&2
        printf '  did you mean: bash .claude/tests/component/run.sh --filter %s ?\n' "$1" >&2
        printf '  Usage: bash .claude/tests/component/run.sh [--filter <pattern>]\n' >&2
        exit 2
        ;;
esac
# --- ARG-PARSING-END (claude-workflow-plugin-icn4 item 3) --------------------

SPEC_TIMEOUT_S="${SPEC_TIMEOUT_S:-3600}"
case "$SPEC_TIMEOUT_S" in
    ''|*[!0-9]*|0)
        printf 'run.sh: SPEC_TIMEOUT_S must be a positive integer (got %s)\n' \
            "${SPEC_TIMEOUT_S:-<empty>}" >&2
        exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
    printf 'run.sh: jq is required but not on PATH\n' >&2
    exit 2
fi

if [ ! -d "$SPECS_DIR" ]; then
    printf 'run.sh: specs dir missing: %s\n' "$SPECS_DIR" >&2
    exit 2
fi

# Discover specs. macOS bash 3.2 friendly (no mapfile).
SPECS=()
while IFS= read -r line; do
    SPECS+=("$line")
done < <(find "$SPECS_DIR" -maxdepth 1 -type f -name '*.sh' | sort)

if [ ${#SPECS[@]} -eq 0 ]; then
    printf 'run.sh: no specs found in %s\n' "$SPECS_DIR" >&2
    exit 2
fi

# Scratch for per-spec output capture. A FILE, not command substitution: a
# timed-out spec can leave children holding stdout, and a pipe reader blocks
# on them forever — the exact hang the cap ends. Output prints when the spec
# finishes; the banner prints up front so a silent long spec is attributable.
#
# NO `trap ... EXIT` IN THIS RUNNER (a9hh R5-F1): on Linux bash 5.2 the EXIT
# trap that used to remove this dir nondeterministically fired inside forked
# children under load and deleted the scratch MID-TIER — every later spec
# failed rc=1 with 0 assertions, and QA measured the same signature here at
# 6/20 container runs ("cat: /tmp/l2-runner.../spec-out.N: No such file");
# our own pre-fix L2 control read 40/40 BAD under contention. In-trap guards
# do not fix it: measured as a factorial on the L1 shape across three
# independent builds (R7-F1 corrected the earlier account; R9 widened the
# observed guard-then-rm range to 28-37/40), a BASHPID guard evaluated as the
# trap's FIRST command misevaluates. An in-trap write alone OBSERVES the
# misfire at baseline rate rather than masking anything; masking is ORDER-
# dependent, not combination-dependent — the byte-identical write before the
# guard reads clean, while guard before write does not — and nobody has
# explained why. That interaction is not a fix. The only shape measured
# clean by every build is an EMPTY trap-space: cleanup happens at the
# explicit terminal exits below (`finish`). The L1 runner carries the full
# measured table; the a9hh Beads record carries the commands. Residual
# cost, stated: HUP/INT/TERM are trapped and clean (R7-F3 — untrapped HUP
# leaked 5/5 on the closed-terminal path); a runner aborted mid-script by
# `set -u` or SIGKILL leaks one /tmp dir — a leak beats a tier that reds
# itself.
RUN_SCRATCH=$(mktemp -d -t l2-runner.XXXXXX)

# --- LEASE-ACQUIRE-BEGIN (claude-workflow-plugin-gsfd, member 5) -----------
# Mirrors the L1 runner's own lease region — see run-tests.sh for the full
# rationale. mrd2's own finding (review-separation.test.sh reading real bd
# records perturbed by a concurrent L2 run) is exactly the case this notice
# is for: it does not stop the contention, but a red that names a live L1
# lease is attributable in one read instead of a re-run habit that eventually
# waves a real regression through.
LEASE_FILE=""
if [ "$TREE_LEASE_AVAILABLE" = "1" ]; then
    LEASE_FILE=$(lease_acquire "$PROJECT_DIR/.claude/.qa-tracking" "L2" \
        "run.sh${FILTER:+ --filter $FILTER} pid=$$") || LEASE_FILE=""
    if [ -n "$LEASE_FILE" ]; then
        CONFLICT_NOTE=$(lease_conflict_summary "$PROJECT_DIR/.claude/.qa-tracking" "$LEASE_FILE") || CONFLICT_NOTE=""
        if [ -n "$CONFLICT_NOTE" ]; then
            printf 'CONCURRENT-RUN NOTICE: another tier claims to be active right now —\n'
            printf '  a failure below may be contention, not regression (claude-workflow-plugin-gsfd):\n'
            printf '%s\n' "$CONFLICT_NOTE" | sed 's/^/  /'
        fi
    fi
fi
# --- LEASE-ACQUIRE-END (claude-workflow-plugin-gsfd) -------------------------
# DESIGN COLLAPSE (claude-workflow-plugin-gsfd, operator-directed, round 6):
# this runner does NOT heartbeat its own lease, and nothing else in this
# codebase does either. Two rounds (R3-F3 FOLLOW-UP, R4-F3) built and then
# chased the correctness cost of touching this lease's mtime from inside the
# WATCHDOG below; a third (R5-F2/R5-F4) found the hardened version still cost
# a background process per tick. The lease is now report-only (see
# tree-lease.sh's own DESIGN COLLAPSE header): nothing ever auto-removes a
# lease on the strength of its age, so there is nothing left for a heartbeat
# to protect. Full causal account: CHANGELOG.md.

# finish <code> — the ONLY place the scratch (and this run's lease, if one
# was acquired) is removed and the ONLY exit once the scratch exists. Never
# runs from a trap (see above).
finish() {
    [ -n "$RUN_SCRATCH" ] && rm -rf "$RUN_SCRATCH"
    if [ "${TREE_LEASE_AVAILABLE:-0}" = "1" ]; then
        # R2-F3 fix round 2 (sol-codex review): belt-and-braces, matching
        # tree-lease.sh's own convention -- this runner is not under `set -e`
        # today so it was not exposed to the exact failure the review named
        # (verify-before-stop.sh, which is), but the fix costs nothing and a
        # future `set -e` here should not have to rediscover it.
        lease_release "${LEASE_FILE:-}" || true
    fi
    exit "$1"
}

# tree_pids <pid> — <pid> plus every live descendant, depth-first, via a
# ppid walk. Portable across macOS and Linux ps (no setsid, no pkill -P
# recursion assumptions). The SNAPSHOT both kill paths use: TERM breaks ppid
# chains, so collect before killing. The TERM loop over it is the POLITE
# pass — a `trap '' TERM` child refuses it (a9hh R2-F3); the KILL after the
# grace is the STRONG pass, group-wide AND against this snapshot (a9hh
# R4-F4) plus one re-walk from every snapshot member still alive (a9hh
# R6-F1: a TERM handler can spawn DURING the grace). The set is two bounded
# walks, not a closed world — what the escalation can still see alive
# afterwards it NAMES as `survivor:` lines rather than claiming a clean
# tree. Full rationale and limits at L1's escalate_kill.
tree_pids() {
    local pid="$1" kids k
    kids=$(ps -axo pid,ppid 2>/dev/null | awk -v p="$pid" '$2 == p { print $1 }')
    for k in $kids; do
        tree_pids "$k"
    done
    printf '%s\n' "$pid"
}

# escalate_kill <pid> <grace_s> — the one kill escalation both kill sites
# here use; byte-mirror of L1's (the full story lives there): snapshot,
# polite tree TERM, group TERM, grace, RE-WALK from live snapshot members
# (R6-F1 — one bounded pass, deliberately never a loop), KILL union +
# group, then NAME survivors on stdout.
# name_group_members <pid-list> <pgid> — mirrors L1: one ps line per live,
# non-zombie process in the list or the group.
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
    # Mirror L1's attribution (a9hh R8-F1). This function knows only which
    # pids IT TERMed — the pre-TERM snapshot. Snapshot members still alive a
    # grace later refused TERM. Everything else is two populations it cannot
    # tell apart: spawned during the grace and found by the re-walk (never
    # TERMed), or double-forked out of the ppid chain but still in the group
    # (TERMed, and refused). Both measured; so that line states MEMBERSHIP and
    # claims no signal in either direction. Full rationale at L1.
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

# Interrupt forwarding: with each spec in its own group, ^C/TERM — and HUP,
# the closed-terminal path (a9hh R7-F3: untrapped, it leaked the scratch
# 5/5 with `finish` unreached) — reaches the runner alone; forward through
# escalate_kill so an interrupted run does not strand a half-finished spec
# tree (R4-F4 reproduced on Linux; R6-F1's trap-spawned child reproduced
# both platforms). Exit stays 130 for all three: it names "interrupted",
# not which signal.
CURRENT_SPEC_PGID=""
# shellcheck disable=SC2329  # invoked via trap.
on_interrupt() {
    # Fork-window guard (a9hh R5-F1): never observed for INT/TERM traps
    # (bash resets those in children reliably — 0 foreign firings across
    # every instrumented Linux soak), but one test buys the belt. Inert on
    # bash 3.2, where BASHPID does not exist and the misfire cannot happen.
    [ "${BASHPID:-$$}" = "$$" ] || exit 130
    if [ -n "$CURRENT_SPEC_PGID" ]; then
        escalate_kill "$CURRENT_SPEC_PGID" 1
    fi
    finish 130
}
trap on_interrupt INT TERM HUP

# Skip-marker regex, ported VERBATIM from L1 (a9hh R7-F2). L1's header note
# carries the four marker shapes, the line-start anchoring rationale (an
# assertion NAMED "skip" cannot match — assertion lines start PASS:/FAIL:),
# and the reserved-idiom measurement behind the bare `note:` clause. Keep
# the two byte-identical: a marker one tier recognises and the other
# ignores is the R7-F2 defect re-armed.
SECTION_SKIP_RE='^[[:space:]]*(SKIPPED|SKIP)[[:space:]:]|^[[:space:]]*[Nn][Oo][Tt][Ee]:'

TOTAL=0
SPEC_PASS=0
SPEC_FAIL=0
SPEC_SKIP=0
SPEC_PARTIAL=0
TIMEOUT_COUNT=0
TOTAL_ASSERTS_PASS=0
TOTAL_ASSERTS_FAIL=0
FAILED_SPECS=()
SKIPPED_SPECS=()
PARTIAL_SPECS=()

# Per-spec runner. We invoke each spec in a fresh subshell with the lib
# files pre-sourced; the spec calls mk_fixture, runs assertions, and prints
# its own PASS:/FAIL: lines. The runner reads the trailing summary line
# (__SPEC_SUMMARY__ pass=N fail=M) and aggregates.
for spec_file in "${SPECS[@]}"; do
    base=$(basename "$spec_file")
    if [ -n "$FILTER" ] && ! printf '%s' "$base" | grep -q "$FILTER"; then
        continue
    fi
    TOTAL=$((TOTAL + 1))
    printf '\n=== %s ===\n' "$base"

    SPEC_OUT="$RUN_SCRATCH/spec-out.$TOTAL"
    TIMEOUT_MARKER="$RUN_SCRATCH/spec-timeout.$TOTAL"
    START_S=$(date +%s)

    # The wrapper sources the lib files, then sources the spec. A subshell so
    # PATH / CLAUDE_PROJECT_DIR mutations stay scoped to the spec. Captures
    # the spec's exit code; specs exit non-zero when their FAIL counter is
    # non-zero (same convention as phase5).
    bash -u -c "
        set +e
        # Per-spec PASS/FAIL counters live in the same shell as the spec.
        PASS=0
        FAIL=0
        FAILED_TESTS=()
        # --- SUMMARY-TRAP-BEGIN (a9hh R4-F1) ---------------------------------
        # The summary must survive ANY exit. A sourced spec's \`exit 0\` —
        # bd_required_or_skip, net_required_or_skip, an ad-hoc SKIPPED gate —
        # used to end this wrapper BEFORE the trailing summary printed, so a
        # spec whose transcript already held FAIL: lines was classified
        # SKIPPED, the aggregate read \`Failed: 0\`, and run.sh exited 0: a
        # real assertion regression converted into a successful skip, on the
        # BD_SHIM_ONLY=1 CI path (post-edit.sh runs ~600 lines of assertions
        # and THEN hits its bd gate). The EXIT trap prints the summary on
        # every builtin exit. TRAP OWNERSHIP: fixture.sh arms its own EXIT
        # trap at source time behind an install-once guard — presetting
        # __COMPONENT_FIXTURE_TRAP_INSTALLED tells it the slot is taken, and
        # __spec_wrapper_exit calls the cleanup itself. A spec that re-arms
        # EXIT for its own teardown must end its trap command with
        # __spec_wrapper_exit (see beads-ledger.sh; the runner scores an
        # exit-0 spec with NO summary line as FAILED, so dropping the chain
        # is loud, not silent).
        __SPEC_SUMMARY_DONE=0
        __spec_summary() {
            [ \"\$__SPEC_SUMMARY_DONE\" = 1 ] && return 0
            __SPEC_SUMMARY_DONE=1
            printf '__SPEC_SUMMARY__ pass=%d fail=%d\n' \"\$PASS\" \"\$FAIL\"
        }
        __spec_wrapper_exit() {
            __spec_summary
            if type __component_fixture_cleanup >/dev/null 2>&1; then
                __component_fixture_cleanup
            fi
            return 0
        }
        __COMPONENT_FIXTURE_TRAP_INSTALLED=1
        trap __spec_wrapper_exit EXIT
        # --- SUMMARY-TRAP-END (a9hh R4-F1) -----------------------------------
        . '$LIB_DIR/assert.sh'
        . '$LIB_DIR/shim.sh'
        . '$LIB_DIR/hook-envelope.sh'
        . '$LIB_DIR/fixture.sh'
        . '$spec_file'
        if [ \"\$FAIL\" -gt 0 ]; then
            exit 1
        fi
        exit 0
    " > "$SPEC_OUT" 2>&1 < /dev/null &
    spec_pid=$!    # == the spec's process-group id, because set -m
    # ^ `< /dev/null` is load-bearing (a9hh R3-F2): set -m makes a background
    #   job inherit the runner's stdin — see the STDIN header note.
    CURRENT_SPEC_PGID="$spec_pid"

    # Watchdog: poll so it exits promptly with the spec; at the cap, write
    # the marker FIRST (a kill racing spec exit still classifies), then run
    # escalate_kill (a9hh R2-F3/R4-F4/R6-F1 — mirrors L1). Survivor lines
    # land in a per-spec file the TIMEOUT verdict surfaces.
    #
    # DESIGN COLLAPSE (claude-workflow-plugin-gsfd, operator-directed, round
    # 6): no heartbeat here, or anywhere else in this codebase. Two rounds
    # (R3-F3 FOLLOW-UP, R4-F3) built and then chased the correctness cost of
    # touching this lease's mtime from inside this watchdog; a third
    # (R5-F2/R5-F4) found the replacement still accumulated background
    # processes. The lease is now report-only (see tree-lease.sh's own
    # DESIGN COLLAPSE header): nothing ever auto-removes a lease on the
    # strength of its age, so there is nothing left for a heartbeat to
    # protect. Full causal account: CHANGELOG.md.
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
    spec_rc=$?
    # a9hh R6-F1: when the cap FIRED, let the watchdog finish its escalation
    # — TERMing it here cut the KILL pass short whenever the leader died at
    # the polite TERM, so a TERM-catching descendant outlived the whole
    # escalation (mirrors L1; reproduced there). The no-timeout path still
    # TERMs it, where it is only sleeping out its poll loop.
    if [ -f "$TIMEOUT_MARKER" ]; then
        wait "$wd_pid" 2>/dev/null
    else
        kill -TERM "$wd_pid" 2>/dev/null
        wait "$wd_pid" 2>/dev/null
    fi
    ELAPSED_S=$(( $(date +%s) - START_S ))

    # Sweep state, initialised OUTSIDE the sentinel region so the excised
    # mutant runner-completeness.test.sh builds still runs under set -u —
    # with the sweep gone these stay 0/empty and the runner behaves like the
    # one that shipped R2-F2.
    SURVIVOR_COUNT=0
    SURVIVOR_IDS=""
    LEAK_NOTE=""
    # --- SURVIVOR-SWEEP-BEGIN (a9hh R2-F2) -----------------------------------
    # The spec is done; its process group must be too. Same sweep as L1 (the
    # full rationale lives there): brief grace so anything mid-death — or
    # mid-WRITE, the output file still exists here — finishes and is counted,
    # then kill what remains and classify the spec FAILED below. Zombies
    # excluded (can neither write nor leak); kill only fires when the scan
    # FOUND members, never blind on a possibly-recycled pgid.
    sweep_polls=0
    while :; do
        SURVIVORS=$(ps -axo pid=,pgid=,stat= 2>/dev/null \
            | awk -v g="$spec_pid" '$2 == g && $3 !~ /^Z/ { print $1 }')
        [ -z "$SURVIVORS" ] && break
        if [ "$sweep_polls" -ge 4 ]; then
            SURVIVOR_COUNT=$(printf '%s\n' "$SURVIVORS" | grep -c .)
            # Name what is about to be killed (best-effort) — survivor
            # identity is what turns the next R3-F1-class flake into a
            # one-line read instead of an instrumented hunt.
            # Control bytes become '?' before the width cut — survivor args
            # are arbitrary argv, and raw ANSI wrecks the one line that
            # names the leak.
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

    # Echo the spec's own output so users see per-test PASS/FAIL lines.
    cat "$SPEC_OUT"

    # Aggregate the assertion totals from the trailing summary line.
    summary=$(grep -E '^__SPEC_SUMMARY__' "$SPEC_OUT" | tail -1)
    sp=""
    sf=""
    if [ -n "$summary" ]; then
        sp=$(printf '%s' "$summary" | sed -nE 's/.*pass=([0-9]+).*/\1/p')
        sf=$(printf '%s' "$summary" | sed -nE 's/.*fail=([0-9]+).*/\1/p')
        TOTAL_ASSERTS_PASS=$((TOTAL_ASSERTS_PASS + ${sp:-0}))
        TOTAL_ASSERTS_FAIL=$((TOTAL_ASSERTS_FAIL + ${sf:-0}))
    fi
    spec_asserts=$(( ${sp:-0} + ${sf:-0} ))
    sf_n=${sf:-0}

    # FAIL: lines in the transcript — same indent-tolerant anchor the L1
    # runner counts assertions with. Consumed by the accounting arms below.
    FAIL_LINES=$(grep -cE '^[[:space:]]*FAIL:' "$SPEC_OUT" 2>/dev/null || true)
    case "$FAIL_LINES" in ''|*[!0-9]*) FAIL_LINES=0 ;; esac

    # Skip markers (a9hh R7-F2 — see SECTION_SKIP_RE above). Counted for
    # every outcome, but only ANNOTATED on a spec that passed: a failed,
    # timed-out or whole-file-skipped spec is already loud for a louder
    # reason. Mirrors L1.
    SECTION_SKIPS=$(grep -cE "$SECTION_SKIP_RE" "$SPEC_OUT" 2>/dev/null || true)
    case "$SECTION_SKIPS" in ''|*[!0-9]*) SECTION_SKIPS=0 ;; esac

    if [ -f "$TIMEOUT_MARKER" ]; then
        SPEC_FAIL=$((SPEC_FAIL + 1))
        TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
        # a9hh R6-F1/R8-F1: surface what was KILLed, with honest attribution,
        # and what the escalation could not kill — both by name, mirrors L1.
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
        FAILED_SPECS+=("$base (TIMEOUT: killed by the ${SPEC_TIMEOUT_S}s per-spec cap after ${ELAPSED_S}s$LEAK_NOTE$WD_SURV_NOTE)")
        printf -- '--- %s: FAILED — TIMEOUT: killed by the %ss per-spec cap (in %ss; never a pass, never a skip%s%s) ---\n' \
            "$base" "$SPEC_TIMEOUT_S" "$ELAPSED_S" "$LEAK_NOTE" "$WD_SURV_NOTE"
        [ -s "$WD_SURVIVORS" ] && cat "$WD_SURVIVORS"
    elif [ "$spec_rc" -ne 0 ]; then
        SPEC_FAIL=$((SPEC_FAIL + 1))
        FAILED_SPECS+=("$base (rc=$spec_rc in ${ELAPSED_S}s$LEAK_NOTE)")
        printf -- '--- %s: FAILED rc=%s (in %ss%s) ---\n' "$base" "$spec_rc" "$ELAPSED_S" "$LEAK_NOTE"
    elif [ "$SURVIVOR_COUNT" -gt 0 ]; then
        # Exited 0 while its group still held live work (a9hh R2-F2): the
        # transcript it was judged on is incomplete by construction — a late
        # line can be a FAIL: or a SKIPPED: — so this is a FAILURE, never a
        # pass. The work was killed above. ("End", not "reap": a survivor
        # can be a ppid=1 non-child a tool left behind — see L1's note.)
        SPEC_FAIL=$((SPEC_FAIL + 1))
        FAILED_SPECS+=("$base (exited 0 with $SURVIVOR_COUNT background process(es) still running — killed; a spec must end its background work before returning; in ${ELAPSED_S}s)")
        printf -- '--- %s: FAILED — returned with %s live background process(es), killed (in %ss); its output ends wherever they were, so no outcome read from it is complete ---\n' \
            "$base" "$SURVIVOR_COUNT" "$ELAPSED_S"
    # --- FAILED-ACCOUNTING-BEGIN (a9hh R4-F1/R4-F2) --------------------------
    # Three arms between "rc says fine" and "the spec measured something",
    # each closing a way a FAILURE used to read as a SKIP or a PASS:
    #   sf_n     — the summary itself counted failed assertions, but the
    #              wrapper's exit-1-on-FAIL gate was bypassed by an early
    #              builtin exit (bd_required_or_skip after a failing leg —
    #              reproduced: FAIL: in transcript, spec SKIPPED, rc=0).
    #   FAIL_LINES — the transcript holds FAIL: lines the summary never
    #              counted: a backgrounded assert whose counter increment
    #              died with its subshell while its output landed in the
    #              still-linked capture file (a9hh R4-F2, reproduced), or a
    #              spec that re-armed EXIT and lost the summary trap.
    #   missing summary — rc=0 with no __SPEC_SUMMARY__ line at all: an
    #              exec-replacement or a clobbered EXIT trap. FAILED loudly,
    #              never SKIPPED — an accounting bypass must not read as
    #              "measured nothing".
    # Excising this region restores the pre-fix classifier;
    # runner-completeness.test.sh section 12 drives that mutant.
    elif [ "$sf_n" -gt 0 ]; then
        SPEC_FAIL=$((SPEC_FAIL + 1))
        FAILED_SPECS+=("$base (exited 0 while its summary counted $sf_n failed assertion(s) — an early exit bypassed the fail gate; in ${ELAPSED_S}s)")
        printf -- '--- %s: FAILED — exited 0, but its summary counted %s failed assertion(s) (early exit bypassed the fail gate; in %ss) ---\n' \
            "$base" "$sf_n" "$ELAPSED_S"
    elif [ "$FAIL_LINES" -gt 0 ]; then
        SPEC_FAIL=$((SPEC_FAIL + 1))
        first_fail=$(grep -m1 -E '^[[:space:]]*FAIL:' "$SPEC_OUT" 2>/dev/null \
            | LC_ALL=C tr -c '[:print:]\n\t' '?' \
            | sed 's/^[[:space:]]*//' | cut -c1-160)
        FAILED_SPECS+=("$base (exited 0 over $FAIL_LINES FAIL: line(s) its summary never counted — first: $first_fail; in ${ELAPSED_S}s)")
        printf -- '--- %s: FAILED — exited 0, but its transcript holds %s FAIL: line(s) the summary never counted (in %ss) ---\n' \
            "$base" "$FAIL_LINES" "$ELAPSED_S"
    elif [ -z "$summary" ]; then
        SPEC_FAIL=$((SPEC_FAIL + 1))
        FAILED_SPECS+=("$base (exited 0 without a __SPEC_SUMMARY__ line — exec-replacement, or an EXIT trap re-armed without chaining __spec_wrapper_exit; in ${ELAPSED_S}s)")
        printf -- '--- %s: FAILED — exited 0 without the summary line, so its accounting was bypassed (re-arm EXIT traps with __spec_wrapper_exit; in %ss) ---\n' \
            "$base" "$ELAPSED_S"
    # --- FAILED-ACCOUNTING-END (a9hh R4-F1/R4-F2) ----------------------------
    elif [ "$spec_asserts" -eq 0 ]; then
        # Exit 0 with zero executed assertions: bd_required_or_skip /
        # net_required_or_skip exits before the summary line (the summary
        # trap still prints pass=0 fail=0), and a spec whose every section
        # skipped reports the same. Either way it measured nothing — a skip,
        # never a pass.
        SPEC_SKIP=$((SPEC_SKIP + 1))
        skip_reason=$(grep -m1 '^SKIPPED:' "$SPEC_OUT" 2>/dev/null || true)
        [ -z "$skip_reason" ] && skip_reason="exited 0 with zero executed assertions"
        SKIPPED_SPECS+=("$base — $skip_reason")
        printf -- '--- %s: SKIPPED, not a pass (in %ss) — %s ---\n' \
            "$base" "$ELAPSED_S" "$skip_reason"
    # --- L2-PARTIAL-BEGIN (a9hh R7-F2) ---------------------------------------
    # Passed what it ran, but its transcript carries a skip marker: it did
    # not run all of itself, and an unqualified PASSED over that transcript
    # is the a9hh section-skip defect one tier down (measured: post-edit.sh
    # PASSED(101) of 115 under BD_SHIM_ONLY=1). Excising this region
    # restores that world; runner-completeness.test.sh drives the mutant.
    elif [ "$SECTION_SKIPS" -gt 0 ]; then
        SPEC_PASS=$((SPEC_PASS + 1))
        SPEC_PARTIAL=$((SPEC_PARTIAL + 1))
        first_marker=$(grep -m1 -E "$SECTION_SKIP_RE" "$SPEC_OUT" 2>/dev/null \
            | sed 's/^[[:space:]]*//' | cut -c1-160)
        PARTIAL_SPECS+=("$base — $SECTION_SKIPS skip marker(s), $spec_asserts assertion(s) ran; first: $first_marker")
        printf -- '--- %s: PASSED but INCOMPLETE (%s assertion(s) in %ss; %s skip marker(s) — see PARTIAL below) ---\n' \
            "$base" "$spec_asserts" "$ELAPSED_S" "$SECTION_SKIPS"
    # --- L2-PARTIAL-END (a9hh R7-F2) -----------------------------------------
    else
        SPEC_PASS=$((SPEC_PASS + 1))
        printf -- '--- %s: PASSED (%s assertion(s) in %ss) ---\n' \
            "$base" "$spec_asserts" "$ELAPSED_S"
    fi
    # Name whatever the sweep killed. Outside the sentinel region: with the
    # sweep excised SURVIVOR_IDS stays empty and this is a no-op.
    if [ "$SURVIVOR_COUNT" -gt 0 ] && [ -n "$SURVIVOR_IDS" ]; then
        printf '%s\n' "$SURVIVOR_IDS" | while IFS= read -r survivor_line; do
            printf '    survivor: %s\n' "$survivor_line"
        done
    fi
    rm -f "$SPEC_OUT" "$TIMEOUT_MARKER" "$WD_SURVIVORS"
done

printf '\n=== Summary ===\n'
printf 'Specs:      Total: %d  Passed: %d  Failed: %d  Skipped: %d  Partial: %d\n' \
    "$TOTAL" "$SPEC_PASS" "$SPEC_FAIL" "$SPEC_SKIP" "$SPEC_PARTIAL"
printf 'Assertions: Passed: %d  Failed: %d\n' \
    "$TOTAL_ASSERTS_PASS" "$TOTAL_ASSERTS_FAIL"
if [ "$TIMEOUT_COUNT" -gt 0 ]; then
    printf 'Timed out (counted in Failed): %d spec(s) at the %ss per-spec cap\n' \
        "$TIMEOUT_COUNT" "$SPEC_TIMEOUT_S"
fi

if [ "$SPEC_FAIL" -gt 0 ]; then
    printf 'Failed specs:\n'
    for f in "${FAILED_SPECS[@]}"; do
        printf '  - %s\n' "$f"
    done
fi
if [ "$SPEC_SKIP" -gt 0 ]; then
    printf 'Skipped specs (NOT passes):\n'
    for f in "${SKIPPED_SPECS[@]}"; do
        printf '  - %s\n' "$f"
    done
fi
if [ "$SPEC_PARTIAL" -gt 0 ]; then
    printf 'PARTIAL — passed, but a skip marker says it did not run all of itself (a9hh R7-F2):\n'
    for f in "${PARTIAL_SPECS[@]}"; do
        printf '  - %s\n' "$f"
    done
fi
if [ "$SPEC_SKIP" -gt 0 ] || [ "$SPEC_PARTIAL" -gt 0 ]; then
    printf 'COMPLETENESS: %d of %d spec(s) skipped, %d partial — the assertion totals above describe only the executed subset.\n' \
        "$SPEC_SKIP" "$TOTAL" "$SPEC_PARTIAL"
fi

# --- FILTER-ZERO-MATCH-BEGIN (a9hh R4-F3/R5-F2) ------------------------------
# A filter that selects NOTHING is an invocation error, never a green run.
# The L1 runner grew this guard (with its paired control, leg 6.3) in the
# same round that left this runner without it — and QA hit the gap for real:
# both runners filter with BRE grep, so the natural ERE alternation
# `--filter 'qa-gate|bd-compat'` matches no basename literally, and the
# pre-fix summary here read `Total: 0 ... rc=0` in 0.16s — this task's
# defect sentence, exit-0 over a spec set that executed nothing.
# runner-completeness.test.sh section 12 carries the L2 twin of leg 6.3.
if [ -n "$FILTER" ] && [ "$TOTAL" -eq 0 ]; then
    printf 'run.sh: --filter %s matched no spec files — nothing ran, so nothing passed\n' \
        "$FILTER" >&2
    finish 2
fi
# --- FILTER-ZERO-MATCH-END (a9hh R4-F3/R5-F2) --------------------------------

if [ "$SPEC_FAIL" -gt 0 ]; then
    finish 1
fi

finish 0

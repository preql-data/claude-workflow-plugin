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

# Hoisted above TELEMETRY-DISARM (claude-workflow-plugin-gsfd): the dolt-side
# half of that region needs $PROJECT_DIR to name the embedded store, and nothing
# between here and its old position depended on THIS being defined later.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"

# --- TELEMETRY-DISARM-BEGIN (a9hh R3-F1; extended claude-workflow-plugin-gsfd/7tfe) ---
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

# claude-workflow-plugin-gsfd (7tfe): bd EMBEDS dolt, and the embedded engine
# spawns ITS OWN telemetry flusher ("dolt send-metrics") that the export above
# cannot reach — icn4's fix round measured the leaked survivor BY NAME (ppid=1,
# /opt/homebrew/bin/dolt send-metrics) inside this very runner's own
# runner-completeness.test.sh, coming from a nested bd-calling fixture.
# MEASURED DIRECTLY, not inferred from `dolt config --help`: `dolt sql -r csv
# -q "SELECT hashof('HEAD')"` against .beads/embeddeddolt/beads with no local
# config spawned the flusher 4/4 trials (`ps -axo pid,ppid,args` polled every
# 50ms for 5s after each call, filtered to the genuine `dolt send-metrics`
# argv — grep noise from the polling harness's own argv excluded); the
# identical command spawned it 0/4 trials once `dolt config --local --add
# metrics.disabled true` was set inside that same directory. `--local` writes
# to .beads/embeddeddolt/beads/.dolt/config.json, which .beads/.gitignore
# already excludes (`embeddeddolt/`) — confirmed via `git check-ignore -v` —
# so this never touches the user's global dolt config
# (~/.dolt/config_global.json, confirmed empty on both sides of the
# experiment) and never enters a change-set hash. Idempotent: `--add` on an
# already-true key overwrites cleanly rather than growing a multivar
# (verified via `dolt config --local --list` after 4 repeated applications).
# Guarded exactly like STORE-CANARY's own existence checks further down: a
# checkout with no embedded-Dolt store (store-less CI, or a pre-1.1.x bd
# install) has nothing to disarm, and a host with no `dolt` binary on PATH is
# a no-op rather than an error.
disarm_dolt_telemetry() {
    local store="$1"
    [ -d "$store/.dolt" ] || return 0
    command -v dolt >/dev/null 2>&1 || return 0
    ( cd "$store" && dolt config --local --add metrics.disabled true ) >/dev/null 2>&1 || true
    return 0
}
disarm_dolt_telemetry "$PROJECT_DIR/.beads/embeddeddolt/beads"
# --- TELEMETRY-DISARM-END (a9hh R3-F1 / claude-workflow-plugin-gsfd) ---------

# claude-workflow-plugin-gsfd (member 5, the lease): sourced early so the
# runner can answer "who else is active" and report itself the same way, no
# matter how far along argument parsing gets before something exits. Missing
# lib degrades to "run without lease visibility" — never a hard failure: an
# ownership signal that cannot be recorded is not grounds to refuse running
# the tier it is meant to inform (same fail-open-on-absence shape as
# workflow-denylist.sh's own missing-lib guard below in verify-before-stop.sh,
# stated once so it does not need restating at every call site).
TREE_LEASE_AVAILABLE=0
_TL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || _TL_DIR=""
if [ -n "$_TL_DIR" ] && [ -f "$_TL_DIR/../tree-lease.sh" ]; then
    # shellcheck source=.claude/scripts/tree-lease.sh
    . "$_TL_DIR/../tree-lease.sh" && TREE_LEASE_AVAILABLE=1
fi

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
#
# THIS NUMBER AND `ls .claude/scripts/tests/*.test.sh | wc -l` DISAGREE BY
# CONSTRUCTION, ALWAYS BY EXACTLY ONE: discovery below is `find ... -name
# '*.sh' ! -name 'run-tests.sh'`, not a `*.test.sh` glob, so
# phase5-synthetic-tests.sh (no `.test.sh` suffix) counts here but not there.
# Verify a bump against a clean `make test` run, never against a file count.
#
# 39 -> 40 (claude-workflow-plugin-icn4 item 1): added
# reviewer-lane-structural.test.sh, the correction-10 structural guard hoisted
# out of the L2 component tier so a violation is caught at every `make test`
# rather than only at that tier's reserved ~65-minute cadence.
#
# 40 -> 41 (claude-workflow-plugin-fkm.4, Phase D2 Part A): added
# design-rubric.test.sh, covering the design-reviewer prompt's D0-placeholder
# removal and the automatic workflow-manifest.sh classification of the new
# .claude/rubrics/design.md file. design.md's own frontmatter/DS1-DS8 shape
# checks did NOT add a spec — they extended the existing per-rubric sweep in
# qa-gate-grade-record.test.sh's Section 8 instead.
#
# 41 -> 42 (claude-workflow-plugin-fkm.4, Phase D2 Part B): added
# design-review-record.test.sh, covering the new design-verdict recording
# subcommand (B1: grammar, validation, independence at record time),
# amendments (B2: iteration-advance + `[amends: <prev-hash>]`), the
# design-satisfied refusal cmd_approve now enforces (B3, with its own
# META-TEST), the cap_terminated predicate wired into REVIEW-SEPARATION (B4),
# and design-gate-precheck (B5).
#
# 42 -> 43 (claude-workflow-plugin-fkm.5, Phase D3): added
# grilling-record.test.sh, covering the new `qa-gate.sh grilling-record`
# subcommand (validation ladder, the vendored method's own approaches>=2
# bar, and the live vendor_hash recompute), and design-record's new
# GRILLING-PRECONDITION (refusal with no GRILLING v1 record on the task or
# its parent epic, success on either, the audited --no-grilling bypass, and
# a METatest proving the precondition block is load-bearing).
#
# 43 -> 44 (claude-workflow-plugin-gsfd, the D4 concurrency-ownership
# prerequisite): added tree-lease.test.sh, covering the new
# .claude/scripts/tree-lease.sh library (acquire/release/conflicts/
# reclaim-stale, the mktemp-suffix bug its own build caught, and the
# pipefail/errexit safety fix lease_conflict_summary needed). The heartbeat
# this line originally listed alongside those was cut in round 6's DESIGN
# COLLAPSE together with the mechanism it tested — see tree-lease.test.sh's
# own header (its old section 9) for the full account.
#
# 44 -> 45 (claude-workflow-plugin-gsfd fix round 1, independent review by
# sol-codex): added scoped-log-dir.test.sh, covering verify-before-stop.sh's
# run_scoped_log_dir / scoped_log_nonce / reap_stale_run_log_dirs — the
# per-run log-path mechanism (member 1) that had ZERO direct test coverage
# before R1-F1 found its own central claim was false (a plain FILE at
# `.claude/.qa-tracking/runs` made the pre-fix function collapse to the
# SAME shared QA_TRACKING_DIR every other concurrent run in that state was
# ALSO handed — the exact collision the batch exists to remove).
#
# NOTE: this comment's own trail was already 45 while EXPECTED_SPECS read 47
# before this entry — two intermediate bumps (45->46, 46->47) landed
# undocumented here, most likely elsewhere in the same gsfd batch. Not
# reconstructed retroactively; flagging rather than guessing at them.
#
# 47 -> 48 (claude-workflow-plugin-fkm.6, Phase D4 first slice): added
# design-conform.test.sh, covering the new `qa-gate.sh design-unit-bind`
# subcommand (argument validation, artifact/unit-membership resolution, the
# bjx unit_id scalar class with its own METatest, and the re-binding
# decision — an existing binding refuses a second write unless
# `--rebind '<reason>'`), the new DESIGN-UNIT v1 record + its reader
# (latest_design_unit_binding), and the new `qa-gate.sh design-conform`
# subcommand (the resolution ladder propagating compute_design_satisfied's
# own keys verbatim, the undeclared/unbuilt computation including the
# absolute-vs-relative path-spelling normalisation this build's own
# development surfaced as a real risk, the denylist exclusion, honest
# degradation on every dependency including a jq-free jq_unavailable
# message, the TOCTOU bracket shared with design-record's own hardening,
# and a METatest proving the undeclared_files gate itself is load-bearing).
# `epic-gate.sh plan-batches` was a separate, later slice as of this entry —
# see the 49 -> 50 bump below, which is that slice landing.
#
# 48 -> 49 (claude-workflow-plugin-6im2): added
# design-unit-bind-parity.test.sh. D4a shipped `design-unit-bind` (the
# writer) with no caller anywhere in .claude/agents/, docs/ or skills/ — the
# reader (design-conform) was fully tested but resolved a binding nothing
# wrote, so every real call took the fail-closed unit_not_in_design path.
# This spec is NOT a behavioural test of design-unit-bind itself
# (design-conform.test.sh already owns that); it is a carrier-parity census
# over `.claude/agents/orchestrator.md` and
# `.claude/skills/workflow-engine/SKILL.md` (the two prompt surfaces this
# task's fix added the invocation to), grounded in one live,
# APPLICATION-STATE read-only call to the shipped script for the flag names
# it asserts on — read-only toward bd/repo/tracking state (it exits before
# require_bd), but NOT file-creation-free: the no-args branch prints
# usage()'s here-document, which bash materialises via a temp file, so the
# call fails closed where file creation is denied (wording corrected in the
# 6im2 round-8 review, R8-F5, to match the spec's own header, which had
# already corrected the same claim under S6-F2) —
# plus a four-leg META-TEST per carrier (strip, prove the strip landed,
# confirm the census names exactly that carrier as missing, restore control).
# Measured at the time of this bump: this specific reconciliation is racing
# `epic-gate.sh plan-batches`'s own new spec (still absent from disk as of
# this edit — see the note in the entry immediately above); whichever of the
# two lands second owns the next bump, 49 -> 50.
#
# 49 -> 50 (claude-workflow-plugin-fkm.6, Phase D4b): added
# plan-batches.test.sh, landing second in the race the entry above names.
# Covers the new `epic-gate.sh plan-batches <epic-id> [--design <path>]`
# (docs/plans/v5-design-phase.md:158-159): the positive arm (a real
# multi-unit batch, built FIRST per this tier's own pairing convention,
# since degradation collapses to one-unit-per-batch and would otherwise make
# every mutant below vacuous); the determinism leg (byte-identical repeat
# runs, and a reorder of the SAME units changing the plan, proving artifact
# order — never `unit_files | keys`, which sorts — is genuinely read); all
# five mutants the release directive specifies, each four-part paired
# (non-vacuity, specific misbehaviour, restore control, execution) —
# Mutant 1 (union accumulation: compare a candidate against a batch's FULL
# file union, never just its most recent member), Mutant 2 (THE META-TEST
# docs/plans/v5-design-phase.md:159 pre-specifies verbatim: a fail-open
# wrapper around the batching computation reads an INDUCED jq failure,
# forced via a marker-matching jq shim, as "everything parallel" instead of
# degrading), Mutant 3 (the one guard with no redundant downstream backup —
# an unbound child's danger is silently invisible, not merely re-caught by
# another check, when its sentinel is stripped; verified during this build
# that the WIDER outer sentinel is NOT a clean strip target: every other
# guard is independently fail-closed, so removing any one still degrades via
# another, and stripping the whole outer region breaks the function's own
# brace matching and does not even parse), Mutant 4 (jq absence: a curated
# PATH with everything but jq confirms the hand-built literal is reached,
# not merely that the process fails to start), and Mutant 5 (dependency
# order: two units with disjoint files, one depending on the other, must
# not co-batch even though file-set intersection alone would allow it) —
# plus seven direct probes of the remaining guard conditions (no design
# attempted propagated WITHOUT design-gate-precheck's own leniency; zero
# children; a binding to a unit an amendment dropped; a stale binding
# design_hash; two tasks bound to one unit; a non-canonical declared path;
# and the --design flag as an ASSERTION in both directions, never a second
# source for the artifact). BD-FREE by design (a hand-authored `bd` shim
# behind canned per-task JSON, plus a directly-written design artifact —
# review-check.sh validate-design needs no bd at all): the unit<->task
# mapping path (design-unit-show, and therefore every Category-C guard) has
# no live caller anywhere in this tree as of this entry (claude-workflow-
# plugin-6im2 wired the PROMPT surfaces, not a live run), so this spec's
# coverage of that path is fixture-only, built explicitly rather than
# implied. `cmd_shared_files` and its own L2 spec are untouched.
#
# 50 -> 51 (claude-workflow-plugin-xsu1 fix round, review artifact h2r1 —
# the previously-UNREVIEWED half of the D4b slice): added
# design-accessors.test.sh, the first DIRECT coverage of the two read-only
# qa-gate.sh accessors plan-batches shells out to (`design-unit-show`,
# `design-status`) — until this round no test anywhere invoked
# design-unit-show at all, and plan-batches.test.sh reaches both only
# through epic-gate.sh over well-formed canned fixtures, a path that cannot
# present a FAILING source. Covers, four-part paired per the tier
# convention: H2-F2 (an unreadable binding source — bd failing, unparseable
# comments — is ok:false/design_binding_unreadable/exit 2, never the
# determined answer bound:false; sed-mutant restoring the pre-fix call-site
# guard misbehaves in exactly the pre-fix way), H2-F3 (the binding is
# validated ONCE against the full union shape; an induced failure of exactly
# that classifier call — marker-matched jq shim, fired-file non-vacuity —
# refuses rather than emitting bound:true with empty required fields),
# H2-F5 (design-status distinguishes design_source_unreadable, ok:false/
# exit 2 with satisfied:false retained, from no_design_attempted, ok:true/
# exit 0; sentinel-strip META brings back the masquerade the guard exists to
# prevent — the key design-gate-precheck maps to "ready"), and H2-F4 (an
# induced failure of each accessor's final `jq -nc` envelope build yields
# the caller-data-free envelope_construction_failed literal, parseable, at
# exit 2 — never malformed output under exit 0). Same fake-bd/canned-JSON
# harness shape as plan-batches.test.sh, so the whole spec runs in seconds.
# H2-F1 (the validate-design final-extraction guard in review-check.sh) did
# NOT add a spec: it extended design-artifact.test.sh's existing Section 2
# with a Section 2b, per this tier's put-it-with-its-subject convention.
#
# 51 -> 52 (claude-workflow-plugin-i8cx, units U3+U4): added
# qa-gate-pipefail.test.sh, covering qa-gate.sh's change-set evidence chain
# under FAILED reads — the masked-pipeline class where an upstream failure
# returned an empty set at rc 0 (write_gate_baseline's dead :327 handler, the
# :402 exclusion build, gate_baseline_entries, reconcile_tracker's
# sort/comm reads, design_foreign_paths, sha256_file). Each guard is paired
# with a PATH-shim fault injection against the SHIPPED script, a mutant that
# restores the pre-fix mask and demonstrates the named masquerade, and the
# two restore controls an over-eager refusal would break first (clean tree
# reconciles rc 0; clean checkout captures entries=0 ok:true).
#
# 52 -> 53 (claude-workflow-plugin-i8cx, unit U1 + the verify-before-stop
# half of U7): added change-set-undeterminable.test.sh — the paired guard
# for the Stop hook's new "a failed read is not an empty change set"
# refusal. reviewable_changes() used to read the tracker through a process
# substitution and git through a `git | sort` pipeline, so an unreadable
# changed-files.txt, a failing tracker sort/comm, or a failing `git status`
# produced the SAME empty stream as a clean session and the hook RELEASED
# (`{}`) — measured live at ee7ce328 with nothing more exotic than
# `chmod 000` on a non-empty tracker, full shipped stack, no shims. The spec
# drives the extracted-from-shipped function (sentinel-only output on each
# induced failure, including the anti-truncation discriminator a
# pipefail-shaped fix would fail: a git-half fault must suppress the
# already-computed tracker half), the SHIPPED hook end-to-end (the guard's
# specific block on each fault; `{}` + no sentinel byte on a clean sandbox;
# restore controls), the VANISHED-CHANGE-SET probe at the W3 detect-stack
# seam (fault -> the LABEL_WITHOUT_RECORD block stands with an honest
# "probe UNDETERMINABLE" log; genuine vanish -> still releases, the gz3
# anti-overreach control), the U7 current-task reads (an unreadable
# current-task.repo ARMS the I8 cross-repo block instead of disarming it;
# an unreadable current-task marker logs "read FAILED" instead of the false
# "empty or missing"), and a sentinel-strip META reproducing the exact
# pre-fix `{}` release on a mutated copy.
# ---------------------------------------------------------------------------
EXPECTED_SPECS=53

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

# --- LEASE-ACQUIRE-BEGIN (claude-workflow-plugin-gsfd, member 5) -----------
# "Who else owns this tree right now" as a READ, not an inference from
# ppid/start-time by hand (9xl4: three near-misses in one session, each
# caught only because an agent happened to check). A missing library or a
# lease-directory failure degrades to "run without visibility", never to
# refusing the tier: this signal informs a reader, it is not a precondition
# for the suite to run.
#
# DESIGN COLLAPSE (claude-workflow-plugin-gsfd, operator-directed, round 6):
# this runner does NOT heartbeat its own lease, and nothing else in this
# codebase does either. Two rounds (R3-F3, R4-F3) built and hardened a
# heartbeat here; a third (R5-F2/R5-F4) found the hardened version still
# cost a background process per tick. The lease is now report-only (see
# tree-lease.sh's own DESIGN COLLAPSE header): nothing ever auto-removes a
# lease on the strength of its age, so there is nothing left for a
# heartbeat to protect — a crash mid-tier simply leaves this lease sitting,
# read STALE by the next checker. Full causal account: CHANGELOG.md.
LEASE_FILE=""
if [ "$TREE_LEASE_AVAILABLE" = "1" ]; then
    LEASE_FILE=$(lease_acquire "$PROJECT_DIR/.claude/.qa-tracking" "L1" \
        "run-tests.sh${FILTER:+ --filter $FILTER} pid=$$") || LEASE_FILE=""
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

# finish <code> — the ONLY place the scratch dir (and this run's lease, if
# one was acquired) is removed, and the ONLY way this runner exits once the
# scratch exists. Never called from an EXIT trap (see the R5-F1 note above);
# on_interrupt calls it LAST, after its guard, so the interrupt path cleans
# up exactly once.
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

# State vars initialised OUTSIDE the sentinel region below, same convention
# as SURVIVOR_COUNT/SURVIVOR_IDS/LEAK_NOTE further down: the paired control
# (runner-completeness.test.sh) excises the ARM region from a COPY, and that
# mutant must still run under `set -u` — every later reference to these four
# (the per-spec sampling block, the verdict elif, and the tail summary's
# DISARMED reprint, none of which live inside THIS sentinel) must see a safe
# default rather than an unbound-variable abort. An excised ARM behaves as
# permanently DISARMED, not as a crash.
PROTECTED_STORE="$PROJECT_DIR/.beads"
STORE_CANARY_ARMED=0
STORE_CANARY_DISARM_REASON="the STORE-CANARY-ARM region did not run"
STORE_HASH_BEFORE=""
# --- STORE-CANARY-ARM-BEGIN (claude-workflow-plugin-j7kk) -------------------
# THE STRUCTURAL GUARD. A per-spec write-state canary on the protected Beads
# store, keyed on STORE STATE, never on a test marker. It exists because
# model-roles.test.sh — one of THIS runner's own 39 specs — was measured
# CAN-REACH(WRITE) against production: 417 repo-root-cwd bd calls in one run
# (186 comment, 151 show, 35 create, 35 list, 10 --version), landing 9,937+
# synthetic `MODEL SWITCH` comments on a real task before that spec was fixed
# (claude-workflow-plugin-j7kk census). The other 38 specs are isolated by
# SEVEN different, undeclared conventions (cd into a fixture store; explicit
# `bd -C <dir>`; a fixture `bin/bd` stub; a callee that cds itself; a
# store-independent subcommand; no bd call on the path at all) and nothing
# states which is required — so a future spec author can reproduce exactly
# this defect, and nothing here would notice until someone went looking for
# 9,937 comments by hand. Prevention has to be structural: a harness-level
# guard that fails ANY spec whose environment resolves to the production
# store, by name, rather than a per-spec fix the next author can omit.
#
# A per-writer guard (teach each of bd's ~11 write-capable production
# scripts to refuse under a test marker) was rejected on two measured
# grounds: it is per-writer, so the next bd-calling script omits it exactly
# as model-select.sh:927 omitted the `.beads`-presence half of its own
# availability guard; and it relocates harness-building into production
# code, which this repo's own conventions (CLAUDE.md) treat as a smell.
#
# DETECTION PREDICATE: `dolt sql -q "SELECT hashof('HEAD')"` on the protected
# store. Chosen over `bd context`'s cwd-resolution check (constant across
# all 39 specs today — a REACHABILITY precondition, not a guard) and over a
# dolt-CLI-free manifest hash (stability was measured, sensitivity to a
# write was not — see the task's OQ-2). Cost ~0.12s/call, measured zero
# false positives across 12 consecutive bd reads plus dolt SELECTs in the
# same census; every bd write auto-commits, so a moved hash is real.
#
# THE PROTECTED STORE IS DERIVED, NEVER HARDCODED. PROJECT_DIR already
# honors CLAUDE_PROJECT_DIR (see above), so the paired control in
# runner-completeness.test.sh points this same mechanism at a SEEDED
# FIXTURE store via the runner's existing lever — no new env knob, and no
# need to contaminate production to prove the anti-contamination guard
# works. A guard that hardcoded "$PROJECT_DIR/.beads" could only be paired
# by causing the harm it exists to prevent, and would ship unpaired.
if ! command -v dolt >/dev/null 2>&1; then
    STORE_CANARY_DISARM_REASON="dolt is not on PATH"
elif [ ! -d "$PROTECTED_STORE/embeddeddolt/beads/.dolt" ]; then
    STORE_CANARY_DISARM_REASON="$PROTECTED_STORE/embeddeddolt/beads/.dolt does not exist (no embedded-Dolt store here — a store-less CI checkout, or a pre-1.1.x bd install)"
else
    STORE_HASH_BEFORE=$(cd "$PROTECTED_STORE/embeddeddolt/beads" 2>/dev/null \
        && dolt sql -r csv -q "SELECT hashof('HEAD')" 2>/dev/null | tail -n1)
    case "$STORE_HASH_BEFORE" in
        ''|*[Hh]ashof*) STORE_CANARY_DISARM_REASON="could not read hashof('HEAD') from $PROTECTED_STORE (dolt query failed)"
                        STORE_HASH_BEFORE="" ;;
        *)              STORE_CANARY_ARMED=1 ;;
    esac
fi
if [ "$STORE_CANARY_ARMED" = "1" ]; then
    printf 'STORE-CANARY: ARMED — watching %s for unattributed writes during this run\n' "$PROTECTED_STORE"
else
    # HONEST DEGRADATION, LOUD AND COUNTED, NEVER A SILENT PASS. A store-less
    # CI checkout has nothing to contaminate, so this does not fail the tier
    # — but a permanently-DISARMED guard is indistinguishable from a working
    # one unless every run says so, both here and in the summary.
    printf 'STORE-CANARY: DISARMED — %s; this run cannot detect writes to %s\n' \
        "$STORE_CANARY_DISARM_REASON" "$PROTECTED_STORE"
fi
# --- STORE-CANARY-ARM-END (claude-workflow-plugin-j7kk) ---------------------

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

    # State vars initialised OUTSIDE the sentinel, same convention as
    # SURVIVOR_COUNT/SURVIVOR_IDS/LEAK_NOTE above: the paired control excises
    # exactly the sentinel-delimited region from a COPY, and the excised
    # mutant must still run under `set -u`, behaving as if this spec had
    # never been sampled at all.
    STORE_WRITES=0
    STORE_NOTE=""
    STORE_DETAIL=""
    # --- STORE-CANARY-BEGIN (claude-workflow-plugin-j7kk) ---------------------
    # Sampled HERE — after `wait "$spec_pid"` and after the survivor sweep —
    # so a spec that backgrounded a writer has already been reaped or killed
    # before this spec's "after" hash is taken; a write from that backgrounded
    # process still counts (it happened during this spec's window), it is
    # simply attributed at the earliest point it can be READ safely.
    #
    # Sampling carries the PREVIOUS spec's "after" as the next spec's
    # "before" (STORE_HASH_BEFORE is reassigned at the bottom of this block,
    # never reset per-iteration) — 40 hashof calls across a 39-spec tier, not
    # 78: one at arm time, one per spec thereafter.
    if [ "$STORE_CANARY_ARMED" = "1" ]; then
        STORE_HASH_AFTER=$(cd "$PROTECTED_STORE/embeddeddolt/beads" 2>/dev/null \
            && dolt sql -r csv -q "SELECT hashof('HEAD')" 2>/dev/null | tail -n1)
        if [ -n "$STORE_HASH_AFTER" ] && [ "$STORE_HASH_AFTER" != "$STORE_HASH_BEFORE" ]; then
            STORE_WRITES=$(cd "$PROTECTED_STORE/embeddeddolt/beads" 2>/dev/null \
                && dolt log --oneline "$STORE_HASH_BEFORE".."$STORE_HASH_AFTER" 2>/dev/null | wc -l | tr -d ' ')
            case "$STORE_WRITES" in ''|*[!0-9]*) STORE_WRITES=1 ;; esac
            STORE_DETAIL=$(cd "$PROTECTED_STORE/embeddeddolt/beads" 2>/dev/null \
                && dolt log --oneline "$STORE_HASH_BEFORE".."$STORE_HASH_AFTER" 2>/dev/null | head -8)
            # claude-workflow-plugin-j7kk R1-F2: the hash MOVED (this `if`
            # only runs when it did) but the double-dot range can still
            # legitimately report ZERO lines — not the empty-or-non-numeric
            # shape the case guard above catches, but the well-formed numeric
            # string "0" itself. That happens when AFTER is NOT reached by NEW
            # commits on top of BEFORE: a mid-run rollback/reset (the
            # v65-to-v53 schema rollback performed during this very batch is
            # the live example of the class) moves HEAD to an ANCESTOR of
            # BEFORE, so every commit reachable from AFTER is also reachable
            # from BEFORE and the range is empty by construction; a `dolt log`
            # call that fails transiently right after a successful `hashof`
            # read degrades identically. Either way the store moved, and this
            # canary must not read that as clean — "0 writes" was never a
            # measurement of "nothing happened", only of "the range had
            # nothing in it", and those are different claims. Escalate to the
            # same STORE_WRITES=1 shape a genuine single write takes (so the
            # dedicated FAIL arm below fires) with a DETAIL that names the
            # actual observation instead of a fabricated commit count.
            if [ "$STORE_WRITES" = "0" ]; then
                STORE_WRITES=1
                STORE_DETAIL="NON-LINEAR store movement: HEAD moved from $STORE_HASH_BEFORE to $STORE_HASH_AFTER but \`dolt log $STORE_HASH_BEFORE..$STORE_HASH_AFTER\` reported no commits — AFTER is not reachable via new commits on BEFORE (a rollback/reset-class move), or dolt log failed transiently after a successful hashof read"
                STORE_NOTE="; the protected Beads store moved from $STORE_HASH_BEFORE to $STORE_HASH_AFTER by a NON-LINEAR change (not a chain of new commits — a rollback/reset-class move, or a transient dolt-log failure) while it ran"
            else
                STORE_NOTE="; the protected Beads store advanced by $STORE_WRITES commit(s) while it ran"
            fi
        fi
        # Carry forward regardless of whether this spec moved it — a NO-OP
        # write compares equal next iteration; a real move becomes the next
        # spec's baseline, so a later spec is never blamed for an earlier
        # one's commits.
        [ -n "$STORE_HASH_AFTER" ] && STORE_HASH_BEFORE="$STORE_HASH_AFTER"
    fi
    # --- STORE-CANARY-END (claude-workflow-plugin-j7kk) -----------------------

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
        FAILED_FILES+=("$base (TIMEOUT: killed by the ${SPEC_TIMEOUT_S}s per-spec cap after emitting $ASSERTS assertion(s)$LEAK_NOTE$WD_SURV_NOTE$STORE_NOTE)")
        printf -- '--- %s: FAILED — TIMEOUT at the %ss per-spec cap (%s assertion(s) emitted in %ss; never a pass, never a skip%s%s%s) ---\n' \
            "$base" "$SPEC_TIMEOUT_S" "$ASSERTS" "$ELAPSED_S" "$LEAK_NOTE" "$WD_SURV_NOTE" "$STORE_NOTE"
        [ -s "$WD_SURVIVORS" ] && cat "$WD_SURVIVORS"
    elif [ "$rc" -ne 0 ]; then
        FAIL=$((FAIL + 1))
        FAILED_FILES+=("$base (rc=$rc, $ASSERTS assertion(s) in ${ELAPSED_S}s$LEAK_NOTE$STORE_NOTE)")
        printf -- '--- %s: FAILED rc=%s (%s assertion(s) in %ss%s%s) ---\n' \
            "$base" "$rc" "$ASSERTS" "$ELAPSED_S" "$LEAK_NOTE" "$STORE_NOTE"
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
        FAILED_FILES+=("$base (exited 0 with $SURVIVOR_COUNT background process(es) still running — killed; a spec must end its background work before returning; $ASSERTS assertion(s) in ${ELAPSED_S}s$STORE_NOTE)")
        printf -- '--- %s: FAILED — returned with %s live background process(es), killed (%s assertion(s) in %ss)%s; its output ends wherever they were, so no outcome read from it is complete ---\n' \
            "$base" "$SURVIVOR_COUNT" "$ASSERTS" "$ELAPSED_S" "$STORE_NOTE"
    # --- STORE-CANARY-BEGIN (claude-workflow-plugin-j7kk) ---------------------
    # A DEDICATED arm for a spec that would otherwise be entirely green but
    # moved the protected store. Placed immediately after the SURVIVOR_COUNT
    # arm and before TRANSCRIPT-FAIL, so a spec already failing for one of
    # the reasons above keeps that reason (STORE_NOTE is appended to each of
    # them instead); this arm exists for the spec that is not already red.
    #
    # L1 cannot attribute a Dolt commit to a PROCESS — no writer identity is
    # recorded store-side (census, section 2.2 item 3: label writes carry no
    # timestamp or attribution at all, and comment-writer provenance is
    # self-reported and was WRONG in the one case measured, claiming a
    # SessionStart apply for a write a test run actually made). So this is a
    # REACHABILITY failure of the tier, not proven authorship: either this
    # spec wrote, or another process wrote concurrently while it ran — both
    # mean L1 ran against a live production store, and every record left
    # behind is test-authored and must not be read as evidence.
    #
    # It does NOT roll back (deliberate — see the ARM block and the task's
    # own measurement: genuine agent writes interleave with a contaminating
    # spec in the same window, and an automatic revert would destroy real
    # work alongside the synthetic records).
    elif [ "$STORE_WRITES" -gt 0 ]; then
        FAIL=$((FAIL + 1))
        FAILED_FILES+=("$base (contaminated the protected Beads store: advanced by $STORE_WRITES commit(s) while this spec ran; $ASSERTS assertion(s) in ${ELAPSED_S}s)")
        printf -- '--- %s: FAILED — the protected Beads store %s advanced by %s commit(s)\n' \
            "$base" "$PROTECTED_STORE" "$STORE_WRITES"
        printf '    while this spec ran. L1 cannot attribute a Dolt commit to a process, so this is a\n'
        printf '    REACHABILITY failure of the tier, not proven authorship: either this spec wrote, or\n'
        printf '    another process wrote concurrently — both mean L1 ran against a live production store.\n'
        printf '    Commits below. Every record left by a spec is test-authored and must not be read as evidence. ---\n'
        [ -n "$STORE_DETAIL" ] && printf '%s\n' "$STORE_DETAIL" | sed 's/^/    /'
    # --- STORE-CANARY-END (claude-workflow-plugin-j7kk) -----------------------
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
if [ "$STORE_CANARY_ARMED" != "1" ]; then
    printf 'STORE-CANARY: DISARMED — %s; this run could not detect writes to %s\n' \
        "$STORE_CANARY_DISARM_REASON" "$PROTECTED_STORE"
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

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
#   EXPECTED_SPEC_FILES_STRICT — TEST-HARNESS-ONLY; there is no legitimate
#             reason to set this by hand, in CI, or in a Makefile target.
#             Default (unset) is 1 -- the completeness floor's identity
#             comparison against EXPECTED_SPEC_FILES below is unconditional
#             and can fail the run on its own. 0 restores the pre-gytz-R2-F2
#             count-only comparison for a single invocation. CORRECTED
#             (claude-workflow-plugin-gytz R3-F3): this paragraph used to say
#             run_l1/run_l1_env_bdactor "set" this variable. They do not --
#             neither function body assigns it (QA's round-3 review measured
#             21 mentions of the name in runner-completeness.test.sh against
#             9 real assignments; re-verified here with the same count). The
#             ONLY place that ever sets a DEFAULT is that file's own
#             top-level `export EXPECTED_SPEC_FILES_STRICT=0`, read once near
#             the top of the file; every other assignment is a plain shell
#             prefix (`EXPECTED_SPEC_FILES_STRICT=1 run_l1 ...`) applied AT
#             THE CALL SITE of run_l1/run_l1_env_bdactor, not inside them --
#             it shadows the export for exactly that one command and its
#             subprocess, then reverts, which is what lets that spec's own
#             ~30 pre-existing sections (which build fixtures out of
#             generic, count-sized stub-NNN.sh names to test UNRELATED
#             runner mechanics, never claiming to model this repo's real
#             spec inventory) pass on the export's default without renaming
#             every one of them to a real spec basename, while the handful
#             of sections that DO need strict mode override it at their own
#             call site instead. See the EXPECTED_SPEC_FILES array's own
#             header below, and the COMPLETENESS-FLOOR block, for the full
#             account. Accepted values: 1/yes/true/unset and 0/no/false;
#             anything else is an invocation error, same reasoning as
#             STRICT_SECTIONS above.
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

# --- STORE-CANARY ATTRIBUTION: REMOVED (claude-workflow-plugin-gytz) -------
# A per-run BEADS_ACTOR marker used to live here, feeding attribute_store_
# advance()'s self-vs-external attribution decision (formerly further down
# this file). That decision, and the marker that fed it, was deleted under
# the standing waiver ruling after failing three consecutive independent
# review rounds: round 0, a `case` guard plus `sed -E` where a no-match
# returned the line unchanged and exonerated the write; round 1, a
# self-verifying `sed -nE '.../p'` defeated by a commit subject that merely
# quoted the marker text; round 2, a companion check that verified two
# subjects held equal parsed strings but never that they came from one
# invocation. claude-workflow-plugin-u443: the operations a real spec's own
# writes actually perform (comment/update/close/label) carry no actor at
# all on bd 1.3.0, so the mechanism could not have fired in its own
# motivating case either. DETECTION (did the protected store's HEAD differ
# AFTER a spec's window from what it was BEFORE) is unaffected and lives on
# below, unattributed: a spec whose window leaves HEAD net-changed fails,
# loudly, by name — it just no longer tries to say who. Replacement: SPEC
# ISOLATION (claude-workflow-plugin-h5lw) — if a spec cannot reach the
# production store, there is no authorship question to adjudicate. Nothing
# here is dormant; there is no flag to re-enable it.
#
# KNOWN LIMIT (R3-F2, round 3, independent review): two ENDPOINT samples —
# one before a spec's window, one after — can only prove NET HEAD CHANGED.
# H0 -> H1 -> back to EXACTLY H0 inside one spec's window is invisible to
# this check by construction: a rollback landing on a DIFFERENT ancestor IS
# caught (the range comparison sees a non-descendant move — see the R1-F2
# NON-LINEAR handling below), but an exact round trip nets to no change and
# there is nothing left to compare against. Every comment and every message
# this file emits about detection is worded to that contract — NET HEAD
# CHANGED — and no stronger. Reaching a stronger contract would require
# durable history/audit evidence: parsing dolt's own commit log as an
# authorizing/exonerating signal, which is EXACTLY the free-form-vendor-text
# mechanism deleted above after three failed review rounds, and precisely
# what this project's standing lesson forbids. Not built here; not planned.
# Under SPEC ISOLATION (-h5lw) this limit costs nothing: on a store no spec
# can legitimately reach at all, there is no genuine advance to restore, so
# an undone move is not a scenario worth paying a parser for — a spec that
# somehow DID touch the protected store and then restored it exactly would
# still have proven the store was reachable, which is the actual property
# isolation exists to rule out, and detection's coarser NET CHANGED contract
# is sufficient for that job.
# -----------------------------------------------------------------------

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
#
# 53 -> 54 (claude-workflow-plugin-i8cx, wave 2 group C): added
# beads-ledger.test.sh — no prior L1 spec exercised this script's internal
# logic at all. classify()'s record-comparison chain (record_meta,
# parse_failures, and the comm/join legs it feeds) ran five unguarded
# pipelines; a crashing jq inside record_meta made $lm/$fm silently EMPTY,
# which compares as "every ledger record is accounted for" — the verdict
# `export`'s own dry-run reads to decide whether its data-loss warning is
# needed. The spec drives the SHIPPED script end-to-end against an isolated
# fixture-local bd database (never the live project's): mutants revert
# record_meta/parse_failures to their pre-fix single-pipe shapes and
# reproduce the false reassurance; the shipped script, same fault, refuses
# instead. workflow-manifest.sh's scan_flat/scan_tree (a process
# substitution masking a failed `find`, so a manifest install.sh --verify
# compares against could silently miss rows) and epic-gate.sh's ONE process
# substitution (_pb_degrade's sort, which could silently emit a
# non-deterministic batch order rather than refuse) did not add specs —
# their coverage was folded into the existing workflow-manifest.test.sh
# (Section 8) and plan-batches.test.sh (9v) respectively, since both already
# drive the right shipped artifact. worktree-sweep.test.sh (Sections C/D)
# likewise gained coverage in place rather than a new file.
#
# 54 -> 55 (claude-workflow-plugin-yzo9): added override-disclosure.test.sh.
# No prior spec covered detect-stack.sh's read_override at all (i8cx shape 1:
# a bare pipeline as a function's return value — a `head` that fails to read
# an existing, non-empty override file returned rc=0 with an EMPTY value,
# INDISTINGUISHABLE from a healthy empty read, and the caller silently
# blanked an already auto-detected TEST_CMD), nor verify-before-stop.sh's
# override_active/override_scope_names/checks_scope_claim/checks_scope_note
# disclosure of an active .claude/*-cmd override (detect-stack.sh had emitted
# the `overrides` object since F8/J17 and said in its own header comment that
# it was tracked for exactly this; nothing ever read it — `grep -c override
# verify-before-stop.sh` returned 0 on every commit before this task). Both
# matter together because this same task ARMS an override for real
# (.claude/test-cmd -> `make test-fast`, the narrowed Stop tier this task
# adds), so the Stop hook depends on both being correct on every Stop from
# here on. The spec drives four extracted functions directly (read_override;
# override_active, whose mutation — override_active always reporting no
# stage overridden — is the one that silences override_scope_names AND the
# checks_scope_note per-stage tag TOGETHER, catching a two-sources-of-truth
# shape this build's own mutation testing surfaced before it could become a
# live drift; checks_scope_claim; checks_scope_note) AND drives the REAL,
# unmodified verify-before-stop.sh end to end against a sandboxed project
# tree (Section C — narrowed and unnarrowed, the pairing convention's own
# negative control), reproducing the mk_sb/run_hook sandbox shape
# change-set-undeterminable.test.sh already uses, self-contained rather than
# coupled to that file (under concurrent edit elsewhere in this change set).
#
# 55 -> 56 (claude-workflow-plugin-i8cx, R3-F2b WIRING): added
# design-gate-precheck-wiring.test.sh. verify-before-stop.sh's
# DESIGN-DISCIPLINE block used to skip calling `qa-gate.sh
# design-gate-precheck` ENTIRELY whenever the matching approval record
# carried the literal `[design bypass:` marker — a blind substring match
# that could not distinguish "no design phase, permanently skip" from "a
# design that was satisfied and unconflicted a moment ago, re-check it still
# is," so a conflict filed after a bypassed approval never re-armed the Stop
# hook. Fixed by making the call unconditional. This spec drives the REAL,
# unstubbed verify-before-stop.sh + qa-gate.sh + bd end to end (Section 1: an
# ordinary --no-design approval on a satisfied, unconflicted design, confirm
# release; file a conflict afterward, confirm the SAME task now blocks
# citing it; a sibling task with NO design phase at all, confirm --no-design
# still releases — the anti-overreach control without which the fix would
# deadlock every doc-only commit) plus a stubbed qa-gate.sh discriminator
# (Section 2: a stub that always refuses design-gate-precheck only blocks
# the marker-present case AFTER this fix, proving the unconditional call is
# genuinely consulted and not a dead call whose result is discarded; a stub
# that always reports ready is the restore control, proving no spurious
# blocking). override-disclosure.test.sh and gate-claim-honesty.test.sh (the
# R5 override-disclosure work landing in the same file concurrently) were
# re-run, unmodified, and confirmed at their existing counts (130 and 297
# assertions respectively) to show no regression.
#
# claude-workflow-plugin-i8cx, independent review rounds 6-8 (operator
# ruling): Section 1's own mechanism changed AGAIN, after this note was
# written. It originally exercised R3-F2b via qa-gate.sh's unit-scoped
# waiver subtraction (waive unit U1 via --no-design, file a conflict on a
# never-waived unit U2, confirm the SAME task now blocks citing U2 and not
# U1). That waiver mechanism — DESIGN-GATE-PRECHECK-UNIT-SCOPE, the
# `[design conflict waived: units=<ids>]` disclosure, and
# DESIGN-BYPASS-UNNEEDED-REFUSAL — was REMOVED after four independent HIGH
# findings (forgeable text, wrong-hash-bound, blanket-not-per-record
# subtraction, a clearing predicate that accepted a content edit with no
# accompanying review). Section 1 now proves the identical R3-F2b property
# (the unconditional call survives and drives the Stop decision) without a
# waiver: an ordinary --no-design approval on a satisfied, unconflicted
# design, followed by a conflict filed afterward — see that spec's own
# header for the full history and design-review-record.test.sh's Section 8h
# for the dedicated negative control (text/label/flag forgery, all proven to
# authorize nothing). EXPECTED_SPECS stayed at 56 for that round — no spec
# was added or removed, only Section 1's own scenario changed shape.
#
# 56 -> 57 (claude-workflow-plugin-k6re, R6-F1, independent review,
# independently reproduced by the orchestrator end to end before dispatch):
# added review-bypass-anchor.test.sh. verify-before-stop.sh's
# matching_approval_record_text selected "the last matching QA-GATE APPROVED
# record" via `jq -r ... | tail -1` — jq -r prints each selected .text value
# RAW, so a multi-line record (a genuine approval whose summary spans lines,
# or a genuine --no-review reason with an embedded newline) emitted MULTIPLE
# SHELL LINES for a SINGLE jq value, and tail -1 returned the last LINE of
# the last such value, never the last RECORD — broken for one matching
# multi-line comment regardless of how many comments matched. Both
# directions were live: a forged trailing `reviewed_by=none ... [review
# bypass:]` line appended after a genuine approval granted an unearned
# audited bypass; a genuine multi-line --no-review approval was wrongly
# refused because its own trailing operator note was selected instead of
# the record. Fixed by selecting the last matching value INSIDE jq
# (`[ generator ] | if length > 0 then .[-1] else empty end`) rather than a
# shell-side tail -1, per the operator's family-level ruling to remove the
# mechanism rather than re-guard it. The spec extracts the three real
# functions (bd_show_with_comments, matching_approval_record_text,
# approval_text_has_audited_review_bypass) from the shipped script and
# drives all six scenarios against a REAL bd store, plus a META section
# with a frozen pre-fix mutant reproducing both bug directions exactly
# while every anti-overreach case (ordinary single-line approval, ordinary
# single-line bypass, no-match) stays byte-identical to shipped.
#
# 57 -> 58 (claude-workflow-plugin-k6re, R6-F2, independent review, round 6):
# added approve-success-gate.test.sh. cmd_approve's hash-aware idempotency
# no-op could report status=approved without ever consulting --expect-hash —
# the SECOND independently-found reach-around of the same arm A2/i8cx already
# fixed once (over compute_design_conflict_open). Fixed with a structural
# gate rather than a third hand-copied inline guard: emit_approve_success
# (APPROVE-SUCCESS-GATE, qa-gate.sh, immediately above cmd_approve) is now the
# ONLY place the script prints a raw status=approved envelope for this
# subcommand — both of cmd_approve's success-reporting exits (the idempotent
# no-op, and the fresh-approval path's own tail) call it instead of printing
# directly. This spec is the STRUCTURAL half, hoisted straight to L1 the same
# way reviewer-lane-structural.test.sh hoisted correction 10's guard: pure
# grep/text-injection, no fixture, no bd, seconds not minutes. It pins the
# two counts that make the chokepoint real rather than assumed (exactly one
# raw `emit_json 1 "approve" "$tid" "approved"` in the shipped script,
# exactly two calls into emit_approve_success), with a non-vacuity META that
# injects a gate-bypassing raw emission into a copy and confirms the count
# would flip — the shape a FIFTH reach-around of this same arm would take.
# The BEHAVIOURAL proof (a real approve, a real mismatch, a real refusal,
# plus an anchor-revert META on the check itself) is the L2 tier's
# approve-idempotency.sh Section J/JM, not duplicated here.
#
# Landed the same review round as the 56 -> 57 bump immediately above
# (claude-workflow-plugin-k6re R6-F1, verify-before-stop.sh): two independent
# specialists each added one spec file to fix two independent findings from
# the same round, concurrently, neither visible to the other's diff. Both
# bumps are individually correct; the counter itself cannot represent two
# concurrent +1s landing in the same window — tracked as its own defect by
# the orchestrator, not fixed here.
#
# 58 -> 59 (claude-workflow-plugin-pqnd, operator-ruled correction): added
# approval-record-disclosure-claim.test.sh. The release gate's approval
# record cannot be tamper-evident (the writer, qa-gate.sh approve, and a
# forger both have `bd comment` access, and no secret the gate holds is
# unreadable to a local writer) but qa-gate.sh and verify-before-stop.sh
# called it that in six operator-/developer-facing places, plus two more the
# six-site audit's case-sensitive search missed (an ALL-CAPS "TAMPER-EVIDENT
# APPROVAL RECORD" in qa-gate.sh, a mixed-case "tamper-EVIDENT record" in
# verify-before-stop.sh's approval_binding_attests — the second co-renders
# into the SAME emit_block call as the corrected operator-facing text, so it
# had to move with it). Corrected the claim to the real threat model
# (OMISSION and STALENESS detection, not FORGERY detection) at all eight
# sites; kept the control exactly as it was — this is wording plus a test,
# not a behaviour change. The new spec's negative control is
# case-insensitive and markdown-emphasis-agnostic on purpose (that is what
# the case-variant sites needed), and its runtime-observed leg drives the
# shipped LABEL-WITHOUT-RECORD-BLOCK region (new sentinel pair, same
# convention as APPROVAL-BINDING-TEXT) for real rather than grepping source.
#
# 59 -> 60 (claude-workflow-plugin-268l): added design-conflict-subject-
# resolution.test.sh. design-conflict (the writer, cmd_design_conflict) and
# its reader (compute_design_conflict_open) used to take the task-id they
# were invoked with as the SUBJECT unconditionally — the task whose
# docs/specs/<id>.md and comment stream a conflict is filed against and read
# from. Under v5 task-per-unit a unit task's own id and the design task that
# actually owns its governing docs/specs/<id>.md differ BY CONSTRUCTION (a
# DESIGN-UNIT binding names the real owner), so asking either function about
# a bound unit task asked about a comment stream that structurally could
# never hold the record — the writer hard-refused (design_artifact_not_
# found) and the reader silently read a conflict-free stream as "no
# conflict". Fixed via a new shared resolve_design_conflict_subject, and
# proved via TWO sentinel-wrapped mutants (DESIGN-CONFLICT-READER-SUBJECT-
# RESOLUTION, DESIGN-CONFLICT-WRITER-SUBJECT-RESOLUTION) that reproduce the
# pre-fix misdirection live: a conflict filed against a bound unit task is
# invisible to the reader mutant and unfileable under the writer mutant, and
# visible/fileable again under the shipped script — each mutant additionally
# discriminated against a still-correct unbound-task control, ruling out "the
# mutant is just globally broken". Also pins the answered design question
# (an unbound task falls back to itself, byte-identical to the pre-fix
# behaviour — NOT a vacuous "nothing to check") and pairs the new backend.md/
# frontend.md/devops.md producer-wiring prose (a structural census plus a
# leg that the named subcommand is actually recognised by the CLI
# dispatcher).
#
# 60 -> 61 (claude-workflow-plugin-k6re, test-suite split, 2026-09-12): NOT
# new coverage — review-separation.test.sh's Sections 7 through 8.14 (the
# UNRECORDED-REVIEW-ARTIFACT-REFUSAL family and its review-reconcile
# governance, added across independent review rounds 13-16) moved verbatim
# into a new file, unrecorded-review-artifact.test.sh. The pre-split file
# had grown from 955 to 2146 lines (2.2x) across those rounds and, run
# standalone with no watchdog, completed all 264 assertions in ~1000s real
# time — over this file's own SPEC_TIMEOUT_S=900 cap, not merely close to
# it (QA round 16 had measured 227/227 in 849s before the round's own
# fix-verification legs, Sections 8.12-8.14, pushed it over: the full L1
# tier killed it at 250 assertions, tree dc4a4c8d, 2026-09-10 16:25:52).
# 94 of the 264 assertions stayed behind in review-separation.test.sh's
# Sections 1-6; 170 moved (167 call-sites in the new file; the +3 is a
# single `for i in 3 1 4 2` loop around one assert_eq in old Section 8.3,
# which runs four times — a static grep of assert_* call sites therefore
# undercounts the moved file's own runtime total by exactly 3, not a
# transcription loss). Both halves measured standalone, alone, nothing else
# running (`/usr/bin/time -p bash <file>`, this tree): review-separation.
# test.sh 94/94 in 315.62s real (35% of the 900s cap);
# unrecorded-review-artifact.test.sh 170/170 in 676.60s real (75.2% of the
# cap) — the tighter of the two, closer to the line than declared safe, so
# flagged plainly rather than rounded down. See both files' own headers for
# the full account.
#
# 170 -> 185 (claude-workflow-plugin-k6re R17-F1 fix round, 2026-09-13): the
# same file gained Section 8.15/8.15.M (15 assertions) pairing-testing the
# R17-F1 fix. `/usr/bin/time -p bash unrecorded-review-artifact.test.sh`,
# standalone, no other load: 185/185 assertions, exit 0, 756.16s real
# (implementer); 771.35s (QA's independent confirming run, same tree). See
# the SPEC_TIMEOUT_S comment below for the updated headroom this moves.
#
# 61 -> 63 (claude-workflow-plugin-fkm.7 D5 piece 3, 2026-09-14): added TWO
# new files for the four green-to-green completion-contract fields (unit_id,
# design_hash, green_before, green_after — docs/plans/v5-design-phase.md
# Phase D5):
#   - validate-completion-green-fields.test.sh (43 assertions) — the four
#     fields' required/type/value checks in review-check.sh
#     cmd_validate_completion, plus a META-TEST stripping the whole
#     GREEN-FIELDS-VALIDATION region from a copy and proving the mutant then
#     accepts a payload missing all four fields (and a bare, unchecked
#     `green_before: "green"` claim) that the shipped script still refuses.
#     Needs no bd fixture — validate-completion is a stateless JSON
#     validator — so this spec runs in well under a second standalone.
#   - green-check.test.sh (119 assertions as of QA round 5, fkm.7 D5 — see
#     the CORRECTIONS below; 57 when this file was first added) — `qa-gate.sh
#     green-check <tid> --phase before|after`: runner=none/green/red across
#     bound and unbound tasks, the phase=before+bound+red refusal
#     (cannot_start_from_green) and its phase=after non-refusal, argument
#     errors, design_binding_unreadable on a never-created task id, and a
#     META-TEST that hardcodes the green/red derivation on a COPY of
#     qa-gate.sh to always claim green — the mechanical form of the plan's
#     own "stub the suite result to claim green while red" line — and shows
#     the mutant both mis-reports an actually-red command AND (the named
#     consequence) lets a BOUND unit past the start gate it should have
#     stopped at, while the shipped script, same fixture, still reports red
#     and still refuses. Needs a real bd fixture (mirrors review-
#     separation.test.sh's shape); standalone runtime is dominated by real
#     `bd create`/`bd comments add` subprocess calls across ~15+ seeded
#     tasks.
#
#     CORRECTION (QA round 3, R3-F5): this trail said "57 assertions" through
#     a round (R2-F2) that actually shipped 67 (a Section 10 hang/timeout
#     leg, +10) without updating this comment — caught, not by inspection,
#     but by literally running `bash green-check.test.sh` and reading its own
#     "Total: N Passed: N" line, the same instrument run-tests.sh itself uses
#     (`grep -cE '^[[:space:]]*(PASS|FAIL):'`).
#
#     CORRECTION (QA round 4, R4-F2): green_check_run has TWO dispatch arms
#     (the elapsed-time HEURISTIC arm when timeout/gtimeout is on PATH, the
#     marker-based WATCHDOG arm when neither is), and the 88-assertion count
#     the round-3 correction above left standing was itself the R4-F2 defect
#     in miniature — EVERY one of those 88 assertions ran on THIS host, which
#     lacks both binaries, so all 88 exercised the watchdog arm ONLY; the
#     heuristic arm (the exact code R4-F1's --help claim was about) executed
#     ZERO times, and a count that looks host-independent while covering
#     only one of two arms is precisely the "measurement that did not happen
#     looking identical to one that passed" shape LESSONS.md:282 names. Per
#     R4-F2's own binding repair, this comment now says WHICH ARM each
#     section covers, not just a bare total:
#       Section 10 (WATCHDOG arm, FORCED via a PATH_NO_TIMEOUT ALLOWLIST --
#         see the R5-F2 CORRECTION below for why "filter" became
#         "allowlist") — cap enforcement, tree-kill.
#       Section 11 (WATCHDOG arm, same PATH_NO_TIMEOUT force) — timed_out
#         disambiguation, airtight on this arm (R3-F1).
#       Section 13 (HEURISTIC arm, FORCED via a `timeout` PATH shim so it
#         runs on ANY host, real binary present or not) — timed_out on this
#         arm is a best-effort elapsed-time inference, NOT airtight (R4-F1,
#         R5-F1). THE REAL BOUND (R5-F1, stated here rather than just
#         referenced): a self-124 landing anywhere in the real-duration
#         window (cap-1, cap] can measure AT the cap and read as a false
#         positive, with probability equal to the start instant's
#         sub-second fraction; only a 124 landing MORE than one second
#         before the cap is guaranteed to read false. "Case G is the one
#         false positive" would itself be the same overclaim in miniature —
#         case G (self-124 landing exactly at the cap) is the one
#         IRREDUCIBLE false positive, not the only possible one. Cases
#         A/B/D/E/F are controls; 13.C-STATIC ALONE proves the R4-F3 fix (a
#         timing-independent grep) — case C itself is a generous-margin
#         control that passes identically against the UNFIXED predicate too
#         and proves nothing about R4-F3, credited to case C through QA
#         round 4, corrected in round 5 (R5-F6) once it was shown a
#         behavioural leg at the actual cap-1 boundary is inherently
#         probabilistic (R5-F1), which is exactly why 13.C-STATIC, not a
#         boundary race, is the right instrument.
#       Section 14 (arm-independent — QA_TRACKING_DIR resolution happens
#         before dispatch) — tracking_dir_unwritable refuses rather than
#         silently reporting a phantom red for a suite that never ran,
#         covering BOTH the directory-missing-and-uncreatable case (R4-F4)
#         and the directory-exists-but-lost-its-write-bit case R4-F4's own
#         fix did not close (R5-F3).
#
#     CORRECTION (QA round 5, R5-F4): the paragraph that used to follow
#     this one said a static grep read "113, not 115" for this file, MEANT
#     as another instance of the R3-F5 static-undercounts-runtime gap. That
#     figure and its causal explanation were BOTH wrong, independent of the
#     round-5 additions below. `grep -c 'assert_eq'` = 113 (then) counts the
#     FUNCTION DEFINITION `assert_eq() {` as if it were a call site and
#     drops every `assert_contains` call entirely -- not a call-site count
#     at all. The correct static instrument is `grep -cE
#     '^[[:space:]]*assert_(eq|contains) '` (line-anchored, both assertion
#     helpers, excludes the definitions): at the round-4 state that read
#     116, not 113, and the true relationship ran the OTHER direction --
#     116 static EXCEEDS 115 runtime because exactly one assertion (8.6,
#     `if command -v timeout` gating a hang-safety check) is host-gated and
#     skipped on a host lacking a real timeout binary; 116 - 1 = 115. On a
#     host WITH timeout, 8.6 would run and the static and runtime figures
#     would match exactly. "Static undercounts runtime" was backwards in
#     both the earlier round's arithmetic AND its causal story.
#
#     88 -> 115 -> 119 (+27 at round 4: Section 10/11 gained explicit
#     dispatch/timed_out assertions when they were retrofitted to FORCE the
#     watchdog arm rather than rely on host luck; Section 13 and Section 14
#     were new. +4 at round 5: Section 10.0b, the allowlist's own negative
#     control (R5-F2); Section 14.1b, the existing-but-unwritable case
#     (R5-F3)). Deliberately NOT presented as a per-section sum -- the
#     authoritative figure is `bash green-check.test.sh`'s own
#     "Total: N Passed: N" line, re-measured three consecutive times this
#     round, all 119/119. The static cross-check, correctly computed
#     (`grep -cE '^[[:space:]]*assert_(eq|contains) ' .claude/scripts/tests/
#     green-check.test.sh`), reads 120 on this host today; 120 - 1
#     (the same host-gated 8.6) = 119, matching the runtime total. This
#     count is NOT expected to move again on its own — it is the number of
#     PASS/FAIL lines one specific spec file emits on this host today, not
#     a quantity with a count-independent expression the way
#     EXPECTED_SPECS's own file-count is. If it drifts, re-run the spec and
#     read its own total, and re-run the static cross-check with the
#     command above rather than hand-adjusting either figure from memory.
#
# 63 -> 66 (claude-workflow-plugin-fkm.7 D5 piece 4, 2026-09-14): added
# THREE new files for the per-unit alignment check (docs/plans/
# v5-design-phase.md Phase D5: "the unit's criteria have tests, the touched
# files fall within the declared set..., and the injected design_hash
# matches the currently bound artifact"):
#   - validate-completion-criteria-tests.test.sh (43 assertions) — the
#     fifth v5 D5 field's required/type/value checks in review-check.sh
#     cmd_validate_completion (criteria_tests: shape, the criteria_tests_
#     without_unit_id one-directional rule, and the tests_added cross-
#     reference), plus a META-TEST stripping the whole CRITERIA-TESTS-
#     VALIDATION region from a copy and proving the mutant then accepts a
#     payload missing the field entirely (and an INVENTED, undeclared test
#     reference) that the shipped script still refuses. Needs no bd
#     fixture, same reason validate-completion-green-fields.test.sh does
#     not: validate-completion is a stateless JSON validator.
#   - design-artifact-parity.test.sh (23 assertions) — the ez9h fix: two
#     design-artifact path resolvers (qa-gate.sh's design_artifact_path_for,
#     the WRITER and every other reader; subagent-start.sh's OWN raw
#     construction) used to disagree on a design_task containing `+` (legal
#     per that field's own grammar), so spec injection degraded on every
#     spawn for such an id. Extracts BOTH shipped sanitisers by awk, proves
#     the `tr` invocations are byte-identical text, then RUNS both
#     extracted functions (never just compares source) across a `+`-bearing
#     id and confirms they resolve the SAME path, with a META-TEST
#     reproducing the pre-fix raw construction and showing it disagrees on
#     the exact input that was the defect. No bd fixture needed — pure
#     string-derivation functions, no filesystem or Beads access.
#   - design-unit-align.test.sh (64 assertions, MEASURED via this spec's own
#     "Total: N Passed: N" line, QA round 1 on fkm.8, R1-F8 correction —
#     this ledger previously said 44, qa-gate.sh:13996 separately said 66;
#     all three mentions across the tree now agree) — `qa-gate.sh design-unit-
#     align` itself: not-applicable when unbound; LEG 1 (files, reused from
#     design-conform, propagated verbatim); LEG 2 (freshness, reused from
#     spec-injection-status; injected:false legal, fresh:false is not); LEG
#     3 (criteria have tests — no implementer record, incomplete coverage,
#     an unknown criterion id, green_after not green, a malformed/missing-
#     file/missing-label test reference, and the full success path); wiring
#     into `approve`'s DESIGN-ALIGNMENT-REFUSAL (a misaligned bound task
#     refuses, exit 2; an aligned one does not); and a METatest proving that
#     refusal block is load-bearing. This is the FIRST spec to drive
#     `approve` on a real v5 task-per-unit CHILD task at all (design-
#     conform.test.sh never calls approve; design-review-record.test.sh's
#     own tasks own their design directly, never through a DESIGN-UNIT
#     binding) — building it surfaced two structural findings neither
#     predecessor could have, both recorded in this file's own comments and
#     in qa-gate.sh: DESIGN-SATISFIED-REFUSAL does not resolve through the
#     DESIGN-UNIT binding the way design-conform/design-unit-align do, so
#     every such child's `approve` needs `--no-design` (matching design-
#     artifact.test.sh's own established convention, extended here rather
#     than reinvented); and design-conform itself, never previously
#     exercised against a change set that had been through a REAL review
#     cycle, flagged review-record's own canonical artifact
#     (docs/reviews/<tid>-r<n>.json) as undeclared_files on every such
#     task's first alignment/approval attempt — fixed at the shared root
#     (qa-gate.sh's REVIEW-ARTIFACT-EXCLUSION, inside cmd_design_conform
#     itself, task-specific, never a blanket docs/reviews/ exemption) and
#     covered by design-conform.test.sh's own new Section 17, not only
#     here, since every OTHER caller of design-conform inherits the fix.
#     Needs a real bd fixture, same shape as design-conform.test.sh; nearly
#     all of its runtime is real `bd create`/`bd comments add`/`approve`
#     subprocess calls across three epic+child pairs and roughly a dozen
#     completion-record cycles.
#
# 66 -> 67 (claude-workflow-plugin-fkm.8 D6, 2026-09-15): added ONE new
# file for the coherence rollup gate (docs/plans/v5-design-phase.md Phase
# D6: "the gate rolls up per-unit results into an epic-level count, in the
# manner of the unresolved-findings count"):
#   - design-coherence.test.sh (55 assertions — `bash .claude/scripts/tests/
#     design-coherence.test.sh`'s own "Total: N Passed: N" line, the
#     authoritative figure per this comment's own established convention
#     above) — `qa-gate.sh
#     design-coherence`: NOT APPLICABLE when the task is not itself a
#     satisfied design task (the ordinary case for a v5 task-per-unit
#     CHILD), NOT APPLICABLE when a satisfied design declares zero units,
#     and NOT APPLICABLE when a satisfied design declares units but has
#     ZERO bd parent-child dependents at all (never decomposed via D4 — a
#     single small task can legitimately be its own design holder with no
#     separate per-unit children; this third not-applicable state is kept
#     as its own section deliberately adjacent to, and distinct from, "a
#     unit with no bound task IN AN EPIC THAT HAS CHILDREN", so the two
#     cannot be confused with each other — see the LESSONS.md entry tagged
#     gate/process for why conflating them is the natural mistake); the
#     five named cases from plan 178, each with its own restore control —
#     (a) a BOUND unit whose criteria_tests is incomplete (reuses
#     compute_design_alignment's own criteria_incomplete verbatim), (b) a
#     unit with NO bound task, in an epic that DOES have real children
#     (task_id empty, its own declared criteria named as uncovered by
#     construction — distinct from the zero-children not-applicable state
#     above by construction, not by assertion, since this section creates
#     real bd children first and leaves them deliberately unbound), (c)
#     undeclared_scope (a resolved unit's completion contract claims a
#     file no unit declares — the epic-wide union check design-conform's
#     own per-task check is never asked), (d) hash divergence (a unit's
#     own DESIGN-UNIT binding hash no longer matches the artifact's
#     current governing hash after an amendment, cleared by re-binding),
#     and (e) tracker/diff mismatch (a file genuinely in the live change
#     set that nothing declares or claims — the 94d-shaped under-coverage
#     case plan 177 exists for, proven DISTINCT from (c) in the same
#     section); wiring into `approve`'s COHERENCE-ROLLUP-REFUSAL (a
#     coherent, satisfied design task approves and its record carries
#     `design_artifact=<ref>@<hash>`, plan 176); and a METatest stripping
#     ONLY the coh_issues-to-count translation step and confirming the
#     SAME undeclared_scope defect Section 8 proved the shipped script
#     catches now clears. Building it surfaced and fixed three defects
#     before this count was reached: a bash 3.2 parser hazard where a
#     LITERAL apostrophe in a double-quoted --arg value, on a
#     backslash-continued line ahead of a single-quoted jq filter,
#     silently corrupted the whole multi-line command (fixed by
#     pre-assigning every such message to a plain variable first — never
#     inlined); a GATE-EVIDENCE-EXCLUSION gap where the rollup's own
#     design artifact and every resolved unit's own review artifact(s)
#     always tripped tracker_diff_mismatch on an otherwise-coherent epic,
#     mirroring design-conform's own REVIEW-ARTIFACT-EXCLUSION one level
#     up; and the zero-children applicability gap above, found only after
#     it regressed several PRE-EXISTING design-review-record.test.sh
#     fixtures that use a single task as both design holder and sole unit
#     of work (each tripped coherence_issues_open on first approval,
#     unrelated to what the fixture was testing) — design-accessors.test.sh
#     also needed a one-line update to its own 11.0c census (3 -> 4 call
#     sites of the shared validate_design_envelope_ok pattern:
#     compute_design_coherence is a legitimate new consumer, confirmed via
#     a full 154/154 re-run in isolation from every other change here).
#     Needs a real bd fixture and a real git repo (unlike design-unit-
#     align.test.sh, this file commits between cycles so reconcile-
#     tracker's git-status scan cannot sweep a later unit's uncommitted
#     work into an earlier unit's own change set); nearly all of its
#     runtime is real `bd create`/`bd comments add`/`approve`/`git commit`
#     subprocess calls across one two-unit epic taken through twelve
#     sequential states.
# ---------------------------------------------------------------------------
# 67 -> 68 (claude-workflow-plugin-fkm.8 D6 JUDGEMENT HALF, 2026-09-15,
# coordinator ruling): docs/plans/v5-design-phase-plan.md:718-737's second
# half — the three whole-system criteria (DS1/DS2/DS8) a mechanical rollup
# cannot answer, judged by a SECOND, cheaper design-reviewer spawn against
# a different packet, root-relayed a second time.
#   - design-rollup.test.sh (73 assertions as of QA round 1 — `bash .claude/
#     scripts/tests/design-rollup.test.sh`'s own "Total: N Passed: N"
#     line, MEASURED after both the split (-7, moved to design-rollup-
#     incoherent.test.sh below — QA round 2, R2-F2 corrected this
#     arithmetic: only SEVEN of the child's 13 assertions moved from here,
#     I.1-I.6b; the other six, I.7-I.9b, are new coverage the child spec
#     itself introduces) and this same round's own new coverage (+3 R1-F1,
#     +3 R1-F3) net against the pre-round 74: 74 - 7 + 3 + 3 = 73) — three new
#     subcommands (`design-rollup-packet`, `design-rollup`,
#     `design-rollup-status`), each proven separately: packet assembly's
#     not-applicable and mechanical-prerequisite refusals with a restore
#     control; the record's reused six-key validation ladder plus this
#     axis's own new checks (required --model, independence, hash-
#     staleness, duplicate-hash) and its exact `DESIGN-ROLLUP v1` grammar
#     on both a genuine coherent and a genuine incoherent verdict;
#     `design-rollup-status` reflecting never-recorded / stale / current;
#     `epic-gate.sh check`'s new block branch with a negative control
#     proving a non-design epic's own pass text is byte-for-byte
#     unchanged; `approve`'s new exit-5 refusal (never-recorded and stale
#     shapes; the incoherent shape moved to design-rollup-incoherent.
#     test.sh below) plus its success path; the mechanical axis (exit 2)
#     proven INDEPENDENT of a recorded coherent rollup by reopening a
#     mechanical issue after recording one; and a METatest — the
#     coordinator's own explicit instruction ("stub the reviewer verdict
#     to always return coherent and assert the gate still refuses when it
#     should") — stripping only DESIGN-ROLLUP-REFUSAL's own hash-
#     freshness comparison to prove a GENUINELY coherent verdict (not a
#     forged one) bound to a superseded hash must still refuse: this
#     axis's trustworthiness was never the verdict's semantic content, it
#     is the binding to current state. Building it surfaced and fixed two
#     defects before this count was reached, both found by driving the
#     shipped code rather than by reading it: a genuine UNBOUNDED
#     RECURSION (epic-gate.sh check -> qa-gate.sh design-rollup-status ->
#     compute_design_coherence -> epic-gate.sh check -> ...), measured
#     live as a runaway subprocess chain during smoke testing before any
#     formal assertion caught it, fixed with a reentrancy guard
#     (QA_GATE_SKIP_EPIC_GATE_REENTRY=1) plus a complementary efficiency
#     guard (EPIC_GATE_SKIP_ROLLUP_CHECK=1) so the fix is bounded AND not
#     wastefully doubling every ordinary design-coherence call; and a
#     `set -e` INTERACTION at all five of this axis's own internal call
#     sites — a bare (non-`||`-guarded) call to a function that can
#     legitimately return non-zero trips this file's own top-of-script
#     errexit and terminates the whole process before the caller's own
#     error envelope is ever built — fixed with the SAME `fn "$tid" ||
#     rc=$?` guard the ORIGINAL compute_design_coherence/
#     cmd_design_coherence pair already used correctly; caught only by
#     this suite's own explicit error_key assertions, not by the looser
#     ad hoc smoke-testing that preceded it. design-reviewer.md gains a
#     "Second invocation" section (prose only, verified against no-
#     nested-spawn-instructions.test.sh's own 16 assertions) and
#     orchestrator.md gains "5f. Coherence-rollup relay".
# ---------------------------------------------------------------------------
# 68 -> 69 (claude-workflow-plugin-fkm.8, QA round 1 on D6, 2026-09-15):
# design-rollup-incoherent.test.sh (13 assertions) split off design-
# rollup.test.sh's own former Section I (R1-F2, HIGH) — self-contained on
# its own epic, needing nothing from the parent file's Setup-through-
# Section-H narrative. Pre-split, both readings (806.83s/823.17s) were
# above the 800s split trigger this comment block already names, against
# SPEC_TIMEOUT_S=900 (1.093x headroom, 76.83s margin) — and the parent
# file's own edits that landed the split had grown it further still
# without anyone updating this ledger's own worst-case figure, which is
# the exact drift class the paragraph two comment-blocks up already
# documents happening "twice now". POST-split (QA round 2, R2-F4 — the
# figure this entry was missing, corrected rather than left as a
# pre-split-only claim): `/usr/bin/time -p bash .claude/scripts/tests/
# design-rollup.test.sh` -> 73/73, exit 0, real 709.07s; `.../design-
# rollup-incoherent.test.sh` -> 13/13, exit 0, real 221.22s. Headroom
# 900/709.07 = 1.269x, margin 190.93s — both measured under CONCURRENT
# load (four competing run-tests.sh --filter processes, load average 3.54
# falling to ~2.5), so these are UPPER bounds, not best cases, and the
# true margin is at least this good. The split costs total tier time even
# as it buys per-spec headroom: 709.07 + 221.22 = 930.29s across the two
# files versus 823.17s for the one (+107.12s, the price of the child's
# own duplicated ~365-line fixture bootstrap against the parent's 451) —
# the right trade against a PER-SPEC cap, stated here rather than
# discovered later. Covers: a genuinely incoherent
# verdict recorded cleanly and `approve` refusing it
# (`design_rollup_incoherent`, one of three now-distinct error_keys — see
# below); and R1-F4's own duplicate-hash-deadlock fix, proven as three
# states in sequence (incoherent -> incoherent still allowed, incoherent
# -> coherent the actual escape the fix exists for, coherent -> anything
# refused again) so the fix reads as narrowed, not removed.
#
# THE SAME ROUND fixed R1-F1 (CRITICAL): reviewer_identity was checked
# only for emptiness before being interpolated raw into the DESIGN-ROLLUP
# v1 machine prefix, PROVEN forgeable against the shipped parser (a
# crafted identity mimicking a second record's own grammar made the
# reader capture a forged coherent verdict) -- fixed with
# assert_record_scalar, the SAME guard design-review-record already
# applies to its own reviewer field; and R1-F3 (HIGH): the packet's union
# diff (`git diff [--stat] "$base...HEAD"`) was simultaneously too wide
# (MEASURED at 9.97x the packet's own byte cap for a D6-scoped change
# alone, sweeping in every commit since the branch diverged from main)
# and BLIND to the actual uncommitted change set this workflow gates (a
# merge-base comparison only ever sees committed history) -- fixed as
# HEAD vs the working tree, with untracked files rendered via `git diff
# --no-index` since ordinary `git diff` never shows them at any base.
# Neither fix added a test file; both are pinned inside design-rollup.
# test.sh's own existing Sections B/C (a non-empty diff observed directly;
# a forged reviewer_identity refused with a non-vacuity check).
#
# 69 -> 71 (claude-workflow-plugin-gytz R1-F2, discovered by QA against the
# unfiltered discovery query): two spec files landed in this same batch and
# neither bumped this line, so the floor's `-ne` comparison was a hard
# failure waiting for the first unfiltered run (the CI l1-unit job; hidden
# so far only because every run so far was `--filter`'d or standalone,
# which disarms the floor). Added:
#   next-work.test.sh (claude-workflow-plugin-90av) -- the Stop hook's
#     release path handing the session its next ready work instead of
#     silently ending it; 75 assertions.
#   review-request-build.test.sh (claude-workflow-plugin-wuu8) -- the Codex
#     review lane's request assembly (diff capture, byte-cap enforcement,
#     lane-agnostic packet building); 61 assertions.
# Swept for a third whole-tree counter neither of the two adding agents
# would have known to bump (the same race shape as EXPECTED_SPECS itself):
# none found. EBF-CORE stays byte-identical across all four agent prompts
# (qa.md, backend.md, frontend.md, devops.md); workflow-manifest.sh
# deliberately excludes .claude/scripts/tests/ (its own :280 comment says
# maxdepth is what keeps it out), so no manifest row was owed either.
#
# 71 -> 72 (claude-workflow-plugin-gytz, same batch, landed AFTER the 69 -> 71
# bump above had already shipped): review-request-diff-budget.test.sh, a
# sibling task's spec, discovered mid-batch by the coordinator re-measuring
# rather than trusting the constant. This is the SAME hole recurring within
# one batch — a hand-integer bumped by whichever agent noticed last is a
# defect generator, not a guard, because "notice" is exactly the step that
# has now failed twice. See the sentinel-delimited spec-name array
# immediately below for the structural fix that replaces the bump mechanism
# itself, not just this one value.
# ---------------------------------------------------------------------------
# --- EXPECTED-SPEC-FILES-BEGIN (claude-workflow-plugin-gytz, second round) --
# THE CLASS, NOT THE INSTANCE. A bare integer here was bumped twice in one
# batch (69 -> 71 -> stale again within the hour, 71 -> 72 above) because a
# COUNT carries no identity: nothing about "71" or "72" tells a reviewer
# WHICH file changed, and nothing about the number ITSELF can be checked for
# correctness except by re-running the same `find` the runner already runs.
# The floor's whole value is comparing a HUMAN-DECLARED expectation against
# DISCOVERED reality — collapsing that expectation to a single digit is what
# made it un-reviewable and easy to forget.
#
# THE FIX: the declaration is now a NAMED LIST, not a count. EXPECTED_SPECS
# below is DERIVED from this array's length (${#EXPECTED_SPEC_FILES[@]}), so
# every existing reference to $EXPECTED_SPECS elsewhere in this file, and
# runner-completeness.test.sh's own $EXPECTED sizing lever, needs zero
# changes beyond how that one count gets produced. What changes is what a
# human touches when a spec is added: ONE LINE naming the file, which is
# exactly what a `git diff` on this region now shows, and exactly what
# "naming the new spec is the fix" (the standing instruction for this round)
# asked for.
#
# TWO OPTIONS WERE ON THE TABLE, and this is the one taken, with the other
# named and rejected:
#   REJECTED: keep EXPECTED_SPECS as a bare integer, and make the BREACH
#   MESSAGE print a name-level diff anyway. This does not save anything: to
#   print "which specs are present and uncounted, which are counted and
#   missing" you need a maintained NAME LIST regardless — an integer alone
#   cannot answer either half of that sentence. Once a name list has to
#   exist for the diagnostic to be honest, making it the PRIMARY declaration
#   (rather than a second, integer-shaped declaration plus a name list kept
#   in sync with it by hand) is strictly less to maintain, not more: one
#   thing to update instead of two, and the two can no longer silently drift
#   from each other because only one of them is hand-written.
#   TAKEN: this array. THIS PARAGRAPH ORIGINALLY SAID the PASS/FAIL decision
#   stayed count-based "unchanged in shape from before this round" so every
#   existing fixture-based test would keep passing on count alone. That
#   claim held for the round it was written in, and stopped being true the
#   moment claude-workflow-plugin-gytz R2-F2 made the identity comparison
#   unconditional (a same-count rename must be caught, and a count-first
#   gate structurally cannot catch one) — a full run of
#   runner-completeness.test.sh at that point showed the predicted cost
#   arriving for real: dozens of this file's own pre-existing sections,
#   sized to $EXPECTED_SPECS with generic names, started failing, because
#   COUNTS MATCH but generic names are never among these 73 real ones. The
#   decision below is now IDENTITY-based by default (comparing the
#   discovered and declared SETS, unconditionally computed) — see
#   EXPECTED_SPEC_FILES_STRICT in the Environment: header above and the
#   COMPLETENESS-FLOOR block for the narrow, test-harness-only escape hatch
#   that keeps this paragraph's original promise (existing fixtures need no
#   renaming) true for the ~30 sections that predate R2-F2, without
#   weakening the check for the one invocation — a real one — that R2-F2 is
#   actually about.
#
# WHAT MUST NOT HAPPEN, stated because it is the single way this fix could
# be quietly undone: EXPECTED_SPEC_FILES must NEVER be computed from the
# same discovery glob the TESTS array below uses (or any equivalent re-scan
# of $TESTS_DIR). That would make the floor compare the discovered set
# against ITSELF — tautologically equal for any set, including an empty one
# or one missing forty specs, which is exactly the vacuity the floor exists
# to eliminate. This array is a STATIC LITERAL and must stay one: no `$(`,
# no backticks, no `find`, no reference to $TESTS_DIR or $PROJECT_DIR
# anywhere inside this sentinel region. runner-completeness.test.sh section
# 19 asserts this directly against the shipped text (not merely a comment
# promise) and separately demonstrates, via a mutant that DOES self-derive,
# that an added-but-undeclared spec then passes silently — the danger this
# paragraph warns about, shown rather than only stated.
#
# Regenerate this list with (sorted to match the `find | sort` the TESTS
# array below already uses, so a diff against discovered reality is a plain
# set comparison):
#   find .claude/scripts/tests -maxdepth 1 -type f -name '*.sh' \
#       ! -name 'run-tests.sh' -exec basename {} \; | sort
# One name per line, nothing else on the line, so both the array-length
# derivation and runner-completeness.test.sh's own extraction (which counts
# non-empty lines between this BEGIN/END pair) stay simple to parse.
EXPECTED_SPEC_FILES=(
    agent-mcp-tools-parity.test.sh
    agent-time-budget.test.sh
    agents-manifest-parity.test.sh
    approval-record-disclosure-claim.test.sh
    approve-success-gate.test.sh
    bd-github-link.test.sh
    beads-ledger.test.sh
    change-set-undeterminable.test.sh
    codex-review-wait-reason.test.sh
    completion-contract-parity.test.sh
    denylist-source.test.sh
    design-accessors.test.sh
    design-artifact-parity.test.sh
    design-artifact.test.sh
    design-coherence.test.sh
    design-conflict-subject-resolution.test.sh
    design-conform.test.sh
    design-gate-precheck-wiring.test.sh
    design-review-record.test.sh
    design-rollup-incoherent.test.sh
    design-rollup.test.sh
    design-rubric.test.sh
    design-structural.test.sh
    design-unit-align.test.sh
    design-unit-bind-parity.test.sh
    doc-only-classifier.test.sh
    effort-fail-open.test.sh
    evidence-before-fix.test.sh
    gate-claim-honesty.test.sh
    green-check.test.sh
    grilling-record.test.sh
    impact-report.test.sh
    installer-flags.test.sh
    judge-calibration.test.sh
    lessons.test.sh
    linux-tier-driver.test.sh
    make-session.test.sh
    mcp-deps-preserve.test.sh
    mcp-deps.test.sh
    mcp-unestablished-results.test.sh
    model-roles.test.sh
    mutation-harness.test.sh
    next-work.test.sh
    no-nested-spawn-instructions.test.sh
    override-disclosure.test.sh
    packaging-parity.test.sh
    phase5-synthetic-tests.sh
    plan-batches.test.sh
    platform-audit.test.sh
    qa-gate-choose.test.sh
    qa-gate-grade-record.test.sh
    qa-gate-lock-recovery.test.sh
    qa-gate-pipefail.test.sh
    qa-impact-of-cue.test.sh
    review-bypass-anchor.test.sh
    review-check.test.sh
    review-count.test.sh
    review-request-build.test.sh
    review-request-diff-budget.test.sh
    review-separation.test.sh
    reviewer-lane-structural.test.sh
    run-with-timeout.test.sh
    runner-completeness.test.sh
    scoped-log-dir.test.sh
    sha256-escape-decode.test.sh
    tree-lease.test.sh
    unrecorded-review-artifact.test.sh
    validate-completion-criteria-tests.test.sh
    validate-completion-green-fields.test.sh
    vendored-skills.test.sh
    verify-release-manifest.test.sh
    workflow-doctor.test.sh
    workflow-manifest.test.sh
    worktree-isolation.test.sh
    worktree-sweep.test.sh
)
# --- EXPECTED-SPEC-FILES-END (claude-workflow-plugin-gytz, second round) ----
EXPECTED_SPECS=${#EXPECTED_SPEC_FILES[@]}

# Per-spec wall-clock cap (seconds). HEADROOM IS 1.167x, NOT 3.7x (nor the
# 1.31x this comment stated one round ago — see below). The 3.7x figure went
# stale exactly the way it once replaced a stale "~5x", and the 1.31x figure
# that replaced IT went stale the same way one round later: each reasoned
# from the worst case measured at the time (originally four CI-shaped tier
# runs at 535c89a: qa-gate-grade-record.test.sh 243s, review-separation.
# test.sh 228s, qa-gate-choose.test.sh 120s — 900/243 = 3.7x), and nothing
# flagged it when a later spec grew past that worst case — twice now.
#
# Current worst observed, standalone (`/usr/bin/time -p bash <file>`, no
# other load, no watchdog outside run-tests.sh's own harness), MEASURED
# 2026-09-13 against this round's own 170 -> 185 assertion growth (see
# EXPECTED_SPECS's comment above): unrecorded-review-artifact.test.sh,
# 185/185 assertions, exit 0 — 756.16s (implementer), 771.35s (QA's
# independent confirming run, same tree). The prior round's figures
# (170/170 — 676.60s implementer, 684.91s QA, 711s implementer's own
# contended full-tier run) are superseded, not merely rounded; this file
# grew again, the way it was always going to. review-separation.test.sh,
# 94/94 assertions, exit 0 — 315.62s (implementer) / 365.95s (QA) —
# comfortably under half the cap either way, unchanged this round.
# 900/771.35 = 1.167x against the worst figure anyone has measured here —
# the ratio moved because the worst-case input moved AGAIN (this file's own
# pairing test for R17-F1, see EXPECTED_SPECS above), not because the cap
# did.
#
# Also over the cap and unrelated to this change set: design-review-
# record.test.sh, reported at 987s standalone — tracked separately on
# claude-workflow-plugin-fcq3, not touched here.
#
# RULING (claude-workflow-plugin-k6re R19-F2): 84-86% of cap SHIPS for this
# task. The tier passes with the file inside, this round's growth (+71-95s
# depending which pair of figures is compared) is roughly half the prior
# round's (~147s), and requiring a second split as a precondition of a P0
# bug fix is scope creep. But 144s of headroom (900 - 756.16) is one
# ordinary round's growth, the LAST split in this exact file was done
# reactively AFTER crossing the cap once already, and a sibling spec
# (design-review-record.test.sh, named above) is over the cap RIGHT NOW.
# File the next split as a follow-up task with a concrete numeric trigger
# (e.g. split at 800s standalone, or at the next round that adds assertions
# to this file, whichever comes first) rather than leaving "ships for now"
# as a header note with no owner.
#
# Deliberately NOT raised. ubuntu-latest is typically slower than the boxes
# these numbers were measured on, so the real CI margin is smaller again —
# and at 1.167x standalone the margin for the tightest spec is thinner than
# it was, not comfortable. Only a genuine hang or severe environmental
# degradation (mwrb: five stale bd daemons made every bd call take >1s) is
# meant to reach the cap outright — if a real spec ever does, raise this and
# say what you measured, do not delete the cap.
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

# --- PRE-RELEASE-REF EXEMPTION: REMOVED (claude-workflow-plugin-h2zz waiver
# ruling, round 4) -------------------------------------------------------
# A narrow, token-gated exemption from STRICT_SECTIONS used to live here,
# for exactly one spec's exactly one section, on the theory that a check
# with no object to compare yet (a release tag not pushed) should be able to
# say so without reddening an otherwise-clean strict run. It failed FIVE
# independent-review rounds in a row, each fix correct on its own terms and
# each one adding a new way to be wrong: round 1 found the emission
# predicate proved local history completeness, not remote tag existence, AND
# separately found the exempt-token regex was an unanchored substring a
# passing assertion's own prose could satisfy; round 2 found the fix for the
# first of those put a live network call inside a tier documented offline;
# round 3 found the timeout guarding that network call was disableable via
# its own public argument, AND separately found the control added to prove
# the disableable-timeout fix was itself vacuous in CI; round 4 found the
# fix for THAT timeout argument rejected only the byte-exact string "0",
# letting "00"/"000" reproduce the original cross-platform split it was
# supposed to close. Six findings, one mechanism, four rounds — this
# project's standing waiver ruling exists for exactly that shape (see the
# STORE-CANARY ATTRIBUTION: REMOVED tombstone above for the shape's first
# instance, claude-workflow-plugin-gytz): remove the mechanism rather than
# guard it again. The underlying claim (does the current release's frozen
# table reproduce from its own tag) is not gone — it moved to
# .claude/scripts/verify-release-manifest.sh, run manually against a
# deliberately-local tag before push (`make verify-release`) and by
# .github/workflows/release-verify.yml once a real tag is actually pushed,
# where "the tag is not reachable yet" cannot occur by construction. L1 no
# longer asserts anything a pre-release ref cannot satisfy, so there is
# nothing here to exempt and nothing to re-guard. Nothing here is dormant;
# there is no flag to re-enable it.
# --- PRE-RELEASE-REF EXEMPTION: REMOVED (claude-workflow-plugin-h2zz) ----

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

# EXPECTED_SPEC_FILES_STRICT — TEST-HARNESS-ONLY escape hatch, discovered
# necessary while fixing claude-workflow-plugin-gytz R2-F2, not requested by
# that finding. Default (unset) is ON: the COMPLETENESS-FLOOR block below
# compares the discovered and declared basename SETS unconditionally, and a
# same-count rename (equal cardinality, different set — the exact shape
# QA's R2-F2 counterexample described) fails the run. That is correct, and
# is what every real invocation gets, because nothing outside
# runner-completeness.test.sh ever sets this variable.
#
# Turning it OFF restores the pre-R2-F2 count-only comparison
# ($TOTAL -ne $EXPECTED_SPECS, nothing else) for one invocation. CORRECTED
# (claude-workflow-plugin-gytz R3-F3): the paragraph below used to say
# run_l1/run_l1_env_bdactor are what turn it off "as their OWN default".
# Neither function body assigns this variable at all -- QA's round-3 review
# measured 21 mentions of the name in runner-completeness.test.sh against 9
# real assignments, re-verified here with the same count. The actual default
# comes from that file's own top-level `export EXPECTED_SPEC_FILES_STRICT=0`
# (read once, near the top, right after $EXPECTED is derived), which every
# ordinary run_l1/run_l1_env_bdactor call simply inherits by plain
# subprocess-environment inheritance; the OFF state is never something those
# two functions decide.
#
# ~30 of that spec's sections predate R2-F2 and build fixtures via
# mk_l1_fixture using generic, count-sized stub-NNN.sh names to test UNRELATED runner
# mechanics (timeouts, signals, telemetry disarm, lease handling, ...) —
# they never claimed to model this repo's real spec inventory, and an
# unconditional identity check against the real EXPECTED_SPEC_FILES array
# fails every one of them on "COUNTS MATCH but the SETS DO NOT", not
# because anything renamed, but because a generic name is never among the
# 73 real ones. Renaming those ~30 sections' fixtures (and the bespoke
# extra files several of them layer on top, e.g. stub-hang.sh,
# stub-skipper.sh) to real spec basenames was considered and REJECTED:
# dozens of independently-reviewed sections built over many rounds, an
# arbitrary choice of which real name each bespoke file "becomes", and the
# loss of self-documenting names in favour of an unrelated real spec's
# basename — for a check those sections were never testing in the first
# place. The handful of sections that DO build real-named fixtures
# specifically to exercise this comparison (runner-completeness.test.sh
# 19a/19b/19e, 20a-20d) explicitly override back to ON
# (EXPECTED_SPEC_FILES_STRICT=1 prefixed at the call site) rather than
# inheriting the helper's off-by-default.
EXPECTED_SPEC_FILES_STRICT_ON=1
case "${EXPECTED_SPEC_FILES_STRICT:-1}" in
    1|yes|true|YES|TRUE)  EXPECTED_SPEC_FILES_STRICT_ON=1 ;;
    0|no|false|NO|FALSE)  EXPECTED_SPEC_FILES_STRICT_ON=0 ;;
    *)
        printf 'run-tests.sh: EXPECTED_SPEC_FILES_STRICT must be 1/yes/true or 0/no/false (got %s)\n' \
            "$EXPECTED_SPEC_FILES_STRICT" >&2
        printf '  This is a test-harness-only variable; if you set it by hand or in CI,\n' >&2
        printf '  unset it instead — a real invocation should never be setting it at all.\n' >&2
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
# verify_actor_marker_took_effect() — REMOVED (claude-workflow-plugin-gytz).
# It existed only to gate attribution (arming STORE_CANARY_ATTRIBUTION_ON /
# ACTOR_SELFCHECK_OK), which no longer exists — see the STORE-CANARY
# ATTRIBUTION: REMOVED tombstone above for the waiver ruling and pointers
# (claude-workflow-plugin-gytz, -u443, -h5lw). Detection does not need an
# actor and never called this function directly.

# dolt_hash_looks_valid <value> — POSITIVE allow-list for a dolt commit hash
# shape (claude-workflow-plugin-gytz R3-F1). A dolt commit hash is exactly 32
# lowercase base32hex characters ([0-9a-v]) — confirmed empirically against
# 200 real commits in THIS repo's own protected store (`dolt log --oneline -n
# 200`: every hash length exactly 32, charset exactly [0-9a-v], zero
# exceptions), and independently consistent with DoltHub's own published
# format (a truncated SHA-512 rendered in that alphabet). Defined once,
# outside every STORE-CANARY sentinel, and called from both the ARM read and
# the per-spec AFTER read below, so the two can never drift apart.
#
# R3-F1: a DENYLIST ("anything non-empty that doesn't say hashof") is how an
# error string, a stray warning, or literal "NULL" became an accepted
# baseline. Only a string SHAPED like a hash may arm the canary or count as a
# valid sample; everything else is a failed read, named as one.
dolt_hash_looks_valid() {
    # R4-F4 (independent review round 4): an EXPLICIT character class here,
    # never a bracket RANGE ([0-9a-v]) -- bash `case`/glob bracket ranges
    # collate per LC_COLLATE, and this runner pins neither LC_COLLATE nor
    # LC_ALL (bash 3.2, in use here, also predates `globasciiranges`). Under
    # a dictionary-order locale a range like [a-v] can admit collating
    # characters outside the intended 22-letter run -- including uppercase
    # -- so the range form is not the exact allow-list the function-level
    # comment above claims, only the C-locale rendering of it. Enumerating
    # every accepted character instead is a plain membership test with no
    # collation step at all, so it needs no LC_* pinning and is exact in
    # every locale. Do not "tidy" this back into a range.
    case "$1" in
        [0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv][0123456789abcdefghijklmnopqrstuv])
            return 0 ;;
        *) return 1 ;;
    esac
}

# transcript_also_failed_note — R4-F1 (independent review round 4). The two
# STORE-CANARY verdict arms below (STORE_SAMPLE_FAILED and STORE_WRITES) sit
# ahead of the TRANSCRIPT-FAIL arm in one `if/elif` chain, so whichever of
# the three fires first is the ONLY reason recorded for a spec — a spec that
# both moves/breaks the canary AND holds its own FAIL: line(s) used to be
# reported for the canary alone, and the transcript reason was never even
# evaluated for it (the comment at the top of the STORE-CANARY verdict arms
# says "these arms exist for the spec that is not already red", which is
# false exactly when a FAIL: line is what makes it red). Prints an
# additional "transcript ALSO holds N FAIL: line(s)" fragment when
# FAIL_LINES is nonzero, or nothing when it is zero, so each STORE-CANARY
# arm can append it to its own message instead of the elif chain silently
# dropping whichever reason fires second. Never fires on its own — the
# dedicated TRANSCRIPT-FAIL arm still owns the case where the canary itself
# is clean. Reads FAIL_LINES and SPEC_OUT from the per-spec loop's own
# globals (this script has no per-spec function scope to pass them
# through — same convention dolt_hash_looks_valid's caller relies on).
transcript_also_failed_note() {
    [ "$FAIL_LINES" -gt 0 ] || return 0
    tafn_first_fail=$(grep -m1 -E '^[[:space:]]*FAIL:' "$SPEC_OUT" 2>/dev/null \
        | LC_ALL=C tr -c '[:print:]\n\t' '?' \
        | sed 's/^[[:space:]]*//' | cut -c1-160)
    printf '; its transcript ALSO holds %s FAIL: line(s) the exit code never carried -- first: %s' \
        "$FAIL_LINES" "$tafn_first_fail"
}

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
# guard that fails, by name, any spec whose window leaves the production
# store's HEAD net-changed (R4-F3, independent review round 4: mere
# resolution to the production store is not what this detects, and neither
# is an exact round trip within one spec's window — see the NET HEAD
# CHANGED / KNOWN LIMIT tombstone below for exactly what is and is not
# caught) -- never a per-spec fix the next author can omit.
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
#
# TWO STATES, NOT THREE (claude-workflow-plugin-gytz waiver ruling). An
# earlier version of this guard also armed a self-check that gated a
# self-vs-external ATTRIBUTION decision layered on top of detection (state
# 2/3 in a prior version of this comment). That decision was removed
# entirely — see the STORE-CANARY ATTRIBUTION: REMOVED tombstone above for
# the ruling and pointers (claude-workflow-plugin-gytz, -u443, -h5lw) — so
# there is nothing left to gate. Detection alone needs no actor at all, and
# was never disarmed by an unverifiable marker even before this cleanup: 23
# pre-existing assertions in runner-completeness.test.sh (sections
# 13d/13f/13h/13i/13j/13k/13l/13m at the time) depended on detection alone.
# The canary is now either ARMED (detection working: a spec whose window
# leaves the store's HEAD net-changed fails, loudly, by name -- R3-F2,
# claude-workflow-plugin-gytz round 3: two ENDPOINT samples can only prove
# NET HEAD CHANGED; see the KNOWN LIMIT in the tombstone above for exactly
# what that does and does not catch) or DISARMED (detection itself
# unavailable — dolt absent, no store, or the hashof read failed — named
# below, never a silent pass).
if ! command -v dolt >/dev/null 2>&1; then
    STORE_CANARY_DISARM_REASON="dolt is not on PATH"
elif [ ! -d "$PROTECTED_STORE/embeddeddolt/beads/.dolt" ]; then
    STORE_CANARY_DISARM_REASON="$PROTECTED_STORE/embeddeddolt/beads/.dolt does not exist (no embedded-Dolt store here — a store-less CI checkout, or a pre-1.1.x bd install)"
else
    STORE_HASH_BEFORE_RAW=$(cd "$PROTECTED_STORE/embeddeddolt/beads" 2>/dev/null \
        && dolt sql -r csv -q "SELECT hashof('HEAD')" 2>/dev/null)
    store_rc=$?
    STORE_HASH_BEFORE=$(printf '%s\n' "$STORE_HASH_BEFORE_RAW" | tail -n1)
    if [ "$store_rc" -ne 0 ]; then
        # R3-F1: the query's own exit status, captured on ITS OWN LINE right
        # after the substitution it belongs to -- never behind the `| tail`
        # pipe that used to mask it (a pipeline's $? is its LAST command's,
        # i.e. tail's, never dolt's or cd's).
        STORE_CANARY_DISARM_REASON="the cd into $PROTECTED_STORE/embeddeddolt/beads, or the dolt hashof('HEAD') read, exited rc=$store_rc"
        STORE_HASH_BEFORE=""
    elif ! dolt_hash_looks_valid "$STORE_HASH_BEFORE"; then
        STORE_CANARY_DISARM_REASON="the hashof('HEAD') read from $PROTECTED_STORE returned '$STORE_HASH_BEFORE', which is not a well-formed dolt hash (expected exactly 32 characters from [0-9a-v]; see dolt_hash_looks_valid above)"
        STORE_HASH_BEFORE=""
    else
        STORE_CANARY_ARMED=1
    fi
fi
if [ "$STORE_CANARY_ARMED" = "1" ]; then
    printf 'STORE-CANARY: ARMED — watching %s; a spec whose window leaves HEAD net-changed fails, by name\n' "$PROTECTED_STORE"
else
    # HONEST DEGRADATION, LOUD, NEVER A SILENT PASS -- but not COUNTED
    # anywhere, and it correctly never affects the tier's exit code (R3-F4:
    # the prior wording claimed disarming was both loud and tallied, and
    # nothing here tallies anything). A store-less CI checkout has nothing
    # to contaminate, so
    # this does not fail the tier — but a permanently-DISARMED guard is
    # indistinguishable from a working one unless every run says so, both
    # here and in the summary (printed twice; see the tail of this file).
    printf 'STORE-CANARY: DISARMED — %s; this run cannot detect writes to %s\n' \
        "$STORE_CANARY_DISARM_REASON" "$PROTECTED_STORE"
fi
# --- STORE-CANARY-ARM-END (claude-workflow-plugin-j7kk) ---------------------

# attribute_store_advance() — REMOVED (claude-workflow-plugin-gytz waiver
# ruling). This was the self-vs-external ATTRIBUTION decision (including the
# DEPADD-PRECURSOR-SKIP and ACTOR-ISSUE-EXTRACT regions, and the
# STORE_ATTRIBUTED_EXTERNAL/STORE_ATTRIBUTION_NOTE globals it produced) that
# tried to answer WHO advanced the protected store, layered on top of the
# STORE-CANARY-ARM detection above. See the STORE-CANARY ATTRIBUTION:
# REMOVED tombstone near the top of this file for the full account: three
# failed independent review rounds, the u443 finding that the mechanism
# could not fire in its own motivating case, and the h5lw spec-isolation
# replacement (also see that tombstone's KNOWN LIMIT paragraph — R3-F2 —
# for exactly what endpoint-only detection can and cannot see). Detection
# is unaffected: a spec whose window leaves the store's HEAD net-changed
# still fails, loudly, by name — it just no longer tries to say who, and
# DEGRADED (the classification this function fed) no longer exists.
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
    STORE_WRITES_UNREADABLE=0
    STORE_NOTE=""
    STORE_DETAIL=""
    STORE_SAMPLE_FAILED=0
    TRANSCRIPT_ALSO=""
    # --- STORE-CANARY-BEGIN (claude-workflow-plugin-j7kk) ---------------------
    # Sampled HERE — after `wait "$spec_pid"` and after the survivor sweep —
    # so a spec that backgrounded a writer has already been reaped or killed
    # before this spec's "after" hash is taken; a write from that backgrounded
    # process is caught if it leaves HEAD net-changed AT THIS SAMPLE (R4-F3,
    # independent review round 4: it does not "still count" unconditionally —
    # a write that is itself undone before this sample, e.g. a round trip
    # back to the same HEAD within this same window, nets to no change and is
    # invisible here, same as everywhere else this file makes the NET HEAD
    # CHANGED claim; see the KNOWN LIMIT tombstone below). What this sampling
    # point buys is READ safety: whatever the window did leave net-changed is
    # attributed at the earliest point it can be read without racing a
    # survivor still holding the store open.
    #
    # Sampling carries the PREVIOUS spec's "after" as the next spec's
    # "before" (STORE_HASH_BEFORE is reassigned at the bottom of this block,
    # never reset per-iteration) — 40 hashof calls across a 39-spec tier, not
    # 78: one at arm time, one per spec thereafter. R3-F3 (independent review
    # round 3): this means the window a FAIL message describes is never
    # provably just "this spec's own execution" — it also covers whatever
    # brief inter-spec bookkeeping (this loop's own cat/grep/rm work) ran
    # since the previous spec's own after-sample was taken. A dedicated
    # pre-launch resample would close that gap at the cost of DOUBLING the
    # per-tier hashof-call count (78, not 40) and doubling the surface for a
    # transient sample failure; instead every message below says "since the
    # last confirmed sample" rather than "while it ran", which is what this
    # sampling scheme can actually prove.
    if [ "$STORE_CANARY_ARMED" = "1" ]; then
        STORE_HASH_AFTER_RAW=$(cd "$PROTECTED_STORE/embeddeddolt/beads" 2>/dev/null \
            && dolt sql -r csv -q "SELECT hashof('HEAD')" 2>/dev/null)
        store_rc=$?
        STORE_HASH_AFTER=$(printf '%s\n' "$STORE_HASH_AFTER_RAW" | tail -n1)
        STORE_VALID_SAMPLE=0
        if [ "$store_rc" -eq 0 ] && dolt_hash_looks_valid "$STORE_HASH_AFTER"; then
            STORE_VALID_SAMPLE=1
        fi
        # R3-F1 (HIGH, independent review round 3): a snapshot that FAILS
        # must be LOUD and must DISARM the canary FOR THIS SPEC — it must
        # never silently read as "no change". The pre-fix shape masked
        # dolt's exit status behind `| tail -n1` (a pipeline's $? is its
        # LAST command's) and accepted anything non-empty that didn't
        # literally echo "hashof" as a valid baseline, so an empty read (cd
        # failed, or dolt itself exited non-zero with nothing on stdout —
        # confirmed directly: a missing .dolt/ makes dolt exit 1 with EMPTY
        # stdout and an error on stderr) left STORE_WRITES at its 0 default
        # and this spec read as clean. STORE_VALID_SAMPLE is 1 only when
        # BOTH the query's own captured exit status is 0 (never masked by a
        # pipe: store_rc is set on its own line, straight off the
        # substitution, before any pipe touches the value) AND the result
        # is POSITIVELY shaped like a dolt hash (dolt_hash_looks_valid,
        # defined above the ARM block) — a denylist is how an error string
        # became a baseline; this is the allow-list instead.
        if [ "$STORE_VALID_SAMPLE" != "1" ]; then
            STORE_SAMPLE_FAILED=1
            if [ "$store_rc" -ne 0 ]; then
                STORE_DETAIL="the store-canary AFTER-sample failed: the cd into $PROTECTED_STORE/embeddeddolt/beads, or the dolt hashof('HEAD') read, exited rc=$store_rc"
            else
                STORE_DETAIL="the store-canary AFTER-sample failed: hashof('HEAD') from $PROTECTED_STORE returned '$STORE_HASH_AFTER', which is not a well-formed dolt hash"
            fi
            STORE_NOTE="; $STORE_DETAIL -- this spec's window cannot be confirmed clean, and the store's last confirmed hash stays $STORE_HASH_BEFORE unchanged, so the next successful sample also covers this spec's unmeasured window"
            # Never carry a failed/garbage sample forward as if it were a
            # valid baseline (R3-F1's last requirement): STORE_HASH_AFTER is
            # blanked here so the carry-forward line below is a no-op, and
            # STORE_HASH_BEFORE is left UNCHANGED — not overwritten with ""
            # or with whatever garbage came back — so the NEXT successful
            # sample's comparison runs from the last CONFIRMED-good hash,
            # honestly covering this spec's unmeasured window too.
            STORE_HASH_AFTER=""
        elif [ -n "$STORE_HASH_AFTER" ] && [ "$STORE_HASH_AFTER" != "$STORE_HASH_BEFORE" ]; then
            STORE_WRITES=$(cd "$PROTECTED_STORE/embeddeddolt/beads" 2>/dev/null \
                && dolt log --oneline "$STORE_HASH_BEFORE".."$STORE_HASH_AFTER" 2>/dev/null | wc -l | tr -d ' ')
            # R4-F2 (independent review round 4): an EMPTY or NON-NUMERIC
            # read here means the count could not be taken AT ALL -- the cd
            # above failed (the directory disappeared or became unreadable
            # between the successful hashof read that got us into this branch
            # and this line), so the right-hand side of `&&` never ran and
            # the whole substitution is empty. That is a DIFFERENT fact from
            # "dolt log ran and reported zero commits" (the well-formed "0"
            # case handled below), and conflating the two used to let this
            # sentinel reach the "advanced by N commit(s)" branch with a
            # fabricated N=1. Flagged here, before the sentinel value
            # overwrites it, so the classification below can route it to the
            # same non-authoritative-count handling as the literal "0" case
            # instead.
            STORE_WRITES_UNREADABLE=0
            case "$STORE_WRITES" in ''|*[!0-9]*) STORE_WRITES=1; STORE_WRITES_UNREADABLE=1 ;; esac
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
            #
            # R3-F2 KNOWN LIMIT applies here too (see the tombstone near the
            # top of this file): this comparison proves NET HEAD CHANGED
            # between two endpoints, never a full history of what happened
            # in between — an advance that was itself later undone within
            # THIS SAME window would net to no change and never reach this
            # branch at all. That is accepted, named, and out of scope; see
            # the tombstone for why building past it is not the direction.
            if [ "$STORE_WRITES" = "0" ] || [ "$STORE_WRITES_UNREADABLE" = "1" ]; then
                STORE_WRITES=1
                if [ "$STORE_WRITES_UNREADABLE" = "1" ]; then
                    # R4-F2: the count could not be READ at all (see the flag
                    # above) -- distinct wording from the NON-LINEAR case
                    # below, which DID get a reading and it was zero.
                    STORE_MOVE_DESC="moved by an UNREADABLE change (the commit count between $STORE_HASH_BEFORE and $STORE_HASH_AFTER could not be read at all)"
                    STORE_DETAIL="UNREADABLE store movement: HEAD moved from $STORE_HASH_BEFORE to $STORE_HASH_AFTER but the commit count between them could not be read -- the cd into $PROTECTED_STORE/embeddeddolt/beads failed (directory missing or unreadable after the hashof read above succeeded), or \`dolt log $STORE_HASH_BEFORE..$STORE_HASH_AFTER\` produced no usable output"
                else
                    STORE_MOVE_DESC="moved by a NON-LINEAR change (not a chain of new commits — a rollback/reset-class move, or a transient dolt-log failure)"
                    STORE_DETAIL="NON-LINEAR store movement: HEAD moved from $STORE_HASH_BEFORE to $STORE_HASH_AFTER but \`dolt log $STORE_HASH_BEFORE..$STORE_HASH_AFTER\` reported no commits — AFTER is not reachable via new commits on BEFORE (a rollback/reset-class move), or dolt log failed transiently after a successful hashof read"
                fi
            else
                # R3-F4: STORE_WRITES is a REAL measured count here (never
                # the boolean sentinel the NON-LINEAR branch above sets) —
                # this is the only branch entitled to say "N commit(s)".
                STORE_MOVE_DESC="advanced by $STORE_WRITES commit(s)"
            fi
            STORE_NOTE="; the protected Beads store $STORE_MOVE_DESC since the last confirmed sample"
            # attribute_store_advance (WHO advanced it) was called here —
            # REMOVED under the claude-workflow-plugin-gytz waiver ruling; see
            # the STORE-CANARY ATTRIBUTION: REMOVED tombstone near the top of
            # this file. Detection above ($STORE_WRITES, $STORE_DETAIL) is
            # unaffected: the dedicated FAIL arm further down fails this spec
            # unconditionally whenever this comparison finds HEAD net-changed,
            # without asking who caused it.
        fi
        # Carry forward only a CONFIRMED-good read (R3-F1: never carry a
        # failed/garbage sample forward as a valid baseline — STORE_HASH_AFTER
        # was already blanked above when the sample failed, so this is a
        # plain no-op in that case, left explicit rather than relied upon).
        [ "$STORE_SAMPLE_FAILED" != "1" ] && [ -n "$STORE_HASH_AFTER" ] && STORE_HASH_BEFORE="$STORE_HASH_AFTER"
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
    # TWO DEDICATED arms for a spec that would otherwise be entirely green
    # but either broke its own store-canary sample or moved the protected
    # store. Placed immediately after the SURVIVOR_COUNT arm and before
    # TRANSCRIPT-FAIL, so a spec already failing for one of the reasons
    # above keeps that reason (STORE_NOTE is appended to each of them
    # instead); these arms exist for the spec that is not already red for
    # ONE of those three reasons — TIMEOUT, rc!=0, or a live survivor. They
    # do NOT preempt a fourth: a spec whose own transcript holds FAIL: line(s)
    # (TRANSCRIPT-FAIL, below) is just as red, and R4-F1 (independent review
    # round 4) found that being placed ahead of that arm in this same
    # `if/elif` chain meant the transcript reason was never even evaluated
    # for such a spec — the canary reason alone was reported, and the other
    # reason was silently lost, not merely deferred. Both arms below now
    # check FAIL_LINES too (via transcript_also_failed_note, defined above
    # dolt_hash_looks_valid) and append it to their own message so a spec red
    # for both reasons is reported for both.
    #
    # R3-F1 (HIGH, independent review round 3): a store-canary sample that
    # FAILED must be exactly as adverse as a DETECTED advance, never read as
    # "no change" — "a measurement that did not happen is indistinguishable
    # from one that passed" is this whole batch's own defect family, and a
    # silent PASS here would be that same defect in a new guard. STORE_NOTE
    # was built above, at the SAMPLING occurrence of this same sentinel pair,
    # from STORE_DETAIL, so this arm's message NAMES which operation failed —
    # never a fabricated "no change".
    elif [ "$STORE_SAMPLE_FAILED" = "1" ]; then
        FAIL=$((FAIL + 1))
        # --- STORE-CANARY-TRANSCRIPT-MERGE-BEGIN (claude-workflow-plugin-gytz R4-F1) ---
        TRANSCRIPT_ALSO=$(transcript_also_failed_note)
        # --- STORE-CANARY-TRANSCRIPT-MERGE-END -----------------------------------
        FAILED_FILES+=("$base (${STORE_NOTE#; }${TRANSCRIPT_ALSO}; $ASSERTS assertion(s) in ${ELAPSED_S}s)")
        printf -- '--- %s: FAILED — %s%s\n' "$base" "${STORE_NOTE#; }" "$TRANSCRIPT_ALSO"
        printf '    A measurement that did not happen must not look like one that passed -- an\n'
        printf '    unmeasurable window is treated as adverse, the same as a detected advance,\n'
        printf '    never as "no change" (claude-workflow-plugin-gytz R3-F1). ---\n'
    # claude-workflow-plugin-j7kk: this arm fires whenever the endpoint
    # comparison finds the store's HEAD net-changed across a spec's window,
    # unconditionally. The self-vs-external ATTRIBUTION decision that used
    # to gate it (claude-workflow-plugin-dhh7) was removed under the
    # standing waiver ruling — see the STORE-CANARY ATTRIBUTION: REMOVED
    # tombstone near the top of this file. Either this spec wrote, or a
    # concurrent writer did; the canary cannot say which any more, so every
    # record left behind is test-authored and must not be read as evidence,
    # either way. R3-F2 KNOWN LIMIT (same tombstone): this is a NET HEAD
    # CHANGED claim from two endpoint samples, never a full history — an
    # advance undone within this exact window is invisible by construction
    # and out of scope by design. R4-F3 (independent review round 4): the
    # message below says only what the two samples actually establish — the
    # store moved, cause not established — rather than naming $base as the
    # contaminator, which the "either this spec wrote, or a concurrent
    # writer did" sentence right above it already contradicts.
    #
    # It does NOT roll back (deliberate — see the ARM block and the task's
    # own measurement: genuine agent writes interleave with a contaminating
    # spec in the same window, and an automatic revert would destroy real
    # work alongside the synthetic records).
    elif [ "$STORE_WRITES" -gt 0 ]; then
        FAIL=$((FAIL + 1))
        # --- STORE-CANARY-TRANSCRIPT-MERGE-BEGIN (claude-workflow-plugin-gytz R4-F1) ---
        TRANSCRIPT_ALSO=$(transcript_also_failed_note)
        # --- STORE-CANARY-TRANSCRIPT-MERGE-END -----------------------------------
        FAILED_FILES+=("$base (the protected Beads store moved, cause not established: ${STORE_NOTE#; }${TRANSCRIPT_ALSO}; $ASSERTS assertion(s) in ${ELAPSED_S}s)")
        printf -- '--- %s: FAILED — %s%s\n' "$base" "${STORE_NOTE#; }" "$TRANSCRIPT_ALSO"
        printf '    (%s). The store moved; cause not established -- either this spec wrote, or\n' \
            "$PROTECTED_STORE"
        printf '    a concurrent writer did, and this canary detects a net HEAD change but no\n'
        printf '    longer attributes it (claude-workflow-plugin-gytz). L1 ran against a live\n'
        printf '    production store either way, so every record left behind is test-authored\n'
        printf '    and must not be read as evidence. Commits below. ---\n'
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
        # Unreachable with STORE_WRITES -gt 0 (the dedicated STORE-CANARY arm
        # above now fails that case unconditionally — claude-workflow-plugin-
        # gytz waiver ruling; DEGRADED no longer exists as a classification),
        # so this branch is a plain PASS.
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
    # claude-workflow-plugin-gytz R2-F2: the SET comparison runs
    # UNCONDITIONALLY, every time, never gated behind a prior count
    # mismatch. QA reproduced the gap a count-first gate leaves: declare
    # {001,002,003}, discover {001,002,zz-undeclared} — EQUAL cardinality,
    # DIFFERENT set, and a cardinality-only floor reads "HELD". A file
    # RENAME is exactly this shape (one name leaves, a different one
    # arrives, the count never moves), and it is the most likely real-world
    # drift, more likely than a pure addition or deletion. The count is now
    # a DERIVED detail of this set comparison, never the trigger for one —
    # this is the same lesson the array itself encodes, one level in:
    # comparing sizes is not comparing sets. That is what runs whenever
    # EXPECTED_SPEC_FILES_STRICT_ON=1, which is every real invocation —
    # make test, CI, and a human at a shell all leave the variable unset.
    #
    # EXPECTED_SPEC_FILES_STRICT_ON=0 restores the ORIGINAL, pre-R2-F2
    # count-only comparison for the BREACH DECISION: breach iff $TOTAL
    # disagrees with $EXPECTED_SPECS, full stop, identical message shape
    # this floor always used for that case. CORRECTED (claude-workflow-
    # plugin-gytz R3-F2): the set comparison below is now computed
    # UNCONDITIONALLY, in both modes — this paragraph used to say it "never
    # runs at all" under STRICT_ON=0, which stopped being quite true the
    # moment the HELD-message caveat below was added, though the GATING
    # decision (does a non-empty diff FAIL the run) is still exactly what
    # STRICT_ON controls, unchanged. THIS IS STILL NOT "compute the diff
    # only after a count mismatch" — the shape R2-F2 forbids — the diff is
    # computed before either branch decides anything, on every run; only
    # whether it can fail the run depends on STRICT_ON. It is a narrow,
    # test-harness-only escape hatch (see the Environment: header and the
    # array's own header above for the full account of why it exists and
    # who is allowed to set it), unreachable from any real invocation, so
    # R2-F2's actual guarantee — a real invocation against the real project
    # cannot silently pass a same-count rename — holds unconditionally for
    # the population it protects.
    DISCOVERED_BASENAMES=$(for __t in "${TESTS[@]}"; do basename "$__t"; done | sort)
    DECLARED_BASENAMES=$(printf '%s\n' "${EXPECTED_SPEC_FILES[@]}" | sort)
    EXTRA_SPECS=$(comm -23 <(printf '%s\n' "$DISCOVERED_BASENAMES") <(printf '%s\n' "$DECLARED_BASENAMES"))
    MISSING_SPECS=$(comm -13 <(printf '%s\n' "$DISCOVERED_BASENAMES") <(printf '%s\n' "$DECLARED_BASENAMES"))
    SET_MISMATCH=0
    if [ -n "$EXTRA_SPECS" ] || [ -n "$MISSING_SPECS" ]; then
        SET_MISMATCH=1
    fi
    if [ "$EXPECTED_SPEC_FILES_STRICT_ON" -eq 1 ]; then
        FLOOR_BREACHED="$SET_MISMATCH"
    else
        FLOOR_BREACHED=0
        if [ "$TOTAL" -ne "$EXPECTED_SPECS" ]; then
            FLOOR_BREACHED=1
        fi
    fi
    if [ "$FLOOR_BREACHED" -eq 1 ]; then
        if [ "$EXPECTED_SPEC_FILES_STRICT_ON" -eq 1 ] && [ "$TOTAL" -eq "$EXPECTED_SPECS" ]; then
            printf 'COMPLETENESS FLOOR BREACH: %d spec file(s) discovered, %d declared — COUNTS MATCH but the SETS DO NOT (a rename-shaped drift: one file left, a different one arrived).\n' \
                "$TOTAL" "$EXPECTED_SPECS" >&2
        else
            printf 'COMPLETENESS FLOOR BREACH: discovered %d spec file(s), expected exactly %d.\n' \
                "$TOTAL" "$EXPECTED_SPECS" >&2
        fi
        printf '  The completeness line above describes a DIFFERENT tier than the one this floor pins.\n' >&2
        printf '  If you added, removed, or renamed a spec deliberately, name it in\n' >&2
        printf '  EXPECTED_SPEC_FILES in run-tests.sh in the same change. Otherwise, spec files\n' >&2
        printf '  have been lost, renamed, or added and every summary since has described the\n' >&2
        printf '  wrong set.\n' >&2
        if [ -n "$EXTRA_SPECS" ]; then
            printf '  DISCOVERED but NOT in EXPECTED_SPEC_FILES (add these lines to the array):\n' >&2
            printf '%s\n' "$EXTRA_SPECS" | sed 's/^/    /' >&2
        fi
        if [ -n "$MISSING_SPECS" ]; then
            printf '  in EXPECTED_SPEC_FILES but NOT discovered (removed or renamed without updating the array):\n' >&2
            printf '%s\n' "$MISSING_SPECS" | sed 's/^/    /' >&2
        fi
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
    # claude-workflow-plugin-gytz R3-F2: ANNOUNCE WHEN THE WEAKER MODE LETS
    # SOMETHING THROUGH — the same convention STRICT_SECTIONS already
    # follows for a skipped section (PARTIAL is named in the completeness
    # line above regardless of STRICT_SECTIONS_ON; that flag only decides
    # whether it fails the run). Byte-identical on a clean run either way,
    # same as STRICT_SECTIONS: this can ONLY fire under
    # EXPECTED_SPEC_FILES_STRICT_ON=0 with a genuine SET_MISMATCH, because
    # under =1 that combination would already have failed the run above —
    # HELD and a non-empty diff cannot coexist in strict mode by
    # construction. Deliberately a SEPARATE line, appended after rather
    # than folded into the HELD text itself, so every existing assertion
    # that checks the HELD line's own exact wording is untouched.
    if [ "$EXPECTED_SPEC_FILES_STRICT_ON" -eq 0 ] && [ "$SET_MISMATCH" -eq 1 ]; then
        printf '  LEGACY MODE (EXPECTED_SPEC_FILES_STRICT=0): the spec-set IDENTITY was not\n'
        printf '  checked this run, and it does not actually match EXPECTED_SPEC_FILES — do not\n'
        printf '  read the HELD line above as a claim that the declared and discovered names agree.\n'
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
    printf '  Either provision what the marker names (that is what the l1-unit job does for bd, dolt,\n' >&2
    printf '  node and BOTH MCP servers node_modules), or — if the section genuinely cannot run here —\n' >&2
    printf '  say so where the claim is made and take the section arm out of the strict environment.\n' >&2
    printf '  Do not read this run as full coverage: it is not.\n' >&2
    finish 1
fi
# --- SECTION-SKIP-REFUSAL-END (a9hh R1-F1) ----------------------------------

if [ "$FAIL" -gt 0 ]; then
    finish 1
fi

finish 0

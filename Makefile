# Makefile — convenience targets for the plugin's local test/lint loop.
# AgentLint W1 looks for `make test` / `make build` style commands as a
# language-agnostic signal that build and test paths are documented.

.PHONY: help session test test-fast test-component test-all test-linux test-linux-all test-live test-e2e test-e2e-record test-e2e-install test-e2e-unit test-ci manifest-validate cassette-diff sync-fixtures lint shellcheck check doctor install-test clean

help:
	@echo "Targets:"
	@echo "  session           — launch Claude at the recorded effort verdict (.claude/effort-verdict; see docs/EFFORT-AB-TEST.md)"
	@echo "  test              — run the plugin's bash test suite (L1 unit)"
	@echo "  test-fast         — run a CONSEQUENCE-selected subset of L1 (Stop-hook budget; claude-workflow-plugin-yzo9; NOT a substitute for 'test')"
	@echo "  test-component    — run hook-pipeline component tests (L2; Phase B)"
	@echo "  test-all          — run L1 unit + L2 component tiers (offline; CI-friendly)"
	@echo "  test-linux        — run the L1 tier inside a Linux container (GNU tooling; needs docker)"
	@echo "  test-linux-all    — same, L1 + L2. Reports which tiers ran; a skip is never a pass"
	@echo "  test-live         — run live E2E for ONE OR MORE fixtures (requires FIXTURE=name OR FIXTURES=\"a b c\";"
	@echo "                      paid; needs ANTHROPIC_API_KEY; pass CONFIRM=1 to skip the cost prompt; RECORD=1 to refresh cassettes)"
	@echo "  test-e2e          — DEPRECATED alias (prints pointer to test-live and exits 2)"
	@echo "  test-e2e-record   — DEPRECATED alias (use 'test-live RECORD=1')"
	@echo "  test-e2e-unit     — run only the offline self-tests of the E2E harness"
	@echo "  test-e2e-install  — install npm deps for the E2E harness"
	@echo "  manifest-validate — validate .claude-plugin/plugin.json (offline)"
	@echo "  test-ci           — run every offline tier (L1 + L2 + L3-unit + manifest); 'what CI runs without API key'"
	@echo "  cassette-diff     — diff the most recent replay vs its committed golden (set FIXTURE=name to scope)"
	@echo "  sync-fixtures     — re-sync every e2e fixture's committed .claude/scripts/ copies to the canonical scripts (heals the drift guard)"
	@echo "  lint              — alias for shellcheck"
	@echo "  shellcheck        — run shellcheck on every hook script"
	@echo "  check             — run AgentLint against this repo"
	@echo "  doctor            — functional health check of an install (TARGET=<dir>, DOCTOR_ARGS=\"...\"); safe mid-session (only 'beads' touches the target)"
	@echo "  install-test      — install into a tempdir, then run the doctor against it (expected GREEN; needs the npm registry)"
	@echo "  clean             — remove transient .qa-tracking state"

# Launch a working session at the effort level the A/B interference test
# (docs/EFFORT-AB-TEST.md) recorded in .claude/effort-verdict. The verdict is
# the first non-comment, non-blank line; defaults to `max` when the file is
# missing or empty. `exec` replaces make so Claude owns the tty directly.
session:
	@v=$$(grep -v '^[[:space:]]*#' .claude/effort-verdict 2>/dev/null | grep -v '^[[:space:]]*$$' | head -1 | tr -d '[:space:]'); \
	[ -n "$$v" ] || v=max; \
	echo "session: launching 'claude --effort $$v' (from .claude/effort-verdict; see docs/EFFORT-AB-TEST.md)"; \
	exec claude --effort "$$v"

test:
	bash .claude/scripts/tests/run-tests.sh

# test-fast (claude-workflow-plugin-yzo9) — a SUBSET of the L1 tier, chosen by
# CONSEQUENCE, not by speed, and it is this repo's own Stop-hook TEST_CMD
# override (.claude/test-cmd) from here on, not merely an offered convenience.
#
# WHY THIS EXISTS. `make test` measures 1731s/1777s uncontended (two
# independent runs, this session) against settings.json's Stop-hook wall-clock
# ceiling of 1320s (.claude/settings.json, hooks.Stop[0].hooks[0].timeout) --
# 1731 > 1320, so the full suite CANNOT complete inside a Stop no matter how
# verify-before-stop.sh's own internal TEST_TIMEOUT_S is tuned (see that
# constant's own header for why it must stay below the external cap rather
# than be raised to try to cover the suite). The operator's decision: narrow
# the Stop tier rather than raise the external cap (which would turn every
# Stop-with-unapproved-changes into a 30-40 minute wait -- worse than the
# problem) or leave both (a permanently-red, ignored gate).
#
# THE SELECTION, justified file by file, not just by budget:
#   review-check.test.sh, impact-report.test.sh, qa-gate-choose.test.sh,
#     qa-gate-lock-recovery.test.sh, qa-gate-pipefail.test.sh --
#     review-check.sh, impact-report.sh and qa-gate.sh's own core commands
#     (choose/enter/approve's lock recovery, the i8cx pipefail-in-the-
#     evidence-chain defect class) are three of the four "gate scripts" this
#     task names directly; a defect in any of them changes whether a release
#     is actually safe, which is exactly what a NARROWED Stop tier most needs
#     to keep catching.
#   gate-claim-honesty.test.sh, run-with-timeout.test.sh, scoped-log-dir.test.sh,
#     tree-lease.test.sh -- the fourth "gate script" (verify-before-stop.sh
#     itself) and the machinery THIS task's own change touches or depends on:
#     gate-claim-honesty pins the checks_scope_claim/checks_scope_note
#     disclosure this task extends with override-awareness; run-with-timeout
#     pins the dispatch mechanism that will run whatever TEST_CMD this file
#     resolves to, override or not; scoped-log-dir and tree-lease cover the
#     per-run log/lease bookkeeping in the same dispatch region.
#   override-disclosure.test.sh -- direct coverage of yzo9's own two fixes
#     (the override disclosure this comment describes, and detect-stack.sh's
#     read_override fail-open correction this narrowing now depends on for
#     real, every Stop, not hypothetically).
#   denylist-source.test.sh, review-count.test.sh, reviewer-lane-structural.test.sh,
#     qa-impact-of-cue.test.sh -- cheap (each well under two seconds
#     uncontended) structural guards on the change-set membership rule, the
#     review-resolution predicate, and two prompt-surface regressions that
#     previously survived multiple green verification passes specifically
#     because their only guard ran at a wider cadence than the violation --
#     the exact failure mode a NARROWED tier risks reintroducing if it is not
#     careful about what "cheap but load-bearing" means.
# Deliberately EXCLUDED: the design-workflow specs (design-*, plan-batches,
# grilling-record), packaging/installer/mcp-deps parity, and the remaining
# qa-gate-grade-record.test.sh / review-separation.test.sh (each independently
# measured over 200s under contention elsewhere in this repo's own test
# history) -- real coverage, but peripheral to "did this Stop's release
# decision stay safe", and expensive enough to defeat the point of a fast
# tier if included.
#
# MEASURED 2026-08-27, HEAD 2eced52 + claude-workflow-plugin-yzo9 (uncommitted;
# other specialists' wave-2 work concurrently active in the same tree AND a
# separate verify-before-stop.sh + run-tests.sh pair observed still running
# from an earlier lease age_s=617 during one of these runs -- so none of these
# are clean-machine numbers). THREE full `make test-fast` runs, in order:
#   1. 13 of these 14 files (override-disclosure.test.sh did not exist yet):
#      ~240s, rc=1 -- run-tests.sh's own STORE-CANARY guard fired on
#      qa-gate-choose.test.sh ("contaminated the protected Beads store:
#      advanced by 4 commit(s)"). Consistent with the guard's own documented
#      inability to distinguish a spec's own write from a concurrent writer
#      landing in the same window (run-tests.sh's STORE-CANARY-BEGIN
#      comment) -- this ran while another Stop hook's own verify-before-
#      stop.sh was independently active (see the lease note above).
#   2. Same 13 files, immediate re-run: 235s, rc=0, clean -- the contamination
#      did not reproduce, consistent with a one-off concurrent write rather
#      than a defect in the spec.
#   3. All 14 files (override-disclosure.test.sh added): 212s, rc=0, clean --
#      the number this file's own header cites.
# Budget was <=300s target / 600s hard ceiling: met on all three (even run 1's
# ~240s), but with less margin than the individual per-spec sum (~207s, timed
# spec-by-spec outside this harness) suggested -- run-tests.sh's own per-spec
# overhead (STORE-CANARY hashing, lease bookkeeping) and general contention
# account for the rest. qa-gate-choose.test.sh's STORE-CANARY exposure is a
# property of run-tests.sh watching the live .beads store for ANY spec, not
# of this selection -- but narrowing the tier means it now runs on EVERY
# Stop instead of inside a `make test` that rarely finished at all, which
# raises the ABSOLUTE number of windows it can land in. A hit blocks (fails
# closed), never passes silently; the recovery is re-running the Stop.
#
# `--filter` DISARMS the L1 completeness floor and this recipe inherits that
# disclosure unmodified (run-tests.sh:236-250: "the runner says the floor is
# disarmed rather than pretending the subset describes the tier"). This
# target is NOT a substitute for `make test` -- it is what the Stop hook can
# afford to run on every iteration; the full tier remains the pre-commit and
# CI gate.
test-fast:
	bash .claude/scripts/tests/run-tests.sh --filter 'review-check\.test\.sh\|impact-report\.test\.sh\|run-with-timeout\.test\.sh\|gate-claim-honesty\.test\.sh\|qa-gate-choose\.test\.sh\|qa-gate-lock-recovery\.test\.sh\|qa-gate-pipefail\.test\.sh\|scoped-log-dir\.test\.sh\|denylist-source\.test\.sh\|review-count\.test\.sh\|tree-lease\.test\.sh\|reviewer-lane-structural\.test\.sh\|qa-impact-of-cue\.test\.sh\|override-disclosure\.test\.sh'

# Component tier (Phase B). The runner discovers specs under
# .claude/tests/component/specs/ and pre-sources the lib/ helpers. Specs
# exercise each hook script via crafted stdin payloads against a tempdir
# fixture (no live runs, no LLM calls).
test-component:
	bash .claude/tests/component/run.sh

# Combined offline test run: L1 unit + L2 component. Preserves the existing
# `test` scope (L1 only) so anything that pinned `make test` keeps working;
# new wiring (CI, docs) should target `test-all` for the full offline gate.
test-all: test test-component

# THE LINUX TIER. Everything above runs on whatever the developer's box is,
# which here is macOS: BSD find, BSD sed, `shasum`, bash 3.2. CI runs on
# ubuntu-latest: GNU findutils, GNU coreutils, `sha256sum`, bash 5.2. These two
# targets run the SAME tier bytes against the second set, in a container, before
# a push — so a red CI run is one unknown (the code) rather than two (the code
# and the CI wiring nobody has exercised either).
#
# The repo is bind-mounted READ-ONLY and the mount is verified per run (the
# driver hashes the tracked tree on both sides and refuses a mismatch), so this
# is safe to run mid-session: a container cannot write into .beads/ or
# .claude/.qa-tracking/ and cannot leave root-owned files in the checkout.
#
# EXIT CODES ARE THREE-VALUED, matching the L1 runner's outcome discipline:
# 0 every requested tier ran and passed, 1 a tier ran and failed, 2 the tier
# could NOT be measured (no docker, no daemon, build failure, byte mismatch).
# A missing docker is a named skip and exit 2 — never a silent green.
test-linux:
	bash .claude/tests/linux/run-linux-tier.sh --tiers l1

test-linux-all:
	bash .claude/tests/linux/run-linux-tier.sh --tiers l1,l2 --keep-going

# L3 live tier — MANUAL ONLY. Per v3.1.0 spec item 0.8, live testing is
# a development-cycle activity, gated behind explicit operator invocation
# with a confirmed cost preview. The old `test-e2e` ran every fixture
# unconditionally on every invocation; `test-live` requires FIXTURE= and
# prints the estimated spend before starting.
#
# Usage:
#   make test-live FIXTURE=node-react-auth
#   make test-live FIXTURES="node-react-auth go-cli-refactor"
#   make test-live FIXTURE=node-react-auth CONFIRM=1        # skip the prompt
#   make test-live FIXTURE=node-react-auth RECORD=1         # captures missing goldens (debugging only — goldens are not a gate after 0.8)
#
# Per-fixture cost estimates (from the 2026-05 G8 runs; estimates only,
# the real cost depends on the model snapshot and any retries triggered
# by QA block-then-recover):
#   node-react-auth        ~ $5-10  / 13-17 min
#   go-cli-refactor        ~ $5-10  / 13-17 min
#   monorepo-frontend-only ~ $5-10  / 13-17 min
#   multi-domain-signup    ~ $5-10  / 13-17 min
#   python-django-bug      ~ $5-10  / 13-17 min
#   qa-block-recovery      ~ $5-10  / 13-17 min (often higher; recovery
#                                                loops add iterations)
test-live:
	@fixtures=""; \
	if [ -n "$$FIXTURES" ]; then \
		fixtures="$$FIXTURES"; \
	elif [ -n "$$FIXTURE" ]; then \
		fixtures="$$FIXTURE"; \
	else \
		echo "Usage: make test-live FIXTURE=<name>" ; \
		echo "       make test-live FIXTURES=\"<a> <b> <c>\"" ; \
		echo "       Optional: CONFIRM=1 (skip cost prompt), RECORD=1 (refresh cassettes)" ; \
		echo "" ; \
		echo "Available fixtures:" ; \
		ls .claude/tests/e2e/fixtures/ 2>/dev/null | sed 's/^/  /' ; \
		exit 2 ; \
	fi ; \
	if [ -z "$$ANTHROPIC_API_KEY" ]; then \
		echo "test-live: ANTHROPIC_API_KEY is not set. Live testing drives real Claude — set the key and rerun." ; \
		exit 2 ; \
	fi ; \
	resolver=".claude/scripts/resolve-fixture-spec.sh" ; \
	resolved_specs="" ; \
	for f in $$fixtures; do \
		spec=$$("$$resolver" "$$f" 2>/tmp/test-live-resolve-err.$$$$) ; \
		rc=$$? ; \
		if [ "$$rc" -ne 0 ]; then \
			echo "test-live: failed to resolve fixture '$$f' to a spec file (rc=$$rc)" ; \
			cat /tmp/test-live-resolve-err.$$$$ >&2 ; \
			rm -f /tmp/test-live-resolve-err.$$$$ ; \
			exit $$rc ; \
		fi ; \
		rm -f /tmp/test-live-resolve-err.$$$$ ; \
		resolved_specs="$$resolved_specs $$spec" ; \
	done ; \
	pattern="" ; \
	for spec in $$resolved_specs; do \
		case "$$pattern" in "") pattern="$$spec" ;; *) pattern="$$pattern|$$spec" ;; esac ; \
	done ; \
	count=0 ; total_lo=0 ; total_hi=0 ; \
	for f in $$fixtures; do \
		count=$$((count + 1)) ; \
		total_lo=$$((total_lo + 5)) ; \
		total_hi=$$((total_hi + 10)) ; \
	done ; \
	echo "test-live: about to run $$count live fixture(s): $$fixtures" ; \
	echo "test-live: resolved spec(s) -> $$pattern" ; \
	echo "test-live: estimated cost ~ \$$$$total_lo-\$$$$total_hi USD (Claude Opus 4.7; 2026-05 baseline)" ; \
	if [ "$$CONFIRM" != "1" ]; then \
		printf 'test-live: proceed? (y/N) ' ; \
		read reply ; \
		case "$$reply" in y|Y|yes|YES) ;; *) echo "test-live: aborted." ; exit 0 ;; esac ; \
	fi ; \
	if [ "$$RECORD" = "1" ]; then \
		echo "test-live: RECORD=1 — RECORD_GOLDEN will be set for the run (debugging only; goldens are not a gate after 0.8)" ; \
		cd .claude/tests/e2e && RECORD_GOLDEN=1 npx vitest run --testNamePattern '.*' specs/ -t "" 2>&1 | tee ../../../.tmp/test-live.log ; \
	else \
		mkdir -p .tmp ; \
		cd .claude/tests/e2e && npx vitest run $$(for s in $$resolved_specs; do echo "specs/$$s"; done) ; \
	fi

# test-e2e / test-e2e-record — DEPRECATED. The historical behaviour was
# "run every live fixture on every invocation"; per 0.8 that's the
# wrong default (it burns API spend unintentionally and disagrees with
# the manual-only live policy). Keeping the targets as thin aliases that
# point at test-live and exit 2 so any CI / cron / muscle-memory caller
# fails loudly. To run live: `make test-live FIXTURE=<name>`.
test-e2e:
	@echo "test-e2e is deprecated. Use 'make test-live FIXTURE=<name>' (v3.1.0 / spec 0.8)." ; \
	echo "See: make help" ; \
	exit 2

test-e2e-record:
	@echo "test-e2e-record is deprecated. Use 'make test-live FIXTURE=<name> RECORD=1' (v3.1.0 / spec 0.8)." ; \
	echo "Note: goldens are no longer a gate after 0.8; they are kept for debugging only." ; \
	exit 2

# Install the E2E harness's npm deps. Separate target so `make test-e2e`
# stays cheap when the deps are already installed.
test-e2e-install:
	cd .claude/tests/e2e && npm install

# L3 self-tests only — no API key needed. Runs ~55 offline unit specs
# that exercise the harness lib (trace schema, normalization, golden
# compare, fixture init). CI runs this as a separate job from the live
# tier so a broken harness fails fast without burning live-run budget.
test-e2e-unit:
	cd .claude/tests/e2e && npm run test:unit

# Offline plugin-manifest validator. Mirrors the schema the SDK runs at
# load time (see lib/validate-plugin-manifest.ts for the source) so we
# catch manifest drift without a live run.
manifest-validate:
	cd .claude/tests/e2e && npx tsx lib/validate-plugin-manifest.ts

# Phase E CI mirror. "What CI runs on a plain PR before the live job."
# Composes the offline tiers in the same order GitHub Actions runs them
# so local-vs-CI parity is one command. We deliberately do NOT call
# manifest-validate as part of test-all (which has older semantics) —
# it gets its own line here so a manifest-only regression surfaces
# distinctly.
#
# claude-workflow-plugin-fkm.1.11 — TWO changes, both deliberate:
#
# 1. IT RECORDS ITS OWN RESULT. The Stop gate runs the detected runner's
#    DEFAULT target, which on this repo is `make test` (L1) plus `make lint`.
#    It does not run this target and has no way to discover it, so it used to
#    print "technical checks passed" over a tree with four L2 specs red. The
#    gate now reads .claude/.qa-tracking/verification-ledger and reports what
#    was last recorded, against the tree it was measured at.
#
#    THE RECORDING COMMAND IS THIS RECIPE, NOT AN AGENT. That is the whole
#    reason it can be trusted at all: nobody types the exit code. It calls the
#    ONE definition of the tree fingerprint (verify-before-stop.sh
#    record-verification) rather than recomputing it here, so the writer and
#    the reader cannot drift — a second copy of that hash is exactly the
#    duplicate canonicalisation llh.18 exists to forbid.
#
# 2. IT NO LONGER FAILS FAST. The tiers were prerequisites, so make aborted at
#    the first red one — which meant a FAILING run recorded nothing and the
#    ledger would still be showing the last GREEN result. A staleness signal
#    that silently keeps a stale green is the defect this task is about, at one
#    remove. Running all four and returning the worst rc also matches CI, which
#    runs them as independent jobs.
#
# `|| true` on the record call: this is instrumentation. It must never be the
# reason a test run reports failure.
#
# THE DRY-RUN GUARD IS LOAD-BEARING, and it is here because it bit on the first
# try. `make -n` does NOT skip a recipe line that contains `$(MAKE)` — it runs
# it, so the whole line above executes under -n, the sub-makes print instead of
# running, rc stays 0, and the record call wrote `make test-ci exited 0` over a
# suite that had not run. A dry run minting a green record is the exact defect
# this feature exists to report on, so it is refused: under -n / -q / -t,
# MAKEFLAGS' first word carries the single-letter flags (measured: `n` for
# `make -n`, empty for `make --no-print-directory`), and we skip the write.
# Matching only the FIRST WORD is what keeps a long option that happens to
# contain the letter n from silently disabling the record on a real run.
# Regression: .claude/scripts/tests/gate-claim-honesty.test.sh section 5 drives
# both a real and a dry run of a Makefile carrying this exact guard — extracted
# from THIS file, never re-typed, so the probe cannot pass over a guard the repo
# does not ship. (It read "section 4" until fkm.1.11 QA round 2; section 4 is
# the tree fingerprint and invokes no make at all. A control attribution naming
# the wrong control is the same defect class as the claim below it.)
#
# STRICT_SECTIONS=1 is exported here and NOT in `make test` (a9hh R1-F1). This
# target's whole claim is "what CI runs", and .claude/tests/README.md says in
# so many words that a green test-ci means a green CI. The CI l1-unit job sets
# STRICT_SECTIONS=1, so without it here that implication is false in exactly
# the direction that hurts: a section skip is green locally and red in CI. It
# also means test-ci needs what CI provisions — both MCP servers' node_modules
# — and says so when they are missing, which is the point. `make test` stays
# lenient: it is the target you run fifty times a day on a laptop.
test-ci:
	@rc=0 ; \
	mf_first="$${MAKEFLAGS%% *}" ; dry=0 ; \
	case "$$mf_first" in *n*|*q*|*t*) dry=1 ;; esac ; \
	STRICT_SECTIONS=1 $(MAKE) --no-print-directory test || rc=$$? ; \
	$(MAKE) --no-print-directory test-component || rc=$$? ; \
	$(MAKE) --no-print-directory test-e2e-unit || rc=$$? ; \
	$(MAKE) --no-print-directory manifest-validate || rc=$$? ; \
	if [ "$$dry" = "1" ]; then \
		echo "test-ci: dry/question/touch run (MAKEFLAGS='$$MAKEFLAGS') — NOT recording a verification result" ; \
	else \
		bash .claude/scripts/verify-before-stop.sh record-verification "make test-ci" "$$rc" || true ; \
	fi ; \
	exit $$rc

# Diff the most recent replay against its committed golden. The FIXTURE
# variable scopes the search; default is whatever has the freshest
# replay file. This target exists for local sanity-checking before
# pushing — it mirrors the cassette-diff job in CI.
cassette-diff:
	@cd .claude/tests/e2e && \
	if [ -n "$$FIXTURE" ]; then \
		pattern="cassettes/replays/$$FIXTURE-*.jsonl" ; \
		golden="cassettes/golden/$$FIXTURE.jsonl" ; \
	else \
		pattern="cassettes/replays/*.jsonl" ; \
		golden="" ; \
	fi ; \
	latest=$$(ls -1t $$pattern 2>/dev/null | head -1) ; \
	if [ -z "$$latest" ]; then \
		echo "cassette-diff: no replays found (run 'make test-e2e' first)" ; \
		exit 2 ; \
	fi ; \
	if [ -z "$$golden" ]; then \
		base=$$(basename "$$latest" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}T.+\.jsonl$$//') ; \
		golden="cassettes/golden/$$base.jsonl" ; \
	fi ; \
	echo "Comparing replay: $$latest" ; \
	echo "       vs golden: $$golden" ; \
	npm run cassette-diff -- --replay "$$latest" --golden "$$golden"

lint: shellcheck

# shellcheck and agentlint are optional dev tools. We skip-with-warning
# rather than hard-fail when missing, mirroring the graceful-degradation
# pattern used in bd-github-link.sh (missing gh/bd/git -> silent skip-with-log,
# not block). Hard-failing here would conflict with cross-cutting principle #3
# (full autonomy, no permission/setup prompts blocking the workflow). CI can
# re-introduce strict mode by calling `shellcheck` directly instead of `make lint`.

shellcheck:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck not on PATH (skipping); install via 'brew install shellcheck' or apt for stricter local lint"; \
		exit 0; \
	else \
		shellcheck .claude/scripts/*.sh .claude/scripts/tests/*.sh .claude/tests/linux/*.sh .claude/tests/mutation/*.sh .claude/tests/mutation/lib/*.sh install.sh uninstall.sh; \
	fi

check:
	@if ! command -v agentlint >/dev/null 2>&1; then \
		echo "agentlint not on PATH (skipping); install via 'npm install -g agentlint-ai' to re-run the harness audit"; \
		exit 0; \
	else \
		agentlint check --format md --output-dir docs/; \
	fi

# install-test — install into a tempdir, then VERIFY IT ORCHESTRATES.
#
# The old body was the entire post-install verification in this repo and it was
# two `test` calls (`test -d .claude`, `test -f plugin.json`). Presence is what
# let both MCP servers ship dead and a SessionStart bail ship silent across
# three releases (v4.1 / claude-workflow-plugin-2br). The doctor executes the
# SessionStart hook, both MCP servers and both gate hooks against the rendered
# target, so a green `install-test` now means "this install runs", not "these
# files exist".
#
# The presence checks are kept AHEAD of the doctor on purpose: they fail with a
# one-line message when the copy itself did not happen, which is a clearer
# signal than eleven downstream check failures.
#
# mcp_bd / mcp_code_graph are NOT skipped here, and as of
# claude-workflow-plugin-z9m (C0b) THIS TARGET IS EXPECTED TO PASS. It used to
# be expected-red, and the red was the v4.1 P0 reproducing on demand: a rendered
# target had no .claude/mcp/*/node_modules, so both server checks failed. C0b
# made install.sh run `npm ci` per server IN THE TARGET, and that is what turns
# this green. Adding `--skip mcp_bd,mcp_code_graph` would make this command
# answer "yes, this install orchestrates" while the defect was live in every
# rendered target — the exact false green the epic exists to kill — so the skip
# stays absent now that it is no longer needed either.
#
# THIS TARGET NEEDS THE NETWORK. `npm ci` fetches from the npm registry, so an
# offline run fails at the dependency step. That is also why it is not CI-wired
# (test-ci is test + test-component + test-e2e-unit + manifest-validate) and why
# the L2 installer specs set CWP_SKIP_MCP_DEPS=1 / CWP_SKIP_VERIFY=1: this
# target is the ONE surface that exercises dependency provisioning for real.
#
# EXIT CODES ARE NOW MEANINGFUL, and the recipe reports which it got: install.sh
# exits 3 for "every file was written and a functional check does not pass",
# distinct from 1 for "aborted". A 3 here means the installer's OWN verification
# caught something; the recipe re-runs nothing and just points at the target.
# Run `make doctor` against this checkout for the same checks without installing.
install-test:
	@d=/tmp/cwp-install-test-$$$$ ; \
	rc=0 ; \
	{ bash install.sh "$$d" && \
	  test -d "$$d/.claude" && \
	  test -f "$$d/.claude-plugin/plugin.json" && \
	  test -f "$$d/.claude/scripts/workflow-doctor.sh" && \
	  bash "$$d/.claude/scripts/workflow-doctor.sh" --target "$$d" ; } || rc=$$? ; \
	if [ "$$rc" -ne 0 ]; then \
		echo "" ; \
		echo "install-test: FAILED (exit $$rc)." ; \
		echo "  This target is EXPECTED TO PASS since claude-workflow-plugin-z9m (C0b)." ; \
		echo "  A failure here is a real regression — read each failing check's indented" ; \
		echo "  fix: line above." ; \
		echo "  exit 3 = the files all landed and install.sh's own verification failed." ; \
		echo "  exit 1 = the install aborted, or the doctor found a failing check on re-run." ; \
		echo "  Offline? 'npm ci' needs the npm registry; there is no cached fallback." ; \
		echo "  Target left in place for inspection: $$d" ; \
	else \
		rm -rf "$$d" ; \
	fi ; \
	exit $$rc

# doctor — run the functional health checks against THIS checkout (or any
# target: `make doctor TARGET=/path/to/project`). Safe mid-session: every
# dynamic check EXCEPT `beads` runs in a throwaway sandbox copy, so the live
# .qa-tracking state and agent model pins are untouched. `beads` runs
# `bd doctor` against the real target on purpose (a copied database would be
# meaningless); it changes no issue data but can checkpoint the SQLite WAL.
# Use DOCTOR_ARGS="--skip beads" for a run that provably touches nothing.
#   make doctor
#   make doctor TARGET=/path/to/project
#   make doctor DOCTOR_ARGS="--skip mcp_bd,mcp_code_graph --json-out /tmp/d.json"
doctor:
	@t="$${TARGET:-$$(pwd)}" ; \
	bash .claude/scripts/workflow-doctor.sh --target "$$t" $(DOCTOR_ARGS)

clean:
	rm -rf .claude/.qa-tracking

# Re-sync the COMMITTED fixture hook-script copies to the canonical
# .claude/scripts/ set. This is the durable "sync step 4" bulk copy that
# heals the offline drift guard in
# .claude/tests/e2e/specs/_fixture-script-sync.unit.spec.ts (the
# "committed fixture scripts match canonical" describe) — distinct from
# runFixture's run-start syncFixtureScripts, which writes the same bytes
# but inside a git stash/restore lifecycle that rolls them back at end of
# run (so it never mutates the committed copies).
#
# The synced set MUST equal listCanonicalHookScripts(): every
# `.claude/scripts/*.sh` EXCEPT the harness-only / operator-only scripts —
# resolve-fixture-spec.sh (the Makefile fixture->spec resolver) and
# workflow-doctor.sh (an operator CLI; no hooks.json event maps to it and no
# hook shells out to it). Neither is ever invoked by a fixture hook. Copying
# either in would trip the guard's "no EXTRA .sh script" assertion, so the
# exclusion below is load-bearing and HAND-MIRRORS FIXTURE_SYNC_EXCLUDES in
# lib/runFixture.ts — both lists must change together.
# Idempotent: re-running after a clean sync is a no-op.
sync-fixtures:
	@canon=".claude/scripts" ; \
	fixroot=".claude/tests/e2e/fixtures" ; \
	if [ ! -d "$$canon" ]; then echo "sync-fixtures: canonical $$canon not found" ; exit 2 ; fi ; \
	if [ ! -d "$$fixroot" ]; then echo "sync-fixtures: $$fixroot not found" ; exit 2 ; fi ; \
	count=0 ; \
	for dir in "$$fixroot"/*/.claude/scripts; do \
		[ -d "$$dir" ] || continue ; \
		for src in "$$canon"/*.sh; do \
			base=$$(basename "$$src") ; \
			if [ "$$base" = "resolve-fixture-spec.sh" ]; then continue ; fi ; \
			if [ "$$base" = "workflow-doctor.sh" ]; then continue ; fi ; \
			cp "$$src" "$$dir/$$base" ; \
			chmod 0755 "$$dir/$$base" ; \
		done ; \
		count=$$((count + 1)) ; \
		echo "sync-fixtures: synced $$dir" ; \
	done ; \
	echo "sync-fixtures: re-synced $$count fixture script dir(s) to canonical $$canon"

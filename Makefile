# Makefile — convenience targets for the plugin's local test/lint loop.
# AgentLint W1 looks for `make test` / `make build` style commands as a
# language-agnostic signal that build and test paths are documented.

.PHONY: help test test-component test-all test-live test-e2e test-e2e-record test-e2e-install test-e2e-unit test-ci manifest-validate cassette-diff lint shellcheck check install-test clean

help:
	@echo "Targets:"
	@echo "  test              — run the plugin's bash test suite (L1 unit)"
	@echo "  test-component    — run hook-pipeline component tests (L2; Phase B)"
	@echo "  test-all          — run L1 unit + L2 component tiers (offline; CI-friendly)"
	@echo "  test-live         — run live E2E for ONE OR MORE fixtures (requires FIXTURE=name OR FIXTURES=\"a b c\";"
	@echo "                      paid; needs ANTHROPIC_API_KEY; pass CONFIRM=1 to skip the cost prompt; RECORD=1 to refresh cassettes)"
	@echo "  test-e2e          — DEPRECATED alias (prints pointer to test-live and exits 2)"
	@echo "  test-e2e-record   — DEPRECATED alias (use 'test-live RECORD=1')"
	@echo "  test-e2e-unit     — run only the offline self-tests of the E2E harness"
	@echo "  test-e2e-install  — install npm deps for the E2E harness"
	@echo "  manifest-validate — validate .claude-plugin/plugin.json (offline)"
	@echo "  test-ci           — run every offline tier (L1 + L2 + L3-unit + manifest); 'what CI runs without API key'"
	@echo "  cassette-diff     — diff the most recent replay vs its committed golden (set FIXTURE=name to scope)"
	@echo "  lint              — alias for shellcheck"
	@echo "  shellcheck        — run shellcheck on every hook script"
	@echo "  check             — run AgentLint against this repo"
	@echo "  install-test      — install into a tempdir and verify"
	@echo "  clean             — remove transient .qa-tracking state"

test:
	bash .claude/scripts/tests/run-tests.sh

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
test-ci: test test-component test-e2e-unit manifest-validate

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
		shellcheck .claude/scripts/*.sh .claude/scripts/tests/*.sh .claude/tests/mutation/*.sh .claude/tests/mutation/lib/*.sh install.sh uninstall.sh; \
	fi

check:
	@if ! command -v agentlint >/dev/null 2>&1; then \
		echo "agentlint not on PATH (skipping); install via 'npm install -g agentlint-ai' to re-run the harness audit"; \
		exit 0; \
	else \
		agentlint check --format md --output-dir docs/; \
	fi

install-test:
	bash install.sh /tmp/cwp-install-test-$$$$ && \
		test -d /tmp/cwp-install-test-$$$$/.claude && \
		test -f /tmp/cwp-install-test-$$$$/.claude-plugin/plugin.json

clean:
	rm -rf .claude/.qa-tracking

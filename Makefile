# Makefile — convenience targets for the plugin's local test/lint loop.
# AgentLint W1 looks for `make test` / `make build` style commands as a
# language-agnostic signal that build and test paths are documented.

.PHONY: help test test-component test-all test-e2e test-e2e-record test-e2e-install test-e2e-unit test-ci manifest-validate cassette-diff lint shellcheck check install-test clean

help:
	@echo "Targets:"
	@echo "  test              — run the plugin's bash test suite (L1 unit)"
	@echo "  test-component    — run hook-pipeline component tests (L2; Phase B)"
	@echo "  test-all          — run L1 unit + L2 component tiers (offline; CI-friendly)"
	@echo "  test-e2e          — run live SDK-driven E2E tests (L3; needs ANTHROPIC_API_KEY)"
	@echo "  test-e2e-unit     — run only the offline self-tests of the E2E harness (~55 tests)"
	@echo "  test-e2e-record   — same as test-e2e, captures missing golden cassettes"
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

# L3 / L4 E2E tier. Hits real Claude. Requires ANTHROPIC_API_KEY in env.
# We surface that requirement loudly rather than fail mid-run.
test-e2e:
	@if [ -z "$$ANTHROPIC_API_KEY" ]; then \
		echo "test-e2e: ANTHROPIC_API_KEY is not set. The E2E harness drives real Claude — set the key and rerun." ; \
		exit 2 ; \
	fi
	cd .claude/tests/e2e && npm test

# Record golden cassettes for any spec missing one. Existing cassettes are
# never overwritten silently — to refresh, delete the cassette and rerun.
test-e2e-record:
	@if [ -z "$$ANTHROPIC_API_KEY" ]; then \
		echo "test-e2e-record: ANTHROPIC_API_KEY is not set." ; \
		exit 2 ; \
	fi
	cd .claude/tests/e2e && RECORD_GOLDEN=1 npm run test:run

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
		shellcheck .claude/scripts/*.sh .claude/scripts/tests/*.sh install.sh uninstall.sh; \
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

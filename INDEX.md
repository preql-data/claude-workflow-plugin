# Index — claude-workflow-plugin

Quick reference for what lives at the repo root and where to read next. AI
agents and humans should both be able to navigate from here without
listing the directory.

## Entry points

- `CLAUDE.md` — project memory and conditional-loading checklist. Read first.
- `README.md` — user-facing pitch and install instructions.
- `HANDOFF.md` — cross-session handoff record with verify conditions.
- `CHANGELOG.md` — release history.
- `CONTRIBUTING.md` — extension points (new specialist, new hook) and design
  overrides vs. AgentLint.
- `SECURITY.md` — vulnerability reporting.
- `AGENTS.md` — companion to CLAUDE.md for non-Claude agent runtimes.

## Plugin assets

- `.claude-plugin/plugin.json` — plugin manifest. Declares agents, hooks,
  commands, skills, and MCP servers.
- `.claude/agents/` — five specialist agent prompts (orchestrator, qa,
  backend, frontend, devops).
- `.claude/scripts/` — hook scripts (intent-router, post-edit, qa-gate,
  verify-before-stop, etc.) and tests under `.claude/scripts/tests/`.
- `.claude/hooks/hooks.json` — hook bindings.
- `.claude/skills/workflow-engine/` — auto-loaded skill describing the
  always-on workflow.
- `.claude/mcp/` — bundled MCP servers (`bd-mcp`, `code-graph-mcp`).
- `.claude/settings.json` — runtime settings (model, thinking budget,
  permissions, additionalDirectories).
- `.mcp.json` — MCP server bindings copied to user repos.

## Test harness (G8)

- `.claude/tests/` — five-tier test pyramid root with `component/`, `e2e/`,
  and per-tier README.
- `.claude/tests/component/` — L2 component specs (15 specs, 243
  assertions; includes `qa-gate-baseline` codifying the 0wk.2 fix).
- `.claude/tests/e2e/` — L3 live e2e fixtures + golden cassettes
  (`node-react-auth`, `python-django-bug`, `go-cli-refactor`,
  `monorepo-frontend-only`, `multi-domain-signup`, `qa-block-recovery`).
- `.claude/scripts/tests/` — L1 bash unit tests (49 assertions).
- `.github/workflows/test.yml` — GitHub Actions CI: lint + 6 test jobs
  + L4 daily drift cron.

## Install / uninstall

- `install.sh`, `install.ps1` — copy plugin assets into a target repo.
- `uninstall.sh`, `uninstall.ps1` — reverse the install with a backup.
- `Makefile` — convenience targets for test, lint, agentlint check.

## Documentation

See `docs/` (which has its own index in `docs/plans/README.md`):

- `docs/AGENTS.md` — agent prompt reference.
- `docs/ARCHITECTURE.md` — full architecture write-up.
- `docs/BEADS.md` — Beads conventions used by the plugin.
- `docs/HOOKS.md` — every hook script's contract.
- `docs/MCP_SERVERS.md` — bd-mcp and code-graph-mcp interfaces.
- `docs/QUICKSTART.md` — first-run guide.
- `docs/TROUBLESHOOTING.md` — common failure modes.
- `docs/WORKFLOW.md` — end-to-end orchestration story.
- `docs/AGENTLINT_REPORT.md` — most recent harness audit (post-G8 Phase F).
- `docs/plans/` — execution plans (`v3-upgrade.md` and successors).

## Tests

- `tests/` -> symlink to `.claude/scripts/tests/`.
- Run: `make test` (or `bash tests/run-tests.sh` directly).
- Smoke install: `make install-test`.

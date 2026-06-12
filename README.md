# Claude Workflow Plugin

A plugin for [Claude Code](https://claude.ai) that turns "build me a feature"
into a tracked, reviewed, regression-tested change set — without you driving
every step.

[![Beads Required](https://img.shields.io/badge/Beads-Required-blue)](https://github.com/steveyegge/beads)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Compatible-green)](https://claude.ai)

## 🎯 What you get

- **Plain-English in, structured work out.** Describe a feature. The
  orchestrator breaks it into a Beads epic with subtasks, routes each
  subtask to a domain specialist (backend / frontend / devops / qa) that
  already knows OWASP, performance budgets, accessibility patterns, and
  root-cause analysis, and ships nothing until QA approves.
- **A QA gate that's a real Stop hook.** Claude literally cannot release
  the conversation without `qa-approved` on the active task. The decision
  is recorded in Beads as a label and a comment — full audit trail, no
  honour system. Bypass attempts are visible in the hook log.
- **Tasks survive sessions.** Specialists auto-claim work via
  `bd update --status in_progress`. PRs and Beads tasks auto-link to
  GitHub (issues, PRs, close-on-merge). Pick up tomorrow where you left
  off tonight.
- **Two MCP servers ship in the box.** `bd-mcp` exposes 21 typed Beads
  tools (no shell quoting bugs). `code-graph-mcp` exposes 7 graph tools
  (`code_search`, `code_context`, `symbol_callers`, `impact_of`,
  `dead_code`, `dependency_path`, `code_index_health`) backed by a
  tree-sitter + SQLite index. Both load automatically via `.mcp.json`
  and `${CLAUDE_PLUGIN_ROOT}`.
- **Regression coverage by construction.** Every QA iteration runs the
  full test suite. A module-A edit that breaks module-B's contract is
  caught before approval, not after. The plugin's own test pyramid (L1
  bash unit → L4 daily drift) demonstrates the pattern.

## ⚡ Install

The plugin requires Beads (`bd`) ≥ 0.47 and `jq`. The installer fails
fast if either is missing and prints the upgrade command.

### Fresh install

```bash
# curl-pipe (no clone needed)
curl -fsSL https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.sh | bash

# or clone-and-run
git clone https://github.com/preql-data/claude-workflow-plugin
cd claude-workflow-plugin
bash install.sh /path/to/your/project
```

### Upgrade from v2

The installer auto-detects v2 layouts (no `model:` frontmatter, no
`.claude-plugin/plugin.json`, no MCP servers) and migrates them. You can
also force upgrade mode explicitly:

```bash
# auto-detects v2 and migrates
curl -fsSL https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.sh | bash

# explicit upgrade
curl -fsSL https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.sh | bash -s -- --upgrade
```

Migration copies the existing `.claude/` to `.claude-v2-backup-<timestamp>/`
before writing v3 files, so user customizations are recoverable. Run the
diff after install to see what changed:

```bash
diff -r .claude-v2-backup-*/ .claude/
```

### Windows

```powershell
irm https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.ps1 | iex
```

PowerShell detects v2 layouts but does **not** perform the migration —
it prints a message asking you to run `install.sh` (via WSL or Git Bash)
for the upgrade. Fresh installs work natively in PowerShell.

## 📦 What you get on disk

| Component | Count | Where |
|-----------|-------|-------|
| Specialist agents | 5 | `.claude/agents/{orchestrator,qa,backend,frontend,devops}.md` |
| Hook scripts | 9 | `.claude/scripts/` (8 hook events + statusline) |
| MCP servers | 2 | `.claude/mcp/{bd-mcp,code-graph-mcp}/` |
| Slash commands | 1 | `.claude/commands/workflow-model.md` |
| Test tiers | 5 | L1 bash unit → L4 daily drift watch (`.claude/tests/`) |
| CI | GitHub Actions | `.github/workflows/test.yml` (lint + 6 test jobs + drift cron) |

The plugin manifest is at `.claude-plugin/plugin.json`. The MCP wiring
is at `.mcp.json`. Both use `${CLAUDE_PLUGIN_ROOT}` so the install works
regardless of project layout.

## 🛠 Customize / contribute

The plugin is designed to be modified by the people using it. The
workflow that ships in this repo runs ON this repo too — you can use
the plugin to upgrade itself.

To customize for your team:

1. Clone:
   ```bash
   git clone https://github.com/preql-data/claude-workflow-plugin
   cd claude-workflow-plugin
   ```

2. Open the cloned repo in Claude Code. The plugin loads automatically.

3. Describe what you want to change in plain English:
   - "Add a security specialist that reviews every backend change"
   - "Change the QA gate to require 80% test coverage before approval"
   - "Add a slash command that creates a fresh Beads epic from a spec doc"

   The orchestrator will create a Beads epic, route the work to the
   right specialist, and run it through the QA gate.

4. Claude will create a feature branch for the change. When QA approves,
   you commit and push. Open a PR upstream if it's a generally-useful
   addition.

The full contributor guide is in [`CONTRIBUTING.md`](CONTRIBUTING.md).
The test pyramid documentation in
[`.claude/tests/README.md`](.claude/tests/README.md) explains how to add
tests for your changes.

## 📐 Architecture

The orchestrator never edits code; specialists do, gated by QA. Hooks
enforce that contract — `prevent-orchestrator-edits.sh` blocks Write/Edit
from the orchestrator role, and `verify-before-stop.sh` refuses Stop
without `qa-approved` on the active task. Cross-repo work and GitHub
auto-linking land via I3/I8 hooks (`bd-github-link.sh`,
`current-task.sh`).

For the deep dive, read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
For the test pyramid that gates every change, read
[`.claude/tests/README.md`](.claude/tests/README.md). For the v3 release
notes (G8 harness, MCP servers, plugin manifest, etc.) read
[`CHANGELOG.md`](CHANGELOG.md).

## ⚠ Caveats

- Live e2e runs cost roughly $5–10 per fixture against Claude Opus 4.7.
  The offline gate (`make test-all`) is free and covers L1 + L2. As of
  v3.1.0, live runs are MANUAL ONLY: `make test-live FIXTURE=<name>`
  prints the estimated cost and prompts for confirmation before
  spending. There is no scheduled CI run that consumes API spend, and
  no automatic per-PR live tier. Live assertions are model-agnostic
  invariants declared in each fixture's `fixture.yaml` — goldens are
  retained as debugging references only.
- The upstream `bd` daemon has a stack-overflow on stale locks; the
  plugin ships a `--no-daemon` shim under `.claude/bin/bd` (inlined onto
  `PATH` in test fixtures). Production installs degrade gracefully.
- AgentLint flags a few intentional design choices (Bash auto-approve,
  tag-pinned actions); rationale is in [`CONTRIBUTING.md`](CONTRIBUTING.md)
  under "Design overrides vs. AgentLint".

---

<div align="center">

[Report Bug](../../issues) • [Request Feature](../../issues) • [Docs](docs/) • [Changelog](CHANGELOG.md)

</div>

# Project Memory — claude-workflow-plugin

This repository is a Claude Code plugin that wires a mandatory orchestrator -> specialist -> QA workflow on top of any project. It ships agent prompts, hook scripts, MCP servers, and install/uninstall scripts. Read this file first; it tells you where to go next based on what you're doing.

## Conditional loading (read these on demand)

Use this checklist instead of front-loading every doc. Pick the row matching the work and read the file.

- if you are editing an agent prompt -> read `.claude/agents/<role>.md` and `docs/AGENTS.md`
- if you are editing a hook script -> read `docs/HOOKS.md` and the script under `.claude/scripts/`
- if you are debugging a hook or helper script -> read `docs/HOOKS.md` and the relevant script under `.claude/scripts/`
- if you are editing the QA gate -> read `.claude/scripts/verify-before-stop.sh` and `.claude/scripts/qa-gate.sh`
- if you are adding or updating tests -> read `.claude/tests/README.md`
- if you are touching install / packaging -> read `install.sh`, `install.ps1`, `.claude-plugin/plugin.json`
- if you are touching MCP servers -> read `docs/MCP_SERVERS.md` and `.claude/mcp/<server>/`
- if you are debugging an MCP issue -> read `docs/MCP_SERVERS.md` and `.claude/mcp/<server>/`
- if you are extending the workflow with a new specialist -> read `CONTRIBUTING.md`
- if you are looking at past releases -> read `CHANGELOG.md`
- if you need the broader plan -> read `docs/WORKFLOW.md` and `docs/ARCHITECTURE.md`
- if you are starting non-trivial planning (epics, multi-domain work, anything an orchestrator decomposes) -> read `LESSONS.md`

## Local test

Run the plugin's own test suite before pushing. The tests cover the QA gate, intent router, and hook scripts. The Makefile is the canonical entry point.

```bash
make test
# Equivalent to:
bash tests/run-tests.sh             # via the symlink shim
bash .claude/scripts/tests/run-tests.sh   # direct path
```

The `tests/` symlink at the repo root points at `.claude/scripts/tests/` so AI agents and CI can use the conventional `bash tests/` invocation.

Lint hook scripts (shellcheck must be on PATH):

```bash
make lint
# Equivalent to: shellcheck .claude/scripts/*.sh .claude/scripts/tests/*.sh install.sh uninstall.sh
```

Validate the plugin manifest:

```bash
node -e 'JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8"))'
```

Re-run AgentLint after non-trivial changes (writes report to `docs/`):

```bash
make check
# Equivalent to: agentlint check --format md --output-dir docs/
```

## Handoff and current focus

When you finish a task, update Beads via `bd update <id>` rather than leaving notes in this file. The v3 upgrade plan at `docs/plans/v3-upgrade.md` (mirrored from `/Users/edk0/.claude/plans/we-are-working-on-dynamic-marshmallow.md`) is complete: Phases 0-7, the G8 test-harness epic, and the post-G8 closeout all shipped on `main` by 2026-05-11. See `CHANGELOG.md` `[3.0.0] - 2026-05-11` for the full per-phase breakdown.

For multi-session continuity, refer to:
- `bd list --status in_progress --json` for the live work queue.
- `.beads/issues.jsonl` for Beads ground truth.
- `docs/AGENTLINT_REPORT.md` for the most recent harness audit.

## Rules (Don't / Instead / Because)

These rules guide every change. Ordered by how often they trip us up.

- Don't have the orchestrator write code directly.
  Instead: delegate to a specialist agent and let them handle the Write/Edit calls.
  Because: the orchestrator's tool list strips Write/Edit (see `prevent-orchestrator-edits.sh`); bypassing this defeats the structural guard the plugin sells as its core value.

- Don't add `permissions.deny` rules to settings.json.
  Instead: broaden `permissions.allow` so specialists run unattended.
  Because: principle 3 of the v3 plan is "full autonomy, no permission prompts"; every deny rule becomes a future user-facing approval prompt.

- Don't pin a specific Opus version (e.g., `claude-opus-4-7`) in agent prompts directly.
  Instead: reference `${CLAUDE_LATEST_OPUS}` from settings.json or use `/workflow-model`.
  Because: models go stale; auto-upgrade is principle 2 of the v3 plan.

- Don't keyword-match user intent in hooks (e.g., grep for "test" then route to qa).
  Instead: let Claude's natural language understanding pick the specialist.
  Because: principle 5 is "intent-based routing, never keyword-based"; keyword routers misfire under paraphrase.

- Don't bypass the QA gate via marker files or comment-text fallbacks.
  Instead: set the `qa-approved` Beads label via `qa-gate.sh approve`.
  Because: the gate's single source of truth is the Beads label; any side channel makes the gate non-deterministic.

- Don't skip Stop-hook re-entry protection.
  Instead: check `stop_hook_active` from stdin and exit 0 if true.
  Because: the Stop hook will infinite-loop and burn tokens otherwise (AgentLint H3).

- Don't ship hardcoded personal paths or emails in source files.
  Instead: use environment variables or read from git config at runtime.
  Because: committed PII is permanent in git history (AgentLint S7, S9).

## Architecture (one-paragraph map)

The plugin is five agent prompts (`orchestrator`, `qa`, `backend`, `frontend`, `devops`) plus seven hook scripts that gate Claude's behavior. The orchestrator delegates by intent; specialists implement; QA gates with a multi-stage check (test, lint, type, security pass) before allowing the Stop hook to release. Beads stores all task state; bd-mcp surfaces it; code-context-mcp pre-loads call sites for QA's regression assessment. Settings give every agent maximum thinking budget and full Bash access. `LESSONS.md` at the repo root is the institutional-memory ledger — append-only via `.claude/scripts/lessons.sh add '<lesson>' --source <task-id>`, read by the orchestrator before decomposing non-trivial work, never hand-edited. See `docs/ARCHITECTURE.md` for the full diagram.

## Beads labels

- `backend`, `frontend`, `devops` — domain tracking.
- `qa-pending` — awaiting QA review.
- `qa-gate-entered` — QA has claimed the task; gate is armed.
- `qa-approved` — QA has signed off; Stop hook releases.
- `qa-blocked` — QA found issues; specialist must fix.
- `bug`, `improvement` — work type.

## Known antipatterns (check before implementing)

These were the recurring mistakes from prior phases. Verify your change does not reintroduce them.

- Stop hook without `stop_hook_active` guard -> infinite loop.
- Hook script emitting raw text instead of `{"hookSpecificOutput": ...}` -> Claude ignores the output silently.
- File-extension allowlist in `post-edit.sh` -> markdown / yaml / Dockerfile changes go untracked.
- Comment-text fallback in `verify-before-stop.sh` for QA approval -> bypasses the label gate.
- Specialist tool list narrowed below the broad set -> specialist hits an "unauthorized tool" wall mid-task.
- `additionalDirectories` missing from settings -> plugin can't read the parent project tree.

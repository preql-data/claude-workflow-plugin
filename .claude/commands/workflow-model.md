---
description: Pin a new model identifier across all workflow agents (orchestrator, qa, backend, frontend, devops, and the future grader). Claude-invokable; the user types intent in plain English and Claude calls this when a newer model lands.
argument-hint: <model-id>
---

# /workflow-model

Pin every workflow agent (and the `CLAUDE_LATEST_OPUS` env hint) to a new
model identifier. The new model id is provided as the single argument: `$1`.

This command is for Claude to invoke. The user is not expected to type it; if
they ask in natural language ("upgrade to the new Opus", "switch the workflow
to claude-opus-5-1"), you call this command with the model id derived from
their request or from `bd doctor` / SessionStart's model-select output.

It is also the rollback path for automatic switches made by
`model-select.sh apply` (spec 0.3): every auto-switch is logged on the
standing "Model selection log" Beads task with a `/workflow-model <old-id>`
rollback line. Run that line to revert.

## What it does

1. Validates the argument is a plausible model id (kebab-case, with the
   optional `[1m]` 1M-context-window suffix documented at
   /docs/en/model-config).
2. Rewrites the `model:` field in every agent file the plugin ships:
   - `.claude/agents/orchestrator.md`
   - `.claude/agents/qa.md`
   - `.claude/agents/backend.md`
   - `.claude/agents/frontend.md`
   - `.claude/agents/devops.md`
   - `.claude/agents/grader.md` (Phase A; rewrite is a no-op until the
     file exists)
3. Updates `CLAUDE_LATEST_OPUS` in `.claude/settings.json` (`env` block)
   so any tooling that still reads the env var sees the new pin.
4. Prints a unified summary diff (one line per file) so the operator can
   see what changed without opening each file.

The actual rewrite lives in `.claude/scripts/workflow-model-apply.sh`. This
command delegates to that script so `model-select.sh apply` and
`/workflow-model` always agree on the pin shape — spec 0.3 calls this out
explicitly as the "factor the rewrite" requirement.

## Implementation steps (run as a single bash invocation)

```bash
NEW_MODEL="${1:?usage: /workflow-model <model-id>}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
bash "$PROJECT_DIR/.claude/scripts/workflow-model-apply.sh" "$NEW_MODEL"
echo ""
echo "Restart Claude Code (or open a new session) for the new model to take effect."
```

## Notes for Claude

- The shared script handles validation, agent-file rewrite, settings.json
  env-hint update, idempotency, and the per-file summary lines. Keep this
  command file as the thin wrapper — do not duplicate the rewrite logic.
- After running, you do NOT need to ask the user for permission. This is a
  declarative config change; no destructive ops.
- If `bd` is installed in the project, consider also opening a Beads task
  recording the manual upgrade so it shows in cross-session context.
  Automatic upgrades from `model-select.sh apply` already record themselves
  on the "Model selection log" meta-task.

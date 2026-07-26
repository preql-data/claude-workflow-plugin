---
description: Pin a new model identifier across all workflow agents (orchestrator, qa, backend, frontend, devops, grader, judge), or scope the pin to one role class. Claude-invokable; the user types intent in plain English and Claude calls this when a newer model lands.
argument-hint: [--role <orchestrator|implementer|reviewer|all>] <model-id>
---

# /workflow-model

Pin every workflow agent (and the `CLAUDE_LATEST_OPUS` env hint) to a new
model identifier. The new model id is provided as the single argument: `$1`.

## Role scoping (v4.0.0 Phase V1)

The rewrite is now role-aware. Two forms:

- `/workflow-model <model-id>` — the UNCHANGED single-arg contract: pins
  **every** agent to `<model-id>`. This is the rollback path — running the
  `Rollback:` line recorded on the "Model selection log" meta-task reverts
  the whole workflow to a prior pin.
- `/workflow-model --role <role> <model-id>` — pins only one role class:
  - `orchestrator` -> `orchestrator.md`
  - `implementer` -> `backend.md`, `frontend.md`, `devops.md`
  - `reviewer` -> `qa.md`, `grader.md`, `judge.md`
  - `all` -> every agent (same as the bare form)

  `CLAUDE_LATEST_OPUS` in settings.json is refreshed only when the role is
  `all` or `implementer` (the env hint now means "latest opus-class = the
  implementer lane"). Automatic per-role switches from `model-select.sh
  apply` record a `Rollback: /workflow-model --role <role> <old-id>` line so
  a single lane can be reverted without disturbing the others.

Which model each role auto-adopts is configured in `.claude/model-roles`
(orchestrator/reviewer default to `top`, implementer to `opus-class`).

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
2. Rewrites the `model:` field in the agent files for the targeted role
   (all agents by default):
   - `.claude/agents/orchestrator.md`
   - `.claude/agents/qa.md`
   - `.claude/agents/backend.md`
   - `.claude/agents/frontend.md`
   - `.claude/agents/devops.md`
   - `.claude/agents/grader.md`
   - `.claude/agents/judge.md`
   (a rewrite is a no-op for any file that does not yet exist)
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
if [ "$#" -eq 0 ]; then
    echo "usage: /workflow-model [--role <orchestrator|implementer|reviewer|all>] <model-id>" >&2
    exit 1
fi
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# Pass every argument through so both the bare-id (pin everything) and the
# --role <role> <id> forms reach the shared helper unchanged.
bash "$PROJECT_DIR/.claude/scripts/workflow-model-apply.sh" "$@"
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

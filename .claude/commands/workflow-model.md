---
description: Pin a new model identifier across all five workflow agents (orchestrator, qa, backend, frontend, devops). Claude-invokable; the user types intent in plain English and Claude calls this when a newer Opus generation lands.
argument-hint: <model-id>
---

# /workflow-model

Pin every workflow agent (and the `CLAUDE_LATEST_OPUS` env hint) to a new model
identifier. The new model id is provided as the single argument: `$1`.

This command is for Claude to invoke. The user is not expected to type it; if
they ask in natural language ("upgrade to the new Opus", "switch the workflow
to claude-opus-5-1"), you call this command with the model id derived from
their request or from `bd doctor` / SessionStart's stale-model warning.

## What it does

1. Validates the argument is a plausible model id (non-empty, kebab-case).
2. Rewrites the `model:` field in:
   - `.claude/agents/orchestrator.md`
   - `.claude/agents/qa.md`
   - `.claude/agents/backend.md`
   - `.claude/agents/frontend.md`
   - `.claude/agents/devops.md`
3. Updates `CLAUDE_LATEST_OPUS` in `.claude/settings.json` (`env` block) so the
   SessionStart hook stops warning about staleness.
4. Prints a unified summary diff (one line per file) so the operator can see
   what changed without opening each file.

## Implementation steps (run as a single bash invocation)

```bash
NEW_MODEL="${1:?usage: /workflow-model <model-id>}"

if ! echo "$NEW_MODEL" | grep -Eq '^[a-z0-9][a-z0-9.-]*$'; then
    echo "Refusing: '$NEW_MODEL' does not look like a model id (need lowercase kebab-case)."
    exit 1
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
AGENTS=(orchestrator qa backend frontend devops)
CHANGED=0

for agent in "${AGENTS[@]}"; do
    f="$PROJECT_DIR/.claude/agents/${agent}.md"
    if [ ! -f "$f" ]; then
        echo "skip: $f (missing)"
        continue
    fi
    OLD=$(grep -E '^model:' "$f" | head -1 | awk '{print $2}')
    if [ "$OLD" = "$NEW_MODEL" ]; then
        echo "unchanged: ${agent} (already $NEW_MODEL)"
        continue
    fi
    # Cross-platform sed: write to tmp then mv
    awk -v new="$NEW_MODEL" '
        /^model:/ && !done { print "model: " new; done=1; next }
        { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "updated: ${agent}: ${OLD:-<none>} -> $NEW_MODEL"
    CHANGED=$((CHANGED + 1))
done

# Update settings.json env hint via jq
SETTINGS="$PROJECT_DIR/.claude/settings.json"
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    OLD_HINT=$(jq -r '.env.CLAUDE_LATEST_OPUS // ""' "$SETTINGS")
    if [ "$OLD_HINT" != "$NEW_MODEL" ]; then
        jq --arg m "$NEW_MODEL" '.env.CLAUDE_LATEST_OPUS = $m' "$SETTINGS" > "$SETTINGS.tmp" \
            && mv "$SETTINGS.tmp" "$SETTINGS"
        echo "updated: settings.json env.CLAUDE_LATEST_OPUS: ${OLD_HINT:-<none>} -> $NEW_MODEL"
    fi
fi

echo ""
echo "Summary: $CHANGED agent file(s) updated to $NEW_MODEL."
echo "Restart Claude Code (or open a new session) for the new model to take effect."
```

## Notes for Claude

- The agent frontmatter comment in each `.md` file references this command --
  keep them in sync if you ever change the trigger name.
- After running, you do NOT need to ask the user for permission. This is a
  declarative config change; no destructive ops.
- If `bd` is installed in the project, consider also opening a Beads task
  recording the upgrade so it shows in cross-session context.

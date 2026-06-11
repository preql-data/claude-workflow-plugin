#!/bin/bash
# workflow-model-apply.sh — rewrite the model: pin across every workflow
# agent and update env.CLAUDE_LATEST_OPUS in settings.json.
#
# Spec 0.3 (claude-workflow-plugin-e0d.3): the model-select.sh helper and
# the /workflow-model slash command both need the same idempotent rewrite
# step, so the logic lives here once and both call into it. /workflow-model
# stays a thin shell over this script; model-select.sh's apply path calls
# it once a better model has been resolved.
#
# Usage:
#   workflow-model-apply.sh <new-model-id>
#       Validates the id (kebab-case + optional [1m] suffix), rewrites
#       every agents/*.md model: line, updates settings.json's
#       env.CLAUDE_LATEST_OPUS via jq, prints a one-line summary per file.
#
# Exit codes:
#   0  rewrite completed (zero or more files actually changed; idempotent)
#   1  invalid model id or write failure
#
# Environment:
#   CLAUDE_PROJECT_DIR  project root (defaults to pwd). Same convention as
#                       every other hook script in the plugin.

set -u

NEW_MODEL="${1:-}"
if [ -z "$NEW_MODEL" ]; then
    printf 'usage: %s <new-model-id>\n' "$(basename "$0")" >&2
    exit 1
fi

# Accept kebab-case ids plus the optional [1m] context-window suffix
# documented at /docs/en/model-config (e.g. claude-opus-4-8[1m]). Aliases
# like "opus" / "fable" / "best" are also kebab-case lowercase so they
# fall through the same regex.
if ! printf '%s' "$NEW_MODEL" | grep -Eq '^[a-z0-9][a-z0-9.-]*(\[1m\])?$'; then
    printf 'Refusing: %q does not look like a model id (need lowercase kebab-case, optional [1m] suffix).\n' "$NEW_MODEL" >&2
    exit 1
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
AGENTS=(orchestrator qa backend frontend devops)
# Phase A (spec): grader.md is added in a later phase; include it here
# pre-emptively so the rewrite covers it the moment the file lands. The
# loop already tolerates missing files.
AGENTS+=(grader)

CHANGED=0

for agent in "${AGENTS[@]}"; do
    f="$PROJECT_DIR/.claude/agents/${agent}.md"
    if [ ! -f "$f" ]; then
        # grader.md not yet present is the expected Phase 0 state; stay
        # silent rather than spamming the operator. Other missing agents
        # are an installer bug and we surface them.
        if [ "$agent" != "grader" ]; then
            printf 'skip: %s (missing)\n' "$f"
        fi
        continue
    fi
    OLD=$(grep -E '^model:' "$f" | head -1 | awk '{print $2}')
    if [ "$OLD" = "$NEW_MODEL" ]; then
        printf 'unchanged: %s (already %s)\n' "$agent" "$NEW_MODEL"
        continue
    fi
    # Cross-platform sed-equivalent via awk: rewrite the first model:
    # frontmatter line, then move atomically.
    if ! awk -v new="$NEW_MODEL" '
        /^model:/ && !done { print "model: " new; done=1; next }
        { print }
    ' "$f" > "$f.tmp"; then
        printf 'error: failed to rewrite %s\n' "$f" >&2
        rm -f "$f.tmp"
        exit 1
    fi
    mv "$f.tmp" "$f"
    printf 'updated: %s: %s -> %s\n' "$agent" "${OLD:-<none>}" "$NEW_MODEL"
    CHANGED=$((CHANGED + 1))
done

# Settings.json env hint. CLAUDE_LATEST_OPUS retains its historical name
# for backward-compat with the existing SessionStart warning that no
# longer fires (we replaced it with model-select.sh's one-liner). The
# env var still threads into agent context where prompts reference it.
SETTINGS="$PROJECT_DIR/.claude/settings.json"
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    OLD_HINT=$(jq -r '.env.CLAUDE_LATEST_OPUS // ""' "$SETTINGS")
    if [ "$OLD_HINT" != "$NEW_MODEL" ]; then
        if ! jq --arg m "$NEW_MODEL" '.env.CLAUDE_LATEST_OPUS = $m' "$SETTINGS" > "$SETTINGS.tmp"; then
            printf 'error: jq failed to update %s\n' "$SETTINGS" >&2
            rm -f "$SETTINGS.tmp"
            exit 1
        fi
        mv "$SETTINGS.tmp" "$SETTINGS"
        printf 'updated: settings.json env.CLAUDE_LATEST_OPUS: %s -> %s\n' \
            "${OLD_HINT:-<none>}" "$NEW_MODEL"
    fi
fi

printf '\nSummary: %d agent file(s) updated to %s.\n' "$CHANGED" "$NEW_MODEL"
exit 0

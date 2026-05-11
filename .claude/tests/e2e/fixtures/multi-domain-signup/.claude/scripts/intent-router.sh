#!/bin/bash
# UserPromptSubmit Hook: Enforces mandatory agent delegation.
#
# Phase 5 (E2/E15): the workflow rules text is no longer embedded inline here.
# Single source of truth is `.claude/skills/workflow-engine/SKILL.md`. This
# hook reads the skill body (skipping the YAML frontmatter) and injects it
# into the additionalContext envelope. When SKILL.md changes, this hook
# automatically picks up the new rules.
#
# Analysis is LLM-driven, but delegation is MANDATORY.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
WORKFLOW_SKILL="$PROJECT_DIR/.claude/skills/workflow-engine/SKILL.md"

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "$INPUT")

# F3 (Phase 4 fix pass): single source of truth for active task id. The
# helper file IS the source of truth — no `bd list --status in_progress`
# fallback (that would resurrect the brittle "first in_progress" anti-pattern
# Phase 1 was supposed to eliminate). Empty helper file means "no active task".
get_current_task() {
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        tid=$(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null | tr -d '\r\n[:space:]' || echo "")
    fi
    printf '%s' "$tid"
}

# B12: skip the workflow injection only on real signals (intent-based, not a
# length heuristic). Two skip cases:
#   1. Slash-command-only inputs with no arg, e.g. /help, /clear.
#   2. Short conversational acknowledgements: ok / thanks / yes / no / sure /
#      cool / nice / hmm / got it / sounds good (case-insensitive, optional
#      trailing punctuation).
TRIMMED=$(printf '%s' "$PROMPT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

if [[ "$TRIMMED" =~ ^/[A-Za-z][A-Za-z0-9_-]*$ ]]; then
    echo "{}"; exit 0
fi

shopt -s nocasematch
if [[ "$TRIMMED" =~ ^(ok|okay|thanks?|thank\ you|yes|no|sure|cool|nice|hmm|got\ it|sounds\ good)[\.\!\?]?$ ]]; then
    shopt -u nocasematch
    echo "{}"; exit 0
fi
shopt -u nocasematch

# Get current Beads state.
#
# F3 read MUST happen unconditionally — the helper file is local to the
# project and has no dependency on bd availability. Previously the read
# was nested inside the `command -v bd && [ -d .beads ]` check, which meant
# bd-unavailable sessions silently dropped the persisted task id and
# violated the F3 docstring contract.
CURRENT_TASK=$(get_current_task)
CURRENT_TASK_INFO=""
IN_PROGRESS_COUNT=0
if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
    IN_PROGRESS=$(bd list --status in_progress --json 2>/dev/null || echo "[]")
    [ -z "$IN_PROGRESS" ] && IN_PROGRESS="[]"
    IN_PROGRESS_COUNT=$(echo "$IN_PROGRESS" | jq 'length' 2>/dev/null || echo "0")
    IN_PROGRESS_COUNT="${IN_PROGRESS_COUNT:-0}"
    if [ -n "$CURRENT_TASK" ]; then
        CURRENT_TASK_INFO=$(bd show "$CURRENT_TASK" 2>/dev/null | head -20 || echo "")
    fi
fi

# Phase 5 / E2-E15: load the canonical workflow rules from the skill file.
# Strip YAML frontmatter so the LLM sees only the prose. If the skill file
# is missing (e.g., partial install), fall back to a minimal stub that
# still asserts mandatory delegation.
load_skill_body() {
    if [ -f "$WORKFLOW_SKILL" ]; then
        # Skip the frontmatter: read everything AFTER the second "---" marker
        # at the top of the file. awk is portable and handles the multiline
        # case cleanly (sed alternatives stumble on macOS BSD sed).
        awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; next} n>=2{print}' "$WORKFLOW_SKILL"
    else
        printf '%s\n' "## Mandatory agent delegation (fallback)"
        printf '%s\n' ""
        printf '%s\n' "You are the Orchestrator. You MUST delegate work to specialists."
        printf '%s\n' "Do not implement code yourself. Use Task() to delegate to @backend,"
        printf '%s\n' "@frontend, or @devops, then @qa for review before completion."
        printf '%s\n' ""
        printf '%s\n' "(Workflow skill SKILL.md not found at $WORKFLOW_SKILL — this is a stub.)"
    fi
}

WORKFLOW_BODY=$(load_skill_body)
WORKFLOW_CONTEXT="
<workflow_engine source=\"skills/workflow-engine/SKILL.md\">
$WORKFLOW_BODY
</workflow_engine>"

# Add current task context whenever the F3 helper file points at one. This
# is independent of bd availability — the helper file is the source of
# truth (Phase 4 fix pass / MINOR follow-up).
if [ -n "$CURRENT_TASK" ]; then
    WORKFLOW_CONTEXT+="
<current_work>
## Currently In Progress: $CURRENT_TASK

$CURRENT_TASK_INFO

If continuing this task, delegate next steps to appropriate specialist.
</current_work>"
fi

cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $(echo "$WORKFLOW_CONTEXT" | jq -Rs .)
  }
}
EOF

#!/bin/bash
# SubagentStart Hook (J3 — Phase 6b).
#
# Fires when Claude Code spawns a subagent. We use it to auto-assign the
# active Beads task to the spawned specialist via additionalContext, so the
# orchestrator doesn't need to repeat the task id and a brief in the
# Task() prompt.
#
# Per the Claude Code hooks reference (https://docs.claude.com/en/docs/claude-code/hooks):
#   - SubagentStart input includes `agent_type` (the subagent name like
#     "@backend", "@qa", or built-ins "general-purpose"/"Explore"/"Plan").
#   - SubagentStart hooks CANNOT block subagent creation, but CAN inject
#     `additionalContext` into the spawned subagent's first turn.
#
# Behaviour:
#   1. Read the incoming JSON from stdin; extract `agent_type`.
#   2. If the agent_type is one of our specialist names (backend, frontend,
#      devops, qa — with or without leading @), AND the current-task helper
#      file is non-empty, emit additionalContext containing the task id +
#      a brief summary pulled from `bd show <id>` (header lines only).
#   3. Otherwise emit `{}` and exit cleanly.
#
# Autonomy: this hook is silent on every error (per principle #3 — full
# autonomy, no user prompts). Failures fall through to the empty-output
# path so subagent creation never gets blocked or noisy.
#
# Phase 6b note: when this script ships before SubagentStart support
# stabilises in the runtime, it is harmless — the hook entry simply
# never fires. CHANGELOG documents the dependency.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"

# Always emit a non-blocking empty result on any failure path. The function
# is the catch-all for "we couldn't do anything useful, but don't want to
# break subagent creation".
emit_empty() { echo '{}'; exit 0; }

# Best-effort logger. Same shape as verify-before-stop.sh / qa-gate.sh.
log_sync_error() {
    local msg="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    printf '%s\t[subagent-start]\t%s\n' "$ts" "$msg" >> "$SYNC_ERRORS_LOG" 2>/dev/null || true
}

# F3 single-source-of-truth read. Empty stdout = no active task.
get_current_task() {
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        tid=$(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null | tr -d '\r\n[:space:]' || echo "")
    fi
    printf '%s' "$tid"
}

# Normalize an agent_type into a canonical short name. Strip a leading "@"
# so "@backend" and "backend" map to the same handler. Lowercase to be
# tolerant of case variations.
normalize_agent_type() {
    local raw="$1"
    [ -z "$raw" ] && return 0
    # Strip leading @ (orchestrator-style) and surrounding whitespace.
    local short
    short=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*@*//' -e 's/[[:space:]]*$//')
    # Lowercase. tr is portable (BSD + GNU).
    printf '%s' "$short" | tr '[:upper:]' '[:lower:]'
}

# Decide if a normalized agent_type is a specialist we want to auto-assign for.
# Built-in agents (general-purpose, Explore, Plan) are not specialists in our
# workflow — they don't claim Beads tasks — so we skip them.
is_specialist() {
    case "$1" in
        backend|frontend|devops|qa) return 0 ;;
        *) return 1 ;;
    esac
}

# Read the input. If stdin is empty (script invoked manually for testing),
# fall through to the empty-output path.
INPUT=$(cat 2>/dev/null || echo "")
if [ -z "$INPUT" ]; then
    emit_empty
fi

# Extract agent_type. The official input field per the docs is `agent_type`.
# We also accept `subagent_type` for forward compatibility (an earlier
# proposal used that name).
AGENT_TYPE=""
if command -v jq >/dev/null 2>&1; then
    AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // .subagent_type // empty' 2>/dev/null || echo "")
fi
if [ -z "$AGENT_TYPE" ]; then
    # Without jq, or with malformed JSON, we can't reliably extract the
    # field. Emit empty rather than guessing.
    emit_empty
fi

CANON=$(normalize_agent_type "$AGENT_TYPE")
if ! is_specialist "$CANON"; then
    # Not a specialist. Nothing to inject.
    emit_empty
fi

CURRENT_TASK=$(get_current_task)
if [ -z "$CURRENT_TASK" ]; then
    # No active task to assign. Don't surface anything; the spawned
    # specialist will see SessionStart's pending list and pick on its own.
    emit_empty
fi

# Pull a short summary of the task. We keep this conservative — no full
# bd show dump (that can be hundreds of lines), just the header lines + the
# notes. The specialist can run bd_show_task or bd_doc_read for the rest.
TASK_HEADER=""
TASK_NOTES_TAIL=""
TASK_LABELS=""
if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
    SHOW_OUT=$(bd show "$CURRENT_TASK" 2>/dev/null || echo "")
    if [ -n "$SHOW_OUT" ]; then
        # First 8 lines: typically id, title, owner, type, created, updated.
        TASK_HEADER=$(printf '%s\n' "$SHOW_OUT" | head -8)
    fi
    # Last 30 lines of NOTES section if present. We don't try to parse the
    # exact section boundaries — head/tail of the full output is good enough.
    if [ -n "$SHOW_OUT" ]; then
        # Look for a "NOTES" line and grab up to 30 lines after it.
        TASK_NOTES_TAIL=$(printf '%s\n' "$SHOW_OUT" | awk '/^NOTES[[:space:]]*$/{found=1; next} found{print}' | head -30 || echo "")
    fi
    # Labels from --json (if available).
    LABELS_JSON=$(bd show "$CURRENT_TASK" --json 2>/dev/null || echo "")
    if [ -n "$LABELS_JSON" ] && command -v jq >/dev/null 2>&1; then
        TASK_LABELS=$(printf '%s' "$LABELS_JSON" | jq -r '
            (if type == "array" then .[0] else . end)
            | .labels // []
            | join(", ")
        ' 2>/dev/null || echo "")
    fi
fi

# Build the additionalContext envelope. We keep this short and structured
# so the specialist sees it instantly without needing to scroll.
CONTEXT=""
read -r -d '' CONTEXT <<EOF || true
<subagent_assignment>
You are spawning as the @${CANON} specialist. The orchestrator's currently
active Beads task is: ${CURRENT_TASK}

${TASK_HEADER:+Task header:
${TASK_HEADER}}

${TASK_LABELS:+Labels: ${TASK_LABELS}}

${TASK_NOTES_TAIL:+Recent notes (last 30 lines):
${TASK_NOTES_TAIL}}

Action: claim or continue this task. The Phase 6a J29/J4 convention is
that the orchestrator may have written a SPEC doc on this task before
spawning you — read it FIRST via the bd_doc_read MCP tool:

  bd_doc_read(task_id="${CURRENT_TASK}", name="spec")

(Or, if the orchestrator chose a different name, list what's attached
first via bd_doc_read(task_id="${CURRENT_TASK}", list_only=true).)

If no spec/context doc is attached, the Task() prompt is your full brief.
</subagent_assignment>
EOF

# Emit the additionalContext envelope. SubagentStart accepts the standard
# JSON-output additionalContext field per the hooks reference.
if command -v jq >/dev/null 2>&1; then
    JSON_CONTEXT=$(printf '%s' "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": $JSON_CONTEXT
  }
}
EOF
    exit 0
fi

# jq absent — fall back to empty rather than emitting malformed JSON.
log_sync_error "jq not available; cannot emit SubagentStart additionalContext for $CURRENT_TASK -> @${CANON}"
emit_empty

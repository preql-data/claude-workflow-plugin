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
# V3 (claude-workflow-plugin-jio.1) adds one side effect between 2 and 3: for
# the three IMPLEMENTING roles (backend/frontend/devops — never qa) the hook
# appends an `IMPLEMENTER: role=<r> task=<t> at <ts>` Beads comment, once per
# (role, task). That record is the implementer set `review-check.sh gate`
# reads, which `qa-gate.sh approve` and the Stop hook use to refuse a
# self-review. It is best-effort: a failure logs and never blocks the spawn.
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

# V3 (claude-workflow-plugin-jio.1): is this agent_type an IMPLEMENTING role?
#
# The review-separation gate needs to know WHO wrote the code so it can refuse
# an approval whose reviewer is one of them. Only the three implementing
# specialists count. qa (and the grader/judge relays) REVIEW — recording them
# as implementers would make every single-agent review non-independent and the
# gate would refuse every approval.
is_implementer_role() {
    case "$1" in
        backend|frontend|devops) return 0 ;;
        *) return 1 ;;
    esac
}

# record_implementer <role> <task-id> — append the IMPLEMENTER identity record
# that `review-check.sh gate` greps for the implementer set.
#
# Grammar (load-bearing, matched by `^IMPLEMENTER: role=([a-z]+) ` in the
# shipped counter — the trailing space after the role is part of the contract):
#   IMPLEMENTER: role=<backend|frontend|devops> task=<tid> at <ISO8601-UTC>
#
# Contract:
#   - IDEMPOTENT per (role, task): a re-spawn of the same specialist on the
#     same task posts nothing. A multi-domain task spawning backend AND
#     frontend gets ONE record per distinct role (the gate de-dupes anyway,
#     but a clean audit trail beats a noisy one).
#   - BEST-EFFORT: every failure path logs to sync-errors.log and returns
#     non-zero; the caller ignores the result. A SubagentStart hook must never
#     block or slow a spawn, and the additionalContext envelope below is
#     emitted regardless.
record_implementer() {
    local role="$1" tid="$2"
    [ -n "$role" ] && [ -n "$tid" ] || return 1
    command -v bd >/dev/null 2>&1 || return 1
    [ -d "$PROJECT_DIR/.beads" ] || return 1

    # Existing records for this task, first line of each comment (all the
    # grammar records are single-line, so line-oriented matching is correct).
    local existing=""
    existing=$(bd show "$tid" --json 2>/dev/null \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // []
                 | .[].text | split("\n")[0]' 2>/dev/null || echo "")

    # IMPLEMENTER-IDEMPOTENCY-GUARD (load-bearing; the L2 META mutates this
    # grep so duplicates post, which must break the "posted exactly once"
    # assertion). The pattern mirrors the gate's own capture.
    if printf '%s\n' "$existing" | grep -qE "^IMPLEMENTER: role=${role} "; then
        return 0
    fi

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    local record="IMPLEMENTER: role=$role task=$tid at $ts"
    # Newer Beads: `bd comments add` (plural). Older: `bd comment add`.
    if bd comments add "$tid" "$record" >/dev/null 2>&1 \
        || bd comment add "$tid" "$record" >/dev/null 2>&1; then
        return 0
    fi
    log_sync_error "failed to record implementer identity ($role) on $tid; review-check gate will see an incomplete implementer set"
    return 1
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

# V0 (cnz.1): fail-open spawn-evidence log. Append one TSV line
# "<utc-ts>\t<agent_type>" for EVERY spawn (specialists AND built-ins like
# general-purpose/Explore/Plan/grader/judge) — the effort A/B interference
# test (cnz.2) reads this to prove which agent types the runtime spawned and
# to catch ultracode's dynamic workflow layer spawning generic agents. This
# runs BEFORE the is_specialist filter on purpose. It never blocks the spawn:
# any failure is swallowed and the existing JSON output below is unchanged.
mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" "$AGENT_TYPE" \
    >> "$QA_TRACKING_DIR/subagent-spawns.log" 2>/dev/null || true

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

# V3 (claude-workflow-plugin-jio.1): record WHO is about to implement.
#
# This is the input half of "nobody signs off on their own work". The spawn is
# the only moment the workflow knows, mechanically, which role touched the
# task — an after-the-fact heuristic (label, comment prose, git author) is
# guessable at best and forgeable at worst. `qa-gate.sh approve` and the Stop
# hook both refuse when the recorded reviewer is in this set.
#
# `|| true` is load-bearing under `set -e` (line 31): a bd hiccup here must
# NEVER block a subagent spawn. record_implementer already logs its own
# failures to sync-errors.log; the additionalContext emission below is
# unaffected either way.
if is_implementer_role "$CANON"; then
    record_implementer "$CANON" "$CURRENT_TASK" || true
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

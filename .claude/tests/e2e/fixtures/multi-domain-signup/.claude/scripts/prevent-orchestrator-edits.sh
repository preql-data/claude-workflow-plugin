#!/bin/bash
# prevent-orchestrator-edits.sh - PreToolUse handler (E3, Phase 4).
#
# Structural complement to C1 (orchestrator's tool list omits Write/Edit).
# When the active subagent is `orchestrator`, this hook blocks Write/Edit/
# MultiEdit invocations and emits a "delegate to specialist" reason.
#
# Reliability principle: only enforce when the data is reliable. The Claude
# Code PreToolUse payload may or may not include subagent identity depending
# on runtime version. We accept several plausible field names and ONLY block
# when at least one of them clearly identifies the active subagent as the
# orchestrator. We never false-positive: when the data is missing, we let
# the call through (the orchestrator's tool list still prevents accidental
# writes; this hook is defense-in-depth, not the only line of defense).
#
# Output (Phase 5 / E9 standardisation):
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                          "permissionDecision":"deny",
#                          "permissionDecisionReason":"..."}}
#   {} otherwise (no-op)
#
# Per the Claude Code hooks reference, PreToolUse uses
# `hookSpecificOutput.permissionDecision` (allow|deny|ask|defer) plus
# `permissionDecisionReason` rather than the top-level
# `{"decision":"block",...}` shape (which is for Stop / UserPromptSubmit /
# PostToolUse / PreCompact). The legacy top-level form was tolerated by
# some runtime versions but is no longer the recommended schema; we
# standardise on hookSpecificOutput across all hooks (E9).

set -e

INPUT=$(cat)

# Probe likely fields for the active subagent / agent name. We try several
# candidate paths because Claude Code's PreToolUse payload schema has
# evolved; missing fields return empty rather than null and the OR chain
# will pick whichever is populated.
SUBAGENT=""
for path in \
    '.subagent_name' \
    '.active_subagent' \
    '.agent.name' \
    '.session.subagent_name' \
    '.context.subagent_name' \
    '.context.active_agent' \
    '.invocation_context.subagent' \
; do
    val=$(echo "$INPUT" | jq -r "$path // empty" 2>/dev/null || echo "")
    if [ -n "$val" ] && [ "$val" != "null" ]; then
        SUBAGENT="$val"
        break
    fi
done

# Lower-case for case-insensitive comparison.
SUBAGENT_LC=$(printf '%s' "$SUBAGENT" | tr '[:upper:]' '[:lower:]')

# Strip a leading `@` (some signal sources prefix it, others don't) and
# trim whitespace.
SUBAGENT_NORM=$(printf '%s' "$SUBAGENT_LC" | sed -e 's/^@//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# Only act when we have a concrete signal that this is THE orchestrator.
#
# Phase 4 fix pass / MINOR: the previous matcher was `*orchestrator*` glob,
# which would false-positive on subagent names like `data-orchestrator-pipeline`
# or `payment-orchestrator-test`. Now we use an exact-match list so other
# specialist agents that happen to contain the substring are unaffected.
case "$SUBAGENT_NORM" in
    orchestrator|subagent_orchestrator|claude-orchestrator)
        REASON='Orchestrator must delegate code edits to specialists.

Use Task("@backend", "...") for API/database/server logic,
Task("@frontend", "...") for UI/components/styling, or
Task("@devops", "...") for CI/CD/infrastructure.

The orchestrator role exists to coordinate; the specialists exist to
implement. The plugin enforces this structurally:
  - Orchestrators tool list omits Write/Edit (cannot reach for them).
  - This PreToolUse hook blocks them when delegated to anyway.

If you genuinely need to edit a file as part of orchestration (extremely
rare - e.g., updating CLAUDE.md as part of a planning task), spawn an
explicit Task("@devops", "...") for the edit and pass the change brief.'
        # E9: hookSpecificOutput.permissionDecision is the modern shape.
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
            "$(printf '%s' "$REASON" | jq -Rs .)"
        exit 0
        ;;
esac

# No reliable orchestrator signal - allow.
echo '{}'

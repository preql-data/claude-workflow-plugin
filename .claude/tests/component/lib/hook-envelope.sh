#!/bin/bash
# hook-envelope.sh - Hook output JSON-envelope validators.
#
# Phase B (claude-workflow-plugin-0wk.11). Generalised from the per-script
# assertions in phase5-synthetic-tests.sh:183-233. Each helper:
#   - Bumps the caller's PASS / FAIL counters via the assert_* helpers.
#   - Tolerates `{}` as a valid no-op envelope.
#   - Uses jq when present (every plugin host today ships jq).
#
# Helpers:
#   assert_valid_envelope <name> <json>
#       JSON parses cleanly AND is either `{}` or carries `hookSpecificOutput`
#       or a top-level `decision` (Stop / UserPromptSubmit / PostToolUse
#       per the Claude Code hooks reference).
#
#   assert_hook_event <name> <json> <expected-event>
#       hookSpecificOutput.hookEventName equals <expected-event>.
#       Use this on hookSpecificOutput-shaped outputs (SessionStart,
#       UserPromptSubmit, PreToolUse, PostToolUse, Stop additionalContext).
#
#   assert_decision <name> <json> <expected-decision>
#       Top-level decision field equals <expected-decision>.
#       Use this on Stop/SubagentStop/UserPromptSubmit/PostToolUse outputs.
#
#   assert_permission_decision <name> <json> <expected-decision>
#       hookSpecificOutput.permissionDecision equals <expected-decision>.
#       Use this on PreToolUse-shaped outputs (allow | deny | ask | defer).
#
#   assert_empty_envelope <name> <json>
#       JSON parses and is the literal `{}`.

if [ -n "${__COMPONENT_HOOK_ENVELOPE_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
__COMPONENT_HOOK_ENVELOPE_SH_SOURCED=1

# Best-effort: source assert.sh if not already loaded so callers can use
# this file standalone in interactive debugging.
if [ -z "${__COMPONENT_ASSERT_SH_SOURCED:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/assert.sh" ]; then
    # shellcheck source=./assert.sh
    . "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
fi

assert_valid_envelope() {
    local name="$1" json="$2"
    if ! command -v jq >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    jq missing on PATH\n' "$name"
        return
    fi
    if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    not valid JSON: %s\n' "$name" "$json"
        return
    fi
    # `{}` counts as valid (no-op). Otherwise require hookSpecificOutput
    # or decision keys.
    local compact
    compact=$(printf '%s' "$json" | jq -c '.' 2>/dev/null)
    if [ "$compact" = "{}" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s (no-op envelope)\n' "$name"
        return
    fi
    local has_hook has_decision
    has_hook=$(printf '%s' "$json" | jq -r 'has("hookSpecificOutput")' 2>/dev/null)
    has_decision=$(printf '%s' "$json" | jq -r 'has("decision")' 2>/dev/null)
    if [ "$has_hook" = "true" ] || [ "$has_decision" = "true" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    no hookSpecificOutput or decision key: %s\n' \
            "$name" "$json"
    fi
}

assert_hook_event() {
    local name="$1" json="$2" expected="$3"
    assert_json_field "$name" "$json" '.hookSpecificOutput.hookEventName' "$expected"
}

assert_decision() {
    local name="$1" json="$2" expected="$3"
    assert_json_field "$name" "$json" '.decision' "$expected"
}

assert_permission_decision() {
    local name="$1" json="$2" expected="$3"
    assert_json_field "$name" "$json" '.hookSpecificOutput.permissionDecision' "$expected"
}

assert_empty_envelope() {
    local name="$1" json="$2"
    if ! command -v jq >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    jq missing on PATH\n' "$name"
        return
    fi
    local compact
    compact=$(printf '%s' "$json" | jq -c '.' 2>/dev/null)
    if [ "$compact" = "{}" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected {}, got: %s\n' "$name" "$compact"
    fi
}

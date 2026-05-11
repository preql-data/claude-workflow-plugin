#!/bin/bash
# prevent-orchestrator-edits.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers E3 (Phase 4): the
# PreToolUse handler that blocks Write/Edit/MultiEdit when the active
# subagent is `orchestrator`, returning `{}` (allow) for specialists.
#
# Per the modern schema, the hook returns
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                          "permissionDecision":"deny",
#                          "permissionDecisionReason":"..."}}
# on a block, and {} for any other input.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
HOOK="$FIXTURE/.claude/scripts/prevent-orchestrator-edits.sh"

# 1. Orchestrator + Write -> deny.
OUT=$(printf '%s' '{"subagent_name":"orchestrator","tool_name":"Write"}' | bash "$HOOK")
assert_valid_envelope "prevent-orch: orch+Write returns valid envelope" "$OUT"
assert_hook_event "prevent-orch: orch+Write hookEventName" "$OUT" "PreToolUse"
assert_permission_decision "prevent-orch: orch+Write permissionDecision=deny" "$OUT" "deny"

# 2. Orchestrator + Edit -> deny.
OUT=$(printf '%s' '{"subagent_name":"orchestrator","tool_name":"Edit"}' | bash "$HOOK")
assert_permission_decision "prevent-orch: orch+Edit denied" "$OUT" "deny"

# 3. Orchestrator + MultiEdit -> deny.
OUT=$(printf '%s' '{"subagent_name":"orchestrator","tool_name":"MultiEdit"}' | bash "$HOOK")
assert_permission_decision "prevent-orch: orch+MultiEdit denied" "$OUT" "deny"

# 4. The reason text mentions delegating to specialists (regression: don't
# let the prose drift away from the agreed message).
REASON=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
assert_match "prevent-orch: reason mentions delegation" \
    "(delegate|specialist)" "$REASON"

# 5. Specialist + Write -> allow (empty envelope).
OUT=$(printf '%s' '{"subagent_name":"backend","tool_name":"Write"}' | bash "$HOOK")
assert_empty_envelope "prevent-orch: backend allowed" "$OUT"

OUT=$(printf '%s' '{"subagent_name":"frontend","tool_name":"Edit"}' | bash "$HOOK")
assert_empty_envelope "prevent-orch: frontend allowed" "$OUT"

OUT=$(printf '%s' '{"subagent_name":"qa","tool_name":"Write"}' | bash "$HOOK")
assert_empty_envelope "prevent-orch: qa allowed" "$OUT"

# 6. `@orchestrator` (with leading @) -> deny (the normaliser strips @).
OUT=$(printf '%s' '{"subagent_name":"@orchestrator","tool_name":"Write"}' | bash "$HOOK")
assert_permission_decision "prevent-orch: @orchestrator denied" "$OUT" "deny"

# 7. Case insensitivity: ORCHESTRATOR -> deny.
OUT=$(printf '%s' '{"subagent_name":"ORCHESTRATOR","tool_name":"Write"}' | bash "$HOOK")
assert_permission_decision "prevent-orch: ORCHESTRATOR case-insensitive" "$OUT" "deny"

# 8. Substring false-positive guard: `data-orchestrator-pipeline` should NOT
# be blocked (the Phase 4 fix replaced glob with exact-match).
OUT=$(printf '%s' '{"subagent_name":"data-orchestrator-pipeline","tool_name":"Write"}' | bash "$HOOK")
assert_empty_envelope "prevent-orch: substring 'orchestrator' in compound name allowed" "$OUT"

# 9. Missing subagent signal -> allow (defense in depth, not the only line).
OUT=$(printf '%s' '{"tool_name":"Write"}' | bash "$HOOK")
assert_empty_envelope "prevent-orch: missing subagent name allowed" "$OUT"

# 10. Alternative field name `active_subagent`.
OUT=$(printf '%s' '{"active_subagent":"orchestrator","tool_name":"Write"}' | bash "$HOOK")
assert_permission_decision "prevent-orch: active_subagent field probed" "$OUT" "deny"

[ "$FAIL" -eq 0 ]

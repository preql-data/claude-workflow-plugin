#!/bin/bash
# subagent-start.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers J3 (Phase 6b): when a
# SubagentStart event names one of our specialists, the hook injects the
# active Beads task id and a brief summary via additionalContext.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
HOOK="$FIXTURE/.claude/scripts/subagent-start.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"

# Seed an active Beads task.
TID=$(cd "$FIXTURE" && bd create "Test subagent task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
assert_match "subagent-start: seed task id created" '^[a-z0-9-]+\.' "$TID"
bash "$CT" set "$TID"

# 1. agent_type=backend + active task -> additionalContext injected.
OUT=$(printf '%s' "{\"agent_type\":\"backend\"}" | bash "$HOOK")
assert_valid_envelope "subagent-start: backend valid envelope" "$OUT"
assert_hook_event "subagent-start: backend hookEventName" "$OUT" "SubagentStart"
# The additionalContext should mention the spawned specialist + the task id.
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: context mentions @backend" "@backend" "$CTX"
assert_contains "subagent-start: context contains task id" "$TID" "$CTX"
assert_match "subagent-start: context references SPEC doc convention" \
    "bd_doc_read" "$CTX"

# 2. agent_type=frontend -> @frontend in the context body.
OUT=$(printf '%s' "{\"agent_type\":\"frontend\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: @frontend in context" "@frontend" "$CTX"

# 3. agent_type=qa -> @qa in the context body.
OUT=$(printf '%s' "{\"agent_type\":\"qa\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: @qa in context" "@qa" "$CTX"

# 4. agent_type=devops -> @devops in the context body.
OUT=$(printf '%s' "{\"agent_type\":\"devops\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: @devops in context" "@devops" "$CTX"

# 5. Built-in agent (general-purpose) -> {} (no injection).
OUT=$(printf '%s' "{\"agent_type\":\"general-purpose\"}" | bash "$HOOK")
assert_empty_envelope "subagent-start: general-purpose no-op" "$OUT"

OUT=$(printf '%s' "{\"agent_type\":\"Explore\"}" | bash "$HOOK")
assert_empty_envelope "subagent-start: Explore no-op" "$OUT"

OUT=$(printf '%s' "{\"agent_type\":\"Plan\"}" | bash "$HOOK")
assert_empty_envelope "subagent-start: Plan no-op" "$OUT"

# 6. @-prefixed agent_type is normalised correctly.
OUT=$(printf '%s' "{\"agent_type\":\"@backend\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: @-prefix normalised to backend" "@backend" "$CTX"

# 7. Forward-compat field name `subagent_type` is accepted.
OUT=$(printf '%s' "{\"subagent_type\":\"backend\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: subagent_type field accepted" "@backend" "$CTX"

# 8. No active task -> {} (the spawned agent will see SessionStart's list).
bash "$CT" clear
OUT=$(printf '%s' "{\"agent_type\":\"backend\"}" | bash "$HOOK")
assert_empty_envelope "subagent-start: no-active-task no-op" "$OUT"

# 9. Empty stdin -> {} (no crash on manual invocations).
OUT=$(printf '' | bash "$HOOK")
assert_empty_envelope "subagent-start: empty stdin no-op" "$OUT"

# 10. Missing agent_type -> {} (the hook can't decide which specialist).
OUT=$(printf '%s' "{}" | bash "$HOOK")
assert_empty_envelope "subagent-start: empty JSON no-op" "$OUT"

[ "$FAIL" -eq 0 ]

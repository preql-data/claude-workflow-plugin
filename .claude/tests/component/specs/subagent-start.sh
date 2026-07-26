#!/bin/bash
# subagent-start.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers J3 (Phase 6b): when a
# SubagentStart event names one of our specialists, the hook injects the
# active Beads task id and a brief summary via additionalContext.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent (CI runner, BD_SHIM_ONLY=1).
# Every assertion below depends on the seeded Beads task (the additionalContext
# the hook injects must mention the task id) — no bd, no signal.
bd_required_or_skip

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

# ===========================================================================
# IMPLEMENTER identity records (v4.0.0 Phase V3 / claude-workflow-plugin-jio.1).
#
# The spawn is the ONE moment the workflow knows, mechanically, which role is
# about to touch a task. `review-check.sh gate` reads those records as the
# implementer set and `qa-gate.sh approve` refuses when the recorded reviewer
# is in it — so a MISSING record silently makes self-review legal, and a
# WRONG one (qa recorded as an implementer) makes every single-agent review
# non-independent and deadlocks the gate. Both directions are asserted.
#
# Grammar (matched by the shipped counter's `^IMPLEMENTER: role=([a-z]+) `):
#   IMPLEMENTER: role=<backend|frontend|devops> task=<tid> at <ISO8601-UTC>
# ===========================================================================

implementer_lines() {
    # All IMPLEMENTER record first-lines on a task (one per line).
    bd show "$1" --json 2>/dev/null \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // []
                 | .[].text | split("\n")[0]' 2>/dev/null \
        | grep -E '^IMPLEMENTER: ' || true
}

count_role() {
    # count_role <tid> <role> -> number of records for that role.
    implementer_lines "$1" | grep -cE "^IMPLEMENTER: role=$2 " | tr -d '[:space:]'
}

TID_IMPL=$(cd "$FIXTURE" && bd create "implementer identity" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$CT" set "$TID_IMPL"

# I1. A backend spawn records the identity exactly once, with the exact grammar.
printf '%s' '{"agent_type":"backend"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: backend spawn records the identity" "1" \
    "$(count_role "$TID_IMPL" backend)"
assert_match "implementer: record matches the counter's grammar (role, task, ISO ts)" \
    "^IMPLEMENTER: role=backend task=${TID_IMPL} at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" \
    "$(implementer_lines "$TID_IMPL" | grep 'role=backend' | head -1)"

# I2. IDEMPOTENT: re-spawning the same role on the same task adds nothing.
# (A re-spawn per iteration is normal; duplicate records would make the audit
# trail unreadable without changing the gate's verdict.)
printf '%s' '{"agent_type":"backend"}' | bash "$HOOK" >/dev/null
printf '%s' '{"agent_type":"@backend"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: re-spawn does NOT duplicate the record" "1" \
    "$(count_role "$TID_IMPL" backend)"

# I3. A REVIEWING agent is never recorded as an implementer. This is the
# assertion that keeps single-agent review viable: if qa were recorded here,
# the qa-claude artifact would be non-independent and approve would refuse
# forever.
printf '%s' '{"agent_type":"qa"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: a qa spawn records NOTHING (reviewers are not implementers)" \
    "0" "$(count_role "$TID_IMPL" qa)"

# I4. Multi-domain task: one record per DISTINCT role.
printf '%s' '{"agent_type":"frontend"}' | bash "$HOOK" >/dev/null
printf '%s' '{"agent_type":"devops"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: a second role gets its own record" "1" \
    "$(count_role "$TID_IMPL" frontend)"
assert_eq "implementer: a third role gets its own record" "1" \
    "$(count_role "$TID_IMPL" devops)"
assert_eq "implementer: three distinct roles -> exactly three records" "3" \
    "$(implementer_lines "$TID_IMPL" | grep -c . | tr -d '[:space:]')"

# I5. Non-specialist spawns are untouched by the new side effect.
printf '%s' '{"agent_type":"general-purpose"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: a general-purpose spawn records nothing" "3" \
    "$(implementer_lines "$TID_IMPL" | grep -c . | tr -d '[:space:]')"

# I6. The existing additionalContext contract still holds alongside the write.
OUT=$(printf '%s' '{"agent_type":"backend"}' | bash "$HOOK")
assert_valid_envelope "implementer: envelope still valid with the identity write" "$OUT"
assert_contains "implementer: additionalContext still carries the task id" "$TID_IMPL" \
    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')"

# I7. Best-effort: with bd off PATH the hook must still emit its envelope
# (a spawn is never blocked by a bookkeeping failure).
TID_NOBD=$(cd "$FIXTURE" && bd create "implementer no-bd" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$CT" set "$TID_NOBD"
NOBD_OUT=$(PATH="/usr/bin:/bin" bash "$HOOK" <<< '{"agent_type":"backend"}' 2>/dev/null || echo "")
NOBD_JSON_OK=$(printf '%s' "$NOBD_OUT" | jq -e . >/dev/null 2>&1 && echo yes || echo no)
assert_eq "implementer: bd absent -> hook still emits valid JSON (never blocks a spawn)" \
    "yes" "$NOBD_JSON_OK"

# I8. META: break the idempotency guard in a COPY (invert the grep so the
# "already recorded" branch never fires) -> a re-spawn DUPLICATES the record,
# i.e. assertion I2 would fail. Proves I2 is sensitive to the guard rather
# than to some incidental de-duplication elsewhere. TEXT-anchored on the guard
# (LESSONS llh.20), not on a line number.
REAL_HOOK=$(readlink "$HOOK" 2>/dev/null || printf '%s' "$HOOK")
HOOK_MUT="$FIXTURE/subagent-start-dupmut.sh"
awk '
    /if printf .%s\\n. "\$existing" \| grep -qE "\^IMPLEMENTER: role=\$\{role\} "; then/ {
        print "    if [ \"no\" = \"yes\" ]; then"
        mutated=1
        next
    }
    { print }
    END { if (!mutated) exit 7 }
' "$REAL_HOOK" > "$HOOK_MUT"
MUT_RC=$?
chmod +x "$HOOK_MUT"
assert_eq "implementer META: idempotency guard located + mutated in the copy" "0" "$MUT_RC"
if [ "$MUT_RC" -eq 0 ]; then
    TID_MUT=$(cd "$FIXTURE" && bd create "implementer META dup" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$CT" set "$TID_MUT"
    printf '%s' '{"agent_type":"backend"}' | bash "$HOOK_MUT" >/dev/null
    printf '%s' '{"agent_type":"backend"}' | bash "$HOOK_MUT" >/dev/null
    assert_eq "implementer META: with the guard broken a re-spawn DUPLICATES (I2 WOULD fail)" \
        "2" "$(count_role "$TID_MUT" backend)"
fi

[ "$FAIL" -eq 0 ]

#!/bin/bash
# 00-smoke.sh - Sanity check that the L2 harness wires up correctly.
#
# Phase B (claude-workflow-plugin-0wk.11). Verifies:
#   - mk_fixture produces a usable project root (bd initialised, scripts
#     symlinked, CLAUDE_PROJECT_DIR set).
#   - The assert.sh helpers update PASS/FAIL counters consistently.
#   - The hook-envelope helpers parse JSON correctly.
#   - The shim.sh helpers stub a command and record its argv.
#
# Lives at the head of the spec listing so when run.sh runs in order this
# fails first if the runner / lib wiring is broken, rather than every
# downstream spec failing for the same root cause.

set -u

# Fixture sanity. mk_fixture must be invoked WITHOUT command substitution
# so its exports (CLAUDE_PROJECT_DIR, PATH) reach the spec's shell.
mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent in BD_SHIM_ONLY=1 mode
# (CI runners). The smoke spec exercises `bd create` at the bottom; we
# can't fake that without a more elaborate shim. Dev-machine path is
# unchanged.
bd_required_or_skip

assert_eq "smoke: mk_fixture returns a non-empty path" "0" "$([ -n "$FIXTURE" ] && echo 0 || echo 1)"
assert_eq "smoke: fixture exists as a directory" "0" "$([ -d "$FIXTURE" ] && echo 0 || echo 1)"
assert_eq "smoke: .claude/.qa-tracking present" "0" "$([ -d "$FIXTURE/.claude/.qa-tracking" ] && echo 0 || echo 1)"
assert_eq "smoke: .beads present" "0" "$([ -d "$FIXTURE/.beads" ] && echo 0 || echo 1)"
assert_eq "smoke: CLAUDE_PROJECT_DIR exported" "$FIXTURE" "$CLAUDE_PROJECT_DIR"
assert_eq "smoke: current-task.sh symlinked in" "0" "$([ -L "$FIXTURE/.claude/scripts/current-task.sh" ] && echo 0 || echo 1)"

# Shim sanity.
mk_shim "fake-cmd" "$FIXTURE" 0 "hello from shim" >/dev/null
OUT=$("$FIXTURE/bin/fake-cmd" arg1 "arg with spaces")
assert_eq "smoke: shim stdout" "hello from shim" "$OUT"
assert_eq "smoke: shim recorded argv" "0" \
    "$(shim_argv_contains "$FIXTURE" "fake-cmd" "arg with spaces" && echo 0 || echo 1)"

# Hook-envelope sanity. Try both a no-op and a hookSpecificOutput shape.
assert_valid_envelope "smoke: {} is a valid envelope" '{}'
assert_valid_envelope "smoke: hookSpecificOutput envelope ok" \
    '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"x"}}'
assert_valid_envelope "smoke: top-level decision envelope ok" \
    '{"decision":"block","reason":"nope"}'
assert_hook_event "smoke: hookEventName extraction" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse"}}' "PreToolUse"
assert_decision "smoke: decision extraction" \
    '{"decision":"block","reason":"x"}' "block"
assert_permission_decision "smoke: permissionDecision extraction" \
    '{"hookSpecificOutput":{"permissionDecision":"deny"}}' "deny"
assert_empty_envelope "smoke: literal {} envelope" '{}'

# JSON-field extraction.
assert_json_field "smoke: json field a.b.c" \
    '{"a":{"b":{"c":"deep"}}}' '.a.b.c' "deep"

# Bd is real in the fixture (the wrapper just adds --no-daemon). Confirm
# bd_show on a freshly-created task works through the wrapper.
TID=$(cd "$FIXTURE" && bd create "Smoke test task" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null)
assert_match "smoke: bd create returned a task id" '^[a-z0-9-]+\.' "$TID"

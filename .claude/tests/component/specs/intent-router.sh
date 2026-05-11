#!/bin/bash
# intent-router.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers the UserPromptSubmit
# hook: inject workflow_engine context for real prompts, skip on slash
# commands and short conversational acks.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent (CI runner, BD_SHIM_ONLY=1).
# The current_work-block assertion (test §5) seeds a real Beads task to
# verify the active-task augmentation; without bd that scenario can't run,
# and the spec is short enough that we'd rather skip the whole thing than
# carry a half-coverage variant.
bd_required_or_skip

IR="$FIXTURE/.claude/scripts/intent-router.sh"

# 1. Real prompt -> UserPromptSubmit envelope with workflow_engine context.
OUT=$(printf '%s' '{"prompt":"add a login endpoint"}' | bash "$IR")
assert_valid_envelope "intent-router: real-prompt valid envelope" "$OUT"
assert_hook_event "intent-router: real-prompt event=UserPromptSubmit" "$OUT" "UserPromptSubmit"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "intent-router: context contains workflow_engine envelope" \
    '<workflow_engine source=' "$CTX"

# 2. Slash command -> {} (skip).
OUT=$(printf '%s' '{"prompt":"/help"}' | bash "$IR")
assert_empty_envelope "intent-router: /help skipped" "$OUT"

OUT=$(printf '%s' '{"prompt":"/clear"}' | bash "$IR")
assert_empty_envelope "intent-router: /clear skipped" "$OUT"

# 3. Conversational ack -> {} (skip). Cover a few key examples.
for ack in "ok" "thanks" "yes" "no" "sure" "cool" "got it" "sounds good"; do
    OUT=$(printf '%s' "{\"prompt\":\"$ack\"}" | bash "$IR")
    assert_empty_envelope "intent-router: ack '$ack' skipped" "$OUT"
done

# 4. Case-insensitive ack skip.
OUT=$(printf '%s' '{"prompt":"OK"}' | bash "$IR")
assert_empty_envelope "intent-router: uppercase OK skipped" "$OUT"

OUT=$(printf '%s' '{"prompt":"Thanks!"}' | bash "$IR")
assert_empty_envelope "intent-router: punctuated Thanks! skipped" "$OUT"

# 5. With an active task, the context includes a current_work block.
CT="$FIXTURE/.claude/scripts/current-task.sh"
TID=$(cd "$FIXTURE" && bd create "Active task for IR" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$CT" set "$TID"
OUT=$(printf '%s' '{"prompt":"continue the work"}' | bash "$IR")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "intent-router: current_work block included" \
    '<current_work>' "$CTX"
assert_contains "intent-router: current_work mentions task id" "$TID" "$CTX"

# 6. Prompt with newlines / multi-line -> still emits valid JSON.
OUT=$(printf '%s' '{"prompt":"line one\nline two"}' | bash "$IR")
assert_valid_envelope "intent-router: multi-line prompt valid envelope" "$OUT"

# 7. Empty prompt object -> skips workflow injection? The script reads
# .prompt and if empty just emits the workflow context unconditionally
# (no skip for empty). We verify the script still emits a valid envelope.
OUT=$(printf '%s' '{}' | bash "$IR")
assert_valid_envelope "intent-router: empty input still valid envelope" "$OUT"

[ "$FAIL" -eq 0 ]

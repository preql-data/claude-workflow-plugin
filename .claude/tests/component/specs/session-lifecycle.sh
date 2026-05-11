#!/bin/bash
# session-lifecycle.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers session-start.sh and
# session-end.sh. Per the docs, SessionStart emits hookSpecificOutput with
# event=SessionStart + additionalContext; SessionEnd emits `{}`.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
SS="$FIXTURE/.claude/scripts/session-start.sh"
SE="$FIXTURE/.claude/scripts/session-end.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# 1. session-start emits SessionStart envelope with additionalContext.
OUT=$(printf '%s' '{}' | bash "$SS" 2>/dev/null)
assert_valid_envelope "session-start: envelope valid" "$OUT"
assert_hook_event "session-start: event=SessionStart" "$OUT" "SessionStart"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "session-start: context contains workflow_engine" \
    '<workflow_engine source=' "$CTX"

# 2. session-start clears stale QA tracking files (B10 / B11).
# Plant a stale changed-files.txt + edit-count, then run session-start
# and confirm they're gone.
printf '/old/path.ts\n' > "$TRACK/changed-files.txt"
printf '5\n' > "$TRACK/edit-count"
printf '%s' '{}' | bash "$SS" >/dev/null 2>&1
assert_eq "session-start: stale changed-files.txt cleared" "1" \
    "$([ -s "$TRACK/changed-files.txt" ] && echo 0 || echo 1)"
assert_eq "session-start: stale edit-count cleared" "1" \
    "$([ -s "$TRACK/edit-count" ] && echo 0 || echo 1)"

# 3. session-start touches .session-start marker so post-edit etc. can
# see a fresh session.
assert_eq "session-start: .session-start marker created" "0" \
    "$([ -f "$FIXTURE/.claude/.session-start" ] && echo 0 || echo 1)"

# 4. Surfaced bd warnings: plant a stale sync-errors.log, confirm next
# SessionStart surfaces a warning AND truncates the log.
SYNC_LOG="$TRACK/sync-errors.log"
printf '2026-01-01T00:00:00Z\t[verify-before-stop]\tbd sync failed: test scenario\n' > "$SYNC_LOG"
OUT=$(printf '%s' '{}' | bash "$SS" 2>/dev/null)
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "session-start: surfaces prior bd-sync error" \
    "bd sync failed" "$CTX"
# Log truncated (size 0).
LOG_SIZE=$(wc -c < "$SYNC_LOG" | tr -d ' ')
assert_eq "session-start: sync log truncated after surfacing" "0" "$LOG_SIZE"

# 5. session-end emits `{}` per the hooks reference (no decision control).
OUT=$(printf '%s' '{"reason":"clear"}' | bash "$SE" 2>/dev/null)
assert_empty_envelope "session-end: returns {}" "$OUT"

# 6. session-end is idempotent — running twice doesn't fail.
RC=0
printf '%s' '{"reason":"clear"}' | bash "$SE" >/dev/null 2>&1 || RC=$?
assert_eq "session-end: idempotent rc=0" "0" "$RC"

# 7. session-end with bd-unavailable PATH still emits {} (graceful degrade).
# Strip the fixture's bin/ from PATH (which has the bd wrapper) for one call.
# We can't easily strip bd from PATH without breaking the parent shell, so
# this is asserted by a sub-bash with cleaned PATH.
OUT=$(PATH=/usr/bin:/bin bash -c "echo '{\"reason\":\"clear\"}' | bash '$SE'" 2>/dev/null)
assert_empty_envelope "session-end: bd-unavailable graceful" "$OUT"

[ "$FAIL" -eq 0 ]

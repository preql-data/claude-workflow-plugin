#!/bin/bash
# PostToolUse Hook: Tracks file changes for QA review, updates Beads.
#
# Phase 1 changes (claude-workflow-plugin-y4a.5):
#   - B5: emit a valid hookSpecificOutput JSON envelope (not raw markdown).
#   - B6: replace narrow extension allowlist with a denylist over build/lock
#         artifacts; everything else (.md/.json/.yaml/.toml/.tf/.proto/etc.)
#         is tracked.
#   - B9: race-safe dedup using flock when available; otherwise append and
#         rely on `sort -u` at read time. No user prompts.
#   - B10: edit-count is reset by session-start.sh so the every-10-edits
#         cadence resets per session.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || echo "")

# sync-errors.log: surface silently-failing best-effort calls so SessionStart
# can present them. Mirrors the pattern in verify-before-stop.sh / B11.
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"
log_sync_error() {
    local msg="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    printf '%s\t[post-edit]\t%s\n' "$ts" "$msg" >> "$SYNC_ERRORS_LOG" 2>/dev/null || true
}

# F3 (Phase 4 fix pass): single source of truth for active task id. The
# previous implementation fell back to `bd list --status in_progress |
# jq .[0].id` when the helper file was empty; that defeats F3 entirely
# under parallel epics. New contract: empty helper file means "no active
# task" — we skip the per-10-edits comment rather than guessing.
get_current_task() {
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        tid=$(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null | tr -d '\r\n[:space:]' || echo "")
    fi
    printf '%s' "$tid"
}

# Always emit a valid response (B5 / E9 standardisation). The PostToolUse
# hooks reference allows either `{}` (no-op) or
# `{"hookSpecificOutput":{"hookEventName":"PostToolUse",
# "additionalContext":"..."}}` (context injection). We use `{}` because
# this hook only tracks state — the Stop hook surfaces the review context.
emit_empty() { echo '{}'; }

if [ -z "$FILE_PATH" ]; then
    emit_empty; exit 0
fi

# B6: denylist (regex against the path). Anything not matched is tracked.
DENYLIST_REGEX='(^|/)(node_modules|dist|build|coverage|\.git|\.next|\.nuxt|target|__pycache__)/|\.(lock|lockb|map|pyc)$|\.min\.(js|css)$|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb|Cargo\.lock|poetry\.lock|go\.sum)$'
if [[ "$FILE_PATH" =~ $DENYLIST_REGEX ]]; then
    emit_empty; exit 0
fi

mkdir -p "$QA_TRACKING_DIR"
TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"
LOCK_FILE="$QA_TRACKING_DIR/.changed-files.lock"

# B9: race-safe append. Two strategies:
#   - flock available: take an exclusive lock around dedup-then-append.
#   - no flock: append unconditionally; readers always `sort -u` (callers
#     already do, see verify-before-stop.sh and the unique count below).
append_dedup_locked() {
    # Run under flock. Stdin/stdout already inherited.
    if [ ! -f "$TRACKING_FILE" ] || ! grep -qxF "$FILE_PATH" "$TRACKING_FILE" 2>/dev/null; then
        printf '%s\n' "$FILE_PATH" >> "$TRACKING_FILE"
    fi
}

if command -v flock >/dev/null 2>&1; then
    # flock takes a file descriptor; open the lock fd and run under it.
    (
        flock -x 9
        append_dedup_locked
    ) 9>"$LOCK_FILE"
else
    # No flock available (e.g., macOS without coreutils). Append blindly;
    # readers normalize via `sort -u`. This trades a small amount of disk
    # for guaranteed safety with no prompts.
    printf '%s\n' "$FILE_PATH" >> "$TRACKING_FILE"
fi

# Cap tracking file size at 500 unique lines (also race-tolerant: we only
# trim if the current file is over 2x that threshold so concurrent appenders
# don't lose data).
if [ -f "$TRACKING_FILE" ]; then
    LINE_COUNT=$(wc -l < "$TRACKING_FILE" 2>/dev/null | tr -d ' ' || echo "0")
    if [ "${LINE_COUNT:-0}" -gt 1000 ]; then
        if command -v flock >/dev/null 2>&1; then
            (
                flock -x 9
                sort -u "$TRACKING_FILE" | tail -500 > "$TRACKING_FILE.tmp" && mv "$TRACKING_FILE.tmp" "$TRACKING_FILE"
            ) 9>"$LOCK_FILE"
        else
            sort -u "$TRACKING_FILE" | tail -500 > "$TRACKING_FILE.tmp" && mv "$TRACKING_FILE.tmp" "$TRACKING_FILE"
        fi
    fi
fi

# Update Beads task with progress (batched to avoid spam).
if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
    EDIT_COUNT_FILE="$QA_TRACKING_DIR/edit-count"
    EDIT_COUNT=$(cat "$EDIT_COUNT_FILE" 2>/dev/null || echo "0")
    EDIT_COUNT=$((EDIT_COUNT + 1))
    echo "$EDIT_COUNT" > "$EDIT_COUNT_FILE"

    if [ $((EDIT_COUNT % 10)) -eq 0 ]; then
        CURRENT_TASK=$(get_current_task)
        if [ -n "$CURRENT_TASK" ]; then
            UNIQUE_COUNT=$(sort -u "$TRACKING_FILE" 2>/dev/null | wc -l | tr -d ' ')
            (bd comments add "$CURRENT_TASK" "Progress: $UNIQUE_COUNT files edited" >/dev/null 2>&1 \
                || bd comment add "$CURRENT_TASK" "Progress: $UNIQUE_COUNT files edited" >/dev/null 2>&1) \
                || log_sync_error "bd comments add failed for $CURRENT_TASK (progress comment, $UNIQUE_COUNT files)"
        fi
        # If CURRENT_TASK is empty here we don't log on every edit — only
        # the Stop hook surfaces "no active task" since edit-volume noise
        # would dominate sync-errors.log.
    fi
fi

# Per principle (Phase 1 cosmetic): the additionalContext is informational
# only. We choose the simplest valid response — `{}` — and let the Stop hook
# surface the full review context. (B5 alternative: keep an envelope but no
# user-facing markdown.)
emit_empty

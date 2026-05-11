#!/bin/bash
# Statusline (Phase 5 / E4 + I2).
#
# Reads:
#   - .claude/.qa-tracking/current-task     (single source of truth, F3)
#   - bd labels for that task               (qa: pending|approved|blocked|gate-entered|none)
#   - .claude/.qa-tracking/changed-files.txt (file count)
#
# Output (single line):
#   [<task-id>] qa: <state> • N files changed
# When no current-task:
#   (no active task) — N files changed
# When bd unavailable:
#   (bd unavailable) — N files changed
#
# Wired via .claude/settings.json `statusLine` field. Per the Claude Code
# docs (https://docs.claude.com/en/docs/claude-code/statusline), the script
# receives a JSON envelope on stdin describing the session; we only need
# project-local state, so we drain stdin and ignore the body. We still cat
# stdin to keep the data flowing in case future versions enforce a read.

set -e

# Drain stdin (don't error if there's nothing).
cat >/dev/null 2>&1 || true

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"

# ---------------------------------------------------------------------------
# Helpers

# F3 single source of truth read. Mirrors the helper in intent-router.sh and
# verify-before-stop.sh: prefer the helper script, fall back to direct read,
# never fall back to `bd list --status in_progress` (would resurrect the F3
# anti-pattern the gate redesign was meant to eliminate).
get_current_task() {
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        tid=$(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null \
            | tr -d '\r\n[:space:]' || echo "")
    fi
    printf '%s' "$tid"
}

# Count unique tracked file changes (sort -u handles the no-flock B9 path).
count_changed_files() {
    if [ -f "$TRACKING_FILE" ]; then
        sort -u "$TRACKING_FILE" 2>/dev/null | grep -c . || echo "0"
    else
        echo "0"
    fi
}

# Read a task's QA state from its labels. Returns one of:
#   approved | blocked | gate-entered | pending | none
# Precedence (most decisive first): approved > blocked > gate-entered > pending.
qa_state_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf 'none'; return; }
    if ! command -v bd >/dev/null 2>&1; then
        printf 'bd-unavailable'
        return
    fi
    if [ ! -d "$PROJECT_DIR/.beads" ]; then
        printf 'no-beads'
        return
    fi
    # `bd show <id> --json` returns either an object or a 1-element array
    # depending on bd version; `// []` and the `.[0].labels else .labels`
    # branch handle both. (Phases 0-4 used the array form; we keep it.)
    local labels
    labels=$(bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null \
        || echo "")
    case ",$labels," in
        *,qa-approved,*)      printf 'approved' ;;
        *,qa-blocked,*)       printf 'blocked' ;;
        *,qa-gate-entered,*)  printf 'gate-entered' ;;
        *,qa-pending,*)       printf 'pending' ;;
        *)                    printf 'none' ;;
    esac
}

# ---------------------------------------------------------------------------
# Main

CURRENT_TASK=$(get_current_task)
FILE_COUNT=$(count_changed_files)
# Strip whitespace from `wc -l` output on macOS.
FILE_COUNT=$(printf '%s' "$FILE_COUNT" | tr -d '[:space:]')
[ -z "$FILE_COUNT" ] && FILE_COUNT=0

if [ -z "$CURRENT_TASK" ]; then
    # No active task — still report file count (useful when changes are
    # accumulating but no task has been claimed yet).
    printf '(no active task) — %s files changed\n' "$FILE_COUNT"
    exit 0
fi

QA_STATE=$(qa_state_for "$CURRENT_TASK")

case "$QA_STATE" in
    bd-unavailable)
        printf '(bd unavailable) — %s files changed\n' "$FILE_COUNT"
        ;;
    no-beads)
        printf '[%s] (.beads missing) — %s files changed\n' "$CURRENT_TASK" "$FILE_COUNT"
        ;;
    *)
        printf '[%s] qa: %s • %s files changed\n' "$CURRENT_TASK" "$QA_STATE" "$FILE_COUNT"
        ;;
esac

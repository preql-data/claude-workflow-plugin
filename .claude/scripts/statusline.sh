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
ORCH_AGENT_FILE="$PROJECT_DIR/.claude/agents/orchestrator.md"

# Hotfix vlp.1: read the active model pin from orchestrator.md frontmatter
# (no network). All seven agent pins are kept in lockstep by
# workflow-model-apply.sh, so reading one is sufficient. We surface this
# in the statusline so the operator can see at-a-glance which model is
# active for the current session — closes the principle-1 visibility gap
# called out in the hotfix plan.
read_model_pin() {
    [ -f "$ORCH_AGENT_FILE" ] || { printf ''; return; }
    local pin
    pin=$(grep -E '^model:' "$ORCH_AGENT_FILE" 2>/dev/null | head -1 | awk '{print $2}')
    printf '%s' "$pin"
}

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
    if [ ! -f "$TRACKING_FILE" ]; then
        echo "0"
        return
    fi
    local count
    # `sort -u` + `wc -l` is portable and always exits 0; trim macOS BSD `wc -l` leading spaces.
    count=$(sort -u "$TRACKING_FILE" 2>/dev/null | wc -l | tr -d '[:space:]')
    echo "${count:-0}"
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

# Spec Phase A: read a task's rubric state from its labels. Cheap-only —
# we share the labels string fetched by qa_state_for via the caller's
# RUBRIC_STATE_LABELS variable (see Main). No extra `bd show` call: the
# fetch is already paid for. Returns one of:
#   satisfied | pending | none
# Precedence: satisfied > pending > none. Matches qa-gate.sh status
# precedence (label semantics are the source of truth).
rubric_state_for_labels() {
    local labels="$1"
    case ",$labels," in
        *,rubric-satisfied,*) printf 'satisfied' ;;
        *,rubric-pending,*)   printf 'pending' ;;
        *)                    printf 'none' ;;
    esac
}

# Variant of qa_state_for that ALSO surfaces the labels string so the
# caller can derive rubric state from the same `bd show` response. Returns
# the QA state on stdout and writes the raw labels into the global var
# named in arg 2 (caller passes the variable name). We split the work
# this way to keep qa_state_for's existing signature stable for any
# external consumer and avoid a second `bd show` call.
# Variant of qa_state_for that prints BOTH the QA state AND the raw
# labels string on stdout, separated by a single tab. The caller splits
# the result with `cut -f1` / `cut -f2`. We use this shape instead of a
# pass-by-name variable because `qa_state_for_with_labels` is invoked via
# command substitution — the subshell would discard any eval-into-var
# write. The single `bd show` call is shared between the QA state read
# and the rubric state derivation, so this stays within the cheap-only
# budget (no extra round-trip).
#
# Output shape:
#   <qa-state>\t<labels-csv>
# where <qa-state> is one of {approved, blocked, gate-entered, pending,
# none, bd-unavailable, no-beads} and <labels-csv> is the comma-joined
# label list (or empty when the read failed).
qa_state_for_with_labels() {
    local tid="$1"
    if [ -z "$tid" ]; then
        printf 'none\t'
        return
    fi
    if ! command -v bd >/dev/null 2>&1; then
        printf 'bd-unavailable\t'
        return
    fi
    if [ ! -d "$PROJECT_DIR/.beads" ]; then
        printf 'no-beads\t'
        return
    fi
    local labels
    labels=$(bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null \
        || echo "")
    local state
    case ",$labels," in
        *,qa-approved,*)      state="approved" ;;
        *,qa-blocked,*)       state="blocked" ;;
        *,qa-gate-entered,*)  state="gate-entered" ;;
        *,qa-pending,*)       state="pending" ;;
        *)                    state="none" ;;
    esac
    printf '%s\t%s' "$state" "$labels"
}

# ---------------------------------------------------------------------------
# Main

CURRENT_TASK=$(get_current_task)
FILE_COUNT=$(count_changed_files)
# Strip whitespace from `wc -l` output on macOS.
FILE_COUNT=$(printf '%s' "$FILE_COUNT" | tr -d '[:space:]')
[ -z "$FILE_COUNT" ] && FILE_COUNT=0

# Hotfix vlp.1: read the model pin once; append " • model: <id>" to every
# branch below so visibility is consistent across task-active /
# no-active-task / bd-unavailable states. Empty pin -> "(no model pin)".
MODEL_PIN=$(read_model_pin)
MODEL_SUFFIX=" • model: ${MODEL_PIN:-(no model pin)}"

if [ -z "$CURRENT_TASK" ]; then
    # No active task — still report file count (useful when changes are
    # accumulating but no task has been claimed yet).
    printf '(no active task) — %s files changed%s\n' "$FILE_COUNT" "$MODEL_SUFFIX"
    exit 0
fi

# Spec Phase A: use the labels-surfacing helper so we can derive the
# rubric state from the SAME `bd show` response — no extra round-trip.
# qa_state_for_with_labels prints "state\tlabels"; split on the tab.
QA_OUT=$(qa_state_for_with_labels "$CURRENT_TASK")
QA_STATE=$(printf '%s' "$QA_OUT" | cut -f1)
RUBRIC_STATE_LABELS=$(printf '%s' "$QA_OUT" | cut -f2-)
RUBRIC_STATE=$(rubric_state_for_labels "$RUBRIC_STATE_LABELS")

case "$QA_STATE" in
    bd-unavailable)
        printf '(bd unavailable) — %s files changed%s\n' "$FILE_COUNT" "$MODEL_SUFFIX"
        ;;
    no-beads)
        printf '[%s] (.beads missing) — %s files changed%s\n' "$CURRENT_TASK" "$FILE_COUNT" "$MODEL_SUFFIX"
        ;;
    *)
        # Surface rubric state only when present (pending/satisfied). The
        # 'none' state means this task pre-dates Phase A or the gate is
        # not yet entered — suppressing it keeps the line short for the
        # common case (intent-router fires before qa-gate enter).
        if [ "$RUBRIC_STATE" = "satisfied" ] || [ "$RUBRIC_STATE" = "pending" ]; then
            printf '[%s] qa: %s • rubric: %s • %s files changed%s\n' \
                "$CURRENT_TASK" "$QA_STATE" "$RUBRIC_STATE" "$FILE_COUNT" "$MODEL_SUFFIX"
        else
            printf '[%s] qa: %s • %s files changed%s\n' \
                "$CURRENT_TASK" "$QA_STATE" "$FILE_COUNT" "$MODEL_SUFFIX"
        fi
        ;;
esac

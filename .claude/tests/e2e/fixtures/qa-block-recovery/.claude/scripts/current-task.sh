#!/bin/bash
# current-task.sh - Single source of truth for the active Beads task ID.
#
# Phase 4 (claude-workflow-plugin-y4a.10) - F3.
# Phase 6b (claude-workflow-plugin-y4a.13) - I8 multi-repo: record the repo
# fingerprint alongside the task id so verify-before-stop can warn when the
# active task targets a different repo than the cwd's HEAD.
#
# The active task ID is persisted at $QA_TRACKING_DIR/current-task. Hooks
# (verify-before-stop, post-edit, intent-router) read this file first; they
# fall back to `bd list --status in_progress` ONLY when the file is empty,
# preserving backward-compatibility for sessions that pre-date this helper.
#
# Storage layout (Phase 6b)
# -------------------------
# Two files under $QA_TRACKING_DIR:
#   current-task           plain task id (kept for back-compat with old
#                          consumers that read via `head -1 current-task`)
#   current-task.repo      repo fingerprint that owned the task at `set` time.
#                          Today the fingerprint is the absolute path of
#                          `git rev-parse --show-toplevel`; later we'll swap
#                          to the bd-issued repo fingerprint when one exists.
#
# Subcommands:
#   set <task-id>            Persist <task-id> + the current repo fingerprint.
#   get                      Print the persisted task id; exits 0 with empty
#                            stdout if the file is missing/empty.
#   get-repo                 Print the persisted repo fingerprint; empty if
#                            unset (back-compat: not all current-task files
#                            were written with a fingerprint).
#   get-json                 Print {"task":"...","repo":"..."} JSON. Convenient
#                            for hook scripts that want both atomically.
#   clear                    Remove BOTH the task and repo file. Idempotent.
#
# Output: plain stdout for non-JSON subs. No JSON envelope (these are
# internal helpers - not directly hooked into Claude's hook lifecycle).
#
# Exit codes:
#   0 success (including "empty" for `get`)
#   1 usage / argument error

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_FILE="$QA_TRACKING_DIR/current-task"
CURRENT_TASK_REPO_FILE="$QA_TRACKING_DIR/current-task.repo"

usage() {
    cat >&2 <<'USAGE'
Usage: current-task.sh <set <id> | get | get-repo | get-json | clear>
  set <id>    Persist the active task id + current repo fingerprint.
  get         Print the persisted task id (empty stdout if unset).
  get-repo    Print the persisted repo fingerprint (empty stdout if unset).
  get-json    Print {"task":"...","repo":"..."} JSON.
  clear       Remove the persisted task id (idempotent).
USAGE
}

# Compute the repo fingerprint for the cwd. Today the fingerprint is the
# absolute path of `git rev-parse --show-toplevel`. We pick the *cwd* (not
# CLAUDE_PROJECT_DIR) deliberately: when the user runs `bd update ...` from
# a worktree of repo B while repo A is the active project, we record where
# bd actually wrote the task -- that matches the verify-before-stop check.
#
# Fallbacks:
#   1. git toplevel of cwd
#   2. CLAUDE_PROJECT_DIR
#   3. plain pwd
# Any of these is stable enough for I8's "are we in the same repo as the
# task?" comparison; the upstream check uses string equality only.
compute_repo_fingerprint() {
    local fp=""
    if command -v git >/dev/null 2>&1; then
        fp=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    fi
    if [ -z "$fp" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        fp="$CLAUDE_PROJECT_DIR"
    fi
    if [ -z "$fp" ]; then
        fp=$(pwd 2>/dev/null || echo "")
    fi
    printf '%s' "$fp"
}

cmd_set() {
    local tid="$1"
    if [ -z "$tid" ]; then
        usage
        exit 1
    fi
    # Reject ids with whitespace - bd ids never contain whitespace.
    if [[ "$tid" =~ [[:space:]] ]]; then
        echo "current-task.sh: task id must not contain whitespace: '$tid'" >&2
        exit 1
    fi
    mkdir -p "$QA_TRACKING_DIR"
    printf '%s\n' "$tid" > "$CURRENT_TASK_FILE"

    # I8: record the repo fingerprint at the same moment. We don't error if
    # this fails (e.g., not in a git repo) -- the gate degrades gracefully
    # to single-repo behaviour when the file is missing.
    local fp
    fp=$(compute_repo_fingerprint)
    if [ -n "$fp" ]; then
        printf '%s\n' "$fp" > "$CURRENT_TASK_REPO_FILE" 2>/dev/null || true
    else
        # Make sure stale fingerprints from a previous task don't linger.
        rm -f "$CURRENT_TASK_REPO_FILE" 2>/dev/null || true
    fi
}

cmd_get() {
    if [ ! -s "$CURRENT_TASK_FILE" ]; then
        # Empty stdout, exit 0 - lets callers do `id=$(... get)` and check
        # `[ -n "$id" ]` without special-casing missing files.
        return 0
    fi
    # Strip trailing newline + leading/trailing whitespace defensively.
    local tid
    tid=$(head -1 "$CURRENT_TASK_FILE" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$tid" ] && printf '%s\n' "$tid"
}

cmd_get_repo() {
    if [ ! -s "$CURRENT_TASK_REPO_FILE" ]; then
        return 0
    fi
    local fp
    fp=$(head -1 "$CURRENT_TASK_REPO_FILE" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$fp" ] && printf '%s\n' "$fp"
}

cmd_get_json() {
    local tid repo
    tid=$(cmd_get || echo "")
    repo=$(cmd_get_repo || echo "")
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg t "$tid" --arg r "$repo" '{task:$t, repo:$r}'
    else
        # Fallback hand-rolled JSON. Both fields are simple strings without
        # quotes (task ids are alpha-num-dot-dash; fingerprints are paths,
        # which we escape conservatively).
        local esc_repo
        esc_repo=$(printf '%s' "$repo" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        printf '{"task":"%s","repo":"%s"}\n' "$tid" "$esc_repo"
    fi
}

cmd_clear() {
    rm -f "$CURRENT_TASK_FILE" 2>/dev/null || true
    rm -f "$CURRENT_TASK_REPO_FILE" 2>/dev/null || true
}

SUB="${1:-}"
shift || true

case "$SUB" in
    set)        cmd_set "$@" ;;
    get)        cmd_get "$@" ;;
    get-repo)   cmd_get_repo "$@" ;;
    get-json)   cmd_get_json "$@" ;;
    clear)      cmd_clear "$@" ;;
    ""|-h|--help|help)
        usage
        exit 1
        ;;
    *)
        echo "current-task.sh: unknown subcommand: $SUB" >&2
        usage
        exit 1
        ;;
esac

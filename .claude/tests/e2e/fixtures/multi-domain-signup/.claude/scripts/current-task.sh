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
#                            stdout if the file is missing/empty. Exits 3 with
#                            empty stdout + a stderr diagnostic if the file
#                            EXISTS but could not be read (i8cx wave 2) --
#                            distinct from "no task set" for any caller that
#                            checks rc rather than just the (empty either way)
#                            stdout.
#   get-repo                 Print the persisted repo fingerprint; empty if
#                            unset (back-compat: not all current-task files
#                            were written with a fingerprint). Same rc-3
#                            read-failure contract as `get`.
#   get-json                 Print {"task":"...","repo":"..."} JSON. Convenient
#                            for hook scripts that want both atomically. NOTE:
#                            does not yet propagate the rc-3 distinction (it
#                            has no production caller today; see the i8cx
#                            wave-2 devops report for the gap if one is added).
#   clear                    Remove BOTH the task and repo file. Idempotent.
#
# Output: plain stdout for non-JSON subs. No JSON envelope (these are
# internal helpers - not directly hooked into Claude's hook lifecycle).
#
# Exit codes:
#   0 success (including "empty" for `get`/`get-repo`, whether because the
#     file is missing/empty OR because it is readable but blank)
#   1 usage / argument error
#   3 `get`/`get-repo` only: the file exists (non-zero size) but could not be
#     read (i8cx wave 2) -- ALWAYS distinguish this from 0 by rc, never by
#     stdout content, which is empty in both cases

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
    # i8cx wave 2: `[ -s ]` above is a STAT (exists + nonzero size), not a
    # readability test -- it can pass on a file whose CONTENT cannot actually
    # be read (permission stripped after creation, an ACL, a mid-read I/O
    # error; stat() needs no read permission on the file itself). The old body
    # piped `head -1 FILE | tr -d '\r' | sed ...` straight through: sed is
    # always last and succeeds trivially on the empty stdin a failed head
    # leaves behind, so a genuine read failure and a merely-blank file both
    # ended in the same tid="". The trailing `[ -n "$tid" ] && printf ...`
    # idiom then returned 1 for EITHER (measured: a chmod-000 non-empty file
    # and a whitespace-only readable file both exited 1, pre-fix) -- so a read
    # failure was not even reliably distinguishable from a healthy blank read
    # by rc, let alone by the stdout every `... get 2>/dev/null || echo ""`
    # caller actually looks at (identical empty string, either way). This
    # helper owns the task slot the whole gate keys off (verify-before-stop.sh
    # get_current_task/get_recorded_repo, qa-gate.sh set/clear, the Stop
    # hook's F1 fast path all read it through here) -- a read failure has to
    # be a DISTINCT, documented state, not an accident of which command in a
    # pipe happens to run last.
    #
    # head is captured on its own statement, out of band, before the strip
    # pipe ever runs. The strip pipe only ever sees an in-memory string
    # (`printf '%s' "$raw" | tr ... | sed ...`), so it cannot mask anything
    # further -- same reasoning the printf-producer idiom uses throughout this
    # codebase (audit bucket 1: a producer that cannot fail makes the LAST
    # stage's rc the pipeline's rc, safely). rc 3 mirrors impact-report.sh's
    # own convention for "the tracked file exists but could not be read"
    # (`grep -n 'exit 3' impact-report.sh`) -- a new, dedicated, documented
    # code, distinct from the 1 a merely-blank file produced by accident
    # pre-fix. A blank-but-READABLE file now correctly returns 0 (matching
    # this function's own usage() contract: "exits 0 with empty stdout if the
    # file is missing/empty"), not 1 -- eliminating a false "read FAILED" log
    # line in verify-before-stop.sh's get_current_task for a file that was
    # actually read fine.
    # `|| rc=$?` is load-bearing under `set -e` (line 42 of this file): a bare
    # `raw=$(head ...)` on its own line trips errexit AT THE ASSIGNMENT the
    # instant head fails, so a two-statement `raw=$(...); rc=$?` never reaches
    # its own second line -- the whole script aborts one line early instead
    # (measured while building this fix: the trace stopped dead after `raw=`,
    # rc 1 straight from head, my rc=3 branch never ran). Combining the
    # assignment and the capture into ONE `||` statement is what keeps this
    # exempt from errexit (bash: a failure "in a && or || list" does not abort
    # unless it is the command AFTER the final operator, and `rc=$?` -- which
    # always succeeds -- is what follows here).
    local raw tid rc=0
    raw=$(head -1 "$CURRENT_TASK_FILE" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "current-task.sh: failed to read $CURRENT_TASK_FILE (head exit $rc)" >&2
        return 3
    fi
    tid=$(printf '%s' "$raw" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$tid" ]; then
        printf '%s\n' "$tid"
    fi
    return 0
}

cmd_get_repo() {
    if [ ! -s "$CURRENT_TASK_REPO_FILE" ]; then
        return 0
    fi
    # i8cx wave 2: same fix as cmd_get above, mirrored for the repo-fingerprint
    # file -- see that function's comment for the full defect writeup. This
    # read feeds get_recorded_repo's I8 cross-repo guard (already hardened
    # against a read failure in wave 1 via rc 2 on ANY nonzero here); rc 3
    # is what makes that guard's `[ "$rr" -eq 0 ] || return 2` branch fire
    # instead of silently disarming on an unreadable marker.
    # See cmd_get's comment above: `|| rc=$?` (one statement) is required
    # under this file's `set -e`, not `raw=$(...); rc=$?` (two statements).
    local raw fp rc=0
    raw=$(head -1 "$CURRENT_TASK_REPO_FILE" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "current-task.sh: failed to read $CURRENT_TASK_REPO_FILE (head exit $rc)" >&2
        return 3
    fi
    fp=$(printf '%s' "$raw" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$fp" ]; then
        printf '%s\n' "$fp"
    fi
    return 0
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

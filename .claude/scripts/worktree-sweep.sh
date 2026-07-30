#!/bin/bash
# worktree-sweep.sh — v4.1 C1b (claude-workflow-plugin-8xv).
#
# Platform-created subagent worktrees live at .claude/worktrees/<name>. Per
# docs/AGENTS.md, ones with NO changes are auto-removed when the subagent
# finishes — ones WITH changes survive, and until this script nothing removed
# them. They accumulate silently.
#
# DRY-RUN IS THE DEFAULT. --apply is the only thing that removes, and removal
# is `git worktree remove` + `git worktree prune`: there is deliberately NO
# `rm -rf` anywhere in this file (worktree-sweep.test.sh asserts that
# structurally). Every gate below must PASS for a worktree to be removable, and
# any error, unreadable path or ambiguity means NOT a candidate:
#
#   1. containment  the RESOLVED path is physically inside the resolved
#                   .claude/worktrees/ root. A string-prefix test is NOT a
#                   containment guard (LESSONS.md): the sibling checkout
#                   `<repo>-impactfix` string-prefixes `<repo>`, and a symlink
#                   under .claude/worktrees/ can point anywhere. Both sides are
#                   `cd … && pwd -P`-resolved and the boundary char is checked.
#   2. same repo    identity via --git-common-dir, never a --show-toplevel
#                   string compare (mirrors verify-before-stop.sh).
#   3. clean        `git status --porcelain` empty (untracked included).
#   4. pushed/merged  rev-list @{upstream}..HEAD == 0, else merge-base
#                   --is-ancestor <branch> <default>. DECIDED LOCALLY: this
#                   never fetches, because SessionEnd runs it and SessionEnd
#                   must not do network I/O.
#   5. age          worktree dir mtime older than --age-days.
#   6. task closed  the id comes from EVIDENCE — the worktree's own
#                   .qa-tracking/current-task, else a task-shaped token in the
#                   branch that bd actually knows. Worktree NAMING is not on the
#                   safety path: `wt-<task>` is prose in docs/HOOKS.md, not a
#                   verified platform contract.
#
# Gate 6's primary evidence only survives gate 3 where `.claude/.qa-tracking/`
# is gitignored (it is here and in install.sh's generated .gitignore); elsewhere
# the branch fallback carries it, or nothing does and nothing is removable.
# Failing toward KEEP is the whole design.
#
# Exit: 0 report produced · 1 a removal failed under --apply · 2 bad invocation.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Same bound and reason as verify-before-stop.sh's WTRES_MAX_CANDIDATES: a
# hook-invoked scan over an unbounded worktree list is a latency hazard.
SWEEP_MAX_CANDIDATES=16

ARG_APPLY=0
ARG_REPORT_ONLY=0
ARG_JSON=0
ARG_AGE_DAYS=7

usage() {
    cat <<'USAGE'
worktree-sweep.sh — report (and optionally remove) finished subagent worktrees
under .claude/worktrees/.

Usage:
  worktree-sweep.sh [--apply] [--age-days N] [--report-only] [--json]
                    [--max-candidates N] [--help]

  --apply             actually remove the removable worktrees. WITHOUT THIS
                      FLAG NOTHING IS REMOVED. Never passed from a hook.
  --age-days N        only worktrees whose directory mtime is older than N
                      days are removable (default 7; 0 still means "not today").
  --report-only       force dry-run. Wins over --apply if both are given.
  --json              emit the report as one JSON object instead of text.
  --max-candidates N  cap how many worktrees are examined (default 16).
  --help              this text.

Removal requires ALL of: containment in .claude/worktrees/, same repository,
clean tree, pushed-or-merged, old enough, and a Beads task that bd reports
closed. Anything unreadable or ambiguous is kept. Removal is
'git worktree remove' + 'git worktree prune'; nothing is deleted by hand.
USAGE
}

# require_uint <argc-remaining> <flag> <value> <min> — validates a flag operand
# and exits 2 on anything else. The argc check lives here because `shift 2` with
# one arg left is a no-op returning non-zero on bash 3.2: an infinite parse loop.
require_uint() {
    local ok=1
    [ "$1" -ge 2 ] || ok=0
    case "${3:-}" in ''|*[!0-9]*) ok=0 ;; esac
    [ "$ok" = "0" ] || [ "${3:-0}" -ge "$4" ] || ok=0
    if [ "$ok" = "0" ]; then
        printf 'worktree-sweep.sh: %s needs an integer >= %s, got: %s\n' "$2" "$4" "${3:-<nothing>}" >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply)       ARG_APPLY=1; shift ;;
        --report-only) ARG_REPORT_ONLY=1; shift ;;
        --json)        ARG_JSON=1; shift ;;
        --age-days)
            require_uint "$#" --age-days "${2:-}" 0
            ARG_AGE_DAYS="$2"; shift 2 ;;
        --max-candidates)
            require_uint "$#" --max-candidates "${2:-}" 1
            SWEEP_MAX_CANDIDATES="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *)
            printf 'worktree-sweep.sh: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2 ;;
    esac
done

# --json is encoded with jq. Without it `finish` would print NOTHING and exit 0,
# which reads exactly like "no worktrees" — refuse loudly. Text mode needs no
# encoder and still works on a jq-less host.
if [ "$ARG_JSON" = "1" ] && ! command -v jq >/dev/null 2>&1; then
    printf 'worktree-sweep.sh: --json needs jq on PATH; re-run without --json\n' >&2
    exit 2
fi

# Fail-safe precedence: asking for a report gets a report, --apply or not.
[ "$ARG_REPORT_ONLY" = "1" ] && ARG_APPLY=0
MODE="dry-run"
[ "$ARG_APPLY" = "1" ] && MODE="apply"

# --- Predicates -------------------------------------------------------------

canon() {
    # canon <path> -> physically resolved path; non-zero + no output on failure.
    [ -n "${1:-}" ] || return 1
    ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

contained_in() {
    # contained_in <root-canon> <path-canon> — STRICTLY inside <root>. Both must
    # already be pwd -P output; the boundary-character check is what stops
    # `<root>-impactfix` from reading as contained.
    local root="${1:-}" p="${2:-}" n
    [ -n "$root" ] && [ -n "$p" ] || return 1
    [ "$root" != "/" ] || return 1
    [ "$p" != "$root" ] || return 1
    n=${#root}
    [ "${p:0:$n}" = "$root" ] || return 1
    [ "${p:$n:1}" = "/" ] || return 1
    return 0
}

repo_identity() {
    # Mirrors verify-before-stop.sh's repo_identity: the resolved common dir is
    # shared by every linked worktree of a repo, so it IS the repo's identity.
    local dir="${1:-}" raw candidate resolved
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    raw=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0
    case "$raw" in
        /*) candidate="$raw" ;;
        *)  candidate="$dir/$raw" ;;
    esac
    resolved=$(canon "$candidate") || resolved=""
    printf '%s' "$resolved"
}

default_ref() {
    # The merge target, resolved LOCALLY. No fetch, ever — SessionEnd runs this.
    local d c
    d=$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || d=""
    if [ -n "$d" ] && git -C "$PROJECT_DIR" rev-parse --verify --quiet "$d" >/dev/null 2>&1; then
        printf '%s' "$d"; return 0
    fi
    for c in origin/main origin/master main master; do
        if git -C "$PROJECT_DIR" rev-parse --verify --quiet "$c" >/dev/null 2>&1; then
            printf '%s' "$c"; return 0
        fi
    done
    printf ''
}

# Beads ids are <prefix>(-<segment>)+ with an optional .N child suffix. A token
# that does not match is never looked up; one that matches but that bd does not
# know resolves to NO id, which is not a candidate.
SWEEP_TASK_SHAPE='^[A-Za-z][A-Za-z0-9]*(-[A-Za-z0-9]+)+(\.[0-9]+)?$'

task_status() {
    # task_status <id> -> the bd status, or empty when bd cannot answer.
    local id="${1:-}" out st
    [ -n "$id" ] || return 0
    command -v bd >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    out=$(cd "$PROJECT_DIR" 2>/dev/null && bd show "$id" --json 2>/dev/null) || out=""
    [ -n "$out" ] || return 0
    # Capture-then-echo, never `jq … || printf ''`: a tool that fails AND writes
    # to stdout would otherwise concatenate into the answer (LESSONS.md).
    st=$(printf '%s' "$out" | jq -r '(if type=="array" then .[0].status else .status end) // empty' 2>/dev/null) || st=""
    printf '%s' "$st"
}

resolve_task() {
    # Sets SWEEP_TASK_ID / SWEEP_TASK_STATUS from EVIDENCE. Called directly (not
    # in a subshell) so the globals reach the caller.
    local w="${1:-}" br="${2:-}" f seg n=0
    SWEEP_TASK_ID=""; SWEEP_TASK_STATUS=""
    f="$w/.claude/.qa-tracking/current-task"
    if [ -f "$f" ]; then
        seg=$(head -1 "$f" 2>/dev/null | tr -d '[:space:]') || seg=""
        if printf '%s' "$seg" | grep -qE "$SWEEP_TASK_SHAPE"; then
            SWEEP_TASK_ID="$seg"
            SWEEP_TASK_STATUS=$(task_status "$seg")
            return 0
        fi
    fi
    [ -n "$br" ] || return 0
    local IFS='/'
    # shellcheck disable=SC2086  # deliberate split of the branch on '/'
    for seg in $br; do
        n=$((n + 1))
        [ "$n" -le 4 ] || break
        printf '%s' "$seg" | grep -qE "$SWEEP_TASK_SHAPE" || continue
        SWEEP_TASK_STATUS=$(task_status "$seg")
        if [ -n "$SWEEP_TASK_STATUS" ]; then SWEEP_TASK_ID="$seg"; return 0; fi
    done
    SWEEP_TASK_STATUS=""
    return 0
}

classify() {
    # classify <raw-path> — sets SWEEP_CANON / SWEEP_BRANCH / SWEEP_TASK_ID and
    # SWEEP_REASON to the FIRST failing gate. Returns 0 only when removable.
    local raw="${1:-}" st br up ahead def pushed=0
    SWEEP_CANON=""; SWEEP_BRANCH=""; SWEEP_TASK_ID=""; SWEEP_TASK_STATUS=""; SWEEP_REASON=""

    SWEEP_CANON=$(canon "$raw") || SWEEP_CANON=""
    [ -n "$SWEEP_CANON" ] || { SWEEP_REASON="unreadable-path"; return 1; }
    contained_in "$SWEEP_ROOT" "$SWEEP_CANON" || { SWEEP_REASON="not-contained"; return 1; }

    [ "$(repo_identity "$SWEEP_CANON")" = "$CURRENT_ID" ] || { SWEEP_REASON="foreign-repo"; return 1; }

    st=$(git -C "$SWEEP_CANON" status --porcelain 2>/dev/null) || { SWEEP_REASON="status-failed"; return 1; }
    [ -z "$st" ] || { SWEEP_REASON="dirty"; return 1; }

    br=$(git -C "$SWEEP_CANON" rev-parse --abbrev-ref HEAD 2>/dev/null) || br=""
    { [ -n "$br" ] && [ "$br" != "HEAD" ]; } || { SWEEP_REASON="detached-head"; return 1; }
    SWEEP_BRANCH="$br"
    up=$(git -C "$SWEEP_CANON" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || up=""
    if [ -n "$up" ]; then
        ahead=$(git -C "$SWEEP_CANON" rev-list --count '@{upstream}..HEAD' 2>/dev/null) || ahead=""
        [ "$ahead" = "0" ] && pushed=1
    fi
    if [ "$pushed" = "0" ]; then
        def=$(default_ref)
        [ -n "$def" ] || { SWEEP_REASON="unpushed-no-default-branch"; return 1; }
        git -C "$SWEEP_CANON" merge-base --is-ancestor "$br" "$def" >/dev/null 2>&1 \
            || { SWEEP_REASON="unpushed-and-unmerged"; return 1; }
    fi

    # `find -mtime +N` rather than stat: POSIX, no GNU/BSD flag split, and its
    # integer truncation rounds toward KEEPING (+7 needs a full 8 days), so even
    # --age-days 0 cannot reach a worktree created this session.
    find "$SWEEP_CANON" -maxdepth 0 -mtime +"$ARG_AGE_DAYS" 2>/dev/null | grep -q . \
        || { SWEEP_REASON="too-young"; return 1; }

    resolve_task "$SWEEP_CANON" "$br"
    [ -n "$SWEEP_TASK_ID" ]      || { SWEEP_REASON="no-task-id"; return 1; }
    [ -n "$SWEEP_TASK_STATUS" ]  || { SWEEP_REASON="task-unknown"; return 1; }
    [ "$SWEEP_TASK_STATUS" = "closed" ] || { SWEEP_REASON="task-not-closed"; return 1; }

    SWEEP_REASON="ok"
    return 0
}

# --- Report -----------------------------------------------------------------

emit_row() {
    # emit_row <status> <path> <reason> <branch> <task>
    if [ "$ARG_JSON" = "1" ]; then
        local row
        row=$(jq -n -c --arg p "$2" --arg s "$1" --arg r "$3" --arg b "$4" --arg t "$5" \
            '{path:$p,status:$s,reason:$r,branch:$b,task:$t}' 2>/dev/null) || row=""
        [ -n "$row" ] && JSON_ROWS="$JSON_ROWS$row
"
        return 0
    fi
    printf '  %-13s %s  reason=%s branch=%s task=%s\n' "$1" "$2" "$3" "${4:--}" "${5:--}"
}

JSON_ROWS=""
TOTAL=0; EXAMINED=0; REMOVABLE=0; REMOVED=0; KEPT=0; RC=0

finish() {
    if [ "$ARG_JSON" = "1" ]; then
        printf '%s' "$JSON_ROWS" | grep -v '^$' \
            | jq -s -c --arg root "$SWEEP_ROOT" --arg mode "$MODE" \
                --argjson age "${ARG_AGE_DAYS:-7}" --argjson total "$TOTAL" \
                --argjson examined "$EXAMINED" --argjson removable "$REMOVABLE" \
                --argjson removed "$REMOVED" --argjson kept "$KEPT" \
                '{root:$root,mode:$mode,age_days:$age,total:$total,examined:$examined,removable:$removable,removed:$removed,kept:$kept,candidates:.}'
    else
        printf 'worktree-sweep: Total: %d  examined: %d  removable: %d  removed: %d  kept: %d  (%s)\n' \
            "$TOTAL" "$EXAMINED" "$REMOVABLE" "$REMOVED" "$KEPT" "$MODE"
        [ "$ARG_APPLY" = "1" ] || [ "$REMOVABLE" = "0" ] \
            || printf 'worktree-sweep: nothing was removed; re-run with --apply to remove the %d above.\n' "$REMOVABLE"
    fi
    exit "$RC"
}

# --- Run --------------------------------------------------------------------

command -v git >/dev/null 2>&1 || { SWEEP_ROOT=""; finish; }
CURRENT_ID=$(repo_identity "$PROJECT_DIR")
CURRENT_TOP=$(canon "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)") || CURRENT_TOP=""
SWEEP_ROOT=$(canon "$PROJECT_DIR/.claude/worktrees") || SWEEP_ROOT=""
{ [ -n "$CURRENT_ID" ] && [ -n "$CURRENT_TOP" ] && [ -n "$SWEEP_ROOT" ]; } || finish

[ "$ARG_JSON" = "1" ] || printf 'worktree-sweep: root=%s age-days=%s mode=%s cap=%s\n' \
    "$SWEEP_ROOT" "$ARG_AGE_DAYS" "$MODE" "$SWEEP_MAX_CANDIDATES"

CANDIDATES=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(canon "$line")" = "$CURRENT_TOP" ] && continue   # never ourselves
    TOTAL=$((TOTAL + 1))
    [ "${#CANDIDATES[@]}" -ge "$SWEEP_MAX_CANDIDATES" ] && continue
    CANDIDATES+=("$line")
done < <(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

for wt in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    EXAMINED=$((EXAMINED + 1))
    if ! classify "$wt"; then
        KEPT=$((KEPT + 1))
        emit_row KEEP "${SWEEP_CANON:-$wt}" "$SWEEP_REASON" "$SWEEP_BRANCH" "$SWEEP_TASK_ID"
        continue
    fi
    REMOVABLE=$((REMOVABLE + 1))
    if [ "$ARG_APPLY" != "1" ]; then
        emit_row REMOVABLE "$SWEEP_CANON" ok "$SWEEP_BRANCH" "$SWEEP_TASK_ID"
        continue
    fi
    # No --force: gate 3 already proved the tree clean, so git refusing here is
    # new information (a race) and must surface, not be overridden.
    if git -C "$PROJECT_DIR" worktree remove "$SWEEP_CANON" >/dev/null 2>&1; then
        REMOVED=$((REMOVED + 1))
        emit_row REMOVED "$SWEEP_CANON" ok "$SWEEP_BRANCH" "$SWEEP_TASK_ID"
    else
        RC=1
        emit_row REMOVE-FAILED "$SWEEP_CANON" git-worktree-remove-failed "$SWEEP_BRANCH" "$SWEEP_TASK_ID"
    fi
done

[ "$REMOVED" = "0" ] || git -C "$PROJECT_DIR" worktree prune >/dev/null 2>&1 || true

finish

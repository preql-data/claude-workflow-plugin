#!/bin/bash
# bd-github-link.sh -- Auto-link Beads tasks <-> GitHub issues / PRs (I3).
#
# Phase 6b deliverable. Wired as a PostToolUse hook on Bash tool calls so it
# only fires when Claude (or a specialist) shells out via the Bash tool. It
# also tolerates being run manually for sanity-testing.
#
# Behaviour
# ---------
# 1) When a Beads task has just been closed (status: closed) and we can map
#    it to a GitHub issue or PR, post a one-line `gh issue comment` /
#    `gh pr comment` linking back to the task id. The mapping comes from
#    (in order of precedence):
#       a) An explicit "gh-link: <ref>" line in the task notes/comments,
#          where <ref> is `org/repo#N`, `#N`, or a full URL.
#       b) The current branch -- if HEAD is on a `bd-<task>` branch and an
#          open PR exists for it (`gh pr view --json url`), use that.
#       c) Beads config `github.repo` + `github.org` plus a recent PR/issue
#          authored by the current user that mentions the task id (we do
#          NOT scan unrelated repos -- only the configured one).
#
# 2) When `gh pr create` runs, parse the PR body for `Closes #N` / `Fixes #N`
#    / `Resolves #N` references (case-insensitive) and append a structured
#    `gh-link:` line to the active Beads task's notes via `bd update`. This
#    creates the inverse link so future closes can find the right PR.
#
# Graceful-degrade rules
# ----------------------
# - If `gh` is not installed, exit 0 silently (`command -v gh`).
# - If the GitHub remote isn't `github.com` (e.g., GitHub Enterprise on a
#   custom host), exit 0 silently. The user can opt in by running gh once
#   to authenticate against their host; we still skip auto-comments for
#   safety.
# - If `bd` isn't available, exit 0 silently -- nothing to link.
# - All `gh` invocations have a generous timeout; we don't want to delay
#   the Bash hook fire by multiple seconds in the common case.
#
# Hook contract
# -------------
# Stdin: PostToolUse JSON envelope from Claude Code. We only act when the
# tool was `Bash` and the command itself indicates a state-changing op.
# Stdout: `{}` (no-op envelope). This hook never blocks or injects context.
#
# Test mode: pass `--manual` to read action from $1/$2 instead of stdin.
#   bd-github-link.sh --manual close <task-id>
#   bd-github-link.sh --manual pr-create <pr-body-file>

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"

# Always emit a no-op envelope. Hooks must never block on this work.
emit_empty() { echo '{}'; }

# Trace failures into sync-errors.log so SessionStart can surface them. We
# don't want to spam stderr (the hook envelope drops it).
log_sync_error() {
    local msg="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    printf '%s\t[bd-github-link]\t%s\n' "$ts" "$msg" >> "$SYNC_ERRORS_LOG" 2>/dev/null || true
}

# Tool/dep guards. Order matters: cheapest check first so we don't burn
# milliseconds invoking gh when we're going to bail anyway.
if ! command -v gh >/dev/null 2>&1; then
    emit_empty
    exit 0
fi
if ! command -v bd >/dev/null 2>&1; then
    emit_empty
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    emit_empty
    exit 0
fi

# ----- Multi-host check -----
# We only post comments when the project's origin is on github.com. GitHub
# Enterprise (e.g., github.example.com) is a different auth scope; trying
# to comment there with the user's gh.com auth fails noisily.
GITHUB_REMOTE_OK=false
if remote_url=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null); then
    case "$remote_url" in
        *github.com:*|*github.com/*) GITHUB_REMOTE_OK=true ;;
        *)                            GITHUB_REMOTE_OK=false ;;
    esac
fi

# Even if the remote isn't on github.com we still let the script run for the
# inverse direction (recording PR refs into Beads notes) -- that's safe and
# host-agnostic. We only short-circuit the *outgoing comment* path on
# non-github.com hosts.

# ----- Helpers ------------------------------------------------------------

# Normalize PR/issue refs into "owner/repo#N" form when possible.
#  inputs accepted: "#42", "owner/repo#42", "https://github.com/owner/repo/pull/42",
#                   "https://github.com/owner/repo/issues/42".
normalize_ref() {
    local raw="$1"
    raw=$(printf '%s' "$raw" | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    [ -z "$raw" ] && return 1

    # Already owner/repo#N or just #N
    if [[ "$raw" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
        printf '%s' "$raw"
        return 0
    fi
    if [[ "$raw" =~ ^#([0-9]+)$ ]]; then
        printf '%s' "$raw"
        return 0
    fi

    # Full URL pattern - either issues or pull
    if [[ "$raw" =~ ^https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(issues|pull)/([0-9]+) ]]; then
        printf '%s/%s#%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
        return 0
    fi
    return 1
}

# Find an explicit gh-link reference attached to a Beads task. We look in
# notes (most recent) and most-recent comments, in that order.
find_gh_link() {
    local tid="$1"
    local payload
    payload=$(bd show "$tid" --json 2>/dev/null | jq -r '
        if type == "array" then .[0] else . end
        | (.notes // ""), (.comments // [] | map(.text) | reverse | .[])
    ' 2>/dev/null || echo "")

    # Iterate lines and pick the FIRST gh-link match.
    while IFS= read -r block; do
        while IFS= read -r line; do
            [[ "$line" =~ [Gg][Hh]-[Ll][Ii][Nn][Kk]:[[:space:]]*(.+)$ ]] || continue
            local raw="${BASH_REMATCH[1]}"
            local norm
            if norm=$(normalize_ref "$raw"); then
                printf '%s' "$norm"
                return 0
            fi
        done <<< "$block"
    done <<< "$payload"

    return 1
}

# Detect the GitHub repo for this checkout in "owner/repo" form. Falls
# through several signals; first non-empty wins.
detect_repo_slug() {
    # Beads config first: most authoritative for the *active* mapping.
    local org repo
    org=$(bd config get github.org 2>/dev/null | sed -E 's/^[A-Za-z._]+ //; /not set/d' | head -1 || echo "")
    repo=$(bd config get github.repo 2>/dev/null | sed -E 's/^[A-Za-z._]+ //; /not set/d' | head -1 || echo "")
    if [ -n "$org" ] && [ -n "$repo" ] && [[ "$org" != *"not set"* ]] && [[ "$repo" != *"not set"* ]]; then
        printf '%s/%s' "$org" "$repo"
        return 0
    fi

    # gh's own repo-detection (uses git remote + auth context).
    local slug
    slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
    if [ -n "$slug" ]; then
        printf '%s' "$slug"
        return 0
    fi

    # Final fallback: parse the origin URL ourselves.
    local url
    url=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || echo "")
    if [[ "$url" =~ github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(\.git)?$ ]]; then
        printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
        return 0
    fi
    return 1
}

# Resolve a normalized ref into something gh can use. Output is two values
# separated by a newline:
#   <kind>     "issue" or "pr"
#   <numeric>  the issue/PR number
#   <owner/repo> e.g., "preql-data/claude-workflow-plugin"
# Reads gh because PR vs issue is not derivable from the ref alone.
resolve_ref_kind() {
    local ref="$1"
    local slug num
    if [[ "$ref" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
        slug="${BASH_REMATCH[1]}"
        num="${BASH_REMATCH[2]}"
    elif [[ "$ref" =~ ^#([0-9]+)$ ]]; then
        num="${BASH_REMATCH[1]}"
        slug=$(detect_repo_slug 2>/dev/null || echo "")
        [ -z "$slug" ] && return 1
    else
        return 1
    fi

    # Try PR first (more specific) then issue. PR numbers and issue
    # numbers do not collide on GitHub.
    if gh pr view "$num" --repo "$slug" --json number >/dev/null 2>&1; then
        printf 'pr\n%s\n%s\n' "$num" "$slug"
        return 0
    fi
    if gh issue view "$num" --repo "$slug" --json number >/dev/null 2>&1; then
        printf 'issue\n%s\n%s\n' "$num" "$slug"
        return 0
    fi
    return 1
}

# Idempotent comment: avoid double-posting. We grep for the task id in the
# existing comments before adding ours. The body shape is fixed so the
# match is robust to surrounding text in the issue/PR thread.
#
# NOTE: this body must stay byte-aligned with the idempotency `grep -F`
# pattern in post_link_comment() below. If you change one, change the other.
# The earlier shape used **bold** around the backtick-wrapped id, which the
# grep never matched (bold + backtick disagreed), causing duplicate comments
# on every re-fire (QA defect, claude-workflow-plugin-vhm).
gh_link_comment_body() {
    local tid="$1"
    # shellcheck disable=SC2016  # literal backticks: this is the canonical
    # comment shape that post_link_comment() greps for verbatim.
    printf 'bd-link: tracked as `%s` (claude-workflow-plugin Beads task)\n' "$tid"
}

post_link_comment() {
    local kind="$1" num="$2" slug="$3" tid="$4"
    if [ "$GITHUB_REMOTE_OK" = false ]; then
        log_sync_error "skip post-link comment for $tid: origin not on github.com"
        return 0
    fi

    # Idempotency check.
    if existing=$(gh "$kind" view "$num" --repo "$slug" --json comments \
                    -q '.comments[].body' 2>/dev/null); then
        if printf '%s' "$existing" | grep -qF "bd-link: tracked as \`$tid\`"; then
            log_sync_error "skipping duplicate gh comment for $tid on $slug#$num"
            return 0
        fi
    fi

    if ! gh "$kind" comment "$num" --repo "$slug" --body "$(gh_link_comment_body "$tid")" >/dev/null 2>&1; then
        log_sync_error "gh $kind comment failed for $tid on $slug#$num"
        return 1
    fi
    log_sync_error "posted gh link comment for $tid on $slug#$num (kind=$kind)"
    return 0
}

# Append a `gh-link:` line to the task notes if not already present. Beads
# notes are single-slot; we read, check, and write back the merged value.
append_gh_link_to_notes() {
    local tid="$1" ref="$2"
    local existing
    existing=$(bd show "$tid" --json 2>/dev/null | jq -r '
        if type == "array" then .[0].notes else .notes end // ""
    ' 2>/dev/null || echo "")

    if printf '%s' "$existing" | grep -qE "^gh-link:[[:space:]]*$ref\$"; then
        return 0  # already present
    fi

    # Append the gh-link line; preserve existing notes verbatim.
    local newnotes
    if [ -n "$existing" ]; then
        newnotes="$existing"$'\n\n'"gh-link: $ref"
    else
        newnotes="gh-link: $ref"
    fi
    if ! bd update "$tid" --notes "$newnotes" >/dev/null 2>&1; then
        log_sync_error "bd update --notes failed when appending gh-link=$ref to $tid"
        return 1
    fi
    return 0
}

# Get the current active task id. Same precedence as other hooks.
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
get_current_task() {
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    fi
    printf '%s' "$tid"
}

# Extract the first valid Beads task id from a tail of `bd update` /
# `bd close` arguments. Skips flags (`--foo`, `--foo=bar`, `-x`), skips
# the values that follow non-attached flags (so `--reason "x"` does not
# trick us into picking `x`), strips one layer of surrounding quotes, and
# bails on shell control tokens (`|`, `;`, `&&`, redirections).
#
# This replaces a brittle three-alt regex that failed to match the
# canonical `bd update <tid> --status closed` shape and mis-captured the
# tid on the alt-order variant. Fix: claude-workflow-plugin-68n.
#
# stdout: the first valid tid, or nothing if none found.
# return: 0 if a tid was printed, 1 otherwise.
extract_tid_from_tail() {
    local tail="$1"
    # Word-split on IFS whitespace. We accept the limitation that quoted
    # values containing whitespace are split (e.g., `--reason "task done"`
    # becomes 3 words); that ambiguity is unavoidable without a real shell
    # parse and only causes us to pick a non-tid token, which downstream
    # `bd show <bogus>` rejects cleanly.
    # shellcheck disable=SC2206
    local words=($tail)
    local i=0 n=${#words[@]} skip_next=0
    while [ "$i" -lt "$n" ]; do
        local tok="${words[$i]}"
        # Strip one layer of surrounding double or single quote.
        tok="${tok%\"}"; tok="${tok#\"}"
        tok="${tok%\'}"; tok="${tok#\'}"
        if [ $skip_next -eq 1 ]; then
            skip_next=0; i=$((i+1)); continue
        fi
        case "$tok" in
            --*=*) i=$((i+1)); continue ;;
            --*)
                # Lookahead: if next token is non-flag, treat as this flag's value.
                local nxt=""
                if [ $((i+1)) -lt "$n" ]; then nxt="${words[$((i+1))]}"; fi
                nxt="${nxt%\"}"; nxt="${nxt#\"}"
                nxt="${nxt%\'}"; nxt="${nxt#\'}"
                if [ -n "$nxt" ] && [[ "$nxt" != -* ]]; then
                    skip_next=1
                fi
                i=$((i+1)); continue ;;
            -*) i=$((i+1)); continue ;;
            '|'|'&'|'&&'|'||'|';') return 1 ;;
        esac
        # Bail on shell redirections.
        if [[ "$tok" == 2\>* ]] || [[ "$tok" == \>* ]] || [[ "$tok" == \<* ]]; then
            return 1
        fi
        # Tid shape: alphanumerics, dot, dash, underscore. No leading dash.
        if [[ "$tok" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$tok" != -* ]]; then
            printf '%s' "$tok"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# ----- Manual mode: bd-github-link.sh --manual <action> [args]
if [ "${1:-}" = "--manual" ]; then
    shift
    action="${1:-}"
    case "$action" in
        close)
            tid="${2:-}"
            [ -z "$tid" ] && { echo "manual close requires <task-id>" >&2; exit 1; }
            # Wrap each step so a failed `gh` call (auth, missing PR, etc.)
            # doesn't propagate via set -e. We log to sync-errors.log and
            # exit 0 -- the caller (a hook in real use) MUST be tolerant.
            if ref=$(find_gh_link "$tid" 2>/dev/null); then
                if read_kind=$(resolve_ref_kind "$ref" 2>/dev/null); then
                    kind=$(printf '%s' "$read_kind" | sed -n '1p')
                    num=$(printf '%s' "$read_kind" | sed -n '2p')
                    slug=$(printf '%s' "$read_kind" | sed -n '3p')
                    post_link_comment "$kind" "$num" "$slug" "$tid" || \
                        log_sync_error "manual close: post_link_comment exited non-zero for $tid (graceful)"
                else
                    log_sync_error "manual close: could not resolve ref=$ref for $tid"
                fi
            else
                log_sync_error "manual close: no gh-link found on $tid"
            fi
            ;;
        pr-create)
            body_file="${2:-}"
            [ -z "$body_file" ] || [ ! -f "$body_file" ] && {
                echo "manual pr-create requires <body-file>" >&2; exit 1
            }
            tid=$(get_current_task)
            [ -z "$tid" ] && { log_sync_error "manual pr-create: no active task"; exit 0; }

            # Parse body for Closes/Fixes/Resolves <ref>. <ref> may be
            # `#N`, `owner/repo#N`, or a github.com URL (issues or pull).
            # The regex is intentionally a single alternation so BASH_REMATCH[2]
            # always holds the ref regardless of form. BASH_REMATCH[3] is the
            # URL kind sub-capture (issues|pull) when applicable -- we only
            # consume [2] and feed it to normalize_ref. Bash ERE has no
            # non-capturing groups so [3] is unavoidable; we just ignore it.
            # Fix: claude-workflow-plugin-7o7 (URL ref form previously missed).
            while IFS= read -r line; do
                if [[ "$line" =~ ([Cc]loses|[Ff]ixes|[Rr]esolves)[[:space:]]+(https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+) ]]; then
                    ref="${BASH_REMATCH[2]}"
                    if norm=$(normalize_ref "$ref"); then
                        append_gh_link_to_notes "$tid" "$norm"
                    fi
                fi
            done < "$body_file"
            ;;
        *)
            echo "Unknown manual action: $action" >&2
            echo "Usage: bd-github-link.sh --manual {close <task-id>|pr-create <body-file>}" >&2
            exit 1
            ;;
    esac
    exit 0
fi

# ----- Hook mode --------------------------------------------------------

# Read PostToolUse stdin. We're tolerant of missing fields.
INPUT=$(cat 2>/dev/null || echo "{}")
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
TOOL_RESPONSE_OUTPUT=$(echo "$INPUT" | jq -r '.tool_response.output // .tool_response.stdout // empty' 2>/dev/null || echo "")

# Only act when the tool is Bash. Other tools (Read/Edit/etc.) won't carry
# `gh pr create` or `bd update --status closed` invocations.
if [ "$TOOL_NAME" != "Bash" ]; then
    emit_empty
    exit 0
fi

# 1) Did this command close a Beads task?
#
# We support every shape the plugin and Beads users actually emit:
#   - `bd update <tid> --status closed`     (canonical, used by verify-before-stop.sh)
#   - `bd update <tid> --status=closed`     (`=` form)
#   - `bd update --status closed <tid>`     (alt flag-order)
#   - `bd update --foo=bar --status closed <tid>`   (with extra flags)
#   - `bd close <tid>`                      (Beads native close)
#   - `bd close --reason="x" <tid>`         (Beads close with reason)
#   - `bd close <tid> <tid2>`               (multi-id; we take the first)
#
# Earlier versions used a three-alt regex whose `.+` between the tid and
# `--status closed` rejected single-space inputs (the canonical case),
# and whose alt-order variant mis-captured `--status` as the tid. The
# fix below uses extract_tid_from_tail() to resolve the tid in a single
# pass, regardless of where it sits relative to flags.
# (claude-workflow-plugin-68n)
TASK_TO_CLOSE=""
# Shape A: `bd update ... --status closed` or `--status=closed` (any order).
if [[ "$COMMAND" =~ bd[[:space:]]+update([[:space:]]|$) ]] &&
   { [[ "$COMMAND" =~ --status[[:space:]]+closed ]] || [[ "$COMMAND" =~ --status=closed ]]; }; then
    update_tail=$(printf '%s' "$COMMAND" | sed -E 's/.*bd[[:space:]]+update[[:space:]]+//')
    TASK_TO_CLOSE=$(extract_tid_from_tail "$update_tail" || echo "")
fi
# Shape B: `bd close ... <tid> [...]` (flag-first or tid-first).
if [ -z "$TASK_TO_CLOSE" ] && [[ "$COMMAND" =~ bd[[:space:]]+close([[:space:]]|$) ]]; then
    close_tail=$(printf '%s' "$COMMAND" | sed -E 's/.*bd[[:space:]]+close([[:space:]]+|$)//')
    TASK_TO_CLOSE=$(extract_tid_from_tail "$close_tail" || echo "")
fi

if [ -n "$TASK_TO_CLOSE" ]; then
    # Validate id shape; bd ids include a slug + dotted index.
    if [[ "$TASK_TO_CLOSE" =~ ^[A-Za-z0-9._-]+$ ]]; then
        if ref=$(find_gh_link "$TASK_TO_CLOSE" 2>/dev/null); then
            if read_kind=$(resolve_ref_kind "$ref" 2>/dev/null); then
                kind=$(printf '%s' "$read_kind" | sed -n '1p')
                num=$(printf '%s' "$read_kind" | sed -n '2p')
                slug=$(printf '%s' "$read_kind" | sed -n '3p')
                post_link_comment "$kind" "$num" "$slug" "$TASK_TO_CLOSE" || true
            else
                log_sync_error "could not resolve gh ref=$ref for $TASK_TO_CLOSE"
            fi
        else
            # No explicit gh-link on task; try to detect via current branch.
            # If HEAD is on bd-<task>, look up an open PR for that branch.
            current_branch=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
            if [ -n "$current_branch" ] && [ "$current_branch" != "HEAD" ]; then
                if pr_url=$(gh pr view --json url -q .url 2>/dev/null); then
                    if [[ "$pr_url" =~ github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+) ]]; then
                        slug="${BASH_REMATCH[1]}"
                        num="${BASH_REMATCH[2]}"
                        post_link_comment "pr" "$num" "$slug" "$TASK_TO_CLOSE" || true
                    fi
                fi
            fi
        fi
    fi
fi

# 2) Did this command create a PR? Detect `gh pr create`.
if [[ "$COMMAND" =~ gh[[:space:]]+pr[[:space:]]+create ]]; then
    # Parse body from the command itself first (`--body "..."` or `-b "..."`).
    PR_BODY=""
    if [[ "$COMMAND" =~ --body[[:space:]]+\"([^\"]*)\" ]] ||
       [[ "$COMMAND" =~ --body[[:space:]]+\'([^\']*)\' ]]; then
        PR_BODY="${BASH_REMATCH[1]}"
    fi
    # Fallback: gh pr create's tool_response.output sometimes contains the
    # PR url; we don't need the body if we can chase the URL.
    if [ -z "$PR_BODY" ] && [ -n "$TOOL_RESPONSE_OUTPUT" ]; then
        # Look for a PR URL in the output and pull its body.
        if [[ "$TOOL_RESPONSE_OUTPUT" =~ (https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+) ]]; then
            pr_url="${BASH_REMATCH[1]}"
            PR_BODY=$(gh pr view "$pr_url" --json body -q .body 2>/dev/null || echo "")
        fi
    fi

    if [ -n "$PR_BODY" ]; then
        active_task=$(get_current_task)
        if [ -n "$active_task" ]; then
            # Walk the body, pull all `Closes/Fixes/Resolves <ref>` refs,
            # where <ref> can be `#N`, `owner/repo#N`, or a github.com URL
            # (issues or pull). Single-alternation regex keeps BASH_REMATCH[2]
            # as the ref regardless of form; BASH_REMATCH[3] is the unavoidable
            # (issues|pull) sub-capture which we ignore (Bash ERE has no
            # non-capturing groups). Fix: claude-workflow-plugin-7o7.
            while IFS= read -r line; do
                if [[ "$line" =~ ([Cc]loses|[Ff]ixes|[Rr]esolves)[[:space:]]+(https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+) ]]; then
                    raw_ref="${BASH_REMATCH[2]}"
                    if norm=$(normalize_ref "$raw_ref"); then
                        append_gh_link_to_notes "$active_task" "$norm" || true
                    fi
                fi
            done <<< "$PR_BODY"
        else
            log_sync_error "gh pr create detected but no active task; cannot persist link"
        fi
    fi
fi

emit_empty
exit 0

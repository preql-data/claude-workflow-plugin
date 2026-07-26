#!/bin/bash
# impact-report.sh — mechanical impact_of artifact generator (G2.n6d /
# claude-workflow-plugin-llh.2).
#
# WHY THIS EXISTS: across 4 paid live runs the QA agent made ZERO
# impact_of calls regardless of prompt strength — even with the exact
# tool name, alias, target symbols, and invariant name in its task
# prompt (evidence: bd show claude-workflow-plugin-n6d; seed traces in
# .claude/tests/e2e/cassettes/seed/). Prompts are suggestions. This
# script makes the impact analysis a DETERMINISTIC ARTIFACT the model
# cannot skip:
#
#   - `qa-gate.sh enter` invokes this script (tolerantly) so the report
#     exists the moment a review cycle opens.
#   - `qa-gate.sh approve` REFUSES (exit 2) when the report is missing
#     or its change_set_hash no longer matches the current changed-files
#     list. Regenerating is one command (below). A documented bypass
#     (`approve --no-impact-report '<reason>'`) exists for genuine
#     emergencies and is recorded in the audit trail.
#
# Usage:
#   impact-report.sh <task-id>     Generate the artifact:
#                                  .claude/.qa-tracking/impact-report-<task-id>.json
#   impact-report.sh --hash-only   Print the sha256 of the CURRENT canonical
#                                  changed-files list and exit. qa-gate.sh
#                                  approve uses this to detect stale reports;
#                                  keeping the canonicalisation in ONE place
#                                  prevents generator/checker drift.
#
# Artifact shape (the per-file `impact` value is the code-graph server's
# structuredContent envelope — {ok, headline, data, llm_observations} on
# success, {ok:false, error:{...}} on a per-file failure — or null when
# the server is absent):
#
#   {
#     "generated_at":    "2026-06-13T00:00:00Z",
#     "task_id":         "<task-id>",
#     "change_set_hash": "<sha256 of the sorted, denylist-filtered changed-files list>",
#     "files":           [{"file": "<path as tracked>", "impact": <object|null>}, ...],
#     "server":          "code-graph" | "absent"
#   }
#
# Degradation contract: the artifact ALWAYS exists after this script
# exits 0; only its CONTENT degrades.
#   - Server absent/unbootable (bin missing, node missing, init handshake
#     times out): server="absent", every impact=null. qa-gate.sh approve
#     ACCEPTS this — it is the documented degradation, not a gate failure.
#   - Per-file tool errors (unindexed path, validation rejection, call
#     timeout): recorded as {ok:false, error:{...}} for that file; the
#     run CONTINUES with the remaining files.
#
# Transport: we drive the code-graph MCP server DIRECTLY over stdio with
# line-delimited JSON-RPC (initialize -> notifications/initialized ->
# tools/call impact_of per file) — one server process for the whole run.
# Unlike the fixed-sleep pattern in the L2 component spec
# (.claude/tests/component/specs/code-graph-mcp.sh), stdin is held open
# via a FIFO until every expected response has been read: the server's
# lazy index build on first call can take minutes on a large repo, and a
# fixed sleep would close stdin (the server exits on stdin EOF — see
# src/server.js) before the response arrives.
#
# Time bounds (env-tunable; generous because the first tools/call pays
# for the whole index build):
#   IMPACT_REPORT_TIMEOUT_S             overall budget   (default 600)
#   IMPACT_REPORT_FIRST_CALL_TIMEOUT_S  first impact_of  (default 300)
#   IMPACT_REPORT_CALL_TIMEOUT_S        later impact_of  (default 60)
#   IMPACT_REPORT_BOOT_TIMEOUT_S        init handshake   (default 30)
#
# Test hooks (also useful for non-standard installs):
#   CODE_GRAPH_MCP_BIN   path to the server entry point (default:
#                        $PROJECT_DIR/.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js)
#   IMPACT_REPORT_NODE   node binary (default: node)
#
# Exit codes:
#   0  artifact written (possibly degraded)
#   1  usage error (missing task id)
#   3  environment cannot produce the artifact at all (jq missing, or
#      .qa-tracking unwritable) — qa-gate.sh enter logs this loudly.
#
# Progress is logged to stderr so an interactive caller can watch the
# index build; qa-gate.sh enter captures it into a per-task log.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"
MCP_BIN="${CODE_GRAPH_MCP_BIN:-$PROJECT_DIR/.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js}"
NODE_BIN="${IMPACT_REPORT_NODE:-node}"

OVERALL_TIMEOUT_S="${IMPACT_REPORT_TIMEOUT_S:-600}"
FIRST_CALL_TIMEOUT_S="${IMPACT_REPORT_FIRST_CALL_TIMEOUT_S:-300}"
CALL_TIMEOUT_S="${IMPACT_REPORT_CALL_TIMEOUT_S:-60}"
BOOT_TIMEOUT_S="${IMPACT_REPORT_BOOT_TIMEOUT_S:-30}"

# Denylist over build artifacts + workflow-internal churn — the SAME
# definition post-edit.sh uses to decide what to track and
# verify-before-stop.sh uses to decide what needs review. The canonical
# change set here MUST match the gate's notion of "changed" or hash
# comparisons drift; 3mg.1 replaced the three drifted copies of this regex
# with the single source below.
#
# Resolved relative to THIS script (BASH_SOURCE), not $PROJECT_DIR: the
# generator may run with CLAUDE_PROJECT_DIR pointing at a different checkout
# than the install it was launched from.
#
# FAIL CLOSED on a missing lib: without the denylist we cannot compute the
# canonical hash the gate binds approvals to, and an unverifiable hash must
# never be silently replaced by a plausible-looking one. Exiting 3 here means
# `--hash-only` prints nothing and the generator writes no artifact, both of
# which upstream (qa-gate.sh compute_change_set_hash -> approve's refusal,
# verify-before-stop.sh's LABEL_WITHOUT_RECORD arm) already treats as
# refuse-to-release.
_WFDL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || _WFDL_DIR=""
if [ -n "$_WFDL_DIR" ] && [ -f "$_WFDL_DIR/workflow-denylist.sh" ]; then
    # shellcheck source=.claude/scripts/workflow-denylist.sh
    . "$_WFDL_DIR/workflow-denylist.sh"
fi
if [ -z "${WORKFLOW_DENYLIST_REGEX:-}" ]; then
    printf '[impact-report] FATAL: workflow-denylist.sh not found or did not define WORKFLOW_DENYLIST_REGEX (looked in %s). Refusing to emit a change-set hash computed with an unknown filter.\n' \
        "${_WFDL_DIR:-<unresolvable script dir>}" >&2
    exit 3
fi
DENYLIST_REGEX="$WORKFLOW_DENYLIST_REGEX"

log() {
    printf '[impact-report] %s\n' "$1" >&2
}

# Writes to a dead FIFO reader must fail with a non-zero rc, not kill
# the script (default SIGPIPE action terminates the shell).
trap '' PIPE

# ---------------------------------------------------------------------------
# Path relativisation for impact_of.
#
# The code-graph index keys every file by its path RELATIVE TO THE PROJECT
# ROOT (resolveProjectRoot = CLAUDE_PROJECT_DIR; see
# .claude/mcp/code-graph-mcp/src/lib/resolve.js). validateScopePath
# REJECTS absolute paths outright ("file must be a project-relative path,
# not absolute"; src/lib/validate.js). So every path we hand to impact_of
# MUST be project-relative or every call errors — which is exactly how the
# artifact silently degraded (preql-backend-9n5: the c0l run errored on
# 29/29 files identically, hash-valid but caller-data-empty).
#
# The changed-files list is NOT confined to the analyzed checkout. A live
# run mixes paths from:
#   - the analyzed project itself        -> $PROJECT_DIR/src/...
#   - a SIBLING WORKTREE of the same repo -> $PROJECT_DIR-<feature>/src/...
#   - genuinely foreign repos             -> .../genie-joindataset/...
#   - non-git scratch                     -> /tmp/..., ~/.claude/...
# A naive "strip $PROJECT_DIR/" prefix (the previous behaviour) only ever
# matched the first bucket; everything else stayed absolute and errored.
#
# Correct relativisation: ask git itself for each file's repo-relative
# path. Two worktrees of one repo share a git COMMON-DIR (the main .git),
# and the same repo-relative path resolves to the same index key — so a
# file under a sibling worktree relativises to a key that IS in this
# project's index. A file in a DIFFERENT repo (or no repo at all) cannot
# be in this index; we record it as an explicit per-file skip rather than
# fire a guaranteed-to-error absolute-path call (which also wastes the
# call budget and pollutes the report with the noisy validation message).
#
# Symlink hygiene: git's --show-toplevel / worktree gitdir pointers return
# fully symlink-resolved paths (e.g. /private/var/... on macOS) while
# CLAUDE_PROJECT_DIR and the changed-files entries may be the un-resolved
# spelling (/var/...). We therefore (a) compare common-dirs only after
# normalising BOTH through `pwd -P`, and (b) build the relative path from
# git's `--show-prefix` + basename rather than string-stripping a prefix
# off the raw path — so neither comparison nor relativisation depends on
# how the path happened to be spelled.

# canon_dir <path> -> absolute, symlink-resolved directory (empty on failure)
canon_dir() { ( cd "$1" 2>/dev/null && pwd -P ); }

# git common-dir of the analyzed project, normalised — the identity we
# match sibling worktrees against. Empty when $PROJECT_DIR is not a git
# checkout (then relativize_for_impact falls back to a literal prefix
# strip so a non-git install still works for files under $PROJECT_DIR).
PROJECT_COMMON_DIR=""
if _pcd_raw=$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null) && [ -n "$_pcd_raw" ]; then
    # --git-common-dir may be relative to PROJECT_DIR; resolve from there.
    PROJECT_COMMON_DIR=$(canon_dir "$PROJECT_DIR/$_pcd_raw")
    [ -n "$PROJECT_COMMON_DIR" ] || PROJECT_COMMON_DIR=$(canon_dir "$_pcd_raw")
fi
unset _pcd_raw

# Per-directory memo: the changed-files list is sort -u'd (see
# canonical_changed_files), so files in the same directory are contiguous
# and caching the previous directory's git lookup avoids re-forking git
# per file on large change sets. bash-3.2 safe (no associative arrays).
_GIT_MEMO_DIR=""
_GIT_MEMO_COMMON=""   # normalised common-dir of the memoised directory ("" = not in a git repo)
_GIT_MEMO_PREFIX=""   # `git rev-parse --show-prefix` for the memoised directory (dir relative to its toplevel)

_git_lookup_dir() {
    # _git_lookup_dir <dir> — populate _GIT_MEMO_COMMON / _GIT_MEMO_PREFIX.
    # Memoised on the last directory queried.
    local dir="$1"
    if [ "$dir" = "$_GIT_MEMO_DIR" ]; then
        return 0
    fi
    _GIT_MEMO_DIR="$dir"
    _GIT_MEMO_COMMON=""
    _GIT_MEMO_PREFIX=""
    [ -d "$dir" ] || return 0
    local common
    common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 0
    [ -n "$common" ] || return 0
    # --git-common-dir is relative to the dir's gitdir resolution; resolve
    # from <dir> (covers both the "../../.git" and absolute-pointer forms).
    _GIT_MEMO_COMMON=$(canon_dir "$dir/$common")
    [ -n "$_GIT_MEMO_COMMON" ] || _GIT_MEMO_COMMON=$(canon_dir "$common")
    # --show-prefix: the dir's path relative to its own toplevel, e.g.
    # "src/configs/". Empty at a repo root. git-supplied, so symlink-safe.
    _GIT_MEMO_PREFIX=$(git -C "$dir" rev-parse --show-prefix 2>/dev/null) || _GIT_MEMO_PREFIX=""
}

relativize_for_impact() {
    # relativize_for_impact <file> -> prints the project-relative path on
    # stdout and returns 0 when <file> belongs to the analyzed project
    # (directly OR via a sibling worktree of the same repo); returns 1
    # (printing nothing) when <file> is outside the analyzed project and
    # must NOT be sent to impact_of.
    local f="$1"
    local dir base
    dir=$(dirname "$f")
    base=$(basename "$f")
    _git_lookup_dir "$dir"

    # Same git repo as the analyzed project (covers $PROJECT_DIR itself and
    # every sibling worktree): the repo-relative path = show-prefix + base.
    if [ -n "$PROJECT_COMMON_DIR" ] && [ -n "$_GIT_MEMO_COMMON" ] && \
       [ "$_GIT_MEMO_COMMON" = "$PROJECT_COMMON_DIR" ]; then
        printf '%s%s\n' "$_GIT_MEMO_PREFIX" "$base"
        return 0
    fi

    # Fallback when we cannot use git (PROJECT_DIR not a checkout): keep the
    # original literal-prefix behaviour so a non-git install still works for
    # files that genuinely sit under $PROJECT_DIR.
    if [ -z "$PROJECT_COMMON_DIR" ]; then
        case "$f" in
            "$PROJECT_DIR"/*) printf '%s\n' "${f#"$PROJECT_DIR"/}"; return 0 ;;
        esac
    fi

    # Different repo, non-git scratch (/tmp, ~/.claude), or otherwise not
    # part of the analyzed project: not in this index, do not call.
    return 1
}

# ---------------------------------------------------------------------------
# Canonical change set + hash. ONE implementation, used by both the
# generator below and `qa-gate.sh approve` (via --hash-only).

canonical_changed_files() {
    [ -f "$TRACKING_FILE" ] || return 0
    local line
    # LC_ALL=C pins the sort order: the report may be generated from an
    # interactive shell and freshness-checked from a hook with a
    # different locale; a locale-dependent sort would make the same list
    # hash differently (false-stale refusals).
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" =~ $DENYLIST_REGEX ]]; then
            continue
        fi
        printf '%s\n' "$line"
    done < <(LC_ALL=C sort -u "$TRACKING_FILE" 2>/dev/null)
}

sha256_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum 2>/dev/null | awk '{print $1}'
    else
        # Degenerate but consistent: both generator and checker emit the
        # same literal, so freshness comparison still functions (it just
        # can't detect staleness — log so the gap is visible).
        cat >/dev/null
        printf 'sha256-unavailable'
    fi
}

change_set_hash() {
    canonical_changed_files | sha256_stdin
}

# ---------------------------------------------------------------------------
# Arg parsing.

case "${1:-}" in
    --hash-only)
        # Normalize: exactly one trailing newline regardless of which
        # hash tool ran (awk emits one, the no-tool fallback does not).
        printf '%s\n' "$(change_set_hash)"
        exit 0
        ;;
    ""|-h|--help)
        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 1
        ;;
esac

TASK_ID="$1"
SANITIZED_TID=$(printf '%s' "$TASK_ID" | tr -c 'A-Za-z0-9._-' '_')
REPORT_FILE="$QA_TRACKING_DIR/impact-report-$SANITIZED_TID.json"

if ! command -v jq >/dev/null 2>&1; then
    log "FATAL: jq is required to assemble the report and is not on PATH"
    exit 3
fi
if ! mkdir -p "$QA_TRACKING_DIR" 2>/dev/null; then
    log "FATAL: cannot create $QA_TRACKING_DIR"
    exit 3
fi

# ---------------------------------------------------------------------------
# Collect the change set once (array; bash 3.2 safe).

CHANGED=()
while IFS= read -r line; do
    CHANGED+=("$line")
done < <(canonical_changed_files)

HASH=$(change_set_hash)
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

WORK_DIR=$(mktemp -d -t impact-report.XXXXXX)
ENTRIES_FILE="$WORK_DIR/entries.jsonl"
: > "$ENTRIES_FILE"
SERVER_PID=""
FIFO_OPEN=0

cleanup() {
    if [ "$FIFO_OPEN" = "1" ]; then
        exec 3>&- 2>/dev/null || true
        FIFO_OPEN=0
    fi
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

append_entry() {
    # append_entry <file> <impact-json-or-the-word-null>
    local f="$1" impact="$2"
    if [ "$impact" != "null" ] && ! printf '%s' "$impact" | jq -e 'type' >/dev/null 2>&1; then
        impact=$(jq -nc --arg m "unparseable tool response" '{ok:false, error:{message:$m}}')
    fi
    jq -nc --arg file "$f" --argjson impact "$impact" '{file:$file, impact:$impact}' >> "$ENTRIES_FILE"
}

write_report() {
    # write_report <server-mode>
    local server_mode="$1"
    local tmp="$REPORT_FILE.tmp.$$"
    if jq -n \
        --arg generated_at "$GENERATED_AT" \
        --arg task_id "$TASK_ID" \
        --arg change_set_hash "$HASH" \
        --arg server "$server_mode" \
        --slurpfile files "$ENTRIES_FILE" \
        '{generated_at:$generated_at, task_id:$task_id, change_set_hash:$change_set_hash, files:$files, server:$server}' \
        > "$tmp" 2>/dev/null; then
        mv "$tmp" "$REPORT_FILE"
        log "report written: $REPORT_FILE (server=$server_mode, files=${#CHANGED[@]}, change_set_hash=$HASH)"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    log "FATAL: jq failed to assemble the report"
    return 1
}

absent_report() {
    # The artifact always exists; content degrades. Every file gets
    # impact:null in absent mode.
    : > "$ENTRIES_FILE"
    local f
    for f in ${CHANGED[@]+"${CHANGED[@]}"}; do
        append_entry "$f" "null"
    done
    write_report "absent" || exit 3
    exit 0
}

# ---------------------------------------------------------------------------
# Server availability. Absent/unbootable -> degraded artifact, exit 0.

if [ ! -f "$MCP_BIN" ]; then
    log "code-graph server bin not found at $MCP_BIN — writing degraded report (server=absent)"
    absent_report
fi
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    log "node binary '$NODE_BIN' not on PATH — writing degraded report (server=absent)"
    absent_report
fi

# ---------------------------------------------------------------------------
# Boot the server: one process, stdin held open via FIFO until all
# responses are in. Server stdout (line-delimited JSON-RPC frames)
# accumulates in $OUT_FILE; we poll it per request id.

OUT_FILE="$WORK_DIR/server-out.jsonl"
ERR_FILE="$WORK_DIR/server-err.log"
FIFO="$WORK_DIR/in.fifo"

if ! mkfifo "$FIFO" 2>/dev/null; then
    log "mkfifo failed in $WORK_DIR — writing degraded report (server=absent)"
    absent_report
fi

CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$NODE_BIN" "$MCP_BIN" < "$FIFO" > "$OUT_FILE" 2> "$ERR_FILE" &
SERVER_PID=$!

# Opening the write end unblocks the server's pending open of the read end.
exec 3> "$FIFO"
FIFO_OPEN=1

NOW_EPOCH() { date +%s; }
START_EPOCH=$(NOW_EPOCH)

server_alive() {
    [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null
}

send_frame() {
    # send_frame <json-line> -> 0 on success, 1 when the server is gone.
    server_alive || return 1
    printf '%s\n' "$1" >&3 2>/dev/null || return 1
    return 0
}

# wait_for_id <id> <deadline-epoch> -> 0 when a frame with that id is in
# $OUT_FILE, 1 on timeout/server-death. The id match is boundary-guarded
# so id=1 cannot match id=101.
frame_grep() {
    grep -E "\"id\"[[:space:]]*:[[:space:]]*${1}([^0-9]|\$)" "$OUT_FILE" 2>/dev/null | head -1
}

wait_for_id() {
    local id="$1" deadline="$2"
    while :; do
        if [ -n "$(frame_grep "$id")" ]; then
            return 0
        fi
        if [ "$(NOW_EPOCH)" -ge "$deadline" ]; then
            return 1
        fi
        # A dead server will never answer; bail early (but only after a
        # final read — the frame may have flushed as the process exited).
        if ! server_alive; then
            [ -n "$(frame_grep "$id")" ] && return 0
            return 1
        fi
        sleep 0.2
    done
}

INIT_FRAME='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"impact-report","version":"1.0.0"}}}'

log "booting code-graph server ($MCP_BIN) for ${#CHANGED[@]} changed file(s)"
if ! send_frame "$INIT_FRAME" || ! wait_for_id 1 $(( $(NOW_EPOCH) + BOOT_TIMEOUT_S )); then
    log "initialize handshake failed within ${BOOT_TIMEOUT_S}s — server stderr tail:"
    tail -5 "$ERR_FILE" >&2 2>/dev/null || true
    log "writing degraded report (server=absent)"
    cleanup
    trap - EXIT
    WORK_DIR=$(mktemp -d -t impact-report.XXXXXX)
    ENTRIES_FILE="$WORK_DIR/entries.jsonl"
    : > "$ENTRIES_FILE"
    trap cleanup EXIT
    absent_report
fi
send_frame '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true

# ---------------------------------------------------------------------------
# One impact_of call per changed file. Sequential send->wait so the
# per-call timeout and the progress log stay truthful. Request ids start
# at 100 (3-digit, collision-free against the boundary-guarded grep).

IDX=0
TOTAL=${#CHANGED[@]}
for f in ${CHANGED[@]+"${CHANGED[@]}"}; do
    IDX=$((IDX + 1))
    REQ_ID=$((99 + IDX))

    # Project-relative path for the tool (the index keys files relative to
    # the project root; absolute paths are rejected by validation). A file
    # that belongs to the analyzed project — directly or via a sibling
    # worktree of the same repo — relativises to a real index key; a file
    # in a different repo or in non-git scratch (/tmp, ~/.claude) can never
    # be in this index, so we record an explicit skip instead of firing a
    # guaranteed-to-error absolute-path call.
    if ! REL=$(relativize_for_impact "$f"); then
        log "($IDX/$TOTAL) SKIP $f — outside the analyzed project (different repo or non-git path); not in this index"
        append_entry "$f" "$(jq -nc --arg m "skipped: path is outside the analyzed project (different repo or non-git scratch path) and cannot be in this project code-graph index" '{ok:false, error:{message:$m}}')"
        continue
    fi

    ELAPSED=$(( $(NOW_EPOCH) - START_EPOCH ))
    REMAINING=$(( OVERALL_TIMEOUT_S - ELAPSED ))
    if [ "$REMAINING" -le 0 ]; then
        log "($IDX/$TOTAL) SKIP $REL — overall budget of ${OVERALL_TIMEOUT_S}s exhausted"
        append_entry "$f" "$(jq -nc --arg m "overall impact-report budget of ${OVERALL_TIMEOUT_S}s exhausted before this file was processed" '{ok:false, error:{message:$m}}')"
        continue
    fi

    CALL_BUDGET="$CALL_TIMEOUT_S"
    [ "$IDX" -eq 1 ] && CALL_BUDGET="$FIRST_CALL_TIMEOUT_S"   # first call pays for the index build
    [ "$CALL_BUDGET" -gt "$REMAINING" ] && CALL_BUDGET="$REMAINING"

    log "($IDX/$TOTAL) impact_of file=$REL (budget ${CALL_BUDGET}s)"
    FRAME=$(jq -nc --argjson id "$REQ_ID" --arg file "$REL" \
        '{jsonrpc:"2.0", id:$id, method:"tools/call", params:{name:"impact_of", arguments:{file:$file, max_depth:5}}}')

    if ! send_frame "$FRAME"; then
        log "($IDX/$TOTAL) server process died before the call could be sent"
        append_entry "$f" "$(jq -nc --arg m "code-graph server process exited mid-run before this file was processed" '{ok:false, error:{message:$m}}')"
        continue
    fi

    if ! wait_for_id "$REQ_ID" $(( $(NOW_EPOCH) + CALL_BUDGET )); then
        log "($IDX/$TOTAL) no response within ${CALL_BUDGET}s for $REL — recorded as per-file error"
        append_entry "$f" "$(jq -nc --arg m "impact_of timed out after ${CALL_BUDGET}s (index build on a large repo? raise IMPACT_REPORT_FIRST_CALL_TIMEOUT_S / IMPACT_REPORT_TIMEOUT_S)" '{ok:false, error:{message:$m}}')"
        continue
    fi

    RESPONSE=$(frame_grep "$REQ_ID")
    if printf '%s' "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        # JSON-RPC protocol-level error frame.
        append_entry "$f" "$(printf '%s' "$RESPONSE" | jq -c '{ok:false, error:{message:(.error.message // "json-rpc error")}}' 2>/dev/null || jq -nc '{ok:false, error:{message:"json-rpc error (unparseable frame)"}}')"
    elif printf '%s' "$RESPONSE" | jq -e '.result.structuredContent' >/dev/null 2>&1; then
        # Normal tool envelope — ok and per-file tool errors both live
        # here ({ok:true, data:...} / {ok:false, error:{...}}).
        append_entry "$f" "$(printf '%s' "$RESPONSE" | jq -c '.result.structuredContent')"
    elif printf '%s' "$RESPONSE" | jq -e '.result.isError == true' >/dev/null 2>&1; then
        append_entry "$f" "$(printf '%s' "$RESPONSE" | jq -c '{ok:false, error:{message:(.result.content[0].text // "tool error without structuredContent")}}' 2>/dev/null || jq -nc '{ok:false, error:{message:"tool error (unparseable frame)"}}')"
    else
        append_entry "$f" "$(jq -nc '{ok:false, error:{message:"unrecognized response shape from code-graph server"}}')"
    fi
done

# Shutdown. Closing the FIFO's last write end SHOULD deliver EOF to the
# server (src/server.js: "Process stays alive until stdin closes"), but
# macOS kqueue does not reliably surface EOF on a FIFO whose writers
# came and went (observed live during llh.2 development: node held the
# read end with zero writers and never exited; the script then hung at
# `wait`). Every response we need is already captured in $OUT_FILE, so
# after a short grace window we terminate the server explicitly — there
# is no in-flight state to flush (each tool call closes its DB handle
# before responding).
exec 3>&-
FIFO_OPEN=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    server_alive || break
    sleep 0.2
done
if server_alive; then
    log "server did not exit on stdin EOF (macOS FIFO/kqueue quirk) — sending SIGTERM"
    kill "$SERVER_PID" 2>/dev/null || true
fi
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

write_report "code-graph" || exit 3
exit 0

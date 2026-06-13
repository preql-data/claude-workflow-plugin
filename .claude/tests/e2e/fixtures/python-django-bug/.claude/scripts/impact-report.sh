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

# Denylist over build/lock artifacts — the SAME regex post-edit.sh uses
# to decide what to track and verify-before-stop.sh uses to decide what
# needs review. The canonical change set here must match the gate's
# notion of "changed" or hash comparisons drift. (Three copies of this
# regex now exist; they were already duplicated pre-llh.2 — see the
# tech-debt note on the Beads task.)
DENYLIST_REGEX='(^|/)(node_modules|dist|build|coverage|\.git|\.next|\.nuxt|target|__pycache__)/|\.(lock|lockb|map|pyc)$|\.min\.(js|css)$|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb|Cargo\.lock|poetry\.lock|go\.sum)$'

log() {
    printf '[impact-report] %s\n' "$1" >&2
}

# Writes to a dead FIFO reader must fail with a non-zero rc, not kill
# the script (default SIGPIPE action terminates the shell).
trap '' PIPE

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

    # Project-relative path for the tool (the index keys files relative
    # to the project root; absolute paths are rejected by validation —
    # a rejection we record per-file rather than fail on).
    REL="$f"
    case "$f" in
        "$PROJECT_DIR"/*) REL="${f#"$PROJECT_DIR"/}" ;;
    esac

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

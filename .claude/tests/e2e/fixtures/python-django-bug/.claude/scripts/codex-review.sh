#!/bin/bash
# codex-review.sh — root-invoked driver for the optional Sol (Codex) review
# turn (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# WHY THIS EXISTS: when the reviewer lane is `codex` (see codex-detect.sh),
# the orchestrator asks Sol for an INDEPENDENT, ADVISORY review. Sol runs
# inside the Codex MCP server (a native binary) as a read-only sandbox agent.
# This script drives that server directly over line-delimited JSON-RPC using
# the SAME pure-bash FIFO client pattern as impact-report.sh, hands Sol a
# bounded review envelope, and turns its final message into a validated review
# artifact on disk. Bounded diligence: every cap comes from .claude/review-config
# and a cap-hit sets `stopped_by` — never a loop. Sol is advisory only: this
# script writes an artifact file and nothing else (no labels, no gate state).
#
# Usage:
#   codex-review.sh <task-id> --request <file> --iteration <n>
#
# Exit codes:
#   0  artifact written (path echoed on stdout)
#   1  usage error
#   4  the review request failed schema validation (via review-check.sh)
#   5  Sol could not produce a valid artifact within budget (timeout, server
#      gone, or still-invalid after the malformed-retry corrective turns) —
#      NO artifact is written; the caller degrades to the Claude path
#   6  iteration exceeds the max_review_iterations cap
#
# Transport / stub seams (mirror impact-report.sh's CODE_GRAPH_MCP_BIN):
#   CODEX_USER_CONFIG   registration source (default $HOME/.claude.json)
#   CODEX_MCP_BIN       override server command (tests: node)
#   CODEX_MCP_ARGS      space-delimited args for the override (tests: <stub.js>)
#   CODEX_MCP_MODEL     override the recorded reviewer_model
#
# The REAL codex-cli 0.145.0 schema (probed offline) drives the call:
#   tools/call codex   {prompt, sandbox:"read-only", cwd}   (required: prompt;
#                       additionalProperties:false; sandbox enum read-only|...)
#   tools/call codex-reply {threadId, prompt}   (threadId is the canonical
#                       follow-up handle; conversationId is deprecated)
#   result: .content[].text (final message) + .structuredContent.threadId

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
REVIEW_CONFIG="$PROJECT_DIR/.claude/review-config"
REVIEW_CHECK="$PROJECT_DIR/.claude/scripts/review-check.sh"
USER_CONFIG="${CODEX_USER_CONFIG:-$HOME/.claude.json}"

trap '' PIPE

log() { printf '[codex-review] %s\n' "$1" >&2; }

if ! command -v jq >/dev/null 2>&1; then
    log "FATAL: jq is required and not on PATH"
    exit 5
fi

# ---------------------------------------------------------------------------
# Arg parsing.
TASK_ID="${1:-}"
if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "-h" ] || [ "$TASK_ID" = "--help" ]; then
    cat >&2 <<'USAGE'
Usage: codex-review.sh <task-id> --request <file> --iteration <n>
Drives the optional Sol (Codex) review turn and writes a validated review
artifact to .claude/.qa-tracking/review-artifact-<task-id>-r<n>.json.
Exit: 0 ok | 1 usage | 4 invalid request | 5 no artifact (degrade) | 6 iteration cap.
USAGE
    exit 1
fi
shift || true

REQUEST_FILE=""
ITER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --request)   REQUEST_FILE="${2:-}"; shift 2 || true ;;
        --iteration) ITER="${2:-}"; shift 2 || true ;;
        *) log "unknown argument: $1"; exit 1 ;;
    esac
done

if [ -z "$REQUEST_FILE" ] || [ -z "$ITER" ]; then
    log "usage: codex-review.sh <task-id> --request <file> --iteration <n>"
    exit 1
fi
if ! printf '%s' "$ITER" | grep -qE '^[0-9]+$'; then
    log "usage: --iteration must be a non-negative integer (got '$ITER')"
    exit 1
fi
if [ ! -f "$REQUEST_FILE" ]; then
    log "request file not found: $REQUEST_FILE"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Validate the request via the ONE validator (subprocess — no duplicate).
if [ ! -x "$REVIEW_CHECK" ] && [ ! -f "$REVIEW_CHECK" ]; then
    log "review-check.sh missing at $REVIEW_CHECK"
    exit 5
fi
VR=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK" validate-request "$REQUEST_FILE" 2>/dev/null || true)
if [ "$(printf '%s' "$VR" | jq -r '.ok // false' 2>/dev/null)" != "true" ]; then
    log "review request failed validation: $(printf '%s' "$VR" | jq -r '.error_key // "unknown"' 2>/dev/null)"
    exit 4
fi

# ---------------------------------------------------------------------------
# 2. Read caps from the ONE config (fail-open to documented defaults).
read_cap() {
    local key="$1" def="$2" val=""
    if [ -f "$REVIEW_CONFIG" ]; then
        val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$REVIEW_CONFIG" 2>/dev/null \
            | head -1 | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" | sed -E 's/[[:space:]]*$//')
    fi
    [ -z "$val" ] && val="$def"
    printf '%s' "$val"
}
MAX_FINDINGS=$(read_cap max_findings 10)
MAX_ITERS=$(read_cap max_review_iterations 3)
TIMEOUT_S=$(read_cap timeout_seconds 300)
MALFORMED_RETRY=$(read_cap malformed_retry 1)
# Numeric sanity (fail-open to defaults on a garbled config line).
printf '%s' "$MAX_FINDINGS" | grep -qE '^[0-9]+$' || MAX_FINDINGS=10
printf '%s' "$MAX_ITERS" | grep -qE '^[0-9]+$' || MAX_ITERS=3
printf '%s' "$TIMEOUT_S" | grep -qE '^[0-9]+$' || TIMEOUT_S=300
printf '%s' "$MALFORMED_RETRY" | grep -qE '^[0-9]+$' || MALFORMED_RETRY=1

# 3. Iteration cap (D-bounded: an iteration above the cap never calls Sol).
if [ "$ITER" -gt "$MAX_ITERS" ]; then
    log "iteration $ITER exceeds max_review_iterations=$MAX_ITERS"
    exit 6
fi

# Request-authoritative fields (forced into the artifact later).
REQ_RT=$(jq -r '.risk_threshold' "$REQUEST_FILE" 2>/dev/null || echo "")
REQ_SC=$(jq -r '.stop_condition' "$REQUEST_FILE" 2>/dev/null || echo "")
REQUEST_RAW=$(cat -- "$REQUEST_FILE" 2>/dev/null)

# ---------------------------------------------------------------------------
# 4. Resolve the server command/args (env override bypasses discovery).
CMD=""
ARGS=()
if [ -n "${CODEX_MCP_BIN:-}" ]; then
    CMD="$CODEX_MCP_BIN"
    __a=""
    # `|| [ -n "$__a" ]` so a final token with no trailing newline is not lost.
    while IFS= read -r __a || [ -n "$__a" ]; do
        [ -n "$__a" ] && ARGS+=("$__a")
        __a=""
    done < <(printf '%s' "${CODEX_MCP_ARGS:-}" | tr ' ' '\n')
else
    if [ ! -f "$USER_CONFIG" ] || ! jq -e '.mcpServers.codex' "$USER_CONFIG" >/dev/null 2>&1; then
        log "no Codex MCP registration in $USER_CONFIG — cannot run Sol"
        exit 5
    fi
    CMD=$(jq -r '.mcpServers.codex.command // empty' "$USER_CONFIG" 2>/dev/null)
    __a=""
    while IFS= read -r __a; do
        ARGS+=("$__a")
    done < <(jq -r '.mcpServers.codex.args[]?' "$USER_CONFIG" 2>/dev/null)
fi
if [ -z "$CMD" ]; then
    log "empty server command — cannot run Sol"
    exit 5
fi

# reviewer_model: env override, else `-m/--model <x>` from the args, else codex.
CODEX_MODEL="${CODEX_MCP_MODEL:-}"
if [ -z "$CODEX_MODEL" ]; then
    __prev=""
    for __x in ${ARGS[@]+"${ARGS[@]}"}; do
        if [ "$__prev" = "-m" ] || [ "$__prev" = "--model" ]; then
            CODEX_MODEL="$__x"; break
        fi
        __prev="$__x"
    done
fi
[ -z "$CODEX_MODEL" ] && CODEX_MODEL="codex"

# ---------------------------------------------------------------------------
# 5. Build the review envelope (advisory instructions + schema + request).
ENVELOPE=$(cat <<EOF
You are Sol, an INDEPENDENT, ADVISORY code reviewer. You NEVER approve, never
apply labels, never modify files or any workflow state. Emit EXACTLY ONE JSON
object as your final message — no surrounding prose, no markdown fences.

Blocking bar: risk_threshold=$REQ_RT on the ordered severity enum
critical>high>medium>low>info. Only findings at or above this bar are blocking.
STOP as soon as the stop_condition is satisfied: $REQ_SC
Report at most $MAX_FINDINGS findings, MOST SEVERE FIRST. Finding ids use the
grammar R$ITER-F<n> (for example R$ITER-F1, R$ITER-F2).

Your final message MUST be a single JSON object of this shape:
{"contract_version":"1","task_id":"$TASK_ID","reviewer_identity":"sol-codex",
 "reviewer_model":"$CODEX_MODEL","reviewed_hash":"<change-set hash from the request>",
 "risk_threshold":"$REQ_RT","stop_condition":"$REQ_SC",
 "verdict":"approve"|"findings",
 "findings":[{"id":"R$ITER-F1","severity":"critical|high|medium|low|info",
              "location":"<path:line>","evidence":"<what you saw>",
              "description":"<why it matters>"}],
 "iterations":$ITER,
 "stopped_by":"verdict"|"stop_condition"|"cap:max_findings"|"cap:max_review_iterations"|"cap:timeout"}

The full review request follows as JSON:
$REQUEST_RAW
EOF
)

# ---------------------------------------------------------------------------
# 6. FIFO JSON-RPC client. One server process; stdin held open via a FIFO so
# the server (which exits on stdin EOF) survives until we have our answers.
WORK=$(mktemp -d -t codex-review.XXXXXX) || { log "mktemp failed"; exit 5; }
FIFO="$WORK/in.fifo"; OUT="$WORK/out.jsonl"; ERR="$WORK/err.log"
SERVER_PID=""
# Invoked indirectly via the EXIT trap below (and after a successful run).
# shellcheck disable=SC2329
cleanup() {
    exec 3>&- 2>/dev/null || true
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
if ! mkfifo "$FIFO" 2>/dev/null; then
    log "mkfifo failed in $WORK"
    exit 5
fi

CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$CMD" ${ARGS[@]+"${ARGS[@]}"} < "$FIFO" > "$OUT" 2> "$ERR" &
SERVER_PID=$!
# Read-write open: never blocks even if the server dies before reading stdin.
exec 3<> "$FIFO"

NOW() { date +%s 2>/dev/null || echo 0; }
START=$(NOW)
DEADLINE=$(( START + TIMEOUT_S ))

server_alive() { [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; }
frame_grep() { grep -E "\"id\"[[:space:]]*:[[:space:]]*$1([^0-9]|\$)" "$OUT" 2>/dev/null | head -1; }
send_frame() { printf '%s\n' "$1" >&3 2>/dev/null || return 1; return 0; }
# wait_id <id> -> 0 got frame | 1 timeout/deadline | 2 server exited
wait_id() {
    local id="$1"
    while :; do
        [ -n "$(frame_grep "$id")" ] && return 0
        [ "$(NOW)" -ge "$DEADLINE" ] && return 1
        if ! server_alive; then
            [ -n "$(frame_grep "$id")" ] && return 0
            return 2
        fi
        sleep 0.2
    done
}

# fail_timeout: kill server, no artifact, exit 5.
fail_no_artifact() {
    log "$1"
    exit 5
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"codex-review","version":"1.0.0"}}}'
send_frame "$INIT" || fail_no_artifact "could not write initialize frame (server gone)"
wait_id 1; rc=$?
[ "$rc" -eq 0 ] || fail_no_artifact "initialize handshake failed/timed out ($(tail -2 "$ERR" 2>/dev/null | tr '\n' ' '))"
send_frame '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true

# extract_final_text <request-id> -> prints stripped candidate text.
extract_text() {
    local resp text
    resp=$(frame_grep "$1")
    text=$(printf '%s' "$resp" | jq -r '.result.content[]? | select(.type=="text") | .text' 2>/dev/null)
    if [ -z "$text" ]; then
        text=$(printf '%s' "$resp" | jq -r '.result.structuredContent.content // empty' 2>/dev/null)
    fi
    # Strip markdown fences; validation requires the message to BE one JSON object.
    printf '%s' "$text" | grep -vE '^[[:space:]]*```' || true
}
extract_thread() {
    frame_grep "$1" | jq -r '.result.structuredContent.threadId // empty' 2>/dev/null || true
}

# validate_candidate <text> -> 0 valid (writes $WORK/valid.json) | 1 invalid
# (writes $WORK/error_key).
validate_candidate() {
    local text="$1"
    printf '%s' "$text" > "$WORK/candidate.json"
    local out
    out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK" validate-artifact "$WORK/candidate.json" 2>/dev/null || true)
    if [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" = "true" ]; then
        cp "$WORK/candidate.json" "$WORK/valid.json"
        return 0
    fi
    printf '%s' "$out" | jq -r '.error_key // "invalid_json"' 2>/dev/null > "$WORK/error_key"
    return 1
}

# The initial codex tool call (read-only sandbox).
CALL=$(jq -nc --arg p "$ENVELOPE" --arg cwd "$PROJECT_DIR" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"codex",arguments:{prompt:$p,sandbox:"read-only",cwd:$cwd}}}')
send_frame "$CALL" || fail_no_artifact "could not write codex tool call (server gone)"
wait_id 2; rc=$?
[ "$rc" -eq 0 ] || fail_no_artifact "codex tool call exceeded ${TIMEOUT_S}s wall-clock budget (or server exited); no artifact"

THREAD=$(extract_thread 2)
CANDIDATE=$(extract_text 2)

VALID_JSON=""
if validate_candidate "$CANDIDATE"; then
    VALID_JSON=$(cat "$WORK/valid.json")
else
    # Up to MALFORMED_RETRY corrective codex-reply turns.
    attempt=0
    reply_id=2
    while [ "$attempt" -lt "$MALFORMED_RETRY" ]; do
        attempt=$(( attempt + 1 ))
        reply_id=$(( reply_id + 1 ))
        ekey=$(cat "$WORK/error_key" 2>/dev/null || echo "invalid_json")
        REPLY=$(jq -nc --argjson id "$reply_id" --arg tid "$THREAD" \
            --arg p "Validation failed: $ekey. Emit ONLY the corrected JSON object — a single JSON object, no prose, no fences." \
            '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:"codex-reply",arguments:{threadId:$tid,prompt:$p}}}')
        send_frame "$REPLY" || break
        wait_id "$reply_id"; rc=$?
        [ "$rc" -eq 0 ] || fail_no_artifact "corrective turn exceeded budget or server exited; no artifact"
        CANDIDATE=$(extract_text "$reply_id")
        if validate_candidate "$CANDIDATE"; then
            VALID_JSON=$(cat "$WORK/valid.json")
            break
        fi
    done
fi

if [ -z "$VALID_JSON" ]; then
    fail_no_artifact "Sol did not produce a valid artifact after $MALFORMED_RETRY corrective turn(s); no artifact"
fi

# We have our answer; tear the server down now (cleanup trap also runs).
exec 3>&- 2>/dev/null || true
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# ---------------------------------------------------------------------------
# 7. Cap-truncate findings, FORCE the authoritative fields, write atomically.
NFIND=$(printf '%s' "$VALID_JSON" | jq '.findings | length' 2>/dev/null || echo 0)
if [ "$NFIND" -gt "$MAX_FINDINGS" ]; then
    VALID_JSON=$(printf '%s' "$VALID_JSON" | jq --argjson n "$MAX_FINDINGS" \
        '.findings |= .[0:$n] | .stopped_by = "cap:max_findings"')
    log "truncated findings $NFIND -> $MAX_FINDINGS (stopped_by=cap:max_findings)"
fi

FINAL=$(printf '%s' "$VALID_JSON" | jq \
    --arg tid "$TASK_ID" \
    --argjson it "$ITER" \
    --arg rt "$REQ_RT" \
    --arg sc "$REQ_SC" \
    --arg model "$CODEX_MODEL" \
    '.task_id=$tid | .iterations=$it | .risk_threshold=$rt | .stop_condition=$sc | .reviewer_identity="sol-codex" | .reviewer_model=$model')

SANITIZED_TID=$(printf '%s' "$TASK_ID" | tr -c 'A-Za-z0-9._-' '_')
ART_FILE="$QA_TRACKING_DIR/review-artifact-$SANITIZED_TID-r$ITER.json"
mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
TMP="$ART_FILE.tmp.$$"
if printf '%s' "$FINAL" | jq . > "$TMP" 2>/dev/null; then
    mv "$TMP" "$ART_FILE"
else
    rm -f "$TMP" 2>/dev/null || true
    fail_no_artifact "failed to assemble the final artifact JSON"
fi

printf '%s\n' "$ART_FILE"
exit 0

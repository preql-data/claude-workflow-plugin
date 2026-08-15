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
#      gone, an unmarshalable tool-call frame, or still-invalid after the
#      malformed-retry corrective turns) — NO artifact is written; the caller
#      degrades to the Claude path
#   6  iteration exceeds the max_review_iterations cap
#   7  the request file exceeds max_request_bytes — refused BEFORE the Codex
#      server is even spawned (claude-workflow-plugin-nq5f). A packet already
#      measured to exhaust the full timeout_seconds budget with no artifact
#      and no diagnosis (144KB, 2026-08-13) is refused loud and fast here
#      instead of silently repeating that 40-minute dead end.
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
artifact to docs/reviews/<task-id>-r<n>.json (claude-workflow-plugin-rqer:
moved from .claude/.qa-tracking/, which is wiped on every completed approve).
Exit: 0 ok | 1 usage | 4 invalid request | 5 no artifact (degrade) | 6 iteration cap
      | 7 request exceeds max_request_bytes (refused before any Sol call).
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
MAX_REQUEST_BYTES=$(read_cap max_request_bytes 100000)
# Numeric sanity (fail-open to defaults on a garbled config line).
printf '%s' "$MAX_FINDINGS" | grep -qE '^[0-9]+$' || MAX_FINDINGS=10
printf '%s' "$MAX_ITERS" | grep -qE '^[0-9]+$' || MAX_ITERS=3
printf '%s' "$TIMEOUT_S" | grep -qE '^[0-9]+$' || TIMEOUT_S=300
printf '%s' "$MALFORMED_RETRY" | grep -qE '^[0-9]+$' || MALFORMED_RETRY=1
printf '%s' "$MAX_REQUEST_BYTES" | grep -qE '^[0-9]+$' || MAX_REQUEST_BYTES=100000

# PACKET-BUDGET BEGIN (claude-workflow-plugin-nq5f)
#
# REFUSE AN OVER-BUDGET PACKET NOW, before mkfifo, before spawning the Codex
# server, before anything that costs real wall-clock time. Two points are
# MEASURED (recorded on claude-workflow-plugin-nq5f, 2026-08-13): a ~88KB
# request completed in 326-635s across five rounds; a ~144KB request EXHAUSTED
# the full timeout_seconds budget (2400s) and produced no artifact and no
# diagnosis at all. The two points are NOT linear (a 1.6x size increase did not
# cost 1.6x the time — it cost the entire budget), and two points cannot be
# interpolated or extrapolated into a curve regardless — a third measurement
# would be the minimum for that, and it does not exist yet. max_request_bytes
# is CHOSEN between the two, rounded for legibility and closer to the
# confirmed-good side than the confirmed-bad one: a JUDGMENT CALL, not a
# derivation, expected to move once a third measurement exists to reason from.
# It errs low on purpose — a refusal here is a CHEAP wrong answer (rescope the
# request smaller, re-run, seconds lost); a 2400s timeout is an EXPENSIVE one
# (40 minutes of nothing). That cost asymmetry, not the measurement, is why the
# bound sits toward the cheap side of the 88KB-144KB range rather than its
# middle.
#
# byte size of the REQUEST FILE alone, not the assembled envelope (step 5,
# below) — the request is what a caller (qa.md 6p.1, and D2's larger future
# packet) actually controls the size of, and checking it here means refusing
# before any per-call work happens at all, matching "at assembly time" rather
# than "after we already started".
REQUEST_BYTES=$(wc -c < "$REQUEST_FILE" 2>/dev/null | tr -d '[:space:]')
[ -n "$REQUEST_BYTES" ] || REQUEST_BYTES=0
if [ "$REQUEST_BYTES" -gt "$MAX_REQUEST_BYTES" ]; then
    log "request file is ${REQUEST_BYTES} bytes, exceeding max_request_bytes=${MAX_REQUEST_BYTES} — refusing before any Sol call is attempted (a packet this size has previously exhausted the full timeout_seconds budget with no artifact and no diagnosis; scope the request smaller, e.g. one file's diff rather than the whole change set, and re-run)"
    exit 7
fi
# PACKET-BUDGET END (claude-workflow-plugin-nq5f)

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
 "reviewer_model":"$CODEX_MODEL","reviewer_pin":"$CODEX_MODEL","reviewed_hash":"<change-set hash from the request>",
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

# wait_fail_reason <rc> <label> <id> — the human-facing text for a wait_id
# failure, DISAMBIGUATING the two ways it fails (claude-workflow-plugin-
# fkm.1.14): rc=1 means the DEADLINE was reached while the server was still
# alive — Sol was still generating, this IS a timeout. rc=2 means the server
# PROCESS EXITED before answering — this is NOT a timeout, the turn ended
# abnormally. Conflating them in one message ("exceeded budget (or server
# exited)") made a stalled call and a crashed server indistinguishable after
# the fact, and the two need different follow-ups: a timeout says "scope the
# packet smaller or accept the wait"; a server exit says "look at $ERR / the
# Codex installation", not "wait longer next time".
wait_fail_reason() {
    local rc="$1" label="$2" id="$3"
    case "$rc" in
        1) printf '%s exceeded the %ss wall-clock budget — the server was STILL ALIVE at the deadline (id=%s never answered; Sol was still generating); no artifact' \
            "$label" "$TIMEOUT_S" "$id" ;;
        2) printf '%s: the server process EXITED before answering (id=%s never got a reply) — NOT a timeout, the turn ended abnormally; no artifact' \
            "$label" "$id" ;;
        *) printf '%s failed for an unrecognised reason (wait_id rc=%s, id=%s); no artifact' \
            "$label" "$rc" "$id" ;;
    esac
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"codex-review","version":"1.0.0"}}}'
send_frame "$INIT" || fail_no_artifact "could not write initialize frame (server gone)"
wait_id 1; rc=$?
[ "$rc" -eq 0 ] || fail_no_artifact "$(wait_fail_reason "$rc" "initialize handshake" 1) ($(tail -2 "$ERR" 2>/dev/null | tr '\n' ' '))"
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
#
# The envelope reaches jq BY FILE, never through argv (claude-workflow-plugin-
# fkm.1.12). `--arg p "$ENVELOPE"` puts the ENTIRE review request on the jq
# command line, so any change set whose assembled envelope exceeds the platform's
# argv limit kills the exec with E2BIG. Measured on macOS 26.3 (Darwin 25.3),
# `getconf ARG_MAX`=1048576: a 1568552-byte review request — 1.5x the limit before
# the instruction header is even prepended — left $CALL EMPTY with the
# assignment's status at 126. Linux is stricter still: it caps a SINGLE argument
# at MAX_ARG_STRLEN (32 pages, typically 131072 bytes) far below its larger
# ARG_MAX. `--rawfile` reads the same bytes off disk and is byte-identical to
# `--arg` for the same string (verified on payloads containing quotes,
# backslashes and tabs), so the lane no longer has a size ceiling on either
# platform. Do NOT "fix" this by refusing oversize envelopes up front — that
# would reinstate the ceiling this removes. $WORK is a mode-0700 mktemp dir
# removed by the EXIT trap, so the envelope (which embeds the full change-set
# diff) neither leaks to other users nor outlives the run.
#
# THIS IS NOT IN TENSION WITH THE max_request_bytes CHECK FURTHER UP (nq5f).
# That check refuses on a MEASURED wall-clock-completion budget — a packet size
# that has been observed to exhaust the ENTIRE timeout_seconds budget with no
# artifact and no diagnosis — which is a fact about how long SOL takes to
# process a prompt, and --rawfile does nothing to change that. The rule above
# is about not reinstating an ARGV/TRANSPORT ceiling now that one doesn't
# exist; the two are different axes and C6/C9 in the component spec each
# isolate their own by raising the OTHER cap out of the way.
#
# CONSEQUENCE FOR ERROR MESSAGES, and it is a rule rather than a preference
# (QA finding R2-F4): NO operator-facing message may cite $ENVELOPE_FILE or any
# other path under $WORK. fail_no_artifact exits, `trap cleanup EXIT` fires on
# that same exit, and `rm -rf "$WORK"` runs before the operator has finished
# reading the line — so a message naming the path sends them to look at something
# that is guaranteed not to exist. Put the diagnostic VALUE in the message
# (byte counts, exit codes, which precondition failed) and leave the path out.
# Inlining a file's CONTENT is fine and is the sanctioned form — see the
# initialize failure, which reads `tail -2 "$ERR"` into its own message.
#
# ONE PRE-EXISTING INSTANCE REMAINS, named so this rule is not read as already
# satisfied everywhere: `log "mkfifo failed in $WORK"` above. It is not touched
# here because it belongs to the larger trap-destroys-its-own-diagnostics gap
# (validate_candidate's candidate.json and error_key, and $ERR on the final
# failure) tracked at claude-workflow-plugin-fkm.1.14, which needs its own
# round. Do not add a fourth instance while waiting for that one.
ENVELOPE_FILE="$WORK/envelope.txt"
if ! printf '%s' "$ENVELOPE" > "$ENVELOPE_FILE" 2>/dev/null || [ ! -s "$ENVELOPE_FILE" ]; then
    fail_no_artifact "could not stage the review envelope for jq --rawfile: this run's temp dir is not writable, or the assembled envelope was empty; nothing was sent, no artifact"
fi
ENVELOPE_BYTES=$(wc -c < "$ENVELOPE_FILE" 2>/dev/null | tr -d '[:space:]')
[ -n "$ENVELOPE_BYTES" ] || ENVELOPE_BYTES="unknown"

CALL=$(jq -nc --rawfile p "$ENVELOPE_FILE" --arg cwd "$PROJECT_DIR" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"codex",arguments:{prompt:$p,sandbox:"read-only",cwd:$cwd}}}')
CALL_RC=$?

# FRAME-GUARD BEGIN (claude-workflow-plugin-fkm.1.12)
# An unbuildable frame must fail LOUD and NOW.
#
# send_frame CANNOT detect this on its own: `printf '%s\n' "" >&3` returns 0, so
# the `|| fail_no_artifact` below never fires on an empty $CALL. The server then
# skips the blank line (a JSON-RPC reader has nothing to parse), no id=2 reply
# ever arrives, and `wait_id 2` burns the ENTIRE timeout_seconds budget waiting
# for a request that was never sent — measured at 45 minutes of dead wait
# presenting as a paid review in progress, with an idle server holding stdin.
# Asserting non-empty AND parseable turns that into an immediate named error.
# Exit 5 (via fail_no_artifact) is the right contract slot: the request itself is
# schema-valid (it already cleared review-check.sh, which has no size cap), the
# invocation is well-formed (not 1), the iteration is in-cap (not 6), and no
# artifact is written — so the caller's move is exactly the documented exit-5
# move in orchestrator.md 5c Step D, degrade to the Claude lane. Retrying the
# paid call would fail identically and deterministically.
#
# The sentinels are load-bearing: the META leg of the codex-review component spec
# excises exactly this block to prove the guard is what converts the hang into a
# fast named failure. Keep them if you move the block.
if [ "$CALL_RC" -ne 0 ] || [ -z "$CALL" ] || ! printf '%s' "$CALL" | jq -e . >/dev/null 2>&1; then
    fail_no_artifact "could not marshal the codex tool call — frame is empty or not valid JSON (jq rc=$CALL_RC, envelope $ENVELOPE_BYTES bytes); nothing was sent, no artifact"
fi
# FRAME-GUARD END (claude-workflow-plugin-fkm.1.12)
send_frame "$CALL" || fail_no_artifact "could not write codex tool call (server gone)"
wait_id 2; rc=$?
[ "$rc" -eq 0 ] || fail_no_artifact "$(wait_fail_reason "$rc" "codex tool call" 2)"

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
        [ "$rc" -eq 0 ] || fail_no_artifact "$(wait_fail_reason "$rc" "corrective turn" "$reply_id")"
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

# reviewer_pin (claude-workflow-plugin-46w9) is FORCED to the same value as
# reviewer_model, for the same reason reviewer_model itself is forced rather
# than trusted from Sol's own output: there is no frontmatter-vs-self-report
# split for a config-driven, non-introspective transport like Sol (unlike a
# Claude-based agent, which HAS its own `model:` frontmatter to compare
# itself against) — $CODEX_MODEL is the only model-identity fact available
# either way, so recording it under both names is accurate rather than
# manufacturing a divergence signal that does not exist for this lane.
FINAL=$(printf '%s' "$VALID_JSON" | jq \
    --arg tid "$TASK_ID" \
    --argjson it "$ITER" \
    --arg rt "$REQ_RT" \
    --arg sc "$REQ_SC" \
    --arg model "$CODEX_MODEL" \
    '.task_id=$tid | .iterations=$it | .risk_threshold=$rt | .stop_condition=$sc | .reviewer_identity="sol-codex" | .reviewer_model=$model | .reviewer_pin=$model')

SANITIZED_TID=$(printf '%s' "$TASK_ID" | tr -c 'A-Za-z0-9._-' '_')
# CANONICAL PATH (claude-workflow-plugin-rqer / v5 D2): the review artifact's
# durable home is docs/reviews/, NOT .claude/.qa-tracking/ — the latter is
# wiped by qa-gate.sh's wipe_review_artifacts on every completed approve
# (deliberately, per its header) and excluded from the change set by
# workflow_self_written (workflow-denylist.sh:265), so an artifact written
# there never outlived a review cycle and no approval ever attested to it.
# This format string MUST match qa-gate.sh's review_artifact_path_for byte
# for byte — the two are pinned against drift by
# .claude/tests/component/specs/codex-review.sh's art_path() helper, which
# independently re-derives this same path and asserts a file does/does not
# exist there across the C1-C9 legs (R1-F3: review-artifact-durability.sh's
# Leg A drives the CLAUDE lane through qa-gate.sh review-record over stdin
# and never invokes this driver at all, so it cannot pin this driver's own
# path computation — corrected here after QA round 1 named both this
# comment and qa-gate.sh's review_artifact_path_for header for citing it).
ART_FILE="$PROJECT_DIR/docs/reviews/$SANITIZED_TID-r$ITER.json"
if ! mkdir -p "$(dirname "$ART_FILE")" 2>/dev/null; then
    fail_no_artifact "could not create the review artifact directory at $(dirname "$ART_FILE"); no artifact"
fi
TMP="$ART_FILE.tmp.$$"
if ! printf '%s' "$FINAL" | jq . > "$TMP" 2>/dev/null; then
    rm -f "$TMP" 2>/dev/null || true
    fail_no_artifact "failed to assemble the final artifact JSON"
fi
# CHECKED mv, ROUND 2 (claude-workflow-plugin-rqer, QA round-1 R1-F1). The
# round-1 version of this comment claimed an exit-status check on `mv` alone
# closed the pre-existing-directory shape below. IT DID NOT, and structurally
# could not: POSIX mv renames INTO an existing directory rather than
# replacing it, so `mv "$TMP" "$ART_FILE"` returns rc=0 when $ART_FILE
# already exists as a directory — reproduced against THIS shipped driver
# with a stub server: a directory pre-placed at the derived path made the
# driver exit 0, print the canonical path on stdout, and strand the
# assembled JSON at "$ART_FILE/$(basename "$TMP")" instead of at $ART_FILE
# itself. mv is not lying about its own result in that shape; the result is
# just not the one this script needs, which is exactly why a bare exit-status
# check cannot see it. qa-gate.sh's cmd_review_record already refuses this
# same shape downstream (its artifact_path_is_directory check) before it
# ever writes — that is the in-repo precedent mirrored below, applied here
# where the bytes are actually produced rather than only where they are
# later read back.
#
# Refuse BEFORE attempting the move, so no stray file is ever created inside
# the directory, and reconfirm AFTER the move that a regular file actually
# landed at $ART_FILE. Two checks, not one: the pre-check avoids littering
# the directory on the KNOWN shape; the post-check is the general proof that
# a file exists, which also covers a same-instant race between the pre-check
# and the move. What the plain `! mv ...` branch below still catches, and
# ALL it now claims to catch, is a full disk or a permissions error mid-move
# — the scope this round's own completion record already stated accurately;
# only this comment previously overclaimed the directory shape too.
# DIR-SHAPE-GUARD BEGIN (claude-workflow-plugin-rqer)
if [ -d "$ART_FILE" ]; then
    rm -f "$TMP" 2>/dev/null || true
    fail_no_artifact "the derived artifact path $ART_FILE already exists as a directory; refusing to move the assembled artifact there rather than have mv silently rename it INTO the directory; no artifact"
fi
# DIR-SHAPE-GUARD END (claude-workflow-plugin-rqer)
if ! mv "$TMP" "$ART_FILE" 2>/dev/null; then
    rm -f "$TMP" 2>/dev/null || true
    fail_no_artifact "could not move the assembled artifact into place at $ART_FILE (disk full or a permissions error); no artifact"
fi
# POST-MOVE-GUARD BEGIN (claude-workflow-plugin-rqer)
if [ ! -f "$ART_FILE" ]; then
    fail_no_artifact "the move to $ART_FILE reported success but no regular file exists there afterward; no artifact"
fi
# POST-MOVE-GUARD END (claude-workflow-plugin-rqer)

printf '%s\n' "$ART_FILE"
exit 0

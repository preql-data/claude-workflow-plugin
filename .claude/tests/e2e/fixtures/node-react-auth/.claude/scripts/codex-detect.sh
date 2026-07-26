#!/bin/bash
# codex-detect.sh — reviewer-lane detection for the optional Sol (Codex)
# review path (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# WHY THIS EXISTS: Sol is an ADVISORY, STRICTLY OPTIONAL second reviewer
# reachable over the Codex MCP server. The workflow must behave IDENTICALLY
# whether or not that server is present — so lane selection has to be a
# truthful, bounded, fail-open probe that ALWAYS resolves to a lane and
# NEVER blocks the session. Absence, misconfiguration, a crash, a hang, or a
# server that speaks MCP but exposes no `codex` tool ALL resolve to
# lane=claude (identical to "not connected").
#
# Layered detection (always exits 0):
#   (a) fast path — the common teammate case: read the Codex MCP registration
#       via `jq .mcpServers.codex` from ${CODEX_USER_CONFIG:-$HOME/.claude.json}.
#       Absent  => lane=claude, method=config-absent (~0s, no process spawned).
#   (b) truthful handshake — present (or a CODEX_MCP_BIN override): spawn the
#       registered command, drive a line-delimited JSON-RPC `initialize` then
#       `tools/list`, and REQUIRE a tool literally named `codex` within
#       ${CODEX_DETECT_TIMEOUT_S:-5} seconds. Any failure/timeout/missing tool
#       => lane=claude with a method naming the failure. The spawned server is
#       ALWAYS killed. We NEVER invoke the `codex` tool itself (that would hit
#       OpenAI); tools/list only.
#
# Subcommands:
#   detect [--refresh]   Run detection, write reviewer-lane.json atomically,
#                        print the resolved lane word (codex|claude) on stdout.
#                        The no-arg form is an alias for `detect`, so the
#                        dormant seam in model-select.sh's detect_reviewer_lane
#                        (`bash codex-detect.sh` — no args, reads stdout) gets a
#                        live lane. --refresh forces a re-probe (detection is
#                        already stateless, so it behaves the same; the flag
#                        exists for CLI symmetry with model-select.sh).
#   status               Print .claude/.qa-tracking/reviewer-lane.json, or the
#                        literal `claude/no-flag` when no detection has run.
#
# Test/override seams (mirror impact-report.sh's CODE_GRAPH_MCP_BIN pattern):
#   CODEX_USER_CONFIG      registration source (default $HOME/.claude.json)
#   CODEX_MCP_BIN          override the server command (bypasses fast-path
#                          discovery — used by the stub in tests)
#   CODEX_MCP_ARGS         space-delimited args for the override command
#   CODEX_DETECT_TIMEOUT_S handshake budget (default 5)
#
# reviewer-lane.json shape (atomic write):
#   {"reviewer_lane":"codex"|"claude",
#    "method":"handshake|config-absent|handshake-failed|timeout|no-codex-tool",
#    "codex_cmd":"<command>", "codex_args":[...], "detected_at":"<iso-8601>"}
#
# NOTE: this script never references the QA gate, verify-before-stop, or the
# release credential. Lane selection is prompt-side + statusline only.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
LANE_FILE="$QA_TRACKING_DIR/reviewer-lane.json"
USER_CONFIG="${CODEX_USER_CONFIG:-$HOME/.claude.json}"
DETECT_TIMEOUT_S="${CODEX_DETECT_TIMEOUT_S:-5}"

# Writes to a FIFO whose reader has gone must fail with a non-zero rc, not
# terminate the script (default SIGPIPE action kills the shell).
trap '' PIPE

log() { printf '[codex-detect] %s\n' "$1" >&2; }

# write_lane_file <lane> <method> <cmd> <args-json>
# Atomic (tmp + mv); best-effort (a write failure must not change the lane
# the caller already resolved on stdout).
write_lane_file() {
    local lane="$1" method="$2" cmd="$3" args="${4:-[]}"
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    local ts tmp
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    tmp="$LANE_FILE.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        if jq -n --arg lane "$lane" --arg method "$method" --arg cmd "$cmd" \
            --argjson args "$args" --arg ts "$ts" \
            '{reviewer_lane:$lane, method:$method, codex_cmd:$cmd, codex_args:$args, detected_at:$ts}' \
            > "$tmp" 2>/dev/null; then
            mv "$tmp" "$LANE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
        else
            rm -f "$tmp" 2>/dev/null || true
        fi
    else
        # jq-less fallback: emit a minimal valid object (no args array).
        if printf '{"reviewer_lane":"%s","method":"%s","codex_cmd":"%s","codex_args":[],"detected_at":"%s"}\n' \
            "$lane" "$method" "$cmd" "$ts" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$LANE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
        else
            rm -f "$tmp" 2>/dev/null || true
        fi
    fi
}

# handshake <cmd> <args-json> — spawn the server, run initialize + tools/list,
# and echo one of: handshake | handshake-failed | timeout | no-codex-tool.
# The server is always reaped. Never invokes the `codex` tool.
handshake() {
    local cmd="$1" args_json="$2"

    # The command must be resolvable — a bare name on PATH or an executable
    # path. (A registered `node` resolves on PATH; a stub path is executable.)
    if ! command -v "$cmd" >/dev/null 2>&1 && [ ! -x "$cmd" ]; then
        printf 'handshake-failed'
        return 0
    fi

    # Materialise the args array (bash 3.2 + set -u safe).
    local args=()
    local __a
    while IFS= read -r __a; do
        args+=("$__a")
    done < <(printf '%s' "$args_json" | jq -r '.[]?' 2>/dev/null)

    local work fifo out err
    work=$(mktemp -d -t codex-detect.XXXXXX 2>/dev/null) || { printf 'handshake-failed'; return 0; }
    fifo="$work/in.fifo"; out="$work/out.jsonl"; err="$work/err.log"
    if ! mkfifo "$fifo" 2>/dev/null; then
        rm -rf "$work" 2>/dev/null || true
        printf 'handshake-failed'
        return 0
    fi

    # Wrapper subshell: it OWNS (and reaps) the server child, then drops an
    # rc marker the moment the server exits. This is the liveness signal —
    # polling `kill -0` on a not-yet-waited background child would keep
    # succeeding on a zombie and misclassify a crash as a timeout.
    rm -f "$work/rc" "$work/srv.pid" 2>/dev/null || true
    (
        "$cmd" ${args[@]+"${args[@]}"} < "$fifo" > "$out" 2> "$err" &
        __srv=$!
        printf '%s' "$__srv" > "$work/srv.pid"
        wait "$__srv" 2>/dev/null
        printf 'done' > "$work/rc"
    ) &
    local wrap_pid=$!

    # Read-write open so a server that crashes BEFORE opening its stdin can't
    # block us forever on the open (a write-only open would wait for a reader).
    exec 3<> "$fifo"

    local now deadline result
    now=$(date +%s 2>/dev/null || echo 0)
    deadline=$(( now + DETECT_TIMEOUT_S ))

    _hs_now() { date +%s 2>/dev/null || echo 0; }
    _hs_alive() { [ ! -f "$work/rc" ]; }
    _hs_frame() { grep -E "\"id\"[[:space:]]*:[[:space:]]*$1([^0-9]|\$)" "$out" 2>/dev/null | head -1; }
    # wait_id <id> -> 0 got frame | 1 timeout | 2 server exited
    _hs_wait() {
        local id="$1"
        while :; do
            [ -n "$(_hs_frame "$id")" ] && return 0
            [ "$(_hs_now)" -ge "$deadline" ] && return 1
            if ! _hs_alive; then
                [ -n "$(_hs_frame "$id")" ] && return 0
                return 2
            fi
            sleep 0.1
        done
    }

    result="handshake-failed"
    local rc
    if printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"codex-detect","version":"1.0.0"}}}' >&3 2>/dev/null; then
        _hs_wait 1; rc=$?
        if [ "$rc" -eq 1 ]; then
            result="timeout"
        elif [ "$rc" -eq 2 ]; then
            result="handshake-failed"
        else
            printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&3 2>/dev/null || true
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' >&3 2>/dev/null || true
            _hs_wait 2; rc=$?
            if [ "$rc" -eq 1 ]; then
                result="timeout"
            elif [ "$rc" -eq 2 ]; then
                result="handshake-failed"
            else
                if _hs_frame 2 | jq -e '.result.tools[]? | select(.name == "codex")' >/dev/null 2>&1; then
                    result="handshake"
                else
                    result="no-codex-tool"
                fi
            fi
        fi
    fi

    # Teardown: close our FIFO end, kill the server + wrapper, reap, cleanup.
    exec 3>&- 2>/dev/null || true
    local sp
    sp=$(cat "$work/srv.pid" 2>/dev/null || true)
    [ -n "${sp:-}" ] && kill "$sp" 2>/dev/null || true
    kill "$wrap_pid" 2>/dev/null || true
    wait "$wrap_pid" 2>/dev/null || true
    rm -rf "$work" 2>/dev/null || true

    printf '%s' "$result"
    return 0
}

# do_detect — layered resolution; writes reviewer-lane.json; prints the lane.
do_detect() {
    local cmd="" args_json="[]" method lane

    if ! command -v jq >/dev/null 2>&1; then
        # No jq: cannot parse a registration; the safe, identical-to-absent
        # resolution is claude.
        write_lane_file "claude" "config-absent" "" "[]"
        printf 'claude\n'
        return 0
    fi

    if [ -n "${CODEX_MCP_BIN:-}" ]; then
        # Override seam (tests / non-standard installs): use the given command
        # directly and skip fast-path discovery. Mirrors CODE_GRAPH_MCP_BIN.
        cmd="$CODEX_MCP_BIN"
        args_json=$(printf '%s' "${CODEX_MCP_ARGS:-}" | jq -Rc 'split(" ") | map(select(length > 0))' 2>/dev/null || printf '[]')
    else
        # Fast path: the registration must exist.
        if [ ! -f "$USER_CONFIG" ] || ! jq -e '.mcpServers.codex' "$USER_CONFIG" >/dev/null 2>&1; then
            write_lane_file "claude" "config-absent" "" "[]"
            printf 'claude\n'
            return 0
        fi
        cmd=$(jq -r '.mcpServers.codex.command // empty' "$USER_CONFIG" 2>/dev/null || printf '')
        args_json=$(jq -c '.mcpServers.codex.args // []' "$USER_CONFIG" 2>/dev/null || printf '[]')
        if [ -z "$cmd" ]; then
            # Registered but no runnable command — identical-to-absent.
            write_lane_file "claude" "config-absent" "" "[]"
            printf 'claude\n'
            return 0
        fi
    fi

    method=$(handshake "$cmd" "$args_json")
    if [ "$method" = "handshake" ]; then
        lane="codex"
    else
        lane="claude"
    fi
    write_lane_file "$lane" "$method" "$cmd" "$args_json"
    printf '%s\n' "$lane"
    return 0
}

cmd_status() {
    if [ -f "$LANE_FILE" ]; then
        cat "$LANE_FILE"
    else
        printf 'claude/no-flag\n'
    fi
}

usage() {
    cat >&2 <<'USAGE'
Usage: codex-detect.sh [detect [--refresh] | status]
  detect [--refresh]  Probe the optional Codex MCP server and resolve the
                      reviewer lane (codex|claude). Writes reviewer-lane.json
                      and prints the lane word. No-arg is an alias for detect.
  status              Print reviewer-lane.json (or 'claude/no-flag').
Always exits 0 (fail-open; absence/failure/timeout == lane=claude).
USAGE
}

SUB="${1:-}"
case "$SUB" in
    status)
        cmd_status
        ;;
    -h|--help)
        usage
        ;;
    detect|--refresh|"")
        do_detect
        ;;
    *)
        log "unknown subcommand '$SUB'; treating as detect"
        do_detect
        ;;
esac

exit 0

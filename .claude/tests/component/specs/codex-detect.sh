#!/bin/bash
# codex-detect.sh — L2 component spec for the reviewer-lane probe
# (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# codex-detect.sh is the truthful, bounded, fail-open probe that resolves the
# optional Sol (Codex) reviewer lane. Sol is ADVISORY: absence, failure,
# timeout, and a server-without-a-codex-tool ALL resolve to lane=claude
# (identical to "not connected"). This spec drives the probe against a
# RECORDING stub MCP server (real JSON-RPC over stdio) in each degradation mode
# and proves:
#   D1  config-absent            -> claude / config-absent (no process spawned)
#   D2  healthy handshake        -> codex  / handshake
#   D3  hung server (no answer)  -> claude / timeout       (bounded)
#   D4  crashing server          -> claude / handshake-failed
#   D5  server without codex tool-> claude / no-codex-tool  (META lookalike)
#   D6  --refresh re-probes and rewrites reviewer-lane.json
#   D7  the model-select seam (detect_reviewer_lane) follows the probe, and the
#       resolved reviewer_lane drives the statusline reviewer segment to `sol`.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

DETECT="$FIXTURE/.claude/scripts/codex-detect.sh"
LANE_FILE="$FIXTURE/.claude/.qa-tracking/reviewer-lane.json"
STUB="$(plugin_root)/.claude/tests/component/lib/stub-codex-mcp.js"

if ! command -v node >/dev/null 2>&1; then
    printf 'SKIPPED: codex-detect.sh spec (node not on PATH)\n'
    # Nothing to assert without node; leave PASS/FAIL at 0 so the runner
    # records a clean skip (mirrors the code-graph-mcp spec convention).
    return 0 2>/dev/null || exit 0
fi

# lane_of / method_of read the atomically-written artifact.
lane_of() { jq -r '.reviewer_lane // ""' "$LANE_FILE" 2>/dev/null || echo ""; }
method_of() { jq -r '.method // ""' "$LANE_FILE" 2>/dev/null || echo ""; }

# run_detect — invoke `codex-detect.sh detect` with the given STUB_MODE via the
# CODEX_MCP_BIN/ARGS override seam. Echoes the printed lane word.
run_detect() {
    local mode="$1" timeout_s="${2:-5}"
    CODEX_MCP_BIN=node CODEX_MCP_ARGS="$STUB" STUB_MODE="$mode" \
        CODEX_DETECT_TIMEOUT_S="$timeout_s" \
        bash "$DETECT" detect 2>/dev/null
}

# ---------------------------------------------------------------------------
# D1: config-absent (mk_fixture pins CODEX_USER_CONFIG to a nonexistent path).
rm -f "$LANE_FILE"
LANE=$(bash "$DETECT" detect 2>/dev/null)
assert_eq "D1 config-absent: prints claude" "claude" "$LANE"
assert_eq "D1 config-absent: lane file lane=claude" "claude" "$(lane_of)"
assert_eq "D1 config-absent: method=config-absent" "config-absent" "$(method_of)"
assert_eq "D1 config-absent: exit 0" "0" "$([ -f "$LANE_FILE" ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# D2: healthy handshake -> codex.
rm -f "$LANE_FILE"
LANE=$(run_detect ok)
assert_eq "D2 handshake ok: prints codex" "codex" "$LANE"
assert_eq "D2 handshake ok: method=handshake" "handshake" "$(method_of)"
assert_eq "D2 handshake ok: codex_cmd recorded" "node" "$(jq -r '.codex_cmd' "$LANE_FILE" 2>/dev/null)"

# ---------------------------------------------------------------------------
# D3: hung server (reads but never answers) -> timeout -> claude, bounded.
rm -f "$LANE_FILE"
T0=$(date +%s)
LANE=$(run_detect hang 2)
T1=$(date +%s)
assert_eq "D3 hung server: prints claude" "claude" "$LANE"
assert_eq "D3 hung server: method=timeout" "timeout" "$(method_of)"
assert_eq "D3 hung server: bounded (< 6s for a 2s budget)" "1" \
    "$([ "$((T1 - T0))" -lt 6 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# D4: crashing server (exits immediately) -> handshake-failed -> claude.
rm -f "$LANE_FILE"
LANE=$(run_detect crash)
assert_eq "D4 crashing server: prints claude" "claude" "$LANE"
assert_eq "D4 crashing server: method=handshake-failed" "handshake-failed" "$(method_of)"

# ---------------------------------------------------------------------------
# D5 (META): a server that speaks MCP but exposes NO `codex` tool must NOT be
# mistaken for Sol. Proves the probe verifies the tool literally, not merely a
# successful handshake.
rm -f "$LANE_FILE"
LANE=$(run_detect no-codex-tool)
assert_eq "D5 no-codex-tool: prints claude" "claude" "$LANE"
assert_eq "D5 no-codex-tool: method=no-codex-tool" "no-codex-tool" "$(method_of)"

# ---------------------------------------------------------------------------
# D6: --refresh re-probes and rewrites the artifact. Seed a codex result, then
# --refresh against a crashing server and confirm the file now reflects the new
# (failed) probe.
rm -f "$LANE_FILE"
run_detect ok >/dev/null
assert_eq "D6 pre-refresh: lane=codex" "codex" "$(lane_of)"
CODEX_MCP_BIN=node CODEX_MCP_ARGS="$STUB" STUB_MODE=crash CODEX_DETECT_TIMEOUT_S=5 \
    bash "$DETECT" detect --refresh >/dev/null 2>&1
assert_eq "D6 --refresh rewrites: lane now claude" "claude" "$(lane_of)"
assert_eq "D6 --refresh rewrites: method now handshake-failed" "handshake-failed" "$(method_of)"

# status prints the artifact; with no file it prints the no-flag sentinel.
STATUS_OUT=$(bash "$DETECT" status 2>/dev/null)
assert_contains "D6 status prints the artifact json" "reviewer_lane" "$STATUS_OUT"
rm -f "$LANE_FILE"
STATUS_NOFILE=$(bash "$DETECT" status 2>/dev/null)
assert_eq "D6 status with no file prints claude/no-flag" "claude/no-flag" "$STATUS_NOFILE"

# ---------------------------------------------------------------------------
# D7: the model-select seam follows the probe, and the statusline renders `sol`.
# reviewer_lane=auto in model-roles routes detect_reviewer_lane to codex-detect;
# with the stub override it resolves codex, so `model-select.sh status` reports
# the codex lane and the statusline reviewer segment collapses to `sol`.
MS="$FIXTURE/.claude/scripts/model-select.sh"
SL="$FIXTURE/.claude/scripts/statusline.sh"
printf 'orchestrator=top\nimplementer=opus-class\nreviewer=top\nreviewer_lane=auto\n' \
    > "$FIXTURE/.claude/model-roles"

SEAM_LANE=$(CODEX_MCP_BIN=node CODEX_MCP_ARGS="$STUB" STUB_MODE=ok \
    bash "$MS" status 2>/dev/null | grep '^reviewer lane:' | sed -E 's/^reviewer lane:[[:space:]]*//')
assert_eq "D7 seam: model-select detect_reviewer_lane follows codex-detect -> codex" \
    "codex" "$SEAM_LANE"

# The resolved artifact (lane=codex) drives the statusline reviewer segment to
# the literal `sol` (this is the visible outcome the operator sees).
printf '{"roles":{"orchestrator":"claude-opus-4-8","implementer":"claude-opus-4-8","reviewer":"claude-opus-4-8"},"reviewer_lane":"codex"}' \
    > "$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json"
STATUSLINE=$(printf '{}' | bash "$SL" 2>/dev/null)
assert_contains "D7 statusline renders the reviewer lane as sol" "rev:sol" "$STATUSLINE"
assert_not_contains "D7 lane=codex is NOT collapsed to a single model" "• model:" "$STATUSLINE"

# D7 SENSITIVITY: the negative guard above is only meaningful if the forbidden
# needle is actually observable in the collapsed shape. Positive control — the
# SAME all-equal role mapping with lane=claude DOES collapse to `• model:`. So
# the guard discriminates lane=codex from lane=claude rather than passing
# because the needle can never appear. (This pairing exists because the guard
# previously called an UNDEFINED helper and was a silent no-op — a vacuous
# assertion that never ran; see assert_not_contains in lib/assert.sh.)
printf '{"roles":{"orchestrator":"claude-opus-4-8","implementer":"claude-opus-4-8","reviewer":"claude-opus-4-8"},"reviewer_lane":"claude"}' \
    > "$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json"
STATUSLINE_CLAUDE=$(printf '{}' | bash "$SL" 2>/dev/null)
assert_contains "D7 sensitivity: the same mapping with lane=claude DOES collapse to '• model:'" \
    "• model:" "$STATUSLINE_CLAUDE"
assert_not_contains "D7 sensitivity: the collapsed (lane=claude) render carries no rev:sol" \
    "rev:sol" "$STATUSLINE_CLAUDE"

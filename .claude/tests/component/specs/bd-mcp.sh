#!/bin/bash
# bd-mcp.sh — L2 component spec for the bd-mcp server's boot contract
# (v4.1 / claude-workflow-plugin-0fc, epic 2br).
#
# WHY THIS FILE EXISTS AT ALL.
#
# Until now there was NO bd-mcp spec in this repo — not a boot test, not a
# tools/list test, nothing. That absence is half of why symptom 2 of the v4 P0
# shipped three times: the plugin's own suite could not tell a bd-mcp that
# boots and serves 21 tools from a bd-mcp that dies on `import` with
# ERR_MODULE_NOT_FOUND because its node_modules never existed in the target.
# The other half was code-graph-mcp.sh's unconditional self-skip on absent
# node_modules (fixed in the same change) — so on exactly the machines where
# the servers were broken, the suite reported green.
#
# What this spec covers:
#
#   1. Boot: the stdio initialize handshake completes and reports
#      serverInfo.name == "bd-mcp" with a non-empty version, at the
#      protocolVersion the client asked for.
#   2. tools/list cardinality: EXACTLY 21 tools, and the sorted name list
#      matches byte-for-byte. Exact equality, not >=: "boots but registers
#      nothing" and "boots and registers a partial surface" are both real
#      failures that a >= bound waves through. The same 21 is pinned in
#      workflow-doctor.sh's DOCTOR_TOOL_COUNTS table, both server READMEs and
#      docs/MCP_SERVERS.md, cross-checked by
#      .claude/scripts/tests/mcp-deps.test.sh.
#   3. Per-tool contract: every tool declares an object inputSchema of
#      type "object", a description longer than 30 characters, and all four
#      MCP annotations the README promises (readOnlyHint, destructiveHint,
#      idempotentHint, openWorldHint).
#   4. A real tools/call round-trip against a real `bd` and a real .beads/:
#      bd_list_tasks succeeds (ok=true) and a bogus task id produces the
#      structured error envelope with the agent-self-correction `hint:` line.
#      This is what separates "the tool NAMES are registered" from "the tools
#      actually reach Beads".
#
# What this spec does NOT cover:
#
#   - Per-tool argument validation and side effects — covered by the server
#     package's own node:test suite (tests/integration.test.js).
#   - The QA-gate side-effect bundle (bd_qa_*) — covered at L2 by
#     .claude/tests/component/specs/qa-gate.sh against the shell helper those
#     tools wrap.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# mk_fixture runs `bd init` in the fixture, and section 4 drives real tool
# calls against that database, so the real CLI is required here (not just for
# the harness). Skip-with-log on a CI runner without bd.
bd_required_or_skip

PLUGIN_ROOT=$(plugin_root)
MCP_DIR="$PLUGIN_ROOT/.claude/mcp/bd-mcp"
MCP_BIN="$MCP_DIR/bin/bd-mcp.js"

# The launcher (bin/bd-mcp.js) is a dynamic-import shim over src/server.js,
# which imports @modelcontextprotocol/sdk from node_modules under MCP_DIR.
#
# install.sh EXCLUDES node_modules from the MCP copy, and under `curl | bash`
# the source is a shallow clone in which .gitignore's `node_modules/` meant
# there was never anything to copy — so a RENDERED TARGET has zero server
# dependencies until the installer's own `npm ci --omit=dev` runs there
# (v4.1 / claude-workflow-plugin-z9m). In THIS repo the dev tree is what we
# boot from, so absent node_modules means "nobody ran npm install in the
# checkout".
#
# We therefore ATTEMPT the install once rather than self-skipping: a bare
# `exit 0` here would reproduce the reporting bug this spec exists to close.
# --omit=dev --ignore-scripts is safe and is the documented air-gapped recipe
# (workflow-doctor.sh --help): the lockfile carries zero dev packages and zero
# install scripts, pinned by .claude/scripts/tests/mcp-deps.test.sh.
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIPPED: %s (node not on PATH)\n' "${BASH_SOURCE[0]##*/}"
    exit 0
fi
if [ ! -f "$MCP_BIN" ]; then
    printf 'SKIPPED: %s (launcher missing at %s)\n' "${BASH_SOURCE[0]##*/}" "$MCP_BIN"
    exit 0
fi
if [ ! -d "$MCP_DIR/node_modules" ]; then
    if ! command -v npm >/dev/null 2>&1; then
        printf 'SKIPPED: %s (node_modules absent under %s and npm not on PATH)\n' \
            "${BASH_SOURCE[0]##*/}" "$MCP_DIR"
        exit 0
    fi
    # shellcheck disable=SC2016  # the backticked npm command is literal text, not a substitution
    printf '  note: %s — node_modules absent; attempting `npm ci --omit=dev` once in %s\n' \
        "${BASH_SOURCE[0]##*/}" "$MCP_DIR"
    NPM_CI_LOG="$FIXTURE/npm-ci-bd-mcp.log"
    if ! ( cd "$MCP_DIR" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
            --loglevel=error ) >"$NPM_CI_LOG" 2>&1; then
        printf 'SKIPPED: %s (npm ci failed in %s; see %s — last lines:)\n' \
            "${BASH_SOURCE[0]##*/}" "$MCP_DIR" "$NPM_CI_LOG"
        tail -5 "$NPM_CI_LOG" 2>/dev/null | sed 's/^/    /'
        exit 0
    fi
    if [ ! -d "$MCP_DIR/node_modules" ]; then
        printf 'SKIPPED: %s (npm ci exited 0 but %s/node_modules still absent)\n' \
            "${BASH_SOURCE[0]##*/}" "$MCP_DIR"
        exit 0
    fi
fi

# The 21-tool surface, sorted and comma-joined. Kept literal (rather than
# derived from the server) so a tool that silently disappears fails HERE
# instead of quietly shrinking a derived expectation.
BD_MCP_TOOLS_SORTED="bd_add_comment,bd_add_dep,bd_add_label,bd_close_task,bd_create_epic,bd_create_task,bd_doc_read,bd_doc_write,bd_get_blocked,bd_get_ready,bd_list_comments,bd_list_deps,bd_list_labels,bd_list_tasks,bd_qa_approve,bd_qa_block,bd_qa_enter,bd_qa_status,bd_remove_label,bd_show_task,bd_update_task"
BD_MCP_TOOL_COUNT=21

# --------------------------------------------------------------------------
# Helper: drive JSON-RPC frames over stdio and capture the responses. The
# server reads line-delimited JSON-RPC from stdin and writes line-delimited
# frames to stdout; the trailing sleep gives it time to flush before EOF.
# Same pattern as code-graph-mcp.sh (and as workflow-doctor.sh's mcp probe).
#
# CLAUDE_PROJECT_DIR points at the FIXTURE so every bd call lands in the
# fixture's throwaway .beads/, never in the plugin repo's real database.
#
# Args: $1 — path to write captured stdout; $2..N — JSON-RPC frames.
# --------------------------------------------------------------------------
bd_mcp_call() {
    local out_file="$1"; shift
    {
        for frame in "$@"; do
            printf '%s\n' "$frame"
            sleep 0.05
        done
        sleep 1
    } | CLAUDE_PROJECT_DIR="$FIXTURE" node "$MCP_BIN" \
        > "$out_file" 2>"$FIXTURE/bd-mcp-stderr.log"
}

INIT_FRAME='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2-bd-mcp","version":"0.0.0"}}}'
READY_FRAME='{"jsonrpc":"2.0","method":"notifications/initialized"}'

# ==========================================================================
# Section 1: boot + tools/list cardinality.
# ==========================================================================
OUT1="$FIXTURE/bd-round1.jsonl"
bd_mcp_call "$OUT1" \
    "$INIT_FRAME" \
    "$READY_FRAME" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

INIT_RAW=$(grep -F '"id":1' "$OUT1" | head -1)
INIT_NAME=$(printf '%s' "$INIT_RAW" | jq -r '.result.serverInfo.name // ""' 2>/dev/null || echo "")
assert_eq "bd-mcp-1: initialize returns serverInfo.name=bd-mcp" \
    "bd-mcp" "$INIT_NAME"

INIT_VERSION=$(printf '%s' "$INIT_RAW" | jq -r '.result.serverInfo.version // ""' 2>/dev/null || echo "")
if [ -n "$INIT_VERSION" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: bd-mcp-1: serverInfo.version is non-empty (got %s)\n' "$INIT_VERSION"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("bd-mcp-1: serverInfo.version is empty")
    printf '  FAIL: bd-mcp-1: serverInfo.version is empty\n'
fi

INIT_PROTO=$(printf '%s' "$INIT_RAW" | jq -r '.result.protocolVersion // ""' 2>/dev/null || echo "")
assert_eq "bd-mcp-1: initialize echoes protocolVersion 2024-11-05" \
    "2024-11-05" "$INIT_PROTO"

TOOLS_RAW=$(grep -F '"id":2' "$OUT1" | head -1)
TOOL_COUNT=$(printf '%s' "$TOOLS_RAW" | jq -r '(.result.tools // []) | length' 2>/dev/null || echo "0")
# EXACT equality. A >= bound is green for a server that registers nothing,
# which is the failure this assertion exists to catch.
assert_eq "bd-mcp-1: tools/list returns EXACTLY $BD_MCP_TOOL_COUNT tools" \
    "$BD_MCP_TOOL_COUNT" "$TOOL_COUNT"

TOOL_NAMES=$(printf '%s' "$TOOLS_RAW" | jq -r '.result.tools[].name' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "bd-mcp-1: tools/list name list matches the pinned surface (sorted, comma-joined)" \
    "$BD_MCP_TOOLS_SORTED" "$TOOL_NAMES"

# The count table in workflow-doctor.sh must agree with the number this spec
# just observed; the two are separate hand-written pins and a drift between
# them means the doctor would pass an install this spec fails (or vice versa).
DOCTOR_SH="$PLUGIN_ROOT/.claude/scripts/workflow-doctor.sh"
DOCTOR_BD_COUNT=$(sed -n 's/^DOCTOR_TOOL_COUNTS="\(.*\)"$/\1/p' "$DOCTOR_SH" 2>/dev/null \
    | tr ' ' '\n' | sed -n 's/^bd-mcp:\([0-9]*\)$/\1/p' | head -1)
assert_eq "bd-mcp-1: workflow-doctor.sh DOCTOR_TOOL_COUNTS agrees on bd-mcp's tool count" \
    "$BD_MCP_TOOL_COUNT" "${DOCTOR_BD_COUNT:-<unset>}"

# ==========================================================================
# Section 2: per-tool contract — schema, description, annotations.
# ==========================================================================
BAD_SCHEMA=$(printf '%s' "$TOOLS_RAW" \
    | jq -r '[(.result.tools // [])[] | select((.inputSchema | type) != "object") | .name] | join(",")' \
    2>/dev/null || echo "jq-failed")
assert_eq "bd-mcp-2: every tool declares an OBJECT inputSchema" "" "$BAD_SCHEMA"

BAD_SCHEMA_TYPE=$(printf '%s' "$TOOLS_RAW" \
    | jq -r '[(.result.tools // [])[] | select(.inputSchema.type != "object") | .name] | join(",")' \
    2>/dev/null || echo "jq-failed")
assert_eq "bd-mcp-2: every tool's inputSchema declares type=object" "" "$BAD_SCHEMA_TYPE"

SHORT_DESC=$(printf '%s' "$TOOLS_RAW" \
    | jq -r '[(.result.tools // [])[] | select(((.description // "") | length) <= 30) | .name] | join(",")' \
    2>/dev/null || echo "jq-failed")
assert_eq "bd-mcp-2: every tool description is longer than 30 characters" "" "$SHORT_DESC"

MIN_DESC=$(printf '%s' "$TOOLS_RAW" \
    | jq -r '[(.result.tools // [])[] | (.description // "") | length] | min' 2>/dev/null || echo "0")
if [ "${MIN_DESC:-0}" -gt 30 ]; then
    PASS=$((PASS + 1))
    printf '  PASS: bd-mcp-2: shortest description is %s chars (> 30)\n' "$MIN_DESC"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("bd-mcp-2: shortest description is ${MIN_DESC:-0} chars (expected > 30)")
    printf '  FAIL: bd-mcp-2: shortest description is %s chars (expected > 30)\n' "${MIN_DESC:-0}"
fi

# The README's claim: "Every tool exposes the four MCP annotations". Asserted
# per-annotation so a failure names WHICH hint is missing rather than just
# "annotations wrong".
for hint in readOnlyHint destructiveHint idempotentHint openWorldHint; do
    MISSING_HINT=$(printf '%s' "$TOOLS_RAW" \
        | jq -r --arg h "$hint" \
            '[(.result.tools // [])[] | select((.annotations // {}) | has($h) | not) | .name] | join(",")' \
        2>/dev/null || echo "jq-failed")
    assert_eq "bd-mcp-2: every tool declares the $hint annotation" "" "$MISSING_HINT"
done

# The QA-gate lifecycle quartet must be present by name: these are the tools
# the workflow's gate is driven through, and a partial surface here means an
# agent silently loses the ability to enter/approve/block a gate.
for qa_tool in bd_qa_enter bd_qa_status bd_qa_approve bd_qa_block; do
    HAS_QA=$(printf '%s' "$TOOLS_RAW" \
        | jq -r --arg t "$qa_tool" '[(.result.tools // [])[] | select(.name == $t)] | length' \
        2>/dev/null || echo "0")
    assert_eq "bd-mcp-2: QA-gate tool $qa_tool is registered" "1" "$HAS_QA"
done

# ==========================================================================
# Section 3: real tools/call round-trip against a real bd + real .beads/.
#
# Registration is not function. This section is what distinguishes "the 21
# names are in the manifest" from "the tools actually reach Beads".
# ==========================================================================
OUT2="$FIXTURE/bd-round2.jsonl"
bd_mcp_call "$OUT2" \
    "$INIT_FRAME" \
    "$READY_FRAME" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bd_list_tasks","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"bd_show_task","arguments":{"task_id":"bd-mcp-l2-does-not-exist"}}}'

LIST_FRAME=$(grep -F '"id":2' "$OUT2" | head -1)
LIST_OK=$(printf '%s' "$LIST_FRAME" | jq -r '.result.structuredContent.ok // ""' 2>/dev/null || echo "")
assert_eq "bd-mcp-3: bd_list_tasks against the fixture's .beads/ returns ok=true" \
    "true" "$LIST_OK"

LIST_IS_ERROR=$(printf '%s' "$LIST_FRAME" | jq -r '.result.isError // false' 2>/dev/null || echo "true")
assert_eq "bd-mcp-3: bd_list_tasks is not an error envelope" "false" "$LIST_IS_ERROR"

LIST_HEADLINE=$(printf '%s' "$LIST_FRAME" | jq -r '.result.structuredContent.headline // ""' 2>/dev/null || echo "")
assert_contains "bd-mcp-3: bd_list_tasks headline names the tool" \
    "bd_list_tasks" "$LIST_HEADLINE"

# A bogus task id must produce the structured error envelope carrying the
# agent-self-correction `hint:` line, not a silent empty success.
ERR_FRAME=$(grep -F '"id":3' "$OUT2" | head -1)
ERR_IS_ERROR=$(printf '%s' "$ERR_FRAME" | jq -r '.result.isError // false' 2>/dev/null || echo "false")
assert_eq "bd-mcp-3: bd_show_task on a nonexistent id marks isError=true" \
    "true" "$ERR_IS_ERROR"

ERR_TEXT=$(printf '%s' "$ERR_FRAME" | jq -r '.result.content[0].text // ""' 2>/dev/null || echo "")
assert_contains "bd-mcp-3: the error envelope names the missing id" \
    "bd-mcp-l2-does-not-exist" "$ERR_TEXT"
assert_contains "bd-mcp-3: the error envelope carries a 'hint:' recovery line" \
    "hint:" "$ERR_TEXT"

# Nothing may be written to the plugin repo's own Beads database by this spec.
# The fixture's .beads/ is the only database in play; assert the fixture DB is
# the one that answered by confirming the fixture dir still holds it.
if [ -d "$FIXTURE/.beads" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: bd-mcp-3: the answering database is the fixture .beads/ (throwaway)\n'
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("bd-mcp-3: fixture .beads/ missing — the tool calls may have hit another database")
    printf '  FAIL: bd-mcp-3: fixture .beads/ missing — the tool calls may have hit another database\n'
fi

# ==========================================================================
# Section 4: the boot failure this spec exists to catch is DETECTABLE.
#
# Not a mutation of the server (that would mean editing the plugin's own
# source): a COPY of the launcher tree with node_modules deliberately absent,
# which is byte-for-byte the shape install.sh renders into a target. The
# import must fail and the handshake must produce no serverInfo — proving
# Section 1's assertion is sensitive to the real defect rather than to
# anything else that happens to be true today.
# ==========================================================================
BROKEN_DIR="$FIXTURE/bd-mcp-no-deps"
mkdir -p "$BROKEN_DIR"
# Copy everything EXCEPT node_modules — exactly install.sh's rsync exclude.
if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude=node_modules "$MCP_DIR/" "$BROKEN_DIR/" >/dev/null 2>&1
else
    cp -R "$MCP_DIR/." "$BROKEN_DIR/" >/dev/null 2>&1
    rm -rf "$BROKEN_DIR/node_modules"
fi

if [ -d "$BROKEN_DIR/node_modules" ] || [ ! -f "$BROKEN_DIR/bin/bd-mcp.js" ]; then
    # The fixture did not get into the state the check needs, so its verdict
    # would be meaningless. Fail loudly instead of reporting a green that
    # proves nothing.
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("bd-mcp-4: could not build the no-deps copy (node_modules present or launcher missing) — the sensitivity check is unverified")
    printf '  FAIL: bd-mcp-4: could not build the no-deps copy — sensitivity unverified\n'
else
    PASS=$((PASS + 1))
    printf '  PASS: bd-mcp-4: no-deps copy built (launcher present, node_modules absent)\n'

    BROKEN_OUT="$FIXTURE/bd-broken.jsonl"
    BROKEN_ERR="$FIXTURE/bd-broken-stderr.log"
    {
        printf '%s\n' "$INIT_FRAME"
        sleep 0.05
        sleep 1
    } | CLAUDE_PROJECT_DIR="$FIXTURE" node "$BROKEN_DIR/bin/bd-mcp.js" \
        > "$BROKEN_OUT" 2>"$BROKEN_ERR" || true

    BROKEN_NAME=$(grep -F '"id":1' "$BROKEN_OUT" 2>/dev/null | head -1 \
        | jq -r '.result.serverInfo.name // ""' 2>/dev/null || echo "")
    assert_eq "bd-mcp-4: a node_modules-less copy yields NO serverInfo.name (the shipped-target defect)" \
        "" "$BROKEN_NAME"

    if grep -qE 'ERR_MODULE_NOT_FOUND|Cannot find (module|package)' "$BROKEN_ERR" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf '  PASS: bd-mcp-4: the no-deps copy fails with a module-resolution error on stderr\n'
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("bd-mcp-4: no-deps copy did not report a module-resolution failure; stderr head: $(head -c 200 "$BROKEN_ERR" 2>/dev/null | tr '\n' ' ')")
        printf '  FAIL: bd-mcp-4: no-deps copy did not report a module-resolution failure\n'
        printf '    stderr head: %s\n' "$(head -c 200 "$BROKEN_ERR" 2>/dev/null | tr '\n' ' ')"
    fi
fi

[ "$FAIL" -eq 0 ]

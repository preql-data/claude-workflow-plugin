#!/bin/bash
# code-graph-mcp.sh — L2 component spec for Phase B item B.1.
#
# Verifies the code-graph-mcp server boots over stdio, returns the
# 7-tool surface in tools/list, reports health, and produces
# actionable errors on malformed args. Includes a META-TEST that
# corrupts the index DB and asserts code_index_health flips to
# `unhealthy` — and a sensitivity check that the assertion would FAIL
# if the health check were stubbed to lie.
#
# What this spec covers (script-testable):
#
#   1. Boot: stdio initialize handshake completes within a timeout.
#   2. tools/list: every one of the 7 declared tools is present with a
#      well-formed inputSchema and an informative description (>30
#      chars).
#   3. Health round-trip: tools/call code_index_health returns ok
#      (uninitialised first, healthy after a code_search build).
#   4. Malformed args: tools/call code_search with `query: 123`
#      surfaces a structured error envelope carrying both `hint:` and
#      `example:` lines (the agent self-correction contract).
#   5. META-TEST: corrupt the index DB → health reports `unhealthy`
#      with reason=corrupt_index.
#   6. META-TEST (sensitivity): stub the corruption-detection branch
#      in db.js to return "healthy" → the health assertion above MUST
#      fail. Mirrors the rubric-loop sensitivity pattern (Section 9).
#
# What this spec does NOT cover:
#
#   - Per-language indexer correctness — covered by the server-package
#     node:test suite (tests/indexer.test.js, tests/tools.test.js,
#     tests/server.test.js).
#   - Long-running indexer behaviour at scale — out of scope; the L2
#     tier targets contract assertions, not load tests.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when bd is unavailable. mk_fixture pre-installs the
# bd shim, so the only time we skip is on CI runners that lack the
# real `bd` CLI. The server itself doesn't need bd, but mk_fixture's
# bd init does (it sets up .beads/ for the surrounding harness).
bd_required_or_skip

PLUGIN_ROOT=$(plugin_root)
MCP_DIR="$PLUGIN_ROOT/.claude/mcp/code-graph-mcp"
MCP_BIN="$MCP_DIR/bin/code-graph-mcp.js"

# The server module imports from node_modules under MCP_DIR. The
# install.sh path copies node_modules along with the rest of the tree
# when shipping; in the source repo it must be installed manually.
# Skip-with-log if node_modules/ is absent (CI may run install
# separately).
if [ ! -d "$MCP_DIR/node_modules" ]; then
    printf 'SKIPPED: %s (node_modules not installed under %s — run `cd %s && npm install` first)\n' \
        "${BASH_SOURCE[0]##*/}" "$MCP_DIR" "$MCP_DIR"
    exit 0
fi
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIPPED: %s (node not on PATH)\n' "${BASH_SOURCE[0]##*/}"
    exit 0
fi

# Build a temp project root the MCP can index. A small sub-fixture is
# enough — three .ts files with a known def/call shape. Keeps the
# index-build path under a few hundred ms.
SAMPLE="$FIXTURE/sample-project"
mkdir -p "$SAMPLE"
cat > "$SAMPLE/a.ts" <<'TS'
export function flagshipSymbol(): string {
    return "flagship";
}
TS
cat > "$SAMPLE/b.ts" <<'TS'
import { flagshipSymbol } from "./a";

export function consumer(): string {
    return flagshipSymbol();
}
TS

# --------------------------------------------------------------------------
# Helper: send JSON-RPC frames over stdio to the MCP server and
# capture the responses. The server reads line-delimited JSON-RPC
# from stdin and writes line-delimited frames to stdout; we use a
# 30s `sleep` tail so the server has time to flush before SIGPIPE.
#
# Args:
#   $1 — path to write captured stdout
#   $2..N — JSON-RPC frames (one per arg)
# --------------------------------------------------------------------------
mcp_call() {
    local out_file="$1"; shift
    {
        for frame in "$@"; do
            printf '%s\n' "$frame"
            sleep 0.05
        done
        sleep 1
    } | CLAUDE_PROJECT_DIR="$SAMPLE" node "$MCP_BIN" > "$out_file" 2>/tmp/code-graph-mcp-stderr.log
}

# --------------------------------------------------------------------------
# Section 1: boot + tools/list.
# --------------------------------------------------------------------------
OUT1="$FIXTURE/round1.jsonl"
mcp_call "$OUT1" \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2-smoke","version":"0.0.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# init response must carry the right serverInfo.
INIT_NAME=$(grep -F '"id":1' "$OUT1" | head -1 | jq -r '.result.serverInfo.name // ""' 2>/dev/null || echo "")
assert_eq "code-graph-mcp-1: initialize returns serverInfo.name=code-graph-mcp" \
    "code-graph-mcp" "$INIT_NAME"

# tools/list response must enumerate the 7 declared tools.
TOOLS_RAW=$(grep -F '"id":2' "$OUT1" | head -1)
TOOL_NAMES=$(printf '%s' "$TOOLS_RAW" | jq -r '.result.tools[].name' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "code-graph-mcp-1: tools/list returns the 7 declared tools (sorted, comma-joined)" \
    "code_context,code_index_health,code_search,dead_code,dependency_path,impact_of,symbol_callers" \
    "$TOOL_NAMES"

# Every tool must declare an inputSchema and a substantive description.
for tool in code_search code_context code_index_health symbol_callers impact_of dead_code dependency_path; do
    HAS_SCHEMA=$(printf '%s' "$TOOLS_RAW" | jq --arg t "$tool" -r \
        '.result.tools[] | select(.name == $t) | .inputSchema | type' 2>/dev/null || echo "")
    assert_eq "code-graph-mcp-1: ${tool}.inputSchema is an object" "object" "$HAS_SCHEMA"

    DESC_LEN=$(printf '%s' "$TOOLS_RAW" | jq --arg t "$tool" -r \
        '.result.tools[] | select(.name == $t) | .description | length' 2>/dev/null || echo "0")
    if [ "$DESC_LEN" -gt 30 ]; then
        PASS=$((PASS + 1))
        printf '  PASS: code-graph-mcp-1: %s description length > 30 (got %s)\n' "$tool" "$DESC_LEN"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("code-graph-mcp-1: $tool description length suspiciously short ($DESC_LEN <= 30)")
        printf '  FAIL: code-graph-mcp-1: %s description length is %s (expected > 30)\n' "$tool" "$DESC_LEN"
    fi
done

# --------------------------------------------------------------------------
# Section 2: health round-trip — uninitialized then healthy.
# --------------------------------------------------------------------------
OUT2="$FIXTURE/round2.jsonl"
mcp_call "$OUT2" \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2","version":"0.0.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"code_index_health","arguments":{}}}'

HEALTH_STATUS=$(grep -F '"id":2' "$OUT2" | head -1 | jq -r '.result.structuredContent.data.status // ""' 2>/dev/null || echo "")
assert_eq "code-graph-mcp-2: pre-build health reports status=uninitialized" \
    "uninitialized" "$HEALTH_STATUS"

# Now trigger a build via code_search, then re-ask health.
OUT3="$FIXTURE/round3.jsonl"
mcp_call "$OUT3" \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2","version":"0.0.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"code_search","arguments":{"query":"flagshipSymbol"}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"code_index_health","arguments":{}}}'

# code_search response.
SEARCH_OK=$(grep -F '"id":2' "$OUT3" | head -1 | jq -r '.result.structuredContent.ok // ""' 2>/dev/null || echo "")
assert_eq "code-graph-mcp-2: code_search returns ok=true after lazy build" "true" "$SEARCH_OK"
SEARCH_COUNT=$(grep -F '"id":2' "$OUT3" | head -1 | jq -r '.result.structuredContent.data.matches | length' 2>/dev/null || echo "0")
if [ "$SEARCH_COUNT" -ge 1 ]; then
    PASS=$((PASS + 1))
    printf '  PASS: code-graph-mcp-2: code_search found flagshipSymbol (count=%s)\n' "$SEARCH_COUNT"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("code-graph-mcp-2: code_search returned 0 matches; expected >= 1")
    printf '  FAIL: code-graph-mcp-2: code_search returned 0 matches; expected >= 1\n'
fi

POST_HEALTH=$(grep -F '"id":3' "$OUT3" | head -1 | jq -r '.result.structuredContent.data.status // ""' 2>/dev/null || echo "")
assert_eq "code-graph-mcp-2: post-build health reports status=healthy" \
    "healthy" "$POST_HEALTH"

# --------------------------------------------------------------------------
# Section 3: malformed args → structured error envelope with hint + example.
# --------------------------------------------------------------------------
OUT4="$FIXTURE/round4.jsonl"
mcp_call "$OUT4" \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2","version":"0.0.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"symbol_callers","arguments":{"symbol":"has spaces and bad!chars"}}}'

ERR_FRAME=$(grep -F '"id":2' "$OUT4" | head -1)
ERR_IS_ERROR=$(printf '%s' "$ERR_FRAME" | jq -r '.result.isError // false' 2>/dev/null || echo "false")
assert_eq "code-graph-mcp-3: malformed symbol marks isError=true" "true" "$ERR_IS_ERROR"

ERR_TEXT=$(printf '%s' "$ERR_FRAME" | jq -r '.result.content[0].text // ""' 2>/dev/null || echo "")
assert_contains "code-graph-mcp-3: error envelope contains 'hint:'" "hint:" "$ERR_TEXT"
assert_contains "code-graph-mcp-3: error envelope contains 'example:'" "example:" "$ERR_TEXT"
assert_contains "code-graph-mcp-3: error envelope mentions invalid characters" \
    "invalid characters" "$ERR_TEXT"

# --------------------------------------------------------------------------
# Section 4: META-TEST — corrupt the index DB; health flips to unhealthy.
# --------------------------------------------------------------------------
INDEX_DB="$SAMPLE/.claude/.code-graph/index.db"
if [ ! -f "$INDEX_DB" ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("code-graph-mcp-4: index DB not present at $INDEX_DB after build — cannot run META-TEST")
    printf '  FAIL: code-graph-mcp-4: index DB missing at %s\n' "$INDEX_DB"
else
    # Overwrite with garbage. The server's openDb is supposed to
    # detect this and produce CodeGraphError(code=CORRUPT_INDEX),
    # which the health tool translates into status=unhealthy without
    # marking isError.
    printf 'NOT-A-SQLITE-FILE — CORRUPTED-FOR-CODE-GRAPH-MCP-META-TEST\n' > "$INDEX_DB"

    OUT5="$FIXTURE/round5.jsonl"
    mcp_call "$OUT5" \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2","version":"0.0.0"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"code_index_health","arguments":{}}}'

    HEALTH_AFTER_CORRUPTION=$(grep -F '"id":2' "$OUT5" | head -1 | jq -r '.result.structuredContent.data.status // ""' 2>/dev/null || echo "")
    HEALTH_REASON=$(grep -F '"id":2' "$OUT5" | head -1 | jq -r '.result.structuredContent.data.reason // ""' 2>/dev/null || echo "")
    assert_eq "code-graph-mcp-4: META-TEST — corrupted index reports status=unhealthy" \
        "unhealthy" "$HEALTH_AFTER_CORRUPTION"
    assert_eq "code-graph-mcp-4: META-TEST — reason=corrupt_index" \
        "corrupt_index" "$HEALTH_REASON"
fi

# --------------------------------------------------------------------------
# Section 5: META-TEST (sensitivity) — stub the corruption-detection in
# db.js to lie ("everything's fine"). The Section 4 assertion above must
# FAIL under the stub. Mirrors the rubric-loop.sh Section 9 anchor-drift
# guard pattern: we look for a sentinel comment to confirm the stub
# actually installed before treating its result as evidence.
#
# Because the L2 fixture symlinks every script BUT the MCP server's
# JS, we stub the server file directly. We copy the whole code-graph-mcp
# tree into the fixture so the stub doesn't touch the real plugin
# source. The stub neutralizes the `throw new CodeGraphError(... code:
# 'CORRUPT_INDEX' ...)` block in db.js by replacing it with a no-op
# (open returns a fresh empty DB).
# --------------------------------------------------------------------------
STUB_DIR="$FIXTURE/code-graph-mcp-stub"
cp -R "$MCP_DIR" "$STUB_DIR"

# Rewrite db.js to neutralize the corruption detection. We rewrite the
# `db.run(SCHEMA_SQL)` try block so an error there silently swallows
# the exception (instead of throwing CORRUPT_INDEX). awk for the
# replacement, with a sentinel for the anchor-drift guard.
DB_JS="$STUB_DIR/src/lib/db.js"
PLUGIN_DB_JS="$MCP_DIR/src/lib/db.js"
rm -f "$DB_JS"
awk '
    /} catch \(err\) {$/ && in_schema {
        print
        print "        // META-TEST stub: corruption detection neutralized. The"
        print "        // real branch throws CodeGraphError(CORRUPT_INDEX) so"
        print "        // code_index_health can flip to unhealthy. Under this"
        print "        // stub we swallow the error and let openDb pretend"
        print "        // everything succeeded — which is exactly what the"
        print "        // sensitivity check needs to falsify the Section-4"
        print "        // assertion."
        in_schema = 0
        # Skip until matching closing brace for the catch block.
        in_catch_swallow = 1
        next
    }
    in_catch_swallow {
        if (/^    }$/) {
            print "        return new DbHandle(db, target);"
            print "    }"
            in_catch_swallow = 0
            done_stub = 1
        }
        next
    }
    /try {$/ && prev_schema {
        in_schema = 1
        prev_schema = 0
    }
    /Apply schema/ { prev_schema = 1 }
    { print }
    END { if (!done_stub) exit 7 }
' "$PLUGIN_DB_JS" > "$DB_JS"
AWK_RC=$?
chmod 644 "$DB_JS"

if [ "$AWK_RC" -ne 0 ] || ! grep -qF 'META-TEST stub: corruption detection neutralized' "$DB_JS"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("code-graph-mcp-5: META-TEST stub did NOT install (awk regex stale or db.js refactored?)")
    printf '  FAIL: code-graph-mcp-5: stub did not install — the Section 4 assertion is unverified for sensitivity\n'
else
    PASS=$((PASS + 1))
    printf '  PASS: code-graph-mcp-5: META-TEST stub installed (sentinel present in db.js)\n'

    # Run the same flow against the stubbed server. We need to ensure
    # the stub variant has its own node_modules (rsync via cp -R
    # copied the existing one). Trigger a fresh build via code_search,
    # then corrupt the index, then ask health — the stubbed server
    # MUST NOT report unhealthy.
    STUB_BIN="$STUB_DIR/bin/code-graph-mcp.js"
    STUB_SAMPLE="$FIXTURE/sample-project-stub"
    cp -R "$SAMPLE" "$STUB_SAMPLE"
    rm -rf "$STUB_SAMPLE/.claude/.code-graph"   # force fresh build

    mcp_call_stub() {
        local out_file="$1"; shift
        {
            for frame in "$@"; do
                printf '%s\n' "$frame"
                sleep 0.05
            done
            sleep 1
        } | CLAUDE_PROJECT_DIR="$STUB_SAMPLE" node "$STUB_BIN" > "$out_file" 2>/tmp/code-graph-mcp-stub-stderr.log
    }

    # Build the index against the stubbed server.
    OUT6="$FIXTURE/round6.jsonl"
    mcp_call_stub "$OUT6" \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2","version":"0.0.0"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"code_search","arguments":{"query":"flagshipSymbol"}}}'

    # Confirm build succeeded.
    STUB_BUILD_OK=$(grep -F '"id":2' "$OUT6" | head -1 | jq -r '.result.structuredContent.ok // ""' 2>/dev/null || echo "")
    assert_eq "code-graph-mcp-5: stubbed-server code_search ok (lazy build still works)" \
        "true" "$STUB_BUILD_OK"

    # Now corrupt the stubbed-server's index DB and re-ask health.
    STUB_INDEX_DB="$STUB_SAMPLE/.claude/.code-graph/index.db"
    if [ ! -f "$STUB_INDEX_DB" ]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("code-graph-mcp-5: stubbed-server index DB not present — cannot complete sensitivity check")
        printf '  FAIL: code-graph-mcp-5: stubbed-server index DB missing at %s\n' "$STUB_INDEX_DB"
    else
        printf 'NOT-A-SQLITE-FILE — CORRUPTED-FOR-CODE-GRAPH-MCP-SENSITIVITY-META-TEST\n' > "$STUB_INDEX_DB"

        OUT7="$FIXTURE/round7.jsonl"
        mcp_call_stub "$OUT7" \
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2","version":"0.0.0"}}}' \
            '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"code_index_health","arguments":{}}}'

        STUB_HEALTH=$(grep -F '"id":2' "$OUT7" | head -1 | jq -r '.result.structuredContent.data.status // ""' 2>/dev/null || echo "")
        # Sensitivity expectation: under the stub, status MUST NOT be
        # "unhealthy". The acceptable outcomes are status=healthy,
        # status=stale, or status=uninitialized — any case where the
        # corruption is invisible. If status=unhealthy still appears,
        # the stub failed to disable detection — the regular
        # assertion is then theatre.
        if [ "$STUB_HEALTH" = "unhealthy" ]; then
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("code-graph-mcp-5: META-TEST sensitivity FAILED — stub did not change behaviour (still reports unhealthy)")
            printf '  FAIL: code-graph-mcp-5: stubbed server STILL reports unhealthy — sensitivity not proven\n'
        else
            PASS=$((PASS + 1))
            printf '  PASS: code-graph-mcp-5: META-TEST sensitivity — stubbed server hides corruption (status=%s ≠ unhealthy)\n' "$STUB_HEALTH"
        fi
    fi
fi

[ "$FAIL" -eq 0 ]

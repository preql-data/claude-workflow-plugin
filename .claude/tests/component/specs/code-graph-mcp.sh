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
#      (uninitialised first, healthy after a code_search build). The
#      build and the health check that observes it run in SEPARATE
#      server processes, with a bounded wait for index.db between
#      them — see the "one observation per process" block above
#      wait_for_index. Merging them back into one round reintroduces
#      claude-workflow-plugin-dxz.
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

# The server module imports from node_modules under MCP_DIR.
#
# CORRECTED (v4.1 / claude-workflow-plugin-0fc). The comment that stood here
# for three releases said "The install.sh path copies node_modules along with
# the rest of the tree when shipping" — the exact INVERSE of the truth, and
# the sentence that made the bare `exit 0` below look benign while the
# shipped-target case it claimed to cover was broken. The truth:
#
#   - install.sh EXCLUDES node_modules from the MCP copy (rsync
#     --exclude=node_modules, and an `rm -rf` in the cp fallback), and under
#     `curl | bash` the source is a shallow clone where .gitignore's
#     `node_modules/` means there was never anything to copy in the first
#     place. A rendered target therefore has ZERO server dependencies.
#   - As of v4.1 the installer runs `npm ci --omit=dev` IN THE TARGET instead
#     (claude-workflow-plugin-z9m), which is what actually makes a shipped
#     install bootable.
#   - In THIS repo the dev tree is what we boot from, so a missing
#     node_modules here means "nobody ran npm install in the checkout", not
#     "the ship path is fine".
#
# And a self-skip is not evidence: an unconditional `exit 0` on absent
# node_modules made this spec report PASS on precisely the machines where the
# servers could not boot. So: ATTEMPT the install once, and only skip-with-log
# if that attempt fails (offline CI runner with no registry access). The flags
# mirror the air-gapped recipe in workflow-doctor.sh --help: --omit=dev and
# --ignore-scripts are safe because both lockfiles carry zero dev packages and
# zero install scripts (pinned by .claude/scripts/tests/mcp-deps.test.sh).
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIPPED: %s (node not on PATH)\n' "${BASH_SOURCE[0]##*/}"
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
    NPM_CI_LOG="$FIXTURE/npm-ci-code-graph.log"
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
# from stdin and writes line-delimited frames to stdout; the trailing
# `sleep 1` holds the pipe open so the server has time to answer and
# flush before it sees EOF.
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
    } | CLAUDE_PROJECT_DIR="$SAMPLE" node "$MCP_BIN" > "$out_file" 2>"$FIXTURE/code-graph-mcp-stderr.log"
}

# --------------------------------------------------------------------------
# ONE OBSERVATION PER PROCESS — the invariant that makes this spec
# deterministic. Never put a state-CHANGING call and the call that
# OBSERVES that state into the same mcp_call.
#
# Why (claude-workflow-plugin-dxz). The MCP SDK does not serialise
# requests. `processReadBuffer` in @modelcontextprotocol/sdk's
# server/stdio.js drains EVERY complete frame in one stdin chunk in a
# single synchronous loop, and `_onrequest` in shared/protocol.js
# dispatches each as `Promise.resolve().then(() => handler(...))` and
# returns immediately. So two tool calls delivered in the same chunk are
# both queued as microtasks before EITHER handler has run a line.
#
# code_search's handler then runs first and suspends on ensureIndex()'s
# `await preloadParsers(...)` — before it has indexed anything — and
# code_index_health's microtask runs right behind it, finds
# existsSync(index.db) false, and correctly answers `uninitialized`. Its
# response overtakes code_search's on the wire.
#
# The measured behaviour, driving this repo's own server over stdio with
# controlled write timing (dxz):
#
#   frames 50 ms apart, 2-file project   -> health answers `healthy`
#   frames 50 ms apart, 151-file project -> health answers `healthy`,
#       even though the build takes ~1.9 s. Measured: the health frame
#       was written at t=156 ms and answered at t=2007 ms, 2 ms behind
#       search's own response — i.e. it sat unread for the entire build,
#       because the event loop is never free while ensureIndex's await
#       chain resolves
#   all frames in ONE write, 2-file      -> health answers `uninitialized`
#   all frames in ONE write, 151-file    -> health answers `uninitialized`
#
# So the variable is NOT the gap between frames — it is whether the two
# frames land in the same stdin read, which bash's buffering of `printf`
# into the pipe and the OS scheduler decide, and which machine load
# moves. That is why this spec flipped in BOTH directions across
# sessions with identical code, and it is why raising the `sleep` would
# have fixed nothing while looking like it worked: a 1.9 s build with a
# 50 ms gap still answers `healthy`.
#
# The fix is therefore the SPLIT, not the barrier: one tool call per
# process leaves nothing to chunk with and nothing to overtake. Every
# round in this spec now issues AT MOST ONE tools/call (round 1 issues
# none — tools/list is stateless) — keep it that way; a second one in
# any round reopens this bug.
#
# Nothing here is a server defect: resolve.js is shared by both tools and
# both read the same CLAUDE_PROJECT_DIR, so the two never disagreed about
# WHERE the index lives, only about WHEN it exists — and orchestrator.md
# and qa.md both tell agents that an empty or missing health result is
# the expected pre-build state. Serialising the server would change a
# documented contract to paper over a test bug.
#
# The barrier below is the readiness CONTRACT between the split halves,
# not the race fix: it states that round 3b (and Sections 4 and 5) may
# only run once round 3a's build actually reached disk. In the healthy
# case the first probe already finds the file — bash waits for every
# member of a pipeline, so node has exited, and therefore finished
# persisting, by the time mcp_call returns. The loop keeps that from
# being an unstated assumption if the server ever persists from a
# detached child or exits on stdin EOF before persist.
#
# A timeout here is a FAIL. Not a skip, not a retry, not "flaky": if the
# lazy build produced no index, every assertion downstream of it is
# meaningless, and a spec that cried flake would teach the next reader to
# re-run instead of to believe it.
# --------------------------------------------------------------------------
INDEX_WAIT_TRIES=20            # x INDEX_WAIT_SLEEP = the ceiling below
INDEX_WAIT_SLEEP=0.25          # fractional sleep is already required by mcp_call
INDEX_WAIT_BUDGET=$(awk -v n="$INDEX_WAIT_TRIES" -v s="$INDEX_WAIT_SLEEP" \
    'BEGIN { printf "%.10g", n * s }')

# wait_for_index <db-path> — 0 once the index exists and is non-empty,
# 1 once the budget is spent. Prints nothing; the caller owns the message
# so the failure text can name the round it belongs to.
wait_for_index() {
    local db_path="$1"
    local tries=0
    while [ "$tries" -lt "$INDEX_WAIT_TRIES" ]; do
        if [ -f "$db_path" ] && [ -s "$db_path" ]; then
            return 0
        fi
        sleep "$INDEX_WAIT_SLEEP"
        tries=$((tries + 1))
    done
    return 1
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

# Round 3a — trigger the build via code_search, in a process of its own.
# Adding a code_index_health frame to THIS round IS the dxz bug; see the
# "one observation per process" block above wait_for_index.
OUT3A="$FIXTURE/round3a.jsonl"
mcp_call "$OUT3A" \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2","version":"0.0.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"code_search","arguments":{"query":"flagshipSymbol"}}}'

# code_search response.
SEARCH_OK=$(grep -F '"id":2' "$OUT3A" | head -1 | jq -r '.result.structuredContent.ok // ""' 2>/dev/null || echo "")
assert_eq "code-graph-mcp-2: code_search returns ok=true after lazy build" "true" "$SEARCH_OK"
SEARCH_COUNT=$(grep -F '"id":2' "$OUT3A" | head -1 | jq -r '.result.structuredContent.data.matches | length' 2>/dev/null || echo "0")
if [ "$SEARCH_COUNT" -ge 1 ]; then
    PASS=$((PASS + 1))
    printf '  PASS: code-graph-mcp-2: code_search found flagshipSymbol (count=%s)\n' "$SEARCH_COUNT"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("code-graph-mcp-2: code_search returned 0 matches; expected >= 1")
    printf '  FAIL: code-graph-mcp-2: code_search returned 0 matches; expected >= 1\n'
fi

# Readiness barrier between 3a and 3b. Round 3a's server has already
# exited (bash waited for the whole pipeline), so this normally returns on
# the first probe. Sections 4 and 5 below both depend on this file, so
# establishing it HERE — once, with a message that names the mechanism —
# is what keeps their failures readable.
INDEX_DB="$SAMPLE/.claude/.code-graph/index.db"
if ! wait_for_index "$INDEX_DB"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("code-graph-mcp-2: the lazy build did not persist an index within ${INDEX_WAIT_BUDGET}s (no $INDEX_DB after code_search) — a BUILD FAILURE, not a flake; do not re-run past this")
    printf '  FAIL: code-graph-mcp-2: the lazy build did not persist an index within %ss — expected %s\n' \
        "$INDEX_WAIT_BUDGET" "$INDEX_DB"
    printf '    (code_search returned ok=%s; check %s for indexer errors)\n' \
        "${SEARCH_OK:-<none>}" "$FIXTURE/code-graph-mcp-stderr.log"
else
    # Round 3b — ask health in a FRESH process. One tool call after the
    # handshake means nothing can interleave, so `healthy` here is a
    # statement about the index on disk rather than about scheduling.
    OUT3B="$FIXTURE/round3b.jsonl"
    mcp_call "$OUT3B" \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"l2","version":"0.0.0"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"code_index_health","arguments":{}}}'

    POST_HEALTH=$(grep -F '"id":2' "$OUT3B" | head -1 | jq -r '.result.structuredContent.data.status // ""' 2>/dev/null || echo "")
    assert_eq "code-graph-mcp-2: post-build health reports status=healthy" \
        "healthy" "$POST_HEALTH"
fi

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
#
# Deterministic on both counts. Its input — index.db on disk — was
# established by Section 2's barrier rather than assumed from round 3's
# timing; and round 5 below issues exactly ONE tool call after the
# handshake, so it has no interleaving window of its own (the dxz race
# needed two in-flight requests). $INDEX_DB is set in Section 2.
# --------------------------------------------------------------------------
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
        } | CLAUDE_PROJECT_DIR="$STUB_SAMPLE" node "$STUB_BIN" > "$out_file" 2>"$FIXTURE/code-graph-mcp-stub-stderr.log"
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

    # Now corrupt the stubbed-server's index DB and re-ask health. Same
    # barrier as Section 2 — round 6 built, round 7 observes, and the two
    # are separate processes, so the only question is whether the build
    # landed. Rounds 6 and 7 each issue one tool call, so neither has an
    # interleaving window.
    STUB_INDEX_DB="$STUB_SAMPLE/.claude/.code-graph/index.db"
    if ! wait_for_index "$STUB_INDEX_DB"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("code-graph-mcp-5: the stubbed server's lazy build did not persist an index within ${INDEX_WAIT_BUDGET}s (no $STUB_INDEX_DB) — cannot complete sensitivity check")
        printf '  FAIL: code-graph-mcp-5: stubbed-server lazy build did not persist an index within %ss — expected %s\n' \
            "$INDEX_WAIT_BUDGET" "$STUB_INDEX_DB"
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

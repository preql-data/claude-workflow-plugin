#!/bin/bash
# impact-report.test.sh — L1 unit fixture for .claude/scripts/impact-report.sh
# (G2.n6d / claude-workflow-plugin-llh.2).
#
# The script under test generates the mechanical impact_of artifact the
# QA gate enforces: qa-gate.sh enter invokes it, qa-gate.sh approve
# refuses without a fresh one (the refusal itself is covered at L2 in
# .claude/tests/component/specs/qa-gate.sh, including the strip
# META-TEST). This L1 tier pins the GENERATOR's contract:
#
#   1. The artifact is ALWAYS created; only content degrades.
#      - server absent (bin missing)            -> server:"absent", impact:null
#      - server absent (node missing)           -> server:"absent", impact:null
#      - server unbootable (bin crashes on boot)-> server:"absent", impact:null
#      - server present (real code-graph)       -> server:"code-graph",
#        per-file structuredContent envelopes
#   2. change_set_hash correctness: sha256 over the canonical
#      changed-files list (LC_ALL=C sort -u + the post-edit denylist),
#      byte-identical to what `--hash-only` recomputes (the staleness
#      check in qa-gate.sh approve depends on this equivalence).
#   3. Per-file tool errors are TOLERATED: an entry the server rejects
#      (absolute path outside the project) records {ok:false, error:{...}}
#      for that file while its neighbours still get real impact data and
#      the run exits 0.
#
# The server-present sections drive the REAL code-graph-mcp server from
# this repo over stdio (free, local; no model calls) against a tiny
# 2-file TypeScript fixture — same shape as the L2 component spec
# code-graph-mcp.sh uses. Skip-with-log when node or the server's
# node_modules are unavailable (mirrors that spec's convention).
#
# Exit codes: 0 all assertions pass, 1 otherwise, 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
IR="$PROJECT_DIR/.claude/scripts/impact-report.sh"
MCP_DIR="$PROJECT_DIR/.claude/mcp/code-graph-mcp"
MCP_BIN="$MCP_DIR/bin/code-graph-mcp.js"

if [ ! -f "$IR" ]; then
    printf 'impact-report.test: script under test missing: %s\n' "$IR" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    printf 'impact-report.test: jq is required\n' >&2
    exit 2
fi

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

assert_match() {
    local name="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -qE "$pattern"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    pattern: %s\n    actual:  %s\n' \
            "$name" "$pattern" "$actual"
    fi
}

# sha256 helper mirroring the script's tool-fallback chain so the
# expected-hash computation is portable.
test_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        cat >/dev/null
        printf 'sha256-unavailable'
    fi
}

FIXTURES=()
# cleanup runs only via the EXIT trap below; the static analyzer can't see
# that indirection. Newer shellchecks emit SC2329 on the definition, older
# ones (CI) emit SC2317 on every statement in the body. Suppress both.
# shellcheck disable=SC2329,SC2317
cleanup() {
    local d
    for d in ${FIXTURES[@]+"${FIXTURES[@]}"}; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
}
trap cleanup EXIT

mk_proj() {
    local d
    d=$(mktemp -d -t impact-report-test.XXXXXX)
    FIXTURES+=("$d")
    mkdir -p "$d/.claude/.qa-tracking"
    printf '%s' "$d"
}

# ---------------------------------------------------------------------------
echo "=== Section 1: server absent (bin missing) — artifact still created ==="

F1=$(mk_proj)
# Seed: duplicate entry, denylisted entry, empty line — canonicalisation
# must dedup, filter, and sort (LC_ALL=C; aa < zz in every locale).
printf 'src/zz-dup.ts\nnode_modules/skip.js\n\nsrc/aa-first.ts\nsrc/zz-dup.ts\n' \
    > "$F1/.claude/.qa-tracking/changed-files.txt"

RC1=0
CLAUDE_PROJECT_DIR="$F1" bash "$IR" "task-A.1" >/dev/null 2>&1 || RC1=$?
assert_eq "absent-bin: exit 0" "0" "$RC1"
R1="$F1/.claude/.qa-tracking/impact-report-task-A.1.json"
assert_eq "absent-bin: artifact exists" "0" "$([ -f "$R1" ] && echo 0 || echo 1)"
J1=$(cat "$R1" 2>/dev/null || echo "{}")
assert_eq "absent-bin: server=absent" "absent" "$(printf '%s' "$J1" | jq -r '.server')"
assert_eq "absent-bin: task_id recorded" "task-A.1" "$(printf '%s' "$J1" | jq -r '.task_id')"
assert_match "absent-bin: generated_at is ISO-8601 UTC" \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    "$(printf '%s' "$J1" | jq -r '.generated_at')"
assert_eq "absent-bin: canonical list deduped + denylist-filtered (2 files)" \
    "2" "$(printf '%s' "$J1" | jq -r '.files | length')"
assert_eq "absent-bin: files sorted (aa-first first)" \
    "src/aa-first.ts" "$(printf '%s' "$J1" | jq -r '.files[0].file')"
assert_eq "absent-bin: every impact is null" \
    "2" "$(printf '%s' "$J1" | jq -r '[.files[] | select(.impact == null)] | length')"

# change_set_hash correctness: independent recomputation + --hash-only.
EXPECTED_HASH=$(printf 'src/aa-first.ts\nsrc/zz-dup.ts\n' | test_sha256)
assert_eq "absent-bin: change_set_hash == independent sha256 of canonical list" \
    "$EXPECTED_HASH" "$(printf '%s' "$J1" | jq -r '.change_set_hash')"
HASH_ONLY=$(CLAUDE_PROJECT_DIR="$F1" bash "$IR" --hash-only 2>/dev/null)
assert_eq "absent-bin: --hash-only matches the recorded hash" \
    "$EXPECTED_HASH" "$HASH_ONLY"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: server absent (node hidden) — artifact still created ==="

F2=$(mk_proj)
printf 'src/one.ts\n' > "$F2/.claude/.qa-tracking/changed-files.txt"
# Make the bin EXIST so the node-availability branch (not the bin branch)
# is what fires.
mkdir -p "$F2/stub-mcp"
: > "$F2/stub-mcp/server.js"
RC2=0
CLAUDE_PROJECT_DIR="$F2" CODE_GRAPH_MCP_BIN="$F2/stub-mcp/server.js" \
    IMPACT_REPORT_NODE="/nonexistent/impact-report-test-node" \
    bash "$IR" "task-B.2" >/dev/null 2>&1 || RC2=$?
assert_eq "absent-node: exit 0" "0" "$RC2"
J2=$(cat "$F2/.claude/.qa-tracking/impact-report-task-B.2.json" 2>/dev/null || echo "{}")
assert_eq "absent-node: server=absent" "absent" "$(printf '%s' "$J2" | jq -r '.server')"
assert_eq "absent-node: impact=null" "null" "$(printf '%s' "$J2" | jq -r '.files[0].impact')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: server unbootable (bin crashes) — degrades to absent ==="

if ! command -v node >/dev/null 2>&1; then
    printf 'SKIPPED: section 3 (node not on PATH)\n'
else
    F3=$(mk_proj)
    printf 'src/one.ts\n' > "$F3/.claude/.qa-tracking/changed-files.txt"
    mkdir -p "$F3/bogus-mcp"
    printf 'process.exit(1);\n' > "$F3/bogus-mcp/crash.js"
    RC3=0
    CLAUDE_PROJECT_DIR="$F3" CODE_GRAPH_MCP_BIN="$F3/bogus-mcp/crash.js" \
        IMPACT_REPORT_BOOT_TIMEOUT_S=3 \
        bash "$IR" "task-C.3" >/dev/null 2>&1 || RC3=$?
    assert_eq "unbootable: exit 0" "0" "$RC3"
    J3=$(cat "$F3/.claude/.qa-tracking/impact-report-task-C.3.json" 2>/dev/null || echo "{}")
    assert_eq "unbootable: server=absent" "absent" "$(printf '%s' "$J3" | jq -r '.server')"
    assert_eq "unbootable: impact=null" "null" "$(printf '%s' "$J3" | jq -r '.files[0].impact')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: server PRESENT (real code-graph) — impact data + per-file error tolerance ==="

if ! command -v node >/dev/null 2>&1; then
    printf 'SKIPPED: section 4 (node not on PATH)\n'
elif [ ! -f "$MCP_BIN" ] || [ ! -d "$MCP_DIR/node_modules" ]; then
    # shellcheck disable=SC2016  # backticks are message text, not expansion.
    printf 'SKIPPED: section 4 (code-graph-mcp not installed under %s — run `cd %s && npm install`)\n' \
        "$MCP_DIR" "$MCP_DIR"
else
    F4=$(mk_proj)
    mkdir -p "$F4/.claude/mcp" "$F4/src"
    # Symlink the real server tree; node resolves imports via realpath so
    # src/ and node_modules/ load from the actual install.
    ln -s "$MCP_DIR" "$F4/.claude/mcp/code-graph-mcp"
    cat > "$F4/src/a.ts" <<'TS'
export function flagshipSymbol(): string {
    return "flagship";
}
TS
    cat > "$F4/src/b.ts" <<'TS'
import { flagshipSymbol } from "./a";
export function consumer(): string {
    return flagshipSymbol();
}
TS
    # Tracker mixes: an ABSOLUTE in-project path (must be converted to
    # project-relative), a relative path, and an absolute OUT-OF-PROJECT
    # path (the server rejects absolute seeds -> per-file error).
    printf '%s/src/a.ts\nsrc/b.ts\n/outside/impact-report-test-abs.ts\n' "$F4" \
        > "$F4/.claude/.qa-tracking/changed-files.txt"

    RC4=0
    CLAUDE_PROJECT_DIR="$F4" bash "$IR" "task-D.4" >/dev/null 2>&1 || RC4=$?
    assert_eq "live: exit 0 despite one per-file error" "0" "$RC4"
    R4="$F4/.claude/.qa-tracking/impact-report-task-D.4.json"
    assert_eq "live: artifact exists" "0" "$([ -f "$R4" ] && echo 0 || echo 1)"
    J4=$(cat "$R4" 2>/dev/null || echo "{}")
    assert_eq "live: server=code-graph" "code-graph" "$(printf '%s' "$J4" | jq -r '.server')"
    assert_eq "live: all 3 files present in report" "3" "$(printf '%s' "$J4" | jq -r '.files | length')"

    # Per-file error tolerated: the out-of-project absolute path is
    # rejected by the server's validation, recorded, run continued.
    ERR_MSG=$(printf '%s' "$J4" | jq -r '.files[] | select(.file == "/outside/impact-report-test-abs.ts") | .impact.error.message // empty')
    assert_match "live: rejected entry carries impact.error.message" \
        'project-relative' "$ERR_MSG"

    # The absolute in-project entry was converted to a relative seed and
    # produced REAL graph data: b.ts imports a.ts -> 1 file dependent,
    # and consumer() calls flagshipSymbol() -> at least 1 caller node
    # beyond the seeds.
    A_OK=$(printf '%s' "$J4" | jq -r --arg f "$F4/src/a.ts" '.files[] | select(.file == $f) | .impact.ok')
    assert_eq "live: in-project absolute entry resolved (impact.ok=true)" "true" "$A_OK"
    A_DEPS=$(printf '%s' "$J4" | jq -r --arg f "$F4/src/a.ts" '.files[] | select(.file == $f) | .impact.data.file_dependents | length')
    assert_eq "live: a.ts has 1 file-level dependent (b.ts imports it)" "1" "$A_DEPS"
    A_CALLERS=$(printf '%s' "$J4" | jq -r --arg f "$F4/src/a.ts" '.files[] | select(.file == $f) | [.impact.data.nodes[] | select(.relation == "caller")] | length')
    assert_match "live: a.ts has >=1 transitive caller (consumer)" '^[1-9][0-9]*$' "$A_CALLERS"

    B_OK=$(printf '%s' "$J4" | jq -r '.files[] | select(.file == "src/b.ts") | .impact.ok')
    assert_eq "live: relative entry resolved (impact.ok=true)" "true" "$B_OK"

    # Hash agreement under the live fixture too.
    H4_REPORT=$(printf '%s' "$J4" | jq -r '.change_set_hash')
    H4_NOW=$(CLAUDE_PROJECT_DIR="$F4" bash "$IR" --hash-only 2>/dev/null)
    assert_eq "live: change_set_hash matches --hash-only" "$H4_NOW" "$H4_REPORT"

    # No orphaned server process: the script must reap its own child
    # (macOS FIFO/kqueue EOF quirk is handled via explicit SIGTERM).
    ORPHANS=$(pgrep -f "$F4/.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "live: no orphaned server process" "0" "$ORPHANS"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: empty change set — artifact with files=[] ==="

F5=$(mk_proj)
# No changed-files.txt at all.
RC5=0
CLAUDE_PROJECT_DIR="$F5" bash "$IR" "task-E.5" >/dev/null 2>&1 || RC5=$?
assert_eq "empty: exit 0" "0" "$RC5"
J5=$(cat "$F5/.claude/.qa-tracking/impact-report-task-E.5.json" 2>/dev/null || echo "{}")
assert_eq "empty: files=[]" "0" "$(printf '%s' "$J5" | jq -r '.files | length')"
EMPTY_HASH=$(printf '' | test_sha256)
assert_eq "empty: hash of empty canonical list" \
    "$EMPTY_HASH" "$(printf '%s' "$J5" | jq -r '.change_set_hash')"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

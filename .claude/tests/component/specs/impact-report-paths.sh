# impact-report-paths.sh — L2 component spec for impact-report.sh path
# relativisation (regression for preql-backend-9n5 / claude-workflow-plugin).
#
# Background: impact-report.sh feeds each changed file to the code-graph
# `impact_of` tool, whose validator REJECTS absolute paths ("file must be
# a project-relative path, not absolute"; see code-graph-mcp src/lib/
# validate.js). The index keys files relative to the project root. The
# previous code stripped only a literal "$PROJECT_DIR/" prefix, so the
# moment the changed-files list contained a path under a SIBLING WORKTREE,
# a DIFFERENT repo, or non-git scratch (/tmp, ~/.claude) the path stayed
# absolute and the call errored. Observed live (preql-backend-c0l QA): the
# report was hash-valid with server=code-graph but every one of 29 files
# carried {ok:false, error:"...not absolute"} — zero usable caller data.
#
# This spec injects a STUB code-graph server (via the documented
# CODE_GRAPH_MCP_BIN / IMPACT_REPORT_NODE hooks) that enforces the SAME
# absolute-path rejection as the real server and records every `file` arg
# it receives. It then asserts:
#
#   1. No per-file impact entry carries the absolute-path validation error.
#   2. Every `file` arg the stub actually received is project-relative.
#   3. A file under the analyzed project itself relativises to a real
#      ok:true impact entry.
#   4. A file under a SIBLING WORKTREE of the same repo also relativises
#      to a real ok:true entry (this is the case the old prefix-strip
#      missed entirely).
#   5. A file in a foreign repo / non-git scratch is recorded as an
#      explicit skip and is NOT sent to impact_of.
#   6. The change_set_hash is byte-for-byte what --hash-only reports
#      (the canonicalisation the gate's freshness check depends on is
#      untouched by the path fix).
#
# What this spec does NOT cover: the real index build, server boot at
# scale, or the gate's pass/fail wiring (qa-gate.sh spec owns that).

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

IR_SCRIPT="$FIXTURE/.claude/scripts/impact-report.sh"
NODE_BIN="${IMPACT_REPORT_NODE:-node}"

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    printf 'SKIP: node not on PATH — cannot run the stub code-graph server\n' >&2
    return 0 2>/dev/null || exit 0
fi
if [ ! -f "$IR_SCRIPT" ]; then
    printf 'SKIP: impact-report.sh not present in fixture at %s\n' "$IR_SCRIPT" >&2
    return 0 2>/dev/null || exit 0
fi

# --- turn the fixture into a real git repo + a sibling worktree ----------
# mk_fixture does not git-init; the path fix is git-driven, so build the
# topology here. PROJECT is the analyzed checkout (== CLAUDE_PROJECT_DIR);
# WORKTREE is a sibling worktree of the SAME repo; FOREIGN is a different
# repo; SCRATCH is a non-git directory.
PROJECT="$FIXTURE"
SANDBOX=$(dirname "$FIXTURE")
WORKTREE="$SANDBOX/$(basename "$FIXTURE")-feature"
FOREIGN="$SANDBOX/foreign-repo-$$"
SCRATCH="$SANDBOX/scratch-$$"

mkdir -p "$PROJECT/src/configs"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email t@t.t
git -C "$PROJECT" config user.name t
printf 'export const A = 1;\n' > "$PROJECT/src/configs/env.validation.ts"
printf 'export const main = 1;\n' > "$PROJECT/src/main.ts"
# Keep the bd/.claude scaffolding out of the commit; we only need the src.
git -C "$PROJECT" add src >/dev/null 2>&1
git -C "$PROJECT" commit -qm init >/dev/null 2>&1
git -C "$PROJECT" worktree add -q "$WORKTREE" -b feature >/dev/null 2>&1

mkdir -p "$FOREIGN/apps/web"
git -C "$FOREIGN" init -q
git -C "$FOREIGN" config user.email t@t.t
git -C "$FOREIGN" config user.name t
printf 'export const x = 1;\n' > "$FOREIGN/apps/web/Component.tsx"
git -C "$FOREIGN" add -A >/dev/null 2>&1
git -C "$FOREIGN" commit -qm init >/dev/null 2>&1

mkdir -p "$SCRATCH"
printf 'print(1)\n' > "$SCRATCH/api.py"

cleanup_paths() {
    git -C "$PROJECT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
    rm -rf "$FOREIGN" "$SCRATCH"
}
trap cleanup_paths RETURN 2>/dev/null || true

# --- changed-files.txt: the exact path-shape mix from the c0l failure ----
TRACK="$PROJECT/.claude/.qa-tracking"
mkdir -p "$TRACK"
RECEIVED="$SANDBOX/received-$$.txt"
: > "$RECEIVED"
{
    printf '%s\n' "$PROJECT/src/configs/env.validation.ts"   # project itself
    printf '%s\n' "$WORKTREE/src/main.ts"                     # sibling worktree, same repo
    printf '%s\n' "$FOREIGN/apps/web/Component.tsx"           # foreign repo
    printf '%s\n' "$SCRATCH/api.py"                           # non-git scratch
} > "$TRACK/changed-files.txt"

# --- stub code-graph MCP server (mirrors lib/validate.js + findFile) -----
STUB="$SANDBOX/stub-code-graph-$$.js"
cat > "$STUB" <<'STUBEOF'
const fs = require('fs');
const RECEIVED = process.env.STUB_RECEIVED_FILE;
let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => {
  buf += d;
  let nl;
  while ((nl = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    if (!line.trim()) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.method === 'initialize') {
      send({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: '2024-11-05', capabilities: {}, serverInfo: { name: 'stub-code-graph', version: '0.0.0' } } });
      continue;
    }
    if (msg.method === 'notifications/initialized') continue;
    if (msg.method === 'tools/call' && msg.params && msg.params.name === 'impact_of') {
      const file = (msg.params.arguments || {}).file;
      if (RECEIVED) { try { fs.appendFileSync(RECEIVED, String(file) + '\n'); } catch {} }
      if (typeof file === 'string' && (file.startsWith('/') || file.startsWith('\\') || /^[A-Za-z]:/.test(file))) {
        send({ jsonrpc: '2.0', id: msg.id, result: { structuredContent: { ok: false, error: { message: 'file must be a project-relative path, not absolute: ' + JSON.stringify(file), hint: 'Strip the leading separator.' } } } });
        continue;
      }
      const root = (process.env.CLAUDE_PROJECT_DIR || process.cwd()).replace(/\/+$/, '');
      if (fs.existsSync(root + '/' + file)) {
        send({ jsonrpc: '2.0', id: msg.id, result: { structuredContent: { ok: true, headline: 'impact_of ' + file, data: { seed: { kind: 'file', value: file }, nodes: [{ name: 'CALLER', file: file, depth: 1, relation: 'caller' }], file_dependents: [] } } } });
      } else {
        send({ jsonrpc: '2.0', id: msg.id, result: { structuredContent: { ok: true, headline: 'impact_of: file ' + JSON.stringify(file) + ' is not in the index', data: { seed: { kind: 'file', value: file }, nodes: [], file_dependents: [] } } } });
      }
      continue;
    }
    send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'method not found' } });
  }
});
function send(obj) { process.stdout.write(JSON.stringify(obj) + '\n'); }
STUBEOF

# --- run the script under test ------------------------------------------
REPORT="$TRACK/impact-report-paths9n5.json"
IR_RC=0
CLAUDE_PROJECT_DIR="$PROJECT" \
CODE_GRAPH_MCP_BIN="$STUB" \
IMPACT_REPORT_NODE="$NODE_BIN" \
STUB_RECEIVED_FILE="$RECEIVED" \
IMPACT_REPORT_BOOT_TIMEOUT_S=15 \
IMPACT_REPORT_FIRST_CALL_TIMEOUT_S=15 \
IMPACT_REPORT_CALL_TIMEOUT_S=15 \
    bash "$IR_SCRIPT" paths9n5 >/dev/null 2>"$SANDBOX/run-$$.log" || IR_RC=$?

assert_eq "impact-report-paths: script exits 0" "0" "$IR_RC"

SERVER=$(jq -r '.server' "$REPORT" 2>/dev/null || echo "")
if [ "$SERVER" = "absent" ]; then
    printf 'SKIP: stub code-graph server did not boot in this environment (server=absent)\n' >&2
    tail -5 "$SANDBOX/run-$$.log" >&2 2>/dev/null || true
    return 0 2>/dev/null || exit 0
fi

# 1. No entry carries the absolute-path validation error.
ABS_ERRORS=$(jq '[.files[] | select((.impact.error.message // "") | test("project-relative path, not absolute"))] | length' "$REPORT" 2>/dev/null)
assert_eq "impact-report-paths: zero absolute-path validation errors" "0" "${ABS_ERRORS:-x}"

# 2. Every path the stub received is project-relative (no leading slash).
ABS_RECEIVED=$(grep '^/' "$RECEIVED" 2>/dev/null | wc -l | tr -d '[:space:]')
RECV_TOTAL=$(grep -c . "$RECEIVED" 2>/dev/null | tr -d '[:space:]')
assert_eq "impact-report-paths: no absolute path handed to impact_of" "0" "${ABS_RECEIVED:-x}"
assert_eq "impact-report-paths: exactly the 2 in-project files were sent" "2" "${RECV_TOTAL:-x}"

# 3. The project's own file resolves to a real ok:true entry.
PROJ_OK=$(jq -r '[.files[] | select((.file | endswith("src/configs/env.validation.ts")) and .impact.ok == true and ((.impact.data.nodes // []) | length) > 0)] | length' "$REPORT" 2>/dev/null)
assert_eq "impact-report-paths: in-project file resolves to real impact data" "1" "${PROJ_OK:-x}"

# 4. The sibling-worktree file resolves to a real ok:true entry (the case
#    the old literal-prefix strip missed).
WT_OK=$(jq -r '[.files[] | select((.file | endswith("-feature/src/main.ts")) and .impact.ok == true and ((.impact.data.nodes // []) | length) > 0)] | length' "$REPORT" 2>/dev/null)
assert_eq "impact-report-paths: sibling-worktree file resolves to real impact data" "1" "${WT_OK:-x}"

# 5. Foreign-repo + scratch files are recorded as explicit skips, not sent.
FOREIGN_SKIP=$(jq -r '[.files[] | select((.file | test("foreign-repo|scratch-")) and (.impact.error.message // "" | test("outside the analyzed project")))] | length' "$REPORT" 2>/dev/null)
assert_eq "impact-report-paths: foreign/scratch files recorded as out-of-project skips" "2" "${FOREIGN_SKIP:-x}"

# 6. change_set_hash matches --hash-only (gate freshness contract intact).
RECORDED_HASH=$(jq -r '.change_set_hash // empty' "$REPORT" 2>/dev/null)
HASH_ONLY=$(CLAUDE_PROJECT_DIR="$PROJECT" bash "$IR_SCRIPT" --hash-only 2>/dev/null)
assert_eq "impact-report-paths: change_set_hash matches --hash-only" "$HASH_ONLY" "$RECORDED_HASH"

rm -f "$STUB" "$RECEIVED" "$SANDBOX/run-$$.log" 2>/dev/null || true

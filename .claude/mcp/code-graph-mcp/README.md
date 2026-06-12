# code-graph-mcp

A tree-sitter + SQLite code-graph MCP server. Replaces the
regex-search-backed `code-context-mcp` (J30 simpler variant, retired
in 3.3.0) while preserving the stable tool surface — `code_search` and
`code_context` are byte-compatible on inputs and on documented output
fields (the `tool` / `backend` value changes from `"git-grep"` to
`"graph-index"`, called out inline in each tool's description). The
third stable name, `code_index_health`, is intentionally an **Add**
rather than byte-compat: the old engine reported git-grep health
(presence, repo root); the new engine reports staleness, per-language
coverage, last index time, and DB size. No live plugin or doc consumer
read the old health fields, so there is zero breakage today — the
schema change is documented as a richer Add, not a backwards-incompatible
swap. Four impact-analysis tools are new: `symbol_callers`, `impact_of`,
`dead_code`, `dependency_path`. Phase B of the verification-suite
v3.3.0 plan.

## Tools

| Name | Summary | Input shape | Side effects |
|---|---|---|---|
| `code_search` | String / regex search; indexed identifier fast path | `{query, max_results?, regex?, cwd?}` | None; reads + builds the index lazily on first call |
| `code_context` | Definition + usage sites for a symbol (semantic, not heuristic) | `{symbol, max_results?, cwd?}` | None; same lazy-build trigger |
| `symbol_callers` | Direct (one-hop) callers of a symbol | `{symbol, cwd?}` | None |
| `impact_of` | Transitive callers + file dependents for a symbol or file | `{symbol? \| file?, max_depth?, cwd?}` | None |
| `dead_code` | Unreferenced exports within a scope | `{scope?, cwd?}` | None |
| `dependency_path` | Shortest call chain from one symbol to another | `{from, to, cwd?}` | None |
| `code_index_health` | Status / drift / coverage / index size | `{cwd?}` | None |

Every tool returns `ok()` with `data` plus a free-form `llm_observations`
string (per v3 principle #9). All tools set `readOnlyHint: true`,
`destructiveHint: false`, `idempotentHint: true`. Every tool except
`code_index_health` sets `openWorldHint: true` (they read filesystem
content). Errors include both a `hint:` line ("what to do") and an
`example:` line (a worked valid call) so a self-correcting agent can
retry without a human round-trip — the bd-mcp convention.

## Configuration

| Variable / file | Purpose |
|---|---|
| `CLAUDE_PROJECT_DIR` | The project root the index covers; set by Claude Code per the docs (spec item 0.1) |
| `CODE_GRAPH_CWD` | Override the cwd resolution from the test harness |
| `grammars/*.wasm` | Vendored tree-sitter grammars; provenance in `grammars/MANIFEST.md` |
| `.claude/.code-graph/index.db` | Per-project SQLite index file; created lazily on first tool call |
| `npm install` | Pulls `web-tree-sitter` (wasm), `sql.js` (wasm), `@modelcontextprotocol/sdk`, `zod`. The plugin installer runs this automatically |
| `npm test` | Runs the node:test suite (indexer, tools, protocol-level validation) |

### Dependency picks

**SQLite via `sql.js`** (wasm). Node 22+ ships a built-in `node:sqlite`
that would be faster, but the plugin's Node floor is 18.17. `sql.js`
needs no native compile, works on the same floor, and is comfortably
fast for the index sizes we produce (a few MB on large polyglot
repos).

**Parsers via `web-tree-sitter`** (wasm) with **vendored** grammars.
We commit 10 `.wasm` files (~9.6 MB total) under `grammars/` from
`@vscode/tree-sitter-wasm@0.3.1` so the server has zero external fetch
at runtime. The legacy `tree-sitter-wasms@0.1.13` aggregator is
incompatible with web-tree-sitter 0.26+ because it produces the
older `dylink` custom-section name (web-tree-sitter expects
`dylink.0`); see `grammars/MANIFEST.md` for the full provenance table.

### Language coverage (honest matrix)

| Language | Defs (functions / classes / types) | Calls (call expressions) | Imports (resolved to local file?) |
|---|---|---|---|
| TypeScript / TSX | yes (incl. interfaces, type aliases, enums, exports) | yes (incl. new + method invocations) | `./*` relative imports → resolved against common extensions / index files |
| JavaScript (and JSX) | yes (incl. CJS `module.exports`) | yes | `./*` relative imports + `require('./*')` → resolved |
| Python | yes (`def`, `class`, top-level assignments) | yes | dotted modules → mapped to `module/path.py` or `__init__.py` |
| Go | yes (incl. methods, type specs, consts/vars) | yes (incl. selector method calls) | package paths recorded by name; not resolved to local files (requires module-aware logic) |
| Rust | yes (fn, struct, enum, trait, impl, mod, const, static) | yes (incl. macro invocations) | `use` paths recorded by name; not resolved |
| Java | yes (class, interface, method, constructor, enum) | yes (incl. `new`) | scoped imports recorded by name; not resolved |
| Ruby | yes (`def`, `class`, `module`, constants) | yes (`call` node only — `method_call` was removed from tree-sitter-ruby 0.23.x) | `require`/`require_relative` paths resolved to `.rb` |
| PHP | yes (function, class, interface, trait, method) | yes (incl. `new`) | `use` + `require`/`include` recorded; not resolved |
| Bash | yes (function definitions, variable assignments) | yes (commands) | `source` / `.` recorded |

What the static graph CANNOT see (echoed in the tool descriptions
themselves so callers learn the limits inline):

- Dynamic dispatch (`obj[method]()`, `Reflect.apply`, `eval`).
- Reflection / metaprogramming (Python `__getattr__`, Ruby
  `method_missing`, decorator rewriting).
- Macro expansion — only the pre-expansion form is visible.
- Renaming re-exports (`export { foo as bar }` chains).
- External library calls / packages.

`dead_code` carries an extra-loud caveat block (re-exports, externally
consumed surface, dynamic dispatch all look dead) — it is a starting
point for cleanup, not a proof.

### Synthetic `<module>` symbol

Every file that has any top-level call statement (a call outside any
function/method/class body) gets a synthetic `kind: "module"` symbol
named `<module>` at line 1, owning that file's top-level calls. This
keeps `impact_of({file})` returning a coherent dependent set when the
file's entry point is module-level code (Python scripts that `if
__name__ == "__main__":`, JS bootstrappers that call `start()` at the
top, bash scripts that just run commands). It is a defensible UX
surprise — callers querying `code_context({symbol: "<module>"})` get
exactly one match per file with top-level calls — so the README calls
it out rather than hiding it.

### `dead_code` scope semantics (trailing slash)

The `scope` parameter is a SQL `LIKE` prefix against the file path
relative to the project root. The match is literal — passing
`scope: "src"` matches both `src/foo.ts` AND `src-other/bar.ts`,
because both start with `src`. Pass `scope: "src/"` (with the
trailing slash) to scope to the directory only. This is the same
prefix-match shape `git ls-files :(top)src` uses; the trailing-slash
convention is documented inline in the tool description so the agent
gets the disambiguation hint without leaving the call site.

## Integration

| Workflow step | Tool calls | Purpose |
|---|---|---|
| Orchestrator decomposition | `code_search` / `code_context` / `impact_of` | Pre-load relevant call sites + impacted symbols into the SPEC doc before delegating to a specialist |
| Specialist work | `code_context`, `symbol_callers` | Identify the exact call sites the change touches; check dynamic-dispatch caveats from the limits matrix |
| QA regression assessment | `impact_of` per changed symbol, `dependency_path` for critical paths | High fan-in seeds become mandatory regression candidates (extends J19); shortest-path queries confirm whether a changed symbol reaches a target subsystem |
| Cleanup epics | `dead_code` | Find candidate unreferenced exports per scope; never auto-delete — always human-verified |

The plugin's `.mcp.json` (and `.claude-plugin/plugin.json`) wires this
server as `code-graph` in place of the retired `code-context-mcp` (B.2
landed alongside B.1; both manifests agree). The stable surface
(`code_search` / `code_context`) is byte-compatible on inputs and on
documented output fields, so existing prompts and hooks that branch
on those tools' results continue to work; `code_index_health`'s
output schema is an Add (richer status fields), not a byte-compat
preservation. The non-stable surface (`symbol_callers`, `impact_of`,
`dead_code`, `dependency_path`) is **new** and unlocks the
impact-analysis workflows the verification-suite plan calls for.

`symbol_callers` is the only tool that was previously hinted at via
the `_phase7_codebase_graph_target.tools_to_expose` placeholder block
in `.mcp.json` but **not implemented** in the old `code-context-mcp`.
It is new with this server.

## Testing

```bash
cd .claude/mcp/code-graph-mcp
npm install
npm test
```

The suite is three files under `tests/`:

- `tests/indexer.test.js` — indexer correctness on the committed
  polyglot fixtures (`tests/fixtures/polyglot/`): cross-file
  resolution for `getCurrentTask`, incremental rebuild fires only on
  hash change, pruning drops deleted files, smoke defs for every
  supported language, and the `CORRUPT_INDEX` contract that
  `code_index_health` relies on.
- `tests/tools.test.js` — every tool over the same fixtures, driven
  via the MCP in-memory transport pair. Asserts the byte-compatible
  surface for `code_search` / `code_context`, the `code_index_health`
  Add schema, the new-stable tools' happy paths and error branches,
  and the seeded-orphan `dead_code` detection. 15 tests.
- `tests/server.test.js` — protocol-level Zod validation + error-shape
  asserts (oversized query, malformed symbol, missing seed in
  `impact_of`, etc.). 9 tests.

Total: **31 tests** (7 indexer + 15 tools + 9 server), ~1.5s wall-clock
on a modern laptop.

The L2 component spec at
`.claude/tests/component/specs/code-graph-mcp.sh` covers the boot
contract: stdio initialize, tools/list returns the 7 declared tools
with informative schemas, malformed args surface `hint:`+`example:`
envelopes, and a META-TEST that corrupts the index DB and asserts
`code_index_health` flips to `unhealthy` (with a sensitivity check
that the assertion fails when the detection branch is stubbed).

Manual smoke (run from the plugin repo root):

```bash
(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0.0.0"}}}'
 sleep 0.1
 printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
 sleep 0.1
 printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"code_search","arguments":{"query":"buildServer","max_results":5}}}'
 sleep 30) \
 | CLAUDE_PROJECT_DIR=$(pwd) node .claude/mcp/code-graph-mcp/bin/code-graph-mcp.js
```

Verified output excerpt (boot in ~110 ms; first index build of the
plugin repo in ~3 s). The example was recorded during B.1 before B.2
deleted `code-context-mcp/`; on the post-3.3.0 tree this same query
returns 2 matches (bd-mcp + code-graph-mcp). The structural shape is
the point, not the exact match count:

```json
{"result":{"content":[{"type":"text","text":"code_search via graph-index: 2 symbol match(es) for \"buildServer\"\n\n{ ... \"matches\": [\n    {\"file\":\".claude/mcp/bd-mcp/src/server.js\",\"line\":43,\"snippet\":\"export function buildServer() {\"},\n    {\"file\":\".claude/mcp/code-graph-mcp/src/server.js\",\"line\":42,\"snippet\":\"export function buildServer() {\"}\n  ]\n}\n..."}], "structuredContent": {"ok":true, ...}}}
```

## Before/after token comparison (offline, output-size proxy)

Spec Phase B acceptance line: "Document a before/after token comparison
for one orchestrator decomposition (exploration with `code_context` only
vs with `impact_of`) — measured once; keep the raw numbers."

**Decomposition target.** Change `qa-gate.sh`'s `grade-record` action
format. The orchestrator needs to know what is affected — which callers,
which test files, which downstream scripts read the grader output the
action produces. The change unit is the `cmd_grade_record` bash function
in `.claude/scripts/qa-gate.sh`.

**Method.** Measured offline by running the new server's tools and
counting the byte size of their JSON outputs, then computing the
file-read cost an orchestrator would pay to discover the same caller
set without `impact_of`. No live model inference, no paid call. Tokens
are bytes divided by 4 — conservative for JSON, approximately right for
source code. The caveat is honest: this is an output-size proxy, not a
live-session token bill. The BEFORE figure assumes a perfect orchestrator
picks exactly the right files to Read; a real orchestrator without
`impact_of` would over-read or under-read.

**Raw numbers (measured 2026-06-12 against this repo, commit on `main`).**

| Step | BEFORE (code_context only + file reads) | AFTER (code_context + impact_of) |
|---|---|---|
| `code_search({query: "cmd_grade_record", max_results: 20})` | 1,308 bytes | 1,308 bytes |
| `code_context({symbol: "cmd_grade_record", max_results: 20})` | 2,356 bytes | 2,356 bytes |
| `impact_of({file: ".claude/scripts/qa-gate.sh", max_depth: 5})` | — | 80,778 bytes |
| Manual file reads (23 files in the caller set, summed sizes) | 256,080 bytes | — |
| **Total** | **259,744 bytes (~64,936 tokens)** | **84,442 bytes (~21,111 tokens)** |

**Delta: 175,302 bytes / ~43,825 tokens saved, or 67.5 % reduction.**
The savings come from replacing manual file reads (256 KB across 23
files) with one structured `impact_of` JSON response (81 KB containing
the same caller graph). For larger change units — anything touching a
function with 50+ callers across the test suite — the ratio scales the
same way; for trivial changes where the caller set is one or two files,
the manual-read path is already small and the savings are minor (the
orchestrator's degradation-to-search heuristic catches that case in
section 1a of `orchestrator.md`).

What the comparison does NOT measure: the conversation token bill of
the orchestrator's reasoning over the outputs. A model reading 256 KB
of source code spends more reasoning tokens than reading 81 KB of
structured JSON, so the live-bill ratio is likely even more favourable
to `impact_of`, but quantifying that is a paid-run question — out of
scope for an offline measurement.

## Limits / non-goals

- **No external resolution.** Imports from npm packages, Go modules,
  Maven artifacts, Cargo crates, etc. are recorded by name only. The
  graph stays inside the project tree.
- **Best-effort name binding only.** `edges.dst_symbol_id` is bound
  when exactly one symbol has the matching name in the index, OR
  when multiple match but exactly one lives in the caller's file. All
  other name collisions stay unresolved — surfaced in the output as
  `resolved: false`, never silently picked.
- **No language server.** No type inference, no overload resolution,
  no rename refactoring. Use a real LSP for those.
- **Indexer is single-threaded.** Tree-sitter via wasm is roughly
  10–30× slower than native bindings (per its own README). For
  the index sizes we expect (small polyglot projects to medium
  monorepos), single-threaded indexing is fine — a few seconds at
  most. If a future Phase needs the speed, swap `web-tree-sitter` for
  the node-gyp `tree-sitter` binding without touching the rest of the
  indexer.
- **Lazy-build means cold first tool call is slow.** Subsequent calls
  hit the warm index in milliseconds; the initial build is the only
  expensive one. Hooks that latency-budget tool calls should bake the
  cold start into their timeouts.
- **No write tools.** This server only reads code and writes the
  index DB; it never mutates source files.
- **Single project per server.** The `cwd` parameter lets a caller
  override per call, but the indexed graph belongs to one project at
  a time. Multi-project / cross-repo graphs would need a different
  schema and are explicitly out of scope.

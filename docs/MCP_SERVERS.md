# MCP Servers

The plugin ships two project-scoped MCP servers under `.claude/mcp/`. Both are wired in `.mcp.json` (and mirrored in `.claude-plugin/plugin.json`) so a Claude Code session inside the plugin's repo gets them automatically.

| Server | Path | Purpose | Tools | README |
|---|---|---|---|---|
| `bd` | `.claude/mcp/bd-mcp/` | Beads issue tracker as native MCP tools | 21 | [bd-mcp/README.md](../.claude/mcp/bd-mcp/README.md) |
| `code-graph` | `.claude/mcp/code-graph-mcp/` | Tree-sitter + SQLite code-graph (search, definitions, callers, transitive impact, dead-code, dependency paths, index health) | 7 | [code-graph-mcp/README.md](../.claude/mcp/code-graph-mcp/README.md) |

Both servers use stdio transport. Both are stateless across invocations (the Beads tools mutate the local `.beads/` database; the code-graph tools read source files and maintain a per-project SQLite index at `.claude/.code-graph/index.db`, gitignored).

## How they work in concert

The two servers slot into the orchestrator -> specialist -> QA flow at three key moments:

1. **Orchestrator decomposition (pre-delegation).** When the orchestrator plans an epic or any non-trivial change, before spawning a specialist it calls `code_search` / `code_context` for the symbols the change is likely to touch *and* `impact_of({symbol})` (or `impact_of({file})`) to surface transitive callers and dependent files. The result lands in the SPEC doc via `bd_doc_write({task_id, name: "spec", ...})` so the specialist starts from full context — no re-discovery, and no surprise from a high-fan-in caller the orchestrator forgot to mention. The `impact_of` query is conditional on the server being available so a target project that has not yet installed code-graph degrades gracefully to the search-only flow.

2. **Specialist claim + completion.** A specialist calls `bd_doc_read({task_id, name: "spec"})` to fetch the SPEC, `bd_update_task({task_id, status: "in_progress"})` to claim, and on completion `bd_qa_enter` then `bd_add_label("qa-pending")`. During the work, specialists query `code_context({symbol})` and `symbol_callers({symbol})` to identify the exact call sites a change touches. The completion contract from F7 — `{task_id, files_changed[], tests_added[], decisions[], blockers[], llm_observations}` — flows back through `bd_update_task --notes` (or via a new versioned doc).

3. **QA regression assessment (extends J19).** The QA agent pulls the diff via `git diff -- $(cat .claude/.qa-tracking/changed-files.txt)` and, for every changed symbol, calls `impact_of({symbol})`. High-fan-in hits are mandatory regression candidates — QA inspects (or runs) their tests as part of the gate, not just the tests that ship in the diff. The full test suite still runs (J19's anti-scope-creep rule), but the impact graph is what tells QA *which* of the existing tests are the highest-value ones to read before approving. Pairs with `verify-before-stop.sh`'s J19 framing (the gate runs the FULL test suite each iteration, not just tests for files in the diff). On approval, `bd_qa_approve` is one atomic call (label add + label removes + comment + memory write) — no manual sequencing. The grader (Phase A) is unaffected by code-graph; its packet is the SPEC doc, the diff, the F7 contract, LESSONS.md, and the applicable rubric files, period.

## Testing MCP Servers

The e2e harness exercises both servers end-to-end via the manual, invariant-based live tier (see [`.claude/tests/README.md`](../.claude/tests/README.md)). Each of the six live fixtures runs against the real orchestrator, specialist, and QA agents — and those agents call `bd_*`, `code_search`, `code_context`, and (post-3.3.0) `impact_of` tools through the real MCP stdio transport. The trace records every tool invocation with normalised payloads, and the spec invariants assert workflow contract properties (orchestrator never edits; QA approval gates Stop; declared specialists are the only ones invoked) — properties that hold across model versions by construction, so a regression in either MCP server's surface surfaces as an invariant violation rather than a golden-cassette diff.

Concrete example: when the orchestrator decomposes the `node-react-auth` fixture's prompt, it calls `code_context({symbol: "createApp"})` *and* `impact_of({symbol: "createApp"})` against the fixture's `server/index.js` (where `createApp` is the Express app factory the new `/auth/login` endpoint hangs off of) before creating subtasks, so the specialist that picks up "Backend: implement /auth/login" reads a SPEC doc pre-loaded with the live call sites and the transitive-caller set. The fixture's `invariants:` block declares `qa-queried-impact-of` (see `.claude/tests/e2e/lib/invariants.ts`), which asserts the QA subagent issued at least one `impact_of` call when the run produced any file writes — the strongest form the trace schema can verify today. Per-symbol coverage ("for every changed symbol in the diff") waits on a Trace-schema extension that records the diff's symbol set; the docstring documents the approximation honestly.

The bd-mcp side has the same coverage: every `bd_create_epic`, `bd_update_task`, `bd_qa_enter`, `bd_qa_approve` call lands in the trace. The Beads label progression invariant (`expected_label_progression` in `fixture.yaml`) catches regressions in the gate's atomic multi-label flips.

## Wiring summary

The plugin ships two parallel MCP manifests. Each scope uses a different variable form because Claude Code expands variables differently in each.

`.mcp.json` (project-scoped, applies to anyone who opens the plugin's repo in Claude Code) uses `${CLAUDE_PROJECT_DIR:-.}`:

```json
{
  "mcpServers": {
    "bd":         { "type": "stdio", "command": "node",
                    "args": ["${CLAUDE_PROJECT_DIR:-.}/.claude/mcp/bd-mcp/bin/bd-mcp.js"] },
    "code-graph": { "type": "stdio", "command": "node",
                    "args": ["${CLAUDE_PROJECT_DIR:-.}/.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js"] }
  }
}
```

The `:-.` default is required. Per the Claude Code MCP docs ([code.claude.com/docs/en/mcp](https://code.claude.com/docs/en/mcp)), `CLAUDE_PROJECT_DIR` is set in the *spawned MCP server's* environment, not in Claude Code's own environment — so a bare `${CLAUDE_PROJECT_DIR}` in a project-scoped `.mcp.json` is unresolved at substitution time and produces an MCP-diagnostics warning ("Missing environment variables: CLAUDE_PROJECT_DIR"). The `:-.` default falls back to the current working directory (which is the project root when Claude Code starts), which resolves the warning without changing semantics.

`.claude-plugin/plugin.json` (the plugin manifest, applies when the plugin is loaded as a plugin) uses bare `${CLAUDE_PLUGIN_ROOT}`:

```json
{
  "mcpServers": {
    "bd":         { "type": "stdio", "command": "node",
                    "args": ["${CLAUDE_PLUGIN_ROOT}/.claude/mcp/bd-mcp/bin/bd-mcp.js"] },
    "code-graph": { "type": "stdio", "command": "node",
                    "args": ["${CLAUDE_PLUGIN_ROOT}/.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js"] }
  }
}
```

Plugin-scope manifests substitute `${CLAUDE_PLUGIN_ROOT}` (and `${CLAUDE_PROJECT_DIR}`) directly per the docs, so the default form is not required here.

The two manifests should always agree on server set and tool surface; if you change one, change the other in the same commit. The L2 spec `.claude/tests/component/specs/installer-mcp-config.sh` enforces this for the rendered install (no bare `${VAR}` references, both servers wired, the retired `code-context` entry absent).

## Migration from code-context-mcp (3.3.0)

Phase B of the verification-suite plan (v3.3.0) retired `code-context-mcp` and replaced it with `code-graph-mcp`. Concretely, what changed:

- **Removed:** `.claude/mcp/code-context-mcp/` and the `code-context` entry in both `.mcp.json` and `.claude-plugin/plugin.json`. The `_phase7_codebase_graph_target` placeholder block in `.mcp.json` is gone now that it is filled.
- **Stable surface is byte-compatible on inputs and on documented output fields.** `code_search` and `code_context` keep their input schemas (`query` / `symbol` / `max_results` / `regex` / `cwd`) and their primary output keys. The `tool` / `backend` value strings change (`"git-grep"` -> `"graph-index"`) to make the new engine visible in tool output — described inline in the tool descriptions so downstream callers know what is and is not the same. `code_index_health` keeps its name and `cwd` input but its output schema is intentionally NEW — the old engine reported `git-grep` health (presence, repo root, etc.); the new engine reports `staleness`, `per-language coverage`, `last index time`, `db_size`. No live plugin or doc consumer reads the old health fields, so there is zero breakage today; the change is an "add" of a richer schema rather than a backwards-incompatible swap.
- **Added — impact-analysis tools.** `symbol_callers({symbol})` (direct callers, one hop), `impact_of({symbol | file})` (transitive callers + file dependents with a depth cap), `dead_code({scope})` (unreferenced exports — see the README for the trailing-slash semantics on scope), and `dependency_path({from, to})` (shortest call chain). `symbol_callers` was previously hinted at via the `_phase7_codebase_graph_target.tools_to_expose` placeholder but not implemented; it is new with this server, alongside the other three.
- **Index location.** `.claude/.code-graph/index.db` (gitignored). Incremental by content hash, lazy build on first tool call — `SessionStart` is unchanged and pays no parse cost.
- **Languages.** ts/tsx/js, python, go, rust, java, ruby, php, bash — matching `detect-stack.sh`. See the server's README for the honest coverage matrix (Go and Rust resolve imports by name only, dynamic dispatch is not visible to the static graph, etc.).
- **Agent wiring.** The orchestrator's pre-delegation step now calls `impact_of` alongside `code_context` and attaches the impact set to the SPEC doc. The QA regression step calls `impact_of` for every changed symbol in the diff and treats high-fan-in hits as mandatory regression candidates (extends J19). Both calls degrade gracefully when the server is not available — see `orchestrator.md` section 1a and `qa.md` section 3a for the conditional language.
- **Grader is unaffected.** The Phase A rubric grader's packet is the SPEC doc, the diff, the F7 contract, `LESSONS.md`, and the applicable rubric files. It does not call MCP tools.

## Where to read more

- [`.claude/mcp/bd-mcp/README.md`](../.claude/mcp/bd-mcp/README.md) — full bd-mcp tool table, configuration, and limits.
- [`.claude/mcp/code-graph-mcp/README.md`](../.claude/mcp/code-graph-mcp/README.md) — code-graph tool table, vendored-grammar provenance, language coverage matrix, and the offline before/after token comparison for the orchestrator's pre-delegation flow.
- [v3 plan](../docs/) — Phase 6 (J29 = bd-mcp) for the bd-mcp design rationale.
- [verification-suite plan](plans/verification-suite.md) — Phase B for the code-graph-mcp design rationale and the migration acceptance criteria.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — Multi-repo Workflows section explains how the gate's I8 logic interacts with these servers' `cwd` parameters.

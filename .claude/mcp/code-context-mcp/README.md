# code-context-mcp

Lightweight code-search and symbol-context MCP tools backed by `git grep` / ripgrep. The simpler J30 path — no tree-sitter dependency.

## Tools

| Name | Summary | Input shape | Side effects |
|---|---|---|---|
| `code_search` | Find a string or regex in the project's source tree | `{query, max_results?, regex?, cwd?}` | None (`readOnlyHint`); spawns one of `rg` / `git grep` / plain `grep` |
| `code_context` | Definition + usage sites for a symbol (heuristic) | `{symbol, max_results?, cwd?}` | None; returns `{definitions[], usages[]}` |
| `code_index_health` | Sanity report: cwd, git/rg availability, tracked file count | `{cwd?}` | None |

Each tool returns `ok()` with structured `data` plus a free-form `llm_observations` field (per the v3 plan's principle #9). All three set `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`. `code_search` and `code_context` set `openWorldHint: true` (they touch the filesystem); `code_index_health` does not.

Backend selection (best-first): `rg` (fastest + structured JSON output) → `git grep` (always there in repos) → plain `grep -rn` (last-resort filesystem walk). `code_context` prefers `git grep -nw` because the word-boundary flag is exactly what identifier lookups need; it falls through to `rg --word-regexp`.

## Configuration

| Variable / file | Purpose |
|---|---|
| `CODE_CONTEXT_CWD` | Override the cwd used for searches |
| `CLAUDE_PROJECT_DIR` | Fallback for `CODE_CONTEXT_CWD`; usually set by Claude Code |
| `npm install` | Pulls `@modelcontextprotocol/sdk` and `zod`. The plugin installer runs this automatically |
| `npm test` | Runs `tests/server.test.js` against a temporary git repo with planted symbols |

No external state. The server is stateless across invocations; `git grep` and `rg` re-scan on every call. The cached "is rg available?" / "is git available?" probe lives in process memory only.

## Integration

The plugin uses these tools at two specific points:

- **Orchestrator pre-loads call sites before delegating.** When the orchestrator decomposes work into Beads tasks, it calls `code_context({symbol})` for every symbol the spawned specialist will likely touch. The results land in the SPEC doc (`bd_doc_write({task_id, name: "spec", ...})`) so the specialist doesn't re-discover them. This is the v3 plan's J30 framing: pre-load relevant call sites before delegating to specialists.
- **QA pre-loads call sites of changed symbols for regression assessment** (J19). When the QA agent reviews a diff, it pulls each changed symbol's `code_context` and considers whether the change is breaking for any caller — even ones outside the diff. Pairs with the regression-coverage framing of `verify-before-stop.sh` (run the FULL test suite per iteration, not just files in the diff).

Both manifest entries (`.mcp.json` and `.claude-plugin/plugin.json`) wire `node` + the launcher under `bin/code-context-mcp.js`.

## Testing

```bash
cd .claude/mcp/code-context-mcp
npm install
npm test
```

The suite (`tests/server.test.js`) builds an in-process `McpServer`, plants known symbols in a temp git repo, and asserts on tool responses for the happy-path (a definition we know exists), the empty-path (an unknown symbol), and the error-path (cwd doesn't exist). 9 tests total at last count; all green is the bar before merging changes.

A manual smoke test of the launched server:

```bash
(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0.0.0"}}}'; sleep 1) | node bin/code-context-mcp.js
```

Should respond with a `serverInfo` envelope identifying `code-context-mcp` v1.0.0.

## Limits / non-goals

- **No semantic analysis.** Definition vs. usage classification is a regex over keyword patterns (`function`, `class`, `const`, `def`, `fn`, `type`, `interface`, …). Wrong on overloads, on dynamic languages, on macro-heavy code. The v3 plan flags this as an intentional simpler-J30 trade-off; the tree-sitter upgrade is the Phase 7+ replacement (the `_phase7_codebase_graph_target` block in `.mcp.json` is the forward pointer).
- **No language-aware ranking.** Results are ordered by `git grep` / `rg` natural order (file path, then line). Don't expect "most relevant first".
- **No cross-repo search.** Single cwd per call. For multi-repo workspaces, set `CODE_CONTEXT_CWD` per call.
- **No write tools.** `code_search` does not modify files. The orchestrator pre-loads context; specialists do the editing via Claude Code's Edit tool.
- **No tree-sitter, no LSP, no semgrep.** Future Phase 7+ replacement may swap in any of those; the tool surface (`code_search` / `code_context` / `code_index_health`) is the stable API others should plan migrations against.

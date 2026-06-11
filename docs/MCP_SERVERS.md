# MCP Servers

The plugin ships two project-scoped MCP servers under `.claude/mcp/`. Both are wired in `.mcp.json` (and mirrored in `.claude-plugin/plugin.json`) so a Claude Code session inside the plugin's repo gets them automatically.

| Server | Path | Purpose | Tools | README |
|---|---|---|---|---|
| `bd` | `.claude/mcp/bd-mcp/` | Beads issue tracker as native MCP tools | 21 | [bd-mcp/README.md](../.claude/mcp/bd-mcp/README.md) |
| `code-context` | `.claude/mcp/code-context-mcp/` | Code search + symbol context (J30 simpler variant) | 3 | [code-context-mcp/README.md](../.claude/mcp/code-context-mcp/README.md) |

Both servers use stdio transport. Both are stateless across invocations (the Beads tools mutate the local `.beads/` database; the code-context tools only read).

## How they work in concert

The two servers are designed to slot into the orchestrator → specialist → QA flow at three key moments:

1. **Orchestrator decomposition.** When the orchestrator plans an epic, it calls `code_context({symbol})` for each likely-touched symbol to pre-load definitions and usages, then `bd_create_epic({title, children: [...]})` plus `bd_doc_write({task_id, name: "spec", content: ...})` to attach a SPEC document with that pre-loaded context. The specialist that picks up the task starts from full context — no re-discovery.

2. **Specialist claim + completion.** A specialist calls `bd_doc_read({task_id, name: "spec"})` to fetch the SPEC, `bd_update_task({task_id, status: "in_progress"})` to claim, and on completion `bd_qa_enter` then `bd_add_label("qa-pending")`. The completion contract from F7 — `{task_id, files_changed[], tests_added[], decisions[], blockers[], llm_observations}` — flows back through `bd_update_task --notes` (or via a new versioned doc).

3. **QA regression assessment.** The QA agent calls `code_context` for every changed symbol in the diff and looks at the usage sites to find regression candidates outside the immediate change. Pairs with `verify-before-stop.sh`'s J19 framing (the gate runs the FULL test suite each iteration, not just tests for files in the diff). On approval, `bd_qa_approve` is one atomic call (label add + label removes + comment + memory write) — no manual sequencing.

## Testing MCP Servers

The e2e harness exercises both servers end-to-end via the golden cassette
workflow (see [`.claude/tests/README.md`](../.claude/tests/README.md)).
Each of the six live fixtures runs against the real orchestrator,
specialist, and QA agents — and those agents call `bd_*` and
`code_context` tools through the real MCP stdio transport. The trace
records every tool invocation with normalised payloads, so a regression
in the bd-mcp surface (a missing field, a re-ordered argument list)
shows up as a structural diff against the golden cassette.

Concrete example: the orchestrator's pre-delegation step in the
`node-react-auth` fixture calls
`code_context({symbol: "auth-handler"})` before creating subtasks, so the
specialist that picks up "Backend: implement /auth/login" reads from a
SPEC document the orchestrator pre-loaded with the live call sites. If
the `code_context` server starts returning a different schema, the
fixture's normalized trace diverges from the golden and the L3-live job
fails with a one-line "Symbol context payload shape drift" message.

The bd-mcp side has the same coverage: every `bd_create_epic`,
`bd_update_task`, `bd_qa_enter`, `bd_qa_approve` call lands in the trace.
The Beads label progression assertion in each spec (`expected_label_progression`
in `fixture.yaml`) is what catches regressions in the gate's atomic
multi-label flips.

## Wiring summary

The plugin ships two parallel MCP manifests. Each scope uses a different
variable form because Claude Code expands variables differently in each.

`.mcp.json` (project-scoped, applies to anyone who opens the plugin's
repo in Claude Code) uses `${CLAUDE_PROJECT_DIR:-.}`:

```json
{
  "mcpServers": {
    "bd":           { "type": "stdio", "command": "node",
                      "args": ["${CLAUDE_PROJECT_DIR:-.}/.claude/mcp/bd-mcp/bin/bd-mcp.js"] },
    "code-context": { "type": "stdio", "command": "node",
                      "args": ["${CLAUDE_PROJECT_DIR:-.}/.claude/mcp/code-context-mcp/bin/code-context-mcp.js"] }
  }
}
```

The `:-.` default is required. Per the Claude Code MCP docs
([code.claude.com/docs/en/mcp](https://code.claude.com/docs/en/mcp)),
`CLAUDE_PROJECT_DIR` is set in the *spawned MCP server's* environment,
not in Claude Code's own environment — so a bare `${CLAUDE_PROJECT_DIR}`
in a project-scoped `.mcp.json` is unresolved at substitution time and
produces an MCP-diagnostics warning ("Missing environment variables:
CLAUDE_PROJECT_DIR"). The `:-.` default falls back to the current working
directory (which is the project root when Claude Code starts), which
resolves the warning without changing semantics.

`.claude-plugin/plugin.json` (the plugin manifest, applies when the plugin
is loaded as a plugin) uses bare `${CLAUDE_PLUGIN_ROOT}`:

```json
{
  "mcpServers": {
    "bd":           { "type": "stdio", "command": "node",
                      "args": ["${CLAUDE_PLUGIN_ROOT}/.claude/mcp/bd-mcp/bin/bd-mcp.js"] },
    "code-context": { "type": "stdio", "command": "node",
                      "args": ["${CLAUDE_PLUGIN_ROOT}/.claude/mcp/code-context-mcp/bin/code-context-mcp.js"] }
  }
}
```

Plugin-scope manifests substitute `${CLAUDE_PLUGIN_ROOT}` (and
`${CLAUDE_PROJECT_DIR}`) directly per the docs, so the default form is
not required here.

The two manifests should always agree on server set and tool surface; if
you change one, change the other in the same commit.

## Forward-looking

A `_phase7_codebase_graph_target` placeholder in `.mcp.json` keeps a forward pointer to a tree-sitter-grade replacement for `code-context`. It is inert (no `mcpServers.code-context-graph` entry) until Phase 7+. The tool surface (`code_search` / `code_context` / `code_index_health`) is the stable API the replacement is expected to honour, so existing callers won't break when it lands.

## Where to read more

- [`.claude/mcp/bd-mcp/README.md`](../.claude/mcp/bd-mcp/README.md) — full bd-mcp tool table, configuration, and limits.
- [`.claude/mcp/code-context-mcp/README.md`](../.claude/mcp/code-context-mcp/README.md) — code-context tool table, backend selection, and migration notes.
- [v3 plan](../docs/) — Phase 6 (J29 = bd-mcp, J30 = code-context-mcp) for the design rationale.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — Multi-repo Workflows section explains how the gate's I8 logic interacts with these servers' `cwd` parameters.

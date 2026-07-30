# MCP Servers

The plugin ships two project-scoped MCP servers under `.claude/mcp/`. Both are wired in `.mcp.json` (and mirrored in `.claude-plugin/plugin.json`) so a Claude Code session inside the plugin's repo gets them automatically.

| Server | Path | Purpose | Tools | README |
|---|---|---|---|---|
| `bd` | `.claude/mcp/bd-mcp/` | Beads issue tracker as native MCP tools | 21 | [bd-mcp/README.md](../.claude/mcp/bd-mcp/README.md) |
| `code-graph` | `.claude/mcp/code-graph-mcp/` | Tree-sitter + SQLite code-graph (search, definitions, callers, transitive impact, dead-code, dependency paths, index health) | 7 | [code-graph-mcp/README.md](../.claude/mcp/code-graph-mcp/README.md) |

Both servers use stdio transport. Both are stateless across invocations (the Beads tools mutate the local `.beads/` database; the code-graph tools read source files and maintain a per-project SQLite index at `.claude/.code-graph/index.db`, gitignored).

## Dependencies

**Both servers have real npm dependencies and neither can boot without them.**
`bin/bd-mcp.js` and `bin/code-graph-mcp.js` are dynamic-import launchers; with
`node_modules/` absent they die on spawn with
`ERR_MODULE_NOT_FOUND: Cannot find package '@modelcontextprotocol/sdk'` and the
session simply has no MCP tools.

This is not a hypothetical. Before v4.1 it was the **default** outcome of a
`curl | bash` install: that path clones the source with `git clone --depth 1`,
`.gitignore` excludes `node_modules/`, so the clone never had dependencies to
copy. Both servers were dead in every such target for three releases, and every
test stayed green because every test asserted file presence.

### What the installer does now

`install.sh` (and `install.ps1`) runs, per server, **in the target**, after the
file copy:

```bash
npm ci --omit=dev --ignore-scripts
```

`node` and `npm` are hard prerequisites, checked before anything is written,
with a floor of **node >= 18.17** — the `"engines"` value both servers declare.
Neither server has native dependencies (pure JS + WASM: `sql.js` and
`web-tree-sitter`, zero `hasInstallScript` packages, both `package-lock.json`
files git-tracked at lockfileVersion 3), so this needs no compiler and no
toolchain, and `--ignore-scripts` is safe rather than merely cautious.

Two escape hatches:

```bash
bash install.sh --skip-mcp-deps /path/to/project   # do not run npm ci
CWP_SKIP_MCP_DEPS=1 curl -fsSL <url>/install.sh | bash   # env form
```

Under `--skip-mcp-deps` the installer says so explicitly and the two server
checks fail verification, so the target is never advertised as working.

### Verifying

`workflow-doctor.sh` **boots each server over stdio** and asserts `tools/list`
returns **exactly** 21 and 7 tools:

```bash
bash .claude/scripts/workflow-doctor.sh
# PASS mcp_bd          serverInfo.name=bd-mcp, tools/list returned exactly 21 tool(s)
# PASS mcp_code_graph  serverInfo.name=code-graph-mcp, tools/list returned exactly 7 tool(s)
```

The equality is exact, not `>=`, because "boots and registers nothing" is a
real failure that a does-it-start check cannot see. `[ -d node_modules ]` is
likewise not a usable test: a failed `npm ci` leaves an empty husk of
directories that passes it.

### Air-gapped installs

There is no cached fallback for `npm ci`. Copy each server's `node_modules/`
from a machine that has run it, then verify:

```bash
cd <target>/.claude/mcp/bd-mcp         && npm ci --omit=dev --ignore-scripts
cd <target>/.claude/mcp/code-graph-mcp && npm ci --omit=dev --ignore-scripts
# ...or copy both node_modules/ trees across, then:
bash .claude/scripts/workflow-doctor.sh --target <target> --skip beads
```

`--skip beads` matters offline for an unrelated reason: `bd doctor` performs a
GitHub release check and can otherwise run past the check's 30s bound and
report a false failure on a healthy install. This exact recipe is executed (not
merely documented) by section 5 of
`.claude/tests/component/specs/installer-target-functional.sh`.

There is also one **optional, per-operator** server the plugin does not ship and never registers for you: `codex`, the OpenAI Codex CLI running in MCP-server mode, which backs the advisory external reviewer lane (Sol). Unlike the two above it is registered at **user scope** (`~/.claude.json`) on the individual machine, never in the project `.mcp.json` — a project-scoped entry would show as a permanently failed server for every teammate without the Codex CLI. With it absent the workflow is unchanged: `codex-detect.sh` is fail-open and the fresh-context Claude review lane fills the reviewer role. Setup, auth, billing, and troubleshooting are in [`CODEX_SETUP.md`](CODEX_SETUP.md).

## How they work in concert

The two servers slot into the orchestrator -> specialist -> QA flow at three key moments:

1. **Orchestrator decomposition (pre-delegation).** When the orchestrator plans an epic or any non-trivial change, before spawning a specialist it calls `code_search` / `code_context` for the symbols the change is likely to touch *and* `impact_of({symbol})` (or `impact_of({file})`) to surface transitive callers and dependent files. The result lands in the SPEC doc via `bd_doc_write({task_id, name: "spec", ...})` so the specialist starts from full context — no re-discovery, and no surprise from a high-fan-in caller the orchestrator forgot to mention. The `impact_of` query is conditional on the server being available so a target project that has not yet installed code-graph degrades gracefully to the search-only flow.

2. **Specialist claim + completion.** A specialist calls `bd_doc_read({task_id, name: "spec"})` to fetch the SPEC, `bd_update_task({task_id, status: "in_progress"})` to claim, and on completion `bd_qa_enter` then `bd_add_label("qa-pending")`. During the work, specialists query `code_context({symbol})` and `symbol_callers({symbol})` to identify the exact call sites a change touches. The completion contract from F7 — `{task_id, files_changed[], tests_added[], decisions[], blockers[], llm_observations, context_coverage}` — flows back through `bd_update_task --notes` (or via a new versioned doc).

3. **QA regression assessment (extends J19).** The QA agent pulls the diff via `git diff -- $(cat .claude/.qa-tracking/changed-files.txt)` and, for every changed symbol, calls `impact_of({symbol})`. High-fan-in hits are mandatory regression candidates — QA inspects (or runs) their tests as part of the gate, not just the tests that ship in the diff. The full test suite still runs (J19's anti-scope-creep rule), but the impact graph is what tells QA *which* of the existing tests are the highest-value ones to read before approving. Pairs with `verify-before-stop.sh`'s J19 framing (the gate runs the FULL test suite each iteration, not just tests for files in the diff). On approval, `bd_qa_approve` is one atomic call (label add + label removes + comment + memory write) — no manual sequencing. The grader (Phase A) never calls an MCP tool itself, but it does read code-graph output at one remove: packet item 7 is the mechanical impact report that `impact-report.sh` produced by driving this server. See [`AGENTS.md`](AGENTS.md) for the full eight-item packet.

## Testing MCP Servers

The e2e harness exercises both servers end-to-end via the manual, invariant-based live tier (see [`.claude/tests/README.md`](../.claude/tests/README.md)). Each of the seven live fixtures runs against the real orchestrator, specialist, and QA agents — and those agents call `bd_*`, `code_search`, `code_context`, and (post-3.3.0) `impact_of` tools through the real MCP stdio transport. The trace records every tool invocation with normalised payloads, and the spec invariants assert workflow contract properties (orchestrator never edits; QA approval gates Stop; declared specialists are the only ones invoked) — properties that hold across model versions by construction, so a regression in either MCP server's surface surfaces as an invariant violation rather than a golden-cassette diff.

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

## Troubleshooting: bd (or code-graph) shows failed / not spawned

If `/mcp` lists a server as failed, or the `bd_*` / `code_*` tools are missing in an installed project, check these two things first — in this order.

1. **Untrusted workspace (v2.1.196+).** Since v2.1.196, Claude Code does not spawn self-approved project `.mcp.json` servers in an untrusted workspace; `/mcp` shows the server as **"⏸ Pending approval"**. Fix: re-accept the workspace trust (reopen the folder and confirm the trust prompt, or approve the server from `/mcp`). This is a trust-state issue, not a config error — the manifest is fine and needs no edit.

2. **Hand-written config drift.** A config you edited by hand (rather than one the installer rendered) must match the plugin's form exactly:
   - Use the literal `${CLAUDE_PROJECT_DIR:-.}` in `.mcp.json` args. A bare `${CLAUDE_PROJECT_DIR}` does **not** expand at substitution time (the variable lives in the *spawned server's* environment, not Claude Code's own) and produces a "Missing environment variables: CLAUDE_PROJECT_DIR" diagnostic. See the Wiring summary above.
   - Set `"type": "stdio"` on every entry. A missing or mistyped transport type leaves the server unspawned.
   - No hidden whitespace in values — a trailing space or stray tab inside the `command`/`args` strings breaks the spawn silently. Re-render from the installer if unsure.

See also the Caveats section of [`README.md`](../README.md).

## Migration from code-context-mcp (3.3.0)

Phase B of the verification-suite plan (v3.3.0) retired `code-context-mcp` and replaced it with `code-graph-mcp`. Concretely, what changed:

- **Removed:** `.claude/mcp/code-context-mcp/` and the `code-context` entry in both `.mcp.json` and `.claude-plugin/plugin.json`. The `_phase7_codebase_graph_target` placeholder block in `.mcp.json` is gone now that it is filled.
- **Stable surface is byte-compatible on inputs and on documented output fields.** `code_search` and `code_context` keep their input schemas (`query` / `symbol` / `max_results` / `regex` / `cwd`) and their primary output keys. The `tool` / `backend` value strings change (`"git-grep"` -> `"graph-index"`) to make the new engine visible in tool output — described inline in the tool descriptions so downstream callers know what is and is not the same. `code_index_health` keeps its name and `cwd` input but its output schema is intentionally NEW — the old engine reported `git-grep` health (presence, repo root, etc.); the new engine reports `staleness`, `per-language coverage`, `last index time`, `db_size`. No live plugin or doc consumer reads the old health fields, so there is zero breakage today; the change is an "add" of a richer schema rather than a backwards-incompatible swap.
- **Added — impact-analysis tools.** `symbol_callers({symbol})` (direct callers, one hop), `impact_of({symbol | file})` (transitive callers + file dependents with a depth cap), `dead_code({scope})` (unreferenced exports — see the README for the trailing-slash semantics on scope), and `dependency_path({from, to})` (shortest call chain). `symbol_callers` was previously hinted at via the `_phase7_codebase_graph_target.tools_to_expose` placeholder but not implemented; it is new with this server, alongside the other three.
- **Index location.** `.claude/.code-graph/index.db` (gitignored). Incremental by content hash, lazy build on first tool call — `SessionStart` is unchanged and pays no parse cost.
- **Languages.** ts/tsx/js, python, go, rust, java, ruby, php, bash — matching `detect-stack.sh`. See the server's README for the honest coverage matrix (Go and Rust resolve imports by name only, dynamic dispatch is not visible to the static graph, etc.).
- **Agent wiring.** The orchestrator's pre-delegation step now calls `impact_of` alongside `code_context` and attaches the impact set to the SPEC doc. The QA regression step calls `impact_of` for every changed symbol in the diff and treats high-fan-in hits as mandatory regression candidates (extends J19). Both calls degrade gracefully when the server is not available — see `orchestrator.md` section 1a and `qa.md` section 3a for the conditional language.
- **Grader calls no MCP tools.** The Phase A rubric grader has a read-only tool set (`Read`, `Grep`, `Glob`, `LS`) and issues no MCP calls. It does consume this server's output at one remove: packet item 7 is the mechanical impact report `impact-report.sh` generates by driving code-graph. The current packet is eight items — see [`AGENTS.md`](AGENTS.md).

## Where to read more

- [`.claude/mcp/bd-mcp/README.md`](../.claude/mcp/bd-mcp/README.md) — full bd-mcp tool table, configuration, and limits.
- [`.claude/mcp/code-graph-mcp/README.md`](../.claude/mcp/code-graph-mcp/README.md) — code-graph tool table, vendored-grammar provenance, language coverage matrix, and the offline before/after token comparison for the orchestrator's pre-delegation flow.
- [v3 plan](../docs/) — Phase 6 (J29 = bd-mcp) for the bd-mcp design rationale.
- [verification-suite plan](plans/verification-suite.md) — Phase B for the code-graph-mcp design rationale and the migration acceptance criteria.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — Multi-repo Workflows section explains how the gate's I8 logic interacts with these servers' `cwd` parameters.

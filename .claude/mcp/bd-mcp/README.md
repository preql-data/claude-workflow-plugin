# bd-mcp

Native MCP tools for the Beads (`bd`) issue tracker. A typed shim — Beads stays the source of truth.

## Tools

| Name | Summary | Input shape | Side effects |
|---|---|---|---|
| `bd_create_task` | Create one task / bug / feature / chore | `{title, type, priority?, labels?, parent?, notes?}` | Inserts a row in `.beads/`; emits `created` event |
| `bd_create_epic` | Create an epic with optional sub-tasks (one call) | `{title, children?:[{title, labels?}]}` | Multi-row insert; partial state on per-child failure |
| `bd_list_tasks` | Filtered list (status, label-AND/OR, parent, type, priority) | `{labels_all?, labels_any?, status?, parent?, type?, priority_min?, priority_max?}` | None (`readOnlyHint`) |
| `bd_show_task` | Detail view incl. dependencies, comments, notes | `{task_id}` | None |
| `bd_update_task` | Set status, notes, assignee, labels (add/remove/set), parent | `{task_id, status?, notes?, labels_add?, labels_remove?, ...}` | One atomic `bd update` |
| `bd_close_task` | Close one or many with optional reason | `{task_ids: [...], reason?}` | Status transition; reversible via `bd reopen` |
| `bd_add_label` / `bd_remove_label` / `bd_list_labels` | Label ops (idempotent) | `{task_ids, label}` | Label CRUD |
| `bd_add_comment` / `bd_list_comments` | Append-only comments with optional metadata | `{task_id, text, metadata?}` | Inserts comment row |
| `bd_add_dep` / `bd_list_deps` | Blocks / related / discovered-from / parent-child | `{from, to, type}` | Inserts dep edge |
| `bd_get_ready` / `bd_get_blocked` | Actionable / waiting-on-deps queries | `{labels?}` | None |
| `bd_doc_write` / `bd_doc_read` | Task-attached docs (J4): main → notes, named → versioned comments | `{task_id, name, content?}` | Notes write OR comment append |
| `bd_qa_enter` / `bd_qa_status` / `bd_qa_approve` / `bd_qa_block` | QA-gate lifecycle, atomic with rollback | `{task_id, summary?}` | Label transitions + comment + memory + iteration counter; wraps `qa-gate.sh` |

21 tools total. Every tool exposes the four MCP annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) and includes a free-form `llm_observations` field on success per the v3 plan's principle #9.

## Configuration

| Variable / file | Purpose |
|---|---|
| `BD_CWD` | Override the cwd `bd` runs in (used when the MCP launches outside the project root) |
| `CLAUDE_PROJECT_DIR` | Fallback for `BD_CWD`; usually set by Claude Code |
| `npm install` | Pulls `@modelcontextprotocol/sdk` and `zod`. The plugin installer runs this automatically |
| `npm test` | Runs the integration suite; needs `bd` on PATH |

The QA tools (`bd_qa_*`) call `qa-gate.sh` from the plugin (`.claude/scripts/qa-gate.sh`) for the side-effect bundle (label transitions, current-task helper writes, iteration-counter wipe, memory writes). If the script is absent, they fall back to direct `bd label` calls and skip side effects.

## Integration

The plugin uses these tools as follows:

- **Orchestrator**: `bd_create_epic` to plan multi-task work in one call; `bd_doc_write({task_id, name: "spec", ...})` to attach the SPEC the spawned specialist reads first.
- **Specialists** (backend / frontend / devops): `bd_doc_read({task_id, name: "spec"})` to pick up the brief; `bd_update_task({task_id, status: "in_progress"})` to claim; `bd_qa_enter` then `bd_add_label("qa-pending")` on completion. The completion contract from F7 (`{task_id, files_changed[], tests_added[], decisions[], blockers[], llm_observations}`) maps cleanly onto these calls.
- **QA agent**: `bd_list_tasks({labels_all: ["qa-pending"]})` to find the queue; `bd_qa_approve` (atomic — sets `qa-approved`, drops `qa-pending`/`qa-gate-entered`, comments) or `bd_qa_block(reason)` to gate.
- **Hooks** (post-edit, verify-before-stop, etc.) still shell out to `bd` directly — migration is a Phase 7+ task. The MCP tools and the bash hooks coexist on the same Beads database.

Two manifest entries point at this server: `.mcp.json` (project-scoped registry) and `.claude-plugin/plugin.json` (plugin manifest mirror). Both wire `node` + the launcher under `bin/bd-mcp.js`.

## Testing

```bash
cd .claude/mcp/bd-mcp
npm install
npm test
```

The integration suite (`tests/integration.test.js`) spins up a temp `.beads`-initialized directory per test and exercises every tool against the real `bd` CLI. The QA tests symlink the plugin's `qa-gate.sh` into the temp tree so the shell helper runs end-to-end (label transitions, atomic rollback, current-task helper writes).

## Limits / non-goals

- **No Beads logic re-implementation.** Every tool shells out to `bd`. If a feature isn't exposed by the CLI yet, the tool either returns `not-supported` or shells through `bd config` for the closest equivalent.
- **No remote Beads sync.** The MCP server runs against the local `.beads/` only. `bd sync` is invoked by the plugin's `session-end.sh` hook, not from a tool.
- **Hooks not yet migrated.** `verify-before-stop.sh`, `post-edit.sh`, etc. still call `bd ...` via bash. Migration is Phase 7+.
- **GitHub auto-linking** is handled separately by `.claude/scripts/bd-github-link.sh` (I3), not via a bd-mcp tool.
- **Multi-repo (I8)** is gate-side, not bd-mcp-side. Cross-repo detection lives in `verify-before-stop.sh`; bd-mcp tools accept an optional `cwd` parameter for federated layouts.

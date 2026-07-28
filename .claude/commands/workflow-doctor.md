---
description: Verify that this project's claude-workflow-plugin install actually orchestrates — executes the SessionStart hook, both MCP servers, and both gate hooks in a throwaway sandbox rather than checking that files are present. Claude-invokable; run it when the workflow seems absent, when MCP tools are missing, or right after an install or upgrade.
argument-hint: [--skip <check,check>] [--json-out <file>]
---

# /workflow-doctor

Run the eleven functional health checks over this project's install. Every
check either EXECUTES the thing or reads a contract a broken install cannot
satisfy — the presence-only assertions live in the installer specs, and
presence is exactly what let "both MCP servers dead" and "no workflow context
at all" ship three times.

## Implementation steps (run as a single bash invocation)

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
bash "$PROJECT_DIR/.claude/scripts/workflow-doctor.sh" --target "$PROJECT_DIR" "$@"
```

## Reading the output

One `PASS` / `FAIL` / `SKIP` line per check, by name. Every `FAIL` is followed
by indented `fix:` lines that are meant to be run as-is. Exit 0 = all
non-skipped checks passed, 1 = at least one failed, 2 = usage error.

The check names are a stable contract (`deps`, `agents`, `skill`,
`mcp_config`, `settings_hooks`, `beads`, `session_start`, `mcp_bd`,
`mcp_code_graph`, `gate_pretooluse`, `gate_stop`). `--skip` rejects an unknown
name rather than ignoring it.

## Notes for Claude

- Safe to run mid-session. Every dynamic check EXCEPT `beads` runs against a
  throwaway copy of the project, so the operator's QA approval, changed-files
  tracker, gate baseline and agent `model:` pins are never touched. Do NOT
  "optimise" this by invoking `session-start.sh` or `verify-before-stop.sh`
  directly — those mutate gate state.
- The one exception, stated precisely because the operator may ask: `beads` runs
  `bd doctor` against the REAL target on purpose (a sandboxed copy would be
  checking a database the workflow does not use). It changes no issue data and
  never touches `issues.jsonl`, but opening the SQLite database in WAL mode
  creates/rewrites `.beads/beads.db-shm` and `.beads/beads.db-wal`, and a
  checkpoint rewrites `.beads/beads.db`. Measured on a 6,936-file target: those
  three files are the ONLY things a full run modifies anywhere, and a run with
  `--skip beads` modifies nothing at all. Use `--skip beads` if the user needs a
  run that provably touches nothing.
- `--skip mcp_bd,mcp_code_graph` is the right move on a host with no node; add
  `beads` on an air-gapped host (`bd doctor` performs a GitHub release check and
  can otherwise blow the 30s bound and report a false FAIL).
  `workflow-doctor.sh --help` carries the air-gapped `npm ci` recipe.
- Report the failing check names and their `fix:` lines back to the user
  verbatim. Do not paraphrase a fix into a different command.
- A `FAIL` on `mcp_bd` / `mcp_code_graph` naming an absent `node_modules` is the
  known v4 packaging defect; the fix is one `npm ci --omit=dev` per server dir.

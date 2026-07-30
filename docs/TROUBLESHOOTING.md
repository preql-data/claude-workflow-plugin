# Troubleshooting

Common issues and solutions for the Ultimate Workflow Plugin.

---

## Start here: run the doctor

Before working through any section below, run the functional health check.
It executes the SessionStart hook, boots both MCP servers over stdio and
drives both gate hooks against your actual install, then prints a `fix:`
line for every failure:

```bash
bash .claude/scripts/workflow-doctor.sh
# or, from the plugin source checkout:
bash install.sh --verify /path/to/your/project
# or, in a session:
/workflow-doctor
```

Exit `0` = every check passed, `1` = something failed (each FAIL names
itself and its fix), `2` = usage error.

This exists because for three releases every check in this repo was
"is the file there" and none was "does it run" — which is exactly how a
target could be byte-perfect and still not orchestrate. If the doctor is
green and something is still wrong, that is a gap worth reporting.

Two useful variants:

```bash
# No node on this host? Skip the two MCP server checks explicitly.
bash .claude/scripts/workflow-doctor.sh --skip mcp_bd,mcp_code_graph

# No outbound network? `bd doctor` reaches GitHub for a release check and
# can blow the 30s bound on a perfectly healthy install.
bash .claude/scripts/workflow-doctor.sh --skip beads,mcp_bd,mcp_code_graph
```

---

## MCP Server Issues

The plugin ships two MCP servers, `bd-mcp` (21 tools) and `code-graph-mcp`
(7 tools), under `.claude/mcp/`. Both are dynamic-import launchers with real
npm dependencies.

### Both MCP servers unavailable / `ERR_MODULE_NOT_FOUND`

**Symptom**: `mcp__bd__*` and `mcp__code_graph__*` tools are missing from a
session. Running a server by hand produces:

```
Error [ERR_MODULE_NOT_FOUND]: Cannot find package '@modelcontextprotocol/sdk'
imported from .../.claude/mcp/bd-mcp/src/server.js
```

**Cause**: the servers' `node_modules/` was never installed in your project.
Before v4.1 this was the default outcome of a `curl | bash` install: that path
clones the source with `git clone --depth 1`, `.gitignore` excludes
`node_modules/`, **so the clone never had dependencies to copy**. Both servers
then died on spawn and the session simply had no MCP tools. Nothing reported it.

**Diagnose**:

```bash
# The dependency the launchers import. `[ -d node_modules ]` is NOT enough —
# a failed `npm ci` leaves an empty husk of directories that passes that test.
ls .claude/mcp/bd-mcp/node_modules/@modelcontextprotocol/sdk
ls .claude/mcp/code-graph-mcp/node_modules/@modelcontextprotocol/sdk

# Or just ask the doctor, which BOOTS each server and counts its tools:
bash .claude/scripts/workflow-doctor.sh --skip beads
```

**Solution** — install the dependencies from the committed lockfiles:

```bash
cd .claude/mcp/bd-mcp         && npm ci --omit=dev --ignore-scripts && cd -
cd .claude/mcp/code-graph-mcp && npm ci --omit=dev --ignore-scripts && cd -
bash .claude/scripts/workflow-doctor.sh   # confirm: 21 and 7 tools
```

Neither server has native dependencies (pure JS + WASM, zero install scripts),
so this needs no compiler and no toolchain. Re-running the plugin installer
does the same thing automatically as of v4.1.

### Air-gapped or offline install

`npm ci` needs the registry and there is no cached fallback. On a host with no
outbound network, copy the dependency trees from a machine that has run the
commands above:

```bash
# On the connected machine, from the plugin source:
tar czf mcp-deps.tgz \
  .claude/mcp/bd-mcp/node_modules \
  .claude/mcp/code-graph-mcp/node_modules

# On the air-gapped host, from the project root:
tar xzf mcp-deps.tgz
bash .claude/scripts/workflow-doctor.sh --skip beads
```

Then install (or re-install) the plugin with dependency provisioning off, so
the installer does not try to reach the registry:

```bash
bash install.sh --skip-mcp-deps /path/to/project
# environment form, for `curl | bash`:
CWP_SKIP_MCP_DEPS=1 curl -fsSL <url>/install.sh | bash
```

`--skip beads` matters offline for an unrelated reason: `bd doctor` performs a
GitHub release check, so with no network it can run past the check's 30s bound
and report a false failure on a healthy install.

### `node` or `npm` missing

Both servers declare `"engines": {"node": ">=18.17"}` and their launchers fail
opaquely on older runtimes. node and npm are hard prerequisites of the
installer as of v4.1. If you cannot install node at all, the rest of the
workflow still works — skip the two server checks explicitly so the remaining
report stays trustworthy:

```bash
bash .claude/scripts/workflow-doctor.sh --skip mcp_bd,mcp_code_graph
```

Both agent prompts degrade gracefully when the code-graph tools are absent
(`orchestrator.md`, `qa.md`), and the Beads lifecycle runs through the `bd`
CLI over Bash rather than through MCP — so a dead MCP server costs you
pre-loaded call sites and impact analysis, not the workflow itself.

### The server boots but registers no tools

The doctor asserts **exact** tool counts (21 and 7), not "at least one",
because "boots and registers nothing" is a real failure that a
`does-it-start` check cannot see. If the counts are wrong rather than the
server dead, the dependency tree is likely partial — remove it and re-run
`npm ci` rather than layering an install on top:

```bash
rm -rf .claude/mcp/bd-mcp/node_modules
cd .claude/mcp/bd-mcp && npm ci --omit=dev --ignore-scripts
```

---

## Installation Issues

### "Beads (bd) not found"

**Symptom**: Installer exits with error about Beads not being installed.

**Cause**: Beads CLI is not installed or not in PATH.

**Solution**:

```bash
# Install Beads
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash

# Or via Homebrew
brew tap steveyegge/beads && brew install beads

# Or via npm
npm install -g @beads/bd

# Verify
bd --version
```

If installed but not found, add to PATH:
```bash
# For Go install
export PATH="$PATH:$(go env GOPATH)/bin"

# Add to ~/.bashrc or ~/.zshrc
echo 'export PATH="$PATH:$(go env GOPATH)/bin"' >> ~/.bashrc
source ~/.bashrc
```

### "jq not found"

**Symptom**: Installer or hooks fail with jq errors.

**Cause**: jq JSON processor not installed.

**Solution**:

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt install jq

# Windows
winget install jqlang.jq
```

### "Permission denied" on scripts

**Symptom**: Hooks fail with permission errors.

**Cause**: Scripts don't have execute permission.

**Solution**:

```bash
chmod +x .claude/scripts/*.sh
```

### Windows: Scripts not running

**Symptom**: Hooks don't trigger on Windows.

**Cause**: Bash not available or Git Bash not in PATH.

**Solution**:

1. Install Git for Windows (includes Git Bash)
2. Ensure Git Bash is in PATH
3. Scripts use `#!/bin/bash` and run via Git Bash

---

## Beads Issues

### "Beads not initialized"

**Symptom**: Session start fails with "Beads not initialized" error.

**Cause**: `.beads/` directory doesn't exist.

**Solution**:

```bash
cd your-project
bd init --quiet
bd hooks install
```

### "bd doctor shows errors"

**Symptom**: Health check fails.

**Solution**:

```bash
# View all issues
bd doctor

# Auto-fix common issues
bd doctor --fix

# Common fixes:
# - Schema mismatch: bd migrate
# - Daemon issues: bd daemon restart
# - Sync issues: bd sync
```

### Tasks not persisting

**Symptom**: Tasks disappear between sessions.

**Cause**: Beads not syncing to git.

**Solution**:

```bash
# Install git hooks
bd hooks install

# Force sync
bd sync

# Verify issues.jsonl exists
ls .beads/issues.jsonl
```

### "bd ready" shows nothing

**Symptom**: No tasks appear even though you created some.

**Causes**:
1. All tasks are blocked by dependencies
2. Tasks have wrong status
3. Tasks are closed

**Solutions**:

```bash
# Check all tasks
bd list

# Check blocked tasks
bd blocked

# Check specific task
bd show $TASK_ID

# Check for dependency cycles
bd dep cycles
```

---

## Hook Issues

### Hooks not triggering

**Symptom**: Workflow context not injected, QA gate not enforcing.

**Cause**: Hooks not configured in settings.json.

**Solution**:

```bash
# Check hooks are configured
cat .claude/settings.json | jq '.hooks'

# Should show SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd
```

If missing, re-run installer or manually add hooks to settings.json.

### Hook timeout errors

**Symptom**: SessionStart times out.

**Cause**: bd prime or other commands taking too long.

**Solution**:

1. Increase timeout in settings.json:
```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "timeout": 60000  // Increase from 30000
      }]
    }]
  }
}
```

2. Check Beads daemon:
```bash
bd doctor
bd daemon restart
```

### "Invalid JSON" errors

**Symptom**: Hooks fail with JSON parsing errors.

**Cause**: Script outputting invalid JSON.

**Solution**:

Test scripts manually:
```bash
# Test session-start
echo '{}' | bash .claude/scripts/session-start.sh | jq .

# Test intent-router
echo '{"prompt":"test"}' | bash .claude/scripts/intent-router.sh | jq .
```

Fix any syntax errors in scripts.

---

## QA Gate Issues

### QA gate not blocking

**Symptom**: Can complete tasks without QA approval.

**Causes**:
1. No code files were edited
2. Stop hook not configured
3. Task already has qa-approved label

**Solutions**:

```bash
# Check Stop hook is configured
cat .claude/settings.json | jq '.hooks.Stop'

# Check tracking file exists
cat .claude/.qa-tracking/changed-files.txt

# Check task labels
bd show $TASK_ID --json | jq '.labels'
```

### QA approved but still blocking

**Symptom**: Blocked even after QA approval.

**Cause**: Approval not detected correctly.

**Solutions**:

1. Check label is exactly `qa-approved`:
```bash
bd show $TASK_ID --json | jq '.labels'
```

2. Check comment contains "QA APPROVED":
```bash
bd show $TASK_ID --json | jq '.comments'
```

3. Manually add file marker (emergency):
```bash
touch .claude/.qa-tracking/approved
```

### Can't find task to approve

**Symptom**: QA doesn't know which task to approve.

**Solution**:

```bash
# Find in-progress tasks
bd list --status in_progress

# Find tasks pending QA
bd list --label qa-pending
```

---

## Context Issues

### The session has no workflow at all — no delegation, no gate

**Symptom**: the plugin is installed, but the main session does everything
itself. No specialist is spawned, no QA gate fires, the Stop hook never
blocks. The same install orchestrates correctly on another machine.

**Cause** (pre-v4.1): `session-start.sh` had two hard `exit 1` paths that
printed a bare `{"error": "..."}` instead of a `hookSpecificOutput` envelope,
when `bd` was off PATH or `.beads/` was missing. Claude Code discards
non-envelope hook output silently, so the session received **no
`workflow_engine` block, no delegation contract and no gate instructions** —
and nothing said so.

**As of v4.1 this cannot happen quietly.** The hook never bails: a missing
dependency becomes a `<workflow_degraded severity="high">` block at the top
of the injected context, naming the cause and its fix. If you see that block
in a session, the workflow is running in **advisory** mode — the delegation
contract still applies, but nothing can prove it was followed.

**Diagnose** — the likeliest cause is PATH divergence, not a missing install.
Hooks run in a non-interactive, non-login shell that does not read `~/.zshrc`
or `~/.bashrc`:

```bash
bash -lc 'command -v bd'    # your login shell
bash -c  'command -v bd'    # what the hook sees — this is the one that matters
```

- **Only the first prints a path** → PATH divergence. Export bd's directory
  from a file non-interactive shells *do* read (`~/.zshenv` for zsh,
  `~/.bash_env` for bash), or set `env.PATH` in `.claude/settings.json`.
  Start a new session afterwards.
- **Neither prints a path** → bd genuinely is not installed.
- **`.beads/` is missing** → run `bd init` in the project root.

**Verify the hook end to end**, which is what the doctor's `session_start`
check does:

```bash
echo '{}' | bash .claude/scripts/session-start.sh \
  | jq -r '.hookSpecificOutput.additionalContext' | head -40
```

You should see the `<workflow_engine source="skills/workflow-engine/SKILL.md">`
block and roughly 13 KB of contract. A `<workflow_degraded>` block at the top
names anything missing.

### "bd prime" output missing

**Symptom**: Session context doesn't include Beads state.

**Cause**: bd prime failing silently.

**Solution**:

```bash
# Test bd prime directly
bd prime

# Check for errors
bd prime 2>&1

# Verify Beads is healthy
bd doctor
```

### CLAUDE.md not loading

**Symptom**: Project memory not in context.

**Cause**: File doesn't exist or has wrong name.

**Solution**:

```bash
# Check file exists (exact case)
ls -la CLAUDE.md

# Create if missing
touch CLAUDE.md
```

### Blocked issues not showing

**Symptom**: Blocked issues not in session context.

**Cause**: No blocked issues, or bd blocked failing.

**Solution**:

```bash
# Check for blocked issues
bd blocked

# Test JSON output
bd blocked --json
```

---

## File Tracking Issues

### Too many files tracked

**Symptom**: QA gate shows hundreds of files.

**Cause**: Working in a large codebase with many edits.

**Solution**: This is expected. The tracking file is capped at 500 entries. For large changes, QA should focus on critical paths.

### Non-code files tracked

**Symptom**: JSON, markdown, etc. appearing in changed files.

**Cause**: File extension filter not matching.

**Note**: This shouldn't happen - only code files are tracked. If it does:

```bash
# Check filter in post-edit.sh
grep -E '\.(ts|tsx|js|jsx|py|go)' .claude/scripts/post-edit.sh
```

### Tracking file not clearing

**Symptom**: Old files appear in new sessions.

**Cause**: Session start not resetting tracking.

**Solution**:

```bash
# Manually clear
rm .claude/.qa-tracking/changed-files.txt
rm .claude/.qa-tracking/approved
```

---

## Performance Issues

### Slow session start

**Cause**: bd prime, bd blocked, or file loading taking time.

**Solutions**:

1. Check Beads daemon:
```bash
bd daemon status
bd daemon restart
```

2. Reduce project memory size (CLAUDE.md)

3. Compact old Beads issues:
```bash
bd admin compact --analyze
```

### High memory usage

**Cause**: Large tracking file or many Beads issues.

**Solutions**:

1. Tracking file is capped at 500 entries (automatic)

2. Compact old Beads issues:
```bash
bd admin compact --apply
```

---

## Git Issues

### Beads not committing

**Symptom**: .beads/issues.jsonl not in git.

**Solution**:

```bash
# Check gitignore
cat .gitignore | grep beads

# Should NOT ignore issues.jsonl
# Add to git
git add .beads/issues.jsonl
git commit -m "Add Beads issues"
```

### Merge conflicts in issues.jsonl

**Symptom**: Git conflict in .beads/issues.jsonl after merge.

**Solution**:

```bash
# Accept remote version
git checkout --theirs .beads/issues.jsonl

# Or accept local version
git checkout --ours .beads/issues.jsonl

# Then import
bd import -i .beads/issues.jsonl

# Commit
git add .beads/issues.jsonl
git commit -m "Resolve Beads merge"
```

---

## Getting Help

### Debug Information

Collect this info when reporting issues:

```bash
# Versions
bd --version
jq --version
git --version
bash --version

# Beads health
bd doctor

# Hook configuration
cat .claude/settings.json | jq '.hooks'

# Recent errors
cat .claude/scripts/session-start.sh | head -50
```

### Logs

Check Claude Code logs for hook errors.

### Community

- [Beads Issues](https://github.com/steveyegge/beads/issues)
- [Beads Docs](https://steveyegge.github.io/beads)

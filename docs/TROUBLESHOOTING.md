# Troubleshooting

Common issues and solutions for the Ultimate Workflow Plugin.

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

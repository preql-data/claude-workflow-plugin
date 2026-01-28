# Hooks Reference

Complete documentation of all hook scripts in the Ultimate Workflow Plugin.

---

## Overview

The plugin uses 5 Claude Code hooks:

| Hook | File | Trigger |
|------|------|---------|
| SessionStart | `session-start.sh` | Session begins |
| UserPromptSubmit | `intent-router.sh` | User submits prompt |
| PostToolUse | `post-edit.sh` | After Write/Edit tools |
| Stop | `verify-before-stop.sh` | Claude attempts to stop |
| SessionEnd | `session-end.sh` | Session ends |

---

## Hook Configuration

**File**: `.claude/settings.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-start.sh\"",
            "timeout": 30000
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/intent-router.sh\""
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/post-edit.sh\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/verify-before-stop.sh\""
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-end.sh\""
          }
        ]
      }
    ]
  }
}
```

---

## SessionStart Hook

**File**: `.claude/scripts/session-start.sh`

**Purpose**: Initialize context with Beads state and workflow instructions.

### What It Does

```bash
# 1. Verify Beads is available
if ! command -v bd &> /dev/null; then
    echo '{"error": "Beads (bd) not found"}'
    exit 1
fi

# 2. Verify Beads is initialized
if [ ! -d "$PROJECT_DIR/.beads" ]; then
    echo '{"error": "Beads not initialized. Run: bd init"}'
    exit 1
fi

# 3. Run bd doctor silently
bd doctor --quiet

# 4. Create session marker
touch "$PROJECT_DIR/.claude/.session-start"

# 5. Reset QA tracking
rm -f "$QA_TRACKING_DIR/approved"
rm -f "$QA_TRACKING_DIR/changed-files.txt"

# 6. Get bd prime output (Beads' agent context)
BD_PRIME=$(bd prime)

# 7. Load CLAUDE.md (project memory)
# 8. Get blocked issues (bd blocked)
# 9. Get qa-pending issues
# 10. Inject workflow instructions

# 11. Output JSON for additionalContext
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "..."
  }
}
EOF
```

### Context Injected

1. **Beads Context** (`<beads_context>`)
   - Output of `bd prime`
   - ~1-2k tokens of agent-optimized context

2. **Project Memory** (`<project_memory>`)
   - Contents of `CLAUDE.md`
   - Project description, users, journeys

3. **Blocked Issues** (`<blocked_issues>`)
   - Output of `bd blocked`
   - Tasks waiting on dependencies

4. **QA Pending** (`<qa_pending>`)
   - Tasks with `qa-pending` label
   - Work awaiting QA review

5. **Workflow Mode** (`<workflow_mode>`)
   - Beads commands cheat sheet
   - Mandatory QA gate reminder
   - Structured notes format

---

## UserPromptSubmit Hook

**File**: `.claude/scripts/intent-router.sh`

**Purpose**: Provide context for LLM-driven work analysis (NOT keyword matching).

### Design Philosophy

**Old approach (removed)**: Keyword matching like `grep -qE '(bug|error|fix)'`
- Brittle - misses nuanced requests
- Limited - can't understand context
- Inflexible - hardcoded patterns

**Current approach**: LLM-driven analysis
- The **Orchestrator agent** analyzes requests intelligently
- Hook provides framework and current task context
- Claude determines work type, domains, and complexity

### What It Does

```bash
# 1. Parse user prompt
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')

# 2. Get current Beads state (for context, not detection)
CURRENT_TASK=$(bd list --status in_progress --json | jq -r '.[0].id // empty')
if [ -n "$CURRENT_TASK" ]; then
    CURRENT_TASK_INFO=$(bd show "$CURRENT_TASK" | head -30)
fi

# 3. Inject orchestrator instructions (LLM does the analysis)
# 4. Add current task context if exists
# 5. Output JSON for additionalContext
```

### Why LLM-Driven?

| Scenario | Keyword Matching | LLM Analysis |
|----------|------------------|--------------|
| "The login isn't working right" | ❌ Might miss | ✅ Understands it's a bug |
| "Can we make this faster?" | ❌ "improve" not present | ✅ Recognizes improvement |
| "Users are complaining about X" | ❌ No keywords | ✅ Understands context |
| "Continue what we were doing" | ❌ No keywords | ✅ Checks current task |

### Context Injected

The hook injects `<orchestrator_instructions>` that guide Claude to:

1. **Analyze work type**: bug, feature, improvement, testing, planning
2. **Identify domains**: backend, frontend, devops
3. **Assess complexity**: simple → single task, complex → epic with subtasks
4. **Take action**: Create appropriate Beads tasks, delegate to specialists

The Orchestrator uses its intelligence to understand:
- Nuanced language ("it's broken" → bug)
- Context from current task
- User intent beyond keywords
- When to ask clarifying questions

---

## PostToolUse Hook

**File**: `.claude/scripts/post-edit.sh`

**Purpose**: Track file changes for QA review.

### What It Does

```bash
# 1. Extract file path from tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path')

# 2. Filter for code files only
if [[ ! "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|go|rs|java|vue|svelte|css)$ ]]; then
    echo "{}"; exit 0
fi

# 3. Add to tracking file (deduplicated)
if ! grep -qxF "$FILE_PATH" "$TRACKING_FILE"; then
    echo "$FILE_PATH" >> "$TRACKING_FILE"
fi

# 4. Cap at 500 files
if [ "$LINE_COUNT" -gt 500 ]; then
    tail -500 "$TRACKING_FILE" > "$TRACKING_FILE.tmp"
    mv "$TRACKING_FILE.tmp" "$TRACKING_FILE"
fi

# 5. Update Beads progress (batched every 10 edits)
if [ $((EDIT_COUNT % 10)) -eq 0 ]; then
    bd comments add "$CURRENT_TASK" "Progress: $UNIQUE_COUNT files edited"
fi

# 6. Output reminder
echo "📝 $COUNT files changed. All require @qa approval."
```

### Tracked File Types

- TypeScript: `.ts`, `.tsx`
- JavaScript: `.js`, `.jsx`
- Python: `.py`
- Go: `.go`
- Rust: `.rs`
- Java: `.java`
- Ruby: `.rb`
- PHP: `.php`
- Vue: `.vue`
- Svelte: `.svelte`
- CSS: `.css`, `.scss`
- HTML: `.html`

### Tracking File Location

```
.claude/.qa-tracking/
├── changed-files.txt    # List of changed files
├── edit-count           # Counter for batching
└── approved             # Marker when QA approves
```

---

## Stop Hook

**File**: `.claude/scripts/verify-before-stop.sh`

**Purpose**: **ENFORCE QA GATE** - Block completion until QA approves.

### What It Does

```bash
# 1. Skip for user interrupt
if [[ "$STOP_REASON" == "user_interrupt" ]]; then
    echo "{}"; exit 0
fi

# 2. Check for tracked changes
if [ -f "$TRACKING_FILE" ] && [ -s "$TRACKING_FILE" ]; then
    CODE_CHANGES_DETECTED=true
fi

# 3. If no changes, allow
if [ "$CODE_CHANGES_DETECTED" = false ]; then
    echo "{}"; exit 0
fi

# 4. Run technical checks (tests, lint)
if ! npm test; then
    FAILED_CHECKS+="❌ Tests failing\n"
fi

# 5. If checks fail, block
if [ -n "$FAILED_CHECKS" ]; then
    echo '{"decision": "block", "reason": "..."}'
    exit 0
fi

# 6. Check for QA approval
QA_APPROVED=false

# Method 1: Check qa-approved label
LABELS=$(bd show "$TASK" --json | jq -r '.labels | join(",")')
if echo "$LABELS" | grep -qi "qa-approved"; then
    QA_APPROVED=true
fi

# Method 2: Check for "QA APPROVED" comment
COMMENT=$(bd show "$TASK" --json | jq -r '.comments[] | select(test("QA APPROVED"))')
if [ -n "$COMMENT" ]; then
    QA_APPROVED=true
fi

# Method 3: Check file marker
if [ -f "$QA_TRACKING_DIR/approved" ]; then
    QA_APPROVED=true
fi

# 7. If not approved, BLOCK
if [ "$QA_APPROVED" = false ]; then
    echo '{"decision": "block", "reason": "🚫 QA APPROVAL REQUIRED..."}'
    exit 0
fi

# 8. If approved, allow and clean up
rm -f "$QA_TRACKING_DIR/approved"
rm -f "$QA_TRACKING_DIR/changed-files.txt"
echo "{}"
```

### Block Message

When QA hasn't approved, shows:

```
🚫 QA APPROVAL REQUIRED

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
15 file(s) changed - ALL require QA review
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Files changed:
src/auth/login.ts
src/components/LoginForm.tsx
... and 13 more files

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
REQUIRED: Delegate to @qa NOW
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Cannot complete without QA approval.
```

### Approval Detection

Three methods (any one succeeds):

1. **Label**: Task has `qa-approved` label
2. **Comment**: Task has comment containing "QA APPROVED"
3. **File marker**: `.claude/.qa-tracking/approved` exists

---

## SessionEnd Hook

**File**: `.claude/scripts/session-end.sh`

**Purpose**: Sync Beads state before session ends.

### What It Does

```bash
# Sync Beads to ensure state is persisted
if command -v bd &> /dev/null && [ -d "$PROJECT_DIR/.beads" ]; then
    bd sync
fi

echo "{}"
```

This ensures any Beads changes are synced to the git-tracked JSONL file before the session closes.

---

## Debugging Hooks

### Check if hooks are configured

```bash
cat .claude/settings.json | jq '.hooks'
```

### Test hooks manually

```bash
# Test session-start
echo '{}' | bash .claude/scripts/session-start.sh

# Test intent-router
echo '{"prompt": "Add user authentication"}' | bash .claude/scripts/intent-router.sh

# Test post-edit
echo '{"tool_input": {"file_path": "src/test.ts"}}' | bash .claude/scripts/post-edit.sh

# Test verify-before-stop
echo '{"stop_reason": "end_turn"}' | bash .claude/scripts/verify-before-stop.sh
```

### Common Issues

**Hook not triggering**:
- Check `settings.json` has the hook configured
- Verify script has execute permission: `chmod +x .claude/scripts/*.sh`
- Check for bash availability (Windows needs Git Bash)

**jq errors**:
- Ensure jq is installed: `jq --version`
- Check JSON input is valid

**Beads errors**:
- Verify Beads is installed: `bd --version`
- Check Beads is initialized: `ls .beads/`
- Run health check: `bd doctor`

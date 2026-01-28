# Architecture

Deep dive into the Ultimate Workflow Plugin system design.

---

## System Overview

The plugin implements an **orchestrator-first architecture** where:

1. A central orchestrator coordinates all work
2. Specialist agents handle domain-specific tasks
3. A mandatory QA gate enforces quality
4. Beads provides persistent memory

```
┌─────────────────────────────────────────────────────────────────────┐
│                          CLAUDE CODE                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐          │
│  │  SessionStart │───▶│UserPromptSub │───▶│  PostToolUse │          │
│  │     Hook      │    │    Hook      │    │     Hook     │          │
│  └──────────────┘    └──────────────┘    └──────────────┘          │
│         │                   │                   │                    │
│         │                   │                   │                    │
│         ▼                   ▼                   ▼                    │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                     ORCHESTRATOR                          │      │
│  │  • Analyzes requests                                      │      │
│  │  • Creates hierarchical tasks in Beads                    │      │
│  │  • Delegates to specialists                               │      │
│  └──────────────────────────────────────────────────────────┘      │
│         │                                                            │
│         ├──────────────┬──────────────┬──────────────┐              │
│         ▼              ▼              ▼              ▼              │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐        │
│  │ @backend │   │@frontend │   │ @devops  │   │   @qa    │        │
│  └──────────┘   └──────────┘   └──────────┘   └──────────┘        │
│                                                      │              │
│                                                      │              │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                      STOP HOOK                            │      │
│  │  • Checks for qa-approved label                          │      │
│  │  • Checks for "QA APPROVED" comment                      │      │
│  │  • BLOCKS if not approved                                │      │
│  └──────────────────────────────────────────────────────────┘      │
│                              │                                       │
│                              ▼                                       │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                   SESSION END                             │      │
│  │  • Syncs Beads state                                     │      │
│  └──────────────────────────────────────────────────────────┘      │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                           BEADS                                      │
│  • Persistent task storage                                          │
│  • Git-synchronized                                                 │
│  • Dependency tracking                                              │
│  • Labels for state                                                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Hooks

The plugin uses 5 Claude Code hooks:

### 1. SessionStart

**Trigger**: When a Claude Code session begins

**Purpose**: Initialize context with Beads state and workflow instructions

**What it does**:
```bash
# 1. Verify Beads is available and initialized
bd doctor --quiet

# 2. Get Beads context via bd prime
BD_PRIME=$(bd prime)

# 3. Load project memory (CLAUDE.md)
# 4. Show blocked issues (bd blocked)
# 5. Show tasks awaiting QA (label: qa-pending)
# 6. Inject workflow instructions
```

**Output**: JSON with `additionalContext` containing all context

### 2. UserPromptSubmit

**Trigger**: When user submits a prompt

**Purpose**: Detect intent and inject domain-specific workflow

**What it does**:
```bash
# 1. Parse user prompt
# 2. Detect work type:
#    - "bug|error|fix" → bug
#    - "add|create|build" → feature
#    - "improve|optimize" → improvement
#    - "test|verify" → testing
#    - "plan|design" → planning

# 3. Detect domains:
#    - "api|database|auth" → backend
#    - "ui|component|css" → frontend
#    - "deploy|docker|ci" → devops

# 4. Inject appropriate workflow context
```

**Output**: JSON with domain-specific instructions

### 3. PostToolUse

**Trigger**: After Write, Edit, or MultiEdit tools

**Purpose**: Track file changes for QA review

**What it does**:
```bash
# 1. Extract file path from tool input
# 2. Filter for code files only (.ts, .tsx, .js, .py, etc.)
# 3. Add to tracking file (deduplicated)
# 4. Cap tracking file at 500 entries
# 5. Update Beads with progress (batched every 10 edits)
```

**Output**: Reminder that changes require QA approval

### 4. Stop

**Trigger**: When Claude attempts to complete/stop

**Purpose**: ENFORCE QA GATE

**What it does**:
```bash
# 1. Skip if user_interrupt or max_turns
# 2. Check if code files were changed
# 3. Run technical checks (tests, lint)
# 4. Check for QA approval:
#    - Look for qa-approved label on task
#    - Look for "QA APPROVED" in comments
# 5. If not approved: BLOCK with instructions
# 6. If approved: Allow completion
```

**Output**: Either `{}` (allow) or `{"decision": "block", "reason": "..."}` 

### 5. SessionEnd

**Trigger**: When session ends

**Purpose**: Ensure Beads state is persisted

**What it does**:
```bash
bd sync
```

---

## Agents

### Orchestrator

The central coordinator that:
- Analyzes user requests
- Creates hierarchical tasks (epics with children)
- Sets labels and dependencies
- Delegates to specialists
- Tracks progress

### Domain Specialists

| Agent | Domain | Responsibilities |
|-------|--------|------------------|
| @backend | API, DB, auth | REST/GraphQL, business logic, data modeling |
| @frontend | UI, UX | Components, styling, accessibility |
| @devops | CI/CD, infra | Pipelines, containers, deployment |

All specialists:
- Claim tasks with `bd update $ID --status in_progress`
- Update notes with structured format
- Add `qa-pending` label when done

### QA Agent

The mandatory quality gate that:
- Reviews all changed files
- Tests USER BEHAVIOR (not implementation)
- Writes E2E tests for critical journeys
- Approves or blocks with specific feedback

Approval process:
```bash
bd comments add $ID "QA APPROVED: <summary>"
bd label remove $ID qa-pending
bd label add $ID qa-approved
```

---

## Data Flow

### Task Creation Flow

```
User Request
    │
    ▼
┌─────────────────────────────────────┐
│ Orchestrator analyzes request       │
│ Identifies: type=feature,           │
│ domains=[backend, frontend]         │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ Create Epic in Beads                │
│ bd create "Epic: ..." -t epic -p 1  │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ Create Subtasks with labels         │
│ bd create "Backend: ..." --parent   │
│   $EPIC -l backend,qa-pending       │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ Set Dependencies                    │
│ bd dep add $QA_TASK $IMPL_TASK      │
│ (QA waits for implementation)       │
└─────────────────────────────────────┘
```

### QA Approval Flow

```
Implementation Complete
    │
    ▼
┌─────────────────────────────────────┐
│ Stop Hook Triggered                 │
│ Checks: qa-approved label?          │
│ Checks: "QA APPROVED" comment?      │
└─────────────────────────────────────┘
    │
    ├─── NO ───┐
    │          ▼
    │   ┌─────────────────────────────┐
    │   │ BLOCKED                     │
    │   │ "Must delegate to @qa"      │
    │   └─────────────────────────────┘
    │          │
    │          ▼
    │   ┌─────────────────────────────┐
    │   │ @qa Reviews                 │
    │   │ • Checks changed files      │
    │   │ • Writes tests              │
    │   │ • Verifies behavior         │
    │   └─────────────────────────────┘
    │          │
    │          ▼
    │   ┌─────────────────────────────┐
    │   │ @qa Approves                │
    │   │ bd comments add "QA APPROVED│
    │   │ bd label add qa-approved    │
    │   └─────────────────────────────┘
    │          │
    └──────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ Task Complete                       │
│ bd close $ID --reason "..."         │
└─────────────────────────────────────┘
```

---

## File Tracking

The `post-edit.sh` script maintains a list of changed files:

```bash
# Location
.claude/.qa-tracking/changed-files.txt

# Format: one file per line
src/auth/login.ts
src/components/LoginForm.tsx
src/api/routes/auth.ts
```

### Deduplication

Files are only added once:
```bash
if ! grep -qxF "$FILE_PATH" "$TRACKING_FILE"; then
    echo "$FILE_PATH" >> "$TRACKING_FILE"
fi
```

### Size Cap

Tracking file is capped at 500 entries for large codebases:
```bash
if [ "$LINE_COUNT" -gt 500 ]; then
    tail -500 "$TRACKING_FILE" > "$TRACKING_FILE.tmp"
    mv "$TRACKING_FILE.tmp" "$TRACKING_FILE"
fi
```

---

## Beads Integration

### Why Beads?

| Need | Beads Feature |
|------|---------------|
| Persistent memory | Issues stored in git-tracked JSONL |
| Context injection | `bd prime` provides optimized context |
| Dependency tracking | `bd dep add` links related tasks |
| State tracking | Labels (`qa-pending`, `qa-approved`) |
| Progress notes | `--notes` field survives compaction |
| Auto-sync | Git hooks sync on commit/push |

### Structured Notes

Notes use a format that survives Beads compaction:

```
COMPLETED: [Specific deliverables]
IN PROGRESS: [Current work + next step]
BLOCKED: [What's preventing progress]
KEY DECISIONS: [Important architectural choices]
```

This ensures future sessions have context even after compaction.

---

## Security Considerations

### Denied Operations

The `settings.json` denies dangerous operations:
```json
{
  "permissions": {
    "deny": [
      "Bash(rm -rf *)",
      "Bash(sudo *)"
    ]
  }
}
```

### Tracking Data

QA tracking data is session-local:
```
.claude/.qa-tracking/
├── changed-files.txt    # Cleared each session
├── approved             # Marker file
└── edit-count           # Counter for batching
```

This data is gitignored and not persisted.

---

## Performance

### Context Efficiency

- `bd prime` provides ~1-2k tokens (vs 10-50k for MCP)
- Blocked issues capped at 20 entries
- QA pending issues capped at 10 entries

### File Tracking

- Deduplication prevents unbounded growth
- 500 file cap for large codebases
- Beads updates batched (every 10 edits)

### Git Hooks

- `bd hooks install` adds auto-sync
- Debounced sync (500ms) prevents spam

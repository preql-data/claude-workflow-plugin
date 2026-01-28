# Beads Integration

How the Ultimate Workflow Plugin uses Beads for persistent task tracking.

---

## Why Beads?

| Need | Solution Without Beads | Solution With Beads |
|------|------------------------|---------------------|
| Task memory | Lost between sessions | Persists in git-tracked JSONL |
| Dependencies | Manual tracking | `bd dep add` with automatic blocking |
| State tracking | Unreliable | Labels (`qa-pending`, `qa-approved`) |
| Context | Rebuild from scratch | `bd prime` provides ~1-2k tokens |
| Progress notes | Gone after compaction | Structured notes survive |
| Sync | Manual | Git hooks auto-sync |

**Beads is REQUIRED** for this workflow because it provides the persistent memory and state tracking that makes the QA gate enforceable across sessions.

---

## Features We Use

### 1. bd prime

**Purpose**: Optimized context injection for AI agents

**Usage**: Called in `session-start.sh`
```bash
BD_PRIME=$(bd prime 2>/dev/null || echo "")
```

**Benefits**:
- ~1-2k tokens (vs 10-50k for MCP)
- Pre-formatted for AI consumption
- Includes ready work, current state, workflow guidance

### 2. bd ready

**Purpose**: Find tasks with no blockers

**Usage**: Shown in workflow context
```bash
bd ready          # Human-readable
bd ready --json   # Machine-readable
```

**When to use**: Start of work to pick next task

### 3. bd blocked

**Purpose**: Show tasks waiting on dependencies

**Usage**: Shown in session context
```bash
BLOCKED=$(bd blocked --json)
BLOCKED_COUNT=$(echo "$BLOCKED" | jq 'length')
```

**When to use**: Understanding what's stuck and why

### 4. Hierarchical Issues

**Purpose**: Organize complex features as epics with children

**Usage**:
```bash
# Create epic
EPIC=$(bd create "Epic: User Auth" -t epic -p 1 \
    --description "Complete authentication system" --json | jq -r '.id')

# Create children
bd create "Backend: Auth API" -p 1 --parent $EPIC -l backend,qa-pending
bd create "Frontend: Login UI" -p 1 --parent $EPIC -l frontend,qa-pending
bd create "QA: Auth tests" -p 1 --parent $EPIC -l qa
```

**Result**:
```
bd-abc123: Epic: User Auth [epic] [P1]
├─ bd-abc123.1: Backend: Auth API [P1] [backend, qa-pending]
├─ bd-abc123.2: Frontend: Login UI [P1] [frontend, qa-pending]
└─ bd-abc123.3: QA: Auth tests [P1] [qa]
```

### 5. Labels

**Purpose**: Track domain and QA status

**Usage**:
```bash
# Add labels
bd label add $ID backend,qa-pending

# Remove labels
bd label remove $ID qa-pending

# Filter by label
bd list --label qa-pending
bd list --label backend
```

**Our label convention**:

| Label | Meaning |
|-------|---------|
| `backend` | Backend domain work |
| `frontend` | Frontend domain work |
| `devops` | DevOps domain work |
| `qa` | QA-owned task |
| `qa-pending` | Awaiting QA review |
| `qa-approved` | QA has signed off |
| `bug` | Bug fix |
| `feature` | New feature |
| `improvement` | Enhancement |

### 6. Structured Notes

**Purpose**: Progress that survives compaction

**Usage**:
```bash
bd update $ID --notes "COMPLETED: JWT auth endpoints
IN PROGRESS: None - ready for QA
BLOCKED: None
KEY DECISIONS: RS256 tokens, 15min expiry"
```

**Format**:
```
COMPLETED: [Specific deliverables]
IN PROGRESS: [Current work + next step]
BLOCKED: [What's preventing progress]
KEY DECISIONS: [Important architectural choices]
```

This format:
- Survives Beads compaction
- Provides context for future sessions
- Helps @qa understand what was done

### 7. Dependencies

**Purpose**: Track what blocks what

**Usage**:
```bash
# QA task depends on implementation tasks
bd dep add $QA_TASK $BACKEND_TASK
bd dep add $QA_TASK $FRONTEND_TASK

# View dependency tree
bd dep tree $EPIC

# Detect cycles
bd dep cycles
```

**Dependency types**:
- `blocks` (default) - Hard blocker
- `related` - Soft relationship
- `parent-child` - Hierarchy
- `discovered-from` - Bug found during work

### 8. Comments

**Purpose**: Append-only notes and approvals

**Usage**:
```bash
# Add progress comment
bd comments add $ID "Progress: 5 files edited"

# Add QA approval
bd comments add $ID "QA APPROVED: Verified login flow, added tests"
```

**Why comments (not notes)**:
- Comments are append-only (preserved)
- Notes can be overwritten
- "QA APPROVED" in comments is our approval signal

### 9. Git Hooks

**Purpose**: Auto-sync Beads with git

**Installation**:
```bash
bd hooks install
```

**Hooks installed**:
- `pre-commit` - Export before commit
- `post-merge` - Import after pull
- `pre-push` - Ensure sync before push

### 10. bd doctor

**Purpose**: Health checks

**Usage**:
```bash
bd doctor           # Full diagnostics
bd doctor --quiet   # Silent (for scripts)
bd doctor --fix     # Auto-repair issues
```

**What it checks**:
- Database integrity
- Schema compatibility
- Git hook installation
- Daemon health
- Dependency cycles

---

## Commands Cheat Sheet

### Finding Work

```bash
bd ready                    # Tasks with no blockers
bd blocked                  # Tasks waiting on dependencies
bd list --status open       # All open tasks
bd list --status in_progress # Currently active
bd list --label qa-pending  # Awaiting QA
bd list --label qa-approved # QA signed off
```

### Creating Tasks

```bash
# Simple task
bd create "Fix login bug" -t bug -p 1 -l bug,qa-pending

# Task with description
bd create "Add dark mode" -t feature -p 2 \
    --description "Implement dark mode toggle in settings" \
    -l frontend,qa-pending

# Epic
bd create "Epic: User Auth" -t epic -p 1 --description "..."

# Child of epic
bd create "Backend: API" -p 1 --parent $EPIC -l backend,qa-pending

# Bug discovered during work
bd create "Bug: edge case" -t bug -p 1 \
    --deps discovered-from:$PARENT_TASK \
    -l bug,qa-pending
```

### Claiming & Tracking

```bash
# Claim task
bd update $ID --status in_progress

# Update notes
bd update $ID --notes "COMPLETED: X | IN PROGRESS: Y"

# Add comment
bd comments add $ID "Progress update"

# Add/remove labels
bd label add $ID qa-pending
bd label remove $ID qa-pending
bd label add $ID qa-approved
```

### Dependencies

```bash
bd dep add $CHILD $PARENT      # Parent blocks child
bd dep tree $ID                # View tree
bd dep cycles                  # Detect cycles
bd dep remove $CHILD $PARENT   # Remove dependency
```

### Closing Tasks

```bash
bd close $ID --reason "Implemented and verified"
```

### Health & Sync

```bash
bd doctor          # Health check
bd sync            # Force sync
bd info            # Database info
```

---

## QA Approval via Beads

The Stop hook checks for QA approval in two places:

### 1. Label Check

```bash
LABELS=$(bd show "$TASK" --json | jq -r '.labels | join(",")')
if echo "$LABELS" | grep -qi "qa-approved"; then
    QA_APPROVED=true
fi
```

### 2. Comment Check

```bash
QA_COMMENT=$(bd show "$TASK" --json | jq -r '.comments[]? | select(test("QA APPROVED";"i"))')
if [ -n "$QA_COMMENT" ]; then
    QA_APPROVED=true
fi
```

### Approval Process

@qa agent:
```bash
# 1. Add approval comment
bd comments add $ID "QA APPROVED: Verified login flow, session handling.
Tests: 5 E2E, 12 unit - all passing."

# 2. Update labels
bd label remove $ID qa-pending
bd label add $ID qa-approved

# 3. Update notes
bd update $ID --notes "COMPLETED: QA review passed"
```

---

## Beads Database Structure

```
.beads/
├── beads.db           # SQLite cache (fast queries, not committed)
├── beads.db-shm       # SQLite shared memory
├── beads.db-wal       # SQLite write-ahead log
├── issues.jsonl       # Git-tracked issues (one JSON per line)
├── metadata.json      # Backend configuration
├── config.yaml        # User configuration
└── deletions.jsonl    # Tombstone manifest (optional)
```

**What's committed to git**: Only `issues.jsonl` (and `metadata.json`, `config.yaml`)

**What's local-only**: `beads.db` and SQLite files

---

## Troubleshooting

### "Beads not found"

```bash
# Install Beads
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash

# Or via Homebrew
brew tap steveyegge/beads && brew install beads

# Verify
bd --version
```

### "Beads not initialized"

```bash
cd your-project
bd init --quiet
bd hooks install
```

### "bd doctor shows errors"

```bash
# Auto-fix common issues
bd doctor --fix

# If still failing, check specific errors
bd doctor
```

### "Tasks not syncing"

```bash
# Force sync
bd sync

# Check git hooks
bd hooks install

# Verify .beads/ is tracked
git status .beads/
```

### "Can't find my tasks"

```bash
# List all
bd list

# Search
bd search "keyword"

# Check status filter
bd list --status open
bd list --status in_progress
bd list --status closed
```

---

## Advanced Usage

### Multi-Project Setup

Each project has its own `.beads/` directory. Tasks don't cross projects.

### JSON Output

All commands support `--json` for scripting:
```bash
bd ready --json | jq '.[0].id'
bd show $ID --json | jq '.labels'
```

### Environment Variables

```bash
BEADS_DB        # Custom database path
BEADS_ACTOR     # Actor name for audit trail
BEADS_NO_DAEMON # Disable daemon mode
```

### Compaction

Beads can compact old closed issues to save context:
```bash
bd admin compact --analyze
bd admin compact --apply --id $ID --summary summary.txt
```

Our structured notes format survives compaction, providing context even after details are trimmed.

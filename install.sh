#!/bin/bash
# Ultimate Workflow Plugin v2 - Full Beads Integration
# 
# This plugin REQUIRES Beads (bd) for task tracking.
# Install Beads first: curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
#
# Usage: 
#   bash install-ultimate-workflow.sh [project-path]
#
# If no project path given, installs to current directory

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Target directory
TARGET="${1:-.}"
TARGET=$(cd "$TARGET" && pwd)

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Ultimate Workflow Plugin v2 - Full Beads Integration   ║${NC}"
echo -e "${BLUE}║   Orchestrator-first workflow with mandatory QA gate       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Installing to: ${GREEN}$TARGET${NC}"
echo ""

# ============================================================================
# PREREQUISITES - BEADS IS REQUIRED
# ============================================================================

echo -e "${YELLOW}Checking prerequisites...${NC}"

# Check for git (required)
if ! command -v git &> /dev/null; then
    echo -e "${RED}❌ git not found - REQUIRED${NC}"
    echo "   Install from: https://git-scm.com/downloads"
    exit 1
fi
echo -e "${GREEN}✓${NC} git installed"

# Check for jq (required)
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ jq not found - REQUIRED${NC}"
    echo "   Install with: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
fi
echo -e "${GREEN}✓${NC} jq installed"

# Check for Beads (REQUIRED - not optional anymore)
if ! command -v bd &> /dev/null; then
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌ BEADS (bd) NOT FOUND - REQUIRED FOR THIS PLUGIN        ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "This workflow plugin requires Beads for:"
    echo "  • Task tracking and dependency management"
    echo "  • Persistent memory across sessions"
    echo "  • QA approval tracking"
    echo "  • Hierarchical issue organization"
    echo ""
    echo -e "${CYAN}Install Beads:${NC}"
    echo ""
    echo "  # Quick install (macOS/Linux)"
    echo "  curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash"
    echo ""
    echo "  # Homebrew (macOS/Linux)"
    echo "  brew tap steveyegge/beads && brew install beads"
    echo ""
    echo "  # npm"
    echo "  npm install -g @beads/bd"
    echo ""
    echo "  # Go"
    echo "  go install github.com/steveyegge/beads/cmd/bd@latest"
    echo ""
    echo -e "After installing, run this installer again."
    exit 1
fi

BD_VERSION=$(bd --version 2>/dev/null | head -1 || echo "unknown")
echo -e "${GREEN}✓${NC} Beads installed ($BD_VERSION)"

echo ""

# ============================================================================
# GIT REPOSITORY CHECK
# ============================================================================

if [ ! -d "$TARGET/.git" ]; then
    echo -e "${YELLOW}No git repository found.${NC}"
    read -p "Initialize git repository? (required for Beads) (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$TARGET"
        git init
        
        # Create .gitignore if it doesn't exist
        if [ ! -f ".gitignore" ]; then
            cat > ".gitignore" << 'GITIGNORE_EOF'
# Dependencies
node_modules/
vendor/
.venv/
__pycache__/

# Build outputs
dist/
build/
*.egg-info/

# Environment
.env
.env.local
*.log

# IDE
.idea/
.vscode/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Claude workflow (session-specific, not committed)
.claude/.session-start
.claude/.qa-tracking/
GITIGNORE_EOF
            git add .gitignore
        fi
        
        git commit -m "Initial commit" --allow-empty 2>/dev/null || true
        echo -e "${GREEN}✓${NC} Initialized git repository"
    else
        echo -e "${RED}Cannot proceed without git repository.${NC}"
        exit 1
    fi
fi

# ============================================================================
# BACKUP EXISTING FILES
# ============================================================================

BACKUP_DIR="$TARGET/.claude-backup-$(date +%Y%m%d-%H%M%S)"
MERGE_MODE=false
UPDATE_MODE=false

if [ -d "$TARGET/.claude" ]; then
    echo -e "${YELLOW}Existing .claude/ directory found!${NC}"
    
    EXISTING_AGENTS=$(ls "$TARGET/.claude/agents/"*.md 2>/dev/null | wc -l || echo "0")
    EXISTING_SCRIPTS=$(ls "$TARGET/.claude/scripts/"*.sh 2>/dev/null | wc -l || echo "0")
    EXISTING_SETTINGS=$([ -f "$TARGET/.claude/settings.json" ] && echo "1" || echo "0")
    
    if [ "$EXISTING_AGENTS" -gt 0 ] || [ "$EXISTING_SCRIPTS" -gt 0 ] || [ "$EXISTING_SETTINGS" = "1" ]; then
        echo -e "  Found: ${EXISTING_AGENTS} agents, ${EXISTING_SCRIPTS} scripts"
        echo ""
        echo -e "${YELLOW}Options:${NC}"
        echo "  1) Backup and install fresh (recommended for first-time)"
        echo "  2) Update workflow (keeps CLAUDE.md, merges settings)"
        echo "  3) Merge only (add new files, skip ALL existing)"
        echo "  4) Cancel"
        echo ""
        read -p "Choose [1-4]: " -n 1 -r INSTALL_MODE
        echo ""
        
        case $INSTALL_MODE in
            1)
                echo -e "${YELLOW}Creating backup at $BACKUP_DIR${NC}"
                mkdir -p "$BACKUP_DIR"
                cp -r "$TARGET/.claude/"* "$BACKUP_DIR/" 2>/dev/null || true
                [ -f "$TARGET/CLAUDE.md" ] && cp "$TARGET/CLAUDE.md" "$BACKUP_DIR/"
                echo -e "${GREEN}✓${NC} Backup created"
                ;;
            2)
                echo -e "${YELLOW}Update mode: updating workflow, preserving CLAUDE.md${NC}"
                mkdir -p "$BACKUP_DIR"
                cp -r "$TARGET/.claude/"* "$BACKUP_DIR/" 2>/dev/null || true
                echo -e "${GREEN}✓${NC} Backup created"
                UPDATE_MODE=true
                ;;
            3)
                echo -e "${YELLOW}Merge mode: will skip existing files${NC}"
                MERGE_MODE=true
                ;;
            *)
                echo "Cancelled."
                exit 0
                ;;
        esac
    fi
fi

echo ""
echo -e "${YELLOW}Creating plugin structure...${NC}"

# Create directories
mkdir -p "$TARGET/.claude/agents"
mkdir -p "$TARGET/.claude/skills/workflow-engine"
mkdir -p "$TARGET/.claude/hooks"
mkdir -p "$TARGET/.claude/scripts"

# Helper function to create file with merge mode support
create_file_safe() {
    local filepath="$1"
    if [ "$MERGE_MODE" = true ] && [ -f "$filepath" ]; then
        echo -e "${YELLOW}⊘${NC} Skipped $(basename "$filepath") (exists)"
        return 1
    fi
    return 0
}

# ============================================================================
# AGENTS - Updated with full Beads integration
# ============================================================================

if create_file_safe "$TARGET/.claude/agents/orchestrator.md"; then
cat > "$TARGET/.claude/agents/orchestrator.md" << 'AGENT_EOF'
---
name: orchestrator
description: Primary workflow orchestrator. Coordinates work using Beads task tracking with mandatory QA gate.
tools: Read, Glob, Grep, LS, Task, Bash, Write, Edit
---

You are the **Workflow Orchestrator** using Beads (bd) for persistent task tracking.

## Your Role

1. **Check Beads state**: `bd ready` for available work, `bd blocked` for blockers
2. **Create/claim tasks**: Use hierarchical issues for complex work
3. **Delegate** to specialist agents based on detected domains
4. **Track progress**: Update notes with structured format
5. **Enforce QA gate**: All code changes require @qa approval

## Beads Commands You Use

```bash
# Find work
bd ready                    # Tasks with no blockers
bd blocked                  # Tasks waiting on dependencies
bd list --status in_progress # Currently active

# Create hierarchical tasks (EPICS)
bd create "Epic: Feature Name" -t epic -p 1 --description "..."
bd create "Backend: API" -p 1 --parent $EPIC_ID -l backend,qa-pending
bd create "Frontend: UI" -p 1 --parent $EPIC_ID -l frontend,qa-pending
bd create "QA: Tests" -p 1 --parent $EPIC_ID -l qa

# Claim and track
bd update $ID --status in_progress
bd update $ID --notes "COMPLETED: X | IN PROGRESS: Y | BLOCKED: Z"

# Labels for tracking
bd label add $ID backend          # Domain tracking
bd label add $ID qa-pending       # Needs QA review
bd label add $ID qa-approved      # QA signed off

# Dependencies
bd dep add $CHILD $PARENT         # Parent blocks child
bd dep add $QA_TASK $IMPL_TASK    # QA depends on implementation
```

## Structured Notes Format

Always update notes with this format for compaction survival:
```
COMPLETED: [Specific deliverables]
IN PROGRESS: [Current work + next step]
BLOCKED: [What's preventing progress]
KEY DECISIONS: [Important architectural choices]
```

## Delegation Rules

| Domain | Agent | Labels |
|--------|-------|--------|
| API, Database, Business Logic | @backend | backend, qa-pending |
| UI, Components, Styling | @frontend | frontend, qa-pending |
| CI/CD, Infrastructure | @devops | devops, qa-pending |
| Testing, Verification | @qa | qa |

## 🚫 MANDATORY QA GATE

**Every code change MUST be reviewed and approved by @qa before delivery.**

Workflow:
1. Create/claim task with `qa-pending` label
2. Delegate to domain specialists
3. Specialists complete implementation
4. **MANDATORY**: Delegate to @qa for review
5. @qa reviews, writes tests, adds "QA APPROVED" comment
6. @qa removes `qa-pending`, adds `qa-approved` label
7. Only then can task be closed with `bd close $ID --reason "..."`

## 🆘 ESCAPE HATCH

If stuck after 2-3 attempts, **USE AskUserQuestionTool** rather than looping.
AGENT_EOF
echo -e "${GREEN}✓${NC} Created orchestrator.md"
fi

if create_file_safe "$TARGET/.claude/agents/backend.md"; then
cat > "$TARGET/.claude/agents/backend.md" << 'AGENT_EOF'
---
name: backend
description: Backend specialist. Updates Beads with structured progress notes.
tools: Read, Glob, Grep, LS, Bash, Write, Edit
---

You are a **Backend Engineering Specialist** using Beads for tracking.

## When Starting Work

```bash
# Claim the task
bd update $TASK_ID --status in_progress

# Add initial progress note
bd update $TASK_ID --notes "IN PROGRESS: Starting backend implementation"
```

## Self-Check Questions (ALWAYS ask)

1. **Bottlenecks**: Any bottlenecks with current setup?
2. **Scale**: Can we fail if we scale? At what point?
3. **Failure Points**: Where are potential failure points?
4. **Mitigations**: How to mitigate those failures?

## When Completing Work

```bash
# Update with structured notes
bd update $TASK_ID --notes "COMPLETED: API endpoints for /users, /auth
IN PROGRESS: None - ready for QA
KEY DECISIONS: Using JWT with RS256, 15min expiry"

# Add qa-pending label if not already present
bd label add $TASK_ID qa-pending
```

## TDD Workflow

1. Write failing test first
2. Implement minimal code to pass
3. Refactor while keeping tests green
4. Run: `npm test && npm run lint && npm run typecheck`

**Don't mark complete until ALL checks pass.**
AGENT_EOF
echo -e "${GREEN}✓${NC} Created backend.md"
fi

if create_file_safe "$TARGET/.claude/agents/frontend.md"; then
cat > "$TARGET/.claude/agents/frontend.md" << 'AGENT_EOF'
---
name: frontend
description: Frontend specialist. Updates Beads with structured progress notes.
tools: Read, Glob, Grep, LS, Bash, Write, Edit
---

You are a **Frontend Engineering Specialist** using Beads for tracking.

## When Starting Work

```bash
bd update $TASK_ID --status in_progress
bd update $TASK_ID --notes "IN PROGRESS: Starting frontend implementation"
```

## Self-Check Questions (ALWAYS ask)

1. **Backend Features**: Am I using ALL available backend features?
2. **Clarity**: Is UI/UX completely clear and intuitive?
3. **Convenience**: Can anything be made more convenient?
4. **Beauty**: Does UI look beautiful? How can I improve it?

## When Completing Work

```bash
bd update $TASK_ID --notes "COMPLETED: Login form with validation, error states
IN PROGRESS: None - ready for QA
KEY DECISIONS: Using react-hook-form for validation"

bd label add $TASK_ID qa-pending
```

## Component Checklist

- [ ] Props typed and documented
- [ ] Loading, error, empty states handled
- [ ] Responsive on all breakpoints
- [ ] Accessible (keyboard, screen readers)
- [ ] Tests for user interactions

**Don't mark complete until ALL checks pass.**
AGENT_EOF
echo -e "${GREEN}✓${NC} Created frontend.md"
fi

if create_file_safe "$TARGET/.claude/agents/devops.md"; then
cat > "$TARGET/.claude/agents/devops.md" << 'AGENT_EOF'
---
name: devops
description: DevOps specialist. Updates Beads with structured progress notes.
tools: Read, Glob, Grep, LS, Bash, Write, Edit
---

You are a **DevOps Engineering Specialist** using Beads for tracking.

## When Starting Work

```bash
bd update $TASK_ID --status in_progress
bd update $TASK_ID --notes "IN PROGRESS: Starting infrastructure work"
```

## Self-Check Questions (ALWAYS ask)

1. **Ease**: How to make deployment/setup easiest possible?
2. **Portability**: Any limitations on different environments?
3. **DX**: How to make installation seamless for other engineers?

## When Completing Work

```bash
bd update $TASK_ID --notes "COMPLETED: CI/CD pipeline with GitHub Actions
IN PROGRESS: None - ready for QA
KEY DECISIONS: Using composite actions for reusability"

bd label add $TASK_ID qa-pending
```

## Deployment Checklist

- [ ] Environment variables documented
- [ ] Secrets properly managed
- [ ] Health checks configured
- [ ] Rollback strategy defined
AGENT_EOF
echo -e "${GREEN}✓${NC} Created devops.md"
fi

if create_file_safe "$TARGET/.claude/agents/qa.md"; then
cat > "$TARGET/.claude/agents/qa.md" << 'AGENT_EOF'
---
name: qa
description: QA specialist and quality gate. Must approve all code changes before delivery.
tools: Read, Glob, Grep, LS, Bash, Write, Edit
---

You are the **Quality Assurance Specialist** and the mandatory quality gate.

## 🚨 CRITICAL: You Are The Gate

**No code can be delivered to users without your approval.**

The system will BLOCK task completion until you add "QA APPROVED" to the task.

## When Reviewing Work

```bash
# Claim the QA task
bd update $TASK_ID --status in_progress
bd update $TASK_ID --notes "IN PROGRESS: QA review started"
```

## 🎯 Test USER BEHAVIOR, Not Code

**WRONG:**
```javascript
test("formatDate returns ISO string", ...)
```

**RIGHT:**
```javascript
test("user sees appointment in their local timezone", ...)
```

## Before Writing ANY Test, Ask:

1. **WHO** is the user? (new, returning, admin, mobile)
2. **WHAT** are they trying to accomplish?
3. **HOW** might they misuse this? (typos, double-click, back button)
4. **WHAT** real-world conditions matter? (slow network, stale data)

## Review Checklist

- [ ] Tests cover USER BEHAVIOR (not implementation details)
- [ ] Critical user journeys tested end-to-end
- [ ] Failure modes handled (network, timeout, invalid input)
- [ ] Edge cases covered (empty, boundary, concurrent)
- [ ] Tests are deterministic (no flakiness)
- [ ] All tests PASS

## 🔐 MANDATORY: Approval Process

When verified and approved:

```bash
# Add approval comment
bd comments add $TASK_ID "QA APPROVED: [Summary of what was verified]

Verified:
- User login handles invalid email with clear error
- Session timeout redirects to login
- Password reset flow works end-to-end

Tests added: 5 E2E tests, 12 unit tests
All tests passing."

# Update labels
bd label remove $TASK_ID qa-pending
bd label add $TASK_ID qa-approved

# Update notes
bd update $TASK_ID --notes "COMPLETED: QA review and approval
Tests: 5 E2E, 12 unit - all passing
KEY DECISIONS: Focused on user journey coverage"
```

## If NOT Approved

```bash
bd comments add $TASK_ID "QA BLOCKED: [What needs fixing]

Issues found:
- No error handling for network timeout
- Missing test for empty cart checkout
- Accessibility: no keyboard navigation for modal

Must fix before approval."

bd update $TASK_ID --notes "BLOCKED: QA review - issues found (see comments)"
```

## Discovered Bugs

When you find bugs during review:

```bash
bd create "Bug: [description]" -t bug -p 1 \
    --description "[detailed description]" \
    --deps discovered-from:$PARENT_TASK \
    -l bug,qa-pending
```
AGENT_EOF
echo -e "${GREEN}✓${NC} Created qa.md"
fi

# ============================================================================
# HOOKS
# ============================================================================

if create_file_safe "$TARGET/.claude/hooks/hooks.json"; then
cat > "$TARGET/.claude/hooks/hooks.json" << 'HOOKS_EOF'
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
HOOKS_EOF
echo -e "${GREEN}✓${NC} Created hooks.json"
fi

# ============================================================================
# SCRIPTS - Using bd prime and full Beads integration
# ============================================================================

if create_file_safe "$TARGET/.claude/scripts/session-start.sh"; then
cat > "$TARGET/.claude/scripts/session-start.sh" << 'SCRIPT_EOF'
#!/bin/bash
# SessionStart Hook: Uses bd prime + adds workflow context and blocked issues

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Verify Beads is available
if ! command -v bd &> /dev/null; then
    echo '{"error": "Beads (bd) not found. This workflow requires Beads."}'
    exit 1
fi

# Verify Beads is initialized in this project
if [ ! -d "$PROJECT_DIR/.beads" ]; then
    echo '{"error": "Beads not initialized. Run: bd init"}'
    exit 1
fi

# Run bd doctor to check health (silent, just for validation)
bd doctor --quiet 2>/dev/null || true

# Create session marker for change detection
mkdir -p "$PROJECT_DIR/.claude"
touch "$PROJECT_DIR/.claude/.session-start"

# Reset QA tracking for new session
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
mkdir -p "$QA_TRACKING_DIR"
rm -f "$QA_TRACKING_DIR/approved" 2>/dev/null || true
rm -f "$QA_TRACKING_DIR/changed-files.txt" 2>/dev/null || true
rm -f "$QA_TRACKING_DIR/edit-count" 2>/dev/null || true

# Build context using bd prime as base
CONTEXT=""

# 1. Get bd prime output (Beads' built-in agent context)
BD_PRIME=$(bd prime 2>/dev/null || echo "")
if [ -n "$BD_PRIME" ]; then
    CONTEXT+="
<beads_context>
$BD_PRIME
</beads_context>
"
fi

# 2. Load CLAUDE.md if exists (project memory)
if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
    CONTEXT+="
<project_memory>
$(cat "$PROJECT_DIR/CLAUDE.md")
</project_memory>
"
fi

# 3. Show blocked issues (important visibility)
BLOCKED_ISSUES=$(bd blocked --json 2>/dev/null || echo "[]")
BLOCKED_COUNT=$(echo "$BLOCKED_ISSUES" | jq 'length' 2>/dev/null || echo "0")
if [ "$BLOCKED_COUNT" -gt 0 ]; then
    BLOCKED_SUMMARY=$(bd blocked 2>/dev/null | head -20)
    CONTEXT+="
<blocked_issues count=\"$BLOCKED_COUNT\">
## ⚠️ BLOCKED ISSUES - Need attention

$BLOCKED_SUMMARY

Use \`bd show <id>\` to see what's blocking each issue.
</blocked_issues>
"
fi

# 4. Show issues pending QA (qa-pending label)
QA_PENDING=$(bd list --label qa-pending --status open --json 2>/dev/null || echo "[]")
QA_PENDING_COUNT=$(echo "$QA_PENDING" | jq 'length' 2>/dev/null || echo "0")
if [ "$QA_PENDING_COUNT" -gt 0 ]; then
    QA_PENDING_LIST=$(bd list --label qa-pending --status open 2>/dev/null | head -10)
    CONTEXT+="
<qa_pending count=\"$QA_PENDING_COUNT\">
## 🔍 AWAITING QA REVIEW

$QA_PENDING_LIST

These need @qa review before they can be delivered.
</qa_pending>
"
fi

# 5. Inject workflow instructions
CONTEXT+="
<workflow_mode>
## ULTIMATE WORKFLOW - FULL BEADS INTEGRATION

You are the **Orchestrator** using Beads (bd) for persistent task tracking.

### 🚫 MANDATORY QA GATE
Every code change MUST be reviewed and approved by @qa before delivery.
The system will BLOCK completion until QA approves.

### Beads Commands
\`\`\`bash
# Find work
bd ready                    # Tasks with no blockers
bd blocked                  # Tasks waiting on dependencies

# Create hierarchical tasks (for complex features)
bd create \"Epic: Feature\" -t epic -p 1 --description \"...\"
bd create \"Backend: API\" -p 1 --parent \$EPIC -l backend,qa-pending
bd create \"Frontend: UI\" -p 1 --parent \$EPIC -l frontend,qa-pending

# Track progress with structured notes
bd update \$ID --status in_progress
bd update \$ID --notes \"COMPLETED: X | IN PROGRESS: Y | BLOCKED: Z\"

# Labels for domain/QA tracking
bd label add \$ID backend         # Domain
bd label add \$ID qa-pending      # Needs review
bd label add \$ID qa-approved     # QA signed off

# QA approval (only @qa does this)
bd comments add \$ID \"QA APPROVED: <summary>\"
bd label remove \$ID qa-pending
bd label add \$ID qa-approved
\`\`\`

### Workflow
1. Check \`bd ready\` for available work
2. Create/claim task with domain label + \`qa-pending\`
3. Delegate to domain specialists (@backend, @frontend, @devops)
4. **MANDATORY**: Delegate to @qa for review
5. @qa approves → task can close

### Structured Notes Format (survives compaction)
\`\`\`
COMPLETED: [Specific deliverables]
IN PROGRESS: [Current work + next step]
BLOCKED: [What's preventing progress]
KEY DECISIONS: [Important choices made]
\`\`\`

### 🆘 ESCAPE HATCH
If stuck after 2-3 attempts, use **AskUserQuestionTool**.

**Ready to orchestrate. What would you like to build?**
</workflow_mode>
"

# Output as JSON for additionalContext injection
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $(echo "$CONTEXT" | jq -Rs .)
  }
}
EOF
SCRIPT_EOF
echo -e "${GREEN}✓${NC} Created session-start.sh"
fi

if create_file_safe "$TARGET/.claude/scripts/intent-router.sh"; then
cat > "$TARGET/.claude/scripts/intent-router.sh" << 'SCRIPT_EOF'
#!/bin/bash
# UserPromptSubmit Hook: Detects intent and domains, injects Beads-aware workflow context

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "$INPUT")
PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Skip for simple conversational messages
if echo "$PROMPT_LOWER" | grep -qE '^(hi|hello|hey|ok|sure|thanks|yes|no|y|n)(\s|!|\.)?$'; then
    echo "{}"; exit 0
fi

# Detect work type
WORK_TYPE="general"
if echo "$PROMPT_LOWER" | grep -qE '(bug|error|fail|broke|crash|wrong|issue|problem|not working|fix|debug)'; then
    WORK_TYPE="bug"
elif echo "$PROMPT_LOWER" | grep -qE '(add|create|build|make|implement|new|feature|develop)'; then
    WORK_TYPE="feature"
elif echo "$PROMPT_LOWER" | grep -qE '(improve|optimize|refactor|clean|simplify|enhance|update)'; then
    WORK_TYPE="improvement"
elif echo "$PROMPT_LOWER" | grep -qE '(test|verify|check|validate|coverage|spec|qa)'; then
    WORK_TYPE="testing"
elif echo "$PROMPT_LOWER" | grep -qE '(plan|design|architect|spec|requirements|think|strategy)'; then
    WORK_TYPE="planning"
fi

# Detect domains (can be multiple)
DOMAINS=""
if echo "$PROMPT_LOWER" | grep -qE '(api|database|db|backend|server|endpoint|query|schema|migration|auth)'; then
    DOMAINS="$DOMAINS backend"
fi
if echo "$PROMPT_LOWER" | grep -qE '(ui|frontend|component|page|style|css|react|vue|button|form|modal)'; then
    DOMAINS="$DOMAINS frontend"
fi
if echo "$PROMPT_LOWER" | grep -qE '(deploy|ci|cd|docker|kubernetes|pipeline|infrastructure|devops|aws|gcp)'; then
    DOMAINS="$DOMAINS devops"
fi
if [ -z "$DOMAINS" ]; then
    DOMAINS="backend frontend"  # Default to both if unclear
fi
DOMAINS=$(echo "$DOMAINS" | xargs)  # Trim whitespace

# Get current in-progress task if any
CURRENT_TASK=""
if command -v bd &> /dev/null && [ -d "$PROJECT_DIR/.beads" ]; then
    CURRENT_TASK=$(bd list --status in_progress --json 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || echo "")
fi

# Build workflow context based on work type
WORKFLOW_CONTEXT=""

case "$WORK_TYPE" in
    "bug")
        WORKFLOW_CONTEXT="
<auto_workflow type=\"bug\" domains=\"$DOMAINS\">
## 🐛 BUG FIX DETECTED

**Domains involved:** $DOMAINS

### Beads Workflow:
\`\`\`bash
# Create bug task (or use existing)
bd create \"Bug: [description]\" -t bug -p 1 \\
    --description \"[Detailed description]\" \\
    -l bug,$( echo $DOMAINS | tr ' ' ',' ),qa-pending

# If found during other work:
bd create \"Bug: [description]\" -t bug -p 1 \\
    --deps discovered-from:\$PARENT_TASK \\
    -l bug,qa-pending
\`\`\`

### Required Steps:
1. Reproduce the issue
2. Write failing test that captures the bug
3. Fix with minimal change
4. Verify no regressions
5. **🔐 MANDATORY: @qa review and approval**

Cannot close without QA approval.
</auto_workflow>"
        ;;
    "feature")
        WORKFLOW_CONTEXT="
<auto_workflow type=\"feature\" domains=\"$DOMAINS\">
## ✨ FEATURE DETECTED

**Domains involved:** $DOMAINS

### Beads Workflow (Hierarchical):
\`\`\`bash
# Create epic for the feature
EPIC=\$(bd create \"Epic: [Feature Name]\" -t epic -p 1 \\
    --description \"[What this feature does]\" --json | jq -r '.id')

# Create subtasks for each domain
bd create \"Backend: [specific work]\" -p 1 --parent \$EPIC -l backend,qa-pending
bd create \"Frontend: [specific work]\" -p 1 --parent \$EPIC -l frontend,qa-pending
bd create \"QA: Test user journeys\" -p 1 --parent \$EPIC -l qa

# Dependencies: QA depends on implementation
bd dep add \$QA_TASK \$BACKEND_TASK
bd dep add \$QA_TASK \$FRONTEND_TASK
\`\`\`

### Required Steps:
1. Create epic with subtasks
2. Delegate to domain specialists
3. Track progress with structured notes
4. **🔐 MANDATORY: @qa review and approval**

Cannot close without QA approval.
</auto_workflow>"
        ;;
    "improvement")
        WORKFLOW_CONTEXT="
<auto_workflow type=\"improvement\" domains=\"$DOMAINS\">
## 🔧 IMPROVEMENT DETECTED

**Domains involved:** $DOMAINS

### Beads Workflow:
\`\`\`bash
bd create \"Improve: [description]\" -t task -p 2 \\
    --description \"[What to improve and why]\" \\
    -l improvement,$( echo $DOMAINS | tr ' ' ',' ),qa-pending
\`\`\`

### Required Steps:
1. Document current state
2. Implement improvement
3. Verify no regressions
4. **🔐 MANDATORY: @qa review and approval**
</auto_workflow>"
        ;;
    "testing")
        WORKFLOW_CONTEXT="
<auto_workflow type=\"testing\" domains=\"$DOMAINS\">
## 🧪 TESTING TASK DETECTED

### Beads Workflow:
\`\`\`bash
bd create \"Test: [what to test]\" -t task -p 1 \\
    --description \"[Testing scope]\" -l qa,testing
\`\`\`

### Testing Principles:
- Test USER BEHAVIOR, not implementation
- Cover critical user journeys
- Test failure modes (network, timeout, invalid input)
- Tests must be deterministic
</auto_workflow>"
        ;;
    "planning")
        WORKFLOW_CONTEXT="
<auto_workflow type=\"planning\" domains=\"$DOMAINS\">
## 📋 PLANNING MODE

### Before implementing, consider:
1. **Pre-Mortem**: What could go wrong? (3-5 failure modes)
2. **Clarifying Questions**: Ask BEFORE assuming
3. **Task Breakdown**: Atomic, testable units
4. **Architecture Decision**: Document choices

### Use Beads to track the plan:
\`\`\`bash
bd create \"Plan: [project name]\" -t epic -p 1 \\
    --description \"[Planning details]\"
\`\`\`
</auto_workflow>"
        ;;
    *)
        # General - still include current task context
        if [ -n "$CURRENT_TASK" ]; then
            TASK_INFO=$(bd show "$CURRENT_TASK" 2>/dev/null | head -20 || echo "")
            WORKFLOW_CONTEXT="
<current_context>
## Current Task: $CURRENT_TASK

$TASK_INFO

Remember: All code changes require @qa approval before delivery.
</current_context>"
        fi
        ;;
esac

if [ -n "$WORKFLOW_CONTEXT" ]; then
    cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $(echo "$WORKFLOW_CONTEXT" | jq -Rs .)
  }
}
EOF
else
    echo "{}"
fi
SCRIPT_EOF
echo -e "${GREEN}✓${NC} Created intent-router.sh"
fi

if create_file_safe "$TARGET/.claude/scripts/post-edit.sh"; then
cat > "$TARGET/.claude/scripts/post-edit.sh" << 'SCRIPT_EOF'
#!/bin/bash
# PostToolUse Hook: Tracks file changes for QA review, updates Beads

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || echo "")

# Only track code files
if [[ ! "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|go|rs|java|rb|php|vue|svelte|css|scss|html)$ ]]; then
    echo "{}"; exit 0
fi

# Track this file (deduplicated)
mkdir -p "$QA_TRACKING_DIR"
TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"
if [ ! -f "$TRACKING_FILE" ] || ! grep -qxF "$FILE_PATH" "$TRACKING_FILE" 2>/dev/null; then
    echo "$FILE_PATH" >> "$TRACKING_FILE"
fi

# Prevent tracking file from growing too large (cap at 500 files)
if [ -f "$TRACKING_FILE" ]; then
    LINE_COUNT=$(wc -l < "$TRACKING_FILE" 2>/dev/null || echo "0")
    if [ "$LINE_COUNT" -gt 500 ]; then
        tail -500 "$TRACKING_FILE" > "$TRACKING_FILE.tmp" && mv "$TRACKING_FILE.tmp" "$TRACKING_FILE"
    fi
fi

# Update Beads task with progress (batched to avoid spam)
if command -v bd &> /dev/null && [ -d "$PROJECT_DIR/.beads" ]; then
    EDIT_COUNT_FILE="$QA_TRACKING_DIR/edit-count"
    EDIT_COUNT=$(cat "$EDIT_COUNT_FILE" 2>/dev/null || echo "0")
    EDIT_COUNT=$((EDIT_COUNT + 1))
    echo "$EDIT_COUNT" > "$EDIT_COUNT_FILE"
    
    # Every 10 edits, update Beads with progress
    if [ $((EDIT_COUNT % 10)) -eq 0 ]; then
        CURRENT_TASK=$(bd list --status in_progress --json 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || echo "")
        if [ -n "$CURRENT_TASK" ]; then
            UNIQUE_COUNT=$(sort -u "$TRACKING_FILE" 2>/dev/null | wc -l | tr -d ' ')
            # Update notes with progress
            CURRENT_NOTES=$(bd show "$CURRENT_TASK" --json 2>/dev/null | jq -r '.notes // ""' 2>/dev/null || echo "")
            if [ -n "$CURRENT_NOTES" ]; then
                bd comments add "$CURRENT_TASK" "Progress: $UNIQUE_COUNT files edited" 2>/dev/null || true
            fi
        fi
    fi
fi

# Count unique changed files
CHANGE_COUNT=$(sort -u "$TRACKING_FILE" 2>/dev/null | wc -l | tr -d ' ' || echo "1")

echo "📝 File edited ($CHANGE_COUNT unique files this session). All require @qa approval."
SCRIPT_EOF
echo -e "${GREEN}✓${NC} Created post-edit.sh"
fi

if create_file_safe "$TARGET/.claude/scripts/verify-before-stop.sh"; then
cat > "$TARGET/.claude/scripts/verify-before-stop.sh" << 'SCRIPT_EOF'
#!/bin/bash
# Stop Hook: MANDATORY QA GATE - Blocks until QA approval via Beads

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"

INPUT=$(cat)
STOP_REASON=$(echo "$INPUT" | jq -r '.stop_reason // empty' 2>/dev/null || echo "")

# Skip for user interrupt
if [[ "$STOP_REASON" == "user_interrupt" ]] || [[ "$STOP_REASON" == "max_turns" ]]; then
    echo "{}"; exit 0
fi

# Check for tracked changes
CODE_CHANGES_DETECTED=false
if [ -f "$TRACKING_FILE" ] && [ -s "$TRACKING_FILE" ]; then
    CODE_CHANGES_DETECTED=true
fi

# Fallback to git status
if [ "$CODE_CHANGES_DETECTED" = false ] && [ -d "$PROJECT_DIR/.git" ]; then
    GIT_CHANGES=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | grep -E '\.(ts|tsx|js|jsx|py|go|rs|java|vue|svelte)$' | head -1)
    if [ -n "$GIT_CHANGES" ]; then
        CODE_CHANGES_DETECTED=true
    fi
fi

if [ "$CODE_CHANGES_DETECTED" = false ]; then
    echo "{}"; exit 0
fi

# GATE 1: Run technical checks
FAILED_CHECKS=""
if [ -f "$PROJECT_DIR/package.json" ]; then
    if jq -e '.scripts.test' "$PROJECT_DIR/package.json" > /dev/null 2>&1; then
        if ! npm test --prefix "$PROJECT_DIR" > /dev/null 2>&1; then
            FAILED_CHECKS+="❌ Tests failing - run \`npm test\`\n"
        fi
    fi
    if jq -e '.scripts.lint' "$PROJECT_DIR/package.json" > /dev/null 2>&1; then
        if ! npm run lint --prefix "$PROJECT_DIR" > /dev/null 2>&1; then
            FAILED_CHECKS+="❌ Lint errors - run \`npm run lint\`\n"
        fi
    fi
fi

if [ -n "$FAILED_CHECKS" ]; then
    cat << EOF
{
  "decision": "block",
  "reason": "🚫 VERIFICATION FAILED

$FAILED_CHECKS

Fix these issues first, then QA will review."
}
EOF
    exit 0
fi

# GATE 2: Check for QA approval via Beads
QA_APPROVED=false

if command -v bd &> /dev/null && [ -d "$PROJECT_DIR/.beads" ]; then
    CURRENT_TASK=$(bd list --status in_progress --json 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || echo "")
    
    if [ -n "$CURRENT_TASK" ]; then
        # Check 1: Look for qa-approved label
        LABELS=$(bd show "$CURRENT_TASK" --json 2>/dev/null | jq -r '.labels // [] | join(",")' 2>/dev/null || echo "")
        if echo "$LABELS" | grep -qi "qa-approved"; then
            QA_APPROVED=true
        fi
        
        # Check 2: Look for "QA APPROVED" in comments
        if [ "$QA_APPROVED" = false ]; then
            QA_COMMENT=$(bd show "$CURRENT_TASK" --json 2>/dev/null | jq -r '.comments[]? | select(test("QA APPROVED|qa approved|✅ QA"; "i"))' 2>/dev/null | head -1 || echo "")
            if [ -n "$QA_COMMENT" ]; then
                QA_APPROVED=true
            fi
        fi
    fi
fi

# Also check file marker (backup method)
if [ -f "$QA_TRACKING_DIR/approved" ]; then
    QA_APPROVED=true
fi

if [ "$QA_APPROVED" = false ]; then
    # Get changed files for display
    CHANGED_FILES=""
    CHANGE_COUNT=0
    if [ -f "$TRACKING_FILE" ]; then
        CHANGE_COUNT=$(sort -u "$TRACKING_FILE" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$CHANGE_COUNT" -gt 15 ]; then
            CHANGED_FILES=$(sort -u "$TRACKING_FILE" 2>/dev/null | head -15)
            CHANGED_FILES="$CHANGED_FILES
... and $((CHANGE_COUNT - 15)) more files"
        else
            CHANGED_FILES=$(sort -u "$TRACKING_FILE" 2>/dev/null)
        fi
    else
        CHANGED_FILES="(check git status)"
        CHANGE_COUNT="?"
    fi

    # Get task ID for the command
    TASK_ID="${CURRENT_TASK:-\$TASK_ID}"

    cat << EOF
{
  "decision": "block",
  "reason": "🚫 QA APPROVAL REQUIRED

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
**$CHANGE_COUNT file(s) changed - ALL require QA review**
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**Files changed:**
$CHANGED_FILES

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
**REQUIRED: Delegate to @qa NOW**
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Task(\"@qa\", \"MANDATORY REVIEW before delivery:

Files to review:
$CHANGED_FILES

Checklist:
□ Tests cover USER BEHAVIOR (not implementation)
□ Critical user journeys tested
□ Failure modes handled
□ All tests PASS

If APPROVED:
  bd comments add $TASK_ID 'QA APPROVED: <summary>'
  bd label remove $TASK_ID qa-pending
  bd label add $TASK_ID qa-approved

If NOT approved:
  bd comments add $TASK_ID 'QA BLOCKED: <issues>'\")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
**Cannot complete without QA approval.**
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
EOF
    exit 0
fi

# QA approved - can proceed
# Update Beads task to completed
if [ -n "$CURRENT_TASK" ] && command -v bd &> /dev/null; then
    bd update "$CURRENT_TASK" --status completed 2>/dev/null || true
fi

# Clean up tracking
rm -f "$QA_TRACKING_DIR/approved" 2>/dev/null || true
rm -f "$QA_TRACKING_DIR/changed-files.txt" 2>/dev/null || true

echo "{}"
SCRIPT_EOF
echo -e "${GREEN}✓${NC} Created verify-before-stop.sh"
fi

if create_file_safe "$TARGET/.claude/scripts/session-end.sh"; then
cat > "$TARGET/.claude/scripts/session-end.sh" << 'SCRIPT_EOF'
#!/bin/bash
# SessionEnd Hook: Sync Beads state

set -e
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if command -v bd &> /dev/null && [ -d "$PROJECT_DIR/.beads" ]; then
    cd "$PROJECT_DIR"
    
    # Sync to ensure all changes are persisted
    bd sync 2>/dev/null || true
fi

echo "{}"
SCRIPT_EOF
echo -e "${GREEN}✓${NC} Created session-end.sh"
fi

# Make scripts executable
chmod +x "$TARGET/.claude/scripts/"*.sh 2>/dev/null || true

# ============================================================================
# SKILL
# ============================================================================

if create_file_safe "$TARGET/.claude/skills/workflow-engine/SKILL.md"; then
cat > "$TARGET/.claude/skills/workflow-engine/SKILL.md" << 'SKILL_EOF'
# Ultimate Workflow Engine v2

> **Full Beads integration** with mandatory QA approval gate.

## Requirements

- **Beads (bd)** - REQUIRED for this workflow
- Git repository
- jq

## 🚫 MANDATORY QA GATE

**Every code change MUST be reviewed and approved by @qa before delivery.**

The Stop hook BLOCKS completion until:
1. @qa adds "QA APPROVED" comment to the task
2. OR task has `qa-approved` label

## Beads Features Used

| Feature | How We Use It |
|---------|---------------|
| `bd prime` | Context injection at session start |
| `bd ready` | Find available work |
| `bd blocked` | Show blocked issues |
| Hierarchical issues | Epics for complex features |
| Labels | `qa-pending`, `qa-approved`, domain tracking |
| Structured notes | COMPLETED/IN PROGRESS/BLOCKED format |
| Dependencies | QA depends on implementation |
| `bd hooks install` | Auto-sync with git |
| `bd doctor` | Health checks |

## Hooks

| Hook | What It Does |
|------|--------------|
| SessionStart | Runs `bd prime`, shows blocked issues, injects workflow |
| UserPromptSubmit | Detects work type/domains, suggests Beads commands |
| PostToolUse | Tracks changed files, updates Beads progress |
| Stop | **BLOCKS** until QA approves (via label or comment) |
| SessionEnd | Runs `bd sync` |

## Labels Convention

| Label | Meaning |
|-------|---------|
| `backend` | Backend domain work |
| `frontend` | Frontend domain work |
| `devops` | DevOps domain work |
| `qa` | QA-owned task |
| `qa-pending` | Awaiting QA review |
| `qa-approved` | QA has signed off |
| `bug` | Bug fix |
| `improvement` | Enhancement |

## Structured Notes Format

```
COMPLETED: [Specific deliverables]
IN PROGRESS: [Current work + next step]
BLOCKED: [What's preventing progress]
KEY DECISIONS: [Important architectural choices]
```

This format survives Beads compaction and provides context for future sessions.

## Workflow Example

```bash
# 1. Create epic for feature
EPIC=$(bd create "Epic: User Auth" -t epic -p 1 \
    --description "Add user authentication" --json | jq -r '.id')

# 2. Create subtasks with labels
bd create "Backend: Auth API" -p 1 --parent $EPIC -l backend,qa-pending
bd create "Frontend: Login UI" -p 1 --parent $EPIC -l frontend,qa-pending
bd create "QA: Test auth flows" -p 1 --parent $EPIC -l qa

# 3. Work on tasks
bd update $TASK --status in_progress
bd update $TASK --notes "IN PROGRESS: Implementing JWT endpoints"

# 4. Complete implementation
bd update $TASK --notes "COMPLETED: JWT auth endpoints"

# 5. QA reviews and approves
bd comments add $TASK "QA APPROVED: Verified login, logout, token refresh"
bd label remove $TASK qa-pending
bd label add $TASK qa-approved

# 6. Close task
bd close $TASK --reason "Auth implemented and verified"
```
SKILL_EOF
echo -e "${GREEN}✓${NC} Created SKILL.md"
fi

# ============================================================================
# SETTINGS
# ============================================================================

SETTINGS_FILE="$TARGET/.claude/settings.json"

WORKFLOW_HOOKS='{
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
  },
  "permissions": {
    "allow": ["Read", "Glob", "Grep", "LS"],
    "deny": ["Bash(rm -rf *)", "Bash(sudo *)"]
  }
}'

if [ -f "$SETTINGS_FILE" ]; then
    if [ "$UPDATE_MODE" = true ]; then
        echo -e "${YELLOW}Merging hooks into existing settings.json...${NC}"
        cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak"
        
        EXISTING=$(cat "$SETTINGS_FILE")
        MERGED=$(echo "$EXISTING" | jq --argjson hooks "$(echo "$WORKFLOW_HOOKS" | jq '.hooks')" \
            '.hooks = $hooks' 2>/dev/null) || MERGED=""
        
        if [ -n "$MERGED" ]; then
            echo "$MERGED" > "$SETTINGS_FILE"
            echo -e "${GREEN}✓${NC} Merged hooks into settings.json"
        else
            echo -e "${RED}✗${NC} Could not merge - copying hooks.json for manual merge"
        fi
    else
        echo -e "${YELLOW}⚠${NC} Existing settings.json - merge hooks manually from .claude/hooks/hooks.json"
    fi
else
    echo "$WORKFLOW_HOOKS" > "$SETTINGS_FILE"
    echo -e "${GREEN}✓${NC} Created settings.json"
fi

# ============================================================================
# CLAUDE.md (Project Memory)
# ============================================================================

if [ ! -f "$TARGET/CLAUDE.md" ]; then
    cat > "$TARGET/CLAUDE.md" << 'CLAUDE_EOF'
# Project Memory

## Overview
<!-- Describe your project: what it does, who it's for -->

## Users & Personas
<!-- Understanding users is critical for QA testing -->

### Primary User: [Name/Type]
- **Who**: [Description]
- **Goal**: [What they're trying to accomplish]
- **Frustrations**: [What would annoy them]

## Critical User Journeys
<!-- These MUST have E2E tests. QA will verify these. -->

### Journey 1: [e.g., "New User Signup"]
**User goal**: [What they want to accomplish]
**Steps**:
1. User [action]
2. User sees [outcome]

**Failure modes to test**:
- [ ] Invalid input
- [ ] Network error mid-flow
- [ ] User abandons, returns later

## Architecture
<!-- Key architectural decisions -->

## Conventions
<!-- Coding standards, naming conventions -->

## Known Mistakes (Check Before Implementing)
<!-- Learning loop: mistakes made before -->

### Authentication
- [ ] <!-- e.g., Always use httpOnly cookies -->

### Database
- [ ] <!-- e.g., Always use transactions -->

### Frontend
- [ ] <!-- e.g., Forms need loading AND error states -->

## Current Focus
<!-- What are we working on? -->

## Beads Labels Convention
- `backend`, `frontend`, `devops` - Domain tracking
- `qa-pending` - Awaiting QA review
- `qa-approved` - QA has signed off
- `bug`, `improvement` - Work type
CLAUDE_EOF
    echo -e "${GREEN}✓${NC} Created CLAUDE.md template"
fi

# ============================================================================
# INITIALIZE BEADS
# ============================================================================

echo ""
echo -e "${YELLOW}Setting up Beads...${NC}"

cd "$TARGET"

# Initialize Beads if not already
if [ ! -d ".beads" ]; then
    echo -e "Initializing Beads..."
    bd init --quiet
    echo -e "${GREEN}✓${NC} Beads initialized"
fi

# Install git hooks for auto-sync
echo -e "Installing Beads git hooks..."
bd hooks install 2>/dev/null || true
echo -e "${GREEN}✓${NC} Git hooks installed"

# Run doctor to verify setup
echo -e "Running Beads health check..."
DOCTOR_OUTPUT=$(bd doctor 2>&1 || true)
if echo "$DOCTOR_OUTPUT" | grep -q "error\|Error\|ERROR"; then
    echo -e "${YELLOW}⚠${NC} Some issues detected:"
    echo "$DOCTOR_OUTPUT" | grep -i "error" | head -5
    echo "  Run 'bd doctor' for details"
else
    echo -e "${GREEN}✓${NC} Beads health check passed"
fi

# ============================================================================
# DONE
# ============================================================================

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ Installation Complete!                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Installed to: ${BLUE}$TARGET/.claude/${NC}"

if [ -d "$BACKUP_DIR" ]; then
    echo -e "Backup at:    ${BLUE}$BACKUP_DIR${NC}"
fi

echo ""
echo -e "${CYAN}What's New in v2:${NC}"
echo "  ✓ Beads is now REQUIRED (not optional)"
echo "  ✓ Uses bd prime for context injection"
echo "  ✓ Git hooks auto-sync Beads state"
echo "  ✓ Labels for domain/QA tracking"
echo "  ✓ Hierarchical issues (epics) for features"
echo "  ✓ Structured notes (survive compaction)"
echo "  ✓ bd blocked visibility in context"
echo "  ✓ bd doctor health checks"
echo ""
echo -e "${YELLOW}Usage:${NC}"
echo "  cd $TARGET"
echo "  claude"
echo ""
echo "  Then describe what you want:"
echo "  > Add user authentication"
echo "  > Fix the login bug"
echo ""
echo -e "${YELLOW}Beads Commands:${NC}"
echo "  bd ready          # Tasks available to work on"
echo "  bd blocked        # Tasks waiting on dependencies"
echo "  bd list           # All tasks"
echo "  bd doctor         # Health check"
echo ""
echo -e "${RED}Remember: All code changes require @qa approval!${NC}"
echo ""

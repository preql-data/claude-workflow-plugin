# Ultimate Workflow Plugin v2 - Windows Installer (PowerShell)
# 
# This plugin REQUIRES Beads (bd) for task tracking.
# Install Beads first: irm https://raw.githubusercontent.com/steveyegge/beads/main/install.ps1 | iex
#
# Usage: 
#   .\install-ultimate-workflow.ps1
#   .\install-ultimate-workflow.ps1 -Path "C:\Projects\myproject"

param(
    [string]$Path = "."
)

$ErrorActionPreference = "Stop"

# Colors
function Write-Color {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

# Resolve target path
$Target = Resolve-Path $Path -ErrorAction SilentlyContinue
if (-not $Target) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $Target = Resolve-Path $Path
}
$Target = $Target.Path

Write-Host ""
Write-Color "╔════════════════════════════════════════════════════════════╗" Cyan
Write-Color "║     Ultimate Workflow Plugin v2 - Windows Installer        ║" Cyan
Write-Color "║   Full Beads Integration with Mandatory QA Gate            ║" Cyan
Write-Color "╚════════════════════════════════════════════════════════════╝" Cyan
Write-Host ""
Write-Host "Installing to: " -NoNewline
Write-Color $Target Green
Write-Host ""

# ============================================================================
# PREREQUISITES - BEADS IS REQUIRED
# ============================================================================

Write-Color "Checking prerequisites..." Yellow

# Check for Git
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Color "✓ git installed" Green
} else {
    Write-Color "✗ git not found - REQUIRED" Red
    Write-Host "  Install from: https://git-scm.com/download/win"
    exit 1
}

# Check for jq (optional but recommended)
$HasJq = $false
if (Get-Command jq -ErrorAction SilentlyContinue) {
    Write-Color "✓ jq installed" Green
    $HasJq = $true
} else {
    Write-Color "⚠ jq not found - some features limited" Yellow
    Write-Host "  Install: winget install jqlang.jq"
}

# Check for Beads (REQUIRED)
if (-not (Get-Command bd -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Color "╔════════════════════════════════════════════════════════════╗" Red
    Write-Color "║  ✗ BEADS (bd) NOT FOUND - REQUIRED FOR THIS PLUGIN         ║" Red
    Write-Color "╚════════════════════════════════════════════════════════════╝" Red
    Write-Host ""
    Write-Host "This workflow plugin requires Beads for:"
    Write-Host "  • Task tracking and dependency management"
    Write-Host "  • Persistent memory across sessions"
    Write-Host "  • QA approval tracking"
    Write-Host "  • Hierarchical issue organization"
    Write-Host ""
    Write-Color "Install Beads:" Cyan
    Write-Host ""
    Write-Host "  # PowerShell (Windows)"
    Write-Host "  irm https://raw.githubusercontent.com/steveyegge/beads/main/install.ps1 | iex"
    Write-Host ""
    Write-Host "  # npm"
    Write-Host "  npm install -g @beads/bd"
    Write-Host ""
    Write-Host "  # Go"
    Write-Host "  go install github.com/steveyegge/beads/cmd/bd@latest"
    Write-Host ""
    Write-Host "After installing, run this installer again."
    exit 1
}

$BdVersion = (bd --version 2>$null | Select-Object -First 1) -replace '\s+', ' '
Write-Color "✓ Beads installed ($BdVersion)" Green

Write-Host ""

# ============================================================================
# GIT REPOSITORY CHECK
# ============================================================================

$GitDir = Join-Path $Target ".git"
if (-not (Test-Path $GitDir)) {
    Write-Color "No git repository found." Yellow
    $InitGit = Read-Host "Initialize git repository? (required for Beads) (y/n)"
    if ($InitGit -eq "y") {
        Push-Location $Target
        git init
        
        # Create .gitignore
        $GitignoreFile = Join-Path $Target ".gitignore"
        if (-not (Test-Path $GitignoreFile)) {
            @"
node_modules/
.venv/
__pycache__/
dist/
build/
.env
.env.local
*.log
.idea/
.vscode/
.DS_Store
.claude/.session-start
.claude/.qa-tracking/
"@ | Out-File -FilePath $GitignoreFile -Encoding UTF8
        }
        
        git add .gitignore 2>$null
        git commit -m "Initial commit" --allow-empty 2>$null
        Pop-Location
        Write-Color "✓ Initialized git repository" Green
    } else {
        Write-Color "Cannot proceed without git repository." Red
        exit 1
    }
}

# ============================================================================
# BACKUP EXISTING FILES
# ============================================================================

$ClaudeDir = Join-Path $Target ".claude"
$MergeMode = $false
$UpdateMode = $false

if (Test-Path $ClaudeDir) {
    Write-Color "Existing .claude/ directory found!" Yellow
    
    $ExistingAgents = (Get-ChildItem "$ClaudeDir\agents\*.md" -ErrorAction SilentlyContinue | Measure-Object).Count
    $ExistingScripts = (Get-ChildItem "$ClaudeDir\scripts\*.sh" -ErrorAction SilentlyContinue | Measure-Object).Count
    
    if ($ExistingAgents -gt 0 -or $ExistingScripts -gt 0) {
        Write-Host "  Found: $ExistingAgents agents, $ExistingScripts scripts"
        Write-Host ""
        Write-Color "Options:" Yellow
        Write-Host "  1) Backup and install fresh"
        Write-Host "  2) Update workflow (keeps CLAUDE.md)"
        Write-Host "  3) Merge only (skip existing files)"
        Write-Host "  4) Cancel"
        Write-Host ""
        
        $Choice = Read-Host "Choose [1-4]"
        
        $BackupDir = "$ClaudeDir-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        switch ($Choice) {
            "1" {
                Write-Color "Creating backup..." Yellow
                Copy-Item -Path $ClaudeDir -Destination $BackupDir -Recurse
                Write-Color "✓ Backup created at $BackupDir" Green
            }
            "2" {
                Copy-Item -Path $ClaudeDir -Destination $BackupDir -Recurse
                Write-Color "✓ Backup created" Green
                $UpdateMode = $true
            }
            "3" {
                $MergeMode = $true
                Write-Color "Merge mode: will skip existing files" Yellow
            }
            default {
                Write-Host "Cancelled."
                exit 0
            }
        }
    }
}

Write-Host ""
Write-Color "Creating plugin structure..." Yellow

# Create directories
$Dirs = @(
    "$ClaudeDir\agents",
    "$ClaudeDir\skills\workflow-engine",
    "$ClaudeDir\hooks",
    "$ClaudeDir\scripts"
)
foreach ($Dir in $Dirs) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
}

# Helper function
function Create-FileIfNotMerge {
    param([string]$FilePath, [string]$Content)
    
    if ($MergeMode -and (Test-Path $FilePath)) {
        Write-Color "⊘ Skipped $(Split-Path $FilePath -Leaf) (exists)" Yellow
        return $false
    }
    
    $Content | Out-File -FilePath $FilePath -Encoding UTF8 -NoNewline
    Write-Color "✓ Created $(Split-Path $FilePath -Leaf)" Green
    return $true
}

# ============================================================================
# AGENTS
# ============================================================================

$OrchestratorContent = @'
---
name: orchestrator
description: Primary workflow orchestrator using Beads task tracking with mandatory QA gate.
tools: Read, Glob, Grep, LS, Task, Bash, Write, Edit
---

You are the **Workflow Orchestrator** using Beads (bd) for persistent task tracking.

## Beads Commands

```bash
bd ready                    # Tasks with no blockers
bd blocked                  # Tasks waiting on dependencies
bd create "Title" -t epic -p 1 --description "..."
bd update $ID --status in_progress
bd update $ID --notes "COMPLETED: X | IN PROGRESS: Y"
bd label add $ID backend,qa-pending
bd comments add $ID "QA APPROVED: summary"
```

## 🚫 MANDATORY QA GATE

Every code change MUST be reviewed by @qa before delivery.
System BLOCKS completion until QA approves.

## Structured Notes Format

```
COMPLETED: [Deliverables]
IN PROGRESS: [Current work]
BLOCKED: [What's preventing progress]
KEY DECISIONS: [Important choices]
```
'@

Create-FileIfNotMerge -FilePath "$ClaudeDir\agents\orchestrator.md" -Content $OrchestratorContent

$BackendContent = @'
---
name: backend
description: Backend specialist using Beads for tracking.
tools: Read, Glob, Grep, LS, Bash, Write, Edit
---

You are a **Backend Engineering Specialist** using Beads.

## When Starting: `bd update $ID --status in_progress`
## When Done: `bd update $ID --notes "COMPLETED: X" && bd label add $ID qa-pending`

## Self-Check Questions
1. Bottlenecks?
2. Scale limits?
3. Failure points?
4. Mitigations?
'@

Create-FileIfNotMerge -FilePath "$ClaudeDir\agents\backend.md" -Content $BackendContent

$FrontendContent = @'
---
name: frontend
description: Frontend specialist using Beads for tracking.
tools: Read, Glob, Grep, LS, Bash, Write, Edit
---

You are a **Frontend Engineering Specialist** using Beads.

## When Starting: `bd update $ID --status in_progress`
## When Done: `bd update $ID --notes "COMPLETED: X" && bd label add $ID qa-pending`

## Self-Check Questions
1. Using all backend features?
2. UI/UX clear?
3. Can be more convenient?
4. Beautiful?
'@

Create-FileIfNotMerge -FilePath "$ClaudeDir\agents\frontend.md" -Content $FrontendContent

$DevopsContent = @'
---
name: devops
description: DevOps specialist using Beads for tracking.
tools: Read, Glob, Grep, LS, Bash, Write, Edit
---

You are a **DevOps Engineering Specialist** using Beads.

## When Starting: `bd update $ID --status in_progress`
## When Done: `bd update $ID --notes "COMPLETED: X" && bd label add $ID qa-pending`
'@

Create-FileIfNotMerge -FilePath "$ClaudeDir\agents\devops.md" -Content $DevopsContent

$QaContent = @'
---
name: qa
description: QA specialist and mandatory quality gate.
tools: Read, Glob, Grep, LS, Bash, Write, Edit
---

You are the **Quality Assurance Specialist** - the mandatory gate.

## 🚨 No code ships without your approval

## Test USER BEHAVIOR, Not Code

WRONG: test("formatDate returns ISO string")
RIGHT: test("user sees appointment in their timezone")

## Approval Process

```bash
# When approved:
bd comments add $ID "QA APPROVED: [summary]"
bd label remove $ID qa-pending
bd label add $ID qa-approved

# When blocked:
bd comments add $ID "QA BLOCKED: [issues]"
```
'@

Create-FileIfNotMerge -FilePath "$ClaudeDir\agents\qa.md" -Content $QaContent

# ============================================================================
# HOOKS
# ============================================================================

$HooksContent = @'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-start.sh\"", "timeout": 30000}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/intent-router.sh\""}]}],
    "PostToolUse": [{"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/post-edit.sh\""}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/verify-before-stop.sh\""}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-end.sh\""}]}]
  }
}
'@

Create-FileIfNotMerge -FilePath "$ClaudeDir\hooks\hooks.json" -Content $HooksContent

# ============================================================================
# SCRIPTS (require Git Bash)
# ============================================================================

Write-Host ""
Write-Color "Note: Scripts require Git Bash to run." Yellow

$SessionStartContent = @'
#!/bin/bash
set -e
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if ! command -v bd &> /dev/null; then
    echo '{"error": "Beads (bd) not found"}'
    exit 1
fi

if [ ! -d "$PROJECT_DIR/.beads" ]; then
    echo '{"error": "Beads not initialized. Run: bd init"}'
    exit 1
fi

mkdir -p "$PROJECT_DIR/.claude/.qa-tracking"
touch "$PROJECT_DIR/.claude/.session-start"
rm -f "$PROJECT_DIR/.claude/.qa-tracking/approved" 2>/dev/null || true
rm -f "$PROJECT_DIR/.claude/.qa-tracking/changed-files.txt" 2>/dev/null || true

CONTEXT=""

BD_PRIME=$(bd prime 2>/dev/null || echo "")
[ -n "$BD_PRIME" ] && CONTEXT+="<beads_context>
$BD_PRIME
</beads_context>
"

[ -f "$PROJECT_DIR/CLAUDE.md" ] && CONTEXT+="<project_memory>
$(cat "$PROJECT_DIR/CLAUDE.md")
</project_memory>
"

BLOCKED=$(bd blocked 2>/dev/null | head -10)
[ -n "$BLOCKED" ] && CONTEXT+="<blocked_issues>
$BLOCKED
</blocked_issues>
"

CONTEXT+="<workflow_mode>
## ULTIMATE WORKFLOW v2

Orchestrator using Beads. MANDATORY QA GATE enforced.

### Commands
bd ready / bd blocked / bd list
bd create \"Title\" -t epic -p 1 --parent \$EPIC -l backend,qa-pending
bd update \$ID --notes \"COMPLETED: X | IN PROGRESS: Y\"
bd comments add \$ID \"QA APPROVED: summary\"

### Flow: Create → Delegate → @qa reviews → QA approves → Done
</workflow_mode>"

cat << EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$(echo "$CONTEXT" | jq -Rs .)}}
EOF
'@

$SessionStartContent | Out-File -FilePath "$ClaudeDir\scripts\session-start.sh" -Encoding UTF8 -NoNewline
Write-Color "✓ Created session-start.sh" Green

$IntentRouterContent = @'
#!/bin/bash
set -e

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "$INPUT")
PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

if echo "$PROMPT_LOWER" | grep -qE '^(hi|hello|hey|ok|sure|thanks)'; then
    echo "{}"; exit 0
fi

WORK_TYPE="general"
echo "$PROMPT_LOWER" | grep -qE '(bug|error|fix|broken)' && WORK_TYPE="bug"
echo "$PROMPT_LOWER" | grep -qE '(add|create|build|feature)' && WORK_TYPE="feature"
echo "$PROMPT_LOWER" | grep -qE '(improve|optimize|refactor)' && WORK_TYPE="improvement"

WORKFLOW_CONTEXT="<auto_workflow type=\"$WORK_TYPE\">
## $WORK_TYPE detected

Use Beads: bd create \"...\" -t $WORK_TYPE -l qa-pending
All changes require @qa approval.
</auto_workflow>"

cat << EOF
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":$(echo "$WORKFLOW_CONTEXT" | jq -Rs .)}}
EOF
'@

$IntentRouterContent | Out-File -FilePath "$ClaudeDir\scripts\intent-router.sh" -Encoding UTF8 -NoNewline
Write-Color "✓ Created intent-router.sh" Green

$PostEditContent = @'
#!/bin/bash
set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_DIR="$PROJECT_DIR/.claude/.qa-tracking"
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

[[ ! "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|go|rs|java|vue|svelte|css)$ ]] && { echo "{}"; exit 0; }

mkdir -p "$QA_DIR"
TRACKING="$QA_DIR/changed-files.txt"
grep -qxF "$FILE_PATH" "$TRACKING" 2>/dev/null || echo "$FILE_PATH" >> "$TRACKING"

COUNT=$(sort -u "$TRACKING" 2>/dev/null | wc -l | tr -d ' ')
echo "📝 $COUNT files changed. All require @qa approval."
'@

$PostEditContent | Out-File -FilePath "$ClaudeDir\scripts\post-edit.sh" -Encoding UTF8 -NoNewline
Write-Color "✓ Created post-edit.sh" Green

$VerifyContent = @'
#!/bin/bash
set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_DIR="$PROJECT_DIR/.claude/.qa-tracking"
TRACKING="$QA_DIR/changed-files.txt"

INPUT=$(cat)
STOP_REASON=$(echo "$INPUT" | jq -r '.stop_reason // empty' 2>/dev/null)

[[ "$STOP_REASON" == "user_interrupt" ]] && { echo "{}"; exit 0; }
[[ ! -f "$TRACKING" ]] || [[ ! -s "$TRACKING" ]] && { echo "{}"; exit 0; }

QA_APPROVED=false
[ -f "$QA_DIR/approved" ] && QA_APPROVED=true

if command -v bd &> /dev/null && [ -d "$PROJECT_DIR/.beads" ]; then
    TASK=$(bd list --status in_progress --json 2>/dev/null | jq -r '.[0].id // empty')
    if [ -n "$TASK" ]; then
        LABELS=$(bd show "$TASK" --json 2>/dev/null | jq -r '.labels // [] | join(",")' 2>/dev/null)
        echo "$LABELS" | grep -qi "qa-approved" && QA_APPROVED=true
        
        if [ "$QA_APPROVED" = false ]; then
            COMMENT=$(bd show "$TASK" --json 2>/dev/null | jq -r '.comments[]? | select(test("QA APPROVED";"i"))' 2>/dev/null | head -1)
            [ -n "$COMMENT" ] && QA_APPROVED=true
        fi
    fi
fi

if [ "$QA_APPROVED" = false ]; then
    FILES=$(sort -u "$TRACKING" 2>/dev/null | head -10)
    COUNT=$(sort -u "$TRACKING" 2>/dev/null | wc -l | tr -d ' ')
    cat << EOF
{"decision":"block","reason":"🚫 QA APPROVAL REQUIRED

$COUNT files changed - require @qa review.

Files: $FILES

Delegate to @qa, then:
  bd comments add \$ID 'QA APPROVED: summary'
  bd label add \$ID qa-approved"}
EOF
    exit 0
fi

rm -f "$QA_DIR/approved" "$TRACKING" 2>/dev/null
echo "{}"
'@

$VerifyContent | Out-File -FilePath "$ClaudeDir\scripts\verify-before-stop.sh" -Encoding UTF8 -NoNewline
Write-Color "✓ Created verify-before-stop.sh" Green

$SessionEndContent = @'
#!/bin/bash
set -e
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
command -v bd &> /dev/null && [ -d "$PROJECT_DIR/.beads" ] && bd sync 2>/dev/null || true
echo "{}"
'@

$SessionEndContent | Out-File -FilePath "$ClaudeDir\scripts\session-end.sh" -Encoding UTF8 -NoNewline
Write-Color "✓ Created session-end.sh" Green

# ============================================================================
# SKILL
# ============================================================================

$SkillContent = @'
# Ultimate Workflow Engine v2

> Full Beads integration with mandatory QA gate.

## Requirements
- Beads (bd) - REQUIRED
- Git repository
- Git Bash (for scripts on Windows)

## Labels
- `qa-pending` - Awaiting QA review
- `qa-approved` - QA signed off
- `backend`, `frontend`, `devops` - Domain tracking

## Workflow
1. Create task with `qa-pending` label
2. Delegate to domain specialists
3. @qa reviews and approves
4. Task can close
'@

Create-FileIfNotMerge -FilePath "$ClaudeDir\skills\workflow-engine\SKILL.md" -Content $SkillContent

# ============================================================================
# SETTINGS
# ============================================================================

$SettingsFile = "$ClaudeDir\settings.json"

$SettingsContent = @'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-start.sh\"", "timeout": 30000}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/intent-router.sh\""}]}],
    "PostToolUse": [{"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/post-edit.sh\""}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/verify-before-stop.sh\""}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-end.sh\""}]}]
  },
  "permissions": {"allow": ["Read", "Glob", "Grep", "LS"], "deny": ["Bash(rm -rf *)", "Bash(sudo *)"]}
}
'@

if (Test-Path $SettingsFile) {
    Write-Color "⚠ Existing settings.json - merge hooks manually" Yellow
} else {
    $SettingsContent | Out-File -FilePath $SettingsFile -Encoding UTF8 -NoNewline
    Write-Color "✓ Created settings.json" Green
}

# ============================================================================
# CLAUDE.md
# ============================================================================

$ClaudeMdFile = Join-Path $Target "CLAUDE.md"
if (-not (Test-Path $ClaudeMdFile)) {
    $ClaudeMdContent = @'
# Project Memory

## Overview
<!-- Describe your project -->

## Users & Personas
### Primary User: [Name]
- **Who**: [Description]
- **Goal**: [What they want]

## Critical User Journeys
### Journey 1: [Name]
**Steps**: 1. User... 2. User sees...
**Failure modes**: Invalid input, network error

## Labels Convention
- `qa-pending` - Awaiting QA
- `qa-approved` - QA signed off
- `backend`, `frontend`, `devops` - Domain
'@

    $ClaudeMdContent | Out-File -FilePath $ClaudeMdFile -Encoding UTF8 -NoNewline
    Write-Color "✓ Created CLAUDE.md" Green
}

# ============================================================================
# INITIALIZE BEADS
# ============================================================================

Write-Host ""
Write-Color "Setting up Beads..." Yellow

Push-Location $Target

# Initialize Beads
$BeadsDir = Join-Path $Target ".beads"
if (-not (Test-Path $BeadsDir)) {
    Write-Host "Initializing Beads..."
    bd init --quiet 2>$null
    Write-Color "✓ Beads initialized" Green
}

# Install hooks
Write-Host "Installing Beads git hooks..."
bd hooks install 2>$null
Write-Color "✓ Git hooks installed" Green

# Health check
Write-Host "Running Beads health check..."
$DoctorOutput = bd doctor 2>&1
if ($DoctorOutput -match "error|Error") {
    Write-Color "⚠ Some issues detected - run 'bd doctor' for details" Yellow
} else {
    Write-Color "✓ Beads health check passed" Green
}

Pop-Location

# ============================================================================
# DONE
# ============================================================================

Write-Host ""
Write-Color "╔════════════════════════════════════════════════════════════╗" Green
Write-Color "║              ✅ Installation Complete!                      ║" Green
Write-Color "╚════════════════════════════════════════════════════════════╝" Green
Write-Host ""
Write-Host "Installed to: " -NoNewline
Write-Color $Target Cyan
Write-Host ""
Write-Color "What's New in v2:" Cyan
Write-Host "  ✓ Beads is REQUIRED"
Write-Host "  ✓ Uses bd prime for context"
Write-Host "  ✓ Git hooks auto-sync"
Write-Host "  ✓ Labels for QA tracking"
Write-Host "  ✓ Hierarchical issues"
Write-Host ""
Write-Color "Requirements:" Yellow
Write-Host "  - Git Bash (comes with Git for Windows)"
Write-Host ""
Write-Color "Usage:" Yellow
Write-Host "  cd $Target"
Write-Host "  claude"
Write-Host ""
Write-Color "Beads Commands:" Yellow
Write-Host "  bd ready    - Available work"
Write-Host "  bd blocked  - Blocked issues"
Write-Host "  bd doctor   - Health check"
Write-Host ""
Write-Color "Remember: All code changes require @qa approval!" Red
Write-Host ""

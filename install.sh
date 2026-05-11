#!/bin/bash
# Claude Workflow Plugin v3 - Linux/macOS installer
#
# Single-source-of-truth: this script copies the canonical agent/script/hook
# definitions from the repo (alongside this file, or freshly cloned to a temp
# dir if piped from curl). It does NOT embed the agent prompts as heredocs.
#
# This plugin REQUIRES Beads (bd) for task tracking.
# Install Beads first:
#   curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
#
# Usage:
#   bash install.sh [project-path]            # from a local clone
#   curl -fsSL <url>/install.sh | bash        # via curl (auto-clones)
#   curl -fsSL <url>/install.sh | bash -s -- /path/to/project

set -e

# Colors -----------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Tunables --------------------------------------------------------------------
MIN_BD_VERSION="0.47"
REPO_URL="${CLAUDE_WORKFLOW_REPO:-https://github.com/preql-data/claude-workflow-plugin.git}"
REPO_BRANCH="${CLAUDE_WORKFLOW_BRANCH:-main}"

# Resolve target ---------------------------------------------------------------
TARGET="${1:-.}"
mkdir -p "$TARGET"
TARGET=$(cd "$TARGET" && pwd)

echo ""
echo -e "${BLUE}Claude Workflow Plugin v3${NC}"
echo -e "Orchestrator-first workflow with mandatory QA gate"
echo ""
echo -e "Installing to: ${GREEN}$TARGET${NC}"
echo ""

# Prerequisites ----------------------------------------------------------------
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v git &> /dev/null; then
    echo -e "${RED}git not found - REQUIRED${NC}"
    echo "  Install from: https://git-scm.com/downloads"
    exit 1
fi
echo -e "${GREEN}OK${NC} git installed"

if ! command -v jq &> /dev/null; then
    echo -e "${RED}jq not found - REQUIRED${NC}"
    echo "  Install with: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
fi
echo -e "${GREEN}OK${NC} jq installed"

if ! command -v bd &> /dev/null; then
    echo ""
    echo -e "${RED}Beads (bd) not found - REQUIRED for this plugin${NC}"
    echo ""
    echo -e "Install Beads:"
    echo "  # macOS / Linux"
    echo "  curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash"
    echo ""
    echo "  # Homebrew"
    echo "  brew tap steveyegge/beads && brew install beads"
    echo ""
    echo "After installing, run this installer again."
    exit 1
fi

BD_VERSION_RAW=$(bd --version 2>/dev/null | head -1 || echo "unknown")
BD_VERSION_NUM=$(echo "$BD_VERSION_RAW" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
echo -e "${GREEN}OK${NC} Beads installed ($BD_VERSION_RAW)"

# D6: enforce minimum bd version at install time
if [ -n "$BD_VERSION_NUM" ]; then
    SORTED=$(printf '%s\n%s\n' "$BD_VERSION_NUM" "$MIN_BD_VERSION" | sort -V | head -1)
    if [ "$SORTED" = "$BD_VERSION_NUM" ] && [ "$BD_VERSION_NUM" != "$MIN_BD_VERSION" ]; then
        echo ""
        echo -e "${RED}Beads version $BD_VERSION_NUM is older than the required minimum $MIN_BD_VERSION.${NC}"
        echo "Upgrade Beads, then rerun this installer:"
        echo "  curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash"
        exit 1
    fi
fi

echo ""

# Locate source-of-truth files -------------------------------------------------
# If this script lives inside a clone of the plugin repo, use that. Otherwise
# clone the repo into a temp directory.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo "")
fi

SOURCE_DIR=""
TMP_CLONE=""
cleanup_clone() {
    if [ -n "$TMP_CLONE" ] && [ -d "$TMP_CLONE" ]; then
        rm -rf "$TMP_CLONE"
    fi
}
trap cleanup_clone EXIT

if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/.claude/agents" ] && [ -f "$SCRIPT_DIR/.claude-plugin/plugin.json" ]; then
    SOURCE_DIR="$SCRIPT_DIR"
    echo -e "${GREEN}OK${NC} Using local plugin source: $SOURCE_DIR"
else
    echo -e "${YELLOW}Fetching plugin source from $REPO_URL ($REPO_BRANCH)...${NC}"
    TMP_CLONE=$(mktemp -d)
    if ! git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMP_CLONE" 2>/dev/null; then
        # Some hosts default to a different branch name; retry without --branch
        rm -rf "$TMP_CLONE"
        TMP_CLONE=$(mktemp -d)
        git clone --depth 1 "$REPO_URL" "$TMP_CLONE"
    fi
    SOURCE_DIR="$TMP_CLONE"
    echo -e "${GREEN}OK${NC} Plugin source ready"
fi

# Sanity-check the source layout
for required in \
    ".claude/agents/orchestrator.md" \
    ".claude/agents/qa.md" \
    ".claude/agents/backend.md" \
    ".claude/agents/frontend.md" \
    ".claude/agents/devops.md" \
    ".claude/scripts/session-start.sh" \
    ".claude/scripts/intent-router.sh" \
    ".claude/scripts/post-edit.sh" \
    ".claude/scripts/verify-before-stop.sh" \
    ".claude/scripts/session-end.sh" \
    ".claude/hooks/hooks.json" \
    ".claude/skills/workflow-engine/SKILL.md" \
    ".claude/settings.json" \
    ".claude-plugin/plugin.json" \
    ".claude/commands/workflow-model.md" \
    ; do
    if [ ! -e "$SOURCE_DIR/$required" ]; then
        echo -e "${RED}Plugin source missing: $required${NC}"
        echo "(Looked in $SOURCE_DIR.) Aborting to avoid a partial install."
        exit 1
    fi
done

# Git repo init ----------------------------------------------------------------
if [ ! -d "$TARGET/.git" ]; then
    echo -e "${YELLOW}No git repository found.${NC}"
    read -p "Initialize git repository? (required for Beads) (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$TARGET"
        git init

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
        echo -e "${GREEN}OK${NC} Initialized git repository"
    else
        echo -e "${RED}Cannot proceed without git repository.${NC}"
        exit 1
    fi
fi

# Mode selection (interactive) -------------------------------------------------
BACKUP_DIR="$TARGET/.claude-backup-$(date +%Y%m%d-%H%M%S)"
MERGE_MODE=false
UPDATE_MODE=false

if [ -d "$TARGET/.claude" ]; then
    echo -e "${YELLOW}Existing .claude/ directory found.${NC}"

    EXISTING_AGENTS=$(find "$TARGET/.claude/agents" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    EXISTING_SCRIPTS=$(find "$TARGET/.claude/scripts" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")
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
                echo -e "${GREEN}OK${NC} Backup created"
                ;;
            2)
                echo -e "${YELLOW}Update mode: updating workflow, preserving CLAUDE.md${NC}"
                mkdir -p "$BACKUP_DIR"
                cp -r "$TARGET/.claude/"* "$BACKUP_DIR/" 2>/dev/null || true
                echo -e "${GREEN}OK${NC} Backup created"
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

mkdir -p "$TARGET/.claude/agents"
mkdir -p "$TARGET/.claude/skills/workflow-engine"
mkdir -p "$TARGET/.claude/hooks"
mkdir -p "$TARGET/.claude/scripts"
mkdir -p "$TARGET/.claude/commands"
mkdir -p "$TARGET/.claude-plugin"

# Idempotent file copy with merge-mode awareness ------------------------------
copy_file() {
    local src="$1"
    local dst="$2"
    if [ "$MERGE_MODE" = true ] && [ -f "$dst" ]; then
        echo -e "${YELLOW}skip${NC} $(basename "$dst") (exists)"
        return 0
    fi
    cp "$src" "$dst"
    echo -e "${GREEN}OK${NC}   $(basename "$dst")"
}

# Agents -----------------------------------------------------------------------
for agent in orchestrator qa backend frontend devops; do
    copy_file "$SOURCE_DIR/.claude/agents/${agent}.md" "$TARGET/.claude/agents/${agent}.md"
done

# Scripts ----------------------------------------------------------------------
for script in session-start.sh intent-router.sh post-edit.sh verify-before-stop.sh session-end.sh; do
    copy_file "$SOURCE_DIR/.claude/scripts/${script}" "$TARGET/.claude/scripts/${script}"
done
chmod +x "$TARGET/.claude/scripts/"*.sh 2>/dev/null || true

# Hooks ------------------------------------------------------------------------
copy_file "$SOURCE_DIR/.claude/hooks/hooks.json" "$TARGET/.claude/hooks/hooks.json"

# Skill ------------------------------------------------------------------------
copy_file "$SOURCE_DIR/.claude/skills/workflow-engine/SKILL.md" \
    "$TARGET/.claude/skills/workflow-engine/SKILL.md"

# Commands ---------------------------------------------------------------------
for cmd in "$SOURCE_DIR/.claude/commands/"*.md; do
    [ -f "$cmd" ] || continue
    copy_file "$cmd" "$TARGET/.claude/commands/$(basename "$cmd")"
done

# Plugin manifest --------------------------------------------------------------
copy_file "$SOURCE_DIR/.claude-plugin/plugin.json" "$TARGET/.claude-plugin/plugin.json"

# Settings.json (with merge support) ------------------------------------------
SETTINGS_FILE="$TARGET/.claude/settings.json"
SOURCE_SETTINGS="$SOURCE_DIR/.claude/settings.json"

if [ -f "$SETTINGS_FILE" ]; then
    if [ "$UPDATE_MODE" = true ]; then
        echo -e "${YELLOW}Merging settings.json (preserving non-workflow keys)...${NC}"
        cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak"
        # Replace workflow-owned keys (hooks, env, additionalDirectories) but keep others.
        MERGED=$(jq -s '
            .[0] as $existing |
            .[1] as $new |
            $existing
            | .hooks = $new.hooks
            | .env = (($existing.env // {}) + ($new.env // {}))
            | .additionalDirectories = ($new.additionalDirectories // $existing.additionalDirectories)
            | (if $existing.permissions then . else .permissions = $new.permissions end)
        ' "$SETTINGS_FILE" "$SOURCE_SETTINGS" 2>/dev/null) || MERGED=""
        if [ -n "$MERGED" ]; then
            echo "$MERGED" > "$SETTINGS_FILE"
            echo -e "${GREEN}OK${NC}   settings.json merged"
        else
            echo -e "${RED}Could not merge settings.json - manual review needed${NC}"
        fi
    elif [ "$MERGE_MODE" = true ]; then
        echo -e "${YELLOW}skip${NC} settings.json (exists, merge mode)"
    else
        # Mode 1 (backup-and-install-fresh) overwrites
        cp "$SOURCE_SETTINGS" "$SETTINGS_FILE"
        echo -e "${GREEN}OK${NC}   settings.json"
    fi
else
    cp "$SOURCE_SETTINGS" "$SETTINGS_FILE"
    echo -e "${GREEN}OK${NC}   settings.json"
fi

# CLAUDE.md template (only if missing) ----------------------------------------
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

## Current Focus
<!-- What are we working on? -->

## Beads Labels Convention
- `backend`, `frontend`, `devops` - Domain tracking
- `qa-pending` - Awaiting QA review
- `qa-approved` - QA has signed off
- `bug`, `improvement` - Work type
CLAUDE_EOF
    echo -e "${GREEN}OK${NC}   CLAUDE.md template"
fi

# Beads init / hooks / doctor --------------------------------------------------
echo ""
echo -e "${YELLOW}Setting up Beads...${NC}"

cd "$TARGET"

if [ ! -d ".beads" ]; then
    echo "Initializing Beads..."
    bd init --quiet
    echo -e "${GREEN}OK${NC} Beads initialized"
fi

echo "Installing Beads git hooks..."
bd hooks install 2>/dev/null || true
echo -e "${GREEN}OK${NC} Git hooks installed"

echo "Running Beads health check..."
DOCTOR_OUTPUT=$(bd doctor 2>&1 || true)
if echo "$DOCTOR_OUTPUT" | grep -qiE 'error'; then
    echo -e "${YELLOW}Some issues detected:${NC}"
    echo "$DOCTOR_OUTPUT" | grep -i error | head -5
    echo "  Run 'bd doctor' for details."
else
    echo -e "${GREEN}OK${NC} Beads health check passed"
fi

# Done -------------------------------------------------------------------------
echo ""
echo -e "${GREEN}Installation complete.${NC}"
echo ""
echo -e "Installed to: ${BLUE}$TARGET/.claude/${NC}"
echo -e "Manifest:     ${BLUE}$TARGET/.claude-plugin/plugin.json${NC}"

if [ -d "$BACKUP_DIR" ]; then
    echo -e "Backup at:    ${BLUE}$BACKUP_DIR${NC}"
fi

echo ""
echo -e "${CYAN}What's new in v3:${NC}"
echo "  - Plugin manifest (.claude-plugin/plugin.json) with v3.0.0"
echo "  - Model pinning per agent + /workflow-model upgrade command"
echo "  - MAX_THINKING_TOKENS at 64000 + extended-thinking instruction in every agent"
echo "  - Parent-folder access via additionalDirectories (../)"
echo "  - SessionStart warns on stale model + old bd"
echo "  - Single-source-of-truth installer (no heredoc duplication)"
echo "  - uninstall.sh for clean removal"
echo ""
echo -e "${YELLOW}Usage:${NC}"
echo "  cd $TARGET"
echo "  claude"
echo ""
echo "  Then describe what you want:"
echo "  > Add user authentication"
echo "  > Fix the login bug"
echo ""
echo -e "${YELLOW}Beads commands:${NC}"
echo "  bd ready          # Tasks available to work on"
echo "  bd blocked        # Tasks waiting on dependencies"
echo "  bd list           # All tasks"
echo "  bd doctor         # Health check"
echo ""
echo "Remember: all code changes require @qa approval."
echo ""

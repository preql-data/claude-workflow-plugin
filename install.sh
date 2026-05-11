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
#   bash install.sh [project-path]                   # from a local clone
#   bash install.sh --upgrade [project-path]         # force v2->v3 upgrade flow
#   bash install.sh --help                           # print usage
#   curl -fsSL <url>/install.sh | bash               # via curl (auto-clones)
#   curl -fsSL <url>/install.sh | bash -s -- /path   # specify target path
#   curl -fsSL <url>/install.sh | bash -s -- --upgrade

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

# Argument parsing ------------------------------------------------------------
# Supports:
#   --upgrade   force the v2->v3 upgrade flow even if auto-detection is fuzzy
#   --help/-h   print usage and exit 0
# Anything else is treated as the target project path (back-compat with v2
# install.sh's positional [project-path] form).
FORCE_UPGRADE=false
TARGET=""

print_usage() {
    cat <<'USAGE'
Claude Workflow Plugin v3 installer

Usage:
  bash install.sh [project-path]                Install (auto-detects v2)
  bash install.sh --upgrade [project-path]      Force the v2->v3 upgrade flow
  bash install.sh --help                        Print this message

Flags:
  --upgrade    Run the v2->v3 migration even if auto-detection is fuzzy.
               Backs up .claude/ to .claude-v2-backup-<timestamp>/ before
               writing v3 files.
  -h, --help   Print this message and exit 0.

Curl-pipe forms:
  curl -fsSL <url>/install.sh | bash
  curl -fsSL <url>/install.sh | bash -s -- /path/to/project
  curl -fsSL <url>/install.sh | bash -s -- --upgrade

The default (no flag) auto-detects v2 layouts (no model: frontmatter, no
.claude-plugin/plugin.json, no .claude/mcp/) and migrates them.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --upgrade)
            FORCE_UPGRADE=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --)
            shift
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            print_usage >&2
            exit 1
            ;;
        *)
            if [ -z "$TARGET" ]; then
                TARGET="$1"
            else
                echo "Unexpected extra argument: $1" >&2
                print_usage >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Resolve target ---------------------------------------------------------------
TARGET="${TARGET:-.}"
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
# Critical-path scripts are explicitly required; the rest of .claude/scripts/*.sh
# rides the glob copy below so the installer stays in sync as helpers are added.
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
    ".claude/scripts/qa-gate.sh" \
    ".claude/scripts/current-task.sh" \
    ".claude/scripts/prevent-orchestrator-edits.sh" \
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

# v2 detection ----------------------------------------------------------------
# Signals (any one is enough to declare a v2 layout; all three is high
# confidence):
#   1. .claude/agents/ exists with agent files that LACK a `model:` frontmatter
#      field (v2 pre-dated model pinning).
#   2. .claude/hooks/hooks.json exists but .claude-plugin/plugin.json does NOT
#      (v2 had no plugin manifest).
#   3. The .claude/ tree lacks .claude/mcp/ AND .claude/skills/workflow-engine/
#      (both arrived in v3).
#
# `--upgrade` forces the upgrade flow regardless of signal count.
detect_v2_install() {
    local claude_dir="$TARGET/.claude"
    [ -d "$claude_dir" ] || return 1

    local signals=()

    # Signal 1: agents without model: frontmatter
    if [ -d "$claude_dir/agents" ]; then
        local missing_model_count=0
        local agent_count=0
        for f in "$claude_dir/agents/"*.md; do
            [ -f "$f" ] || continue
            agent_count=$((agent_count + 1))
            # Look for `model:` inside the first 20 lines (the frontmatter).
            if ! head -20 "$f" 2>/dev/null | grep -qE '^model:'; then
                missing_model_count=$((missing_model_count + 1))
            fi
        done
        if [ "$agent_count" -gt 0 ] && [ "$missing_model_count" = "$agent_count" ]; then
            signals+=("agents lack 'model:' frontmatter")
        fi
    fi

    # Signal 2: hooks.json without plugin.json
    if [ -f "$claude_dir/hooks/hooks.json" ] && [ ! -f "$TARGET/.claude-plugin/plugin.json" ]; then
        signals+=("hooks.json present, no .claude-plugin/plugin.json")
    fi

    # Signal 3: missing v3-era directories
    if [ ! -d "$claude_dir/mcp" ] && [ ! -d "$claude_dir/skills/workflow-engine" ]; then
        # Only flag this signal if .claude/ has any v2-era content at all;
        # an empty .claude/ is not a v2 install, it's just a stub.
        if [ -d "$claude_dir/agents" ] || [ -d "$claude_dir/scripts" ] || [ -f "$claude_dir/settings.json" ]; then
            signals+=("no .claude/mcp/ and no .claude/skills/workflow-engine/")
        fi
    fi

    if [ "${#signals[@]}" -gt 0 ]; then
        V2_SIGNALS="${signals[*]}"
        return 0
    fi
    return 1
}

V2_UPGRADE=false
V2_SIGNALS=""
V2_BACKUP_DIR=""

if [ "$FORCE_UPGRADE" = true ]; then
    V2_UPGRADE=true
    if detect_v2_install; then
        echo -e "${YELLOW}Upgrade mode forced (--upgrade). Detected signals: $V2_SIGNALS${NC}"
    else
        echo -e "${YELLOW}Upgrade mode forced (--upgrade). No v2 signals detected; treating .claude/ as v2 anyway.${NC}"
    fi
elif detect_v2_install; then
    V2_UPGRADE=true
    echo -e "${CYAN}Detected v2 plugin installation. Upgrading to v3...${NC}"
    echo -e "  Signals: $V2_SIGNALS"
fi

# Mode selection (interactive) -------------------------------------------------
BACKUP_DIR="$TARGET/.claude-backup-$(date +%Y%m%d-%H%M%S)"
MERGE_MODE=false
UPDATE_MODE=false

# v2 upgrade path: back up the v2 .claude/ to .claude-v2-backup-<ts>/ and
# fall through to a fresh install. We do not invoke the interactive mode
# prompt because the upgrade is unambiguous.
if [ "$V2_UPGRADE" = true ] && [ -d "$TARGET/.claude" ]; then
    V2_BACKUP_DIR="$TARGET/.claude-v2-backup-$(date +%Y%m%d-%H%M%S)"
    echo -e "${YELLOW}Backing up v2 install to $V2_BACKUP_DIR${NC}"
    mkdir -p "$V2_BACKUP_DIR"
    cp -r "$TARGET/.claude/"* "$V2_BACKUP_DIR/" 2>/dev/null || true
    [ -f "$TARGET/CLAUDE.md" ] && cp "$TARGET/CLAUDE.md" "$V2_BACKUP_DIR/"
    echo -e "${GREEN}OK${NC} v2 backup created"
    # UPDATE_MODE preserves CLAUDE.md and merges settings non-destructively.
    UPDATE_MODE=true
elif [ -d "$TARGET/.claude" ]; then
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
# Copy every hook + helper script. The set has grown across plugin versions
# (v2 was 5 scripts; v3 is 14). Using a glob keeps the installer in sync
# automatically as scripts are added/removed in the plugin source.
shopt -s nullglob
for src in "$SOURCE_DIR/.claude/scripts/"*.sh; do
    copy_file "$src" "$TARGET/.claude/scripts/$(basename "$src")"
done
shopt -u nullglob
chmod +x "$TARGET/.claude/scripts/"*.sh 2>/dev/null || true

# MCP servers -----------------------------------------------------------------
# Copy each MCP server directory wholesale (source files + package.json +
# package-lock.json + tests/). node_modules will be installed by the operator
# if they want to run the servers locally; ship-time we just copy the source.
if [ -d "$SOURCE_DIR/.claude/mcp" ]; then
    mkdir -p "$TARGET/.claude/mcp"
    for mcp_dir in "$SOURCE_DIR/.claude/mcp"/*/; do
        [ -d "$mcp_dir" ] || continue
        mcp_name=$(basename "$mcp_dir")
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --exclude=node_modules --exclude=.tmp --exclude='*.log' \
                "$mcp_dir" "$TARGET/.claude/mcp/$mcp_name/"
        else
            # Fallback: cp -R then prune dev artifacts.
            mkdir -p "$TARGET/.claude/mcp/$mcp_name"
            cp -R "$mcp_dir." "$TARGET/.claude/mcp/$mcp_name/"
            rm -rf "$TARGET/.claude/mcp/$mcp_name/node_modules" 2>/dev/null || true
            rm -rf "$TARGET/.claude/mcp/$mcp_name/.tmp" 2>/dev/null || true
            find "$TARGET/.claude/mcp/$mcp_name" -maxdepth 2 -name '*.log' -type f -delete 2>/dev/null || true
        fi
        echo -e "${GREEN}OK${NC}   mcp/$mcp_name"
    done
fi

# Root MCP config ------------------------------------------------------------
if [ -f "$SOURCE_DIR/.mcp.json" ]; then
    copy_file "$SOURCE_DIR/.mcp.json" "$TARGET/.mcp.json"
fi

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

if [ -n "$V2_BACKUP_DIR" ] && [ -d "$V2_BACKUP_DIR" ]; then
    echo -e "v2 backup:    ${BLUE}$V2_BACKUP_DIR${NC}"
fi
if [ -d "$BACKUP_DIR" ]; then
    echo -e "Backup at:    ${BLUE}$BACKUP_DIR${NC}"
fi

echo ""
if [ "$V2_UPGRADE" = true ]; then
    echo -e "${CYAN}What changed in the v2 -> v3 upgrade:${NC}"
    echo "  - .claude-plugin/plugin.json: first-class Claude Code plugin manifest"
    echo "  - Agent files now pin 'model:' (run /workflow-model to bump)"
    echo "  - Two MCP servers: bd-mcp (21 typed Beads tools), code-context-mcp (3 search tools)"
    echo "  - QA gate is now Beads-label-driven (qa-approved), no longer marker-file"
    echo "  - Hook output uses hookSpecificOutput envelope; PreToolUse blocks orchestrator edits"
    echo "  - SessionStart warns on stale model / old bd; SessionEnd writes a structured summary"
    echo "  - 5-tier test pyramid under .claude/tests/ + GitHub Actions CI"
    echo "  - Single-source-of-truth installer (no embedded heredoc agent prompts)"
    echo ""
    echo -e "Full release notes: ${BLUE}CHANGELOG.md${NC}"
    if [ -n "$V2_BACKUP_DIR" ]; then
        echo -e "Diff your customizations: ${BLUE}diff -r $V2_BACKUP_DIR $TARGET/.claude${NC}"
    fi
else
    echo -e "${CYAN}What's new in v3:${NC}"
    echo "  - Plugin manifest (.claude-plugin/plugin.json) with v3.0.0"
    echo "  - Model pinning per agent + /workflow-model upgrade command"
    echo "  - MAX_THINKING_TOKENS at 64000 + extended-thinking instruction in every agent"
    echo "  - Parent-folder access via additionalDirectories (../)"
    echo "  - SessionStart warns on stale model + old bd"
    echo "  - Single-source-of-truth installer (no heredoc duplication)"
    echo "  - uninstall.sh for clean removal"
fi
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

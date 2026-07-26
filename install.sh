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
INSTALL_MODE_OVERRIDE=""

print_usage() {
    cat <<'USAGE'
Claude Workflow Plugin v3 installer

Usage:
  bash install.sh [project-path]                Install (auto-detects v2)
  bash install.sh --upgrade [project-path]      Force the v2->v3 upgrade flow
  bash install.sh --help                        Print this message

Flags:
  --upgrade        Run the v2->v3 migration even if auto-detection is fuzzy.
                   Backs up .claude/ to .claude-v2-backup-<timestamp>/ before
                   writing v3 files.
  --mode=<1|2|3>   Explicitly choose the install mode for existing .claude/:
                     1 = Backup and install fresh
                     2 = Update workflow (keeps CLAUDE.md, merges settings)
                     3 = Merge only (skip existing files)
                   Useful when running under `curl ... | bash` where the
                   interactive prompt has no usable stdin.
  -h, --help       Print this message and exit 0.

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
        --mode=*)
            INSTALL_MODE_OVERRIDE="${1#*=}"
            shift
            ;;
        --mode)
            INSTALL_MODE_OVERRIDE="${2:-}"
            shift 2
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

# Validate --mode override (must be 1, 2, or 3 if set) ------------------------
if [ -n "$INSTALL_MODE_OVERRIDE" ]; then
    case "$INSTALL_MODE_OVERRIDE" in
        1|2|3) ;;
        *)
            echo "Invalid --mode value: '$INSTALL_MODE_OVERRIDE' (expected 1, 2, or 3)" >&2
            exit 1
            ;;
    esac
fi

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
#
# review-check.sh and impact-report.sh are on this list because BOTH gate ends
# fail CLOSED without them (v4 V3 / G2.n6d): a partial install missing either
# one leaves `qa-gate.sh approve` refusing and the Stop hook blocking, with no
# way to tell from inside the loop that the cause is a missing file. Failing
# loudly here turns a permanent gate deadlock into an install-time error.
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
    ".claude/scripts/review-check.sh" \
    ".claude/scripts/impact-report.sh" \
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
    # Under `curl ... | bash`, stdin is the curl pipe so `read` gets EOF and
    # we'd silently fall to the "Cannot proceed" branch. Prefer the
    # controlling terminal when available; otherwise default to "y" since
    # the script literally cannot continue without git anyway (Beads
    # depends on it).
    if [ -t 0 ]; then
        read -p "Initialize git repository? (required for Beads) (y/n) " -n 1 -r
        echo
    elif (exec 3</dev/tty) 2>/dev/null; then
        # See the mode-prompt block for why this probe is needed.
        echo "(curl-piped; reading from /dev/tty)"
        read -p "Initialize git repository? (required for Beads) (y/n) " -n 1 -r < /dev/tty
        echo
    else
        REPLY="y"
        echo -e "${YELLOW}Non-interactive mode detected. Auto-initializing git (required for Beads).${NC}"
    fi
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
        # When piped from curl, stdin is the pipe — `read` from stdin gets
        # empty input and we'd fall through to "Cancelled." Read from
        # /dev/tty if it's available; otherwise default to Update (the
        # safe non-destructive choice for re-running upgrades).
        if [ -n "$INSTALL_MODE_OVERRIDE" ]; then
            INSTALL_MODE="$INSTALL_MODE_OVERRIDE"
            echo "Mode set via --mode=$INSTALL_MODE"
        elif [ -t 0 ]; then
            # Interactive (terminal stdin)
            read -p "Choose [1-4]: " -n 1 -r INSTALL_MODE
            echo ""
        elif (exec 3</dev/tty) 2>/dev/null; then
            # curl-piped but a controlling terminal is actually openable.
            # The `[ -e /dev/tty ]` test alone is not enough on macOS —
            # the device node always exists but `open()` fails with
            # ENXIO when there's no controlling terminal. Probing with
            # `exec 3</dev/tty` in a subshell tells us for real.
            echo "(curl-piped; reading from /dev/tty)"
            read -p "Choose [1-4]: " -n 1 -r INSTALL_MODE < /dev/tty
            echo ""
        else
            # Fully non-interactive (CI, no controlling tty). Default to
            # Update — the safe re-install path.
            INSTALL_MODE=2
            echo -e "${YELLOW}Non-interactive mode detected. Defaulting to Update (option 2).${NC}"
            echo -e "${YELLOW}Pass --mode=<1|2|3> to override or --upgrade for the v2 migration flow.${NC}"
        fi

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
mkdir -p "$TARGET/.claude/rubrics"
mkdir -p "$TARGET/.claude/tests/mutation"
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
# Glob copy so newly-shipped agents (grader.md @ v3.2.0, judge.md @ v3.4.0)
# ride along without an installer edit per release. The required-source
# check above pins the five v3.0 agents so a missing core role still fails
# fast; the glob picks up everything else under .claude/agents/.
shopt -s nullglob
for src in "$SOURCE_DIR/.claude/agents/"*.md; do
    copy_file "$src" "$TARGET/.claude/agents/$(basename "$src")"
done
shopt -u nullglob

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

# Shared merge-input validity gate (v4.1 / R1-F1) ------------------------------
# `jq empty` is NOT a validity check for a merge input: it exits 0 for an EMPTY
# file AND for a MULTI-DOCUMENT stream. Both Update-mode merges below slurp with
# `jq -s` and index .[0] (existing) / .[1] (new) — so a target holding two
# documents pushes the SHIPPED file out to .[2], silently binding $new to the
# operator's second document. Proven outcome for .mcp.json: the merged config
# comes out with none of the shipped bd / code-graph servers. The only contract
# that makes the positional binding sound is "exactly ONE JSON document, and
# that document is an object" — which also rejects a top-level array or scalar,
# neither of which either merge can index.
# BEGIN JSON_SINGLE_OBJECT_JQ (packaging-parity.test.sh extracts this block; keep the sentinels)
JSON_SINGLE_OBJECT_JQ='length == 1 and (.[0] | type == "object")'
# END JSON_SINGLE_OBJECT_JQ

# json_single_object <file> — 0 when the file holds exactly one JSON document
# and that document is an object; non-zero for empty, multi-document, malformed,
# array/scalar, or unreadable input. Both mode-2 merges gate on this.
json_single_object() {
    jq -s -e "$JSON_SINGLE_OBJECT_JQ" "$1" >/dev/null 2>&1
}

# Root MCP config ------------------------------------------------------------
# Mode 1 (backup-and-install-fresh) and mode 3 (merge/skip-existing) go through
# copy_file exactly as before. Mode 2 (Update) MERGES instead of overwriting, so
# an operator's own MCP servers survive a plugin upgrade:
#
#   mcpServers    — union with the SHIPPED entries winning on collision. That
#                   union IS the v3.5 -> v4 rewrite of `bd` / `code-graph` to
#                   the `${CLAUDE_PROJECT_DIR:-.}` form (the shipped entries
#                   carry it), and it drops nothing the operator added.
#   code-context  — the server retired in 3.3.0 is deleted outright; leaving it
#                   shadows code-graph and points at a launcher directory the
#                   installer no longer copies.
#   top-level keys — untouched (the merge base is $existing), so an operator's
#                   own comment/config blocks survive.
#
# Hoisted and sentinel-delimited so packaging-parity.test.sh executes the REAL
# expression rather than a copied literal. Keep this jq expression equivalent
# to install.ps1's.
# shellcheck disable=SC2016  # jq program text: $existing/$new are jq bindings, not shell vars
# BEGIN MCP_MERGE_JQ (packaging-parity.test.sh extracts this block; keep the sentinels)
MCP_MERGE_JQ='
    .[0] as $existing |
    .[1] as $new |
    $existing
    | .mcpServers = (($existing.mcpServers // {}) + ($new.mcpServers // {}))
    | del(.mcpServers["code-context"])
'
# END MCP_MERGE_JQ

# Operator-owned servers pass through verbatim — including any bare `${VAR}`
# reference, which Claude Code does NOT expand in a project-scoped .mcp.json
# (https://code.claude.com/docs/en/mcp — the documented form is
# `${VAR:-default}`). We never rewrite operator config; we name the server so
# the operator can decide. Emits one server key per line, shipped keys excluded.
# shellcheck disable=SC2016  # jq program text: $merged/$new/$shipped are jq bindings
MCP_BARE_VAR_JQ='
    .[0] as $merged |
    .[1] as $new |
    ($new.mcpServers // {}) as $shipped |
    ($merged.mcpServers // {}) | to_entries
    | map(select($shipped[.key] == null))
    | map(select([.value | .. | strings] | any(test("\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}"))))
    | .[].key
'

if [ -f "$SOURCE_DIR/.mcp.json" ]; then
    MCP_FILE="$TARGET/.mcp.json"
    if [ "$UPDATE_MODE" = true ] && [ -f "$MCP_FILE" ]; then
        cp "$MCP_FILE" "$MCP_FILE.bak"
        if json_single_object "$MCP_FILE"; then
            echo -e "${YELLOW}Merging .mcp.json (preserving operator-added servers)...${NC}"
            MCP_MERGED=$(jq -s "$MCP_MERGE_JQ" "$MCP_FILE" "$SOURCE_DIR/.mcp.json" 2>/dev/null) || MCP_MERGED=""
            if [ -n "$MCP_MERGED" ]; then
                echo "$MCP_MERGED" > "$MCP_FILE"
                echo -e "${GREEN}OK${NC}   .mcp.json merged (previous file at .mcp.json.bak)"
                MCP_BARE_VARS=$(jq -s -r "$MCP_BARE_VAR_JQ" "$MCP_FILE" "$SOURCE_DIR/.mcp.json" 2>/dev/null || true)
                if [ -n "$MCP_BARE_VARS" ]; then
                    while IFS= read -r mcp_srv; do
                        [ -n "$mcp_srv" ] || continue
                        echo -e "${YELLOW}note${NC} .mcp.json server '$mcp_srv' carries a bare \${VAR} reference; project-scoped configs need the \${VAR:-default} form. Left unchanged (operator-owned)."
                    done <<< "$MCP_BARE_VARS"
                fi
            else
                echo -e "${RED}Could not merge .mcp.json - manual review needed (previous file at .mcp.json.bak)${NC}"
            fi
        else
            cp "$SOURCE_DIR/.mcp.json" "$MCP_FILE"
            echo -e "${RED}.mcp.json was not a single JSON object (empty, multi-document, or malformed) - installed the shipped config (previous file saved to .mcp.json.bak)${NC}"
        fi
    else
        copy_file "$SOURCE_DIR/.mcp.json" "$MCP_FILE"
    fi
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

# Rubrics (Phase A / v3.2.0) ---------------------------------------------------
# The grader subagent reads these at grading time. Default + per-domain
# overlays + bug-type overlay; shipped as plain markdown.
if [ -d "$SOURCE_DIR/.claude/rubrics" ]; then
    shopt -s nullglob
    for src in "$SOURCE_DIR/.claude/rubrics/"*.md; do
        copy_file "$src" "$TARGET/.claude/rubrics/$(basename "$src")"
    done
    shopt -u nullglob
fi

# Rubric config (Phase A / v3.2.0) ---------------------------------------------
if [ -f "$SOURCE_DIR/.claude/rubric-config" ]; then
    copy_file "$SOURCE_DIR/.claude/rubric-config" "$TARGET/.claude/rubric-config"
fi

# Review config (v4.0.0 Phase V2) ----------------------------------------------
# Bounded-diligence caps for the optional Sol reviewer lane, read by
# codex-review.sh (the ONE place caps live). Single file, plain text.
# Deliberately NOT in the required-source check — codex-review.sh fails open to
# the documented defaults when the file is absent.
if [ -f "$SOURCE_DIR/.claude/review-config" ]; then
    copy_file "$SOURCE_DIR/.claude/review-config" "$TARGET/.claude/review-config"
fi

# Model-ranking (Phase 0 / v3.1.0) ---------------------------------------------
# Read by model-select.sh on SessionStart. Single file, plain text.
if [ -f "$SOURCE_DIR/.claude/model-ranking" ]; then
    copy_file "$SOURCE_DIR/.claude/model-ranking" "$TARGET/.claude/model-ranking"
fi

# Model-roles (v4.0.0 Phase V1) ------------------------------------------------
# Role -> selection-strategy map read by model-select.sh on SessionStart.
# Single file, plain text. Deliberately NOT in the required-source check —
# a source tree without it still installs (model-select.sh fails open to the
# all-`top` v3.5 behavior when the file is absent).
if [ -f "$SOURCE_DIR/.claude/model-roles" ]; then
    copy_file "$SOURCE_DIR/.claude/model-roles" "$TARGET/.claude/model-roles"
fi

# Effort verdict (v4.0.0 V0 / cnz.1) -------------------------------------------
# The effort A/B interference-test output consumed by `make session` and the
# session-start Warning 4 reconciliation. Single file, plain text. Deliberately
# NOT in the required-source check — a source tree without it still installs.
if [ -f "$SOURCE_DIR/.claude/effort-verdict" ]; then
    copy_file "$SOURCE_DIR/.claude/effort-verdict" "$TARGET/.claude/effort-verdict"
fi

# Mutation tier (Phase C / v3.4.0) ---------------------------------------------
# The /mutation-sweep command and the @judge subagent both expect this
# tier on disk. We ship the catalog, config, harness, judge-gate, and the
# hand-labeled calibration set. Per-run output dirs
# (.claude/.mutation-runs/, .claude/.mutation-worktrees/) are gitignored
# and created on first sweep.
if [ -d "$SOURCE_DIR/.claude/tests/mutation" ]; then
    mkdir -p "$TARGET/.claude/tests/mutation/calibration"
    mkdir -p "$TARGET/.claude/tests/mutation/lib"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude='runs' --exclude='*.log' \
            "$SOURCE_DIR/.claude/tests/mutation/" \
            "$TARGET/.claude/tests/mutation/"
    else
        cp -R "$SOURCE_DIR/.claude/tests/mutation/." \
            "$TARGET/.claude/tests/mutation/"
        rm -rf "$TARGET/.claude/tests/mutation/calibration/runs" 2>/dev/null || true
    fi
    chmod +x "$TARGET/.claude/tests/mutation/"*.sh 2>/dev/null || true
    chmod +x "$TARGET/.claude/tests/mutation/lib/"*.sh 2>/dev/null || true
    echo -e "${GREEN}OK${NC}   tests/mutation/"
fi

# Lessons ledger (Phase 0 / v3.1.0) --------------------------------------------
# The orchestrator reads this during decomposition; seeded with the two
# production lessons. Keep at the repo root so it's discoverable from a
# fresh checkout.
if [ -f "$SOURCE_DIR/LESSONS.md" ]; then
    copy_file "$SOURCE_DIR/LESSONS.md" "$TARGET/LESSONS.md"
fi

# Worktree-include (Phase 0 / v3.1.0) ------------------------------------------
# Patterns required for parallel-specialist isolated worktrees to be
# runnable (env files, etc.).
if [ -f "$SOURCE_DIR/.worktreeinclude" ]; then
    copy_file "$SOURCE_DIR/.worktreeinclude" "$TARGET/.worktreeinclude"
fi

# Plugin manifest --------------------------------------------------------------
copy_file "$SOURCE_DIR/.claude-plugin/plugin.json" "$TARGET/.claude-plugin/plugin.json"

# Settings.json (with merge support) ------------------------------------------
SETTINGS_FILE="$TARGET/.claude/settings.json"
SOURCE_SETTINGS="$SOURCE_DIR/.claude/settings.json"

# The Update-mode merge expression. Replace workflow-owned keys, keep the rest:
#
#   hooks                 — always replaced (workflow-owned wholesale).
#   env                   — union with the SHIPPED values winning on collision,
#                           then the retired CLAUDE_CODE_EFFORT_LEVEL pin is
#                           deleted (idempotent — a no-op when absent). The
#                           union can only ADD keys, so that del is the only
#                           thing that removes a legacy pin on an Update.
#   additionalDirectories — replaced when shipped, else kept.
#   permissions           — add-if-absent: an operator's list is never widened
#                           or narrowed by an upgrade.
#   effortLevel           — add-if-absent (v4.1): a settings file of pre-v3.5
#                           lineage gains the shipped floor, while an
#                           operator's own pin survives untouched.
#   statusLine            — add-if-absent (v4.1): same contract.
#
# "add-if-absent" is keyed on PRESENCE (`has`), never on truthiness (R1-F2).
# `if $existing.effortLevel then` would read an explicit `null` or `false` as
# absent and overwrite it — a present operator-owned key is operator-owned
# whatever its value. The permissions clause carried the same latent defect
# since v4.0.0 and is converted here too, so one expression cannot hold two
# different notions of "absent".
#
# Hoisted and sentinel-delimited so packaging-parity.test.sh executes the REAL
# expression rather than a copied literal. Keep this jq expression equivalent
# to install.ps1's.
# shellcheck disable=SC2016  # jq program text: $existing/$new are jq bindings, not shell vars
# BEGIN SETTINGS_MERGE_JQ (packaging-parity.test.sh extracts this block; keep the sentinels)
SETTINGS_MERGE_JQ='
    .[0] as $existing |
    .[1] as $new |
    $existing
    | .hooks = $new.hooks
    | .env = ((($existing.env // {}) + ($new.env // {})) | del(.CLAUDE_CODE_EFFORT_LEVEL))
    | .additionalDirectories = ($new.additionalDirectories // $existing.additionalDirectories)
    | (if ($existing | has("permissions")) then . else .permissions = $new.permissions end)
    | (if ($existing | has("effortLevel")) then . else .effortLevel = $new.effortLevel end)
    | (if ($existing | has("statusLine"))  then . else .statusLine  = $new.statusLine  end)
'
# END SETTINGS_MERGE_JQ

if [ -f "$SETTINGS_FILE" ]; then
    if [ "$UPDATE_MODE" = true ]; then
        echo -e "${YELLOW}Merging settings.json (preserving non-workflow keys)...${NC}"
        cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak"
        # v4.0.0 (cnz.1): detect a legacy env.CLAUDE_CODE_EFFORT_LEVEL pin in
        # the EXISTING settings before the merge. The env union below can only
        # ADD keys, so without the explicit del the legacy pin survives an
        # Update — and any non-xhigh value there deactivates ultracode
        # orchestration. We print a one-line notice when we actually remove it.
        HAD_EFFORT_ENV=$(jq -r 'if (.env // {} | has("CLAUDE_CODE_EFFORT_LEVEL")) then "yes" else "no" end' "$SETTINGS_FILE" 2>/dev/null || echo "no")
        # R1-F1, same class as .mcp.json above: the merge indexes .[0]/.[1], so
        # a settings.json holding two documents would bind $new to the operator's
        # SECOND document and silently drop every shipped hook. Refuse anything
        # that is not exactly one JSON object. Unlike .mcp.json we do NOT install
        # a fresh copy — settings.json is operator-owned, so the file is left
        # untouched (the .bak above is already taken) and the operator is told
        # why on the existing manual-review line.
        SETTINGS_SKIP_REASON=""
        if json_single_object "$SETTINGS_FILE"; then
            MERGED=$(jq -s "$SETTINGS_MERGE_JQ" "$SETTINGS_FILE" "$SOURCE_SETTINGS" 2>/dev/null) || MERGED=""
        else
            MERGED=""
            SETTINGS_SKIP_REASON=" (not a single JSON object: empty, multi-document, or malformed)"
        fi
        if [ -n "$MERGED" ]; then
            echo "$MERGED" > "$SETTINGS_FILE"
            echo -e "${GREEN}OK${NC}   settings.json merged"
            if [ "$HAD_EFFORT_ENV" = "yes" ]; then
                echo -e "${CYAN}note${NC} removed legacy env.CLAUDE_CODE_EFFORT_LEVEL (v4: a non-xhigh value deactivates ultracode orchestration; effortLevel is now the floor)"
            fi
        else
            echo -e "${RED}Could not merge settings.json${SETTINGS_SKIP_REASON} - manual review needed; your file is unchanged (copy at .claude/settings.json.bak)${NC}"
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
    echo "  - Two MCP servers: bd-mcp (21 typed Beads tools), code-graph-mcp (7 graph tools incl. impact_of / dead_code)"
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
    echo "  - Plugin manifest (.claude-plugin/plugin.json) — see it for the version"
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

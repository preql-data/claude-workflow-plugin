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
#   bash install.sh --upgrade [project-path]         # force the migration flow
#   bash install.sh --help                           # print usage
#   curl -fsSL <url>/install.sh | bash               # via curl (auto-clones)
#   curl -fsSL <url>/install.sh | bash -s -- /path   # specify target path
#   curl -fsSL <url>/install.sh | bash -s -- --upgrade
#
# Upgrades are auto-detected, and there are two of them (v4.1 / U0.3):
#   v2 -> v3   no `model:` frontmatter / no plugin manifest / no .claude/mcp/.
#   v3 -> v4   an installed .claude-plugin/plugin.json declaring 3.x. Backs the
#              tree up, classifies every shipped file by hash against the
#              release the target was installed from, replaces plugin-owned
#              files, preserves operator-owned edits (shipped copy written
#              alongside as <file>.new), and merges settings.json / .mcp.json
#              key-wise instead of clobbering them.
# `--upgrade` forces whichever migration the target's signals point at; it may
# not be combined with `--mode`.
#
# Re-runs (v4.1 / U0.4): a target this installer has already written carries
# .claude/install-manifest, which records the release and the per-file hashes
# it installed. Mode 2 (Update) uses it as the classify old-table, so a second
# run gets the SAME per-file treatment as an upgrade — operator edits preserved
# with a .new alongside instead of overwritten — and skips its backup entirely
# when the tree is already at this release with nothing to write.

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
  bash install.sh [project-path]                Install (auto-detects upgrades)
  bash install.sh --upgrade [project-path]      Force the migration flow
  bash install.sh --help                        Print this message

Flags:
  --upgrade        Run the migration flow even if auto-detection is fuzzy.
                   Which migration depends on the target's signals: a v2
                   layout backs up to .claude-v2-backup-<timestamp>/, an
                   installed plugin manifest backs up to
                   .claude-v3-backup-<timestamp>/ and runs the hash-based
                   v3 -> v4 upgrade. Cannot be combined with --mode.
  --mode=<1|2|3>   Explicitly choose the install mode for existing .claude/:
                     1 = Backup and install fresh
                     2 = Update workflow (keeps CLAUDE.md, merges settings;
                         when the target carries .claude/install-manifest it
                         also preserves your edits per file, .new alongside,
                         and skips the backup when nothing changed)
                     3 = Merge only (skip existing files)
                   Useful when running under `curl ... | bash` where the
                   interactive prompt has no usable stdin.
                   Cannot be combined with --upgrade.
  -h, --help       Print this message and exit 0.

Curl-pipe forms:
  curl -fsSL <url>/install.sh | bash
  curl -fsSL <url>/install.sh | bash -s -- /path/to/project
  curl -fsSL <url>/install.sh | bash -s -- --upgrade

The default (no flag) auto-detects both upgrades: v2 layouts (no model:
frontmatter, no .claude-plugin/plugin.json, no .claude/mcp/) migrate to v3,
and an installed .claude-plugin/plugin.json declaring 3.x takes the v3 -> v4
upgrade flow (backup, per-file hash classification, operator files preserved
with a .new alongside, settings.json / .mcp.json merged key-wise). Anything
else falls through to the three existing install modes.
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

# --upgrade and --mode are mutually exclusive (v4.1 / U0.3) -------------------
# They answer the same question with different mechanisms, and silently
# letting one win would make the destructive choice unpredictable: --upgrade
# owns the whole decision (timestamped backup, per-file hash classification,
# verdict-driven writes) while --mode picks one of the three flat
# existing-install behaviours. Refuse rather than guess.
if [ "$FORCE_UPGRADE" = true ] && [ -n "$INSTALL_MODE_OVERRIDE" ]; then
    echo -e "${RED}--upgrade and --mode=$INSTALL_MODE_OVERRIDE cannot be combined.${NC}" >&2
    echo "  --upgrade runs a migration flow that decides per file (backup," >&2
    echo "  classify, replace / preserve / merge)." >&2
    echo "  --mode picks one flat behaviour for an existing .claude/." >&2
    echo "Pass exactly one of them." >&2
    exit 1
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
# Scratch space for the generated surface manifest, the upgrade plan, and the
# upgrade report (v4.1 / U0.3). Created on demand by ensure_work_dir.
INSTALL_WORK_DIR=""
cleanup_install_tmp() {
    if [ -n "$TMP_CLONE" ] && [ -d "$TMP_CLONE" ]; then
        rm -rf "$TMP_CLONE"
    fi
    if [ -n "$INSTALL_WORK_DIR" ] && [ -d "$INSTALL_WORK_DIR" ]; then
        rm -rf "$INSTALL_WORK_DIR"
    fi
    # Explicit success: an EXIT trap whose last command fails under `set -e`
    # would rewrite the script's exit status.
    return 0
}
trap cleanup_install_tmp EXIT

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

# Surface manifest helpers (v4.1 / U0.3) --------------------------------------
# .claude/scripts/workflow-manifest.sh is the ONE machine-readable enumeration
# of what this plugin ships (path / class / sha256). Two consumers here:
#   - the install-manifest written into every target, so a later upgrade (and
#     the L2/L3 parity specs) can tell exactly which release wrote the tree;
#   - the v3 -> v4 upgrade flow's `classify` call, which needs the same
#     enumeration to decide replace / preserve / merge per file.
MANIFEST_TOOL="$SOURCE_DIR/.claude/scripts/workflow-manifest.sh"

# The version this run is INSTALLING, read from the source manifest rather
# than hardcoded — every readout and the install-manifest header interpolate
# it, so a release bump needs no installer edit.
SOURCE_VERSION=$(jq -r '.version // empty' "$SOURCE_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo "")
SOURCE_VERSION_LABEL="${SOURCE_VERSION:-unknown}"

SOURCE_MANIFEST=""

ensure_work_dir() {
    if [ -z "$INSTALL_WORK_DIR" ]; then
        INSTALL_WORK_DIR=$(mktemp -d)
    fi
    return 0
}

# ensure_source_manifest — generate the source surface manifest ONCE per run
# into $SOURCE_MANIFEST. Returns non-zero (leaving $SOURCE_MANIFEST empty)
# when the generator is missing or fails, so callers degrade with a note
# instead of aborting an otherwise-good install. Callers MUST use it as an
# `if` condition; the non-zero return is a normal outcome, not an error.
ensure_source_manifest() {
    if [ -n "$SOURCE_MANIFEST" ]; then
        return 0
    fi
    if [ ! -f "$MANIFEST_TOOL" ]; then
        return 1
    fi
    ensure_work_dir
    local out="$INSTALL_WORK_DIR/source-manifest.tsv"
    if ! bash "$MANIFEST_TOOL" generate "$SOURCE_DIR" > "$out" 2>/dev/null; then
        return 1
    fi
    SOURCE_MANIFEST="$out"
    return 0
}

# target_plugin_version — the `version` field of the manifest ALREADY installed
# in the target, or "" when there is none / it is unreadable. Every caller runs
# before the copy loops overwrite it; once plugin.json has been replaced this
# function reports the new version, which is why the v3 flow captures it during
# detection.
target_plugin_version() {
    local installed="$TARGET/.claude-plugin/plugin.json"
    if [ ! -f "$installed" ]; then
        return 0
    fi
    jq -r '.version // empty' "$installed" 2>/dev/null || true
}

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

# v3 detection (v4.1 / U0.3) --------------------------------------------------
# Signals, in decision order:
#   (a) $TARGET/.claude-plugin/plugin.json declares a 3.x version. PRIMARY and
#       sufficient on its own — the installed manifest is the one artifact that
#       states, on the record, which release wrote the tree.
#   (b) That version is missing/unreadable/empty AND neither v4 marker is
#       present (.claude/scripts/review-check.sh, .claude/model-roles). It
#       reuses v2 signal 3's "not just an empty stub" guard, so a fresh or
#       empty target can never take this branch.
#
#       What (b) actually covers is a manifest whose VERSION FIELD is
#       unreadable or hand-edited — the file is there, jq gets nothing out of
#       it. A DELETED manifest is NOT this branch's case in practice: v2
#       signal 2 ("hooks.json present, no .claude-plugin/plugin.json") fires
#       first on any real installed tree, and the caller tries
#       detect_v2_install FIRST, so a manifest-less install routes to the v2
#       flow for as long as .claude/hooks/hooks.json survives. (b) sees a
#       deleted manifest only when hooks.json is gone too. Do not delete v2
#       signal 2 on the strength of this branch — they cover different trees.
#
# Sets V3_DETECTED_VERSION (may be "" under signal b) and V3_SIGNALS.
detect_v3_install() {
    local claude_dir="$TARGET/.claude"
    local ver
    ver=$(target_plugin_version)

    case "$ver" in
        3.*)
            V3_DETECTED_VERSION="$ver"
            V3_SIGNALS=".claude-plugin/plugin.json declares version $ver"
            return 0
            ;;
    esac

    # A readable non-3.x version (4.x, or anything else) is NOT this flow.
    if [ -n "$ver" ]; then
        return 1
    fi
    if [ ! -d "$claude_dir" ]; then
        return 1
    fi
    # Either v4 marker means the target is already v4 or newer.
    if [ -f "$claude_dir/scripts/review-check.sh" ] || [ -f "$claude_dir/model-roles" ]; then
        return 1
    fi
    # "Not just an empty stub": .claude/ has to hold real installed content.
    if [ -d "$claude_dir/agents" ] || [ -d "$claude_dir/scripts" ] || [ -f "$claude_dir/settings.json" ]; then
        V3_DETECTED_VERSION=""
        V3_SIGNALS="no readable plugin version; no .claude/scripts/review-check.sh and no .claude/model-roles (both v4)"
        return 0
    fi
    return 1
}

V2_UPGRADE=false
V2_SIGNALS=""
V2_BACKUP_DIR=""
V3_UPGRADE=false
V3_SIGNALS=""
V3_DETECTED_VERSION=""
V3_BACKUP_DIR=""
# Verdict-driven writes: copies go through place_by_verdict instead of a flat
# cp. TRUE for the v3 -> v4 upgrade flow, and (v4.1 / U0.4) for a mode-2 Update
# whose target carries a usable .claude/install-manifest. False everywhere
# else, which is what keeps copy_file's verdict lookup a no-op for fresh
# installs, mode 1 and mode 3.
VERDICT_MODE=false
# The classify plan (path/class/verdict TSV) those writes consume. Empty when
# no plan was built.
PLAN_FILE=""
# The hash table the plan was built against; named in the readout. Two
# sources, one code path: the frozen manifests/v<release>.sha256 table (v3
# flow) or the target's own install-manifest body (mode-2 Update, and a v4 -> v4
# --upgrade since U0.5). PLAN_OLD_TABLE is the PATH; PLAN_OLD_TABLE_LABEL is
# what the readouts call it, since one of the two sources is a temp file.
PLAN_OLD_TABLE=""
PLAN_OLD_TABLE_LABEL=""
# The install-manifest body of the tree being updated, and the release its
# header names. Set by install_manifest_old_table; "" when the target has no
# usable manifest (every pre-v4.1 install).
INSTALLED_MANIFEST_BODY=""
INSTALLED_MANIFEST_VERSION=""
PRESERVED_FILES=()
REPLACED_FILES=()

if [ "$FORCE_UPGRADE" = true ]; then
    # --upgrade forces A migration; WHICH one is still a detection question.
    # v2 signals win (that layout predates the manifest entirely), then an
    # installed plugin manifest of any version takes the v3 flow, and a target
    # we cannot read at all keeps the legacy "treat .claude/ as v2" behaviour
    # --upgrade has had since v3.0.
    if detect_v2_install; then
        V2_UPGRADE=true
        echo -e "${YELLOW}Upgrade mode forced (--upgrade). Detected signals: $V2_SIGNALS${NC}"
    elif [ -f "$TARGET/.claude-plugin/plugin.json" ]; then
        V3_UPGRADE=true
        if detect_v3_install; then
            echo -e "${YELLOW}Upgrade mode forced (--upgrade). Running the v3 -> v${SOURCE_VERSION_LABEL} upgrade flow.${NC}"
            echo -e "  Signals: $V3_SIGNALS"
        else
            V3_DETECTED_VERSION=$(target_plugin_version)
            echo -e "${YELLOW}Upgrade mode forced (--upgrade). Target declares v${V3_DETECTED_VERSION:-unknown}; running the upgrade flow anyway.${NC}"
            # Deliberately does NOT name the old table: which one this run uses
            # is decided further down (the target's own install-manifest when it
            # has a usable one, else the frozen release table) and the
            # "Classifying the installed tree against ..." line reports it for
            # real. Naming "the frozen table" here was wrong for a v4 -> v4
            # upgrade the moment U0.5 taught the flow to prefer the manifest.
            echo -e "  Anything that differs from both the shipped file and the reference table named below is treated as customized (replaced with a report line, or preserved as .new)."
        fi
    else
        V2_UPGRADE=true
        echo -e "${YELLOW}Upgrade mode forced (--upgrade). No v2 signals detected; treating .claude/ as v2 anyway.${NC}"
    fi
elif detect_v2_install; then
    V2_UPGRADE=true
    echo -e "${CYAN}Detected v2 plugin installation. Upgrading to v3...${NC}"
    echo -e "  Signals: $V2_SIGNALS"
elif detect_v3_install; then
    V3_UPGRADE=true
    echo -e "${CYAN}Detected v${V3_DETECTED_VERSION:-3.x} plugin installation. Upgrading to v${SOURCE_VERSION_LABEL}...${NC}"
    echo -e "  Signals: $V3_SIGNALS"
fi

# Upgrade-plan helpers (v4.1 / U0.3, generalised in U0.4) ----------------------
# ONE classify call site, TWO old-table sources:
#   - manifests/v<release>.sha256, the frozen table for the release a v3.x
#     target was installed from (the v3 -> v4 upgrade flow); and
#   - $TARGET/.claude/install-manifest, written by every v4.1+ install, for a
#     mode-2 Update of a tree this installer already wrote.
# Both produce the same path/class/verdict plan and both feed the same
# place_by_verdict walk further down, so the preservation rules cannot drift
# between an upgrade and a re-run. That single walk is the whole design: the
# second run on an upgraded tree used to plain-copy every shipped file and
# re-clobber anything the operator had changed since.

# build_plan <old-table> [label] — classify $TARGET against $SOURCE_DIR using
# <old-table>, leaving the plan at $PLAN_FILE. Returns non-zero (with
# PLAN_FILE reset to "") when the generator or the table is missing, or when
# classify fails; callers decide whether that is fatal. MUST be used as an
# `if` condition — a non-zero return is a normal outcome, not an error.
#
# [label] is what the readouts CALL the old table. It exists because one of the
# two sources is a temp file: an install-manifest body lives at
# $INSTALL_WORK_DIR/installed-manifest.tsv, and a report line reading "hashed
# against installed-manifest.tsv" names a path the operator has never seen and
# cannot inspect. Defaults to the table's basename, which is the right answer
# for the frozen manifests/v<release>.sha256 tables.
build_plan() {
    local old="$1"
    local label="${2:-}"
    if [ ! -f "$MANIFEST_TOOL" ] || [ ! -f "$old" ]; then
        PLAN_FILE=""
        return 1
    fi
    ensure_work_dir
    local out="$INSTALL_WORK_DIR/upgrade-plan.tsv"
    if ! bash "$MANIFEST_TOOL" classify \
            --target "$TARGET" --source "$SOURCE_DIR" --old-table "$old" \
            > "$out"; then
        PLAN_FILE=""
        return 1
    fi
    PLAN_FILE="$out"
    PLAN_OLD_TABLE="$old"
    if [ -n "$label" ]; then
        PLAN_OLD_TABLE_LABEL="$label"
    else
        PLAN_OLD_TABLE_LABEL=$(basename "$old")
    fi
    return 0
}

# install_manifest_old_table — 0 when $TARGET/.claude/install-manifest is one
# of ours AND usable as a classify old-table. On success sets
# INSTALLED_MANIFEST_BODY (a temp copy of the manifest minus its header line)
# and INSTALLED_MANIFEST_VERSION (the release the header names).
#
# Globals rather than stdout on purpose: a `$(...)` form would run the whole
# function in a SUBSHELL and both assignments would evaporate (LESSONS.md,
# 2026-06-12 — the same trap as `die` inside a command substitution).
#
# Every failure arm is a legitimate tree, not an error: no manifest at all
# (every pre-v4.1 install), a foreign header, or a body with no valid row.
# The row check matters — a header-only or truncated file would otherwise
# classify every shipped file as "not in the old table" and turn a routine
# Update into a wall of .new litter.
install_manifest_old_table() {
    local mf="$TARGET/.claude/install-manifest"
    [ -f "$mf" ] || return 1
    local header
    header=$(head -1 "$mf" 2>/dev/null || echo "")
    case "$header" in
        "# claude-workflow-plugin "*) ;;
        *) return 1 ;;
    esac
    ensure_work_dir
    local body="$INSTALL_WORK_DIR/installed-manifest.tsv"
    tail -n +2 "$mf" > "$body" 2>/dev/null || return 1
    # The generator's own row grammar: <path><TAB><class><TAB><64 lowercase
    # hex>. No {64} interval in the regex — BSD awk's support for those is not
    # something an installer should bet on; length() is portable everywhere.
    local rows
    rows=$(awk -F'\t' '
        $1 != "" &&
        ($2 == "workflow" || $2 == "operator" || $2 == "merged") &&
        $3 ~ /^[0-9a-f]+$/ && length($3) == 64 { n++ }
        END { printf "%d", n + 0 }' "$body")
    [ "${rows:-0}" -ge 1 ] || return 1
    INSTALLED_MANIFEST_BODY="$body"
    INSTALLED_MANIFEST_VERSION="${header#\# claude-workflow-plugin }"
    return 0
}

# plan_row_count — rows in the plan; 0 when there is none. An EMPTY plan must
# never read as "nothing to do": with no rows, every path falls through
# place_by_verdict's unknown-verdict arm and gets COPIED, so skipping the
# backup on an empty plan would clobber the tree without a snapshot. The probe
# requires at least one row for exactly that reason — the same "degrade to
# nothing is known, never to nothing to do" rule workflow-manifest.sh applies
# to an empty old table.
plan_row_count() {
    if [ -z "$PLAN_FILE" ] || [ ! -f "$PLAN_FILE" ]; then
        printf '0'
        return 0
    fi
    awk 'END { printf "%d", NR + 0 }' "$PLAN_FILE"
}

# plan_write_count — how many plan rows would put bytes on disk. TWO terms:
#
#   1. Verdict rows: copy-new, replace-stock and replace-custom (all three
#      write the shipped file) plus preserve-custom (writes a <path>.new
#      sidecar). skip-current writes nothing.
#   2. `merged`-class rows whose file is ABSENT from the target (v4.1 / U0.5).
#      classify emits `merge` for settings.json / .mcp.json unconditionally,
#      because the installer reconciles them with jq instead of copying — but
#      the two jq merge sections only own the case where the file EXISTS. When
#      it does not, the path falls through to a plain copy (place_by_verdict's
#      `merge` arm for .mcp.json, the else arm of the settings block), and that
#      copy is a write the first term cannot see.
#
# TERM 2 IS THE U0.5 RIDER ON U0.4's PROBE, and the alternative was to soften
# the readout to "no tracked file changes". Counting the write won because the
# probe's contract is "it fired => this run put no bytes on disk", and that
# sentence is what the backup decision rests on. An operator who deleted
# .mcp.json and re-ran the same release was told "no file changes" while the
# installer recreated the file. Nothing was ever at risk — an absent file
# cannot be lost, and a mode-2 backup only ever snapshots .claude/ — but an
# invariant that is only NEARLY true is one a future change can break without
# failing a test. So the write is counted: the readout stays literally
# accurate, the backup falls on the conservative side, and the cost is one
# timestamped backup directory in the rare case where a config file was
# deleted before a re-run.
#
# Prints 0 when there is no plan — every caller must therefore check
# VERDICT_MODE first, or "no plan" would read as "no work".
#
# Standalone awk rather than four plan_count calls: this runs inside the mode
# block, before plan_count is defined further down.
plan_write_count() {
    if [ -z "$PLAN_FILE" ] || [ ! -f "$PLAN_FILE" ]; then
        printf '0'
        return 0
    fi
    local n
    n=$(awk -F'\t' '
        $3 == "copy-new" || $3 == "replace-stock" ||
        $3 == "replace-custom" || $3 == "preserve-custom" { n++ }
        END { printf "%d", n + 0 }' "$PLAN_FILE")
    # MERGED-ABSENT-START (load-bearing; the L2 META-TEST DELETES this block and
    # asserts the probe goes back to firing on a tree that is about to gain a
    # file. Keep both sentinels, and keep the deletion fail-safe: without this
    # loop the count can only get SMALLER — i.e. back to the pre-U0.5 readout,
    # never to a spuriously skipped backup.)
    local merged_rel
    while IFS= read -r merged_rel; do
        [ -n "$merged_rel" ] || continue
        [ -f "$TARGET/$merged_rel" ] || n=$((n + 1))
    done < <(awk -F'\t' '$2 == "merged" { print $1 }' "$PLAN_FILE")
    # MERGED-ABSENT-END
    printf '%d' "$n"
}

# Mode selection (interactive) -------------------------------------------------
BACKUP_DIR="$TARGET/.claude-backup-$(date +%Y%m%d-%H%M%S)"
MERGE_MODE=false
UPDATE_MODE=false
# Set true by the two Update-mode jq merges below. The v3 upgrade report
# distinguishes "merged key-wise" from "installed as shipped" on the strength
# of these rather than by looking for a leftover .bak, which a previous run
# could also have left behind.
SETTINGS_MERGE_DONE=false
MCP_MERGE_DONE=false

# v2 upgrade path: back up the v2 .claude/ to .claude-v2-backup-<ts>/ and
# fall through to a fresh install. We do not invoke the interactive mode
# prompt because the upgrade is unambiguous.
if [ "$V2_UPGRADE" = true ] && [ -d "$TARGET/.claude" ]; then
    V2_BACKUP_DIR="$TARGET/.claude-v2-backup-$(date +%Y%m%d-%H%M%S)"
    echo -e "${YELLOW}Backing up v2 install to $V2_BACKUP_DIR${NC}"
    mkdir -p "$V2_BACKUP_DIR"
    # `cp -R dir/.` rather than `cp -r dir/*` (v4.1 / U0.3): the glob form is
    # silently dotfile-blind, so .claude/.qa-tracking/ — every gate record and
    # review artifact in a live install — never reached the backup.
    cp -R "$TARGET/.claude/." "$V2_BACKUP_DIR/" 2>/dev/null || true
    [ -f "$TARGET/CLAUDE.md" ] && cp "$TARGET/CLAUDE.md" "$V2_BACKUP_DIR/"
    echo -e "${GREEN}OK${NC} v2 backup created"
    # UPDATE_MODE preserves CLAUDE.md and merges settings non-destructively.
    UPDATE_MODE=true
elif [ "$V3_UPGRADE" = true ]; then
    # ---- v3.x -> v4 upgrade flow (v4.1 / U0.3) ------------------------------
    # Order is load-bearing:
    #   1. BACK UP. Nothing below is reversible without it.
    #   2. CLASSIFY. `classify` hashes the target, so it has to run before the
    #      first write.
    #   3. Copy loops consume the plan through copy_file -> place_by_verdict.
    V3_BACKUP_DIR="$TARGET/.claude-v3-backup-$(date +%Y%m%d-%H%M%S)"
    echo -e "${YELLOW}Backing up the installed plugin to $V3_BACKUP_DIR${NC}"
    mkdir -p "$V3_BACKUP_DIR"
    if [ -d "$TARGET/.claude" ]; then
        # Same dotfile-blindness fix as the v2 path above, and here the backup
        # is the ONLY copy of a replaced file — so a failure is fatal rather
        # than `|| true`. Upgrading a tree we could not snapshot is exactly the
        # unrecoverable case this flow exists to prevent.
        if ! cp -R "$TARGET/.claude/." "$V3_BACKUP_DIR/"; then
            echo -e "${RED}Could not back up $TARGET/.claude — refusing to upgrade in place.${NC}"
            echo "Free the disk space (or fix the permissions) and rerun."
            exit 1
        fi
    fi
    # Root-level files the upgrade may touch. Stored FLAT in the backup root:
    # the backup is already a snapshot of .claude/, so mirroring paths would
    # nest a confusing second .claude-plugin/ inside it. plugin.json is the
    # only name that could collide, and it keeps its basename.
    for v3_root_file in CLAUDE.md .mcp.json LESSONS.md .worktreeinclude; do
        if [ -f "$TARGET/$v3_root_file" ]; then
            cp "$TARGET/$v3_root_file" "$V3_BACKUP_DIR/$v3_root_file"
        fi
    done
    if [ -f "$TARGET/.claude-plugin/plugin.json" ]; then
        cp "$TARGET/.claude-plugin/plugin.json" "$V3_BACKUP_DIR/plugin.json"
    fi
    echo -e "${GREEN}OK${NC} backup created (includes dotfiles: .qa-tracking/ and friends)"

    # UPDATE_MODE is what routes settings.json and .mcp.json through the
    # key-wise jq merges below instead of a clobbering copy — which is exactly
    # what classify's `merge` verdict for both `merged`-class files means.
    UPDATE_MODE=true

    # Pick the old table this upgrade classifies against. TWO sources, in
    # preference order (v4.1 / U0.5):
    #
    #   1. $TARGET/.claude/install-manifest, when the target is NOT a 3.x
    #      install and the manifest parses. It records the exact per-file hashes
    #      THIS tree was installed with, so "stock" and "customized" are
    #      answered from the tree's own history rather than inferred from a
    #      release table that predates it. Reached by `--upgrade` on a 4.x
    #      target: without it, every file that changed between v3.5 and the
    #      installed release looks customized, so stock operator files collect
    #      spurious .new sidecars and stock workflow files get reported as
    #      "replaced; yours is in the backup" — the lossless-but-noisy behaviour
    #      U0.4 documented and left open.
    #
    #   2. manifests/v<release>.sha256 — the frozen table for the release a
    #      target was installed from. This is the ONLY option for a genuine 3.x
    #      tree (no install-manifest existed before v4.1) and the fallback for
    #      any target whose manifest is missing or unreadable. v3.5.0 is the
    #      default; a future manifests/v<version>.sha256 is picked up
    #      automatically, which is how this flow stays honest for 3.2 / 3.3
    #      targets later.
    #
    # A 3.x version pins source 2 explicitly rather than by accident: if some
    # hand-built 3.x tree ever carried an install-manifest, the frozen table is
    # still the right answer for it, because the v3.5 -> v4 verdicts that
    # sections 1-7 of the L2 spec pin are defined against that table.
    UPGRADE_OLD_TABLE=""
    UPGRADE_OLD_TABLE_LABEL=""
    case "$V3_DETECTED_VERSION" in
        3.*|"")
            ;;
        *)
            if install_manifest_old_table; then
                UPGRADE_OLD_TABLE="$INSTALLED_MANIFEST_BODY"
                UPGRADE_OLD_TABLE_LABEL=".claude/install-manifest (v$INSTALLED_MANIFEST_VERSION)"
            fi
            ;;
    esac

    if [ -z "$UPGRADE_OLD_TABLE" ]; then
        V3_FROZEN_TABLE="$SOURCE_DIR/manifests/v3.5.0.sha256"
        if [ -n "$V3_DETECTED_VERSION" ] && [ -f "$SOURCE_DIR/manifests/v$V3_DETECTED_VERSION.sha256" ]; then
            V3_FROZEN_TABLE="$SOURCE_DIR/manifests/v$V3_DETECTED_VERSION.sha256"
        fi
        UPGRADE_OLD_TABLE="$V3_FROZEN_TABLE"
        UPGRADE_OLD_TABLE_LABEL=$(basename "$V3_FROZEN_TABLE")
    fi

    if [ ! -f "$MANIFEST_TOOL" ] || [ ! -f "$UPGRADE_OLD_TABLE" ]; then
        echo -e "${RED}The upgrade flow needs both .claude/scripts/workflow-manifest.sh and a frozen hash table.${NC}"
        echo "  generator: $MANIFEST_TOOL"
        echo "  old table: $UPGRADE_OLD_TABLE"
        echo "This source tree has neither, so customized files cannot be told from"
        echo "stock ones. Your backup is at $V3_BACKUP_DIR."
        echo "Rerun with --mode=2 for the flat non-destructive update instead."
        exit 1
    fi

    echo -e "${YELLOW}Classifying the installed tree against $UPGRADE_OLD_TABLE_LABEL...${NC}"
    if ! build_plan "$UPGRADE_OLD_TABLE" "$UPGRADE_OLD_TABLE_LABEL"; then
        echo -e "${RED}Could not classify the installed tree; refusing to write a partial upgrade.${NC}"
        echo "Your backup is at $V3_BACKUP_DIR. Rerun with --mode=2 to take the flat"
        echo "non-destructive update path instead."
        exit 1
    fi
    VERDICT_MODE=true
    echo -e "${GREEN}OK${NC} upgrade plan: $(wc -l < "$PLAN_FILE" | tr -d ' ') file(s) classified"
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
                # Mode 1 is the explicit "back up and install fresh" choice, so
                # its backup is the POINT of the mode rather than a safety net
                # for whatever this run happens to write. It therefore keeps its
                # unconditional backup and its flat overwrite; the no-change
                # probe below is deliberately mode-2 only (v4.1 / U0.4).
                echo -e "${YELLOW}Creating backup at $BACKUP_DIR${NC}"
                mkdir -p "$BACKUP_DIR"
                # Dotfile-inclusive form; see the v2 backup above for why.
                cp -R "$TARGET/.claude/." "$BACKUP_DIR/" 2>/dev/null || true
                [ -f "$TARGET/CLAUDE.md" ] && cp "$TARGET/CLAUDE.md" "$BACKUP_DIR/"
                echo -e "${GREEN}OK${NC} Backup created"
                ;;
            2)
                echo -e "${YELLOW}Update mode: updating workflow, preserving CLAUDE.md${NC}"
                UPDATE_MODE=true

                # Verdict-driven Update (v4.1 / U0.4) --------------------------
                # Through v4.0 this branch plain-copied every shipped file, so
                # the SECOND run on a tree the installer had already written
                # silently overwrote anything the operator changed in between —
                # the very clobber the v3 -> v4 flow exists to prevent, one run
                # later. $TARGET/.claude/install-manifest names the release that
                # wrote the tree and carries its per-file hashes, which is
                # exactly the old table classify needs, so the Update reuses the
                # upgrade flow's verdict walk rather than a second copy of it.
                #
                # No usable manifest (every pre-v4.1 install) -> the legacy
                # plain-copy behaviour, unchanged. The note says so, and points
                # out that this run writes the manifest the NEXT one will use.
                # Classification runs BEFORE the backup because it only reads,
                # and the probe below needs its verdicts to decide.
                # UPDATE-VERDICT-START (load-bearing; the L2 META-TEST DELETES
                # this block to prove the preservation comes from here — the
                # stripped copy falls back to the pre-v4.1 plain-copy Update and
                # re-clobbers the operator's file, which is the whole regression.
                # Keep both sentinels, and keep deletion fail-safe: without this
                # block VERDICT_MODE stays false and the legacy path runs.)
                if install_manifest_old_table; then
                    # The label is what a readout would CALL this table; the
                    # path itself is a temp file. Passed here as well as on the
                    # upgrade path so the two call sites cannot drift into
                    # naming the same source two different ways.
                    if build_plan "$INSTALLED_MANIFEST_BODY" \
                            ".claude/install-manifest (v$INSTALLED_MANIFEST_VERSION)"; then
                        VERDICT_MODE=true
                        echo -e "${GREEN}OK${NC} classified against .claude/install-manifest (v$INSTALLED_MANIFEST_VERSION): $(wc -l < "$PLAN_FILE" | tr -d ' ') file(s)"
                    else
                        echo -e "${YELLOW}note${NC} could not classify against .claude/install-manifest; updating with plain copies (your tree is backed up below)"
                    fi
                else
                    echo -e "${YELLOW}note${NC} no usable .claude/install-manifest in the target; updating with plain copies. This run writes one, so the next update preserves your per-file edits."
                fi
                # UPDATE-VERDICT-END

                # No-change probe. Re-running the SAME release over an unchanged
                # tree writes nothing, and a timestamped backup dir per re-run is
                # noise the operator has to clean up by hand. Skip the backup
                # only when BOTH hold: the manifest header names the release we
                # are installing, and the plan carries zero write verdicts. The
                # merges and the install-manifest rewrite still run either way —
                # both are idempotent.
                #
                # A preserved customization (preserve-custom) counts as a write,
                # so a tree with one still gets its backup: "wrote nothing" has
                # to mean nothing, not almost nothing.
                # NOCHANGE-PROBE-START (load-bearing; the L2 META-TEST rewrites
                # the initialiser inside these sentinels to force the probe TRUE
                # and asserts the backup assertion flips. Keep both sentinels,
                # and keep the fail-safe default false: deleting this block must
                # leave the backup unconditional, never the other way round.)
                UPDATE_SKIP_BACKUP=false
                if [ "$VERDICT_MODE" = true ] &&
                   [ -n "$INSTALLED_MANIFEST_VERSION" ] &&
                   [ "$INSTALLED_MANIFEST_VERSION" = "$SOURCE_VERSION_LABEL" ] &&
                   [ "$(plan_row_count)" -ge 1 ] &&
                   [ "$(plan_write_count)" = "0" ]; then
                    UPDATE_SKIP_BACKUP=true
                fi
                # NOCHANGE-PROBE-END

                if [ "$UPDATE_SKIP_BACKUP" = true ]; then
                    echo -e "${CYAN}note${NC} already at $SOURCE_VERSION_LABEL; no file changes — skipping backup"
                else
                    mkdir -p "$BACKUP_DIR"
                    # Dotfile-inclusive form; see the v2 backup above for why.
                    cp -R "$TARGET/.claude/." "$BACKUP_DIR/" 2>/dev/null || true
                    echo -e "${GREEN}OK${NC} Backup created"
                fi
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

# Verdict lookup for the verdict-driven flows (v4.1 / U0.3, U0.4) -------------
# plan_verdict <path-relative-to-target> — the classify verdict, or "" when the
# path is not in the plan (no plan at all on non-verdict paths).
#
# awk with a field-1 EQUALITY test rather than grep: shipped paths are full of
# regex metacharacters (`.claude/...`), and awk exits 0 when nothing matched,
# so this needs no `|| true` to survive `set -e`. No associative arrays — the
# installer has to run under macOS's bash 3.2.
plan_verdict() {
    if [ -z "$PLAN_FILE" ] || [ ! -f "$PLAN_FILE" ]; then
        return 0
    fi
    awk -F'\t' -v p="$1" '$1 == p { print $3; exit }' "$PLAN_FILE"
}

# plan_count <verdict> — how many plan rows carry that verdict. Counted from the
# plan (not from what the copy loops did) so the readout reports the actual
# classification, including the two rsync'd directory trees.
plan_count() {
    if [ -z "$PLAN_FILE" ] || [ ! -f "$PLAN_FILE" ]; then
        printf '0'
        return 0
    fi
    awk -F'\t' -v v="$1" '$3 == v { n++ } END { printf "%d", n + 0 }' "$PLAN_FILE"
}

# place_by_verdict <src> <dst> — verdict-driven placement. Reached from
# copy_file whenever VERDICT_MODE is on: the v3 -> v4 upgrade flow, and a
# mode-2 Update classified against the target's own install-manifest. ONE walk
# for both, so an upgrade and a re-run can never disagree about what is safe to
# overwrite.
#
#   copy-new / replace-stock  copy (new file, or untouched stock)
#   skip-current              nothing to do (target already byte-identical)
#   replace-custom            copy AND report; the operator's version is in the
#                             backup (plugin-owned product wins)
#   preserve-custom           do NOT touch the operator's file; write the
#                             shipped content to <path>.new and report
#   merge                     plain copy — reachable only when a `merged`-class
#                             file is ABSENT from the target, since the jq
#                             merge sections own the exists case
#   "" (not in the plan)      copy, with a note: the manifest is supposed to
#                             enumerate everything the copy loops touch, so an
#                             unlisted path means the two have drifted
place_by_verdict() {
    local src="$1"
    local dst="$2"
    local rel verdict
    rel="${dst#"$TARGET"/}"
    verdict=$(plan_verdict "$rel")

    # plugin.json is the version marker the NEXT upgrade's detection reads, so
    # it is copied on every verdict. A customized one is still reported (the
    # original is in the backup).
    if [ "$rel" = ".claude-plugin/plugin.json" ]; then
        cp "$src" "$dst"
        if [ "$verdict" = "replace-custom" ]; then
            REPLACED_FILES+=("$rel")
            echo -e "${YELLOW}OK${NC}   $rel (replaced; yours is in the backup)"
        else
            echo -e "${GREEN}OK${NC}   $rel"
        fi
        return 0
    fi

    case "$verdict" in
        skip-current)
            echo -e "${CYAN}same${NC} $rel (already current)"
            ;;
        preserve-custom)
            cp "$src" "$dst.new"
            PRESERVED_FILES+=("$rel")
            echo -e "${YELLOW}keep${NC} $rel (yours; shipped version written to $rel.new)"
            ;;
        replace-custom)
            cp "$src" "$dst"
            REPLACED_FILES+=("$rel")
            echo -e "${YELLOW}OK${NC}   $rel (replaced; yours is in the backup)"
            ;;
        copy-new|replace-stock|merge)
            cp "$src" "$dst"
            echo -e "${GREEN}OK${NC}   $rel"
            ;;
        "")
            cp "$src" "$dst"
            echo -e "${YELLOW}OK${NC}   $rel (not in the shipped manifest; copied)"
            ;;
        *)
            cp "$src" "$dst"
            echo -e "${YELLOW}OK${NC}   $rel (unrecognised verdict '$verdict'; copied)"
            ;;
    esac
    return 0
}

# Idempotent file copy with merge-mode awareness ------------------------------
copy_file() {
    local src="$1"
    local dst="$2"
    if [ "$MERGE_MODE" = true ] && [ -f "$dst" ]; then
        echo -e "${YELLOW}skip${NC} $(basename "$dst") (exists)"
        return 0
    fi
    # The verdict-driven flows decide per file. Routing that through copy_file
    # rather than rewriting each copy loop keeps ONE decision point: every loop
    # below (agents, scripts, commands, rubrics, single config files) gets the
    # verdict treatment for free, and no future loop can forget it. Gating on
    # VERDICT_MODE rather than V3_UPGRADE is what lets the mode-2 Update reuse
    # the walk unchanged (v4.1 / U0.4).
    if [ "$VERDICT_MODE" = true ]; then
        place_by_verdict "$src" "$dst"
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
#
# v3 upgrade flow (v4.1 / U0.3): this tree stays a DIRECTORY UNIT. The manifest
# enumerates its files (so the parity assertions cover them) and classify emits
# a verdict per file, but rsync wins here and those verdicts are not consulted —
# a per-file walk would mean reimplementing rsync's delete/exclude semantics in
# the installer. Sound because the whole tree is `workflow` class: vendored
# server source is plugin product, never operator-owned, so the only verdicts it
# can produce are copy-new / skip-current / replace-stock / replace-custom, and
# rsync's outcome matches all four. The upgrade report names it as a directory
# unit rather than pretending it went file by file. Same for tests/mutation/.
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
                MCP_MERGE_DONE=true
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
# Directory unit, exactly like .claude/mcp/ above: rsync wholesale, per-file
# upgrade verdicts deliberately not consulted (all `workflow` class).
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
            SETTINGS_MERGE_DONE=true
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

# Install manifest (v4.1 / U0.3) ----------------------------------------------
# Written on EVERY install path — fresh, modes 1/2/3, the v2 migration and the
# v3 upgrade — right after the last copy. It records the SOURCE surface this run
# installed from: one header line naming the version, then the generated
# path/class/sha256 TSV verbatim.
#
# Two consumers depend on it and both compare bytes, so this file carries NO
# timestamp, no hostname and no install-path: the next upgrade reads the header
# to know which release wrote the tree, and the parity/equivalence specs
# regenerate the manifest and diff it against the body. Adding "installed at
# <date>" here would break both.
if ensure_source_manifest; then
    {
        printf '# claude-workflow-plugin %s\n' "$SOURCE_VERSION_LABEL"
        cat "$SOURCE_MANIFEST"
    } > "$TARGET/.claude/install-manifest"
    echo -e "${GREEN}OK${NC}   .claude/install-manifest ($SOURCE_VERSION_LABEL)"
else
    echo -e "${YELLOW}note${NC} could not write .claude/install-manifest (workflow-manifest.sh unavailable in $SOURCE_DIR)"
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

# v3 upgrade readout (v4.1 / U0.3) --------------------------------------------
# Plain text on purpose: the same bytes go to the terminal AND to
# $V3_BACKUP_DIR/upgrade-report.txt, and ANSI escapes in a saved report are
# noise. Both version numbers are read from the two plugin.json files — the
# installed one was captured during detection, before the copy loops replaced
# it — so no release number is hardcoded here.
v3_write_report() {
    local from_label="v$V3_DETECTED_VERSION"
    if [ -z "$V3_DETECTED_VERSION" ]; then
        from_label="an unidentified v3.x install"
    fi
    local total_classified
    total_classified=$(wc -l < "$PLAN_FILE" | tr -d ' ')
    local f

    cat <<REPORT
Upgrade complete: $from_label -> v$SOURCE_VERSION_LABEL

Target:           $TARGET
Backup:           $V3_BACKUP_DIR
Install manifest: $TARGET/.claude/install-manifest

Files by upgrade verdict (workflow-manifest.sh classify, hashed against ${PLAN_OLD_TABLE_LABEL:-$(basename "$PLAN_OLD_TABLE")}):
  copied (new)           $(plan_count copy-new)
  replaced (stock)       $(plan_count replace-stock)
  already current        $(plan_count skip-current)
  replaced (customized)  $(plan_count replace-custom)
  preserved (yours)      $(plan_count preserve-custom)
  merged key-wise        $(plan_count merge)
  ---------------------- ---
  total classified       $total_classified

The lists below cover the per-file walk. .claude/mcp/ and .claude/tests/mutation/
are copied wholesale with rsync (plugin-owned product, never operator-owned), so
their files are counted above but not listed one by one.
REPORT

    printf '\nMerged key-wise instead of overwritten:\n'
    if [ "$SETTINGS_MERGE_DONE" = true ]; then
        printf '  .claude/settings.json  (your pre-upgrade copy: .claude/settings.json.bak)\n'
    else
        printf '  .claude/settings.json  (installed as shipped; nothing to merge)\n'
    fi
    if [ "$MCP_MERGE_DONE" = true ]; then
        printf '  .mcp.json              (your pre-upgrade copy: .mcp.json.bak)\n'
    else
        printf '  .mcp.json              (installed as shipped; nothing to merge)\n'
    fi

    printf '\nPreserved your version, shipped version written alongside as *.new (%s):\n' \
        "${#PRESERVED_FILES[@]}"
    if [ "${#PRESERVED_FILES[@]}" -eq 0 ]; then
        printf '  (none — no operator-owned file differed from the shipped one)\n'
    else
        for f in "${PRESERVED_FILES[@]}"; do
            printf '  %s\n      -> shipped version at %s.new\n' "$f" "$f"
        done
    fi

    printf '\nReplaced, and yours was customized (your version is in the backup) (%s):\n' \
        "${#REPLACED_FILES[@]}"
    if [ "${#REPLACED_FILES[@]}" -eq 0 ]; then
        printf '  (none)\n'
    else
        for f in "${REPLACED_FILES[@]}"; do
            printf '  %s\n' "$f"
        done
    fi

    cat <<REPORT

ACTION REQUIRED

  1. Review each *.new file, merge what you want into your own copy, then
     delete the *.new file. Nothing reads them; they exist so an upgrade never
     silently overwrites something you wrote.

  2. Pre-v4 approvals on OPEN tasks re-block once, on purpose. The v4
     change-set denylist changed, so the Stop hook now recomputes a different
     change_set_hash: a task still carrying a qa-approved label from before
     this upgrade reports LABEL_WITHOUT_RECORD and has to be re-approved. That
     is the correct fail-closed direction — a stale approval must not release
     work. CLOSED tasks are historical and are never re-blocked. The exact
     recovery commands are in CHANGELOG.md under
     "UPGRADE NOTE — one-time hash migration".

  3. If anything looks wrong, your pre-upgrade tree is intact:
       diff -r $V3_BACKUP_DIR $TARGET/.claude
REPORT
}

# Done -------------------------------------------------------------------------
echo ""
if [ "$V3_UPGRADE" = true ]; then
    ensure_work_dir
    V3_REPORT_FILE="$INSTALL_WORK_DIR/upgrade-report.txt"
    v3_write_report > "$V3_REPORT_FILE"
    cat "$V3_REPORT_FILE"
    if cp "$V3_REPORT_FILE" "$V3_BACKUP_DIR/upgrade-report.txt" 2>/dev/null; then
        echo ""
        echo -e "This report: ${BLUE}$V3_BACKUP_DIR/upgrade-report.txt${NC}"
    else
        echo ""
        echo -e "${YELLOW}note${NC} could not save the report into $V3_BACKUP_DIR"
    fi
else
    # Fresh installs and the three flat modes keep the readout they have had
    # since v3.0 (the v4 rebrand of this block is U0.8).
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

    # Verdict-driven Update summary (v4.1 / U0.4). Only a mode-2 Update with a
    # usable install-manifest reaches this: the v3 flow prints its own full
    # report in the branch above, and every other path has no plan to
    # summarise. Deliberately short — the per-file `keep` / `OK` lines are
    # already in the scrollback; what an operator cannot reconstruct from those
    # is the count and the list of .new files still waiting for a decision.
    if [ "$VERDICT_MODE" = true ]; then
        echo ""
        echo -e "${CYAN}Classified against .claude/install-manifest (v$INSTALLED_MANIFEST_VERSION):${NC}"
        echo "  already current        $(plan_count skip-current)"
        echo "  copied (new)           $(plan_count copy-new)"
        echo "  replaced (stock)       $(plan_count replace-stock)"
        echo "  replaced (customized)  $(plan_count replace-custom)"
        echo "  preserved (yours)      $(plan_count preserve-custom)"
        echo "  merged key-wise        $(plan_count merge)"
        if [ "${#PRESERVED_FILES[@]}" -gt 0 ]; then
            echo ""
            echo "Your version was kept; the shipped version is alongside as *.new:"
            for preserved_file in "${PRESERVED_FILES[@]}"; do
                echo "  $preserved_file  ->  $preserved_file.new"
            done
            echo "Review each *.new, merge what you want, then delete it."
        fi
        if [ "${#REPLACED_FILES[@]}" -gt 0 ]; then
            echo ""
            echo "Replaced, and yours was customized (your version is in the backup):"
            for replaced_file in "${REPLACED_FILES[@]}"; do
                echo "  $replaced_file"
            done
        fi
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

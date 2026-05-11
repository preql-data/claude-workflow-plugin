#!/bin/bash
# Claude Workflow Plugin - Uninstaller (Linux/macOS)
#
# Uninstall is the rare destructive op where we ask one yes/no confirmation.
# Files are MOVED to a trash directory rather than rm -rf'd, so the user can
# recover if they change their mind.
#
# Usage:
#   bash uninstall.sh [project-path]
#
# Optional: --restore-backup re-installs from the most recent .claude-backup-*

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Args ------------------------------------------------------------------------
RESTORE_BACKUP=false
TARGET="."
for arg in "$@"; do
    case "$arg" in
        --restore-backup) RESTORE_BACKUP=true ;;
        -*) echo "Unknown flag: $arg"; exit 2 ;;
        *) TARGET="$arg" ;;
    esac
done

if [ ! -d "$TARGET" ]; then
    echo -e "${RED}Target directory does not exist: $TARGET${NC}"
    exit 1
fi
TARGET=$(cd "$TARGET" && pwd)

echo ""
echo -e "${BLUE}Claude Workflow Plugin - Uninstaller${NC}"
echo ""
echo -e "Target: ${CYAN}$TARGET${NC}"
echo ""

# Discover what's installed ---------------------------------------------------
TO_REMOVE=()
DESCRIPTIONS=()

if [ -d "$TARGET/.claude" ]; then
    TO_REMOVE+=("$TARGET/.claude")
    AGENT_COUNT=$(find "$TARGET/.claude/agents" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    SCRIPT_COUNT=$(find "$TARGET/.claude/scripts" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    DESCRIPTIONS+=(".claude/ ($AGENT_COUNT agents, $SCRIPT_COUNT scripts, settings.json, hooks, etc.)")
fi

if [ -d "$TARGET/.claude-plugin" ]; then
    TO_REMOVE+=("$TARGET/.claude-plugin")
    DESCRIPTIONS+=(".claude-plugin/ (plugin.json manifest)")
fi

if [ -d "$TARGET/.beads" ]; then
    TO_REMOVE+=("$TARGET/.beads")
    DESCRIPTIONS+=(".beads/ (Beads task database -- contains all your tracked tasks)")
fi

# Existing backups (will be left in place by default; user can clean later)
EXISTING_BACKUPS=$(find "$TARGET" -maxdepth 1 -name '.claude-backup-*' -type d 2>/dev/null | sort)
LATEST_BACKUP=$(echo "$EXISTING_BACKUPS" | tail -1)

if [ "${#TO_REMOVE[@]}" -eq 0 ]; then
    echo -e "${YELLOW}Nothing to remove. The plugin does not appear to be installed at $TARGET.${NC}"
    exit 0
fi

# Print what will happen ------------------------------------------------------
echo -e "${YELLOW}The following will be moved to a trash directory:${NC}"
for desc in "${DESCRIPTIONS[@]}"; do
    echo "  - $desc"
done
echo ""

if [ -n "$LATEST_BACKUP" ]; then
    echo -e "${CYAN}Backups found (will be kept in place):${NC}"
    while IFS= read -r b; do
        [ -n "$b" ] && echo "  - $b"
    done <<< "$EXISTING_BACKUPS"
    if [ "$RESTORE_BACKUP" = true ]; then
        echo ""
        echo -e "${YELLOW}--restore-backup set: after removal, will restore from $LATEST_BACKUP${NC}"
    fi
    echo ""
fi

# Confirmation (the rare exception per autonomy principle #3) -----------------
read -p "Proceed with uninstall? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Move to trash ---------------------------------------------------------------
TRASH_DIR="$TARGET/.claude-uninstall-trash-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$TRASH_DIR"

for path in "${TO_REMOVE[@]}"; do
    if [ -e "$path" ]; then
        mv "$path" "$TRASH_DIR/"
        echo -e "${GREEN}OK${NC} moved $(basename "$path") -> $TRASH_DIR/"
    fi
done

# CLAUDE.md is the user's project memory; leave it alone unless empty/template
CLAUDE_MD="$TARGET/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    if grep -q "<!-- Describe your project: what it does, who it's for -->" "$CLAUDE_MD" 2>/dev/null \
        && [ "$(wc -l < "$CLAUDE_MD" | tr -d ' ')" -lt 60 ]; then
        # Looks like the unmodified template -- safe to move
        mv "$CLAUDE_MD" "$TRASH_DIR/"
        echo -e "${GREEN}OK${NC} moved CLAUDE.md (unmodified template) -> $TRASH_DIR/"
    else
        echo -e "${CYAN}note${NC} CLAUDE.md left in place (looks customized; remove manually if you want)"
    fi
fi

# Optional restore from backup ------------------------------------------------
if [ "$RESTORE_BACKUP" = true ] && [ -n "$LATEST_BACKUP" ] && [ -d "$LATEST_BACKUP" ]; then
    echo ""
    echo -e "${YELLOW}Restoring from $LATEST_BACKUP...${NC}"
    cp -r "$LATEST_BACKUP"/* "$TARGET/" 2>/dev/null || true
    # If the backup contained .claude/ and CLAUDE.md they'll be restored; .beads is NOT
    # in the backup format from install.sh (intentional), so the user will need to re-run
    # `bd init` if they want Beads back.
    echo -e "${GREEN}OK${NC} restored configuration from backup"
    echo "  (Note: .beads database was not in the backup; run 'bd init' to recreate.)"
fi

echo ""
echo -e "${GREEN}Uninstall complete.${NC}"
echo ""
echo -e "Trash:  ${CYAN}$TRASH_DIR${NC}"
echo "  -> Recover with: mv \"$TRASH_DIR\"/.* \"$TARGET\"/  (or copy specific files back)"
echo "  -> Permanently delete with: rm -rf \"$TRASH_DIR\""
echo ""

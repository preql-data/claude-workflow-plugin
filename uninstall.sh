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
#
# ROOT-SCOPE FILES (v4.1 / U0.5)
# ------------------------------
# Through v4.0 this script removed .claude/, .claude-plugin/ and .beads/ and
# left every ROOT-level file the installer had written — .mcp.json, LESSONS.md
# and .worktreeinclude — sitting in the project. An operator who uninstalled
# got a tree that looked clean and still had three plugin files in it, with no
# way to tell which of them they had written themselves.
#
# $TARGET/.claude/install-manifest (written by every v4.1+ install) closes
# that: it records path/class/sha256 for everything the installer put on disk,
# so a root-scope row can be hashed and judged instead of guessed at.
#
#   hash matches the manifest -> untouched since install; moves to the trash
#                                with the directories.
#   hash differs              -> the operator edited it (a ledger they wrote
#                                into, an .mcp.json holding their own servers).
#                                LEFT IN PLACE, with a note.
#   cannot be hashed          -> also left in place. We never move a file we
#                                could not verify.
#
# No manifest, a foreign header, or a body with no valid row -> the pre-v4.1
# behaviour, unchanged: the three directories move and root files stay. That is
# the only correct fallback — with no table of hashes there is no way to tell a
# stock file from an operator's, and this is a destructive operation.
#
# CONTAINMENT (v4.1 / U0.7, claude-workflow-plugin-wn4)
# ----------------------------------------------------
# A manifest row is UNTRUSTED INPUT to a script that calls `mv`, so a row has to
# be proven to name a file inside the project before it is acted on. That takes
# TWO rules, because the first one is not enough:
#
#   lexical   manifest_root_rows' awk filter drops absolute rows and rows
#             carrying a `..` segment.
#   physical  row_contained resolves the row's PARENT DIRECTORY with `cd`/`pwd -P`
#             and requires the result to be inside the resolved target.
#
# The second rule exists because the first is a string test, and `[ -f ]` and
# hashing both FOLLOW SYMLINKS: a row like `data/thing.txt`, where `data` is a
# symlink to somewhere else on the disk, is lexically spotless and still reached
# a file outside the project and moved it (wn4, reproduced before the fix — the
# readout even called it "unmodified since install"). Physical containment is
# what makes the file header's invariant true rather than nearly true.
#
# Deliberately NOT the cheaper "root rows must be FLAT" rule: root scope is flat
# in TODAY's surface only, and the generator already documents a shipped-docs
# subset (docs/) arriving in a later phase. A flat-only rule would silently stop
# consuming those rows the release they appear.

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
# The same target with every symlink in it RESOLVED. `cd` + `pwd -P` is the
# portable way to get it: realpath(1) is absent on older macOS, readlink -f is
# GNU-only, and a destructive uninstaller may not require python3. Computed once;
# row_contained compares against it. Falls back to the logical path if the cd
# fails, which cannot happen here (the -d test above just succeeded) but would
# leave the comparison strict rather than empty if it ever did.
TARGET_PHYS=$(cd "$TARGET" 2>/dev/null && pwd -P) || TARGET_PHYS=""
[ -n "$TARGET_PHYS" ] || TARGET_PHYS="$TARGET"

echo ""
echo -e "${BLUE}Claude Workflow Plugin - Uninstaller${NC}"
echo ""
echo -e "Target: ${CYAN}$TARGET${NC}"
echo ""

# Install-manifest helpers (v4.1 / U0.5) --------------------------------------
# Hashing is resolved ONCE. Same fallback chain as workflow-manifest.sh
# (sha256sum -> shasum -a 256 -> openssl dgst), normalised to bare lowercase
# 64-hex, because the manifest this compares against was written by that
# generator.
HASH_TOOL=""

resolve_hash_tool() {
    if command -v sha256sum >/dev/null 2>&1; then
        HASH_TOOL="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        HASH_TOOL="shasum"
    elif command -v openssl >/dev/null 2>&1; then
        HASH_TOOL="openssl"
    fi
    return 0
}

# hash_of <file> — bare lowercase 64-hex sha256 on stdout, or NOTHING when it
# cannot be computed (no tool, unreadable file, malformed output).
#
# Empty is a legitimate answer here, not an error: the caller treats an
# unverifiable file as "leave it alone". Deliberately the opposite policy from
# workflow-manifest.sh, which dies on a bad hash — there a wrong hash silently
# overwrites a customized file, here an absent hash only means one extra file
# is left on disk for the operator to delete by hand.
hash_of() {
    local f="$1"
    local raw=""
    local out=""
    [ -f "$f" ] || return 0
    case "$HASH_TOOL" in
        sha256sum)
            raw=$(sha256sum "$f" 2>/dev/null) || raw=""
            out="${raw%% *}"
            ;;
        shasum)
            raw=$(shasum -a 256 "$f" 2>/dev/null) || raw=""
            out="${raw%% *}"
            ;;
        openssl)
            # openssl 1.x prints "SHA256(f)= <hex>", 3.x "SHA2-256(f)= <hex>";
            # the hash is the last field either way.
            raw=$(openssl dgst -sha256 "$f" 2>/dev/null) || raw=""
            out="${raw##* }"
            ;;
        *)
            out=""
            ;;
    esac
    [ "${#out}" -eq 64 ] || return 0
    case "$out" in
        *[!0-9a-f]*) return 0 ;;
    esac
    printf '%s' "$out"
}

# manifest_root_rows — `<path><TAB><sha256>` for every ROOT-SCOPE row of
# $TARGET/.claude/install-manifest; nothing at all when the manifest is absent,
# carries a foreign header, or holds no valid row.
#
# Root scope is defined by the PATH RULE — not under .claude/ and not under
# .claude-plugin/ — rather than by a list of names, so the release that ships a
# fourth root-level file needs no edit here. Absolute paths and any path
# containing a .. segment are dropped: this feeds `mv`, and a manifest row that
# escaped the target would move a file from outside the project.
#
# The valid-row count gates the WHOLE output. A header-only or truncated
# manifest has to degrade to "we know nothing about this tree" (legacy
# behaviour), never to "this tree has no root-scope files".
manifest_root_rows() {
    local mf="$TARGET/.claude/install-manifest"
    [ -f "$mf" ] || return 0
    case "$(head -1 "$mf" 2>/dev/null || echo "")" in
        "# claude-workflow-plugin "*) ;;
        *) return 0 ;;
    esac
    # The generator's row grammar: <path><TAB><class><TAB><64 lowercase hex>.
    # length() rather than a {64} interval — BSD awk's support for those is not
    # something a destructive script should bet on. The header line has no tabs,
    # so it cannot satisfy the grammar and needs no separate skip.
    awk -F'\t' '
        $1 != "" &&
        ($2 == "workflow" || $2 == "operator" || $2 == "merged") &&
        $3 ~ /^[0-9a-f]+$/ && length($3) == 64 {
            valid++
            if ($1 !~ /^\.claude\// && $1 !~ /^\.claude-plugin\// &&
                $1 !~ /^\// && $1 !~ /(^|\/)\.\.(\/|$)/) {
                rows[++n] = $1 "\t" $3
            }
        }
        END {
            if (valid < 1) { exit 0 }
            for (i = 1; i <= n; i++) { print rows[i] }
        }
    ' "$mf" 2>/dev/null || true
    return 0
}

# row_contained <relative-path> — 0 when $TARGET/<relative-path>'s PARENT
# DIRECTORY resolves physically inside $TARGET_PHYS (or IS $TARGET_PHYS), 1
# otherwise. The wn4 guard; see the CONTAINMENT block in the file header.
#
# The PARENT is what is resolved, not the file: a candidate that is itself a
# symlink is safe to hand to `mv`, which relocates the LINK and leaves the file it
# points at alone. A symlinked parent is the dangerous shape, because then `mv`
# operates on a real file that lives somewhere else.
#
# Callers only reach this for rows whose file EXISTS, so a failing `cd` means a
# genuinely unreadable parent rather than a routine absent file — and that is
# refused too (fail closed: never move what cannot be located).
row_contained() {
    local rel="$1"
    local parent parent_phys
    parent=$(dirname "$TARGET/$rel")
    parent_phys=$(cd "$parent" 2>/dev/null && pwd -P) || parent_phys=""
    [ -n "$parent_phys" ] || return 1
    case "$parent_phys" in
        "$TARGET_PHYS")   return 0 ;;
        "$TARGET_PHYS"/*) return 0 ;;
    esac
    return 1
}

# Discover what's installed ---------------------------------------------------
TO_REMOVE=()
DESCRIPTIONS=()
# Root-scope files that will NOT move, and why. Reported after the move next to
# the CLAUDE.md note, so the record of what was left behind sits with the
# record of what went.
ROOT_KEPT_MODIFIED=()
ROOT_KEPT_UNVERIFIED=()
# Rows REFUSED because they resolve outside the project (wn4). Kept separate from
# the two "kept" lists on purpose: those are files the operator owns, this is a
# manifest we do not trust.
ROOT_REFUSED_OUTSIDE=()

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

# Root-scope files, from the install manifest (v4.1 / U0.5). Enumerated HERE,
# before the confirmation, so every path that will move is on screen when the
# operator answers y/n. Appended after the three directories so a tree with no
# usable manifest produces exactly the pre-v4.1 listing.
resolve_hash_tool
ROOT_ROWS=""
if [ -n "$HASH_TOOL" ]; then
    ROOT_ROWS=$(manifest_root_rows)
elif [ -f "$TARGET/.claude/install-manifest" ]; then
    echo -e "${YELLOW}note${NC} no sha256 tool on PATH (need sha256sum, shasum, or openssl);"
    echo "     root-level plugin files cannot be verified and will be left in place."
    echo ""
fi
while IFS=$'\t' read -r mf_path mf_hash; do
    [ -n "$mf_path" ] || continue
    [ -f "$TARGET/$mf_path" ] || continue
    # WN4-CONTAINMENT-START (load-bearing; the L2 META-TEST at
    # installer-manifest-parity.sh 9c DELETES this block and asserts the
    # symlinked-parent row moves the outside file again — wn4's defect. Keep both
    # sentinels, and keep the deletion fail-OPEN: without this block the script
    # degrades to the pre-hardening behaviour, never to refusing legitimate rows.)
    if ! row_contained "$mf_path"; then
        ROOT_REFUSED_OUTSIDE+=("$mf_path")
        continue
    fi
    # WN4-CONTAINMENT-END
    ACTUAL_HASH=$(hash_of "$TARGET/$mf_path")
    if [ -z "$ACTUAL_HASH" ]; then
        ROOT_KEPT_UNVERIFIED+=("$mf_path")
    elif [ "$ACTUAL_HASH" = "$mf_hash" ]; then
        TO_REMOVE+=("$TARGET/$mf_path")
        DESCRIPTIONS+=("$mf_path (unmodified since install)")
    else
        ROOT_KEPT_MODIFIED+=("$mf_path")
    fi
done <<< "$ROOT_ROWS"

# Existing backups (will be left in place by default; user can clean later).
# All THREE prefixes are listed: .claude-backup-* from install modes 1/2, plus
# .claude-v2-backup-* and .claude-v3-backup-* from the two migration flows.
# Listing only the first made an upgraded project look like it had no backups at
# all — and the migration ones are precisely the snapshots holding the
# pre-upgrade tree.
EXISTING_BACKUPS=$(find "$TARGET" -maxdepth 1 -type d \
    \( -name '.claude-backup-*' -o -name '.claude-v2-backup-*' -o -name '.claude-v3-backup-*' \) \
    2>/dev/null | sort)
# --restore-backup restores from a mode-1/2 .claude-backup-* ONLY, deliberately
# unchanged: a migration backup is a snapshot of a PREVIOUS MAJOR's tree, so
# restoring one after an uninstall would resurrect a v2/v3 layout under a v4
# name. The listing above is informational; the restore source is not widened.
RESTORABLE_BACKUPS=$(find "$TARGET" -maxdepth 1 -name '.claude-backup-*' -type d 2>/dev/null | sort)
LATEST_BACKUP=$(printf '%s\n' "$RESTORABLE_BACKUPS" | tail -1)

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

if [ "${#ROOT_KEPT_MODIFIED[@]}" -gt 0 ] || [ "${#ROOT_KEPT_UNVERIFIED[@]}" -gt 0 ]; then
    echo -e "${CYAN}Left in place (yours, not the installer's any more):${NC}"
    # Each loop is guarded by its own count: bash 3.2 expands an empty array to
    # one empty word under some option combinations, and a phantom "  - " line
    # in a destructive-op readout is worse than four extra lines of shell.
    if [ "${#ROOT_KEPT_MODIFIED[@]}" -gt 0 ]; then
        for kept in "${ROOT_KEPT_MODIFIED[@]}"; do
            echo "  - $kept (modified since install)"
        done
    fi
    if [ "${#ROOT_KEPT_UNVERIFIED[@]}" -gt 0 ]; then
        for kept in "${ROOT_KEPT_UNVERIFIED[@]}"; do
            echo "  - $kept (could not be verified)"
        done
    fi
    echo ""
fi

# Refused rows (wn4). Printed BEFORE the confirmation and in their own block: an
# operator staring at the last screen of a destructive op needs to see that a row
# was ignored — and needs it NOT to appear in the "will be moved" list above.
if [ "${#ROOT_REFUSED_OUTSIDE[@]}" -gt 0 ]; then
    echo -e "${YELLOW}Refused (the install manifest names a path outside this project):${NC}"
    for refused in "${ROOT_REFUSED_OUTSIDE[@]}"; do
        echo "  - $refused (resolves outside the project; not touched)"
    done
    echo "  The manifest has been edited or a directory in the path is a symlink."
    echo ""
fi

# Gated on EXISTING_BACKUPS rather than LATEST_BACKUP: a project whose only
# backup is a v2/v3 migration snapshot still has backups to report, and it is
# the one that most needs to hear so.
if [ -n "$EXISTING_BACKUPS" ]; then
    echo -e "${CYAN}Backups found (will be kept in place):${NC}"
    while IFS= read -r b; do
        [ -n "$b" ] && echo "  - $b"
    done <<< "$EXISTING_BACKUPS"
    if [ "$RESTORE_BACKUP" = true ]; then
        echo ""
        if [ -n "$LATEST_BACKUP" ]; then
            echo -e "${YELLOW}--restore-backup set: after removal, will restore from $LATEST_BACKUP${NC}"
        else
            echo -e "${YELLOW}--restore-backup set, but no .claude-backup-* directory exists to restore from.${NC}"
            echo "  (A .claude-v2-backup-*/.claude-v3-backup-* migration snapshot is never restored"
            echo "   automatically — it holds a previous major's layout. Copy from it by hand if that"
            echo "   is really what you want.)"
        fi
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

# Root-scope files the operator changed since install, or that could not be
# hashed: never moved. The note is the record — an operator reading only the
# tail of this output has to be able to see that something was deliberately
# left behind, and which.
if [ "${#ROOT_KEPT_MODIFIED[@]}" -gt 0 ]; then
    for kept in "${ROOT_KEPT_MODIFIED[@]}"; do
        echo -e "${CYAN}note${NC} $kept left in place (modified since install; remove manually if you want)"
    done
fi
if [ "${#ROOT_KEPT_UNVERIFIED[@]}" -gt 0 ]; then
    for kept in "${ROOT_KEPT_UNVERIFIED[@]}"; do
        echo -e "${CYAN}note${NC} $kept left in place (could not verify it against the install manifest)"
    done
fi
if [ "${#ROOT_REFUSED_OUTSIDE[@]}" -gt 0 ]; then
    for refused in "${ROOT_REFUSED_OUTSIDE[@]}"; do
        echo -e "${YELLOW}note${NC} $refused (resolves outside the project; refused, nothing was moved for that row)"
    done
fi

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

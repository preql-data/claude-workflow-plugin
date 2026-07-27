#!/bin/bash
# workflow-manifest.sh — the ONE machine-readable enumeration of the plugin's
# shipped surface, plus the hash-based customization verdict the v3.5->v4
# upgrade path is built on (v4.1 Phase U0 / claude-workflow-plugin-gzc).
#
# WHY THIS EXISTS
# ---------------
# install.sh's copy loops are the de-facto answer to "what does this plugin
# ship?", and for two releases they answered WRONG: the agent list was
# hardcoded, .claude/agents/grader.md was left out of it, and every fresh
# v3.2/v3.3 install silently lacked the rubric loop's grader while the repo's
# own tests stayed green (LESSONS.md, recorded 2026-06-12). Glob-copy fixed
# that instance; it did not make the surface CHECKABLE.
#
# An upgrade path cannot be built on a surface definition that only exists as
# a sequence of cp calls. This script turns the surface into a DATA ARTIFACT:
# a sorted, header-free, timestamp-free TSV that can be regenerated on demand,
# byte-compared against a frozen per-release table, and asserted against an
# install target. Determinism is load-bearing — downstream specs regenerate
# this output and compare it byte-for-byte, so nothing here may embed a
# timestamp, a hostname, a locale-dependent sort, or an unordered glob.
#
# THE THREE CLASSES
# -----------------
#   workflow  Plugin-owned product. The installer replaces these wholesale;
#             an operator edit to one of them is a local fork, not a setting.
#   operator  Operator-owned content the installer SEEDS but must never
#             clobber once the operator has touched it (rubrics, the model
#             ranking, the lessons ledger).
#   merged    Structured config the installer merges key-wise with jq rather
#             than copying (settings.json, .mcp.json). Never a straight copy,
#             so it never gets a copy/skip/replace verdict.
#
# The surface rules below MIRROR install.sh's copy loops exactly (install.sh
# "Creating plugin structure..." through the plugin-manifest copy). When a
# copy loop changes, this file changes in the same commit — that pairing is
# the whole point of the artifact.
#
# SUBCOMMANDS
#   generate <source-root>
#       Sorted TSV on stdout, one row per shipped file:
#           <path><TAB><class><TAB><sha256>
#       Paths are relative to <source-root> (e.g. .claude/agents/qa.md).
#       No header, no comments, no timestamps.
#
#   classify --target <dir> --source <dir> --old-table <file>
#       Sorted TSV on stdout, one row per SOURCE-manifest entry:
#           <path><TAB><class><TAB><verdict>
#       <old-table> is a frozen manifest from the release the target was
#       installed from (see manifests/). It is what lets us tell "the
#       operator never touched this stock file" from "the operator edited
#       it": a target file whose hash still matches the old release's hash
#       is stock and safe to replace.
#
#       Verdicts, in decision order:
#           merge           class is `merged` — always; the installer does a
#                           jq key-wise merge and never a copy.
#           copy-new        the path does not exist in the target at all.
#           skip-current    target hash == source hash; already up to date.
#           replace-stock   target hash == the old release's hash for that
#                           path; untouched stock, safe to overwrite.
#           replace-custom  differs from both, class `workflow` — plugin
#                           product wins.
#           preserve-custom differs from both, class `operator` — the
#                           operator's content wins (caller writes .new
#                           alongside and reports it).
#
# EXIT CODES
#   0  success
#   1  runtime failure (no usable sha256 tool, unreadable file, bad hash)
#   2  usage error
#
# Dependencies: POSIX shell utilities + awk + one of sha256sum / shasum /
# openssl. No jq — this must run before/independently of the gate stack.
# Bash 3.2 compatible (macOS system bash): no associative arrays, no
# mapfile, no ${var^^}.

set -e

# ---------------------------------------------------------------------------
# Usage

usage() {
    cat <<'USAGE'
Usage: workflow-manifest.sh <subcommand> [options]

  generate <source-root>
      Print the workflow-surface manifest for the tree at <source-root>:
      sorted TSV, <path><TAB><class><TAB><sha256>, one row per shipped
      file, paths relative to <source-root>. Deterministic: no header,
      no timestamps, LC_ALL=C sort order.

  classify --target <dir> --source <dir> --old-table <file>
      Print an upgrade plan for the install at <dir> against the plugin
      source at <dir>, using <file> (a frozen manifest from the release
      the target was installed from) to tell stock files from customized
      ones. Sorted TSV, <path><TAB><class><TAB><verdict>, one row per
      source-manifest entry.

      Verdicts: merge | copy-new | skip-current | replace-stock |
                replace-custom | preserve-custom

  -h, --help
      Print this text.

Exit codes: 0 success, 1 runtime failure, 2 usage error.
USAGE
}

usage_error() {
    printf 'workflow-manifest.sh: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

die() {
    printf 'workflow-manifest.sh: %s\n' "$1" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Scratch space. One work dir per invocation, removed on exit. mk_workdir is
# idempotent so both subcommands can call it without leaking a second dir.

WORK_DIR=""

# Invoked indirectly, by the EXIT trap immediately below.
# shellcheck disable=SC2329
cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR" 2>/dev/null || true
    fi
    # Explicit success: an EXIT trap whose last command fails under `set -e`
    # would rewrite the script's exit status.
    return 0
}
trap cleanup EXIT

mk_workdir() {
    if [ -z "$WORK_DIR" ]; then
        WORK_DIR=$(mktemp -d -t workflow-manifest.XXXXXX)
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Hashing. Resolved ONCE per invocation (a `command -v` probe per file would
# be thousands of forks on a tree with node_modules pruned but still large).
# Fallback chain: sha256sum (GNU coreutils) -> shasum -a 256 (macOS/perl) ->
# openssl dgst -sha256. All three are normalised to bare lowercase 64-hex.

HASH_TOOL=""

require_hash_tool() {
    if [ -n "$HASH_TOOL" ]; then
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        HASH_TOOL="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        HASH_TOOL="shasum"
    elif command -v openssl >/dev/null 2>&1; then
        HASH_TOOL="openssl"
    else
        die "no usable sha256 tool on PATH (need sha256sum, shasum, or openssl)"
    fi
    return 0
}

# hash_file <path> -> bare 64-hex sha256 on stdout.
#
# Fails hard rather than emitting a placeholder: a manifest row with a
# plausible-but-wrong hash would make a customized file look stock and get it
# silently overwritten on upgrade. Note that `die` here exits the command
# SUBSTITUTION subshell, not the script (LESSONS.md, 2026-06-12) — callers
# therefore assign plainly (`h=$(hash_file "$f")`) so `set -e` propagates the
# non-zero status, never wrapped in `|| true`.
hash_file() {
    local f="$1"
    local raw=""
    local out=""
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
            printf 'workflow-manifest.sh: hash tool not resolved before hash_file\n' >&2
            exit 1
            ;;
    esac
    if [ "${#out}" -ne 64 ]; then
        printf 'workflow-manifest.sh: sha256 of %s via %s was not 64 chars (got %s)\n' \
            "$f" "$HASH_TOOL" "'$out'" >&2
        exit 1
    fi
    case "$out" in
        *[!0-9a-f]*)
            printf 'workflow-manifest.sh: sha256 of %s via %s is not lowercase hex (got %s)\n' \
                "$f" "$HASH_TOOL" "'$out'" >&2
            exit 1
            ;;
    esac
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Row emitters. All operate on paths RELATIVE to $PWD — generate_rows runs
# inside a subshell already cd'd to the source root, so relativisation is
# structural rather than a prefix-strip (no trailing-slash or symlink-spelling
# edge cases to get wrong).

# emit_row <class> <relative-path>
# A single file that is absent is simply omitted — a v3.5 tree has no
# .claude/model-roles and that is not an error, it is the whole reason we
# freeze a table per release.
emit_row() {
    local class="$1"
    local rel="$2"
    local h
    [ -f "$rel" ] || return 0
    h=$(hash_file "$rel")
    printf '%s\t%s\t%s\n' "$rel" "$class" "$h"
}

# scan_flat <class> <dir> <name-glob>
# One directory level only. `find -maxdepth 1` rather than a shell glob:
# nullglob is a per-shell setting and an unmatched glob would otherwise be
# emitted literally. maxdepth is also what keeps .claude/scripts/tests/ out
# of the .claude/scripts/*.sh surface.
scan_flat() {
    local class="$1"
    local dir="$2"
    local glob="$3"
    local f
    [ -d "$dir" ] || return 0
    while IFS= read -r -d '' f; do
        emit_row "$class" "$f"
    done < <(find "$dir" -maxdepth 1 -type f -name "$glob" -print0 2>/dev/null)
}

# scan_tree <class> <dir> [prune-dir-name...]
# Recursive scan of a wholesale-copied tree. Prunes the named directories at
# any depth and always drops *.log, mirroring install.sh's rsync --exclude
# sets for .claude/mcp (node_modules, .tmp, *.log) and .claude/tests/mutation
# (runs, *.log). Pruning rather than filtering matters: node_modules holds
# ~6800 files that must never be walked, let alone hashed.
scan_tree() {
    local class="$1"
    local dir="$2"
    shift 2
    [ -d "$dir" ] || return 0
    local args=()
    local first=1
    local n
    if [ "$#" -gt 0 ]; then
        args+=( '(' )
        for n in "$@"; do
            if [ "$first" = "1" ]; then
                first=0
            else
                args+=( '-o' )
            fi
            args+=( -name "$n" )
        done
        args+=( ')' -prune -o )
    fi
    args+=( -type f '!' -name '*.log' -print0 )
    local f
    while IFS= read -r -d '' f; do
        emit_row "$class" "$f"
    done < <(find "$dir" "${args[@]}" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# THE SURFACE. Mirrors install.sh's copy loops one-for-one; keep the two in
# sync in the same commit.
#
# DELIBERATELY EXCLUDED:
#   CLAUDE.md              never-touched operator memory — the installer does
#                          not seed it and an upgrade must not consider it.
#   .claude/scripts/tests/ the plugin's own L1 suite is repo-only; install.sh
#                          copies flat .claude/scripts/*.sh only.
#   docs/ (all but two)    the shipped-docs subset is NAMED file by file below,
#                          never scanned. docs/ in an install target is the
#                          OPERATOR's directory; the plugin borrows exactly two
#                          filenames in it. A scan_flat over docs/*.md would
#                          enumerate the repo's own 14 references plus every
#                          dated AgentLint report, and — worse — the uninstall
#                          root-scope walk would then offer to move an
#                          operator's docs out of their own project.
#   .claude/settings.local.json, .claude/.session-start, and every other
#                          per-machine artifact: not copied, not classified.
generate_rows() {
    # --- workflow: plugin-owned product -----------------------------------
    scan_flat workflow ".claude/agents"   '*.md'
    scan_flat workflow ".claude/scripts"  '*.sh'
    scan_flat workflow ".claude/commands" '*.md'
    emit_row  workflow ".claude/hooks/hooks.json"
    emit_row  workflow ".claude/skills/workflow-engine/SKILL.md"
    scan_tree workflow ".claude/mcp" "node_modules" ".tmp"
    scan_tree workflow ".claude/tests/mutation" "runs"
    emit_row  workflow ".worktreeinclude"
    emit_row  workflow ".claude-plugin/plugin.json"
    # The shipped-docs subset (v4.1 / U0.8). Two files, named individually —
    # see the docs/ note above for why this is not a directory scan. Class
    # `workflow`: they are plugin-owned reference material that a release
    # rewrites, not operator content, so an operator edit gets the same
    # replace-custom + "yours is in the backup" treatment every other
    # plugin-owned file gets. Absent files are simply omitted, which is how a
    # pre-U0.8 tag (docs/HOOKS.md yes, docs/CODEX_SETUP.md no) still freezes.
    emit_row  workflow "docs/CODEX_SETUP.md"
    emit_row  workflow "docs/HOOKS.md"

    # --- operator: seeded once, never clobbered ---------------------------
    scan_flat operator ".claude/rubrics" '*.md'
    emit_row  operator ".claude/rubric-config"
    emit_row  operator ".claude/review-config"
    emit_row  operator ".claude/model-ranking"
    emit_row  operator ".claude/model-roles"
    emit_row  operator ".claude/effort-verdict"
    emit_row  operator "LESSONS.md"

    # --- merged: jq key-wise merge, never a copy --------------------------
    emit_row  merged ".claude/settings.json"
    emit_row  merged ".mcp.json"
}

# generate_manifest <source-root> -> sorted TSV on stdout.
# Written to a temp file and sorted separately rather than piped: a pipeline
# would hide a failing left-hand side behind sort's exit status, and a
# silently truncated manifest is exactly the failure mode this artifact
# exists to prevent.
generate_manifest() {
    local root="$1"
    local raw
    mk_workdir
    raw="$WORK_DIR/rows.tsv"
    ( cd "$root" && generate_rows ) > "$raw"
    LC_ALL=C sort "$raw"
}

# ---------------------------------------------------------------------------
# generate

cmd_generate() {
    local root="${1:-}"
    [ -n "$root" ] || usage_error "generate requires <source-root>"
    [ "$#" -le 1 ] || usage_error "generate takes exactly one argument"
    [ -d "$root" ] || usage_error "generate: source root not found: $root"
    require_hash_tool
    generate_manifest "$root"
}

# ---------------------------------------------------------------------------
# classify

cmd_classify() {
    local target=""
    local source=""
    local oldtable=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target)
                [ "$#" -ge 2 ] || usage_error "classify: --target requires a value"
                target="$2"
                shift 2
                ;;
            --source)
                [ "$#" -ge 2 ] || usage_error "classify: --source requires a value"
                source="$2"
                shift 2
                ;;
            --old-table)
                [ "$#" -ge 2 ] || usage_error "classify: --old-table requires a value"
                oldtable="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage_error "classify: unrecognised argument '$1'"
                ;;
        esac
    done

    [ -n "$target" ]   || usage_error "classify: --target is required"
    [ -n "$source" ]   || usage_error "classify: --source is required"
    [ -n "$oldtable" ] || usage_error "classify: --old-table is required"
    [ -d "$target" ]   || usage_error "classify: target root not found: $target"
    [ -d "$source" ]   || usage_error "classify: source root not found: $source"
    [ -f "$oldtable" ] || usage_error "classify: old-table file not found: $oldtable"
    [ -r "$oldtable" ] || usage_error "classify: old-table file not readable: $oldtable"

    require_hash_tool
    mk_workdir

    local src_tsv="$WORK_DIR/source.tsv"
    generate_manifest "$source" > "$src_tsv"

    # Join the source manifest against the frozen old-release table on path.
    # One awk pass instead of a grep per row. "-" marks "this path is not in
    # the old table" — unambiguous next to a 64-hex hash, and it keeps the
    # field non-empty so IFS-tab field splitting below cannot collapse it.
    #
    # The old table is loaded in BEGIN via getline, NOT with the usual
    # two-file `NR == FNR` idiom. NR == FNR is true for EVERY record of the
    # second file when the first file contributed zero records, so an EMPTY
    # old table would make awk `next` past the entire source manifest and
    # classify would exit 0 having printed nothing at all. An installer
    # reading that plan would conclude there was no work to do. An empty or
    # path-poor old table is a legitimate input (an install whose release we
    # cannot identify), so it has to degrade to "nothing is known to be
    # stock", never to "nothing to do".
    local joined="$WORK_DIR/joined.tsv"
    awk -F'\t' -v OFS='\t' -v oldf="$oldtable" '
        BEGIN {
            while ((getline line < oldf) > 0) {
                n = split(line, f, "\t")
                if (n >= 3 && f[1] != "") { old[f[1]] = f[3] }
            }
            close(oldf)
        }
        {
            oldhash = "-"
            if ($1 in old) { oldhash = old[$1] }
            print $1, $2, $3, oldhash
        }
    ' "$src_tsv" > "$joined"

    # Structural self-check on the join: one plan row per source-manifest row,
    # always. This is the guard that turns a future join regression (the
    # NR == FNR trap above was one, caught pre-ship) into a loud failure
    # instead of a silently truncated upgrade plan.
    local src_rows joined_rows
    src_rows=$(wc -l < "$src_tsv" | tr -d ' ')
    joined_rows=$(wc -l < "$joined" | tr -d ' ')
    if [ "$src_rows" != "$joined_rows" ]; then
        die "internal: old-table join produced $joined_rows row(s) for $src_rows source row(s)"
    fi

    # Buffer the plan and print it only after the last row is computed, the
    # same all-or-nothing contract generate_manifest has. Streaming straight
    # to stdout would leave a TRUNCATED plan on a caller's disk if a target
    # file turned out to be unreadable half way through: the exit code says
    # 1, but a consumer doing `classify ... > plan.tsv` and reading the file
    # without checking would act on a plan that silently stops early.
    local plan="$WORK_DIR/plan.tsv"

    local path class srchash oldhash tgt tgthash verdict
    while IFS=$'\t' read -r path class srchash oldhash; do
        [ -n "$path" ] || continue

        # `merged` files are never copied — the installer reconciles them key
        # by key with jq — so no hash comparison can produce a useful verdict.
        if [ "$class" = "merged" ]; then
            printf '%s\t%s\t%s\n' "$path" "$class" "merge"
            continue
        fi

        tgt="$target/$path"
        if [ ! -f "$tgt" ]; then
            printf '%s\t%s\t%s\n' "$path" "$class" "copy-new"
            continue
        fi

        tgthash=$(hash_file "$tgt")
        if [ "$tgthash" = "$srchash" ]; then
            verdict="skip-current"
        elif [ "$oldhash" != "-" ] && [ "$tgthash" = "$oldhash" ]; then
            verdict="replace-stock"
        else
            # Differs from the shipped version AND from the release the target
            # was installed from (or the path is not in the old table at all):
            # the operator changed it, or it arrived from an unknown release.
            verdict="replace-custom"
            # CUSTOM-VERDICT-START (load-bearing; the L1 META-test strips to END)
            if [ "$class" = "operator" ]; then
                verdict="preserve-custom"
            fi
            # CUSTOM-VERDICT-END
        fi
        printf '%s\t%s\t%s\n' "$path" "$class" "$verdict"
    done < "$joined" > "$plan"

    cat "$plan"
}

# ---------------------------------------------------------------------------
# Dispatch

case "${1:-}" in
    generate)
        shift
        cmd_generate "$@"
        ;;
    classify)
        shift
        cmd_classify "$@"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    "")
        usage_error "a subcommand is required"
        ;;
    *)
        usage_error "unknown subcommand '$1'"
        ;;
esac

exit 0

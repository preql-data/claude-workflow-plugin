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
#   governing <source-root>
#       Sorted TSV on stdout, one row per GOVERNING ARTIFACT:
#           <path><TAB><origin>
#       No hashes, no hash tool required. See THE GOVERNING-ARTIFACT QUERY
#       below for what "governing" means and who asks.
#
#   hash-file <path>
#       Bare 64-lowercase-hex sha256 of ONE named file, over its RAW BYTES,
#       on stdout. Refuses (exit 1, naming which) on a missing, unreadable or
#       EMPTY path BEFORE hashing. This is the design-artifact binding's digest
#       (v5 D1); it is not, and must never become, a second change-set
#       canonicalisation — that is impact-report.sh --hash-only.
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

  governing <source-root>
      Print the GOVERNING-ARTIFACT set for the tree at <source-root>:
      sorted TSV, <path><TAB><origin>, paths relative to <source-root>.
      Every shipped-surface path (origin = its manifest class) plus the
      named runtime-contract files the plugin does not ship but whose
      content governs how it behaves (origin = runtime-contract), plus the
      design artifacts under docs/specs/ (origin = design-artifact).
      No hashes, so no sha256 tool is needed.

  hash-file <path>
      Print the sha256 of <path> over its RAW BYTES: bare 64 lowercase hex,
      no filename, no newline-normalisation, so `shasum -a 256 <path>`
      reproduces it by hand. REFUSES before hashing when <path> is missing,
      unreadable or empty — those digest to the sha256 of zero bytes, which
      is valid-looking and constant, and would bind a gate to nothing.

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
#
# MANIFEST_EMIT_HASH=0 drops the third column and, with it, the entire hashing
# dependency: `governing` needs the ENUMERATION, not the digests, and hashing
# ~130 files to answer "is this path plugin-owned?" would put a sha256 tool on
# the Stop hook's critical path for nothing. The hashed branch below is
# untouched by that switch — byte-for-byte the statement that produced every
# frozen table under manifests/ — so `generate` output cannot move with it.
MANIFEST_EMIT_HASH=1
emit_row() {
    local class="$1"
    local rel="$2"
    local h
    [ -f "$rel" ] || return 0
    if [ "$MANIFEST_EMIT_HASH" = "0" ]; then
        printf '%s\t%s\n' "$rel" "$class"
        return 0
    fi
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
    # Skills and vendored reference docs are TREE scans, not named files
    # (v4.1 / U4). Both mirror install.sh's copy_shipped_tree walks exactly —
    # every file, dropping only *.log — so a second skill, a supporting file
    # beside an existing one, or a second vendored document is classified with
    # no edit here. `scan_tree` returns 0 on a missing directory, which is what
    # keeps a pre-U4 tag's frozen table byte-identical: `git ls-tree v3.5.0`
    # carries exactly one file under .claude/skills/ and no .claude/vendor/ at
    # all, so this pair emits the same single row the named emit_row did.
    scan_tree workflow ".claude/skills"
    scan_tree workflow ".claude/vendor"
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

# GOVERNING-ARTIFACT-SURFACE BEGIN (claude-workflow-plugin-s5qf)
#
# THE GOVERNING-ARTIFACT QUERY
# ----------------------------
# WHO ASKS. `verify-before-stop.sh`'s `is_doc_only_path`, and nothing else
# today. F1 — the doc-only fast path — auto-approves a change set with
# `reviewed_by=none` when every path in it is documentation. The classifier
# decides "documentation" from the file's NAME (`*.md`, `*.txt`, a bare
# `LICENSE`), narrowed by an affirmative content veto that catches anything the
# OS will execute (claude-workflow-plugin-bbh). An agent prompt, a rubric and a
# lessons ledger are markdown, carry no exec bit and no `#!`, and so are
# documentation to every check in that function.
#
# THEY ARE NOT DOCUMENTATION. They are executable policy in prose: the grader
# reads `.claude/rubrics/*.md` as its criteria and `LESSONS.md` as criteria by
# reference, the runtime reads `.claude/agents/*.md` as the agent, and
# `.claude/skills/**/SKILL.md` is loaded and followed. `.md` eligibility for
# these is the same category error `LICENSE.sh` was: a NAME asserting a content
# type it does not have. bbh deleted two arms for inferring content type from a
# path's shape; a `docs/specs/` arm, or a `.claude/agents/` arm, would be that
# identical inference wearing a different suffix.
#
# SO THIS ASKS A DIFFERENT QUESTION, and it is one this file already answers:
# IS THIS PATH PART OF THE PLUGIN'S OWN DECLARED SURFACE? That is not an
# inference about the file — it is a lookup in the enumeration install.sh
# copies from and every frozen table under manifests/ is cut from. A path is in
# it because the project SAYS it ships that path, which is exactly the "fact
# about a project's layout" the bbh region header says no shape or content
# check can recover.
#
# WHY THE WHOLE SURFACE AND NOT A "GOVERNING" SUBSET. Because a subset would
# have to be minted here, and a minted list is a new place for the next
# artifact to be missing — the objection that removed the `docs/` arm rather
# than narrowing it. The manifest's own header already states the property that
# makes the whole surface the right answer: workflow-class files are "plugin-
# owned product ... an operator edit to one of them is a local fork, not a
# setting". A local fork of plugin product is a change to the product. The two
# shipped docs (docs/HOOKS.md, docs/CODEX_SETUP.md) are inside for that reason
# and not by accident; docs/HOOKS.md in particular is a contract this repo's
# own specs assert against.
#
# WHAT IT COSTS, measured rather than assumed, because that is the half of a
# fast-path change that is usually skipped. Over this repo's whole history at
# b8f0095 — 142 non-merge commits, classifier extracted from the shipped hook
# and driven per path, manifest regenerated from each commit's own tree via
# `git archive`:
#     7 commits were doc-only, i.e. F1-eligible;
#     1 of those 7 also touched a governing artifact (ea6ae385, docs/HOOKS.md
#       alone) and would now need a QA round.
# Counted the other way round, from churn: 60 commits touched a veto-reachable
# governing artifact, and 59 of them carried a reviewable path anyway, so F1
# was never available to them. Governing artifacts change CONSTANTLY here
# (LESSONS.md 37, docs/HOOKS.md 23, .claude/agents/qa.md 22) and essentially
# never alone. The availability cost is 1 commit in 142, not the broad loss the
# churn figures suggest at a glance.
#
# WHAT IT DOES NOT REACH, stated because a fast path that auto-approves is
# allowed to be narrow and is not allowed to be wrong:
#   * A DELETION. The enumeration is built from files that exist, so deleting
#     `.claude/agents/qa.md` alone is still doc-only. This is the same
#     asymmetry the content veto documents and defends — an absent file is not
#     evidence — and closing it would need a path-SHAPE rule for "would have
#     been a row", i.e. the inference bbh removed. Deleting a plugin-owned
#     artifact correctly also moves .claude-plugin/plugin.json or a frozen
#     table, neither of which is doc-named, so a correct deletion is not
#     doc-only anyway.
#   (`docs/specs/<task-id>.md`, the v5 design record, WAS listed here as the
#   second unreachable case. claude-workflow-plugin-fkm.3 / D1 closed it — see
#   the design-artifact row in runtime_contract_rows below, which is why the
#   route this note recommended, a reader for a marker the designer writes, was
#   NOT the one taken.)
#
# runtime_contract_rows — files the plugin does NOT ship, whose content
# nonetheless governs how it behaves. `generate_rows` must never call this and
# no install path may read it: these are not part of the shipped surface, they
# have no class, no upgrade verdict and no uninstall row. CLAUDE.md is here
# because Claude Code auto-loads it into every agent's context — a product fact
# about the runtime, the same kind of fact as `.claude/settings.json` being the
# settings file, and not an inference from `.md` or from sitting at the root.
# Naming an individual file is house-consistent: the surface above names
# docs/HOOKS.md, docs/CODEX_SETUP.md and .worktreeinclude one by one.
#
# THE DESIGN-ARTIFACT ROW IS A DECLARED DIRECTORY, NOT A NAMED FILE
# (claude-workflow-plugin-fkm.3 / D1), and that difference is stated rather than
# glossed because it is the one thing here a reviewer could reasonably push back
# on. CLAUDE.md is one path this file spells out. `docs/specs/*.md` cannot be:
# the artifact is named for the task it designs, so the set is only knowable at
# scan time. Every OTHER property of the mechanism is unchanged — still inside
# the function `generate_rows` never calls, still no class, no upgrade verdict,
# no uninstall row, no install copy.
#
# IT IS STILL A DECLARATION AND NOT A PATH INFERENCE, which is the distinction
# the operator's ruling on claude-workflow-plugin-bbh drew. The removed `docs/`
# arm asked "does this path LOOK like documentation?" and answered from its
# shape, which is why `docs/deploy.sh` auto-approved. This asks nothing about
# the path: `docs/specs` is the directory THIS PROJECT'S WORKFLOW WRITES ITS
# DESIGN ARTIFACT INTO — the same kind of product fact as CLAUDE.md being
# auto-loaded — and the row exists because the project says so, not because the
# name ends in `.md` or sits under `docs/`. An operator's ordinary
# `docs/architecture.md` is untouched, and so is every other file in `docs/`;
# the directory named here is one the plugin created for itself.
#
# WHY NOT THE ALTERNATIVE THIS FILE PREVIOUSLY POINTED AT. The note above
# suggested D1 disqualify the artifact "from the design RECORD that names the
# file, or from a machine-readable marker the designer writes INTO it". Both are
# reachable now that D1 writes both, and the record route was rejected for a
# specific reason: is_doc_only_path runs per PATH inside a Stop hook with no
# task context and no bd, so a record lookup there would be a bd call per
# candidate path — and it would answer "no" for the artifact of a design that
# has not been recorded YET, which is exactly the window (a designer-only change
# set, before any record exists) the veto has to cover. The marker route reads
# file CONTENT, which the DOC-CONTENT-VETO already does — but it would make the
# veto depend on the designer having written a well-formed block, i.e. an agent
# could opt its own artifact back into the fast path by malforming it. A
# declaration is decided by the project, not by the document under review.
#
# ORIGIN IS `design-artifact`, NOT `runtime-contract`. Same function, different
# token, so the Stop hook's log line says which declaration vetoed the path, and
# so "the ONLY runtime-contract row is CLAUDE.md" stays an assertable invariant
# about NAMED files while the directory declaration grows beside it.
#
# THE AVAILABILITY COST, measured the way s5qf measured its own: every design
# artifact loses the F1 fast path when it changes alone. That is the entire
# point rather than a side effect — a designer-only change set is precisely the
# one that must not auto-approve with reviewed_by=none, because the document it
# contains is what the whole release exists to review. Over this repo's history
# the cost is exactly zero commits, because `docs/specs/` does not exist before
# this release; over an installed project it is one QA round per design
# revision, which is the review the phase mandates anyway.
DESIGN_SPEC_SUBDIR="docs/specs"

# scan_declared_dir <class> <dir> <name-glob>
# THE DECLARATION SCAN. It differs from scan_flat above in exactly one way: it
# enumerates directory ENTRIES rather than regular files, so a SYMLINK matching
# the glob is declared too.
#
# WHY (claude-workflow-plugin-fkm.3, QA round 2 finding R2-F2). `find -maxdepth 1
# -type f` EXCLUDES symlinks, and that was measured against the shipped scan: with
# docs/specs/<tid>.md a symlink to ../../outside/design.md, `governing` emitted NO
# row for it while a regular file in the same directory emitted one. The F1
# doc-only fast path this declaration exists to close therefore reopened for the
# design artifact itself — a change set of exactly that path would auto-approve
# with reviewed_by=none, which is the one outcome the declaration was added to
# prevent. The declaration is about A PATH THIS PROJECT'S WORKFLOW WRITES ITS
# DESIGN INTO; what kind of directory entry sits at that path does not change
# whose document it is, and the fail-closed answer is to declare it.
#
# scan_flat IS DELIBERATELY NOT CHANGED TO MATCH. It builds the SHIPPED SURFACE,
# whose output is frozen per release under manifests/ and compared byte-for-byte
# by the reproducibility assert, and install.sh copies files rather than links —
# so widening it would move frozen rows for a case no install path produces. The
# spec asserts that boundary from both sides: a symlink in the declared directory
# IS governing, a symlink in .claude/agents/ leaves `generate` byte-unchanged.
#
# A DANGLING link is declared too. It is a path the project declared, and "the
# target is missing" is not a reason to hand the Stop gate a fast path over it —
# an absent file is not evidence, the same asymmetry the region header states
# above. `emit_row` would drop it (its `[ -f ]` guard follows the link), so the
# non-regular branch emits the enumeration row directly. That branch carries no
# digest column, which is exactly right for the only caller — generate_governing
# runs with MANIFEST_EMIT_HASH=0 and cmd_governing's header states the
# enumeration carries no digests — and `generate` never reaches this function at
# all. If a FUTURE caller ever turns hashing on, that branch would emit a
# two-field row into a three-field table and the consumer's field-2 origin read
# would silently start reading a hash; so it DIES there instead. A sentinel in
# the hash column is the alternative and it is the one this file has already
# ruled out twice (see hash_file, and the hash-file header below): a constant
# compares equal to every other artifact and to itself after any edit.
#
# NOT A DELETION FIX, and it does not make one harder: the enumeration is still
# built from entries that EXIST, so removing a declared artifact is still
# invisible to it (claude-workflow-plugin-mdnc, which is pre-existing for every
# declared path — CLAUDE.md, the agent prompts, the rubrics). This strictly ADDS
# rows; nothing that was declared before stops being declared.
#
# THE DECLARED DIRECTORY MAY ITSELF BE A SYMLINK, and `-H` is what makes that
# case work (fkm.3 QA round 4, R4-F3). `find` does not descend a final
# directory-symlink operand without -H or -L — measured identical on BSD find
# and GNU findutils 4.10.0 — while the `[ -d "$dir" ]` guard above it DOES
# follow. So the guard passed and the scan came back silently EMPTY: `ls
# docs/specs/` listed the artifact and `governing` emitted no row for it, which
# is R2-F2's harm reached by a second route. `-H` is the narrow spelling on
# purpose: it follows COMMAND-LINE operands only, so entries INSIDE the
# directory are still reported as themselves and a symlinked artifact is still
# declared by the `-type l` arm rather than by its target's type.
#
# THE ENUMERATION'S STATUS IS THE DECLARATION'S STATUS (R4-F2). The scan used to
# run inside a process substitution with `2>/dev/null`, which discarded find's
# diagnostic AND lost its exit status — so a directory that is searchable but
# not listable (mode 0311) produced zero rows at rc 0 while the artifact stayed
# stat-able, readable and hashable by name. That FALSIFIES AN INVARIANT THE
# CONSUMER DOCUMENTS: verify-before-stop.sh's load_governing_set captures this
# query's rc precisely because "an empty set from a FAILED run is not
# [legitimate]" — the outer layer distinguishes the two carefully and the inner
# layer handed it a failure wearing an empty set's clothes. So find writes to a
# file whose status can be read, and a failed enumeration DIES.
#
# WHAT THE CONSUMER DOES WITH THE FAILURE is unchanged and is not this
# function's call: load_governing_set logs a sync error and classifies as it did
# before the declaration existed. That is s5qf's deliberate fail-open-with-a-log
# on an unanswerable query. The defect fixed here is that the query was ANSWERING
# — wrongly, and silently — rather than failing.
scan_declared_dir() {
    local class="$1"
    local dir="$2"
    local glob="$3"
    local f listing find_err find_rc=0
    [ -d "$dir" ] || return 0
    # One fixed name: the listing is fully consumed before the next call, and
    # generate_governing (the only caller, through governing_rows) has already
    # created WORK_DIR, so this is a no-op that keeps the function honest if a
    # second caller ever appears.
    mk_workdir
    listing="$WORK_DIR/declared-scan.z"
    find_err=$( { find -H "$dir" -maxdepth 1 \( -type f -o -type l \) -name "$glob" -print0 >"$listing"; } 2>&1 ) || find_rc=$?
    if [ "$find_rc" -ne 0 ]; then
        die "scan_declared_dir: could not ENUMERATE the declared directory '$dir' (find exited $find_rc; find said: ${find_err:-<no diagnostic>}). The declaration is a VETO, so an empty answer and a failed one must not look alike: the consumer treats an empty set as 'nothing is declared' and fast-paths, and a failed query as 'unavailable' and logs it. Refusing here is what keeps that distinction real."
    fi
    while IFS= read -r -d '' f; do
        if [ -f "$f" ]; then
            emit_row "$class" "$f"
        elif [ "$MANIFEST_EMIT_HASH" = "0" ]; then
            printf '%s\t%s\n' "$f" "$class"
        else
            die "scan_declared_dir: $f is declared but has no hashable content (a dangling link), and hashing is on. The declaration is an ENUMERATION — generate_governing sets MANIFEST_EMIT_HASH=0 — so there is no digest for a third column, and a sentinel there would be a constant that compares equal to every other row and to itself after any edit."
        fi
    done < "$listing"
}

runtime_contract_rows() {
    emit_row runtime-contract "CLAUDE.md"
    scan_declared_dir design-artifact "$DESIGN_SPEC_SUBDIR" '*.md'
}

governing_rows() {
    generate_rows
    runtime_contract_rows
}

# generate_governing <source-root> -> sorted TSV on stdout.
# Same all-or-nothing discipline as generate_manifest: buffered to a file and
# sorted separately, so a failing left-hand side can never hide behind sort's
# exit status and hand a caller a silently truncated set. For THIS caller a
# truncated set is a missed veto, i.e. a release nobody reviewed.
generate_governing() {
    local root="$1"
    local raw
    mk_workdir
    raw="$WORK_DIR/governing.tsv"
    ( cd "$root" && MANIFEST_EMIT_HASH=0 governing_rows ) > "$raw"
    LC_ALL=C sort "$raw"
}
# GOVERNING-ARTIFACT-SURFACE END (claude-workflow-plugin-s5qf)

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
# governing
#
# No require_hash_tool: the enumeration carries no digests, so this answers on
# a box with neither sha256sum, shasum nor openssl. That matters because the
# caller is a Stop hook, and a gate that silently stops vetoing when a hashing
# tool is missing would be the worst kind of failure — invisible and in the
# releasing direction.

cmd_governing() {
    local root="${1:-}"
    [ -n "$root" ] || usage_error "governing requires <source-root>"
    [ "$#" -le 1 ] || usage_error "governing takes exactly one argument"
    [ -d "$root" ] || usage_error "governing: source root not found: $root"
    generate_governing "$root"
}

# ---------------------------------------------------------------------------
# classify

# DESIGN-ARTIFACT-HASH BEGIN (claude-workflow-plugin-fkm.3 / D1)
#
# hash-file <path> — the ONE content digest of a NAMED BLOB, as opposed to
# impact-report.sh --hash-only, which is the ONE canonicalisation of a CHANGE
# SET. Two different questions; keeping them in two places is deliberate.
#
# WHY IT LIVES HERE and not on impact-report.sh, where the v5 plan sketched it
# as `--hash-file`. hash_file() above already has exactly the contract a binding
# needs and impact-report.sh's hasher has the inverse of it:
#
#   * NO SENTINEL. hash_file dies when it cannot produce 64 lowercase hex.
#     impact-report.sh's sha256_stdin prints the literal `sha256-unavailable` on
#     a host with no sha tool — a CONSTANT, so every artifact would hash equal to
#     every other one and equal to itself after any edit. This repo has ruled
#     that sentinel a defect twice (qa-gate.sh's CHANGE_SET_HASH_UNAVAILABLE
#     note, verify-before-stop.sh's "THIS COPY TOOK HALF THE CURE" / _vl_is_hash)
#     and both times the cure was a SHAPE TEST, NEVER AN IDENTITY TEST. A gate
#     that binds to a design document must not inherit an unfailable comparison.
#   * RAW BYTES. The plan's spelling piped the file through
#     `sed -e 's/\r$//' -e 's/[[:space:]]*$//'` first. Measured on this repo's
#     platform: that collapses a Markdown HARD LINE BREAK (two trailing spaces)
#     into no break — `line one  \nline two` and `line one\nline two` both hash
#     to e9024f1a…, while their raw digests differ (87f1d7bd… vs e9024f1a…). The
#     artifact IS Markdown, so the normalisation makes a real content edit
#     invisible to the hash it exists to detect — the exact inverse of the goal.
#     `s/\r$//` is additionally redundant: POSIX [[:space:]] includes CR, and
#     both spellings were measured byte-identical. Raw bytes also mean a reviewer
#     reproduces any recorded binding with `shasum -a 256 <file>` by hand, which
#     a sed pipeline does not allow.
#
#     WHAT RAW BYTES GIVE UP, said here and not only in the spec that drives it:
#     LINE-ENDING INSENSITIVITY, which is the one thing `s/\r$//` bought and is
#     now unserved. A CRLF checkout of the same artifact (git
#     `core.autocrlf=true` on Windows, or an editor that rewrites endings on
#     save) digests differently from the LF one although the Markdown renders
#     identically, so a design recorded on one checkout reads as CHANGED on the
#     other. The cost is bounded and LOUD rather than silent: approve's ladder
#     withholds the token and names both hashes ("the design artifact has
#     CHANGED since it was recorded"), and the designer re-records. The trade is
#     deliberate — a hash blind to a Markdown hard line break is wrong in the
#     RELEASING direction, while one that sees a line-ending change is
#     inconvenient in the REFUSING direction.
#
# THE THREE REFUSALS FIRE BEFORE ANY HASHING, and that ordering is the whole
# point of the subcommand rather than a nicety. A missing, unreadable or EMPTY
# file digests to e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
# — the sha256 of zero bytes, which impact-report.test.sh pins as the EMPTY
# CHANGE SET constant. It is 64 valid hex, it passes any shape check, and it is
# stable across calls, so a binding taken over an absent artifact would compare
# EQUAL to itself forever and the meta-test "strip the hash and the binding must
# fail" would pass vacuously. hash_file already dies on missing/unreadable (the
# digest comes back empty and fails the 64-char check); EMPTY is the one that
# gets through, so it is refused explicitly and by name.
#
# Exit codes follow this file's contract: 0 with the digest on stdout, 1 for a
# runtime refusal (naming which), 2 for usage.
cmd_hash_file() {
    local path="${1:-}"
    [ -n "$path" ] || usage_error "hash-file requires <path>"
    [ "$#" -le 1 ] || usage_error "hash-file takes exactly one argument"
    if [ ! -f "$path" ]; then
        die "hash-file: no such file: $path (refusing before hashing — an absent path digests to the sha256 of zero bytes, which is valid-looking, constant, and would bind an approval to nothing)"
    fi
    if [ ! -r "$path" ]; then
        die "hash-file: not readable: $path (refusing before hashing — an unreadable path digests to the sha256 of zero bytes, which is valid-looking, constant, and would bind an approval to nothing)"
    fi
    if [ ! -s "$path" ]; then
        die "hash-file: file is empty: $path (refusing before hashing — zero bytes digest to e3b0c442…, the same constant the empty change set produces, so the binding would be indistinguishable from no artifact at all)"
    fi
    require_hash_tool
    hash_file "$path"
}
# DESIGN-ARTIFACT-HASH END (claude-workflow-plugin-fkm.3 / D1)

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
    governing)
        shift
        cmd_governing "$@"
        ;;
    hash-file)
        shift
        cmd_hash_file "$@"
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

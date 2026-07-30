#!/bin/bash
# installer-manifest-parity.sh - L2 component spec for FRESH-install packaging
# parity and manifest-driven uninstall (v4.1 Phase U0 / claude-workflow-plugin-56r,
# absorbing the bzy packaging-parity task).
#
# WHAT THIS PROVES
# ----------------
# The plugin shipped two releases whose installer silently omitted
# .claude/agents/grader.md while every test stayed green (LESSONS.md,
# 2026-06-12). Glob-copy fixed that instance. This spec removes the CLASS, in
# both directions, for a FRESH install:
#
#   manifest -> target   every row of `workflow-manifest.sh generate` names a
#                        file that exists in the installed tree AND is
#                        byte-identical to the source. A shipped file the copy
#                        loops forget fails here.
#   target -> manifest   in the wholly-plugin-owned directories, every file the
#                        installer PUT there appears in the manifest. A rogue
#                        shipped file, or a copy loop that outgrows the
#                        generator's surface rules, fails here. Without this
#                        direction the manifest could drift into a subset of
#                        what is actually installed and still pass.
#
# installer-v3-upgrade.sh covers the same ground for the v3.5 -> v4 UPGRADE, and
# only for the workflow class. This spec is the fresh-install half, all classes.
#
# WHY NO CLASS IS EXEMPT (the exemption decision, from observed behaviour)
# -----------------------------------------------------------------------
# `merged`-class files (.claude/settings.json, .mcp.json) are the ones an
# upgrade reconciles with jq rather than copying, so the obvious expectation is
# that they cannot be hash-asserted. On a FRESH install they can, and are:
# install.sh routes both through a plain copy unless UPDATE_MODE is on AND the
# file already exists (the .mcp.json merge is gated on
# `[ "$UPDATE_MODE" = true ] && [ -f "$MCP_FILE" ]`; the settings merge on the
# same pair). A fresh target has neither, so both land verbatim — verified by
# running the installer, not by reading it. Asserting them is therefore free
# coverage, and it pins that a future change cannot start rewriting them on the
# fresh path without saying so here.
#
# CLAUDE.md is a different thing entirely: it is a heredoc template written only
# when the file is absent, deliberately NOT part of the shipped surface (see
# workflow-manifest.sh's DELIBERATELY EXCLUDED block), and never upgraded. It
# has no manifest row, so nothing here asserts on it except the uninstall legs,
# where it keeps its own template heuristic.
#
# THE TWO rsync'd TREES ARE NOT IN THE NO-EXTRAS SCAN. .claude/mcp/ and
# .claude/tests/mutation/ are copied wholesale by rsync with an --exclude set,
# and the generator mirrors those excludes with -prune rules. Re-encoding that
# exclude set in this checker would make the target -> manifest direction a copy
# of the code under test, so those trees are covered by the manifest -> target
# direction only.
#
# DELIBERATE DEVIATION: NO bd_required_or_skip / NO mk_fixture
# ------------------------------------------------------------
# Same reasoning as installer-v3-upgrade.sh: `bd_required_or_skip` exits 0 with
# a SKIPPED line when the real Beads CLI is absent, and CI sets BD_SHIM_ONLY=1
# because there is no public bd installer to curl — so this spec would never
# run in CI, which is the one place packaging parity most needs a guard.
# install.sh asks bd for four things (`--version`, `init`, `hooks install`,
# `doctor`) and reads only the version string and a case-insensitive 'error'
# grep of doctor's output, so a stub is a complete stand-in. mk_fixture is
# skipped for the same reason (it wraps the REAL bd); the fixture cleanup array
# from lib/fixture.sh is still used for teardown.
#
# fake-bd does NOT create .beads/, so the uninstall legs seed a marker file
# there themselves — a real install has that directory and it is one of the
# three the uninstaller moves.
#
# SECTIONS
#   1. Fresh install        — the real installer, --mode=1, into an empty
#                             sibling tempdir.
#   2. Parity + guards      — every manifest row present and hash-equal, plus
#                             vacuity guards on the manifest itself.
#      2b META-TEST         — truncate one row's hash in a COPY of the manifest;
#                             the same checker must fail on exactly that row.
#   3. No extras            — the six wholly-plugin-owned scopes.
#      3b META-TEST         — plant .claude/agents/rogue.md; the same checker
#                             must flag it, and stop flagging once it is gone.
#   4. install-manifest     — written, header names the source version, body
#                             byte-equals the generated TSV.
#   5. Uninstall leg A      — with a usable manifest: the three directories AND
#                             the three unmodified root files reach the trash.
#   6. Uninstall leg B      — an operator-modified root file is left in place
#                             with a note; the unmodified ones still go.
#   7. Uninstall leg C      — manifest DELETED: exact pre-v4.1 behaviour, root
#                             files left behind. This pins back-compat.
#   8. Uninstall leg D      — manifest MALFORMED (foreign header): the same
#                             legacy behaviour, via the other failure arm.
#   9. Synthetic edge cases — the three guards on the destructive path that a
#                             real install cannot produce: a hash-MATCHING
#                             path-traversal row, a hash-MATCHING row under a
#                             SYMLINKED parent (claude-workflow-plugin-wn4), and
#                             --restore-backup with only a migration snapshot to
#                             restore from. Built by hand (a .claude/ directory
#                             and a manifest is all uninstall.sh needs), so they
#                             cost no install.
#      9c META-TEST         — the containment block is deleted from a COPY of
#                             uninstall.sh and the symlinked-parent row moves the
#                             outside file again: wn4's defect, mechanically.
#
# Runtime is dominated by four installs (~1.5s each: a ~10 MB copy plus ~250
# hashes) and eight uninstalls. No network, no LLM calls.

set -u

# INSTALLER FLAGS FOR THE L2 TIER (v4.1 / C0b) -------------------------------
# install.sh now does two things after the copy loops that this spec has no
# business paying for:
#   1. `npm ci` per MCP server IN THE TARGET. That needs the npm registry, so
#      leaving it on would make assertions about FILE COPYING fail on an
#      offline machine — a network dependency in the component tier.
#   2. workflow-doctor.sh, exiting 3 ("installed, verification FAILED") when a
#      functional check does not pass. This spec's fixtures are not built to
#      satisfy eleven functional checks, and every `install.sh exits 0`
#      assertion here would start reporting a fixture gap as an installer bug.
# Both are covered for real by `make install-test`, which installs into a
# tempdir and requires a fully green doctor — that is the surface that proves
# dependency provisioning works, and it is now expected to be GREEN.
# Exported once so every installer invocation in this file inherits them
# without a per-call-site flag; the v3.5-era installer some of these specs also
# run ignores unknown environment variables.
export CWP_SKIP_MCP_DEPS=1
export CWP_SKIP_VERIFY=1

PLUGIN_ROOT=$(plugin_root)
MANIFEST_TOOL="$PLUGIN_ROOT/.claude/scripts/workflow-manifest.sh"

WORK=$(mktemp -d -t cwp-manifest-parity.XXXXXX)
__COMPONENT_FIXTURES_TO_CLEAN+=("$WORK")

# The root-level file each uninstall leg reasons about, and the sentinel that
# makes it "operator-modified". Seeded verbatim and asserted verbatim from these
# literals so the two can never drift.
LESSON_SENTINEL="OPERATOR-SENTINEL-LESSONS-LEDGER"
ROGUE_AGENT=".claude/agents/rogue.md"

# --- fake bd ----------------------------------------------------------------
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/bd" <<'FAKE_BD'
#!/bin/bash
# fake-bd — the entire `bd` surface install.sh touches. Deliberate: this spec
# must run in CI where the real Beads CLI is unavailable (see spec header).
# `doctor` output must never contain the string 'error' — install.sh greps for
# it case-insensitively and would print a spurious warning.
case "${1:-}" in
    --version|-v|version)
        printf 'bd 0.99.0 (fake-bd for installer specs)\n'
        ;;
    init)
        printf 'fake-bd: initialized Beads workspace\n'
        ;;
    hooks)
        printf 'fake-bd: git hooks installed\n'
        ;;
    doctor)
        printf 'fake-bd: all checks passed\n'
        ;;
    *)
        printf 'fake-bd: ok (%s)\n' "${1:-}"
        ;;
esac
exit 0
FAKE_BD
chmod +x "$FAKE_BIN/bd"
export PATH="$FAKE_BIN:$PATH"

# --- helpers ----------------------------------------------------------------

# yesno <command...> — "yes" when the command succeeds, "no" when it does not.
# The wrapped command's own output is discarded, and that is load-bearing: this
# is called inside $( ), so a command that PRINTS as well as returning a status
# would otherwise prepend its stdout to the yes/no.
yesno() {
    if "$@" >/dev/null 2>&1; then printf 'yes'; else printf 'no'; fi
}

# hash_of <file> — bare lowercase 64-hex sha256, or "" when it cannot be
# computed. Resolved per call (a few hundred calls total; not worth caching in a
# test) and deliberately INDEPENDENT of workflow-manifest.sh: the target side of
# a parity check must not be hashed by the same code that produced the manifest,
# or a bug in that code would agree with itself.
hash_of() {
    local f="$1"
    local raw=""
    [ -f "$f" ] || return 0
    if command -v sha256sum >/dev/null 2>&1; then
        raw=$(sha256sum "$f" 2>/dev/null) || raw=""
        printf '%s' "${raw%% *}"
    elif command -v shasum >/dev/null 2>&1; then
        raw=$(shasum -a 256 "$f" 2>/dev/null) || raw=""
        printf '%s' "${raw%% *}"
    elif command -v openssl >/dev/null 2>&1; then
        raw=$(openssl dgst -sha256 "$f" 2>/dev/null) || raw=""
        printf '%s' "${raw##* }"
    fi
    return 0
}

# fresh_install <dir> <logfile> — git-init <dir>, then the real installer with
# --mode=1. git init comes FIRST because install.sh's "Initialize git
# repository?" prompt falls through to /dev/tty when a controlling terminal is
# openable, which would hang a developer's suite while passing in CI. --mode=1
# is inert on an empty target (the mode block is gated on an existing .claude/);
# it is passed for the same reason installer-mcp-config.sh passes it — so the
# invocation says out loud that no interactive branch is wanted.
fresh_install() {
    local dir="$1"
    local log="$2"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        git init -q >/dev/null 2>&1 || true
        git -c user.email=test@example.com -c user.name=test \
            commit --allow-empty -q -m "parity baseline" >/dev/null 2>&1 || true
    )
    bash "$PLUGIN_ROOT/install.sh" --mode=1 "$dir" </dev/null >"$log" 2>&1
}

# seed_beads <dir> — the .beads/ directory a real `bd init` would have made,
# with a marker inside. The marker is what proves the uninstaller MOVED the
# directory rather than some later step recreating an empty one.
seed_beads() {
    mkdir -p "$1/.beads"
    printf 'beads marker (must reach the trash)\n' > "$1/.beads/marker.txt"
}

# manifest_has_path <manifest> <path> — 0 when the manifest carries a row for
# that exact path. awk field-1 EQUALITY, not grep: shipped paths are full of
# regex metacharacters, and awk exits 0 when nothing matched so this needs no
# `|| true`.
manifest_has_path() {
    awk -F'\t' -v p="$2" '
        BEGIN { found = 0 }
        $1 == p { found = 1; exit }
        END { exit (found ? 0 : 1) }
    ' "$1"
}

# CHECKER (shared with the 2b META): every row of <manifest> must name a file
# that EXISTS under <target> and whose sha256 equals the row's. Prints one line
# per violation and nothing at all when the target satisfies the manifest.
#
# A row whose hash field is empty or short is a VIOLATION, never a skip — the 2b
# META truncates exactly such a row, and a checker that skipped it would report
# parity on a manifest it never actually compared.
parity_violations() {
    local manifest="$1"
    local target="$2"
    local mpath mclass mhash actual
    while IFS=$'\t' read -r mpath mclass mhash; do
        [ -n "$mpath" ] || continue
        # mclass is read only to consume field 2; the class does not change the
        # assertion (see the header's exemption note).
        : "$mclass"
        if [ ! -f "$target/$mpath" ]; then
            printf '%s (absent)\n' "$mpath"
            continue
        fi
        actual=$(hash_of "$target/$mpath")
        if [ "$actual" != "$mhash" ]; then
            printf '%s (hash differs)\n' "$mpath"
        fi
    done < "$manifest"
}

# THE SCOPE LIST — declared ONCE (v4.1 / U4).
#
# Entries are "<dir>:<maxdepth>". .claude/scripts is depth 1 on purpose: that is
# what keeps the repo-only .claude/scripts/tests/ tier out of the scan, exactly
# as the generator's `find -maxdepth 1` does. Every scope here is one the
# installer owns END TO END — it writes every file in it and the operator is
# expected to write none — which is what makes "not in the manifest" a defect
# rather than a customization.
#
# HOISTED because it was previously hand-copied into extra_files AND
# files_in_scopes. Those two are a checker and its own vacuity guard, so two
# copies could disagree: adding a scope to the checker and not to the counter
# leaves the guard under-counting, which is precisely the direction that
# silently WEAKENS the guard rather than failing it. One array, one truth.
#
# .claude/skills is scoped to the tree (not to `workflow-engine`) and
# .claude/vendor is new, matching workflow-manifest.sh's `scan_tree` pair and
# install.sh's `copy_shipped_tree` walks. All three must move together.
PARITY_SCOPES=(
    ".claude/agents:1"
    ".claude/scripts:1"
    ".claude/hooks:1"
    ".claude/commands:1"
    ".claude/rubrics:1"
    ".claude/skills:9"
    ".claude/vendor:9"
)

# CHECKER (shared with the 3b META): every file the target carries in a
# wholly-plugin-owned directory must appear in <manifest>. Prints one line per
# file that does not.
extra_files() {
    local manifest="$1"
    local target="$2"
    local scope dir depth rel
    for scope in "${PARITY_SCOPES[@]}"; do
        dir="${scope%:*}"
        depth="${scope##*:}"
        [ -d "$target/$dir" ] || continue
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            if ! manifest_has_path "$manifest" "$rel"; then
                printf '%s (not in the manifest)\n' "$rel"
            fi
        done < <(cd "$target" && find "$dir" -maxdepth "$depth" -type f 2>/dev/null | LC_ALL=C sort)
    done
}

# files_in_scopes <target> — how many files the scopes hold in total. A vacuity
# guard for extra_files: an empty scan trivially reports no extras. Reads the
# SAME array the checker reads, so the guard cannot drift out from under it.
files_in_scopes() {
    local target="$1"
    local scope dir depth total=0 n
    for scope in "${PARITY_SCOPES[@]}"; do
        dir="${scope%:*}"
        depth="${scope##*:}"
        [ -d "$target/$dir" ] || continue
        n=$(cd "$target" && find "$dir" -maxdepth "$depth" -type f 2>/dev/null | grep -c . | tr -d ' \n')
        total=$((total + n))
    done
    printf '%d' "$total"
}

# uninstall_of <target> <logfile> — the real uninstaller, confirmation answered
# from a pipe. `read -p ... -n 1` takes the single 'y'; the exit status is the
# uninstaller's because it is last in the pipeline.
uninstall_of() {
    printf 'y\n' | bash "$PLUGIN_ROOT/uninstall.sh" "$1" >"$2" 2>&1
}

# trash_dir_of <target> — the (first) .claude-uninstall-trash-* directory, or "".
trash_dir_of() {
    find "$1" -maxdepth 1 -type d -name '.claude-uninstall-trash-*' 2>/dev/null \
        | LC_ALL=C sort | head -1
}

# trash_count_of <target> — how many trash directories exist.
trash_count_of() {
    find "$1" -maxdepth 1 -type d -name '.claude-uninstall-trash-*' 2>/dev/null \
        | grep -c . | tr -d ' \n'
}

# ===========================================================================
# Section 1: the fresh install under test
# ===========================================================================
T="$WORK/target"
INSTALL_LOG="$WORK/install.log"
INSTALL_RC=0
fresh_install "$T" "$INSTALL_LOG" || INSTALL_RC=$?
if [ "$INSTALL_RC" -ne 0 ]; then
    printf '  diagnostic: install.sh exited %s; tail of log:\n' "$INSTALL_RC"
    tail -20 "$INSTALL_LOG" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-manifest-parity 1: install.sh --mode=1 exits 0 on an empty target" \
    "0" "$INSTALL_RC"
assert_eq "installer-manifest-parity 1: the installed tree carries .claude-plugin/plugin.json" \
    "yes" "$(yesno test -f "$T/.claude-plugin/plugin.json")"

SOURCE_VERSION=$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo "")
assert_eq "installer-manifest-parity 1: the source declares a readable version" \
    "yes" "$(yesno test -n "$SOURCE_VERSION")"

# ===========================================================================
# Section 2: manifest -> target parity
# ===========================================================================
MANIFEST="$WORK/source-manifest.tsv"
GEN_RC=0
bash "$MANIFEST_TOOL" generate "$PLUGIN_ROOT" > "$MANIFEST" 2>"$WORK/generate.err" || GEN_RC=$?
assert_eq "installer-manifest-parity 2: generate on the plugin source exits 0" "0" "$GEN_RC"

# Vacuity guards. Every assertion below is a loop over this file, so an empty or
# truncated manifest would report perfect parity over nothing at all.
MANIFEST_ROWS=$(grep -c . "$MANIFEST" | tr -d ' \n')
assert_eq "installer-manifest-parity 2: the manifest lists a plausible number of files (>100)" \
    "yes" "$(yesno test "${MANIFEST_ROWS:-0}" -gt 100)"
for class in workflow operator merged; do
    CLASS_ROWS=$(awk -F'\t' -v c="$class" '$2 == c' "$MANIFEST" | grep -c . | tr -d ' \n')
    assert_eq "installer-manifest-parity 2: the manifest carries $class-class rows" \
        "yes" "$(yesno test "${CLASS_ROWS:-0}" -ge 1)"
done
# The merged class is named exactly, because the header's "no class is exempt"
# decision is a claim about THESE two files. A third merged-class file arriving
# without a look at the fresh-install path fails here.
MERGED_PATHS=$(awk -F'\t' '$2 == "merged" { print $1 }' "$MANIFEST" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')
assert_eq "installer-manifest-parity 2: the merged class is exactly settings.json + .mcp.json" \
    ".claude/settings.json .mcp.json" "$MERGED_PATHS"

PARITY_BAD=$(parity_violations "$MANIFEST" "$T")
if [ -n "$PARITY_BAD" ]; then
    printf '  diagnostic: parity violations (first 10):\n'
    printf '%s\n' "$PARITY_BAD" | head -10 | sed 's/^/    /'
fi
assert_eq "installer-manifest-parity 2: every manifest row is present and hash-equal in the fresh install" \
    "" "$(printf '%s' "$PARITY_BAD" | tr '\n' ' ' | sed 's/ *$//')"

# --- 2b META-TEST: the parity checker can FAIL ------------------------------
# One row of a COPY of the manifest loses its hash field. Row COUNT is asserted
# unchanged: deleting a row would be the weaker mutation (a checker that only
# iterates rows cannot notice a missing one), so the mutation has to be a
# truncation for the META to prove that hashes are actually compared.
META_ROW=".claude/agents/qa.md"
assert_eq "installer-manifest-parity 2b: the META row exists in the real manifest" \
    "yes" "$(yesno manifest_has_path "$MANIFEST" "$META_ROW")"
META_MANIFEST="$WORK/manifest-truncated.tsv"
awk -F'\t' -v OFS='\t' -v p="$META_ROW" '$1 == p { print $1, $2; next } { print }' \
    "$MANIFEST" > "$META_MANIFEST"
META_DIFF_RC=0
cmp -s "$MANIFEST" "$META_MANIFEST" || META_DIFF_RC=$?
assert_eq "installer-manifest-parity 2b META-TEST: the truncated copy really differs from the manifest" \
    "yes" "$(yesno test "$META_DIFF_RC" -ne 0)"
assert_eq "installer-manifest-parity 2b META-TEST: the truncated copy has the SAME row count (truncated, not deleted)" \
    "$MANIFEST_ROWS" "$(grep -c . "$META_MANIFEST" | tr -d ' \n')"
# Stated as "the truncated row, and one violation more than the untouched
# manifest produced" rather than as an exact-string match on the whole violation
# list. An exact match would also fail whenever section 2 is legitimately failing
# for an unrelated reason (a genuinely missing shipped file), turning one real
# defect into two confusing ones — the META has to isolate the checker's
# sensitivity to THIS mutation.
META_VIOLATIONS=$(parity_violations "$META_MANIFEST" "$T")
assert_contains "installer-manifest-parity 2b META-TEST: the checker flags the truncated row" \
    "$META_ROW (hash differs)" "$META_VIOLATIONS"
assert_eq "installer-manifest-parity 2b META-TEST: and flags exactly one row more than the untouched manifest did" \
    "$(( $(printf '%s' "$PARITY_BAD" | grep -c . | tr -d ' \n') + 1 ))" \
    "$(printf '%s' "$META_VIOLATIONS" | grep -c . | tr -d ' \n')"

# ===========================================================================
# Section 3: target -> manifest (no extras in plugin-owned directories)
# ===========================================================================
SCOPE_FILES=$(files_in_scopes "$T")
assert_eq "installer-manifest-parity 3: the plugin-owned scopes hold a plausible number of files (>30)" \
    "yes" "$(yesno test "${SCOPE_FILES:-0}" -gt 30)"

EXTRAS=$(extra_files "$MANIFEST" "$T")
if [ -n "$EXTRAS" ]; then
    printf '  diagnostic: installed files missing from the manifest (first 10):\n'
    printf '%s\n' "$EXTRAS" | head -10 | sed 's/^/    /'
fi
assert_eq "installer-manifest-parity 3: no installed file in a plugin-owned scope is missing from the manifest" \
    "" "$(printf '%s' "$EXTRAS" | tr '\n' ' ' | sed 's/ *$//')"

# --- 3b META-TEST: the no-extras checker can FAIL --------------------------
# A rogue agent file — the shape of "the repo shipped something the manifest
# does not enumerate", and of "a copy loop grew past the generator's surface
# rules". The same checker must flag it, and must go quiet again once it is
# gone: a checker that latched would satisfy the first half of this META while
# making section 3 permanently red.
printf 'rogue file planted by the 3b META-TEST\n' > "$T/$ROGUE_AGENT"
assert_eq "installer-manifest-parity 3b META-TEST: a rogue agents/*.md is reported as an extra" \
    "$ROGUE_AGENT (not in the manifest)" \
    "$(extra_files "$MANIFEST" "$T" | tr '\n' ' ' | sed 's/ *$//')"
rm -f "$T/$ROGUE_AGENT"
assert_eq "installer-manifest-parity 3b META-TEST: the checker is quiet again once the rogue file is gone" \
    "" "$(extra_files "$MANIFEST" "$T" | tr '\n' ' ' | sed 's/ *$//')"

# ===========================================================================
# Section 3c: the shipped-docs subset is a SUBSET (v4.1 / U0.8)
# ===========================================================================
# docs/ is deliberately NOT one of the no-extras scopes above, and cannot be:
# an install target's docs/ belongs to the operator, so "every file here is in
# the manifest" is false by design. The invariant that DOES hold is the mirror
# image — the installer put exactly the two files it ships there and nothing
# else — and it needs its own leg because both `extra_files` (wrong direction)
# and section 2's parity walk (would pass just as well if the installer had
# copied all 30 docs) are blind to it.
#
# The failure this catches is a future `cp docs/*.md`: section 2 stays green,
# section 3 stays green, and every install starts dumping the repo's internal
# design notes and dated AgentLint reports into the operator's project.
INSTALLED_DOCS=$( (cd "$T" && find docs -type f 2>/dev/null | LC_ALL=C sort) \
    | tr '\n' ' ' | sed 's/ *$//')
assert_eq "installer-manifest-parity 3c: the fresh install put EXACTLY the two shipped docs in docs/" \
    "$(printf '%s\n' "docs/CODEX_SETUP.md" "docs/HOOKS.md" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')" \
    "$INSTALLED_DOCS"
# Named negatives, so the assertion above reads as a claim about specific files
# a scan WOULD have brought along rather than only as a count.
for unshipped in docs/ARCHITECTURE.md docs/WORKFLOW.md docs/AGENTLINT_REPORT.md docs/plans/README.md; do
    assert_eq "installer-manifest-parity 3c: the install did NOT bring $unshipped along" \
        "no" "$(yesno test -e "$T/$unshipped")"
done
# Byte-equality is section 2's job (both rows are in the manifest), but the two
# docs are the newest surface members, so their presence is called out by name
# here — this is the leg that fails if a future installer edit drops the copy
# block while leaving the manifest rows in place.
for shipped_doc in docs/CODEX_SETUP.md docs/HOOKS.md; do
    assert_eq "installer-manifest-parity 3c: $shipped_doc is present and byte-equal to the source" \
        "yes" "$(yesno cmp -s "$T/$shipped_doc" "$PLUGIN_ROOT/$shipped_doc")"
    assert_eq "installer-manifest-parity 3c: ...and the manifest carries a row for it" \
        "yes" "$(yesno manifest_has_path "$MANIFEST" "$shipped_doc")"
done

# ===========================================================================
# Section 4: the install-manifest the run wrote
# ===========================================================================
INSTALL_MANIFEST="$T/.claude/install-manifest"
assert_eq "installer-manifest-parity 4: .claude/install-manifest was written" \
    "yes" "$(yesno test -f "$INSTALL_MANIFEST")"
assert_eq "installer-manifest-parity 4: its header names the version being installed" \
    "# claude-workflow-plugin $SOURCE_VERSION" \
    "$(head -1 "$INSTALL_MANIFEST" 2>/dev/null || echo "")"
BODY_CMP_RC=0
tail -n +2 "$INSTALL_MANIFEST" 2>/dev/null | cmp -s - "$MANIFEST" || BODY_CMP_RC=$?
if [ "$BODY_CMP_RC" -ne 0 ]; then
    printf '  diagnostic: first differing rows (install-manifest body vs generated):\n'
    diff <(tail -n +2 "$INSTALL_MANIFEST" 2>/dev/null) "$MANIFEST" 2>/dev/null \
        | head -10 | sed 's/^/    /'
fi
assert_eq "installer-manifest-parity 4: its body byte-equals the generated manifest" \
    "0" "$BODY_CMP_RC"
# The install-manifest itself is deliberately NOT a manifest row: it is written
# after the last copy and records the surface, so enumerating itself would make
# the body a function of its own hash.
assert_eq "installer-manifest-parity 4: the install-manifest is not itself a manifest row" \
    "no" "$(yesno manifest_has_path "$MANIFEST" ".claude/install-manifest")"

# ===========================================================================
# Section 5: uninstall leg A — a usable manifest consumes the root files
# ===========================================================================
# Through v4.0 the uninstaller removed three DIRECTORIES and left .mcp.json,
# LESSONS.md and .worktreeinclude in the project, because it had no way to tell
# them from files the operator had written. The install-manifest is that way.
#
# The root-scope set is READ FROM THE MANIFEST rather than hardcoded here, so
# the assertion follows the shipped surface: a release that adds a fourth
# root-level file is covered without an edit, and one that stops shipping
# .worktreeinclude does not leave a stale expectation behind.
ROOT_PATHS=$(awk -F'\t' '$1 !~ /^\.claude\// && $1 !~ /^\.claude-plugin\// { print $1 }' \
    "$MANIFEST" | LC_ALL=C sort)
ROOT_PATHS_FLAT=$(printf '%s' "$ROOT_PATHS" | tr '\n' ' ' | sed 's/ *$//')
# Expected side built from an explicit literal list run through the same sort, so
# the assertion states WHICH files it means without hardcoding a collation order.
#
# FIVE since v4.1 / U0.8: the shipped-docs subset (docs/CODEX_SETUP.md,
# docs/HOOKS.md) is root scope too, and root scope therefore stopped being FLAT.
# uninstall.sh's header records that it deliberately never adopted a
# "root rows must be flat" rule for exactly this release; the legs below are
# where that pays off, because they are driven from this list and so cover the
# nested rows without an edit.
assert_eq "installer-manifest-parity 5: the manifest's root scope is exactly the five known files" \
    "$(printf '%s\n' ".mcp.json" ".worktreeinclude" "LESSONS.md" \
        "docs/CODEX_SETUP.md" "docs/HOOKS.md" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')" \
    "$ROOT_PATHS_FLAT"
# At least one root row is NESTED, which is what makes the trash-layout
# assertions below non-vacuous. Without this, a future release that dropped the
# docs subset would silently turn those legs back into flat-file checks.
assert_eq "installer-manifest-parity 5: at least one root row is nested (the docs subset)" \
    "yes" "$(yesno test "$(printf '%s\n' "$ROOT_PATHS" | grep -c '/' | tr -d ' \n')" -ge 1)"

seed_beads "$T"
# An operator's OWN doc, sitting in the same directory as the two shipped ones.
# It has no manifest row, so the root-scope walk must not touch it — the
# uninstaller may only take what the installer wrote, and docs/ is the first
# shipped scope where the operator has files of their own next to the plugin's.
printf 'notes the operator wrote (never installed by the plugin)\n' \
    > "$T/docs/OPERATOR_NOTES.md"
# Backup directories from all THREE mechanisms, so the "kept in place" listing is
# asserted for each. The two migration prefixes were invisible to the pre-U0.5
# listing, which is the worst case to be silent about: a project that took the
# v2 or v3 upgrade path has its ONLY pre-upgrade snapshot under one of them.
BACKUP_DIRS="\
.claude-backup-20260202-000000
.claude-v2-backup-20250101-000000
.claude-v3-backup-20260101-000000"
while IFS= read -r backup_dir; do
    [ -n "$backup_dir" ] || continue
    mkdir -p "$T/$backup_dir"
    printf 'snapshot marker\n' > "$T/$backup_dir/marker.txt"
done <<< "$BACKUP_DIRS"

UNINSTALL_A_LOG="$WORK/uninstall-a.log"
UNINSTALL_A_RC=0
uninstall_of "$T" "$UNINSTALL_A_LOG" || UNINSTALL_A_RC=$?
if [ "$UNINSTALL_A_RC" -ne 0 ]; then
    printf '  diagnostic: uninstall exited %s; tail of log:\n' "$UNINSTALL_A_RC"
    tail -20 "$UNINSTALL_A_LOG" 2>/dev/null | sed 's/^/    /'
fi
UNINSTALL_A_TEXT=$(cat "$UNINSTALL_A_LOG" 2>/dev/null || echo "")
assert_eq "installer-manifest-parity 5: uninstall.sh exits 0" "0" "$UNINSTALL_A_RC"
assert_eq "installer-manifest-parity 5: exactly one trash directory was created" \
    "1" "$(trash_count_of "$T")"
TRASH_A=$(trash_dir_of "$T")

for gone in .claude .claude-plugin .beads; do
    assert_eq "installer-manifest-parity 5: $gone/ is gone from the project" \
        "no" "$(yesno test -e "$T/$gone")"
    assert_eq "installer-manifest-parity 5: $gone/ is in the trash" \
        "yes" "$(yesno test -d "$TRASH_A/$gone")"
done
# The marker proves .beads/ was MOVED, not recreated empty by a later step.
assert_eq "installer-manifest-parity 5: the trashed .beads/ still carries its marker file" \
    "yes" "$(yesno test -f "$TRASH_A/.beads/marker.txt")"

# The root files: driven from the manifest's own root scope, one assertion pair
# each. This is the leg that used to leak.
#
# "in the trash" is asserted at the row's OWN RELATIVE PATH, not at its
# basename: the trash mirrors the project layout (v4.1 / U0.8) so that
# docs/HOOKS.md comes back to docs/ and cannot collide with a same-named file
# from elsewhere. The readout names the relative path for the same reason.
while IFS= read -r root_path; do
    [ -n "$root_path" ] || continue
    assert_eq "installer-manifest-parity 5: unmodified $root_path left the project" \
        "no" "$(yesno test -e "$T/$root_path")"
    assert_eq "installer-manifest-parity 5: unmodified $root_path is in the trash at its own relative path" \
        "yes" "$(yesno test -f "$TRASH_A/$root_path")"
    assert_contains "installer-manifest-parity 5: the readout listed $root_path as unmodified before asking" \
        "$root_path (unmodified since install)" "$UNINSTALL_A_TEXT"
    assert_contains "installer-manifest-parity 5: the readout records moving $root_path" \
        "moved $root_path ->" "$UNINSTALL_A_TEXT"
done <<< "$ROOT_PATHS"

# The nested rows, stated positively AND negatively. The negative half is the
# regression: `mv "$path" "$TRASH_DIR/"` put docs/HOOKS.md at the trash ROOT,
# where the printed recovery command would have restored it into the project
# root instead of back into docs/.
for nested_doc in docs/CODEX_SETUP.md docs/HOOKS.md; do
    assert_eq "installer-manifest-parity 5: $nested_doc is in the trash UNDER docs/" \
        "yes" "$(yesno test -f "$TRASH_A/$nested_doc")"
    assert_eq "installer-manifest-parity 5: ...and NOT flattened to the trash root" \
        "no" "$(yesno test -e "$TRASH_A/$(basename "$nested_doc")")"
done
# The operator's own docs are none of the uninstaller's business: only manifest
# rows move, so a doc the plugin never installed stays where it is.
assert_eq "installer-manifest-parity 5: an operator doc the plugin never installed is untouched" \
    "yes" "$(yesno test -f "$T/docs/OPERATOR_NOTES.md")"
assert_eq "installer-manifest-parity 5: ...and did not reach the trash" \
    "no" "$(yesno test -e "$TRASH_A/docs/OPERATOR_NOTES.md")"

# Every backup directory is NAMED in the listing and LEFT WHERE IT IS. Naming
# matters because this is the last screen before a destructive op: an operator
# deciding whether to proceed needs to know a recoverable snapshot exists, and
# for an upgraded project that snapshot is under a v2/v3 prefix.
while IFS= read -r backup_dir; do
    [ -n "$backup_dir" ] || continue
    assert_contains "installer-manifest-parity 5: the readout lists $backup_dir as kept in place" \
        "$backup_dir" "$UNINSTALL_A_TEXT"
    assert_eq "installer-manifest-parity 5: and $backup_dir survived the uninstall" \
        "yes" "$(yesno test -f "$T/$backup_dir/marker.txt")"
done <<< "$BACKUP_DIRS"

# CLAUDE.md keeps its own pre-existing heuristic (unmodified template -> trash).
# Asserted here so a future change to the manifest walk cannot silently take
# over a file that is deliberately outside the shipped surface.
assert_eq "installer-manifest-parity 5: the untouched CLAUDE.md template also reached the trash" \
    "yes" "$(yesno test -f "$TRASH_A/CLAUDE.md")"
assert_contains "installer-manifest-parity 5: and it was reported as the unmodified template" \
    "moved CLAUDE.md (unmodified template)" "$UNINSTALL_A_TEXT"

# ===========================================================================
# Section 6: uninstall leg B — an operator-modified root file is left alone
# ===========================================================================
# A fresh install, then the ledger gets an entry the operator wrote. Uninstall
# must leave LESSONS.md exactly where it is, say so, and still take the two root
# files that are untouched. The whole point of hashing rather than name-matching.
TB="$WORK/target-modified"
TB_INSTALL_RC=0
fresh_install "$TB" "$WORK/install-b.log" || TB_INSTALL_RC=$?
assert_eq "installer-manifest-parity 6: the second fixture installs cleanly" "0" "$TB_INSTALL_RC"
seed_beads "$TB"
printf '\n- %s: an uninstall must not take a ledger the operator wrote into.\n' \
    "$LESSON_SENTINEL" >> "$TB/LESSONS.md"
# Pre-condition: without the edit in place every assertion below would pass for
# the wrong reason.
assert_contains "installer-manifest-parity 6: the ledger carries the operator entry before the uninstall" \
    "$LESSON_SENTINEL" "$(cat "$TB/LESSONS.md" 2>/dev/null || echo "")"

UNINSTALL_B_LOG="$WORK/uninstall-b.log"
UNINSTALL_B_RC=0
uninstall_of "$TB" "$UNINSTALL_B_LOG" || UNINSTALL_B_RC=$?
UNINSTALL_B_TEXT=$(cat "$UNINSTALL_B_LOG" 2>/dev/null || echo "")
assert_eq "installer-manifest-parity 6: uninstall.sh exits 0 with a modified root file" \
    "0" "$UNINSTALL_B_RC"
TRASH_B=$(trash_dir_of "$TB")
assert_eq "installer-manifest-parity 6: LESSONS.md is STILL IN THE PROJECT" \
    "yes" "$(yesno test -f "$TB/LESSONS.md")"
assert_contains "installer-manifest-parity 6: and it still carries the operator entry" \
    "$LESSON_SENTINEL" "$(cat "$TB/LESSONS.md" 2>/dev/null || echo "")"
assert_eq "installer-manifest-parity 6: LESSONS.md was NOT moved to the trash" \
    "no" "$(yesno test -e "$TRASH_B/LESSONS.md")"
assert_contains "installer-manifest-parity 6: the readout notes it was left in place, and why" \
    "LESSONS.md left in place (modified since install" "$UNINSTALL_B_TEXT"
assert_contains "installer-manifest-parity 6: the pre-confirmation listing names it too" \
    "LESSONS.md (modified since install)" "$UNINSTALL_B_TEXT"
# The two UNMODIFIED root files still go: "leave what the operator touched" must
# not degrade into "leave everything at the root".
for still_going in .mcp.json .worktreeinclude; do
    assert_eq "installer-manifest-parity 6: unmodified $still_going still left the project" \
        "no" "$(yesno test -e "$TB/$still_going")"
    assert_eq "installer-manifest-parity 6: unmodified $still_going is in the trash" \
        "yes" "$(yesno test -f "$TRASH_B/$still_going")"
done
assert_eq "installer-manifest-parity 6: .claude/ still went to the trash" \
    "yes" "$(yesno test -d "$TRASH_B/.claude")"

# ===========================================================================
# Section 7: uninstall leg C — no manifest is the pre-v4.1 behaviour
# ===========================================================================
# Every install before v4.1 wrote no install-manifest, and those trees are still
# out there. With no table of hashes there is no way to tell a stock root file
# from an operator's, so the ONLY correct behaviour is the old one: move the
# three directories, leave the root files. This section pins that byte-faithfully
# — it is the back-compat contract, not a limitation to be fixed later.
TC="$WORK/target-legacy"
TC_INSTALL_RC=0
fresh_install "$TC" "$WORK/install-c.log" || TC_INSTALL_RC=$?
assert_eq "installer-manifest-parity 7: the legacy fixture installs cleanly" "0" "$TC_INSTALL_RC"
seed_beads "$TC"
# Clone BEFORE mutating, so leg D gets the identical tree through the other
# failure arm. cp -R src/. dst/ and not src/*: the whole tree is dotfiles, which
# the glob form silently skips.
TD="$WORK/target-malformed"
mkdir -p "$TD"
cp -R "$TC/." "$TD/" 2>/dev/null || true
assert_eq "installer-manifest-parity 7: the clone for leg D carries an install-manifest" \
    "yes" "$(yesno test -f "$TD/.claude/install-manifest")"

rm -f "$TC/.claude/install-manifest"
assert_eq "installer-manifest-parity 7: the legacy fixture has no install-manifest" \
    "no" "$(yesno test -e "$TC/.claude/install-manifest")"
UNINSTALL_C_LOG="$WORK/uninstall-c.log"
UNINSTALL_C_RC=0
uninstall_of "$TC" "$UNINSTALL_C_LOG" || UNINSTALL_C_RC=$?
UNINSTALL_C_TEXT=$(cat "$UNINSTALL_C_LOG" 2>/dev/null || echo "")
assert_eq "installer-manifest-parity 7: uninstall.sh exits 0 without a manifest" "0" "$UNINSTALL_C_RC"
TRASH_C=$(trash_dir_of "$TC")
for gone in .claude .claude-plugin .beads; do
    assert_eq "installer-manifest-parity 7: $gone/ still reached the trash" \
        "yes" "$(yesno test -d "$TRASH_C/$gone")"
done
# The leak, asserted as the CONTRACT for a manifest-less tree.
for leaked in .mcp.json .worktreeinclude LESSONS.md; do
    assert_eq "installer-manifest-parity 7: $leaked is left in the project (legacy behaviour)" \
        "yes" "$(yesno test -f "$TC/$leaked")"
    assert_eq "installer-manifest-parity 7: $leaked is NOT in the trash" \
        "no" "$(yesno test -e "$TRASH_C/$leaked")"
done
# ...and it got there by finding no manifest, not by deciding the files were
# modified: neither root-scope readout line may appear.
assert_not_contains "installer-manifest-parity 7: no root file was listed as unmodified" \
    "(unmodified since install)" "$UNINSTALL_C_TEXT"
assert_not_contains "installer-manifest-parity 7: no root file was noted as left in place" \
    "left in place (modified since install" "$UNINSTALL_C_TEXT"

# ===========================================================================
# Section 8: uninstall leg D — a malformed manifest takes the same legacy path
# ===========================================================================
# The other failure arm: the file is there but it is not one of ours. A header
# check that accepted anything would read a foreign file's rows as hashes and
# either leak (harmless) or MOVE A FILE IT NEVER INSTALLED (not harmless), so
# the arm is asserted separately from leg C rather than assumed equivalent.
printf '# some-other-tool 1.0\nnot\ta\tmanifest\n' > "$TD/.claude/install-manifest"
UNINSTALL_D_LOG="$WORK/uninstall-d.log"
UNINSTALL_D_RC=0
uninstall_of "$TD" "$UNINSTALL_D_LOG" || UNINSTALL_D_RC=$?
UNINSTALL_D_TEXT=$(cat "$UNINSTALL_D_LOG" 2>/dev/null || echo "")
assert_eq "installer-manifest-parity 8: uninstall.sh exits 0 on a foreign manifest" \
    "0" "$UNINSTALL_D_RC"
TRASH_D=$(trash_dir_of "$TD")
assert_eq "installer-manifest-parity 8: .claude/ still reached the trash" \
    "yes" "$(yesno test -d "$TRASH_D/.claude")"
for leaked in .mcp.json .worktreeinclude LESSONS.md; do
    assert_eq "installer-manifest-parity 8: $leaked is left in the project (foreign manifest)" \
        "yes" "$(yesno test -f "$TD/$leaked")"
done
assert_not_contains "installer-manifest-parity 8: no root file was listed as unmodified" \
    "(unmodified since install)" "$UNINSTALL_D_TEXT"

# ===========================================================================
# Section 9: synthetic edge cases on the destructive path
# ===========================================================================
# uninstall.sh needs a .claude/ directory and (for the root-scope walk) a
# manifest — not a real install. Both cases below are shapes a real install
# cannot produce, which is exactly why they need a hand-built tree: they are
# what a CORRUPTED or hand-edited manifest does to a script that calls `mv`.

# --- 9a. a hash-MATCHING escaping row must not move a file outside ----------
# The dangerous version of the case, not the easy one: every row carries its
# victim's REAL hash, so the hash check would wave them all through and only the
# two containment guards stand between a manifest row and `mv /etc/hosts`:
#
#   the LEXICAL path rule    (in manifest_root_rows' awk filter) drops absolute
#                            rows and rows carrying a `..` segment.
#   PHYSICAL containment     (row_contained, the WN4-CONTAINMENT block) drops a
#                            row whose parent directory resolves outside the
#                            target — which is what a SYMLINKED parent does, and
#                            what the lexical rule alone cannot see
#                            (claude-workflow-plugin-wn4: `[ -f ]` and hashing
#                            both follow symlinks, so a lexically-clean row
#                            reached a file outside the project and moved it).
#
# A legitimate row is included alongside so the assertions can tell "the
# escaping rows were dropped" from "the whole manifest was rejected" — if the
# manifest had been thrown out wholesale, .mcp.json would still be sitting in the
# project and this section would prove nothing about either rule.
# ALL THREE victims live inside $WORK — the relative row escapes only as far as
# the fixture's parent, the absolute row points at another fixture file rather
# than at a real system path, and the symlink points at a fixture directory. That
# is deliberate: anyone probing these guards by MUTATING them (9c below does
# exactly that) would otherwise have the mutant attempt `mv` on a system file,
# and a spec must not depend on the host's permissions to stay harmless.
TS="$WORK/synthetic-traversal"
mkdir -p "$TS/.claude"
VICTIM_REL="$WORK/outside-victim.txt"
VICTIM_ABS="$WORK/absolute-victim.txt"
# wn4: a directory OUTSIDE the target, reached through a symlink INSIDE it. The
# row spelling ("data/symlink-victim.txt") is relative and carries no `..`, so it
# passes the lexical rule untouched.
VICTIM_LINK_DIR="$WORK/outside-symlinked"
VICTIM_LINK="$VICTIM_LINK_DIR/symlink-victim.txt"
SYMLINK_ROW="data/symlink-victim.txt"
printf 'a file one level OUTSIDE the project\n' > "$VICTIM_REL"
printf 'a file named by ABSOLUTE path\n' > "$VICTIM_ABS"
mkdir -p "$VICTIM_LINK_DIR"
printf 'a file reached through a SYMLINKED parent directory\n' > "$VICTIM_LINK"
ln -s "$VICTIM_LINK_DIR" "$TS/data"
printf '{"mcpServers":{}}\n' > "$TS/.mcp.json"
{
    printf '# claude-workflow-plugin 4.0.0\n'
    printf '.mcp.json\tmerged\t%s\n' "$(hash_of "$TS/.mcp.json")"
    printf '../outside-victim.txt\toperator\t%s\n' "$(hash_of "$VICTIM_REL")"
    printf '%s\tworkflow\t%s\n' "$VICTIM_ABS" "$(hash_of "$VICTIM_ABS")"
    printf '%s\toperator\t%s\n' "$SYMLINK_ROW" "$(hash_of "$VICTIM_LINK")"
} > "$TS/.claude/install-manifest"
# Pre-conditions: the symlink really resolves outside, and the row's hash really
# matches the victim. Without both, 9a's symlink assertions would pass because
# the row never had a chance, not because the guard stopped it.
assert_eq "installer-manifest-parity 9a: the fixture's symlinked parent resolves outside the target" \
    "yes" "$(yesno test -f "$TS/$SYMLINK_ROW")"
assert_eq "installer-manifest-parity 9a: and the symlink row carries the victim's REAL hash" \
    "$(hash_of "$VICTIM_LINK")" \
    "$(awk -F'\t' -v p="$SYMLINK_ROW" '$1 == p { print $3 }' "$TS/.claude/install-manifest")"

UNINSTALL_TS_LOG="$WORK/uninstall-traversal.log"
UNINSTALL_TS_RC=0
uninstall_of "$TS" "$UNINSTALL_TS_LOG" || UNINSTALL_TS_RC=$?
UNINSTALL_TS_TEXT=$(cat "$UNINSTALL_TS_LOG" 2>/dev/null || echo "")
assert_eq "installer-manifest-parity 9a: uninstall.sh exits 0 on a manifest with escaping rows" \
    "0" "$UNINSTALL_TS_RC"
assert_eq "installer-manifest-parity 9a: the file OUTSIDE the project still exists" \
    "yes" "$(yesno test -f "$VICTIM_REL")"
# Defence in depth, not the load-bearing half: every candidate is tested and
# moved as "$TARGET/$path", so an ABSOLUTE row degrades to "$TARGET//abs/path"
# and simply does not exist — it survives even with the path rule removed. The
# RELATIVE row is the one that reaches a real file, and (verified by deleting the
# rule from uninstall.sh) it is the one whose assertion flips.
assert_eq "installer-manifest-parity 9a: the absolute-path row was not acted on either" \
    "yes" "$(yesno test -f "$VICTIM_ABS")"
assert_not_contains "installer-manifest-parity 9a: the traversal row is not even named in the readout" \
    "outside-victim" "$UNINSTALL_TS_TEXT"
assert_not_contains "installer-manifest-parity 9a: nor is the absolute one" \
    "absolute-victim" "$UNINSTALL_TS_TEXT"
# wn4, the load-bearing half of the new guard: the symlinked-parent row is
# REFUSED. The victim stays where it was, nothing of it reaches the trash, and
# the row is never presented as something that will move.
TRASH_TS=$(trash_dir_of "$TS")
assert_eq "installer-manifest-parity 9a (wn4): the file behind the symlinked parent still exists" \
    "yes" "$(yesno test -f "$VICTIM_LINK")"
assert_contains "installer-manifest-parity 9a (wn4): and still carries its content" \
    "a file reached through a SYMLINKED parent directory" \
    "$(cat "$VICTIM_LINK" 2>/dev/null || echo "")"
assert_eq "installer-manifest-parity 9a (wn4): nothing named symlink-victim.txt reached the trash" \
    "no" "$(yesno test -e "$TRASH_TS/symlink-victim.txt")"
assert_not_contains "installer-manifest-parity 9a (wn4): the row was NOT listed as something that will move" \
    "$SYMLINK_ROW (unmodified since install)" "$UNINSTALL_TS_TEXT"
assert_not_contains "installer-manifest-parity 9a (wn4): nor was it reported as moved" \
    "moved symlink-victim.txt" "$UNINSTALL_TS_TEXT"
# It is REFUSED OUT LOUD rather than silently skipped: a manifest row that
# resolves outside the project is the corrupted-manifest case, and an operator
# running a destructive op has to be told which row was ignored and why.
assert_contains "installer-manifest-parity 9a (wn4): the readout names the refused row" \
    "$SYMLINK_ROW (resolves outside the project" "$UNINSTALL_TS_TEXT"
# The control half: the legitimate row WAS consumed, so the manifest was parsed
# and it is the two containment rules doing the work.
assert_eq "installer-manifest-parity 9a: the legitimate root row was still consumed" \
    "yes" "$(yesno test -f "$TRASH_TS/.mcp.json")"

# --- 9b. --restore-backup with only a migration snapshot -------------------
# The listing widened to v2/v3 backups; the RESTORE source deliberately did not.
# A migration snapshot holds a previous major's layout, and it is stored FLAT (it
# is a copy of .claude/'s contents, not of .claude/ itself), so restoring one
# would splatter agents/ and scripts/ into the project root. The operator is told
# instead.
TR9="$WORK/synthetic-restore"
mkdir -p "$TR9/.claude" "$TR9/.claude-v3-backup-20260101-000000"
printf 'from the v3 snapshot\n' > "$TR9/.claude-v3-backup-20260101-000000/agents-marker.txt"
UNINSTALL_TR_LOG="$WORK/uninstall-restore.log"
UNINSTALL_TR_RC=0
printf 'y\n' | bash "$PLUGIN_ROOT/uninstall.sh" --restore-backup "$TR9" \
    >"$UNINSTALL_TR_LOG" 2>&1 || UNINSTALL_TR_RC=$?
UNINSTALL_TR_TEXT=$(cat "$UNINSTALL_TR_LOG" 2>/dev/null || echo "")
assert_eq "installer-manifest-parity 9b: uninstall.sh --restore-backup exits 0" \
    "0" "$UNINSTALL_TR_RC"
assert_contains "installer-manifest-parity 9b: the migration snapshot is listed as kept" \
    ".claude-v3-backup-20260101-000000" "$UNINSTALL_TR_TEXT"
assert_contains "installer-manifest-parity 9b: and the readout says why it will not be restored" \
    "no .claude-backup-* directory exists to restore from" "$UNINSTALL_TR_TEXT"
assert_eq "installer-manifest-parity 9b: nothing from it was splattered into the project root" \
    "no" "$(yesno test -e "$TR9/agents-marker.txt")"
assert_eq "installer-manifest-parity 9b: and the snapshot itself is untouched" \
    "yes" "$(yesno test -f "$TR9/.claude-v3-backup-20260101-000000/agents-marker.txt")"

# --- 9c META-TEST: the containment guard can actually fail -------------------
# claude-workflow-plugin-wn4 was a REAL escape, reproduced before it was fixed:
# with only the lexical path rule in place, the symlinked-parent row of 9a moved
# the outside file into the in-project trash and the readout called it
# "unmodified since install". This META keeps that proof mechanical — the block
# is deleted from a COPY of uninstall.sh (anchored on its own sentinels, so a
# rename breaks the META loudly instead of silently making it a no-op) and the
# same fixture shape is run through the mutant.
#
# A SECOND fixture, not 9a's: the mutant is expected to consume its victim, and
# reusing 9a's tree would leave the section's own assertions depending on run
# order.
MUTANT_UNINSTALL="$WORK/uninstall-no-containment.sh"
sed '/# WN4-CONTAINMENT-START/,/# WN4-CONTAINMENT-END/d' \
    "$PLUGIN_ROOT/uninstall.sh" > "$MUTANT_UNINSTALL"
assert_eq "installer-manifest-parity 9c META-TEST: the mutated copy really differs from uninstall.sh" \
    "no" "$(yesno cmp -s "$MUTANT_UNINSTALL" "$PLUGIN_ROOT/uninstall.sh")"
assert_eq "installer-manifest-parity 9c META-TEST: the strip removed the containment block (fewer lines)" \
    "yes" "$(yesno test "$(grep -c . "$MUTANT_UNINSTALL" | tr -d ' \n')" -lt "$(grep -c . "$PLUGIN_ROOT/uninstall.sh" | tr -d ' \n')")"
assert_eq "installer-manifest-parity 9c META-TEST: the mutated copy is still valid bash" \
    "yes" "$(yesno bash -n "$MUTANT_UNINSTALL")"

TSM="$WORK/synthetic-symlink-mutant"
mkdir -p "$TSM/.claude"
MUTANT_LINK_DIR="$WORK/outside-symlinked-mutant"
MUTANT_VICTIM="$MUTANT_LINK_DIR/symlink-victim-mutant.txt"
mkdir -p "$MUTANT_LINK_DIR"
printf 'the mutant is expected to move this one\n' > "$MUTANT_VICTIM"
ln -s "$MUTANT_LINK_DIR" "$TSM/data"
printf '{"mcpServers":{}}\n' > "$TSM/.mcp.json"
{
    printf '# claude-workflow-plugin 4.0.0\n'
    printf '.mcp.json\tmerged\t%s\n' "$(hash_of "$TSM/.mcp.json")"
    printf 'data/symlink-victim-mutant.txt\toperator\t%s\n' "$(hash_of "$MUTANT_VICTIM")"
} > "$TSM/.claude/install-manifest"

UNINSTALL_TSM_LOG="$WORK/uninstall-symlink-mutant.log"
UNINSTALL_TSM_RC=0
printf 'y\n' | bash "$MUTANT_UNINSTALL" "$TSM" >"$UNINSTALL_TSM_LOG" 2>&1 || UNINSTALL_TSM_RC=$?
UNINSTALL_TSM_TEXT=$(cat "$UNINSTALL_TSM_LOG" 2>/dev/null || echo "")
assert_eq "installer-manifest-parity 9c META-TEST: the mutant still runs to completion" \
    "0" "$UNINSTALL_TSM_RC"
# THE FLIP. 9a asserts the victim survives; without the block the same shape of
# row takes it out of its directory entirely.
assert_eq "installer-manifest-parity 9c META-TEST: without the block the outside file is GONE from its own directory" \
    "no" "$(yesno test -f "$MUTANT_VICTIM")"
TRASH_TSM=$(trash_dir_of "$TSM")
# Under the row's own relative path, because the trash mirrors the project
# layout (v4.1 / U0.8) — the mutant follows the symlink, so the victim is
# relocated out of its real directory and lands at <trash>/data/<name>.
assert_eq "installer-manifest-parity 9c META-TEST: and it sits in the project's trash instead" \
    "yes" "$(yesno test -f "$TRASH_TSM/data/symlink-victim-mutant.txt")"
assert_contains "installer-manifest-parity 9c META-TEST: the mutant even called it unmodified since install" \
    "data/symlink-victim-mutant.txt (unmodified since install)" "$UNINSTALL_TSM_TEXT"
assert_not_contains "installer-manifest-parity 9c META-TEST: and printed no refusal" \
    "resolves outside the project" "$UNINSTALL_TSM_TEXT"
# The mutation is SURGICAL: deleting the containment block must not disturb the
# lexical rule or the legitimate row, or the flip above could be a side effect of
# breaking the walk wholesale.
assert_eq "installer-manifest-parity 9c META-TEST: the mutant still consumed the legitimate row" \
    "yes" "$(yesno test -f "$TRASH_TSM/.mcp.json")"

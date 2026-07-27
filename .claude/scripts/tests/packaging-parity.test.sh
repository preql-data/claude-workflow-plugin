#!/bin/bash
# packaging-parity.test.sh — L1 spec for the two installer merge expressions
# (claude-workflow-plugin-p5n, v4.1 Phase U0; absorbs claude-workflow-plugin-bzy).
#
# WHAT THIS PROTECTS
# ------------------
# `install.sh` mode 2 (Update) is the ONLY path an already-installed project
# takes to reach a new plugin version. THREE jq expressions decide what survives
# that path, all three duplicated verbatim into install.ps1:
#
#   SETTINGS_MERGE_JQ — replaces workflow-owned settings keys, preserves the
#   operator's, deletes the retired env.CLAUDE_CODE_EFFORT_LEVEL pin (v4: a
#   non-xhigh value there deactivates ultracode orchestration), and — new in
#   v4.1 — ADDS effortLevel / statusLine to a settings file of pre-v3.5
#   lineage that lacks them.
#
#   MCP_MERGE_JQ — unions the shipped MCP servers over the installed ones
#   (which is how a v3.5 tree gets the `${CLAUDE_PROJECT_DIR:-.}` form and
#   loses the code-context server retired in 3.3.0) while operator-added
#   servers and operator top-level keys pass through verbatim.
#
#   JSON_SINGLE_OBJECT_JQ — the gate BOTH merges pass their target through
#   first. Both slurp with `jq -s` and bind positionally (.[0] existing,
#   .[1] new), which is only sound when each input holds exactly one JSON
#   document. The `jq empty` check this replaced accepted an empty file and a
#   multi-document stream; a two-document target pushed the shipped file out
#   to .[2] and produced a config with none of the shipped servers (R1-F1).
#
# Until now the `del(.CLAUDE_CODE_EFFORT_LEVEL)` behaviour was proven only by a
# LIVE PROBE in a session transcript (RELEASE_AUDIT row TM13): a hand-run copy
# of the expression against a synthetic settings file. Nothing in `make test`
# caught a future break, and the expression is DUPLICATED as a PowerShell
# string literal in install.ps1 — the drift surface the "Keep this jq
# expression equivalent to install.sh's" comment can only ask about politely.
#
# THE CONTRACT THIS SPEC ENFORCES
#   1. Both expressions are extracted FROM THE INSTALLERS, between literal
#      sentinel comments, and executed through real jq. A copied literal in
#      this file would test the copy, not the shipped installer — the whole
#      point of bzy deliverable 1.
#   2. The extracted expressions are also the ones the installers RUN (the
#      wiring section): a hoisted-but-unused variable would make every
#      behavioural assertion below theatre.
#   3. bash and PowerShell carry token-identical expressions.
#
# ASSERTION ANCHORING: every check is anchored to TEXT (a sentinel token, a
# jq key, a fixture value) and never to a line number — install.sh's merge
# block has moved twice already.
#
# SECTIONS
#   0. Preflight: the two installers and jq exist.
#   1. Extraction: sentinels present exactly once, extraction non-empty.
#   1b. Wiring: the installers invoke the hoisted variables, each expression is
#       defined exactly once per file (no stale duplicate), both merges gate on
#       the validity helper, and the retired `jq empty` oracle is gone.
#   2. Settings fixture battery, driven by the EXTRACTED bash expression —
#      including the PRESENCE-not-truthiness battery (R1-F2): an operator's
#      explicit null/false survives an upgrade.
#   3. MCP fixture battery, driven by the EXTRACTED bash expression, against
#      the REAL shipped .mcp.json.
#   3b. Merge-input validity gate (R1-F1): empty / multi-document / malformed /
#      array / scalar inputs are rejected, the retired oracle's acceptance of
#      the first two is pinned as a regression witness, and the consequence of
#      accepting a multi-document target is demonstrated end-to-end.
#   4. Expression identity bash <-> ps1 (whitespace-normalised).
#   5. META-TESTs: each proves a check above is capable of failing.
#   6. install.ps1 UPGRADE-MACHINERY parity (v4.1 / U0.7) — see the block below.
#   6m-6q. v4.1 / U0.8 additions:
#      6m  version-dynamic branding — no hardcoded major in either installer,
#          the banner/usage header/readout heading all interpolate a version read
#          from .claude-plugin/plugin.json, and `--help` is EXECUTED to prove it.
#      6n  the generated .gitignore — install.sh's heredoc is EXECUTED and the
#          file it produces is compared line-for-line against install.ps1's list,
#          plus per-entry checks for the nine artifacts the plugin itself writes.
#      6o  the shipped-docs subset — the same two paths in FIVE places (both
#          surfaces, both copy loops, both required-source lists) plus the frozen
#          v3.5 table's refreeze evidence, and a rule that neither installer
#          globs docs/.
#      6p  R1-F2 / R1-F3 readout wording — the seven merged-file report
#          sentences compared file-to-file with path separators folded, the four
#          merge states present in both, the retired booleans gone, and the
#          prerequisite diagnosis naming whichever half actually failed.
#      6q  uninstaller nested rows + the m7e R1-F3 CRLF-tolerance divergence,
#          recorded in both uninstaller headers.
#   7. META-TESTs for section 6.
#   7b. META-TESTs for the U0.8 checkers (16-20).
#
# WHY SECTION 6 IS TEXTUAL AND NOT EXECUTED (U0.7)
# -----------------------------------------------
# U0.7 ported install.sh's whole v3 -> v4 upgrade machinery into install.ps1:
# the -Upgrade switch and its exclusivity with -Mode, Detect-V3Install, the
# dotfile-inclusive backup, a PS-NATIVE reimplementation of
# workflow-manifest.sh's generate/classify (Get-FileHash instead of shasum), the
# verdict walk, the no-change probe, and the LF-only install-manifest writer.
# That is ~600 lines of duplicated contract, and NOTHING in `make test` can run
# it: the L2/L3 tiers execute bash only, .github/workflows/windows-install.yml is
# workflow_dispatch-only, and there is no PowerShell on the dev/CI lane that runs
# this suite.
#
# So the checks below pin the parts of the port that a silent divergence would
# make WRONG rather than merely different, and they pin them FILE-TO-FILE
# wherever the two dialects allow it (extract from both, compare) rather than
# against literals typed here:
#
#   * both installers agree on the shipped SURFACE (extracted from
#     workflow-manifest.sh's generate_rows and from install.ps1's
#     Get-WorkflowSurfaceRows and compared as sets) — the one that drifts when a
#     future release adds a file to one side only;
#   * the no-change probe's readout is byte-identical, because the L2 spec
#     asserts on that exact sentence;
#   * the jq merge operand ORDER is existing-then-shipped in both, because
#     swapping it stays valid jq and silently reverses the union direction
#     (claude-workflow-plugin-3t1);
#   * no Out-File / -NoNewline survives on a JSON or manifest write path, because
#     under Windows PowerShell 5.1 that means a BOM and a single-line body, and a
#     CRLF manifest silently degrades the next Update to plain copies (3t1
#     facets 1-2);
#   * the wn4 containment rule is present in BOTH uninstall scripts.
#
# Exit codes:
#   0  all assertions pass
#   1  one or more assertions failed

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
INSTALL_SH="$PROJECT_DIR/install.sh"
INSTALL_PS1="$PROJECT_DIR/install.ps1"
SHIPPED_MCP="$PROJECT_DIR/.mcp.json"
SHIPPED_SETTINGS="$PROJECT_DIR/.claude/settings.json"
# Section 6 subjects: the surface generator both installers must agree with, and
# the two uninstallers that share the wn4 containment rule.
MANIFEST_TOOL="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
UNINSTALL_SH="$PROJECT_DIR/uninstall.sh"
UNINSTALL_PS1="$PROJECT_DIR/uninstall.ps1"

WORK=$(mktemp -d -t packaging-parity-test.XXXXXX)
# Invoked indirectly, by the EXIT trap immediately below.
# shellcheck disable=SC2329
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

# --- extraction helpers ----------------------------------------------------

# extract_block <file> <name> — print the lines strictly between
# `# BEGIN <name>` and `# END <name>`.
#
# Matched with index() rather than an anchored regex so the same extractor
# works for install.sh (sentinels at column 0) and install.ps1 (sentinels
# indented inside the install function). The BEGIN sentinel carries a
# trailing parenthetical in both files; only the token prefix is matched.
extract_block() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 1
    awk -v b="# BEGIN $name" -v e="# END $name" '
        !inb && index($0, b) { inb = 1; next }
        inb && index($0, e)  { exit }
        inb                  { print }
    ' "$file"
}

# strip_quoted_literal — stdin to stdout: drop the assignment head up to and
# including the FIRST single quote on the first line (`NAME='` in bash,
# `$Name = '` in PowerShell) and the trailing single quote on the last line.
# Neither jq expression contains a single quote, so this is unambiguous for
# both dialects; a quote appearing inside one later would be caught by the
# fixture batteries failing to parse.
strip_quoted_literal() {
    sed -e "1s/^[^']*'//" -e "\$s/'[[:space:]]*\$//"
}

# extract_expr <file> <name> — the runnable jq program text.
extract_expr() {
    extract_block "$1" "$2" | strip_quoted_literal
}

# normalize_expr — stdin to stdout: collapse every whitespace run to one
# space and trim. This is what makes the bash <-> ps1 comparison a TOKEN
# comparison: the two literals live at different indentation depths and the
# add-if-absent clauses are column-aligned with double spaces.
normalize_expr() {
    tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# sentinel_line_count <file> <token> — how many lines carry the token.
# Exactly 1 is the contract: 0 means the sentinel was renamed or deleted,
# 2+ means a second definition was pasted in (the drift this spec exists
# to prevent).
sentinel_line_count() {
    grep -c -- "$2" "$1" 2>/dev/null | tr -d ' \n'
}

# code_line_count <file> <literal> — fixed-string line count over CODE lines
# only; any line whose first non-space character is `#` (the comment marker in
# both bash and PowerShell) is excluded first.
#
# Comment-blindness is required, not cosmetic: the "this call no longer exists"
# assertions below would otherwise be satisfied by the prose that DESCRIBES the
# retired call, and the installers deliberately explain why `jq empty` was
# unsound. Counting prose as code would make those assertions unfailable.
code_line_count() {
    grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -c -F -- "$2" | tr -d ' \n'
}

# --- merge + checker helpers -----------------------------------------------
# Every checker takes FILE PATHS so the META-TESTs can run byte-identical
# logic against deliberately mutated merges.

# run_merge <expr> <existing.json> <new.json> <out.json> — mirrors the
# installers' invocation exactly: `jq -s <expr> <existing> <new>`.
run_merge() {
    jq -s "$1" "$2" "$3" > "$4" 2>/dev/null
}

# check_retired_key_deleted <merged.json> — 0 when env.CLAUDE_CODE_EFFORT_LEVEL
# is gone, 1 when it survived the merge, 2 when the file is unusable.
check_retired_key_deleted() {
    [ -f "$1" ] || return 2
    jq empty "$1" >/dev/null 2>&1 || return 2
    if jq -e '(.env // {}) | has("CLAUDE_CODE_EFFORT_LEVEL")' "$1" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# check_key_added <merged.json> <jq-path> <expected> — 0 when the key holds
# the expected value, 1 when it is absent or differs, 2 when unusable.
check_key_added() {
    [ -f "$1" ] || return 2
    jq empty "$1" >/dev/null 2>&1 || return 2
    local actual
    actual=$(jq -r "$2 // \"ABSENT\"" "$1" 2>/dev/null)
    [ "$actual" = "$3" ] || return 1
    return 0
}

# jq_get <file> <filter> — raw scalar read, "ERR" when jq fails.
jq_get() {
    jq -r "$2" "$1" 2>/dev/null || echo "ERR"
}

# jq_sorted <file> <filter> — canonical compact form of a subtree, for
# deep-equality comparisons.
jq_sorted() {
    jq -S -c "$2" "$1" 2>/dev/null || echo "ERR"
}

# --- U0.8 helpers (sections 6m-6q) ------------------------------------------

# extract_dashed_block <file> <name> — the lines strictly between
# `# <name>-START` and `# <name>-END`.
#
# The repo uses TWO sentinel spellings and they are not interchangeable:
# `# BEGIN <name>` / `# END <name>` marks a block a test EXTRACTS, while
# `# <name>-START` / `# <name>-END` marks a block a META-TEST DELETES with sed.
# MERGE-STATUS-LINES is the second kind (an L2 META strips it) and is also
# extracted here, so it needs this reader rather than extract_block.
extract_dashed_block() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 1
    awk -v b="# $name-START" -v e="# $name-END" '
        !inb && index($0, b) { inb = 1; next }
        inb && index($0, e)  { exit }
        inb                  { print }
    ' "$file"
}

# gitignore_from_sh <install.sh> — the .gitignore install.sh ACTUALLY PRODUCES,
# on stdout.
#
# The sentinel block is EXECUTED, not scraped: it is a `cat > .gitignore <<
# 'EOF'` heredoc, and running it is the only way to prove the file that lands on
# an operator's disk carries these lines. Scraping the body would test the test's
# own idea of where a heredoc starts and ends. Runs in a scratch subdirectory
# with `cd`, since the block writes to a relative path exactly as the installer
# does (it runs after `cd "$TARGET"`).
gitignore_from_sh() {
    local file="$1"
    local dir="$WORK/gitignore-exec-$$-$RANDOM"
    mkdir -p "$dir" || return 1
    extract_block "$file" "GENERATED_GITIGNORE" > "$dir/block.sh" || return 1
    ( cd "$dir" && bash ./block.sh >/dev/null 2>&1 ) || return 1
    [ -f "$dir/.gitignore" ] || return 1
    cat "$dir/.gitignore"
    rm -rf "$dir"
}

# gitignore_from_ps <install.ps1> — the same file as install.ps1's line list
# would render it.
#
# One single-quoted entry per line inside the sentinels; `''` is PowerShell's
# escape for a literal quote, so it is un-doubled here. Anything that is not a
# quoted entry (the Write-LfFile call, the closing paren) is skipped, so the
# extraction cannot silently absorb code.
gitignore_from_ps() {
    extract_block "$1" "GENERATED_GITIGNORE" 2>/dev/null \
        | sed -n "s/^[[:space:]]*'\(.*\)'[[:space:]]*$/\1/p" \
        | sed "s/''/'/g"
}

# gitignore_entries — stdin to stdout: the PATTERN lines only (comments and
# blanks dropped), sorted. Used for the "these entries are present" assertions,
# where order is irrelevant; the full-body comparison above is order-sensitive
# on purpose.
gitignore_entries() {
    grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | LC_ALL=C sort
}

# docs_from_surface_sh <workflow-manifest.sh> — the docs/ paths the generator's
# surface enumerates, sorted and space-joined.
docs_from_surface_sh() {
    surface_pairs_sh "$1" | sed -n 's|^workflow:\(docs/.*\)$|\1|p' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# docs_from_surface_ps <install.ps1> — the same, from the PowerShell surface.
docs_from_surface_ps() {
    surface_pairs_ps "$1" | sed -n 's|^workflow:\(docs/.*\)$|\1|p' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# docs_from_copy_block <file> — the docs the COPY LOOP iterates, read from the
# SHIPPED_DOCS sentinel block. Works for both dialects: bash writes
# `SHIPPED_DOCS="a b"`, PowerShell `$ShippedDocs = @("a", "b")`, so every
# docs/-looking token inside the block is collected.
docs_from_copy_block() {
    extract_block "$1" "SHIPPED_DOCS" 2>/dev/null \
        | tr -s ' ",()=' '\n' \
        | grep '^docs/' \
        | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# docs_from_required_sh <install.sh> — the docs entries in install.sh's
# required-source list (the `for required in \` block).
docs_from_required_sh() {
    awk '/^for required in \\$/, /^    ; do$/' "$1" 2>/dev/null \
        | sed -n 's|^[[:space:]]*"\(docs/[^"]*\)".*|\1|p' \
        | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# docs_from_required_ps <install.ps1> — the same, from the $Required array.
docs_from_required_ps() {
    awk '/\$Required = @\(/, /^    \)$/' "$1" 2>/dev/null \
        | sed -n 's|^[[:space:]]*"\(docs/[^"]*\)".*|\1|p' \
        | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# merge_status_lines <file> — the merged-class report SENTENCES a file renders,
# extracted from the MERGE-STATUS-LINES sentinel block and normalised so the two
# dialects are directly comparable. Sorted, one sentence per line.
#
# Normalisation, in order:
#   1. keep only the lines that name one of the two files (the `case` / `switch`
#      scaffolding and the section heading carry no ".json");
#   2. drop everything up to and including the opening quote — `printf '` in
#      bash, `$lines.Add("` in PowerShell;
#   3. drop each dialect's trailing scaffolding: `\n' ;;` / `")`. The two
#      patterns cannot collide, because a bash line never ends `")` and a
#      PowerShell one never ends `\n' ;;`;
#   4. turn Windows separators into forward slashes. That is the ONLY difference
#      the two blocks are allowed to have, so folding it here is what makes the
#      remaining comparison meaningful rather than trivially false.
merge_status_lines() {
    extract_dashed_block "$1" "MERGE-STATUS-LINES" 2>/dev/null \
        | grep -F -- '.json' \
        | sed -e "s/^[^\"']*[\"']//" \
              -e "s/\\\\n' ;;\$//" \
              -e 's/")$//' \
              -e 's/\\/\//g' \
        | LC_ALL=C sort
}

# ===========================================================================
echo "=== Section 0: preflight ==="

assert_eq "preflight: install.sh exists" "yes" \
    "$([ -f "$INSTALL_SH" ] && echo yes || echo no)"
assert_eq "preflight: install.ps1 exists" "yes" \
    "$([ -f "$INSTALL_PS1" ] && echo yes || echo no)"
assert_eq "preflight: jq on PATH" "yes" \
    "$(command -v jq >/dev/null 2>&1 && echo yes || echo no)"

if [ ! -f "$INSTALL_SH" ] || [ ! -f "$INSTALL_PS1" ] || ! command -v jq >/dev/null 2>&1; then
    printf '\nFAILED: %d (preflight; nothing downstream can run)\n' "$FAIL"
    exit 1
fi

# ===========================================================================
echo ""
echo "=== Section 1: expression extraction from the installers (bzy #1) ==="

# assert_extractable <label> <file> <name> — the four properties that make an
# expression followable from source: both sentinels present exactly once, and
# a non-empty extraction that looks like the merge program.
# shellcheck disable=SC2016 # literal `$existing`/`$new` are jq bindings being searched for, never shell expansions
assert_extractable() {
    local label="$1" file="$2" name="$3" expr
    assert_eq "$label: '# BEGIN $name' present exactly once" "1" \
        "$(sentinel_line_count "$file" "# BEGIN $name")"
    assert_eq "$label: '# END $name' present exactly once" "1" \
        "$(sentinel_line_count "$file" "# END $name")"
    expr=$(extract_expr "$file" "$name")
    assert_eq "$label: $name extraction is non-empty" "non-empty" \
        "$([ -n "$(printf '%s' "$expr" | tr -d '[:space:]')" ] && echo non-empty || echo EMPTY)"
    assert_eq "$label: $name extraction binds \$existing and \$new" "yes" \
        "$(printf '%s' "$expr" | grep -q '\.\[0\] as \$existing' \
           && printf '%s' "$expr" | grep -q '\.\[1\] as \$new' \
           && echo yes || echo no)"
}

# assert_extractable_scalar <label> <file> <name> <substring> — the same
# sentinel contract for a single-line expression that carries no $existing/$new
# bindings (the R1-F1 validity gate).
assert_extractable_scalar() {
    local label="$1" file="$2" name="$3" needle="$4" expr
    assert_eq "$label: '# BEGIN $name' present exactly once" "1" \
        "$(sentinel_line_count "$file" "# BEGIN $name")"
    assert_eq "$label: '# END $name' present exactly once" "1" \
        "$(sentinel_line_count "$file" "# END $name")"
    expr=$(extract_expr "$file" "$name")
    assert_eq "$label: $name extraction is non-empty" "non-empty" \
        "$([ -n "$(printf '%s' "$expr" | tr -d '[:space:]')" ] && echo non-empty || echo EMPTY)"
    assert_eq "$label: $name extraction carries the slurp-length check" "yes" \
        "$(printf '%s' "$expr" | grep -qF -- "$needle" && echo yes || echo no)"
}

assert_extractable "install.sh" "$INSTALL_SH" "SETTINGS_MERGE_JQ"
assert_extractable "install.sh" "$INSTALL_SH" "MCP_MERGE_JQ"
assert_extractable "install.ps1" "$INSTALL_PS1" "SETTINGS_MERGE_JQ"
assert_extractable "install.ps1" "$INSTALL_PS1" "MCP_MERGE_JQ"
assert_extractable_scalar "install.sh" "$INSTALL_SH" "JSON_SINGLE_OBJECT_JQ" "length == 1"
assert_extractable_scalar "install.ps1" "$INSTALL_PS1" "JSON_SINGLE_OBJECT_JQ" "length == 1"

SH_SETTINGS_EXPR=$(extract_expr "$INSTALL_SH" "SETTINGS_MERGE_JQ")
SH_MCP_EXPR=$(extract_expr "$INSTALL_SH" "MCP_MERGE_JQ")
SH_VALID_EXPR=$(extract_expr "$INSTALL_SH" "JSON_SINGLE_OBJECT_JQ")
PS_SETTINGS_EXPR=$(extract_expr "$INSTALL_PS1" "SETTINGS_MERGE_JQ")
PS_MCP_EXPR=$(extract_expr "$INSTALL_PS1" "MCP_MERGE_JQ")
PS_VALID_EXPR=$(extract_expr "$INSTALL_PS1" "JSON_SINGLE_OBJECT_JQ")

# Fail LOUDLY and stop: a silent empty extraction would turn every jq run
# below into a vacuous pass. This is bzy deliverable 1's whole point.
if [ -z "$(printf '%s' "$SH_SETTINGS_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$SH_MCP_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$SH_VALID_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$PS_SETTINGS_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$PS_MCP_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$PS_VALID_EXPR" | tr -d '[:space:]')" ]; then
    printf '\nFAILED: %d (expression extraction empty — sentinels missing, renamed,\n' "$FAIL"
    printf '  or the assignment reshaped. Nothing downstream can run.)\n'
    exit 1
fi

# ===========================================================================
echo ""
echo "=== Section 1b: the installers RUN the hoisted expressions ==="
# Without these, someone could hoist the variables, leave the old inline
# expression in the jq call, and every behavioural assertion below would
# still pass while the shipped installer used something else entirely.

# shellcheck disable=SC2016 # the searched-for text IS a literal shell invocation line
assert_eq "wiring: install.sh invokes jq -s \"\$SETTINGS_MERGE_JQ\"" "1" \
    "$(code_line_count "$INSTALL_SH" 'jq -s "$SETTINGS_MERGE_JQ"')"
# shellcheck disable=SC2016 # the searched-for text IS a literal shell invocation line
assert_eq "wiring: install.sh invokes jq -s \"\$MCP_MERGE_JQ\"" "1" \
    "$(code_line_count "$INSTALL_SH" 'jq -s "$MCP_MERGE_JQ"')"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation line
assert_eq "wiring: install.ps1 invokes jq -s \$SettingsMergeJq" "1" \
    "$(code_line_count "$INSTALL_PS1" 'jq -s $SettingsMergeJq')"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation line
assert_eq "wiring: install.ps1 invokes jq -s \$McpMergeJq" "1" \
    "$(code_line_count "$INSTALL_PS1" 'jq -s $McpMergeJq')"

# One definition per file. A second copy of either signature line means the
# expression was duplicated back into an inline call.
assert_eq "wiring: install.sh defines del(.CLAUDE_CODE_EFFORT_LEVEL) exactly once" "1" \
    "$(code_line_count "$INSTALL_SH" 'del(.CLAUDE_CODE_EFFORT_LEVEL)')"
assert_eq "wiring: install.ps1 defines del(.CLAUDE_CODE_EFFORT_LEVEL) exactly once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'del(.CLAUDE_CODE_EFFORT_LEVEL)')"
assert_eq "wiring: install.sh defines del(.mcpServers[\"code-context\"]) exactly once" "1" \
    "$(code_line_count "$INSTALL_SH" 'del(.mcpServers["code-context"])')"
assert_eq "wiring: install.ps1 defines del(.mcpServers[\"code-context\"]) exactly once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'del(.mcpServers["code-context"])')"

# The THIRD duplicated jq expression: the bare-${VAR} detector that names an
# operator server whose config Claude Code cannot expand. It is not sentinel-
# wrapped (it is a readout probe, not a merge), but it is duplicated across the
# two installers just the same — so pin its detector line FILE-TO-FILE. No
# copied literal: both sides come from the installers, only the anchor
# `any(test(` is typed here.
probe_line() {
    grep -F -- 'any(test(' "$1" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
assert_eq "bare-var probe: install.sh carries exactly one detector line" "1" \
    "$(probe_line "$INSTALL_SH" | grep -c . | tr -d ' \n')"
assert_eq "bare-var probe: install.ps1 carries exactly one detector line" "1" \
    "$(probe_line "$INSTALL_PS1" | grep -c . | tr -d ' \n')"
assert_eq "bare-var probe: the two detector lines are byte-identical" \
    "$(probe_line "$INSTALL_SH")" "$(probe_line "$INSTALL_PS1")"

# R1-F1 wiring: BOTH merges must gate on the validity helper, and the retired
# `jq empty` oracle (which accepts empty AND multi-document input) must be gone
# from both installers. Two call sites each: .mcp.json and settings.json.
assert_eq "wiring: install.sh gates both merges on json_single_object" "2" \
    "$(code_line_count "$INSTALL_SH" 'if json_single_object "$')"
assert_eq "wiring: install.sh defines json_single_object() once" "1" \
    "$(code_line_count "$INSTALL_SH" 'json_single_object() {')"
# shellcheck disable=SC2016 # the searched-for text IS a literal shell invocation line
assert_eq "wiring: install.sh runs the gate as jq -s -e" "1" \
    "$(code_line_count "$INSTALL_SH" 'jq -s -e "$JSON_SINGLE_OBJECT_JQ"')"
assert_eq "wiring: install.ps1 gates both merges on Test-JsonSingleObject" "2" \
    "$(code_line_count "$INSTALL_PS1" 'if (Test-JsonSingleObject $')"
assert_eq "wiring: install.ps1 defines Test-JsonSingleObject once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'function Test-JsonSingleObject')"
# The retired oracle: `jq empty` must appear in NEITHER installer. It is the
# exact check R1-F1 proved unsound, so its return is the regression to catch.
assert_eq "wiring: install.sh no longer uses the retired 'jq empty' oracle" "0" \
    "$(code_line_count "$INSTALL_SH" 'jq empty')"
assert_eq "wiring: install.ps1 no longer uses the retired 'jq empty' oracle" "0" \
    "$(code_line_count "$INSTALL_PS1" 'jq empty')"

# ===========================================================================
echo ""
echo "=== Section 2: settings merge battery (bzy #2) ==="

# The shipped values the add-if-absent clauses hand to a pre-v3.5 tree. If
# .claude/settings.json ever loses either key, the clause would write a null
# into the operator's file — so assert the real shipped surface first.
assert_eq "shipped settings.json carries effortLevel" "yes" \
    "$([ "$(jq_get "$SHIPPED_SETTINGS" '.effortLevel // "ABSENT"')" != "ABSENT" ] && echo yes || echo no)"
assert_eq "shipped settings.json carries statusLine" "yes" \
    "$([ "$(jq_get "$SHIPPED_SETTINGS" '.statusLine.command // "ABSENT"')" != "ABSENT" ] && echo yes || echo no)"

# --- fixtures --------------------------------------------------------------
# EXISTING (pre-v3.5 lineage): the retired env pin, an operator env key, an
# operator permissions block, an operator top-level key, stale hooks — and
# NO effortLevel / statusLine.
NEW_SETTINGS="$WORK/new-settings.json"
OLD_LEGACY="$WORK/existing-legacy.json"
OLD_PINNED="$WORK/existing-pinned.json"

cat > "$OLD_LEGACY" <<'JSON'
{
  "additionalDirectories": ["./legacy"],
  "env": {
    "CLAUDE_CODE_EFFORT_LEVEL": "xhigh",
    "OPERATOR_KEY": "operator-value",
    "MAX_THINKING_TOKENS": "32000"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash legacy-session-start.sh" }
        ]
      }
    ]
  },
  "permissions": { "allow": ["Read", "Bash", "OperatorTool"] },
  "operatorTopLevel": "keep-me"
}
JSON

# VARIANT: the operator pinned effortLevel and statusLine themselves, and has
# no permissions block. Proves both directions of add-if-absent.
cat > "$OLD_PINNED" <<'JSON'
{
  "effortLevel": "high",
  "env": { "OPERATOR_KEY": "operator-value" },
  "statusLine": { "type": "command", "command": "bash operator-statusline.sh" },
  "hooks": {}
}
JSON

# SHIPPED NEW: modelled on .claude/settings.json (same key shape, same
# effortLevel/statusLine/env/hook contract) with fixture-local values so the
# assertions stay stable when the real file's values move.
cat > "$NEW_SETTINGS" <<'JSON'
{
  "additionalDirectories": ["../"],
  "effortLevel": "xhigh",
  "env": {
    "MAX_THINKING_TOKENS": "64000",
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1",
    "CLAUDE_LATEST_OPUS": "claude-opus-5"
  },
  "statusLine": {
    "type": "command",
    "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/statusline.sh\""
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-start.sh\"", "timeout": 30000 }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/verify-before-stop.sh\"", "timeout": 1320000 }
        ]
      }
    ]
  },
  "permissions": { "allow": ["Read", "Write", "Edit", "Bash", "Task"] }
}
JSON

# Expected values read back from the fixture (never re-typed as a literal —
# a typo in an expectation is indistinguishable from a real failure).
NEW_STATUSLINE=$(jq_get "$NEW_SETTINGS" '.statusLine.command')
NEW_SESSIONSTART=$(jq_get "$NEW_SETTINGS" '.hooks.SessionStart[0].hooks[0].command')

MERGED_LEGACY="$WORK/merged-legacy.json"
MERGE_RC=0
run_merge "$SH_SETTINGS_EXPR" "$OLD_LEGACY" "$NEW_SETTINGS" "$MERGED_LEGACY" || MERGE_RC=$?
assert_eq "settings: extracted expression runs under real jq (exit 0)" "0" "$MERGE_RC"
assert_eq "settings: merged output is valid JSON" "0" \
    "$(jq empty "$MERGED_LEGACY" >/dev/null 2>&1 && echo 0 || echo 1)"

# The TM13 claim, now mechanical.
RC=0; check_retired_key_deleted "$MERGED_LEGACY" || RC=$?
assert_eq "settings: retired env.CLAUDE_CODE_EFFORT_LEVEL is deleted" "0" "$RC"

assert_eq "settings: operator env key survives the union" "operator-value" \
    "$(jq_get "$MERGED_LEGACY" '.env.OPERATOR_KEY // "ABSENT"')"
assert_eq "settings: shipped env key CLAUDE_LATEST_OPUS arrives" "claude-opus-5" \
    "$(jq_get "$MERGED_LEGACY" '.env.CLAUDE_LATEST_OPUS // "ABSENT"')"
assert_eq "settings: shipped env key CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH arrives" "1" \
    "$(jq_get "$MERGED_LEGACY" '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH // "ABSENT"')"
assert_eq "settings: shipped value wins on env collision (MAX_THINKING_TOKENS)" "64000" \
    "$(jq_get "$MERGED_LEGACY" '.env.MAX_THINKING_TOKENS // "ABSENT"')"

assert_eq "settings: hooks are replaced wholesale (SessionStart is the shipped one)" \
    "$NEW_SESSIONSTART" \
    "$(jq_get "$MERGED_LEGACY" '.hooks.SessionStart[0].hooks[0].command // "ABSENT"')"
assert_eq "settings: newly-shipped hook event arrives (Stop)" "true" \
    "$(jq_get "$MERGED_LEGACY" '.hooks | has("Stop")')"
assert_eq "settings: the stale hook command is gone" "absent" \
    "$(jq -c '.hooks' "$MERGED_LEGACY" 2>/dev/null | grep -q 'legacy-session-start' && echo present || echo absent)"

assert_eq "settings: operator permissions preserved (OperatorTool still allowed)" "true" \
    "$(jq_get "$MERGED_LEGACY" '(.permissions.allow // []) | index("OperatorTool") != null')"
assert_eq "settings: operator permissions NOT widened to the shipped list" "false" \
    "$(jq_get "$MERGED_LEGACY" '(.permissions.allow // []) | index("Task") != null')"

# The v4.1 add-if-absent clauses.
RC=0; check_key_added "$MERGED_LEGACY" '.effortLevel' "xhigh" || RC=$?
assert_eq "settings: effortLevel is ADDED from the shipped file" "0" "$RC"
RC=0; check_key_added "$MERGED_LEGACY" '.statusLine.command' "$NEW_STATUSLINE" || RC=$?
assert_eq "settings: statusLine is ADDED from the shipped file" "0" "$RC"

assert_eq "settings: operator top-level key survives" "keep-me" \
    "$(jq_get "$MERGED_LEGACY" '.operatorTopLevel // "ABSENT"')"
assert_eq "settings: additionalDirectories comes from the shipped file" '["../"]' \
    "$(jq_sorted "$MERGED_LEGACY" '.additionalDirectories')"

# --- operator-pinned variant ----------------------------------------------
MERGED_PINNED="$WORK/merged-pinned.json"
MERGE_RC=0
run_merge "$SH_SETTINGS_EXPR" "$OLD_PINNED" "$NEW_SETTINGS" "$MERGED_PINNED" || MERGE_RC=$?
assert_eq "settings(pinned): merge runs (exit 0)" "0" "$MERGE_RC"
assert_eq "settings(pinned): operator effortLevel is PRESERVED, not overwritten" "high" \
    "$(jq_get "$MERGED_PINNED" '.effortLevel // "ABSENT"')"
assert_eq "settings(pinned): operator statusLine is PRESERVED" "bash operator-statusline.sh" \
    "$(jq_get "$MERGED_PINNED" '.statusLine.command // "ABSENT"')"
assert_eq "settings(pinned): absent permissions block is ADDED from the shipped file" "true" \
    "$(jq_get "$MERGED_PINNED" '(.permissions.allow // []) | index("Task") != null')"

# --- R1-F2: add-if-absent means PRESENCE, not truthiness -------------------
# `if $existing.effortLevel then` reads an explicit null or false as "absent"
# and overwrites it. An operator who deliberately wrote `"effortLevel": null`
# (or `false`) owns that key just as much as one who wrote "high" — the upgrade
# must not silently replace it with the shipped value. The permissions clause
# carried the identical defect since v4.0.0 and is covered here too.
OLD_FALSY="$WORK/existing-falsy.json"
cat > "$OLD_FALSY" <<'JSON'
{
  "effortLevel": null,
  "statusLine": false,
  "permissions": null,
  "env": { "OPERATOR_KEY": "operator-value" },
  "hooks": {}
}
JSON

MERGED_FALSY="$WORK/merged-falsy.json"
MERGE_RC=0
run_merge "$SH_SETTINGS_EXPR" "$OLD_FALSY" "$NEW_SETTINGS" "$MERGED_FALSY" || MERGE_RC=$?
assert_eq "settings(falsy): merge runs (exit 0)" "0" "$MERGE_RC"
# Compact JSON, not raw: `jq -r` renders null as the string "null", which is
# indistinguishable from a literal "null" value.
assert_eq "settings(falsy): operator effortLevel:null is PRESERVED as null" "null" \
    "$(jq -c '.effortLevel' "$MERGED_FALSY" 2>/dev/null)"
assert_eq "settings(falsy): the effortLevel key is still present (not deleted)" "true" \
    "$(jq -c 'has("effortLevel")' "$MERGED_FALSY" 2>/dev/null)"
assert_eq "settings(falsy): operator statusLine:false is PRESERVED as false" "false" \
    "$(jq -c '.statusLine' "$MERGED_FALSY" 2>/dev/null)"
assert_eq "settings(falsy): operator permissions:null is PRESERVED as null" "null" \
    "$(jq -c '.permissions' "$MERGED_FALSY" 2>/dev/null)"
# Sanity: the rest of the merge still happened, so the assertions above are
# about presence semantics and not about a merge that silently did nothing.
assert_eq "settings(falsy): shipped hooks still arrived" "true" \
    "$(jq_get "$MERGED_FALSY" '.hooks | has("Stop")')"
assert_eq "settings(falsy): operator env key still preserved" "operator-value" \
    "$(jq_get "$MERGED_FALSY" '.env.OPERATOR_KEY // "ABSENT"')"

# --- idempotency -----------------------------------------------------------
# Re-running Update against an already-merged file must be a no-op. Compare
# canonicalised (jq -S) forms so key ORDER never decides the verdict.
MERGED_TWICE="$WORK/merged-legacy-twice.json"
MERGE_RC=0
run_merge "$SH_SETTINGS_EXPR" "$MERGED_LEGACY" "$NEW_SETTINGS" "$MERGED_TWICE" || MERGE_RC=$?
assert_eq "settings: second merge runs (exit 0)" "0" "$MERGE_RC"
jq -S . "$MERGED_LEGACY" > "$WORK/norm-1.json" 2>/dev/null
jq -S . "$MERGED_TWICE" > "$WORK/norm-2.json" 2>/dev/null
assert_eq "settings: merge is idempotent (normalised outputs byte-identical)" "same" \
    "$(cmp -s "$WORK/norm-1.json" "$WORK/norm-2.json" && echo same || echo different)"

# ===========================================================================
echo ""
echo "=== Section 3: .mcp.json merge battery ==="

# Real shipped config sanity — the MCP battery's "new" side IS the file the
# installer copies, so a regression there must surface here, not silently
# weaken the fixtures.
assert_eq "shipped .mcp.json parses" "0" \
    "$(jq empty "$SHIPPED_MCP" >/dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "shipped .mcp.json declares bd and code-graph, not code-context" "true" \
    "$(jq_get "$SHIPPED_MCP" '((.mcpServers | has("bd")) and (.mcpServers | has("code-graph")) and ((.mcpServers | has("code-context")) | not))')"

# EXISTING: an operator server (with a deliberately BARE ${SOMEVAR} arg —
# the installer must not rewrite operator config), the stale code-context
# entry, and an outdated bd entry carrying the bare ${CLAUDE_PROJECT_DIR}
# form that v3.5 shipped.
OLD_MCP="$WORK/existing-mcp.json"
cat > "$OLD_MCP" <<'JSON'
{
  "_comment": "operator's own note — must survive the upgrade",
  "operatorTopLevel": { "keep": true },
  "mcpServers": {
    "myserver": {
      "type": "stdio",
      "command": "node",
      "args": ["${SOMEVAR}/tools/myserver.js"],
      "env": { "MY_TOKEN": "${MY_TOKEN}" }
    },
    "code-context": {
      "type": "stdio",
      "command": "node",
      "args": ["${CLAUDE_PROJECT_DIR}/.claude/mcp/code-context-mcp/bin/code-context-mcp.js"],
      "env": {}
    },
    "bd": {
      "type": "stdio",
      "command": "node",
      "args": ["${CLAUDE_PROJECT_DIR}/.claude/mcp/bd-mcp/bin/bd-mcp.js"],
      "env": {}
    }
  }
}
JSON

MERGED_MCP="$WORK/merged-mcp.json"
MERGE_RC=0
run_merge "$SH_MCP_EXPR" "$OLD_MCP" "$SHIPPED_MCP" "$MERGED_MCP" || MERGE_RC=$?
assert_eq "mcp: extracted expression runs under real jq (exit 0)" "0" "$MERGE_RC"
assert_eq "mcp: merged output is valid JSON" "0" \
    "$(jq empty "$MERGED_MCP" >/dev/null 2>&1 && echo 0 || echo 1)"

assert_eq "mcp: operator server 'myserver' passes through verbatim" \
    "$(jq_sorted "$OLD_MCP" '.mcpServers.myserver')" \
    "$(jq_sorted "$MERGED_MCP" '.mcpServers.myserver')"
# shellcheck disable=SC2016 # `${SOMEVAR}` is the JSON payload under test, not a shell expansion
assert_eq "mcp: operator's bare \${SOMEVAR} is NOT rewritten by the merge" "true" \
    "$(jq_get "$MERGED_MCP" '.mcpServers.myserver.args[0] | contains("${SOMEVAR}")')"

assert_eq "mcp: retired code-context entry is deleted" "false" \
    "$(jq_get "$MERGED_MCP" '.mcpServers | has("code-context")')"

assert_eq "mcp: bd entry equals the shipped entry" \
    "$(jq_sorted "$SHIPPED_MCP" '.mcpServers.bd')" \
    "$(jq_sorted "$MERGED_MCP" '.mcpServers.bd')"
assert_eq "mcp: code-graph entry equals the shipped entry" \
    "$(jq_sorted "$SHIPPED_MCP" '.mcpServers["code-graph"]')" \
    "$(jq_sorted "$MERGED_MCP" '.mcpServers["code-graph"]')"
# The upgrade payload the plan asks for by name: the v3.5 bare form becomes
# the diagnostics-clean default form.
# shellcheck disable=SC2016 # `${CLAUDE_PROJECT_DIR:-.}` is the JSON payload under test
assert_eq "mcp: bd args carry the \${CLAUDE_PROJECT_DIR:-.} default form" "true" \
    "$(jq_get "$MERGED_MCP" '.mcpServers.bd.args[0] | contains("${CLAUDE_PROJECT_DIR:-.}")')"
assert_eq "mcp: no bd arg left in the bare \${CLAUDE_PROJECT_DIR} form" "false" \
    "$(jq_get "$MERGED_MCP" '.mcpServers.bd.args[0] | test("\\$\\{CLAUDE_PROJECT_DIR\\}")')"

assert_eq "mcp: operator top-level key survives" "true" \
    "$(jq_get "$MERGED_MCP" '.operatorTopLevel.keep')"
assert_eq "mcp: operator _comment is NOT replaced by the shipped one" \
    "operator's own note — must survive the upgrade" \
    "$(jq_get "$MERGED_MCP" '._comment // "ABSENT"')"
assert_eq "mcp: server set is exactly bd + code-graph + myserver" \
    "[\"bd\",\"code-graph\",\"myserver\"]" \
    "$(jq -c '.mcpServers | keys' "$MERGED_MCP" 2>/dev/null)"

MERGED_MCP_TWICE="$WORK/merged-mcp-twice.json"
MERGE_RC=0
run_merge "$SH_MCP_EXPR" "$MERGED_MCP" "$SHIPPED_MCP" "$MERGED_MCP_TWICE" || MERGE_RC=$?
assert_eq "mcp: second merge runs (exit 0)" "0" "$MERGE_RC"
jq -S . "$MERGED_MCP" > "$WORK/mcp-norm-1.json" 2>/dev/null
jq -S . "$MERGED_MCP_TWICE" > "$WORK/mcp-norm-2.json" 2>/dev/null
assert_eq "mcp: merge is idempotent (normalised outputs byte-identical)" "same" \
    "$(cmp -s "$WORK/mcp-norm-1.json" "$WORK/mcp-norm-2.json" && echo same || echo different)"

# ===========================================================================
echo ""
echo "=== Section 3b: merge-input validity gate (R1-F1) ==="
# Both merges bind positionally (.[0] existing, .[1] new) after `jq -s`. That
# binding is only sound if EACH input file holds exactly one JSON document.
# `jq empty` — the oracle this gate replaced — exits 0 for an empty file and
# for a multi-document stream, so a two-document target pushed the shipped file
# out to .[2] and produced a config with none of the shipped servers.

VF_SINGLE="$WORK/vf-single.json"
VF_EMPTY="$WORK/vf-empty.json"
VF_BLANK="$WORK/vf-blank.json"
VF_MULTI="$WORK/vf-multi.json"
VF_MALFORMED="$WORK/vf-malformed.json"
VF_ARRAY="$WORK/vf-array.json"
VF_SCALAR="$WORK/vf-scalar.json"

printf '{"mcpServers":{"myserver":{"command":"node"}}}\n' > "$VF_SINGLE"
: > "$VF_EMPTY"
printf '\n   \n' > "$VF_BLANK"
# Two documents: the exact shape that silently demoted the shipped config.
printf '{"mcpServers":{"myserver":{"command":"node"}}}\n{"mcpServers":{"decoy":{"command":"sh"}}}\n' > "$VF_MULTI"
printf '{ "mcpServers": \n' > "$VF_MALFORMED"
printf '[1,2,3]\n' > "$VF_ARRAY"
printf '42\n' > "$VF_SCALAR"

# validator_verdict <expr> <file> — "accepted"/"rejected", running the
# EXTRACTED gate exactly as install.sh's json_single_object() does.
validator_verdict() {
    if jq -s -e "$1" "$2" >/dev/null 2>&1; then echo accepted; else echo rejected; fi
}

# retired_oracle_verdict <file> — what the pre-fix `jq empty` check said. Kept
# so the regression is documented mechanically rather than in a comment.
retired_oracle_verdict() {
    if jq empty "$1" >/dev/null 2>&1; then echo accepted; else echo rejected; fi
}

assert_eq "gate: a single JSON object is ACCEPTED" "accepted" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_SINGLE")"
assert_eq "gate: the real shipped .mcp.json is ACCEPTED" "accepted" \
    "$(validator_verdict "$SH_VALID_EXPR" "$SHIPPED_MCP")"
assert_eq "gate: the real shipped settings.json is ACCEPTED" "accepted" \
    "$(validator_verdict "$SH_VALID_EXPR" "$SHIPPED_SETTINGS")"
assert_eq "gate: an EMPTY file is REJECTED (takes the loud fallback)" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_EMPTY")"
assert_eq "gate: a whitespace-only file is REJECTED" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_BLANK")"
assert_eq "gate: a MULTI-DOCUMENT file is REJECTED (takes the loud fallback)" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_MULTI")"
assert_eq "gate: a malformed file is REJECTED" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_MALFORMED")"
assert_eq "gate: a top-level ARRAY document is REJECTED (unindexable by the merge)" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_ARRAY")"
assert_eq "gate: a top-level scalar document is REJECTED" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_SCALAR")"

# The regression witness: the retired oracle accepted exactly the two shapes
# that corrupt the merge. If these two ever flip to "rejected", `jq empty`
# changed semantics and this whole section's premise needs revisiting.
assert_eq "gate: the retired 'jq empty' oracle ACCEPTED an empty file (the R1-F1 defect)" "accepted" \
    "$(retired_oracle_verdict "$VF_EMPTY")"
assert_eq "gate: the retired 'jq empty' oracle ACCEPTED a multi-document file (the R1-F1 defect)" "accepted" \
    "$(retired_oracle_verdict "$VF_MULTI")"

# CONSEQUENCE PROOF — what the gate is actually protecting. Feed the merge the
# multi-document target it used to accept and show the shipped servers vanish.
VF_MERGED="$WORK/vf-merged-multidoc.json"
run_merge "$SH_MCP_EXPR" "$VF_MULTI" "$SHIPPED_MCP" "$VF_MERGED" || true
assert_eq "gate: consequence — merging an accepted multi-doc target DROPS shipped bd" "false" \
    "$(jq_get "$VF_MERGED" '.mcpServers | has("bd")')"
assert_eq "gate: consequence — it DROPS shipped code-graph too" "false" \
    "$(jq_get "$VF_MERGED" '.mcpServers | has("code-graph")')"
assert_eq "gate: consequence — the target's SECOND document won the \$new binding" "true" \
    "$(jq_get "$VF_MERGED" '.mcpServers | has("decoy")')"
assert_eq "gate: which is why the gate rejects that input before the merge runs" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_MULTI")"

assert_eq "gate: JSON_SINGLE_OBJECT_JQ is token-identical in both installers" \
    "$(printf '%s' "$SH_VALID_EXPR" | normalize_expr)" \
    "$(printf '%s' "$PS_VALID_EXPR" | normalize_expr)"

# ===========================================================================
echo ""
echo "=== Section 4: expression identity, install.sh <-> install.ps1 (bzy #3) ==="

SH_SETTINGS_NORM=$(printf '%s' "$SH_SETTINGS_EXPR" | normalize_expr)
PS_SETTINGS_NORM=$(printf '%s' "$PS_SETTINGS_EXPR" | normalize_expr)
SH_MCP_NORM=$(printf '%s' "$SH_MCP_EXPR" | normalize_expr)
PS_MCP_NORM=$(printf '%s' "$PS_MCP_EXPR" | normalize_expr)

# Two empty strings compare equal. Pin a floor so the identity assertions
# cannot pass vacuously if extraction ever degrades to whitespace.
assert_eq "identity: normalised bash settings expression is substantial (>100 chars)" "yes" \
    "$([ "${#SH_SETTINGS_NORM}" -gt 100 ] && echo yes || echo no)"
assert_eq "identity: normalised bash mcp expression is substantial (>60 chars)" "yes" \
    "$([ "${#SH_MCP_NORM}" -gt 60 ] && echo yes || echo no)"

assert_eq "identity: SETTINGS_MERGE_JQ is token-identical in both installers" \
    "$SH_SETTINGS_NORM" "$PS_SETTINGS_NORM"
assert_eq "identity: MCP_MERGE_JQ is token-identical in both installers" \
    "$SH_MCP_NORM" "$PS_MCP_NORM"

# ===========================================================================
echo ""
echo "=== Section 5: META-TESTs (bzy #4) ==="
# Each META mutates a COPY and asserts the corresponding check above FAILS.
# Without them, a checker that always returns 0 would look identical to a
# passing suite.

# --- META 1: drop the del() call; the retired key must survive ------------
META_EXPR_NO_DEL=$(printf '%s' "$SH_SETTINGS_EXPR" | sed 's/ | del(\.CLAUDE_CODE_EFFORT_LEVEL)//')
assert_eq "META 1: the mutation actually changed the expression" "changed" \
    "$([ "$META_EXPR_NO_DEL" != "$SH_SETTINGS_EXPR" ] && echo changed || echo UNCHANGED)"
META_MERGED="$WORK/meta-no-del.json"
META_RC=0
run_merge "$META_EXPR_NO_DEL" "$OLD_LEGACY" "$NEW_SETTINGS" "$META_MERGED" || META_RC=$?
assert_eq "META 1: the mutated expression is still valid jq (exit 0)" "0" "$META_RC"
META_RC=0; check_retired_key_deleted "$META_MERGED" || META_RC=$?
assert_eq "META 1: without del(), the retired-key check FAILS (returns 1)" "1" "$META_RC"
assert_eq "META 1: and the retired key is demonstrably still there" "xhigh" \
    "$(jq_get "$META_MERGED" '.env.CLAUDE_CODE_EFFORT_LEVEL // "ABSENT"')"

# --- META 2: drop the effortLevel add-if-absent clause --------------------
# shellcheck disable=SC2016 # `$new` is jq program text inside a sed pattern
META_EXPR_NO_EFFORT=$(printf '%s' "$SH_SETTINGS_EXPR" | sed '/\.effortLevel = \$new\.effortLevel/d')
assert_eq "META 2: the mutation actually changed the expression" "changed" \
    "$([ "$META_EXPR_NO_EFFORT" != "$SH_SETTINGS_EXPR" ] && echo changed || echo UNCHANGED)"
META_MERGED_2="$WORK/meta-no-effort-clause.json"
META_RC=0
run_merge "$META_EXPR_NO_EFFORT" "$OLD_LEGACY" "$NEW_SETTINGS" "$META_MERGED_2" || META_RC=$?
assert_eq "META 2: the mutated expression is still valid jq (exit 0)" "0" "$META_RC"
META_RC=0; check_key_added "$META_MERGED_2" '.effortLevel' "xhigh" || META_RC=$?
assert_eq "META 2: without the clause, the added-key check FAILS (returns 1)" "1" "$META_RC"
# The surgical proof: only effortLevel went missing; statusLine still lands.
META_RC=0; check_key_added "$META_MERGED_2" '.statusLine.command' "$NEW_STATUSLINE" || META_RC=$?
assert_eq "META 2: the mutation is surgical — statusLine still lands" "0" "$META_RC"

# --- META 3: break one token in a COPY of the ps1 literal -----------------
# shellcheck disable=SC2016 # `$new`/`$existing` are jq program text inside a sed pattern
META_PS_EXPR=$(printf '%s' "$PS_SETTINGS_EXPR" | sed 's/\.hooks = \$new\.hooks/.hooks = $existing.hooks/')
assert_eq "META 3: the mutation actually changed the ps1 copy" "changed" \
    "$([ "$META_PS_EXPR" != "$PS_SETTINGS_EXPR" ] && echo changed || echo UNCHANGED)"
META_PS_NORM=$(printf '%s' "$META_PS_EXPR" | normalize_expr)
assert_eq "META 3: one drifted token makes the identity check FAIL" "different" \
    "$([ "$SH_SETTINGS_NORM" = "$META_PS_NORM" ] && echo same || echo different)"
# Companion: normalisation alone is not what makes them differ — the
# unmutated ps1 literal still matches after the same normalisation.
assert_eq "META 3 companion: the unmutated ps1 literal still matches" "same" \
    "$([ "$SH_SETTINGS_NORM" = "$PS_SETTINGS_NORM" ] && echo same || echo different)"

# --- META 4: extraction from a file with no sentinels ---------------------
# Proves section 1's fail-loud arm is reachable: a renamed/removed sentinel
# yields an empty extraction and a zero sentinel count, not a silent pass.
META_NO_SENTINEL="$WORK/no-sentinels.sh"
cat > "$META_NO_SENTINEL" <<'FIXTURE'
#!/bin/bash
SETTINGS_MERGE_JQ='
    .[0] as $existing |
    .[1] as $new |
    $existing | .hooks = $new.hooks
'
jq -s "$SETTINGS_MERGE_JQ" a.json b.json
FIXTURE
assert_eq "META 4: a file without sentinels yields an EMPTY extraction" "EMPTY" \
    "$([ -n "$(extract_expr "$META_NO_SENTINEL" "SETTINGS_MERGE_JQ" | tr -d '[:space:]')" ] && echo non-empty || echo EMPTY)"
assert_eq "META 4: and its BEGIN-sentinel count is 0" "0" \
    "$(sentinel_line_count "$META_NO_SENTINEL" "# BEGIN SETTINGS_MERGE_JQ")"

# --- META 5: a duplicated definition is caught ----------------------------
# The drift shape this spec exists to prevent: a second copy pasted back in.
META_DUP="$WORK/duplicated.sh"
{
    cat "$META_NO_SENTINEL"
    printf '# BEGIN SETTINGS_MERGE_JQ\n'
    printf 'SETTINGS_MERGE_JQ_COPY=1\n'
    printf '# END SETTINGS_MERGE_JQ\n'
    printf '# BEGIN SETTINGS_MERGE_JQ\n'
    printf 'SETTINGS_MERGE_JQ_COPY2=1\n'
    printf '# END SETTINGS_MERGE_JQ\n'
} > "$META_DUP"
assert_eq "META 5: two definitions make the exactly-once check FAIL (count 2)" "2" \
    "$(sentinel_line_count "$META_DUP" "# BEGIN SETTINGS_MERGE_JQ")"

# --- META 6 (R1-F1): weaken the gate back to pre-fix semantics -------------
# `length >= 1` is exactly what `jq empty` meant: "at least one document parses".
# Under it the multi-document rejection must FAIL — which is the assertion the
# whole of section 3b rests on.
META_VALID_WEAK=$(printf '%s' "$SH_VALID_EXPR" | sed 's/length == 1/length >= 1/')
assert_eq "META 6: the mutation actually changed the gate expression" "changed" \
    "$([ "$META_VALID_WEAK" != "$SH_VALID_EXPR" ] && echo changed || echo UNCHANGED)"
assert_eq "META 6: the weakened gate is still valid jq (single object accepted)" "accepted" \
    "$(validator_verdict "$META_VALID_WEAK" "$VF_SINGLE")"
assert_eq "META 6: with length >= 1 the MULTI-DOC rejection FAILS (accepted again)" "accepted" \
    "$(validator_verdict "$META_VALID_WEAK" "$VF_MULTI")"
# And the object arm is separately load-bearing: drop it and an array passes.
META_VALID_NOOBJ=$(printf '%s' "$SH_VALID_EXPR" | sed 's/ and (\.\[0\] | type == "object")//')
assert_eq "META 6: dropping the object arm actually changed the expression" "changed" \
    "$([ "$META_VALID_NOOBJ" != "$SH_VALID_EXPR" ] && echo changed || echo UNCHANGED)"
assert_eq "META 6: without the object arm a top-level ARRAY is accepted again" "accepted" \
    "$(validator_verdict "$META_VALID_NOOBJ" "$VF_ARRAY")"

# --- META 7 (R1-F2): revert the presence guard to truthiness ---------------
# The pre-fix shape. Under it an operator's explicit null must be clobbered —
# so the null-preservation assertion FAILS, proving it is not vacuous.
# shellcheck disable=SC2016 # `$existing` is jq program text inside sed patterns
META_EXPR_TRUTHY=$(printf '%s' "$SH_SETTINGS_EXPR" \
    | sed -e 's/(\$existing | has("effortLevel"))/$existing.effortLevel/' \
          -e 's/(\$existing | has("statusLine"))/$existing.statusLine/')
assert_eq "META 7: the mutation actually changed the expression" "changed" \
    "$([ "$META_EXPR_TRUTHY" != "$SH_SETTINGS_EXPR" ] && echo changed || echo UNCHANGED)"
META_MERGED_3="$WORK/meta-truthiness.json"
META_RC=0
run_merge "$META_EXPR_TRUTHY" "$OLD_FALSY" "$NEW_SETTINGS" "$META_MERGED_3" || META_RC=$?
assert_eq "META 7: the mutated expression is still valid jq (exit 0)" "0" "$META_RC"
assert_eq "META 7: under truthiness the operator's effortLevel:null is CLOBBERED" '"xhigh"' \
    "$(jq -c '.effortLevel' "$META_MERGED_3" 2>/dev/null)"
# The operator wrote a boolean; under truthiness it comes back as the shipped
# statusLine OBJECT. Comparing types states the clobber unambiguously.
assert_eq "META 7: under truthiness the operator's statusLine:false is CLOBBERED (boolean -> shipped object)" "object" \
    "$(jq -r '.statusLine | type' "$META_MERGED_3" 2>/dev/null)"
# The surgical proof: permissions was NOT part of this mutation, so it still
# survives — a blanket breakage would have taken it out too.
assert_eq "META 7: the mutation is surgical — permissions:null still preserved" "null" \
    "$(jq -c '.permissions' "$META_MERGED_3" 2>/dev/null)"

# ===========================================================================
echo ""
echo "=== Section 6: install.ps1 upgrade-machinery parity (U0.7) ==="

# --- helpers used only by sections 6 and 7 ---------------------------------

# text_line_count <file> <literal> — fixed-string line count over ALL lines,
# comments included. The companion to code_line_count: some of the parity
# subjects below ARE prose (the corrected signal-(b) explanation, the sentinel
# comments), and those must be counted where they live.
text_line_count() {
    grep -c -F -- "$2" "$1" 2>/dev/null | tr -d ' \n'
}

# probe_readout <file> — the no-change probe's message from the first `;` to the
# end of the sentence, extracted FROM THE FILE. Everything before that point is
# the interpolated version variable, spelled differently in the two dialects
# ($SOURCE_VERSION_LABEL vs $SourceVersionLabel), so the tail is the comparable
# part. Only the anchor `already at ` is typed here.
#
# The final substitution RESOLVES install.ps1's composed em dash (R1-F1): that
# file has no byte-order mark, so a literal UTF-8 em dash would be decoded by
# Windows PowerShell 5.1 as cp1252 and its trailing 0x94 byte — U+201D, a
# DOUBLE-QUOTE CHARACTER in the PowerShell grammar — would close the string and
# break the whole script's parse. The character is therefore built at output time
# and resolved back here, so this assertion still compares the sentence the two
# installers RENDER rather than the way each spells it.
probe_readout() {
    # shellcheck disable=SC2016 # the sed script matches literal PowerShell source, never an expansion
    grep -F -- 'already at ' "$1" 2>/dev/null \
        | grep -v '^[[:space:]]*#' \
        | head -1 \
        | sed -e 's/^.*already at //' -e 's/".*$//' -e 's/^[^;]*//' \
              -e 's/\$(\[char\]0x2014)/—/g'
}

# nonascii_outside_comments <file> — how many lines carry a byte above 0x7F while
# NOT being a whole-line comment. MUST be 0 for both .ps1 files (R1-F1).
#
# THE RULE AND WHY IT IS THIS SHAPE. Windows PowerShell 5.1 decodes a BOM-less
# .ps1 as the ANSI code page. A UTF-8 em dash (E2 80 94) becomes three cp1252
# characters ending in 0x94 = U+201D; an en dash (E2 80 93) ends in 0x93 =
# U+201C. The PowerShell grammar counts U+201C/201D/201E as double-quote
# characters and U+2018/2019/201A/201B as single-quote characters, so such a byte
# inside a string literal TERMINATES it and the rest of the file mis-parses —
# a silent, whole-script failure on the only platform this file exists for.
#
# Inside a COMMENT the tokenizer consumes to end of line whatever the bytes are,
# so comment prose is inert and stays exempt (both installers are written in the
# repo's em-dash-heavy comment style, and rewriting that would bury the diff).
# The rule is deliberately a SUPERSET of the dangerous set — it also forbids
# non-ASCII in a TRAILING comment, which is harmless — because "every non-ASCII
# byte lives on a whole-line comment" is checkable in three lines and cannot have
# a false negative, whereas a string-state tracker in a test can.
#
# The alternative fix (BOM the files) was rejected: a BOM is a byte any editor or
# pipeline can strip, and stripping it silently restores the parse failure. ASCII
# source cannot be broken that way.
nonascii_outside_comments() {
    LC_ALL=C awk '
        BEGIN { ascii = "\t"; for (i = 32; i <= 126; i++) ascii = ascii sprintf("%c", i) }
        /^[[:space:]]*#/ { next }
        {
            for (j = 1; j <= length($0); j++) {
                if (index(ascii, substr($0, j, 1)) == 0) { print FNR; next }
            }
        }
    ' "$1" 2>/dev/null | grep -c . | tr -d ' \n'
}

# arg_role_order <file> <anchor> <existing-token> <shipped-token> — the ORDER in
# which a merge invocation names its two operands, as "existing shipped" or
# "shipped existing" ("" when the line or a token is missing).
#
# This is the 3t1 rider: both merges bind .[0] as $existing and .[1] as $new, so
# the operand order IS the union direction. A swapped pair stays valid jq, keeps
# every expression-identity assertion above green, and silently makes the
# operator's config win over the shipped one.
arg_role_order() {
    local file="$1" anchor="$2" existing="$3" shipped="$4" line pe ps
    line=$(grep -v '^[[:space:]]*#' "$file" 2>/dev/null | grep -F -- "$anchor" | head -1)
    [ -n "$line" ] || { printf 'NO-INVOCATION-LINE'; return 0; }
    pe=$(awk -v s="$line" -v t="$existing" 'BEGIN { print index(s, t) }')
    ps=$(awk -v s="$line" -v t="$shipped"  'BEGIN { print index(s, t) }')
    if [ "$pe" = "0" ] || [ "$ps" = "0" ]; then printf 'TOKEN-MISSING'; return 0; fi
    if [ "$pe" -lt "$ps" ]; then printf 'existing shipped'; else printf 'shipped existing'; fi
}

# surface_pairs_sh <workflow-manifest.sh> — "<class>:<path>" per surface rule in
# the generator's generate_rows body, sorted.
surface_pairs_sh() {
    awk '/^generate_rows\(\) \{/, /^\}/' "$1" 2>/dev/null \
        | grep -E '^[[:space:]]*(emit_row|scan_flat|scan_tree)[[:space:]]' \
        | sed -E 's/^[[:space:]]*(emit_row|scan_flat|scan_tree)[[:space:]]+([a-z]+)[[:space:]]+"([^"]+)".*/\2:\3/' \
        | LC_ALL=C sort
}

# surface_pairs_ps <install.ps1> — the same pairs from install.ps1's
# Get-WorkflowSurfaceRows body, sorted. The two lists must be EQUAL: that is the
# assertion that fails when a release adds a shipped file to one implementation
# and not the other.
surface_pairs_ps() {
    awk '/function Get-WorkflowSurfaceRows/, /^    }$/' "$1" 2>/dev/null \
        | grep -E 'Get-Surface(FileRow|FlatRows|TreeRows)[[:space:]]+-Root' \
        | sed -E 's/.*-Class "([a-z]+)".*-(Dir|Rel) "([^"]+)".*/\1:\3/' \
        | LC_ALL=C sort
}

# outfile_on_json_paths <file> — code lines that write one of the three
# byte-sensitive targets through Out-File. MUST be zero: `Out-File -Encoding
# UTF8` writes a BOM under Windows PowerShell 5.1, and the array-valued jq output
# these sites carry comes back as a single concatenated line under -NoNewline.
outfile_on_json_paths() {
    grep -v '^[[:space:]]*#' "$1" 2>/dev/null \
        | grep -F -- 'Out-File' \
        | grep -E 'SettingsFile|TargetMcpJson|install-manifest' \
        | grep -c . | tr -d ' \n'
}

# nonewline_on_json_paths <file> — same shape, for the -NoNewline flag.
nonewline_on_json_paths() {
    grep -v '^[[:space:]]*#' "$1" 2>/dev/null \
        | grep -F -- '-NoNewline' \
        | grep -E 'SettingsFile|TargetMcpJson|install-manifest' \
        | grep -c . | tr -d ' \n'
}

# jq_stderr_null <file> — jq invocations that redirect stderr with 2>$null. MUST
# be zero in install.ps1: under $ErrorActionPreference = 'Stop', Windows
# PowerShell 5.1 turns a redirected native stderr into a TERMINATING
# NativeCommandError, so the malformed-JSON arm crashed the installer instead of
# taking its documented fallback (3t1 facet 3).
jq_stderr_null() {
    # shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
    grep -v '^[[:space:]]*#' "$1" 2>/dev/null \
        | grep -F -- 'jq ' \
        | grep -c -F -- '2>$null' | tr -d ' \n'
}

# --- 6a. preflight for this section ---------------------------------------
assert_eq "6a: workflow-manifest.sh exists (the surface generator)" "yes" \
    "$([ -f "$MANIFEST_TOOL" ] && echo yes || echo no)"
assert_eq "6a: uninstall.sh exists" "yes" \
    "$([ -f "$UNINSTALL_SH" ] && echo yes || echo no)"
assert_eq "6a: uninstall.ps1 exists" "yes" \
    "$([ -f "$UNINSTALL_PS1" ] && echo yes || echo no)"

# --- 6b. the -Upgrade switch and its exclusivity with -Mode ----------------
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6b: install.ps1 declares the -Upgrade switch parameter" "1" \
    "$(code_line_count "$INSTALL_PS1" '[switch]$Upgrade')"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell condition
assert_eq "6b: install.ps1 tests -Upgrade against -Mode exactly once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'if ($Upgrade -and $Mode)')"
assert_eq "6b: install.ps1 refuses the combination (the message line)" "1" \
    "$(code_line_count "$INSTALL_PS1" 'cannot be combined.')"
assert_eq "6b: install.sh refuses the combination too" "1" \
    "$(code_line_count "$INSTALL_SH" 'cannot be combined.')"
# The remediation sentence is byte-identical in both installers, so it is pinned
# file-to-file rather than against a literal typed here.
assert_eq "6b: the 'pass exactly one' remediation line is byte-identical in both installers" \
    "$(grep -F -- 'Pass exactly one of them.' "$INSTALL_SH" | sed -e 's/^[[:space:]]*//' -e 's/^echo "//' -e 's/" >&2$//')" \
    "$(grep -F -- 'Pass exactly one of them.' "$INSTALL_PS1" | sed -e 's/^[[:space:]]*//' -e 's/^Write-Host "//' -e 's/"$//')"
# The refusal has to EXIT 1, not warn: assert an `exit 1` inside the block.
assert_eq "6b: the ps1 refusal block exits 1" "yes" \
    "$(awk '/if \(\$Upgrade -and \$Mode\)/,/^}/' "$INSTALL_PS1" | grep -q 'exit 1' && echo yes || echo no)"

# --- 6c. Detect-V3Install and the detection ladder -------------------------
assert_eq "6c: install.ps1 defines Detect-V3Install exactly once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'function Detect-V3Install {')"
assert_eq "6c: install.ps1 CALLS Detect-V3Install (twice: forced and auto)" "2" \
    "$(code_line_count "$INSTALL_PS1" '(Detect-V3Install)')"
assert_eq "6c: install.sh defines detect_v3_install exactly once" "1" \
    "$(code_line_count "$INSTALL_SH" 'detect_v3_install() {')"
# Signal (a), the PRIMARY one, is the same sentence in both installers.
assert_eq "6c: the 3.x primary signal string is byte-identical in both installers" \
    "$(grep -o -F -- '.claude-plugin/plugin.json declares version' "$INSTALL_SH" | head -1)" \
    "$(grep -o -F -- '.claude-plugin/plugin.json declares version' "$INSTALL_PS1" | head -1)"
assert_eq "6c: ...and it is present at all (not two empty extractions)" "1" \
    "$(grep -c -F -- '.claude-plugin/plugin.json declares version' "$INSTALL_PS1" | tr -d ' \n')"
# Signal (b): the marker-absent fallback, whose signal text names both v4 markers.
SIGNAL_B='no readable plugin version; no .claude/scripts/review-check.sh and no .claude/model-roles (both v4)'
assert_eq "6c: the marker-absent signal (b) text is present in install.sh" "1" \
    "$(text_line_count "$INSTALL_SH" "$SIGNAL_B")"
assert_eq "6c: ...and byte-identically in install.ps1" "1" \
    "$(text_line_count "$INSTALL_PS1" "$SIGNAL_B")"
# The CORRECTED signal-(b) explanation from U0.4 — the paragraph that records why
# v2 signal 2 must not be deleted on the strength of this branch. Prose, so
# text_line_count; carried by both files.
SIGNAL_B_COMMENT='What (b) actually covers is a manifest whose VERSION FIELD is'
assert_eq "6c: install.sh carries the corrected signal-(b) explanation" "1" \
    "$(text_line_count "$INSTALL_SH" "$SIGNAL_B_COMMENT")"
assert_eq "6c: install.ps1 carries it too (the U0.4 correction was mirrored, not re-derived)" "1" \
    "$(text_line_count "$INSTALL_PS1" "$SIGNAL_B_COMMENT")"
assert_eq "6c: install.ps1 keeps the do-not-delete-v2-signal-2 warning" "1" \
    "$(text_line_count "$INSTALL_PS1" 'Do not delete v2 signal 2 on the strength')"

# --- 6d. the v3 backup ----------------------------------------------------
assert_eq "6d: install.sh names the .claude-v3-backup- prefix" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" '.claude-v3-backup-')" -ge 1 ] && echo yes || echo no)"
assert_eq "6d: install.ps1 names the .claude-v3-backup- prefix" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '.claude-v3-backup-')" -ge 1 ] && echo yes || echo no)"
# Dotfile inclusion is the load-bearing part: .claude/.qa-tracking/ is every gate
# record in a live install, and the bash side reached it by moving from
# `cp -r dir/*` to `cp -R dir/.`. The PowerShell spelling of that same mistake is
# a wildcard Copy-Item without -Force, so all three ps1 backup sites go through
# ONE helper that enumerates with Get-ChildItem -Force.
assert_eq "6d: install.ps1 defines the dotfile-inclusive backup helper once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'function Copy-ClaudeTree {')"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation
assert_eq "6d: ...and every backup site uses it (v3 flow, mode 1, mode 2)" "3" \
    "$(code_line_count "$INSTALL_PS1" 'Copy-ClaudeTree -SourceTree')"
# The forbidden form is copying the DIRECTORY ITSELF (`Copy-Item -Path $ClaudeDir
# ... -Recurse`), which is what install.ps1 did through v4.0 and what skips hidden
# children. Copying each ENUMERATED child recursively is fine and is what the
# helper does — so the anchor is the source operand, not the -Recurse flag.
# shellcheck disable=SC2016 # the searched-for text is the dotfile-BLIND form being forbidden
assert_eq "6d: ...and the dotfile-blind whole-directory Copy-Item is gone" "0" \
    "$(code_line_count "$INSTALL_PS1" 'Copy-Item -Path $ClaudeDir')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6d: the helper enumerates with -Force (hidden items included)" "1" \
    "$(code_line_count "$INSTALL_PS1" 'Get-ChildItem -LiteralPath $SourceTree -Force')"
# The four root-level files plus plugin.json, stored FLAT in the backup root.
for v3_root in "CLAUDE.md" ".mcp.json" "LESSONS.md" ".worktreeinclude"; do
    assert_eq "6d: install.ps1's v3 backup covers the root file $v3_root" "yes" \
        "$(awk '/Root-level files the upgrade may touch/,/plugin.json" -Force/' "$INSTALL_PS1" \
            | grep -q -F -- "$v3_root" && echo yes || echo no)"
done

# --- 6e. the PS-native manifest machinery ---------------------------------
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6e: install.ps1 hashes with Get-FileHash -Algorithm SHA256" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" 'Get-FileHash -LiteralPath $FilePath -Algorithm SHA256')" -ge 1 ] && echo yes || echo no)"
# Get-FileHash returns UPPERCASE; the manifest and every comparison are lowercase.
assert_eq "6e: ...and lowercases the digest (the manifest is lowercase hex)" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" 'ToLowerInvariant')" -ge 1 ] && echo yes || echo no)"
# LC_ALL=C on the bash side; ordinal on the PowerShell side. A culture-aware sort
# would reorder `.claude-plugin/...` against `.claude/...` and the install-manifest
# body would stop byte-equalling the generated one.
assert_eq "6e: install.ps1 sorts the manifest ORDINALLY (= LC_ALL=C)" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '[System.StringComparer]::Ordinal')" -ge 1 ] && echo yes || echo no)"
assert_eq "6e: workflow-manifest.sh sorts with LC_ALL=C" "yes" \
    "$([ "$(code_line_count "$MANIFEST_TOOL" 'LC_ALL=C sort')" -ge 1 ] && echo yes || echo no)"
# THE SURFACE ITSELF, extracted from both implementations and compared as sets.
SURFACE_SH=$(surface_pairs_sh "$MANIFEST_TOOL")
SURFACE_PS=$(surface_pairs_ps "$INSTALL_PS1")
assert_eq "6e: the generator's surface rule list is substantial (>=15 rules)" "yes" \
    "$([ "$(printf '%s\n' "$SURFACE_SH" | grep -c . | tr -d ' \n')" -ge 15 ] && echo yes || echo no)"
assert_eq "6e: install.ps1 enumerates the SAME class:path surface as workflow-manifest.sh" \
    "$(printf '%s' "$SURFACE_SH" | tr '\n' ' ')" \
    "$(printf '%s' "$SURFACE_PS" | tr '\n' ' ')"
# The two wholesale-copied trees carry prune sets; both files must name them.
for prune_name in "node_modules" ".tmp" "runs"; do
    assert_eq "6e: install.ps1 prunes $prune_name in the tree walk" "yes" \
        "$([ "$(code_line_count "$INSTALL_PS1" "$prune_name")" -ge 1 ] && echo yes || echo no)"
    assert_eq "6e: workflow-manifest.sh prunes $prune_name too" "yes" \
        "$([ "$(code_line_count "$MANIFEST_TOOL" "$prune_name")" -ge 1 ] && echo yes || echo no)"
done
# The classify contract: the same six verdict TOKENS in both implementations.
for verdict in "copy-new" "skip-current" "replace-stock" "replace-custom" "preserve-custom" "merge"; do
    assert_eq "6e: workflow-manifest.sh emits the verdict token '$verdict'" "yes" \
        "$([ "$(code_line_count "$MANIFEST_TOOL" "$verdict")" -ge 1 ] && echo yes || echo no)"
    assert_eq "6e: install.ps1 handles the verdict token '$verdict'" "yes" \
        "$([ "$(code_line_count "$INSTALL_PS1" "$verdict")" -ge 1 ] && echo yes || echo no)"
done
# The plan self-check: one plan row per source row, in both implementations.
assert_eq "6e: install.ps1 keeps the row-count self-check on the plan" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" 'internal: classify produced')" -ge 1 ] && echo yes || echo no)"
assert_eq "6e: workflow-manifest.sh keeps its join row-count self-check" "yes" \
    "$([ "$(code_line_count "$MANIFEST_TOOL" 'internal: old-table join produced')" -ge 1 ] && echo yes || echo no)"

# --- 6f. the verdict walk and its six readout labels ----------------------
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation
assert_eq "6f: install.ps1 routes copies through the verdict walk exactly once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'Copy-ByVerdict -Src $Src -Dst $Dst')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6f: install.sh routes copies through place_by_verdict exactly once" "1" \
    "$(code_line_count "$INSTALL_SH" 'place_by_verdict "$src" "$dst"')"
# preserve-custom writes a sidecar rather than touching the operator's file.
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6f: install.ps1 writes the shipped file to <path>.new on preserve-custom" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '"$Dst.new"')" -ge 1 ] && echo yes || echo no)"
# The six readout labels, present in BOTH installers. These are what an operator
# reads after an upgrade, and the L2 spec asserts on them for the bash side.
for label in "copied (new)" "replaced (stock)" "already current" \
             "replaced (customized)" "preserved (yours)" "merged key-wise"; do
    assert_eq "6f: install.sh carries the verdict label '$label'" "yes" \
        "$([ "$(text_line_count "$INSTALL_SH" "$label")" -ge 1 ] && echo yes || echo no)"
    assert_eq "6f: install.ps1 carries the verdict label '$label'" "yes" \
        "$([ "$(text_line_count "$INSTALL_PS1" "$label")" -ge 1 ] && echo yes || echo no)"
done
# The MERGED-ABSENT term is a v4.1 addition to the write count, not a label: it is
# what keeps "no file changes" literally true when a merged-class file is missing.
assert_eq "6f: install.sh names the MERGED-ABSENT term" "yes" \
    "$([ "$(text_line_count "$INSTALL_SH" 'MERGED-ABSENT-START')" -ge 1 ] && echo yes || echo no)"
assert_eq "6f: install.ps1 names it too" "yes" \
    "$([ "$(text_line_count "$INSTALL_PS1" 'MERGED-ABSENT-START')" -ge 1 ] && echo yes || echo no)"
# The upgrade report goes to the backup as a file, not just to the console.
assert_eq "6f: install.ps1 saves upgrade-report.txt into the backup" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" 'upgrade-report.txt')" -ge 1 ] && echo yes || echo no)"
assert_eq "6f: install.sh does too" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" 'upgrade-report.txt')" -ge 1 ] && echo yes || echo no)"

# --- 6g. the no-change probe and both sentinel pairs ----------------------
# The readout sentence is asserted VERBATIM by the L2 spec
# (installer-v3-upgrade.sh 8a/8b/8c/8d), so a paraphrase on either side is a
# silent divergence between what the two installers claim to have done.
SH_PROBE=$(probe_readout "$INSTALL_SH")
PS_PROBE=$(probe_readout "$INSTALL_PS1")
assert_eq "6g: the probe readout extracted from install.sh is substantial" "yes" \
    "$([ "${#SH_PROBE}" -gt 20 ] && echo yes || echo no)"
assert_eq "6g: ...and mentions 'no file changes'" "yes" \
    "$(printf '%s' "$SH_PROBE" | grep -qF 'no file changes' && echo yes || echo no)"
assert_eq "6g: the no-change probe readout is byte-identical in both installers" \
    "$SH_PROBE" "$PS_PROBE"
# Both sentinel pairs, in both installers, exactly once each. The L2 METAs delete
# or rewrite these blocks by name on the bash side; the ps1 copies exist so the
# two can be diffed by eye and so a future strip does not miss one.
for sentinel in "NOCHANGE-PROBE-START" "NOCHANGE-PROBE-END" \
                "MERGED-ABSENT-START" "MERGED-ABSENT-END"; do
    assert_eq "6g: install.sh carries '$sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_SH" "$sentinel")"
    assert_eq "6g: install.ps1 carries '$sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_PS1" "$sentinel")"
done
# The probe is mode-2 only and gated on all four conjuncts, including the
# row-count floor that stops an EMPTY plan from reading as "nothing to do".
assert_eq "6g: the ps1 probe requires a non-empty plan" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '(Get-PlanRowCount) -ge 1')" -ge 1 ] && echo yes || echo no)"
assert_eq "6g: the ps1 probe requires zero write verdicts" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '(Get-PlanWriteCount) -eq 0')" -ge 1 ] && echo yes || echo no)"
assert_eq "6g: the bash probe requires the same non-empty plan" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" 'plan_row_count)" -ge 1')" -ge 1 ] && echo yes || echo no)"

# --- 6h. v4 -> v4 install-manifest old-table preference ------------------
assert_eq "6h: install.ps1 defines the install-manifest old-table reader once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'function Get-InstalledManifestOldTable {')"
assert_eq "6h: ...and consults it from BOTH the upgrade flow and the mode-2 Update" "2" \
    "$(code_line_count "$INSTALL_PS1" 'if (Get-InstalledManifestOldTable)')"
assert_eq "6h: install.sh consults its equivalent from both places too" "2" \
    "$(code_line_count "$INSTALL_SH" 'if install_manifest_old_table; then')"
assert_eq "6h: install.ps1 labels that table the way the readouts name it" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '.claude/install-manifest (v')" -ge 1 ] && echo yes || echo no)"
assert_eq "6h: install.sh uses the same label" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" '.claude/install-manifest (v')" -ge 1 ] && echo yes || echo no)"
# A 3.x target must pin the FROZEN table even if it somehow carries a manifest.
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6h: install.ps1 excludes 3.x targets from the manifest preference" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '-not ($script:V3DetectedVersion -like "3.*")')" -ge 1 ] && echo yes || echo no)"
assert_eq "6h: install.ps1 falls back to the frozen manifests/ table" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" 'manifests\v3.5.0.sha256')" -ge 1 ] && echo yes || echo no)"

# --- 6i. LF / BOM discipline on every byte-sensitive write ---------------
assert_eq "6i: install.ps1 defines exactly one LF writer" "1" \
    "$(code_line_count "$INSTALL_PS1" 'function Write-LfFile {')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6i: ...which writes with WriteAllText (not a cmdlet that appends a newline policy)" "1" \
    "$(code_line_count "$INSTALL_PS1" '[System.IO.File]::WriteAllText($FilePath')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6i: ...with a BOM-LESS UTF8 encoder" "1" \
    "$(code_line_count "$INSTALL_PS1" 'New-Object System.Text.UTF8Encoding($false)')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6i: ...joining lines with LF" "yes" \
    "$(grep -v '^[[:space:]]*#' "$INSTALL_PS1" | grep -F -- '$Lines -join' | grep -qF '`n' && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation
assert_eq "6i: the .mcp.json merge writes through it" "1" \
    "$(code_line_count "$INSTALL_PS1" 'Write-LfFile -FilePath $TargetMcpJson')"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation
assert_eq "6i: the settings.json merge writes through it" "1" \
    "$(code_line_count "$INSTALL_PS1" 'Write-LfFile -FilePath $SettingsFile')"
assert_eq "6i: the install-manifest writes through it" "yes" \
    "$(grep -v '^[[:space:]]*#' "$INSTALL_PS1" | grep -F -- 'Write-LfFile' | grep -qF 'install-manifest' && echo yes || echo no)"
# THE REGRESSION THIS SECTION EXISTS FOR: no Out-File / -NoNewline on a JSON or
# manifest write path (3t1 facets 1-2). Section 7's META reintroduces one.
assert_eq "6i: NO Out-File on a JSON or manifest write path" "0" \
    "$(outfile_on_json_paths "$INSTALL_PS1")"
assert_eq "6i: NO -NoNewline on a JSON or manifest write path" "0" \
    "$(nonewline_on_json_paths "$INSTALL_PS1")"
# The manifest header both implementations write and read. Anchored on the WRITE
# expression, not on the bare token: install.ps1 also names the token in the
# reader (StartsWith / Substring), so a token-anywhere check would stay green with
# the writer's header broken.
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6i: install.ps1 writes the shared install-manifest header" "1" \
    "$(code_line_count "$INSTALL_PS1" '@("# claude-workflow-plugin $SourceVersionLabel")')"
assert_eq "6i: install.sh writes the same header token" "1" \
    "$(code_line_count "$INSTALL_SH" '# claude-workflow-plugin %s')"
assert_eq "6i: and install.ps1's reader gates on that same header token" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" 'StartsWith("# claude-workflow-plugin ")')" -ge 1 ] && echo yes || echo no)"

# --- 6j. 3t1: the WinPS 5.1 stderr trap and the jq operand order ---------
assert_eq "6j: install.ps1 no longer redirects jq's stderr with 2>\$null" "0" \
    "$(jq_stderr_null "$INSTALL_PS1")"
assert_eq "6j: the validity gate scopes ErrorActionPreference to Continue" "yes" \
    "$(awk '/function Test-JsonSingleObject/,/^    }$/' "$INSTALL_PS1" \
        | grep -qF "ErrorActionPreference = 'Continue'" && echo yes || echo no)"
assert_eq "6j: ...and captures jq's stderr into the discarded stream instead" "yes" \
    "$(awk '/function Test-JsonSingleObject/,/^    }$/' "$INSTALL_PS1" \
        | grep -qF '2>&1' && echo yes || echo no)"
# The operand ORDER pin. Roles are read from each installer's own invocation line;
# only the variable spellings are named here.
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
SH_SETTINGS_ORDER=$(arg_role_order "$INSTALL_SH" 'jq -s "$SETTINGS_MERGE_JQ"' '"$SETTINGS_FILE"' '"$SOURCE_SETTINGS"')
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
PS_SETTINGS_ORDER=$(arg_role_order "$INSTALL_PS1" 'jq -s $SettingsMergeJq' '$SettingsFile' '$SourceSettings')
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
SH_MCP_ORDER=$(arg_role_order "$INSTALL_SH" 'jq -s "$MCP_MERGE_JQ"' '"$MCP_FILE"' '"$SOURCE_DIR/.mcp.json"')
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
PS_MCP_ORDER=$(arg_role_order "$INSTALL_PS1" 'jq -s $McpMergeJq' '$TargetMcpJson' '$SourceMcpJson')
assert_eq "6j: install.sh's settings merge binds existing-then-shipped" \
    "existing shipped" "$SH_SETTINGS_ORDER"
assert_eq "6j: install.ps1's settings merge binds existing-then-shipped" \
    "existing shipped" "$PS_SETTINGS_ORDER"
assert_eq "6j: the settings operand order matches file-to-file" \
    "$SH_SETTINGS_ORDER" "$PS_SETTINGS_ORDER"
assert_eq "6j: install.sh's .mcp.json merge binds existing-then-shipped" \
    "existing shipped" "$SH_MCP_ORDER"
assert_eq "6j: install.ps1's .mcp.json merge binds existing-then-shipped" \
    "existing shipped" "$PS_MCP_ORDER"
assert_eq "6j: the .mcp.json operand order matches file-to-file" \
    "$SH_MCP_ORDER" "$PS_MCP_ORDER"

# --- 6k. wn4: the containment rule is in BOTH uninstallers ---------------
# The bash guard was proven to be load-bearing by an executed L2 META
# (installer-manifest-parity.sh 9c). Nothing can execute the ps1 one, so its
# presence is pinned here — wn4's acceptance criterion 4.
for sentinel in "WN4-CONTAINMENT-START" "WN4-CONTAINMENT-END"; do
    assert_eq "6k: uninstall.sh carries '$sentinel' exactly once" "1" \
        "$(text_line_count "$UNINSTALL_SH" "$sentinel")"
    assert_eq "6k: uninstall.ps1 carries '$sentinel' exactly once" "1" \
        "$(text_line_count "$UNINSTALL_PS1" "$sentinel")"
done
assert_eq "6k: uninstall.sh resolves the row's parent physically (pwd -P)" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_SH" 'pwd -P')" -ge 1 ] && echo yes || echo no)"
assert_eq "6k: uninstall.ps1 refuses a reparse point in the row's directory chain" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_PS1" '[System.IO.FileAttributes]::ReparsePoint')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6k: uninstall.ps1 compares the resolved parent against the resolved target" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_PS1" 'StartsWith($script:TargetRoot')" -ge 1 ] && echo yes || echo no)"
# The refusal is REPORTED, in the same words, by both scripts.
REFUSAL_TEXT='resolves outside the project'
assert_eq "6k: uninstall.sh reports a refused row" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_SH" "$REFUSAL_TEXT")" -ge 1 ] && echo yes || echo no)"
assert_eq "6k: uninstall.ps1 reports it in the same words" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_PS1" "$REFUSAL_TEXT")" -ge 1 ] && echo yes || echo no)"
# The manifest-driven root walk itself, mirrored: header check, class grammar,
# 64-hex hashes, and the lowercase-sensitive comparison PowerShell gets wrong by
# default.
assert_eq "6k: uninstall.ps1 gates on the shared manifest header" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_PS1" '# claude-workflow-plugin ')" -ge 1 ] && echo yes || echo no)"
assert_eq "6k: uninstall.ps1 matches the 64-hex hash grammar CASE-SENSITIVELY (-cnotmatch)" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_PS1" '-cnotmatch')" -ge 1 ] && echo yes || echo no)"
assert_eq "6k: uninstall.ps1 lists all three backup prefixes" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_PS1" '.claude-v2-backup-*')" -ge 1 ] &&
       [ "$(code_line_count "$UNINSTALL_PS1" '.claude-v3-backup-*')" -ge 1 ] &&
       [ "$(code_line_count "$UNINSTALL_PS1" '.claude-backup-*')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "6k: uninstall.ps1 still restores ONLY from a .claude-backup-* snapshot" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_PS1" '$RestorableBackups')" -ge 2 ] && echo yes || echo no)"

# --- 6l. R1-F1: no non-ASCII byte outside a whole-line comment -------------
# The WinPS 5.1 ANSI-decode trap, mechanically. See nonascii_outside_comments for
# the full mechanism; the short version is that one UTF-8 em dash inside a
# double-quoted string is a whole-script parse failure on Windows PowerShell 5.1,
# and BOTH files carried one before this check existed (install.ps1 since before
# U0.7 — its pre-existing site is why the file could never have parsed on 5.1).
assert_eq "6l: install.ps1 has no non-ASCII byte outside a whole-line comment" "0" \
    "$(nonascii_outside_comments "$INSTALL_PS1")"
assert_eq "6l: uninstall.ps1 has no non-ASCII byte outside a whole-line comment" "0" \
    "$(nonascii_outside_comments "$UNINSTALL_PS1")"
# Vacuity guard: the checker must be looking at files that DO carry non-ASCII in
# their comments, or "0 outside comments" would be trivially true of any ASCII
# file and the META below would be the only thing keeping it honest.
assert_eq "6l: ...and both files really do carry non-ASCII comment prose (so the exemption is doing work)" "yes" \
    "$([ "$(LC_ALL=C grep -c '[^ -~	]' "$INSTALL_PS1" | tr -d ' \n')" -ge 1 ] &&
       [ "$(LC_ALL=C grep -c '[^ -~	]' "$UNINSTALL_PS1" | tr -d ' \n')" -ge 1 ] && echo yes || echo no)"
# The byte-pinned readout is the one place the character is REQUIRED, so it is
# composed at output time instead of written. Assert the composition is there:
# without it, either the sentence drifts from install.sh's or the em dash comes
# back as a literal.
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell subexpression
assert_eq "6l: install.ps1 composes the probe's em dash at output time" "1" \
    "$(code_line_count "$INSTALL_PS1" 'no file changes $([char]0x2014) skipping backup')"

# ===========================================================================
echo ""
echo "=== Section 6m: version-dynamic branding (U0.8) ==="
# For the whole of v4.0 both installers greeted the operator with "Claude
# Workflow Plugin v3" and the fresh-install readout listed v3 features, on a 4.x
# release. Nothing caught it: the L1 spec that reads the usage header asserted
# the literal v3 string, so the stale major was PINNED rather than detected.
#
# Both halves are checked here — the hardcode is gone AND the version is read
# from the manifest — because either alone is satisfiable by the wrong file
# (a hardcode removed and nothing put back prints a bare product name forever).
BRAND_STALE='Claude Workflow Plugin v3'
assert_eq "6m: install.sh carries no hardcoded '$BRAND_STALE'" "0" \
    "$(text_line_count "$INSTALL_SH" "$BRAND_STALE")"
assert_eq "6m: install.ps1 carries no hardcoded '$BRAND_STALE'" "0" \
    "$(text_line_count "$INSTALL_PS1" "$BRAND_STALE")"
assert_eq "6m: neither installer hardcodes the v3 what's-new heading" "0 0" \
    "$(printf '%s %s' \
        "$(text_line_count "$INSTALL_SH" "What's new in v3:")" \
        "$(text_line_count "$INSTALL_PS1" "What's new in v3:")")"
# The banner interpolates a label built from the manifest.
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6m: install.sh's banner prints the interpolated brand label" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" '${BRAND_LABEL}')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6m: install.sh's usage header prints it too" "1" \
    "$(code_line_count "$INSTALL_SH" 'printf '"'"'%s installer\n'"'"' "$BRAND_LABEL"')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "6m: install.ps1's banner prints the interpolated brand label" "1" \
    "$(code_line_count "$INSTALL_PS1" 'Write-Color $BrandLabel Cyan')"
# ...and the label really comes from plugin.json in both.
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6m: install.sh reads the branding version from .claude-plugin/plugin.json" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" 'plugin_json_version "$SCRIPT_DIR/.claude-plugin/plugin.json"')" -ge 1 ] && echo yes || echo no)"
# jq-free on the bash side, because --help and the banner both run BEFORE the
# prerequisite block has proven jq exists.
assert_eq "6m: ...with a jq-free extractor (the banner precedes the jq prereq check)" "1" \
    "$(code_line_count "$INSTALL_SH" 'plugin_json_version() {')"
assert_eq "6m: install.ps1 reads it from the same manifest" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '".claude-plugin/plugin.json"')" -ge 1 ] && echo yes || echo no)"
# The fresh readout heading interpolates the MAJOR rather than naming one.
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6m: install.sh's fresh readout heading interpolates the major" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" "What's new in v\$FRESH_MAJOR:")" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "6m: install.ps1's does too" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" "What's new in v\${freshMajor}:")" -ge 1 ] && echo yes || echo no)"
# EXECUTED, on the bash side: --help must actually render the version the
# manifest declares. This is the only leg of 6m that proves the wiring rather
# than the presence of the wiring.
BRAND_EXPECTED_VERSION=$(jq -r '.version // empty' "$PROJECT_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo "")
assert_eq "6m: the plugin manifest declares a version (guards the executed check)" "yes" \
    "$([ -n "$BRAND_EXPECTED_VERSION" ] && echo yes || echo no)"
BRAND_HELP_OUT=$(bash "$INSTALL_SH" --help 2>&1 || true)
assert_eq "6m: install.sh --help renders the manifest's version in the header" "yes" \
    "$(printf '%s' "$BRAND_HELP_OUT" | grep -qF "Claude Workflow Plugin v$BRAND_EXPECTED_VERSION installer" && echo yes || echo no)"

# ===========================================================================
echo ""
echo "=== Section 6n: the generated .gitignore (U0.8) ==="
# install.sh and install.ps1 each write a .gitignore into a project they had to
# `git init` themselves, and through v4.0 the two lists had drifted (the ps1 one
# was missing vendor/, *.egg-info/, Thumbs.db and every section comment) while
# NEITHER covered the artifacts the plugin itself writes: four backup/trash
# directory prefixes, the *.new upgrade sidecars, and the two pre-merge .bak
# files. CHANGELOG.md's 3.4.0 entry has claimed since June that
# .claude/.mutation-runs/ and .claude/.mutation-worktrees/ are "added to the
# install-time .gitignore" — they were not. That is the doc/code divergence this
# section closes.
#
# WHY THE FRESH-INSTALL L2 SPEC DOES NOT DO THIS. The heredoc is only reached
# when the target has no .git, and install.sh's git-init prompt falls through to
# reading /dev/tty whenever a controlling terminal is openable — so an L2 fixture
# that reached this block would HANG on a developer's machine while passing in
# CI. installer-manifest-parity.sh's fresh_install git-inits first for exactly
# that reason. The block is therefore EXECUTED here instead, which tests the same
# bytes without needing an installer run.
GITIGNORE_SH=$(gitignore_from_sh "$INSTALL_SH" || echo "")
GITIGNORE_PS=$(gitignore_from_ps "$INSTALL_PS1")
assert_eq "6n: executing install.sh's heredoc really produced a .gitignore" "yes" \
    "$([ -n "$GITIGNORE_SH" ] && echo yes || echo no)"
assert_eq "6n: install.ps1's line list is non-empty too" "yes" \
    "$([ -n "$GITIGNORE_PS" ] && echo yes || echo no)"
# Vacuity guard: both sides must be substantial, or the equality below could be
# "" == "".
assert_eq "6n: the produced file has a plausible number of lines (>=40)" "yes" \
    "$([ "$(printf '%s\n' "$GITIGNORE_SH" | grep -c . | tr -d ' \n')" -ge 40 ] && echo yes || echo no)"
# ORDER-SENSITIVE full-body equality: a .gitignore is read top to bottom and the
# section comments are part of what an operator sees, so this is a byte
# comparison and not a set comparison.
assert_eq "6n: install.ps1's .gitignore is line-for-line what install.sh's heredoc produces" \
    "$GITIGNORE_SH" "$GITIGNORE_PS"
# The individual entries this task added, named one at a time so a failure says
# WHICH one went missing rather than dumping a 51-line diff.
GITIGNORE_SH_ENTRIES=$(printf '%s\n' "$GITIGNORE_SH" | gitignore_entries)
for gi_entry in \
    '.claude-backup-*/' \
    '.claude-v2-backup-*/' \
    '.claude-v3-backup-*/' \
    '.claude-uninstall-trash-*/' \
    '*.new' \
    '.claude/settings.json.bak' \
    '.mcp.json.bak' \
    '.claude/.mutation-runs/' \
    '.claude/.mutation-worktrees/'
do
    assert_eq "6n: the generated .gitignore ignores $gi_entry" "yes" \
        "$(printf '%s\n' "$GITIGNORE_SH_ENTRIES" | grep -qxF -- "$gi_entry" && echo yes || echo no)"
done
# The pre-existing entries are still there — the additions were additive, and a
# .gitignore that lost node_modules/ would be a much worse regression than the
# one this section fixes.
for gi_kept in 'node_modules/' '.env' '.claude/.session-start' '.claude/.qa-tracking/'; do
    assert_eq "6n: ...and still ignores $gi_kept" "yes" \
        "$(printf '%s\n' "$GITIGNORE_SH_ENTRIES" | grep -qxF -- "$gi_kept" && echo yes || echo no)"
done
# LF / BOM discipline on the ps1 side (U0.7 convention). `Out-File -Encoding
# UTF8` means UTF-8 WITH BOM under Windows PowerShell 5.1, and a BOM on the first
# line of a .gitignore is a pattern git may not match — so the very first rule
# could silently stop working on the one platform this file exists for.
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation
assert_eq "6n: install.ps1 writes the .gitignore through the LF writer" "yes" \
    "$(extract_block "$INSTALL_PS1" "GENERATED_GITIGNORE" | grep -qF -- 'Write-LfFile -FilePath $GitignoreFile' && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is the FORBIDDEN Out-File form
assert_eq "6n: ...and no longer through Out-File" "0" \
    "$(code_line_count "$INSTALL_PS1" 'Out-File -FilePath $GitignoreFile')"
# Both sentinel pairs, exactly once each, in both files.
for gi_sentinel in "BEGIN GENERATED_GITIGNORE" "END GENERATED_GITIGNORE"; do
    assert_eq "6n: install.sh carries '$gi_sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_SH" "$gi_sentinel")"
    assert_eq "6n: install.ps1 carries '$gi_sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_PS1" "$gi_sentinel")"
done

# ===========================================================================
echo ""
echo "=== Section 6o: the shipped-docs subset, five ways (U0.8) ==="
# docs/CODEX_SETUP.md and docs/HOOKS.md are named in FIVE places, and every one
# of them has to agree or the install is wrong in a different way each time:
#
#   workflow-manifest.sh generate_rows   the manifest row (bash surface)
#   install.ps1 Get-WorkflowSurfaceRows  the manifest row (PowerShell surface)
#   install.sh $SHIPPED_DOCS             the bash copy loop
#   install.ps1 $ShippedDocs             the PowerShell copy loop
#   the required-source list in both     the fail-fast preflight
#
# A row without a copy loop makes every parity spec fail loudly (good). A copy
# loop without a row makes the installer write a file no upgrade will ever
# classify or uninstall (silent). One installer's list without the other's is the
# grader.md failure mode with a second platform attached.
DOCS_EXPECTED="docs/CODEX_SETUP.md docs/HOOKS.md"
assert_eq "6o: workflow-manifest.sh's surface enumerates exactly the two shipped docs" \
    "$DOCS_EXPECTED" "$(docs_from_surface_sh "$MANIFEST_TOOL")"
assert_eq "6o: install.ps1's surface enumerates the same two" \
    "$DOCS_EXPECTED" "$(docs_from_surface_ps "$INSTALL_PS1")"
assert_eq "6o: install.sh's copy loop iterates the same two" \
    "$DOCS_EXPECTED" "$(docs_from_copy_block "$INSTALL_SH")"
assert_eq "6o: install.ps1's copy loop iterates the same two" \
    "$DOCS_EXPECTED" "$(docs_from_copy_block "$INSTALL_PS1")"
assert_eq "6o: install.sh's required-source list names the same two" \
    "$DOCS_EXPECTED" "$(docs_from_required_sh "$INSTALL_SH")"
assert_eq "6o: install.ps1's required-source list names the same two" \
    "$DOCS_EXPECTED" "$(docs_from_required_ps "$INSTALL_PS1")"
# And the two files exist, so the required-source check cannot abort every
# install the moment this lands.
for shipped_doc in docs/CODEX_SETUP.md docs/HOOKS.md; do
    assert_eq "6o: $shipped_doc exists in the repo (the preflight would abort otherwise)" "yes" \
        "$([ -f "$PROJECT_DIR/$shipped_doc" ] && echo yes || echo no)"
done
# NEITHER installer may glob docs/. The subset is a subset because docs/ in an
# install target belongs to the operator — a glob would ship the repo's internal
# design notes and every dated AgentLint report into their project, and would put
# them in the manifest, which would let the uninstaller offer to move an
# operator's own docs.
for docs_glob in 'docs/*.md' 'docs\*.md' 'docs/*'; do
    assert_eq "6o: install.sh does not copy docs with the glob '$docs_glob'" "0" \
        "$(code_line_count "$INSTALL_SH" "$docs_glob")"
    assert_eq "6o: install.ps1 does not either ('$docs_glob')" "0" \
        "$(code_line_count "$INSTALL_PS1" "$docs_glob")"
done
assert_eq "6o: the generator does not scan docs/ as a directory" "0" \
    "$(code_line_count "$MANIFEST_TOOL" 'scan_flat workflow "docs"')"
# The docs rows are class workflow in BOTH surfaces — the class decides whether an
# operator edit is replaced (with their copy in the backup) or preserved behind a
# .new sidecar, and a reference doc that disagreed with the code it documents
# would be worse than a lost edit.
assert_eq "6o: both docs rows are class workflow in the bash surface" "2" \
    "$(surface_pairs_sh "$MANIFEST_TOOL" | grep -c '^workflow:docs/' | tr -d ' \n')"
assert_eq "6o: and in the PowerShell surface" "2" \
    "$(surface_pairs_ps "$INSTALL_PS1" | grep -c '^workflow:docs/' | tr -d ' \n')"
# Both sentinel pairs, exactly once each.
for docs_sentinel in "BEGIN SHIPPED_DOCS" "END SHIPPED_DOCS"; do
    assert_eq "6o: install.sh carries '$docs_sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_SH" "$docs_sentinel")"
    assert_eq "6o: install.ps1 carries '$docs_sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_PS1" "$docs_sentinel")"
done
# The frozen v3.5 table had to be REGENERATED in the same commit as the surface
# change, or the flagship L2 spec's byte-integrity check (which regenerates from
# the v3.5.0 tag and cmp's) breaks. The table is the artifact, so the evidence
# that the refreeze happened is in it: the tag carried docs/HOOKS.md and never
# carried docs/CODEX_SETUP.md.
FROZEN_TABLE_U08="$PROJECT_DIR/manifests/v3.5.0.sha256"
assert_eq "6o: the frozen v3.5.0 table was refrozen WITH the docs row" "1" \
    "$(awk -F'\t' '$1 == "docs/HOOKS.md"' "$FROZEN_TABLE_U08" 2>/dev/null | grep -c . | tr -d ' \n')"
assert_eq "6o: ...and without the one the tag never had" "0" \
    "$(awk -F'\t' '$1 == "docs/CODEX_SETUP.md"' "$FROZEN_TABLE_U08" 2>/dev/null | grep -c . | tr -d ' \n')"

# ===========================================================================
echo ""
echo "=== Section 6p: R1-F2 / R1-F3 readout wording (U0.8) ==="
# R1-F2: the saved upgrade report rendered ONE BOOLEAN per merged-class file, so
# "the merge was attempted and failed" printed the same sentence as "there was
# nothing to merge" — while the two on-disk outcomes differ completely (one file
# left untouched and unmerged, the other replaced wholesale by the shipped
# config). The terminal shows the failure in red; the SAVED report is what gets
# read days later, and it was wrong. installer-v3-upgrade.sh section 10 proves
# the behaviour end-to-end on the bash side; this pins the two installers to the
# SAME sentences, because nothing can execute the ps1 one.
MERGE_LINES_SH=$(merge_status_lines "$INSTALL_SH")
MERGE_LINES_PS=$(merge_status_lines "$INSTALL_PS1")
assert_eq "6p: install.sh's merged-file report block yields sentences" "yes" \
    "$([ -n "$MERGE_LINES_SH" ] && echo yes || echo no)"
# SEVEN: three settings arms + four .mcp.json arms. Counted so a block that
# collapsed back to one sentence per file cannot pass the equality below.
assert_eq "6p: install.sh renders all seven merged-file arms" "7" \
    "$(printf '%s\n' "$MERGE_LINES_SH" | grep -c . | tr -d ' \n')"
assert_eq "6p: install.ps1 renders the same seven" "7" \
    "$(printf '%s\n' "$MERGE_LINES_PS" | grep -c . | tr -d ' \n')"
assert_eq "6p: and the sentences are identical file-to-file (path separators folded)" \
    "$MERGE_LINES_SH" "$MERGE_LINES_PS"
# The four status tokens, in both. These are what the report switches on, so a
# missing one is a silently unreachable arm.
for merge_state in "shipped" "merged" "failed-untouched" "failed-replaced"; do
    assert_eq "6p: install.sh knows the merge state '$merge_state'" "yes" \
        "$([ "$(code_line_count "$INSTALL_SH" "$merge_state")" -ge 1 ] && echo yes || echo no)"
    assert_eq "6p: install.ps1 knows it too" "yes" \
        "$([ "$(code_line_count "$INSTALL_PS1" "$merge_state")" -ge 1 ] && echo yes || echo no)"
done
# The retired booleans are GONE from both, not merely unused: a leftover
# SETTINGS_MERGE_DONE would be a second source of truth for the same question.
for retired_flag in "SETTINGS_MERGE_DONE" "MCP_MERGE_DONE"; do
    assert_eq "6p: install.sh no longer carries the retired flag $retired_flag" "0" \
        "$(code_line_count "$INSTALL_SH" "$retired_flag")"
done
for retired_flag in "SettingsMergeDone" "McpMergeDone"; do
    assert_eq "6p: install.ps1 no longer carries the retired flag $retired_flag" "0" \
        "$(code_line_count "$INSTALL_PS1" "$retired_flag")"
done
# Both sentinel pairs, exactly once each (the L2 META at section 10c deletes the
# bash block by name).
for merge_sentinel in "MERGE-STATUS-LINES-START" "MERGE-STATUS-LINES-END"; do
    assert_eq "6p: install.sh carries '$merge_sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_SH" "$merge_sentinel")"
    assert_eq "6p: install.ps1 carries '$merge_sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_PS1" "$merge_sentinel")"
done

# R1-F3: the upgrade-prerequisite failure said "This source tree has neither" on
# an OR, so a tree with a working generator and merely no frozen table was told
# both were missing. The wording now names whichever half actually failed, and
# each line reports its own state.
# code_line_count, not text_line_count: install.sh's comment explains the retired
# wording verbatim, and that prose is the record of why the fix exists. What must
# be gone is the `echo` that PRINTED it.
assert_eq "6p (R1-F3): install.sh no longer PRINTS 'has neither'" "0" \
    "$(code_line_count "$INSTALL_SH" "has neither")"
assert_eq "6p (R1-F3): ...and the retired wording is still documented as the reason" "yes" \
    "$([ "$(text_line_count "$INSTALL_SH" "has neither")" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6p (R1-F3): it names the missing half from a computed variable instead" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" 'is missing the $UPGRADE_PREREQ_MISSING')" -ge 1 ] && echo yes || echo no)"
assert_eq "6p (R1-F3): both halves can be named (generator / old table)" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" 'UPGRADE_PREREQ_MISSING="generator"')" -ge 1 ] &&
       [ "$(code_line_count "$INSTALL_SH" 'UPGRADE_PREREQ_MISSING="old table"')" -ge 1 ] && echo yes || echo no)"
assert_eq "6p (R1-F3): ...and both at once, when both are absent" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" 'and the old table')" -ge 1 ] && echo yes || echo no)"
# Each of the two diagnostic lines reports found-vs-MISSING for its OWN path, so
# the operator does not have to infer it from the sentence.
assert_eq "6p (R1-F3): each prerequisite line reports its own found/MISSING state" "2" \
    "$(code_line_count "$INSTALL_SH" 'echo "found" || echo "MISSING"')"
# install.ps1 has ONE prerequisite here by construction (it reimplements the
# generator natively, so there is no script to be missing) and its sentence
# already named the table. Pinned so the divergence stays deliberate: a future
# "restore parity" edit that re-added a generator clause would be adding a branch
# that cannot fire.
assert_eq "6p (R1-F3): install.ps1's single-prerequisite arm names the table" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" 'needs a frozen hash table and this source tree has none')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "6p (R1-F3): ...and marks it MISSING on the path line" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '$frozenTable (MISSING)')" -ge 1 ] && echo yes || echo no)"
assert_eq "6p (R1-F3): ...and records why it has only one prerequisite" "yes" \
    "$([ "$(text_line_count "$INSTALL_PS1" 'ONE prerequisite here, not two')" -ge 1 ] && echo yes || echo no)"

# ===========================================================================
echo ""
echo "=== Section 6q: uninstaller nested rows + the CRLF divergence (U0.8) ==="
# Root scope stopped being FLAT when the docs subset joined the surface, and
# `mv "$path" "$TRASH_DIR/"` flattens: docs/HOOKS.md would land at the trash root,
# collide with any same-named file from another directory, and the recovery
# command printed at the end would restore it to the project root. Both
# uninstallers now mirror the project layout inside the trash.
# installer-manifest-parity.sh section 5 proves the bash behaviour by executing
# it; this pins the ps1 mirror.
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6q: uninstall.sh moves each entry to its own relative path in the trash" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_SH" 'mv "$path" "$TRASH_DIR/$rel"')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6q: ...creating the parent first" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_SH" 'mkdir -p "$dest_parent"')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is the FORBIDDEN flattening form
assert_eq "6q: ...and the flattening form is gone" "0" \
    "$(code_line_count "$UNINSTALL_SH" 'mv "$path" "$TRASH_DIR/"')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "6q: uninstall.ps1 mirrors the layout too" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_PS1" 'Move-Item -LiteralPath $p -Destination $dest')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "6q: ...creating the parent first" "yes" \
    "$([ "$(code_line_count "$UNINSTALL_PS1" 'New-Item -ItemType Directory -Path $destParent -Force')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is the FORBIDDEN flattening form
assert_eq "6q: ...and the flattening form is gone there as well" "0" \
    "$(code_line_count "$UNINSTALL_PS1" 'Move-Item -LiteralPath $p -Destination $TrashDir')"
# The readout names the RELATIVE path, not the basename — otherwise the operator
# reading "moved HOOKS.md" cannot tell which HOOKS.md moved.
# shellcheck disable=SC2016 # the searched-for text is the FORBIDDEN basename readout form
assert_eq "6q: uninstall.sh's move line names the relative path" "0" \
    "$(code_line_count "$UNINSTALL_SH" 'moved $(basename "$path")')"
# The m7e R1-F3 rider: the two uninstallers do NOT tolerate a CRLF install-manifest
# equally, and that has to be written down where a maintainer will meet it. Both
# headers carry the note; the anchor is a phrase, so a reword that keeps the
# meaning keeps the assertion.
CRLF_NOTE_ANCHOR='CRLF TOLERANCE DIVERGES FROM'
assert_eq "6q: uninstall.sh's header records the CRLF-manifest divergence" "1" \
    "$(text_line_count "$UNINSTALL_SH" "$CRLF_NOTE_ANCHOR")"
assert_eq "6q: uninstall.ps1's header records it too" "1" \
    "$(text_line_count "$UNINSTALL_PS1" "$CRLF_NOTE_ANCHOR")"
# The note has to say WHICH WAY each side goes, or it is a label rather than a
# record: bash degrades to the legacy leave-everything behaviour, PowerShell
# consumes the manifest normally.
assert_eq "6q: the bash note names its awk field-3 mechanism" "yes" \
    "$([ "$(text_line_count "$UNINSTALL_SH" 'leaves \r on field 3')" -ge 1 ] && echo yes || echo no)"
assert_eq "6q: the ps1 note names ReadAllLines as the reason it differs" "yes" \
    "$([ "$(text_line_count "$UNINSTALL_PS1" 'ReadAllLines, which strips the \r')" -ge 1 ] && echo yes || echo no)"
# Anchored on a fragment SHORT ENOUGH to survive comment reflow in both files:
# the full sentence wraps differently in each, and a whole-line fixed-string
# match on it would be a line-wrap assertion rather than a content one.
assert_eq "6q: both notes state the direction is SAFE (bash leaves more behind)" "yes" \
    "$([ "$(text_line_count "$UNINSTALL_SH" 'bash leaves more behind than it')" -ge 1 ] &&
       [ "$(text_line_count "$UNINSTALL_PS1" 'bash leaves more behind than it')" -ge 1 ] && echo yes || echo no)"

# ===========================================================================
echo ""
echo "=== Section 6r: every backup leg covers the ROOT scope (U0.8, QA cycle 1) ==="
# THE DEFECT. U0.8's first cut added the docs subset to the copy surface and
# synced six places that name it — but the backup legs enumerated root-level
# files from a hardcoded list written before docs/ was shipped. An
# operator-edited docs/HOOKS.md was classified replace-custom, overwritten, and
# reported as "yours is in the backup" while the backup held no such file. Three
# arms reproduced it (v3 upgrade, mode-2 Update, fresh install).
#
# installer-v3-upgrade.sh section 11 proves the CONTRACT by execution on the bash
# side — the operator's bytes are recoverable, byte-exact, in all three arms.
# Nothing can execute the ps1, so its mirror is pinned textually here, and the
# structural properties that made the bug possible are pinned for BOTH: one
# helper, called from every leg, reading the SAME list the copy loop reads.
assert_eq "6r: install.sh defines the root-file backup helper exactly once" "1" \
    "$(code_line_count "$INSTALL_SH" 'backup_root_files() {')"
assert_eq "6r: install.ps1 defines its mirror exactly once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'function Copy-RootFiles {')"
# EVERY leg calls it. bash has four (v2 migration, v3 upgrade, mode 1, mode 2);
# install.ps1 has three because it redirects the v2 migration to install.sh
# rather than reimplementing it. The counts are asserted exactly: a leg that
# stops calling the helper is the defect returning.
assert_eq "6r: install.sh calls it from all FOUR backup legs (v2, v3, mode 1, mode 2)" "4" \
    "$(code_line_count "$INSTALL_SH" 'backup_root_files "')"
assert_eq "6r: install.ps1 calls it from all THREE of its legs (v3, mode 1, mode 2)" "3" \
    "$(code_line_count "$INSTALL_PS1" 'Copy-RootFiles -BackupDir')"
# ...and install.ps1 really does have only three, because the v2 path redirects.
assert_eq "6r: install.ps1 has exactly three .claude-tree backup sites to match" "3" \
    "$(code_line_count "$INSTALL_PS1" 'Copy-ClaudeTree -SourceTree')"
# THE STRUCTURAL FIX: the backup list is BUILT FROM the shipped-docs variable,
# not from a second literal. This is what makes a future addition to the subset
# impossible to omit from a backup — the property the original bug lacked.
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6r: install.sh's backup list is derived from \$SHIPPED_DOCS" "1" \
    "$(code_line_count "$INSTALL_SH" 'BACKUP_ROOT_FILES="CLAUDE.md .mcp.json LESSONS.md .worktreeinclude $SHIPPED_DOCS"')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "6r: install.ps1's is derived from \$ShippedDocs" "1" \
    "$(code_line_count "$INSTALL_PS1" '+ $ShippedDocs')"
# The docs list must be defined ABOVE the first backup leg in both files, or the
# derivation above reads an empty variable and the bug is back with the fix
# apparently in place. Line-order assertion, which is the only way to see it.
SH_DOCS_LINE=$(grep -n '^SHIPPED_DOCS=' "$INSTALL_SH" | head -1 | cut -d: -f1)
SH_FIRST_BACKUP=$(grep -n 'backup_root_files "' "$INSTALL_SH" | head -1 | cut -d: -f1)
assert_eq "6r: install.sh defines \$SHIPPED_DOCS before the first backup leg" "yes" \
    "$([ -n "$SH_DOCS_LINE" ] && [ -n "$SH_FIRST_BACKUP" ] && [ "$SH_DOCS_LINE" -lt "$SH_FIRST_BACKUP" ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
PS_DOCS_LINE=$(grep -n '\$ShippedDocs = @(' "$INSTALL_PS1" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
PS_LIST_LINE=$(grep -n '\$BackupRootFiles = @(' "$INSTALL_PS1" | head -1 | cut -d: -f1)
PS_FIRST_BACKUP=$(grep -n 'Copy-RootFiles -BackupDir' "$INSTALL_PS1" | head -1 | cut -d: -f1)
assert_eq "6r: install.ps1 defines \$ShippedDocs before \$BackupRootFiles before the first leg" "yes" \
    "$([ -n "$PS_DOCS_LINE" ] && [ -n "$PS_LIST_LINE" ] && [ -n "$PS_FIRST_BACKUP" ] &&
       [ "$PS_DOCS_LINE" -lt "$PS_LIST_LINE" ] && [ "$PS_LIST_LINE" -lt "$PS_FIRST_BACKUP" ] && echo yes || echo no)"
# The retired hardcoded root lists are GONE from both — a leftover would be a
# second source of truth for the same question.
assert_eq "6r: install.sh no longer iterates a hardcoded v3 root list" "0" \
    "$(code_line_count "$INSTALL_SH" 'for v3_root_file in CLAUDE.md .mcp.json LESSONS.md .worktreeinclude')"
# shellcheck disable=SC2016 # the searched-for text is the RETIRED hardcoded list being forbidden
assert_eq "6r: install.ps1 no longer iterates one either" "0" \
    "$(code_line_count "$INSTALL_PS1" 'foreach ($rootFile in @("CLAUDE.md", ".mcp.json", "LESSONS.md", ".worktreeinclude"))')"
# MIRRORED LAYOUT, the decision this change set made twice (trash + backup).
# Documented in both, so the next maintainer meets the reasoning rather than the
# rule alone.
for layout_anchor in 'A ROOT ROW KEEPS ITS RELATIVE PATH' 'MIRRORED'; do
    assert_eq "6r: install.sh documents the backup layout ('$layout_anchor')" "yes" \
        "$([ "$(text_line_count "$INSTALL_SH" "$layout_anchor")" -ge 1 ] && echo yes || echo no)"
    assert_eq "6r: install.ps1 documents it too" "yes" \
        "$([ "$(text_line_count "$INSTALL_PS1" "$layout_anchor")" -ge 1 ] && echo yes || echo no)"
done
# plugin.json stays FLAT — the one deliberate exception, which the L2 spec's 6f
# leg depends on. Pinned so "make it all mirrored" cannot quietly break 6f.
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6r: install.sh keeps plugin.json flat in the v3 backup" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" '"$V3_BACKUP_DIR/plugin.json"')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "6r: install.ps1 does too" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" '(Join-Path $V3BackupDir "plugin.json")')" -ge 1 ] && echo yes || echo no)"
# Both ROOT-BACKUP sentinel pairs, exactly once each. The L2 META at
# installer-v3-upgrade.sh 11d deletes the bash block by name.
for root_sentinel in "ROOT-BACKUP-START" "ROOT-BACKUP-END"; do
    assert_eq "6r: install.sh carries '$root_sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_SH" "$root_sentinel")"
    assert_eq "6r: install.ps1 carries '$root_sentinel' exactly once" "1" \
        "$(text_line_count "$INSTALL_PS1" "$root_sentinel")"
done
# The strip has to stay FAIL-OPEN: the sentinels sit INSIDE the helper, so
# deleting the block leaves a runnable no-op rather than call sites pointing at a
# function that no longer exists (which would abort the run under `set -e` and
# make the META unable to compare anything).
SH_STRIPPED_BACKUP="$WORK/install-root-backup-stripped.sh"
sed '/# ROOT-BACKUP-START/,/# ROOT-BACKUP-END/d' "$INSTALL_SH" > "$SH_STRIPPED_BACKUP"
assert_eq "6r: stripping the block leaves install.sh valid bash (fail-open)" "yes" \
    "$(bash -n "$SH_STRIPPED_BACKUP" 2>/dev/null && echo yes || echo no)"
assert_eq "6r: ...with the helper still DEFINED (so the four call sites resolve)" "1" \
    "$(code_line_count "$SH_STRIPPED_BACKUP" 'backup_root_files() {')"
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6r: ...and the copy loop inside it gone" "0" \
    "$(code_line_count "$SH_STRIPPED_BACKUP" 'for rel in $BACKUP_ROOT_FILES; do')"

# --- the fresh-install guard (arm C) --------------------------------------
# The fresh path has no plan, no verdict walk and no backup directory, so the
# guard is a pre-copy exists-and-differs check that parks the operator's bytes at
# <path>.bak. docs/ is the only shipped scope where this can happen at all.
assert_eq "6r: install.sh defines the fresh-install docs guard once" "1" \
    "$(code_line_count "$INSTALL_SH" 'preserve_pre_existing_doc() {')"
assert_eq "6r: install.ps1 defines its mirror once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'function Save-PreExistingDoc {')"
# The copy is CONDITIONAL on the guard succeeding in both: a failed preservation
# refuses the copy rather than overwriting anyway.
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6r: install.sh only copies a doc when preservation succeeded" "1" \
    "$(code_line_count "$INSTALL_SH" 'if preserve_pre_existing_doc "$SOURCE_DIR/$shipped_doc" "$TARGET/$shipped_doc"; then')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "6r: install.ps1 does the same" "1" \
    "$(code_line_count "$INSTALL_PS1" 'if (Save-PreExistingDoc -Src $docSrc -Dst $docDst) {')"
# Both use the .bak suffix (the installer's existing convention for a preserved
# pre-write copy), and both say so on the readout — a silent overwrite was the
# whole problem on this arm.
assert_eq "6r: install.sh names the .bak sidecar on the readout" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" 'your copy saved as')" -ge 1 ] && echo yes || echo no)"
assert_eq "6r: install.ps1 uses the same wording" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" 'your copy saved as')" -ge 1 ] && echo yes || echo no)"
# Gated on exists-AND-DIFFERS, so a re-run over an already-shipped doc leaves no
# litter; and skipped on the verdict paths, which take a real backup instead.
# shellcheck disable=SC2016 # the searched-for text is literal shell source, never an expansion
assert_eq "6r: install.sh's guard is a no-op under VERDICT_MODE" "yes" \
    "$([ "$(code_line_count "$INSTALL_SH" '[ "$VERDICT_MODE" = true ] && return 0')" -ge 1 ] && echo yes || echo no)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "6r: install.ps1's guard is a no-op under \$script:VerdictMode" "yes" \
    "$([ "$(code_line_count "$INSTALL_PS1" 'if ($script:VerdictMode) { return $true }')" -ge 1 ] && echo yes || echo no)"

# ===========================================================================
echo ""
echo "=== Section 7: META-TESTs for the U0.7 parity checks ==="
# Each mutates a COPY of install.ps1 (or uninstall.ps1) and asserts the matching
# section-6 check FAILS. Without them, a checker anchored on a string that no
# longer exists would look identical to a passing suite.

PS_COPY="$WORK/install-mutant.ps1"

# --- META 8: break one verdict label -------------------------------------
sed 's/preserved (yours)/preserved (theirs)/' "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 8: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
assert_eq "META 8: the broken label makes the verdict-label check FAIL (count 0)" "0" \
    "$(text_line_count "$PS_COPY" 'preserved (yours)')"
assert_eq "META 8: and the mutation is surgical — the other five labels survive" "yes" \
    "$([ "$(text_line_count "$PS_COPY" 'merged key-wise')" -ge 1 ] &&
       [ "$(text_line_count "$PS_COPY" 'already current')" -ge 1 ] && echo yes || echo no)"

# --- META 9 (3t1): reintroduce Out-File at a merge write site ------------
# The exact pre-fix line, restored: `Out-File -Encoding UTF8` is a BOM under
# Windows PowerShell 5.1 and `-NoNewline` concatenates jq's output lines.
# shellcheck disable=SC2016 # the replacement text IS PowerShell source
sed 's#^\( *\)Write-LfFile -FilePath \$TargetMcpJson -Lines @(\$mcpMerged)#\1$mcpMerged | Out-File -FilePath $TargetMcpJson -Encoding UTF8 -NoNewline#' \
    "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 9: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation
assert_eq "META 9: the pre-fix Out-File line really is back" "1" \
    "$(code_line_count "$PS_COPY" '$mcpMerged | Out-File -FilePath $TargetMcpJson')"
assert_eq "META 9: the Out-File-on-JSON-path check FAILS (1, not 0)" "1" \
    "$(outfile_on_json_paths "$PS_COPY")"
assert_eq "META 9: the -NoNewline-on-JSON-path check FAILS too" "1" \
    "$(nonewline_on_json_paths "$PS_COPY")"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation
assert_eq "META 9: and the .mcp.json LF-writer assertion FAILS (0, not 1)" "0" \
    "$(code_line_count "$PS_COPY" 'Write-LfFile -FilePath $TargetMcpJson')"
# Surgical: the settings write site is untouched, so 6i's other half still holds.
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation
assert_eq "META 9: the mutation is surgical — the settings LF write survives" "1" \
    "$(code_line_count "$PS_COPY" 'Write-LfFile -FilePath $SettingsFile')"

# --- META 10 (3t1): swap the jq merge operands ---------------------------
# shellcheck disable=SC2016 # the replacement text IS PowerShell source
sed 's#jq -s \$McpMergeJq \$TargetMcpJson \$SourceMcpJson#jq -s $McpMergeJq $SourceMcpJson $TargetMcpJson#' \
    "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 10: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "META 10: the swapped operands flip the union direction (shipped first)" \
    "shipped existing" \
    "$(arg_role_order "$PS_COPY" 'jq -s $McpMergeJq' '$TargetMcpJson' '$SourceMcpJson')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "META 10: which no longer matches install.sh's order" "no" \
    "$([ "$SH_MCP_ORDER" = "$(arg_role_order "$PS_COPY" 'jq -s $McpMergeJq' '$TargetMcpJson' '$SourceMcpJson')" ] && echo yes || echo no)"

# --- META 11: rename a sentinel -----------------------------------------
sed 's/NOCHANGE-PROBE-START/NOCHANGE-PROBE-BEGIN/' "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 11: renaming the sentinel makes the exactly-once check FAIL (count 0)" "0" \
    "$(text_line_count "$PS_COPY" 'NOCHANGE-PROBE-START')"
assert_eq "META 11: and its END partner is still there (so the pair check is what catches it)" "1" \
    "$(text_line_count "$PS_COPY" 'NOCHANGE-PROBE-END')"

# --- META 12: drop one surface rule from the ps1 enumeration -------------
# The drift shape this section exists to catch: a release adds (or removes) a
# shipped file on one side only. Here the model-roles rule is deleted from the
# PowerShell surface; the set comparison must stop matching.
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
sed '/Get-SurfaceFileRow  -Root $Root -Class "operator" -Rel ".claude\/model-roles"/d' \
    "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 12: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
META_SURFACE_PS=$(surface_pairs_ps "$PS_COPY")
assert_eq "META 12: the mutated copy really lost exactly one surface rule" \
    "$(( $(printf '%s\n' "$SURFACE_PS" | grep -c . | tr -d ' \n') - 1 ))" \
    "$(printf '%s\n' "$META_SURFACE_PS" | grep -c . | tr -d ' \n')"
assert_eq "META 12: and the surface-parity assertion FAILS" "different" \
    "$([ "$SURFACE_SH" = "$META_SURFACE_PS" ] && echo same || echo different)"

# --- META 13b: restore the dotfile-blind backup form --------------------
# The pre-U0.7 line, put back at the mode-1 site. It is the PowerShell spelling of
# `cp -r dir/*`: hidden children — .claude/.qa-tracking/, the entire gate history
# of a live install — never reach the backup.
# shellcheck disable=SC2016 # the replacement text IS PowerShell source
sed 's#^\( *\)Copy-ClaudeTree -SourceTree \$ClaudeDir -BackupDir \$BackupDir#\1Copy-Item -Path $ClaudeDir -Destination $BackupDir -Recurse#' \
    "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 13b: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell/shell source, never an expansion
assert_eq "META 13b: the dotfile-blind form is detected (count >= 1, not 0)" "yes" \
    "$([ "$(code_line_count "$PS_COPY" 'Copy-Item -Path $ClaudeDir')" -ge 1 ] && echo yes || echo no)"
assert_eq "META 13b: and the all-sites-use-the-helper count FAILS (fewer than 3)" "yes" \
    "$([ "$(code_line_count "$PS_COPY" 'Copy-ClaudeTree -SourceTree')" -lt 3 ] && echo yes || echo no)"

# --- META 14 (R1-F1): plant an em dash inside a string -------------------
# The exact defect QA found: a UTF-8 em dash inside a double-quoted string of a
# BOM-less .ps1. Planted in a COPY, the guard must catch it — and must go on
# ignoring the file's em-dash-heavy COMMENT prose, or it would be a rule nobody
# could keep.
# shellcheck disable=SC2016 # the replacement text IS PowerShell source
sed 's#^\( *\)Write-Color "Merge mode: will skip existing files" Yellow#\1Write-Color "Merge mode — will skip existing files" Yellow#' \
    "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 14: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
assert_eq "META 14: the planted em dash really is inside a double-quoted string" "1" \
    "$(grep -c 'Write-Color "Merge mode — will skip existing files"' "$PS_COPY" | tr -d ' \n')"
assert_eq "META 14: the ASCII guard FAILS on the planted copy (1, not 0)" "1" \
    "$(nonascii_outside_comments "$PS_COPY")"
assert_eq "META 14: and the unmutated file still passes (the guard is not just counting em dashes)" "0" \
    "$(nonascii_outside_comments "$INSTALL_PS1")"
# The same guard applied to uninstall.ps1, whose HEAD version was ASCII-clean and
# which this change set is what put non-ASCII comment prose into.
# shellcheck disable=SC2016 # the replacement text IS PowerShell source
sed 's#^\( *\)Write-Host "Cancelled."#\1Write-Host "Cancelled — nothing was moved."#' \
    "$UNINSTALL_PS1" > "$WORK/uninstall-emdash.ps1"
assert_eq "META 14: the uninstall.ps1 mutation actually changed the copy" "1" \
    "$(cmp -s "$WORK/uninstall-emdash.ps1" "$UNINSTALL_PS1" && echo 0 || echo 1)"
assert_eq "META 14: the guard FAILS there too (1, not 0)" "1" \
    "$(nonascii_outside_comments "$WORK/uninstall-emdash.ps1")"

# --- META 15 (R1-F1): the composed dash is resolved, not rubber-stamped --
# probe_readout resolves `$([char]0x2014)` back to an em dash so 6g compares the
# RENDERED sentences. Compose a DIFFERENT character (0x2013, en dash) and the
# comparison must stop matching — otherwise the resolve step would be hiding any
# drift at that site rather than normalising a known spelling.
# shellcheck disable=SC2016 # the replacement text IS PowerShell source
sed 's/\$(\[char\]0x2014)/$([char]0x2013)/' "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 15: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
assert_eq "META 15: the wrong code point survives the resolve step unresolved" "yes" \
    "$(probe_readout "$PS_COPY" | grep -qF '0x2013' && echo yes || echo no)"
assert_eq "META 15: so the byte-identity assertion FAILS" "different" \
    "$([ "$SH_PROBE" = "$(probe_readout "$PS_COPY")" ] && echo same || echo different)"
assert_eq "META 15 companion: the unmutated file still matches after the same resolve" "same" \
    "$([ "$SH_PROBE" = "$(probe_readout "$INSTALL_PS1")" ] && echo same || echo different)"

# --- META 13 (wn4): strip the containment block from uninstall.ps1 -------
UNINSTALL_COPY="$WORK/uninstall-mutant.ps1"
sed '/# WN4-CONTAINMENT-START/,/# WN4-CONTAINMENT-END/d' "$UNINSTALL_PS1" > "$UNINSTALL_COPY"
assert_eq "META 13: the mutation actually changed the uninstall.ps1 copy" "1" \
    "$(cmp -s "$UNINSTALL_COPY" "$UNINSTALL_PS1" && echo 0 || echo 1)"
assert_eq "META 13: the stripped copy fails the sentinel check (count 0)" "0" \
    "$(text_line_count "$UNINSTALL_COPY" 'WN4-CONTAINMENT-START')"
assert_eq "META 13: and loses the reparse-point refusal entirely" "0" \
    "$(code_line_count "$UNINSTALL_COPY" '[System.IO.FileAttributes]::ReparsePoint')"

# ===========================================================================
echo ""
echo "=== Section 7b: META-TESTs for the U0.8 parity checks ==="
# Same discipline as section 7: every checker added by U0.8 gets a mutation that
# makes it fail. Four new checkers, four METAs — 6n's gitignore comparison, 6o's
# five-way docs set, 6p's merged-file sentence identity, and 6m's branding rule.

# --- META 16 (6n): drop one entry from the ps1 .gitignore list ------------
# The drift shape 6n exists for: an entry added to one installer and not the
# other. *.new is the one to remove — it is the entry an operator most notices
# when it is missing, because every upgrade leaves sidecars behind.
sed "/^ *'\*\.new'\$/d" "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 16: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
META_GITIGNORE_PS=$(gitignore_from_ps "$PS_COPY")
assert_eq "META 16: the mutated list really lost exactly one line" \
    "$(( $(printf '%s\n' "$GITIGNORE_PS" | grep -c . | tr -d ' \n') - 1 ))" \
    "$(printf '%s\n' "$META_GITIGNORE_PS" | grep -c . | tr -d ' \n')"
assert_eq "META 16: and it was the *.new entry" "no" \
    "$(printf '%s\n' "$META_GITIGNORE_PS" | gitignore_entries | grep -qxF -- '*.new' && echo yes || echo no)"
assert_eq "META 16: -> 6n's line-for-line equality FAILS" "different" \
    "$([ "$GITIGNORE_SH" = "$META_GITIGNORE_PS" ] && echo same || echo different)"

# --- META 17 (6o): drop one doc from the ps1 copy loop --------------------
# A copy loop that stops shipping a file the manifest still enumerates. Every
# parity spec downstream would fail on a real install, which is the point — but
# the FIVE-WAY set check is what names the cause in one line instead of leaving a
# "docs/CODEX_SETUP.md (absent)" to be traced back by hand.
# shellcheck disable=SC2016 # the replacement text IS PowerShell source
sed 's#^\( *\)\$ShippedDocs = @("docs/CODEX_SETUP.md", "docs/HOOKS.md")#\1$ShippedDocs = @("docs/HOOKS.md")#' \
    "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 17: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
assert_eq "META 17: the mutated copy loop iterates only one doc" \
    "docs/HOOKS.md" "$(docs_from_copy_block "$PS_COPY")"
assert_eq "META 17: -> 6o's five-way agreement FAILS" "different" \
    "$([ "$DOCS_EXPECTED" = "$(docs_from_copy_block "$PS_COPY")" ] && echo same || echo different)"
# Surgical: the SURFACE still enumerates both, which is precisely the
# manifest-says-yes / installer-says-no state 6o detects.
assert_eq "META 17: the mutation is surgical — the ps1 SURFACE still names both" \
    "$DOCS_EXPECTED" "$(docs_from_surface_ps "$PS_COPY")"

# --- META 18 (6p): reword one merged-file sentence in the ps1 ------------
# The R1-F2 regression, restored on one arm: the .mcp.json refusal goes back to
# claiming the shipped file was installed with nothing to merge. That is the
# sentence v4.0 printed for a file whose merge had FAILED, so the mutation is the
# defect itself rather than an arbitrary string change.
sed 's/MERGE REFUSED - yours was not a single JSON object, so the SHIPPED config was installed over it; yours is at .mcp.json.bak. Re-add your own servers from there./installed as shipped; nothing to merge/' \
    "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 18: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
META_MERGE_LINES=$(merge_status_lines "$PS_COPY")
assert_eq "META 18: the reworded arm lost the MERGE REFUSED sentence" "no" \
    "$(printf '%s\n' "$META_MERGE_LINES" | grep -qF 'MERGE REFUSED' && echo yes || echo no)"
assert_eq "META 18: -> 6p's file-to-file sentence identity FAILS" "different" \
    "$([ "$MERGE_LINES_SH" = "$META_MERGE_LINES" ] && echo same || echo different)"
# The collapse is visible in the DISTINCT count, not the line count: the reworded
# arm now renders the same sentence as the shipped-nothing-to-merge arm, so seven
# arms still emit seven lines but only six different sentences. Stated as
# distinct-vs-total because that IS the defect — two states the operator has to
# tell apart, printing identical text.
assert_eq "META 18: ...and two arms now render the SAME sentence (6 distinct of 7)" "6" \
    "$(printf '%s\n' "$META_MERGE_LINES" | LC_ALL=C sort -u | grep -c . | tr -d ' \n')"
assert_eq "META 18 companion: the real installers render seven DISTINCT sentences" "7" \
    "$(printf '%s\n' "$MERGE_LINES_SH" | LC_ALL=C sort -u | grep -c . | tr -d ' \n')"

# --- META 19 (6m): put the stale v3 branding back -----------------------
# Restored at the ps1 banner, which is where it actually lived for the whole of
# v4.0. Both halves of 6m must react: the hardcode check finds it, and the
# interpolation check stops finding the label.
# shellcheck disable=SC2016 # the replacement text IS PowerShell source
sed 's/^Write-Color \$BrandLabel Cyan$/Write-Color "Claude Workflow Plugin v3" Cyan/' \
    "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 19: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
assert_eq "META 19: -> the no-hardcode check FAILS (count 1, not 0)" "1" \
    "$(text_line_count "$PS_COPY" 'Claude Workflow Plugin v3')"
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "META 19: -> and the interpolated-banner check FAILS (count 0, not 1)" "0" \
    "$(code_line_count "$PS_COPY" 'Write-Color $BrandLabel Cyan')"
# The unmutated file still passes both, so META 19 is about the mutation and not
# about a checker that flags everything.
# shellcheck disable=SC2016 # the searched-for text is literal PowerShell source
assert_eq "META 19 companion: the real install.ps1 still passes both halves" "0 1" \
    "$(printf '%s %s' \
        "$(text_line_count "$INSTALL_PS1" 'Claude Workflow Plugin v3')" \
        "$(code_line_count "$INSTALL_PS1" 'Write-Color $BrandLabel Cyan')")"

# --- META 20 (6n): the gitignore block is EXECUTED, not scraped ----------
# gitignore_from_sh runs the real heredoc. If it ever degraded to "print the
# lines between the sentinels", a body that no longer wrote a .gitignore at all
# would still produce output and 6n would pass on a broken installer. Mutate a
# COPY so the heredoc writes to a DIFFERENT filename and the extractor must come
# back empty — which only an executing extractor can notice.
SH_COPY_GI="$WORK/install-gitignore-mutant.sh"
sed 's/^            cat > "\.gitignore" << '"'"'GITIGNORE_EOF'"'"'$/            cat > ".not-a-gitignore" << '"'"'GITIGNORE_EOF'"'"'/' \
    "$INSTALL_SH" > "$SH_COPY_GI"
assert_eq "META 20: the mutation actually changed the sh copy" "1" \
    "$(cmp -s "$SH_COPY_GI" "$INSTALL_SH" && echo 0 || echo 1)"
assert_eq "META 20: the mutant no longer writes .gitignore" "0" \
    "$(code_line_count "$SH_COPY_GI" 'cat > ".gitignore" <<')"
assert_eq "META 20: -> the executing extractor returns NOTHING for it" "" \
    "$(gitignore_from_sh "$SH_COPY_GI" 2>/dev/null || printf '')"
assert_eq "META 20: -> so 6n's equality FAILS" "different" \
    "$([ "$(gitignore_from_sh "$SH_COPY_GI" 2>/dev/null || printf '')" = "$GITIGNORE_PS" ] && echo same || echo different)"

# --- META 21 (6r): drop the root-file backup call from one ps1 leg --------
# THE DEFECT SHAPE, on the side nothing can execute: a backup leg that stops
# covering the root scope. QA reproduced this on the bash mode-2 leg — the arm the
# v4.0 -> v4.1 population actually runs — so the mutation targets the ps1 mirror
# of exactly that leg. 6r's exact-count assertion is what has to notice.
# The call site is located by NUMBER rather than by an indentation-sensitive
# pattern: the three legs sit at three different nesting depths, and a literal
# leading-space count in a sed script is exactly the kind of anchor that rots
# into a silent no-op after a reindent. The LAST occurrence is the mode-2 leg,
# asserted below rather than assumed.
META21_LINE=$(grep -n 'Copy-RootFiles -BackupDir' "$INSTALL_PS1" | tail -1 | cut -d: -f1)
assert_eq "META 21: the targeted call site was located" "yes" \
    "$([ -n "$META21_LINE" ] && echo yes || echo no)"
# It really is the mode-2 leg: the line after it is that leg's own readout.
assert_eq "META 21: ...and it is the mode-2 leg (its readout follows)" "yes" \
    "$(sed -n "$((META21_LINE + 1))p" "$INSTALL_PS1" | grep -qF 'OK Backup created' && echo yes || echo no)"
awk -v skip="$META21_LINE" 'NR != skip' "$INSTALL_PS1" > "$PS_COPY"
assert_eq "META 21: the mutation actually changed the ps1 copy" "1" \
    "$(cmp -s "$PS_COPY" "$INSTALL_PS1" && echo 0 || echo 1)"
assert_eq "META 21: the mutant really lost exactly one call site (3 -> 2)" "2" \
    "$(code_line_count "$PS_COPY" 'Copy-RootFiles -BackupDir')"
assert_eq "META 21: -> 6r's all-legs-covered count FAILS" "no" \
    "$([ "$(code_line_count "$PS_COPY" 'Copy-RootFiles -BackupDir')" = "3" ] && echo yes || echo no)"
# Surgical: the helper and the other legs survive, so the flip is about the
# missing call and not about a mutant that lost the whole mechanism.
assert_eq "META 21: the mutation is surgical — the helper is still defined" "1" \
    "$(code_line_count "$PS_COPY" 'function Copy-RootFiles {')"
assert_eq "META 21: ...and the .claude-tree backup sites are untouched" "3" \
    "$(code_line_count "$PS_COPY" 'Copy-ClaudeTree -SourceTree')"

# --- META 22 (6m): plugin_json_version reads the TOP-LEVEL version --------
# QA raised this as non-blocking: the extractor is `sed -n | head -1`, so a loose
# `^[[:space:]]*"version"` anchor takes the FIRST own-line "version" key at ANY
# depth — correct today only because the shipped manifest happens to list the
# top-level key first. The anchor was tightened to the top-level indent depth
# instead of leaving the behaviour to file layout, and this META is the witness
# for both halves: the tightened anchor is right, and the loose one really was
# wrong on the same fixture (so the tightening is not cosmetic).
#
# The EXTRACTOR IS TAKEN FROM install.sh, not retyped: a copied regex would test
# this file's idea of the rule rather than the shipped one.
PJV_SCRATCH="$WORK/pjv"
mkdir -p "$PJV_SCRATCH"
PJV_SED=$(awk '/^plugin_json_version\(\) \{/, /^\}/' "$INSTALL_SH" \
    | sed -n "s/^[[:space:]]*sed -n '\(.*\)'.*/\1/p" | head -1)
assert_eq "META 22: the extractor's sed program was extracted from install.sh" "yes" \
    "$([ -n "$PJV_SED" ] && echo yes || echo no)"
# The dangerous fixture: a nested "version" on its OWN line, BEFORE the
# top-level one. (An INLINE nested key was never a risk — the anchor requires
# "version" to be the first token on its line — which is why the fixture nests it
# across lines.)
printf '{\n  "mcpServers": {\n    "a": {\n      "version": "0.0.1"\n    }\n  },\n  "version": "9.9.9"\n}\n' \
    > "$PJV_SCRATCH/nested-first.json"
assert_eq "META 22: the SHIPPED extractor returns the top-level version on the hostile fixture" "9.9.9" \
    "$(sed -n "$PJV_SED" "$PJV_SCRATCH/nested-first.json" | head -1)"
# The regression witness: the anchor it replaced returns the WRONG string on that
# same fixture. Without this the tightening would look like a style change.
assert_eq "META 22: the retired loose anchor returned the NESTED version instead" "0.0.1" \
    "$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$PJV_SCRATCH/nested-first.json" | head -1)"
# ...and the loose anchor is no longer in install.sh.
assert_eq "META 22: install.sh no longer carries the loose anchor" "0" \
    "$(code_line_count "$INSTALL_SH" 's/^[[:space:]]*"version"')"
# On the REAL manifest the shipped extractor agrees with jq — the two independent
# readers of the same field.
assert_eq "META 22: on the real plugin.json the extractor agrees with jq" \
    "$BRAND_EXPECTED_VERSION" \
    "$(sed -n "$PJV_SED" "$PROJECT_DIR/.claude-plugin/plugin.json" | head -1)"
# A reformat to another indent width yields EMPTY rather than a wrong value, and
# 6m's EXECUTED --help check then fails loudly. Empty-or-loud is the correct
# failure mode for a branding string.
printf '{\n    "version": "9.9.9"\n}\n' > "$PJV_SCRATCH/four-space.json"
assert_eq "META 22: a differently-indented manifest yields EMPTY, never a wrong version" "" \
    "$(sed -n "$PJV_SED" "$PJV_SCRATCH/four-space.json" | head -1)"
assert_eq "META 22: ...and 6m's executed --help check is what catches that" "yes" \
    "$(printf '%s' "$BRAND_HELP_OUT" | grep -qF "Claude Workflow Plugin v$BRAND_EXPECTED_VERSION installer" && echo yes || echo no)"

# --- Summary ---------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

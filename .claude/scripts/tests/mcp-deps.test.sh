#!/bin/bash
# mcp-deps.test.sh — L1 unit fixture for the shipped MCP servers' DEPENDENCY
# and SURFACE contracts (v4.1 / claude-workflow-plugin-0fc, epic 2br).
#
# WHY THESE ASSERTIONS EXIST.
#
# Symptom 2 of the v4 P0 was "both MCP servers unavailable in every
# curl-installed target". The single sufficient cause was that server
# dependencies are never installed there: install.sh excludes node_modules from
# the copy, and under `curl | bash` the source is a shallow clone in which
# .gitignore's `node_modules/` meant there was never anything to copy. The fix
# is `npm ci --omit=dev` in the target — and that fix is only cheap and only
# safe because of four facts about the two lockfiles:
#
#   - both are GIT-TRACKED (npm ci refuses without a lockfile, so an untracked
#     lockfile means a fresh clone can never install);
#   - both are lockfileVersion 3 (what the pinned npm understands);
#   - both have ZERO packages with hasInstallScript, so `--ignore-scripts` is a
#     no-op and the air-gapped recipe needs no build toolchain;
#   - both have ZERO dev packages, so `--omit=dev` cannot remove anything the
#     servers need at runtime.
#
# Every one of those is an ASSUMPTION the installer and the doctor's --help
# recipe now depend on. A future dependency bump that introduces a native
# module with a postinstall step, or a runtime dep marked dev, must fail HERE —
# loudly, at the place where the decision about --ignore-scripts / --omit=dev
# was made — rather than silently in a user's target six months later.
#
# The second half of the file pins the TOOL-COUNT table as ONE contract living
# in four places: DOCTOR_TOOL_COUNTS in workflow-doctor.sh, the `N tools total.`
# sentence in each server README, and the Tools column of docs/MCP_SERVERS.md.
# The doctor asserts EXACT tool-count equality at boot, so a table that drifts
# from the docs turns a real surface change into a mysterious doctor failure
# (or, worse, hides one).
#
# META-TESTs (anchored to unique TEXT patterns, never line numbers; both work
# on synthetic copies so no repo file is ever mutated):
#
#   META-TEST 1  bumping a DOCTOR_TOOL_COUNTS entry by one makes the
#                table-vs-README cross-check FAIL. Control asserts it agrees on
#                the real table first.
#   META-TEST 2  the lockfile readers are not vacuous: a synthetic lockfile
#                carrying hasInstallScript:true reports 1 (not 0), one carrying
#                dev:true reports 1 (not 0), and a MALFORMED lockfile reports a
#                loud READER-ERROR rather than a comfortable 0.
#
# Exit codes: 0 all assertions pass, 1 otherwise, 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
DOCTOR="$PROJECT_DIR/.claude/scripts/workflow-doctor.sh"
MCP_ROOT="$PROJECT_DIR/.claude/mcp"
MCP_DOC="$PROJECT_DIR/docs/MCP_SERVERS.md"
MCP_JSON="$PROJECT_DIR/.mcp.json"
PLUGIN_JSON="$PROJECT_DIR/.claude-plugin/plugin.json"

for f in "$DOCTOR" "$MCP_DOC" "$MCP_JSON" "$PLUGIN_JSON"; do
    [ -f "$f" ] || {
        printf 'mcp-deps.test: required file missing: %s\n' "$f" >&2
        exit 2
    }
done
for tool in jq awk sed git; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'mcp-deps.test: %s is required\n' "$tool" >&2
        exit 2
    }
done

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

WORK=$(mktemp -d -t mcp-deps-test.XXXXXX) || {
    printf 'mcp-deps.test: mktemp failed\n' >&2
    exit 2
}
# cleanup runs only via the EXIT trap; the analyzer can't see that indirection.
# shellcheck disable=SC2329,SC2317
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Readers. Each one FAILS LOUDLY rather than defaulting to a comfortable
# value: a reader that errors and answers "0" makes an
# "assert zero install scripts" test green for a lockfile it could not even
# parse. META-TEST 2 pins that property.
# ---------------------------------------------------------------------------

lock_version() {
    jq -r 'if type == "object" and has("lockfileVersion") then .lockfileVersion else "READER-ERROR" end' \
        "$1" 2>/dev/null || printf 'READER-ERROR'
}

lock_package_count() {
    jq -r 'if type == "object" and (.packages | type) == "object"
           then (.packages | length) else "READER-ERROR" end' "$1" 2>/dev/null \
        || printf 'READER-ERROR'
}

lock_install_script_count() {
    jq -r 'if type == "object" and (.packages | type) == "object"
           then ([.packages | to_entries[] | select(.value.hasInstallScript == true)] | length)
           else "READER-ERROR" end' "$1" 2>/dev/null || printf 'READER-ERROR'
}

lock_dev_package_count() {
    jq -r 'if type == "object" and (.packages | type) == "object"
           then ([.packages | to_entries[] | select(.value.dev == true)] | length)
           else "READER-ERROR" end' "$1" 2>/dev/null || printf 'READER-ERROR'
}

# The DOCTOR_TOOL_COUNTS table from a given copy of workflow-doctor.sh.
doctor_table() {
    sed -n 's/^DOCTOR_TOOL_COUNTS="\(.*\)"$/\1/p' "$1" | head -1
}

# table_count <doctor-script> <server-dir> — the pinned count, or READER-ERROR.
table_count() {
    local pair found=""
    for pair in $(doctor_table "$1"); do
        case "$pair" in
            "$2":*) found="${pair#*:}" ;;
        esac
    done
    printf '%s' "${found:-READER-ERROR}"
}

# readme_tool_count <server-dir> — the leading number of the README's
# `^<N> tools total.` line. Anchored at line start so the many other
# "N tools"/"N tests" phrases in the prose cannot be mistaken for the claim.
readme_tool_count() {
    local n
    n=$(sed -n 's/^\([0-9][0-9]*\) tools total\..*/\1/p' "$MCP_ROOT/$1/README.md" 2>/dev/null)
    if [ "$(printf '%s\n' "$n" | grep -c . || true)" != "1" ]; then
        printf 'READER-ERROR'
        return
    fi
    printf '%s' "$n"
}

# readme_count_line_count <server-dir> — how many lines match the anchor. Must
# be exactly 1, or readme_tool_count's answer is ambiguous.
readme_count_line_count() {
    grep -cE '^[0-9]+ tools total\.' "$MCP_ROOT/$1/README.md" 2>/dev/null | tr -d ' ' || printf '0'
}

# doc_tool_count <mcp-json-key> — the Tools cell for a row of the server table
# in docs/MCP_SERVERS.md. The Tools column index is located from the HEADER
# row, so inserting a column upstream cannot silently shift the reader onto a
# different cell.
doc_tool_count() {
    awk -v want="$1" '
        BEGIN { col = 0 }
        /^\|/ {
            n = split($0, cells, "|")
            for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", cells[i]) }
            if (col == 0) {
                for (i = 1; i <= n; i++) { if (cells[i] == "Tools") { col = i } }
                next
            }
            key = cells[2]
            gsub(/`/, "", key)
            if (key == want) { print cells[col]; exit }
        }
        END { if (col == 0) print "READER-ERROR" }
    ' "$MCP_DOC" 2>/dev/null || printf 'READER-ERROR'
}

# mcp_key_for <server-dir> — the .mcp.json key a server dir maps to
# (bd-mcp -> bd, code-graph-mcp -> code-graph).
mcp_key_for() { printf '%s' "${1%-mcp}"; }

# starts_with <string> <prefix> — print "true"/"false". A function rather than
# an inline `case`: bash 3.2's command-substitution lexer reads a case pattern's
# `)` as the closing paren of `$( ... )`, so `$(case ... esac)` is a syntax
# error there. shellcheck accepts the inline form, so this only shows up at run
# time on macOS — hence the helper.
starts_with() {
    case "$1" in
        "$2"*) printf 'true' ;;
        *)     printf 'false' ;;
    esac
}

# ---------------------------------------------------------------------------
# Discover the server dirs on disk. Everything below is driven off this list
# plus the table, so a third server cannot be added without either being
# covered or making the 1:1 assertions fail.
# ---------------------------------------------------------------------------
SERVER_DIRS=""
for d in "$MCP_ROOT"/*/; do
    [ -d "$d" ] || continue
    SERVER_DIRS="$SERVER_DIRS $(basename "$d")"
done
SERVER_DIRS="${SERVER_DIRS# }"

TABLE=$(doctor_table "$DOCTOR")

# ===========================================================================
echo "=== Section 1: lockfile contracts (what makes 'npm ci --omit=dev' safe) ==="

# Non-vacuity guard for the whole section: assertions of the form "zero
# packages have property X" are trivially true over an empty package set.
assert_eq "lockfiles: at least one MCP server dir exists to assert about" "true" \
    "$([ -n "$SERVER_DIRS" ] && echo true || echo false)"

for server in $SERVER_DIRS; do
    LOCK="$MCP_ROOT/$server/package-lock.json"
    PKG="$MCP_ROOT/$server/package.json"

    assert_eq "lockfiles: $server/package-lock.json exists" "true" \
        "$([ -f "$LOCK" ] && echo true || echo false)"

    # git ls-files, not `git status`: an untracked lockfile is invisible to a
    # fresh clone, so `npm ci` in a target would refuse.
    TRACKED=$(git -C "$PROJECT_DIR" ls-files --error-unmatch \
        ".claude/mcp/$server/package-lock.json" 2>/dev/null || echo "")
    assert_eq "lockfiles: $server/package-lock.json is GIT-TRACKED (npm ci refuses without it)" \
        ".claude/mcp/$server/package-lock.json" "$TRACKED"

    PKG_TRACKED=$(git -C "$PROJECT_DIR" ls-files --error-unmatch \
        ".claude/mcp/$server/package.json" 2>/dev/null || echo "")
    assert_eq "lockfiles: $server/package.json is GIT-TRACKED" \
        ".claude/mcp/$server/package.json" "$PKG_TRACKED"

    assert_eq "lockfiles: $server lockfileVersion is 3" "3" "$(lock_version "$LOCK")"

    PKG_COUNT=$(lock_package_count "$LOCK")
    # A lockfile with a near-empty package map would make the two zero-count
    # assertions below meaningless; pin a floor so they stay load-bearing.
    assert_eq "lockfiles: $server lockfile describes a real dependency tree (> 10 packages)" "true" \
        "$([ "$PKG_COUNT" != "READER-ERROR" ] && [ "${PKG_COUNT:-0}" -gt 10 ] && echo true || echo false)"

    assert_eq "lockfiles: $server has ZERO packages with hasInstallScript (--ignore-scripts is a no-op)" \
        "0" "$(lock_install_script_count "$LOCK")"
    assert_eq "lockfiles: $server has ZERO dev packages (--omit=dev removes nothing needed)" \
        "0" "$(lock_dev_package_count "$LOCK")"

    # The engines pin the installer's node prerequisite is derived from.
    ENGINES=$(jq -r '.engines.node // ""' "$PKG" 2>/dev/null || echo "")
    assert_eq "lockfiles: $server/package.json declares an engines.node range" "true" \
        "$([ -n "$ENGINES" ] && echo true || echo false)"
done

# ===========================================================================
echo ""
echo "=== Section 2: the tool-count table is ONE contract in four places ==="

assert_eq "table: exactly one BEGIN DOCTOR_TOOL_COUNTS sentinel" "1" \
    "$(grep -c '^# BEGIN DOCTOR_TOOL_COUNTS' "$DOCTOR" | tr -d ' ')"
assert_eq "table: exactly one END DOCTOR_TOOL_COUNTS sentinel" "1" \
    "$(grep -c '^# END DOCTOR_TOOL_COUNTS' "$DOCTOR" | tr -d ' ')"
assert_eq "table: the sentinel block yields a non-empty table" "true" \
    "$([ -n "$TABLE" ] && echo true || echo false)"

TABLE_ENTRIES=$(printf '%s' "$TABLE" | wc -w | tr -d ' ')
SERVER_DIR_COUNT=$(printf '%s' "$SERVER_DIRS" | wc -w | tr -d ' ')
assert_eq "table: one entry per shipped server dir" "$SERVER_DIR_COUNT" "$TABLE_ENTRIES"

for pair in $TABLE; do
    server="${pair%%:*}"
    count="${pair#*:}"

    assert_eq "table: $server's count is a positive integer" "true" \
        "$(printf '%s' "$count" | grep -qE '^[1-9][0-9]*$' && echo true || echo false)"

    # Anchor uniqueness first: if the README carried two `N tools total.` lines
    # the reader's answer would be arbitrary.
    assert_eq "table: $server/README.md has exactly ONE '<N> tools total.' line" "1" \
        "$(readme_count_line_count "$server")"
    assert_eq "table: $server count matches its README's '<N> tools total.' sentence" \
        "$count" "$(readme_tool_count "$server")"

    key=$(mcp_key_for "$server")
    assert_eq "table: $server count matches docs/MCP_SERVERS.md's Tools column for '$key'" \
        "$count" "$(doc_tool_count "$key")"
done

# ===========================================================================
echo ""
echo "=== Section 3: table <-> .claude/mcp/*/ <-> .mcp.json keys are 1:1 ==="

MCP_KEYS=$(jq -r '(.mcpServers // {}) | keys[]' "$MCP_JSON" 2>/dev/null | LC_ALL=C sort \
    | tr '\n' ' ' | sed 's/ *$//')
PLUGIN_KEYS=$(jq -r '(.mcpServers // {}) | keys[]' "$PLUGIN_JSON" 2>/dev/null | LC_ALL=C sort \
    | tr '\n' ' ' | sed 's/ *$//')

TABLE_KEYS=""
for pair in $TABLE; do
    TABLE_KEYS="$TABLE_KEYS $(mcp_key_for "${pair%%:*}")"
done
TABLE_KEYS=$(printf '%s' "$TABLE_KEYS" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort \
    | tr '\n' ' ' | sed 's/ *$//')

DIR_KEYS=""
for server in $SERVER_DIRS; do
    DIR_KEYS="$DIR_KEYS $(mcp_key_for "$server")"
done
DIR_KEYS=$(printf '%s' "$DIR_KEYS" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort \
    | tr '\n' ' ' | sed 's/ *$//')

assert_eq "mapping: table server names map onto the shipped dirs exactly" \
    "$DIR_KEYS" "$TABLE_KEYS"
assert_eq "mapping: shipped dirs map onto .mcp.json mcpServers keys exactly" \
    "$DIR_KEYS" "$MCP_KEYS"
assert_eq "mapping: .mcp.json and plugin.json declare the SAME server keys" \
    "$MCP_KEYS" "$PLUGIN_KEYS"

# Every declared launcher must exist on disk, and must live under the dir the
# key maps back to — that is what makes the key<->dir mapping meaningful rather
# than a naming coincidence.
for server in $SERVER_DIRS; do
    key=$(mcp_key_for "$server")
    ARG=$(jq -r --arg k "$key" '(.mcpServers[$k].args // [])[0] // ""' "$MCP_JSON" 2>/dev/null || echo "")
    REL=$(printf '%s' "$ARG" | sed -n 's|.*\(\.claude/mcp/.*\)$|\1|p')
    assert_eq "mapping: .mcp.json's '$key' launcher resolves under .claude/mcp/$server/" "true" \
        "$(starts_with "$REL" ".claude/mcp/$server/")"
    assert_eq "mapping: .mcp.json's '$key' launcher file exists on disk" "true" \
        "$([ -n "$REL" ] && [ -f "$PROJECT_DIR/$REL" ] && echo true || echo false)"
done

# ===========================================================================
echo ""
echo "=== Section 4: META-TESTs ==="

echo ""
echo "--- META-TEST 1: bumping a table count breaks the README cross-check ---"
# Control first: the real table and the real README agree. Without this the
# mutant's disagreement could be pre-existing rather than caused.
CTRL_TABLE_BD=$(table_count "$DOCTOR" "bd-mcp")
CTRL_README_BD=$(readme_tool_count "bd-mcp")
assert_eq "META-TEST 1 control: the real table and the real README already AGREE on bd-mcp" \
    "$CTRL_README_BD" "$CTRL_TABLE_BD"

MUT="$WORK/doctor-tools-bumped.sh"
# Anchored on the unique table text, not a line number. The bump is derived
# from the observed count so the mutation survives a legitimate future change
# to the real number.
if [ "$CTRL_TABLE_BD" = "READER-ERROR" ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST 1: could not read the real bd-mcp table count; the mutation cannot be built")
    printf '  FAIL: META-TEST 1: could not read the real bd-mcp count — mutation not built\n'
else
    BUMPED=$((CTRL_TABLE_BD + 1))
    sed "s/^DOCTOR_TOOL_COUNTS=\"bd-mcp:${CTRL_TABLE_BD} /DOCTOR_TOOL_COUNTS=\"bd-mcp:${BUMPED} /" \
        "$DOCTOR" > "$MUT"
    assert_eq "META-TEST 1: the mutant really differs from the original" "1" \
        "$(cmp -s "$MUT" "$DOCTOR" && echo 0 || echo 1)"
    assert_eq "META-TEST 1: the mutant is still valid bash" "0" \
        "$(bash -n "$MUT" 2>/dev/null && echo 0 || echo 1)"
    MUT_TABLE_BD=$(table_count "$MUT" "bd-mcp")
    assert_eq "META-TEST 1: the mutant's table really reads $BUMPED" "$BUMPED" "$MUT_TABLE_BD"
    # THE assertion: the same cross-check that passed on the control must now
    # disagree. Anything else means the cross-check does not read the table.
    assert_eq "META-TEST 1: the table-vs-README cross-check FAILS on the mutant" "differ" \
        "$([ "$MUT_TABLE_BD" = "$CTRL_README_BD" ] && echo same || echo differ)"
    # ...and the doc cross-check too, so a partial fix cannot hide it.
    assert_eq "META-TEST 1: the table-vs-docs/MCP_SERVERS.md cross-check FAILS on the mutant" "differ" \
        "$([ "$MUT_TABLE_BD" = "$(doc_tool_count bd)" ] && echo same || echo differ)"
fi
# The repo copy was never touched: re-read the real table and confirm.
assert_eq "META-TEST 1: the real workflow-doctor.sh table is unchanged after the mutation" \
    "$CTRL_TABLE_BD" "$(table_count "$DOCTOR" "bd-mcp")"

echo ""
echo "--- META-TEST 2: the lockfile readers are not vacuous ---"
# The trap this closes: a reader that errors and answers "0" makes every
# "zero packages have property X" assertion green for a lockfile it could not
# parse. Three synthetic lockfiles, three distinguishable answers.
GOOD_LOCK="$WORK/good-lock.json"
cat > "$GOOD_LOCK" <<'JSON'
{"lockfileVersion":3,"packages":{"":{"name":"x"},"node_modules/a":{"version":"1.0.0"}}}
JSON
assert_eq "META-TEST 2 control: a clean synthetic lockfile reports 0 install scripts" \
    "0" "$(lock_install_script_count "$GOOD_LOCK")"
assert_eq "META-TEST 2 control: a clean synthetic lockfile reports 0 dev packages" \
    "0" "$(lock_dev_package_count "$GOOD_LOCK")"
assert_eq "META-TEST 2 control: a clean synthetic lockfile reports 2 packages" \
    "2" "$(lock_package_count "$GOOD_LOCK")"

SCRIPT_LOCK="$WORK/install-script-lock.json"
cat > "$SCRIPT_LOCK" <<'JSON'
{"lockfileVersion":3,"packages":{"":{"name":"x"},"node_modules/native-thing":{"version":"1.0.0","hasInstallScript":true}}}
JSON
assert_eq "META-TEST 2: a lockfile with hasInstallScript:true reports 1, NOT 0" \
    "1" "$(lock_install_script_count "$SCRIPT_LOCK")"

DEV_LOCK="$WORK/dev-lock.json"
cat > "$DEV_LOCK" <<'JSON'
{"lockfileVersion":3,"packages":{"":{"name":"x"},"node_modules/only-for-tests":{"version":"1.0.0","dev":true}}}
JSON
assert_eq "META-TEST 2: a lockfile with dev:true reports 1, NOT 0" \
    "1" "$(lock_dev_package_count "$DEV_LOCK")"

BAD_LOCK="$WORK/malformed-lock.json"
printf 'this is not json at all\n' > "$BAD_LOCK"
assert_eq "META-TEST 2: a MALFORMED lockfile reports READER-ERROR, not a comfortable 0" \
    "READER-ERROR" "$(lock_install_script_count "$BAD_LOCK")"
assert_eq "META-TEST 2: ...for the dev-package reader too" \
    "READER-ERROR" "$(lock_dev_package_count "$BAD_LOCK")"
assert_eq "META-TEST 2: ...and for the lockfileVersion reader" \
    "READER-ERROR" "$(lock_version "$BAD_LOCK")"

NO_PACKAGES_LOCK="$WORK/no-packages-lock.json"
printf '{"lockfileVersion":3}\n' > "$NO_PACKAGES_LOCK"
assert_eq "META-TEST 2: a lockfile with NO packages map reports READER-ERROR, not 0" \
    "READER-ERROR" "$(lock_install_script_count "$NO_PACKAGES_LOCK")"

# The README reader must also refuse to guess when its anchor is missing or
# duplicated — the same vacuity class one layer up.
NO_ANCHOR_README="$WORK/no-anchor"
mkdir -p "$NO_ANCHOR_README"
printf 'A README with no count sentence.\n' > "$NO_ANCHOR_README/README.md"
OLD_MCP_ROOT="$MCP_ROOT"
MCP_ROOT="$WORK"
assert_eq "META-TEST 2: the README reader returns READER-ERROR when the anchor is absent" \
    "READER-ERROR" "$(readme_tool_count "no-anchor")"
printf '5 tools total.\n7 tools total.\n' > "$NO_ANCHOR_README/README.md"
assert_eq "META-TEST 2: the README reader returns READER-ERROR on a DUPLICATED anchor" \
    "READER-ERROR" "$(readme_tool_count "no-anchor")"
MCP_ROOT="$OLD_MCP_ROOT"
# Restore-check: the reader still answers correctly for the real server after
# the fixture swap, so a later assertion cannot inherit the poisoned root.
assert_eq "META-TEST 2: after restoring MCP_ROOT the real bd-mcp README still reads cleanly" \
    "$CTRL_README_BD" "$(readme_tool_count "bd-mcp")"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

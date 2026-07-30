#!/bin/bash
# mcp-deps-preserve.test.sh — L1 spec for install.sh's MCP dependency
# PRESERVATION contract (v4.1 / claude-workflow-plugin-z9m, QA round 2 R2-F1).
#
# THE DEFECT THIS EXISTS TO STOP RESHIPPING
# -----------------------------------------
# `npm ci` REMOVES an existing node_modules before it installs. That is
# documented, intended npm behaviour — it is what makes `ci` reproducible — and
# it means a FAILED `npm ci` does not leave a stale tree, it leaves a DESTROYED
# one. Measured on a populated bd-mcp against an unreachable registry:
#
#     before:  3,909 entries,  98 package.json
#     after:      94 entries,   0 package.json   (94 EMPTY directories), rc 1
#
# C0b introduced `npm ci` into the installer, so before this contract existed
# every re-install was one registry outage, proxy block or VPN drop away from
# turning a working target into two dead MCP servers. C0b also ENLARGED the
# exposed population from ~0 (targets previously had no node_modules at all) to
# 100% of installs.
#
# WHY IT SHIPPED, AND WHY THAT MATTERS MORE THAN THE BUG
# -----------------------------------------------------
# The first cut of C0b removed a `rm -rf <target>/node_modules` from the
# no-rsync copy fallback and verified the removal under `--skip-mcp-deps` — the
# one flag that disables `npm ci` entirely. That proved the OLD trigger (which
# needed an rsync-less host) was closed while the NEW one, on the DEFAULT path
# on every host, was never exercised even once. A fix must be verified in the
# configuration where the harm can occur.
#
# WHAT IS ASSERTED, AND AGAINST WHAT
# ----------------------------------
# The four functions under test are EXTRACTED FROM install.sh and executed, not
# reimplemented here: a copied implementation would pin this file's idea of the
# contract rather than the shipped one. Extraction is anchored on each
# function's own `name() {` line and its column-0 `}`; if one is renamed the
# extraction comes back empty and section 0 fails loudly instead of the suite
# quietly testing nothing.
#
# npm is faked for most sections — a script that does exactly what npm ci does
# (delete node_modules, then fail) — because that is deterministic, offline and
# instant. Section 6 then repeats the core assertion against the REAL npm with
# an unreachable registry and an empty cache, so the suite also proves the tool
# genuinely behaves that way rather than only that the guard works against a
# model of it. Section 6 skips itself when npm is absent.
#
# SECTIONS
#   0. Extraction: all four functions and both sentinel blocks are readable.
#   1. Preserve on failure: a populated tree survives a failing npm ci intact.
#   2. Skip when current: a matching stamp means npm is NEVER invoked.
#   3. Stamp discipline: a changed lockfile re-runs npm; a FAILED run leaves no
#      stamp (otherwise the next run would skip a broken tree).
#   4. Interrupted-run reclaim: a reserve with no node_modules is moved back.
#   5. Success path: npm succeeds -> tree in place, reserve gone, stamp matches.
#   6. REAL npm, unreachable registry (the QA-specified reproduction).
#   7. META-TEST: neuter the set-aside in a COPY and the tree IS destroyed.
#
# Exit codes: 0 all assertions pass, 1 otherwise.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
INSTALL_SH="$PROJECT_DIR/install.sh"

WORK=$(mktemp -d -t mcp-deps-preserve.XXXXXX)
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

# --- extraction -------------------------------------------------------------

# extract_func <file> <name> — the function's source, from its `name() {` line
# to the next column-0 `}`.
extract_func() {
    awk -v pat="^$2\\\\(\\\\) \\\\{$" '
        $0 ~ pat { inb = 1 }
        inb      { print }
        inb && $0 == "}" { exit }
    ' "$1"
}

# extract_block <file> <name> — the lines strictly between the sentinels. Same
# reader packaging-parity.test.sh uses.
extract_block() {
    awk -v b="# BEGIN $2" -v e="# END $2" '
        !inb && index($0, b) { inb = 1; next }
        inb && index($0, e)  { exit }
        inb                  { print }
    ' "$1"
}

# ---------------------------------------------------------------------------
echo "=== Section 0: extraction from install.sh ==="

assert_eq "install.sh exists" "yes" \
    "$([ -f "$INSTALL_SH" ] && echo yes || echo no)"
if [ ! -f "$INSTALL_SH" ]; then
    printf '\nFAILED: %d (installer missing)\n' "$FAIL"
    exit 1
fi

HARNESS="$WORK/deps-lib.sh"
{
    # The colours the extracted functions echo with. Empty is fine and keeps
    # the assertions free of escape sequences.
    printf 'RED=""\nGREEN=""\nYELLOW=""\nCYAN=""\nNC=""\n'
    extract_block "$INSTALL_SH" "MCP_DEPS_CMD"
    extract_block "$INSTALL_SH" "MCP_DEPS_STAMP"
    printf 'MCP_DEPS_RESULT=""\n'
    for _fn in mcp_sha256_of mcp_deps_reclaim mcp_deps_current mcp_deps_install; do
        extract_func "$INSTALL_SH" "$_fn"
    done
} > "$HARNESS"

for _fn in mcp_sha256_of mcp_deps_reclaim mcp_deps_current mcp_deps_install; do
    assert_eq "extracted $_fn() from install.sh" "yes" \
        "$(grep -q "^$_fn() {" "$HARNESS" && echo yes || echo no)"
done
assert_eq "extracted the npm argument vector" "yes" \
    "$(grep -q '^MCP_DEPS_NPM_ARGS=' "$HARNESS" && echo yes || echo no)"
assert_eq "extracted the stamp/reserve names" "yes" \
    "$(grep -q '^MCP_DEPS_STAMP_NAME=' "$HARNESS" && grep -q '^MCP_DEPS_RESERVE_NAME=' "$HARNESS" \
       && echo yes || echo no)"
assert_eq "the extracted harness is valid bash" "0" \
    "$(bash -n "$HARNESS" 2>/dev/null && echo 0 || echo 1)"
# Vacuity guard: an extraction that produced a handful of lines would parse
# fine and assert nothing. The four functions are ~95 lines together.
assert_eq "the harness is substantial (>60 lines)" "yes" \
    "$([ "$(grep -c . "$HARNESS" | tr -d ' \n')" -gt 60 ] && echo yes || echo no)"

if ! bash -n "$HARNESS" 2>/dev/null; then
    printf '\nFAILED: %d (harness does not parse; nothing downstream can run)\n' "$FAIL"
    exit 1
fi

# --- fixtures ---------------------------------------------------------------

# A fake npm that does EXACTLY what npm ci does: remove node_modules, then
# report failure. Deterministic, offline, instant. Records that it ran.
mk_npm_destructive_fail() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/npm" <<'FAKE'
#!/bin/bash
printf 'ran\n' >> "${FAKE_NPM_LOG:-/dev/null}"
rm -rf ./node_modules
exit 1
FAKE
    chmod +x "$bin/npm"
}

# A fake npm that succeeds and leaves a plausible tree behind.
mk_npm_success() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/npm" <<'FAKE'
#!/bin/bash
printf 'ran\n' >> "${FAKE_NPM_LOG:-/dev/null}"
rm -rf ./node_modules
mkdir -p ./node_modules/somepkg
printf '{"name":"somepkg"}\n' > ./node_modules/somepkg/package.json
exit 0
FAKE
    chmod +x "$bin/npm"
}

# mk_server <dir> <marker-count> — a server directory with a lockfile and a
# populated node_modules carrying <marker-count> recognisable files.
mk_server() {
    local d="$1" n="$2" i=0
    mkdir -p "$d/node_modules/pkg-a" "$d/node_modules/pkg-b"
    printf '{"name":"srv","version":"1.0.0"}\n' > "$d/package.json"
    printf '{"lockfileVersion":3,"packages":{}}\n' > "$d/package-lock.json"
    while [ "$i" -lt "$n" ]; do
        printf 'marker %s\n' "$i" > "$d/node_modules/pkg-a/file-$i.js"
        i=$((i + 1))
    done
}

markers_in() {
    find "$1/node_modules" -name 'file-*.js' -type f 2>/dev/null | grep -c . | tr -d ' \n'
}

# run_install <server-dir> <fake-bin> — drive the SHIPPED mcp_deps_install with
# the fake npm first on PATH. Echoes the verdict.
run_install() {
    local d="$1" bin="$2"
    (
        # shellcheck disable=SC1090
        . "$HARNESS"
        # shellcheck disable=SC2030  # the PATH change is MEANT to be subshell-local
        PATH="$bin:$PATH"
        export PATH
        mcp_deps_install "$d" >/dev/null 2>&1
        printf '%s' "$MCP_DEPS_RESULT"
    )
}

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: a populated tree survives a FAILING npm ci ==="

S1="$WORK/s1"; mk_server "$S1" 200
BIN_FAIL="$WORK/bin-fail"; mk_npm_destructive_fail "$BIN_FAIL"

assert_eq "fixture: 200 marker files are in place before the run" "200" "$(markers_in "$S1")"
S1_RESULT=$(run_install "$S1" "$BIN_FAIL")
assert_eq "a failing npm ci reports 'failed'" "failed" "$S1_RESULT"
# THE ASSERTION THIS FILE EXISTS FOR.
assert_eq "...and every one of the 200 marker files survived" "200" "$(markers_in "$S1")"
assert_eq "...and node_modules is a real tree, not an empty shell" "yes" \
    "$([ -f "$S1/node_modules/pkg-a/file-0.js" ] && echo yes || echo no)"
assert_eq "...and no reserve directory is left behind" "0" \
    "$(find "$S1" -maxdepth 1 -name '.node_modules.cwp-reserve' 2>/dev/null | grep -c . | tr -d ' \n')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: skip-when-current never invokes npm ==="

S2="$WORK/s2"; mk_server "$S2" 50
# Stamp it the way a successful run would.
(
    # shellcheck disable=SC1090
    . "$HARNESS"
    mcp_sha256_of "$S2/package-lock.json" > "$S2/node_modules/.cwp-lockfile-sha256"
)
assert_eq "fixture: the stamp was written and is 64 hex" "yes" \
    "$([ "$(tr -d '\n' < "$S2/node_modules/.cwp-lockfile-sha256" | wc -c | tr -d ' ')" = "64" ] \
       && echo yes || echo no)"

FAKE_NPM_LOG="$WORK/s2-npm.log"; export FAKE_NPM_LOG
: > "$FAKE_NPM_LOG"
S2_RESULT=$(FAKE_NPM_LOG="$FAKE_NPM_LOG" run_install "$S2" "$BIN_FAIL")
assert_eq "a matching stamp reports 'current'" "current" "$S2_RESULT"
# The point of layer 1: on the common re-install npm is not merely survived,
# it is never given the chance to run.
assert_eq "...and npm was NEVER invoked" "0" \
    "$(grep -c . "$FAKE_NPM_LOG" 2>/dev/null | tr -d ' \n')"
assert_eq "...and the tree is untouched" "50" "$(markers_in "$S2")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: stamp discipline ==="

# A stamp that does NOT match the lockfile must not be trusted — this is the
# upgrade case, where the shipped lockfile has moved on.
S3="$WORK/s3"; mk_server "$S3" 30
printf 'not-the-right-hash\n' > "$S3/node_modules/.cwp-lockfile-sha256"
: > "$WORK/s3-npm.log"
S3_RESULT=$(FAKE_NPM_LOG="$WORK/s3-npm.log" run_install "$S3" "$BIN_FAIL")
assert_eq "a stale stamp does NOT skip: npm is invoked" "1" \
    "$(grep -c . "$WORK/s3-npm.log" 2>/dev/null | tr -d ' \n')"
assert_eq "...the run reports 'failed'" "failed" "$S3_RESULT"
assert_eq "...and the tree is STILL preserved" "30" "$(markers_in "$S3")"
# A stamp written on a failed run would make the NEXT run skip a broken tree —
# the silent-green shape one level down.
assert_eq "...and no stamp was written for the failed attempt" "no" \
    "$([ -f "$S3/node_modules/.cwp-lockfile-sha256" ] \
       && [ "$(tr -d '[:space:]' < "$S3/node_modules/.cwp-lockfile-sha256")" != "not-the-right-hash" ] \
       && echo yes || echo no)"

# An unstamped tree (an operator's own npm install, or a pre-C0b target) is
# never mistaken for current.
S3B="$WORK/s3b"; mk_server "$S3B" 20
: > "$WORK/s3b-npm.log"
S3B_RESULT=$(FAKE_NPM_LOG="$WORK/s3b-npm.log" run_install "$S3B" "$BIN_FAIL")
assert_eq "an UNSTAMPED tree does not claim to be current" "failed" "$S3B_RESULT"
assert_eq "...npm was invoked for it" "1" \
    "$(grep -c . "$WORK/s3b-npm.log" 2>/dev/null | tr -d ' \n')"
assert_eq "...and it was preserved anyway" "20" "$(markers_in "$S3B")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: an interrupted run is healed on the next one ==="

S4="$WORK/s4"; mk_server "$S4" 40
# Exactly the state a run killed between the rename and npm's completion leaves.
mv "$S4/node_modules" "$S4/.node_modules.cwp-reserve"
assert_eq "fixture: node_modules is absent and the reserve holds the tree" "yes" \
    "$([ ! -d "$S4/node_modules" ] && [ -d "$S4/.node_modules.cwp-reserve" ] && echo yes || echo no)"
S4_RESULT=$(run_install "$S4" "$BIN_FAIL")
assert_eq "the reclaim restored the interrupted tree" "40" "$(markers_in "$S4")"
assert_eq "...even though npm then failed again" "failed" "$S4_RESULT"
assert_eq "...and the reserve is gone" "0" \
    "$(find "$S4" -maxdepth 1 -name '.node_modules.cwp-reserve' 2>/dev/null | grep -c . | tr -d ' \n')"

# The other reclaim arm: a stale reserve alongside a good tree is discarded,
# not restored over it.
S4B="$WORK/s4b"; mk_server "$S4B" 10
mkdir -p "$S4B/.node_modules.cwp-reserve/stale"
printf 'stale\n' > "$S4B/.node_modules.cwp-reserve/stale/file.js"
run_install "$S4B" "$BIN_FAIL" >/dev/null
assert_eq "a stale reserve beside a live tree is discarded" "0" \
    "$(find "$S4B" -maxdepth 1 -name '.node_modules.cwp-reserve' 2>/dev/null | grep -c . | tr -d ' \n')"
assert_eq "...and the live tree was not clobbered by it" "10" "$(markers_in "$S4B")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: the success path stamps and cleans up ==="

S5="$WORK/s5"; mk_server "$S5" 15
BIN_OK="$WORK/bin-ok"; mk_npm_success "$BIN_OK"
S5_RESULT=$(run_install "$S5" "$BIN_OK")
assert_eq "a successful npm ci reports 'ok'" "ok" "$S5_RESULT"
assert_eq "...the reserve was removed" "0" \
    "$(find "$S5" -maxdepth 1 -name '.node_modules.cwp-reserve' 2>/dev/null | grep -c . | tr -d ' \n')"
assert_eq "...a stamp was written" "yes" \
    "$([ -f "$S5/node_modules/.cwp-lockfile-sha256" ] && echo yes || echo no)"
# shellcheck disable=SC1090  # $HARNESS is generated above, by this file
S5_WANT=$( . "$HARNESS"; mcp_sha256_of "$S5/package-lock.json" )
assert_eq "...and it matches the lockfile that produced the tree" "$S5_WANT" \
    "$(tr -d '[:space:]' < "$S5/node_modules/.cwp-lockfile-sha256" 2>/dev/null)"
# Which means the very next run is a no-op.
: > "$WORK/s5-npm.log"
S5_AGAIN=$(FAKE_NPM_LOG="$WORK/s5-npm.log" run_install "$S5" "$BIN_OK")
assert_eq "...so an immediate re-run reports 'current'" "current" "$S5_AGAIN"
assert_eq "...and does not invoke npm" "0" \
    "$(grep -c . "$WORK/s5-npm.log" 2>/dev/null | tr -d ' \n')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: REAL npm against an unreachable registry ==="
#
# Sections 1-5 prove the guard holds against a MODEL of npm. This one proves the
# model is right: real `npm ci`, real lockfile, registry pointed at a closed
# port and a cache directory that is empty, so the failure is deterministic and
# needs no network. This is the exact reproduction QA specified.

if ! command -v npm >/dev/null 2>&1; then
    echo "  SKIPPED: npm is not on PATH"
else
    S6="$WORK/s6"
    mkdir -p "$S6/node_modules/pkg-a"
    # A lockfile that REQUIRES a fetch, so npm ci must reach the registry.
    cat > "$S6/package.json" <<'PKG'
{"name":"srv","version":"1.0.0","dependencies":{"leftpad-does-not-matter":"1.0.0"}}
PKG
    cat > "$S6/package-lock.json" <<'LOCK'
{
  "name": "srv",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "srv",
      "version": "1.0.0",
      "dependencies": { "leftpad-does-not-matter": "1.0.0" }
    },
    "node_modules/leftpad-does-not-matter": {
      "version": "1.0.0",
      "resolved": "https://registry.npmjs.org/leftpad-does-not-matter/-/leftpad-does-not-matter-1.0.0.tgz",
      "integrity": "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
    }
  }
}
LOCK
    i=0
    while [ "$i" -lt 120 ]; do
        printf 'marker %s\n' "$i" > "$S6/node_modules/pkg-a/file-$i.js"
        i=$((i + 1))
    done
    assert_eq "fixture: 120 marker files before the real npm run" "120" "$(markers_in "$S6")"

    S6_CACHE="$WORK/s6-cache"; mkdir -p "$S6_CACHE"
    S6_RESULT=$(
        # shellcheck disable=SC1090
        . "$HARNESS"
        npm_config_registry="http://127.0.0.1:9/" \
        npm_config_cache="$S6_CACHE" \
        npm_config_fetch_retries=0 \
        npm_config_audit=false \
        npm_config_fund=false \
        export npm_config_registry npm_config_cache npm_config_fetch_retries
        mcp_deps_install "$S6" >/dev/null 2>&1
        printf '%s' "$MCP_DEPS_RESULT"
    )
    assert_eq "real npm ci against a closed port reports 'failed'" "failed" "$S6_RESULT"
    # THE REGRESSION. Before the preserve-and-restore this read 0 (npm had
    # deleted the tree and left empty directories behind).
    assert_eq "...and all 120 marker files survived the REAL npm ci" "120" "$(markers_in "$S6")"
    assert_eq "...and no reserve was orphaned" "0" \
        "$(find "$S6" -maxdepth 1 -name '.node_modules.cwp-reserve' 2>/dev/null | grep -c . | tr -d ' \n')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: META-TEST (the preservation can actually fail) ==="
#
# Delete the set-aside from a COPY of install.sh — the single `mv` that moves
# node_modules to the reserve — and re-extract. Without it npm runs against the
# live tree and destroys it, which is precisely the shipped-in-round-1 defect.
# Anchored on the mv's own source text, never a line number: if it is reworded
# the sed matches nothing and the "copy differs" assertion below fails, so the
# META is repaired rather than silently rotting into a no-op.

# The mutation is `mv` -> `true`: the branch still SUCCEEDS (so the function
# proceeds exactly as it does today and does not divert into its
# could-not-set-aside refusal) but NOTHING IS MOVED, so npm runs against the
# live tree. That is precisely the round-1 shape, reproduced with one token.
MUTANT="$WORK/install-no-setaside.sh"
# shellcheck disable=SC2016  # sed script: the $VAR text is the installer's own source
sed 's|if mv "\$d/node_modules" "\$reserve" 2>/dev/null; then|if true; then|' \
    "$INSTALL_SH" > "$MUTANT"
assert_eq "META-TEST: the mutated copy really differs from install.sh" "1" \
    "$(cmp -s "$MUTANT" "$INSTALL_SH" && echo 0 || echo 1)"
assert_eq "META-TEST: the mutated copy is still valid bash" "0" \
    "$(bash -n "$MUTANT" 2>/dev/null && echo 0 || echo 1)"
# shellcheck disable=SC2016  # the searched-for text is the installer's own source line
assert_eq "META-TEST: the set-aside really is gone from the copy" "0" \
    "$(grep -c 'if mv "\$d/node_modules" "\$reserve"' "$MUTANT" | tr -d ' \n')"
# Surgical: everything else about the function survives, so the flip below is
# about the missing rename and not about a sed that ate the mechanism.
assert_eq "META-TEST: the mutation is surgical — the restore path survives" "yes" \
    "$(grep -q 'RESTORED unchanged' "$MUTANT" && echo yes || echo no)"

MUT_HARNESS="$WORK/deps-lib-mutant.sh"
{
    printf 'RED=""\nGREEN=""\nYELLOW=""\nCYAN=""\nNC=""\n'
    extract_block "$MUTANT" "MCP_DEPS_CMD"
    extract_block "$MUTANT" "MCP_DEPS_STAMP"
    printf 'MCP_DEPS_RESULT=""\n'
    for _fn in mcp_sha256_of mcp_deps_reclaim mcp_deps_current mcp_deps_install; do
        extract_func "$MUTANT" "$_fn"
    done
} > "$MUT_HARNESS"
assert_eq "META-TEST: the mutant harness parses" "0" \
    "$(bash -n "$MUT_HARNESS" 2>/dev/null && echo 0 || echo 1)"

S7="$WORK/s7"; mk_server "$S7" 75
assert_eq "META-TEST: fixture has 75 marker files" "75" "$(markers_in "$S7")"
(
    # shellcheck disable=SC1090
    . "$MUT_HARNESS"
    # shellcheck disable=SC2031  # deliberately subshell-local, like run_install's
    PATH="$BIN_FAIL:$PATH"
    export PATH
    mcp_deps_install "$S7" >/dev/null 2>&1
) || true
# THE FLIP: without the set-aside, the same failing npm destroys the tree.
assert_eq "META-TEST: -> WITHOUT the set-aside the tree is DESTROYED" "0" \
    "$(markers_in "$S7")"
# Control, on the same fixture shape with the real harness: preserved.
S7C="$WORK/s7c"; mk_server "$S7C" 75
run_install "$S7C" "$BIN_FAIL" >/dev/null
assert_eq "META-TEST control: the shipped code preserves the same fixture" "75" \
    "$(markers_in "$S7C")"

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

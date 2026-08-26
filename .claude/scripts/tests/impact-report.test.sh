#!/bin/bash
# impact-report.test.sh — L1 unit fixture for .claude/scripts/impact-report.sh
# (G2.n6d / claude-workflow-plugin-llh.2).
#
# The script under test generates the mechanical impact_of artifact the
# QA gate enforces: qa-gate.sh enter invokes it, qa-gate.sh approve
# refuses without a fresh one (the refusal itself is covered at L2 in
# .claude/tests/component/specs/qa-gate.sh, including the strip
# META-TEST). This L1 tier pins the GENERATOR's contract:
#
#   1. The artifact is ALWAYS created; only content degrades.
#      - server absent (bin missing)            -> server:"absent", impact:null
#      - server absent (node missing)           -> server:"absent", impact:null
#      - server unbootable (bin crashes on boot)-> server:"absent", impact:null
#      - server present (real code-graph)       -> server:"code-graph",
#        per-file structuredContent envelopes
#   2. change_set_hash correctness: sha256 over the canonical
#      changed-files list (LC_ALL=C sort -u + the post-edit denylist),
#      byte-identical to what `--hash-only` recomputes (the staleness
#      check in qa-gate.sh approve depends on this equivalence).
#   3. Out-of-project entries are SKIPPED LOCALLY and never sent to the
#      tool (PR #2 / preql-backend-9n5). impact-report.sh relativises
#      every path through git identity (relativize_for_impact) BEFORE
#      calling impact_of; anything that cannot belong to this index —
#      a foreign repo, non-git scratch, or a bare-relative path the
#      non-git fallback cannot anchor — is recorded as
#      {ok:false, error:{message:"skipped: path is outside the analyzed
#      project ..."}} while its neighbours still get real impact data and
#      the run exits 0. Corollary the report must uphold: it never
#      contains the server's "project-relative path, not absolute"
#      validation error, because no absolute path is ever handed over.
#   4. An UNREADABLE tracker REFUSES; an EMPTY one does not (i8cx U2).
#      --hash-only / --relativized-changed-files print NOTHING and exit 3,
#      and the generator writes NO artifact, when changed-files.txt exists
#      but its read fails — a failed read used to hash as the EMPTY set
#      (e3b0c442…) on both the generator and the checker side, so approve's
#      freshness comparison matched over a change set nobody read.
#      Sections 7/7M/8; the legitimately-empty states in sections 5/6 stay
#      rc 0 on the pinned constant.
#
# The server-present sections drive the REAL code-graph-mcp server from
# this repo over stdio (free, local; no model calls) against a tiny
# 2-file TypeScript fixture — same shape as the L2 component spec
# code-graph-mcp.sh uses. Skip-with-log when node or the server's
# node_modules are unavailable (mirrors that spec's convention).
#
# Exit codes: 0 all assertions pass, 1 otherwise, 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
IR="$PROJECT_DIR/.claude/scripts/impact-report.sh"
MCP_DIR="$PROJECT_DIR/.claude/mcp/code-graph-mcp"
MCP_BIN="$MCP_DIR/bin/code-graph-mcp.js"

if [ ! -f "$IR" ]; then
    printf 'impact-report.test: script under test missing: %s\n' "$IR" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    printf 'impact-report.test: jq is required\n' >&2
    exit 2
fi

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

assert_match() {
    local name="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -qE "$pattern"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    pattern: %s\n    actual:  %s\n' \
            "$name" "$pattern" "$actual"
    fi
}

# sha256 helper mirroring the script's tool-fallback chain so the
# expected-hash computation is portable.
test_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        cat >/dev/null
        printf 'sha256-unavailable'
    fi
}

FIXTURES=()
# cleanup runs only via the EXIT trap below; the static analyzer can't see
# that indirection. Newer shellchecks emit SC2329 on the definition, older
# ones (CI) emit SC2317 on every statement in the body. Suppress both.
# shellcheck disable=SC2329,SC2317
cleanup() {
    local d
    for d in ${FIXTURES[@]+"${FIXTURES[@]}"}; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
}
trap cleanup EXIT

mk_proj() {
    local d
    d=$(mktemp -d -t impact-report-test.XXXXXX)
    FIXTURES+=("$d")
    mkdir -p "$d/.claude/.qa-tracking"
    printf '%s' "$d"
}

# ---------------------------------------------------------------------------
echo "=== Section 1: server absent (bin missing) — artifact still created ==="

F1=$(mk_proj)
# Seed: duplicate entry, denylisted entry, empty line — canonicalisation
# must dedup, filter, and sort (LC_ALL=C; aa < zz in every locale).
printf 'src/zz-dup.ts\nnode_modules/skip.js\n\nsrc/aa-first.ts\nsrc/zz-dup.ts\n' \
    > "$F1/.claude/.qa-tracking/changed-files.txt"

RC1=0
CLAUDE_PROJECT_DIR="$F1" bash "$IR" "task-A.1" >/dev/null 2>&1 || RC1=$?
assert_eq "absent-bin: exit 0" "0" "$RC1"
R1="$F1/.claude/.qa-tracking/impact-report-task-A.1.json"
assert_eq "absent-bin: artifact exists" "0" "$([ -f "$R1" ] && echo 0 || echo 1)"
J1=$(cat "$R1" 2>/dev/null || echo "{}")
assert_eq "absent-bin: server=absent" "absent" "$(printf '%s' "$J1" | jq -r '.server')"
assert_eq "absent-bin: task_id recorded" "task-A.1" "$(printf '%s' "$J1" | jq -r '.task_id')"
assert_match "absent-bin: generated_at is ISO-8601 UTC" \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    "$(printf '%s' "$J1" | jq -r '.generated_at')"
assert_eq "absent-bin: canonical list deduped + denylist-filtered (2 files)" \
    "2" "$(printf '%s' "$J1" | jq -r '.files | length')"
assert_eq "absent-bin: files sorted (aa-first first)" \
    "src/aa-first.ts" "$(printf '%s' "$J1" | jq -r '.files[0].file')"
assert_eq "absent-bin: every impact is null" \
    "2" "$(printf '%s' "$J1" | jq -r '[.files[] | select(.impact == null)] | length')"

# change_set_hash correctness: independent recomputation + --hash-only.
EXPECTED_HASH=$(printf 'src/aa-first.ts\nsrc/zz-dup.ts\n' | test_sha256)
assert_eq "absent-bin: change_set_hash == independent sha256 of canonical list" \
    "$EXPECTED_HASH" "$(printf '%s' "$J1" | jq -r '.change_set_hash')"
HASH_ONLY=$(CLAUDE_PROJECT_DIR="$F1" bash "$IR" --hash-only 2>/dev/null)
assert_eq "absent-bin: --hash-only matches the recorded hash" \
    "$EXPECTED_HASH" "$HASH_ONLY"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: server absent (node hidden) — artifact still created ==="

F2=$(mk_proj)
printf 'src/one.ts\n' > "$F2/.claude/.qa-tracking/changed-files.txt"
# Make the bin EXIST so the node-availability branch (not the bin branch)
# is what fires.
mkdir -p "$F2/stub-mcp"
: > "$F2/stub-mcp/server.js"
RC2=0
CLAUDE_PROJECT_DIR="$F2" CODE_GRAPH_MCP_BIN="$F2/stub-mcp/server.js" \
    IMPACT_REPORT_NODE="/nonexistent/impact-report-test-node" \
    bash "$IR" "task-B.2" >/dev/null 2>&1 || RC2=$?
assert_eq "absent-node: exit 0" "0" "$RC2"
J2=$(cat "$F2/.claude/.qa-tracking/impact-report-task-B.2.json" 2>/dev/null || echo "{}")
assert_eq "absent-node: server=absent" "absent" "$(printf '%s' "$J2" | jq -r '.server')"
assert_eq "absent-node: impact=null" "null" "$(printf '%s' "$J2" | jq -r '.files[0].impact')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: server unbootable (bin crashes) — degrades to absent ==="

if ! command -v node >/dev/null 2>&1; then
    printf 'SKIPPED: section 3 (node not on PATH)\n'
else
    F3=$(mk_proj)
    printf 'src/one.ts\n' > "$F3/.claude/.qa-tracking/changed-files.txt"
    mkdir -p "$F3/bogus-mcp"
    printf 'process.exit(1);\n' > "$F3/bogus-mcp/crash.js"
    RC3=0
    CLAUDE_PROJECT_DIR="$F3" CODE_GRAPH_MCP_BIN="$F3/bogus-mcp/crash.js" \
        IMPACT_REPORT_BOOT_TIMEOUT_S=3 \
        bash "$IR" "task-C.3" >/dev/null 2>&1 || RC3=$?
    assert_eq "unbootable: exit 0" "0" "$RC3"
    J3=$(cat "$F3/.claude/.qa-tracking/impact-report-task-C.3.json" 2>/dev/null || echo "{}")
    assert_eq "unbootable: server=absent" "absent" "$(printf '%s' "$J3" | jq -r '.server')"
    assert_eq "unbootable: impact=null" "null" "$(printf '%s' "$J3" | jq -r '.files[0].impact')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: server PRESENT (real code-graph) — impact data + out-of-project skips ==="

# PR #2 (relativize_for_impact) made relativisation GIT-IDENTITY driven: a
# path is sent to impact_of only when its directory is in the same git repo
# (same --git-common-dir) as $PROJECT_DIR; when $PROJECT_DIR is not a git
# checkout at all the code falls back to a literal "$PROJECT_DIR/" prefix
# strip. This fixture is a mktemp dir, so it exercises the NON-GIT FALLBACK
# branch (the git branch, incl. sibling worktrees, is owned by the L2 spec
# .claude/tests/component/specs/impact-report-paths.sh, which drives a stub
# server against a real worktree topology).
#
# That contract only holds while the fixture really is outside any git
# checkout. If the tempdir happens to live inside a repo, PROJECT_COMMON_DIR
# is non-empty and every expectation below flips (including the pre-existing
# a.ts ones) — so we measure the ACTUAL fixture and skip loudly rather than
# emit a baffling failure.
F4_GIT_HOST=""
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIPPED: section 4 (node not on PATH)\n'
elif [ ! -f "$MCP_BIN" ] || [ ! -d "$MCP_DIR/node_modules" ]; then
    # shellcheck disable=SC2016  # backticks are message text, not expansion.
    printf 'SKIPPED: section 4 (code-graph-mcp not installed under %s — run `cd %s && npm install`)\n' \
        "$MCP_DIR" "$MCP_DIR"
else
    F4=$(mk_proj)
    F4_GIT_HOST=$(git -C "$F4" rev-parse --git-common-dir 2>/dev/null || echo "")
fi

if [ -n "$F4_GIT_HOST" ]; then
    printf 'SKIPPED: section 4 (fixture tempdir is inside a git checkout: %s — this section pins the NON-GIT relativisation fallback and needs a fixture outside any repo)\n' \
        "$F4_GIT_HOST"
elif [ -n "${F4:-}" ]; then
    mkdir -p "$F4/.claude/mcp" "$F4/src"
    # Symlink the real server tree; node resolves imports via realpath so
    # src/ and node_modules/ load from the actual install.
    ln -s "$MCP_DIR" "$F4/.claude/mcp/code-graph-mcp"
    cat > "$F4/src/a.ts" <<'TS'
export function flagshipSymbol(): string {
    return "flagship";
}
TS
    cat > "$F4/src/b.ts" <<'TS'
import { flagshipSymbol } from "./a";
export function consumer(): string {
    return flagshipSymbol();
}
TS
    # Tracker mixes the three shapes the non-git fallback must separate:
    #   - an ABSOLUTE in-project path  -> anchored by the prefix strip, SENT
    #   - a BARE-RELATIVE path         -> unanchorable here, SKIPPED
    #   - an absolute OUT-OF-PROJECT path -> not in this index, SKIPPED
    # (Production tracker entries are absolute: post-edit.sh records
    # `tool_input.file_path` verbatim, which Claude Code supplies absolute.)
    printf '%s/src/a.ts\nsrc/b.ts\n/outside/impact-report-test-abs.ts\n' "$F4" \
        > "$F4/.claude/.qa-tracking/changed-files.txt"

    RC4=0
    CLAUDE_PROJECT_DIR="$F4" bash "$IR" "task-D.4" >/dev/null 2>&1 || RC4=$?
    assert_eq "live: exit 0 despite one per-file error" "0" "$RC4"
    R4="$F4/.claude/.qa-tracking/impact-report-task-D.4.json"
    assert_eq "live: artifact exists" "0" "$([ -f "$R4" ] && echo 0 || echo 1)"
    J4=$(cat "$R4" 2>/dev/null || echo "{}")
    assert_eq "live: server=code-graph" "code-graph" "$(printf '%s' "$J4" | jq -r '.server')"
    assert_eq "live: all 3 files present in report" "3" "$(printf '%s' "$J4" | jq -r '.files | length')"

    # Out-of-project absolute path: recorded as an explicit LOCAL skip and
    # never sent to the server; the run continues with its neighbours.
    OUT_OK=$(printf '%s' "$J4" | jq -r '.files[] | select(.file == "/outside/impact-report-test-abs.ts") | .impact.ok')
    assert_eq "live: out-of-project entry recorded ok=false" "false" "$OUT_OK"
    ERR_MSG=$(printf '%s' "$J4" | jq -r '.files[] | select(.file == "/outside/impact-report-test-abs.ts") | .impact.error.message // empty')
    assert_match "live: out-of-project entry carries the explicit skip record" \
        '^skipped: path is outside the analyzed project' "$ERR_MSG"

    # PR #2's core invariant, restated at L1: because relativisation happens
    # BEFORE the call, no absolute path is ever handed to impact_of, so the
    # server's absolute-path validation error can never appear in a report.
    # (Pre-PR#2 this count was 1 — the out-of-project entry produced it.)
    ABS_ERRS=$(printf '%s' "$J4" | jq -r '[.files[] | select((.impact.error.message // "") | test("project-relative path, not absolute"))] | length')
    assert_eq "live: zero absolute-path validation errors in the report" "0" "$ABS_ERRS"

    # The absolute in-project entry was converted to a relative seed and
    # produced REAL graph data: b.ts imports a.ts -> 1 file dependent,
    # and consumer() calls flagshipSymbol() -> at least 1 caller node
    # beyond the seeds.
    A_OK=$(printf '%s' "$J4" | jq -r --arg f "$F4/src/a.ts" '.files[] | select(.file == $f) | .impact.ok')
    assert_eq "live: in-project absolute entry resolved (impact.ok=true)" "true" "$A_OK"
    A_DEPS=$(printf '%s' "$J4" | jq -r --arg f "$F4/src/a.ts" '.files[] | select(.file == $f) | .impact.data.file_dependents | length')
    assert_eq "live: a.ts has 1 file-level dependent (b.ts imports it)" "1" "$A_DEPS"
    A_CALLERS=$(printf '%s' "$J4" | jq -r --arg f "$F4/src/a.ts" '.files[] | select(.file == $f) | [.impact.data.nodes[] | select(.relation == "caller")] | length')
    assert_match "live: a.ts has >=1 transitive caller (consumer)" '^[1-9][0-9]*$' "$A_CALLERS"

    # Bare-relative entry. The non-git fallback can only anchor the literal
    # "$PROJECT_DIR/" prefix, so a relative path has no resolvable identity
    # here and is skipped rather than guessed at — the same explicit record
    # the foreign path gets. (In a real git checkout the git branch anchors
    # it against the process cwd instead; that path is L2-covered.)
    B_OK=$(printf '%s' "$J4" | jq -r '.files[] | select(.file == "src/b.ts") | .impact.ok')
    assert_eq "live: bare-relative entry not resolvable under a non-git project root (ok=false)" \
        "false" "$B_OK"
    B_ERR=$(printf '%s' "$J4" | jq -r '.files[] | select(.file == "src/b.ts") | .impact.error.message // empty')
    assert_match "live: bare-relative entry carries the explicit skip record" \
        '^skipped: path is outside the analyzed project' "$B_ERR"

    # The entry is recorded, not dropped: the report still describes the
    # whole change set (already asserted as 3 above) and the file key is the
    # path AS TRACKED, unmodified by relativisation.
    B_KEY=$(printf '%s' "$J4" | jq -r '[.files[] | select(.file == "src/b.ts")] | length')
    assert_eq "live: skipped entry keeps its as-tracked path key" "1" "$B_KEY"

    # Hash agreement under the live fixture too.
    H4_REPORT=$(printf '%s' "$J4" | jq -r '.change_set_hash')
    H4_NOW=$(CLAUDE_PROJECT_DIR="$F4" bash "$IR" --hash-only 2>/dev/null)
    assert_eq "live: change_set_hash matches --hash-only" "$H4_NOW" "$H4_REPORT"

    # No orphaned server process: the script must reap its own child
    # (macOS FIFO/kqueue EOF quirk is handled via explicit SIGTERM).
    ORPHANS=$(pgrep -f "$F4/.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "live: no orphaned server process" "0" "$ORPHANS"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: empty change set — artifact with files=[] ==="

F5=$(mk_proj)
# No changed-files.txt at all.
RC5=0
CLAUDE_PROJECT_DIR="$F5" bash "$IR" "task-E.5" >/dev/null 2>&1 || RC5=$?
assert_eq "empty: exit 0" "0" "$RC5"
J5=$(cat "$F5/.claude/.qa-tracking/impact-report-task-E.5.json" 2>/dev/null || echo "{}")
assert_eq "empty: files=[]" "0" "$(printf '%s' "$J5" | jq -r '.files | length')"
EMPTY_HASH=$(printf '' | test_sha256)
assert_eq "empty: hash of empty canonical list" \
    "$EMPTY_HASH" "$(printf '%s' "$J5" | jq -r '.change_set_hash')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: the EMPTY-SET hash is a pinned constant (94d) ==="

# WHY A LITERAL AND NOT A RECOMPUTATION.
#
# Section 5 above compares the artifact's hash against a locally recomputed one,
# which proves the two agree — and would keep passing if BOTH moved together.
# The empty-set hash is not just any value: it is load-bearing text in three
# other places, all of which reason about the specific string.
#
#   - verify-before-stop.sh's VANISHED-CHANGE-SET note names
#     `e3b0c44298fc…` as the hash a Stop recomputed mid-approve, and its whole
#     argument is that this value "no honest approval of real work can carry".
#   - .claude/tests/component/specs/approve-idempotency.sh names it for the
#     same reason.
#   - The 94d change set exists because a tracker that under-covers hashes as
#     if the missing files were not there; an EMPTY tracker hashes to exactly
#     this, which is how a review cycle came to bind a hollow approval over 0
#     files (claude-workflow-plugin-fkm.1.2) while looking perfectly valid.
#
# So the constant is a contract, not an implementation detail. Pinning it means
# any change to the canonicalisation that silently moves it — a trailing
# newline, a header line, a `sort` that emits something for empty input — fails
# HERE, next to the reason, instead of turning three prose citations into
# quiet fiction.
#
# This is the sha256 of the EMPTY BYTE STRING, which is what an empty canonical
# list feeds to sha256_stdin:
#     printf '' | shasum -a 256
EMPTY_SET_HASH_CONST="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

if [ "$EMPTY_HASH" = "sha256-unavailable" ]; then
    printf 'SKIPPED: section 6 (neither shasum nor sha256sum on PATH; the degraded sentinel is not a sha256)\n'
else
    assert_eq "empty-const: the empty canonical list hashes to the pinned e3b0c442… constant" \
        "$EMPTY_SET_HASH_CONST" "$(printf '%s' "$J5" | jq -r '.change_set_hash')"
    assert_eq "empty-const: --hash-only on a project with NO tracker prints the same constant" \
        "$EMPTY_SET_HASH_CONST" "$(CLAUDE_PROJECT_DIR="$F5" bash "$IR" --hash-only 2>/dev/null)"

    # A tracker that exists but is EMPTY must hash identically to one that does
    # not exist. `approve` treats an empty report as fresh against an empty
    # tracker, so these two states have to be indistinguishable — if they ever
    # diverged, the freshness check would refuse a legitimately empty cycle.
    F6=$(mk_proj)
    : > "$F6/.claude/.qa-tracking/changed-files.txt"
    assert_eq "empty-const: an EXISTING but empty tracker hashes to the same constant" \
        "$EMPTY_SET_HASH_CONST" "$(CLAUDE_PROJECT_DIR="$F6" bash "$IR" --hash-only 2>/dev/null)"

    # And a tracker holding ONLY denylisted paths is empty after filtering, so
    # it lands on the same constant — the "empty post-denylist" class the Stop
    # hook's fast path treats as nothing-to-review.
    printf 'node_modules/a.js\npnpm-lock.yaml\n' > "$F6/.claude/.qa-tracking/changed-files.txt"
    assert_eq "empty-const: a tracker of ONLY denylisted paths hashes to the same constant" \
        "$EMPTY_SET_HASH_CONST" "$(CLAUDE_PROJECT_DIR="$F6" bash "$IR" --hash-only 2>/dev/null)"

    # Discriminator: one real path must NOT hash to it. Without this the three
    # assertions above would all pass against a --hash-only that always printed
    # the constant.
    printf 'src/real.ts\n' > "$F6/.claude/.qa-tracking/changed-files.txt"
    NONEMPTY6=$(CLAUDE_PROJECT_DIR="$F6" bash "$IR" --hash-only 2>/dev/null)
    assert_eq "empty-const: DISCRIMINATOR — one real path does not hash to the empty-set constant" \
        "differs" "$([ "$NONEMPTY6" != "$EMPTY_SET_HASH_CONST" ] && echo differs || echo same)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: unreadable tracker REFUSES; empty stays empty (i8cx U2) ==="

# THE CONTRACT UNDER TEST (claude-workflow-plugin-i8cx U2).
# canonical_changed_files used to consume `sort -u "$TRACKING_FILE"` through a
# process substitution, whose exit status is unobservable: a failed read ran
# the loop zero times and returned 0, and change_set_hash piped that through
# sha256_stdin with no status check — so a tracker that could not be READ
# hashed to the same empty-set digest e3b0c442… as a tracker that is
# legitimately EMPTY. Generator (the report's change_set_hash) and checker
# (approve's --hash-only recompute) share the function, so the freshness
# comparison MATCHED over a change set nobody ever read.
#
# The fix distinguishes the two states; this section pins BOTH sides:
#   - legitimately empty (tracker ABSENT, or present+readable+empty, or all
#     entries denylisted) -> rc 0, prints the pinned e3b0c442… constant;
#   - unreadable (tracker EXISTS but the sort that reads it fails)
#     -> prints NOTHING on stdout, exits 3, logs a FATAL to stderr.
#
# The failing read is injected with a PATH shim that fails ONLY when the
# tracker path itself is an ARGUMENT (impact-report.sh is the sole argv-sort
# consumer of the tracker on the enter/approve path; qa-gate.sh's own sorts
# are stdin-fed and fall through to the real sort untouched). The shim logs
# each hit, so every leg proves the mutation-of-state landed where it was
# aimed (pairing requirement part 1, .claude/tests/README.md).

REAL_SORT=$(command -v sort)
SHIM_DIR=$(mktemp -d -t impact-report-shim.XXXXXX)
FIXTURES+=("$SHIM_DIR")
SHIM_HITS="$SHIM_DIR/hits.log"
: > "$SHIM_HITS"
cat > "$SHIM_DIR/sort" <<SORTSHIM
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        */changed-files.txt)
            printf '%s\n' "\$*" >> "$SHIM_HITS"
            echo "sort-shim: simulated tracker read failure" >&2
            exit 1
            ;;
    esac
done
exec "$REAL_SORT" "\$@"
SORTSHIM
chmod +x "$SHIM_DIR/sort"

shim_hits() { wc -l < "$SHIM_HITS" | tr -d ' '; }

F7=$(mk_proj)
# Same canonical content as section 1: dup + denylisted + empty line.
printf 'src/zz-dup.ts\nnode_modules/skip.js\n\nsrc/aa-first.ts\nsrc/zz-dup.ts\n' \
    > "$F7/.claude/.qa-tracking/changed-files.txt"

# FROZEN VECTOR: sha256 of the canonical list "src/aa-first.ts\nsrc/zz-dup.ts\n"
# (printf 'src/aa-first.ts\nsrc/zz-dup.ts\n' | shasum -a 256). Measured against
# the PRE-i8cx script (git 6d0011f, file sha256 59424d26…) and required to be
# byte-identical post-fix: the U2 change must not re-key existing artifacts.
# If this literal ever moves, the canonicalisation itself moved.
FROZEN_VECTOR="cd2f8afea16a3ba85f57af6e57a09b4c0b6738ebb6d9fb4043d8ca77fbc5dfcd"

# 7.1 Unreadable: --hash-only prints NOTHING and exits 3 — and specifically
# NOT the empty-set digest, which is the silent answer the pre-fix script
# gave here (both sides of approve's freshness check would match on it).
: > "$SHIM_HITS"
RC71=0
OUT71=$(PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F7" bash "$IR" --hash-only 2>"$F7/err71.txt") || RC71=$?
assert_eq "7.1 unreadable --hash-only: exit 3" "3" "$RC71"
assert_eq "7.1 unreadable --hash-only: stdout is EMPTY" "" "$OUT71"
assert_eq "7.1 unreadable --hash-only: output is NOT the empty-set digest e3b0c442… (the pre-fix silent answer)" \
    "differs" "$([ "$OUT71" != "$EMPTY_SET_HASH_CONST" ] && echo differs || echo same)"
assert_match "7.1 unreadable --hash-only: stderr names the refusal" \
    "could not be read" "$(cat "$F7/err71.txt" 2>/dev/null)"
assert_match "7.1 shim landed (tracker-argv sort was invoked and failed)" \
    '^[1-9]' "$(shim_hits)"

# 7.2 Restore control: unshimmed, the SAME tracker yields the real hash —
# equal to an independent recomputation AND to the pre-fix frozen vector.
RC72=0
OUT72=$(CLAUDE_PROJECT_DIR="$F7" bash "$IR" --hash-only 2>/dev/null) || RC72=$?
assert_eq "7.2 restore: unshimmed --hash-only exits 0" "0" "$RC72"
assert_eq "7.2 restore: hash matches independent recomputation" \
    "$(printf 'src/aa-first.ts\nsrc/zz-dup.ts\n' | test_sha256)" "$OUT72"
if [ "$EMPTY_HASH" = "sha256-unavailable" ]; then
    printf 'SKIPPED: 7.2 frozen-vector literal (no sha256 tool on PATH)\n'
else
    assert_eq "7.2 restore: hash byte-identical to the PRE-FIX frozen vector (no re-keying)" \
        "$FROZEN_VECTOR" "$OUT72"
fi

# 7.3 ABSENT tracker is legitimately empty: even with the failing sort on
# PATH it exits 0 on the constant, because no read is attempted at all.
F7A=$(mk_proj)
: > "$SHIM_HITS"
RC73=0
OUT73=$(PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F7A" bash "$IR" --hash-only 2>/dev/null) || RC73=$?
assert_eq "7.3 ABSENT tracker (legit empty): exit 0 even with the failing sort on PATH" "0" "$RC73"
if [ "$EMPTY_HASH" != "sha256-unavailable" ]; then
    assert_eq "7.3 ABSENT tracker prints the pinned empty-set constant" \
        "$EMPTY_SET_HASH_CONST" "$OUT73"
fi
assert_eq "7.3 ABSENT tracker never invoked the tracker-argv sort (shim hits = 0)" \
    "0" "$(shim_hits)"

# 7.4 The distinction that is the whole point: an EMPTY-but-readable tracker
# is proven empty (rc 0, constant); an EMPTY-but-UNREADABLE one cannot be
# proven anything and refuses (rc 3, no bytes). Same file size, different
# answers, because only one of the two reads succeeded.
F7E=$(mk_proj)
: > "$F7E/.claude/.qa-tracking/changed-files.txt"
RC74=0
OUT74=$(CLAUDE_PROJECT_DIR="$F7E" bash "$IR" --hash-only 2>/dev/null) || RC74=$?
assert_eq "7.4 EMPTY readable tracker: exit 0 (proven-empty is a real answer)" "0" "$RC74"
if [ "$EMPTY_HASH" != "sha256-unavailable" ]; then
    assert_eq "7.4 EMPTY readable tracker: the empty-set constant" \
        "$EMPTY_SET_HASH_CONST" "$OUT74"
fi
: > "$SHIM_HITS"
RC74U=0
OUT74U=$(PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F7E" bash "$IR" --hash-only 2>/dev/null) || RC74U=$?
assert_eq "7.4 EMPTY tracker whose READ FAILS: exit 3 (cannot-prove-empty is not empty)" "3" "$RC74U"
assert_eq "7.4 EMPTY tracker whose READ FAILS: no stdout" "" "$OUT74U"

# 7.5 Generator mode: an unreadable set writes NO artifact (a refused report
# is no report — qa-gate.sh enter captures rc 3 and warns loudly).
: > "$SHIM_HITS"
RC75=0
PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F7" bash "$IR" "task-U2.gen" >/dev/null 2>&1 || RC75=$?
assert_eq "7.5 unreadable: generator exits 3" "3" "$RC75"
assert_eq "7.5 unreadable: NO artifact written" \
    "absent" "$([ -f "$F7/.claude/.qa-tracking/impact-report-task-U2.gen.json" ] && echo present || echo absent)"
RC75R=0
CLAUDE_PROJECT_DIR="$F7" bash "$IR" "task-U2.gen" >/dev/null 2>&1 || RC75R=$?
assert_eq "7.5 restore: unshimmed generator exits 0" "0" "$RC75R"
assert_eq "7.5 restore: artifact binds the REAL hash" \
    "$OUT72" "$(jq -r '.change_set_hash' "$F7/.claude/.qa-tracking/impact-report-task-U2.gen.json" 2>/dev/null)"

# 7.6 --relativized-changed-files: an unreadable set must refuse rather than
# emit an empty set at rc 0 (qa-gate.sh design-conform's actual_rc guard
# refuses on any non-zero exit; an empty set at rc 0 would read as "no
# changed files" and pass the undeclared-files check vacuously).
: > "$SHIM_HITS"
RC76=0
OUT76=$(PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F7" bash "$IR" --relativized-changed-files 2>/dev/null) || RC76=$?
assert_eq "7.6 unreadable: --relativized-changed-files exits 3" "3" "$RC76"
assert_eq "7.6 unreadable: emits NO set" "" "$OUT76"
RC76R=0
OUT76R=$(CLAUDE_PROJECT_DIR="$F7" bash "$IR" --relativized-changed-files 2>/dev/null) || RC76R=$?
assert_eq "7.6 restore: unshimmed exits 0" "0" "$RC76R"
assert_eq "7.6 restore: both canonical entries emitted" "src/aa-first.ts
src/zz-dup.ts" "$OUT76R"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7M: META — both halves of the U2 guard are load-bearing ==="

# Pairing requirement (.claude/tests/README.md): a new check ships with a
# mutation that provably lands, fails in the SPECIFIC way the guard
# prevents, has a restore control, and at least one leg drives the shipped
# artifact. TWO mutants, one per shipped half, because the fix is only
# sound as a PAIR (the i8cx audit: "ship :270 and :288 together or not at
# all"):
#   7M1 rewrites the UNREADABLE-TRACKER-GUARD sentinel region on a COPY
#       into the unguarded pre-i8cx read — canonical_changed_files then
#       returns 0 over a failed read and every downstream guard is blind.
#   7M2 keeps the rc guard but strips the subshell pipefail from
#       change_set_hash — canonical returns 1 but the pipe swallows it.
# Each mutant must (a) be PROVEN mutated, (b) still behave correctly
# unshimmed (ruling out broken-for-the-wrong-reason), and (c) with the
# failing sort print EXACTLY the empty-set digest at rc 0 — the silent
# answer that made approve's freshness comparison (impact_report_stale /
# impact_report_unverifiable in qa-gate.sh) match on both sides. Section
# 7.1's assertions would all go green-blind against either mutant.

MUT_DIR=$(mktemp -d -t impact-report-mutants.XXXXXX)
FIXTURES+=("$MUT_DIR")
# The script sources workflow-denylist.sh from ITS OWN directory (BASH_SOURCE),
# so the mutants need the real denylist as a sibling.
cp "$PROJECT_DIR/.claude/scripts/workflow-denylist.sh" "$MUT_DIR/"

# --- 7M1: rc guard removed (the pre-i8cx read) ---
MUT_A="$MUT_DIR/impact-report-mutant-a.sh"
awk '
    /# UNREADABLE-TRACKER-GUARD BEGIN/ {
        inb = 1; found = 1
        print "    LC_ALL=C sort -u \"$TRACKING_FILE\" > \"$_ccf_sorted\" 2>/dev/null"
        next
    }
    /# UNREADABLE-TRACKER-GUARD END/ { inb = 0; next }
    inb { next }
    { print }
    END { if (!found) exit 7 }
' "$IR" > "$MUT_A"
AWK_RC=$?
assert_eq "7M1 mutation landed (sentinel region found and rewritten; exit 7 = anchors gone)" "0" "$AWK_RC"
assert_eq "7M1 mutant differs from the shipped script" \
    "differs" "$(cmp -s "$MUT_A" "$IR" && echo same || echo differs)"
BASHN_A=0
bash -n "$MUT_A" 2>/dev/null || BASHN_A=$?
assert_eq "7M1 mutant still parses (runnable pre-fix code, not a broken file)" "0" "$BASHN_A"
OUTA_OK=$(CLAUDE_PROJECT_DIR="$F7" bash "$MUT_A" --hash-only 2>/dev/null)
assert_eq "7M1 mutant unshimmed still produces the real hash (it IS the pre-fix behaviour, not garbage)" \
    "$OUT72" "$OUTA_OK"
: > "$SHIM_HITS"
RCA=0
OUTA=$(PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F7" bash "$MUT_A" --hash-only 2>/dev/null) || RCA=$?
assert_eq "7M1 mutant + failing sort: exits 0 (the silence the guard exists to break)" "0" "$RCA"
if [ "$EMPTY_HASH" != "sha256-unavailable" ]; then
    assert_eq "7M1 mutant + failing sort: prints EXACTLY the empty-set digest" \
        "$EMPTY_SET_HASH_CONST" "$OUTA"
fi
assert_match "7M1 mutant leg: shim landed" '^[1-9]' "$(shim_hits)"

# --- 7M2: subshell pipefail stripped (rc guard alone is not enough) ---
MUT_B="$MUT_DIR/impact-report-mutant-b.sh"
sed 's/( set -o pipefail; canonical_changed_files | sha256_stdin )/( canonical_changed_files | sha256_stdin )/' \
    "$IR" > "$MUT_B"
PIPEFAIL_SHIPPED=$(grep -cF '( set -o pipefail; canonical_changed_files | sha256_stdin )' "$IR" || true)
PIPEFAIL_MUT=$(grep -cF '( set -o pipefail; canonical_changed_files | sha256_stdin )' "$MUT_B" || true)
PLAIN_MUT=$(grep -cF '( canonical_changed_files | sha256_stdin )' "$MUT_B" || true)
assert_eq "7M2 anchor present exactly once in the shipped script" "1" "$PIPEFAIL_SHIPPED"
assert_eq "7M2 mutation landed (pipefail text absent from the mutant)" "0" "$PIPEFAIL_MUT"
assert_eq "7M2 mutant carries the unguarded pipe exactly once" "1" "$PLAIN_MUT"
BASHN_B=0
bash -n "$MUT_B" 2>/dev/null || BASHN_B=$?
assert_eq "7M2 mutant still parses" "0" "$BASHN_B"
OUTB_OK=$(CLAUDE_PROJECT_DIR="$F7" bash "$MUT_B" --hash-only 2>/dev/null)
assert_eq "7M2 mutant unshimmed still produces the real hash" "$OUT72" "$OUTB_OK"
: > "$SHIM_HITS"
RCB=0
OUTB=$(PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F7" bash "$MUT_B" --hash-only 2>/dev/null) || RCB=$?
assert_eq "7M2 mutant + failing sort: exits 0 — the rc guard fires but the plain pipe swallows it (the halves only work as a pair)" \
    "0" "$RCB"
if [ "$EMPTY_HASH" != "sha256-unavailable" ]; then
    assert_eq "7M2 mutant + failing sort: prints EXACTLY the empty-set digest" \
        "$EMPTY_SET_HASH_CONST" "$OUTB"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: qa-gate approve wiring — refuses on an unreadable set (i8cx U2) ==="

# The consumer side of the U2 contract, driven end-to-end through the
# SHIPPED qa-gate.sh: approve's freshness check reaches this script's
# --hash-only via compute_change_set_hash (`|| printf ''`), so empty
# stdout + rc 3 must land on the impact_report_unverifiable refusal
# (exit 2) rather than binding. The mutant leg (8M) then proves the chain
# was load-bearing: with 7M1's mutant installed, the same failing sort
# makes generator and checker AGREE on the empty-set digest and approve
# BINDS an approval to a change set that was never read — the live
# pre-i8cx failure, reproduced under a bound name.
#
# Real bd, same fixture recipe as review-separation.test.sh (all scripts
# copied, bd init, .git removed to pin the non-git arm). Skip-with-log
# without bd, mirroring this spec's own missing-dep convention (sections
# 3/4); the guard itself is covered bd-free in section 7 either way.

if ! command -v bd >/dev/null 2>&1; then
    printf 'SKIPPED: section 8 (bd CLI not on PATH — the approve wiring legs need Beads)\n'
else
    F8=$(mktemp -d -t impact-report-approve.XXXXXX)
    FIXTURES+=("$F8")
    mkdir -p "$F8/.claude/scripts" "$F8/.claude/.qa-tracking" "$F8/.beads"
    cp "$PROJECT_DIR/.claude/scripts/"*.sh "$F8/.claude/scripts/"
    chmod +x "$F8/.claude/scripts/"*.sh
    QG8="$F8/.claude/scripts/qa-gate.sh"
    IR8="$F8/.claude/scripts/impact-report.sh"
    TRACK8="$F8/.claude/.qa-tracking"

    S8_OLDPWD=$(pwd)
    cd "$F8" && bd init >/dev/null 2>&1
    rm -rf "$F8/.git"   # pin the non-git arm (mirrors review-separation.test.sh)

    s8_labels() {
        bd show "$1" --json 2>/dev/null \
            | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
            2>/dev/null || echo ""
    }
    s8_comments() {
        { bd show "$1" --json --include-comments 2>/dev/null \
            || bd show "$1" --json 2>/dev/null || true; } \
            | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' \
            2>/dev/null || echo ""
    }
    s8_completion() {
        # The F7 completion contract record, written through the real writer
        # (same shape review-separation.test.sh seeds).
        local tid="$1" file="$2" pay
        pay="$TRACK8/completion-draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
        cat > "$pay" <<JSON
{"task_id":"$tid","role":"devops","model":"seeded","pin":"seeded","files_changed":["$file"],"tests_added":["impact-report.test.sh::section-8"],"decisions":["seeded fixture"],"blockers":[],"llm_observations":"seeded by the impact-report section-8 fixture","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown"}
JSON
        bash "$QG8" completion-record "$tid" --file "$pay" >/dev/null 2>&1
    }
    s8_artifact() {
        # s8_artifact <tid> <reviewed-hash> — independent reviewer, no findings.
        local tid="$1" rh="$2" art
        art="$TRACK8/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
        cat > "$art" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"qa-claude","reviewer_model":"test-model","reviewer_pin":"test-model","reviewed_hash":"$rh","risk_threshold":"high","stop_condition":"acceptance criteria traced to tests","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}
JSON
        bash "$QG8" review-record "$tid" < "$art" >/dev/null 2>&1
    }

    # --- T1: SHIPPED scripts; every other precondition satisfied ---
    T1=$(bd create "i8cx U2: approve refuses on unreadable set" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    printf 'src/one.ts\n' > "$TRACK8/changed-files.txt"
    CLAUDE_PROJECT_DIR="$F8" bash "$QG8" enter "$T1" >/dev/null 2>&1
    s8_completion "$T1" "src/one.ts"
    bd comments add "$T1" "IMPLEMENTER: role=backend task=$T1 at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
    RH1=$(CLAUDE_PROJECT_DIR="$F8" bash "$IR8" --hash-only 2>/dev/null)
    s8_artifact "$T1" "$RH1"
    assert_eq "8.0 fixture sane: enter wrote a report binding the REAL hash" \
        "$RH1" "$(jq -r '.change_set_hash' "$TRACK8/impact-report-$(printf '%s' "$T1" | tr -c 'A-Za-z0-9._-' '_').json" 2>/dev/null)"

    # 8.1 With completion, implementer and independent review all in place, a
    # failing tracker read must STILL refuse — impact_report_unverifiable,
    # exit 2, no label flips. (Pre-fix, --hash-only answered e3b0c442… here;
    # against a report generated over the same failed read the comparison
    # MATCHED — 8M reproduces that end state.)
    : > "$SHIM_HITS"
    RC81=0
    OUT81=$(PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F8" bash "$QG8" approve "$T1" "must refuse: tracker unreadable" 2>/dev/null) || RC81=$?
    assert_eq "8.1 approve + failing sort: exit 2" "2" "$RC81"
    assert_eq "8.1 approve + failing sort: error_key=impact_report_unverifiable" \
        "impact_report_unverifiable" "$(printf '%s' "$OUT81" | jq -r '.error_key // empty')"
    assert_match "8.1 shim landed inside approve's recompute" '^[1-9]' "$(shim_hits)"
    L81=$(s8_labels "$T1")
    assert_eq "8.1 refusal added no qa-approved" \
        "absent" "$(printf '%s' "$L81" | grep -qF 'qa-approved' && echo present || echo absent)"
    assert_match "8.1 refusal kept qa-gate-entered (gate stays armed)" 'qa-gate-entered' "$L81"

    # 8.2 Restore control: same task, working sort -> approve SUCCEEDS, so
    # the 8.1 refusal was the shim's doing, not a broken fixture.
    RC82=0
    OUT82=$(CLAUDE_PROJECT_DIR="$F8" bash "$QG8" approve "$T1" --no-design "i8cx U2: testing impact-freshness wiring, not design-satisfied" "restore control: real read, real hash" 2>/dev/null) || RC82=$?
    assert_eq "8.2 restore: approve exits 0" "0" "$RC82"
    assert_eq "8.2 restore: status=approved" "approved" "$(printf '%s' "$OUT82" | jq -r '.status // empty')"
    assert_match "8.2 restore: qa-approved label present" 'qa-approved' "$(s8_labels "$T1")"

    # --- 8M: the end-to-end corruption, reproduced under a bound name ---
    # 7M1's mutant installed as the fixture's impact-report.sh, failing sort
    # active for EVERY step, so the corrupted world is self-consistent —
    # which is exactly why the defect was silent: enter writes a report
    # whose change_set_hash is the empty-set digest over a NON-EMPTY
    # tracker, the reviewer's reviewed_hash agrees (every consumer reads
    # the same silent answer), and approve BINDS.
    cp "$MUT_A" "$IR8"
    T2=$(bd create "i8cx U2: mutant binds a hollow approval" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    printf 'src/two.ts\n' > "$TRACK8/changed-files.txt"
    : > "$SHIM_HITS"
    PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F8" bash "$QG8" enter "$T2" >/dev/null 2>&1
    R2="$TRACK8/impact-report-$(printf '%s' "$T2" | tr -c 'A-Za-z0-9._-' '_').json"
    assert_eq "8M mutant enter: a report was written over the FAILED read" \
        "present" "$([ -f "$R2" ] && echo present || echo absent)"
    if [ "$EMPTY_HASH" != "sha256-unavailable" ]; then
        assert_eq "8M mutant report binds the empty-set digest while the tracker names src/two.ts" \
            "$EMPTY_SET_HASH_CONST" "$(jq -r '.change_set_hash' "$R2" 2>/dev/null)"
    fi
    assert_eq "8M mutant report claims files=[] over a non-empty tracker" \
        "0" "$(jq -r '.files | length' "$R2" 2>/dev/null)"
    assert_eq "8M the tracker REALLY was non-empty at enter time" \
        "src/two.ts" "$(cat "$TRACK8/changed-files.txt" 2>/dev/null)"
    s8_completion "$T2" "src/two.ts"
    bd comments add "$T2" "IMPLEMENTER: role=backend task=$T2 at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
    RH2=$(PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F8" bash "$IR8" --hash-only 2>/dev/null)
    s8_artifact "$T2" "$RH2"
    RC8M=0
    OUT8M=$(PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$F8" bash "$QG8" approve "$T2" --no-design "i8cx U2 META: proving the mutant binds, not design-satisfied" "mutant leg: this approval binds a change set that was never read" 2>/dev/null) || RC8M=$?
    assert_eq "8M mutant approve: exit 0 — the freshness comparison MATCHED on the silent answer (8.1 would be green-blind here)" \
        "0" "$RC8M"
    assert_eq "8M mutant approve: status=approved" \
        "approved" "$(printf '%s' "$OUT8M" | jq -r '.status // empty')"
    assert_match "8M mutant approve: qa-approved bound over the unread set" \
        'qa-approved' "$(s8_labels "$T2")"
    if [ "$EMPTY_HASH" != "sha256-unavailable" ]; then
        assert_match "8M the approval record itself carries the empty-set digest" \
            "change_set_hash=$EMPTY_SET_HASH_CONST" "$(s8_comments "$T2")"
    fi

    # 8R Restore: shipped script back in place, byte-identical, and a fresh
    # read of a reseeded tracker yields a real hash again.
    cp "$PROJECT_DIR/.claude/scripts/impact-report.sh" "$IR8"
    assert_eq "8R fixture impact-report.sh restored byte-identical to shipped" \
        "same" "$(cmp -s "$IR8" "$PROJECT_DIR/.claude/scripts/impact-report.sh" && echo same || echo differs)"
    printf 'src/three.ts\n' > "$TRACK8/changed-files.txt"
    OUT8R=$(CLAUDE_PROJECT_DIR="$F8" bash "$IR8" --hash-only 2>/dev/null)
    assert_eq "8R restored script hashes the reseeded tracker for real" \
        "$(printf 'src/three.ts\n' | test_sha256)" "$OUT8R"

    cd "$S8_OLDPWD" || true
fi

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

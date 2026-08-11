#!/bin/bash
# workflow-manifest.test.sh — L1 spec for the shipped-surface manifest
# generator and its upgrade classifier (v4.1 Phase U0 /
# claude-workflow-plugin-gzc).
#
# WHAT THIS PROTECTS
# ------------------
# .claude/scripts/workflow-manifest.sh is the ONE machine-readable answer to
# "what does this plugin ship, and may the installer overwrite this copy of
# it?". Two properties make it usable as an upgrade oracle, and both are the
# kind that rot silently:
#
#   SURFACE FIDELITY — the enumerated set must match install.sh's copy loops.
#   The failure mode is documented in LESSONS.md (2026-06-12): install.sh's
#   hardcoded agent list dropped grader.md for two releases while the repo's
#   own tests stayed green. A manifest that quietly stops listing a shipped
#   file reproduces that failure with a rubber stamp on top, so the real-repo
#   section below presence-asserts specific once-droppable assets by name.
#
#   DETERMINISM — later specs regenerate this output and byte-compare it
#   against the frozen tables under manifests/. A timestamp, a locale-
#   dependent sort, or an unordered glob would make every comparison a coin
#   flip. Two consecutive runs must be byte-identical.
#
#   TABLE FIDELITY — a frozen table under manifests/ must describe the tree of
#   the release it is NAMED for. install.sh classifies an installed tree
#   against it (workflow-manifest.sh:490-503), so a table that has drifted from
#   its own release makes every verdict wrong in the safest-LOOKING direction:
#   a file the operator never touched matches neither the new source nor the
#   recorded oldhash, lands on preserve-custom, and gets a spurious .new
#   sidecar. Section 6 pins this for the CURRENT release by regenerating from
#   `git archive <tag>` rather than from the working tree.
#
# ASSERTION ANCHORING: every check below is anchored to TEXT (a path, a class
# token, a verdict token, a row grammar) and never to a line number — the
# brittleness LESSONS.md (2026-06-13) records after three re-anchorings.
#
# SECTIONS
#   1. Synthetic-source surface: a tiny fixture tree proves both what IS
#      enumerated (with the right class) and what is EXCLUDED.
#   2. Determinism: two consecutive generate runs are byte-identical.
#   3. Real-repo sanity: named assets present, operator memory and the
#      plugin's own L1 suite absent.
#   4. Classify decision table: all six verdicts, one assertion each.
#   4d. The shipped-docs subset (v4.1 / U0.8): the four verdicts its
#      asymmetric old-table membership makes reachable.
#   5. Frozen-table FORMAT: manifests/v3.5.0.sha256 row grammar, sort order,
#      v3.5 sentinels present, v4 markers absent, and the U0.8 refreeze
#      (docs/HOOKS.md in, docs/CODEX_SETUP.md out) from both sides.
#   6. Frozen-table CONTENT for the current release: the table named by
#      .claude-plugin/plugin.json reproduces byte-for-byte from the tree of
#      the tag it names, under the current generator. Notes a skip when the
#      table or the tag is not in this checkout.
#   7. META-TESTs: each proves a check above is capable of failing.
#
# Exit codes:
#   0  all assertions pass
#   1  one or more assertions failed

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SCRIPT="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
FROZEN="$PROJECT_DIR/manifests/v3.5.0.sha256"

# The CURRENT release, DERIVED rather than hardcoded, so Section 6 follows the
# version bump instead of needing an edit at every release.
# .claude-plugin/plugin.json is the one version-carrying manifest in this repo
# (HANDOFF.md:305-313), and after a release it keeps naming that release for the
# whole development period that follows — which is exactly what makes it the
# right pointer at "the frozen table that is currently shipping".
#
# Every lookup below is allowed to MISS, and a miss is a note, never a failure.
# Between a version bump and the release that freezes its table there is a
# window where plugin.json names a release that has neither a table nor a tag;
# a check that went red for that whole window would be muted and then deleted.
RELEASE_VERSION=$(jq -r '.version // empty' \
    "$PROJECT_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo "")
RELEASE_TAG="v$RELEASE_VERSION"
RELEASE_TABLE="$PROJECT_DIR/manifests/$RELEASE_TAG.sha256"

TAB=$(printf '\t')
# The row grammar the frozen tables and every generate run must satisfy:
#   <non-empty path><TAB><class token><TAB><64 lowercase hex>
ROW_RE="^[^${TAB}]+${TAB}(workflow|operator|merged)${TAB}"'[0-9a-f]{64}$'

WORK=$(mktemp -d -t workflow-manifest-test.XXXXXX)
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

# --- helpers ---------------------------------------------------------------

# mkfile <root> <relative-path> <content> — create a fixture file, parents
# included.
mkfile() {
    local root="$1" rel="$2" content="$3"
    mkdir -p "$root/$(dirname "$rel")"
    printf '%s\n' "$content" > "$root/$rel"
}

# field_of <tsv> <path> <field-number> — exact-match lookup on column 1.
# Prints the requested column, or nothing when the path has no row. Uses awk
# string equality (not grep) so a path containing regex metacharacters could
# never widen the match.
field_of() {
    awk -F'\t' -v p="$2" -v n="$3" '$1 == p { print $n; exit }' "$1"
}

# row_count <tsv> <path> — how many rows carry exactly this path (0 or 1).
row_count() {
    awk -F'\t' -v p="$2" '$1 == p { n++ } END { print n + 0 }' "$1"
}

# prefix_count <tsv> <prefix> — how many rows' paths start with <prefix>.
# Used for "no .claude/scripts/tests/ path leaked in" style checks.
prefix_count() {
    awk -F'\t' -v pre="$2" 'index($1, pre) == 1 { n++ } END { print n + 0 }' "$1"
}

# check_table_format <file> — 0 when EVERY non-empty line matches the row
# grammar, 1 when any line does not (or the file has no rows at all), 2 when
# the file is missing.
#
# Takes a FILE so META-TEST 1 can run byte-identical logic against a
# deliberately corrupted copy. A table with zero rows returns 1 on purpose:
# without that arm an empty file would pass vacuously.
check_table_format() {
    local f="$1"
    [ -f "$f" ] || return 2
    grep -qv "^[[:space:]]*$" "$f" || return 1
    if grep -v "^[[:space:]]*$" "$f" | grep -qvE "$ROW_RE"; then
        return 1
    fi
    return 0
}

# tables_match <a> <b> — 0 when the two manifest tables are byte-identical,
# 1 when they differ, 2 when either file is missing.
#
# Section 6's whole claim runs through here, and so does META 4, which drives
# BYTE-IDENTICAL logic against a deliberately mutated copy — the same reason
# check_table_format above takes a file rather than reaching for $FROZEN.
#
# The missing-input arm is 2 rather than 1 on purpose, and META 4 pins it: a
# comparator that returned "match" for a file that is not there would let
# Section 6 pass on a checkout carrying no table at all, which is the one
# result nobody would look at twice.
tables_match() {
    local a="$1" b="$2"
    { [ -f "$a" ] && [ -f "$b" ]; } || return 2
    cmp -s "$a" "$b" || return 1
    return 0
}

# --- preflight -------------------------------------------------------------

echo "=== Section 0: the script under test ==="
assert_eq "workflow-manifest.sh exists at .claude/scripts/workflow-manifest.sh" \
    "yes" "$([ -f "$SCRIPT" ] && echo yes || echo no)"
if [ ! -f "$SCRIPT" ]; then
    printf '\nFAILED: %d (script missing; remaining sections cannot run)\n' "$((FAIL))"
    exit 1
fi
assert_eq "workflow-manifest.sh parses under bash -n" "0" \
    "$(bash -n "$SCRIPT" 2>/dev/null && echo 0 || echo 1)"
assert_eq "workflow-manifest.sh --help exits 0" "0" \
    "$(bash "$SCRIPT" --help >/dev/null 2>&1 && echo 0 || echo $?)"
# Usage errors are exit 2, distinct from runtime failure (1), so a caller can
# tell "you invoked me wrong" from "I could not hash a file".
bash "$SCRIPT" >/dev/null 2>&1 && RC=0 || RC=$?
assert_eq "no subcommand is a usage error (exit 2)" "2" "$RC"
bash "$SCRIPT" generate >/dev/null 2>&1 && RC=0 || RC=$?
assert_eq "generate without <source-root> is a usage error (exit 2)" "2" "$RC"
bash "$SCRIPT" generate "$WORK/definitely-not-here" >/dev/null 2>&1 && RC=0 || RC=$?
assert_eq "generate with a nonexistent source root is a usage error (exit 2)" "2" "$RC"
bash "$SCRIPT" classify --target "$WORK" --source "$WORK" >/dev/null 2>&1 && RC=0 || RC=$?
assert_eq "classify without --old-table is a usage error (exit 2)" "2" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: synthetic-source surface (what is in, what is out) ==="

SYN="$WORK/synthetic-source"
mkdir -p "$SYN"

# In-surface members, one per copy loop in install.sh.
mkfile "$SYN" ".claude/agents/qa.md"                    "synthetic qa agent"
mkfile "$SYN" ".claude/scripts/qa-gate.sh"              "#!/bin/bash"
mkfile "$SYN" ".claude/commands/workflow-model.md"      "synthetic command"
mkfile "$SYN" ".claude/hooks/hooks.json"                '{"hooks":{}}'
mkfile "$SYN" ".claude/skills/workflow-engine/SKILL.md" "synthetic skill"
mkfile "$SYN" ".claude/mcp/demo-mcp/src/server.js"      "// synthetic mcp"
mkfile "$SYN" ".claude/tests/mutation/mutation-sweep.sh" "#!/bin/bash"
mkfile "$SYN" ".worktreeinclude"                        ".env"
mkfile "$SYN" ".claude-plugin/plugin.json"              '{"name":"synthetic"}'
mkfile "$SYN" "docs/CODEX_SETUP.md"                     "synthetic codex setup"
mkfile "$SYN" "docs/HOOKS.md"                           "synthetic hooks reference"
mkfile "$SYN" ".claude/rubrics/default.md"              "synthetic rubric"
mkfile "$SYN" ".claude/rubric-config"                   "default"
mkfile "$SYN" ".claude/model-ranking"                   "opus"
mkfile "$SYN" "LESSONS.md"                              "# Lessons"
mkfile "$SYN" ".claude/settings.json"                   '{"env":{}}'
mkfile "$SYN" ".mcp.json"                               '{"mcpServers":{}}'

# Deliberately NOT created: .claude/model-roles, .claude/review-config,
# .claude/effort-verdict. A v3.5-era tree has none of them and their absence
# must be silent, not an error — that is what makes a per-release frozen
# table meaningful.

# Out-of-surface members. Each one is a real thing that exists in the repo
# and must never reach an install target through this manifest.
mkfile "$SYN" ".claude/scripts/tests/some.test.sh"                    "#!/bin/bash"
mkfile "$SYN" ".claude/mcp/demo-mcp/node_modules/pkg/index.js"        "// vendored dep"
mkfile "$SYN" ".claude/mcp/demo-mcp/debug.log"                        "noise"
mkfile "$SYN" ".claude/tests/mutation/calibration/runs/report.json"   '{"run":1}'
mkfile "$SYN" "CLAUDE.md"                                             "# operator memory"
mkfile "$SYN" ".claude/settings.local.json"                           '{"local":true}'
# docs/ is a NAMED SUBSET, never a scan (v4.1 / U0.8). These three are real
# repo docs that sit next to the two shipped ones and must stay out: docs/ in an
# install target belongs to the operator, and a scan_flat over docs/*.md would
# both bloat every frozen table and let the uninstaller's root-scope walk offer
# to move an operator's own docs out of their project.
mkfile "$SYN" "docs/ARCHITECTURE.md"                                  "# not shipped"
mkfile "$SYN" "docs/al-2026-01-01-000000-deadbeef.md"                 "# dated agentlint report"
mkfile "$SYN" "docs/plans/README.md"                                  "# not shipped"

SYN_TSV="$WORK/synthetic.tsv"
bash "$SCRIPT" generate "$SYN" > "$SYN_TSV" 2>"$WORK/synthetic.err" && RC=0 || RC=$?
assert_eq "generate on the synthetic tree exits 0 (absent optional files are not errors)" \
    "0" "$RC"
assert_eq "generate on the synthetic tree writes nothing to stderr" \
    "" "$(cat "$WORK/synthetic.err")"
assert_eq "generate output satisfies the <path>TAB<class>TAB<sha256> row grammar" \
    "0" "$(check_table_format "$SYN_TSV" && echo 0 || echo $?)"

# Presence + class. Spot-checks span all three classes and both scan shapes
# (flat directory scan and pruned recursive scan).
assert_eq "surface: .claude/agents/qa.md is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" ".claude/agents/qa.md" 2)"
assert_eq "surface: .claude/scripts/qa-gate.sh is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" ".claude/scripts/qa-gate.sh" 2)"
assert_eq "surface: .claude/commands/workflow-model.md is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" ".claude/commands/workflow-model.md" 2)"
assert_eq "surface: .claude/hooks/hooks.json is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" ".claude/hooks/hooks.json" 2)"
assert_eq "surface: .claude/skills/workflow-engine/SKILL.md is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" ".claude/skills/workflow-engine/SKILL.md" 2)"
assert_eq "surface: .claude/mcp/demo-mcp/src/server.js is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" ".claude/mcp/demo-mcp/src/server.js" 2)"
assert_eq "surface: .claude/tests/mutation/mutation-sweep.sh is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" ".claude/tests/mutation/mutation-sweep.sh" 2)"
assert_eq "surface: .worktreeinclude is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" ".worktreeinclude" 2)"
assert_eq "surface: .claude-plugin/plugin.json is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" ".claude-plugin/plugin.json" 2)"
# The shipped-docs subset (v4.1 / U0.8). Class `workflow` on purpose: these are
# plugin-owned reference material a release rewrites, so an operator edit is
# reported and replaced with their copy in the backup — not preserved with a
# .new sidecar the way an operator-class file is.
assert_eq "surface: docs/CODEX_SETUP.md is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" "docs/CODEX_SETUP.md" 2)"
assert_eq "surface: docs/HOOKS.md is class workflow" \
    "workflow" "$(field_of "$SYN_TSV" "docs/HOOKS.md" 2)"
assert_eq "surface: .claude/rubrics/default.md is class operator" \
    "operator" "$(field_of "$SYN_TSV" ".claude/rubrics/default.md" 2)"
assert_eq "surface: .claude/rubric-config is class operator" \
    "operator" "$(field_of "$SYN_TSV" ".claude/rubric-config" 2)"
assert_eq "surface: .claude/model-ranking is class operator" \
    "operator" "$(field_of "$SYN_TSV" ".claude/model-ranking" 2)"
assert_eq "surface: LESSONS.md is class operator" \
    "operator" "$(field_of "$SYN_TSV" "LESSONS.md" 2)"
assert_eq "surface: .claude/settings.json is class merged" \
    "merged" "$(field_of "$SYN_TSV" ".claude/settings.json" 2)"
assert_eq "surface: .mcp.json is class merged" \
    "merged" "$(field_of "$SYN_TSV" ".mcp.json" 2)"

# Exclusions.
assert_eq "excluded: .claude/scripts/tests/ never appears (flat scripts scan)" \
    "0" "$(prefix_count "$SYN_TSV" ".claude/scripts/tests/")"
assert_eq "excluded: node_modules under .claude/mcp is pruned" \
    "0" "$(row_count "$SYN_TSV" ".claude/mcp/demo-mcp/node_modules/pkg/index.js")"
assert_eq "excluded: *.log under .claude/mcp is dropped" \
    "0" "$(row_count "$SYN_TSV" ".claude/mcp/demo-mcp/debug.log")"
assert_eq "excluded: calibration/runs/ under .claude/tests/mutation is pruned" \
    "0" "$(row_count "$SYN_TSV" ".claude/tests/mutation/calibration/runs/report.json")"
assert_eq "excluded: CLAUDE.md (never-touched operator memory)" \
    "0" "$(row_count "$SYN_TSV" "CLAUDE.md")"
assert_eq "excluded: .claude/settings.local.json (per-machine, never copied)" \
    "0" "$(row_count "$SYN_TSV" ".claude/settings.local.json")"
# docs/ is a NAMED SUBSET, not a directory scan. The count assertion is the one
# that matters: a future `scan_flat workflow docs '*.md'` would still satisfy
# every per-file presence check above and would be caught only here.
assert_eq "docs/ subset: EXACTLY two docs rows, never a directory scan" \
    "2" "$(prefix_count "$SYN_TSV" "docs/")"
assert_eq "excluded: docs/ARCHITECTURE.md (a repo doc that is not shipped)" \
    "0" "$(row_count "$SYN_TSV" "docs/ARCHITECTURE.md")"
assert_eq "excluded: docs/al-*.md (dated AgentLint reports are not shipped)" \
    "0" "$(row_count "$SYN_TSV" "docs/al-2026-01-01-000000-deadbeef.md")"
assert_eq "excluded: docs/plans/ (no recursion under docs/)" \
    "0" "$(row_count "$SYN_TSV" "docs/plans/README.md")"

# Absent optional single files are omitted rather than erroring.
assert_eq "absent optional file .claude/model-roles is omitted, not errored" \
    "0" "$(row_count "$SYN_TSV" ".claude/model-roles")"
assert_eq "absent optional file .claude/effort-verdict is omitted, not errored" \
    "0" "$(row_count "$SYN_TSV" ".claude/effort-verdict")"

# Exact row count: 11 workflow + 4 operator + 2 merged. A bare "did my file
# appear" check cannot see a rule that started matching TOO MUCH.
assert_eq "synthetic tree yields exactly 17 rows" "17" \
    "$(wc -l < "$SYN_TSV" | tr -d ' ')"
assert_eq "synthetic tree yields 11 workflow rows" "11" \
    "$(awk -F'\t' '$2 == "workflow"' "$SYN_TSV" | wc -l | tr -d ' ')"
assert_eq "synthetic tree yields 4 operator rows" "4" \
    "$(awk -F'\t' '$2 == "operator"' "$SYN_TSV" | wc -l | tr -d ' ')"
assert_eq "synthetic tree yields 2 merged rows" "2" \
    "$(awk -F'\t' '$2 == "merged"' "$SYN_TSV" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: determinism (byte-identical across runs) ==="

SYN_TSV_2="$WORK/synthetic-run2.tsv"
bash "$SCRIPT" generate "$SYN" > "$SYN_TSV_2"
assert_eq "two consecutive generate runs on the same tree are byte-identical" \
    "0" "$(cmp -s "$SYN_TSV" "$SYN_TSV_2" && echo 0 || echo 1)"
assert_eq "generate output is in LC_ALL=C sort order" \
    "0" "$(LC_ALL=C sort "$SYN_TSV" | cmp -s - "$SYN_TSV" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: real-repo sanity ==="

REPO_TSV="$WORK/repo.tsv"
bash "$SCRIPT" generate "$PROJECT_DIR" > "$REPO_TSV" && RC=0 || RC=$?
assert_eq "generate against the repo root exits 0" "0" "$RC"

# Named once-droppable assets. grader.md is the file install.sh actually lost
# for two releases; the other three are one per scan shape so a rule that
# stopped firing entirely could not hide.
for p in \
    ".claude/scripts/qa-gate.sh" \
    ".claude/agents/grader.md" \
    ".claude/scripts/workflow-denylist.sh" \
    ".claude-plugin/plugin.json" \
    "docs/CODEX_SETUP.md" \
    "docs/HOOKS.md"
do
    assert_eq "real repo: manifest lists $p" "1" "$(row_count "$REPO_TSV" "$p")"
done

assert_eq "real repo: manifest does NOT list CLAUDE.md" \
    "0" "$(row_count "$REPO_TSV" "CLAUDE.md")"
assert_eq "real repo: manifest lists no .claude/scripts/tests/ path" \
    "0" "$(prefix_count "$REPO_TSV" ".claude/scripts/tests/")"
# The docs subset, against the REAL docs/ directory — which holds 14 references
# plus a growing pile of dated AgentLint reports. Two rows and no more.
assert_eq "real repo: EXACTLY two docs/ rows (the named subset, not a scan)" \
    "2" "$(prefix_count "$REPO_TSV" "docs/")"
for notshipped in \
    "docs/ARCHITECTURE.md" \
    "docs/WORKFLOW.md" \
    "docs/AGENTS.md" \
    "docs/AGENTLINT_REPORT.md" \
    "docs/plans/README.md"
do
    assert_eq "real repo: manifest does NOT list $notshipped" \
        "0" "$(row_count "$REPO_TSV" "$notshipped")"
done
assert_eq "real repo: both docs rows are class workflow" "workflow workflow" \
    "$(printf '%s %s' \
        "$(field_of "$REPO_TSV" "docs/CODEX_SETUP.md" 2)" \
        "$(field_of "$REPO_TSV" "docs/HOOKS.md" 2)")"
assert_eq "real repo: manifest rows satisfy the row grammar" \
    "0" "$(check_table_format "$REPO_TSV" && echo 0 || echo $?)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: classify decision table (all six verdicts) ==="

# Three trees plus a frozen table built FROM the stock tree, so the fixture
# exercises generate -> classify composition rather than hand-written hashes.
#
#   path                        OLD (stock)      SRC (new)     TGT (installed)  expect
#   .claude/settings.json       {"v":"3.5"}      {"v":"4"}     {"v":"local"}    merge
#   .claude/agents/newagent.md  -                new v4        -                copy-new
#   .claude/agents/qa.md        qa v3.5          qa v4         qa v4            skip-current
#   .claude/agents/backend.md   backend v3.5     backend v4    backend v3.5     replace-stock
#   .claude/agents/devops.md    devops v3.5      devops v4     devops OPERATOR  replace-custom
#   .claude/rubrics/default.md  rubric v3.5      rubric v4     rubric OPERATOR  preserve-custom
OLD_TREE="$WORK/classify/old"
SRC_TREE="$WORK/classify/src"
TGT_TREE="$WORK/classify/tgt"

mkfile "$OLD_TREE" ".claude/agents/qa.md"           "qa v3.5"
mkfile "$OLD_TREE" ".claude/agents/backend.md"      "backend v3.5"
mkfile "$OLD_TREE" ".claude/agents/devops.md"       "devops v3.5"
mkfile "$OLD_TREE" ".claude/rubrics/default.md"     "rubric v3.5"
mkfile "$OLD_TREE" ".claude/settings.json"          '{"v":"3.5"}'

mkfile "$SRC_TREE" ".claude/agents/qa.md"           "qa v4"
mkfile "$SRC_TREE" ".claude/agents/backend.md"      "backend v4"
mkfile "$SRC_TREE" ".claude/agents/devops.md"       "devops v4"
mkfile "$SRC_TREE" ".claude/agents/newagent.md"     "newagent v4"
mkfile "$SRC_TREE" ".claude/rubrics/default.md"     "rubric v4"
mkfile "$SRC_TREE" ".claude/settings.json"          '{"v":"4"}'

mkfile "$TGT_TREE" ".claude/agents/qa.md"           "qa v4"
mkfile "$TGT_TREE" ".claude/agents/backend.md"      "backend v3.5"
mkfile "$TGT_TREE" ".claude/agents/devops.md"       "devops OPERATOR"
mkfile "$TGT_TREE" ".claude/rubrics/default.md"     "rubric OPERATOR"
mkfile "$TGT_TREE" ".claude/settings.json"          '{"v":"local"}'

OLD_TABLE="$WORK/classify/old-table.sha256"
bash "$SCRIPT" generate "$OLD_TREE" > "$OLD_TABLE"

CLS_TSV="$WORK/classify/plan.tsv"
bash "$SCRIPT" classify --target "$TGT_TREE" --source "$SRC_TREE" \
    --old-table "$OLD_TABLE" > "$CLS_TSV" 2>"$WORK/classify/err.txt" && RC=0 || RC=$?
assert_eq "classify exits 0 on a well-formed fixture" "0" "$RC"
assert_eq "classify writes nothing to stderr" "" "$(cat "$WORK/classify/err.txt")"
assert_eq "classify emits one row per SOURCE-manifest entry (6)" "6" \
    "$(wc -l < "$CLS_TSV" | tr -d ' ')"

assert_eq "verdict merge: class merged wins regardless of hashes" \
    "merge" "$(field_of "$CLS_TSV" ".claude/settings.json" 3)"
assert_eq "verdict copy-new: path absent from the target" \
    "copy-new" "$(field_of "$CLS_TSV" ".claude/agents/newagent.md" 3)"
assert_eq "verdict skip-current: target hash == source hash" \
    "skip-current" "$(field_of "$CLS_TSV" ".claude/agents/qa.md" 3)"
assert_eq "verdict replace-stock: target hash == old-table hash" \
    "replace-stock" "$(field_of "$CLS_TSV" ".claude/agents/backend.md" 3)"
assert_eq "verdict replace-custom: workflow file differing from both" \
    "replace-custom" "$(field_of "$CLS_TSV" ".claude/agents/devops.md" 3)"
assert_eq "verdict preserve-custom: operator file differing from both" \
    "preserve-custom" "$(field_of "$CLS_TSV" ".claude/rubrics/default.md" 3)"

# The class column survives into the plan — the installer needs it to pick
# the .new-alongside treatment, not just the verdict.
assert_eq "classify carries the class column through (rubric stays operator)" \
    "operator" "$(field_of "$CLS_TSV" ".claude/rubrics/default.md" 2)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4b: old-table edge cases (degrade, never disappear) ==="

# REGRESSION (found pre-ship, gzc): with an EMPTY old table the two-file
# `NR == FNR` awk idiom is true for every record of the SECOND file, so the
# join swallowed the whole source manifest and classify exited 0 having
# printed nothing. An installer reading that plan concludes there is no work
# to do — the quietest possible way to skip an entire upgrade. An unknown or
# empty old table must degrade to "nothing is known to be stock", never to
# "nothing to do", so the row count is asserted first and explicitly.
EMPTY_TABLE="$WORK/classify/old-table-empty.sha256"
: > "$EMPTY_TABLE"
EMPTY_TSV="$WORK/classify/plan-empty-table.tsv"
bash "$SCRIPT" classify --target "$TGT_TREE" --source "$SRC_TREE" \
    --old-table "$EMPTY_TABLE" > "$EMPTY_TSV" && RC=0 || RC=$?
assert_eq "empty old table: classify still exits 0" "0" "$RC"
assert_eq "empty old table: still one row per source entry (6), not zero" "6" \
    "$(wc -l < "$EMPTY_TSV" | tr -d ' ')"
assert_eq "empty old table: nothing can be called stock" "0" \
    "$(awk -F'\t' '$3 == "replace-stock"' "$EMPTY_TSV" | wc -l | tr -d ' ')"
assert_eq "empty old table: the stock target file degrades to replace-custom" \
    "replace-custom" "$(field_of "$EMPTY_TSV" ".claude/agents/backend.md" 3)"
assert_eq "empty old table: operator preservation is unaffected" \
    "preserve-custom" "$(field_of "$EMPTY_TSV" ".claude/rubrics/default.md" 3)"
assert_eq "empty old table: hash-independent verdicts are unaffected (merge)" \
    "merge" "$(field_of "$EMPTY_TSV" ".claude/settings.json" 3)"
assert_eq "empty old table: absent-in-target is still copy-new" \
    "copy-new" "$(field_of "$EMPTY_TSV" ".claude/agents/newagent.md" 3)"
assert_eq "empty old table: already-current is still skip-current" \
    "skip-current" "$(field_of "$EMPTY_TSV" ".claude/agents/qa.md" 3)"

# A NON-empty old table that simply lacks one path — the per-path arm of the
# same rule, distinct from the whole-table-empty case above.
PARTIAL_TABLE="$WORK/classify/old-table-partial.sha256"
# awk field equality rather than a grep pattern: the delimiter is a literal
# tab and an invisible character inside a quoted regex is exactly the kind of
# thing that rots without anyone noticing.
awk -F'\t' '$1 != ".claude/agents/backend.md"' "$OLD_TABLE" > "$PARTIAL_TABLE"
PARTIAL_TSV="$WORK/classify/plan-partial-table.tsv"
bash "$SCRIPT" classify --target "$TGT_TREE" --source "$SRC_TREE" \
    --old-table "$PARTIAL_TABLE" > "$PARTIAL_TSV"
assert_eq "partial old table: the removed path is no longer stock" \
    "replace-custom" "$(field_of "$PARTIAL_TSV" ".claude/agents/backend.md" 3)"
assert_eq "partial old table: the paths still listed keep their verdicts" \
    "preserve-custom" "$(field_of "$PARTIAL_TSV" ".claude/rubrics/default.md" 3)"
assert_eq "partial old table: still one row per source entry (6)" "6" \
    "$(wc -l < "$PARTIAL_TSV" | tr -d ' ')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4c: fail loud, never a silently short manifest ==="

# A file the tool cannot hash must abort the run with a message naming it,
# and must leave NOTHING on stdout. Dropping the row instead would hand back
# a plausible-looking manifest that is one entry short — the grader.md
# failure mode with a checksum on top. Partial output matters as much as the
# exit code: a caller doing `generate ... > table` and reading the file
# without checking $? would never notice.
#
# The fixture needs a genuinely unreadable file, which chmod cannot express
# for a root user. Probe first and skip-with-log rather than assert something
# the environment cannot represent (the house CI convention).
UNREAD="$WORK/unreadable"
mkfile "$UNREAD/src" ".claude/agents/aaa.md" "first"
mkfile "$UNREAD/src" ".claude/agents/bbb.md" "second"
mkfile "$UNREAD/src" ".claude/agents/ccc.md" "third"
chmod 000 "$UNREAD/src/.claude/agents/bbb.md" 2>/dev/null || true

if [ -r "$UNREAD/src/.claude/agents/bbb.md" ]; then
    echo "  SKIPPED: this environment cannot make a file unreadable (running as root?)"
else
    bash "$SCRIPT" generate "$UNREAD/src" >"$UNREAD/out.tsv" 2>"$UNREAD/err.txt" && RC=0 || RC=$?
    assert_eq "unhashable file: generate exits non-zero" "1" \
        "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
    assert_eq "unhashable file: generate leaves NO partial manifest on stdout" "0" \
        "$(wc -c < "$UNREAD/out.tsv" | tr -d ' ')"
    assert_eq "unhashable file: the error names the offending path" "1" \
        "$(grep -c 'bbb\.md' "$UNREAD/err.txt" | tr -d ' ')"

    # Same contract on the classify side: an unreadable TARGET file must not
    # yield a truncated upgrade plan.
    mkfile "$UNREAD/tgt" ".claude/agents/aaa.md" "first"
    mkfile "$UNREAD/tgt" ".claude/agents/bbb.md" "operator edited"
    mkfile "$UNREAD/tgt" ".claude/agents/ccc.md" "third"
    chmod 644 "$UNREAD/src/.claude/agents/bbb.md"
    chmod 000 "$UNREAD/tgt/.claude/agents/bbb.md"
    bash "$SCRIPT" classify --target "$UNREAD/tgt" --source "$UNREAD/src" \
        --old-table "$EMPTY_TABLE" >"$UNREAD/plan.tsv" 2>/dev/null && RC=0 || RC=$?
    assert_eq "unhashable target file: classify exits non-zero" "1" \
        "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
    assert_eq "unhashable target file: classify leaves NO partial plan on stdout" "0" \
        "$(wc -c < "$UNREAD/plan.tsv" | tr -d ' ')"
    chmod 644 "$UNREAD/tgt/.claude/agents/bbb.md"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4d: the shipped-docs subset classifies correctly (U0.8) ==="

# The docs subset is the first surface entry whose OLD-TABLE membership is
# asymmetric: docs/HOOKS.md existed at v3.5 and docs/CODEX_SETUP.md did not.
# That asymmetry is the whole reason the refreeze had to happen in the same
# commit as the surface change, so the four reachable verdicts are pinned here
# against a purpose-built fixture rather than inferred from section 5's
# presence checks.
#
# Four target shapes, one old table generated FROM the "v3.5" tree, so the
# fixture exercises generate -> classify composition:
#
#   target                             CODEX_SETUP.md  HOOKS.md
#   no docs/ at all                    copy-new        copy-new
#   carries the stock v3.5 HOOKS.md    copy-new        replace-stock
#   carries an EDITED HOOKS.md         copy-new        replace-custom
#   already at the shipped bytes       skip-current    skip-current
DOC_OLD="$WORK/docs/old"     # stands in for the v3.5.0 tag tree
DOC_SRC="$WORK/docs/src"     # stands in for HEAD
mkfile "$DOC_OLD" "docs/HOOKS.md"       "hooks reference v3.5"
mkfile "$DOC_SRC" "docs/HOOKS.md"       "hooks reference v4"
mkfile "$DOC_SRC" "docs/CODEX_SETUP.md" "codex setup v4"

DOC_TABLE="$WORK/docs/old-table.sha256"
bash "$SCRIPT" generate "$DOC_OLD" > "$DOC_TABLE"
assert_eq "docs classify: the stand-in old table has HOOKS.md but not CODEX_SETUP.md" \
    "1 0" "$(printf '%s %s' \
        "$(row_count "$DOC_TABLE" "docs/HOOKS.md")" \
        "$(row_count "$DOC_TABLE" "docs/CODEX_SETUP.md")")"

# doc_verdict <target-dir> <path> — the classify verdict for one docs row.
doc_verdict() {
    bash "$SCRIPT" classify --target "$1" --source "$DOC_SRC" --old-table "$DOC_TABLE" 2>/dev/null \
        | awk -F'\t' -v p="$2" '$1 == p { print $3; exit }'
}

DOC_T_NONE="$WORK/docs/tgt-none"
mkdir -p "$DOC_T_NONE"
assert_eq "docs classify: CODEX_SETUP.md is copy-new when the target has no docs/" \
    "copy-new" "$(doc_verdict "$DOC_T_NONE" "docs/CODEX_SETUP.md")"
assert_eq "docs classify: HOOKS.md is copy-new too when the target has no docs/" \
    "copy-new" "$(doc_verdict "$DOC_T_NONE" "docs/HOOKS.md")"

DOC_T_STOCK="$WORK/docs/tgt-stock"
mkfile "$DOC_T_STOCK" "docs/HOOKS.md" "hooks reference v3.5"
assert_eq "docs classify: an untouched v3.5 HOOKS.md is replace-stock (the refreeze is what makes this reachable)" \
    "replace-stock" "$(doc_verdict "$DOC_T_STOCK" "docs/HOOKS.md")"
assert_eq "docs classify: ...and CODEX_SETUP.md is still copy-new (no v3.5 hash to match)" \
    "copy-new" "$(doc_verdict "$DOC_T_STOCK" "docs/CODEX_SETUP.md")"

DOC_T_EDITED="$WORK/docs/tgt-edited"
mkfile "$DOC_T_EDITED" "docs/HOOKS.md" "hooks reference v3.5 WITH AN OPERATOR EDIT"
# workflow class, so the plugin's product wins and the operator's copy goes to
# the backup. NOT preserve-custom: a .new sidecar next to a reference doc would
# be litter nobody reads, and the doc has to match the code it documents.
assert_eq "docs classify: an EDITED HOOKS.md is replace-custom, not preserve-custom" \
    "replace-custom" "$(doc_verdict "$DOC_T_EDITED" "docs/HOOKS.md")"

DOC_T_CURRENT="$WORK/docs/tgt-current"
mkfile "$DOC_T_CURRENT" "docs/HOOKS.md"       "hooks reference v4"
mkfile "$DOC_T_CURRENT" "docs/CODEX_SETUP.md" "codex setup v4"
assert_eq "docs classify: a target already at the shipped bytes is skip-current (HOOKS.md)" \
    "skip-current" "$(doc_verdict "$DOC_T_CURRENT" "docs/HOOKS.md")"
assert_eq "docs classify: a target already at the shipped bytes is skip-current (CODEX_SETUP.md)" \
    "skip-current" "$(doc_verdict "$DOC_T_CURRENT" "docs/CODEX_SETUP.md")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: frozen table manifests/v3.5.0.sha256 ==="

assert_eq "frozen table exists at manifests/v3.5.0.sha256" \
    "yes" "$([ -f "$FROZEN" ] && echo yes || echo no)"

if [ -f "$FROZEN" ]; then
    assert_eq "frozen table: every non-empty line matches the row grammar" \
        "0" "$(check_table_format "$FROZEN" && echo 0 || echo $?)"
    assert_eq "frozen table: file is in LC_ALL=C sort order" \
        "0" "$(LC_ALL=C sort "$FROZEN" | cmp -s - "$FROZEN" && echo 0 || echo 1)"
    assert_eq "frozen table: pure rows, no comment lines (byte-reproducible)" \
        "0" "$(grep -c '^#' "$FROZEN" | tr -d ' ')"

    # v3.5 sentinels — both shipped in the v3.5.0 tag.
    assert_eq "frozen table: contains .claude/agents/grader.md" \
        "1" "$(row_count "$FROZEN" ".claude/agents/grader.md")"
    assert_eq "frozen table: contains .claude/scripts/qa-gate.sh" \
        "1" "$(row_count "$FROZEN" ".claude/scripts/qa-gate.sh")"

    # THE U0.8 REFREEZE, pinned from both sides. Extending the generate surface
    # without regenerating this table in the SAME commit breaks the flagship L2
    # spec's byte-integrity check (installer-v3-upgrade.sh section 2 regenerates
    # from the tag and cmp's), and these two rows are exactly what that refreeze
    # changed. They also pin that the table came from the TAG rather than from
    # HEAD: the v3.5.0 tree has docs/HOOKS.md and has never had CODEX_SETUP.md,
    # so the asymmetry below is only reproducible from the tag.
    #
    # Downstream, the asymmetry is what makes the two docs rows classify
    # DIFFERENTLY on a v3.5 -> v4 upgrade: HOOKS.md has a v3.5 hash, so a target
    # still carrying the untouched v3.5 file is replace-stock (section 4d proves
    # it); CODEX_SETUP.md has none, so it can only ever be copy-new or, once
    # installed, skip-current.
    assert_eq "frozen table: contains docs/HOOKS.md (the v3.5.0 tag shipped it)" \
        "1" "$(row_count "$FROZEN" "docs/HOOKS.md")"
    assert_eq "frozen table: does NOT contain docs/CODEX_SETUP.md (absent from the tag, so omitted)" \
        "0" "$(row_count "$FROZEN" "docs/CODEX_SETUP.md")"
    assert_eq "frozen table: docs/HOOKS.md is class workflow there too" \
        "workflow" "$(field_of "$FROZEN" "docs/HOOKS.md" 2)"
    assert_eq "frozen table: EXACTLY one docs/ row (the tag had no other shipped doc)" \
        "1" "$(prefix_count "$FROZEN" "docs/")"

    # v4-only markers — their presence would mean the table was generated
    # from the wrong tree (e.g. HEAD instead of the tag), which would make
    # every customization verdict wrong in the safest-looking direction.
    for marker in \
        ".claude/scripts/review-check.sh" \
        ".claude/model-roles" \
        ".claude/scripts/workflow-denylist.sh" \
        ".claude/review-config" \
        ".claude/effort-verdict"
    do
        assert_eq "frozen table: does NOT contain v4-only $marker" \
            "0" "$(row_count "$FROZEN" "$marker")"
    done

    assert_eq "frozen table: does NOT contain CLAUDE.md" \
        "0" "$(row_count "$FROZEN" "CLAUDE.md")"
    assert_eq "frozen table: contains no .claude/scripts/tests/ path" \
        "0" "$(prefix_count "$FROZEN" ".claude/scripts/tests/")"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: the current release's table reproduces from its own tag ==="

# WHY THIS SECTION EXISTS — claude-workflow-plugin-ce5.
#
# HANDOFF.md's release checklist used to assert byte-reproducibility as
#
#     workflow-manifest.sh generate . | cmp - manifests/v4.1.0.sha256
#
# — a LIVE WORKING TREE against a table frozen at the release commit. That is
# red BY CONSTRUCTION. It goes red the moment any manifest-covered path changes
# after the freeze, which is every development day, and it says nothing about
# the generator when it does. Measured 2026-08-07 at 1a3d59b: 73 differing
# lines, from 36 rows whose hash moved plus one row that did not exist at the
# tag (.claude/scripts/beads-ledger.sh). Anyone running that checklist got a red
# on a load-bearing determinism assert with no way to tell stale-table drift
# from a broken generator.
#
# The property actually worth asserting is TREE-SCOPED: the frozen table
# reproduces byte-for-byte from the tree of the TAG IT NAMES, under the current
# generator. It stays green across development because a tag's tree does not
# move, and it is the claim install.sh's classifier actually depends on.
#
# ON claude-workflow-plugin-1nz (live-repo assertions failing under concurrent
# writers), stated exactly rather than as a blanket "this one is safe": the tag
# side genuinely cannot move — it is read out of the object database, not the
# working tree. The other two inputs, the frozen table and plugin.json, ARE
# working-tree files and a concurrent writer could touch them. The difference
# from 1nz is that nothing in a normal session writes either one, and a session
# that DID write one has changed which release ships or what that release
# contains — so a red here is the signal, not interference.
#
# SCOPED TO THE CURRENT RELEASE ONLY, deliberately. The same comparison for
# v3.5.0 already runs one tier up, at .claude/tests/component/specs/
# installer-v3-upgrade.sh section 2 ("byte-identical to the regenerated tag
# manifest"), so a copy here would be a second maintenance point for one claim.
# Measured 2026-08-07 for the record, since it is worth knowing and is not
# asserted here: the v3.5.0 tree under the CURRENT generator still reproduces
# manifests/v3.5.0.sha256 exactly, 117 rows.
#
# WHAT IS DELIBERATELY ABSENT: a HEAD-vs-frozen check. plugin.json carries the
# shipping release's version for the entire development period after that
# release, so such a check would be red every day between two releases. A check
# that can never go green gets muted, then deleted, and takes the checks around
# it with it.

SECTION6_SKIP=""
SECTION6_HINT=""
if [ -z "$RELEASE_VERSION" ]; then
    SECTION6_SKIP="could not read .version from .claude-plugin/plugin.json (jq absent, or the manifest moved)"
elif [ ! -f "$RELEASE_TABLE" ]; then
    SECTION6_SKIP="plugin.json declares $RELEASE_VERSION but manifests/$RELEASE_TAG.sha256 has not been frozen yet"
elif ! git -C "$PROJECT_DIR" rev-parse -q --verify "$RELEASE_TAG^{commit}" >/dev/null 2>&1; then
    SECTION6_SKIP="the $RELEASE_TAG tag is not reachable here (shallow clone, tagless worktree, not a git checkout at all, or that release is not tagged yet)"
    # Only this branch is the one CI can regress into, so only this branch says
    # so. Printing the fetch-depth hint on the table-absent branch too would
    # send the next reader after a checkout setting that was never the cause.
    SECTION6_HINT="the CI l1-unit job checks out with fetch-depth: 0 precisely so this tag IS present; a skip in CI means that was reverted"
fi

if [ -n "$SECTION6_SKIP" ]; then
    # MOVES NEITHER PASS NOR FAIL on purpose — but it is NOT invisible, and the
    # text here used to say it was ("run-tests.sh has no SKIP verb, it reads a
    # spec's exit code and nothing else"). Both clauses died with
    # claude-workflow-plugin-a9hh. run-tests.sh now: (1) has a SKIP verb —
    # exit-0-with-zero-assertions is a third outcome that fails the tier; and
    # (2) reads the executed-assertion count, not the exit code alone. Since
    # a9hh R1-F1 it also reads THIS line: a `note: ... SKIPPED` on a spec that
    # otherwise passed makes the spec PARTIAL, names it under the completeness
    # line, and — under STRICT_SECTIONS=1, which the CI l1-unit job sets —
    # fails the tier. That is deliberate here: CI checks out with fetch-depth:
    # 0 precisely so the tag IS reachable, so this note firing in CI means the
    # checkout config regressed, which is worth a red.
    #
    # The house idiom for "this leg had no inputs to measure" is still a bare
    # note (workflow-doctor.test.sh 5a, META 3, META 4, META 5) — it is just no
    # longer a note that nothing can see. Consequence, stated because it
    # surprises anyone diffing two runs: the assertion total for this spec is
    # NOT a constant — it drops by this whole section when the note fires. That
    # is stated WITHOUT a literal count on purpose. A hardcoded one was written
    # here first, said "seven" against a section of eight, and was caught only
    # by running the skip path; the next assertion added below would have
    # rotted it again.
    printf '  note: 6 SKIPPED - %s.\n' "$SECTION6_SKIP"
    printf '        There is nothing to compare, so this is neither a pass nor a\n'
    printf '        failure. The comparator itself is still proven sensitive by\n'
    printf '        META 4 below, which needs only the frozen table.\n'
    if [ -n "$SECTION6_HINT" ]; then
        printf '        Note also: %s.\n' "$SECTION6_HINT"
    fi
else
    TAGTREE="$WORK/release-tag-tree"
    mkdir -p "$TAGTREE"
    # pipefail inside the subshell: without it a failing `git archive` is masked
    # by tar exiting 0 on an empty stream, and the section would go on to
    # compare a 132-row table against a 0-row manifest and blame the generator.
    ARCHIVE_RC=0
    ( set -o pipefail; git -C "$PROJECT_DIR" archive "$RELEASE_TAG" | tar -x -C "$TAGTREE" ) \
        || ARCHIVE_RC=$?
    assert_eq "release $RELEASE_TAG: git archive extracts the tag tree cleanly" \
        "0" "$ARCHIVE_RC"
    assert_eq "release $RELEASE_TAG: the extracted tree carries .claude-plugin/plugin.json" \
        "yes" "$([ -f "$TAGTREE/.claude-plugin/plugin.json" ] && echo yes || echo no)"

    REGEN="$WORK/release-tag-manifest.tsv"
    GEN_RC=0
    # stderr to a FILE, not /dev/null: generate dies loudly on an unreadable
    # file or a missing hash tool, and that message is the whole diagnosis when
    # this fails. Discarding it would leave a bare "exit 1" to explain.
    bash "$SCRIPT" generate "$TAGTREE" > "$REGEN" 2>"$WORK/release-tag-generate.err" \
        || GEN_RC=$?
    if [ "$GEN_RC" -ne 0 ]; then
        printf '  diagnostic: generate over the %s tree exited %s; stderr:\n' "$RELEASE_TAG" "$GEN_RC"
        sed 's/^/    /' "$WORK/release-tag-generate.err" 2>/dev/null | head -10
    fi
    assert_eq "release $RELEASE_TAG: generate over the tag tree exits 0" "0" "$GEN_RC"

    # Non-vacuity before the claim: two empty files are byte-identical, so an
    # empty regeneration compared against an empty table would "pass" and prove
    # nothing at all.
    REGEN_ROWS=$(wc -l < "$REGEN" 2>/dev/null | tr -d ' ')
    TABLE_ROWS=$(wc -l < "$RELEASE_TABLE" 2>/dev/null | tr -d ' ')
    assert_eq "release $RELEASE_TAG: the regeneration produced rows (not an empty-vs-empty match)" \
        "yes" "$([ "${REGEN_ROWS:-0}" -gt 0 ] && echo yes || echo no)"
    assert_eq "release $RELEASE_TAG: regenerated row count equals the frozen table's" \
        "$TABLE_ROWS" "$REGEN_ROWS"

    # THE CLAIM.
    REGEN_MATCH=$(tables_match "$REGEN" "$RELEASE_TABLE" && echo 0 || echo $?)
    if [ "$REGEN_MATCH" != "0" ]; then
        printf '  diagnostic: first differing rows (regenerated from %s vs frozen):\n' "$RELEASE_TAG"
        diff "$REGEN" "$RELEASE_TABLE" 2>/dev/null | head -10 | sed 's/^/    /'
    fi
    assert_eq "release $RELEASE_TAG: manifests/$RELEASE_TAG.sha256 is byte-identical to the regenerated tag manifest" \
        "0" "$REGEN_MATCH"

    # WHICH SIDE MOVED. When the claim above fails these two say whether the
    # table was edited after the tag or the generator changed under it, which is
    # the first question anyone hitting that red will ask. They are not
    # redundant: a table re-frozen against an unchanged tag to match a CHANGED
    # generator satisfies the claim above and fails here — and that shape
    # matters, because an operator installing from the tag and one installing
    # from the branch would then classify against two different tables.
    TAGCOPY="$WORK/release-table-at-tag.sha256"
    SHOW_RC=0
    git -C "$PROJECT_DIR" show "$RELEASE_TAG:manifests/$RELEASE_TAG.sha256" \
        > "$TAGCOPY" 2>/dev/null || SHOW_RC=$?
    assert_eq "release $RELEASE_TAG: the tag tree carries the table it is named for" \
        "0" "$SHOW_RC"
    assert_eq "release $RELEASE_TAG: and the committed copy is unedited since the tag" \
        "0" "$(tables_match "$TAGCOPY" "$RELEASE_TABLE" && echo 0 || echo $?)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: META-TESTs (each check above can actually fail) ==="

# META 1 — corrupt a hash in a COPY of the frozen table. If the format check
# cannot see a 40-char hash where 64 belongs, Section 5 is decoration.
if [ -f "$FROZEN" ]; then
    META_TABLE="$WORK/frozen-truncated.sha256"
    awk -F'\t' -v OFS='\t' 'NR == 1 { $3 = substr($3, 1, 40) } { print }' \
        "$FROZEN" > "$META_TABLE"
    assert_eq "META: the corrupted copy really differs from the frozen table" \
        "1" "$(cmp -s "$META_TABLE" "$FROZEN" && echo 0 || echo 1)"
    assert_eq "META: format check FAILS on a table with a truncated hash" \
        "1" "$(check_table_format "$META_TABLE" && echo 0 || echo $?)"

    # And the same checker on a table whose class token is not in the enum.
    META_CLASS="$WORK/frozen-badclass.sha256"
    awk -F'\t' -v OFS='\t' 'NR == 1 { $2 = "whatever" } { print }' \
        "$FROZEN" > "$META_CLASS"
    assert_eq "META: format check FAILS on an out-of-enum class token" \
        "1" "$(check_table_format "$META_CLASS" && echo 0 || echo $?)"

    # An empty table must not pass vacuously.
    : > "$WORK/frozen-empty.sha256"
    assert_eq "META: format check FAILS on a table with zero rows" \
        "1" "$(check_table_format "$WORK/frozen-empty.sha256" && echo 0 || echo $?)"
fi

# META 2 — sensitivity of generate. Adding an IN-surface file must change the
# output; adding an OUT-of-surface file must not. Without the positive arm,
# "deterministic" would be satisfiable by a generator that emits nothing.
mkfile "$SYN" ".claude/agents/meta-extra-agent.md" "an agent that arrived later"
META_ADDED="$WORK/synthetic-with-extra.tsv"
bash "$SCRIPT" generate "$SYN" > "$META_ADDED"
assert_eq "META: adding an in-surface file CHANGES the generate output" \
    "1" "$(cmp -s "$META_ADDED" "$SYN_TSV" && echo 0 || echo 1)"
assert_eq "META: the added agent is the thing that appeared" \
    "1" "$(row_count "$META_ADDED" ".claude/agents/meta-extra-agent.md")"
rm -f "$SYN/.claude/agents/meta-extra-agent.md"

mkfile "$SYN" ".claude/scripts/tests/meta-extra.test.sh" "#!/bin/bash"
META_IGNORED="$WORK/synthetic-with-excluded.tsv"
bash "$SCRIPT" generate "$SYN" > "$META_IGNORED"
assert_eq "META: adding an out-of-surface file leaves the output unchanged" \
    "0" "$(cmp -s "$META_IGNORED" "$SYN_TSV" && echo 0 || echo 1)"
rm -f "$SYN/.claude/scripts/tests/meta-extra.test.sh"

# META 2b — the same sensitivity probe for the docs subset specifically (v4.1 /
# U0.8), because docs/ is the one directory where "in the surface" and "in the
# directory" come apart. A new .md dropped into docs/ must NOT change the
# output; EDITING one of the two named files must. Without the second arm the
# subset rule would be satisfiable by a generator that had stopped hashing docs
# at all, and without the first the rule would be satisfiable by a directory
# scan — the exact thing the named list exists to prevent.
mkfile "$SYN" "docs/META_NEW_DOC.md" "a doc that arrived later and is not shipped"
META_DOCS_ADDED="$WORK/synthetic-docs-added.tsv"
bash "$SCRIPT" generate "$SYN" > "$META_DOCS_ADDED"
assert_eq "META: a NEW file in docs/ leaves the output unchanged (subset, not a scan)" \
    "0" "$(cmp -s "$META_DOCS_ADDED" "$SYN_TSV" && echo 0 || echo 1)"
rm -f "$SYN/docs/META_NEW_DOC.md"

printf 'META edit\n' >> "$SYN/docs/HOOKS.md"
META_DOCS_EDITED="$WORK/synthetic-docs-edited.tsv"
bash "$SCRIPT" generate "$SYN" > "$META_DOCS_EDITED"
assert_eq "META: EDITING docs/HOOKS.md DOES change the output (the row is really hashed)" \
    "1" "$(cmp -s "$META_DOCS_EDITED" "$SYN_TSV" && echo 0 || echo 1)"
# Confinement stated as "every changed line is the HOOKS.md row" rather than as
# a fixed count: a one-row hash change is a `NcN` hunk, so diff emits BOTH a `<`
# and a `>` line for it, and hardcoding 2 would silently start passing if a
# second row ever joined the hunk.
META_DOCS_CHANGED_LINES=$(diff "$META_DOCS_EDITED" "$SYN_TSV" 2>/dev/null | grep -c '^[<>]' | tr -d ' \n')
META_DOCS_CHANGED_HOOKS=$(diff "$META_DOCS_EDITED" "$SYN_TSV" 2>/dev/null | grep -c '^[<>].*docs/HOOKS\.md' | tr -d ' \n')
assert_eq "META: ...and EVERY changed line is the docs/HOOKS.md row (nothing else moved)" \
    "$META_DOCS_CHANGED_LINES" "$META_DOCS_CHANGED_HOOKS"
assert_eq "META: ...on a diff that really has changed lines (not a vacuous 0 == 0)" "yes" \
    "$([ "${META_DOCS_CHANGED_LINES:-0}" -ge 2 ] && echo yes || echo no)"
mkfile "$SYN" "docs/HOOKS.md" "synthetic hooks reference"
assert_eq "META: restoring the file restores byte-identical output" \
    "0" "$(bash "$SCRIPT" generate "$SYN" | cmp -s - "$SYN_TSV" && echo 0 || echo 1)"

# META 3 — the operator branch in classify is load-bearing. Strip the
# sentinel-delimited block from a COPY and the operator fixture that differs
# from BOTH source and stock must stop yielding preserve-custom. If it still
# yielded it, the "never clobber operator customizations" guarantee would be
# coming from somewhere unverified.
STRIPPED="$WORK/workflow-manifest-stripped.sh"
sed '/# CUSTOM-VERDICT-START/,/# CUSTOM-VERDICT-END/d' "$SCRIPT" > "$STRIPPED"

SCRIPT_LINES=$(wc -l < "$SCRIPT" | tr -d ' ')
STRIPPED_LINES=$(wc -l < "$STRIPPED" | tr -d ' ')
assert_eq "META: the strip removed the sentinel block (fewer lines)" "1" \
    "$([ "$STRIPPED_LINES" -lt "$SCRIPT_LINES" ] && echo 1 || echo 0)"
assert_eq "META: the stripped copy is still syntactically valid bash" "0" \
    "$(bash -n "$STRIPPED" 2>/dev/null && echo 0 || echo 1)"

STRIPPED_TSV="$WORK/classify/plan-stripped.tsv"
bash "$STRIPPED" classify --target "$TGT_TREE" --source "$SRC_TREE" \
    --old-table "$OLD_TABLE" > "$STRIPPED_TSV" 2>/dev/null && RC=0 || RC=$?
assert_eq "META: the stripped copy still runs classify" "0" "$RC"

STRIPPED_VERDICT=$(field_of "$STRIPPED_TSV" ".claude/rubrics/default.md" 3)
assert_eq "META: without the sentinel block the operator file is NOT preserve-custom" \
    "no" "$([ "$STRIPPED_VERDICT" = "preserve-custom" ] && echo yes || echo no)"
assert_eq "META: it falls through to the workflow default instead" \
    "replace-custom" "$STRIPPED_VERDICT"
# The other five verdicts are unaffected — the strip is surgical, so a
# failure above really is about the operator branch and not collateral damage.
assert_eq "META: the stripped copy still reports replace-stock correctly" \
    "replace-stock" "$(field_of "$STRIPPED_TSV" ".claude/agents/backend.md" 3)"

# META 4 — Section 6's comparator (claude-workflow-plugin-ce5). Mutate ONE hash
# in a COPY of the frozen release table and prove tables_match flags it.
#
# ONE hash, and one BYTE of it, because that is the real failure: the defect
# this section was filed for moved exactly one row (LESSONS.md), and a
# comparator that only noticed wholesale corruption would have called that
# table clean. The mutant stays valid 64-lowercase-hex, so it still passes
# check_table_format — which is the point of running both checkers: Section 5
# CANNOT see this and Section 6 must.
#
# Runs whenever the table exists, INDEPENDENT of the tag, so the comparator's
# sensitivity is proven even on a checkout where Section 6 itself skipped.
if [ -f "$RELEASE_TABLE" ]; then
    META_RELEASE="$WORK/release-table-onehash.sha256"
    awk -F'\t' -v OFS='\t' '
        NR == 1 {
            last = substr($3, 64, 1)
            $3 = substr($3, 1, 63) ((last == "0") ? "1" : "0")
        }
        { print }
    ' "$RELEASE_TABLE" > "$META_RELEASE"

    assert_eq "META: the one-hash mutant really differs from the frozen release table" \
        "1" "$(cmp -s "$META_RELEASE" "$RELEASE_TABLE" && echo 0 || echo 1)"
    assert_eq "META: the mutant is STILL format-valid (so only a byte comparison can catch it)" \
        "0" "$(check_table_format "$META_RELEASE" && echo 0 || echo $?)"
    assert_eq "META: Section 6's comparator FAILS on a table with one changed hash" \
        "1" "$(tables_match "$META_RELEASE" "$RELEASE_TABLE" && echo 0 || echo $?)"
    # Confinement: exactly the mutated row moved. A one-row change is an NcN
    # hunk, so diff emits both a `<` and a `>` line for it and 2 is the whole
    # difference — anything more means the awk edited more than it claimed.
    META_REL_LINES=$(diff "$META_RELEASE" "$RELEASE_TABLE" 2>/dev/null | grep -c '^[<>]' | tr -d ' \n')
    assert_eq "META: ...and the mutation is the ONLY thing that moved" "2" "$META_REL_LINES"

    # Positive control: the same comparator on an unmutated copy must PASS, or
    # the red above would be a comparator stuck at fail rather than a detection.
    META_RELEASE_COPY="$WORK/release-table-copy.sha256"
    cp "$RELEASE_TABLE" "$META_RELEASE_COPY"
    assert_eq "META: ...while an UNmutated copy still matches (not stuck at fail)" \
        "0" "$(tables_match "$META_RELEASE_COPY" "$RELEASE_TABLE" && echo 0 || echo $?)"
    # Missing input is 2, never 0. A comparator that reported a match for a file
    # that is not there would make Section 6 pass on a checkout with no table.
    assert_eq "META: ...and a MISSING table reports 2, never a match" \
        "2" "$(tables_match "$WORK/definitely-not-a-table.sha256" "$RELEASE_TABLE" && echo 0 || echo $?)"
else
    printf '  note: META 4 SKIPPED - manifests/%s.sha256 is not in this checkout,\n' "$RELEASE_TAG"
    printf '        so there is no frozen table to mutate. Moves neither counter.\n'
fi

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

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
#   against it via workflow-manifest.sh's cmd_classify() — the function
#   behind its `classify` subcommand. What a stale table does to any ONE
#   verdict is that function's own contract, not this comment's to restate:
#   an earlier version of this sentence was already rewritten once after
#   being found false (claude-workflow-plugin-h2zz R5-F4), and the rewrite
#   was itself found false in a new way (round 7) — the same
#   defect-survives-repeated-rounds-against-one-mechanism shape as the
#   round-4 waiver ruling below — so the description is deleted here rather
#   than attempted again. Read cmd_classify() directly, or see Section 4
#   below, which exercises all six verdicts against a fixture and is this
#   file's own tested, honest reference. This used to be pinned HERE, for
#   the CURRENT release, by
#   regenerating from `git archive <tag>` rather than the working tree
#   (formerly Section 6). claude-workflow-plugin-h2zz waiver ruling (round 4):
#   that check needs the release tag reachable, which cannot hold on a
#   pre-release ref by definition, and five independent-review rounds of
#   trying to exempt L1 from that fact narrowly enough failed six times over
#   (see run-tests.sh's PRE-RELEASE-REF EXEMPTION: REMOVED tombstone for the
#   full account). The check itself is not gone — it moved to
#   .claude/scripts/verify-release-manifest.sh (`make verify-release`,
#   pre-push, and .github/workflows/release-verify.yml, tag-triggered,
#   post-push), which implements its own inline `cmp -s` comparator and
#   does NOT call tables_match (below) at all — tables_match is retained
#   here purely as TEST-LOCAL coverage, proven sensitive by META 4 in
#   Section 7, which drives it against $RELEASE_TABLE (manifests/<the
#   CURRENT plugin.json version>.sha256, e.g. v5.0.0 today) — not the older
#   manifests/v3.5.0.sha256 that Section 5 uses for its format checks. META 4
#   stays tag-independent because it reads that table as a plain file out of
#   the checked-out working tree, never through `git archive <tag>` or any
#   other tag lookup, so it never depends on whether the tag exists or is
#   reachable.
#
# ASSERTION ANCHORING: every check below is anchored to TEXT (a path, a class
# token, a verdict token, a row grammar) and never to a line number — the
# brittleness LESSONS.md (2026-06-13) records after three re-anchorings.
#
# SECTIONS
#   1. Synthetic-source surface: a tiny fixture tree proves both what IS
#      enumerated (with the right class) and what is EXCLUDED.
#   1g. The governing-artifact query (claude-workflow-plugin-s5qf): the same
#      enumeration re-served without hashes, plus the named runtime-contract
#      files, for F1's doc-only classifier — and the negative control that it
#      did NOT widen the install surface it borrows.
#   2. Determinism: two consecutive generate runs are byte-identical.
#   3. Real-repo sanity: named assets present, operator memory and the
#      plugin's own L1 suite absent.
#   4. Classify decision table: all six verdicts, one assertion each.
#   4d. The shipped-docs subset (v4.1 / U0.8): the four verdicts its
#      asymmetric old-table membership makes reachable.
#   5. Frozen-table FORMAT: manifests/v3.5.0.sha256 row grammar, sort order,
#      v3.5 sentinels present, v4 markers absent, and the U0.8 refreeze
#      (docs/HOOKS.md in, docs/CODEX_SETUP.md out) from both sides.
#   6. REMOVED (claude-workflow-plugin-h2zz waiver ruling, round 4) — used to
#      regenerate the CURRENT release's frozen table from its own tag and
#      byte-compare here; that assertion cannot hold on a pre-release ref by
#      definition, and six independent-review findings across four rounds of
#      trying to exempt it narrowly enough is this project's own trigger for
#      "remove the mechanism rather than guard it again" (see run-tests.sh's
#      PRE-RELEASE-REF EXEMPTION: REMOVED tombstone). Moved to
#      .claude/scripts/verify-release-manifest.sh (`make verify-release`,
#      pre-push) and .github/workflows/release-verify.yml (tag-triggered,
#      post-push). The comparator it drove (tables_match) and the mutation-
#      sensitivity coverage for it are unaffected — see META 4 below.
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

# The CURRENT release, DERIVED rather than hardcoded, so META 4 below (and
# .claude/scripts/verify-release-manifest.sh, which reads the same
# plugin.json independently) follow the version bump instead of needing an
# edit at every release. Formerly also consumed by Section 6 (removed —
# claude-workflow-plugin-h2zz waiver ruling; see that section's own
# tombstone above).
# .claude-plugin/plugin.json is the one version-carrying manifest in this repo
# (HANDOFF.md's v4.1.0 "Verify conditions" section, the "exactly ONE
# version-carrying manifest" assertion), and after a release it keeps naming
# that release for the whole development period that follows — which is
# exactly what makes it the right pointer at "the frozen table that is
# currently shipping".
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
# Section 6's whole claim used to run through here, back when Section 6
# existed (R5-F4, claude-workflow-plugin-h2zz round 5: this comment
# previously said "runs through here" in the present tense, after Section 6
# had already been removed). Today META 4 below is the ONLY caller, and it
# drives the same BYTE-IDENTICAL logic against a deliberately mutated copy —
# the same reason check_table_format above takes a file rather than reaching
# for $FROZEN. Retained purely as TEST-LOCAL coverage: the shipped release
# gate (.claude/scripts/verify-release-manifest.sh) does NOT call this
# helper — it has its own inline `cmp -s` comparator, independently covered
# by verify-release-manifest.test.sh.
#
# The missing-input arm is 2 rather than 1 on purpose, and META 4 pins it: a
# comparator that returned "match" for a file that is not there would have
# let Section 6 pass, back when Section 6 existed, on a checkout carrying no
# table at all — the one result nobody would look at twice, and the same
# invariant META 4 still enforces on its own behalf today.
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
echo "=== Section 1g: the governing-artifact query (claude-workflow-plugin-s5qf) ==="
#
# `governing` is what verify-before-stop.sh's F1 fast path asks instead of
# guessing whether a `.md` is documentation or is the system. Two properties
# carry the whole design and both are silent-rot candidates:
#
#   IT IS THE SAME ENUMERATION. If `governing` ever answered from a list of its
#   own, the fix would have minted the second vocabulary it exists to avoid —
#   and that list would drift from the surface exactly the way install.sh's
#   hardcoded agent list drifted from the shipped agents (LESSONS.md,
#   2026-06-12). So the superset relation below is asserted PATH BY PATH
#   against `generate`, not spot-checked.
#
#   IT IS NOT AN INSTALL SURFACE. CLAUDE.md is in the governing set and must
#   never reach a manifest row: it is never-touched operator memory, the
#   installer does not seed it, and an uninstall walk that enumerated it would
#   offer to move an operator's own project memory out of their project. The
#   negative control for that is asserted on `generate`, from both sides.

GOV_TSV="$WORK/synthetic-governing.tsv"
bash "$SCRIPT" governing "$SYN" > "$GOV_TSV" 2>"$WORK/governing.err" && RC=0 || RC=$?
assert_eq "governing on the synthetic tree exits 0" "0" "$RC"
assert_eq "governing on the synthetic tree writes nothing to stderr" \
    "" "$(cat "$WORK/governing.err")"

# Usage errors are exit 2, same contract as generate.
bash "$SCRIPT" governing >/dev/null 2>&1 && RC=0 || RC=$?
assert_eq "governing without <source-root> is a usage error (exit 2)" "2" "$RC"
bash "$SCRIPT" governing "$WORK/definitely-not-here" >/dev/null 2>&1 && RC=0 || RC=$?
assert_eq "governing with a nonexistent source root is a usage error (exit 2)" "2" "$RC"

# ROW GRAMMAR: <path><TAB><origin>, TWO fields. The consumer looks the path up
# by EXACT equality on field 1 and reads field 2 as the origin, so a third
# column would silently break every lookup — which is why the hashed/no-hash
# switch has a leg of its own rather than being trusted.
GOV_ROW_RE="^[^${TAB}]+${TAB}(workflow|operator|merged|runtime-contract)$"
assert_eq "governing rows are <path>TAB<origin> and nothing else" "0" \
    "$(grep -vE "$GOV_ROW_RE" "$GOV_TSV" | grep -c . | tr -d '[:space:]')"
assert_eq "governing rows carry exactly 2 tab-separated fields (no hash column)" "0" \
    "$(awk -F'\t' 'NF != 2' "$GOV_TSV" | grep -c . | tr -d '[:space:]')"
assert_eq "governing output is in LC_ALL=C sort order" "0" \
    "$(LC_ALL=C sort "$GOV_TSV" | cmp -s - "$GOV_TSV" && echo 0 || echo 1)"

# SUPERSET, path by path. Every shipped-surface path is a governing path, with
# its manifest class carried through unchanged as the origin.
cut -f1 "$SYN_TSV" | LC_ALL=C sort > "$WORK/gen-paths.txt"
cut -f1 "$GOV_TSV" | LC_ALL=C sort > "$WORK/gov-paths.txt"
assert_eq "every generate path is also a governing path (no row lost)" "" \
    "$(LC_ALL=C comm -23 "$WORK/gen-paths.txt" "$WORK/gov-paths.txt" | tr '\n' ' ' | sed 's/ *$//')"
MISMATCHED_ORIGIN=0
while IFS=$'\t' read -r gp gc _; do
    [ "$(field_of "$GOV_TSV" "$gp" 2)" = "$gc" ] || MISMATCHED_ORIGIN=$((MISMATCHED_ORIGIN + 1))
done < "$SYN_TSV"
assert_eq "every shipped path's origin IS its manifest class, unchanged" "0" "$MISMATCHED_ORIGIN"

# THE ONE ADDITION, and it is named rather than scanned for.
assert_eq "governing: CLAUDE.md is present with origin runtime-contract" \
    "runtime-contract" "$(field_of "$GOV_TSV" "CLAUDE.md" 2)"
assert_eq "governing: the ONLY runtime-contract row is CLAUDE.md" "1" \
    "$(awk -F'\t' '$2 == "runtime-contract"' "$GOV_TSV" | wc -l | tr -d ' ')"
assert_eq "governing: exactly one row more than generate" \
    "$(( $(wc -l < "$SYN_TSV" | tr -d ' ') + 1 ))" "$(wc -l < "$GOV_TSV" | tr -d ' ')"

# ANTI-OVERREACH. An ordinary operator doc must not become governing just by
# sitting next to one that is. These are the SAME three out-of-surface docs
# Section 1 asserts against `generate`; the query inherits the exclusion
# because it inherits the enumeration, and that inheritance is the claim.
assert_eq "governing: docs/ARCHITECTURE.md (a repo doc that is not shipped) is NOT governing" \
    "0" "$(row_count "$GOV_TSV" "docs/ARCHITECTURE.md")"
assert_eq "governing: docs/al-*.md (a dated AgentLint report) is NOT governing" \
    "0" "$(row_count "$GOV_TSV" "docs/al-2026-01-01-000000-deadbeef.md")"
assert_eq "governing: docs/plans/README.md is NOT governing" \
    "0" "$(row_count "$GOV_TSV" "docs/plans/README.md")"
assert_eq "governing: .claude/settings.local.json (per-machine) is NOT governing" \
    "0" "$(row_count "$GOV_TSV" ".claude/settings.local.json")"
assert_eq "governing: .claude/scripts/tests/ never appears" \
    "0" "$(prefix_count "$GOV_TSV" ".claude/scripts/tests/")"
# THE RESIDUAL THIS PINNED IS CLOSED (claude-workflow-plugin-fkm.3 / v5 D1).
# The leg read "docs/specs/<task-id>.md is NOT governing yet", asserted rather
# than merely written down so that D1 closing it would be a LOUD test change and
# not a silent behaviour drift. This is that change.
#
# The design artifact is declared in runtime_contract_rows beside CLAUDE.md, with
# its OWN origin token, because the two declarations are different in kind:
# CLAUDE.md is one named file, and the artifact is named for the task it designs,
# so only the directory can be declared. Everything else about the mechanism is
# unchanged — still outside generate_rows, so still no install row, no upgrade
# verdict and no uninstall walk (the two controls below re-assert exactly that).
mkfile "$SYN" "docs/specs/claude-workflow-plugin-abc.md" "# a design record"
mkfile "$SYN" "docs/specs/claude-workflow-plugin-def.md" "# another design record"
# ANTI-OVERREACH, seeded in the same tree so the two answers are measured
# together: a SIBLING directory under docs/ that the project declares nothing
# about must stay out. This is the leg that distinguishes "a declared directory"
# from "anything under docs/", i.e. from the path-shape inference bbh removed.
mkfile "$SYN" "docs/design-notes/idea.md" "# an operator note"
bash "$SCRIPT" governing "$SYN" > "$WORK/governing-with-spec.tsv"
assert_eq "governing: docs/specs/<task-id>.md IS governing (fkm.3/D1 closed the residual)" \
    "1" "$(row_count "$WORK/governing-with-spec.tsv" "docs/specs/claude-workflow-plugin-abc.md")"
assert_eq "governing: ...with origin design-artifact, not runtime-contract" \
    "design-artifact" "$(field_of "$WORK/governing-with-spec.tsv" "docs/specs/claude-workflow-plugin-abc.md" 2)"
assert_eq "governing: the declaration is the DIRECTORY, so a second artifact needs no edit" \
    "1" "$(row_count "$WORK/governing-with-spec.tsv" "docs/specs/claude-workflow-plugin-def.md")"
assert_eq "governing: exactly 2 design-artifact rows, i.e. the scan is bounded to that directory" \
    "2" "$(awk -F'\t' '$2 == "design-artifact"' "$WORK/governing-with-spec.tsv" | wc -l | tr -d ' ')"
assert_eq "governing anti-overreach: docs/design-notes/idea.md is NOT governing" \
    "0" "$(row_count "$WORK/governing-with-spec.tsv" "docs/design-notes/idea.md")"
assert_eq "governing: docs/ARCHITECTURE.md is STILL not governing with docs/specs declared" \
    "0" "$(row_count "$WORK/governing-with-spec.tsv" "docs/ARCHITECTURE.md")"

# THE DECLARATION ENUMERATES DIRECTORY ENTRIES, NOT REGULAR FILES (fkm.3 QA
# round 2, R2-F2). `scan_flat`'s `find -maxdepth 1 -type f` EXCLUDES symlinks,
# and that was measured against the shipped scan before this: a symlinked
# artifact produced NO row, so the F1 doc-only fast path reopened for the one
# document the design phase exists to review — a change set of exactly that path
# auto-approved with reviewed_by=none. A dangling link is declared for the same
# reason an absent target is not evidence: the declaration is about the PATH.
mkdir -p "$SYN/outside"
printf '# a design record reached through a link\n' > "$SYN/outside/linked-design.md"
ln -sfn "../../outside/linked-design.md" "$SYN/docs/specs/claude-workflow-plugin-lnk.md"
ln -sfn "../../outside/gone.md"          "$SYN/docs/specs/claude-workflow-plugin-dead.md"
# ANTI-OVERREACH partner, in the same tree so both answers are measured together.
ln -sfn "../../outside/linked-design.md" "$SYN/docs/design-notes/linked-idea.md"
bash "$SCRIPT" governing "$SYN" > "$WORK/governing-with-links.tsv"
assert_eq "governing: a SYMLINKED artifact in the declared dir IS declared (R2-F2)" \
    "1" "$(row_count "$WORK/governing-with-links.tsv" "docs/specs/claude-workflow-plugin-lnk.md")"
assert_eq "governing: ...with the same design-artifact origin a regular file gets" \
    "design-artifact" "$(field_of "$WORK/governing-with-links.tsv" "docs/specs/claude-workflow-plugin-lnk.md" 2)"
assert_eq "governing: a DANGLING link is declared too (an absent target is not evidence)" \
    "1" "$(row_count "$WORK/governing-with-links.tsv" "docs/specs/claude-workflow-plugin-dead.md")"
assert_eq "governing: ...and its row is still <path>TAB<origin>, two fields" \
    "0" "$(awk -F'\t' '$1 == "docs/specs/claude-workflow-plugin-dead.md" && NF != 2' "$WORK/governing-with-links.tsv" | grep -c . | tr -d '[:space:]')"
assert_eq "governing: the two regular artifacts are still there (the scan did not swap one set for another)" \
    "2" "$(awk -F'\t' '$1 == "docs/specs/claude-workflow-plugin-abc.md" || $1 == "docs/specs/claude-workflow-plugin-def.md"' "$WORK/governing-with-links.tsv" | wc -l | tr -d ' ')"
assert_eq "governing anti-overreach: an identical symlink in the UNDECLARED sibling dir is NOT governing" \
    "0" "$(row_count "$WORK/governing-with-links.tsv" "docs/design-notes/linked-idea.md")"
# AND THE SHIPPED SURFACE IS UNTOUCHED. scan_flat still skips symlinks, which is
# what keeps every frozen table under manifests/ reproducible — install.sh copies
# files, not links, so a link in .claude/agents/ is not a shipped artifact.
ln -sfn "qa.md" "$SYN/.claude/agents/linked-agent.md"
bash "$SCRIPT" generate "$SYN" > "$WORK/generate-with-links.tsv"
assert_eq "control: a symlink in .claude/agents/ does NOT enter the shipped surface" \
    "0" "$(row_count "$WORK/generate-with-links.tsv" ".claude/agents/linked-agent.md")"
assert_eq "control: ...so generate is byte-identical to the run before any link existed" \
    "0" "$(cmp -s "$WORK/generate-with-links.tsv" "$SYN_TSV" && echo 0 || echo 1)"
assert_eq "control: ...and governing does not declare it either (it is not in the declared dir)" \
    "0" "$(row_count "$WORK/governing-with-links.tsv" ".claude/agents/linked-agent.md")"
# THE HASH-COLUMN GUARD. The dangling branch has no digest to emit. If a future
# caller turned hashing on it would put a two-field row into a three-field table
# and the consumer's field-2 origin read would silently start reading a hash, so
# the scan DIES instead — the same "no sentinel, ever" rule hash_file follows.
META_DECL_HASHED="$WORK/workflow-manifest-declared-hashed.sh"
# shellcheck disable=SC2016  # rewriting the LITERAL text of that line, not expanding it.
sed 's#^    ( cd "$root" \&\& MANIFEST_EMIT_HASH=0 governing_rows ) > "$raw"$#    ( cd "$root" \&\& require_hash_tool \&\& MANIFEST_EMIT_HASH=1 governing_rows ) > "$raw"#' \
    "$SCRIPT" > "$META_DECL_HASHED"
assert_eq "META: the hashed-declaration mutation APPLIED (copy differs)" "1" \
    "$(cmp -s "$META_DECL_HASHED" "$SCRIPT" && echo 0 || echo 1)"
bash "$META_DECL_HASHED" governing "$SYN" > "$WORK/governing-declared-hashed.tsv" 2>"$WORK/declared-hashed.err" && RC=0 || RC=$?
assert_eq "META: with hashing on, a DANGLING declared link REFUSES rather than emitting a short row" \
    "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_eq "META: ...naming the condition rather than dying obscurely" "1" \
    "$(grep -c 'declared but has no hashable content' "$WORK/declared-hashed.err" | tr -d '[:space:]')"
assert_eq "META: ...and no two-field row reached the output" "0" \
    "$(awk -F'\t' 'NF == 2' "$WORK/governing-declared-hashed.tsv" 2>/dev/null | grep -c . | tr -d '[:space:]')"
# RESTORE CONTROL: the shipped copy, same tree with the same dangling link.
assert_eq "META: restore control — the SHIPPED (hashless) copy declares it and exits 0" \
    "1" "$(row_count "$WORK/governing-with-links.tsv" "docs/specs/claude-workflow-plugin-dead.md")"
rm -f "$SYN/.claude/agents/linked-agent.md"
# AND IT STILL NEVER REACHES THE INSTALL SURFACE — the same both-directions
# control the CLAUDE.md row gets, run against a tree that HAS artifacts in it.
bash "$SCRIPT" generate "$SYN" > "$WORK/generate-with-spec.tsv"
assert_eq "control: generate emits no docs/specs row" "0" \
    "$(prefix_count "$WORK/generate-with-spec.tsv" "docs/specs/")"
assert_eq "control: generate emits no design-artifact class token" "0" \
    "$(awk -F'\t' '$2 == "design-artifact"' "$WORK/generate-with-spec.tsv" | wc -l | tr -d ' ')"
assert_eq "control: generate output is byte-unchanged by the artifacts' existence" \
    "0" "$(cmp -s "$WORK/generate-with-spec.tsv" "$SYN_TSV" && echo 0 || echo 1)"

# --- THE DECLARED DIRECTORY ITSELF (fkm.3 QA round 4, R4-F2 + R4-F3) -------
# The round-2 scan fixed what the declared directory CONTAINS. Round 3 found two
# ways the DIRECTORY defeats the scan, and both end in the same place: a
# `governing` run that exits 0 with no design-artifact row, which the consumer
# reads as "nothing is declared" and hands the doc-only fast path.
#
#   R4-F3  the declared path is itself a directory SYMLINK. `find` will not
#          descend a final symlink operand without -H/-L — measured identical on
#          BSD find and GNU findutils 4.10.0 — while the `[ -d "$dir" ]` guard
#          above it DOES follow. So the guard passes, the scan is silently empty,
#          and `ls docs/specs/` lists an artifact `governing` never mentions.
#   R4-F2  the directory is searchable but not listable (mode 0311). find's
#          diagnostic went to /dev/null and its STATUS was lost to process
#          substitution, so the scan returned 0 rows at rc 0 while the artifact
#          stayed stat-able, readable and hashable by name.
#
# R4-F2 falsifies an invariant its own consumer documents: load_governing_set
# captures the query's rc precisely because "an empty set from a FAILED run is
# not [legitimate]". The outer layer checks carefully and the inner layer
# returned 0, which defeated it.
#
# Both are driven in HERMETIC roots rather than in $SYN: one of them has to
# restructure docs/specs into a symlink and the other has to make it unreadable,
# and neither should be able to disturb the legs above.
declared_root() {                  # $1 = root, $2 = plain | link
    local root="$1" shape="$2"
    rm -rf "${root:?}"
    mkdir -p "$root/docs"
    if [ "$shape" = "link" ]; then
        mkdir -p "$root/docs/specs-real"
        printf '# a design record\n' > "$root/docs/specs-real/claude-workflow-plugin-dir.md"
        ln -sfn "specs-real" "$root/docs/specs"
    else
        mkdir -p "$root/docs/specs"
        printf '# a design record\n' > "$root/docs/specs/claude-workflow-plugin-dir.md"
    fi
}

# CONTROL FIRST: the same bare root with a REAL directory. Without it, a "1" in
# the symlink leg below could be unreachable in a root this small and the leg
# would be measuring the fixture rather than the scan.
declared_root "$WORK/decl-plain" plain
bash "$SCRIPT" governing "$WORK/decl-plain" > "$WORK/governing-decl-plain.tsv"
assert_eq "governing CONTROL: a plain declared directory in a bare root emits its artifact row" \
    "1" "$(row_count "$WORK/governing-decl-plain.tsv" "docs/specs/claude-workflow-plugin-dir.md")"

declared_root "$WORK/decl-link" link
assert_eq "precondition: the declared path is a directory SYMLINK in this root" "yes" \
    "$([ -L "$WORK/decl-link/docs/specs" ] && echo yes || echo no)"
# A GLOB, not `ls | grep`: this is a readdir THROUGH the symlinked directory,
# which is the claim — the artifact is listable by the declared spelling while
# `governing` says nothing about it.
assert_eq "precondition: ...and the artifact IS listed through it, so the scan has something to find" \
    "1" "$(set -- "$WORK/decl-link/docs/specs"/*.md; [ -e "$1" ] && echo "$#" || echo 0)"
bash "$SCRIPT" governing "$WORK/decl-link" > "$WORK/governing-decl-link.tsv"
assert_eq "governing: a declared directory reached through a SYMLINK is still scanned (R4-F3)" \
    "1" "$(row_count "$WORK/governing-decl-link.tsv" "docs/specs/claude-workflow-plugin-dir.md")"
assert_eq "governing: ...with the same design-artifact origin a real directory's artifact gets" \
    "design-artifact" "$(field_of "$WORK/governing-decl-link.tsv" "docs/specs/claude-workflow-plugin-dir.md" 2)"

# THE ENUMERATION'S STATUS IS THE DECLARATION'S STATUS.
LOCK_ROOT="$WORK/decl-locked"
declared_root "$LOCK_ROOT" plain
bash "$SCRIPT" governing "$LOCK_ROOT" > "$WORK/governing-decl-unlocked.tsv" 2>/dev/null && UNLOCK_RC=0 || UNLOCK_RC=$?
assert_eq "governing CONTROL: the same root while readable — rc 0 AND the row present" "0/1" \
    "$UNLOCK_RC/$(row_count "$WORK/governing-decl-unlocked.tsv" "docs/specs/claude-workflow-plugin-dir.md")"
chmod 0311 "$LOCK_ROOT/docs/specs" 2>/dev/null || true
# Skipped as root, where 0311 does not deny — asserted, not assumed, for the
# reason the mode-000 leg in design-artifact.test.sh states: a leg that cannot
# fail is worse than an absent one.
if find "$LOCK_ROOT/docs/specs" -maxdepth 1 -name '*.md' -print >/dev/null 2>&1; then
    printf '  SKIP: governing enumeration-failure legs (this user can list a mode-0311 directory; likely root)\n'
else
    assert_eq "precondition: the artifact is STILL readable by name while the directory is unlistable" \
        "1" "$(grep -c 'a design record' "$LOCK_ROOT/docs/specs/claude-workflow-plugin-dir.md" 2>/dev/null | tr -d '[:space:]')"
    bash "$SCRIPT" governing "$LOCK_ROOT" > "$WORK/governing-decl-locked.tsv" 2>"$WORK/decl-locked.err" && LOCK_RC=0 || LOCK_RC=$?
    assert_eq "governing: an ENUMERATION FAILURE is a FAILED query, not an empty one (R4-F2)" "1" \
        "$([ "$LOCK_RC" -ne 0 ] && echo 1 || echo 0)"
    assert_eq "governing: ...and it says so, naming the directory it could not read" "1" \
        "$(grep -c "could not ENUMERATE the declared directory" "$WORK/decl-locked.err" | tr -d '[:space:]')"
    assert_eq "governing: ...carrying find's own diagnostic, which used to go to /dev/null" "1" \
        "$(grep -cE "find said: [^[:space:]]" "$WORK/decl-locked.err" | tr -d '[:space:]')"
    assert_eq "governing: ...and NO row reached stdout, so no partial set can pass for a whole one" "0" \
        "$(grep -c . "$WORK/governing-decl-locked.tsv" 2>/dev/null | tr -d '[:space:]')"
fi
chmod 0755 "$LOCK_ROOT/docs/specs" 2>/dev/null || true
rm -rf "${WORK:?}/decl-plain" "${WORK:?}/decl-link" "${WORK:?}/decl-locked"

rm -rf "${SYN:?}/docs/specs" "${SYN:?}/docs/design-notes" "${SYN:?}/outside"

# NEGATIVE CONTROL, both directions: adding the governing query must not have
# widened the INSTALL surface. Section 1 already asserts CLAUDE.md is excluded
# from generate; this re-asserts it AFTER the query exists, which is the only
# ordering that can catch runtime_contract_rows leaking into generate_rows.
bash "$SCRIPT" generate "$SYN" > "$WORK/generate-recheck.tsv"
assert_eq "control: generate STILL emits no CLAUDE.md row" \
    "0" "$(row_count "$WORK/generate-recheck.tsv" "CLAUDE.md")"
assert_eq "control: generate STILL emits no runtime-contract class token" "0" \
    "$(awk -F'\t' '$2 == "runtime-contract"' "$WORK/generate-recheck.tsv" | wc -l | tr -d ' ')"
assert_eq "control: generate output is unchanged by the query's existence" \
    "0" "$(cmp -s "$WORK/generate-recheck.tsv" "$SYN_TSV" && echo 0 || echo 1)"
assert_eq "control: generate still satisfies the 3-column hashed row grammar" \
    "0" "$(check_table_format "$WORK/generate-recheck.tsv" && echo 0 || echo $?)"

# AN UNDECLARED TREE DECLARES NOTHING. A source root with no plugin surface and
# no CLAUDE.md yields an EMPTY set — which is what makes the consumer's fast
# path unchanged on any install that never declares one. Asserted with a
# discriminator (the seeded tree is non-empty) so "empty" cannot be satisfied
# by a query that always returns nothing.
BARE="$WORK/bare-source"
mkdir -p "$BARE"
mkfile "$BARE" "README.md"        "# just a readme"
mkfile "$BARE" "docs/guide.md"    "# just a guide"
bash "$SCRIPT" governing "$BARE" > "$WORK/governing-bare.tsv" && RC=0 || RC=$?
assert_eq "governing on a tree with no declared surface exits 0" "0" "$RC"
assert_eq "governing on a tree with no declared surface is EMPTY" "0" \
    "$(grep -c . "$WORK/governing-bare.tsv" | tr -d '[:space:]')"
assert_eq "discriminator: the SEEDED tree is not empty (so 'empty' means something)" \
    "yes" "$([ "$(grep -c . "$GOV_TSV")" -gt 0 ] && echo yes || echo no)"
# ...and a tree whose ONLY declaration is CLAUDE.md yields exactly that row.
mkfile "$BARE" "CLAUDE.md" "# operator memory"
bash "$SCRIPT" governing "$BARE" > "$WORK/governing-bare2.tsv"
assert_eq "a tree whose only declaration is CLAUDE.md yields exactly one row" "1" \
    "$(grep -c . "$WORK/governing-bare2.tsv" | tr -d '[:space:]')"
assert_eq "...and that row is CLAUDE.md/runtime-contract" \
    "runtime-contract" "$(field_of "$WORK/governing-bare2.tsv" "CLAUDE.md" 2)"

# NO HASHING HAPPENS, proved by behaviour rather than by reading the switch.
# generate DIES on a file it cannot hash (hash_file exits 1 rather than emit a
# plausible-but-wrong digest); governing never opens the file, so it succeeds.
# The precondition is asserted because chmod 000 does not restrict root, and a
# suite running as root would otherwise pass this pair vacuously (LESSONS.md,
# 2026-07-29).
UNREADABLE="$WORK/unreadable-source"
mkdir -p "$UNREADABLE"
mkfile "$UNREADABLE" ".claude/agents/qa.md" "readable agent"
mkfile "$UNREADABLE" ".claude/agents/locked.md" "unreadable agent"
chmod 000 "$UNREADABLE/.claude/agents/locked.md" 2>/dev/null || true
if [ -r "$UNREADABLE/.claude/agents/locked.md" ]; then
    printf '  note: unreadable-file legs SKIPPED - chmod 000 did not deny this user\n'
    printf '        (running as root?). Moves neither counter.\n'
else
    assert_eq "precondition: the locked file really is unreadable" "no" \
        "$([ -r "$UNREADABLE/.claude/agents/locked.md" ] && echo yes || echo no)"
    bash "$SCRIPT" generate "$UNREADABLE" >/dev/null 2>&1 && RC=0 || RC=$?
    assert_eq "generate FAILS on a file it cannot hash (exit 1, never a fake digest)" "1" "$RC"
    bash "$SCRIPT" governing "$UNREADABLE" > "$WORK/governing-unreadable.tsv" 2>/dev/null && RC=0 || RC=$?
    assert_eq "governing SUCCEEDS on the same tree — it hashes nothing" "0" "$RC"
    assert_eq "...and still enumerates the unreadable path" "workflow" \
        "$(field_of "$WORK/governing-unreadable.tsv" ".claude/agents/locked.md" 2)"
    chmod 644 "$UNREADABLE/.claude/agents/locked.md" 2>/dev/null || true
fi

# DETERMINISM, same contract as generate: downstream compares are byte-level.
bash "$SCRIPT" governing "$SYN" > "$WORK/governing-run2.tsv"
assert_eq "two consecutive governing runs on the same tree are byte-identical" "0" \
    "$(cmp -s "$GOV_TSV" "$WORK/governing-run2.tsv" && echo 0 || echo 1)"

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
    # it). What CODEX_SETUP.md classifies as, for every target shape, is
    # cmd_classify()'s own contract, not this comment's to enumerate
    # (claude-workflow-plugin-h2zz R8-F3: an earlier revision claimed it "can
    # only ever be copy-new or...skip-current", which is false -- a
    # pre-existing target whose bytes differ from the shipped source has no
    # old-table hash to fall back on either, since it was never in the tag, so
    # cmd_classify() falls through to replace-custom, a shape section 4d does
    # not exercise for this path). Read cmd_classify() directly, or section 4d
    # above for the two shapes it does cover here (copy-new, skip-current).
    assert_eq "frozen table: contains docs/HOOKS.md (the v3.5.0 tag shipped it)" \
        "1" "$(row_count "$FROZEN" "docs/HOOKS.md")"
    assert_eq "frozen table: does NOT contain docs/CODEX_SETUP.md (absent from the tag, so omitted)" \
        "0" "$(row_count "$FROZEN" "docs/CODEX_SETUP.md")"
    assert_eq "frozen table: docs/HOOKS.md is class workflow there too" \
        "workflow" "$(field_of "$FROZEN" "docs/HOOKS.md" 2)"
    assert_eq "frozen table: EXACTLY one docs/ row (the tag had no other shipped doc)" \
        "1" "$(prefix_count "$FROZEN" "docs/")"

    # v4-only markers — their presence would mean the table was generated
    # from the wrong tree (e.g. HEAD instead of the tag). What a wrong-tree
    # old table does to any ONE verdict is cmd_classify()'s own contract to
    # read directly, not this comment's to characterise in the aggregate
    # (claude-workflow-plugin-h2zz R8-F4: an earlier revision claimed it
    # would make "every customization verdict wrong" -- false: a missing
    # target is still copy-new and a genuinely customized target still
    # yields replace-custom/preserve-custom regardless of which table is
    # consulted, since neither path's verdict depends on oldhash matching
    # anything; only a target whose bytes coincidentally match an entry in
    # the WRONG table, or fail to match the entry the RIGHT table would have
    # had, is actually at risk -- and no fixture in this file drives that
    # case). The markers are asserted absent below because a correctly-tagged
    # table should not contain them, not because their presence would
    # corrupt every downstream verdict.
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

# --- SECTION 6: REMOVED (claude-workflow-plugin-h2zz waiver ruling, round 4)
# See run-tests.sh's PRE-RELEASE-REF EXEMPTION: REMOVED tombstone and this
# file's own SECTIONS overview and TABLE FIDELITY comments above for the
# full six-finding, four-round account. Section 6b (the exemption's own
# emission-predicate pairing test) is REMOVED WITH IT — there is no longer
# a predicate to drive. The relocated check lives in
# .claude/scripts/verify-release-manifest.sh; META 4 in Section 7 keeps the
# comparator's mutation-sensitivity coverage, unaffected.
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
# claude-workflow-plugin-h2zz R8-F5: an earlier revision asserted "the other
# five verdicts are unaffected" as a blanket claim while re-running only ONE
# of them (replace-stock) below. Read cmd_classify() itself for WHY the strip
# is surgical (the removed block sits inside the innermost else-branch and
# only fires when class == "operator", physically before/outside every other
# branch), rather than trusting this comment's characterisation of it — and,
# since $STRIPPED_TSV already carries a full plan from one classify run, the
# other four are re-asserted directly here instead of merely claimed.
assert_eq "META: the stripped copy still reports replace-stock correctly" \
    "replace-stock" "$(field_of "$STRIPPED_TSV" ".claude/agents/backend.md" 3)"
assert_eq "META: ...merge is still unaffected (settings.json)" \
    "merge" "$(field_of "$STRIPPED_TSV" ".claude/settings.json" 3)"
assert_eq "META: ...copy-new is still unaffected (newagent.md)" \
    "copy-new" "$(field_of "$STRIPPED_TSV" ".claude/agents/newagent.md" 3)"
assert_eq "META: ...skip-current is still unaffected (qa.md)" \
    "skip-current" "$(field_of "$STRIPPED_TSV" ".claude/agents/qa.md" 3)"
assert_eq "META: ...and a NON-operator replace-custom (devops.md, class workflow) is still unaffected -- the removed branch was never reachable for it either way" \
    "replace-custom" "$(field_of "$STRIPPED_TSV" ".claude/agents/devops.md" 3)"

# META 4 — the tables_match comparator (claude-workflow-plugin-ce5). Mutate
# ONE hash in a COPY of the frozen release table and prove tables_match flags
# it. This comparator used to drive the removed Section 6 (claude-workflow-
# plugin-h2zz waiver ruling, round 4 — see that section's own tombstone
# above); it is retained here purely as TEST-LOCAL coverage of the same
# byte-identical-comparison invariant (round 5, R5-F4: it does NOT also
# drive the shipped release gate, despite what an earlier version of this
# comment claimed — .claude/scripts/verify-release-manifest.sh implements
# its own comparators: two separate `cmp -s` call sites, not one — the
# unconditional tag-copy comparison and the final frozen-table
# comparison, named by what each compares rather than by a line number
# (round 6, claude-workflow-plugin-h2zz: this comment used to pin ONE
# line for what was already two call sites, stale the moment the R5-F1
# tag-table block landed above them) — both independently covered by
# verify-release-manifest.test.sh). This leg's coverage is
# unaffected by the removal either way, since it only ever needed the
# frozen table, never the tag.
#
# ONE hash, and one BYTE of it, because that is the real failure: the defect
# this check was filed for moved exactly one row (LESSONS.md), and a
# comparator that only noticed wholesale corruption would have called that
# table clean. The mutant stays valid 64-lowercase-hex, so it still passes
# check_table_format — which is the point of running both checkers: Section 5
# cannot see this, and only a byte-for-byte comparator can.
#
# Runs whenever the table exists, INDEPENDENT of the tag: unlike the removed
# Section 6, this leg never depends on `git archive <tag>` or the tag being
# reachable at all. It CAN still skip, legitimately — the `if
# [ -f "$RELEASE_TABLE" ]` guard immediately below and the "META 4 SKIPPED"
# note in its `else` branch exist for exactly that, not as dead code. The
# one real window is the one this file's own preflight already documents
# (near the top: "every lookup below is allowed to MISS, and a miss is a
# note, never a failure"): between a version bump and the release that
# freezes its table, plugin.json names a release with no table yet, and
# $RELEASE_TABLE is legitimately absent. Forcing that window to be an error
# instead of a skip would mean either failing this whole spec for the
# entire pre-freeze development period on every release, or maintaining a
# second code path just to tell the two cases apart — worse than the skip
# it would replace, for a leg whose only job is extra sensitivity on top of
# Section 5, not a check anything else here depends on.
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
    assert_eq "META: tables_match FAILS on a table with one changed hash" \
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
    # Missing input is 2, never 0: a comparator that reported a match for a
    # file that is not there would have let Section 6 pass, back when
    # Section 6 called this helper, on a checkout with no table at all. The
    # invariant is unchanged by the removal -- META 4 still pins it here.
    assert_eq "META: ...and a MISSING table reports 2, never a match" \
        "2" "$(tables_match "$WORK/definitely-not-a-table.sha256" "$RELEASE_TABLE" && echo 0 || echo $?)"
else
    printf '  note: META 4 SKIPPED - manifests/%s.sha256 is not in this checkout,\n' "$RELEASE_TAG"
    printf '        so there is no frozen table to mutate. Moves neither counter.\n'
fi

# META 5 — the runtime-contract entry is load-bearing (s5qf). Neutralise ONLY
# the body of runtime_contract_rows in a COPY: CLAUDE.md must leave the
# governing set while every shipped-surface row stays. Without this, Section
# 1g's CLAUDE.md leg could be passing because CLAUDE.md sneaked in through some
# scan — which would be the leak the section's negative control exists to
# forbid, passing as the feature.
#
# Anchored on the emit_row TEXT, never a line number (LESSONS.md, 2026-06-13).
META_NORC="$WORK/workflow-manifest-no-runtime-contract.sh"
sed 's#^    emit_row runtime-contract "CLAUDE.md"$#    :#' "$SCRIPT" > "$META_NORC"
assert_eq "META: the runtime-contract neutralisation APPLIED (copy differs)" "1" \
    "$(cmp -s "$META_NORC" "$SCRIPT" && echo 0 || echo 1)"
assert_eq "META: the neutralised copy is still syntactically valid bash" "0" \
    "$(bash -n "$META_NORC" 2>/dev/null && echo 0 || echo 1)"
META_NORC_TSV="$WORK/governing-no-runtime-contract.tsv"
bash "$META_NORC" governing "$SYN" > "$META_NORC_TSV" 2>/dev/null && RC=0 || RC=$?
assert_eq "META: the neutralised copy still runs governing" "0" "$RC"
assert_eq "META: without runtime_contract_rows, CLAUDE.md is NOT governing (1g WOULD fail)" \
    "0" "$(row_count "$META_NORC_TSV" "CLAUDE.md")"
# DISCRIMINATOR: the neutralisation removed exactly one thing. If the shipped
# surface had gone too, the leg above would be measuring a broken script.
assert_eq "META: ...while the shipped surface is untouched (.claude/agents/qa.md still governing)" \
    "workflow" "$(field_of "$META_NORC_TSV" ".claude/agents/qa.md" 2)"
# RESTORE CONTROL: the shipped copy, same tree, same invocation.
bash "$SCRIPT" governing "$SYN" > "$WORK/governing-restore.tsv"
assert_eq "META: restore control — the SHIPPED copy puts CLAUDE.md back" \
    "runtime-contract" "$(field_of "$WORK/governing-restore.tsv" "CLAUDE.md" 2)"

# META 6 — the no-hash switch is load-bearing (s5qf). Force generate_governing
# to hash and the query gains a third column. The consumer
# (verify-before-stop.sh's governing_artifact_origin) reads field 2 as the
# origin and matches field 1 by exact equality, so a three-column answer does
# not error anywhere — it just stops meaning what the reader thinks, which is
# why "2 fields" is asserted rather than assumed.
META_HASHED="$WORK/workflow-manifest-hashed-governing.sh"
# shellcheck disable=SC2016  # matching the LITERAL text `$root` / `$raw` in the
# script under test, not expanding it — the whole point is to rewrite that line.
sed 's#^    ( cd "$root" \&\& MANIFEST_EMIT_HASH=0 governing_rows ) > "$raw"$#    ( cd "$root" \&\& require_hash_tool \&\& MANIFEST_EMIT_HASH=1 governing_rows ) > "$raw"#' \
    "$SCRIPT" > "$META_HASHED"
assert_eq "META: the hashed-governing mutation APPLIED (copy differs)" "1" \
    "$(cmp -s "$META_HASHED" "$SCRIPT" && echo 0 || echo 1)"
assert_eq "META: the hashed copy is still syntactically valid bash" "0" \
    "$(bash -n "$META_HASHED" 2>/dev/null && echo 0 || echo 1)"
META_HASHED_TSV="$WORK/governing-hashed.tsv"
bash "$META_HASHED" governing "$SYN" > "$META_HASHED_TSV" 2>/dev/null && RC=0 || RC=$?
assert_eq "META: the hashed copy still runs governing" "0" "$RC"
assert_eq "META: with hashing forced on, rows carry 3 fields (the 1g grammar leg WOULD fail)" \
    "0" "$(awk -F'\t' 'NF == 2' "$META_HASHED_TSV" | grep -c . | tr -d '[:space:]')"
# RESTORE CONTROL.
assert_eq "META: restore control — the SHIPPED copy emits 2-field rows" "0" \
    "$(awk -F'\t' 'NF != 2' "$WORK/governing-restore.tsv" | grep -c . | tr -d '[:space:]')"

# -----------------------------------------------------------------------
# Section 8: pipefail/process-substitution hardening (claude-workflow-
# plugin-i8cx, wave 2 group C). scan_flat/scan_tree used to feed a `while
# ... done < <(find ... -print0)` loop — a process substitution, so find's
# own exit status was structurally unobservable (no pipefail scope reaches
# a `< <(...)` boundary at all). A find that fails partway through (a
# permission-denied subdirectory) used to look EXACTLY like "this directory
# legitimately has fewer files" — install.sh --verify and the upgrade path
# both compare against this table, so a missing row verifies as "unchanged"
# forever. The fix matches this file's OWN in-tree template
# (scan_declared_dir, added earlier for the declared-directory scan): write
# find's output to a listing file, capture its rc directly, and die() on
# failure rather than silently emitting whatever arrived before the error.
# -----------------------------------------------------------------------
printf '\n--- Section 8: scan_flat/scan_tree die on a failed find, never emit a truncated manifest ---\n'

PERM_ROOT="$WORK/perm-source"
rm -rf "$PERM_ROOT"
mkdir -p "$PERM_ROOT/.claude/agents" "$PERM_ROOT/.claude/skills/blocked-skill"
printf '# a\n' > "$PERM_ROOT/.claude/agents/qa.md"
printf '# b\n' > "$PERM_ROOT/.claude/skills/blocked-skill/SKILL.md"

# --- 8a: scan_flat (.claude/agents), unreadable at maxdepth 1 --------------
assert_eq "8a.0 CONTROL: readable .claude/agents/ generates cleanly (exit 0), qa.md present" \
    "0|1" "$(bash "$SCRIPT" generate "$PERM_ROOT" > "$WORK/8a-control.tsv" 2>/dev/null; echo "$?")|$(grep -c '^\.claude/agents/qa\.md' "$WORK/8a-control.tsv")"

chmod 000 "$PERM_ROOT/.claude/agents"
bash "$SCRIPT" generate "$PERM_ROOT" > "$WORK/8a-broken.tsv" 2> "$WORK/8a-broken.err"
A8_RC=$?
chmod 755 "$PERM_ROOT/.claude/agents"
assert_eq "8a.1 THE FIX: an unreadable .claude/agents/ makes generate DIE (nonzero), never a silently truncated manifest" \
    "1" "$([ "$A8_RC" -ne 0 ] && echo 1 || echo 0)"
assert_eq "8a.2 ...with nothing printed to stdout (buffered failure, not a partial table)" \
    "0" "$(wc -c < "$WORK/8a-broken.tsv" | tr -d '[:space:]')"
assert_eq "8a.3 ...and the stated reason distinguishes a FAILED enumeration from a legitimately EMPTY one" \
    "1" "$(grep -c 'must not look like an empty' "$WORK/8a-broken.err")"

# --- 8b: scan_tree (.claude/skills), unreadable at depth 2 (recursive) -----
chmod 000 "$PERM_ROOT/.claude/skills/blocked-skill"
bash "$SCRIPT" generate "$PERM_ROOT" > "$WORK/8b-broken.tsv" 2> "$WORK/8b-broken.err"
B8_RC=$?
chmod 755 "$PERM_ROOT/.claude/skills/blocked-skill"
assert_eq "8b.1 THE FIX: an unreadable subdirectory deep in the RECURSIVE skills scan also dies loudly" \
    "1" "$([ "$B8_RC" -ne 0 ] && echo 1 || echo 0)"
assert_eq "8b.2 ...naming scan_tree specifically" \
    "1" "$(grep -c 'scan_tree:' "$WORK/8b-broken.err")"

# --- 8c: MUTANT — revert scan_flat to the pre-fix process-substitution
# shape (wholesale function replacement, qa-gate-pipefail.test.sh's MUTANT
# B technique — the fix replaced the loop's own producer, not merely added
# a strippable guard). ------------------------------------------------------
cat > "$WORK/8c-orig-scan-flat.txt" <<'ORIGEOF'
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
ORIGEOF
MUT_SF="$WORK/8c-mutant.sh"
awk -v bodyfile="$WORK/8c-orig-scan-flat.txt" '
    $0 == "scan_flat() {" {
        skipping = 1
        while ((getline line < bodyfile) > 0) print line
        next
    }
    skipping && /^}/ { skipping = 0; next }
    skipping { next }
    { print }
' "$SCRIPT" > "$MUT_SF"
chmod +x "$MUT_SF"
bash -n "$MUT_SF"
assert_eq "8c.0 NON-VACUITY: the mutant parses" "0" "$?"
MUT_SF_BODY=$(sed -n '/^scan_flat() {/,/^}/p' "$MUT_SF")
MUT_SF_DIE_COUNT=$(printf '%s' "$MUT_SF_BODY" | grep -c 'scan_flat: could not ENUMERATE')
MUT_SF_PROCSUB_COUNT=$(printf '%s' "$MUT_SF_BODY" | grep -c 'done < <(find')
assert_eq "8c.1 NON-VACUITY: the mutant's scan_flat lost the listing-file/die guard (reverted to the pre-fix procsub, byte for byte)" \
    "0|1" "${MUT_SF_DIE_COUNT}|${MUT_SF_PROCSUB_COUNT}"

chmod 000 "$PERM_ROOT/.claude/agents"
bash "$MUT_SF" generate "$PERM_ROOT" > "$WORK/8c-mutant-out.tsv" 2> "$WORK/8c-mutant-out.err"
MUT_RC=$?
chmod 755 "$PERM_ROOT/.claude/agents"
assert_eq "8c.2 SPECIFIC MISBEHAVIOUR: the mutant + the SAME unreadable directory exits 0 — the failure is completely invisible" \
    "0" "$MUT_RC"
assert_eq "8c.3 ...and silently emits a manifest simply MISSING the qa.md row, indistinguishable from 'this tree never shipped it'" \
    "0" "$(grep -c '^\.claude/agents/qa\.md' "$WORK/8c-mutant-out.tsv")"

MUT_CTRL_OUT="$WORK/8c-mutant-restore.tsv"
bash "$MUT_SF" generate "$PERM_ROOT" > "$MUT_CTRL_OUT" 2>/dev/null
assert_eq "8c.4 RESTORE CONTROL: even the mutant, unshimmed (readable directory), emits qa.md correctly — the mutation only bites under the injected fault" \
    "1" "$(grep -c '^\.claude/agents/qa\.md' "$MUT_CTRL_OUT")"

# --- 8d: cmd_classify's wc|tr row-count self-check — a garbled tail-stage
# output (not merely empty) is now impossible: `wc` runs alone, `tr` runs on
# an already-captured in-memory string. Function-level: extract and drive
# the shipped body directly (leg 4: shipped bytes, not a re-typed copy);
# cmd_classify's OWN end-to-end verdict is unaffected on a matching pair of
# counts (already exercised by Sections 4/5 above), so this proves the
# NARROWER function-level contract the fix actually changes. --------------
printf '\n--- Section 8d: the row-count self-check never reads a garbled wc/tr tail as a real number ---\n'
mkdir -p "$WORK/8d-wc-shim-bin"
cat > "$WORK/8d-wc-shim-bin/wc" <<'SHIMEOF'
#!/bin/bash
# Prints a plausible-looking-but-WRONG count, then fails — simulating wc
# dying mid-write rather than failing before printing anything.
printf '99\n'
exit 9
SHIMEOF
chmod +x "$WORK/8d-wc-shim-bin/wc"
D8_OUT=$(PATH="$WORK/8d-wc-shim-bin:$PATH" bash "$SCRIPT" classify --target "$SYN" --source "$SYN" --old-table "$OLD_TABLE" 2>&1)
D8_RC=$?
assert_eq "8d.1 THE FIX: a wc that prints a plausible WRONG count then fails makes classify DIE (nonzero), never silently trust the garbled '99'" \
    "1" "$([ "$D8_RC" -ne 0 ] && echo 1 || echo 0)"
assert_eq "8d.2 ...and names wc's own exit status, not a fabricated row-count mismatch" \
    "1" "$(printf '%s' "$D8_OUT" | grep -c 'wc exited')"

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

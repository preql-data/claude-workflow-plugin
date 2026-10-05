#!/bin/bash
# design-rubric.test.sh — L1 spec for Phase D2 Part A
# (claude-workflow-plugin-fkm.4): the design-reviewer prompt body and the
# automatic manifest coverage of the new design rubric.
#
# SPLIT WITH qa-gate-grade-record.test.sh
# ----------------------------------------
# design.md's own frontmatter shape (version: 1, name: design, no
# extends:) and its DS1-DS8 heading count ride the EXISTING "Section 8:
# structural sanity of .claude/rubrics/ files" sweep in
# qa-gate-grade-record.test.sh instead of being duplicated here — that
# file already carries the EXPECTED_RUBRICS table, the
# expected_rubric_version() extractor, and the "does NOT declare a key"
# assertion shape (the bugfix applies_to check); design.md rides that
# existing machinery rather than growing a second, parallel one (DS7,
# applied reflexively to this task's own tests). This file covers the two
# things that do NOT already have a home there: the design-reviewer AGENT
# PROMPT (a different artifact than a rubric file) and whether a brand
# new rubric file is automatically picked up for install/upgrade with no
# installer edit (a claim about workflow-manifest.sh's behaviour, not
# about qa-gate.sh's).
#
# PAIRING STATUS (.claude/tests/README.md, "The pairing requirement")
# ---------------------------------------------------------------------
# Phase D2 Part A ships two prose artifacts (the design rubric, the
# design-reviewer prompt body) with no consuming executable yet — Part B
# of this same phase builds the record grammar, the subcommand, and the
# enforcement sites that will eventually read a design verdict. Per
# README's P7 guidance, a check that only asserts PROMPT TEXT is a
# DOCUMENT check and cannot reach leg 4 (execution) on its own:
#
#   Section 1 (placeholder removal)       — DOCUMENT check. UNPAIRED at leg
#     4: no shipped executable reads design-reviewer.md's body today (the
#     design-reviewer subagent that eventually will is an LLM, not
#     something this harness can drive and check exit codes against).
#     Paired at legs 1-3 (non-vacuity, misbehaviour, control) via the
#     META-TEST in this section.
#   Section 2 (no nested-spawn directive) — DOCUMENT check, same status as
#     Section 1, kept narrow and cross-referenced against the dedicated
#     no-nested-spawn-instructions.test.sh rather than duplicating its
#     pairing story here.
#   Sections 3-4 (manifest classification) — REACH leg 4. They drive the
#     real, shipped workflow-manifest.sh against a synthetic tree and then
#     against the real repo root. The claim under test — "a new rubric
#     file needs no installer/manifest edit" — is a claim about that
#     script's behaviour, and these sections run it rather than asserting
#     prose about it.
#
# Exit codes:
#   0  every assertion passed
#   1  one or more assertions failed
#   2  invocation error (a file this spec depends on is missing)
#
# Usage:
#   bash .claude/scripts/tests/design-rubric.test.sh

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
REVIEWER_MD="$PROJECT_DIR/.claude/agents/design-reviewer.md"
DESIGN_RUBRIC="$PROJECT_DIR/.claude/rubrics/design.md"
MANIFEST_SCRIPT="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"

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

# field_of <tsv-file> <path> <field-number> — first matching row's Nth
# tab-separated field, or empty when the path has no row. Mirrors the
# helper of the same name in workflow-manifest.test.sh (reused in shape,
# not sourced, so this file has no load-time dependency on that one).
field_of() {
    awk -F'\t' -v p="$2" -v n="$3" '$1 == p { print $n; exit }' "$1" 2>/dev/null
}

for f in "$REVIEWER_MD" "$DESIGN_RUBRIC" "$MANIFEST_SCRIPT"; do
    if [ ! -f "$f" ]; then
        printf 'design-rubric.test.sh: required file not found: %s\n' "$f" >&2
        exit 2
    fi
done

WORK=$(mktemp -d -t design-rubric-test.XXXXXX)
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
echo "=== Section 1: design-reviewer.md carries no D0 placeholder text (AC 4.1) ==="
# DOCUMENT check — UNPAIRED at leg 4, reason in the header comment above.
# Paired at legs 1-3 via the META-TEST at the end of this section.

placeholder_status_count=$(grep -c "## Status: frontmatter and registration only (Phase D0)" "$REVIEWER_MD")
assert_eq "design-reviewer.md: D0 status heading absent" "0" "$placeholder_status_count"

placeholder_body_count=$(grep -c "This prompt body is a placeholder" "$REVIEWER_MD")
assert_eq "design-reviewer.md: 'placeholder' sentence absent" "0" "$placeholder_body_count"

required_fixes_count=$(grep -c "required_fixes" "$REVIEWER_MD")
assert_eq "design-reviewer.md: names required_fixes (the grade-record field, not a synonym)" \
    "yes" "$([ "$required_fixes_count" -gt 0 ] && echo yes || echo no)"

required_changes_count=$(grep -c "required_changes" "$REVIEWER_MD")
assert_eq "design-reviewer.md: never uses required_changes" "0" "$required_changes_count"

reviewer_identity_count=$(grep -c "reviewer_identity" "$REVIEWER_MD")
assert_eq "design-reviewer.md: verdict shape names reviewer_identity" \
    "yes" "$([ "$reviewer_identity_count" -gt 0 ] && echo yes || echo no)"

# META-TEST: the placeholder-absence check is only worth having if a
# fixture that STILL carries the D0 scaffolding is flagged — non-vacuity
# (the fixture really carries both strings), misbehaviour (the production
# assertion above would disagree with it), and a restated control (the
# shipped file has neither).
META_PLACEHOLDER=$(mktemp -t design-reviewer-meta.XXXXXX)
cat > "$META_PLACEHOLDER" <<'FIXTURE'
---
name: design-reviewer
---

You are the design reviewer.

## Status: frontmatter and registration only (Phase D0)

**This prompt body is a placeholder. Phase D2 owns it.**
FIXTURE
meta_status=$(grep -c "## Status: frontmatter and registration only (Phase D0)" "$META_PLACEHOLDER")
meta_body=$(grep -c "This prompt body is a placeholder" "$META_PLACEHOLDER")
assert_eq "META: placeholder fixture really carries the status heading" "1" "$meta_status"
assert_eq "META: placeholder fixture really carries the placeholder sentence" "1" "$meta_body"
assert_eq "META: control — shipped design-reviewer.md carries neither string" "yes" \
    "$([ "$(grep -c "## Status: frontmatter and registration only (Phase D0)" "$REVIEWER_MD")" = "0" ] \
        && [ "$(grep -c "This prompt body is a placeholder" "$REVIEWER_MD")" = "0" ] \
        && echo yes || echo no)"
rm -f "$META_PLACEHOLDER"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: no nested-spawn directive in design-reviewer.md ==="
# Belt-and-suspenders alongside no-nested-spawn-instructions.test.sh's own
# discovery-based sweep (which already covers this file) — asserted again
# here, narrowly, so this spec stands on its own if read in isolation
# without needing to cross-reference that file's regex definitions.

spawn_task_kw=$(grep -cE '^[[:space:]]*Task\([^)]*subagent_type[[:space:]]*=' "$REVIEWER_MD")
assert_eq "design-reviewer.md: no Task(subagent_type=...) directive" "0" "$spawn_task_kw"

spawn_at_role=$(grep -cE '^[[:space:]]*Task\([[:space:]]*"@[A-Za-z]+"' "$REVIEWER_MD")
assert_eq "design-reviewer.md: no Task(\"@role\"...) directive" "0" "$spawn_at_role"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: workflow-manifest.sh classifies design.md as operator (leg 4: execution) ==="
# EXECUTION leg: drives the real, shipped workflow-manifest.sh against a
# small self-contained synthetic tree. Mirrors the synthetic-tree pattern
# in workflow-manifest.test.sh Section 1 (mkfile + generate + a
# field-of-row check), rebuilt here in miniature rather than extending
# that file's shared SYN fixture and its pinned exact-row-count
# assertions (17 total / 4 operator rows) — a self-contained tree keeps
# this spec's blast radius to the two rubric files it actually cares
# about, at the cost of a few duplicated lines of setup.

SYN="$WORK/synthetic-rubrics-source"
mkdir -p "$SYN/.claude/rubrics"
printf -- '---\nversion: 2\nname: default\n---\n\nsynthetic default rubric\n' \
    > "$SYN/.claude/rubrics/default.md"
printf -- '---\nversion: 1\nname: design\n---\n\nsynthetic design rubric\n' \
    > "$SYN/.claude/rubrics/design.md"

SYN_TSV="$WORK/synthetic-rubrics.tsv"
bash "$MANIFEST_SCRIPT" generate "$SYN" > "$SYN_TSV" 2>"$WORK/synthetic-rubrics.err"
manifest_rc=$?
assert_eq "generate on the two-rubric synthetic tree exits 0" "0" "$manifest_rc"
assert_eq "generate on the two-rubric synthetic tree writes nothing to stderr" \
    "" "$(cat "$WORK/synthetic-rubrics.err")"

assert_eq "synthetic tree: .claude/rubrics/default.md is class operator" \
    "operator" "$(field_of "$SYN_TSV" ".claude/rubrics/default.md" 2)"
assert_eq "synthetic tree: .claude/rubrics/design.md is class operator" \
    "operator" "$(field_of "$SYN_TSV" ".claude/rubrics/design.md" 2)"

rubrics_row_count=$(awk -F'\t' '$1 ~ /^\.claude\/rubrics\// { n++ } END { print n + 0 }' "$SYN_TSV")
assert_eq "synthetic tree: exactly 2 .claude/rubrics/ rows (a real directory scan, not one hardcoded name)" \
    "2" "$rubrics_row_count"

# META-TEST: this section is sensitive to a rubric NOT being on disk, not
# just always-reporting-operator regardless of content. Remove design.md
# from the synthetic tree and confirm its row disappears.
rm -f "$SYN/.claude/rubrics/design.md"
SYN_TSV_AFTER="$WORK/synthetic-rubrics-after.tsv"
bash "$MANIFEST_SCRIPT" generate "$SYN" > "$SYN_TSV_AFTER" 2>/dev/null
after_count=$(awk -F'\t' '$1 ~ /^\.claude\/rubrics\// { n++ } END { print n + 0 }' "$SYN_TSV_AFTER")
assert_eq "META: removing design.md drops the row count to 1 (scan reflects disk, not a fixed list)" \
    "1" "$after_count"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: real-repo bridge — the SHIPPED design.md is picked up too ==="
# Bridges Section 3's synthetic proof to the actual shipped artifact,
# mirroring workflow-manifest.test.sh's own "real-repo sanity" section.
# Asserts only the one row this spec cares about — never a total row
# count — so it does not become a second place that has to be bumped
# every time an unrelated shipped file is added.

REAL_TSV="$WORK/real-repo.tsv"
bash "$MANIFEST_SCRIPT" generate "$PROJECT_DIR" > "$REAL_TSV" 2>"$WORK/real-repo.err"
real_rc=$?
assert_eq "generate on the real repo root exits 0" "0" "$real_rc"
assert_eq "real repo: .claude/rubrics/design.md is class operator" \
    "operator" "$(field_of "$REAL_TSV" ".claude/rubrics/design.md" 2)"

# --- Summary ----------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

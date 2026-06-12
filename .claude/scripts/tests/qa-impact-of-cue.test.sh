#!/bin/bash
# qa-impact-of-cue.test.sh — claude-workflow-plugin-366.9.
#
# Encodes the model-behaviour gap surfaced by Phase B run 3
# (cassettes/seed/node-react-auth-2026-06-12T00-50-56-312Z.jsonl):
# QA had all 7 code-graph tools structurally available
# (toolsAvailable contains mcp__plugin_claude-workflow_code-graph__impact_of
# and the other six) but invoked impact_of zero times across both QA
# spawns. Negative-fact anchor: .claude/tests/e2e/specs/_phase-b-run3-trace.unit.spec.ts.
#
# The forensic hypothesis (366.9): QA subagents in live runs receive
# their TASK PROMPT from verify-before-stop.sh's Stop-block template
# (the `Task("@qa", "Mandatory review before delivery: ... Checklist:
# ...")` block, lines 967-989 of verify-before-stop.sh as of 366.8).
# Pre-fix, that template's checklist enumerates tests/journeys/failure
# modes but contains ZERO reference to impact_of, code-graph, or the
# regression-impact scan. The brief argues the task-prompt checklist
# dominates QA's attention over qa.md section 3a's embedded "consult
# the code graph when present" standing instruction, and in run 3 both
# QA invocations followed the checklist faithfully and never reached
# for code-graph.
#
# Fix surfaces:
#
#   (a) verify-before-stop.sh's QA-delegation template MUST contain an
#       imperative impact_of cue inside the Task("@qa", ...) block, so
#       every QA spawn driven by the Stop hook starts with the cue at
#       the top of its working memory.
#
#   (b) qa.md section 3a MUST present impact_of as the LITERAL FIRST
#       ACTION of the review procedure when files have changed — an
#       unconditional imperative, not an embedded paragraph step that
#       reads as optional. The 3a heading "Regression impact scan" must
#       be followed by an actionable, ordered first-action directive
#       that explicitly names impact_of.
#
# This test asserts both surfaces. The two anchors are deliberately
# robust against rewording — they require the literal token `impact_of`
# inside a contextual window, not exact prose. Re-wording the cue is
# fine; deleting it (or moving it out of the relevant section) flips
# the test red.
#
# META-TESTs (mirror agent-mcp-tools-parity.test.sh):
#   1. Strip the impact_of cue from a temp copy of verify-before-stop.sh
#      and assert the verify-template check fails.
#   2. Strip the impact_of first-action from a temp copy of qa.md
#      section 3a and assert the qa-md check fails.
#
# Exit codes:
#   0 — both surfaces carry the cue AND both META-TEST mutations are
#       flagged
#   1 — one or more assertions failed
#   2 — invocation error (missing files)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
VBS_FILE="$PROJECT_DIR/.claude/scripts/verify-before-stop.sh"
QA_FILE="$PROJECT_DIR/.claude/agents/qa.md"

if [ ! -f "$VBS_FILE" ]; then
    printf 'qa-impact-of-cue: verify-before-stop.sh not found: %s\n' "$VBS_FILE" >&2
    exit 2
fi
if [ ! -f "$QA_FILE" ]; then
    printf 'qa-impact-of-cue: qa.md not found: %s\n' "$QA_FILE" >&2
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

# ---------------------------------------------------------------------------
# Surface (a): verify-before-stop.sh's QA-delegation template.
#
# The template is the heredoc starting with `Task("@qa", "Mandatory review`
# and ending with the `qa-gate.sh block` line. We extract that window and
# assert it mentions impact_of.
#
# Extraction strategy: awk a window from the line containing the
# `Task("@qa", "Mandatory review` anchor through the next blank line that
# follows the closing `qa-gate.sh block` line (the template's own end).
# Robust to whitespace/wording changes inside the window because the
# anchors are at the heredoc boundaries.

extract_qa_task_block() {
    local file="$1"
    # The template lives inside a bash double-quoted REASON string so its
    # `"` characters are backslash-escaped (`\"`) in the source — match
    # both raw and escaped forms with a permissive regex.
    awk '
        BEGIN { in_block = 0 }
        /Task\(\\?"@qa\\?",[[:space:]]*\\?"Mandatory review/ { in_block = 1 }
        in_block { print }
        in_block && /qa-gate\.sh block/ { in_block = 0 }
    ' "$file"
}

QA_BLOCK=$(extract_qa_task_block "$VBS_FILE")

if [ -z "$QA_BLOCK" ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("verify-before-stop.sh: could not locate Task('@qa', ...) block")
    printf '  FAIL: verify-before-stop.sh: could not locate Task("@qa", ...) block\n'
else
    # The block must contain the literal token `impact_of` — that's the
    # cue we want surfaced at the top of QA's working memory on every
    # Stop-hook spawn.
    if printf '%s' "$QA_BLOCK" | grep -qF -- 'impact_of'; then
        impact_rc=0
    else
        impact_rc=1
    fi
    assert_eq "verify-before-stop.sh: QA task-block mentions impact_of" "0" "$impact_rc"

    # And the block must mention code-graph somewhere in the same
    # window — proving the cue is contextualised to the right MCP
    # server (so QA doesn't go grep for some unrelated tool).
    if printf '%s' "$QA_BLOCK" | grep -qiF -- 'code-graph'; then
        cg_rc=0
    else
        cg_rc=1
    fi
    assert_eq "verify-before-stop.sh: QA task-block mentions code-graph" "0" "$cg_rc"
fi

# ---------------------------------------------------------------------------
# Surface (b): qa.md section 3a.
#
# Section 3a is the "Regression impact scan" subsection of section 3.
# Anchored by `### 3a. Regression impact scan` heading and bounded by
# the next `### ` heading.
#
# Pre-fix: 3a's body opened with the prose paragraph "The Stop-hook
# gate already runs the FULL test suite..." and only mentioned
# impact_of mid-paragraph. The fix elevates impact_of into the LITERAL
# FIRST ACTION: an unconditional imperative directive that names
# impact_of in the first sentence/bullet of the procedure.
#
# Robust anchor: within the first ~600 chars of section 3a's body,
# `impact_of` must appear AND the wording must read as an actionable
# first step (we look for one of: "First", "FIRST", "Before",
# "first action", or a leading numbered/bulleted list item that
# carries impact_of).

extract_qa_section_3a() {
    local file="$1"
    awk '
        BEGIN { in_section = 0 }
        /^### 3a\. / { in_section = 1; print; next }
        in_section && /^### / { exit }
        in_section { print }
    ' "$file"
}

QA_3A=$(extract_qa_section_3a "$QA_FILE")

if [ -z "$QA_3A" ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("qa.md: could not locate section 3a")
    printf '  FAIL: qa.md: could not locate section 3a (### 3a. ...)\n'
else
    # Sanity: the section must mention impact_of at all (carryover from
    # the pre-fix state was true; this catches accidental deletion).
    if printf '%s' "$QA_3A" | grep -qF -- 'impact_of'; then
        any_impact_rc=0
    else
        any_impact_rc=1
    fi
    assert_eq "qa.md 3a: section mentions impact_of" "0" "$any_impact_rc"

    # First-action wording: within the FIRST 600 characters of section
    # 3a's body, there must be both `impact_of` AND a first-action
    # marker. The 600-char cap is generous (~10 lines) yet tight
    # enough that a buried mid-paragraph mention does not satisfy it.
    HEAD_3A=$(printf '%s' "$QA_3A" | head -c 600)
    if printf '%s' "$HEAD_3A" | grep -qF -- 'impact_of'; then
        head_impact_rc=0
    else
        head_impact_rc=1
    fi
    assert_eq "qa.md 3a: impact_of appears in first 600 chars of body" "0" "$head_impact_rc"

    # First-action marker. Accept any of: literal "First", "FIRST",
    # "Before reading the diff", or a leading "1." numbered list item.
    # This is wording-tolerant: any rewrite that keeps the
    # first-action shape passes; rewrites that demote impact_of back
    # to "consult when needed" or similar do not.
    if printf '%s' "$HEAD_3A" \
        | grep -qE '(^|[^[:alnum:]])(First|FIRST|Before reading the diff|First action|FIRST ACTION)([^[:alnum:]]|$)' \
        || printf '%s' "$HEAD_3A" | grep -qE '^[[:space:]]*1\.'; then
        first_action_rc=0
    else
        first_action_rc=1
    fi
    assert_eq "qa.md 3a: first-action marker present in first 600 chars" "0" "$first_action_rc"
fi

# ---------------------------------------------------------------------------
# META-TEST 1 (verify-before-stop.sh): strip the impact_of cue from a
# temp copy and assert the verify-template check fails. This proves
# the test is sensitive to a regression in the template wording.

META1_TMP=$(mktemp -t qa-impact-of-cue-vbs.XXXXXX)
# Strip every line in the Task("@qa", ...) block that mentions impact_of
# or code-graph. The rest of the script stays intact.
awk '
    BEGIN { in_block = 0 }
    /Task\(\\?"@qa\\?",[[:space:]]*\\?"Mandatory review/ { in_block = 1 }
    in_block && /impact_of/ { next }
    in_block && /code-graph/ { next }
    in_block && /qa-gate\.sh block/ { in_block = 0; print; next }
    { print }
' "$VBS_FILE" > "$META1_TMP"

META1_BLOCK=$(extract_qa_task_block "$META1_TMP")
if printf '%s' "$META1_BLOCK" | grep -qF -- 'impact_of'; then
    meta1_rc=0
else
    meta1_rc=1
fi
# We expect rc=1 (impact_of stripped) — META-TEST proves the check sees
# the stripped state.
assert_eq "META-TEST 1: stripped verify-before-stop.sh fails the impact_of cue check" "1" "$meta1_rc"

rm -f "$META1_TMP"

# ---------------------------------------------------------------------------
# META-TEST 2 (qa.md): strip the first-action impact_of line from a temp
# copy and assert the head-of-3a check fails.

META2_TMP=$(mktemp -t qa-impact-of-cue-qa.XXXXXX)
# Strip every line within section 3a that mentions impact_of.
awk '
    BEGIN { in_section = 0 }
    /^### 3a\. / { in_section = 1; print; next }
    in_section && /^### / { in_section = 0; print; next }
    in_section && /impact_of/ { next }
    { print }
' "$QA_FILE" > "$META2_TMP"

META2_3A=$(awk '
    BEGIN { in_section = 0 }
    /^### 3a\. / { in_section = 1; print; next }
    in_section && /^### / { exit }
    in_section { print }
' "$META2_TMP")
META2_HEAD=$(printf '%s' "$META2_3A" | head -c 600)
if printf '%s' "$META2_HEAD" | grep -qF -- 'impact_of'; then
    meta2_rc=0
else
    meta2_rc=1
fi
# Expected rc=1 (impact_of stripped) — proves the head-of-3a check is
# sensitive to a regression in section 3a's wording.
assert_eq "META-TEST 2: stripped qa.md 3a fails the impact_of head check" "1" "$meta2_rc"

rm -f "$META2_TMP"

# ---------------------------------------------------------------------------
# Summary.

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

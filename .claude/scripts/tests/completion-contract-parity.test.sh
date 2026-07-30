#!/bin/bash
# completion-contract-parity.test.sh — claude-workflow-plugin-i17 (v4.1 / C2).
#
# ONE definition of the F7 specialist completion contract; a dozen documents
# that each carry a copy of it. This L1 spec reads those documents and refuses
# a tree in which a copy has drifted from the canonical field list.
#
# WHY THIS SPEC EXISTS — two real gaps that were live at v4.0
# ----------------------------------------------------------
# Neither was found by a check. Both were found by reading, several releases
# after they appeared, and both are the kind of drift a doc review skims past:
#
#   1. THE DEVOPS GAP. docs/AGENTS.md names four carriers of the contract
#      ("backend, frontend, devops, qa") and .claude/agents/devops.md had no
#      completion-contract section AT ALL. The doc claimed a contract one of
#      its four named specialists had never been handed. Section 1's fence
#      CENSUS is the guard, and it is why that section asserts a COUNT rather
#      than "every fence we found is well-formed": a file with zero F7 fences
#      satisfies the second phrasing vacuously, which is exactly how the gap
#      survived. The census would have printed devops=0 and gone red.
#
#   2. THE FRONTEND HEDGE. .claude/agents/frontend.md closed its contract
#      section by making `llm_observations` mandatory only "when there is
#      anything notable to say", while docs/AGENTS.md said a payload without
#      it is malformed — a conditional and an absolute, on the same field, in
#      two prompts the same orchestrator routes between. Section 5's
#      forbidden-phrase scan is the guard: the hedge's exact wording is on the
#      denied list, so re-introducing it fails here. FUTURE EDITORS: if you
#      want to cite that phrasing as an antipattern, PARAPHRASE it — quoting
#      it verbatim anywhere in the carrier set turns this spec red, by design.
#      (This spec is not itself a carrier, which is why the needle can be
#      spelled out here and in the META-B fixture without self-tripping. The
#      shipped frontend.md paraphrases it, deliberately.)
#
# WHAT IT ASSERTS
#   1. Fence census. Every ```json fence carrying BOTH "task_id" and
#      "llm_observations" is an F7 contract block. Expected: AGENTS.md=1,
#      backend=1, frontend=1, devops=1, qa=3. Asserted as one completeness
#      line so a missing carrier cannot pass by being absent.
#   2. Per fence: it PARSES as JSON, and its first seven keys in DOCUMENT
#      ORDER are the canonical seven. jq is the oracle here — the spec does
#      not grep the prose for field names, it parses the JSON the prompt
#      actually ships and asks jq what keys it has. A grep mirror would go
#      green on a field name mentioned in a sentence next to a fence that
#      never got one.
#   3. qa.md's three blocks are a SUPERSET (base seven, then QA-specific
#      fields) — qa.md section 10 promises the base fields keep their
#      canonical names AND ordering, which is why order is asserted.
#   4. `context_coverage` reached every prose carrier: grader.md (packet item
#      4, the quality taxonomy, the working procedure), the default rubric's
#      C3 and C8, qa.md's section 3 review checklist, and both READMEs.
#   5. Forbidden phrases: the stale count words and the frontend hedge occur
#      ZERO times across the carrier set.
#   6. Each .claude/rubrics/*.md is byte-identical to the rubric-revision-loop
#      e2e fixture's copy. That identity is currently accidental — nothing
#      syncs them and nothing checked them. This turns it into an assertion,
#      so a rubric revision that forgets the fixture fails at L1 instead of
#      inside a paid live run.
#
# META-TESTS (both mutate a COPY under mktemp; the live repo is never touched)
#   A. A prompt fixture with `context_coverage` deleted from its fence must be
#      flagged by the same key-order checker section 2 uses — and a copy of
#      devops.md with every json fence stripped (the shape that file actually
#      had through v4.0) must be flagged by the same census checker section 1
#      uses. The second half is what makes the devops-gap claim above a
#      demonstration rather than a story.
#   B. A doc fixture still saying "all six fields", and one still carrying the
#      frontend hedge, must each be flagged by the same phrase scanner
#      section 5 uses. Without B, section 5 would be a check that has never
#      been seen to go red — every phrase on the denied list is (correctly)
#      absent from the shipped tree.
#
# DELIBERATE EXCLUSIONS — do not "fix" these
#   - docs/plans/verification-suite.md still says "six" in two places: its
#     model-agnostic-invariants bullet and its "Default rubric criteria for
#     v1" bullet. It is the historical design doc for the verification suite —
#     a record of what was planned in that cycle, not a live contract carrier.
#     Historical design docs are not retro-edited; the same rule the
#     RELEASE_AUDIT addendum applies.
#   - docs/RELEASE_AUDIT.md row A10 likewise says "six base fields" and cites
#     a dated inspection ("read 2026-06-13"). Rewriting a dated evidence row
#     would falsify the evidence.
#   - CHANGELOG.md entries are historical for the same reason.
#
# HONEST CEILING. This spec guards the DOCUMENTS. There is no runtime
# enforcement of the contract anywhere in the plugin: nothing rejects a
# completion payload that omits a field, and the e2e `completion-contract`
# invariant remains `skipped` on its documented trace gap. The contract is
# enforced by convention plus the QA review checklist plus rubric C3/C8 —
# and this spec only makes sure those three say the same thing.
#
# Exit codes:
#   0  every assertion passed and both META-TESTs flagged their fixtures
#   1  one or more assertions failed
#   2  invocation error (jq missing)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"

if ! command -v jq >/dev/null 2>&1; then
    printf 'completion-contract-parity.test.sh: jq is required but not on PATH\n' >&2
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

# The canonical field list, in the canonical order. `context_coverage` is
# SEVENTH and last on purpose: appending it leaves the original six in the
# positions qa.md section 10 promises they keep.
CANONICAL="task_id,files_changed,tests_added,decisions,blockers,llm_observations,context_coverage"

# Files that carry a copy of the contract or its field list. Order is the
# reading order a maintainer would follow: definition, then the prompts that
# implement it, then the docs that describe it.
CARRIERS=(
    "docs/AGENTS.md"
    "docs/MCP_SERVERS.md"
    ".claude/agents/backend.md"
    ".claude/agents/frontend.md"
    ".claude/agents/devops.md"
    ".claude/agents/qa.md"
    ".claude/agents/grader.md"
    ".claude/rubrics/default.md"
    ".claude/tests/e2e/fixtures/rubric-revision-loop/.claude/rubrics/default.md"
    ".claude/mcp/bd-mcp/README.md"
    ".claude/tests/README.md"
    ".claude/tests/e2e/lib/invariants.ts"
)

# ---------------------------------------------------------------------------
# The extractors. Both take a FILE so the META-TESTs run byte-identical logic
# against deliberately-broken copies.

# f7_fence_count <file> — how many fenced json blocks carry BOTH "task_id"
# and "llm_observations". Those two together are what makes a block an F7
# contract rather than some other JSON the prompt happens to show.
#
# The awk program is SINGLE-quoted throughout: it contains backtick fence
# markers, and a backtick inside a double-quoted shell string silently
# command-substitutes.
f7_fence_count() {
    [ -f "$1" ] || { printf '0'; return 1; }
    awk '
        /^```json[[:space:]]*$/ { inb = 1; buf = ""; next }
        /^```[[:space:]]*$/ && inb {
            inb = 0
            if (buf ~ /"task_id"/ && buf ~ /"llm_observations"/) n++
            next
        }
        inb { buf = buf $0 "\n" }
        END { printf "%d", n + 0 }
    ' "$1"
}

# f7_fence <file> <n> — the raw body of the Nth F7 fence in the file, or the
# empty string when there is no Nth one.
f7_fence() {
    [ -f "$1" ] || return 1
    awk -v want="$2" '
        /^```json[[:space:]]*$/ { inb = 1; buf = ""; next }
        /^```[[:space:]]*$/ && inb {
            inb = 0
            if (buf ~ /"task_id"/ && buf ~ /"llm_observations"/) {
                n++
                if (n == want) { printf "%s", buf; exit }
            }
            next
        }
        inb { buf = buf $0 "\n" }
    ' "$1"
}

# fence_head7 <json-text> — the first seven keys in DOCUMENT order, comma
# joined; the literal string PARSE_ERROR when the body is not valid JSON.
# keys_unsorted (not keys) because the ordering is part of the promise.
fence_head7() {
    printf '%s' "$1" \
        | jq -r 'keys_unsorted[0:7] | join(",")' 2>/dev/null \
        || printf 'PARSE_ERROR'
}

# fence_parses <json-text> — the word yes/no.
fence_parses() {
    if printf '%s' "$1" | jq -e . >/dev/null 2>&1; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# phrase_hits <phrase> [file...] — total occurrences of a FIXED string across
# the given files (defaults to the whole carrier set). Case-insensitive: a
# sentence-initial "All six fields" is the same drift as a mid-sentence one.
phrase_hits() {
    local needle="$1"
    shift
    local -a scan
    if [ "$#" -gt 0 ]; then
        scan=("$@")
    else
        scan=()
        local c
        for c in "${CARRIERS[@]}"; do scan+=("$PROJECT_DIR/$c"); done
    fi
    grep -o -i -F -- "$needle" "${scan[@]}" 2>/dev/null | wc -l | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
echo "=== Section 1: F7 fence census (a COUNT, so a zero-fence file fails) ==="

CENSUS=""
for pair in "docs/AGENTS.md:AGENTS" \
            ".claude/agents/backend.md:backend" \
            ".claude/agents/frontend.md:frontend" \
            ".claude/agents/devops.md:devops" \
            ".claude/agents/qa.md:qa"; do
    file="${pair%%:*}"
    label="${pair##*:}"
    count=$(f7_fence_count "$PROJECT_DIR/$file")
    CENSUS="$CENSUS $label=$count"
done
CENSUS="${CENSUS# }"

assert_eq "census: every carrier ships the expected number of F7 fences" \
    "AGENTS=1 backend=1 frontend=1 devops=1 qa=3" "$CENSUS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: every fence parses and opens with the canonical seven ==="

# file:index pairs, matching the census above.
FENCES=(
    "docs/AGENTS.md:1"
    ".claude/agents/backend.md:1"
    ".claude/agents/frontend.md:1"
    ".claude/agents/devops.md:1"
    ".claude/agents/qa.md:1"
    ".claude/agents/qa.md:2"
    ".claude/agents/qa.md:3"
)

for spec in "${FENCES[@]}"; do
    file="${spec%:*}"
    idx="${spec##*:}"
    body=$(f7_fence "$PROJECT_DIR/$file" "$idx")
    assert_eq "$file fence #$idx: parses as JSON" "yes" "$(fence_parses "$body")"
    assert_eq "$file fence #$idx: first seven keys are the canonical seven, in order" \
        "$CANONICAL" "$(fence_head7 "$body")"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: qa.md's three blocks are a SUPERSET, not a variant ==="

# The QA contract adds fields ON TOP of the base seven. Count the blocks that
# actually carry a QA-specific key beyond the seven, and assert the COUNT —
# "no block was missing one" would be vacuously true for zero blocks.
QA_SUPERSETS=0
for idx in 1 2 3; do
    body=$(f7_fence "$PROJECT_DIR/.claude/agents/qa.md" "$idx")
    extra=$(printf '%s' "$body" | jq -r 'keys_unsorted[7:] | length' 2>/dev/null)
    has_approved=$(printf '%s' "$body" | jq -r 'has("approved")' 2>/dev/null)
    if [ "${extra:-0}" -gt 0 ] 2>/dev/null && [ "$has_approved" = "true" ]; then
        QA_SUPERSETS=$((QA_SUPERSETS + 1))
    fi
done
assert_eq "qa.md: all three contract blocks extend the base seven (and carry approved)" \
    "3" "$QA_SUPERSETS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: context_coverage reached every PROSE carrier ==="

# Each of these is a place a reader or an agent looks for the field list and
# would otherwise get the pre-C2 answer. Anchored on text, never line numbers.
# NB: the needles below are SINGLE-quoted, and several contain markdown
# backticks. That is deliberate and load-bearing: a backtick inside a
# double-quoted string command-substitutes silently, so the needle would
# become the output of running its own contents. SC2016 fires on exactly this
# shape, which is why the group carries one scoped disable rather than being
# "fixed" by switching to double quotes.
# shellcheck disable=SC2016  # literal markdown backticks are DATA, not commands
{
assert_eq "grader.md: packet item 4 lists context_coverage among the base seven" \
    "1" "$(phrase_hits '`llm_observations`, `context_coverage`. QA-specific' "$PROJECT_DIR/.claude/agents/grader.md")"
assert_eq "grader.md: carries the context_coverage quality taxonomy" \
    "1" "$(phrase_hits '`context_coverage` is mandatory and substantive, on the same three-way taxonomy' "$PROJECT_DIR/.claude/agents/grader.md")"
assert_eq "grader.md: working-procedure step 4 reads context_coverage" \
    "1" "$(phrase_hits 'read `context_coverage` and cross-check' "$PROJECT_DIR/.claude/agents/grader.md")"
assert_eq "default rubric: C3 enumerates context_coverage" \
    "1" "$(phrase_hits '`llm_observations`, and `context_coverage`' "$PROJECT_DIR/.claude/rubrics/default.md")"
assert_eq "default rubric: C8 exists and is about context_coverage" \
    "1" "$(phrase_hits '### C8. `context_coverage` names what was read' "$PROJECT_DIR/.claude/rubrics/default.md")"
}
assert_eq "qa.md section 3: the review checklist asks for all seven fields" \
    "1" "$(phrase_hits 'The specialist returned all seven F7 fields' "$PROJECT_DIR/.claude/agents/qa.md")"
assert_eq "bd-mcp README: the F7 tuple carries context_coverage" \
    "1" "$(phrase_hits 'llm_observations, context_coverage}' "$PROJECT_DIR/.claude/mcp/bd-mcp/README.md")"
assert_eq "tests README: the completion-contract row says seven" \
    "1" "$(phrase_hits 'carries all seven F7 fields' "$PROJECT_DIR/.claude/tests/README.md")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: forbidden phrases occur ZERO times in the carrier set ==="

# Stale count words. Each is a distinct phrasing that appeared somewhere in
# the tree before C2, so each is a real regression shape rather than a
# hypothetical one.
assert_eq "stale count: 'all six fields' is gone" "0" "$(phrase_hits 'all six fields')"
assert_eq "stale count: 'base six' is gone"       "0" "$(phrase_hits 'base six')"
assert_eq "stale count: 'six base fields' is gone" "0" "$(phrase_hits 'six base fields')"
assert_eq "stale count: 'the six fields' is gone"  "0" "$(phrase_hits 'the six fields')"
# The frontend hedge (see the header). Denied by exact wording.
assert_eq "hedge: the conditional mandatoriness phrasing is gone" \
    "0" "$(phrase_hits 'when there is anything notable to say')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: rubrics are byte-identical to the e2e fixture copies ==="

FIXTURE_RUBRICS="$PROJECT_DIR/.claude/tests/e2e/fixtures/rubric-revision-loop/.claude/rubrics"
for r in default backend frontend devops bugfix; do
    a="$PROJECT_DIR/.claude/rubrics/$r.md"
    b="$FIXTURE_RUBRICS/$r.md"
    if cmp -s "$a" "$b"; then
        verdict="identical"
    else
        verdict="DRIFTED"
    fi
    assert_eq "rubric $r.md matches the rubric-revision-loop fixture copy" \
        "identical" "$verdict"
done

# The version bump is the thing most likely to be applied to one copy only,
# so pin it explicitly rather than relying on cmp alone to explain the break.
assert_eq "default rubric declares version 2 (C8 landed in v4.1)" \
    "1" "$(phrase_hits 'version: 2' "$PROJECT_DIR/.claude/rubrics/default.md")"

# ---------------------------------------------------------------------------
echo ""
echo "=== META-TEST A: a fence with context_coverage deleted must be flagged ==="

# The mutation happens on a COPY in a mktemp dir. The live prompt is never
# written to — an experiment that edits the tree under review changes the
# change-set hash out from under whoever is reviewing it.
META_DIR=$(mktemp -d -t ccp-meta.XXXXXX)
META_PROMPT="$META_DIR/backend.md"
cp "$PROJECT_DIR/.claude/agents/backend.md" "$META_PROMPT"

# Anchored on the field's own line text, never on a line number.
grep -v '"context_coverage": "<freeform notes>"' "$META_PROMPT" > "$META_DIR/stripped" \
    && mv "$META_DIR/stripped" "$META_PROMPT"

# 1. The mutation landed and did not decapitate the fence: the file still has
#    exactly one F7 block. (Removing the field also removes the trailing
#    comma's partner, so confirm the block still parses before concluding
#    anything from the key list.)
assert_eq "META-A: the mutated copy still has exactly one F7 fence" \
    "1" "$(f7_fence_count "$META_PROMPT")"
META_BODY=$(f7_fence "$META_PROMPT" 1)
assert_eq "META-A: the mutation landed (context_coverage no longer in the fence)" \
    "0" "$(printf '%s' "$META_BODY" | grep -c 'context_coverage' | tr -d '[:space:]')"

# 2. ...and the SAME checker section 2 uses now disagrees with the canonical
#    seven. This is the sensitivity proof: without it, section 2 could be
#    matching something that is true of any prompt.
assert_eq "META-A: the key-order checker flags the stripped fence" \
    "no" "$([ "$(fence_head7 "$META_BODY")" = "$CANONICAL" ] && echo yes || echo no)"

# 3. Control: the SHIPPED prompt still passes the same checker, so the
#    disagreement above is caused by the mutation and not by the checker.
assert_eq "META-A: control — the shipped backend.md still matches canonical" \
    "yes" "$([ "$(fence_head7 "$(f7_fence "$PROJECT_DIR/.claude/agents/backend.md" 1)")" = "$CANONICAL" ] && echo yes || echo no)"

# 4-5. THE DEVOPS GAP, reconstructed. The header claims section 1's census
#      would have caught a prompt with no contract section at all; prove it
#      rather than assert it. Strip every fenced json block from a copy of
#      devops.md — that is the shape the file actually had through v4.0 — and
#      confirm the census checker returns 0 where the shipped file returns 1.
META_NOFENCE="$META_DIR/devops-nofence.md"
awk '
    /^```json[[:space:]]*$/ { skip = 1; next }
    /^```[[:space:]]*$/ && skip { skip = 0; next }
    skip { next }
    { print }
' "$PROJECT_DIR/.claude/agents/devops.md" > "$META_NOFENCE"

assert_eq "META-A: the fence-stripping mutation landed (copy is shorter than the original)" \
    "shorter" \
    "$([ "$(wc -l < "$META_NOFENCE")" -lt "$(wc -l < "$PROJECT_DIR/.claude/agents/devops.md")" ] && echo shorter || echo same)"
assert_eq "META-A: the census flags a devops.md with no contract block (the v4.0 gap)" \
    "0" "$(f7_fence_count "$META_NOFENCE")"

# ---------------------------------------------------------------------------
echo ""
echo "=== META-TEST B: stale-count and hedge fixtures must be flagged ==="

# Section 5 asserts phrases are ABSENT. An absence assertion that has never
# been seen to fire is indistinguishable from a typo in the needle, so prove
# the scanner fires on text that carries each shape.
META_STALE="$META_DIR/stale-doc.md"
cat > "$META_STALE" <<'FIXTURE'
The contract is enforced by convention, not schema validation — the QA gate
doesn't reject missing fields, but the QA agent's review checklist asks "did
the specialist return all six fields?" and that question being honest is part
of QA approving.
FIXTURE

META_HEDGE="$META_DIR/hedge-doc.md"
# The hedge stays on ONE line: grep -F does not match across a newline, so a
# wrapped fixture would silently prove nothing.
cat > "$META_HEDGE" <<'FIXTURE'
The llm_observations field is mandatory: it is the channel for everything the
typed schema doesn't capture.
Never leave it empty when there is anything notable to say.
FIXTURE

assert_eq "META-B: the scanner flags a doc still saying 'all six fields'" \
    "1" "$(phrase_hits 'all six fields' "$META_STALE")"
assert_eq "META-B: ...and the shipped tree does not (the fixture is the only hit)" \
    "0" "$(phrase_hits 'all six fields')"
assert_eq "META-B: the scanner flags a doc still carrying the hedge" \
    "1" "$(phrase_hits 'when there is anything notable to say' "$META_HEDGE")"
assert_eq "META-B: ...and the shipped tree does not" \
    "0" "$(phrase_hits 'when there is anything notable to say')"

rm -rf "$META_DIR"

# --- Summary -------------------------------------------------------------

printf '\nTotal: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    printf 'Failed assertions:\n'
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

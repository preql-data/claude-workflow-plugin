#!/bin/bash
# Unit-test fixture for .claude/scripts/qa-gate.sh `grade-record` subcommand
# and the rubric-label plumbing in `enter` / `approve` / `status`
# (spec Phase A / claude-workflow-plugin-l1r.1).
#
# Covers:
#   1. enter side effects:
#      - rubric-pending is set alongside qa-gate-entered.
#      - re-enter on a task that previously had rubric-satisfied clears it
#        (a fresh cycle invalidates the prior verdict).
#   2. grade-record happy paths:
#      - satisfied verdict: comment posted with shape
#        "RUBRIC <v> iteration <n>: satisfied — all criteria pass";
#        rubric-pending removed; rubric-satisfied added.
#      - needs_revision verdict: comment posted with the failed criterion
#        names; labels unchanged (the qa-blocked round-trip is the QA
#        agent's move, not grade-record's).
#   3. grade-record malformed input:
#      - missing required key (verdict)
#      - verdict not in the satisfied|needs_revision enum
#      - criterion_results not an array
#      - iteration not a number
#      Each exits non-zero with a STRUCTURED JSON error envelope naming
#      the offender via error_key.
#   4. approve with rubric-pending still set:
#      - approve still succeeds (principle 6: Stop-hook contract untouched)
#      - the JSON observations include a loud WARNING.
#      - rubric-pending is cleared (cycle ends), rubric-satisfied (if any)
#        is preserved as audit trail.
#   5. status output exposes rubric state.
#   6. Every rubric file under .claude/rubrics/ declares the version the
#      per-file expectation table names (default=2 since v4.1's C8; the four
#      overlays stay at 1; the standalone design.md rubric — v5.0.0 Phase D2
#      Part A, claude-workflow-plugin-fkm.4, no extends: — is 1 too), plus a
#      META-TEST that a stale-version fixture is flagged by the same
#      extractor, plus design.md's own structural checks: no extends:,
#      name: design, and exactly the eight DS1-DS8 criterion headings (with
#      its own META-TEST proving a 7-heading fixture is caught).
#   7. META-TEST: a stubbed qa-gate.sh with the satisfied-branch label
#      calls removed asserts the rubric-satisfied test FAILS — proving
#      the assertion is sensitive to the script's label-flip behaviour,
#      not vacuous.
#
# Conventions mirror .claude/scripts/tests/qa-gate-choose.test.sh —
# plain bash, `set -u`, assert helpers, trailing summary, tempdir
# fixture with a pass-through bd shim (it carried --no-daemon until bd 1.1.2
# removed the flag along with the daemon).
#
# Exit codes:
#   0  every assertion passed
#   1  at least one assertion failed
#
# Usage:
#   bash .claude/scripts/tests/qa-gate-grade-record.test.sh
#   bash .claude/scripts/tests/qa-gate-grade-record.test.sh --keep

# shellcheck disable=SC2317
# Same rationale as the other tests in this dir: assert_* helpers and
# scenario bodies are reached via control flow (set -u + early-exit +
# subshells) the static analyzer can't follow. Disabled file-wide.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

KEEP_FIXTURE=0
[ "${1:-}" = "--keep" ] && KEEP_FIXTURE=1

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

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' \
            "$name" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s (unexpected match)\n    needle:   %s\n    haystack: %s\n' \
            "$name" "$needle" "$haystack"
    fi
}

# ---------------------------------------------------------------------------
# Fixture setup. Mirror qa-gate-choose.test.sh's pattern.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)/.."
PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"
FIXTURE=$(mktemp -d -t qa-gate-grade.XXXXXX)
TEST_HOME=$(mktemp -d -t qa-gate-grade-home.XXXXXX)

# shellcheck disable=SC2329  # cleanup invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\nTest HOME: %s\n' "$FIXTURE" "$TEST_HOME"
    else
        rm -rf "$FIXTURE" "$TEST_HOME"
    fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.beads" "$TEST_HOME/.claude/projects" "$FIXTURE/bin"

cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

# No BD_SHIM_ONLY skip arm any more (a9hh): CI installs the real bd, and a
# bd-less environment is a hard failure everywhere.
if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — qa-gate-grade-record tests require Beads."
    exit 1
fi

# bd wrapper: a pass-through so the fixture has one PATH-controlled bd. It
# injected --no-daemon until bd 1.1.2 removed the flag (and the daemon: 1.1.x
# runs an in-process embedded Dolt engine, so there is no tempdir race left).
REAL_BD=$(command -v bd)
cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"
export PATH="$FIXTURE/bin:$PATH"

cd "$FIXTURE" && bd init >/dev/null 2>&1

export CLAUDE_PROJECT_DIR="$FIXTURE"
export HOME="$TEST_HOME"

QG="$FIXTURE/.claude/scripts/qa-gate.sh"

# V3 (claude-workflow-plugin-jio.1): seed the records that make a task
# APPROVABLE. `qa-gate.sh approve` now REFUSES unless the task carries a review
# artifact whose reviewer differs from every recorded IMPLEMENTER and has no
# open finding at/above its risk_threshold (review-check.sh gate). This fixture
# has no live spawn and no reviewer, so the approve-path assertions below have
# to model the real flow: the IMPLEMENTER comment subagent-start.sh writes on
# spawn, plus a qa-claude artifact recorded through the REAL review-record
# writer (so a grammar change breaks the seed loudly instead of silently
# drifting). reviewed_hash is pinned to the current canonical change-set hash
# so no staleness warning is emitted into the observations under test.
seed_review_records() {
    local tid="$1" reviewer="${2:-qa-claude}" role="${3:-backend}"
    local ts hash art
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1 \
        || bd comment add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1 \
        || return 1

    # v5 D2 Part B (claude-workflow-plugin-fkm.4) MIGRATION: approve now ALSO
    # refuses (exit 2, no_design_attempted) without a satisfied, independent
    # DESIGN-REVIEW verdict, unless --no-design. Section 6's subject is the
    # RUBRIC warning approve emits, which is only observable on an approve
    # that SUCCEEDS — same reasoning the P7 completion-record migration
    # states just below — so the design precondition has to be satisfied
    # here too, seeded through the real writers.
    local design_sanitized design_art design_hash
    design_sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
    mkdir -p "$FIXTURE/docs/specs" 2>/dev/null || true
    design_art="$FIXTURE/docs/specs/$design_sanitized.md"
    cat > "$design_art" <<DESIGNDOC
# Design — $tid

## Problem
Seeded fixture design (qa-gate-grade-record harness only).

## Approaches considered
1. A second seed convention — rejected: no reuse to justify one.
2. This minimal artifact — chosen: matches every other seed helper here.

## Chosen approach
Seed a schema-valid design so approve's design-satisfied refusal does not
block a spec that is not testing it.

## Units
See the machine block.

## Global constraints
None.

## Out of scope
Everything this fixture does not seed.

## Verification plan
make test

## Revision log
- v1 seeded by the qa-gate-grade-record fixture.

<!-- DESIGN-UNITS BEGIN -->
\`\`\`json
{
  "contract_version": "1",
  "task_id": "$tid",
  "designer_identity": "designer",
  "units": [
    {
      "unit_id": "U1",
      "role": "$role",
      "goal": "seeded unit",
      "acceptance": [ { "id": "AC1", "text": "seeded fixture: nothing asserted" } ],
      "files": [ ".claude/scripts/qa-gate.sh" ],
      "verification": "make test",
      "depends_on": []
    }
  ]
}
\`\`\`
<!-- DESIGN-UNITS END -->
DESIGNDOC
    # v5 D3 (claude-workflow-plugin-fkm.5): design-record now refuses
    # grilling_record_missing without a GRILLING v1 record. This spec-local
    # helper seeds a minimal design ONLY so approve's design-satisfied
    # refusal does not block a spec that is not testing it (its own comment
    # above) — bypass rather than seed a real grilling record, since this
    # fixture never copies the vendor tree grilling-record would need to
    # hash.
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
        design-record "$tid" --no-grilling "qa-gate-grade-record.test.sh: seeding design-satisfied, not testing grilling" \
        >/dev/null 2>&1 || return 1
    design_hash=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/workflow-manifest.sh" hash-file "$design_art" 2>/dev/null) || design_hash=""
    if [ -z "$design_hash" ]; then return 1; fi
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
        design-review-record "$tid" --design-hash "$design_hash" \
        <<< '{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"seeded fixture"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}' \
        >/dev/null 2>&1 || return 1

    # claude-workflow-plugin-wob2 (L2): put a KNOWN, task-specific path into
    # the tracker BEFORE computing the hash this review pins itself to, not
    # just after (as the comment below this block already does once
    # review-record has written a new tracked file). Without this, the
    # tracker is still absent-or-empty at this exact point (nothing in this
    # fixture populates changed-files.txt directly), so impact-report.sh
    # --hash-only legitimately answers the SHA-256 empty-content digest — a
    # well-formed 64-hex string that review-check.sh validate-artifact now
    # refuses outright as reviewed_hash_unusable (a degradation sentinel
    # that would compare equal to itself forever; see that check's own
    # header).
    #
    # A DIRECT APPEND, NOT reconcile-tracker's git-status discovery: measured
    # (this task's own reproduction) that `reconcile-tracker` alone is not
    # reliable across this file's MULTIPLE seed_review_records calls (three,
    # for TID_E2/TID_AW/TID_AS in the same fixture, no commits ever made) —
    # the FIRST call's design doc makes `docs/` an untracked DIRECTORY, `git
    # status --porcelain` then collapses it to one opaque `?? docs/` line,
    # and once a later baseline capture records that line, EVERY path under
    # docs/ — including files that do not exist yet — reads as
    # "already-baselined, pre-existing dirt" forever after: reconcile then
    # finds nothing new to add and change_set_hash silently reverts to the
    # empty-set digest for the SECOND and THIRD calls, exactly the input
    # this check now refuses. Appending this task's own design_art path
    # directly sidesteps that git/baseline granularity question entirely —
    # it is the same direct-write shape run_cycle_pre_approve in
    # review-artifact-durability.sh already uses for identical reasons.
    mkdir -p "$FIXTURE/.claude/.qa-tracking" 2>/dev/null || true
    printf '%s\n' "$design_art" >> "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
    hash=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
    [ -z "$hash" ] && hash="unverified"
    art="$FIXTURE/.claude/.qa-tracking/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"%s","reviewer_model":"seeded-fixture","reviewer_pin":"seeded-fixture","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded fixture: acceptance criteria traced","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
        "$tid" "$reviewer" "$hash" > "$art"
    # claude-workflow-plugin-rqer (v5 D2): --file now asserts the CANONICAL
    # derived path; piped via stdin instead.
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
        review-record "$tid" < "$art" >/dev/null 2>&1 || return 1
    # claude-workflow-plugin-rqer (v5 D2): the artifact just written now lives
    # at a TRACKED path (docs/reviews/), so this fixture's git-visible dirt
    # includes it from this instant — but changed-files.txt does not know that
    # yet. If a caller lets this function return with the tracker still
    # absent-or-empty, the NEXT `approve` reconciles from a blank tracker via
    # `git status`, and 94d.1's change_set_reconstructed refusal fires
    # (measured: it names this fixture's own uncommitted `.claude/scripts/`
    # and `bin/` as dropped-as-baselined, because `bd create` auto-inits git
    # here and nothing in this fixture ever commits it). Append the artifact's
    # own path DIRECTLY (claude-workflow-plugin-wob2 — same reason and same
    # shape as the design_art append above: reconcile-tracker's git-status
    # discovery silently finds nothing once `docs/` has collapsed into one
    # opaque baselined directory line, which is exactly the state review-record
    # just created for the FIRST time on THIS task), then reconcile (for
    # anything else genuinely git-dirty) and regenerate the impact report so
    # approve's freshness check sees the WITH-artifact set rather than
    # refusing on staleness a moment later.
    if [ -f "$FIXTURE/.claude/scripts/impact-report.sh" ]; then
        printf '%s\n' "$FIXTURE/docs/reviews/$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json" \
            >> "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
        CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
            reconcile-tracker >/dev/null 2>&1 || true
        CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/impact-report.sh" \
            "$tid" >/dev/null 2>&1 || true
    fi
    # P7 (claude-workflow-plugin-qbhw) MIGRATION: approve additionally REFUSES
    # (exit 2, completion_record_missing) without a validated COMPLETION v1
    # record. Section 6's subject is the RUBRIC warning approve emits, which is
    # only observable on an approve that SUCCEEDS — so the completion
    # precondition has to be satisfied here rather than bypassed, or the
    # observations under test never get written. Seeded through the REAL writer.
    #
    # files_changed is [] because this fixture changes no files: the accurate
    # declaration, and it keeps approve's completeness cross-check (fkm.1.20)
    # from adding a WARNING to the very observations section 6 asserts on.
    local pay
    pay="$FIXTURE/.claude/.qa-tracking/completion-draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    printf '{"task_id":"%s","role":"%s","model":"seeded","pin":"seeded","files_changed":[],"tests_added":[],"decisions":["seeded fixture"],"blockers":[],"llm_observations":"seeded by the qa-gate-grade-record fixture","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown"}\n' \
        "$tid" "$role" > "$pay"
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
        completion-record "$tid" --file "$pay" >/dev/null 2>&1
}

# Helper: read the current labels for a task as a comma-joined string.
labels_for() {
    local tid="$1"
    bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}

# Helper: count comments matching a regex on a task.
# Same version-tolerant reader the production scripts use: bd 1.1.2 returns
# only a comment_count on a plain `show --json` and needs --include-comments;
# bd 0.47.x rejects that flag but inlines .comments. Pin the chain, not the leg.
bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

comment_count_matching() {
    local tid="$1" pat="$2"
    bd_show_with_comments "$tid" \
        | jq -r --arg pat "$pat" \
            'if type == "array" then .[0].comments else .comments end // [] | map(select(.text | test($pat))) | length' \
        2>/dev/null || echo "0"
}

# Helper: pull the first comment matching a regex (or empty).
comment_first_matching() {
    local tid="$1" pat="$2"
    bd_show_with_comments "$tid" \
        | jq -r --arg pat "$pat" \
            'if type == "array" then .[0].comments else .comments end // [] | map(select(.text | test($pat))) | .[0].text // ""' \
        2>/dev/null || echo ""
}

# Helper: build a verdict JSON. Args:
#   $1 verdict (satisfied|needs_revision)
#   $2 iteration (number)
#   $3 rubric_version (string)
#   $4 optional override JSON snippet for criterion_results
#   $5 optional override for required_fixes
build_verdict() {
    local verdict="$1" iter="$2" rv="$3"
    local cr="${4:-}"
    local rf="${5:-}"
    if [ -z "$cr" ]; then
        if [ "$verdict" = "satisfied" ]; then
            cr='[{"criterion":"C1","pass":true,"justification":"matches SPEC"},{"criterion":"C2","pass":true,"justification":"user-behavior tests added"}]'
        else
            cr='[{"criterion":"C2","pass":false,"justification":"only mock-internal tests"},{"criterion":"C7","pass":false,"justification":"circular boundary-mock assertion"},{"criterion":"C1","pass":true,"justification":"behaviour ok"}]'
        fi
    fi
    [ -z "$rf" ] && rf='["Add a test asserting user-visible behavior","Extract the producer fixture and cite source"]'
    jq -nc \
        --arg verdict "$verdict" \
        --argjson cr "$cr" \
        --argjson rf "$rf" \
        --argjson it "$iter" \
        --arg rv "$rv" \
        '{verdict:$verdict,criterion_results:$cr,required_fixes:$rf,iteration:$it,rubric_version:$rv}'
}

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: enter sets rubric-pending; clears stale rubric-satisfied ==="

# 1.1 Fresh enter sets rubric-pending alongside qa-gate-entered.
TID_E1=$(bd create "enter fresh test" -t task -p 1 --json | jq -r '.id')
OUT=$(bash "$QG" enter "$TID_E1")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "enter fresh: status=entered" "entered" "$STATUS"
LABELS=$(labels_for "$TID_E1")
assert_contains "enter fresh: qa-gate-entered set" "qa-gate-entered" "$LABELS"
assert_contains "enter fresh: rubric-pending set" "rubric-pending" "$LABELS"
assert_not_contains "enter fresh: rubric-satisfied NOT present" "rubric-satisfied" "$LABELS"
# Observation surfaces the new label.
OBS=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "enter fresh: observations mention rubric-pending" \
    "rubric-pending" "$OBS"

# 1.2 Re-enter on a task that has rubric-satisfied: stale rubric-satisfied
# is cleared (a fresh cycle is not yet satisfied), rubric-pending re-added.
TID_E2=$(bd create "enter stale rubric-satisfied test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_E2" >/dev/null
seed_review_records "$TID_E2"   # V3 (jio.1) MIGRATION
# Approve to clear the gate then plant rubric-satisfied as if from a
# prior cycle. We use bd label directly to avoid triggering the approve
# path's rubric-pending cleanup.
bash "$QG" approve "$TID_E2" "stage prior cycle as approved" >/dev/null
bd label add "$TID_E2" rubric-satisfied >/dev/null 2>&1
PRE=$(labels_for "$TID_E2")
assert_contains "enter stale: pre-condition rubric-satisfied present" \
    "rubric-satisfied" "$PRE"
# Also remove qa-approved so the re-enter codepath is the not-yet-entered
# branch (the qa-approved label would not block enter but it cleanly
# isolates the rubric-label behaviour from the qa-lifecycle behaviour).
bd label remove "$TID_E2" qa-approved >/dev/null 2>&1

# Re-enter.
OUT=$(bash "$QG" enter "$TID_E2")
LABELS=$(labels_for "$TID_E2")
assert_not_contains "enter stale: rubric-satisfied cleared on re-enter" \
    "rubric-satisfied" "$LABELS"
assert_contains "enter stale: rubric-pending re-set on re-enter" \
    "rubric-pending" "$LABELS"
OBS=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "enter stale: observations cite cleared stale rubric-satisfied" \
    "cleared stale rubric-satisfied" "$OBS"

# 1.3 Idempotent re-enter (already qa-gate-entered) on a task whose
# rubric-pending was somehow removed: rubric-pending is refreshed.
TID_E3=$(bd create "enter idempotent refresh test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_E3" >/dev/null
# Force-remove rubric-pending to simulate stale state.
bd label remove "$TID_E3" rubric-pending >/dev/null 2>&1
PRE=$(labels_for "$TID_E3")
assert_not_contains "enter idem: pre-condition rubric-pending absent" \
    "rubric-pending" "$PRE"

OUT=$(bash "$QG" enter "$TID_E3")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "enter idem: status=entered (idempotent)" "entered" "$STATUS"
LABELS=$(labels_for "$TID_E3")
assert_contains "enter idem: rubric-pending refreshed" "rubric-pending" "$LABELS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: grade-record happy path (satisfied) ==="

TID_S=$(bd create "grade-record satisfied test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_S" >/dev/null
PRE_LABELS=$(labels_for "$TID_S")
assert_contains "grade-record sat: pre-condition rubric-pending present" \
    "rubric-pending" "$PRE_LABELS"

VERDICT=$(build_verdict "satisfied" 1 "v1")

OUT=$(printf '%s' "$VERDICT" | bash "$QG" grade-record "$TID_S")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
OK=$(printf '%s' "$OUT" | jq -r '.ok')
assert_eq "grade-record sat: ok=true" "true" "$OK"
assert_eq "grade-record sat: status=satisfied" "satisfied" "$STATUS"

# Comment shape.
CMT_COUNT=$(comment_count_matching "$TID_S" "^RUBRIC v1 iteration 1: satisfied")
assert_eq "grade-record sat: RUBRIC comment posted (1 match)" "1" "$CMT_COUNT"
CMT_BODY=$(comment_first_matching "$TID_S" "^RUBRIC v1 iteration 1: satisfied")
assert_contains "grade-record sat: comment summary 'all criteria pass'" \
    "all criteria pass" "$CMT_BODY"

# Labels flipped.
LABELS=$(labels_for "$TID_S")
assert_not_contains "grade-record sat: rubric-pending removed" \
    "rubric-pending" "$LABELS"
assert_contains "grade-record sat: rubric-satisfied added" \
    "rubric-satisfied" "$LABELS"

# Observations.
OBS=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "grade-record sat: observations report label-flip" \
    "rubric-satisfied added=1" "$OBS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: grade-record happy path (needs_revision) ==="

TID_N=$(bd create "grade-record needs_revision test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_N" >/dev/null

VERDICT=$(build_verdict "needs_revision" 2 "v1")

# Pipe via stdin (the default agent-facing shape).
OUT=$(printf '%s' "$VERDICT" | bash "$QG" grade-record "$TID_N")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "grade-record nr: status=needs_revision" "needs_revision" "$STATUS"

# Comment shape: failed criterion names appear, NOT "all criteria pass".
CMT_BODY=$(comment_first_matching "$TID_N" "^RUBRIC v1 iteration 2: needs_revision")
assert_contains "grade-record nr: comment names failed C2" "C2" "$CMT_BODY"
assert_contains "grade-record nr: comment names failed C7" "C7" "$CMT_BODY"
assert_not_contains "grade-record nr: comment NOT 'all criteria pass'" \
    "all criteria pass" "$CMT_BODY"
assert_contains "grade-record nr: comment uses 'failed:' prefix" \
    "failed:" "$CMT_BODY"

# Labels unchanged: rubric-pending still set, rubric-satisfied still absent.
LABELS=$(labels_for "$TID_N")
assert_contains "grade-record nr: rubric-pending preserved" \
    "rubric-pending" "$LABELS"
assert_not_contains "grade-record nr: rubric-satisfied NOT added" \
    "rubric-satisfied" "$LABELS"
# And we do NOT touch qa-blocked here — the qa-blocked round-trip is
# the QA agent's move (qa-gate.sh block), not grade-record's.
assert_not_contains "grade-record nr: qa-blocked NOT auto-added" \
    "qa-blocked" "$LABELS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: grade-record --file variant ==="

TID_F=$(bd create "grade-record --file test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_F" >/dev/null

VFILE="$FIXTURE/.claude/.qa-tracking/verdict-via-file.json"
build_verdict "satisfied" 1 "v1" > "$VFILE"
OUT=$(bash "$QG" grade-record "$TID_F" --file "$VFILE")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "grade-record --file: status=satisfied" "satisfied" "$STATUS"
LABELS=$(labels_for "$TID_F")
assert_contains "grade-record --file: rubric-satisfied added" \
    "rubric-satisfied" "$LABELS"

# Nonexistent file errors with a structured envelope.
OUT=$(bash "$QG" grade-record "$TID_F" --file /nonexistent/path 2>/dev/null || true)
EKEY=$(printf '%s' "$OUT" | jq -r '.error_key // ""')
assert_eq "grade-record --file: nonexistent file -> error_key=file_not_found" \
    "file_not_found" "$EKEY"
OK=$(printf '%s' "$OUT" | jq -r '.ok')
assert_eq "grade-record --file: nonexistent file -> ok=false" "false" "$OK"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: malformed input (structured errors) ==="

TID_M=$(bd create "grade-record malformed test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_M" >/dev/null

# 5.1 Missing verdict key.
BAD1='{"criterion_results":[],"required_fixes":[],"iteration":1,"rubric_version":"v1"}'
RC=0
OUT=$(printf '%s' "$BAD1" | bash "$QG" grade-record "$TID_M" 2>/dev/null) || RC=$?
assert_eq "malformed (missing verdict): exit non-zero" "1" "$RC"
EKEY=$(printf '%s' "$OUT" | jq -r '.error_key // ""')
assert_eq "malformed (missing verdict): error_key=missing_key:verdict" \
    "missing_key:verdict" "$EKEY"

# 5.2 verdict not in enum.
BAD2='{"verdict":"maybe","criterion_results":[],"required_fixes":[],"iteration":1,"rubric_version":"v1"}'
RC=0
OUT=$(printf '%s' "$BAD2" | bash "$QG" grade-record "$TID_M" 2>/dev/null) || RC=$?
assert_eq "malformed (bad verdict enum): exit non-zero" "1" "$RC"
EKEY=$(printf '%s' "$OUT" | jq -r '.error_key // ""')
assert_eq "malformed (bad verdict enum): error_key=verdict_invalid_enum" \
    "verdict_invalid_enum" "$EKEY"

# 5.3 criterion_results not an array.
BAD3='{"verdict":"satisfied","criterion_results":{"bad":true},"required_fixes":[],"iteration":1,"rubric_version":"v1"}'
RC=0
OUT=$(printf '%s' "$BAD3" | bash "$QG" grade-record "$TID_M" 2>/dev/null) || RC=$?
assert_eq "malformed (criterion_results object): exit non-zero" "1" "$RC"
EKEY=$(printf '%s' "$OUT" | jq -r '.error_key // ""')
assert_eq "malformed (criterion_results object): error_key=criterion_results_not_array" \
    "criterion_results_not_array" "$EKEY"

# 5.4 iteration not a number.
BAD4='{"verdict":"satisfied","criterion_results":[],"required_fixes":[],"iteration":"one","rubric_version":"v1"}'
RC=0
OUT=$(printf '%s' "$BAD4" | bash "$QG" grade-record "$TID_M" 2>/dev/null) || RC=$?
assert_eq "malformed (iteration string): exit non-zero" "1" "$RC"
EKEY=$(printf '%s' "$OUT" | jq -r '.error_key // ""')
assert_eq "malformed (iteration string): error_key=iteration_not_number" \
    "iteration_not_number" "$EKEY"

# 5.5 Not JSON at all.
RC=0
OUT=$(printf 'this is not json' | bash "$QG" grade-record "$TID_M" 2>/dev/null) || RC=$?
assert_eq "malformed (not JSON): exit non-zero" "1" "$RC"
EKEY=$(printf '%s' "$OUT" | jq -r '.error_key // ""')
assert_eq "malformed (not JSON): error_key=invalid_json" \
    "invalid_json" "$EKEY"

# 5.6 Empty stdin.
RC=0
OUT=$(printf '' | bash "$QG" grade-record "$TID_M" 2>/dev/null) || RC=$?
assert_eq "malformed (empty stdin): exit non-zero" "1" "$RC"
EKEY=$(printf '%s' "$OUT" | jq -r '.error_key // ""')
assert_eq "malformed (empty stdin): error_key=empty_input" \
    "empty_input" "$EKEY"

# 5.7 Criterion_results item missing the criterion key.
BAD5='{"verdict":"needs_revision","criterion_results":[{"pass":false,"justification":"x"}],"required_fixes":[],"iteration":1,"rubric_version":"v1"}'
RC=0
OUT=$(printf '%s' "$BAD5" | bash "$QG" grade-record "$TID_M" 2>/dev/null) || RC=$?
assert_eq "malformed (item missing criterion): exit non-zero" "1" "$RC"
EKEY=$(printf '%s' "$OUT" | jq -r '.error_key // ""')
assert_match "malformed (item missing criterion): error_key flags bad criterion" \
    "criterion_results_item_invalid" "$EKEY"

# 5.8 Missing task id (positional).
RC=0
OUT=$(bash "$QG" grade-record 2>/dev/null) || RC=$?
assert_eq "malformed (no task id): exit non-zero" "1" "$RC"

# 5.9 Unknown flag.
RC=0
OUT=$(printf '{}' | bash "$QG" grade-record "$TID_M" --weird-flag 2>/dev/null) || RC=$?
assert_eq "malformed (unknown flag): exit non-zero" "1" "$RC"
EKEY=$(printf '%s' "$OUT" | jq -r '.error_key // ""')
assert_eq "malformed (unknown flag): error_key=unknown_flag" \
    "unknown_flag" "$EKEY"

# Labels untouched by every failure path.
LABELS=$(labels_for "$TID_M")
assert_contains "malformed: rubric-pending preserved across failures" \
    "rubric-pending" "$LABELS"
assert_not_contains "malformed: rubric-satisfied NOT added" \
    "rubric-satisfied" "$LABELS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: approve with rubric-pending still set warns loudly ==="

# Scenario A: approve with rubric-pending (no satisfied verdict).
TID_AW=$(bd create "approve-with-pending warning test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_AW" >/dev/null
bd label add "$TID_AW" qa-pending >/dev/null 2>&1

# Sanity: rubric-pending is set, rubric-satisfied is not.
PRE_LABELS=$(labels_for "$TID_AW")
assert_contains "approve-warn: pre-condition rubric-pending set" \
    "rubric-pending" "$PRE_LABELS"
assert_not_contains "approve-warn: pre-condition rubric-satisfied absent" \
    "rubric-satisfied" "$PRE_LABELS"

seed_review_records "$TID_AW"   # V3 (jio.1) MIGRATION
OUT=$(bash "$QG" approve "$TID_AW" "Override: deferred Phase A rubric for plumbing-only commit.")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
OK=$(printf '%s' "$OUT" | jq -r '.ok')
# Approve still succeeds (principle 6: rubric is NOT a gate).
assert_eq "approve-warn: ok=true (still approves)" "true" "$OK"
assert_eq "approve-warn: status=approved" "approved" "$STATUS"

# The WARNING is loud in observations.
OBS=$(printf '%s' "$OUT" | jq -r '.observations')
assert_match "approve-warn: observations contain WARNING" \
    "WARNING" "$OBS"
assert_contains "approve-warn: observations mention rubric-pending" \
    "rubric-pending" "$OBS"
assert_contains "approve-warn: observations mention override reason expectation" \
    "override reason" "$OBS"

# rubric-pending is cleared (cycle ends).
LABELS=$(labels_for "$TID_AW")
assert_not_contains "approve-warn: rubric-pending cleared on approve" \
    "rubric-pending" "$LABELS"
# qa-approved set, qa-gate-entered + qa-pending removed.
assert_contains "approve-warn: qa-approved set" "qa-approved" "$LABELS"
assert_not_contains "approve-warn: qa-gate-entered removed" \
    "qa-gate-entered" "$LABELS"

# Scenario B: approve with rubric-satisfied (the happy path).
TID_AS=$(bd create "approve-with-satisfied audit-trail test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_AS" >/dev/null
bd label add "$TID_AS" qa-pending >/dev/null 2>&1

# claude-workflow-plugin-wob2 (L2): seed BEFORE grading, not after. "The happy
# path" this scenario names means "nothing changed since grading" — that is
# only TRUE if the change set grade-record binds to is the SAME one approve
# later sees. seed_review_records populates changed-files.txt (design_art,
# then the review artifact) and regenerates the persisted impact report as
# its last step; grade-record with no --graded-hash falls back to "live
# recompute, corroborated by the persisted impact report" (cmd_grade_record's
# own comment) — so calling it AFTER seeding means both the live and the
# persisted hash already reflect the fully-seeded tracker, and grade-record
# binds to that same real hash rather than to the fixture's pre-seed empty
# one. Calling it BEFORE (the previous order) bound the RUBRIC record to the
# empty-set hash honestly captured at that instant, then seeding added two
# more tracked paths afterward — a REAL "the change set moved after grading"
# event, which is exactly what the mismatch warning below exists to catch;
# it was firing correctly, the fixture's ordering was what made "the happy
# path" not actually happy.
seed_review_records "$TID_AS"   # V3 (jio.1) MIGRATION
# Record a satisfied verdict to set rubric-satisfied.
VERDICT=$(build_verdict "satisfied" 1 "v1")
printf '%s' "$VERDICT" | bash "$QG" grade-record "$TID_AS" >/dev/null

OUT=$(bash "$QG" approve "$TID_AS" "All criteria passed per RUBRIC v1 iteration 1.")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "approve-sat: status=approved" "approved" "$STATUS"
OBS=$(printf '%s' "$OUT" | jq -r '.observations')
# claude-workflow-plugin-wob2 (L2): a bare "no WARNING at all" check is no
# longer correct to ask for here. review-record's own reviewed_hash is
# necessarily computed BEFORE its artifact file exists — the artifact
# cannot be hashed into a change set that does not yet contain it — so once
# that artifact's own path lands in the tracker (seed_review_records' own
# post-write reconcile, same as production's review-record + reconcile
# flow), approve's D6 staleness note ALWAYS fires for a genuine review:
# "the review artifact recorded reviewed_hash=X but this approval binds
# change_set_hash=Y" is not a defect, it is the audited-never-blocking
# behaviour cmd_approve's own D6 comment documents. What THIS scenario
# actually asserts — the one thing that must NOT reappear once grading and
# seeding are correctly ordered (see the comment above seed_review_records's
# call, this section) — is the RUBRIC mismatch warning specifically, so
# check for its exact, distinguishing text rather than the word "WARNING"
# in general, which the unrelated and expected review-staleness note also
# contains.
assert_not_contains "approve-sat: observations do not contain the RUBRIC mismatch warning" \
    "rubric-satisfied is set, but the satisfied verdict binds a DIFFERENT change set" "$OBS"
assert_contains "approve-sat: observations cite preserved audit trail" \
    "rubric-satisfied preserved" "$OBS"

# rubric-satisfied preserved (audit trail), rubric-pending absent.
LABELS=$(labels_for "$TID_AS")
assert_contains "approve-sat: rubric-satisfied preserved" \
    "rubric-satisfied" "$LABELS"
assert_not_contains "approve-sat: rubric-pending absent" \
    "rubric-pending" "$LABELS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: status exposes rubric state ==="

TID_ST=$(bd create "status rubric-state test" -t task -p 1 --json | jq -r '.id')

# 7.1 not-entered: rubric=none.
OUT=$(bash "$QG" status "$TID_ST")
OBS=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "status not-entered: rubric=none" "rubric=none" "$OBS"

# 7.2 entered: rubric=pending.
bash "$QG" enter "$TID_ST" >/dev/null
OUT=$(bash "$QG" status "$TID_ST")
OBS=$(printf '%s' "$OUT" | jq -r '.observations')
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "status entered: status=entered" "entered" "$STATUS"
assert_contains "status entered: rubric=pending" "rubric=pending" "$OBS"

# 7.3 after satisfied verdict: rubric=satisfied.
VERDICT=$(build_verdict "satisfied" 1 "v1")
printf '%s' "$VERDICT" | bash "$QG" grade-record "$TID_ST" >/dev/null
OUT=$(bash "$QG" status "$TID_ST")
OBS=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "status post-satisfied: rubric=satisfied" "rubric=satisfied" "$OBS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: structural sanity of .claude/rubrics/ files ==="

RUBRICS_DIR="$PLUGIN_DIR/.claude/rubrics"
EXPECTED_RUBRICS=(default backend frontend devops bugfix design)

# Per-file EXPECTED version. Through v4.0 this loop grepped one hardcoded
# literal for all five files, which quietly asserted "every rubric is on the
# same version" — a property nobody wanted and which went red the first time
# a single rubric was revised on its own (v4.1 / C2 added criterion C8 for
# `context_coverage` to default.md and bumped it to 2; the four overlays were
# untouched and stay at 1). A table makes each rubric's version a deliberate,
# independently-editable fact, and a NEW rubric file that nobody adds here
# fails rather than inheriting someone else's number. `design=1` (v5.0.0
# Phase D2 Part A) joined the same way: standalone, not an overlay, but its
# version is exactly as deliberate a fact as any of the other five.
RUBRIC_VERSIONS="default=2 backend=1 frontend=1 devops=1 bugfix=1 design=1"

# expected_rubric_version <name> — the table's value; exit 1 (empty output)
# when the rubric is absent from the table.
# Deliberately no `case` here: `$(case … esac)` parses under `bash -n` and
# passes shellcheck but dies at runtime, and this function is only ever
# called inside a command substitution.
expected_rubric_version() {
    _erv_want="$1"
    for _erv_pair in $RUBRIC_VERSIONS; do
        if [ "${_erv_pair%%=*}" = "$_erv_want" ]; then
            printf '%s' "${_erv_pair#*=}"
            return 0
        fi
    done
    return 1
}

# rubric_version_of <file> — the frontmatter version as a bare number, or
# empty when absent/malformed. Takes a FILE so the META-TEST below runs the
# identical extraction against a deliberately-wrong fixture.
rubric_version_of() {
    [ -f "$1" ] || return 1
    head -10 "$1" \
        | sed -n 's/^version:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' \
        | head -1
}

for r in "${EXPECTED_RUBRICS[@]}"; do
    f="$RUBRICS_DIR/$r.md"
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("rubric file missing: $r.md")
        printf '  FAIL: rubric file missing: %s\n' "$f"
        continue
    fi
    # Frontmatter must be present and declare the version the table expects.
    head1=$(head -1 "$f")
    assert_eq "rubric $r.md: frontmatter opens with ---" "---" "$head1"
    want=$(expected_rubric_version "$r") || want=""
    got=$(rubric_version_of "$f") || got=""
    assert_eq "rubric $r.md: frontmatter declares version $want" "$want" "$got"
done

# META-TEST: the version check is only worth having if a WRONG version fails
# it. Feed the identical extractor a fixture rubric that declares version 1
# where the table says default is 2, and confirm the comparison disagrees.
# Anchored on the frontmatter text, never on a line number.
META_RUBRIC=$(mktemp -t rubric-version-meta.XXXXXX)
cat > "$META_RUBRIC" <<'FIXTURE'
---
version: 1
name: default
---

# Default rubric (v1) — deliberately stale fixture, not a shipped file.
FIXTURE
meta_got=$(rubric_version_of "$META_RUBRIC") || meta_got=""
meta_want=$(expected_rubric_version default) || meta_want=""
# 1. the mutation landed: the fixture really does say 1.
assert_eq "META: stale fixture rubric really declares version 1" "1" "$meta_got"
# 2. and the table really expects something else, so the check fires.
assert_eq "META: the table expects 2 for default, so the stale fixture is flagged" \
    "no" "$([ "$meta_got" = "$meta_want" ] && echo yes || echo no)"
# 3. control: the SHIPPED default.md agrees with the table (the check is not
#    simply always-disagreeing).
assert_eq "META: control — shipped default.md matches the table" \
    "yes" "$([ "$(rubric_version_of "$RUBRICS_DIR/default.md")" = "$meta_want" ] && echo yes || echo no)"
rm -f "$META_RUBRIC"

# Domain rubrics declare extends: default in frontmatter.
for r in backend frontend devops; do
    if head -10 "$RUBRICS_DIR/$r.md" | grep -qE '^extends:[[:space:]]*default[[:space:]]*$'; then
        PASS=$((PASS + 1))
        printf '  PASS: rubric %s.md: extends: default declared\n' "$r"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("rubric $r.md: missing extends: default")
        printf '  FAIL: rubric %s.md: missing "extends: default"\n' "$r"
    fi
done

# bugfix overlay declares applies_to: bug.
if head -10 "$RUBRICS_DIR/bugfix.md" | grep -qE '^applies_to:[[:space:]]*bug[[:space:]]*$'; then
    PASS=$((PASS + 1))
    printf '  PASS: rubric bugfix.md: applies_to: bug declared\n'
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("rubric bugfix.md: missing applies_to: bug")
    printf '  FAIL: rubric bugfix.md: missing "applies_to: bug"\n'
fi

# design.md (v5.0.0 Phase D2 Part A, claude-workflow-plugin-fkm.4) is
# STANDALONE — the opposite assertion from the extends: loop above. Pulling
# code-review criteria into a design review is a category error, so this
# rubric must NOT declare extends: default the way backend/frontend/devops
# do.
DESIGN_RUBRIC="$RUBRICS_DIR/design.md"
if [ -f "$DESIGN_RUBRIC" ] && ! head -10 "$DESIGN_RUBRIC" | grep -qE '^extends:'; then
    PASS=$((PASS + 1))
    printf '  PASS: rubric design.md: does NOT declare extends: (standalone)\n'
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("rubric design.md: unexpectedly declares extends: (should be standalone)")
    printf '  FAIL: rubric design.md: unexpectedly declares extends: (should be standalone)\n'
fi

# design.md declares name: design (no other rubric's name: is asserted here
# individually — filename and `name:` never drifted apart for the other
# five, but design.md is new enough that nothing else in the tree checks it
# yet, so it is worth asserting explicitly rather than trusting the loop
# above, which only checks version).
if head -10 "$DESIGN_RUBRIC" | grep -qE '^name:[[:space:]]*design[[:space:]]*$'; then
    PASS=$((PASS + 1))
    printf '  PASS: rubric design.md: name: design declared\n'
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("rubric design.md: missing name: design")
    printf '  FAIL: rubric design.md: missing "name: design"\n'
fi

# design.md declares exactly the eight DS1-DS8 criteria (AC 4.2 of
# claude-workflow-plugin-fkm.4). Anchored on the heading grammar
# ("### DS<n>."), never on a line count, the same anchoring convention this
# section already uses for `version:`/`extends:`/`applies_to:`.
ds_heading_count=$(grep -cE '^### DS[1-8]\.' "$DESIGN_RUBRIC")
assert_eq "rubric design.md: exactly 8 DS1-DS8 criterion headings" "8" "$ds_heading_count"

# META-TEST: the DS-count check is only worth having if a design.md with one
# criterion missing is flagged. Built the same way the version META-TEST
# above builds its stale fixture — a throwaway file, never the shipped one.
META_DS_RUBRIC=$(mktemp -t design-rubric-ds-meta.XXXXXX)
{
    printf -- '---\nversion: 1\nname: design\n---\n\n# Design rubric (deliberately incomplete fixture, not shipped)\n\n'
    for n in 1 2 3 4 5 6 7; do
        printf '### DS%d. Placeholder criterion %d.\n\nBody text.\n\n' "$n" "$n"
    done
} > "$META_DS_RUBRIC"
meta_ds_count=$(grep -cE '^### DS[1-8]\.' "$META_DS_RUBRIC")
# 1. the mutation landed: the fixture really declares 7, not 8.
assert_eq "META: 7-criterion fixture really declares 7 DS headings" "7" "$meta_ds_count"
# 2. the check disagrees with the fixture (the assertion above WOULD fail).
assert_eq "META: the count check would flag the 7-criterion fixture" "no" \
    "$([ "$meta_ds_count" = "8" ] && echo yes || echo no)"
# 3. control: the SHIPPED design.md still declares all 8.
assert_eq "META: control — shipped design.md still declares all 8" "yes" \
    "$([ "$(grep -cE '^### DS[1-8]\.' "$DESIGN_RUBRIC")" = "8" ] && echo yes || echo no)"
rm -f "$META_DS_RUBRIC"

# Rubric-config has the iteration_cap key.
RUBRIC_CONFIG="$PLUGIN_DIR/.claude/rubric-config"
if [ -f "$RUBRIC_CONFIG" ] && grep -qE '^iteration_cap=3[[:space:]]*$' "$RUBRIC_CONFIG"; then
    PASS=$((PASS + 1))
    printf '  PASS: .claude/rubric-config: iteration_cap=3 declared\n'
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=(".claude/rubric-config: iteration_cap=3 missing")
    printf '  FAIL: .claude/rubric-config: iteration_cap=3 missing\n'
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9: META-TEST — stub the label flip, assert satisfied test FAILS ==="

# Build a stubbed qa-gate.sh whose satisfied-branch label calls are
# neutered. We snip the two lines that drive the label flip on the
# satisfied path:
#   remove_rubric_pending "$tid" || removed_pending=0
#   if ! add_label "$tid" "rubric-satisfied"; then
# Replace with no-ops so the comment is still posted but the labels
# never change. If the rubric-satisfied assertion in Section 2 was
# vacuous (e.g. checking a label that always exists), the stubbed
# script would still pass it. The point of the META-TEST is to prove
# that assertion fails when the production behavior is mutated.

STUB_DIR=$(mktemp -d -t qa-gate-grade-meta.XXXXXX)
mkdir -p "$STUB_DIR/.claude/scripts" "$STUB_DIR/.claude/.qa-tracking" "$STUB_DIR/.beads"
cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$STUB_DIR/.claude/scripts/"
chmod +x "$STUB_DIR/.claude/scripts/"*.sh

# Use awk to comment out the two satisfied-branch label-flip lines.
# The lines we're targeting (verbatim from the source):
#   remove_rubric_pending "$tid" || removed_pending=0
#   if ! add_label "$tid" "rubric-satisfied"; then
# We replace them with a no-op that preserves the surrounding control
# flow (the `if` block needs to stay parseable). The simplest mutation
# that achieves this is to swap the add_label call for a shell-builtin
# `true` (always succeeds), so the if-branch never fires and the label
# is never set. We use the builtin rather than /bin/true because the
# path is not portable across macOS (/usr/bin/true) and Linux.

STUB_QG="$STUB_DIR/.claude/scripts/qa-gate.sh"
# Mutation 1: replace the remove_rubric_pending call line with a no-op
# colon command. We use awk so the match is anchored on the literal
# source line rather than relying on sed's regex semantics.
awk '
    /^        remove_rubric_pending "\$tid" \|\| removed_pending=0$/ {
        print "        : # META-TEST stubbed: remove_rubric_pending neutralized"
        next
    }
    { print }
' "$STUB_QG" > "$STUB_QG.tmp" && mv "$STUB_QG.tmp" "$STUB_QG"

# Mutation 2: replace the add_label rubric-satisfied conditional with a
# call to shell builtin `true` (always returns 0), so the if-branch
# never fires and rubric-satisfied is never added.
awk '
    /^        if ! add_label "\$tid" "rubric-satisfied"; then$/ {
        print "        if ! true; then  # META-TEST stubbed: add_label rubric-satisfied neutralized"
        next
    }
    { print }
' "$STUB_QG" > "$STUB_QG.tmp" && mv "$STUB_QG.tmp" "$STUB_QG"
chmod +x "$STUB_QG"

# Sanity: confirm the mutation actually landed in the file. If both
# patterns matched, we expect "META-TEST stubbed" to appear twice. A
# count of zero would mean the line shape drifted and the mutation
# was a no-op — that is the wrong kind of META-TEST failure.
MUT_COUNT=$(grep -c "META-TEST stubbed" "$STUB_QG" 2>/dev/null || echo "0")
if [ "$MUT_COUNT" -lt 2 ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST: mutation did not land (count=$MUT_COUNT, expected 2). The qa-gate.sh source lines may have drifted from the awk patterns above.")
    printf '  FAIL: META-TEST: mutation count=%d (expected 2). Update the awk patterns in this test if you edited the satisfied-branch shape.\n' "$MUT_COUNT"
fi

# Sanity: shellcheck must still be happy with the mutated file (the test
# fails for the WRONG reason if the mutation breaks parsing). We use
# bash -n which is always on PATH.
if ! bash -n "$STUB_QG"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST: stubbed qa-gate.sh failed bash -n; mutation broke parsing")
    printf '  FAIL: META-TEST: stubbed qa-gate.sh failed bash -n\n'
else
    PASS=$((PASS + 1))
    printf '  PASS: META-TEST: stubbed qa-gate.sh parses\n'
fi

# Stand up a fresh Beads workspace inside STUB_DIR so the stub does not
# bleed back into the main FIXTURE's labels (the bd state would be
# shared otherwise).
mkdir -p "$STUB_DIR/bin"
cat > "$STUB_DIR/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} "\$@"
EOF
chmod +x "$STUB_DIR/bin/bd"

# Run the bd init + scenario in a subshell so the env mutations (PATH,
# CLAUDE_PROJECT_DIR) don't leak out.
(
    set -u
    export PATH="$STUB_DIR/bin:$PATH"
    cd "$STUB_DIR" && bd init >/dev/null 2>&1
    export CLAUDE_PROJECT_DIR="$STUB_DIR"
    TID_MT=$(bd create "META-TEST stubbed satisfied" -t task -p 1 --json | jq -r '.id')
    bash "$STUB_QG" enter "$TID_MT" >/dev/null
    VERDICT='{"verdict":"satisfied","criterion_results":[{"criterion":"C1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":1,"rubric_version":"v1"}'
    # Run grade-record under the stub.
    printf '%s' "$VERDICT" | bash "$STUB_QG" grade-record "$TID_MT" >/dev/null
    # The stubbed script should leave rubric-satisfied UNSET (because the
    # add_label call was neutralized). The META-TEST passes if the absence
    # holds — which is the failure mode the production assertion catches.
    STUB_LABELS=$(bd show "$TID_MT" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")')
    printf '%s\n' "$STUB_LABELS"
) > "$STUB_DIR/meta-labels.txt"
STUB_LABELS=$(cat "$STUB_DIR/meta-labels.txt" 2>/dev/null || echo "")

# Assertion: rubric-satisfied is ABSENT under the stub. If this holds,
# the production assertion in Section 2 ("rubric-satisfied added") is
# sensitive — mutating the label-flip out of the script breaks the
# production assertion as expected.
if printf '%s' ",$STUB_LABELS," | grep -q ',rubric-satisfied,'; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST: stubbed script STILL sets rubric-satisfied (mutation ineffective)")
    printf '  FAIL: META-TEST: stubbed script still sets rubric-satisfied; the mutation did not land. labels=%s\n' "$STUB_LABELS"
else
    PASS=$((PASS + 1))
    printf '  PASS: META-TEST: stubbed script does NOT set rubric-satisfied (production assertion in Section 2 would fail here, confirming sensitivity)\n'
fi

# The load-bearing META-TEST assertion is the rubric-satisfied absence
# above. We deliberately do NOT also re-check the comment path here:
# the comment is asserted in Section 2's happy-path test, and adding a
# second comment-shape check under the stub would conflate two
# mutations (label-flip vs comment-post). Localised mutations make
# localised failure signals.

rm -rf "$STUB_DIR"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf 'Passed: %d\n' "$PASS"
printf 'Failed: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0

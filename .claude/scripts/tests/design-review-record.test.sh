#!/bin/bash
# design-review-record.test.sh — v5 Phase D2 Part B (claude-workflow-plugin-
# fkm.4): the design-verdict recording subcommand, amendments, the
# design-satisfied refusal at approve, and the cap_terminated predicate.
#
# WHAT THIS COVERS, and why each part needs a test of its own:
#
#   1. qa-gate.sh `design-review-record` — shape validation, inline, mirroring
#      cmd_grade_record's own required-key loop (no second parser: there is
#      no "review-check.sh validate-X" for a verdict, on either the code or
#      the design side).
#
#   2. Independence (AC 4.4 / pairing plan P3): a verdict whose
#      reviewer_identity equals the designer= on the task's latest
#      DESIGN-ARTIFACT record is refused AT RECORD TIME, before anything is
#      written — not deferred to approve.
#
#   3. Amendments (B2 / P6): iteration must ADVANCE past the latest recorded
#      one (a duplicate is refused, non-vacuously — the record count is
#      unchanged), and a genuine revision (design_hash moved) carries
#      `[amends: <prev-hash>]`; an unchanged re-review does not.
#
#   4. compute_design_satisfied via `design-gate-precheck` (B5): the shared
#      predicate's full status vocabulary, including the DELIBERATE asymmetry
#      between precheck (lenient on "no design at all") and approve (strict).
#
#   5. `qa-gate.sh approve`'s DESIGN-SATISFIED-REFUSAL (B3 / P1): unconditional
#      refusal without a satisfied, fresh, independent verdict — leaving the
#      task provably UNTOUCHED — the `--no-design` audited bypass, the
#      `design_verdict_hash=` machine token and its position in the record,
#      staleness -> refusal, and the METatest proving the block (not
#      something incidental) is what refuses: strip its sentinels from a
#      copy and watch the same task approve with no design verdict at all.
#      NOTE ON P2: the original pairing plan framed design-hash staleness as
#      "arm 2 of the ladder at qa-gate.sh:3717-3786" (DESIGN-BINDING-TOKEN)
#      converting to a refusal. D2 built a NEW, sibling block instead (see
#      that block's own header for why) — DESIGN-BINDING-TOKEN stays
#      observation-only. The FUNCTIONAL requirement P2 asks for (a stale
#      design_hash refuses approval) is what section 5 actually tests; it
#      just exercises a different code path than the plan's example named.
#
#   6. cap_terminated (B4 / P4): wired into REVIEW-SEPARATION, not a new
#      block — a review whose latest artifact stopped at a CAP refuses
#      (shares --no-review's bypass), a review that concluded on its own
#      terms (verdict or stop_condition) does not, and the has()-vs-`//`
#      reading discipline is verified directly against synthetic envelopes,
#      plus a METatest proving the arm is load-bearing.
#
#   7. The bjx scalar-class discipline (P5): a reviewer_identity containing a
#      character outside the declared class is REJECTED, never sanitised —
#      and a METatest removing that one guard line shows the CONCRETE
#      consequence a missing guard would have: the malformed record is
#      written, but the shipped READER (latest_design_review's own anchored
#      capture, which compute_design_satisfied depends on) then cannot see
#      it at all — the record becomes indistinguishable from "never
#      recorded", which is the "downstream anchored capture(...) mis-parses"
#      the pairing plan names.
#
# Exit codes: 0 all assertions passed | 1 one or more failed | 2 harness error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()
KEEP_FIXTURE="${KEEP_FIXTURE:-0}"
[ "${1:-}" = "--keep" ] && KEEP_FIXTURE=1

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
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
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' "$name" "$needle" "$haystack"
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
        printf '  FAIL: %s (unexpected match)\n    needle:   %s\n    haystack: %s\n' "$name" "$needle" "$haystack"
    fi
}

# ---------------------------------------------------------------------------
# Fixture. Same shape as design-artifact.test.sh: the real scripts, a real
# bd, a throwaway project root and HOME. `cd "$FIXTURE"` (no subshell) is the
# FAIL-CLOSED store-isolation mechanism this tier requires — BEADS_DIR alone
# is fail-open (falls back to the production store when the target is not
# already an initialised one), so every bd call below runs with this
# process's cwd inside the fixture, never via an env-var redirect alone.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t design-review-record.XXXXXX)
TEST_HOME=$(mktemp -d -t design-review-record-home.XXXXXX)

# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\nTest HOME: %s\n' "$FIXTURE" "$TEST_HOME"
    else
        chmod -R u+rwX "$FIXTURE" 2>/dev/null || true
        rm -rf "$FIXTURE" "$TEST_HOME"
    fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.beads" "$FIXTURE/bin" "$FIXTURE/docs/specs" \
    "$TEST_HOME/.claude/projects"

cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — design-review-record tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — design-review-record tests require jq."
    exit 2
fi

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
RC="$FIXTURE/.claude/scripts/review-check.sh"
WM="$FIXTURE/.claude/scripts/workflow-manifest.sh"
IR="$FIXTURE/.claude/scripts/impact-report.sh"
TRACKING="$FIXTURE/.claude/.qa-tracking/changed-files.txt"

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }

bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

comments_of() {
    bd_show_with_comments "$1" \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text' \
        2>/dev/null || echo ""
}

comment_count() {
    bd_show_with_comments "$1" \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | length' \
        2>/dev/null || echo "0"
}

labels_of() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null || echo ""
}

count_design_review() {
    comments_of "$1" | grep -cE '^DESIGN-REVIEW v1 ' 2>/dev/null | tr -d ' \n'
}

latest_design_review_line() {
    comments_of "$1" | grep -E '^DESIGN-REVIEW v1 ' | tail -1
}

latest_approval() {
    comments_of "$1" | grep -E '^QA-GATE APPROVED ' | tail -1
}

# write_artifact <path> <task-id> — a minimal, schema-valid design artifact.
write_artifact() {
    local path="$1" tid="$2"
    cat > "$path" <<ARTIFACT
# Design — $tid

## Problem
Test subject.

## Approaches considered
1. Approach A — rejected: does not match the existing pattern.
2. Approach B — chosen: matches it.

## Chosen approach
Approach B.

## Units
See the machine block.

## Global constraints
None.

## Out of scope
Everything else.

## Verification plan
make test

## Revision log
- v1 initial.

<!-- DESIGN-UNITS BEGIN -->
\`\`\`json
{
  "contract_version": "1",
  "task_id": "$tid",
  "designer_identity": "designer",
  "units": [
    {
      "unit_id": "U1",
      "role": "devops",
      "goal": "test unit",
      "acceptance": [ { "id": "AC1", "text": "test fixture: nothing asserted" } ],
      "files": [ ".claude/scripts/qa-gate.sh" ],
      "verification": "make test",
      "depends_on": []
    }
  ]
}
\`\`\`
<!-- DESIGN-UNITS END -->
ARTIFACT
}

# seed_approvable <tid> [reviewer] [role] — everything approve needs EXCEPT
# a design verdict, deliberately: this file needs full control over the
# design axis, so it does not fold design seeding into this helper the way
# .claude/tests/component/lib/fixture.sh now does for the component tier.
seed_approvable() {
    local tid="$1" reviewer="${2:-qa-claude}" role="${3:-devops}"
    local ts hash art pay
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1 \
        || bd comment add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1
    hash=$(bash "$IR" --hash-only 2>/dev/null || echo "")
    [ -z "$hash" ] && hash="unverified"
    art="$FIXTURE/.claude/.qa-tracking/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"%s","reviewer_model":"seeded-fixture","reviewer_pin":"seeded-fixture","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded fixture","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
        "$tid" "$reviewer" "$hash" > "$art"
    bash "$QG" review-record "$tid" < "$art" >/dev/null 2>&1
    bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
    bash "$IR" "$tid" >/dev/null 2>&1 || true
    pay="$FIXTURE/.claude/.qa-tracking/completion-draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    printf '{"task_id":"%s","role":"%s","model":"seeded","pin":"seeded","files_changed":[],"tests_added":[],"decisions":["seeded"],"blockers":[],"llm_observations":"seeded by the design-review-record fixture","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown"}\n' \
        "$tid" "$role" > "$pay"
    bash "$QG" completion-record "$tid" --file "$pay" >/dev/null 2>&1
}

VALID_VERDICT='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'

# ===========================================================================
printf '\n=== Section 1: design-review-record — shape validation ===\n'
# ===========================================================================

TID1=$(bd create "D2 verdict shape subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART1="$FIXTURE/docs/specs/$TID1.md"
write_artifact "$ART1" "$TID1"
printf '%s\n' "$ART1" > "$TRACKING"
bash "$QG" enter "$TID1" >/dev/null 2>&1
bash "$QG" design-record "$TID1" >/dev/null 2>&1
HASH1=$(bash "$WM" hash-file "$ART1")

# 2>/dev/null (not 2>&1): a missing task id ALSO triggers usage()'s
# multi-line help text on stderr, ahead of the one-line JSON error on
# stdout. Merging the two makes the combined blob unparseable as JSON — this
# is about isolating THIS test's own stdout capture, not about the
# subcommand's behaviour (every other missing-key/malformed-input check
# below emits no usage() text, so 2>&1 is harmless there).
OUT=$(bash "$QG" design-review-record 2>/dev/null); EXIT_RC=$?
assert_eq "1.1 no task id: exit 1" "1" "$EXIT_RC"
assert_eq "1.1b ...error_key=missing_task_id" "missing_task_id" "$(json_field '.error_key' "$OUT")"

OUT=$(printf '{}' | bash "$QG" design-review-record "$TID1" 2>&1); EXIT_RC=$?
assert_eq "1.2 missing --design-hash: exit 1" "1" "$EXIT_RC"
assert_eq "1.2b ...error_key=missing_design_hash" "missing_design_hash" "$(json_field '.error_key' "$OUT")"

OUT=$(printf '{}' | bash "$QG" design-review-record "$TID1" --design-hash "not-a-hash" 2>&1)
assert_eq "1.3 --design-hash not 64 hex: design_hash_invalid" "design_hash_invalid" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" < /dev/null 2>&1)
assert_eq "1.4 empty stdin, no --file: empty_input" "empty_input" "$(json_field '.error_key' "$OUT")"

OUT=$(printf 'not json' | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.5 invalid JSON: invalid_json" "invalid_json" "$(json_field '.error_key' "$OUT")"

OUT=$(printf '[]' | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.6 top-level array: not_an_object" "not_an_object" "$(json_field '.error_key' "$OUT")"

for key in verdict criterion_results required_fixes iteration rubric_version reviewer_identity; do
    MISSING=$(printf '%s' "$VALID_VERDICT" | jq -c "del(.$key)")
    OUT=$(printf '%s' "$MISSING" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
    assert_eq "1.7 missing required key '$key': missing_key:$key" "missing_key:$key" "$(json_field '.error_key' "$OUT")"
done

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.verdict="bogus"')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.13 verdict outside {satisfied,needs_revision}: verdict_invalid_enum" "verdict_invalid_enum" "$(json_field '.error_key' "$OUT")"

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.criterion_results="nope"')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.14 criterion_results not an array: criterion_results_not_array" "criterion_results_not_array" "$(json_field '.error_key' "$OUT")"

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.criterion_results=[{"pass":true,"justification":"x"}]')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.15 criterion_results item missing 'criterion': criterion_results_item_invalid:missing_or_bad_criterion" \
    "criterion_results_item_invalid:missing_or_bad_criterion" "$(json_field '.error_key' "$OUT")"

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.required_fixes="nope"')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.16 required_fixes not an array: required_fixes_not_array" "required_fixes_not_array" "$(json_field '.error_key' "$OUT")"

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration="one"')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.17 iteration not a number: iteration_not_number" "iteration_not_number" "$(json_field '.error_key' "$OUT")"

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=1.5')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.18 iteration=1.5 (not [0-9]+): iteration_not_integer" "iteration_not_integer" "$(json_field '.error_key' "$OUT")"

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.rubric_version=1')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.19 rubric_version not a string: rubric_version_not_string" "rubric_version_not_string" "$(json_field '.error_key' "$OUT")"

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.rubric_version=""')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.20 rubric_version empty: rubric_version_empty" "rubric_version_empty" "$(json_field '.error_key' "$OUT")"

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.reviewer_identity=""')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "1.21 reviewer_identity empty: reviewer_identity_empty" "reviewer_identity_empty" "$(json_field '.error_key' "$OUT")"

assert_eq "1.22 none of the above wrote a DESIGN-REVIEW record" "0" "$(count_design_review "$TID1")"

# ===========================================================================
printf '\n=== Section 2: independence at RECORD time (AC 4.4 / P3) ===\n'
# ===========================================================================

SELF=$(printf '%s' "$VALID_VERDICT" | jq -c '.reviewer_identity="designer"')
OUT=$(printf '%s' "$SELF" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "2.1 reviewer_identity == designer= (self-review): design_reviewer_not_independent" \
    "design_reviewer_not_independent" "$(json_field '.error_key' "$OUT")"
assert_eq "2.1b ...and nothing was recorded (misbehaviour would be: it was)" "0" "$(count_design_review "$TID1")"

OUT=$(printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "2.2 CONTROL: a genuinely different identity (design-claude) records ok" "recorded" "$(json_field '.status' "$OUT")"
assert_eq "2.2b ...exactly one DESIGN-REVIEW record now exists" "1" "$(count_design_review "$TID1")"

TID2=$(bd create "D2 no designer subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID2" --design-hash "$HASH1" 2>&1)
assert_eq "2.3 no DESIGN-ARTIFACT record at all: design_artifact_record_missing" \
    "design_artifact_record_missing" "$(json_field '.error_key' "$OUT")"

# ===========================================================================
printf '\n=== Section 3: amendments (B2 / P6) ===\n'
# ===========================================================================

BEFORE=$(count_design_review "$TID1")
DUP=$(printf '%s' "$VALID_VERDICT")
OUT=$(printf '%s' "$DUP" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1" 2>&1)
assert_eq "3.1 a second record at the SAME iteration is refused" \
    "design_review_iteration_not_advancing" "$(json_field '.error_key' "$OUT")"
AFTER=$(count_design_review "$TID1")
assert_eq "3.1b non-vacuity: record count is unchanged (nothing written)" "$BEFORE" "$AFTER"

printf '\n<!-- amended -->\n' >> "$ART1"
HASH1B=$(bash "$WM" hash-file "$ART1")
bash "$QG" design-record "$TID1" >/dev/null 2>&1
AMEND=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=2')
OUT=$(printf '%s' "$AMEND" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1B" 2>&1)
assert_eq "3.2 iteration=2 against a revised artifact (new design_hash): recorded" "recorded" "$(json_field '.status' "$OUT")"
LATEST=$(latest_design_review_line "$TID1")
assert_contains "3.2b ...carries [amends: <prev-design-hash>]" "[amends: $HASH1]" "$LATEST"

NOCH=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=3')
OUT=$(printf '%s' "$NOCH" | bash "$QG" design-review-record "$TID1" --design-hash "$HASH1B" 2>&1)
assert_eq "3.3 iteration=3 against the SAME (unchanged) design_hash: recorded" "recorded" "$(json_field '.status' "$OUT")"
LATEST=$(latest_design_review_line "$TID1")
assert_not_contains "3.3b ...carries NO [amends: ...] marker (nothing changed)" "[amends:" "$LATEST"

# ===========================================================================
printf '\n=== Section 4: compute_design_satisfied via design-gate-precheck (B5) ===\n'
# ===========================================================================

TID4=$(bd create "D2 precheck subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" design-gate-precheck "$TID4" 2>&1); EXIT_RC=$?
assert_eq "4.1 no design attempted at all: exit 0" "0" "$EXIT_RC"
assert_eq "4.1b ...status=ready (deliberately lenient — see B5's own header)" "ready" "$(json_field '.status' "$OUT")"

ART4="$FIXTURE/docs/specs/$TID4.md"
write_artifact "$ART4" "$TID4"
printf '%s\n' "$ART4" > "$TRACKING"
bash "$QG" enter "$TID4" >/dev/null 2>&1
bash "$QG" design-record "$TID4" >/dev/null 2>&1
HASH4=$(bash "$WM" hash-file "$ART4")
OUT=$(bash "$QG" design-gate-precheck "$TID4" 2>&1); EXIT_RC=$?
assert_eq "4.2 design started, no verdict yet: exit 4" "4" "$EXIT_RC"
assert_eq "4.2b ...error_key=design_verdict_missing" "design_verdict_missing" "$(json_field '.error_key' "$OUT")"

NR=$(printf '%s' "$VALID_VERDICT" | jq -c '.verdict="needs_revision" | .required_fixes=["fix U1"] | .criterion_results=[{"criterion":"DS2","pass":false,"justification":"not disjoint"}]')
printf '%s' "$NR" | bash "$QG" design-review-record "$TID4" --design-hash "$HASH4" >/dev/null 2>&1
OUT=$(bash "$QG" design-gate-precheck "$TID4" 2>&1)
assert_eq "4.3 latest verdict is needs_revision: design_not_satisfied" "design_not_satisfied" "$(json_field '.error_key' "$OUT")"

SAT=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=2')
printf '%s' "$SAT" | bash "$QG" design-review-record "$TID4" --design-hash "$HASH4" >/dev/null 2>&1
OUT=$(bash "$QG" design-gate-precheck "$TID4" 2>&1)
assert_eq "4.4 CONTROL: satisfied verdict + matching artifact: status=ready" "ready" "$(json_field '.status' "$OUT")"

printf '\n<!-- edited after the satisfied verdict -->\n' >> "$ART4"
OUT=$(bash "$QG" design-gate-precheck "$TID4" 2>&1)
assert_eq "4.5 artifact edited AFTER the satisfied verdict: design_verdict_stale" "design_verdict_stale" "$(json_field '.error_key' "$OUT")"

# ===========================================================================
printf '\n=== Section 5: approve — DESIGN-SATISFIED-REFUSAL (B3 / P1 / P2) ===\n'
# ===========================================================================

TID5=$(bd create "D2 approve, no design" -t task -p 1 --json 2>/dev/null | jq -r '.id')
printf 'placeholder-5.md\n' > "$TRACKING"
: > "$FIXTURE/placeholder-5.md"
bash "$QG" enter "$TID5" >/dev/null 2>&1
seed_approvable "$TID5"
PRE_COUNT=$(comment_count "$TID5")
PRE_LABELS=$(labels_of "$TID5")
OUT=$(bash "$QG" approve "$TID5" "attempt on a task with no design at all" 2>&1); EXIT_RC=$?
assert_eq "5.1 no design verdict at all: exit 2" "2" "$EXIT_RC"
assert_eq "5.1b ...error_key=no_design_attempted" "no_design_attempted" "$(json_field '.error_key' "$OUT")"
POST_COUNT=$(comment_count "$TID5")
POST_LABELS=$(labels_of "$TID5")
assert_eq "5.1c the task is left UNTOUCHED — comment count unchanged" "$PRE_COUNT" "$POST_COUNT"
assert_eq "5.1d ...and labels unchanged" "$PRE_LABELS" "$POST_LABELS"

OUT=$(bash "$QG" approve "$TID5" --no-design "this task has no design phase" "bypassed attempt" 2>&1)
assert_eq "5.2 CONTROL: --no-design '<reason>' -> approved" "approved" "$(json_field '.status' "$OUT")"
APPROVAL=$(latest_approval "$TID5")
assert_contains "5.2b ...[design bypass: <reason>] recorded" "[design bypass: this task has no design phase" "$APPROVAL"
assert_not_contains "5.2c ...no design_verdict_hash= token (nothing was bound)" "design_verdict_hash=" "$APPROVAL"

TID6=$(bd create "D2 approve, satisfied design" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART6="$FIXTURE/docs/specs/$TID6.md"
write_artifact "$ART6" "$TID6"
printf '%s\n' "$ART6" > "$TRACKING"
bash "$QG" enter "$TID6" >/dev/null 2>&1
bash "$QG" design-record "$TID6" >/dev/null 2>&1
HASH6=$(bash "$WM" hash-file "$ART6")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID6" --design-hash "$HASH6" >/dev/null 2>&1
seed_approvable "$TID6"
OUT=$(bash "$QG" approve "$TID6" "reviewed and satisfied" 2>&1)
assert_eq "5.3 satisfied verdict, matching artifact: approved" "approved" "$(json_field '.status' "$OUT")"
APPROVAL=$(latest_approval "$TID6")
assert_contains "5.3b ...design_verdict_hash=<h> token present" "design_verdict_hash=$HASH6" "$APPROVAL"
assert_eq "5.3c ...positioned LAST among machine tokens, immediately before ' at '" "yes" \
    "$(printf '%s' "$APPROVAL" | grep -qE 'design_verdict_hash=[0-9a-fA-F]{64} at [0-9]{4}-' && echo yes || echo no)"

TID7=$(bd create "D2 approve, stale design" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART7="$FIXTURE/docs/specs/$TID7.md"
write_artifact "$ART7" "$TID7"
printf '%s\n' "$ART7" > "$TRACKING"
bash "$QG" enter "$TID7" >/dev/null 2>&1
bash "$QG" design-record "$TID7" >/dev/null 2>&1
HASH7=$(bash "$WM" hash-file "$ART7")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID7" --design-hash "$HASH7" >/dev/null 2>&1
printf '\n<!-- edited after the satisfied verdict, before approve -->\n' >> "$ART7"
seed_approvable "$TID7"
PRE7_COUNT=$(comment_count "$TID7")
OUT=$(bash "$QG" approve "$TID7" "attempt after a stale edit" 2>&1); EXIT_RC=$?
assert_eq "5.4 design artifact edited after the satisfied verdict: exit 2" "2" "$EXIT_RC"
assert_eq "5.4b ...error_key=design_verdict_stale (P2's functional requirement)" "design_verdict_stale" "$(json_field '.error_key' "$OUT")"
POST7_COUNT=$(comment_count "$TID7")
assert_eq "5.4c the task is left UNTOUCHED" "$PRE7_COUNT" "$POST7_COUNT"

# --- METatest: strip DESIGN-SATISFIED-REFUSAL from a copy -----------------
# Same convention as design-artifact.test.sh section 4.6-4.7: the stripped
# copy is placed INSIDE .claude/scripts/ (not a separate directory) so
# sibling-script resolution (workflow-denylist.sh, review-check.sh,
# workflow-manifest.sh) still works.
awk '/# DESIGN-SATISFIED-REFUSAL BEGIN/{s=1} !s{print} /# DESIGN-SATISFIED-REFUSAL END/{s=0}' \
    "$QG" > "$FIXTURE/.claude/scripts/qa-gate-nodesign.sh"
STRIP_DELTA=$(( $(wc -l < "$QG") - $(wc -l < "$FIXTURE/.claude/scripts/qa-gate-nodesign.sh") ))
assert_eq "5.5 META: the region strip actually removed lines" "yes" "$([ "$STRIP_DELTA" -gt 10 ] && echo yes || echo no)"
chmod +x "$FIXTURE/.claude/scripts/qa-gate-nodesign.sh"
if bash -n "$FIXTURE/.claude/scripts/qa-gate-nodesign.sh" 2>/dev/null; then
    assert_eq "5.5b META: the stripped copy is still valid bash" "0" "0"
else
    assert_eq "5.5b META: the stripped copy is still valid bash" "0" "1"
fi

TID8=$(bd create "D2 META strip subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
printf 'placeholder-8.md\n' > "$TRACKING"
: > "$FIXTURE/placeholder-8.md"
bash "$QG" enter "$TID8" >/dev/null 2>&1
seed_approvable "$TID8"
CTRL_OUT=$(bash "$QG" approve "$TID8" "control: shipped script, no design at all" 2>&1)
assert_eq "5.5c META CONTROL: the SHIPPED script still refuses (no design at all)" \
    "no_design_attempted" "$(json_field '.error_key' "$CTRL_OUT")"
MUTANT_OUT=$(bash "$FIXTURE/.claude/scripts/qa-gate-nodesign.sh" approve "$TID8" "mutant: same task, region stripped" 2>&1)
assert_eq "5.5d META MISBEHAVIOUR: the STRIPPED copy approves the SAME task anyway" \
    "approved" "$(json_field '.status' "$MUTANT_OUT")"
rm -f "$FIXTURE/.claude/scripts/qa-gate-nodesign.sh"

# ===========================================================================
printf '\n=== Section 6: cap_terminated wired into REVIEW-SEPARATION (B4 / P4) ===\n'
# ===========================================================================

record_capped_review() {
    local tid="$1" stopped_by="$2"
    local ts hash art
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "IMPLEMENTER: role=devops task=$tid at $ts" >/dev/null 2>&1
    hash=$(bash "$IR" --hash-only 2>/dev/null || echo "")
    [ -z "$hash" ] && hash="unverified"
    art="$FIXTURE/.claude/.qa-tracking/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"qa-claude","reviewer_model":"seeded","reviewer_pin":"seeded","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded fixture","verdict":"approve","findings":[],"iterations":3,"stopped_by":"%s"}\n' \
        "$tid" "$hash" "$stopped_by" > "$art"
    bash "$QG" review-record "$tid" < "$art" >/dev/null 2>&1
    bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
    bash "$IR" "$tid" >/dev/null 2>&1 || true
    local pay
    pay="$FIXTURE/.claude/.qa-tracking/completion-draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    printf '{"task_id":"%s","role":"devops","model":"seeded","pin":"seeded","files_changed":[],"tests_added":[],"decisions":["seeded"],"blockers":[],"llm_observations":"seeded","context_coverage":"seeded"}\n' \
        "$tid" > "$pay"
    bash "$QG" completion-record "$tid" --file "$pay" >/dev/null 2>&1
}

TID9=$(bd create "D2 cap-terminated review" -t task -p 1 --json 2>/dev/null | jq -r '.id')
printf 'placeholder-9.md\n' > "$TRACKING"
: > "$FIXTURE/placeholder-9.md"
bash "$QG" enter "$TID9" >/dev/null 2>&1
record_capped_review "$TID9" "cap:max_review_iterations"
CAPOUT=$(bash "$RC" gate "$TID9" 2>/dev/null)
assert_eq "6.0 precondition: review-check.sh gate itself reports cap_terminated=true" \
    "true" "$(json_field '.artifact.cap_terminated' "$CAPOUT")"
OUT=$(bash "$QG" approve "$TID9" --no-design "isolating cap_terminated from design" "attempt" 2>&1); EXIT_RC=$?
assert_eq "6.1 latest review stopped_by=cap:max_review_iterations: exit 4" "4" "$EXIT_RC"
assert_eq "6.1b ...error_key=review_cap_terminated" "review_cap_terminated" "$(json_field '.error_key' "$OUT")"
assert_contains "6.1c ...names the actual stopped_by value" "cap:max_review_iterations" "$(json_field '.observations' "$OUT")"

TID10=$(bd create "D2 verdict-concluded review" -t task -p 1 --json 2>/dev/null | jq -r '.id')
printf 'placeholder-10.md\n' > "$TRACKING"
: > "$FIXTURE/placeholder-10.md"
bash "$QG" enter "$TID10" >/dev/null 2>&1
record_capped_review "$TID10" "verdict"
OUT=$(bash "$QG" approve "$TID10" --no-design "isolating cap_terminated from design" "control attempt" 2>&1)
assert_eq "6.2 CONTROL: stopped_by=verdict (concluded on its own terms): approved" "approved" "$(json_field '.status' "$OUT")"

TID11=$(bd create "D2 stop_condition review" -t task -p 1 --json 2>/dev/null | jq -r '.id')
printf 'placeholder-11.md\n' > "$TRACKING"
: > "$FIXTURE/placeholder-11.md"
bash "$QG" enter "$TID11" >/dev/null 2>&1
record_capped_review "$TID11" "stop_condition"
OUT=$(bash "$QG" approve "$TID11" --no-design "isolating cap_terminated from design" "control attempt 2" 2>&1)
assert_eq "6.3 CONTROL: stopped_by=stop_condition (concluded on its own terms): approved" "approved" "$(json_field '.status' "$OUT")"

TID12=$(bd create "D2 no-review bypass of cap" -t task -p 1 --json 2>/dev/null | jq -r '.id')
printf 'placeholder-12.md\n' > "$TRACKING"
: > "$FIXTURE/placeholder-12.md"
bash "$QG" enter "$TID12" >/dev/null 2>&1
record_capped_review "$TID12" "cap:timeout"
OUT=$(bash "$QG" approve "$TID12" --no-design "no design" --no-review "waiving review for this fixture" "bypass both" 2>&1)
assert_eq "6.4 --no-review ALSO bypasses cap_terminated (same audited escape, shared block)" \
    "approved" "$(json_field '.status' "$OUT")"

# --- the has()-vs-`//` reading discipline, against synthetic envelopes -----
CAP_LINE_PRESENT=$(grep -cF 'if has("cap_terminated") then (.cap_terminated | tostring) else "false" end' "$QG")
assert_eq "6.5 precondition: the exact has()-guarded read is present verbatim in the shipped script" "1" "$CAP_LINE_PRESENT"
FILTER='.artifact | if has("cap_terminated") then (.cap_terminated | tostring) else "false" end'
R_EXPLICIT_FALSE=$(printf '%s' '{"artifact":{"cap_terminated":false}}' | jq -r "$FILTER")
R_KEY_ABSENT=$(printf '%s' '{"artifact":{}}' | jq -r "$FILTER")
assert_eq "6.5b an explicit cap_terminated=false reads as false" "false" "$R_EXPLICIT_FALSE"
assert_eq "6.5c a MISSING key (older review-check.sh) ALSO reads as false, not as capped" "false" "$R_KEY_ABSENT"
NAIVE=$(printf '%s' '{"artifact":{"cap_terminated":false}}' | jq -r '.artifact.cap_terminated // "MISREAD-AS-ABSENT"')
assert_eq "6.5d CONTROL: the naive \`// \` idiom DOES misread an explicit false (this is why has() is used instead)" \
    "MISREAD-AS-ABSENT" "$NAIVE"

# --- METatest: strip REVIEW-CAP-TERMINATED-REFUSAL from a copy -------------
awk '/# REVIEW-CAP-TERMINATED-REFUSAL BEGIN/{s=1} !s{print} /# REVIEW-CAP-TERMINATED-REFUSAL END/{s=0}' \
    "$QG" > "$FIXTURE/.claude/scripts/qa-gate-nocap.sh"
CAP_STRIP_DELTA=$(( $(wc -l < "$QG") - $(wc -l < "$FIXTURE/.claude/scripts/qa-gate-nocap.sh") ))
assert_eq "6.6 META: the region strip actually removed lines" "yes" "$([ "$CAP_STRIP_DELTA" -gt 5 ] && echo yes || echo no)"
chmod +x "$FIXTURE/.claude/scripts/qa-gate-nocap.sh"
if bash -n "$FIXTURE/.claude/scripts/qa-gate-nocap.sh" 2>/dev/null; then
    assert_eq "6.6b META: the stripped copy is still valid bash" "0" "0"
else
    assert_eq "6.6b META: the stripped copy is still valid bash" "0" "1"
fi
TID13=$(bd create "D2 cap META subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
printf 'placeholder-13.md\n' > "$TRACKING"
: > "$FIXTURE/placeholder-13.md"
bash "$QG" enter "$TID13" >/dev/null 2>&1
record_capped_review "$TID13" "cap:max_findings"
CTRL_OUT=$(bash "$QG" approve "$TID13" --no-design "no design" "control: shipped, still capped" 2>&1)
assert_eq "6.6c META CONTROL: the SHIPPED script refuses the capped review" \
    "review_cap_terminated" "$(json_field '.error_key' "$CTRL_OUT")"
MUTANT_OUT=$(bash "$FIXTURE/.claude/scripts/qa-gate-nocap.sh" approve "$TID13" --no-design "no design" "mutant: same task, arm stripped" 2>&1)
assert_eq "6.6d META MISBEHAVIOUR: the STRIPPED copy approves the SAME capped review anyway" \
    "approved" "$(json_field '.status' "$MUTANT_OUT")"
rm -f "$FIXTURE/.claude/scripts/qa-gate-nocap.sh"

# ===========================================================================
printf '\n=== Section 7: the bjx scalar-class discipline (P5) ===\n'
# ===========================================================================

TID14=$(bd create "D2 scalar class subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART14="$FIXTURE/docs/specs/$TID14.md"
write_artifact "$ART14" "$TID14"
printf '%s\n' "$ART14" > "$TRACKING"
bash "$QG" enter "$TID14" >/dev/null 2>&1
bash "$QG" design-record "$TID14" >/dev/null 2>&1
HASH14=$(bash "$WM" hash-file "$ART14")

BAD_ID="design claude"
assert_contains "7.1 precondition: the test's own reviewer_identity actually contains the offending byte (a space)" \
    " " "$BAD_ID"
BAD=$(printf '%s' "$VALID_VERDICT" | jq -c --arg id "$BAD_ID" '.reviewer_identity=$id')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID14" --design-hash "$HASH14" 2>&1)
assert_eq "7.1b reviewer_identity with a space: reviewer_invalid_chars (REJECTED, not sanitised)" \
    "reviewer_invalid_chars" "$(json_field '.error_key' "$OUT")"
assert_eq "7.1c ...and nothing was recorded" "0" "$(count_design_review "$TID14")"

BAD=$(printf '%s' "$VALID_VERDICT" | jq -c '.rubric_version="1: evil"')
OUT=$(printf '%s' "$BAD" | bash "$QG" design-review-record "$TID14" --design-hash "$HASH14" 2>&1)
assert_eq "7.2 rubric_version with a colon: rubric_version_invalid_chars" \
    "rubric_version_invalid_chars" "$(json_field '.error_key' "$OUT")"

# --- METatest: remove ONLY the reviewer-scalar guard line -------------------
# A single-line removal rather than a sentinel region — this guard is one
# call among several inside the "write" section, with no BEGIN/END of its
# own — so the mutation targets the exact line and proves the removal landed
# via a grep count before/after, mirroring the non-vacuity discipline every
# other METatest in this file uses for its own mutation.
# shellcheck disable=SC2016  # single-quoted deliberately: this is the
# LITERAL source text to grep/sed for, not an expression to expand.
MUT_LINE='assert_record_scalar "design-review-record" "$tid" "reviewer" "$reviewer_identity"'
GREP_BEFORE=$(grep -cF "$MUT_LINE" "$QG")
assert_eq "7.3 precondition: the guard line exists exactly once in the shipped script" "1" "$GREP_BEFORE"
sed "\\|$MUT_LINE|d" "$QG" > "$FIXTURE/.claude/scripts/qa-gate-noguard.sh"
GREP_AFTER=$(grep -cF "$MUT_LINE" "$FIXTURE/.claude/scripts/qa-gate-noguard.sh")
assert_eq "7.3b META: the guard line was actually removed" "0" "$GREP_AFTER"
chmod +x "$FIXTURE/.claude/scripts/qa-gate-noguard.sh"
if bash -n "$FIXTURE/.claude/scripts/qa-gate-noguard.sh" 2>/dev/null; then
    assert_eq "7.3c META: the no-guard copy is still valid bash" "0" "0"
else
    assert_eq "7.3c META: the no-guard copy is still valid bash" "0" "1"
fi

TID15=$(bd create "D2 no-guard mutant subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART15="$FIXTURE/docs/specs/$TID15.md"
write_artifact "$ART15" "$TID15"
printf '%s\n' "$ART15" > "$TRACKING"
bash "$QG" enter "$TID15" >/dev/null 2>&1
bash "$QG" design-record "$TID15" >/dev/null 2>&1
HASH15=$(bash "$WM" hash-file "$ART15")
BAD15=$(printf '%s' "$VALID_VERDICT" | jq -c --arg id "$BAD_ID" '.reviewer_identity=$id')
NG_OUT=$(printf '%s' "$BAD15" | bash "$FIXTURE/.claude/scripts/qa-gate-noguard.sh" design-review-record "$TID15" --design-hash "$HASH15" 2>&1)
assert_eq "7.3d META MISBEHAVIOUR: the no-guard mutant WRITES the record with the invalid byte" \
    "recorded" "$(json_field '.status' "$NG_OUT")"
RAW_LINE=$(latest_design_review_line "$TID15")
assert_contains "7.3e ...the bad byte really reached the comment text" "reviewer=design claude" "$RAW_LINE"

# THE CONSEQUENCE: the shipped reader (latest_design_review, which
# compute_design_satisfied depends on) requires reviewer=[A-Za-z0-9._+-]+
# with NO space, anchored — so it cannot match the malformed line at all,
# and the record becomes indistinguishable from "never recorded". This is
# the "downstream anchored capture(...) mis-parses" the pairing plan names.
PRECHECK_OUT=$(bash "$QG" design-gate-precheck "$TID15" 2>&1)
assert_eq "7.3f CONSEQUENCE: the shipped (guarded) reader treats the malformed record as ABSENT, not as a recorded verdict" \
    "design_verdict_missing" "$(json_field '.error_key' "$PRECHECK_OUT")"

CTRL_OUT=$(printf '%s' "$BAD15" | bash "$QG" design-review-record "$TID15" --design-hash "$HASH15" 2>&1)
assert_eq "7.3g META CONTROL: the SHIPPED script rejects the same input rather than writing it" \
    "reviewer_invalid_chars" "$(json_field '.error_key' "$CTRL_OUT")"
rm -f "$FIXTURE/.claude/scripts/qa-gate-noguard.sh"

# ===========================================================================
# Summary line convention (matches design-artifact.test.sh and every other
# L1 spec, deliberately): run-tests.sh's TRANSCRIPT-FAIL arm (a9hh R4-F2,
# :887/:989) greps every spec's transcript for lines matching
# '^[[:space:]]*FAIL:' and fails the SPEC on any match, precisely so a spec
# whose own exit-code plumbing is broken cannot report a false pass. A raw
# "FAIL: %d" summary line — even printing 0 — collides with that heuristic
# byte-for-byte: the regex has no way to know "FAIL: 0" is a zero-count
# accounting line rather than one failed assertion named "0". Every other
# spec in this tier avoids the collision by spelling its own summary label
# "FAILED:" (with a D), which the anchored regex does not match. Reproduced
# and fixed the hard way: an earlier version of this exact block printed
# "FAIL: %d" and a clean, fully-passing run (85/85) was scored FAILED by
# run-tests.sh with "first: FAIL: 0" — the collision, not a real assertion
# failure. Do not revert to the shorter spelling.
printf '\n=== Summary ===\n'
printf '\nTotal: %d assertion(s) run\n' "$((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d assertion(s)\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

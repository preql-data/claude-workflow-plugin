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
#   6. Every rubric file under .claude/rubrics/ has version frontmatter.
#   7. META-TEST: a stubbed qa-gate.sh with the satisfied-branch label
#      calls removed asserts the rubric-satisfied test FAILS — proving
#      the assertion is sensitive to the script's label-flip behaviour,
#      not vacuous.
#
# Conventions mirror .claude/scripts/tests/qa-gate-choose.test.sh —
# plain bash, `set -u`, assert helpers, trailing summary, tempdir
# fixture with a bd --no-daemon shim.
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

if ! command -v bd >/dev/null 2>&1; then
    if [ "${BD_SHIM_ONLY:-0}" = "1" ]; then
        echo "SKIPPED: qa-gate-grade-record.test.sh (bd not available; CI env BD_SHIM_ONLY=1)"
        exit 0
    fi
    echo "bd CLI not on PATH — qa-gate-grade-record tests require Beads."
    exit 1
fi

# bd --no-daemon wrapper so the tempdir DB doesn't race the daemon.
REAL_BD=$(command -v bd)
cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} --no-daemon "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"
export PATH="$FIXTURE/bin:$PATH"

cd "$FIXTURE" && bd init >/dev/null 2>&1

export CLAUDE_PROJECT_DIR="$FIXTURE"
export HOME="$TEST_HOME"

QG="$FIXTURE/.claude/scripts/qa-gate.sh"

# Helper: read the current labels for a task as a comma-joined string.
labels_for() {
    local tid="$1"
    bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}

# Helper: count comments matching a regex on a task.
comment_count_matching() {
    local tid="$1" pat="$2"
    bd show "$tid" --json 2>/dev/null \
        | jq -r --arg pat "$pat" \
            'if type == "array" then .[0].comments else .comments end // [] | map(select(.text | test($pat))) | length' \
        2>/dev/null || echo "0"
}

# Helper: pull the first comment matching a regex (or empty).
comment_first_matching() {
    local tid="$1" pat="$2"
    bd show "$tid" --json 2>/dev/null \
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
# Record a satisfied verdict to set rubric-satisfied.
VERDICT=$(build_verdict "satisfied" 1 "v1")
printf '%s' "$VERDICT" | bash "$QG" grade-record "$TID_AS" >/dev/null

OUT=$(bash "$QG" approve "$TID_AS" "All criteria passed per RUBRIC v1 iteration 1.")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "approve-sat: status=approved" "approved" "$STATUS"
OBS=$(printf '%s' "$OUT" | jq -r '.observations')
assert_not_contains "approve-sat: observations DO NOT contain WARNING" \
    "WARNING" "$OBS"
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
EXPECTED_RUBRICS=(default backend frontend devops bugfix)
for r in "${EXPECTED_RUBRICS[@]}"; do
    f="$RUBRICS_DIR/$r.md"
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("rubric file missing: $r.md")
        printf '  FAIL: rubric file missing: %s\n' "$f"
        continue
    fi
    # Frontmatter must be present and contain `version: 1`.
    head1=$(head -1 "$f")
    assert_eq "rubric $r.md: frontmatter opens with ---" "---" "$head1"
    if head -10 "$f" | grep -qE '^version:[[:space:]]*1[[:space:]]*$'; then
        PASS=$((PASS + 1))
        printf '  PASS: rubric %s.md: version: 1 present\n' "$r"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("rubric $r.md: missing version: 1 frontmatter")
        printf '  FAIL: rubric %s.md: missing "version: 1" in frontmatter\n' "$r"
    fi
done

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
exec ${REAL_BD} --no-daemon "\$@"
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

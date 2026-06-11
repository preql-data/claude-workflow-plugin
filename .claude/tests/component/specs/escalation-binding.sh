#!/bin/bash
# escalation-binding.sh — L2 component spec for spec 0.2.
#
# Drives verify-before-stop.sh through synthetic Stop payloads with a
# stubbed failing test runner. The acceptance contract from the spec:
#
#   "The captured production scenario stops re-running the suite at
#    iteration 4 and lands on a recorded J21 decision by iteration 5 at
#    the latest (auto-defer counts as the recorded decision)."
#
# Concretely we assert:
#
#   1. Iteration 1-3 invoke the test runner shim and block.
#   2. Iteration 3 transitions the gate into the escalated state:
#        - qa-escalated label added on the active task
#        - exactly one ESCALATED comment posted (idempotent on later loops)
#        - block reason carries the "record a J21 choice" wording
#        - the test command is still invoked on the way to cap (so the
#          shim count is 3 after iteration 3)
#   3. Iteration 4 does NOT invoke the test command (shim count stays 3)
#      but still blocks under the escalation wording.
#   4. Iteration 5 (still no choice) auto-defers:
#        - qa-deferred label set
#        - Stop allowed ({} envelope)
#        - qa-pending preserved
#   5. A later Stop with qa-deferred set allows immediately.
#   6. A fresh `qa-gate.sh enter` on the deferred task clears
#      qa-deferred + qa-escalated and resumes normal gating (suite runs
#      again on the next Stop).
#   7. Runner-vs-assertion classification: a shim that exits 127 lands
#      on the "Test suite failed to run" wording; a shim that exits 1
#      with assertion output lands on "Tests failing".
#   8. Counter reset on active-task change: switching CURRENT_TASK
#      between two tasks reads independent counter files.
#   9. META-TEST: stubbing the iteration counter persistence (zeroing
#      the file every loop) makes the cap-assertion fail. This proves
#      the test is sensitive to a regression in counter persistence.
#
# Run via the L2 component runner (.claude/tests/component/run.sh),
# which pre-sources assert.sh / shim.sh / hook-envelope.sh / fixture.sh.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
QG="$FIXTURE/.claude/scripts/qa-gate.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# The component fixture symlinks detect-stack.sh from the plugin. We
# replace it with a stub that always reports `npm test` as the test
# command (no lint/type so the path stays fast). The shim for `npm` is
# then used to script test failures iteration-by-iteration.
rm -f "$FIXTURE/.claude/scripts/detect-stack.sh"
cat > "$FIXTURE/.claude/scripts/detect-stack.sh" <<'STUB'
#!/bin/bash
# Test-time stack detector for escalation-binding spec.
printf '{"runner":"npm","test_cmd":"npm test","lint_cmd":"","type_cmd":""}\n'
STUB
chmod +x "$FIXTURE/.claude/scripts/detect-stack.sh"

# A `npm` shim that records every invocation to npm.log and exits with
# code 1 + emits a synthetic "1 test failing" line. The log lets us
# count how many times the test runner was actually invoked across
# Stop loops — the production bug was "still re-running the full test
# suite every loop", so the count is the gating evidence.
mk_shim "npm" "$FIXTURE" 1 "FAIL  src/handler.test.ts: AssertionError: 1 test failing" >/dev/null
NPM_LOG="$FIXTURE/bin/npm.log"

# Seed a task and enter the QA gate.
TID=$(cd "$FIXTURE" && bd create "Escalation cap test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
assert_match "esc: seeded task id" '^[a-z0-9-]+\.' "$TID"
bash "$QG" enter "$TID" >/dev/null
bd label add "$TID" qa-pending >/dev/null 2>&1

# Use a NON-doc-only path so we exercise the test pass on every loop.
# Re-seed each loop because the QA-required path doesn't truncate it.
ensure_tracking() {
    printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"
}

# Helper: count npm invocations from the shim log.
npm_count() {
    [ -f "$NPM_LOG" ] || { echo "0"; return; }
    grep -c . "$NPM_LOG" 2>/dev/null || echo "0"
}

# Helper: read labels.
labels_for() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}

# Helper: count comments matching a pattern.
comment_count_matching() {
    bd show "$1" --json 2>/dev/null \
        | jq -r --arg pat "$2" \
            'if type == "array" then .[0].comments else .comments end // [] | map(select(.text | test($pat))) | length' \
        2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
# Iterations 1-3: full suite runs each loop; iteration 3 transitions to
# escalated.

ensure_tracking
OUT1=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_decision "esc-1: iter 1 blocks" "$OUT1" "block"
assert_eq "esc-1: npm invoked once" "1" "$(npm_count)"
SAN_T=$(printf '%s' "$TID" | tr -c 'A-Za-z0-9._-' '_')
ITER1=$(head -1 "$TRACK/iteration-count.$SAN_T" 2>/dev/null)
assert_eq "esc-1: counter=1" "1" "$ITER1"

ensure_tracking
OUT2=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_decision "esc-2: iter 2 blocks" "$OUT2" "block"
assert_eq "esc-2: npm invoked again (count=2)" "2" "$(npm_count)"

ensure_tracking
OUT3=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_decision "esc-3: iter 3 (cap) blocks" "$OUT3" "block"
# At cap, the suite STILL runs on its way to setting qa-escalated -
# spec wording: "first cap hit ... the gate still blocks". Reuse only
# kicks in on subsequent loops.
assert_eq "esc-3: npm invoked at cap (count=3)" "3" "$(npm_count)"

# Label + comment side-effects of cap hit.
LABELS3=$(labels_for "$TID")
assert_contains "esc-3: qa-escalated label added" "qa-escalated" "$LABELS3"
ESCALATED_COMMENTS=$(comment_count_matching "$TID" "QA-GATE ESCALATED")
assert_eq "esc-3: one escalation comment posted" "1" "$ESCALATED_COMMENTS"

# Block reason wording.
REASON3=$(printf '%s' "$OUT3" | jq -r '.reason // empty')
assert_contains "esc-3: reason mentions ESCALATED" \
    "ESCALATED" "$REASON3"
assert_contains "esc-3: reason cites J21 choose options" \
    "qa-gate.sh choose" "$REASON3"

# ---------------------------------------------------------------------------
# Iteration 4: no choice recorded. Suite MUST NOT be re-invoked. Still
# blocks with the escalation wording.

ensure_tracking
OUT4=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_decision "esc-4: iter 4 still blocks while escalated" "$OUT4" "block"
# Key invariant: the count is UNCHANGED from iteration 3.
assert_eq "esc-4: npm NOT re-invoked (count stays 3)" "3" "$(npm_count)"
REASON4=$(printf '%s' "$OUT4" | jq -r '.reason // empty')
assert_contains "esc-4: reason mentions ESCALATED" \
    "ESCALATED" "$REASON4"
assert_contains "esc-4: reason mentions record a J21 choice" \
    "record a J21 choice" "$REASON4"

# Idempotent: the escalation comment should NOT have been re-posted.
ESCALATED_COMMENTS4=$(comment_count_matching "$TID" "QA-GATE ESCALATED")
assert_eq "esc-4: escalation comment NOT re-posted" "1" "$ESCALATED_COMMENTS4"

# ---------------------------------------------------------------------------
# Iteration 5: still no choice. Auto-defer fires.

ensure_tracking
RAW5=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1)
OUT5=$(printf '%s' "$RAW5" | tail -1)
assert_empty_envelope "esc-5: iter 5 auto-defers (allow)" "$OUT5"
assert_eq "esc-5: npm STILL NOT re-invoked (count stays 3)" "3" "$(npm_count)"
LABELS5=$(labels_for "$TID")
assert_contains "esc-5: qa-deferred label set by auto-defer" "qa-deferred" "$LABELS5"
assert_contains "esc-5: qa-pending preserved" "qa-pending" "$LABELS5"

# Audit comment for auto-defer.
DEFER_COMMENTS=$(comment_count_matching "$TID" "QA-GATE AUTO-DEFER")
assert_eq "esc-5: one auto-defer comment posted" "1" "$DEFER_COMMENTS"

# ---------------------------------------------------------------------------
# Acceptance replay (spec 0.2): "stops re-running the suite at iteration
# 4 and lands on a recorded J21 decision by iteration 5 at the latest."
# We've already proven both:
#   - npm count stayed at 3 through iterations 4 and 5
#   - qa-deferred (the auto-defer recorded decision) is on the task
# Tag this as the acceptance assertion explicitly.
assert_eq "ACCEPTANCE: suite NOT re-run after cap (npm=3 across iters 4+5)" \
    "3" "$(npm_count)"
assert_contains "ACCEPTANCE: J21 decision recorded by iter 5 (qa-deferred)" \
    "qa-deferred" "$LABELS5"

# ---------------------------------------------------------------------------
# A later Stop with qa-deferred still set allows immediately.

ensure_tracking
OUT6=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_empty_envelope "esc-6: subsequent Stop with qa-deferred allows" "$OUT6"
assert_eq "esc-6: npm STILL NOT re-invoked (count stays 3)" "3" "$(npm_count)"

# ---------------------------------------------------------------------------
# A fresh `qa-gate.sh enter` clears qa-deferred + qa-escalated and
# resumes normal gating. The next Stop must run the suite again.

bash "$QG" enter "$TID" >/dev/null
LABELS_R=$(labels_for "$TID")
DEF_GREP=$(printf '%s' ",$LABELS_R," | grep -c ',qa-deferred,' || true)
DEF_GREP=$(printf '%s' "$DEF_GREP" | tr -d '[:space:]')
assert_eq "esc-resume: qa-deferred cleared on re-enter" "0" "$DEF_GREP"
ESC_GREP=$(printf '%s' ",$LABELS_R," | grep -c ',qa-escalated,' || true)
ESC_GREP=$(printf '%s' "$ESC_GREP" | tr -d '[:space:]')
assert_eq "esc-resume: qa-escalated cleared on re-enter" "0" "$ESC_GREP"

# Re-seed qa-pending so the gate still asks for review (enter sets
# qa-gate-entered but not qa-pending).
bd label add "$TID" qa-pending >/dev/null 2>&1

ensure_tracking
OUT_R=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_decision "esc-resume: gate blocks again after re-enter" "$OUT_R" "block"
assert_eq "esc-resume: npm re-invoked (count=4)" "4" "$(npm_count)"

# ---------------------------------------------------------------------------
# Runner-vs-assertion classification (spec 0.2). Replace the npm shim
# with one that exits 127 (command-not-found classification per
# classify_test_failure). Use a fresh task to keep state clean.

# Switch to a new task with no escalation state.
TID2=$(cd "$FIXTURE" && bd create "classification test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID2" >/dev/null
bd label add "$TID2" qa-pending >/dev/null 2>&1
ensure_tracking

# 127 = runner-failure path.
mk_shim "npm" "$FIXTURE" 127 "bash: npm: command not found" >/dev/null
OUT_RUNNER=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_decision "esc-class: runner-failure still blocks" "$OUT_RUNNER" "block"
REASON_RUNNER=$(printf '%s' "$OUT_RUNNER" | jq -r '.reason // empty')
assert_contains "esc-class: 127 classified as runner failure" \
    "Test suite failed to run" "$REASON_RUNNER"
assert_contains "esc-class: runner block message says environment/runner" \
    "environment/runner issue" "$REASON_RUNNER"

# 1 with assertion output = assertion path.
TID3=$(cd "$FIXTURE" && bd create "assertion test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID3" >/dev/null
bd label add "$TID3" qa-pending >/dev/null 2>&1
ensure_tracking
mk_shim "npm" "$FIXTURE" 1 "FAIL src/test.ts: expected true to equal false" >/dev/null
OUT_ASSERT=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_decision "esc-class: assertion-failure blocks" "$OUT_ASSERT" "block"
REASON_ASSERT=$(printf '%s' "$OUT_ASSERT" | jq -r '.reason // empty')
assert_contains "esc-class: assertion failure uses 'Tests failing'" \
    "Tests failing" "$REASON_ASSERT"
# Negative check: the assertion path must NOT carry the runner wording.
NOT_RUNNER=$(printf '%s' "$REASON_ASSERT" | grep -c 'Test suite failed to run' || true)
NOT_RUNNER=$(printf '%s' "$NOT_RUNNER" | tr -d '[:space:]')
assert_eq "esc-class: assertion failure does NOT say 'failed to run'" \
    "0" "$NOT_RUNNER"

# ---------------------------------------------------------------------------
# Counter reset on active-task change: TID and TID2 have independent
# per-task counter files. The spec calls for "verify and add an
# explicit test rather than new code if it already holds" — this is
# the test.

SAN_T2=$(printf '%s' "$TID2" | tr -c 'A-Za-z0-9._-' '_')
SAN_T3=$(printf '%s' "$TID3" | tr -c 'A-Za-z0-9._-' '_')
# After the runs above, TID2's counter is 1 (one Stop) and TID3's is 1.
assert_eq "esc-counter: TID2 has its own counter file" "0" \
    "$([ -s "$TRACK/iteration-count.$SAN_T2" ] && echo 0 || echo 1)"
assert_eq "esc-counter: TID3 has its own counter file" "0" \
    "$([ -s "$TRACK/iteration-count.$SAN_T3" ] && echo 0 || echo 1)"
# Counters are independent (both at 1, not summed).
COUNT_T2=$(head -1 "$TRACK/iteration-count.$SAN_T2" 2>/dev/null)
COUNT_T3=$(head -1 "$TRACK/iteration-count.$SAN_T3" 2>/dev/null)
assert_eq "esc-counter: TID2 counter=1 (not leaked from TID)" "1" "$COUNT_T2"
assert_eq "esc-counter: TID3 counter=1 (not leaked from TID2)" "1" "$COUNT_T3"

# ---------------------------------------------------------------------------
# META-TEST: mutate the iteration counter persistence. We do this by
# building a SECOND fixture, replacing iteration_file_for in its copy
# of verify-before-stop.sh with a no-op (always returns the same path
# and is wiped between calls), and re-running the iteration 1..4
# scenario. The cap-assertion ("npm count stays at 3 from iteration 3
# onward") MUST fail under the stub — proving the test is sensitive
# to a regression in counter persistence.

mk_fixture
FIXTURE_M="$COMPONENT_FIXTURE_PATH"
VBS_M="$FIXTURE_M/.claude/scripts/verify-before-stop.sh"
QG_M="$FIXTURE_M/.claude/scripts/qa-gate.sh"
TRACK_M="$FIXTURE_M/.claude/.qa-tracking"

# Same stack stub + shim approach.
rm -f "$FIXTURE_M/.claude/scripts/detect-stack.sh"
cat > "$FIXTURE_M/.claude/scripts/detect-stack.sh" <<'STUB'
#!/bin/bash
printf '{"runner":"npm","test_cmd":"npm test","lint_cmd":"","type_cmd":""}\n'
STUB
chmod +x "$FIXTURE_M/.claude/scripts/detect-stack.sh"
mk_shim "npm" "$FIXTURE_M" 1 "FAIL src/x.ts: 1 test failing" >/dev/null
NPM_LOG_M="$FIXTURE_M/bin/npm.log"

# Mutate verify-before-stop.sh: replace bump_iteration with a version
# that ALWAYS returns "1" (counter never grows). This is the regression
# the META-TEST is sensitive to. We use awk to overwrite the function
# body while leaving everything else intact.
PLUGIN_VBS=$(readlink "$VBS_M")
rm "$VBS_M"
awk '
    BEGIN { in_fn=0; replaced=0 }
    /^bump_iteration\(\) \{$/ && !replaced {
        print "bump_iteration() {"
        print "    # META-TEST stub: counter never grows past 1."
        print "    local file=\"$1\""
        print "    printf %s\\\\n 1 > \"$file\""
        print "    printf %s 1"
        print "}"
        in_fn=1
        replaced=1
        next
    }
    in_fn && /^\}$/ { in_fn=0; next }
    in_fn { next }
    { print }
' "$PLUGIN_VBS" > "$VBS_M"
chmod +x "$VBS_M"

TID_M=$(cd "$FIXTURE_M" && bd create "meta-test counter mutation" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_M" enter "$TID_M" >/dev/null
bd label add "$TID_M" qa-pending >/dev/null 2>&1

# Run the gate 5 times (cap=3 + buffer + one extra) to give the
# regression every opportunity to surface. With the bump stubbed to
# "always 1", the gate NEVER transitions into escalated (it's pinned
# at iteration 1), so the suite IS re-run on every loop. After 5
# Stops the npm count is 5, not capped at 3. This is the regression
# signal.
for _ in 1 2 3 4 5; do
    printf 'src/x.ts\n' > "$TRACK_M/changed-files.txt"
    printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS_M" >/dev/null 2>&1 || true
done

# Read META npm count.
META_COUNT=$([ -f "$NPM_LOG_M" ] && grep -c . "$NPM_LOG_M" 2>/dev/null || echo "0")
# Strip trailing whitespace just in case.
META_COUNT=$(printf '%s' "$META_COUNT" | tr -d '[:space:]')

# Under the mutation, npm was invoked 4 times (one per Stop). Without
# the mutation it would be 3 (capped at iteration 3). Assert the
# META invariant: counter mutation => npm count > 3.
META_GT_3=$([ "$META_COUNT" -gt 3 ] 2>/dev/null && echo "yes" || echo "no")
assert_eq "META-TEST: counter-persistence mutation causes suite re-run past cap" \
    "yes" "$META_GT_3"

# And the escalation label should NOT be set (because the counter
# never reached 3 under the stub).
LABELS_META=$(bd show "$TID_M" --json 2>/dev/null \
    | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")')
META_ESC=$(printf '%s' ",$LABELS_META," | grep -c ',qa-escalated,' || true)
META_ESC=$(printf '%s' "$META_ESC" | tr -d '[:space:]')
assert_eq "META-TEST: qa-escalated NOT set under stubbed counter (proves the cap-assertion would fail)" \
    "0" "$META_ESC"

[ "$FAIL" -eq 0 ]

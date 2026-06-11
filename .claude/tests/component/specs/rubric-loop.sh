#!/bin/bash
# rubric-loop.sh — L2 component spec for spec Phase A item A.2.
#
# Drives the full rubric-grader QA loop offline with scripted verdicts
# (canned JSON files) — no LLM call, no real grader subagent. Mirrors
# escalation-binding.sh's structure: tempdir fixture, real-bd-with-shim,
# direct script invocations against verify-before-stop.sh + qa-gate.sh.
#
# What this spec covers (script-testable):
#
#   1. enter — rubric-pending label set alongside qa-gate-entered.
#   2. grade-record(needs_revision, iteration 1) — RUBRIC comment posted,
#      labels unchanged.
#   3. qa-gate.sh block — qa-blocked label added; comment recorded
#      (carrying the required_fixes the QA agent would paste in).
#   4. re-enter on the same task — rubric-satisfied cleared (none present
#      to clear; rubric-pending refreshed), counters reset, escalation
#      labels cleared. The full QA round-trip rejoins normal gating.
#   5. grade-record(satisfied, iteration 2) — rubric-pending removed,
#      rubric-satisfied added, RUBRIC comment posted.
#   6. qa-gate.sh approve — rubric-satisfied SURVIVES as the audit trail
#      label; rubric-pending is cleared if present; the approval comment
#      cites the verdict. Stop-hook semantics untouched (principle 6).
#   7. Cap-path coupling (the script-testable slice): drive
#      verify-before-stop.sh through iterations to MAX_ITERATIONS and
#      assert qa-escalated engages WITH rubric-pending still on the
#      task. The 0.2 escalation machinery and the Phase A rubric labels
#      co-exist on the same task without contaminating each other.
#   8. META-TEST: corrupt a scripted verdict (satisfied with a missing
#      key) — grade-record rejects with the structured error envelope
#      naming the offending key. Repeat for the invalid-enum and
#      not-an-object cases (A.1 sensitivity pattern extended).
#   9. META-TEST (sensitivity): stub the satisfied-branch label flip in
#      qa-gate.sh and re-run the satisfied assertions. The label-flip
#      assertions MUST fail under the stub — proving the test is
#      sensitive to the script's label-flip behaviour, not vacuous.
#
# What this spec does NOT cover (L2-untestable-by-design):
#
#   - The 3-iteration cap from .claude/rubric-config is read by the QA
#     AGENT PROMPT, not by qa-gate.sh. The cap is a prompt-level
#     contract (qa.md section 6e). At L2 we exercise the SCRIPT slice:
#     grade-record + labels + the 0.2 escalation continuing to work
#     with rubric labels present. The prompt-level cap is covered by
#     the e2e rubric-revision-loop fixture (built but RUN manually
#     at phase closeout).
#
# Run via the L2 component runner (.claude/tests/component/run.sh),
# which pre-sources assert.sh / shim.sh / hook-envelope.sh / fixture.sh.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# Stack-detect stub: report a single test command so the verify-before-stop
# escalation path has something to invoke when we exercise the cap-path
# coupling later. Lifted from escalation-binding.sh's stub.
rm -f "$FIXTURE/.claude/scripts/detect-stack.sh"
cat > "$FIXTURE/.claude/scripts/detect-stack.sh" <<'STUB'
#!/bin/bash
# Test-time stack detector for rubric-loop spec.
printf '{"runner":"npm","test_cmd":"npm test","lint_cmd":"","type_cmd":""}\n'
STUB
chmod +x "$FIXTURE/.claude/scripts/detect-stack.sh"

# A `npm` shim that records every invocation. Exit 1 + an "assertion
# failing" line so the gate's iteration counter advances each Stop.
mk_shim "npm" "$FIXTURE" 1 "FAIL  src/handler.test.ts: AssertionError: 1 test failing" >/dev/null
NPM_LOG="$FIXTURE/bin/npm.log"

# Canned-verdict directory. Each file is a strict-JSON grader output the
# QA agent would pipe into `qa-gate.sh grade-record`. Building them as
# files (rather than inline heredocs) lets us replay/mutate them across
# the meta-tests.
VERDICTS_DIR="$FIXTURE/.canned-verdicts"
mkdir -p "$VERDICTS_DIR"

cat > "$VERDICTS_DIR/needs-revision-iter1.json" <<'JSON'
{
  "verdict": "needs_revision",
  "criterion_results": [
    {"criterion": "C1", "pass": true,  "justification": "POST /login wired per SPEC."},
    {"criterion": "C2", "pass": false, "justification": "No test exercises the 401 path for invalid creds."}
  ],
  "required_fixes": [
    "server/login.test.ts — add a test asserting 401 on invalid credentials."
  ],
  "iteration": 1,
  "rubric_version": "1"
}
JSON

cat > "$VERDICTS_DIR/satisfied-iter2.json" <<'JSON'
{
  "verdict": "satisfied",
  "criterion_results": [
    {"criterion": "C1", "pass": true, "justification": "POST /login wired per SPEC."},
    {"criterion": "C2", "pass": true, "justification": "server/login.test.ts now covers the 401 path."}
  ],
  "required_fixes": [],
  "iteration": 2,
  "rubric_version": "1"
}
JSON

# Corrupted verdict — missing the required `rubric_version` key. Used
# in the META-TEST.
cat > "$VERDICTS_DIR/corrupt-missing-key.json" <<'JSON'
{
  "verdict": "satisfied",
  "criterion_results": [
    {"criterion": "C1", "pass": true, "justification": "ok"}
  ],
  "required_fixes": [],
  "iteration": 1
}
JSON

# Corrupted verdict — verdict outside the allowed enum.
cat > "$VERDICTS_DIR/corrupt-bad-enum.json" <<'JSON'
{
  "verdict": "maybe",
  "criterion_results": [],
  "required_fixes": [],
  "iteration": 1,
  "rubric_version": "1"
}
JSON

# Corrupted verdict — top-level is an array, not an object.
cat > "$VERDICTS_DIR/corrupt-not-object.json" <<'JSON'
[1, 2, 3]
JSON

# Helpers shared with escalation-binding.sh shape.
ensure_tracking() {
    printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"
}

npm_count() {
    [ -f "$NPM_LOG" ] || { echo "0"; return; }
    grep -c . "$NPM_LOG" 2>/dev/null || echo "0"
}

labels_for() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}

comment_count_matching() {
    bd show "$1" --json 2>/dev/null \
        | jq -r --arg pat "$2" \
            'if type == "array" then .[0].comments else .comments end // [] | map(select(.text | test($pat))) | length' \
        2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
# Section 1: enter sets rubric-pending alongside qa-gate-entered.

TID=$(cd "$FIXTURE" && bd create "Rubric loop happy-path" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
assert_match "rubric-loop-1: seed task id present" '^[a-z0-9-]+\.' "$TID"

ENTER_OUT=$(bash "$QG" enter "$TID")
assert_json_field "rubric-loop-1: enter ok=true" "$ENTER_OUT" '.ok' "true"
LABELS_1=$(labels_for "$TID")
assert_contains "rubric-loop-1: rubric-pending set on enter" \
    "rubric-pending" "$LABELS_1"
assert_contains "rubric-loop-1: qa-gate-entered set on enter" \
    "qa-gate-entered" "$LABELS_1"

# ---------------------------------------------------------------------------
# Section 2: grade-record(needs_revision, iteration 1) — comment recorded,
# labels unchanged.

bd label add "$TID" qa-pending >/dev/null 2>&1

GR_OUT_1=$(bash "$QG" grade-record "$TID" --file "$VERDICTS_DIR/needs-revision-iter1.json")
assert_json_field "rubric-loop-2: grade-record ok=true on needs_revision" \
    "$GR_OUT_1" '.ok' "true"
assert_json_field "rubric-loop-2: grade-record status=needs_revision" \
    "$GR_OUT_1" '.status' "needs_revision"

# Labels stayed where they were — qa-blocked round-trip is the QA agent's
# move, not grade-record's.
LABELS_2=$(labels_for "$TID")
assert_contains "rubric-loop-2: rubric-pending preserved after needs_revision" \
    "rubric-pending" "$LABELS_2"
SATISFIED_PRESENT_2=$(printf '%s' ",$LABELS_2," | grep -c ',rubric-satisfied,' || true)
SATISFIED_PRESENT_2=$(printf '%s' "$SATISFIED_PRESENT_2" | tr -d '[:space:]')
assert_eq "rubric-loop-2: rubric-satisfied absent on needs_revision" "0" \
    "$SATISFIED_PRESENT_2"

# Comment matches the spec shape: "RUBRIC <version> iteration <n>: <verdict> — <summary>"
RUBRIC_COMMENT_COUNT=$(comment_count_matching "$TID" "RUBRIC 1 iteration 1: needs_revision")
assert_eq "rubric-loop-2: RUBRIC iteration-1 comment posted" "1" \
    "$RUBRIC_COMMENT_COUNT"

# ---------------------------------------------------------------------------
# Section 3: qa-gate.sh block — the QA agent pastes required_fixes into
# the block comment. We're not asserting on the comment text directly
# beyond it being recorded; the contract is "block label added,
# qa-gate-entered preserved" + the block comment exists.

BLOCK_OUT=$(bash "$QG" block "$TID" "Rubric needs_revision (iteration 1): server/login.test.ts — add a test asserting 401 on invalid credentials. Re-grade after the specialist addresses these. See the RUBRIC comment for the full criterion-by-criterion verdict.")
assert_json_field "rubric-loop-3: block ok=true" "$BLOCK_OUT" '.ok' "true"
assert_json_field "rubric-loop-3: block status=blocked" "$BLOCK_OUT" '.status' "blocked"
LABELS_3=$(labels_for "$TID")
assert_contains "rubric-loop-3: qa-blocked added" "qa-blocked" "$LABELS_3"
assert_contains "rubric-loop-3: qa-gate-entered preserved through block" \
    "qa-gate-entered" "$LABELS_3"
# rubric-pending must still be on the task — the rubric cycle isn't
# satisfied yet; block doesn't clear it.
assert_contains "rubric-loop-3: rubric-pending preserved through block" \
    "rubric-pending" "$LABELS_3"

# The QA-GATE BLOCKED audit comment is recorded.
BLOCK_COMMENT_COUNT=$(comment_count_matching "$TID" "QA-GATE BLOCKED")
assert_eq "rubric-loop-3: QA-GATE BLOCKED comment recorded" "1" \
    "$BLOCK_COMMENT_COUNT"

# ---------------------------------------------------------------------------
# Section 4: re-enter on the same task — fresh cycle.
#
# Simulate the specialist round-trip landing: the task is qa-blocked,
# the specialist fixed the failing criterion, and now QA re-enters to
# re-grade. enter() must (per qa-gate.sh enter logic):
#   - keep rubric-pending set
#   - clear stale rubric-satisfied (none here, but the path runs)
#   - clear escalation labels (none here either)
#   - reset the per-iteration counter

REENTER_OUT=$(bash "$QG" enter "$TID")
assert_json_field "rubric-loop-4: re-enter ok=true" "$REENTER_OUT" '.ok' "true"
LABELS_4=$(labels_for "$TID")
assert_contains "rubric-loop-4: rubric-pending re-set on re-enter" \
    "rubric-pending" "$LABELS_4"

# ---------------------------------------------------------------------------
# Section 5: grade-record(satisfied, iteration 2) — rubric-pending
# removed, rubric-satisfied added.

GR_OUT_2=$(bash "$QG" grade-record "$TID" --file "$VERDICTS_DIR/satisfied-iter2.json")
assert_json_field "rubric-loop-5: grade-record ok=true on satisfied" \
    "$GR_OUT_2" '.ok' "true"
assert_json_field "rubric-loop-5: grade-record status=satisfied" \
    "$GR_OUT_2" '.status' "satisfied"

LABELS_5=$(labels_for "$TID")
assert_contains "rubric-loop-5: rubric-satisfied added on satisfied verdict" \
    "rubric-satisfied" "$LABELS_5"
PENDING_PRESENT_5=$(printf '%s' ",$LABELS_5," | grep -c ',rubric-pending,' || true)
PENDING_PRESENT_5=$(printf '%s' "$PENDING_PRESENT_5" | tr -d '[:space:]')
assert_eq "rubric-loop-5: rubric-pending removed on satisfied verdict" "0" \
    "$PENDING_PRESENT_5"

# Iteration-2 comment recorded with the spec shape.
RUBRIC_COMMENT_COUNT_2=$(comment_count_matching "$TID" "RUBRIC 1 iteration 2: satisfied")
assert_eq "rubric-loop-5: RUBRIC iteration-2 satisfied comment posted" "1" \
    "$RUBRIC_COMMENT_COUNT_2"

# ---------------------------------------------------------------------------
# Section 6: qa-gate.sh approve — rubric-satisfied survives as the audit
# trail; the approval comment cites the verdict. Stop-hook contract is
# untouched (principle 6).

APPROVE_OUT=$(bash "$QG" approve "$TID" "Rubric v1 satisfied at iteration 2 (all default criteria pass). Verified: login handles invalid email with clear error.")
assert_json_field "rubric-loop-6: approve ok=true" "$APPROVE_OUT" '.ok' "true"
assert_json_field "rubric-loop-6: approve status=approved" "$APPROVE_OUT" '.status' "approved"

LABELS_6=$(labels_for "$TID")
assert_contains "rubric-loop-6: qa-approved set" "qa-approved" "$LABELS_6"
# rubric-satisfied is the audit-trail label and MUST survive approve.
assert_contains "rubric-loop-6: rubric-satisfied SURVIVES approve (audit trail)" \
    "rubric-satisfied" "$LABELS_6"
# Approve also clears qa-gate-entered + qa-pending.
ENTERED_PRESENT_6=$(printf '%s' ",$LABELS_6," | grep -c ',qa-gate-entered,' || true)
ENTERED_PRESENT_6=$(printf '%s' "$ENTERED_PRESENT_6" | tr -d '[:space:]')
assert_eq "rubric-loop-6: qa-gate-entered removed after approve" "0" \
    "$ENTERED_PRESENT_6"

# The approve comment is recorded and carries the verdict citation we
# passed in (this is the "must cite the verdict" rule's audit signal).
APPROVE_COMMENT_COUNT=$(comment_count_matching "$TID" "Rubric v1 satisfied at iteration 2")
assert_eq "rubric-loop-6: approve comment cites the rubric verdict" "1" \
    "$APPROVE_COMMENT_COUNT"

# ---------------------------------------------------------------------------
# Section 7: cap-path coupling — the 0.2 escalation machinery continues
# to work with rubric labels present on the same task. The PROMPT-level
# 3-iteration rubric cap (qa.md section 6e) is L2-untestable-by-design
# (it lives in the QA agent's prompt, not in any script). The
# SCRIPT-testable slice we assert here is:
#
#   - A fresh task with rubric-pending set advances through
#     verify-before-stop.sh's iteration loop.
#   - When iter hits MAX_ITERATIONS (default 3), qa-escalated is set on
#     the task WITHOUT affecting the rubric labels.
#   - Both label families (rubric-* and qa-escalated) coexist; neither
#     contaminates the other's lifecycle.
#
# This is the coupling claim — the 0.2 escalation contract continues to
# hold under the new label vocabulary.

TID_CAP=$(cd "$FIXTURE" && bd create "Rubric+escalation coexistence" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID_CAP" >/dev/null
bd label add "$TID_CAP" qa-pending >/dev/null 2>&1

LABELS_CAP_PRE=$(labels_for "$TID_CAP")
assert_contains "rubric-loop-7: rubric-pending set before cap drive" \
    "rubric-pending" "$LABELS_CAP_PRE"

# Reset the npm counter so we can read the cap-drive count cleanly.
: > "$NPM_LOG"

# Drive 3 Stop fires — iter 1, 2, 3. Iter 3 is the cap-hit which
# transitions to escalated.
ensure_tracking
printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" >/dev/null 2>&1 || true
ensure_tracking
printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" >/dev/null 2>&1 || true
ensure_tracking
printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" >/dev/null 2>&1 || true

assert_eq "rubric-loop-7: npm invoked once per iter through cap (count=3)" \
    "3" "$(npm_count)"

LABELS_CAP_POST=$(labels_for "$TID_CAP")
assert_contains "rubric-loop-7: qa-escalated engaged at cap" \
    "qa-escalated" "$LABELS_CAP_POST"
# Rubric labels are unchanged by the escalation transition.
assert_contains "rubric-loop-7: rubric-pending coexists with qa-escalated" \
    "rubric-pending" "$LABELS_CAP_POST"
SATISFIED_PRESENT_CAP=$(printf '%s' ",$LABELS_CAP_POST," | grep -c ',rubric-satisfied,' || true)
SATISFIED_PRESENT_CAP=$(printf '%s' "$SATISFIED_PRESENT_CAP" | tr -d '[:space:]')
assert_eq "rubric-loop-7: rubric-satisfied NOT inadvertently added by escalation" \
    "0" "$SATISFIED_PRESENT_CAP"

# ---------------------------------------------------------------------------
# Section 8: META-TEST — corrupt scripted verdicts.
# grade-record rejects malformed input with the structured error envelope
# (`ok=false`, `error_key=...`, `usage=...`). This is the spec's
# guard that the QA agent gets a precise re-prompt rather than a silent
# accept of garbage.

TID_M=$(cd "$FIXTURE" && bd create "META: malformed verdict" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID_M" >/dev/null

# 8a. Missing required key (rubric_version) — error_key carries the
# missing-key signal so the QA agent can re-spawn precisely.
META_OUT_MISSING=$(bash "$QG" grade-record "$TID_M" --file "$VERDICTS_DIR/corrupt-missing-key.json" 2>&1 || true)
META_OK_MISSING=$(printf '%s' "$META_OUT_MISSING" | tail -1 | jq -r 'if has("ok") then .ok else "?" end' 2>/dev/null || echo "?")
META_EKEY_MISSING=$(printf '%s' "$META_OUT_MISSING" | tail -1 | jq -r '.error_key // ""' 2>/dev/null || echo "")
assert_eq "rubric-loop-8a: grade-record rejects missing-key verdict (ok=false)" \
    "false" "$META_OK_MISSING"
assert_contains "rubric-loop-8a: error_key names the missing key" \
    "missing_key:rubric_version" "$META_EKEY_MISSING"

# 8b. Verdict outside the allowed enum.
META_OUT_ENUM=$(bash "$QG" grade-record "$TID_M" --file "$VERDICTS_DIR/corrupt-bad-enum.json" 2>&1 || true)
META_OK_ENUM=$(printf '%s' "$META_OUT_ENUM" | tail -1 | jq -r 'if has("ok") then .ok else "?" end' 2>/dev/null || echo "?")
META_EKEY_ENUM=$(printf '%s' "$META_OUT_ENUM" | tail -1 | jq -r '.error_key // ""' 2>/dev/null || echo "")
assert_eq "rubric-loop-8b: grade-record rejects bad-enum verdict (ok=false)" \
    "false" "$META_OK_ENUM"
assert_eq "rubric-loop-8b: error_key=verdict_invalid_enum" \
    "verdict_invalid_enum" "$META_EKEY_ENUM"

# 8c. Top-level is an array, not an object.
META_OUT_OBJ=$(bash "$QG" grade-record "$TID_M" --file "$VERDICTS_DIR/corrupt-not-object.json" 2>&1 || true)
META_OK_OBJ=$(printf '%s' "$META_OUT_OBJ" | tail -1 | jq -r 'if has("ok") then .ok else "?" end' 2>/dev/null || echo "?")
META_EKEY_OBJ=$(printf '%s' "$META_OUT_OBJ" | tail -1 | jq -r '.error_key // ""' 2>/dev/null || echo "")
assert_eq "rubric-loop-8c: grade-record rejects array-top-level verdict (ok=false)" \
    "false" "$META_OK_OBJ"
assert_eq "rubric-loop-8c: error_key=not_an_object" \
    "not_an_object" "$META_EKEY_OBJ"

# After the rejected attempts the task labels should be exactly what
# `enter` set — no rubric-satisfied sneaked in via the malformed inputs.
LABELS_M=$(labels_for "$TID_M")
M_SATISFIED=$(printf '%s' ",$LABELS_M," | grep -c ',rubric-satisfied,' || true)
M_SATISFIED=$(printf '%s' "$M_SATISFIED" | tr -d '[:space:]')
assert_eq "rubric-loop-8: malformed verdicts do not flip labels" \
    "0" "$M_SATISFIED"
assert_contains "rubric-loop-8: rubric-pending preserved through rejections" \
    "rubric-pending" "$LABELS_M"

# ---------------------------------------------------------------------------
# Section 9: META-TEST (sensitivity) — stub the satisfied-branch label
# flip in qa-gate.sh and re-run the satisfied assertions. The label-flip
# assertions in Section 5 MUST fail under the stub.
#
# This mirrors qa-gate-grade-record.test.sh's META-TEST pattern (and
# the escalation-binding.sh counter-mutation pattern): build a second
# fixture, replace its qa-gate.sh with a copy whose label-flip is
# neutralized, and re-run the satisfied path against it.
#
# If the spec's satisfied-label assertions still pass under the stub,
# they aren't actually sensitive to the script's behaviour and the
# regression coverage is vacuous.

mk_fixture
FIXTURE_M="$COMPONENT_FIXTURE_PATH"
QG_M="$FIXTURE_M/.claude/scripts/qa-gate.sh"

# Build a stubbed copy of qa-gate.sh whose satisfied-branch label
# operations are neutered. awk swaps the two label-mutation lines for
# no-ops while leaving the rest of the script untouched.
PLUGIN_QG=$(readlink "$QG_M")
rm "$QG_M"
awk '
    # Inside cmd_grade_record satisfied branch: neutralize the label flip.
    /remove_rubric_pending "\$tid" \|\| removed_pending=0/ {
        print "    # META-TEST stub: label flip neutralized to prove sensitivity."
        print "    removed_pending=0  # would have flipped; now does nothing"
        next
    }
    /if ! add_label "\$tid" "rubric-satisfied"; then/ {
        print "    # META-TEST stub: rubric-satisfied add neutralized."
        print "    added_satisfied=0  # would have flipped; now does nothing"
        print "    if false; then"
        next
    }
    { print }
' "$PLUGIN_QG" > "$QG_M"
chmod +x "$QG_M"

# Sanity: the stub must have actually been installed. Look for the
# sentinel comment line we injected. If awk didn't match (e.g. someone
# renamed the function and the regex went stale), we want to FAIL the
# meta-test loudly rather than silently report a vacuous PASS.
if ! grep -qF 'META-TEST stub: label flip neutralized' "$QG_M"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("rubric-loop-9: META-TEST stub did NOT install (awk regex stale?)")
    printf '  FAIL: rubric-loop-9: META-TEST stub did not install — the satisfied-label assertions below cannot be trusted\n'
fi

# Re-run a satisfied verdict against the stubbed copy. The label flip
# would have set rubric-satisfied; under the stub it must NOT appear.
mkdir -p "$FIXTURE_M/.canned-verdicts"
cat > "$FIXTURE_M/.canned-verdicts/satisfied-meta.json" <<'JSON'
{
  "verdict": "satisfied",
  "criterion_results": [{"criterion": "C1", "pass": true, "justification": "ok"}],
  "required_fixes": [],
  "iteration": 1,
  "rubric_version": "1"
}
JSON

TID_META=$(cd "$FIXTURE_M" && bd create "META: stubbed satisfied flip" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_M" enter "$TID_META" >/dev/null

# Pre-condition: rubric-pending is on the task (enter set it).
LABELS_META_PRE=$(labels_for "$TID_META")
assert_contains "rubric-loop-9: META pre-condition rubric-pending set" \
    "rubric-pending" "$LABELS_META_PRE"

# Run the stubbed grade-record. The script's `ok=true` envelope still
# reports satisfied (the comment IS still posted — only the label flip
# is stubbed), but the labels DON'T flip.
bash "$QG_M" grade-record "$TID_META" --file "$FIXTURE_M/.canned-verdicts/satisfied-meta.json" >/dev/null 2>&1

LABELS_META_POST=$(labels_for "$TID_META")

# Under the stub, rubric-satisfied is NOT added (the if-true was
# neutered) — assert the spec-5 satisfied invariant WOULD fail.
META_SATISFIED_PRESENT=$(printf '%s' ",$LABELS_META_POST," | grep -c ',rubric-satisfied,' || true)
META_SATISFIED_PRESENT=$(printf '%s' "$META_SATISFIED_PRESENT" | tr -d '[:space:]')
assert_eq "rubric-loop-9: META spec-5 'satisfied adds rubric-satisfied' WOULD fail under stub" \
    "0" "$META_SATISFIED_PRESENT"

# And rubric-pending is NOT removed under the stub — spec-5 first half
# invariant would also fail.
META_PENDING_PRESENT=$(printf '%s' ",$LABELS_META_POST," | grep -c ',rubric-pending,' || true)
META_PENDING_PRESENT=$(printf '%s' "$META_PENDING_PRESENT" | tr -d '[:space:]')
assert_eq "rubric-loop-9: META spec-5 'satisfied removes rubric-pending' WOULD fail under stub" \
    "1" "$META_PENDING_PRESENT"

[ "$FAIL" -eq 0 ]

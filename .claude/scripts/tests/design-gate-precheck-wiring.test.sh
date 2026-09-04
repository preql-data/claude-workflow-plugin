#!/bin/bash
# design-gate-precheck-wiring.test.sh — claude-workflow-plugin-i8cx, R3-F2b
# WIRING fix: verify-before-stop.sh's DESIGN-DISCIPLINE block used to skip
# calling `qa-gate.sh design-gate-precheck` ENTIRELY whenever the matching
# approval record carried the literal `[design bypass:` marker:
#
#   if printf '%s' "$MATCHED_APPROVAL_TEXT" | grep -qF '[design bypass:'; then
#       <log only, no gate check>
#
# Every `--no-design` approval writes that marker unconditionally, so the
# check could not distinguish "no design phase, permanently skip" from "a
# design that was satisfied and unconflicted a moment ago, re-check it
# still is." What was missing is that verify-before-stop.sh ever CALLED
# design-gate-precheck when the marker was present. THE FIX (R3-F2b, still
# in force, UNCHANGED by everything below): the conditional skip became an
# UNCONDITIONAL call. THIS FILE'S JOB is proving that call survives and is
# genuinely consulted; it does not depend on, and after
# claude-workflow-plugin-i8cx (operator ruling, independent review rounds
# 6-8) no longer CAN depend on, any waiver mechanism.
#
# HISTORY, so a reader diffing this file understands why Section 1 changed
# shape. Through independent review round 5, this file exercised R3-F2b
# using qa-gate.sh's own unit-scoped waiver subtraction (DESIGN-GATE-
# PRECHECK-UNIT-SCOPE): waive unit U1 via --no-design, prove a NEW conflict
# on a DIFFERENT unit U2 still blocked. Independent review rounds 6-8 found
# FOUR HIGH findings against that waiver mechanism itself (forgeable text,
# wrong-hash-bound, blanket-not-per-record subtraction, a clearing predicate
# that accepted a content edit with no accompanying review) and the operator
# removed it entirely rather than fix it a fifth time — see qa-gate.sh's own
# DESIGN-CONFLICT-REFUSAL header for the full finding list. Section 1 below
# proves the SAME property (the unconditional call survives, and its result
# genuinely drives the Stop decision) using a mechanism that does not
# require a waiver to exist: an ORDINARY `--no-design` approval on a design
# that was satisfied and unconflicted AT APPROVAL TIME still writes the
# plain `[design bypass:` marker (DESIGN-BYPASS-UNNEEDED-REFUSAL, which used
# to forbid exactly that, was ALSO removed — judged on its own merits and
# found to exist only to prevent a harm R3-F2b's unconditional call had
# already fixed a different way); a conflict filed AFTER that approval must
# still be caught, because the call is unconditional. This is a strictly
# SIMPLER reproduction of the same wiring property, and it doubles as an
# end-to-end (real bd, real git, real verify-before-stop.sh) leg of the
# negative control design-review-record.test.sh Section 8h proves at the
# qa-gate.sh CLI layer: the approval's own reason/summary carries the
# RETIRED waiver bracket text verbatim, proving that text has no authorizing
# effect at the Stop hook either.
#
# THREE LEGS THIS FILE PROVES AGAINST THE SHIPPED, UNSTUBBED HOOK:
#   Section 1 (real bd, real git, real qa-gate.sh):
#     1a a `[design bypass:` marker is present (an ordinary --no-design
#        approval; the design was satisfied and unconflicted, so there was
#        nothing to disclose), nothing else filed -> Stop ALLOWS.
#     1b a NEW conflict filed AFTER that approval -> Stop BLOCKS, even
#        though the marker from 1a is still on the governing approval
#        record and even though that record's own reason/summary contains
#        the retired waiver bracket text verbatim. qa-gate.sh's own
#        design-gate-precheck output (which the Stop hook now
#        unconditionally consults, and whose exit code alone drives its
#        decision) is independently re-checked in the SAME tree state and
#        demonstrably cites the conflict — see the NOTE below for exactly
#        what the Stop hook's own surfaced text does and does not repeat
#        from that output.
#     1c (leg 2) a task with NO design phase AT ALL, approved --no-design ->
#         Stop still ALLOWS. This is the anti-overreach control named in the
#         authorization record as "not optional": without it the fix would
#         deadlock every doc-only commit, which is exactly what the skip
#         existed to prevent. UNCHANGED by the waiver removal — this axis
#         never depended on it.
#
#   Section 2 (stubbed qa-gate.sh, no bd/.beads/design phase at all — the
#   pairing convention's non-vacuity/specific-misbehaviour/restore-control
#   discriminator): proves the unconditional call is genuinely CONSULTED,
#   not a dead call whose result is discarded. With a `[design bypass:]`
#   marker present:
#     2a a stub that ALWAYS refuses design-gate-precheck -> pre-fix ALLOWS
#        (the bug: skip fires, stub never runs), post-fix BLOCKS naming the
#        stub's own error_key. Non-vacuity + specific misbehaviour.
#     2b (restore control) the same marker, a stub that ALWAYS reports ready
#        -> ALLOWS both before and after — the fix must not spuriously block
#        a genuinely-satisfied, bypass-approved task merely because a call
#        now happens where none did before.
#
# NOTE ON WHAT THE STOP HOOK'S OWN SURFACE REPEATS. Read verify-before-
# stop.sh's DESIGN-DISCIPLINE block before assuming otherwise: it extracts
# ONLY `.error_key` from design-gate-precheck's JSON (DESIGN_GATE_KEY) into
# DESIGN_DISCIPLINE_DETAIL — `.observations` (where the affected unit id
# actually appears) is never read there. So the Stop hook's own block
# reason says "error_key=design_conflict_open", not the unit id, both
# before and after R3-F2b — a pre-existing characteristic of that DETAIL
# string, not a gap this file's scope covers. 1b below proves the
# discrimination at the layer that is actually true today: qa-gate.sh's own
# precheck output, which the Stop hook's block/release DECISION is
# provably driven by (1a releases, 1b blocks, only the conflict differs)
# even though its printed text does not repeat the affected unit by name.
#
# Exit codes: 0 all assertions passed | 1 one or more failed | 2 harness error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

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

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }

# ===========================================================================
# Section 1 fixture: real bd, real git, all shipped scripts unmodified/
# uncoupled from any other test file under concurrent edit (self-contained,
# matching this tier's own convention — see override-disclosure.test.sh's
# header for why: "under concurrent edit elsewhere in this change; the
# pattern is reproduced here, self-contained, rather than coupled to a file
# this task does not own").
# ===========================================================================

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"

if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — design-gate-precheck-wiring tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — design-gate-precheck-wiring tests require jq."
    exit 2
fi
REAL_GIT="$(command -v git)"
if [ -z "$REAL_GIT" ]; then
    echo "git not on PATH — design-gate-precheck-wiring tests require git."
    exit 2
fi

FIXTURE=$(mktemp -d -t design-gate-precheck-wiring.XXXXXX)
TEST_HOME=$(mktemp -d -t design-gate-precheck-wiring-home.XXXXXX)
WORK=$(mktemp -d -t design-gate-precheck-wiring-work.XXXXXX)
KEEP_FIXTURE="${KEEP_FIXTURE:-0}"
[ "${1:-}" = "--keep" ] && KEEP_FIXTURE=1

# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\nTest HOME: %s\nWork (Section 2): %s\n' "$FIXTURE" "$TEST_HOME" "$WORK"
    else
        chmod -R u+rwX "$FIXTURE" "$WORK" 2>/dev/null || true
        rm -rf "$FIXTURE" "$TEST_HOME" "$WORK"
    fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.beads" "$FIXTURE/bin" "$FIXTURE/docs/specs" \
    "$TEST_HOME/.claude/projects"

cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

mkdir -p "$FIXTURE/.claude/vendor/superpowers/brainstorming"
cp "$PLUGIN_DIR/.claude/vendor/superpowers/brainstorming/SKILL.md" \
    "$FIXTURE/.claude/vendor/superpowers/brainstorming/SKILL.md"

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

VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
QG="$FIXTURE/.claude/scripts/qa-gate.sh"
WM="$FIXTURE/.claude/scripts/workflow-manifest.sh"
IR="$FIXTURE/.claude/scripts/impact-report.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# Real git repo, matching verify-design-discipline.sh's (L2) own precedent:
# keep the harness's own scaffolding out of git's view so the design artifact
# under docs/specs/ is the only tracked, reviewable diff, and a real `git
# status --porcelain` succeeds for every reconcile/baseline call the shipped
# scripts make along the way.
printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' > "$FIXTURE/.gitignore"
(cd "$FIXTURE" && "$REAL_GIT" init -q \
    && "$REAL_GIT" config user.email t@t.t && "$REAL_GIT" config user.name t \
    && "$REAL_GIT" add -A && "$REAL_GIT" commit -qm baseline >/dev/null) || true

rm -f "$FIXTURE/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$FIXTURE/.claude/scripts/detect-stack.sh"
chmod +x "$FIXTURE/.claude/scripts/detect-stack.sh"

# baseline_incidental_dirt equivalent (L2 lib/fixture.sh) — capture whatever
# fixture scaffolding exists as pre-existing BEFORE any task's own tracked
# file is written, so it is never later counted as part of a change set.
bash "$QG" baseline-capture --by session-start --exclude-tracked >/dev/null 2>&1 || true

stop_decision() {
    printf '%s' '{"stop_hook_active": false}' \
        | bash "$VBS" 2>/dev/null | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null
}
stop_reason() {
    printf '%s' '{"stop_hook_active": false}' \
        | bash "$VBS" 2>/dev/null | tail -1 | jq -r '.reason // ""' 2>/dev/null
}

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
latest_approval() {
    comments_of "$1" | grep -E '^QA-GATE APPROVED ' | tail -1
}

seed_grilling() {
    local tid="$1"
    bash "$QG" grilling-record "$tid" --rounds 3 --questions 5 --approaches 2 --unresolved 0 \
        "design-gate-precheck-wiring.test.sh: exercising the design-discipline Stop-time wiring" \
        >/dev/null 2>&1
}

# design_artifact_path <tid> — mirrors qa-gate.sh's own derivation
# (design_artifact_path_for), so this never guesses a second one.
design_artifact_path() {
    local sanitized
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/docs/specs/%s.md' "$FIXTURE" "$sanitized"
}

# write_artifact <path> <tid> <u1-goal> <u2-goal> — a minimal, schema-valid
# TWO-unit design artifact (byte-shape borrowed from design-review-record.
# test.sh's own write_artifact, which this file does not source — see the
# header on self-containment). Two real declared units are required:
# design-conflict's UNIT-MEMBERSHIP-GATE refuses --unit U2 against a
# single-unit artifact (unit_not_in_artifact).
write_artifact() {
    local path="$1" tid="$2" u1_goal="${3:-goal for unit U1}" u2_goal="${4:-goal for unit U2}"
    cat > "$path" <<ARTIFACT
# Design — $tid

## Problem
Component-tier test subject (design-gate-precheck-wiring.test.sh).

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
      "goal": "$u1_goal",
      "acceptance": [ { "id": "AC1", "text": "test fixture: nothing asserted" } ],
      "files": [ ".claude/scripts/qa-gate.sh" ],
      "verification": "make test",
      "depends_on": []
    },
    {
      "unit_id": "U2",
      "role": "devops",
      "goal": "$u2_goal",
      "acceptance": [ { "id": "AC2", "text": "test fixture: nothing asserted" } ],
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

# seed_review <tid> — everything approve needs EXCEPT a design verdict
# (IMPLEMENTER + REVIEW-ARTIFACT + COMPLETION), matching design-review-
# record.test.sh's own seed_approvable in shape. Echoes any docs/reviews/
# line(s) reconcile-tracker folded into changed-files.txt on stdout, so the
# caller can snapshot it once and restage it precisely — the tracker is
# truncated by `approve` itself and by every Stop release, so nothing later
# can re-derive this line by re-reading the tracker.
seed_review() {
    local tid="$1" reviewer="${2:-qa-claude}" role="${3:-devops}"
    local ts hash art pay
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1 \
        || bd comment add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1
    hash=$(bash "$IR" --hash-only 2>/dev/null || echo "")
    [ -z "$hash" ] && hash="unverified"
    art="$TRACK/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"%s","reviewer_model":"seeded-fixture","reviewer_pin":"seeded-fixture","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded fixture","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
        "$tid" "$reviewer" "$hash" > "$art"
    bash "$QG" review-record "$tid" < "$art" >/dev/null 2>&1
    bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
    bash "$IR" "$tid" >/dev/null 2>&1 || true
    pay="$TRACK/completion-draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    printf '{"task_id":"%s","role":"%s","model":"seeded","pin":"seeded","files_changed":[],"tests_added":[],"decisions":["seeded"],"blockers":[],"llm_observations":"seeded by design-gate-precheck-wiring.test.sh","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown"}\n' \
        "$tid" "$role" > "$pay"
    bash "$QG" completion-record "$tid" --file "$pay" >/dev/null 2>&1
    grep -E '/docs/reviews/' "$TRACK/changed-files.txt" 2>/dev/null || true
}

# restage <tid> <file>... — current-task marker + changed-files.txt
# reconstruction ahead of a Stop fire. `approve` and every Stop RELEASE both
# truncate changed-files.txt as a side effect (write_gate_baseline +
# truncate_changed_files_tracker), so the tracker must be rebuilt to the
# EXACT set that produced the bound change_set_hash before every single Stop
# invocation in this file, not just the first.
restage() {
    local tid="$1"
    shift
    printf '%s\n' "$tid" > "$TRACK/current-task"
    : > "$TRACK/changed-files.txt"
    local f
    for f in "$@"; do
        [ -n "$f" ] && printf '%s\n' "$f" >> "$TRACK/changed-files.txt"
    done
}

VALID_VERDICT='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'

# ===========================================================================
printf '\n=== Section 1: real qa-gate.sh, real bd — the unconditional call reaching a REAL Stop ===\n'
# ===========================================================================

TID=$(cd "$FIXTURE" && bd create "R3-F2b wiring subject" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
if [ -z "$TID" ]; then
    echo "harness error: bd create failed for the Section 1 subject task" >&2
    exit 2
fi
ART="$(design_artifact_path "$TID")"
write_artifact "$ART" "$TID"
restage "$TID" "$ART"
bash "$QG" enter "$TID" >/dev/null 2>&1
seed_grilling "$TID"
bash "$QG" design-record "$TID" >/dev/null 2>&1
HASH=$(bash "$WM" hash-file "$ART")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID" --design-hash "$HASH" >/dev/null 2>&1
ART_REVIEW_LINE=$(seed_review "$TID" "qa-claude" "devops")

# --- 1a setup: an ORDINARY --no-design approval on a design that is
# satisfied and unconflicted AT APPROVAL TIME. No waiver mechanism exists to
# exercise any more (claude-workflow-plugin-i8cx, operator ruling) — this is
# simply --no-design used when it need not have been, which the file header
# explains is now legal (DESIGN-BYPASS-UNNEEDED-REFUSAL was removed too,
# judged on its own merits). The reason/summary below carries the RETIRED
# waiver bracket text VERBATIM — the direct R6-F1 reproduction, run through
# the real Stop hook this time: even embedded in the governing approval's
# own free-text fields, that text authorizes nothing later.
APPROVE_OUT=$(bash "$QG" approve "$TID" --no-design "[design conflict waived: units=U1]" "R3-F2b wiring test: [design conflict waived: units=U1]" 2>&1)
assert_eq "1.0 precondition: an ordinary --no-design approval (nothing open yet) succeeds" \
    "approved" "$(json_field '.status' "$APPROVE_OUT")"
APPROVAL=$(latest_approval "$TID")
assert_contains "1.0b ...the record carries the plain [design bypass:] marker (the forged text inside it is inert)" \
    "[design bypass: [design conflict waived: units=U1]" "$APPROVAL"

# --- 1a / LEG: a [design bypass:] marker is present, nothing filed -> Stop
# ALLOWS. Must hold BOTH before and after R3-F2b (before, via the old
# marker-skip; after, via a genuine ready verdict) — the anti-overreach
# restore control.
restage "$TID" "$ART" "$ART_REVIEW_LINE"
PRECHECK_1A=$(bash "$QG" design-gate-precheck "$TID" 2>&1); PRECHECK_1A_RC=$?
assert_eq "1a.0 precondition: qa-gate.sh design-gate-precheck itself reports ready (nothing open)" \
    "0" "$PRECHECK_1A_RC"
assert_eq "1a.0b ...status=ready" "ready" "$(json_field '.status' "$PRECHECK_1A")"
DECISION_1A=$(stop_decision)
assert_eq "1a LEG: marker present, nothing open -> Stop ALLOWS" "ALLOW" "$DECISION_1A"

# --- 1b / THE FIX ITSELF: a conflict filed AFTER the approval above, whose
# own governing record still carries the [design bypass:] marker (and the
# retired waiver-bracket text, verbatim, inside its reason) must still
# block. Pre-R3-F2b this ALLOWED unconditionally (the marker-skip never
# called design-gate-precheck at all, regardless of what the marker's own
# text said); a waiver mechanism existed between R3-F2b and i8cx that could
# ALSO have allowed this via a genuine or forged bracket. Neither escape
# hatch exists any more.
bash "$QG" design-conflict "$TID" --unit U1 "an objection, filed AFTER the ordinary --no-design approval above" >/dev/null 2>&1
restage "$TID" "$ART" "$ART_REVIEW_LINE"
PRECHECK_1B=$(bash "$QG" design-gate-precheck "$TID" 2>&1); PRECHECK_1B_RC=$?
assert_eq "1b.0 precondition: qa-gate.sh design-gate-precheck itself now refuses (exit 4)" "4" "$PRECHECK_1B_RC"
assert_eq "1b.0b ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$PRECHECK_1B")"
assert_contains "1b.0c ...names U1" "U1" "$(json_field '.observations' "$PRECHECK_1B")"

restage "$TID" "$ART" "$ART_REVIEW_LINE"
DECISION_1B=$(stop_decision)
assert_eq "1b THE FIX ITSELF: a conflict filed after a --no-design approval -> Stop BLOCKS (was ALLOW pre-R3-F2b, and could ALSO have been ALLOW pre-i8cx via the since-removed waiver)" \
    "block" "$DECISION_1B"
restage "$TID" "$ART" "$ART_REVIEW_LINE"
REASON_1B=$(stop_reason)
assert_contains "1b.1 the Stop hook's own reason cites the precheck's error_key" \
    "error_key=design_conflict_open" "$REASON_1B"
# See the file header NOTE: verify-before-stop.sh's DESIGN_DISCIPLINE_DETAIL
# extracts ONLY .error_key from design-gate-precheck's JSON, never
# .observations — so the Stop hook's own printed text does not repeat the
# unit id by name, before or after R3-F2b. 1b.0b/1b.0c above are the actual
# proof that the mechanism the Stop hook now unconditionally consults sees
# the conflict; 1a vs 1b is the behavioural proof, at the Stop hook's own
# decision, that this is what is firing — identical approval record,
# forged-text marker and all, only whether a conflict was filed afterward
# differs.

# ===========================================================================
printf '\n=== Section 1c: LEG 2 — genuinely no design phase, --no-design -> Stop still ALLOWS ===\n'
# ===========================================================================
# THE ANTI-OVERREACH CONTROL. Named "not optional" in the authorization
# record: without this, the fix would deadlock every doc-only commit, which
# is exactly what the marker-skip existed to prevent. No design-record, no
# design-review-record — EVER — for this task; compute_design_satisfied must
# read this as no_design_attempted, which design-gate-precheck's own B5
# leniency (unconditionally reached by this fix, not bypassed) maps to
# "ready" regardless of caller.

TID_ND=$(cd "$FIXTURE" && bd create "R3-F2b wiring: genuinely no design phase" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
if [ -z "$TID_ND" ]; then
    echo "harness error: bd create failed for the Section 1c subject task" >&2
    exit 2
fi
mkdir -p "$FIXTURE/src"
: > "$FIXTURE/src/other-1c.ts"
restage "$TID_ND" "src/other-1c.ts"
bash "$QG" enter "$TID_ND" >/dev/null 2>&1
ND_REVIEW_LINE=$(seed_review "$TID_ND" "qa-claude" "devops")
ND_APPROVE_OUT=$(bash "$QG" approve "$TID_ND" --no-design "this task has no design phase" "R3-F2b wiring test: ordinary no-design bypass" 2>&1)
assert_eq "1c.0 precondition: --no-design approve succeeds with no design phase at all" \
    "approved" "$(json_field '.status' "$ND_APPROVE_OUT")"
ND_APPROVAL=$(latest_approval "$TID_ND")
assert_contains "1c.0b ...the record carries the plain [design bypass:] marker" \
    "[design bypass: this task has no design phase" "$ND_APPROVAL"
assert_not_contains "1c.0c ...and NOT a waived-units bracket (nothing was ever open)" \
    "[design conflict waived:" "$ND_APPROVAL"

restage "$TID_ND" "src/other-1c.ts" "$ND_REVIEW_LINE"
PRECHECK_1C=$(bash "$QG" design-gate-precheck "$TID_ND" 2>&1); PRECHECK_1C_RC=$?
assert_eq "1c.1 precondition: qa-gate.sh design-gate-precheck itself reports ready (no_design_attempted leniency)" \
    "0" "$PRECHECK_1C_RC"
assert_eq "1c.1b ...status=ready" "ready" "$(json_field '.status' "$PRECHECK_1C")"

restage "$TID_ND" "src/other-1c.ts" "$ND_REVIEW_LINE"
DECISION_1C=$(stop_decision)
assert_eq "1c LEG 2 / ANTI-OVERREACH: genuinely no design phase, --no-design -> Stop ALLOWS (must hold both before and after the fix)" \
    "ALLOW" "$DECISION_1C"

# ===========================================================================
printf '\n=== Section 2: stubbed qa-gate.sh — proving the unconditional call is genuinely CONSULTED ===\n'
# ===========================================================================
# No bd, no git, no design phase — a fast, synthetic control isolating ONE
# fact: does verify-before-stop.sh's own release/block decision, with a
# `[design bypass:]` marker present, actually change when design-gate-
# precheck's answer changes? Pre-fix it cannot (the marker-skip never calls
# it); post-fix it must. Mirrors override-disclosure.test.sh's
# build_sandbox_discipline "design-fail" shape, WITH the bypass marker this
# file's own comment (line ~1001-1004 there) explicitly says that fixture
# does NOT carry — the marker is exactly the one variable this section adds.
#
# claude-workflow-plugin-yrij: the fabricated comment's `reviewed_by=` MUST
# be the literal "none", not an arbitrary placeholder identity. qa-gate.sh's
# writer (qa-gate.sh:4235, 4268-4327, 3713) sets reviewed_by to "none" if,
# and only if, --no-review was genuinely passed; every other path leaves a
# real identity, and this stub's `[review bypass:]` marker is meant to read
# as that genuine escape (the whole point is to skip review-discipline
# cleanly so design-discipline is what actually gets exercised). Before
# verify-before-stop.sh anchored that marker on reviewed_by=none, a
# placeholder like "test-fixture" worked by accident — the old reader
# treated ANY occurrence of the `[review bypass:` substring as sufficient.
# Same class as override-disclosure.test.sh's build_sandbox_release /
# build_sandbox_worktree_release / build_sandbox_discipline fixtures.

build_sandbox_stub() {
    local root="$1" precheck_mode="$2"
    mkdir -p "$root/.claude/scripts" "$root/.claude/.qa-tracking" "$root/notes" "$root/bin"
    # Copy the FULL, real script set (from Section 1's own $FIXTURE, already
    # populated from the plugin tree) rather than a hand-curated subset — a
    # missing collaborator (impact-report.sh, current-task.sh, ...) makes
    # current_change_set_hash() fail closed into the UNRELATED
    # LABEL_WITHOUT_RECORD path instead of the DESIGN-DISCIPLINE path this
    # section exists to isolate, which is a vacuous pass for the wrong reason
    # (measured: this is exactly what happened before this fix, see the
    # pre-fix run this file's own commit history/report records).
    cp "$FIXTURE/.claude/scripts/"*.sh "$root/.claude/scripts/"
    chmod +x "$root/.claude/scripts/"*.sh
    if [ "$precheck_mode" = "refuse" ]; then
        cat > "$root/.claude/scripts/qa-gate.sh" <<'QG'
#!/bin/bash
case "${1:-}" in
  status) printf '{"status":"approved"}\n' ;;
  design-gate-precheck) printf '{"error_key":"design_not_satisfied","observations":"stub: design-gate-precheck-wiring.test.sh Section 2a"}\n'; exit 4 ;;
  *) exit 0 ;;
esac
QG
    else
        cat > "$root/.claude/scripts/qa-gate.sh" <<'QG'
#!/bin/bash
case "${1:-}" in
  status) printf '{"status":"approved"}\n' ;;
  design-gate-precheck) printf '{"status":"ready"}\n'; exit 0 ;;
  *) exit 0 ;;
esac
QG
    fi
    chmod +x "$root/.claude/scripts/qa-gate.sh"
    cat > "$root/.claude/scripts/detect-stack.sh" <<'DS'
#!/bin/bash
printf '%s' '{"runner":"npm","test_cmd":"true","lint_cmd":"","type_cmd":"","overrides":{"test":false,"lint":false,"type":false}}'
DS
    chmod +x "$root/.claude/scripts/detect-stack.sh"
    printf '.claude/\nnotes/\nbin/\n.beads/\n' > "$root/.gitignore"
    (cd "$root" && "$REAL_GIT" init -q \
        && "$REAL_GIT" config user.email t@example.com && "$REAL_GIT" config user.name t \
        && mkdir -p src && printf 'code\n' > src/app.ts \
        && "$REAL_GIT" add .gitignore src >/dev/null && "$REAL_GIT" commit -qm init >/dev/null) || true
    printf 'x\n' > "$root/notes/impl.ts"
    printf '%s\n' "$root/notes/impl.ts" > "$root/.claude/.qa-tracking/changed-files.txt"
    printf 'tsk-stub\n' > "$root/.claude/.qa-tracking/current-task"
    mkdir -p "$root/.beads"
    local h
    h=$(CLAUDE_PROJECT_DIR="$root" bash "$IR" --hash-only 2>/dev/null)
    cat > "$root/bin/bd" <<BDSTUB
#!/bin/bash
if [ "\${1:-}" = "show" ]; then
    printf '%s' '{"comments":[{"text":"QA-GATE APPROVED change_set_hash=$h reviewed_by=none [review bypass: test fixture, nothing to review] [design bypass: stub fixture, exercising the wiring only]"}]}'
    exit 0
fi
exit 0
BDSTUB
    chmod +x "$root/bin/bd"
}

run_stop_hook_stub() {
    local root="$1"
    (cd "$root" && printf '{"stop_hook_active": false}' \
        | env PATH="$root/bin:$PATH" CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/verify-before-stop.sh" 2>"$WORK/stub-stderr.$$")
}

SB2A="$WORK/sb2a"
build_sandbox_stub "$SB2A" "refuse"
OUT_2A=$(run_stop_hook_stub "$SB2A")
assert_eq "2a NON-VACUITY + SPECIFIC MISBEHAVIOUR: marker present, a stub that ALWAYS refuses -> Stop BLOCKS (was ALLOW pre-fix: the skip never called the stub at all)" \
    "block" "$(printf '%s' "$OUT_2A" | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null)"
assert_contains "2a.1 ...the block reason names the stub's own error_key, proving the call's RESULT drove the decision" \
    "error_key=design_not_satisfied" "$(printf '%s' "$OUT_2A" | tail -1 | jq -r '.reason // ""' 2>/dev/null)"

SB2B="$WORK/sb2b"
build_sandbox_stub "$SB2B" "ready"
OUT_2B=$(run_stop_hook_stub "$SB2B")
assert_eq "2b RESTORE CONTROL: marker present, a stub that ALWAYS reports ready -> Stop still ALLOWS (no spurious block just because the call now happens)" \
    "ALLOW" "$(printf '%s' "$OUT_2B" | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null)"

# ===========================================================================
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

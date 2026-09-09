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
#   8. v5 Phase D5 (claude-workflow-plugin-fkm.7): `design-conflict` — the
#      writer (shape validation, the bjx injection reproduction for BOTH
#      unit_id and design_hash, auto-derived vs caller-claimed design_hash),
#      and its wiring into approve as a DESIGN-CONFLICT-REFUSAL block. THE
#      LEG THAT MATTERS MOST: the fkm.1.19 anti-regression — a newer,
#      approved DESIGN-REVIEW recorded at the SAME (unchanged) design_hash
#      is "silent about the unit" in the strongest sense (nothing in the
#      artifact moved), and must NOT retire an open conflict; only a GENUINE
#      amendment (a new design_hash, independently re-reviewed and approved)
#      does. Also: multiple conflicts on different units are each tracked
#      independently (no `last`-only reader), and a METatest proving the
#      sentinel region — not something incidental — is what refuses. (Item
#      10 below records that DESIGN-CONFLICT-REFUSAL later became
#      UNCONDITIONAL — no longer nested inside approve's DESIGN-SATISFIED-
#      REFUSAL, no longer skippable by --no-design.)
#
#   9. v5 D5 FOLLOW-UP (claude-workflow-plugin-i8cx, R2-F2/F3/F4 — sol-codex
#      round 2 independent review): three HIGH findings against item 8's own
#      shipped mechanism. R2-F3 ("the one that matters most" per the fix
#      task's own instructions, pinned in Section 8b/8c below): the clearing
#      predicate was a WHOLE-ARTIFACT hash comparison, so amending and
#      approving an UNRELATED unit silently cleared a DIFFERENT unit's open
#      conflict — retirement-by-omission one level under the fkm.1.19 shape
#      item 8 already guards. Fixed by keying clearance on a NEW unit_hash=
#      token (a live hash of the DISPUTED unit's own current content, never
#      the whole artifact); the writer's --design-hash is now a
#      CONFIRMATION of the live artifact hash, never a trusted claim,
#      closing "a stale/mistyped hash is born cleared" too — and --unit must
#      now name a REAL, declared unit (unit_not_in_artifact, a structural
#      consequence, not scope creep). This fix STANDS and is unaffected by
#      item 10. R2-F2 (pinned in Section 8b): the conflict check lived ONLY
#      in cmd_approve, so a conflict filed AFTER approval never re-armed the
#      Stop-time recheck (verify-before-stop.sh's own call is to
#      design-gate-precheck, which only asked compute_design_satisfied).
#      Fixed inside cmd_design_gate_precheck, with NO caller-side change
#      needed — verified by reading verify-before-stop.sh's own branch,
#      which keys on exit status alone. This fix ALSO STANDS. R2-F4
#      (originally pinned in Section 8h, HISTORICAL — see item 10):
#      --no-design's audited bypass wrote the SAME generic marker for "no
#      design phase" and "a KNOWN OPEN conflict, deliberately waived" —
#      indistinguishable in the durable record. R2-F4's ORIGINAL fix added
#      an ADDITIVE, conditional second bracket
#      (`[design conflict waived: units=<ids>]`) disclosing which units were
#      waived. Item 10 records why that entire disclosure-plus-waiver
#      mechanism was later REMOVED rather than repaired a further time.
#
#  10. v5 D5 WAIVER REMOVAL (claude-workflow-plugin-i8cx, independent review
#      rounds 6-8 — operator ruling). The R2-F4 disclosure bracket from item
#      9, and the R3-F2a/R3-F2b machinery items 8g/8h used to test
#      (DESIGN-BYPASS-UNNEEDED-REFUSAL, DESIGN-GATE-PRECHECK-UNIT-SCOPE,
#      latest_design_conflict_waiver_units), grew into a mechanism where
#      `--no-design` could WAIVE a real, open, evidenced DESIGN-CONFLICT.
#      FOUR independent HIGH findings against that mechanism, none of them
#      about item 9's own R2-F3/R2-F2 fixes (both of which stand):
#      R6-F1 the waiver was FORGEABLE — any ordinary approval summary
#      containing the literal text `[design conflict waived: units=<ids>]`
#      was read back as a real waiver by a later reader, because the
#      record's own free-text summary space is self-asserted; R6-F2 the
#      reader took the LATEST QA-GATE APPROVED comment without checking it
#      governs the CURRENT change-set hash; R6-F3 subtraction was by unit ID
#      with no per-record identity, so a waiver silently covered every
#      FUTURE conflict on that unit; R6-F4 the clearing predicate the
#      waiver's disclosure depended on cleared on unit CONTENT CHANGE ALONE,
#      without requiring the superseding review the v5 plan specifies.
#      OPERATOR RULING: remove the mechanism rather than guard it a fifth
#      time — disclosure and authorization carry different evidentiary
#      requirements, and a record invented to make a bypass observable had
#      been promoted into a control that authorizes releases. WHAT CHANGED:
#      `approve`'s DESIGN-CONFLICT-REFUSAL is now UNCONDITIONAL (runs
#      whether or not --no-design was given — see qa-gate.sh's own header on
#      that block); the waiver disclosure bracket, the unneeded-bypass
#      refusal, and the unit-scope subtraction reader are all DELETED, not
#      merely disabled; and compute_design_conflict_open's own clearing
#      predicate now requires a CURRENT SATISFIED review, not a content
#      change alone (the R6-F4 fix, folded into item 9's own R2-F3
#      predicate rather than layered beside it). Sections 8e/8f/8g/8h below
#      are REPURPOSED (not merely edited) to test the new, unconditional
#      shape and to serve as the anti-reintroduction negative control: no
#      flag, marker, label, or free-text phrase may clear or authorize an
#      open conflict. Section 8i (anti-overreach: a genuinely no-design-
#      phase task) is UNCHANGED — that property was never part of the
#      waiver and does not depend on it.
#
#  11. v5 D5 R9-F1 (claude-workflow-plugin-i8cx, sol-codex independent review
#      round 9, docs/reviews/claude-workflow-plugin-i8cx-r9.json): THE FIFTH
#      independent HIGH against reaching compute_design_conflict_open
#      correctly — this one against cmd_design_gate_precheck itself, not
#      `approve`. The conflict check items 9/10 fixed inside
#      cmd_design_gate_precheck lived ONLY inside the
#      `if [ "$DESIGN_SATISFIED" = "true" ]` arm, so no_design_attempted
#      (and every other non-true DESIGN_SATISFIED_KEY) returned "ready"
#      WITHOUT EVER CALLING compute_design_conflict_open. Neither existing
#      section could reach this cell: 8h's subject has a recorded SATISFIED
#      design; 8i's subject has no design phase AND no conflict. Sol's own
#      supporting evidence — `design-conflict` needs only a validating
#      docs/specs/<tid>.md FILE on disk, never a DESIGN-ARTIFACT beads
#      record — means a task that is genuinely no_design_attempted can
#      still legitimately carry an open conflict, so `approve --no-design`
#      followed by a conflict filed afterward could pass every later
#      Stop-time recheck forever. FIXED by making the conflict check
#      UNCONDITIONAL and evaluated BEFORE any DESIGN_SATISFIED branching
#      (qa-gate.sh's own DESIGN-GATE-PRECHECK-CONFLICT header carries the
#      full structural argument for why this forecloses a sixth arm, the
#      same way item 10's fix made `approve`'s own check unconditional
#      with respect to bypass_design). Whether `design-conflict` requiring
#      no DESIGN-ARTIFACT record is ITSELF a defect was assessed and
#      rejected — see that same header. Sections 8j (the uncovered cell,
#      plus its anti-vacuity companion) and 8k (METatest) below are the new
#      coverage; 8h/8i/approve's own DESIGN-CONFLICT-REFUSAL are UNCHANGED.
#      One PRE-EXISTING assertion needed a touch-up, caught by this fix
#      rather than by inspection: Section 8f's 8.24c used design-gate-
#      precheck as a precondition check for "verdict still design_verdict_
#      missing" on a task that ALSO carries an open conflict (filed at
#      8.23) — a value only reachable pre-fix because the conflict check
#      was unreachable for ANY non-true key, the exact bug class item 11
#      fixes. 8.24c now reads that precondition via design-status instead
#      (which exposes compute_design_satisfied's own key directly, never
#      touching the conflict axis), and two new assertions (8.24c2/8.24c3)
#      state explicitly what used to be silently invisible: design-gate-
#      precheck on that SAME task now reports design_conflict_open, not
#      design_verdict_missing. 8.24d/8.24e (the actual R6-F4 property under
#      test in that section, exercised via `approve`) are untouched and
#      still pass unmodified.
#
#  12. A2 (claude-workflow-plugin-i8cx, TIER 0 — a live reach-around shipped
#      in 18c9319 that TEN independent review rounds on this same axis did
#      not catch). THE SIXTH independent finding against reaching
#      compute_design_conflict_open correctly (R2-F2; R3-F2a/b; R6-F1
#      through F4 against the since-removed waiver; R9-F1 against
#      cmd_design_gate_precheck; this one against cmd_approve's OWN
#      idempotency arm) — and, unlike the first five, not against a
#      BRANCH that skipped the check but against an EARLY RETURN several
#      hundred lines above DESIGN-CONFLICT-REFUSAL: the hash-aware
#      idempotency no-op (IDEMPOTENCY, gz3/v4.1 U1) returns "approved" the
#      moment change_set_hash matches a bound record, and a DESIGN-CONFLICT
#      is a Beads comment that moves no file and no hash — so a conflict
#      filed AFTER an approval, on a change set nobody touches again, sailed
#      straight through. Every EXISTING leg in sections 8a-8k files its
#      conflict BEFORE the task's first-ever approve, so had_approved=0 in
#      every one of them and none exercises the idempotency arm at all —
#      the exact coverage gap that let this ship. FIXED by giving the
#      idempotency arm its OWN copy of the SAME check (same predicate, same
#      error_key, same exit code — see qa-gate.sh's own
#      IDEMPOTENT-APPROVE-CONFLICT-RECHECK header for why a second call site
#      inside cmd_approve and not a restructure), leaving the other six
#      refusal families that arm also skips UNTOUCHED (out of scope for this
#      leaf fix; a possible follow-up, not decided here). Section 8l
#      reproduces the defect and proves the fix (REFUSAL leg); 8m is the
#      essential anti-overreach companion — a genuine repeat approve with NO
#      new conflict must remain the documented no-op, proven non-vacuously
#      by an unchanged comment_count (the fall-through re-verify-and-rewrite
#      path would have appended a fresh record even if it too concluded
#      approved); 8n is the METatest proving the new sentinel region, not
#      something incidental, is what refuses.
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

# v5 D3 (claude-workflow-plugin-fkm.5): design-record's grilling precondition
# is seeded below via a REAL `qa-gate.sh grilling-record` call (seed_grilling),
# which hashes the vendored brainstorming SKILL.md — without it, every
# seed_grilling call refuses vendor_hash_unavailable.
mkdir -p "$FIXTURE/.claude/vendor/superpowers/brainstorming"
cp "$PLUGIN_DIR/.claude/vendor/superpowers/brainstorming/SKILL.md" \
    "$FIXTURE/.claude/vendor/superpowers/brainstorming/SKILL.md"

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

# seed_grilling <tid> — v5 D3 (claude-workflow-plugin-fkm.5): design-record
# now refuses (grilling_record_missing) without a GRILLING v1 record on the
# task or its parent epic. THIS FILE exercises design-review-record and the
# design-satisfied refusal — orthogonal to whether a grilling happened — so
# every task that calls design-record below gets one real, minimal grilling
# record here. The precondition itself has its own dedicated spec:
# grilling-record.test.sh.
seed_grilling() {
    local tid="$1"
    bash "$QG" grilling-record "$tid" --rounds 3 --questions 5 --approaches 2 --unresolved 0 \
        "design-review-record.test.sh: exercising the design-satisfied axis" >/dev/null 2>&1
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

# v5 D5 (claude-workflow-plugin-fkm.7): DESIGN-CONFLICT has no "v1" tag and
# no `last // {}`-style single-record reader — compute_design_conflict_open
# reads EVERY record — so these helpers, unlike latest_design_review_line,
# are named for what they actually return: a COUNT (all records) and the
# most-recently-POSTED text (which is not the same claim as "the currently
# authoritative one" the way DESIGN-REVIEW's amendment model makes true).
count_design_conflict() {
    comments_of "$1" | grep -cE '^DESIGN-CONFLICT ' 2>/dev/null | tr -d ' \n'
}

latest_design_conflict_line() {
    comments_of "$1" | grep -E '^DESIGN-CONFLICT ' | tail -1
}

# write_artifact <path> <task-id> [u1-goal] [u2-goal] — a minimal,
# schema-valid design artifact. u1-goal defaults to "test unit" (byte-exact
# with every call site that predates this parameter). A non-empty u2-goal
# ADDITIONALLY declares a second unit, U2 — for section 8c's independent,
# per-unit conflict-tracking legs, which need two REAL declared units
# (design-conflict's own UNIT-MEMBERSHIP-GATE refuses --unit U2 otherwise:
# unit_not_in_artifact). U2's acceptance id is AC2, never AC1 — review-check.sh
# validate-design's schema treats acceptance ids as unique ACROSS THE WHOLE
# artifact, not merely within one unit (acceptance_id_duplicate), so reusing
# AC1 for a second unit fails validation outright rather than producing a
# second, independently-amendable unit.
#
# REGENERATING THE WHOLE ARTIFACT THROUGH THIS ONE FUNCTION on every call —
# never sed/printf-patching the file on disk afterwards — is what makes an
# "amendment" in this file MEAN something precise: the only way any fixture
# here can move a unit's own canonical content (and therefore its
# design_unit_content_hash / unit_hash) is by changing that unit's OWN
# u1-goal/u2-goal text, which is exactly what a genuine design amendment to
# THAT unit looks like. Appending unrelated prose after the DESIGN-UNITS
# block (this file's PRE-round-2 approach to "amend") changes the
# whole-artifact hash without touching any unit's own declared object at
# all — which is indistinguishable, to the per-unit clearing predicate this
# section tests, from an amendment to nothing.
write_artifact() {
    local path="$1" tid="$2" u1_goal="${3:-test unit}" u2_goal="${4:-}"
    local unit1 unit2 units_block
    unit1=$(cat <<UNIT1
    {
      "unit_id": "U1",
      "role": "devops",
      "goal": "$u1_goal",
      "acceptance": [ { "id": "AC1", "text": "test fixture: nothing asserted" } ],
      "files": [ ".claude/scripts/qa-gate.sh" ],
      "verification": "make test",
      "depends_on": []
    }
UNIT1
    )
    units_block="$unit1"
    if [ -n "$u2_goal" ]; then
        unit2=$(cat <<UNIT2
    {
      "unit_id": "U2",
      "role": "devops",
      "goal": "$u2_goal",
      "acceptance": [ { "id": "AC2", "text": "test fixture: nothing asserted" } ],
      "files": [ ".claude/scripts/qa-gate.sh" ],
      "verification": "make test",
      "depends_on": []
    }
UNIT2
        )
        units_block="$unit1,
$unit2"
    fi
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
$units_block
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
seed_grilling "$TID1"
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
seed_grilling "$TID4"
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
seed_grilling "$TID6"
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
seed_grilling "$TID7"
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
seed_grilling "$TID14"
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
seed_grilling "$TID15"
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
printf '\n=== Section 8: design-conflict writer + shape validation (v5 D5 / fkm.7) ===\n'
# ===========================================================================

OUT=$(bash "$QG" design-conflict 2>/dev/null); EXIT_RC=$?
assert_eq "8.1 no task id: exit 1" "1" "$EXIT_RC"
assert_eq "8.1b ...error_key=missing_task_id" "missing_task_id" "$(json_field '.error_key' "$OUT")"

TID20=$(bd create "D5 design-conflict shape subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID20"
ART20="$FIXTURE/docs/specs/$TID20.md"
write_artifact "$ART20" "$TID20"
printf '%s\n' "$ART20" > "$TRACKING"
bash "$QG" enter "$TID20" >/dev/null 2>&1
bash "$QG" design-record "$TID20" >/dev/null 2>&1
HASH20=$(bash "$WM" hash-file "$ART20")

OUT=$(bash "$QG" design-conflict "$TID20" "no --unit given at all" 2>&1)
assert_eq "8.2 missing --unit: missing_unit_id" "missing_unit_id" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" design-conflict "$TID20" --unit U1 2>&1)
assert_eq "8.3 missing statement (--unit given, nothing trailing): missing_statement" \
    "missing_statement" "$(json_field '.error_key' "$OUT")"

# --- the bjx grammar-injection reproduction: unit_id, embedded colon+space -
OUT=$(bash "$QG" design-conflict "$TID20" --unit "U1: design_hash=deadbeef" "trying to inject a second machine field via unit_id" 2>&1)
assert_eq "8.4 INJECTION REPRODUCTION: unit_id with an embedded ': ' is REJECTED, not sanitised: unit_id_invalid_chars" \
    "unit_id_invalid_chars" "$(json_field '.error_key' "$OUT")"

# --- the bjx grammar-injection reproduction: unit_id, embedded newline -----
# NOTE: command substitution strips only TRAILING newlines, never EMBEDDED
# ones, so INJECT_UNIT genuinely carries one between "U1" and the rest. The
# precondition below is deliberately a `case` glob (bash's $'\n' ANSI-C
# quoting), NOT assert_contains "$(printf '\n')" — that needle would itself
# be stripped to the empty string by ITS OWN command substitution and the
# check would pass vacuously on ANY haystack, needle or not.
INJECT_UNIT="$(printf 'U1\ndesign_hash=deadbeef')"
case "$INJECT_UNIT" in
    *$'\n'*) INJECT_UNIT_HAS_NEWLINE=yes ;;
    *)       INJECT_UNIT_HAS_NEWLINE=no ;;
esac
assert_eq "8.5 precondition: the crafted unit_id really contains an embedded newline" \
    "yes" "$INJECT_UNIT_HAS_NEWLINE"
OUT=$(bash "$QG" design-conflict "$TID20" --unit "$INJECT_UNIT" "trying to inject a second record via a newline in unit_id" 2>&1)
assert_eq "8.5b INJECTION REPRODUCTION: unit_id with an embedded newline is REJECTED, not sanitised: unit_id_invalid_chars" \
    "unit_id_invalid_chars" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" design-conflict "$TID20" --unit U1 --design-hash "not valid" "explicit design-hash containing a space" 2>&1)
assert_eq "8.6 explicit --design-hash with a space: design_hash_invalid_chars" \
    "design_hash_invalid_chars" "$(json_field '.error_key' "$OUT")"

assert_eq "8.6b non-vacuity: none of 8.1-8.6 wrote a DESIGN-CONFLICT record" "0" "$(count_design_conflict "$TID20")"

# --- explicit --design-hash is now a CONFIRMATION of the live artifact ------
# hash, never an independent, merely-trusted claim (R2-F3, independent
# review round 2). This block used to assert the OPPOSITE — that a
# plainly-wrong, non-64-hex value was accepted verbatim ("need not be 64
# hex ... uncorrected") — which is exactly the gap Sol's review reported: a
# stale or mistyped explicit hash used to be recorded as-is and then read
# back by compute_design_conflict_open as ALREADY not the current design,
# so the conflict was born cleared. Rewritten to the NEW contract rather
# than restored. The character CLASS itself is UNCHANGED and still
# deliberately looser than is_sha256_hex (8.6 above still covers
# design_hash_invalid_chars on a value with a space — a class violation,
# never a currency one) — but any value in that class must now ALSO equal
# the live recompute or be refused.
OUT=$(bash "$QG" design-conflict "$TID20" --unit U1 --design-hash "short-and-not-hex" "explicit hash in-class but NOT current" 2>&1)
assert_eq "8.7 explicit --design-hash not matching the live artifact: design_hash_not_current" \
    "design_hash_not_current" "$(json_field '.error_key' "$OUT")"
assert_eq "8.7b non-vacuity: the mismatched attempt wrote NO record" "0" "$(count_design_conflict "$TID20")"

BEFORE_DC20C=$(count_design_conflict "$TID20")
OUT=$(bash "$QG" design-conflict "$TID20" --unit U1 --design-hash "$HASH20" "explicit hash that DOES match the live artifact: confirmed" 2>&1)
assert_eq "8.7c explicit --design-hash matching the live artifact: recorded" "recorded" "$(json_field '.status' "$OUT")"
assert_eq "8.7d ...exactly one new record" "$((BEFORE_DC20C + 1))" "$(count_design_conflict "$TID20")"
assert_contains "8.7e ...the record carries the CONFIRMED (live) hash" \
    "design_hash=$HASH20 " "$(latest_design_conflict_line "$TID20")"
assert_contains "8.7f ...and the unit_id positional token" "DESIGN-CONFLICT U1 " "$(latest_design_conflict_line "$TID20")"

# --- --design-hash omitted: a live recompute over the current artifact -----
BEFORE_DC20=$(count_design_conflict "$TID20")
OUT=$(bash "$QG" design-conflict "$TID20" --unit U1 "design-hash omitted, should auto-derive" 2>&1)
assert_eq "8.8 --design-hash omitted, artifact exists: recorded" "recorded" "$(json_field '.status' "$OUT")"
assert_contains "8.8b ...carries the LIVE artifact hash (auto-derived, strict 64-hex)" \
    "design_hash=$HASH20 " "$(latest_design_conflict_line "$TID20")"
assert_eq "8.8c ...exactly one new record" "$((BEFORE_DC20 + 1))" "$(count_design_conflict "$TID20")"

# --- --design-hash omitted AND no artifact exists at all -------------------
TID21=$(bd create "D5 design-conflict no artifact at all" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" design-conflict "$TID21" --unit U1 "no artifact was ever recorded" 2>&1)
assert_eq "8.9 no artifact + no --design-hash: design_artifact_not_found" \
    "design_artifact_not_found" "$(json_field '.error_key' "$OUT")"

# ===========================================================================
printf '\n=== Section 8b: approve DESIGN-CONFLICT-REFUSAL — the fkm.1.19 leg ===\n'
# ===========================================================================

TID22=$(bd create "D5 no-conflict control subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID22"
ART22="$FIXTURE/docs/specs/$TID22.md"
write_artifact "$ART22" "$TID22"
printf '%s\n' "$ART22" > "$TRACKING"
bash "$QG" enter "$TID22" >/dev/null 2>&1
bash "$QG" design-record "$TID22" >/dev/null 2>&1
HASH22=$(bash "$WM" hash-file "$ART22")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID22" --design-hash "$HASH22" >/dev/null 2>&1
seed_approvable "$TID22"

# CONTROL, non-vacuity for the new code path: a satisfied design with NO
# conflict ever filed must approve exactly as it did before this section
# existed — guards against the new check accidentally firing on the
# ordinary case.
OUT=$(bash "$QG" approve "$TID22" "control: no conflict filed at all" 2>&1)
assert_eq "8.10 CONTROL: satisfied design, no conflict filed: approved" "approved" "$(json_field '.status' "$OUT")"

TID23=$(bd create "D5 fkm.1.19 anti-regression subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID23"
ART23="$FIXTURE/docs/specs/$TID23.md"
write_artifact "$ART23" "$TID23"
printf '%s\n' "$ART23" > "$TRACKING"
bash "$QG" enter "$TID23" >/dev/null 2>&1
bash "$QG" design-record "$TID23" >/dev/null 2>&1
HASH23=$(bash "$WM" hash-file "$ART23")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID23" --design-hash "$HASH23" >/dev/null 2>&1
seed_approvable "$TID23"

OUT=$(bash "$QG" design-conflict "$TID23" --unit U1 "AC1 contradicts the existing auth flow; cannot be satisfied as written" 2>&1)
assert_eq "8.11 conflict filed against the currently-satisfied artifact: recorded" "recorded" "$(json_field '.status' "$OUT")"

PRE23_COUNT=$(comment_count "$TID23")
OUT=$(bash "$QG" approve "$TID23" "attempt with an open conflict" 2>&1); EXIT_RC=$?
assert_eq "8.12 open conflict blocks approve: exit 2" "2" "$EXIT_RC"
assert_eq "8.12b ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$OUT")"
assert_contains "8.12c ...names the affected unit in the observations" "U1" "$(json_field '.observations' "$OUT")"
POST23_COUNT=$(comment_count "$TID23")
assert_eq "8.12d the task is left UNTOUCHED" "$PRE23_COUNT" "$POST23_COUNT"

# THE LEG THAT MATTERS MOST (per this task's own instructions): record a
# NEWER, approved DESIGN-REVIEW that is SILENT about the unit — in the
# strongest sense available, since DESIGN-REVIEW's own grammar carries no
# per-unit field at all: a re-affirmation at the SAME, UNCHANGED
# design_hash. The iteration counter advances; the artifact's bytes do not.
SAME_HASH_REVIEW=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=2')
OUT=$(printf '%s' "$SAME_HASH_REVIEW" | bash "$QG" design-review-record "$TID23" --design-hash "$HASH23" 2>&1)
assert_eq "8.13 precondition: the re-affirmation recorded at the SAME design_hash" "recorded" "$(json_field '.status' "$OUT")"
LATEST_REVIEW23=$(latest_design_review_line "$TID23")
assert_not_contains "8.13b ...and carries NO [amends:] marker (the bytes did not change)" "[amends:" "$LATEST_REVIEW23"

OUT=$(bash "$QG" approve "$TID23" "attempt after a same-hash re-review, silent about the conflict" 2>&1); EXIT_RC=$?
assert_eq "8.14 fkm.1.19 ANTI-REGRESSION: approve STILL refuses — a later record silent about the unit does not retire the conflict" \
    "2" "$EXIT_RC"
assert_eq "8.14b ...error_key is STILL design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$OUT")"

# --- the ANTI-OVERREACH leg: a GENUINE amendment DOES clear it -------------
# Without this leg the gate could never open again — a design_conflict that
# nothing can ever clear is as much a defect as one retirement-by-omission
# silently clears.
#
# THE AMENDMENT MUST TOUCH U1's OWN DECLARED CONTENT, not merely the
# whole-artifact bytes: compute_design_conflict_open's clearing predicate
# (R2-F3, independent review round 2) keys on design_unit_content_hash of
# the DISPUTED unit specifically, never the whole-artifact hash. Appending
# prose after the DESIGN-UNITS block (this leg's own pre-round-2 approach)
# moves the whole-artifact hash without moving U1's own canonical JSON at
# all, so it is indistinguishable, to that predicate, from no amendment —
# which is exactly why 8.16 used to fail here. Regenerating via
# write_artifact with a new u1-goal changes U1's own object (and therefore
# the whole-artifact bytes too, satisfying 8.15/8.15b below unchanged).
write_artifact "$ART23" "$TID23" "test unit, amended in response to the conflict"
HASH23B=$(bash "$WM" hash-file "$ART23")
bash "$QG" design-record "$TID23" >/dev/null 2>&1
AMEND_REVIEW=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=3')
OUT=$(printf '%s' "$AMEND_REVIEW" | bash "$QG" design-review-record "$TID23" --design-hash "$HASH23B" 2>&1)
assert_eq "8.15 precondition: a genuine amendment recorded at a NEW design_hash" "recorded" "$(json_field '.status' "$OUT")"
LATEST_REVIEW23B=$(latest_design_review_line "$TID23")
assert_contains "8.15b ...carries [amends: <prev-hash>]" "[amends: $HASH23]" "$LATEST_REVIEW23B"

OUT=$(bash "$QG" approve "$TID23" "attempt after the design was genuinely amended" 2>&1)
assert_eq "8.16 ANTI-OVERREACH: a genuine amendment clears the conflict — approved" "approved" "$(json_field '.status' "$OUT")"

# ===========================================================================
printf '\n=== Section 8c: every record considered — multiple units, independently ===\n'
# ===========================================================================

TID24=$(bd create "D5 multi-unit conflict subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID24"
ART24="$FIXTURE/docs/specs/$TID24.md"
# TWO real declared units (U1 AND U2) — R2-F3's clearing predicate keys on
# the DISPUTED unit's own content and refuses design-conflict's own
# UNIT-MEMBERSHIP-GATE (unit_not_in_artifact) for any --unit the artifact
# does not declare, so a synthetic, undeclared U2 can no longer exercise
# this path the way a pre-round-2 fixture did.
write_artifact "$ART24" "$TID24" "goal for unit U1" "goal for unit U2"
printf '%s\n' "$ART24" > "$TRACKING"
bash "$QG" enter "$TID24" >/dev/null 2>&1
bash "$QG" design-record "$TID24" >/dev/null 2>&1
HASH24=$(bash "$WM" hash-file "$ART24")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID24" --design-hash "$HASH24" >/dev/null 2>&1
seed_approvable "$TID24"

bash "$QG" design-conflict "$TID24" --unit U1 "first objection, unit U1" >/dev/null 2>&1
bash "$QG" design-conflict "$TID24" --unit U2 "second objection, a DIFFERENT unit U2" >/dev/null 2>&1
assert_eq "8.17 precondition: two DESIGN-CONFLICT records now exist" "2" "$(count_design_conflict "$TID24")"

OUT=$(bash "$QG" approve "$TID24" "attempt with two open conflicts on different units" 2>&1)
assert_eq "8.17b both units still pinned to the current hash: still refused" "design_conflict_open" "$(json_field '.error_key' "$OUT")"
assert_contains "8.17c ...names U1" "U1" "$(json_field '.observations' "$OUT")"
assert_contains "8.17d ...AND names U2 (every record considered, not just the latest)" "U2" "$(json_field '.observations' "$OUT")"

# --- an amendment to only ONE of the two units clears ONLY that one -------
# The genuinely independent half of the anti-overreach guarantee: 8.16/8.18
# alone would not distinguish "clears the unit that changed" from "clears
# everything the moment ANYTHING changes". Amending U2 alone must leave
# U1's own conflict open.
write_artifact "$ART24" "$TID24" "goal for unit U1" "goal for unit U2, amended"
HASH24A=$(bash "$WM" hash-file "$ART24")
bash "$QG" design-record "$TID24" >/dev/null 2>&1
AMEND_REVIEW24A=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=2')
printf '%s' "$AMEND_REVIEW24A" | bash "$QG" design-review-record "$TID24" --design-hash "$HASH24A" >/dev/null 2>&1

OUT=$(bash "$QG" approve "$TID24" "attempt after amending U2 only" 2>&1)
assert_eq "8.17e amending ONLY U2 still refuses (U1's own content did not change)" \
    "design_conflict_open" "$(json_field '.error_key' "$OUT")"
assert_contains "8.17f ...names U1 (still open)" "U1" "$(json_field '.observations' "$OUT")"
assert_not_contains "8.17g ...but no longer names U2 (its own content changed, so IT cleared)" \
    "U2" "$(json_field '.observations' "$OUT")"

# --- amending the REMAINING unit (U1) clears BOTH: each was pinned to the --
# hash the artifact carried when its OWN conflict was filed (both filed
# against the same original design_hash — "the same superseded hash" — but
# cleared independently, one amendment at a time, never in lockstep).
write_artifact "$ART24" "$TID24" "goal for unit U1, amended" "goal for unit U2, amended"
HASH24B=$(bash "$WM" hash-file "$ART24")
bash "$QG" design-record "$TID24" >/dev/null 2>&1
AMEND_REVIEW24=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=3')
printf '%s' "$AMEND_REVIEW24" | bash "$QG" design-review-record "$TID24" --design-hash "$HASH24B" >/dev/null 2>&1

OUT=$(bash "$QG" approve "$TID24" "attempt after amending past both conflicts" 2>&1)
assert_eq "8.18 an amendment clears BOTH open conflicts at once (both were pinned to the same superseded hash): approved" \
    "approved" "$(json_field '.status' "$OUT")"

# ===========================================================================
printf '\n=== Section 8d: METatest — DESIGN-CONFLICT-REFUSAL is load-bearing ===\n'
# ===========================================================================

awk '/# DESIGN-CONFLICT-REFUSAL BEGIN/{s=1} !s{print} /# DESIGN-CONFLICT-REFUSAL END/{s=0}' \
    "$QG" > "$FIXTURE/.claude/scripts/qa-gate-noconflict.sh"
STRIP_DELTA2=$(( $(wc -l < "$QG") - $(wc -l < "$FIXTURE/.claude/scripts/qa-gate-noconflict.sh") ))
assert_eq "8.19 META: the region strip actually removed lines" "yes" "$([ "$STRIP_DELTA2" -gt 10 ] && echo yes || echo no)"
chmod +x "$FIXTURE/.claude/scripts/qa-gate-noconflict.sh"
if bash -n "$FIXTURE/.claude/scripts/qa-gate-noconflict.sh" 2>/dev/null; then
    assert_eq "8.19b META: the stripped copy is still valid bash" "0" "0"
else
    assert_eq "8.19b META: the stripped copy is still valid bash" "0" "1"
fi

TID25=$(bd create "D5 META strip subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID25"
ART25="$FIXTURE/docs/specs/$TID25.md"
write_artifact "$ART25" "$TID25"
printf '%s\n' "$ART25" > "$TRACKING"
bash "$QG" enter "$TID25" >/dev/null 2>&1
bash "$QG" design-record "$TID25" >/dev/null 2>&1
HASH25=$(bash "$WM" hash-file "$ART25")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID25" --design-hash "$HASH25" >/dev/null 2>&1
seed_approvable "$TID25"
bash "$QG" design-conflict "$TID25" --unit U1 "META fixture: an unresolved objection" >/dev/null 2>&1

CTRL_OUT=$(bash "$QG" approve "$TID25" "control: shipped script, open conflict present" 2>&1)
assert_eq "8.19c META CONTROL: the SHIPPED script still refuses (open conflict present)" \
    "design_conflict_open" "$(json_field '.error_key' "$CTRL_OUT")"
MUTANT_OUT=$(bash "$FIXTURE/.claude/scripts/qa-gate-noconflict.sh" approve "$TID25" "mutant: same task, region stripped" 2>&1)
assert_eq "8.19d META MISBEHAVIOUR: the STRIPPED copy approves the SAME task, open conflict and all" \
    "approved" "$(json_field '.status' "$MUTANT_OUT")"
rm -f "$FIXTURE/.claude/scripts/qa-gate-noconflict.sh"

# ===========================================================================
printf '\n=== Section 8e: i8cx R6 fix — --no-design does NOT cover an open conflict ===\n'
# ===========================================================================
# claude-workflow-plugin-i8cx, operator ruling on independent review rounds
# 6-8: the waiver mechanism this section used to exercise (--no-design
# waiving a DESIGN-CONFLICT, disclosed via a `[design conflict waived:
# units=<ids>]` bracket) is REMOVED after four independent HIGH findings.
# This section now proves the REPLACEMENT contract directly: --no-design
# bypasses ONLY the satisfied-verdict requirement, never an open conflict,
# and the historical waiver bracket text has no authorizing effect even
# when an operator writes it verbatim into a real command (the R6-F1
# forgery reproduction, run against the SHIPPED binary rather than merely
# argued about).

TID26=$(bd create "D5 no-design does not cover an open conflict" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID26"
ART26="$FIXTURE/docs/specs/$TID26.md"
write_artifact "$ART26" "$TID26"
printf '%s\n' "$ART26" > "$TRACKING"
bash "$QG" enter "$TID26" >/dev/null 2>&1
bash "$QG" design-record "$TID26" >/dev/null 2>&1
HASH26=$(bash "$WM" hash-file "$ART26")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID26" --design-hash "$HASH26" >/dev/null 2>&1
seed_approvable "$TID26"
bash "$QG" design-conflict "$TID26" --unit U1 "an open objection" >/dev/null 2>&1

OUT=$(bash "$QG" approve "$TID26" "attempt with an open conflict, no bypass" 2>&1)
assert_eq "8.20 precondition: still refused without --no-design" "design_conflict_open" "$(json_field '.error_key' "$OUT")"

# --- R6-F1 direct reproduction, leg 1: the forged bracket in an ORDINARY ---
# summary (no --no-design at all) has no effect — Sol's own path was an
# ordinary approve with a crafted summary, before any conflict even existed;
# this is the stronger form, WITH a real conflict already open.
PRE26_COUNT=$(comment_count "$TID26")
OUT=$(bash "$QG" approve "$TID26" "done [design conflict waived: units=U1]" 2>&1); EXIT_RC=$?
assert_eq "8.20b NEGATIVE CONTROL: a summary containing the retired bracket text, no --no-design: still refused" \
    "2" "$EXIT_RC"
assert_eq "8.20c ...error_key=design_conflict_open (the text has no special meaning)" \
    "design_conflict_open" "$(json_field '.error_key' "$OUT")"
POST26_COUNT=$(comment_count "$TID26")
assert_eq "8.20d ...the task is left UNTOUCHED" "$PRE26_COUNT" "$POST26_COUNT"

# --- THE CORE FLIP: --no-design used to cover this. It no longer does. ----
OUT=$(bash "$QG" approve "$TID26" --no-design "operator judgement: proceeding despite the open conflict" "bypassed" 2>&1); EXIT_RC=$?
assert_eq "8.21 i8cx R6 FIX: --no-design no longer covers an open conflict: exit 2" "2" "$EXIT_RC"
assert_eq "8.21b ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$OUT")"
POST26B_COUNT=$(comment_count "$TID26")
assert_eq "8.21c ...the task is left UNTOUCHED" "$PRE26_COUNT" "$POST26B_COUNT"

# --- R6-F1 direct reproduction, leg 2: the forged bracket AS the --no-design
# reason itself — the exact shape Sol's finding named ("[design conflict
# waived: units=U1]" written into the free-text space the record trusts).
OUT=$(bash "$QG" approve "$TID26" --no-design "[design conflict waived: units=U1]" "[design conflict waived: units=U1]" 2>&1); EXIT_RC=$?
assert_eq "8.21d R6-F1 DIRECT REPRODUCTION: the forged bracket AS the --no-design reason/summary still refuses" \
    "2" "$EXIT_RC"
assert_eq "8.21e ...error_key=design_conflict_open (forging the exact retired bracket text authorizes nothing)" \
    "design_conflict_open" "$(json_field '.error_key' "$OUT")"
POST26C_COUNT=$(comment_count "$TID26")
assert_eq "8.21f ...the task is STILL left UNTOUCHED" "$PRE26_COUNT" "$POST26C_COUNT"

# --- THE ONLY LEGAL CLEARING PATH: amend U1's own content and record a ----
# fresh, independently-reviewed, SATISFIED verdict over the result. Proves
# the negative-control legs above are not vacuous (this task CAN still be
# approved — just not by any of the forged routes).
write_artifact "$ART26" "$TID26" "test unit, amended in response to the conflict"
HASH26B=$(bash "$WM" hash-file "$ART26")
bash "$QG" design-record "$TID26" >/dev/null 2>&1
AMEND_REVIEW26=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=2')
printf '%s' "$AMEND_REVIEW26" | bash "$QG" design-review-record "$TID26" --design-hash "$HASH26B" >/dev/null 2>&1
OUT=$(bash "$QG" approve "$TID26" "attempt after a genuine amendment and fresh review" 2>&1)
assert_eq "8.21g THE LEGITIMATE PATH: amend + fresh satisfied review clears it, ordinary approve succeeds" \
    "approved" "$(json_field '.status' "$OUT")"
APPROVAL26=$(latest_approval "$TID26")
assert_not_contains "8.21h ...and the record carries no bypass marker of any kind (ordinary approval, nothing to disclose)" \
    "[design bypass:" "$APPROVAL26"

# ===========================================================================
printf '\n=== Section 8f: R6-F4 — a content edit alone, without a satisfied review, does not clear ===\n'
# ===========================================================================
# claude-workflow-plugin-i8cx independent review round 6: the predicate that
# used to feed the (now-removed) waiver disclosure cleared a conflict on
# unit CONTENT CHANGE ALONE, with no check that any review ever covered the
# result. That predicate is shared by compute_design_conflict_open itself
# (not only the removed disclosure), so this section proves the fix directly
# against `approve`, starting from the HARDEST case: a verdict that was
# never satisfied in the first place (design_verdict_missing).

TID27=$(bd create "D5 R6-F4 unsatisfied-verdict conflict subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID27"
ART27="$FIXTURE/docs/specs/$TID27.md"
write_artifact "$ART27" "$TID27"
printf '%s\n' "$ART27" > "$TRACKING"
bash "$QG" enter "$TID27" >/dev/null 2>&1
bash "$QG" design-record "$TID27" >/dev/null 2>&1
seed_approvable "$TID27"

PRECHECK27=$(bash "$QG" design-gate-precheck "$TID27" 2>&1)
assert_eq "8.22 precondition: TID27's design verdict is genuinely UNSATISFIED (design_verdict_missing — no DESIGN-REVIEW was ever recorded)" \
    "design_verdict_missing" "$(json_field '.error_key' "$PRECHECK27")"

OUT=$(bash "$QG" design-conflict "$TID27" --unit U1 "AC1 cannot be satisfied as designed; filed before any verdict exists" 2>&1)
assert_eq "8.23 the writer accepts a conflict with NO satisfied verdict at all: recorded" \
    "recorded" "$(json_field '.status' "$OUT")"

# --- i8cx R6 FIX: --no-design no longer rescues this state either — it ----
# used to (this was R3-F1's own reproduction: "a valid artifact can receive
# an open U1 conflict while its verdict is missing", and --no-design cleared
# it). Now it refuses identically to the ordinary path.
OUT=$(bash "$QG" approve "$TID27" --no-design "no satisfied verdict exists yet, proceeding anyway" "bypassed attempt" 2>&1); EXIT_RC=$?
assert_eq "8.24 i8cx R6 FIX: --no-design on an UNSATISFIED verdict with an open conflict now refuses too" \
    "2" "$EXIT_RC"
assert_eq "8.24b ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$OUT")"

# --- R6-F4 DIRECT REPRODUCTION: edit U1's OWN content (moves its unit_hash)
# but record NO new review at all — the verdict stays design_verdict_missing.
# The pre-fix predicate cleared on this alone; it must NOT anymore.
write_artifact "$ART27" "$TID27" "test unit, edited but never re-reviewed"
bash "$QG" design-record "$TID27" >/dev/null 2>&1
# design-status (not design-gate-precheck) is the correct instrument for
# THIS precondition as of R9-F1 (round 9): compute_design_satisfied's own
# key is checked directly here, unaffected by the open conflict TID27 has
# carried since 8.23 — design-gate-precheck's OWN output no longer stays
# quiet about an open conflict just because DESIGN_SATISFIED_KEY is
# something other than "true" (8.24c2/8.24c3 immediately below state that
# same fact as its own explicit assertion, rather than leaving it as an
# incidental side effect this precondition would otherwise silently hide).
STATUS27B=$(bash "$QG" design-status "$TID27" 2>&1)
assert_eq "8.24c precondition: still unsatisfied after the edit (no review was recorded)" \
    "design_verdict_missing" "$(json_field '.error_key' "$STATUS27B")"
# --- R9-F1, CAUGHT BY THIS EXACT PRECONDITION WHILE FIXING IT: before that
# fix, design-gate-precheck on a design_verdict_missing task with an
# ALREADY-open conflict (filed at 8.23) reported design_verdict_missing too
# — the conflict check was unreachable outside the DESIGN_SATISFIED=true arm
# for ANY non-true key, not only no_design_attempted (Section 8j's own
# dedicated leg). Now it reports the conflict, the more specific and more
# actionable fact, taking priority the same way `approve --no-design`'s own
# bypass path already does (it skips DESIGN_SATISFIED entirely and always
# reaches the unconditional conflict check).
PRECHECK27B=$(bash "$QG" design-gate-precheck "$TID27" 2>&1); PRECHECK27B_RC=$?
assert_eq "8.24c2 R9-F1: design-gate-precheck's OWN output now reports the conflict here too: exit 4" \
    "4" "$PRECHECK27B_RC"
assert_eq "8.24c3 ...error_key=design_conflict_open (not design_verdict_missing — the conflict takes priority)" \
    "design_conflict_open" "$(json_field '.error_key' "$PRECHECK27B")"
OUT=$(bash "$QG" approve "$TID27" --no-design "the unit changed, but nothing reviewed it" "attempt" 2>&1); EXIT_RC=$?
assert_eq "8.24d R6-F4 DIRECT REPRODUCTION: a content edit with NO accompanying satisfied review does not clear" \
    "2" "$EXIT_RC"
assert_eq "8.24e ...error_key is STILL design_conflict_open (an edit is not an approved review)" \
    "design_conflict_open" "$(json_field '.error_key' "$OUT")"

# --- THE LEGITIMATE PATH FROM HERE: record a fresh, satisfied, ------------
# independently-reviewed verdict over the edited artifact. Once satisfied,
# --no-design is not even needed.
HASH27=$(bash "$WM" hash-file "$ART27")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID27" --design-hash "$HASH27" >/dev/null 2>&1
OUT=$(bash "$QG" approve "$TID27" "attempt after the edit was actually reviewed and found satisfied" 2>&1)
assert_eq "8.24f THE LEGITIMATE PATH: edit + fresh satisfied review clears it, ordinary approve succeeds" \
    "approved" "$(json_field '.status' "$OUT")"

# --- CONTROL: a SIBLING task in the SAME unsatisfied state, but with NO ----
# conflict ever filed, must still approve via --no-design exactly as before
# — this axis (no design phase / unsatisfied verdict, no conflict) is
# UNCHANGED by the i8cx R6 fix, which touches only the conflict axis.
TID27B=$(bd create "D5 R6-F4 control: unsatisfied, no conflict filed" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID27B"
ART27B="$FIXTURE/docs/specs/$TID27B.md"
write_artifact "$ART27B" "$TID27B"
printf '%s\n' "$ART27B" > "$TRACKING"
bash "$QG" enter "$TID27B" >/dev/null 2>&1
bash "$QG" design-record "$TID27B" >/dev/null 2>&1
seed_approvable "$TID27B"
OUT=$(bash "$QG" approve "$TID27B" --no-design "no verdict yet, no conflict either" "bypassed, control" 2>&1)
assert_eq "8.25 CONTROL: unsatisfied verdict, no conflict filed: approved (unchanged axis)" "approved" "$(json_field '.status' "$OUT")"
APPROVAL27B=$(latest_approval "$TID27B")
assert_contains "8.25b ...carries the plain marker" "[design bypass: no verdict yet, no conflict either" "$APPROVAL27B"
assert_not_contains "8.25c REGRESSION SENTINEL: the retired bracket text never appears (the mechanism that wrote it is gone)" \
    "[design conflict waived:" "$APPROVAL27B"

# ===========================================================================
printf '\n=== Section 8g: DESIGN-BYPASS-UNNEEDED-REFUSAL removed — --no-design simply succeeds ===\n'
# ===========================================================================
# The R3-F2a refusal ("--no-design was given but bypasses nothing") existed
# ONLY to stop an operator from writing the `[design bypass:` marker on an
# approval that did not need it, because verify-before-stop.sh used to treat
# that marker's bare PRESENCE as a permanent skip of its own design recheck.
# R3-F2b (still in force, unchanged by i8cx) replaced that blind skip with
# an unconditional call to design-gate-precheck, so the marker has had no
# such effect for a long time — the refusal was judged on its own merits and
# removed as dead weight that existed to prevent a harm fixed a different
# way. --no-design on a satisfied, unconflicted design now just succeeds.

TID28=$(bd create "D5 no-design succeeds even when unneeded" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID28"
ART28="$FIXTURE/docs/specs/$TID28.md"
write_artifact "$ART28" "$TID28"
printf '%s\n' "$ART28" > "$TRACKING"
bash "$QG" enter "$TID28" >/dev/null 2>&1
bash "$QG" design-record "$TID28" >/dev/null 2>&1
HASH28=$(bash "$WM" hash-file "$ART28")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID28" --design-hash "$HASH28" >/dev/null 2>&1
seed_approvable "$TID28"

OUT=$(bash "$QG" approve "$TID28" --no-design "just in case" "an unneeded bypass" 2>&1)
assert_eq "8.26 --no-design on a satisfied, unconflicted design now SUCCEEDS (DESIGN-BYPASS-UNNEEDED-REFUSAL removed)" \
    "approved" "$(json_field '.status' "$OUT")"
APPROVAL28=$(latest_approval "$TID28")
assert_contains "8.26b ...carries the plain marker" "[design bypass: just in case" "$APPROVAL28"
assert_not_contains "8.26c REGRESSION SENTINEL: the retired bracket text never appears" \
    "[design conflict waived:" "$APPROVAL28"

# --- THE CONSEQUENCE THAT STILL MATTERS: a conflict filed AFTER this ------
# --no-design approval must still be caught fresh — proving the marker's
# presence (harmless now, but still written) suppresses nothing.
bash "$QG" design-conflict "$TID28" --unit U1 "filed AFTER a --no-design approval; must still be caught" >/dev/null 2>&1
STOPCHECK28=$(bash "$QG" design-gate-precheck "$TID28" 2>&1); STOP_RC=$?
assert_eq "8.27 design-gate-precheck still refuses on a conflict filed after ANY approval, bypass or not: exit 4" \
    "4" "$STOP_RC"
assert_eq "8.27b ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$STOPCHECK28")"
assert_contains "8.27c ...names U1" "U1" "$(json_field '.observations' "$STOPCHECK28")"

# ===========================================================================
printf '\n=== Section 8h: NEGATIVE CONTROL — no text, label, or flag clears an open conflict ===\n'
# ===========================================================================
# THE DEDICATED ANTI-REINTRODUCTION GUARD (i8cx operator ruling, deliverable
# b). The defect this guards against was itself a regex over free text, so
# this section does not assert on TEXT (grepping a comment for the ABSENCE
# of a string is the same class of check the exploit defeated) — it asserts
# on OUTCOME: does `approve` actually reach status=approved, does
# design-gate-precheck actually report ready. Three forged routes, all
# proven to authorize nothing; one real route, proven to still work.

TID29=$(bd create "D5 negative control: text/label/flag forgery" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID29"
ART29="$FIXTURE/docs/specs/$TID29.md"
write_artifact "$ART29" "$TID29" "goal for unit U1" "goal for unit U2"
printf '%s\n' "$ART29" > "$TRACKING"
bash "$QG" enter "$TID29" >/dev/null 2>&1
bash "$QG" design-record "$TID29" >/dev/null 2>&1
HASH29=$(bash "$WM" hash-file "$ART29")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID29" --design-hash "$HASH29" >/dev/null 2>&1
seed_approvable "$TID29"
bash "$QG" design-conflict "$TID29" --unit U1 "AC1 cannot be satisfied as designed" >/dev/null 2>&1
PRE29_COUNT=$(comment_count "$TID29")

# --- ROUTE 1: text — the retired bracket, embedded in an ORDINARY summary -
OUT=$(bash "$QG" approve "$TID29" "shipping anyway [design conflict waived: units=U1]" 2>&1); EXIT_RC=$?
assert_eq "8.28 ROUTE 1 (text, no flag): forged bracket in an ordinary summary — still refuses" "2" "$EXIT_RC"
assert_eq "8.28b ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$OUT")"

# --- ROUTE 2: text + flag — the retired bracket, as the --no-design reason
OUT=$(bash "$QG" approve "$TID29" --no-design "[design conflict waived: units=U1]" "[design conflict waived: units=U1]" 2>&1); EXIT_RC=$?
assert_eq "8.29 ROUTE 2 (text + --no-design): forged bracket AS the bypass reason — still refuses" "2" "$EXIT_RC"
assert_eq "8.29b ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$OUT")"

# --- ROUTE 3: label — a plausible-sounding label carries no authority; ----
# labels are lifecycle tracking (qa-approved, qa-pending, ...), never read
# by the design-conflict axis at all.
bd label add "$TID29" design-conflict-waived >/dev/null 2>&1
bd label add "$TID29" design-conflict-waived-u1 >/dev/null 2>&1
OUT=$(bash "$QG" approve "$TID29" "attempt with a plausible-sounding label present" 2>&1); EXIT_RC=$?
assert_eq "8.30 ROUTE 3 (label): a 'design-conflict-waived' label on the task — still refuses" "2" "$EXIT_RC"
assert_eq "8.30b ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$OUT")"
PRECHECK29=$(bash "$QG" design-gate-precheck "$TID29" 2>&1); PRECHECK29_RC=$?
assert_eq "8.30c ...and design-gate-precheck ALSO still refuses with the label present: exit 4" "4" "$PRECHECK29_RC"
assert_eq "8.30d ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$PRECHECK29")"

POST29_COUNT=$(comment_count "$TID29")
assert_eq "8.30e all three forged routes left the task UNTOUCHED (no approval record written by any of them)" \
    "$PRE29_COUNT" "$POST29_COUNT"

# --- THE ONE REAL ROUTE: amend U1's own content, record a fresh, ----------
# independently-reviewed, SATISFIED verdict. Proves the three refusals above
# are not vacuous — this task CAN still be approved, just not by forgery.
write_artifact "$ART29" "$TID29" "goal for unit U1, amended in response to the conflict" "goal for unit U2"
HASH29B=$(bash "$WM" hash-file "$ART29")
bash "$QG" design-record "$TID29" >/dev/null 2>&1
AMEND_REVIEW29=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=2')
printf '%s' "$AMEND_REVIEW29" | bash "$QG" design-review-record "$TID29" --design-hash "$HASH29B" >/dev/null 2>&1
OUT=$(bash "$QG" approve "$TID29" "attempt after a genuine amendment and fresh review" 2>&1)
assert_eq "8.31 THE LEGITIMATE PATH: amend + fresh satisfied review clears it, ordinary approve succeeds" \
    "approved" "$(json_field '.status' "$OUT")"

# ===========================================================================
printf '\n=== Section 8i: anti-overreach — a genuinely no-design-phase task is unaffected ===\n'
# ===========================================================================

TID30=$(bd create "D5 anti-overreach: no design phase at all" -t task -p 1 --json 2>/dev/null | jq -r '.id')
# claude-workflow-plugin-wob2 (L2): same one-line seed every OTHER section in
# this file writes before its own design/approve flow (see the many
# `printf ... > "$TRACKING"` sites above — placeholder-N.md is the
# established shape for a section with no real design artifact to point at).
# TID30 is the one section that skipped it, because this task deliberately
# has no design phase to hang a real path on — but seed_approvable's own
# reviewed_hash still needs the tracker non-empty at the instant it calls
# impact-report.sh --hash-only, or it now legitimately answers the SHA-256
# empty-content digest, which review-check.sh validate-artifact refuses as
# reviewed_hash_unusable (a degradation sentinel, never a usable binding).
printf 'placeholder-30.md\n' > "$TRACKING"
seed_approvable "$TID30"
OUT=$(bash "$QG" approve "$TID30" --no-design "this task never had a design phase" "ordinary no-design bypass" 2>&1)
assert_eq "8.32 ANTI-OVERREACH: a task with genuinely no design phase still approves with --no-design" \
    "approved" "$(json_field '.status' "$OUT")"
APPROVAL30=$(latest_approval "$TID30")
assert_contains "8.32b ...carries the plain marker" "[design bypass: this task never had a design phase" "$APPROVAL30"
assert_not_contains "8.32c REGRESSION SENTINEL: no retired waiver bracket (no artifact ever existed to conflict against, and the mechanism that wrote this bracket is gone entirely)" \
    "[design conflict waived:" "$APPROVAL30"

# ===========================================================================
printf '\n=== Section 8j: R9-F1 — no_design_attempted does not bypass an open conflict ===\n'
# ===========================================================================
# claude-workflow-plugin-i8cx, sol-codex independent review round 9
# (docs/reviews/claude-workflow-plugin-i8cx-r9.json, R9-F1, HIGH). THE
# UNCOVERED CELL neither 8h nor 8i can reach: 8h's subject has a recorded
# SATISFIED design (the DESIGN_SATISFIED=true arm, already correctly guarded
# since R2-F2); 8i's subject has no design phase AND no conflict. Sol's own
# evidence: `design-conflict` needs only a validating docs/specs/<tid>.md
# FILE on disk (design_artifact_path_for + the UNIT-MEMBERSHIP-GATE) — it
# never checks for a DESIGN-ARTIFACT beads record (Section 8's own TID21
# already proves the FILE is what gates it: no file at all refuses
# design_artifact_not_found regardless of any beads record). So a task that
# is genuinely no_design_attempted (design-record was NEVER called, even
# though an artifact file happens to exist) can still legitimately carry an
# open DESIGN-CONFLICT. qa-gate.sh's own DESIGN-GATE-PRECHECK-CONFLICT
# header carries the full judgement call on whether THAT (no DESIGN-ARTIFACT
# record required to file a conflict) is itself a second defect: it is not —
# a conflict is evidence about the ARTIFACT'S CONTENT, not about whether
# anyone ever formally recorded starting a design phase, and requiring a
# record first would make it impossible to object to a design that was never
# properly recorded in the first place, which is a worse failure mode than
# the one being fixed here.
#
# ASSERTIONS BELOW ARE OUTCOME-ONLY (exit code + error_key/status), never
# text presence — the defect this section guards was a check that failed to
# RUN at all, not a check whose printed text was wrong, so a text-presence
# assertion could not have caught it and must not be how this is guarded
# going forward either (i8cx operator ruling, same discipline Section 8h's
# own header states for the retired-waiver-text axis).

TID31=$(bd create "D5 R9-F1: no_design_attempted does not bypass an open conflict" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART31="$FIXTURE/docs/specs/$TID31.md"
write_artifact "$ART31" "$TID31"

# --- precondition: genuinely no_design_attempted, even though the artifact
# FILE exists on disk — design-record is never called for TID31, anywhere in
# this section. design-status exposes compute_design_satisfied's key
# VERBATIM even on its ok:true/exit-0 path (unlike design-gate-precheck's
# own "ready" envelope, which carries no error_key field at all), so this is
# the precise, outcome-based way to confirm the state under test without
# relying on design-gate-precheck's own prose.
STATUS31=$(bash "$QG" design-status "$TID31" 2>&1)
assert_eq "8j.1 precondition: no_design_attempted (artifact FILE exists, never design-recorded)" \
    "no_design_attempted" "$(json_field '.error_key' "$STATUS31")"

# --- ANTI-VACUITY COMPANION: the SAME task, before any conflict is filed,
# still reports ready. Without this leg, 8j.4 below would pass just as well
# if design-gate-precheck simply broke outright (e.g. always exit 4).
PRECHECK31A=$(bash "$QG" design-gate-precheck "$TID31" 2>&1); PRECHECK31A_RC=$?
assert_eq "8j.2 ANTI-VACUITY: no_design_attempted, NO conflict filed yet: exit 0" \
    "0" "$PRECHECK31A_RC"
assert_eq "8j.2b ...status=ready" "ready" "$(json_field '.status' "$PRECHECK31A")"

# --- file a REAL DESIGN-CONFLICT against the on-disk artifact.
CONFLICT31_OUT=$(bash "$QG" design-conflict "$TID31" --unit U1 "AC1 cannot be satisfied as designed; filed against an artifact that was never design-recorded" 2>&1)
assert_eq "8j.3 precondition: the conflict writer accepts it (no DESIGN-ARTIFACT record required)" \
    "recorded" "$(json_field '.status' "$CONFLICT31_OUT")"
STATUS31B=$(bash "$QG" design-status "$TID31" 2>&1)
assert_eq "8j.3b precondition still holds: TID31 is STILL no_design_attempted after filing the conflict" \
    "no_design_attempted" "$(json_field '.error_key' "$STATUS31B")"

# --- R9-F1 THE FIX ITSELF ---------------------------------------------------
PRECHECK31B=$(bash "$QG" design-gate-precheck "$TID31" 2>&1); PRECHECK31B_RC=$?
assert_eq "8j.4 R9-F1 THE FIX ITSELF: no_design_attempted + an open conflict now REFUSES: exit 4" \
    "4" "$PRECHECK31B_RC"
assert_eq "8j.4b ...error_key=design_conflict_open (not no_design_attempted, not ready)" \
    "design_conflict_open" "$(json_field '.error_key' "$PRECHECK31B")"

# ===========================================================================
printf '\n=== Section 8k: METatest — the R9-F1 fix is load-bearing ===\n'
# ===========================================================================

awk '/# DESIGN-GATE-PRECHECK-CONFLICT BEGIN/{s=1} !s{print} /# DESIGN-GATE-PRECHECK-CONFLICT END/{s=0}' \
    "$QG" > "$FIXTURE/.claude/scripts/qa-gate-noprecheckconflict.sh"
STRIP_DELTA3=$(( $(wc -l < "$QG") - $(wc -l < "$FIXTURE/.claude/scripts/qa-gate-noprecheckconflict.sh") ))
assert_eq "8k.1 META: the region strip actually removed lines" "yes" "$([ "$STRIP_DELTA3" -gt 10 ] && echo yes || echo no)"
chmod +x "$FIXTURE/.claude/scripts/qa-gate-noprecheckconflict.sh"
if bash -n "$FIXTURE/.claude/scripts/qa-gate-noprecheckconflict.sh" 2>/dev/null; then
    assert_eq "8k.1b META: the stripped copy is still valid bash" "0" "0"
else
    assert_eq "8k.1b META: the stripped copy is still valid bash" "0" "1"
fi

CTRL31_OUT=$(bash "$QG" design-gate-precheck "$TID31" 2>&1); CTRL31_RC=$?
assert_eq "8k.2 META CONTROL: the SHIPPED script still refuses TID31 (no_design_attempted, open conflict)" \
    "4|design_conflict_open" "$CTRL31_RC|$(json_field '.error_key' "$CTRL31_OUT")"
MUTANT31_OUT=$(bash "$FIXTURE/.claude/scripts/qa-gate-noprecheckconflict.sh" design-gate-precheck "$TID31" 2>&1); MUTANT31_RC=$?
assert_eq "8k.3 META MISBEHAVIOUR: the STRIPPED copy reports the SAME task ready — the exact R9-F1 defect shape" \
    "0|ready" "$MUTANT31_RC|$(json_field '.status' "$MUTANT31_OUT")"
rm -f "$FIXTURE/.claude/scripts/qa-gate-noprecheckconflict.sh"

# ===========================================================================
printf '\n=== Section 8l: A2 (claude-workflow-plugin-i8cx) — the idempotency-arm reach-around ===\n'
# ===========================================================================
# EVERY leg in 8a-8k files its DESIGN-CONFLICT before the task's first-ever
# approve, so had_approved=0 every time and the code under test is always
# the MAIN block (or design-gate-precheck's own copy) — never cmd_approve's
# hash-aware IDEMPOTENCY no-op, which returns from a completely different,
# much earlier point in the function. That gap is exactly how A2 shipped and
# survived ten independent review rounds: approve -> file a conflict on an
# ALREADY-approved, unchanged change set -> approve again reported
# status=approved, exit 0, because the idempotency arm never asked
# compute_design_conflict_open at all.

TID32=$(bd create "A2 idempotency-arm reach-around subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID32"
ART32="$FIXTURE/docs/specs/$TID32.md"
write_artifact "$ART32" "$TID32"
printf '%s\n' "$ART32" > "$TRACKING"
bash "$QG" enter "$TID32" >/dev/null 2>&1
bash "$QG" design-record "$TID32" >/dev/null 2>&1
HASH32=$(bash "$WM" hash-file "$ART32")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID32" --design-hash "$HASH32" >/dev/null 2>&1
seed_approvable "$TID32"

OUT=$(bash "$QG" approve "$TID32" "first approval, no conflict yet" 2>&1)
assert_eq "8l.1 precondition: the FIRST approve succeeds (fresh, non-idempotent path)" "approved" "$(json_field '.status' "$OUT")"
assert_contains "8l.1b precondition: qa-approved is now set" "qa-approved" "$(labels_of "$TID32")"
PRE32_APPROVALS=$(comments_of "$TID32" | grep -cE '^QA-GATE APPROVED ' 2>/dev/null | tr -d ' \n')
assert_eq "8l.1c precondition: exactly one bound approval record exists" "1" "$PRE32_APPROVALS"

# File the conflict AFTER the approval, against the SAME, still-unamended
# artifact — no file touched, so change_set_hash does not move and a repeat
# approve would otherwise take the idempotency arm.
OUT=$(bash "$QG" design-conflict "$TID32" --unit U1 "filed AFTER approval, on an unchanged change set" 2>&1)
assert_eq "8l.2 precondition: the conflict is recorded" "recorded" "$(json_field '.status' "$OUT")"

# --- THE REFUSAL LEG: the reproduction from A2's own repro steps ----------
PRE32_COUNT=$(comment_count "$TID32")
OUT=$(bash "$QG" approve "$TID32" "second approve: should hit the idempotency arm, must still refuse" 2>&1); EXIT_RC=$?
assert_eq "8l.3 A2 FIX: a second approve on an already-approved, unchanged change set REFUSES once a conflict exists: exit 2" \
    "2" "$EXIT_RC"
assert_eq "8l.3b ...error_key=design_conflict_open (identical to the main block's own key)" \
    "design_conflict_open" "$(json_field '.error_key' "$OUT")"
assert_contains "8l.3c ...names the affected unit in the observations" "U1" "$(json_field '.observations' "$OUT")"
POST32_COUNT=$(comment_count "$TID32")
assert_eq "8l.3d the task is left UNTOUCHED (the refusal writes nothing)" "$PRE32_COUNT" "$POST32_COUNT"
POST32_APPROVALS=$(comments_of "$TID32" | grep -cE '^QA-GATE APPROVED ' 2>/dev/null | tr -d ' \n')
assert_eq "8l.3e ...and no SECOND approval record was written" "$PRE32_APPROVALS" "$POST32_APPROVALS"

# ===========================================================================
printf '\n=== Section 8m: A2 IDEMPOTENCY-PRESERVED — anti-overreach control ===\n'
# ===========================================================================
# The essential companion to 8l.3: a genuine repeat approve with NO new
# conflict must remain the documented no-op. Without this leg, 8l.3 alone
# could be satisfied by a fix that re-verifies EVERYTHING on the idempotency
# arm (option (c) taken literally) — which would ALSO refuse-or-rewrite this
# control case, trading the A2 defect for a broken idempotency contract.

TID33=$(bd create "A2 idempotency-preserved control subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
seed_grilling "$TID33"
ART33="$FIXTURE/docs/specs/$TID33.md"
write_artifact "$ART33" "$TID33"
printf '%s\n' "$ART33" > "$TRACKING"
bash "$QG" enter "$TID33" >/dev/null 2>&1
bash "$QG" design-record "$TID33" >/dev/null 2>&1
HASH33=$(bash "$WM" hash-file "$ART33")
printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$TID33" --design-hash "$HASH33" >/dev/null 2>&1
seed_approvable "$TID33"

OUT=$(bash "$QG" approve "$TID33" "first approval, no conflict ever" 2>&1)
assert_eq "8m.1 precondition: the FIRST approve succeeds" "approved" "$(json_field '.status' "$OUT")"

PRE33_COUNT=$(comment_count "$TID33")
PRE33_APPROVALS=$(comments_of "$TID33" | grep -cE '^QA-GATE APPROVED ' 2>/dev/null | tr -d ' \n')
OUT=$(bash "$QG" approve "$TID33" "second approve: no new conflict, must still no-op" 2>&1); EXIT_RC=$?
assert_eq "8m.2 IDEMPOTENCY PRESERVED: a genuine repeat approve, no conflict, is still exit 0" "0" "$EXIT_RC"
assert_eq "8m.2b ...status=approved" "approved" "$(json_field '.status' "$OUT")"
assert_contains "8m.2c ...and still SAYS it is an idempotent no-op (the source's own discriminator string — see the IDEMPOTENCY comment on why the OPPOSITE outcome deliberately never uses this phrase)" \
    "idempotent no-op" "$(json_field '.observations' "$OUT")"
POST33_COUNT=$(comment_count "$TID33")
assert_eq "8m.3 ANTI-VACUITY: comment_count is BYTE-IDENTICAL before/after — proves the idempotency arm's TRUE no-op ran (a fall-through re-verify-and-rewrite would have appended a fresh QA-GATE APPROVED comment even if it ALSO happened to conclude approved)" \
    "$PRE33_COUNT" "$POST33_COUNT"
POST33_APPROVALS=$(comments_of "$TID33" | grep -cE '^QA-GATE APPROVED ' 2>/dev/null | tr -d ' \n')
assert_eq "8m.3b ...and specifically: still exactly one QA-GATE APPROVED record (not a second one)" \
    "$PRE33_APPROVALS" "$POST33_APPROVALS"

# ===========================================================================
printf '\n=== Section 8n: METatest — IDEMPOTENT-APPROVE-CONFLICT-RECHECK is load-bearing ===\n'
# ===========================================================================
# Same convention as 8d/8k: strip the new sentinel region from a copy and
# watch the SAME task (TID32, already carrying a bound approval AND an open,
# un-amended conflict after section 8l's own leg above) approve anyway.
# Reusing TID32 rather than a fresh subject is deliberate: its state after
# 8l.3 IS the exact precondition this METatest needs (already approved once,
# conflict filed afterward, second approve currently refusing), so a third
# repeat of the six-command setup dance would test nothing a fresh TID's
# CONTROL leg here does not already re-confirm.

awk '/# IDEMPOTENT-APPROVE-CONFLICT-RECHECK BEGIN/{s=1} !s{print} /# IDEMPOTENT-APPROVE-CONFLICT-RECHECK END/{s=0}' \
    "$QG" > "$FIXTURE/.claude/scripts/qa-gate-noidemconflict.sh"
STRIP_DELTA9=$(( $(wc -l < "$QG") - $(wc -l < "$FIXTURE/.claude/scripts/qa-gate-noidemconflict.sh") ))
assert_eq "8n.1 META: the region strip actually removed lines" "yes" "$([ "$STRIP_DELTA9" -gt 10 ] && echo yes || echo no)"
chmod +x "$FIXTURE/.claude/scripts/qa-gate-noidemconflict.sh"
if bash -n "$FIXTURE/.claude/scripts/qa-gate-noidemconflict.sh" 2>/dev/null; then
    assert_eq "8n.1b META: the stripped copy is still valid bash" "0" "0"
else
    assert_eq "8n.1b META: the stripped copy is still valid bash" "0" "1"
fi

CTRL32_OUT=$(bash "$QG" approve "$TID32" "control: shipped script, second approve, open conflict present" 2>&1); CTRL32_RC=$?
assert_eq "8n.2 META CONTROL: the SHIPPED script still refuses TID32's second approve" \
    "2|design_conflict_open" "$CTRL32_RC|$(json_field '.error_key' "$CTRL32_OUT")"
MUTANT32_OUT=$(bash "$FIXTURE/.claude/scripts/qa-gate-noidemconflict.sh" approve "$TID32" "mutant: same task, idempotency-arm recheck stripped" 2>&1); MUTANT32_RC=$?
assert_eq "8n.3 META MISBEHAVIOUR: the STRIPPED copy reports the SAME already-approved task 'approved' again — the exact A2 defect shape reproduced" \
    "0|approved" "$MUTANT32_RC|$(json_field '.status' "$MUTANT32_OUT")"
rm -f "$FIXTURE/.claude/scripts/qa-gate-noidemconflict.sh"

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

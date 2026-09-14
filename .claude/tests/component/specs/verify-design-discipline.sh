#!/bin/bash
# verify-design-discipline.sh — L2 component spec for the DESIGN-DISCIPLINE
# release block in verify-before-stop.sh (v5 Phase D2 Part B /
# claude-workflow-plugin-fkm.4).
#
# THE CONTRACT UNDER TEST: mirrors verify-review-discipline.sh, for the
# design-satisfied axis instead of the code-review one. A change-set-bound
# approval is necessary but no longer sufficient: before releasing, the Stop
# hook re-runs `qa-gate.sh design-gate-precheck` — the SAME predicate
# (compute_design_satisfied) `approve` itself consulted — against the CURRENT
# record set. That re-check exists because a design can regress AFTER an
# approval (a fresh review comes back needs_revision, the artifact is
# edited), and the approval record, written once, cannot know about it.
#
# THE SHARPEST CASE THIS FILE DRIVES (D2) IS DELIBERATELY A ZERO-FILE-CHANGE
# ONE: a second DESIGN-REVIEW verdict posted as a bare Beads comment, with NO
# artifact edit at all. That is precisely the "state lives only in bd" hole
# fkm.4's own spec names (section B3): the Stop hook's SKIP-UNCHANGED region
# is keyed on tree_fingerprint() (file-based, minus the tracked-path
# denylist), which a Beads-only change moves not at all — so a design check
# wired INSIDE that region would replay a stale, already-green result right
# past a live regression. This is the case that proves DESIGN-DISCIPLINE's
# placement OUTSIDE SKIP-UNCHANGED (mirroring REVIEW-DISCIPLINE) actually
# matters, rather than merely documenting an intention.
#
# Cases (each drives the REAL hook with a crafted stdin payload):
#   D1  satisfied design + matching approval record        -> RELEASE (control)
#   D2  a FRESH DESIGN-REVIEW verdict (needs_revision) posted AFTER the
#       approval, with NO file touched at all               -> BLOCK, reason
#                                                               cites design_not_satisfied
#   D3  a further DESIGN-REVIEW verdict restoring satisfied  -> RELEASE
#   D4  an audited `[design bypass:` record (approved via --no-design, no
#       design verdict at all)                              -> RELEASE anyway
#                                                               — isolating the
#                                                               marker as cause
#   D5  qa-gate.sh missing                                  -> BLOCK (fail CLOSED)
#   D6  META: strip the DESIGN-DISCIPLINE sentinel block from a copy of the
#       hook -> the D2 regressed-design state RELEASES, proving the block
#       (not something incidental) is what refuses.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
QG="$FIXTURE/.claude/scripts/qa-gate.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
WM="$FIXTURE/.claude/scripts/workflow-manifest.sh"
IR="$FIXTURE/.claude/scripts/impact-report.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# Same reasoning as verify-review-discipline.sh's own header: keep this
# spec's own instrumentation (the harness's bin/, .claude/scripts/ symlinks,
# .qa-tracking/) out of the fixture's git view, so the SUBJECT (the design
# artifact under docs/specs/) stays the only tracked, reviewable diff.
printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' > "$FIXTURE/.gitignore"
(cd "$FIXTURE" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

rm -f "$FIXTURE/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$FIXTURE/.claude/scripts/detect-stack.sh"
chmod +x "$FIXTURE/.claude/scripts/detect-stack.sh"

baseline_incidental_dirt "$FIXTURE"

stop_decision() {
    local hook="${1:-$VBS}"
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | bash "$hook" 2>/dev/null | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null
}

stop_reason() {
    local hook="${1:-$VBS}"
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | bash "$hook" 2>/dev/null | tail -1 | jq -r '.reason // ""' 2>/dev/null
}

comments_of() {
    bd_show_with_comments "$1" \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' \
        2>/dev/null || echo ""
}

# design_artifact_path <tid> — mirrors qa-gate.sh's own derivation exactly
# (design_artifact_path_for), so this spec never guesses a second one.
design_artifact_path() {
    local sanitized
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/docs/specs/%s.md' "$FIXTURE" "$sanitized"
}

write_artifact() {
    local path="$1" tid="$2"
    # mk_fixture (unlike the L1 test tier's own fixture setup) does not
    # pre-create docs/specs/ — most component specs never touch a design
    # artifact — so this function ensures its own directory rather than
    # assuming the shared harness provides it.
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    cat > "$path" <<ARTIFACT
# Design — $tid

## Problem
Component-tier test subject.

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
make test-component

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
      "verification": "make test-component",
      "depends_on": []
    }
  ]
}
\`\`\`
<!-- DESIGN-UNITS END -->
ARTIFACT
}

# seed_code_review_only <tid> [reviewer] [role] — IMPLEMENTER + REVIEW-ARTIFACT
# + COMPLETION, deliberately WITHOUT seed_review_records' own design seeding
# (v5 D2 folded seed_design_verdict into that shared helper — see its own
# header in lib/fixture.sh). This spec needs precise, independent control of
# the design axis, so it builds the code-review half locally instead of
# calling the shared helper and then fighting its auto-seeded design verdict.
seed_code_review_only() {
    local tid="$1" reviewer="${2:-qa-claude}" role="${3:-devops}"
    local ts hash art pay
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1 \
        || bd comment add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1
    hash=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" --hash-only 2>/dev/null || echo "")
    [ -z "$hash" ] && hash="unverified"
    art="$TRACK/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"%s","reviewer_model":"seeded","reviewer_pin":"seeded","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded fixture","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
        "$tid" "$reviewer" "$hash" > "$art"
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" review-record "$tid" < "$art" >/dev/null 2>&1
    if [ -f "$IR" ]; then
        CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
        CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" "$tid" >/dev/null 2>&1 || true
    fi
    pay="$TRACK/completion-draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    printf '{"task_id":"%s","role":"%s","model":"seeded","pin":"seeded","files_changed":[],"tests_added":[],"decisions":["seeded"],"blockers":[],"llm_observations":"seeded","context_coverage":"seeded","unit_id":"","design_hash":"","green_before":"none","green_after":"none","criteria_tests":{}}\n' \
        "$tid" "$role" > "$pay"
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" completion-record "$tid" --file "$pay" >/dev/null 2>&1
}

restage() {
    local tid="$1" file="$2"
    bash "$CT" set "$tid" >/dev/null 2>&1
    {
        printf '%s\n' "$file"
        [ -n "$RESTAGE_ART_LINES" ] && printf '%s\n' "$RESTAGE_ART_LINES"
    } > "$TRACK/changed-files.txt"
}
RESTAGE_ART_LINES=""

VALID_VERDICT='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'

# ---------------------------------------------------------------------------
# D1: control — satisfied design + matching approval releases.
TID=$(cd "$FIXTURE" && bd create "design-discipline release" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
ART="$(design_artifact_path "$TID")"
write_artifact "$ART" "$TID"
printf '%s\n' "$ART" > "$TRACK/changed-files.txt"
bash "$QG" enter "$TID" >/dev/null 2>&1
# v5 D3 (claude-workflow-plugin-fkm.5): design-record now refuses
# grilling_record_missing without one; seed it first, through the real
# writer. This file exercises the DESIGN-DISCIPLINE Stop-hook re-check, not
# the grilling precondition — seed_grilling_record is the shared fixture
# helper every other seeding path in this tier now goes through for free.
seed_grilling_record "$TID" "$FIXTURE" >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" design-record "$TID" >/dev/null 2>&1
HASH=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$WM" hash-file "$ART")
printf '%s' "$VALID_VERDICT" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" design-review-record "$TID" --design-hash "$HASH" >/dev/null 2>&1
seed_code_review_only "$TID" "qa-claude" "devops"
# Snapshot the docs/reviews/ line(s) the reconcile above folded in —
# RESTAGE's own comment (below) explains why this snapshot, taken once at
# the instant it is present AND known-correct, is the correct source rather
# than a live re-read or a fresh glob (identical reasoning to
# verify-review-discipline.sh's TID_ART_LINES). Deliberately NOT
# /docs/specs/ too: every restage() call below for this task already passes
# $ART as its own explicit <file> argument, so capturing it a second time
# here would duplicate the line and change the canonical hash restage means
# to reproduce.
TID_ART_LINES=$(grep -E '/docs/reviews/' "$TRACK/changed-files.txt" 2>/dev/null || true)
RESTAGE_ART_LINES="$TID_ART_LINES"
APPROVE_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$TID" "design satisfied; ships safely" 2>&1)
assert_json_field "D1: approve succeeds with a satisfied, matching design verdict" \
    "$APPROVE_OUT" '.status' "approved"
restage "$TID" "$ART"
assert_eq "D1: satisfied design + matching record -> RELEASE" "ALLOW" "$(stop_decision)"

# ---------------------------------------------------------------------------
# D2: a FRESH needs_revision verdict posted AFTER approval, NO file touched.
#
# This is the whole point of the re-check: the approval record is already
# written and still matches the change-set (llh.18 is satisfied), and NO
# tracked file moved either (tree_fingerprint is unchanged) — only the
# design-review state in Beads changed. If DESIGN-DISCIPLINE were wired
# inside SKIP-UNCHANGED (keyed on tree_fingerprint), this exact case would
# replay a stale green result. It is not; this proves that.
restage "$TID" "$ART"
NR=$(printf '%s' "$VALID_VERDICT" | jq -c '.verdict="needs_revision" | .iteration=2 | .required_fixes=["U1 needs another look"] | .criterion_results=[{"criterion":"DS2","pass":false,"justification":"regressed"}]')
printf '%s' "$NR" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" design-review-record "$TID" --design-hash "$HASH" >/dev/null 2>&1
# Precondition: the approval record is STILL on file and still matches (any
# block below is about DESIGN state, not the code review or the change set).
D2_RECORD_OK=$(comments_of "$TID" | grep -cE '^QA-GATE APPROVED .*change_set_hash=' 2>/dev/null | tr -d ' ')
assert_eq "D2: precondition — the change-set-bound approval record is still on file" \
    "1" "$D2_RECORD_OK"
assert_eq "D2: precondition — NO file changed (tree_fingerprint-relevant set is identical)" \
    "$ART" "$(cat "$TRACK/changed-files.txt" | head -1)"
assert_eq "D2: a post-approval needs_revision verdict, zero file changes -> BLOCK" \
    "block" "$(stop_decision)"
restage "$TID" "$ART"
D2_REASON=$(stop_reason)
assert_contains "D2: block reason names the error_key" "design_not_satisfied" "$D2_REASON"
assert_contains "D2: block reason steers to design-review-record" \
    "qa-gate.sh design-review-record" "$D2_REASON"
assert_contains "D2: block reason explains a design can regress AFTER approval" \
    "happen AFTER an approval" "$D2_REASON"

# ---------------------------------------------------------------------------
# D3: a further verdict restoring satisfied clears it.
restage "$TID" "$ART"
SAT2=$(printf '%s' "$VALID_VERDICT" | jq -c '.iteration=3')
printf '%s' "$SAT2" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" design-review-record "$TID" --design-hash "$HASH" >/dev/null 2>&1
restage "$TID" "$ART"
assert_eq "D3: a fresh satisfied verdict restores -> RELEASE" "ALLOW" "$(stop_decision)"

# ---------------------------------------------------------------------------
# D4: the audited `[design bypass:` record (approved via --no-design).
#
# Drive a REAL --no-design approve rather than hand-writing the marker — a
# task that genuinely never had a design phase, exactly like the F1 doc-only
# fast path's own --no-review usage (verify-review-discipline.sh's D4).
TID_ND=$(cd "$FIXTURE" && bd create "no-design bypass" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
printf 'src/other.ts\n' > "$TRACK/changed-files.txt"
mkdir -p "$FIXTURE/src" 2>/dev/null || true
: > "$FIXTURE/src/other.ts"
bash "$QG" enter "$TID_ND" >/dev/null 2>&1
seed_code_review_only "$TID_ND" "qa-claude" "devops"
RESTAGE_ART_LINES=$(grep -E '/docs/reviews/' "$TRACK/changed-files.txt" 2>/dev/null || true)
ND_APPROVE=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$TID_ND" --no-design "this task has no design phase" "bypassed" 2>&1)
assert_json_field "D4: --no-design approve succeeds" "$ND_APPROVE" '.status' "approved"
restage "$TID_ND" "src/other.ts"
assert_eq "D4: a [design bypass:] record releases despite NO design verdict at all" \
    "ALLOW" "$(stop_decision)"
ND_APPROVAL=$(comments_of "$TID_ND" | grep 'QA-GATE APPROVED' | tail -1)
assert_contains "D4: the approval record carries the audited [design bypass:] marker" \
    "[design bypass: this task has no design phase" "$ND_APPROVAL"

# ---------------------------------------------------------------------------
# D5: FAIL CLOSED when qa-gate.sh (DESIGN-DISCIPLINE's predicate script) is
# unavailable.
#
# Same task and state as D3's release — the ONLY variable is whether
# qa-gate.sh exists (DESIGN-DISCIPLINE calls `qa-gate.sh design-gate-precheck`
# as a subprocess, exactly as REVIEW-DISCIPLINE calls review-check.sh gate).
# UNLIKE review-check.sh, though, qa-gate.sh's total absence is ALSO caught
# by a separate, earlier, unconditional guard elsewhere in this hook (it owns
# the change-set tracker reconcile too) — see the comment on the assertion
# below for what that means for attribution.
#
# claude-workflow-plugin-rqer precedent (verify-review-discipline.sh's own
# D5 comment): restore RESTAGE_ART_LINES to TID's snapshot first — D4 just
# overwrote that GLOBAL with $TID_ND's own (unrelated) review-artifact line,
# and restage()'s tracker write for $TID would otherwise fold a DIFFERENT
# task's docs/reviews/ path into THIS one's change set, moving the hash away
# from what D1 actually bound and turning this sanity check into a spurious
# BLOCK.
RESTAGE_ART_LINES="$TID_ART_LINES"
restage "$TID" "$ART"
assert_eq "D5: sanity — this state releases while qa-gate.sh is present" \
    "ALLOW" "$(stop_decision)"
QG_REAL=$(readlink "$QG" 2>/dev/null || printf '%s' "$QG")
rm -f "$QG"
assert_eq "D5: precondition — qa-gate.sh is absent" \
    "absent" "$([ -e "$QG" ] && echo present || echo absent)"
restage "$TID" "$ART"
assert_eq "D5: MISSING qa-gate.sh -> BLOCK (fails closed, not open)" \
    "block" "$(stop_decision)"
restage "$TID" "$ART"
D5_REASON=$(stop_reason)
# NOT "design predicate is missing": removing qa-gate.sh ENTIRELY trips a
# MORE FUNDAMENTAL, EARLIER, unconditional guard in verify-before-stop.sh
# (around its own tracker-reconcile setup — "QA gate cannot run: qa-gate.sh
# is missing", which emit_block's and exits before this hook ever reaches
# the gate block DESIGN-DISCIPLINE lives in). That guard exists precisely
# because qa-gate.sh is ALSO what owns the change-set tracker reconcile, so
# its total absence is caught long before any design-specific logic runs.
# DESIGN-DISCIPLINE's OWN `[ ! -f "$QA_GATE" ]` arm is consequently
# unreachable for "qa-gate.sh entirely absent" — it would only fire if a
# future refactor separated design-gate-precheck into its own script the
# way review-check.sh already is (which is exactly why REVIEW-DISCIPLINE's
# OWN missing-predicate leg IS independently reachable: review-check.sh is
# a distinct file qa-gate.sh does not depend on for the reconcile). This
# assertion proves the SYSTEM still fails closed either way — which is the
# property D5 exists to establish — while naming the ACTUAL, observed cause
# rather than the one this test originally assumed.
assert_contains "D5: block reason names qa-gate.sh as the missing dependency (a more fundamental, earlier guard than DESIGN-DISCIPLINE's own — see comment)" \
    "qa-gate.sh is missing" "$D5_REASON"
ln -sf "$QG_REAL" "$QG"
restage "$TID" "$ART"
assert_eq "D5: restoring qa-gate.sh restores the release" "ALLOW" "$(stop_decision)"

# ---------------------------------------------------------------------------
# D6: META — the DESIGN-DISCIPLINE block is load-bearing.
#
# Strip everything between the sentinels from a COPY of the hook and re-run
# D2's exact scenario (matching approval record + a post-approval
# needs_revision verdict, zero file changes). Under the stripped copy the
# release SUCCEEDS, i.e. D2's "block" assertion would fail — so D2 is
# testing the block, not a side effect.
#
# 3mg.1 precedent (see verify-review-discipline.sh's own D6 comment): the
# stripped copy lives in the fixture's `.claude/scripts/`, next to the
# `workflow-denylist.sh` the hook sources BASH_SOURCE-relative. Parked at the
# fixture root it would take the missing-denylist fail-closed arm and BLOCK
# regardless — inverting this META's expected ALLOW and hiding whether the
# DESIGN-DISCIPLINE block is load-bearing at all.
VBS_STRIPPED="$FIXTURE/.claude/scripts/verify-before-stop-nodesigndiscipline.sh"
REAL_VBS=$(readlink "$VBS" 2>/dev/null || printf '%s' "$VBS")
STRIP_RC=0
awk '
    /# DESIGN-DISCIPLINE BEGIN/ { skipping=1; found=1; next }
    /# DESIGN-DISCIPLINE END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$REAL_VBS" > "$VBS_STRIPPED" || STRIP_RC=$?
chmod +x "$VBS_STRIPPED"
assert_eq "D6 META: DESIGN-DISCIPLINE sentinels present in verify-before-stop.sh" \
    "0" "$STRIP_RC"

if [ "$STRIP_RC" -eq 0 ]; then
    PARSE_RC=0
    bash -n "$VBS_STRIPPED" 2>/dev/null || PARSE_RC=$?
    assert_eq "D6 META: stripped copy still parses (block is cleanly strippable)" \
        "0" "$PARSE_RC"

    TID_META=$(cd "$FIXTURE" && bd create "design-discipline META" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    ART_META="$(design_artifact_path "$TID_META")"
    write_artifact "$ART_META" "$TID_META"
    printf '%s\n' "$ART_META" > "$TRACK/changed-files.txt"
    bash "$QG" enter "$TID_META" >/dev/null 2>&1
    seed_grilling_record "$TID_META" "$FIXTURE" >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" design-record "$TID_META" >/dev/null 2>&1
    HASH_META=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$WM" hash-file "$ART_META")
    printf '%s' "$VALID_VERDICT" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" design-review-record "$TID_META" --design-hash "$HASH_META" >/dev/null 2>&1
    seed_code_review_only "$TID_META" "qa-claude" "devops"
    RESTAGE_ART_LINES=$(grep -E '/docs/reviews/' "$TRACK/changed-files.txt" 2>/dev/null || true)
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$TID_META" "clean at approve time" >/dev/null 2>&1
    NR_META=$(printf '%s' "$VALID_VERDICT" | jq -c '.verdict="needs_revision" | .iteration=2 | .required_fixes=["regressed"] | .criterion_results=[{"criterion":"DS2","pass":false,"justification":"regressed"}]')
    printf '%s' "$NR_META" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" design-review-record "$TID_META" --design-hash "$HASH_META" >/dev/null 2>&1
    # Control: the REAL hook blocks this state (same assertion as D2).
    restage "$TID_META" "$ART_META"
    assert_eq "D6 META: control — the real hook BLOCKS the regressed-design state" \
        "block" "$(stop_decision "$VBS")"
    # And the stripped copy releases it.
    restage "$TID_META" "$ART_META"
    assert_eq "D6 META: WITHOUT the block, the regressed design RELEASES (D2 WOULD fail)" \
        "ALLOW" "$(stop_decision "$VBS_STRIPPED")"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("D6 META: sentinels missing — strip meta-test skipped")
    printf '  FAIL: D6 META: sentinels missing — strip meta-test skipped\n'
fi

[ "$FAIL" -eq 0 ]

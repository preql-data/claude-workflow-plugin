#!/bin/bash
# design-coherence.test.sh — v5 D6 (claude-workflow-plugin-fkm.8): the
# coherence ROLLUP (docs/plans/v5-design-phase.md Phase D6: "the gate rolls
# up per-unit results into an epic-level count, in the manner of the
# unresolved-findings count: every acceptance criterion in the bound
# artifact maps to at least one passing test; every implemented unit maps
# to a design unit id; files touched outside all declared unit sets are
# scope drift").
#
# WHAT THIS COVERS, and why each part needs a test of its own:
#
#   1. `qa-gate.sh design-coherence` — three NOT APPLICABLE states, each
#      needing its own section because each is reached a different way:
#      <task-id> is not itself a satisfied design task (the ordinary case
#      for a v5 task-per-unit CHILD, and for every task with no design
#      phase at all); a satisfied design declares ZERO units (nothing to
#      roll up); and a satisfied design declares units but has ZERO bd
#      parent-child dependents at all (never decomposed via D4 — a single
#      small task can legitimately be its own design holder with no
#      separate children, and the coherence question does not yet apply to
#      it). The third is deliberately kept apart from case (b) below, which
#      looks similar from inside a single unit's own result but is reached
#      only after real children exist — see the LESSONS.md entry tagged
#      gate/process for why conflating the two is the natural mistake.
#
#   2. THE FIVE NAMED CASES from plan 178, each proven with a negative
#      control per .claude/tests/README.md's pairing requirement:
#        (a) a criterion with no covering test, on a unit that DOES have a
#            bound task (reuses compute_design_alignment's own
#            criteria_incomplete, propagated as kind=incomplete)
#        (b) a unit with no bound task, IN AN EPIC THAT HAS REAL CHILDREN
#            (kind=incomplete, naming the unit's own declared criteria as
#            uncovered by construction) — built by creating real bd
#            children first and leaving one deliberately unbound, so this
#            case cannot be confused with the zero-children NOT APPLICABLE
#            state in part 1
#        (c) a file some resolved unit's completion contract claims to
#            have touched, that no unit declares anywhere (kind=
#            undeclared_scope — the UNION check design-conform's own
#            per-task check is never asked)
#        (d) hash divergence: a unit's own DESIGN-UNIT binding hash no
#            longer equals the artifact's current governing hash after an
#            amendment (kind=hash_divergence), cleared by re-binding
#        (e) tracker/diff mismatch: a file genuinely in the CURRENT change
#            set that no unit declares and no completion payload claims
#            (kind=tracker_diff_mismatch — the 94d-shaped under-coverage
#            case plan 177 exists for), distinct from (c)
#
#   3. GATE-EVIDENCE-EXCLUSION: the rollup's own design artifact and every
#      resolved unit's own review artifact(s) must NOT themselves trip (e)
#      — proven by the full success path landing on ok:true while both
#      remain genuinely present in the live tracker.
#
#   4. Wiring into `qa-gate.sh approve` — COHERENCE-ROLLUP-REFUSAL: an
#      incoherent, satisfied design task refuses approval (exit 2); a
#      coherent one does not, and its approval comment carries
#      `design_artifact=<ref>@<hash>` (plan 176).
#
#   5. METatest: stub the rollup's count-translation step to always return
#      zero and confirm the SAME defect (Section 8's undeclared_scope) that
#      the shipped script catches now clears — "if the suite stays green
#      with the rollup stubbed, it is decorative" (the brief's own words).
#
# Needs a real bd fixture, same shape as design-unit-align.test.sh; two
# units under one epic, two children, driven through completion-record,
# design-unit-bind, review-record and approve across a dozen-plus cycles.
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

# ---------------------------------------------------------------------------
# Fixture. Same shape as design-unit-align.test.sh: the real scripts, a real
# bd, a throwaway project root and HOME, and a real git repo (this file, not
# design-unit-align.test.sh, needs `git commit` between cycles so that
# reconcile-tracker's git-status scan does not sweep a LATER unit's
# not-yet-completed files into an EARLIER unit's own change set — see the
# comment on CHILD1's own cycle, Section 4, for the full reasoning).

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t design-coherence.XXXXXX)
TEST_HOME=$(mktemp -d -t design-coherence-home.XXXXXX)

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

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/scripts/tests" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.beads" "$FIXTURE/bin" "$FIXTURE/docs/specs" "$FIXTURE/src" \
    "$FIXTURE/.claude/vendor/superpowers/brainstorming" \
    "$TEST_HOME/.claude/projects"

cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh
cp "$PLUGIN_DIR/.claude/vendor/superpowers/brainstorming/SKILL.md" \
    "$FIXTURE/.claude/vendor/superpowers/brainstorming/SKILL.md"

if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — design-coherence tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — design-coherence tests require jq."
    exit 2
fi
if ! command -v git >/dev/null 2>&1; then
    echo "git not on PATH — design-coherence tests require a real git checkout."
    exit 2
fi

REAL_BD=$(command -v bd)
cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"
export PATH="$FIXTURE/bin:$PATH"

( cd "$FIXTURE" && git init -q && git config user.email t@t.com && git config user.name t )
cd "$FIXTURE" && bd init >/dev/null 2>&1
export CLAUDE_PROJECT_DIR="$FIXTURE"
export HOME="$TEST_HOME"

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
RC="$FIXTURE/.claude/scripts/review-check.sh"
WM="$FIXTURE/.claude/scripts/workflow-manifest.sh"
TRACKING="$FIXTURE/.claude/.qa-tracking/changed-files.txt"

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }

seed_grilling() {
    bash "$QG" grilling-record "$1" --rounds 2 --questions 4 --approaches 2 --unresolved 0 \
        "design-coherence.test.sh: seeding the grilling precondition" >/dev/null 2>&1
}

checkpoint_git() { ( cd "$FIXTURE" && git add -A >/dev/null 2>&1 && git commit -q -m "test checkpoint" --allow-empty >/dev/null 2>&1 ) || true; }

write_artifact() {
    local path="$1" tid="$2" units="$3"
    local block
    block=$(jq -nc --arg tid "$tid" --argjson units "$units" \
        '{contract_version:"1", task_id:$tid, designer_identity:"designer", units:$units}')
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
$block
\`\`\`
<!-- DESIGN-UNITS END -->
ARTIFACT
}

SATISFIED_V1='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'
SATISFIED_V2='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":2,"rubric_version":"1","reviewer_identity":"design-claude"}'

# design_and_review <epic-tid> <units-json> -> echoes the live artifact hash.
design_and_review() {
    local epic="$1" units="$2" art hash
    seed_grilling "$epic"
    art="$FIXTURE/docs/specs/$epic.md"
    write_artifact "$art" "$epic" "$units"
    printf '%s\n' "$art" > "$TRACKING"
    checkpoint_git
    bash "$QG" enter "$epic" >/dev/null 2>&1
    bash "$QG" design-record "$epic" >/dev/null 2>&1
    hash=$(bash "$WM" hash-file "$art")
    printf '%s' "$SATISFIED_V1" | bash "$QG" design-review-record "$epic" --design-hash "$hash" >/dev/null 2>&1
    printf '%s' "$hash"
}

# seed_spec_injection <tid> <epic> <unit-id> -- writes a SPEC-INJECTED v1
# record directly (design-accessors.test.sh Section 12's technique, reused
# verbatim by design-unit-align.test.sh), using the REAL per-unit content
# hash so LEG 2 (freshness, reused by the rollup) reads it as fresh.
seed_spec_injection() {
    local tid="$1" epic="$2" uid="$3"
    local art dhash ujson tmpf uhash ts
    art="$FIXTURE/docs/specs/$epic.md"
    dhash=$(bash "$WM" hash-file "$art")
    ujson=$(bash "$RC" design-unit-json "$art" "$uid" | jq -r '.unit_json')
    tmpf="$FIXTURE/.claude/.qa-tracking/.dc-si-tmp.json"
    printf '%s\n' "$ujson" > "$tmpf"
    uhash=$(bash "$WM" hash-file "$tmpf")
    rm -f "$tmpf"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "SPEC-INJECTED v1 task=$tid design_task=$epic unit_id=$uid design_hash=$dhash unit_hash=$uhash at $ts: injected at spawn" >/dev/null 2>&1
}

seed_green_check() {
    local tid="$1" phase="$2" result="$3" uid="${4:-U1}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "GREEN-CHECK v1 task=$tid unit_id=$uid phase=$phase result=$result exit_code=0 at $ts: suite $result (design-coherence.test.sh seeded)" >/dev/null 2>&1
}

write_test_file() {
    local rel="$1"; shift
    mkdir -p "$(dirname "$FIXTURE/$rel")"
    {
        printf '#!/bin/bash\n'
        local lbl
        for lbl in "$@"; do
            printf 'assert_eq "%s" "1" "1"\n' "$lbl"
        done
    } > "$FIXTURE/$rel"
}

# record_completion <tid> <role> <extra-json> -- builds a valid base F7
# payload merged with <extra-json> and records it via the REAL
# completion-record subcommand (the REAL validator runs on every call).
record_completion() {
    local tid="$1" role="$2" extra="$3"
    local out="$FIXTURE/.claude/.qa-tracking/.dc-completion-payload-$RANDOM$RANDOM.json"
    jq -n --arg tid "$tid" --arg role "$role" --argjson extra "$extra" '
        {task_id:$tid, files_changed:[], tests_added:[], decisions:["seeded"],
         blockers:[], llm_observations:"seeded", context_coverage:"seeded",
         role:$role, model:"m", pin:"m",
         unit_id:"", design_hash:"", green_before:"none", green_after:"none",
         criteria_tests:{}} + $extra
    ' > "$out"
    bash "$QG" completion-record "$tid" --file "$out" >/dev/null 2>&1
    rm -f "$out" 2>/dev/null || true
}

# seed_review_and_enter <tid> -- an IMPLEMENTER record, a review artifact, a
# reconciled tracker, and a fresh impact report (design-unit-align.test.sh's
# own helper, reused verbatim).
seed_review_and_enter() {
    local tid="$1" reviewer="${2:-qa-claude}" role="${3:-devops}"
    local ts hash art
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1 \
        || bd comment add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1
    bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
    hash=$(bash "$FIXTURE/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
    [ -z "$hash" ] && hash="unverified"
    art="$FIXTURE/.claude/.qa-tracking/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"%s","reviewer_model":"seeded-fixture","reviewer_pin":"seeded-fixture","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded fixture","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
        "$tid" "$reviewer" "$hash" > "$art"
    bash "$QG" review-record "$tid" < "$art" >/dev/null 2>&1
    bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
    bash "$FIXTURE/.claude/scripts/impact-report.sh" "$tid" >/dev/null 2>&1 || true
}

TWO_UNIT='[
  {"unit_id":"U1","role":"devops","goal":"unit one",
   "acceptance":[{"id":"AC1","text":"criterion one"}],
   "files":["src/a.sh",".claude/scripts/tests/dc-u1.test.sh"],
   "verification":"make test","depends_on":[]},
  {"unit_id":"U2","role":"devops","goal":"unit two",
   "acceptance":[{"id":"BC1","text":"criterion b1"}],
   "files":["src/b.sh",".claude/scripts/tests/dc-u2.test.sh"],
   "verification":"make test","depends_on":[]}
]'

# ===========================================================================
printf '\n=== Section 1: NOT APPLICABLE — task is not itself a design task ===\n'
# ===========================================================================

FRESH=$(bd create "DC: never a design task" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" design-coherence "$FRESH" 2>&1); RC_A=$?
assert_eq "1.1 exit 0" "0" "$RC_A"
assert_eq "1.1b ok=true, applicable=false" "true|false" \
    "$(json_field '.ok' "$OUT")|$(json_field '.applicable' "$OUT")"
assert_eq "1.1c coherence_count=0, unit_ids empty" "0|[]" \
    "$(json_field '.coherence_count' "$OUT")|$(echo "$OUT" | jq -c '.unit_ids')"

# ===========================================================================
printf '\n=== Section 2: NOT APPLICABLE — satisfied design, zero units declared ===\n'
# ===========================================================================

ZERO_UNIT_EPIC=$(bd create "DC epic zero units" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
design_and_review "$ZERO_UNIT_EPIC" '[]' >/dev/null
OUT=$(bash "$QG" design-coherence "$ZERO_UNIT_EPIC" 2>&1); RC_A=$?
assert_eq "2.1 exit 0" "0" "$RC_A"
assert_eq "2.1b ok=true, applicable=false (satisfied but nothing to roll up)" "true|false" \
    "$(json_field '.ok' "$OUT")|$(json_field '.applicable' "$OUT")"

# ===========================================================================
printf '\n=== Section 3: NOT APPLICABLE — declared units, but ZERO children ever created ===\n'
# ===========================================================================
# A satisfied design that declares units but has NO bd parent-child
# dependents at all was never decomposed via D4 -- nobody ever created a
# per-unit child task under it. "Does every declared unit map to its own
# child task" cannot be meaningfully asked of a task with no children,
# exactly as compute_design_alignment itself is not askable of a task with
# no DESIGN-UNIT binding. MEASURED, not assumed: before this NOT-APPLICABLE
# check existed, every satisfied, undecomposed design-holding task in this
# repo's OWN test suite (design-review-record.test.sh, design-artifact.
# test.sh) started refusing approval the moment it declared one unit --
# found by the regression battery this change's own completion report
# names, fixed here, and pinned by this section so it cannot silently
# regress again.

EPIC=$(bd create "DC epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
EPIC_HASH_V1=$(design_and_review "$EPIC" "$TWO_UNIT")

OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "3.1 exit 0 (nothing to roll up: never decomposed)" "0" "$RC_A"
assert_eq "3.1b ok=true, applicable=false" "true|false" \
    "$(json_field '.ok' "$OUT")|$(json_field '.applicable' "$OUT")"
assert_contains "3.1c observations name why: no children exist" "NO bd parent-child dependents" "$(json_field '.observations' "$OUT")"

# ===========================================================================
printf '\n=== Section 3b: (b) a unit with NO bound task, in an epic that HAS children ===\n'
# ===========================================================================
# Children now exist (so Section 3's not-applicable case no longer
# applies), but NEITHER is bound to a unit yet -- the real shape of "a unit
# with no bound task at all": some decomposition has genuinely happened,
# distinct from Section 3's "never decomposed" case, yet U1/U2 are still
# both unresolved. unit_task_map is genuinely empty, so task_id is empty
# and the unit's OWN declared criteria are named as uncovered by
# construction. Distinct from Section 4/5 below, where a task IS bound but
# has not yet completed, or has completed incompletely.

CHILD1=$(bd create "DC child 1 (U1)" -t task -p 1 --parent "$EPIC" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
CHILD2=$(bd create "DC child 2 (U2)" -t task -p 1 --parent "$EPIC" --no-inherit-labels --json 2>/dev/null | jq -r '.id')

OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "3b.1 exit 4 (both units unresolved, even though children now exist)" "4" "$RC_A"
assert_eq "3b.1b applicable=true, coherence_count=2" "true|2" \
    "$(json_field '.applicable' "$OUT")|$(json_field '.coherence_count' "$OUT")"
assert_eq "3b.1c both issues are kind=incomplete" "incomplete|incomplete" \
    "$(echo "$OUT" | jq -r '.issues[0].kind')|$(echo "$OUT" | jq -r '.issues[1].kind')"
assert_eq "3b.1d unresolved_unit_ids names both" "U1,U2" \
    "$(echo "$OUT" | jq -r '.unresolved_unit_ids | sort | join(",")')"
assert_eq "3b.1e both issues carry an EMPTY task_id (neither CHILD is bound yet)" "|" \
    "$(echo "$OUT" | jq -r '.issues[0].task_id')|$(echo "$OUT" | jq -r '.issues[1].task_id')"
assert_contains "3b.1f U2's own issue names its declared criterion id (BC1)" "BC1" \
    "$(echo "$OUT" | jq -c '[.issues[] | select(.unit_id=="U2")][0].criteria')"

# ===========================================================================
printf '\n=== Section 4: intermediate — U2 is BOUND but has no completion record yet ===\n'
# ===========================================================================
# CHILD1 (U1) gets bound and fully completed; CHILD2 (U2) gets bound (so
# unit_task_map now resolves it, unlike Section 3b) but never completed --
# distinct from BOTH Section 3b (no binding exists at all, task_id empty)
# and Section 5 below (bound AND completed, but criteria_tests itself is
# incomplete): this is compute_design_alignment's OWN no_implementer_
# completion_record leg, reused, surfacing here as kind=incomplete with a
# REAL task_id.
#
# ONLY U1's own declared files exist on disk / in git status while CHILD1's
# own cycle runs — U2's files are written LATER, after CHILD1 is committed
# — so reconcile-tracker's git-status scan (which cannot distinguish "this
# belongs to CHILD1" from "this belongs to CHILD2", it only sees git-visible
# dirt) never sweeps U2's uncommitted work into CHILD1's own change set. In
# the real, worktree-isolated v5 workflow (D4b: "each member getting its own
# worktree") this cross-contamination cannot happen at all, since each
# unit's reconcile only ever sees its own worktree; this fixture uses one
# shared tree, so it sequences around the same fact by hand.

bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC" --unit-id U1 "bound to U1" >/dev/null 2>&1
bash "$QG" design-unit-bind "$CHILD2" --design-task "$EPIC" --unit-id U2 "bound to U2" >/dev/null 2>&1

write_test_file "src/a.sh" "unused"
write_test_file ".claude/scripts/tests/dc-u1.test.sh" "covers AC1"
printf '%s\n%s\n' "$FIXTURE/src/a.sh" "$FIXTURE/.claude/scripts/tests/dc-u1.test.sh" > "$TRACKING"
seed_spec_injection "$CHILD1" "$EPIC" "U1"
record_completion "$CHILD1" "devops" "$(jq -nc --arg r ".claude/scripts/tests/dc-u1.test.sh" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     files_changed:["src/a.sh", $r],
     tests_added:[($r+"::covers AC1")],
     criteria_tests:{"AC1":[($r+"::covers AC1")]}}
')"
seed_green_check "$CHILD1" "after" "green" "U1"
seed_review_and_enter "$CHILD1"
APPR1=$(bash "$QG" approve "$CHILD1" --no-design "DC: not the axis under test" "approve child1" 2>&1); APPR1_RC=$?
assert_eq "4.1 CHILD1 (U1) approves cleanly (per-unit alignment, D5)" "0" "$APPR1_RC"
assert_eq "4.1b ...status=approved" "approved" "$(json_field '.status' "$APPR1")"
checkpoint_git

OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "4.2 exit 4 (U2 alone remains unresolved)" "4" "$RC_A"
assert_eq "4.2b coherence_count=1" "1" "$(json_field '.coherence_count' "$OUT")"
assert_eq "4.2c the remaining issue names U2, kind=incomplete" "U2|incomplete" \
    "$(echo "$OUT" | jq -r '.issues[0].unit_id')|$(echo "$OUT" | jq -r '.issues[0].kind')"
assert_eq "4.2d ...task_id is CHILD2's real id (BOUND, unlike Section 3's task_id-empty case)" "$CHILD2" \
    "$(echo "$OUT" | jq -r '.issues[0].task_id')"
assert_contains "4.2e ...detail cites compute_design_alignment's OWN no_implementer_completion_record key" \
    "no_implementer_completion_record" "$(echo "$OUT" | jq -r '.issues[0].detail')"

# ===========================================================================
printf '\n=== Section 5: (a) a BOUND unit whose criteria_tests is incomplete ===\n'
# ===========================================================================

write_test_file "src/b.sh" "unused"
write_test_file ".claude/scripts/tests/dc-u2.test.sh" "covers BC1"
printf '%s\n%s\n' "$FIXTURE/src/b.sh" "$FIXTURE/.claude/scripts/tests/dc-u2.test.sh" > "$TRACKING"
seed_spec_injection "$CHILD2" "$EPIC" "U2"
# Deliberately record CHILD2's completion with criteria_tests EMPTY — bound,
# but its one declared criterion (BC1) has no covering test. This alone
# would refuse CHILD2's OWN per-unit approve (D5); it must ALSO surface
# through the rollup as a DIFFERENT reason than Section 4's (no task at
# all) — case (a), not case (b).
record_completion "$CHILD2" "devops" '{"unit_id":"U2", "green_before":"green", "green_after":"green", "files_changed":["src/b.sh"], "tests_added":[], "criteria_tests":{}}'

OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "5.1 exit 4 (U2 now bound but incomplete)" "4" "$RC_A"
assert_eq "5.1b the issue for U2 now names its OWN task_id (bound, unlike Section 4)" "$CHILD2" \
    "$(echo "$OUT" | jq -r '[.issues[] | select(.unit_id=="U2")][0].task_id')"
assert_eq "5.1c kind=incomplete, detail cites the alignment leg's own key" "incomplete" \
    "$(echo "$OUT" | jq -r '[.issues[] | select(.unit_id=="U2")][0].kind')"
assert_contains "5.1d detail names criteria_incomplete (compute_design_alignment's OWN key, propagated)" \
    "criteria_incomplete" "$(echo "$OUT" | jq -r '[.issues[] | select(.unit_id=="U2")][0].detail')"

# ===========================================================================
printf '\n=== Section 6: full success — both units complete, aligned, coherent ===\n'
# ===========================================================================

record_completion "$CHILD2" "devops" "$(jq -nc --arg r ".claude/scripts/tests/dc-u2.test.sh" '
    {unit_id:"U2", green_before:"green", green_after:"green",
     files_changed:["src/b.sh", $r],
     tests_added:[($r+"::covers BC1")],
     criteria_tests:{"BC1":[($r+"::covers BC1")]}}
')"
seed_green_check "$CHILD2" "after" "green" "U2"
seed_review_and_enter "$CHILD2"
APPR2=$(bash "$QG" approve "$CHILD2" --no-design "DC: not the axis under test" "approve child2" 2>&1); APPR2_RC=$?
assert_eq "6.1 CHILD2 (U2) approves cleanly" "0" "$APPR2_RC"
assert_eq "6.1b ...status=approved" "approved" "$(json_field '.status' "$APPR2")"

OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "6.2 exit 0, fully coherent" "0" "$RC_A"
assert_eq "6.2b ok=true, coherence_count=0, issues=[]" "true|0|[]" \
    "$(json_field '.ok' "$OUT")|$(json_field '.coherence_count' "$OUT")|$(echo "$OUT" | jq -c '.issues')"
assert_eq "6.2c unit_task_map resolves both" "$CHILD1|$CHILD2" \
    "$(echo "$OUT" | jq -r '.unit_task_map.U1')|$(echo "$OUT" | jq -r '.unit_task_map.U2')"

# ===========================================================================
printf '\n=== Section 7: wiring into approve — COHERENCE-ROLLUP-REFUSAL (L2) ===\n'
# ===========================================================================
# Approve the EPIC itself now that it is coherent. review-record's OWN
# validator refuses an all-zero (empty-set) reviewed_hash as
# reviewed_hash_unusable (measured directly: an epic approve attempt with a
# genuinely empty tracker hit exactly this, unrelated to coherence) -- so
# re-touch a file a unit ALREADY DECLARED and a completion contract ALREADY
# CLAIMED (src/a.sh, U1/CHILD1's own), never an undeclared one: this
# exercises "the epic's own final review, over content the rollup already
# accounts for", not a fresh undeclared-scope/under-coverage case Sections
# 8/9 exist to test instead.
printf '# epic-level final check\n' >> "$FIXTURE/src/a.sh"
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
checkpoint_git
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
bash "$FIXTURE/.claude/scripts/impact-report.sh" "$EPIC" >/dev/null 2>&1 || true
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bd comments add "$EPIC" "IMPLEMENTER: role=devops task=$EPIC at $ts" >/dev/null 2>&1
record_completion "$EPIC" "devops" '{"files_changed":["src/a.sh"]}'
EHASH=$(bash "$FIXTURE/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
EART="$FIXTURE/.claude/.qa-tracking/review-artifact-$(printf '%s' "$EPIC" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"qa-claude","reviewer_model":"m","reviewer_pin":"m","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
    "$EPIC" "$EHASH" > "$EART"
bash "$QG" review-record "$EPIC" < "$EART" >/dev/null 2>&1
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
bash "$FIXTURE/.claude/scripts/impact-report.sh" "$EPIC" >/dev/null 2>&1 || true

# v5 D6's JUDGEMENT half (claude-workflow-plugin-fkm.8) added a SECOND,
# independent requirement for an epic-typed task's own approve:
# DESIGN-ROLLUP-REFUSAL (exit 5, design_rollup_missing), reached only once
# COHERENCE-ROLLUP-REFUSAL (this section's OWN axis, exit 2) has already
# NOT fired. This section predates that axis and never seeded a
# `DESIGN-ROLLUP v1` verdict, so 7.1 started failing at exit 5 the moment
# the judgement half's enforcement landed in cmd_approve -- MEASURED, not
# assumed, by the regression battery that ran after design-rollup.test.sh
# itself went green. Seeding a coherent verdict here restores what this
# CONTROL always meant to prove (a fully coherent epic-level design task
# approves), now correctly requiring both axes rather than the mechanical
# one alone.
printf '%s' "$SATISFIED_V1" | bash "$QG" design-rollup "$EPIC" --design-hash "$EPIC_HASH_V1" --model "claude-fable-5" >/dev/null 2>&1

EPIC_APPR=$(bash "$QG" approve "$EPIC" "coherent epic approval" 2>&1); EPIC_APPR_RC=$?
assert_eq "7.1 CONTROL: a fully coherent epic-level design task approves (no --no-design needed: IS itself a satisfied design task)" \
    "approved" "$(json_field '.status' "$EPIC_APPR")"
assert_eq "7.1b exit 0" "0" "$EPIC_APPR_RC"
assert_contains "7.1c approval comment carries design_artifact=<ref>@<hash> (plan 176)" \
    "design_artifact=${EPIC}@" "$(bd comments "$EPIC" --json 2>/dev/null | jq -r '.[].text' | grep 'QA-GATE APPROVED' | tail -1)"

# ===========================================================================
printf '\n=== Section 8: (c) undeclared_scope — a completion contract claims a file no unit declares ===\n'
# ===========================================================================

record_completion "$CHILD1" "devops" "$(jq -nc --arg r ".claude/scripts/tests/dc-u1.test.sh" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     files_changed:["src/a.sh", $r, "src/ROGUE.sh"],
     tests_added:[($r+"::covers AC1")],
     criteria_tests:{"AC1":[($r+"::covers AC1")]}}
')"
OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "8.1 exit 4" "4" "$RC_A"
assert_eq "8.1b an issue of kind undeclared_scope is present" "undeclared_scope" \
    "$(echo "$OUT" | jq -r '[.issues[] | select(.kind=="undeclared_scope")][0].kind')"
assert_contains "8.1c names the offending file" "src/ROGUE.sh" \
    "$(echo "$OUT" | jq -c '[.issues[] | select(.kind=="undeclared_scope")][0].files')"

# RESTORE CONTROL: CHILD1 back to its clean, declared-only claim.
record_completion "$CHILD1" "devops" "$(jq -nc --arg r ".claude/scripts/tests/dc-u1.test.sh" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     files_changed:["src/a.sh", $r],
     tests_added:[($r+"::covers AC1")],
     criteria_tests:{"AC1":[($r+"::covers AC1")]}}
')"
OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "8.2 RESTORE CONTROL: clean claim, coherent again" "0" "$RC_A"

# ===========================================================================
printf '\n=== Section 9: (e) tracker/diff mismatch — a genuinely untracked, unclaimed file ===\n'
# ===========================================================================
# Distinct from (c): here the file is NOT claimed by any completion payload
# at all -- it sits ONLY in the live tracker, exactly the 94d-shaped
# under-coverage case plan 177 exists for (a subagent edit / shell-written
# file the tracker sees but no completion contract ever mentions).

write_test_file "src/mystery.sh" "nobody claims me"
printf '%s\n' "$FIXTURE/src/mystery.sh" > "$TRACKING"
OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "9.1 exit 4" "4" "$RC_A"
assert_eq "9.1b an issue of kind tracker_diff_mismatch is present" "tracker_diff_mismatch" \
    "$(echo "$OUT" | jq -r '[.issues[] | select(.kind=="tracker_diff_mismatch")][0].kind')"
assert_contains "9.1c names the offending file" "src/mystery.sh" \
    "$(echo "$OUT" | jq -c '[.issues[] | select(.kind=="tracker_diff_mismatch")][0].files')"
assert_contains "9.1d distinct from undeclared_scope: NOT also reported under that kind" \
    "null" "$(echo "$OUT" | jq -r '[.issues[] | select(.kind=="undeclared_scope")][0] // null')"

# RESTORE CONTROL: remove the mystery file from disk and the tracker.
rm -f "$FIXTURE/src/mystery.sh"
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "9.2 RESTORE CONTROL: coherent again once the untracked file is gone" "0" "$RC_A"

# ===========================================================================
printf '\n=== Section 10: (d) hash divergence — design amended, a unit never rebound ===\n'
# ===========================================================================

ART="$FIXTURE/docs/specs/$EPIC.md"
printf -- '- v2 amended after the fact (design-coherence.test.sh).\n' >> "$ART"
printf '%s\n' "$ART" > "$TRACKING"
checkpoint_git
bash "$QG" enter "$EPIC" >/dev/null 2>&1
NEW_HASH=$(bash "$WM" hash-file "$ART")
assert_eq "10.0 the amendment actually moved the hash" "no" "$([ "$NEW_HASH" = "$EPIC_HASH_V1" ] && echo yes || echo no)"
printf '%s' "$SATISFIED_V2" | bash "$QG" design-review-record "$EPIC" --design-hash "$NEW_HASH" >/dev/null 2>&1

OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "10.1 exit 4" "4" "$RC_A"
assert_eq "10.1b BOTH units diverge (neither was rebound)" "hash_divergence|hash_divergence" \
    "$(echo "$OUT" | jq -r '[.issues[] | select(.unit_id=="U1")][0].kind')|$(echo "$OUT" | jq -r '[.issues[] | select(.unit_id=="U2")][0].kind')"
assert_contains "10.1c detail names both the stale and the current hash" "$NEW_HASH" \
    "$(echo "$OUT" | jq -r '[.issues[] | select(.unit_id=="U1")][0].detail')"

# CLEAR IT the amendment way (D2): re-bind both children to the amended hash.
bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC" --unit-id U1 --rebind "amendment rebind" >/dev/null 2>&1
bash "$QG" design-unit-bind "$CHILD2" --design-task "$EPIC" --unit-id U2 --rebind "amendment rebind" >/dev/null 2>&1
OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); RC_A=$?
assert_eq "10.2 RESTORE CONTROL: re-bound to the amended hash, coherent again" "0" "$RC_A"

# ===========================================================================
printf '\n=== Section 11: METatest — the coherence count is load-bearing ===\n'
# ===========================================================================
# "Stub the rollup to always return zero" (the brief's own words), in the
# most literal sense: strip ONLY the translation of coh_issues into
# DESIGN_COHERENCE_COUNT, leaving every individual condition check (LEG 1-3
# reuse, the scope-drift union, the hash-divergence loop, the tracker/diff
# comparison) completely untouched. If the suite stayed green with this
# stripped, the count itself -- the one thing cmd_approve's refusal ladder
# actually reads -- would be decorative.

record_completion "$CHILD1" "devops" "$(jq -nc --arg r ".claude/scripts/tests/dc-u1.test.sh" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     files_changed:["src/a.sh", $r, "src/ROGUE.sh"],
     tests_added:[($r+"::covers AC1")],
     criteria_tests:{"AC1":[($r+"::covers AC1")]}}
')"
META_QG="$FIXTURE/.claude/scripts/qa-gate-no-coherence-count.sh"
STRIP_RC=0
awk '
    /^    # COHERENCE-COUNT-ROLLUP BEGIN/ { skip = 1; found = 1; next }
    /^    # COHERENCE-COUNT-ROLLUP END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$META_QG" || STRIP_RC=$?
chmod +x "$META_QG" 2>/dev/null || true
assert_eq "11.1 META NON-VACUITY: the sentinels were found and the strip ran cleanly" "0" "$STRIP_RC"
SHIPPED_LINES=$(wc -l < "$QG" | tr -d '[:space:]')
STRIPPED_LINES=$(wc -l < "$META_QG" | tr -d '[:space:]')
assert_eq "11.1b ...the mutant copy is shorter than the shipped script" \
    "shorter" "$([ "$STRIPPED_LINES" -lt "$SHIPPED_LINES" ] && echo shorter || echo same-or-longer)"
BASH_N_RC=0
bash -n "$META_QG" 2>/dev/null || BASH_N_RC=$?
assert_eq "11.1c ...and the mutant still parses" "0" "$BASH_N_RC"

MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$META_QG" design-coherence "$EPIC" 2>&1); MUTANT_RC=$?
assert_eq "11.2 SPECIFIC MISBEHAVIOUR: without the count, the SAME undeclared_scope defect clears (ok=true)" \
    "true" "$(json_field '.ok' "$MUTANT_OUT")"
assert_eq "11.2b ...exit 0 on the mutant" "0" "$MUTANT_RC"
assert_eq "11.2c ...coherence_count=0 on the mutant despite a real, present defect" \
    "0" "$(json_field '.coherence_count' "$MUTANT_OUT")"
rm -f "$META_QG"

CTRL_OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1); CTRL_RC=$?
assert_eq "11.3 RESTORE CONTROL: the SAME defect against the SHIPPED script still refuses" "4" "$CTRL_RC"
assert_eq "11.3b ...naming undeclared_scope, not silently passing" "undeclared_scope" \
    "$(echo "$CTRL_OUT" | jq -r '[.issues[] | select(.kind=="undeclared_scope")][0].kind')"

# Leave CHILD1 clean for anyone re-running with --keep.
record_completion "$CHILD1" "devops" "$(jq -nc --arg r ".claude/scripts/tests/dc-u1.test.sh" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     files_changed:["src/a.sh", $r],
     tests_added:[($r+"::covers AC1")],
     criteria_tests:{"AC1":[($r+"::covers AC1")]}}
')"

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

#!/bin/bash
# design-rollup-incoherent.test.sh — split off design-rollup.test.sh's own
# former Section I (QA round 1, R1-F2, claude-workflow-plugin-fkm.8): the
# INCOHERENT-verdict scenario and the R1-F4 duplicate-hash-deadlock fix,
# both self-contained on their own epic (EPIC2) and needing nothing from
# design-rollup.test.sh's own Setup/Section A-H narrative on $EPIC.
#
# WHY A SEPARATE FILE, not just a separate section. QA measured design-
# rollup.test.sh (pre-split) at 806.83s and 823.17s standalone against
# run-tests.sh's own SPEC_TIMEOUT_S=900 -- both readings ABOVE the 800s
# split trigger run-tests.sh:999 already names, with headroom (1.093x)
# BELOW the 1.167x the comment there states as the tier's prior worst case.
# The natural seam is exactly this: EPIC2 (built here) shares no state with
# $EPIC (built by the other file's own Setup), so nothing here needs that
# file's own Setup-through-Section-H sequence to run first. Splitting here
# removes two full complete_unit cycles plus a design_and_review cycle from
# the ORIGINAL file's own standalone runtime, while this file's own content
# is short enough to sit comfortably under the cap on its own.
#
# WHAT THIS COVERS:
#
#   1. A genuinely INCOHERENT design-rollup verdict (needs_revision,
#      real criterion_results, real required_fixes) records CLEANLY (exit
#      0) -- design-rollup never refuses to record a truthful bad verdict,
#      only a forged or misbound one -- and translates to verdict=incoherent
#      with gaps=<required_fixes length> in the DESIGN-ROLLUP v1 grammar.
#      approve still refuses (exit 5, design_rollup_incoherent -- QA round 2,
#      R2-F3 corrected this header, which had named the wrong one of the
#      three distinct keys R1-F10 introduced; I.6b below has always
#      asserted the right one) on a RECORDED, CURRENT, but incoherent
#      rollup: coherent is a REQUIREMENT, not merely "a verdict exists".
#
#   2. R1-F4 (QA round 1, HIGH, the SUSTAINED half of the coordinator's own
#      split ruling on this finding): before this fix, design-rollup's own
#      hash-freshness check (--design-hash must equal the CURRENT governing
#      hash) plus its own duplicate-hash check (a second verdict at the
#      SAME design_hash was refused unconditionally) together admitted AT
#      MOST ONE VERDICT PER design_hash, EVER -- an incoherent verdict
#      LOCKED the governing task while that hash governed, with no escape
#      short of a design-document edit, even though the reviewer's own
#      gaps are ordinarily implementation-side and fixable without ever
#      touching the design text. Proven here as three states, not one, so
#      the fix reads as NARROW rather than a blanket removal of the
#      duplicate check: incoherent -> incoherent (still allowed, a genuine
#      re-judgement), incoherent -> coherent (allowed, the actual escape
#      this fix exists for), then coherent -> anything at the SAME hash
#      (still refused -- a coherent verdict remains a terminus at its own
#      design_hash; the companion finding's NOT-SUSTAINED half explicitly
#      treats a coherent verdict's own non-staleness against LATER change
#      sets as an accepted residual, not something to route around here).
#      NOT change-set-hash-bound: the coordinator's own explicit ruling
#      kept plan:721's grammar exactly as specified (no new field), so this
#      fix needs no persisted reference point at all -- only the PRIOR
#      record's own verdict.
#
# Needs a real bd fixture, real git, real qa-gate.sh/epic-gate.sh — same
# shape as design-rollup.test.sh's own fixture/helper conventions, copied
# verbatim below rather than sourced (this file's own header states no
# script here is sourceable, the same reason every helper duplicated
# elsewhere in this tier is duplicated rather than imported).
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
# Fixture. Same shape as design-rollup.test.sh: the real scripts, a real bd,
# a throwaway project root and HOME, and a real git repo.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t design-rollup-incoherent.XXXXXX)
TEST_HOME=$(mktemp -d -t design-rollup-incoherent-home.XXXXXX)

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
    echo "bd CLI not on PATH — design-rollup-incoherent tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — design-rollup-incoherent tests require jq."
    exit 2
fi
if ! command -v git >/dev/null 2>&1; then
    echo "git not on PATH — design-rollup-incoherent tests require a real git checkout."
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
TRACKING="$FIXTURE/.claude/.qa-tracking/changed-files.txt"

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }

seed_grilling() {
    bash "$QG" grilling-record "$1" --rounds 2 --questions 4 --approaches 2 --unresolved 0 \
        "design-rollup-incoherent.test.sh: seeding the grilling precondition" >/dev/null 2>&1
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

design_and_review() {
    local epic="$1" units="$2" verdict="${3:-$SATISFIED_V1}" art hash
    seed_grilling "$epic"
    art="$FIXTURE/docs/specs/$epic.md"
    write_artifact "$art" "$epic" "$units"
    printf '%s\n' "$art" > "$TRACKING"
    checkpoint_git
    bash "$QG" enter "$epic" >/dev/null 2>&1
    bash "$QG" design-record "$epic" >/dev/null 2>&1
    hash=$(bash "$WM" hash-file "$art")
    printf '%s' "$verdict" | bash "$QG" design-review-record "$epic" --design-hash "$hash" >/dev/null 2>&1
    printf '%s' "$hash"
}

seed_spec_injection() {
    local tid="$1" epic="$2" uid="$3"
    local art dhash ujson tmpf uhash ts
    art="$FIXTURE/docs/specs/$epic.md"
    dhash=$(bash "$WM" hash-file "$art")
    ujson=$(bash "$RC" design-unit-json "$art" "$uid" | jq -r '.unit_json')
    tmpf="$FIXTURE/.claude/.qa-tracking/.dr-si-tmp.json"
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
    bd comments add "$tid" "GREEN-CHECK v1 task=$tid unit_id=$uid phase=$phase result=$result exit_code=0 at $ts: suite $result (design-rollup-incoherent.test.sh seeded)" >/dev/null 2>&1
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

record_completion() {
    local tid="$1" role="$2" extra="$3"
    local out="$FIXTURE/.claude/.qa-tracking/.dr-completion-payload-$RANDOM$RANDOM.json"
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

seed_review_and_enter() {
    local tid="$1" reviewer="${2:-qa-claude}" role="${3:-devops}"
    local ts hash art
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1
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

# epic_review_and_complete <epic> <review-iteration-suffix> [<files...>] --
# the epic's OWN completion+review cycle, re-touching files ALREADY
# DECLARED by some unit (never an undeclared marker), reusing design-
# coherence.test.sh's own Section 7 technique verbatim. Only ever called
# ONCE per epic in this file (unlike the parent file, which must vary the
# file combination across successive calls on the SAME epic to dodge the
# idempotent-approve hash collision) -- EPIC2 here is approached only via
# design-rollup's own record path, never a second full epic-level approve,
# so that hazard does not arise in this file.
epic_review_and_complete() {
    local epic="$1" iter="$2"
    shift 2
    local files=("$@")
    [ "${#files[@]}" -gt 0 ] || files=("src/a.sh")
    local f=""
    local tracked=()
    for f in "${files[@]}"; do
        printf '# epic-level touch (%s)\n' "$iter" >> "$FIXTURE/$f"
        tracked+=("$FIXTURE/$f")
    done
    printf '%s\n' "${tracked[@]}" > "$TRACKING"
    checkpoint_git
    bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
    bash "$FIXTURE/.claude/scripts/impact-report.sh" "$epic" >/dev/null 2>&1 || true
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$epic" "IMPLEMENTER: role=devops task=$epic at $ts" >/dev/null 2>&1
    local files_json=""
    files_json=$(printf '%s\n' "${files[@]}" | jq -R . | jq -sc .)
    record_completion "$epic" "devops" "$(jq -nc --argjson f "$files_json" '{files_changed:$f}')"
    local ehash eart
    ehash=$(bash "$FIXTURE/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
    eart="$FIXTURE/.claude/.qa-tracking/review-artifact-$(printf '%s' "$epic" | tr -c 'A-Za-z0-9._-' '_')-r$iter.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"qa-claude","reviewer_model":"m","reviewer_pin":"m","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
        "$epic" "$ehash" > "$eart"
    bash "$QG" review-record "$epic" < "$eart" >/dev/null 2>&1
    bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
    bash "$FIXTURE/.claude/scripts/impact-report.sh" "$epic" >/dev/null 2>&1 || true
}

# EPIC2's own design fixture -- deliberately a2.sh/b2.sh/dr2-*.test.sh, not
# a.sh/b.sh/dr-*.test.sh, matching design-rollup.test.sh's own TWO_UNIT_B
# byte-for-byte (kept in step with that file so a reader comparing the two
# is not asked to reconcile a spurious difference).
TWO_UNIT_B='[
  {"unit_id":"U1","role":"devops","goal":"unit one",
   "acceptance":[{"id":"AC1","text":"criterion one"}],
   "files":["src/a2.sh",".claude/scripts/tests/dr2-u1.test.sh"],
   "verification":"make test","depends_on":[]},
  {"unit_id":"U2","role":"devops","goal":"unit two",
   "acceptance":[{"id":"BC1","text":"criterion b1"}],
   "files":["src/b2.sh",".claude/scripts/tests/dr2-u2.test.sh"],
   "verification":"make test","depends_on":[]}
]'

# complete_unit <child> <epic> <uid> <impl-file> <test-file> <ac-id> --
# drives ONE unit through spec-injection, a fully-aligned completion
# record, a GREEN-CHECK record, review+enter, and a clean per-unit approve.
complete_unit() {
    local child="$1" epic="$2" uid="$3" impl="$4" testf="$5" ac="$6"
    write_test_file "$impl" "unused"
    write_test_file "$testf" "covers $ac"
    printf '%s\n%s\n' "$FIXTURE/$impl" "$FIXTURE/$testf" > "$TRACKING"
    seed_spec_injection "$child" "$epic" "$uid"
    record_completion "$child" "devops" "$(jq -nc --arg r "$testf" --arg i "$impl" --arg uid "$uid" --arg ac "$ac" '
        {unit_id:$uid, green_before:"green", green_after:"green",
         files_changed:[$i, $r],
         tests_added:[($r+"::covers "+$ac)],
         criteria_tests:{($ac):[($r+"::covers "+$ac)]}}
    ')"
    seed_green_check "$child" "after" "green" "$uid"
    seed_review_and_enter "$child"
    local out rc
    out=$(bash "$QG" approve "$child" --no-design "DR: not the axis under test" "approve $uid" 2>&1); rc=$?
    printf '%s|%s' "$rc" "$(json_field '.status' "$out")"
    checkpoint_git
}

# RC/WM referenced by seed_spec_injection/design_and_review above --
# resolved here, alongside QG/TRACKING, matching design-rollup.test.sh's
# own placement (kept after the functions that reference them there too).
RC="$FIXTURE/.claude/scripts/review-check.sh"
WM="$FIXTURE/.claude/scripts/workflow-manifest.sh"

# ===========================================================================
printf '\n=== Section I: an INCOHERENT verdict — recorded, and still refused ===\n'
# ===========================================================================
# A separate epic (self-contained -- this file's own only epic): coherent
# mechanically, but the design-reviewer judges the whole-system criteria
# NOT satisfied.

EPIC2=$(bd create "DR epic 2 — incoherent path" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
HASH2=$(design_and_review "$EPIC2" "$TWO_UNIT_B")
C1B=$(bd create "DR2 child U1" -t task -p 1 --parent "$EPIC2" --json 2>/dev/null | jq -r '.id')
C2B=$(bd create "DR2 child U2" -t task -p 1 --parent "$EPIC2" --json 2>/dev/null | jq -r '.id')
bash "$QG" design-unit-bind "$C1B" --design-task "$EPIC2" --unit-id U1 "bound" >/dev/null 2>&1
bash "$QG" design-unit-bind "$C2B" --design-task "$EPIC2" --unit-id U2 "bound" >/dev/null 2>&1
R1B=$(complete_unit "$C1B" "$EPIC2" "U1" "src/a2.sh" ".claude/scripts/tests/dr2-u1.test.sh" "AC1")
assert_eq "I.1 EPIC2 CHILD1 approves cleanly (setup)" "0|approved" "$R1B"
R2B=$(complete_unit "$C2B" "$EPIC2" "U2" "src/b2.sh" ".claude/scripts/tests/dr2-u2.test.sh" "BC1")
assert_eq "I.2 EPIC2 CHILD2 approves cleanly (setup)" "0|approved" "$R2B"

NEEDS_REVISION='{"verdict":"needs_revision","criterion_results":[{"criterion":"DS1","pass":false,"justification":"AC1 restates the goal, not falsifiable once built"},{"criterion":"DS2","pass":true,"justification":"ok"}],"required_fixes":["Rewrite U1 AC1 to name a checkable artefact"],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'
OUT=$(printf '%s' "$NEEDS_REVISION" | bash "$QG" design-rollup "$EPIC2" --design-hash "$HASH2" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "I.3 a genuinely needs_revision verdict still records cleanly: exit 0" "0" "$RC_A"
LATEST2=$(bd comments "$EPIC2" --json 2>/dev/null | jq -r '[.[].text | select(startswith("DESIGN-ROLLUP v1 "))] | last')
assert_contains "I.4 record translates needs_revision -> verdict=incoherent" "verdict=incoherent" "$LATEST2"
assert_contains "I.5 record translates required_fixes length -> gaps=1" "gaps=1" "$LATEST2"

# epic_review_and_complete's own default file ("src/a.sh") belongs to a
# DIFFERENT epic in design-rollup.test.sh's own Setup, not to EPIC2's own
# design here -- EPIC2 was built from TWO_UNIT_B, which declares
# src/a2.sh/src/b2.sh instead. Touching and tracking src/a.sh here would
# put a file NOTHING in EPIC2's own design declares into EPIC2's own live
# diff, which is exactly the under-coverage shape tracker_diff_mismatch
# exists to catch -- MEASURED, not assumed, before this explicit argument
# was added (in the pre-split file, back when both epics shared one
# fixture): the default produced exactly that (I.6/I.6b got
# coherence_issues_open instead of the expected design_rollup_missing).
# Naming one of EPIC2's own declared files here keeps this section's own
# git activity inside the design it actually belongs to.
epic_review_and_complete "$EPIC2" "1" "src/a2.sh"
OUT=$(bash "$QG" approve "$EPIC2" "attempt with a recorded but incoherent rollup" 2>&1); RC_A=$?
assert_eq "I.6 a RECORDED, CURRENT, but incoherent rollup still refuses approve: exit 5" "5" "$RC_A"
assert_eq "I.6b error_key=design_rollup_incoherent (QA round 1, R1-F10: distinct from the never-recorded/stale shapes)" "design_rollup_incoherent" "$(json_field '.error_key' "$OUT")"

# R1-F4 fix (QA round 1, HIGH, SUSTAINED half of a split ruling): before
# this fix, :15856/:16048 together admitted AT MOST ONE VERDICT PER
# design_hash, EVER -- I.3's own incoherent verdict against $HASH2 would
# have LOCKED EPIC2 permanently while that hash governs, with no escape
# short of an artifact edit, even though the reviewer's own gaps
# (required_fixes) are ordinarily implementation-side and fixable without
# touching the design document at all. Proven here as three states, not
# one, so the fix is shown NARROW rather than a blanket removal of the
# duplicate check: incoherent -> incoherent (still allowed, a genuine
# re-judgement of unchanged-verdict work), incoherent -> coherent (allowed,
# the actual escape this fix exists for), then coherent -> anything at the
# SAME hash (still refused -- a coherent verdict remains a terminus at its
# own design_hash, exactly as the coordinator's own NOT-SUSTAINED ruling on
# the companion finding treats a coherent verdict's non-staleness as an
# accepted residual, not a defect to route around here too).
OUT=$(printf '%s' "$NEEDS_REVISION" | bash "$QG" design-rollup "$EPIC2" --design-hash "$HASH2" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "I.7 R1-F4 FIX: a SECOND verdict at the SAME design_hash is now allowed when the PRIOR one was incoherent: exit 0" "0" "$RC_A"
LATEST2B=$(bd comments "$EPIC2" --json 2>/dev/null | jq -r '[.[].text | select(startswith("DESIGN-ROLLUP v1 "))] | length')
assert_eq "I.7b ...and it is a genuine SECOND record, not a rewrite of the first (2 DESIGN-ROLLUP v1 comments now exist)" "2" "$LATEST2B"

OUT=$(printf '%s' "$SATISFIED_V1" | bash "$QG" design-rollup "$EPIC2" --design-hash "$HASH2" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "I.8 the escape this fix exists for: incoherent -> coherent at the SAME hash, no artifact amendment needed: exit 0" "0" "$RC_A"
assert_eq "I.8b status=recorded" "recorded" "$(json_field '.status' "$OUT")"

OUT=$(printf '%s' "$NEEDS_REVISION" | bash "$QG" design-rollup "$EPIC2" --design-hash "$HASH2" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "I.9 RESTORE CONTROL: once the LATEST verdict at this hash is coherent, a further record at the SAME hash is refused again -- the fix did not remove the duplicate check, only narrowed it: exit 1" "1" "$RC_A"
assert_eq "I.9b error_key=design_rollup_duplicate_hash" "design_rollup_duplicate_hash" "$(json_field '.error_key' "$OUT")"

# ===========================================================================
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

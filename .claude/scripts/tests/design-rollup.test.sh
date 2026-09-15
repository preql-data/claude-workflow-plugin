#!/bin/bash
# design-rollup.test.sh — v5 D6 JUDGEMENT HALF (claude-workflow-plugin-fkm.8,
# coordinator ruling 2026-09-14): the LLM-judgement surfaces plan:718-737
# names on top of the mechanical rollup design-coherence.test.sh already
# covers — a second, cheaper `design-reviewer` spawn scoped to DS1/DS2/DS8,
# relayed root-orchestrated exactly like the rubric grader and the first
# design review (subagents cannot spawn subagents), recorded as
# `DESIGN-ROLLUP v1`, and enforced on the two surfaces the plan names:
# `epic-gate.sh cmd_check`'s own block branch, and `qa-gate.sh approve`'s
# exit-5 `design_rollup_missing` refusal.
#
# SPLIT (QA round 1, R1-F2, HIGH): the former Section I (an INCOHERENT
# verdict recorded and still refused, plus the R1-F4 duplicate-hash-
# deadlock fix) moved to design-rollup-incoherent.test.sh -- it was
# self-contained on its own epic and needed nothing from this file's own
# Setup-through-Section-H narrative, so splitting it out brought this
# file's own standalone runtime back under comfortable headroom on the
# 800s split trigger run-tests.sh already names (measured pre-split at
# 806.83s/823.17s against SPEC_TIMEOUT_S=900). See that file's own header
# for the incoherent-verdict scope it carried with it.
#
# ALSO CARRIES three fixes from that same QA round, all covered below:
# R1-F1 (CRITICAL) -- reviewer_identity is no longer trusted past an
# emptiness check before being interpolated into the DESIGN-ROLLUP v1
# record (Section C); R1-F3 (HIGH) -- the packet's own union diff is now
# HEAD-vs-working-tree (the change set the gate actually binds), not a
# branch-vs-main comparison that was simultaneously too wide and blind to
# uncommitted work (Section B).
#
# WHAT THIS COVERS, and why each part needs a test of its own:
#
#   1. `design-rollup-packet <epic-id>` — refuses (exit 2,
#      design_rollup_mechanical_prerequisite) while the MECHANICAL rollup
#      still has issues open, with a restore control once it is clean:
#      the judgement half is "cheaper" precisely because it never re-checks
#      what the mechanical half already discharged, so asking for a packet
#      before that half is settled would spend a spawn on data about to
#      change. On success, the packet's four sections (plan:718-737's own
#      words) are all present and both units are named in it.
#
#   2. `design-rollup <epic-id> --design-hash <h> --model <m> [--file <p>]`
#      — reuses design-review-record's OWN six-key JSON validation ladder
#      verbatim (not re-tested exhaustively here — that ladder's failure
#      modes are already proven 200+ times over in design-review-
#      record.test.sh; this file tests only what is NEW): a required
#      --model flag (transport metadata, the SAME 46w9 split every other
#      model-bearing record already uses); a fresh mechanical TOCTOU
#      re-check refusing a verdict recorded against a since-reopened
#      mechanical rollup; a hash-freshness check refusing a verdict whose
#      --design-hash no longer matches the CURRENT governing hash; a
#      duplicate-hash refusal (a second verdict against the SAME hash);
#      the independence check (reviewer_identity == designer, reused
#      verbatim from design-review-record); and the satisfied/needs_
#      revision -> coherent/incoherent, required_fixes -> gaps translation
#      that produces the exact `DESIGN-ROLLUP v1 reviewer=<id> model=<m>
#      design_hash=<h> units=<n>/<n> verdict=<coherent|incoherent>
#      gaps=<n> at <ts>: <summary>` grammar plan:718-737 specifies.
#
#   3. `design-rollup-status <epic-id>` — the READ-ONLY accessor epic-
#      gate.sh's own cmd_check shells out to: {applicable, mechanical_ok,
#      rollup_recorded, rollup_coherent, rollup_hash_fresh}, each state
#      reached a different way (never recorded; recorded-but-stale after
#      an amendment; recorded-and-current).
#
#   4. `epic-gate.sh cmd_check` — the NEW branch inside "all children
#      approved": `block` when the epic's own design axis is applicable
#      but not (mechanically clean AND judged coherent AND current), with
#      a restore control proving the ORIGINAL "pass" text is unchanged for
#      a task with no design phase at all (never touched by this change).
#      A REENTRANCY test is included directly: epic-gate.sh's own new
#      shell-out to qa-gate.sh calls BACK INTO compute_design_coherence,
#      which itself shells out to epic-gate.sh check for child enumeration
#      — MEASURED live while building this fix as a genuine unbounded
#      subprocess chain before the reentrancy guard existed. This file
#      proves the guarded call terminates and is not merely "usually
#      fast enough" by bounding the real wall-clock elapsed.
#
#   5. `qa-gate.sh approve` — DESIGN-ROLLUP-REFUSAL, exit 5,
#      design_rollup_missing: refuses when no rollup was ever recorded, and
#      when the recorded one is stale (an amendment landed since); succeeds
#      once a current, coherent rollup exists. The "current but incoherent
#      still refuses" case moved to design-rollup-incoherent.test.sh
#      alongside the former Section I. Proven DISTINCT from COHERENCE-
#      ROLLUP-REFUSAL's own exit 2: reopening a MECHANICAL issue after a
#      genuinely coherent rollup was already recorded still refuses at
#      exit 2, never silently accepted because a "coherent" record exists.
#
#   6. METatest (the coordinator's own explicit instruction): "stub the
#      reviewer verdict to always return coherent and assert the gate
#      still refuses when it should, or the LLM leg is decorative." Built
#      as a sentinel-strip over the hash-freshness comparison inside
#      DESIGN-ROLLUP-REFUSAL: a GENUINELY coherent verdict (not a forged
#      one — the reviewer really did say coherent) recorded against a
#      SUPERSEDED hash must still refuse, because the verdict's semantic
#      content was never what makes this axis trustworthy — the BINDING
#      to the current artifact state is. Without the freshness check, the
#      exact same stale-but-coherent record wrongly clears the gate.
#
# Needs a real bd fixture, real git, real qa-gate.sh/epic-gate.sh — same
# shape as design-coherence.test.sh, reusing its own fixture/helper
# conventions verbatim.
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

assert_ne() {
    local name="$1" not_expected="$2" actual="$3"
    if [ "$not_expected" != "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    not-expected: %s\n    actual:       %s\n' "$name" "$not_expected" "$actual"
    fi
}

# ---------------------------------------------------------------------------
# Fixture. Same shape as design-coherence.test.sh: the real scripts, a real
# bd, a throwaway project root and HOME, and a real git repo.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t design-rollup.XXXXXX)
TEST_HOME=$(mktemp -d -t design-rollup-home.XXXXXX)

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
    echo "bd CLI not on PATH — design-rollup tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — design-rollup tests require jq."
    exit 2
fi
if ! command -v git >/dev/null 2>&1; then
    echo "git not on PATH — design-rollup tests require a real git checkout."
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
EG="$FIXTURE/.claude/scripts/epic-gate.sh"
RC="$FIXTURE/.claude/scripts/review-check.sh"
WM="$FIXTURE/.claude/scripts/workflow-manifest.sh"
TRACKING="$FIXTURE/.claude/.qa-tracking/changed-files.txt"

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }

seed_grilling() {
    bash "$QG" grilling-record "$1" --rounds 2 --questions 4 --approaches 2 --unresolved 0 \
        "design-rollup.test.sh: seeding the grilling precondition" >/dev/null 2>&1
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
# design-review-record's own iteration-advance check refuses a SECOND
# record at an iteration <= the latest already recorded for the SAME task
# (design_review_iteration_not_advancing) -- reusing SATISFIED_V2 (iteration
# 2) verbatim for a THIRD design-review-record call on the SAME $EPIC
# (Section K, after Section H already recorded iteration 2 against HASH_V2)
# is refused silently by that check, since the call is piped to
# >/dev/null 2>&1. MEASURED, not assumed: this was the actual root cause of
# K's own design_verdict_stale failures, found via a live debug capture of
# design-status showing compute_design_satisfied still reading H's OWN
# HASH_V2 record as latest, long after Section K believed it had recorded a
# fresh HASH_V3 one. SATISFIED_V3 exists so Section K's own second amendment
# advances the iteration count, exactly as a real second amendment round
# would.
SATISFIED_V3='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":3,"rubric_version":"1","reviewer_identity":"design-claude"}'

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
    bd comments add "$tid" "GREEN-CHECK v1 task=$tid unit_id=$uid phase=$phase result=$result exit_code=0 at $ts: suite $result (design-rollup.test.sh seeded)" >/dev/null 2>&1
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
# coherence.test.sh's own Section 7 technique verbatim. <files...> DEFAULTS
# to src/a.sh alone but MUST be varied across consecutive calls on the SAME
# epic (this is why every call site below names an explicit combination):
# change_set_hash is a hash of the PATH LIST alone, never content, so two
# calls touching the IDENTICAL file set produce the IDENTICAL hash — and a
# SECOND approve attempt whose hash matches ANY prior QA-GATE APPROVED
# record on this task (not only the latest one — gz3's own "one hash per
# record, checked against all of them") is routed through the IDEMPOTENT-
# APPROVE-CONFLICT-RECHECK arm, which does NOT carry COHERENCE-ROLLUP-
# REFUSAL or DESIGN-ROLLUP-REFUSAL at all (both are main-ladder-only,
# exactly like DESIGN-ALIGNMENT-REFUSAL). Reusing a file combination this
# task has already been approved under would make a later section's
# assertions pass for the WRONG reason (an unrelated idempotent fast path)
# rather than because the axis under test actually ran.
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

TWO_UNIT='[
  {"unit_id":"U1","role":"devops","goal":"unit one",
   "acceptance":[{"id":"AC1","text":"criterion one"}],
   "files":["src/a.sh",".claude/scripts/tests/dr-u1.test.sh"],
   "verification":"make test","depends_on":[]},
  {"unit_id":"U2","role":"devops","goal":"unit two",
   "acceptance":[{"id":"BC1","text":"criterion b1"}],
   "files":["src/b.sh",".claude/scripts/tests/dr-u2.test.sh"],
   "verification":"make test","depends_on":[]}
]'

# TWO_UNIT_B (EPIC2's own design fixture) moved to design-rollup-
# incoherent.test.sh alongside the former Section I (QA round 1, R1-F2) --
# nothing in this file references EPIC2 anymore.

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

# ===========================================================================
printf '\n=== Setup: one epic, two units, both mechanically complete ===\n'
# ===========================================================================

EPIC=$(bd create "DR epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
HASH_V1=$(design_and_review "$EPIC" "$TWO_UNIT")
CHILD1=$(bd create "DR child U1" -t task -p 1 --parent "$EPIC" --json 2>/dev/null | jq -r '.id')
CHILD2=$(bd create "DR child U2" -t task -p 1 --parent "$EPIC" --json 2>/dev/null | jq -r '.id')
bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC" --unit-id U1 "bound to U1" >/dev/null 2>&1
bash "$QG" design-unit-bind "$CHILD2" --design-task "$EPIC" --unit-id U2 "bound to U2" >/dev/null 2>&1

# ===========================================================================
printf '\n=== Section A: design-rollup-packet — NOT APPLICABLE / mechanical prerequisite ===\n'
# ===========================================================================

FRESH=$(bd create "DR: never a design task" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" design-rollup-packet "$FRESH" 2>&1); RC_A=$?
assert_eq "A.1 not applicable: exit 2" "2" "$RC_A"
assert_eq "A.1b error_key names it, packet_path empty" "design_rollup_not_applicable|" \
    "$(json_field '.error_key' "$OUT")|$(json_field '.packet_path' "$OUT")"

R1=$(complete_unit "$CHILD1" "$EPIC" "U1" "src/a.sh" ".claude/scripts/tests/dr-u1.test.sh" "AC1")
assert_eq "A.2 CHILD1 (U1) approves cleanly" "0|approved" "$R1"

OUT=$(bash "$QG" design-rollup-packet "$EPIC" 2>&1); RC_A=$?
assert_eq "A.3 U2 still unresolved: mechanical prerequisite refuses, exit 2" "2" "$RC_A"
assert_eq "A.3b error_key=design_rollup_mechanical_prerequisite" "design_rollup_mechanical_prerequisite" \
    "$(json_field '.error_key' "$OUT")"
assert_eq "A.3c packet_path empty on refusal" "" "$(json_field '.packet_path' "$OUT")"

R2=$(complete_unit "$CHILD2" "$EPIC" "U2" "src/b.sh" ".claude/scripts/tests/dr-u2.test.sh" "BC1")
assert_eq "A.4 CHILD2 (U2) approves cleanly (RESTORE CONTROL precondition)" "0|approved" "$R2"

OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1)
assert_eq "A.5 mechanical rollup now clean (precondition for the restore control)" "true|0" \
    "$(json_field '.ok' "$OUT")|$(json_field '.coherence_count' "$OUT")"

# ===========================================================================
printf '\n=== Section B: design-rollup-packet — RESTORE CONTROL, assembles cleanly ===\n'
# ===========================================================================

PKT_OUT=$(bash "$QG" design-rollup-packet "$EPIC" 2>&1); PKT_RC=$?
assert_eq "B.1 mechanical clean: packet assembly succeeds, exit 0" "0" "$PKT_RC"
assert_eq "B.1b ok=true, unit_count=2, design_hash matches" "true|2|$HASH_V1" \
    "$(json_field '.ok' "$PKT_OUT")|$(json_field '.unit_count' "$PKT_OUT")|$(json_field '.design_hash' "$PKT_OUT")"
PKT_PATH=$(json_field '.packet_path' "$PKT_OUT")
assert_eq "B.2 the packet file actually exists on disk" "yes" "$([ -f "$PKT_PATH" ] && echo yes || echo no)"
PKT_CONTENT=$(cat -- "$PKT_PATH" 2>/dev/null || echo "")
assert_eq "B.3 all FOUR packet sections are present" "4" \
    "$(printf '%s' "$PKT_CONTENT" | grep -c '^### ')"
assert_contains "B.4 section 1 names the design artifact" "docs/specs/$EPIC.md" "$PKT_CONTENT"
assert_contains "B.5 section 2 names CHILD1's own completion contract" "\"task_id\": \"$CHILD1\"" "$PKT_CONTENT"
assert_contains "B.6 section 2 names CHILD2's own completion contract" "\"task_id\": \"$CHILD2\"" "$PKT_CONTENT"
assert_contains "B.7 section 4 lists the DESIGN-REVIEW history" "DESIGN-REVIEW v1" "$PKT_CONTENT"

# R1-F3 fix (QA round 1, HIGH): the union diff must reflect the ACTUAL
# change set the gate binds -- HEAD vs the working tree -- never a
# branch-vs-main comparison, which is BLIND to anything not yet committed.
# Every earlier scenario in this file checkpoints (commits) after every
# write, so the fixture's own git tree is otherwise always clean by
# packet-assembly time -- a fixture where the diff is empty by
# construction can never catch this class (the coordinator's own explicit
# instruction on this finding). Deliberately leave src/a.sh with an
# UNCOMMITTED modification here, assemble a fresh packet, and assert the
# diff section shows the REAL, uncommitted content -- something a
# base...HEAD comparison against committed history could never show,
# since nothing new has been committed at all.
printf '# UNCOMMITTED at packet-assembly time (B.8)\n' >> "$FIXTURE/src/a.sh"
PKT_OUT2=$(bash "$QG" design-rollup-packet "$EPIC" 2>&1); PKT_RC2=$?
assert_eq "B.8 packet assembly still succeeds with an uncommitted change present" "0" "$PKT_RC2"
PKT_PATH2=$(json_field '.packet_path' "$PKT_OUT2")
PKT_CONTENT2=$(cat -- "$PKT_PATH2" 2>/dev/null || echo "")
assert_contains "B.9 R1-F3 FIX: the union diff section shows the UNCOMMITTED content itself, not just a path list -- proves this is HEAD-vs-working-tree, not a branch comparison against committed history" \
    "+# UNCOMMITTED at packet-assembly time (B.8)" "$PKT_CONTENT2"
assert_contains "B.9b ...labeled against HEAD vs working tree, not a branch merge-base" \
    "Base: HEAD vs working tree" "$PKT_CONTENT2"
# Fold the uncommitted change into history so later sections' own
# git/tracker assumptions (a clean tree between scenarios) are undisturbed.
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
checkpoint_git
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true

# ===========================================================================
printf '\n=== Section C: design-rollup (record) — malformed input, reused ladder ===\n'
# ===========================================================================

OUT=$(printf '%s' "$SATISFIED_V1" | bash "$QG" design-rollup "$EPIC" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "C.1 missing --design-hash: exit 1" "1" "$RC_A"
assert_eq "C.1b error_key=missing_design_hash" "missing_design_hash" "$(json_field '.error_key' "$OUT")"

OUT=$(printf '%s' "$SATISFIED_V1" | bash "$QG" design-rollup "$EPIC" --design-hash "$HASH_V1" 2>&1); RC_A=$?
assert_eq "C.2 missing --model: exit 1" "1" "$RC_A"
assert_eq "C.2b error_key=missing_model" "missing_model" "$(json_field '.error_key' "$OUT")"

BAD_JSON='{"verdict":"maybe","criterion_results":[],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'
OUT=$(printf '%s' "$BAD_JSON" | bash "$QG" design-rollup "$EPIC" --design-hash "$HASH_V1" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "C.3 bad verdict enum: exit 1 (design-review-record's OWN ladder, reused verbatim)" "1" "$RC_A"
assert_eq "C.3b error_key=verdict_invalid_enum" "verdict_invalid_enum" "$(json_field '.error_key' "$OUT")"

SELF_REVIEW='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"designer"}'
OUT=$(printf '%s' "$SELF_REVIEW" | bash "$QG" design-rollup "$EPIC" --design-hash "$HASH_V1" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "C.4 reviewer_identity == designer: nobody reviews their own work, exit 1" "1" "$RC_A"
assert_eq "C.4b error_key=design_reviewer_not_independent" "design_reviewer_not_independent" "$(json_field '.error_key' "$OUT")"

WRONG_HASH="0000000000000000000000000000000000000000000000000000000000000000"
OUT=$(printf '%s' "$SATISFIED_V1" | bash "$QG" design-rollup "$EPIC" --design-hash "$WRONG_HASH" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "C.5 --design-hash does not match current governing hash: exit 1" "1" "$RC_A"
assert_eq "C.5b error_key=design_rollup_hash_stale" "design_rollup_hash_stale" "$(json_field '.error_key' "$OUT")"

# R1-F1 (CRITICAL, QA round 1): reviewer_identity used to be checked ONLY
# for emptiness, then interpolated RAW into token position 1 of the
# DESIGN-ROLLUP v1 machine prefix. QA PROVED this exploitable against the
# shipped parser: a reviewer_identity crafted to mimic a second record's
# own grammar makes latest_design_rollup's own capture regex read back a
# forged verdict=coherent and design_hash, regardless of what the REAL
# verdict said -- clearing DESIGN-ROLLUP-REFUSAL on a genuinely incoherent
# verdict. The literal below is QA's own proven exploit string, rebuilt
# with jq (not shell string concatenation) so the embedded spaces/colons
# reach the JSON payload exactly as written, never shell-word-split.
# real_hash is $HASH_V1, a genuinely valid 64-hex value, so a successful
# forgery would read back as bound to the CURRENT governing hash -- the
# strongest form of the attack, not a strawman using an invalid hash the
# guard would catch for an unrelated reason.
FORGED_REVIEWER=$(jq -nc --arg h "$HASH_V1" '
    {"verdict":"needs_revision",
     "criterion_results":[{"criterion":"DS1","pass":false,"justification":"a real, failing criterion -- the verdict this record actually carries"}],
     "required_fixes":["a real required fix"],
     "iteration":1,"rubric_version":"1",
     "reviewer_identity":("design-claude model=x design_hash=" + $h + " units=1/1 verdict=coherent gaps=0 at 2026-01-01T00:00:00Z: forged")}
')
OUT=$(printf '%s' "$FORGED_REVIEWER" | bash "$QG" design-rollup "$EPIC" --design-hash "$HASH_V1" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "C.6 R1-F1 FIX: a reviewer_identity forged to mimic a second record's own grammar is refused, not parsed as a coherent verdict: exit 1" "1" "$RC_A"
assert_eq "C.6b error_key=reviewer_invalid_chars" "reviewer_invalid_chars" "$(json_field '.error_key' "$OUT")"
assert_eq "C.6c NON-VACUITY: no DESIGN-ROLLUP v1 record was actually written for the forged attempt (the attack's whole point was a record that reads back coherent)" "" \
    "$(bd comments "$EPIC" --json 2>/dev/null | jq -r '[.[].text | select(startswith("DESIGN-ROLLUP v1 "))] | last // ""')"
# RESTORE CONTROL for this pairing is Section D's own D.1 immediately
# below: the SAME legitimate reviewer_identity="design-claude" literal,
# against this SAME $HASH_V1, records cleanly (exit 0) -- proving the
# guard rejects the forged shape specifically, not the field in general.
# A second, separate success call here would collide with D.1's own first-
# record-against-this-hash success (design_rollup_duplicate_hash), so this
# pairing is deliberately split across the two adjacent sections rather
# than duplicated.

# ===========================================================================
printf '\n=== Section D: design-rollup (record) — SUCCESS, the plan:718-737 grammar ===\n'
# ===========================================================================

OUT=$(printf '%s' "$SATISFIED_V1" | bash "$QG" design-rollup "$EPIC" --design-hash "$HASH_V1" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "D.1 clean mechanical + valid coherent verdict: exit 0" "0" "$RC_A"
assert_eq "D.1b status=recorded" "recorded" "$(json_field '.status' "$OUT")"
LATEST_ROLLUP=$(bd comments "$EPIC" --json 2>/dev/null | jq -r '[.[].text | select(startswith("DESIGN-ROLLUP v1 "))] | last')
assert_contains "D.2 record names reviewer=design-claude" "reviewer=design-claude" "$LATEST_ROLLUP"
assert_contains "D.3 record names model=claude-fable-5" "model=claude-fable-5" "$LATEST_ROLLUP"
assert_contains "D.4 record names design_hash=<the artifact's own hash>" "design_hash=$HASH_V1" "$LATEST_ROLLUP"
assert_contains "D.5 record names units=2/2" "units=2/2" "$LATEST_ROLLUP"
assert_contains "D.6 record names verdict=coherent" "verdict=coherent" "$LATEST_ROLLUP"
assert_contains "D.7 record names gaps=0" "gaps=0" "$LATEST_ROLLUP"

OUT=$(printf '%s' "$SATISFIED_V1" | bash "$QG" design-rollup "$EPIC" --design-hash "$HASH_V1" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "D.8 a SECOND verdict against the SAME hash is a duplicate: exit 1" "1" "$RC_A"
assert_eq "D.8b error_key=design_rollup_duplicate_hash" "design_rollup_duplicate_hash" "$(json_field '.error_key' "$OUT")"

# ===========================================================================
printf '\n=== Section E: design-rollup-status — reflects the recorded, current state ===\n'
# ===========================================================================

OUT=$(bash "$QG" design-rollup-status "$EPIC" 2>&1); RC_A=$?
assert_eq "E.1 exit 0 (everything true)" "0" "$RC_A"
assert_eq "E.1b applicable, mechanical_ok, recorded, coherent, fresh — all true" "true|true|true|true|true" \
    "$(json_field '.applicable' "$OUT")|$(json_field '.mechanical_ok' "$OUT")|$(json_field '.rollup_recorded' "$OUT")|$(json_field '.rollup_coherent' "$OUT")|$(json_field '.rollup_hash_fresh' "$OUT")"

OUT=$(bash "$QG" design-rollup-status "$FRESH" 2>&1); RC_A=$?
assert_eq "E.2 NEGATIVE CONTROL: a non-design task reads not-applicable, exit 0" "0" "$RC_A"
assert_eq "E.2b applicable=false" "false" "$(json_field '.applicable' "$OUT")"

# ===========================================================================
printf '\n=== Section F: epic-gate.sh check — the NEW block branch, and its restore control ===\n'
# ===========================================================================

CHECK_OUT=$(bash "$EG" check "$EPIC" 2>&1)
assert_eq "F.1 all children approved AND rollup coherent+fresh: decision=pass" "pass" "$(json_field '.decision' "$CHECK_OUT")"

# NEGATIVE CONTROL, proven by construction rather than assumed: a task with
# NO design phase at all must see the ORIGINAL, unmodified pass text — this
# change must be provably inert for the ordinary (non-design) epic-gate
# caller.
PLAIN_EPIC=$(bd create "DR: plain epic, no design" -t task -p 1 --json 2>/dev/null | jq -r '.id')
PLAIN_CHILD=$(bd create "DR: plain child" -t task -p 1 --parent "$PLAIN_EPIC" --json 2>/dev/null | jq -r '.id')
bd update "$PLAIN_CHILD" --status closed >/dev/null 2>&1
bd label add "$PLAIN_CHILD" qa-approved >/dev/null 2>&1
PLAIN_CHECK=$(bash "$EG" check "$PLAIN_EPIC" 2>&1)
assert_eq "F.2 NEGATIVE CONTROL: a non-design epic's pass text is UNCHANGED" \
    "All 1 sub-task(s) qa-approved under epic $PLAIN_EPIC; epic can close." \
    "$(json_field '.observations' "$PLAIN_CHECK")"

# REENTRANCY: epic-gate.sh check -> qa-gate.sh design-rollup-status ->
# compute_design_coherence -> epic-gate.sh check (for child enumeration).
# MEASURED (not assumed) to terminate: this call itself IS the proof --
# if the reentrancy guard regressed, this line would hang the whole suite
# rather than report a clean pass/fail, so the fact that F.1/F.2 above
# printed at all is already evidence; this assertion additionally bounds
# the wall-clock cost so a REGRESSION TO THE WASTEFUL (but bounded) shape
# — the reentrancy guard alone, without the complementary skip-rollup-
# check guard — is visible as a timing regression rather than silently
# passing.
REENTRANCY_START=$(date +%s)
bash "$EG" check "$EPIC" >/dev/null 2>&1
REENTRANCY_ELAPSED=$(( $(date +%s) - REENTRANCY_START ))
assert_eq "F.3 epic-gate.sh check terminates well inside a sane bound (reentrancy fix holds)" "yes" \
    "$([ "$REENTRANCY_ELAPSED" -lt 30 ] && echo yes || echo "no(${REENTRANCY_ELAPSED}s)")"

# ===========================================================================
printf '\n=== Section G: qa-gate.sh approve — DESIGN-ROLLUP-REFUSAL, exit 5 ===\n'
# ===========================================================================

epic_review_and_complete "$EPIC" "1" "src/a.sh"
EPIC_APPR=$(bash "$QG" approve "$EPIC" "epic approval, rollup coherent+fresh" 2>&1); EPIC_APPR_RC=$?
assert_eq "G.1 coherent, current rollup: approve succeeds" "approved" "$(json_field '.status' "$EPIC_APPR")"
assert_eq "G.1b exit 0" "0" "$EPIC_APPR_RC"

# ===========================================================================
printf '\n=== Section H: an AMENDMENT stales the recorded rollup ===\n'
# ===========================================================================
# Amend the artifact (a fresh Revision log row, a moved design_hash) and
# record a FRESH satisfied DESIGN-REVIEW (iteration 2) against it, without
# yet recording a NEW design-rollup verdict. The rollup axis must now read
# stale, distinctly from "never recorded" (Section A/D's own states).

ART="$FIXTURE/docs/specs/$EPIC.md"
{
    cat "$ART"
    printf -- '- v2 amended: no functional change, exercising the rollup staleness path.\n'
} > "$ART.new"
mv "$ART.new" "$ART"
printf '%s\n' "$ART" > "$TRACKING"
checkpoint_git
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
bash "$FIXTURE/.claude/scripts/impact-report.sh" "$EPIC" >/dev/null 2>&1 || true
HASH_V2=$(bash "$WM" hash-file "$ART")
assert_ne "H.1 the amendment actually moved the hash" "$HASH_V1" "$HASH_V2"
printf '%s' "$SATISFIED_V2" | bash "$QG" design-review-record "$EPIC" --design-hash "$HASH_V2" >/dev/null 2>&1

# Re-inject BOTH units' specs against the NEW hash. This is NOT optional
# scaffolding: compute_design_alignment's own LEG 2 (freshness, reused
# verbatim by the mechanical rollup) compares EACH unit's SPEC-INJECTED
# record's design_hash against the artifact's CURRENT governing hash --
# ANY amendment, including a revision-log-only one with no functional
# content change, moves that hash and therefore staled BOTH units' own
# freshness leg, not only the rollup's own binding. MEASURED, not assumed:
# this fixture's own first draft omitted this step and observed
# mechanical_ok=false here, which is the MECHANICAL axis correctly doing
# its own job (spec_injection_stale on both units) — the exact behaviour
# design-coherence.test.sh's own Section 10 already pins as this axis's
# established, correct hash-divergence response, not a defect. Re-
# injecting isolates what THIS section is actually testing (the ROLLUP's
# own staleness, a DIFFERENT axis) from the mechanical axis re-opening for
# an unrelated, already-covered reason; Section J later reopens the
# mechanical axis deliberately, to prove ITS OWN independence instead.
seed_spec_injection "$CHILD1" "$EPIC" "U1"
seed_spec_injection "$CHILD2" "$EPIC" "U2"

# Re-bind BOTH units' own DESIGN-UNIT binding records against the NEW hash,
# too. This is a THIRD, independent hash-carrying mechanism -- distinct from
# both the artifact's own current hash and the SPEC-INJECTED record's
# freshness handled by seed_spec_injection above. compute_design_coherence's
# hash_divergence check (design-coherence.test.sh Section 10, pinned there
# as correct, established behaviour) reads EACH unit's own latest
# `DESIGN-UNIT v1` comment (written by design-unit-bind, read by
# latest_design_unit_binding) and compares ITS design_hash against the
# artifact's current governing hash -- unaffected by, and unfixed by,
# re-injecting the spec. MEASURED, not assumed: a live debug capture of
# `design-coherence`'s own output at this exact point (an earlier draft of
# this section, before this fix) showed both units reporting
# kind=hash_divergence, detail citing their DESIGN-UNIT binding as still
# carrying the PRE-amendment hash while the governing hash had moved.
# Re-run through design-unit-bind's own --rebind path -- the same remedy
# compute_design_coherence's own hash_divergence detail message and
# design-conform's header both name -- so the binding, like the spec
# injection, tracks the amendment.
bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC" --unit-id U1 --rebind "artifact amended in Section H" >/dev/null 2>&1
bash "$QG" design-unit-bind "$CHILD2" --design-task "$EPIC" --unit-id U2 --rebind "artifact amended in Section H" >/dev/null 2>&1

STATUS_OUT=$(bash "$QG" design-rollup-status "$EPIC" 2>&1)
assert_eq "H.2 the recorded rollup is now STALE (design_hash moved)" "false" \
    "$(json_field '.rollup_hash_fresh' "$STATUS_OUT")"
assert_eq "H.2b ...but mechanical_ok is untouched once both units are re-injected against the new hash" "true" \
    "$(json_field '.mechanical_ok' "$STATUS_OUT")"

APPR_OUT=$(bash "$QG" approve "$EPIC" "attempt after amendment, before a fresh rollup" 2>&1); APPR_RC=$?
assert_eq "H.3 approve refuses the STALE rollup: exit 5" "5" "$APPR_RC"
assert_eq "H.3b error_key=design_rollup_verdict_stale (QA round 1, R1-F10: distinct from the never-recorded/incoherent shapes)" "design_rollup_verdict_stale" \
    "$(json_field '.error_key' "$APPR_OUT")"

OUT=$(printf '%s' "$SATISFIED_V1" | bash "$QG" design-rollup "$EPIC" --design-hash "$HASH_V1" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "H.4 recording a verdict against the OLD hash is ALSO refused (hash-stale at record time)" "1" "$RC_A"
assert_eq "H.4b error_key=design_rollup_hash_stale" "design_rollup_hash_stale" "$(json_field '.error_key' "$OUT")"

OUT=$(printf '%s' "$SATISFIED_V1" | bash "$QG" design-rollup "$EPIC" --design-hash "$HASH_V2" --model "claude-fable-5" 2>&1); RC_A=$?
assert_eq "H.5 RESTORE CONTROL: a fresh verdict against the CURRENT hash records cleanly" "0" "$RC_A"
LATEST_ROLLUP=$(bd comments "$EPIC" --json 2>/dev/null | jq -r '[.[].text | select(startswith("DESIGN-ROLLUP v1 "))] | last')
assert_contains "H.5b the new record carries the NEW hash" "design_hash=$HASH_V2" "$LATEST_ROLLUP"

epic_review_and_complete "$EPIC" "2" "src/b.sh"
EPIC_APPR2=$(bash "$QG" approve "$EPIC" "epic approval after amendment + fresh rollup" 2>&1); EPIC_APPR2_RC=$?
assert_eq "H.6 RESTORE CONTROL: approve succeeds once the rollup is fresh again" "approved" "$(json_field '.status' "$EPIC_APPR2")"
assert_eq "H.6b exit 0" "0" "$EPIC_APPR2_RC"

# ===========================================================================
printf '\n=== Section I moved (QA round 1, R1-F2): see design-rollup-incoherent.test.sh ===\n'
# ===========================================================================
# The former Section I (an INCOHERENT verdict, and the R1-F4 duplicate-hash
# deadlock fix) was self-contained on its own epic (EPIC2) and needed
# nothing from this file's own Setup-through-Section-H narrative on $EPIC --
# split into design-rollup-incoherent.test.sh (R1-F2, QA round 1) to bring
# this file's own standalone runtime back under headroom on the 800s split
# trigger run-tests.sh already names. See that file's own header for the
# full scope this move carried with it.
#
# H.6's own successful approve already truncates $TRACKING (changed-files.
# txt) to empty on success -- with EPIC2's own leftover-review-artifact
# concern gone along with EPIC2 itself, nothing needs re-clearing here.
# What DOES still apply, unchanged, is the hash-uniqueness precondition
# Section J's own upcoming approve call needs: set_idempotency_reference's
# own `[ -s changed-files.txt ]` branch treats an EMPTY tracker as "approve
# leaves it this way" and falls back to a PERSISTED impact report's own
# hash instead of a live recompute -- and since $EPIC has ALREADY been
# approved at least once with an empty-at-hash-time tracker (G.1, whose own
# predecessor (A.4's successful CHILD approve) truncates on success and
# nothing repopulates before G.1 runs) and once against src/b.sh's own
# persisted report (H.6), EITHER stale reference matches a real prior
# approval record, and task_has_approval_record_for($EPIC, that hash) is
# true -- which would send the very next approve call down IDEMPOTENT-
# APPROVE-CONFLICT-RECHECK, a SHORTER ladder that does not carry
# COHERENCE-ROLLUP-REFUSAL at all. MEASURED, not assumed: leaving the
# tracker empty here produced exactly that on J.2 (exit 0 instead of the
# expected exit 2) the first time this fix was tried, before the split.
# src/a.sh is a path $EPIC's own U1 genuinely declares (so touching it
# cannot ITSELF manufacture a NEW tracker_diff_mismatch), and "src/a.sh"
# ALONE, as a path-list, has never been the bound hash of any EARLIER
# successful approve on $EPIC in this file (G.1 bound empty/persisted,
# H.6 bound src/b.sh alone, and K's own later round deliberately reserves
# the src/a.sh+src/b.sh COMBINATION for itself) -- change_set_hash hashes
# the PATH LIST only, never content, so the choice of WHICH never-yet-used
# path list matters here, not what is written inside the file.
printf '# epic-level touch (J)\n' >> "$FIXTURE/src/a.sh"
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
checkpoint_git
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true

# ===========================================================================
printf '\n=== Section J: the mechanical axis (exit 2) is INDEPENDENT of a coherent rollup ===\n'
# ===========================================================================
# Reopen a mechanical issue on the ALREADY-approved, already-coherent
# EPIC (Section H) by corrupting CHILD1's persisted completion contract
# to drop its own declared test file from files_changed — the SAME
# undeclared/incomplete shape design-coherence.test.sh's own Section 8
# exercises, here to prove COHERENCE-ROLLUP-REFUSAL (exit 2) still fires
# even though a genuinely coherent DESIGN-ROLLUP v1 record exists for
# this exact (now stale-by-content, not by hash) state.

record_completion "$CHILD1" "devops" "$(jq -nc --arg r ".claude/scripts/tests/dr-u1.test.sh" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     files_changed:["src/a.sh", $r, "src/ROGUE-J.sh"],
     tests_added:[($r+"::covers AC1")],
     criteria_tests:{"AC1":[($r+"::covers AC1")]}}
')"
OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1)
assert_eq "J.1 the mechanical rollup is open again (undeclared_scope)" "false" "$(json_field '.ok' "$OUT")"

APPR_OUT=$(bash "$QG" approve "$EPIC" "attempt with a reopened mechanical issue" 2>&1); APPR_RC=$?
assert_eq "J.2 approve refuses at the MECHANICAL leg, exit 2 (never the rollup's exit 5)" "2" "$APPR_RC"
assert_ne "J.2b NOT design_rollup_missing — the mechanical key fires first" "design_rollup_missing" "$(json_field '.error_key' "$APPR_OUT")"

# RESTORE CONTROL
record_completion "$CHILD1" "devops" "$(jq -nc --arg r ".claude/scripts/tests/dr-u1.test.sh" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     files_changed:["src/a.sh", $r],
     tests_added:[($r+"::covers AC1")],
     criteria_tests:{"AC1":[($r+"::covers AC1")]}}
')"
OUT=$(bash "$QG" design-coherence "$EPIC" 2>&1)
assert_eq "J.3 RESTORE CONTROL: mechanical rollup clean again" "true" "$(json_field '.ok' "$OUT")"

# ===========================================================================
printf '\n=== Section K: METatest — the hash-freshness check is load-bearing ===\n'
# ===========================================================================
# The coordinator's own instruction: "stub the reviewer verdict to always
# return coherent and assert the gate still refuses when it should." Built
# here as a strip of DESIGN-ROLLUP-REFUSAL's OWN hash-freshness comparison
# (never the mechanical leg above, and never the record-time validation in
# Section C/H — this targets specifically whether the semantic content of
# a GENUINELY coherent verdict is enough on its own, absent the binding
# check, to wrongly pass a STALE record). $LATEST_ROLLUP (Section H) is a
# real, non-forged "verdict=coherent" record — it is simply bound to
# HASH_V1, which Section H's own amendment already superseded with HASH_V2.

MUTANT="$FIXTURE/.claude/scripts/qa-gate-no-rollup-freshness.sh"
awk '
    /# DESIGN-ROLLUP-REFUSAL BEGIN/ { skip=1 }
    !skip { print }
    /# DESIGN-ROLLUP-REFUSAL END/ { skip=0 }
' "$QG" > "$MUTANT"
chmod +x "$MUTANT"

assert_eq "K.1 META NON-VACUITY: the strip actually removed lines" "yes" \
    "$([ "$(wc -l < "$MUTANT")" -lt "$(wc -l < "$QG")" ] && echo yes || echo no)"
assert_eq "K.1b META: the stripped copy is still valid bash" "0" \
    "$(bash -n "$MUTANT" >/dev/null 2>&1; echo $?)"

# CONTROL precondition: EPIC (Section H) currently reads coherent+fresh
# against HASH_V2 (H.5/H.6 already proved this). Re-amend ONE MORE TIME so
# there is once again a genuinely-coherent-but-superseded record on file —
# H.5's own record (against HASH_V2) becomes the stale one this METatest
# targets, the SAME shape H.3 already proved the SHIPPED script refuses.
{
    cat "$ART"
    printf -- '- v3 amended again: a second no-op revision for the METatest.\n'
} > "$ART.new"
mv "$ART.new" "$ART"
printf '%s\n' "$ART" > "$TRACKING"
checkpoint_git
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
HASH_V3=$(bash "$WM" hash-file "$ART")
assert_ne "K.2 the second amendment also moved the hash" "$HASH_V2" "$HASH_V3"
printf '%s' "$SATISFIED_V3" | bash "$QG" design-review-record "$EPIC" --design-hash "$HASH_V3" >/dev/null 2>&1

# Re-inject both units again -- SAME reason as Section H's own identical
# step: this amendment ALSO staled both units' own LEG 2 freshness, and
# this METatest needs the MECHANICAL axis clean so DESIGN-ROLLUP-REFUSAL
# is the ONLY thing being compared between the mutant and the shipped
# script, never confounded by an unrelated, already-covered mechanical
# refusal firing first on either side of that comparison.
seed_spec_injection "$CHILD1" "$EPIC" "U1"
seed_spec_injection "$CHILD2" "$EPIC" "U2"

# Re-bind both units' DESIGN-UNIT binding records too -- SAME reason as
# Section H's own identical step (see the comment there): the
# hash_divergence check reads this record independently of spec-injection
# freshness, and this METatest specifically needs the MECHANICAL axis
# (COHERENCE-ROLLUP-REFUSAL, exit 2) clean so DESIGN-ROLLUP-REFUSAL (exit 5)
# is the ONLY thing being compared between the mutant and the shipped
# script. An open hash_divergence issue would make cmd_approve refuse at
# the EARLIER, mechanical check on BOTH the mutant and the shipped script
# alike (that check is untouched by the mutant's strip), which would make
# K.3's "exit 0 on the mutant" assertion fail for an unrelated reason.
bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC" --unit-id U1 --rebind "artifact amended in Section K" >/dev/null 2>&1
bash "$QG" design-unit-bind "$CHILD2" --design-task "$EPIC" --unit-id U2 --rebind "artifact amended in Section K" >/dev/null 2>&1

# A fresh completion+review cycle is required here for TWO reasons, not
# one: (1) approve's own completion_record_missing/review_artifact_missing
# preconditions need evidence for WHATEVER the live tracker currently
# names; (2) touching a NEW combination (BOTH declared files together,
# never tried by an earlier round: G.1 used src/a.sh alone, H.6 used
# src/b.sh alone) gives this cycle a change_set_hash NEITHER prior
# approval was ever bound to. Reusing either single-file combination here
# would produce a hash THIS TASK has already been approved under
# (change_set_hash is a hash of PATHS, never content), routing this call
# through the IDEMPOTENT-APPROVE-CONFLICT-RECHECK arm instead of the main
# refusal ladder — DESIGN-ROLLUP-REFUSAL (like COHERENCE-ROLLUP-REFUSAL
# beside it) is wired into the main ladder ONLY, so an idempotent
# short-circuit would make this METatest pass for the wrong reason (an
# unrelated fast path) rather than because the freshness check did or did
# not run.
epic_review_and_complete "$EPIC" "3" "src/a.sh" "src/b.sh"

# ORDER IS LOAD-BEARING: the shipped script's OWN refusal runs FIRST,
# against the untouched, not-yet-approved state, and the mutant's wrong
# approval runs SECOND. Reversing this (mutant first, shipped second, as
# an earlier draft had it) makes the mutant's OWN successful approve WRITE
# a real qa-approved label plus an approval record bound to $EPIC's
# CURRENT change_set_hash -- and since nothing between the two calls
# touches $TRACKING or the git tree, the shipped script's own subsequent
# attempt computes the IDENTICAL hash and lands on the IDEMPOTENT-APPROVE
# short-circuit instead of the main refusal ladder, returning "approved"
# for a completely different (and, on its own terms, correct) reason --
# an idempotent no-op over an already-bound hash, not a re-run of
# DESIGN-ROLLUP-REFUSAL. MEASURED, not assumed: that is exactly what the
# reversed order produced (exit 0 / error_key=null on what this section
# labels K.4) before the calls were swapped. Testing the shipped script
# against FRESH, unapproved state first is what actually exercises
# DESIGN-ROLLUP-REFUSAL; the mutant's later approval is then unambiguously
# attributable to the ONE thing that differs between the two calls -- the
# stripped freshness check -- rather than to which one happened to run
# first.
RESTORE_OUT=$(bash "$QG" approve "$EPIC" "RESTORE CONTROL: shipped script, same stale record" 2>&1); RESTORE_RC=$?
assert_eq "K.3 RESTORE CONTROL: the SHIPPED script refuses the STALE-but-coherent record" "5" "$RESTORE_RC"
assert_eq "K.3b ...error_key=design_rollup_verdict_stale (QA round 1, R1-F10), not silently approved" "design_rollup_verdict_stale" "$(json_field '.error_key' "$RESTORE_OUT")"

MUTANT_OUT=$(bash "$MUTANT" approve "$EPIC" "MUTANT: stale-but-genuinely-coherent record" 2>&1); MUTANT_RC=$?
assert_eq "K.4 SPECIFIC MISBEHAVIOUR: without the freshness check, the STALE coherent record wrongly clears the gate" "0" "$MUTANT_RC"
assert_eq "K.4b ...status=approved on the mutant, over a record bound to a SUPERSEDED hash" "approved" "$(json_field '.status' "$MUTANT_OUT")"

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

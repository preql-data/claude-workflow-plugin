#!/bin/bash
# design-unit-align.test.sh — v5 D5 piece 4 (claude-workflow-plugin-fkm.7):
# the per-unit alignment check (docs/plans/v5-design-phase.md Phase D5:
# "the unit's criteria have tests, the touched files fall within the
# declared set ..., and the injected design_hash matches the currently
# bound artifact. Failures block that unit, not the epic").
#
# WHAT THIS COVERS, and why each part needs a test of its own:
#
#   1. `qa-gate.sh design-unit-align` — NOT APPLICABLE when the task carries
#      no DESIGN-UNIT binding at all (the ordinary case for most tasks): no
#      refusal, no bypass flag needed, `applicable:false`.
#
#   2. LEG 1 (FILES) — reused from design-conform, NOT reimplemented: a
#      file-set violation propagates design-conform's OWN error_key
#      (`undeclared_files`) VERBATIM. This spec does not re-prove design-
#      conform's own resolution ladder (design-conform.test.sh already does
#      that exhaustively); it proves the COMPOSITION propagates correctly.
#
#   3. LEG 2 (FRESHNESS) — reused from spec-injection-status: `injected:
#      false` (no SPEC-INJECTED record at all) does NOT fail this leg —
#      matching docs/AGENTS.md's own disclosed best-effort gap — while a
#      positively evidenced `fresh:false` DOES (`spec_injection_stale`).
#
#   4. LEG 3 (CRITERIA HAVE TESTS) — the new predicate, tested exhaustively:
#      no implementer completion record; incomplete coverage; an unknown
#      criterion id; green_after not green (self-declared); green_after
#      EXTERNALLY CORROBORATED against a real GREEN-CHECK v1 record, not
#      merely read back (Section 7b, R7-F3 — QA round 7: absent record,
#      contradicting record, corrected record, and a leg-level METatest); a
#      malformed/missing-file/missing-label test reference; a test_ref
#      confined to the project tree, not merely to "the repo" as an earlier
#      draft claimed (Section 8.4-8.8, R7-F4 — an absolute-path escape, a
#      `../`-relative escape, and a leg-level METatest); and the full
#      success path.
#
#   5. Wiring into `qa-gate.sh approve` — DESIGN-ALIGNMENT-REFUSAL: a
#      misaligned, bound task REFUSES approval (exit 2); an aligned one, or
#      one with no binding at all, does not.
#
#   6. TWO KINDS OF METatest, at two different levels, deliberately not
#      conflated: Sections 7b/8 strip a NAMED LEG-LEVEL region and re-run
#      `design-unit-align` directly (cheap, no approve/review/reconcile
#      setup needed — Sections 1-9 already exercise this level); Section 11
#      strips DESIGN-ALIGNMENT-REFUSAL itself and re-runs through the REAL
#      `approve` (the separate question of whether the leg's answer is
#      actually WIRED into the gate, not merely correct in isolation). Each
#      has its own restore control on the shipped script over the identical
#      state.
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
# Fixture. Same shape as design-conform.test.sh: the real scripts, a real
# bd, a throwaway project root and HOME. `cd "$FIXTURE"` (no subshell) is
# the FAIL-CLOSED store-isolation mechanism this tier requires.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t design-unit-align.XXXXXX)
TEST_HOME=$(mktemp -d -t design-unit-align-home.XXXXXX)

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
    echo "bd CLI not on PATH — design-unit-align tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — design-unit-align tests require jq."
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
TRACKING="$FIXTURE/.claude/.qa-tracking/changed-files.txt"

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }

seed_grilling() {
    local tid="$1"
    bash "$QG" grilling-record "$tid" --rounds 2 --questions 4 --approaches 2 --unresolved 0 \
        "design-unit-align.test.sh: seeding the grilling precondition" >/dev/null 2>&1
}

checkpoint_git() {
    ( cd "$FIXTURE" && git add -A >/dev/null 2>&1 && git commit -q -m "test checkpoint" --allow-empty >/dev/null 2>&1 ) || true
}

# write_artifact <path> <task-id> <unit-json-array>
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

SATISFIED_VERDICT='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'

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
    printf '%s' "$SATISFIED_VERDICT" | bash "$QG" design-review-record "$epic" --design-hash "$hash" >/dev/null 2>&1
    printf '%s' "$hash"
}

# seed_spec_injection <tid> <epic> <unit-id> [unit-hash-override] -- writes
# a SPEC-INJECTED v1 record directly (design-accessors.test.sh Section 12's
# technique: construct the record text, not run subagent-start.sh's hook),
# using the REAL per-unit content hash unless an override is given (for the
# stale-content leg).
seed_spec_injection() {
    local tid="$1" epic="$2" uid="$3" override_hash="${4:-}"
    local art dhash ujson tmpf uhash ts
    art="$FIXTURE/docs/specs/$epic.md"
    dhash=$(bash "$WM" hash-file "$art")
    ujson=$(bash "$RC" design-unit-json "$art" "$uid" | jq -r '.unit_json')
    # Under .claude/.qa-tracking/, not the fixture root -- see
    # record_completion's own comment for why scratch lives there.
    tmpf="$FIXTURE/.claude/.qa-tracking/.dua-si-tmp.json"
    printf '%s\n' "$ujson" > "$tmpf"
    uhash=$(bash "$WM" hash-file "$tmpf")
    rm -f "$tmpf"
    [ -n "$override_hash" ] && uhash="$override_hash"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "SPEC-INJECTED v1 task=$tid design_task=$epic unit_id=$uid design_hash=$dhash unit_hash=$uhash at $ts: injected at spawn" >/dev/null 2>&1
}

# seed_green_check <tid> <phase> <result> [unit-id] -- writes a
# `GREEN-CHECK v1` record directly, in the EXACT grammar cmd_green_check's
# own writer produces (qa-gate.sh:14495 area: "GREEN-CHECK v1 task=<tid>
# unit_id=<u> phase=<p> result=<r> exit_code=<n> at <ts>: <summary>") --
# same technique as seed_spec_injection above (construct the record text
# directly, not run the real subcommand end to end), because LEG 3 step (d)
# reads THIS record's shape via latest_green_check_result, not a live
# suite run, and design-conform.test.sh/design-unit-align.test.sh both
# already establish that constructing a record directly, byte-for-byte
# matching the shipped grammar, is how THIS file's fixtures exercise a
# reader without needing the writer's own end-to-end preconditions (a
# resolvable test command via detect-stack.sh, which a bare bd fixture has
# none of). R7-F3 (QA round 7).
seed_green_check() {
    local tid="$1" phase="$2" result="$3" uid="${4:-U1}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "GREEN-CHECK v1 task=$tid unit_id=$uid phase=$phase result=$result exit_code=0 at $ts: suite $result (design-unit-align.test.sh seeded)" >/dev/null 2>&1
}

# write_test_file <relpath> <label...> -- a real, readable test file
# containing the given labels, so LEG 3's file+label corroboration has a
# real filesystem artifact to check.
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
# payload (all twelve fields legal-shaped) merged with <extra-json>, and
# records it via the REAL completion-record subcommand (the REAL validator
# runs on every call, exactly as production does).
record_completion() {
    local tid="$1" role="$2" extra="$3"
    # The scratch payload file lives under .claude/.qa-tracking/ (never the
    # fixture root) so reconcile_tracker's workflow_self_written check
    # excludes it from the change set exactly as it excludes every OTHER
    # gate-bookkeeping file there -- a probe dropped anywhere else enters
    # changed-files.txt and moves change_set_hash out from under whichever
    # `approve` call runs next, which is exactly what happened here before
    # this fix (measured: a stray .completion-payload-*.json at the fixture
    # root produced impact_report_stale in Sections 10/11, never a real
    # alignment refusal).
    local out="$FIXTURE/.claude/.qa-tracking/.dua-completion-payload-$RANDOM$RANDOM.json"
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

# files[] declares BOTH source paths and the test file(s) this unit's own
# criteria_tests will reference (Sections 5-11 alternately use
# dua-fixture.test.sh and dua-fixture2.test.sh across different epics built
# from this SAME template) -- a real unit design declares the tests it adds
# as part of its own touched set, exactly like files_changed on the F7
# contract includes tests; leaving them undeclared here reproduces, in the
# fixture itself, the "mention mistaken for a test" class of gap this whole
# piece exists to close, just one level up (a criterion pointing at a REAL,
# EXISTING, CORRECTLY-LABELLED test file that the unit never said it would
# touch at all).
TWO_CRIT_UNIT='[
  {"unit_id":"U1","role":"devops","goal":"unit one",
   "acceptance":[{"id":"AC1","text":"criterion one"},{"id":"AC2","text":"criterion two"}],
   "files":["src/a.sh","src/b.sh",".claude/scripts/tests/dua-fixture.test.sh",".claude/scripts/tests/dua-fixture2.test.sh"],
   "verification":"make test","depends_on":[]}
]'

# ===========================================================================
printf '\n=== Section 1: NOT APPLICABLE — no DESIGN-UNIT binding at all ===\n'
# ===========================================================================

FRESH=$(bd create "DUA: never bound" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" design-unit-align "$FRESH" 2>&1); RC_A=$?
assert_eq "1.1 exit 0" "0" "$RC_A"
assert_eq "1.1b ...ok=true, applicable=false" "true|false" \
    "$(json_field '.ok' "$OUT")|$(json_field '.applicable' "$OUT")"
assert_eq "1.1c ...unit_id/design_task are empty (nothing resolved, nothing to name)" "|" \
    "$(json_field '.unit_id' "$OUT")|$(json_field '.design_task' "$OUT")"

# ===========================================================================
printf '\n=== Section 2: LEG 1 (FILES) — reused from design-conform, propagated verbatim ===\n'
# ===========================================================================

EPIC1=$(bd create "DUA epic 1" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD1=$(bd create "DUA child 1" -t task -p 1 --parent "$EPIC1" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
# The live hash is not asserted here — design-conform.test.sh's own Section
# 2 already proves design-unit-bind records it correctly; this file only
# needs the design SATISFIED and the unit BOUND, not a second check of the
# hash's own value.
design_and_review "$EPIC1" "$TWO_CRIT_UNIT" >/dev/null
bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC1" --unit-id U1 "bound to U1" >/dev/null 2>&1

write_test_file "src/a.sh" "unused"
write_test_file "src/b.sh" "unused"
write_test_file "src/UNDECLARED.sh" "unused"
printf '%s\n%s\n%s\n' "$FIXTURE/src/a.sh" "$FIXTURE/src/b.sh" "$FIXTURE/src/UNDECLARED.sh" > "$TRACKING"

OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "2.1 an undeclared file in the change set: exit 4" "4" "$RC_A"
assert_eq "2.1b ...error_key=undeclared_files (design-conform's OWN key, propagated verbatim, not re-wrapped)" \
    "undeclared_files" "$(json_field '.error_key' "$OUT")"
assert_eq "2.1c ...applicable=true, unit_id/design_task resolved" "true|U1|$EPIC1" \
    "$(json_field '.applicable' "$OUT")|$(json_field '.unit_id' "$OUT")|$(json_field '.design_task' "$OUT")"
assert_contains "2.1d ...observations names the failing leg" "LEG 1 (files) failed" "$(json_field '.observations' "$OUT")"

# Restore the tracker to exactly the declared set for the rest of this
# file -- AND remove the file itself from disk, not just from $TRACKING.
# Resetting the tracker alone is not enough: UNDECLARED.sh remains a REAL,
# UNCOMMITTED file in the fixture's own git working tree, and Section 10's
# `seed_review_and_enter` calls `reconcile-tracker` (a real git-status
# scan) much later -- which rediscovers it as "new" regardless of what
# $TRACKING says at this point, and reintroduces the exact undeclared-file
# condition this section exists to PROVE, this time contaminating a
# control case that is supposed to succeed. Measured directly while
# building this fix: leaving the file in place turned Section 10.1's own
# "fully aligned" control into a false undeclared_files refusal. Deleting
# it here, once its OWN assertions (above) are done with it, is the fix.
rm -f "$FIXTURE/src/UNDECLARED.sh"
printf '%s\n%s\n' "$FIXTURE/src/a.sh" "$FIXTURE/src/b.sh" > "$TRACKING"

# ===========================================================================
printf '\n=== Section 3: LEG 2 (FRESHNESS) — injected:false is LEGAL, fresh:false is NOT ===\n'
# ===========================================================================

OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "3.1 files conform, NO SPEC-INJECTED record at all: LEG 2 passes through (injected:false is legal)" \
    "4" "$RC_A"
assert_eq "3.1b ...so the failure (if any) comes from a LATER leg, never spec_injection_stale" \
    "no" "$([ "$(json_field '.error_key' "$OUT")" = "spec_injection_stale" ] && echo yes || echo no)"

# Now seed a STALE SPEC-INJECTED record (wrong unit_hash) and confirm LEG 2
# DOES fail this time.
seed_spec_injection "$CHILD1" "$EPIC1" "U1" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "3.2 a STALE SPEC-INJECTED record (unit content changed since injection): exit 4" "4" "$RC_A"
assert_eq "3.2b ...error_key=spec_injection_stale" \
    "spec_injection_stale" "$(json_field '.error_key' "$OUT")"
assert_contains "3.2c ...observations names the failing leg" "LEG 2 (freshness) failed" "$(json_field '.observations' "$OUT")"

# A FRESH record clears LEG 2 (used by every section below).
seed_spec_injection "$CHILD1" "$EPIC1" "U1"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "3.3 a FRESH SPEC-INJECTED record: LEG 2 no longer the failing leg" \
    "no" "$([ "$(json_field '.error_key' "$OUT")" = "spec_injection_stale" ] && echo yes || echo no)"

# ===========================================================================
printf '\n=== Section 4: LEG 3 (CRITERIA HAVE TESTS) — no implementer record at all ===\n'
# ===========================================================================

OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "4.1 LEG 1/2 pass, no COMPLETION record at all: exit 4" "4" "$RC_A"
assert_eq "4.1b ...error_key=no_implementer_completion_record" \
    "no_implementer_completion_record" "$(json_field '.error_key' "$OUT")"

# ===========================================================================
printf '\n=== Section 5: LEG 3 — incomplete coverage ===\n'
# ===========================================================================

DUA_TEST_REL=".claude/scripts/tests/dua-fixture.test.sh"
write_test_file "$DUA_TEST_REL" "covers AC1" "covers AC2"

record_completion "$CHILD1" "devops" "$(jq -nc --arg r "$DUA_TEST_REL" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     tests_added:[($r+"::covers AC1")],
     criteria_tests:{"AC1":[($r+"::covers AC1")]}}
')"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "5.1 AC2 has no covering test: exit 4" "4" "$RC_A"
assert_eq "5.1b ...error_key=criteria_incomplete" \
    "criteria_incomplete" "$(json_field '.error_key' "$OUT")"
assert_contains "5.1c ...names the missing criterion id" "AC2" "$(json_field '.observations' "$OUT")"

# ===========================================================================
printf '\n=== Section 6: LEG 3 — unknown criterion id ===\n'
# ===========================================================================

record_completion "$CHILD1" "devops" "$(jq -nc --arg r "$DUA_TEST_REL" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     tests_added:[($r+"::covers AC1"), ($r+"::covers AC2")],
     criteria_tests:{"AC1":[($r+"::covers AC1")], "AC2":[($r+"::covers AC2")],
                      "AC-BOGUS":[($r+"::covers AC1")]}}
')"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "6.1 criteria_tests names an id the unit does not declare: exit 4" "4" "$RC_A"
assert_eq "6.1b ...error_key=criteria_test_unknown_criterion" \
    "criteria_test_unknown_criterion" "$(json_field '.error_key' "$OUT")"
assert_contains "6.1c ...names the unknown id" "AC-BOGUS" "$(json_field '.observations' "$OUT")"

# ===========================================================================
printf '\n=== Section 7: LEG 3 — green_after not green ===\n'
# ===========================================================================

record_completion "$CHILD1" "devops" "$(jq -nc --arg r "$DUA_TEST_REL" '
    {unit_id:"U1", green_before:"green", green_after:"red",
     tests_added:[($r+"::covers AC1"), ($r+"::covers AC2")],
     criteria_tests:{"AC1":[($r+"::covers AC1")], "AC2":[($r+"::covers AC2")]}}
')"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "7.1 complete, well-formed coverage but green_after=red: exit 4" "4" "$RC_A"
assert_eq "7.1b ...error_key=criteria_tests_without_green_after" \
    "criteria_tests_without_green_after" "$(json_field '.error_key' "$OUT")"

# ===========================================================================
printf '\n=== Section 7b: LEG 3 (d) — green_after EXTERNALLY corroborated, not self-declared (R7-F3) ===\n'
# ===========================================================================
# QA round 7, R7-F3: before this round, (d) read .green_after off the SAME
# payload criteria_tests sits on and string-compared it -- a
# self-certification, not the "actually ran" corroboration the region
# header claimed. This section proves the record is now REQUIRED, that a
# CONTRADICTING record refuses distinctly from an ABSENT one, and that the
# gate is load-bearing (a mutant with the check stripped lets an
# uncorroborated claim through the SAME payload the shipped script
# refuses).
#
# A COMPLETE, otherwise-fully-aligned payload throughout -- so that once
# corroborated, nothing else stops it, and the metatest below can reach
# a clean ok:true rather than tripping some OTHER leg first.
GC_PAYLOAD="$(jq -nc --arg r "$DUA_TEST_REL" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     tests_added:[($r+"::covers AC1"), ($r+"::covers AC2")],
     criteria_tests:{"AC1":[($r+"::covers AC1")], "AC2":[($r+"::covers AC2")]}}
')"
record_completion "$CHILD1" "devops" "$GC_PAYLOAD"

OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "7b.1 green_after='green' claimed, but NO GREEN-CHECK v1 record at all: exit 4" \
    "4" "$RC_A"
assert_eq "7b.1b ...error_key=criteria_tests_green_check_unrecorded" \
    "criteria_tests_green_check_unrecorded" "$(json_field '.error_key' "$OUT")"

# METatest, at THIS leg's own level (design-unit-align directly, not
# through approve -- Sections 1-9 already test this level; Section 11's
# metatest is for the SEPARATE question of approve's own wiring).
META_QG_GC="$FIXTURE/.claude/scripts/qa-gate-no-green-check-corrob.sh"
STRIP_RC_GC=0
awk '
    /^    # LEG-3-GREEN-CHECK-CORROBORATION BEGIN/ { skip = 1; found = 1; next }
    /^    # LEG-3-GREEN-CHECK-CORROBORATION END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$META_QG_GC" || STRIP_RC_GC=$?
chmod +x "$META_QG_GC" 2>/dev/null || true
assert_eq "7b.2 META NON-VACUITY: the sentinels were found and the strip ran cleanly" "0" "$STRIP_RC_GC"
GC_SHIPPED_LINES=$(wc -l < "$QG" | tr -d '[:space:]')
GC_STRIPPED_LINES=$(wc -l < "$META_QG_GC" | tr -d '[:space:]')
assert_eq "7b.2b ...the mutant copy is shorter than the shipped script" \
    "shorter" "$([ "$GC_STRIPPED_LINES" -lt "$GC_SHIPPED_LINES" ] && echo shorter || echo same-or-longer)"
GC_BASH_N_RC=0
bash -n "$META_QG_GC" 2>/dev/null || GC_BASH_N_RC=$?
assert_eq "7b.2c ...and the mutant still parses" "0" "$GC_BASH_N_RC"

MUTANT_GC_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$META_QG_GC" design-unit-align "$CHILD1" 2>&1)
assert_eq "7b.3 SPECIFIC MISBEHAVIOUR: WITHOUT the corroboration, the SAME uncorroborated claim clears (ok=true)" \
    "true" "$(json_field '.ok' "$MUTANT_GC_OUT")"
rm -f "$META_QG_GC"

CTRL_GC_OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1)
assert_eq "7b.4 RESTORE CONTROL: the SAME state against the SHIPPED script still refuses" \
    "criteria_tests_green_check_unrecorded" "$(json_field '.error_key' "$CTRL_GC_OUT")"

# A CONTRADICTING record (result=red) must refuse distinctly from an
# ABSENT one -- "not merely exist" is the orchestrator's own framing of
# what this leg was asked to check.
seed_green_check "$CHILD1" "after" "red"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "7b.5 a CONTRADICTING GREEN-CHECK v1 record (result=red) vs the payload's claimed green: exit 4" \
    "4" "$RC_A"
assert_eq "7b.5b ...error_key=criteria_tests_green_check_mismatch (distinct from _unrecorded)" \
    "criteria_tests_green_check_mismatch" "$(json_field '.error_key' "$OUT")"

# A LATER, CORRECTED record (result=green) supersedes the earlier red one
# ("latest wins", the same selection latest_implementer_completion_record
# already uses) and the leg clears -- reaching the full aligned state,
# since GC_PAYLOAD above is otherwise complete.
seed_green_check "$CHILD1" "after" "green"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "7b.6 a LATER, corrected GREEN-CHECK v1 record (result=green): the leg clears, exit 0" \
    "0" "$RC_A"
assert_eq "7b.6b ...ok=true (fully aligned: LEG 3 corroborated end to end)" \
    "true" "$(json_field '.ok' "$OUT")"

# ===========================================================================
printf '\n=== Section 8: LEG 3 — malformed / missing-file / missing-label refs ===\n'
# ===========================================================================

record_completion "$CHILD1" "devops" '
    {"unit_id":"U1","green_before":"green","green_after":"green",
     "tests_added":["no-double-colon-here"],
     "criteria_tests":{"AC1":["no-double-colon-here"],"AC2":["no-double-colon-here"]}}
'
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "8.1 a test_ref with no '::' separator: exit 4" "4" "$RC_A"
assert_eq "8.1b ...error_key=criteria_test_ref_malformed" \
    "criteria_test_ref_malformed" "$(json_field '.error_key' "$OUT")"

record_completion "$CHILD1" "devops" "$(jq -nc '
    {unit_id:"U1", green_before:"green", green_after:"green",
     tests_added:[".claude/scripts/tests/DOES-NOT-EXIST.sh::x"],
     criteria_tests:{"AC1":[".claude/scripts/tests/DOES-NOT-EXIST.sh::x"],
                      "AC2":[".claude/scripts/tests/DOES-NOT-EXIST.sh::x"]}}
')"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "8.2 a test_ref naming a file that does not exist: exit 4" "4" "$RC_A"
assert_eq "8.2b ...error_key=criteria_test_file_missing" \
    "criteria_test_file_missing" "$(json_field '.error_key' "$OUT")"

record_completion "$CHILD1" "devops" "$(jq -nc --arg r "$DUA_TEST_REL" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     tests_added:[($r+"::a label that is not in the file")],
     criteria_tests:{"AC1":[($r+"::a label that is not in the file")],
                      "AC2":[($r+"::a label that is not in the file")]}}
')"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "8.3 a test_ref naming a real file but an absent label: exit 4" "4" "$RC_A"
assert_eq "8.3b ...error_key=criteria_test_label_not_found" \
    "criteria_test_label_not_found" "$(json_field '.error_key' "$OUT")"

# R7-F4 (QA round 7): a test_ref is not confined to the project tree
# without an explicit containment check. DEMONSTRATED by QA against a REAL
# file outside the repo that a bare `grep -qF` can match: /etc/passwd
# contains "root" on every host this test runs on (verified directly:
# `grep -qF root /etc/passwd`, exit 0). Using the SAME demonstration here
# rather than inventing a synthetic one -- it is what was actually proven,
# and a synthetic stand-in could look like it exercises the vector while
# actually testing something narrower.
ESCAPE_ABS_PAYLOAD='
    {"unit_id":"U1","green_before":"green","green_after":"green",
     "tests_added":["/etc/passwd::root"],
     "criteria_tests":{"AC1":["/etc/passwd::root"],"AC2":["/etc/passwd::root"]}}
'
record_completion "$CHILD1" "devops" "$ESCAPE_ABS_PAYLOAD"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "8.4 an ABSOLUTE-PATH test_ref (/etc/passwd::root) outside the project tree: exit 4" \
    "4" "$RC_A"
assert_eq "8.4b ...error_key=criteria_test_ref_outside_project" \
    "criteria_test_ref_outside_project" "$(json_field '.error_key' "$OUT")"

ESCAPE_REL_PAYLOAD='
    {"unit_id":"U1","green_before":"green","green_after":"green",
     "tests_added":["../../../../../../../../etc/passwd::root"],
     "criteria_tests":{"AC1":["../../../../../../../../etc/passwd::root"],
                        "AC2":["../../../../../../../../etc/passwd::root"]}}
'
record_completion "$CHILD1" "devops" "$ESCAPE_REL_PAYLOAD"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "8.5 a '../'-RELATIVE test_ref escaping the project tree: exit 4" \
    "4" "$RC_A"
assert_eq "8.5b ...error_key=criteria_test_ref_outside_project (same class as the absolute escape)" \
    "criteria_test_ref_outside_project" "$(json_field '.error_key' "$OUT")"

# METatest: strip LEG-3-REF-CONTAINMENT and confirm the SAME absolute-path
# escape (still on CHILD1 from 8.4/8.5 -- re-recorded to be explicit and
# order-independent) now clears ALL THE WAY to ok:true, since nothing else
# in this payload is wrong and /etc/passwd genuinely contains "root".
record_completion "$CHILD1" "devops" "$ESCAPE_ABS_PAYLOAD"
META_QG_RC="$FIXTURE/.claude/scripts/qa-gate-no-ref-containment.sh"
STRIP_RC_RC=0
awk '
    /^        # LEG-3-REF-CONTAINMENT BEGIN/ { skip = 1; found = 1; next }
    /^        # LEG-3-REF-CONTAINMENT END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$META_QG_RC" || STRIP_RC_RC=$?
chmod +x "$META_QG_RC" 2>/dev/null || true
assert_eq "8.6 META NON-VACUITY: the sentinels were found and the strip ran cleanly" "0" "$STRIP_RC_RC"
RC_SHIPPED_LINES=$(wc -l < "$QG" | tr -d '[:space:]')
RC_STRIPPED_LINES=$(wc -l < "$META_QG_RC" | tr -d '[:space:]')
assert_eq "8.6b ...the mutant copy is shorter than the shipped script" \
    "shorter" "$([ "$RC_STRIPPED_LINES" -lt "$RC_SHIPPED_LINES" ] && echo shorter || echo same-or-longer)"
RC_BASH_N_RC=0
bash -n "$META_QG_RC" 2>/dev/null || RC_BASH_N_RC=$?
assert_eq "8.6c ...and the mutant still parses" "0" "$RC_BASH_N_RC"

MUTANT_RC_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$META_QG_RC" design-unit-align "$CHILD1" 2>&1)
assert_eq "8.7 SPECIFIC MISBEHAVIOUR: WITHOUT containment, the SAME /etc/passwd::root escape clears (ok=true)" \
    "true" "$(json_field '.ok' "$MUTANT_RC_OUT")"
rm -f "$META_QG_RC"

CTRL_RC_OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1)
assert_eq "8.8 RESTORE CONTROL: the SAME escape against the SHIPPED script still refuses" \
    "criteria_test_ref_outside_project" "$(json_field '.error_key' "$CTRL_RC_OUT")"

# ===========================================================================
printf '\n=== Section 9: THE FULL SUCCESS PATH — all three legs pass ===\n'
# ===========================================================================

record_completion "$CHILD1" "devops" "$(jq -nc --arg r "$DUA_TEST_REL" '
    {unit_id:"U1", green_before:"green", green_after:"green",
     tests_added:[($r+"::covers AC1"), ($r+"::covers AC2")],
     criteria_tests:{"AC1":[($r+"::covers AC1")], "AC2":[($r+"::covers AC2")]}}
')"
OUT=$(bash "$QG" design-unit-align "$CHILD1" 2>&1); RC_A=$?
assert_eq "9.1 every leg passes: exit 0" "0" "$RC_A"
assert_eq "9.1b ...ok=true, error_key empty, applicable=true" "true||true" \
    "$(json_field '.ok' "$OUT")|$(json_field '.error_key' "$OUT")|$(json_field '.applicable' "$OUT")"
assert_contains "9.1c ...observations says aligned" "aligned:" "$(json_field '.observations' "$OUT")"

# ===========================================================================
printf '\n=== Section 10: wiring into approve — DESIGN-ALIGNMENT-REFUSAL ===\n'
# ===========================================================================

# seed_review_and_enter <tid> -- the rest of what `approve` needs beyond
# alignment: an IMPLEMENTER record (so REVIEW-SEPARATION independence
# holds), a review artifact, a reconciled tracker, and a fresh impact
# report. Mirrors design-review-record.test.sh's own seed_approvable, minus
# the completion-record call (this file's own record_completion already
# covers that, with the FULL v5 D5 field set).
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
    # review-record writes the canonical artifact to docs/reviews/, a NEW
    # untracked path git did not see at the reconcile above -- reconcile
    # AGAIN so the impact report regenerated next (and the approve call
    # right after this function returns) both see the SAME, POST-artifact
    # tracker state. Without this second call the persisted impact report
    # is bound to a hash that predates the review artifact's own file,
    # and `approve`'s own internal reconcile (which DOES pick the artifact
    # up) then disagrees with it -- measured directly: impact_report_stale
    # on every call, not the alignment refusal each section is actually
    # testing. design-review-record.test.sh's own seed_approvable follows
    # this exact order (reconcile AFTER review-record, THEN regenerate);
    # this helper now matches it.
    bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
    bash "$FIXTURE/.claude/scripts/impact-report.sh" "$tid" >/dev/null 2>&1 || true
}

# CHILD1 currently carries the fully-aligned completion record from Section
# 9. Bring it the rest of the way to an approvable state.
#
# --no-design IS REQUIRED HERE, and its necessity is itself a finding worth
# recording (not silently worked around): DESIGN-SATISFIED-REFUSAL
# (fkm.4/D2) calls `compute_design_satisfied "$tid"` on the task passed to
# `approve` DIRECTLY -- it does NOT resolve through the DESIGN-UNIT binding
# the way design-conform and design-unit-align both do (design-conform's
# own step 2 explicitly calls `compute_design_satisfied "$design_task"`,
# the RESOLVED epic, never `$tid`). A v5 task-per-unit CHILD task like
# CHILD1 never carries its own DESIGN-ARTIFACT/DESIGN-REVIEW records --
# those live on the EPIC -- so DESIGN-SATISFIED-REFUSAL reads
# no_design_attempted for EVERY such child regardless of how satisfied its
# governing epic's design actually is, and --no-design is the ONLY way
# past it (mirrors design-artifact.test.sh's own approve calls, which ALL
# use --no-design for the identical reason, per that file's own comments:
# "testing DESIGN-BINDING-TOKEN, not design-satisfied"). This does not
# weaken what THIS section tests: --no-design bypasses ONLY the
# satisfied-verdict requirement and has NO effect on DESIGN-ALIGNMENT-
# REFUSAL (see that block's own header) or DESIGN-CONFLICT-REFUSAL, which
# is the entire point of the axis this section exercises.
seed_review_and_enter "$CHILD1"
APPR_OUT=$(bash "$QG" approve "$CHILD1" --no-design "DUA section 10: not the axis under test" "DUA section 10: aligned approval" 2>&1); APPR_RC=$?
assert_eq "10.1 CONTROL: a fully aligned, otherwise-approvable task: approve succeeds" \
    "approved" "$(json_field '.status' "$APPR_OUT")"
assert_eq "10.1b ...exit 0" "0" "$APPR_RC"

# A SECOND task, bound but genuinely misaligned (green_after=red), must
# refuse — the exact scenario Section 7 proved standalone, now through the
# real gate.
EPIC2=$(bd create "DUA epic 2 (approve wiring)" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD2=$(bd create "DUA child 2 (approve wiring)" -t task -p 1 --parent "$EPIC2" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC2" "$TWO_CRIT_UNIT" >/dev/null
bash "$QG" design-unit-bind "$CHILD2" --design-task "$EPIC2" --unit-id U1 "bound to U1" >/dev/null 2>&1
DUA_TEST_REL2=".claude/scripts/tests/dua-fixture2.test.sh"
write_test_file "$DUA_TEST_REL2" "covers AC1 v2" "covers AC2 v2"
printf '%s\n%s\n' "$FIXTURE/src/a.sh" "$FIXTURE/src/b.sh" > "$TRACKING"
seed_spec_injection "$CHILD2" "$EPIC2" "U1"
record_completion "$CHILD2" "devops" "$(jq -nc --arg r "$DUA_TEST_REL2" '
    {unit_id:"U1", green_before:"green", green_after:"red",
     tests_added:[($r+"::covers AC1 v2"), ($r+"::covers AC2 v2")],
     criteria_tests:{"AC1":[($r+"::covers AC1 v2")], "AC2":[($r+"::covers AC2 v2")]}}
')"
seed_review_and_enter "$CHILD2"

APPR2_OUT=$(bash "$QG" approve "$CHILD2" --no-design "DUA section 10: not the axis under test" "DUA section 10: misaligned approval attempt" 2>&1); APPR2_RC=$?
assert_eq "10.2 a BOUND, MISALIGNED task (green_after=red on criteria_tests): approve REFUSES, exit 2" \
    "2" "$APPR2_RC"
assert_eq "10.2b ...error_key=criteria_tests_without_green_after" \
    "criteria_tests_without_green_after" "$(json_field '.error_key' "$APPR2_OUT")"
assert_contains "10.2c ...names the remedy (fix the work, or amend+rebind)" "design-unit-bind" "$(json_field '.observations' "$APPR2_OUT")"

# ===========================================================================
printf '\n=== Section 11: METatest — DESIGN-ALIGNMENT-REFUSAL is load-bearing ===\n'
# ===========================================================================

# Lives in .claude/scripts/ (a sibling of the real workflow-denylist.sh),
# matching design-conform.test.sh's own mutant convention
# (qa-gate-noconformgate.sh et al) -- NOT under .claude/.qa-tracking/ as an
# earlier draft of this test had it. That earlier placement broke the
# mutant's OWN reconcile_tracker: qa-gate.sh resolves _WFDL_DIR from
# dirname "${BASH_SOURCE[0]}" (qa-gate.sh:536, deliberately relative to the
# running script, never $PROJECT_DIR -- see the comment right above it) and
# only sources "$_WFDL_DIR/workflow-denylist.sh" when that file exists there
# (qa-gate.sh:537-540; no error if it doesn't, the source just silently
# never happens). approve() calls reconcile_tracker() internally, which then
# finds WORKFLOW_DENYLIST_REGEX unset and refuses with tracker_unreconcilable
# (qa-gate.sh:1266-1270) before DESIGN-ALIGNMENT-REFUSAL -- the thing this
# section actually exists to test -- is ever reached. That was a
# self-inflicted failure of the harness, not a finding about the shipped
# script: design-conform's own mutants never hit it because design-conform()
# never calls reconcile_tracker() -- it only reads changed-files.txt
# directly or via impact-report.sh, which sources its own denylist copy
# independently and was never relocated.
#
# The tracker-pollution risk that motivated the original .qa-tracking/
# placement (an untracked mutant file getting swept up by a LATER real
# reconcile-tracker call -- CHILD3's own seed_review_and_enter below does
# call it) is handled instead by deleting this file immediately after the
# one mutant approve call that needs it (right after MUTANT_OUT/MUTANT_RC
# are captured), strictly before CHILD3's sequence begins -- so no
# subsequent reconcile ever has a chance to observe it on disk.
META_QG="$FIXTURE/.claude/scripts/qa-gate-no-alignment.sh"
STRIP_RC=0
awk '
    /^# DESIGN-ALIGNMENT-REFUSAL BEGIN/ { skip = 1; found = 1; next }
    /^# DESIGN-ALIGNMENT-REFUSAL END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$META_QG" || STRIP_RC=$?
chmod +x "$META_QG" 2>/dev/null || true

assert_eq "11.1 NON-VACUITY: the sentinels were found and the strip ran cleanly" "0" "$STRIP_RC"
SHIPPED_LINES=$(wc -l < "$QG" | tr -d '[:space:]')
STRIPPED_LINES=$(wc -l < "$META_QG" | tr -d '[:space:]')
assert_eq "11.2 ...the mutant copy is shorter than the shipped script" \
    "shorter" "$([ "$STRIPPED_LINES" -lt "$SHIPPED_LINES" ] && echo shorter || echo same-or-longer)"
BASH_N_RC=0
bash -n "$META_QG" 2>/dev/null || BASH_N_RC=$?
assert_eq "11.3 ...and the mutant still parses" "0" "$BASH_N_RC"

# Re-seed CHILD2 back to the SAME misaligned state Section 10.2 already
# proved the shipped script refuses (idempotent: completion-record and
# review-record both append/overwrite rather than requiring a fresh task).
record_completion "$CHILD2" "devops" "$(jq -nc --arg r "$DUA_TEST_REL2" '
    {unit_id:"U1", green_before:"green", green_after:"red",
     tests_added:[($r+"::covers AC1 v2"), ($r+"::covers AC2 v2")],
     criteria_tests:{"AC1":[($r+"::covers AC1 v2")], "AC2":[($r+"::covers AC2 v2")]}}
')"
seed_review_and_enter "$CHILD2"

MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$META_QG" approve "$CHILD2" --no-design "DUA section 11: not the axis under test" "DUA section 11: mutant re-attempt" 2>&1); MUTANT_RC=$?
assert_eq "11.4 SPECIFIC MISBEHAVIOUR: WITHOUT the block, the SAME misaligned task approves anyway" \
    "approved" "$(json_field '.status' "$MUTANT_OUT")"
assert_eq "11.4b ...exit 0 on the mutant" "0" "$MUTANT_RC"

# Delete the mutant NOW, before CHILD3's own seed_review_and_enter (below)
# gets anywhere near a reconcile-tracker call -- see the placement comment
# above META_QG's assignment for why this timing matters.
rm -f "$META_QG"

# RESTORE CONTROL: a FRESH bound-misaligned task (CHILD2 is now qa-approved
# from the mutant run above, so idempotency could mask the control — use a
# THIRD task in the SAME misaligned state) against the SHIPPED script still
# refuses.
EPIC3=$(bd create "DUA epic 3 (control)" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD3=$(bd create "DUA child 3 (control)" -t task -p 1 --parent "$EPIC3" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC3" "$TWO_CRIT_UNIT" >/dev/null
bash "$QG" design-unit-bind "$CHILD3" --design-task "$EPIC3" --unit-id U1 "bound to U1" >/dev/null 2>&1
printf '%s\n%s\n' "$FIXTURE/src/a.sh" "$FIXTURE/src/b.sh" > "$TRACKING"
seed_spec_injection "$CHILD3" "$EPIC3" "U1"
record_completion "$CHILD3" "devops" "$(jq -nc --arg r "$DUA_TEST_REL2" '
    {unit_id:"U1", green_before:"green", green_after:"red",
     tests_added:[($r+"::covers AC1 v2"), ($r+"::covers AC2 v2")],
     criteria_tests:{"AC1":[($r+"::covers AC1 v2")], "AC2":[($r+"::covers AC2 v2")]}}
')"
seed_review_and_enter "$CHILD3"
CTRL_OUT=$(bash "$QG" approve "$CHILD3" --no-design "DUA section 11: not the axis under test" "DUA section 11: control on shipped script" 2>&1); CTRL_RC=$?
assert_eq "11.5 RESTORE CONTROL: the SAME misaligned shape against the SHIPPED script still refuses" \
    "2" "$CTRL_RC"
assert_eq "11.5b ...error_key=criteria_tests_without_green_after" \
    "criteria_tests_without_green_after" "$(json_field '.error_key' "$CTRL_OUT")"

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
exit 0

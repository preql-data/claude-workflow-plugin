#!/bin/bash
# design-conform.test.sh — v5 Phase D4, first slice (claude-workflow-plugin-
# fkm.6): the unit<->task binding record (`design-unit-bind` /
# `latest_design_unit_binding`) and the deterministic conformance check
# (`design-conform`). `epic-gate.sh plan-batches` is a separate later slice
# and is NOT covered here.
#
# WHAT THIS COVERS, and why each part needs a test of its own:
#
#   1. `qa-gate.sh design-unit-bind` — argument validation ladder, artifact
#      resolution (design_artifact_not_found, design_artifact_outside_spec_
#      dir), and the ONE substantive refusal the binding record exists to
#      prevent: `unit_not_in_artifact` — a binding to a nonexistent unit is
#      worse than none.
#
#   2. The DESIGN-UNIT v1 record grammar and its reader
#      (latest_design_unit_binding): posted ON the implementing task (never
#      on the design-owning task — unlike GRILLING there is no epic-level
#      fallback), carrying `design_task`/`unit_id`/`design_hash` as machine
#      tokens a program reads back, never as free-text prose.
#
#   3. Re-binding (the decision this slice's brief asked to be made
#      explicit): an EXISTING binding on a task refuses a second write with
#      `design_binding_exists` unless `--rebind '<reason>'`; the audited
#      bypass records `[rebind: <reason>]` and DOES overwrite the binding
#      the reader returns.
#
#   4. The bjx scalar-class discipline on `unit_id`
#      (`^[A-Za-z0-9._-]+$`, review-check.sh's OWN schema class, STRICTER
#      than assert_record_scalar's default `[A-Za-z0-9._+-]`): a value
#      outside it is REJECTED, never sanitised, with a METatest proving the
#      early guard is load-bearing (without it, a malformed value still
#      cannot be WRITTEN — the artifact's own membership check catches it
#      first — but the caller gets a less specific, more expensive refusal
#      instead of the immediate, precise one).
#
#   5. `qa-gate.sh design-conform` — the resolution ladder (no binding, or a
#      unit that no longer exists after an amendment, is `unit_not_in_
#      design`; an unsatisfied or stale governing design propagates
#      compute_design_satisfied's OWN key verbatim — design_verdict_missing,
#      design_not_satisfied — rather than re-implementing that predicate)
#      and the undeclared/unbuilt computation itself: an exact match
#      conforms; an extra file is `undeclared_files` (the ONLY failure, exit
#      4, no bypass flag exists); a missing file is `unbuilt` only (reported,
#      never gates); and — the sharp edge this slice's own build surfaced —
#      an absolute-tracker-spelling and a relative-tracker-spelling of the
#      SAME declared file must relativize to the same string and never
#      double-count as both undeclared and unbuilt.
#
#   6. The `.claude/tests/e2e/fixtures/*/.claude/{scripts,beads}/` denylist
#      exclusion this slice's own brief named explicitly: a change under that
#      subtree must never count as undeclared.
#
#   7. A METatest proving the UNDECLARED-FILES-GATE block (not something
#      incidental) is what design-conform's whole gate depends on: strip it
#      from a copy and watch a real scope violation conform instead of
#      refusing, with a CONTROL on the shipped script over the identical
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
# Fixture. Same shape as design-review-record.test.sh / grilling-record.test
# .sh: the real scripts, a real bd, a throwaway project root and HOME.
# `cd "$FIXTURE"` (no subshell) is the FAIL-CLOSED store-isolation mechanism
# this tier requires — BEADS_DIR alone is fail-open. Copies .claude/vendor/
# (design-record's grilling precondition needs it to hash) same as its
# siblings.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t design-conform.XXXXXX)
TEST_HOME=$(mktemp -d -t design-conform-home.XXXXXX)

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
    "$FIXTURE/.claude/vendor/superpowers/brainstorming" \
    "$TEST_HOME/.claude/projects"

cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh
cp "$PLUGIN_DIR/.claude/vendor/superpowers/brainstorming/SKILL.md" \
    "$FIXTURE/.claude/vendor/superpowers/brainstorming/SKILL.md"

if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — design-conform tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — design-conform tests require jq."
    exit 2
fi

REAL_BD=$(command -v bd)
cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"
REAL_JQ=$(command -v jq)
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

seed_grilling() {
    local tid="$1"
    bash "$QG" grilling-record "$tid" --rounds 2 --questions 4 --approaches 2 --unresolved 0 \
        "design-conform.test.sh: seeding the grilling precondition" >/dev/null 2>&1
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

count_binding() {
    comments_of "$1" | grep -cE '^DESIGN-UNIT v1 ' 2>/dev/null | tr -d ' \n'
}

latest_binding_line() {
    comments_of "$1" | grep -E '^DESIGN-UNIT v1 ' | tail -1
}

# write_artifact <path> <task-id> <unit-json-array> — a minimal, schema-valid
# design artifact whose DESIGN-UNITS block is exactly <unit-json-array>
# (a jq array of unit objects), so every section below can vary the
# declared units without hand-writing a fresh heredoc each time.
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

TWO_UNIT_BLOCK='[
  {"unit_id":"U1","role":"devops","goal":"unit one",
   "acceptance":[{"id":"AC1","text":"fixture"}],
   "files":["src/a.sh","src/b.sh"],"verification":"make test","depends_on":[]},
  {"unit_id":"U2","role":"backend","goal":"unit two",
   "acceptance":[{"id":"AC2","text":"fixture"}],
   "files":["src/c.sh"],"verification":"make test","depends_on":["U1"]}
]'

SATISFIED_VERDICT='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'

# checkpoint_git — commit everything accumulated so far in $FIXTURE.
#
# WHY THIS EXISTS, and why every `enter` call in this file is preceded by
# one: `enter` reconciles changed-files.txt against a REPO-WIDE `git status
# --porcelain` (94d), and git's porcelain output reports an entirely
# untracked DIRECTORY as one collapsed `?? dir/` line that reconcile_tracker
# expands to every file beneath it. $FIXTURE is a real git repo (bd init
# creates one) and nothing in this file ever commits, so `docs/specs/`
# accumulates EVERY prior epic's artifact as untracked dirt — invisible to
# the FIRST epic recorded (nothing else exists under docs/ yet) but visible
# to every later one, where design-record's own designer_touched_source
# check correctly (if confusingly, the first time you hit it) refuses to
# bind over paths that are not that epic's own artifact. This is fixture
# hygiene, not a workaround for a defect in the shipped script: a real
# session does not leave N unrelated epics' specs uncommitted and untracked
# at once the way one giant multi-epic test file does.
checkpoint_git() {
    ( cd "$FIXTURE" && git add -A >/dev/null 2>&1 && git commit -q -m "test checkpoint" --allow-empty >/dev/null 2>&1 ) || true
}

# design_and_review <epic-tid> <units-json> — grill, write the artifact,
# design-record it, and design-review-record a SATISFIED verdict against it,
# in one call. Returns (echoes) the live hash on stdout.
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

# ===========================================================================
printf '\n=== Section 1: design-unit-bind — argument validation ladder ===\n'
# ===========================================================================

EPIC1=$(bd create "D4 bind shape epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD1=$(bd create "D4 bind shape child" -t task -p 1 --parent "$EPIC1" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
if [ -z "$EPIC1" ] || [ "$EPIC1" = "null" ] || [ -z "$CHILD1" ] || [ "$CHILD1" = "null" ]; then
    echo "harness error: could not create the epic/child pair"
    exit 2
fi
HASH1=$(design_and_review "$EPIC1" "$TWO_UNIT_BLOCK")

OUT=$(bash "$QG" design-unit-bind 2>/dev/null); EXIT_RC=$?
assert_eq "1.1 no task id: exit 1" "1" "$EXIT_RC"
assert_eq "1.1b ...error_key=missing_task_id" "missing_task_id" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" design-unit-bind "$CHILD1" --unit-id U1 2>&1)
assert_eq "1.2 missing --design-task: missing_design_task" "missing_design_task" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC1" 2>&1)
assert_eq "1.3 missing --unit-id: missing_unit_id" "missing_unit_id" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC1" --unit-id U1 --rebind 2>&1)
assert_eq "1.4 --rebind with no reason: missing_rebind_reason" "missing_rebind_reason" "$(json_field '.error_key' "$OUT")"

assert_eq "1.5 none of the above wrote a DESIGN-UNIT record" "0" "$(count_binding "$CHILD1")"

# ===========================================================================
printf '\n=== Section 2: design-unit-bind — artifact resolution + membership ===\n'
# ===========================================================================

OUT=$(bash "$QG" design-unit-bind "$CHILD1" --design-task "does-not-exist-$$" --unit-id U1 2>&1)
assert_eq "2.1 --design-task names a task with no artifact: design_artifact_not_found" \
    "design_artifact_not_found" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC1" --unit-id U99 2>&1); EXIT_RC=$?
assert_eq "2.2 --unit-id names a unit the artifact does not declare: exit 1" "1" "$EXIT_RC"
assert_eq "2.2b ...error_key=unit_not_in_artifact" "unit_not_in_artifact" "$(json_field '.error_key' "$OUT")"
assert_contains "2.2c ...names the declared units so the caller can see what IS valid" "U1, U2" "$OUT"
assert_eq "2.2d non-vacuity: nothing was recorded on the refusal" "0" "$(count_binding "$CHILD1")"

OUT=$(bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC1" --unit-id U1 "bound to unit one" 2>&1)
assert_eq "2.3 a valid bind: recorded" "recorded" "$(json_field '.status' "$OUT")"
assert_eq "2.3b exactly one DESIGN-UNIT record now exists" "1" "$(count_binding "$CHILD1")"

REC=$(latest_binding_line "$CHILD1")
assert_contains "2.4 the record carries task=<the implementing task>" "task=$CHILD1 " "$REC"
assert_contains "2.5 ...design_task=<the design-owning task>" "design_task=$EPIC1 " "$REC"
assert_contains "2.6 ...unit_id=U1" "unit_id=U1 " "$REC"
assert_contains "2.7 ...design_hash=<the live artifact hash>" "design_hash=$HASH1 " "$REC"
assert_contains "2.8 ...the free-text summary" "bound to unit one" "$REC"

# latest_design_unit_binding is not called directly here (this tier drives
# subcommands, not internal functions) — it is exercised end to end through
# design-conform's own resolution ladder in Sections 5-7 below, which
# depends entirely on it to resolve design_task/unit_id. This section
# confirms the ONE property specific to THIS record and not to the reader's
# general shape: a binding is per-IMPLEMENTING-TASK, with NO parent-epic
# fallback (unlike GRILLING) — a sibling child with no binding of its own
# must not see CHILD1's.
SIBLING=$(bd create "D4 bind: unbound sibling" -t task -p 1 --parent "$EPIC1" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
assert_eq "2.9 a SIBLING task under the SAME epic, never itself bound: carries zero DESIGN-UNIT records (no epic-level fallback)" \
    "0" "$(count_binding "$SIBLING")"

# ===========================================================================
printf '\n=== Section 3: re-binding — the decision this slice makes explicit ===\n'
# ===========================================================================

BEFORE=$(count_binding "$CHILD1")
OUT=$(bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC1" --unit-id U2 2>&1); EXIT_RC=$?
assert_eq "3.1 re-binding WITHOUT --rebind: exit 1" "1" "$EXIT_RC"
assert_eq "3.1b ...error_key=design_binding_exists" "design_binding_exists" "$(json_field '.error_key' "$OUT")"
assert_contains "3.1c ...names the EXISTING unit_id" "unit_id=U1" "$OUT"
AFTER=$(count_binding "$CHILD1")
assert_eq "3.1d non-vacuity: record count is unchanged (nothing written)" "$BEFORE" "$AFTER"

OUT=$(bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC1" --unit-id U2 --rebind "re-plan: this task now covers U2" 2>&1)
assert_eq "3.2 re-binding WITH --rebind: recorded" "recorded" "$(json_field '.status' "$OUT")"
assert_eq "3.2b a SECOND DESIGN-UNIT record now exists (append-only)" "2" "$(count_binding "$CHILD1")"

LATEST=$(latest_binding_line "$CHILD1")
assert_contains "3.2c the LATEST record carries unit_id=U2" "unit_id=U2 " "$LATEST"
assert_contains "3.2d ...and the audited [rebind: <reason>] marker" \
    "[rebind: re-plan: this task now covers U2]" "$LATEST"

# Rebind back to U1 so later sections have a stable, known binding.
bash "$QG" design-unit-bind "$CHILD1" --design-task "$EPIC1" --unit-id U1 --rebind "back to U1 for the rest of this file" >/dev/null 2>&1

# ===========================================================================
printf '\n=== Section 4: the bjx unit_id scalar-class discipline ===\n'
# ===========================================================================

CHILD_BAD=$(bd create "D4 bad unit_id child" -t task -p 1 --parent "$EPIC1" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" design-unit-bind "$CHILD_BAD" --design-task "$EPIC1" --unit-id "U1 evil" 2>&1); EXIT_RC=$?
assert_eq "4.1 unit_id containing a space: exit 1" "1" "$EXIT_RC"
assert_eq "4.1b ...error_key=unit_id_invalid_chars (REJECTED, not sanitised)" \
    "unit_id_invalid_chars" "$(json_field '.error_key' "$OUT")"
assert_eq "4.1c ...nothing was recorded" "0" "$(count_binding "$CHILD_BAD")"

OUT=$(bash "$QG" design-unit-bind "$CHILD_BAD" --design-task "$EPIC1" --unit-id "U1:evil" 2>&1)
assert_eq "4.2 unit_id containing a colon: ALSO unit_id_invalid_chars" \
    "unit_id_invalid_chars" "$(json_field '.error_key' "$OUT")"

# --- METatest: remove BOTH occurrences of the guard line -------------------
# Two occurrences by design (Section 1's own header explains why): the early
# fail-fast, and the write-section defense-in-depth. A single-line mutation
# (not a sentinel region — this guard has none of its own) targets the exact
# source text, proven non-vacuous by a before/after grep count rather than
# assumed.
# shellcheck disable=SC2016  # single-quoted deliberately: this is the
# LITERAL source text to grep/sed for, not an expression to expand.
# QA round 2, R2-F5: this assertion USED TO hardcode "2" as if it were a
# claim about the total population of assert_unit_id_scalar call sites in
# qa-gate.sh. It never was one — MUT_LINE is subcommand-qualified
# ("design-unit-bind" is the literal first argument), so it can only ever
# match design-unit-bind's own two call sites (the early fail-fast and the
# write-section defense-in-depth, per Section 1's header) — REGARDLESS of
# how many OTHER subcommands also call assert_unit_id_scalar with their own,
# differently-named first argument (design-conflict's one call site;
# green-check's, added in fkm.7 D5 piece 3 and the reason this survived only
# "by luck" per QA — a needle that happened to stay subcommand-scoped, not a
# guard that was actually counting the shared idiom's total population). The
# fix is not a re-count: it is asserting what was always true, a
# COUNT-INDEPENDENT non-vacuity check (there is at least one line to
# mutate), rather than the population claim the old wording implied.
MUT_LINE='assert_unit_id_scalar "design-unit-bind" "$tid" "unit_id" "$unit_id"'
GREP_BEFORE=$(grep -cF "$MUT_LINE" "$QG")
assert_eq "4.3 NON-VACUITY: design-unit-bind's own (subcommand-qualified) guard line exists at least once in the shipped script" \
    "true" "$([ "$GREP_BEFORE" -gt 0 ] 2>/dev/null && echo true || echo false)"
sed "\\|$MUT_LINE|d" "$QG" > "$FIXTURE/.claude/scripts/qa-gate-nounitidguard.sh"
GREP_AFTER=$(grep -cF "$MUT_LINE" "$FIXTURE/.claude/scripts/qa-gate-nounitidguard.sh")
# QA round 3, R3-F6: this message used to read "both occurrences were
# actually removed", baking in a population claim (exactly 2) the R2-F5 fix
# above deliberately moved away from -- the assertion itself (GREP_AFTER==0)
# was always count-independent (zero remain, whatever the original count
# was); only the wording still implied otherwise.
assert_eq "4.3b META: no occurrences of the guard line remain in the mutant" "0" "$GREP_AFTER"
chmod +x "$FIXTURE/.claude/scripts/qa-gate-nounitidguard.sh"
NG_PARSE_RC=0
bash -n "$FIXTURE/.claude/scripts/qa-gate-nounitidguard.sh" 2>/dev/null || NG_PARSE_RC=$?
assert_eq "4.3c META: the no-guard copy still parses" "0" "$NG_PARSE_RC"
BYTE_DIFF=$(cmp -s "$QG" "$FIXTURE/.claude/scripts/qa-gate-nounitidguard.sh" && echo same || echo differ)
assert_eq "4.3d META: the mutant's bytes actually differ from the shipped script" "differ" "$BYTE_DIFF"

CHILD_MUT=$(bd create "D4 no-guard mutant child" -t task -p 1 --parent "$EPIC1" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
MUT_OUT=$(bash "$FIXTURE/.claude/scripts/qa-gate-nounitidguard.sh" design-unit-bind "$CHILD_MUT" --design-task "$EPIC1" --unit-id "U1 evil" 2>&1)
assert_eq "4.3e MISBEHAVIOUR: WITHOUT the class check, the malformed --unit-id is refused ANYWAY, but ONLY by the membership check (a DIFFERENT, more expensive, less specific path — 'U1 evil' can never be a real declared unit)" \
    "unit_not_in_artifact" "$(json_field '.error_key' "$MUT_OUT")"
assert_eq "4.3f ...and still nothing was recorded (the membership check remains a real backstop)" "0" "$(count_binding "$CHILD_MUT")"

CTRL_OUT=$(bash "$QG" design-unit-bind "$CHILD_MUT" --design-task "$EPIC1" --unit-id "U1 evil" 2>&1)
assert_eq "4.3g CONTROL: the SHIPPED script gives the precise, cheap refusal for the SAME input" \
    "unit_id_invalid_chars" "$(json_field '.error_key' "$CTRL_OUT")"
rm -f "$FIXTURE/.claude/scripts/qa-gate-nounitidguard.sh"

# ===========================================================================
printf '\n=== Section 5: design-conform — the resolution ladder ===\n'
# ===========================================================================

FRESH=$(bd create "D4 conform: never bound" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" design-conform "$FRESH" 2>&1); EXIT_RC=$?
assert_eq "5.1 a task with NO DESIGN-UNIT binding at all: exit 4" "4" "$EXIT_RC"
assert_eq "5.1b ...error_key=unit_not_in_design" "unit_not_in_design" "$(json_field '.error_key' "$OUT")"

EPIC2=$(bd create "D4 conform: unreviewed design epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD2=$(bd create "D4 conform: unreviewed design child" -t task -p 1 --parent "$EPIC2" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
seed_grilling "$EPIC2"
ART2="$FIXTURE/docs/specs/$EPIC2.md"
write_artifact "$ART2" "$EPIC2" "$TWO_UNIT_BLOCK"
printf '%s\n' "$ART2" > "$TRACKING"
checkpoint_git
bash "$QG" enter "$EPIC2" >/dev/null 2>&1
bash "$QG" design-record "$EPIC2" >/dev/null 2>&1
bash "$QG" design-unit-bind "$CHILD2" --design-task "$EPIC2" --unit-id U1 >/dev/null 2>&1
OUT=$(bash "$QG" design-conform "$CHILD2" 2>&1); EXIT_RC=$?
assert_eq "5.2 bound, but the governing design was never REVIEWED: exit 4" "4" "$EXIT_RC"
assert_eq "5.2b ...error_key=design_verdict_missing (compute_design_satisfied's OWN key, propagated verbatim)" \
    "design_verdict_missing" "$(json_field '.error_key' "$OUT")"

HASH2=$(bash "$WM" hash-file "$ART2")
NEEDS_REV='{"verdict":"needs_revision","criterion_results":[{"criterion":"DS1","pass":false,"justification":"no"}],"required_fixes":["revise"],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'
printf '%s' "$NEEDS_REV" | bash "$QG" design-review-record "$EPIC2" --design-hash "$HASH2" >/dev/null 2>&1
OUT=$(bash "$QG" design-conform "$CHILD2" 2>&1); EXIT_RC=$?
assert_eq "5.3 bound, governing design reviewed but needs_revision: exit 4" "4" "$EXIT_RC"
assert_eq "5.3b ...error_key=design_not_satisfied (propagated, not re-derived)" \
    "design_not_satisfied" "$(json_field '.error_key' "$OUT")"

# --- an amendment that renames the bound unit_id: unit_not_in_design ------
EPIC3=$(bd create "D4 conform: amendment epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD3=$(bd create "D4 conform: amendment child" -t task -p 1 --parent "$EPIC3" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
ONE_UNIT_U1='[{"unit_id":"U1","role":"devops","goal":"unit one",
  "acceptance":[{"id":"AC1","text":"fixture"}],
  "files":["src/a.sh"],"verification":"make test","depends_on":[]}]'
design_and_review "$EPIC3" "$ONE_UNIT_U1" >/dev/null
bash "$QG" design-unit-bind "$CHILD3" --design-task "$EPIC3" --unit-id U1 >/dev/null 2>&1

ART3="$FIXTURE/docs/specs/$EPIC3.md"
printf '\n<!-- v2: renamed U1 -> U1B -->\n' >> "$ART3"
ONE_UNIT_RENAMED='[{"unit_id":"U1B","role":"devops","goal":"unit one, renamed",
  "acceptance":[{"id":"AC1","text":"fixture"}],
  "files":["src/a.sh"],"verification":"make test","depends_on":[]}]'
# Rewrite the DESIGN-UNITS block in place to the renamed shape.
write_artifact "$ART3" "$EPIC3" "$ONE_UNIT_RENAMED"
printf '%s\n' "$ART3" > "$TRACKING"
checkpoint_git
bash "$QG" enter "$EPIC3" >/dev/null 2>&1
bash "$QG" design-record "$EPIC3" >/dev/null 2>&1
HASH3B=$(bash "$WM" hash-file "$ART3")
AMEND_VERDICT=$(printf '%s' "$SATISFIED_VERDICT" | jq -c '.iteration=2')
printf '%s' "$AMEND_VERDICT" | bash "$QG" design-review-record "$EPIC3" --design-hash "$HASH3B" >/dev/null 2>&1

OUT=$(bash "$QG" design-conform "$CHILD3" 2>&1); EXIT_RC=$?
assert_eq "5.4 the bound unit_id (U1) was renamed away by an amendment: exit 4" "4" "$EXIT_RC"
assert_eq "5.4b ...error_key=unit_not_in_design (governing design IS satisfied — only the unit vanished)" \
    "unit_not_in_design" "$(json_field '.error_key' "$OUT")"
assert_contains "5.4c ...names the bound unit_id so a human can see what to re-bind" "unit_id=U1 " "$OUT"

# ===========================================================================
printf '\n=== Section 6: design-conform — undeclared / unbuilt ===\n'
# ===========================================================================

EPIC4=$(bd create "D4 conform: undeclared/unbuilt epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD4=$(bd create "D4 conform: undeclared/unbuilt child" -t task -p 1 --parent "$EPIC4" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC4" "$TWO_UNIT_BLOCK" >/dev/null
bash "$QG" design-unit-bind "$CHILD4" --design-task "$EPIC4" --unit-id U1 >/dev/null 2>&1
# U1 declares src/a.sh + src/b.sh.

: > "$TRACKING"
OUT=$(bash "$QG" design-conform "$CHILD4" 2>&1); EXIT_RC=$?
assert_eq "6.1 nothing touched yet: conforms (rc 0)" "0" "$EXIT_RC"
assert_eq "6.1b ok=true" "true" "$(json_field '.ok' "$OUT")"
assert_eq "6.1c undeclared_files is empty" "0" "$(json_field '.undeclared_files | length' "$OUT")"
assert_eq "6.1d unbuilt_files names BOTH declared files (nothing built yet)" \
    "2" "$(json_field '.unbuilt_files | length' "$OUT")"

mkdir -p "$FIXTURE/src"
touch "$FIXTURE/src/a.sh" "$FIXTURE/src/b.sh"
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
printf 'src/b.sh\n' >> "$TRACKING"
OUT=$(bash "$QG" design-conform "$CHILD4" 2>&1); EXIT_RC=$?
assert_eq "6.2 the EXACT declared set touched, one ABSOLUTE-spelled + one RELATIVE-spelled: conforms (rc 0)" "0" "$EXIT_RC"
assert_eq "6.2b ok=true" "true" "$(json_field '.ok' "$OUT")"
assert_eq "6.2c undeclared_files is empty — the absolute spelling relativized to the SAME string as the declared entry, not a foreign extra" \
    "0" "$(json_field '.undeclared_files | length' "$OUT")"
assert_eq "6.2d unbuilt_files is empty (both declared files were touched)" \
    "0" "$(json_field '.unbuilt_files | length' "$OUT")"

touch "$FIXTURE/src/z-not-declared.sh"
printf 'src/z-not-declared.sh\n' >> "$TRACKING"
OUT=$(bash "$QG" design-conform "$CHILD4" 2>&1); EXIT_RC=$?
assert_eq "6.3 an EXTRA, undeclared file: exit 4" "4" "$EXIT_RC"
assert_eq "6.3b ...error_key=undeclared_files" "undeclared_files" "$(json_field '.error_key' "$OUT")"
assert_eq "6.3c ...undeclared_files names exactly the one extra path" \
    "src/z-not-declared.sh" "$(json_field '.undeclared_files[0]' "$OUT")"
assert_contains "6.3d ...observations name BOTH remedies and NO overrule path" \
    "No overrule path" "$OUT"

# Missing (declared but not touched) does NOT gate.
: > "$TRACKING"
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
OUT=$(bash "$QG" design-conform "$CHILD4" 2>&1); EXIT_RC=$?
assert_eq "6.4 only ONE of two declared files touched: still conforms (unbuilt never gates)" "0" "$EXIT_RC"
assert_eq "6.4b unbuilt_files names the untouched declared file" \
    "src/b.sh" "$(json_field '.unbuilt_files[0]' "$OUT")"

# --- the denylist exclusion this slice's brief names explicitly -----------
mkdir -p "$FIXTURE/.claude/tests/e2e/fixtures/somefixture/.claude/scripts"
touch "$FIXTURE/.claude/tests/e2e/fixtures/somefixture/.claude/scripts/mirrored.sh"
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
printf 'src/b.sh\n' >> "$TRACKING"
printf '.claude/tests/e2e/fixtures/somefixture/.claude/scripts/mirrored.sh\n' >> "$TRACKING"
OUT=$(bash "$QG" design-conform "$CHILD4" 2>&1); EXIT_RC=$?
assert_eq "6.5 a change under .claude/tests/e2e/fixtures/*/.claude/scripts/ is denylisted: still conforms" "0" "$EXIT_RC"
assert_eq "6.5b ...undeclared_files is empty (the fixture-mirror path never counted)" \
    "0" "$(json_field '.undeclared_files | length' "$OUT")"

# --- R1-F3 (review round 1): the removed-directory case is now
# RESOLVED, not just pinned. relativize_for_impact's own `[ -d "$dir" ]`
# guard still declines a path whose containing directory no longer exists,
# but impact-report.sh's own --relativized-changed-files now recovers it
# with a direct $PROJECT_DIR-prefix strip (absolute spelling) or by passing
# an already-relative spelling through unchanged (reconcile_tracker's own
# shape) — neither needs the directory to exist. Both sub-cases below used
# to read as undeclared_files; both now conform.
rm -rf "$FIXTURE/src"
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
printf 'src/b.sh\n' >> "$TRACKING"
OUT=$(bash "$QG" design-conform "$CHILD4" 2>&1); EXIT_RC=$?
assert_eq "6.6 a declared file whose directory was removed (absolute spelling): now CONFORMS (R1-F3 fix)" "0" "$EXIT_RC"
assert_eq "6.6b ...ok=true" "true" "$(json_field '.ok' "$OUT")"
assert_eq "6.6c ...undeclared_files is empty" "0" "$(json_field '.undeclared_files | length' "$OUT")"

: > "$TRACKING"
printf 'src/a.sh\n' > "$TRACKING"
printf 'src/b.sh\n' >> "$TRACKING"
OUT=$(bash "$QG" design-conform "$CHILD4" 2>&1); EXIT_RC=$?
assert_eq "6.6d the SAME case, both entries ALREADY relative (directory still removed): also CONFORMS" "0" "$EXIT_RC"
assert_eq "6.6e ...ok=true" "true" "$(json_field '.ok' "$OUT")"
mkdir -p "$FIXTURE/src"
touch "$FIXTURE/src/a.sh" "$FIXTURE/src/b.sh"

# --- what remains genuinely unnormalisable gets its OWN error key, never
# folded into undeclared_files (R1-F3's other half): a path that is
# ABSOLUTE, NOT a sibling-worktree match, and NOT under $PROJECT_DIR either
# — the residual relativize_for_impact truly cannot resolve.
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
printf 'src/b.sh\n' >> "$TRACKING"
printf '/some/totally/unrelated/repo/file.sh\n' >> "$TRACKING"
OUT=$(bash "$QG" design-conform "$CHILD4" 2>&1); EXIT_RC=$?
assert_eq "6.7 a genuinely foreign absolute path: exit 4" "4" "$EXIT_RC"
assert_eq "6.7b ...error_key=change_set_path_unnormalizable (DISTINCT from undeclared_files and change_set_unreadable)" \
    "change_set_path_unnormalizable" "$(json_field '.error_key' "$OUT")"
assert_contains "6.7c ...names the remedy, not just the fact" "Remedy:" "$OUT"
: > "$TRACKING"
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
printf 'src/b.sh\n' >> "$TRACKING"

# ===========================================================================
printf '\n=== Section 7: META — the UNDECLARED-FILES-GATE block is load-bearing ===\n'
# ===========================================================================

: > "$TRACKING"
QG_NOGATE="$FIXTURE/.claude/scripts/qa-gate-noconformgate.sh"
STRIP_RC=0
awk '
    /# UNDECLARED-FILES-GATE BEGIN/ { skipping=1; found=1; next }
    /# UNDECLARED-FILES-GATE END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_NOGATE" || STRIP_RC=$?
chmod +x "$QG_NOGATE"
assert_eq "7.1a META: UNDECLARED-FILES-GATE sentinels are present (the strip found them)" "0" "$STRIP_RC"

PARSE_RC=0
bash -n "$QG_NOGATE" 2>/dev/null || PARSE_RC=$?
assert_eq "7.1b META: the stripped copy still parses" "0" "$PARSE_RC"

BYTE_DIFF=$(cmp -s "$QG" "$QG_NOGATE" && echo same || echo differ)
assert_eq "7.1c META: the mutant's bytes actually differ from the shipped script" "differ" "$BYTE_DIFF"

# Reproduce 6.3's REAL scope violation (an undeclared extra file) against
# the MUTANT.
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
printf 'src/b.sh\n' >> "$TRACKING"
printf 'src/z-not-declared.sh\n' >> "$TRACKING"
MUT_OUT=$(bash "$QG_NOGATE" design-conform "$CHILD4" 2>&1); MUT_RC=$?
assert_eq "7.1d MISBEHAVIOUR: WITHOUT the gate, a task that touched an undeclared file CONFORMS (exit 0)" "0" "$MUT_RC"
assert_eq "7.1e ...ok=true over a real, uncaught scope violation" "true" "$(json_field '.ok' "$MUT_OUT")"

CTRL_OUT=$(bash "$QG" design-conform "$CHILD4" 2>&1); CTRL_RC=$?
assert_eq "7.1f CONTROL: the SHIPPED script refuses the SAME state the mutant just let through" "4" "$CTRL_RC"
assert_eq "7.1g ...error_key=undeclared_files" "undeclared_files" "$(json_field '.error_key' "$CTRL_OUT")"
rm -f "$QG_NOGATE"

# ===========================================================================
printf '\n=== Section 8: degrade honestly — tool-unavailable + the TOCTOU bracket ===\n'
# ===========================================================================
# Each leg MOVES the actual dependency the fixture relies on, runs the
# shipped subcommand, then restores it immediately (the restore doubling as
# this leg's own CONTROL — the SAME task state, tool present, succeeds) so no
# later section is affected. Mirrors grilling-record.test.sh Section 6's
# exact shape for the identical reason: these refusals fired during
# development but need a pinned assertion, not just a code path.

EPIC8=$(bd create "D4 conform: degradation epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD8=$(bd create "D4 conform: degradation child" -t task -p 1 --parent "$EPIC8" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC8" "$ONE_UNIT_U1" >/dev/null
# Isolate this section's design-conform calls from whatever Section 7 left
# in the tracker: exactly ONE_UNIT_U1's own declared file, real on disk, so
# every design-conform call below in Section 8 conforms cleanly whenever the
# tool it is testing IS present — the thing this section actually tests is
# tool availability, not the undeclared/unbuilt computation (already covered
# by Section 6).
mkdir -p "$FIXTURE/src"
touch "$FIXTURE/src/a.sh"
printf 'src/a.sh\n' > "$TRACKING"

WM_MOVED="$WM.movedaway"
mv "$WM" "$WM_MOVED"
OUT=$(bash "$QG" design-unit-bind "$CHILD8" --design-task "$EPIC8" --unit-id U1 2>&1); EXIT_RC=$?
assert_eq "8.1 design-unit-bind, workflow-manifest.sh missing: exit 2" "2" "$EXIT_RC"
assert_eq "8.1b ...error_key=hash_tool_unavailable" "hash_tool_unavailable" "$(json_field '.error_key' "$OUT")"
assert_eq "8.1c ...nothing recorded" "0" "$(count_binding "$CHILD8")"
mv "$WM_MOVED" "$WM"
assert_eq "8.1d CONTROL: restoring workflow-manifest.sh lets the SAME bind succeed" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-unit-bind "$CHILD8" --design-task "$EPIC8" --unit-id U1 2>&1)")"

RC_MOVED="$RC.movedaway"
mv "$RC" "$RC_MOVED"
CHILD8B=$(bd create "D4 conform: degradation child B" -t task -p 1 --parent "$EPIC8" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" design-unit-bind "$CHILD8B" --design-task "$EPIC8" --unit-id U1 2>&1); RC_STATUS=$?
assert_eq "8.2 design-unit-bind, review-check.sh missing: exit 2" "2" "$RC_STATUS"
assert_eq "8.2b ...error_key=validator_unavailable" "validator_unavailable" "$(json_field '.error_key' "$OUT")"
assert_eq "8.2c ...nothing recorded" "0" "$(count_binding "$CHILD8B")"
mv "$RC_MOVED" "$RC"
assert_eq "8.2d CONTROL: restoring review-check.sh lets the SAME bind succeed" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-unit-bind "$CHILD8B" --design-task "$EPIC8" --unit-id U1 2>&1)")"

mv "$RC" "$RC_MOVED"
OUT=$(bash "$QG" design-conform "$CHILD8" 2>&1); RC_STATUS=$?
assert_eq "8.3 design-conform, review-check.sh missing: exit 2" "2" "$RC_STATUS"
assert_eq "8.3b ...error_key=validator_unavailable" "validator_unavailable" "$(json_field '.error_key' "$OUT")"
mv "$RC_MOVED" "$RC"
assert_eq "8.3c CONTROL: restoring review-check.sh lets the SAME conform run again" "true" \
    "$(json_field '.ok' "$(bash "$QG" design-conform "$CHILD8" 2>&1)")"

IR_MOVED="$IR.movedaway"
mv "$IR" "$IR_MOVED"
OUT=$(bash "$QG" design-conform "$CHILD8" 2>&1); RC_STATUS=$?
assert_eq "8.4 design-conform, impact-report.sh missing: exit 2" "2" "$RC_STATUS"
assert_eq "8.4b ...error_key=impact_tool_unavailable" "impact_tool_unavailable" "$(json_field '.error_key' "$OUT")"
mv "$IR_MOVED" "$IR"
assert_eq "8.4c CONTROL: restoring impact-report.sh lets the SAME conform run again" "true" \
    "$(json_field '.ok' "$(bash "$QG" design-conform "$CHILD8" 2>&1)")"

# --- jq_unavailable: a jq-less PATH built by hand, per worktree-sweep.test.sh
# A16's own precedent and its own reasoning — PATH=/usr/bin:/bin is NOT
# jq-less on a modern macOS or Linux runner, so the restricted PATH is
# assembled from symlinks to the real binaries this call chain needs, minus
# jq, and the absence is asserted as a precondition before the behaviour.
NOJQ_BIN="$FIXTURE/nojq-bin"
mkdir -p "$NOJQ_BIN"
for b in bash bd git sed awk grep cut head tail tr cmp date mkdir cp mv \
         dirname basename readlink realpath sort wc shasum sha256sum; do
    bp=$(command -v "$b" 2>/dev/null) && ln -sf "$bp" "$NOJQ_BIN/$b"
done
assert_eq "8.5 precondition: the restricted PATH really has no jq" "yes" \
    "$(PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1 && echo no || echo yes)"
NOJQ_OUT=$(PATH="$NOJQ_BIN" CLAUDE_PROJECT_DIR="$FIXTURE" HOME="$TEST_HOME" "$NOJQ_BIN/bash" "$QG" design-conform "$CHILD8" 2>&1); NOJQ_RC=$?
assert_eq "8.5b design-conform on a jq-less PATH: exit 2" "2" "$NOJQ_RC"
assert_eq "8.5c ...error_key=jq_unavailable" "jq_unavailable" "$(json_field '.error_key' "$NOJQ_OUT")"
assert_eq "8.5d CONTROL: the SAME task, jq back on PATH, runs again" "true" \
    "$(json_field '.ok' "$(bash "$QG" design-conform "$CHILD8" 2>&1)")"

# --- THE TOCTOU BRACKET (design_artifact_changed_during_bind) --------------
# Same technique as design-artifact.test.sh 6.6 for design-record's own
# read window: a shim installed AT review-check.sh's PATH runs the REAL
# validator, then rewrites the artifact before returning — so the write
# lands deterministically inside the exact window the bracket exists to
# close. qa-gate.sh itself is UNMODIFIED.
EPIC9=$(bd create "D4 conform: TOCTOU epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD9=$(bd create "D4 conform: TOCTOU child" -t task -p 1 --parent "$EPIC9" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC9" "$ONE_UNIT_U1" >/dev/null
ART9="$FIXTURE/docs/specs/$EPIC9.md"
PRE_SWAP_HASH=$(bash "$WM" hash-file "$ART9")
cp "$RC" "$FIXTURE/.claude/scripts/review-check.real.sh"
cat > "$RC" <<SHIM
#!/bin/bash
out=\$(bash "$FIXTURE/.claude/scripts/review-check.real.sh" "\$@"); rc=\$?
if [ "\${1:-}" = "validate-design" ]; then
    printf '%s\n<!-- swapped mid-bind -->\n' "\$(cat "$ART9")" > "$ART9"
fi
printf '%s\n' "\$out"
exit \$rc
SHIM
chmod +x "$RC"
TOC_OUT=$(bash "$QG" design-unit-bind "$CHILD9" --design-task "$EPIC9" --unit-id U1 2>&1)
# $WM (workflow-manifest.sh) was never touched by the shim above — only
# review-check.sh ($RC) was — so it is still the real hasher here.
POST_SWAP_HASH=$(bash "$WM" hash-file "$ART9" 2>/dev/null)
assert_eq "8.6 precondition: the shim really did rewrite the artifact inside the window" "differ" \
    "$([ "$PRE_SWAP_HASH" != "$POST_SWAP_HASH" ] && echo differ || echo same)"
assert_eq "8.6b the bind is REFUSED when the artifact moves during it" \
    "design_artifact_changed_during_bind" "$(json_field '.error_key' "$TOC_OUT")"
assert_eq "8.6c ...and NOTHING is recorded, so no design-conform can corroborate the unvalidated bytes" \
    "0" "$(count_binding "$CHILD9")"
# CONTROL: restore the real validator, restore the artifact, confirm the
# SAME bind now succeeds — the refusal above was caused by the write, not by
# an unrelated defect the shim happened to also trigger.
cp "$FIXTURE/.claude/scripts/review-check.real.sh" "$RC"
rm -f "$FIXTURE/.claude/scripts/review-check.real.sh"
write_artifact "$ART9" "$EPIC9" "$ONE_UNIT_U1"
printf '%s\n' "$ART9" > "$TRACKING"
checkpoint_git
bash "$QG" enter "$EPIC9" >/dev/null 2>&1
bash "$QG" design-record "$EPIC9" >/dev/null 2>&1
HASH9=$(bash "$WM" hash-file "$ART9")
FRESH_VERDICT=$(printf '%s' "$SATISFIED_VERDICT" | jq -c '.iteration=1')
printf '%s' "$FRESH_VERDICT" | bash "$QG" design-review-record "$EPIC9" --design-hash "$HASH9" >/dev/null 2>&1
CTRL9_OUT=$(bash "$QG" design-unit-bind "$CHILD9" --design-task "$EPIC9" --unit-id U1 2>&1)
assert_eq "8.6d CONTROL: the real validator, no swap: the same bind records normally" \
    "recorded" "$(json_field '.status' "$CTRL9_OUT")"

# ===========================================================================
printf '\n=== Section 9: META — design-unit-bind'"'"'s two remaining gates are load-bearing ===\n'
# ===========================================================================
# Sections 2.2 and 3.1 already assert the SHIPPED behaviour of
# unit_not_in_artifact and design_binding_exists directly. This section adds
# the mutation leg those assertions do not: proof that each refusal is
# CAUSED by its own sentinel-wrapped block, not by something incidental.

EPIC10=$(bd create "D4 bind: gate-9 epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC10" "$ONE_UNIT_U1" >/dev/null

# --- 9.1: UNIT-MEMBERSHIP-GATE ---------------------------------------------
QG_NOMEMBER="$FIXTURE/.claude/scripts/qa-gate-nomembergate.sh"
STRIP9_RC=0
awk '
    /# UNIT-MEMBERSHIP-GATE BEGIN/ { skipping=1; found=1; next }
    /# UNIT-MEMBERSHIP-GATE END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_NOMEMBER" || STRIP9_RC=$?
chmod +x "$QG_NOMEMBER"
assert_eq "9.1a META: UNIT-MEMBERSHIP-GATE sentinels are present (the strip found them)" "0" "$STRIP9_RC"
P9A_RC=0
bash -n "$QG_NOMEMBER" 2>/dev/null || P9A_RC=$?
assert_eq "9.1b META: the stripped copy still parses" "0" "$P9A_RC"
D9A=$(cmp -s "$QG" "$QG_NOMEMBER" && echo same || echo differ)
assert_eq "9.1c META: the mutant's bytes actually differ from the shipped script" "differ" "$D9A"

CHILD10=$(bd create "D4 bind: gate-9 nonexistent-unit child" -t task -p 1 --parent "$EPIC10" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
MUT9A_OUT=$(bash "$QG_NOMEMBER" design-unit-bind "$CHILD10" --design-task "$EPIC10" --unit-id U99-DOES-NOT-EXIST 2>&1)
assert_eq "9.1d MISBEHAVIOUR: WITHOUT the gate, binding to a unit the artifact never declared RECORDS anyway" \
    "recorded" "$(json_field '.status' "$MUT9A_OUT")"
assert_eq "9.1e ...and it is a REAL record, not a dry run" "1" "$(count_binding "$CHILD10")"

CTRL10=$(bd create "D4 bind: gate-9 nonexistent-unit control" -t task -p 1 --parent "$EPIC10" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
CTRL9A_OUT=$(bash "$QG" design-unit-bind "$CTRL10" --design-task "$EPIC10" --unit-id U99-DOES-NOT-EXIST 2>&1)
assert_eq "9.1f CONTROL: the SHIPPED script refuses the SAME nonexistent unit_id the mutant just recorded" \
    "unit_not_in_artifact" "$(json_field '.error_key' "$CTRL9A_OUT")"
rm -f "$QG_NOMEMBER"

# --- 9.2: REBIND-GATE -------------------------------------------------------
QG_NOREBIND="$FIXTURE/.claude/scripts/qa-gate-norebindgate.sh"
STRIP9B_RC=0
awk '
    /# REBIND-GATE BEGIN/ { skipping=1; found=1; next }
    /# REBIND-GATE END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_NOREBIND" || STRIP9B_RC=$?
chmod +x "$QG_NOREBIND"
assert_eq "9.2a META: REBIND-GATE sentinels are present (the strip found them)" "0" "$STRIP9B_RC"
P9B_RC=0
bash -n "$QG_NOREBIND" 2>/dev/null || P9B_RC=$?
assert_eq "9.2b META: the stripped copy still parses" "0" "$P9B_RC"
D9B=$(cmp -s "$QG" "$QG_NOREBIND" && echo same || echo differ)
assert_eq "9.2c META: the mutant's bytes actually differ from the shipped script" "differ" "$D9B"

CHILD11=$(bd create "D4 bind: gate-9 silent-rebind child" -t task -p 1 --parent "$EPIC10" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
bash "$QG" design-unit-bind "$CHILD11" --design-task "$EPIC10" --unit-id U1 >/dev/null 2>&1
BEFORE9B=$(count_binding "$CHILD11")
MUT9B_OUT=$(bash "$QG_NOREBIND" design-unit-bind "$CHILD11" --design-task "$EPIC10" --unit-id U1 2>&1)
assert_eq "9.2d MISBEHAVIOUR: WITHOUT the gate, a SECOND bind with no --rebind records anyway (silent re-binding)" \
    "recorded" "$(json_field '.status' "$MUT9B_OUT")"
AFTER9B=$(count_binding "$CHILD11")
assert_eq "9.2e ...and a NEW record really landed (count advanced)" "$((BEFORE9B + 1))" "$AFTER9B"

CTRL9B_OUT=$(bash "$QG" design-unit-bind "$CHILD11" --design-task "$EPIC10" --unit-id U1 2>&1)
assert_eq "9.2f CONTROL: the SHIPPED script refuses the SAME second bind the mutant just recorded" \
    "design_binding_exists" "$(json_field '.error_key' "$CTRL9B_OUT")"
rm -f "$QG_NOREBIND"

# ===========================================================================
printf '\n=== Section 10: R1-F1 (review round 1) — a PRESENT jq that FAILS mid-computation must never fail open ===\n'
# ===========================================================================
# Distinct from Section 8.5 (jq entirely ABSENT, checked as this
# subcommand's own first action): here jq resolves and command -v succeeds,
# but ONE specific invocation inside the undeclared/unbuilt computation
# fails. install_failing_jq installs a shim at $FIXTURE/bin/jq — EARLIER in
# PATH than the real jq — that delegates to the REAL jq for every call
# EXCEPT one whose arguments contain the given pattern, which it fails
# (exit 7, no output) instead of running.
install_failing_jq() {
    local pattern="$1"
    cat > "$FIXTURE/bin/jq" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        *'$pattern'*) exit 7 ;;
    esac
done
exec "$REAL_JQ" "\$@"
EOF
    chmod +x "$FIXTURE/bin/jq"
}
restore_real_jq() { rm -f "$FIXTURE/bin/jq"; }

# install_failing_jq_exact <pattern> — R2-F4 fix (review round 2): a
# SUBSTRING match is the wrong tool when the string that must trip is
# itself a substring of an EARLIER filter that must NOT trip first.
# checkpoint 2's shape-check filter is the single compound string
# `(.undeclared | type) == "array" and ... and (.undeclared_n | type) ==
# "number" and ...` — it CONTAINS `.undeclared_n` as a substring, so
# install_failing_jq '.undeclared_n' tripped checkpoint 2 (which runs
# first) rather than checkpoint 3's own standalone `jq -r '.undeclared_n'`
# extraction, and the test still passed for the WRONG reason: both
# checkpoints route to the identical set_computation_failed/exit 2 outcome,
# so nothing distinguished "checkpoint 3's own guard fired" from
# "checkpoint 2 already refused before checkpoint 3 was ever reached" — a
# regression in checkpoint 3's own fallback would have left this control
# green. Checkpoint 3's four extractions each pass jq a filter that IS
# exactly this short string and nothing else (`jq -r '.undeclared_n'`, not
# embedded in a longer expression); checkpoint 2's filter never equals any
# of them exactly. Exact whole-argument equality is therefore the
# discriminator that actually isolates checkpoint 3.
install_failing_jq_exact() {
    local pattern="$1"
    cat > "$FIXTURE/bin/jq" <<EOF
#!/bin/bash
for a in "\$@"; do
    if [ "\$a" = "$pattern" ]; then
        exit 7
    fi
done
exec "$REAL_JQ" "\$@"
EOF
    chmod +x "$FIXTURE/bin/jq"
}

EPIC12=$(bd create "D4 R1-F1 epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD12=$(bd create "D4 R1-F1 child" -t task -p 1 --parent "$EPIC12" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC12" "$ONE_UNIT_U1" >/dev/null
bash "$QG" design-unit-bind "$CHILD12" --design-task "$EPIC12" --unit-id U1 >/dev/null 2>&1
mkdir -p "$FIXTURE/src"
touch "$FIXTURE/src/a.sh"
printf 'src/a.sh\n' > "$TRACKING"

# --- checkpoint 1: actual_json's own jq -R -s split computation ------------
install_failing_jq 'split("'
OUT=$(bash "$QG" design-conform "$CHILD12" 2>&1); EXIT_RC=$?
assert_eq "10.1 checkpoint 1 (actual_json split): exit 2, never 0" "2" "$EXIT_RC"
assert_eq "10.1b ...error_key=set_computation_failed (NOT ok:true)" \
    "set_computation_failed" "$(json_field '.error_key' "$OUT")"
restore_real_jq
CTRL_OUT=$(bash "$QG" design-conform "$CHILD12" 2>&1)
assert_eq "10.1c CONTROL: the SAME task, real jq restored, conforms" "true" "$(json_field '.ok' "$CTRL_OUT")"

# --- checkpoint 2: diff_json's own set-difference computation --------------
# shellcheck disable=SC2016  # single-quoted deliberately: this is the
# LITERAL jq-source substring to match against, not an expression to expand.
install_failing_jq 'as $undeclared'
OUT=$(bash "$QG" design-conform "$CHILD12" 2>&1); EXIT_RC=$?
assert_eq "10.2 checkpoint 2 (diff_json): exit 2, never 0" "2" "$EXIT_RC"
assert_eq "10.2b ...error_key=set_computation_failed" \
    "set_computation_failed" "$(json_field '.error_key' "$OUT")"
restore_real_jq
CTRL_OUT=$(bash "$QG" design-conform "$CHILD12" 2>&1)
assert_eq "10.2c CONTROL: the SAME task, real jq restored, conforms" "true" "$(json_field '.ok' "$CTRL_OUT")"

# --- checkpoint 3: extracting the already-validated diff_json's own fields -
# EXACT match, not substring (R2-F4 fix, review round 2) — see
# install_failing_jq_exact's own header for why a substring match on this
# specific pattern silently exercised checkpoint 2 instead.
install_failing_jq_exact '.undeclared_n'
# Precondition proving the discriminator actually discriminates: feed the
# shim checkpoint 2's OWN filter text directly (against `{}`, so the REAL
# jq's own answer is the well-known -e-on-a-false-result code, 1 — an
# error would print 2, a wrongly-tripped shim would print 7) and confirm
# it does NOT trip, so 10.3 below cannot be passing for the same wrong
# reason as before.
PRECHECK_CP2_RC=0
printf '%s' '{}' | "$FIXTURE/bin/jq" -e '
        (.undeclared | type) == "array" and (.unbuilt | type) == "array"
        and (.undeclared_n | type) == "number" and (.unbuilt_n | type) == "number"
    ' >/dev/null 2>&1 || PRECHECK_CP2_RC=$?
assert_eq "10.3 precondition: the exact-match shim does NOT trip on checkpoint 2's own (longer) filter text" \
    "1" "$PRECHECK_CP2_RC"
OUT=$(bash "$QG" design-conform "$CHILD12" 2>&1); EXIT_RC=$?
assert_eq "10.3b checkpoint 3 (undeclared_n extraction): exit 2, never 0" "2" "$EXIT_RC"
assert_eq "10.3c ...error_key=set_computation_failed" \
    "set_computation_failed" "$(json_field '.error_key' "$OUT")"
restore_real_jq
CTRL_OUT=$(bash "$QG" design-conform "$CHILD12" 2>&1)
assert_eq "10.3d CONTROL: the SAME task, real jq restored, conforms" "true" "$(json_field '.ok' "$CTRL_OUT")"

# ===========================================================================
printf '\n=== Section 11: R1-F2 (review round 1) — the satisfied-hash/declarations TOCTOU bracket ===\n'
# ===========================================================================
# Same shim TECHNIQUE as design-artifact.test.sh's own 6.6 (a swap installed
# AT review-check.sh's path, run once, self-restoring), applied to
# design-conform's OWN window: compute_design_satisfied (step 2) reads the
# artifact ONCE via a live re-hash with no review-check.sh call at all;
# validate-design (step 3) reads it AGAIN, separately. The shim runs the
# REAL validator first (so its answer reflects the bytes at call time), THEN
# rewrites the artifact, THEN prints the REAL (pre-rewrite) answer — putting
# the write exactly inside the window the finding names.
EPIC13=$(bd create "D4 R1-F2 epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD13=$(bd create "D4 R1-F2 child" -t task -p 1 --parent "$EPIC13" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC13" "$ONE_UNIT_U1" >/dev/null
bash "$QG" design-unit-bind "$CHILD13" --design-task "$EPIC13" --unit-id U1 >/dev/null 2>&1
ART13="$FIXTURE/docs/specs/$EPIC13.md"
printf '%s\n' "$ART13" > "$TRACKING"
PRE_SWAP_HASH13=$(bash "$WM" hash-file "$ART13")

cp "$RC" "$FIXTURE/.claude/scripts/review-check.real.sh"
cat > "$RC" <<SHIM
#!/bin/bash
out=\$(bash "$FIXTURE/.claude/scripts/review-check.real.sh" "\$@"); rc=\$?
if [ "\${1:-}" = "validate-design" ]; then
    printf '%s\n<!-- swapped between the satisfied-hash check and this read -->\n' "\$(cat "$ART13")" > "$ART13"
fi
printf '%s\n' "\$out"
exit \$rc
SHIM
chmod +x "$RC"

TOC13_OUT=$(bash "$QG" design-conform "$CHILD13" 2>&1); TOC13_RC=$?
POST_SWAP_HASH13=$(bash "$WM" hash-file "$ART13" 2>/dev/null)
assert_eq "11.1 precondition: the shim really did rewrite the artifact inside the window" "differ" \
    "$([ "$PRE_SWAP_HASH13" != "$POST_SWAP_HASH13" ] && echo differ || echo same)"
assert_eq "11.2 design-conform is REFUSED when the artifact moves between the two reads: exit 4" "4" "$TOC13_RC"
assert_eq "11.2b ...error_key=design_verdict_stale (never ok:true over declarations no reviewer confirmed)" \
    "design_verdict_stale" "$(json_field '.error_key' "$TOC13_OUT")"

# CONTROL: restore the real validator AND the original artifact bytes,
# confirm the SAME task now conforms — the refusal above was caused by the
# swap, not by an unrelated defect the shim happened to also trigger.
cp "$FIXTURE/.claude/scripts/review-check.real.sh" "$RC"
rm -f "$FIXTURE/.claude/scripts/review-check.real.sh"
write_artifact "$ART13" "$EPIC13" "$ONE_UNIT_U1"
printf '%s\n' "$ART13" > "$TRACKING"
checkpoint_git
bash "$QG" enter "$EPIC13" >/dev/null 2>&1
bash "$QG" design-record "$EPIC13" >/dev/null 2>&1
HASH13B=$(bash "$WM" hash-file "$ART13")
FRESH13=$(printf '%s' "$SATISFIED_VERDICT" | jq -c '.iteration=2')
printf '%s' "$FRESH13" | bash "$QG" design-review-record "$EPIC13" --design-hash "$HASH13B" >/dev/null 2>&1
mkdir -p "$FIXTURE/src"
touch "$FIXTURE/src/a.sh"
printf 'src/a.sh\n' > "$TRACKING"
CTRL13_OUT=$(bash "$QG" design-conform "$CHILD13" 2>&1)
assert_eq "11.3 CONTROL: no swap, real validator: the same task conforms" "true" "$(json_field '.ok' "$CTRL13_OUT")"

# --- 11.4-11.6: the SAME closing bracket, but the artifact DISAPPEARS
# rather than merely changing, so workflow-manifest.sh hash-file itself
# fails (rc<>0, no stdout) instead of succeeding over different bytes.
# 11.1-11.3 above proved the MISMATCH sub-case; this proves the bracket
# also survives the re-hash call FAILING OUTRIGHT — the exact shape of the
# errexit-on-bare-assignment hazard this build's own audit caught in
# post_conform_hash/post_conform_rc (see qa-gate.sh's comment there): before
# the fix, a failing hash-file call died the WHOLE SCRIPT at the assignment
# with no envelope at all, rather than reaching this refusal.
EPIC13B=$(bd create "D4 R1-F2 epic (hash-file failure sub-case)" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD13B=$(bd create "D4 R1-F2 child (hash-file failure sub-case)" -t task -p 1 --parent "$EPIC13B" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC13B" "$ONE_UNIT_U1" >/dev/null
bash "$QG" design-unit-bind "$CHILD13B" --design-task "$EPIC13B" --unit-id U1 >/dev/null 2>&1
ART13B="$FIXTURE/docs/specs/$EPIC13B.md"
mkdir -p "$FIXTURE/src"; touch "$FIXTURE/src/a.sh"
printf 'src/a.sh\n' > "$TRACKING"
assert_eq "11.4 precondition: the artifact exists before the shim runs" "yes" \
    "$([ -f "$ART13B" ] && echo yes || echo no)"

cp "$RC" "$FIXTURE/.claude/scripts/review-check.real.sh"
cat > "$RC" <<SHIM
#!/bin/bash
out=\$(bash "$FIXTURE/.claude/scripts/review-check.real.sh" "\$@"); rc=\$?
if [ "\${1:-}" = "validate-design" ]; then
    rm -f "$ART13B"
fi
printf '%s\n' "\$out"
exit \$rc
SHIM
chmod +x "$RC"

DEL13B_OUT=$(bash "$QG" design-conform "$CHILD13B" 2>&1); DEL13B_RC=$?
assert_eq "11.5 precondition: the shim really did delete the artifact inside the window" "yes" \
    "$([ -f "$ART13B" ] && echo no || echo yes)"
assert_eq "11.5b design-conform is REFUSED (not a silent crash) when the re-hash call FAILS OUTRIGHT: exit 4" \
    "4" "$DEL13B_RC"
assert_eq "11.5c ...error_key=design_verdict_stale (same key the mismatch sub-case uses — 'cannot confirm the reviewed hash still describes this artifact' covers both causes)" \
    "design_verdict_stale" "$(json_field '.error_key' "$DEL13B_OUT")"
assert_contains "11.5d ...and the observations note the read actually failed, not just mismatched" \
    "unreadable, rc=" "$DEL13B_OUT"

# CONTROL: restore the real validator AND the artifact, confirm the SAME
# task conforms — the refusal above was caused by the deletion, not by an
# unrelated defect (e.g. a leftover process substitution) the shim also hit.
cp "$FIXTURE/.claude/scripts/review-check.real.sh" "$RC"
rm -f "$FIXTURE/.claude/scripts/review-check.real.sh"
write_artifact "$ART13B" "$EPIC13B" "$ONE_UNIT_U1"
printf '%s\n' "$ART13B" > "$TRACKING"
checkpoint_git
bash "$QG" enter "$EPIC13B" >/dev/null 2>&1
bash "$QG" design-record "$EPIC13B" >/dev/null 2>&1
HASH13C=$(bash "$WM" hash-file "$ART13B")
FRESH13B=$(printf '%s' "$SATISFIED_VERDICT" | jq -c '.iteration=2')
printf '%s' "$FRESH13B" | bash "$QG" design-review-record "$EPIC13B" --design-hash "$HASH13C" >/dev/null 2>&1
printf 'src/a.sh\n' > "$TRACKING"
CTRL13B_OUT=$(bash "$QG" design-conform "$CHILD13B" 2>&1)
assert_eq "11.6 CONTROL: no deletion, real validator, artifact restored: the same task conforms" \
    "true" "$(json_field '.ok' "$CTRL13B_OUT")"

# ===========================================================================
printf '\n=== Section 12: R1-F4 (review round 1) — the reader now genuinely matches the writer'"'"'s classes ===\n'
# ===========================================================================
# A hand-posted comment matching the OLD, looser grammar
# (design_hash=[A-Za-z0-9-]+, any single space before free text) but NOT the
# tightened one (design_hash EXACTLY 64 hex, then the literal " at "
# boundary) must be treated as NO BINDING AT ALL — the writer could never
# have produced it, so the reader must not accept it either.
EPIC14=$(bd create "D4 R1-F4 epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD14=$(bd create "D4 R1-F4 child (forged binding)" -t task -p 1 --parent "$EPIC14" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC14" "$ONE_UNIT_U1" >/dev/null

FORGED_SHORT_HASH="DESIGN-UNIT v1 task=$CHILD14 design_task=$EPIC14 unit_id=U1 design_hash=deadbeef anything-that-is-not-at"
bd comments add "$CHILD14" "$FORGED_SHORT_HASH" >/dev/null 2>&1 \
    || bd comment add "$CHILD14" "$FORGED_SHORT_HASH" >/dev/null 2>&1
FORGED_LANDED=$(comments_of "$CHILD14" | grep -cF "$FORGED_SHORT_HASH")
assert_eq "12.1 precondition: the forged (short-hash, no ' at ' boundary) comment actually landed" "1" "$FORGED_LANDED"

OUT=$(bash "$QG" design-conform "$CHILD14" 2>&1); EXIT_RC=$?
assert_eq "12.2 design-conform treats the forged comment as NO BINDING AT ALL: exit 4" "4" "$EXIT_RC"
assert_eq "12.2b ...error_key=unit_not_in_design (not a corrupted-but-accepted binding)" \
    "unit_not_in_design" "$(json_field '.error_key' "$OUT")"

CHILD14B=$(bd create "D4 R1-F4 child (64-hex, no at boundary)" -t task -p 1 --parent "$EPIC14" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
HASH14=$(bash "$WM" hash-file "$FIXTURE/docs/specs/$EPIC14.md")
FORGED_NO_AT="DESIGN-UNIT v1 task=$CHILD14B design_task=$EPIC14 unit_id=U1 design_hash=$HASH14 notat 2026-01-01T00:00:00Z: forged"
bd comments add "$CHILD14B" "$FORGED_NO_AT" >/dev/null 2>&1 \
    || bd comment add "$CHILD14B" "$FORGED_NO_AT" >/dev/null 2>&1
FORGED2_LANDED=$(comments_of "$CHILD14B" | grep -cF "$FORGED_NO_AT")
assert_eq "12.3 precondition: the SECOND forgery (real 64-hex hash, but 'notat' not 'at') landed" "1" "$FORGED2_LANDED"
OUT=$(bash "$QG" design-conform "$CHILD14B" 2>&1); EXIT_RC=$?
assert_eq "12.4 a real 64-hex hash with the WRONG boundary word is ALSO no binding: exit 4" "4" "$EXIT_RC"
assert_eq "12.4b ...error_key=unit_not_in_design" "unit_not_in_design" "$(json_field '.error_key' "$OUT")"

# CONTROL: a REAL binding via the shipped writer on a fresh task still reads
# correctly (the tightened classes are not simply refusing everything).
CHILD14C=$(bd create "D4 R1-F4 control (real binding)" -t task -p 1 --parent "$EPIC14" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
bash "$QG" design-unit-bind "$CHILD14C" --design-task "$EPIC14" --unit-id U1 >/dev/null 2>&1
mkdir -p "$FIXTURE/src"; touch "$FIXTURE/src/a.sh"
printf 'src/a.sh\n' > "$TRACKING"
CTRL14_OUT=$(bash "$QG" design-conform "$CHILD14C" 2>&1)
assert_eq "12.5 CONTROL: a REAL (shipped-writer) binding still reads correctly" "true" "$(json_field '.ok' "$CTRL14_OUT")"

# --- R2-F1 (review round 2): R1-F4 tightened hash width/class and the ' at
# ' boundary, but two gaps remained — `task=` was matched but never
# compared against <tid>, and nothing after ' at ' was validated at all.
# The writer ALWAYS emits `task=<the task it is posted on>`, so a comment
# carrying a DIFFERENT task= value could only exist by being copied,
# mis-posted, or hand-forged — exactly the case the reader must now refuse
# rather than accept as "the binding for whichever task the comment
# happens to sit on".
CHILD14D=$(bd create "D4 R2-F1 child (foreign task= field)" -t task -p 1 --parent "$EPIC14" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
HASH14D=$(bash "$WM" hash-file "$FIXTURE/docs/specs/$EPIC14.md")
FORGED_FOREIGN_TASK="DESIGN-UNIT v1 task=SOME-OTHER-TASK-999 design_task=$EPIC14 unit_id=U1 design_hash=$HASH14D at 2026-01-01T00:00:00Z: mis-posted binding"
bd comments add "$CHILD14D" "$FORGED_FOREIGN_TASK" >/dev/null 2>&1 \
    || bd comment add "$CHILD14D" "$FORGED_FOREIGN_TASK" >/dev/null 2>&1
FORGED_FOREIGN_LANDED=$(comments_of "$CHILD14D" | grep -cF "$FORGED_FOREIGN_TASK")
assert_eq "12.6 precondition: the foreign-task= comment actually landed on CHILD14D" "1" "$FORGED_FOREIGN_LANDED"
OUT=$(bash "$QG" design-conform "$CHILD14D" 2>&1); EXIT_RC=$?
assert_eq "12.6b a well-formed record whose OWN task= names a DIFFERENT task is NO BINDING here: exit 4" "4" "$EXIT_RC"
assert_eq "12.6c ...error_key=unit_not_in_design (not accepted as CHILD14D's binding merely because it sits on CHILD14D)" \
    "unit_not_in_design" "$(json_field '.error_key' "$OUT")"

# --- R2-F1's second half: nothing after the ' at ' boundary used to be
# validated, so a malformed (non-ISO-8601) timestamp still matched. The
# writer's $ts is always `date -u +%Y-%m-%dT%H:%M:%SZ`; the reader now
# requires that exact shape plus the literal ': ' that always follows it.
CHILD14E=$(bd create "D4 R2-F1 child (malformed timestamp)" -t task -p 1 --parent "$EPIC14" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
FORGED_BAD_TS="DESIGN-UNIT v1 task=$CHILD14E design_task=$EPIC14 unit_id=U1 design_hash=$HASH14D at not-a-real-timestamp: forged"
bd comments add "$CHILD14E" "$FORGED_BAD_TS" >/dev/null 2>&1 \
    || bd comment add "$CHILD14E" "$FORGED_BAD_TS" >/dev/null 2>&1
FORGED_BAD_TS_LANDED=$(comments_of "$CHILD14E" | grep -cF "$FORGED_BAD_TS")
assert_eq "12.7 precondition: the malformed-timestamp comment actually landed" "1" "$FORGED_BAD_TS_LANDED"
OUT=$(bash "$QG" design-conform "$CHILD14E" 2>&1); EXIT_RC=$?
assert_eq "12.7b a real task=, real 64-hex hash, but a non-ISO-8601 timestamp is ALSO no binding: exit 4" "4" "$EXIT_RC"
assert_eq "12.7c ...error_key=unit_not_in_design" "unit_not_in_design" "$(json_field '.error_key' "$OUT")"

# CONTROL: the SAME two attack shapes, but via the shipped writer on a
# fresh task, still record and read correctly — R2-F1 tightened the
# reader, not the writer's own class, so an ordinary bind is unaffected.
CHILD14F=$(bd create "D4 R2-F1 control (real binding, post-tightening)" -t task -p 1 --parent "$EPIC14" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
bash "$QG" design-unit-bind "$CHILD14F" --design-task "$EPIC14" --unit-id U1 >/dev/null 2>&1
printf 'src/a.sh\n' > "$TRACKING"
CTRL14F_OUT=$(bash "$QG" design-conform "$CHILD14F" 2>&1)
assert_eq "12.8 CONTROL: a REAL binding on a DIFFERENT fresh task still reads correctly after the task=/timestamp tightening" \
    "true" "$(json_field '.ok' "$CTRL14F_OUT")"

# ===========================================================================
printf '\n=== Section 13: R1-F5 (review round 1) — design-unit-bind degrades honestly on a jq-less PATH too ===\n'
# ===========================================================================
# Same restricted-PATH technique as Section 8.5, applied to the SIBLING
# subcommand the review found unprotected.
EPIC15=$(bd create "D4 R1-F5 epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD15=$(bd create "D4 R1-F5 child" -t task -p 1 --parent "$EPIC15" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC15" "$ONE_UNIT_U1" >/dev/null

NOJQ_BIN2="$FIXTURE/nojq-bin2"
mkdir -p "$NOJQ_BIN2"
for b in bash bd git sed awk grep cut head tail tr cmp date mkdir cp mv \
         dirname basename readlink realpath sort wc shasum sha256sum; do
    bp=$(command -v "$b" 2>/dev/null) && ln -sf "$bp" "$NOJQ_BIN2/$b"
done
assert_eq "13.1 precondition: the restricted PATH really has no jq" "yes" \
    "$(PATH="$NOJQ_BIN2" command -v jq >/dev/null 2>&1 && echo no || echo yes)"
NOJQ_BIND_OUT=$(PATH="$NOJQ_BIN2" CLAUDE_PROJECT_DIR="$FIXTURE" HOME="$TEST_HOME" "$NOJQ_BIN2/bash" "$QG" design-unit-bind "$CHILD15" --design-task "$EPIC15" --unit-id U1 2>&1); NOJQ_BIND_RC=$?
assert_eq "13.2 design-unit-bind on a jq-less PATH: exit 2" "2" "$NOJQ_BIND_RC"
assert_eq "13.2b ...error_key=jq_unavailable" "jq_unavailable" "$(json_field '.error_key' "$NOJQ_BIND_OUT")"
assert_eq "13.2c ...and the envelope is valid JSON with task_id:null (no caller text interpolated, same property design-conform's own message has)" \
    "null" "$(printf '%s' "$NOJQ_BIND_OUT" | jq -r '.task_id' 2>/dev/null)"
assert_eq "13.2d ...nothing was recorded" "0" "$(count_binding "$CHILD15")"
CTRL15_OUT=$(bash "$QG" design-unit-bind "$CHILD15" --design-task "$EPIC15" --unit-id U1 2>&1)
assert_eq "13.3 CONTROL: the SAME task, jq back on PATH, binds normally" "recorded" "$(json_field '.status' "$CTRL15_OUT")"

# ===========================================================================
printf '\n=== Section 14: R1-F6 (review round 1) — a GENUINE concurrent-rebind race, not just sequential ===\n'
# ===========================================================================
# Section 3 and 9.2 test the SEQUENTIAL invariant. This section tests actual
# concurrency, which this dev host cannot do with a real flock (there is
# none — see the shipped code's own comment). A minimal flock(1)-compatible
# shim built on Python's fcntl.flock (the SAME underlying kernel primitive
# util-linux's real flock(1) wraps) gives a GENUINE mutex for this one
# section, without installing anything system-wide. Gracefully skipped, not
# failed, when python3/fcntl is unavailable.
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import fcntl' >/dev/null 2>&1; then
    printf 'note: Section 14 needs python3 with fcntl (not found) — SKIPPING the genuine-concurrency race test\n'
else
    FLOCK_STUB_BIN="$FIXTURE/flock-stub-bin"
    mkdir -p "$FLOCK_STUB_BIN"
    cat > "$FLOCK_STUB_BIN/flock" <<'PYEOF'
#!/usr/bin/env python3
import sys
import fcntl
mode = fcntl.LOCK_EX
fd = None
for a in sys.argv[1:]:
    if a == "-x":
        mode = fcntl.LOCK_EX
    elif a == "-s":
        mode = fcntl.LOCK_SH
    elif a.lstrip("-").isdigit():
        fd = int(a)
if fd is None:
    sys.exit(1)
fcntl.flock(fd, mode)
sys.exit(0)
PYEOF
    chmod +x "$FLOCK_STUB_BIN/flock"

    EPIC16=$(bd create "D4 R1-F6 race epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
    CHILD16=$(bd create "D4 R1-F6 race child" -t task -p 1 --parent "$EPIC16" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
    design_and_review "$EPIC16" "$ONE_UNIT_U1" >/dev/null

    assert_eq "14.1 precondition: the stub flock genuinely resolves ahead of any real one" "$FLOCK_STUB_BIN/flock" \
        "$(PATH="$FLOCK_STUB_BIN:$PATH" command -v flock)"

    RACE_A=$(mktemp -t race14-a.XXXXXX)
    RACE_B=$(mktemp -t race14-b.XXXXXX)
    (
        PATH="$FLOCK_STUB_BIN:$PATH" bash "$QG" design-unit-bind "$CHILD16" --design-task "$EPIC16" --unit-id U1 > "$RACE_A" 2>&1
    ) &
    RPID_A=$!
    (
        PATH="$FLOCK_STUB_BIN:$PATH" bash "$QG" design-unit-bind "$CHILD16" --design-task "$EPIC16" --unit-id U1 > "$RACE_B" 2>&1
    ) &
    RPID_B=$!
    wait "$RPID_A" "$RPID_B"

    RACE_STATUSES=$(printf '%s\n%s\n' "$(json_field '.status' "$(cat "$RACE_A")")" "$(json_field '.status' "$(cat "$RACE_B")")" | sort | tr '\n' ',')
    assert_eq "14.2 with a WORKING flock, exactly ONE of the two truly-concurrent binds recorded and the other refused (never both, never neither)" \
        "error,recorded," "$RACE_STATUSES"
    assert_eq "14.3 ...and exactly ONE DESIGN-UNIT binding exists on the task, not two" \
        "1" "$(count_binding "$CHILD16")"
    rm -f "$RACE_A" "$RACE_B"
fi

# ===========================================================================
printf '\n=== Section 15: R2-F2 (review round 2) — the rebind lock is now shared across worktrees of ONE repo, not per-checkout ===\n'
# ===========================================================================
# Section 14 proves the flock branch is a real mutex for two concurrent
# callers sharing ONE $PROJECT_DIR. R2-F2's finding is about TWO DIFFERENT
# $PROJECT_DIR values (two worktrees) racing against the SAME shared Beads
# store — pre-fix, each derived a DIFFERENT lock file from its own
# $QA_TRACKING_DIR, so neither actually excluded the other despite both
# addressing one store. That needs a REAL `git worktree add` to drive at
# all (a single fixture dir structurally cannot express two PROJECT_DIRs).
#
# This tests the STRUCTURAL property directly — WHICH lock file path each
# context resolves to — rather than trying to force a live race across two
# real OS processes to observe the SAME thing indirectly and flakily
# (whether the race actually interleaves is a scheduling question a
# four-part pairing control should not depend on; the review's own R2-F2
# finding was itself "verified by reading the lock derivation... the race
# outcome is inferred", never executed as a race either). Proving the two
# contexts resolve to the SAME physical lock file is the exact property
# that makes Section 14's already-proven flock mutual exclusion apply
# across them too — nothing about flock's own correctness needs re-proving
# here, only path identity.
# The lock file (`.design-unit-bind-<sanitized-tid>.lock`) is only ever
# TOUCHED inside the `if command -v flock` branch (the `9>"$rebind_lock"`
# redirection) — on a flock-less host (this one; see Section 14's own
# header) `cmd_design_unit_bind` always takes the OTHER branch, which never
# references $rebind_lock at all, so NEITHER the shipped script NOR a
# mutant would ever create the file and this whole section would be
# vacuous either way. The SAME Python flock(1)-compatible stub Section 14
# already proved genuine (fcntl.flock, not a no-op) is installed here too,
# for the SAME reason and with the SAME graceful skip.
sanitize_lock_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}
lock_file_present() {
    # lock_file_present <root-dir> <task-id> -> "1" or "0"
    [ -f "$1/.design-unit-bind-$(sanitize_lock_name "$2").lock" ] && printf '1' || printf '0'
}

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import fcntl' >/dev/null 2>&1; then
    printf 'note: Section 15 needs python3 with fcntl (not found) — SKIPPING the cross-worktree lock-root test\n'
else
    FLOCK_STUB_BIN15="$FIXTURE/flock-stub-bin-15"
    mkdir -p "$FLOCK_STUB_BIN15"
    cat > "$FLOCK_STUB_BIN15/flock" <<'PYEOF'
#!/usr/bin/env python3
import sys
import fcntl
mode = fcntl.LOCK_EX
fd = None
for a in sys.argv[1:]:
    if a == "-x":
        mode = fcntl.LOCK_EX
    elif a == "-s":
        mode = fcntl.LOCK_SH
    elif a.lstrip("-").isdigit():
        fd = int(a)
if fd is None:
    sys.exit(1)
fcntl.flock(fd, mode)
sys.exit(0)
PYEOF
    chmod +x "$FLOCK_STUB_BIN15/flock"

    EPIC17=$(bd create "D4 R2-F2 cross-worktree epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
    design_and_review "$EPIC17" "$ONE_UNIT_U1" >/dev/null

    WT17="${FIXTURE}-r2f2-wt"
    rm -rf "$WT17" 2>/dev/null
    WT17_ADD_RC=0
    git -C "$FIXTURE" worktree add -q -b r2f2wt-branch "$WT17" >/dev/null 2>&1 || WT17_ADD_RC=$?
    if [ "$WT17_ADD_RC" -ne 0 ] || [ ! -d "$WT17" ]; then
        printf 'note: Section 15 could not create a real git worktree (rc=%s) — SKIPPING\n' "$WT17_ADD_RC"
    else
        # Precondition: the two really are worktrees of ONE repo, via the
        # SAME symlink-resolved --git-common-dir identity the fix itself
        # uses (never a --show-toplevel string compare, which would report
        # them as different and prove nothing about the property under
        # test).
        CID_MAIN=$(cd "$(git -C "$FIXTURE" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
        CID_WT=$(cd "$(git -C "$WT17" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
        assert_eq "15.1 precondition: the linked worktree and the main checkout resolve to ONE common git directory" \
            "$CID_MAIN" "$CID_WT"
        assert_contains "15.1b precondition: the resolved common directory is a real, non-empty path" "/" "$CID_MAIN"
        SHARED_LOCK_ROOT="$CID_MAIN/claude-workflow-design-unit-locks"

        # --- MUTATION: strip the cross-worktree lock-root block, reverting
        # _design_unit_lock_root to ALWAYS return $QA_TRACKING_DIR — the
        # exact pre-fix behaviour.
        QG_NOCROSSLOCK="$FIXTURE/.claude/scripts/qa-gate-nocrosslock.sh"
        STRIP15_RC=0
        awk '
            /# CROSS-WORKTREE-LOCK-ROOT BEGIN/ { skipping=1; found=1; next }
            /# CROSS-WORKTREE-LOCK-ROOT END/   { skipping=0; next }
            skipping { next }
            { print }
            END { if (!found) exit 7 }
        ' "$QG" > "$QG_NOCROSSLOCK" || STRIP15_RC=$?
        chmod +x "$QG_NOCROSSLOCK"
        assert_eq "15.2 META: CROSS-WORKTREE-LOCK-ROOT sentinels are present (the strip found them)" "0" "$STRIP15_RC"
        P15_RC=0
        bash -n "$QG_NOCROSSLOCK" 2>/dev/null || P15_RC=$?
        assert_eq "15.2b META: the stripped copy still parses" "0" "$P15_RC"
        D15=$(cmp -s "$QG" "$QG_NOCROSSLOCK" && echo same || echo differ)
        assert_eq "15.2c META: the mutant's bytes actually differ from the shipped script" "differ" "$D15"

        CHILD17M1=$(bd create "D4 R2-F2 mutant, main-checkout context" -t task -p 1 --parent "$EPIC17" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
        CHILD17M2=$(bd create "D4 R2-F2 mutant, worktree context" -t task -p 1 --parent "$EPIC17" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
        PATH="$FLOCK_STUB_BIN15:$PATH" CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG_NOCROSSLOCK" design-unit-bind "$CHILD17M1" --design-task "$EPIC17" --unit-id U1 >/dev/null 2>&1
        PATH="$FLOCK_STUB_BIN15:$PATH" CLAUDE_PROJECT_DIR="$WT17" bash "$QG_NOCROSSLOCK" design-unit-bind "$CHILD17M2" --design-task "$EPIC17" --unit-id U1 >/dev/null 2>&1
        # Non-vacuity: the lock-file-location assertions below are
        # meaningless if the binds themselves silently failed.
        assert_eq "15.2d non-vacuity: the mutant's own bind actually recorded (main-checkout context)" \
            "1" "$(count_binding "$CHILD17M1")"
        assert_eq "15.2e non-vacuity: the mutant's own bind actually recorded (worktree context)" \
            "1" "$(count_binding "$CHILD17M2")"
        assert_eq "15.3 MISBEHAVIOUR: WITHOUT the fix, the main-checkout call's lock lands under its OWN per-checkout .qa-tracking" \
            "1" "$(lock_file_present "$FIXTURE/.claude/.qa-tracking" "$CHILD17M1")"
        assert_eq "15.3b ...and the worktree call's lock lands under ITS OWN, DIFFERENT per-checkout .qa-tracking" \
            "1" "$(lock_file_present "$WT17/.claude/.qa-tracking" "$CHILD17M2")"
        assert_eq "15.3c ...neither uses the shared location at all — two DIFFERENT physical lock files for ONE shared store, unlocked against each other" \
            "0" "$(( $(lock_file_present "$SHARED_LOCK_ROOT" "$CHILD17M1") + $(lock_file_present "$SHARED_LOCK_ROOT" "$CHILD17M2") ))"
        rm -f "$QG_NOCROSSLOCK"

        # --- CONTROL: the SAME two calls, same two fresh tasks, against
        # the SHIPPED script: both lock files land at the IDENTICAL shared
        # path, keyed on THESE tasks' own ids (not a blanket glob, which
        # would also count Section 14's own still-present lock file for a
        # DIFFERENT task at the same shared root).
        CHILD17C1=$(bd create "D4 R2-F2 control, main-checkout context" -t task -p 1 --parent "$EPIC17" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
        CHILD17C2=$(bd create "D4 R2-F2 control, worktree context" -t task -p 1 --parent "$EPIC17" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
        PATH="$FLOCK_STUB_BIN15:$PATH" CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" design-unit-bind "$CHILD17C1" --design-task "$EPIC17" --unit-id U1 >/dev/null 2>&1
        PATH="$FLOCK_STUB_BIN15:$PATH" CLAUDE_PROJECT_DIR="$WT17" bash "$QG" design-unit-bind "$CHILD17C2" --design-task "$EPIC17" --unit-id U1 >/dev/null 2>&1
        assert_eq "15.4 CONTROL: WITH the fix, the main-checkout call's lock lands under the SHARED, git-common-dir-based location" \
            "1" "$(lock_file_present "$SHARED_LOCK_ROOT" "$CHILD17C1")"
        assert_eq "15.4b ...and the worktree call's lock ALSO lands under that SAME shared location" \
            "1" "$(lock_file_present "$SHARED_LOCK_ROOT" "$CHILD17C2")"
        assert_eq "15.4c ...neither used its own per-checkout .qa-tracking (main)" \
            "0" "$(lock_file_present "$FIXTURE/.claude/.qa-tracking" "$CHILD17C1")"
        assert_eq "15.4d ...nor its own per-checkout .qa-tracking (worktree)" \
            "0" "$(lock_file_present "$WT17/.claude/.qa-tracking" "$CHILD17C2")"
        assert_eq "15.4e ...and both binds still recorded correctly despite sharing one lock (not a false refusal): main-checkout" \
            "1" "$(count_binding "$CHILD17C1")"
        assert_eq "15.4f ...worktree" \
            "1" "$(count_binding "$CHILD17C2")"
    fi
    rm -rf "$WT17" 2>/dev/null
    git -C "$FIXTURE" worktree prune >/dev/null 2>&1 || true
fi

# ===========================================================================
printf '\n=== Section 16: R2-F3 (review round 2) — a write that never landed must never read as recorded ===\n'
# ===========================================================================
# add_comment() ends in `|| log_sync_error ...` (itself ending in `||
# true`), so it ALWAYS returns success regardless of whether `bd comments
# add`/`bd comment add` actually wrote anything. A shim at $FIXTURE/bin/bd
# makes BOTH bd comment-posting spellings fail while every OTHER bd
# subcommand (create, show, --include-comments) still passes through to
# the real binary — reproducing "the store write silently did not happen"
# without touching bd itself (claude-workflow-plugin-nod4 owns that).
install_failing_bd_comment() {
    cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
if [ "\$1" = "comments" ] && [ "\$2" = "add" ]; then
    exit 9
fi
if [ "\$1" = "comment" ] && [ "\$2" = "add" ]; then
    exit 9
fi
exec ${REAL_BD} "\$@"
EOF
    chmod +x "$FIXTURE/bin/bd"
}
restore_real_bd() {
    cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} "\$@"
EOF
    chmod +x "$FIXTURE/bin/bd"
}

EPIC18=$(bd create "D4 R2-F3 epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD18=$(bd create "D4 R2-F3 child" -t task -p 1 --parent "$EPIC18" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC18" "$ONE_UNIT_U1" >/dev/null

install_failing_bd_comment
assert_eq "16.1 precondition: the shim really does make bd's comment-posting fail" "9" \
    "$(bd comments add "$CHILD18" "probe" >/dev/null 2>&1; echo $?)"
assert_eq "16.1b precondition: ...while bd show still works (only comment-posting is broken)" "0" \
    "$(bd show "$CHILD18" --json >/dev/null 2>&1; echo $?)"

OUT=$(bash "$QG" design-unit-bind "$CHILD18" --design-task "$EPIC18" --unit-id U1 2>&1); EXIT_RC=$?
assert_eq "16.2 design-unit-bind is REFUSED (never recorded) when the write silently does not land: exit 5" \
    "5" "$EXIT_RC"
assert_eq "16.2b ...error_key=design_binding_write_unconfirmed" \
    "design_binding_write_unconfirmed" "$(json_field '.error_key' "$OUT")"
assert_eq "16.2c ...and NOTHING is actually recorded (the read-back correctly found none)" \
    "0" "$(count_binding "$CHILD18")"
restore_real_bd

# --- META: the WRITE-CONFIRMATION-GATE is what catches this, not
# something incidental. Strip it and reproduce the SAME failing-write
# scenario: without the read-back, add_comment's fail-open status is all
# this function has, and it reports recorded on a write that never
# happened.
QG_NOCONFIRM="$FIXTURE/.claude/scripts/qa-gate-noconfirmgate.sh"
STRIP16_RC=0
awk '
    /# WRITE-CONFIRMATION-GATE BEGIN/ { skipping=1; found=1; next }
    /# WRITE-CONFIRMATION-GATE END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_NOCONFIRM" || STRIP16_RC=$?
chmod +x "$QG_NOCONFIRM"
assert_eq "16.3 META: WRITE-CONFIRMATION-GATE sentinels are present (the strip found them)" "0" "$STRIP16_RC"
P16_RC=0
bash -n "$QG_NOCONFIRM" 2>/dev/null || P16_RC=$?
assert_eq "16.3b META: the stripped copy still parses" "0" "$P16_RC"
D16=$(cmp -s "$QG" "$QG_NOCONFIRM" && echo same || echo differ)
assert_eq "16.3c META: the mutant's bytes actually differ from the shipped script" "differ" "$D16"

CHILD18B=$(bd create "D4 R2-F3 child (met test)" -t task -p 1 --parent "$EPIC18" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
install_failing_bd_comment
MUT16_OUT=$(bash "$QG_NOCONFIRM" design-unit-bind "$CHILD18B" --design-task "$EPIC18" --unit-id U1 2>&1)
assert_eq "16.4 MISBEHAVIOUR: WITHOUT the gate, the SAME silently-failed write reports recorded anyway" \
    "recorded" "$(json_field '.status' "$MUT16_OUT")"
restore_real_bd
assert_eq "16.4b ...despite NOTHING actually having been written (the false-positive claim)" \
    "0" "$(count_binding "$CHILD18B")"
rm -f "$QG_NOCONFIRM"

# --- CONTROL: the SAME task, real bd restored throughout: the SAME bind
# now genuinely succeeds and IS recorded — the refusal above was caused by
# the write failing, not by an unrelated defect the shim happened to also
# trigger.
CTRL16_OUT=$(bash "$QG" design-unit-bind "$CHILD18" --design-task "$EPIC18" --unit-id U1 2>&1)
assert_eq "16.5 CONTROL: the SAME bind, real bd, genuinely succeeds and is confirmed" \
    "recorded" "$(json_field '.status' "$CTRL16_OUT")"
assert_eq "16.5b ...and IS actually recorded this time" "1" "$(count_binding "$CHILD18")"

# ===========================================================================
printf '\n=== Section 17: REVIEW-ARTIFACT-EXCLUSION — a real review cycle does not\n'
printf '    make design-conform refuse its own evidence (v5 D5 piece 4,\n'
printf '    claude-workflow-plugin-fkm.7) ===\n'
# ===========================================================================
#
# THE GAP THIS CLOSES: no section above ever drives design-conform against a
# change set that has been through a REAL `review-record` cycle — every
# section writes $TRACKING by hand. Once combined for the first time (design-
# unit-align.test.sh Section 10, built alongside this fix), the canonical
# review artifact `review-record` itself writes to docs/reviews/<tid>-r<n>.json
# — documented, intended behaviour (qa.md section 6-prime: "the canonical
# file... enters the change set the approval binds") — was flagged as
# undeclared_files on EVERY SUCH TASK's first conform/align/approve attempt,
# because no unit's files[] ever declares gate-written review evidence.

EPIC17=$(bd create "D5 piece 4 review-artifact-exclusion epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD17=$(bd create "D5 piece 4 review-artifact-exclusion child" -t task -p 1 --parent "$EPIC17" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
ONE_UNIT_U1_17='[{"unit_id":"U1","role":"devops","goal":"unit one",
  "acceptance":[{"id":"AC1","text":"fixture"}],
  "files":["src/a.sh"],"verification":"make test","depends_on":[]}]'
design_and_review "$EPIC17" "$ONE_UNIT_U1_17" >/dev/null
bash "$QG" design-unit-bind "$CHILD17" --design-task "$EPIC17" --unit-id U1 "bound to U1" >/dev/null 2>&1

mkdir -p "$FIXTURE/src"
: > "$FIXTURE/src/a.sh"
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"

# A REAL review cycle: reconcile, hash, write+record the canonical artifact
# (landing at docs/reviews/<CHILD17>-r1.json), reconcile AGAIN (the artifact
# itself is a new untracked path git did not see at the first reconcile —
# the SAME ordering design-review-record.test.sh's own seed_approvable
# uses), then regenerate the persisted impact report.
bd comments add "$CHILD17" "IMPLEMENTER: role=devops task=$CHILD17 at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
H17=$(bash "$IR" --hash-only 2>/dev/null)
ART17="$FIXTURE/.claude/.qa-tracking/review-artifact-$(printf '%s' "$CHILD17" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"qa-claude","reviewer_model":"seeded-fixture","reviewer_pin":"seeded-fixture","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded fixture","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
    "$CHILD17" "$H17" > "$ART17"
bash "$QG" review-record "$CHILD17" < "$ART17" >/dev/null 2>&1
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
bash "$IR" "$CHILD17" >/dev/null 2>&1 || true

assert_contains "17.0 precondition: the canonical review artifact genuinely entered the tracker" \
    "docs/reviews/" "$(cat "$TRACKING")"

OUT17=$(bash "$QG" design-conform "$CHILD17" 2>&1); RC17=$?
assert_eq "17.1 THE FIX: design-conform CONFORMS after a real review cycle (rc=0), never refusing over its own evidence" \
    "0" "$RC17"
assert_eq "17.1b ...ok=true, undeclared_files empty" "true|[]" \
    "$(json_field '.ok' "$OUT17")|$(json_field '.undeclared_files | tojson' "$OUT17")"

# --- ANTI-OVERREACH: a DIFFERENT task's review artifact is NOT exempted ---
# The exclusion is task-SPECIFIC (matches THIS task's own canonical path
# only), never a blanket docs/reviews/ pass. Simulate scope creep: an extra
# file under docs/reviews/ that is NOT CHILD17's own canonical artifact
# name lands in the tracker — it must still be flagged.
printf '%s\ndocs/reviews/some-other-task-r1.json\n' "$FIXTURE/src/a.sh" > "$TRACKING"
mkdir -p "$FIXTURE/docs/reviews"
printf '{}' > "$FIXTURE/docs/reviews/some-other-task-r1.json"
OUT17B=$(bash "$QG" design-conform "$CHILD17" 2>&1); RC17B=$?
assert_eq "17.2 ANTI-OVERREACH: an unrelated docs/reviews/ path (not THIS task's own artifact) is STILL flagged (rc=4)" \
    "4" "$RC17B"
assert_eq "17.2b ...error_key=undeclared_files" \
    "undeclared_files" "$(json_field '.error_key' "$OUT17B")"
assert_contains "17.2c ...names the unrelated path specifically" \
    "some-other-task-r1.json" "$(json_field '.undeclared_files | tojson' "$OUT17B")"

# Restore the tracker to the genuinely-conforming state for the META below
# -- AND remove the unrelated file from DISK, not just from $TRACKING. The
# tracker reset alone is not enough: the file is still a REAL, uncommitted
# path in the fixture's own git working tree, and `reconcile-tracker`
# (right below, and again inside the META block) is a real git-status
# scan that rediscovers anything still on disk regardless of what
# $TRACKING said a moment ago -- the identical class of bug design-unit-
# align.test.sh's own UNDECLARED.sh fix already closed once (see that
# file's comment on the same lesson). Measured directly while building
# this: leaving the file in place turned 17.5's own restore control into a
# false undeclared_files refusal.
rm -f "$FIXTURE/docs/reviews/some-other-task-r1.json"
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
bash "$IR" "$CHILD17" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
printf '\n=== Section 17 META: REVIEW-ARTIFACT-EXCLUSION is load-bearing ===\n'
# ---------------------------------------------------------------------------

# Under .claude/.qa-tracking/, NOT .claude/scripts/ where this file's OTHER
# mutant copies (Sections 4, 14, 16) live -- those sections never call
# reconcile-tracker, so a mutant sitting in the tracked tree never matters
# to them; THIS section does call it (twice, above and below), and a
# mutant .sh file left in .claude/scripts/ is a REAL untracked path that
# gets rediscovered exactly like the two fixes just above. Same root cause,
# same fix, applied to the mutant file itself this time.
QG_NOEXCL="$FIXTURE/.claude/.qa-tracking/.dua-qa-gate-noreviewexcl.sh"
STRIP17_RC=0
awk '
    /^# REVIEW-ARTIFACT-EXCLUSION BEGIN/ { skip = 1; found = 1; next }
    /^# REVIEW-ARTIFACT-EXCLUSION END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_NOEXCL" || STRIP17_RC=$?
chmod +x "$QG_NOEXCL" 2>/dev/null || true

assert_eq "17.3 META NON-VACUITY: the sentinels were found and the strip ran cleanly" "0" "$STRIP17_RC"
SHIPPED_LINES17=$(wc -l < "$QG" | tr -d '[:space:]')
STRIPPED_LINES17=$(wc -l < "$QG_NOEXCL" | tr -d '[:space:]')
assert_eq "17.3b ...the mutant copy is shorter than the shipped script" \
    "shorter" "$([ "$STRIPPED_LINES17" -lt "$SHIPPED_LINES17" ] && echo shorter || echo same-or-longer)"
P17_RC=0
bash -n "$QG_NOEXCL" 2>/dev/null || P17_RC=$?
assert_eq "17.3c ...and the mutant still parses" "0" "$P17_RC"

# Restore the genuinely-conforming tracker (the unrelated file itself was
# already removed from disk above; this just re-derives $TRACKING's own
# content the same way reconcile always would) before driving the mutant.
printf '%s\n' "$FIXTURE/src/a.sh" > "$TRACKING"
bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
bash "$IR" "$CHILD17" >/dev/null 2>&1 || true
assert_contains "17.3d precondition: the review artifact is STILL in the (restored) tracker" \
    "docs/reviews/" "$(cat "$TRACKING")"

MUT17_OUT=$(bash "$QG_NOEXCL" design-conform "$CHILD17" 2>&1); MUT17_RC=$?
assert_eq "17.4 SPECIFIC MISBEHAVIOUR: WITHOUT the exclusion, the SAME real review cycle is refused (rc=4)" \
    "4" "$MUT17_RC"
assert_eq "17.4b ...error_key=undeclared_files, naming the artifact this task itself wrote" \
    "true" "$(printf '%s' "$MUT17_OUT" | jq -r --arg tid "$CHILD17" '(.error_key == "undeclared_files") and ((.undeclared_files | tostring) | contains($tid))')"

CTRL17_OUT=$(bash "$QG" design-conform "$CHILD17" 2>&1); CTRL17_RC=$?
assert_eq "17.5 RESTORE CONTROL: the SHIPPED script, same state, conforms (rc=0)" "0" "$CTRL17_RC"
assert_eq "17.5b ...ok=true" "true" "$(json_field '.ok' "$CTRL17_OUT")"
rm -f "$QG_NOEXCL"

# ===========================================================================
printf '\n=== Section 18: claude-workflow-plugin-1c82 — a declared, denylisted\n'
printf 'fixture-mirror path must not read as unbuilt ===\n'
# ===========================================================================
# THE DEFECT AS FILED: a unit legitimately declares an e2e fixture-mirror
# path in its OWN files[] (U1-AC8a's `make sync-fixtures` sanctioned route to
# keeping the seven fixture copies byte-identical to a canonical script), but
# workflow_denylisted() means that path can NEVER reach `actual`
# (impact-report.sh's own canonical, denylist-filtered change set) whether it
# was rewritten or not. Pre-fix, `declared - actual` reported it `unbuilt`
# UNCONDITIONALLY — not a measurement of build state, a structural blind
# spot rendered identically to a genuine miss. This section proves the fix
# WITHOUT instantiating the easy (vacuous) case: the declared set carries a
# SECOND, ordinary, non-denylisted file that genuinely was never touched
# either, and THAT one must still show up in unbuilt_files — proving the
# filter removes exactly the denylisted entry, not the whole computation.

ONE_UNIT_DENYLIST_BLOCK='[
  {"unit_id":"U1","role":"devops","goal":"unit touching a fixture mirror",
   "acceptance":[{"id":"AC1","text":"fixture"}],
   "files":["src/real18.sh",".claude/tests/e2e/fixtures/onezerocxx/.claude/scripts/mirrored18.sh"],
   "verification":"make test","depends_on":[]}
]'

EPIC18=$(bd create "1c82 conform: denylisted-declared epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD18=$(bd create "1c82 conform: denylisted-declared child" -t task -p 1 --parent "$EPIC18" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC18" "$ONE_UNIT_DENYLIST_BLOCK" >/dev/null
bash "$QG" design-unit-bind "$CHILD18" --design-task "$EPIC18" --unit-id U1 >/dev/null 2>&1
# U1 declares src/real18.sh (ordinary) + the fixture-mirror path (denylisted).

: > "$TRACKING"
OUT18=$(bash "$QG" design-conform "$CHILD18" 2>&1); RC18=$?
assert_eq "18.1 nothing touched yet: still conforms (rc 0)" "0" "$RC18"
assert_eq "18.1b ok=true" "true" "$(json_field '.ok' "$OUT18")"
assert_eq "18.1c undeclared_files is empty" "0" "$(json_field '.undeclared_files | length' "$OUT18")"
assert_eq "18.1d NOT VACUOUS: unbuilt_files names EXACTLY ONE file, the ORDINARY one — the fixture mirror is excluded, src/real18.sh is not" \
    "src/real18.sh" "$(json_field '.unbuilt_files[0]' "$OUT18")"
assert_eq "18.1e ...and unbuilt_files has length 1, not 2 (the denylisted entry is genuinely gone, not just reordered)" \
    "1" "$(json_field '.unbuilt_files | length' "$OUT18")"
assert_eq "18.1f observations disclose the exclusion count, matching this codebase's own denylisted=N convention" \
    "yes" "$(printf '%s' "$OUT18" | jq -r '.observations' | grep -qF 'denylisted=1' && echo yes || echo no)"

# Tracker membership of the fixture-mirror path must not matter: it is
# excluded from `declared` regardless, because it can never reach `actual`
# either way (impact-report.sh's own denylist filter, applied at the source,
# not something this fix adds). Proven, not assumed.
mkdir -p "$FIXTURE/.claude/tests/e2e/fixtures/onezerocxx/.claude/scripts"
touch "$FIXTURE/.claude/tests/e2e/fixtures/onezerocxx/.claude/scripts/mirrored18.sh"
printf '.claude/tests/e2e/fixtures/onezerocxx/.claude/scripts/mirrored18.sh\n' > "$TRACKING"
OUT18B=$(bash "$QG" design-conform "$CHILD18" 2>&1); RC18B=$?
assert_eq "18.2 the fixture mirror IS now tracked (genuinely synced) — still conforms" "0" "$RC18B"
assert_eq "18.2b ...unbuilt_files is UNCHANGED (still names only src/real18.sh): build state of a denylisted path cannot move this computation either way" \
    "src/real18.sh" "$(json_field '.unbuilt_files[0]' "$OUT18B")"

# ---------------------------------------------------------------------------
printf '\n=== Section 18 META: DENYLIST-EXCLUSION is load-bearing ===\n'
# ---------------------------------------------------------------------------
: > "$TRACKING"
QG_NODENY="$FIXTURE/.claude/.qa-tracking/.dua-qa-gate-nodeny.sh"
STRIP18_RC=0
awk '
    /^    # --- DENYLIST-EXCLUSION \(claude-workflow-plugin-1c82\) --/ { skip = 1; found = 1; next }
    /^    # --- DENYLIST-EXCLUSION END \(claude-workflow-plugin-1c82\) --/ { skip = 0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_NODENY" || STRIP18_RC=$?
chmod +x "$QG_NODENY" 2>/dev/null || true

assert_eq "18.3 META NON-VACUITY: the sentinels were found and the strip ran cleanly" "0" "$STRIP18_RC"
SHIPPED_LINES18=$(wc -l < "$QG" | tr -d '[:space:]')
STRIPPED_LINES18=$(wc -l < "$QG_NODENY" | tr -d '[:space:]')
assert_eq "18.3b ...the mutant copy is shorter than the shipped script" \
    "shorter" "$([ "$STRIPPED_LINES18" -lt "$SHIPPED_LINES18" ] && echo shorter || echo same-or-longer)"
P18_RC=0
bash -n "$QG_NODENY" 2>/dev/null || P18_RC=$?
assert_eq "18.3c ...and the mutant still parses" "0" "$P18_RC"

MUT18_OUT=$(bash "$QG_NODENY" design-conform "$CHILD18" 2>&1); MUT18_RC=$?
assert_eq "18.4 SPECIFIC MISBEHAVIOUR: WITHOUT the filter, still conforms (unbuilt never gates, rc 0)..." "0" "$MUT18_RC"
assert_eq "18.4b ...but unbuilt_files now ALSO names the fixture mirror (length 2, not 1)" \
    "2" "$(json_field '.unbuilt_files | length' "$MUT18_OUT")"
assert_eq "18.4c ...specifically containing the denylisted path the shipped script excludes" \
    "yes" "$(printf '%s' "$MUT18_OUT" | jq -r '.unbuilt_files | tostring' | grep -qF 'onezerocxx' && echo yes || echo no)"

CTRL18_OUT=$(bash "$QG" design-conform "$CHILD18" 2>&1); CTRL18_RC=$?
assert_eq "18.5 RESTORE CONTROL: the SHIPPED script, same state, exit 0 (conforms)" "0" "$CTRL18_RC"
assert_eq "18.5b ...and still excludes the fixture mirror (length 1)" "1" \
    "$(json_field '.unbuilt_files | length' "$CTRL18_OUT")"
rm -f "$QG_NODENY"

# ===========================================================================
printf '\n=== Section 19: claude-workflow-plugin-j4pe R1-F3 — the denylist\n'
printf 'dependency guard must test the FUNCTION, not a variable that can be\n'
printf 'inherited independently ===\n'
# ===========================================================================
# INDEPENDENT REVIEW ROUND 1's OWN REPRODUCTION: WORKFLOW_DENYLIST_REGEX set,
# workflow_denylisted() undefined -> bash prints "command not found" TWICE
# but the pipeline's own exit status stays 0 and the returned array RETAINS
# the denylisted path, because `workflow_denylisted "$p" && continue` treats
# an undefined command (rc 127) as "false", so the "drop it" arm never fires
# and every line falls through to be kept. Reproduced directly against this
# exact pipeline shape before writing this section (not merely trusted from
# the review artifact):
#   $ WORKFLOW_DENYLIST_REGEX=x; declared_json='["a","fixtures/mirror.sh"]'
#   $ <the exact filter pipeline> -> rc=0, result=["a","fixtures/mirror.sh"]
#   (both lines retained; the denylisted one was never dropped)
#
# THE ENVIRONMENT MUTATION this section drives: a copy of the CANONICAL qa-
# gate.sh with ONE line inserted immediately after the top-level TRACKER-
# RECONCILE source block: `unset -f workflow_denylisted`. This leaves
# WORKFLOW_DENYLIST_REGEX exactly as sourced (unset -f touches only the
# function namespace) while making the function itself undefined for the
# REST of that process's execution — the identical state the reviewer's
# in-memory probe constructed, built here as a file so it can actually run
# design-conform end to end rather than a bare pipeline fragment.

EPIC19=$(bd create "j4pe R1-F3 epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD19=$(bd create "j4pe R1-F3 child" -t task -p 1 --parent "$EPIC19" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
design_and_review "$EPIC19" "$ONE_UNIT_DENYLIST_BLOCK" >/dev/null
bash "$QG" design-unit-bind "$CHILD19" --design-task "$EPIC19" --unit-id U1 >/dev/null 2>&1
: > "$TRACKING"

# THE MUTATION THIS SECTION ACTUALLY DRIVES (revised from an earlier `unset -f
# workflow_denylisted` cut): this fix's OWN re-source step (cmd_design_
# conform's DENYLIST-EXCLUSION block, "if ! declare -F ... ; then ... source
# ... fi") makes a bare `unset -f` INSIDE a running qa-gate.sh process a
# non-reproduction — the very first call site re-sources $PROJECT_DIR's own
# workflow-denylist.sh and heals it right back, which is the fix working
# CORRECTLY, not a gap in this test. To reach the state the guard exists for
# — the function genuinely, persistently unavailable, re-source included —
# the SIBLING LIBRARY FILE itself is temporarily replaced with a version that
# defines WORKFLOW_DENYLIST_REGEX (so the variable half of the contract is
# satisfied exactly as the reviewer's own reproduction set up) but OMITS
# workflow_denylisted() entirely — so EVERY source of that path, including
# qa-gate.sh's own top-level TRACKER-RECONCILE read and cmd_design_conform's
# own re-source attempt, loads the SAME function-less file. This lets the
# fully SHIPPED, UNMODIFIED qa-gate.sh run directly against the fault, which
# is a stronger "shipped artifact running" leg than a qa-gate.sh copy would
# have been.
WFDL_LIVE="$FIXTURE/.claude/scripts/workflow-denylist.sh"
WFDL_BACKUP="$FIXTURE/.claude/.qa-tracking/.dua-workflow-denylist-orig.sh"
WFDL_NOFUNC="$FIXTURE/.claude/.qa-tracking/.dua-workflow-denylist-nofunc.sh"
cp "$WFDL_LIVE" "$WFDL_BACKUP"
grep '^WORKFLOW_DENYLIST_REGEX=' "$WFDL_LIVE" > "$WFDL_NOFUNC"
assert_eq "19.1 NON-VACUITY: the variable-only mutant library actually carries the regex line" "1" \
    "$(grep -cF 'WORKFLOW_DENYLIST_REGEX=' "$WFDL_NOFUNC")"
assert_eq "19.1b ...and DELIBERATELY omits the function (grep for its definition finds nothing)" "0" \
    "$(grep -cF 'workflow_denylisted()' "$WFDL_NOFUNC")"
cp "$WFDL_NOFUNC" "$WFDL_LIVE"

M19_OUT=$(bash "$QG" design-conform "$CHILD19" 2>&1); M19_RC=$?
assert_eq "19.2 THE SHIPPED, UNMODIFIED CHECK CODE, run with the sibling library missing its function: refuses, exit 2" "2" "$M19_RC"
assert_eq "19.2b ...error_key=workflow_denylist_unavailable, not a silent unfiltered pass" \
    "workflow_denylist_unavailable" "$(json_field '.error_key' "$M19_OUT")"
assert_contains "19.2c ...observations name which half of the contract was missing" \
    "function present: no" "$M19_OUT"

# --- the OLD (variable-only) shape, LAYERED on the SAME broken library ---
# proves this is a real regression risk, not a hypothetical: revert JUST the
# `! declare -F workflow_denylisted >/dev/null 2>&1 || ` clause this fix
# added (both call sites; sed matches the exact literal, not a region) on a
# COPY of qa-gate.sh, and drive the SAME function-less library through it.
QG_OLDCHECK="$FIXTURE/.claude/.qa-tracking/.dua-qa-gate-mutant19-oldcheck.sh"
sed 's/! declare -F workflow_denylisted >\/dev\/null 2>&1 || //g' "$QG" > "$QG_OLDCHECK"
assert_eq "19.3 NON-VACUITY: the old-shape mutant differs from the shipped script" "differs" \
    "$(cmp -s "$QG" "$QG_OLDCHECK" && echo same || echo differs)"
assert_eq "19.3b ...and still parses" "0" "$(bash -n "$QG_OLDCHECK" 2>/dev/null; echo $?)"
chmod +x "$QG_OLDCHECK"

# stdout and stderr captured SEPARATELY, deliberately: the OLD (variable-
# only) shape never detects the missing function, so execution reaches the
# ACTUAL filtering pipeline and calls the genuinely-undefined
# workflow_denylisted() directly -- printing "command not found" to stderr
# exactly as the reviewer's own reproduction measured. Mixed into stdout via
# a bare `2>&1` (as design-conform.test.sh's own Section 17 crash, fixed
# earlier this cycle, already proved once) that text breaks jq's parse of
# the JSON that follows it, which would make THIS assertion fail for a
# harness reason having nothing to do with the production misbehaviour being
# proven. Separating them lets both halves of the reviewer's own observation
# be asserted directly: the noisy diagnostic (19.4a) AND the wrong-but-well-
# formed JSON underneath it (19.4b/c/d).
M19OLD_ERR="$FIXTURE/.claude/.qa-tracking/.dua-m19old-stderr.txt"
M19OLD_OUT=$(bash "$QG_OLDCHECK" design-conform "$CHILD19" 2>"$M19OLD_ERR"); M19OLD_RC=$?
assert_eq "19.4 SPECIFIC MISBEHAVIOUR: the OLD variable-only check, same broken library, exit 0 (silently WRONG)" "0" "$M19OLD_RC"
assert_contains "19.4a ...stderr carries the SAME 'command not found' diagnostic the reviewer's own reproduction measured" \
    "workflow_denylisted: command not found" "$(cat "$M19OLD_ERR" 2>/dev/null)"
assert_eq "19.4b ...ok=true, never refused" "true" "$(json_field '.ok' "$M19OLD_OUT")"
assert_eq "19.4c ...and 1c82's OWN defect shape is back: unbuilt_files now names the fixture mirror (length 2, not 1)" \
    "2" "$(json_field '.unbuilt_files | length' "$M19OLD_OUT")"
assert_contains "19.4d ...specifically re-including the denylisted path the shipped check would have refused over" \
    "onezerocxx" "$M19OLD_OUT"
rm -f "$QG_OLDCHECK" "$M19OLD_ERR"

# --- restore the real library BEFORE the control, or 19.5 tests nothing ---
cp "$WFDL_BACKUP" "$WFDL_LIVE"
assert_eq "19.5 precondition: the sibling library is genuinely restored (function defined again)" "1" \
    "$(grep -cF 'workflow_denylisted()' "$WFDL_LIVE")"

CTRL19_OUT=$(bash "$QG" design-conform "$CHILD19" 2>&1); CTRL19_RC=$?
assert_eq "19.5b RESTORE CONTROL: the SHIPPED script, library restored, exit 0 (conforms)" "0" "$CTRL19_RC"
assert_eq "19.5c ...and correctly excludes the fixture mirror (length 1, not 2)" "1" \
    "$(json_field '.unbuilt_files | length' "$CTRL19_OUT")"
rm -f "$WFDL_BACKUP" "$WFDL_NOFUNC"

# ===========================================================================
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

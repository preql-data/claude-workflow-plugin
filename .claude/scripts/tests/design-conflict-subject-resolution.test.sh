#!/bin/bash
# design-conflict-subject-resolution.test.sh — claude-workflow-plugin-268l.
#
# THE DEFECT. cmd_design_conflict (the writer) and compute_design_conflict_
# open (the reader) both used to take <task-id> itself as the SUBJECT — the
# task whose docs/specs/<id>.md and comment stream a conflict is filed
# against and read from. Under v5 task-per-unit the unit task id and the
# design task id differ BY CONSTRUCTION (a DESIGN-UNIT binding, written by
# design-unit-bind, names a DIFFERENT task as the design owner), so asking
# either function about a bound unit task asked about a comment stream that
# structurally cannot hold the record. THE FIX resolves the subject through
# resolve_design_conflict_subject (qa-gate.sh) FIRST: <tid>'s own DESIGN-UNIT
# binding, when one exists, names the real subject; when none exists, <tid>
# remains its own subject — byte-identical to the pre-fix behaviour, because
# a task that owns its design DIRECTLY (no binding at all) is a real,
# already-exercised shape (worktree-approval-resolution.sh 8b, design-gate-
# precheck-wiring.test.sh 1b), not a hypothetical.
#
# WHAT THIS FILE PROVES, IN ORDER:
#   Section 1  fixture — a satisfied design task (TID_D, units U1/U2) and two
#              unit tasks bound to it (TID_U -> U1, TID_U2 -> U2).
#   Section 2  THE ROUND TRIP, shipped script: filing a conflict via the
#              BOUND unit task TID_U lands on TID_D (never on TID_U), and
#              design-gate-precheck TID_U — asked about the UNIT task —
#              correctly refuses, naming U1.
#   Section 3  THE UNBOUND CASE, shipped script: a task (TID_V) that owns its
#              own design DIRECTLY, no binding at all — filing and detecting
#              a conflict against it must work exactly as before. This is
#              the answered design question (resolve_design_conflict_
#              subject's own header) pinned as an executable, not left as
#              prose. TID_V's conflict is left OPEN deliberately, for reuse
#              as Section 5's mutant discriminator.
#   Section 4  THE UNREADABLE-SOURCE CASE, shipped script: a nonexistent
#              task id refuses distinctly on both the writer and the reader
#              — never silently "no conflict".
#   Section 5  THE READER MUTATION — the misdirection, proved both ways.
#              Strip resolve_design_conflict_subject's call out of compute_
#              design_conflict_open; the mutant is blind to TID_D's real,
#              open conflict when asked about TID_U (the pre-fix bug,
#              reproduced live); the shipped script sees it (already proved
#              in Section 2, re-asserted here for a clean side-by-side).
#              Discriminator: the SAME mutant still correctly detects TID_V's
#              (unbound) conflict — it is blind to the RESOLVED-subject case
#              specifically, not to conflict detection in general.
#   Section 6  THE WRITER MUTATION — same shape, for cmd_design_conflict:
#              the mutant cannot file a conflict for TID_U2 at all
#              (design_artifact_not_found — nothing produces one), the
#              shipped script succeeds and lands it on TID_D.
#   Section 7  PRODUCER WIRING — backend.md/frontend.md/devops.md each name
#              the exact subcommand (structural), and the subcommand they
#              name really exists and runs (already proved live by Sections
#              2/3/4/6; Section 7 adds the cheap, direct "recognised by the
#              CLI dispatcher" leg design-unit-bind-parity.test.sh's own
#              section 1 uses: bare invocation -> missing_task_id, not an
#              unknown-subcommand fall-through).
#
# PAIRING (`.claude/tests/README.md` "The pairing requirement"), per mutant:
#   (a) NON-VACUITY   — sentinel found, strip landed (byte-shorter + grep
#                        absent), `bash -n` still parses.
#   (b) MISBEHAVIOUR  — the mutant fails in the SPECIFIC way the guard
#                        prevents (named error_key / status, not "differs").
#   (c) RESTORE       — the SAME fixture state, shipped script, correct.
#   (d) EXECUTION     — every leg above drives the real subprocess; nothing
#                        here is a source-level grep standing in for a run.
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
# Fixture — self-contained (design-gate-precheck-wiring.test.sh's own header
# explains why: not coupled to a file this task does not own).
# ===========================================================================

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"

if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — design-conflict-subject-resolution tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — design-conflict-subject-resolution tests require jq."
    exit 2
fi
REAL_GIT="$(command -v git)"
if [ -z "$REAL_GIT" ]; then
    echo "git not on PATH — design-conflict-subject-resolution tests require git."
    exit 2
fi

FIXTURE=$(mktemp -d -t design-conflict-subject.XXXXXX)
TEST_HOME=$(mktemp -d -t design-conflict-subject-home.XXXXXX)
KEEP_FIXTURE="${KEEP_FIXTURE:-0}"
[ "${1:-}" = "--keep" ] && KEEP_FIXTURE=1

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

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
WM="$FIXTURE/.claude/scripts/workflow-manifest.sh"

printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' > "$FIXTURE/.gitignore"
(cd "$FIXTURE" && "$REAL_GIT" init -q \
    && "$REAL_GIT" config user.email t@t.t && "$REAL_GIT" config user.name t \
    && "$REAL_GIT" add -A && "$REAL_GIT" commit -qm baseline >/dev/null) || true

bash "$QG" baseline-capture --by session-start --exclude-tracked >/dev/null 2>&1 || true

design_artifact_path() {
    local sanitized
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/docs/specs/%s.md' "$FIXTURE" "$sanitized"
}

# write_artifact <path> <tid> <u1-goal> <u2-goal> — byte-shape borrowed from
# design-gate-precheck-wiring.test.sh's own write_artifact (not sourced —
# see this file's own header on self-containment).
write_artifact() {
    local path="$1" tid="$2" u1_goal="${3:-goal for unit U1}" u2_goal="${4:-goal for unit U2}"
    cat > "$path" <<ARTIFACT
# Design — $tid

## Problem
Component-tier test subject (design-conflict-subject-resolution.test.sh).

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
      "role": "backend",
      "goal": "$u1_goal",
      "acceptance": [ { "id": "AC1", "text": "test fixture: nothing asserted" } ],
      "files": [ ".claude/scripts/qa-gate.sh" ],
      "verification": "make test",
      "depends_on": []
    },
    {
      "unit_id": "U2",
      "role": "backend",
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

seed_grilling() {
    local tid="$1"
    bash "$QG" grilling-record "$tid" --rounds 3 --questions 5 --approaches 2 --unresolved 0 \
        "design-conflict-subject-resolution.test.sh: exercising the 268l subject fix" \
        >/dev/null 2>&1
}

VALID_VERDICT='{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"ok"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}'

# design_task <tid-var-name> <label> — creates a bd task, writes+records+
# reviews a satisfied two-unit design for it, returns the id on stdout.
new_designed_task() {
    local label="$1"
    local tid art hash
    tid=$(cd "$FIXTURE" && bd create "$label" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    [ -n "$tid" ] || { echo "harness error: bd create failed for '$label'" >&2; exit 2; }
    art="$(design_artifact_path "$tid")"
    write_artifact "$art" "$tid"
    printf '%s\n' "$tid" > "$FIXTURE/.claude/.qa-tracking/current-task"
    printf '%s\n' "$art" > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
    bash "$QG" enter "$tid" >/dev/null 2>&1
    seed_grilling "$tid"
    bash "$QG" design-record "$tid" >/dev/null 2>&1
    hash=$(bash "$WM" hash-file "$art")
    printf '%s' "$VALID_VERDICT" | bash "$QG" design-review-record "$tid" --design-hash "$hash" >/dev/null 2>&1
    printf '%s' "$tid"
}

comments_of() {
    bd show "$1" --json --include-comments 2>/dev/null \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text' \
        2>/dev/null || echo ""
}

# ===========================================================================
printf '\n=== Section 1: fixture — a satisfied design (TID_D, U1/U2) and two bound unit tasks ===\n'
# ===========================================================================

TID_D=$(new_designed_task "268l: design task owning docs/specs directly")

TID_U=$(cd "$FIXTURE" && bd create "268l: unit task bound to U1" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
[ -n "$TID_U" ] || { echo "harness error: bd create failed for TID_U" >&2; exit 2; }
BIND_U=$(bash "$QG" design-unit-bind "$TID_U" --design-task "$TID_D" --unit-id U1 2>&1)
assert_eq "1.1 precondition: TID_U bound to TID_D:U1 succeeds" "recorded" "$(json_field '.status' "$BIND_U")"

TID_U2=$(cd "$FIXTURE" && bd create "268l: unit task bound to U2" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
[ -n "$TID_U2" ] || { echo "harness error: bd create failed for TID_U2" >&2; exit 2; }
BIND_U2=$(bash "$QG" design-unit-bind "$TID_U2" --design-task "$TID_D" --unit-id U2 2>&1)
assert_eq "1.2 precondition: TID_U2 bound to TID_D:U2 succeeds" "recorded" "$(json_field '.status' "$BIND_U2")"

assert_eq "1.3 precondition: TID_U and TID_D are DIFFERENT tasks (the whole premise of the bug)" \
    "different" "$([ "$TID_U" != "$TID_D" ] && echo different || echo same)"

# ===========================================================================
printf '\n=== Section 2: THE ROUND TRIP (shipped script) — file via TID_U, lands on TID_D ===\n'
# ===========================================================================

CONFLICT_OUT=$(bash "$QG" design-conflict "$TID_U" --unit U1 "268l round trip: U1 assumes an endpoint that does not exist" 2>&1)
assert_eq "2.1 design-conflict on the BOUND unit task succeeds" "recorded" "$(json_field '.status' "$CONFLICT_OUT")"
assert_contains "2.2 ...the observations name TID_D as where it was resolved to" "$TID_D" "$(json_field '.observations' "$CONFLICT_OUT")"

D_COMMENTS=$(comments_of "$TID_D")
U_COMMENTS=$(comments_of "$TID_U")
assert_contains "2.3 THE FIX: the DESIGN-CONFLICT record landed on TID_D (the resolved subject)" \
    "DESIGN-CONFLICT U1 " "$D_COMMENTS"
assert_not_contains "2.4 ...and NOT on TID_U (the pre-fix, wrong subject)" \
    "DESIGN-CONFLICT U1 " "$U_COMMENTS"

PRECHECK_U=$(bash "$QG" design-gate-precheck "$TID_U" 2>&1); PRECHECK_U_RC=$?
assert_eq "2.5 design-gate-precheck TID_U (asked about the UNIT task) now refuses" "4" "$PRECHECK_U_RC"
assert_eq "2.6 ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$PRECHECK_U")"
assert_contains "2.7 ...names U1" "U1" "$(json_field '.observations' "$PRECHECK_U")"
assert_contains "2.8 ...names TID_D as the resolved design task" "$TID_D" "$(json_field '.observations' "$PRECHECK_U")"

# ===========================================================================
printf '\n=== Section 3: THE UNBOUND CASE (shipped script) — TID_V owns its OWN design, no binding ===\n'
# ===========================================================================
# The answered design question, pinned as an executable: <tid> with NO
# DESIGN-UNIT binding becomes its own subject, byte-identical to the pre-268l
# behaviour. TID_V's conflict is left OPEN deliberately — Section 5 reuses it
# as the mutant discriminator (a fact the READER mutant must still get right).

TID_V=$(new_designed_task "268l: task that owns its OWN design directly (no binding)")
BOUND_V=$(bash "$QG" design-unit-show "$TID_V" 2>&1)
assert_eq "3.1 precondition: TID_V carries NO DESIGN-UNIT binding" "false" "$(json_field '.bound' "$BOUND_V")"

CONFLICT_V=$(bash "$QG" design-conflict "$TID_V" --unit U1 "268l unbound case: U1 is contradicted by the code" 2>&1)
assert_eq "3.2 design-conflict on the UNBOUND task still succeeds directly" "recorded" "$(json_field '.status' "$CONFLICT_V")"
assert_eq "3.2b R1-F4: the structured design_task field falls back to TID_V itself (unbound)" \
    "$TID_V" "$(json_field '.design_task' "$CONFLICT_V")"
V_COMMENTS=$(comments_of "$TID_V")
assert_contains "3.3 ...and lands on TID_V itself (no binding to redirect through)" \
    "DESIGN-CONFLICT U1 " "$V_COMMENTS"

PRECHECK_V=$(bash "$QG" design-gate-precheck "$TID_V" 2>&1); PRECHECK_V_RC=$?
assert_eq "3.4 design-gate-precheck TID_V refuses on its OWN conflict (fallback-to-self unchanged)" "4" "$PRECHECK_V_RC"
assert_eq "3.5 ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$PRECHECK_V")"

# ===========================================================================
printf '\n=== Section 4: THE UNREADABLE-SOURCE CASE (shipped script) — a nonexistent task id ===\n'
# ===========================================================================
# Neither the writer nor the reader may silently read "cannot tell if bound"
# as "no conflict" — see resolve_design_conflict_subject's own header.

NOPE="no-such-task-268l-$$"

CONFLICT_NOPE=$(bash "$QG" design-conflict "$NOPE" --unit U1 "should never be recorded" 2>&1); CONFLICT_NOPE_RC=$?
assert_eq "4.1 design-conflict on a NONEXISTENT task refuses (exit 2)" "2" "$CONFLICT_NOPE_RC"
assert_eq "4.2 ...error_key=design_binding_unreadable (not missing_unit_id or any unrelated key)" \
    "design_binding_unreadable" "$(json_field '.error_key' "$CONFLICT_NOPE")"

PRECHECK_NOPE=$(bash "$QG" design-gate-precheck "$NOPE" 2>&1); PRECHECK_NOPE_RC=$?
assert_eq "4.3 design-gate-precheck on the SAME nonexistent task refuses (exit 4)" "4" "$PRECHECK_NOPE_RC"
assert_eq "4.4 ...error_key=design_conflict_source_unreadable (never 'ready', never 'no conflict')" \
    "design_conflict_source_unreadable" "$(json_field '.error_key' "$PRECHECK_NOPE")"

# ===========================================================================
printf '\n=== Section 5: THE READER MUTATION — the misdirection, before and after ===\n'
# ===========================================================================

QG_REAL="$FIXTURE/.claude/scripts/qa-gate.sh"
QG_MUT_READER="$FIXTURE/.claude/scripts/qa-gate-reader-mut.sh"
READER_STRIP_RC=0
awk '
    /# DESIGN-CONFLICT-READER-SUBJECT-RESOLUTION BEGIN/ { skipping=1; found=1; next }
    /# DESIGN-CONFLICT-READER-SUBJECT-RESOLUTION END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG_REAL" > "$QG_MUT_READER" || READER_STRIP_RC=$?
chmod +x "$QG_MUT_READER"

# (a) NON-VACUITY
assert_eq "5a.1 META: READER-SUBJECT-RESOLUTION sentinels present, strip landed" "0" "$READER_STRIP_RC"
READER_MUT_PARSE=0
bash -n "$QG_MUT_READER" 2>/dev/null || READER_MUT_PARSE=$?
assert_eq "5a.2 META: the stripped copy still parses" "0" "$READER_MUT_PARSE"
assert_eq "5a.3 META: the strip landed a SHORTER file (not a no-op match)" \
    "shorter" "$([ "$(wc -l < "$QG_MUT_READER")" -lt "$(wc -l < "$QG_REAL")" ] && echo shorter || echo same-or-longer)"
assert_eq "5a.4 DISCRIMINATOR: the mutant is a SURGICAL strip — the WRITER's own sentinel survives untouched" \
    "yes" "$(grep -q 'DESIGN-CONFLICT-WRITER-SUBJECT-RESOLUTION BEGIN' "$QG_MUT_READER" && echo yes || echo no)"

# (b) SPECIFIC MISBEHAVIOUR — the exact wrong-subject masquerade: asked about
# TID_U, the mutant checks TID_U's OWN (conflict-free) stream and reports
# ready, even though TID_D genuinely has an open conflict governing U1.
PRECHECK_U_MUT=$(bash "$QG_MUT_READER" design-gate-precheck "$TID_U" 2>&1); PRECHECK_U_MUT_RC=$?
assert_eq "5b.1 THE MISDIRECTION, REPRODUCED LIVE: mutant reports TID_U ready (blind to TID_D's real conflict)" \
    "0" "$PRECHECK_U_MUT_RC"
assert_eq "5b.2 ...status=ready" "ready" "$(json_field '.status' "$PRECHECK_U_MUT")"

# (a continued) DISCRIMINATOR — the SAME mutant still correctly detects
# TID_V's (unbound) conflict: it is blind to the RESOLVED-subject case
# specifically, not to conflict detection as a whole (rules out "the mutant
# is just globally broken").
PRECHECK_V_MUT=$(bash "$QG_MUT_READER" design-gate-precheck "$TID_V" 2>&1); PRECHECK_V_MUT_RC=$?
assert_eq "5a.5 DISCRIMINATOR: the SAME mutant still refuses TID_V (unbound conflicts are unaffected)" "4" "$PRECHECK_V_MUT_RC"
assert_eq "5a.6 ...error_key=design_conflict_open, proving the mutant is not simply broken end to end" \
    "design_conflict_open" "$(json_field '.error_key' "$PRECHECK_V_MUT")"

# (c) RESTORE CONTROL — same fixture state, shipped script, correct (already
# proved in 2.5/2.6 above; re-asserted here immediately beside the mutant for
# a clean side-by-side rather than a citation back).
PRECHECK_U_SHIPPED=$(bash "$QG_REAL" design-gate-precheck "$TID_U" 2>&1); PRECHECK_U_SHIPPED_RC=$?
assert_eq "5c.1 RESTORE CONTROL: the SHIPPED script, same state, still refuses TID_U" "4" "$PRECHECK_U_SHIPPED_RC"
assert_eq "5c.2 ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$PRECHECK_U_SHIPPED")"

# (d) EXECUTION — 5b.1/5c.1 above both drove the real subprocess (mutant and
# shipped respectively); nothing in this section is a source-level grep.

# ===========================================================================
printf '\n=== Section 6: THE WRITER MUTATION — nothing produces one, before and after ===\n'
# ===========================================================================

QG_MUT_WRITER="$FIXTURE/.claude/scripts/qa-gate-writer-mut.sh"
WRITER_STRIP_RC=0
awk '
    /# DESIGN-CONFLICT-WRITER-SUBJECT-RESOLUTION BEGIN/ { skipping=1; found=1; next }
    /# DESIGN-CONFLICT-WRITER-SUBJECT-RESOLUTION END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG_REAL" > "$QG_MUT_WRITER" || WRITER_STRIP_RC=$?
chmod +x "$QG_MUT_WRITER"

# (a) NON-VACUITY
assert_eq "6a.1 META: WRITER-SUBJECT-RESOLUTION sentinels present, strip landed" "0" "$WRITER_STRIP_RC"
WRITER_MUT_PARSE=0
bash -n "$QG_MUT_WRITER" 2>/dev/null || WRITER_MUT_PARSE=$?
assert_eq "6a.2 META: the stripped copy still parses" "0" "$WRITER_MUT_PARSE"
assert_eq "6a.3 META: the strip landed a SHORTER file (not a no-op match)" \
    "shorter" "$([ "$(wc -l < "$QG_MUT_WRITER")" -lt "$(wc -l < "$QG_REAL")" ] && echo shorter || echo same-or-longer)"
assert_eq "6a.4 DISCRIMINATOR: the mutant is a SURGICAL strip — the READER's own sentinel survives untouched" \
    "yes" "$(grep -q 'DESIGN-CONFLICT-READER-SUBJECT-RESOLUTION BEGIN' "$QG_MUT_WRITER" && echo yes || echo no)"

# (b) SPECIFIC MISBEHAVIOUR — TID_U2 is a legitimately bound v5 unit task
# (bound to TID_D:U2 in Section 1) with no docs/specs/<id>.md of its own; the
# mutant never resolves the binding, so it looks for TID_U2's OWN artifact
# and refuses — "nothing produces one", the writer half of the bug title.
CONFLICT_U2_MUT=$(bash "$QG_MUT_WRITER" design-conflict "$TID_U2" --unit U2 "should not be recordable under the mutant" 2>&1); CONFLICT_U2_MUT_RC=$?
assert_eq "6b.1 THE MISDIRECTION, REPRODUCED LIVE: mutant cannot file a conflict for a legitimately bound unit task" \
    "1" "$CONFLICT_U2_MUT_RC"
assert_eq "6b.2 ...error_key=design_artifact_not_found (looked for TID_U2's OWN, nonexistent artifact)" \
    "design_artifact_not_found" "$(json_field '.error_key' "$CONFLICT_U2_MUT")"

# (a continued) DISCRIMINATOR — the SAME writer mutant still correctly files
# an ORDINARY (Mode A, unbound) conflict, proving it is blind specifically to
# subject RESOLUTION, not to filing conflicts as a whole. A throwaway task is
# used (not TID_V) so this leg cannot be mistaken for reusing TID_V's
# already-filed record.
TID_W=$(new_designed_task "268l: writer-mutant discriminator, unbound")
CONFLICT_W_MUT=$(bash "$QG_MUT_WRITER" design-conflict "$TID_W" --unit U1 "discriminator: unbound tasks still work under the writer mutant" 2>&1)
assert_eq "6a.5 DISCRIMINATOR: the SAME mutant still files an ordinary (unbound) conflict directly" \
    "recorded" "$(json_field '.status' "$CONFLICT_W_MUT")"

# (c) RESTORE CONTROL — shipped script, same TID_U2, succeeds and lands on
# TID_D (never on TID_U2).
CONFLICT_U2_SHIPPED=$(bash "$QG_REAL" design-conflict "$TID_U2" --unit U2 "268l writer restore control: U2 acceptance criteria contradicted" 2>&1)
assert_eq "6c.1 RESTORE CONTROL: the SHIPPED script files the SAME conflict successfully" \
    "recorded" "$(json_field '.status' "$CONFLICT_U2_SHIPPED")"
D_COMMENTS_AFTER_U2=$(comments_of "$TID_D")
U2_COMMENTS=$(comments_of "$TID_U2")
assert_contains "6c.2 ...and it landed on TID_D" "DESIGN-CONFLICT U2 " "$D_COMMENTS_AFTER_U2"
assert_not_contains "6c.3 ...never on TID_U2 itself" "DESIGN-CONFLICT U2 " "$U2_COMMENTS"

# (d) EXECUTION — 6b.1/6a.5/6c.1 above all drove the real subprocess.

# ===========================================================================
printf '\n=== Section 7: PRODUCER WIRING — the prompts name it, the subcommand exists ===\n'
# ===========================================================================
# Producer wiring is prose, so it is paired the way this repo pairs prose
# (.claude/tests/README.md "The pairing requirement"): a structural assertion
# that the instruction exists and names the real subcommand, plus a leg that
# the subcommand it names actually exists and runs. The "runs" half is
# already proved live by Sections 2/3/4/6 above; this section adds the
# cheap, direct "recognised by the CLI dispatcher" leg (design-unit-bind-
# parity.test.sh's own section 1 shape: a bare invocation must reach the
# subcommand's OWN missing_task_id, not an unknown-subcommand fall-through).

for role in backend frontend devops; do
    PROMPT="$PLUGIN_DIR/.claude/agents/$role.md"
    HIT=$(grep -c 'qa-gate\.sh design-conflict' "$PROMPT" 2>/dev/null || echo 0)
    assert_eq "7.$role.1 STRUCTURAL: $role.md names 'qa-gate.sh design-conflict' at least once" \
        "yes" "$([ "${HIT:-0}" -ge 1 ] 2>/dev/null && echo yes || echo no)"
done

BARE_OUT=$(bash "$QG" design-conflict 2>/dev/null); BARE_RC=$?
assert_eq "7.exists.1 EXISTENCE: the CLI dispatcher recognises design-conflict (not an unknown-subcommand fall-through)" \
    "1" "$BARE_RC"
assert_eq "7.exists.2 ...reaches cmd_design_conflict's OWN missing_task_id, not a generic dispatch error" \
    "missing_task_id" "$(json_field '.error_key' "$BARE_OUT")"

# ===========================================================================
printf '\n=== Section 8: THE WRITE-CONFIRMATION GATE (QA round 1, R1-F1, HIGH) ===\n'
# ===========================================================================
# add_comment ends in `|| log_sync_error ...`, and log_sync_error ends in
# `printf ... || true`, so add_comment ALWAYS returns 0 — a transient store
# failure leaves cmd_design_conflict reporting "recorded" for a write that
# never happened, and design-gate-precheck then reads the resulting silence
# as no-conflict: THE one comment-only record in this file whose ABSENCE is
# the PERMISSIVE state, so a lost write here is a false PASS, not a merely
# confusing refusal (claude-workflow-plugin-nod4's own P1-not-P0 argument
# inverts for this record type). Fixed the same way cmd_design_unit_bind's
# own WRITE-CONFIRMATION-GATE (qa-gate.sh, ~80 lines away) already does:
# re-read the exact thing just written and refuse rather than trust add_
# comment's exit status, which proves nothing.
#
# A FRESH design/unit pair, entirely separate from every earlier section's
# state, so this section is order-independent and its own confirmation
# checks are never confused by an ALREADY-open conflict record left behind
# by Sections 2/3/6.

TID_D8=$(new_designed_task "268l R1-F1: write-confirmation gate design task")
TID_U8=$(cd "$FIXTURE" && bd create "268l R1-F1: write-confirmation gate unit task" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
[ -n "$TID_U8" ] || { echo "harness error: bd create failed for TID_U8" >&2; exit 2; }
BIND_U8=$(bash "$QG" design-unit-bind "$TID_U8" --design-task "$TID_D8" --unit-id U1 2>&1)
assert_eq "8.0 precondition: TID_U8 bound to TID_D8:U1 succeeds" "recorded" "$(json_field '.status' "$BIND_U8")"

# bin-writefail/bd — a real-bd passthrough EXCEPT both comment-write
# syntaxes, which exit 1 unconditionally: the exact "bd shim failing BOTH
# comment-write syntaxes" QA measured against. `show`, `create`, and
# everything else the resolution/confirmation reads need still reaches the
# real store.
mkdir -p "$FIXTURE/bin-writefail"
cat > "$FIXTURE/bin-writefail/bd" <<EOF
#!/bin/bash
case "\${1:-}" in
    comments|comment)
        [ "\${2:-}" = "add" ] && exit 1
        ;;
esac
exec ${REAL_BD} "\$@"
EOF
chmod +x "$FIXTURE/bin-writefail/bd"

QG_MUT_WC="$FIXTURE/.claude/scripts/qa-gate-writeconfirm-mut.sh"
WC_STRIP_RC=0
awk '
    /# WRITE-CONFIRMATION-GATE BEGIN \(268l, R1-F1\)/ { skipping=1; found=1; next }
    /# WRITE-CONFIRMATION-GATE END \(268l, R1-F1\)/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG_REAL" > "$QG_MUT_WC" || WC_STRIP_RC=$?
chmod +x "$QG_MUT_WC"

# (a) NON-VACUITY
assert_eq "8a.1 META: WRITE-CONFIRMATION-GATE sentinels present, strip landed" "0" "$WC_STRIP_RC"
WC_MUT_PARSE=0
bash -n "$QG_MUT_WC" 2>/dev/null || WC_MUT_PARSE=$?
assert_eq "8a.2 META: the stripped copy still parses" "0" "$WC_MUT_PARSE"
assert_eq "8a.3 META: the strip landed a SHORTER file (not a no-op match)" \
    "shorter" "$([ "$(wc -l < "$QG_MUT_WC")" -lt "$(wc -l < "$QG_REAL")" ] && echo shorter || echo same-or-longer)"
assert_eq "8a.4 DISCRIMINATOR: the mutant is a SURGICAL strip — both subject-resolution sentinels survive untouched" \
    "yes" "$(grep -q 'DESIGN-CONFLICT-WRITER-SUBJECT-RESOLUTION BEGIN' "$QG_MUT_WC" && grep -q 'DESIGN-CONFLICT-READER-SUBJECT-RESOLUTION BEGIN' "$QG_MUT_WC" && echo yes || echo no)"

# (b) SPECIFIC MISBEHAVIOUR — the exact defect QA measured, reproduced live:
# the mutant reports rc=0/status=recorded for a write the failing shim never
# let land.
MUT_LOSTWRITE_TEXT="8b lost-write probe: this text must NOT land ($$)"
MUT_LOSTWRITE_OUT=$(PATH="$FIXTURE/bin-writefail:$PATH" bash "$QG_MUT_WC" design-conflict "$TID_U8" --unit U1 "$MUT_LOSTWRITE_TEXT" 2>&1); MUT_LOSTWRITE_RC=$?
assert_eq "8b.1 THE DEFECT, REPRODUCED LIVE: mutant + failing write reports rc=0/status=recorded" \
    "0|recorded" "$MUT_LOSTWRITE_RC|$(json_field '.status' "$MUT_LOSTWRITE_OUT")"
D8_COMMENTS_AFTER_LOST=$(comments_of "$TID_D8")
assert_not_contains "8b.2 ...even though the record it claims to have posted is GENUINELY ABSENT from TID_D8" \
    "$MUT_LOSTWRITE_TEXT" "$D8_COMMENTS_AFTER_LOST"

# (c) RESTORE CONTROL — the shipped script, identical failing shim, refuses
# instead of falsely claiming success.
SHIPPED_LOSTWRITE_TEXT="8c lost-write probe: this text must NOT land either ($$)"
SHIPPED_LOSTWRITE_OUT=$(PATH="$FIXTURE/bin-writefail:$PATH" bash "$QG_REAL" design-conflict "$TID_U8" --unit U1 "$SHIPPED_LOSTWRITE_TEXT" 2>&1); SHIPPED_LOSTWRITE_RC=$?
assert_eq "8c.1 RESTORE CONTROL: shipped script + failing write refuses (exit 5)" "5" "$SHIPPED_LOSTWRITE_RC"
assert_eq "8c.2 ...error_key=design_conflict_write_unconfirmed" \
    "design_conflict_write_unconfirmed" "$(json_field '.error_key' "$SHIPPED_LOSTWRITE_OUT")"
D8_COMMENTS_AFTER_SHIPPED_LOST=$(comments_of "$TID_D8")
assert_not_contains "8c.3 ...and, correctly, nothing was recorded (the write really did fail, this is not a false refusal)" \
    "$SHIPPED_LOSTWRITE_TEXT" "$D8_COMMENTS_AFTER_SHIPPED_LOST"

# (d) the shipped positive path — write genuinely succeeds, is genuinely
# confirmed present, and the round trip through design-gate-precheck sees
# the real conflict afterward. Not a mutation leg; the ordinary success case
# this gate must never block.
SHIPPED_OK_TEXT="8d genuine write probe: this text SHOULD land ($$)"
SHIPPED_OK_OUT=$(bash "$QG_REAL" design-conflict "$TID_U8" --unit U1 "$SHIPPED_OK_TEXT" 2>&1); SHIPPED_OK_RC=$?
assert_eq "8d.1 shipped script, healthy store: succeeds normally" "0|recorded" "$SHIPPED_OK_RC|$(json_field '.status' "$SHIPPED_OK_OUT")"
assert_eq "8d.1b R1-F4: the structured design_task field names the RESOLVED subject (TID_D8), not TID_U8" \
    "$TID_D8" "$(json_field '.design_task' "$SHIPPED_OK_OUT")"
assert_eq "8d.1c R1-F4: the structured unit_id field is present too, matching design-unit-show's own precedent shape" \
    "U1" "$(json_field '.unit_id' "$SHIPPED_OK_OUT")"
D8_COMMENTS_AFTER_OK=$(comments_of "$TID_D8")
assert_contains "8d.2 ...and the record is genuinely present this time" "$SHIPPED_OK_TEXT" "$D8_COMMENTS_AFTER_OK"
PRECHECK_U8=$(bash "$QG_REAL" design-gate-precheck "$TID_U8" 2>&1); PRECHECK_U8_RC=$?
assert_eq "8d.3 ...and design-gate-precheck now genuinely refuses on it" "4" "$PRECHECK_U8_RC"
assert_eq "8d.4 ...error_key=design_conflict_open" "design_conflict_open" "$(json_field '.error_key' "$PRECHECK_U8")"

# (a continued) DISCRIMINATOR — the SAME mutant, healthy store: still
# succeeds genuinely. Proves the strip is blind SPECIFICALLY to a lost
# write, not to filing conflicts as a whole.
MUT_OK_TEXT="8e mutant genuine write probe: this text SHOULD land too ($$)"
MUT_OK_OUT=$(bash "$QG_MUT_WC" design-conflict "$TID_U8" --unit U1 "$MUT_OK_TEXT" 2>&1); MUT_OK_RC=$?
assert_eq "8a.5 DISCRIMINATOR: the SAME mutant, healthy store, still succeeds genuinely" \
    "0|recorded" "$MUT_OK_RC|$(json_field '.status' "$MUT_OK_OUT")"
D8_COMMENTS_AFTER_MUT_OK=$(comments_of "$TID_D8")
assert_contains "8a.6 ...and the record really is present (not a vacuous rc=0)" "$MUT_OK_TEXT" "$D8_COMMENTS_AFTER_MUT_OK"

# (e) the OTHER new refusal: the confirmation RE-READ itself fails (as
# opposed to succeeding but not showing the record). This sits OUTSIDE the
# WRITE-CONFIRMATION-GATE sentinel (matching cmd_design_unit_bind's own
# confirm_rc-before-mismatch ordering), so there is no region to mutate —
# it is proved directly, live, against the shipped script: a shim that lets
# the write and the SUBJECT's own resolution read through normally but
# fails `bd show` specifically for the DESIGN task (the confirmation read's
# own target), simulating bd becoming unreachable in the gap between the
# write and the re-read.
mkdir -p "$FIXTURE/bin-showfail-subject"
cat > "$FIXTURE/bin-showfail-subject/bd" <<EOF
#!/bin/bash
if [ "\${1:-}" = "show" ] && [ "\${2:-}" = "$TID_D8" ]; then
    exit 1
fi
exec ${REAL_BD} "\$@"
EOF
chmod +x "$FIXTURE/bin-showfail-subject/bd"
CONFIRM_UNREADABLE_OUT=$(PATH="$FIXTURE/bin-showfail-subject:$PATH" bash "$QG_REAL" design-conflict "$TID_U8" --unit U1 "8f confirm-reread-fails probe" 2>&1); CONFIRM_UNREADABLE_RC=$?
assert_eq "8f.1 confirmation re-read itself failing refuses distinctly (exit 5)" "5" "$CONFIRM_UNREADABLE_RC"
assert_eq "8f.2 ...error_key=design_conflict_confirm_unreadable (never write_unconfirmed — the read never happened, it isn't known to be absent)" \
    "design_conflict_confirm_unreadable" "$(json_field '.error_key' "$CONFIRM_UNREADABLE_OUT")"

# (f) EXECUTION — every leg above (8b.1, 8c.1, 8d.1, 8a.5, 8f.1) drove the
# real subprocess (mutant or shipped); nothing in this section is a
# source-level grep standing in for a run.

# ===========================================================================
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

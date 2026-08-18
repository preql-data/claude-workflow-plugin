#!/bin/bash
# grilling-record.test.sh — v5 Phase D3 (claude-workflow-plugin-fkm.5): the
# grilling-record subcommand and design-record's grilling precondition.
#
# WHAT THIS COVERS, and why each part needs a test of its own:
#
#   1. `qa-gate.sh grilling-record` — shape validation, inline, mirroring
#      grade-record's / design-review-record's own required-argument ladder:
#      missing task id, each of --rounds/--questions/--approaches/
#      --unresolved missing or non-integer, and the vendored method's own
#      bar (`approaches >= 2`, else insufficient_approaches). Written by the
#      ORCHESTRATOR, AT ROOT — nothing here checks that identity (the record
#      carries no `who=` field to check it against); the structural
#      guarantee is designer.md's tool list omitting Bash entirely — a claim
#      this file does NOT assert (QA R1-F3: an earlier draft of this header
#      said "asserted directly" here, which sent a reader hunting in the
#      wrong file). The actual assertion lives in
#      design-artifact.test.sh sections 5.1/5.2 (the frontmatter/tools-list
#      checker and its negative control against a fixture whose tools line
#      still carries Bash).
#
#   2. The record grammar and `vendor_hash` — a LIVE workflow-manifest.sh
#      hash-file recompute over the vendored brainstorming SKILL.md, taken
#      at record time, never a caller-supplied value. Asserted against the
#      SAME instrument actually running (not a re-derivation of sha256 by a
#      second tool), so this file's own execution leg is the shipped script.
#
#   3. The GRILLING-PRECONDITION inside `cmd_design_record` (D3's third
#      deliverable): refuses `grilling_record_missing` with no `GRILLING v1`
#      record on the task itself OR on its parent epic; succeeds once one
#      exists on either; `--no-grilling '<reason>'` is the audited bypass,
#      recording `[grilling bypass: <reason>]`.
#
#   4. A METatest proving the precondition block is load-bearing: strip
#      `# GRILLING-PRECONDITION BEGIN/END` from a copy of qa-gate.sh and show
#      the SAME task state that the shipped script refuses instead records
#      cleanly on the mutant — mirroring the pairing plan's own P1 shape for
#      the sibling DESIGN-SATISFIED-REFUSAL METatest in design-review-record
#      .test.sh.
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
# Fixture. Same shape as design-review-record.test.sh: the real scripts, a
# real bd, a throwaway project root and HOME. `cd "$FIXTURE"` (no subshell)
# is the FAIL-CLOSED store-isolation mechanism this tier requires — BEADS_DIR
# alone is fail-open (falls back to the production store when the target is
# not already an initialised one), so every bd call below runs with this
# process's cwd inside the fixture, never via an env-var redirect alone.
# ALSO copies .claude/vendor/ (unlike its siblings before D3): this file's
# subject hashes the vendored brainstorming SKILL.md, so without it every
# grilling-record call would refuse vendor_hash_unavailable.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t grilling-record.XXXXXX)
TEST_HOME=$(mktemp -d -t grilling-record-home.XXXXXX)

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
    echo "bd CLI not on PATH — grilling-record tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — grilling-record tests require jq."
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
WM="$FIXTURE/.claude/scripts/workflow-manifest.sh"
VENDORED_SKILL="$FIXTURE/.claude/vendor/superpowers/brainstorming/SKILL.md"

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }

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

# count_grilling <tid> — counts comments matching the FULL tightened
# grammar `_grilling_comment_on` requires (QA R1-F1), not a bare
# `^GRILLING v1 ` prefix — the two diverged the first time this file used
# count_grilling to check a FORGED, prefix-only comment (5.1b), where a
# bare-prefix count silently reported 1 for text the shipped precondition
# reader does not treat as a record at all. Every REAL grilling-record call
# always produces the full grammar, so this tightening changes nothing for
# this file's other four call sites (2.1b, D3b, 6.2c, 6.5c) — verified by
# re-running the full suite after the change.
count_grilling() {
    comments_of "$1" | grep -cE '^GRILLING v1 rounds=[0-9]+ questions=[0-9]+ approaches=[0-9]+ unresolved=[0-9]+ vendor_hash=[0-9a-f]{64} at ' 2>/dev/null | tr -d ' \n'
}

latest_grilling_line() {
    comments_of "$1" | grep -E '^GRILLING v1 ' | tail -1
}

# write_artifact <path> <task-id> — a minimal, schema-valid design artifact,
# byte-identical in shape to the sibling design-record specs so this file
# never guesses a second schema.
write_artifact() {
    local path="$1" tid="$2"
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
    {
      "unit_id": "U1",
      "role": "devops",
      "goal": "test unit",
      "acceptance": [ { "id": "AC1", "text": "test fixture: nothing asserted" } ],
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

LIVE_VENDOR_HASH=$(bash "$WM" hash-file "$VENDORED_SKILL" 2>/dev/null)

# ===========================================================================
printf '\n=== Section 1: grilling-record — argument validation ladder ===\n'
# ===========================================================================

TID1=$(bd create "D3 grilling shape subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
if [ -z "$TID1" ] || [ "$TID1" = "null" ]; then
    echo "harness error: could not create a Beads task"
    exit 2
fi

# 2>/dev/null (not 2>&1): a missing task id ALSO triggers usage()'s
# multi-line help text on stderr, ahead of the one-line JSON error on
# stdout — merging the two makes the combined blob unparseable as JSON.
OUT=$(bash "$QG" grilling-record 2>/dev/null); RC=$?
assert_eq "1.1 no task id: exit 1" "1" "$RC"
assert_eq "1.1b ...error_key=missing_task_id" "missing_task_id" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" grilling-record "$TID1" --questions 3 --approaches 2 --unresolved 0 "s" 2>&1)
assert_eq "1.2 missing --rounds: missing_rounds" "missing_rounds" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" grilling-record "$TID1" --rounds 2 --approaches 2 --unresolved 0 "s" 2>&1)
assert_eq "1.3 missing --questions: missing_questions" "missing_questions" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" grilling-record "$TID1" --rounds 2 --questions 3 --unresolved 0 "s" 2>&1)
assert_eq "1.4 missing --approaches: missing_approaches" "missing_approaches" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" grilling-record "$TID1" --rounds 2 --questions 3 --approaches 2 "s" 2>&1)
assert_eq "1.5 missing --unresolved: missing_unresolved" "missing_unresolved" "$(json_field '.error_key' "$OUT")"

# Each counter individually must be a non-negative integer — table-driven so
# every field's OWN reader-facing error_key is asserted, not just the first.
OUT=$(bash "$QG" grilling-record "$TID1" --rounds -1 --questions 3 --approaches 2 --unresolved 0 "s" 2>&1)
assert_eq "1.6 --rounds=-1: rounds_not_integer" "rounds_not_integer" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" grilling-record "$TID1" --rounds 2 --questions abc --approaches 2 --unresolved 0 "s" 2>&1)
assert_eq "1.7 --questions=abc: questions_not_integer" "questions_not_integer" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" grilling-record "$TID1" --rounds 2 --questions 3 --approaches 1.5 --unresolved 0 "s" 2>&1)
assert_eq "1.8 --approaches=1.5: approaches_not_integer" "approaches_not_integer" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" grilling-record "$TID1" --rounds 2 --questions 3 --approaches 2 --unresolved -3 "s" 2>&1)
assert_eq "1.9 --unresolved=-3: unresolved_not_integer" "unresolved_not_integer" "$(json_field '.error_key' "$OUT")"

# THE VENDORED METHOD'S OWN BAR — 0 and 1 approaches are both below it;
# both must refuse the SAME way, and 2 must not.
OUT=$(bash "$QG" grilling-record "$TID1" --rounds 2 --questions 3 --approaches 0 --unresolved 0 "s" 2>&1)
assert_eq "1.10 --approaches=0: insufficient_approaches" "insufficient_approaches" "$(json_field '.error_key' "$OUT")"
assert_contains "1.10b ...names the vendored method's own bar" \
    "Propose 2-3 different approaches" "$OUT"

OUT=$(bash "$QG" grilling-record "$TID1" --rounds 2 --questions 3 --approaches 1 --unresolved 0 "s" 2>&1)
assert_eq "1.11 --approaches=1: ALSO insufficient_approaches" "insufficient_approaches" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" grilling-record "$TID1" --rounds 2 --questions 3 --approaches 2 --unresolved 0 "s" 2>&1)
assert_eq "1.12 --approaches=2 (the exact bar): NOT insufficient_approaches" "recorded" "$(json_field '.status' "$OUT")"

# Unknown flag: same "free-text summary accumulator" shape design-record's
# own parser has — an unrecognised flag becomes part of the summary rather
# than a hard error, so this asserts the ACTUAL shipped behaviour rather
# than a stricter one nobody built.
TID1B=$(bd create "D3 grilling unknown-flag subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" grilling-record "$TID1B" --rounds 2 --questions 3 --approaches 2 --unresolved 0 --bogus 2>&1)
assert_eq "1.13 an unrecognised flag is folded into the free-text summary, not refused" \
    "recorded" "$(json_field '.status' "$OUT")"
assert_contains "1.13b ...and the literal text appears in the record" \
    "--bogus" "$(latest_grilling_line "$TID1B")"

# ===========================================================================
printf '\n=== Section 2: the GRILLING v1 record grammar and vendor_hash ===\n'
# ===========================================================================

TID2=$(bd create "D3 grilling record grammar subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" grilling-record "$TID2" --rounds 4 --questions 9 --approaches 3 --unresolved 2 \
    "explored a shared-helper design and a per-call-site one" 2>&1)
assert_eq "2.1 a fully-valid call records" "recorded" "$(json_field '.status' "$OUT")"

REC=$(latest_grilling_line "$TID2")
assert_eq "2.1b exactly one GRILLING v1 record exists" "1" "$(count_grilling "$TID2")"
assert_contains "2.2 the record carries rounds=4" "rounds=4 " "$REC"
assert_contains "2.3 ...questions=9" "questions=9 " "$REC"
assert_contains "2.4 ...approaches=3" "approaches=3 " "$REC"
assert_contains "2.5 ...unresolved=2" "unresolved=2 " "$REC"
assert_contains "2.6 ...the free-text summary" \
    "explored a shared-helper design and a per-call-site one" "$REC"

# THE EXECUTION LEG: vendor_hash is asserted against the SHIPPED instrument
# actually RUNNING (workflow-manifest.sh hash-file), never a re-derivation
# of sha256 by a second tool.
[ -n "$LIVE_VENDOR_HASH" ] && [ "${#LIVE_VENDOR_HASH}" -eq 64 ] || {
    echo "harness error: could not hash the fixture's vendored SKILL.md"
    exit 2
}
assert_contains "2.7 the record's vendor_hash equals workflow-manifest.sh hash-file's live recompute" \
    "vendor_hash=$LIVE_VENDOR_HASH " "$REC"

# A default (no summary text) still records, with the documented fallback.
TID2B=$(bd create "D3 grilling no-summary subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" grilling-record "$TID2B" --rounds 1 --questions 1 --approaches 2 --unresolved 0 2>&1)
assert_eq "2.8 no trailing summary text still records" "recorded" "$(json_field '.status' "$OUT")"
assert_contains "2.8b ...with the documented fallback text" \
    "grilling recorded" "$(latest_grilling_line "$TID2B")"

# rounds=0/questions=0/unresolved=0 are all LEGAL non-negative integers —
# only approaches has a floor above zero.
TID2C=$(bd create "D3 grilling zero-counters subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OUT=$(bash "$QG" grilling-record "$TID2C" --rounds 0 --questions 0 --approaches 2 --unresolved 0 "s" 2>&1)
assert_eq "2.9 rounds=0/questions=0/unresolved=0 are legal (only approaches has a floor)" \
    "recorded" "$(json_field '.status' "$OUT")"

# ===========================================================================
printf '\n=== Section 3: the GRILLING-PRECONDITION inside design-record ===\n'
# ===========================================================================

# D1: a fresh task with NO grilling record at all -> refused.
TID3=$(bd create "D3 precondition subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART3="$FIXTURE/docs/specs/$TID3.md"
write_artifact "$ART3" "$TID3"
printf '%s\n' "$ART3" > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
bash "$QG" enter "$TID3" >/dev/null 2>&1

OUT=$(bash "$QG" design-record "$TID3" 2>&1); RC=$?
assert_eq "D1 no grilling record at all: design-record exit 1" "1" "$RC"
assert_eq "D1b ...error_key=grilling_record_missing" "grilling_record_missing" "$(json_field '.error_key' "$OUT")"
assert_contains "D1c ...names the remediation" "qa-gate.sh grilling-record $TID3" "$OUT"
assert_contains "D1d ...and the bypass" "--no-grilling" "$OUT"
DR_COUNT=$(comments_of "$TID3" | grep -cE '^DESIGN-ARTIFACT v1 ' 2>/dev/null | tr -d ' \n')
assert_eq "D1e the refusal wrote NOTHING — no DESIGN-ARTIFACT record exists" "0" "$DR_COUNT"

# D2: grill the SAME task directly -> design-record now succeeds.
bash "$QG" grilling-record "$TID3" --rounds 2 --questions 4 --approaches 2 --unresolved 1 \
    "grilled directly on the task" >/dev/null 2>&1
OUT=$(bash "$QG" design-record "$TID3" 2>&1)
assert_eq "D2 grilling recorded ON THE TASK: design-record succeeds" "recorded" "$(json_field '.status' "$OUT")"

# D3: parent-epic path. A CHILD task with NO grilling of its own, whose
# PARENT EPIC has been grilled, still succeeds. --no-inherit-labels is not
# load-bearing for this assertion (nothing here checks labels) but is kept
# for the same reason CLAUDE.md documents it everywhere else: a bare
# --parent copies the epic's labels onto the child, which is never what a
# fresh test task wants.
EPIC=$(bd create "D3 grilling epic" -t epic -p 1 --json 2>/dev/null | jq -r '.id')
CHILD=$(bd create "D3 grilling child (ungrilled itself)" -t task -p 1 --parent "$EPIC" --no-inherit-labels --json 2>/dev/null | jq -r '.id')
if [ -z "$EPIC" ] || [ "$EPIC" = "null" ] || [ -z "$CHILD" ] || [ "$CHILD" = "null" ]; then
    echo "harness error: could not create the epic/child pair"
    exit 2
fi
ART_CHILD="$FIXTURE/docs/specs/$CHILD.md"
write_artifact "$ART_CHILD" "$CHILD"
printf '%s\n' "$ART_CHILD" > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
bash "$QG" enter "$CHILD" >/dev/null 2>&1

OUT=$(bash "$QG" design-record "$CHILD" 2>&1)
assert_eq "D3 pre-check: child refuses too — grilling is on neither task nor epic yet" \
    "grilling_record_missing" "$(json_field '.error_key' "$OUT")"

bash "$QG" grilling-record "$EPIC" --rounds 3 --questions 6 --approaches 2 --unresolved 0 \
    "grilled at the epic level" >/dev/null 2>&1
CHILD_OWN_COUNT=$(count_grilling "$CHILD")
assert_eq "D3b the CHILD ITSELF still carries zero GRILLING records (the epic's is not copied down)" \
    "0" "$CHILD_OWN_COUNT"

OUT=$(bash "$QG" design-record "$CHILD" 2>&1)
assert_eq "D3c grilling recorded on the PARENT EPIC ONLY: the child's design-record still succeeds" \
    "recorded" "$(json_field '.status' "$OUT")"

# D4: --no-grilling bypass, on a fresh ungrilled task.
TID4=$(bd create "D3 no-grilling bypass subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART4="$FIXTURE/docs/specs/$TID4.md"
write_artifact "$ART4" "$TID4"
printf '%s\n' "$ART4" > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
bash "$QG" enter "$TID4" >/dev/null 2>&1

OUT=$(bash "$QG" design-record "$TID4" --no-grilling 2>&1)
assert_eq "D4 --no-grilling with NO reason: missing_grilling_bypass_reason" \
    "missing_grilling_bypass_reason" "$(json_field '.error_key' "$OUT")"

OUT=$(bash "$QG" design-record "$TID4" --no-grilling "F1 doc-only class: no dialogue was needed" 2>&1)
assert_eq "D4b --no-grilling WITH a reason: succeeds despite no GRILLING v1 record anywhere" \
    "recorded" "$(json_field '.status' "$OUT")"
D4_RECORD=$(comments_of "$TID4" | grep -E '^DESIGN-ARTIFACT v1 ' | tail -1)
assert_contains "D4c the record carries the audited [grilling bypass: <reason>] marker" \
    "[grilling bypass: F1 doc-only class: no dialogue was needed]" "$D4_RECORD"

# ===========================================================================
printf '\n=== Section 4: META — the GRILLING-PRECONDITION block is load-bearing ===\n'
# ===========================================================================

# Strip the sentinel-delimited block from a COPY of qa-gate.sh and replay
# D1's exact scenario (a design artifact, `enter`, then design-record, with
# NO grilling record anywhere). Under the stripped copy the record SUCCEEDS
# — i.e. D1's "refused" assertion would fail — so D1 is testing the block
# itself, not an incidental side effect. Mirrors design-review-record.test
# .sh's own P1-shaped METatest for DESIGN-SATISFIED-REFUSAL.
QG_NOGUARD="$FIXTURE/.claude/scripts/qa-gate-noguard.sh"
STRIP_RC=0
awk '
    /# GRILLING-PRECONDITION BEGIN/ { skipping=1; found=1; next }
    /# GRILLING-PRECONDITION END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_NOGUARD" || STRIP_RC=$?
chmod +x "$QG_NOGUARD"
assert_eq "META-1a: GRILLING-PRECONDITION sentinels are present in the shipped qa-gate.sh (the strip found them)" \
    "0" "$STRIP_RC"

PARSE_RC=0
bash -n "$QG_NOGUARD" 2>/dev/null || PARSE_RC=$?
assert_eq "META-1b: the stripped copy still parses (the block is cleanly strippable)" "0" "$PARSE_RC"

BYTE_DIFF=$(cmp -s "$QG" "$QG_NOGUARD" && echo same || echo differ)
assert_eq "META-1c: the mutant's bytes actually differ from the shipped script" "differ" "$BYTE_DIFF"

TID_META=$(bd create "D3 GRILLING-PRECONDITION META subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART_META="$FIXTURE/docs/specs/$TID_META.md"
write_artifact "$ART_META" "$TID_META"
printf '%s\n' "$ART_META" > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
bash "$QG" enter "$TID_META" >/dev/null 2>&1

MUT_OUT=$(bash "$QG_NOGUARD" design-record "$TID_META" 2>&1)
assert_eq "META-1d MISBEHAVIOUR: WITHOUT the block, design-record records a task NOBODY grilled" \
    "recorded" "$(json_field '.status' "$MUT_OUT")"
MUT_DR_COUNT=$(comments_of "$TID_META" | grep -cE '^DESIGN-ARTIFACT v1 ' 2>/dev/null | tr -d ' \n')
assert_eq "META-1e ...and the DESIGN-ARTIFACT record it wrote is real, not a dry run" "1" "$MUT_DR_COUNT"

# CONTROL: the SAME task state, the SHIPPED (guarded) script, refuses. Uses
# a fresh design-record call on the SAME task — design-record's own
# duplicate-artifact machinery is orthogonal to this assertion, so re-derive
# a clean second subject instead of fighting it.
TID_CTRL=$(bd create "D3 GRILLING-PRECONDITION control subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART_CTRL="$FIXTURE/docs/specs/$TID_CTRL.md"
write_artifact "$ART_CTRL" "$TID_CTRL"
printf '%s\n' "$ART_CTRL" > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
bash "$QG" enter "$TID_CTRL" >/dev/null 2>&1

CTRL_OUT=$(bash "$QG" design-record "$TID_CTRL" 2>&1)
assert_eq "META-1f CONTROL: the SHIPPED script refuses the SAME ungrilled state the mutant just recorded" \
    "grilling_record_missing" "$(json_field '.error_key' "$CTRL_OUT")"
rm -f "$QG_NOGUARD"

# ===========================================================================
printf '\n=== Section 5: QA R1-F1 — the reader matches the FULL writer grammar, not a bare prefix ===\n'
# ===========================================================================
#
# QA finding (claude-workflow-plugin-fkm.5, reviewed_hash 1a0c9f53): the
# first shipped version of _grilling_comment_on was `startswith("GRILLING
# v1 ")` alone, MEASURED (in an isolated fixture) to accept a hand-posted
# comment carrying none of the real fields. This section pins the fix and
# proves the tightened reader is what closes it, not an incidental side
# effect.

TID5=$(bd create "R1-F1 forged-comment subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART5="$FIXTURE/docs/specs/$TID5.md"
write_artifact "$ART5" "$TID5"
printf '%s\n' "$ART5" > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
bash "$QG" enter "$TID5" >/dev/null 2>&1

FORGED_TEXT="GRILLING v1 totally informal, no counters, no vendor_hash"
bd comments add "$TID5" "$FORGED_TEXT" >/dev/null 2>&1 \
    || bd comment add "$TID5" "$FORGED_TEXT" >/dev/null 2>&1
FORGED_LANDED=$(comments_of "$TID5" | grep -cF "$FORGED_TEXT" 2>/dev/null | tr -d ' \n')
assert_eq "5.1 precondition: the forged comment actually landed on the task" "1" "$FORGED_LANDED"
assert_eq "5.1b precondition: it does NOT match the tightened grammar (no real counters/vendor_hash)" \
    "0" "$(count_grilling "$TID5")"

OUT=$(bash "$QG" design-record "$TID5" 2>&1)
assert_eq "5.2 the SHIPPED (tightened) script REFUSES design-record over the forged comment" \
    "grilling_record_missing" "$(json_field '.error_key' "$OUT")"

# --- META: reverting the reader to the pre-fix bare-prefix shape must
# accept the SAME forged comment, proving the tightened grammar (not
# something else) is what closes R1-F1.
QG_WEAKREADER="$FIXTURE/.claude/scripts/qa-gate-weakreader.sh"
WEAK_RC=0
awk '
    /# GRILLING-READER-GRAMMAR BEGIN/ {
        print
        print "        | any(.[]; .text | startswith(\"GRILLING v1 \"))"
        skipping=1; found=1; next
    }
    /# GRILLING-READER-GRAMMAR END/ { print; skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_WEAKREADER" || WEAK_RC=$?
chmod +x "$QG_WEAKREADER"
assert_eq "META-2a: the GRILLING-READER-GRAMMAR sentinels are present (the substitution found them)" \
    "0" "$WEAK_RC"

PARSE_RC2=0
bash -n "$QG_WEAKREADER" 2>/dev/null || PARSE_RC2=$?
assert_eq "META-2b: the weak-reader copy still parses" "0" "$PARSE_RC2"

BYTE_DIFF2=$(cmp -s "$QG" "$QG_WEAKREADER" && echo same || echo differ)
assert_eq "META-2c: the weak-reader copy's bytes actually differ from the shipped script" "differ" "$BYTE_DIFF2"

WEAK_OUT=$(bash "$QG_WEAKREADER" design-record "$TID5" 2>&1)
assert_eq "META-2d MISBEHAVIOUR: WITHOUT the tightened grammar, the SAME forged comment satisfies the precondition" \
    "recorded" "$(json_field '.status' "$WEAK_OUT")"
WEAK_DR_COUNT=$(comments_of "$TID5" | grep -cE '^DESIGN-ARTIFACT v1 ' 2>/dev/null | tr -d ' \n')
assert_eq "META-2e ...and it is a REAL record, not a dry run" "1" "$WEAK_DR_COUNT"
rm -f "$QG_WEAKREADER"

# CONTROL, on a fresh subject (TID5 is now recorded by the mutant above, so a
# second design-record on it would hit duplicate-artifact machinery instead
# of re-testing this precondition): the SHIPPED script still refuses a
# SEPARATE task carrying the identical forged comment.
TID6=$(bd create "R1-F1 forged-comment control" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART6="$FIXTURE/docs/specs/$TID6.md"
write_artifact "$ART6" "$TID6"
printf '%s\n' "$ART6" > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
bash "$QG" enter "$TID6" >/dev/null 2>&1
bd comments add "$TID6" "$FORGED_TEXT" >/dev/null 2>&1 \
    || bd comment add "$TID6" "$FORGED_TEXT" >/dev/null 2>&1
CTRL2_OUT=$(bash "$QG" design-record "$TID6" 2>&1)
assert_eq "META-2f CONTROL: the SHIPPED script refuses the SAME forged comment the mutant just recorded" \
    "grilling_record_missing" "$(json_field '.error_key' "$CTRL2_OUT")"

# A real grilling-record call must still satisfy the tightened grammar (no
# regression on the legitimate path — already exercised in Section 3's D2,
# repeated here beside the forgery case for locality).
TID7=$(bd create "R1-F1 real grilling still passes" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ART7="$FIXTURE/docs/specs/$TID7.md"
write_artifact "$ART7" "$TID7"
printf '%s\n' "$ART7" > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
bash "$QG" enter "$TID7" >/dev/null 2>&1
bash "$QG" grilling-record "$TID7" --rounds 2 --questions 4 --approaches 2 --unresolved 0 \
    "a genuine dialogue" >/dev/null 2>&1
OUT7=$(bash "$QG" design-record "$TID7" 2>&1)
assert_eq "5.3 a REAL grilling-record call still satisfies the tightened grammar" \
    "recorded" "$(json_field '.status' "$OUT7")"

# ===========================================================================
printf '\n=== Section 6: QA R1-F5 — failure-injection for the hash-availability refusals ===\n'
# ===========================================================================
#
# QA finding: vendor_hash_unavailable / hash_tool_unavailable fired during
# development (per the implementer's own notes) but carried no pinned
# assertion. Both legs move the ACTUAL file the fixture depends on, run the
# shipped subcommand, then restore it immediately so no later section is
# affected.

TID8=$(bd create "R1-F5 vendor-file-missing subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
VENDOR_MOVED="$VENDORED_SKILL.movedaway"
mv "$VENDORED_SKILL" "$VENDOR_MOVED"
assert_eq "6.1 precondition: the vendored SKILL.md is genuinely absent from this fixture right now" \
    "absent" "$([ -e "$VENDORED_SKILL" ] && echo present || echo absent)"

OUT8=$(bash "$QG" grilling-record "$TID8" --rounds 1 --questions 1 --approaches 2 --unresolved 0 "s" 2>&1)
RC8=$?
assert_eq "6.2 grilling-record REFUSES when the vendored SKILL.md is missing (exit 2, mechanical class)" "2" "$RC8"
assert_eq "6.2b ...error_key=vendor_hash_unavailable" "vendor_hash_unavailable" "$(json_field '.error_key' "$OUT8")"
NO_RECORD8=$(count_grilling "$TID8")
assert_eq "6.2c ...and nothing was recorded" "0" "$NO_RECORD8"
mv "$VENDOR_MOVED" "$VENDORED_SKILL"
assert_eq "6.3 CONTROL: restoring the file lets grilling-record succeed on the SAME task" \
    "recorded" "$(json_field '.status' "$(bash "$QG" grilling-record "$TID8" --rounds 1 --questions 1 --approaches 2 --unresolved 0 "s" 2>&1)")"

TID9=$(bd create "R1-F5 hash-tool-missing subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
WM_MOVED="$WM.movedaway"
mv "$WM" "$WM_MOVED"
assert_eq "6.4 precondition: workflow-manifest.sh is genuinely absent from this fixture right now" \
    "absent" "$([ -e "$WM" ] && echo present || echo absent)"

OUT9=$(bash "$QG" grilling-record "$TID9" --rounds 1 --questions 1 --approaches 2 --unresolved 0 "s" 2>&1)
RC9=$?
assert_eq "6.5 grilling-record REFUSES when workflow-manifest.sh is missing (exit 2, mechanical class)" "2" "$RC9"
assert_eq "6.5b ...error_key=hash_tool_unavailable" "hash_tool_unavailable" "$(json_field '.error_key' "$OUT9")"
NO_RECORD9=$(count_grilling "$TID9")
assert_eq "6.5c ...and nothing was recorded" "0" "$NO_RECORD9"
mv "$WM_MOVED" "$WM"
assert_eq "6.6 CONTROL: restoring workflow-manifest.sh lets grilling-record succeed on the SAME task" \
    "recorded" "$(json_field '.status' "$(bash "$QG" grilling-record "$TID9" --rounds 1 --questions 1 --approaches 2 --unresolved 0 "s" 2>&1)")"

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

#!/bin/bash
# design-artifact.test.sh — v5 Phase D1 (claude-workflow-plugin-fkm.3).
#
# WHAT THIS COVERS, and why each part needs a test of its own:
#
#   1. workflow-manifest.sh `hash-file` — the design binding's digest. The
#      release plan spelled this as `impact-report.sh --hash-file <path>` piping
#      the file through `sed -e 's/\r$//' -e 's/[[:space:]]*$//'` into
#      sha256_stdin. Section 1 DRIVES that spelling beside the shipped one and
#      measures the two defects that moved the host: a missing artifact digests
#      to e3b0c442… (the sha256 of zero bytes, which impact-report.test.sh pins
#      as the EMPTY CHANGE SET) at rc=0, and the normalisation collapses a
#      Markdown hard line break so a real content edit is invisible to the hash.
#      Both make the binding unfailable, which is the failure mode a "strip the
#      hash and the binding must break" meta-test cannot see, because it passes
#      vacuously against them.
#
#   2. review-check.sh `validate-design` — the DESIGN-UNITS extraction. The plan
#      said to model it on epic-gate.sh's files_changed_of; section 2 drives that
#      idiom over the very artifact this one accepts and shows it returns [].
#
#   3. qa-gate.sh `design-record` — LAYER 2 OF THE DESIGNER EDIT BAN, running.
#      This is the runnable half of the pairing: layer 1 is an ABSENCE in
#      designer.md's frontmatter, and an absence has no runtime observable
#      offline — nothing in this tree asserts any agent's tools line omits a
#      write tool, so there is no precedent to extend either. Section 3 fires the
#      consequence check on a real source path instead, with both controls (an
#      implementer has spawned; the change set is only the artifact).
#
#   4. The approval record's fourth machine token, `design_hash=<h>`, its
#      four-arm ladder, and the D1 META-TEST: strip the token from a recorded
#      approval and the binding must read UNBOUND.
#
#   5. Layer 1, with the negative control the frontmatter assertion needs: the
#      same checker must FLAG a fixture whose tools line still carries Bash.
#
# Exit codes: 0 all assertions passed | 1 one or more failed | 2 harness error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()
KEEP_FIXTURE="${KEEP_FIXTURE:-0}"

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
# Fixture. Same shape as qa-gate-grade-record.test.sh: the real scripts, a real
# bd, a throwaway project root and HOME.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t design-artifact.XXXXXX)
TEST_HOME=$(mktemp -d -t design-artifact-home.XXXXXX)

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

if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — design-artifact tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — design-artifact tests require jq."
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

# The sha256 of ZERO BYTES. Pinned as a literal here for the same reason
# impact-report.test.sh pins it: it is the value a broken hasher returns for a
# file that does not exist, it is 64 valid hex, and it is stable — so it passes
# every shape check a reader could apply. Every assertion that this constant is
# NOT produced is an assertion that the binding can actually fail.
EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# sha256_of_file <path> — the BY-HAND digest a reviewer would compute. Written
# as an if/elif rather than `cmd -v X && X || Y`: that idiom also runs Y when X
# is present and FAILS, which would silently substitute a different tool's
# output into an assertion about the first one's.
#
# FED ON STDIN, NOT BY NAME, AND THAT IS NOT COSMETIC. Both shasum and sha256sum
# implement the checksum-file escaping rule: a path containing a newline (or a
# backslash) is printed BACKSLASH-ESCAPED and the whole line is prefixed with a
# literal `\`, so `awk '{print $1}'` returns `\<hash>` — 65 characters. Section 9
# hashes files that are NAMED with a trailing newline, and the first run of it
# passed 9.3c vacuously for exactly that reason: the needle was `\<digest>`,
# which of course appeared in no record. The digest of the CONTENT is identical
# either way (measured: same 64 hex for an ordinary path both ways), so every
# other assertion in this file is unaffected — and `shasum -a 256 <path>` still
# reproduces a binding by hand, which is what the record's own observation says.
sha256_of_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'
    else
        sha256sum < "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# plan_hash <path> — the release plan's spelling, kept intact so sections 1.6
# and 1.7 measure it rather than describe it.
plan_hash() {
    if command -v shasum >/dev/null 2>&1; then
        sed -e 's/\r$//' -e 's/[[:space:]]*$//' "$1" 2>/dev/null | shasum -a 256 | awk '{print $1}'
    else
        sed -e 's/\r$//' -e 's/[[:space:]]*$//' "$1" 2>/dev/null | sha256sum | awk '{print $1}'
    fi
}

# write_artifact <path> <task-id> — a VALID design artifact: eight prose
# sections, one sentinel pair, PRETTY-PRINTED fenced JSON with NESTED objects.
# Pretty-printed and nested on purpose — that is the shape an LLM writes and the
# shape the idiom section 2.2 drives cannot read.
write_artifact() {
    local path="$1" tid="$2"
    cat > "$path" <<ARTIFACT
# Design — $tid

## Problem
The gate cannot tell a design document from documentation about one.

## Approaches considered
1. Infer from the path — rejected: that is the shape inference bbh removed.
2. Declare the directory — chosen.

## Chosen approach
Declare it.

## Units
See the machine block.

## Global constraints
No new harnesses.

## Out of scope
The Linear adapter.

## Verification plan
\`make test\`

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
      "goal": "declare the directory",
      "acceptance": [
        { "id": "AC1", "text": "governing lists docs/specs/<id>.md with origin design-artifact" }
      ],
      "files": [ ".claude/scripts/workflow-manifest.sh" ],
      "verification": "make test",
      "depends_on": []
    },
    {
      "unit_id": "U2",
      "role": "devops",
      "goal": "flip the tripwires",
      "acceptance": [
        { "id": "AC2", "text": "both shipped tripwire legs assert the new verdict" }
      ],
      "files": [ ".claude/scripts/tests/workflow-manifest.test.sh" ],
      "verification": "make test",
      "depends_on": [ "U1" ]
    }
  ]
}
\`\`\`
<!-- DESIGN-UNITS END -->
ARTIFACT
}

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }

# ===========================================================================
printf '\n=== Section 1: workflow-manifest.sh hash-file — the binding digest ===\n'
# ===========================================================================

H_REAL="$FIXTURE/docs/specs/hashme.md"
printf 'a design\n' > "$H_REAL"

H_OUT=$(bash "$WM" hash-file "$H_REAL" 2>/dev/null); H_RC=$?
assert_eq "1.1 hash-file exits 0 on a real file" "0" "$H_RC"
BY_HAND=$(sha256_of_file "$H_REAL")
assert_eq "1.1a precondition: a by-hand digest is computable on this host" "64" "${#BY_HAND}"
assert_eq "1.1b ...and the digest is RAW BYTES — a reviewer reproduces it with shasum -a 256" \
    "$BY_HAND" "$H_OUT"

# THE REFUSALS. Each is measured for THREE properties, and the third one is the
# one that keeps the leg from being vacuous.
#
#   (a) a non-zero exit;
#   (b) no digest emitted — least of all the empty-bytes constant;
#   (c) THE DIAGNOSTIC NAMES THE CONDITION, and refuses BEFORE hashing.
#
# (c) is not decoration. Without the explicit guards, hash_file() would still
# exit 1 on a missing or unreadable path — the digest comes back empty and fails
# its 64-char check — so (a) and (b) alone would pass against a build with no
# guards at all, and the assertion would be measuring the wrong mechanism.
# Asserting the named diagnostic is what makes removing a guard RED. Only the
# EMPTY case changes behaviour without them: zero bytes hash to 64 valid hex.
H_MISS=$(bash "$WM" hash-file "$FIXTURE/docs/specs/absent.md" 2>&1); H_MISS_RC=$?
assert_eq "1.2 hash-file REFUSES a missing path (non-zero exit)" "1" "$H_MISS_RC"
assert_not_contains "1.2b ...and emits no digest at all, least of all the empty-bytes constant" \
    "$EMPTY_SHA" "$H_MISS"
assert_contains "1.2c ...and the refusal fires BEFORE hashing, naming the condition" \
    "hash-file: no such file" "$H_MISS"

: > "$FIXTURE/docs/specs/empty.md"
H_EMPTY=$(bash "$WM" hash-file "$FIXTURE/docs/specs/empty.md" 2>&1); H_EMPTY_RC=$?
assert_eq "1.3 hash-file REFUSES a zero-byte file (non-zero exit)" "1" "$H_EMPTY_RC"
assert_not_contains "1.3b ...and does NOT return the empty-bytes constant it would otherwise hash to" \
    "$EMPTY_SHA" "$H_EMPTY"
assert_contains "1.3c ...naming emptiness as the reason" "hash-file: file is empty" "$H_EMPTY"

# Unreadable. Skipped as root, where chmod 000 does not deny — a leg that cannot
# fail is worse than an absent one, so the precondition is asserted rather than
# assumed.
UNREADABLE="$FIXTURE/docs/specs/unreadable.md"
printf 'secret design\n' > "$UNREADABLE"
chmod 000 "$UNREADABLE" 2>/dev/null || true
if [ -r "$UNREADABLE" ]; then
    printf '  SKIP: 1.4 unreadable-path refusal (this user can read a chmod-000 file; likely root)\n'
else
    H_UNRD=$(bash "$WM" hash-file "$UNREADABLE" 2>&1); H_UNRD_RC=$?
    assert_eq "1.4 hash-file REFUSES an unreadable path (non-zero exit)" "1" "$H_UNRD_RC"
    assert_not_contains "1.4b ...and emits no empty-bytes constant" "$EMPTY_SHA" "$H_UNRD"
    assert_contains "1.4c ...naming unreadability rather than a short digest" \
        "hash-file: not readable" "$H_UNRD"
fi
chmod 644 "$UNREADABLE" 2>/dev/null || true

assert_eq "1.5 hash-file with no operand is a usage error (exit 2)" "2" \
    "$(bash "$WM" hash-file >/dev/null 2>&1; echo $?)"
assert_eq "1.5b hash-file with two operands is a usage error (exit 2)" "2" \
    "$(bash "$WM" hash-file a b >/dev/null 2>&1; echo $?)"

# --- THE NEGATIVE CONTROL FOR THE WHOLE SECTION ---------------------------
# The release plan's spelling, driven here rather than reasoned about. If these
# two legs ever stop reproducing, the refusals above have become decoration and
# the reason for them is gone.
PLAN_HASH_MISSING=$(plan_hash "$FIXTURE/docs/specs/absent.md"); PLAN_RC=$?
assert_eq "1.6 CONTROL: the plan's sed|sha spelling exits 0 on a MISSING artifact" "0" "$PLAN_RC"
assert_eq "1.6b CONTROL: ...and returns the empty-change-set constant as a valid-looking binding" \
    "$EMPTY_SHA" "$PLAN_HASH_MISSING"

# Markdown hard line break: two trailing spaces. A real content edit.
printf 'line one  \nline two\n' > "$FIXTURE/docs/specs/hb.md"
printf 'line one\nline two\n'   > "$FIXTURE/docs/specs/nb.md"
assert_eq "1.7 CONTROL: the plan's normalisation makes a Markdown hard line break INVISIBLE" \
    "$(plan_hash "$FIXTURE/docs/specs/nb.md")" "$(plan_hash "$FIXTURE/docs/specs/hb.md")"
HB=$(bash "$WM" hash-file "$FIXTURE/docs/specs/hb.md" 2>/dev/null)
NB=$(bash "$WM" hash-file "$FIXTURE/docs/specs/nb.md" 2>/dev/null)
assert_eq "1.7b ...while the shipped raw-bytes digest DOES see it" \
    "differ" "$([ "$HB" != "$NB" ] && echo differ || echo same)"

rm -f "$FIXTURE/docs/specs/hashme.md" "$FIXTURE/docs/specs/empty.md" \
      "$FIXTURE/docs/specs/unreadable.md" "$FIXTURE/docs/specs/hb.md" \
      "$FIXTURE/docs/specs/nb.md"

# ===========================================================================
printf '\n=== Section 2: review-check.sh validate-design — the DESIGN-UNITS block ===\n'
# ===========================================================================

VALID="$FIXTURE/docs/specs/valid-design.md"
write_artifact "$VALID" "seed-task"

V_OUT=$(bash "$RC" validate-design "$VALID" 2>/dev/null); V_RC=$?
assert_eq "2.1 a pretty-printed, fenced, nested-object artifact VALIDATES" "0" "$V_RC"
assert_eq "2.1b ...ok=true" "true" "$(json_field '.ok' "$V_OUT")"
assert_eq "2.1c ...and reports the unit COUNT the record will carry" "2" "$(json_field '.units' "$V_OUT")"
assert_eq "2.1d ...and the unit ids" "U1,U2" "$(json_field '.unit_ids | join(",")' "$V_OUT")"
# The envelope carries the artifact's own task_id so the RECORD WRITER never has
# to re-parse the block. Everything the writer needs comes from here.
assert_eq "2.1e ...and the artifact's own task_id, so no second parser is needed" \
    "seed-task" "$(json_field '.task_id' "$V_OUT")"

# THE NEGATIVE CONTROL FOR THE EXTRACTION DISCIPLINE. epic-gate.sh's
# files_changed_of is what the plan pointed at; its selector is `jq -R capture`
# over `\\{[^{}]*"units"[^{}]*\\}`. Driven over the SAME block this validator
# just read as two units.
IDIOM=$(awk '/DESIGN-UNITS BEGIN/,/DESIGN-UNITS END/' "$VALID" \
    | jq -Rr 'try (capture("(?<j>\\{[^{}]*\"units\"[^{}]*\\})"; "g") | .j | fromjson | .units[]?) catch empty' 2>/dev/null \
    | jq -R . 2>/dev/null | jq -sc . 2>/dev/null || echo '[]')
assert_eq "2.2 CONTROL: the files_changed_of idiom reads the SAME block as ZERO units" "[]" "$IDIOM"
assert_eq "2.2b ...so 'model it on files_changed_of' would have made every unit check vacuous" \
    "0" "$(printf '%s' "$IDIOM" | jq -r 'length' 2>/dev/null || echo 0)"

# Bare JSON (no fence) is equally legal.
BARE="$FIXTURE/docs/specs/bare.md"
grep -v '^```' "$VALID" > "$BARE"
assert_eq "2.3 an UNFENCED block validates too" "true" \
    "$(json_field '.ok' "$(bash "$RC" validate-design "$BARE" 2>/dev/null)")"

# A prose mention of the sentinel must not be read as a block boundary.
PROSE="$FIXTURE/docs/specs/prose.md"
# shellcheck disable=SC2016  # the backticks are LITERAL markdown in the planted
# prose — expanding them is exactly what must not happen.
sed 's|^## Problem$|## Problem\nEvery artifact carries a `<!-- DESIGN-UNITS BEGIN -->` sentinel, as quoted here.|' \
    "$VALID" > "$PROSE"
assert_eq "2.4 a sentinel QUOTED mid-sentence is not a block boundary (still valid, still 2 units)" \
    "2" "$(json_field '.units' "$(bash "$RC" validate-design "$PROSE" 2>/dev/null)")"

# Every refusal, each with its own key. Table-driven: <name>|<mutation-sed>|<expected key>
mutate() { sed "$1" "$VALID" > "$2"; }
M="$FIXTURE/docs/specs/mutant.md"

check_refusal() {
    local name="$1" expected_key="$2" file="$3"
    local out rc
    out=$(bash "$RC" validate-design "$file" 2>/dev/null); rc=$?
    assert_eq "2.5 $name -> exit 4" "4" "$rc"
    assert_eq "2.5 $name -> error_key=$expected_key" "$expected_key" "$(json_field '.error_key' "$out")"
    assert_eq "2.5 $name -> units reported as 0, never a count" "0" "$(json_field '.units' "$out")"
}

grep -v '^## Revision log$' "$VALID" > "$M";                       check_refusal "missing prose section"        "design_section_missing"          "$M"
{ cat "$VALID"; printf '\n<!-- DESIGN-UNITS BEGIN -->\n{}\n<!-- DESIGN-UNITS END -->\n'; } > "$M"
                                                                    check_refusal "a SECOND block appended"     "design_units_sentinels"          "$M"
sed '/DESIGN-UNITS/d' "$VALID" > "$M";                              check_refusal "no block at all"             "design_units_sentinels"          "$M"
mutate 's|"contract_version": "1",|"contract_version": "1",,|' "$M"; check_refusal "unparseable JSON"            "design_block_unparseable"        "$M"
mutate 's|"files": \[ ".claude/scripts/workflow-manifest.sh" \]|"files": []|' "$M"
                                                                    check_refusal "a unit with NO declared files" "unit_files_missing:U1"          "$M"
mutate 's|{ "id": "AC1", "text": "governing lists docs/specs/<id>.md with origin design-artifact" }|"governing lists it"|' "$M"
                                                                    check_refusal "acceptance criterion with no id" "unit_acceptance_id_missing:U1" "$M"
mutate 's|"depends_on": \[\]|"depends_on": [], "implementer_class": "high"|' "$M"
                                                                    check_refusal "escalation with no reason"   "unit_escalation_without_reason:U1" "$M"
mutate 's|"depends_on": \[ "U1" \]|"depends_on": [ "U9" ]|' "$M";   check_refusal "dependency on an undeclared unit" "unit_depends_on_undeclared:U2->U9" "$M"
mutate 's|"depends_on": \[\]|"depends_on": [ "U2" ]|' "$M";         check_refusal "a dependency CYCLE"          "design_units_cyclic"             "$M"
mutate 's|"unit_id": "U2"|"unit_id": "U1"|' "$M";                   check_refusal "a duplicate unit_id"         "unit_id_duplicate:U1"            "$M"
awk '/^```json$/{print; print "```"; next} {print}' "$VALID" > "$M"; check_refusal "a NESTED fence in the block" "design_block_fences"             "$M"
: > "$M";                                                           check_refusal "a zero-byte artifact"        "design_artifact_empty"           "$M"

V_ABSENT=$(bash "$RC" validate-design "$FIXTURE/docs/specs/nope.md" 2>/dev/null)
assert_eq "2.6 a missing file is a usage error, not a design with zero units" "usage" \
    "$(json_field '.error_key' "$V_ABSENT")"

# ===========================================================================
printf '\n=== Section 3: qa-gate.sh design-record — LAYER 2 OF THE EDIT BAN, RUNNING ===\n'
# ===========================================================================

TID=$(bd create "D1 design subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
if [ -z "$TID" ] || [ "$TID" = "null" ]; then
    echo "harness error: could not create a Beads task"
    exit 2
fi
ART="$FIXTURE/docs/specs/$TID.md"
write_artifact "$ART" "$TID"

# A clean change set: the artifact and nothing else.
printf '%s\n' "$ART" > "$TRACKING"

DR=$(bash "$QG" design-record "$TID" 2>&1); DR_RC=$?
assert_eq "3.1 design-record on a clean change set exits 0" "0" "$DR_RC"
assert_eq "3.1b ...status=recorded" "recorded" "$(json_field '.status' "$DR")"

latest_design_record() {
    { bd show "$1" --json --include-comments 2>/dev/null || bd show "$1" --json 2>/dev/null; } \
        | jq -r '[ (if type=="array" then .[0].comments else .comments end) // []
                   | .[].text | select(startswith("DESIGN-ARTIFACT v1 ")) ] | last // ""' 2>/dev/null
}
REC=$(latest_design_record "$TID")
assert_contains "3.2 the record's machine prefix is the DESIGN-ARTIFACT v1 grammar" \
    "DESIGN-ARTIFACT v1 task=$TID designer=designer design_hash=" "$REC"
assert_contains "3.2b ...and carries the unit count" "units=2 at " "$REC"

REC_HASH=$(printf '%s' "$REC" | grep -oE 'design_hash=[A-Za-z0-9-]+' | head -1 | cut -d= -f2-)
ART_BY_HAND=$(sha256_of_file "$ART")
assert_eq "3.3 the recorded design_hash reproduces by hand with shasum -a 256" "$ART_BY_HAND" "$REC_HASH"

# --- THE RUNNABLE HALF OF THE PAIRING -------------------------------------
# Layer 1 is an absence in frontmatter; this is the consequence firing on a real
# source path. A designer holding Write can create it; it cannot be recorded.
#
# THE REFUSAL MOVED, DELIBERATELY (fkm.3 QA round 5). It used to be
# `artifact_outside_spec_dir` — the containment predicate answering for a path
# the caller spelled. `--file` now only ASSERTS the derivation, so a source path
# is refused before any resolution happens at all, and the consequence layer's
# real teeth are 3.7 below (the TRACKER), which is where a path the designer did
# not spell still arrives.
SRC="$FIXTURE/.claude/scripts/thing.sh"
printf '#!/bin/bash\necho hi\n' > "$SRC"
OUT_OUTSIDE=$(bash "$QG" design-record "$TID" --file "$SRC" 2>&1); OUTSIDE_RC=$?
assert_eq "3.4 design-record REFUSES an artifact at a SOURCE path (non-zero exit)" "1" "$OUTSIDE_RC"
assert_eq "3.4b ...error_key=artifact_path_not_derived — --file cannot carry it" "artifact_path_not_derived" \
    "$(json_field '.error_key' "$OUT_OUTSIDE")"
assert_contains "3.4c ...and the refusal NAMES the derived path the task can record" \
    "$FIXTURE/docs/specs/$TID.md" "$(json_field '.observations' "$OUT_OUTSIDE")"

# A file inside the spec dir but not named for the task: the record carries the
# hash and no path, so the path has to be derivable.
WRONGNAME="$FIXTURE/docs/specs/not-the-task.md"
write_artifact "$WRONGNAME" "$TID"
OUT_NAME=$(bash "$QG" design-record "$TID" --file "$WRONGNAME" 2>&1)
assert_eq "3.5 ...and REFUSES a spec-dir file not named for the task" "artifact_path_not_derived" \
    "$(json_field '.error_key' "$OUT_NAME")"
rm -f "$WRONGNAME"

# `..` out of the directory is answered by the same physical resolution.
OUT_DOTDOT=$(bash "$QG" design-record "$TID" --file "$FIXTURE/docs/specs/../../etc/passwd" 2>&1)
assert_not_contains "3.6 a ../ escape from the spec dir does not record" "\"status\":\"recorded\"" "$OUT_DOTDOT"

# designer_touched_source: a source path in the change set, no IMPLEMENTER yet.
printf '%s\n%s\n' "$ART" "$SRC" > "$TRACKING"
OUT_TOUCH=$(bash "$QG" design-record "$TID" 2>&1); TOUCH_RC=$?
assert_eq "3.7 design-record REFUSES while the change set holds a source path (non-zero exit)" "1" "$TOUCH_RC"
assert_eq "3.7b ...error_key=designer_touched_source" "designer_touched_source" \
    "$(json_field '.error_key' "$OUT_TOUCH")"
assert_contains "3.7c ...and NAMES the offending path rather than reporting a count" \
    "$SRC" "$(json_field '.observations' "$OUT_TOUCH")"

# The audited bypass, and its reason lands in the durable record.
OUT_BYPASS=$(bash "$QG" design-record "$TID" --accept-foreign-paths "pre-spawn orchestrator edit" 2>&1)
assert_eq "3.8 the audited bypass records" "recorded" "$(json_field '.status' "$OUT_BYPASS")"
assert_contains "3.8b ...and the reason is in the RECORD, not just the envelope" \
    "[foreign paths accepted: pre-spawn orchestrator edit]" "$(latest_design_record "$TID")"
assert_eq "3.8c ...a bypass with no reason is refused" "missing_bypass_reason" \
    "$(json_field '.error_key' "$(bash "$QG" design-record "$TID" --accept-foreign-paths 2>&1)")"

# CONTROL 1 for 3.7: the same change set, minus the source path, records.
printf '%s\n' "$ART" > "$TRACKING"
assert_eq "3.9 CONTROL: with only the artifact tracked, the same call records" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$TID" 2>&1)")"

# CONTROL 2 for 3.7: the same source path, but an implementer has SPAWNED. The
# check is phase-scoped on the IMPLEMENTER record (written at spawn), not on the
# COMPLETION record (written at finish, which would leave it armed all the way
# through implementation).
printf '%s\n%s\n' "$ART" "$SRC" > "$TRACKING"
IMPL_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bd comments add "$TID" "IMPLEMENTER: role=devops task=$TID at $IMPL_TS" >/dev/null 2>&1 \
    || bd comment add "$TID" "IMPLEMENTER: role=devops task=$TID at $IMPL_TS" >/dev/null 2>&1
OUT_AFTER=$(bash "$QG" design-record "$TID" 2>&1)
assert_eq "3.10 CONTROL: the identical source path records once an implementer has SPAWNED" \
    "recorded" "$(json_field '.status' "$OUT_AFTER")"
assert_contains "3.10b ...and says the check switched off, naming the record that did it" \
    "designer_touched_source is OFF" "$(json_field '.observations' "$OUT_AFTER")"

# A decoy artifact: its own task_id names a different task.
DECOY_TID=$(bd create "D1 decoy" -t task -p 2 --json 2>/dev/null | jq -r '.id')
DECOY_ART="$FIXTURE/docs/specs/$DECOY_TID.md"
write_artifact "$DECOY_ART" "$TID"        # deliberately the WRONG task id inside
printf '%s\n' "$DECOY_ART" > "$TRACKING"
assert_eq "3.11 an artifact whose own task_id names another task is refused" \
    "artifact_task_id_mismatch" \
    "$(json_field '.error_key' "$(bash "$QG" design-record "$DECOY_TID" --file "$DECOY_ART" 2>&1)")"
rm -f "$DECOY_ART"

# A malformed artifact: the validator's key is propagated, not flattened.
BROKEN_TID=$(bd create "D1 broken" -t task -p 2 --json 2>/dev/null | jq -r '.id')
BROKEN_ART="$FIXTURE/docs/specs/$BROKEN_TID.md"
write_artifact "$BROKEN_ART" "$BROKEN_TID"
sed -i.bak 's|"files": \[ ".claude/scripts/workflow-manifest.sh" \]|"files": []|' "$BROKEN_ART"
rm -f "$BROKEN_ART.bak"
printf '%s\n' "$BROKEN_ART" > "$TRACKING"
assert_eq "3.12 a schema failure propagates the validator's OWN key, not a generic one" \
    "unit_files_missing:U1" \
    "$(json_field '.error_key' "$(bash "$QG" design-record "$BROKEN_TID" --file "$BROKEN_ART" 2>&1)")"

# An EMPTY artifact must never be recorded — this is the leg that makes the
# "strip the hash and the binding breaks" meta-test non-vacuous.
EMPTY_TID=$(bd create "D1 empty" -t task -p 2 --json 2>/dev/null | jq -r '.id')
EMPTY_ART="$FIXTURE/docs/specs/$EMPTY_TID.md"
: > "$EMPTY_ART"
printf '%s\n' "$EMPTY_ART" > "$TRACKING"
OUT_EMPTY=$(bash "$QG" design-record "$EMPTY_TID" --file "$EMPTY_ART" 2>&1)
assert_eq "3.13 a ZERO-BYTE artifact is refused before anything is hashed" "design_artifact_empty" \
    "$(json_field '.error_key' "$OUT_EMPTY")"
assert_not_contains "3.13b ...so the empty-bytes constant never reaches a record" \
    "$EMPTY_SHA" "$(latest_design_record "$EMPTY_TID")"
rm -f "$EMPTY_ART"

# ===========================================================================
printf '\n=== Section 4: the approval record binds the design (fourth machine token) ===\n'
# ===========================================================================

# v5 D2 Part B (claude-workflow-plugin-fkm.4) MIGRATION: every approve() call
# in this section (and further down, at ENTRY POINT 4 and section 7) now
# ALSO passes --no-design '<reason>' — approve REFUSES (exit 2,
# no_design_attempted / design_verdict_missing) unless a satisfied,
# independent DESIGN-REVIEW verdict exists, and every task in THIS file has,
# at most, a DESIGN-ARTIFACT record (D1's own, which predates D2's reviewer
# half). Section 4 and ENTRY POINT 4/section 7 are testing DESIGN-BINDING-
# TOKEN and the anchored-reader discipline specifically — an orthogonal axis
# from design-satisfied — so the bypass isolates what each assertion is
# actually about, the same migration seed_completion_record's own header
# documents for the identical shape of acquired precondition (P7).
# --no-design does not skip DESIGN-BINDING-TOKEN: that block runs
# unconditionally, after design-satisfied is resolved either way.
#
# An approvable task, seeded through the REAL writers so a grammar change breaks
# this loudly rather than drifting silently.
seed_approvable() {
    local tid="$1" ts hash art pay
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "IMPLEMENTER: role=devops task=$tid at $ts" >/dev/null 2>&1 \
        || bd comment add "$tid" "IMPLEMENTER: role=devops task=$tid at $ts" >/dev/null 2>&1
    hash=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
    [ -z "$hash" ] && hash="unverified"
    art="$FIXTURE/.claude/.qa-tracking/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"qa-claude","reviewer_model":"seeded-fixture","reviewer_pin":"seeded-fixture","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded fixture","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
        "$tid" "$hash" > "$art"
    # claude-workflow-plugin-rqer (v5 D2): --file now asserts the CANONICAL
    # derived path; piped via stdin instead.
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" review-record "$tid" < "$art" >/dev/null 2>&1
    pay="$FIXTURE/.claude/.qa-tracking/completion-draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    printf '{"task_id":"%s","role":"devops","model":"seeded","pin":"seeded","files_changed":[],"tests_added":[],"decisions":["seeded"],"blockers":[],"llm_observations":"seeded by the design-artifact fixture","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown"}\n' \
        "$tid" > "$pay"
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" completion-record "$tid" --file "$pay" >/dev/null 2>&1
}

APPR_TID=$(bd create "D1 approve subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
APPR_ART="$FIXTURE/docs/specs/$APPR_TID.md"
write_artifact "$APPR_ART" "$APPR_TID"
printf '%s\n' "$APPR_ART" > "$TRACKING"
bash "$QG" enter "$APPR_TID" >/dev/null 2>&1
bash "$QG" design-record "$APPR_TID" >/dev/null 2>&1
APPR_DESIGN_HASH=$(printf '%s' "$(latest_design_record "$APPR_TID")" \
    | grep -oE 'design_hash=[A-Za-z0-9-]+' | head -1 | cut -d= -f2-)
seed_approvable "$APPR_TID"
APPROVE_OUT=$(bash "$QG" approve "$APPR_TID" --no-design "fkm.4: testing DESIGN-BINDING-TOKEN, not design-satisfied" "D1 binding leg" 2>&1)

latest_approval() {
    { bd show "$1" --json --include-comments 2>/dev/null || bd show "$1" --json 2>/dev/null; } \
        | jq -r '[ (if type=="array" then .[0].comments else .comments end) // []
                   | .[].text | select(startswith("QA-GATE APPROVED ")) ] | last // ""' 2>/dev/null
}
APPROVAL=$(latest_approval "$APPR_TID")
assert_eq "4.0 the approve under test succeeded" "approved" "$(json_field '.status' "$APPROVE_OUT")"
assert_contains "4.1 the approval record carries design_hash= as a MACHINE token" \
    "design_hash=$APPR_DESIGN_HASH" "$APPROVAL"
# claude-workflow-plugin-rqer (v5 D2): design_hash= is no longer necessarily
# the LAST token before the timestamp — seed_approvable's review-record call
# now binds a real canonical artifact too, so an artifact_hash=<64 hex> token
# (AC-3) sits between design_hash= and ' at ' whenever that binding verifies,
# which it does here. The token ORDER contract this pins is still "nothing
# but a machine token, in the documented sequence, ever sits between
# worktree= and the timestamp" — updated to name BOTH tokens that sequence
# now covers, rather than silently degrading to "design_hash= appears
# somewhere in the record" (which is what removing the anchor to ' at ' cheaply
# would have measured).
assert_eq "4.1b ...positioned AFTER worktree= and immediately before ' at ' (token ORDER contract)" \
    "yes" \
    "$(printf '%s' "$APPROVAL" | grep -qE 'worktree=[^ ]+ design_hash=[0-9a-fA-F]{64} artifact_hash=[0-9a-fA-F]{64} at [0-9]{4}-' && echo yes || echo no)"
assert_contains "4.1c ...and approve NAMES the binding in its envelope" \
    "design binding VERIFIED" "$(json_field '.observations' "$APPROVE_OUT")"

# COMPATIBILITY: the two shipped readers must extract IDENTICAL values from the
# record now that a fourth token sits on it. Their exact expressions.
READ_CS=$(printf '%s' "$APPROVAL" | jq -Rr 'capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h' 2>/dev/null || echo "")
READ_RB=$(printf '%s' "$APPROVAL" | grep -oE 'reviewed_by=[^ ]+' | head -1 | cut -d= -f2-)
assert_eq "4.2 the llh.18 change_set_hash capture still stops at the space" "yes" \
    "$([ ${#READ_CS} -ge 8 ] && echo yes || echo no)"
assert_eq "4.2b the jio.1 reviewed_by capture is unaffected by the new token" "qa-claude" "$READ_RB"
assert_not_contains "4.2c the new token did not leak into reviewed_by" "design_hash" "$READ_RB"

# --- THE D1 META-TEST -----------------------------------------------------
# "Strip the hash from a recorded approval — the binding must fail."
#
# THE READER IS ANCHORED ON THE MACHINE PREFIX, and that is a fix rather than a
# style choice (QA round 2, R2-F6). This helper previously read
# `grep -oE 'design_hash=[A-Za-z0-9-]+' | head -1`, which is unanchored: the
# summary is unvalidated positional text on the same line, so on a record whose
# token was legitimately WITHHELD the first match is whatever the summary says.
# `[^:]*` is what forbids that — everything after ` at <ISO-8601>:` is summary,
# and no colon may be crossed to reach the token. Section 7 drives both
# spellings against the same records and measures the difference; D6, which is
# the phase that will read this token for real, must copy THIS one.
#
# THE TWO ALTERNATIVES, and why this spelling: a greedy `.*` prefix plus a
# trailing ` at <ts>: ` is defeated by a summary that simply contains that suffix
# (sed prefers the LAST match), and a fully-enumerated token sequence breaks the
# moment a token is absent — hash_field legitimately is, when the change set
# cannot be hashed. The one cost here is a PROJECT PATH containing a colon: the
# worktree token is a filesystem path, and the reader would then return empty.
# That is a false UNBOUND — the fail-closed direction, and the one a reader of a
# security token should pick.
# claude-workflow-plugin-rqer (v5 D2): the optional `(artifact_hash=[0-9a-fA-F]{64} )?`
# group accounts for AC-3's new token, which sits between design_hash= and the
# timestamp whenever a review-artifact binding also verifies on the same
# approval. Optional, not required: callers here include records seeded
# without a review artifact at all, and this reader's whole job is to find
# design_hash= regardless of what does or does not follow it before ' at '.
read_design_binding() {
    printf '%s' "$1" | sed -nE 's/^QA-GATE APPROVED [^:]*design_hash=([0-9a-fA-F]{64}) (artifact_hash=[0-9a-fA-F]{64} )?at [0-9]{4}-.*/\1/p'
}
STRIPPED=$(printf '%s' "$APPROVAL" | sed -E 's/design_hash=[0-9a-fA-F]+ //')
assert_eq "4.3 META: the strip mutation actually removed the token" "yes" \
    "$([ "$STRIPPED" != "$APPROVAL" ] && echo yes || echo no)"
assert_eq "4.3b META: the binding reader reports UNBOUND on the stripped record" "" \
    "$(read_design_binding "$STRIPPED")"
assert_eq "4.3c META control: it reads the real hash on the unstripped record (4.1 is sensitive)" \
    "$APPR_DESIGN_HASH" "$(read_design_binding "$APPROVAL")"
assert_eq "4.3d META: the stripped record is still otherwise coherent (no double space)" "0" \
    "$(printf '%s' "$STRIPPED" | grep -c '  ' | tr -d ' \n')"

# --- CONTINUOUS ENFORCEMENT IS THE LIVE RECOMPUTE, NOT A LABEL -------------
# A one-byte edit to the artifact after it was recorded must UNBIND the next
# approval and say why. This is what makes "silent deviation is illegitimate"
# true rather than aspirational.
DRIFT_TID=$(bd create "D1 drift subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
DRIFT_ART="$FIXTURE/docs/specs/$DRIFT_TID.md"
write_artifact "$DRIFT_ART" "$DRIFT_TID"
printf '%s\n' "$DRIFT_ART" > "$TRACKING"
bash "$QG" enter "$DRIFT_TID" >/dev/null 2>&1
bash "$QG" design-record "$DRIFT_TID" >/dev/null 2>&1
printf '\n<!-- one byte later -->\n' >> "$DRIFT_ART"     # the design moved
seed_approvable "$DRIFT_TID"
DRIFT_OUT=$(bash "$QG" approve "$DRIFT_TID" --no-design "fkm.4: testing DESIGN-BINDING-TOKEN, not design-satisfied" "D1 drift leg" 2>&1)
DRIFT_APPROVAL=$(latest_approval "$DRIFT_TID")
assert_eq "4.4 an approve after a post-record artifact edit still succeeds (D1 records, D2 refuses)" \
    "approved" "$(json_field '.status' "$DRIFT_OUT")"
assert_eq "4.4b ...but writes NO design_hash token — the binding is withheld, not guessed" "" \
    "$(read_design_binding "$DRIFT_APPROVAL")"
assert_contains "4.4c ...and names the divergence with BOTH hashes" \
    "the design artifact has CHANGED since it was recorded" "$(json_field '.observations' "$DRIFT_OUT")"

# A task with no design at all: unbound, with the reason named. Ordinary today.
NODES_TID=$(bd create "D1 no-design subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
printf '%s\n' "$FIXTURE/docs/specs/valid-design.md" > "$TRACKING"
bash "$QG" enter "$NODES_TID" >/dev/null 2>&1
seed_approvable "$NODES_TID"
NODES_OUT=$(bash "$QG" approve "$NODES_TID" --no-design "fkm.4: this IS the no-design-at-all case under test" "D1 no-design leg" 2>&1)
assert_eq "4.5 a task with no DESIGN-ARTIFACT record approves with no token" "" \
    "$(read_design_binding "$(latest_approval "$NODES_TID")")"
assert_contains "4.5b ...and the absence is NAMED rather than silent" \
    "no design binding (no DESIGN-ARTIFACT record" "$(json_field '.observations' "$NODES_OUT")"

# --- META: strip the token region from the SHIPPED script ------------------
# Same contract the WORKTREE-TOKEN META asserts: a build with the region excised
# must still approve and must write a coherent pre-D1 record.
STRIP_DIR="$FIXTURE/strip"
mkdir -p "$STRIP_DIR"
awk '/# DESIGN-BINDING-TOKEN BEGIN/{s=1} !s{print} /# DESIGN-BINDING-TOKEN END/{s=0}' \
    "$QG" > "$STRIP_DIR/qa-gate.sh"
STRIP_DELTA=$(( $(wc -l < "$QG") - $(wc -l < "$STRIP_DIR/qa-gate.sh") ))
assert_eq "4.6 META: the region strip actually removed lines" "yes" \
    "$([ "$STRIP_DELTA" -gt 10 ] && echo yes || echo no)"
if bash -n "$STRIP_DIR/qa-gate.sh" 2>/dev/null; then
    assert_eq "4.6b META: the stripped copy is still valid bash (empty defaults live OUTSIDE the region)" "0" "0"
else
    assert_eq "4.6b META: the stripped copy is still valid bash (empty defaults live OUTSIDE the region)" "0" "1"
fi
cp "$STRIP_DIR/qa-gate.sh" "$FIXTURE/.claude/scripts/qa-gate-stripped.sh"
chmod +x "$FIXTURE/.claude/scripts/qa-gate-stripped.sh"
STRIP_TID=$(bd create "D1 strip META subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
STRIP_ART="$FIXTURE/docs/specs/$STRIP_TID.md"
write_artifact "$STRIP_ART" "$STRIP_TID"
printf '%s\n' "$STRIP_ART" > "$TRACKING"
bash "$QG" enter "$STRIP_TID" >/dev/null 2>&1
bash "$QG" design-record "$STRIP_TID" >/dev/null 2>&1
seed_approvable "$STRIP_TID"
STRIP_OUT=$(bash "$FIXTURE/.claude/scripts/qa-gate-stripped.sh" approve "$STRIP_TID" --no-design "fkm.4: testing DESIGN-BINDING-TOKEN, not design-satisfied" "META strip leg" 2>&1)
STRIP_APPROVAL=$(latest_approval "$STRIP_TID")
assert_eq "4.7 META: the stripped build still approves" "approved" "$(json_field '.status' "$STRIP_OUT")"
assert_eq "4.7b META: ...and writes NO design token (4.1 WOULD fail against this build)" "" \
    "$(read_design_binding "$STRIP_APPROVAL")"
assert_eq "4.7c META: ...with no dangling token and no double space in the record" "0" \
    "$(printf '%s' "$STRIP_APPROVAL" | grep -c '  ' | tr -d ' \n')"
rm -f "$FIXTURE/.claude/scripts/qa-gate-stripped.sh"

# ===========================================================================
printf '\n=== Section 5: layer 1 (the tools omission) and its negative control ===\n'
# ===========================================================================

DESIGNER_MD="$PLUGIN_DIR/.claude/agents/designer.md"
assert_eq "5.0 designer.md exists" "yes" "$([ -f "$DESIGNER_MD" ] && echo yes || echo no)"

# tools_of <agent-file> -> the comma-separated tools value, or empty.
tools_of() {
    awk 'NR==1 && $0=="---"{f=1;next} f && /^---$/{exit} f && /^tools:[[:space:]]/{sub(/^tools:[[:space:]]*/,"");print;exit}' "$1"
}
# grants_tool <tools-line> <token> -> 0 when the token appears as its own member.
grants_tool() {
    printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -qxF "$2"
}

DESIGNER_TOOLS=$(tools_of "$DESIGNER_MD")
assert_eq "5.1 designer.md HAS a tools: line (an absent one would inherit everything)" "yes" \
    "$([ -n "$DESIGNER_TOOLS" ] && echo yes || echo no)"
assert_eq "5.2 designer.md does NOT grant Bash — the shell vector" "absent" \
    "$(grants_tool "$DESIGNER_TOOLS" "Bash" && echo present || echo absent)"
assert_eq "5.3 designer.md does NOT grant Edit — the patch vector" "absent" \
    "$(grants_tool "$DESIGNER_TOOLS" "Edit" && echo present || echo absent)"
# STATED, NOT ASSUMED: Write is RETAINED. The artifact is the designer's only
# deliverable and writing it is the only way to produce it, so this omission is
# not a sandbox — layer 2 (section 3) is what makes writing anything else
# consequential. Asserting the retention keeps a future "tighten the tools list"
# change from silently removing the designer's ability to do its job.
assert_eq "5.4 designer.md DOES still grant Write (deliberate; layer 2 is the enforcing layer)" \
    "present" "$(grants_tool "$DESIGNER_TOOLS" "Write" && echo present || echo absent)"
assert_eq "5.5 designer.md keeps its code-graph grant (its body names impact_of)" "present" \
    "$(grants_tool "$DESIGNER_TOOLS" "mcp__code-graph" && echo present || echo absent)"

# THE NEGATIVE CONTROL for 5.2/5.3. An absence assertion is only worth anything
# if the same checker reports PRESENCE on a file that has it. Without this, a
# typo in tools_of() (a changed frontmatter shape, a renamed key) would make
# every absence assertion above pass over an empty string.
CTRL_MD="$FIXTURE/control-agent.md"
printf -- '---\nname: control\ntools: Read, Bash, Write, Edit\n---\n\nbody\n' > "$CTRL_MD"
CTRL_TOOLS=$(tools_of "$CTRL_MD")
assert_eq "5.6 CONTROL: the same extractor reads a tools line that HAS Bash" "present" \
    "$(grants_tool "$CTRL_TOOLS" "Bash" && echo present || echo absent)"
assert_eq "5.6b CONTROL: ...and Edit" "present" \
    "$(grants_tool "$CTRL_TOOLS" "Edit" && echo present || echo absent)"
assert_eq "5.6c CONTROL: ...and correctly reports a tool that IS absent from it" "absent" \
    "$(grants_tool "$CTRL_TOOLS" "WebFetch" && echo present || echo absent)"

# The designer cannot run its own record-writing command (no Bash), so the
# prompt must hand the command back rather than pretend to run it.
assert_eq "5.7 designer.md hands the record command back instead of claiming to run it" "yes" \
    "$(grep -qF 'DESIGN-RELAY: status=artifact-ready' "$DESIGNER_MD" && echo yes || echo no)"

# THE SPEC-DIR PARITY. Two scripts name the directory: the governing declaration
# and the record's path refusals. They must agree, or a design recorded in one
# place is invisible to the veto in the other. Same writer/reader parity
# discipline rubric_version carries.
# STRUCTURAL: ONE PARSER FOR THE DESIGN-UNITS GRAMMAR. review-check.sh owns it;
# qa-gate.sh must read what it needs off the validator's envelope and never
# re-extract the block. An ad-hoc second extraction there is the drift class the
# ONE-validator rule exists to prevent, and it is invisible until the two copies
# disagree — so it is asserted structurally rather than left to review.
assert_eq "5.7b qa-gate.sh does not carry its own DESIGN-UNITS extraction" "0" \
    "$(grep -c 'DESIGN-UNITS BEGIN' "$PLUGIN_DIR/.claude/scripts/qa-gate.sh" | tr -d ' \n')"
assert_eq "5.7c CONTROL: review-check.sh — the ONE parser — does carry it" "yes" \
    "$(grep -q 'DESIGN-UNITS BEGIN' "$PLUGIN_DIR/.claude/scripts/review-check.sh" && echo yes || echo no)"

WM_DIR=$(grep -E '^DESIGN_SPEC_SUBDIR=' "$PLUGIN_DIR/.claude/scripts/workflow-manifest.sh" | head -1 | cut -d'"' -f2)
QG_DIR=$(grep -E '^DESIGN_SPEC_SUBDIR=' "$PLUGIN_DIR/.claude/scripts/qa-gate.sh" | head -1 | cut -d'"' -f2)
assert_eq "5.8 the governing declaration names a spec dir" "docs/specs" "$WM_DIR"
assert_eq "5.8b ...and design-record names the SAME one" "$WM_DIR" "$QG_DIR"

# ===========================================================================
printf '\n=== Section 6: hostile path spellings, at EVERY entry point ===\n'
# ===========================================================================
#
# WHY THIS SECTION EXISTS, in the words of the review that produced it: "a
# pairing requirement satisfied on the safe half of a pair manufactures
# confidence." Leg 3.6 above feeds ../ to --file — the path that was ALREADY
# resolved physically — and correctly refuses, so a green run read as "traversal
# is handled". The check that actually enforces the edit ban reads the TRACKER,
# and no leg ever put a hostile spelling into it. Two HIGH findings lived in
# exactly that gap, and both were reproduced against the shipped code before
# anything here was written:
#
#   R2-F1  design_path_is_foreign reduced LEXICALLY. $PROJECT_DIR/docs/specs/
#          ../../.claude/scripts/pwn.sh read as NOT FOREIGN, so design-record
#          answered `recorded` with a source path in the change set — while the
#          SAME path spelled plainly was refused.
#   R2-F2  a symlinked artifact escaped BOTH halves: `find -maxdepth 1 -type f`
#          omitted it from the governing declaration (no row at all, so the F1
#          doc-only fast path reopened for the design artifact itself), and
#          design-record resolved only dirname() so it accepted the link and
#          bound the OUTSIDE file's bytes — measured identical to
#          `shasum -a 256 outside/design.md`.
#
# So each entrance a hostile path can arrive through is driven here — the
# TRACKER, --file, and the GOVERNING query — in each of the three spellings that
# defeat a prefix match: a `..` segment, a leaf symlink, and a relative path.
# Every refusal leg is paired with a CONTROL in the same spelling class, because
# a containment fix that simply called everything foreign would pass all of the
# refusals and none of the controls.

HOSTILE_TID=$(bd create "D1 hostile spellings" -t task -p 1 --json 2>/dev/null | jq -r '.id')
H_ART="$FIXTURE/docs/specs/$HOSTILE_TID.md"
write_artifact "$H_ART" "$HOSTILE_TID"
H_SRC="$FIXTURE/.claude/scripts/pwn.sh"
printf '#!/bin/bash\necho pwned\n' > "$H_SRC"
mkdir -p "$FIXTURE/outside" "$FIXTURE/docs/specs/sub" "$FIXTURE/docs/design-notes"
write_artifact "$FIXTURE/outside/design.md" "$HOSTILE_TID"
OUTSIDE_SHA=$(sha256_of_file "$FIXTURE/outside/design.md")
assert_eq "6.0 precondition: the outside artifact has a computable digest to bind" \
    "64" "${#OUTSIDE_SHA}"

# --- ENTRY POINT 1: THE TRACKER (designer_touched_source) ------------------
# Each leg puts the artifact AND one hostile spelling of a source path in the
# change set. The refusal must be the same one the plain spelling gets.
hostile_tracker() {
    printf '%s\n%s\n' "$H_ART" "$1" > "$TRACKING"
    bash "$QG" design-record "$HOSTILE_TID" 2>&1
}
assert_eq "6.1 TRACKER: an absolute .. traversal to a source path is FOREIGN (R2-F1)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/../../.claude/scripts/pwn.sh")")"
assert_eq "6.1b TRACKER: the RELATIVE traversal spelling too" "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "docs/specs/../../.claude/scripts/pwn.sh")")"
# 6.1c's REASON CHANGED IN ROUND 6 and the name says so. It used to pass because
# the tracker followed the leaf into `.claude/scripts` and compared directories;
# the tracker no longer reads a target (R6-F1), so what refuses it now is the
# NAME — an entry in the declared directory that is not the derived filename is
# not this task's artifact whatever it points at. The leaf-following claim it
# used to carry lives at 6.3b, on the RECORD side, where following the leaf is
# the correct answer and R2-F2 is still closed.
ln -sf "../../.claude/scripts/pwn.sh" "$FIXTURE/docs/specs/link-to-src.md"
assert_eq "6.1c TRACKER: a LEAF SYMLINK sitting in the spec dir under a foreign NAME is FOREIGN" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/link-to-src.md")")"
printf 'nested\n' > "$FIXTURE/docs/specs/sub/deeper.md"
assert_eq "6.1d TRACKER: a NESTED path under the spec dir is FOREIGN (the declaration is maxdepth 1)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/sub/deeper.md")")"
assert_contains "6.1e TRACKER: the refusal NAMES the offending spelling rather than counting it" \
    "docs/specs/../../.claude/scripts/pwn.sh" \
    "$(json_field '.observations' "$(hostile_tracker "$FIXTURE/docs/specs/../../.claude/scripts/pwn.sh")")"
# THE DIRECTORY-ENTRY SPELLING, pinned because the verdict CHANGED with the fix
# and the change is deliberate. `reconcile_tracker` expands a collapsed
# `?? docs/specs/` into the files inside it, so the ordinary path never produces
# this entry; it survives only when that expansion is unavailable (a git
# failure), where reconcile keeps the directory rather than dropping it. The old
# prefix match read `docs/specs/` as INSIDE (a `*` glob matches the empty
# string); one directory entry cannot be shown to be only the artifact, so it is
# foreign now — refused with the audited bypass available, which is the
# fail-closed direction under an unreadable git.
#
# ROUND 6 MADE THE LEG'S OWN TITLE ITS REASON: `docs/specs/` has an EMPTY last
# component, so the NAME arm refuses it directly. The directory arm reaches the
# same verdict (dirname's trailing-slash rule answers `docs`), so neither arm is
# load-bearing here alone — see the report's disclosure on the trailing-slash
# rule, which no longer has a behavioural leg of its own.
assert_eq "6.1f TRACKER: the bare declared DIRECTORY is foreign too (it names no artifact)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/")")"

# CONTROLS. Same predicate, the spellings that must still record — otherwise
# "everything is foreign" would satisfy every leg above.
printf '%s\n' "$H_ART" > "$TRACKING"
assert_eq "6.2 CONTROL: the artifact's own absolute path still records" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$HOSTILE_TID" 2>&1)")"
printf '%s\n' "docs/specs/$HOSTILE_TID.md" > "$TRACKING"
assert_eq "6.2b CONTROL: ...and its REPO-RELATIVE spelling, which is what a reconcile writes" \
    "recorded" "$(json_field '.status' "$(bash "$QG" design-record "$HOSTILE_TID" 2>&1)")"
# THE SYMLINKED-ROOT SPELLING. Not hypothetical: on this platform $TMPDIR is
# itself reached through /var -> /private/var, so PROJECT_DIR and `pwd -P`
# already disagree. An explicit alias makes the same case run on Linux too.
ROOT_ALIAS="$TEST_HOME/root-alias"
ln -sfn "$FIXTURE" "$ROOT_ALIAS"
printf '%s\n' "$ROOT_ALIAS/docs/specs/$HOSTILE_TID.md" > "$TRACKING"
assert_eq "6.2c CONTROL: the artifact spelled through a SYMLINKED ROOT is not foreign either" \
    "recorded" "$(json_field '.status' "$(bash "$QG" design-record "$HOSTILE_TID" 2>&1)")"
# ...and the same alias does NOT launder a source path.
printf '%s\n%s\n' "$H_ART" "$ROOT_ALIAS/.claude/scripts/pwn.sh" > "$TRACKING"
assert_eq "6.2d ...while a SOURCE path through that same alias is still FOREIGN" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(bash "$QG" design-record "$HOSTILE_TID" 2>&1)")"

# --- ENTRY POINT 2: --file -------------------------------------------------
# 3.6 already drives an absolute `..`; these are the two spellings it cannot see.
#
# THE TARGET IS A VALID ARTIFACT *FOR THIS TASK*, and that is load-bearing rather
# than tidy. With a mismatched task_id inside it, the decoy check
# (artifact_task_id_mismatch) refuses first and 6.3c/6.3d then pass against a
# build with NO containment at all — which the M7 mutation run demonstrated
# before this fixture was corrected. Containment must be the only thing standing
# between the link and a record, or these legs measure the decoy check.
SYMLINK_TID=$(bd create "D1 symlinked artifact" -t task -p 1 --json 2>/dev/null | jq -r '.id')
SYM_ART="$FIXTURE/docs/specs/$SYMLINK_TID.md"
SYM_TARGET="$FIXTURE/outside/design-$SYMLINK_TID.md"
write_artifact "$SYM_TARGET" "$SYMLINK_TID"
SYM_OUTSIDE_SHA=$(sha256_of_file "$SYM_TARGET")
ln -sfn "../../outside/design-$SYMLINK_TID.md" "$SYM_ART"
printf '%s\n' "$SYM_ART" > "$TRACKING"
assert_eq "6.3 precondition: the symlink resolves to a file whose bytes ARE hashable" \
    "$SYM_OUTSIDE_SHA" "$(bash "$WM" hash-file "$SYM_ART" 2>/dev/null)"
assert_eq "6.3a precondition: ...and that file is a VALID artifact for THIS task, so only containment refuses it" \
    "true" "$(json_field '.ok' "$(bash "$RC" validate-design "$SYM_TARGET" 2>/dev/null)")"
OUT_SYM=$(bash "$QG" design-record "$SYMLINK_TID" --file "$SYM_ART" 2>&1)
assert_eq "6.3b --file: a LEAF SYMLINK out of the spec dir is refused (R2-F2)" \
    "artifact_outside_spec_dir" "$(json_field '.error_key' "$OUT_SYM")"
assert_not_contains "6.3c ...and the outside file's digest reaches NO record" \
    "$SYM_OUTSIDE_SHA" "$(latest_design_record "$SYMLINK_TID")"
assert_eq "6.3d ...so the task carries no DESIGN-ARTIFACT record at all" "" \
    "$(latest_design_record "$SYMLINK_TID")"
OUT_REL_DOTDOT=$(bash "$QG" design-record "$HOSTILE_TID" --file "docs/specs/../../outside/design.md" 2>&1)
assert_eq "6.4 --file: the RELATIVE traversal spelling is refused too" \
    "artifact_path_not_derived" "$(json_field '.error_key' "$OUT_REL_DOTDOT")"
# CONTROL: --file still accepts a relative spelling of the REAL artifact, so the
# refusal above is about containment and not about relative paths as a class.
printf '%s\n' "$H_ART" > "$TRACKING"
assert_eq "6.4b CONTROL: --file with a RELATIVE spelling of the real artifact records" \
    "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$HOSTILE_TID" --file "docs/specs/$HOSTILE_TID.md" 2>&1)")"
# ONE SPELLING, ONE FILE — and after round 5 it is one spelling because there is
# only one VALUE, not because the argument is normalised carefully. `-f` and
# `hash-file` resolve a relative path against $PWD while the containment
# predicate resolves one against $PROJECT_DIR; with those two roots differing, a
# relative --file used to be CHECKED as one file and HASHED as another. The
# argument is now compared as a STRING against the derived path, so the decoy
# below cannot be reached at all: the record binds the artifact in $PROJECT_DIR
# whatever the cwd is. The leg is kept, and its assertion inverted, because it is
# the only place the two-roots disagreement is observable — the same relative
# spelling, a real file at it in another cwd, different bytes.
#
# THE DECOY ROOT LIVES INSIDE THE FIXTURE, and that placement is load-bearing:
# `bd` resolves its database by walking UP from the CURRENT directory, so a
# design-record run from a cwd outside the Beads workspace reports
# `status=recorded` while `add_comment`'s bd call fails and the record only
# reaches sync-errors.log (measured — `require_bd` checks that
# $PROJECT_DIR/.beads EXISTS, not that bd can resolve it from here). Under a
# decoy root in $TEST_HOME, 6.4e was therefore unfalsifiable: no record could
# land whatever the code did. Inside the fixture, bd walks up to the real
# database and the mutation's record is visible.
OTHER_CWD="$FIXTURE/decoy-root"
mkdir -p "$OTHER_CWD/docs/specs"
write_artifact "$OTHER_CWD/docs/specs/$HOSTILE_TID.md" "$HOSTILE_TID"
printf '\n<!-- a DIFFERENT file at the same relative spelling -->\n' >> "$OTHER_CWD/docs/specs/$HOSTILE_TID.md"
OTHER_SHA=$(sha256_of_file "$OTHER_CWD/docs/specs/$HOSTILE_TID.md")
assert_eq "6.4c precondition: the decoy at that spelling really has different bytes" "differ" \
    "$([ "$OTHER_SHA" != "$(sha256_of_file "$H_ART")" ] && echo differ || echo same)"
OUT_CWD=$( (cd "$OTHER_CWD" && bash "$QG" design-record "$HOSTILE_TID" --file "docs/specs/$HOSTILE_TID.md" 2>&1) )
assert_eq "6.4d a relative --file names the DERIVED path, so the cwd cannot redirect it" \
    "recorded" "$(json_field '.status' "$OUT_CWD")"
assert_eq "6.4d2 ...and the digest it binds is the artifact under \$PROJECT_DIR, not the decoy at the same spelling" \
    "$(sha256_of_file "$H_ART")" \
    "$(printf '%s' "$(latest_design_record "$HOSTILE_TID")" | grep -oE 'design_hash=[A-Za-z0-9-]+' | head -1 | cut -d= -f2-)"
assert_not_contains "6.4e ...and the decoy's bytes reach no record (checked one file, hashed the other)" \
    "$OTHER_SHA" "$(latest_design_record "$HOSTILE_TID")"

# --- ENTRY POINT 3: THE GOVERNING QUERY ------------------------------------
# The other half of R2-F2, in the same fixture as the refusal above, so "escapes
# BOTH halves" is answered by two legs that see the same symlink.
GOV_OUT=$(bash "$WM" governing "$FIXTURE" 2>/dev/null)
assert_eq "6.5 GOVERNING: the symlinked artifact IS declared (find -type f omitted it)" "1" \
    "$(printf '%s\n' "$GOV_OUT" | awk -F'\t' -v p="docs/specs/$SYMLINK_TID.md" '$1 == p' | grep -c . | tr -d ' \n')"
assert_eq "6.5b ...with origin design-artifact, exactly like a regular one" "design-artifact" \
    "$(printf '%s\n' "$GOV_OUT" | awk -F'\t' -v p="docs/specs/$SYMLINK_TID.md" '$1 == p {print $2}' | head -1)"
assert_eq "6.5c CONTROL: the regular artifact beside it is still declared" "1" \
    "$(printf '%s\n' "$GOV_OUT" | awk -F'\t' -v p="docs/specs/$HOSTILE_TID.md" '$1 == p' | grep -c . | tr -d ' \n')"
# ANTI-OVERREACH: a symlink in a directory the project declares NOTHING about
# must stay out. Without this, "declare every symlink" would pass 6.5.
ln -sfn "../../outside/design.md" "$FIXTURE/docs/design-notes/linked-note.md"
GOV_OUT2=$(bash "$WM" governing "$FIXTURE" 2>/dev/null)
assert_eq "6.5d ANTI-OVERREACH: a symlink in an UNDECLARED sibling directory is not governing" "0" \
    "$(printf '%s\n' "$GOV_OUT2" | awk -F'\t' '$1 == "docs/design-notes/linked-note.md"' | grep -c . | tr -d ' \n')"

# --- THE READ WINDOW (R2-F3) -----------------------------------------------
# A writer landing between the validator's read and the hasher's read. Delivered
# deterministically by a shim AT THE VALIDATOR'S PATH: it runs the real
# validator, then rewrites the artifact before returning. qa-gate.sh is
# UNMODIFIED, and the write lands exactly in the window the finding names.
TOCTOU_TID=$(bd create "D1 read-window subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
TOC_ART="$FIXTURE/docs/specs/$TOCTOU_TID.md"
write_artifact "$TOC_ART" "$TOCTOU_TID"
printf '%s\n' "$TOC_ART" > "$TRACKING"
TOC_VALID_SHA=$(sha256_of_file "$TOC_ART")
cp "$RC" "$FIXTURE/.claude/scripts/review-check.real.sh"
install_swap_shim() {          # $1 = 1 to swap the artifact, 0 for the control
    cat > "$RC" <<SHIM
#!/bin/bash
out=\$(bash "$FIXTURE/.claude/scripts/review-check.real.sh" "\$@"); rc=\$?
if [ "\${1:-}" = "validate-design" ] && [ "$1" = "1" ]; then
    printf '# Design — swapped after validation\nno units block here\n' > "$TOC_ART"
fi
printf '%s\n' "\$out"
exit \$rc
SHIM
    chmod +x "$RC"
}
install_swap_shim 1
OUT_TOC=$(bash "$QG" design-record "$TOCTOU_TID" 2>&1)
TOC_DISK_SHA=$(sha256_of_file "$TOC_ART")
assert_eq "6.6 precondition: the shim really did swap the bytes inside the window" "differ" \
    "$([ "$TOC_DISK_SHA" != "$TOC_VALID_SHA" ] && echo differ || echo same)"
assert_eq "6.6b precondition: the swapped bytes are SCHEMA-INVALID, so binding them is the defect" \
    "design_section_missing" \
    "$(json_field '.error_key' "$(bash "$FIXTURE/.claude/scripts/review-check.real.sh" validate-design "$TOC_ART" 2>/dev/null)")"
assert_eq "6.6c the record is REFUSED when the artifact moves during it (R2-F3)" \
    "design_artifact_changed_during_record" "$(json_field '.error_key' "$OUT_TOC")"
assert_eq "6.6d ...and NOTHING is recorded, so no approve can corroborate the unvalidated bytes" "" \
    "$(latest_design_record "$TOCTOU_TID")"
assert_not_contains "6.6e ...least of all a binding naming the bytes the validator never saw" \
    "$TOC_DISK_SHA" "$(latest_design_record "$TOCTOU_TID")"
# CONTROL: the identical shim WITHOUT the swap. The refusal above must be caused
# by the write, not by the shim being in the path.
write_artifact "$TOC_ART" "$TOCTOU_TID"
install_swap_shim 0
assert_eq "6.6f CONTROL: the same shim with no write records normally" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$TOCTOU_TID" 2>&1)")"
cp "$FIXTURE/.claude/scripts/review-check.real.sh" "$RC"
rm -f "$FIXTURE/.claude/scripts/review-check.real.sh"
assert_eq "6.6g CONTROL: the real validator is restored (later sections use it)" "true" \
    "$(json_field '.ok' "$(bash "$RC" validate-design "$TOC_ART" 2>/dev/null)")"

# --- ENTRY POINT 4: approve's LIVE RE-HASH ---------------------------------
# The THIRD caller of the containment question, and the one that would say
# `design binding VERIFIED` over a document the declaration does not govern.
# The swap keeps the bytes IDENTICAL, so the hash comparison agrees and
# containment is the only thing that can refuse it — which is what makes this a
# test of the containment arm rather than of the drift arm 4.4 already covers.
# Its positive control is 4.1c, where the same ladder DOES report VERIFIED.
SWAP_TID=$(bd create "D1 post-record symlink swap" -t task -p 1 --json 2>/dev/null | jq -r '.id')
SWAP_ART="$FIXTURE/docs/specs/$SWAP_TID.md"
write_artifact "$SWAP_ART" "$SWAP_TID"
printf '%s\n' "$SWAP_ART" > "$TRACKING"
assert_eq "6.7 precondition: the design recorded normally, over the real file" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$SWAP_TID" 2>&1)")"
SWAP_SHA=$(sha256_of_file "$SWAP_ART")
cp "$SWAP_ART" "$FIXTURE/outside/swapped-$SWAP_TID.md"
rm -f "$SWAP_ART"
ln -sfn "../../outside/swapped-$SWAP_TID.md" "$SWAP_ART"
assert_eq "6.7b precondition: the swap kept the digest IDENTICAL, so no drift arm can fire" \
    "$SWAP_SHA" "$(bash "$WM" hash-file "$SWAP_ART" 2>/dev/null)"
bash "$QG" enter "$SWAP_TID" >/dev/null 2>&1
seed_approvable "$SWAP_TID"
SWAP_OUT=$(bash "$QG" approve "$SWAP_TID" --no-design "fkm.4: testing DESIGN-BINDING-TOKEN containment, not design-satisfied" "D1 approve-containment leg" 2>&1)
assert_eq "6.7c precondition: the approve under test SUCCEEDED (or 6.7d reads an absent record)" \
    "approved" "$(json_field '.status' "$SWAP_OUT")"
assert_eq "6.7d approve WITHHOLDS the binding when the artifact resolves outside the declared dir" "" \
    "$(read_design_binding "$(latest_approval "$SWAP_TID")")"
assert_contains "6.7e ...naming containment as the reason, not a hash mismatch — the hashes AGREE" \
    "does not resolve INSIDE docs/specs/" "$(json_field '.observations' "$SWAP_OUT")"

# --- THE PREDICATE IS PHYSICAL, OR IT IS NOT A PREDICATE (R3-F1 / R4-F1) ---
# Round 3 found the round-2 fix incomplete, and both reviewers found it from
# different fixtures. `cd <dir>` is bash LOGICAL mode: it collapses `..`
# LEXICALLY and only falls back to physical resolution when the reduced path
# fails to chdir. So a `..` FOLLOWING a directory symlink is resolved against the
# SPELLING, and `pwd -P` cannot undo it — `pwd -P` reports the directory the `cd`
# landed in, and by then the wrong directory has already been chosen.
#
# ONE FIXTURE INGREDIENT: a directory symlink inside the declared directory. The
# escape spelling's dirname (`docs/specs/esc-dir/..`) reduces LEXICALLY to
# `docs/specs`, which exists, so the chdir succeeds and the fallback never runs.
# That is the whole mechanism, and it is why the reduction must never happen:
# the predicate examined `docs/specs` while the kernel opened `outside/`.
#
# THE SHIPPED SUITE WAS BLIND TO IT — QA measured 166/166 before AND after the
# one-word fix — so both legs below were written and OBSERVED RED against the
# unfixed bytes before `-P` was added. A leg written after a fix that passes
# proves only that it was written after the fix.
ESC_TID=$(bd create "D1 dir-symlink escape" -t task -p 1 --json 2>/dev/null | jq -r '.id')
mkdir -p "$FIXTURE/outside/child"
ln -sfn "../../outside/child" "$FIXTURE/docs/specs/esc-dir"
ESC_SRC="$FIXTURE/outside/pwn-escape.sh"
ESC_SPELLING="$FIXTURE/docs/specs/esc-dir/../pwn-escape.sh"
ESC_NONCE="nonce-$$-escaped"
printf '#!/bin/bash\necho %s\n' "$ESC_NONCE" > "$ESC_SPELLING"
# THE HARM, MADE CONCRETE FIRST: written through the spec-dir spelling, landed
# outside it. Two spellings, ONE file — which is exactly what makes a predicate
# that answers differently for the two a hole rather than a strictness question.
assert_eq "6.8 precondition: a write through the spec-dir spelling lands OUTSIDE the spec dir" \
    "1" "$(grep -c "$ESC_NONCE" "$ESC_SRC" 2>/dev/null | tr -d ' \n')"
assert_eq "6.8a precondition: ...and the dirname really does reduce LEXICALLY to the declared dir" \
    "$( ( cd "$FIXTURE/docs/specs" && pwd -P ) )" \
    "$( ( cd "$(dirname "$ESC_SPELLING")" 2>/dev/null && pwd -P ) )"
assert_eq "6.8b TRACKER: a '..' after a DIRECTORY symlink is FOREIGN (R4-F1)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$ESC_SPELLING")")"
assert_eq "6.8c CONTROL: the SAME FILE spelled plainly gets the SAME refusal" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$ESC_SRC")")"
# ANTI-OVERREACH, in the SAME spelling class: a `..` after a symlink that lands
# back INSIDE the declared directory must still record. Without this leg,
# "refuse anything with a symlink and a .. in it" would satisfy 6.8b.
ln -sfn "sub" "$FIXTURE/docs/specs/in-dir"
assert_eq "6.8d CONTROL: a '..' after a symlink that lands back INSIDE the dir still records" \
    "recorded" \
    "$(json_field '.status' "$(hostile_tracker "$FIXTURE/docs/specs/in-dir/../$HOSTILE_TID.md")")"

# THE SAME SPELLING AT --file, where the consequence is the BINDING rather than
# the ban: QA drove this one to a recorded design_hash equal to the OUTSIDE
# decoy's digest. The decoy is a VALID artifact FOR THIS TASK and is NAMED for
# it, so every earlier refusal (not-found, not-derived, task-id mismatch,
# schema) passes and containment is the only thing left — the M7 fixture
# correction, applied rather than restated.
ESC_ART_OUT="$FIXTURE/outside/$ESC_TID.md"
write_artifact "$ESC_ART_OUT" "$ESC_TID"
ESC_OUT_SHA=$(sha256_of_file "$ESC_ART_OUT")
ESC_FILE_SPELLING="$FIXTURE/docs/specs/esc-dir/../$ESC_TID.md"
assert_eq "6.9 precondition: the escape spelling hashes to the OUTSIDE decoy, not to anything in the dir" \
    "$ESC_OUT_SHA" "$(bash "$WM" hash-file "$ESC_FILE_SPELLING" 2>/dev/null)"
assert_eq "6.9a precondition: ...and it is a VALID design for THIS task, so only containment can refuse it" \
    "true" "$(json_field '.ok' "$(bash "$RC" validate-design "$ESC_FILE_SPELLING" 2>/dev/null)")"
printf '%s\n' "$ESC_FILE_SPELLING" > "$TRACKING"
OUT_ESC_FILE=$(bash "$QG" design-record "$ESC_TID" --file "$ESC_FILE_SPELLING" 2>&1)
assert_eq "6.9b --file: the dir-symlink escape is refused (R4-F1, --file side)" \
    "artifact_path_not_derived" "$(json_field '.error_key' "$OUT_ESC_FILE")"
assert_not_contains "6.9c ...and the OUTSIDE decoy's digest reaches NO record" \
    "$ESC_OUT_SHA" "$(latest_design_record "$ESC_TID")"
assert_eq "6.9d ...so the task carries no DESIGN-ARTIFACT record at all" "" \
    "$(latest_design_record "$ESC_TID")"
# THE ANTI-OVERREACH FOR THIS CLASS NOW LIVES AT THE TRACKER (6.8d above), which
# is the entry point that still takes a spelling nobody derived: a `..` after a
# symlink that lands back INSIDE the directory must still record. At --file the
# same spelling is refused, and that is the POINT of round 5 rather than an
# overreach — the argument may only assert the derivation, so the two legs
# together say "the predicate is not banning the class; the argument is not
# carrying it".
printf '%s\n' "$H_ART" > "$TRACKING"
assert_eq "6.9e --file: the INSIDE hop is refused too — the argument asserts, it does not resolve" \
    "artifact_path_not_derived" \
    "$(json_field '.error_key' "$(bash "$QG" design-record "$HOSTILE_TID" --file "$FIXTURE/docs/specs/in-dir/../$HOSTILE_TID.md" 2>&1)")"
assert_eq "6.9f CONTROL: ...while the SAME spelling in the TRACKER still records (6.8d's pair)" \
    "recorded" \
    "$(json_field '.status' "$(hostile_tracker "$FIXTURE/docs/specs/in-dir/../$HOSTILE_TID.md")")"

# --- THE BRACKET COVERS CONTENT; NOW IT COVERS CONTAINMENT TOO (R3-F4) -----
# The round-2 bracket hashes before and after the validator, so a CONTENT swap
# in that window is refused. Containment was checked ONCE, before it. Replace
# the leaf with a symlink to a BYTE-IDENTICAL file outside the declared
# directory inside that window and both hashes agree, so the record is written
# over bytes never established as the declared directory's.
#
# Delivered by the same shim idiom as 6.6 — installed AT THE VALIDATOR'S PATH,
# with qa-gate.sh unmodified, so the write lands exactly in the window the
# finding names. IDENTICAL BYTES is the load-bearing part: it is what stops the
# content bracket from being what refuses this, which is what makes these legs
# a test of containment rather than a second test of 6.6.
CSWAP_TID=$(bd create "D1 containment-window swap" -t task -p 1 --json 2>/dev/null | jq -r '.id')
CSWAP_ART="$FIXTURE/docs/specs/$CSWAP_TID.md"
write_artifact "$CSWAP_ART" "$CSWAP_TID"
CSWAP_OUTSIDE="$FIXTURE/outside/cswap-$CSWAP_TID.md"
cp "$CSWAP_ART" "$CSWAP_OUTSIDE"
cp "$CSWAP_ART" "$FIXTURE/docs/specs/cswap-inside-$CSWAP_TID.md"
CSWAP_SHA=$(sha256_of_file "$CSWAP_ART")
printf '%s\n' "$CSWAP_ART" > "$TRACKING"
cp "$RC" "$FIXTURE/.claude/scripts/review-check.real.sh"
install_relink_shim() {        # $1 = link target for the leaf, empty = control
    cat > "$RC" <<SHIM
#!/bin/bash
out=\$(bash "$FIXTURE/.claude/scripts/review-check.real.sh" "\$@"); rc=\$?
if [ "\${1:-}" = "validate-design" ] && [ -n "$1" ]; then
    rm -f "$CSWAP_ART"
    ln -sfn "$1" "$CSWAP_ART"
fi
printf '%s\n' "\$out"
exit \$rc
SHIM
    chmod +x "$RC"
}
install_relink_shim "../../outside/cswap-$CSWAP_TID.md"
OUT_CSWAP=$(bash "$QG" design-record "$CSWAP_TID" 2>&1)
assert_eq "6.10 precondition: the shim really relinked the leaf out of the declared dir" "yes" \
    "$([ -L "$CSWAP_ART" ] && echo yes || echo no)"
assert_eq "6.10a precondition: ...and the digest is UNCHANGED by the swap, so no content arm can fire" \
    "$CSWAP_SHA" "$(bash "$WM" hash-file "$CSWAP_ART" 2>/dev/null)"
assert_eq "6.10b the record is REFUSED when CONTAINMENT moves during it (R3-F4)" \
    "design_artifact_changed_during_record" "$(json_field '.error_key' "$OUT_CSWAP")"
assert_eq "6.10c ...and NOTHING is recorded over bytes never shown to be the declared dir's" "" \
    "$(latest_design_record "$CSWAP_TID")"
# CONTROL 1: the same shim relinking to a byte-identical file that is STILL
# INSIDE the declared directory. A fix that refused every mid-record relink —
# or every symlinked leaf — would pass 6.10b and fail this.
rm -f "$CSWAP_ART"
write_artifact "$CSWAP_ART" "$CSWAP_TID"
install_relink_shim "cswap-inside-$CSWAP_TID.md"
assert_eq "6.10d CONTROL: a relink that still resolves INSIDE the dir records normally" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$CSWAP_TID" 2>&1)")"
# CONTROL 2: the identical shim with NO swap, so 6.10b is caused by the relink
# and not by the shim being in the path.
rm -f "$CSWAP_ART"
write_artifact "$CSWAP_ART" "$CSWAP_TID"
install_relink_shim ""
assert_eq "6.10e CONTROL: the same shim with no swap at all records normally" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$CSWAP_TID" 2>&1)")"
cp "$FIXTURE/.claude/scripts/review-check.real.sh" "$RC"
rm -f "$FIXTURE/.claude/scripts/review-check.real.sh"
assert_eq "6.10f CONTROL: the real validator is restored (section 7 uses it)" "true" \
    "$(json_field '.ok' "$(bash "$RC" validate-design "$CSWAP_ART" 2>/dev/null)")"

# --- THE ENTRY IS CLASSIFIED AS AN ENTRY, NOT AS ITS TARGET (R6-F1) --------
# Round 5 replaced two containment predicates with one, and it was right to:
# the round-2 pair answered LEXICALLY on one side and PHYSICALLY on the other,
# which is not a style difference but a hole. Round 6 found that the collapse had
# given BOTH callers the RECORD caller's answer, and the two callers do not ask
# the same question. `design-record` asks "are the BYTES here the artifact?" and
# MUST follow a leaf symlink — that is R2-F2, driven at 6.3b. The tracker scan
# asks "is this ENTRY the one file this design may touch?" and must NOT: the
# entry names a location, and following it classifies a source path by its
# target.
#
# THREE MEASURED INSTANCES OF ONE DEFECT, each returning foreign_n=0 against the
# round-5 bytes. Only the first needs a symlink. The other two need nothing but
# `Write`, which is the single writing tool designer.md grants — which is why
# (a) sets the severity rather than the symlink case.
OTHER_TID=$(bd create "D1 another task's design" -t task -p 1 --json 2>/dev/null | jq -r '.id')
OTHER_ART="$FIXTURE/docs/specs/$OTHER_TID.md"
write_artifact "$OTHER_ART" "$OTHER_TID"
printf 'notes about the design, not a design\n' > "$FIXTURE/docs/specs/notes.txt"
mkdir -p "$FIXTURE/src"
ln -sfn "../docs/specs/$HOSTILE_TID.md" "$FIXTURE/src/runtime"
assert_eq "6.11 precondition: another task's artifact really is a second, VALID design sitting in the declared directory" \
    "true" "$(json_field '.ok' "$(bash "$RC" validate-design "$OTHER_ART" 2>/dev/null)")"
assert_eq "6.11a TRACKER: ANOTHER TASK'S design artifact is FOREIGN — one task, one file (R6-F1)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$OTHER_ART")")"
assert_eq "6.11b TRACKER: any other file in the declared directory is FOREIGN too" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/notes.txt")")"
assert_eq "6.11c precondition: the source-tree symlink really resolves to THIS task's artifact" \
    "$(sha256_of_file "$H_ART")" "$(bash "$WM" hash-file "$FIXTURE/src/runtime" 2>/dev/null)"
assert_eq "6.11d TRACKER: a SOURCE path that POINTS AT the artifact is FOREIGN — the leaf is not followed" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/src/runtime")")"
assert_contains "6.11e ...and the refusal NAMES the source path, so the operator sees what was written" \
    "src/runtime" \
    "$(json_field '.observations' "$(hostile_tracker "$FIXTURE/src/runtime")")"
# CONTROL: the name arm is a NAME test, not a ban on the directory. Without it,
# "call every entry foreign" would satisfy 6.11a/b/d.
printf '%s\n' "$H_ART" > "$TRACKING"
assert_eq "6.11f CONTROL: the task's own artifact, at the derived name, still records" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$HOSTILE_TID" 2>&1)")"

# --- THE DIRECTORY ARM, WITH THE NAME ARM NEUTRALISED ----------------------
# THIS BLOCK EXISTS BECAUSE OF WHAT THE ROUND-6 FIX DOES TO THE LEGS ABOVE IT.
# Every historical refusal in this section names a hostile path something like
# `pwn.sh`, and after the split a name that is not `<tid>.md` is refused by the
# NAME arm before its directory is ever interesting. So 6.1, 6.1b, 6.1d, 6.2d,
# 6.8b and 6.8c — the legs written to prove the DIRECTORY walk is physical —
# would now pass against a build with no directory arm at all. Each claim is
# therefore re-driven here under the artifact's OWN name, where only the
# directory arm can refuse it: R2-F1's `..`, the maxdepth-1 rule, R4-F1's `..`
# after a directory symlink, and the symlinked root.
write_artifact "$FIXTURE/outside/$HOSTILE_TID.md" "$HOSTILE_TID"
assert_eq "6.12 precondition: the artifact's own NAME names a DIFFERENT FILE outside the declared directory, so only location separates them" \
    "yes" \
    "$([ -f "$FIXTURE/outside/$HOSTILE_TID.md" ] \
        && [ ! "$FIXTURE/outside/$HOSTILE_TID.md" -ef "$H_ART" ] \
        && [ "${H_ART##*/}" = "$HOSTILE_TID.md" ] && echo yes || echo no)"
assert_eq "6.12a TRACKER: a '..' traversal carrying the artifact's own name is FOREIGN (R2-F1, directory arm alone)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/../../outside/$HOSTILE_TID.md")")"
assert_eq "6.12b TRACKER: a NESTED path carrying the artifact's own name is FOREIGN (maxdepth 1, directory arm alone)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/sub/$HOSTILE_TID.md")")"
assert_eq "6.12c TRACKER: a '..' after a DIRECTORY symlink carrying the artifact's own name is FOREIGN (R4-F1, directory arm alone)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/esc-dir/../$HOSTILE_TID.md")")"
assert_eq "6.12d TRACKER: the SYMLINKED ROOT does not launder the artifact's own name either (directory arm alone)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$ROOT_ALIAS/outside/$HOSTILE_TID.md")")"
# CONTROL, in 6.12d's own spelling class: through the SAME alias, the artifact's
# real location still records. A directory arm that refused every aliased path
# would pass 6.12d and fail this.
printf '%s\n' "$ROOT_ALIAS/docs/specs/$HOSTILE_TID.md" > "$TRACKING"
assert_eq "6.12e CONTROL: through the same alias, the artifact's REAL location still records" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$HOSTILE_TID" 2>&1)")"

# ===========================================================================
printf '\n=== Section 7: the binding reader is ANCHORED, not a substring ===\n'
# ===========================================================================
#
# R2-F6. The token itself is sound — the WRITER emits a design_hash only after a
# live re-hash agrees with the record, and latest_design_artifact_hash reads the
# record with a `^`-anchored jq capture behind a startswith() filter. The hazard
# is on the READ side, in the case where the token is legitimately WITHHELD: the
# approval's summary is unvalidated positional text on the SAME line, so an
# unanchored reader picks a forged `design_hash=` out of it and reports a binding
# where the gate deliberately wrote none. The spec's own helper had that shape;
# D6 is the phase that reads this token for real, and this section is what stops
# it inheriting the wrong one.

FORGED="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
# The unanchored spelling, kept intact so the two are MEASURED against the same
# records rather than argued about.
read_design_binding_unanchored() {
    printf '%s' "$1" | grep -oE 'design_hash=[A-Za-z0-9-]+' | head -1 | cut -d= -f2-
}

# 7.1 — a REAL binding whose SUMMARY carries a forged token. Written through the
# real writers: design-record's summary is free text, which is precisely the
# space the finding is about.
FORGE_TID=$(bd create "D1 forged-summary subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
FORGE_ART="$FIXTURE/docs/specs/$FORGE_TID.md"
write_artifact "$FORGE_ART" "$FORGE_TID"
# ORDER MATTERS AND IT COST A DEBUGGING ROUND: `enter` RECONCILES the tracker,
# appending every git-visible path not already in the gate baseline — and `bd
# init` makes the fixture a git repo, so each earlier section's leftovers
# (control-agent.md, the outside/ tree) arrive as untracked entries the moment a
# later enter runs. design-record then sees them as foreign paths and refuses,
# correctly. So the record is taken FIRST, over a tracker written immediately
# before it, and its status is ASSERTED rather than redirected to /dev/null —
# which is how the refusal hid the first time.
printf '%s\n' "$FORGE_ART" > "$TRACKING"
FORGE_REC_OUT=$(bash "$QG" design-record "$FORGE_TID" "superseding an earlier design_hash=$FORGED" 2>&1)
assert_eq "7.0 precondition: the design record with a forged token in its SUMMARY was written" \
    "recorded" "$(json_field '.status' "$FORGE_REC_OUT")"
FORGE_REAL=$(sha256_of_file "$FORGE_ART")
bash "$QG" enter "$FORGE_TID" >/dev/null 2>&1
seed_approvable "$FORGE_TID"
bash "$QG" approve "$FORGE_TID" --no-design "fkm.4: testing the anchored reader, not design-satisfied" "D1 anchored-reader leg" >/dev/null 2>&1
FORGE_APPROVAL=$(latest_approval "$FORGE_TID")
assert_contains "7.1 precondition: the forged token really is in the record's free text" \
    "design_hash=$FORGED" "$(latest_design_record "$FORGE_TID")"
assert_eq "7.1b the SHIPPED writer bound the artifact's real digest, not the forged one" \
    "$FORGE_REAL" "$(read_design_binding "$FORGE_APPROVAL")"
assert_eq "7.1c ...and the forged value never reaches the approval's machine token" "no" \
    "$([ "$(read_design_binding "$FORGE_APPROVAL")" = "$FORGED" ] && echo yes || echo no)"

# 7.2 — the case that separates the two readers: NO legitimate token, a forged
# one in the summary, and — in the same comment stream — a PROSE mention of the
# whole record grammar, which the startswith() filter must also refuse.
NOBIND_TID=$(bd create "D1 unbound-with-forgery subject" -t task -p 1 --json 2>/dev/null | jq -r '.id')
printf '%s\n' "$FIXTURE/docs/specs/valid-design.md" > "$TRACKING"
bash "$QG" enter "$NOBIND_TID" >/dev/null 2>&1
PROSE_MENTION="for reference we wrote DESIGN-ARTIFACT v1 task=$NOBIND_TID designer=designer design_hash=$FORGED units=1 at 2026-01-01T00:00:00Z: quoted, not recorded"
bd comments add "$NOBIND_TID" "$PROSE_MENTION" >/dev/null 2>&1 \
    || bd comment add "$NOBIND_TID" "$PROSE_MENTION" >/dev/null 2>&1 || true
seed_approvable "$NOBIND_TID"
NOBIND_OUT=$(bash "$QG" approve "$NOBIND_TID" --no-design "fkm.4: testing the anchored reader, not design-satisfied" "D1 forged summary design_hash=$FORGED" 2>&1)
NOBIND_APPROVAL=$(latest_approval "$NOBIND_TID")
assert_contains "7.2 precondition: the approval line really does carry the forged token in its summary" \
    "design_hash=$FORGED" "$NOBIND_APPROVAL"
assert_contains "7.2b the PROSE mention of the grammar was not read as a record" \
    "no design binding (no DESIGN-ARTIFACT record" "$(json_field '.observations' "$NOBIND_OUT")"
assert_eq "7.2c CONTROL: the UNANCHORED reader — the shape D6 must not copy — returns the FORGERY" \
    "$FORGED" "$(read_design_binding_unanchored "$NOBIND_APPROVAL")"
assert_eq "7.2d ...while the anchored reader reports UNBOUND, which is what the gate wrote" "" \
    "$(read_design_binding "$NOBIND_APPROVAL")"

# ===========================================================================
printf '\n=== Section 8: the header states what the predicate ACTUALLY resolves ===\n'
# ===========================================================================
#
# R3-F3 / R4-F6 / R4-F7 / R5-F4. The round-2 header claimed "INTERMEDIATE
# symlinks and every `..` segment are resolved by `pwd -P`". That sentence was
# measurably false in TWO ways, and the first is what shipped the hole: `pwd -P`
# reports where a `cd` landed, so it cannot undo a `..` the `cd` already ate, and
# bash's default `cd` eats them lexically. A reader who believed the sentence
# would see no reason to add `-P`.
#
# The second was carried for one round as a stated BOUNDARY — `target=$(readlink
# "$p")` strips a TRAILING NEWLINE from a symlink's target, so a link pointing at
# `alias\n` was examined as `alias`. Round 5 closed it instead (`[ -ef ]`, see
# section 9), so the statement had to go with it: a disclaimer that no longer
# matches the code is worse than none, in either direction.
#
# THESE LEGS ARE ABOUT THE SHIPPED FILE, not the fixture copy: the claim a
# maintainer reads is the one in the repo.
SHIPPED_QG="$PLUGIN_DIR/.claude/scripts/qa-gate.sh"
DESIGN_REGION=$(awk '/^# DESIGN-ARTIFACT BEGIN \(v5 Phase D1/,/^# DESIGN-ARTIFACT END \(v5 Phase D1/' "$SHIPPED_QG")
# THE PROSE HALF AND THE CODE HALF, SEPARATED. Without the split, "the header
# mentions cd -P" would be satisfied by the `cd -P` CALLS in the region and could
# not fail while the code was right and the comment was wrong — the exact defect
# this section exists to catch. R5-F4: the CODE-shape legs need the mirror image
# for the same reason, or a prose line quoting an idiom satisfies an assertion
# about the code that uses it.
DESIGN_REGION_PROSE=$(printf '%s\n' "$DESIGN_REGION" | grep -E '^[[:space:]]*#')
DESIGN_REGION_CODE=$(printf '%s\n' "$DESIGN_REGION" | grep -vE '^[[:space:]]*#')
assert_eq "8.0 precondition: the D1 region really was extracted (both sentinels present)" "yes" \
    "$([ "$(printf '%s\n' "$DESIGN_REGION" | grep -c .)" -gt 100 ] && echo yes || echo no)"
assert_eq "8.0b precondition: ...and its PROSE half is separable from its code" "yes" \
    "$([ "$(printf '%s\n' "$DESIGN_REGION_PROSE" | grep -c .)" -gt 50 ] && echo yes || echo no)"
assert_eq "8.0c precondition: ...and its CODE half is separable from its prose" "yes" \
    "$([ "$(printf '%s\n' "$DESIGN_REGION_CODE" | grep -c .)" -gt 30 ] && echo yes || echo no)"
# shellcheck disable=SC2016  # the LITERAL text of the deleted claim, backticks included.
assert_eq "8.1 the FALSE claim is GONE — it was REPLACED, not annotated" "0" \
    "$(grep -cF 'resolved by `pwd -P`' "$SHIPPED_QG" | tr -d ' \n')"
assert_eq "8.2 ...and the PROSE names the mechanism that does the resolving" "yes" \
    "$(printf '%s\n' "$DESIGN_REGION_PROSE" | grep -qF 'cd -P' && echo yes || echo no)"
assert_eq "8.2b ...and says why the default is not enough (bash cd is LOGICAL)" "yes" \
    "$(printf '%s\n' "$DESIGN_REGION_PROSE" | grep -q 'LOGICAL' && echo yes || echo no)"
assert_eq "8.3 the newline case is still stated where the claim it bounds lives" "yes" \
    "$(printf '%s\n' "$DESIGN_REGION_PROSE" | grep -qi 'newline' && echo yes || echo no)"
# NEEDLE CHOSEN BY MUTATION, not by taste: `-ef` alone stayed green when the
# whole closure paragraph was deleted, because a second bullet mentions the flag
# in passing. `device+inode` is what the paragraph SAYS, and nothing else in the
# region says it — so removing the paragraph reddens this leg, which is the only
# reason to have it.
assert_eq "8.3b ...and it is stated as CLOSED, naming the primitive and what it compares" "yes" \
    "$(printf '%s\n' "$DESIGN_REGION_PROSE" | grep -qF 'device+inode' && echo yes || echo no)"
# shellcheck disable=SC2016  # the literal words of the disclaimer that was retired.
assert_eq "8.3c ...and the retired DISCLAIMER is gone, not left beside the fix" "0" \
    "$(printf '%s\n' "$DESIGN_REGION_PROSE" | grep -cF 'DISCLOSED rather than half-closed' | tr -d ' \n')"
# THE CODE AGREES WITH THE TEXT. A comment claiming physical resolution beside a
# logical `cd` is the defect this section exists for, so the two are asserted
# together: every physical-resolution site in the region carries `-P`, and none
# is left in the logical spelling. Measured over the CODE half only (R5-F4) — the
# prose names `cd -P` repeatedly, so counting the whole region let a comment
# stand in for a call.
assert_eq "8.4 all three physical-resolution sites in the region's CODE use cd -P" "3" \
    "$(printf '%s\n' "$DESIGN_REGION_CODE" | grep -c 'cd -P ' | tr -d ' \n')"
assert_eq "8.4b ...and NO logical 'cd \"' is left in the region's CODE" "0" \
    "$(printf '%s\n' "$DESIGN_REGION_CODE" | grep -cE 'cd "' | tr -d ' \n')"
# THE CLASS, ASSERTED STRUCTURALLY (R5-F1/F2/F3). Five rounds of findings had one
# root: a PATHNAME crossed a COMMAND SUBSTITUTION, which strips every trailing
# newline and cannot tell a command's output terminator from a filename's last
# byte. Section 9 drives the behaviour; these three legs stop the SPELLING coming
# back — including at the caller, which is where a byte-preserving walk gets
# truncated one frame later if the predicate returns a path instead of an answer.
# shellcheck disable=SC2016  # the needles ARE the literal idiom; expansion would defeat them.
assert_eq "8.6 no \$(dirname …) survives in the region's CODE" "0" \
    "$(printf '%s\n' "$DESIGN_REGION_CODE" | grep -cF '$(dirname' | tr -d ' \n')"
# shellcheck disable=SC2016
assert_eq "8.6b no \$(basename …) survives in the region's CODE" "0" \
    "$(printf '%s\n' "$DESIGN_REGION_CODE" | grep -cF '$(basename' | tr -d ' \n')"
# 8.6c WAS STRENGTHENED IN ROUND 6, not merely widened to fit new names. The old
# needle named two predicates by prefix, so a THIRD one captured by a caller
# would have satisfied it — and round 6 adds two functions. It now counts EVERY
# `$(design_…` capture in the region's code and subtracts the two the header
# names as safe: the derivation (its format string ends in a literal `d`, so no
# byte can be eaten) and the foreign LIST (line-delimited, counted and printed,
# never opened). A new predicate captured by a caller reds this without anyone
# remembering to extend a pattern.
# shellcheck disable=SC2016  # the needles ARE the literal idiom.
assert_eq "8.6c no caller CAPTURES an answer from a design predicate as a string" "0" \
    "$(printf '%s\n' "$DESIGN_REGION_CODE" | grep -oE '\$\(design_[a-z_]+' \
        | grep -vxF '$(design_artifact_path_for' | grep -vxF '$(design_foreign_paths' \
        | grep -c . | tr -d ' \n')"
# shellcheck disable=SC2016
assert_eq "8.6d CONTROL: the region's code is non-trivial, so 8.6/8.6b/8.6c are not vacuous" "yes" \
    "$([ "$(printf '%s\n' "$DESIGN_REGION_CODE" | grep -c '\$(')" -gt 5 ] && echo yes || echo no)"
# shellcheck disable=SC2016
assert_eq "8.6e CONTROL: both subtracted exceptions really are present, so 8.6c is not subtracting an empty set" "2" \
    "$(printf '%s\n' "$DESIGN_REGION_CODE" | grep -oE '\$\(design_[a-z_]+' \
        | grep -cE '^\$\(design_(artifact_path_for|foreign_paths)$' | tr -d ' \n')"
assert_eq "8.7 the PROSE says WHY the round-trips are gone (command substitution)" "yes" \
    "$(printf '%s\n' "$DESIGN_REGION_PROSE" | grep -qi 'command substitution' && echo yes || echo no)"

# THE TWO QUESTIONS, ASSERTED STRUCTURALLY (R6-F1). The round-5 unification gave
# both callers the RECORD caller's answer; the round-6 split is ONE STATEMENT
# apart from that, which makes it exactly the kind of change a later reader
# "restores" while tidying. These legs make the restoration red, and 8.8c is the
# control that stops them being read as a ban on following leaves at all — the
# record side must keep doing it or R2-F2 reopens.
DESIGN_FOREIGN_BODY=$(printf '%s\n' "$DESIGN_REGION" | awk '/^design_foreign_paths\(\)/,/^}/')
DESIGN_ENTRY_BODY=$(printf '%s\n' "$DESIGN_REGION" | awk '/^design_entry_is_artifact\(\)/,/^}/')
DESIGN_CONTAINED_BODY=$(printf '%s\n' "$DESIGN_REGION" | awk '/^design_path_is_contained\(\)/,/^}/')
assert_eq "8.8 precondition: all three function bodies were extracted from the shipped region" "yes" \
    "$([ "$(printf '%s\n' "$DESIGN_FOREIGN_BODY" | grep -c .)" -gt 5 ] \
        && [ "$(printf '%s\n' "$DESIGN_ENTRY_BODY" | grep -c .)" -gt 3 ] \
        && [ "$(printf '%s\n' "$DESIGN_CONTAINED_BODY" | grep -c .)" -gt 10 ] && echo yes || echo no)"
assert_eq "8.8a the TRACKER caller does not use the leaf-FOLLOWING predicate (R6-F1)" "0" \
    "$(printf '%s\n' "$DESIGN_FOREIGN_BODY" | grep -c 'design_path_is_contained' | tr -d ' \n')"
assert_eq "8.8b ...and the ENTRY predicate never reads a link target at all" "0" \
    "$(printf '%s\n' "$DESIGN_ENTRY_BODY" | grep -c 'readlink' | tr -d ' \n')"
assert_eq "8.8c CONTROL: the RECORD predicate DOES read one — 8.8b is a split, not a ban (R2-F2 stays closed)" "1" \
    "$(printf '%s\n' "$DESIGN_CONTAINED_BODY" | grep -c 'readlink' | tr -d ' \n')"
assert_eq "8.8d ...and BOTH questions resolve their directory through the ONE shared core, so neither can drift" "2" \
    "$(printf '%s\n%s\n' "$DESIGN_ENTRY_BODY" "$DESIGN_CONTAINED_BODY" \
        | grep -c 'design_dir_is_spec_dir' | tr -d ' \n')"
assert_eq "8.9 the PROSE states the tracker's question is about the ENTRY, not its target" "yes" \
    "$(printf '%s\n' "$DESIGN_REGION_PROSE" | grep -qF 'THE LEAF MUST NOT BE FOLLOWED' && echo yes || echo no)"
assert_eq "8.9b ...and says this is NOT the round-2 pair restored, so the split is not read as a regression" "yes" \
    "$(printf '%s\n' "$DESIGN_REGION_PROSE" | grep -qF 'NOT THE ROUND-2 SHAPE RESTORED' && echo yes || echo no)"
# THE CHANGELOG CARRIES THE ONLY OTHER COPY of this claim, and it is the copy a
# maintainer reads first. docs/HOOKS.md does NOT repeat it — it documents the
# DECLARATION rather than the predicate; `grep -n 'pwd -P' docs/HOOKS.md` hits
# post-edit.sh's 94d rule and worktree-sweep.sh and nothing else. The window is
# extracted by TEXT anchors, never by line number.
CL_CONTAINMENT=$(awk '/\*\*Both checks answer containment through ONE physical predicate\*\*/,/^  - \*\*/' \
    "$PLUGIN_DIR/CHANGELOG.md")
assert_eq "8.5 precondition: the CHANGELOG's containment paragraph was located by its anchor" "yes" \
    "$([ "$(printf '%s\n' "$CL_CONTAINMENT" | grep -c .)" -gt 5 ] && echo yes || echo no)"
assert_eq "8.5b the CHANGELOG's copy names the same mechanism the code uses" "yes" \
    "$(printf '%s\n' "$CL_CONTAINMENT" | grep -qF 'cd -P' && echo yes || echo no)"
assert_eq "8.5c ...and reaches the same verdict on the newline case, so the two copies cannot drift" "yes" \
    "$(printf '%s\n' "$CL_CONTAINMENT" | grep -qi 'newline' && echo yes || echo no)"
assert_eq "8.5d ...naming -ef, the primitive that closed it, rather than disclosing it as a residual" "yes" \
    "$(printf '%s\n' "$CL_CONTAINMENT" | grep -qF -- '-ef' && echo yes || echo no)"
assert_eq "8.5e ...and records the round-6 SPLIT, so the CHANGELOG cannot go on claiming one answer for two questions" "yes" \
    "$(printf '%s\n' "$CL_CONTAINMENT" | grep -qF 'classified as an ENTRY, not as its target' && echo yes || echo no)"

# ===========================================================================
printf '\n=== Section 9: a bash string operation is not a path operation ===\n'
# ===========================================================================
#
# THE CLASS, not its latest spelling. Rounds 2, 3, 4 and 5 each found a hole in
# this one region, each fixed the spelling that was reported, and each was
# followed by another. Round 5 named the root: a PATHNAME was round-tripped
# through a COMMAND SUBSTITUTION. `$( )` strips EVERY trailing newline, and it
# cannot distinguish a newline that terminates a command's output from a newline
# that is the last byte of a filename. The region had it six times over
# `$(dirname …)` and `$(basename …)`, once over `$(readlink …)`, and five more
# times at the CALLERS, which captured the predicate's printed answer.
#
# Every leg below was written and OBSERVED RED against the pre-fix bytes, with
# the command in the task report. Each is paired with a control in the same
# spelling class, because "refuse anything with a symlink or an odd byte in it"
# would satisfy the refusals and none of the controls.
#
# THE FOUR SHAPES, all measured against the shipped predicate first:
#   9.1  R3-F3 — a link whose TARGET is NAMED with a trailing newline. `readlink`
#        reads it back one byte short, so the walk inspected `alias` while the
#        kernel opened `alias\n`. Closed by `[ -ef ]`, not by a byte-preserving
#        reader (there is no portable one).
#   9.2  R5-F1 — a component of the path itself named with a trailing newline,
#        arriving through `--file`. Closed by deleting the input.
#   9.3  R5-F2 — a SECOND file inside the declared directory named `<tid>.md\n`,
#        which `basename` reads back as `<tid>.md`. Closed by the same deletion.
#   9.4  the route that SURVIVES the deletion, and the one nobody reported: a
#        symlink whose target contains an INTERNAL newline, which `$(readlink …)`
#        keeps. Round 6 moved it from the TRACKER to the RECORD caller, because
#        the tracker stopped reading targets when the two questions were split
#        (R6-F1) and the record side is now the only caller a link can hand a
#        newline-named directory to. Both variants are driven: the newline-named
#        sibling as a SYMLINK (reads outside the tree) and as a REAL DIRECTORY
#        (the case that also proves the answer is not truncated at the caller).
#   9.5  the case round 5 claimed could not be built: a HARDLINK defeats `-ef`,
#        so the IN-LOOP dirname has a behavioural consequence after all.

NL=$(printf '\nX'); NL="${NL%X}"
assert_eq "9.0 precondition: the harness can spell a trailing newline at all" "1" "${#NL}"

# --- 9.1  THE LINK WHOSE TARGET IS NAMED WITH A TRAILING NEWLINE (R3-F3) ----
# Reached through the DERIVED path, so it survives the --file deletion: the
# artifact IS docs/specs/<tid>.md, and it is a symlink to `alias\n`, while an
# innocuous `alias` sits beside it. Pre-fix, `readlink` returned `alias`, the
# walk resolved THAT, reported the declared directory, and hash-file — following
# the real chain — bound the OUTSIDE decoy's bytes.
NLT_TID=$(bd create "D1 newline-named symlink target" -t task -p 1 --json 2>/dev/null | jq -r '.id')
NLT_ART="$FIXTURE/docs/specs/$NLT_TID.md"
NLT_DECOY="$FIXTURE/outside/decoy-$NLT_TID.md"
write_artifact "$NLT_DECOY" "$NLT_TID"
NLT_DECOY_SHA=$(sha256_of_file "$NLT_DECOY")
printf 'innocuous\n' > "$FIXTURE/docs/specs/alias-$NLT_TID"
ln -sfn "../../outside/decoy-$NLT_TID.md" "$FIXTURE/docs/specs/alias-$NLT_TID$NL"
ln -sfn "alias-$NLT_TID$NL" "$NLT_ART"
printf '%s\n' "$NLT_ART" > "$TRACKING"
assert_eq "9.1 precondition: the kernel opens the OUTSIDE decoy through the derived path" \
    "$NLT_DECOY_SHA" "$(bash "$WM" hash-file "$NLT_ART" 2>/dev/null)"
assert_eq "9.1a precondition: ...and readlink really reads the target one byte short" "yes" \
    "$([ "$(readlink "$NLT_ART")" = "alias-$NLT_TID" ] && echo yes || echo no)"
assert_eq "9.1b precondition: ...and the decoy is a VALID design for THIS task, so only containment can refuse it" \
    "true" "$(json_field '.ok' "$(bash "$RC" validate-design "$NLT_ART" 2>/dev/null)")"
OUT_NLT=$(bash "$QG" design-record "$NLT_TID" 2>&1)
assert_eq "9.1c the record is REFUSED: the reconstructed target is a different file (R3-F3)" \
    "artifact_outside_spec_dir" "$(json_field '.error_key' "$OUT_NLT")"
assert_not_contains "9.1d ...and the outside decoy's digest reaches NO record" \
    "$NLT_DECOY_SHA" "$(latest_design_record "$NLT_TID")"
assert_eq "9.1e ...so the task carries no DESIGN-ARTIFACT record at all" "" \
    "$(latest_design_record "$NLT_TID")"
# CONTROL: an HONEST relative link, same shape, target inside the directory. The
# -ef check must not refuse a link merely for being one.
HL_TID=$(bd create "D1 honest relative link" -t task -p 1 --json 2>/dev/null | jq -r '.id')
write_artifact "$FIXTURE/docs/specs/real-$HL_TID.md" "$HL_TID"
ln -sfn "real-$HL_TID.md" "$FIXTURE/docs/specs/$HL_TID.md"
printf '%s\n' "$FIXTURE/docs/specs/$HL_TID.md" > "$TRACKING"
assert_eq "9.1f CONTROL: an honest relative symlink INSIDE the directory still records" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$HL_TID" 2>&1)")"
# THE VERDICT THAT CHANGED, pinned because it changed: a DANGLING link inside the
# declared directory used to resolve to the directory (its dirname exists) and
# read as contained. It cannot be shown to be the artifact, so it is foreign now
# — the same fail-closed direction as the bare directory entry at 6.1f. Note the
# DECLARATION (workflow-manifest.sh) still declares a dangling link, deliberately:
# "governed by the veto" and "provably the artifact" are different questions.
#
# WHICH ARM ANSWERS IT MOVED IN ROUND 6, and the leg says so rather than keeping
# a reason that stopped being true: at the TRACKER this is now refused by the
# NAME (it is not the derived filename), because the tracker no longer reads a
# target. 9.1h is where the RECORD side answers for a dangling DERIVED path, and
# it answers `artifact_not_found` — `[ ! -f ]` fires before containment is ever
# consulted, which is also why the containment message never has to describe a
# dangling link (R6-F4).
ln -sfn "gone-$HOSTILE_TID.md" "$FIXTURE/docs/specs/dangling-$HOSTILE_TID.md"
assert_eq "9.1g a DANGLING link inside the declared directory is foreign at the TRACKER (by name; verdict changed, fail-closed)" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/dangling-$HOSTILE_TID.md")")"
DNG_TID=$(bd create "D1 dangling derived path" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ln -sfn "gone-$DNG_TID.md" "$FIXTURE/docs/specs/$DNG_TID.md"
printf '%s\n' "$FIXTURE/docs/specs/$DNG_TID.md" > "$TRACKING"
assert_eq "9.1h ...while a dangling DERIVED path is refused at the RECORD side, and by absence rather than by containment" \
    "artifact_not_found" \
    "$(json_field '.error_key' "$(bash "$QG" design-record "$DNG_TID" 2>&1)")"

# --- 9.2  R5-F1: A PATH COMPONENT NAMED WITH A TRAILING NEWLINE ------------
# `docs/specs\n` is a SIBLING of `docs/specs` — a different directory — and here
# it is a symlink out of the tree. Pre-fix, `$(dirname …)` returned
# `…/docs/specs` because command substitution ate the pathname's own last byte,
# both containment checks agreed, and the record bound the outside decoy.
NLP_TID=$(bd create "D1 newline-named path component" -t task -p 1 --json 2>/dev/null | jq -r '.id')
ln -sfn "$FIXTURE/outside" "$FIXTURE/docs/specs$NL"
NLP_DECOY="$FIXTURE/outside/$NLP_TID.md"
write_artifact "$NLP_DECOY" "$NLP_TID"
NLP_DECOY_SHA=$(sha256_of_file "$NLP_DECOY")
NLP_SPELLING="$FIXTURE/docs/specs$NL/$NLP_TID.md"
write_artifact "$FIXTURE/docs/specs/$NLP_TID.md" "$NLP_TID"
printf '\n<!-- the REAL one, different bytes -->\n' >> "$FIXTURE/docs/specs/$NLP_TID.md"
NLP_REAL_SHA=$(sha256_of_file "$FIXTURE/docs/specs/$NLP_TID.md")
printf '%s\n' "$FIXTURE/docs/specs/$NLP_TID.md" > "$TRACKING"
assert_eq "9.2 precondition: the newline spelling opens the OUTSIDE decoy, not the real artifact" \
    "$NLP_DECOY_SHA" "$(bash "$WM" hash-file "$NLP_SPELLING" 2>/dev/null)"
assert_eq "9.2a precondition: ...and the two really are different bytes" "differ" \
    "$([ "$NLP_DECOY_SHA" != "$NLP_REAL_SHA" ] && echo differ || echo same)"
assert_eq "9.2b precondition: ...and the decoy is a VALID design for THIS task" "true" \
    "$(json_field '.ok' "$(bash "$RC" validate-design "$NLP_SPELLING" 2>/dev/null)")"
OUT_NLP=$(bash "$QG" design-record "$NLP_TID" --file "$NLP_SPELLING" 2>&1)
assert_eq "9.2c --file cannot carry a path this task did not derive (R5-F1)" \
    "artifact_path_not_derived" "$(json_field '.error_key' "$OUT_NLP")"
assert_not_contains "9.2d ...and the outside decoy's digest reaches NO record" \
    "$NLP_DECOY_SHA" "$(latest_design_record "$NLP_TID")"
# CONTROL: the derived path, same task, same directory — records, and binds the
# REAL artifact's bytes. The refusal above is about the value, not about --file.
assert_eq "9.2e CONTROL: --file with the DERIVED path records" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$NLP_TID" --file "$FIXTURE/docs/specs/$NLP_TID.md" 2>&1)")"
assert_eq "9.2f ...binding the real artifact's digest, never the decoy's" "$NLP_REAL_SHA" \
    "$(printf '%s' "$(latest_design_record "$NLP_TID")" | grep -oE 'design_hash=[A-Za-z0-9-]+' | head -1 | cut -d= -f2-)"

# --- 9.3  R5-F2: A SECOND FILE IN THE DIRECTORY NAMED `<tid>.md\n` ---------
# This one passes containment HONESTLY — it really is in the declared directory
# — and defeated the NAME check instead, because `$(basename …)` read `<tid>.md\n`
# back as `<tid>.md`. It is the finding that falsified the soundness premise
# stated two lines below the check: "the record carries the HASH and no path,
# which is only sound while the path is derivable from the task id".
IMP_TID=$(bd create "D1 impostor named for the task" -t task -p 1 --json 2>/dev/null | jq -r '.id')
IMP_REAL="$FIXTURE/docs/specs/$IMP_TID.md"
IMP_FAKE="$FIXTURE/docs/specs/$IMP_TID.md$NL"
write_artifact "$IMP_REAL" "$IMP_TID"
write_artifact "$IMP_FAKE" "$IMP_TID"
printf '\n<!-- impostor -->\n' >> "$IMP_FAKE"
IMP_REAL_SHA=$(sha256_of_file "$IMP_REAL")
IMP_FAKE_SHA=$(sha256_of_file "$IMP_FAKE")
printf '%s\n' "$IMP_REAL" > "$TRACKING"
assert_eq "9.3 precondition: the impostor is a SECOND, different file inside the declared directory" "differ" \
    "$([ "$IMP_REAL_SHA" != "$IMP_FAKE_SHA" ] && echo differ || echo same)"
assert_eq "9.3a precondition: ...and it is a VALID design for THIS task, so only the name check stood between it and a record" \
    "true" "$(json_field '.ok' "$(bash "$RC" validate-design "$IMP_FAKE" 2>/dev/null)")"
OUT_IMP=$(bash "$QG" design-record "$IMP_TID" --file "$IMP_FAKE" 2>&1)
assert_eq "9.3b the impostor cannot be recorded (R5-F2)" "artifact_path_not_derived" \
    "$(json_field '.error_key' "$OUT_IMP")"
assert_not_contains "9.3c ...and its digest reaches NO record" \
    "$IMP_FAKE_SHA" "$(latest_design_record "$IMP_TID")"
assert_eq "9.3d CONTROL: the file the task DOES derive records, binding its own digest" "$IMP_REAL_SHA" \
    "$( bash "$QG" design-record "$IMP_TID" >/dev/null 2>&1
        printf '%s' "$(latest_design_record "$IMP_TID")" | grep -oE 'design_hash=[A-Za-z0-9-]+' | head -1 | cut -d= -f2- )"

# --- 9.4  THE INTERNAL NEWLINE, AT THE CALLER THAT STILL FOLLOWS A TARGET ---
# ROUND 6 MOVED THIS CLASS, and the move is the point rather than a relocation.
# It used to be driven through the TRACKER, on the reasoning that a tracker line
# cannot itself contain a newline (changed-files.txt is line-delimited, so the
# byte would split the entry in two) while a symlink TARGET can, and an INTERNAL
# newline survives `$(readlink …)` intact. R6-F1 split the two questions: the
# tracker no longer reads a target at all, so the newline-named directory can
# only be put back in a predicate's hands by the RECORD side — where the
# consequence is the BINDING, which is the worse of the two. The same two
# variants, re-aimed at that caller, plus the tracker-side statement of the
# split at 9.4f.
#
# BOTH VARIANTS, because they fail differently:
#   (a) the sibling is a SYMLINK out of the tree — `cd -P` lands on an outside
#       path, so this one is caught by resolving the dirname faithfully.
#   (b) the sibling is a REAL DIRECTORY — `cd -P` lands on `…/docs/specs\n`, and
#       a predicate that PRINTS that answer has it truncated back to
#       `…/docs/specs` by the caller's own `$( )`. Only an answer that never
#       crosses a command substitution survives (b), which is why the predicates
#       return an exit status.
NLD_TID=$(bd create "D1 newline sibling as a symlink" -t task -p 1 --json 2>/dev/null | jq -r '.id')
NLD_ART="$FIXTURE/docs/specs/$NLD_TID.md"
rm -rf "$FIXTURE/docs/specs$NL"
ln -sfn "$FIXTURE/outside" "$FIXTURE/docs/specs$NL"
NLD_DECOY="$FIXTURE/outside/nld-$NLD_TID.md"
write_artifact "$NLD_DECOY" "$NLD_TID"
NLD_DECOY_SHA=$(sha256_of_file "$NLD_DECOY")
ln -sfn "../specs$NL/nld-$NLD_TID.md" "$NLD_ART"
printf '%s\n' "$NLD_ART" > "$TRACKING"
assert_eq "9.4 precondition: the link's target really carries an INTERNAL newline that readlink keeps" "yes" \
    "$([ "$(readlink "$NLD_ART")" = "../specs$NL/nld-$NLD_TID.md" ] && echo yes || echo no)"
assert_eq "9.4a precondition: ...and the DERIVED path really opens the decoy outside the declared directory" \
    "$NLD_DECOY_SHA" "$(bash "$WM" hash-file "$NLD_ART" 2>/dev/null)"
assert_eq "9.4a2 precondition: ...and that decoy is a VALID design for THIS task, so only containment can refuse it" \
    "true" "$(json_field '.ok' "$(bash "$RC" validate-design "$NLD_ART" 2>/dev/null)")"
OUT_NLD=$(bash "$QG" design-record "$NLD_TID" 2>&1)
assert_eq "9.4b RECORD: a link through a newline-named sibling SYMLINK is refused" \
    "artifact_outside_spec_dir" "$(json_field '.error_key' "$OUT_NLD")"
assert_not_contains "9.4b2 ...and the outside decoy's digest reaches NO record" \
    "$NLD_DECOY_SHA" "$(latest_design_record "$NLD_TID")"
NLD2_TID=$(bd create "D1 newline sibling as a real directory" -t task -p 1 --json 2>/dev/null | jq -r '.id')
NLD2_ART="$FIXTURE/docs/specs/$NLD2_TID.md"
rm -f "$FIXTURE/docs/specs$NL"
mkdir -p "$FIXTURE/docs/specs$NL"
NLD2_DECOY="$FIXTURE/docs/specs$NL/nld2-$NLD2_TID.md"
write_artifact "$NLD2_DECOY" "$NLD2_TID"
NLD2_DECOY_SHA=$(sha256_of_file "$NLD2_DECOY")
ln -sfn "../specs$NL/nld2-$NLD2_TID.md" "$NLD2_ART"
printf '%s\n' "$NLD2_ART" > "$TRACKING"
assert_eq "9.4c precondition: the sibling is now a REAL directory, one byte from the declared one" "yes" \
    "$([ -d "$FIXTURE/docs/specs$NL" ] && [ ! -L "$FIXTURE/docs/specs$NL" ] && echo yes || echo no)"
assert_eq "9.4c2 precondition: ...and the decoy inside it is a VALID design for THIS task" "true" \
    "$(json_field '.ok' "$(bash "$RC" validate-design "$NLD2_ART" 2>/dev/null)")"
OUT_NLD2=$(bash "$QG" design-record "$NLD2_TID" 2>&1)
assert_eq "9.4d RECORD: a link through a newline-named sibling DIRECTORY is refused too" \
    "artifact_outside_spec_dir" "$(json_field '.error_key' "$OUT_NLD2")"
assert_not_contains "9.4d2 ...and that decoy's digest reaches NO record either" \
    "$NLD2_DECOY_SHA" "$(latest_design_record "$NLD2_TID")"
# CONTROL: the identical construction whose target is the DECLARED directory —
# a relative target with a `..` hop, reached through a link, landing inside. A
# record side that refused every link with a `..` in its target would pass
# 9.4b/9.4d and fail this.
INS_TID=$(bd create "D1 dotdot hop landing inside" -t task -p 1 --json 2>/dev/null | jq -r '.id')
write_artifact "$FIXTURE/docs/specs/ins-real-$INS_TID.md" "$INS_TID"
ln -sfn "../specs/ins-real-$INS_TID.md" "$FIXTURE/docs/specs/$INS_TID.md"
printf '%s\n' "$FIXTURE/docs/specs/$INS_TID.md" > "$TRACKING"
assert_eq "9.4e CONTROL: the same construction landing INSIDE the declared directory still records" \
    "recorded" "$(json_field '.status' "$(bash "$QG" design-record "$INS_TID" 2>&1)")"
# THE SPLIT, STATED (R6-F1). The SAME link — inside the declared directory,
# pointing at this task's own artifact — is CONTAINED to the record side, which
# follows it, and FOREIGN to the tracker side, which does not, because the entry
# is a second file in the directory whatever it points at. This is the leg that
# separates the round-6 split from the round-5 unification: under one predicate
# serving both callers it reads NOT foreign, which is how R6-F1 was measured.
ln -sfn "../specs/$HOSTILE_TID.md" "$FIXTURE/docs/specs/inside-link.md"
assert_eq "9.4f TRACKER: a link whose target IS this task's artifact is still FOREIGN under its own name" \
    "designer_touched_source" \
    "$(json_field '.error_key' "$(hostile_tracker "$FIXTURE/docs/specs/inside-link.md")")"
rm -rf "$FIXTURE/docs/specs$NL" "$FIXTURE/docs/specs/inside-link.md"

# --- 9.5  THE HARDLINK THAT DEFEATS `-ef` (fkm.3 QA round 6, R6-F2) --------
# The IN-LOOP dirname is spelled `${p%/*}` for the same reason as the final one,
# and round 5 reported that no BEHAVIOURAL case could be constructed for it
# because `-ef` subsumed the mutation. That reasoning was wrong and QA built the
# counter-example: `-ef` compares device+inode and NOT names, so a HARDLINK is
# precisely the case where a name truncated by `$(dirname …)` still names the
# same file. The guard then passes, the walk continues on the WRONG NAME, and the
# final `cd -P` lands in the wrong directory — inverting foreign to CONTAINED.
# Structural leg 8.6 reddens on that mutation already; this makes the CONSEQUENCE
# observable rather than only the spelling, which is the difference between
# knowing a rule is enforced and knowing what it is worth.
HLK_TID=$(bd create "D1 hardlink defeats -ef" -t task -p 1 --json 2>/dev/null | jq -r '.id')
rm -rf "$FIXTURE/docs/specs$NL"
mkdir -p "$FIXTURE/docs/specs$NL"
write_artifact "$FIXTURE/docs/specs/hlk-$HLK_TID.md" "$HLK_TID"
ln "$FIXTURE/docs/specs/hlk-$HLK_TID.md" "$FIXTURE/docs/specs$NL/hlk-$HLK_TID.md"
ln -sfn "hlk-$HLK_TID.md" "$FIXTURE/docs/specs$NL/hlk-link-$HLK_TID.md"
ln -sfn "../specs$NL/hlk-link-$HLK_TID.md" "$FIXTURE/docs/specs/$HLK_TID.md"
printf '%s\n' "$FIXTURE/docs/specs/$HLK_TID.md" > "$TRACKING"
assert_eq "9.5 precondition: the two names really are ONE inode, which is what defeats -ef" "same" \
    "$([ "$FIXTURE/docs/specs/hlk-$HLK_TID.md" -ef "$FIXTURE/docs/specs$NL/hlk-$HLK_TID.md" ] && echo same || echo differ)"
assert_eq "9.5a precondition: ...and the bytes at the derived path are a VALID design for THIS task, so only containment can refuse it" \
    "true" "$(json_field '.ok' "$(bash "$RC" validate-design "$FIXTURE/docs/specs/$HLK_TID.md" 2>/dev/null)")"
assert_eq "9.5b RECORD: the walk lands in the newline-named directory and the record is REFUSED" \
    "artifact_outside_spec_dir" \
    "$(json_field '.error_key' "$(bash "$QG" design-record "$HLK_TID" 2>&1)")"
# CONTROL: the identical two-hop chain with no newline anywhere, landing in the
# declared directory. A walk that refused every two-hop chain would pass 9.5b.
HLK2_TID=$(bd create "D1 hardlink control" -t task -p 1 --json 2>/dev/null | jq -r '.id')
write_artifact "$FIXTURE/docs/specs/hlk2-$HLK2_TID.md" "$HLK2_TID"
ln -sfn "hlk2-$HLK2_TID.md" "$FIXTURE/docs/specs/hlk2-link-$HLK2_TID.md"
ln -sfn "../specs/hlk2-link-$HLK2_TID.md" "$FIXTURE/docs/specs/$HLK2_TID.md"
printf '%s\n' "$FIXTURE/docs/specs/$HLK2_TID.md" > "$TRACKING"
assert_eq "9.5c CONTROL: the same two-hop chain inside the declared directory still records" "recorded" \
    "$(json_field '.status' "$(bash "$QG" design-record "$HLK2_TID" 2>&1)")"
rm -rf "$FIXTURE/docs/specs$NL"

# ===========================================================================
printf '\n=== Summary ===\n'
# ===========================================================================
printf '\nTotal: %d assertion(s) run\n' "$((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d assertion(s)\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

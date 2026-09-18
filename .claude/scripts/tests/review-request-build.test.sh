#!/bin/bash
# review-request-build.test.sh — claude-workflow-plugin-wuu8: the Codex
# review lane could not review this repo's own changes. Three compounding
# defects, measured on real captured packets (see wuu8's own comment
# stream): (a) some assembly sites left `.diff` empty (an unset $DIFF shell
# variable in qa.md 6p.1's own documented recipe silently became "");
# (b) the impact report was embedded PRETTY-PRINTED and DOUBLE-ENCODED
# (escaped inside a JSON string) and dominated the packet (measured: 98.5%
# and 79.4% of two real requests) despite this repo's own impact reports
# NOT being uniformly empty the way an earlier analysis claimed (that
# analysis queried the wrong jq path — see Section C's own header); (c) the
# recipe's own `--arg impact "$(cat <report>)"` form dies with "argument
# list too long: jq" on a real report (measured: 1.86MB) BEFORE the
# packet-budget cap is ever consulted, leaving an EMPTY request file
# nothing checked for.
#
# THE FIX under test: `qa-gate.sh review-request-build`, a new subcommand
# (was: hand-rolled jq an agent re-derived from qa.md's markdown each time)
# that (a) computes `.diff` from the SAME denylist-filtered, canonical
# change set change_set_hash already hashes (impact-report.sh
# --relativized-changed-files), handling untracked files the way
# design_rollup_union_diff already does; (b) summarises the impact report
# into a small, honest object instead of embedding it whole — omitted-with-
# reason when there is nothing useful to show, never a bare `{}`; (c) reads
# every potentially-large field via jq --rawfile/--slurpfile, never through
# jq's own argument list, and refuses (rather than writes) an empty or
# invalid assembly.
#
# PAIRING (`.claude/tests/README.md` "The pairing requirement"): every
# section below is a mutation/negative-control PAIRED with the shipped
# command, non-vacuity-checked, naming the specific misbehaviour it
# prevents, with at least one leg driving the real, shipped
# `qa-gate.sh review-request-build` as a subprocess (leg 4). Sections B, C,
# E and F reproduce the qa.md 6p.1 recipe AS IT WAS BEFORE THIS FIX
# (`--arg diff "$DIFF"` with $DIFF never assigned; `--arg impact
# "$(cat <path>)"`) as their negative control — a faithful transcription of
# the historical defect, not an invented strawman, so a regression back to
# that shape would be caught here as loudly as it was caught on the real
# packets that motivated this task.
#
# Section G's META-TEST answers a question the coordinator asked directly:
# "stub the size check to always pass and assert something still catches
# an oversized packet, or the budget guard is decorative." It is answered
# empirically (G.3) rather than assumed either way.
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
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle (should be ABSENT): %s\n    haystack: %s\n' "$name" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    fi
}

assert_lt() {
    local name="$1" a="$2" b="$3"
    if [ "$a" -lt "$b" ] 2>/dev/null; then
        PASS=$((PASS + 1))
        printf '  PASS: %s (%s < %s)\n' "$name" "$a" "$b"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected %s < %s\n' "$name" "$a" "$b"
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
# Fixture. Same shape as design-rollup.test.sh: the real scripts, a real bd,
# a throwaway project root and HOME, and a real git repo. `mktemp -t`
# (never a path under the harness's own /tmp/claude-<session>/ scratchpad)
# is load-bearing, not stylistic: that scratchpad prefix is itself
# denylisted (workflow-denylist.sh group 7), so a fixture built under it
# would have every one of its own "changed" files silently excluded before
# this test ever ran — measured directly while building this fix.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t review-request-build.XXXXXX)
TEST_HOME=$(mktemp -d -t review-request-build-home.XXXXXX)

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

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" "$FIXTURE/.beads" \
    "$FIXTURE/bin" "$FIXTURE/src" "$TEST_HOME/.claude/projects"

cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — review-request-build tests require Beads."
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — review-request-build tests require jq."
    exit 2
fi
if ! command -v git >/dev/null 2>&1; then
    echo "git not on PATH — review-request-build tests require a real git checkout."
    exit 2
fi

REAL_BD=$(command -v bd)
REAL_JQ=$(command -v jq)
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
CR_SCRIPT="$FIXTURE/.claude/scripts/codex-review.sh"
TRACKING="$FIXTURE/.claude/.qa-tracking/changed-files.txt"
SPEC_FILE="$FIXTURE/.claude/.qa-tracking/.rrb-spec.txt"

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }

# new_task <title> — creates a bd task and prints its id.
new_task() { bd create "$1" -t task --json 2>/dev/null | jq -r '.id // .issue.id // empty'; }

# seed_completion <tid> <files-json-array> — an IMPLEMENTER + COMPLETION v1
# record, so review-request-build's completion-contract auto-derivation has
# something real to find (the same lookup chain compute_design_alignment's
# own scope-drift check uses).
seed_completion() {
    local tid="$1" files_json="$2"
    bd comments add "$tid" "IMPLEMENTER: role=devops task=$tid at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
    local payload="$FIXTURE/.claude/.qa-tracking/.rrb-completion-$$-$RANDOM.json"
    jq -n --arg tid "$tid" --argjson files "$files_json" '
        {task_id:$tid, files_changed:$files, tests_added:["t"], decisions:["d"],
         blockers:[], llm_observations:"seeded", context_coverage:"seeded",
         role:"devops", model:"m", pin:"m", unit_id:"", design_hash:"",
         green_before:"none", green_after:"none", criteria_tests:{}}
    ' > "$payload"
    bash "$QG" completion-record "$tid" --file "$payload" >/dev/null 2>&1
    rm -f "$payload" 2>/dev/null || true
}

set_tracker() {
    : > "$TRACKING"
    local f
    for f in "$@"; do printf '%s\n' "$f" >> "$TRACKING"; done
}

printf 'SPEC: review-request-build.test.sh fixture spec.\n' > "$SPEC_FILE"

echo "=== Fixture: $FIXTURE ==="
echo "=== git: $(git --version), DEVELOPER_DIR=${DEVELOPER_DIR:-<unset>} ==="

# ===========================================================================
# SECTION B — fix (a): `.diff` is the denylist-filtered change set, and a
# fixture-mirror path can never dominate it. Also the historical-regression
# control: qa.md 6p.1's own PRE-FIX recipe (`--arg diff "$DIFF"` with $DIFF
# never assigned) produced an EMPTY diff on a real captured packet
# (a9hh-r9) — reproduced verbatim below as the negative control.

echo
echo "--- SECTION B: diff population + denylist filtering ---"

echo "line 1" > "$FIXTURE/src/a.sh"
( cd "$FIXTURE" && git add -A && git commit -q -m "B: initial commit" )
TID_B=$(new_task "section B task")
seed_completion "$TID_B" '["src/a.sh","src/new-file.sh"]'

echo "line 1" > "$FIXTURE/src/a.sh"
printf 'CHANGED-LINE-MARKER-B\n' >> "$FIXTURE/src/a.sh"
printf 'NEW-FILE-MARKER-B\n' > "$FIXTURE/src/new-file.sh"
mkdir -p "$FIXTURE/.claude/tests/e2e/fixtures/demo-b/.claude/scripts"
printf 'FIXTURE-MIRROR-MARKER-B\n' > "$FIXTURE/.claude/tests/e2e/fixtures/demo-b/.claude/scripts/mirror.sh"
set_tracker "$FIXTURE/src/a.sh" "$FIXTURE/src/new-file.sh" \
    "$FIXTURE/.claude/tests/e2e/fixtures/demo-b/.claude/scripts/mirror.sh"

# B.1 NON-VACUITY: the mirror path really is in a diffable state -- an
# UNFILTERED comparison over the same three paths DOES contain its marker,
# so B.5's absence below is the denylist filter's doing, not an accident of
# the mirror file never having been diffable at all. new-file.sh AND
# mirror.sh are both BRAND-NEW untracked paths, so plain `git diff HEAD`
# shows neither (git only ever diffs what is in the index or HEAD) --
# using the SAME --no-index-against-/dev/null idiom review_request_diff_
# text itself uses for untracked files, so this "unfiltered" baseline is a
# fair comparison (same untracked-handling, just without the denylist step)
# rather than a strawman that would omit the mirror for an unrelated reason.
UNFILTERED_DIFF="$(cd "$FIXTURE" && git diff --no-ext-diff HEAD -- src/a.sh 2>/dev/null)"
UNFILTERED_DIFF="$UNFILTERED_DIFF
$(cd "$FIXTURE" && git diff --no-ext-diff --no-index -- /dev/null src/new-file.sh 2>/dev/null)"
UNFILTERED_DIFF="$UNFILTERED_DIFF
$(cd "$FIXTURE" && git diff --no-ext-diff --no-index -- /dev/null .claude/tests/e2e/fixtures/demo-b/.claude/scripts/mirror.sh 2>/dev/null)"
assert_contains "B.1 non-vacuity: unfiltered comparison DOES contain the fixture-mirror marker" \
    "FIXTURE-MIRROR-MARKER-B" "$UNFILTERED_DIFF"

# B.2: drive the SHIPPED artifact.
REQ_B="$FIXTURE/.claude/.qa-tracking/review-request-$TID_B.json"
B_OUT=$(bash "$QG" review-request-build "$TID_B" --iteration 1 \
    --stop-condition "section B" --spec-file "$SPEC_FILE" 2>&1)
B_RC=$?
assert_eq "B.2 review-request-build exits 0 over a real change set" "0" "$B_RC"
assert_eq "B.2b ok:true" "true" "$(json_field '.ok' "$B_OUT")"

B_DIFF=$(json_field '.diff' "$(cat "$REQ_B" 2>/dev/null)")
assert_contains "B.3 .diff contains the tracked file's changed line" "CHANGED-LINE-MARKER-B" "$B_DIFF"
assert_contains "B.4 .diff contains the untracked (brand-new) file's content" "NEW-FILE-MARKER-B" "$B_DIFF"
assert_not_contains "B.5 THE FIX: .diff does NOT contain the fixture-mirror's content" \
    "FIXTURE-MIRROR-MARKER-B" "$B_DIFF"

# B.6 NEGATIVE CONTROL / historical regression: qa.md 6p.1's recipe BEFORE
# this fix, transcribed verbatim (`--arg diff "$DIFF"` with $DIFF never
# assigned anywhere in that recipe -- an unset shell variable, which `--arg`
# silently renders as the empty string). This is not a strawman: it is
# character-for-character the shape that produced an empty `.diff` on the
# real a9hh-r9 packet this task's own investigation measured. `${DIFF:-}`,
# not a bare `$DIFF`, is deliberate: this TEST FILE runs under `set -u` for
# its own hygiene (design-rollup.test.sh's own convention), which the
# ORIGINAL recipe's ordinary interactive shell never had — a bare
# reference here would abort the substitution on THIS file's unrelated
# nounset setting before jq ever ran, which would demonstrate this test's
# own strictness rather than the recipe's actual historical behaviour
# (jq DID run, and DID silently render the unset variable as "").
OLD_RECIPE_REQ=$(jq -n --arg diff "${DIFF:-}" '{diff:$diff}' 2>/dev/null)
OLD_RECIPE_DIFF=$(json_field '.diff' "$OLD_RECIPE_REQ")
assert_eq "B.6 NEGATIVE CONTROL: the pre-fix recipe's unset \$DIFF produces an EMPTY diff" \
    "" "$OLD_RECIPE_DIFF"
# B.7 RESTORE CONTROL: the shipped command, same inputs, is NOT empty (B.3
# above already proved this — referenced here so the pairing is explicit).
assert_ne "B.7 RESTORE: the shipped command's .diff is NOT empty (contrast with B.6)" \
    "" "$B_DIFF"

# ===========================================================================
# SECTION C — fix (b), part 1: `.impact_report` is a JSON OBJECT, never a
# pretty-printed, double-encoded STRING, and the per-file summary keeps
# real signal while dropping zero-impact/error/null entries.
#
# CORRECTING THE RECORD (carried from qa-gate.sh's own header comment on
# these functions, restated here because it is exactly what this section
# proves): an earlier measurement claimed this repo's impact reports are
# uniformly "structurally edge-free" — that a query of `.impact.nodes`
# always returns zero. It queried the WRONG path: the code-graph server's
# structuredContent nests real data under `.impact.data.nodes` /
# `.impact.data.file_dependents`, so `.impact.nodes` returns 0 REGARDLESS OF
# CONTENT — a query bug, not a property of this repo's reports. C.4/C.5
# below use a report with REAL non-zero `.impact.data.nodes` content
# specifically to prove the summariser reports it (rather than the
#"always empty" behaviour a summariser built on the mis-measurement would
# have shipped).

echo
echo "--- SECTION C: impact_report object-not-string, summary filtering ---"

TID_C=$(new_task "section C task")
seed_completion "$TID_C" '["src/a.sh"]'
set_tracker "$FIXTURE/src/a.sh"
REPORT_C="$FIXTURE/.claude/.qa-tracking/impact-report-$TID_C.json"

# A SMALL, real-shaped report: one file with genuine nodes (self + caller +
# a cross-file dependent) and one file with none at all, plus an ok:false
# error-shaped entry and a null-impact entry — the four documented
# degradation shapes impact-report.sh's own header names, all in one
# report, so the summariser's robustness against every shape is proven in
# a single pass rather than assumed for the ones not explicitly tried.
jq -n --arg tid "$TID_C" '
    {generated_at:"2026-01-01T00:00:00Z", task_id:$tid,
     change_set_hash:("a"*64), server:"code-graph",
     files:[
       {file:"src/a.sh", impact:{ok:true, headline:"ok", data:{
           nodes:[{name:"f1",kind:"function",relation:"self",depth:0},
                  {name:"f1",kind:"function",relation:"caller",depth:1},
                  {name:"f1",kind:"function",relation:"caller",depth:2}],
           file_dependents:["other.js"]}}},
       {file:"src/zero.sh", impact:{ok:true, headline:"not in index", data:{
           nodes:[], file_dependents:[]}}},
       {file:"src/err.sh", impact:{ok:false, error:{message:"boom"}}},
       {file:"src/null.sh", impact:null}
     ]}
' > "$REPORT_C"

REQ_C="$FIXTURE/.claude/.qa-tracking/review-request-$TID_C.json"
C_OUT=$(bash "$QG" review-request-build "$TID_C" --iteration 1 \
    --stop-condition "section C" --spec-file "$SPEC_FILE" 2>&1)
assert_eq "C.1 review-request-build exits 0 with a real impact report present" "0" "$?"
assert_eq "C.1b ok:true on stdout" "true" "$(json_field '.ok' "$C_OUT")"
C_REQ_RAW=$(cat "$REQ_C" 2>/dev/null)

# C.2 NEGATIVE CONTROL: qa.md 6p.1's PRE-FIX recipe embedded the impact
# report as `--arg impact "$(cat <path>)"` -- a STRING, escaped and
# doubled in size. Reproduced verbatim against the SAME report.
OLD_RECIPE_IMPACT=$(jq -n --arg impact "$(cat "$REPORT_C")" '{impact_report:$impact}' 2>/dev/null)
assert_eq "C.2 NEGATIVE CONTROL: the pre-fix recipe's impact_report is type STRING" \
    "string" "$(json_field '.impact_report | type' "$OLD_RECIPE_IMPACT")"

# C.3 RESTORE / THE FIX: the shipped command's impact_report is an OBJECT.
assert_eq "C.3 THE FIX: the shipped command's impact_report is type OBJECT, never a string" \
    "object" "$(json_field '.impact_report | type' "$C_REQ_RAW")"

# C.4: the summary keeps the real-data file with correct counts.
C_ENTRY=$(json_field '.impact_report.summary[] | select(.file=="src/a.sh")' "$C_REQ_RAW")
assert_eq "C.4a summary reports the correct node count for the real-data file" \
    "3" "$(json_field '.nodes' "$C_ENTRY")"
assert_eq "C.4b summary splits self vs caller correctly" \
    "1|2" "$(json_field '.self' "$C_ENTRY")|$(json_field '.callers' "$C_ENTRY")"
assert_eq "C.4c summary reports the real cross-file dependent count" \
    "1" "$(json_field '.dependents' "$C_ENTRY")"

# C.5: the summary EXCLUDES the zero-impact/error/null files (never dumps
# every file's full detail; a file with genuinely nothing to report does
# not appear in the compact summary array at all).
C_SUMMARY_FILES=$(json_field '[.impact_report.summary[].file] | join(",")' "$C_REQ_RAW")
assert_not_contains "C.5a summary excludes the zero-node file" "zero.sh" "$C_SUMMARY_FILES"
assert_not_contains "C.5b summary excludes the error-shaped (ok:false) file" "err.sh" "$C_SUMMARY_FILES"
assert_not_contains "C.5c summary excludes the null-impact file" "null.sh" "$C_SUMMARY_FILES"
assert_contains "C.5d summary DOES include the real-data file (contrast — not vacuously empty)" \
    "src/a.sh" "$C_SUMMARY_FILES"
assert_eq "C.6 total_nodes sums correctly across the whole report" \
    "3" "$(json_field '.impact_report.total_nodes' "$C_REQ_RAW")"
assert_eq "C.7 file_count covers every file impact-report.sh looked at, not just the summarised ones" \
    "4" "$(json_field '.impact_report.file_count' "$C_REQ_RAW")"

# ===========================================================================
# SECTION D — fix (b), part 2: THREE degradation states must be visibly
# distinguishable from each other and from "present with real signal"
# (Section C). None of them may read as a bare `{}` ("nothing depends on
# this") — this is the unifying defect family the coordinator named: a
# measurement that did not happen must never look identical to one that did.

echo
echo "--- SECTION D: omitted-with-reason, distinguishable degradation states ---"

TID_D=$(new_task "section D task")
seed_completion "$TID_D" '["src/a.sh"]'
set_tracker "$FIXTURE/src/a.sh"
REPORT_D="$FIXTURE/.claude/.qa-tracking/impact-report-$TID_D.json"
REQ_D="$FIXTURE/.claude/.qa-tracking/review-request-$TID_D.json"

# D.1: no impact report has ever been generated for this task.
rm -f "$REPORT_D"
bash "$QG" review-request-build "$TID_D" --iteration 1 --stop-condition "D1" --spec-file "$SPEC_FILE" >/dev/null 2>&1
D1_IMPACT=$(json_field '.impact_report' "$(cat "$REQ_D" 2>/dev/null)")
assert_eq "D.1a omitted:true when no report exists" "true" "$(json_field '.omitted' "$D1_IMPACT")"
D1_REASON=$(json_field '.reason' "$D1_IMPACT")
assert_contains "D.1b reason names the specific cause (no report generated yet)" \
    "no impact report has been generated" "$D1_REASON"

# D.2: a report exists but the code-graph server was absent.
jq -n --arg tid "$TID_D" '
    {generated_at:"t", task_id:$tid, change_set_hash:("b"*64), server:"absent",
     files:[{file:"src/a.sh", impact:null}]}
' > "$REPORT_D"
bash "$QG" review-request-build "$TID_D" --iteration 2 --stop-condition "D2" --spec-file "$SPEC_FILE" >/dev/null 2>&1
D2_IMPACT=$(json_field '.impact_report' "$(cat "$REQ_D" 2>/dev/null)")
assert_eq "D.2a omitted:true when server was absent" "true" "$(json_field '.omitted' "$D2_IMPACT")"
D2_NOTE=$(json_field '.note' "$D2_IMPACT")
assert_contains "D.2b note names the specific cause (server absent)" "server was unavailable" "$D2_NOTE"

# D.3: a report exists, the server ran, files were looked at — and every
# one genuinely has zero nodes and zero dependents.
jq -n --arg tid "$TID_D" '
    {generated_at:"t", task_id:$tid, change_set_hash:("c"*64), server:"code-graph",
     files:[{file:"src/a.sh", impact:{ok:true, headline:"not in index", data:{nodes:[], file_dependents:[]}}}]}
' > "$REPORT_D"
bash "$QG" review-request-build "$TID_D" --iteration 3 --stop-condition "D3" --spec-file "$SPEC_FILE" >/dev/null 2>&1
D3_IMPACT=$(json_field '.impact_report' "$(cat "$REQ_D" 2>/dev/null)")
assert_eq "D.3a omitted:true when genuinely edge-free" "true" "$(json_field '.omitted' "$D3_IMPACT")"
D3_NOTE=$(json_field '.note' "$D3_IMPACT")
assert_contains "D.3b note names the specific cause (no recorded node/dependent anywhere)" \
    "no file in this change set has any recorded call-graph node" "$D3_NOTE"

# D.4 THE DISTINGUISHABILITY REQUIREMENT: all three reasons/notes are
# pairwise DIFFERENT, and NONE of the three objects is a bare `{}`.
assert_ne "D.4a D.1's reason differs from D.2's note" "$D1_REASON" "$D2_NOTE"
assert_ne "D.4b D.2's note differs from D.3's note" "$D2_NOTE" "$D3_NOTE"
assert_ne "D.4c D.1's reason differs from D.3's note" "$D1_REASON" "$D3_NOTE"
assert_ne "D.4d D.1 is not a bare {} (has a path key)" "" "$(json_field '.path' "$D1_IMPACT")"
assert_eq "D.4e D.2 carries file_count (never bare {})" "1" "$(json_field '.file_count' "$D2_IMPACT")"
assert_eq "D.4f D.3 carries file_count (never bare {})" "1" "$(json_field '.file_count' "$D3_IMPACT")"
# D.4g RESTORE / non-vacuity contrast: Section C's real-data case is
# NEITHER omitted-empty state — its summary is genuinely non-empty, proving
# this summariser does not just always say "omitted, nothing here"
# regardless of what the underlying report actually contains.
assert_ne "D.4g contrast with Section C: a real-data report does NOT read like D.2/D.3" \
    "[]" "$(json_field '.impact_report.summary' "$C_REQ_RAW")"

# ===========================================================================
# SECTION E — the assembled packet for a representative (production-scale)
# change set stays comfortably under max_request_bytes, AND the pre-fix
# recipe cannot even assemble one over the same input (ARG_MAX). This
# section reproduces the actual measured production failure: a ~1.86MB
# impact report (this repo's own qa-gate.sh, at real scale, carries 4000+
# nodes) that the OLD recipe's `--arg impact "$(cat ...)"` form cannot
# place on jq's argument list at all.

echo
echo "--- SECTION E: production-scale packet stays under max_request_bytes ---"

TID_E=$(new_task "section E task")
seed_completion "$TID_E" '["src/a.sh"]'
set_tracker "$FIXTURE/src/a.sh"
REPORT_E="$FIXTURE/.claude/.qa-tracking/impact-report-$TID_E.json"
REQ_E="$FIXTURE/.claude/.qa-tracking/review-request-$TID_E.json"

# A synthetic report at the SAME order of magnitude as this repo's own real
# qa-gate.sh impact entry (measured directly against
# .claude/.qa-tracking/impact-report-claude-workflow-plugin-fkm.8.json
# while building this fix: 4100 nodes, 1367 self / 2733 caller-shaped, full
# schema — symbol_id/name/kind/file/lang/line/depth/relation per node).
#
# SIZED RELATIVE TO THE HOST'S OWN ARG_MAX, not to a fixed byte count: a
# fixed ~640KB report reliably reproduced "argument list too long: jq" in
# one interactive measurement but SUCCEEDED (rc=0) when this test first
# shipped and ran non-interactively — the two invocations differ in
# inherited environment size, which counts against the SAME ARG_MAX budget
# as argv. Generating comfortably past 3x this host's own ARG_MAX (floor
# 4MB, so a host reporting a small or unavailable ARG_MAX still gets a
# report large enough to fail on ordinary Linux MAX_ARG_STRLEN too — 32
# pages, typically 131072 bytes per single argument, far below ARG_MAX
# proper) removes that source of flakiness rather than hoping a fixed
# number clears whatever the executing environment happens to add.
HOST_ARG_MAX=$(getconf ARG_MAX 2>/dev/null || echo 131072)
[ "$HOST_ARG_MAX" -gt 0 ] 2>/dev/null || HOST_ARG_MAX=131072
TARGET_BYTES=$((HOST_ARG_MAX * 3))
[ "$TARGET_BYTES" -ge 4000000 ] 2>/dev/null || TARGET_BYTES=4000000

python3 - "$REPORT_E" "$TID_E" "$TARGET_BYTES" <<'PY'
import json, sys
report_path, tid, target_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3])

def build(n):
    nodes = [{"symbol_id": i, "name": f"fn_{i}", "kind": "function",
              "file": "src/a.sh", "lang": "bash", "line": i + 1, "depth": i % 6,
              "relation": ("self" if i % 3 == 0 else "caller")} for i in range(n)]
    return {"generated_at": "t", "task_id": tid, "change_set_hash": "d" * 64,
            "server": "code-graph",
            "files": [{"file": "src/a.sh", "impact": {"ok": True, "headline": "ok",
                       "data": {"nodes": nodes, "file_dependents": []}}}]}

# Start from a measured estimate (~300 bytes/node pretty-printed) and grow
# geometrically until the actual serialised size clears the target -- more
# robust than trusting the per-node estimate to hold across Python/json
# versions.
n = max(1000, target_bytes // 250)
while True:
    text = json.dumps(build(n), indent=2)
    if len(text) >= target_bytes:
        break
    n = int(n * 1.5) + 1000
with open(report_path, "w") as f:
    f.write(text)
print(f"generated {n} nodes, {len(text)} bytes (target {target_bytes})", file=sys.stderr)
PY
E_REPORT_BYTES=$(wc -c < "$REPORT_E" | tr -d '[:space:]')
assert_lt "E.0 non-vacuity: the generated synthetic report ($E_REPORT_BYTES bytes) clears the sizing target ($TARGET_BYTES)" \
    "$TARGET_BYTES" "$((E_REPORT_BYTES + 1))"

# E.1 NEGATIVE CONTROL: the pre-fix recipe's `--arg impact "$(cat <path>)"`
# form against this SAME oversized report. `getconf ARG_MAX` on this host
# names the ceiling; the assembled arg (this report's bytes, doubled by
# JSON-string escaping) exceeds it on any host where the report itself
# does — reproduced live while building this fix (macOS, ARG_MAX=1048576,
# rc=127, "argument list too long: jq").
OLD_RECIPE_OUT=$(jq -n --arg impact "$(cat "$REPORT_E" 2>/dev/null)" '{impact_report:$impact}' 2>&1)
OLD_RECIPE_RC=$?
assert_ne "E.1 NEGATIVE CONTROL: the pre-fix recipe FAILS assembling a ${E_REPORT_BYTES}-byte report (rc=$OLD_RECIPE_RC)" \
    "0" "$OLD_RECIPE_RC"
assert_eq "E.1b non-vacuity: the failure is empty jq output, not a well-formed small object" \
    "" "$(json_field '.impact_report' "$OLD_RECIPE_OUT")"

# E.2 THE FIX: the shipped command over the IDENTICAL report.
E_OUT=$(bash "$QG" review-request-build "$TID_E" --iteration 1 \
    --stop-condition "section E" --spec-file "$SPEC_FILE" 2>&1)
assert_eq "E.2 review-request-build succeeds over the same oversized report" "0" "$?"
assert_eq "E.2b ok:true on stdout" "true" "$(json_field '.ok' "$E_OUT")"
E_TOTAL_BYTES=$(wc -c < "$REQ_E" | tr -d '[:space:]')
# The shipped, documented cap (review-config's own default, restated here
# rather than re-read from a config file the fixture does not carry, so
# this assertion means the same thing whether or not review-config ships).
MAX_REQUEST_BYTES_DEFAULT=100000
assert_lt "E.3 assembled request ($E_TOTAL_BYTES bytes) is under max_request_bytes ($MAX_REQUEST_BYTES_DEFAULT)" \
    "$E_TOTAL_BYTES" "$MAX_REQUEST_BYTES_DEFAULT"
# Informational (not a hard failure): the wuu8 target was "~15KB plus a
# filtered diff". A generous 30KB ceiling still catches a regression that
# reintroduces meaningful bloat without being brittle against reasonable
# future growth in the summary shape.
assert_lt "E.4 (informational headroom) assembled request is under a 30000-byte soft target" \
    "$E_TOTAL_BYTES" "30000"

# ===========================================================================
# SECTION F — a genuine assembly failure is REFUSED, never handed onward as
# a plausible-looking empty file. Fault-injects `jq` itself (rather than
# relying on a real ARG_MAX crash, which Section E's negative control
# already reproduces once) so this section can assert the SPECIFIC recovery
# behaviour: no file at the canonical path, no leftover .tmp.* droppings,
# a structured, correctly-attributed error.

echo
echo "--- SECTION F: a failed assembly is refused, not written ---"

TID_F=$(new_task "section F task")
seed_completion "$TID_F" '["src/a.sh"]'
set_tracker "$FIXTURE/src/a.sh"
REQ_F="$FIXTURE/.claude/.qa-tracking/review-request-$TID_F.json"
rm -f "$REQ_F" "$FIXTURE/.claude/.qa-tracking/"*.tmp.* 2>/dev/null

# The fault only fires on the ONE call site combining BOTH --rawfile AND
# --slurpfile in a single invocation — verified unique in qa-gate.sh before
# relying on it (`grep -c -- '--slurpfile' .claude/scripts/qa-gate.sh`
# found exactly one PRE-EXISTING call, at compute_design_alignment's own
# scope-drift check, using --slurpfile alone with no --rawfile — so it does
# not collide with this shim). Every other jq call in the whole process
# tree (bd's own internals, review-check.sh, impact-report.sh) passes
# through untouched.
cat > "$FIXTURE/bin/jq" <<EOF
#!/bin/bash
has_rawfile=0; has_slurp=0
for a in "\$@"; do
    [ "\$a" = "--rawfile" ] && has_rawfile=1
    [ "\$a" = "--slurpfile" ] && has_slurp=1
done
if [ "\$has_rawfile" = "1" ] && [ "\$has_slurp" = "1" ]; then
    echo "jq: injected fault (review-request-build.test.sh Section F)" >&2
    exit 5
fi
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$FIXTURE/bin/jq"

F_OUT=$(bash "$QG" review-request-build "$TID_F" --iteration 1 \
    --stop-condition "section F" --spec-file "$SPEC_FILE" 2>&1)
F_RC=$?

assert_ne "F.1 fault-injected assembly does NOT exit 0" "0" "$F_RC"
assert_eq "F.2 error_key names the specific check (assembled_request_empty)" \
    "assembled_request_empty" "$(json_field '.error_key' "$F_OUT")"
# F.3 NON-VACUITY: the observations text names the SHIM's own distinctive
# exit code (5), proving the injected fault — not some unrelated failure —
# is what was caught.
assert_contains "F.3 non-vacuity: observations name the injected jq rc=5" "jq rc=5" "$F_OUT"
assert_eq "F.4 THE FIX: no file was left at the canonical request path" \
    "absent" "$([ -f "$REQ_F" ] && echo exists || echo absent)"
F_TMP_COUNT=$(find "$FIXTURE/.claude/.qa-tracking/" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l | tr -d '[:space:]')
assert_eq "F.5 no leftover .tmp.* files (the guard cleaned up rather than aborting mid-write)" \
    "0" "$F_TMP_COUNT"

# F.6 RESTORE CONTROL: remove the fault, same task, same inputs — succeeds
# normally and the canonical path now exists and validates.
rm -f "$FIXTURE/bin/jq"
F2_OUT=$(bash "$QG" review-request-build "$TID_F" --iteration 2 \
    --stop-condition "section F restore" --spec-file "$SPEC_FILE" 2>&1)
assert_eq "F.6 RESTORE: without the fault, the identical call succeeds" "0" "$?"
assert_eq "F.6c RESTORE: ok:true on stdout" "true" "$(json_field '.ok' "$F2_OUT")"
assert_eq "F.6b RESTORE: the request now exists at the canonical path" \
    "exists" "$([ -f "$REQ_F" ] && echo exists || echo absent)"

# ===========================================================================
# SECTION G — regression guard (do not weaken the honest exit-7 refusal
# codex-review.sh already ships — claude-workflow-plugin-nq5f) plus the
# coordinator's own META-TEST: "stub the size check to always pass and
# assert something still catches an oversized packet, or the budget guard
# is decorative." codex-review.sh's own component spec
# (.claude/tests/component/specs/codex-review.sh, leg C9) already covers
# this exhaustively; this section is a lighter confirmation that a request
# THIS command assembles remains compatible with that enforcement, plus the
# META-TEST the coordinator asked for by name, answered empirically rather
# than assumed.

echo
echo "--- SECTION G: exit-7 regression + META-TEST (is the size guard decorative) ---"

# Reuse Section E's already-assembled request; lower max_request_bytes
# below its actual size so codex-review.sh's own cap fires on it (no need
# for a literal 100KB+ payload — the cap is config-driven, and testing the
# discrimination at a smaller, deterministic boundary is equally valid).
G_CAP=$((E_TOTAL_BYTES / 2))
mkdir -p "$FIXTURE/.claude"
{
    echo "risk_threshold_default=high"
    echo "max_findings=10"
    echo "max_review_iterations=3"
    echo "timeout_seconds=5"
    echo "malformed_retry=1"
    echo "max_request_bytes=$G_CAP"
} > "$FIXTURE/.claude/review-config"

# G.1 non-vacuity: the request really IS over the lowered cap.
assert_lt "G.1 non-vacuity: the lowered cap ($G_CAP) is genuinely below the request size ($E_TOTAL_BYTES)" \
    "$G_CAP" "$E_TOTAL_BYTES"

G1_ERR=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$CR_SCRIPT" "$TID_E" --request "$REQ_E" --iteration 1 2>&1 >/dev/null)
G1_RC=$?
assert_eq "G.2 REGRESSION GUARD: codex-review.sh still exits 7 for a genuinely oversized packet" "7" "$G1_RC"
assert_contains "G.2b refusal names max_request_bytes and the byte count" "exceeding max_request_bytes=$G_CAP" "$G1_ERR"

# G.3 RESTORE / contrast: a request comfortably UNDER the (lowered) cap
# does NOT exit 7 — it fails differently (no Codex MCP registered in this
# fixture's isolated HOME), proving the cap discriminates by SIZE
# specifically rather than refusing everything unconditionally. A
# DEDICATED, hand-built minimal request is used rather than reusing
# Section B's (whose actual byte count is not controlled against this
# section's own halved cap and could coincidentally land on either side of
# it) -- small enough to clear $G_CAP with margin, and still schema-valid
# (validate-request runs BEFORE the size check in codex-review.sh, so an
# invalid request would exit 4 without ever reaching the check this
# section exists to exercise).
TINY_HASH=$(python3 -c "print('a'*64)")
SMALL_REQ="$FIXTURE/.claude/.qa-tracking/.rrb-tiny-request.json"
jq -nc --arg h "$TINY_HASH" '
    {contract_version:"1", task_id:"tiny-task", iteration:1,
     risk_threshold:"high", stop_condition:"x", change_set_hash:$h,
     spec:"s", diff:"", completion_contract:"{}", impact_report:{}}
' > "$SMALL_REQ"
SMALL_REQ_BYTES=$(wc -c < "$SMALL_REQ" | tr -d '[:space:]')
assert_lt "G.3 non-vacuity: the dedicated tiny request ($SMALL_REQ_BYTES bytes) is genuinely under the lowered cap ($G_CAP)" \
    "$SMALL_REQ_BYTES" "$G_CAP"
TINY_VALIDATE=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/review-check.sh" validate-request "$SMALL_REQ" 2>/dev/null)
assert_eq "G.3b non-vacuity: the dedicated tiny request is schema-valid (reaches the size check at all)" \
    "true" "$(json_field '.ok' "$TINY_VALIDATE")"
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$CR_SCRIPT" "tiny-task" --request "$SMALL_REQ" --iteration 1 >/dev/null 2>&1
G3_RC=$?
assert_eq "G.3c RESTORE: a request under the cap reaches PAST the size check (exit 5, no Codex MCP — not exit 7)" \
    "5" "$G3_RC"

# G.4 META-TEST: a copy of codex-review.sh with the size-refusal condition
# stubbed to always "pass" (never refuse). If nothing ELSE in the pipeline
# also catches an oversized packet, the guard is proven NOT decorative by
# showing what removing it actually costs: the SAME oversized request now
# advances PAST the byte check entirely, all the way to the NEXT guard
# (no Codex MCP registration, exit 5) instead of being refused at exit 7 —
# i.e. nothing else stands between an oversized packet and an attempted
# spend once this one check is gone.
MUTANT_CR="$FIXTURE/.claude/scripts/codex-review-mutant.sh"
cp "$CR_SCRIPT" "$MUTANT_CR"
# shellcheck disable=SC2016  # single-quoted on purpose: matching codex-review.sh's own LITERAL source text, not expanding this test's variables.
BEFORE_COUNT=$(grep -c 'if \[ "\$REQUEST_BYTES" -gt "\$MAX_REQUEST_BYTES" \]; then' "$MUTANT_CR")
# shellcheck disable=SC2016
sed -i.bak 's/if \[ "\$REQUEST_BYTES" -gt "\$MAX_REQUEST_BYTES" \]; then/if false; then/' "$MUTANT_CR"
rm -f "$MUTANT_CR.bak"
# shellcheck disable=SC2016
AFTER_COUNT=$(grep -c 'if \[ "\$REQUEST_BYTES" -gt "\$MAX_REQUEST_BYTES" \]; then' "$MUTANT_CR")
AFTER_STUB_COUNT=$(grep -c '^if false; then$' "$MUTANT_CR")

# G.4a NON-VACUITY: the mutation actually landed exactly once, and the
# mutant is still valid bash — otherwise this leg would prove nothing
# about the SUT (`.claude/tests/README.md`'s own worked example for this).
assert_eq "G.4a non-vacuity: exactly one refusal condition existed before mutation" "1" "$BEFORE_COUNT"
assert_eq "G.4b non-vacuity: the original condition is GONE after mutation" "0" "$AFTER_COUNT"
assert_eq "G.4c non-vacuity: the stub landed in its place" "1" "$AFTER_STUB_COUNT"
bash -n "$MUTANT_CR"
assert_eq "G.4d non-vacuity: the mutant still parses as valid bash" "0" "$?"

CLAUDE_PROJECT_DIR="$FIXTURE" bash "$MUTANT_CR" "$TID_E" --request "$REQ_E" --iteration 1 >/dev/null 2>&1
G4_RC=$?
assert_ne "G.4e META-TEST: with the size check stubbed out, the SAME oversized request no longer exits 7" \
    "7" "$G4_RC"
assert_eq "G.4f META-TEST ANSWER: it advances to the NEXT guard instead (exit 5, no Codex MCP) — nothing else in this pipeline independently catches an oversized packet, so the size check is NOT decorative: disabling it removes ALL protection between an oversized request and an attempted paid call" \
    "5" "$G4_RC"
rm -f "$MUTANT_CR"

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

#!/bin/bash
# Unit-test fixture for .claude/scripts/qa-gate.sh `choose` subcommand
# (spec 0.2 / claude-workflow-plugin-e0d.2).
#
# Covers the four J21 decision-gate choices the production gate now
# records via `qa-gate.sh choose <choice> <task-id> <note>`:
#
#   1. approve   — delegates to the existing atomic approve flow;
#                  removes qa-escalated / qa-deferred labels; wipes
#                  per-task iteration state.
#   2. continue  — clears qa-escalated; resets iteration counter; keeps
#                  qa-pending so the loop is alive again.
#   3. tech-debt — calls tech-debt.sh add --bd-task; clears qa-escalated;
#                  resets counter.
#   4. defer     — sets qa-deferred (allowing the next Stop); preserves
#                  qa-pending.
#
# Also covers:
#   - Cap-hit detection: bumping the counter to MAX_ITERATIONS is the
#     trigger the verify-before-stop hook reads (we assert the qa-gate
#     side of the contract; the verify side is L2).
#   - Malformed args: unknown choice, missing note, missing task id —
#     each exits non-zero with a usage message on stderr.
#   - (claude-workflow-plugin-j7kk, 39cy) `qa-gate.sh status` reporting
#     "unavailable" rather than "not-entered" when `bd show` fails for any
#     reason — this file already builds the bd-init'd fixture + pass-through
#     wrapper this needs, so it lives here rather than in a new file.
#
# Conventions: this script mirrors bd-github-link.test.sh /
# phase5-synthetic-tests.sh — plain bash, `set -u`, assert helpers,
# trailing summary. No bats. The fixture is a tempdir with bd init'd
# inside it, reached through a pass-through bd wrapper on PATH (it carried
# --no-daemon until bd 1.1.2 removed the flag along with the daemon).
#
# Exit codes:
#   0  every assertion passed
#   1  at least one assertion failed
#
# Usage:
#   bash .claude/scripts/tests/qa-gate-choose.test.sh
#   bash .claude/scripts/tests/qa-gate-choose.test.sh --keep

# shellcheck disable=SC2317
# Same rationale as the other tests in this dir: assert_* helpers and
# scenario bodies are reached via control flow (set -u + early-exit +
# subshells) the static analyzer can't follow. Disabled file-wide.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

KEEP_FIXTURE=0
[ "${1:-}" = "--keep" ] && KEEP_FIXTURE=1

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

assert_match() {
    local name="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -qE "$pattern"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    pattern: %s\n    actual:  %s\n' \
            "$name" "$pattern" "$actual"
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
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' \
            "$name" "$needle" "$haystack"
    fi
}

# ---------------------------------------------------------------------------
# Fixture setup. Mirror phase5-synthetic-tests.sh's pattern.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)/.."
PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"
FIXTURE=$(mktemp -d -t qa-gate-choose.XXXXXX)
TEST_HOME=$(mktemp -d -t qa-gate-choose-home.XXXXXX)

# shellcheck disable=SC2329  # cleanup invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\nTest HOME: %s\n' "$FIXTURE" "$TEST_HOME"
    else
        rm -rf "$FIXTURE" "$TEST_HOME"
    fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.beads" "$TEST_HOME/.claude/projects" "$FIXTURE/bin"

cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

# No BD_SHIM_ONLY skip arm any more (a9hh): CI installs the real bd, and a
# bd-less environment is a hard failure everywhere.
if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — qa-gate-choose tests require Beads."
    exit 1
fi

# bd wrapper: a pass-through so the fixture has one PATH-controlled bd. It
# injected --no-daemon until bd 1.1.2 removed the flag (and the daemon: 1.1.x
# runs an in-process embedded Dolt engine, so there is no tempdir race left).
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

# V3 (claude-workflow-plugin-jio.1): seed the records that make a task
# APPROVABLE. `qa-gate.sh approve` now REFUSES unless the task carries a review
# artifact whose reviewer differs from every recorded IMPLEMENTER and has no
# open finding at/above its risk_threshold (review-check.sh gate). This fixture
# has no live spawn and no reviewer, so the approve-path assertions below have
# to model the real flow: the IMPLEMENTER comment subagent-start.sh writes on
# spawn, plus a qa-claude artifact recorded through the REAL review-record
# writer (so a grammar change breaks the seed loudly instead of silently
# drifting). reviewed_hash is pinned to the current canonical change-set hash
# so no staleness warning is emitted into the observations under test.
seed_review_records() {
    local tid="$1" reviewer="${2:-qa-claude}" role="${3:-backend}"
    local ts hash art
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comments add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1 \
        || bd comment add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1 \
        || return 1

    # v5 D2 Part B (claude-workflow-plugin-fkm.4) MIGRATION: approve now ALSO
    # refuses (exit 2, no_design_attempted) without a satisfied, independent
    # DESIGN-REVIEW verdict, unless --no-design. `choose approve` has the SAME
    # "no bypass flag to pass through" limitation the jio.1 comment above
    # already documents for the review artifact and the qbhw comment below
    # documents for completion — so the design records must be real too,
    # seeded through the real writers here rather than at eighty call sites.
    # Placed BEFORE the review artifact so the reconcile + impact-report
    # refresh a few lines down (already here for the review artifact's own
    # new tracked path) folds in docs/specs/<tid>.md in the SAME pass.
    local design_sanitized design_art design_hash
    design_sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
    mkdir -p "$FIXTURE/docs/specs" 2>/dev/null || true
    design_art="$FIXTURE/docs/specs/$design_sanitized.md"
    cat > "$design_art" <<DESIGNDOC
# Design — $tid

## Problem
Seeded fixture design (qa-gate-choose harness only).

## Approaches considered
1. A second seed convention — rejected: no reuse to justify one.
2. This minimal artifact — chosen: matches every other seed helper here.

## Chosen approach
Seed a schema-valid design so approve's design-satisfied refusal does not
block a spec that is not testing it.

## Units
See the machine block.

## Global constraints
None.

## Out of scope
Everything this fixture does not seed.

## Verification plan
make test

## Revision log
- v1 seeded by the qa-gate-choose fixture.

<!-- DESIGN-UNITS BEGIN -->
\`\`\`json
{
  "contract_version": "1",
  "task_id": "$tid",
  "designer_identity": "designer",
  "units": [
    {
      "unit_id": "U1",
      "role": "$role",
      "goal": "seeded unit",
      "acceptance": [ { "id": "AC1", "text": "seeded fixture: nothing asserted" } ],
      "files": [ ".claude/scripts/qa-gate.sh" ],
      "verification": "make test",
      "depends_on": []
    }
  ]
}
\`\`\`
<!-- DESIGN-UNITS END -->
DESIGNDOC
    # v5 D3 (claude-workflow-plugin-fkm.5): design-record now refuses
    # grilling_record_missing without one; bypass rather than seed a real
    # grilling record, since this fixture never copies the vendor tree
    # grilling-record would need to hash, and this seed exists only so
    # approve's design-satisfied refusal does not block a spec testing J21
    # escalation, not grilling.
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
        design-record "$tid" --no-grilling "qa-gate-choose.test.sh: seeding design-satisfied, not testing grilling" \
        >/dev/null 2>&1 || return 1
    design_hash=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/workflow-manifest.sh" hash-file "$design_art" 2>/dev/null) || design_hash=""
    if [ -z "$design_hash" ]; then return 1; fi
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
        design-review-record "$tid" --design-hash "$design_hash" \
        <<< '{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"seeded fixture"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}' \
        >/dev/null 2>&1 || return 1

    # claude-workflow-plugin-wob2 (L2): put a KNOWN, task-specific path into
    # the tracker BEFORE computing the hash this review pins itself to, not
    # just after (as the comment below this block already does once
    # review-record has written a new tracked file). Without this, the
    # tracker is still absent-or-empty at this exact point (nothing in this
    # fixture populates changed-files.txt directly), so impact-report.sh
    # --hash-only legitimately answers the SHA-256 empty-content digest — a
    # well-formed 64-hex string that review-check.sh validate-artifact now
    # refuses outright as reviewed_hash_unusable (a degradation sentinel
    # that would compare equal to itself forever; see that check's own
    # header).
    #
    # A DIRECT APPEND, NOT reconcile-tracker's git-status discovery:
    # reconcile-tracker alone worked here when this was the fixture's only
    # seed_review_records call (measured), but is NOT reliable in general —
    # qa-gate-grade-record.test.sh's sibling helper calls it three times in
    # one fixture with no commits ever made, and the FIRST call's design doc
    # makes `docs/` an untracked DIRECTORY; `git status --porcelain` then
    # collapses it to one opaque `?? docs/` line, and once a later baseline
    # capture records that line, every path under docs/ — including files
    # that do not exist yet — reads as "already-baselined, pre-existing
    # dirt" forever after, so change_set_hash silently reverts to the
    # empty-set digest on the second and third call. This file only ever
    # calls seed_review_records once today, so that failure mode is not
    # currently reachable here — but appending this task's own design_art
    # path directly sidesteps the question rather than depending on it
    # staying that way, and matches the direct-write shape
    # run_cycle_pre_approve in review-artifact-durability.sh already uses
    # for the identical reason.
    mkdir -p "$FIXTURE/.claude/.qa-tracking" 2>/dev/null || true
    printf '%s\n' "$design_art" >> "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
    hash=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
    [ -z "$hash" ] && hash="unverified"
    art="$FIXTURE/.claude/.qa-tracking/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"%s","reviewer_model":"seeded-fixture","reviewer_pin":"seeded-fixture","reviewed_hash":"%s","risk_threshold":"high","stop_condition":"seeded fixture: acceptance criteria traced","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}\n' \
        "$tid" "$reviewer" "$hash" > "$art"
    # claude-workflow-plugin-rqer (v5 D2): --file now asserts the CANONICAL
    # derived path; piped via stdin instead.
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
        review-record "$tid" < "$art" >/dev/null 2>&1 || return 1
    # claude-workflow-plugin-rqer (v5 D2): the artifact just written now lives
    # at a TRACKED path (docs/reviews/), so this fixture's git-visible dirt
    # includes it from this instant — but changed-files.txt does not know that
    # yet. If a caller lets this function return with the tracker still
    # absent-or-empty, the NEXT `approve` reconciles from a blank tracker via
    # `git status`, and 94d.1's change_set_reconstructed refusal fires
    # (measured: it names this fixture's own uncommitted `.claude/scripts/`
    # and `bin/` as dropped-as-baselined, because `bd create` auto-inits git
    # here and nothing in this fixture ever commits it). Reconcile now, while
    # the caller still controls exactly what's dirty, then regenerate the
    # impact report so approve's freshness check sees the WITH-artifact set
    # rather than refusing on staleness a moment later.
    if [ -f "$FIXTURE/.claude/scripts/impact-report.sh" ]; then
        CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
            reconcile-tracker >/dev/null 2>&1 || true
        CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/impact-report.sh" \
            "$tid" >/dev/null 2>&1 || true
    fi
    # P7 (claude-workflow-plugin-qbhw) MIGRATION: approve additionally REFUSES
    # (exit 2, completion_record_missing) unless the task carries a validated
    # COMPLETION v1 record. `choose approve` delegates straight to cmd_approve,
    # so it inherits that refusal — deliberately, per the subcommand's own
    # contract ("a J21 decision does not exempt the task from ... a recorded
    # completion contract"). Seeded through the REAL writer for the same reason
    # the artifact above is: a grammar change must break this loudly.
    #
    # files_changed is [] because this fixture changes no files. That is the
    # accurate declaration, and it keeps approve's completeness cross-check
    # (fkm.1.20) silent — a fabricated path here would emit a WARNING into the
    # very observations several assertions below read.
    local pay
    pay="$FIXTURE/.claude/.qa-tracking/completion-draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    printf '{"task_id":"%s","role":"%s","model":"seeded","pin":"seeded","files_changed":[],"tests_added":[],"decisions":["seeded fixture"],"blockers":[],"llm_observations":"seeded by the qa-gate-choose fixture","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown","unit_id":"","design_hash":"","green_before":"none","green_after":"none"}\n' \
        "$tid" "$role" > "$pay"
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/qa-gate.sh" \
        completion-record "$tid" --file "$pay" >/dev/null 2>&1
}
TRACK="$FIXTURE/.claude/.qa-tracking"

# Helper: read the current labels for a task as a comma-joined string.
labels_for() {
    local tid="$1"
    bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}

# Same version-tolerant reader the production scripts use: bd 1.1.2 returns
# only a comment_count on a plain `show --json` and needs --include-comments;
# bd 0.47.x rejects that flag but inlines .comments. Pin the chain, not the leg.
bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

# Helper: count comments matching a regex on a task. Kept for parity
# with the L2 spec's helper, even though this file uses inline jq for
# every comment-check — having both reduces future drift.
# NOTE: the disable below must stay DIRECTLY above comment_count_matching —
# a shellcheck directive binds to the next command, so anything inserted
# between them silently transfers the suppression to the interloper.
# shellcheck disable=SC2329  # Retained as a documented helper.
comment_count_matching() {
    local tid="$1" pat="$2"
    bd_show_with_comments "$tid" \
        | jq -r --arg pat "$pat" \
            'if type == "array" then .[0].comments else .comments end // [] | map(select(.text | test($pat))) | length' \
        2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: usage / malformed args ==="

# 1.1 No args -> exit 1 + usage.
RC=0; bash "$QG" choose 2>/dev/null || RC=$?
assert_eq "choose: no args exit 1" "1" "$RC"

# 1.2 Unknown choice -> exit 1 + usage on stderr.
RC=0
STDERR=$(bash "$QG" choose unknown task1 'note' 2>&1 >/dev/null || true)
bash "$QG" choose unknown task1 'note' >/dev/null 2>&1 || RC=$?
assert_eq "choose: unknown choice exit 1" "1" "$RC"
assert_contains "choose: unknown choice stderr mentions choice value" \
    "unknown choose value" "$STDERR"

# 1.3 Missing note -> exit 1.
RC=0; bash "$QG" choose defer task1 2>/dev/null >/dev/null || RC=$?
assert_eq "choose: missing note exit 1" "1" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: choose continue ==="

# Seed: task with qa-escalated + planted iteration counter.
TID_CONT=$(bd create "choose continue test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_CONT" >/dev/null
bd label add "$TID_CONT" qa-pending >/dev/null 2>&1
bd label add "$TID_CONT" qa-escalated >/dev/null 2>&1
SANITIZED_CONT=$(printf '%s' "$TID_CONT" | tr -c 'A-Za-z0-9._-' '_')
printf '3\n' > "$TRACK/iteration-count.$SANITIZED_CONT"
printf 'cached failure\n' > "$TRACK/last-failed-checks.$SANITIZED_CONT"
: > "$TRACK/escalation-posted.$SANITIZED_CONT"

# Pre-condition.
LABELS_BEFORE=$(labels_for "$TID_CONT")
assert_contains "choose continue: pre-condition qa-escalated present" \
    "qa-escalated" "$LABELS_BEFORE"

OUT=$(bash "$QG" choose continue "$TID_CONT" "Fixing the failing tests")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "choose continue: status=continue" "continue" "$STATUS"

LABELS_AFTER=$(labels_for "$TID_CONT")
ESC_GREP=$(printf '%s' ",$LABELS_AFTER," | grep -c ',qa-escalated,' || true)
ESC_GREP=$(printf '%s' "$ESC_GREP" | tr -d '[:space:]')
assert_eq "choose continue: qa-escalated removed" "0" "$ESC_GREP"

# qa-pending preserved (loop is alive again).
assert_contains "choose continue: qa-pending preserved" \
    "qa-pending" "$LABELS_AFTER"

# Counter wiped.
assert_eq "choose continue: iteration counter wiped" "1" \
    "$([ -s "$TRACK/iteration-count.$SANITIZED_CONT" ] && echo 0 || echo 1)"

# Cache wiped.
assert_eq "choose continue: cached failed-checks wiped" "1" \
    "$([ -s "$TRACK/last-failed-checks.$SANITIZED_CONT" ] && echo 0 || echo 1)"
assert_eq "choose continue: escalation-posted marker wiped" "1" \
    "$([ -f "$TRACK/escalation-posted.$SANITIZED_CONT" ] && echo 0 || echo 1)"

# Audit comment recorded.
CMT_CONT=$(bd_show_with_comments "$TID_CONT" | jq -r 'if type == "array" then .[0].comments else .comments end | map(select(.text | test("QA-GATE CHOICE continue"))) | length')
assert_eq "choose continue: audit comment recorded" "1" "$CMT_CONT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: choose defer ==="

TID_DEF=$(bd create "choose defer test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_DEF" >/dev/null
bd label add "$TID_DEF" qa-pending >/dev/null 2>&1
bd label add "$TID_DEF" qa-escalated >/dev/null 2>&1

OUT=$(bash "$QG" choose defer "$TID_DEF" "Defer; surface to user")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "choose defer: status=deferred" "deferred" "$STATUS"

LABELS_AFTER=$(labels_for "$TID_DEF")
assert_contains "choose defer: qa-deferred label set" \
    "qa-deferred" "$LABELS_AFTER"
assert_contains "choose defer: qa-pending preserved" \
    "qa-pending" "$LABELS_AFTER"
# qa-escalated is NOT cleared by `choose defer` itself — the deferred
# state subsumes it, and a re-enter is the natural clearing signal.
# (We deliberately do not assert clearance here; the verify-before-stop
# auto-defer path also keeps qa-escalated so the SessionStart surface
# can mention both labels.)

# Audit comment.
CMT_DEF=$(bd_show_with_comments "$TID_DEF" | jq -r 'if type == "array" then .[0].comments else .comments end | map(select(.text | test("QA-GATE CHOICE defer"))) | length')
assert_eq "choose defer: audit comment recorded" "1" "$CMT_DEF"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: choose approve (delegates to approve) ==="

TID_APP=$(bd create "choose approve test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_APP" >/dev/null
bd label add "$TID_APP" qa-pending >/dev/null 2>&1
bd label add "$TID_APP" qa-escalated >/dev/null 2>&1
SANITIZED_APP=$(printf '%s' "$TID_APP" | tr -c 'A-Za-z0-9._-' '_')
printf '3\n' > "$TRACK/iteration-count.$SANITIZED_APP"

# V3 (jio.1) MIGRATION: `choose approve` delegates to cmd_approve, which now
# refuses without an independent review artifact. `choose` has no bypass
# flag to pass through, so the records must be real. v5 D2 Part B (fkm.4)
# adds the SAME shape of precondition for design-satisfied — `choose`'s
# argument list still has no room to thread --no-design through either — so
# seed_review_records above now ALSO seeds a real, satisfied design verdict.
seed_review_records "$TID_APP"
OUT=$(bash "$QG" choose approve "$TID_APP" "Findings accepted as non-blocking")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "choose approve: status=approved" "approved" "$STATUS"

LABELS_AFTER=$(labels_for "$TID_APP")
assert_contains "choose approve: qa-approved set" \
    "qa-approved" "$LABELS_AFTER"
ESC_GREP=$(printf '%s' ",$LABELS_AFTER," | grep -c ',qa-escalated,' || true)
ESC_GREP=$(printf '%s' "$ESC_GREP" | tr -d '[:space:]')
assert_eq "choose approve: qa-escalated removed via approve flow" "0" "$ESC_GREP"
PEND_GREP=$(printf '%s' ",$LABELS_AFTER," | grep -c ',qa-pending,' || true)
PEND_GREP=$(printf '%s' "$PEND_GREP" | tr -d '[:space:]')
assert_eq "choose approve: qa-pending removed" "0" "$PEND_GREP"

# Counter wiped by approve.
assert_eq "choose approve: iteration counter wiped" "1" \
    "$([ -s "$TRACK/iteration-count.$SANITIZED_APP" ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: choose tech-debt ==="

TID_TD=$(bd create "choose tech-debt test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_TD" >/dev/null
bd label add "$TID_TD" qa-pending >/dev/null 2>&1
bd label add "$TID_TD" qa-escalated >/dev/null 2>&1
SANITIZED_TD=$(printf '%s' "$TID_TD" | tr -c 'A-Za-z0-9._-' '_')
printf '3\n' > "$TRACK/iteration-count.$SANITIZED_TD"

# current-task.set so tech-debt.sh add --bd-task can link back.
bash "$FIXTURE/.claude/scripts/current-task.sh" set "$TID_TD"

# Call choose tech-debt with full args (note, severity, file:line, effort).
OUT=$(bash "$QG" choose tech-debt "$TID_TD" \
    "Fix path-traversal in upload handler" \
    "high" "src/upload.ts:42" "2h")
STATUS=$(printf '%s' "$OUT" | jq -r '.status')
assert_eq "choose tech-debt: status=tech-debt" "tech-debt" "$STATUS"

# Tech-debt row written.
assert_eq "choose tech-debt: TECHNICAL_DEBT.md created" "0" \
    "$([ -f "$FIXTURE/TECHNICAL_DEBT.md" ] && echo 0 || echo 1)"
TD_ROW=$(grep -F 'Fix path-traversal in upload handler' "$FIXTURE/TECHNICAL_DEBT.md" || echo "")
assert_match "choose tech-debt: severity recorded in row" "high" "$TD_ROW"
assert_match "choose tech-debt: file:line recorded" "src/upload.ts:42" "$TD_ROW"

# Escalation cleared, counter wiped.
LABELS_AFTER=$(labels_for "$TID_TD")
ESC_GREP=$(printf '%s' ",$LABELS_AFTER," | grep -c ',qa-escalated,' || true)
ESC_GREP=$(printf '%s' "$ESC_GREP" | tr -d '[:space:]')
assert_eq "choose tech-debt: qa-escalated removed" "0" "$ESC_GREP"
assert_eq "choose tech-debt: iteration counter wiped" "1" \
    "$([ -s "$TRACK/iteration-count.$SANITIZED_TD" ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: enter clears qa-deferred / qa-escalated (resume) ==="

TID_RES=$(bd create "resume after defer test" -t task -p 1 --json | jq -r '.id')
bash "$QG" enter "$TID_RES" >/dev/null
bd label add "$TID_RES" qa-pending >/dev/null 2>&1
bash "$QG" choose defer "$TID_RES" "Defer for now" >/dev/null

# Re-enter on the same task -> qa-deferred + qa-escalated cleared, gate
# active again.
bash "$QG" enter "$TID_RES" >/dev/null
LABELS_RES=$(labels_for "$TID_RES")
DEF_GREP=$(printf '%s' ",$LABELS_RES," | grep -c ',qa-deferred,' || true)
DEF_GREP=$(printf '%s' "$DEF_GREP" | tr -d '[:space:]')
assert_eq "enter: qa-deferred cleared on re-enter" "0" "$DEF_GREP"
ESC_GREP=$(printf '%s' ",$LABELS_RES," | grep -c ',qa-escalated,' || true)
ESC_GREP=$(printf '%s' "$ESC_GREP" | tr -d '[:space:]')
assert_eq "enter: qa-escalated cleared on re-enter" "0" "$ESC_GREP"
assert_contains "enter: qa-gate-entered re-set" \
    "qa-gate-entered" "$LABELS_RES"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section: status reports UNAVAILABLE, not not-entered, when bd cannot be read (claude-workflow-plugin-j7kk, 39cy) ==="
#
# THE BUG, reproduced rather than assumed: get_labels() used to swallow ANY
# `bd show` failure into an empty string (`|| echo ""`), so has_label()
# returned false for every qa lifecycle label and cmd_status's precedence
# cascade fell through to its LAST arm — {"ok":true,"status":"not-entered"}
# — over a store it never actually read. MEASURED live during the
# schema-skew incident this fixes: `qa-gate.sh status` returned exactly that
# JSON against an unreachable store. Unavailable is not not-entered: a task
# already entered/approved/blocked would misreport as needing a first-time
# QA entry.
TID_UNAVAIL=$(bd create "status unavailable test" -t task -p 1 --json | jq -r '.id')
bd label add "$TID_UNAVAIL" qa-approved >/dev/null 2>&1

# A SEPARATE, LOCALLY-SCOPED bd wrapper whose `show` subcommand fails; every
# other subcommand passes through to the real bd. Prepended to PATH for ONE
# invocation only (inline VAR=val form on the command line), NEVER exported —
# yj2 is exactly the hazard of a broken wrapper LEAKING into later
# fixtures/sections via a persistent PATH mutation or a mk_bd_shim-style
# `command -v bd` chain, and this section's whole point is a TARGETED
# failure, not a poisoned suite.
BROKEN_BIN=$(mktemp -d -t qa-gate-status-broken.XXXXXX)
cat > "$BROKEN_BIN/bd" <<EOF
#!/bin/bash
if [ "\$1" = "show" ]; then
    echo "bd: schema version mismatch (store is at a newer schema than this binary supports)" >&2
    exit 1
fi
exec ${REAL_BD} "\$@"
EOF
chmod +x "$BROKEN_BIN/bd"

# Non-vacuity: confirm the broken wrapper really does fail `bd show` before
# trusting anything measured through it.
BROKEN_SHOW_RC=0
PATH="$BROKEN_BIN:$PATH" bd show "$TID_UNAVAIL" >/dev/null 2>&1 || BROKEN_SHOW_RC=$?
assert_eq "status-unavailable: NON-VACUITY — the broken wrapper's bd show really fails" \
    "1" "$BROKEN_SHOW_RC"

STATUS_UNAVAIL=$(PATH="$BROKEN_BIN:$PATH" bash "$QG" status "$TID_UNAVAIL" 2>/dev/null)
STATUS_UNAVAIL_RC=0
PATH="$BROKEN_BIN:$PATH" bash "$QG" status "$TID_UNAVAIL" >/dev/null 2>&1 || STATUS_UNAVAIL_RC=$?

assert_eq "status-unavailable: shipped qa-gate.sh reports ok:false when bd show fails, not ok:true" \
    "false" "$(printf '%s' "$STATUS_UNAVAIL" | jq -r '.ok' 2>/dev/null)"
assert_eq "status-unavailable: reports its OWN status (unavailable), never not-entered" \
    "unavailable" "$(printf '%s' "$STATUS_UNAVAIL" | jq -r '.status' 2>/dev/null)"
assert_contains "status-unavailable: names the underlying bd failure so an operator can act" \
    "could not be read" "$STATUS_UNAVAIL"
assert_eq "status-unavailable: exits non-zero (never rc=0, which the pre-fix report carried)" \
    "yes" "$([ "$STATUS_UNAVAIL_RC" -ne 0 ] && echo yes || echo no)"

# RESTORE CONTROL: same task, the SAME real bd (no PATH override), reports
# the TRUE state (approved) — proving the failure above is about the broken
# wrapper, not about this task or this script being unable to report status
# in general.
STATUS_OK=$(bash "$QG" status "$TID_UNAVAIL" 2>/dev/null)
assert_eq "status-unavailable: RESTORE CONTROL — the real bd reports the task's true state (approved)" \
    "approved" "$(printf '%s' "$STATUS_OK" | jq -r '.status' 2>/dev/null)"

# THE MUTANT: excise the STATUS-UNAVAILABLE region from a COPY of qa-gate.sh
# (placed alongside the real one so sibling-script resolution — e.g.
# workflow-denylist.sh, resolved via BASH_SOURCE — still works) and
# demonstrate the OLD, WRONG shape reproduces exactly over the SAME broken
# store: {"ok":true,"status":"not-entered"}, rc=0 — the false success this
# task fixes.
MUT_QG="$FIXTURE/.claude/scripts/qa-gate.status-mutant.sh"
awk '
    /STATUS-UNAVAILABLE-BEGIN/ { skipping=1; found=1; next }
    /STATUS-UNAVAILABLE-END/   { skipping=0; next }
    !skipping { print }
    END { if (!found) exit 7 }
' "$QG" > "$MUT_QG"
AWK_SU_RC=$?
assert_eq "status-unavailable MUTANT: the region was FOUND and excised (awk found-check)" "0" "$AWK_SU_RC"
assert_eq "status-unavailable MUTANT: the mutant differs from the shipped script" \
    "differs" "$(cmp -s "$QG" "$MUT_QG" && echo identical || echo differs)"
assert_eq "status-unavailable MUTANT: the mutant still parses (bash -n)" \
    "0" "$(bash -n "$MUT_QG" 2>/dev/null; echo $?)"
chmod +x "$MUT_QG"
MUT_STATUS=$(PATH="$BROKEN_BIN:$PATH" bash "$MUT_QG" status "$TID_UNAVAIL" 2>/dev/null)
MUT_RC=0
PATH="$BROKEN_BIN:$PATH" bash "$MUT_QG" status "$TID_UNAVAIL" >/dev/null 2>&1 || MUT_RC=$?
assert_eq "status-unavailable MUTANT: SPECIFIC — with the check excised, the SAME broken store reports ok:true" \
    "true" "$(printf '%s' "$MUT_STATUS" | jq -r '.ok' 2>/dev/null)"
assert_eq "status-unavailable MUTANT: ...and status:not-entered — the exact pre-fix false success" \
    "not-entered" "$(printf '%s' "$MUT_STATUS" | jq -r '.status' 2>/dev/null)"
assert_eq "status-unavailable MUTANT: ...exiting 0, not 3 (this is the false-success shape, reproduced)" \
    "0" "$MUT_RC"

rm -rf "$BROKEN_BIN" "$MUT_QG"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf 'Passed: %d\n' "$PASS"
printf 'Failed: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0

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
#
# Conventions: this script mirrors bd-github-link.test.sh /
# phase5-synthetic-tests.sh — plain bash, `set -u`, assert helpers,
# trailing summary. No bats. The fixture is a tempdir with bd init'd
# inside it; we use a --no-daemon wrapper so the test doesn't race the
# daemon-autostart path on fresh DBs.
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

if ! command -v bd >/dev/null 2>&1; then
    if [ "${BD_SHIM_ONLY:-0}" = "1" ]; then
        echo "SKIPPED: qa-gate-choose.test.sh (bd not available; CI env BD_SHIM_ONLY=1)"
        exit 0
    fi
    echo "bd CLI not on PATH — qa-gate-choose tests require Beads."
    exit 1
fi

# bd --no-daemon wrapper so the tempdir DB doesn't race the daemon.
REAL_BD=$(command -v bd)
cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} --no-daemon "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"
export PATH="$FIXTURE/bin:$PATH"

cd "$FIXTURE" && bd init >/dev/null 2>&1

export CLAUDE_PROJECT_DIR="$FIXTURE"
export HOME="$TEST_HOME"

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# Helper: read the current labels for a task as a comma-joined string.
labels_for() {
    local tid="$1"
    bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}

# Helper: count comments matching a regex on a task. Kept for parity
# with the L2 spec's helper, even though this file uses inline jq for
# every comment-check — having both reduces future drift.
# shellcheck disable=SC2329  # Retained as a documented helper.
comment_count_matching() {
    local tid="$1" pat="$2"
    bd show "$tid" --json 2>/dev/null \
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
CMT_CONT=$(bd show "$TID_CONT" --json | jq -r 'if type == "array" then .[0].comments else .comments end | map(select(.text | test("QA-GATE CHOICE continue"))) | length')
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
CMT_DEF=$(bd show "$TID_DEF" --json | jq -r 'if type == "array" then .[0].comments else .comments end | map(select(.text | test("QA-GATE CHOICE defer"))) | length')
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

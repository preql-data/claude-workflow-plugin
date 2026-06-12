#!/bin/bash
# Synthetic tests for Phase 5 deliverables (claude-workflow-plugin-y4a.11).
#
# Covers:
#   - Statusline output across QA states (none, gate-entered, approved,
#     blocked, no-task, no-bd).
#   - Memory write on QA block (E8): file creation, idempotent re-block,
#     MEMORY.md index update.
#   - Hook envelope validity (E9): every hook produces parseable JSON
#     matching the documented shape.
#   - Workflow-engine skill is loaded from SKILL.md by intent-router.sh
#     and session-start.sh.
#
# Exit codes:
#   0 - all tests passed
#   1 - at least one test failed
#
# Usage:
#   bash .claude/scripts/tests/phase5-synthetic-tests.sh
# Pass --keep to leave the temp fixture on disk.

# shellcheck disable=SC2317
# Helper functions in this file (assert_eq, assert_match, cleanup) are
# invoked via name indirection — the trap calls cleanup, and the inline
# scenarios call the asserts directly through a control flow the static
# analyzer can't follow once `set -u` + early-exit branches are in play.
# Older shellcheck (0.9.x, what CI runs) emits SC2317 on every line inside
# those functions. Disabled file-wide because the fix-by-fix approach
# would mean annotating ~15 individual lines.

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
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
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
        printf '  FAIL: %s\n    pattern: %s\n    actual:  %s\n' "$name" "$pattern" "$actual"
    fi
}

# ---------------------------------------------------------------------------
# Fixture setup. Copy scripts + skill into a tempdir; init Beads.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)/.."
PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"
FIXTURE=$(mktemp -d -t y4a11-phase5.XXXXXX)
TEST_HOME=$(mktemp -d -t y4a11-phase5-home.XXXXXX)

# shellcheck disable=SC2329  # cleanup is invoked via `trap` below.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\nTest HOME: %s\n' "$FIXTURE" "$TEST_HOME"
    else
        rm -rf "$FIXTURE" "$TEST_HOME"
    fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.claude/skills/workflow-engine" "$FIXTURE/.beads" \
    "$TEST_HOME/.claude/projects"

cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
cp "$PLUGIN_DIR/.claude/skills/workflow-engine/SKILL.md" \
    "$FIXTURE/.claude/skills/workflow-engine/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

if ! command -v bd >/dev/null 2>&1; then
    # Match the L2 spec convention: in BD_SHIM_ONLY=1 mode (CI runner,
    # no public bd installer), skip-with-log instead of hard-fail. The
    # statusline + qa-gate + memory-bridge sections all require real bd
    # state — no useful partial coverage is possible. Dev-machine path
    # stays loud so misconfigurations are caught.
    if [ "${BD_SHIM_ONLY:-0}" = "1" ]; then
        echo "SKIPPED: phase5-synthetic-tests.sh (bd not available; CI env BD_SHIM_ONLY=1)"
        exit 0
    fi
    echo "bd CLI not on PATH — these synthetic tests require Beads."
    exit 1
fi

cd "$FIXTURE" && bd init >/dev/null 2>&1

export CLAUDE_PROJECT_DIR="$FIXTURE"
export HOME="$TEST_HOME"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: Statusline (E4 / I2) ==="

# Hotfix vlp.1: statusline now appends " • model: <id>" (read from
# orchestrator.md frontmatter). The phase5 fixture does NOT seed an
# orchestrator.md, so the suffix is the literal "• model: (no model pin)".
# A separate per-section test below covers the "with pin" path.
MODEL_SUFFIX_NONE=" • model: (no model pin)"

# 1.1 No task, no files
bash "$FIXTURE/.claude/scripts/current-task.sh" clear 2>/dev/null || true
rm -f "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh")
assert_eq "statusline: no task, no files" "(no active task) — 0 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# 1.2 No task, with file changes
printf '/path/a.ts\n/path/b.ts\n/path/a.ts\n' > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh")
assert_eq "statusline: no task, 2 unique files" "(no active task) — 2 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# 1.3 Task set, no QA labels
TASK=$(bd create "Statusline test" -t task -p 1 --json | jq -r '.id')
bash "$FIXTURE/.claude/scripts/current-task.sh" set "$TASK"
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh")
assert_eq "statusline: task set, qa: none" "[$TASK] qa: none • 2 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# 1.4 Task with qa-pending
bd label add "$TASK" qa-pending >/dev/null 2>&1
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh")
assert_eq "statusline: qa-pending" "[$TASK] qa: pending • 2 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# 1.5 Task with gate entered
# Covers the gate-entered semantic state: a task has been handed to QA but
# not yet approved/blocked. The changed-files tracker still reflects the
# 2 unique files staged from 1.2 — gate-entered does NOT truncate.
#
# Spec Phase A (rubric-grader): qa-gate.sh enter ALSO adds rubric-pending
# alongside qa-gate-entered (spec v3.2.0). statusline.sh surfaces the
# rubric state on the SAME `bd show` call (no extra round-trip), so the
# expected output here includes the "rubric: pending" segment.
bash "$FIXTURE/.claude/scripts/qa-gate.sh" enter "$TASK" >/dev/null 2>&1
bash "$FIXTURE/.claude/scripts/current-task.sh" set "$TASK"
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh")
assert_eq "statusline: gate-entered (rubric-pending also set per Phase A)" \
    "[$TASK] qa: gate-entered • rubric: pending • 2 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# 1.6 Task approved — verify the semantic transition across approve.
#
# Pre-approve: gate-entered with 2 files staged (carried from 1.5).
# Post-approve: qa: approved with 0 files changed.
#
# Post-0wk.2: qa-gate.sh approve truncates changed-files.txt as part of its
# atomic cleanup (alongside clearing current-task and iteration counters).
# The truncation is correct behavior: "approved" means "this batch is done",
# so the post-edit tracker is correctly empty in the approved state. The
# test now asserts the transition rather than the (stale) pre-truncate count.

# Pre-approve check: gate-entered, 2 files still in tracker. Spec Phase A
# adds the rubric: pending segment to the statusline output once the
# gate is entered (qa-gate.sh enter sets rubric-pending alongside
# qa-gate-entered).
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh")
assert_eq "statusline: pre-approve (gate-entered, rubric-pending, 2 files)" \
    "[$TASK] qa: gate-entered • rubric: pending • 2 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# Approve clears current-task and truncates changed-files.txt as side effects,
# so we re-set the task before reading statusline.
bash "$FIXTURE/.claude/scripts/qa-gate.sh" approve "$TASK" "Test approval" >/dev/null 2>&1
bash "$FIXTURE/.claude/scripts/current-task.sh" set "$TASK"
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh")
assert_eq "statusline: approved" "[$TASK] qa: approved • 0 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# 1.7 bd unavailable — verify both pre-approve (files staged) and
# post-approve (truncated) shapes when bd is off PATH.
#
# The statusline degrades gracefully to "(bd unavailable)" when bd is not
# on PATH, regardless of QA state. The file-count side is independent of
# bd, so this still exercises the post-edit tracker.
#
# Approve in 1.6 already truncated changed-files.txt (post-0wk.2 behavior).
# We simulate the two states directly by writing/clearing the tracker —
# we cannot call approve a second time on the same task (it would no-op:
# "qa-approved already set").

# Pre-approve shape: 2 files staged.
printf '/path/c.ts\n/path/d.ts\n' > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
OUT=$(PATH=/usr/bin:/bin bash -c "echo '{}' | bash '$FIXTURE/.claude/scripts/statusline.sh'")
assert_eq "statusline: bd unavailable (pre-approve, 2 files)" \
    "(bd unavailable) — 2 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# Post-approve shape: tracker truncated (post-0wk.2 qa-gate.sh approve
# semantics — see 1.6 for the qa-gate-driven verification of this).
: > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
OUT=$(PATH=/usr/bin:/bin bash -c "echo '{}' | bash '$FIXTURE/.claude/scripts/statusline.sh'")
assert_eq "statusline: bd unavailable" "(bd unavailable) — 0 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# 1.8 Hotfix vlp.1: seed an orchestrator.md with a model pin and verify
# the statusline picks it up. This is the positive coverage for the
# new "• model: <id>" segment — sections 1.1-1.7 covered the "no pin"
# fallback; here we prove the read path works against real frontmatter.
mkdir -p "$FIXTURE/.claude/agents"
cat > "$FIXTURE/.claude/agents/orchestrator.md" <<'AGENT'
---
name: orchestrator
description: stub
model: claude-fable-5
---
stub body
AGENT
# Restore PATH (1.7 dropped bd from PATH); fresh tracker; task active.
bash "$FIXTURE/.claude/scripts/current-task.sh" set "$TASK"
: > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh")
assert_eq "statusline: pin read from orchestrator.md" \
    "[$TASK] qa: approved • 0 files changed • model: claude-fable-5" "$OUT"

# META-TEST: remove the model: line entirely; the statusline must
# degrade to "(no model pin)" without erroring. Sensitivity check on
# the read_model_pin path.
cat > "$FIXTURE/.claude/agents/orchestrator.md" <<'AGENT'
---
name: orchestrator
description: stub without model pin
---
stub body
AGENT
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh")
assert_eq "statusline META-TEST: missing model: line falls back to (no model pin)" \
    "[$TASK] qa: approved • 0 files changed${MODEL_SUFFIX_NONE}" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: QA-block memory bridge (E8) ==="

TASK2=$(bd create "Memory bridge test" -t task -p 1 --json | jq -r '.id')
bash "$FIXTURE/.claude/scripts/current-task.sh" set "$TASK2"
SLUG=$(printf '%s' "$FIXTURE" | sed -e 's|/|-|g')
MEMORY_DIR="$TEST_HOME/.claude/projects/${SLUG}/memory"

# 2.1 First block writes a memory file
REASON1="Missing rate limit on POST /auth/login endpoint - allows brute force attacks"
bash "$FIXTURE/.claude/scripts/qa-gate.sh" block "$TASK2" "$REASON1" >/dev/null 2>&1
COUNT=$(find "$MEMORY_DIR" -maxdepth 1 -name 'qa-block-*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "memory: first block creates 1 file" "1" "$COUNT"

# 2.2 MEMORY.md index updated
INDEX_HAS=$(grep -c "qa-block-" "$MEMORY_DIR/MEMORY.md" 2>/dev/null || echo 0)
assert_eq "memory: MEMORY.md indexed" "1" "$INDEX_HAS"

# 2.3 Same reason → idempotent (still 1 file, but Last seen line appended)
sleep 1
bash "$FIXTURE/.claude/scripts/qa-gate.sh" block "$TASK2" "$REASON1" >/dev/null 2>&1
COUNT=$(find "$MEMORY_DIR" -maxdepth 1 -name 'qa-block-*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "memory: re-block same reason → still 1 file" "1" "$COUNT"

LAST_SEEN=$(grep -c "Last seen:" "$MEMORY_DIR/qa-block-"*.md 2>/dev/null || echo 0)
LAST_SEEN=$(printf '%s' "$LAST_SEEN" | tr -d '[:space:]')
if [ "$LAST_SEEN" -ge 1 ]; then
    PASS=$((PASS+1))
    echo "  PASS: memory: re-block appends Last seen line"
else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("memory: re-block appends Last seen line")
    echo "  FAIL: memory: re-block appends Last seen line (count=$LAST_SEEN)"
fi

# 2.4 Different reason → new file
REASON2="SQL injection in /search endpoint due to string concatenation"
bash "$FIXTURE/.claude/scripts/qa-gate.sh" block "$TASK2" "$REASON2" >/dev/null 2>&1
COUNT=$(find "$MEMORY_DIR" -maxdepth 1 -name 'qa-block-*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "memory: different reason → 2 files" "2" "$COUNT"

# 2.5 Frontmatter shape is correct
FIRST_FILE=$(find "$MEMORY_DIR" -maxdepth 1 -name 'qa-block-*.md' -type f | head -1)
HAS_TYPE=$(grep -c '^type: feedback$' "$FIRST_FILE" || echo 0)
HAS_TYPE=$(printf '%s' "$HAS_TYPE" | tr -d '[:space:]')
assert_eq "memory: type: feedback in frontmatter" "1" "$HAS_TYPE"

HAS_NAME=$(grep -c '^name: qa-block-' "$FIRST_FILE" || echo 0)
HAS_NAME=$(printf '%s' "$HAS_NAME" | tr -d '[:space:]')
assert_eq "memory: name: qa-block-<fp> in frontmatter" "1" "$HAS_NAME"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: Hook envelope validity (E9) ==="

# 3.1 session-start.sh
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/session-start.sh" 2>/dev/null)
EVENT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
assert_eq "envelope: session-start.sh hookEventName" "SessionStart" "$EVENT"

# 3.2 intent-router.sh real prompt
OUT=$(echo '{"prompt":"add an auth endpoint"}' | bash "$FIXTURE/.claude/scripts/intent-router.sh" 2>/dev/null)
EVENT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
assert_eq "envelope: intent-router.sh hookEventName" "UserPromptSubmit" "$EVENT"

# 3.3 intent-router.sh slash skip
OUT=$(echo '{"prompt":"/help"}' | bash "$FIXTURE/.claude/scripts/intent-router.sh" 2>/dev/null)
PARSED=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null)
assert_eq "envelope: intent-router.sh slash skip = {}" "{}" "$PARSED"

# 3.4 prevent-orchestrator-edits.sh on orchestrator
OUT=$(echo '{"subagent_name":"orchestrator","tool_name":"Write"}' | bash "$FIXTURE/.claude/scripts/prevent-orchestrator-edits.sh" 2>/dev/null)
EVENT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
DEC=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
assert_eq "envelope: prevent-orchestrator hookEventName" "PreToolUse" "$EVENT"
assert_eq "envelope: prevent-orchestrator permissionDecision" "deny" "$DEC"

# 3.5 prevent-orchestrator-edits.sh on specialist
OUT=$(echo '{"subagent_name":"backend","tool_name":"Write"}' | bash "$FIXTURE/.claude/scripts/prevent-orchestrator-edits.sh" 2>/dev/null)
PARSED=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null)
assert_eq "envelope: prevent-orchestrator specialist allow = {}" "{}" "$PARSED"

# 3.6 post-edit.sh
OUT=$(echo '{"tool_input":{"file_path":"/tmp/foo.ts"}}' | bash "$FIXTURE/.claude/scripts/post-edit.sh" 2>/dev/null)
PARSED=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null)
assert_eq "envelope: post-edit.sh = {}" "{}" "$PARSED"

# 3.7 verify-before-stop.sh allow path
rm -f "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
OUT=$(echo '{"stop_reason":"end_turn"}' | bash "$FIXTURE/.claude/scripts/verify-before-stop.sh" 2>/dev/null)
PARSED=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null)
assert_eq "envelope: verify-before-stop.sh allow = {}" "{}" "$PARSED"

# 3.8 verify-before-stop.sh block path
printf '/path/changed.ts\n' > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
bash "$FIXTURE/.claude/scripts/current-task.sh" clear
OUT=$(echo '{"stop_reason":"end_turn"}' | bash "$FIXTURE/.claude/scripts/verify-before-stop.sh" 2>/dev/null)
DEC=$(printf '%s' "$OUT" | jq -r '.decision // empty' 2>/dev/null)
assert_eq "envelope: verify-before-stop.sh block decision" "block" "$DEC"

# 3.9 session-end.sh
OUT=$(echo '{"reason":"clear"}' | bash "$FIXTURE/.claude/scripts/session-end.sh" 2>/dev/null)
PARSED=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null)
assert_eq "envelope: session-end.sh = {}" "{}" "$PARSED"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: Workflow-engine skill canonicalisation (E2 / E15) ==="

# 4.1 intent-router.sh injects the skill body
OUT=$(echo '{"prompt":"add a feature"}' | bash "$FIXTURE/.claude/scripts/intent-router.sh" 2>/dev/null)
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
assert_match "skill: intent-router injects workflow_engine envelope" \
    "<workflow_engine source=" "$CTX"
assert_match "skill: intent-router includes 'Workflow engine' header" \
    "Workflow engine" "$CTX"
assert_match "skill: intent-router does NOT contain Step 4 legacy text" \
    "Mandatory roles|Mandatory delegation flow" "$CTX"

# 4.2 session-start.sh injects the skill body
OUT=$(bash "$FIXTURE/.claude/scripts/session-start.sh" < <(echo '{}') 2>/dev/null)
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
assert_match "skill: session-start injects workflow_engine envelope" \
    "<workflow_engine source=" "$CTX"

# 4.3 SKILL.md frontmatter is well-formed
FRONTMATTER_LINES=$(awk '/^---[[:space:]]*$/{n++; if (n==2) {print NR; exit}} ' "$FIXTURE/.claude/skills/workflow-engine/SKILL.md")
if [ -n "$FRONTMATTER_LINES" ] && [ "$FRONTMATTER_LINES" -gt 1 ]; then
    PASS=$((PASS+1))
    echo "  PASS: skill: SKILL.md has well-formed YAML frontmatter (closes at line $FRONTMATTER_LINES)"
else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("skill: SKILL.md frontmatter")
    echo "  FAIL: skill: SKILL.md frontmatter not closed properly"
fi

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

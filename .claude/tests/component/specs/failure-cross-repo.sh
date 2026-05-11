#!/bin/bash
# failure-cross-repo.sh - Phase D failure-injection spec.
#
# Cross-references:
#   - G8 plan, "Failure-injection surface" §4 (intent-routing-cross-repo)
#   - claude-workflow-plugin-0wk.13 (Phase D)
#   - verify-before-stop.sh component spec (baseline coverage)
#   - I8 (Phase 6b) cross-repo guard in verify-before-stop.sh
#
# Tier decision: L2 component. The cross-repo guard is a pure
# bash-script branch in verify-before-stop.sh that compares the
# .qa-tracking/current-task.repo file against `git rev-parse
# --show-toplevel`. No LLM behaviour is involved — it's all reading
# files and emitting a block envelope. A live test would just be paying
# $5-10 to re-prove what 100ms of stdin-fed bash can prove deterministically.
#
# This spec strengthens the existing verify-before-stop.sh cross-repo
# coverage with:
#
#   1. The "claimed task in repo A, Stop fires in repo B" scenario the
#      brief describes — pre-seed current-task.repo with a fingerprint
#      that DIFFERS from the fixture's actual git toplevel. Verify the
#      gate emits `decision: "block"` with the I8 block-reason text
#      naming all 3 numbered recovery options.
#
#   2. Each of the three recovery options is structurally present
#      (numbered "1.", "2.", "3."), and each contains the actionable
#      bash incantation the human (or Claude) is expected to run. This
#      is the I8 spec contract from Phase 6.
#
#   3. The regression-injection meta-test (Phase D acceptance bar): if
#      we delete the recorded-repo file, the cross-repo guard MUST
#      short-circuit to the "no recorded repo → degrade silently"
#      behaviour and STOP blocking on this signal. That proves the
#      block above is being driven by the cross-repo branch
#      specifically, not by some unrelated block path that happened to
#      fire.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# --------------------------------------------------------------------------
# Setup: a real Beads task + recorded repo fingerprint that POINTS AT A
# DIFFERENT REPO than the fixture's git toplevel. The fixture's mk_fixture
# already initialises a .git inside the fixture path; we record a clearly
# different absolute path as the "task's repo".
# --------------------------------------------------------------------------
TID=$(cd "$FIXTURE" && bd create "Cross-repo failure-injection task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
assert_match "failure-cross-repo: task created" '^[a-z0-9-]+\.' "$TID"
bash "$CT" set "$TID"

# Initialise git inside the fixture so the gate's `git rev-parse
# --show-toplevel` returns something (otherwise the comparison gets
# skipped via the "cwd not a git repo" early-exit). The fixture might
# already have .git from mk_fixture's `bd init` flow; either way `git
# init` is idempotent.
(cd "$FIXTURE" && git init -q 2>/dev/null) || true

# Spoof the recorded repo fingerprint. Use a clearly-fake absolute path
# so any accidental match against the real fixture path is impossible.
printf '/tmp/some-other-fake-repo\n' > "$TRACK/current-task.repo"

# Seed a tracked code change so the gate doesn't short-circuit on
# "no changes detected".
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"

# --------------------------------------------------------------------------
# 1. Cross-repo Stop fires → decision: "block" with the I8 reason text.
# --------------------------------------------------------------------------
OUT=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS")
assert_decision "failure-cross-repo: cross-repo Stop blocks" "$OUT" "block"

REASON=$(printf '%s' "$OUT" | jq -r '.reason // empty')
assert_contains "failure-cross-repo: reason mentions 'Cross-repo'" "Cross-repo" "$REASON"
assert_contains "failure-cross-repo: reason names recorded repo path" \
    "/tmp/some-other-fake-repo" "$REASON"
assert_contains "failure-cross-repo: reason mentions I8" "I8" "$REASON"

# --------------------------------------------------------------------------
# 2. The three numbered recovery options (I8 spec contract). The reason
# must include the three structured option lines so the orchestrator/QA
# agent can pick a recovery path.
# --------------------------------------------------------------------------
assert_match "failure-cross-repo: option 1. present" "^[[:space:]]+1\\." "$REASON"
assert_match "failure-cross-repo: option 2. present" "^[[:space:]]+2\\." "$REASON"
assert_match "failure-cross-repo: option 3. present" "^[[:space:]]+3\\." "$REASON"

# Option 1 must instruct cd into the other repo. Option 3 must reference
# the reset incantation (`current-task.sh clear` + `qa-gate.sh enter`)
# so the recovery path is actionable, not just descriptive.
assert_contains "failure-cross-repo: option 1 includes 'cd into' instruction" \
    "cd into /tmp/some-other-fake-repo" "$REASON"
assert_contains "failure-cross-repo: option 3 includes current-task.sh clear" \
    "current-task.sh clear" "$REASON"
assert_contains "failure-cross-repo: option 3 includes qa-gate.sh enter" \
    "qa-gate.sh enter" "$REASON"

# --------------------------------------------------------------------------
# 3. Side-effect: the cross-repo block must NOT auto-close the task. If
# it did, a Stop fired in the wrong repo would silently close work in
# the right repo — the bug I8 was designed to prevent. We verify by
# reading the task status post-Stop.
# --------------------------------------------------------------------------
STATUS=$(cd "$FIXTURE" && bd show "$TID" --json 2>/dev/null | jq -r 'if type=="array" then .[0].status else .status end')
# The fixture's task starts in `open` (bd default) and never transitions
# to `in_progress` because we never explicitly start it. What matters for
# the I8 guard is that the cross-repo block does NOT silently close it —
# i.e. the status must remain non-closed (open OR in_progress, never
# `closed`). The reason text further attests "no labels touched, no
# status changes" so we belt-and-brace by also asserting on a non-closed
# value.
case "$STATUS" in
    closed|completed|done)
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("failure-cross-repo: task auto-closed after cross-repo block (status=$STATUS)")
        printf '  FAIL: failure-cross-repo: task auto-closed after cross-repo block (status=%s)\n' "$STATUS"
        ;;
    *)
        PASS=$((PASS + 1))
        printf '  PASS: failure-cross-repo: task NOT auto-closed after cross-repo block (status=%s)\n' "$STATUS"
        ;;
esac

# --------------------------------------------------------------------------
# 4. Regression-injection meta-test (Phase D acceptance bar).
#
# Remove the recorded-repo file. The gate's `detect_cross_repo()` then
# short-circuits to "no recorded repo → degrade silently" (which is the
# documented pre-I8 behaviour for users without per-task repo tracking).
# The SAME envelope must NOT carry a cross-repo block. It may carry a
# different kind of block (no QA approval, etc.) — what matters is that
# the cross-repo branch ISN'T the firing path.
#
# If this section fails (the cross-repo block fires even with no recorded
# repo), the previous asserts were probably triggering a different code
# path entirely and the harness has a bug.
# --------------------------------------------------------------------------
rm -f "$TRACK/current-task.repo"
# Keep changed-files.txt so we still hit the "changes + task" path.

OUT2=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1)
# The envelope is the LAST JSON-shaped line — `bd update`'s stdout can
# bleed into stdout during qa-gate side effects.
LAST=$(printf '%s' "$OUT2" | tail -1)
LAST_COMPACT=$(printf '%s' "$LAST" | jq -c '.' 2>/dev/null || echo "NOT_JSON")

# Two acceptable outcomes for the meta-test:
#  (a) `{}` — no block at all (everything else also short-circuited).
#  (b) A block whose reason does NOT mention "Cross-repo".
# Either proves the cross-repo branch isn't firing. We reject ONLY the
# case where Cross-repo appears in the reason.
META_REASON=$(printf '%s' "$LAST_COMPACT" | jq -r '.reason // ""' 2>/dev/null || echo "")
if printf '%s' "$META_REASON" | grep -qF "Cross-repo"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("failure-cross-repo: META-TEST regression — cross-repo still firing without recorded-repo file")
    printf '  FAIL: failure-cross-repo: META-TEST regression — cross-repo still firing without recorded-repo file\n    last envelope: %s\n' "$LAST_COMPACT"
else
    PASS=$((PASS + 1))
    printf '  PASS: failure-cross-repo: META-TEST — removing recorded-repo file disables cross-repo branch\n'
fi

[ "$FAIL" -eq 0 ]

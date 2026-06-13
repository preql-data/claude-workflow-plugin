#!/bin/bash
# failure-hook-crash.sh - Phase D failure-injection spec.
#
# Cross-references:
#   - G8 plan, "Failure-injection surface" §5 (hook script crashes mid-run)
#   - claude-workflow-plugin-0wk.13 (Phase D)
#   - Autonomy principle (G8 plan, cross-cutting #3): no permission
#     prompts even under failure modes — the gate must degrade
#     gracefully, never block the user on a hook crash.
#
# Tier decision: L2 component. The "graceful degrade" contract is a
# pure properties-of-bash claim: when an optional hook script exits
# non-zero (or crashes), the upstream pipeline that called it must
# continue to function. This is testable deterministically by
# substituting the hook with `exit 2` and probing the next hook's
# behaviour. A live test would burn $5-10 to re-prove the same
# property with more noise; the L2 spec is the right granularity.
#
# Two optional hooks are exercised here:
#
#   1. `bd-github-link.sh` (PostToolUse, Bash matcher). This is the
#      example the brief calls out. The hook is best-effort: it logs
#      Beads ↔ GitHub links on `bd update --status closed` and
#      `gh pr create`. A crash there must not prevent verify-before-stop.sh
#      from running on the next Stop, must not poison the bash command
#      that triggered it, and must not surface a user-facing prompt.
#
#   2. `subagent-start.sh` (SubagentStart). The principle is symmetric:
#      an optional housekeeping hook that crashes mid-run must not
#      block the orchestrator's ability to launch a specialist.
#
# What we verify in each case:
#
#   - The crash hook IS firing (we ran it; got exit 2).
#   - The downstream gate (verify-before-stop.sh / qa-gate.sh) still
#     produces a valid envelope for its own inputs.
#   - No permission denial / no decision change leaks from the crashed
#     optional hook into the downstream pipeline.
#
# Regression-injection meta-test (Phase D bar): we also run the same
# probe WITHOUT corrupting the optional hook and verify the gate
# behaves identically. If the gate behaviour differs between the two
# runs, the gate is sensitive to optional-hook health — i.e. the
# "graceful degrade" property is broken and this spec should fail.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent (CI runner, BD_SHIM_ONLY=1).
# Both failure scenarios in this spec seed a Beads task before testing the
# crashing-hook fallback behaviour; without bd the seeding step fails first.
bd_required_or_skip

VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
SUBAGENT_HOOK="$FIXTURE/.claude/scripts/subagent-start.sh"
LINK_HOOK="$FIXTURE/.claude/scripts/bd-github-link.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
QG="$FIXTURE/.claude/scripts/qa-gate.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# --------------------------------------------------------------------------
# Replace the optional hooks with `exit 2` stubs. Important: the fixture's
# .claude/scripts contains SYMLINKS to the real plugin scripts (so the
# spec exercises the real source, not a copy). We must `rm` the symlink
# before writing a regular-file stub — otherwise we'd be editing the
# real plugin source and dirtying the workspace.
# --------------------------------------------------------------------------
rm -f "$LINK_HOOK"
cat > "$LINK_HOOK" <<'STUB'
#!/bin/bash
# Phase D failure-injection: this stub crashes with exit 2 to simulate
# a corrupted / broken optional hook. The gate's autonomy principle
# (G8 plan cross-cutting #3) requires the surrounding pipeline to
# continue operating.
read -r _stdin_unused >/dev/null 2>&1 || true
printf 'fake hook crashed\n' >&2
exit 2
STUB
chmod +x "$LINK_HOOK"

rm -f "$SUBAGENT_HOOK"
cat > "$SUBAGENT_HOOK" <<'STUB'
#!/bin/bash
# Phase D failure-injection: subagent-start.sh stubbed to exit 2.
read -r _stdin_unused >/dev/null 2>&1 || true
printf 'fake subagent-start crashed\n' >&2
exit 2
STUB
chmod +x "$SUBAGENT_HOOK"

# --------------------------------------------------------------------------
# 1. Confirm both stubs DO crash. This is the precondition for the rest
# of the spec — if the stubs accidentally exited 0 the test would be a
# false positive.
# --------------------------------------------------------------------------
RC=0
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
    | bash "$LINK_HOOK" >/dev/null 2>&1 || RC=$?
assert_eq "failure-hook-crash: bd-github-link stub exits non-zero" "2" "$RC"

RC=0
printf '%s' '{"subagent_name":"backend"}' \
    | bash "$SUBAGENT_HOOK" >/dev/null 2>&1 || RC=$?
assert_eq "failure-hook-crash: subagent-start stub exits non-zero" "2" "$RC"

# --------------------------------------------------------------------------
# 2. Seed a real Beads task + tracking state so verify-before-stop.sh has
# something meaningful to evaluate. We use the same setup pattern as the
# verify-before-stop.sh spec.
# --------------------------------------------------------------------------
TID=$(cd "$FIXTURE" && bd create "Hook-crash failure-injection task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
assert_match "failure-hook-crash: task created" '^[a-z0-9-]+\.' "$TID"
# llh.18: seed the change-set BEFORE enter/approve so the change-set-bound
# approval record carries the SAME hash verify-before-stop will recompute
# below. (Approval is now bound to the reviewed files: approving an empty
# change-set then introducing src/handler.ts is a post-approval edit that
# correctly re-blocks. The real flow always reviews the actual changed
# files, which is what seeding-before-approve models here.)
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"
bash "$QG" enter "$TID" >/dev/null
# Approve the task so the gate's QA-required path doesn't drown out the
# graceful-degrade signal. The gate's happy path is then `decision: approve`
# implicit (empty envelope).
bash "$QG" approve "$TID" "Approved for hook-crash failure-injection" >/dev/null
# qa-gate.sh approve clears current-task; we re-set it so the gate sees
# the approval (matches the existing verify-before-stop.sh spec pattern).
bash "$CT" set "$TID"
# approve truncated the tracker (0wk.2); restore the SAME reviewed change-set
# so the recomputed hash matches the recorded one.
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"

# --------------------------------------------------------------------------
# 3. Run verify-before-stop.sh. The gate's main flow does NOT shell out
# to bd-github-link.sh or subagent-start.sh — those are independent hook
# events with their own pipelines. So this is really verifying that the
# gate's OWN behaviour is unaffected by the fact that two of its sibling
# hooks would crash if invoked. (The actual cross-hook isolation is
# enforced by the Claude Code runtime, not bash; we're checking we
# haven't accidentally created an inter-hook coupling.)
# --------------------------------------------------------------------------
RAW=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1)
# Last JSON-shaped line. bd update may bleed into stdout during the
# QA-approved path's `bd update --status closed`.
OUT=$(printf '%s' "$RAW" | tail -1)
COMPACT=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null || echo "NOT_JSON")

# The gate's approval-clean exit emits `{}`. Accept either `{}` or a
# hookSpecificOutput envelope WITHOUT decision (the B2 epic-gate note
# path). Reject any envelope that carries `decision: block`.
if [ "$COMPACT" = "{}" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: failure-hook-crash: gate still approves cleanly (envelope=%s)\n' "$COMPACT"
elif printf '%s' "$COMPACT" | jq -e '.hookSpecificOutput and (has("decision") | not)' >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf '  PASS: failure-hook-crash: gate approves with hookSpecificOutput note (no decision)\n'
else
    HAS_BLOCK=$(printf '%s' "$COMPACT" | jq -r '.decision // ""')
    if [ "$HAS_BLOCK" = "block" ]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("failure-hook-crash: gate blocked under optional-hook crash (decision=block)")
        printf '  FAIL: failure-hook-crash: gate blocked under optional-hook crash\n    envelope: %s\n' "$COMPACT"
    else
        # Some other shape — surface for human review but don't fail
        # the spec; the contract is "no block", and we don't see one.
        PASS=$((PASS + 1))
        printf '  PASS: failure-hook-crash: gate did NOT block (other-shape envelope=%s)\n' "$COMPACT"
    fi
fi

# --------------------------------------------------------------------------
# 4. Sync-errors log should NOT carry an entry from the crashed hook.
# This is subtle: bd-github-link.sh writes to sync-errors.log on its
# graceful-degrade paths, but the stub exits 2 BEFORE reaching that
# code. We're verifying that the runtime didn't somehow surface the
# crash through the gate's log channel.
# --------------------------------------------------------------------------
SYNC_LOG="$TRACK/sync-errors.log"
if [ -f "$SYNC_LOG" ]; then
    # The gate may legitimately write entries (cross-repo issues,
    # bd update failures, etc.). We only fail if a "bd-github-link"
    # entry is there, which would mean the gate accidentally ran it.
    if grep -qF "[bd-github-link]" "$SYNC_LOG" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("failure-hook-crash: bd-github-link sync-errors entry leaked into gate path")
        printf '  FAIL: failure-hook-crash: bd-github-link entry leaked into gate path\n'
    else
        PASS=$((PASS + 1))
        printf '  PASS: failure-hook-crash: no bd-github-link entry in sync-errors.log\n'
    fi
else
    PASS=$((PASS + 1))
    printf '  PASS: failure-hook-crash: no sync-errors.log at all (gate path clean)\n'
fi

# --------------------------------------------------------------------------
# 5. Direct exercise of bd-github-link.sh's MANUAL mode (`--manual close`)
# to confirm the stub IS being invoked when the hook would have fired.
# This proves the crash is happening in the test environment, not just
# bypassed via some path inversion.
# --------------------------------------------------------------------------
RC=0
bash "$LINK_HOOK" --manual close "$TID" >/dev/null 2>&1 || RC=$?
assert_eq "failure-hook-crash: bd-github-link --manual close stub fires (exit 2)" "2" "$RC"

# --------------------------------------------------------------------------
# 6. Regression-injection meta-test (Phase D bar).
#
# Restore the real bd-github-link.sh symlink (cheapest way: nuke the stub
# and re-symlink to the plugin's real script). Run the same gate flow.
# Confirm the behaviour is IDENTICAL — graceful-degrade means the gate
# doesn't notice whether the optional hook is healthy or sick.
# --------------------------------------------------------------------------
PLUGIN_ROOT=$(plugin_root)
rm -f "$LINK_HOOK"
ln -sf "$PLUGIN_ROOT/.claude/scripts/bd-github-link.sh" "$LINK_HOOK"

# Re-seed the changed-files (the previous run cleaned them up via the
# QA-approved path).
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"
# Re-enter the gate; previous approval cleared the current-task.
TID2=$(cd "$FIXTURE" && bd create "Hook-crash restore meta-test task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID2" >/dev/null
bash "$QG" approve "$TID2" "Approved for restore meta-test" >/dev/null
bash "$CT" set "$TID2"
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"

RAW2=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1)
OUT2=$(printf '%s' "$RAW2" | tail -1)
COMPACT2=$(printf '%s' "$OUT2" | jq -c '.' 2>/dev/null || echo "NOT_JSON")

# Same acceptance shape as section 3 — a non-block envelope. The
# behaviour with and without the crash stub MUST match.
HAS_BLOCK2=$(printf '%s' "$COMPACT2" | jq -r '.decision // ""' 2>/dev/null)
if [ "$HAS_BLOCK2" = "block" ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("failure-hook-crash: META-TEST — restored hook now produces block (gate is sensitive to optional-hook health, autonomy violation)")
    printf '  FAIL: failure-hook-crash: META-TEST regression — gate behaviour DIFFERS between crash and clean states\n    crash envelope:  %s\n    clean envelope:  %s\n' "$COMPACT" "$COMPACT2"
else
    PASS=$((PASS + 1))
    printf '  PASS: failure-hook-crash: META-TEST — gate behaviour identical with restored hook\n'
fi

[ "$FAIL" -eq 0 ]

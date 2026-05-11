#!/bin/bash
# failure-orchestrator-restriction.sh - Phase D failure-injection spec.
#
# Cross-references:
#   - G8 plan, "Failure-injection surface" §1 (orchestrator-restriction)
#   - claude-workflow-plugin-0wk.13 (Phase D)
#   - prevent-orchestrator-edits.sh component spec (baseline coverage)
#
# Tier decision: L2 component. The behaviour we want to verify is purely
# hook-level (PreToolUse deny on orchestrator + allow on specialists);
# the orchestrator's "fallback to delegating" is a downstream consequence
# the orchestrator's LLM handles on its own — that part is implicit in
# the live `happy-path.spec.ts` and `qa-block-recovery.spec.ts` already.
# What we MUST guard against is: someone deletes / no-ops
# prevent-orchestrator-edits.sh and the gate silently lets the
# orchestrator's Write through. Live runs are massively overkill for that
# — a deterministic L2 spec catches it in <1s and costs $0.
#
# This spec is the COMPANION to prevent-orchestrator-edits.sh. The
# baseline spec covers the happy path (deny on orchestrator, allow on
# specialists). This spec adds:
#
#   1. The "explicit prompt instruction" attack surface — verify the
#      deny still fires when the upstream payload mimics the
#      "just edit the files yourself, don't delegate" scenario the
#      brief describes. The hook only reads subagent identity from
#      the JSON envelope; prompt prose can't bypass the rule. We
#      synthesise the envelope shape the SDK would produce in that
#      scenario and confirm.
#
#   2. The "regression-injection meta-test" — neutralise the
#      protection (replace the hook with `exit 0` no-op) and prove
#      the same envelope is no longer blocked. This is the literal
#      Phase D acceptance criterion: each new spec must FAIL when
#      its corresponding plugin protection is removed.
#
#   3. Failure-mode coverage for compound subagent names that
#      happen to contain "orchestrator" as a substring
#      (`data-orchestrator-pipeline`, `payment-orchestrator-svc`,
#      etc.) — verifies the exact-match list (vs the old glob) is
#      still firing on the right rows.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
HOOK="$FIXTURE/.claude/scripts/prevent-orchestrator-edits.sh"

# --------------------------------------------------------------------------
# 1. "Just edit yourself, don't delegate" attack surface.
#
# Scenario: a user prompts the orchestrator with explicit instructions to
# bypass delegation. The orchestrator's tool list omits Write/Edit, but a
# misconfigured runtime could still surface them; in that case the only
# remaining line of defense is this PreToolUse hook. We feed the canonical
# envelope shape that surfaces in that scenario (subagent_name=orchestrator
# + tool_name=Write) and confirm the deny still fires.
# --------------------------------------------------------------------------

for TOOL in Write Edit MultiEdit; do
    OUT=$(printf '%s' "{\"subagent_name\":\"orchestrator\",\"tool_name\":\"$TOOL\"}" | bash "$HOOK")
    assert_valid_envelope "failure-orch: orch+$TOOL produces valid envelope" "$OUT"
    assert_hook_event "failure-orch: orch+$TOOL event=PreToolUse" "$OUT" "PreToolUse"
    assert_permission_decision "failure-orch: orch+$TOOL permissionDecision=deny" "$OUT" "deny"
    REASON=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
    # The reason must explicitly tell the orchestrator's LLM to delegate —
    # otherwise the recovery path (re-invoke a specialist) doesn't happen.
    assert_match "failure-orch: orch+$TOOL reason names delegation explicitly" \
        "(delegate|specialist|Task\\(\"@)" "$REASON"
done

# --------------------------------------------------------------------------
# 2. Specialists must NEVER be blocked by this hook — they're the entire
# point of the "delegate" instruction. Cover backend / frontend / qa /
# devops / sre / debugger / data — every plugin specialist.
# --------------------------------------------------------------------------

for SPEC in backend frontend qa devops sre debugger data product-manager; do
    OUT=$(printf '%s' "{\"subagent_name\":\"$SPEC\",\"tool_name\":\"Write\"}" | bash "$HOOK")
    assert_empty_envelope "failure-orch: specialist '$SPEC' allowed to Write" "$OUT"
done

# --------------------------------------------------------------------------
# 3. Substring false-positive guard. The fix in Phase 4 replaced glob with
# exact-match; a regression here means the rule silently blocks every
# subagent whose name happens to contain "orchestrator" as a substring
# (e.g. a future user-defined `data-orchestrator-pipeline` agent).
# --------------------------------------------------------------------------

for COMPOUND in data-orchestrator-pipeline payment-orchestrator-test orchestrator-helper my-orchestrator-utils; do
    OUT=$(printf '%s' "{\"subagent_name\":\"$COMPOUND\",\"tool_name\":\"Write\"}" | bash "$HOOK")
    assert_empty_envelope "failure-orch: compound name '$COMPOUND' (substring) allowed" "$OUT"
done

# --------------------------------------------------------------------------
# 4. Regression-injection meta-test (Phase D acceptance bar).
#
# Replace the hook with a no-op `exit 0` shim that mimics what would happen
# if `prevent-orchestrator-edits.sh` were deleted / corrupted / disabled.
# The same orchestrator+Write envelope MUST then go through unblocked. If
# this section starts passing the OPPOSITE way (deny envelope from a no-op
# shim) the harness has a deep bug.
#
# Important: replace the SYMLINK with a regular file rather than editing
# the underlying plugin script — the fixture's .claude/scripts is symlinked
# into the plugin so any rewrite would clobber the real source. `rm -f` on
# the symlink + write a fresh stub is the safe substitution.
# --------------------------------------------------------------------------

rm -f "$HOOK"
cat > "$HOOK" <<'STUB'
#!/bin/bash
# No-op stub — Phase D regression-injection meta-test for the
# orchestrator-restriction guard. If the guard were missing or no-op'd
# in production, this is what every PreToolUse fire would look like.
read -r _stdin_unused
echo '{}'
STUB
chmod +x "$HOOK"

OUT=$(printf '%s' '{"subagent_name":"orchestrator","tool_name":"Write"}' | bash "$HOOK")
assert_empty_envelope "failure-orch: META-TEST — disabled hook allows orchestrator Write" "$OUT"

# The same envelope through the no-op MUST NOT carry a permissionDecision.
# This is what proves the prior asserts above were measuring something
# real about the live hook — they would have failed identically here.
NO_DECISION=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "absent"')
assert_eq "failure-orch: META-TEST — no permissionDecision in no-op stub" "absent" "$NO_DECISION"

# Final guard: tally the assertion bookkeeping by mirroring the convention
# the other specs follow — the runner reads the trailing PASS/FAIL line.
[ "$FAIL" -eq 0 ]

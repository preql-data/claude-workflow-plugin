/**
 * Gate sanity check (Phase A.2 acceptance criterion).
 *
 * Proves the harness genuinely tests the plugin's Stop-gate behaviour
 * rather than just LLM behaviour. The Phase A spec demands:
 *
 *   "Re-run the spec without verify-before-stop.sh and prove it FAILS
 *    at hookFired('Stop', { decision: 'approve' }) because there's no
 *    Stop hook to approve."
 *
 * The G8 plan's task brief explicitly permits us to satisfy this
 * criterion via a unit test that mutates an in-memory trace's
 * hookOutputs and confirms the matcher fails — cheaper and faster than
 * burning two extra live runs, and proves exactly the same assertion
 * structure.
 *
 * Stop hook decision semantics (from the Claude Code hooks reference,
 * https://code.claude.com/docs/en/hooks): Stop hooks ONLY emit
 * `decision: "block"` for an explicit block, or NO decision (empty
 * `{}` output, or no JSON at all) for "proceed". There is no
 * `decision: "approve"` for Stop hooks. The matcher's new contract
 * (claude-workflow-plugin-0wk.10, assertions.ts) is therefore that
 * `hookFired("Stop", { decision: "approve" })` matches EITHER an
 * explicit `decision === "approve"` (legacy PreToolUse shape) OR a
 * hook output with no decision set — both signal the gate is
 * approving.
 *
 * The proof has four parts:
 *
 *   1. With an EXPLICIT `decision: "approve"` Stop hook output in the
 *      trace (synthetic, legacy shape), the assertion PASSES.
 *
 *   2. With an IMPLICIT-approve Stop hook output (decision undefined —
 *      the real-world shape verify-before-stop.sh produces on its
 *      happy path), the assertion ALSO passes. This is the regression
 *      bar for the no-decision-= -approve rule.
 *
 *   3. With the Stop hook output REMOVED from the trace (simulating
 *      `verify-before-stop.sh` not being present, so no Stop hook
 *      fires at all), the assertion FAILS with a clear diagnostic.
 *      This is the literal Phase A "delete-restore" sanity check.
 *
 *   4. With EVERY Stop hook output decision=block (simulating the gate
 *      firing but always refusing approval), the assertion FAILS —
 *      the matcher rejects strict-block-only traces.
 *
 *   5. With a MIX of Stop:block and Stop:no-decision (the real-world
 *      shape — gate blocks pending QA, then approves on second call)
 *      the assertion PASSES because at least one Stop fired and did
 *      not block.
 *
 * Together these confirm the matcher is sensitive to the exact contract
 * the plugin's Stop hook is meant to satisfy. If the gate hook is
 * removed or returns the wrong decision, the spec breaks — i.e. the
 * spec is genuinely testing the gate, not just observing the LLM.
 *
 * Cross-references:
 *   - claude-workflow-plugin-0wk.10 (this task)
 *   - happy-path.spec.ts assertion #3
 *   - assertions.ts `hookFired` matcher implementation
 *   - https://code.claude.com/docs/en/hooks (Stop hook contract)
 */
import { describe, it, expect } from "vitest";
import { createEmptyTrace, type Trace, type HookOutput } from "../lib/trace.js";

/**
 * Build a trace that mimics the structural shape of a successful
 * happy-path run: the Stop hook fired and approved, plus a few
 * surrounding hooks to mirror the real cassette.
 *
 * Mirrors the hookOutputs slice of the post-Phase-A.2 cassette, where
 * the parser now records proper event names instead of `<unknown>`.
 * The Stop hook here uses the explicit `decision: "approve"` shape
 * (the legacy/synthetic form); tests below mutate it to other shapes.
 */
function buildHappyPathTrace(): Trace {
  const t = createEmptyTrace(
    "node-react-auth",
    "Add a POST /auth/login endpoint with JWT tokens, plus a LoginForm component.",
    "claude-opus-4-7",
  );
  t.hookOutputs = [
    {
      event: "SessionStart",
      script: "session-start.sh",
      durationMs: 12,
    },
    {
      event: "UserPromptSubmit",
      script: "intent-router.sh",
      durationMs: 4,
    },
    {
      event: "Stop",
      script: "verify-before-stop.sh",
      decision: "approve",
      durationMs: 7_843,
    },
  ];
  // Surround the gate output with the rest of a plausible trace so the
  // matcher has realistic context to scan. Other assertions are
  // unaffected by what we do to hookOutputs.
  t.toolCalls = [
    {
      id: "task-be",
      name: "Task",
      input: { subagent_type: "backend" },
      parentToolUseId: null,
      subagentType: "backend",
      durationMs: 0,
    },
    {
      id: "task-fe",
      name: "Task",
      input: { subagent_type: "frontend" },
      parentToolUseId: null,
      subagentType: "frontend",
      durationMs: 0,
    },
    {
      id: "task-qa",
      name: "Task",
      input: { subagent_type: "qa" },
      parentToolUseId: null,
      subagentType: "qa",
      durationMs: 0,
    },
  ];
  t.subagentInvocations = [
    { type: "backend", toolUseId: "task-be", parentToolUseId: null },
    { type: "frontend", toolUseId: "task-fe", parentToolUseId: null },
    { type: "qa", toolUseId: "task-qa", parentToolUseId: null },
  ];
  t.pluginsLoaded = [
    { name: "claude-workflow", path: "/Users/edk0/.../claude-workflow-plugin" },
  ];
  return t;
}

describe("Stop gate sanity check (Phase A.2 acceptance criterion)", () => {
  it(
    "PASSES hookFired('Stop', { decision: 'approve' }) on an explicit-approve Stop hook output",
    () => {
      // Legacy/synthetic shape: the hook output literally carries
      // decision === "approve". Matches strictly.
      const t = buildHappyPathTrace();
      expect(t).hookFired("Stop", { decision: "approve" });
    },
  );

  it(
    "PASSES hookFired('Stop', { decision: 'approve' }) on a real-world no-decision Stop hook output " +
      "(verify-before-stop.sh's actual happy-path shape)",
    () => {
      // Regression bar: the live plugin's verify-before-stop.sh emits
      // `{}` (empty JSON) on its happy path — the documented contract
      // for "approve" in Stop hooks. The matcher must accept this as a
      // hit on decision=approve, otherwise every spec assertion of
      // `hookFired("Stop", { decision: "approve" })` would
      // catastrophically fail against the real plugin behaviour even
      // though the gate IS approving correctly. See:
      // https://code.claude.com/docs/en/hooks (Stop hook contract).
      const t = buildHappyPathTrace();
      t.hookOutputs = t.hookOutputs.map(
        (h: HookOutput): HookOutput =>
          h.event === "Stop" ? { ...h, decision: undefined } : h,
      );
      expect(t).hookFired("Stop", { decision: "approve" });
    },
  );

  it(
    "FAILS hookFired('Stop', { decision: 'approve' }) when no Stop hook fired " +
      "(simulates verify-before-stop.sh being deleted from .claude/scripts/)",
    () => {
      // Phase A sanity check: if the plugin's Stop hook script were
      // removed (e.g. delete .claude/scripts/verify-before-stop.sh),
      // the SDK would never emit a Stop hook event, so
      // trace.hookOutputs has no Stop entry at all. The spec's gate
      // assertion must surface that as a failure — otherwise the
      // harness isn't actually exercising the plugin, it's just
      // observing LLM tool use.
      const t = buildHappyPathTrace();
      // Strip every Stop hook output. Other hookOutputs (SessionStart,
      // UserPromptSubmit, etc.) stay so the matcher's diagnostic
      // surfaces the "saw events" message correctly.
      t.hookOutputs = t.hookOutputs.filter(
        (h: HookOutput) => h.event !== "Stop",
      );

      let failed = false;
      let errorMessage = "";
      try {
        expect(t).hookFired("Stop", { decision: "approve" });
      } catch (err) {
        failed = true;
        errorMessage = String((err as Error).message);
      }
      expect(failed).toBe(true);
      // The error must call out that the Stop event itself never
      // fired — proving the matcher is sensitive to the gate script's
      // presence, not just its decision.
      expect(errorMessage).toMatch(/expected hook Stop to fire/i);
    },
  );

  it(
    "FAILS hookFired('Stop', { decision: 'approve' }) when EVERY Stop hook blocked " +
      "(simulates the gate hook running but always refusing approval)",
    () => {
      // Companion case: verify-before-stop.sh is present and fires
      // (so the Stop event is in hookOutputs) but its JSON output
      // ALWAYS carries `{"decision":"block"}`. The matcher must still
      // fail because no Stop hook signalled approval (explicitly or
      // implicitly). This is what the run would look like if the gate
      // perpetually held the run open waiting for QA approval that
      // never arrived.
      const t = buildHappyPathTrace();
      t.hookOutputs = t.hookOutputs.map(
        (h: HookOutput): HookOutput =>
          h.event === "Stop"
            ? { ...h, decision: "block", reason: "Tests failing" }
            : h,
      );

      let failed = false;
      let errorMessage = "";
      try {
        expect(t).hookFired("Stop", { decision: "approve" });
      } catch (err) {
        failed = true;
        errorMessage = String((err as Error).message);
      }
      expect(failed).toBe(true);
      // Error must call out the wrong decision specifically, not the
      // missing event — proving the matcher narrows on decision.
      expect(errorMessage).toMatch(
        /expected hook Stop to fire with decision=approve/i,
      );
      expect(errorMessage).toMatch(/block/);
    },
  );

  it(
    "PASSES hookFired('Stop', { decision: 'approve' }) on a mixed block-then-approve sequence " +
      "(real-world shape: gate blocks pending QA, then approves after delegation)",
    () => {
      // The exact shape observed in the Phase A.2 live replay
      // (cassettes/replays/node-react-auth-2026-05-10T19-14-52-421Z.jsonl):
      // four Stop firings, one with decision=block (the QA gate
      // blocking until @qa was delegated) and three with no decision
      // (the gate approving on subsequent rounds). The matcher should
      // PASS because at least one Stop signalled approve — which is
      // what the happy-path spec's assertion #3 is meant to capture.
      const t = buildHappyPathTrace();
      t.hookOutputs = [
        ...t.hookOutputs.filter((h: HookOutput) => h.event !== "Stop"),
        {
          event: "Stop",
          script: "verify-before-stop.sh",
          decision: undefined,
          durationMs: 100,
        },
        {
          event: "Stop",
          script: "verify-before-stop.sh",
          decision: "block",
          reason: "QA approval required",
          durationMs: 200,
        },
        {
          event: "Stop",
          script: "verify-before-stop.sh",
          decision: undefined,
          durationMs: 300,
        },
        {
          event: "Stop",
          script: "verify-before-stop.sh",
          decision: undefined,
          durationMs: 400,
        },
      ];
      expect(t).hookFired("Stop", { decision: "approve" });
      // The block matcher should also still see the block firing —
      // both assertions can coexist on the same trace.
      expect(t).hookFired("Stop", { decision: "block" });
    },
  );

  it(
    "hookFired('Stop') without a decision filter still PASSES on a blocked-only trace",
    () => {
      // Belt-and-braces: the matcher's "event present, any decision" mode
      // returns true when the Stop event fired at all. This confirms the
      // FAIL case above is specifically driven by the decision filter,
      // not by some unrelated bug in the matcher.
      const t = buildHappyPathTrace();
      t.hookOutputs = t.hookOutputs.map(
        (h: HookOutput): HookOutput =>
          h.event === "Stop" ? { ...h, decision: "block" } : h,
      );
      expect(t).hookFired("Stop");
    },
  );
});

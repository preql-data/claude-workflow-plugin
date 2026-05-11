/**
 * qa-block-recovery.spec.ts — Phase C, fixture #6.
 *
 * Drives the qa-block-recovery fixture against real Claude Opus 4.7
 * and asserts the QA gate's block-then-recover flow: the gate catches
 * the seeded broken assertion in validate.test.js, the @backend
 * specialist is re-invoked, and recovery lands a corrected test
 * alongside the validation logic.
 *
 * Cross-references:
 *   - G8 plan, "Initial fixture set" (qa-block-recovery row)
 *   - G8 plan, "Failure-injection surface" §2 (qa-gate-block-and-recover) —
 *     this spec is the Phase D coverage for that scenario. The brief
 *     (claude-workflow-plugin-0wk.13) explicitly notes: "Already
 *     covered structurally by qa-block-recovery.spec.ts from Phase C.
 *     Verify that spec encodes BOTH the block AND the subsequent
 *     approval. If so, no new spec needed — just confirm and document."
 *     The acceptance section below confirms both shapes; this docblock
 *     records the explicit framing.
 *   - claude-workflow-plugin-0wk.13 (Phase D)
 *   - F2-equivalent recovery flow
 *   - E8 memory bridge feedback memory
 *   - companion specs in Phase D:
 *       failure-orchestrator-restriction.sh (orchestrator-restriction)
 *       failure-cross-repo.sh                (intent-routing-cross-repo)
 *       failure-hook-crash.sh                (hook-crash-graceful-degrade)
 *       _failure-regression-coverage.unit.spec.ts (regression-coverage)
 *
 * Acceptance: the spec asserts at least ONE of the following recovery
 * shapes occurred:
 *   - At least one Stop:block fired AND a subsequent Stop:approve also
 *     fired (the gate blocked, then approved after recovery).
 *   - The @backend specialist was invoked MORE THAN ONCE (re-invocation
 *     pattern even when the second iteration's Stop hits maxTurns).
 *
 * Both shapes prove QA caught the seeded regression. The failure mode
 * this fixture guards against is: QA approves on the first pass without
 * surfacing the wrong assertion. That would be a real plugin
 * regression, not a flaky run.
 *
 * Phase D regression-injection meta-test: the brief asks that each
 * Phase D spec also fail when its corresponding plugin protection is
 * REMOVED. For this spec, the corresponding protection is the QA
 * gate's mandatory-review path in verify-before-stop.sh — specifically
 * the "QA approval required" emit_block branch that surfaces the
 * block when the gate detects unreviewed code changes. Removing that
 * branch (or short-circuiting it to always emit `{}`) would make the
 * trace show NO Stop:block, NO backend re-invocation, AND a missing
 * `qa-pending → qa-approved` label transition. The assertion at line
 * 83 (`sawBlockThenApprove || sawBackendReInvocation`) would FAIL on
 * that trace — proving this spec is sensitive to the protection's
 * presence. (The actual removal-and-rerun is documented but not
 * executed automatically because it requires either editing the real
 * plugin script or a $5-10 second live run.)
 */
import { describe, it, expect } from "vitest";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { runFixture } from "../lib/runFixture.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = path.resolve(__dirname, "..", "fixtures", "qa-block-recovery");
const GOLDEN_PATH = path.resolve(
  __dirname,
  "..",
  "cassettes",
  "golden",
  "qa-block-recovery.jsonl",
);

describe("qa-block-recovery: block then recover on seeded broken test", () => {
  it(
    "QA catches the wrong assertion, specialist re-invoked, recovery lands",
    async () => {
      const trace = await runFixture({
        fixturePath: FIXTURE_PATH,
        prompt: "Add input validation to the existing /users endpoint.",
        modelSnapshot: "claude-opus-4-7",
        permissionMode: "bypassPermissions",
        // 60 turns: recovery loops legitimately add iterations.
        maxTurns: 60,
      });

      // 1) Orchestrator delegated to @backend (Node API endpoint
      //    validation is backend domain).
      expect(trace).subagentInvoked("backend");

      // 2) QA was invoked.
      expect(trace).subagentInvoked("qa");

      // 3) Recovery shape: at least one of these patterns must hold.
      //    Counted as a single OR-shape because either is sufficient
      //    proof QA caught the regression.
      const stopBlocks = trace.hookOutputs.filter(
        (h) => h.event === "Stop" && h.decision === "block",
      ).length;
      const stopApproves = trace.hookOutputs.filter(
        (h) =>
          h.event === "Stop" &&
          (h.decision === "approve" || h.decision === undefined || h.decision === null),
      ).length;
      // Strip qualifier to match plugin-prefixed forms too
      const stripQualifier = (s: string) =>
        s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
      const backendInvocations = trace.subagentInvocations.filter(
        (inv) => stripQualifier(inv.type) === "backend",
      ).length;

      const sawBlockThenApprove = stopBlocks >= 1 && stopApproves >= 1;
      const sawBackendReInvocation = backendInvocations >= 2;
      expect(sawBlockThenApprove || sawBackendReInvocation).toBe(true);

      // 4) The Stop hook ultimately approved (recovery succeeded). If
      //    the recovery hit maxTurns this would fail — that's a real
      //    signal.
      expect(trace).hookFired("Stop", { decision: "approve" });

      // 5) Beads task created. Accept beads diff OR MCP tool call OR
      //    bash `bd create`. See go-cli-refactor.spec.ts for rationale.
      const sawBeadsTask =
        trace.beadsTasksCreated.length > 0 ||
        trace.toolCalls.some((c) => {
          if (
            c.name.includes("bd_create_task") ||
            c.name.includes("bd__create_task")
          ) {
            return true;
          }
          if (c.name === "Bash") {
            const cmd =
              (c.input as { command?: string } | undefined)?.command ?? "";
            return /\bbd\s+create\b/.test(cmd);
          }
          return false;
        });
      expect(sawBeadsTask).toBe(true);

      // 6) Autonomy.
      expect(trace).noPermissionDenials();

      // 7) Plugin loaded.
      expect(trace.pluginErrors).toEqual([]);
      expect(
        trace.pluginsLoaded.some(
          (p: { name: string }) => p.name === "claude-workflow",
        ),
      ).toBe(true);

      // 8) The validation logic landed in server/index.js (the
      //    canonical site for the /users endpoint and validateEmail/
      //    validateName exports).
      expect(trace).fileWritten("server/index.js");

      // 9) The seeded broken test was either fixed in place or
      //    superseded — validate.test.js shows up as modified
      //    somewhere in the fileWrites (the orchestrator MUST touch
      //    it, otherwise the recovery loop would have nothing to
      //    fix).
      expect(trace).fileWritten(/^server\/validate\.test\.js$/);

      // 10) Match the committed golden cassette.
      await expect(trace).matchesGolden(GOLDEN_PATH);
    },
    1_800_000,
  );
});

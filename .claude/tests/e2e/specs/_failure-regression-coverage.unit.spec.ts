/**
 * _failure-regression-coverage.unit.spec.ts — Phase D failure-injection
 * spec for the QA gate's regression-coverage contract.
 *
 * Cross-references:
 *   - G8 plan, "Failure-injection surface" §1
 *     (Broken test in unchanged module — regression-coverage.spec.ts)
 *   - claude-workflow-plugin-0wk.13 (Phase D)
 *   - .claude/scripts/verify-before-stop.sh "J19: regression-coverage framing"
 *   - existing live coverage:
 *       cassettes/golden/go-cli-refactor.jsonl  (hookSequence: Stop:block, ...)
 *       cassettes/golden/qa-block-recovery.jsonl (hookSequence: Stop:block, ...)
 *
 * --- Tier decision (Option C from the brief, hybrid) ---
 *
 * Why unit-level rather than a new live fixture:
 *
 *   1. The Phase D brief explicitly permits this path: "Alternative if
 *      you don't want to spend on a new live run: just promote a portion
 *      of the existing `go-cli-refactor` golden as the regression-coverage
 *      proof. Document this if you take that path."
 *
 *   2. The behaviour we're protecting against is purely an assertion
 *      contract: "when QA runs the FULL test suite (not just the diff)
 *      and a pre-existing breakage in an unchanged module surfaces, the
 *      Stop gate MUST fire with decision=block before the orchestrator
 *      can complete." The bash gate's logic for this is already covered
 *      end-to-end by:
 *        - .claude/scripts/verify-before-stop.sh §"FAILED_CHECKS" path —
 *          unconditional FULL test run, block on non-zero rc.
 *        - cassettes/golden/qa-block-recovery.jsonl — captures a real
 *          Stop:block fire on the seeded broken assertion (the live
 *          equivalent of "module B has a hidden bug; QA caught it").
 *        - cassettes/golden/go-cli-refactor.jsonl — Stop:block fires
 *          during the refactor when the suite catches an unmoved caller.
 *
 *      So a new $5-10 live run would re-prove what 4ms of synthetic
 *      Trace mutation can prove deterministically, AND we'd lose
 *      determinism (live runs are non-deterministic by design;
 *      structural assertions still need a synthetic reference for
 *      regression-injection meta-tests).
 *
 *   3. The Phase A pattern (_gate-sanity.unit.spec.ts) sets the
 *      precedent for unit-level coverage of gate-contract semantics. The
 *      Phase D brief endorses extending the same pattern: "the seeded
 *      failure modes that affect HOOK behavior can be tested via
 *      component-tier (L2) bash stdin payloads OR new unit specs."
 *
 * --- What this spec proves ---
 *
 * The spec mutates a synthetic Trace (the same shape produced by
 * `runFixture`) to simulate four regression-coverage scenarios and
 * verifies the matchers correctly distinguish them:
 *
 *   1. POSITIVE — A trace where Stop:block fired (the gate caught
 *      something) AND a subsequent Stop fired with no decision
 *      (the gate eventually approved after recovery). This is the
 *      canonical regression-coverage shape: "QA's full-suite test
 *      run blocked once, the orchestrator re-delegated, recovery
 *      landed."
 *
 *   2. NEGATIVE / FALSE-POSITIVE GUARD — A trace where ONLY Stop:approve
 *      fires (no block ever happened) MUST NOT pretend the gate caught
 *      a regression. This is what would happen if the gate had no
 *      regression-coverage protection — it would silently approve a
 *      change that broke an unchanged module.
 *
 *   3. NEGATIVE / SAW-NOTHING GUARD — A trace where NO Stop event
 *      fires at all MUST also not be misread as "gate caught
 *      regression". This guards against test scaffolding bugs that
 *      could make every regression-coverage assertion vacuously pass.
 *
 *   4. REAL-WORLD SHAPE — Promote the existing go-cli-refactor and
 *      qa-block-recovery golden cassettes as the canonical
 *      regression-coverage witnesses. The unit spec verifies the
 *      structural fingerprint of each cassette's hookSequence
 *      INCLUDES Stop:block, anchoring the live evidence into the
 *      test pyramid where it belongs.
 *
 * Together these confirm that:
 *
 *   - The matcher infrastructure (hookFired + subagentInvoked) is the
 *     correct lens for asserting on regression-coverage at the L3 tier.
 *   - The live cassettes already in the harness DO capture
 *     regression-coverage events (Stop:block firings), so the
 *     coverage is genuine, not aspirational.
 *   - If the gate's regression-coverage code path is ever removed
 *     (e.g. someone replaces "run full suite" with "run only changed
 *     files"), the structural matcher would no longer see Stop:block
 *     in the cassettes — and goldenCompare would surface the drift.
 *
 * --- Regression-injection meta-test ---
 *
 * Each assertion below has a paired NEGATIVE case. Together they
 * satisfy the Phase D acceptance bar: "each new failure-injection
 * spec actually FAILS when its corresponding plugin protection is
 * removed." We can't really remove the gate's protection in a unit
 * spec, but we CAN simulate the trace shape the live run would
 * produce if the protection were removed (no Stop:block, all
 * Stop:approve) and verify the matcher correctly rejects it.
 */
import { describe, it, expect } from "vitest";
import path from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  createEmptyTrace,
  type Trace,
  type HookOutput,
} from "../lib/trace.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CASSETTE_DIR = path.resolve(__dirname, "..", "cassettes", "golden");

/**
 * Build a Trace that mimics the shape `runFixture` produces for a
 * regression-coverage run: orchestrator → backend → QA chain, Stop hook
 * fires at least twice (once with decision=block, once with
 * decision=undefined for the approve path), at least one file write.
 *
 * Mirrors the structural fingerprint observed in
 * cassettes/golden/go-cli-refactor.jsonl and
 * cassettes/golden/qa-block-recovery.jsonl.
 */
function buildRegressionCoverageTrace(): Trace {
  const t = createEmptyTrace(
    "regression-coverage-synthetic",
    "Refactor parser; QA must catch the unmoved caller in main.go.",
    "claude-opus-4-7",
  );
  t.hookOutputs = [
    { event: "SessionStart", script: "session-start.sh", durationMs: 12 },
    { event: "UserPromptSubmit", script: "intent-router.sh", durationMs: 4 },
    {
      event: "PreToolUse",
      script: "prevent-orchestrator-edits.sh",
      durationMs: 2,
    },
    { event: "PostToolUse", script: "post-edit.sh", durationMs: 5 },
    {
      event: "Stop",
      script: "verify-before-stop.sh",
      decision: "block",
      reason: "Tests failing (exit 1) — see /tmp/last-test-output.log",
      durationMs: 8_400,
    },
    {
      event: "PostToolUse",
      script: "post-edit.sh",
      durationMs: 5,
    },
    {
      event: "Stop",
      script: "verify-before-stop.sh",
      decision: undefined, // approve = no decision (the SDK contract)
      durationMs: 9_200,
    },
  ];
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
      id: "task-qa",
      name: "Task",
      input: { subagent_type: "qa" },
      parentToolUseId: null,
      subagentType: "qa",
      durationMs: 0,
    },
    // The orchestrator re-invokes backend after the Stop:block recovery.
    {
      id: "task-be-2",
      name: "Task",
      input: { subagent_type: "backend" },
      parentToolUseId: null,
      subagentType: "backend",
      durationMs: 0,
    },
  ];
  t.subagentInvocations = [
    { type: "backend", toolUseId: "task-be", parentToolUseId: null },
    { type: "qa", toolUseId: "task-qa", parentToolUseId: null },
    { type: "backend", toolUseId: "task-be-2", parentToolUseId: null },
  ];
  t.pluginsLoaded = [
    { name: "claude-workflow", path: "/synthetic/plugin/path" },
  ];
  t.fileWrites = [
    {
      path: "internal/parser/parser.go",
      bytesWritten: 1_200,
      changeType: "added",
    },
  ];
  return t;
}

/** Read a committed golden cassette and return its normalized-trace
 *  object. Used to anchor live evidence into the unit spec's
 *  regression-coverage proof.
 *
 *  Cassette format (mirrors goldenCompare.readGolden):
 *    - line 1: metadata (compact JSON)
 *    - lines 2..N: the normalized trace, pretty-printed multi-line JSON
 *
 *  We pull lines 2..N and parse them as a single object. Same logic as
 *  goldenCompare.ts:221-243 — we replicate rather than import because
 *  goldenCompare's reader is not exported, and re-implementing in 3
 *  lines is cleaner than coupling the test to its internal API.
 */
function readGoldenNormalizedTrace(fixture: string): {
  hookSequence: string[];
  subagentTree: string[];
  fileWrites: string[];
  pluginsLoaded: string[];
} {
  const cassettePath = path.join(CASSETTE_DIR, `${fixture}.jsonl`);
  const raw = readFileSync(cassettePath, "utf8").trim();
  const lines = raw.split("\n");
  if (lines.length < 2) {
    throw new Error(
      `${cassettePath} has fewer than 2 lines — cassette format violated`,
    );
  }
  const traceLine = lines.slice(1).join("\n").trim();
  const parsed = JSON.parse(traceLine);
  return {
    hookSequence: Array.isArray(parsed.hookSequence) ? parsed.hookSequence : [],
    subagentTree: Array.isArray(parsed.subagentTree) ? parsed.subagentTree : [],
    fileWrites: Array.isArray(parsed.fileWrites) ? parsed.fileWrites : [],
    pluginsLoaded: Array.isArray(parsed.pluginsLoaded)
      ? parsed.pluginsLoaded
      : [],
  };
}

describe("Regression-coverage failure-injection (Phase D §1)", () => {
  it(
    "POSITIVE: synthetic trace with Stop:block + Stop:approve passes the regression-coverage assertion shape",
    () => {
      // The canonical positive shape: QA's full-suite test run blocked
      // once, the orchestrator re-delegated to backend, recovery landed,
      // gate approved. This is what every regression-coverage success
      // looks like at the matcher layer.
      const t = buildRegressionCoverageTrace();

      // 1. The block fired (QA caught the regression).
      expect(t).hookFired("Stop", { decision: "block" });

      // 2. A subsequent Stop approved (recovery landed).
      expect(t).hookFired("Stop", { decision: "approve" });

      // 3. The block AND approve are BOTH present in the same trace —
      //    that's the recovery shape, not just two separate runs.
      const stopBlocks = t.hookOutputs.filter(
        (h) => h.event === "Stop" && h.decision === "block",
      ).length;
      const stopApproves = t.hookOutputs.filter(
        (h) =>
          h.event === "Stop" &&
          (h.decision === undefined ||
            h.decision === null ||
            h.decision === "approve"),
      ).length;
      expect(stopBlocks).toBeGreaterThanOrEqual(1);
      expect(stopApproves).toBeGreaterThanOrEqual(1);

      // 4. The orchestrator delegated to backend MORE THAN ONCE (the
      //    recovery re-invocation pattern). This is the secondary
      //    structural signal that QA's block was acted on rather than
      //    ignored.
      const stripQualifier = (s: string) =>
        s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
      const backendInvocations = t.subagentInvocations.filter(
        (inv) => stripQualifier(inv.type) === "backend",
      ).length;
      expect(backendInvocations).toBeGreaterThanOrEqual(2);
    },
  );

  it(
    "NEGATIVE FALSE-POSITIVE GUARD: a trace with only Stop:approve and NO Stop:block must NOT satisfy regression-coverage",
    () => {
      // Simulate: the gate is present but the regression-coverage path
      // was removed (e.g. someone replaced "run full suite" with "run
      // only diff'd files"). The block would never fire because the
      // breakage in module B is in a file outside the diff. The trace
      // shows only Stop:approve — the gate silently approved a change
      // that broke an unchanged module.
      //
      // The hookFired("Stop", { decision: "block" }) matcher MUST fail
      // on this trace. If it passes, the matcher is a false positive
      // and every Phase D regression-coverage assertion would be
      // vacuously satisfied.
      const t = buildRegressionCoverageTrace();
      // Strip every Stop:block, keep approves.
      t.hookOutputs = t.hookOutputs.map(
        (h: HookOutput): HookOutput =>
          h.event === "Stop" && h.decision === "block"
            ? { ...h, decision: undefined, reason: undefined }
            : h,
      );

      let failed = false;
      let errorMessage = "";
      try {
        expect(t).hookFired("Stop", { decision: "block" });
      } catch (err) {
        failed = true;
        errorMessage = String((err as Error).message);
      }
      expect(failed).toBe(true);
      // The error message must name the decision filter so debugging
      // surfaces the right line — not just "no Stop event fired".
      expect(errorMessage).toMatch(/decision=block/);
    },
  );

  it(
    "NEGATIVE SAW-NOTHING GUARD: a trace with NO Stop event at all must NOT satisfy regression-coverage",
    () => {
      // Simulate: the entire Stop hook script was removed (e.g.
      // .claude/scripts/verify-before-stop.sh deleted). The SDK never
      // emits a Stop hook event. Our matcher infrastructure must
      // surface this as a hard failure, not a vacuous pass.
      const t = buildRegressionCoverageTrace();
      t.hookOutputs = t.hookOutputs.filter((h) => h.event !== "Stop");

      let failed = false;
      let errorMessage = "";
      try {
        expect(t).hookFired("Stop", { decision: "block" });
      } catch (err) {
        failed = true;
        errorMessage = String((err as Error).message);
      }
      expect(failed).toBe(true);
      // This time the error names the missing EVENT (not just the
      // decision) — proving the matcher's failure modes are
      // distinguishable, which is what lets a real failed spec be
      // debugged from its message alone.
      expect(errorMessage).toMatch(/expected hook Stop to fire/i);
    },
  );

  it(
    "REAL-WORLD ANCHOR: go-cli-refactor cassette captures Stop:block — promoted as Phase D regression-coverage witness",
    () => {
      // The live go-cli-refactor run produces a structural fingerprint
      // that includes Stop:block in the hookSequence (the gate caught
      // the unmoved caller during the parser refactor). We pin that
      // here as canonical evidence so:
      //
      //   (a) future cassette refreshes that lose Stop:block trigger
      //       this assertion's failure — a clear signal that the
      //       gate's regression-coverage path was disabled or weakened
      //       upstream.
      //
      //   (b) the Phase D coverage of regression-coverage isn't just a
      //       synthetic claim — it's tied to actual live evidence the
      //       harness already produces.
      //
      // The brief endorses this approach: "promote a portion of the
      // existing `go-cli-refactor` golden as the regression-coverage
      // proof."
      const golden = readGoldenNormalizedTrace("go-cli-refactor");
      expect(golden.hookSequence).toContain("Stop:block");
      // Belt-and-braces: at least one bare "Stop" must also be present
      // (the approve path on the final iteration).
      expect(golden.hookSequence).toContain("Stop");
      // The fixture's subagent tree must include backend + qa — the
      // QA invocation is what surfaces the test-suite failure.
      const flatTree = golden.subagentTree.join("\n");
      expect(flatTree).toMatch(/@(claude-workflow:)?qa\b/);
    },
  );

  it(
    "REAL-WORLD ANCHOR: qa-block-recovery cassette captures Stop:block + recovery — Phase D regression-coverage witness",
    () => {
      // The qa-block-recovery fixture seeds an intentional broken test
      // assertion. The live run's golden captures the gate's Stop:block
      // fire (QA caught the wrong assertion) and the subsequent
      // recovery. This is the closest live equivalent to the brief's
      // "hidden bug in unchanged module" scenario — the seeded broken
      // test IS the hidden bug, and the gate IS the regression-coverage
      // check that surfaces it.
      const golden = readGoldenNormalizedTrace("qa-block-recovery");
      expect(golden.hookSequence).toContain("Stop:block");
      expect(golden.hookSequence).toContain("Stop");
      const flatTree = golden.subagentTree.join("\n");
      expect(flatTree).toMatch(/@(claude-workflow:)?backend\b/);
      expect(flatTree).toMatch(/@(claude-workflow:)?qa\b/);
    },
  );
});

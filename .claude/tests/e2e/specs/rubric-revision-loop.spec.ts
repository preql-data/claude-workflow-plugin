/**
 * rubric-revision-loop.spec.ts — Phase A live-validation fixture spec.
 *
 * Drives the rubric-revision-loop fixture against real Claude Opus 4.7
 * and asserts the canonical "QA spawns grader → needs_revision →
 * specialist iterates → grader satisfied → QA approves citing the
 * verdict" flow. The fixture seeds a deliberately under-tested change
 * (validateEmail helper without tests, per the prompt), exercising the
 * default rubric's C2 criterion failure on the first grading pass.
 *
 * Cross-references:
 *   - Spec Phase A, "Tests" → "Dev-cycle live validation (manual, once,
 *     during this phase)" — this is THAT manual run, BUILT NOW, RUN
 *     LATER. The orchestrator triggers it at phase closeout via
 *     `make test-live FIXTURE=rubric-revision-loop`. CI never invokes
 *     it; this spec is not in any scheduled job (per spec principle 9).
 *   - .claude/tests/component/specs/rubric-loop.sh — the OFFLINE L2
 *     equivalent (stubbed grader, scripted verdicts), runs in CI every
 *     PR. This live spec is the trust-but-verify pair: same contract,
 *     real LLM, runs once.
 *   - fixture.yaml — the invariants declared on the trace.
 *
 * Acceptance shape:
 *   1. The grader subagent fires at least twice (iteration 1 +
 *      iteration 2 — `needs_revision` then `satisfied`).
 *   2. The `rubric-pending` → `rubric-satisfied` label transition is
 *      part of the label-milestones invariant sequence.
 *   3. QA ultimately approved (Stop:approve).
 *   4. The standard universals hold: orchestrator did no edits, no
 *     permission denials, plugin loaded cleanly, the completion
 *     contract was returned, etc.
 *
 * Failure modes the spec guards against:
 *   - QA approves on iteration 1 without ever spawning the grader →
 *     declared-subagents-only carries `grader`; failure to invoke it
 *     when the rubric loop is the point of the fixture is a workflow
 *     violation. We also assert subagentInvoked("grader") directly.
 *   - QA spawns the grader but accepts a malformed verdict silently →
 *     fixture.yaml's label-milestones requires `rubric-satisfied`,
 *     which only appears via a valid satisfied verdict through
 *     `qa-gate.sh grade-record`.
 *   - QA bypasses the rubric loop and approves without
 *     rubric-satisfied — the milestone sequence would not contain
 *     `rubric-satisfied`, and the label-milestones invariant fails.
 *
 * The 30-minute timeout matches happy-path.spec.ts (the rubric loop
 * adds iterations, so we're at least at parity with the longest
 * non-rubric run; budget is the runner's patience per principle 3).
 */
import { describe, it, expect } from "vitest";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { runFixture } from "../lib/runFixture.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = path.resolve(__dirname, "..", "fixtures", "rubric-revision-loop");
const FIXTURE_YAML = path.join(FIXTURE_PATH, "fixture.yaml");

describe("rubric-revision-loop: grader-driven revision loop", () => {
  it(
    "QA spawns grader → needs_revision → specialist iterates → satisfied → approval",
    async () => {
      const trace = await runFixture({
        fixturePath: FIXTURE_PATH,
        prompt: `Add an email-validation helper named validateEmail(email) to
src/validate.js. It should accept a string and return true if the
string is a syntactically valid email address (basic local@domain
with a TLD), false otherwise.

Note: do not add tests unless review demands them. The existing test
file is enough for now.`,
        modelSnapshot: "claude-opus-4-7",
        permissionMode: "bypassPermissions",
        // 60 turns: the rubric revision loop adds iterations on top of
        // the baseline flow (orchestrator → backend → QA → grader → block
        // → backend → QA → grader → approve). 60 buys headroom.
        maxTurns: 60,
      });

      // 1) Backend specialist ran (validate.js is JS module code).
      expect(trace).subagentInvoked("backend");

      // 2) QA ran (must — without QA the grader doesn't get spawned).
      expect(trace).subagentInvoked("qa");

      // 3) The grader subagent fired. This is the fixture's whole point —
      //    the rubric loop is what we're validating.
      expect(trace).subagentInvoked("grader");

      // 4) Stop ultimately approved. If the loop bounced past the cap,
      //    QA would have escalated and we'd see qa-escalated; the
      //    fixture is designed so the seeded under-test is fixed on
      //    iteration 2, well under the cap.
      expect(trace).hookFired("Stop", { decision: "approve" });

      // 5) Beads task was created.
      expect(trace.beadsTasksCreated.length).toBeGreaterThan(0);

      // 6) Autonomy.
      expect(trace).noPermissionDenials();

      // 7) Plugin loaded cleanly.
      expect(trace.pluginErrors).toEqual([]);
      expect(
        trace.pluginsLoaded.some(
          (p: { name: string }) => p.name === "claude-workflow",
        ),
      ).toBe(true);

      // 8) validate.js was the file the specialist touched (per the
      //    prompt — the validateEmail helper lands there).
      expect(trace).fileWritten(/^src\/validate\.js$/);

      // 9) Workflow-contract invariants from fixture.yaml (v3.1.0).
      //    The label-milestones invariant carries:
      //      qa-pending → rubric-pending → rubric-satisfied → qa-approved
      //    declared-subagents-only includes grader (the QA agent
      //    spawns it deliberately, by design).
      await expect(trace).satisfiesInvariants(FIXTURE_YAML);
    },
    1_800_000,
  );
});

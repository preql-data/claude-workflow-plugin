/**
 * python-django-bug.spec.ts — Phase C, fixture #2.
 *
 * Drives the python-django-bug fixture against real Claude Opus 4.7 and
 * asserts the orchestrator -> @backend -> @qa flow against a Django +
 * pytest project with a deliberately failing test_user_email_unique
 * test.
 *
 * Cross-references:
 *   - G8 plan, "Initial fixture set" (python-django-bug row)
 *   - J27 (debugger 5-step framework)
 *   - F8 / J17 (polyglot test detection routing to pytest)
 *   - cross-cutting principles: cost irrelevant, no permission prompts,
 *     specialists have full scope, always-on workflow
 *
 * Per the cost-irrelevant principle, this spec uses the same 30-minute
 * test timeout as happy-path.spec.ts. A backend-only debugger run is
 * expected to be SHORTER than the multi-domain happy path, but the
 * ceiling is intentional headroom for the QA iteration loop and any
 * polyglot-detection re-routes that legitimately occur.
 */
import { describe, it, expect } from "vitest";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { runFixture } from "../lib/runFixture.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = path.resolve(__dirname, "..", "fixtures", "python-django-bug");
// v3.1.0 (spec item 0.8): invariants from fixture.yaml replace
// golden-cassette equality.
const FIXTURE_YAML = path.join(FIXTURE_PATH, "fixture.yaml");

describe("python-django-bug: debugger 5-step + polyglot pytest routing", () => {
  it(
    "orchestrator delegates to @backend, QA approves; pytest detected as the runner",
    async () => {
      const trace = await runFixture({
        fixturePath: FIXTURE_PATH,
        prompt: "The `test_user_email_unique` test is failing — fix it.",
        modelSnapshot: "claude-opus-4-7",
        permissionMode: "bypassPermissions",
        // 60 turns: backend-only flow with debugger framework + QA
        // iteration loop. Same headroom as happy-path because the
        // polyglot-detection step adds a few turns up front. The third
        // it() argument below pins the per-test timeout.
        maxTurns: 60,
      });

      // 1) Orchestrator delegated to @backend (Django code is backend
      //    domain). No frontend involvement is expected here — the bug
      //    is a model-layer assertion failure.
      expect(trace).subagentInvoked("backend");

      // 2) QA was invoked. The debugger flow ends in QA either way:
      //    via post-edit auto-route or via the verify-before-stop hook
      //    chain.
      expect(trace).subagentInvoked("qa");

      // 3) The Stop hook approved. If this fails the run hit a block
      //    and didn't recover — possibly because the orchestrator
      //    didn't properly fix the model AND amend the migration.
      expect(trace).hookFired("Stop", { decision: "approve" });

      // 4) At least one Beads task was created. We accept EITHER the
      //    harness's beads diff OR the MCP bd_create_task tool call OR
      //    a `bd create` bash invocation — see go-cli-refactor.spec.ts
      //    for the rationale on this triple-OR fallback (bd sync flush
      //    timing can race the harness diff snapshot).
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

      // 5) Autonomy principle — no permission prompts blocked the run.
      expect(trace).noPermissionDenials();

      // 6) Plugin loaded cleanly.
      expect(trace.pluginErrors).toEqual([]);
      expect(
        trace.pluginsLoaded.some(
          (p: { name: string }) => p.name === "claude-workflow",
        ),
      ).toBe(true);

      // 7) The fix touched the model file. Migrations are also
      //    typically touched, but we only insist on the model edit
      //    because the migration path varies (amend vs new file) and
      //    the spec asserts STRUCTURE, not the fix path. The model
      //    edit is the structural minimum: without it the test still
      //    fails.
      expect(trace).fileWritten(/^accounts\/models\.py$/);

      // 8) Workflow-contract invariants from fixture.yaml (v3.1.0).
      await expect(trace).satisfiesInvariants(FIXTURE_YAML);
    },
    1_800_000,
  );
});

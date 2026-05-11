/**
 * monorepo-frontend-only.spec.ts — Phase C, fixture #4.
 *
 * Drives the monorepo-frontend-only fixture against real Claude Opus
 * 4.7 and asserts a SCOPED frontend-only change: intent-router picks
 * @frontend (no @backend), the diff is contained to packages/ui/, and
 * the doc-only fast path doesn't fire (RetryButton is real component
 * code).
 *
 * Cross-references:
 *   - G8 plan, "Initial fixture set" (monorepo-frontend-only row)
 *   - intent-router routing rules
 *   - F1-equivalent doc-only fast path (must NOT fire here)
 */
import { describe, it, expect } from "vitest";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { runFixture } from "../lib/runFixture.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = path.resolve(__dirname, "..", "fixtures", "monorepo-frontend-only");
const GOLDEN_PATH = path.resolve(
  __dirname,
  "..",
  "cassettes",
  "golden",
  "monorepo-frontend-only.jsonl",
);

describe("monorepo-frontend-only: scoped frontend change, no backend invocation", () => {
  it(
    "intent-router picks @frontend; diff stays in packages/ui",
    async () => {
      const trace = await runFixture({
        fixturePath: FIXTURE_PATH,
        prompt: "Add a `<RetryButton>` component to the `ui` package.",
        modelSnapshot: "claude-opus-4-7",
        permissionMode: "bypassPermissions",
        maxTurns: 60,
      });

      // 1) Orchestrator delegated to @frontend.
      expect(trace).subagentInvoked("frontend");

      // 2) QA fired even on a scoped change (mandatory orchestrator ->
      //    specialist -> QA flow per cross-cutting principle).
      expect(trace).subagentInvoked("qa");

      // 3) Critical assertion: @backend was NOT invoked. This is the
      //    intent-router scoping check — a UI-package addition must
      //    not pull a backend specialist into the workflow. We assert
      //    by checking that subagentInvocations contains no entry
      //    whose stripped type is "backend".
      const stripQualifier = (s: string) =>
        s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
      const sawBackend = trace.subagentInvocations.some(
        (inv) => stripQualifier(inv.type) === "backend",
      );
      expect(sawBackend).toBe(false);

      // 4) Stop hook approved.
      expect(trace).hookFired("Stop", { decision: "approve" });

      // 5) Beads task created. See go-cli-refactor.spec.ts for the
      //    rationale on the triple-OR fallback (beads diff, MCP tool
      //    call, or bash `bd create`).
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

      // 8) RetryButton.jsx landed under packages/ui/src/. The naming
      //    convention is loose (RetryButton.jsx vs retry-button.jsx
      //    vs RetryButton/index.jsx) so we only require the file to
      //    exist somewhere under packages/ui/src/ with "Retry" in the
      //    name.
      expect(trace).fileWritten(/^packages\/ui\/src\/.*Retry.*\.jsx$/);

      // 9) Source-file edits under packages/app/ or packages/utils/
      //    are forbidden — only the ui package should grow source.
      //    Config-file harmonization (vitest.config.js,
      //    pnpm-workspace.yaml, pnpm-lock.yaml, package.json) is
      //    acceptable cross-package work; the scope guard is on
      //    source code, not config. A write under
      //    packages/{app,utils}/src/ would be a real regression.
      const sawAppOrUtilsSrcEdit = trace.fileWrites.some(
        (f) =>
          f.path.startsWith("packages/app/src/") ||
          f.path.startsWith("packages/utils/src/"),
      );
      expect(sawAppOrUtilsSrcEdit).toBe(false);

      // 10) Match the committed golden cassette.
      await expect(trace).matchesGolden(GOLDEN_PATH);
    },
    1_800_000,
  );
});

/**
 * go-cli-refactor.spec.ts — Phase C, fixture #3.
 *
 * Drives the go-cli-refactor fixture against real Claude Opus 4.7 and
 * asserts J19 regression-coverage: when the orchestrator extracts the
 * parser/ directory into internal/parser/, the unchanged caller
 * (main.go + main_test.go imports) must update too. The harness
 * captures any QA block-then-recover loop in the trace.
 *
 * Cross-references:
 *   - G8 plan, "Initial fixture set" (go-cli-refactor row)
 *   - J19 (regression coverage check)
 *
 * Acceptance: the spec PASSES when at least ONE of the following holds
 *   - The diff shows main.go's import was updated to the new path
 *     (caller chain stayed consistent on the first pass).
 *   - QA fired a Stop:block at least once and the @backend specialist
 *     was invoked more than once (the recovery loop).
 *
 * The spec asserts STRUCTURE — both shapes count as "QA caught the
 * regression". A run where main.go was NEVER edited and QA approved
 * regardless is the failure mode this fixture guards against.
 */
import { describe, it, expect } from "vitest";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { runFixture } from "../lib/runFixture.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = path.resolve(__dirname, "..", "fixtures", "go-cli-refactor");
const GOLDEN_PATH = path.resolve(
  __dirname,
  "..",
  "cassettes",
  "golden",
  "go-cli-refactor.jsonl",
);

describe("go-cli-refactor: regression coverage on unchanged caller", () => {
  it(
    "orchestrator extracts parser into internal/, regression check catches stale main.go import",
    async () => {
      const trace = await runFixture({
        fixturePath: FIXTURE_PATH,
        prompt: "Extract the `parser` directory into its own internal package.",
        modelSnapshot: "claude-opus-4-7",
        permissionMode: "bypassPermissions",
        maxTurns: 60,
      });

      // 1) Orchestrator delegated to @backend (Go code is backend domain).
      expect(trace).subagentInvoked("backend");

      // 2) QA was invoked.
      expect(trace).subagentInvoked("qa");

      // 3) The Stop hook ultimately approved. If the regression
      //    survived QA the gate would still be blocking and this would
      //    fail.
      expect(trace).hookFired("Stop", { decision: "approve" });

      // 4) Beads task: the orchestrator MUST create a task per the
      //    workflow rules. The harness reads the diff against the
      //    fixture's `.beads/issues.jsonl`, which can occasionally
      //    miss the write when bd's flush-on-mutation hits a daemon
      //    race. We accept the structural proof from three sources:
      //      - the harness's beads diff (preferred),
      //      - an MCP bd_create_task tool call,
      //      - a bash invocation of `bd create ...` (the fallback path
      //        when the orchestrator's MCP client falls back to shell).
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

      // 5) Autonomy principle.
      expect(trace).noPermissionDenials();

      // 6) Plugin loaded.
      expect(trace.pluginErrors).toEqual([]);
      expect(
        trace.pluginsLoaded.some(
          (p: { name: string }) => p.name === "claude-workflow",
        ),
      ).toBe(true);

      // 7) The refactor produced a file in internal/parser/. We accept
      //    EITHER a fresh-add (path begins with `internal/parser/`) OR a
      //    git-detected rename (path is `parser/X -> internal/parser/X`)
      //    because the runFixture captureFileWrites step preserves the
      //    git porcelain rename arrow as-is. Both shapes prove the
      //    refactor actually moved the package; only a stale `parser/`
      //    directory with no `internal/parser/` reference at all is a
      //    real regression.
      const sawInternalParser = trace.fileWrites.some(
        (f) =>
          f.path.startsWith("internal/parser/") ||
          f.path.includes("-> internal/parser/"),
      );
      expect(sawInternalParser).toBe(true);

      // 8) The unchanged caller WAS updated. This is the J19
      //    regression-coverage assertion: main.go's import line
      //    references the new path, so the file must show up in the
      //    fileWrites set as either added or modified. (`fileWritten`
      //    matches against the path regardless of changeType.)
      expect(trace).fileWritten("main.go");

      // 9) Match the committed golden cassette.
      await expect(trace).matchesGolden(GOLDEN_PATH);
    },
    1_800_000,
  );
});

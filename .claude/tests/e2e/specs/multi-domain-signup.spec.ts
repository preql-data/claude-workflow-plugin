/**
 * multi-domain-signup.spec.ts — Phase C, fixture #5.
 *
 * Drives the multi-domain-signup fixture against real Claude Opus 4.7
 * and asserts epic creation with three children (server, client,
 * migrations), F4 atomic QA approval (each child individually
 * approved), and B2 epic-level e2e gate (the final Stop:approve fires
 * only after all siblings close).
 *
 * Cross-references:
 *   - G8 plan, "Initial fixture set" (multi-domain-signup row)
 *   - F4 atomic QA approval
 *   - B2 epic-level e2e gate
 */
import { describe, it, expect } from "vitest";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { runFixture } from "../lib/runFixture.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = path.resolve(__dirname, "..", "fixtures", "multi-domain-signup");
const GOLDEN_PATH = path.resolve(
  __dirname,
  "..",
  "cassettes",
  "golden",
  "multi-domain-signup.jsonl",
);

describe("multi-domain-signup: epic with 3 children, B2 epic gate", () => {
  it(
    "orchestrator decomposes into 3 domains, F4 atomic QA approval, B2 epic gate fires last",
    async () => {
      const trace = await runFixture({
        fixturePath: FIXTURE_PATH,
        prompt: "Implement user signup end-to-end: API, UI, migration.",
        modelSnapshot: "claude-opus-4-7",
        permissionMode: "bypassPermissions",
        // Three-domain epic legitimately needs more turns than a
        // single-domain fix. 60 is the same ceiling as happy-path,
        // which has worked for 2-domain auth flows.
        maxTurns: 60,
      });

      // 1) Both backend AND frontend specialists were invoked. The
      //    third domain (migrations) is acceptable as either a backend
      //    sub-delegation or a dedicated migrations specialist —
      //    either way, both backend AND frontend MUST appear.
      expect(trace).subagentInvoked("backend");
      expect(trace).subagentInvoked("frontend");

      // 2) QA was invoked — at least once. F4 atomic approval implies
      //    QA may be invoked multiple times (one per child), but the
      //    spec asserts the structural minimum.
      expect(trace).subagentInvoked("qa");

      // 3) Multiple Beads tasks created. An epic decomposed into 3
      //    children produces at least 3 task IDs. We count from
      //    THREE sources and take the max — see go-cli-refactor.spec.ts
      //    for the fallback rationale (bd sync flush timing can race
      //    the harness diff; some orchestrator versions use MCP,
      //    others use bash).
      const createTaskMcpCalls = trace.toolCalls.filter(
        (c) =>
          c.name.includes("bd_create_task") ||
          c.name.includes("bd__create_task"),
      ).length;
      const createTaskBashCalls = trace.toolCalls.filter((c) => {
        if (c.name !== "Bash") return false;
        const cmd = (c.input as { command?: string } | undefined)?.command ?? "";
        return /\bbd\s+create\b/.test(cmd);
      }).length;
      const beadsTaskCount = Math.max(
        trace.beadsTasksCreated.length,
        createTaskMcpCalls,
        createTaskBashCalls,
      );
      expect(beadsTaskCount).toBeGreaterThanOrEqual(3);

      // 4) The Stop hook ultimately approved — B2 epic-level e2e gate
      //    fires after children close.
      expect(trace).hookFired("Stop", { decision: "approve" });

      // 5) Autonomy.
      expect(trace).noPermissionDenials();

      // 6) Plugin loaded.
      expect(trace.pluginErrors).toEqual([]);
      expect(
        trace.pluginsLoaded.some(
          (p: { name: string }) => p.name === "claude-workflow",
        ),
      ).toBe(true);

      // 7) Three-domain coverage in fileWrites: writes under server/,
      //    client/, AND migrations/. This is the structural proof that
      //    the orchestrator addressed all three domains, not just two.
      const sawServerEdit = trace.fileWrites.some((f) =>
        f.path.startsWith("server/"),
      );
      const sawClientEdit = trace.fileWrites.some((f) =>
        f.path.startsWith("client/"),
      );
      const sawMigrationEdit = trace.fileWrites.some((f) =>
        f.path.startsWith("migrations/"),
      );
      expect(sawServerEdit).toBe(true);
      expect(sawClientEdit).toBe(true);
      expect(sawMigrationEdit).toBe(true);

      // 8) Match the committed golden cassette.
      await expect(trace).matchesGolden(GOLDEN_PATH);
    },
    1_800_000,
  );
});

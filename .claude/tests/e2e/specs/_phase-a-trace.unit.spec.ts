/**
 * _phase-a-trace.unit.spec.ts — Phase A recorded-trace regression anchor.
 *
 * Loads the recorded rubric-revision-loop trace from
 * `cassettes/seed/rubric-revision-loop-2026-06-11T21-45-00-465Z.jsonl`
 * and asserts the same structural contract the live spec drives — except
 * fully offline, against the JSONL artifact. This is what the G8 plan
 * calls a "seed corpus" entry: it memorialises the Phase A live
 * validation evidence so we can re-verify the workflow's shape without
 * re-spending the live API budget. The seed/ directory is committed
 * (cassettes/replays/ is gitignored; see .gitignore allowlist).
 *
 * What this spec asserts about the recorded trace:
 *   1. The grader subagent fired exactly twice, both ROOT-parented
 *      (parentToolUseId === null). This is the corrected design from
 *      claude-workflow-plugin-l1r.6 — subagents cannot spawn subagents,
 *      so the grader is spawned at root by the orchestrator's
 *      RUBRIC-RELAY: grading-relay.
 *   2. The `qa-gate.sh grade-record` invocation appears at least once
 *      in toolCalls — that's how the orchestrator pipes the grader's
 *      verdict back through the QA gate.
 *   3. The Stop hook fired (event presence is the structural minimum;
 *      the live trace's `decision` field is sometimes null on this
 *      serializer shape — the OR-shape on task creation accommodates
 *      that, see runFixture.ts hook_response handling).
 *   4. The OR-shape task-creation check passes against this trace
 *      (it's the very trace that motivated the OR-shape adoption —
 *      `beadsTasksCreated` is empty but toolCalls carry the bd-create
 *      operations). This pins the regression: any future change that
 *      breaks the OR-shape against this trace also breaks the live spec.
 *
 * Why offline-against-a-fixed-JSONL instead of re-running live:
 * Per the v3 plan's principle 6 ("cost-irrelevant"), live runs are
 * evidence not replay substitutes. But CI needs a way to catch
 * regressions to the trace shape without paying the live cost on every
 * PR. The recorded trace is that anchor: if its structural shape ever
 * fails to satisfy the rubric-revision-loop spec's contract, we know
 * the contract has drifted and the next live run will fail too.
 *
 * Cross-references:
 *   - claude-workflow-plugin-l1r.7 (the bug this anchor secures)
 *   - claude-workflow-plugin-l1r.6 (root-orchestrated grader spawn)
 *   - specs/rubric-revision-loop.spec.ts (the live counterpart)
 */
import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import type { Trace } from "../lib/trace.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TRACE_PATH = path.resolve(
  __dirname,
  "..",
  "cassettes",
  "seed",
  "rubric-revision-loop-2026-06-11T21-45-00-465Z.jsonl",
);

// If the trace file isn't checked in (e.g. on a fresh clone where the
// replay dir is empty), we skip-with-log rather than failing. The anchor
// only makes sense when the artifact is present — a missing file is a
// "not yet captured" state, not a regression.
const HAVE_TRACE = existsSync(TRACE_PATH);

function loadTrace(): Trace {
  const raw = readFileSync(TRACE_PATH, "utf8").trim();
  // The replay JSONL carries the entire trace on a single line (see
  // runFixture.ts::writeTraceDump). Parse it as one JSON object.
  return JSON.parse(raw) as Trace;
}

describe.skipIf(!HAVE_TRACE)(
  "Phase A recorded-trace regression anchor: rubric-revision-loop 2026-06-11T21-45-00-465Z",
  () => {
    it("the grader subagent fired exactly twice, both root-parented", () => {
      const trace = loadTrace();
      // Plugin-qualifier-tolerant: accept "grader" or
      // "claude-workflow:grader" (the live trace uses the qualified form
      // because plugin.json registered the agent under
      // `claude-workflow:grader`). Mirrors assertions.ts::subagentInvoked.
      const stripQualifier = (s: string) =>
        s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
      const graderInvocations = trace.subagentInvocations.filter(
        (inv) => stripQualifier(inv.type) === "grader",
      );
      expect(graderInvocations.length).toBe(2);
      // Both at root — orchestrator (not a subagent) spawned them. This
      // is the structural proof of the claude-workflow-plugin-l1r.6 fix.
      for (const inv of graderInvocations) {
        expect(inv.parentToolUseId).toBeNull();
      }
    });

    it("the qa-gate.sh grade-record relay was invoked at least once", () => {
      const trace = loadTrace();
      const gradeRecordCalls = trace.toolCalls.filter((c) => {
        if (c.name !== "Bash") return false;
        const cmd =
          (c.input as { command?: string } | undefined)?.command ?? "";
        return /qa-gate\.sh\s+grade-record\b/.test(cmd);
      });
      expect(gradeRecordCalls.length).toBeGreaterThan(0);
    });

    it("the Stop hook fired (event presence is the structural minimum)", () => {
      const trace = loadTrace();
      const stopHooks = trace.hookOutputs.filter((h) => h.event === "Stop");
      expect(stopHooks.length).toBeGreaterThan(0);
    });

    it("the OR-shape task-creation check passes against this trace", () => {
      // This is THE assertion the spec fix is built around. The trace's
      // `beadsTasksCreated` is empty (the bug — runFixture's pre-flush
      // capture race), but the structural evidence in `toolCalls` is
      // unambiguous: two MCP `bd_create_task` calls + one Bash
      // `BD_NO_DAEMON=1 bd create` call. The OR-shape catches this.
      const trace = loadTrace();
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

      // Also pin the diagnostic shape we expect for this exact trace: at
      // least two MCP bd_create_task calls (orchestrator + retry) and at
      // least one Bash `bd create` call. This tightens the anchor so a
      // shape regression (e.g. the orchestrator stops emitting MCP calls)
      // is caught here rather than silently masked by the OR-shape.
      const mcpCreateCount = trace.toolCalls.filter(
        (c) =>
          c.name.includes("bd_create_task") ||
          c.name.includes("bd__create_task"),
      ).length;
      const bashBdCreateCount = trace.toolCalls.filter((c) => {
        if (c.name !== "Bash") return false;
        const cmd =
          (c.input as { command?: string } | undefined)?.command ?? "";
        return /\bbd\s+create\b/.test(cmd);
      }).length;
      expect(mcpCreateCount).toBeGreaterThanOrEqual(2);
      expect(bashBdCreateCount).toBeGreaterThanOrEqual(1);
    });

    it("the QA subagent ran at least once (rubric loop requires it)", () => {
      const trace = loadTrace();
      const stripQualifier = (s: string) =>
        s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
      const qaInvocations = trace.subagentInvocations.filter(
        (inv) => stripQualifier(inv.type) === "qa",
      );
      expect(qaInvocations.length).toBeGreaterThan(0);
    });

    it("the backend subagent ran (the under-tested change required a fix)", () => {
      const trace = loadTrace();
      const stripQualifier = (s: string) =>
        s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
      const backendInvocations = trace.subagentInvocations.filter(
        (inv) => stripQualifier(inv.type) === "backend",
      );
      expect(backendInvocations.length).toBeGreaterThan(0);
    });
  },
);

describe.skipIf(HAVE_TRACE)(
  "Phase A recorded-trace regression anchor: skip when artifact missing",
  () => {
    it("logs a skip notice — the recorded trace artifact is not present", () => {
      process.stderr.write(
        `SKIPPED: _phase-a-trace.unit.spec.ts (trace artifact missing at ${TRACE_PATH})\n`,
      );
      expect(true).toBe(true);
    });
  },
);

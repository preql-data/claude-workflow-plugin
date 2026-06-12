/**
 * _phase-b-run3-trace.unit.spec.ts — Phase B run-3 recorded-trace anchor.
 *
 * Loads the run-3 node-react-auth trace from
 * `cassettes/seed/node-react-auth-2026-06-12T00-50-56-312Z.jsonl` and pins
 * the structural shape observed during the second Phase B live validation
 * (after the 366.5 / 366.6 fixes had landed). Companion to
 * `_phase-b-trace.unit.spec.ts` which anchors the FIRST live trace
 * (2026-06-11T23-34-49-784Z) and pins the OPEN findings present at that
 * point.
 *
 * What this spec asserts about the run-3 trace:
 *
 *   1. The 366.5 capture fix is verified live: beadsTasksCreated is
 *      non-empty, and the OR-shape used in happy-path.spec.ts:90 passes.
 *      The auth-86b lineage (epic + 2 children + delivery anchor
 *      auth-b69) appears in beadsTasksCreated.
 *
 *   2. Subagent invocations: 7 total, with model-driven re-entry shape —
 *      claude-workflow:orchestrator (1, root), bare backend / frontend
 *      (2, inside orchestrator), and re-entered claude-workflow:backend
 *      / frontend / qa (4, root). Three of the four root-parented
 *      invocations are NOT what the seed trace had (qa x2 only); the
 *      orchestrator-as-subagent + backend/frontend root re-entry is the
 *      model's response to the Stop-hook block-then-recover cycle
 *      colliding with the closed epic. Pin the exact distribution so a
 *      future invariant tightening catches drift.
 *
 *   3. Code-graph MCP tools were available but UNUSED: all 7 tools
 *      appear in toolsAvailable (the 366.6 frontmatter widening is
 *      verified live), but zero impact_of calls anywhere in the trace.
 *      This is the headline open question of the run — QA had access
 *      to impact_of via the widened frontmatter and chose not to call
 *      it. The negative-fact anchor lets a future paid run that DOES
 *      call impact_of flip this assertion red, which is the desired
 *      signal.
 *
 *   4. Invariant verdicts against HEAD fixture.yaml:
 *        - stop-requires-approval: PASS
 *        - orchestrator-no-edits:  PASS
 *        - completion-contract:    SKIPPED (documented trace gap)
 *        - label-milestones:       FAIL — qa-pending missing from
 *          observed adds. The post-run beads diff is set-membership
 *          (added-minus-removed), and qa-pending was added then
 *          removed by qa-approved within the same run, so it never
 *          surfaces in the diff. Documented approximation in
 *          invariants.ts; pinning the failure here makes the gap
 *          visible without weakening the invariant.
 *        - declared-subagents-only: PASS
 *        - qa-queried-impact-of:   FAIL — code-graph tools present,
 *          fileWrites > 0, zero QA-attributable impact_of calls. The
 *          skip branch does NOT fire because the structural-availability
 *          predicate (toolsAvailable contains code-graph entries) is
 *          satisfied. This is the contract working correctly — QA's
 *          impact_of usage is a model-behaviour gap, not a structural
 *          one, and the invariant flags it accurately.
 *
 *   5. Plugin loaded cleanly, no errors, no permission denials.
 *
 *   6. fileWrites = 8, success, 46 turns, $8.11 cost. The run produced a
 *      complete delivery (auth-b69 closed-and-approved) within the
 *      60-turn ceiling.
 *
 * Cross-references:
 *   - claude-workflow-plugin-366.8 (the cause-B fixture-restore regression
 *     that this run exposed)
 *   - claude-workflow-plugin-366.9 (the cause-A qa-impact-of usage gap,
 *     filed as a follow-up — QA had the tool, did not call it)
 *   - cassettes/seed/node-react-auth-2026-06-11T23-34-49-784Z.jsonl (run 2
 *     anchor — the open findings of which the run-3 fixes were targeting)
 */
import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { evaluateAll, parseInvariantsFromYaml } from "../lib/invariants.js";
import type { Trace, ToolCall } from "../lib/trace.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TRACE_PATH = path.resolve(
  __dirname,
  "..",
  "cassettes",
  "seed",
  "node-react-auth-2026-06-12T00-50-56-312Z.jsonl",
);
const FIXTURE_YAML_PATH = path.resolve(
  __dirname,
  "..",
  "fixtures",
  "node-react-auth",
  "fixture.yaml",
);
const HAVE_TRACE = existsSync(TRACE_PATH);

function loadTrace(): Trace {
  const raw = readFileSync(TRACE_PATH, "utf8").trim();
  return JSON.parse(raw) as Trace;
}

function stripQualifier(s: string): string {
  return s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
}

describe.skipIf(!HAVE_TRACE)(
  "Phase B run-3 recorded-trace anchor: node-react-auth 2026-06-12T00-50-56-312Z",
  () => {
    it("plugin loaded cleanly: claude-workflow registered, no pluginErrors", () => {
      const trace = loadTrace();
      expect(trace.pluginErrors).toEqual([]);
      expect(
        trace.pluginsLoaded.some((p) => p.name === "claude-workflow"),
      ).toBe(true);
      // The pre-366.8 false-premise hypothesis (Question A in the
      // forensic brief) claimed code-graph tools "vanished" in run 3.
      // This pins the negative-rebuttal: all 7 tools were registered.
      const codeGraphTools = trace.toolsAvailable.filter((t) =>
        /code-graph/.test(t),
      );
      expect(codeGraphTools.length).toBe(7);
    });

    it("366.5 capture fix verified live: beadsTasksCreated non-empty with auth-86b lineage", () => {
      const trace = loadTrace();
      // The headline 366.5 fix flipping live: tasks now surface in the
      // post-run diff instead of being lost to the sync_base.jsonl
      // short-circuit.
      expect(trace.beadsTasksCreated.length).toBeGreaterThanOrEqual(3);
      const haveAuth86b = trace.beadsTasksCreated.some((id) =>
        id.startsWith("auth-86b"),
      );
      expect(haveAuth86b).toBe(true);
      // The OR-shape from happy-path.spec.ts:90 must pass — re-derive
      // it here so the anchor proves the live spec's contract holds.
      const sawBeadsTask =
        trace.beadsTasksCreated.length > 0 ||
        trace.toolCalls.some((c) => {
          if (
            c.name.includes("bd_create_task") ||
            c.name.includes("bd__create_task") ||
            c.name.includes("bd_create_epic") ||
            c.name.includes("bd__create_epic")
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
    });

    it("subagent invocations: 7 total with model-driven re-entry shape (orchestrator + bare children + root re-entry)", () => {
      const trace = loadTrace();
      expect(trace.subagentInvocations.length).toBe(7);

      // Pin the exact subagent distribution observed in run 3. This
      // shape differs from the run-2 seed (4 root invocations only):
      // run 3's model decided to invoke the orchestrator AS A SUBAGENT
      // from the root, then the orchestrator delegated to bare-named
      // backend / frontend internally, and the SDK separately re-
      // entered claude-workflow:backend / :frontend / :qa x2 at root.
      // Both bare and qualified forms count as the same role per the
      // declared-subagents-only invariant.
      const byTypeAndParent: Record<string, number> = {};
      for (const inv of trace.subagentInvocations) {
        const bare = stripQualifier(inv.type);
        const at =
          inv.parentToolUseId === null ? "root" : "nested";
        const key = `${bare}@${at}`;
        byTypeAndParent[key] = (byTypeAndParent[key] ?? 0) + 1;
      }
      // Root-parented: orchestrator x1, backend x1, frontend x1, qa x2.
      expect(byTypeAndParent["orchestrator@root"]).toBe(1);
      expect(byTypeAndParent["backend@root"]).toBe(1);
      expect(byTypeAndParent["frontend@root"]).toBe(1);
      expect(byTypeAndParent["qa@root"]).toBe(2);
      // Nested (inside the orchestrator): bare backend / frontend.
      expect(byTypeAndParent["backend@nested"]).toBe(1);
      expect(byTypeAndParent["frontend@nested"]).toBe(1);
    });

    it("code-graph MCP server registered with all 7 tools, but zero impact_of calls anywhere (run-3 open finding)", () => {
      const trace = loadTrace();

      // Server-level: connected under plugin-qualified name.
      const cgServers = (trace.systemInit?.mcpServers ?? []).filter((s) =>
        /code-graph/.test(s.name),
      );
      expect(
        cgServers.some(
          (s) =>
            s.name === "plugin:claude-workflow:code-graph" &&
            s.status === "connected",
        ),
      ).toBe(true);

      // Tool-level: every Phase B tool in toolsAvailable.
      const expectedTools = [
        "code_search",
        "code_context",
        "code_index_health",
        "dead_code",
        "dependency_path",
        "impact_of",
        "symbol_callers",
      ];
      for (const t of expectedTools) {
        const fullName = `mcp__plugin_claude-workflow_code-graph__${t}`;
        expect(
          trace.toolsAvailable.includes(fullName),
          `expected code-graph tool '${t}' in toolsAvailable but did not find '${fullName}'`,
        ).toBe(true);
      }

      // NEGATIVE-FACT ANCHOR: zero impact_of calls anywhere in the run.
      // QA had the tool via the 366.6 widened frontmatter but chose not
      // to call it. When a future paid run DOES call impact_of, this
      // assertion goes red — that's the desired signal driving the
      // anchor refresh.
      const impactCalls = trace.toolCalls.filter((c) =>
        /code-graph.*impact_of|^impact_of$/.test(c.name),
      );
      expect(impactCalls.length).toBe(0);

      // Cross-derive the QA-attributable count to triple-check.
      const qaTaskIds = new Set(
        trace.subagentInvocations
          .filter((i) => stripQualifier(i.type) === "qa")
          .map((i) => i.toolUseId),
      );
      const callIndex = new Map<string, ToolCall>();
      for (const c of trace.toolCalls) callIndex.set(c.id, c);
      function isInsideQa(call: ToolCall): boolean {
        let p = call.parentToolUseId;
        const seen = new Set<string>();
        while (p && !seen.has(p)) {
          seen.add(p);
          if (qaTaskIds.has(p)) return true;
          const par = callIndex.get(p);
          if (!par) return false;
          p = par.parentToolUseId;
        }
        return false;
      }
      const qaImpactCalls = impactCalls.filter(isInsideQa);
      expect(qaImpactCalls.length).toBe(0);
    });

    it("invariant verdicts against HEAD fixture.yaml: 3 pass + 1 skip + 2 fail (verbatim from the evaluator)", () => {
      const trace = loadTrace();
      const yamlContent = readFileSync(FIXTURE_YAML_PATH, "utf8");
      const specs = parseInvariantsFromYaml(yamlContent);
      // Sanity check the parse succeeded.
      expect(specs.length).toBe(6);

      const agg = evaluateAll(trace, specs);

      // Aggregate shape: 2 failed, 1 skipped, allPassed=false.
      expect(agg.allPassed).toBe(false);
      expect(agg.skipped).toEqual(["completion-contract"]);
      expect(agg.failed.sort()).toEqual(
        ["label-milestones", "qa-queried-impact-of"].sort(),
      );

      // Per-invariant verdicts — pin each one so a future engine change
      // that flips any of them (e.g. tightening the skip branch on
      // qa-queried-impact-of, or extending label-milestones to inspect
      // tool_use sequencing instead of beadsLabelTransitions) is loud.
      const resultsByName = Object.fromEntries(
        agg.results.map((r) => [r.name, r.result]),
      );
      expect(resultsByName["stop-requires-approval"]?.pass).toBe(true);
      expect(resultsByName["orchestrator-no-edits"]?.pass).toBe(true);
      expect(resultsByName["completion-contract"]?.skipped).toBe(true);
      expect(resultsByName["completion-contract"]?.pass).toBe(true);
      expect(resultsByName["label-milestones"]?.pass).toBe(false);
      expect(resultsByName["label-milestones"]?.detail ?? "").toContain(
        "missing milestone label add(s): [qa-pending]",
      );
      expect(resultsByName["declared-subagents-only"]?.pass).toBe(true);
      expect(resultsByName["qa-queried-impact-of"]?.pass).toBe(false);
      // The skip branch did NOT fire — confirming the
      // structural-availability predicate (code-graph tools present)
      // was satisfied. This is what makes the failure a model-behaviour
      // gap rather than a tooling regression.
      expect(resultsByName["qa-queried-impact-of"]?.skipped).toBeFalsy();
      expect(resultsByName["qa-queried-impact-of"]?.detail ?? "").toContain(
        "0 impact_of call(s) from QA",
      );
    });

    it("no permission denials: autonomy principle holds", () => {
      const trace = loadTrace();
      expect(trace.permissionDenials).toEqual([]);
    });

    it("Stop-hook block-then-recover cycle: at least 2 blocks + at least 2 allows, both blocks cite QA-approval", () => {
      const trace = loadTrace();
      const stopHooks = trace.hookOutputs.filter((h) => h.event === "Stop");
      const blocks = stopHooks.filter((h) => h.decision === "block");
      const allows = stopHooks.filter(
        (h) =>
          h.decision === "approve" ||
          h.decision === undefined ||
          h.decision === null,
      );
      // Run 3 produced 6 Stop firings (3 block + 3 allow) per the
      // double-recovery path triggered by the orchestrator-as-subagent
      // shape colliding with the closed-epic + delivery-anchor pattern.
      // We assert lower bounds rather than exact counts because the
      // recovery cycle's exact length depends on how the model phrases
      // its final summary — we want the anchor to survive minor
      // rewording.
      expect(blocks.length).toBeGreaterThanOrEqual(2);
      expect(allows.length).toBeGreaterThanOrEqual(2);
      for (const b of blocks) {
        expect(b.reason ?? "").toContain("QA approval required");
      }
    });

    it("the workflow shipped: 8 fileWrites, 46 turns, success result", () => {
      const trace = loadTrace();
      expect(trace.fileWrites.length).toBe(8);
      expect(trace.result.subtype).toBe("success");
      expect(trace.result.turns).toBe(46);
    });
  },
);

describe.skipIf(HAVE_TRACE)(
  "Phase B run-3 recorded-trace anchor: skip when artifact missing",
  () => {
    it("logs a skip notice — the recorded trace artifact is not present", () => {
      process.stderr.write(
        `SKIPPED: _phase-b-run3-trace.unit.spec.ts (trace artifact missing at ${TRACE_PATH})\n`,
      );
      expect(true).toBe(true);
    });
  },
);

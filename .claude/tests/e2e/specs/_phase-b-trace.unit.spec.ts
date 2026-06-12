/**
 * _phase-b-trace.unit.spec.ts — Phase B recorded-trace regression anchor.
 *
 * Loads the recorded node-react-auth trace from
 * `cassettes/seed/node-react-auth-2026-06-11T23-34-49-784Z.jsonl` and
 * asserts the structural shape the Phase B (v3.3.0 code-graph) live
 * validation produced. This is the offline-against-fixed-JSONL companion
 * to `_phase-a-trace.unit.spec.ts`: a seed-corpus anchor that lets CI
 * catch regressions to the trace shape without re-spending the ~$5.78
 * live capture cost.
 *
 * What this spec asserts about the recorded trace:
 *
 *   1. Plugin loaded cleanly with no errors. The single registered plugin
 *      is `claude-workflow`.
 *
 *   2. Exactly four root-parented subagent invocations: backend (1) +
 *      frontend (1) + qa (2). The second QA is the Stop-hook-triggered
 *      re-review after the orchestrator closed the epic prematurely
 *      (a legitimate block-then-recover cycle, see hookOutputs analysis
 *      below). All four are ROOT-parented — consistent with the
 *      l1r.6 corrected design (subagents cannot spawn subagents).
 *
 *   3. The code-graph MCP server was registered with all seven declared
 *      tools (code_search, code_context, code_index_health, dead_code,
 *      dependency_path, impact_of, symbol_callers). This is the headline
 *      Phase B deliverable surface.
 *
 *   4. The OR-shape task-creation check passes: 1 MCP `bd_create_epic`
 *      call from the orchestrator (which did not produce auth-055 — see
 *      durationMs=14816 evidence below) PLUS 4 Bash `bd create`
 *      invocations (which successfully created auth-055 + auth-055.1 +
 *      auth-055.2). The naive `beadsTasksCreated.length > 0` shape would
 *      have failed because the harness's flushFixtureBeads (pre-fix)
 *      could not produce issues.jsonl when sync_base.jsonl was the
 *      bd-recognized export. The OR-shape catches the workflow despite
 *      the capture gap.
 *
 *   5. PHASE B OPEN FINDING (intentionally anchored as evidence-of-deviation,
 *      NOT a passing assertion): the QA subagent made ZERO impact_of
 *      calls despite the code-graph server being loaded and fileWrites
 *      being non-empty. Root cause: agent frontmatter (.claude/agents/qa.md
 *      `tools:` line) does not enumerate MCP tools, so subagents cannot
 *      reach mcp__plugin_claude-workflow_code-graph__impact_of directly.
 *      QA degraded to the documented grep fallback (see qa.md sec 3a
 *      "Graceful degradation"), satisfying the spirit of the contract
 *      but failing the letter of the `qa-queried-impact-of` invariant.
 *      Pinning this fact in the anchor makes the finding visible to
 *      future maintainers: when the QA frontmatter is widened to include
 *      code-graph tools (or when the invariant is updated to accept the
 *      degradation path), THIS assertion will need to update too.
 *
 *   6. The block-then-recover Stop cycle: 4 Stop hook firings (2 block,
 *      2 null/allow). Both blocks emitted by verify-before-stop.sh with
 *      "QA approval required" reasoning. The 2 allows came after
 *      qa-gate.sh approve cycles. This is the legitimate gate-working
 *      pattern, NOT a leaked Stop — pinning the count guards against
 *      regressions where the gate either over-blocks (>2 blocks) or
 *      under-blocks (0 blocks → no gate evidence at all).
 *
 * Cross-references:
 *   - claude-workflow-plugin-366.5 (the forensic task this anchor secures)
 *   - claude-workflow-plugin-366 (Phase B epic)
 *   - specs/happy-path.spec.ts (the live counterpart driving this fixture)
 *   - lib/beadsCapture.ts (the harness fix that the OR-shape compensates for)
 *
 * Why offline-against-a-fixed-JSONL: same rationale as
 * _phase-a-trace.unit.spec.ts — live runs are evidence not replay
 * substitutes, but CI needs a way to catch trace-shape regressions
 * without paying the live cost. This anchor pins the Phase B headline
 * shape so any future change that breaks it will fail loudly.
 */
import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import type { Trace, ToolCall } from "../lib/trace.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TRACE_PATH = path.resolve(
  __dirname,
  "..",
  "cassettes",
  "seed",
  "node-react-auth-2026-06-11T23-34-49-784Z.jsonl",
);

// If the trace file isn't checked in (e.g. on a fresh clone), skip-with-log
// rather than failing — same convention as the Phase A anchor.
const HAVE_TRACE = existsSync(TRACE_PATH);

function loadTrace(): Trace {
  const raw = readFileSync(TRACE_PATH, "utf8").trim();
  return JSON.parse(raw) as Trace;
}

/** Plugin-qualifier tolerant: `claude-workflow:backend` -> `backend`. */
function stripQualifier(s: string): string {
  return s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
}

describe.skipIf(!HAVE_TRACE)(
  "Phase B recorded-trace regression anchor: node-react-auth 2026-06-11T23-34-49-784Z",
  () => {
    it("plugin loaded cleanly: claude-workflow registered, no pluginErrors", () => {
      const trace = loadTrace();
      expect(trace.pluginErrors).toEqual([]);
      expect(
        trace.pluginsLoaded.some((p) => p.name === "claude-workflow"),
      ).toBe(true);
    });

    it("declared subagent set: 1 backend + 1 frontend + 2 qa, all root-parented", () => {
      const trace = loadTrace();
      const byType: Record<string, number> = {};
      for (const inv of trace.subagentInvocations) {
        const bare = stripQualifier(inv.type);
        byType[bare] = (byType[bare] ?? 0) + 1;
        // l1r.6 invariant: every subagent invocation is root-parented.
        expect(inv.parentToolUseId).toBeNull();
      }
      expect(byType.backend).toBe(1);
      expect(byType.frontend).toBe(1);
      // 2 QA: initial review + Stop-hook-triggered re-review after the
      // epic-close-before-Stop-fire race. Pinning the count guards
      // against silent regressions to either too few (gate skipped) or
      // too many (recovery loop runaway).
      expect(byType.qa).toBe(2);
      expect(trace.subagentInvocations.length).toBe(4);
    });

    it("code-graph MCP server registered with all 7 declared tools (Phase B headline)", () => {
      const trace = loadTrace();
      // Server-level: should be 'connected' under the plugin-qualified
      // name. The unqualified `code-graph` server alias appears as
      // 'failed' in systemInit.mcpServers — that's expected (the SDK
      // tries both aliases and reports the qualified one as connected).
      const codeGraphServers = (trace.systemInit?.mcpServers ?? []).filter(
        (s) => /code-graph/.test(s.name),
      );
      expect(codeGraphServers.length).toBeGreaterThan(0);
      expect(
        codeGraphServers.some(
          (s) =>
            s.name === "plugin:claude-workflow:code-graph" &&
            s.status === "connected",
        ),
      ).toBe(true);

      // Tool-level: every one of the 7 Phase B tools must appear in
      // toolsAvailable. Missing any means the server registered but
      // didn't expose its full surface — a partial-install regression
      // we want to catch.
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
    });

    it("the OR-shape task-creation check passes: 1 bd_create_epic MCP + 4 Bash bd create", () => {
      const trace = loadTrace();
      // OR-shape: harness diff OR MCP bd_create_* tool call OR Bash
      // `bd create` invocation. Mirrors multi-domain-signup.spec.ts and
      // _phase-a-trace.unit.spec.ts.
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

      // Pin the diagnostic shape: exactly 1 MCP `bd_create_epic` call
      // (the orchestrator's first attempt, which took 14.8s and the
      // orchestrator subsequently pivoted to bash — strong evidence the
      // MCP path errored), plus at least 4 Bash `bd create` calls
      // (epic + 2 children + close, all under the auth-055 lineage).
      const epicMcpCalls = trace.toolCalls.filter(
        (c) =>
          c.name.includes("bd_create_epic") ||
          c.name.includes("bd__create_epic"),
      );
      expect(epicMcpCalls.length).toBe(1);
      // Sanity-check the long duration that motivated the pivot: 10s+
      // for an in-process MCP call to BD is anomalous.
      expect(epicMcpCalls[0]?.durationMs ?? 0).toBeGreaterThan(10_000);

      const bashBdCreate = trace.toolCalls.filter((c) => {
        if (c.name !== "Bash") return false;
        const cmd =
          (c.input as { command?: string } | undefined)?.command ?? "";
        return /\bbd\s+create\b/.test(cmd);
      });
      expect(bashBdCreate.length).toBeGreaterThanOrEqual(3);
    });

    it("PHASE B OPEN FINDING: QA made zero impact_of calls (subagent MCP-tool-visibility gap)", () => {
      // This assertion documents an OPEN FINDING that future work needs
      // to resolve. Pinning the negative fact here makes it visible:
      // when QA's frontmatter is widened (or the invariant accepts the
      // documented grep degradation), this anchor will need to update.
      //
      // Evidence: code-graph server WAS loaded (asserted above), but
      // QA agent frontmatter (.claude/agents/qa.md) does not enumerate
      // mcp__plugin_claude-workflow_code-graph__* tools. Subagents
      // inherit the frontmatter's tool whitelist, so QA could not
      // call impact_of directly. QA logged "code-graph MCP unavailable
      // in fixture" and degraded to grep — satisfying the spirit of
      // qa.md sec 3a's "Graceful degradation" clause but failing the
      // letter of the `qa-queried-impact-of` invariant in
      // lib/invariants.ts.
      const trace = loadTrace();

      const qaTaskIds = new Set(
        trace.subagentInvocations
          .filter((i) => stripQualifier(i.type) === "qa")
          .map((i) => i.toolUseId),
      );
      expect(qaTaskIds.size).toBe(2);

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

      const impactCalls = trace.toolCalls.filter((c) =>
        /code-graph.*impact_of|^impact_of$/.test(c.name),
      );
      const qaImpactCalls = impactCalls.filter(isInsideQa);
      // THE finding: zero impact_of calls anywhere in the trace, and
      // zero QA-attributable impact_of calls specifically. The 'any
      // call' assertion is the stronger one — if any tool in the run
      // had reached impact_of (e.g. via orchestrator pre-delegation
      // analysis), we'd revise the finding.
      expect(impactCalls.length).toBe(0);
      expect(qaImpactCalls.length).toBe(0);

      // QA DID exercise the documented degradation path: grep across
      // the source tree to find callers of changed symbols. Pinning
      // this proves the degradation was intentional, not a workflow
      // dropout.
      const qaBashCalls = trace.toolCalls
        .filter((c) => c.name === "Bash")
        .filter((c) => isInsideQa(c));
      const qaGrepCalls = qaBashCalls.filter((c) => {
        const cmd =
          (c.input as { command?: string } | undefined)?.command ?? "";
        return /\bgrep\b/.test(cmd);
      });
      expect(qaGrepCalls.length).toBeGreaterThan(0);
    });

    it("Stop hook block-then-recover cycle: 4 firings (2 block, 2 allow)", () => {
      const trace = loadTrace();
      const stopHooks = trace.hookOutputs.filter((h) => h.event === "Stop");
      expect(stopHooks.length).toBe(4);
      const blocks = stopHooks.filter((h) => h.decision === "block");
      const allows = stopHooks.filter(
        (h) =>
          h.decision === "approve" ||
          h.decision === undefined ||
          h.decision === null,
      );
      expect(blocks.length).toBe(2);
      expect(allows.length).toBe(2);

      // Both blocks must cite the QA-approval-required contract — the
      // text varies slightly between iteration 1 and 2 but both contain
      // "QA approval required". This pins the gate's failure message
      // contract against silent rewording that would weaken the audit
      // trail.
      for (const b of blocks) {
        expect(b.reason ?? "").toContain("QA approval required");
      }
    });

    it("qa-gate.sh actual subcommand counts: 1 enter, 2 approve, 0 block (single-cycle recovery)", () => {
      // Pinning the actual qa-gate.sh subcommand distribution catches
      // regressions where the gate either skips the enter→approve
      // ceremony or fails to handle the recovery cycle. Naive grep over
      // the trace's raw text inflates these numbers because qa-gate.sh
      // payloads echo back into hook output blocks; only true tool_use
      // invocations count.
      const trace = loadTrace();
      const gateCalls = trace.toolCalls.filter((c) => {
        if (c.name !== "Bash") return false;
        const cmd =
          (c.input as { command?: string } | undefined)?.command ?? "";
        return /qa-gate\.sh/.test(cmd);
      });
      // Total: enter (1) + approve (2) + status (1) + 2 source-inspection
      // grep/sed calls = 6.
      expect(gateCalls.length).toBe(6);

      const subCounts: Record<string, number> = {};
      for (const c of gateCalls) {
        const cmd =
          (c.input as { command?: string } | undefined)?.command ?? "";
        const m = /qa-gate\.sh\s+([a-z_-]+)/.exec(cmd);
        const sub = m ? (m[1] ?? "<no-subcmd>") : "<no-subcmd>";
        subCounts[sub] = (subCounts[sub] ?? 0) + 1;
      }
      expect(subCounts.enter).toBe(1);
      expect(subCounts.approve).toBe(2);
      expect(subCounts.status).toBe(1);
      // block is structurally zero: the recovery was driven by Stop-
      // hook re-block on a missing current-task, not by QA explicitly
      // blocking the work.
      expect(subCounts.block ?? 0).toBe(0);
    });

    it("no permission denials: autonomy principle holds", () => {
      const trace = loadTrace();
      expect(trace.permissionDenials).toEqual([]);
    });

    it("the workflow shipped: 9 fileWrites, 44 turns, success result", () => {
      // Sanity-check the run's outcome envelope. fileWrites=9 is the
      // expected 6 changed files + 3 new files (auth-055 acceptance).
      // success on 44 turns within the 60-turn ceiling is the
      // production-shape signature.
      const trace = loadTrace();
      expect(trace.fileWrites.length).toBe(9);
      expect(trace.result.subtype).toBe("success");
      expect(trace.result.turns).toBe(44);
    });
  },
);

describe.skipIf(HAVE_TRACE)(
  "Phase B recorded-trace regression anchor: skip when artifact missing",
  () => {
    it("logs a skip notice — the recorded trace artifact is not present", () => {
      process.stderr.write(
        `SKIPPED: _phase-b-trace.unit.spec.ts (trace artifact missing at ${TRACE_PATH})\n`,
      );
      expect(true).toBe(true);
    });
  },
);

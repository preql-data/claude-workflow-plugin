/**
 * _phase-b-run4-trace.unit.spec.ts — Phase B run-4 recorded-trace anchor.
 *
 * Loads the run-4 node-react-auth trace from
 * `cassettes/seed/node-react-auth-2026-06-12T02-18-12-871Z.jsonl` and pins
 * the structural shape observed during the THIRD Phase B live validation
 * (after the 366.8 dirty-on-entry recovery fix and the 366.9 impact_of cue
 * fix had landed). Companion to `_phase-b-trace.unit.spec.ts` (run 2)
 * and `_phase-b-run3-trace.unit.spec.ts` (run 3).
 *
 * Headline run-4 findings (the "why" of this anchor):
 *
 *   1. **satisfiesInvariants() evaluated LIVE for the first time.** The
 *      366.8 fix preserved the fixture's invariants block end-to-end
 *      (no dirty-entry recovery wipe; the post-run working tree restore
 *      did NOT regress fixture.yaml). The engine ran against the recorded
 *      trace and emitted the verdict the live spec asserts on.
 *
 *   2. **Cue-channel gap, surfaced with citation.** The Stop hook fired 2
 *      block events with the QA-approval-required template. Each block's
 *      reason text contains the OLD 4-item checklist — NEITHER "FIRST: for
 *      every changed file" NOR "impact_of" appears in either block. The
 *      fixture's vendored `.claude/scripts/verify-before-stop.sh` (last
 *      touched in commit a8a7bcf "v3 upgrade + G8 test harness") predates
 *      the 366.9 cue-fix commit 8f07ea9, so the fixture-local script
 *      that the plugin's hooks.json invokes via $CLAUDE_PROJECT_DIR
 *      lacks the cue. The cue IS present in the repo's
 *      `.claude/scripts/verify-before-stop.sh` (line 977-982), but the
 *      fixture renders its own copy and that copy is stale.
 *
 *   3. **Orchestrator's free-composed QA prompt DID carry impact_of —
 *      explicitly.** The first QA Agent invocation prompt (toolUseId
 *      `toolu_018kaX5SpZ2NttWtT3X72aCJ`) names the tool, the alias, and
 *      the invariant by name: "use `mcp__plugin_claude-workflow_code-graph
 *      __impact_of` ... so the `qa-queried-impact-of` invariant is
 *      satisfied for this trace". Despite that, impact_of was called
 *      ZERO times — confirming the gap is not "the cue never reached
 *      QA" but rather "even explicit on-the-nose orchestrator instruction
 *      does not move the model".
 *
 *   4. **label-milestones structural failure persists.** The engine
 *      output the identical missing-`qa-pending` failure it produced on
 *      run 3, even though the run DEMONSTRABLY cycled the QA gate
 *      correctly (qa-approved sits on every relevant task and qa-pending
 *      was added → removed in-run by `qa-gate.sh approve`). The
 *      `beadsLabelTransitions` field captures net diffs, not transition
 *      events, so transient labels are invisible. Tracked as the new
 *      bug filed alongside this spec.
 *
 *   5. **Spec failed/passed mix per the engine (verbatim):**
 *        - stop-requires-approval: PASS — "2 Stop:allow event(s) with
 *          qa-approved/qa-deferred recorded on: [auth-neb, auth-neb.1,
 *          auth-neb.2]"
 *        - orchestrator-no-edits:  PASS — "no Write/Edit/MultiEdit
 *          attributable to the orchestrator"
 *        - completion-contract:    SKIP — documented trace gap
 *        - label-milestones:       FAIL — "missing milestone label
 *          add(s): [qa-pending] — observed adds across run: [backend,
 *          devops, frontend, qa-approved]"
 *        - declared-subagents-only: PASS — "all 4 invocation(s) matched
 *          declared specialists or always-allowed roles"
 *        - qa-queried-impact-of:   FAIL — "0 impact_of call(s) from QA,
 *          expected at least 1. fileWrites=7 ... QA must call impact_of
 *          to surface high-fan-in regression candidates (extends J19)."
 *
 *   6. **Auth task lineage captured again (366.5 still verified):** 4
 *      Beads tasks created (`auth-aug`, `auth-neb`, `auth-neb.1`,
 *      `auth-neb.2`). The capture path stayed green; this trace also
 *      verifies that the 366.8 fixture-restore fix did not regress the
 *      365.5 capture path.
 *
 *   7. **Code-graph tools registered but unused (negative-fact anchor
 *      carries forward):** All 7 tools present in toolsAvailable; 0
 *      calls. Future paid run that DOES call impact_of will flip the
 *      assertion red — desired signal.
 *
 * Cross-references:
 *   - claude-workflow-plugin-366.8 (the dirty-on-entry recovery fix
 *     whose effects this trace shows working)
 *   - claude-workflow-plugin-366.9 (the cue-fix whose hook surface
 *     this trace shows didn't fire; superseded by a new follow-up bug)
 *   - cassettes/seed/node-react-auth-2026-06-12T00-50-56-312Z.jsonl
 *     (run 3 — the offline invariant verdict was identical; this run's
 *     value is that it produced the verdict LIVE in-spec).
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
  "node-react-auth-2026-06-12T02-18-12-871Z.jsonl",
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
  "Phase B run-4 recorded-trace anchor: node-react-auth 2026-06-12T02-18-12-871Z",
  () => {
    it("plugin loaded cleanly: claude-workflow registered, no pluginErrors, no permissionDenials", () => {
      const trace = loadTrace();
      expect(trace.pluginErrors).toEqual([]);
      expect(trace.permissionDenials).toEqual([]);
      expect(
        trace.pluginsLoaded.some((p) => p.name === "claude-workflow"),
      ).toBe(true);
    });

    it("code-graph MCP: 7 tools available, all expected names present (verify carryover from 366.6)", () => {
      const trace = loadTrace();
      const codeGraphTools = trace.toolsAvailable.filter((t) =>
        /code-graph/.test(t),
      );
      expect(codeGraphTools.length).toBe(7);
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

    it("auth task lineage captured: 4 tasks created (auth-aug + auth-neb epic + 2 children)", () => {
      const trace = loadTrace();
      // 366.5 fix still verified — capture path green. Run-4 produced a
      // 4-task lineage: a devops follow-up `auth-aug`, the auth epic
      // `auth-neb`, and its 2 children `auth-neb.1` / `auth-neb.2`.
      expect(trace.beadsTasksCreated.length).toBe(4);
      expect(trace.beadsTasksCreated.sort()).toEqual(
        ["auth-aug", "auth-neb", "auth-neb.1", "auth-neb.2"].sort(),
      );
    });

    it("NEGATIVE-FACT ANCHOR: 0 impact_of calls in the entire trace (run-4 still flags the model-behaviour gap)", () => {
      const trace = loadTrace();
      // The 366.9 cue fix is in qa.md 3a (live repo) and in the repo's
      // verify-before-stop.sh template, yet impact_of was not invoked.
      // The new follow-up bug filed alongside this run carries this
      // forward; the spec pins it so a future paid run that DOES call
      // impact_of will flip red and force the anchor refresh.
      const impactCalls = trace.toolCalls.filter((c) =>
        /code-graph.*impact_of|^impact_of$/.test(c.name),
      );
      expect(impactCalls.length).toBe(0);

      // Cross-derive the QA-attributable count.
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

    it("Stop hook cue-channel gap: 2 Stop:block events fired, NEITHER carried the impact_of cue (fixture-local script is stale)", () => {
      const trace = loadTrace();
      const stopHooks = trace.hookOutputs.filter((h) => h.event === "Stop");
      // Run 4 produced 4 Stop firings (2 block + 2 allow). The block-then-
      // recover cycle's exact length is model-driven — assert exact for
      // this trace and use lower bounds elsewhere.
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
      // Headline assertion: neither block carried the cue. This is what
      // makes the new follow-up bug different from 366.9 — the cue text
      // SHIPPED on the repo's surface but the fixture's vendored copy
      // is what runs in-fixture, and that copy was rendered before the
      // 8f07ea9 fix. Bears repeating in the test so a re-rendered fixture
      // (or a re-rendered-into-fixture install path fix) flips this red.
      for (const b of blocks) {
        const reason = b.reason ?? "";
        expect(reason).toContain("QA approval required");
        expect(reason).not.toContain("FIRST: for every changed file");
        expect(reason).not.toContain("impact_of");
      }
    });

    it("orchestrator's QA-prompt composition DID name impact_of and the invariant (free composition compensated for the hook gap)", () => {
      const trace = loadTrace();
      // Locate the QA Agent invocation by tool_use id. Run 4 produced 2
      // QA spawns; the first one is the substantive review (the second
      // is an epic-level re-application after the orchestrator
      // prematurely closed the epic). The first one is the carrier of
      // the impact_of language.
      const qaAgents = trace.toolCalls.filter(
        (c) =>
          c.name === "Agent" &&
          /:?qa$/i.test(
            (c.input as { subagent_type?: string } | undefined)
              ?.subagent_type ?? "",
          ),
      );
      expect(qaAgents.length).toBe(2);
      const firstQaPrompt =
        (qaAgents[0]!.input as { prompt?: string } | undefined)?.prompt ?? "";
      // Pin the exact load-bearing strings the prompt contained. These
      // citations make the bug filing reproducible: any reviewer can
      // open this trace and search the captured prompt for the exact
      // language. Note the bare-name fallback alias is also present —
      // that's what the orchestrator wrote.
      expect(firstQaPrompt).toContain("impact_of");
      expect(firstQaPrompt).toContain(
        "mcp__plugin_claude-workflow_code-graph__impact_of",
      );
      expect(firstQaPrompt).toContain("qa-queried-impact-of");
      // And yet (assertion below): 0 impact_of calls. The prompt told
      // QA exactly which tool to call and which invariant it satisfies.
      // The model still did not call it.
    });

    it("invariant verdicts against HEAD fixture.yaml: 3 pass + 1 skip + 2 fail (verbatim from the engine, live-evaluable)", () => {
      const trace = loadTrace();
      const yamlContent = readFileSync(FIXTURE_YAML_PATH, "utf8");
      const specs = parseInvariantsFromYaml(yamlContent);
      // Sanity check the parse succeeded.
      expect(specs.length).toBe(6);
      // Sanity check the fixture.yaml carries the expected invariants
      // (the 366.8 fix-effect we are anchoring is that this block is
      // not wiped by the dirty-on-entry self-heal; the run-3 anchor's
      // forensic captured the same parse against the same yaml).
      const names = specs.map((s) => s.name).sort();
      expect(names).toEqual(
        [
          "stop-requires-approval",
          "orchestrator-no-edits",
          "completion-contract",
          "label-milestones",
          "declared-subagents-only",
          "qa-queried-impact-of",
        ].sort(),
      );

      const agg = evaluateAll(trace, specs);
      // Aggregate: 2 failed, 1 skipped, allPassed=false.
      expect(agg.allPassed).toBe(false);
      expect(agg.skipped).toEqual(["completion-contract"]);
      expect(agg.failed.sort()).toEqual(
        ["label-milestones", "qa-queried-impact-of"].sort(),
      );

      // Per-invariant verdicts — pin each one including the exact detail
      // substring so an engine change that subtly reshapes the message
      // is loud.
      const resultsByName = Object.fromEntries(
        agg.results.map((r) => [r.name, r.result]),
      );
      expect(resultsByName["stop-requires-approval"]?.pass).toBe(true);
      expect(resultsByName["stop-requires-approval"]?.detail ?? "").toContain(
        "Stop:allow event(s) with qa-approved/qa-deferred",
      );

      expect(resultsByName["orchestrator-no-edits"]?.pass).toBe(true);
      expect(resultsByName["orchestrator-no-edits"]?.detail ?? "").toContain(
        "no Write/Edit/MultiEdit attributable to the orchestrator",
      );

      expect(resultsByName["completion-contract"]?.skipped).toBe(true);

      expect(resultsByName["label-milestones"]?.pass).toBe(false);
      // Verbatim missing-label string is what the new structural bug
      // filing cites — pin it precisely.
      expect(resultsByName["label-milestones"]?.detail ?? "").toContain(
        "missing milestone label add(s): [qa-pending]",
      );
      expect(resultsByName["label-milestones"]?.detail ?? "").toContain(
        "observed adds across run: [backend, devops, frontend, qa-approved]",
      );

      expect(resultsByName["declared-subagents-only"]?.pass).toBe(true);

      expect(resultsByName["qa-queried-impact-of"]?.pass).toBe(false);
      // The skip branch did NOT fire (structural availability satisfied).
      expect(resultsByName["qa-queried-impact-of"]?.skipped).toBeFalsy();
      expect(resultsByName["qa-queried-impact-of"]?.detail ?? "").toContain(
        "0 impact_of call(s) from QA",
      );
      expect(resultsByName["qa-queried-impact-of"]?.detail ?? "").toContain(
        "fileWrites=7",
      );
    });

    it("workflow shipped: 7 fileWrites, 41 turns, success, $5.46 cost, durationMs=1330711 (~22 min)", () => {
      const trace = loadTrace();
      // Cost recorded; we tolerate small float drift on this assertion.
      expect(trace.result.subtype).toBe("success");
      expect(trace.fileWrites.length).toBe(7);
      expect(trace.result.turns).toBe(41);
      // Cost surfaces in bd notes / ops review; pin to two decimals.
      const cost = trace.result.totalCostUsd ?? 0;
      expect(cost).toBeGreaterThan(5.4);
      expect(cost).toBeLessThan(5.5);
      expect(trace.result.durationMs).toBe(1330711);
    });

    it("subagent invocation shape: 4 root invocations (backend, frontend, qa x2) — no orchestrator-as-subagent re-entry this run", () => {
      const trace = loadTrace();
      expect(trace.subagentInvocations.length).toBe(4);
      const byTypeAndParent: Record<string, number> = {};
      for (const inv of trace.subagentInvocations) {
        const bare = stripQualifier(inv.type);
        const at = inv.parentToolUseId === null ? "root" : "nested";
        const key = `${bare}@${at}`;
        byTypeAndParent[key] = (byTypeAndParent[key] ?? 0) + 1;
      }
      // Run 4 differs from run 3 (which had the orchestrator-as-subagent
      // re-entry shape). Here the orchestrator stays at root and spawns
      // backend / frontend / qa(x2) directly.
      expect(byTypeAndParent["backend@root"]).toBe(1);
      expect(byTypeAndParent["frontend@root"]).toBe(1);
      expect(byTypeAndParent["qa@root"]).toBe(2);
      expect(byTypeAndParent["orchestrator@root"] ?? 0).toBe(0);
    });

    it("toolCalls volume: 159 total — dominated by Bash (119) plus Read/Write/Grep/Agent + 1 bd_create_epic", () => {
      const trace = loadTrace();
      // Volume guardrail — useful for spotting future drift in either
      // direction (e.g. a regression making the model thrash on bd
      // commands would show up as a big Bash spike).
      expect(trace.toolCalls.length).toBe(159);
      const byName: Record<string, number> = {};
      for (const c of trace.toolCalls) {
        byName[c.name] = (byName[c.name] ?? 0) + 1;
      }
      expect(byName["Bash"]).toBe(119);
      expect(byName["Read"]).toBe(24);
      expect(byName["Write"]).toBe(6);
      expect(byName["Grep"]).toBe(4);
      expect(byName["Agent"]).toBe(4);
      expect(
        byName["mcp__plugin_claude-workflow_bd__bd_create_epic"] ?? 0,
      ).toBe(1);
    });
  },
);

describe.skipIf(HAVE_TRACE)(
  "Phase B run-4 recorded-trace anchor: skip when artifact missing",
  () => {
    it("logs a skip notice — the recorded trace artifact is not present", () => {
      process.stderr.write(
        `SKIPPED: _phase-b-run4-trace.unit.spec.ts (trace artifact missing at ${TRACE_PATH})\n`,
      );
      expect(true).toBe(true);
    });
  },
);

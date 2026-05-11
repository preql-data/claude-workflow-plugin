/**
 * happy-path.spec.ts — Phase A's anchor spec.
 *
 * Drives the node-react-auth fixture against real Claude Opus 4.7 and
 * asserts the canonical "orchestrator -> backend + frontend -> QA
 * approval" structural shape, then matches the result against a
 * committed golden cassette.
 *
 * Cross-references:
 *   - G8 plan, "Initial fixture set" (node-react-auth row)
 *   - G8 plan, "Phase A — Foundation"
 *   - cross-cutting principles: cost irrelevant, no permission prompts,
 *     specialists have full scope, always-on workflow
 *
 * The 30-minute test timeout is intentional. A full live happy-path
 * run (orchestrator + 2 specialists + QA + every hook firing + Beads
 * writes) on Opus 4.7 with maxTurns=30 against a real fixture runs
 * genuinely long: an early Phase A live-record run timed out at the
 * old 10-min ceiling while the SDK was still actively making
 * progress (LoginForm + tests + auth endpoint already written, QA
 * about to start). Per the cost-irrelevant principle the only
 * constraint here is the runner's patience, so we give the spec the
 * headroom it actually needs. A blown 30-min budget IS a real signal
 * worth investigating, not a flaky test to retry.
 */
import { describe, it, expect } from "vitest";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Use a relative import. We keep the `~/lib/*` paths alias in tsconfig.json
// for IDE ergonomics but vitest's NodeNext resolver doesn't follow paths
// without a runtime plugin; relative is portable.
import { runFixture } from "../lib/runFixture.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = path.resolve(__dirname, "..", "fixtures", "node-react-auth");
// Golden cassettes are JSONL (metadata header + normalized trace body) —
// see goldenCompare.ts / promoteReplay.ts. The filename extension matches
// the gitignore allowlist (`cassettes/golden/**`) and the promoter's
// default output path.
const GOLDEN_PATH = path.resolve(
  __dirname,
  "..",
  "cassettes",
  "golden",
  "node-react-auth.jsonl",
);

describe("happy-path: node-react-auth", () => {
  it(
    "orchestrator delegates to backend and frontend, QA approves",
    async () => {
      const trace = await runFixture({
        fixturePath: FIXTURE_PATH,
        prompt:
          "Add a POST /auth/login endpoint with JWT tokens, plus a LoginForm component.",
        modelSnapshot: "claude-opus-4-7",
        // bypassPermissions = the SDK's "dontAsk" — autonomy principle.
        permissionMode: "bypassPermissions",
        // 30 was the v3 plan default; observed 30 turns insufficient for full
        // multi-domain auth flow (orchestrator → backend → frontend → QA all
        // firing). 60 buys headroom; if a future fixture hits 60 too, that's
        // a signal of plugin-workflow overhead worth investigating
        // separately, not a default we should keep raising.
        maxTurns: 60,
      });

      // 1) Orchestrator delegated to BOTH specialists. Order doesn't
      //    matter; presence does.
      //
      // Substrate-level (`subagent_type`) assertion now meaningful after
      // the plugin.json schema fix (claude-workflow-plugin-0wk.9). Plugin
      // agents register as `claude-workflow:<role>`; the
      // `subagentInvoked` matcher accepts either the bare role name or
      // the namespaced form (see assertions.ts). Intent-level
      // `delegatedTo` is preserved as a fallback for degraded-substrate
      // testing — e.g. when the plugin loader fails and the orchestrator
      // falls back to general-purpose, the intent is still encoded in
      // the Agent prompt's "@<role>" / "<Role>:" markers and that
      // matcher will still pass.
      expect(trace).subagentInvoked("backend");
      expect(trace).subagentInvoked("frontend");

      // 2) QA was invoked at some point (either by orchestrator post-edit,
      //    or via the verify-before-stop hook chain).
      expect(trace).subagentInvoked("qa");

      // 3) The Stop hook (verify-before-stop.sh) fired with an approve
      //    decision — the QA gate ultimately approved the work. If this
      //    fails the run hit a block and didn't recover.
      expect(trace).hookFired("Stop", { decision: "approve" });

      // 4) At least one Beads task was created (the orchestrator opens
      //    one per workflow rules). We don't pin task IDs because
      //    they're project-scoped and not deterministic.
      expect(trace.beadsTasksCreated.length).toBeGreaterThan(0);

      // 5) Autonomy principle — no permission prompts blocked the run.
      expect(trace).noPermissionDenials();

      // 6) Plugin loaded cleanly. If pluginErrors is non-empty the
      //    fixture or harness is misconfigured.
      expect(trace.pluginErrors).toEqual([]);
      expect(
        trace.pluginsLoaded.some(
          (p: { name: string }) => p.name === "claude-workflow",
        ),
      ).toBe(true);

      // 7) Match the committed golden cassette. Drift = either real
      //    regression or intentional change requiring cassette refresh.
      await expect(trace).matchesGolden(GOLDEN_PATH);
    },
    1_800_000,
  );
});

/**
 * Custom Vitest matchers for Trace assertions.
 *
 * Each matcher is intentionally narrow — it asserts ONE structural
 * property (subagent invocation, hook firing, label transition, file
 * write, etc.) and produces a clear diagnostic when it fails. Tests
 * compose them; the matcher itself doesn't try to be a mini-DSL.
 *
 * Cross-reference: G8 plan, "Determinism strategy" §1 — assert STRUCTURE,
 * not prose. None of these matchers ever look at finalAssistantMessage.
 */
import { expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";

import type { Trace } from "./trace.js";
import { compareToGolden } from "./goldenCompare.js";
import {
  evaluateAll,
  parseInvariantsFromYaml,
  type InvariantSpec,
} from "./invariants.js";

interface MatcherResult {
  pass: boolean;
  message: () => string;
  actual?: unknown;
  expected?: unknown;
}

/** Hook decision values as carried in trace.hookOutputs[].decision. The
 *  literal enum mirrors `HookOutputSchema.decision` in trace.ts; we
 *  also accept `null` because some serializers (and the `?? null`
 *  fallback in trace ingestion) normalize undefined to null. */
type HookDecision = "approve" | "block" | "ask" | undefined | null;

function isTrace(value: unknown): value is Trace {
  return (
    typeof value === "object" &&
    value !== null &&
    "schemaVersion" in value &&
    "toolCalls" in value &&
    "hookOutputs" in value
  );
}

function assertTrace(value: unknown, matcher: string): asserts value is Trace {
  if (!isTrace(value)) {
    throw new Error(
      `expect(...).${matcher}: received value is not a Trace. Got: ${typeof value}`,
    );
  }
}

interface SubagentInvokedOpts {
  /** If set, restrict the match to subagents whose direct parent in the
   *  call tree was a subagent of `parentType`. Cross-references via the
   *  subagent's parentToolUseId chain. */
  parentType?: string;
}

export const matchers = {
  /**
   * PRIMARY matcher (substrate-level). Assert the trace contains at
   * least one Task/Agent tool_use that spawned a subagent of the given
   * type.
   *
   * Matching is plugin-qualifier-tolerant: an expected type "backend"
   * matches any of "backend", "claude-workflow:backend",
   * "any-plugin:backend". The SDK registers plugin-defined agents under
   * a qualified "<plugin>:<name>" form (see `agents` in the system_init
   * event); after the plugin.json schema fix
   * (claude-workflow-plugin-0wk.9) our agents register as
   * `claude-workflow:backend`, `claude-workflow:frontend`, etc. The
   * orchestrator may pick either form when it can resolve the agent;
   * this matcher accepts both so a future plugin rename or
   * registration-path change doesn't silently break specs.
   *
   * If you need to pin to a specific plugin (e.g. cross-plugin tests),
   * pass the qualified form verbatim (e.g. "claude-workflow:backend") —
   * exact matches always count regardless of qualifier-stripping.
   *
   * For tests where the substrate is degraded (no plugin loaded, or the
   * manifest failed to validate), prefer `delegatedTo` — it reads the
   * orchestrator's intent from the Agent input fields and still
   * succeeds when no qualified subagent type is on the tool_use.
   *
   * Example:
   *   expect(trace).subagentInvoked("backend")
   *   expect(trace).subagentInvoked("qa", { parentType: "orchestrator" })
   *   // Pin to a specific plugin (no qualifier stripping if you pass the
   *   // qualified form on both sides):
   *   expect(trace).subagentInvoked("claude-workflow:backend")
   */
  subagentInvoked(received: unknown, type: string, opts: SubagentInvokedOpts = {}): MatcherResult {
    assertTrace(received, "subagentInvoked");
    const matchesType = (actual: string): boolean => {
      if (actual === type) return true;
      // Tolerate plugin qualification in either direction.
      const stripQualifier = (s: string) =>
        s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
      return stripQualifier(actual) === stripQualifier(type);
    };
    const candidates = received.subagentInvocations.filter((inv) =>
      matchesType(inv.type),
    );
    if (candidates.length === 0) {
      const seen = received.subagentInvocations.map((s) => s.type).sort();
      return {
        pass: false,
        message: () =>
          `expected trace to invoke @${type}; saw subagents: [${seen.join(", ") || "<none>"}]`,
        actual: seen,
        expected: type,
      };
    }
    if (!opts.parentType) {
      return {
        pass: true,
        message: () => `expected trace NOT to invoke @${type}`,
      };
    }
    // parentType filter: walk up the tool tree from each candidate's
    // parentToolUseId to find the nearest Task call and check its
    // subagent_type. Also tolerant of plugin qualification.
    const matchesParent = (actual: string | undefined): boolean => {
      if (!actual || !opts.parentType) return false;
      if (actual === opts.parentType) return true;
      const stripQualifier = (s: string) =>
        s.includes(":") ? s.slice(s.indexOf(":") + 1) : s;
      return stripQualifier(actual) === stripQualifier(opts.parentType);
    };
    const idToCall = new Map(received.toolCalls.map((c) => [c.id, c]));
    for (const candidate of candidates) {
      let parentId = candidate.parentToolUseId;
      while (parentId) {
        const parent = idToCall.get(parentId);
        if (!parent) break;
        if (
          (parent.name === "Task" || parent.name === "Agent") &&
          matchesParent(parent.subagentType)
        ) {
          return {
            pass: true,
            message: () =>
              `expected trace NOT to invoke @${type} under parent @${opts.parentType}`,
          };
        }
        parentId = parent.parentToolUseId;
      }
    }
    return {
      pass: false,
      message: () =>
        `expected @${type} to be invoked under parent @${opts.parentType}; subagents of type @${type} existed but none had that parent in the call tree.`,
    };
  },

  /**
   * INTENT-LEVEL FALLBACK matcher. Asserts the orchestrator delegated to
   * a given role *by intent*, even when the SDK substrate doesn't
   * register the role-specific subagent.
   *
   * After the plugin.json schema fix (claude-workflow-plugin-0wk.9),
   * substrate-level subagent registration works and `subagentInvoked` is
   * the primary matcher specs should use. This matcher remains useful
   * for two cases:
   *
   *   1. **Degraded-substrate testing** — explicit tests of the plugin
   *      under environments where the manifest fails to load (e.g.
   *      version skew, breaking SDK changes) so the orchestrator falls
   *      back to `subagent_type: "general-purpose"`. In that mode the
   *      role survives only in the Agent tool's `description` and
   *      `prompt` fields ("Backend: …", "You are acting as the
   *      @backend …"), which this matcher reads.
   *   2. **Cross-plugin portability** — fixtures intended to run against
   *      stock Claude (no plugin) where the orchestrator can't invoke a
   *      registered subagent at all.
   *
   * Match rules (case-insensitive on `role`):
   *   - description starts with "<Role>:"  (e.g. "Backend: POST /auth/login")
   *   - description or prompt contains "@<role>"
   *   - description or prompt contains "act as @<role>" / "as @<role>"
   *
   * Example:
   *   expect(trace).delegatedTo("backend")  // intent-level fallback
   *   expect(trace).delegatedTo("qa")
   */
  delegatedTo(received: unknown, role: string): MatcherResult {
    assertTrace(received, "delegatedTo");
    const r = role.toLowerCase();
    const hits = received.toolCalls.filter((c) => {
      if (c.name !== "Agent" && c.name !== "Task") return false;
      const i = (c.input ?? {}) as { description?: string; prompt?: string };
      const desc = (i.description ?? "").toLowerCase();
      const prompt = (i.prompt ?? "").toLowerCase();
      const blob = `${desc}\n${prompt}`;
      return (
        blob.includes(`@${r}`) ||
        desc.startsWith(`${r}:`) ||
        blob.includes(`act as @${r}`) ||
        blob.includes(`as @${r}`)
      );
    });
    if (hits.length === 0) {
      const seenAgentDescs = received.toolCalls
        .filter((c) => c.name === "Agent" || c.name === "Task")
        .map((c) => {
          const i = (c.input ?? {}) as { description?: string };
          return i.description ?? "<no description>";
        });
      return {
        pass: false,
        message: () =>
          `expected trace to delegate to @${role}; no Agent/Task call had matching description/prompt. Saw Agent/Task descriptions: [${seenAgentDescs.join(" | ") || "<none>"}]`,
      };
    }
    return {
      pass: true,
      message: () =>
        `expected trace NOT to delegate to @${role}; found ${hits.length} matching Agent/Task call(s)`,
    };
  },

  /**
   * Assert a hook event fired (optionally with a specific decision).
   *
   * Decision semantics (from the Claude Code hooks reference,
   * https://code.claude.com/docs/en/hooks):
   *
   *   - "block" — only valid explicit value for Stop, SubagentStop,
   *     UserPromptSubmit, UserPromptExpansion, PostToolUse,
   *     PostToolUseFailure, PostToolBatch, ConfigChange, PreCompact.
   *     Setting decision="block" tells Claude to NOT proceed and
   *     surfaces `reason` back to the model.
   *   - **Omitted (or `decision` undefined)** — universally signals
   *     "approve, proceed normally" for every event listed above.
   *     There is NO explicit `decision: "approve"` value for these
   *     events; "approve" is signalled BY ABSENCE.
   *   - "approve" — only PreToolUse has ever used this value (and it's
   *     deprecated in favour of `hookSpecificOutput.permissionDecision:
   *     "allow"`). The SDK still TYPES `decision?: "approve" | "block"`
   *     (SyncHookJSONOutput, sdk.d.ts:5523) for compatibility.
   *
   * Match behavior:
   *   - `decision: "block"` — matches hook outputs with explicit
   *     `decision === "block"`. Strict.
   *   - `decision: "approve"` — matches hook outputs with EITHER an
   *     explicit `decision === "approve"` (legacy PreToolUse) OR no
   *     `decision` set at all (the universal "proceed" signal). This
   *     reflects the actual hook contract: a happy-path Stop hook
   *     returning `{}` is signalling approval, and a spec asserting
   *     "the gate approved" should match it.
   *   - `decision: "ask"` — matches strictly.
   *
   * This was discovered during claude-workflow-plugin-0wk.10 Phase A.2
   * when the live trace's Stop hook outputs (post-includeHookEvents
   * fix) showed `decision === undefined` on every approval — because
   * verify-before-stop.sh emits `{}` on the approve path, which is the
   * documented contract. A strict `decision === "approve"` check would
   * make every spec assertion of the form `hookFired("Stop", { decision:
   * "approve" })` fail spuriously even when the gate IS approving
   * correctly.
   *
   * Example:
   *   expect(trace).hookFired("Stop")
   *   expect(trace).hookFired("Stop", { decision: "approve" })
   *   expect(trace).hookFired("Stop", { decision: "block" })
   */
  hookFired(
    received: unknown,
    event: string,
    opts: { decision?: "approve" | "block" | "ask" } = {},
  ): MatcherResult {
    assertTrace(received, "hookFired");
    const candidates = received.hookOutputs.filter((h) => h.event === event);
    if (candidates.length === 0) {
      const seen = [...new Set(received.hookOutputs.map((h) => h.event))].sort();
      return {
        pass: false,
        message: () =>
          `expected hook ${event} to fire; saw events: [${seen.join(", ") || "<none>"}]`,
      };
    }
    if (!opts.decision) {
      return {
        pass: true,
        message: () => `expected hook ${event} NOT to fire`,
      };
    }
    // Decision filter. For "approve" we also accept no-decision-set hook
    // outputs (the universal "proceed" signal — see docblock above).
    const matchesDecision = (actual: HookDecision): boolean => {
      if (actual === opts.decision) return true;
      if (opts.decision === "approve" && (actual === undefined || actual === null)) {
        return true;
      }
      return false;
    };
    const matching = candidates.filter((h) => matchesDecision(h.decision));
    if (matching.length === 0) {
      const decisions = candidates.map((h) => h.decision ?? "<none>");
      return {
        pass: false,
        message: () =>
          `expected hook ${event} to fire with decision=${opts.decision}; instead saw decisions: [${decisions.join(", ")}]`,
      };
    }
    return {
      pass: true,
      message: () =>
        `expected hook ${event} NOT to fire with decision=${opts.decision}`,
    };
  },

  /**
   * Assert the Beads label transitions include a specific add/remove for
   * a given task.
   *
   * Example:
   *   expect(trace).beadsLabelTransitioned("claude-workflow-plugin-xyz", ["qa-pending"])
   *   expect(trace).beadsLabelTransitioned("xyz", ["qa-approved"], ["qa-pending"])
   */
  beadsLabelTransitioned(
    received: unknown,
    taskId: string,
    added: string[] = [],
    removed: string[] = [],
  ): MatcherResult {
    assertTrace(received, "beadsLabelTransitioned");
    const transition = received.beadsLabelTransitions.find(
      (t) => t.taskId === taskId,
    );
    if (!transition) {
      const seen = received.beadsLabelTransitions.map((t) => t.taskId);
      return {
        pass: false,
        message: () =>
          `expected label transition on ${taskId}; saw transitions on: [${seen.join(", ") || "<none>"}]`,
      };
    }
    const missingAdds = added.filter((l) => !transition.added.includes(l));
    const missingRemoves = removed.filter(
      (l) => !transition.removed.includes(l),
    );
    if (missingAdds.length === 0 && missingRemoves.length === 0) {
      return {
        pass: true,
        message: () =>
          `expected ${taskId} NOT to transition with adds=${JSON.stringify(added)} removes=${JSON.stringify(removed)}`,
      };
    }
    return {
      pass: false,
      message: () =>
        `${taskId} transition mismatch: missing adds=${JSON.stringify(missingAdds)} missing removes=${JSON.stringify(missingRemoves)} (actual transition: +[${transition.added.join(", ")}] -[${transition.removed.join(", ")}])`,
    };
  },

  /**
   * Assert at least one file write touched a path matching the given
   * literal or regex.
   *
   * Example:
   *   expect(trace).fileWritten("server/index.js")
   *   expect(trace).fileWritten(/^client\/src\/.*\.jsx$/)
   */
  fileWritten(received: unknown, pathOrRegex: string | RegExp): MatcherResult {
    assertTrace(received, "fileWritten");
    const matcher: (p: string) => boolean =
      typeof pathOrRegex === "string"
        ? (p) => p === pathOrRegex
        : (p) => pathOrRegex.test(p);
    const hits = received.fileWrites.filter((f) => matcher(f.path));
    if (hits.length === 0) {
      const seen = received.fileWrites.map((f) => f.path);
      return {
        pass: false,
        message: () =>
          `expected file write matching ${pathOrRegex}; wrote: [${seen.join(", ") || "<none>"}]`,
      };
    }
    return {
      pass: true,
      message: () =>
        `expected NO file write matching ${pathOrRegex}; got ${hits.length} match(es)`,
    };
  },

  /**
   * Assert the run completed with no permission denials.
   *
   * This enforces the autonomy principle (no permission prompts blocked
   * the run). Any denial is a regression of the principle.
   */
  noPermissionDenials(received: unknown): MatcherResult {
    assertTrace(received, "noPermissionDenials");
    if (received.permissionDenials.length === 0) {
      return {
        pass: true,
        message: () =>
          `expected at least one permission denial — got zero (suspicious; the principle should hold)`,
      };
    }
    const summary = received.permissionDenials
      .map((d) => `${d.tool} (${d.reason || "<no reason>"})`)
      .join("; ");
    return {
      pass: false,
      message: () =>
        `expected zero permission denials (autonomy principle); got ${received.permissionDenials.length}: ${summary}`,
    };
  },

  /**
   * Assert the trace satisfies every invariant declared in a fixture's
   * fixture.yaml `invariants:` block. This is the PRIMARY gate for live
   * specs since v3.1.0 spec item 0.8 — model-agnostic, drift-free.
   *
   * The matcher reads fixture.yaml from disk, extracts the invariants
   * block via `parseInvariantsFromYaml`, runs each through the engine in
   * `invariants.ts`, and pass/fails on aggregate. Skipped invariants are
   * surfaced in the message (we don't pretend a skip is a pass) but do
   * not fail the assertion.
   *
   * Example:
   *   await expect(trace).satisfiesInvariants(
   *     path.join(FIXTURE_PATH, "fixture.yaml")
   *   );
   */
  async satisfiesInvariants(
    received: unknown,
    fixtureYamlPath: string,
  ): Promise<MatcherResult> {
    assertTrace(received, "satisfiesInvariants");
    if (!existsSync(fixtureYamlPath)) {
      return {
        pass: false,
        message: () =>
          `satisfiesInvariants: fixture.yaml not found at ${fixtureYamlPath}`,
      };
    }
    let content: string;
    try {
      content = readFileSync(fixtureYamlPath, "utf8");
    } catch (err) {
      return {
        pass: false,
        message: () =>
          `satisfiesInvariants: could not read ${fixtureYamlPath}: ${(err as Error).message}`,
      };
    }
    const specs: InvariantSpec[] = parseInvariantsFromYaml(content);
    if (specs.length === 0) {
      return {
        pass: false,
        message: () =>
          `satisfiesInvariants: no invariants declared in ${fixtureYamlPath}. Add an 'invariants:' block (see .claude/tests/README.md).`,
      };
    }
    const agg = evaluateAll(received, specs);
    if (agg.allPassed) {
      const skipNote =
        agg.skipped.length > 0
          ? ` (skipped: ${agg.skipped.join(", ")})`
          : "";
      const lines = agg.results
        .map((r) => `  - ${r.name}: ${r.result.skipped ? "skipped" : "pass"} — ${r.result.detail}`)
        .join("\n");
      return {
        pass: true,
        message: () =>
          `expected trace NOT to satisfy ${specs.length} invariant(s)${skipNote}.\n${lines}`,
      };
    }
    const failureLines = agg.results
      .filter((r) => !r.result.pass && !r.result.skipped)
      .map((r) => `  - ${r.name}: ${r.result.detail}`)
      .join("\n");
    return {
      pass: false,
      message: () =>
        `${agg.failed.length} invariant(s) violated:\n${failureLines}\n\nFixture: ${fixtureYamlPath}`,
    };
  },

  /**
   * @deprecated Since v3.1.0 (spec item 0.8): golden cassette equality is
   * no longer a gate. Goldens are kept as debugging references; live
   * specs gate via `satisfiesInvariants(fixtureYamlPath)`. This matcher
   * remains for ad-hoc inspection (e.g. inside cassette-diff workflows)
   * but every live spec should use the invariant matcher instead.
   *
   * NOTE: This is async; Vitest's expect.extend supports async matchers
   * since v1.0+. Tests use `await expect(trace).matchesGolden(path)`.
   */
  async matchesGolden(received: unknown, goldenPath: string): Promise<MatcherResult> {
    assertTrace(received, "matchesGolden");
    const result = await compareToGolden(received, goldenPath);
    if (result.status === "recorded") {
      // Recording is a successful outcome (the user asked for a record),
      // but we still surface it so the spec output makes it obvious a
      // new cassette was created.
      return {
        pass: true,
        message: () =>
          `recorded golden cassette at ${goldenPath} (set RECORD_GOLDEN to refresh)`,
      };
    }
    if (result.status === "matched") {
      return {
        pass: true,
        message: () => `expected trace NOT to match golden ${goldenPath}`,
      };
    }
    const diffStr = (result.diffs ?? []).join("\n  - ");
    return {
      pass: false,
      message: () =>
        `golden cassette drift at ${goldenPath}:\n  - ${diffStr}\n\nIf this drift is intentional, delete the cassette and re-record with RECORD_GOLDEN=1.`,
    };
  },
};

/** Type augmentation so TypeScript knows about the matchers. We register
 *  them on Vitest's `Assertion<T>` interface (matching vitest's own
 *  declaration shape — no default on T, since vitest declares it without
 *  one in its own d.ts). */
declare module "vitest" {
  // eslint-disable-next-line @typescript-eslint/no-empty-object-type, @typescript-eslint/no-unused-vars
  interface Assertion<T> {
    subagentInvoked(type: string, opts?: SubagentInvokedOpts): void;
    delegatedTo(role: string): void;
    hookFired(
      event: string,
      opts?: { decision?: "approve" | "block" | "ask" },
    ): void;
    beadsLabelTransitioned(
      taskId: string,
      added?: string[],
      removed?: string[],
    ): void;
    fileWritten(pathOrRegex: string | RegExp): void;
    noPermissionDenials(): void;
    satisfiesInvariants(fixtureYamlPath: string): Promise<void>;
    /** @deprecated Use satisfiesInvariants. Retained for debugging only. */
    matchesGolden(goldenPath: string): Promise<void>;
  }
  // eslint-disable-next-line @typescript-eslint/no-empty-object-type
  interface AsymmetricMatchersContaining {
    subagentInvoked(type: string, opts?: SubagentInvokedOpts): unknown;
    delegatedTo(role: string): unknown;
    hookFired(
      event: string,
      opts?: { decision?: "approve" | "block" | "ask" },
    ): unknown;
    beadsLabelTransitioned(
      taskId: string,
      added?: string[],
      removed?: string[],
    ): unknown;
    fileWritten(pathOrRegex: string | RegExp): unknown;
    noPermissionDenials(): unknown;
    satisfiesInvariants(fixtureYamlPath: string): Promise<unknown>;
    /** @deprecated Use satisfiesInvariants. */
    matchesGolden(goldenPath: string): Promise<unknown>;
  }
}

/** Register all matchers with Vitest. Called from setup.ts. */
export function registerMatchers(): void {
  expect.extend(matchers as never);
}

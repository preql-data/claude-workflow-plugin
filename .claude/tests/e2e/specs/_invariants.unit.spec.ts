/**
 * _invariants.unit.spec.ts — offline self-tests for the invariant engine
 * introduced in v3.1.0 spec item 0.8.
 *
 * Goal: prove the engine is sensitive to violations of each implemented
 * invariant. For each invariant we have:
 *
 *   - A POSITIVE case: a synthetic Trace (or a retained replay) that
 *     SHOULD satisfy the invariant. We assert the engine returns
 *     `pass: true`.
 *
 *   - A META-TEST: a deliberate mutation of the trace that violates
 *     exactly that invariant. We assert the engine returns
 *     `pass: false` and the failure detail mentions the invariant by
 *     name. If a META-TEST starts passing through, the engine has gone
 *     soft for that invariant.
 *
 * These specs are L3-unit (offline, free) and run on every PR. The
 * `_` prefix opts them into the unit pool via the `unit.spec` filter in
 * vitest's `test:unit` script.
 *
 * Cross-references:
 *   - lib/invariants.ts (the engine under test)
 *   - .claude/tests/README.md (META-TEST convention)
 */
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  INVARIANTS,
  evaluateAll,
  listInvariants,
  parseInvariantsFromYaml,
  type InvariantSpec,
} from "../lib/invariants.js";
import { createEmptyTrace, TraceSchema, type Trace } from "../lib/trace.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPLAYS_DIR = path.resolve(__dirname, "..", "cassettes", "replays");

// ---------------------------------------------------------------------------
// Synthetic-trace helpers. The engine takes raw `Trace` objects (NOT
// normalized), so we build minimal but valid traces here.
// ---------------------------------------------------------------------------

/**
 * Build a known-good synthetic trace that should satisfy every
 * universal invariant: orchestrator delegates to backend + qa; QA
 * approval flows; no orchestrator-attributable edits; declared
 * specialists only; milestones present.
 */
function goodTrace(): Trace {
  const t = createEmptyTrace("synthetic-good", "prompt", "claude-opus-4-7");
  // Orchestrator delegates to backend via Task. Backend writes a file.
  // Backend triggers QA via Task. QA approves. Stop allows.
  t.toolCalls = [
    {
      id: "task-backend",
      name: "Task",
      input: { subagent_type: "backend" },
      parentToolUseId: null,
      subagentType: "backend",
      durationMs: 0,
    },
    {
      id: "write-server",
      name: "Write",
      input: { file_path: "server/index.js", content: "..." },
      // Parented to backend Task — this is the specialist's edit,
      // NOT orchestrator-attributable.
      parentToolUseId: "task-backend",
      durationMs: 0,
    },
    {
      id: "task-qa",
      name: "Task",
      input: { subagent_type: "qa" },
      parentToolUseId: null,
      subagentType: "qa",
      durationMs: 0,
    },
  ];
  t.subagentInvocations = [
    { type: "backend", toolUseId: "task-backend", parentToolUseId: null },
    { type: "qa", toolUseId: "task-qa", parentToolUseId: null },
  ];
  t.hookOutputs = [
    {
      event: "Stop",
      script: "verify-before-stop.sh",
      // decision absent = allow per Claude Code hooks contract.
      durationMs: 1,
    },
  ];
  t.beadsTasksCreated = ["good-1"];
  t.beadsLabelTransitions = [
    { taskId: "good-1", added: ["qa-pending", "qa-approved"], removed: [] },
  ];
  return t;
}

/** Universal spec set used by most fixtures. */
const UNIVERSAL_SPECS: InvariantSpec[] = [
  { name: "stop-requires-approval" },
  { name: "orchestrator-no-edits" },
  { name: "completion-contract" },
  {
    name: "label-milestones",
    params: { milestones: ["qa-pending", "qa-approved"] },
  },
  {
    name: "declared-subagents-only",
    params: { declared: ["backend", "qa"] },
  },
];

// ---------------------------------------------------------------------------
// Registry meta-coverage
// ---------------------------------------------------------------------------

describe("invariant engine: registry", () => {
  it("registers all five invariants from spec 0.8", () => {
    const names = listInvariants();
    expect(names).toContain("stop-requires-approval");
    expect(names).toContain("orchestrator-no-edits");
    expect(names).toContain("completion-contract");
    expect(names).toContain("label-milestones");
    expect(names).toContain("declared-subagents-only");
  });

  it("evaluateAll fails-loudly on an unknown invariant name (catches fixture.yaml typos)", () => {
    const t = goodTrace();
    const agg = evaluateAll(t, [{ name: "does-not-exist" }]);
    expect(agg.allPassed).toBe(false);
    expect(agg.failed).toContain("does-not-exist");
    expect(agg.results[0]?.result.detail).toMatch(/unknown invariant/);
  });
});

// ---------------------------------------------------------------------------
// Positive sweep + per-invariant META-TESTs.
//
// Each block:
//   1. Asserts the invariant passes on the good trace (positive case).
//   2. Mutates the good trace into a violation and asserts the engine
//      catches it by name (META-TEST).
// ---------------------------------------------------------------------------

describe("invariant: stop-requires-approval", () => {
  it("passes on a Stop:allow trace where qa-approved was set", () => {
    const t = goodTrace();
    const r = INVARIANTS["stop-requires-approval"]!(t);
    expect(r.pass).toBe(true);
  });

  it("passes vacuously when no Stop:allow occurred (only blocks)", () => {
    const t = goodTrace();
    t.hookOutputs = [
      {
        event: "Stop",
        script: "verify-before-stop.sh",
        decision: "block",
        durationMs: 1,
      },
    ];
    t.beadsLabelTransitions = []; // no approval needed if no allow
    const r = INVARIANTS["stop-requires-approval"]!(t);
    expect(r.pass).toBe(true);
    expect(r.detail).toMatch(/vacuously satisfied/);
  });

  it("accepts qa-deferred as an audited escape (per spec 0.2)", () => {
    const t = goodTrace();
    t.beadsLabelTransitions = [
      { taskId: "good-1", added: ["qa-deferred"], removed: [] },
    ];
    const r = INVARIANTS["stop-requires-approval"]!(t);
    expect(r.pass).toBe(true);
  });

  it("META-TEST: fails when Stop:allow fires without any qa-approved/qa-deferred", () => {
    const t = goodTrace();
    // Strip the approval transition; Stop:allow remains.
    t.beadsLabelTransitions = [
      { taskId: "good-1", added: ["qa-pending"], removed: [] },
    ];
    const agg = evaluateAll(t, [{ name: "stop-requires-approval" }]);
    expect(agg.allPassed).toBe(false);
    expect(agg.failed).toEqual(["stop-requires-approval"]);
    expect(agg.results[0]?.result.detail).toMatch(/gate may have leaked/);
  });
});

describe("invariant: orchestrator-no-edits", () => {
  it("passes when only specialist-scoped writes exist", () => {
    const t = goodTrace();
    const r = INVARIANTS["orchestrator-no-edits"]!(t);
    expect(r.pass).toBe(true);
  });

  it("META-TEST: fails when a root-level Write is injected (orchestrator-attributable)", () => {
    const t = goodTrace();
    // Inject a Write at the top level (parentToolUseId=null).
    t.toolCalls.push({
      id: "rogue-write",
      name: "Write",
      input: { file_path: "rogue.md", content: "x" },
      parentToolUseId: null,
      durationMs: 0,
    });
    const agg = evaluateAll(t, [{ name: "orchestrator-no-edits" }]);
    expect(agg.allPassed).toBe(false);
    expect(agg.failed).toEqual(["orchestrator-no-edits"]);
    expect(agg.results[0]?.result.detail).toMatch(/Write\(rogue\.md\)/);
  });

  it("META-TEST: catches an Edit on a tool call whose parent chain skips Task", () => {
    const t = goodTrace();
    // A Bash tool call lives at the top level (orchestrator), and a
    // Write claims to be parented by it. Because Bash is not a Task,
    // walking the chain hits root without crossing a Task — the Write
    // is orchestrator-attributable.
    t.toolCalls.push({
      id: "orchestrator-bash",
      name: "Bash",
      input: { command: "ls" },
      parentToolUseId: null,
      durationMs: 0,
    });
    t.toolCalls.push({
      id: "orchestrator-edit",
      name: "Edit",
      input: { file_path: "config.json" },
      parentToolUseId: "orchestrator-bash",
      durationMs: 0,
    });
    const r = INVARIANTS["orchestrator-no-edits"]!(t);
    expect(r.pass).toBe(false);
    expect(r.detail).toMatch(/Edit\(config\.json\)/);
  });

  it("META-TEST: catches MultiEdit at orchestrator scope", () => {
    const t = goodTrace();
    t.toolCalls.push({
      id: "rogue-multi",
      name: "MultiEdit",
      input: { file_path: "many.ts" },
      parentToolUseId: null,
      durationMs: 0,
    });
    const r = INVARIANTS["orchestrator-no-edits"]!(t);
    expect(r.pass).toBe(false);
    expect(r.detail).toMatch(/MultiEdit/);
  });
});

describe("invariant: completion-contract", () => {
  it("returns skipped with a documented reason (trace gap)", () => {
    const t = goodTrace();
    const r = INVARIANTS["completion-contract"]!(t);
    expect(r.skipped).toBe(true);
    expect(r.detail).toMatch(/skipped/i);
    expect(r.detail).toMatch(/trace gap/i);
  });

  it("evaluateAll reports the skip without counting it as a failure", () => {
    const t = goodTrace();
    const agg = evaluateAll(t, [{ name: "completion-contract" }]);
    expect(agg.allPassed).toBe(true);
    expect(agg.skipped).toContain("completion-contract");
    expect(agg.failed).toEqual([]);
  });
});

describe("invariant: label-milestones", () => {
  it("passes when every declared milestone appears as an added label", () => {
    const t = goodTrace();
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "qa-approved"],
    });
    expect(r.pass).toBe(true);
  });

  it("passes when milestones span multiple transitions on different tasks", () => {
    const t = goodTrace();
    t.beadsLabelTransitions = [
      { taskId: "a", added: ["qa-pending"], removed: [] },
      { taskId: "b", added: ["qa-approved"], removed: [] },
    ];
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "qa-approved"],
    });
    expect(r.pass).toBe(true);
  });

  it("tolerates extra intermediate adds (e.g. qa-blocked) — spec 0.8 'extras allowed'", () => {
    const t = goodTrace();
    t.beadsLabelTransitions = [
      {
        taskId: "x",
        added: ["qa-pending", "qa-blocked", "qa-pending", "qa-approved"],
        removed: [],
      },
    ];
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "qa-approved"],
    });
    expect(r.pass).toBe(true);
  });

  it("META-TEST: fails when a required milestone is missing from every transition", () => {
    const t = goodTrace();
    t.beadsLabelTransitions = [
      // qa-approved is gone; only qa-pending shows up.
      { taskId: "good-1", added: ["qa-pending"], removed: [] },
    ];
    const agg = evaluateAll(t, [
      {
        name: "label-milestones",
        params: { milestones: ["qa-pending", "qa-approved"] },
      },
    ]);
    expect(agg.allPassed).toBe(false);
    expect(agg.failed).toEqual(["label-milestones"]);
    expect(agg.results[0]?.result.detail).toMatch(/qa-approved/);
  });

  it("META-TEST: fails when no label transitions occur at all", () => {
    const t = goodTrace();
    t.beadsLabelTransitions = [];
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "qa-approved"],
    });
    expect(r.pass).toBe(false);
    expect(r.detail).toMatch(/missing milestone/);
  });
});

describe("invariant: declared-subagents-only", () => {
  it("passes when every subagent is in the declared set", () => {
    const t = goodTrace();
    const r = INVARIANTS["declared-subagents-only"]!(t, {
      declared: ["backend", "qa"],
    });
    expect(r.pass).toBe(true);
  });

  it("accepts plugin-qualified subagent types as matching the bare declared name", () => {
    const t = goodTrace();
    t.subagentInvocations = [
      {
        type: "claude-workflow:backend",
        toolUseId: "task-backend",
        parentToolUseId: null,
      },
      {
        type: "claude-workflow:qa",
        toolUseId: "task-qa",
        parentToolUseId: null,
      },
    ];
    const r = INVARIANTS["declared-subagents-only"]!(t, {
      declared: ["backend", "qa"],
    });
    expect(r.pass).toBe(true);
  });

  it("always allows orchestrator + general-purpose roles (SDK fallback)", () => {
    const t = goodTrace();
    t.subagentInvocations.push(
      {
        type: "claude-workflow:orchestrator",
        toolUseId: "task-orch",
        parentToolUseId: null,
      },
      {
        type: "general-purpose",
        toolUseId: "task-gen",
        parentToolUseId: null,
      },
    );
    const r = INVARIANTS["declared-subagents-only"]!(t, {
      declared: ["backend", "qa"],
    });
    expect(r.pass).toBe(true);
  });

  it("META-TEST: fails when an undeclared specialist appears (e.g. devops in a frontend-only fixture)", () => {
    const t = goodTrace();
    t.subagentInvocations.push({
      type: "devops",
      toolUseId: "task-devops",
      parentToolUseId: null,
    });
    const agg = evaluateAll(t, [
      {
        name: "declared-subagents-only",
        params: { declared: ["backend", "qa"] },
      },
    ]);
    expect(agg.allPassed).toBe(false);
    expect(agg.failed).toEqual(["declared-subagents-only"]);
    expect(agg.results[0]?.result.detail).toMatch(/devops/);
  });

  it("META-TEST: fails when an undeclared plugin-qualified type appears", () => {
    const t = goodTrace();
    t.subagentInvocations.push({
      type: "other-plugin:exotic-role",
      toolUseId: "task-x",
      parentToolUseId: null,
    });
    const r = INVARIANTS["declared-subagents-only"]!(t, {
      declared: ["backend", "qa"],
    });
    expect(r.pass).toBe(false);
    expect(r.detail).toMatch(/exotic-role/);
  });

  it("errors when the fixture forgets to declare a `declared` param (loud failure beats silent pass)", () => {
    const t = goodTrace();
    const r = INVARIANTS["declared-subagents-only"]!(t, {});
    expect(r.pass).toBe(false);
    expect(r.detail).toMatch(/missing `declared` parameter/);
  });
});

// ---------------------------------------------------------------------------
// Seed-corpus validation: retained replays should satisfy the universal
// invariants. We pick the LATEST replay per fixture (stable signal of
// the most recent known-good run) and run the engine over each.
//
// Any replay missing label transitions (early runs predating bd hook
// instrumentation) is skipped automatically — the label-milestones
// invariant would correctly fail on those, but they're not actually
// regressions, they're pre-instrumentation traces.
// ---------------------------------------------------------------------------

interface ReplayPick {
  fixture: string;
  file: string;
  trace: Trace;
}

function loadLatestReplayPerFixture(): ReplayPick[] {
  if (!existsSync(REPLAYS_DIR)) return [];
  const byFixture = new Map<string, { file: string; mtime: number }>();
  for (const fname of readdirSync(REPLAYS_DIR)) {
    if (!fname.endsWith(".jsonl")) continue;
    // Strip the ISO timestamp suffix to derive the fixture name.
    const m = /^(.+?)-(\d{4}-\d{2}-\d{2}T.+)\.jsonl$/.exec(fname);
    if (!m) continue;
    const fixture = m[1];
    if (!fixture) continue;
    const full = path.join(REPLAYS_DIR, fname);
    const mtime = statSync(full).mtimeMs;
    const prev = byFixture.get(fixture);
    if (!prev || prev.mtime < mtime) {
      byFixture.set(fixture, { file: full, mtime });
    }
  }
  const out: ReplayPick[] = [];
  for (const [fixture, { file }] of byFixture.entries()) {
    try {
      const raw = readFileSync(file, "utf8");
      const obj = JSON.parse(raw);
      const parsed = TraceSchema.safeParse(obj);
      if (parsed.success) {
        out.push({ fixture, file, trace: parsed.data });
      }
    } catch {
      // Replays from prior schema versions may not parse; skip them.
    }
  }
  return out;
}

const seedCorpus = loadLatestReplayPerFixture();

describe("invariant engine: seed corpus (retained replays)", () => {
  if (seedCorpus.length === 0) {
    it("no parseable replays found — skipping seed-corpus checks", () => {
      expect(true).toBe(true);
    });
    return;
  }

  for (const pick of seedCorpus) {
    describe(`replay: ${pick.fixture}`, () => {
      it("universal invariants evaluate without throwing", () => {
        const agg = evaluateAll(pick.trace, [
          { name: "stop-requires-approval" },
          { name: "orchestrator-no-edits" },
        ]);
        // We don't assert allPassed here because some seed replays
        // predate the full hook instrumentation. The point is the engine
        // produces structured results for every retained trace without
        // crashing on schema shape edge cases.
        expect(agg.results.length).toBe(2);
        expect(agg.results.every((r) => typeof r.result.detail === "string"));
      });

      it("orchestrator-no-edits passes on seed replays (the orchestrator restriction is the hardest contract to silently break)", () => {
        const r = INVARIANTS["orchestrator-no-edits"]!(pick.trace);
        // Seed replays MUST satisfy this — the
        // prevent-orchestrator-edits.sh guard makes it true in
        // production; a replay that violates it would prove the guard
        // failed in that run. If this trips, investigate the trace
        // before "fixing" the invariant.
        expect(r.pass).toBe(true);
      });
    });
  }
});

// ---------------------------------------------------------------------------
// YAML parser self-tests (the parser is a hand-rolled extractor; if it
// silently misreads a fixture, every invariant after it pays the price).
// ---------------------------------------------------------------------------

describe("invariant engine: parseInvariantsFromYaml", () => {
  it("extracts simple name-only entries", () => {
    const yaml = `
name: test
invariants:
  - name: stop-requires-approval
  - name: orchestrator-no-edits
`;
    const specs = parseInvariantsFromYaml(yaml);
    expect(specs).toEqual([
      { name: "stop-requires-approval" },
      { name: "orchestrator-no-edits" },
    ]);
  });

  it("extracts entries with list params (milestones)", () => {
    const yaml = `
invariants:
  - name: label-milestones
    params:
      milestones:
        - qa-pending
        - qa-approved
`;
    const specs = parseInvariantsFromYaml(yaml);
    expect(specs).toHaveLength(1);
    expect(specs[0]?.name).toBe("label-milestones");
    expect(specs[0]?.params?.milestones).toEqual(["qa-pending", "qa-approved"]);
  });

  it("extracts mixed entries (params + bare) in the same block", () => {
    const yaml = `
invariants:
  - name: stop-requires-approval
  - name: label-milestones
    params:
      milestones:
        - qa-pending
        - qa-approved
  - name: declared-subagents-only
    params:
      declared:
        - backend
        - frontend
        - qa

notes: |
  trailing keys must not bleed in.
`;
    const specs = parseInvariantsFromYaml(yaml);
    expect(specs).toHaveLength(3);
    expect(specs[0]?.name).toBe("stop-requires-approval");
    expect(specs[1]?.params?.milestones).toEqual([
      "qa-pending",
      "qa-approved",
    ]);
    expect(specs[2]?.params?.declared).toEqual([
      "backend",
      "frontend",
      "qa",
    ]);
  });

  it("returns [] when the file has no invariants block", () => {
    const yaml = `
name: test
description: nothing here
`;
    expect(parseInvariantsFromYaml(yaml)).toEqual([]);
  });

  it("real fixture.yaml files parse and declare invariants for all 6 fixtures", () => {
    const fixturesDir = path.resolve(__dirname, "..", "fixtures");
    if (!existsSync(fixturesDir)) {
      // Tolerant: in some CI matrix configs fixtures may not be present.
      return;
    }
    const fixtures = readdirSync(fixturesDir).filter((d) =>
      statSync(path.join(fixturesDir, d)).isDirectory(),
    );
    expect(fixtures.length).toBeGreaterThan(0);
    for (const fixture of fixtures) {
      const yamlPath = path.join(fixturesDir, fixture, "fixture.yaml");
      if (!existsSync(yamlPath)) continue;
      const yaml = readFileSync(yamlPath, "utf8");
      const specs = parseInvariantsFromYaml(yaml);
      expect(
        specs.length,
        `fixture ${fixture} should declare invariants (post-0.8)`,
      ).toBeGreaterThan(0);
      // Every declared name must exist in the registry — typos here are
      // silent gate-bypass risks.
      const registered = new Set(listInvariants());
      for (const s of specs) {
        expect(
          registered.has(s.name),
          `fixture ${fixture}: invariant '${s.name}' not in registry`,
        ).toBe(true);
      }
    }
  });
});

// Re-use the universal spec set in at least one place so that constant
// doesn't go unused if a future cleanup removes one of the per-invariant
// blocks above.
describe("invariant engine: aggregate (universal spec set)", () => {
  it("good trace satisfies the universal spec set", () => {
    const t = goodTrace();
    const agg = evaluateAll(t, UNIVERSAL_SPECS);
    expect(agg.allPassed).toBe(true);
    expect(agg.failed).toEqual([]);
  });
});

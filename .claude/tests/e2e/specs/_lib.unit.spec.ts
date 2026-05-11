/**
 * Self-tests for the harness lib. These don't hit Claude — they verify
 * trace normalization, golden compare, schema validation, and fixture
 * git-init plumbing. Run as part of `make test-e2e` (no API key needed).
 *
 * The naming "_lib.unit.spec.ts" puts these first alphabetically so they
 * run before the live happy-path spec; if these fail the harness itself
 * is broken and there's no point burning API budget on the live run.
 */
import { describe, it, expect } from "vitest";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { TraceSchema, createEmptyTrace, type Trace } from "../lib/trace.js";
import { normalizeTrace, compareToGolden } from "../lib/goldenCompare.js";
import { ensureFixtureGitInit } from "../lib/fixtureInit.js";
import { findPluginRoot } from "../lib/runFixture.js";

describe("trace schema", () => {
  it("createEmptyTrace produces a TraceSchema-valid object", () => {
    const t = createEmptyTrace("fix", "do thing", "claude-opus-4-7");
    const parsed = TraceSchema.parse(t);
    expect(parsed.fixture).toBe("fix");
    expect(parsed.modelSnapshot).toBe("claude-opus-4-7");
    expect(parsed.toolCalls).toEqual([]);
  });

  it("rejects an obviously broken trace", () => {
    expect(() =>
      TraceSchema.parse({
        schemaVersion: 99,
        fixture: "x",
        prompt: "y",
      }),
    ).toThrow();
  });

  // The SDK has shipped two shapes for plugin-load errors:
  //   - flat strings (older / synthetic traces),
  //   - structured `{ plugin, type, message, ... }` objects (current SDK,
  //     observed in cassettes/replays/node-react-auth-2026-05-10T12-39-25-664Z.jsonl).
  // The schema must accept either at both top-level `pluginErrors` AND
  // nested `systemInit.pluginErrors`, otherwise TraceSchema.parse() fails
  // on every live capture. These two cases are the regression bar.
  it("accepts string-shaped pluginErrors (legacy/synthetic shape)", () => {
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.pluginErrors = ["Failed to load plugin: foo"];
    t.systemInit = {
      plugins: [],
      pluginErrors: ["Failed to load plugin: foo"],
      availableSubagents: [],
      tools: [],
      mcpServers: [],
    };
    const parsed = TraceSchema.parse(t);
    expect(parsed.pluginErrors).toEqual(["Failed to load plugin: foo"]);
    expect(parsed.systemInit?.pluginErrors).toEqual([
      "Failed to load plugin: foo",
    ]);
  });

  it("accepts structured object pluginErrors (live SDK shape)", () => {
    // This is the verbatim shape from the live G8 Phase A trace.
    const sdkError = {
      plugin: "inline[0]",
      type: "generic-error",
      message:
        "Failed to load plugin: Plugin claude-workflow-plugin has an invalid manifest file at /path/to/plugin.json.\n\nValidation errors: hooks: Invalid input, commands: Invalid input, agents: Invalid input, skills: Invalid input",
    };
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.pluginErrors = [sdkError];
    t.systemInit = {
      plugins: [],
      pluginErrors: [sdkError],
      availableSubagents: [],
      tools: [],
      mcpServers: [],
    };
    const parsed = TraceSchema.parse(t);
    expect(parsed.pluginErrors).toEqual([sdkError]);
    expect(parsed.systemInit?.pluginErrors).toEqual([sdkError]);
  });

  it("accepts mixed string + object pluginErrors and unknown forward-compat fields", () => {
    // Belt-and-braces: future SDK rev might add fields (line numbers,
    // file paths, validation paths). The passthrough record schema must
    // not reject unknown fields, and the harness must continue to accept
    // mixed-shape arrays (e.g. one error from the loader, one from a
    // downstream validator).
    const futureError = {
      plugin: "inline[1]",
      type: "schema-error",
      message: "future shape",
      // Forward-compat fields the harness has never seen:
      details: { line: 42, path: ["agents", 0] },
      severity: "error",
    };
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.pluginErrors = ["legacy string", futureError];
    t.systemInit = {
      plugins: [],
      pluginErrors: ["legacy string", futureError],
      availableSubagents: [],
      tools: [],
      mcpServers: [],
    };
    const parsed = TraceSchema.parse(t);
    expect(parsed.pluginErrors).toHaveLength(2);
    expect(parsed.pluginErrors[0]).toBe("legacy string");
    expect(parsed.pluginErrors[1]).toEqual(futureError);
    expect(parsed.systemInit?.pluginErrors).toHaveLength(2);
  });

  it("parses a real live replay with object pluginErrors", () => {
    // Smoke-test against the actual replay JSONL captured during the
    // G8 Phase A live run. If this regresses, the harness can't parse
    // its own output — that's the bug we're guarding against.
    const replayPath = path.resolve(
      __dirname,
      "..",
      "cassettes",
      "replays",
      "node-react-auth-2026-05-10T12-39-25-664Z.jsonl",
    );
    const fs = require("node:fs") as typeof import("node:fs");
    const raw = fs.readFileSync(replayPath, "utf8").trim();
    const obj = JSON.parse(raw);
    const parsed = TraceSchema.parse(obj);
    expect(parsed.pluginErrors.length).toBeGreaterThan(0);
    // The live trace's first error is a structured object, not a string.
    const first = parsed.pluginErrors[0];
    expect(typeof first).toBe("object");
    expect(first as Record<string, unknown>).toMatchObject({
      plugin: expect.any(String),
      type: expect.any(String),
      message: expect.any(String),
    });
  });
});

describe("normalizeTrace", () => {
  it("collapses tool calls into a name sequence", () => {
    const t = createEmptyTrace("f", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "a",
        name: "Read",
        input: {},
        parentToolUseId: null,
        durationMs: 0,
      },
      {
        id: "b",
        name: "Task",
        input: { subagent_type: "backend" },
        parentToolUseId: null,
        subagentType: "backend",
        durationMs: 0,
      },
    ];
    const n = normalizeTrace(t);
    expect(n.toolSequence).toEqual(["Read", "Task(backend)"]);
  });

  it("indents subagent tree by depth via parentToolUseId chains", () => {
    const t = createEmptyTrace("f", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "task1",
        name: "Task",
        input: { subagent_type: "backend" },
        parentToolUseId: null,
        subagentType: "backend",
        durationMs: 0,
      },
      {
        id: "task2",
        name: "Task",
        input: { subagent_type: "qa" },
        parentToolUseId: "task1",
        subagentType: "qa",
        durationMs: 0,
      },
    ];
    t.subagentInvocations = [
      { type: "backend", toolUseId: "task1", parentToolUseId: null },
      { type: "qa", toolUseId: "task2", parentToolUseId: "task1" },
    ];
    const n = normalizeTrace(t);
    expect(n.subagentTree).toEqual(["@backend", "  @qa"]);
  });

  it("aggregates permission denials by tool name", () => {
    const t = createEmptyTrace("f", "p", "claude-opus-4-7");
    t.permissionDenials = [
      { tool: "Bash", reason: "rule" },
      { tool: "Bash", reason: "rule" },
      { tool: "Write", reason: "mode" },
    ];
    const n = normalizeTrace(t);
    expect(n.permissionDenials).toEqual([
      { tool: "Bash", count: 2 },
      { tool: "Write", count: 1 },
    ]);
  });

  it("folds object pluginErrors into a stable JSON string fingerprint", () => {
    // Two runs of the same broken plugin should produce the SAME
    // fingerprint for diff purposes even though the SDK is free to emit
    // object keys in any order. Sorting the keys in the serialized
    // string is what makes the comparison stable.
    const t1 = createEmptyTrace("f", "p", "claude-opus-4-7");
    t1.pluginErrors = [
      { plugin: "inline[0]", type: "generic-error", message: "boom" },
    ];
    const t2 = createEmptyTrace("f", "p", "claude-opus-4-7");
    t2.pluginErrors = [
      // Same error, different key order — JSON.stringify on the raw
      // object would produce different bytes, but our fingerprint sorts.
      { message: "boom", type: "generic-error", plugin: "inline[0]" },
    ];
    const n1 = normalizeTrace(t1);
    const n2 = normalizeTrace(t2);
    expect(n1.pluginErrors).toEqual(n2.pluginErrors);
    expect(n1.pluginErrors[0]).toBe(
      '{"message":"boom","plugin":"inline[0]","type":"generic-error"}',
    );
  });

  it("passes string pluginErrors through unchanged for cassette compat", () => {
    // Existing/synthetic golden cassettes recorded plain strings. The
    // normalizer must not wrap them in JSON-of-strings, otherwise older
    // cassettes silently drift on the next run.
    const t = createEmptyTrace("f", "p", "claude-opus-4-7");
    t.pluginErrors = ["Failed to load plugin: foo"];
    const n = normalizeTrace(t);
    expect(n.pluginErrors).toEqual(["Failed to load plugin: foo"]);
  });
});

describe("compareToGolden", () => {
  let tmpDir: string;
  beforeEachSetup();

  function beforeEachSetup() {
    // not using vitest beforeEach here to keep this self-contained
  }

  it("records a golden when missing and RECORD_GOLDEN=1", async () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "gold-"));
    const goldPath = path.join(tmpDir, "out.json");
    const t = makeTrace();
    const result = await compareToGolden(t, goldPath, { record: true });
    expect(result.status).toBe("recorded");
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("throws when golden missing and not in record mode", async () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "gold-"));
    const goldPath = path.join(tmpDir, "out.json");
    const t = makeTrace();
    await expect(
      compareToGolden(t, goldPath, { record: false }),
    ).rejects.toThrow(/no golden cassette/i);
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("matches when traces are structurally identical", async () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "gold-"));
    const goldPath = path.join(tmpDir, "out.json");
    const t1 = makeTrace();
    await compareToGolden(t1, goldPath, { record: true });
    // Second run: same structural shape, different durations/costs.
    const t2 = makeTrace();
    t2.result.durationMs = 999_999;
    t2.result.totalCostUsd = 1.23;
    const r = await compareToGolden(t2, goldPath, { record: false });
    expect(r.status).toBe("matched");
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("flags drift on tool sequence change", async () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "gold-"));
    const goldPath = path.join(tmpDir, "out.json");
    const t1 = makeTrace();
    await compareToGolden(t1, goldPath, { record: true });
    // Mutate tool sequence: drop one, add another.
    const t2 = makeTrace();
    t2.toolCalls.push({
      id: "new",
      name: "Bash",
      input: {},
      parentToolUseId: null,
      durationMs: 0,
    });
    const r = await compareToGolden(t2, goldPath, { record: false });
    expect(r.status).toBe("drifted");
    expect(r.diffs?.length ?? 0).toBeGreaterThan(0);
    rmSync(tmpDir, { recursive: true, force: true });
  });

  function makeTrace(): Trace {
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "a",
        name: "Read",
        input: {},
        parentToolUseId: null,
        durationMs: 0,
      },
      {
        id: "b",
        name: "Task",
        input: { subagent_type: "backend" },
        parentToolUseId: null,
        subagentType: "backend",
        durationMs: 0,
      },
    ];
    t.subagentInvocations = [
      { type: "backend", toolUseId: "b", parentToolUseId: null },
    ];
    t.fileWrites = [
      { path: "server/auth.js", bytesWritten: 100, changeType: "added" },
    ];
    t.beadsTasksCreated = ["fix-001"];
    t.beadsLabelTransitions = [
      { taskId: "fix-001", added: ["qa-approved"], removed: ["qa-pending"] },
    ];
    t.hookOutputs = [
      {
        event: "Stop",
        script: "<unknown>",
        decision: "approve",
        durationMs: 0,
      },
    ];
    t.pluginsLoaded = [{ name: "claude-workflow", path: "/plugin" }];
    return t;
  }
});

describe("ensureFixtureGitInit", () => {
  it("is idempotent on an already-initialized fixture", () => {
    const tmp = mkdtempSync(path.join(tmpdir(), "fix-"));
    try {
      writeFileSync(path.join(tmp, "README.md"), "hello\n");
      ensureFixtureGitInit(tmp);
      // Second call should be a noop.
      ensureFixtureGitInit(tmp);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
});

describe("findPluginRoot", () => {
  it("walks up to locate the plugin root from a deep path", () => {
    // From .claude/tests/e2e/lib up to the repo root.
    const root = findPluginRoot(
      "/Users/edk0/Desktop/projects/claude-workflow-plugin/.claude/tests/e2e/lib",
    );
    expect(root).toBe(
      "/Users/edk0/Desktop/projects/claude-workflow-plugin",
    );
  });

  it("throws when no plugin root can be found", () => {
    // `/tmp` has no `.claude-plugin/plugin.json` ancestor.
    expect(() => findPluginRoot("/tmp")).toThrow(
      /could not locate plugin root/,
    );
  });
});

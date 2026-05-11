/**
 * Self-tests for the custom Vitest matchers. Validates the matchers
 * resolve to their actual implementations (the setup.ts registration
 * works) and they produce correct pass/fail outcomes against synthetic
 * Trace inputs.
 */
import { describe, it, expect } from "vitest";
import { createEmptyTrace, type Trace } from "../lib/trace.js";

function buildTrace(): Trace {
  const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
  t.toolCalls = [
    {
      id: "task-be",
      name: "Task",
      input: { subagent_type: "backend" },
      parentToolUseId: null,
      subagentType: "backend",
      durationMs: 0,
    },
    {
      id: "task-qa",
      name: "Task",
      input: { subagent_type: "qa" },
      parentToolUseId: "task-be",
      subagentType: "qa",
      durationMs: 0,
    },
  ];
  t.subagentInvocations = [
    { type: "backend", toolUseId: "task-be", parentToolUseId: null },
    { type: "qa", toolUseId: "task-qa", parentToolUseId: "task-be" },
  ];
  t.fileWrites = [
    { path: "server/auth.js", bytesWritten: 100, changeType: "added" },
  ];
  t.beadsTasksCreated = ["nra-1"];
  t.beadsLabelTransitions = [
    { taskId: "nra-1", added: ["qa-approved"], removed: ["qa-pending"] },
  ];
  t.hookOutputs = [
    {
      event: "Stop",
      script: "<unknown>",
      decision: "approve",
      durationMs: 5,
    },
    {
      event: "PreToolUse",
      script: "<unknown>",
      decision: "block",
      durationMs: 1,
    },
  ];
  t.pluginsLoaded = [{ name: "claude-workflow", path: "/x" }];
  return t;
}

describe("custom matchers (registered globally via setup.ts)", () => {
  it("subagentInvoked passes when type matches", () => {
    const t = buildTrace();
    expect(t).subagentInvoked("backend");
    expect(t).subagentInvoked("qa");
  });

  it("subagentInvoked with parentType filter resolves the call tree", () => {
    const t = buildTrace();
    // qa was spawned by backend (parentToolUseId=task-be).
    expect(t).subagentInvoked("qa", { parentType: "backend" });
  });

  it("hookFired with decision narrows correctly", () => {
    const t = buildTrace();
    expect(t).hookFired("Stop", { decision: "approve" });
    expect(t).hookFired("PreToolUse", { decision: "block" });
  });

  it("beadsLabelTransitioned matches the transition shape", () => {
    const t = buildTrace();
    expect(t).beadsLabelTransitioned("nra-1", ["qa-approved"], ["qa-pending"]);
  });

  it("fileWritten matches a regex", () => {
    const t = buildTrace();
    expect(t).fileWritten(/^server\/.*\.js$/);
  });

  it("noPermissionDenials passes when there are zero", () => {
    const t = buildTrace();
    expect(t).noPermissionDenials();
  });

  it("subagentInvoked fails informatively when type missing", () => {
    const t = buildTrace();
    let failed = false;
    try {
      expect(t).subagentInvoked("frontend");
    } catch {
      failed = true;
    }
    expect(failed).toBe(true);
  });

  // Substrate registration after the plugin.json schema fix
  // (claude-workflow-plugin-0wk.9): plugin-defined agents register under
  // `<plugin>:<name>` qualified types (e.g. `claude-workflow:backend`).
  // `subagentInvoked("backend")` must accept either the bare or
  // namespaced form so a future plugin rename doesn't silently break
  // every spec.
  it("subagentInvoked accepts namespaced subagent types (bare matcher arg)", () => {
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "task-be",
        name: "Agent",
        input: { subagent_type: "claude-workflow:backend" },
        parentToolUseId: null,
        subagentType: "claude-workflow:backend",
        durationMs: 0,
      },
    ];
    t.subagentInvocations = [
      {
        type: "claude-workflow:backend",
        toolUseId: "task-be",
        parentToolUseId: null,
      },
    ];
    // Bare argument resolves to the namespaced trace entry.
    expect(t).subagentInvoked("backend");
    // Qualified-form argument also passes (exact match).
    expect(t).subagentInvoked("claude-workflow:backend");
  });

  it("subagentInvoked accepts bare types when matcher is called with qualified form", () => {
    // Mirror case: trace has bare `backend`, spec expects qualified
    // `claude-workflow:backend`. Should still match — the matcher
    // strips qualifiers on both sides before comparing.
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "task-be",
        name: "Agent",
        input: { subagent_type: "backend" },
        parentToolUseId: null,
        subagentType: "backend",
        durationMs: 0,
      },
    ];
    t.subagentInvocations = [
      { type: "backend", toolUseId: "task-be", parentToolUseId: null },
    ];
    expect(t).subagentInvoked("claude-workflow:backend");
  });

  it("subagentInvoked with parentType filter is qualifier-tolerant", () => {
    // QA was spawned by the namespaced backend agent; the parentType
    // filter should still resolve when expressed as bare "backend".
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "task-be",
        name: "Agent",
        input: { subagent_type: "claude-workflow:backend" },
        parentToolUseId: null,
        subagentType: "claude-workflow:backend",
        durationMs: 0,
      },
      {
        id: "task-qa",
        name: "Agent",
        input: { subagent_type: "claude-workflow:qa" },
        parentToolUseId: "task-be",
        subagentType: "claude-workflow:qa",
        durationMs: 0,
      },
    ];
    t.subagentInvocations = [
      {
        type: "claude-workflow:backend",
        toolUseId: "task-be",
        parentToolUseId: null,
      },
      {
        type: "claude-workflow:qa",
        toolUseId: "task-qa",
        parentToolUseId: "task-be",
      },
    ];
    expect(t).subagentInvoked("qa", { parentType: "backend" });
  });

  it("delegatedTo matches the @role marker in the Agent prompt", () => {
    // Models the actual SDK substrate seen in the live G8 trace: the
    // orchestrator passes subagent_type="general-purpose" but encodes
    // the role via the Agent tool's description and prompt fields.
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "agent-1",
        name: "Agent",
        input: {
          subagent_type: "general-purpose",
          description: "Backend: POST /auth/login with JWT",
          prompt:
            "You are acting as the @backend specialist for the e2e fixture.",
        },
        parentToolUseId: null,
        subagentType: "general-purpose",
        durationMs: 0,
      },
      {
        id: "agent-2",
        name: "Agent",
        input: {
          subagent_type: "general-purpose",
          description: "Frontend: LoginForm React component",
          prompt: "You are acting as the @frontend specialist.",
        },
        parentToolUseId: null,
        subagentType: "general-purpose",
        durationMs: 0,
      },
      {
        id: "agent-3",
        name: "Agent",
        input: {
          subagent_type: "general-purpose",
          description: "QA review: auth feature",
          prompt: "You are the @qa specialist. Review the changes.",
        },
        parentToolUseId: null,
        subagentType: "general-purpose",
        durationMs: 0,
      },
    ];
    expect(t).delegatedTo("backend");
    expect(t).delegatedTo("frontend");
    expect(t).delegatedTo("qa");
    // Case-insensitive role argument.
    expect(t).delegatedTo("Backend");
  });

  it("delegatedTo matches description starting with '<Role>:'", () => {
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "agent-1",
        name: "Agent",
        input: {
          subagent_type: "general-purpose",
          description: "Devops: configure CI",
          prompt: "no role marker in prompt",
        },
        parentToolUseId: null,
        subagentType: "general-purpose",
        durationMs: 0,
      },
    ];
    expect(t).delegatedTo("devops");
  });

  it("delegatedTo matches Task tool calls too (not only Agent)", () => {
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "task-1",
        name: "Task",
        input: {
          subagent_type: "general-purpose",
          description: "QA gate review",
          prompt: "act as @qa for this gate",
        },
        parentToolUseId: null,
        subagentType: "general-purpose",
        durationMs: 0,
      },
    ];
    expect(t).delegatedTo("qa");
  });

  it("delegatedTo fails informatively when no Agent/Task call references the role", () => {
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "agent-1",
        name: "Agent",
        input: {
          subagent_type: "general-purpose",
          description: "Backend: foo",
          prompt: "act as @backend",
        },
        parentToolUseId: null,
        subagentType: "general-purpose",
        durationMs: 0,
      },
    ];
    let failed = false;
    try {
      expect(t).delegatedTo("frontend");
    } catch {
      failed = true;
    }
    expect(failed).toBe(true);
  });

  it("delegatedTo ignores non-Agent/Task tool calls", () => {
    const t = createEmptyTrace("fix", "p", "claude-opus-4-7");
    t.toolCalls = [
      {
        id: "bash-1",
        name: "Bash",
        input: { command: "echo @backend", description: "Backend: nope" },
        parentToolUseId: null,
        durationMs: 0,
      },
    ];
    let failed = false;
    try {
      expect(t).delegatedTo("backend");
    } catch {
      failed = true;
    }
    expect(failed).toBe(true);
  });
});

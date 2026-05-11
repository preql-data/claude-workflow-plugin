/**
 * Unit tests for `lib/validate-plugin-manifest.ts`.
 *
 * The validator is a zod replica of the SDK's CSH() schema (see lib comment).
 * These tests pin down the boundary cases that motivated the replica:
 *   - reject paths without "./" prefix (the live bug — claude-workflow-plugin-0wk.9)
 *   - accept the canonical fixed shape
 *   - tolerate either inline hooks or "./...json" path
 *   - reject the SDK-rejected shape `{ path: "..." }` for hooks
 *
 * If the SDK ever exposes its schema for direct import we should swap this
 * out for the real thing; until then this file is the regression net.
 */
import { describe, it, expect } from "vitest";
import { validateManifest } from "../lib/validate-plugin-manifest.js";

const baseFields = {
  name: "claude-workflow",
  version: "3.0.0",
  description: "test",
  author: { name: "preql-data" },
  homepage: "https://example.com",
  repository: "https://example.com/repo",
  license: "MIT",
  keywords: ["a"],
};

describe("validate-plugin-manifest", () => {
  it("accepts the canonical fixed shape", () => {
    const result = validateManifest({
      ...baseFields,
      agents: ["./.claude/agents/orchestrator.md"],
      commands: ["./.claude/commands/workflow-model.md"],
      skills: ["./.claude/skills/workflow-engine"],
      hooks: "./.claude/hooks/hooks.json",
      mcpServers: { bd: { command: "node" } },
    });
    expect(result.ok).toBe(true);
    expect(result.errors).toEqual([]);
  });

  it("accepts a manifest with no component fields (auto-discovery)", () => {
    // The Anthropic-official plugins (feature-dev, hookify, etc.) leave
    // every component field unset and rely on plugin-root auto-discovery.
    // The validator must accept that shape too.
    const result = validateManifest(baseFields);
    expect(result.ok).toBe(true);
  });

  it("rejects agent paths without leading ./", () => {
    // This is the exact shape that produced the live SDK error
    // "Plugin claude-workflow-plugin has an invalid manifest file ...
    //  Validation errors: agents: Invalid input".
    const result = validateManifest({
      ...baseFields,
      agents: [".claude/agents/orchestrator.md"],
    });
    expect(result.ok).toBe(false);
    expect(result.errors.join("\n")).toMatch(/agents.*start with "\.\/"/);
  });

  it("rejects { path: ... } shape for hooks (the original buggy form)", () => {
    const result = validateManifest({
      ...baseFields,
      hooks: { path: ".claude/hooks/hooks.json" },
    });
    expect(result.ok).toBe(false);
    expect(result.errors.some((e) => e.startsWith("hooks"))).toBe(true);
  });

  it("accepts inline hooks object", () => {
    const result = validateManifest({
      ...baseFields,
      hooks: {
        hooks: {
          PreToolUse: [
            { matcher: "Write", hooks: [{ type: "command", command: "x" }] },
          ],
        },
      },
    });
    expect(result.ok).toBe(true);
  });

  it("rejects an empty plugin name", () => {
    const result = validateManifest({ ...baseFields, name: "" });
    expect(result.ok).toBe(false);
    expect(result.errors.join("\n")).toMatch(/name/);
  });

  it("requires the author.name field if author is present", () => {
    const result = validateManifest({
      ...baseFields,
      author: { url: "https://example.com" },
    });
    expect(result.ok).toBe(false);
    expect(result.errors.join("\n")).toMatch(/author\.name/);
  });

  it("rejects skills paths without ./ prefix", () => {
    const result = validateManifest({
      ...baseFields,
      skills: [".claude/skills/workflow-engine"],
    });
    expect(result.ok).toBe(false);
  });
});

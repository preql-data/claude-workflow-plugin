/**
 * The Trace object — what every L3/L4 E2E test asserts on.
 *
 * Per the G8 plan (we-are-working-on-dynamic-marshmallow.md, "The Trace
 * object" section): we capture STRUCTURE, not prose. Tool call shapes,
 * subagent tree (via `parentToolUseId`), hook firing decisions, file-write
 * paths, Beads label transitions, permission denials. Anything that drifts
 * run-to-run (prose, costs, durations, IDs) is collected for diagnostics
 * but ignored by `goldenCompare`.
 *
 * The Zod schema below is the single source of truth for the shape; both
 * `runFixture` (producer) and `goldenCompare` (consumer/normalizer) parse
 * traces through it. Loose fields are tolerated where the SDK schema is
 * still evolving (pre-1.0); fields the assertions depend on are strict.
 */
import { z } from "zod";

export const ToolCallSchema = z.object({
  /** SDK tool_use block id ("toolu_xxx"). Stable within one run; rewritten
   *  to a deterministic ordinal during normalization. */
  id: z.string(),
  /** Tool name (e.g. "Write", "Bash", "Task", "mcp__bd__create_task"). */
  name: z.string(),
  /** Raw input object as the model produced it. We keep a structural
   *  fingerprint (key set + path-like values) for comparison; full payload
   *  is preserved for debug/diagnostics. */
  input: z.unknown(),
  /** SDK chain-tracking field. Top-level (orchestrator) = null. Subagent
   *  invocations carry the parent's tool_use id here. */
  parentToolUseId: z.string().nullable(),
  /** When `name === "Task"`, this is the input.subagent_type pulled out
   *  for convenience. Empty string if absent. */
  subagentType: z.string().optional(),
  /** Wall-clock duration in ms; ignored during golden comparison. */
  durationMs: z.number().nonnegative().default(0),
  /** UUID of the assistant message that contained this tool_use. Useful
   *  for cross-referencing back to the raw event log when debugging. */
  messageUuid: z.string().optional(),
});
export type ToolCall = z.infer<typeof ToolCallSchema>;

export const SubagentInvocationSchema = z.object({
  /** "backend" | "frontend" | "qa" | "devops" | "orchestrator" | ... */
  type: z.string(),
  /** ID of the Task tool_use that spawned this subagent (= the subagent's
   *  parentToolUseId for any nested calls). */
  toolUseId: z.string(),
  /** If this subagent was itself spawned by another subagent, the parent's
   *  toolUseId (= grandparent in the call tree). Null if spawned by the
   *  root orchestrator. */
  parentToolUseId: z.string().nullable(),
});
export type SubagentInvocation = z.infer<typeof SubagentInvocationSchema>;

export const FileWriteSchema = z.object({
  /** Path relative to the fixture root (forward-slash, OS-normalized). */
  path: z.string(),
  /** File size after the run; -1 if the path was deleted (also captured
   *  here so we can assert "this file was removed"). Ignored during
   *  golden compare; only `path` is structural. */
  bytesWritten: z.number().int(),
  /** "added" | "modified" | "deleted". Comes from `git status --porcelain`. */
  changeType: z.enum(["added", "modified", "deleted"]),
});
export type FileWrite = z.infer<typeof FileWriteSchema>;

export const PermissionDenialSchema = z.object({
  tool: z.string(),
  reason: z.string(),
  /** "rule" | "mode" | "classifier" | "asyncAgent" | unknown. */
  decisionReasonType: z.string().optional(),
  agentId: z.string().optional(),
  toolUseId: z.string().optional(),
});
export type PermissionDenial = z.infer<typeof PermissionDenialSchema>;

export const HookOutputSchema = z.object({
  /** Hook event names mirror the SDK's. We accept any string — the plugin
   *  may grow new events — and let assertions narrow as needed. */
  event: z.string(),
  /** Path to the hook script that fired. Best-effort; the SDK does not
   *  always reflect this (shell-command hooks loaded via settingSources
   *  fire opaquely from the SDK's POV). When unknown we record "<unknown>"
   *  and rely on `event` + `decision`. */
  script: z.string().default("<unknown>"),
  /** "approve" | "block" | "ask" — straight from HookJSONOutput.decision.
   *  Optional because not every hook event surfaces a decision (e.g. a
   *  SessionStart hook that just logs). */
  decision: z.enum(["approve", "block", "ask"]).optional(),
  /** Free-form reason captured from HookJSONOutput.reason. Useful for
   *  debugging; ignored in golden compare. */
  reason: z.string().optional(),
  /** Hook duration in ms. Ignored in golden compare. */
  durationMs: z.number().nonnegative().default(0),
  /** Raw response payload; preserved verbatim for diagnostics. */
  response: z.unknown().optional(),
  /** SDK hook_id for cross-referencing the started/progress/response trio. */
  hookId: z.string().optional(),
});
export type HookOutput = z.infer<typeof HookOutputSchema>;

export const BeadsLabelTransitionSchema = z.object({
  taskId: z.string(),
  added: z.array(z.string()).default([]),
  removed: z.array(z.string()).default([]),
});
export type BeadsLabelTransition = z.infer<typeof BeadsLabelTransitionSchema>;

/**
 * Plugin-load error as surfaced by the SDK at `system/init`.
 *
 * Two shapes occur in the wild:
 *   - **string** — older/synthetic traces and the plan's original spec
 *     stored each error as a flat human-readable line.
 *   - **structured object** — the live SDK (observed in the G8 Phase A
 *     trace at `cassettes/replays/node-react-auth-2026-05-10T12-39-25-664Z.jsonl`)
 *     emits `{ plugin, type, message }`. The `message` carries the validator's
 *     verbatim complaint about the plugin manifest; `plugin` is the SDK's
 *     internal slot identifier (e.g. `"inline[0]"`) and `type` is a coarse
 *     family (`"generic-error"` so far).
 *
 * The schema accepts either shape. Object errors are stored as a passthrough
 * `record(string, unknown)` so the SDK can grow new fields (line numbers,
 * file paths, validation paths) without forcing a harness change. Downstream
 * normalization (`goldenCompare.normalizeTrace`) folds both shapes into a
 * stable JSON-string fingerprint so existing cassettes continue to compare.
 */
export const PluginErrorSchema = z.union([
  z.string(),
  z.record(z.string(), z.unknown()),
]);
export type PluginError = z.infer<typeof PluginErrorSchema>;

export const ResultSchema = z.object({
  /** Final assistant text. Captured for the human reading the cassette;
   *  IGNORED by golden comparison (prose drifts). */
  finalAssistantMessage: z.string(),
  totalCostUsd: z.number().nonnegative().default(0),
  inputTokens: z.number().int().nonnegative().default(0),
  outputTokens: z.number().int().nonnegative().default(0),
  turns: z.number().int().nonnegative().default(0),
  /** Result subtype: "success" | "error_max_turns" | ... */
  subtype: z.string().default("success"),
  /** Total wall-clock duration in ms. */
  durationMs: z.number().nonnegative().default(0),
});
export type Result = z.infer<typeof ResultSchema>;

/**
 * Best-effort capture of the SDK's `system/init` message. The SDK is
 * pre-1.0 and the surface is still evolving — fields are tolerated as
 * optional and treated as diagnostic-only (never compared in the
 * golden). The intent is to give post-mortem visibility into plugin
 * loading: when `pluginsLoaded` is empty in the trace, this snapshot
 * lets us see whether the SDK silently dropped the plugin, never
 * surfaced it in the init event, or registered it under an unexpected
 * shape. Anything the SDK emits at init time that the harness doesn't
 * already understand lands in `raw` so future debug sessions don't
 * have to re-spend an expensive live capture to inspect it.
 */
export const SystemInitSchema = z
  .object({
    /** Plugin names the SDK reported as loaded at init. May be a subset
     *  of `Trace.pluginsLoaded` when the harness derives loaded plugins
     *  from multiple sources; here we keep the SDK's own view. */
    plugins: z.array(z.string()).default([]),
    /** Plugin-load errors the SDK reported (if any). Accepts either
     *  string or structured object — see PluginErrorSchema. */
    pluginErrors: z.array(PluginErrorSchema).default([]),
    /** Subagents the SDK reports as available for the Task/Agent tool's
     *  `subagent_type` parameter. Empty in the live G8 trace where the
     *  plugin's @backend/@frontend/@qa agents weren't registered. */
    availableSubagents: z.array(z.string()).default([]),
    /** Full tools list from init. Mirrors `Trace.toolsAvailable` for
     *  convenience; included here so the systemInit object can be read
     *  standalone without cross-referencing other top-level fields. */
    tools: z.array(z.string()).default([]),
    /** MCP servers reported at init (name + status). */
    mcpServers: z
      .array(z.object({ name: z.string(), status: z.string() }))
      .default([]),
    /** The verbatim init message fields the harness didn't parse into
     *  the structured slots above. Useful when we need to read whatever
     *  the SDK currently emits without having to re-record. */
    raw: z.unknown().optional(),
  })
  .optional();
export type SystemInit = z.infer<typeof SystemInitSchema>;

export const TraceSchema = z.object({
  /** Schema version. Bump when the structural shape changes in a way
   *  that would invalidate older golden cassettes. */
  schemaVersion: z.literal(1),
  fixture: z.string(),
  prompt: z.string(),
  /** ISO 8601 timestamp when the run started. Ignored in golden compare. */
  startedAt: z.string(),
  /** Pinned model snapshot used for the run. NOT ignored: a cassette
   *  recorded against an old model is invalid against a different one. */
  modelSnapshot: z.string(),
  toolCalls: z.array(ToolCallSchema).default([]),
  subagentInvocations: z.array(SubagentInvocationSchema).default([]),
  fileWrites: z.array(FileWriteSchema).default([]),
  permissionDenials: z.array(PermissionDenialSchema).default([]),
  hookOutputs: z.array(HookOutputSchema).default([]),
  beadsTasksCreated: z.array(z.string()).default([]),
  beadsLabelTransitions: z.array(BeadsLabelTransitionSchema).default([]),
  /** Plugin loader status from the SDK init event. Cassette-stable; if
   *  this drifts, the harness is loading the plugin wrong. */
  pluginsLoaded: z
    .array(z.object({ name: z.string(), path: z.string() }))
    .default([]),
  pluginErrors: z.array(PluginErrorSchema).default([]),
  /** Raw `init` event tools list, for diagnostics. Ignored in compare. */
  toolsAvailable: z.array(z.string()).default([]),
  /** Best-effort SDK init snapshot. Diagnostic only; ignored in golden
   *  compare. See SystemInitSchema for the rationale. */
  systemInit: SystemInitSchema,
  result: ResultSchema,
});
export type Trace = z.infer<typeof TraceSchema>;

/**
 * Build a fresh, empty Trace skeleton. The runner mutates this in place
 * as messages stream in. `result` is filled at the end from the SDK's
 * `result` event.
 */
export function createEmptyTrace(
  fixture: string,
  prompt: string,
  modelSnapshot: string,
): Trace {
  return {
    schemaVersion: 1,
    fixture,
    prompt,
    startedAt: new Date().toISOString(),
    modelSnapshot,
    toolCalls: [],
    subagentInvocations: [],
    fileWrites: [],
    permissionDenials: [],
    hookOutputs: [],
    beadsTasksCreated: [],
    beadsLabelTransitions: [],
    pluginsLoaded: [],
    pluginErrors: [],
    toolsAvailable: [],
    result: {
      finalAssistantMessage: "",
      totalCostUsd: 0,
      inputTokens: 0,
      outputTokens: 0,
      turns: 0,
      subtype: "success",
      durationMs: 0,
    },
  };
}

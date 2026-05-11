/**
 * goldenCompare — structural diff against a committed golden cassette.
 *
 * The plan ("Determinism strategy" §6) calls golden cassettes "evidence,
 * not a replay substitute". Concretely:
 *
 *   - We assert STRUCTURE (tool name sequence, subagent tree, hook firing
 *     order, file-write paths, label-transition shapes, plugin load
 *     status).
 *   - We IGNORE drift (durations, costs, IDs, prose, byte sizes, raw
 *     hook response bodies, raw tool inputs unless their key set changes).
 *
 * On record mode (RECORD_GOLDEN=1), missing goldens are written. Existing
 * goldens are NEVER overwritten silently — if the user wants to refresh a
 * cassette, they delete it first. This makes accidental cassette drift
 * impossible: a structural change always produces a diff for review.
 *
 * The cassette format is JSONL with two lines:
 *   1. metadata (schemaVersion, fixture, modelSnapshot, recordedAt)
 *   2. the normalized trace (one JSON object on the second line)
 *
 * We use JSONL not JSON-array because git diff handles line-oriented
 * formats more readably and we anticipate adding event-stream sidecar
 * lines in Phase B/C without bumping the schema version.
 */
import {
  readFileSync,
  writeFileSync,
  existsSync,
  mkdirSync,
} from "node:fs";
import path from "node:path";

import type { Trace, ToolCall } from "./trace.js";

export type GoldenStatus = "matched" | "drifted" | "recorded";

export interface GoldenDiff {
  status: GoldenStatus;
  /** Path to the golden file. Always present. */
  goldenPath: string;
  /** When status is "drifted", a structured list of mismatches. */
  diffs?: string[];
  /** When status is "drifted" or "matched", the normalized trace we
   *  compared against (the actual run, not the golden). Useful for
   *  surfacing a pretty-print in a failed test message. */
  normalizedTrace?: NormalizedTrace;
  /** The golden's normalized trace, when one was loaded. */
  goldenTrace?: NormalizedTrace;
}

export interface NormalizedTrace {
  schemaVersion: 1;
  fixture: string;
  modelSnapshot: string;
  /** Tool name sequence (just `name` strings, in chronological order).
   *  Subagent type is appended in parens for `Task` calls so reordering
   *  changes show up. */
  toolSequence: string[];
  /** Subagent tree as an indented list: each entry is "type:childIndex".
   *  The shape captures who-spawned-whom even if id strings change. */
  subagentTree: string[];
  /** Hook firing sequence, "event[:decision]" — one line per fire. */
  hookSequence: string[];
  /** File-write paths sorted by path; changeType folded in. */
  fileWrites: string[];
  /** Permission denials by tool name (count of denials per tool). */
  permissionDenials: Array<{ tool: string; count: number }>;
  /** Beads task creations (just IDs, sorted). */
  beadsTasksCreated: string[];
  /** Beads label transitions: "<taskId>: +a +b -c" lines, sorted by task. */
  beadsLabelTransitions: string[];
  /** Plugin loader status — names only, sorted. */
  pluginsLoaded: string[];
  /** Plugin load errors verbatim. */
  pluginErrors: string[];
}

/**
 * Strip a trace down to its structural fingerprint. The result is
 * deterministic (within tolerance) across runs of the same fixture with
 * the same prompt against the same model snapshot. Anything in the
 * trace that drifts run-to-run is filtered out here.
 */
export function normalizeTrace(trace: Trace): NormalizedTrace {
  const toolSequence: string[] = [];
  for (const call of trace.toolCalls) {
    if (call.name === "Task" && call.subagentType) {
      toolSequence.push(`Task(${call.subagentType})`);
    } else {
      toolSequence.push(call.name);
    }
  }

  // Build the subagent tree by walking parentToolUseId chains. Each
  // line is "depth | type". Depth is computed by counting parents.
  const idToToolCall = new Map<string, ToolCall>();
  for (const call of trace.toolCalls) idToToolCall.set(call.id, call);

  const depthOf = (call: ToolCall): number => {
    let depth = 0;
    let parentId = call.parentToolUseId;
    const seen = new Set<string>();
    while (parentId && !seen.has(parentId)) {
      seen.add(parentId);
      const parent = idToToolCall.get(parentId);
      if (!parent) break;
      depth += 1;
      parentId = parent.parentToolUseId;
    }
    return depth;
  };

  const subagentTree: string[] = [];
  for (const inv of trace.subagentInvocations) {
    const tc = idToToolCall.get(inv.toolUseId);
    const depth = tc ? depthOf(tc) : 0;
    subagentTree.push(`${"  ".repeat(depth)}@${inv.type}`);
  }

  // Hook sequence: keep firing order, fold decision in. We do NOT sort —
  // ordering is part of the structure (e.g. PostToolUse must fire after
  // PreToolUse for the same tool).
  const hookSequence: string[] = [];
  for (const h of trace.hookOutputs) {
    hookSequence.push(h.decision ? `${h.event}:${h.decision}` : h.event);
  }

  // File writes: deterministic ordering by path. We keep changeType but
  // not bytesWritten (varies by exact prose the model wrote).
  const fileWrites = [...trace.fileWrites]
    .sort((a, b) => a.path.localeCompare(b.path))
    .map((f) => `${f.changeType}:${f.path}`);

  // Permission denials: aggregate by tool. Count is structural — a real
  // regression would show up as more denials.
  const denialMap = new Map<string, number>();
  for (const d of trace.permissionDenials) {
    denialMap.set(d.tool, (denialMap.get(d.tool) ?? 0) + 1);
  }
  const permissionDenials = [...denialMap.entries()]
    .map(([tool, count]) => ({ tool, count }))
    .sort((a, b) => a.tool.localeCompare(b.tool));

  // Beads: sort by id for determinism.
  const beadsTasksCreated = [...trace.beadsTasksCreated].sort();
  const beadsLabelTransitions = [...trace.beadsLabelTransitions]
    .sort((a, b) => a.taskId.localeCompare(b.taskId))
    .map((t) => {
      const adds = [...t.added].sort().map((l) => `+${l}`);
      const removes = [...t.removed].sort().map((l) => `-${l}`);
      return `${t.taskId}: ${[...adds, ...removes].join(" ")}`;
    });

  const pluginsLoaded = [...trace.pluginsLoaded]
    .map((p) => p.name)
    .sort();
  // Plugin errors arrive as either strings (old/synthetic shape) or
  // `{ plugin, type, message, ... }` objects (live SDK). For comparison
  // purposes we fold every error to a stable string fingerprint:
  //   - strings pass through untouched (preserves old golden cassettes);
  //   - objects are stringified with sorted keys so new fields don't
  //     scramble the comparison and so JSON.stringify isn't sensitive to
  //     key insertion order. We DO NOT filter to a "known fields" subset
  //     because the plan calls for forward-compat passthrough; if the SDK
  //     starts surfacing additional structured detail (line numbers,
  //     manifest paths) we want to see it diff in the cassette.
  const pluginErrors = [...trace.pluginErrors].map(serializePluginError);

  return {
    schemaVersion: 1,
    fixture: trace.fixture,
    modelSnapshot: trace.modelSnapshot,
    toolSequence,
    subagentTree,
    hookSequence,
    fileWrites,
    permissionDenials,
    beadsTasksCreated,
    beadsLabelTransitions,
    pluginsLoaded,
    pluginErrors,
  };
}

/** Pretty-print a normalized trace for cassette storage. Multi-line so
 *  git diff shows individual changes, not one giant blob. */
function serializeNormalized(n: NormalizedTrace): string {
  return JSON.stringify(n, null, 2);
}

/**
 * Fold a plugin error (which may be a string or a structured object) into
 * a stable string fingerprint for golden comparison.
 *
 * Strings pass through unchanged so previously-recorded cassettes (which
 * stored each error as a single line) keep matching. Objects are
 * stringified with their keys sorted alphabetically so JSON.stringify's
 * insertion-order sensitivity doesn't introduce false drift between runs
 * — the SDK is free to emit `{ plugin, type, message }` in any order and
 * the cassette will still match.
 */
function serializePluginError(err: unknown): string {
  if (typeof err === "string") return err;
  if (err && typeof err === "object") {
    const sortedKeys = Object.keys(err as Record<string, unknown>).sort();
    const ordered: Record<string, unknown> = {};
    for (const k of sortedKeys) {
      ordered[k] = (err as Record<string, unknown>)[k];
    }
    return JSON.stringify(ordered);
  }
  // Defensive fallback: stringify whatever odd shape the SDK throws at
  // us so the comparison can still run rather than the whole pipeline
  // throwing on an unexpected primitive (numbers, booleans, null).
  return JSON.stringify(err);
}

/** Read a golden cassette. Returns null if not present. Throws if the
 *  file is malformed. */
function readGolden(goldenPath: string): NormalizedTrace | null {
  if (!existsSync(goldenPath)) return null;
  const raw = readFileSync(goldenPath, "utf8").trim();
  if (!raw) return null;
  // Cassette format: 1st line metadata, 2nd line normalized trace.
  // Tolerate a single-line cassette too (just the trace).
  const lines = raw.split("\n");
  let traceLine: string;
  if (lines.length >= 2) {
    traceLine = lines.slice(1).join("\n").trim();
  } else {
    traceLine = lines[0]!;
  }
  // The "trace" portion may itself be multi-line pretty-printed JSON.
  // We try parsing the whole tail as one object.
  try {
    return JSON.parse(traceLine) as NormalizedTrace;
  } catch (err) {
    throw new Error(
      `goldenCompare: golden cassette at ${goldenPath} is malformed (${(err as Error).message})`,
    );
  }
}

/** Recursive shallow structural diff. Only collects differences, doesn't
 *  attempt patch-style output. */
function diffNormalized(
  actual: NormalizedTrace,
  golden: NormalizedTrace,
): string[] {
  const diffs: string[] = [];

  if (actual.modelSnapshot !== golden.modelSnapshot) {
    diffs.push(
      `modelSnapshot drifted: golden=${golden.modelSnapshot} actual=${actual.modelSnapshot} — re-record cassette intentionally if model snapshot changed.`,
    );
  }
  if (actual.fixture !== golden.fixture) {
    diffs.push(
      `fixture name drifted: golden=${golden.fixture} actual=${actual.fixture}`,
    );
  }

  diffArrays("toolSequence", actual.toolSequence, golden.toolSequence, diffs);
  diffArrays("subagentTree", actual.subagentTree, golden.subagentTree, diffs);
  diffArrays("hookSequence", actual.hookSequence, golden.hookSequence, diffs);
  diffArrays("fileWrites", actual.fileWrites, golden.fileWrites, diffs);
  diffArrays(
    "beadsTasksCreated",
    actual.beadsTasksCreated,
    golden.beadsTasksCreated,
    diffs,
  );
  diffArrays(
    "beadsLabelTransitions",
    actual.beadsLabelTransitions,
    golden.beadsLabelTransitions,
    diffs,
  );
  diffArrays(
    "pluginsLoaded",
    actual.pluginsLoaded,
    golden.pluginsLoaded,
    diffs,
  );
  diffArrays(
    "pluginErrors",
    actual.pluginErrors,
    golden.pluginErrors,
    diffs,
  );

  // Permission denials: compare both tool name and count.
  const goldenDenialMap = new Map(
    golden.permissionDenials.map((d) => [d.tool, d.count]),
  );
  const actualDenialMap = new Map(
    actual.permissionDenials.map((d) => [d.tool, d.count]),
  );
  const allTools = new Set([
    ...goldenDenialMap.keys(),
    ...actualDenialMap.keys(),
  ]);
  for (const tool of allTools) {
    const g = goldenDenialMap.get(tool) ?? 0;
    const a = actualDenialMap.get(tool) ?? 0;
    if (g !== a) {
      diffs.push(`permissionDenials[${tool}]: golden=${g} actual=${a}`);
    }
  }

  return diffs;
}

function diffArrays(
  field: string,
  actual: readonly string[],
  golden: readonly string[],
  out: string[],
): void {
  // Order-sensitive comparison — for sequences (tool, hook) the order is
  // structural; for sets (fileWrites, beadsTasksCreated) we already
  // sorted at normalize time, so order coincidentally matches set
  // semantics.
  if (actual.length !== golden.length) {
    out.push(
      `${field}: length differs (golden=${golden.length} actual=${actual.length})\n  + golden: ${JSON.stringify(golden)}\n  + actual: ${JSON.stringify(actual)}`,
    );
    return;
  }
  for (let i = 0; i < actual.length; i++) {
    if (actual[i] !== golden[i]) {
      out.push(
        `${field}[${i}]: golden=${JSON.stringify(golden[i])} actual=${JSON.stringify(actual[i])}`,
      );
    }
  }
}

export interface CompareToGoldenOptions {
  /** Override RECORD_GOLDEN env. Useful in tests of the harness itself. */
  record?: boolean;
}

/**
 * Compare a freshly produced trace against a committed golden cassette.
 *
 * Behavior:
 *   - Golden missing + RECORD_GOLDEN=1 → write it, return {status:"recorded"}.
 *   - Golden missing + no record flag → throw.
 *   - Golden present → normalize both, structural diff, return
 *     {status:"matched"|"drifted", diffs?}.
 *
 * The harness never overwrites an existing golden silently. To refresh,
 * delete the file and re-run with RECORD_GOLDEN=1. This is intentional:
 * golden drift should always be visible in PR diffs.
 */
export async function compareToGolden(
  trace: Trace,
  goldenPath: string,
  options: CompareToGoldenOptions = {},
): Promise<GoldenDiff> {
  const recordMode =
    options.record ?? process.env.RECORD_GOLDEN === "1";
  const normalized = normalizeTrace(trace);
  const goldenTrace = readGolden(goldenPath);

  if (!goldenTrace) {
    if (!recordMode) {
      throw new Error(
        `goldenCompare: no golden cassette at ${goldenPath}. Re-run with RECORD_GOLDEN=1 to capture one.`,
      );
    }
    // Write a new golden.
    const goldenDir = path.dirname(goldenPath);
    if (!existsSync(goldenDir)) mkdirSync(goldenDir, { recursive: true });
    const metadata = {
      cassetteSchemaVersion: 1,
      fixture: normalized.fixture,
      modelSnapshot: normalized.modelSnapshot,
      recordedAt: new Date().toISOString(),
      note:
        "Golden cassette: structural fingerprint of a known-good run. " +
        "Edits to this file should be reviewed in PR diffs. To refresh: " +
        "delete this file and rerun with RECORD_GOLDEN=1.",
    };
    const body =
      JSON.stringify(metadata) + "\n" + serializeNormalized(normalized) + "\n";
    writeFileSync(goldenPath, body, "utf8");
    return { status: "recorded", goldenPath, normalizedTrace: normalized };
  }

  const diffs = diffNormalized(normalized, goldenTrace);
  if (diffs.length === 0) {
    return {
      status: "matched",
      goldenPath,
      normalizedTrace: normalized,
      goldenTrace,
    };
  }
  return {
    status: "drifted",
    goldenPath,
    diffs,
    normalizedTrace: normalized,
    goldenTrace,
  };
}

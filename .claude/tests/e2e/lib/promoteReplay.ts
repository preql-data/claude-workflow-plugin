#!/usr/bin/env tsx
/**
 * promoteReplay — promote a captured replay JSONL into a committed
 * golden cassette, without re-running the live SDK.
 *
 * The G8 plan distinguishes "replay" from "golden":
 *
 *   - **Replay** (`cassettes/replays/<fixture>-<iso-timestamp>.jsonl`): the
 *     verbatim Trace dumped by `runFixture` after a live capture. One
 *     file per recording. These are diagnostic — not normalized, not
 *     deduplicated, dated by capture wall-clock. Useful for
 *     post-mortems and as the raw input to this promoter.
 *   - **Golden** (`cassettes/golden/<fixture>.jsonl`): the canonical
 *     structural fingerprint the harness compares each fresh run
 *     against. One per fixture. Normalized via `goldenCompare.normalizeTrace`
 *     so drift in prose/IDs/durations doesn't trigger false positives.
 *
 * This script bridges the two: read a replay, validate it parses against
 * `TraceSchema` (the live trace surface evolves and the schema sometimes
 * needs widening — see PluginErrorSchema's history for example), then
 * normalize and write the golden. Existing goldens are NEVER overwritten
 * silently — promoting on top of an existing golden is an explicit
 * operator decision, gated by `--force`.
 *
 * Usage:
 *
 *   npx tsx lib/promoteReplay.ts \
 *     --fixture <slug> \
 *     --replay <path-to-replay.jsonl> \
 *     [--validate-only] \
 *     [--force] \
 *     [--out <path>]
 *
 * Prints a structured summary (tool counts, subagent invocations, hook
 * firings, plugin errors, the Agent/Task descriptions the orchestrator
 * generated) on stdout — both for human eyeballs at PR review time and
 * for downstream tooling that wants to embed the summary in CI output.
 *
 * Exit codes:
 *   0 — success (golden written, or `--validate-only` validated cleanly)
 *   1 — schema validation failed
 *   2 — golden already exists and `--force` not passed
 *   3 — bad CLI args
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { TraceSchema, type Trace } from "./trace.js";
import { normalizeTrace } from "./goldenCompare.js";

interface CliArgs {
  fixture: string;
  replay: string;
  validateOnly: boolean;
  force: boolean;
  out?: string;
}

/**
 * Tiny argv parser — we deliberately avoid yargs/commander to keep this
 * script's dependency surface zero beyond what the harness already pulls
 * in. The flag syntax is `--key value` or `--flag` (boolean). Unknown
 * flags exit 3 with a usage message.
 */
function parseArgs(argv: string[]): CliArgs {
  const out: Partial<CliArgs> = { validateOnly: false, force: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case "--fixture":
        out.fixture = argv[++i];
        break;
      case "--replay":
        out.replay = argv[++i];
        break;
      case "--out":
        out.out = argv[++i];
        break;
      case "--validate-only":
        out.validateOnly = true;
        break;
      case "--force":
        out.force = true;
        break;
      case "-h":
      case "--help":
        printUsage();
        process.exit(0);
      default:
        process.stderr.write(`promoteReplay: unknown argument ${a}\n`);
        printUsage();
        process.exit(3);
    }
  }
  if (!out.fixture || !out.replay) {
    process.stderr.write("promoteReplay: --fixture and --replay are required\n");
    printUsage();
    process.exit(3);
  }
  return out as CliArgs;
}

function printUsage(): void {
  process.stderr.write(
    [
      "Usage: tsx lib/promoteReplay.ts --fixture <slug> --replay <path>",
      "                                [--validate-only] [--force] [--out <path>]",
      "",
      "  --fixture        Slug used for the golden filename (e.g. node-react-auth).",
      "  --replay         Path to the replay JSONL (one Trace JSON per file).",
      "  --validate-only  Just parse + summarize; do not write a golden.",
      "  --force          Overwrite an existing golden (default: refuse, exit 2).",
      "  --out            Override the golden output path. Default:",
      "                   <e2e-root>/cassettes/golden/<fixture>.jsonl",
      "",
    ].join("\n"),
  );
}

interface TraceSummary {
  toolCalls: number;
  subagentInvocations: number;
  hookOutputs: number;
  fileWrites: number;
  beadsTasksCreated: number;
  pluginErrors: number;
  agentDelegations: Array<{
    name: string;
    description: string;
    subagentType?: string;
  }>;
  toolCounts: Record<string, number>;
  pluginsLoaded: string[];
}

/**
 * Walk a parsed Trace and produce a small, human-friendly summary.
 *
 * Why these specific stats: they're the things a reviewer eyeballs before
 * merging a refreshed cassette. "How many tool calls? Did QA get
 * delegated? Did any hooks fire? Were there plugin errors?" is the
 * repeated set of questions every Phase A retro asks; this answers them
 * in one pass.
 */
function summarizeTrace(trace: Trace): TraceSummary {
  const toolCounts: Record<string, number> = {};
  const agentDelegations: TraceSummary["agentDelegations"] = [];
  for (const tc of trace.toolCalls) {
    toolCounts[tc.name] = (toolCounts[tc.name] ?? 0) + 1;
    if (tc.name === "Agent" || tc.name === "Task") {
      const i = (tc.input ?? {}) as { description?: string };
      agentDelegations.push({
        name: tc.name,
        description: (i.description ?? "<no description>").trim(),
        subagentType: tc.subagentType || undefined,
      });
    }
  }
  return {
    toolCalls: trace.toolCalls.length,
    subagentInvocations: trace.subagentInvocations.length,
    hookOutputs: trace.hookOutputs.length,
    fileWrites: trace.fileWrites.length,
    beadsTasksCreated: trace.beadsTasksCreated.length,
    pluginErrors: trace.pluginErrors.length,
    agentDelegations,
    toolCounts,
    pluginsLoaded: trace.pluginsLoaded.map((p) => p.name),
  };
}

function formatSummary(s: TraceSummary): string {
  const lines: string[] = [];
  lines.push("Replay summary:");
  lines.push(`  toolCalls           : ${s.toolCalls}`);
  lines.push(`  subagentInvocations : ${s.subagentInvocations}`);
  lines.push(`  hookOutputs         : ${s.hookOutputs}`);
  lines.push(`  fileWrites          : ${s.fileWrites}`);
  lines.push(`  beadsTasksCreated   : ${s.beadsTasksCreated}`);
  lines.push(`  pluginErrors        : ${s.pluginErrors}`);
  lines.push(
    `  pluginsLoaded       : [${s.pluginsLoaded.join(", ") || "<none>"}]`,
  );
  lines.push("  toolCounts          :");
  const sortedTools = Object.entries(s.toolCounts).sort(
    (a, b) => b[1] - a[1] || a[0].localeCompare(b[0]),
  );
  for (const [name, count] of sortedTools) {
    lines.push(`    - ${name.padEnd(28)} ${count}`);
  }
  if (s.agentDelegations.length > 0) {
    lines.push("  agentDelegations    :");
    for (const d of s.agentDelegations) {
      const ty = d.subagentType ? ` (subagent_type=${d.subagentType})` : "";
      const desc =
        d.description.length > 80
          ? `${d.description.slice(0, 77)}...`
          : d.description;
      lines.push(`    - ${d.name}${ty}: ${desc}`);
    }
  }
  return lines.join("\n");
}

/**
 * Read the replay JSONL. The replay format the harness writes is "one
 * Trace as a single JSON object on a single line" — but we tolerate
 * whitespace/newlines so a hand-edited replay still round-trips.
 *
 * Why we don't just `JSON.parse(readFileSync(...))`: the file extension
 * is `.jsonl` and a future replay format may grow sidecar lines (events,
 * raw SDK messages) without a schema bump. Reading the FIRST non-empty
 * line keeps the reader tolerant; if that line ever stops being the
 * Trace itself, the parse will fail loudly and we'll know to revisit.
 */
function readReplayTrace(replayPath: string): Trace {
  if (!existsSync(replayPath)) {
    process.stderr.write(
      `promoteReplay: replay not found at ${replayPath}\n`,
    );
    process.exit(3);
  }
  const raw = readFileSync(replayPath, "utf8");
  const trimmed = raw.trim();
  if (!trimmed) {
    process.stderr.write(`promoteReplay: replay file is empty: ${replayPath}\n`);
    process.exit(3);
  }
  let firstObj: unknown;
  try {
    // First, try parsing the whole file as a single JSON value (matches
    // what runFixture writes today: one big object with embedded
    // newlines disallowed).
    firstObj = JSON.parse(trimmed);
  } catch {
    // Fallback: take the first non-empty line and try to parse that.
    // Lets us tolerate forward-compat sidecar lines without breaking.
    const firstLine = trimmed.split("\n").find((l) => l.trim().length > 0);
    if (!firstLine) {
      process.stderr.write(
        `promoteReplay: replay file has no JSON content: ${replayPath}\n`,
      );
      process.exit(1);
    }
    try {
      firstObj = JSON.parse(firstLine);
    } catch (err) {
      process.stderr.write(
        `promoteReplay: failed to parse replay as JSON (${(err as Error).message}): ${replayPath}\n`,
      );
      process.exit(1);
    }
  }
  // Validate against the schema so we catch shape drift early. Letting
  // an invalid replay slip into a golden would mean every subsequent
  // live run "drifts" against bad data, which is worse than failing
  // here.
  try {
    return TraceSchema.parse(firstObj);
  } catch (err) {
    process.stderr.write(
      `promoteReplay: replay does not validate against TraceSchema:\n${(err as Error).message}\n`,
    );
    process.exit(1);
  }
}

/**
 * Write the golden cassette using the same 2-line format as
 * compareToGolden uses. Header line carries metadata for human
 * inspection (cassetteSchemaVersion, fixture, modelSnapshot, recordedAt,
 * promotedFrom = the replay source). Body line is the pretty-printed
 * normalized trace.
 */
function writeGolden(goldenPath: string, trace: Trace, replayPath: string): void {
  const normalized = normalizeTrace(trace);
  const goldenDir = path.dirname(goldenPath);
  if (!existsSync(goldenDir)) mkdirSync(goldenDir, { recursive: true });
  const metadata = {
    cassetteSchemaVersion: 1,
    fixture: normalized.fixture,
    modelSnapshot: normalized.modelSnapshot,
    recordedAt: new Date().toISOString(),
    promotedFrom: path.relative(path.dirname(goldenDir), replayPath),
    note:
      "Promoted from a captured replay via lib/promoteReplay.ts. " +
      "Edits to this file should be reviewed in PR diffs. To refresh: " +
      "delete this file and rerun the live spec with RECORD_GOLDEN=1, " +
      "or run promoteReplay against a newer replay.",
  };
  const body =
    JSON.stringify(metadata) +
    "\n" +
    JSON.stringify(normalized, null, 2) +
    "\n";
  writeFileSync(goldenPath, body, "utf8");
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  const __dirname = path.dirname(fileURLToPath(import.meta.url));
  const e2eRoot = path.resolve(__dirname, "..");
  const replayPath = path.isAbsolute(args.replay)
    ? args.replay
    : path.resolve(e2eRoot, args.replay);
  const goldenPath =
    args.out ??
    path.resolve(e2eRoot, "cassettes", "golden", `${args.fixture}.jsonl`);

  process.stderr.write(`promoteReplay: reading replay  ${replayPath}\n`);
  const trace = readReplayTrace(replayPath);
  const summary = summarizeTrace(trace);

  process.stderr.write(`promoteReplay: schema validation OK\n`);
  process.stdout.write(formatSummary(summary) + "\n");

  if (args.validateOnly) {
    process.stderr.write(
      `promoteReplay: --validate-only set; not writing golden.\n`,
    );
    return;
  }

  if (existsSync(goldenPath) && !args.force) {
    process.stderr.write(
      `promoteReplay: golden already exists at ${goldenPath}.\n` +
        "  Pass --force to overwrite, or delete the existing file and re-run.\n",
    );
    process.exit(2);
  }

  writeGolden(goldenPath, trace, replayPath);
  process.stderr.write(`promoteReplay: wrote golden  ${goldenPath}\n`);
}

// Only run when invoked as a script. Importing this file (e.g. for
// unit tests of summarizeTrace) should not trigger main().
const __filename = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  main();
}

// Public exports for testability.
export { parseArgs, summarizeTrace, formatSummary };

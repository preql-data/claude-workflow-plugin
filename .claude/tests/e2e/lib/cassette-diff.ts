/**
 * cassette-diff.ts — structural diff between a replay and a golden cassette,
 * rendered as human-readable Markdown for PR comments.
 *
 * Phase E (G8). The L3-live CI job runs the e2e harness against real
 * Claude. Each run drops a full (un-normalized) `Trace` to
 * `cassettes/replays/<fixture>-<ISO>.jsonl`. Goldens live at
 * `cassettes/golden/<fixture>.jsonl` and store a `NormalizedTrace`
 * (alongside a metadata header line — see goldenCompare.ts for the
 * format).
 *
 * Vitest's `compareToGolden` already gives us the diff list at run
 * time, but the CI bot needs:
 *   1. A standalone CLI it can invoke after the run.
 *   2. A Markdown rendering suitable for `gh pr comment`.
 *   3. The ability to read a replay file directly (no Vitest dep).
 *
 * That's what this module does. It does NOT re-implement the diff —
 * it imports `normalizeTrace` and `diffNormalized` semantics from the
 * production goldenCompare path so structural drift detection stays in
 * one place. The only thing duplicated is the array-diff helper, which
 * is private to `goldenCompare.ts`; we re-derive an equivalent here so
 * the Markdown renderer can split per-field for readability.
 *
 * Usage:
 *   npm run cassette-diff -- --replay <path> --golden <path> [--out <md>]
 *
 * Exit codes:
 *   0 — no structural drift (cassettes match)
 *   1 — drift detected (full report on stdout or in --out)
 *   2 — invocation error (missing files, malformed JSON)
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

import {
  normalizeTrace,
  type NormalizedTrace,
} from "./goldenCompare.js";
import { TraceSchema, type Trace } from "./trace.js";

// ---------------------------------------------------------------------------
// Loaders
// ---------------------------------------------------------------------------

/**
 * Read a replay cassette. Replay files are emitted by `runFixture` as a
 * single line of `JSON.stringify(trace)` (see writeTraceDump in
 * runFixture.ts) — i.e. an un-normalized Trace. We parse via the Zod
 * schema so structural shape problems surface here, not deep in a diff.
 */
export function loadReplay(replayPath: string): Trace {
  if (!existsSync(replayPath)) {
    throw new Error(`cassette-diff: replay not found at ${replayPath}`);
  }
  const raw = readFileSync(replayPath, "utf8").trim();
  if (!raw) {
    throw new Error(`cassette-diff: replay file is empty: ${replayPath}`);
  }
  // Replays are single-line JSON; we accept multi-line tolerantly (in
  // case a future format prepends a metadata header).
  const lines = raw.split("\n").filter((l) => l.trim().length > 0);
  // Prefer the last line as the trace body so an optional header
  // doesn't break us. For single-line replays this is the only line.
  const traceLine = lines[lines.length - 1]!;
  let parsed: unknown;
  try {
    parsed = JSON.parse(traceLine);
  } catch (err) {
    throw new Error(
      `cassette-diff: replay JSON is malformed at ${replayPath}: ${(err as Error).message}`,
    );
  }
  // Zod validation is forgiving on optional fields but strict on the
  // schemaVersion + result shape — useful for spotting corrupted files.
  const safe = TraceSchema.safeParse(parsed);
  if (!safe.success) {
    throw new Error(
      `cassette-diff: replay does not match TraceSchema at ${replayPath}: ${safe.error.message}`,
    );
  }
  return safe.data;
}

/**
 * Read a golden cassette. Goldens are `<metadata-header>\n<normalized-trace>`
 * with the trace pretty-printed across multiple lines (see
 * goldenCompare.ts → `serializeNormalized`). We accept a single-line
 * cassette too so the format can be downsized in the future.
 */
export function loadGolden(goldenPath: string): NormalizedTrace {
  if (!existsSync(goldenPath)) {
    throw new Error(`cassette-diff: golden not found at ${goldenPath}`);
  }
  const raw = readFileSync(goldenPath, "utf8").trim();
  if (!raw) {
    throw new Error(`cassette-diff: golden file is empty: ${goldenPath}`);
  }
  // Detect the two-line vs one-line shape: if the first character is
  // `{` AND the line ends with `}` AND there's a second line that ALSO
  // starts with `{`, the format is header+body. Otherwise treat the
  // whole file as a single JSON document.
  const lines = raw.split("\n");
  let body: string;
  if (lines.length >= 2 && lines[0]!.trim().endsWith("}") && lines[1]!.trim().startsWith("{")) {
    body = lines.slice(1).join("\n").trim();
  } else {
    body = raw;
  }
  try {
    return JSON.parse(body) as NormalizedTrace;
  } catch (err) {
    throw new Error(
      `cassette-diff: golden JSON is malformed at ${goldenPath}: ${(err as Error).message}`,
    );
  }
}

// ---------------------------------------------------------------------------
// Diff
// ---------------------------------------------------------------------------

export interface FieldDiff {
  field: string;
  /** Type of drift. "length" = array length changed; "value" = one or
   *  more elements at the same index differ; "scalar" = a scalar field
   *  changed. */
  kind: "length" | "value" | "scalar";
  /** A small set of per-index entries when kind === "value" (capped at
   *  20 so the PR comment doesn't grow unbounded). */
  entries?: Array<{ index: number; golden: string; replay: string }>;
  /** Summary string for kind === "length" or "scalar". */
  summary?: string;
}

export interface CassetteDiff {
  /** True iff every checked field matches. */
  match: boolean;
  /** Path to the replay (raw Trace) we compared. */
  replayPath: string;
  /** Path to the golden (NormalizedTrace) we compared. */
  goldenPath: string;
  /** Field-level diff entries (empty when `match` is true). */
  fields: FieldDiff[];
  /** The normalized actual trace (the replay run through `normalizeTrace`). */
  normalizedReplay: NormalizedTrace;
  /** The golden — kept for context in the rendered report. */
  golden: NormalizedTrace;
}

const MAX_ENTRIES_PER_FIELD = 20;

function diffArrayField(
  field: string,
  replayArr: readonly string[],
  goldenArr: readonly string[],
): FieldDiff | null {
  if (replayArr.length !== goldenArr.length) {
    return {
      field,
      kind: "length",
      summary: `length differs (golden=${goldenArr.length} replay=${replayArr.length})`,
    };
  }
  const entries: FieldDiff["entries"] = [];
  for (let i = 0; i < replayArr.length; i++) {
    if (replayArr[i] !== goldenArr[i]) {
      if (entries.length < MAX_ENTRIES_PER_FIELD) {
        entries.push({
          index: i,
          golden: String(goldenArr[i]),
          replay: String(replayArr[i]),
        });
      }
    }
  }
  if (entries.length === 0) return null;
  return { field, kind: "value", entries };
}

/**
 * Produce a structural diff. Pure function; takes already-loaded inputs
 * so it's easy to unit-test without filesystem fixtures.
 */
export function diffNormalized(
  replay: NormalizedTrace,
  golden: NormalizedTrace,
  replayPath: string,
  goldenPath: string,
): CassetteDiff {
  const fields: FieldDiff[] = [];

  if (replay.modelSnapshot !== golden.modelSnapshot) {
    fields.push({
      field: "modelSnapshot",
      kind: "scalar",
      summary: `golden=${golden.modelSnapshot} replay=${replay.modelSnapshot}`,
    });
  }
  if (replay.fixture !== golden.fixture) {
    fields.push({
      field: "fixture",
      kind: "scalar",
      summary: `golden=${golden.fixture} replay=${replay.fixture}`,
    });
  }

  const arrayFields: Array<[string, readonly string[], readonly string[]]> = [
    ["toolSequence", replay.toolSequence, golden.toolSequence],
    ["subagentTree", replay.subagentTree, golden.subagentTree],
    ["hookSequence", replay.hookSequence, golden.hookSequence],
    ["fileWrites", replay.fileWrites, golden.fileWrites],
    ["beadsTasksCreated", replay.beadsTasksCreated, golden.beadsTasksCreated],
    ["beadsLabelTransitions", replay.beadsLabelTransitions, golden.beadsLabelTransitions],
    ["pluginsLoaded", replay.pluginsLoaded, golden.pluginsLoaded],
    ["pluginErrors", replay.pluginErrors, golden.pluginErrors],
  ];
  for (const [name, r, g] of arrayFields) {
    const d = diffArrayField(name, r, g);
    if (d) fields.push(d);
  }

  // Permission denials are stored as {tool, count}; compare per-tool.
  const goldenDenialMap = new Map(
    golden.permissionDenials.map((d) => [d.tool, d.count]),
  );
  const replayDenialMap = new Map(
    replay.permissionDenials.map((d) => [d.tool, d.count]),
  );
  const allTools = new Set<string>([
    ...goldenDenialMap.keys(),
    ...replayDenialMap.keys(),
  ]);
  for (const tool of allTools) {
    const g = goldenDenialMap.get(tool) ?? 0;
    const r = replayDenialMap.get(tool) ?? 0;
    if (g !== r) {
      fields.push({
        field: `permissionDenials[${tool}]`,
        kind: "scalar",
        summary: `golden=${g} replay=${r}`,
      });
    }
  }

  return {
    match: fields.length === 0,
    replayPath,
    goldenPath,
    fields,
    normalizedReplay: replay,
    golden,
  };
}

/**
 * Full pipeline: load files, normalize, diff. Throws on unloadable input
 * (exit code 2 territory); returns a `CassetteDiff` whose `.match` field
 * tells the caller whether to exit 0 or 1.
 */
export function compareCassettes(
  replayPath: string,
  goldenPath: string,
): CassetteDiff {
  const replay = loadReplay(replayPath);
  const golden = loadGolden(goldenPath);
  const normalizedReplay = normalizeTrace(replay);
  return diffNormalized(normalizedReplay, golden, replayPath, goldenPath);
}

// ---------------------------------------------------------------------------
// Markdown rendering
// ---------------------------------------------------------------------------

/**
 * Render a `CassetteDiff` as Markdown suitable for a GitHub PR comment.
 *
 * Layout (no-drift case):
 *   ### Cassette diff — node-react-auth
 *   Replay matches golden. No structural drift.
 *
 * Drift case includes a header, the file paths, a count of mismatched
 * fields, and a per-field diff block (length / scalar / value).
 *
 * The `replay - golden` framing keeps PR-comment polarity intuitive:
 * "this PR's run produced X; the committed golden was Y".
 */
export function renderMarkdown(diff: CassetteDiff): string {
  const fixture = diff.normalizedReplay.fixture;
  const replayName = path.basename(diff.replayPath);
  const goldenName = path.basename(diff.goldenPath);

  if (diff.match) {
    return [
      `### Cassette diff — ${fixture}`,
      ``,
      `Replay matches golden. No structural drift.`,
      ``,
      `- Replay: \`${replayName}\``,
      `- Golden: \`${goldenName}\``,
    ].join("\n");
  }

  const out: string[] = [];
  out.push(`### Cassette diff — ${fixture} (drift detected)`);
  out.push(``);
  out.push(`Replay: \`${replayName}\``);
  out.push(`Golden: \`${goldenName}\``);
  out.push(``);
  out.push(`${diff.fields.length} field(s) drifted:`);
  out.push(``);

  for (const f of diff.fields) {
    out.push(`#### \`${f.field}\``);
    if (f.kind === "length" || f.kind === "scalar") {
      out.push(``);
      out.push(`- ${f.summary ?? "(no detail)"}`);
      out.push(``);
      // For length diffs on long arrays, the raw arrays would explode
      // the comment. We omit them; reviewers should rerun locally and
      // inspect via `compareToGolden`.
    } else {
      // value diff
      out.push(``);
      out.push(`| index | golden | replay |`);
      out.push(`|---|---|---|`);
      for (const e of f.entries ?? []) {
        const goldenCell = escapeCell(e.golden);
        const replayCell = escapeCell(e.replay);
        out.push(`| ${e.index} | \`${goldenCell}\` | \`${replayCell}\` |`);
      }
      if ((f.entries?.length ?? 0) === MAX_ENTRIES_PER_FIELD) {
        out.push(``);
        out.push(
          `_(showing first ${MAX_ENTRIES_PER_FIELD} differing entries; more may exist)_`,
        );
      }
      out.push(``);
    }
  }

  out.push(`---`);
  out.push(``);
  out.push(
    `If this drift is intentional (model/prompt/plugin change), refresh the cassette:`,
  );
  out.push(``);
  out.push(`\`\`\``);
  out.push(`rm ${diff.goldenPath}`);
  out.push(`make test-e2e-record`);
  out.push(`\`\`\``);

  return out.join("\n");
}

function escapeCell(value: string): string {
  // Markdown table cells: pipes and backticks. We replace `|` with
  // its HTML entity; backticks become repeated to escape inline-code
  // closure within a cell.
  return value.replace(/\|/g, "\\|").replace(/`/g, "ˋ");
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

interface CliOptions {
  replay?: string;
  golden?: string;
  out?: string;
  help: boolean;
}

export function parseArgs(argv: readonly string[]): CliOptions {
  const opts: CliOptions = { help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--replay" && i + 1 < argv.length) {
      opts.replay = argv[++i];
    } else if (a === "--golden" && i + 1 < argv.length) {
      opts.golden = argv[++i];
    } else if (a === "--out" && i + 1 < argv.length) {
      opts.out = argv[++i];
    } else if (a === "--help" || a === "-h") {
      opts.help = true;
    }
  }
  return opts;
}

function printHelp(): void {
  process.stdout.write(
    [
      "cassette-diff — structural diff between a replay and a golden cassette",
      "",
      "Usage:",
      "  npm run cassette-diff -- --replay <path> --golden <path> [--out <md>]",
      "",
      "Flags:",
      "  --replay <path>   Replay cassette (single-line JSON Trace).",
      "  --golden <path>   Golden cassette (header + NormalizedTrace).",
      "  --out <path>      Write Markdown to this file. If omitted, prints to stdout.",
      "  --help, -h        Show this help.",
      "",
      "Exit codes: 0 = match, 1 = drift, 2 = invocation error.",
      "",
    ].join("\n"),
  );
}

const isMain =
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith("cassette-diff.ts") ||
  process.argv[1]?.endsWith("cassette-diff.js");

if (isMain) {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    printHelp();
    process.exit(0);
  }
  if (!opts.replay || !opts.golden) {
    process.stderr.write(
      "cassette-diff: --replay and --golden are required (use --help for usage)\n",
    );
    process.exit(2);
  }
  try {
    const diff = compareCassettes(opts.replay, opts.golden);
    const md = renderMarkdown(diff);
    if (opts.out) {
      writeFileSync(opts.out, md + "\n", "utf8");
      process.stderr.write(
        `cassette-diff: report written to ${opts.out} (${diff.match ? "match" : "drift"})\n`,
      );
    } else {
      process.stdout.write(md + "\n");
    }
    process.exit(diff.match ? 0 : 1);
  } catch (err) {
    process.stderr.write(
      `cassette-diff: ${(err as Error).message}\n`,
    );
    process.exit(2);
  }
}

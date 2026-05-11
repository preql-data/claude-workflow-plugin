/**
 * pr-summary.ts — render a Markdown trace summary for a PR comment.
 *
 * Phase E (G8). After a successful L3-live run in CI, the workflow
 * posts a comment to the PR so reviewers can see WHAT the plugin
 * actually did (not just pass/fail). The summary covers:
 *
 *   - Subagent invocation tree (per fixture).
 *   - Hook firing order — count by event type.
 *   - Beads label transitions.
 *   - META-TEST assertion category (separately tallied; structurally
 *     distinct from regular assertions because they prove the test's
 *     own sensitivity, not the SUT's behaviour). META counts are
 *     scraped from the component-tier (`.claude/tests/component/run.sh`)
 *     log output, since META-TESTs are an L2 concept — they don't appear
 *     in the L3 trace.
 *   - Total cost in USD (from `trace.result.totalCostUsd`).
 *
 * Inputs:
 *   --replay <path>     Replay cassette (full Trace as single-line JSON).
 *   --component-log <path>  Optional. Plain-text capture of the L2
 *                       runner's stdout/stderr. We grep this for
 *                       "META-TEST" lines and bucket them as PASS/FAIL.
 *                       Missing/empty → reported as "(not provided)".
 *   --out <path>        Write Markdown to file. Default: stdout.
 *
 * Design note — why scrape rather than parse JSON: the L2 runner is a
 * pure bash test harness whose output is plain text and changing that
 * for the sake of PR summaries would balloon the diff. The grep-based
 * scraper is robust because the META-TEST marker is consistently used
 * in the existing component specs (failure-cross-repo,
 * failure-hook-crash, failure-orchestrator-restriction) — a regression
 * in one of those specs would show up as a FAIL line containing
 * "META-TEST".
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

import { TraceSchema, type Trace } from "./trace.js";

// ---------------------------------------------------------------------------
// Loaders
// ---------------------------------------------------------------------------

/**
 * Load a replay JSONL file (a single un-normalized Trace). Identical to
 * cassette-diff's loader by design — we re-implement instead of importing
 * to keep pr-summary.ts a sibling that can be run standalone without
 * pulling cassette-diff's argv handler.
 */
export function loadReplay(replayPath: string): Trace {
  if (!existsSync(replayPath)) {
    throw new Error(`pr-summary: replay not found at ${replayPath}`);
  }
  const raw = readFileSync(replayPath, "utf8").trim();
  if (!raw) {
    throw new Error(`pr-summary: replay file is empty: ${replayPath}`);
  }
  const lines = raw.split("\n").filter((l) => l.trim().length > 0);
  const traceLine = lines[lines.length - 1]!;
  let parsed: unknown;
  try {
    parsed = JSON.parse(traceLine);
  } catch (err) {
    throw new Error(
      `pr-summary: replay JSON malformed at ${replayPath}: ${(err as Error).message}`,
    );
  }
  const safe = TraceSchema.safeParse(parsed);
  if (!safe.success) {
    throw new Error(
      `pr-summary: replay does not match TraceSchema at ${replayPath}: ${safe.error.message}`,
    );
  }
  return safe.data;
}

// ---------------------------------------------------------------------------
// META-TEST scraping
// ---------------------------------------------------------------------------

export interface MetaTestStats {
  /** Total META-TEST lines found in the log (PASS + FAIL). */
  total: number;
  /** Number with `PASS:` prefix. */
  pass: number;
  /** Number with `FAIL:` prefix. */
  fail: number;
  /** True iff we scanned a log (otherwise the caller didn't pass one). */
  scanned: boolean;
  /** The first 10 FAIL lines verbatim, for the summary. */
  failures: string[];
}

/**
 * Scrape META-TEST PASS/FAIL counts out of an L2 (component-tier)
 * runner log. Heuristic — matches the structure used by
 * `.claude/tests/component/lib/assert.sh`'s helpers and a handful of
 * ad-hoc inline checks in the specs that don't go through the helper.
 *
 * Regex: leading whitespace, "PASS:" or "FAIL:", any space, anything,
 * "META-TEST". Anchored at line-start tolerates indentation from the
 * runner's "=== spec ===" sections.
 */
export function scrapeMetaTests(logText: string): MetaTestStats {
  const stats: MetaTestStats = {
    total: 0,
    pass: 0,
    fail: 0,
    scanned: true,
    failures: [],
  };
  const lines = logText.split("\n");
  const metaRegex = /\b(PASS|FAIL):\s+.*META-TEST/;
  for (const line of lines) {
    const m = line.match(metaRegex);
    if (!m) continue;
    stats.total += 1;
    if (m[1] === "PASS") {
      stats.pass += 1;
    } else {
      stats.fail += 1;
      if (stats.failures.length < 10) {
        stats.failures.push(line.trim());
      }
    }
  }
  return stats;
}

export function scrapeMetaTestsFromFile(
  logPath: string | undefined,
): MetaTestStats {
  if (!logPath) {
    return { total: 0, pass: 0, fail: 0, scanned: false, failures: [] };
  }
  if (!existsSync(logPath)) {
    return { total: 0, pass: 0, fail: 0, scanned: false, failures: [] };
  }
  const text = readFileSync(logPath, "utf8");
  return scrapeMetaTests(text);
}

// ---------------------------------------------------------------------------
// Summary derivation
// ---------------------------------------------------------------------------

export interface SubagentTreeNode {
  type: string;
  toolUseId: string;
  parentToolUseId: string | null;
  children: SubagentTreeNode[];
}

/**
 * Build a parent->children tree of subagent invocations using their
 * `toolUseId` / `parentToolUseId` relationship. The relationship is
 * recorded by `runFixture` from the SDK's chain-tracking field, so the
 * shape reflects "who spawned whom". A node whose parent is not in
 * `subagentInvocations` is a root (i.e. spawned directly by the
 * orchestrator). The roots' parent is normalized to `null` even if the
 * raw trace says otherwise.
 */
export function buildSubagentTree(trace: Trace): SubagentTreeNode[] {
  const nodes = trace.subagentInvocations.map<SubagentTreeNode>((inv) => ({
    type: inv.type,
    toolUseId: inv.toolUseId,
    parentToolUseId: inv.parentToolUseId,
    children: [],
  }));
  const byToolUseId = new Map<string, SubagentTreeNode>();
  for (const n of nodes) byToolUseId.set(n.toolUseId, n);

  const roots: SubagentTreeNode[] = [];
  for (const n of nodes) {
    if (n.parentToolUseId && byToolUseId.has(n.parentToolUseId)) {
      byToolUseId.get(n.parentToolUseId)!.children.push(n);
    } else {
      // Normalize: dangling parent → root.
      n.parentToolUseId = null;
      roots.push(n);
    }
  }
  return roots;
}

function renderTree(nodes: SubagentTreeNode[], depth = 0): string[] {
  const out: string[] = [];
  for (const n of nodes) {
    out.push(`${"  ".repeat(depth)}- @${n.type}`);
    if (n.children.length > 0) {
      out.push(...renderTree(n.children, depth + 1));
    }
  }
  return out;
}

export interface HookEventCounts {
  [event: string]: number;
}

/**
 * Count hook firings by event name. Order is alphabetical so the
 * summary is stable across runs even when the SDK shuffles event order
 * within a single iteration.
 */
export function countHooksByEvent(trace: Trace): HookEventCounts {
  const counts: HookEventCounts = {};
  for (const h of trace.hookOutputs) {
    counts[h.event] = (counts[h.event] ?? 0) + 1;
  }
  return counts;
}

export interface SummaryInputs {
  trace: Trace;
  /** Path to the replay file (for the header). */
  replayPath: string;
  meta: MetaTestStats;
}

// ---------------------------------------------------------------------------
// Markdown rendering
// ---------------------------------------------------------------------------

/**
 * Render the PR summary as Markdown. Sections:
 *   1. Header (fixture + cost).
 *   2. Subagent invocation tree.
 *   3. Hook firing counts.
 *   4. Beads label transitions.
 *   5. META-TEST tally.
 *
 * All sections degrade to a one-liner when the underlying data is
 * empty (e.g. a fixture that doesn't write any Beads labels still
 * gets a clean section header that says so).
 */
export function renderPrSummary(inputs: SummaryInputs): string {
  const { trace, replayPath, meta } = inputs;
  const out: string[] = [];

  // --- 1. Header ---
  out.push(`## E2E trace summary — \`${trace.fixture}\``);
  out.push(``);
  out.push(`- Replay: \`${path.basename(replayPath)}\``);
  out.push(`- Model: \`${trace.modelSnapshot}\``);
  const cost = trace.result?.totalCostUsd ?? 0;
  if (cost > 0) {
    out.push(`- Total cost: \`$${cost.toFixed(4)} USD\``);
  } else {
    out.push(`- Total cost: \`(not reported)\``);
  }
  out.push(
    `- Turns: \`${trace.result?.turns ?? 0}\` · Tokens: \`${
      (trace.result?.inputTokens ?? 0) + (trace.result?.outputTokens ?? 0)
    }\``,
  );
  out.push(``);

  // --- 2. Subagent tree ---
  out.push(`### Subagent invocation tree`);
  out.push(``);
  const roots = buildSubagentTree(trace);
  if (roots.length === 0) {
    out.push(`_No subagent invocations recorded._`);
  } else {
    out.push(...renderTree(roots));
  }
  out.push(``);

  // --- 3. Hook firing ---
  out.push(`### Hook firing (by event)`);
  out.push(``);
  const hookCounts = countHooksByEvent(trace);
  const hookKeys = Object.keys(hookCounts).sort();
  if (hookKeys.length === 0) {
    out.push(`_No hooks fired._`);
  } else {
    out.push(`| Event | Count |`);
    out.push(`|---|---|`);
    for (const k of hookKeys) {
      out.push(`| \`${k}\` | ${hookCounts[k]} |`);
    }
  }
  out.push(``);

  // --- 4. Beads label transitions ---
  out.push(`### Beads label transitions`);
  out.push(``);
  if (trace.beadsLabelTransitions.length === 0) {
    out.push(`_No label transitions recorded._`);
  } else {
    out.push(`| Task | Added | Removed |`);
    out.push(`|---|---|---|`);
    for (const t of trace.beadsLabelTransitions) {
      const added = (t.added ?? []).map((l) => `\`${l}\``).join(" ") || "—";
      const removed = (t.removed ?? []).map((l) => `\`${l}\``).join(" ") || "—";
      out.push(`| \`${t.taskId}\` | ${added} | ${removed} |`);
    }
  }
  out.push(``);

  // --- 5. META-TEST tally ---
  out.push(`### META-TEST assertions`);
  out.push(``);
  out.push(
    `_META-TESTs prove the test's own sensitivity — they're structurally distinct from regular assertions (which prove SUT behaviour)._`,
  );
  out.push(``);
  if (!meta.scanned) {
    out.push(`Component-tier log not provided — META-TEST counts unavailable.`);
  } else if (meta.total === 0) {
    out.push(`Component-tier log scanned: no META-TEST assertions found.`);
  } else {
    const allPassed = meta.fail === 0;
    out.push(
      `- Total META-TEST assertions: **${meta.total}**`,
    );
    out.push(`- Passed: **${meta.pass}**`);
    out.push(`- Failed: **${meta.fail}**${allPassed ? "" : " (regression-injection sensitivity broken!)"}`);
    if (meta.failures.length > 0) {
      out.push(``);
      out.push(`First failure(s):`);
      for (const f of meta.failures) {
        out.push(`- \`${f.replace(/`/g, "ˋ")}\``);
      }
    }
  }

  return out.join("\n");
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

interface CliOptions {
  replay?: string;
  componentLog?: string;
  out?: string;
  help: boolean;
}

export function parseArgs(argv: readonly string[]): CliOptions {
  const opts: CliOptions = { help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--replay" && i + 1 < argv.length) {
      opts.replay = argv[++i];
    } else if (a === "--component-log" && i + 1 < argv.length) {
      opts.componentLog = argv[++i];
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
      "pr-summary — render an E2E trace summary as Markdown",
      "",
      "Usage:",
      "  npm run pr-summary -- --replay <path> [--component-log <path>] [--out <md>]",
      "",
      "Flags:",
      "  --replay <path>           Replay JSONL produced by the e2e harness.",
      "  --component-log <path>    Plain-text log from `make test-component`. Used to",
      "                            scrape META-TEST PASS/FAIL counts. Optional.",
      "  --out <path>              Write Markdown to file. Default: stdout.",
      "  --help, -h                Show this help.",
      "",
      "Exit codes: 0 = success, 2 = invocation error.",
      "",
    ].join("\n"),
  );
}

const isMain =
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith("pr-summary.ts") ||
  process.argv[1]?.endsWith("pr-summary.js");

if (isMain) {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    printHelp();
    process.exit(0);
  }
  if (!opts.replay) {
    process.stderr.write(
      "pr-summary: --replay is required (use --help for usage)\n",
    );
    process.exit(2);
  }
  try {
    const trace = loadReplay(opts.replay);
    const meta = scrapeMetaTestsFromFile(opts.componentLog);
    const md = renderPrSummary({ trace, replayPath: opts.replay, meta });
    if (opts.out) {
      writeFileSync(opts.out, md + "\n", "utf8");
      process.stderr.write(`pr-summary: report written to ${opts.out}\n`);
    } else {
      process.stdout.write(md + "\n");
    }
    process.exit(0);
  } catch (err) {
    process.stderr.write(
      `pr-summary: ${(err as Error).message}\n`,
    );
    process.exit(2);
  }
}

/**
 * beadsCapture — read, flush, and diff a fixture's `.beads/issues.jsonl`.
 *
 * The L3 harness (`runFixture`) captures `beadsTasksCreated` /
 * `beadsLabelTransitions` by diffing `.beads/issues.jsonl` pre- and
 * post-run. That file is only written when bd "exports" the SQLite DB
 * to JSONL. There are two paths bd can take for any CRUD:
 *
 *   1. Direct (BD_NO_DAEMON=1 or --no-daemon): writes SQLite, then
 *      auto-flushes JSONL synchronously. Usually fine for our capture.
 *   2. Daemon path: writes SQLite, ENQUEUES a flush, returns immediately.
 *      The daemon polls (default 5s interval) and exports JSONL
 *      eventually. Reading issues.jsonl right after a create lands BEFORE
 *      the daemon's next tick — `readBeadsIssues` returns stale data
 *      and the diff is empty.
 *
 * Live evidence: the rubric-revision-loop trace at 2026-06-11T21-45-00-465Z
 * had three bd-create operations (two via MCP `bd_create_task` + one bash
 * `BD_NO_DAEMON=1 bd create`) yet `beadsTasksCreated` was empty. The MCP
 * server (.claude/mcp/bd-mcp/src/lib/exec-bd.js) does NOT pass
 * `--no-daemon`, so its writes are subject to the race. See Beads task
 * claude-workflow-plugin-l1r.7 for the offline repro that confirms it.
 *
 * The fix is to export the fixture's .beads/ to JSONL before BOTH the
 * pre-run snapshot and the post-run diff. That was `bd sync --flush-only`
 * until bd 1.1.2 removed `bd sync`; it is now `bd export -o
 * .beads/issues.jsonl`, which rewrites the target from the DB on every
 * supported bd and performs no git operations — exactly what a hermetic
 * flush needs. `BD_NO_DAEMON=1` is still passed: inert on 1.1.x (no daemon
 * exists) and still meaningful on 0.47.x.
 *
 * The flush is best-effort: if bd isn't installed, or the .beads/ isn't
 * initialised yet, we log and proceed. Capture stays best-effort — specs
 * carry an OR-shape fallback (`harness diff OR MCP bd_create_task OR
 * Bash bd create`) to keep the workflow assertions robust regardless.
 */
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

export interface BeadsIssue {
  id: string;
  labels: string[];
}

export interface BeadsDiff {
  created: string[];
  transitions: Array<{ taskId: string; added: string[]; removed: string[] }>;
}

/**
 * Read the fixture's .beads/issues.jsonl into a map keyed by id. Tolerant
 * of a missing file (returns empty map) and corrupt lines (skips them).
 *
 * Tracked-by-id, not by line position, because bd rewrites issues.jsonl
 * on every flush and ordering is not stable.
 */
export function readBeadsIssues(fixturePath: string): Map<string, BeadsIssue> {
  const issuesPath = path.join(fixturePath, ".beads", "issues.jsonl");
  const result = new Map<string, BeadsIssue>();
  if (!existsSync(issuesPath)) return result;
  const raw = readFileSync(issuesPath, "utf8");
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const parsed = JSON.parse(trimmed);
      if (parsed && typeof parsed.id === "string") {
        result.set(parsed.id, {
          id: parsed.id,
          labels: Array.isArray(parsed.labels) ? [...parsed.labels] : [],
        });
      }
    } catch {
      // Tolerate corrupt lines — beads occasionally produces them mid-write
      // and the cleanup pass repairs them. Skipping is safe here.
    }
  }
  return result;
}

/**
 * Read the fixture's bd COMMENT stream out of `.beads/issues.jsonl`
 * (v4.0.0 Phase V3 / claude-workflow-plugin-jio.2).
 *
 * WHY: the gate's audit records — `QA-GATE APPROVED … reviewed_by=<id>`,
 * `REVIEW-ARTIFACT v1 …`, `IMPLEMENTER: role=<role>`, `RESOLVED <id> …`,
 * `ARBITRATION <id> decision=<d>` — live in comments, not labels. The
 * `approval-cites-independent-review` invariant replays them; without
 * this capture it has nothing to read and skips.
 *
 * SAME CHANNEL AS `readBeadsIssues`: the JSONL export, which the caller
 * has already flushed via `flushFixtureBeads`. No extra bd invocation, no
 * new failure mode — if the flush was stale the labels are stale too, and
 * both degrade together (visibly).
 *
 * ORDERING: bd assigns each comment a globally-increasing integer id, so
 * when every captured row has a numeric id we sort by it — that is the
 * DB's own insertion order, and it is exactly the order the gate wrote
 * the records in. Only when an id is missing/non-numeric (a bd version
 * that omits it) do we fall back to `created_at` (parsed, so mixed
 * `Z`/offset forms compare correctly) with the file order as the final
 * tie-break. The returned `order` field is a dense 0-based rank, NOT the
 * bd id — consumers compare ranks, never arithmetic on them.
 *
 * Tolerant of everything `readBeadsIssues` is: missing file, corrupt
 * lines, issues with no `comments` array, comment rows that aren't
 * objects. A capture problem must degrade to "fewer comments" (the
 * invariant then reports what it can see), never to a throw inside the
 * post-run capture block.
 */
export function readBeadsComments(
  fixturePath: string,
): Array<{ task: string; text: string; order: number }> {
  const issuesPath = path.join(fixturePath, ".beads", "issues.jsonl");
  if (!existsSync(issuesPath)) return [];
  let raw: string;
  try {
    raw = readFileSync(issuesPath, "utf8");
  } catch {
    return [];
  }

  const rows: Array<{
    task: string;
    text: string;
    id: number | null;
    at: number | null;
    seen: number;
  }> = [];
  let seen = 0;
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      continue; // same tolerance as readBeadsIssues
    }
    const issue = parsed as { id?: unknown; comments?: unknown };
    if (!issue || typeof issue.id !== "string") continue;
    if (!Array.isArray(issue.comments)) continue;
    for (const c of issue.comments) {
      if (!c || typeof c !== "object") continue;
      const row = c as { id?: unknown; text?: unknown; created_at?: unknown };
      if (typeof row.text !== "string") continue;
      const numericId =
        typeof row.id === "number" && Number.isFinite(row.id)
          ? row.id
          : typeof row.id === "string" && /^[0-9]+$/.test(row.id)
            ? Number(row.id)
            : null;
      const parsedAt =
        typeof row.created_at === "string" ? Date.parse(row.created_at) : NaN;
      rows.push({
        task: issue.id,
        text: row.text,
        id: numericId,
        at: Number.isFinite(parsedAt) ? parsedAt : null,
        seen: seen++,
      });
    }
  }

  const everyRowHasId = rows.every((r) => r.id !== null);
  rows.sort((a, b) => {
    if (everyRowHasId) return (a.id as number) - (b.id as number) || a.seen - b.seen;
    const at = a.at ?? 0;
    const bt = b.at ?? 0;
    if (at !== bt) return at - bt;
    return a.seen - b.seen;
  });

  return rows.map((r, i) => ({ task: r.task, text: r.text, order: i }));
}

/**
 * Compute the diff between pre- and post-run beads state.
 *
 * "Created": present in `after`, absent in `before`. Carries the full
 * post labels for any created task as a transition row so the trace
 * has structural evidence of what labels were applied at creation
 * time (e.g. `qa-pending`).
 *
 * "Transitions": present in both, but the label set changed.
 */
export function diffBeadsIssues(
  before: Map<string, BeadsIssue>,
  after: Map<string, BeadsIssue>,
): BeadsDiff {
  const created: string[] = [];
  const transitions: Array<{
    taskId: string;
    added: string[];
    removed: string[];
  }> = [];

  for (const [id, post] of after.entries()) {
    const pre = before.get(id);
    if (!pre) {
      created.push(id);
      if (post.labels.length > 0) {
        transitions.push({ taskId: id, added: [...post.labels], removed: [] });
      }
      continue;
    }
    const preSet = new Set(pre.labels);
    const postSet = new Set(post.labels);
    const added = [...postSet].filter((l) => !preSet.has(l));
    const removed = [...preSet].filter((l) => !postSet.has(l));
    if (added.length > 0 || removed.length > 0) {
      transitions.push({ taskId: id, added, removed });
    }
  }
  return { created, transitions };
}

/**
 * Result of an attempted beads flush. `ok` mirrors `spawnSync` exit-zero;
 * when `ok` is false the caller should treat the diff as best-effort and
 * fall through to the OR-shape spec assertion.
 */
export interface FlushResult {
  ok: boolean;
  status: number | null;
  stderrTail: string;
  /** True when `.beads/` is missing entirely (a fixture that has not
   *  yet run `bd init` — the flush is a no-op and `ok` is true). */
  noBeadsDir: boolean;
  /** True when the `bd` binary couldn't be located. Caller should warn
   *  but not fail the run — capture stays best-effort. */
  bdMissing: boolean;
}

/**
 * Flush the fixture's beads DB to `.beads/issues.jsonl` synchronously.
 *
 * Uses `bd export -o .beads/issues.jsonl` — one unconditional call that
 * rewrites the ledger from the DB on both bd 0.47.x and 1.1.2. Runs from
 * `fixturePath` as cwd, so bd auto-discovers the FIXTURE's `.beads/` (and
 * not the harness's parent project's `.beads/`).
 *
 * Tolerant of:
 *   - Missing `.beads/` directory (fixture before `bd init`) → no-op.
 *   - `bd` binary not on PATH (rare; CI runners that haven't installed
 *     the Beads CLI) → logs a warning and returns `bdMissing:true`.
 *   - Non-zero exit (corrupt DB, lock contention, etc.) → returns the
 *     stderr tail for diagnostics. Caller logs and proceeds.
 *
 * Why best-effort: capture is a diagnostic aid, not a correctness gate.
 * Spec assertions carry an OR-shape so a flush failure doesn't fail a
 * spec that has structural evidence from toolCalls.
 */
export function flushFixtureBeads(
  fixturePath: string,
  opts: { bdBin?: string; timeoutMs?: number } = {},
): FlushResult {
  const beadsDir = path.join(fixturePath, ".beads");
  if (!existsSync(beadsDir)) {
    return { ok: true, status: 0, stderrTail: "", noBeadsDir: true, bdMissing: false };
  }
  // Prefer the fixture's own `bd` shim if present — it carries
  // workspace-specific quirks (e.g. the 0.47.1 --no-daemon wrapper at
  // .claude/bin/bd). Fall back to plain `bd` on PATH.
  const shimPath = path.join(fixturePath, ".claude", "bin", "bd");
  const bd = opts.bdBin ?? (existsSync(shimPath) ? shimPath : "bd");

  const issuesJsonl = path.join(beadsDir, "issues.jsonl");
  const timeoutMs = opts.timeoutMs ?? 15_000;
  // BD_NO_DAEMON is inert on bd 1.1.x (there is no daemon — the engine is
  // in-process embedded Dolt) but still correct on 0.47.x, where the daemon
  // could enqueue the flush instead of performing it. An unknown env var is
  // ignored, unlike an unknown FLAG, so keeping it costs nothing.
  const env = { ...process.env, BD_NO_DAEMON: "1" };

  // ONE authoritative call: `bd export -o <file>` (fkm.1.1).
  //
  // This used to be a two-step dance — `bd sync --flush-only` first, then
  // `bd export --force -o` only when issues.jsonl was still ABSENT. bd 1.1.2
  // broke both halves and the guard between them:
  //
  //   - `bd sync` was REMOVED outright, so step 1 always failed.
  //   - `--force` was REMOVED, so the step-2 fallback always failed too.
  //   - Worse, step 2 only fired when the file was MISSING. Under 1.1.2 the
  //     common shape is a ledger that exists but is STALE, so the fallback
  //     never ran and the harness captured a stale ledger while reporting
  //     success — a fresh instance of the very 366.5 bug the fallback was
  //     added to fix.
  //
  // Plain `bd export -o` is the right primitive on BOTH supported versions,
  // and this was measured rather than assumed: on 0.47.1 it recreates a
  // deleted target AND picks up a subsequently-created issue, so the hash
  // short-circuit that motivated `--force` belonged to `sync --flush-only`,
  // not to `export`. Unconditional means no guard can go stale again.
  const exportResult = spawnSync(bd, ["export", "-o", issuesJsonl], {
    cwd: fixturePath,
    encoding: "utf8",
    timeout: timeoutMs,
    env,
  });

  // ENOENT — bd binary not found. Common on CI runners without Beads
  // installed; capture is best-effort so we log via the returned struct
  // rather than throwing.
  if (
    exportResult.error &&
    (exportResult.error as NodeJS.ErrnoException).code === "ENOENT"
  ) {
    return {
      ok: false,
      status: null,
      stderrTail: `bd binary not found at ${bd}`,
      noBeadsDir: false,
      bdMissing: true,
    };
  }

  const exportStderr = exportResult.stderr ?? "";
  const exportStderrTail =
    exportStderr.length > 500 ? exportStderr.slice(-500) : exportStderr;
  // ok requires BOTH a zero exit and the file existing afterwards — the
  // "exit 0 but wrote nothing" edge case is exactly what 366.5 was.
  return {
    ok: exportResult.status === 0 && existsSync(issuesJsonl),
    status: exportResult.status,
    stderrTail: exportStderrTail,
    noBeadsDir: false,
    bdMissing: false,
  };
}

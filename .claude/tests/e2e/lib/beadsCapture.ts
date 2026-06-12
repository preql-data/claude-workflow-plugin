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
 * The fix is to call `bd sync --flush-only` against the fixture's .beads/
 * before BOTH the pre-run snapshot and the post-run diff. `--flush-only`
 * exports pending JSONL without any git operations — exactly what we
 * want for a hermetic flush. We pass `BD_NO_DAEMON=1` so the flush
 * itself is unambiguous (it never gets enqueued on the daemon).
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
 * Uses `bd sync --flush-only` (--help: "Only export pending changes to
 * JSONL (skip git operations)") with `BD_NO_DAEMON=1` so the flush
 * itself never gets enqueued on the daemon. Runs from `fixturePath` as
 * cwd, so bd auto-discovers the FIXTURE's `.beads/` (and not the
 * harness's parent project's `.beads/`).
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
  const env = { ...process.env, BD_NO_DAEMON: "1" };

  // Step 1: try the cheap `bd sync --flush-only` path first. When bd has
  // pending dirty rows AND issues.jsonl exists with a stale hash, this is
  // the fast path that produces the correct file.
  const flushResult = spawnSync(bd, ["sync", "--flush-only"], {
    cwd: fixturePath,
    encoding: "utf8",
    timeout: timeoutMs,
    env,
  });

  // ENOENT — bd binary not found. Common on CI runners without Beads
  // installed; capture is best-effort so we log via the returned struct
  // rather than throwing.
  if (
    flushResult.error &&
    (flushResult.error as NodeJS.ErrnoException).code === "ENOENT"
  ) {
    return {
      ok: false,
      status: null,
      stderrTail: `bd binary not found at ${bd}`,
      noBeadsDir: false,
      bdMissing: true,
    };
  }

  // Step 2: if issues.jsonl is still absent after the flush, fall back
  // to `bd export --force -o .beads/issues.jsonl`. This is needed
  // because bd 0.47.1's `--flush-only` short-circuits with "JSONL
  // unchanged (hash match)" when the metadata table's
  // jsonl_content_hash matches a SIBLING file (e.g. sync_base.jsonl
  // — the prior run's import baseline, gitignored, survives
  // `git clean -fd`). In that state flush-only exits 0 but writes
  // nothing, leaving readBeadsIssues with an empty map and
  // beadsTasksCreated with an empty diff. The live-trace evidence is
  // .claude/tests/e2e/cassettes/replays/node-react-auth-2026-06-11T23-34-49-784Z.jsonl
  // — see claude-workflow-plugin-366.5 forensic notes.
  //
  // `bd export --force` always rewrites the target from the DB
  // regardless of hash state, so this is the reliable "ensure
  // issues.jsonl reflects DB state" primitive. We only invoke it when
  // the cheap path failed to produce the file — keeping the fast path
  // for the common case where bd's flush did the right thing.
  if (!existsSync(issuesJsonl)) {
    const exportResult = spawnSync(
      bd,
      ["export", "--force", "-o", issuesJsonl],
      {
        cwd: fixturePath,
        encoding: "utf8",
        timeout: timeoutMs,
        env,
      },
    );
    if (
      exportResult.error &&
      (exportResult.error as NodeJS.ErrnoException).code === "ENOENT"
    ) {
      // Shouldn't happen — the flush above would have caught this —
      // but be paranoid.
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
    // The export pass is authoritative — its result is what we return.
    // ok:true requires the export to succeed AND issues.jsonl to exist
    // after it runs (catches the "exit 0 but empty stdout" edge case).
    return {
      ok: exportResult.status === 0 && existsSync(issuesJsonl),
      status: exportResult.status,
      stderrTail: exportStderrTail,
      noBeadsDir: false,
      bdMissing: false,
    };
  }

  // Cheap path succeeded — issues.jsonl is present. Report the original
  // flush result.
  const flushStderr = flushResult.stderr ?? "";
  const flushStderrTail =
    flushStderr.length > 500 ? flushStderr.slice(-500) : flushStderr;
  return {
    ok: flushResult.status === 0,
    status: flushResult.status,
    stderrTail: flushStderrTail,
    noBeadsDir: false,
    bdMissing: false,
  };
}

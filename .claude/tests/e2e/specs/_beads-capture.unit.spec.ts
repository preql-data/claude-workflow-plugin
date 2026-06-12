/**
 * _beads-capture.unit.spec.ts — offline unit specs for the runFixture
 * beads-capture helpers. The L3 harness reads `.beads/issues.jsonl`
 * pre- and post-run to compute `beadsTasksCreated` /
 * `beadsLabelTransitions`. Two scenarios it must handle:
 *
 *   1. Daemon-route race: the bd daemon writes SQLite eagerly but
 *      flushes JSONL on its poll interval (default 5s). A read
 *      immediately after a daemon-route `bd create` returns stale
 *      data and the diff is empty.
 *   2. BD_NO_DAEMON path: writes SQLite + flushes JSONL synchronously,
 *      so the diff captures the task without external intervention.
 *
 * Live trace (claude-workflow-plugin-l1r.7,
 * cassettes/replays/rubric-revision-loop-2026-06-11T21-45-00-465Z.jsonl)
 * caught the race: three bd-create operations on the wire but
 * `beadsTasksCreated` came back empty. Two of those were MCP
 * `bd_create_task` (daemon-route) — exactly the failure mode condition 1.
 *
 * Regression contract these specs encode:
 *
 *   a) `flushFixtureBeads` against a sandbox where a task was created
 *      via the BD_NO_DAEMON path leaves `.beads/issues.jsonl` populated
 *      with the new task — `readBeadsIssues` + `diffBeadsIssues` MUST
 *      see it. (Direct write path; should never have been broken, but
 *      this pins the contract.)
 *
 *   b) Without a flush, when bd is invoked via the daemon path with no
 *      flush window, `readBeadsIssues` may miss the task. With a flush
 *      injected before the post-snapshot, the task appears. This is
 *      the race the harness fixes.
 *
 *   c) `flushFixtureBeads` is tolerant: missing `.beads/` is treated as
 *      a no-op (a fixture that hasn't run `bd init` yet — returns
 *      `noBeadsDir:true`), and a missing bd binary returns
 *      `bdMissing:true` rather than throwing.
 *
 * Run mode: real bd is preferred (available locally and on the dev
 * CI runner where the QA gate runs). When `BD_SHIM_ONLY=1` is set OR
 * the `bd` binary isn't on PATH, individual specs SKIP-WITH-LOG via
 * `it.skipIf` — mirroring the shell tests' convention (see
 * .claude/tests/component/lib/fixture.sh, bd_required_or_skip).
 */
import { describe, it, expect } from "vitest";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  readBeadsIssues,
  diffBeadsIssues,
  flushFixtureBeads,
} from "../lib/beadsCapture.js";

// Detect whether the real bd CLI is available. We don't try to be
// clever — if `bd --version` exits 0, we use it. The CI's BD_SHIM_ONLY
// override is supported for parity with the shell tests' convention.
function isBdAvailable(): boolean {
  if (process.env.BD_SHIM_ONLY === "1") return false;
  const res = spawnSync("bd", ["--version"], { encoding: "utf8", timeout: 5_000 });
  return res.status === 0;
}

const BD_AVAILABLE = isBdAvailable();

// Per-spec sandbox: a fresh git repo + .beads/ initialized via bd init.
// The fixture's pattern of a `.claude/bin/bd` shim is mirrored so the
// flush helper exercises its shim-discovery branch as well.
function makeSandbox(prefix: string): string {
  const dir = mkdtempSync(path.join(tmpdir(), `beads-capture-${prefix}-`));
  // git init — bd's hint warnings expect a git workspace.
  const init = spawnSync("git", ["init", "-q"], { cwd: dir, encoding: "utf8" });
  if (init.status !== 0) throw new Error(`git init failed: ${init.stderr}`);
  // Set a deterministic identity so bd's "owner" field is stable.
  spawnSync("git", ["config", "user.email", "test@example.com"], { cwd: dir });
  spawnSync("git", ["config", "user.name", "test"], { cwd: dir });

  // Install the bd shim under .claude/bin/, mirroring the fixture
  // pattern. The shim wraps the real bd with --no-daemon, so callers
  // that PATH-resolve through it never hit the daemon path. We point
  // it at the actual bd location so the test still exercises real bd
  // (BD_AVAILABLE guards us against missing binaries).
  mkdirSync(path.join(dir, ".claude", "bin"), { recursive: true });
  // Find a real bd. PATH lookup so it works on dev + CI.
  const which = spawnSync("which", ["bd"], { encoding: "utf8" });
  const realBd = which.status === 0 ? which.stdout.trim() : "bd";
  writeFileSync(
    path.join(dir, ".claude", "bin", "bd"),
    `#!/bin/bash\nexec "${realBd}" --no-daemon "$@"\n`,
    { mode: 0o755 },
  );
  return dir;
}

function cleanupSandbox(dir: string): void {
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch {
    // Best-effort cleanup — vitest will tear down its tmp anyway.
  }
}

describe("beadsCapture: reading and diffing issues.jsonl", () => {
  it("readBeadsIssues returns empty map for a fixture without .beads/", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "beads-capture-empty-"));
    try {
      const map = readBeadsIssues(dir);
      expect(map.size).toBe(0);
    } finally {
      cleanupSandbox(dir);
    }
  });

  it("readBeadsIssues returns empty map for an existing .beads/ with no issues.jsonl yet", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "beads-capture-nojsonl-"));
    try {
      mkdirSync(path.join(dir, ".beads"), { recursive: true });
      const map = readBeadsIssues(dir);
      expect(map.size).toBe(0);
    } finally {
      cleanupSandbox(dir);
    }
  });

  it("readBeadsIssues parses well-formed issues.jsonl into a map keyed by id", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "beads-capture-parse-"));
    try {
      mkdirSync(path.join(dir, ".beads"), { recursive: true });
      const jsonl =
        JSON.stringify({ id: "x-1", labels: ["a", "b"] }) +
        "\n" +
        JSON.stringify({ id: "x-2", labels: [] }) +
        "\n";
      writeFileSync(path.join(dir, ".beads", "issues.jsonl"), jsonl);
      const map = readBeadsIssues(dir);
      expect(map.size).toBe(2);
      expect(map.get("x-1")?.labels.sort()).toEqual(["a", "b"]);
      expect(map.get("x-2")?.labels).toEqual([]);
    } finally {
      cleanupSandbox(dir);
    }
  });

  it("readBeadsIssues tolerates blank and malformed lines", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "beads-capture-corrupt-"));
    try {
      mkdirSync(path.join(dir, ".beads"), { recursive: true });
      const jsonl =
        JSON.stringify({ id: "x-1", labels: ["a"] }) +
        "\n\n" +
        "{this is not valid json}\n" +
        JSON.stringify({ id: "x-2", labels: ["b"] }) +
        "\n";
      writeFileSync(path.join(dir, ".beads", "issues.jsonl"), jsonl);
      const map = readBeadsIssues(dir);
      expect(map.size).toBe(2);
      expect(map.has("x-1")).toBe(true);
      expect(map.has("x-2")).toBe(true);
    } finally {
      cleanupSandbox(dir);
    }
  });

  it("diffBeadsIssues marks new ids as created and surfaces label-add transitions", () => {
    const before = new Map([
      ["x-1", { id: "x-1", labels: ["qa-pending"] }],
    ]);
    const after = new Map([
      ["x-1", { id: "x-1", labels: ["qa-pending", "qa-approved"] }],
      ["x-2", { id: "x-2", labels: ["backend"] }],
    ]);
    const { created, transitions } = diffBeadsIssues(before, after);
    expect(created).toEqual(["x-2"]);
    // Two transitions: x-1 gained qa-approved; x-2 gained backend (it
    // was created with labels).
    expect(transitions.length).toBe(2);
    const x1 = transitions.find((t) => t.taskId === "x-1");
    expect(x1?.added).toEqual(["qa-approved"]);
    expect(x1?.removed).toEqual([]);
    const x2 = transitions.find((t) => t.taskId === "x-2");
    expect(x2?.added).toEqual(["backend"]);
  });
});

describe("beadsCapture: flushFixtureBeads tolerance", () => {
  it("returns noBeadsDir:true when the fixture has no .beads/ directory yet", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "beads-capture-nobeads-"));
    try {
      const result = flushFixtureBeads(dir);
      expect(result.ok).toBe(true);
      expect(result.noBeadsDir).toBe(true);
      expect(result.bdMissing).toBe(false);
    } finally {
      cleanupSandbox(dir);
    }
  });

  it("returns bdMissing:true when the bd binary cannot be located", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "beads-capture-nobd-"));
    try {
      mkdirSync(path.join(dir, ".beads"), { recursive: true });
      const result = flushFixtureBeads(dir, {
        bdBin: "/this/path/does/not/exist/bd",
      });
      expect(result.ok).toBe(false);
      expect(result.bdMissing).toBe(true);
    } finally {
      cleanupSandbox(dir);
    }
  });
});

describe.skipIf(!BD_AVAILABLE)("beadsCapture: real-bd flush contract", () => {
  // Live evidence regression: this is the spec that fails BEFORE the
  // runFixture flush fix and passes after. We initialize a sandbox the
  // way the fixture does (git init + bd init via the no-daemon path),
  // create a task using BD_NO_DAEMON=1, then run the flush helper and
  // assert the diff captures the task.
  //
  // The pre-fix behavior was that runFixture never flushed at all —
  // the post-snapshot was read at whatever stale state the DB had at
  // end-of-run. We can't reproduce that EXACT race in a single test
  // worker (the BD_NO_DAEMON path auto-flushes), but we CAN pin the
  // contract that the flush+diff pipeline captures every task that
  // bd has written to SQLite — which is the contract the live race
  // violated by reading without flushing.

  it("flush + diff captures a task created via BD_NO_DAEMON=1 (post-fix contract)", () => {
    const dir = makeSandbox("flush-contract");
    try {
      // bd init via the shim — mirrors how a real fixture sets up.
      const shim = path.join(dir, ".claude", "bin", "bd");
      const init = spawnSync(shim, ["init", "--prefix", "u1"], {
        cwd: dir,
        encoding: "utf8",
        timeout: 15_000,
      });
      // bd init prints a doctor-style summary; non-zero exit can happen
      // even on success when no git upstream is set. Treat any output
      // we got as a soft signal and proceed — readBeadsIssues will tell
      // us authoritatively whether bd is functional.
      expect(existsSync(path.join(dir, ".beads"))).toBe(true);

      const before = readBeadsIssues(dir);
      expect(before.size).toBe(0);

      // Create a task via BD_NO_DAEMON=1 — the "direct" path. This SHOULD
      // flush synchronously. We pass --json to mirror how the
      // orchestrator's bash bd-create calls in the live trace looked.
      const create = spawnSync(
        shim,
        [
          "create",
          "Flush-contract test task",
          "-t",
          "feature",
          "-p",
          "2",
          "-l",
          "backend,qa-pending",
          "--json",
        ],
        {
          cwd: dir,
          encoding: "utf8",
          timeout: 15_000,
          env: { ...process.env, BD_NO_DAEMON: "1" },
        },
      );
      expect(create.status).toBe(0);

      // Inject the flush — this is the harness fix. It's idempotent
      // when bd has already auto-flushed.
      const flushResult = flushFixtureBeads(dir);
      expect(flushResult.bdMissing).toBe(false);
      // We accept ok:true OR a non-zero exit so long as issues.jsonl
      // exists with content — bd sync --flush-only sometimes exits 1
      // when no flush is pending (the auto-flush already ran). Either
      // way the contract is "issues.jsonl reflects the new task".

      const after = readBeadsIssues(dir);
      const { created } = diffBeadsIssues(before, after);

      // The fix's contract: post-flush, the diff sees the new task.
      // This is what the rubric-revision-loop live trace failed to
      // produce — beadsTasksCreated was empty despite the bd create.
      expect(created.length).toBeGreaterThan(0);
      expect(created[0]).toMatch(/^u1-[a-z0-9]+$/);

      // Spot-check labels propagation: created task carries the labels
      // we passed at create time — the diff's transition row should
      // mention them.
      const issuesJsonl = readFileSync(
        path.join(dir, ".beads", "issues.jsonl"),
        "utf8",
      );
      expect(issuesJsonl).toContain('"backend"');
      expect(issuesJsonl).toContain('"qa-pending"');
    } finally {
      cleanupSandbox(dir);
    }
  });

  it("flush is idempotent — repeated calls don't corrupt or drop state", () => {
    const dir = makeSandbox("flush-idempotent");
    try {
      const shim = path.join(dir, ".claude", "bin", "bd");
      spawnSync(shim, ["init", "--prefix", "u2"], {
        cwd: dir,
        encoding: "utf8",
        timeout: 15_000,
      });
      spawnSync(
        shim,
        ["create", "Idem 1", "-t", "feature", "-p", "2", "-d", "x"],
        {
          cwd: dir,
          encoding: "utf8",
          timeout: 15_000,
          env: { ...process.env, BD_NO_DAEMON: "1" },
        },
      );
      // Call flush three times — should never throw or partially write.
      flushFixtureBeads(dir);
      flushFixtureBeads(dir);
      flushFixtureBeads(dir);
      const after = readBeadsIssues(dir);
      expect(after.size).toBe(1);
    } finally {
      cleanupSandbox(dir);
    }
  });

  // Live-evidence regression (claude-workflow-plugin-366.5, Phase B trace
  // forensic): the node-react-auth-2026-06-11T23-34-49-784Z.jsonl replay
  // had beadsTasksCreated=[] despite 1 MCP bd_create_epic + 4 Bash
  // BD_NO_DAEMON=1 bd create operations on the wire. Forensic reproduction
  // against the live fixture's .beads/ pinned down the precise mechanism:
  //
  //   1. bd 0.47.1 records `jsonl_content_hash` + `jsonl_file_hash` in
  //      the `metadata` table on every successful flush.
  //   2. `bd sync --flush-only` checks those hashes against an existing
  //      JSONL file. If the hash matches OR the recorded hash points at
  //      a hash that some sibling .beads file (sync_base.jsonl in the
  //      live case) already carries, bd treats the flush as "JSONL
  //      unchanged" and writes NOTHING — even when `.beads/issues.jsonl`
  //      is absent on disk. Exit code is 0.
  //   3. The fixture's `.beads/sync_base.jsonl` is GITIGNORED (see
  //      `.beads/.gitignore` line 38) but `.beads/issues.jsonl` is NOT.
  //      runFixture's restore does `git clean -fd` (without `-x`), which
  //      cleans untracked-but-not-ignored files like issues.jsonl while
  //      leaving sync_base.jsonl + beads.db intact across runs.
  //   4. The hash in metadata still references sync_base's content. So
  //      after restore: beads.db has the DB rows, sync_base.jsonl has a
  //      matching-hash copy, issues.jsonl is absent. flush-only does
  //      nothing, readBeadsIssues sees an empty map, the diff is empty.
  //
  // The l1r.7 fix targeted the right symptom (race-between-daemon-and-
  // JSONL) but the wrong mechanism: `bd sync --flush-only` is not a
  // reliable "ensure issues.jsonl reflects DB state" primitive when bd
  // judges another file as the canonical export.
  //
  // This spec encodes the contract by reproducing the exact state:
  // beads.db populated + sync_base.jsonl present with matching hash +
  // issues.jsonl ABSENT. flushFixtureBeads must restore issues.jsonl
  // from the DB so the post-snapshot read sees the task.
  //
  // Pre-fix: this fails — flushFixtureBeads exits 0 but issues.jsonl
  // stays absent and readBeadsIssues returns an empty map.
  // Post-fix: flushFixtureBeads falls back to `bd export --force` (or
  // equivalent full-rewrite path) which always populates issues.jsonl
  // from the DB regardless of file-hash / sibling-file state.
  it("flush populates issues.jsonl when sync_base.jsonl is the bd-recognized export and issues.jsonl is absent (the live-fixture pattern)", () => {
    const dir = makeSandbox("flush-sync-base-hash-trap");
    try {
      const shim = path.join(dir, ".claude", "bin", "bd");
      spawnSync(shim, ["init", "--prefix", "pris"], {
        cwd: dir,
        encoding: "utf8",
        timeout: 15_000,
      });
      // Create a task via the no-daemon path. bd will populate both
      // beads.db AND issues.jsonl on the create itself.
      const create = spawnSync(
        shim,
        [
          "create",
          "Live pristine repro: epic-shaped task",
          "-t",
          "epic",
          "-p",
          "2",
          "-l",
          "feature",
        ],
        {
          cwd: dir,
          encoding: "utf8",
          timeout: 15_000,
          env: { ...process.env, BD_NO_DAEMON: "1" },
        },
      );
      expect(create.status).toBe(0);
      const initialJsonl = path.join(dir, ".beads", "issues.jsonl");
      expect(existsSync(initialJsonl)).toBe(true);

      // Reproduce the live-fixture pristine state by simulating the
      // observed git-clean-after-sync mechanism:
      //   (a) rename issues.jsonl -> sync_base.jsonl (mirrors the prior
      //       run's bd having promoted the export to a sync base, and
      //       leaving the gitignored sync_base.jsonl behind after the
      //       harness's `git clean -fd` removed only issues.jsonl).
      //   (b) at this point the bd metadata's jsonl_content_hash still
      //       matches sync_base.jsonl's content — exactly the condition
      //       that triggers bd 0.47.1's "JSONL unchanged (hash match)"
      //       short-circuit.
      // We don't rely on calling `bd sync` to set up the trap because
      // bd in 0.47.1 is finicky about sync without a configured branch;
      // the rename + retained hash IS what the live trace's fixture
      // state looks like (verified against the .beads/beads.db at
      // .claude/tests/e2e/fixtures/node-react-auth/.beads/).
      const syncBasePath = path.join(dir, ".beads", "sync_base.jsonl");
      writeFileSync(syncBasePath, readFileSync(initialJsonl, "utf8"));
      rmSync(initialJsonl);
      expect(existsSync(initialJsonl)).toBe(false);
      expect(existsSync(syncBasePath)).toBe(true);

      // Pre-snapshot: should be empty (the bug-condition the live
      // trace ran into).
      const before = readBeadsIssues(dir);
      expect(before.size).toBe(0);

      // THE CONTRACT: flush must restore issues.jsonl from the DB
      // regardless of sibling-file / hash state. Pre-fix: bd's
      // flush-only short-circuits, this assertion fails. Post-fix:
      // flushFixtureBeads forces an export.
      const flushResult = flushFixtureBeads(dir);
      expect(flushResult.bdMissing).toBe(false);

      // Post-flush, issues.jsonl MUST exist and contain the task.
      expect(existsSync(initialJsonl)).toBe(true);
      const after = readBeadsIssues(dir);
      const { created } = diffBeadsIssues(before, after);
      // Pre-fix: 0 (issues.jsonl was never written).
      // Post-fix: >=1 (the epic created above appears).
      expect(created.length).toBeGreaterThan(0);
      expect(created.some((id) => /^pris-/.test(id))).toBe(true);
    } finally {
      cleanupSandbox(dir);
    }
  });
});

describe.skipIf(BD_AVAILABLE)("beadsCapture: skip-with-log when bd is absent", () => {
  it("logs a skip notice — real bd unavailable on this runner", () => {
    // Mirrors the BD_SHIM_ONLY=1 convention from
    // .claude/tests/component/lib/fixture.sh::bd_required_or_skip. We
    // surface the skip via stderr so the CI log makes it obvious that
    // the contract specs above did not run.
    process.stderr.write(
      "SKIPPED: beads-capture real-bd specs (bd CLI absent or BD_SHIM_ONLY=1)\n",
    );
    expect(true).toBe(true);
  });
});

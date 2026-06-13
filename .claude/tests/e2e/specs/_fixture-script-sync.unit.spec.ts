/**
 * _fixture-script-sync.unit.spec.ts — DRIFT GUARD + sync-mechanism specs
 * for the fixture hook-script sync (G2.fixture-sync /
 * claude-workflow-plugin-llh.8).
 *
 * THE DEFECT CLASS (run-4 evidence; bd claude-workflow-plugin-366.10 +
 * n6d): every e2e fixture carries COMMITTED copies of the plugin's hook
 * scripts under `fixtures/<name>/.claude/scripts/*.sh`, invoked at run
 * time via `$CLAUDE_PROJECT_DIR/.claude/scripts/...` from the fixture's
 * settings.json hooks. Those copies pin whatever bytes were rendered when
 * the fixture was created. In run 4 a fixture's verify-before-stop.sh
 * predated a shipped fix, so the fix NEVER REACHED THE LIVE RUN — the
 * harness silently tested stale plugin behavior. (The plugin AGENT
 * surface loads dynamically through plugins:[{type:local}], so only these
 * project-scoped script copies can drift.)
 *
 * TWO LAYERS, both under test here:
 *
 *   1. DRIFT GUARD (the `committed fixture scripts match canonical`
 *      describe): an OFFLINE assertion — runs in CI's l3-vitest-unit job
 *      (`npm run test:unit`), no API key — that FAILS LOUDLY when any
 *      fixture's committed `.claude/scripts/<x>.sh` differs from the
 *      canonical `.claude/scripts/<x>.sh`, or is missing, or the fixture
 *      carries an extra script the canonical set dropped. This is what
 *      catches future drift before a live run can silently consume it.
 *
 *   2. SYNC MECHANISM (the `syncFixtureScripts` describe): runFixture's
 *      run-start sync that overwrites a fixture's copies with canonical
 *      bytes. The META-TEST introduces drift in a throwaway sandbox and
 *      proves (a) the guard's own comparison logic flags it, and (b)
 *      syncFixtureScripts re-heals it to byte-identical. Without the
 *      meta-test the guard could be vacuously green (e.g. a bug that
 *      compares a file against itself).
 *
 * Source of truth: `listCanonicalHookScripts` is the SINGLE definition of
 * "what is a fixture hook script" — shared by the live sync, the guard,
 * and the meta-test. The harness-only `resolve-fixture-spec.sh` is
 * excluded there (Makefile fixture->spec resolver; never invoked by a
 * fixture hook).
 */
import { describe, it, expect } from "vitest";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  findPluginRoot,
  listCanonicalHookScripts,
  syncFixtureScripts,
  sha256Hex,
} from "../lib/runFixture.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const E2E_ROOT = path.resolve(__dirname, "..");
const PLUGIN_ROOT = findPluginRoot(E2E_ROOT);
const CANONICAL_SCRIPTS_DIR = path.join(PLUGIN_ROOT, ".claude", "scripts");
const FIXTURES_DIR = path.join(E2E_ROOT, "fixtures");

/** Every fixture dir that ships a `.claude/scripts/` (i.e. exercises the
 *  plugin hook surface). Fixtures without that dir are out of scope for
 *  the guard — they have no copies to drift. */
function fixturesWithScripts(): string[] {
  if (!existsSync(FIXTURES_DIR)) return [];
  return readdirSync(FIXTURES_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .filter((name) =>
      existsSync(path.join(FIXTURES_DIR, name, ".claude", "scripts")),
    )
    .sort();
}

const CANONICAL_NAMES = listCanonicalHookScripts(PLUGIN_ROOT);
const FIXTURE_NAMES = fixturesWithScripts();

// A single representative script for the META-tests. Asserting presence
// here (rather than indexing CANONICAL_NAMES[0] inline) keeps the type
// `string` under noUncheckedIndexedAccess and fails fast with a clear
// message if the canonical set is ever empty.
const SAMPLE_SCRIPT = CANONICAL_NAMES[0];
if (!SAMPLE_SCRIPT) {
  throw new Error(
    "_fixture-script-sync.unit.spec: canonical hook-script set is empty — listCanonicalHookScripts returned nothing",
  );
}

describe("fixture-script-sync: canonical hook-script set", () => {
  it("listCanonicalHookScripts is non-empty and excludes the harness-only resolver", () => {
    expect(CANONICAL_NAMES.length).toBeGreaterThan(0);
    // resolve-fixture-spec.sh is the Makefile fixture->spec resolver and
    // must never be synced into a fixture (no fixture hook invokes it).
    expect(CANONICAL_NAMES).not.toContain("resolve-fixture-spec.sh");
    // Sanity: the run-4 culprit and its transitive deps ARE in the set.
    for (const required of [
      "verify-before-stop.sh",
      "qa-gate.sh",
      "session-start.sh",
      "impact-report.sh",
    ]) {
      expect(CANONICAL_NAMES).toContain(required);
    }
  });

  it("finds at least one fixture that ships a .claude/scripts/ dir", () => {
    // If this ever drops to zero the guard below would be vacuously
    // green — pin it so a fixture-layout change can't silently disable
    // the drift guard.
    expect(FIXTURE_NAMES.length).toBeGreaterThan(0);
  });
});

describe("fixture-script-sync: DRIFT GUARD — committed fixture scripts match canonical", () => {
  // One assertion per (fixture, canonical-script) pair. it.each gives a
  // readable failure line naming the exact drifting file, so a red CI
  // run points straight at "sync fixture X" rather than a generic fail.
  const cases: Array<{ fixture: string; script: string }> = [];
  for (const fixture of FIXTURE_NAMES) {
    for (const script of CANONICAL_NAMES) {
      cases.push({ fixture, script });
    }
  }

  it.each(cases)(
    "$fixture/.claude/scripts/$script is byte-identical to canonical",
    ({ fixture, script }) => {
      const fixtureCopy = path.join(
        FIXTURES_DIR,
        fixture,
        ".claude",
        "scripts",
        script,
      );
      const canonical = path.join(CANONICAL_SCRIPTS_DIR, script);
      expect(
        existsSync(fixtureCopy),
        `${fixture} is missing canonical hook script ${script} — run syncFixtureScripts (or 'make sync-fixtures') to heal`,
      ).toBe(true);
      const canonSha = sha256Hex(readFileSync(canonical));
      const copySha = sha256Hex(readFileSync(fixtureCopy));
      expect(
        copySha,
        `${fixture}/.claude/scripts/${script} has DRIFTED from canonical (run-4 staleness class) — re-sync fixtures`,
      ).toBe(canonSha);
    },
  );

  it.each(FIXTURE_NAMES)(
    "%s carries no EXTRA .sh script absent from the canonical set",
    (fixture) => {
      const dir = path.join(FIXTURES_DIR, fixture, ".claude", "scripts");
      const extra = readdirSync(dir)
        .filter((f) => f.endsWith(".sh"))
        .filter((f) => !CANONICAL_NAMES.includes(f));
      expect(
        extra,
        `${fixture} ships orphan hook script(s) not in canonical .claude/scripts/: ${extra.join(", ")}`,
      ).toEqual([]);
    },
  );
});

/** Build a throwaway fixture sandbox containing a `.claude/scripts/` dir
 *  seeded with DELIBERATELY-STALE copies of the canonical scripts (a
 *  marker line prepended) so the sync has real bytes to overwrite. */
function makeStaleFixtureSandbox(): { dir: string; cleanup: () => void } {
  const dir = mkdtempSync(path.join(tmpdir(), "fixture-script-sync-"));
  const scriptsDir = path.join(dir, ".claude", "scripts");
  spawnSync("mkdir", ["-p", scriptsDir]);
  for (const name of CANONICAL_NAMES) {
    const canonical = readFileSync(
      path.join(CANONICAL_SCRIPTS_DIR, name),
      "utf8",
    );
    // Prepend a marker so every copy is guaranteed to differ from
    // canonical (emulates a fixture frozen before a shipped fix).
    writeFileSync(
      path.join(scriptsDir, name),
      `# STALE-FIXTURE-MARKER (pre-sync)\n${canonical}`,
    );
  }
  return {
    dir,
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}

describe("fixture-script-sync: syncFixtureScripts mechanism (META-TEST)", () => {
  it("META: a deliberately-drifted copy is detected as different from canonical", () => {
    // Proves the guard's comparison primitive (sha mismatch) actually
    // fires on real drift — the guard above is only meaningful if THIS
    // passes. We do NOT mutate any committed fixture; the drift lives in
    // a tempdir sandbox.
    const sandbox = makeStaleFixtureSandbox();
    try {
      const sample = SAMPLE_SCRIPT;
      const canonSha = sha256Hex(
        readFileSync(path.join(CANONICAL_SCRIPTS_DIR, sample)),
      );
      const staleSha = sha256Hex(
        readFileSync(path.join(sandbox.dir, ".claude", "scripts", sample)),
      );
      // Drift MUST be observable — if these were equal the guard could
      // never catch staleness.
      expect(staleSha).not.toBe(canonSha);
    } finally {
      sandbox.cleanup();
    }
  });

  it("syncFixtureScripts overwrites every drifted copy with byte-identical canonical content", () => {
    const sandbox = makeStaleFixtureSandbox();
    try {
      const synced = syncFixtureScripts(sandbox.dir, PLUGIN_ROOT);

      // Every canonical script was synced...
      expect(synced.map((s) => s.name).sort()).toEqual([...CANONICAL_NAMES].sort());
      // ...and every one was reported as `changed` (all copies were stale).
      expect(synced.every((s) => s.changed)).toBe(true);

      // On-disk verification: each fixture copy is now byte-identical to
      // canonical, and the recorded SHA matches the bytes written.
      for (const rec of synced) {
        const canonical = readFileSync(
          path.join(CANONICAL_SCRIPTS_DIR, rec.name),
        );
        const copy = readFileSync(
          path.join(sandbox.dir, ".claude", "scripts", rec.name),
        );
        expect(sha256Hex(copy)).toBe(sha256Hex(canonical));
        expect(rec.sha256).toBe(sha256Hex(canonical));
      }

      // The harness-only resolver is NEVER written into the fixture.
      expect(
        existsSync(
          path.join(sandbox.dir, ".claude", "scripts", "resolve-fixture-spec.sh"),
        ),
      ).toBe(false);
    } finally {
      sandbox.cleanup();
    }
  });

  it("syncFixtureScripts is idempotent — a second sync reports zero changes", () => {
    const sandbox = makeStaleFixtureSandbox();
    try {
      syncFixtureScripts(sandbox.dir, PLUGIN_ROOT); // heal
      const second = syncFixtureScripts(sandbox.dir, PLUGIN_ROOT); // re-run
      expect(second.every((s) => !s.changed)).toBe(true);
    } finally {
      sandbox.cleanup();
    }
  });

  it("syncFixtureScripts creates .claude/scripts/ when absent (minimal fixture shape)", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "fixture-script-sync-empty-"));
    try {
      expect(existsSync(path.join(dir, ".claude", "scripts"))).toBe(false);
      const synced = syncFixtureScripts(dir, PLUGIN_ROOT);
      expect(existsSync(path.join(dir, ".claude", "scripts"))).toBe(true);
      expect(synced.length).toBe(CANONICAL_NAMES.length);
      // Every script created fresh counts as a change.
      expect(synced.every((s) => s.changed)).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("synced scripts are executable (mode preserved for bash hook invocation)", () => {
    const sandbox = makeStaleFixtureSandbox();
    try {
      syncFixtureScripts(sandbox.dir, PLUGIN_ROOT);
      const sample = SAMPLE_SCRIPT;
      const { mode } = statSync(
        path.join(sandbox.dir, ".claude", "scripts", sample),
      );
      // owner-execute bit set.
      expect(mode & 0o100).toBe(0o100);
    } finally {
      sandbox.cleanup();
    }
  });
});

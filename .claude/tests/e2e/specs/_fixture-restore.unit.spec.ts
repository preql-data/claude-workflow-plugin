/**
 * _fixture-restore.unit.spec.ts — offline unit specs for runFixture's
 * restoreFixture mechanism.
 *
 * Phase B finding (claude-workflow-plugin-366.5 -> 366.6): the previous
 * `restoreFixture` was `git stash` + `git reset --hard <pre-sha>` + `git
 * clean -fd` + (optional) `git stash pop`. If a `git stash pop`
 * conflicted with the reset-restored tree, the helper dropped the stash
 * to avoid a dangling state — which silently lost uncommitted operator
 * edits to harness-metadata files. node-react-auth/fixture.yaml's
 * invariants block was wiped exactly this way during the seed live
 * trace's run.
 *
 * Regression contract these specs encode:
 *
 *   a) An uncommitted edit to fixture.yaml SURVIVES a restore cycle.
 *      The harness must never silently revert it, because fixture.yaml
 *      is operator-authored metadata that the agent under test never
 *      writes.
 *
 *   b) A fixture WITHOUT a fixture.yaml round-trips cleanly through the
 *      restore (the harness-metadata preservation is a no-op for
 *      absent files; no thrown error).
 *
 *   c) Tracked code files that the agent might have modified ARE
 *      restored to the pre-run SHA (i.e. the existing reset/clean
 *      contract is preserved — the harness-metadata exception is
 *      narrow and additive, not a wholesale change to the restore
 *      semantics).
 *
 * Run mode: pure git via spawnSync in a tempdir. No bd, no Claude SDK.
 */
import { describe, it, expect } from "vitest";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  snapshotFixture,
  restoreFixture,
  selfHealOnEntry,
} from "../lib/runFixture.js";

// Build a fresh git sandbox with a fixture.yaml + a tracked source file
// committed at HEAD. The sandbox emulates the relevant shape of a
// fixtures/<name>/ directory under .claude/tests/e2e/.
function makeFixtureSandbox(prefix: string, fixtureYamlContent: string | null): {
  dir: string;
  cleanup: () => void;
} {
  const dir = mkdtempSync(path.join(tmpdir(), `fixture-restore-${prefix}-`));
  const init = spawnSync("git", ["init", "-q"], { cwd: dir, encoding: "utf8" });
  if (init.status !== 0) throw new Error(`git init failed: ${init.stderr}`);
  spawnSync("git", ["config", "user.email", "test@example.com"], { cwd: dir });
  spawnSync("git", ["config", "user.name", "test"], { cwd: dir });

  // Commit a source file that represents agent-writable content.
  writeFileSync(path.join(dir, "src.js"), "// canonical pre-run content\n");
  if (fixtureYamlContent !== null) {
    writeFileSync(path.join(dir, "fixture.yaml"), fixtureYamlContent);
  }
  spawnSync("git", ["add", "-A"], { cwd: dir });
  const commit = spawnSync(
    "git",
    ["commit", "-q", "-m", "initial"],
    { cwd: dir, encoding: "utf8" },
  );
  if (commit.status !== 0) {
    throw new Error(`git commit failed: ${commit.stderr}`);
  }

  return {
    dir,
    cleanup: () => {
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

describe("runFixture.restoreFixture: harness-metadata preservation", () => {
  it("uncommitted fixture.yaml edits SURVIVE a restore cycle (Phase B regression)", () => {
    // Canonical fixture.yaml content as committed at HEAD.
    const committedYaml = `name: regression-fixture\nprompt: test\n`;
    // The operator's uncommitted edit — adding an invariants block.
    const editedYaml = `name: regression-fixture\nprompt: test\ninvariants:\n  - name: stop-requires-approval\n`;

    const sandbox = makeFixtureSandbox("yaml-survives", committedYaml);
    try {
      // Operator edits fixture.yaml without committing.
      writeFileSync(path.join(sandbox.dir, "fixture.yaml"), editedYaml);

      // Snapshot the pre-run state — this is what runFixture does at
      // the top of every run. With the uncommitted edit present, the
      // snapshot stashes it.
      const snap = snapshotFixture(sandbox.dir);

      // Simulate the agent under test mutating tracked source files
      // mid-run. (The harness wants these wiped at restore time; the
      // operator's fixture.yaml edit is the exception.)
      writeFileSync(
        path.join(sandbox.dir, "src.js"),
        "// agent-mutated content\n",
      );
      // Simulate an untracked artifact the agent might leave behind.
      writeFileSync(
        path.join(sandbox.dir, "untracked-artifact.txt"),
        "// agent left this",
      );

      // Run restoreFixture — this is the contract under test.
      restoreFixture(sandbox.dir, snap);

      // The operator's uncommitted fixture.yaml edit MUST be back.
      const yamlAfter = readFileSync(
        path.join(sandbox.dir, "fixture.yaml"),
        "utf8",
      );
      expect(yamlAfter).toBe(editedYaml);

      // The agent's mutation of the tracked source file MUST be
      // reverted to the pre-run SHA — the existing restore contract.
      const srcAfter = readFileSync(path.join(sandbox.dir, "src.js"), "utf8");
      expect(srcAfter).toBe("// canonical pre-run content\n");

      // The untracked artifact MUST be cleaned.
      expect(existsSync(path.join(sandbox.dir, "untracked-artifact.txt"))).toBe(false);
    } finally {
      sandbox.cleanup();
    }
  });

  it("fixture WITHOUT a fixture.yaml round-trips cleanly (preservation is a no-op for absent files)", () => {
    const sandbox = makeFixtureSandbox("no-yaml", null);
    try {
      // Verify the pre-condition: fixture.yaml is not present.
      expect(existsSync(path.join(sandbox.dir, "fixture.yaml"))).toBe(false);

      const snap = snapshotFixture(sandbox.dir);
      writeFileSync(
        path.join(sandbox.dir, "src.js"),
        "// agent-mutated content\n",
      );
      restoreFixture(sandbox.dir, snap);

      // Source file is reverted, fixture.yaml is still absent.
      const srcAfter = readFileSync(path.join(sandbox.dir, "src.js"), "utf8");
      expect(srcAfter).toBe("// canonical pre-run content\n");
      expect(existsSync(path.join(sandbox.dir, "fixture.yaml"))).toBe(false);
    } finally {
      sandbox.cleanup();
    }
  });

  it("snapshotFixture captures fixture.yaml content into harnessMetadata at snapshot time", () => {
    // Pins the contract: snapshotFixture must populate
    // snapshot.harnessMetadata["fixture.yaml"] with the bytes that
    // were on disk at the start of the run. This is what makes
    // restoreFixture independent of git's stash state — the
    // harness-metadata path runs regardless of how the
    // reset/clean/pop sequence behaves.
    const committedYaml = `name: regression-fixture\nprompt: test\n`;
    const operatorYaml = `name: regression-fixture\nprompt: test\n# operator edit\ninvariants:\n  - name: stop-requires-approval\n`;
    const sandbox = makeFixtureSandbox("snapshot-captures-yaml", committedYaml);
    try {
      // Operator edits fixture.yaml uncommitted.
      writeFileSync(path.join(sandbox.dir, "fixture.yaml"), operatorYaml);

      const snap = snapshotFixture(sandbox.dir);

      // The snapshot must carry the operator's bytes, NOT the HEAD
      // bytes. This is the empirical proof that the restore path's
      // override has the right input.
      expect(snap.harnessMetadata).toBeDefined();
      expect(snap.harnessMetadata["fixture.yaml"]).toBe(operatorYaml);
    } finally {
      sandbox.cleanup();
    }
  });

  it("Run-3 regression: uncommitted fixture.yaml SURVIVES the dirty-on-entry self-heal that precedes snapshotFixture (claude-workflow-plugin-366.8)", () => {
    // Run 3 of Phase B (node-react-auth, 2026-06-12T00-50-56-312Z) ended
    // with fixture.yaml -28 lines vs outer HEAD on disk, and the live
    // spec failed with "no invariants declared in fixture.yaml". Forensic
    // chain:
    //
    //   1. Outer repo committed an invariants block to fixture.yaml at
    //      256e0c1 (v3.3.0). The FIXTURE's nested .git (a separate repo
    //      created by fixtureInit.ensureFixtureGitInit) was last committed
    //      before that, so the outer-committed bytes look UNCOMMITTED to
    //      the inner git.
    //   2. On every fresh runFixture invocation the inner repo therefore
    //      shows `git status --porcelain` dirty (the operator-authored
    //      invariants edit is uncommitted relative to nested HEAD).
    //   3. The dirty-on-entry self-heal at runFixture.ts:811-818 runs
    //      `git reset --hard HEAD && git clean -fd -e node_modules`
    //      BEFORE snapshotFixture (line 838) calls snapshotHarnessMetadata.
    //   4. Net: snapshotHarnessMetadata captures the post-reset (no-
    //      invariants) bytes, and the end-of-run restoreHarnessMetadata
    //      writes those wiped bytes back. The operator's edit is
    //      structurally unrecoverable through this code path.
    //
    // This test pins the contract: a dirty-on-entry fixture must come
    // out of the entry-self-heal with HARNESS_METADATA_FILES preserved,
    // even though tracked-but-uncommitted source files (src.js below)
    // get reverted to HEAD as designed.
    const committedYaml = `name: regression-fixture\nprompt: test\n`;
    // Operator's intended edit — committed at the OUTER plugin repo but
    // not at the inner fixture repo (the run-3 production shape).
    const operatorYaml = `name: regression-fixture\nprompt: test\ninvariants:\n  - name: stop-requires-approval\n  - name: orchestrator-no-edits\n`;

    const sandbox = makeFixtureSandbox("run3-dirty-entry", committedYaml);
    try {
      // Simulate the prior crash leftover: an untracked artifact AND an
      // uncommitted edit to fixture.yaml. This is the exact shape run 3
      // had on entry.
      writeFileSync(path.join(sandbox.dir, "fixture.yaml"), operatorYaml);
      writeFileSync(
        path.join(sandbox.dir, "crash-leftover.txt"),
        "// stray artifact from a SIGKILL'd prior run",
      );
      // Also simulate an agent-style tracked-file mutation.
      writeFileSync(
        path.join(sandbox.dir, "src.js"),
        "// agent-mutated content from prior crashed run\n",
      );

      // selfHealOnEntry is the structural extraction of the dirty-on-entry
      // recovery from runFixture.ts. It MUST preserve harness-metadata
      // files while still wiping crash leftovers + reverting tracked
      // source files. This is the contract the run-3 regression broke.
      selfHealOnEntry(sandbox.dir);

      // fixture.yaml — operator's intent MUST survive the self-heal.
      const yamlAfterHeal = readFileSync(
        path.join(sandbox.dir, "fixture.yaml"),
        "utf8",
      );
      expect(yamlAfterHeal).toBe(operatorYaml);

      // Crash leftover MUST be cleaned.
      expect(existsSync(path.join(sandbox.dir, "crash-leftover.txt"))).toBe(false);

      // Tracked source file MUST be reverted to HEAD (existing self-heal
      // contract, unchanged).
      const srcAfterHeal = readFileSync(path.join(sandbox.dir, "src.js"), "utf8");
      expect(srcAfterHeal).toBe("// canonical pre-run content\n");

      // End-to-end follow-through: snapshotFixture then restoreFixture
      // must round-trip the operator's bytes correctly. This is the
      // user-visible contract — what the live spec's satisfiesInvariants
      // sees at end-of-run.
      const snap = snapshotFixture(sandbox.dir);
      // The agent under test "writes" to the tracked file mid-run.
      writeFileSync(
        path.join(sandbox.dir, "src.js"),
        "// in-run agent edit\n",
      );
      restoreFixture(sandbox.dir, snap);

      const yamlAtEnd = readFileSync(
        path.join(sandbox.dir, "fixture.yaml"),
        "utf8",
      );
      expect(yamlAtEnd).toBe(operatorYaml);
    } finally {
      sandbox.cleanup();
    }
  });

  it("restoreFixture rewrites fixture.yaml from harnessMetadata as the LAST step, overriding any intermediate state", () => {
    // Direct test of the override: feed restoreFixture a hand-crafted
    // snapshot whose harnessMetadata says fixture.yaml should be
    // some-specific-string, with a working tree that already differs.
    // The restore must end with fixture.yaml == the snapshot's bytes
    // regardless of what git reset/clean/pop produced.
    //
    // This is the test that distinguishes the new restoreFixture from
    // the legacy one: a fixture.yaml whose content at restore time
    // does NOT match the snapshot.harnessMetadata gets rewritten.
    const committedYaml = `name: regression-fixture\nprompt: test\n`;
    const snapshotYaml = `name: regression-fixture\nprompt: test\n# snapshot-captured operator edit\ninvariants:\n  - name: stop-requires-approval\n`;
    const sandbox = makeFixtureSandbox("metadata-override", committedYaml);
    try {
      // Get a valid pre-run SHA via the real snapshotFixture (clean
      // tree case so no stash is created).
      const baseSnap = snapshotFixture(sandbox.dir);
      // Build the snapshot the test wants: not-stashed, real SHA,
      // hand-crafted harnessMetadata that differs from HEAD's
      // fixture.yaml.
      const snap = {
        stashed: false,
        headSha: baseSnap.headSha,
        harnessMetadata: { "fixture.yaml": snapshotYaml },
      };

      // Simulate a run that wrote a CONFLICTING fixture.yaml.
      writeFileSync(
        path.join(sandbox.dir, "fixture.yaml"),
        `name: regression-fixture\n# run-time-mutated; should be overridden\n`,
      );

      restoreFixture(sandbox.dir, snap);

      const yamlAfter = readFileSync(
        path.join(sandbox.dir, "fixture.yaml"),
        "utf8",
      );
      expect(yamlAfter).toBe(snapshotYaml);
    } finally {
      sandbox.cleanup();
    }
  });
});

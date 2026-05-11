/**
 * fixtureInit — idempotent initializer for a fixture's nested git repo.
 *
 * Background: each fixture is committed in the parent repo as plain
 * files. The fixture's OWN `.git/` is intentionally not committed
 * (nested git repos aren't a thing the parent tracks — git skips the
 * inner `.git/` directory). On a fresh clone, the fixture has no
 * `.git/` and `runFixture` would fail at the stash step.
 *
 * Solution: before any spec runs, this helper detects the missing
 * `.git/`, runs `git init` + initial commit so the fixture has a
 * known-good HEAD to stash/reset against. The result is identical to
 * what we committed at fixture build time, just locally re-derived.
 *
 * Idempotent: noop when `.git/` already exists. Calling repeatedly is
 * safe.
 */
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

export function ensureFixtureGitInit(fixturePath: string): void {
  if (!path.isAbsolute(fixturePath)) {
    throw new Error(
      `ensureFixtureGitInit: fixturePath must be absolute, got: ${fixturePath}`,
    );
  }
  if (!existsSync(fixturePath)) {
    throw new Error(
      `ensureFixtureGitInit: fixture path does not exist: ${fixturePath}`,
    );
  }
  if (existsSync(path.join(fixturePath, ".git"))) {
    return;
  }
  const run = (args: string[]) =>
    spawnSync("git", args, {
      cwd: fixturePath,
      encoding: "utf8",
      timeout: 30_000,
    });
  const init = run(["init", "-q", "-b", "main"]);
  if (init.status !== 0) {
    throw new Error(
      `ensureFixtureGitInit: git init failed: ${init.stderr}`,
    );
  }
  // Local config: use a stable identity so the initial commit's hash is
  // reproducible across machines. Disable signing — CI envs without a
  // GPG key would otherwise fail.
  run(["config", "user.email", "fixture@local"]);
  run(["config", "user.name", "fixture-init"]);
  run(["config", "commit.gpgsign", "false"]);
  // Stage everything (the .gitignore in the fixture excludes node_modules,
  // .qa-tracking, beads.db, etc.) and commit.
  const add = run(["add", "-A"]);
  if (add.status !== 0) {
    throw new Error(`ensureFixtureGitInit: git add failed: ${add.stderr}`);
  }
  const commit = run([
    "commit",
    "-q",
    "--allow-empty",
    "-m",
    "fixture: initial state (auto-init)",
  ]);
  if (commit.status !== 0) {
    throw new Error(
      `ensureFixtureGitInit: git commit failed: ${commit.stderr}`,
    );
  }
}

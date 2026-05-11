/**
 * Vitest config for the L3/L4 E2E harness.
 *
 * Why these specific settings:
 *   - 30-minute global per-test timeout: live runs hit real Claude
 *     Opus 4.7 with the QA gate iteration loop, multiple subagents,
 *     full hook firing, and Beads writes. An early Phase A live run
 *     timed out at a 10-minute ceiling while real work was in flight
 *     (the SDK had written the component + tests + auth endpoint and
 *     QA was about to start). Per the cost-irrelevant principle the
 *     only constraint is the runner's patience, so we set the global
 *     ceiling to 30 min. Specs may override per-test with the third
 *     `it()` argument (the happy-path spec also pins 1_800_000 ms
 *     locally so it's self-documenting).
 *   - No global setup file: per-fixture isolation lives in `runFixture.ts`
 *     (git stash + tempdir HOME). Globals would muddle that.
 *   - Single-threaded (`pool: "forks"` with `singleFork: true`): the SDK
 *     spawns a child process and shares some global state (HOME, cwd via
 *     env). Parallel SDK runs in one fork race on those mutations. We let
 *     Promptfoo handle parallelism at a higher layer (one Promptfoo process
 *     per concurrency slot, each running this Vitest config under it).
 *   - setupFiles registers the custom matchers from lib/assertions.ts so
 *     `expect(trace).subagentInvoked(...)` etc. resolve in every spec
 *     without per-file imports.
 *
 * Note on timeout-vs-cleanup: vitest enforces `testTimeout` by SIGKILL'ing
 * the worker, which means try/finally cleanup in `runFixture` does not
 * run when the timeout fires. The harness mitigates this with a
 * self-heal-on-entry check in `runFixture` (auto-restore if fixture is
 * dirty); see also the discovered-from follow-up bug.
 */
import { defineConfig } from "vitest/config";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  resolve: {
    alias: {
      "~/lib": path.resolve(__dirname, "lib"),
    },
  },
  test: {
    testTimeout: 30 * 60 * 1000,
    hookTimeout: 60 * 1000,
    globals: false,
    pool: "forks",
    poolOptions: {
      forks: {
        singleFork: true,
      },
    },
    fileParallelism: false,
    setupFiles: [path.resolve(__dirname, "lib/setup.ts")],
    include: ["specs/**/*.spec.ts"],
    reporters: process.env.CI ? ["default", "json"] : ["default"],
    outputFile: process.env.CI
      ? { json: path.resolve(__dirname, ".tmp/vitest-results.json") }
      : undefined,
  },
});

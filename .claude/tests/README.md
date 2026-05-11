# Tests

Five-tier test pyramid for the claude-workflow-plugin. Each tier catches a
different failure mode; together they form the gate that a change has to
clear before it ships.

## Overview

| Tier | Lives at | What it proves | Live? | Where it runs |
| ---- | -------- | -------------- | ----- | ------------- |
| **L1 — bash unit** | `.claude/scripts/tests/*.sh` | Individual hook script logic with crafted stdin payloads | Offline | `make test`, CI |
| **L2 — component** | `.claude/tests/component/specs/*.sh` | Hook **pipelines** (e.g. `qa-gate enter` → `current-task set` → `verify-before-stop allow`) end-to-end with tempdir fixtures | Offline | `make test-component`, CI |
| **L3 — vitest unit** | `.claude/tests/e2e/specs/*.unit.spec.ts` | Harness internals: trace schema, normalization, golden compare, fixture init, custom matchers | Offline | `make test-e2e-unit`, CI |
| **L3 — live e2e** | `.claude/tests/e2e/specs/<fixture>.spec.ts` | Plugin behaviour end-to-end against real Claude Opus 4.7 for a representative fixture project | **Live** (~$5–10 per fixture per recording) | `make test-e2e`, CI when `ANTHROPIC_API_KEY` is set |
| **L4 — drift watch** | Same specs as L3-live | Daily re-run on `main` so model output drift surfaces as a cassette diff rather than at PR review time | **Live** | GitHub Actions cron (6:00 UTC) |

CI surfaces each tier as a distinct check (`.github/workflows/test.yml`)
so a failure points at the right layer.

## When to add a test at which tier

Use the first row that matches:

| You changed... | Add the test at... | Why |
| -------------- | ------------------ | --- |
| A single hook script's logic (input → output JSON) | **L1** | Cheap, fast, the contract is a JSON envelope |
| Hook **pipeline** behaviour — e.g. how `qa-gate.sh` interacts with `current-task.sh` and `verify-before-stop.sh` | **L2** | L2 has the fixture scaffolding to chain hooks; L1 stops at one script |
| `runFixture` / `trace.ts` / `goldenCompare.ts` / `cassette-diff.ts` machinery | **L3-unit** | Pure logic, no model calls needed |
| Orchestrator → specialist → QA chain, or any behaviour that requires the model to **decide** something | **L3-live** | These are the assertions the L1/L2 tiers can't reach |
| Model-output stability over time (catching drift in subagent tree shape, hook firing order, label transitions) | **L4** | Daily cron on `main` |

If a test could plausibly live at two tiers, prefer the **lower** (cheaper,
faster, more deterministic) one. The Phase D failure-injection specs are
a worked example: they sit at L3-unit (`_failure-regression-coverage.unit.spec.ts`,
`_gate-sanity.unit.spec.ts`) because the gate's contract is testable via
synthetic Trace mutation; we don't need a new $5–10 live run to re-prove
what 4ms of deterministic logic can prove.

## Local commands

```
make test              # L1 bash unit tests
make test-component    # L2 component tier
make test-all          # L1 + L2 (the offline gate)
make test-e2e-unit     # L3 vitest unit tier (offline harness self-tests)
make manifest-validate # Zod-replica check of .claude-plugin/plugin.json
make test-ci           # L1 + L2 + L3-unit + manifest (what CI runs without API key)
make test-e2e          # L3 live tier — requires ANTHROPIC_API_KEY
make test-e2e-record   # L3 live tier in record mode (captures missing goldens)
make test-e2e-install  # one-shot npm install for the e2e harness
make cassette-diff     # diff the most recent replay vs its committed golden
```

`make test-ci` is the local mirror of what the GitHub Actions
`tests` workflow runs before the live tier. If `test-ci` is green
locally, the offline jobs in CI will be green too.

## Adding a new fixture

1. **Create the directory.** `.claude/tests/e2e/fixtures/<name>/` with the
   skeleton the existing fixtures use (compare `node-react-auth/` for the
   canonical shape). At minimum: `fixture.yaml`, `.claude/settings.json`,
   any project files the prompt expects to find (e.g. `package.json`,
   `server/`, `client/` for a workspace).

2. **Pre-install the bd shim.** Drop the shim at
   `.claude/bin/bd` (a 2-line script that exec's `bd --no-daemon "$@"` —
   see `node-react-auth/.claude/bin/bd` as the template) and inline its
   parent directory on the `PATH` for every hook command in
   `.claude/settings.json`. This must be **inlined** on each hook command,
   not set via `env`, because Claude Code does not expand `${VAR}` inside
   `settings.json` env blocks
   ([anthropics/claude-code#4276](https://github.com/anthropics/claude-code/issues/4276)).

3. **Initialize `.git/`** with a single commit. The canonical state is
   what `runFixture.ts` stashes/restores around each run; a clean git
   baseline is required.

4. **Initialize `.beads/`** with `bd init` (the shim handles the
   `--no-daemon` invocation transparently).

5. **Write `fixture.yaml`** with `name`, `description`, `prompt`,
   `expected_subagents`, `expected_hooks`, `expected_label_progression`,
   and any `notes:` that explain non-obvious choices.

6. **Write the spec** at `.claude/tests/e2e/specs/<name>.spec.ts`. Start
   from `happy-path.spec.ts`; replace the fixture path, golden path, and
   the structural assertions for what your fixture is meant to exercise.

7. **Capture the golden.** With `ANTHROPIC_API_KEY` set:

   ```
   cd .claude/tests/e2e
   RECORD_GOLDEN=1 npm run test:run -- <name>.spec.ts
   ```

   This writes `cassettes/golden/<name>.jsonl`. Commit it.

## Refreshing a golden cassette

The default-deny convention prevents accidental overwrites: existing
goldens are never overwritten silently. To refresh one:

```
# Option A — re-record from scratch (live run).
rm .claude/tests/e2e/cassettes/golden/<name>.jsonl
cd .claude/tests/e2e
RECORD_GOLDEN=1 npm run test:run -- <name>.spec.ts

# Option B — promote a recent replay (when you have a known-good replay
# but the spec failed for an unrelated reason).
cd .claude/tests/e2e
npm run promote-replay -- --fixture <name> \
  --replay cassettes/replays/<name>-<timestamp>.jsonl
```

Option B is the shortcut after a "fixture passed, harness threw" kind of
run. The promoter normalizes the replay and writes it as the new golden,
so the next live run diffs against fresh evidence.

## Reading a structural diff

`cassette-diff` normalizes both sides before comparing. The normalization
strips drift we don't care about and preserves the structural fingerprint:

| Preserved (a change here is a real signal) | Normalized away (a change here is noise) |
| ------------------------------------------ | ---------------------------------------- |
| Tool name sequence | Tool durations, costs, token counts |
| Subagent tree shape (who-spawned-whom) | Subagent run IDs, UUIDs |
| Hook firing sequence (event[:decision]) | Hook response bodies, timestamps |
| File-write paths + change types | Raw file contents written |
| Permission denials by tool, with counts | Free-form prose in reasons |
| Beads task IDs created | Created-at timestamps |
| Beads label transitions (`+added -removed`) | Note text in `bd update --notes` |
| Plugin loader status (names + errors) | Load timing |

Interpreting drift:

- **Tool sequence drift** — the orchestrator (or a specialist) reached
  for a different tool, or in a different order. Usually a model-output
  shift; check if it's a regression vs an acceptable variation.
- **Subagent tree drift** — the routing changed. If you intended to add a
  specialist or change the orchestrator's Domain → Delegate table, this
  is your evidence; otherwise investigate.
- **Hook firing drift** — a hook that used to fire isn't, or vice versa.
  Almost always a regression (hooks are deterministic given the same
  tool sequence).
- **Label transition drift** — Beads label flow changed. Compare against
  the QA convention: `qa-pending → qa-approved`, never the reverse.

## The META-TEST convention

A **META-TEST** is an assertion that proves the test itself is sensitive
to the failure it claims to catch — not just that the system under test
is currently passing. They live next to the regular assertions in L1, L2,
and L3-unit specs, prefixed with the word `META-TEST` in the test name.

Why this matters: a passing assertion is consistent with two states:
either the SUT is correct, or the assertion is too weak to catch the bug.
META-TESTs disambiguate by mutating the trace (or hook envelope) in a
way that should trip the assertion, and checking that it does.

The CI workflow tallies META-TEST pass/fail counts as a distinct line
in the L2 job summary so regression-injection sensitivity stays
visible. If a META-TEST starts passing through when it should fail, the
test has gone soft and the gate doesn't actually guard the thing it
names.

## Known gotchas

- **bd daemon stack-overflow.** `bd 0.47.1`'s daemon-autostart path
  crashes (`cmd/bd/daemon_autostart.go:228`). Every fixture pre-installs
  a `bd` shim at `.claude/bin/bd` that exec's `bd --no-daemon "$@"`. If
  your hook subprocess can't find `bd`, you forgot to inline the bin/
  prefix on the hook command's `PATH`.
- **`cassettes/replays/` is gitignored, `cassettes/golden/` is committed.**
  Replays are debug artifacts; goldens are evidence. Don't `git add`
  replays.
- **Vitest runs single-fork** (`singleFork: true` in `vitest.config.ts`).
  The Claude Agent SDK shares process-global state (HOME, cwd via env)
  and parallel runs race on it. Higher-level parallelism is the job of
  Promptfoo, one process per slot.
- **Stop hooks signal "allow" by absence.** A Stop hook returning `{}`
  (or no `decision` key) means *allow stop*. Only `decision: "block"`
  blocks. There is no "approve" decision.
- **`includeHookEvents: true` is required** to capture non-`SessionStart`
  hook events in the SDK's stream. `runFixture.ts` sets this; if you
  build a custom run path, set it there too or hooks won't appear in
  the trace.
- **`${VAR}` in `settings.json` env does NOT expand.** Each hook command
  must inline its `PATH` prefix
  ([anthropics/claude-code#4276](https://github.com/anthropics/claude-code/issues/4276)).
- **Hook subprocesses need the fixture's bd shim on `PATH`.** That's the
  whole reason for the inline-PATH-per-command pattern above. If a new
  hook lands in `settings.json`, make sure its command line starts with
  `PATH="$CLAUDE_PROJECT_DIR/.claude/bin:$PATH" bash ...`.

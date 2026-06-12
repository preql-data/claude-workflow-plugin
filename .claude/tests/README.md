# Tests

Four-tier test pyramid for the claude-workflow-plugin. Each tier catches a
different failure mode; together they form the gate that a change has to
clear before it ships. The live tier is manual-only and invariant-based as
of v3.1.0 (spec item 0.8) — see [Live e2e (manual, invariant-based)](#live-e2e-manual-invariant-based)
below.

## Overview

| Tier | Lives at | What it proves | Live? | Where it runs |
| ---- | -------- | -------------- | ----- | ------------- |
| L1 — bash unit | `.claude/scripts/tests/*.sh` | Individual hook script logic with crafted stdin payloads | Offline | `make test`, CI |
| L2 — component | `.claude/tests/component/specs/*.sh` | Hook pipelines end-to-end with tempdir fixtures | Offline | `make test-component`, CI |
| L3 — vitest unit | `.claude/tests/e2e/specs/*.unit.spec.ts` | Harness internals: trace schema, normalization, custom matchers, the invariant engine | Offline | `make test-e2e-unit`, CI |
| L3 — live e2e | `.claude/tests/e2e/specs/<fixture>.spec.ts` | Plugin behaviour end-to-end against real Claude, asserted via fixture-declared invariants | Live (~$5–10 per fixture) | `make test-live FIXTURE=<name>` (manual only) |

The retired L4 daily drift watch and any automatic L3-live PR/cron runs
were removed in v3.1.0 spec item 0.8. CI consumes zero API spend on a
normal PR or push run.

## When to add a test at which tier

Use the first row that matches:

| You changed... | Add the test at... | Why |
| -------------- | ------------------ | --- |
| A single hook script's logic (input → output JSON) | L1 | Cheap, fast, the contract is a JSON envelope |
| Hook pipeline behaviour — e.g. how `qa-gate.sh` interacts with `current-task.sh` and `verify-before-stop.sh` | L2 | L2 has the fixture scaffolding to chain hooks; L1 stops at one script |
| `runFixture` / `trace.ts` / `invariants.ts` / harness internals | L3-unit | Pure logic, no model calls needed |
| Orchestrator → specialist → QA chain, or any behaviour that requires the model to decide something | L3-live | These are the assertions the L1/L2 tiers can't reach; gated on invariants from fixture.yaml |

If a test could plausibly live at two tiers, prefer the lower one (cheaper,
faster, more deterministic). The Phase D failure-injection specs are
a worked example: they sit at L3-unit (`_failure-regression-coverage.unit.spec.ts`,
`_gate-sanity.unit.spec.ts`) because the gate's contract is testable via
synthetic Trace mutation; no new $5–10 live run is needed to re-prove
what 4ms of deterministic logic can prove.

## Local commands

```
make test              # L1 bash unit tests
make test-component    # L2 component tier
make test-all          # L1 + L2 (the offline gate)
make test-e2e-unit     # L3 vitest unit tier (offline; includes the invariant engine specs)
make manifest-validate # Zod-replica check of .claude-plugin/plugin.json
make test-ci           # L1 + L2 + L3-unit + manifest (what CI runs)
make test-live FIXTURE=<name> [CONFIRM=1] [RECORD=1]
                       # L3 live tier — manual only; requires FIXTURE= and ANTHROPIC_API_KEY
make test-e2e-install  # one-shot npm install for the e2e harness
make cassette-diff     # diff the most recent replay vs its committed golden (debugging tool)
```

`make test-ci` is the local mirror of what the GitHub Actions
`tests` workflow runs. If `test-ci` is green locally, CI will be green too.

## Live e2e (manual, invariant-based)

Live runs hit real Claude. They are not on a schedule and not on any PR
gate. Run them deliberately during a development cycle when you need to
validate that a change in the plugin surface still produces the right
multi-agent workflow.

```
make test-live FIXTURE=node-react-auth         # one fixture
make test-live FIXTURES="a b c"                 # multiple
make test-live FIXTURE=node-react-auth CONFIRM=1 # skip the prompt
```

`test-live` requires a `FIXTURE=` (or `FIXTURES=`) argument and prints
the estimated cost before starting. Without explicit `CONFIRM=1` it
waits for a y/N confirmation.

### Per-fixture cost (estimates)

All estimates derive from the G8 runs in 2026-05. Real cost depends on
the active model snapshot and whether QA's block-then-recover loop
fires. Values are USD; the active model is whichever the SessionStart
resolver pins (see `.claude/scripts/model-select.sh` and the statusline
output).

| Fixture | Estimated cost | Estimated time | Notes |
| ------- | -------------- | -------------- | ----- |
| node-react-auth | $5-10 | 13-17 min | Canonical two-domain happy path; longest baseline |
| go-cli-refactor | $5-10 | 13-17 min | Single-domain refactor with regression-coverage check |
| monorepo-frontend-only | $5-10 | 13-17 min | Scoped single-domain change |
| multi-domain-signup | $5-10 | 13-17 min | Three-domain epic; can run longer |
| python-django-bug | $5-10 | 13-17 min | Single-domain bug fix with debugger framework |
| qa-block-recovery | $5-10 | 13-17 min | Often higher — recovery loops add iterations |

### Invariants (model-agnostic gate)

Live specs gate on invariants, not golden-trace equality. Each
fixture's `fixture.yaml` declares an `invariants:` block; the spec
asserts every declared invariant passes. Invariants are properties of
the workflow contract (orchestrator never edits, QA approval gates
Stop, declared specialists are the only ones invoked), so they hold
across model versions by construction — no cassette refresh cycle.

Schema:

```yaml
invariants:
  - name: stop-requires-approval
  - name: orchestrator-no-edits
  - name: completion-contract
  - name: label-milestones
    params:
      milestones:
        - qa-pending
        - qa-approved
  - name: declared-subagents-only
    params:
      declared:
        - backend
        - qa
```

### Built-in invariants

| Name | What it asserts | Implementation notes |
| ---- | --------------- | -------------------- |
| `stop-requires-approval` | A Stop hook never allowed completion without `qa-approved` (or `qa-deferred` per 0.2) appearing on at least one task | Approximation — the trace records label transitions as a single before/after diff per task, not interleaved with hook events, so we assert the strongest checkable form (presence of qa-approved given any Stop:allow). Documented in `invariants.ts`. |
| `orchestrator-no-edits` | No Write / Edit / MultiEdit toolCall is attributable to the orchestrator (root-level call outside any subagent's parent chain) | Trace-level proof that `prevent-orchestrator-edits.sh` did its job that run |
| `completion-contract` | Every specialist completion payload carries all six F7 fields | Implemented as `skipped` with a documented trace-gap reason — the trace doesn't capture structured completion payloads yet. Faking it would make the gate worthless |
| `label-milestones` | Fixture-declared milestone labels all appear as label adds across the run | Replaces `expected_label_progression` exact-equality. Extra intermediate adds are allowed |
| `declared-subagents-only` | Every subagent invocation matches the fixture's declared specialist set | Plugin-qualifier tolerant (`backend` matches `claude-workflow:backend`); orchestrator and `general-purpose` are always allowed |

### Adding an invariant

1. Implement the function in `lib/invariants.ts` matching the
   `InvariantImpl` signature: `(trace, params?) => {pass, detail}`.
2. Register it in the `INVARIANTS` map at the bottom of the same file.
3. Add it to the relevant fixtures' `invariants:` blocks in
   `fixture.yaml`.
4. Add at least one POSITIVE case and one META-TEST in
   `specs/_invariants.unit.spec.ts`. The META-TEST must mutate a
   known-good trace to violate the new invariant and assert the engine
   catches it by name.

The unit tier validates the engine on every PR (offline, free); see
`specs/_invariants.unit.spec.ts` for the existing META-TEST pattern.

## Adding a new fixture

1. Create the directory at `.claude/tests/e2e/fixtures/<name>/`
   with the skeleton the existing fixtures use (compare
   `node-react-auth/` for the canonical shape). At minimum:
   `fixture.yaml`, `.claude/settings.json`, any project files the prompt
   expects to find.

2. Pre-install the bd shim at `.claude/bin/bd` (a 2-line script that
   exec's `bd --no-daemon "$@"` — see `node-react-auth/.claude/bin/bd`
   as the template) and inline its parent directory on the `PATH` for
   every hook command in `.claude/settings.json`. The inline form is
   required because Claude Code does not expand `${VAR}` inside
   `settings.json` env blocks
   ([anthropics/claude-code#4276](https://github.com/anthropics/claude-code/issues/4276)).

3. Initialize `.git/` with a single commit. The canonical state is
   what `runFixture.ts` stashes/restores around each run; a clean git
   baseline is required.

4. Initialize `.beads/` with `bd init` (the shim handles the
   `--no-daemon` invocation transparently).

5. Write `fixture.yaml` with `name`, `description`, `prompt`,
   `expected_subagents`, `expected_hooks`, `expected_label_progression`,
   an `invariants:` block (see the schema above), and any `notes:` that
   explain non-obvious choices.

6. Write the spec at `.claude/tests/e2e/specs/<name>.spec.ts`. Start
   from `happy-path.spec.ts`; replace the fixture path and the
   structural assertions for what your fixture is meant to exercise.
   End the spec with
   `await expect(trace).satisfiesInvariants(FIXTURE_YAML)`.

7. Run live once to validate during the development cycle:

   ```
   make test-live FIXTURE=<name>
   ```

## Golden cassettes (debugging only)

After v3.1.0 spec item 0.8, golden cassettes are not a gate. The
existing files under `cassettes/golden/` are retained as a seed corpus
for testing the invariant engine itself (see `_invariants.unit.spec.ts`)
and as debugging references. To inspect the structural shape of the
most recent replay against its committed golden:

```
make cassette-diff FIXTURE=<name>
```

This prints a structural diff. It does not gate, does not refresh
anything, and is safe to ignore in normal CI flow.

`cassette-diff` normalizes both sides before comparing. The normalization
strips drift we don't care about and preserves the structural fingerprint:

| Preserved | Normalized away |
| --------- | --------------- |
| Tool name sequence | Tool durations, costs, token counts |
| Subagent tree shape (who-spawned-whom) | Subagent run IDs, UUIDs |
| Hook firing sequence (event[:decision]) | Hook response bodies, timestamps |
| File-write paths + change types | Raw file contents written |
| Permission denials by tool, with counts | Free-form prose in reasons |
| Beads task IDs created | Created-at timestamps |
| Beads label transitions (`+added -removed`) | Note text in `bd update --notes` |
| Plugin loader status (names + errors) | Load timing |

## Interpreting cassette drift

When `make cassette-diff` surfaces a difference, it is informational
only. Interpret it like this:

- Tool sequence drift — the orchestrator (or a specialist) reached
  for a different tool, or in a different order. Usually a model-output
  shift; not a gate fail.
- Subagent tree drift — the routing changed. If you intended to add a
  specialist or change the orchestrator's Domain → Delegate table, this
  is your evidence; otherwise investigate.
- Hook firing drift — a hook that used to fire isn't, or vice versa.
  Hooks are deterministic given the same tool sequence, so this is
  worth investigating even though the live gate no longer fails on it.
- Label transition drift — Beads label flow changed. Compare against
  the QA convention: `qa-pending → qa-approved`, never the reverse.

The live gate fails on invariants (see above), not on drift. Use drift
as a debugging signal, not as a regression detector.

## The META-TEST convention

A META-TEST is an assertion that proves the test itself is sensitive
to the failure it claims to catch — not just that the system under test
is currently passing. They live next to the regular assertions in L1, L2,
and L3-unit specs, prefixed with the word `META-TEST` in the test name.

Why this matters: a passing assertion is consistent with two states —
either the SUT is correct, or the assertion is too weak to catch the bug.
META-TESTs disambiguate by mutating the trace (or hook envelope) in a
way that should trip the assertion, and checking that it does.

The CI workflow tallies META-TEST pass/fail counts as a distinct line
in the L2 job summary so regression-injection sensitivity stays
visible. If a META-TEST starts passing through when it should fail, the
test has gone soft and the gate doesn't actually guard the thing it
names.

### Invariant META-TEST pattern

The invariant engine carries the META-TEST convention into L3-unit. For
every invariant in `lib/invariants.ts`, `specs/_invariants.unit.spec.ts`
holds at least:

- One POSITIVE case: a synthetic (or retained-replay) `Trace` that
  satisfies the invariant; the engine returns `pass: true`.
- One META-TEST: a deliberate mutation of that trace that violates the
  invariant; the engine returns `pass: false` and the failure detail
  cites the invariant by name.

Example pattern (see the file for live code):

```ts
it("META-TEST: fails when a root-level Write is injected (orchestrator-attributable)", () => {
  const t = goodTrace();
  t.toolCalls.push({
    id: "rogue-write",
    name: "Write",
    input: { file_path: "rogue.md" },
    parentToolUseId: null, // root level == orchestrator scope
    durationMs: 0,
  });
  const agg = evaluateAll(t, [{ name: "orchestrator-no-edits" }]);
  expect(agg.allPassed).toBe(false);
  expect(agg.results[0].result.detail).toMatch(/Write\(rogue\.md\)/);
});
```

Every invariant must arrive with this pair. Adding a check without its
META-TEST is the same gap as a regular assertion without one.

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

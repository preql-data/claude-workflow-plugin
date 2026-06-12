---
description: Run the on-demand mutation sweep (Phase C). Generates deterministic mutants per fault-class catalog, applies each in a throwaway git worktree, runs the offline test tier against it, and emits a survivors report. Stops at the cost-confirmation gate before any judge calls.
argument-hint: [--targets <path,path>] [--fault-classes <ids>] [--no-judge|--confirm-judge]
---

# /mutation-sweep

Invoke the Phase C mutation harness against the active project.

This command is for Claude to invoke. The user types intent in plain
English ("run the mutation sweep on the QA gate", "do a mutation pass on
post-edit") and you call this command with the appropriate targets.

The harness is **deterministic only** at C.1. A subsequent phase (C.2)
plugs an LLM judge into the seam this command emits. **No paid API call
is made by the deterministic pass.** The cost-confirmation gate at the
end of the run guards the judge step — you must pass `--confirm-judge`
(or the operator must answer `y` at the prompt) for the judge to run.

## What it does

1. Selects targets via `lib/rank-targets.sh` — `impact_of` fan-in when
   code-graph is present; `tests-referencing + line-count` heuristic
   otherwise. The heuristic is the always-on default; the harness is
   guaranteed to run without code-graph.
2. Generates mutants from the catalog at
   `.claude/tests/mutation/fault-classes.md` via `lib/generate.sh`.
   Deterministic awk/sed transforms — same input file always produces
   the same mutant set.
3. Applies each mutant in a fresh `git worktree --detach` under
   `.claude/.mutation-worktrees/`. Trap-based cleanup prunes every
   worktree on exit, including SIGINT / SIGTERM. The main tree is
   never touched.
4. Runs `bash .claude/scripts/tests/run-tests.sh` against the worktree
   under a per-mutant timeout. Tests fail -> KILLED. Tests pass ->
   SURVIVED.
5. Emits `report.json` and `summary.txt` under
   `.claude/.mutation-runs/<timestamp>/`. The JSON is the contract C.2
   reads; the summary is for the operator's eyes.
6. Prints survivor count + estimated judge cost. Waits for
   `--confirm-judge` (or `y`) before invoking the judge command.
   Without confirmation, the deterministic report stays on disk and
   the script exits 0 — no paid step has run.

## Caps and budget

All defined in `.claude/tests/mutation/mutation.conf`:

- `MAX_MUTANTS_PER_FILE` — mutants generated per target (default 24).
- `MAX_MUTANTS_PER_RUN` — hard ceiling across all targets (default 60).
- `MUTANT_TEST_TIMEOUT_S` — per-mutant wall-clock cap (default 60s).
- `SWEEP_TIMEOUT_S` — overall sweep cap (default 1800s).
- `JUDGE_MAX_CALLS` — refuse to prompt for confirmation above this
  survivor count (default 50).

Override per-invocation with `--max-mutants <N>`.

## Implementation steps (run as a single bash invocation)

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
bash "$PROJECT_DIR/.claude/tests/mutation/mutation-sweep.sh" "$@"
```

## Notes for Claude

- Pass `--no-judge` when the operator only wants the deterministic
  report. This is the default when in doubt — it produces no spend.
- Pass `--confirm-judge` only after the operator has explicitly
  agreed to the cost (you should ask if not stated). C.2 owns the
  judge binary; until then `--judge-cmd` is unset and the seam
  exits 0 with a "judge step ready" message.
- The report and survivors file paths are printed at the end of the
  run. Read them with the Read tool to summarise findings; don't
  re-run the sweep just to re-print the summary.
- Beads tasks are NOT written automatically. C.3 owns the
  beads-routing seam. Surviving mutants in the report.json are
  candidates a future drafter agent will turn into killing tests.
- If the run produces zero mutants, that's a valid outcome: the
  selected targets have no fault-class triggers under the current
  catalog. Consider widening `--fault-classes` or selecting
  different targets before assuming the harness is broken.

See `.claude/tests/mutation/README.md` for the cost model, the judge
seam contract, the ranking fallback, and the META-TEST convention this
tier carries.

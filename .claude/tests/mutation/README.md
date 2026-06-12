# Mutation testing (tier L3.5) — claude-workflow-plugin C.1

Phase C of the verification suite (spec: `docs/plans/verification-suite.md`,
Beads epic `claude-workflow-plugin-n45`). This directory ships the
**deterministic half** of the mutation harness:

- `fault-classes.md` — the reviewable, extensible mutation catalog.
- `mutation.conf` — caps, sentinels, command exclusions, judge budget.
- `lib/generate.sh` — per-fault-class mutant generator.
- `lib/rank-targets.sh` — target ranking (code-graph or heuristic).
- `mutation-sweep.sh` — the entry point. Generates, applies in
  worktrees, runs offline tests, classifies KILLED/SURVIVED.

The LLM judge (C.2) and the Beads / tech-debt routing (C.3) plug into
the seams documented below. C.1 ships only the deterministic pass and
the cost-confirmation gate.

## Usage

```bash
# Auto-discover targets under .claude/scripts/, run every fault class,
# stop at the cost-confirmation gate.
bash .claude/tests/mutation/mutation-sweep.sh

# Or via the Claude-invokable command (asks Claude to pick targets):
/mutation-sweep
```

Common invocations:

```bash
# Deterministic pass only, no judge prompt:
bash .claude/tests/mutation/mutation-sweep.sh --no-judge

# Scope to specific targets and fault classes:
bash .claude/tests/mutation/mutation-sweep.sh \
    --targets .claude/scripts/verify-before-stop.sh,.claude/scripts/post-edit.sh \
    --fault-classes F1,F6,F8 \
    --no-judge

# Auto-confirm the judge step (CI / scripted use):
bash .claude/tests/mutation/mutation-sweep.sh --confirm-judge --judge-cmd "$JUDGE"

# Override the run-wide cap:
bash .claude/tests/mutation/mutation-sweep.sh --max-mutants 12 --no-judge
```

Outputs land under `.claude/.mutation-runs/<timestamp>/`:

- `report.json` — the structured contract (counts, caps, per-survivor
  records, judge-cost estimate).
- `summary.txt` — the same data, formatted for terminal reading.
- `survivors.jsonl` — one row per surviving mutant; consumed by C.2.
- `mutants.txt` — every generated mutant in the wire format
  `lib/generate.sh` emits (debugging only).
- `judge-packet.json` — written only after the cost-confirmation gate
  passes; the file the judge command reads.

`.claude/.mutation-worktrees/` holds the throwaway worktrees during a
run. The harness prunes them via a trap that fires on `EXIT`, `INT`,
and `TERM`, so even a `Ctrl+C` mid-run leaves no leftovers. Both
directories are gitignored.

## Caps and budget

Defined in `mutation.conf` (shell-sourceable):

| Knob | Default | Notes |
| ---- | ------- | ----- |
| `MAX_MUTANTS_PER_FILE` | 24 | Per-target ceiling. |
| `MAX_MUTANTS_PER_RUN`  | 60 | Hard ceiling across all targets. Override with `--max-mutants <N>`. |
| `MUTANT_TEST_TIMEOUT_S` | 60 | Per-mutant wall clock. |
| `SWEEP_TIMEOUT_S`       | 1800 | Overall sweep cap. |
| `JUDGE_COST_PER_CALL_USD` | 0.03 | Cost-gate display estimate. C.2 owns the real number. |
| `JUDGE_MAX_CALLS` | 50 | Refuse to prompt above this survivor count. |

## Cost model

The deterministic pass — generate, apply in worktree, run free L1+L2 —
**costs zero API spend**. Every byte of execution is offline awk/sed
plus the existing free tier.

The judge step **costs `survivors * JUDGE_COST_PER_CALL_USD`**. C.2's
seam is the only paid component, and it is gated behind:

1. an explicit `--confirm-judge` flag, OR
2. an interactive `y/N` prompt with the cost preview, OR
3. is skipped entirely when `--no-judge` is set.

No automatic / scheduled / CI invocation of the judge exists. This
mirrors v3 principle 9 (no automatic paid runs) and 0.8 (manual live
testing only).

## Judge seam contract (C.2 owns the binary, C.1 ships the seam)

After the deterministic pass and the cost-confirmation gate, the harness
writes a single packet file:

```
.claude/.mutation-runs/<timestamp>/judge-packet.json
```

If `--judge-cmd <path>` is provided, the harness invokes:

```
<judge-cmd> --packet <path-to-judge-packet.json>
```

The judge subagent (defined at `.claude/agents/judge.md`, shipped in
C.2) reads the packet, classifies each survivor as `equivalent`
(observationally inert — no test could ever distinguish it from the
original) or `genuine` (a plausible future test could kill it), and
writes its verdict to stdout as JSON. The harness captures stdout
to `verdict.json` in the same run directory.

### Packet shape (C.1 -> C.2)

```jsonc
{
  "contract_version": "1",
  "report": ".claude/.mutation-runs/<ts>/report.json",
  "survivors": [
    {
      "id": 7,
      "fault": "F6",
      "target": ".claude/scripts/qa-gate.sh",
      "line": 142,
      "rationale": "off-by-one -gt -> -ge",
      "orig": "if [ \"$iter\" -gt \"$MAX_ITERATIONS\" ]; then escalate; fi",
      "mut":  "if [ \"$iter\" -ge \"$MAX_ITERATIONS\" ]; then escalate; fi",
      "status": "SURVIVED"
    }
    // ...
  ]
}
```

### Verdict shape (C.2 -> stdout, captured into verdict.json)

```jsonc
{
  "contract_version": "1",
  "verdicts": [
    {
      "id": 7,
      "classification": "genuine",
      "confidence": 0.92,
      "justification": "Flipping -gt to -ge shifts the escalation cap by one iteration, which is a real off-by-one regression that a sustained-load test would catch."
    },
    {
      "id": 8,
      "classification": "equivalent",
      "confidence": 0.85,
      "justification": "The mutated line is inside a code branch the tests' fixtures never reach; the mutation is observationally inert."
    }
  ],
  "calibration": {
    "precision": null,
    "recall": null
  }
}
```

The `classification` enum is `"equivalent" | "genuine"` exactly — no
other values. The `calibration` object on the judge's output is left as
null per field: precision and recall are computed by `judge-gate.sh`
against the calibration set, not estimated by the judge itself.

C.2 is the only component permitted to consume `judge-packet.json` and
write `verdict.json`. The harness does not parse the verdict — that's
C.3's concern (Beads task routing + tech-debt rows).

### Why a file packet (not piped stdin)?

The packet is reviewable on disk, replayable across multiple judge
invocations (calibration), and survives a SIGINT mid-run. Piping the
survivors over stdin would lose all three properties.

## Calibration procedure (C.2) — root-orchestrated relay

The calibration set lives at
`.claude/tests/mutation/calibration/calibration-set.json`. It is a
hand-labeled corpus of >= 20 mutants spanning all 8 fault classes
(>= 5 of them labeled `equivalent` so precision has a real denominator
of true-equivalents to discriminate against). Each entry carries the
survivor shape plus two extra fields: `ground_truth`
(`"equivalent" | "genuine"`) and `label_rationale` (the human-author's
reasoning that produced the label). The L1 suite
(`judge-calibration.test.sh`) validates the shape and the >= 20 / >= 5
contracts on every test run.

The judge is graded against this set via
`.claude/tests/mutation/judge-gate.sh`, which computes:

- **precision** = TP / (TP + FP)
  where TP = judge said genuine AND truth says genuine;
        FP = judge said genuine BUT truth says equivalent.
- **recall**    = TP / (TP + FN)
  where FN = judge said equivalent BUT truth says genuine.

The gate exits 0 iff `precision >= JUDGE_PRECISION_MIN`
(mutation.conf; default 0.8). Recall is reported alongside but is not a
gating threshold — C.2's design bias is precision over recall (better to
miss an equivalent and waste one C.3 follow-up than to bury a real
regression). Override via `--threshold <float>` if a calibration run
needs a different bar for diagnostic purposes.

The Beads task records the gate's verdict, the confusion matrix, and
the per-mutant outcomes from `calibration-report.json` so the audit
trail shows what each calibration round graded against.

### Root-orchestrated relay flow

Subagents cannot spawn other subagents — see
`code.claude.com/docs/en/sub-agents`: `Agent(agent_type)` has no effect
inside a subagent definition (lesson 4 in `LESSONS.md`). The mutation
judge is therefore **always spawned from the ROOT conversation level**,
not from another subagent. Concretely, a calibration round goes:

1. Operator runs the mutation sweep (`/mutation-sweep` or
   `make mutate`); the sweep produces `judge-packet.json` on disk.
2. The orchestrator (root) reads the packet path and spawns the
   `@judge` subagent ONCE via its own `Task` call, passing either the
   packet's inline JSON or the file path. (For calibration, the
   "packet" is the calibration set reformatted to the survivor shape —
   strip `ground_truth` and `label_rationale` before handing it to the
   judge so the labels do not contaminate the verdict.)
3. The judge classifies each survivor and returns STRICT JSON as its
   final message. The orchestrator captures stdout to
   `.claude/.mutation-runs/<ts>/verdict.json`.
4. The orchestrator runs:

   ```bash
   bash .claude/tests/mutation/judge-gate.sh \
       --verdict .claude/.mutation-runs/<ts>/verdict.json \
       --calibration .claude/tests/mutation/calibration/calibration-set.json
   ```

   Exit 0 means precision >= JUDGE_PRECISION_MIN (calibration passed).
   Exit 1 means precision < threshold. Exit 2 means malformed inputs.
   Exit 3 means precision is undefined (judge predicted zero genuine).
5. The orchestrator posts the precision and confusion matrix as a
   comment on the Beads task that owns the calibration round, then
   updates the task's status accordingly.

The judge is never spawned by another subagent. QA does not spawn the
judge; the grader does not spawn the judge; the mutation-sweep harness
does not spawn the judge. Only the root orchestrator does. Re-nesting
the spawn would be structurally unreachable per the docs (the regex in
`no-nested-spawn-instructions.test.sh` catches the regression at L1).

### Why this design

The judge's value is precision on equivalents. Generating mutants is
cheap; the filter is the product. If precision drops below the
threshold, the C.3 routing (Beads tasks + tech-debt rows) gets
contaminated by false positives faster than humans can triage them, and
the cost-to-benefit of the whole tier collapses. The gate's job is to
notice that drop before it ships and refuse the run.

The gate is run-of-mill jq + bash; it has no LLM dependency. The
calibration set is the durable artefact; the judge's prompt can be
re-tuned across calibration rounds without touching the gate or the
truth labels.

## Ranking: two paths, one always-on fallback

`lib/rank-targets.sh` chooses targets by score.

### Path 1 — code-graph (when available)

If `.claude/.code-graph/index.db` exists AND `sqlite3` is on PATH, the
ranker queries the graph for fan-in (how many places reference the
target). High fan-in -> high rank. The query is best-effort: any
sqlite error, missing table, or empty result falls back to path 2 for
that target. A code-graph database that exists but cannot answer
gracefully degrades; the sweep never aborts on a partial index.

### Path 2 — heuristic (always-on fallback)

When code-graph is absent (or fails), the score for each target is:

```
score = (test_references * 100) + line_count
```

Where:

- `test_references` is the number of files in
  `.claude/scripts/tests/` and `.claude/tests/component/specs/` that
  mention the target's basename.
- `line_count` is the script's line count.

Heavy weight on test references: a script no test mentions is a low
priority for the sweep (mutants there will all SURVIVE because no
test exercises them; surfacing that is C.3's job, not C.1's).

### Ranking-fallback proof

The L1 test (`mutation-harness.test.sh`, section 5) constructs a
fixture with no code-graph index present and confirms the sweep
produces a valid report — proving the harness runs the heuristic path
end-to-end without code-graph. The ranker also emits a stderr line on
every invocation declaring which path it took
(`# rank-targets: using code-graph path (...)` or
`# rank-targets: code-graph index not present; using heuristic fallback`)
so a sweep run can be inspected after the fact for which side it took.

## Fault classes

See `fault-classes.md` for the catalog: F1 through F8, each with
rationale, worked example, and the transform shape the generator uses.
The catalog drives the generator; the generator never emits a mutant
shape not documented there. Destructive commands (`rm`, `mv`, `git
push`, network mutators) are excluded by design — both at the catalog
level and in `mutation.conf`'s `COMMAND_EXCLUSIONS`.

## Containment

Every mutant is applied inside a fresh `git worktree --detach HEAD`
under `.claude/.mutation-worktrees/m-<run_ts>-<mutant_idx>/`. The main
checkout is **never** touched.

Three layers of cleanup:

1. The inner loop calls `git worktree remove --force "$wt"` after
   each mutant runs.
2. The trap at script setup time calls `cleanup_worktrees` on `EXIT`,
   `INT`, and `TERM`. This catches SIGINT (Ctrl+C), kill -TERM, and
   any uncaught error.
3. The trap also calls `git worktree prune` at the end to clean any
   dangling registry entries.

If `--keep-worktrees` is set (debugging only), cleanup is skipped and
the path is logged so the operator knows where to look.

### Containment proof

`mutation-harness.test.sh` sections 3 and 4 prove the main tree's
HEAD and tracked-file hashes are unchanged after a sweep, and that no
worktrees are left in either the directory or the git registry.
Section 9 strips the trap from a patched copy of the harness and
proves it then leaks at least one worktree — the META-TEST for the
containment assertion's sensitivity.

## Cost-confirmation gate

After the deterministic pass:

```
Mutation sweep summary (run 20260612T070000Z)
  targets:    7
  mutants:    35
  killed:     32
  survived:   3
  ...
  deterministic cost:  $0.00 (no paid calls in this phase)
  judge estimated:     $0.09 (3 survivors x $0.03/call)

Proceed to judge (3 calls, ~$0.09)? (y/N)
```

The gate enforces:

- Without `--confirm-judge` and without explicit `y`, the script exits
  0 — the deterministic report stays on disk, no judge call runs.
- `--no-judge` skips the gate entirely (no prompt printed).
- With `--judge-cmd <path>` AND confirmation, the judge command is
  invoked. The L1 test (section 6) proves both directions:
  unconfirmed gate blocks the sentinel command; `--confirm-judge`
  invokes it.

## What this tier proves vs. what it does NOT prove

The mutation harness proves that **the offline test suite catches the
fault classes the catalog documents**. A mutant the suite fails to
kill is either:

1. A real test gap (regression coverage missing), OR
2. A semantically equivalent mutation the catalog should not have
   produced (a generator bug), OR
3. A mutation in unreachable code (dead code worth pruning).

C.2's judge classifies each survivor as equivalent or non-equivalent
to disambiguate (1)+(3) from (2). C.3 routes the non-equivalent
survivors into Beads / tech-debt so the gap gets filled.

The harness does **not** test:

- The plugin's own runtime behaviour (that's L1/L2/L3-unit and the
  manual L3-live tier — see `.claude/tests/README.md`).
- Whether a survivor will be killed by a yet-to-be-written test —
  C.2/C.3 propose drafts; the QA gate enforces correctness.

## Adding a fault class

See the "Adding a fault class" section of `fault-classes.md`. The
contract is:

1. Append a section to the catalog (id, rationale, example, transform).
2. Add the matching `gen_<id>` function in `lib/generate.sh`.
3. Add at least one L1 test asserting the new class produces a
   killable mutant under a toy target + toy test pair.

## META-TEST convention

The L1 test ships META-TESTs for both directions:

- **Inverted kill-detection** (section 8) — if the harness treated a
  passing-tests run as KILLED, the kill-count assertion would silently
  always pass. We invert the test command and assert KILLED == 0.
- **Removed cleanup** (section 9) — if the trap were absent, the
  containment assertion would silently always pass. We patch the
  harness to strip the trap and inline cleanup, run it, and assert
  worktrees leak.

Both are the canary the spec calls out as required for the whole
mutation tier.

## File layout

```
.claude/tests/mutation/
├── README.md                  (this file)
├── fault-classes.md           (catalog)
├── mutation.conf              (caps, sentinels, budget, JUDGE_PRECISION_MIN)
├── mutation-sweep.sh          (entry point — deterministic pass + judge seam)
├── judge-gate.sh              (C.2 — precision/recall vs calibration set)
├── calibration/
│   └── calibration-set.json   (C.2 — hand-labeled ground truth, >= 20 mutants)
└── lib/
    ├── generate.sh            (per-class mutant generator)
    └── rank-targets.sh        (impact_of-or-heuristic)

.claude/scripts/tests/
├── mutation-harness.test.sh   (L1 unit tests; includes META-TESTs)
└── judge-calibration.test.sh  (C.2 — gate math + calibration validation + META-TESTs)

.claude/agents/
└── judge.md                   (C.2 — separate-context mutation judge subagent)

.claude/commands/
└── mutation-sweep.md          (/mutation-sweep — Claude-invokable wrapper)

.claude-plugin/plugin.json     (agents[] registers judge.md; commands[] registers /mutation-sweep)
```

## Phase C roadmap

- **C.1 (claude-workflow-plugin-n45.1)** — deterministic harness,
  fault-class catalog, worktree containment, cost gate,
  /mutation-sweep command, judge seam contract. **Shipped.**
- **C.2 (claude-workflow-plugin-n45.2)** — LLM judge subagent
  (`judge.md`), calibration set (`calibration/calibration-set.json`,
  hand-labeled, all 8 fault classes, >= 5 equivalents), calibration
  gate (`judge-gate.sh`, precision >= 0.8), L1 suite
  (`judge-calibration.test.sh`). Root-orchestrated relay — the judge
  is spawned from the root conversation, never by another subagent.
  **Ships with this PR.**
- **C.3 (claude-workflow-plugin-n45.3)** — Beads / tech-debt routing.
  Surviving non-equivalent mutants become drafted killing tests and
  tracked tasks.

The seams in C.1 (packet file, verdict file, no automatic writes) are
designed so C.2 and C.3 can land without touching `mutation-sweep.sh`.

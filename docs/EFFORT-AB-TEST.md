# Effort A/B interference test

This is the manual, cost-gated procedure that produces the value in
[`.claude/effort-verdict`](../.claude/effort-verdict). It answers one
question: **does launching a session at `ultracode` interfere with the
plugin's orchestrator -> specialist -> QA contract, or is plain `max` the
safer durable default?**

- **Scope:** executed under the paid task `claude-workflow-plugin-cnz.2`
  (NOT `cnz.1`, which shipped the offline wiring this runbook drives).
- **Cost:** ~$10-20 USD across the two live runs. Real spend depends on the
  active model snapshot and whether QA's block-then-recover loop fires.
  **Cost confirmation is required before starting** — do not run this on a
  schedule or from CI.
- **Output:** the verdict written back into `.claude/effort-verdict`, a
  per-criterion table on meta-task `claude-workflow-plugin-4o2`, and a
  `lessons.sh` entry.

## Why this test exists (the platform facts)

- The live docs state: *"When `CLAUDE_CODE_EFFORT_LEVEL` is set to a level
  other than xhigh, requests run at that level and ultracode's workflow
  orchestration stays inactive."* v4 therefore removed the
  `env.CLAUDE_CODE_EFFORT_LEVEL` pin; the durable floor is `effortLevel:
  xhigh` alone, and the session level is chosen at launch.
- `ultracode` is session-only (`claude --effort ultracode`, >= v2.1.203). It
  sends `xhigh` to the model **and** has Claude orchestrate its own dynamic
  workflows for substantive tasks. That second behaviour is the thing under
  test: ultracode's native workflow layer may spawn generic workflow agents
  from the main session, competing with — or bypassing — this plugin's
  orchestrator.
- `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` (pinned in settings) caps *nested*
  subagent spawning. It cannot cap agents ultracode spawns **from the main
  session** — those are depth-1 by definition.
- ultracode's hook-env proxy value is `xhigh`, so from inside a hook you
  cannot tell an ultracode session apart from a plain `xhigh` one. The
  evidence below leans on the spawn log, not on the effort value.

## Pre-registered expectation (record this before running)

State this hypothesis in the `cnz.2` task notes **before** the runs so the
result cannot be rationalised after the fact:

> ultracode's dynamic workflows are expected to spawn generic workflow agents
> (e.g. `general-purpose`) directly from the main session. The `depth=1` pin
> cannot block main-session spawns, so **criterion 4 is expected to FAIL
> under ultracode**. If it does, the verdict is `max`. Record the observed
> outcome verbatim regardless of whether it matches this expectation.

## Setup

Run each arm in a **fresh worktree copy** so neither run pollutes the other's
Beads state or `.qa-tracking/`.

```bash
# From the plugin repo root.
BASE=$(git rev-parse --show-toplevel)
git worktree add /tmp/effort-ab-ultracode HEAD
git worktree add /tmp/effort-ab-max HEAD
mkdir -p "$BASE/.claude/.qa-tracking/effort-ab/ultracode" \
         "$BASE/.claude/.qa-tracking/effort-ab/max"
```

The smoke task is the **two-domain shape** of the `multi-domain-signup`
fixture (a signup feature that needs both a backend endpoint and a frontend
form, so the orchestrator must delegate to at least two specialists and then
QA). Use the fixture's prompt verbatim:

```bash
sed -n '/^prompt:/,/^[a-z_]*:/p' \
  "$BASE/.claude/tests/e2e/fixtures/multi-domain-signup/fixture.yaml"
```

## Procedure

Do the following **twice** — once per arm. Arm A launches with
`claude --effort ultracode`; arm B with `claude --effort max`.

1. `cd` into that arm's worktree.
2. Launch the session at the arm's effort level:
   - Arm A: `claude --effort ultracode`
   - Arm B: `claude --effort max` (equivalently `make session` once the
     verdict is `max`).
3. Paste the two-domain smoke prompt and let the workflow run end to end
   (orchestrator decomposes -> specialists implement -> QA gates -> Stop).
4. When provoked, confirm the orchestrator-edit block fires: ask the
   orchestrator directly to edit a file (it must be refused by
   `prevent-orchestrator-edits.sh`, not silently allowed).
5. Copy that arm's evidence into the shared capture dir (see below) before
   tearing the worktree down.

## Pass criteria

All four must hold for an arm to "pass". Criterion 4 is the discriminating
one between `ultracode` and `max`.

1. **Orchestrator receives and delegates.** The plugin orchestrator (not
   ultracode's native workflow layer) is the first responder, opens the Beads
   epic, and routes work to specialists. Evidence: the Beads epic + child
   tasks exist and carry the domain labels; the transcript shows the
   orchestrator delegating rather than being bypassed.
2. **PreToolUse orchestrator-edit block fires when provoked.** A direct
   Write/Edit/MultiEdit attempt attributable to the orchestrator is blocked.
   Evidence: the block message in the transcript; no orchestrator-attributed
   file write in the diff.
3. **Stop-gate semantics unchanged.** The Stop hook refuses to release until
   the active task carries a hash-current `qa-approved` record. Evidence: a
   Stop was blocked pre-approval and released only after QA approved.
4. **Every spawn is a declared workflow agent.** Every line in
   `.claude/.qa-tracking/subagent-spawns.log` names an agent in the set
   `{orchestrator, qa, backend, frontend, devops, grader, judge}`. Any other
   value (e.g. `general-purpose`, `Explore`, `Plan`, or an unnamed
   ultracode-workflow agent) is a **criterion-4 failure**. Check with:

   ```bash
   cut -f2 .claude/.qa-tracking/subagent-spawns.log \
     | sed 's/^@//' | sort -u \
     | grep -vxE 'orchestrator|qa|backend|frontend|devops|grader|judge' \
     && echo "CRITERION 4 FAILED: off-list spawn(s) above" \
     || echo "criterion 4 passed: all spawns on-list"
   ```

## Evidence capture

Capture each arm's artefacts under its dir before tearing down the worktree:

```
.claude/.qa-tracking/effort-ab/ultracode/
  subagent-spawns.log      # copied from the arm's .qa-tracking/
  transcript.md            # the session transcript (or SDK trace)
  beads-tasks.json         # bd list --json snapshot of the created epic+children
  criteria.md              # the four criteria marked pass/fail with evidence
.claude/.qa-tracking/effort-ab/max/
  (same four files)
```

```bash
# Example, run inside each arm's worktree at the end of its run:
ARM=ultracode   # or: max
DEST="$BASE/.claude/.qa-tracking/effort-ab/$ARM"
cp .claude/.qa-tracking/subagent-spawns.log "$DEST/" 2>/dev/null || true
bd list --json > "$DEST/beads-tasks.json" 2>/dev/null || true
```

## Recording the verdict

Once both arms are scored:

1. **Decide the verdict.** If arm A (ultracode) fails any criterion — expected
   to be criterion 4 — the verdict is `max`. Only if ultracode passes all four
   (and offers a real benefit) is `ultracode` the verdict.

2. **Write it into `.claude/effort-verdict`.** Replace the first non-comment
   line with the verdict and remove the `# PROVISIONAL ...` marker line:

   ```bash
   # verdict is 'max' or 'ultracode'
   printf '%s\n' \
     '# .claude/effort-verdict — recorded output of the effort A/B interference test.' \
     '# See docs/EFFORT-AB-TEST.md. Consumed by `make session` + session-start Warning 4.' \
     "$VERDICT" > "$BASE/.claude/effort-verdict"
   ```

   `make session` and session-start Warning 4 pick it up automatically.

3. **Record a lesson** so the reasoning survives:

   ```bash
   bash .claude/scripts/lessons.sh add \
     'Effort A/B: <verdict> — <one-line why, e.g. ultracode spawned general-purpose from the main session, failing criterion 4>' \
     --source claude-workflow-plugin-cnz.2
   ```

4. **Comment on the meta-task** `claude-workflow-plugin-4o2` (`Model selection
   log`) with the per-criterion table for both arms and a rollback note:

   | Criterion | ultracode | max |
   | --------- | --------- | --- |
   | 1 orchestrator delegates | pass/fail + evidence | pass/fail + evidence |
   | 2 orchestrator-edit block | pass/fail | pass/fail |
   | 3 Stop-gate unchanged | pass/fail | pass/fail |
   | 4 all spawns on-list | pass/fail (off-list: ...) | pass/fail |

   Rollback note: the verdict only drives launch effort. To revert, set the
   first line of `.claude/effort-verdict` back to `max` (or delete the file —
   `make session` defaults to `max`). No settings or agent pins change.

5. **Tear down the worktrees:**

   ```bash
   git worktree remove /tmp/effort-ab-ultracode
   git worktree remove /tmp/effort-ab-max
   ```

## Notes

- This test does not modify `settings.json`, agent frontmatter, or any hook.
  The only durable artefact it changes is `.claude/effort-verdict`.
- The `.claude/.qa-tracking/` tree is gitignored, so the captured evidence is
  local-only; summarise it in the `4o2` comment for the durable record.
- If the runbook itself needs to change (new criterion, different fixture),
  update it under a fresh task and note the change in the `cnz.2` comment.

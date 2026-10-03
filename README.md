# Claude Workflow Plugin

A plugin for [Claude Code](https://claude.ai) that turns "build me a feature"
into a tracked, reviewed, regression-tested change set — without you driving
every step.

[![Beads Required](https://img.shields.io/badge/Beads-Required-blue)](https://github.com/steveyegge/beads)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Compatible-green)](https://claude.ai)

## 🎯 What you get

- **Plain-English in, structured work out.** Describe a feature. The
  orchestrator breaks it into a Beads epic with subtasks, routes each
  subtask to a domain specialist (backend / frontend / devops / qa) that
  already knows OWASP, performance budgets, accessibility patterns, and
  root-cause analysis, and ships nothing until QA approves.
- **A QA gate that's a real Stop hook.** Claude literally cannot release
  the conversation without `qa-approved` on the active task. The decision
  is recorded in Beads as a label and a comment — full audit trail, no
  honour system. The label alone is not enough: the Stop hook releases
  only when the approval comment carries a `change_set_hash` matching the
  current diff, so a forged `qa-approved` label (added without
  `qa-gate.sh approve`) does not pass the gate.
- **Tasks survive sessions.** Specialists auto-claim work via
  `bd update --status in_progress`. GitHub issue auto-linking is provided
  (`bd-github-link.sh`: posts a back-link comment on task close and parses
  `Closes #N`); its call shapes are verified by the `bd-github-link` L1
  test against a stubbed `gh`, not a live round-trip. Pick up tomorrow
  where you left off tonight.
- **A separate-context rubric grader gates every QA approval.** Before
  QA signs off, a read-only `grader` subagent scores the work against
  a versioned rubric (default + per-domain overlays + a bugfix overlay
  for evidence-before-fix). The grader sees only the diff, the SPEC,
  and the lessons ledger — no specialist conversation context — so its
  verdict is independent. Iteration cap is binding and engages the
  escalation path on cap-hit.
- **Optional: an external reviewer lane (Sol via Codex).** Every QA
  cycle records an independent review artifact. By default the
  plugin's own fresh-context Claude path authors it, for free. If you
  install and register the OpenAI Codex CLI at user scope, that same
  artifact comes from Sol instead — a second model family reading the
  same diff. It is strictly optional and purely advisory: it writes no
  labels, records no approval, and with Codex absent the workflow is
  byte-identical (proved by a degradation spec, not asserted). The
  review turn is manual and cost-confirmed, and it meters your own
  OpenAI account. See
  [The model-role-class workflow](#-the-model-role-class-workflow)
  below; setup, billing, and troubleshooting:
  [`docs/CODEX_SETUP.md`](docs/CODEX_SETUP.md).
- **Two MCP servers ship in the box.** `bd-mcp` exposes 21 typed Beads
  tools (no shell quoting bugs). `code-graph-mcp` exposes 7 graph tools
  (`code_search`, `code_context`, `symbol_callers`, `impact_of`,
  `dead_code`, `dependency_path`, `code_index_health`) backed by a
  tree-sitter + SQLite index. Both load automatically via `.mcp.json`
  and `${CLAUDE_PLUGIN_ROOT}`.
- **Regression coverage by construction.** Every QA iteration runs the
  full test suite. A module-A edit that breaks module-B's contract is
  caught before approval, not after. The plugin's own test pyramid (L1
  bash unit → L3 vitest unit → L3 live e2e → L3.5 mutation tier)
  demonstrates the pattern. Live tests are invariant-based, manual
  only, and the CI consumes zero API spend per PR.
- **On-demand mutation sweep with a calibrated LLM judge filter.**
  `/mutation-sweep` generates fault-class mutants for hook scripts,
  runs them in throwaway git worktrees against the free L1/L2 tiers,
  and routes survivors through a read-only `judge` subagent
  calibrated against a hand-labeled set (precision ≥ 0.8). Every
  step is dev-cycle-manual — no CI wiring, no scheduled job, no
  automatic paid call.
- **Lessons ledger as institutional memory.** `LESSONS.md` is
  append-only via `lessons.sh add`; the orchestrator reads it before
  decomposing non-trivial work; the grader reads it as part of every
  grading packet. The two seed lessons (parallel-agent worktree
  isolation; boundary-mock fidelity) shipped with v3.1.0.

## 🧠 The model-role-class workflow

Five role classes, one gate. `.claude/model-roles` maps each **role** to a
selection **strategy**, and `model-select.sh` re-resolves every lane at
session start — so each class auto-adopts the newest model in its own
tier without anyone editing a version string.

| Role | Agents | Strategy | Resolves to |
|------|--------|----------|-------------|
| `designer` | `designer` | `top` | the resolver's single best pick — the newest, most capable family in your account listing |
| `design_reviewer` | `design-reviewer` | `top` | same pick as `designer`; the optional external lane routes design review to Sol via Codex when connected, which is what keeps the two from reviewing each other under the same identity |
| `orchestrator` | `orchestrator` | `opus-class` | the newest `claude-opus-*` model listed, falling back to `top` when your account lists none |
| `implementer` | `backend`, `frontend`, `devops` | `sonnet-class` | the newest `claude-sonnet-*` model listed, falling back to `top` when your account lists none |
| `reviewer` | `qa`, `grader`, `judge` | `opus-class` | the newest `claude-opus-*` model listed; the optional external lane routes the review turn to Sol via Codex when connected |

The model each lane lands on is **resolver output, not configuration**.
Read the live mapping with `bash .claude/scripts/model-select.sh roles`
(prints `role  strategy  resolved-id`), see it in the statusline (fixed
render order `des dsr orch impl rev`, roles sharing a resolved model
joined with `+`, at most three groups printed before the tail becomes
` +<k> more`, collapsing to the single-model shape only when **all five**
roles resolve to the same id *and* both review lanes are `claude`), and
override with `/workflow-model`. Setting every role to `top` in
`.claude/model-roles` reproduces the v3.5 single-model behavior exactly.

### Nobody signs off on their own work

This is a gate rule, not a prompt. The change-set-hash-bound `qa-approved`
record is the **only** release credential, and since v4.0.0
`qa-gate.sh approve` refuses (exit 4) unless both hold:

1. the task carries a **review artifact** whose `reviewer_identity` differs
   from every implementer recorded for that task — `subagent-start.sh`
   writes `IMPLEMENTER: role=<backend|frontend|devops> task=<id>` at spawn,
   so identity is captured by the harness, not self-declared; and
2. **zero findings** at or above the review's `risk_threshold` are still
   open.

`verify-before-stop.sh` re-runs the *same* predicate before releasing the
Stop hook, because findings can arrive after an approval and a write-once
record cannot know about them. Both ends call one counter
(`review-check.sh gate`) — there is no second implementation of it, and no
second way to release. A missing or unrunnable counter fails **closed** at
both ends.

### An approval can bind nothing — and v5.0.0 refuses the worst case

The credential above binds a **change set**, and through v4.1 that change set
could be silently empty. The tracker behind it is fed by a `PostToolUse` hook
on `Write|Edit|MultiEdit|NotebookEdit` — **not `Bash`** — so a file you edit in
vim, in your IDE, or from a shell script never enters it. Work that pre-dates
the session is invisible for the same reason: the gate's baseline treats
anything already in the tree as pre-existing. Approve over either and you get:

```
impact-report.sh --hash-only   ->  e3b0c442…855      # sha256 of empty input
approve                        ->  "impact-report verified (change_set_hash match)"
```

An approval bound to that hash covers zero files, permanently, no matter what
is in your tree. **v4.1 does not warn about this. It says "verified".**

v5.0.0 refuses the total case and only warns on the partial one:

| Situation | v5.0.0 |
|---|---|
| **None** of the declared files in the bound change set, and at least one of them is not denylisted | **refuses**, `error_key=completion_files_total_miss`, and names the recovery commands |
| **None** of them, but *every* declared file is denylisted | **approves** — deliberately: that is the legitimate all-denylisted case, not a swallowed tracker |
| **Some** of them missing | **warns** (`completion_files_crosscheck`) and still approves |
| No completion record at all | **refuses** — separately, because nothing states what was done |

A partially-wrong change set is still bindable. The rewrite that closes the
whole family (`claude-workflow-plugin-qnvo`) is implemented and independently
verified, preserved on branch `qnvo/primitive-replacement` at `1f4bd81`, and
**deferred to v5.0.1** — it broke six test specs, and that fixture work needs
its own design. (Its own task record shows a QA block: that block is what
established the six-spec floor, and is why it is deferred rather than shipped.)

### Arbitration

When the implementing specialist disputes a finding, exactly two things
clear it and nothing else does:

- **Resolve with evidence** — `qa-gate.sh resolve-finding <tid> <finding-id>
  --fix '<ref>' --test '<ref>' '<summary>'`. Both refs are mandatory; this
  is the evidence-before-fix protocol as a record.
- **Arbitrate** — `qa-gate.sh arbitrate <tid> <finding-id>
  <overrule|sustain> '<rationale>'`. `overrule` clears the gate count;
  `sustain` keeps the finding OPEN as the audit record of a dispute that was
  heard and upheld — which is what makes an overrule mean anything.

Arbitration is the **orchestrator's** job: the reviewer and the author are
the two parties, so only the third can adjudicate, and the rationale must
cite both positions.

### The optional Sol lane

The reviewer role runs on the plugin's own fresh-context Claude path by
default, for free. Install and register the OpenAI Codex CLI at user scope
and the same artifact comes from Sol instead — a second model family reading
the same diff. It is strictly optional and purely advisory: it writes no
labels, records no approval, the review turn is manual and cost-confirmed,
and it meters your own OpenAI account. With Codex absent, failed, or timed
out, the workflow is byte-identical (proved by a degradation spec, not
asserted). Setup, billing, model tracking, and troubleshooting:
[`docs/CODEX_SETUP.md`](docs/CODEX_SETUP.md).

### Effort policy

Three layers, and none of them is a model-version pin:

- **Floor** — `.claude/settings.json` `effortLevel: "xhigh"`, the highest
  value that field accepts. Persists across sessions.
- **Session level** — `.claude/effort-verdict`, currently **`max`**,
  recorded by the A/B interference test in
  [`docs/EFFORT-AB-TEST.md`](docs/EFFORT-AB-TEST.md). Launch a working
  session with `make session`, which reads the first non-comment line of
  that file and execs `claude --effort <verdict>` (defaulting to `max` when
  the file is missing or empty).
- **Ceiling** — every agent's frontmatter `effort: max`, the durable
  per-agent maximum.

Honest limit: `ultracode` is session-only and its hook-environment proxy is
`xhigh`, so a session launched at ultracode is indistinguishable from a
plain xhigh session from inside the plugin. SessionStart therefore *detects
and warns* when the live effort, the floor, and the verdict disagree —
detect-and-warn is the ceiling here, and the plugin does not claim to
enforce the session level.

## 📐 The design phase (v5.0.0) — **opt-in**

**This phase is opt-in in v5.0.0.** You opt IN by running it:
`qa-gate.sh grilling-record` → `design-record` → `design-review-record` until
`design-satisfied` holds. A task with no design phase takes the ordinary
documented exit at approve — `--no-design '<reason>'` — and the reason is
recorded in the approval comment. Neither path is new; both are pre-existing
semantics.

**Why opt-in, stated plainly:** `design-conform` has been observed on a real
target project exactly twice, and both observations were vacuous — it reported
"conforms" while naming the files that had just been written as untouched,
because the change set it read was empty. Until that is fixed, the design
phase's conformance check is not something to rely on.

The coherence rollup has a defect of the same shape, independently — it skips
the conformance leg and reads the same session-scoped tracker itself. Two
qualifications, because the evidence here is weaker and the effect narrower
than above, and saying so is the point:

- **Never observed.** The rollup has never been run on a real target, in either
  direction — it returns not-applicable without checking anything when the task
  is not itself a satisfied design task, which is the ordinary case for a
  task-per-unit child. So this is an inference from reading the code, not
  something we watched happen.
- **Narrow.** Scope is checked by two arms and only one reads the tracker. An
  empty change set costs you the *under-coverage* direction — "a file was
  touched that no unit covers". The other direction, "a unit's completion
  contract claims a file no unit declares", reads persisted records and still
  fires, as do the untested-criterion, unmapped-unit and moved-artifact-hash
  checks.

**What it costs**, measured on a real product repository. Measured gate-`enter`
to change-set-bound approval, from that project's own Beads store:

| Path | Time | Rounds | Outcome |
|---|---|---|---|
| Default, small code change | **3m57s** | 1 | approved |
| Default, doc-only change | **17m51s** | 1 | approved |
| Design, one small unit | **12m10s** | 1 | approved, but bound an empty change set |

That last row is the gate cycle only. The cost you are actually opting into is
the design phase that runs before implementation starts: **2h08m16s**, from the
design task being created to the design review returning `satisfied`, across
three review rounds (two `needs_revision`, one `satisfied`), producing a
49,512-byte artifact. Budget against that number. No total-elapsed figure is
given: the validation run spans an overnight gap, so a wall-clock total would
not mean anything.

And it did **not** reach a meaningful approval — the approval it produced bound
an empty change set.

Before any implementation task exists, a `designer` produces a design
artifact and a `design-reviewer` scores it against `.claude/rubrics/design.md`
through a review loop. **On a stock install those two roles resolve to the
SAME model** — both are `top` — so the design is reviewed by its own identity
family. The resolver reports that rather than blocking it: it sets
`identity_collapse: true`, writes `.claude/.qa-tracking/design-family-collapse`,
warns at SessionStart, and the statusline shows `!id`. What IS enforced
mechanically is narrower — `qa-gate.sh design-record` refuses a verdict whose
`reviewer_identity` equals the designer's. **Design review is Claude-lane only
in v5.0.0.** `design_reviewer_lane` is resolved and displayed, but no script
drives design review through Codex — `design-reviewer.md` instructs the agent
to emit `design-claude` unconditionally, and it has no tool to read the lane.
Worse, installing Codex sets the lane to `codex`, which makes
`identity_collapse` report **false** while both roles still resolve to the same
model — a cleared flag over an uncleared risk (`claude-workflow-plugin-yvpe`).
**The one real clearance today is to set `design_reviewer` to a family-class
distinct from whatever `top` resolves to** (e.g. `design_reviewer=opus-class`)
in `.claude/model-roles`; that changes the resolved model rather than a label.
Implementation
then runs green-to-green per unit, and a coherence rollup blocks approval
while any acceptance criterion is untested or any touched file falls outside
every declared unit.

**Design artifacts live in your repository, as files.** The path is
`docs/specs/<task-id>.md`, derived from the task id — the same derivation
`qa-gate.sh design-record` enforces, so there is exactly one path to check.
The directory is created on demand in your project the first time the design
phase runs; it does not ship with the plugin.

**v5 ships no Linear integration.** There is no design-store adapter, no
external issue-tracker write path, and nothing to configure. Design artifacts
are files in your repo and task state is in Beads. If you read anywhere that
a Linear path exists, that text is wrong — there is no Linear path for one to
work.

**Parallel batching is file-set-only.** Two units are scheduled concurrently
when their declared file sets do not intersect. The `impact_of` half of the
intersection check described in the design is **deferred**
(`claude-workflow-plugin-l7gd`), and every batch readout says so with
`graph_intersection_computed:false` rather than degrading silently. See
Caveats for what that means in practice.

## ⚡ Install

The plugin requires Beads (`bd`) ≥ 1.1.2 and `jq`. The installer fails
fast if either is missing, and on an older bd it REFUSES before writing
any plugin file and prints the upgrade procedure. v5 raised this floor from v4's
0.47, and on 0.47.x the upgrade is a one-way storage-engine migration
(SQLite to embedded Dolt): back up `.beads/` first, then install exactly
bd 1.1.2, the version measured to migrate a 0.47.x store (bd 1.3.1 refuses
one outright). The installer does not upgrade bd itself unless you supply
the command (`BD_UPGRADE_COMMAND`, plus `CWP_BEADS_UPGRADE=1`), and it
refuses if that upgrade fails or leaves bd below 1.1.2. `--skip-beads-upgrade`
only stops that upgrade from running; it never admits an older bd.

### Fresh install

```bash
# curl-pipe (no clone needed)
curl -fsSL https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.sh | bash

# or clone-and-run
git clone https://github.com/preql-data/claude-workflow-plugin
cd claude-workflow-plugin
bash install.sh /path/to/your/project
```

### Upgrade from v2

The installer auto-detects v2 layouts (no `model:` frontmatter, no
`.claude-plugin/plugin.json`, no MCP servers) and migrates them. You can
also force upgrade mode explicitly:

```bash
# auto-detects v2 and migrates
curl -fsSL https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.sh | bash

# explicit upgrade
curl -fsSL https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.sh | bash -s -- --upgrade
```

Migration copies the existing `.claude/` to `.claude-v2-backup-<timestamp>/`
before writing v3 files, so user customizations are recoverable. Run the
diff after install to see what changed:

```bash
diff -r .claude-v2-backup-*/ .claude/
```

### Windows

```powershell
irm https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.ps1 | iex
```

PowerShell detects v2 layouts but does **not** perform the migration —
it prints a message asking you to run `install.sh` (via WSL or Git Bash)
for the upgrade. Fresh installs: PowerShell installer provided; verified
by parity inspection, not execution. (An executable check —
`.github/workflows/windows-install.yml`, a `workflow_dispatch` job that
runs `install.ps1` on `windows-latest` and asserts the rendered install
plus an MCP stdio boot-check — is committed but has not been dispatched:
publishing it requires a token with the GitHub `workflow` scope.)

### Supported bd range

The hooks and MCP servers are verified against `bd $(bd --version)` by
`.claude/tests/component/specs/bd-compat.sh`, which pins all 32 bd
invocations the production scripts depend on — exit codes, JSON shapes,
id formats, and the `BD_NO_DAEMON` flush/export path. Supported range:
**>= 1.1.2**, the floor the installer enforces (see Install), with no known
upper break. That spec is the compatibility
oracle: after upgrading bd, run it to certify the new version (it prints
the detected `bd --version` in its header and fails loudly, naming the
exact command, on any output-shape mismatch):

```bash
bash .claude/tests/component/run.sh --filter bd-compat
```

Separately, `workflow-doctor.sh`'s `beads` check validates the **embedded-
Dolt schema** of a *local* bd store — a narrower, different question from
CLI compatibility above, because bd silently auto-migrates a local store's
schema on first run of a newer binary, with no confirmation and no opt-out.
The schema number does not order with bd's release number (measured
2026-09-27, claude-workflow-plugin-we57: bd 1.2.2 ships schema 53, *lower*
than 1.2.1's 65 — it is the documented rollback of 1.2.1's migration), so
this is a **validated SET of exact `bd:schema` pairs**, membership-tested,
not a floor or an interval:

| bd version | schema | status |
|---|---|---|
| 1.1.2 | 53 | pair measured directly; CI floor coverage **UNCONFIRMED** — see below |
| 1.2.1 | 65 | measured, not validated — no suite exercises it |
| 1.2.2 | 53 | measured, not validated — no suite exercises it |
| 1.3.0 | 66 | validated — its own CI lane (`l1-doctor-bd-max`) and the development host |
| 1.3.1 | 66 | validated — the CI ceiling, its own lane (`l1-doctor-bd-1-3-1`); it refuses a 0.47.x store, so it cannot be the upgrade bridge |

**Why the floor row says UNCONFIRMED** (claude-workflow-plugin-wyt3, 2026-10-02).
`1.1.2:53` is a correct pair — a store created by bd 1.1.2 reports schema 53
under the doctor's own query, measured directly. What is NOT established is
that CI's `l1-unit` lane exercises it. That lane installs bd 1.1.2 from a
pinned, sha256-verified tarball, yet the doctor running inside it reported
`installed bd 1.3.1 / store schema v66`. The cause, found by hashing bd
before and after every spec: `installer-flags.test.sh` drove `install.sh`
below its bd floor with a fake old bd, and the installer's then-default
upgrade (an unpinned `curl | bash`, never in a released version) replaced the
job's bd mid-suite with the newest release. Before bd 1.3.1 was published the
same lane would have observed `1.3.0:66` — a set member — and passed. So its
green history is consistent with never having measured the floor at all, and
this row will not claim otherwise until the lane is shown to measure 1.1.2.
That default is gone, the test runner stubs the upgrade command for every
spec, and it fails any spec that replaces a bd binary on `PATH` or at a
default install location. The 1.3.0 and 1.3.1 rows are unaffected: neither
lane runs `installer-flags.test.sh`; each runs only `workflow-doctor.test.sh`
against the bd it pins.

A live pair inside the set PASSes the doctor's `beads` check (the note names
which member matched); a pair outside it — including the two measured-but-
unvalidated rows above — FAILs as `bd-version-vs-schema DRIFT`, which is what
converts a silent bd self-upgrade back into a reviewed one instead of a
missed one. See `DOCTOR_BD_SCHEMA_VALIDATED`'s own header comment in
`.claude/scripts/workflow-doctor.sh` for the full measurement method and the
procedure for adding a pair once it gains suite coverage, and run the doctor
to check your own install:

```bash
bash .claude/scripts/workflow-doctor.sh
```

## 📦 What you get on disk

Counts re-derived from the tree on 2026-09-18 for the v5.0.0 release
(claude-workflow-plugin-fkm.9), not carried forward from the v4.1.0
release audit. The command behind each changed row is in that row.

| Component | Count | Where |
|-----------|-------|-------|
| Agents | 9 | `.claude/agents/{orchestrator,designer,design-reviewer,qa,backend,frontend,devops,grader,judge}.md` — `ls .claude/agents/*.md \| wc -l` |
| Shell scripts | 29 | `.claude/scripts/*.sh` (`ls .claude/scripts/*.sh \| wc -l`) — of which **7** are hook entry points, wired across **7** hook events (`SessionStart`, `UserPromptSubmit`, `SubagentStart`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd` — `jq '.hooks\|keys\|length' .claude/settings.json`); the rest are helpers the agents and hooks call (`qa-gate`, `epic-gate`, `impact-report`, `review-check`, `workflow-doctor`, `workflow-manifest`, `worktree-sweep`, `model-select`, `codex-detect`, `lessons`, `statusline`, …) |
| MCP servers | 2 | `.claude/mcp/{bd-mcp,code-graph-mcp}/` — 21 and 7 tools respectively; `bash .claude/scripts/workflow-doctor.sh` spawns both and asserts those exact counts |
| Rubrics | 6 | `.claude/rubrics/{default,backend,frontend,devops,design}.md` + `bugfix.md` overlay — `ls .claude/rubrics/*.md \| wc -l` |
| Slash commands | 3 | `.claude/commands/{workflow-model,mutation-sweep,workflow-doctor}.md` |
| Skills | 1 | `.claude/skills/workflow-engine/SKILL.md` — the only registered skill, and `plugin.json`'s `skills[]` array is asserted to be length 1 by `vendored-skills.test.sh` |
| Vendored reference | 1 | `.claude/vendor/superpowers/` — `brainstorming/SKILL.md` from `obra/superpowers` at pin `3dcbd5c4` (MIT), plus `MANIFEST.md` and `LICENSE.upstream`. Deliberately **not** under `.claude/skills/` and **not** registered: an explicit `Read` in `orchestrator.md` loads it exactly where it is wired instead of session-wide. Provenance and the ten local modifications are in `MANIFEST.md`; see also `THIRD_PARTY.md` |
| Test tiers | L1 + L2 + L3 unit + L3 live + L3.5 mutation | `.claude/scripts/tests/` + `.claude/tests/{component,e2e,mutation}/` |
| Lessons ledger | 1 | `LESSONS.md` (append-only via `lessons.sh add`) |
| CI | GitHub Actions | `.github/workflows/test.yml` (lint + offline tiers; live tier `workflow_dispatch`-only; zero API spend per PR) |

The plugin manifest is at `.claude-plugin/plugin.json`. The MCP wiring
is at `.mcp.json`. The plugin manifest uses `${CLAUDE_PLUGIN_ROOT}`
(plugin scope substitutes this directly); the project-scoped `.mcp.json`
uses `${CLAUDE_PROJECT_DIR:-.}` (the default form per the Claude Code
MCP docs — bare `${CLAUDE_PROJECT_DIR}` produces a diagnostics warning
in project scope).

## 🛠 Customize / contribute

The plugin is designed to be modified by the people using it. The
workflow that ships in this repo runs ON this repo too — you can use
the plugin to upgrade itself.

To customize for your team:

1. Clone:
   ```bash
   git clone https://github.com/preql-data/claude-workflow-plugin
   cd claude-workflow-plugin
   ```

2. Open the cloned repo in Claude Code. The plugin loads automatically.

3. Describe what you want to change in plain English:
   - "Add a security specialist that reviews every backend change"
   - "Change the QA gate to require 80% test coverage before approval"
   - "Add a slash command that creates a fresh Beads epic from a spec doc"

   The orchestrator will create a Beads epic, route the work to the
   right specialist, and run it through the QA gate.

4. Claude will create a feature branch for the change. When QA approves,
   you commit and push. Open a PR upstream if it's a generally-useful
   addition.

The full contributor guide is in [`CONTRIBUTING.md`](CONTRIBUTING.md).
The test pyramid documentation in
[`.claude/tests/README.md`](.claude/tests/README.md) explains how to add
tests for your changes.

## 📐 Architecture

The orchestrator never edits code; specialists do, gated by QA. Hooks
enforce that contract — `prevent-orchestrator-edits.sh` blocks Write/Edit
from the orchestrator role, and `verify-before-stop.sh` refuses Stop
without `qa-approved` on the active task. Cross-repo work and GitHub
auto-linking land via I3/I8 hooks (`bd-github-link.sh`,
`current-task.sh`). Three of the nine agents are spawned from the root
conversation only (the `grader` for rubric verdicts, the `judge`
for mutation classification, and the `design-reviewer` for design
verdicts) because Claude Code subagents cannot spawn other subagents —
all three arrive via root-orchestrated relays (`RUBRIC-RELAY`,
`JUDGE-RELAY`, and the design relay). The nine agents ride five model
role classes (`designer`, `design_reviewer`, `orchestrator`,
`implementer`, `reviewer`), each pinned to a *strategy* rather than a
model version in `.claude/model-roles`.

For the deep dive, read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
For the test pyramid that gates every change, read
[`.claude/tests/README.md`](.claude/tests/README.md). For the release
notes — v4 (tri-model workflow, role-aware models, the Sol lane, sign-off
separation, worktree-aware gate scoping) and the v3 line (G8 harness, MCP
servers, rubric loop, code-graph MCP, mutation tier) — read
[`CHANGELOG.md`](CHANGELOG.md). Every shipped claim is tracked with its
evidence pointer in [`docs/RELEASE_AUDIT.md`](docs/RELEASE_AUDIT.md).

## ⚠ Caveats

- **File-disjoint units can still conflict semantically, and nothing catches
  that automatically.** Parallel batching proves that two units touch no file
  in common; it does not prove they are behaviourally independent. The
  `impact_of` half that would strengthen this is deferred
  (`claude-workflow-plugin-l7gd`), and its own precondition
  (`claude-workflow-plugin-kk9y`) is that the code indexer resolves call edges
  through `"$SCRIPT_DIR/other.sh" --flag`-style invocations, which it does not
  yet — so building the impact half alone would add a conjunct that is
  uninformative on shell-heavy repositories. Worktree isolation for batch
  members is an orchestrator responsibility, not something the batching
  mechanism allocates or records, so a later unit's full-suite run cannot be
  relied on to see an earlier unit's changes. **Run the cross-cutting
  integration sweep yourself after a parallel batch; the gate does not do it
  for you** — `epic-gate.sh` calls it "recommended", which means exactly that.
- Live e2e runs cost roughly $5–10 per fixture against the
  SessionStart-resolved models (whichever family/tier the resolver picks
  for each role per `.claude/model-roles`, honouring the exclusions in
  `.claude/model-ranking`; the active pins are shown in the statusline
  and tracked on the "Model selection log" Beads meta-task). Since v4.0.0
  the implementer lane can ride a different tier from the orchestrator
  and reviewer lanes, so per-fixture cost varies with the resolved split.
  The offline gate (`make test-all`) is free and covers L1 + L2. As of
  v3.1.0, live runs are MANUAL ONLY: `make test-live FIXTURE=<name>`
  prints the estimated cost and prompts for confirmation before
  spending. There is no scheduled CI run that consumes API spend, and
  no automatic per-PR live tier. Live assertions are model-agnostic
  invariants declared in each fixture's `fixture.yaml` — goldens are
  retained as debugging references only.
- The mutation tier (`/mutation-sweep`, v3.4.0) is also dev-cycle
  manual. The deterministic pass — generate, apply in worktree, run
  L1+L2 — is free; the judge step is gated behind `--confirm-judge`
  or an interactive y/N prompt with a per-call cost estimate (default
  `JUDGE_COST_PER_CALL_USD=0.03`). EOF stdin defaults to N so a
  scripted invocation can never trip a paid call without an explicit
  `--confirm-judge` flag. Judge precision is reported on every run
  against the hand-labeled calibration set (default threshold 0.8).
- The upstream `bd` daemon has a stack-overflow on stale locks. A
  `--no-daemon` shim that sidesteps it ships **only inside the e2e test
  fixtures** (`.claude/tests/e2e/fixtures/<name>/.claude/bin/bd`, resolved
  onto `PATH` per-fixture by the harness — `beadsCapture.ts:169`); the
  installer does **not** place a shim on a production install (no
  `.claude/bin/` is rendered). If you hit the daemon bug on a real
  install, invoke `bd --no-daemon <subcommand>` yourself.
- AgentLint flags a few intentional design choices (Bash auto-approve,
  tag-pinned actions); rationale is in [`CONTRIBUTING.md`](CONTRIBUTING.md)
  under "Design overrides vs. AgentLint".
- If `bd` or `code-graph` show as failed or not spawned after install (e.g.
  `/mcp` lists them as "⏸ Pending approval"), see the **Troubleshooting**
  subsection in [`docs/MCP_SERVERS.md`](docs/MCP_SERVERS.md) — usually a
  workspace-trust re-accept (v2.1.196+) or a hand-edited `.mcp.json` missing
  the `${CLAUDE_PROJECT_DIR:-.}` form or `"type":"stdio"`.

---

<div align="center">

[Report Bug](../../issues) • [Request Feature](../../issues) • [Docs](docs/) • [Changelog](CHANGELOG.md)

</div>

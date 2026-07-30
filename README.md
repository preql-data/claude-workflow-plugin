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
  OpenAI account. See [The tri-model workflow](#-the-tri-model-workflow)
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

## 🧠 The tri-model workflow

Three classes of agent, three model lanes, one gate. `.claude/model-roles`
maps each **role** to a selection **strategy**, and `model-select.sh`
re-resolves every lane at session start — so each class auto-adopts the
newest model in its own tier without anyone editing a version string.

| Role | Agents | Strategy | Resolves to |
|------|--------|----------|-------------|
| `orchestrator` | `orchestrator` | `top` | the resolver's single best pick — the newest, most capable family in your account listing |
| `implementer` | `backend`, `frontend`, `devops` | `opus-class` | the newest `claude-opus-*` model listed, falling back to `top` when your account lists none |
| `reviewer` | `qa`, `grader`, `judge` | `top` | the top pick for the fresh-context Claude review path; the optional external lane routes the review turn to Sol via Codex when connected |

The model each lane lands on is **resolver output, not configuration**.
Read the live mapping with `bash .claude/scripts/model-select.sh roles`
(prints `role  strategy  resolved-id`), see it in the statusline
(`orch:… impl:… rev:…`, collapsing to the single-model shape only when all
three lanes resolved to the same id *and* the reviewer lane is `claude`),
and override with `/workflow-model`. Setting every role to `top` in
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

## ⚡ Install

The plugin requires Beads (`bd`) ≥ 0.47 and `jq`. The installer fails
fast if either is missing and prints the upgrade command.

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
**>= 0.47.x** with no known upper break. That spec is the compatibility
oracle: after upgrading bd, run it to certify the new version (it prints
the detected `bd --version` in its header and fails loudly, naming the
exact command, on any output-shape mismatch):

```bash
bash .claude/tests/component/run.sh --filter bd-compat
```

## 📦 What you get on disk

Counts re-derived from the tree on 2026-07-30 for the v4.1.0 release audit,
not carried forward from the previous release.

| Component | Count | Where |
|-----------|-------|-------|
| Agents | 7 | `.claude/agents/{orchestrator,qa,backend,frontend,devops,grader,judge}.md` |
| Shell scripts | 26 | `.claude/scripts/*.sh` — of which **7** are hook entry points, wired across **7** hook events (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SubagentStart`, `SessionEnd`); the rest are helpers the agents and hooks call (`qa-gate`, `impact-report`, `review-check`, `workflow-doctor`, `workflow-manifest`, `worktree-sweep`, `model-select`, `lessons`, `statusline`, …) |
| MCP servers | 2 | `.claude/mcp/{bd-mcp,code-graph-mcp}/` — 21 and 7 tools respectively; `bash .claude/scripts/workflow-doctor.sh` spawns both and asserts those exact counts |
| Rubrics | 5 | `.claude/rubrics/{default,backend,frontend,devops}.md` + `bugfix.md` overlay |
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
`current-task.sh`). Two of the seven agents are spawned from the root
conversation only (the `grader` for rubric verdicts and the `judge`
for mutation classification) because Claude Code subagents cannot
spawn other subagents — both arrive via root-orchestrated relays
(`RUBRIC-RELAY` and `JUDGE-RELAY`).

For the deep dive, read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
For the test pyramid that gates every change, read
[`.claude/tests/README.md`](.claude/tests/README.md). For the release
notes — v4 (tri-model workflow, role-aware models, the Sol lane, sign-off
separation, worktree-aware gate scoping) and the v3 line (G8 harness, MCP
servers, rubric loop, code-graph MCP, mutation tier) — read
[`CHANGELOG.md`](CHANGELOG.md). Every shipped claim is tracked with its
evidence pointer in [`docs/RELEASE_AUDIT.md`](docs/RELEASE_AUDIT.md).

## ⚠ Caveats

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

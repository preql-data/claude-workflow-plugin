# Changelog

All notable changes to the Claude Workflow Plugin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Versioning

- **Major** (`X.0.0`): Breaking changes to the plugin shape -- the install
  layout, the agent contract, the hook output schema, or the QA gate semantics.
  Operators may need to re-run the installer in fresh mode.
- **Minor** (`x.Y.0`): New capabilities (a new agent, a new slash command, a
  new hook event). Existing installs continue to work; fresh install picks up
  the new feature.
- **Patch** (`x.y.Z`): Bug fixes, doc updates, internal refactors, prompt
  tightening. No behavior changes for the operator.

## [Unreleased]

No unreleased changes. The next release entry will go here.

## [3.4.0] - 2026-06-12

Phase C of the verification-suite plan (`docs/plans/verification-suite.md`):
the mutation-testing tier (L3.5). Ships an on-demand sweep that generates
fault-class mutants for hook scripts, contains them in throwaway git
worktrees, runs the free L1/L2 tiers against each, and filters surviving
mutants through a separate-context `@judge` subagent calibrated against a
hand-labeled set (precision 0.9412 on the 24-mutant corpus, threshold
0.8). Every step is dev-cycle-manual — `make mutate` or `/mutation-sweep`
— with zero CI wiring, zero scheduled jobs, and zero automatic paid
calls. The acceptance sweep over `verify-before-stop.sh` + `post-edit.sh`
produced 32 mutants (4 killed by the existing suite, 28 survived); the
judge classified 27 genuine + 1 equivalent; survivor 12 (a cache-replay
control-flow regression that bypassed the test suite while still
reporting "technical checks passed") was killed with 8 new L2
assertions, and the 26-survivor backlog is tracked as
`claude-workflow-plugin-6ix`. All five Phase C child tasks
(`claude-workflow-plugin-n45.1` harness, `n45.2` judge + calibration,
`n45.3` acceptance sweep, `n45.5` exclusion-bypass + JUDGE-RELAY fix,
`n45.4` closeout) were `qa-approved` on `main` by 2026-06-12.

### Added

- **Mutation-testing harness (C.1).** New tier under
  `.claude/tests/mutation/`: `mutation-sweep.sh` entry point,
  `fault-classes.md` catalog (F1 doc-only / F2 inverted conditional /
  F3 off-by-one / F4 swapped sentinel / F5 dropped jq fallback /
  F6 wrong hook envelope key / F7 removed regex anchor / F8 removed
  flock — destructive command classes excluded by design),
  `mutation.conf` caps (`MAX_MUTANTS_PER_FILE=24`,
  `MAX_MUTANTS_PER_RUN=60`, `MUTANT_TEST_TIMEOUT_S=60`,
  `SWEEP_TIMEOUT_S=1800`, `COMMAND_EXCLUSIONS` covering `rm mv cp curl
  wget gh push reset checkout`, `JUDGE_PRECISION_MIN=0.8`),
  `lib/generate.sh` (deterministic awk/sed generators — all 8 generators
  now uniformly call `should_skip` after n45.5; fault-class catalog
  parity is enforced at L1), `lib/rank-targets.sh` (`impact_of` when
  code-graph index present, lines × test-references fallback
  otherwise — graceful-degradation proven by the L1 test fixture
  running with no DB). 18-assertion L1 suite
  (`mutation-harness.test.sh`) with two META-TESTs (inverted
  kill-detection and trap-stripped containment leak).
- **Worktree containment (C.1).** Every mutant applied inside a
  fresh `git worktree --detach HEAD` under
  `.claude/.mutation-worktrees/m-<run_ts>-<idx>/`; main checkout is
  never touched. Three-layer cleanup: per-mutant
  `git worktree remove --force`, EXIT/INT/TERM trap, and final
  `git worktree prune`. Both `.claude/.mutation-runs/` and
  `.claude/.mutation-worktrees/` are gitignored. Containment proof
  is the L1 suite section 3 (HEAD + tracked-file hashes unchanged
  after sweep) + section 4 (zero worktrees in directory and registry)
  + section 9 META-TEST (trap-stripped harness leaks at least one
  worktree).
- **Cost-confirmation gate (C.1).** After the deterministic pass the
  harness prints a survivor count + judge cost estimate (survivors
  × `JUDGE_COST_PER_CALL_USD`); the judge step gates behind
  `--confirm-judge` (CI / scripted) or an interactive y/N prompt.
  EOF stdin defaults to N (no paid call without explicit
  confirmation). `--no-judge` skips the gate entirely. Mirrors the
  0.8 manual-only-live-testing convention.
- **`/mutation-sweep` Claude-invokable command (C.1).** New
  `.claude/commands/mutation-sweep.md` — thin wrapper that asks
  Claude to pick targets and forward to `mutation-sweep.sh`.
  Registered in `plugin.json` commands[] in the same commit per the
  manifest-parity lesson.
- **Judge subagent (C.2).** New `.claude/agents/judge.md` —
  read-only tools (`Read, Grep, Glob, LS`), strict-JSON output
  (`{verdict: equivalent|genuine, confidence, justification}`),
  three worked examples (equivalent counter, genuine label-typo,
  subtle defended-caller default removal), `proactive: false`
  (spawned only from the root via JUDGE-RELAY). Carries the shared
  `effort: max` + time-budget block. Calibration design bias is
  precision over recall — better to miss an equivalent than to bury
  a real regression. Registered in `plugin.json` agents[] in the
  same commit (manifest-parity lesson; now 7 agents total).
- **Calibration set + precision gate (C.2).** Hand-labeled corpus at
  `.claude/tests/mutation/calibration/calibration-set.json`: 24
  entries (≥20 per spec headroom), all 8 fault classes represented
  (≥5 equivalents so precision has a real denominator),
  per-entry `ground_truth` + `label_rationale`. The L1 suite
  (`judge-calibration.test.sh`, 65 assertions, 2 META-TESTs)
  validates the shape, the ≥20 / ≥5 contracts, and the precision/
  recall math. `judge-gate.sh` runs precision/recall against the set:
  exit 0 iff `precision >= JUDGE_PRECISION_MIN` (default 0.8). Recall
  is reported alongside but is not a gating threshold. Exit codes
  0 / 1 / 2 / 3 cover pass, below-threshold, malformed input, and
  undefined precision respectively.
- **Calibration round result (C.2).** First calibration sweep ran
  2026-06-12 (root-orchestrated relay, in-session, zero API spend
  via the operator's existing Claude session): TP 16, FP 1, FN 1,
  TN 6, **precision 0.9412 / recall 0.9412 — GATE PASSED** (0.8
  threshold). One FP (id 8 — ARG_MAX/PATH-stub jq failure surface
  argued constructible; ground truth holds it unconstructible) and
  one FN (id 12 per the confusion matrix). Run artefacts:
  `calibration/runs/2026-06-12-{calibration-report,verdict}.json`
  (tracked); raw run dir gitignored.
- **JUDGE-RELAY procedure (C.2, n45.5).** Orchestrator section 5b
  (`JUDGE-RELAY: judging-relay`) — judge is always spawned from the
  root conversation, never by another subagent (`code.claude.com/docs/
  en/sub-agents`: `Agent(agent_type)` has no effect in a subagent
  definition). The harness writes `judge-packet.json` on disk; the
  orchestrator reads it, spawns `@judge` once via `Task`, captures
  stdout to `verdict.json`, then runs `judge-gate.sh`. Guarded at L1
  by `no-nested-spawn-instructions.test.sh`. Mirrors the 5a
  RUBRIC-RELAY shape introduced in v3.2.0.
- **Acceptance sweep results (C.3).** First sweep over
  `.claude/scripts/verify-before-stop.sh` + `.claude/scripts/post-edit.sh`
  ran 2026-06-12 (`/mutation-sweep`, throwaway worktrees,
  `--no-judge` deterministic pass + JUDGE-RELAY for survivors).
  **32 mutants generated, 4 killed by the existing suite, 28
  survived** (87.5 % survival rate before triage). The judge
  classified **27 genuine / 1 equivalent** (id 27 — printf-rc
  masking, unconstructible failure surface). Killing-test target:
  id 12 (line 657 `=` → `!=`) — the failing test suite was replayed
  from cache while the gate reported "technical checks passed", a
  false-positive everything-is-fine verdict on a session that
  actually had a failing suite. Survivor 12 was killed by 8 new L2
  assertions on `.claude/tests/component/specs/verify-before-stop.sh`
  testing the suite-actually-ran invariant via on-disk tracking
  artefacts (`last-test-rc.<TID>`, `last-test-output.log`,
  `last-runner.<TID>`) plus negative-wording assertions on the block
  reason (no "QA approval required" / "technical checks passed" when
  tests fail). The remaining 26 genuine survivors are tracked as
  `claude-workflow-plugin-6ix` with seven theme groupings
  (A: block-reason wording paths; B: F1 doc-only fast path;
  C: cross-repo detection; D: git-status fallback; E: escalation
  boundary; F: post-edit tracking/cadence; G: post-edit doc filter)
  and two `TECHNICAL_DEBT.md` rows.
- **Installer surface expanded for the v3.4.0 manifest (C.4).**
  `install.sh` + `install.ps1` now ship every agent declared in
  `plugin.json` agents[] (was hardcoded to the five v3.0 roles,
  silently dropped `grader.md` from v3.2.0 and `judge.md` from
  v3.4.0). Glob-copy under `.claude/agents/*.md` replaces the
  fixed list. Additionally ships `.claude/rubrics/*.md` +
  `.claude/rubric-config` (Phase A surface), `.claude/tests/mutation/`
  excluding `runs/` + `*.log` (Phase C surface),
  `.claude/model-ranking` + `LESSONS.md` + `.worktreeinclude` (Phase 0
  surface). Ten new assertions in `installer-mcp-config.sh` cover the
  full Phase A + Phase C presence (grader.md, judge.md,
  rubrics/default.md, rubric-config, mutation-sweep.sh, judge-gate.sh,
  calibration-set.json, mutation-sweep.md command, LESSONS.md,
  model-ranking).

### Changed

- **`mutation.conf` documents the default test-cmd tier (C.4).** The
  `MUTANT_TEST_TIMEOUT_S` block now documents that the harness
  defaults to the L1 unit subset
  (`bash .claude/scripts/tests/run-tests.sh`) and recommends a
  per-target `--test-cmd 'L1 && L2'` override for hook-script targets
  whose primary coverage lives in L2 component specs. Originates
  from the C.3 acceptance sweep where survivor 12 needed L2
  assertions to be killable — the L1 default would have left it
  survived. The README "Per-target test-cmd overrides" section
  carries the operator-facing variant.

### Migration

- **Existing v3.3.0 installs missing the v3.2.0 grader + v3.4.0
  judge files: re-run the installer.** `bash install.sh` (or the
  curl-pipe form) over the existing target copies the missing
  agents, rubrics, mutation tier, and supporting config files. No
  manual editing required; Beads data, settings, hooks, and MCP
  config are preserved (merge-aware copy). The `update` mode is
  conservative — workflow-owned keys are refreshed, non-workflow
  keys (and any local customizations under `.claude/`) are kept.
- **Mutation tier is gitignored at runtime.** `.claude/.mutation-runs/`
  and `.claude/.mutation-worktrees/` are added to the install-time
  `.gitignore`. Calibration `runs/` artefacts are tracked
  per-checkpoint; only the live run dirs are excluded.

## [3.3.0] - 2026-06-12

Phase B of the verification-suite plan (`docs/plans/verification-suite.md`):
the code-graph MCP server. Replaces `code-context-mcp` (3 git-grep tools)
with `code-graph-mcp` (7 graph tools backed by tree-sitter + SQLite).
Adds impact-analysis surfaces to the orchestrator pre-delegation step
and the QA regression scan, with measured ~67.5 % context efficiency
on a representative QA workload. Both child tasks
(`claude-workflow-plugin-366.1` server build, `366.2` integration +
migration) were `qa-approved` on `main` by 2026-06-12. Phase C
shipped immediately after, as v3.4.0 — see the entry above.

### Added

- **`code-graph-mcp` server (B.1).** New tree-sitter + SQLite code
  graph server under `.claude/mcp/code-graph-mcp/`. Seven tools:
  `code_search`, `code_context`, `symbol_callers` (byte-compatible
  trio with the retired engine on inputs and primary output keys —
  the `tool` / `backend` strings change to `"graph-index"`), plus
  `impact_of`, `dead_code`, `dependency_path`, `code_index_health`
  (the new analysis surface). Lazy index at
  `.claude/.code-graph/index.db` (gitignored), incremental by content
  hash, built on first tool call so SessionStart pays no parse cost.
  Ships 10 vendored wasm grammars (JS/TS/TSX/Python/Go/Rust/Bash/
  Ruby/Java/C). 31 server tests (7 indexer + 15 tools + 9 server).
- **Agent wiring for impact analysis (B.2).** `orchestrator.md`
  section 1a queries `impact_of` for likely-touched symbols/files
  during pre-delegation and attaches the result to the SPEC doc;
  `qa.md` section 3a queries `impact_of` for every changed symbol
  in the diff and treats high-fan-in callers as mandatory regression
  candidates (extends J19). Both calls degrade gracefully when the
  server is unavailable (logged in `llm_observations`).
  `docs/AGENTS.md` mirrors the new behaviors (orchestrator + QA
  Key Behaviors each gain item 6).
- **`qa-queried-impact-of` invariant + fixture declaration (B.2).**
  New live-test invariant asserts QA queried `impact_of` for every
  changed symbol during a regression pass; declared on the
  `node-react-auth` fixture's `fixture.yaml`. Composes with the
  existing four active invariants.
- **`agent-mcp-tools-parity.test.sh` L1 test (366.6).** New L1
  parity test asserts every non-exempt agent file with a `tools:`
  frontmatter line enumerates each `mcp__*` tool its prompt body
  references. Carries four META-TESTs (gap trips checker;
  server-grant passes; exempt short-circuit; no-tools-line
  inherits). `grader.md` is exempt-by-design (read-only tools,
  no MCP body references); the exemption is encoded in
  `EXEMPT_AGENTS` with a justification.
- **L2 installer assertions for the new server (B.2).** Five new
  assertions in `.claude/tests/component/specs/installer-mcp-config.sh`:
  `code-graph` args reference the launcher path and use the
  `${CLAUDE_PROJECT_DIR:-.}` default form; the retired `code-context`
  entry is absent from the rendered `.mcp.json`; the rendered install
  has `.claude/mcp/code-graph-mcp/` and a vendored wasm grammar
  (typescript spot-check on the rsync exclude behavior); the
  `.claude/mcp/code-context-mcp/` directory is gone. The two
  META-TESTs (bare-form rejected, default-form accepted) are
  unchanged.

### Changed

- **Measured context efficiency: 259,744 → 84,442 bytes
  (~67.5 % reduction).** Offline output-size proxy on a
  representative QA regression workload (decomposition target:
  change `qa-gate.sh`'s grade-record action format; symbol seed
  `cmd_grade_record`). BEFORE figure is the minimum file-read
  cost an orchestrator would pay without `impact_of` (23 files at
  ~256 KB); AFTER is `code_search` + `code_context` + `impact_of`
  seed. Tokens are bytes/4, conservative for JSON. Method,
  raw 23-file list, and caveats documented in
  `.claude/mcp/code-graph-mcp/README.md` under "Before/after token
  comparison".

### Removed

- **`code-context-mcp` retired (B.2).** `.claude/mcp/code-context-mcp/`
  deleted; the `code-context` server entry removed from both
  `.mcp.json` and `.claude-plugin/plugin.json` in the same commit
  the new server was wired in. The `_phase7_codebase_graph_target`
  forward-pointer block in `.mcp.json` is gone now that it is
  filled. Beads data and the QA gate semantics are untouched.

### Migration — code-context-mcp retired (3.3.0)

Phase B of the verification-suite plan (v3.3.0) replaces
`code-context-mcp` with `code-graph-mcp`, a tree-sitter + SQLite
code-graph server. For existing installs:

- **Easy path: re-run the installer.** `bash install.sh` (or the
  curl-pipe form) over the existing target rewrites `.mcp.json` and
  `.claude-plugin/plugin.json` to wire `code-graph` and drops the
  retired `code-context` entry. The `${CLAUDE_PROJECT_DIR:-.}`
  default form from 3.1.0 is preserved.
- **Manual path: edit `.mcp.json` in place.** Swap the
  `code-context` entry's `command` / `args` to point at
  `${CLAUDE_PROJECT_DIR:-.}/.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js`
  and rename the key from `code-context` to `code-graph`. Keep the
  `${VAR:-.}` default form (the 3.1.0 hotfix).
- **First tool call builds the index lazily.** No SessionStart
  parse cost; the first `code_search` / `code_context` /
  `impact_of` call pays the build (~tens of ms per kLOC for the
  vendored grammars). Subsequent calls are incremental by content
  hash.
- **Beads data unaffected.** Task state, labels, comments, gate
  semantics are all unchanged — the swap is MCP-layer only.

`code_search` and `code_context` keep their input schemas and
primary output keys; only the `tool` / `backend` value strings
change (`"git-grep"` → `"graph-index"`). `code_index_health` is
intentionally an **Add** rather than byte-compat — the old engine
reported git-grep environment health, the new engine reports
staleness, per-language coverage, last index time, and DB size.
No live consumer reads the old health fields. The full migration
detail is in `docs/MCP_SERVERS.md`.

### Fixed

- **`docs/MCP_SERVERS.md` fabricated example corrected (B.1 QA
  follow-up, `byj`).** The "Concrete example" paragraph cited a
  non-existent fixture symbol (`auth-handler`) and a non-existent
  invariant name. The fix implemented the real
  `qa-queried-impact-of` invariant (declared on `node-react-auth`'s
  `fixture.yaml`) and rewrote the example around the real
  `createApp` symbol (the Express app factory in
  `server/index.js`).
- **Stale fixture `SKILL.md` references swept (B.2).** Every
  fixture under `.claude/skills/workflow-engine/SKILL.md` and the
  seven fixture variants were rewritten to reference `code-graph`
  in their MCP server table row.
- **`make test-live FIXTURE=<fixture>` spec resolution (366.4).**
  The recipe assumed 1:1 fixture-to-spec naming and failed with
  "No test files found" for `FIXTURE=node-react-auth` (the lone
  scenario-named spec, `happy-path.spec.ts`). New
  `.claude/scripts/resolve-fixture-spec.sh` scans each spec's
  `FIXTURE_PATH` constant for the requested fixture; the Makefile
  resolves before the cost prompt, prints the resolved spec(s),
  and unknown fixtures now fail fast with a listing of available
  fixtures.
- **Harness Beads capture #2 (366.5).** `bd 0.47.1`'s
  `sync --flush-only` short-circuits with "auto-import skipped,
  JSONL unchanged (hash match)" when `issues.jsonl` is absent and
  `sync_base.jsonl`'s hash matches `metadata.jsonl_content_hash`
  in `beads.db` — the live-fixture restore pattern hits this
  every run, leaving `issues.jsonl` unmaterialized so the Phase B
  live trace reported zero created tasks. `lib/beadsCapture.ts`
  now falls back to `bd export --force -o .beads/issues.jsonl` to
  force materialization; `happy-path.spec.ts:90` adopted the
  multi-domain-signup OR-shape assertion (harness diff OR
  `bd_create_(task|epic)` MCP OR Bash `bd create`); the Phase B
  live trace was committed as the seed regression anchor with a
  dedicated `_phase-b-trace.unit.spec.ts`.
- **Subagent MCP tool allowlists (366.6).** Subagent `tools:`
  frontmatter is an allowlist, and per
  `code.claude.com/docs/en/sub-agents` it structurally strips MCP
  tools when no `mcp__*` entry is enumerated — so QA and the
  three specialists could not reach the `code-graph` / `bd` MCP
  servers at all. Server-level grants
  (`mcp__plugin_claude-workflow_code-graph`,
  `mcp__plugin_claude-workflow_bd`, `mcp__code-graph`, `mcp__bd`)
  were added under both the plugin and project prefixes for all
  five non-grader agents. QA section 3a + orchestrator section 1a
  wording was tightened so an empty/missing index is a lazy-build
  signal (PROCEED) rather than a degradation reason — degrade
  only when `code-graph` is structurally absent from the surface.
  `lib/runFixture.ts` gained `HARNESS_METADATA_FILES` +
  `snapshotHarnessMetadata` / `restoreHarnessMetadata` so
  operator-authored `fixture.yaml` content survives the
  reset/clean/pop restore cycle (new
  `_fixture-restore.unit.spec.ts`, 4 specs).

## [3.2.0] - 2026-06-11

Phase A of the verification-suite plan (`docs/plans/verification-suite.md`):
the rubric-grader QA loop. Adds a separate-context `grader` subagent, a
versioned rubric set (default + backend/frontend/devops domain overlays
+ bugfix overlay), `qa-gate.sh grade-record` lifecycle with
`rubric-pending`/`rubric-satisfied` labels, the QA grading loop with a
binding iteration cap that engages the 0.2 escalation path, and a
statusline rubric segment. Both Phase A child tasks
(`claude-workflow-plugin-l1r.1` plumbing, `l1r.2` grader + wiring) were
`qa-approved` on `main` by 2026-06-11. Validated 2026-06-11 — 3 runs
(~$15-30), relay demonstrated end-to-end in run 3, trace anchored
offline in `_phase-a-trace.unit.spec.ts` + seed cassette; two
live-found defects fixed (grader manifest registration; nested-spawn
relay redesign). Phases B/C remain pending and will ship as
v3.3.0 / v3.4.0.

### Added

- **Grader subagent (A.2).** New `.claude/agents/grader.md` — read-only
  tools (`Read, Grep, Glob, LS`), non-proactive (spawned deliberately by
  the QA agent), carrying the shared `effort: max` + time-budget block.
  Strict-JSON output contract (`verdict`, `criterion_results`,
  `required_fixes`, `iteration`, `rubric_version`); separate context
  prevents self-critique contamination.
- **Versioned rubric set (A.1).** `.claude/rubrics/default.md` (v1,
  C1–C7: SPEC fidelity, user-behavior tests, F7 with substantive
  `llm_observations`, no unrelated scope, J26 modules addressed, docs
  updated, boundary-mock fidelity citing `LESSONS.md` lesson 2);
  `backend.md` / `frontend.md` / `devops.md` (each extends default
  with four domain criteria); `bugfix.md` overlay (applies_to: bug,
  G1–G4 enforcing spec 0.5 evidence-before-fix protocol).
- **`qa-gate.sh grade-record` (A.1).** New subcommand that reads a
  strict-JSON verdict from `--file <path>` or stdin, validates the
  shape (rejecting malformed input with a structured `error_key`
  envelope), appends a `RUBRIC <version> iteration <n>: <verdict>`
  Beads comment, and on `satisfied` flips `rubric-pending` →
  `rubric-satisfied`. On `needs_revision` labels are unchanged — the
  `qa-blocked` round-trip is the QA agent's move per principle 7.
- **QA grading loop with binding cap (A.2).** New section 6 in
  `qa.md` (subsections 6a–6f: packet assembly → spawn grader →
  record → needs_revision round-trip → cap → override-reason rule).
  Cap reads from `.claude/rubric-config` (`iteration_cap=3` default);
  hitting the cap engages the 0.2 escalation path
  (`qa-escalated` + J21 decision) rather than looping further.
  Mirrored into `docs/AGENTS.md` (5 → 6 agents).
- **Statusline rubric segment (A.2).** `.claude/scripts/statusline.sh`
  now emits `qa: <state> • rubric: <state> • N files changed` when a
  rubric label is present, using the existing `bd show` round-trip
  (no new fetch). Suppresses the rubric segment when no rubric label
  is set, to keep the line short.
- **`rubric-revision-loop` live fixture (A.2).** Full e2e fixture
  under `.claude/tests/e2e/fixtures/rubric-revision-loop/` with a
  prompt that deliberately under-tests its change, forcing C2 to
  fail on iteration 1 so the loop exercises the needs_revision
  → re-grade → satisfied path. Validated live 2026-06-12 (3 runs,
  ~$15-30; relay demonstrated in run 3; trace anchored offline in
  `_phase-a-trace.unit.spec.ts` + seed cassette).

### Changed

- **`qa-gate.sh enter` arms `rubric-pending` (A.1).** Fresh and
  idempotent paths both set `rubric-pending` alongside
  `qa-gate-entered`; re-entry clears any stale `rubric-satisfied`
  from a prior cycle. `cmd_status` now reports
  `rubric=<pending|satisfied|none>` in `observations`.
- **`qa-gate.sh approve` warns on un-graded approvals (A.1).** Per
  principle 6 the approve path does NOT hard-gate on
  `rubric-satisfied`; it warns loudly in `observations` when
  `rubric-pending` is still set, and the QA agent's prompt (6f)
  enforces the explicit override-reason rule. Approve drops
  `rubric-pending` (cycle ends) and preserves `rubric-satisfied`
  as the audit trail.

## [3.1.0] - 2026-06-11

Phase 0 of the verification-suite plan (`docs/plans/verification-suite.md`).
Two production hotfixes (MCP loader, QA-gate escalation cap), five agent
policy upgrades (best-model auto-selection, max effort + time budget,
evidence-before-fix protocol, parallel-specialist worktree isolation,
lessons ledger), and a live-test economics rework (retire golden-cassette
equality, manual invariant-based live testing only, zero-API CI). All
eight child tasks (`claude-workflow-plugin-e0d.1` through `e0d.8`) were
`qa-approved` on `main` by 2026-06-11. Phases A/B/C remain pending and
will ship as v3.2.0 / v3.3.0 / v3.4.0.

### Fixed

- **MCP path resolution in installed projects (0.1).** `.mcp.json` server
  entries now use `${CLAUDE_PROJECT_DIR:-.}` default form so both `bd` and
  `code-context` servers load in installed targets, not just the plugin's
  own repo. Verified against the Claude Code MCP configuration docs
  (project-scoped variables) and covered by a new L2 installer spec that
  asserts no unresolved `${...}` refs in a rendered fresh install.
- **QA-gate escalation cap is now binding (0.2).** Adds `qa-escalated`
  state (J21 comment + label at cap-hit, suite re-runs skipped while
  escalated), `qa-deferred` auto-defer escape valve on the next choiceless
  Stop (the single audited bypass under principle 6), and runner-vs-
  assertion failure classification so environment errors route to
  "fix the environment" instead of looping on code. Previously a live
  transcript showed `ESCALATION: Iteration 7 (>= 3)` re-running the suite
  on every loop with no behavioral consequence.

### Added

- **Automatic best-model selection on every SessionStart (0.3).** New
  `.claude/scripts/model-select.sh` resolves available models via the
  free `GET /v1/models` listing, ranks by `.claude/model-ranking`
  (family preference + unknown-newer heuristic + largest-context
  variant), and rewrites agent `model:` fields through the shared
  `workflow-model-apply.sh` helper. 1-hour cache; fail-open on
  missing key or network failure. Every switch records a Beads
  comment on a standing meta-task with the `/workflow-model` rollback
  command.
- **Maximum effort and high time budget (0.4).** `effortLevel: xhigh`
  (the highest persisted value) in `settings.json`,
  `CLAUDE_CODE_EFFORT_LEVEL=max` in the `env` block (env wins per the
  Claude Code env-vars docs), and `effort: max` in every agent's
  frontmatter. Shared time-budget block added to all six agent prompts
  with principle-3 language ("Depth beats speed in every trade"). L1
  test discovers agents via glob so future additions get covered
  automatically.
- **Evidence-before-fix protocol (0.5).** Merged into qa.md's J27
  framework as 6 numbered steps (deterministic repro, failing test
  first, root-cause statement with cited evidence, declare confidence
  or ask, fix flips the failing test, two-bounce mandatory return to
  evidence mode). Mirrored in `backend.md`, `frontend.md`, `devops.md`
  with voice-appropriate tooling references. The "symptom-patching
  chains" anti-pattern is named explicitly in all four agent files
  and in `docs/AGENTS.md`. Bug-typed tasks only.
- **Worktree isolation for parallel specialists (0.6).** Orchestrator
  delegation rule: 2+ concurrent specialists every get
  `isolation: "worktree"` on the Task call. Serial single-specialist
  delegation unchanged. New `.worktreeinclude` at repo root covers
  env files so worktrees are runnable. Cited against the Claude Code
  sub-agents and worktrees docs.
- **Lessons ledger (0.7).** New `.claude/scripts/lessons.sh add
  '<text>' --source <task-id>` helper with normalized-text dedup;
  prints structured JSON output. `LESSONS.md` at repo root seeded
  with the two production lessons (worktree contamination,
  boundary-mock fidelity sourced from a real producer spec).
  `CLAUDE.md` conditional-loading row points the orchestrator to
  read it before non-trivial planning. `qa.md` epic-close step now
  emits candidate-lesson `lessons.sh add` calls instead of chat
  prose.
- **Invariant engine for manual live testing (0.8).** New
  `lib/invariants.ts` over normalized traces with 4 active
  invariants (orchestrator-no-edits, qa-approved-required,
  milestone-subsequence, declared-subagents-only) plus 1 honestly
  skipped (F7 completion contract, surfaced as `skipped` in matcher
  output rather than green-washed). Every fixture's `fixture.yaml`
  declares an `invariants:` block; `satisfiesInvariants` matcher
  replaces `matchesGolden` across all 6 live specs. New L2
  installer-config spec asserts no unresolved variables in
  rendered fresh installs.

### Changed

- **Manual-only live testing, zero-API CI (0.8).** L4 daily drift
  cron and per-PR live CI removed from `.github/workflows/test.yml`.
  `l3-live` is now `workflow_dispatch`-only. `make test-live` requires
  an explicit `FIXTURE=<name>` (or `FIXTURES="a b c"`), validates
  `ANTHROPIC_API_KEY`, prints a per-fixture cost estimate, and gates
  on `CONFIRM=1` for the y/N prompt. CI now consumes zero API spend
  on every PR.

### Removed

- **Golden-cassette equality as a gate (0.8).** `matchesGolden` is
  deprecated to a manual debugging reference; gating is invariant-
  based after this release. The retained recorded cassettes seed the
  invariant-engine self-tests. `make test-e2e` and
  `make test-e2e-record` are deprecated aliases that exit 2 with a
  pointer to `make test-live`.

## [3.0.0] - 2026-05-11

This release is the v2 -> v3 upgrade (Phases 0-7 of the consolidated v3 plan
at `docs/plans/v3-upgrade.md`), plus the G8 end-to-end test harness epic
and a post-G8 closeout pass. All work was merged to `main` by
2026-05-11. The release covers the plugin manifest, model pinning,
auto-loaded skill, statusline, two bundled MCP servers, the GitHub-link
hook, the AgentLint sweep, the five-tier test pyramid (L1 bash unit ->
L4 daily drift), a v2 -> v3 migrator, and a README rewrite. See the
sub-headers below for the per-phase breakdown.

### Added (v3 upgrade -- Phase 0, Foundation)

- `.claude-plugin/plugin.json` -- first-class Claude Code plugin manifest
  declaring `name`, `version`, `agents`, `hooks`, `commands`, `skills`, and a
  placeholder `mcpServers` block (Phase 6 populated). (E1)
- `.claude/commands/workflow-model.md` -- Claude-invokable slash command that
  rewrites the `model:` field across all five agents and updates the
  `CLAUDE_LATEST_OPUS` env hint in `settings.json`. (A5)
- `model:` field on every agent (`orchestrator`, `qa`, `backend`, `frontend`,
  `devops`), pinned to `claude-opus-4-7`. (A1, A3)
- `MAX_THINKING_TOKENS=64000` and `CLAUDE_LATEST_OPUS=claude-opus-4-7` in
  `.claude/settings.json` `env` block. (A2)
- `additionalDirectories: ["../"]` in `.claude/settings.json` so Claude has
  parent-folder read access by default. (E16)
- Extended-thinking instruction (`Use extended thinking for all non-trivial
  work.`) in every agent prompt, near the role intro. (A2)
- SessionStart hook now warns (non-blocking) when:
  - `bd --version` is older than the pinned minimum (currently `0.47`). (D6)
  - Any agent's `model:` field doesn't match `${CLAUDE_LATEST_OPUS}`,
    prompting the operator to run `/workflow-model`. (A1)
- `install.sh` and `install.ps1` enforce the minimum `bd` version at install
  time (fail-fast with a clear upgrade message). (D6)
- `uninstall.sh` and `uninstall.ps1` -- safe uninstall that *moves* the plugin
  files to a trash directory (`.claude-uninstall-trash-<timestamp>/`) instead
  of deleting them, and optionally restores from the latest
  `.claude-backup-*/`. (G5)
- `CHANGELOG.md` -- this file. (G6)
- `CONTRIBUTING.md` -- how to add a specialist agent, extend hooks, and where
  to look for the deferred testing strategy. (G7)

### Added (v3 upgrade -- Phase 5, Best-practice integrations)

- `.claude/skills/workflow-engine/SKILL.md` rewritten as the canonical
  source of truth for workflow rules. Frontmatter declares `name`,
  `description`, `when_to_use`, and explicit `disable-model-invocation:
  false` so Claude auto-loads it on session start without a slash trigger.
  (E2 / E15, principle 4 -- always-on workflow)
- `.claude/scripts/statusline.sh` -- single-line statusline rendering
  `[<task-id>] qa: <state> N files changed`, with graceful fallbacks for
  no-active-task and bd-unavailable cases. Reads from
  `.claude/.qa-tracking/current-task` (F3 single source of truth) and
  the task's labels for state. (E4 / I2)
- `.claude/settings.json` `statusLine` field wires the script into Claude
  Code's status bar. (E4 / I2)
- `.mcp.json` placeholder at project root with `_phase6_*` keys describing
  the bd-mcp (J29) and codebase-graph (J30) servers Phase 6 filled in.
  (E5)
- Memory bridge: `qa-gate.sh block <task> <reason>` now writes a
  `feedback`-typed memory entry to
  `~/.claude/projects/<project-slug>/memory/qa-block-<fp>.md` and updates
  `MEMORY.md` index. The fingerprint is a SHA1 of the first 80 chars of
  the reason so repeat-blocks of the same pattern collapse to one file
  (with appended `Last seen` timestamps). Across sessions, recurring QA
  patterns become memory the orchestrator can read. (E8, principle 5 --
  intent-based)
- TaskCreate / TaskUpdate dual-tracking section in `orchestrator.md`:
  documents Beads as cross-session and TaskCreate as intra-session, with
  a concrete worked example for an Epic + sub-tasks. (E13)

### Added (v3 upgrade -- Phase 6, MCP servers)

- bd-mcp MCP server (21 typed Beads tools) wired via `.mcp.json` with
  `${CLAUDE_PLUGIN_ROOT}` substitution. (J29)
- code-context-mcp MCP server (3 search tools: `code_search`,
  `code_context`, `symbol_callers`). (J30)
- Phase 6b: `bd-github-link.sh` (I3 -- auto-link Beads tasks to
  GitHub PRs/issues), cross-repo guard in `verify-before-stop.sh` and
  `current-task.sh` (I8), `docs/MCP_SERVERS.md` doc convention.

### Added (v3 upgrade -- Phase 7, AgentLint sweep)

- AgentLint sweep (61 -> 90 score climb); added `CLAUDE.md`, `HANDOFF.md`,
  `INDEX.md`, `SECURITY.md`, `Makefile`, `.gitignore`, `tests/` symlink,
  `.claude/scripts/tests/run-tests.sh` runner, and `stop_hook_active`
  circuit breaker in the Stop hook.

### Added (G8 test harness)

- L1 bash unit tests (49 assertions across `.claude/scripts/tests/`).
- L2 component tier (15 specs, 243 assertions, including the new
  `qa-gate-baseline` spec that codifies the 0wk.2 fix).
- L3 vitest unit tier (55 tests covering trace schema, normalization,
  golden compare, fixture init, custom matchers).
- L3 live e2e tier: 6 fixtures + golden cassettes -- `node-react-auth`,
  `python-django-bug`, `go-cli-refactor`, `monorepo-frontend-only`,
  `multi-domain-signup`, `qa-block-recovery`.
- L4 daily drift watch (GitHub Actions cron in `.github/workflows/test.yml`).
- GitHub Actions CI with 7 jobs: `lint`, `l1-unit`, `l2-component`,
  `l3-vitest-unit`, `manifest-validate`, `l3-live`, `l4-drift-watch`.
- Cassette-diff bot + PR summary tool with META-TEST tally surfacing.
- Failure-injection coverage: `orchestrator-restriction`, `cross-repo`,
  `hook-crash`, `regression-coverage`, `block-and-recover`.

### Added (post-G8 closeout)

- **README rewrite**: 325 -> 164 lines, value-forward pitch with
  install + upgrade + customize sections and copy-pasteable commands.
- **`install.sh --upgrade`**: detects v2 installs via three signals
  (agents lack `model:`, no `.claude-plugin/plugin.json`, no
  `.claude/mcp/` or `.claude/skills/workflow-engine/`), backs up to
  `.claude-v2-backup-<timestamp>/`, runs the v3 install, prints a
  "what changed" summary. Curl-pipe friendly:
  `... | bash -s -- --upgrade`.
- **`install.ps1` v2 redirect**: detects v2 and redirects to
  `install.sh` via Git Bash / WSL / curl instead of re-implementing
  the migration in PowerShell.
- **`CONTRIBUTING.md` quick-start**: mirror paragraph pointing at
  README's Customize section.
- **CI**: `npm ci --include=optional` plus glibc-binary verification
  step in `l3-live` and `l3-vitest-unit` jobs (SDK was resolving the
  `linux-x64-musl` variant on ubuntu-latest).

### Changed (v3 upgrade -- Phase 5)

- `intent-router.sh` and `session-start.sh` no longer embed the workflow
  rules text. Both now load
  `.claude/skills/workflow-engine/SKILL.md`, strip the YAML frontmatter,
  and inject the body via the `<workflow_engine>` envelope. When SKILL.md
  changes, the rules change everywhere. Fallback stub is in place if
  the skill file is missing. (E2 / E15)
- `orchestrator.md` opens with a pointer to the canonical SKILL.md and
  treats its own role-specific guidance as additive. (E2 / E15)
- All hook scripts standardised on the `hookSpecificOutput` envelope per
  the Claude Code hooks reference, with the documented exception of
  hooks that use top-level `decision/reason` (Stop, UserPromptSubmit,
  PostToolUse, PreCompact). `prevent-orchestrator-edits.sh` migrated
  from top-level `decision: block` to
  `hookSpecificOutput.permissionDecision: deny` per the PreToolUse spec.
  Documentation comments at the top of each script now spell out which
  shape is intentional. (E9)
- `qa-gate.sh block` returns a slightly richer `observations` field
  including whether the memory entry was written successfully. (E8)

### Changed (v3 upgrade -- Phase 0)

- `install.sh` and `install.ps1` rewritten to use the canonical files in the
  repo as the single source of truth. They `cp` / `Copy-Item` from the local
  clone (or freshly clone the repo to a temp dir if piped from
  `curl ... | bash`). The PowerShell installer no longer ships a truncated
  copy of the agent prompts. (G4)
- Tone-down pass on `docs/*.md` and `.claude/scripts/*.sh`: emoji limited to
  H1/H2 markers, ASCII separator bars (`---`-style) removed from script
  output. Agent prompts are not touched in this pass; that was Phase 2 (C6).
  (G9)

### Fixed (Phase 6b)

- 3 regex bugs in `bd-github-link.sh` (URL ref form, idempotency,
  close-detection); replaced with a token-walker parser.

### Fixed (Phase 7 / 0wk.9)

- `plugin.json` manifest schema for the SDK plugin loader (paths
  prefixed with `./`, hooks as string, skills as directory, MCP servers
  inline). Specialists now register as `claude-workflow:<role>` instead
  of falling back to `general-purpose`.

### Fixed (G8 / 0wk.2)

- `qa-gate.sh approve` now writes `approved-baseline` + truncates
  `changed-files.txt`; `verify-before-stop.sh` diffs git status against
  the baseline so we no longer see false-positive "0 files changed"
  demands on fresh sessions.
- Mid-G8: SDK `includeHookEvents: true`, `hookFired` matcher for the
  Claude Code Stop contract (no-decision = approve), HEAD-SHA capture
  before fixture run.

### Fixed (post-G8 closeout)

- **`statusline.sh::count_changed_files`** "00" bug: `grep -c .`
  exited non-zero on empty input and the `|| echo "0"` fallback ran
  on top of grep's own "0" output. Switched to `sort -u | wc -l`.
- **L1 `phase5-synthetic-tests.sh` statusline expectations**: updated
  to cover the full 0wk.2 transition (`gate-entered - 2 files` ->
  `approved - 0 files`) rather than the pre-0wk.2 state.
- **CI portability** (`BD_SHIM_ONLY=1` env opt): L1+L2 bd-dependent
  specs skip-with-log on the GitHub Actions runner (no `bd` CLI).
  Dev-machine paths unchanged.
- **L3 vitest unit specs**: replaced hardcoded `/Users/edk0/...`
  paths in `_lib.unit.spec.ts` with `import.meta.url`-relative
  resolution; replay-file reference replaced with the committed
  golden cassette.
- **shellcheck**: SC2015 refactor at `qa-gate.sh:340`
  (A && B || C -> if/then/fi); file-wide `# shellcheck disable=SC2317`
  in `bd-github-link.test.sh` and `phase5-synthetic-tests.sh` for
  source-pattern false positives.

### Closed bugs

- `0wk.7` -- zero subagent invocations (resolved by 0wk.9 plugin.json
  fix).
- `0wk.8` -- SDK doesn't register plugin agents (resolved by 0wk.9).
- `0wk.2` -- `qa-gate.sh approve` didn't clear `changed-files.txt`
  (resolved in the closeout pass).

### Known limitations

- L3 live runs cost ~$5-10/fixture; gated on `ANTHROPIC_API_KEY`
  secret. Now actually fires on every PR since the secret is
  configured.
- L3-live golden cassettes drift periodically as the model evolves;
  re-record via `RECORD_GOLDEN=1 npm run test:run` from the fixture
  dir.
- 0wk.4: vitest SIGKILL bypasses try/finally cleanup (mitigated by
  self-heal-on-entry in `runFixture.ts`).
- 0wk.5: bd daemon stack-overflow on stale locks (upstream beads CLI
  bug; workaround in production via `--db --allow-stale`).
- 8oz / a7y: SHA-pin GitHub Actions (+4 AgentLint Safety), gitleaks
  CI job (+2). Both P2 follow-ups in the AgentLint roadmap.

### Notes

- I1 was verified during Phase 5 (no leftover manual
  `bd label add/remove` ceremonies in `qa.md` or `orchestrator.md`;
  the `bd label add qa-pending` calls in specialist agent files are
  correct usage -- those add the *handoff* label that QA acts on, not
  the gate-state labels qa-gate.sh manages).
- The Phase 0 plan intentionally left the QA gate semantics, hook
  payload schema, and tool-list narrowing to later phases. Existing
  installs continue to work after upgrading to v3.0.0.

## [2.0.0] - 2026-05-08

Last commit before the v3 work began: `7dda421 fix installation command`.

This is the baseline this changelog is being backfilled from. Reconstructed
from `git log --oneline` and the README/docs as they stood at that commit.

### Added
- Mandatory orchestrator -> specialists -> QA workflow with five agents:
  `orchestrator`, `qa`, `backend`, `frontend`, `devops`.
- Beads (`bd`) integration as a hard requirement: `bd prime` for context,
  `bd ready` / `bd blocked` surfaced at SessionStart, hierarchical issues
  (epics + subtasks), labels for domain (`backend`, `frontend`, `devops`)
  and QA state (`qa-pending`, `qa-approved`).
- Stop-hook QA gate: blocks task completion until `qa-approved` label or
  "QA APPROVED" comment is recorded on the active task.
- LLM-driven intent discovery in `intent-router.sh` (replacing keyword
  matching) with mandatory delegation framing in the
  `<mandatory_delegation>` context block.
- Hook scripts: `session-start.sh`, `intent-router.sh`, `post-edit.sh`,
  `verify-before-stop.sh`, `session-end.sh`.
- `install.sh` (Linux/macOS) and `install.ps1` (Windows) with backup,
  update, and merge modes.
- `workflow-engine` skill with workflow documentation.
- Documentation set under `docs/`: `QUICKSTART.md`, `ARCHITECTURE.md`,
  `AGENTS.md`, `HOOKS.md`, `BEADS.md`, `WORKFLOW.md`, `TROUBLESHOOTING.md`.
- `CLAUDE.md` template for project memory (users, journeys, conventions,
  known mistakes).

### Known limitations (resolved in v3)
- Installer scripts embedded the agent prompts as heredocs, so the
  PowerShell version drifted to a much shorter copy than the bash version
  (resolved in v3 Phase 0 / G4).
- No model pinning -- agents inherited whatever model the runtime decided
  (resolved in v3 Phase 0 / A1).
- No plugin manifest, so the install was not a "plugin" by Claude Code's
  formal definition (resolved in v3 Phase 0 / E1).
- `verify-before-stop.sh` had a marker-file bypass and a `$TASK_ID`
  placeholder bug; `post-edit.sh` emitted raw text instead of JSON; QA
  approval was decided by comment-text fallback (resolved in v3 Phase 1).

## [1.0.0] - earlier

Initial commit (`1909ebf initial commit`). Pre-Beads experimental layout;
not separately documented because v2 superseded it before any external
release.

[Unreleased]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.4.0...HEAD
[3.4.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.3.0...v3.4.0
[3.3.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.2.0...v3.3.0
[3.2.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.1.0...v3.2.0
[3.1.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/preql-data/claude-workflow-plugin/releases/tag/v2.0.0
[1.0.0]: https://github.com/preql-data/claude-workflow-plugin/releases/tag/v1.0.0

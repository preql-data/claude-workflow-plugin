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

## [3.2.0] - 2026-06-11

Phase A of the verification-suite plan (`docs/plans/verification-suite.md`):
the rubric-grader QA loop. Adds a separate-context `grader` subagent, a
versioned rubric set (default + backend/frontend/devops domain overlays
+ bugfix overlay), `qa-gate.sh grade-record` lifecycle with
`rubric-pending`/`rubric-satisfied` labels, the QA grading loop with a
binding iteration cap that engages the 0.2 escalation path, and a
statusline rubric segment. Both Phase A child tasks
(`claude-workflow-plugin-l1r.1` plumbing, `l1r.2` grader + wiring) were
`qa-approved` on `main` by 2026-06-11. The single live validation
(`make test-live FIXTURE=rubric-revision-loop`) is pending; the
recorded result will be appended to the closeout notes when run.
Phases B/C remain pending and will ship as v3.3.0 / v3.4.0.

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
  → re-grade → satisfied path. Live validation pending; recorded in
  closeout notes when run via `make test-live FIXTURE=rubric-revision-loop`.

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

[Unreleased]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.2.0...HEAD
[3.2.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.1.0...v3.2.0
[3.1.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/preql-data/claude-workflow-plugin/releases/tag/v2.0.0
[1.0.0]: https://github.com/preql-data/claude-workflow-plugin/releases/tag/v1.0.0

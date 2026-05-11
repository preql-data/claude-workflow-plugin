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

## [Unreleased] - Phase 6+ (post-Phase 5 work)

### Added
- **Phase 6**: bd-mcp MCP server (21 typed Beads tools), code-context-mcp
  server (3 search tools), `.mcp.json` wiring with
  `${CLAUDE_PLUGIN_ROOT}` substitution. (J29, J30)
- **Phase 6b**: `bd-github-link.sh` (I3 -- auto-link Beads tasks to
  GitHub PRs/issues), cross-repo guard in `verify-before-stop.sh` and
  `current-task.sh` (I8), MCP_SERVERS.md doc convention.
- **Phase 7**: AgentLint sweep (61->90 score climb); added CLAUDE.md,
  HANDOFF.md, INDEX.md, SECURITY.md, Makefile, `.gitignore`, tests
  symlink, `run-tests.sh` runner, `stop_hook_active` circuit breaker.

### Fixed
- Phase 6b: 3 regex bugs in `bd-github-link.sh` (URL ref form,
  idempotency, close-detection); replaced with a token-walker parser.
- 0wk.9: `plugin.json` manifest schema for the SDK plugin loader (paths
  prefixed with `./`, hooks as string, skills as directory, MCP servers
  inline). Specialists now register as `claude-workflow:<role>` instead
  of falling back to `general-purpose`.

### Post-G8 closeout

#### Added
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

#### Fixed
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

#### Closed bugs
- `0wk.7` -- zero subagent invocations (resolved by 0wk.9 plugin.json
  fix).
- `0wk.8` -- SDK doesn't register plugin agents (resolved by 0wk.9).
- `0wk.2` -- `qa-gate.sh approve` didn't clear `changed-files.txt`
  (resolved in the closeout pass).

#### Known limitations (unchanged from G8)
- L3 live runs cost ~$5-10/fixture; gated on `ANTHROPIC_API_KEY`
  secret. Now actually fires on every PR since the secret is
  configured.
- L3-live golden cassettes drift periodically as the model evolves;
  re-record via `RECORD_GOLDEN=1 npm run test:run` from the fixture
  dir.

## [G8 - E2E Test Harness] - 2026-05-09 to 2026-05-11

### Added
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

### Fixed
- 0wk.2: `qa-gate.sh approve` now writes `approved-baseline` +
  truncates `changed-files.txt`; `verify-before-stop.sh` diffs git
  status against the baseline so we no longer see false-positive
  "0 files changed" demands on fresh sessions.
- Mid-G8: SDK `includeHookEvents: true`, `hookFired` matcher for the
  Claude Code Stop contract (no-decision = approve), HEAD-SHA capture
  before fixture run.

### Known issues
- 0wk.4: vitest SIGKILL bypasses try/finally cleanup (mitigated by
  self-heal-on-entry in `runFixture.ts`).
- 0wk.5: bd daemon stack-overflow on stale locks (upstream beads CLI
  bug; workaround in production via `--db --allow-stale`).
- 8oz / a7y: SHA-pin GitHub Actions (+4 AgentLint Safety), gitleaks
  CI job (+2). Both P2 follow-ups in the AgentLint roadmap.

## [3.0.0] - Unreleased

This is the v2 -> v3 upgrade. The work is organized in seven phases per the
approved plan
(`/Users/edk0/.claude/plans/we-are-working-on-dynamic-marshmallow.md`); this
section will be updated as each phase lands. Phases 0 through 7 are
complete; the G8 harness epic shipped 2026-05-11.

### Phase 5 - Best-practice integrations

#### Added
- `.claude/skills/workflow-engine/SKILL.md` rewritten as the canonical
  source of truth for workflow rules. Frontmatter declares `name`,
  `description`, `when_to_use`, and explicit `disable-model-invocation:
  false` so Claude auto-loads it on session start without a slash trigger.
  (E2 / E15, principle 4 — always-on workflow)
- `.claude/scripts/statusline.sh` — single-line statusline rendering
  `[<task-id>] qa: <state> N files changed`, with graceful fallbacks for
  no-active-task and bd-unavailable cases. Reads from
  `.claude/.qa-tracking/current-task` (F3 single source of truth) and
  the task's labels for state. (E4 / I2)
- `.claude/settings.json` `statusLine` field wires the script into Claude
  Code's status bar. (E4 / I2)
- `.mcp.json` placeholder at project root with `_phase6_*` keys describing
  the bd-mcp (J29) and codebase-graph (J30) servers Phase 6 will fill in.
  (E5)
- Memory bridge: `qa-gate.sh block <task> <reason>` now writes a
  `feedback`-typed memory entry to
  `~/.claude/projects/<project-slug>/memory/qa-block-<fp>.md` and updates
  `MEMORY.md` index. The fingerprint is a SHA1 of the first 80 chars of
  the reason so repeat-blocks of the same pattern collapse to one file
  (with appended `Last seen` timestamps). Across sessions, recurring QA
  patterns become memory the orchestrator can read. (E8, principle 5 —
  intent-based)
- TaskCreate / TaskUpdate dual-tracking section in `orchestrator.md`:
  documents Beads as cross-session and TaskCreate as intra-session, with
  a concrete worked example for an Epic + sub-tasks. (E13)

#### Changed
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

#### Notes
- I1 was verified (no leftover manual `bd label add/remove` ceremonies
  in `qa.md` or `orchestrator.md`; the `bd label add qa-pending` calls
  in specialist agent files are correct usage — those add the
  *handoff* label that QA acts on, not the gate-state labels qa-gate.sh
  manages).
- Out of scope (Phase 6/7): bd-mcp implementation (J29), codebase-graph
  (J30), SubagentStart cross-session hooks (J3), Beads-GitHub link (I3),
  multi-repo gate (I8), AgentLint sweep (J32). Phase 5 ships the
  scaffolding (`.mcp.json`) but the servers are not built.

### Phase 0 - Foundation (this release)

#### Added
- `.claude-plugin/plugin.json` - first-class Claude Code plugin manifest
  declaring `name`, `version`, `agents`, `hooks`, `commands`, `skills`, and a
  placeholder `mcpServers` block (Phase 6 will populate). (E1)
- `.claude/commands/workflow-model.md` - Claude-invokable slash command that
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
- `uninstall.sh` and `uninstall.ps1` - safe uninstall that *moves* the plugin
  files to a trash directory (`.claude-uninstall-trash-<timestamp>/`) instead
  of deleting them, and optionally restores from the latest
  `.claude-backup-*/`. (G5)
- `CHANGELOG.md` - this file. (G6)
- `CONTRIBUTING.md` - how to add a specialist agent, extend hooks, and where
  to look for the deferred testing strategy. (G7)

#### Changed
- `install.sh` and `install.ps1` rewritten to use the canonical files in the
  repo as the single source of truth. They `cp` / `Copy-Item` from the local
  clone (or freshly clone the repo to a temp dir if piped from
  `curl ... | bash`). The PowerShell installer no longer ships a truncated
  copy of the agent prompts. (G4)
- Tone-down pass on `docs/*.md` and `.claude/scripts/*.sh`: emoji limited to
  H1/H2 markers, ASCII separator bars (`━━━`-style) removed from script
  output. Agent prompts are not touched in this pass; that's Phase 2 (C6).
  (G9)

#### Notes
- The plan intentionally leaves the QA gate semantics, hook payload schema,
  and tool-list narrowing to later phases. Existing installs will continue to
  work after upgrading to v3.0.0.

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

### Known limitations (resolved or in flight in v3)
- Installer scripts embedded the agent prompts as heredocs, so the
  PowerShell version drifted to a much shorter copy than the bash version
  (resolved in v3 Phase 0 / G4).
- No model pinning -- agents inherited whatever model the runtime decided
  (resolved in v3 Phase 0 / A1).
- No plugin manifest, so the install was not a "plugin" by Claude Code's
  formal definition (resolved in v3 Phase 0 / E1).
- `verify-before-stop.sh` had a marker-file bypass and a `$TASK_ID`
  placeholder bug; `post-edit.sh` emitted raw text instead of JSON; QA
  approval was decided by comment-text fallback (deferred to v3 Phase 1).

## [1.0.0] - earlier

Initial commit (`1909ebf initial commit`). Pre-Beads experimental layout;
not separately documented because v2 superseded it before any external
release.

[3.0.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/preql-data/claude-workflow-plugin/releases/tag/v2.0.0
[1.0.0]: https://github.com/preql-data/claude-workflow-plugin/releases/tag/v1.0.0

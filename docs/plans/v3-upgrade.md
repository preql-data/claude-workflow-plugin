# Claude Workflow Plugin v3 — Approved Implementation Plan

## Context

You audited the v2 plugin with me in the previous turn. Out of ~100 candidate findings + 32 borrows from the awesome-claude-plugins ecosystem, you approved **~70 items** with several cross-cutting modifications. This document is the consolidated execution plan.

## Cross-cutting principles (apply to every section below)

These are the principles you set that override anything inconsistent in the original audit text:

1. **Max everything, cost is irrelevant.** Every agent runs Opus 4.7 at maximum thinking budget. Don't add cost-balancing tiers.
2. **Auto-upgrade model pinning.** Don't hard-pin a single model version that goes stale — pin to a moving alias / config var so a newer Opus auto-applies on release without re-installing.
3. **Full autonomy, no permission prompts.** The user answers Claude's clarifying *questions*, but never sees an "approve this tool?" prompt. Claude runs unrestricted. This means: no `permissions.deny`, broad `permissions.allow`, no scoping of specialist tool lists, no structural restrictions that need user confirmation.
4. **Always-on workflow.** Once installed, the workflow loads and runs automatically — no `/skill` or `/loop` triggering needed.
5. **Intent-based routing, never keyword-based.** Wherever the audit said "match X keyword to Y agent", the implementation must use LLM intent understanding instead. Specialists/skills are picked by what the request *means*, not what words appear in it.
6. **Slash commands are for Claude, not the user.** The user types intent in plain English; Claude internally invokes whatever slash commands or sub-skills it needs. So we don't ship `/qa-approve`-style human-facing commands — we expose those as auto-invoked tools.
7. **Specialists have full scope.** Every specialist agent gets a broad tool list. We do not narrow tools per agent.
8. **`proactive: true` on every agent** so Claude can spawn them whenever intent matches, without explicit `Task()` calls being required.
9. **Free-form `notes` field everywhere there's structured output.** Whenever a specialist returns a typed completion report (J20-style), include an `llm_observations` free-text field for whatever didn't fit the schema.
10. **Parent-folder access by default.** Settings include `additionalDirectories: ["../"]`.

---

## Phase 0 — Foundation (model, manifest, packaging)

| #     | Item                                                                                                                                    | File(s)                                                  |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| **A1** | Add a `model:` field to every agent. Use a moving alias (e.g., `claude-opus-latest` if the runtime supports it; otherwise have install.sh pull the current latest at install time and add a SessionStart self-check that warns if a newer model is available). | `.claude/agents/*.md`, `install.sh`, `session-start.sh` |
| **A2** | Set `MAX_THINKING_TOKENS` (or runtime equivalent) to maximum in `settings.json`. Add `Use extended thinking for all non-trivial work.` to every agent's system prompt — orchestrator, qa, backend, frontend, devops. | `.claude/settings.json`, `.claude/agents/*.md`           |
| **A3** | No mixed-model tiers. Opus 4.7 (or successor) on all 5 agents.                                                                          | (configuration only)                                     |
| **A5** | `/workflow-model` slash command (Claude-invokable, see principle #6) that rewrites the model field across all agents — used when a new generation lands. | new `.claude/commands/workflow-model.md`                 |
| **E1** | Convert plugin to proper Claude Code plugin format: add `.claude-plugin/plugin.json` with `name`, `version`, `description`, declared `agents`/`hooks`/`commands`/`skills`/`mcpServers`. | new `.claude-plugin/plugin.json`                         |
| **E16** | `additionalDirectories: ["../"]` in settings.json — parent-folder readable by default.                                                  | `.claude/settings.json`                                   |
| **D6** | Pin a minimum Beads version (e.g., `bd >= 0.47`); SessionStart hook fails fast with a clear message if older.                            | `install.sh`, `session-start.sh`                          |
| **G4** | install.sh and install.ps1 generated from a single source — eliminate the divergence (PowerShell currently ships shorter agent prompts). | `install.sh`, `install.ps1`, source-of-truth files       |
| **G5** | Ship `uninstall.sh` / `uninstall.ps1` — list what'll be removed, confirm, restore from latest backup if present.                         | new `uninstall.sh`, new `uninstall.ps1`                  |
| **G6** | Start `CHANGELOG.md` in keepachangelog.com format. Backfill v2 → v3 transition.                                                        | new `CHANGELOG.md`                                        |
| **G7** | Short `CONTRIBUTING.md` covering: how to add a specialist, how to extend hooks, how to test (forward-pointer to G8).                    | new `CONTRIBUTING.md`                                     |
| **G9** | Tone down emoji + ASCII separators across docs and scripts. Keep emoji only at H1/H2 markers; drop ASCII separators in script output.    | `docs/*`, `.claude/scripts/*`                             |

---

## Phase 1 — Correctness & Safety fixes

This phase fixes bugs that today silently corrupt state, bypass the QA gate, or produce malformed hook output.

| #      | Item                                                                                                                                                  | File(s) / Lines                                              |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| **B1 / D1 / J2** | **Replace marker-file QA bypass with maestro-style design-gate lifecycle.** Three Beads-backed operations: `enter_qa_gate(task)`, `qa_gate_status(task)`, `record_qa_approval(task, approved_doc)`. Gate is immutable once entered; only clears when an approved-document reference is recorded. Delete `verify-before-stop.sh:88-91` (`.qa-tracking/approved` marker bypass). | `verify-before-stop.sh`, new helper            |
| **B5** | Fix `post-edit.sh` to emit valid JSON envelope (`{"hookSpecificOutput":{...}}`), not raw markdown text.                                                | `post-edit.sh:55`                                            |
| **B6** | Replace narrow file-extension allowlist with a denylist (skip lockfiles, `node_modules/`, `dist/`, `.map` files, build artifacts) so .md/.json/.yaml/Dockerfile/.sh/.toml/.sql/.tf/.proto/.graphql/.swift/.kt/.c/.cpp/.h are tracked. | `post-edit.sh:12`, `verify-before-stop.sh:26`               |
| **B8** | `verify-before-stop.sh:112` placeholder bug — when no task is detected, render a Claude-friendly placeholder (Claude is the consumer per principle #6), not the literal `$TASK_ID` shell-string. | `verify-before-stop.sh:112`                                  |
| **B9** | Race condition in `post-edit.sh` dedup. Use `flock` or accept dupes + `sort -u` on read. **No user prompts** anywhere in this fix path.                 | `post-edit.sh:19-21`                                          |
| **B10** | Reset `edit-count` in SessionStart cleanup (it currently persists across sessions and breaks the every-10-edits batching).                            | `session-start.sh`, `post-edit.sh:34-36`                     |
| **B11** | `session-end.sh:8`: `cd "$PROJECT_DIR" \|\| { echo '{}'; exit 0; }`. Log bd-sync failures to `.claude/.qa-tracking/sync-errors.log` so SessionStart can surface them next session. | `session-end.sh`, `session-start.sh`                          |
| **B12** | `intent-router.sh:13-16` — drop the 10-char heuristic; skip on real signals (clearly conversational acks, slash-command-only inputs).                  | `intent-router.sh:13-16`                                      |
| **B13** | Drop the comment-text fallback in `verify-before-stop.sh:78-84`. Single source of truth: the `qa-approved` label set via `bd label add`.               | `verify-before-stop.sh:78-84`                                 |
| **B14 / D4** | **Trust Claude Code: remove all `permissions.deny` rules and broaden `permissions.allow` so specialists can do anything they need.** Per principle #3. | `.claude/settings.json:56-59`                                |
| **B16** | When `bd blocked` / `bd list --label qa-pending` is truncated, print `...and N more` so Claude knows how many were hidden.                             | `session-start.sh`                                            |
| **B17** | Anchor `hooks.json` PostToolUse matcher: `^(Write\|Edit\|MultiEdit)$`. (Worth doing since it's a one-line fix that prevents accidental matches like NotebookEdit if someone introduces it.) | `.claude/hooks/hooks.json:26`                                 |
| **D7** | Wrap CLAUDE.md content in `<project_memory>` fenced block when injecting into context — frame as data, not instructions.                                | `session-start.sh`                                            |

---

## Phase 2 — Agent definitions cleanup

| #      | Item                                                                                                                                                                                                | File(s)                                       |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| **C1** | Remove `Write, Edit` from orchestrator's tool list. **Do not otherwise scope orchestrator** (don't restrict Bash). Orchestrator delegates by behavior; the tool removal makes accidental code-writing structurally impossible. | `.claude/agents/orchestrator.md:4`           |
| **C2** | Add `AskUserQuestion` to orchestrator's tool list (referenced by its prompt's escape hatch but currently missing).                                                                                    | `.claude/agents/orchestrator.md:4`           |
| **C3** | QA agent's task discovery: explicit step `bd list --label qa-pending --status open --json` at top of QA workflow. Stop relying on undocumented Task()-prompt convention.                              | `.claude/agents/qa.md`                       |
| **C4** | **Specialists (qa, backend, frontend, devops): keep full broad tool set.** Per principle #7, no narrowing. (This is the explicit override of the original audit's C4 recommendation.)                 | `.claude/agents/{qa,backend,frontend,devops}.md` |
| **C5** | Add `proactive: true` (or runtime equivalent — e.g., `description` patterns Claude auto-spawns on) to every agent. Combined with intent-based routing, this lets the orchestrator skip explicit `Task()` calls when the work is unambiguous. | All five agents                              |
| **C6** | Strip emoji + ALL CAPS from agent prompts. Plain prose.                                                                                                                                              | `.claude/agents/*.md`                         |
| **C7** | Cross-reference between specialists and QA. Each specialist prompt gains a "QA will test [user-visible outcome]; design for testability" section, with concrete examples per role.                    | `.claude/agents/{backend,frontend,devops}.md` |

---

## Phase 3 — Specialist enrichment (closes the "all specialists are identical" gap)

Pull the dense, domain-specific bodies from the open-source plugins below into our specialist prompts. **Don't copy verbatim** — adapt structure and concrete checklists.

| #       | Item                                                                                                                                                                                                                                                       | Into                            | Source                                       |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- | -------------------------------------------- |
| **J24** | 6-section structure (API design / Database / System architecture / Security / Performance / DevOps) + OWASP-aware security subsection (JWT, RBAC, input validation, rate limiting, encryption at rest/in transit, parameterized queries) + "ship-pragmatic" framing. | `.claude/agents/backend.md`     | backend-architect                            |
| **J25** | Concrete performance budget (FCP <1.8s, TTI <3.9s, CLS <0.1, bundle <200 KB gzipped) + dependency-swap table (moment→date-fns, lodash→lodash-es, axios→fetch) + Server vs. Client Component decision matrix + Core Web Vitals + a11y/ARIA/keyboard-nav checklist. | `.claude/agents/frontend.md`    | senior-frontend + frontend-developer         |
| **J26** | 8-module security scan taxonomy (SECRETS → INJECTION → AUTH → CONFIG → DEPS → AI → MOBILE → DATA) including the LLM Top-10 module (hardcoded keys, prompt injection, eval-of-LLM-output, system-prompt leakage, excessive permissions). Tech-stack detection first, then run modules conditionally. | `.claude/agents/qa.md` (security pass) | security-sweep                               |
| **J27** | 5-step root-cause framework when QA finds failures: capture → reproduce → isolate → minimal fix → verify-and-prevent. Pair with structured output.                                                                                                          | `.claude/agents/qa.md` (failure path) | debugger                                     |
| **F7**  | Specialist completion contract: structured output `{task_id, files_changed[], tests_added[], decisions[], blockers[], llm_observations}`. The trailing `llm_observations` free-text field is mandatory per principle #9 — preserves room for "what the LLM thinks fits". | All specialist agents          | (audit-original + your modification)         |

---

## Phase 4 — QA gate redesign (the heart of v3)

This is where most of your selections cluster. The current Stop hook is a one-shot `npm test` wall; v3 makes it the multi-stage, intent-driven, regression-aware audit you described.

| #            | Item                                                                                                                                                                                                                                                                                                            |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **B2**       | **Per-task QA tracking + epic-level e2e gate.** Track each task's QA state independently (no more arbitrary "first in_progress" pick). When a task closes, if it has siblings under the same epic *or* shares files with another in-progress task, run an additional integration/e2e pass before marking the epic completed. |
| **F3**       | Single source of truth for "current task ID": `.claude/.qa-tracking/current-task` written when orchestrator/specialist claims a task, read by all hooks (intent-router, post-edit, verify-before-stop). Replaces the brittle `bd list --status in_progress \| jq '.[0].id'` repeated across 3 files.            |
| **B3**       | Stop hook test/lint timeouts: **15–20 minutes for `npm test`/equivalent**, ~60s for the wrapper. Capture stderr+stdout to a tempfile and surface a tail on failure (currently buried with `2>&1 >/dev/null`).                                                                                                  |
| **F8 / J17** | **Polyglot test/lint command + framework detection.** Detect `package.json` → npm; `pyproject.toml` → pytest; `go.mod` → `go test`; `Cargo.toml` → `cargo test`; etc. Allow project override via `.claude/test-cmd` and `.claude/lint-cmd`.                                                                       |
| **F1**       | Doc-only fast path. If the diff is comments / `*.md` / `*.txt` only, auto-approve with comment "QA auto-approved: doc-only".                                                                                                                                                                                    |
| **J18**      | **Conditional specialist selection — by intent, not keyword.** When the QA gate runs, the orchestrator (or a router skill) decides via LLM intent which sub-checks to run: e.g., "auth/permissions touched → security pass; hot path / loop touched → perf pass; UI components touched → a11y pass". *Not* regex over filenames or commit messages. |
| **J19**      | **Iterative review loop with regression check.** Phases: review → identify → auto-fix trivial → re-test → re-review changed files. **Plus regression coverage**: every iteration runs the full project type-check + full test suite (not just changed files), so changes in module A that break module B's public contract get flagged. |
| **J21**      | Decision gate at the end: present options (✅ approve / 🔧 continue / 📋 file as tech-debt in `TECHNICAL_DEBT.md` / 📌 defer to human). Replaces today's binary pass/block.                                                                                                                                       |
| **J22**      | `TECHNICAL_DEBT.md` artifact: deferred findings with severity + file:line + effort estimate. Each entry can spawn a Beads task.                                                                                                                                                                                  |
| **F4**       | Atomic QA approval — one operation that sets label + writes comment + (with J2) records gate-approval document. Must remain compatible with autonomy + intent-based skill selection (i.e., no extra confirmation steps).                                                                                          |
| **E3**       | PreToolUse hook that, when the active subagent is `orchestrator`, blocks `Write\|Edit\|MultiEdit` with a `decision: "block"` and a "delegate to specialist" reason. Structural complement to C1.                                                                                                                  |
| **E10**     | `defaultMode: "plan"` for the orchestrator. Complex requests start in plan mode by default; orchestrator exits to act after producing/confirming a plan.                                                                                                                                                          |

---

## Phase 5 — Best-practice integrations (Claude Code 2026 features the v2 plugin missed)

| #     | Item                                                                                                                                                                                                  | File(s)                                                             |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| **E2 / E15** | The `workflow-engine` skill is currently dead (no triggers). Per principle #4, the workflow loads always-on without trigger. Either: (a) auto-load via plugin.json registration, or (b) merge its content into orchestrator.md and delete the skill. Pick (a) so it remains a single-source-of-truth for workflow rules. | `.claude/skills/workflow-engine/SKILL.md`, `.claude-plugin/plugin.json` |
| **E4 / I2** | Statusline showing `[task-id] (qa: pending\|approved\|none) — N files changed`. Beads has the data; small bash script.                                                                                | `.claude/settings.json`, new `.claude/scripts/statusline.sh`        |
| **E5** | Real MCP-server integration: ship `bd-mcp` (J29) and the codebase-graph wrapper (J30) under `.mcp.json`. See Phase 6.                                                                                  | `.mcp.json`                                                          |
| **E8** | Memory system integration: when QA blocks for a domain reason ("team requires X for Y"), save a `feedback` memory so subsequent tasks pre-warn.                                                          | new memory bridge in `verify-before-stop.sh` or QA agent               |
| **E9** | Standardize all hooks on `hookSpecificOutput` envelope (intent-router already uses it; verify-before-stop and post-edit don't).                                                                          | `verify-before-stop.sh`, `post-edit.sh`                              |
| **E13** | Use TaskCreate / TaskUpdate as the *intra-session* breakdown of a Beads task into steps. Beads = cross-session; TaskCreate = within-session. Orchestrator emits both.                                  | `.claude/agents/orchestrator.md`                                     |
| **I1**  | Auto-invocation of QA approve/block (per principle #6). Internally, this is a Claude-callable command (or direct Beads call wrapped via bd-mcp J29).                                                    | new internal command or bd-mcp tool                                  |

---

## Phase 6 — MCP servers + external integrations

| #         | Item                                                                                                                                                                                                                                                       | File(s)                                                |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| **J29**   | **Build `bd-mcp`** — Beads exposed as native MCP tools (`bd_create_task`, `bd_approve_qa`, `bd_block_qa`, `bd_list`, `bd_show`, etc.) following mcp-builder's 4-phase methodology and agent-centric design (consolidate workflows, actionable error messages). Eliminates bash-string formatting in every hook. | new repo or `.claude/mcp/bd-mcp/`                       |
| **J3**    | **Cross-session task hooks (backlog-style)**: `SessionStart` shows pending tasks, `SubagentStart` auto-assigns the right pending task to the spawned agent. Replaces today's manual handoff via Task()-prompt strings.                                       | `session-start.sh`, new SubagentStart hook entry        |
| **J4**    | **Task docs** (`bd_doc_write` / `bd_doc_read` if shipped via bd-mcp, or via Beads notes): orchestrator attaches a SPEC document to a Beads task, downstream specialist `bd_doc_read`s it before implementing.                                              | bd-mcp + agent prompts                                  |
| **J30**   | **Codebase-graph integration** (or simpler tree-sitter-only context tool). Expose `code_search(query)` and `code_context(symbol)` as MCP tools. Orchestrator pre-loads relevant call sites before delegating to specialists; QA pre-loads call sites of changed symbols for regression assessment (pairs with J19). | `.mcp.json`, optional sidecar service                  |
| **I3**    | Auto-link Beads ↔ GitHub: when a task closes, post a comment on its parent issue/PR; when a PR opens with a `Closes #N` reference, link the Beads task. Use `gh` CLI or a github MCP server.                                                                | new helper or PostToolUse hook on `Bash(gh*)`         |
| **I8**    | Multi-repo workflow: today the plugin assumes single-repo. Beads supports multi-repo; the QA gate doesn't. Make the gate aware of cross-repo tasks (consume Beads' multi-repo metadata; gate at the right repo's HEAD). Document any setup steps in CONTRIBUTING. | `verify-before-stop.sh`, docs                          |

---

## Phase 7 — Validation & meta-checks

| #       | Item                                                                                                                                                              | Notes                                                                                                |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **J32** | Run **AgentLint** on this plugin's CLAUDE.md, every agent prompt, and the new plugin.json. 51 evidence-backed checks across Findability/Instructions/Workability/Safety/Continuity/Harness. Treat findings as the third-party diff against everything Phase 0–6 just changed. | Tool: https://github.com/0xmariowu/AgentLint                                                          |

---

## Deferred — G8: Plugin self-testing strategy (separate research task)

You explicitly want this as a follow-up. The vision: a comprehensive testing strategy where **Claude itself spins up a child Claude Code session** to exercise the plugin end-to-end on a real-ish project, then verifies behavior and outputs.

Rough scope to plan in the next round:

- A test harness that, given a plugin install, can:
  1. Spawn a child Claude Code session in a clean test project
  2. Issue a sequence of realistic prompts ("add an auth endpoint", "fix this bug", "refactor X")
  3. Capture the resulting Beads tasks, file edits, hook outputs, QA gate transitions
  4. Assert on outcomes: did the right specialist get called? did the QA gate fire? did the test/lint actually run with the right timeout? did the polyglot detection pick the right runner?
- Test fixtures: 4-5 representative project skeletons (Node/React, Python/Django, Go service, Rust CLI, monorepo)
- Failure-injection: deliberately broken code, racy edits, intentionally-bad tests — verify the QA gate blocks correctly
- Regression suite: each item from Phases 0–6 gets at least one corresponding behavior test

This will need its own plan (which agents to use, where the harness lives, how to make it CI-runnable, etc.). Tracked as deferred — surface it again when Phases 0–6 are far enough along to be testable.

---

## Critical files (where most edits will land)

- `.claude-plugin/plugin.json` — new (Phase 0)
- `.claude/agents/{orchestrator,qa,backend,frontend,devops}.md` — model pinning, tool fixes, prompt enrichment, proactive flag (Phases 0/2/3)
- `.claude/scripts/verify-before-stop.sh` — gate redesign (Phases 1/4)
- `.claude/scripts/post-edit.sh` — JSON envelope, denylist, race fix (Phase 1)
- `.claude/scripts/intent-router.sh` — current-task source, intent skip (Phases 1/4)
- `.claude/scripts/session-{start,end}.sh` — sync error log, edit-count reset, CLAUDE.md framing, additionalDirectories surface (Phases 1/5)
- `.claude/hooks/hooks.json` — anchored matcher, PreToolUse for orchestrator restriction, SubagentStart (Phases 1/4/6)
- `.claude/settings.json` — model thinking budget, full-allow permissions, `additionalDirectories: ["../"]`, defaultMode plan, statusLine (Phases 0/1/4/5)
- `.claude/skills/workflow-engine/SKILL.md` — auto-load wiring (Phase 5)
- `.claude/mcp/bd-mcp/` — new MCP server for Beads (Phase 6)
- `.mcp.json` — bd-mcp + codebase-graph wiring (Phase 6)
- `install.sh` / `install.ps1` / new `uninstall.sh` / new `uninstall.ps1` — single-source-of-truth refactor + uninstall (Phase 0)
- `CHANGELOG.md` / `CONTRIBUTING.md` — new (Phase 0)
- README + `docs/QUICKSTART.md` — fix YOUR_ORG placeholders, document new model pinning, statusline, MCP servers, multi-repo (Phase 0/5/6)

---

## Verification (high-level — full strategy deferred to G8)

For each phase, before moving to the next:

1. **Phase 0**: install in a clean test directory; check plugin.json validates; confirm uninstall reverses everything; SessionStart shows current model + warns on staleness if applicable.
2. **Phase 1**: synthetic stdin payloads against each hook script (`echo '{"stop_reason":"end_turn"}' | bash verify-before-stop.sh`) — assert exit codes and JSON envelopes. Verify the marker-file bypass no longer works (touch the file, confirm the gate still blocks).
3. **Phase 2**: load each agent in a Claude session; trigger a delegation; confirm tool list is right and `proactive: true` actually causes auto-spawn on intent.
4. **Phase 3**: feed the agent a realistic auth-endpoint task; verify the specialist's enriched prompt produces an OWASP-aware implementation.
5. **Phase 4**: build a fixture with auth changes; confirm intent-based selection runs the security pass; verify regression test catches a deliberately-introduced break in an unchanged module.
6. **Phase 5**: confirm statusline updates live; confirm memory writes occur on QA-block; confirm TaskCreate/TaskUpdate populate the in-session list.
7. **Phase 6**: bd-mcp tool calls succeed; cross-session handoff works (close session, reopen, SubagentStart picks up the right task); GitHub link comments post correctly.
8. **Phase 7**: run AgentLint, address any blockers it surfaces.

Full E2E behavior testing is the deferred G8 task.

---

## Execution mode

This is a 7-phase project with strong inter-phase dependencies (Phase 4's gate redesign depends on Phase 1's fixes; Phase 6's MCP work depends on Phase 0's plugin manifest). Recommend executing in order, but Phases 2/3 can run in parallel with Phase 1, and Phase 7 (AgentLint) should run continuously after Phase 0 completes.

When you approve this plan, I'll spawn specialist agents to implement each phase, opening a Beads epic per phase with sub-tasks per item, and routing through the orchestrator → backend/frontend/devops → qa flow that the v2 plugin already has — eating the plugin's own dogfood as we upgrade it.
# Verification suite — Phases 0/A/B/C (v3.1.0 – v3.4.0)

> Provenance: operator-authored spec, received 2026-06-11. Copied verbatim per
> its own bootstrap instruction. Execution mapping lives in the session plan;
> Beads epics link back here via task docs.

You are upgrading the claude-workflow-plugin repository — the same plugin loaded in this session. Dogfood it: the orchestrator decomposes, specialists implement, QA gates every change. Four workstreams ship in sequence as Phases 0, A, B, and C. Each phase is its own Beads epic with child tasks per deliverable.

## Read first

1. `CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/plans/v3-upgrade.md` — conventions and style baseline
2. `.claude/tests/README.md` — the five-tier pyramid and META-TEST convention. Note: 0.8 below retires golden-cassette equality and the L4 drift schedule; read the current doc to understand what is being replaced.
3. `docs/HOOKS.md` — the qa-gate.sh state machine and verify-before-stop.sh contract; Phase 0 changes both
4. `docs/MCP_SERVERS.md` and `.mcp.json` — note the `_phase7_codebase_graph_target` placeholder; Phase B fills it
5. `docs/AGENTS.md` — the F7 completion contract, J26 security taxonomy, J27 root-cause framework, J21 decision gate
6. `CONTRIBUTING.md` — "Design overrides vs. AgentLint"

Then copy this document to `docs/plans/verification-suite.md`, add an index entry to `docs/plans/README.md`, and open one Beads epic per phase (linked via `bd doc write`) before writing any code.

## Cross-cutting principles

These extend the v3 principles. Where they conflict with anything older, these win.

1. **Always the best available model.** On every SessionStart, resolve the most capable model available to this account — newest family first, largest context variant where offered — and apply it across all agents automatically. A model released minutes ago is a valid target. Mechanism in 0.3. Every auto-switch is logged in Beads and is reversible with one `/workflow-model` call. A model switch never triggers any paid test run.
2. **Maximum effort, maximum thinking.** Set the highest supported effort level alongside the existing `MAX_THINKING_TOKENS` max. Verify the current setting names against the Claude Code docs rather than guessing; fail open (keep defaults, log a warning) where a model lacks the knob.
3. **Time budget is high.** Every agent prompt carries this: take the time the task needs; gather context exhaustively — read the files, trace the call paths, consult the code graph when present — before acting; never compress analysis to finish sooner. Depth beats speed in every trade.
4. **Evidence before fixes. Guessing is prohibited.** No bugfix lands without a deterministic reproduction, a failing test written first, and a root-cause statement backed by evidence. When confidence is not total: instrument, collect logs, or ask the user for logs/repro/access via AskUserQuestion — do not patch. Protocol in 0.5; Phase A enforces it via rubric.
5. **Worktree isolation for parallel specialists.** Two or more concurrently spawned specialists always get isolated worktrees. Same-tree parallel agents contaminating each other's branches is a known production failure (lessons ledger, 0.7).
6. **One approval source of truth.** The `qa-approved` label remains the only signal the Stop hook trusts (v3 decision B13). New verdicts — rubric, mutation — are inputs the QA agent consumes before approving, never parallel gates wired into `verify-before-stop.sh`. The single deliberate exception is the audited `qa-deferred` escape introduced in 0.2.
7. **Thin-wrapper rule.** Grader verdicts, mutation findings, model switches, and lessons are recorded as Beads comments and labels. Engines can swap out later; the audit trail stays.
8. **Every new behavior lands with a test at the right tier plus a META-TEST** proving the assertion fails when the behavior it guards is mutated. All META-TESTs operate on recorded traces offline — they never require a live run.
9. **No automatic paid runs. Live testing is a development-cycle activity.** The free deterministic tiers (L1 bash unit, L2 component, L3 vitest unit) are the always-on gates and run in CI per PR at zero API cost. Any test infrastructure that consumes API spend — live e2e fixtures, mutation generation, judge calls — runs only by explicit manual invocation while actively developing the plugin. No cron schedules, no scheduled CI jobs, no model-switch triggers, no side-effect runs. Live assertions are model-agnostic invariants (0.8), never golden-trace equality, so riding a new model never invalidates the suite or forces a re-recording cycle.
10. **Doc style matches CLAUDE.md.** No emphasis-keyword spam, Dont/Because rule format, action-oriented headings.
11. **Per-phase closeout:** `make test-all`, `make check` (document any new intentional AgentLint overrides in CONTRIBUTING.md), CHANGELOG.md entry, HANDOFF.md verify conditions, plugin.json version bump (0 → 3.1.0, A → 3.2.0, B → 3.3.0, C → 3.4.0), then the landing-the-plane protocol from AGENTS.md. A phase is not done until `git push` succeeds.
12. **Escape hatch.** If blocked after 2–3 attempts on any design decision below, use AskUserQuestion rather than looping.

---

## Phase 0 — Hotfixes and agent policy (v3.1.0)

Two production bugs, five policy upgrades, and the live-test economics rework. Ship as one epic.

### 0.1 Fix MCP path resolution in installed projects (bug)

Evidence: MCP Config Diagnostics in an installed target project report, for the project-scoped `.mcp.json`: `[bd] mcpServers.bd: Missing environment variables: CLAUDE_PROJECT_DIR` and the same for `code-context`. The servers fail to load in any repo other than the plugin's own.

Fix: audit `.mcp.json`, `.claude-plugin/plugin.json`, and both installers. First verify against the current MCP configuration docs (the diagnostic links them) which variables Claude Code actually expands inside `.mcp.json` — do not assume. Then remove the dependency on anything not guaranteed-expanded, in order of preference: (a) a variable the docs guarantee for project-scoped MCP config, (b) project-relative paths for stdio `args` if supported, (c) install-time substitution of the resolved absolute path by install.sh/install.ps1, re-rendered on upgrade. Update both manifests in the same commit (they must agree).

Tests and acceptance: an L2 installer test renders a fresh install into a clean temp project and asserts the resulting config contains no unresolved `${...}` references to undefined variables. Acceptance is a fresh install where MCP diagnostics show zero warnings and both servers connect.

### 0.2 Make the QA-gate escalation cap binding (bug)

Evidence: a live gate transcript shows `ESCALATION: Iteration 7 (>= 3)` — four iterations past the cap — still re-printing the J21 options and re-running the full test suite on every loop, with no behavioral consequence.

Fix: extend the `qa-gate.sh` state machine with an `escalated` state.

- First cap hit: record a `qa-escalated` label plus a comment listing the four J21 options. While escalated, Stop evaluations skip the full-suite re-run (reuse the last recorded result) and the block reason changes to "escalated — record a J21 choice before iterating further."
- If one more Stop occurs with no recorded choice: auto-select option 4 (defer). Set a `qa-deferred` label with a comment, leave the task `qa-pending`, and allow Stop. `verify-before-stop.sh` treats `qa-deferred` on the active task as allow — this is the single audited escape valve permitted under principle 6. SessionStart surfaces deferred tasks at the top of the next session.
- Iteration counter resets on QA approval and on active-task change.
- Classify "Test suite failed to run" (runner/infrastructure errors — e.g., a testcontainers `cleanup` TypeError) distinctly from assertion failures in the block message, so the next iteration targets the environment first instead of burning a loop on code.

Tests: L1 for cap and state transitions; L2 for escalated → recorded choice and escalated → auto-defer; META-TEST mutates the iteration counter persistence — the cap assertion must fail. Acceptance: an offline replay of the captured scenario stops re-running the suite at iteration 4 and lands on a recorded J21 decision by iteration 5 at the latest.

### 0.3 Automatic best-model selection on every session

New helper `.claude/scripts/model-select.sh`, wired into SessionStart.

- Resolve the set of models available to this account (verify the current mechanism — CLI listing, API endpoint, or moving aliases — against the docs).
- Rank by family tier using a config file `.claude/model-ranking` (one line per family in preference order), so brand-new families slot in with a one-line edit. Add an unknown-newer heuristic: a model id within a known family carrying a higher version than anything in the ranking is auto-preferred. Prefer the largest-context variant of the chosen model where multiple are offered.
- If the resolved best differs from the current pin: rewrite agent `model:` fields through the existing `/workflow-model` machinery and post a Beads comment on a standing meta-task recording old → new and the rollback command.
- The only post-switch validation is free: confirm the new model id resolves in the listing. Do not trigger any inference-based check, drift run, or fixture as a side effect of a switch.
- Keep SessionStart fast: cache the lookup for up to an hour; on lookup failure, keep the current pin and emit a one-line warning — never block the session.

### 0.4 Maximum effort and high time budget

Set the highest supported effort level in `settings.json` (verify the current knob name in the docs; apply per-agent where the runtime supports it) alongside the existing `MAX_THINKING_TOKENS` maximum. Add a shared time-budget block to all agent prompts, orchestrator included, with the principle 3 language: high time budget, exhaustive context gathering before acting, no compressing analysis to finish sooner, generous timeouts on long-running commands.

### 0.5 Evidence-before-fix protocol (extends J27)

Add to `qa.md` and all three implementation specialists, applying to every bug-typed task:

1. Reproduce deterministically before anything else.
2. Write the failing test first — it encodes the root cause, not the symptom.
3. Attach a root-cause statement to the Beads task: "X did Y because W; evidence: Z" with the actual evidence (trace, bisect result, log excerpt).
4. Declare confidence. If it is not total: do not patch. Instrument the code, collect logs, or use AskUserQuestion to request logs, reproduction details, or access from the user. Asking is always cheaper than a wrong fix.
5. The fix must flip the failing test from step 2.
6. If a shipped fix bounces — the issue persists after merge — twice, return to evidence mode is mandatory, with an escalation comment naming the prior attempts.

Name the anti-pattern explicitly in the prompts: symptom-patching chains, where speculative fixes stack into double-digit follow-up PRs for a single issue.

### 0.6 Worktree isolation for parallel specialists

Update the orchestrator's delegation rules: when spawning two or more specialists concurrently, give each an isolated worktree (verify the current mechanism — agent frontmatter or Task parameter — against the docs) and ship a `.worktreeinclude` covering env files so worktrees are runnable. Serial single-specialist work is unchanged.

### 0.7 Lessons ledger

New helper `.claude/scripts/lessons.sh add '<lesson>' --source <task-id>`: dedup-appends to `LESSONS.md`. `CLAUDE.md` gains a pointer to it; the orchestrator reads it during planning and the grader (Phase A) receives it in the grading packet. QA's epic-close step proposes candidate lessons — the existing "memory I'd recommend you internalize" outputs become `lessons.sh` calls instead of chat text. Seed the ledger with the two production lessons:

1. Parallel agents in the same working tree contaminate each other's branches; concurrent specialists require worktree isolation.
2. Boundary mocks must use the real downstream producer's shape, pinned via a fixture extracted from the producer's spec — never invented. A mock that feeds `body.error` so the test can assert `body.error` is circular and proves nothing.

### 0.8 Retire golden-cassette equality; make live testing manual and invariant-based

Evidence: golden cassettes are per-model artifacts — structural fingerprints drift across model versions even after normalization, so a day-zero model-upgrade policy makes every golden stale on arrival. A recent refresh cycle burned roughly $400 with tests still failing afterward, and the L4 drift cron was disabled for the same reason. The mechanism is incompatible with the model policy in principle 1; replace it rather than run it less.

Changes:

- **Remove every automatic paid run.** Delete the L4 scheduled drift job and any scheduled or per-PR L3-live CI jobs; convert any remaining live entry points to manual `workflow_dispatch` only. After this item, a full CI run consumes zero API spend.
- **Guard manual live runs.** `make test-live` requires an explicit `FIXTURE=<name>` and exits with usage otherwise. Multiple fixtures require `FIXTURES=...`. Before starting, print an estimated cost (per-fixture estimate from the tests README) and require confirmation unless `CONFIRM=1` is set.
- **Replace golden equality with model-agnostic invariants.** Keep the trace recorder and normalization pipeline; retire golden-trace comparison as a gate. Each fixture's `fixture.yaml` declares an invariant set asserted over the recorded trace, for example: the Stop hook never allowed completion without `qa-approved` (or `qa-deferred` per 0.2) on the active task; the orchestrator performed no Write/Edit/MultiEdit; every specialist completion payload carried all six F7 fields; required label milestones appear in order as a subsequence (extra intermediate steps allowed — this replaces `expected_label_progression` equality); every spawned subagent matches a declared specialist. Invariants are properties of the workflow contract, so they hold across model versions by construction.
- **Goldens become optional debugging references.** Keep `cassette-diff` as a manual inspection tool; remove it from any gating path. Existing recorded cassettes are retained as the seed corpus for testing the invariant engine itself.
- **META-TESTs carry over unchanged in spirit and stay free:** mutate a recorded trace to violate each invariant and assert the engine detects it. No live run is ever needed for META-TEST coverage.

Files: `.github/workflows/test.yml`, the e2e harness specs, the `fixture.yaml` schema, `.claude/tests/README.md` (rewrite the golden-cassette section as the invariant reference), `Makefile`, README caveats section.

Tests and acceptance: L3 vitest covers the invariant engine against the retained recorded traces, including one deliberately mutated trace per invariant. Acceptance: CI is green with zero API spend; `make test-live` without `FIXTURE` exits with usage; a violated trace fails the matching invariant by name.

### Phase 0 closeout

Files touched: `.mcp.json`, `.claude-plugin/plugin.json`, `install.sh`, `install.ps1`, `.claude/scripts/{qa-gate.sh,verify-before-stop.sh,session-start.sh,model-select.sh,lessons.sh}`, `.claude/settings.json`, all six agent prompt files, `.claude/model-ranking`, `LESSONS.md`, `.github/workflows/test.yml`, the e2e harness and `fixture.yaml` schema, `.claude/tests/README.md`, `Makefile`, `docs/HOOKS.md`, `docs/WORKFLOW.md` (label table gains `qa-escalated`, `qa-deferred`). Then the principle 11 checklist.

---

## Phase A — Rubric-grader QA loop (v3.2.0)

Goal: before QA approves any task, a separate-context grader agent scores the work against a versioned rubric, and the specialist iterates until the verdict is satisfied or the loop escalates.

### Design

- New agent `.claude/agents/grader.md`. Read-only tools (Read, Grep, Glob, LS). `proactive: false` — it is spawned deliberately by the QA agent, never auto-routed. The grader must not see the specialist's conversation; its entire input is a grading packet assembled by QA: the `bd show` output, the SPEC doc (`bd_doc_read`), the diff of files listed in `.qa-tracking/changed-files.txt`, the F7 completion contract, and `LESSONS.md`. The separate context is the mechanism — it prevents self-critique contamination.
- Grader output is strict JSON: `{verdict: "satisfied" | "needs_revision", criterion_results: [{criterion, pass, justification}], required_fixes: [], iteration: N, rubric_version: "..."}`. One-line justification per criterion; pass/fail only, no numeric score theater.
- Rubrics at `.claude/rubrics/{default,backend,frontend,devops}.md` with frontmatter `version: 1`. Domain rubrics extend default. A task-type overlay `.claude/rubrics/bugfix.md` applies additionally whenever the task type is `bug`.
- Default rubric criteria for v1: behavior matches the task description and SPEC; tests added exercise user behavior rather than implementation; the completion contract carries all six F7 fields with a substantive `llm_observations`; no unrelated scope in the diff; the J26 modules relevant to the diff were addressed; docs updated where behavior changed; **boundary-mock fidelity** — mocks of boundaries the project does not control derive their shape from a fixture extracted from the real producer's spec (the fixture's source is cited), and circular pass-through assertions are an automatic needs_revision.
- Bugfix overlay criteria, enforcing 0.5: a failing test demonstrating the root cause exists and predates the fix in the commit sequence; the root-cause statement with cited evidence is attached to the task; the fix rationale contains no speculative language ("might", "should fix", "probably"); the fix flips the failing test.
- Loop wiring: the QA agent flow gains a grading step before approval. A `needs_revision` verdict reuses the existing qa-blocked → specialist → re-review round-trip, with `required_fixes` pasted into the block comment. Iteration cap: 3 by default, overridable in `.claude/rubric-config`. On hitting the cap, the escalation path from 0.2 engages — and after 0.2, it is binding.
- Recording: `qa-gate.sh enter` additionally sets a `rubric-pending` label. New subcommand `qa-gate.sh grade-record` appends a comment `RUBRIC <version> iteration <n>: <verdict> — <one-line summary>` and on `satisfied` flips `rubric-pending` → `rubric-satisfied`. QA approval comments must cite the final rubric verdict; approving without `rubric-satisfied` requires an explicit override reason inside the approval comment.
- `verify-before-stop.sh` is not modified for gating (principle 6). Optionally extend `statusline.sh` to show rubric state alongside qa state if the cost is one extra `bd show` field read.

### Files

`.claude/agents/grader.md` (new), `.claude/rubrics/*.md` (new, including bugfix overlay), `.claude/scripts/qa-gate.sh` (extend), `.claude/agents/qa.md` (grading step + override rule), `docs/AGENTS.md`, `docs/WORKFLOW.md` (label table gains `rubric-pending`, `rubric-satisfied`).

### Tests

- L1: `qa-gate.sh grade-record` happy path; malformed verdict JSON rejected with a structured error.
- L2 (the permanent regression coverage, free and offline): a stubbed grader emitting scripted verdicts drives the full loop — pending → needs_revision → satisfied; cap reached → 0.2's escalated state engages.
- META-TEST: mutate a recorded trace's verdict from satisfied to needs_revision — the milestone-subsequence invariant must fail. Offline.
- Dev-cycle live validation (manual, once, during this phase): add a `rubric-revision-loop` fixture seeding a deliberately under-tested change, with invariants declaring the ordered milestones `rubric-pending` → `rubric-satisfied`. Run it via `make test-live FIXTURE=rubric-revision-loop`, record the result and cost in the phase closeout notes. It is not a CI gate.

### Acceptance

On the stubbed L2 loop, the under-tested change receives `needs_revision` with at least one actionable `required_fix`, then passes after revision. A seeded circular-mock test and a seeded fix-without-failing-test both produce needs_revision citing the right criterion. `bd show` reads as a complete audit trail. Stop-hook semantics unchanged beyond 0.2. The one manual live run passes its invariants.

---

## Phase B — code-graph MCP (v3.3.0)

Goal: replace `code-context-mcp` with a tree-sitter + SQLite code-graph server that honors the stable tool surface and adds impact analysis. This fills the `_phase7_codebase_graph_target` placeholder.

### Design

- New server `.claude/mcp/code-graph-mcp/` — Node, stdio, same layout as the two sibling servers. Prefer zero-native-compile dependencies (web-tree-sitter with vendored wasm grammars; wasm SQLite) so install never hits node-gyp. If you choose a native dependency instead, document why in the server README and verify the install.sh copy path still works.
- Path resolution must use the scheme validated in 0.1 — the new server must load cleanly in installed target projects, not just this repo. Add that case to the 0.1 installer test.
- Tool surface, capped at 7. Keep `code_search`, `code_context`, `symbol_callers` byte-compatible with the current server. Add: `impact_of(symbol | file)` — transitive callers and dependents with a depth cap; `dead_code(scope)` — unreferenced exports; `dependency_path(from, to)`; `code_index_health()` — staleness, per-language coverage, last index time. Error messages stay agent-centric per bd-mcp's conventions: say what was wrong and what a valid call looks like.
- Language set matches `detect-stack.sh`: ts/js/tsx, python, go, rust, java, ruby, php, bash.
- Index at `.claude/.code-graph/index.db`, gitignored. Incremental by content hash. Lazy build on first tool call — do not touch SessionStart (timeout risk).
- Manifest rule: update `.mcp.json` and `.claude-plugin/plugin.json` in the same commit. Remove the placeholder key. Delete `code-context-mcp` only after the new server's tests pass, and note the removal under a migration heading in CHANGELOG.
- Agent wiring: the orchestrator's pre-delegation step calls `impact_of` for likely-touched symbols and attaches results to the SPEC doc. The QA regression step calls `impact_of` for every changed symbol and treats high-fan-in hits as mandatory regression candidates — this extends J19. Update `docs/MCP_SERVERS.md`, including the "how they work in concert" section.

### Tests

- L3 vitest: indexer correctness on committed polyglot fixtures with known call graphs; incremental reindex fires on hash change and not otherwise; search query correctness.
- L2: server boots over stdio; health tool responds; malformed args produce actionable errors; loads in a rendered fresh-install target (0.1 scheme).
- META-TEST: corrupt the index file — `code_index_health` must report unhealthy, and the spec asserting health must fail when the health check is stubbed to lie. Offline.
- Dev-cycle live validation (manual, once, during this phase): run `make test-live FIXTURE=node-react-auth` and confirm the invariants hold with the new server in place; add a fixture-declared invariant that the QA step queried `impact_of` for every changed symbol. Because gating is invariant-based after 0.8, the changed trace shape requires no golden refresh.

### Acceptance

On a seeded fixture, `impact_of` returns the known transitive caller set and `dead_code` finds a seeded orphan export. Document a before/after token comparison for one orchestrator decomposition (exploration with `code_context` only vs with `impact_of`) in the server README — measured once during this development cycle; keep the raw numbers.

---

## Phase C — Mutation testing with LLM-judge filter (v3.4.0, tier L3.5)

Goal: an on-demand mutation sweep that generates fault-class mutants for hook scripts and MCP servers, filters equivalent mutants with a separate-context judge before any execution, runs survivors against the free tiers, and converts surviving mutants into proposed tests routed through the normal QA gate.

### Design

- New tier `.claude/tests/mutation/` with harness `mutation-sweep.sh` and a Claude-invokable command `.claude/commands/mutation-sweep.md` (v3 principle: commands are for Claude, not humans).
- **Cadence: development cycles only.** The sweep runs via `make mutate` or `/mutation-sweep` when explicitly invoked while working on the plugin. No cron, no scheduled job, no CI wiring beyond an optional manual `workflow_dispatch`. Generator and judge calls are the only paid component and exist solely inside an explicit invocation.
- Generator: an LLM step produces up to K mutants per target file from a fault catalog written for this codebase: inverted conditionals, off-by-one on caps and counters, swapped Beads label strings, dropped jq fallbacks (`.file_path // .path`), wrong `hookSpecificOutput` keys, removed regex anchors, removed flock. The catalog lives at `.claude/tests/mutation/fault-classes.md` so it is reviewable and extensible. Fault classes touching destructive commands (rm, mv, git push, anything network-mutating) are excluded by design.
- Judge: a separate-context subagent classifies each mutant equivalent / non-equivalent before any execution. Commit a hand-labeled calibration set of at least 20 mutants at `.claude/tests/mutation/calibration/`; every sweep reports judge precision and recall against it and fails the run if precision drops below 0.8. The filter is the product — generation is cheap, filtering is what makes the results trustworthy.
- Execution containment: apply mutants only in a throwaway git worktree; run only L1 and L2 (the free tiers) against them, never live fixtures; clean up the worktree even on failure. Disable network for mutant test commands where the runner supports it.
- Survivors: each surviving non-equivalent mutant becomes (a) a drafted killing test, (b) a Beads task with a `discovered-from` dependency, and (c) a TECHNICAL_DEBT.md entry via `tech-debt.sh` when the test is deferred. Drafted tests go through the normal specialist → QA gate like any other change.
- Budget: caps in `.claude/tests/mutation/config` (mutants per file, total per sweep, judge-call cap). Print an estimated cost before starting and require confirmation unless `CONFIRM=1`, matching the 0.8 convention. Log total sweep cost in the run summary.
- Target ranking: if Phase B is live, rank targets by `impact_of` fan-in; otherwise rank by lowest L1/L2 coverage. The harness must run without the code-graph server present.

### Tests

- L1: harness argument parsing, cap enforcement, worktree cleanup on failure, cost-confirmation gate.
- META-TEST pair, the canary for the whole tier: a seeded known-killable mutant must be killed by the existing suite (if it survives, the harness flags itself); a seeded equivalent mutant must be filtered by the judge (if it reaches execution, the run fails).

### Acceptance

The first sweep — run manually during this development cycle — over `verify-before-stop.sh` and `post-edit.sh` produces at least one genuine surviving mutant whose killing test is accepted through the QA gate. Judge precision is at or above 0.8 on the calibration set. Sweep cost appears in the run summary.

---

## Sequencing

0 → A → B → C. Phase 0 ships first because 0.1 unblocks MCP loading in installed projects (Phase B depends on its resolution scheme), 0.2 makes the escalation that Phase A's rubric loop leans on actually binding, and 0.8 provides the invariant harness that Phases A and B use for their one-time live validations. C consumes B's `impact_of` when available but must degrade gracefully without it. Do not start a phase before the previous phase's closeout checklist (principle 11) is green.

## Definition of done

All four epics closed in Beads with `qa-approved` on every child task. A fresh install into a clean target project shows zero MCP diagnostics warnings. An offline replay of the captured escalation scenario lands on a recorded J21 decision within two iterations of the cap. CI is fully green at zero API spend, and no scheduled paid job exists anywhere in the repo. Each phase's single manual live validation is recorded in its closeout notes with fixture name, invariants passed, and cost. AgentLint score documented in `docs/AGENTLINT_REPORT.md` with any new overrides explained. CHANGELOG reads as coherent release notes for 3.1.0–3.4.0. README's "What you get" table and caveats updated: 6 agents, rubric files, 2 MCP servers, invariant-based live testing (manual only), lessons ledger.

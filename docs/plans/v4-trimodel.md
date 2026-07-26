# v4.0.0 — Tri-model workflow: Fable plans, Opus builds, Sol tries to break it

Paste this entire document as the opening prompt in a Claude Code session at the root of the claude-workflow-plugin repository. This is a major release on top of v3.5.0 (shipped 2026-06-15). Everything ships through the plugin's own gates.

---

You are implementing a tri-model workflow on top of the existing v3.5 architecture: the orchestrator runs on the newest, most capable Claude family (Fable-class today), implementation specialists run on the strongest Opus-class implementer (Opus 4.8 today), and an optional external reviewer lane runs on the latest OpenAI model (GPT-5.6 Sol today) via the Codex CLI's MCP server mode. The governing rule is: **nobody signs off on their own work** — the implementer implements, the reviewer reviews, the orchestrator arbitrates disagreements, and the existing change-set-hash-bound QA gate remains the only thing that can release.

## Read first

1. `CLAUDE.md`, `docs/plans/README.md` and the v3.5 plan it indexes, `LESSONS.md` — current state and accumulated lessons
2. `docs/HOOKS.md`, `docs/MCP_SERVERS.md`, `docs/AGENTS.md` — the gate state machine, both MCP servers, the seven agents and completion contracts
3. The current Claude Code changelog and docs (code.claude.com/docs) — several July 2026 platform changes are load-bearing below; verify every platform claim in this document against the live docs before acting on it
4. Open PRs on the repo — PR #2 (impact-report path relativisation) is merged as part of Phase V4

Then copy this document to `docs/plans/v4-trimodel.md`, index it in `docs/plans/README.md`, and open one Beads epic per phase before writing code.

## Cross-cutting principles

Inherited unchanged from v3.x: no automatic paid runs (anything costing tokens is manual, dev-cycle-only, with cost confirmation); prompts are suggestions, mechanics are guarantees; evidence-before-fix; day-zero model adoption; worktree isolation for parallel specialists; doc style per CLAUDE.md; per-phase closeout with landing-the-plane; escape hatch via AskUserQuestion after 2–3 stuck attempts. New for v4:

1. **Single source of truth is untouchable.** The change-set-hash-bound `qa-approved` record remains the only release credential. The Sol lane, the second opinion, and arbitration are all inputs feeding the existing gate — never a parallel approval path. If any design choice below would create a second way to release, stop and redesign.
2. **Nobody signs off on their own work — mechanically.** The gate, not a prompt, enforces that the approval cites an independent review artifact whose reviewer identity differs from the implementing specialist.
3. **Sol is strictly optional.** Feature-detect the Codex MCP connection at session start. Absent: zero behavior change — the fresh-context Claude review path covers the reviewer role. Present: Sol reviews feed the grader/QA packet as advisory input. All tests must pass in both configurations.
4. **Bounded diligence.** Every review delegation carries an explicit `risk_threshold` and `stop_condition`, and the harness enforces caps on findings and iterations. Thorough reviewer models loop forever without this; the bound is mechanical, not stylistic.
5. **Effort is ultracode or max everywhere, decided empirically.** Phase V0 runs the interference test; its verdict sets the default for every Claude agent. The OpenAI side always runs its maximum reasoning effort (`xhigh`). No agent anywhere runs below the verdict level.

## Phase V0 — Platform restore and effort verdict (v4 prerequisite)

The tri-model loop cannot ship on a session that no longer orchestrates. Restore delegation first, then decide ultracode vs max.

Platform restore — verify each item against the current changelog/docs, then fix:

- Find and remove the `CLAUDE_CODE_EFFORT_LEVEL=max` export (shell profiles, settings `env` blocks, service definitions). Per the model-config docs this env var overrides every other effort mechanism, and a non-xhigh value keeps ultracode's orchestration layer inactive — the most likely cause of "does everything in the main session."
- Set `effortLevel: "xhigh"` in `settings.json` as the persistent floor (`max`/`ultracode` are session-only and rejected there). Wire the session launch path to pass the effort flag per the V0 verdict below.
- Fix the failing `bd` MCP server in installed projects: use `${CLAUDE_PROJECT_DIR:-.}` (bare `${CLAUDE_PROJECT_DIR}` does not expand in hand-written project `.mcp.json`), strip hidden whitespace from config values, confirm `"type": "stdio"`, and re-accept workspace trust — since v2.1.196 project `.mcp.json` servers self-approved via committed settings are no longer spawned in untrusted workspaces.
- Audit for the July behavior changes: nested subagent spawning is off by default since v2.1.217 (set the documented depth env var only if the workflow needs depth > 1); the Task tool `mode` parameter is deprecated and ignored since v2.1.212; per-session subagent caps exist (verify names and defaults); agent-file folders must have accepted workspace trust or their frontmatter hooks silently disable (v2.1.218).
- Confirm workflows are enabled (no `disableWorkflows` / disable env var) — ultracode does not exist without them.

Effort verdict — the ultracode interference test:

- Run the same smoke delegation task twice on this repo, once launched with ultracode and once with max: a small two-domain feature that must produce an orchestrator plan, two specialist delegations, a grader pass, and a gate approval.
- Pass criteria for ultracode, all four required: (1) the plugin's orchestrator agent receives the task and delegates per its own rules — ultracode's native workflow layer must not bypass it; (2) the PreToolUse orchestrator-edit block still fires when provoked; (3) Stop-gate semantics are unchanged (blocks without the bound approval, releases with it); (4) every spawned subagent matches a declared plugin agent (the existing invariant).
- Verdict: all four hold → ultracode is the default everywhere. Any fail → max is the default everywhere, and the failing observation is recorded verbatim. Either way, write the decision with evidence to `LESSONS.md` and the Beads meta-task, and encode it in the launch wiring so every future session inherits it without manual flags.

Tests and acceptance: L1 config assertions (no effort env var present, xhigh floor set, bd-mcp config well-formed); manual smoke showing `/mcp` lists `bd ✓ connected` and the orchestrator delegating; the recorded A/B verdict with evidence. Version stays pre-release until V5.

## Phase V1 — Role-aware model selection

Extend the generation-aware model resolver from "one best model for all agents" to role classes, preserving day-zero adoption within each class.

- New config `.claude/model-roles` mapping role → selection strategy: `orchestrator` → the resolver's top pick (newest, most capable family — Fable-class today); `implementer` (backend, frontend, devops) → the newest Opus-class model (Opus 4.8 today), falling back to the top pick if no Opus-class model is listed; `reviewer` (qa, grader, judge, and the new reviewer lane) → Sol via Codex when connected, else the top pick.
- The existing rules carry over per class: newest by release metadata, largest context variant, ranking file as override/exclusion only, unrecognized families as first-class candidates, Beads meta-task comment with rollback on every switch. The `model-roles` file is the new override surface — setting every role to `top` reproduces v3.5 behavior.
- `model-select.sh` rewrites each agent's `model:` frontmatter per its role. The statusline gains a compact role→model display so a stale or misrouted pin is visible at a glance.
- Effort: every Claude agent gets the V0 verdict level; the Codex wiring passes maximum reasoning effort (`xhigh`) — verify the exact flag syntax against current Codex CLI docs.

Tests: L1/L2 against faked model listings — Opus-class present → implementers get it while orchestrator gets the top pick; Opus-class absent → implementers fall back to top; codex connected/absent flips the reviewer mapping; ranking exclusions respected per role. A spec asserting every agent's frontmatter matches its role's resolver output. META-TEST: stub the resolver to misroute one role — the frontmatter-matches-role assertion must fail.

Acceptance: on this machine, orchestrator lands on the newest Claude family, implementers on the newest Opus-class, and the statusline shows the mapping.

## Phase V2 — Sol reviewer lane (optional, via Codex MCP)

- SessionStart feature-detect: a helper checks for a connected Codex MCP server and records availability where the orchestrator and gate can read it. Codex MCP mode is experimental — the plugin must treat its absence, failure, or timeout identically to "not connected."
- Operator setup doc, a first-class deliverable: write `docs/CODEX_SETUP.md`. The connection is manual and per-operator by nature — each machine needs the Codex CLI installed and authenticated against the operator's own OpenAI account — so the doc must take a teammate from zero to connected without help. Verify every command against the current OpenAI Codex CLI docs before writing it, then cover: (1) installing the Codex CLI; (2) both auth paths — ChatGPT subscription login and API key — and the billing implications of each (Sol reviews meter against the operator's OpenAI account, separate from Anthropic); (3) registering at user scope, e.g. the community wiring `claude mcp add --scope user codex -- codex -m gpt-5.6-sol mcp-server` with reasoning effort set to maximum via config flag, plus an explicit warning never to commit the codex entry to the project `.mcp.json` (teammates without Codex would see a permanently failed server); (4) model-pinning guidance: prefer whatever mechanism the verified docs offer for tracking the newest model (default-model config or a thin launch wrapper) over hard-pinning `gpt-5.6-sol` in the registration, so the day-zero adoption policy extends to the OpenAI side; (5) verification — `/mcp` lists codex as connected, workspace trust accepted, and the plugin's feature-detect reports the reviewer lane active; (6) troubleshooting — pending-approval/trust states, timeouts, and the graceful-degrade behavior when disconnected. Link this doc from README's tri-model section.
- Review-request template (used for every reviewer delegation, Sol or Claude): the change-set diff, the SPEC, the completion contract, and two mandatory fields the orchestrator must fill — `risk_threshold` (the severity at or above which findings block) and `stop_condition` (what "done reviewing" means). The harness rejects review requests missing either field.
- Review artifact, strict JSON, written to the Beads task: `{reviewer_identity, reviewer_model, findings: [{severity, location, evidence, description}], verdict: "approve" | "findings", iterations, stopped_by}`. Harness caps: max findings per review and max review iterations, configured in one place; hitting a cap sets `stopped_by` accordingly rather than looping.
- Routing: Codex connected → the reviewer lane calls Sol through the Codex MCP tools with the template; absent → the existing fresh-context Claude review path (grader plus QA) fills the role using the same template and artifact schema, so downstream mechanics are identical. Sol output is advisory: it lands in the grader/QA packet; it never writes labels or approval records.
- Optional UI verification inside the review lane: when the review scope includes frontend changes and the operator has a headless Playwright MCP configured, the reviewer may drive it — manual-gated and cost-confirmed like every paid activity. Do not add Playwright as a required dependency.

Tests: L2 with a stubbed Codex MCP (a fake stdio server emitting scripted review artifacts) covering approve, findings-above-threshold, cap-hit, and server-timeout paths; L1 for template validation (missing risk_threshold/stop_condition rejected) and artifact schema validation; a degradation spec proving byte-identical gate behavior when the feature-detect reports absent. META-TEST: mutate a recorded artifact's `stopped_by` after a cap-hit — the cap assertion must fail.

## Phase V3 — Sign-off separation and arbitration

- Gate rule, mechanical: `qa-gate.sh approve` refuses unless the task carries a review artifact whose `reviewer_identity` differs from the implementing specialist recorded in the completion contract. The approval record gains a `reviewed_by=<identity>` field alongside the change-set hash.
- Findings discipline, mechanical: every finding at or above the request's `risk_threshold` must, before approval, be either resolved with evidence (the fix plus the test that proves it, per the evidence-before-fix protocol) or explicitly arbitrated — an orchestrator-authored `ARBITRATION:` Beads comment referencing the finding and stating the decision and rationale. The gate counts unresolved, un-arbitrated at-or-above-threshold findings and blocks while the count is nonzero.
- Arbitration is the orchestrator's job: when the implementer disputes a finding, the orchestrator reads both positions, decides, and records the arbitration comment. Update the orchestrator prompt accordingly — but the enforcement lives in the gate count, not the prompt.
- New invariant for the live harness: every approval is preceded in the trace by an independent review artifact (identity ≠ implementer) and zero unresolved at-threshold findings. META-TESTs: forge a recorded trace where reviewer equals implementer — the invariant must fail; strip an arbitration comment from a trace with an at-threshold finding — the gate-count assertion must fail.

Acceptance: a seeded self-review (specialist writes its own review artifact) is refused by the gate; a seeded disputed finding releases only after an arbitration comment exists; existing single-agent flows still pass because the Claude review path from V2 provides the independent identity.

## Phase V4 — Worktree-aware gate scoping (load-bearing for parallel implement/review)

The tri-model loop runs implementers and reviewers in parallel worktrees; the gate must evaluate work where it happened. Production transcripts show the current misfires: the Stop gate diffing the primary checkout's pre-existing dirty tree (45 unrelated files) instead of the worktree, being unable to see per-worktree approvals (real approval hash bound in `wt-<task>` while the primary checkout hashes differently), and listing agent-memory files (`MEMORY.md`, ops notes) as reviewable code.

- Merge and verify PR #2 (impact-report path relativisation per repo root) — it is a correct necessary sub-fix; build on it.
- Baseline snapshot: at session start or task claim, record the baseline commit and the set of already-dirty files; the gate evaluates only the delta since baseline, structurally ignoring pre-existing dirt the session never touched.
- Per-worktree approval resolution: when a change-set-bound approval exists, locate the worktree (via `git worktree list`) whose diff reproduces the recorded hash and evaluate there — never against an unrelated checkout's diff.
- Agent-memory denylist: exclude `MEMORY.md`, `.claude/**` memory locations, and ops-note patterns from the reviewable change set.
- Root resolution via `git rev-parse --show-toplevel` / `--git-common-dir` rather than CWD, so hooks behave identically from the primary checkout or any linked worktree.

Tests: extend PR #2's stub-server spec pattern — L1/L2 fixtures reproducing all three transcript scenarios (pre-existing dirty primary, approval recorded in a sibling worktree, memory files present), each failing pre-fix and passing post-fix. META-TEST: mutate the baseline snapshot to empty — the pre-existing-dirt exclusion assertion must fail.

## Phase V5 — Release v4.0.0

- Version bump to 4.0.0 across `plugin.json` and both manifests; CHANGELOG written as major-release notes (tri-model workflow, role-aware models, Sol lane, sign-off separation, worktree scoping, effort verdict).
- README: a tri-model section (roles, models, the nobody-signs-off rule, arbitration) that links `docs/CODEX_SETUP.md` for the optional Codex lane, and the effort policy with the V0 verdict. Sweep all living docs for hardcoded model versions — they must reference the role mapping, not versions.
- RELEASE_AUDIT claims ledger gains rows for every new behavior — role-aware selection, graceful Sol degradation, sign-off separation, bounded diligence, worktree scoping — each ending PROVEN with its test artifact, per the standing no-adjective-without-artifact rule.
- Two manual live validations, cost-confirmed: the full loop once with Codex connected (Fable plans → Opus-class implements → Sol reviews with a threshold and a deliberately disputed finding → arbitration → gate release) and once with Codex absent (identical flow through the Claude review path). Record fixtures, invariants passed, and cost in the closeout notes.

## Sequencing

V0 → V1 → V2 → V3 → V4 → V5, strictly. V0 gates everything (no delegation, no workflow). V3 depends on V2's artifact schema; V4 is required before the V5 live validations exercise parallel worktrees. Do not start a phase before the previous phase's closeout (tests green, `make check`, CHANGELOG, HANDOFF verify conditions, push) is complete.

## Definition of done

All six epics closed with change-set-bound approvals. The V0 effort verdict recorded with evidence and encoded in launch wiring. Orchestrator delegating again on this machine with `bd ✓ connected`. Role→model mapping live and visible in the statusline. Both live validations recorded (with and without Codex), demonstrating that Sol's presence changes review quality but never the release mechanics. Zero NOT-PROVEN rows among the new claims. CI still costs zero API dollars, and no scheduled paid job exists anywhere in the repo.

# v5.0.0 — Design as a first-class, reviewed, continuously-enforced phase

> **Status (2026-08-02):** IN PROGRESS on branch `v5/design-phase`, cut from `main`
> at `bb8fce7` (the PR #4 merge, which carries v4.0.0 and v4.1.0).
>
> The directive below is preserved verbatim as the operator wrote it. Six decisions
> taken at planning time, and fourteen corrections established from source, live in
> the **Correction layer** section at the end of this file. Where the correction
> layer and the directive text disagree, **the correction layer governs** — the same
> convention `v4.1-upgrade-wave.md` uses.
>
> Session plan mirror: `~/.claude/plans/v5-0-0-design-stateless-wilkinson.md`.

---

The plugin has one structural gap that every other guarantee sits on top of: **the orchestrator both designs and delegates, and nobody reviews the design.** Every enforcement mechanism downstream — the rubric grader, the independent reviewer, the change-set-bound approval — verifies that the work matches the plan. None of them verify the plan, and none of them notice when the plan quietly stops governing the work.

This release separates design from orchestration, gives design its own review loop, stores the artifact where humans read and revise it, keeps the design binding at every delegation boundary rather than only at the end, and makes the three deliverables — design doc, tests, code — verifiably describe the same system.

Target workflow, in runtime order:

```
grill for context  →  design  →  review design (2–3 iterations)  →  design artifact
      ↓
orchestrate from the artifact: task per design unit, dependency order, parallel batches
      ↓
implement each unit in its own worktree, green-to-green, spec injected at spawn
      ↓
per-unit alignment check  →  review work  →  coherence rollup  →  gate
```

## Read first

1. `docs/plans/README.md` and the v4/v4.1 plans, `docs/RELEASE_AUDIT.md`, `LESSONS.md`, `CLAUDE.md`
2. `docs/AGENTS.md` (roster, completion contract, rubric criteria), `docs/HOOKS.md` (gate state machine, preconditions, `epic-gate.sh` including its `shared-files` intersection logic, `subagent-start.sh` injection), `docs/WORKFLOW.md` (label lifecycle)
3. `.claude/agents/grader.md` and the rubric files — this release reuses that machinery rather than building a parallel one
4. `.claude/model-roles` and `model-select.sh` — role classes expand from three to five, plus a per-unit override
5. The live Claude Code docs for anything platform-related, per the standing rule

Then copy this document to `docs/plans/v5-design-phase.md`, index it, and open one Beads epic per phase before writing code.

## Cross-cutting principles

All v4.x principles carry forward unchanged. Four additions govern this release:

1. **Reuse before building.** The v4.1 lesson stands: verification surface is now the dominant defect source. Every capability below must be expressed as one of — a new agent file, a new rubric criterion, a new field or enum value on an existing contract, a deterministic check, or a new condition in an existing gate. **No new harnesses.** If a phase seems to need one, stop and report before building it.
2. **Nobody reviews their own work, extended to design.** The reviewer of a design must not be its author, enforced the same way as code review: mechanically, by identity comparison at record time.
3. **The design governs continuously, not terminally.** The artifact is re-read from disk at every delegation boundary; nothing downstream works from a paraphrase of it. Where context and the artifact disagree, the artifact wins — the same rule that governs session state.
4. **Deviation is legitimate; silent deviation is not.** Designs are sometimes wrong. Changing one is a reviewed amendment, never an edit at approval time.

## Accountability model

Encode this table in `docs/ARCHITECTURE.md`; it resolves who owns what and who checks it.

| Concern | Owner | Verified by |
| --- | --- | --- |
| Problem framing, acceptance criteria, unit decomposition, unit sizing | `designer` | `design_reviewer`, against `.claude/rubrics/design.md` |
| Task-per-unit conformance | `orchestrator` | Deterministic conformance check (D4) — no review round |
| Scheduling: dependency order, parallel batches, worktree allocation | `orchestrator` | Computed intersection check (D4) |
| Implementation of a unit, green-to-green | `implementer` | `grader` + per-unit alignment check (D5) |
| Reality contradicting the design | `implementer` raises `design_conflict` | Amendment through the D2 review loop |
| Material deviation from the decomposition | `orchestrator` raises amendment | `design_reviewer` |
| Code quality, regressions | `reviewer` / `qa` | Existing independent-review + gate rules |
| Design ↔ tests ↔ code coherence | Gate | Rollup of per-unit results (D6) |

## Phase P — Prerequisite hardening (blocking)

The v4.1 closure report's meta-finding is the reason this phase exists: *a gate that reports confidently on unverified evidence is worse than no gate, because it is trusted.* This release adds three new trusted signals — `design-satisfied`, the `design_artifact` hash binding, and the coherence count — on top of instrumentation that v4.1 proved unreliable. Fix the dependencies first. Each item below is already filed with evidence, reproduction, and a candidate fix.

- **`94d` (P1)** — the change-set tracker under-covers: subagent edits and shell-written files never reach `changed-files.txt`. D6 compares touched files against declared unit sets, so an under-covering tracker lets the release's headline guarantee pass on a partial diff. It is also the mechanism behind the v4.1 incident where a new file reached a release tag without entering any reviewer's change set. Carry that incident's sharper lesson into the fix: the coverage question is "who globs or constructs paths under this directory," not "who names this file."
- **`qzv` (P1)** — F1 binds its verdict to a change set but writes its label to the task; it fired on the release task itself, bound to a previous task's change set. This release adds two more label-bound states with the same shape, so fix the binding before multiplying it. Adopt the cheap containment the report identifies: specialists re-read task state at completion and reconcile it against what they actually passed.
- **`1nz` (promoted to blocking)** — live-repo assertions fail under any concurrent writer, five instances, the last being the Stop hook racing the gate's own state machine. D4's computed batching increases concurrent writers deliberately; this must be sound before that lands.
- **`dxz` (promoted to blocking)** — code-graph-mcp flakes in both directions; `code_search` builds a working index while `code_index_health` finds no database at `indexPath()`. D1's cross-repo impact and D4's batching both consume it. Either fix it, or make the degradation explicit, tested, and visible in the batch readout — silent fallback to file-set-only intersection is the failure mode to avoid.
- **`8zi` and `2ty`**, both cheap and both directly in this release's path: `approve` must clear `qa-blocked`, since the new design labels inherit that lifecycle; and the J21 counter must stop charging a thorough review against the defect budget, since the design review loop escalates through J21 and would otherwise auto-defer good reviews.
- **Runtime contract validation.** `context_coverage` shipped with zero runtime enforcement — the parity test guards documents, nothing rejects a payload. This release adds `unit_id`, `green_before`, `green_after`, and `design_hash`; fields nothing validates are documentation. Add one validation point where completion payloads are recorded, rejecting malformed or incomplete contracts, and reuse it for every field added below.
- **`LESSONS.md` curation.** The ledger is at 71 entries and grew 25 in a single session; D1 and D2 inject it into both the designer and design-reviewer packets. Unbounded injection will crowd out the artifact under review. Add relevance scoping or sectioning before those two consumers land.
- **Resolve the `v4.1.0` tag question and its manifest prerequisite (`ce5`) first.** D7 extends the same manifest machinery, and building on a manifest that misclassifies its own `LESSONS.md` reintroduces the defect class v4.1 just closed.
- **Triage the 23 stale `in_progress` tasks** so that query is a usable signal again — D4's conformance check and current-task resolution both read it.

Tests: each item lands at the tier its filing indicates. `94d` and `qzv` additionally require a META-TEST proving the new coverage or binding assertion fails when the fix is reverted.

## Phase D0 — Role expansion and model mapping

Five role classes replace three. Selection stays generation-aware within each class — latest release in the family, largest context variant, `.claude/model-roles` as override/exclusion only, unrecognized families first-class. Never pin a specific version.

| Class | Target family | Notes |
| --- | --- | --- |
| `designer` | latest Fable-class | Highest available effort. Long-context judgment and product taste |
| `design_reviewer` | latest OpenAI reasoning model, fallback latest Fable-class | Must resolve to an identity distinct from `designer`; if both would collapse to one identity, the resolver reports a configuration error |
| `orchestrator` | latest Opus-class | Follows a specification precisely; scheduling and arbitration |
| `implementer` | latest Sonnet-class | backend/frontend/devops. The reviewed design plus green-to-green tests are what make this safe |
| `reviewer` | latest Sol-class via Codex, fallback latest Opus-class | qa, grader, judge, code reviewer |

- **Per-unit escalation.** A design unit may declare `implementer_class: high` when its complexity or fan-in warrants it; the resolver then assigns that unit the latest Opus-class model instead of Sonnet-class. Targeted exceptions rather than a blanket tier. The design rubric requires a stated reason for any escalation, so this cannot become the default.
- **Root-relay under the depth-1 pin.** Nested spawning is pinned to depth 1, so the designer cannot spawn its own reviewer. The root/orchestrator seat spawns the design reviewer directly, exactly as the QA→grader relay works today. Any design requiring designer→reviewer spawning is invalid in this release.
- **The root session is the orchestrator seat**, so it should run the `orchestrator` class. Update the session-model guard (or add it here): on mismatch with the `orchestrator` class resolution, warn loudly with the fix and set a statusline flag. Never block.

Tests: L1/L2 against faked listings — each class resolves to its family and falls back correctly when absent; designer and design_reviewer never collapse; per-unit escalation routes to Opus-class; exclusions respected per class. A spec asserting every agent's frontmatter matches its class. META-TEST: stub the resolver to collapse designer and design_reviewer — the distinct-identity spec must fail.

Rider to record: moving implementers from Opus-class to Sonnet-class is a deliberate quality-for-cost trade the design artifact is meant to absorb. Track grader rounds per implementation task before and after; if rounds rise materially, `model-roles` is a one-line revert and the observation belongs in `LESSONS.md`.

## Phase D1 — Design agent and design artifact

- New agent `.claude/agents/designer.md`, `designer` class, highest effort. It produces a design artifact and nothing else — no code. Enforce structurally the way the orchestrator's edit ban is enforced: extend the existing PreToolUse block so the designer cannot Write/Edit outside the artifact path.
- Artifact schema (`design_version: 1`), required sections: problem and user-visible outcome; testable acceptance criteria, each with a stable id; enumerated units of implementation; cross-repo impact from `impact_of` (mandatory when the code-graph server is available); explicit non-goals; risks and failure modes with mitigations; assumptions requiring human confirmation; open questions.
- **Each unit carries**: a stable `unit_id`; the acceptance-criterion ids it satisfies; its declared file/module set; its test strategy; its dependencies on other units; and optionally `implementer_class: high` with a reason. The declared file set and dependency list are what make D4's scheduling and D5's alignment checks computable — they are not documentation, they are inputs.
- The controlling standard: **an implementer must be able to build each unit without guessing, and a unit must be small enough to be implemented and verified as one coherent change.** That is the anti-guessing principle moved upstream, plus the sizing constraint that makes Sonnet-class implementation safe.
- Storage: **Linear is the human-facing source of truth** when its MCP is connected — the artifact is a Linear document, revised in place across iterations and amendments, linked to the Beads epic. Repo path `docs/specs/<task-id>.md` is the fallback when Linear is absent; the Codex-lane degradation contract applies — absent Linear changes where the doc lives, never whether the phase runs.
- **The gate cannot call MCP.** Hooks are bash and cannot fetch a Linear document. So the approved artifact is mirrored locally and its content hash recorded in Beads as `design_artifact=<linear-id-or-path>@<hash>`. Linear holds the readable prose; the mirrored copy plus hash is the machine-verifiable artifact the gate binds to and that D5 injects from — the same pattern as change-set hashes. Keep the coupling one-directional: Beads holds the reference, Linear holds the prose. Do not build a sync engine.
- Tests: L1 schema validation (missing required section rejected; criteria without ids rejected; unit without declared file set or criterion mapping rejected; escalation without a reason rejected); L2 for mirror-and-hash and Linear-absent fallback; L1 for the designer edit ban. META-TEST: strip the hash from a recorded approval — the binding assertion must fail.

## Phase D2 — Design review loop

Reuse the grader machinery wholesale; change the identity and the rubric.

- New agent `.claude/agents/design-reviewer.md`, `design_reviewer` class, read-only tools, `proactive: false`, spawned by the root/orchestrator. Packet: the design artifact, the grilling record (D3), relevant `impact_of` output, and `LESSONS.md`. Fresh context — it must not see the designer's conversation.
- Verdict JSON mirrors the grader's shape: `{verdict, criterion_results, required_changes, iteration, rubric_version, reviewer_identity}`.
- Design rubric at `.claude/rubrics/design.md`, `version: 1`. Criteria: every acceptance criterion is testable as written and has an id; **every unit is independently buildable and verifiable, and small enough for one coherent change** (with a declared file set and dependencies, and a stated reason for any `implementer_class: high`); units cover all acceptance criteria and nothing beyond them; the dependency graph is acyclic; cross-repo impact addressed when the graph is available; risks carry mitigations rather than acknowledgements; assumptions are marked for human confirmation rather than silently adopted; non-goals present; the design solves the problem the grilling record surfaced rather than an adjacent one.
- Loop: default 2 iterations, cap 3, configured in one place. `needs_revision` returns `required_changes`; the designer revises the artifact **in place** with a revision note. On cap without satisfaction, escalate through the existing J21 decision gate.
- Labels reuse the existing pattern: `design-pending` → `design-satisfied`, recorded by a new `qa-gate.sh` subcommand following the `grade-record` convention. A verdict whose `reviewer_identity` equals the designer identity is refused at record time.
- **Amendments run through this same loop.** Any `design_conflict` from an implementer (D5) or material deviation from the orchestrator (D4) re-enters here: the designer revises, the reviewer re-reviews the changed sections, `design-satisfied` is re-recorded with a new artifact hash, and dependent tasks are re-bound to it. Amendment is the only legal way the design changes after approval.
- Gate precondition: implementation orchestration cannot begin until the epic carries `design-satisfied` and a bound `design_artifact` reference. Implement as a condition in the existing gate/relay path, not a new hook.
- Tests: L2 with a stubbed design reviewer emitting scripted verdicts — satisfied first pass; one revision then satisfied; cap reached then escalation; amendment mid-implementation producing a new hash and re-binding dependents. L1 for identity-collapse refusal and in-place revision (no duplicate artifacts). META-TEST: forge a verdict where reviewer identity equals designer — the record must be refused.

## Phase D3 — Context grilling as a precondition

- Front-door behavior: before design begins, the session interrogates the human for context — using the vendored brainstorming skill and AskUserQuestion — until answers stop changing the design space. Bounded per the standing diligence rule: a stated question cap, an explicit "enough" exit the human may take at any time, and a recorded stopping reason.
- Mechanical part, deliberately minimal: a **grilling record** on the Beads epic (questions asked, answers received, assumptions the human confirmed, questions declined). The designer cannot start without it; the design rubric checks the design against it. No harness, no new tracker.
- **Enforcement point matters, and Stop is the wrong one.** The v4.1 report states it plainly about the brainstorming ceremony skip: F1 is a Stop-time change-set classifier and structurally cannot gate whether a document was read before decomposition. So the grilling-record precondition — and D2's `design-satisfied` precondition — must be checked where the orchestrator spawns implementers (the pre-delegation relay path), not at Stop. A Stop-time check would fire after the work it was meant to prevent.
- Integrity, not just content: per `e2j`, a ban list cannot detect deletion — the vendored brainstorming document can be gutted to a stub with its spec still green. The precondition must verify the document's integrity (hash or equivalent), not merely that no banned text appears in it.
- Tests: L1 that design start is refused without a grilling record; L1 that a gutted vendored document fails the integrity check; L2 that the record reaches the design reviewer's packet and that the precondition fires pre-delegation rather than at Stop. This is a documentation-and-check phase — resist growing it.

## Phase D4 — Orchestrator scheduling and decomposition conformance

The orchestrator's job narrows to execution planning, and its output is checked deterministically rather than reviewed.

- **Task per unit.** The orchestrator creates one Beads task per design unit, each recording its `unit_id`, its criterion ids, its declared file set, and its resolved implementer class. Dependencies from the artifact become Beads dependencies.
- **Conformance check (deterministic, no LLM, no review round):** every created task maps to a design unit id; every unit has a task; no orphan tasks; the Beads dependency edges match the artifact's; the bound artifact hash matches what the orchestrator planned from. Failures block delegation with a structured reason. This is the answer to "who checks the orchestrator" for the routine case.
- **Material deviation** — a unit the orchestrator wants to split, merge, drop, add, or whose criteria it wants to change — is not resolvable by task edits. It raises an amendment through D2. The conformance check is what makes deviation impossible to do silently.
- **Parallel batching, computed not judged.** Two units may run concurrently when their declared file sets do not intersect and their `impact_of` sets do not intersect; reuse `epic-gate.sh shared-files` and the code-graph server for the computation. Degradation to file-set-only intersection must be **named in the batch readout**, never silent — `dxz` makes graph availability genuinely unreliable, and an invisible fallback would quietly widen every batch. The orchestrator emits batches respecting dependency order, each member getting its own worktree per the existing isolation rule. Concurrency is capped by the existing subagent limits — read them, do not assume — and by whatever bound `1nz`'s fix establishes for concurrent writers against the gate's state machine.
- Tests: L1 for the conformance algorithm (missing task, orphan task, mismatched dependency edge, stale artifact hash) and for batch computation (intersecting file sets never batched together; dependency order respected; graph-absent degradation). L2 for delegation blocked on a conformance failure and for an amendment clearing it. META-TEST: stub the intersection check to always return empty — the batching assertion must fail.

## Phase D5 — Green-to-green implementation with continuous design alignment

This phase is where design dilution is prevented rather than detected late.

- **Spec injection at spawn.** Each implementer's packet includes its unit's spec, criterion texts, and declared file set read **verbatim from the mirrored artifact at spawn time**, via the existing SubagentStart injection. The implementer never works from the orchestrator's paraphrase, and the injected hash is recorded so a later mismatch is visible.
- **Green-to-green per unit.** Record the suite green before starting; add the failing test for the unit's criteria; implement; record the suite green after. Both states plus `unit_id` and the injected `design_hash` go into the completion contract as new fields. Reuse existing test-run and detect-stack machinery — no new runner. A unit that cannot start from green stops and reports; the red baseline becomes its own task.
- **`design_conflict` blocker.** When a unit's acceptance criteria cannot be satisfied as written — the design is wrong, incomplete, or contradicted by the code — the implementer returns a `design_conflict` blocker with evidence and stops. It does not reinterpret, improvise, or partially satisfy. This is evidence-before-fix applied to design, and it is the highest-value dilution guard in the release. The blocker routes to D2 as an amendment.
- **Per-unit alignment check** at unit completion, using the same mapping algorithm as D6 scoped to one unit: the unit's criteria have tests, the touched files fall within the declared set (or the excess is explicitly recorded as drift), and the injected `design_hash` matches the currently bound artifact. Failures block that unit, not the epic — fail on unit two, not after unit ten.
- Rubric additions: green-to-green evidence present; `unit_id` maps to a design unit; touched files within the declared set or drift recorded. All four new contract fields route through Phase P's runtime validation point — a field the recorder does not reject when malformed is documentation, and this release does not add decorative fields.
- Tests: L1 contract-shape validation for the new fields and for `design_conflict` shape; L1 for the per-unit alignment algorithm; L2 through the stubbed grader proving a missing `green_before` earns `needs_revision`, a stale `design_hash` blocks, and a `design_conflict` routes to amendment rather than approval. META-TEST: stub the suite result to claim green while red — the assertion must fail.

## Phase D6 — Coherence rollup gate

- At QA time the gate rolls up per-unit results into an epic-level count, in the manner of the unresolved-findings count: every acceptance criterion in the bound artifact maps to at least one passing test; every implemented unit maps to a design unit id; files touched outside all declared unit sets are scope drift. Unmapped criteria mean incomplete; unmapped code means undeclared scope. Because D5 checked each unit already, this is a rollup rather than a fresh scan — reuse the same algorithm.
- Both conditions clear two ways, and both are recorded: fix the work, or amend the artifact through D2 so design and reality reconverge. Silent approval-time editing of the design is not available.
- Approval records gain `design_artifact=<ref>@<hash>` alongside `change_set_hash` and `reviewed_by`. The gate refuses approval while the coherence count is nonzero or while the bound artifact hash differs from the one the units were built against.
- **This gate is only as good as the change-set tracker.** Its inputs are the files the tracker reports, so `94d` must be fixed (Phase P) before the rollup means anything; a tracker that misses subagent edits and shell-written files produces a green coherence count over an unexamined diff. Add an assertion that the rollup's file set matches the repository diff for the bound change set, so under-coverage surfaces as a failure rather than as a pass.
- Tests: L1 for the rollup (criterion with no test, unit with no criterion, file outside all declared sets, hash divergence, tracker/diff mismatch); L2 end-to-end showing a coherence failure blocking and an amendment clearing it. META-TEST: stub the rollup to always return zero — the coherence assertion must fail.

## Phase D7 — Release 5.0.0

- Version 5.0.0 across both manifests. Major bump: the workflow gained a mandatory phase and the gate gained preconditions, so existing installs change behavior.
- Docs: rewrite `docs/WORKFLOW.md` and `docs/ARCHITECTURE.md` for the new flow and the accountability table; `docs/AGENTS.md` for the roster, expanded contract, and design rubric; `docs/HOOKS.md` for the new preconditions and conformance checks; README for the role table and the design phase. A migration section covers what changes for a v4 project — including that in-flight work without a design artifact needs one before approval, and how to grandfather it.
- Installer: extend the upgrade machinery to v4→v5, and extend the v4.1 post-install verification to the new agents, rubrics, and the Linear-absent fallback.
- RELEASE_AUDIT rows, each PROVEN with its artifact: design is mandatory and independently reviewed; unit sizing is enforced pre-implementation; decomposition conformance is deterministic; parallel batches never share files or impact; specs are injected verbatim at spawn; `design_conflict` routes to amendment rather than improvisation; implementation is green-to-green per unit; the three deliverables are verified coherent; role classes resolve per family with fallbacks and per-unit escalation.
- Two manual live validations, cost-confirmed: one full arc (grill → design → one review revision → artifact → conformance → two parallel batches in worktrees → a seeded `design_conflict` producing an amendment → review → coherence → release) with Linear connected and the Codex lane active; one with both absent, proving identical mechanics through fallback paths. Record fixtures, invariants, and cost.
- Slack update for #engineering in the established house style — `:rocket:` opener with version and framing, "What this gets you" bullets for engineers who have not read the internals, "What changed since v4" bullets, an honest "Heads-up" (Sonnet implementers as a deliberate trade with per-unit escalation as the safety valve; the design phase front-loads time; Linear optional), repo link in Slack link form, closing tag of Faithful Ojebiyi and Albert with the curl one-liner. Counts and artifacts, no confidence adjectives. Deliver in chat; do not post.

## Sequencing

Build order P → D0 → D1 → D2 → D3 → D4 → D5 → D6 → D7. Phase P is blocking: the new signals this release adds are trusted, and trusting them on top of a tracker that under-covers or a label binding that misfires would reproduce v4.1's meta-finding at a larger scale. The remaining order deliberately differs from runtime order — the artifact schema and its unit fields must exist before scheduling can compute from them, and the review loop must exist before amendments have a channel. Each phase closes out fully (tests green, `make check`, CHANGELOG entry, HANDOFF conditions, push) before the next begins.

## Definition of done

Phase P closed: change-set coverage fixed with a META-TEST, label binding corrected, concurrent-writer soundness established, code-graph either fixed or explicitly and visibly degrading, `qa-blocked` cleared on approve, the J21 counter no longer penalising thorough review, runtime contract validation in place, `LESSONS.md` injection scoped, the tag/manifest question resolved, and stale `in_progress` tasks triaged. Nine agents with role-class pins resolving per family plus per-unit escalation. A design phase that cannot be skipped, reviewed by an independent identity, capped and escalating through existing machinery, with its preconditions enforced pre-delegation rather than at Stop. Design artifacts in Linear when available, mirrored and hash-bound for the gate and for spawn-time injection, with the repo fallback proven. Deterministic decomposition conformance and computed parallel batching with visible degradation, material deviation forced through reviewed amendment. Implementation green-to-green per unit with verbatim spec injection, per-unit alignment checks, runtime-validated contract fields, and `design_conflict` routing to amendment. A coherence rollup that blocks on unmapped criteria, undeclared scope, hash divergence, or tracker/diff mismatch. Both live validations recorded. Version 5.0.0 with rewritten docs, the accountability table, a v4→v5 migration section, extended installer verification, and RELEASE_AUDIT rows PROVEN by tests. The Slack update drafted, unposted.

---

# Correction layer (2026-08-02)

Everything below governs where it disagrees with the directive text above.

## Decisions taken at planning time

| # | Decision |
|---|---|
| 1 | **Phase P folds into v5.0.0.** One release; P's tasks close inside the v5 arc rather than shipping as a v4.2.0. |
| 2 | **The `v4.1.0` tag stays put.** No tag move, no `v4.1.1`. `ce5` is resolved by scoping `HANDOFF.md`'s assert to the tag plus adding a reproduction guard — not by regenerating a frozen table. |
| 3 | **Identity separation is role-level, not model-level.** `reviewer_identity` is a lane/role string like the existing `sol-codex` / `qa-claude`. A designer/design-reviewer model-family collapse is a loud warning plus a statusline flag, **never a block** — the directive's "configuration error" would make the Codex-absent fallback arm unrunnable. Design-reviewer lane priority: **Sol via Codex first, Claude fallback.** |
| 4 | **Linear ships as an unproven adapter.** `docs/specs/<task-id>.md` is the artifact; Linear is written and unit-tested behind the degradation contract but shipped explicitly UNVERIFIED, and its live validation is recorded **NOT-PROVEN** — not PROVEN-WITH-CAVEAT, because there is no artifact at all. Linear MCP was installed but unauthenticated when this was planned. |
| 5 | **Branch off `main`.** `origin/main` at `bb8fce7` is the PR #4 merge and contains `v4.1.0`. |
| 6 | **The Codex-connected live arc will be run**, with the cost estimate derived from measured token flows and a confirmation gate before spending. |

## Corrections established from source

1. **`orchestrator.md:97-99` forbids what decision 4 requires** — it says the design lands via `bd_doc_write(name="spec")` and *"never in a file under `docs/`"*. Rewrite it in D1. Keep the clause count at three so `vendored-skills.test.sh:166`'s `"Three clauses override that file wherever it disagrees"` sentinel still matches.
2. **`required_fixes`, not `required_changes`.** The grader's real field is `required_fixes` (`grader.md:87`) and `cmd_grade_record:2258-2270` keys on that literal.
3. **"Both manifests" is not a versioning claim.** Per `HANDOFF.md:305-313` there is exactly ONE version-carrying manifest; the idiom means `.mcp.json` and `plugin.json` must agree on MCP server definitions.
4. **`1nz` does not really block `2ty`.** The fix is to stop the iteration counter being authoritative, not to lock it. Recut the Beads edge.
5. **`enter` is the wrong runtime-validation point** — it is documented tolerant (`qa-gate.sh:1102-1106`) and F1 itself calls it on exactly the classes with no completion payload. Enforce at `approve`.
6. **A `^Bash$` PostToolUse matcher for `post-edit.sh` is unbuildable** — `tool_input.command` carries no path field. The matcher fix is real for `NotebookEdit` only; a reconciler handles Bash.
7. **`fable-class` must not be the design-lane fallback strategy** — a family-pinned strategy kills day-zero adoption of a new top family. `top` expresses the same intent and auto-adopts.
8. **Do not wire `SubagentStop`** — it breaks the pinned literal at `platform-audit.test.sh:274-275` and buys nothing `design-conform` at approve cannot do.
9. **Do not path-scope `prevent-orchestrator-edits.sh`** — `LESSONS.md` records the P0 caused by fail-closing that hook on an identity the runtime does not surface to PreToolUse. Use the tools-list omission plus a phase-scoped consequence check.
10. **Sol-first must never touch the three gate scripts** — `reviewer-lane-degradation.sh:33-38` asserts zero `codex|reviewer[._]lane` matches in `qa-gate.sh`, `verify-before-stop.sh`, `review-check.sh`, with a live META.
11. **Rubric criterion ids are `DS1..DS8`**, not `D1..Dn`, which would collide with these phase names.
12. **`docs/ARCHITECTURE.md:70-74` is wrong** beyond the directive's claim: `jq '.hooks|keys[]' .claude/settings.json` returns **seven** events including SubagentStart; the prose says six.
13. **Whether the runtime honours a mid-session frontmatter `model:` change is unverifiable offline.** Per-unit escalation is claimed as a declared, audited, reversible pin change — never as "the unit ran on Opus."
14. **`.claude/model-roles` is manifest class `operator`**, so an edited copy gets a `.new` sidecar and never receives the v5 defaults; that install silently stays on `implementer=opus-class`.

## Unplanned P0, found during setup

**`bd` was upgraded 0.47.1 → 1.1.2** (`claude-workflow-plugin-vfh`). The committed `.beads/issues.jsonl` could not be imported at all: 15 issues exceeded Go's 64KB `bufio.Scanner` limit, so a fresh clone recovered **zero** issues and the entire ledger existed only in one gitignored SQLite file. Verified after the upgrade: 277 records, 974 comments, every per-issue status identical to the old DB, and a fresh clone now recovers all of it.

The upgrade carries breaking changes the plugin had to absorb: `bd show --json` no longer inlines `.comments` (it returns `comment_count`; bodies need the new `--include-comments` flag), which silently breaks the gate's entire audit-trail reader across nine call sites; `--no-daemon` was removed, which the L2 fixture shim injects into every bd call; and 1.1.x ships usage telemetry on by default, now disabled via `bd metrics off`.

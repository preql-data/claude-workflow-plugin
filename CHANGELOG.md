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

## [5.0.0] - 2026-09-30

> **THE DESIGN PHASE SHIPS OPT-IN.** Read this before the feature description
> below, which was written when it was going to be the default.
>
> You opt IN by running the design phase — `grilling-record`, `design-record`,
> `design-review-record` until `design-satisfied`. A task with no design phase
> takes the documented ordinary exit at approve: `--no-design '<reason>'`, and
> the reason is recorded in the approval comment. **No new flag and no new
> config key were added for this** — both paths are pre-existing semantics, and
> `qa-gate.sh`'s own precheck already assumed most tasks have no design phase
> ("the overwhelming majority of tasks never have a design phase").
>
> **Why opt-in.** Two of the checks the design phase adds are not yet
> trustworthy in a target project: `design-conform`, and the coherence
> rollup. **The evidence for the two is NOT the same, and the difference is
> stated rather than blurred: `design-conform` was OBSERVED failing; the
> rollup's case is an INFERENCE from the code, because it has never run on a
> real target at all.** They are also independent — the rollup does not
> inherit the conformance check's answer.
> `compute_design_alignment` shells out to `design-conform` as LEG 1
> only in default mode; `compute_design_coherence` calls it with
> `mode="rollup"`, which skips LEG 1 entirely (`qa-gate.sh:15182`, and the
> function header at `:15119-15145` states the reason: LEG 1 reads a
> session-scoped tracker that is meaningless for a historical unit). The
> rollup reads that same tracker directly instead
> (`impact-report.sh --relativized-changed-files`, `:16119`). **The effect is
> narrow and was overstated twice before reaching this wording.** Scope is
> checked by two arms: the LIVE arm asks "was a file touched that no unit
> covers" (`under_coverage = $diff - $roll`, `:16194`) and dies over an empty
> change set; the DURABLE arm asks "does a unit's persisted completion contract
> claim a file no unit declares" (`undeclared_scope`, `:16066`, reading
> digest-checked payloads at `:16019-16048`) and still fires. So an empty change
> set costs the UNDER-COVERAGE DIRECTION of scope, not scope as a whole, and the
> other three conjuncts (untested criterion, unmapped unit, moved artifact hash)
> read durable records and are unaffected. *(Draft one said an empty change set
> made the whole rollup vacuous; draft two said the scope conjunct could not
> fire. Both overstated the defect. Recorded because corrections that make a
> release look better are the ones nobody chases.)* **Why this was never observed:**
> `compute_design_coherence` returns not-applicable without running any check
> when the task is not itself a satisfied design task (`:15694`) — the ordinary
> case for a task-per-unit child — and the F4 validation run's only approval was
> on such a child, its governing parent never having entered the gate. Not a
> bypass; the coherence axis has none. See `DP9` in the audit for the full
> derivation. `design-conform` has been
> observed on a real repository exactly **twice**, and BOTH observations were
> VACUOUS, by two independent routes — a denylist collision on an ancestor
> directory name (`claude-workflow-plugin-pqoj`), then a cross-session
> gate-baseline swallow on a denylist-clean path
> (`claude-workflow-plugin-q5l6`). It reported
> "conforms" while naming the three files that had just been written and
> green-tested as untouched, because the change set it read was empty. Shipping
> that as a mandatory gate would hand every user a new check that reports
> success while checking nothing, which is the defect this entire release was
> written to remove.
>
> **What it costs, measured on a real product repository.** Default path: a
> small code change took **3m57s** and a doc-only change **17m51s**, each one
> round, each approved — both measured gate-`enter` to change-set-bound
> approval, from the F4 clone's own Beads store (`bd show <id> --json
> --include-comments`: `target-2c5` 15:14:07Z→15:18:04Z, `target-w8v`
> 14:51:19Z→15:09:10Z). *(An earlier draft said "5 minutes" and "19
> minutes" with no anchor; neither reproduced at any anchor, and
> CONTRIBUTING.md binds a CHANGELOG entry to carry the command and the commit
> behind every number.)* Design path, one small unit — **two anchors, because
> the two numbers answer different questions and only one is comparable to the
> pair above**. Same anchor as that pair (gate-`enter`→approval): **12m10s**
> (`target-23z.1`, 2026-09-29 15:41:15Z→15:53:25Z). The design phase itself,
> which is the cost the opt-in ADDS in front of implementation (design task
> created→design-review verdict `satisfied`): **2h08m16s** (`target-23z`
> created 2026-09-28 16:03:55Z→DESIGN-REVIEW `satisfied` 18:12:11Z), across
> **three** review rounds — two `needs_revision`, one `satisfied` — producing
> a **49,512-byte** artifact (`wc -c docs/specs/target-23z.md`). Budget
> against **2h08m16s**, not the gate cycle. *(Two earlier drafts of this
> sentence were wrong and are superseded. The first published "3 hours 24
> minutes" beside the gate-`enter` pair with no anchor at all, inviting a
> like-for-like reading it does not support. The second anchored it to "last
> implementation completion", which does not produce that figure: `target-23z.1`
> carries THREE `COMPLETION v1` records — 2026-09-28 18:53:07Z and 19:27:38Z,
> and 2026-09-29 15:49:44Z — so under the stated anchor the span is 23h45m49s,
> not 3h23m43s. 3h23m43s was the last SAME-DAY completion, a qualifier the
> sentence dropped. No total-elapsed figure is published here at all: the run
> spans an overnight gap, which makes wall-clock totals meaningless.)* It did
> **not** reach a meaningful
> approval. It completed its mechanism end to end, and the approval it produced
> bound an empty change set. That is not softened here because opt-in users
> should see the cost profile before choosing.
>
> **What would make it the default**, all three evidence-gated and none true
> today: the change-set rewrite landed (`claude-workflow-plugin-qnvo`, written
> and preserved, deferred to v5.0.1); the test-fixture migration landed; and
> the flagship path completing end to end in a real target with an approval
> that binds real work.

**Design becomes a first-class, reviewed, continuously-enforced phase.**
Through 4.1.0 the orchestrator both designed and delegated, and nothing
reviewed the design — every downstream guarantee (the rubric grader, the
independent reviewer, the change-set-bound approval) verified that the work
matched the plan, and none of them verified the plan itself, or noticed when
it quietly stopped governing the work. This release adds a `designer` role
that produces a reviewed artifact before any implementation task exists; a
`design_reviewer` role — a distinct identity *string*, mechanically enforced
at `design-record`, though it resolves to the SAME MODEL as the designer on
every install today — connecting Codex does NOT change that, it only clears
the warning (see the identity-collapse entry below) — reusing
the grader machinery with a new eight-criterion rubric (`DS1`–`DS8`) — that
gates it through a review loop capped and escalating through the existing
J21 machinery; a deterministic, no-LLM conformance check binding every
implementation task to a design unit, with no review round; computed
parallel batching **on declared file sets only** — the `impact_of` half of
the intersection check is deferred (`claude-workflow-plugin-l7gd`) and every
batch readout says so with `graph_intersection_computed:false` rather than
degrading silently;
green-to-green implementation per unit with the spec injected verbatim at
spawn and a `design_conflict` blocker that routes a wrong design to
amendment instead of improvisation; and a coherence rollup that blocks
approval while any acceptance criterion is untested, any implemented unit is
unmapped, any touched file falls outside every declared unit set, or the
bound artifact hash has moved. Two role classes became five, and the roster
grows from seven agents to nine (`designer`, `design-reviewer`).

**Why this is a major.** The `## Versioning` criteria above name four things
that make a release major; the one this release claims is **the agent
contract**. The roster grows from seven agents to nine; the completion
contract every specialist files at close gains five new fields (`unit_id`,
`design_hash`, `green_before`, `green_after`, `criteria_tests`), validated
at `approve` rather than merely documented (a field the recorder does not
reject when malformed is documentation, not a contract); and the
orchestrator's own job narrows — from planning-and-designing to
execution-planning against a reviewed artifact, with its output checked
deterministically instead of by review. A stock `.claude/model-roles` from
any prior release has no `designer`/`design_reviewer` keys at all, which is
exactly the shape the major criterion's "operators may need to re-run the
installer in fresh mode" clause describes. Stated so it is not read as an
unmapped second criterion: the QA gate also gains new preconditions this
release — **`approve` refuses an unsatisfied design, and refuses an
incoherent rollup**. *(Corrected 2026-09-30: an earlier version of this
sentence said "an epic cannot proceed to implementation without
`design-satisfied` plus a bound `design_artifact`". That was wrong three
ways, and the correction is not cosmetic because this paragraph is a
normative argument resting on it. One: the design phase ships OPT-IN, so an
epic CAN proceed with no design at all. Two: the refusal is waivable —
`--no-design '<reason>'` bypasses the whole design-satisfied check, not just
the design-less case. Three: there is no PRE-implementation enforcement point
in any form; `design-gate-precheck`'s own help calls itself "a PRE-DELEGATION
convenience the orchestrator MAY run … never enforced from here (nothing can
force a prompt to run a script before deciding to delegate)", and `approve`
is the only real backstop.)* — but that is the gate enforcing the new agent
contract's consequences, not an independent widening of gate semantics in
the sense v4.0.0 used the term (two new NECESSARY conditions on every
approval, independent of role). The agent contract is where this release's
weight actually sits.

> **UPGRADE NOTE — four things to act on, in this order.**
>
> **1. `.claude/model-roles` is operator-owned, and an edited copy does not
> self-upgrade.** The file is manifest class `operator`, so an install whose
> copy was customized receives the v5 defaults as a
> `.claude/model-roles.new` sidecar and silently keeps running the OLD key
> set — with no `designer`/`design_reviewer` mapping at all, both falling
> back to `top` fail-open rather than to anything this release intends.
> `missing_keys` in the resolved artifact and a new SessionStart warning are
> what make that visible instead of silent. If you have ever hand-edited
> `.claude/model-roles`, diff it against the `.new` sidecar after upgrading
> and merge in the two design-lane keys plus the escalation/reviewer-lane
> grammar by hand.
>
> **2. Implementers move from Opus-class to Sonnet-class.** `backend`,
> `frontend` and `devops` now resolve to the latest Sonnet-class model — a
> deliberate quality-for-cost trade that the reviewed design artifact and
> per-unit green-to-green tests are meant to absorb, with a unit's own
> declared `implementer_class: high` as the escalation safety valve for
> work whose complexity or fan-in warrants it. Revert is one line:
> `implementer=opus-class` in `.claude/model-roles`. Track grader rounds per
> implementation task before and after; if rounds rise materially, revert
> and record the observation in `LESSONS.md`, per this release's own rider
> in `.claude/model-roles` itself. Separately, and landed in this same
> release rather than deferred: `orchestrator` and `reviewer` — which
> shipped Phase D0 still pinned to `top` (Fable today), a recorded deviation
> from the plan's own D0 table — have both since moved to `opus-class`,
> closing that deviation; see the Added section below for the full
> rationale and dates.
>
> **3. v5 ships no Linear integration.** `docs/specs/<task-id>.md` is the
> design-artifact path — the only one that ships. No reader of a
> `DESIGN_STORE` variable exists anywhere in `.claude/scripts`: there is no
> adapter, written or otherwise, so there is nothing to validate live and
> nothing to keep unproven. Two guards ship in this same release and assert
> that absence rather than guard a claim of existence —
> `.claude/tests/component/specs/design-degradation.sh` (behavioural:
> byte-identical gate output with and without `DESIGN_STORE=linear` set)
> and `.claude/scripts/tests/design-structural.test.sh` (structural: a
> lexical tripwire for three tracked literal spellings across the three
> gate scripts — an early warning should a store-selection path ever be
> added, not a completeness proof). No line in this CHANGELOG, the README,
> or the drafted Slack update may assert the Linear path works, and none
> does — there is no Linear path for one to work.
>
> **4. Re-run `--verify` after upgrading.** `bash install.sh --verify` now
> runs thirteen named checks (up from eleven — Phase P added `beads_ledger`,
> then `a13r` added `model_parity`), including two that spawn the MCP
> servers over stdio and assert exact tool counts (21 / 7, unchanged) and
> two (`gate_pretooluse`, `gate_stop`) that exercise the live hook contract.
> A `beads_ledger` FAIL is not always a divergence: the same named
> FAIL also fires when `.claude/scripts/beads-ledger.sh` itself is
> missing (a partial install) or when the check times out (30s
> bound, no verdict produced) — neither is repaired by reconciling.
> When it IS a real ledger/database divergence, the check names
> which side is ahead — `stale` (database ahead), `ledger-ahead`, or
> `indeterminate` (direction unprovable; handled the same as
> `ledger-ahead`) — and prints that direction's own remedy. Read the
> check's own `fix:` line rather than reaching for `bash
> .claude/scripts/beads-ledger.sh reconcile --apply` on reflex:
> reconcile is the right remedy for a real divergence, not for a
> partial install or a timeout.

### Added

- **Grading rubric criterion C9 — accuracy is symmetric** (`claude-workflow-plugin-38cd`):
  `.claude/rubrics/default.md` **goes to version 3**. A claim that OVERSTATES a
  defect now fails the rubric exactly as one that understates it, with an
  automatic `needs_revision` for an inference presented in the voice of an
  observation. It is its own criterion rather than a note on C1 because the
  asymmetry is measured, not assumed: optimistic errors get hunted, pessimistic
  ones read as conservative and nobody re-derives them. In this release's own
  review the same claim about the coherence rollup was overstated twice in
  successive rounds, and each survived a round that was explicitly looking for
  the previous one. Recorded here because v4.1 recorded its own `1` → `2` bump
  the same way, and a rubric change alters how every task is graded.

- **v5 Phase D6 — the coherence rollup gate** (`fkm.8`): at approve time,
  `qa-gate.sh design-coherence <task-id>` rolls up per-unit results into an
  epic-level count, "in the manner of the unresolved-findings count"
  (`review-check.sh gate`'s own `OPEN_COUNT`) — reusing D5's
  `compute_design_alignment` per unit rather than re-scanning the design
  artifact's acceptance array. Applicable only when `<task-id>` is itself a
  satisfied design task (typically the epic) declaring at least one unit
  **and having at least one real bd parent-child dependent** — a satisfied
  design that was never decomposed via D4 (the common case: one small task
  is its own design holder, with no separate per-unit children ever
  created) reads `applicable:false` rather than "every declared unit is
  unresolved"; a v5 task-per-unit child, or any task with no design phase,
  also reads `applicable:false`. The zero-children gate was not part of the
  original design and was added after it regressed several pre-existing
  `design-review-record.test.sh` fixtures that use one task as both design
  holder and sole unit of work — every one of them tripped
  `coherence_issues_open` on first approval, unrelated to what the test was
  actually exercising, until `compute_design_coherence` started checking
  `epic-gate.sh check "$tid"`'s own child count before resolving any unit's
  binding. Four kinds of open issue, aggregated into one array
  and one count, each with its own remedy: `incomplete` (a criterion has
  no covering test, whether because no task is bound to its unit at all or
  because a bound task's own coverage is incomplete), `undeclared_scope` (a
  resolved unit's persisted completion contract claims a file no unit
  declares anywhere — the epic-wide union check `design-conform`'s own
  per-task check is never asked), `hash_divergence` (a unit's own
  `DESIGN-UNIT` binding hash, or its spec injection, no longer matches the
  artifact's current governing `design_hash` — never `change_set_hash`,
  which cannot detect content drift by construction), and
  `tracker_diff_mismatch` (a file genuinely in the live, denylist-filtered
  change-set tracker that nothing the rollup examined accounts for — the
  94d-shaped under-coverage case; the OPPOSITE direction, the rollup's own
  file set naming a path absent from today's residual diff, is reported but
  deliberately not gated, since most of a design's history is not in
  today's tracker). Before that comparison runs, the governing task's own
  design artifact and every resolved unit's own review artifact(s) are
  excluded (`GATE-EVIDENCE-EXCLUSION`), generalising `design-conform`'s own
  `REVIEW-ARTIFACT-EXCLUSION` across every resolved child rather than one
  task — without it, an otherwise-coherent epic fails on its own design doc
  and its children's review artifacts on every ordinary run. Wired into
  `qa-gate.sh approve` as `COHERENCE-ROLLUP-REFUSAL` (exit 2, unconditional
  once applicable — no bypass flag exists on this axis; the two remedies
  are fix the work, or amend the artifact through the D2 review loop and
  re-bind). A coherent approval's record gains a sixth machine token,
  `design_artifact=<task-id>@<design_hash>`, last among the machine tokens.
  `claude-workflow-plugin-2tv5` (deferred to this phase by design) is
  resolved: an open `DESIGN-CONFLICT` stays artifact-wide (blocks every
  sibling unit, not just the disputed one — coherence's own epic-level
  framing makes the artifact the right scope for both questions), and the
  refusal text now names the calling task's own bound unit alongside the
  blocking one so it no longer reads as a mislabel to an uninvolved
  sibling. `compute_design_alignment` gains an opt-in `mode=rollup`
  parameter (default unchanged, proven byte-for-byte via the existing
  `design-unit-align.test.sh`, 64 assertions when this was written and 73
  since `claude-workflow-plugin-1dbz`) that skips its files leg for
  exactly this caller — reusing that leg's live-tracker comparison against
  a historical unit would be unsound, not merely redundant, once that
  unit's own approve has already truncated the tracker. Tests:
  `design-coherence.test.sh` (55 assertions — `bash
  .claude/scripts/tests/design-coherence.test.sh`'s own `Total: 55 Passed:
  55` line) — three not-applicable states (not a design task; satisfied
  design with zero declared units; satisfied design with declared units but
  zero bd children, pinning the fix above), the "declared unit with no
  bound task, in an epic that DOES have children" case kept as its own
  section specifically so it cannot be confused with the zero-children
  case, all five named issue cases from the plan with individual restore
  controls (including `tracker_diff_mismatch` proven distinct from
  `undeclared_scope`), the full success path, the `approve` wiring
  end-to-end, and a METatest stripping only the issue-count translation
  step. `design-accessors.test.sh`'s own census assertion (`11.0c`, counting
  call sites of the shared `validate_design_envelope_ok` consumption
  pattern) was updated from 3 to 4: `compute_design_coherence` is a
  legitimate fourth consumer, needed because it reads `validate-design`'s
  raw `unit_ids`/`unit_files` directly rather than through
  `design-conform`'s own subprocess, which does not expose them (confirmed
  via a full 154/154 `design-accessors.test.sh` re-run after the count
  update). Building the rollup surfaced a bash 3.2 parsing hazard, fixed at every
  occurrence: a literal apostrophe in a double-quoted `--arg` value, on a
  backslash-continued line ahead of a later single-quoted `jq` filter,
  silently corrupted the whole multi-line command — the filter arrived at
  `jq` split into unrelated fragments, each a distinct compile error, with
  the array element silently becoming empty. The fix is structural, not a
  one-off: every such message is now assigned to a plain variable first and
  never inlined.

- **v5 Phase D6, the coherence rollup's JUDGEMENT half** (`fkm.8`, added
  after the operator's ruling that `docs/plans/v5-design-phase-plan.md`
  governs where it disagrees with the directive this phase was originally
  briefed from — see the FINDING comment on `claude-workflow-plugin-fkm`
  for the full evidence trail). The mechanical rollup above answers "does
  every declared unit map to a complete, aligned, correctly-scoped task";
  it cannot answer DS1 (are the criteria, now that the system is built,
  still falsifiable), DS2 (is the decomposition, now that it is
  implemented, still complete and disjoint), or DS8 (does the FINISHED
  system contradict `LESSONS.md`, and is this verdict capped rather than
  earned) — plan:718-737's own three whole-system criteria. Those go to a
  SECOND, cheaper `design-reviewer` spawn — the SAME agent D2 already uses,
  root-relayed a second time (subagents cannot spawn subagents) against a
  DIFFERENT packet (the artifact, every unit's F7 contract, a union diff,
  the conflict/amendment history — no grilling record, no `impact_of`),
  scoped by the spawn prompt to grade DS1/DS2/DS8 substantively and mark
  DS3-DS7 pass/vacuous (already discharged mechanically and at the first
  review). **No change to the agent's output contract** — same six keys,
  same validation ladder `design-review-record` already runs. Three new
  subcommands: `design-rollup-packet <epic-id>` (assembles + persists the
  packet, refusing `design_rollup_mechanical_prerequisite` unless the
  mechanical rollup is already clean); `design-rollup <epic-id>
  --design-hash <h> --model <m> [--file <path>]` (records `DESIGN-ROLLUP
  v1 reviewer=<id> model=<m> design_hash=<h> units=<n>/<n>
  verdict=<coherent|incoherent> gaps=<n> at <ts>: <summary>` — `gaps` is a
  COUNT, not the array plan:718-737's own illustrative grammar shows (a
  genuine D6 deviation, recorded on `uwzv`; QA round 1, R1-F6, corrected
  the real reason here after an earlier version of this entry gave a false
  one — `REVIEW-ARTIFACT`'s own `findings=[R8-F1:medium,...]` IS a
  verbatim array in this codebase's machine-prefix grammar, so "no record
  stores one" was never true; the actual reason is that `required_fixes`
  elements are free-text sentences with no gap-id space analogous to
  `REVIEW-ARTIFACT`'s own `R<n>-F<n>` ids, so they cannot survive this
  single-line grammar verbatim), matching `RUBRIC`/`DESIGN-REVIEW`'s own
  "scalar prefix, free text in the tail" convention for the same reason;
  adds a required `--model` flag, a mechanical TOCTOU
  re-check, a hash-freshness check, and a duplicate-hash refusal on top of
  `design-review-record`'s reused six-key ladder); `design-rollup-status
  <epic-id>` (READ-ONLY `{applicable, mechanical_ok, rollup_recorded,
  rollup_coherent, rollup_hash_fresh}`, the accessor `epic-gate.sh`
  shells out to). Two enforcement surfaces: `epic-gate.sh cmd_check`'s
  "all children approved" branch now additionally checks this axis
  (advisory — changes only the Stop hook's `EPIC_DEFER_NOTE`), and
  `qa-gate.sh approve` on the governing task gains **`DESIGN-ROLLUP-
  REFUSAL`, exit 5 for all three shapes** — `error_key=design_rollup_
  missing` (never recorded), `design_rollup_verdict_stale` (recorded but
  superseded by a later amendment), or `design_rollup_incoherent`
  (recorded, current, but not coherent) — three distinct keys since QA
  round 1 (R1-F10; originally one shared key, distinguishable only by
  parsing the observations string), independent of the mechanical axis's
  own exit 2 in
  both directions: a coherent rollup record can never paper over a broken
  mechanical check, and a reopened mechanical issue still refuses at exit 2
  even with a coherent rollup already on file. No bypass flag on either
  axis. TWO REAL DEFECTS found by driving the shipped code, both fixed
  structurally: (1) a genuine unbounded recursion — `epic-gate.sh check` →
  `design-rollup-status` → `compute_design_coherence` → `epic-gate.sh
  check` again — measured live as a runaway subprocess chain, fixed with a
  reentrancy guard (`QA_GATE_SKIP_EPIC_GATE_REENTRY=1`) that switches
  child-enumeration to a direct `bd` query for that one call, plus a
  complementary efficiency guard (`EPIC_GATE_SKIP_ROLLUP_CHECK=1`) so the
  fix is not merely bounded but not wastefully doubling every ordinary
  `design-coherence` call's subprocess cost; (2) a `set -e` interaction —
  this file runs under `set -e` throughout, and a bare (non-`||`-guarded)
  call to a function that can legitimately return non-zero trips `errexit`
  and terminates the whole process before the caller's own error-envelope
  construction ever runs, at all five of this axis's internal call sites,
  fixed with the SAME `fn "$tid" || rc=$?` guard the original `compute_
  design_coherence`/`cmd_design_coherence` pair already used correctly —
  caught only by the formal L1 suite's explicit `error_key` assertions,
  not by the looser smoke-testing that preceded it. Tests:
  `design-rollup.test.sh` (new) covers packet assembly's refusals and
  restore control, the full record validation ladder and exact grammar on
  both a genuine `coherent` and a genuine `incoherent` verdict, all three
  `design-rollup-status` states, `epic-gate.sh check`'s new branch with a
  negative control proving a non-design epic's own text is byte-for-byte
  unchanged, the reentrancy fix's termination bounded by a wall-clock
  assertion rather than assumed, `approve`'s exit-5 refusal in the
  never-recorded and stale shapes plus its success path, the mechanical
  axis's independence proven by reopening an issue AFTER a coherent
  rollup was recorded, and a METatest — the coordinator's own explicit
  instruction — stripping only the hash-freshness comparison to prove a
  genuinely `coherent` verdict bound to a superseded hash must still
  refuse, because this axis's trustworthiness was never the verdict's
  semantic content but the binding to current state.

  **QA ROUND 1 (fkm.8): 1 CRITICAL + 3 HIGH fixed, plus three false
  justifications corrected.** R1-F1 (CRITICAL) — `reviewer_identity` was
  checked only for emptiness before being interpolated raw into the
  `DESIGN-ROLLUP v1` machine prefix; PROVEN forgeable against the shipped
  parser (a crafted identity mimicking a second record's own grammar made
  the reader capture a forged `verdict=coherent`/`design_hash`, clearing
  the refusal on a genuinely incoherent verdict — the `bjx` class). Fixed
  with `assert_record_scalar`, the same guard `design-review-record`
  already applies to `reviewer`. R1-F2 (HIGH) — the spec measured at
  806.83s/823.17s standalone, above the 800s split trigger against a 900s
  cap; split into `design-rollup-incoherent.test.sh` (the self-contained
  incoherent-verdict/deadlock-fix scenario). R1-F3 (HIGH) — the packet's
  union diff (`git diff [--stat] "$base...HEAD"`) was simultaneously too
  wide (the whole branch since diverging from main — MEASURED at 9.97x
  the packet's own cap for a D6-scoped change alone) and blind to the
  actual uncommitted change set this workflow gates (a merge-base
  comparison only ever sees committed history); now `HEAD` vs the working
  tree, with untracked files rendered via `git diff --no-index`. R1-F4
  (HIGH, split ruling) — the duplicate-hash check admitted at most one
  verdict per `design_hash` ever, so an incoherent verdict locked the
  governing task with no escape short of a design-document edit; the
  SUSTAINED half now allows a superseding verdict at the same hash when
  the PRIOR one was incoherent (a coherent verdict remains a terminus,
  unchanged); the NOT-SUSTAINED half (binding the record to
  `change_set_hash` too) was declined — plan:721 specifies no such field,
  and the resulting staleness gap is an accepted residual, linked to
  `r7ed`. Three false justifications corrected (same family as D5's own
  round-7 block): `gaps=<n>` vs the plan's own `gaps=[…]` was justified
  with "no record in this codebase stores an array verbatim", which
  `REVIEW-ARTIFACT`'s own `findings=[R8-F1:medium,...]` directly
  contradicts — corrected to the real reason (no gap-id space for
  free-text `required_fixes` elements) and recorded as a deviation on
  `uwzv`; a comment claiming "zero `issue_type=epic` rows exist" was
  measured false (23 exist, 0 open) — the predicate itself was kept (it
  is the better match for the actual question) but the justification
  corrected; and an exit-5-belongs-to-a-different-command argument was
  self-contradicted by this same axis's own new exit-5 usage in the same
  function. Also: the three exit-5 `approve` refusal shapes gained
  distinct `error_key`s (previously one shared key). `design-reviewer.md`
  gains a "Second
  invocation" section (prose only — no new spawn instruction, verified
  against `no-nested-spawn-instructions.test.sh`'s own 16 assertions) and
  `orchestrator.md` gains "5f. Coherence-rollup relay".

- **`approve` refuses when a review artifact exists on disk with no
  corresponding record, and a non-governing path to reconcile historic ones
  without disturbing which round governs** (`k6re`, the headline defect: "a
  gate reporting confidence its evidence does not support"). The external
  reviewer driver writes `docs/reviews/<task-id>-r<n>.json` and exits;
  nothing called `review-record` for it unless an agent remembered to, so a
  fresh artifact could sit unrecorded indefinitely while `approve` still
  reported "independent review verified" for whichever round *was* recorded
  — the corpus this fix was measured against (`claude-workflow-plugin-i8cx`,
  documented in `review-check.sh`'s own `recorded-hashes` header comment) was
  12 artifacts on disk against 3 recorded rounds at the time of that
  measurement. The reconciliation mechanism below (`review-reconcile`)
  exists and works — exercised end-to-end and independently verified
  against k6re's own 10-artifact backlog — but i8cx itself has NOT been
  reconciled: the identical shape still reproduces today, at HEAD
  `adaf64d`:
  `ls -1 docs/reviews/claude-workflow-plugin-i8cx-r*.json | wc -l` -> 12;
  `bd comments claude-workflow-plugin-i8cx | grep -c 'REVIEW-ARTIFACT v1 iteration='` -> 3;
  `bd comments claude-workflow-plugin-i8cx | grep -c 'REVIEW-ARTIFACT-RECONCILED v1 iteration='` -> 0.
  Three more tasks carry an unreconciled backlog of the same shape —
  `pqnd` (4 unrecorded), `xsu1` (2), `6im2` (1) — for **16 unrecorded
  artifacts across 4 tasks** outstanding in total; tracked separately on
  `claude-workflow-plugin-r6zh`.

  - **`review-check.sh recorded-hashes <task-id>`** (new subcommand) — the
    UNION of every `artifact_hash=` bound by a well-formed
    `REVIEW-ARTIFACT v1` (or, see below, `REVIEW-ARTIFACT-RECONCILED v1`)
    record for a task, deduplicated. Deliberately not `gate`'s single
    K3-selected winner — a membership question over every recorded round,
    not a release-verdict selection.
  - **`qa-gate.sh approve`** gains a new refusal (exit 4,
    `review_artifact_unrecorded`) between `REVIEW-SEPARATION` and the
    completion-contract check: for every `docs/reviews/<task-id>-r*.json` on
    disk, its content hash (never mtime — a checkout, copy or restore moves
    an mtime without changing a byte) must appear in `recorded-hashes`, or
    approval refuses naming the file(s), each annotated with its SHA-256 when
    it could be computed — a file outside the declared review directory, not
    a regular file, or unhashable for some other reason is named with that
    reason instead, since there is no hash to report in those cases. New
    audited bypass `--accept-unrecorded-review '<reason>'`, a dedicated flag
    rather than a `--no-review` overload, so acknowledging a historic backlog
    does not also silently waive open-findings resolution.
  - **`qa-gate.sh review-reconcile <task-id> --file <path> [--acknowledge-findings] <reason>`**
    (new subcommand). `review-record` stamps WRITE time, not review time, into
    the grammar `gate`'s K3 selector reads — that selector requires a
    single record to be simultaneously max(iteration) AND
    max(at-timestamp), refusing with `review_artifact_selection_disagreement`
    on disagreement. Backfilling several historic rounds through
    `review-record` in any order the caller does not carefully control can
    invert that agreement (measured on two distinct backlog shapes: one
    where numeric-ascending order happens to avoid it, and one — the
    highest iteration already recorded — where no order of the remaining
    set can). `review-reconcile` instead appends the NON-GOVERNING
    `REVIEW-ARTIFACT-RECONCILED v1` grammar: accounted for by
    `recorded-hashes` so `approve` stops refusing on it, but structurally
    unmatchable by `gate`'s K3 trigger (the grammar diverges at the
    character immediately after `REVIEW-ARTIFACT`), so it can never become
    a selection candidate no matter what order it lands in. Refuses (exit 1,
    `reconcile_open_findings_unacknowledged`) when the artifact being
    reconciled carries a `findings[]` entry at or above its own
    `risk_threshold` — a RECONCILED record is non-governing and carries no
    findings of its own, so reconciling one with an open at-threshold finding
    would let it leave the trust chain silently — unless `--acknowledge-findings`
    is given, in which case the comment gains a visible
    `[open findings acknowledged: <id>:<severity>,...]` marker ahead of the
    reason.
  - **Test coverage for this feature now spans two files.** The
    UNRECORDED-REVIEW-ARTIFACT-REFUSAL family and its `review-reconcile`
    governance (added across independent review rounds 13-16) outgrew the
    file they landed in — measured at ~1000s real time standalone, over
    `run-tests.sh`'s own `SPEC_TIMEOUT_S=900` per-spec cap — and were
    split verbatim into a new L1 spec, `unrecorded-review-artifact.test.sh`
    (170 assertions as measured by `/usr/bin/time -p bash
    .claude/scripts/tests/unrecorded-review-artifact.test.sh` at HEAD
    `adaf64d`); `review-separation.test.sh` keeps Sections 1-6, the
    original REVIEW-SEPARATION contract, and its own count dropped to 94.
    See `run-tests.sh`'s `EXPECTED_SPECS` comment (60 -> 61) for the full
    accounting.

- **Concurrency ownership: a lease answers "who owns this tree right now"
  before D4 needs to ask** (`gsfd`, the D4 prerequisite). j7kk's
  skip-when-unchanged removes the redundant-run case but does not resolve
  ownership — measured twice, both occurrences of a fixed-path collision
  below had the tree genuinely move, so the skip correctly declined to fire
  and the collision happened anyway.

  - **`.claude/scripts/tree-lease.sh`** (new) — a shared ownership primitive:
    `lease_acquire`/`lease_release`/`lease_conflicts`/`lease_reclaim_stale`,
    sourced by the L1 runner (`run-tests.sh`), the L2 runner
    (`.claude/tests/component/run.sh`), and the Stop hook
    (`verify-before-stop.sh`). **This paragraph describes the FINAL, round-6
    shape, not an intermediate one — read the fix-round history below for
    the full account of how it got here, including a four-value grammar
    (LIVE/LIVE-BUT-OLD/UNCONFIRMED/STALE) and a periodic `lease_heartbeat`
    that shipped for several rounds and are BOTH gone now.** The lease is
    report-only: `lease_conflicts` computes one of two statuses, and
    nothing ever auto-removes a lease on the strength of either. A
    same-host pid that answers `kill -0` reads LIVE when EITHER its
    recorded start time matches its own measured elapsed runtime (same
    PROCESS, not a pid the OS recycled after the original exited) OR that
    measurement could not be taken at all (no usable `ps` where the check
    ran, or the pid exited between the `kill -0` and the check) — an
    unconfirmable reading is a HEDGED live, never a new way to fail a live
    owner, matching `_lease_pid_start_matches`'s own contract ("cannot rule
    out a match"). (Corrected here — see gsfd R6-F4: this paragraph
    previously listed "a liveness check that could not complete" under
    STALE, which disagreed with both the code, which treats it as
    confirmed-live, and with `_lease_pid_start_matches`'s own header.) LIVE
    holds unconditionally, for as long as the process genuinely is — age
    never demotes it. Everything else (a different host, no recorded pid, a
    confirmed-dead pid, or a pid that now belongs to a DIFFERENT process —
    a MEASURED elapsed-runtime mismatch, reuse) reads STALE; age is still
    printed on both, informational only, and no threshold of any kind
    decides the word any more.

    R6-F4 also added the missing test leg: `tree-lease.test.sh` gains
    section 4c (+ META 4c) — an unusable `ps` double placed first on PATH
    (the rest of PATH, and so every other external command `lease_conflicts`
    needs, is untouched) drives the real "unknown" path through
    `_lease_pid_start_matches` and `lease_conflicts` together and proves it
    classifies LIVE, never STALE; a mutant narrowing the conversion to
    accept only a literal "yes" proves the identical fixture then reads
    STALE. 7 new assertions (2 preconditions + 2 main + 3 META), all passing
    alongside the rest of the file:
    `bash .claude/scripts/tests/tree-lease.test.sh` — 78 assertions total,
    this change set. Sections 4 ("yes") and 4b ("no") already existed;
    "unknown" was the gap. Separately, R6-F5: that file's own header
    claimed its sections were "renumbered to be contiguous" after two were
    deleted (the old heartbeat section 9, the old dead_grace_s section 14) —
    they were not; both the catalogue and the executable body jump straight
    from 8 to 10, and 14 does not exist. The comment is corrected to say so
    rather than renumbering the surviving sections, which would have touched
    every META/assertion label from 10 through 13 for a LOW-severity
    bookkeeping mismatch.

    `lease_reclaim_stale`
    removes every lease it reads STALE and is never called on anyone's
    behalf — an explicit, standalone operator action only
    (`bash -c '. tree-lease.sh; lease_reclaim_stale "$dir"'`). Not a
    mutex — it cannot stop a non-participating writer (a human's shell, an
    MCP host that never sourced it), and does not try to; it is the
    extension point for when 9xl4's timed-out-Codex-host scenario becomes
    reachable again. New L1 spec: `tree-lease.test.sh` (64 assertions as
    shipped in fix round 1; 77 after fix round 2 adds R2-F1's
    UNCONFIRMED-state coverage, R2-F3's set -e survival test, and R2-F6's
    owner_host META-TEST; 86 after fix round 3 adds the heartbeat-callers
    coverage and section 14's `dead_grace_s` boundary tests. **Not current
    past that point: round 6's DESIGN COLLAPSE (below) deletes both of
    those sections outright — the mechanisms they guarded, `lease_heartbeat`
    and the `dead_grace_s` threshold, no longer exist anywhere in this
    codebase — leaving 71 assertions, all passing, as measured by
    `bash .claude/scripts/tests/tree-lease.test.sh` at this change set.**).

    **Fix round 1** (independent cross-family review, sol-codex/gpt-5.6-sol,
    4 HIGH + 4 MEDIUM, `gsfd` R1-F1..F8) found this initial version's own
    tests encoded some of its bugs as "correct":
    - R1-F2: hostname+pid is not process identity. `kill -0` succeeding only
      proves SOME process holds that pid now, not that it is the SAME one
      that wrote the lease — a pid the OS recycled after the original
      exited would pass `kill -0` forever and keep a dead lease LIVE for up
      to the 3h backstop. `started_at` (recorded, unused before this fix) is
      now cross-checked against the current holder's actual elapsed runtime
      (`ps -o etime=`, portable across GNU/BSD, parsed by hand since GNU's
      simpler `etimes` is not shared); a mismatch reads STALE unconditionally.
      Residual, documented rather than silently shipped: hostname string
      equality is not proof of MACHINE identity, and a genuine cross-host
      collision (two hosts/containers reporting the same hostname) is not
      closed by this alone.

      **Fix round 2 (R2-F1, sol-codex review): the ABOVE "every consumer is
      advisory-only" claim was false, disproven by enumeration rather than
      accepted on assertion.** `lease_conflicts`'s own output feeds
      `lease_reclaim_stale`, called synchronously from every `lease_acquire`
      (self-heal); a hostname collision made a local `kill -0` misread a
      genuinely LIVE remote owner as dead, and `lease_reclaim_stale`
      REMOVED its lease file — a real deletion, not a notice. Fixed by
      making a same-hostname-string "dead" reading (kill -0 failing, or a
      pid-reuse mismatch) NO LONGER sufficient on its own to reclaim
      instantly: it now reports a new `UNCONFIRMED` status (distinct from
      LIVE — never asserting alive what could not be confirmed) and is
      reclaimed only once ALSO old enough to cross the same age backstop a
      plain cross-host lease already used — never instantly from a local
      check that was never capable of testing a remote machine's process
      table in the first place. The bounded consequence, now actually true:
      a hostname collision can still eventually cost a live foreign owner
      its lease file, but only on that backstop's schedule (default 3h),
      identical exposure to the cross-host case already accepted here
      before either fix.

      **Further correction, same review round**, caught re-checking this
      fix against a REAL caller rather than only this file's own test
      fixtures: `lease_acquire` originally recorded `started_at` as the
      ACQUIRE-CALL moment. `verify-before-stop.sh` does substantial work
      (task detection, doc-only classification, escalation checks,
      `DETECT_STACK`) before ever reaching `lease_acquire` — and the exact
      high-contention conditions this batch targets are the ones that
      stretch that gap furthest — so a caller whose own preamble ran longer
      than the 5s matching tolerance would have its OWN fresh, legitimate
      lease misread as pid-reuse by any concurrent checker moments later.
      Measured directly: a lease acquired after a real 7s delay read STALE
      under the original shape and LIVE once `started_at` is back-computed
      from the pid's own measured elapsed runtime instead (a fact about the
      PROCESS, stable for its whole life, rather than about when
      `lease_acquire` happened to be called). New assertions (12, META 12)
      drive this with a real, unsimulated delay — the property is about
      actual OS-measured elapsed time, which cannot be faked by backdating
      an mtime the way the age-backstop tests do.
    - R1-F3: the age backstop used to override a CONFIRMED-live pid — it ran
      whenever `stale="no"`, including the branch where `kill -0` had just
      succeeded, so a still-running L1 tier (44 specs × 900s cap can exceed
      the 10800s default, and no caller heartbeats) could have its own live
      lease reclaimed mid-run. Now the age check only fires when liveness
      could NOT be confirmed; a confirmed-live-but-old lease reports the new
      `LIVE-BUT-OLD` status and is never reclaimed. Separately,
      `_lease_mtime_epoch` emitted literal `'0'` on a `stat` failure, which
      the sanitiser's `''|*[!0-9]*` pattern does not catch (it emits empty
      now, closing the gap).
    - R1-F4: the mktemp-template META-TEST hardcoded BSD's un-substituted-
      placeholder outcome as "correct" — measured FAILING on GNU coreutils
      9.7 (the CI platform), where the identical template IS substituted.
      Fixed by probing this platform's OWN mktemp behaviour for the exact
      template shape and asserting the mutant matches the probe, so both
      platforms get a real, non-skipped assertion.
    - R1-F5: `set -u` sat at file scope and leaked into every sourcing
      caller (reproduced: `bash -c 'set +u; . tree-lease.sh; echo "$-"'`
      gained a `u`), contradicting the file's own "nothing here mutates the
      caller's shell state" promise. Scoped to the direct-execution CLI
      block only. **Rationale corrected (R2-F8, round 2 review): the fix is
      sound, the original explanation here was not.** A function's BODY is
      not evaluated under nounset merely by being DEFINED — defining a
      function only parses it, never executes it — but every CALL to one
      of this file's functions, made from the same shell that sourced it,
      ran under whatever `set -u` state that sourcing left behind, which
      before this fix was "on" (that IS the leak R1-F5 measured and fixed).
      Definitions were never affected; calls were.
    - R1-F8: `lease_heartbeat` and `lease_release`'s own defining effects,
      and the `started_at` field R1-F2 turns on, had no discriminating
      assertion; all three now have a dedicated META-TEST. `owner_host`'s
      own write was claimed covered too but was not (R2-F6, round 2
      review) — fixed with a dedicated META-TEST of its own.

    **Fix round 2** (`gsfd` R2-F3, sol-codex review):
    `lease_release`'s own "best-effort; always returns 0" promise was false
    under a failing `rm -f` (a permissions change, a read-only remount): the
    bare `[ -n "$f" ] && rm -f "$f" 2>/dev/null` statement's exit status was
    `rm`'s, and `verify-before-stop.sh` calls it under its own `set -e`
    without a guard — a Stop hook that produces no output releases rather
    than blocks, the worst failure direction, and silently. Fixed with
    `|| true` on the `rm` itself (a trailing `return 0` is not enough, same
    reasoning `lease_conflict_summary`'s own ERREXIT SAFETY note already
    gives), plus belt-and-braces `|| true` at all three call sites
    (`verify-before-stop.sh`, both L1/L2 runners). Reproduced directly:
    `rm -f` against a DIRECTORY reliably fails "Is a directory" on both
    BSD and GNU rm, independent of privilege level, and a bare
    `set -e` caller genuinely aborted before this fix, survived after.

    **Fix round 3** (`gsfd` R3-F3, sol-codex review, independently measured
    rather than merely reasoned through): round 2's UNCONFIRMED status
    (above) closed the cross-host hostname-collision risk by applying the
    SAME long `stale_s` clock (default 3h) to every non-confirmed-live
    reading — which also, as a direct consequence, applied it to the
    ordinary same-host crash case, by far the more common one. Every
    restart after ANY local crash rendered a live-seeming "concurrent
    (unconfirmed...)" notice for a full three hours, for a process the
    host itself could confirm dead via a single `kill -0`. A notice that
    is usually wrong is one operators learn to ignore, which is worse than
    no notice — the reviewer flagged this independently, before it was
    confirmed. Fixed by splitting the one age threshold into two: `stale_s`
    still governs the confirmed-live and true-cross-host buckets
    unchanged, but a same-host reading that failed liveness confirmation
    (`kill -0` failing, or a `started_at` mismatch) now clears on the much
    shorter `dead_grace_s` (default 90s — roughly three missed heartbeats
    at the runners' own 30s cadence, sized the same way
    `_lease_pid_start_matches`'s existing 5s tolerance was, to absorb
    ordinary scheduling jitter, not to widen a timeout). Splitting the
    threshold without reopening R2-F1's own collision risk required making
    `dead_grace_s` trustworthy in BOTH directions, which needed active
    evidence rather than passive inference: every participating runner
    (L1 `run-tests.sh`, L2 `.claude/tests/component/run.sh`, the Stop hook)
    now refreshes its own lease's mtime every 30s while genuinely alive,
    via `lease_heartbeat` — which previously had no production caller at
    all, an observation from round 1 closed here. **Superseded, not
    current (R4-F5, round 4 review): this paragraph originally shipped as
    "a bounded, self-terminating (6h ceiling) heartbeat daemon" — a
    background subshell per runner. That daemon design was RETIRED two
    fix rounds later (see "the heartbeat daemon retired" entry below,
    same fix arc) after producing two further defects of its own; there
    is no daemon, no 6h ceiling, and no fd-redirect control left in the
    shipped code. This paragraph is corrected in place because the
    MECHANISM it describes (mtime-refresh cadence, the two-population
    threshold split) is still exactly what ships; only ITS OWN
    "daemon" framing was overtaken by later rounds and is named here
    rather than left to mislead a reader who stops at this paragraph.**
    A same-host process that crashes stops heartbeating and clears
    `dead_grace_s` within two minutes; a genuinely-alive FOREIGN owner
    sharing this host's hostname string keeps refreshing ITS OWN lease and
    never approaches `dead_grace_s` either — one mechanism resolving both
    directions at once, rather than trading one off against the other.
    Considered and rejected, reasoned through by hand rather than assumed:
    Linux boot-id + pid-namespace identity, the reviewer's own alternative
    suggestion — it gives zero benefit on macOS (this repo's own authoring
    platform) and, worked through against this file's own "cloned
    container image" concern, still cannot discriminate that specific case
    either, since containers sharing a base image commonly share both
    machine-id and boot-id. KNOWN LIMITATION, documented rather than fixed
    this round (inferred by the reviewer but not independently measured):
    a hostname-colliding foreign lease whose pid AND recorded start time
    happen to coincide with an unrelated local process still reads
    CONFIRMED-live and can persist as LIVE-BUT-OLD indefinitely — heartbeat
    evidence does not help here, because the coincidence already satisfies
    `confirmed_live`'s own check before heartbeating is ever consulted.
    Separately (R3-F4, documentation only): this file's own header
    previously claimed the cross-host/no-pid bucket could read
    `UNCONFIRMED` or `STALE`; the shipped code has only ever produced
    `LIVE` or `STALE` there (it has no local evidence to withhold
    confirmation FOR), and the header now says so.

    **SELF-FOUND regression, same round, before reporting it** (not from the
    independent review — found verifying the heartbeat daemon above against
    a minimal byte-for-byte reproduction of its own spawn shape, rather than
    only against this repo's own fixtures): the heartbeat subshell added to
    all three participating runners (`run-tests.sh`, `component/run.sh`,
    `verify-before-stop.sh`) did not redirect its own stdin/stdout/stderr
    away from its parent's. `kill "$LEASE_HEARTBEAT_PID"` (or
    `$STOP_LEASE_HEARTBEAT_PID`) at each runner's own cleanup point signals
    the SUBSHELL WRAPPER only; the `sleep 30` it is blocked in at that
    instant is a SEPARATE child process, gets re-parented to pid 1 rather
    than terminated when its parent dies, and — measured directly against
    the shipped shape — keeps holding whatever fds it inherited for up to
    its remaining ~30s. In `verify-before-stop.sh` specifically, this
    script's own stdout IS the JSON envelope Claude Code reads back, and a
    caller reading a child's stdout as a STREAM (the same constraint bash's
    own `$(...)` command substitution has, and the shape any hook-invocation
    harness must use to capture that JSON) cannot see EOF until every
    process holding the pipe's write end has closed it. Left unfixed, EVERY
    Stop hook invocation that reached this heartbeat would have appeared to
    hang for up to 30s after its real decision was already written, for as
    long as this repo's lease mechanism was in use — measured directly with
    a minimal reproduction of the identical spawn shape: an unfixed capture
    took the full orphaned tail of the sleep to return; the same capture
    against the fixed shape returned immediately. Fixed by redirecting the
    subshell's own fds at the moment it is spawned
    (`</dev/null >/dev/null 2>&1`) in all three runners, which closes the
    gap regardless of whether the later `kill` can reach the in-flight
    `sleep` (it cannot, and still does not after this fix — the orphaned
    sleep still lingers doing nothing observable, but no longer holds a copy
    of the parent's stdout for anyone to wait on). New component-spec
    coverage (`vbs-r3fix` in `verify-before-stop.sh`'s own spec) drives the
    ACTUAL shipped hook through a real dispatch, times a stdout-pipe capture
    of it directly, and — the same non-negotiable pairing requirement as
    every other control in this changeset — proves a copy with the redirect
    stripped measurably hangs the identical capture, so this check would
    catch its own regression rather than merely observe the fix once.
    **Not current (round 6 DESIGN COLLAPSE, below): `vbs-r3fix` covered a
    background heartbeat daemon that itself no longer exists in ANY form —
    not as a daemon, not as the in-process replacement round 4 gave it. The
    section was deleted with the mechanism, not left to pass vacuously; see
    the DESIGN COLLAPSE entry for why.**

    **The heartbeat daemon retired** (independent cross-family review,
    same fix arc, one round later): the fd-redirect fix above closed the
    stdout-inheritance hang, but the SAME orphaned `sleep 30` — surviving
    a `kill` to its now-dead subshell wrapper for up to its remaining
    ~30s — then tripped `run-tests.sh`'s own per-spec survivor-hygiene
    check in any spec invoking this hook (`phase5-synthetic-tests.sh`:
    "exited 0 with 1 background process(es) still running"). Both
    defects trace to one assumption: that a background daemon is the
    right shape for a heartbeat inside code that must terminate cleanly.
    Shrinking the daemon's sleep interval was considered and rejected —
    it would only trade a reliable failure for an intermittent one, which
    this repo already treats as a defect in its own right (the store-
    canary/97-minute-L2-run history this same task's own description
    cites). The daemon was retired instead, in favour of an IN-PROCESS
    heartbeat: `run-tests.sh`/`component/run.sh` fold it into the
    per-spec WATCHDOG's own already-necessary 1-second poll loop (no new
    process — that loop exists regardless, for `SPEC_TIMEOUT_S`
    enforcement); `verify-before-stop.sh`'s `run_with_timeout` was
    rewritten from a single blocking `timeout`/`gtimeout` call (absent by
    default on BSD/macOS, degrading to unbounded when missing) into a
    genuine in-process poll loop of its own. Both fd-redirect mutant
    suites (`vbs-r3fix`; `runner-completeness.test.sh` section 18) were
    retired rather than left passing vacuously against a design with no
    fd left to guard, and replaced with assertions that the lease file's
    mtime genuinely advances during a real >30s dispatch/spec through the
    REAL, unstubbed code, each paired with a mutant that disables the
    heartbeat call specifically. **Not current (round 6 DESIGN COLLAPSE,
    below): the in-process heartbeat this paragraph describes is ALSO
    gone — deleted outright, not replaced again — and their REPLACEMENT
    mtime-advances assertions went with it for the same reason: there is
    no lease-mtime-advances-during-dispatch property left to prove once
    nothing heartbeats. `run_with_timeout` is back to the plain
    `timeout`/`gtimeout` call this paragraph says it was rewritten FROM.**

    **Fix round 4** (independent cross-family review): the daemon
    retirement itself introduced four further findings, all in the new
    code that retirement added.
    - R4-F1 (HIGH): `run_with_timeout`'s supervision loop tested
      `kill -0 "$child_pid"` — is the WRAPPER still alive — and only
      killed the process group once the deadline fired. A test_cmd
      shaped as `real_work &` (backgrounding its own work) let the
      `bash -c` wrapper reach the end of its command string and exit in
      well under a second while `real_work` kept running, reparented,
      inside the SAME isolated group `set -m` created — the function
      returned 0 (success) while the thing it was timing was still
      running, completely unsupervised, indefinitely. Third occurrence
      in this same fix arc of "the wrapper exited" being mistaken for
      "the work finished" (the stdout-fd orphan, the phase5 survivor, now
      this) — the fix applies this repo's own `run-tests.sh`
      SURVIVOR-SWEEP philosophy here too: completion means the process
      GROUP is empty, not that one pid exited. The loop condition is now
      `kill -0 -- "-$child_pid"` (the identical negative-pid group target
      the timeout-kill path already used) — verified directly: a
      `bash -c 'sleep N & exit 0'` reproduction shows the wrapper dead
      within a second while the group-signal check still reports the
      group alive until the orphaned sleep actually finishes, and 5
      repeated forced-timeout runs of the exact exploit shape all
      correctly returned 124 (never 0), each independently confirmed
      leak-free by exact-PID descendant tracking.
    - R4-F2 (MEDIUM): the deadline was a COUNT of completed one-second
      polls, not a clock reading, so per-iteration overhead (including
      the heartbeat's own work) could stretch 1200 counted ticks
      materially past 1200 real seconds under load — exactly when a
      timeout matters most. More seriously, the heartbeat ran
      SYNCHRONOUSLY inside the same loop, so a stalled `lease_heartbeat`/
      `touch` blocked the loop from ever reaching its next deadline check
      at all, coupling the deadline's own liveness to the filesystem
      operation it supervises. Fixed by reading a real timestamp
      (`date +%s`) once and comparing elapsed wall-clock time each
      iteration instead of counting passes, and by firing the heartbeat
      as a bounded, redirected, fire-and-forget background call
      (`</dev/null >/dev/null 2>&1 &`, never waited on) rather than
      synchronously — in the common case it completes in a fraction of a
      second and leaves nothing behind; in the pathological hung case
      this loop's own deadline enforcement is no longer blocked by it,
      and the orphan (a zombie once it does exit) is excluded from
      `run-tests.sh`'s own survivor check on principle, so this does not
      reintroduce the daemon shape just retired. Verified directly: with
      `lease_heartbeat` replaced by a 120-second hang, the SAME
      `run_with_timeout` call still returned 124 at ~36s (a 35s cap plus
      grace) rather than 120+s.
    - R4-F3 (MEDIUM): the per-spec watchdog's heartbeat counter was LOCAL
      to that one watchdog subshell, reset to 0 every time a fresh spec
      started, so a tier lasting many minutes but composed of
      sub-30-second specs never let any single watchdog's own counter
      reach 30 — the lease was never refreshed for the tier's real,
      cumulative duration, and after `dead_grace_s` (90s) a host sharing
      this one's hostname could misread the still-running tier as
      locally dead and reclaim its lease, reopening the exact collision
      the heartbeat exists to prevent. R3-F3 was PARTIALLY FIXED: a
      single long command genuinely heartbeats throughout (the case it
      was built for); the ordinary many-short-specs tier shape did not.
      Fixed by keying the decision off the lease FILE's own mtime
      (`_lease_mtime_epoch`, already in `tree-lease.sh`) instead of a
      per-watchdog counter — the mtime is the one piece of state that
      genuinely persists across every spec/watchdog boundary a tier
      crosses. Verified directly against the REAL runner (not a
      simulation): a 4-spec, 8-seconds-each fixture (32s cumulative, no
      single spec anywhere near 30s) showed the lease file's mtime
      advance at precisely t+31s into the run, mid-way through the
      fourth spec — 30 seconds after the initial acquire, exactly the
      documented cadence, despite three prior spec/watchdog boundaries
      that individually never got close.
    - R4-F4 (MEDIUM): the generation `mkdir` lock in `qa-gate.sh`'s
      `wipe_iteration_state` had no owner record and no stale-lock
      recovery — if a holder died (a crash, a SIGKILL) between acquiring
      and releasing it, the lock directory was left behind forever
      (`mkdir` locks have no built-in expiry), so every LATER call spent
      its own ~1s budget failing to acquire it and then proceeded
      read-modify-write UNLOCKED, silently, permanently, from that
      point on — broader than the shipped comment's "extreme contention"
      framing: one interrupted holder was enough, not sustained
      contention. Fixed with stale-lock recovery: the winning `mkdir` now
      records its own pid inside the lock directory; a waiter whose
      `mkdir` fails reads that pid and, if it is no longer alive
      (`kill -0`), removes the stale lock and retries within the SAME
      bounded loop rather than exhausting the budget and degrading. This
      does not need the pid-reuse-proof certainty `tree-lease.sh`'s own
      lease identity does (R1-F2/R2-F1) — a false "still held" reading
      here only ever repeats the pre-fix behaviour for that one call,
      never worse, while the common case (a genuinely dead holder) now
      self-heals instead of wedging permanently. Verified directly: a
      simulated crashed holder (a lock directory with a recorded, verified-
      dead pid) was reclaimed within the same bounded retry loop (0s
      wasted), and five consecutive calls after repeated simulated
      crashes each correctly reacquired the lock with the generation
      counter incrementing sequentially throughout, with zero lost bumps.
    - R4-F5 (LOW, documentation): the CHANGELOG passage above this entry,
      `tree-lease.test.sh`'s own header prose, and two comments in
      `verify-before-stop.sh` still described the retired daemon and its
      GNU-`timeout`-based predecessor as the shipped mechanism. Corrected
      in place rather than silently rewritten, naming what changed and
      why, matching this file's own "Rationale corrected" convention.
    - **Permanent test coverage for this round**, added after the fix and
      verified by running each new spec against both the shipped code and
      a purpose-built mutant. `run-with-timeout.test.sh` (NEW, 22
      assertions) drives `run_with_timeout` extracted verbatim from the
      shipped script: R4-F1 (5 repeated forced-timeout runs of the
      backgrounding-exploit shape, each independently confirmed leak-free
      by exact-PID matching on a distinct sleep duration per run, plus a
      mutant reverting the group check that reproduces rc=0-with-leak on
      demand) and R4-F2 (a 131s-hung heartbeat override proving the
      deadline still fires at ~cap+grace, plus a mutant reverting the
      heartbeat to synchronous that proves the identical scenario now
      genuinely blocks past the cap). `runner-completeness.test.sh` gained
      sections 18.3/18.4 (L1 and L2) for the R4-F3 gap specifically: 5 stub
      specs at 8s each (40s cumulative, no single spec anywhere near 30s)
      confirmed the lease's mtime advances mid-tier against the REAL
      runner, with a purpose-built mutant (a per-spec-reset tick counter,
      deliberately distinct from the "disabled outright" mutant sections
      18.1/18.2 use) proving the property specifically fails for the
      CUMULATIVE case when absent — the earlier single-long-spec mutant
      would still (correctly) fail to heartbeat here too, but for the
      wrong reason, and would not have distinguished this property from
      "heartbeating is broken entirely". That same edit surfaced and fixed
      a second, self-inflicted regression: the R4-F3 shipped-code change
      had removed the exact `$((waited % 30)) -eq 0` text sections
      18.1/18.2's own pre-existing mutant construction searched for,
      silently turning that mutant into a byte-identical copy of the
      shipped file (`diff` producing 0 lines, not the expected 2) — caught
      by re-running the section after the shipped-code edit rather than
      assuming a prior-round control still applied, and fixed by
      re-targeting the mutant's sed pattern at the new threshold
      (`-ge 30` -> `-ge 999999`, disabling the heartbeat outright, which is
      the property those two sections actually need) rather than
      reintroducing the retired tick-counter shape, which is what the new
      18.3/18.4 mutant is for instead. `qa-gate-lock-recovery.test.sh`
      (NEW, 12 assertions) drives `wipe_iteration_state` extracted from the
      shipped script for R4-F4: a genuinely-dead pid (spawned and reaped by
      the spec itself, not guessed or hardcoded) planted inside a
      hand-built stale lock is shown to self-heal within one retry
      iteration across 5 consecutive simulated crashes, with a mutant
      reverting to the pre-fix plain-`mkdir`-retry shape (no pid recorded,
      no recovery) shown to leave the lock directory behind permanently —
      the bug's own exact symptom, reproduced on demand.

      **Not current for two of these three files (round 6 DESIGN COLLAPSE,
      below) — corrected in place rather than left to mislead:**
      `run-with-timeout.test.sh`'s R4-F1/R4-F2 sections (2-4 and their
      METAs) tested the in-process rewrite directly; that rewrite is gone,
      their own target literals (`kill -0 -- "-$child_pid"`, the in-loop
      `lease_heartbeat` call) no longer exist in the shipped function, and
      every mutant built against them would have been byte-identical to
      the original — deleted along with the mechanism. What remains is
      sections 0-1 (extraction validity, exit-code/log-capture passthrough
      for a quick command — still true of the restored dispatch), measured
      at 6 assertions, all passing
      (`bash .claude/scripts/tests/run-with-timeout.test.sh`, this change
      set). `runner-completeness.test.sh` section 18 (18.1-18.4 and their
      METAs) is deleted in full for the identical reason — neither runner
      heartbeats at all now, so there is no "lease mtime advances during
      dispatch" property left for either the real legs or their mutants to
      exercise. `qa-gate-lock-recovery.test.sh` is the one file in this
      list that GAINED coverage rather than lost it: see R5-F3 below.

    **Fix round 5** (independent cross-family review): the daemon-to-
    in-process rewrite (round 4, above) had its own defects.
    - R5-F1 (HIGH): "normal completion" in `run_with_timeout` meant "the
      original supervised process group has no signalable members", not
      "the descendant tree is empty". The ordinary R4-F1 attack stayed
      fixed — a `sleep 1800 &` child stays in the wrapper's own group, so
      the loop keeps timing it and the group kill still reaches it — but a
      child that calls `setsid`/`setpgid` (a daemonising helper that then
      runs long work) LEAVES that group; once the wrapper exits 0 the
      original group reads empty and the function returns 0 while the
      detached work keeps running, unsupervised. The timeout branch was
      weaker still: it signalled the group and waited only for the
      wrapper, never confirming the group had actually emptied. This is
      the same "wrapper exited" mistaken for "work finished" shape as
      R4-F1 and the earlier fd-orphan/phase5-survivor pair — a fourth
      occurrence, in the function every verification in this plugin flows
      through.
    - R5-F2 (MEDIUM): `.claude/tests/component/specs/verify-before-stop.sh`'s
      `vbs-r3fix` heartbeat mutant targeted the retired literal
      `[ "$hb_tick" -ge 30 ]`, which by this point occurred zero times in
      the shipped hook (the condition had already become
      `"$((now - hb_last))" -ge 30` in an earlier round) — the "mutant" was
      byte-identical to the original, its own non-vacuity guard required 2
      changed lines and got 0, and the section was failing RED, unnoticed
      because it had not been re-run since the shipped-code edit that broke
      it. Sixth instance in this batch's own controls of a check that does
      not exercise the mechanism it names.
    - R5-F3 (MEDIUM): `qa-gate.sh`'s stale-lock recovery (R4-F4, round 4)
      only covered a holder that recorded a NUMERIC pid before dying. A
      crash — or a failed write — between the winning `mkdir` and its very
      next line left a lock directory with no valid pid file, and the
      pre-fix handling of that state was a bare no-op: an ownerless lock
      persisted FOREVER, and every later call proceeded UNLOCKED,
      permanently, from that point on — the exact defect R4-F4 believed it
      had already closed, just reached a different way.
    - R5-F4 (MEDIUM): the round-4 in-process heartbeat was correctly
      decoupled from a stalled deadline, but it was still a background
      process that could outlive the call it was fired from — the round-4
      spec explicitly acknowledged and killed that orphan. A persistently
      blocked heartbeat accumulated roughly one process per 30s in the Stop
      hook; the runner watchdogs could launch a new one every second while
      the lease mtime stayed old, and their own mtime lookup could itself
      block on a stalled mount. The daemon was retired to remove exactly
      this class of defect; the fire-and-forget heartbeat reintroduced a
      narrower version of it.
    - R5-F5 (LOW): `runner-completeness.test.sh`'s dolt-flusher spawn probe
      (`poll_for_dolt_flusher`, section 15.9/15.10) set its `hit` result
      only inside a fixed ~3-second sampling loop; a flusher visible only
      during `wait "$bgpid"` or only to the post-drain loop that already
      ran afterward anyway (to confirm the tree was clear) left `hit`
      unset regardless of what the post-drain had just spent up to 5
      seconds watching. The 15.10 NEGATIVE CONTROL could therefore pass
      for the wrong reason: a real spawn the config failed to suppress,
      observed only outside the original window, still read "not-seen".
    - R5-F6 (LOW): `verify-before-stop.sh`'s `STOP_TIMEOUT_FILE` /
      `read_stop_timeout` had no caller anywhere in the file, and the
      header still promised a configurable 60s "outer wrapper" timeout
      that knob was supposed to provide, while `settings.json` supplies a
      fixed 1320000ms Stop-hook timeout regardless. A dead knob plus a
      stale contract.

    **Fix round 6: DESIGN COLLAPSE** (operator-directed). Five independent
    review rounds on this task's own lease and heartbeat machinery produced
    one causal chain: a lease could read a live cross-host owner as
    reclaimable -> fixed with an UNCONFIRMED state -> that made the
    ordinary same-host crash path routinely false for up to three hours ->
    fixed with a heartbeat -> the heartbeat's own daemon orphaned a child
    and held the Stop hook's stdout -> fixed by retiring the daemon and
    rewriting `run_with_timeout` in-process -> that rewrite could
    under-report a finished command via `setsid` (R5-F1), in the function
    every verification in this plugin flows through, and its own heartbeat
    still accumulated background processes (R5-F4). Each fix was a
    legitimate correction of a real defect the PREVIOUS fix had introduced;
    five rounds in, the pattern itself was the finding.

    **The operator's decision: the lease becomes report-only.** It reports
    who claims to own a tree; it never auto-reclaims anything, ever again.
    `lease_acquire` no longer calls `lease_reclaim_stale`. Once nothing is
    ever deleted on the strength of a liveness guess, the precision every
    round above was fighting for stops mattering for CORRECTNESS and only
    affects message quality — so the heartbeat this whole chain was built
    to keep fresh is unnecessary, full stop, and is deleted from every
    caller and from `tree-lease.sh` itself (not disabled, not hardened
    further — removed): `lease_heartbeat` no longer exists anywhere in the
    shipped code, and neither does any caller of it. `run_with_timeout`
    reverts to the ORIGINAL, pre-fix-arc `timeout`/`gtimeout` dispatch this
    same entry describes it being rewritten FROM, four fix rounds ago —
    the one accepted trade restored along with it, unchanged from before
    this whole arc began: a host with neither `timeout` nor `gtimeout` on
    PATH runs the command UNBOUNDED (macOS ships neither by default;
    `brew install coreutils` provides `gtimeout`).

    **The trade, stated rather than left for a reader to wonder about:** a
    lease whose owner crashed now lingers in `<dir>/leases/` until
    something else removes it — there is no accumulation problem in
    practice (a handful of small text files), and `lease_reclaim_stale`
    remains defined and directly callable by an operator who wants to
    sweep them (`bash -c '. tree-lease.sh; lease_reclaim_stale "$dir"'`),
    just never invoked on anyone's behalf. This is the deliberate price of
    never again deleting a lease that might be live: the R2-F1 risk (a
    cross-host collision reclaiming a genuinely live owner) and the R3-F3
    risk (an ordinary crash reading falsely live for hours) both required
    machinery to arbitrate correctly; removing the arbitration removes
    both risks by removing the thing they were both about. The four-way
    STALE/LIVE/LIVE-BUT-OLD/UNCONFIRMED split and its two independent age
    thresholds (`stale_s`, `dead_grace_s`) existed only to feed that
    arbitration; with nothing left to decide, the grammar collapses to two
    values with no threshold behind either: LIVE (this host, a recorded
    pid that answers `kill -0`, whose measured elapsed runtime is
    consistent with the lease's own recorded `started_at` — same PROCESS,
    not a reused pid) and STALE (everything else). Age is still printed
    for both, as information a human deciding whether to go look might
    want, but nothing treats any age as a threshold to cross any more.
    `tree-lease.sh`: 40,493 -> 27,307 bytes measured at this change set
    (`wc -c .claude/scripts/tree-lease.sh`); `tree-lease.test.sh`: 71
    assertions, all passing (`bash .claude/scripts/tests/tree-lease.test.sh`,
    this change set) — its own former heartbeat section (old section 9)
    and the `dead_grace_s`-specific section (old section 14) are deleted
    outright, because the mechanisms they guarded no longer exist anywhere
    in this codebase, not repaired to match a design that is gone.

    **The three round-5 findings independent of the collapse, resolved on
    their own terms:**
    - R5-F3: fixed by treating "no confirmable numeric owner" — whether
      reached via an absent pid file or a present-but-empty/garbage one —
      as ONE recoverable state, reclaimed after exactly one retry's grace
      (this loop's own 0.1s sleep) rather than on first sighting. The
      grace matters: for a few microseconds after a genuinely live
      winner's `mkdir` succeeds and before its own printf lands, this
      state is indistinguishable from the crashed case, and reclaiming on
      the very first sighting would let a waiter steal a lock its live
      holder is a moment from legitimately owning; by the second sighting,
      at least one full 0.1s sleep has elapsed, orders of magnitude longer
      than a single local `printf` to a small file ever takes to land.
      `qa-gate-lock-recovery.test.sh` gained sections 4-6 (the no-pid-file
      and empty-pid-file cases, single and 5x repeated) plus a surgical
      META that reverts only this branch — not the whole R4-F4 mechanism —
      located by two independently-unique line anchors rather than a
      hand-written multi-line pattern; 24 assertions total, all passing
      (`bash .claude/scripts/tests/qa-gate-lock-recovery.test.sh`, this
      change set). **Verifying that META surfaced a SEPARATE, pre-existing
      regression this same fix caused as a side effect**: the ORIGINAL
      R4-F4 META (which reverts the whole retry loop via a hardcoded
      "skip the next 14 lines" awk transform) assumed a loop body length
      that this fix's own additions grew from 14 lines to 19 — the
      transform then consumed only part of the original loop, leaking its
      tail into the "mutant" and producing a diff of 17 lines where 13 was
      expected, and a mutant that failed `bash -n` outright. Fixed by
      re-anchoring that transform on the loop's own matching `done` line
      instead of a hardcoded count, so a future change inside the loop
      cannot silently re-break it the same way. Caught by re-running the
      file after the fix, not assumed correct because the change set
      looked self-contained.
    - R5-F5: fixed by running the identical new-pid check the sampling
      loop already used inside the post-drain loop too, so any attributed
      pid `poll_for_dolt_flusher` observes anywhere in its own lifetime —
      sampling window or post-drain window, whichever — sets `hit`; the
      drain-to-completion behaviour is unchanged, this only adds an
      observation to a loop that was already running. Proved with a new
      META-TEST built on a deterministic, call-counted stub of the
      pid-attribution primitive (empty for the 62 calls the shipped loops
      make before post-drain begins, a fake never-baseline pid from call
      63 onward) rather than a real timing race against actual dolt/ps
      latency, which would have made the scenario itself flaky to
      construct: the shipped function reports "seen", a mutant with just
      this check removed (via `declare -f`, i.e. from what bash itself
      already parsed out of the shipped definition, not a hand-retyped
      copy) reports "not-seen" for the identical scripted scenario — the
      bug's own exact symptom, reproduced on demand. Known residual,
      disclosed rather than silently accepted, and LARGER than polling
      granularity alone would suggest (corrected here — see gsfd R6-F3:
      this paragraph previously named only the smaller of the two blind
      spots below and so understated the gap). Two distinct blind spots,
      not one: a flusher that spawns and fully exits inside the ~50ms gap
      BETWEEN two polls, in either loop — small, bounded by the poll
      interval itself; and a flusher that spawns and fully exits ENTIRELY
      inside `wait "$bgpid"` above, where NOTHING polls at all — bounded
      only by how long the launched `dolt sql` itself takes, which can be
      far longer than 50ms under a slow store. Closing either needs an
      event-based mechanism (strace/dtrace/an audit hook), not a tighter
      poll interval or a poll wedged into the wait — the latter is the same
      background-supervision shape this task's own operator-directed
      collapse removed elsewhere (the lease heartbeat), reappearing here.
    - R5-F6: `STOP_TIMEOUT_FILE`/`read_stop_timeout` were already dead code
      with no caller (deleted as part of the round-6 `run_with_timeout`
      revert above); the remaining gap was the header's own stale claim of
      a "configurable outer wrapper timeout" that knob used to provide.
      Corrected in place: the header now states the three fixed timeouts
      (1200s/300s/600s) are each enforced by `run_with_timeout`'s own
      `timeout`/`gtimeout` call, names what was deleted and why, and points
      at `settings.json`'s fixed 1320000ms Stop-hook timeout as the actual
      wall-clock ceiling.

    **A seventh instance, found by the sweep this round's own instructions
    asked for rather than by an independent reviewer**: `runner-
    completeness.test.sh` section 16 (the CONCURRENT-RUN NOTICE integration
    coverage) asserted the OLD four-value grammar directly — a stale lease
    "reclaimed" (16.6, expecting the file gone afterward) and a
    fresh-mtime dead pid read UNCONFIRMED and surfaced as a distinctly-
    worded notice (16.6b-d) — both properties the round-6 collapse removed.
    Re-running the full file after the collapse (not assumed unaffected
    because the change looked confined to `tree-lease.sh` and `qa-gate.sh`)
    showed 16.6 and 16.6b failing exactly as the collapse predicts: the
    stale lease file survives (report-only, correctly) where the pre-
    collapse assertion expected it gone, and the fresh-mtime scenario
    prints no notice (STALE now, unconditionally) where the pre-collapse
    assertion expected one. Fixed by asserting the CURRENT invariant
    directly — a dead-pid lease is never surfaced as a conflict and always
    survives, IDENTICALLY regardless of its mtime — rather than deleting
    the age-comparison coverage outright; proving age no longer changes the
    outcome is a real, meaningful property of the collapse, not a
    redundant restatement of 16.5. 338 assertions, all passing
    (`bash .claude/scripts/tests/runner-completeness.test.sh`, this change
    set; two runs, one after the section-16 fix, both fully green).

    Filed rather than fixed in this round, per its own "delete substantially
    more than you add" instruction: nothing in this suite proves
    `run_with_timeout` returns 124 for a GENUINE (non-backgrounding-trick)
    hang past its deadline via the restored plain dispatch — the single
    most safety-critical property of the function, and currently
    unverified anywhere, tracked separately (`claude-workflow-plugin-v4jn`).

    **Fix round 7** (a further defect found continuing the round-6 sweep,
    after the collapse above had already shipped): the collapse's own "one
    accepted trade" two paragraphs up — a host with neither `timeout` nor
    `gtimeout` on PATH runs the restored dispatch UNBOUNDED — was correctly
    stated, but nothing downstream disclosed it happening at runtime. The
    unbounded branch's own inline comment claimed "log indicates this";
    nothing did — `: > "$log"` at the top of `run_with_timeout` and the
    command's own `>"$log"` redirect both TRUNCATE, so a marker written
    before either point is destroyed before anyone reads it, and the
    pre-fix branch wrote nothing after either. Nor did the operator-facing
    "WHAT THIS GATE RAN, EXACTLY." block (`checks_scope_note`) say
    anything: it already names every OTHER unmeasured stage ("NOT RUN
    tests ...") but stayed silent about an advertised cap that quietly did
    not apply on the RAN ones. Consequence: the gate named a
    `${TEST_TIMEOUT_S}s`/`${LINT_TIMEOUT_S}s`/`${TYPE_TIMEOUT_S}s` bound it
    never enforced on such a host, and a genuinely hung command would be
    stopped only by the surrounding Stop hook's own wall-clock timeout
    (`.claude/settings.json`, 1320000ms) — killed with no output at all,
    which this plugin's own hook contract already treats as advisory
    rather than blocking (no JSON envelope means nothing instructs Claude
    to stay). A hang, on such a host, read as "nothing happened," not as a
    timeout — and a hook that emits nothing is non-blocking.

    **Disclosure, not enforcement — the two should not be confused.** On a
    host lacking both binaries the command still runs unbounded after this
    round, identically to before it; what changed is that the gate now
    says so, in the same voice as its other "NOT RUN" lines. The
    in-process supervisor round 6 removed (the causal chain two
    paragraphs above) WAS providing genuine enforcement on such a host —
    it carried R5-F1 (HIGH, a `setsid` escape from the process-group
    supervision the rewrite depended on, in the one function every
    verification in this plugin flows through), one of the round-5
    findings the round-6 collapse cites as why patching this chain
    further was the wrong move — and removing it was still the right
    call. This round does not reopen that decision or restore any
    enforcement on the affected hosts; it closes the honesty gap the
    reversion reopened alongside a trade the collapse always intended to
    accept.

    Fixed: the unbounded branch now captures the command's real exit code
    before writing anything else (so the trailing marker write can never
    overwrite the return status the 124-means-timeout convention depends
    on), appends a marker line to the log AFTER the command's own output —
    appended, never prepended, since prepending would itself be destroyed
    by the command's own truncating `>"$log"` open — and sets a
    `TIMEOUT_NOT_ENFORCED` flag, reset at the top of EVERY call (including
    the two branches that never take it) so a stale value from an earlier
    check in the same run can never survive onto a later one that took a
    different branch. **This reset-on-every-call design is superseded by
    Fix round 8 below (`gsfd` R6-F1): resetting the FLAG on every call does
    not stop three SEQUENTIAL calls from disagreeing with each other, which
    is a different property than the one this paragraph verified — see that
    round for the two ways it went wrong and the fix.** `checks_scope_note`
    reads that flag and prints a
    `TIMEOUT NOT ENFORCED:` paragraph naming which RAN check(s) and their
    advertised cap went unbounded; it reaches every operator-facing
    `REASON` string — the FAILED_CHECKS path and both the escalated and
    non-escalated QA-approval-required paths — because all three already
    call `checks_scope_note` for the "WHAT THIS GATE RAN" block. The
    disclosure points at `.claude/settings.json` rather than hardcoding
    the Stop hook's own outer-timeout figure, deliberately, so the string
    cannot go stale against a number that lives in a different file.

    New/updated coverage: `run-with-timeout.test.sh` gains section 2 — 2a
    mutates PATH to resolve neither `timeout` nor `gtimeout` (two
    preconditions assert the mutation actually landed) and checks the
    log, the passed-through exit code, and the flag all land correctly;
    2b is the restore control, a working `timeout` stub prepended to
    PATH, proving the marker does NOT fire once a `timeout` binary resolves
    on PATH (corrected here — see gsfd R6-F2: this sentence previously said
    the stub proves a cap "genuinely is enforced", which the stub's own
    header already disclaimed — it drops the duration argument and execs
    the rest, enforcing nothing; what 2b actually proves is marker
    SUPPRESSION on binary resolution, not that a bound is genuinely held).
    13 new assertions (2a: 2 preconditions + 6; 2b: 1
    precondition + 4), bringing the file to 19 total, up from the 6 that
    survived round 6's own deletion of sections 2-4 — counted directly
    against the shipped file, this change set:
    `grep -c '^assert_eq\|^assert_contains' .claude/scripts/tests/run-with-timeout.test.sh`
    returns 21, less the two function definitions (`assert_eq()` and
    `assert_contains()`) the same anchor matches at the top of the file.
    (This entry reports that count, not a fresh pass/fail run — this
    documentation task's own brief excluded running any test tier.) A new
    `vbs-tmo` section in
    `.claude/tests/component/specs/verify-before-stop.sh` drives the
    identical property end-to-end, through the real Stop hook dispatch
    against a not-yet-approved task: `tmo-a` (the absent-binaries leg,
    conditional on the ambient host genuinely lacking both binaries —
    honestly named `SKIPPED:` otherwise, matching this tier's established
    idiom for an environment the harness cannot force) and `tmo-b` (the
    restore control, forced on any host by prepending a working `timeout`
    shim to PATH for that one dispatch).

    Two gaps remain in this area, both filed rather than folded into this
    round. `claude-workflow-plugin-v4jn` (pre-existing, unchanged by this
    round): a different property from this round's own disclosure work —
    does an unbounded run SAY so, never does a cap actually fire — needing
    the OPPOSITE PATH setup (a working `timeout` shim present, not
    absent). `claude-workflow-plugin-cdmp` (new, filed this round):
    `tmo-a` above is conditional on the ambient host already lacking both
    binaries, so it is honestly SKIPPED rather than exercised on Linux CI
    runners, which ship `timeout` in coreutils — the disclosure's
    end-to-end gate-block path is therefore verified on a macOS-like host
    only, never in CI; the function-level behaviour in
    `run-with-timeout.test.sh` section 2 is unconditional and covers every
    host, including CI.

    **Fix round 8** (`gsfd` R6-F1, review round 6): the disclosure fixed in
    round 7 above reset `TIMEOUT_NOT_ENFORCED` at the top of EVERY
    `run_with_timeout` call and decided the branch by re-probing `command -v`
    each time — correct for a single call, but the real dispatch in
    `verify-before-stop.sh` calls it up to THREE times in one shell (test,
    then lint, then type-check), and `checks_scope_note` reads the flag only
    ONCE, after all three, then names EVERY stage that ran under it. Two
    ways for that combination to lie, and review named the second as the
    one that matters more: a bounded call followed by an unbounded one made
    the summary claim ALL ran stages went unbounded (false for the bounded
    one); an unbounded call followed by a bounded one CLEARED the flag,
    hiding the unbounded call entirely from the summary that runs after
    both. Fixed by deciding ONCE per shell rather than per call: the first
    `run_with_timeout` invocation in a run caches its `command -v` answer in
    a new global, `TIMEOUT_DISPATCH` (`timeout` / `gtimeout` / `none`), and
    every later call in the SAME shell reuses that cached answer instead of
    re-probing PATH — so every dispatch call in a run takes the identical
    branch, and the flag's value after the last one accurately describes all
    of them, never a subset. The trade, disclosed rather than hidden: a
    capability that genuinely regresses mid-run (a `timeout` binary removed
    from PATH between two calls) now fails LOUD — the cached branch is
    attempted regardless, and a binary no longer where the cache expects it
    produces a real "command not found" exit — instead of silently sliding
    into the unbounded branch a second time. A host that always has, or
    never has, the binary behaves byte-for-byte as before.

    Also corrected this round, both named directly in the review, neither a
    design change: the file header's B3 line and the tunable-timeouts
    comment both said the three caps are "each enforced" / commands are
    "capped" unconditionally, which this repo's own authoring box (neither
    `timeout` nor `gtimeout` on PATH) already falsifies — reworded to name
    the condition. And this CHANGELOG's own round-7 entry above claimed the
    `run-with-timeout.test.sh` 2b restore-control stub proves a cap
    "genuinely is enforced" — the stub itself (its own header already says
    so) enforces nothing, so that sentence is corrected in place to describe
    what 2b actually proves: marker suppression once a `timeout` binary
    resolves on PATH.

    New coverage: `gate-claim-honesty.test.sh` gains section 8 (+ 8M META),
    driving the REAL awk-extracted `run_with_timeout` and the REAL
    `checks_scope_note` together in one shell — two sequential calls with
    deliberately differing PATH environments, in both orderings (8a:
    unbounded then would-resolve; 8b: bounded then would-not-resolve) — and
    proving the shipped code no longer exhibits either misattribution while
    a mutant reverting the cache (the pre-fix per-call reprobe, forced via
    `if true; then` in place of the cache check) reproduces both exactly.
    19 new assertions — measured directly against section 8's own line range
    in this change set (`sed -n '2640,2780p' .claude/scripts/tests/gate-claim-honesty.test.sh | grep -c '^assert_eq\|^assert_contains\|^assert_absent'`),
    not the whole-file anchor count the round-7 entry above used: that count
    is a less precise proxy here, since it also matches the three
    `assert_eq()`/`assert_contains()`/`assert_absent()` function DEFINITIONS
    as false positives while separately missing three pre-existing INDENTED
    calls elsewhere in the file the same `^`-anchor cannot see (two of them
    mutually-exclusive if/else alternates) — the whole-file static count and
    the runtime PASSED count already disagreed by one for reasons that
    predate this change, which is why this entry measures its OWN new
    section directly instead of repeating that proxy. Unlike round 7's own
    entry above, this one IS a fresh run, not a static count:
    `bash .claude/scripts/tests/gate-claim-honesty.test.sh` on this change
    set passes 297 assertions total (0 failed); re-running
    `bash .claude/scripts/tests/run-with-timeout.test.sh` confirms that
    file's own 19 assertions are unaffected — its sections 0-2 each call
    `run_with_timeout` once per subshell, so the caching this fix adds is
    never exercised across two calls there; that cross-call property is
    what section 8 above is for.

  - **Fixed shared paths removed at the root, not mitigated.**
    `verify-before-stop.sh`'s `TEST_LOG`/`LINT_LOG`/`TYPE_LOG` move from
    three names fixed across every concurrent Stop hook invocation to a
    per-run scratch directory — FOUR measured occurrences of the gate
    asserting "Tests failing (exit 2)" while citing a log that had been
    deleted out from under it (by a concurrent Stop hook's own truncate, or
    by `qa-gate.sh`'s `enter`/`approve`/`choose` wipe, which runs for ANY
    task regardless of who is mid-write). A stable, fixed-name convenience
    copy is still written for human/agent debugging after capture completes
    — advisory only, never read back by the gate's own logic, so a race on
    it is cosmetic. `.claude/tests/component/specs/model-select.sh` (19
    occurrences) and `code-graph-mcp.sh` (2 more, found by enumerating every
    fixed `/tmp/` redirect across the whole L2 specs population rather than
    trusting the one file a prior review named) move the same way, onto
    `mk_fixture`'s own per-spec directory. A new structural census
    (`runner-completeness.test.sh` section 17) reds if a fixed `/tmp/` path
    is reintroduced anywhere in that population.

    **Fix round 1** (`gsfd` R1-F1, R1-F7):
    - R1-F1: the ABOVE claim was false on its own final fallback branch.
      `run_scoped_log_dir`'s own header at the time documented "if even THAT
      mkdir fails, this degrades to the historical shared QA_TRACKING_DIR
      itself" in the SAME breath this changelog entry denied it — both were
      true statements about different branches, and the degrade one was
      reachable with nothing more than a plain FILE sitting at
      `.claude/.qa-tracking/runs` (defeats `mkdir -p`, `mktemp -d`, and the
      `$RANDOM` fallback all at once, since none can create anything nested
      under a path that is not a directory). Fixed with a second retry tier
      directly under `$QA_TRACKING_DIR` (bypassing the blocked `runs/`
      entirely), and — only if even that fails — an EMPTY return that moves
      uniqueness from the directory to a per-pid/nonce-suffixed FILENAME the
      caller builds instead; the shared, unqualified `QA_TRACKING_DIR` path
      is no longer reachable at all. This mechanism had zero direct test
      coverage before this fix; new L1 spec `scoped-log-dir.test.sh` (24
      assertions as measured by
      `bash .claude/scripts/tests/scoped-log-dir.test.sh` at this change
      set) drives the shipped functions via awk extraction and replays the
      historical pre-fix body (captured verbatim) to prove the exact
      collision it used to produce.
    - R1-F7: the census itself missed a QUOTED fixed redirect
      (`2>"/tmp/x"`) twice over — the detection regex required no quote
      between the operator and `/tmp/`, and the JSON-false-positive filter
      would ALSO have excluded a quoted target even if the first stage had
      caught it. A separate pass now catches quoted targets specifically
      (an opening quote immediately adjacent to the operator can only be a
      real "quote this redirect" idiom; the JSON shape's own opening quote
      never sits there). Separately, the census silently read an
      unreadable population (missing directory, zero `.sh` files) as
      CLEAN — the glob-over-grep shape left the glob unexpanded, grep's
      "No such file" went to a suppressed stderr, and the function's own
      `return 0` swallowed the rest. It now enumerates explicitly and
      returns a distinct, non-zero, stderr-diagnosed failure when the
      population cannot be read at all.

    **Fix round 2** (`gsfd` R2-F5, sol-codex review): two more census gaps.
    A SINGLE-quoted fixed redirect (`2>'/tmp/x'`) missed BOTH R1-F7 passes
    (the double-quoted pass needs a literal `"`; the bare pass needs no
    quote at all) — closed with a fourth pass mirroring the double-quoted
    one, quote character swapped, same non-vacuity reasoning (this tree's
    one JSON false-positive shape can never produce a single quote sitting
    immediately after a redirect operator, since JSON's own delimiter is
    `"`). Separately, a population that DID enumerate (non-empty file list)
    could still scan clean past an UNREADABLE `.sh` file inside it — `find`
    can list an unreadable file by name via its parent directory's own
    permissions, and every grep pass suppressed its own stderr while the
    function's `return 0` ignored every grep exit code, so an open failure
    on ONE file was indistinguishable from a genuinely clean scan of ALL of
    them. Fixed by checking each grep pass's own exit code in isolation (2
    means a read/open error occurred, independent of whether it ALSO found
    matches in files it could read — measured on both GNU and BSD grep) and
    by routing `find` through a captured file rather than a process
    substitution, the only way to observe `find`'s OWN exit status at all
    (a nonzero exit there — an unreadable top-level directory, or a
    partial listing — now reports distinctly from "enumerated fine, found
    nothing").

  - **The unevidenced-failure tail read now hedges instead of asserting.**
    `log_tail()` used to print the bare literal `(no log)` for an absent
    file — indistinguishable from "produced no output" — over what was
    measured, four times, to actually be a log that had been written and
    then removed. It now says so, naming a concurrently-active lease when
    tree-lease.sh observed one at capture time, mirroring the honesty
    `run-tests.sh`'s own STORE-CANARY already gives the identical ambiguity
    ("either this spec wrote, or another process wrote concurrently").

    **Fix round 1** (`gsfd` R1-F6): a cached Stop replay (escalation, or
    tree-and-change-set-unchanged) used to carry only the RENDERED bullet
    text, whose "see `<stable log>`" phrase points at a shared, mutable,
    fixed-name file — by the time a replay's message is actually read, that
    file can hold a different run's capture (a concurrent Stop's own
    overwrite) or nothing (`qa-gate.sh`'s wipe). The actual captured tail
    text is now ALSO persisted per task and restored on replay
    (`replay_cached_tails_for`), so a replayed verdict shows the same
    evidence the original run's own verdict was based on, independent of
    whatever the shared name currently resolves to.

    **Fix round 2** (`gsfd` R2-F2, R2-F4, sol-codex review + orchestrator
    acceptance measurement):
    - R2-F2: the component spec's own META-TEST for R1-F6 (a stripped copy
      of `replay_cached_tails_for` re-running the identical escalated
      replay) measured `.decision` EMPTY instead of `block` — read at
      first as a crash-shaped defect, but MEASURED to be neither a crash
      nor an R1-F6 regression: firing the mutant's call as a SECOND
      escalated Stop against the SAME task, with no `qa-gate.sh choose` in
      between, trips `verify-before-stop.sh`'s own, unrelated auto-defer
      counter (`AUTO_DEFER_AFTER_ESCALATED_STOPS=2`) regardless of any code
      change — reproduced with the completely UNMUTATED shipped hook fired
      twice in a row, identical `{}` outcome. Fixed in the TEST, not the
      hook: the per-task auto-defer counter is reset directly (the same
      tracking-file-poke idiom this spec already uses for
      `changed-files.txt`) immediately before the mutant's own call, so it
      runs as this task's escalated Stop #1 again — every OTHER piece of
      state the META-TEST actually exercises (the escalation label, the
      corrupted STABLE log, the persisted tail cache) is left untouched.
    - R2-F4: R1-F6 fixed replay WITHIN one cycle; it left open a cross-CYCLE
      case — `qa-gate.sh enter`/`choose continue` can wipe a task's
      per-cycle state (including the R1-F6 tail cache) while an OLDER Stop
      hook invocation from the PREVIOUS cycle is still mid-run (a slow
      suite, a stale process). That older run, unaware anything moved on,
      would go on to persist its OWN now-stale results over the just-wiped
      files — a LATER cycle replaying an EARLIER cycle's evidence, the
      R1-F6 defect pointing the other direction. Fixed with a per-task
      CYCLE GENERATION counter (`qa-gate.sh`'s `wipe_iteration_state` bumps
      it on every enter/choose-continue/choose-tech-debt/approve);
      `verify-before-stop.sh` reads it before dispatch and again right
      before persisting, refusing every write (rc/runner/failed-checks/all
      three tails) if the two disagree — the same refuse-not-persist
      direction `record_verified_state` already takes on a mismatched tree
      reading, applied to cycle identity instead. **Claimed here as
      "driven with a REAL concurrent `qa-gate.sh enter` against a
      genuinely slow (`sleep 12`) test command, not a simulated race" —
      corrected, not true (R3-F1, round 3 review): the control's stub JSON
      used `sleep 12 \&\& exit 1`; `\&` is not a valid JSON escape, `jq -e`
      on that exact payload returns rc 5 (measured directly), `TEST_CMD`
      resolved empty, and the hook finished and persisted before the
      concurrent `enter` ever fired — nothing was actually racing, and
      every assertion in this control passed vacuously. See fix round 3,
      below, for the corrected control and its own mutant-based
      negative-control proof.** Residual, stated rather than
      silently shipped: this closes the CROSS-CYCLE case; it does not give
      the six per-task cache files one atomic write as a unit, so two Stop
      hooks truly concurrent WITHIN the same cycle can still interleave
      individual field writes — closing that fully needs a bundled,
      atomically-renamed snapshot format, larger deferred work.

    **Fix round 3** (`gsfd` R3-F1, R3-F2, sol-codex review): two more
    issues in this same area, the second a direct continuation of R2-F4's
    own disclosed residual above.
    - R3-F1: see the in-place correction above — the round-2 fix was
      verified against a control that never actually held the hook inside
      its post-capture window, the same "a control that passes tells you
      nothing until you know which branch it exercised" defect class as
      R2-F2 and R2-F7 elsewhere in this changeset. Fixed by replacing the
      sleep-and-hope stub with one that touches a marker file before
      sleeping, so the test POLLS (bounded, up to 30s) for genuine entry
      into the post-capture window instead of guessing a fixed duration
      from a value that, it turned out, was never even reaching the shell
      it was meant to run in — and asserts the marker's arrival directly,
      rather than assuming it. A mutant-based negative control was
      added alongside it — the two CYCLE-GEN sentinel regions stripped via
      the same `awk_mutate` pattern this spec already uses elsewhere — that
      fires the IDENTICAL marker-synchronized race against the mutant hook
      and asserts the write now SUCCEEDS, proving the fixed control
      actually discriminates fixed-from-unfixed rather than passing
      regardless of which branch ran.
    - R3-F2: the TOCTOU window R2-F4 disclosed above as still open (a Stop
      reading generation before a concurrent `enter` wipes and bumps it,
      then persisting its six stale files after) is narrowed here, not
      newly closed. `wipe_iteration_state` now bumps the generation FIRST,
      before any per-task deletion, under a bounded `mkdir`-based lock
      around the read-modify-write itself — the increment was not atomic
      either, so two overlapping wipes could previously lose a bump
      independent of the ordering issue. `verify-before-stop.sh` adds a
      SECOND generation read immediately after persisting and rolls its own
      just-written six files back out if it no longer matches, on top of
      the existing pre-write check. The bundled-atomic-snapshot rewrite
      R2-F4 already named as the actual fix for a fully-concurrent-within-
      one-cycle interleave remains deferred, larger work — this shrinks the
      window the round-2 fix left open, it does not close it.

  - **The embedded Dolt engine's own telemetry flusher is disarmed, not just
    bd's.** `BD_DISABLE_METRICS=1` stops `bd send-metrics`; bd embeds dolt,
    and the embedded engine spawns its own `dolt send-metrics` that variable
    cannot reach — the leaked survivor `runner-completeness.test.sh` was
    measured killing itself for. Both runners now also call
    `dolt config --local --add metrics.disabled true` against the repo's
    embedded store at startup, writing to an untracked, repo-scoped path
    (`.beads/embeddeddolt/beads/.dolt/config.json`, excluded by
    `.beads/.gitignore`) rather than the user's global dolt config. Measured
    by driving it: 4/4 trials spawned the flusher with no local config, 0/4
    once the config was set.

    **Fix round 2** (`gsfd` R2-F7, sol-codex review): the spawn-detection
    probe itself (`runner-completeness.test.sh`'s 15.9/15.10) matched ANY
    `dolt send-metrics` process HOST-WIDE, with no attribution to the store
    a given call actually exercised — MEASURED both ways: 15.10 failed
    under a contended acceptance run (foreign Dolt activity elsewhere
    misread as this store's own), and passed clean idle. The disarm
    mechanism itself was never in question, only the probe's ability to
    tell "this store" from "some other Dolt activity" apart. Fixed by
    attributing on two signals together: cwd (a genuine flusher launched
    from `cd "$store" && dolt sql` inherits that cwd — read via
    `/proc/<pid>/cwd` on Linux or `lsof -a -p <pid> -d cwd` on macOS, no
    `/proc` there) AND "newly observed" (15.9 and 15.10 share one fixture
    store, so cwd alone cannot tell a slow-to-exit flusher one call spawned
    from one the OTHER call spawns — a pre-call snapshot of every
    already-attributed pid is the baseline a hit must be absent from).
    Degrades to a distinct `unattributable` outcome, never silently
    treated as `not-seen`, when neither `/proc` nor `lsof` is available.

  - **A concurrent tier's lease is named, not guessed.** Both runners print
    a `CONCURRENT-RUN NOTICE` at startup when a live lease from the other
    tier is found, so a red spec downstream of contention
    (`review-separation.test.sh` reading real bd records perturbed by a
    concurrent L2 run) is attributable in one read. This does not eliminate
    the contention — a genuine lock, or fixture-local bd workspaces for
    record-touching specs, remain open, larger work — it makes the
    contention nameable.

- **The design phase gets an artifact, a schema, a hash binding, and an edit
  ban** (`fkm.3`, v5.0.0 Phase D1). The designer's prompt body ships, the design
  artifact at `docs/specs/<task-id>.md` gets a machine-checkable contract, and
  the approval record gains a fourth machine token that names the bytes the
  design was.

  - **`review-check.sh validate-design <file>`** — the ONE validator gains a
    fourth schema, beside `validate-request` / `validate-artifact` /
    `validate-completion`. It checks eight required `## ` prose sections and one
    `<!-- DESIGN-UNITS BEGIN/END -->` block: `contract_version`, `task_id`,
    `designer_identity`, and a non-empty `units[]` where every unit declares a
    unique `unit_id`, a `goal`, a `verification` command, a **non-empty
    `files[]`**, `acceptance[]` of `{id, text}`, a `depends_on` naming only
    declared unit ids, and an `escalation_reason` whenever `implementer_class`
    is `high` — with the dependency graph checked for cycles.

    The extraction is specified from scratch rather than modelled on
    `epic-gate.sh files_changed_of`, which the plan pointed at. Measured: that
    idiom's selector is `jq -R 'capture("\\{[^{}]*\"…\"[^{}]*\\}")'`, and `jq
    -R` is line-oriented, so a PRETTY-PRINTED object never matches and
    `[^{}]*` cannot cross a brace, so a NESTED object never matches either.
    Driven over this release's own example artifact it returns `[]` — which is
    what "zero units" would have meant, indistinguishable from a malformed
    block, from an absent one, and from jq being missing. Every refusal here
    carries its own `error_key` and a non-zero exit; none reads as zero units.

  - **`workflow-manifest.sh hash-file <path>`** — the design binding's digest,
    over RAW BYTES, so `shasum -a 256 <file>` reproduces a recorded binding by
    hand. It **refuses before hashing** on a missing, unreadable or empty path.
    That ordering is the point: zero bytes digest to
    `e3b0c442…`, which `impact-report.test.sh` pins as the EMPTY CHANGE SET
    constant — 64 valid hex, stable across calls — so a binding taken over an
    absent artifact compares equal to itself forever and any "strip the hash and
    the binding must fail" test passes vacuously.

    This is a deliberate departure from the plan, which spelled it
    `impact-report.sh --hash-file` piping the file through
    `sed -e 's/\r$//' -e 's/[[:space:]]*$//'`. Both defects were measured and
    both are now negative controls in the spec: that spelling returns the
    empty-set constant at rc 0 for a missing artifact, and its normalisation
    collapses a Markdown **hard line break** (two trailing spaces) so
    `line one  \nline two` and `line one\nline two` hash identically — a real
    content edit made invisible to the hash that exists to detect it, in a
    Markdown artifact. `s/\r$//` is additionally redundant: POSIX
    `[[:space:]]` includes CR, measured byte-identical.

  - **`qa-gate.sh design-record <tid>`** — writes
    `DESIGN-ARTIFACT v1 task=… designer=… design_hash=… units=… at <ts>: …`,
    and is **layer 2 of the designer edit ban**. It refuses
    `artifact_path_not_derived` when `--file` names anything but the path
    derived from the task id, `artifact_outside_spec_dir` when what sits at that
    path does not resolve into `docs/specs/`, and `designer_touched_source` when
    the change set holds a path outside that directory while no `IMPLEMENTER`
    record exists on the task. The phase boundary is the implementer's SPAWN
    record, not its
    COMPLETION record — keying on completion would leave the check armed through
    the whole implementation window. The change set is the SESSION's rather than
    the designer's, so an audited `--accept-foreign-paths '<reason>'` records
    the reason in the record.

    **Both checks answer containment through ONE physical predicate** (QA round
    2, findings R2-F1 and R2-F2). They did not at first, and the two halves
    disagreeing is what the round found: the tracker scan reduced paths
    LEXICALLY, so `$PROJECT_DIR/docs/specs/../../src/pwn.sh` read as "inside the
    design directory" and `design-record` answered `recorded` with a source file
    in the change set — while the same path spelled plainly was refused. The
    `--file` check resolved only `dirname()`, so `docs/specs/<tid>.md` pointing
    at `../../outside/design.md` was accepted and the record bound the outside
    file's bytes, measured identical to `shasum -a 256` of it. One predicate now
    resolves `..`, intermediate symlinks and the LEAF, for the tracker, for
    `--file`, and for `approve`'s live re-hash; an unresolvable path is FOREIGN,
    which is the fail-closed direction the old comment claimed and the old code
    did not do. A nested `docs/specs/sub/x.md` is foreign too — the declaration
    scans one directory level, so the Stop-gate veto could not see a nested file
    either.

    **And the predicate resolves physically because it says `cd -P`** (QA round
    4, R4-F1 — the round-2 fix was incomplete and both reviewers found it, from
    different fixtures). Bare `cd` is bash LOGICAL mode: it collapses `..`
    LEXICALLY and only falls back to physical resolution when the reduced path
    fails to `chdir`. So a `..` FOLLOWING a directory symlink resolved against
    the spelling — `docs/specs/<dirlink>/..` reduced to `docs/specs`, which
    exists, so the fallback never ran — and `pwd -P` could not repair it,
    because it reports where the `cd` landed. Measured end to end at two of the
    three callers with one directory symlink as the only ingredient: the tracker
    answered `status=recorded` with a source path in the change set while the
    same file spelled plainly was refused, and `--file` bound an outside decoy's
    digest. The third caller, `approve`'s re-hash, was spared only because it
    re-hashes a DERIVED path and the derivation's `tr -c 'A-Za-z0-9._-'` cannot
    emit a slash; the code now says so where the sanitiser is, so widening that
    class cannot quietly open a third site.

    **Then round 5 named the CLASS the first four rounds had each been fixing
    one spelling of: a pathname round-tripped through a command substitution.**
    `$( )` strips every trailing newline and cannot tell a command's output
    terminator from a filename's last byte. The region held eleven of them — two
    `$(dirname …)`, four `$(basename …)`, one `$(readlink …)`, and five CALLER
    captures of the answer the predicate used to print. Three moves, in the order
    that matters. `--file` became an **assertion**: it may only name the path
    derived from the task id, so R2-F1, R2-F2, R4-F1, R5-F1 and R5-F2 stop
    *existing* rather than being filtered, and the predicate is left doing the
    one job that still has an attacker-supplied input — the tracker. The
    predicate now returns an **exit status** rather than a path, comparing both
    directories as `$PWD` inside one subshell, with `dirname` spelled in
    parameter expansion (`${p%/*}` plus dirname's trailing-slash rule, so
    `docs/specs/` still answers `docs`). And the one surviving substitution,
    `readlink`'s, is proven honest by `[ "$prev" -ef "$p" ]` — bash's
    device+inode comparison, FALSE for a target read back one byte short and TRUE
    for an honest link, relative or absolute or chained. That **closes** the
    newline residual this entry used to disclose, so the disclosure is gone
    rather than sitting beside the fix; one verdict changed with it, a dangling
    symlink inside the declared directory being foreign now. Every shape was
    driven end to end against the unfixed bytes first: each produced a
    `DESIGN-ARTIFACT` record, two of them binding an outside decoy's digest and
    one binding a second file in the directory named `<tid>.md` with a trailing
    newline. Net effect on the region: eight lines of code fewer, eleven path
    round-trips fewer, two functions fewer, one argument no longer an input.

    **The record's read window brackets containment, not only content** (QA
    round 3, R3-F4). The round-2 bracket hashed before and after validation, so
    replacing the leaf with a symlink to a byte-identical file outside the
    declared directory inside that window left both hashes agreeing and produced
    a record over bytes never shown to belong there. The closing bracket now
    re-runs the same containment predicate and compares it to the opening
    answer, refusing with the same `design_artifact_changed_during_record`. It
    does not make the window atomic — nothing check-then-use can — so one
    caveat, an A -> B -> A oscillation that restores the original state before
    the second read, now covers content and containment together instead of two
    caveats side by side.

    **The record binds the bytes the validator saw** (R2-F3). `validate-design`
    and `hash-file` are separate opens of one path — and the validator itself
    opens it a dozen times — so a writer landing in that window produced a record
    naming schema-invalid bytes, which a later `approve` then re-hashed and
    reported as `design binding VERIFIED`. Reproduced, then closed: the artifact
    is hashed before and after validation and the record is refused
    (`design_artifact_changed_during_record`) unless the two agree.

    **And round 6 found that ONE predicate was one too few, because the two
    callers ask different questions** (R6-F1). The round-5 collapse was right
    about the DIRECTORY and wrong about the LEAF: it gave both callers the
    record caller's answer. `design-record` and `approve` ask "are the BYTES
    here the declared artifact?", which must follow a leaf symlink — that is
    R2-F2 and it stays. The tracker scan asks "is this ENTRY the one file this
    design may touch?", and a tracker entry is
    **classified as an ENTRY, not as its target**: it names a location in the
    source tree, and where it points is a fact about a different file. Following
    it meant a source-tree symlink `src/runtime` aimed at `docs/specs/<tid>.md`
    disappeared from the foreign set — and, needing no symlink and no filesystem
    precondition at all, that another task's `docs/specs/<other-tid>.md` and a
    plain `docs/specs/notes.txt` read as CONTAINED, so a designer holding only
    `Write` could clobber another task's design and still record. All three
    measured. The fix keeps ONE physical directory comparison shared
    by both callers — so there is still no second notion of "inside" to drift,
    which is what round 2 was about — and splits only the leaf: the tracker
    compares the entry's last component with the derived filename using
    `${p##*/}`, never `basename`. `designer_touched_source` now means "not this
    task's one design artifact" rather than "outside `docs/specs/`", and the
    message, `designer.md` and the usage block say so.

  - **Layer 1 is `designer.md`'s tools list, which now omits `Bash` and
    `Edit`** — two tokens; `MultiEdit` and `Task` were never granted. It is
    **not airtight and is not claimed to be**: `Write` is retained because the
    artifact is the designer's only deliverable, and `Write` overwrites any path
    in the tree. Layer 1 closes the shell vector and the patch vector; layer 2 is
    what makes writing anything else consequential. `prevent-orchestrator-edits.sh`
    is deliberately untouched — `LESSONS.md` records the P0 from fail-closing it
    on an identity the runtime does not surface to PreToolUse.

  - **The approval record gains `design_hash=<h>` as a FOURTH MACHINE TOKEN**,
    after `worktree=` and immediately before ` at <ts>`, not as a bracketed
    suffix. Two reasons, both load-bearing. The token-order contract constrains
    ORDER, not COUNT, and every existing reader is an anchored capture an
    appended `key=value` cannot disturb. And the suffix space is self-asserted:
    `$summary` is built from unvalidated positionals and interpolated on the same
    line, while both readers of the existing markers `grep -qF '[review bypass:'`
    over the whole comment — so a value the gate must TRUST cannot live there.
    (That pre-existing exposure is filed separately as
    `claude-workflow-plugin-yrij`.) The binding runs a four-arm ladder in the
    manner of `grade-record`'s: bind only when a live re-hash of the artifact
    agrees with the recorded one; otherwise write NO token and NAME the reason —
    the design moved, the artifact is unhashable, or there is no record. A
    one-byte post-approval edit to the design therefore un-binds the next
    approval exactly as a post-approval code edit moves `change_set_hash`.

  - **The designer's prompt body ships.** It carries the artifact's required
    sections and unit contract, the controlling standard ("an implementer must
    be able to build each unit without guessing"), escalation as a *declared*
    pin change rather than a claim that a unit ran on a model, `impact_of` as a
    required pass, and a handoff block — the designer has no shell, so it cannot
    record its own artifact and hands the command back instead of pretending to
    run it. It is also told, explicitly, that it receives no hook-injected
    context: `subagent-start.sh`'s injection is implementer-roles-only.

- **Model role classes expand from three to five** (`fkm.2`, v5.0.0 Phase D0).
  `designer` and `design_reviewer` join `orchestrator`, `implementer` and
  `reviewer`. Two new agents ship with their frontmatter and manifest
  registration — `.claude/agents/designer.md` and
  `.claude/agents/design-reviewer.md` — with the prompt bodies deliberately
  left to Phases D1 and D2. They are created and registered in the same change
  because an agent file that exists on disk and is absent from
  `.claude-plugin/plugin.json` is silently invisible to the SDK: no error
  surfaces anywhere.

  - **The role set is now defined once.** `ALL_ROLES` in `model-select.sh` and
    `CONCRETE_ROLES` in `workflow-model-apply.sh` are the only enumerations;
    `status`, `roles`, `apply` and the drift check all iterate them, and a test
    asserts the two agree. `cmd_apply` replaced nine flat variables with a
    `role\tstrategy\tpick\tfallback` scratch file built by one loop and consumed
    by one `jq` pass (bash 3.2 is the floor — no associative arrays).

  - **`current_pin()` gained an explicit arm per role, and its catch-all now
    warns.** This was the sharp edge of the expansion: the previous last arm was
    `orchestrator|*)`, a silent catch-all, so a role with no arm read
    `orchestrator.md`'s pin. `_apply_role` then compared the new lane's desired
    model against the *orchestrator's* current one, found them equal, and
    skipped the rewrite — no error, no warning, exit 0. Both design lanes would
    have reported as pinned and never been written. Guarded by a META that
    strips the `designer)` arm and asserts the lane goes unwritten while the
    resolver still exits 0.

  - **A lane whose representative agent file is absent is now skipped
    entirely** — no rewrite, no switch count, no meta-task audit comment.
    `current_pin` returns empty for a missing file, so `"" != "$desired"` held
    on every run: the lane "switched" forever, was counted forever, and wrote a
    `MODEL SWITCH [<role>] <none> -> <id>` audit comment forever, for a file
    that does not exist. D0 made it reachable (`designer.md` /
    `design-reviewer.md` legitimately do not exist on a v4 install being
    upgraded); it was latent before that for any of the five. Found by the
    component tier's `ms-G` assertion, which reported `(2 switched)` for an
    apply where every existing pin already matched.

  - **Strategy grammar generalised** from the `opus-class` literal to
    `^[a-z][a-z0-9]*-class$`, so `sonnet-class`, `fable-class`, `haiku-class`
    and any future family parse from one rule. Selection is deliberately NOT
    gated on the family appearing in `.claude/model-ranking` — gating would kill
    day-zero adoption of a new family — so a misspelt family instead earns a
    "not a known tier — check for a typo" hint on the fallback warning.

  - **Per-unit implementer escalation.** `model-select.sh escalate <task-id>`
    resolves the new `implementer_class_high` strategy through the same
    resolution path as the lanes, records the previous pin atomically **before**
    repinning, and `restore` reverses it. Both are idempotent, and three restore
    paths mean a crash self-heals: `session-end.sh` best-effort, the next
    SessionStart `apply`, and an explicit `restore`. Deliberately **not** wired
    into `qa-gate.sh` — the gate stays free of model concerns.

    `_apply_role`'s exit status is an **interface, not a boolean**: `0` switched,
    `1` no-op, `2` no agent file, `3` the rewrite helper failed. It returned `1`
    for the last three alike, so both `escalate` and `restore` answered a
    failure with "already at `<id>` (no rewrite needed)" one line after the
    helper reported it — and `restore` then deleted the escalation record, the
    one artifact that made the lane restorable. The record is now dropped only
    when the lane is provably back (rc 0 or 1); a failure keeps it, and
    `session-end.sh`'s next best-effort `restore` clears it once the pin
    returns. Separately, `previous_pin` is the **pre-escalation** pin: escalating
    a second task while one was live overwrote it with the escalated id, which
    made every later `restore` a no-op. A live record's `previous_pin` is now
    carried forward and the displaced task id is kept under `supersedes`.
    D0 ships no caller for either path — D4/D5's parallel unit batches over one
    implementer lane are where a second escalation actually arrives.

    Escalation is a **declared, audited, reversible pin change and nothing
    more.** Whether the Claude Code runtime honours a mid-session frontmatter
    `model:` change is not established anywhere in this tree and is not
    verifiable offline, so no test, doc or line here claims an escalated unit
    *ran* on the escalated model.

  - **Resolved-artifact schema 2**: five `roles`, five `strategies`, five
    `fallbacks`, both lane keys, `escalation:{strategy,resolved}`,
    `identity_collapse`, and `missing_keys`. The top-level
    `implementer_fallback` boolean is retained because existing readers assert
    on it. Escalation stays out of `roles` — it owns no agent files, and a
    `roles[]` entry would make the role-map parity check look for one.

  - **Identity collapse is reported, never blocked.** When `designer` and
    `design_reviewer` resolve to the same model *and* the design lane is
    `claude`, the resolver warns, writes
    `.claude/.qa-tracking/design-family-collapse`, sets `identity_collapse` in
    the artifact and lights `!id` on the statusline — then writes every pin and
    exits 0. Blocking would make the Codex-absent arm unrunnable. On a stock
    install without Codex the flag is permanently lit. **Only ONE of the two
    clearances documented in the `.claude/model-roles` header actually works:
    giving `design_reviewer` a distinct family-class.** Installing Codex clears
    the flag without changing which model reviews the design, because no script
    drives design review through Codex — see `claude-workflow-plugin-yvpe` and
    the identity-collapse entry below.

  - **Session-model guard.** The root session is the orchestrator seat, and the
    live session model is observable ONLY in the statusline's stdin envelope —
    `session-start.sh` never reads stdin. So `statusline.sh` now reads that
    envelope rather than draining it, compares `.model.id` against the resolved
    orchestrator id, and persists the result read-compare-write (it runs on
    every render). SessionStart Warning 8 re-validates the record against the
    current artifact and prints the fix verbatim. Never blocks.

    The comparison is by **model identity, not id string**. As literal equality
    it made `claude-fable-5[1m]` — the 1M-context variant of the *correct*
    model — read as drift forever, with a fix line telling the operator to move
    to a smaller context window; this repo's own drift record carried that
    shape. A trailing bracketed context-window marker is now separated from the
    base id, and the rule is deliberately **asymmetric**: when the resolver
    named no variant, any variant of that model matches; when it named one
    (`pick_best` sorts `_ctx` DESC, so a resolved `[1m]` is a deliberate pick),
    a session that is not on it is still drift and the fix line names the
    variant. Stripping both sides would have deleted that true positive to fix
    the false one.

  - **SessionStart Warnings 8, 9 and 10 are covered by tests.** They shipped
    with none — 63 lines of operator-facing notices with no assertion in any
    tier (QA finding R1-F1). `model-roles.test.sh` section 10 now drives the
    real hook in a hermetic sandbox and parses the envelope it emits: one
    positive over state produced by the shipped resolver and the shipped
    statusline, three negatives (a stale drift record, a config with nothing to
    report, no artifact at all), and three METAs that disable one notice each
    and prove the other two still fire. Warning 10 is the only surface that
    makes correction 14 visible, and its regression mode is silence — the same
    silence it exists to break.

  - **Statusline renders five roles** by grouping equal values with `+` in the
    fixed order `des dsr orch impl rev`, three groups then ` +<k> more`. It
    iterates the roles PRESENT in the artifact, so a leftover three-role v4
    artifact still renders with no upgrade step.

- **The design phase gets a starting precondition: a grilling record**
  (`fkm.5`, v5.0.0 Phase D3). `qa-gate.sh design-record` now refuses
  (`grilling_record_missing`) unless a `GRILLING v1` record exists on the
  task or its parent epic.

  - **`qa-gate.sh grilling-record <task-id> --rounds <n> --questions <n>
    --approaches <n> --unresolved <n> ['<summary>']`** — written by the
    orchestrator, at root (it ran the dialogue; the designer's own tool list
    omits `Bash`, so it structurally cannot invoke this). `--approaches`
    must be at least 2 (`insufficient_approaches` otherwise) — the vendored
    brainstorming method's own bar. Appends:
    `GRILLING v1 rounds=<n> questions=<n> approaches=<n> unresolved=<n>
    vendor_hash=<h> at <ts>: <summary>`. `vendor_hash` is not a flag: it is a
    live `workflow-manifest.sh hash-file` recompute over the vendored
    `brainstorming/SKILL.md`, so the record names which method text was in
    force — later drift in the vendored file cannot retroactively validate a
    dialogue that never followed it.

  - **The precondition is mechanical, inside `design-record`, not at Stop** —
    the same reasoning the v4.1 closure gives for the brainstorming ceremony
    generally: a Stop-time change-set classifier fires after the work it
    would gate. `--no-grilling '<reason>'` is the audited bypass, for the F1
    doc-only class and the single-line-typo path.

  - **The precondition reader requires the FULL record grammar, not a bare
    prefix** (QA R1-F1). The first version checked only `startswith("GRILLING
    v1 ")`, which a hand-posted comment with none of the real fields
    satisfied — a lower forgery bar than every sibling reader in this file.
    The reader now requires the anchored shape the one real writer always
    produces (four `[0-9]+` counters and a 64-hex `vendor_hash=`), closing
    that gap without narrowing what a legitimate `grilling-record` call
    produces.

  - **`.claude/vendor/superpowers/MANIFEST.md` gains a recorded content
    hash** of `brainstorming/SKILL.md`, asserted against a live recompute by
    `vendored-skills.test.sh` (94 -> 100 assertions) — a drift detector for
    the MANIFEST's own claim, separate from the ten surgical modifications'
    bans.

### Changed

- **`docs/specs/*.md` is now a GOVERNING ARTIFACT, so a design document no
  longer takes the F1 doc-only fast path** (`fkm.3`, closing the residual
  `s5qf` disclosed and two shipped tests pinned). Before this, a change set
  consisting of exactly the design auto-approved with `reviewed_by=none` — the
  one deliverable the design phase exists to review taking the ungated exit.
  It is declared in `runtime_contract_rows` beside `CLAUDE.md`, with origin
  `design-artifact`, so it is still outside `generate_rows`: no install row, no
  upgrade verdict, no uninstall walk, and `generate`'s output is byte-unchanged.
  The one difference from `CLAUDE.md` is stated plainly in the code: that is a
  named file and this is a **declared directory**, because the artifact is named
  for the task it designs. It remains a declaration rather than the path-shape
  inference `bbh` removed — the row exists because the workflow writes its design
  artifact there, not because the name ends in `.md` or sits under `docs/`. An
  operator's own `docs/` is untouched, and an anti-overreach leg pins that a
  sibling directory under `docs/` still fast-paths. The two deliberate tripwires
  (`doc-only-classifier.test.sh` 6c, `workflow-manifest.test.sh`) flip in this
  same commit, as their headers asked.

  **The declared directory is scanned for ENTRIES, not for regular files** (QA
  round 2, R2-F2). `scan_flat`'s `find -maxdepth 1 -type f` excludes symlinks,
  so a symlinked `docs/specs/<task-id>.md` produced no governing row at all and
  the fast path reopened for the very artifact this declaration closes. The
  declaration now has its own scanner, which declares symlinks — dangling ones
  included, on the same reasoning the deletion residual states, and it dies
  rather than emit a digest-less row if a future caller ever turns hashing on.
  `scan_flat` is deliberately unchanged: it builds the surface frozen per
  release under `manifests/`, and `install.sh` copies files rather than links.
  Asserted from both sides — a symlink in the declared directory is governing, a
  symlink in `.claude/agents/` leaves `generate` byte-identical. This does not
  reach a DELETED declared path, which stays out of every enumeration and is
  tracked as `claude-workflow-plugin-mdnc`.

  **The declared DIRECTORY defeated that scanner in two more ways, and both are
  closed** (QA round 4, R4-F3 and R4-F2 — independently reported by both
  reviewers). If `docs/specs` is itself a directory symlink, `find` will not
  descend a final symlink operand without `-H`/`-L` — identical on BSD find and
  GNU findutils 4.10.0 — while the `[ -d ]` guard above it does follow, so the
  guard passed and the scan came back silently empty: `ls docs/specs/` listed
  the artifact and `governing` emitted no row for it. The scan now passes `-H`,
  which follows command-line operands only, so entries *inside* the directory
  are still reported as themselves. And a directory that is searchable but not
  listable (mode `0311`) used to yield zero rows **at rc 0**, because find's
  diagnostic went to `/dev/null` and its exit status was lost to process
  substitution — a check failing open and silently. That falsified an invariant
  its own consumer documents: `load_governing_set` captures this query's rc
  precisely because "an empty set from a FAILED run is not [legitimate]". The
  enumeration is now read from a file whose status can be checked, and a failed
  one dies with find's own diagnostic quoted in the message. What the consumer
  then does is unchanged — it logs and classifies as it did before the
  declaration existed, which is `s5qf`'s deliberate fail-open on an
  *unanswerable* query. The defect was that the query had been ANSWERING.

- **`orchestrator.md`'s Spec-location clause is narrowed rather than deleted.**
  Per-task implementation SPECs still go on the Beads task via `bd_doc_write`
  per section 4a and still never into an ad-hoc file under `docs/`; the one
  exception named is the design artifact, which is a gate input with a schema
  and a digest. The clause count, the four wiring sentinels and the
  exactly-once appearance of the count sentence are all unchanged.

- **`CLAUDE.md` said "five agent prompts"; the tree has nine.** Corrected. It
  matters more than the other stale censuses because `CLAUDE.md` is the sole
  `runtime_contract_rows` entry and is auto-loaded into every agent's context —
  including the designer's, which would otherwise decompose against a system
  that stopped existing at D0. (`README.md` and `HANDOFF.md` carry the same
  class of stale count and are tracked separately as
  `claude-workflow-plugin-l1wk`.)

- **The v5 plan is mirrored into the repo** (`claude-workflow-plugin-omiv`).
  `docs/plans/v5-design-phase.md` was the operator's DIRECTIVE plus a
  fourteen-line summary of the corrections; the plan it was turned into — which
  exists because the directive is wrong in fourteen enumerated ways, and which
  carries the per-phase detail established from source — had never been
  mirrored. Briefs have cited sections by name that do not exist in the file
  they point at, and one such reader produced a false "the plan contradicts
  itself" finding by comparing directive text against a correction written to
  overrule it. Both files are now indexed in `docs/plans/README.md`, each says
  which one governs, and the "Adding a new plan" recipe gained the step whose
  absence caused it. Neither is scanned by `workflow-manifest.sh`, so neither
  becomes an install row.


- **`implementer` moves from `opus-class` to `sonnet-class`** (`fkm.2`). A
  deliberate quality-for-cost trade that the reviewed design artifact and the
  green-to-green per-unit tests are meant to absorb, with per-unit escalation as
  the safety valve. **Note the sequencing: this lands in D0 while that safety
  machinery lands in D1-D5.** Track grader rounds per implementation task before
  and after; the revert is one line in `.claude/model-roles`.

- **`orchestrator` and `reviewer` shipped D0 on `top`, which was NOT what the
  plan's D0 table specified — both rows have since LANDED at the plan's own
  tier** (`fkm.2`; tracked and closed on `fkm.10`; QA finding R1-F3). The plan
  asks for latest Opus-class on `orchestrator`, and Sol-via-Codex with a latest
  Opus-class fallback on `reviewer`. D0 shipped the Sol half of `reviewer` but
  left both tiers on `top` (Fable today) — correction 7 licenses `top` for the
  DESIGN lanes only, and the reason does not transfer: there `top` IS the
  Fable class the plan named, whereas Opus is not the top family, so `top` on
  these two lanes was a *higher* tier than specified, not the same one.
  **`reviewer` landed first** (2026-09-07): `top` -> `opus-class`, because the
  deferral rationale never actually applied to it — the operator's standing
  instruction is that QA and review run on Sol in priority to Opus and NEVER
  on Fable (a weekly-limit constraint), so `top` resolving to Fable was a live,
  silent policy violation on every reviewer spawn, not a deliberate capability
  trade being protected. **`orchestrator` landed second** (2026-09-18, `fkm.9`
  / D7): `top` -> `opus-class`, for two independent reasons — the plan's own
  D0 table specifies `latest Opus-class` on its own terms, and the original
  deferral reason (the orchestrator seat still doing design-shaped judgment,
  because D0 shipped no working designer) no longer holds now that D1
  (`designer`) and D2 (`design_reviewer`, the review loop) have shipped; and,
  as an *extension* of the same weekly-limit reasoning rather than the
  operator instruction's literal text, the orchestrator is spawned on
  essentially every non-trivial turn — far more often than any reviewer — so
  it was the seat burning the protected weekly Fable budget hardest of the
  two still on `top`. Both landings are recorded with full rationale in
  `.claude/model-roles`'s own header (rewritten from "DECLARED DEVIATION" to
  "DEVIATION LANDED" describing both rows), and `fkm.10` is closed. The design
  lanes (`designer`, `design_reviewer`) remain `top` — that was never a
  deviation to begin with, per correction 7 above.

- **Eight files stopped hardcoding agent/role lists** (`fkm.2`). The unit is a
  FILE that no longer enumerates agents or roles, which is what the list below
  can be counted against; two of the eight carried two enumerations apiece
  (`workflow-model-apply.sh`, `model-roles.test.sh`), so the site count is ten.
  The files:
  `workflow-model-apply.sh`'s `all` role and its missing-file skip (which
  name-tested `grader`/`judge` and would have printed a scary line for every
  agent shipped afterwards), `model-select.sh`'s intra-role drift check,
  `no-nested-spawn-instructions.test.sh`'s agent list,
  `model-roles.test.sh`'s role and agent sets, the seven-agent loops in
  `specs/model-select.sh` and `specs/model-roles-parity.sh`,
  `specs/installer-mcp-config.sh`'s per-release agent presence assertions, and
  `installer-flags.test.sh`'s synthetic source. Each conversion ships a
  non-vacuity leg, because "every agent matched" is trivially true over an empty
  set — which is the one failure a discovery conversion can introduce silently.

  `specs/model-select.sh`'s ms-R4 snapshot also moved off
  `eval PRE_R4_<agent>=`: `design-reviewer` is not a legal bash variable name,
  so that form would have failed at exactly the moment discovery made it
  reachable.

- **The test runners stop scoring absence as green** (`a9hh`, `mwrb`). Both
  tier runners (`.claude/scripts/tests/run-tests.sh`,
  `.claude/tests/component/run.sh`) previously scored specs by exit status
  alone, so a spec that exited 0 having executed zero assertions was counted
  PASSED — measured in CI shape as 286 of 2461 L1 assertions (11.6% of the
  tier, `review-separation.test.sh`'s 60 included) never executing under a
  summary line byte-identical to a full run. A skip is now a THIRD OUTCOME
  that is never a pass; the L1 tier enforces a completeness floor
  (`EXPECTED_SPECS`) that fails the run when the discovered set shrinks —
  framed in-file as the negative control for the completeness line, the
  pairing convention's first application; and both runners kill a hung spec
  at a per-spec wall-clock cap (`SPEC_TIMEOUT_S`; L1 900s, L2 3600s),
  reporting it FAILED with a distinct TIMEOUT reason — never passed, never
  skipped — with per-spec elapsed time printed (a hung tier emits no
  completeness line at all, measured three times as 45+ minute losses). The
  CI `l1-unit` job now installs the real `bd` (pinned v1.1.2,
  checksum-verified release tarball, into `/usr/local/bin` — not `/usr/bin`,
  which `installer-flags.test.sh` probes as a prereq-hostile PATH) plus BOTH
  MCP servers' deps, and the L1 skip arms are deleted. Precisely: five
  whole-file `BD_SHIM_ONLY` arms (`bd-github-link`, `qa-gate-choose`,
  `qa-gate-grade-record`, `review-separation`, `phase5-synthetic-tests`) and
  one section-level `BD_SHIM_ONLY` note arm
  (`mcp-unestablished-results.test.sh:489`);
  `mcp-unestablished-results.test.sh` KEEPS its whole-file
  node/`node_modules` arm, which is correct — it names a prerequisite, is now
  classified SKIPPED, and fails the tier, so CI installs the prerequisite
  instead of arguing with the arm. A bd-less environment is a loud failure
  everywhere, not a silent green. `l2-component` keeps `BD_SHIM_ONLY=1` for
  now — its summary now says honestly that 37 of 44 specs skip there;
  installing bd + a floor in that job is the recorded follow-up.
- **…and the L1 runner stops scoring a skipped SECTION as coverage**
  (`a9hh` R1-F1). The floor above counts spec FILES, and the first fix round
  for `a9hh` shipped its own false green on exactly that gap: the rewired
  `l1-unit` job printed `Total: 36  Passed: 36  Failed: 0  Skipped: 0` and
  `Completeness floor: HELD (36/36 specs discovered and executed)`, rc=0,
  over 15 assertions that never ran — `impact-report.test.sh` executed 24 of
  39 and printed `SKIPPED: section 4 (code-graph-mcp not installed …)`
  because the job installed bd-mcp's `node_modules` and not
  code-graph-mcp's. Section 4 is the LIVE code-graph path (`server=code-graph`,
  exit-0-despite-one-per-file-error, the non-git relativisation fallback) —
  the live half of the artifact `qa-gate.sh approve` refuses to run without.
  Three changes close it: the job runs a second `npm ci` in
  `.claude/mcp/code-graph-mcp` (94 packages, no install scripts, no native
  builds) and verifies both `node_modules` before the suite; the runner
  recognises the four section-skip marker shapes the tier prints, counts them
  as `Partial: N`, names each with its own marker text, prints
  `Assertions executed: N` (the number that moves when a section is lost —
  2501 vs 2486 across the same 36 specs), and qualifies the completeness line
  itself; and `STRICT_SECTIONS=1`, set on `l1-unit` where every prerequisite
  is provisioned, makes a skipped section RED. It is unset by default because
  a dev machine legitimately lacks prerequisites and a control that cries
  wolf stops being read; an unrecognised value is an invocation error, never
  a silent "off". Both runners also now launch specs as background jobs (the
  watchdog needs to poll them) with stdin explicitly redirected from
  `/dev/null` — the redirect must be explicit because `set -m` inverts the
  async default (see the R3 entry below); no spec read stdin before or
  after, but it is a real semantic change.
  Paired by `runner-completeness.test.sh` (40 → 83 assertions), which
  drives both shipped runners and TWO mutants of the L1 one — un-floored, and
  with the section refusal excised — against shrunken, skipping,
  section-skipping and deliberately hanging fixtures, with the orphan probes
  scoped per run and a decoy process proving the scoping is real.
  The sweep this finding demanded turned up a second instance nobody had
  named: `workflow-doctor.test.sh`'s META-TEST 3, 4 and 5 printed
  `note: META-TEST N needs <prerequisite>` with the word "Skipping" on a
  LATER line, so three section-level skips were invisible to any line-anchored
  detector. They now carry the word on the marker line, and section 9 of
  `runner-completeness.test.sh` scans every spec's `note:` literals and fails
  on one that does not — with a control proving the scan can fail, and an
  end-to-end leg showing the runner really is blind to the old shape.
- **…and both runners stop trusting a spec's exit as the end of its story**
  (`a9hh` R2, three HIGH findings from a second model family — Sol,
  gpt-5.6-sol — each reproduced as a failing invocation before any fix).
  R2-F1: the section-skip detector demanded a skip word ON the `note:` line
  and its convention scan read only quoted printf/echo literals, so the
  known-bad two-line shape emitted through a heredoc evaded both layers at
  once — `STRICT_SECTIONS=1` reported `Partial: 0`, rc=0, over an omitted
  section (the class the round existed to close, surviving its three fixed
  instances). Detection now keys on the spec's OUTPUT, where every emission
  mechanism converges: ANY line-initial `note:` counts (checked against both
  tiers: nothing else prints one; a future informational `note:` fails loud
  as PARTIAL in strict CI, the safe direction), and the source scan reads
  heredoc bodies too, kept as the human-legibility lint plus dormant-arm
  audit it always was. R2-F2: the runner waited only on the spec's top-level
  pid, so a spec could background a subshell and exit 0 — reproduced:
  `Passed: 36 … Partial: 0`, rc=0, the child alive after the tier returned,
  its `SKIPPED:` marker written into the already-unlinked output file
  (outcome and evidence both lost). Specs now run as their own process
  groups (`set -m`); after `wait`, a survivor sweep polls the group (short
  grace, so in-flight output lands and COUNTS), kills what remains, and
  classifies the spec FAILED with a reap-your-own-work reason — a spec that
  backgrounds and reaps stays a clean PASS, and bd's double-forking daemon
  (own session, ppid 1, measured) never enters the group. R2-F3: the
  watchdog's `kill_tree` sent TERM to descendants and its KILL only to the
  (usually already dead) top-level pid, so a `trap '' TERM` child survived
  the cap and outlived the whole run — reproduced on both runners, and the
  paired control could never have caught it because its blocking child was
  a `sleep`, which honors TERM: a negative control structurally incapable
  of failing, inside the batch that exists to eliminate exactly that. The
  escalation is now group-wide (`kill -KILL -- -pgid`), the ppid walk stays
  as the polite first pass, and an INT/TERM trap forwards interrupts to the
  active spec group (own-group specs no longer die with the terminal's ^C).
  `runner-completeness.test.sh` grows 83 → 117 assertions: TERM-immune child
  AND TERM-immune leader legs against both shipped runners (the blocking
  child now actually ignores TERM), background-and-exit legs, TWO new
  sweep-excision mutants (L1 + L2, awk-verified) demonstrating the exact
  green-over-leak line on demand, a backgrounds-but-reaps restore control,
  and heredoc-emission controls for the scan — with the pre-R2 literal-only
  scan kept on display as a leg proving it finds 0 hits on the heredoc
  fixture. Every new leg names, in-file, the mutation that turns it red;
  the three mutations were each run by hand and observed to redden their leg
  (narrowed regex → 9.5; sweep excised → 5.8/5.13; watchdog escalation
  deleted → runner blocked 20s past a 3s cap → 5.10 via the outer cap).
- **…and the sweep stops crying wolf on bd's telemetry, and the runners stop
  claiming stdin semantics `set -m` inverts** (`a9hh` R3, QA re-review; both
  HIGH findings reproduced against the shipped runners before any edit).
  R3-F1: `bd send-metrics` — spawned by ANY bd command while metrics are
  enabled — detaches to ppid=1 WITHOUT `setsid`, so unlike the daemon the
  R2 header generalised from it stays IN the spec's process group; a fresh
  fixture HOME re-enables metrics (no `~/.config/bd` defaults to ON,
  measured on bd 1.1.2, the version CI pins), and a slow endpoint carries
  the flusher past the sweep's 2.0s grace, SIGKILLing an innocent spec.
  Reproduced through the shipped runner: 0/25 firings idle, 10/10 with the
  endpoint blackholed — the CI-latency shape (QA: 4/25 under load; 61/61
  census flushers in-group, 0/61 setsid, max lifetime 3s). Both runners now
  export `BD_DISABLE_METRICS=1`, which prevents the SPAWN itself (measured:
  3/3 in-group flushers without it, 0/3 with). An argv-pattern sweep
  exemption was rejected as forgeable (`exec -a 'bd send-metrics'` would
  cloak a real leak), and a ppid==1 exclusion as suicidal (an escaped child
  reparents to 1 the instant its spec dies — that predicate deletes R2-F2's
  own detection). The sweep now NAMES every survivor it kills
  (pid/ppid/pgid/args under the verdict line — QA needed an instrumented
  copy to identify the flusher; the next person reads it off the failure),
  and the failure text demands what a spec CAN do ("end its background work
  before returning" — "reap" is impossible for a ppid=1 non-child). R3-F2:
  both runners' new STDIN paragraphs promised the POSIX async
  `/dev/null` default while `set -m` INVERTS it — with job control on, a
  background job inherits the runner's stdin. Reproduced both ways: a
  reader spec consumed a sentinel piped into the shipped runner, and under
  a pty it was SIGTTIN-stopped (state T at 8/8 samples; `kill -0` reads
  stopped as alive) into a full-cap TIMEOUT — the mwrb wedge, in text that
  promised instant EOF. Both launch sites now redirect `< /dev/null`
  explicitly, and the paragraphs state the measured behaviour. Also: the
  README's mutant census said "two mutants" over a change set that shipped
  four (R3-F3 — corrected, now the enumerated eight), and the `note:`
  predicate's zero-false-positive claim lived in a comment rather than a
  leg (R3-F4) — it is now a dated measurement carrying its command in the
  header, plus output-layer legs pinning both directions: the tier's real
  near-miss shapes (`Note also:`, `(note:`, `footnote:`) stay invisible,
  and a line-initial `Note: switching` arriving through a subprocess is a
  LOUD, verbatim-quoted PARTIAL, never a silent green.
  `runner-completeness.test.sh` grows 117 → 149: telemetry-disarm pairs
  (the env probe driven with the variable `env -u`-stripped at the call
  site, so it proves the RUNNER establishes it, not the ambient
  environment), real-bd verification (a fresh HOME reports OFF with the
  variable and ON without — a bd that renames it goes red HERE, not as a
  1-in-6 CI flake), stdin sentinel pairs against both runners, and FOUR new
  excision/strip mutants (awk found-checked, cmp-verified, demonstrated red
  in-run); the two hand mutations for the new 8.21 legs (de-anchored
  `note:` predicate, re-narrowed predicate) were each run and observed to
  redden exactly their leg.
- **…and the runners stop deleting their own scratch mid-tier on Linux,
  converting failures into skips, swallowing background failures, blessing
  empty filters, and stranding descendants on interrupt** (`a9hh` R4/R5 —
  two independent parallel reviews on the same bytes: Sol, gpt-5.6-sol,
  4 HIGH by inspection; QA, 1 HIGH + 2 MEDIUM by measurement; every finding
  reproduced against the shipped runners before any edit). R5-F1, the
  blocker: both runners' EXIT trap (`cleanup_scratch`) nondeterministically
  fired **inside forked children** on Linux bash 5.2.21 under load and
  `rm -rf`'d the live scratch MID-TIER — every later spec failed rc=1 with
  0 assertions (`cat: …/spec-out.N: No such file`), one spec went SKIPPED
  over its unlinked output. Reproduced in ubuntu:24.04 against 36 trivial
  stubs: 32/40 runs bad under CPU contention (`--cpus=1` + 2 spinners),
  1/12 from a bind mount, 0/30 idle (QA: up to 10/12 bind-mounted, 6/20 at
  L2 — our L2 pre-fix control measured 40/40 under contention); not
  reproducible on macOS bash 3.2. The trap-body interactions were then
  MEASURED AS A FACTORIAL rather than modelled — 40 trials per variant, 36
  trivial stubs, ubuntu:24.04 bash 5.2.21 aarch64, `docker run --cpus=1 -e
  LOAD=2` — by THREE independent builds: QA (R5/R7), ours (R4/R5, re-run
  and extended R6/R7), and a third at R9. R7 falsified this entry's first
  account and R9 refined the correction. What follows is what those three
  builds OBSERVED, stated as ranges across builds and NOT as bounds: the
  spread at n=40 is wide enough that a 5-point gap between builds is noise
  (28/40 against 33/40 is z≈1.35), so a range is the honest form and a
  superlative is not. Variants are named by the ORDER of their statements,
  because "guard + write + rm" cannot distinguish 28/40 from 0/40 — a whole
  review round was spent reconciling that ambiguous label against an
  unambiguous table — and run-tests.sh carries each body VERBATIM. A bare
  `rm` in the trap: 29-35/40 BAD. A BASHPID guard evaluated as the trap's
  FIRST command (guard→rm, and guard→write→rm): 25-37/40 BAD — the
  misfiring child gets past the guard and deletes. This entry called that
  "the WORST shape measured"; the R9 build does not reproduce that ordering
  (its guard shapes read 28 and 28, against 30 for the bare rm), so the
  superlative is WITHDRAWN. What IS supported is that guard-first is no
  better than the bare rm, which is the load-bearing point; which shape is
  worst is not established. An in-trap WRITE never masks the defect:
  write→rm with no guard stays at baseline, 27-32/40 BAD, while the write
  LOGS every foreign firing — the defect is instrumentable. QA's rm→log
  control read 0/40-0/60 because removing the rm removes the deleter, so
  their "the deleter IS the rm" inference was CORRECT (this entry
  previously miscalled it a probe effect, over what were two GUARD fallback
  shapes, not "two logging variants"). The one armed-trap shape every build
  reads clean is write→guard→rm — the byte-identical write placed BEFORE
  the guard: 0/40 + 0/40 + 0/25+0/25, with 109 and 48 foreign firings
  observed entering the trap and every one stopped by the
  now-correctly-evaluating guard. The masking is therefore ORDER-dependent,
  not combination-dependent: the two builds that isolated the order read
  35/40 and 28/40 BAD with the guard first against 0/40 with the write
  first, and in the R9 build 146 logged firings recorded `BASHPID != $$` in
  the instant before running the `rm`. Why first-command evaluation differs
  inside a misfiring child is still unexplained. strace also masks (0/30). No in-trap shape is
  trustworthy; the fix is structural, not a guard: NO EXIT trap at all —
  cleanup moved to explicit terminal exits (`finish`), leaving nothing in
  trap-space for a misfiring child to execute. Verified on the fixed bytes
  in the identical amplified container: L1 0/40 + 0/12 mount, L2 0/40;
  re-verified at R6/R7 — 0/12 on the reviewed bytes, then 0/40 sha-pinned
  on the final R6/R7 bytes (pre-fix controls in the same harness: 32/40,
  1/12, 40/40). R4-F1: an L2 spec's
  failing assertion followed by a skip gate's `exit 0`
  (`bd_required_or_skip`'s exact mechanism, reachable today via
  `post-edit.sh` under `BD_SHIM_ONLY=1`) was classified SKIPPED with
  `Failed: 0`, rc=0 — the wrapper died before its summary line. The wrapper
  now owns an EXIT trap that prints the summary on ANY builtin exit
  (fixture.sh's install-once guard is pre-set so trap ownership is not
  contested; `beads-ledger.sh`, the one spec that re-arms EXIT, chains
  `__spec_wrapper_exit`; the runner's missing-summary FAILURE is the
  guarantee, and a lint leg cheaply catches the static shapes — widened at
  R7-F4 to multi-signal/numeric-0/trailing-comment forms, with a
  variable-spelled signal named as the residual only runtime can catch),
  and the
  classifier grew three arms: summary-counted failures under rc=0 are
  FAILED, transcript `FAIL:` lines the summary never counted are FAILED,
  and a missing summary line under rc=0 is FAILED — never SKIPPED. A spec
  that measures N assertions and THEN skips is PASSED with its count
  (pre-fix: SKIPPED, assertions vanished). R4-F2: both runners scored
  rc=0 as PASSED over transcripts containing `FAIL:` lines — a
  backgrounded assertion failing inside the sweep's 2s grace window landed
  its FAIL: in the still-linked capture file, was COUNTED as an executed
  assertion, and passed (reproduced both tiers). New transcript arm in
  both: rc=0 + line-initial `FAIL:` = FAILED, closing the grace window
  from the other side (within-grace failures caught by transcript,
  beyond-grace by the sweep — no duration of failing background work is
  green). R4-F3/R5-F2 (found independently by both reviewers): L2's
  `--filter` matching nothing left `Total: 0`, rc=0 — this task's defect
  sentence in the tier's own sibling runner, hit for real by QA via a BRE
  alternation; L2 now carries L1's guard (rc=2, names the no-match).
  R4-F4: INT/TERM to either runner signalled only the active spec's
  process GROUP, stranding an out-of-group descendant on a live ppid chain
  (`setsid sleep & wait` — reproduced on Linux, both runners, descendant
  alive past exit 130). Both interrupt handlers and both watchdog cap
  paths now snapshot the ppid tree BEFORE the polite TERM pass and KILL
  both the snapshot and the group after the grace (verified on Linux:
  descendant REAPED, rc=130). R5-F3: the runner header claimed set -m side
  effects were "measured on … Linux bash 5" before anyone had measured on
  Linux; the sentence now carries its actual provenance including this
  round's measurement (0 job-notice lines across 5 full 36-spec tier runs,
  ubuntu:24.04 bash 5.2.21, command in-file). Plus QA's nits: failed
  `assert_contains` in the paired spec now prints the haystack (`| `
  -prefixed so quoted runner output cannot feed the outer runner's
  anchors), and survivor lines strip control bytes before the width cut.
  `runner-completeness.test.sh` grows 149 → 192: early-exit/exec/summary
  legs, transcript-arm legs (deterministic and Sol's timing shape),
  zero-match twins for L2, portable-setsid interrupt legs against both
  runners (perl POSIX, macOS has no setsid(1)), scratch-lifecycle legs via
  an mktemp PATH shim (TMPDIR-scoping was VACUOUS on macOS — BSD mktemp
  ignores it for `-d -t`; caught by running the no-rm reddening mutation,
  which is the pairing requirement doing its job on its own control), a
  no-EXIT-trap structure pin with fixture control, the trap-chain lint,
  and THREE new mutants (L1 transcript arm, L2 filter guard, L2
  accounting). Hand-run reddening mutations, each observed red: interrupt
  reverted to group-only signals → 12.30 alive; `finish` without its rm →
  12.35 names the surviving path; summary trap excised alone →
  12.10-12.12 lose the pass-then-skip accounting.
  The R6/R7 rounds (Sol, 1 HIGH; QA, 1 HIGH + 1 MEDIUM + 2 LOW — QA's
  factorial falsified this entry's own earlier probe-effect account, and
  the paragraphs above now carry the corrected one) then closed the
  escalation's remaining honesty gaps. R6-F1: the pre-TERM snapshot is not
  a closed set — a TERM handler can SPAWN during the grace window, and the
  runner also TERMed its own watchdog the moment `wait` returned, so on
  the common path (leader dies politely) the KILL pass never ran at all:
  reproduced on macOS AND Linux with a setsid shell whose TERM trap
  backgrounds a sleep — interrupt path stranded the spawned child, cap
  path stranded the SHELL TOO. Per the R6 scope ruling the fix is bounded,
  not an arms race (chasing a re-spawning tree needs cgroups/namespaces):
  one shared `escalate_kill()` now re-walks ONCE from every snapshot
  member still alive after the grace, the runner lets a FIRED watchdog
  finish (marker-gated wait), every kill site names what refused TERM
  before KILLing it and names anything it could not kill as a `survivor:`
  line, and every "guarantee" claim in both runners and the tests README
  is rewritten to the measured truth: two bounded walks, named survivors,
  stated limits. R7-F2: the R4-F1 summary trap moved two specs from
  SKIPPED to an UNQUALIFIED green — `post-edit.sh` `PASSED (101
  assertion(s))` of a 115-assertion full run under `BD_SHIM_ONLY=1` — so
  L2 now carries L1's `SECTION_SKIP_RE` and a `Partial:` counter
  (measured, macOS with bd off PATH + BD_SHIM_ONLY=1, final bytes:
  `Total: 44 Passed: 12 Failed: 1 Skipped: 31 Partial: 2`, the sole red
  the pre-existing installer-v3-upgrade 8e-B), and test.yml's l2-component
  comment now states the measured coverage instead of the "7-spec
  remainder / never as passes" claim this change set's own fix falsified.
  R7-F3: SIGHUP — the closed-terminal path — leaked the scratch dir 5/5
  with `finish` unreached (rc=129, measured both platforms); both runners
  now trap HUP through the same interrupt path (0/5 leaks, rc=130), and
  the disclosed residual is exactly `set -u` aborts and SIGKILL. R7-F4:
  the trap-chain scan matched only the canonical single-signal form (four
  evasions scored 0); it now catches multi-signal, numeric-0 and
  trailing-comment forms, names the variable-spelled signal as invisible
  to any static scan, and the runtime missing-summary FAILURE — verified
  by QA against real evasions — is documented as the guarantee.
  `runner-completeness.test.sh` grows 192 → 211: the widened-scan evasion
  controls (12.43a-e, plus a false-positive control over chained/reset/
  RETURN/numeral shapes), grace-window respawn legs against both runners
  and both kill paths (12.44-12.47), HUP lifecycle legs (12.48/12.49), L2
  partial legs (12.50-12.53), and a TWELFTH committed mutant (the
  L2-PARTIAL excision, 12.54-12.56 — the R7-F2 deception on demand). Leg
  5.9 was rewritten for the new architecture (the escalation, not the
  sweep, now kills a TERM-refuser on the timeout path — so it must NAME
  the kill, and does). Five hand-run reddening mutations, each observed
  red on exactly its legs with sha-verified byte-identical restores:
  pre-widening regex → 12.43a/c/d; RESNAPSHOT excised → 12.45/12.46;
  watchdog-wait reverted → 12.46 + 5.9; HUP untrapped → 12.48/12.49;
  refusers report stripped → 5.9. R8-F1 (Sol, on the R6/R7 bytes) then
  caught the escalation's own report lying about WHY it had killed: every
  member of the kill set was named `refused TERM, KILLed:`, including
  processes the post-grace re-walk had found that were BORN after the TERM
  pass and never received one — which sends a maintainer hunting a
  signal-handling defect that does not exist. Reproduced on the shipped
  bytes with Sol's shape, a setsid'd shell whose TERM trap backgrounds a
  child: the trap-spawned child — absent from the pre-TERM snapshot and in
  a different process group — was named a TERM refuser, and so was a
  `sleep 1` the shell's own loop had started after the TERM. The report now
  attributes only what the escalation can KNOW. It TERMed the pre-TERM
  snapshot itself, so a snapshot member still alive a full grace later did
  refuse (`refused TERM, KILLed:`); everything else is named by MEMBERSHIP
  (`not in the TERM snapshot, KILLed:`) and claims no signal in either
  direction. That second label matters: the FIRST attempt at this fix
  called it "discovered after TERM pass", which reproduces as the same
  defect inverted — a process double-forked before the snapshot has no ppid
  chain back to the leader and is invisible to `tree_pids`, but it KEEPS
  the spec's pgid, so the group TERM does reach it and it can refuse, and
  the label would deny a signal-handling defect that IS there. Both wrong
  labels were measured against the shipped escalation and then run as
  reddening mutations in BOTH runners: each reds exactly 12.46c, 12.47b and
  12.47d (tier rc=1), disturbing no other leg, while the two controls that
  observe the TERM and the kill themselves stay green — which is what makes
  the reddening about the attribution rather than about the escalation.
  `runner-completeness.test.sh` grows 211 → 216: two grace-window
  attribution legs (12.46c/12.47b, one per runner) and three for the other
  population (12.47c-e), where the double-forked orphan RECORDS its own
  TERM — so the leg OBSERVES the delivery the wrong label would have
  denied instead of arguing about it, and needs no `perl`, covering the
  machine where 12.44-12.47 skip. L2 tier caveat, restated for the
  PARTIAL era: under `BD_SHIM_ONLY=1` CI, specs that ran assertions
  before their bd gate read PASSED-but-INCOMPLETE with a `Partial:`
  count rather than unqualified passes; the assertion totals remain
  environment-sensitive and the l2-component job still pins no numbers —
  the L2 floor stays u84b's territory.
- **`review-config` ships `max_review_iterations=12` and
  `timeout_seconds=2400`** (`iu5o`, operator decision; both installers copy
  the file to every target). The in-file rationale carries the measurement
  that cuts against the larger numbers: Sol completed a real 1008-line review
  payload in 66s of the original 300s budget — the timeout was never the
  blocker; what blocked the lane was `max_review_iterations=3` returning
  rc=6 at zero seconds, and the iteration counter is lane-blind (Claude
  rounds consume Codex eligibility — the defect is `nq5f`; when it lands the
  cap should be revisited down). The larger timeout is headroom for a wedged
  turn's worst case (40 min vs 5 min before degrading to the Claude path),
  not a per-turn spend increase. The shipped values are now asserted by L2
  (`codex-review.sh` spec section C8): the iteration cap is bracketed
  behaviourally at the rc=6 boundary (12 admitted, 13 refused) against the
  shipped file's bytes, with a drifted-config negative control — a
  spec-authored fixture config is exactly how the first raise rode through
  provably untested.

### Fixed

- **Three defects in v5.0.0 itself, found by LIVE-2 — the first end-to-end use
  of the shipped design phase on real work.** v5.0.0 was first tagged at
  `c5ba7cc`, before all three. Because it was never published — the tag is
  local, only the branch has been pushed, to open PR #5, and this branch *is*
  the release — the three fixes are folded into 5.0.0 rather than cut as a
  `5.0.1`. `manifests/v5.0.0.sha256` is regenerated against the final release
  surface to match, and publication is gated on the local tag resolving to
  the final release commit. All three share one shape with the `gytz` family
  below — mechanisms each correct in isolation that had never been run
  together.
  - **`513j` — the design phase turned an operator's own `make test` red**
    (commit `26dac6c`, 238 assertions in the touched spec). `@designer` writes
    to `docs/specs/<task-id>.md` on a DERIVED path — `design-record` refuses any
    other — while `approval-record-disclosure-claim.test.sh` pinned the exact
    SET and count of `docs/**/*.md`, excluding only `docs/reviews/**`. First use
    of the feature broke the suite: `1S.2` expected 39, actual 40. The spec was
    working; nobody had taught it about a directory v5 introduced. The fix is
    one exclusion, and it took four review rounds. Only the pre-existing
    `docs/reviews` predicate's bug pre-dated the change — it had been
    UNANCHORED since it was written (BSD `find`'s `-path` wildcards cross
    `/`, so `docs/a/docs/reviews/x.md` was always invisible to that census),
    found only because the new `docs/specs` predicate sat next to it with
    the same bug. The `$root` metacharacter defect was not pre-existing: it
    was introduced by the fix itself, when anchoring the exclusion to
    `$root/docs/specs/*` left `$root` ACTIVE PATTERN SYNTAX to `find` even
    when shell-quoted, so a root containing `*` recreated the over-exclusion
    and one containing `[` caused UNDER-exclusion. Both closed by removing
    `$root` from the patterns entirely: `find` now runs from inside `docs/`
    so the exclusions are the fixed literals `./reviews/*` and `./specs/*`.
    The other half of the four rounds was sandbox isolation, unrelated to
    the predicates: the mirror's symlink guard was not fail-closed,
    `ensure_real_dir_chain` verified only below its own base and never the
    base itself, and LEG 2 (one of three) had no isolation gate at all —
    closed by a shared `is_real_dir_not_symlink` predicate, fail-closed
    with no replacement attempt, and by gating every post-copy mirror
    write.
  - **`a13r` — `fkm.10` was recorded but never effected** (commit `ea8031d`,
    37 files). `.claude/model-roles` declared `orchestrator=opus-class` while
    `.claude/agents/orchestrator.md` still pinned `model: claude-fable-5`, and
    the frontmatter pin is what a spawn actually honours. Nothing reconciled
    them: `session-start.sh` runs `model-select.sh apply --quiet --check`
    (`c5ba7cc:session-start.sh:618-625`), which warns and still records the
    resolved-mapping artifact but writes no frontmatter pins — the one write
    that would have closed the gap. The pin is
    corrected, and `model-select.sh check-parity` plus a `model_parity`
    `workflow-doctor` registry check make the next disagreement visible instead
    of silent. **The larger half of this commit is the guard that proves it.**
    Section 3.1c compared SOURCE TEXT, and one defect family was closed FIVE
    times across eight review rounds, each fix opening the next: a whole-file
    grep counted a set the mutation never touched; the scoped grep replacing it
    could match an EMPTY range; the selector dropped an arm from BOTH compared
    sides on a shared reindent; the completeness loop added to fix that had a
    key source that could go empty; its per-role predicate matched `printf`
    inside a COMMENT. At the fifth, the project's waiver ruling was applied —
    *when a defect family survives repeated rounds against the same mechanism,
    remove the mechanism* — and the text comparison was DELETED in favour of
    comparing what the two functions OUTPUT, with `role_agents()` driven through
    the shipped `--print-role-map` entry point. Six assertions removed. The
    diagnosis: a BEHAVIOURAL question had been approximated by a TEXTUAL one,
    and every defect was an artifact of the approximation.
  - **`1c82` — `design-conform` positively asserted that byte-identical,
    freshly-synced fixture mirrors were UNBUILT** (commit `326deeb`, 23 files).
    Not "I cannot see these files" — a false claim that the implementer had
    failed to do work that was done. Root cause: `actual` (impact-report.sh's
    change set) is denylist-filtered AT ITS SOURCE, so a denylisted-but-declared
    path can never appear in it, built or not; `declared` was not filtered, so
    `declared - actual` reported such a path unbuilt UNCONDITIONALLY AND
    FOREVER, independent of build state. The gate was measuring a set difference
    that could only ever have one answer. Fixed by filtering `declared` through
    the same shared `workflow_denylisted()` before the diff — provably inert on
    the `undeclared_files` gate (with `actual` A disjoint from denylist D and
    filtered declared `C'=C\D`, `A\C = A\C'`). Independent review then found a
    second defect IN THE FIX: availability was tested by `WORKFLOW_DENYLIST_REGEX`
    being non-empty, so an inherited variable with the function undefined let the
    pipeline return rc=0 and RETAIN the denylisted path, silently recreating
    `1c82`. It now tests `declare -F workflow_denylisted`, re-sources from
    `$PROJECT_DIR` when either half of the library contract is missing, and
    REFUSES if either remains absent.
  - **NOT FIXED, and stated because a changelog that read otherwise would be the
    defect this release is about: `j4pe` remains OPEN.** D4 task-per-unit is
    still structurally incompatible with the D2 design-satisfied gate — a
    correctly-bound unit child refuses with `no_design_attempted`, because
    `compute_design_satisfied()` resolves every input on the passed task id and
    never consults `latest_design_unit_binding`. A direct fix was built across
    six review rounds and then REVERTED WHOLESALE: round 5 ruled the
    resulting fail-open NEWLY REACHABLE rather than inherited (shipped
    v5.0.0 exits 2 at `qa-gate.sh:6990` — before the durable approval write
    at `:7784`, by which point `reconcile_tracker`, called at `:5642`, has
    already run and written its reconciliation bookkeeping, unconditionally
    truncating `reconcile-subtracted.txt` at `:1273` — though it appends
    `changed-files.txt` (`:1615-1625`) only when unreconciled paths survive,
    not on every call — so the fail-open cannot occur there), and round 6
    found the lock
    meant to close it INERT on macOS — no `flock`, no `else` branch, proceeds
    unlocked by design — with an incomplete lock population even where `flock`
    exists. Round 7 ruled the revert exact. The safe version is filed as
    `cfa3` (P1, design-pending) carrying all six rounds of findings as its
    design brief; `robt` (the non-atomic approval boundary) folds into it.

- **Four gate defects that each made a measurement that never happened look
  exactly like one that passed** (`gytz`; commit `261e09e`, 43 paths). Four
  tasks share one change set because they share one defect family: in every
  case the failure mode was not "the check said no" but "the check said
  nothing, and nothing is what success looks like here."
  - **`90av` — the Stop hook was a gate pretending to be a scheduler.** On
    release it ended the session instead of handing over the next ready
    work — shipped, unfixed, across two prior attempts over months —
    because `additionalContext` on a Stop event is DISCLOSURE-ONLY and
    cannot resume a turn; only a top-level `{"decision":"block"}` continues
    a session. `compute_next_work()` now resolves READY / NOTHING /
    DEGRADED as three distinct states and emits a block for READY only, so
    an empty queue and a broken query no longer render identically.
  - **`9hv4` — a zero-match lesson search looked like a clean search.**
    Phase P's `LESSONS.md` scoping never fully landed, and both consumers
    required to follow it had already shipped against the gap.
    `lessons.sh list` with filters now emits accounting on stderr, so a
    search matching zero entries is reported as zero rather than returning
    the same clean, confident, empty output as a search that matched
    nothing because it was scoped wrong.
  - **`wuu8` — a refused review packet looked like a reviewer with no
    findings.** A real review packet measured 14.5x over
    `codex-review.sh`'s `max_request_bytes`, so the "Codex lane active" arc
    silently exercised the exit-7 fallback instead of reaching Codex at
    all. The packet is now built with a byte budget and whole-file-only
    elision — never a mid-file cut, which would hand a reviewer an
    incomplete hunk with no marker that anything followed it — ordered
    largest-first within a tier. Shipped smallest-first for one round, and
    that was measurably wrong: six small agent prompts consumed a
    35,841-byte floor before `qa-gate.sh` (48,868 bytes) could be seated at
    all, so the reviewer received zero bytes of either gate script
    implementing the HIGH-severity repairs actually under review.
  - **`dhh7` — the store canary's ATTRIBUTION mechanism is DELETED, not
    fixed.** A hand-written regex parser over `bd`'s free-form
    commit-message text decided self-vs-external, and failed three
    consecutive independent review rounds as each tightened the regex
    while the underlying defect survived — the input was never a protocol,
    it was a vendor's human-readable prose, which changed under the
    project mid-arc when the host's `bd` moved 1.2.2 -> 1.3.0. Removed
    under the standing waiver ruling: when a defect family survives
    repeated rounds against the same mechanism, remove the mechanism —
    tombstones only, no dormant code, no flag, no `NOT-PROVEN` row.
    Detection survives and is now honest: `hashof('HEAD')` needs no actor,
    so it does not depend on the same commit-message prose that just
    failed three times, and any store advance during a spec now fails that
    spec, named. Four further defects in that detection path, found by the
    fourth and fifth review rounds, are fixed in the same commit: a failed
    snapshot no longer reads as "no change" (the query's `rc` is captured
    on its own line rather than masked behind a pipe, and the hash is
    validated by a POSITIVE allow-list — a bracket-range allow-list follows
    locale collation, and under `en_US.UTF-8` on this host bash 3.2 matches
    uppercase `A`-`U` against what was meant to be lowercase-hex-only); a
    boolean sentinel can no longer render as "advanced by 1 commit(s)"; and
    the canary no longer shadows a spec's own transcript failures.
  - **`bd dep add` on an already-existing edge is a silent no-op** — rc=0,
    an identical success message, and the store hash provably does not
    move. Found while fixing the four above; fixtures now verify the write
    LANDED before asserting any verdict, so a write that did not happen can
    never again be read as a guard that did not fire.

  **A known limit ships openly rather than being papered over**: the
  canary's contract is now stated as exactly what two endpoint samples can
  prove — NET HEAD CHANGED, never "advanced at any time." An exact
  advance-then-restore inside one spec is invisible, and that limit is
  characterised by a test that drives a real `dolt reset --hard` round trip,
  not described in a comment. Closing it fully would mean rebuilding the
  mechanism just deleted; spec isolation (`h5lw`, filed, not yet landed)
  removes the need instead.

  Measured at `261e09e` (cited from the commit's own record — not re-run by
  this piece, per this task's constraint against a full-tier run while
  sibling agents are concurrently writing to `bd`): `make test` (full L1)
  72/72 specs, completeness floor HELD, 7,306 assertions (71 passed / 1
  failed — the one failure was a store advance caused by the gate's own
  mandatory J21 write during the run itself, and a quiesced re-run proved
  the store hash byte-identical before and after); `runner-completeness`
  463/463 assertions, rc=0; `make lint` rc=0; `bd --version` 1.3.0
  (`f45b249ce`). Nine follow-ups filed, none silent, including `h5lw` (spec
  isolation, the family-level fix several of the above converge on) and
  `srlo` — filed, still OPEN, NOT fixed by this commit: a fake
  system-reminder, shaped like a genuine one, observed attached to tool
  results and steering agents to edit via Bash (`sed`, heredocs) instead of
  the dedicated Write/Edit tools specifically because `post-edit.sh` hooks
  Write/Edit/MultiEdit/NotebookEdit and NOT Bash, so a Bash-mediated edit
  never enters `changed-files.txt` or `change_set_hash` and ships outside
  what the QA approval attests. Observed against 12+ agent carriers this
  arc; every agent that reported on it refused except one, which
  self-reported complying once, caught itself, and remediated via a real
  Edit call. The defence today is each agent independently recognising and
  refusing the carrier — filed specifically because that is a per-agent
  judgement call repeated dozens of times rather than a mechanical gate,
  and it has already failed once.

- **The finishing pass: eleven fixes that took CI fully green for the first
  time in the arc.** Every prior v5 candidate shipped with at least one red
  job. At `430fe99` the full matrix is green — **L1 75/75 specs, 0 failed, 0
  skipped, 0 partial, 7,890 assertions, completeness floor HELD; L2 48 specs,
  33 passed, 0 failed** (15 skipped and 4 partial, stated rather than rounded
  into "green"); shellcheck, manifest validation, the `bd`-max doctor job and
  L3 vitest all passing, with only the manual live-Claude job skipped (run
  `36465905492`). The eleven, each with the measurement that established it:

  - **`0z9v`** — `design-conform.test.sh`'s sentinel strip named only ONE of
    the two sentinel pairs it had to remove, so `REBIND-GATE-FLOCKED` survived
    and a whole family of assertions was compared against text that still
    carried its marker. The strip now names both pairs with separate found-
    flags and distinct exits (7 and 8), so a future single-pair regression
    cannot masquerade as the other, plus sections 9.2g–9.2u. **228 -> 245
    assertions, the same on both platforms** — real Linux CI reads
    `design-conform.test.sh: FAILED rc=1 (228 assertion(s))` at `bff6cc4`
    (run `36232214628`) and `PASSED (245 assertion(s))` at `430fe99` (run
    `36465905492`), matching macOS exactly. *An earlier draft of this entry
    reported "Linux 209 with 2 FAIL -> 226/226" as a platform contrast. There
    is no platform contrast.* The 209/226 pair is a narrower repro container
    missing Sections 14 and 15, which skip without python3
    (`design-conform.test.sh:1400-1401`, `:1491-1492`); the delta is the same
    19 assertions on both sides. `ad8f4cb` had corrected this exact
    container-versus-runner misreading for two sibling specs one day earlier
    and left the warning in its own commit message — and this entry
    reproduced it anyway, which is why the correction is recorded here in
    place rather than silently applied.

  - **`18fc`** — five independent SHA-256 helpers mis-parsed the one line
    format GNU coreutils and perl's `Digest::SHA` emit for a pathological
    filename. Both prefix the output LINE with `\` and escape the name when it
    contains a newline or a backslash, making field 1 sixty-five characters
    instead of sixty-four, so the recorded "hash" silently carried a leading
    backslash. Fixed at `workflow-manifest.sh hash_file` (both arms),
    `qa-gate.sh sha256_file`, `beads-ledger.sh sha256_file`,
    `install.sh mcp_sha256_of` and `uninstall.sh hash_of`, with a new 595-line
    `sha256-escape-decode.test.sh` pairing each with a negative control.

  - **`8lc1`** — a shell-compatibility probe measured the WRONG SHELL'S
    behaviour. bash 5.0+ defaults `globasciiranges` ON, forcing bracket RANGE
    expressions to ASCII ordering regardless of `LC_COLLATE`; macOS bash 3.2
    has no such option, so the probe agreed with the platform it ran on and
    disagreed with the platform it was predicting. Now capability-detected
    (`SC_ASCII_RANGE_PREAMBLE='shopt -u globasciiranges; '`), applied to both
    the probe and `sc_shape_check_locale`, with a new negative control `13w.0`.
    455 -> 464 assertions.

  - **`we57` + `0cr6`** — `workflow-doctor.sh` looked for the embedded-Dolt
    store under a fixed name, but `bd` names it after the PROJECT DIRECTORY
    with non-alphanumerics mapped to `_`, so the check silently examined
    nothing on any project whose directory name differed. Resolved by name via
    a new `resolve_bd_schema_store()`. In the same pass the single
    `DOCTOR_BD_SCHEMA_PIN` became `DOCTOR_BD_SCHEMA_VALIDATED`, a validated
    SET: the store schema version is **non-monotonic across bd releases**
    (1.1.2:53, 1.2.1:65, 1.2.2:53, 1.3.0:66), so a floor or an interval is
    meaningless and only an explicit set can be correct. A new CI job
    `l1-doctor-bd-max` pins the upper end; README gained a "Supported bd range".

  - **`qwny`** — `model-roles.test.sh` Section 11's isolation witness was not
    hermetic; it now builds its fixture through `"$REAL_BD" init --database
    beads`, pinning the store name instead of inheriting the directory's.
    452 assertions + 1 skip -> 456 + 0 skips.

  - **`4c6r`** — the runner-completeness oracle POLLED FOR A PROCESS that dolt
    only transiently spawns. dolt v2.3.5's `shouldFlushEvents("sql")` is
    unconditionally true and the config is read INSIDE the spawned subprocess,
    so the race was the subprocess's LIFETIME, not its spawn timing, and a poll
    could miss it entirely while reporting a clean result. Replaced with the
    deterministic `.devts` events-log side effect under a fresh per-call
    `$HOME` — an artefact that persists, rather than a process that may not be
    there when looked at.

  - **`lto2`** — `approval-record-disclosure-claim.test.sh` pinned line numbers
    that had moved. Pins 39 -> 41 and 90 -> 92, and the pin+1 canaries
    (`1S.14.5`, `1S.14.10`) 40 -> 42. 224 passed / 14 failed -> 238 / 0.

  - **`g47z`** — `review-artifact-durability.sh`'s AC-3 asserted on the WORDING
    of a refusal that no longer exists in that form. Post-`k6re` the
    unrecorded-artifact path is a HARD REFUSAL, while the assertion had been
    written against the older warn-and-succeed behaviour; its needle `"no
    review-artifact binding"` derives from `review_file_binding_obs`, which has
    exactly one consumer — the SUCCESS summary — so it could never appear in a
    refusal at all. Retargeted to `'"error_key":"review_artifact_unrecorded"'`,
    which `git log -S` confirms was introduced by exactly one commit
    (`fa30d05`) and is followed by `exit 4`. `qa-gate.sh` was deliberately left
    untouched: the gate was right and the assertion was stale. 40/1 -> 41/0.

  - **`4l1d`** — 21 e2e fixture mirrors had drifted from the scripts they
    mirror; `make sync-fixtures` re-synced them. 21 failing vitest specs -> 210
    passing.

  - **`lgq4`** — `.claude/test-cmd` had been deleted, which silently NARROWED
    the Stop gate to whatever `detect-stack.sh` guessed. Restored (51 bytes)
    and the whole `test-cmd`/`lint-cmd`/`type-cmd` family gitignored, so the
    file can exist locally without ever entering a change set.

  - **`1vrs` R1-F1** — a comment-only correction: `workflow-doctor.test.sh`'s
    META-TEST index still described the retired single pin as current, which
    would have sent the next reader looking for a mechanism that no longer
    exists.

- **First real-project validation, and what it found.** Nothing in the v5 arc
  had ever pointed the plugin at a repository other than its own. It has now
  been run end to end against a foreign poetry-managed Python product repo:
  install exit 0 in 19s, `workflow-doctor` 12 passed / 0 failed / 1 skipped,
  then the whole arc — grilling, design, three review rounds to
  `verdict=satisfied`, decomposition into units, and a real implementation that
  went **green-to-green (1,901 passing before, 1,907 after — +6, exactly its
  own new tests, 0 failures across ~2,000)** with all seven acceptance criteria
  met and the pairing requirement confirmed empirically by stashing the fix and
  watching the new tests fail distinguishably. **This is the first evidence the
  plugin works on anything but itself.** It also surfaced three defects that no
  amount of self-testing could have found, all filed, none fixed in this
  release:

  - **`pqoj` (P0, INHERITED — present identically in 4.1.0, not a v5
    regression).** The shared denylist's `(^|/)(node_modules|dist|build|
    coverage|...|target|__pycache__)/` alternation anchors to a SEGMENT
    BOUNDARY with no containment check against the project root, and
    `changed-files.txt` carries absolute paths. So an ancestor directory at ANY
    depth named `build`, `dist`, `target` or `coverage` denylists **every file
    in the project**: `post-edit.sh` rejects each path at entry,
    `changed-files.txt` is never created at all, and `change_set_hash` becomes
    `e3b0c442…b7852b855` — sha256 of zero bytes — permanently and regardless of
    what is edited. Because that value is CONSTANT, the "has the change set
    moved since approval?" comparison protecting every downstream gate can
    never fire. Verified by sourcing the real denylist and by direct
    observation in the clone, where three genuinely-edited files produced no
    tracker at all. It survived the whole arc because this repository's own
    path contains no matching segment — invisible on the authoring host, fatal
    elsewhere. **Consequence for this release note's own honesty: the run's
    `design-conform` "ok:true" is VACUOUS** — it named the three just-written
    files as "not yet touched" — so whether `design-conform` works on a foreign
    repo remains UNESTABLISHED in either direction.

  - **`6ob3` (P1).** `detect-stack.sh`'s Python branch hardcodes bare `python
    -m pytest` with no poetry/venv/uv detection, while its npm branch
    interrogates `package.json`'s own scripts and leaves the command EMPTY when
    there is none. On a poetry project it resolved the ambient interpreter and
    reported 103 collected / 98 errors, so `green-check --phase before` refused
    with `cannot_start_from_green` — against a suite that is genuinely green
    (2,180 collected / 0 errors; 1,901 passing in 45s under the project's own
    interpreter). The documented `.claude/test-cmd` override fixes it
    completely and was verified doing so; nothing tells an operator to write
    one, which is the real defect. The same ambient-PATH blindness runs the
    other way for lint and type: `command -v ruff`/`mypy` come back empty on a
    venv-isolated project, so the gate would run no lint and no type check and
    still report success — the loud half was discoverable, the silent half was
    not.

  - **`1dbz` — FIXED IN THIS RELEASE, not shipped as a known issue.**
    `design-unit-align`'s LEG 3 demanded a covering test for every declared
    acceptance criterion, with no accommodation for a REGRESSION-SHAPED
    criterion whose entire content is "the pre-existing suite still passes", so
    a correct, fully-implemented unit could not be aligned. It failed LOUD and
    named the exact criterion — the healthy failure mode, and the deliberate
    contrast with `pqoj`. The fix is below under "A regression-shaped
    acceptance criterion can now name the pre-existing test that covers it".

  The implementer refused the `.claude/test-cmd` workaround for its own
  blocker, on the grounds that manufacturing a way past a refusal you have just
  hit is indistinguishable from working around it — which is the behaviour the
  design wants, and is why the operator provisioned the override instead.

- **Parallel batching ships on file sets only, and the claim was narrowed to
  say so.** The v5 design asserted that two units may run concurrently only
  when their declared file sets **and** their `impact_of` sets do not
  intersect. Only the first conjunct ships. `graph_intersection_computed` is
  the literal `false` at every emission site in `epic-gate.sh` — the success
  path at `:1014` and all five error paths — and `:1082` structurally
  validates that it is false, so there is no code path where it is true. The
  `impact_of` half is deferred to **`claude-workflow-plugin-l7gd`** (open since
  2026-08-22), and its own precondition is
  **`claude-workflow-plugin-kk9y`**: the code indexer records no call edge for
  a `"$SCRIPT_DIR/other.sh" --flag` invocation because the command name is not
  a bare word node, so on a shell-heavy repository the impact conjunct would be
  uninformative even once built. Rather than leave the overclaim standing, the
  release-audit row was narrowed by prove-or-remove to the file-set claim that
  actually ships — verified by `plan-batches.test.sh`, 319 passed / 0 failed —
  with the deferral, its precondition and the re-verdict trigger named in the
  row. **The withdrawn conjunct is withdrawn everywhere, including here.**

- **What that costs you, stated rather than buried: file-disjoint units can
  still conflict SEMANTICALLY, and no automatic control catches it.** Two units
  may touch entirely disjoint files and still break each other's behaviour.
  Worktree isolation for batch members is an **orchestrator responsibility, not
  a mechanism**: `epic-gate.sh` contains zero occurrences of `worktree`, the
  `plan-batches` envelope carries no worktree field, and `plan-batches.test.sh`
  never mentions one — while the design requires per-member isolation. So
  either members are isolated, in which case a later unit's full-suite
  `green-check --phase after` cannot see an earlier unit's changes until
  integration; or they are not, which is the contamination failure recorded as
  the first entry in this repo's lessons ledger. Either way the cross-cutting
  integration sweep is **manual** (`epic-gate.sh` calls it "recommended").
  **Run it yourself after a parallel batch.**

- **A regression-shaped acceptance criterion can now name the pre-existing
  test that covers it (`claude-workflow-plugin-1dbz`).** `design-unit-align`
  LEG 3 required every `criteria_tests` reference to appear byte-for-byte in
  the same payload's `tests_added`, so a criterion asserting that specific
  existing behaviour is preserved had nothing legal to name and the unit could
  never align. Found by pointing the plugin at a real product repository: a
  correctly implemented, green-to-green unit was refused. **LEG 3 stays
  strict** — a criterion with no covering test is still refused, and no
  criterion "kind", invariant category or exemption was added, because a
  designer could label a behavioural criterion an invariant to escape testing.
  Two changes instead. **(1)** The record-time `criteria_tests ⊆ tests_added`
  cross-check is removed, so a reference may name a pre-existing test. This
  loses nothing: `tests_added` was never externally verified either — its only
  consumers check that the key exists, that it is an array, and its length for
  a summary line — so a caller willing to invent a reference could always have
  written the same string into `tests_added`. What actually guards the field is
  untouched and unconditional: the reference must still resolve to a real file
  inside the project tree with the named label found in it, and `green_after`
  must be green *and externally corroborated* against the `GREEN-CHECK v1
  phase=after` record rather than read off the payload making the claim.
  Verified mechanically: the non-comment diff of `qa-gate.sh` is **two lines**,
  the old and new refusal text. **(2)** Upstream, `designer.md`'s
  pre-declaration checklist and rubric **DS1** now reject criteria that merely
  restate an invariant the gate already enforces — a criterion saying "the
  whole suite passes" is redundant, since green-to-green per unit enforces
  exactly that. Folded into DS1 rather than added as a ninth criterion, so the
  shipped "eight-criterion rubric" claim stays true (`DS1`–`DS8`, `version: 1`
  unchanged). LEG 3's refusal now names the recovery path — remove the
  criterion via `qa-gate.sh design-conflict` and the D2 amendment loop —
  instead of returning a bare `criteria_incomplete`. `design-unit-align.test.sh`
  64 → **73 assertions**, `validate-completion-criteria-tests.test.sh` 43 →
  **46**, all passing, each of the four new scenarios driving the shipped
  scripts rather than a stub.

- **`designer` and `design-reviewer` resolve to the SAME model on a stock
  install**, and the docs now say so where a reader will meet them. Both roles
  are `top`, so without the optional Codex lane the design is reviewed by its
  own identity family. This is reported, never blocked — `identity_collapse:
  true` in the resolver artifact, a `design-family-collapse` marker, a
  SessionStart warning and `!id` in the statusline. What is enforced
  mechanically is narrower and worth stating precisely: `qa-gate.sh
  design-record` refuses a verdict whose `reviewer_identity` equals the
  designer's. **Design review is Claude-lane only in this release, and the
  documented Codex clearance does not work.** `design_reviewer_lane` is
  resolved and displayed, but no script drives design review through Codex —
  `codex-review.sh` has zero design handling, and `design-reviewer.md`
  instructs the agent to emit `design-claude` unconditionally because it has no
  tool to read the lane. Installing Codex therefore makes things *report*
  better without being better: `model-select.sh:1374` raises
  `identity_collapse` only when the models match **and** the lane is `claude`,
  so flipping the lane clears the flag over an unchanged risk. Measured live on
  a Codex-installed host: `designer=claude-fable-5`,
  `design_reviewer=claude-fable-5`, `design_reviewer_lane=codex`,
  `"identity_collapse": false`. Filed as `claude-workflow-plugin-yvpe`. **The
  only real clearance today is `design_reviewer=<family>-class` distinct from
  `top`**, which changes the resolved model rather than a label.

## [4.1.0] - 2026-07-30

**The verifiable install.** Through 4.0.0 the plugin had no answer to "what
does this ship, and does it work where it landed?" — the shipped surface
existed only as a sequence of `cp` calls, there was no upgrade path off 3.x,
and post-install verification was two `test` calls. This release turns the
surface into a data artifact (`workflow-manifest.sh` plus a frozen per-release
hash table), builds a real v3.5 → v4 upgrade flow on top of it that preserves
operator customizations instead of clobbering them, and replaces
presence-checking with `workflow-doctor.sh` — eleven named checks that assert
FUNCTION rather than existence, two of which spawn the MCP servers over stdio
and assert exact tool counts. That last one earned its keep immediately: it
found a P0 absent from the plan, in which
every `curl | bash` install ran **no workflow at all** — both MCP servers dead
because `--depth 1` never cloned `node_modules`, and SessionStart emitting a
bare `{"error": …}` with no workflow context, no delegation contract and
nothing saying so. Around that, the v4.0.0 follow-up queue was burned down:
the `LABEL_WITHOUT_RECORD` remediation that printed a loop with no exit, three
transient-block race windows, and rubric verdicts that were not bound to the
change set they graded.

**Why this is a minor.** New capabilities, no broken contracts — the
`## Versioning` criteria above, applied literally. The release adds a new
slash command (`/workflow-doctor`, one of that block's own examples of a
minor), three new scripts, a new installer mode (`--upgrade`), a vendored
reference document, and a seventh field on the F7 completion contract. It
does **not** change the install layout, the hook output schema, or the QA
gate's release predicate, and existing installs upgrade in UPDATE mode —
never the fresh-mode re-install the major criterion names. That last point is
the one a reader of 4.0.0's note will want checked, so it is stated
explicitly: **neither `gz3` nor `bjx` adds a condition to the release
predicate.** 4.0.0 was a major precisely because the predicate gained two new
NECESSARY conditions (an independent review artifact, zero unresolved
at-threshold findings). `gz3` makes `approve`'s idempotency hash-aware — it
constrains when approve may *no-op*, and its Stop-side `VANISHED-CHANGE-SET`
arm *releases* a state that previously hung, so both directions are
weakly-or-not-at-all restrictive. `bjx` adds `change_set_hash` to the RUBRIC
record grammar and makes `enter` preserve a satisfied rubric label only on
positive evidence; its approve-side rubric cross-check is deliberately a
WARNING plus a durable `[rubric mismatch: …]` token rather than a refusal,
because `qa.md` 6f forbids a script-side rubric denial as a parallel gate and
`verify-before-stop.sh` reads no rubric state at all. Two honest
counterweights, both in the upgrade note below rather than buried here: the
change-set denylist grew three patterns, so an in-flight review cycle pays a
one-time re-approve; and `node` ≥ 18.17 became a hard, *checked* prerequisite,
so an installer run on a node-less host now aborts where it previously
proceeded — the requirement is not new (both MCP servers have always been
node), only the check is.

> **UPGRADE NOTE — two things to act on, in this order.**
>
> **1. Node is now a checked prerequisite and dependencies install in the
> target.** Every `curl | bash` install of 4.0.0 shipped both MCP servers
> DEAD: the source is a `git clone --depth 1`, `.gitignore` excludes
> `node_modules`, so the clone never had dependencies to copy and both
> launchers died at `ERR_MODULE_NOT_FOUND`. The installer now requires
> `node` ≥ 18.17 and `npm` (checked BEFORE the clone, so it aborts before
> writing anything) and runs `npm ci --omit=dev --ignore-scripts` per server
> in the TARGET after the copy. A run that installs the tree but cannot
> verify it exits **3** — distinct from `1`, which means "aborted, nothing
> written". **Existing 4.0.0 installs do not self-heal.** Re-run the
> installer in update mode, or do it by hand in the installed project:
>
> ```bash
> ( cd .claude/mcp/bd-mcp         && npm ci --omit=dev --ignore-scripts )
> ( cd .claude/mcp/code-graph-mcp && npm ci --omit=dev --ignore-scripts )
> ```
>
> Then confirm with `bash .claude/scripts/workflow-doctor.sh` (or
> `bash install.sh --verify`, or `/workflow-doctor`), which spawns both
> servers over stdio and asserts `tools/list` returns EXACTLY 21 and EXACTLY
> 7. "The config parses" is precisely what passed while this was broken, so
> the doctor does not check that.
>
> **2. One-time hash migration. The change set was never bounded
> by the repo.** `post-edit.sh` records `tool_input.file_path` VERBATIM, so any
> absolute path an agent wrote entered `changed-files.txt`, the change-set
> hash, and the Stop gate — including files outside the repository entirely.
> Three patterns join the shared denylist in this release:
>
> - `(^|/)\.claude/plans/` — plan-mode plan files wherever they live;
>   `~/.claude/plans/<slug>.md`, outside the repo, is the real shape.
> - `^(/private)?/tmp/claude-[^/]+/` — the harness's own per-session
>   scratchpad (grader verdict files, relay artifacts).
> - `(^|/)\.claude/\.mutation-(runs|worktrees)/` — `mutation-sweep.sh` per-run
>   reports and the throwaway checkouts `--keep-worktrees` leaves behind.
>
> `change_set_hash` is a sha256 over the DENYLIST-FILTERED changed-files list,
> so an approval recorded before this landing no longer matches the hash the
> Stop hook recomputes after it: the gate emits `LABEL_WITHOUT_RECORD` and
> re-blocks. That is the correct fail-closed direction — a stale approval must
> not release. All three patterns ship in ONE landing, so an in-flight cycle
> pays the migration exactly once. Recovery for a cycle caught mid-flight:
>
> ```bash
> bash .claude/scripts/qa-gate.sh enter <task-id>
> bash .claude/scripts/impact-report.sh <task-id>
> bash .claude/scripts/qa-gate.sh approve <task-id> '<summary>'
> ```
>
> That is the whole recipe — the same three commands the block reason prints,
> and no `bd label remove` step (`approve`'s idempotency has been hash-aware
> since 4.0.0's `gz3` fix).
>
> **What this fixes.** Six recorded instances in a single release. The worst
> was a hard dead end rather than friction: a plan-mode plan file blocked a
> TASK-LESS session across three Stop iterations up to J21 escalation. The file
> is `.md`, so F1 classified the change set doc-only — but F1's doc-only fast
> path auto-approves only WITH an active task, and plan mode forbids creating
> one. There was no exit. The other five were harness scratchpad verdicts
> mutating the hash mid-relay, two agent-chosen `/tmp` probes (one of which
> entered an approval's bound change set), and the two `mutation-sweep`
> directories — gitignored, but reachable by `Edit`.
>
> **What it deliberately does NOT cover, and why.** `/tmp` and `/var/folders/`
> as a class. The reason is mechanical, not stylistic: two component specs seed
> `changed-files.txt` with ABSOLUTE paths rooted at `mktemp -d`'s parent —
> `/tmp/...` on a Linux CI job, `/var/folders/...` on a macOS dev box — so
> either pattern would silently empty the change set of the spec that exists to
> prove path relativisation AND the spec that exists to prove the cross-worktree
> approval bridge. Both would keep passing while proving nothing. The narrow
> `/tmp/claude-<session>/` form is safe because those fixtures are created as
> `mktemp -d -t component-fixture.XXXXXX`. Agent-chosen scratch outside that
> prefix is addressed by PROMPT guidance instead — `qa.md` and the three
> specialist prompts send throwaway probes to the session scratchpad or
> `.claude/.qa-tracking/`. Pinned by
> `.claude/tests/component/specs/denylist-shared.sh`: **section D** drives the
> migration for the patterns that actually shipped (it pins the PRE-landing lib
> and then restores the real one, so the restore *is* the landing), while
> **section C** keeps the invented canary that proves the mechanism itself.

### Added

#### The v3.5 → v4 upgrade path (Phase U0, epic `0jk`)

- **`.claude/scripts/workflow-manifest.sh`** — the one machine-readable
  enumeration of the shipped surface. `generate <root>` emits a sorted,
  header-free, timestamp-free TSV of `<path><TAB><class><TAB><sha256>`
  mirroring `install.sh`'s copy loops one-for-one; `classify` produces a
  six-verdict upgrade decision table from an old hash table, a target and a
  source. Three classes: `workflow` (plugin-owned, replaced wholesale),
  `operator` (seeded once, never clobbered), `merged` (jq key-wise, never a
  copy). Hash chain `sha256sum` → `shasum` → `openssl`. Determinism is
  load-bearing — downstream specs regenerate the output and compare it
  byte-for-byte.
- **`manifests/v3.5.0.sha256`** — the frozen table for the last v3 release,
  generated from the real `v3.5.0` tag (117 rows, byte-reproducible), and
  **`manifests/v4.1.0.sha256`** for this one. `install.sh` picks
  `manifests/v<detected>.sha256` automatically, so a stock target of a
  released version classifies against its OWN hashes rather than falling back
  to v3.5's and reporting every unchanged file as customized.
- **`install.sh --upgrade` / `--mode <fresh|update>`**, mutually exclusive and
  validated before prerequisites. `detect_v3_install` reads `plugin.json` 3.x
  as the primary signal with a marker-absent fallback; a dotfile-inclusive
  `.claude-v3-backup-<timestamp>/` is taken; copies are verdict-driven
  (preserve-custom writes a `.new` sidecar alongside, replace-custom warns and
  backs up, merges go through the shared jq expressions); an
  `.claude/install-manifest` is written on every path; the run ends with a
  verdict-count readout and an `upgrade-report.txt`.
- **Idempotent re-runs.** Mode-2 UPDATE consumes the target's own
  `install-manifest` as `classify`'s old-table, so operator customizations
  survive a re-run (the re-clobber gap was reproduced before it was fixed;
  a legacy plain-copy fallback covers targets with no manifest). A
  sentinel-guarded no-change probe skips backup creation on genuine no-ops.
- **Manifest-driven uninstall.** `uninstall.sh` consumes the
  `install-manifest` — unmodified plugin-owned root files are trashed,
  customized ones are left with a note, and v2/v3 backups are listed. Both
  uninstallers enforce physical parent containment (`cd && pwd -P`, never a
  string prefix).
- **`install.ps1` carries the whole upgrade machinery**: `-Upgrade`, the
  detection ladder, exclusivity, PowerShell-native generate/classify/hash
  producing byte-compatible TSV, an LF-only `install-manifest`, the verdict
  walk, probe and report with rendered-sentence parity against bash, and the
  same manifest-driven uninstall.
- **Two shipped docs join the installed surface** (`docs/CODEX_SETUP.md`,
  `docs/HOOKS.md`), named file by file rather than by a `docs/` scan — an
  install target's `docs/` belongs to the operator.

#### Installed targets that actually orchestrate (Phase C0, epic `2br` — unplanned P0)

- **`.claude/scripts/workflow-doctor.sh`** — eleven named checks, each
  `PASS`/`FAIL`/`SKIP` with a `fix:` line, plus `--json-out` and exit `0/1/2`.
  Three front doors: `install.sh --verify`, the new `/workflow-doctor` slash
  command, and direct invocation. Two checks carry the phase: `session_start`
  pipes a synthetic payload through the REAL hook and asserts the emitted
  envelope CONTAINS the workflow context; `mcp_bd` / `mcp_code_graph` spawn
  each server over stdio and assert `tools/list` returns EXACTLY 21 / EXACTLY
  7 (probed with a stub at 0/20/21/22 tools → FAIL/FAIL/PASS/FAIL — exact
  equality is what catches "boots but registers nothing"). Every dynamic check
  runs in a throwaway sandbox; the `beads` check is the one documented
  exception, disclosed in all three operator-facing surfaces, because
  `bd doctor` must open the real database to mean anything.
- **MCP dependencies are installed in the target** — `npm ci --omit=dev
  --ignore-scripts` per server, with `< /dev/null` (under `curl | bash` stdin
  is the script text, and an npm prompt would eat it). `node` ≥ 18.17 and
  `npm` are hard prerequisites checked before the clone. Preserve-and-restore
  around the install, because `npm ci` removes `node_modules` first and a
  failing re-install would otherwise destroy the operator's tree. New flags
  `--verify`, `--skip-mcp-deps`, `--skip-verify` with env forms for
  `curl | bash`.
- **SessionStart degrades loudly instead of vanishing.** The full envelope is
  emitted always, with a `<workflow_degraded severity="high">` block SEEDED at
  the TOP of the context rather than appended. bd-off-PATH and missing-`.beads`
  are separate reasons. An EXIT trap enforces the guarantee at the exit rather
  than at each call site, so the next unanticipated death is also covered, and
  the jq-absent path gets a real awk JSON encoder rather than a truncated
  literal.

#### Gate follow-up burn-down (Phase U1, epic `waz`)

- **Hash-aware approve idempotency.** `approve` no-ops ONLY when an existing
  record binds the hash this approve would bind; otherwise it re-verifies every
  precondition and writes a fresh bound record. This closes a printed
  remediation that could not work (`enter` never removed `qa-approved` and
  `approve` short-circuited on its mere presence, so following the printed
  commands was a no-op loop). Three transient-block race windows close with it:
  record-before-label, clear-after-truncate, and a Stop-side
  `VANISHED-CHANGE-SET` release for the two-read straddle no approve-side
  ordering can fix.
- **Rubric verdicts are bound to the change set they graded.** RUBRIC records
  carry `change_set_hash`; `enter` preserves a `rubric-satisfied` label only on
  positive evidence (gate open, latest record satisfied, hash equal to now) and
  degrades to the old clear otherwise. The hash comes from three sources in
  descending authority — `--graded-hash` from the packet, else a live recompute
  corroborated by the persisted report, else explicitly unbound naming both —
  and deliberately never from the grader's own JSON, which would let the graded
  party state what it graded.
- **`docs/CODEX_SETUP.md` gains the hand-edit model-pin procedure**, a revert
  path, a moved-CLI-surface introspection ladder, and exit-5/exit-6 lane
  troubleshooting. The profiles section was CORRECTED rather than written: on
  codex-cli 0.145.0 a profile cannot reach the `mcp-server` lane at all, so the
  doc defends the single top-level model key instead of qualifying it.

#### Worktree sweeper and out-of-repo scratch (Phase U2, epic `0yg`)

- **`.claude/scripts/worktree-sweep.sh`** — a report-only sweeper for
  platform-created worktrees under `.claude/worktrees/` that carry changes and
  therefore survive subagent teardown. Dry-run is the default and `--apply` is
  the only thing that removes; removal requires ALL of physical containment,
  same-repo identity via `--git-common-dir`, a clean `status --porcelain`,
  locally-decidable pushed-or-merged, age past `--age-days` (default 7), and a
  task id resolved FROM EVIDENCE that `bd` reports closed. Each rejected
  candidate prints its FIRST failing reason. SessionEnd runs it
  `--report-only` under a bound, never `--apply`, and writes its own log which
  SessionStart surfaces as a fourth warning.
- **Three patterns join the shared denylist** — see the upgrade note above.

#### The seventh contract field (Phase U3, REDUCED, epic `gio`)

- **`context_coverage`** is appended SEVENTH and last to the F7 completion
  contract in all four specialist carriers plus `docs/AGENTS.md` — never
  inserted mid-list, because `qa.md` section 10 promises the base fields keep
  canonical names AND ordering. Convention: what you read to ground the change
  / what you deliberately did NOT read and why / the largest remaining unknown
  you are shipping on.
- **Rubric criterion C8** with an empty/boilerplate/detached taxonomy mirroring
  `grader.md`; `.claude/rubrics/default.md` goes to version 2.
- **The contract's claimed enforcement now exists.** `docs/AGENTS.md` asserted
  the contract was enforced because "the QA agent's review checklist asks 'did
  the specialist return all six fields?'" — and `qa.md` section 3's checklist
  had six items, none of them that. It is now written, and AGENTS.md names
  `qa.md` section 3 so the citation is checkable.

#### A vendored design method, and one debugging protocol (Phase U4, REDUCED, epic `q37`)

- **`.claude/vendor/superpowers/brainstorming/SKILL.md`** — vendored from
  `obra/superpowers` at pin `3dcbd5c4` (MIT) as a REFERENCE DOC, not a
  registered skill. It loads exactly where wired (an explicit `Read` in
  `orchestrator.md` section 1) rather than session-wide, and it preserves
  "everything under `.claude/skills/` is registered in `plugin.json`" as an
  exact, exception-free invariant. Ten surgical local modifications, each with
  a measured upstream count, are annotated in the sibling `MANIFEST.md` —
  including the deletion of a `<HARD-GATE>` demanding user approval for every
  project (a second, prose-only release authority) and of a sentence
  suppressing `frontend-design`, which is a LIVE registered skill here.
- **EBF-CORE** — upstream `systematic-debugging` is MERGED into the existing
  evidence-before-fix protocol rather than shipped beside it as a competing
  voice. A delimited region is byte-identical across `qa.md`, `backend.md`,
  `frontend.md` and `devops.md`, carrying a precedence clause and a
  bounce-twice supremacy rule stated in-text as deliberately stricter than
  upstream's "3+ fixes".
- **Root `LICENSE` and `THIRD_PARTY.md`** — `plugin.json` declared MIT with no
  backing file.

#### Tests

Every count below was re-executed on **2026-07-30** for this release audit on
`gauntlet/v4.0.0`; see `docs/RELEASE_AUDIT.md` rows `UW1`-`UW12` for the
per-claim evidence pointers.

- **Nine new L1 specs** (the full delta against the `v4.0.0` tag, derived by
  `git ls-tree` rather than recalled): `packaging-parity.test.sh` (**623** — it
  extracts the merge expressions FROM source between literal sentinels and
  compares bash↔ps1 token identity; closes `bzy`),
  `workflow-manifest.test.sh` (131), `installer-flags.test.sh` (94),
  `workflow-doctor.test.sh` (94), `vendored-skills.test.sh` (94),
  `mcp-deps.test.sh` (55), `mcp-deps-preserve.test.sh` (49),
  `completion-contract-parity.test.sh` (45), `worktree-sweep.test.sh` (34).
  Of the existing specs, `denylist-source.test.sh` went 20 → **32**.
- **Eight new L2 specs**, likewise the full delta:
  `installer-v3-upgrade.sh` (**235** — the flagship, built on a genuine v3.5
  fixture rendered by **v3.5.0's own installer**),
  `rubric-binding.sh` (149), `installer-manifest-parity.sh` (139),
  `installer-target-functional.sh` (138 assertions across 968 lines and 41
  METAs — its section 6, `PATH=/usr/bin:/bin`, is the ONLY thing in the repo
  that can catch the SessionStart P0, because the doctor's own `session_start`
  check passes on a host that has `bd`), `approve-idempotency.sh` (93),
  `upgrade-gate-compat.sh` (89), `worktree-sweep.sh` (55), and `bd-mcp.sh`
  (28) — **there was no bd-mcp spec at all before this release, which is half
  of why the dead-server symptom shipped.** Of the existing specs,
  `denylist-shared.sh` gained section D, 36 → **79**.
- Suite totals moved L1 **23 → 32 files / 1,540 assertions**, L2 **33 → 41
  specs / 1,011 → 1,983 assertions**, L3 unit **430 → 444 passed / 5 skipped**.
  (The L1 file count includes the pre-existing `phase5-synthetic-tests.sh`,
  which the runner discovers because it globs `*.sh`, not `*.test.sh`; all
  nine additions are `.test.sh` files.)
- **Load-bearing METAs were verified by removal, not assertion.** The EBF-CORE
  identity check has a 40-non-blank-line floor plus both sentinels required
  inside the region, because two EMPTY regions compare equal — identity alone
  would be one `sed` away from meaningless. The reviewer reproduced this on the
  live files: identity-alone PASSED all three emptied comparisons while the
  region checker REJECTED all four.

### Changed

- **`make install-test` verifies function, not presence.** It was literally two
  `test` calls. It now runs `workflow-doctor.sh` against a rendered target and
  went from 9 passed / 2 failed to **11 / 0** — the P0 verified fixed by the
  check that was catching it.
- **`.gitignore` is healed rather than only seeded.** `npm ci` writes ~13,700
  files and the installer previously wrote a `.gitignore` only when the target
  had none, so a Go or Python operator saw every one of them untracked. The
  heredoc also closes the CHANGELOG-3.4.0 divergence and the backup/sidecar
  noise, with line-for-line ps1 parity via `Write-LfFile`.
- **Installer branding is version-dynamic**, read from `plugin.json` by a
  deliberately jq-free `sed` anchored on exactly two spaces — the top-level
  depth of the 2-space-indented manifest. A looser `[[:space:]]*` anchor took
  the FIRST own-line `version` key at ANY depth and would brand every run with
  a nested one.
- **`.claude/settings.json` and `.claude/hooks/hooks.json` parity is checked
  across the full event set**, not just SubagentStart. Generalising that
  checker immediately found a real divergence: `hooks.json` wires
  `^Bash$ → bd-github-link.sh` and `settings.json` does not, so the
  Beads↔GitHub auto-link has never fired in this repo's own sessions.
  Behaviour is unchanged and the allowance is pinned exactly; the decision is
  filed as `claude-workflow-plugin-eo8`.
- **`run_bounded` kills the process group** (`set -m` plus
  `kill -TERM -$pid`). The previous watchdog orphaned grandchildren — measured
  at 3 per timeout — and the bounded calls wrap node MCP servers and the Stop
  hook, so every timeout left the wedged process alive.
- **`docs/TROUBLESHOOTING.md` gains 191 lines** and had ZERO occurrences of
  "MCP" before this release; QUICKSTART makes the doctor the primary
  verification step; `docs/MCP_SERVERS.md` gains a Dependencies section.

### Fixed

- **A failing `npm ci` destroyed the operator's working tree (data loss).**
  `npm ci` removes `node_modules` before installing, so a failed re-install
  took a measured 3,909 files / 98 `package.json` down to 94 empty directories
  / 0. Fixed with skip-when-current plus preserve-and-restore, verified by
  construction: the shipped installer restores byte-for-byte while a
  set-aside-removed mutant takes both trees to 0/0. Found only because the
  first verification run used `--skip-mcp-deps` — the one flag that disables
  the code path capable of causing the harm.
- **A failed dependency install printed a green tail.** The failure printed
  `FAILED npm ci`, then "Installation complete." in green, then advertised
  "Two MCP servers", and exited 0. Now a three-arm headline, a qualified
  advert, and a `DEPENDENCY UPDATE DID NOT FINISH` block naming each server
  and its fix command. Related: a failed `npm ci` leaves `node_modules` as an
  empty husk (94 directories, 0 files), so `[ -d node_modules ]` answered TRUE
  for a tree that cannot boot — replaced by `mcp_server_has_deps`.
- **An upgrade could destroy operator bytes while reporting them safe.** The
  shipped-docs surface was extended without backup legs across three arms plus
  an uncited v2 leg, so the report said "yours is in the backup" over files
  that had none. Fixed structurally with a derived `$SHIPPED_DOCS` and one
  shared backup helper across seven legs, with a META proving the report string
  was never an oracle for recoverability.
- **`install.ps1` was already WinPS-5.1 parse-broken at 4.0.0.** The
  `windows-install.yml` evidence is pwsh-7-only, so the breakage was invisible.
  Repaired across seven sites with an ASCII guard and METAs to prevent
  regression. This is a source-level repair; see the residual below.
- **A CI-red and a ~8 % flake at one line.** `workflow-doctor.test.sh`'s
  non-mutation assertion compared file AGE, which is a function of wall-clock
  time and changed with zero mutation whenever a run crossed a minute boundary;
  and `stat -f %m` is the BSD spelling, where GNU's `-f` is
  `--file-system` and writes 248 bytes of unrelated output to stdout that a
  `$(A || B)` capture then concatenates onto the fallback's answer. Both close
  by snapshotting raw mtime, GNU-first. Discrimination is retained: touching
  the marker still FAILS on both platforms.
- **`.claude/worktrees/` is gitignored at the project root.** It had been
  denylisted since v4 but never ignored (`:71` covered only the e2e-fixture
  nesting), so a leftover worktree was invisible to the gate AND visible in
  `git status`.

### Not shipped, and why

No claim in this release covers any of the following. They are recorded here
because a plan that is silently under-executed is indistinguishable from one
that failed.

- **U5, staging e2e QA with injected auth (epic `f2t`) — CANCELLED, not
  deferred.** There is no date at which it becomes correct. Four reasons in
  order of weight: it has the most external dependencies of any phase in this
  release; the largest security surface, since injected auth means credentials
  in a harness the plugin drives unattended; it is the only phase requiring
  live paid runs to verify, so its evidence would be the weakest in a release
  whose standing rule is that no adjective ships without an artifact; and the
  provider abstraction it implies stays speculative until a SECOND project
  validates the shape. Revisit when that project exists.
- **U3's ledger and frontier harness (epic `gio`) — DEFERRED on
  `claude-workflow-plugin-gio.1`**, behind an evidence bar of three closed
  tasks exhibiting the same blind spot. What shipped is the `context_coverage`
  field and rubric C8, above. The motivating problem — a 14-PR speculative-fix
  chain — is already solved by evidence-before-fix, which is shipped and
  mechanically guarded, so building the harness now would be machinery ahead of
  evidence. There is no `.claude/context-config`, no `context-ledger.sh` and no
  orchestrator wiring.
- **U6, the nested-spawn depth-3 migration (`7be`) — CLOSED as
  need-triggered.** `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` stays pinned.
  Depth-1 is not a limitation awaiting removal; it is itself an enforcement
  mechanism, because a subagent that cannot spawn subagents structurally cannot
  procure its own review — which is exactly the separation the gate's
  independence predicate exists to guarantee. Migrating would mean building a
  parent-role guard to restore in software a property the platform default
  gives for free. **The 2026-08-23 next-check date recorded on that task is
  RETIRED and is not a live date**; the standing task
  `claude-workflow-plugin-1bn` states the trigger as a condition — raise the
  pin WHEN a concrete workflow needs nested spawn — never as an elapsed month.
- **`wearclair-module`**, named in the original U4 request, remains
  unidentified after two independent checks (not among the 14 `SKILL.md` files
  at the pin, no web presence). Recorded as a skip.

## [4.0.0] - 2026-07-26

**The tri-model workflow.** The orchestrator plans on the newest, most
capable Claude family; implementation specialists build on the newest
Opus-class model; an optional external reviewer lane reads the same diff on
a second model family (Sol, through the Codex CLI's MCP-server mode). The
governing rule is **nobody signs off on their own work**, and as of this
release that is mechanical rather than advisory: `qa-gate.sh approve`
REFUSES unless the task carries a review artifact whose reviewer identity
differs from every recorded implementer, and the Stop hook re-runs the same
predicate before releasing. The change-set-hash-bound `qa-approved` record
from 3.5.0 remains the **only** release credential — the Sol lane, the
second opinion, and arbitration are inputs feeding that one gate, never a
parallel approval path. Alongside it, the gate learned to evaluate work
*where it happened*: baseline-scoped change sets, one shared denylist, and
a cross-worktree approval bridge, because the tri-model loop runs
implementers and reviewers in parallel linked worktrees.

**Why this is a major.** The Stop-gate release predicate gained two new
necessary conditions (an independent review artifact whose reviewer is not
an implementer, and zero unresolved at-or-above-threshold findings), and
the change-set denylist changed — so an approval recorded under 3.5.0 no
longer releases without a re-approve. Operators of installed projects
should re-run the installer in update mode to pick up the settings
migration below.

> **UPGRADE NOTE — one-time hash migration.** The change-set denylist changed,
> so the Stop hook recomputes a DIFFERENT `change_set_hash` for any change set
> containing a newly-filtered path. An approval recorded before this landing no
> longer matches that hash: the gate emits `LABEL_WITHOUT_RECORD` and re-blocks
> until the cycle is re-approved. That is the correct fail-closed direction — a
> stale approval must not release — and every denylist addition in this release
> ships in ONE landing, so an in-flight cycle pays the migration exactly once.
> Recovery for a cycle caught mid-flight (see `docs/HOOKS.md`, "Denylist changes
> are a hash migration"):
>
> ```bash
> bash .claude/scripts/qa-gate.sh enter <task-id>
> bash .claude/scripts/impact-report.sh <task-id>
> bash .claude/scripts/qa-gate.sh approve <task-id> '<summary>'
> ```
>
> That is the whole recipe — the same three commands the block reason prints, and
> no `bd label remove` step. On 4.0.0 exactly, retiring the stale `qa-approved`
> label first WAS required, because `enter` does not clear it and `approve`
> short-circuited on its mere presence; `approve`'s idempotency is now hash-aware,
> so a stale label no longer stops it (see `docs/HOOKS.md`, "Approve idempotency
> is hash-aware", and `claude-workflow-plugin-gz3`). Both routes are pinned by
> `denylist-shared.sh` section C: C4 drives the commands extracted from the block
> reason, C5 keeps the explicit-label-removal variant working.

### Added

#### Role-aware model selection (Phase V1, epic `bi3`)

- `.claude/model-roles` config maps each ROLE to a selection STRATEGY —
  `orchestrator=top` (the resolver's single best pick: newest, most capable
  family), `implementer=opus-class` (the newest `claude-opus-*` in the
  listing, falling back to `top` when none is listed), `reviewer=top`.
  Setting every role to `top` reproduces v3.5 single-pin behavior exactly;
  a missing file, missing key, or unrecognised value fails open to `top`.
- `model-select.sh` resolves per role behind an all-or-nothing MANUAL gate
  and writes `.claude/.qa-tracking/model-roles-resolved.json` atomically
  (stale beats none); it gains a `roles` subcommand and per-role `status`.
  `workflow-model-apply.sh` gains `--role <role> <id>` and
  `--print-role-map` (a bare `<id>` remains the pin-everything rollback).
  The statusline renders `orch:/impl:/rev:` when the roles diverge and
  collapses to the v3.5 single-model display when they don't.
- Day-zero adoption is preserved *within* each class: newest by release
  metadata, largest context variant, ranking file as override/exclusion
  only, unrecognized families as first-class candidates, and a Beads
  meta-task comment with a rollback command on every switch.
- The `!claude-fable` regional exclusion was lifted from
  `.claude/model-ranking` (evidence-gated, dated, with a rollback line;
  `!claude-mythos` kept).

#### The optional Sol reviewer lane (Phase V2, epic `1vq`)

- An **advisory, strictly optional** external reviewer lane: GPT-5.6-Sol
  reached through the Codex CLI's MCP-server mode. Absent, failed, or
  timed-out Codex behaves identically to "not connected" — the plugin's
  fresh-context Claude review path covers the reviewer role, proven
  byte-identical by a dedicated degradation spec. Sol writes no labels and
  records no approval; its artifact is grading-packet item 8.
- Helpers: `codex-detect.sh` (a layered, bounded, fail-open feature-detect
  writing an atomic reviewer-lane flag), `.claude/review-config` (the ONE
  place bounded-diligence caps live), `review-check.sh`
  (`validate-request` / `validate-artifact` / `gate` — the one counter,
  structurally codex-free), and `codex-review.sh` (a FIFO JSON-RPC driver
  with caps, cap-truncation, and a timeout).
- **Bounded diligence is mechanical.** Every review delegation carries a
  mandatory `risk_threshold` and `stop_condition` (the harness rejects a
  request missing either), and the caps in `.claude/review-config`
  (`max_findings`, `max_review_iterations`, `timeout_seconds`,
  `malformed_retry`) bound the turn: hitting one sets the artifact's
  `stopped_by` (`cap:max_findings` | `cap:max_review_iterations` |
  `cap:timeout`) instead of looping.
- Review artifact schema, strict JSON, recorded on the Beads task:
  `{reviewer_identity, reviewer_model, findings:[{severity, location,
  evidence, description}], verdict, iterations, stopped_by}`.
- Prompt wiring: `qa.md` §6-prime (the advisory review-artifact step),
  `orchestrator.md` §5c REVIEW-RELAY (paid, cost-confirmed), and the
  grading packet reconciled to eight items (item 8 advisory,
  non-criterion).
- `docs/CODEX_SETUP.md` — the operator setup doc, a first-class
  deliverable: every command live-verified; both auth paths and their
  billing implications; user-scope registration (mechanically required —
  the detector reads only top-level `.mcpServers.codex`); model-pinning
  guidance that extends day-zero adoption across the vendor boundary;
  verification and troubleshooting tables.
- **The Codex model pin lives in `~/.codex/config.toml`, not in the
  registration** (`docs/CODEX_SETUP.md` §5 and §7; finding
  `claude-workflow-plugin-gl6`, from the live validation below). codex-cli
  0.145.0's `mcp-server` mode ignores the registration's `-m <slug>` flag,
  and a `-c model=…` override does not stick either — the config file is
  authoritative, while `-m` only supplies the `reviewer_model` string the
  artifact records. A slug the ChatGPT-account backend rejects (e.g.
  `gpt-5.2-codex`, HTTP 400 "not supported when using Codex with a ChatGPT
  account") therefore fails the review turn with `codex-review.sh` exit 5.
  That path degrades to the Claude lane with zero behaviour change, as
  designed, so this is an operator-config trap rather than a plugin defect —
  the setup doc now carries the diagnosis, the one-line fix, and a free
  `codex doctor --json` check for the resolved model.

#### Sign-off separation and arbitration (Phase V3, epic `jio`)

- **Nobody signs off on their own work, enforced by the gate.**
  `qa-gate.sh approve` now REFUSES (exit 4) unless the task carries a
  review artifact whose `reviewer_identity` differs from every recorded
  implementer AND has zero findings at/above the artifact's
  `risk_threshold` still open. `verify-before-stop.sh` re-runs the SAME
  predicate before releasing, because findings can be recorded AFTER an
  approval and the write-once approval record cannot know about them. Both
  ends CALL the one shipped counter (`review-check.sh gate`) — there is no
  second implementation of the counting.
- Implementer identity is recorded at spawn: `subagent-start.sh` appends
  `IMPLEMENTER: role=<backend|frontend|devops> task=<tid> at <ts>` (once
  per role+task, best-effort, never blocks a spawn). `qa` is deliberately
  excluded — it reviews, and recording it would make every single-agent
  review non-independent.
- Approval records name the reviewer:
  `QA-GATE APPROVED change_set_hash=<h> reviewed_by=<id> at <ts>: <summary>`.
  The new token is space-separated AFTER the hash, so the llh.18 hash
  capture is byte-compatible (pinned by a test running the Stop hook's
  exact `jq`).
- Audited bypass `approve --no-review '<reason>'` (mirrors
  `--no-impact-report`; an empty reason exits 1). It stamps
  `[review bypass: <reason>]` on the approval record, which is the marker
  the Stop hook's discipline check skips on. The F1 doc-only /
  beads-state / empty fast path uses it automatically — a doc-only change
  has no implementer and nothing to review.
- Both new checks FAIL CLOSED: a missing or unrunnable `review-check.sh`
  refuses at approve and blocks at Stop. `review-check.sh` and
  `impact-report.sh` joined the installers' critical-path file list, so a
  partial install fails loudly at install time instead of deadlocking the
  gate later.
- **Arbitration of disputed findings** (`orchestrator.md` §5d). When the
  implementing specialist disputes an at-threshold finding, exactly two
  things clear it: RESOLVE with evidence (`qa-gate.sh resolve-finding
  <tid> <fid> --fix '<ref>' --test '<ref>' '<summary>'` — both refs
  mandatory, evidence-before-fix as a record) or ARBITRATE (`qa-gate.sh
  arbitrate <tid> <fid> <overrule|sustain> '<rationale>'`). `overrule`
  clears the gate count; `sustain` keeps the finding OPEN as the audit
  record of a dispute that was heard and upheld — which is what makes an
  overrule mean anything. Arbitration is the ORCHESTRATOR's job: the
  reviewer and the author are the two parties, so only the third can
  adjudicate, and the rationale must cite both positions. The prompt is
  guidance; the enforcement is the gate count.
- **Live-harness invariant `approval-cites-independent-review`** — the
  trace-side proof that the mechanism held during a real run. For EVERY
  `QA-GATE APPROVED` record: it names a reviewer (or carries the audited
  `[review bypass:` marker), an EARLIER `REVIEW-ARTIFACT v1` exists whose
  `reviewer=` is not one of the task's `IMPLEMENTER: role=` identities,
  and replaying the preceding records leaves zero open at-threshold
  findings (`RESOLVED … fix= test=` and a latest `ARBITRATION …
  decision=overrule` clear; `sustain` does not). It is a deliberate SECOND
  implementation of `review-check.sh gate`'s predicate, in TypeScript over
  a different input — if the shell counter is subverted or a fixture ships
  a stale copy of the gate, the two disagree and that disagreement is the
  signal. Declared in all seven fixture `invariants:` blocks.
- The e2e trace gained an OPTIONAL `beadsComments` field
  (`{task, text, order}`), captured post-run by `readBeadsComments()` from
  the same already-flushed `.beads/issues.jsonl` the label capture reads
  (no extra `bd` invocation). ABSENT means "not captured" and the
  invariant SKIPS (pre-jio.2 traces are not retro-failed); an EMPTY ARRAY
  means "captured, bd held nothing". Approvals with no `reviewed_by=`
  token skip as a pre-V3 recording.

#### Worktree-aware gate scoping (Phase V4, epic `3mg`)

The tri-model loop runs implementers and reviewers in parallel worktrees, so
the gate must evaluate work where it happened. Three production transcript
scenarios are closed.

- **Approval records name the approving checkout.** `qa-gate.sh approve`
  appends a `worktree=<tok>` token — the checkout's git toplevel, spaces
  `%20`-encoded so it stays ONE space-terminated token, `none` off a git
  checkout (never omitted: a stable grammar is what lets a reader tell "no
  worktree recorded" from "recorded but unresolvable"). Every approve path
  reaches the one record writer, including the F1 fast path and both
  audited bypasses:

  ```
  QA-GATE APPROVED change_set_hash=<h> reviewed_by=<id> worktree=<tok> at <ts>: <summary>
  ```

  Token ORDER is the compatibility contract: every addition since llh.18
  goes AFTER the hash token, space-separated, so the v3.5
  `change_set_hash` and V3 `reviewed_by` captures extract identical values
  from the old and new shapes. Pinned by a differential META
  (`review-separation.test.sh` 4.2b) that strips the `WORKTREE-TOKEN`
  sentinels from a copy of `qa-gate.sh`, approves with it, and runs BOTH
  reader expressions over BOTH record shapes plus a renamed token.
- **The Stop hook resolves cross-worktree approvals**
  (`WORKTREE-RESOLUTION` in `verify-before-stop.sh`). This closes the
  deadlock where a review performed in a linked worktree recorded a
  change-set hash the primary checkout could never reproduce, so its Stop
  hook reported "qa-approved label present but no change-set-bound
  approval record matches" forever. Only on the path that already blocks,
  the hook tries the recorded token first (O(1)), then `git worktree list
  --porcelain`, skipping the current checkout, capped at 16 candidates. A
  candidate releases only when ALL of these are positively proven: it is a
  worktree of this repo (symlink-resolved `--git-common-dir`, never a
  toplevel string compare); its persisted `impact-report-<tid>.json`
  carries a `change_set_hash` that a real approval record on the task
  cites; its own `git status` minus its own `gate-baseline` is empty (no
  post-approval drift there); every reviewable path in THIS checkout is
  inside that report's approved file set, compared repo-relative; and the
  V3 `review-check.sh gate` predicate is still clean (same audited
  `[review bypass:` escape) — so a finding recorded after the approval
  re-arms this path too.
- **Record-based, not recomputed.** `approve` truncates
  `changed-files.txt` in the approving checkout, so a recompute there
  returns the sha256 of the empty list — the approved hash is
  unreproducible even in the worktree that produced it. The resolution
  therefore reads the persisted impact report, which survives approve. The
  L2 spec asserts both the truncation and the diverging recompute, so
  making that truncation conditional fails loudly instead of silently
  disabling resolution.
- **Read-only, fail-closed, no MCP boot.** File reads plus `git worktree
  list` / `git rev-parse` / `git status` / `jq`. Nothing is written
  anywhere (the spec re-checksums the candidate worktree), and the
  code-graph MCP server is never booted (asserted with an armed canary
  that is proved live on an `enter` and silent on every Stop). Any error,
  unreadable artifact, or ambiguity falls through to the block. A removed
  worktree is named in the block reason ("bound in worktree `<path>`,
  which no longer exists"); otherwise the reason gains "(checked N
  worktree(s))".

#### Platform restore and the effort verdict (Phase V0, epic `cnz`)

- Effort-verdict launch wiring: a committed `.claude/effort-verdict`
  (verdict `max`, recorded by the cnz.2 A/B interference test), a
  `make session` launch target that execs `claude --effort <verdict>`, and
  session-start Warning 4 verdict reconciliation plus Warning 5 platform
  guards (`CLAUDE_CODE_SUBAGENT_MODEL` override, subagent spawn-depth
  drift).
- Subagent spawn evidence log
  (`.claude/.qa-tracking/subagent-spawns.log`, written by
  `subagent-start.sh`) and SubagentStart wiring in `settings.json` (parity
  with `hooks.json`).
- `docs/EFFORT-AB-TEST.md` runbook and the recorded A/B outcome:
  ultracode showed ZERO orchestration interference (the pre-registered
  expectation was NOT confirmed), but `max` remains the verdict per the
  runbook's conjunctive rule — criteria 2-3 were not fully re-verified
  under the operator's time-box and no benefit was observed, since
  ultracode runs the model at a fixed `xhigh` proxy below the `max` this
  verdict pins. Details on meta-task `claude-workflow-plugin-4o2`.

#### Tests

Every count below was re-executed on 2026-07-26 for the release audit; see
`docs/RELEASE_AUDIT.md` rows TM1-TM14 for the per-claim evidence pointers.

- New L1: `model-roles.test.sh` (40), `review-check.test.sh` (39),
  `review-count.test.sh` (38), `review-separation.test.sh` (60 incl. the
  strip-META and the 4.2b differential token META),
  `denylist-source.test.sh` (20 incl. 4 METAs), `platform-audit.test.sh`
  (18 incl. two META groups), `make-session.test.sh` (7 incl. the
  verdict-ignoring-stub META). `effort-fail-open.test.sh` (14) was
  inverted to the new no-env-pin baseline.
- New L2: `codex-detect.sh` (24), `codex-review.sh` (25),
  `reviewer-lane-degradation.sh` (8), `review-separation-records.sh` (16),
  `verify-review-discipline.sh` (24), `arbitration-acceptance.sh` (33),
  `model-roles-parity.sh` (10 incl. the liar-misroute META),
  `denylist-shared.sh` (33), `gate-baseline-v2.sh` (46),
  `worktree-approval-resolution.sh` (**67 assertions authored, 65
  executed** against a REAL `git worktree add` — the two `wtres-2.1`
  pre-fix legs are conditional on the committed HEAD predating the fix and
  are permanently superseded by the section-8 sentinel-strip META; this
  corrects the pre-release dev note's "55", 3mg.2 QA finding R1-F1).
  `model-select.sh` grew the `ms-R1..R6` role cases and the `ms-T1..T5`
  tier-vs-recency regression (88 total); `subagent-start.sh` grew 13
  identity assertions incl. an idempotency-break META (30 total);
  `failure-cross-repo.sh` gained the worktree cases (19);
  `qa-gate-baseline.sh` was retargeted at the v2 baseline file (23).
- L3 unit: `_invariants.unit.spec.ts` (102) covers
  `approval-cites-independent-review` with both plan-mandated METAs plus a
  mechanical META-COVERAGE assertion — every `INVARIANTS` row must ship a
  META-TEST or a documented exemption (only `completion-contract`, which
  is always skipped). Sensitivity was proven by mutation: neutering
  independence, making open findings non-fatal, letting `sustain` clear,
  flipping the skip to a silent pass, and registering a META-less
  invariant each turned the matching test red; every mutation was
  byte-restored. `_beads-capture.unit.spec.ts` gained a real-`bd` round
  trip proving the three record grammars survive capture in write order.
- Load-bearing METAs were verified by removal, not assertion: both
  sentinel blocks and the `subagent-start.sh` idempotency guard were
  stripped from the real scripts to prove the protected assertions go red
  — 25 / 10 / 4 failures respectively, as recorded by the implementing
  tasks (`jio.1`/`jio.2`) at the time; the release audit re-ran the suites
  green rather than re-running those one-off mutations. Four existing
  METAs that copied a hook to a fixture ROOT now copy it into
  `.claude/scripts/` — outside that directory the copy cannot find the
  shared denylist lib and blocks for the wrong reason, a silent false
  pass.
- Existing approve-reaching specs migrated to seed real review records via
  a shared `seed_review_records` fixture helper.
- **Live tri-model validation ran 2026-07-26
  (`claude-workflow-plugin-d2j.2`) — both legs PASSED.** Codex CONNECTED:
  `codex-review.sh` drove the REAL Codex MCP server on `gpt-5.6-sol`
  (read-only sandbox, no subagent spawning), Sol returned a schema-valid
  `verdict=findings` artifact with a genuine medium finding, and the real
  gate scripts BLOCKED it (`independent:true`, one open at-threshold
  finding) until an orchestrator `arbitrate … overrule` cleared the count.
  Codex ABSENT: feature-detect resolved `reviewer_lane=claude` and a
  same-schema `qa-claude`/`claude-fable-5` artifact drove the IDENTICAL
  sequence. Reviewer identity, model and finding quality differed; the gate
  DECISIONS were byte-identical — which is the release claim, confirmed
  live rather than only by the offline degradation spec. Scope stated
  plainly: the subject was a small synthetic harness driven through the gate
  scripts directly, not a full specialist→QA→grader cycle, so no e2e trace
  was captured and the `approval-cites-independent-review` invariant remains
  proven offline only. `docs/RELEASE_AUDIT.md` rows TM7/TM14 carry the
  result and that caveat.

### Changed

- **ONE denylist, three consumers.** New
  `.claude/scripts/workflow-denylist.sh` defines
  `WORKFLOW_DENYLIST_REGEX` + `workflow_denylisted()`; `post-edit.sh`
  (what gets TRACKED), `impact-report.sh` (what enters the change set and
  its HASH) and `verify-before-stop.sh` (what needs REVIEW) all source it,
  BASH_SOURCE-relative. The three copies had drifted: only the Stop hook's
  knew about `.claude/worktrees/` and the e2e fixture churn, so post-edit
  tracked worktree paths INTO the hash that the gate could not see — the
  hash and the gate disagreed about what "the changes" were. Now
  guaranteed to move together: harness-worktree paths leave the tracked
  set, the hash and the gate's view agree, and a change set of only
  build/workflow churn is `empty` rather than half-visible.
- **Memory files are no longer reviewable work.** `MEMORY.md` and
  `.claude/memory/` join the denylist, so they exit the change set BEFORE
  F1 doc-only classification: a memory-only change set now takes the
  `empty` fast path (release, no gate record) instead of being
  auto-approved as `doc-only` with a `[review bypass: F1 doc-only ...]`
  record about agent recall state. `CLAUDE.md` (behaviour-bearing —
  session-start injects it), `LESSONS.md` and `HANDOFF.md` (audit
  deliverables) are deliberately NOT denylisted.
- **Missing-lib behaviour is fail-closed per consumer**: `impact-report.sh`
  exits 3 (no hash, which upstream already treats as refuse-to-release),
  `verify-before-stop.sh` BLOCKS with a remediation reason (after the
  `stop_hook_active` circuit breaker, never before it), and `post-edit.sh`
  tracks the path unfiltered — over-tracking is the fail-closed side for a
  hook whose output feeds the gate.
- **gate-baseline v2.** `.claude/.qa-tracking/approved-baseline` (a bare
  line list, one writer) is superseded by
  `.claude/.qa-tracking/gate-baseline`, a versioned file with a provenance
  header (`head=`, `captured_at=`, `captured_by=`) over the
  `LC_ALL=C`-sorted `git status --porcelain` snapshot. Three writers now:
  `session-start.sh` on arrival (only when no review cycle is active —
  baselining an in-flight cycle would release its work unreviewed),
  `qa-gate.sh enter` (write-if-missing, minus paths already in
  `changed-files.txt` so the session's own edits are never baselined), and
  `qa-gate.sh approve` (full refresh, as before). New subcommand
  `qa-gate.sh baseline-capture [--by <who>] [--if-missing]
  [--exclude-tracked]` so session-start has one implementation to call.
  The legacy file is read as a fallback for one release and deleted on the
  first v2 write. This closes the "session opened in an already-dirty repo
  blocks on dirt the session never made" case; there is deliberately NO
  hash-side subtraction (the baseline is subtracted only in the git
  fallback, so editing an already-dirty file still gates).
- **`-d "$PROJECT_DIR/.git"` replaced by `git rev-parse --git-dir`** in
  `verify-before-stop.sh` and `qa-gate.sh`. In a LINKED WORKTREE `.git` is
  a FILE, so the old predicate answered "not a git repo" and silently
  disabled both the baseline writer and the Stop gate's git-status
  fallback — with an empty `changed-files.txt` the gate then had no
  detector at all and FAILED OPEN, in exactly the
  `isolation: "worktree"` topology the plugin tells agents to use.
- **The I8 cross-repo guard compares REPOSITORY identity, not checkout
  identity.** `detect_cross_repo` used `git rev-parse --show-toplevel`,
  which is per-checkout, so a Stop fired from a linked worktree of the
  SAME repo the task was claimed in tripped the cross-repo block. It now
  compares the symlink-resolved `git rev-parse --git-common-dir`, which
  every worktree of a repo shares and which differs across repos. A
  genuinely different repo still blocks; a recorded repo path that no
  longer resolves is still a mismatch (fail closed).
- **`qa-gate.sh choose approve` is no longer an unconditional escape**
  (J21 correction, `orchestrator.md` / `qa.md`). It delegates to the same
  `cmd_approve` as a direct approve, so it refuses while an at-threshold
  finding is open — a cap-hit escalation does not dissolve a dispute;
  arbitrate or resolve first. The same correction was applied to the
  rubric override in `qa.md` 6f (a judgment override does not satisfy a
  mechanical gate) and to the then-stale V2 scope notes in
  `orchestrator.md` 5c / `qa.md` 6p.3.
- `settings.json`: removed `env.CLAUDE_CODE_EFFORT_LEVEL` (a non-xhigh
  value there deactivates ultracode's orchestration layer per the live
  docs, leaving `effortLevel: "xhigh"` as the durable floor); pinned
  `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` (v2.1.219 flipped the platform
  default to depth 3; the relay architecture assumes depth 1).
- Installers (`install.sh` / `install.ps1`): the update-mode settings
  merge now deletes the legacy `env.CLAUDE_CODE_EFFORT_LEVEL` key (with a
  one-line notice), so installed projects migrate on their next update;
  the operator's own `env` keys and the `effortLevel` floor survive the
  merge and the deletion is idempotent. Both installers ship the new
  configs (`.claude/model-roles`, `.claude/review-config`,
  `.claude/effort-verdict`).
- `docs/MCP_SERVERS.md`: bd-mcp troubleshooting for installed projects
  (v2.1.196 workspace-trust behavior, the `${CLAUDE_PROJECT_DIR:-.}`
  form), cross-linked from README Caveats. The CONTRIBUTING effort recipe
  was rewritten to the three-layer model (floor `effortLevel: xhigh` /
  session verdict via `make session` / frontmatter `effort: max` ceiling).
- `docs/HOOKS.md` documents the verified cross-worktree topology, the
  fail-closed guarantee, and "Denylist changes are a hash migration".

### Fixed

- **The model resolver ranked recency above capability class (bug `en9`).**
  `pick_best` sorted by recency FIRST, so a newer but less capable family
  took the `top` lane: with `claude-opus-5` (created 2026-07-24) in the
  same listing as `claude-fable-5` (2026-06-07), orchestrator/qa/grader/
  judge were dragged onto Opus and the v4 role split collapsed to a single
  model. The sort is now `[._class, -(._ts), -(._ctx)]` — capability class
  (the family's position in `.claude/model-ranking`) PRIMARY, recency only
  WITHIN a class. An UNKNOWN family is ranked in the TOP class, so
  day-zero adoption of a genuinely-new above-Fable tier still wins on
  recency; the documented residual (a new BELOW-Fable family also landing
  in the top class) is covered by the unknown-family warning and a
  `!<family>` exclusion. Exclusions still filter first; the MANUAL-adopt
  and fail-open contracts are unchanged. Verified RED against the pre-fix
  resolver (pass=76 fail=12) and GREEN after (pass=88 fail=0), with the
  required `ms-TM` META — a `pick_best` reverted to the recency-primary
  sort must make `ms-T1` fail. `ms-Y` was re-scoped from cross-family to
  intra-class recency (it asserted the pre-en9 contract) and passes
  against both resolvers.
- **Two mid-review defects in the Sol lane** — a silently-non-executing
  test and a gate finding-suppression hole — were found during 1vq.1 and
  closed with load-bearing METAs.
- **PR #2 (`impact-report.sh` path relativisation) reconciled.**
  `impact-report.test.sh` section 4 still asserted the pre-PR#2 contract
  and only ran where a code-graph server is present (it skips in CI, so
  the divergence was invisible there). Out-of-project and
  unanchorable-relative entries are now recorded as explicit
  `skipped: path is outside the analyzed project ...` entries rather than
  being sent to the tool, so the report can no longer contain the server's
  absolute-path validation error.

## [3.5.0] - 2026-06-14

The **Release Acceptance Gauntlet**. Epic `claude-workflow-plugin-llh`
put every shipped claim through an adversarial certification —
operating rules: no adjective without artifact, prove-or-remove,
mechanics over prompts, dogfood throughout, hard $80 paid cap. The
output is a 121-row claims ledger (`docs/RELEASE_AUDIT.md`) re-tallied
mechanically at the verdict to **PROVEN 51 / PROVEN-WITH-CAVEAT 47 /
REMOVED 23 / NOT-PROVEN 0**. The gauntlet found and fixed a release-gate
P0 (a forgeable approval label that released unreviewed code), hardened
the Stop invariant against it, removed 13 stale-doc claims that no longer
matched the code, and red-team-certified that the gate does not leak
under live load — confirmed on two paid runs ($10.15 of $80): a
node-react-auth feature shipped end-to-end through the gate, and a
python-django-bug bugfix run whose unreviewed change the hardened gate
correctly BLOCKED. The guarantee: **51 claims proven by executed tests,
47 caveats documented and tracked, zero unproven claims shipped.** The
release rule (NOT-PROVEN = 0 AND Stage-3 P0/P1 closed) is MET.

### Added

- **Change-set-hash-bound QA approval — the P0 fix (llh.18).** The Stop
  gate no longer releases on the bare `qa-approved` label. `qa-gate.sh
  approve` now writes a tamper-evident approval record carrying
  `change_set_hash` — the sha256 of the sorted, denylist-filtered diff
  via `impact-report.sh --hash-only` (`qa-gate.sh:230,730-749`) — and
  `verify-before-stop.sh` requires a record whose hash matches the
  *current* change-set, not the label
  (`task_has_matching_approval_record`, release predicate
  `:1101-1146`). A bare label-add writes no record → block; a decoy-task
  approval has a different hash → block; any post-approval edit changes
  the hash → re-block. The release predicate fails CLOSED on a missing or
  unrecomputable hash. A load-bearing META-test proves the check is
  load-bearing (neutralize the hash comparison → a forged label
  releases).
- **`impact-report.sh` — mechanical impact analysis (G2.n6d, llh.2).**
  A deterministic driver that runs code-graph `impact_of` over the
  changed files at gate-enter and writes
  `.qa-tracking/impact-report-<task>.json`
  (`{generated_at, task_id, change_set_hash, files:[{file,impact}],
  server}`). `qa-gate.sh approve` REFUSES (exit 2) without a
  hash-current artifact; the documented bypass `approve
  --no-impact-report '<reason>'` lands in the audit trail. L1
  `impact-report.test.sh`.
- **bd-compatibility L2 spec (G2.bd-compat, llh.6).** `bd-compat.sh`
  pins 32 distinct `bd` command+flag invocations — inventoried from
  every hook script, bd-mcp, and the e2e capture lib — each run against
  the installed `bd` (0.47.1) and asserted to the EXACT output shape the
  caller parses (verbatim production `jq`). 71 assertions / 0 fail,
  auto-discovered into `make test-all`. Three load-bearing contract
  subtleties are pinned (create returns an OBJECT vs show/update
  1-element ARRAYS; `bd close` on a BLOCKED issue is an exit-0 no-op;
  `bd list --type epic --json` carries no `.dependents` on 0.47.1). A
  non-vacuity META-test fails loudly with a supported-range banner on
  shape mismatch.
- **`windows-install.yml` CI job (G2.ps1, llh.7) — dispatch-only.**
  `.github/workflows/windows-install.yml` (windows-latest,
  `workflow_dispatch` only, zero API spend) ports 27 parity assertions
  from `installer-mcp-config.sh` and includes a code-graph-mcp stdio
  `initialize` boot-check validated locally on macOS
  (`serverInfo={code-graph-mcp,1.0.0}`). It is authored but undispatched
  — gh's token scopes (`gist, read:org, repo`) lack `workflow`, so
  `install.ps1` is verified by parity inspection + local boot, not
  Windows execution (see Security/residuals).
- **Claims ledger (`docs/RELEASE_AUDIT.md`).** The 121-row artifact of
  the gauntlet: every README / QUICKSTART / docs / installer / agent-
  prompt claim plus the seven implicit gauntlet-spec claims, each with a
  verification method, an evidence pointer, and a status. Re-tallied
  mechanically at the verdict (grep over end-anchored status cells).

### Changed

- **Stop-requires-approval invariant hardened (llh.25 disposition).**
  The live `invStopRequiresApproval` check now excludes H3
  `stop_hook_active` re-entry guards (16ms `{}`-and-exit-0 anti-loop
  bail-outs were being mis-counted as approval leaks) and skips on
  bd-unavailable (a crashed bd daemon zeroes out label writes, which is
  an infra failure, not a gate leak).
- **Label-event deriver matches var-bound `bd` (llh.23).** The e2e
  label-transition deriver maps the variable-bound `bd` command shapes
  the live workflow emits, not only the literal seed-fixture forms, so
  `qa-pending → qa-approved` milestones derive from real runs.
- **Stop-hook fast-path extended (G2.gate-friction, llh.3/llh.17).**
  The doc-only fast path now also short-circuits beads-state-only diffs,
  empty post-denylist change-sets, and transient e2e fixture-script
  churn — the false-block cases the original fast path missed,
  reproduced as L2 cases first.
- **`bd close` stdout no longer pollutes the verdict (llh.20).** The
  `✓ Updated issue` banner bd prints on close is suppressed/redirected
  before `verify-before-stop.sh` emits its `{}` verdict, so the Stop
  hook's JSON is not corrupted by bd's success chatter.

### Fixed

- **Red-team P0: forgeable approval label (llh.18).** A bare `bd label
  add <task> qa-approved` (every agent has `bd`) released unreviewed
  code because the Stop predicate reduced to `has_label qa-approved`,
  skipping the impact-report refusal, audit comment, and rubric that
  `qa-gate.sh approve` enforces. Closed by the change-set-hash-bound
  approval record (see Added).
- **Red-team P1: decoy current-task redirect (llh.18).** The gate
  checked approval of whatever `current-task` pointed at and never bound
  it to the tracked changed files — approve a trivial decoy, repoint
  `current-task`, ship unrelated unreviewed code. Closed by binding the
  approval record to the change-set hash.
- **Fail-open in the P0 fix (llh.18).** The first iteration of the
  hash-bound check could pass when the hash was missing/unrecomputable;
  the release predicate now fails CLOSED in that case.
- **13 stale-doc claims (prove-or-remove).** Claims contradicted by the
  current code/config were removed or rewritten: the hook-event count
  (5 → 6 in settings.json + a 7th, SubagentStart, in hooks.json:
  H1/AR1/Q6/H2); the embedded agent-prompt blocks relabeled "Full
  Prompt" → excerpt (A2); the live-fixture count (six → seven, adding
  `rubric-revision-loop`: M4/AR10); the PostToolUse extension-allowlist
  description corrected to the actual build-artifact denylist + `{}`
  emit (AR2); the file-tracking trim threshold (500 → 1000 with 2x
  headroom: AR4); the golden-cassette PR-diff framing → debugging-
  reference framing (AR11); stale "Ultimate Workflow Plugin" branding +
  the unmeasured "in 5 minutes" claim (Q2); the "`bd doctor` all green"
  overclaim caveated to the CORE SYSTEM + GIT INTEGRATION must-pass set
  (Q4); and the hardcoded "v3.0.0" installer banner dropped in favor of
  pointing at the manifest (I7).

### Security

- **Red-team certification — the gate does not leak under live load.**
  The three mandatory red-team attacks (forge the label via `bd`
  directly; recreate the legacy marker file; interrupt the hook
  mid-evaluation) were reproduced and DEFEATED, and the failed attacks
  are the evidence (the marker is never read; the interrupt is a
  deliberate `{}`-and-exit-0 anti-loop pass-through that leaves prior
  gate state intact). Forensically confirmed on the paid python-django-
  bug run (llh.25): the gate BLOCKED the unreviewed `models.py` change
  on every Stop reaching change-set logic; the only "allow" Stops were
  H3 re-entry guards, and no unaudited completion path survived.
- **Residual threat boundary documented.** The fix raises the bar from a
  trivially-forgeable label to a change-set-bound record; it is not a
  cryptographic sandbox. An agent with arbitrary shell can still
  reproduce the hash-bound comment by hand (`bd comment add "QA-GATE
  APPROVED change_set_hash=$(impact-report.sh --hash-only)"`) — a stated
  THREAT-MODEL BOUNDARY at both the producer (`qa-gate.sh:730`) and
  consumer (`verify-before-stop.sh:1146`) sites; the full-shell-autonomy
  model precludes an HMAC keyed on a withheld secret. The orchestrator
  Bash-write vector is the related residual: Write/Edit/MultiEdit are
  structurally omitted from the orchestrator tool list and
  hook-blocked, but a write-shaped Bash command is not — closing it
  mechanically needs runtime-surfaced subagent identity this environment
  does not provide.

### Reverted

- **llh.19 (orchestrator Bash-write fail-closed).** The mechanical
  attempt to fail CLOSED on write-shaped Bash from the orchestrator was
  reverted to HEAD: `prevent-orchestrator-edits.sh` cannot attribute the
  caller in this identity-less runtime, so failing closed broke
  legitimate specialist Bash. The Bash-write vector is carried as a
  documented residual (see Security) rather than fixed.

## [3.4.1] - 2026-06-13

Hotfix release for the v3.4.0 line: model resolution was selecting the
stale `claude-opus-4-7` pin instead of the newest catalogue entry, and
the effort-default story was muddled by working-tree drift after the
`/effort` exposure. Three child tasks under epic
`claude-workflow-plugin-vlp` — `vlp.1` (resolver), `vlp.2` (effort
defaults), and the discovered-from defect
`claude-workflow-plugin-3fn` (manual-adopt subshell-loss) — all
`qa-approved` on `main` by 2026-06-13. First real-world adoption
recorded the same day: all seven agent pins moved
`claude-opus-4-7 → claude-fable-5`; the switch is logged on
meta-task `claude-workflow-plugin-4o2` (`Model selection log`,
comment 278) with the rollback command `/workflow-model
claude-opus-4-7`. Operator pain summary: zero — the switch was
quiet, the statusline now displays the active pin, and
SessionStart names the applied effort level.

### Fixed

- **Model resolver: generation-aware, never family-gated (vlp.1).**
  `.claude/scripts/model-select.sh` `pick_best` rewritten. Sort is now
  `created_at` DESC → `max_input_tokens` DESC → ranking-file position
  ASC. The family-gated `startswith` jq filter that silently dropped
  unknown families is removed; unknown families are first-class
  candidates and trigger an advisory warning, not exclusion. The
  `.claude/model-ranking` header rewritten end-to-end: `!prefix`
  lines are exclusions, non-`!` lines are tertiary tie-breakers, and
  the tier list itself is preserved. Regression test: spec X in
  `.claude/tests/component/specs/model-select.sh` exercises a
  faked listing with `claude-zenith-6` (unknown family, newest
  `created_at`) and asserts the resolver picks it; the META-TEST
  spec I proves a stub picker propagates to the agent pin (sensitivity).
- **Manual-adopt gate stdout-sentinel fix (3fn).** Defect filed
  during QA review of `vlp.1`: `MANUAL_ADOPT_REQUIRED=...` inside
  `pick_best` was a subshell-local assignment lost by `$(...)`
  command substitution, so the gate at `cmd_apply` was dead code
  and the LOUD adopt notice fired _while_ the pin was rewritten
  anyway — a 100 % silent-stale-pin contract violation on every
  unparseable `created_at`. Fix changes `pick_best`'s stdout
  contract to encode the signal: happy path emits `<id>\n`,
  manual-adopt path emits `MANUAL\t<id>\n`. `cmd_apply`,
  `cmd_resolve`, and `cmd_status` all parse the `MANUAL$'\t'*`
  prefix; `cmd_apply` short-circuits BEFORE `current_pin`
  comparison or rewrite. Tab byte is unambiguous — model ids are
  restricted to `[a-z0-9-]+` so no collision. Dead parent-shell
  global removed; file-header contract comment updated (lines 49–67).
  Regression: Spec M block (`ms-M` / `ms-ME` / `ms-MT` / `ms-MC` /
  `ms-MX`) adds 20 assertions including a META-TEST proving the new
  gate is sensitive (stripped `cmd_apply` rewrites the pin; honest
  `cmd_apply` does not).
- **`--refresh` flag bypasses the 1-hour listing cache (vlp.1).**
  `model-select.sh resolve --refresh` / `apply --refresh` forces a
  live `/v1/models` GET; `cache_fresh` returns false when
  `REFRESH=1`. Documented in the resolver header.
- **Statusline shows the active model pin (vlp.1).**
  `.claude/scripts/statusline.sh` appends `• model: <id>` to every
  output branch; the id is read from `orchestrator.md` frontmatter
  (no network). Fallback `(no model pin)` when the frontmatter line
  is absent. Two new assertions in
  `.claude/scripts/tests/phase5-synthetic-tests.sh` cover both the
  pin-present and pin-absent branches.
- **Six stale `Opus 4.7` doc references (vlp.1).** Model-agnostic
  prose now lands in `README.md:180`, `docs/ARCHITECTURE.md:419`,
  `CONTRIBUTING.md:34/61/208`, and `.claude/tests/README.md:79`.
  Historical references inside dated CHANGELOG sections (e.g. the
  `[3.0.0]` entry) are preserved as accurate snapshots of what
  shipped at the time.

### Changed

- **Effort default landed at the maximum persistable level (vlp.2).**
  `.claude/settings.json` carries `effortLevel: "xhigh"` (the cap
  accepted by the `effortLevel` field per
  `docs.claude.com/en/docs/claude-code/settings` — `"max"` is
  invalid in this field and is rejected at load) plus
  `env.CLAUDE_CODE_EFFORT_LEVEL: "max"` (the env var DOES accept
  `max` and persists across sessions per
  `docs.claude.com/en/docs/claude-code/env-vars`). Working-tree
  drift (`effortLevel: "max"` + deleted env var) reverted via
  deliberate Write. All seven agent frontmatter `effort: max` lines
  unchanged — `max` is the highest subagent-frontmatter value per
  `docs.claude.com/en/docs/claude-code/sub-agents`. SessionStart
  now emits a one-line note naming the applied level + the
  `/effort ultracode` opt-in path; the env value takes precedence
  per the cited docs, and the message names both when they differ.
  Ultracode itself is documented as a runtime opt-in (via `/effort
  ultracode`, `--settings`, or the SDK control request), not a
  durable default, because the docs explicitly state ultracode
  cannot be persisted in settings. CONTRIBUTING.md carries the
  verbatim docs quote and the three persistable knobs.
- **First real-world model adoption recorded (vlp.1, vlp.2).**
  2026-06-13: all seven agent pins moved from `claude-opus-4-7` to
  `claude-fable-5` (newest `created_at` in the live `/v1/models`
  listing). Settings `env.CLAUDE_LATEST_OPUS` updated. Audit comment
  on `claude-workflow-plugin-4o2` (`Model selection log`) records
  the transition plus the rollback `/workflow-model
  claude-opus-4-7`. Statusline now displays `• model:
  claude-fable-5`.

### Verification

- `make test` (L1 bash unit): **15 specs**, 0 fail.
- `make test-all` (L1 + L2 component): **21 specs / 454 assertions**,
  0 fail (+20 over the v3.4.0 baseline of 434; the M-block
  manual-adopt regression coverage).
- `cd .claude/tests/e2e && npm run test:unit`: **158 passed / 5
  skipped** (unchanged from v3.4.0 — the five skips are honest
  invariant-engine + trace-anchor artifact-missing skips, not
  green-washed).
- `make lint`: clean.
- `make check` (AgentLint): **87/100** core (composition stable
  post-pin change — the only S7 line that shifted is a new fixture
  path in `.claude/tests/component/specs/model-select.sh`, which
  matches the documented S7 fixture override convention; the
  numeric score is unchanged).
- Plugin manifest: `node -e JSON.parse(...)` confirms valid + version
  `3.4.1`.
- Guard suites green: `agents-manifest-parity`, `agent-time-budget`,
  `agent-mcp-tools-parity`, `no-nested-spawn-instructions`.

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

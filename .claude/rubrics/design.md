---
version: 1
name: design
---

# Design rubric (v1)

Scored by the design reviewer (`.claude/agents/design-reviewer.md`) against a design artifact at `docs/specs/<task-id>.md` — never against a code diff, and never composed with `default.md` or a domain overlay (backend/frontend/devops) or the bugfix overlay. Pulling code-review criteria into a design review is a category error: there is no diff yet, no tests to run, no F7 completion contract to check. This file is deliberately **standalone** — no `extends:` — and is the design reviewer's own single rubric. It is not selected through `qa.md`'s domain-label `cat` + `case` selector (that selector serves the QA/grader loop over implementation diffs, which never grades a design artifact — growing it with a design arm would add a reader nothing calls); the design reviewer reads this file directly, itself, as its one and only rubric. It also carries no `applies_to:` key, unlike `bugfix.md`'s: that key is read by no script (its only consumer is a test asserting `bugfix.md`'s own value), and reusing it here would misleadingly imply the same "applied additionally on top of default" overlay semantics this rubric deliberately does not have — prose above states applicability instead, the same way every rubric in this directory does regardless of whether it also carries the frontmatter key.

Each criterion below is a pass/fail assertion, exactly like the default/domain rubrics: one-line justification, no numeric score theater. Where `review-check.sh validate-design` already enforces something mechanically — a required prose section, the single `<!-- DESIGN-UNITS BEGIN/END -->` sentinel pair, `acceptance[]` entries as non-empty `{id, text}` objects, `depends_on` acyclicity, `escalation_reason` whenever `implementer_class` is `high` — that is a precondition to this rubric being reached at all, never a criterion of it. `review-check.sh` already draws this line in its own comments: it does not judge design quality; this rubric and the design reviewer do. The criteria below start where the schema check stops — is the design any *good*, not just well-formed.

## Criteria

### DS1. Acceptance criteria are observable and falsifiable.

`review-check.sh validate-design` already enforces that every `acceptance[]` entry is an object with a non-empty `id` and `text` — that is a schema precondition, not this criterion. This criterion asks whether `text`, having satisfied the schema, is actually checkable: it names an artefact, a command, or a record — the same falsifiability bar the designer's own controlling standard states — rather than a feeling ("works correctly", "is secure", "handles errors well" are not criteria). An acceptance entry that is schema-valid but not falsifiable fails DS1.

Second, folded into this criterion rather than given its own number (the same DS2/DS8 shape: two checks under one heading because both ask whether a criterion's `text` earns its own id, and neither has a more natural home) — claude-workflow-plugin-1dbz: `text` must not merely restate an invariant the gate already enforces on every unit regardless of what this design says. `green-check --phase before|after` (the green-to-green machinery every unit already carries) already proves "the pre-existing suite still passes" for every unit; a criterion whose whole content is that restatement is falsifiable in the technical sense but adds nothing this unit's acceptance array should be spending an id on, and `design-unit-align` LEG 3 has no honest test to name for it later — a real gap found in production, not a hypothetical one. This is not a reason to forbid asserting that existing behaviour survives a change; it is a reason to make the assertion specific. A criterion about preserving SPECIFIC existing behaviour remains legitimate and should name that behaviour so an implementer can point `criteria_tests` at the existing test(s) that already cover it — `criteria_tests` may cite a pre-existing test, not only a newly added one.

Evidence that satisfies it: quote the unit id and the acceptance `id`/`text` pair, and name the artefact, command, or record it points at. An entry whose `text` restates the unit's goal in different words, with nothing to run or read against it, fails the first half. An entry whose `text` restates only that the pre-existing suite or general behaviour is unaffected, with no SPECIFIC behaviour named, fails the second half even though `green-check` could technically be cited as its evidence — quote it and say which existing test(s) it should instead have pointed an implementer at, or that it should be dropped because the gate already covers it for free.

### DS2. The decomposition is complete and disjoint.

Two checks folded into one criterion. Completeness: every acceptance criterion implied by `Problem` and `Chosen approach` is owned by at least one unit — nothing the design promises is left with no unit responsible for delivering it. Disjointness: no two units declare the same path in `files[]` unless one `depends_on` the other — the designer's own controlling standard states that two units sharing a file can never run in parallel, and a later phase computes parallel batches from exactly this file-set intersection, so an undeclared overlap here silently serialises work that should have parallelised, or lets two units race on the same file with no ordering between them.

Evidence that satisfies it: a one-line trace from each acceptance criterion to the unit that owns it, plus a pairwise check of every unit's `files[]` against every other unit's. An unowned criterion, a criterion two units both claim, or a file two units declare with no `depends_on` edge between them fails DS2.

### DS3. Every unit with a dependent declares its interface; verification is a real command.

`files`, `verification` (non-empty), and the schema shape are already enforced mechanically. `interfaces` is schema-optional. This criterion asks: for every unit that has at least one dependent (another unit's `depends_on` names it), does its `interfaces` state the contract the dependent unit is building against, rather than leaving that implementer to reverse-engineer it from source code that does not exist yet? It also asks whether `verification`, though present, is an actual command someone can run rather than "tests should pass" restated.

Evidence that satisfies it: for each unit with a dependent, quote its `interfaces` entry; for each unit, quote a `verification` string that is a real invocation. A depended-upon unit with an empty `interfaces` array, or a `verification` that names no command, fails DS3.

### DS4. At least two approaches were considered, each rejected for a stated technical reason.

`Approaches considered` names at least two candidates, and every rejected one carries a reason grounded in an actual technical constraint — a measurement, a call site, an existing pattern it would have broken, a scaling limit — never a bare preference ("simpler", "cleaner") stated without the constraint that makes it so. This is the design phase's own accountability model, applied one step earlier than usual: a rejection with no stated constraint is a decision nobody can revisit later when that constraint stops holding.

Evidence that satisfies it: quote each rejected approach's stated reason and name the constraint or measurement behind it. A design with only one approach, or a second approach dismissed by adjective alone, fails DS4.

### DS5. Out of scope is stated and substantive.

`Out of scope` (the prose section) names at least one adjacent thing this design deliberately does not do. Empty or boilerplate ("N/A", "everything in the problem statement is in scope") fails this criterion: every design this rubric reviews has some adjacent temptation an implementer could pull in without meaning to, and naming it up front is what lets a later diff be checked against a boundary the design actually stated, rather than one inferred after the fact.

Evidence that satisfies it: quote the out-of-scope entry and, where useful, the adjacent capability it declines. A section present in name only fails DS5 exactly as an absent section would.

### DS6. Global constraints are copied verbatim, not paraphrased.

When the spawning seat handed the designer a `## Global Constraints` block (the epic-level convention in `orchestrator.md`'s SPEC-doc section), the artifact's own `Global constraints` section reproduces every value byte-for-byte — a version floor, a platform requirement, a naming rule — rather than restating it in different words. Paraphrase is where a constraint quietly drifts: "bash 3.2" restated as "an older bash" is no longer checkable by anyone downstream who does not also have the original epic spec open.

Evidence that satisfies it: a value-by-value comparison of the epic's Global Constraints block against the design's Global constraints section. Any value that is reworded rather than copied fails DS6 — not only a value that was dropped.

### DS7. Every new file or script is justified against reuse.

Mechanises this release's own non-negotiable cross-cutting principle (`docs/plans/v5-design-phase.md`: "Reuse before building... Every capability must be expressed as one of — a new agent file, a new rubric criterion, a new field or enum value on an existing contract, a deterministic check, or a new condition in an existing gate. No new harnesses. If a phase seems to need one, stop and report before building it."). Every unit whose `files[]` introduces a path that does not exist in the tree today carries, in its goal or risks text, a one-line reason an existing file, script, or gate condition could not have been extended to cover the same capability instead.

Evidence that satisfies it: for each new path in any unit's `files[]`, quote the one-line justification and name the existing artefact it considered and rejected extending. A new file or script with no such justification fails DS7 regardless of how well-specified the rest of the unit is.

### DS8. The design contradicts no institutional memory, and no capped-out review stands in for a verdict.

Two checks, one criterion, because neither has a more natural home among DS1-DS7. First: the design does not reintroduce a documented `LESSONS.md` anti-pattern, and does not propose a record grammar, subcommand name, or field name that collides with or duplicates one that already ships (`design-record` is already taken by the designer's own artifact-recording command; a design that reuses that name, or reinvents the `DESIGN-ARTIFACT` record's shape under a different one, fails here).

Second — folded into this criterion by explicit operator directive rather than by the original plan, because no other criterion is about the review *process* rather than the design's content: a verdict recorded only because an iteration cap was reached, with no criterion above independently earning `pass` on its own merits, is incomplete by construction and never counts as this rubric being satisfied. `verdict` and `stop_condition` are the only two ways a review concludes on its own terms; every `cap:*` value is the other case — the review ran out of turns or budget, not out of things to find. `review-check.sh`'s gate command already exposes this mechanically, as a `cap_terminated` boolean derived from `stopped_by`, for exactly this reason. A design-satisfied predicate built on top of this rubric that accepts a cap-terminated loop — or a cap-terminated independent code review — as sufficient evidence is reporting a floor as a ceiling.

Evidence that satisfies it: (a) a named sweep of the design against `LESSONS.md`'s current entries and the record grammars already in use, stating which lesson or grammar it might have collided with and why it does not; (b) for the current review iteration, a statement of whether the iteration cap has been reached and, if so, explicit confirmation that every `criterion_results` entry above is still judged on its own merits rather than waved through under cap pressure. A collision with a lesson or an existing record grammar fails DS8 outright; a `satisfied` verdict issued at or after the iteration cap with any criterion that would not independently justify `pass` also fails it, regardless of how much iteration budget remains.

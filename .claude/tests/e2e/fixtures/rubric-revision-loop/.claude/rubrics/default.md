---
version: 2
name: default
---

# Default rubric (v2)

Applies to every task graded under the rubric-grader QA loop (spec Phase A). Each criterion below is a pass/fail assertion the grader evaluates from the grading packet: `bd show` for the task, the SPEC doc, the diff of the files listed in `.qa-tracking/changed-files.txt`, the F7 completion contract returned by the specialist, and `LESSONS.md`. One-line justification per criterion. No numeric score theater — pass or fail.

The criteria are intentionally short and checkable. Where the criterion needs context (boundary-mock fidelity, F7 fields), the "Evidence that satisfies it" line names the artefact the grader looks at.

## Criteria

### C1. Behavior matches the task description and SPEC.

The shipped diff implements the behavior the task description asks for, and matches the goal + acceptance criteria stated in the attached SPEC doc (read via `bd_doc_read(task_id, name="spec")`). Out-of-scope behavior the SPEC explicitly excludes is NOT in the diff.

Evidence that satisfies it: a 1-2 sentence walk-through that maps every user-visible behavior in the SPEC to a code path in the diff (or to a deliberate, documented deferral in the F7 `decisions` array). A diff that adds plausibly-related behavior the SPEC does not name fails this criterion — that is scope creep.

### C2. Tests added exercise user behavior rather than implementation.

Where the diff introduces new behavior, the diff also introduces tests that assert against the user-visible contract (return shape, side effects, error envelope, accessibility role, status code) rather than against the implementation's private structure (function-name mocking, line-coverage gymnastics, internal control-flow assertions).

Evidence that satisfies it: at least one test in the diff that would still pass if the implementation were rewritten while keeping the user contract identical. A test that asserts only against private symbols, internal call counts, or framework boilerplate fails this criterion.

### C3. The F7 completion contract carries all seven fields with substantive `llm_observations`.

The specialist's structured completion payload includes `task_id`, `files_changed`, `tests_added`, `decisions`, `blockers`, `llm_observations`, and `context_coverage`. `llm_observations` is non-trivial narrative — what surprised the specialist, what was unclear, what they noticed and did not act on. A boilerplate one-liner like "no observations" fails this criterion (principle 9: `llm_observations` is mandatory and substantive).

Evidence that satisfies it: each of the seven fields is present and the `llm_observations` paragraph is the kind of thing a human engineer would say at a stand-up. C3 scores presence-of-seven plus the quality of `llm_observations`; the quality of `context_coverage` is C8's job, so a payload can pass C3 on presence and still fail C8 on substance.

### C4. No unrelated scope in the diff.

Every file the specialist touched serves the task. Drive-by refactors, formatting churn on untouched lines, and "while I'm here" cleanups that exceed the task brief fail this criterion — they should be filed as paired follow-up Beads tasks instead.

Evidence that satisfies it: the diff's file list maps cleanly to the SPEC's deliverables; any incidental change is either trivial (one-line typo fix) or explicitly justified in the `decisions` array.

### C5. J26 modules relevant to the diff are addressed.

Where the diff touches a domain covered by the J26 security taxonomy (SECRETS, INJECTION, AUTH, CONFIG, DEPS, AI, MOBILE, DATA — see `docs/AGENTS.md`), the diff demonstrates that the relevant modules were considered. Untouched J26 domains are out of scope.

Evidence that satisfies it: the `decisions` array (or the SPEC) names which J26 modules apply, and the diff shows defences in those modules (input validation at the trust boundary, parameterised queries, narrow CORS, audited logging, etc.). A diff that touches user input handling without naming INJECTION fails this criterion.

### C6. Docs updated where behavior changed.

When the diff changes user-visible behavior, the documentation that describes that behavior is updated in the same change. This includes `CHANGELOG.md`, README sections, `docs/*.md`, command help text, and SPEC docs the diff renders out of date.

Evidence that satisfies it: a docs-only file in `files_changed` paired with each behavioral change, or a deliberate `decisions` entry stating why a doc deferral is correct (e.g. an internal refactor that ships without user-visible change). A behavioral change that ships with no doc update and no deferral note fails this criterion.

### C7. Boundary-mock fidelity (LESSONS.md lesson 2).

When the diff introduces or modifies mocks of boundaries the project does not control (third-party HTTP APIs, external SDKs, system calls, message-bus payloads), every such mock derives its shape from a fixture extracted from the real downstream producer's spec (OpenAPI, proto file, SDK source, vendor docs). The fixture's source is cited in a comment, the `decisions` array, or `llm_observations`.

**Automatic needs_revision:** circular pass-through assertions are an immediate fail. A mock that feeds `body.error` so a test can assert `body.error` proves nothing — it tests the test's own setup, not the production behavior. Cite `LESSONS.md` lesson 2 in the justification.

Evidence that satisfies it: every new boundary mock points at a fixture file (`.fixtures/`, `__fixtures__/`, `testdata/`) carrying a snapshot of the producer's payload, and the fixture has a comment naming the source (URL, commit, SDK version). Tests assert against the producer's contract, not against the mock's own input.

### C8. `context_coverage` names what was read, what was skipped, and the largest unknown.

The F7 payload's seventh field records three things, in order: the sources the specialist actually read to ground the change; the sources they deliberately did NOT read, and why; and the largest remaining unknown the work ships on. It fails on the same three-way taxonomy C3 applies to `llm_observations` — **empty**, **boilerplate** ("read the relevant files", "full context gathered"), or **detached from the work**: sources named that the diff plainly does not depend on, or the file carrying the diff's central change missing from the list. A coverage note with no deliberate omission in it is boilerplate by construction, because there is always one.

This is not a new principle. It is the evidence-before-fix discipline (`docs/AGENTS.md`) applied *before* the change rather than after — that protocol arms only on bug-typed tasks, and the ordinary feature work that produced the motivating 14-PR speculative-fix chain never gets typed as a bug at all.

Evidence that satisfies it: named files or artefacts (paths, doc names, task ids, log lines) in the "read" part; at least one explicit omission carrying its reason; and an unknown concrete enough that a reviewer could act on it. Grade it against the diff, not against its own confidence — the sources named should be the ones the change actually depends on.

# Lessons ledger

Production lessons learned the hard way. Each entry is a single-sentence
takeaway, traceable to the Beads task(s) that produced it, with the date
it was first recorded.

Add new entries via `.claude/scripts/lessons.sh add '<lesson>' --source <task-id>`
— never hand-edit. The helper deduplicates by normalized text (case- and
whitespace-insensitive), so repeating an existing lesson appends the new
source to that entry rather than creating a duplicate. The only legitimate
hand-edit is pruning entries that are no longer relevant.

The orchestrator reads this file during planning (see `orchestrator.md`),
the grader (Phase A) receives it in the grading packet, and the QA agent
proposes additions at epic close. Treat it as the institutional memory the
plugin runs against, not a static reference doc.

## Lessons

- Parallel agents in the same working tree contaminate each other's branches; concurrent specialists require worktree isolation. <!-- sources: claude-workflow-plugin-e0d.7 --> <!-- recorded: 2026-06-11 -->
- Boundary mocks must use the real downstream producer's shape, pinned via a fixture extracted from the producer's spec — never invented. A mock that feeds `body.error` so the test can assert `body.error` is circular and proves nothing. <!-- sources: claude-workflow-plugin-e0d.7 --> <!-- recorded: 2026-06-11 -->

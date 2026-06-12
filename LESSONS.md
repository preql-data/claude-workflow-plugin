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
- New agent files must be registered in .claude-plugin/plugin.json agents[] in the same commit that creates them; an unregistered agent is silently invisible to the SDK — no error surfaces. Guard: agents-manifest-parity test. <!-- sources: claude-workflow-plugin-l1r.5 --> <!-- recorded: 2026-06-11 -->
- Subagents cannot spawn other subagents in the Claude Code runtime (docs: sub-agents page — Agent(agent_type) has no effect in subagent definitions). Any agent-spawning step must live at the root conversation level; design multi-agent handoffs as root-orchestrated relays, never nested spawns. <!-- sources: claude-workflow-plugin-l1r.5 --> <!-- recorded: 2026-06-11 -->
- Interface examples must be executed by a test: the Makefile's own usage string (make test-live FIXTURE=node-react-auth) was broken for the one fixture whose spec file is scenario-named — nothing ever ran the documented invocation. Caught only when a paid live run failed fast. Any CLI surface a doc or help text advertises needs an L2 assertion that executes that exact invocation (dry-run mode where the real one costs money). <!-- sources: claude-workflow-plugin-366.4 --> <!-- recorded: 2026-06-11 -->
- Prose cues do not reliably drive subagent tool usage: across 4 live runs, QA made zero impact_of calls even when its task prompt contained the exact tool name, alias, target symbols, and invariant name. When a workflow REQUIRES a tool call, make it mechanical (compute it where calls are reliable — e.g. orchestrator at root — and pass results down), don't prompt for it. <!-- sources: claude-workflow-plugin-n6d --> <!-- recorded: 2026-06-12 -->
- Rendered fixture installs pin plugin scripts at render time: the fixture's verify-before-stop.sh predated the cue fix by one commit, so a hook-template change never reached the live run. Script-level fixes require re-rendering fixture installs (or a version check at run start) before they affect live validation. <!-- sources: claude-workflow-plugin-366.10 --> <!-- recorded: 2026-06-12 -->
- Never run QA review concurrently with a builder in the same working tree: QA attributed the parallel C.2 task's freshly-written files to the C.1 task under review and blocked it for scope creep. Sequence QA after all writers finish, or give builders worktree isolation (orchestrator.md 4b exists for exactly this). <!-- sources: claude-workflow-plugin-n45.1 --> <!-- recorded: 2026-06-12 -->
- Manifest-declared assets must be presence-asserted at the install target: install.sh's hardcoded agent list silently dropped grader.md for two releases (v3.2.0-v3.3.0) — every fresh install was missing the rubric loop's grader while the repo's own tests stayed green. Glob-copy from the manifest source of truth and add an installer-spec presence assertion for every plugin.json agents[]/commands[] entry. <!-- sources: claude-workflow-plugin-n45.4 --> <!-- recorded: 2026-06-12 -->

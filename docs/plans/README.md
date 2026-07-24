# Plans

This directory holds approved execution plans as first-class repo
artifacts. Plans live here (not in Slack, Confluence, or a private chat
log) so a fresh agent or human contributor can read them after the
session that produced them ends.

## Index

- `v4-trimodel.md` — the v4.0.0 tri-model workflow: Fable-class orchestrator,
  Opus-class implementers, optional GPT-5.6-Sol reviewer lane via Codex MCP;
  mechanical sign-off separation ("nobody signs off on their own work"),
  arbitration, worktree-aware gate scoping, and the ultracode-vs-max effort
  verdict. Phases V0-V5, one Beads epic per phase. Verified platform facts
  and the executable step plan live in the session plan mirror
  (`~/.claude/plans/v4-0-0-tri-model-lively-deer.md`).
  **Status**: Active (started 2026-07-24).

- `verification-suite.md` — Phases 0/A/B/C shipping v3.1.0 through v3.4.0:
  MCP path hotfix, binding QA-gate escalation, best-model auto-selection,
  evidence-before-fix protocol, lessons ledger, invariant-based live testing
  (golden-cassette retirement), rubric-grader QA loop, code-graph MCP,
  mutation testing with LLM-judge filter. One Beads epic per phase.
  **Status**: Complete (v3.1.0-v3.4.0 shipped; the follow-on Release
  Acceptance Gauntlet closed as v3.5.0 on 2026-06-14 — see CHANGELOG).

- `v3-upgrade.md` — the consolidated v3 plan executed across Phases 0-7
  (claude-workflow-plugin-y4a). Originally drafted as `dynamic-marshmallow`
  in `~/.claude/plans/`; mirrored here for posterity.
  **Status**: Complete (Phases 0-7 verified in HANDOFF.md; G8 harness
  shipped 2026-05-11).

## Adding a new plan

1. Write the plan as a single markdown file in this directory.
2. Open a Beads epic linked to the plan via `bd doc write`.
3. Reference the plan from `CLAUDE.md` only if it is the active plan;
   archived plans stay discoverable via this README's index.
4. When the plan is fully executed, leave the file in place. Plans are
   historical artifacts, not living documents — superseding plans link
   forward via this README.

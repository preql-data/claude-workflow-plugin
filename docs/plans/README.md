# Plans

This directory holds approved execution plans as first-class repo
artifacts. Plans live here (not in Slack, Confluence, or a private chat
log) so a fresh agent or human contributor can read them after the
session that produced them ends.

## Index

- `v4.1-upgrade-wave.md` — v4.1.0 minor release: U0 installer v3.5→v4
  upgrade path (priority), U1 follow-up burn-down (gz3/gl6/bjx), U2
  worktree sweeper + scratchpad denylist (prm), U3 context-gathering
  ledger, U4 vendored superpowers skills, U5 staging e2e QA, U6 gated
  depth-3 migration.
  **Status**: In progress (started 2026-07-26); session plan mirror at
  `~/.claude/plans/v4-1-0-upgrade-gleaming-karp.md`; epics
  claude-workflow-plugin-0jk (U0), -waz (U1), -0yg (U2), -gio (U3), -q37
  (U4), -f2t (U5), -7be (U6 gate pre-checked FAILING → deferral path),
  -uvk (closeout). The U6 gate was pre-checked against the live
  changelog on 2026-07-26 and **fails**: the depth-3 default was 2 days
  old and the prior flip landed 3 days before it, far short of the
  30-day hold. U6 therefore executes as its documented deferral path —
  the `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` pin stays, with the
  evidence and a next-check date recorded on the standing task.

- `v4-trimodel.md` — the v4.0.0 tri-model workflow: Fable-class orchestrator,
  Opus-class implementers, optional GPT-5.6-Sol reviewer lane via Codex MCP;
  mechanical sign-off separation ("nobody signs off on their own work"),
  arbitration, worktree-aware gate scoping, and the ultracode-vs-max effort
  verdict. Phases V0-V5, one Beads epic per phase. Verified platform facts
  and the executable step plan live in the session plan mirror
  (`~/.claude/plans/v4-0-0-tri-model-lively-deer.md`).
  **Status**: Complete (2026-07-24 → 2026-07-26). **All phases V0-V5 are
  done** and shipped as v4.0.0, including V5 item 5 — the two cost-gated live
  tri-model validations (`claude-workflow-plugin-d2j.2`), which both PASSED on
  2026-07-26: a real `gpt-5.6-sol` review turn with Codex connected, and the
  Claude lane with Codex absent, producing byte-identical gate decisions from
  two different reviewers. Scope of that validation, per
  `docs/RELEASE_AUDIT.md` rows TM7/TM14: a small synthetic subject driven
  through the gate scripts directly, so no live e2e trace was captured.
  Tagged and released as `v4.0.0` on 2026-07-26 (commit `7b57a13`); the
  epic-closing bd sync is `86d238c`.

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

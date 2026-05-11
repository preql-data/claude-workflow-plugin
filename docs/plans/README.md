# Plans

This directory holds approved execution plans as first-class repo
artifacts. Plans live here (not in Slack, Confluence, or a private chat
log) so a fresh agent or human contributor can read them after the
session that produced them ends.

## Index

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

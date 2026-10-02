# Plans

This directory holds approved execution plans as first-class repo
artifacts. Plans live here (not in Slack, Confluence, or a private chat
log) so a fresh agent or human contributor can read them after the
session that produced them ends.

## Index

- `v5-design-phase-plan.md` — **the plan for v5.0.0, and the one to brief from.**
  Mirrored 2026-08-12 from `~/.claude/plans/v5-0-0-design-stateless-wilkinson.md`
  (`claude-workflow-plugin-omiv`), byte-for-byte below a provenance comment. It
  carries the six planning decisions, the fourteen corrections to the directive
  **in full**, and the per-phase detail established from source: Phase P's P0–P9
  breakdown, D1's artifact schema, record grammars and two-layer edit ban, D2's
  DS1–DS8 rubric and enforcement sites, D7's release checklist.
  **Status**: see the `v5-design-phase.md` entry below — one arc, two documents.
  **Read this one first.** The directive entry below is the input it was written
  against; where they disagree, this file governs.

- `v5-design-phase.md` — **the DIRECTIVE for v5.0.0** (the operator's original
  request), preserved verbatim with a fourteen-item summary of the correction
  layer appended. It is an input, not a plan: briefs citing sections by name
  ("Corrections to the directive", "Phase D0 — role classes 3 → 5") are citing
  the plan above, whose sections do not exist in this file. Kept under its
  original filename because `qa-gate.sh`, `review-check.sh` and `HANDOFF.md`
  already cite that path. Its scope, for the index: design becomes a
  first-class, independently reviewed, continuously enforced workflow phase.
  Phase P
  (prerequisite hardening of the signals v4.1 proved unreliable — `94d`
  change-set coverage, `qzv` label binding, `1nz` concurrent writers, `dxz`
  code-graph, `8zi`/`2ty`, runtime contract validation, `LESSONS.md` scoping,
  `ce5`, stale-task triage), D0 role classes 3→5, D1 designer + design
  artifact, D2 design review loop, D3 grilling precondition, D4 decomposition
  conformance + computed batching, D5 green-to-green with spec injection, D6
  coherence rollup, D7 release.
  **Status**: IN PROGRESS (started 2026-08-02) on branch `v5/design-phase`,
  cut from `main` at `bb8fce7`. The plan file carries a **correction layer**
  at the end — six planning decisions and fourteen corrections established
  from source — which governs wherever it disagrees with the directive text
  preserved above it. Notable departures already recorded: Phase P folds into
  5.0.0 rather than shipping separately; the `v4.1.0` tag stays put; identity
  separation is role-level with model collapse as a warning, not a block;
  Linear ships as an explicitly UNVERIFIED adapter with `docs/specs/` as the
  real artifact. **Unplanned**: `bd` was upgraded 0.47.1 → 1.1.2
  (`claude-workflow-plugin-vfh`) after the committed `.beads/issues.jsonl`
  was found to be unimportable — a fresh clone recovered zero issues.
  Session plan mirror at `~/.claude/plans/v5-0-0-design-stateless-wilkinson.md`,
  now also in-repo as `v5-design-phase-plan.md` (D1 / `omiv`).

- `v4.1-upgrade-wave.md` — v4.1.0 minor release: U0 installer v3.5→v4
  upgrade path (priority), U1 follow-up burn-down (gz3/gl6/bjx), U2
  worktree sweeper + scratchpad denylist (prm), U3 context-gathering
  ledger, U4 vendored superpowers skills, U5 staging e2e QA, U6 gated
  depth-3 migration.
  **Status**: All seven phases resolved (2026-07-26 → 2026-07-30);
  release closeout `claude-workflow-plugin-uvk` still open. The plan was
  **not executed as written** — a dated status block at the top of the
  plan file carries the correction layer, and the plan text below it is
  preserved verbatim. **Shipped in full**: U0 installer upgrade path
  (-0jk, eight sub-tasks), U1 follow-up burn-down (-waz), U2 sweeper +
  denylist (-0yg). **Reduced**: U3 (-gio) shipped as the
  `context_coverage` contract field plus rubric C8 rather than the
  ledger/frontier harness, which is deferred on -gio.1 behind a
  three-instance evidence bar; U4 (-q37) shipped as one vendored
  reference doc plus a practice harvest rather than five registered
  skills. **Cancelled**: U5 staging e2e QA (-f2t) — most external
  dependencies, largest security surface, only phase needing live paid
  runs, and a provider abstraction that stays speculative until a second
  project validates it. **Closed as need-triggered, not
  calendar-deferred**: U6 depth-3 migration (-7be) — depth-1 is itself
  the mechanism that stops an implementer procuring its own review, so
  the `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` pin stays and the
  standing task -1bn carries a condition rather than a date; the
  2026-08-23 next-check date is **retired**. **Unplanned**: a P0 (-2br)
  that left every installed target running no workflow at all displaced
  the planned sequence and shipped first. Session plan mirror at
  `~/.claude/plans/v4-1-0-upgrade-gleaming-karp.md`.

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
  epic-closing bd sync is `86d238c`. (`bd sync` was removed in bd 1.1.2;
  the equivalent today is `beads-ledger.sh reconcile --apply` — this line records what
  happened in July, so the command name stays as it was.)

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

0. **Mirror the PLAN, not the request that produced it.** A planning session
   normally leaves two documents: the operator's directive and the plan written
   against it, the second of which exists precisely because the first is wrong
   somewhere. Copying only the directive is the shape that produced
   `claude-workflow-plugin-omiv` — every brief for v5 cited correction sections
   that were not in the file it pointed at, and work stayed correct only because
   the orchestrator carried the corrections inline each time. If both documents
   are worth keeping, index both and say in each which one governs.
1. Write the plan as a single markdown file in this directory.
2. Open a Beads epic linked to the plan via `bd doc write`.
3. Reference the plan from `CLAUDE.md` only if it is the active plan;
   archived plans stay discoverable via this README's index.
4. When the plan is fully executed, leave the file in place. Plans are
   historical artifacts, not living documents — superseding plans link
   forward via this README.

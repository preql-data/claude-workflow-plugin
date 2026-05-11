# HANDOFF — claude-workflow-plugin

This file is the cross-session handoff record. Read it first when picking up
work on this repository.

## Current state

- Active plan: `docs/plans/v3-upgrade.md` (Phases 0-7).
- Active phase: Phase 7 — AgentLint validation. Beads task
  `claude-workflow-plugin-y4a.14` (label `qa,qa-pending` -> moves to
  `qa-approved` when this phase closes).
- Parent epic: `claude-workflow-plugin-y4a` (v3.0.0 upgrade).

## Verify conditions for "Phase 7 complete"

A new session can confirm readiness without re-running everything by
checking these assertions:

- assert: AgentLint score >= 80/100. The before/after scores are recorded
  in `docs/AGENTLINT_REPORT.md`. Re-run via `make check`.
- assert: `bash tests/run-tests.sh` exits 0 and reports
  `Passed: 20  Failed: 0` (or higher) for the bd-github-link suite plus
  any phase 5 synthetic tests that apply to the local env.
- assert: `node -e 'JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8"))'`
  exits 0 (plugin manifest is valid JSON).
- assert: `bd list --label qa-approved --status open --json | jq 'length >= 1'`
  shows that claude-workflow-plugin-y4a.14 is approved (when this phase
  is signed off by the QA agent).
- assert: every entry in `.claude/agents/*.md` has a `model:` field. Run
  `grep -L '^model:' .claude/agents/*.md` and confirm an empty output.
- assert: PASS — no Stop-hook circuit breaker regression. Run the synthetic
  test `echo '{"stop_reason":"end_turn","stop_hook_active":true}' | bash .claude/scripts/verify-before-stop.sh`
  and confirm it exits 0 with `{}` output.
- assert: READY — install + uninstall round-trip. Run
  `bash install.sh /tmp/cwp-handoff-$$ && bash /tmp/cwp-handoff-$$/uninstall.sh`
  and confirm both succeed without errors.

## Recent decisions

- 2026-05-09 (Phase 7): AgentLint flagged `H4 dangerous Bash auto-approve`,
  `S9 personal email in git history`, and `W2/W4/W11 CI / linter / test-required
  gate`. All four are deferred-with-rationale per principle 3 (full autonomy)
  and principle "G8 deferred" (CI harness lives in the deferred testing plan).
  See `CONTRIBUTING.md` -> "Design overrides vs. AgentLint" for the full list.
- 2026-05-08 (Phase 6): bd-mcp + code-context-mcp ship as in-tree node servers
  under `.claude/mcp/`. The `.mcp.json` references them via
  `${CLAUDE_PLUGIN_ROOT}` so they relocate cleanly.
- 2026-05-08 (Phase 4): QA gate is iterative with regression coverage; the
  Stop hook reads `stop_hook_active` to avoid infinite loops (AgentLint H3).

## Where to look next

- For the queue of in-flight tasks: `bd ready` (ready to start),
  `bd blocked` (waiting on dependencies), `bd list --label qa-pending`.
- For the next phase plan: `docs/plans/v3-upgrade.md` Phase 7 section.
- For deferred work: search for `discovered-from:claude-workflow-plugin-y4a`
  in Beads — these are the follow-up tasks Phase 0-7 surfaced.

## Owner

Maintainer: see `.git/config` and the email in `SECURITY.md`. Not paged on a
schedule; cadence-driven from the plan.

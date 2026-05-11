# HANDOFF — claude-workflow-plugin

This file is the cross-session handoff record. Read it first when picking up
work on this repository.

## Current state

- Plan `docs/plans/v3-upgrade.md` (Phases 0-7) is **complete**. The G8
  end-to-end test-harness epic and the post-G8 closeout pass also
  shipped. Everything landed on `main` by 2026-05-11.
- Parent epic: `claude-workflow-plugin-y4a` (v3.0.0 upgrade) — closed.
- Per-phase release notes: `CHANGELOG.md` `[3.0.0] - 2026-05-11`.
- Open tickets: `bd ready` (ready to start), `bd blocked` (waiting on
  dependencies), `bd list --label qa-pending` (awaiting QA). The known
  deferrals are `claude-workflow-plugin-8oz` (SHA-pin GitHub Actions,
  P2) and `claude-workflow-plugin-a7y` (gitleaks CI job, P2).

## Verify conditions for "v3 + G8 + closeout shipped"

A new session can confirm readiness without re-running everything by
checking these assertions:

- assert: AgentLint score >= 80/100. The Phase 7 baseline was 90/100;
  post-G8 Phase F sits at 87/100 (-3 from the new tag-pinned actions in
  `test.yml`). See `docs/AGENTLINT_REPORT.md`. Re-run via `make check`.
- assert: `make test-all` exits 0 (offline gate — L1 bash unit + L2
  component + L3 vitest unit). Live L3 is gated on `ANTHROPIC_API_KEY`
  and runs in CI.
- assert: `npm run test:unit` reports `55/55` passing for the L3 vitest
  unit tier.
- assert: `node -e 'JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8"))'`
  exits 0 (plugin manifest is valid JSON).
- assert: every entry in `.claude/agents/*.md` has a `model:` field. Run
  `grep -L '^model:' .claude/agents/*.md` and confirm an empty output.
- assert: PASS — no Stop-hook circuit breaker regression. Run the synthetic
  test `echo '{"stop_reason":"end_turn","stop_hook_active":true}' | bash .claude/scripts/verify-before-stop.sh`
  and confirm it exits 0 with `{}` output.
- assert: READY — install + uninstall round-trip. Run
  `bash install.sh /tmp/cwp-handoff-$$ && bash /tmp/cwp-handoff-$$/uninstall.sh`
  and confirm both succeed without errors.

## Recent decisions

- 2026-05-11 (post-G8 closeout): README rewrite (325 -> 164 lines),
  `install.sh --upgrade` v2 detector + migrator, `install.ps1` v2
  redirect to `install.sh`, CI portability with `BD_SHIM_ONLY=1` opt
  and glibc-binary verification. Closed bugs 0wk.2 / 0wk.7 / 0wk.8.
- 2026-05-09 to 2026-05-11 (G8): End-to-end test harness with five
  tiers (L1 bash unit, L2 component, L3 vitest unit, L3 live e2e with 6
  fixtures + golden cassettes, L4 daily drift watch) and GitHub Actions
  CI (7 jobs).
- 2026-05-09 (Phase 7): AgentLint flagged `H4 dangerous Bash auto-approve`,
  `S9 personal email in git history`, and `W2/W4/W11 CI / linter / test-required
  gate`. Of those: W2 was resolved by G8 (CI now exists); H4 / S9 / W4 / W11
  remain deferred with rationale per principle 3 (full autonomy) and
  the AgentLint detector limitations documented in
  `docs/AGENTLINT_REPORT.md`. See `CONTRIBUTING.md` -> "Design overrides
  vs. AgentLint" for the full list.
- 2026-05-08 (Phase 6): bd-mcp + code-context-mcp ship as in-tree node servers
  under `.claude/mcp/`. The `.mcp.json` references them via
  `${CLAUDE_PLUGIN_ROOT}` so they relocate cleanly.
- 2026-05-08 (Phase 4): QA gate is iterative with regression coverage; the
  Stop hook reads `stop_hook_active` to avoid infinite loops (AgentLint H3).

## Where to look next

- For the queue of work in flight: `bd ready` (ready to start),
  `bd blocked` (waiting on dependencies), `bd list --label qa-pending`.
- For deferred AgentLint Safety follow-ups: `docs/AGENTLINT_REPORT.md`
  "Phase 8+ Roadmap" section (`8oz`, `a7y`).
- For per-phase release detail: `CHANGELOG.md` `[3.0.0] - 2026-05-11`.
- For deferred work surfaced during execution: search for
  `discovered-from:claude-workflow-plugin-y4a` in Beads — those are the
  follow-up tasks Phase 0-7 + G8 surfaced.

## Owner

Maintainer: see `.git/config` and the email in `SECURITY.md`. Not paged on a
schedule; cadence-driven from the plan.

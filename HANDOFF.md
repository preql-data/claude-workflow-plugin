# HANDOFF — claude-workflow-plugin

This file is the cross-session handoff record. Read it first when picking up
work on this repository.

## Current state

- Plan `docs/plans/v3-upgrade.md` (Phases 0-7) is **complete**. The G8
  end-to-end test-harness epic and the post-G8 closeout pass also
  shipped. Everything landed on `main` by 2026-05-11.
- Plan `docs/plans/verification-suite.md` Phase B shipped 2026-06-12
  as **v3.3.0**. Parent epic: `claude-workflow-plugin-366` with two
  child tasks `366.1` (code-graph-mcp server: scaffold, indexer, 7
  tools, 31 tests) and `366.2` (manifests, installer test, agent
  wiring, migration) both `qa-approved`. Phase A's live validation
  also completed in this cycle (3 runs, defects fixed in-flight,
  trace anchored offline) — Phase A entry amended in the
  `[3.2.0]` section. Phase C remains pending.
- Plan `docs/plans/verification-suite.md` Phase A shipped 2026-06-11
  as **v3.2.0**. Parent epic for Phase A:
  `claude-workflow-plugin-l1r` with two child tasks `l1r.1` (rubric
  plumbing) and `l1r.2` (grader + wiring) both `qa-approved`. Live
  validation completed 2026-06-12 (recorded in the `[3.2.0]`
  CHANGELOG amendment alongside Phase B's closeout).
- Plan `docs/plans/verification-suite.md` Phase 0 shipped 2026-06-11
  as **v3.1.0**. Parent epic for Phase 0:
  `claude-workflow-plugin-e0d` (all eight child tasks
  `e0d.1`–`e0d.8` `qa-approved`).
- Parent epic: `claude-workflow-plugin-y4a` (v3.0.0 upgrade) — closed.
- Per-phase release notes: `CHANGELOG.md` `[3.3.0] - 2026-06-12`
  (Phase B), `[3.2.0] - 2026-06-11` (Phase A), `[3.1.0] - 2026-06-11`
  (Phase 0), and `[3.0.0] - 2026-05-11` (v3 + G8 + closeout).
- Open tickets: `bd ready` (ready to start), `bd blocked` (waiting on
  dependencies), `bd list --label qa-pending` (awaiting QA). The
  carried bugs across the v3.x line are
  `claude-workflow-plugin-l1r.3` (Phase A follow-up),
  `claude-workflow-plugin-0wk.4` (vitest SIGKILL bypasses
  try/finally cleanup; self-heal mitigation in `runFixture.ts`),
  `0wk.5` (upstream bd daemon stack-overflow on stale locks;
  `--allow-stale` workaround), `0wk.6` (carried Phase 0 follow-up),
  `claude-workflow-plugin-8oz` (SHA-pin GitHub Actions, P2), and
  `claude-workflow-plugin-a7y` (gitleaks CI job, P2).

## Verify conditions for "v3.3.0 (Phase B) shipped"

A new session can confirm readiness without re-running everything by
checking these assertions:

- assert: `.claude-plugin/plugin.json` `version` equals `3.3.0`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `3.3.0`.
- assert: `make test-all` exits 0 (offline gate — L1 bash unit + L2
  component). Post-Phase-B baseline is **21 specs / 409 assertions**
  (the 21st spec is `resolve-fixture-spec.sh`, added by `366.4` —
  the test-live fixture→spec resolver bug fix).
- assert: `cd .claude/tests/e2e && npm run test:unit` reports
  `125/2 skip` for the vitest unit tier (the two skips are honest
  invariant-engine skips; not green-washed).
- assert: `cd .claude/mcp/code-graph-mcp && npm test` reports
  **31 tests** passing (7 indexer + 15 tools + 9 server). The DB at
  `.claude/.code-graph/index.db` is gitignored and built lazily on
  first tool call.
- assert: `.claude/tests/component/specs/installer-mcp-config.sh`
  reports **14/14** assertions passing (the two META-TESTs plus the
  twelve content assertions including the five new Phase B ones for
  `code-graph` wiring and `code-context` retirement).
- assert: the `code-context` server entry is absent from both
  manifests. Run
  `! grep -q '"code-context"' .mcp.json .claude-plugin/plugin.json`
  and confirm exit 0.
- assert: `.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js` exists
  and is referenced from both manifests in the `${VAR:-.}` default
  form. Run
  `test -x .claude/mcp/code-graph-mcp/bin/code-graph-mcp.js`.
- assert: AgentLint score holds at **87/100** (or higher). Phase B
  introduces no new deterministic-detector findings beyond the
  documented S7 fixture overrides. Re-run via `make check`.

## Verify conditions for "v3.2.0 (Phase A) shipped"

A new session can confirm readiness without re-running everything by
checking these assertions:

- assert: `.claude-plugin/plugin.json` `version` equals `3.2.0`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `3.2.0`.
- assert: `make test-all` exits 0 (offline gate — L1 bash unit + L2
  component). Post-Phase-A baseline is **19 specs / 359 assertions**.
- assert: `qa-gate.sh grade-record` with no positional arguments
  exits non-zero with a structured-error JSON envelope. Run
  `bash .claude/scripts/qa-gate.sh grade-record </dev/null; echo $?`
  and confirm the final line is `1` and the trailing JSON contains
  `"error_key":"missing_task_id"`.
- assert: `.claude/agents/grader.md` exists and declares the
  read-only tool set on its frontmatter line. Run
  `grep -E '^tools: Read, Grep, Glob, LS$' .claude/agents/grader.md`
  and confirm a single hit (no `Bash`, no `Write`, no `Edit`, no
  `Task`).
- assert: `.claude/rubrics/default.md` carries `version: 1` in its
  frontmatter. Run
  `awk '/^---/{c++;next} c==1 && /^version: 1$/ {found=1} END{exit !found}' .claude/rubrics/default.md`
  and confirm exit 0.
- assert: `qa-gate.sh enter` on a fresh task arms `rubric-pending`
  alongside `qa-gate-entered`. Proxy verification (no live sandbox
  needed): the L1 spec
  `.claude/scripts/tests/qa-gate-grade-record.test.sh` Section 1
  exercises this end-to-end (87/87 assertions); rerun via
  `bash .claude/scripts/tests/qa-gate-grade-record.test.sh` and
  confirm `Failed: 0`.
- assert: AgentLint score holds at **87/100**. Phase A's new files
  (grader prompt, rubrics, L1 test, L2 spec, fixture) introduce no
  new deterministic-detector findings. Re-run via `make check`.

The single manual live validation —
`make test-live FIXTURE=rubric-revision-loop` — was run 2026-06-12
(3 runs, ~$15-30, defects fixed in-flight). Recorded in the
`[3.2.0]` CHANGELOG amendment shipped alongside the Phase B
(v3.3.0) closeout. The trace is anchored offline in
`_phase-a-trace.unit.spec.ts` and the seed cassette.

## Verify conditions for "v3.1.0 (Phase 0) shipped"

A new session can confirm readiness without re-running everything by
checking these assertions:

- assert: `.claude-plugin/plugin.json` `version` equals `3.1.0`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `3.1.0`.
- assert: `make test-all` exits 0 (offline gate — L1 bash unit + L2
  component). Post-Phase-0 baseline is 18 specs / 315 assertions.
- assert: `make test-live` without a `FIXTURE=` arg exits with code 2
  (the 0.8 guard). Run `make test-live; echo $?` and confirm `2`.
- assert: `.mcp.json` uses the `${CLAUDE_PROJECT_DIR:-.}` default form
  and contains no bare `${CLAUDE_PROJECT_DIR}` refs. Run
  `grep -c 'CLAUDE_PROJECT_DIR:-' .mcp.json` for a non-zero hit and
  `! grep -E '\${CLAUDE_PROJECT_DIR}([^:-]|$)' .mcp.json` to confirm
  the bare form is absent.
- assert: `qa-gate.sh` exposes a `choose` subcommand. Run
  `bash .claude/scripts/qa-gate.sh choose 2>&1 | grep -q 'choose'`
  and confirm exit 0.
- assert: `LESSONS.md` exists with at least 2 entries. Run
  `grep -cE '^- ' LESSONS.md` and confirm `>= 2`.
- assert: `.claude/model-ranking` exists and is non-empty. Run
  `test -s .claude/model-ranking`.
- assert: `.github/workflows/test.yml` has no `schedule:` block. Run
  `! grep -E '^\s*schedule:' .github/workflows/test.yml` and confirm
  zero hits (CI is zero-API-spend).

### Earlier (v3.0.0 + G8) verify conditions

- assert: AgentLint score >= 80/100. The Phase 7 baseline was 90/100;
  post-G8 Phase F was 87/100; post-Phase-0 is **87/100** with one
  new override documented for S7 (the example slug comment is not a
  personal path). See `docs/AGENTLINT_REPORT.md`. Re-run via
  `make check`.
- assert: `npm run test:unit` reports `55/55` passing for the L3 vitest
  unit tier (now extended to 96 unit tests after 0.8's invariant
  engine; the L3 unit gate is `cd .claude/tests/e2e && npm run test:unit`).
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

- 2026-06-11 (Phase A / v3.2.0): Two child tasks shipped in the
  `claude-workflow-plugin-l1r` epic. A.1 (`l1r.1`) added the
  rubric plumbing — `qa-gate.sh grade-record` with structured-error
  envelopes for nine malformed-input cases, `enter` arming
  `rubric-pending` (clearing stale `rubric-satisfied` on re-entry),
  `approve` warning loudly when `rubric-pending` is still set
  (principle 6: no hard gate; the override-reason rule is the
  prompt's concern), and a versioned rubric set
  (`.claude/rubrics/{default,backend,frontend,devops}.md` + the
  `bugfix.md` overlay) with `.claude/rubric-config` carrying
  `iteration_cap=3`. A.2 (`l1r.2`) added the grader subagent
  (separate context, read-only tools, strict-JSON verdict), the
  QA grading loop (qa.md section 6 with subsections 6a–6f),
  docs/AGENTS.md update (5 → 6 agents), the statusline rubric
  segment on the existing `bd show` round-trip, and the
  `rubric-revision-loop` e2e fixture (built; live validation
  pending — recorded in closeout notes when run). The binding
  cap from `.claude/rubric-config` engages the 0.2 escalation
  path on cap-hit rather than looping further.
  `verify-before-stop.sh` is **unmodified** — the rubric is a QA
  input, not a parallel Stop gate (principle 6). AgentLint holds
  at 87/100 with no composition change.
- 2026-06-11 (Phase 0 / v3.1.0): Eight items shipped in one epic
  (`claude-workflow-plugin-e0d`). Two hotfixes — `${CLAUDE_PROJECT_DIR:-.}`
  default form in `.mcp.json` (0.1) and a binding QA-gate escalation cap
  with `qa-escalated`/`qa-deferred` states (0.2). Five policy upgrades:
  best-model auto-selection via `model-select.sh` + `.claude/model-ranking`
  on SessionStart (0.3), `effortLevel: xhigh` + `CLAUDE_CODE_EFFORT_LEVEL=max`
  + per-agent effort frontmatter + shared time-budget block (0.4),
  evidence-before-fix protocol as 6 J27 steps + bounce-twice rule (0.5),
  parallel-specialist worktree isolation via `isolation: "worktree"` + a
  new `.worktreeinclude` (0.6), and `lessons.sh` + `LESSONS.md` seeded
  with two production lessons (0.7). Live-test economics rework: golden-
  cassette equality retired, invariant engine over normalized traces with
  4 active invariants + 1 honestly skipped (0.8), `make test-live` now
  manual-only with `FIXTURE=` required and cost preview, CI is zero-API
  spend (L4 cron + per-PR live wiring removed, `l3-live` is
  `workflow_dispatch`-only). New L2 installer-config spec; `matchesGolden`
  deprecated to debugging.
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
- 2026-05-08 (Phase 6): bd-mcp + code-context-mcp ship as in-tree node servers (code-context-mcp was retired in 3.3.0 in favor of code-graph-mcp; see verification-suite Phase B)
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

# HANDOFF — claude-workflow-plugin

This file is the cross-session handoff record. Read it first when picking up
work on this repository.

## Current state

- **v3.5.0** — the Release Acceptance Gauntlet — closeout complete
  2026-06-14; awaiting the orchestrator commit + first git tag. Parent
  epic `claude-workflow-plugin-llh`. The gauntlet put every shipped
  claim through adversarial certification (rules: no adjective without
  artifact; prove-or-remove; mechanics over prompts; $80 hard paid cap).
  Output: the 121-row claims ledger `docs/RELEASE_AUDIT.md`, re-tallied
  mechanically at the verdict to **PROVEN 51 / PROVEN-WITH-CAVEAT 47 /
  REMOVED 23 / NOT-PROVEN 0** (grep over end-anchored status cells; the
  one textual `NOT-PROVEN` left is the status-vocabulary DEFINITION row,
  not a data row). **Release rule MET**: NOT-PROVEN = 0 AND the Stage-3
  red-team P0/P1 (llh.18) closed. The release-defining change is the
  **change-set-hash-bound QA approval (llh.18)** — the Stop gate now
  requires a tamper-evident approval record whose `change_set_hash`
  matches the current diff, not the bare `qa-approved` label, defeating
  the red team's forged-label (P0), decoy-current-task (P1), and
  post-approval-drift attacks (642 L2 assertions incl. a load-bearing
  META-test). The gate was red-team-certified NOT to leak under live
  load: forensically confirmed (llh.25) on the paid python-django-bug
  run, where the hardened gate BLOCKED the unreviewed change. **Paid
  budget: $10.15 of $80** — node-react-auth ($8.01, feature shipped +
  QA-approved + worktrees merged) and python-django-bug ($2.14,
  bugfix-0.5 engaged + gate held). Closeout task:
  `claude-workflow-plugin-llh.26`. **NO commit/tag was made by the
  closeout** — the orchestrator commits and applies the first git tag.
  See `CHANGELOG.md` `[3.5.0] - 2026-06-14` and the residual-risk
  register below.
- Hotfix **v3.4.1** shipped 2026-06-13. Parent epic
  `claude-workflow-plugin-vlp` with three child tasks all
  `qa-approved` on `main`: `vlp.1` (model resolver — generation-aware
  selection, `--refresh` flag, statusline pin, ranking
  exclusion-semantics, 6 stale-doc refs), `vlp.2` (effort defaults —
  `effortLevel: xhigh` + `env.CLAUDE_CODE_EFFORT_LEVEL: max` +
  SessionStart one-liner + CONTRIBUTING.md `Why ultracode cannot be
  the durable default`), and the discovered-from defect
  `claude-workflow-plugin-3fn` (manual-adopt stdout-sentinel —
  `MANUAL_ADOPT_REQUIRED` subshell-loss). Closeout
  (`vlp.3` — CHANGELOG, HANDOFF, version bump, AgentLint rerun) is
  this current task. First real-world adoption recorded
  2026-06-13: all seven agent pins moved
  `claude-opus-4-7 → claude-fable-5` (newest `created_at` in the
  live `/v1/models` listing); audit comment on meta-task
  `claude-workflow-plugin-4o2` (`Model selection log`, comment 278)
  with rollback `/workflow-model claude-opus-4-7`. Statusline now
  displays the active model id.
- Plan `docs/plans/v3-upgrade.md` (Phases 0-7) is **complete**. The G8
  end-to-end test-harness epic and the post-G8 closeout pass also
  shipped. Everything landed on `main` by 2026-05-11.
- Plan `docs/plans/verification-suite.md` is **complete** across all
  four phases (0 → A → B → C → v3.1.0 / v3.2.0 / v3.3.0 / v3.4.0
  → hotfix v3.4.1).
  Definition-of-done sweep (spec line 213) is green: every epic
  closed with `qa-approved` on every child task; fresh install
  renders zero MCP-diagnostics warnings AND ships the full
  manifest-declared surface (7 agents + rubrics + mutation tier);
  CI carries no scheduled paid job (zero API spend per PR); per-phase
  manual live-validation cost was recorded inline in each `[3.x.0]`
  CHANGELOG section; AgentLint holds at 87/100 with documented
  Phase-A + Phase-C overrides; CHANGELOG reads as coherent release
  notes 3.1.0 → 3.4.0 → 3.4.1; README "What you get" + Caveats
  updated to reflect 7 agents, rubrics, 2 MCP servers,
  invariant-based manual live testing, lessons ledger, and the
  mutation tier.
- Plan `docs/plans/verification-suite.md` Phase C shipped 2026-06-12
  as **v3.4.0**. Parent epic: `claude-workflow-plugin-n45` with five
  child tasks `n45.1` (deterministic harness), `n45.2` (judge +
  calibration), `n45.3` (acceptance sweep), `n45.5`
  (exclusion-bypass fix + JUDGE-RELAY), and `n45.4` (this closeout) —
  all `qa-approved`. First calibration round 2026-06-12 (in-session,
  zero API spend): precision 0.9412 / recall 0.9412 — GATE PASSED
  (0.8 threshold). Acceptance sweep over `verify-before-stop.sh` +
  `post-edit.sh`: 32 mutants generated, 4 killed by existing suite,
  28 survived; judge classified 27 genuine + 1 equivalent; one
  genuine survivor (id 12, cache-replay control-flow regression)
  was killed via 8 new L2 assertions on `verify-before-stop.sh`;
  26 remaining genuine survivors tracked as
  `claude-workflow-plugin-6ix` (P2 backlog) with 2 TECHNICAL_DEBT.md
  rows.
- Plan `docs/plans/verification-suite.md` Phase B shipped 2026-06-12
  as **v3.3.0**. Parent epic: `claude-workflow-plugin-366` with two
  child tasks `366.1` (code-graph-mcp server: scaffold, indexer, 7
  tools, 31 tests) and `366.2` (manifests, installer test, agent
  wiring, migration) both `qa-approved`. Phase A's live validation
  also completed in this cycle (3 runs, defects fixed in-flight,
  trace anchored offline) — Phase A entry amended in the
  `[3.2.0]` section.
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
- Per-phase release notes: `CHANGELOG.md` `[3.4.1] - 2026-06-13`
  (hotfix), `[3.4.0] - 2026-06-12` (Phase C), `[3.3.0] - 2026-06-12`
  (Phase B), `[3.2.0] - 2026-06-11` (Phase A),
  `[3.1.0] - 2026-06-11` (Phase 0), and `[3.0.0] - 2026-05-11`
  (v3 + G8 + closeout).
- Suite numbers (post-v3.4.1): `make test` (L1) reports **15 specs**
  passing (+1 over Phase-C: `effort-fail-open.test.sh` from
  `vlp.2`); `make test-all` (L1 + L2 offline gate) reports
  **21 specs / 454 assertions** passing (+20 over the 3.4.0
  baseline of 434, all from the M-block manual-adopt regression
  coverage added by `3fn`); `cd .claude/tests/e2e && npm run
  test:unit` reports **158 passed / 5 skipped** (unchanged from
  v3.4.0 — the five skips are honest invariant-engine +
  trace-anchor artifact-missing skips, not green-washed);
  `make lint` clean; `make check` (AgentLint) holds at **87/100**.
- Open tickets: `bd ready` (ready to start), `bd blocked` (waiting on
  dependencies), `bd list --label qa-pending` (awaiting QA). The
  carried bugs across the v3.x line are
  `claude-workflow-plugin-n6d` (Phase B carried bug: QA did not
  query `impact_of` live across 4 paid runs even with explicit
  prompt cues — mechanical pre-compute option C is the design
  candidate; tracked P1),
  `claude-workflow-plugin-9ke` (Phase B carried bug:
  `beadsLabelTransitions` captures net diffs missing transient
  `qa-pending` — engine repair tracked P2),
  `claude-workflow-plugin-6ix` (Phase C 26-survivor mutation
  backlog; P2 with seven theme groupings A–G),
  `claude-workflow-plugin-l1r.3` (Phase A follow-up),
  `claude-workflow-plugin-n45.6` (Phase C.1 polish: SIGINT halt,
  stale-worktree reclaim, MAX_MUTANTS_PER_FILE doc, judge-output
  robustness — extract LAST well-formed JSON object; P3),
  `claude-workflow-plugin-0wk.4` (vitest SIGKILL bypasses
  try/finally cleanup; self-heal mitigation in `runFixture.ts`),
  `0wk.5` (upstream bd daemon stack-overflow on stale locks;
  `--allow-stale` workaround), `0wk.6` (carried Phase 0 follow-up),
  `claude-workflow-plugin-8oz` (SHA-pin GitHub Actions, P2), and
  `claude-workflow-plugin-a7y` (gitleaks CI job, P2).

## Residual-risk register (v3.5.0)

The gauntlet shipped with NOT-PROVEN = 0, but 47 rows are
PROVEN-WITH-CAVEAT. These are the carried residuals that survive into the
release notes — each has a concrete flip-to-PROVEN path in its
`docs/RELEASE_AUDIT.md` row, and each carries a tracking task.

- **n6d consultation inject-fix (ledger A4/M3/P6b/S3; tracker
  `claude-workflow-plugin-llh.22`, open).** The mechanical impact report
  is generated + freshness-gated + hash-bound at gate-enter (PROVEN);
  QA *consulting* it is prompt-surfaced (qa.md §3a "FIRST ACTION: cat the
  report"), NOT force-injected — the paid node-react-auth run recorded 0
  QA reads despite §3a. Fix: embed the impact summary (high-fan-in
  callers) into the `verify-before-stop.sh` QA-Task template so it is in
  QA context by construction; the `qa-queried-impact-of` invariant must
  co-evolve to check the embedded-in-prompt signal. Flip: inject-fix +
  one re-validation.
- **Windows execution (ledger S6/R25/R26/I5/Q7; tracker `llh.7`,
  carried).** `install.ps1` is parity-inspected and the code-graph-mcp
  stdio boot is validated locally on macOS; `.github/workflows/
  windows-install.yml` exists (27 parity assertions) but is
  undispatched — gh's token scopes (`gist, read:org, repo`) lack
  `workflow`. Flip: re-auth gh with `workflow` scope, push, dispatch +
  watch a green windows-latest run.
- **Orchestrator Bash-write vector (ledger R30/P1; tracker `llh.19`,
  reverted).** Write/Edit/MultiEdit are structurally omitted from the
  orchestrator tool list AND hook-blocked (red-team confirmed); a
  write-shaped Bash command (`bash -c 'cat > src/x.ts'`) is neither
  denied nor tracked. The mechanical fail-closed fix (llh.19) was
  REVERTED because `prevent-orchestrator-edits.sh` cannot attribute the
  caller in this identity-less runtime, so failing closed broke
  legitimate specialist Bash. Flip: runtime-surfaced subagent identity
  (not available in this environment), or content-detection on
  write-shaped Bash.
- **bd daemon stack-overflow — 0wk.5 (ledger P10; tracker
  `claude-workflow-plugin-0wk.5`, open, upstream/environmental).** The
  installed `bd` (0.47.1) crashes on daemon autostart against stale
  locks (`acquireStartLock`, `daemon_autostart.go:228`; `runtime:
  goroutine stack exceeds 1000000000-byte limit`), which zeroed out all
  label writes on the paid python-django-bug run and blocked the
  bugfix-0.5 label-milestone confirmation. NOT a workflow defect (llh.25
  classified INVARIANT-NUANCE + bd-daemon-crash; the gate did not leak).
  Workaround: the documented `bd --no-daemon` path. Flip: a bd build
  without the 0wk.5 crash + a captured `qa-pending → qa-approved`
  milestone stream from a re-run.
- **node-react-auth label-cassette gap (tracker:
  `claude-workflow-plugin-llh.27`, this closeout's follow-up; pre-
  existing, non-blocking).** The seed-fixture worktree task-creation
  label-event stream is not fully derived (a `qa-pending` add-event is
  declared in the fixture but absent from the derived stream).
  DISTINCT from llh.23's var-bound-bd deriver fix. Flip: extend the
  deriver to map the worktree task-creation command shape, then the
  label-milestone invariant passes on the seed cassette.

## Verify conditions for "v3.5.0 (Release Acceptance Gauntlet) shipped"

A new session can confirm readiness without re-running the gauntlet by
checking these assertions:

- assert: `.claude-plugin/plugin.json` `version` equals `3.5.0`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `3.5.0`.
- assert: `docs/RELEASE_AUDIT.md` re-tallies to **PROVEN 51 /
  PROVEN-WITH-CAVEAT 47 / NOT-PROVEN 0 / REMOVED 23 = 121**. Run the four
  greps `grep -cE '\| PROVEN \|$'`, `grep -cE '\| PROVEN-WITH-CAVEAT \|$'`,
  `grep -cE '\| NOT-PROVEN \|$'`, `grep -cE '\| REMOVED \|$'` over the
  file and confirm `51 / 47 / 0 / 23`; the leading-row-id count
  `grep -cE '^\| [A-Za-z]+[0-9]+[a-z]? \|'` is `121`. (The only textual
  `NOT-PROVEN` is the status-vocabulary DEFINITION row, which is not
  end-anchored as a data row.)
- assert: `make test-all` exits 0. Post-gauntlet baseline is **22 specs
  / 642 assertions** (+1 spec over v3.4.1's 21 — the `bd-compat.sh`
  L2 smoke spec from llh.6, 71 assertions — plus the llh.18
  change-set-hash-bound approval assertions on `qa-gate.sh` +
  `verify-before-stop.sh`).
- assert: `make test` exits 0. Post-gauntlet L1 baseline is **16 specs**
  (+1 over v3.4.1's 15 — the `impact-report.test.sh` from G2.n6d/llh.2).
- assert: `cd .claude/tests/e2e && npm run test:unit` reports **368
  passed / 5 skipped** (+210 tests over v3.4.1's 158 — chiefly the
  `_fixture-script-sync.unit.spec.ts` 140-case drift guard from llh.8 +
  the bd-compat / hardened-gate unit coverage; the five skips are the
  honest invariant-engine + trace-anchor artifact-missing skips, not
  green-washed).
- assert: `make lint` clean (shellcheck over all hook + test scripts +
  install/uninstall).
- assert: the hardened gate requires a hash-matching approval record,
  not the bare label. Run
  `grep -c 'task_has_matching_approval_record' .claude/scripts/verify-before-stop.sh`
  and confirm `>= 1`; a bare `bd label add <task> qa-approved` without a
  matching `QA-GATE APPROVED change_set_hash=<h>` record must NOT release
  the Stop gate.
- assert: `.claude/scripts/impact-report.sh` exists and `qa-gate.sh
  approve` refuses (exit 2) without a hash-current impact-report
  artifact.
- assert: `.github/workflows/windows-install.yml` exists and is
  `workflow_dispatch`-only (authored, undispatched — see residual
  register).

The two paid live events ran 2026-06-13 (budget $10.15 of $80):
node-react-auth ($8.01, 1526s, trace
`cassettes/replays/node-react-auth-2026-06-13T16-52-03-909Z.jsonl`) —
feature shipped + QA-approved + worktree branches merged; and
python-django-bug ($2.14, 620s, trace
`cassettes/replays/python-django-bug-2026-06-13T19-56-33-557Z.jsonl`) —
bugfix-0.5 engaged, the hardened gate BLOCKED the unreviewed change
(llh.25: no leak).

## Verify conditions for "v3.4.1 (hotfix) shipped"

A new session can confirm readiness without re-running everything by
checking these assertions:

- assert: `.claude-plugin/plugin.json` `version` equals `3.4.1`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `3.4.1`.
- assert: all seven agent frontmatter `model:` lines equal
  `claude-fable-5`. Run
  `grep -hE '^model:' .claude/agents/*.md | sort -u`
  and confirm the single line `model: claude-fable-5`.
- assert: `.claude/settings.json` `env.CLAUDE_LATEST_OPUS` equals
  `claude-fable-5`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude/settings.json","utf8")).env.CLAUDE_LATEST_OPUS)'`
  and confirm `claude-fable-5`.
- assert: `.claude/settings.json` `effortLevel` equals `"xhigh"` and
  `env.CLAUDE_CODE_EFFORT_LEVEL` equals `"max"` (the persistable
  pair per the cited docs).
- assert: `model-select.sh apply` emits both the LOUD adopt notice
  and a `manual adoption required for '...'` result line when the
  winner's `created_at` is unparseable, AND leaves the seven agent
  pins byte-unchanged. This is the contract enforced by Spec M
  (`ms-M / ms-ME / ms-MT / ms-MC / ms-MX`) in
  `.claude/tests/component/specs/model-select.sh`; rerun via
  `bash .claude/tests/component/run.sh --filter model-select` and
  confirm `45/45`.
- assert: `make test-all` exits 0. Post-v3.4.1 baseline is
  **21 specs / 454 assertions** (+20 over the v3.4.0 baseline of
  434, all from the new M-block manual-adopt regression coverage).
- assert: `make test` exits 0. Post-v3.4.1 baseline is **15 specs**
  (+1 over Phase-C: `effort-fail-open.test.sh` from `vlp.2`).
- assert: `cd .claude/tests/e2e && npm run test:unit` reports
  **158 passed / 5 skipped** (unchanged — the v3.4.1 patch surface
  does not touch the L3 vitest tier).
- assert: meta-task `claude-workflow-plugin-4o2`
  (`Model selection log`) carries at least one comment with the
  `MODEL SWITCH` prefix recording the
  `claude-opus-4-7 -> claude-fable-5` transition (comment id 278
  in the 2026-06-13 snapshot).
- assert: statusline emits `• model: <id>` for every output
  branch. Proxy check:
  `bash .claude/scripts/tests/phase5-synthetic-tests.sh` includes
  two assertions covering the pin-present and pin-absent branches;
  rerun via `make test` and confirm green.
- assert: AgentLint score holds at **87/100**. The v3.4.1 patch
  surface introduces one additional S7 fixture path
  (`.claude/tests/component/specs/model-select.sh`) that matches
  the documented S7 fixture override convention; the numeric score
  is unchanged. Re-run via `make check`.

The single manual live event — the first real-world model adoption —
ran 2026-06-13. Decision path was offline + cached listing: the
resolver picked `claude-fable-5` as the newest `created_at`, the
seven agent pins flipped from `claude-opus-4-7`, and the audit
comment landed on meta-task `4o2`. Zero API spend during the
hotfix cycle.

## Verify conditions for "v3.4.0 (Phase C) shipped"

A new session can confirm readiness without re-running everything by
checking these assertions. Counts and `version` lines below are
**v3.4.0 release-time anchors** — the v3.4.1 hotfix bumped the
version to `3.4.1`, `make test` to 15 specs, and `make test-all` to
21 / 454; see the v3.4.1 verify block above for the post-hotfix
numbers.

- assert: `.claude-plugin/plugin.json` `version` equals `3.4.0`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `3.4.0`.
- assert: `.claude-plugin/plugin.json` agents[] declares all seven
  agents (orchestrator, qa, backend, frontend, devops, grader,
  judge). Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).agents.length)'`
  and confirm `7`.
- assert: `make test-all` exits 0 (offline gate — L1 bash unit + L2
  component). Post-Phase-C baseline is **21 specs / 429 assertions**
  (+10 over the 3.3.0 baseline of 419, from the new Phase A + C
  presence assertions in `installer-mcp-config.sh`).
- assert: `.claude/tests/component/specs/installer-mcp-config.sh`
  reports **24/24** assertions passing (the two META-TESTs plus
  twelve content assertions for code-graph + zero-bare-`${VAR}` +
  the ten new presence assertions for grader.md, judge.md,
  rubrics/default.md, rubric-config, mutation-sweep.sh,
  judge-gate.sh, calibration-set.json, mutation-sweep.md,
  LESSONS.md, model-ranking).
- assert: `cd .claude/tests/e2e && npm run test:unit` reports
  **158 passed / 5 skipped** (unchanged from 3.3.0; Phase C is a
  manual-tier closeout, so the L3 vitest count holds).
- assert: `.claude/agents/judge.md` exists and declares the
  read-only tool set on its frontmatter line. Run
  `grep -E '^tools: Read, Grep, Glob, LS$' .claude/agents/judge.md`
  and confirm a single hit (no `Bash`, no `Write`, no `Edit`, no
  `Task`).
- assert: `.claude/tests/mutation/judge-gate.sh` exists and is
  executable. Run `test -x .claude/tests/mutation/judge-gate.sh`.
- assert: `.claude/tests/mutation/calibration/calibration-set.json`
  exists and carries ≥20 entries with all 8 fault classes. Run
  `node -e 'const j=JSON.parse(require("fs").readFileSync(".claude/tests/mutation/calibration/calibration-set.json","utf8")); console.log(j.length>=20, new Set(j.map(e=>e.fault)).size>=8)'`
  and confirm `true true`.
- assert: the orchestrator wires JUDGE-RELAY. Run
  `grep -c 'JUDGE-RELAY: judging-relay' .claude/agents/orchestrator.md`
  and confirm `>= 1`.
- assert: AgentLint score holds at **87/100**. Phase C introduces
  no new deterministic-detector findings beyond the documented S7
  fixture overrides. Re-run via `make check`.
- assert: a rendered fresh install has all of: `.claude/agents/{grader,judge}.md`,
  `.claude/rubrics/default.md`, `.claude/rubric-config`,
  `.claude/tests/mutation/{mutation-sweep.sh,judge-gate.sh}`,
  `.claude/tests/mutation/calibration/calibration-set.json`,
  `.claude/commands/mutation-sweep.md`, `LESSONS.md`,
  `.claude/model-ranking`. The L2
  `installer-mcp-config.sh` spec asserts each path; the spec runs
  inside `make test-all`. The fresh-install rendering itself uses
  `bash install.sh <tempdir>`; ten new assertions added in v3.4.0
  cover the surface.

The single manual calibration run —
`/mutation-sweep` over `verify-before-stop.sh` + `post-edit.sh` with
the JUDGE-RELAY — was run 2026-06-12 (in-session relay; zero API-key
spend because the judge ran via the operator's existing Claude
session). Precision 0.9412 / recall 0.9412 — GATE PASSED.
Acceptance sweep numbers (32 mutants / 4 killed / 28 survived;
27 genuine / 1 equivalent; survivor id 12 killed via 8 L2
assertions; 26-survivor backlog tracked as
`claude-workflow-plugin-6ix`) are recorded in the `[3.4.0]`
CHANGELOG section.

## Verify conditions for "v3.3.0 (Phase B) shipped"

A new session can confirm readiness without re-running everything by
checking these assertions:

- assert: `.claude-plugin/plugin.json` `version` equals `3.3.0`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `3.3.0`.
- assert: `make test-all` exits 0 (offline gate — L1 bash unit + L2
  component). Post-Phase-B baseline is **21 specs / 411 assertions**
  (the 21st spec is `resolve-fixture-spec.sh`, added by `366.4` —
  the test-live fixture→spec resolver bug fix; the 411 figure
  includes the 2 new `vbs` assertions added by `366.9`'s impact_of
  cue fix — QA-fix inline 2026-06-12 during the 366 epic-close
  review; prior closeout amendment recorded 409).
- assert: `cd .claude/tests/e2e && npm run test:unit` reports
  `158/5 skip` for the vitest unit tier (the five skips are honest
  invariant-engine skips and trace-anchor artifact-missing skips;
  not green-washed; up from 125/2 with the addition of the run-3
  + run-4 trace anchors filed under `366.8`/`366.10` — QA-fix
  inline 2026-06-12 during the 366 epic-close review).
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

- 2026-06-12 (Phase C / v3.4.0): Five child tasks shipped in the
  `claude-workflow-plugin-n45` epic. C.1 (`n45.1`) shipped the
  deterministic harness — `.claude/tests/mutation/mutation-sweep.sh`
  + the 8-class catalog (F1–F8) + `mutation.conf` caps +
  `lib/generate.sh` (deterministic awk/sed generators) +
  `lib/rank-targets.sh` (`impact_of` when code-graph index present,
  heuristic fallback when not), throwaway-worktree containment
  with three-layer cleanup (per-mutant remove + EXIT/INT/TERM trap +
  final prune), and the cost-confirmation gate (EOF defaults to N).
  C.2 (`n45.2`) shipped `.claude/agents/judge.md` (read-only tools;
  strict JSON output; 3 worked examples), the 24-mutant hand-labeled
  calibration set (all 8 fault classes, 7 equivalents), the
  precision/recall gate (`judge-gate.sh`; threshold 0.8 — recall
  reported but not gating), and the L1 suite
  (`judge-calibration.test.sh`, 65 assertions, 2 META-TESTs).
  C.3 (`n45.3`) ran the acceptance sweep over
  `verify-before-stop.sh` + `post-edit.sh` (32 mutants, 4 killed,
  28 survived; judge 27 genuine / 1 equivalent) and shipped the
  killing test for survivor id 12 (cache-replay control-flow
  regression — 8 new L2 assertions). C.5 (`n45.5`) fixed the
  COMMAND_EXCLUSIONS bypass in F2/F4/F5/F7/F8 generators and added
  the JUDGE-RELAY anchor to `orchestrator.md` section 5b
  (mirroring the 5a RUBRIC-RELAY shape). C.4 (`n45.4`, this
  closeout) bumped `plugin.json` to 3.4.0, fixed the installer
  surface gap (was hardcoded to 5 v3.0 agents — silently dropped
  grader.md from v3.2.0 and judge.md from v3.4.0 in fresh
  installs; now glob-copies all 7 + ships
  `.claude/rubrics/*` + `.claude/tests/mutation/` + rubric-config +
  model-ranking + LESSONS.md + `.worktreeinclude`), extended the
  `installer-mcp-config.sh` L2 spec with 10 new presence
  assertions (Phase A + C surface), and added a doc note +
  `mutation.conf` comment + per-target `--test-cmd` override
  recommendation so future sweeps over hook scripts pick the
  L1+L2 combo by default. First calibration round 2026-06-12
  (in-session, zero API spend): precision 0.9412 / recall 0.9412
  — GATE PASSED. 26-survivor backlog tracked as
  `claude-workflow-plugin-6ix` (P2). AgentLint holds at 87/100.
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

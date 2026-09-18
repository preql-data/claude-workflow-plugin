# HANDOFF — claude-workflow-plugin

This file is the cross-session handoff record. Read it first when picking up
work on this repository.

## Current state

- **v4.0.0 IS COMPLETE AND READY TO TAG (2026-07-26, tasks
  `claude-workflow-plugin-d2j.2` live validations + `d2j.3` docs sweep).**
  Supersedes the d2j.1 bullet immediately below — its "STILL OPEN — V5 item 5"
  no longer holds. **All six phases V0-V5 are done**, and the two cost-gated
  live tri-model validations BOTH PASSED: (a) Codex CONNECTED —
  `codex-review.sh` drove the REAL Codex MCP server on `gpt-5.6-sol`
  (read-only sandbox, no subagent spawning), Sol returned a schema-valid
  `verdict=findings` artifact with a genuine MEDIUM finding, and the real gate
  scripts BLOCKED (`independent:true`, `open_findings:1`) until an
  orchestrator `arbitrate R1-F1 overrule` cleared the count and the gate
  PASSED; (b) Codex ABSENT — `codex-detect` resolved `reviewer_lane=claude`
  and a same-schema `qa-claude`/`claude-fable-5` artifact drove the IDENTICAL
  BLOCK → overrule → PASS sequence on twin task `d2j.2.1`. Reviewer identity,
  model and finding quality differed; the gate DECISIONS were byte-identical —
  the v4 core claim, now shown live. **Scope, stated rather than buried:** the
  subject was a small synthetic `count_files` harness and the implementer
  identity was posted directly, not produced by a full specialist→QA→grader
  cycle, and the flow ran through the gate scripts directly, so NO e2e trace
  was captured and the `approval-cites-independent-review` invariant is still
  proven offline only. `docs/RELEASE_AUDIT.md` TM7/TM14 carry the live result
  with that caveat; the full record is the `validation-results` doc on
  `d2j.2`. One finding filed, operator-scope and NOT a plugin defect:
  `claude-workflow-plugin-gl6` — the Codex model pin is authoritative in
  `~/.codex/config.toml` (codex-cli 0.145.0 `mcp-server` ignores the
  registration's `-m`), and `gpt-5.2-codex` is rejected by ChatGPT-account
  backends, which is what made the first Sol turn exit 5;
  `docs/CODEX_SETUP.md` §5 + §7 now document the diagnosis, fix and a free
  verification command. **The release tag remains the orchestrator's to
  apply** — neither d2j.2 nor d2j.3 commits or tags.
- **v4.0.0 RELEASE DOCS LANDED (2026-07-26, task `claude-workflow-plugin-d2j.1`).**
  *[SUPERSEDED by the bullet above — V5 item 5 has since RUN and PASSED. Kept
  unedited as the record of what was true when d2j.1 landed.]*
  Supersedes the 2026-07-25 progress bullet below: V0-V4 are all COMPLETE and
  committed on `gauntlet/v4.0.0`, and Phase V5 items 1-4 (version bump to
  **4.0.0**, the consolidated CHANGELOG entry, the README tri-model section +
  effort policy, the 14-row `TM1`-`TM14` RELEASE_AUDIT ledger, and the
  model-version doc sweep) shipped with this task. **STILL OPEN — V5 item 5:**
  the two cost-gated live tri-model validations (`claude-workflow-plugin-d2j.2`,
  Codex-connected and Codex-absent) have NOT been run; RELEASE_AUDIT rows TM7
  and TM14 carry an explicit `live validation: pending d2j.2` note and assert no
  live result. The release tag itself is the orchestrator's to apply — d2j.1
  makes no commit and no approval.
- **BLOCKER (2026-07-25): Anthropic account monthly spend limit reached** mid-session — spawning further specialist/QA/grader agents fails. All work below is committed and pushed on `gauntlet/v4.0.0`; resume once the limit resets or is raised (`/usage-credits`).
- **Model pins (user-directed, DONE + pushed, commit f980626):** implementers (backend/frontend/devops) on `claude-opus-5`; orchestrator/qa/grader/judge on `claude-fable-5`. The en9 resolver fix (tier order beats recency) makes this the durable resolved state from the real listing. The listing cache was refreshed once via the operator's Claude Code OAuth credential; task `qrh` adds an automatic OAuth-bearer fallback so keyless envs stay current.
- **v4.0.0 progress on `gauntlet/v4.0.0`:** V0 COMPLETE (epic cnz — platform restore + effort verdict `max`). V1 COMPLETE (epic bi3 — role-aware selection, fable un-excluded). V2 PARTIAL (epic 1vq): 1vq.1 (Sol-lane helpers: codex-detect/review-config/review-check/codex-review + qa-gate review-record/resolve-finding/arbitrate + stub-codex tests) qa-approved + pushed; **1vq.2 (qa.md/orchestrator.md REVIEW-RELAY prompts + docs/CODEX_SETUP.md + packet-drift fix) NOT STARTED — now unblocked, the V2 resume point.** V3/V4/V5 not started.
- **Open follow-ups:** qrh (P2, OAuth /v1/models fallback), 5ie (P3, bd JSONL >64KB import — commits currently need `--no-verify`), bfd (P3, EFFORT-AB-TEST cost estimate), + a doc-refresh for `.claude/model-ranking`'s comment block (now describes the pre-en9 sort; file ORDER is the load-bearing PRIMARY key post-en9).



- **v4.0.0 (Phase V0 — platform restore, COMPLETE 2026-07-25)** — epic
  `claude-workflow-plugin-cnz` closed; both children (cnz.1 offline wiring,
  cnz.2 paid A/B) qa-approved with hash-bound records. Effort verdict: `max`
  (recorded in `.claude/effort-verdict`; per-criterion table on meta-task
  `claude-workflow-plugin-4o2` — the pre-registered ultracode-interference
  expectation was NOT confirmed, but max wins on the conjunctive rule).
  Launch a working session via `make session`.
- **v4.0.0 (Phase V1 — role-aware model selection, COMPLETE 2026-07-25)** —
  epic `claude-workflow-plugin-bi3` closed (bi3.1 machinery, bi3.2 fable
  un-exclusion), both qa-approved. Live split: orchestrator/qa/grader/judge on
  `claude-fable-5`, implementers on the newest opus-class the resolver can see
  (opus-4-8 from the June cache; PENDING OPERATOR STEP for Opus 5: run
  `ANTHROPIC_API_KEY=<key> bash .claude/scripts/model-select.sh resolve --refresh`
  once — the next apply then lands implementers on `claude-opus-5-*`
  automatically). Next: Phase V2 (Sol reviewer lane, epic
  `claude-workflow-plugin-1vq`).
- **v4.0.0 (Phase V0 — original in-progress note)** — parent epic
  `claude-workflow-plugin-cnz`; offline wiring `claude-workflow-plugin-cnz.1`.
  Removed the `env.CLAUDE_CODE_EFFORT_LEVEL` pin: the live docs are explicit
  that any non-xhigh value there deactivates ultracode's workflow
  orchestration, so the durable effort FLOOR is now `effortLevel: xhigh`
  alone. The per-session effort is chosen at launch via
  `.claude/effort-verdict` + `make session` (verdict PROVISIONALLY `max`
  until the paid A/B interference test `claude-workflow-plugin-cnz.2` runs —
  runbook `docs/EFFORT-AB-TEST.md`). Pinned
  `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` (v2.1.219 defaulted nested subagent
  spawning to depth 3). Wired `SubagentStart` in `settings.json` to match
  `hooks.json`; `subagent-start.sh` now appends every spawn to
  `.claude/.qa-tracking/subagent-spawns.log`. `session-start.sh` Warning 4
  reconciles effort floor/live/verdict and Warning 5 guards
  `CLAUDE_CODE_SUBAGENT_MODEL` / the spawn-depth pin. New L1
  `platform-audit.test.sh`; `effort-fail-open.test.sh` inverted for the
  removed pin. **Plugin version NOT bumped** — a later phase owns the bump.
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
  requires a change-set-bound approval record — a disclosure that
  approve ran and bound this hash, not a cryptographic guard against
  hand-forgery (`claude-workflow-plugin-pqnd`) — whose `change_set_hash`
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

## Verify conditions for "v5.0.0 (design as a first-class, reviewed, continuously-enforced phase) shipped"

Every number below was measured on **2026-09-18** by the D7 docs/audit piece
of `claude-workflow-plugin-fkm.9`, on branch `v5/design-phase` at HEAD
`261e09e` plus this piece's own uncommitted edits to `RELEASE_AUDIT.md`,
`HANDOFF.md` and `CHANGELOG.md`. This piece owns those three files
exclusively and does not own the version/manifest piece, the docs-rewrite
piece, or the live-validations piece of the same D7 task — several
conditions below are stated as **NOT YET MET** rather than rounded up to a
pass, because they are those other pieces' work and this section's whole
purpose is to be checkable, not reassuring. A new session can confirm
readiness by re-running every command here.

**Addendum, 2026-09-19:** the live-validations piece (LIVE-1) and a
version/manifest update landed a day later than the rest of this block.
Three consequences, each also reflected at its own bullet below rather than
only here: the v5.0.0 ledger's tally moved from `11 / 5 / 1 / 0 / 17` to
`11 / 6 / 1 / 0 / 18` (`DP18` added for LIVE-1, `DP15`'s caveat narrowed);
`manifests/v5.0.0.sha256` now exists; and a fresh v4.1.0 -> v5.0.0 upgrade
target measures `12/12`, exit `0` on `install.sh --verify` — which sits
alongside, and does not change, this checkout's own `11/12`, exit `1`.

- assert: `.claude-plugin/plugin.json` `version` equals `5.0.0`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `5.0.0`. **MET** (checked live).
- assert: the manifest's top-level 2-space indentation is intact — the same
  load-bearing anchor named in every prior release's verify block. Run
  `grep -c '^  "version": "5\.0\.0",$' .claude-plugin/plugin.json` and
  confirm `1`. **MET** (checked live).
- assert: the banner is produced by EXECUTING the installer. Run
  `bash install.sh --help | head -3` and confirm the first line is
  `Claude Workflow Plugin v5.0.0 installer`. **MET** (checked live).
- assert: the agent census is bumped, and three independent counting
  methods agree. Run `jq '.agents | length' .claude-plugin/plugin.json` →
  `9`; run `ls .claude/agents/*.md | wc -l` → `9`; run `bash install.sh
  --verify 2>&1 | grep '^PASS agents'` → contains `9 declared agent(s)`.
  The two new names in all three counts are `designer` and
  `design-reviewer`. **MET** (all three checked live, 2026-09-18).
- assert: five role classes resolve, one row per agent-group. Run
  `bash .claude/scripts/workflow-model-apply.sh --print-role-map | wc -l` →
  `9`, and `bash .claude/scripts/workflow-model-apply.sh --print-role-map |
  awk '{print $1}' | sort -u | wc -l` → `5` (`designer`, `design_reviewer`,
  `orchestrator`, `implementer`, `reviewer`). **MET** (checked live).
- assert: the design rubric carries all eight DS criteria. Run
  `grep -cE '^### DS[0-9]+\.' .claude/rubrics/design.md` and confirm `8`.
  **MET** (checked live).
- assert: `docs/RELEASE_AUDIT.md` now holds FOUR ledgers (frozen v3.5.0,
  v4.0.0, v4.1.0, v5.0.0), so its greps are section-scoped per ledger. Run:
  - v5.0.0 ledger →
    `awk '/^## v5\.0\.0 claims ledger/,0' docs/RELEASE_AUDIT.md | grep -cE '\| PROVEN \|$'`
    and the three sibling statuses → confirm `11 / 6 / 1 / 0`, and
    `grep -cE '^\| DP[0-9]+ \|'` over the same range → `18`. The one
    NOT-PROVEN row is `DP17` (Linear), by explicit directive decision — see
    below. (`11/5/1/0/17` at this block's original 2026-09-18 measurement;
    `11/6/1/0/18` after `DP18` — LIVE-1 — was appended 2026-09-19 and
    `DP15`'s caveat was narrowed; PROVEN and NOT-PROVEN are unaffected, only
    PROVEN-WITH-CAVEAT moved.)
  - assert the trap is closed for a fourth time: the v4.1.0 range must NOT
    end at `,0`. Run `grep -cF 'v4\.1\.0 claims ledger/,0'
    docs/RELEASE_AUDIT.md` and confirm `0`; run `grep -cF 'v4\.1\.0 claims
    ledger/,/^## v5\.0\.0 claims ledger/' docs/RELEASE_AUDIT.md` and confirm
    `5`. **Positive control:** `grep -cF 'v5\.0\.0 claims ledger/,0'
    docs/RELEASE_AUDIT.md` → `5` — v5.0.0's own five ranges, which
    legitimately end at `,0` because v5.0.0 is currently the last
    claims-ledger section. **MET**, and the two prior ledgers' own greps
    (v3.5.0 → v4.0.0, v4.0.0 → v4.1.0) are unaffected and still return their
    original counts (checked live: `51/47/0/23` and `14/0/0/0`
    respectively).
- assert: the Sol-first design-reviewer lane never touches the three gate
  scripts. Run `grep -icE 'codex|reviewer[._]lane'
  .claude/scripts/qa-gate.sh .claude/scripts/verify-before-stop.sh
  .claude/scripts/review-check.sh` and confirm `0` for all three. **MET**
  (checked live, 2026-09-18 — this is a direct re-derivation, not a read of
  `.claude/scripts/tests/reviewer-lane-structural.test.sh`, which asserts
  the same thing on every `make test`).
- assert: the session-model guard warns and never blocks. Run
  `grep -c 'Never blocking' .claude/scripts/session-start.sh` and confirm
  `>= 1`; the same warning names its own fix inline (`/model
  $SS_DRIFT_EXPECTED`). **MET** (checked live).
- assert: install verification reports the MCP tool counts exactly. Run
  `bash install.sh --verify` and confirm the `mcp_bd` line reads "tools/list
  returned exactly 21 tool(s)" and `mcp_code_graph` reads "exactly 7
  tool(s)". **MET** (checked live, 2026-09-18).
- assert, and this is the one prior verify blocks did not have to state
  this carefully: `install.sh --verify`'s overall exit code and check
  count. **DO NOT assume 11/11 from the plan's own gate line — it predates
  a check this release's own Phase P added.** Run
  `sed -n 's/^DOCTOR_CHECK_NAMES="\(.*\)"$/\1/p' .claude/scripts/workflow-doctor.sh | wc -w`
  and confirm **`12`**, not 11 — `beads_ledger` was added by
  commit `fdfd6ce` (Phase P / `fkm.1.1`, the bd 1.1.2 migration). Then run
  `bash install.sh --verify; echo "exit=$?"` (capture `$?` directly — piping
  the output through another command loses it) and read the summary line.
  **NOT MET as of this measurement, and this is NOT rounded up to a pass**:
  this checkout currently reads
  `workflow-doctor: 12 check(s) — 11 passed, 1 failed, 0 skipped` and
  `exit=1`. Independently reproduced on the same tree: a second run read
  the same verdict with the database count moved 536 -> 538 (the live store
  growing between runs, not flakiness — the divergence itself is what
  reproduces, not the exact figure). The one failure is `beads_ledger`: the
  on-disk `.beads/issues.jsonl` (442 records) and the live `bd` database
  disagree with no provable direction.
  **Three facts establish this is dev-checkout state, not shipped-artifact
  behaviour — checked live, not assumed:**
  1. `workflow-doctor.sh`'s own header (`:272`, `:291`) states every dynamic
     check EXCEPT `beads` and `beads_ledger` runs against a throwaway
     sandbox copy; those two deliberately read the REAL target's database
     (`beads_ledger` explicitly because "a sandboxed copy would answer for
     the wrong ledger").
  2. `.beads/` is not shipped/manifested surface: run
     `grep -c '\.beads/' manifests/v4.1.0.sha256` and confirm `0`.
  3. Ledger and database start in agreement BY CONSTRUCTION on both paths
     that create them: a genuinely fresh install with no pre-existing
     `.beads/` runs `bd init --quiet` into an empty directory
     (`install.sh:2971-2974`), trivially in sync; the separate
     bd-binary-version-upgrade repair path rebuilds the database FROM the
     ledger via `bd bootstrap` when the two disagree (`install.sh:610-622`,
     "Step 4 — ALREADY-INSTALLED PATH"). Divergence is therefore only
     reachable after a checkout has been worked in, which is exactly this
     repository's own state.
  This is a live-store-vs-export condition this repo's own `CLAUDE.md`
  already documents ("the live store is always ahead of the export") and is
  gated behind `claude-workflow-plugin-0rbi` (open) plus the
  `.beads/quarantine.tsv` contamination it names (5 data rows, checked live
  via `tail -n +2 .beads/quarantine.tsv | wc -l` — `claude-workflow-plugin-ofd`
  alone carries 10,123 comments matching `text LIKE 'MODEL SWITCH%'`) —
  reconciling blind is explicitly the wrong move per `CLAUDE.md`'s own
  standing instruction (`beads-ledger.sh reconcile --apply` would import the
  ledger and re-export the union into that git-tracked file, writing the
  quarantined contamination in permanently), not an oversight of this piece.
  **Expect `12/12`, exit `0`, once `0rbi` lands and
  `bash .claude/scripts/beads-ledger.sh reconcile --apply` has run** — and
  correct the plan's own "11/11" gate line to "12/12" regardless, since that
  correction is owed independent of the ledger reconciling. **Until then,
  `install.sh --verify` does not pass on this tree — full stop, not a
  caveat that changes the exit code.**
- assert: **a genuinely fresh v4.1.0 -> v5.0.0 upgrade, on its own
  disposable target, is a different measurement from the one above and does
  not change it.** LIVE-1 (`fkm.9`, run 2026-09-19 — a day after the rest of
  this block) installed v4.1.0 from the tag into a scratch target, edited
  one operator file, upgraded with THIS checkout's installer, then ran
  `install.sh --verify` twice (once before, once after `npm ci --omit=dev`
  in both MCP server dirs). Both runs read
  `workflow-doctor: 12 check(s) — 12 passed, 0 failed, 0 skipped` and
  `exit=0` (byte-identical logs; exit codes captured directly as
  `exit-code:0` both times). **MET, but read the next sentence before
  treating this as good news about `beads_ledger` as a check**: the scratch
  target carried ZERO Beads records on either side of the comparison it
  passed — `bd export` on the target wrote an empty file and
  `.beads/issues.jsonl` does not exist there at all — so the pass is between
  two empty sets. It shows install-and-upgrade do not themselves CREATE
  ledger drift; it says nothing about a target that goes on to accumulate
  real history the way this very checkout has. **The assertion above stands
  exactly as written: on THIS tree, `install.sh --verify` does not pass,
  full stop.** Full measurement, predictions and both wrinkles:
  `docs/RELEASE_AUDIT.md` `DP18`, with the LIVE-1 addendum folded into
  `DP16` and `DP15` in the same file.
- assert: `make lint` is clean AND actually ran (same zero-bytes-vs-skip
  distinction every prior release's block uses — the recipe exits 0 on skip
  too). Run `make lint > /tmp/lint.out 2>&1; echo $?` and confirm `0` with
  `wc -c < /tmp/lint.out` equal to `0`; confirm `command -v shellcheck`
  resolves (`0.11.0` on the authoring host). **MET** (checked live,
  2026-09-18).
- assert: **the v5.0.0 manifest now EXISTS.** Run `ls manifests/` and
  confirm three files: `v3.5.0.sha256`, `v4.1.0.sha256`, `v5.0.0.sha256`.
  **MET as of 2026-09-19** (checked live; `git status --porcelain --
  manifests/` shows it `??` — untracked, generated after the version bump
  and the surface changes this piece's own edits contributed, matching the
  sequencing the plan specified at `docs/plans/v5-design-phase-plan.md:763-766`).
  **What this does NOT assert:** that the table is byte-reproducible from a
  tagged v5.0.0 checkout the way `UW1` established for earlier releases, or
  that any `--upgrade` run has actually classified against it — LIVE-1
  (`docs/RELEASE_AUDIT.md` `DP15`/`DP18`) upgraded a v4.1.0 target using
  that target's OWN install-manifest as the old table, never touching this
  file. Both remain open, separately from existence.
- assert: **`v4.1.0` is unmoved, and its manifest still reproduces from the
  tag's own tree** — this is the one condition this section is explicitly
  required to carry forward from every prior release, now re-verified
  against a repo that has moved 90+ commits since. Run `git rev-list -n1
  v4.1.0` and confirm `57fb88867bb13caa8b345497e4d0bae6c5f56acb` (short form
  `57fb888`). **Note for whoever re-runs this: `git rev-parse v4.1.0` alone
  is NOT the same command** — `v4.1.0` is an ANNOTATED tag
  (`git cat-file -t v4.1.0` → `tag`), so a bare `rev-parse` returns the tag
  *object's* own hash, not the commit; `rev-list -n1` (or `rev-parse
  v4.1.0^{commit}`) dereferences it. Then run
  `T=$(mktemp -d) && git archive v4.1.0 | tar -x -C "$T" && bash
  .claude/scripts/workflow-manifest.sh generate "$T" | cmp -
  manifests/v4.1.0.sha256` and confirm `cmp` is silent with exit `0`.
  **MET** (both checked live, 2026-09-18 — the tag has not moved and its
  frozen manifest still reproduces byte-for-byte from its own tree).
- assert: the Linear adapter's status is exactly NOT-PROVEN, and no shipped
  doc asserts otherwise. Run `ls docs/specs/ 2>&1` and confirm "No such file
  or directory" (the repo-fallback path has never been exercised against a
  connected workspace); run
  `grep -c 'The Linear adapter ships unproven' CHANGELOG.md` and confirm
  `>= 1`. **MET as a disclosure** (the honest, correct state for this
  release, per directive correction 4 — not a gap this section is hiding).
  Two more mechanisms for this SAME claim landed WHILE this HANDOFF section
  was being written (a sibling D7 piece, not this one), and were then
  narrowed under two rounds of independent, non-Claude review (sol-codex)
  before this section's own correction pass on 2026-09-19 — read them as a
  TRIPWIRE plus a scoped BEHAVIOURAL test, never as a completeness proof;
  their own file headers say so explicitly, in exactly those words.
  **CORRECTION: a prior draft of this section verified the L1 half with
  `grep -icE 'DESIGN_STORE.*linear|linear.*design.store'
  .claude/scripts/qa-gate.sh .claude/scripts/verify-before-stop.sh
  .claude/scripts/review-check.sh` and treated `0` as confirming the guard.
  That two-pattern grep is narrower than, and was never, the shipped
  detector — do not use it.** Run the shipped L1 spec directly instead:
  `test -f .claude/scripts/tests/design-structural.test.sh && bash
  .claude/scripts/tests/design-structural.test.sh` and confirm the last
  line reads `PASSED: 33 assertion(s)` with exit `0` (offline, no `bd`
  dependency, safe to run standalone). This asserts `qa-gate.sh`,
  `verify-before-stop.sh` and `review-check.sh` contain none of three
  tracked literal spellings (`DESIGN_STORE`, capitalised `Linear`,
  comment-stripped bare lowercase `linear`) — two rounds of independent
  review found the original single-pattern version bypassed (a natural
  `case`-arm on a prefix-stripped external ref, then case-folding and
  quote-reassembly against the three-signal redesign) and established that
  no lexical grep over a fixed three-file list can be hardened into a
  completeness proof, because a gate could source a helper file this guard
  never scans. For the L2 half, run `find . -iname 'design-degradation*'
  -not -path '*/node_modules/*'` and confirm it returns
  `./.claude/tests/component/specs/design-degradation.sh` — this spec
  proves the `review-record`/`review-check` gate sequence produces
  byte-identical stdout with `DESIGN_STORE=linear` set versus explicitly
  unset, genuinely behavioural (it drives the real gate scripts end-to-end
  against a live Beads fixture) but scoped to that one sequence; it is not
  re-run here (it writes a Beads task, and this checklist stays read-only).
  Neither mechanism is the same claim as Linear working, and this row's
  status does not change because of either.
- assert: on-disk counts match what the docs will claim once the rewrite
  piece lands. Run `ls .claude/agents/*.md | wc -l` → `9`; run
  `ls .claude/rubrics/*.md | wc -l` → `6` (the new `design.md` rubric, up
  from v4.1.0's 5); run `ls .claude/scripts/*.sh | wc -l` for the current
  script count (not pinned here — several Phase P tasks added scripts this
  arc; whoever re-runs this should compare against the docs-rewrite piece's
  own README table rather than a number frozen here). **Agents and rubrics
  MET; script-count parity is the docs-rewrite piece's condition, not
  restated here.**

**Remaining before the tag:** the version/manifest piece (`manifests/v5.0.0.sha256`
generation + regenerate-and-`cmp`), the docs-rewrite piece
(`docs/WORKFLOW.md`, `docs/ARCHITECTURE.md`, `docs/AGENTS.md`, `docs/HOOKS.md`,
`README.md`), the live-validations piece (LIVE-1/LIVE-2 execution and
recording; LIVE-3 stays NOT RUN by design), and reconciling the
`beads_ledger` doctor check via `claude-workflow-plugin-0rbi`. This piece
performs none of those and makes no commit, no tag, and no approval — per
the standing convention, the orchestrator applies the tag once every D7
piece has landed and been reviewed.

## Verify conditions for "v4.1.0 (the verifiable install) shipped"

Every number below was measured on **2026-07-30** by
`claude-workflow-plugin-uvk` on branch `gauntlet/v4.0.0` — the branch name is
historical (it carries the v4.0.0 release and 31 commits of v4.1 work on top);
the release is 4.1.0. Each suite figure comes from a run performed in that
session, one tier at a time, with the tier's own completeness line recorded
rather than the absence of failures. Deltas below are against the v4.0.0
baselines in the section immediately following this one, which is where those
numbers are attributed. A new session can confirm readiness by re-running
every command here.

- assert: `.claude-plugin/plugin.json` `version` equals `4.1.0`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `4.1.0`.
- assert: the manifest's TOP-LEVEL 2-space indentation is intact, because
  `install.sh`'s `plugin_json_version()` (`:96-101`) is a deliberately jq-free
  `sed` anchored on **exactly two spaces** and a reformat silently degrades
  every banner to the unnumbered product name. Run
  `grep -c '^  "version": "4\.1\.0",$' .claude-plugin/plugin.json` and confirm
  `1`. Cross-check with the installer's own expression, run verbatim:
  `sed -n 's/^  "version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .claude-plugin/plugin.json | head -1`
  and confirm `4.1.0`. This condition was load-bearing in v4.0.0 and stated
  nowhere; it is stated here now.
- assert: the banner is produced by EXECUTING the installer, not by reading
  it. Run `bash install.sh --help | head -3` and confirm the first line is
  `Claude Workflow Plugin v4.1.0 installer`.
- assert: there is exactly ONE version-carrying manifest, so "both manifests"
  in the plan means something else. Run
  `grep -c '"version"' .mcp.json` and confirm `0`; run
  `node -e 'const p=require("./.claude/tests/e2e/package.json");console.log(p.private,p.version)'`
  and confirm `true 0.0.0` (its only `4.0.0` is the `zod` range `^4.0.0`). The
  "both manifests" idiom is inherited from `docs/plans/verification-suite.md:47`
  and means `.mcp.json` and `.claude-plugin/plugin.json` must AGREE on their
  MCP server definitions — mechanically asserted by L1
  `platform-audit.test.sh` section (d), and not a versioning claim.
- assert: the installers carry NO hardcoded version literal, so a release is a
  one-line bump and never a refactor. Run
  `grep -nE '4\.[0-9]+\.0' install.sh install.ps1 | grep -cvE ':[0-9]+:[[:space:]]*#'`
  and confirm `0` — i.e. every one of the 7 hits (5 in `install.sh`, 2 in
  `install.ps1`) is a COMMENT line, each a provenance note naming the release
  a feature arrived in. Cross-check the denominator with
  `grep -hcE '4\.[0-9]+\.0' install.sh install.ps1` → `5` and `2`, so the zero
  above is a zero out of seven rather than a zero out of nothing.
- assert: `bash .claude/scripts/tests/run-tests.sh` exits 0. v4.1.0 L1 baseline
  is **32 test files / 0 failures / 1,540 assertions** (**+9 files** over
  v4.0.0's 23 — the delta derived from `git ls-tree v4.0.0`, not recalled:
  `packaging-parity`, `workflow-manifest`, `installer-flags`,
  `workflow-doctor`, `vendored-skills`, `mcp-deps`, `mcp-deps-preserve`,
  `completion-contract-parity`, `worktree-sweep`). Confirm
  the completeness line `Total: 32  Passed: 32  Failed: 0`, not merely the
  absence of `FAIL`. Note the runner globs `*.sh`, not `*.test.sh`, so the
  count includes the pre-existing `phase5-synthetic-tests.sh`; reproduce it
  with
  `find .claude/scripts/tests -maxdepth 1 -type f -name '*.sh' ! -name 'run-tests.sh' | wc -l`
  → `32`.
- assert: `bash .claude/tests/component/run.sh` exits 0. v4.1.0 L2 baseline is
  **41 specs / 1,983 assertions / 0 fail** (**+8 specs and +972 assertions**
  over v4.0.0's 33 / 1,011 — again derived from `git ls-tree v4.0.0`:
  `installer-v3-upgrade`, `rubric-binding`, `installer-manifest-parity`,
  `installer-target-functional`, `approve-idempotency`, `upgrade-gate-compat`,
  `worktree-sweep`, `bd-mcp`). Confirm both completeness lines:
  `Specs: Total: 41  Passed: 41  Failed: 0` and
  `Assertions: Passed: 1983  Failed: 0`.
- assert: `cd .claude/tests/e2e && npm run test:unit` reports **444 passed /
  5 skipped** across 15 files (**+14 passed** over v4.0.0's 430; skips
  unchanged at 5). The five skips are the same honest invariant-engine and
  trace-anchor artifact-missing skips — `completion-contract` (Invariant 3) is
  among them and is documented as always-skipped, not green-washed.
- assert: `make lint` is clean AND actually ran. The recipe
  skips-with-a-warning and **exits 0** when `shellcheck` is absent, so exit 0
  alone proves nothing. Run `make lint > /tmp/lint.out 2>&1; echo $?` and
  confirm `0` **with `wc -c < /tmp/lint.out` equal to `0`** — the skip branch
  prints a sentence, so zero bytes is what distinguishes clean from skipped.
  Confirm `command -v shellcheck` resolves (0.11.0 on the authoring host).
- assert: `docs/RELEASE_AUDIT.md` now holds THREE ledgers, so its greps are
  section-scoped per ledger. Run:
  - frozen v3.5.0 ledger →
    `awk '/^# Release Audit/,/^## v4\.0\.0 claims ledger/' docs/RELEASE_AUDIT.md | grep -cE '\| PROVEN \|$'`
    and the three sibling statuses → confirm `51 / 47 / 0 / 23`; row-id count
    via `grep -cE '^\| [A-Z]+[0-9]+[a-z]? \|'` over the same range → `121`
    (the optional trailing letter is required: rows `P6a` and `P6b` exist, and
    without it the count reads `119`).
  - v4.0.0 ledger →
    `awk '/^## v4\.0\.0 claims ledger/,/^## v4\.1\.0 claims ledger/' docs/RELEASE_AUDIT.md | grep -cE '\| PROVEN \|$'`
    → confirm `14 / 0 / 0 / 0`, row-ids `14`.
  - v4.1.0 ledger →
    `awk '/^## v4\.1\.0 claims ledger/,/^## v5\.0\.0 claims ledger/' docs/RELEASE_AUDIT.md | grep -cE '\| PROVEN \|$'`
    and siblings → confirm `13 / 3 / 0 / 0`, and
    `grep -cE '^\| UW[0-9]+ \|'` over the same range → `16`.
    **RE-SCOPED 2026-09-18 (`claude-workflow-plugin-fkm.9`), counts
    unchanged.** This range used to end at `,0` — end-of-file — which was
    right only while v4.1.0 was the last claims-ledger section. A fourth
    ledger (`v5.0.0`) now sits below it, so the open-ended form would have
    silently folded its rows into v4.1.0's counts (17 at this ledger's
    2026-09-18 compilation; 18 as of 2026-09-19, after `DP18`). Same correction,
    same reason, as the v3.5.0 → v4.0.0 and v4.0.0 → v4.1.0 ones above and
    below.
  - assert the trap is still closed: the v4.0.0 range must NOT end at `,0`.
    Run `grep -cF 'v4\.0\.0 claims ledger/,0' docs/RELEASE_AUDIT.md` and
    confirm `0`; run
    `grep -cF 'v4\.0\.0 claims ledger/,/^## v4\.1\.0 claims ledger/' docs/RELEASE_AUDIT.md`
    and confirm `5` (all five ranges bounded).
  - assert the trap is closed a second time, at the section that used to be
    exempt: the v4.1.0 range must NOT end at `,0` either, now that v5.0.0
    exists. Run `grep -cF 'v4\.1\.0 claims ledger/,0' docs/RELEASE_AUDIT.md`
    and confirm `0` — this is the exact string that was `5` (and cited as a
    *positive* control) before the v5.0.0 ledger landed; run
    `grep -cF 'v4\.1\.0 claims ledger/,/^## v5\.0\.0 claims ledger/' docs/RELEASE_AUDIT.md`
    and confirm `5` (all five ranges re-bounded to the new last ledger).
    **Positive control, so the zero above is not vacuous:**
    `grep -cF 'v5\.0\.0 claims ledger/,0' docs/RELEASE_AUDIT.md` → `5` — the
    grep CAN find this shape, and those five are v5.0.0's own ranges, which
    end at `,0` legitimately because v5.0.0 is currently the last
    claims-ledger section (`## Standing attestations` follows it but carries
    no status cells and no `| V<n> |`-shaped rows, so it does not count as a
    ledger for this purpose). With the open-ended form the v4.1.0 range
    would return `24 / 9 / 1 / 0` instead of `13 / 3 / 0 / 0`, which is
    measured against the shipped v5.0.0 section as it stands after `DP18`
    (2026-09-19; it read `24 / 8 / 1 / 0` against the 17-row section at this
    block's original 2026-09-18 measurement), not hypothetical. This is
    the third time this exact correction has been paid (v3.5.0 → v4.0.0,
    v4.0.0 → v4.1.0, and now v4.1.0 → v5.0.0) and RELEASE_AUDIT.md's own
    tally block carries the standing instruction to whoever appends a fifth
    ledger next.
- assert: a stock 4.1.0 target classifies against its OWN hashes. Run
  `ls manifests/` and confirm both `v3.5.0.sha256` and `v4.1.0.sha256` are
  present. `install.sh:1315-1322` falls back to `manifests/v3.5.0.sha256`
  when a target has no `install-manifest` and no table matches its detected
  version, so without this file every unchanged 4.1 file would be classified
  against v3.5's hashes and reported as customized.
- assert: the v4.1.0 manifest is byte-reproducible **from the tree of the tag it
  names**. Run
  `T=$(mktemp -d) && git archive v4.1.0 | tar -x -C "$T" && bash .claude/scripts/workflow-manifest.sh generate "$T" > /tmp/m1 && cmp /tmp/m1 manifests/v4.1.0.sha256`
  and confirm `cmp` is silent with exit `0`, and
  `wc -l < manifests/v4.1.0.sha256` → `132` (119 `workflow` + 11 `operator` +
  2 `merged`; the frozen `v3.5.0.sha256` is `117`). Determinism is load-bearing: the
  generator may embed no timestamp, hostname, locale-dependent sort or
  unordered glob, and this comparison is what enforces that.
  **Against the TAG, never against `.`.** This line used to read `generate .`,
  which compares a LIVE WORKING TREE against a table frozen at the release
  commit `57fb888` — red by construction, and red on a load-bearing determinism
  assert with nothing to tell stale-table drift from a broken generator.
  Measured 2026-08-07 at `1a3d59b`: **73 differing lines**, from 36 rows whose
  hash moved after the freeze plus `.claude/scripts/beads-ledger.sh`, which did
  not exist at the tag. That is expected drift. The table is correct for the
  tree it names, and the tag is not moving
  (`docs/plans/v5-design-phase.md`, correction-layer decision 2).
  **Do not "fix" a red here by regenerating the table.** A `v4.1.0.sha256`
  regenerated at HEAD no longer describes v4.1.0's tree, so an operator
  upgrading from a real v4.1.0 install matches neither the new source nor the
  recorded oldhash on any drifted row, lands on `preserve-custom`
  (`workflow-manifest.sh:490-503`) and collects `.new` sidecars for files they
  never touched — the defect class `016` closed, reintroduced from the other
  side. Regenerate at the D7 refreeze, against the tag that release actually
  ships. Automated as `.claude/scripts/tests/workflow-manifest.test.sh`
  Section 6, which runs this comparison on every L1 run for whichever release
  `.claude-plugin/plugin.json` currently names, and prints a `note:` skip rather
  than a failure when that tag or table is not in the checkout
  (`claude-workflow-plugin-ce5`).
- assert: there are exactly TWO `SKILL.md` files in the plugin's own surface —
  one registered skill and one vendored reference. Run
  `find .claude -name SKILL.md -not -path '*/node_modules/*' -not -path '*/tests/e2e/*' | wc -l`
  and confirm `2`. **Both exclusions are required and neither is cosmetic:**
  the bare `find .claude -name SKILL.md | wc -l` returns **15**, because the
  e2e fixtures each carry a copy of the workflow-engine skill (and two nested
  harness worktrees carry more) and `node_modules` ships four unrelated
  vendor skills. Cross-check the registration half with
  `jq '.skills | length' .claude-plugin/plugin.json` → `1`.
- assert: the vendored reference is NOT registered as a skill. Run
  `jq -r '.skills[]' .claude-plugin/plugin.json` and confirm the sole entry is
  `./.claude/skills/workflow-engine` — nothing under `.claude/vendor/`. Run
  `grep -c '3dcbd5c4' .claude/vendor/superpowers/MANIFEST.md` → `5` and
  `grep -c '3dcbd5c4' THIRD_PARTY.md` → `1`, confirming both files carry the
  pin (`vendored-skills.test.sh` asserts a single distinct pin across them,
  so agreement is mechanical, not eyeballed).
- assert: install verification is functional rather than presence-based. Run
  `make install-test` and confirm exit `0` with the doctor reporting
  **11 passed / 0 failed / 0 skipped**. It was 9 passed / 2 failed before
  C0b — that pair WAS the P0, reproducing in CI instead of in a teammate's
  project.
- assert: the MCP tool counts the doctor enforces match the servers. Run
  `grep -rhA1 'registerTool(' .claude/mcp/bd-mcp/src/tools/*.js | grep -oE "'bd_[a-z_]+'" | sort -u | wc -l`
  → `21`, and `ls .claude/mcp/code-graph-mcp/src/tools/*.js | wc -l` → `7`.
  These are the exact equalities `workflow-doctor.sh` asserts over stdio; a
  server that boots but registers nothing is what "the config parses" missed.
- assert: `README.md`'s on-disk table matches the tree. Run
  `ls .claude/agents/*.md | wc -l` → `7`, `ls .claude/scripts/*.sh | wc -l` →
  `26`, `ls .claude/commands/*.md | wc -l` → `3`,
  `ls .claude/rubrics/*.md | wc -l` → `5`. The commands row read `2` before
  this release; `/workflow-doctor` is the third.
- assert: the spawn-depth pin is unchanged and its retirement date is retired.
  Run `grep -c 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH.*1' .claude/settings.json`
  and confirm `≥ 1`. U6 (`claude-workflow-plugin-7be`) is CLOSED as
  need-triggered, not calendar-deferred: **the 2026-08-23 next-check date on
  that task is retired and is not a live date**, and the standing task
  `claude-workflow-plugin-1bn` states the trigger as a condition.
- assert: no living doc names 4.0.0 as the CURRENT version (dated per-release
  records below deliberately still do). Run
  `grep -rn 'v4\.0\.0' README.md docs/QUICKSTART.md | grep -viE 'changelog|since|release|prior|previous|4\.1'`
  and confirm nothing describes 4.0.0 as current.

**Remaining before the tag:** the commit, the tag and the push are the
operator's steps — this closeout task performs none of them. The PR #4 body is
prepared at `/tmp/pr-body-v4.1.0.md` and was deliberately NOT applied with
`gh pr edit`.

## Verify conditions for "v4.0.0 (tri-model workflow) shipped"

Every number below was measured on 2026-07-26 by `claude-workflow-plugin-d2j.1`
on `gauntlet/v4.0.0`. A new session can confirm readiness by re-running them.

- assert: `.claude-plugin/plugin.json` `version` equals `4.0.0`. Run
  `node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'`
  and confirm `4.0.0`.
- assert: both MCP manifests agree. `.mcp.json` and
  `.claude-plugin/plugin.json` declare the SAME server name set
  (`bd`, `code-graph`), both as `"type": "stdio"`, with `.mcp.json` keeping
  the literal `${CLAUDE_PROJECT_DIR:-.}` form. Mechanically asserted by L1
  `platform-audit.test.sh` section (d).
- assert: `make test` exits 0. v4.0.0 L1 baseline is **23 test files / 0
  failures** (+7 over v3.5.0's 16: `model-roles`, `review-check`,
  `review-count`, `review-separation`, `denylist-source`, `platform-audit`,
  `make-session`).
- assert: `bash .claude/tests/component/run.sh` exits 0. v4.0.0 L2 baseline is
  **33 specs / 1011 assertions / 0 fail** (+11 specs and +369 assertions over
  v3.5.0's 22 / 642).
- assert: `cd .claude/tests/e2e && npm run test:unit` reports **430 passed /
  5 skipped** across 15 files (+62 over v3.5.0's 368, chiefly the 102-case
  `_invariants.unit.spec.ts` incl. `approval-cites-independent-review`). The
  five skips are the same honest invariant-engine / trace-anchor
  artifact-missing skips, not green-washed.
- assert: `make lint` clean (shellcheck over all hook + test + mutation
  scripts + install/uninstall).
- assert: `docs/RELEASE_AUDIT.md` now holds TWO ledgers, so its greps are
  **section-scoped** (this supersedes the file-wide greps in the v3.5.0 block
  below — the frozen counts are unchanged, the command is not). Run:
  - frozen v3.5.0 ledger →
    `awk '/^# Release Audit/,/^## v4\.0\.0 claims ledger/' docs/RELEASE_AUDIT.md | grep -cE '\| PROVEN \|$'`
    and the three sibling statuses → confirm `51 / 47 / 0 / 23`, row-id count
    `121`.
  - v4.0.0 ledger →
    `awk '/^## v4\.0\.0 claims ledger/,/^## v4\.1\.0 claims ledger/' docs/RELEASE_AUDIT.md | grep -cE '\| PROVEN \|$'`
    → confirm `14 / 0 / 0 / 0`, and
    `grep -cE '^\| TM[0-9]+ \|'` over the same range → `14`.
    **RE-SCOPED 2026-07-30 (`claude-workflow-plugin-uvk`), counts unchanged.**
    This range ended at `,0` — end-of-file — which was right only while
    v4.0.0 was the last section. A third ledger now sits below it, so the
    open-ended form returns `27 / 3` and would have made the v4.0.0 verdict
    line a false statement about rows it never audited. Same correction, same
    reason, as the v3.5.0 → v4.0.0 one directly above.
- assert: sign-off separation is mechanical at BOTH gate ends. Run
  `grep -c 'REVIEW-SEPARATION' .claude/scripts/qa-gate.sh` (≥ 1) and
  `grep -c 'REVIEW-DISCIPLINE' .claude/scripts/verify-before-stop.sh` (≥ 1);
  a self-review (reviewer identity == a recorded implementer) must fail
  `approve` with exit 4 and must not release the Stop hook.
- assert: cross-worktree approval resolution ships. Run
  `grep -c 'WORKTREE-RESOLUTION' .claude/scripts/verify-before-stop.sh` and
  `grep -c 'WORKTREE-TOKEN' .claude/scripts/qa-gate.sh` (both ≥ 1).
- assert: one denylist, three consumers.
  `grep -l 'workflow-denylist.sh' .claude/scripts/{post-edit,impact-report,verify-before-stop}.sh | wc -l`
  is `3`.
- assert: the effort verdict is readable and `make session` honours it. The
  first non-comment line of `.claude/effort-verdict` is `max`; L1
  `make-session.test.sh` runs the real Makefile target against a stub
  `claude` and asserts the argv.
- assert: `README.md` carries a "The tri-model workflow" section linking
  `docs/CODEX_SETUP.md`, and no living doc names 3.5.0 as the CURRENT version
  (dated per-release records below deliberately still do).

**DONE since, 2026-07-26 (`claude-workflow-plugin-d2j.2`):** the two paid live
tri-model validations both PASSED — Codex connected (a real `gpt-5.6-sol`
review turn → a genuine medium finding → gate BLOCK → arbitration overrule →
gate PASS) and the identical flow with Codex absent (Claude lane, same
artifact schema, same two decisions). RELEASE_AUDIT rows TM7/TM14 now carry
the live result together with its scope caveat: the subject was a small
synthetic harness driven through the gate scripts directly, so no e2e trace
was captured and the `approval-cites-independent-review` invariant remains
proven offline only. Two free, re-runnable assertions over committed Beads
state (the review artifact JSON itself is per-session ephemera under the
gitignored `.claude/.qa-tracking/`, so it is deliberately NOT the durable
evidence):

- assert: the Sol-lane record survives in Beads. Run
  `bd show claude-workflow-plugin-d2j.2 --json | jq -r '.[].comments[]?.text' | grep -cE 'REVIEW-ARTIFACT v1 .*reviewer=sol-codex model=gpt-5\.6-sol .*verdict=findings'`
  → `1`, and the same pipeline with `-cE '^ARBITRATION R1-F1 decision=overrule'`
  → `1`.
- assert: the Codex-absent twin used the same grammar on the Claude lane. Run
  the same pipeline against `claude-workflow-plugin-d2j.2.1` with
  `-cE 'REVIEW-ARTIFACT v1 .*reviewer=qa-claude model=claude-fable-5'` → `1`.

**Remaining before the tag:** nothing in the plan — the tag itself is the
orchestrator's step.

## Verify conditions for "v3.5.0 (Release Acceptance Gauntlet) shipped"

> **HISTORICAL SNAPSHOT — as-of 2026-06-14, kept unedited.** Like the
> v3.4.1 block further down, this section records what the tree looked
> like at *that* release; it is not a statement about the current tree.
> The version and RELEASE_AUDIT-grep assertions below are stale by design
> — for the current tree use the v4.0.0 block above (`version` is `4.0.0`,
> and the RELEASE_AUDIT greps are section-scoped).

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

# AgentLint report — post Phase C (claude-workflow-plugin-n45)

> For design rationale behind deferred AgentLint findings, see
> `docs/plans/v3-upgrade.md`, `docs/plans/verification-suite.md`, and
> the "Design overrides vs. AgentLint" section in `CONTRIBUTING.md`.

**AgentLint version**: 1.1.13 (CLI: `agentlint check`).

**Date**: 2026-06-12 (post-Phase-C verified; v3.4.0 release closeout).

**Command**: `agentlint check --format md --output-dir docs/` (also
exposed as `make check`).

## Summary

Current run (post Phase C): **87/100** — unchanged from the
post-Phase-0 / post-Phase-A / post-Phase-B baseline, and Phases
B + C introduce no new deterministic-detector findings.

### Score history

The table has been retired in favour of a list — four columns of
dimension scores were getting cramped. Each entry below is a single
release closeout; "Δ" notes what moved versus the prior entry.

- **Phase 7 baseline — 90/100.** Findability 10, Instructions 10,
  Workability 8, Continuity 10, Safety 8, Harness 7. Recorded
  immediately after Phase 7 closed (Beads
  `claude-workflow-plugin-y4a.14`).
- **Post G8 Phase F — 87/100.** Δ versus Phase 7: Workability gained
  W2 (CI now exists, +2), Safety lost S2 (new actions tag-pinned
  rather than SHA-pinned, -4). Net -3.
- **Post Phase 0 (v3.1.0) — 87/100.** Δ versus Phase F: no overall
  change. Composition shifted inside Safety — S7 (no personal paths
  in source) flipped from 1 → 0 as a detector-visibility artifact
  (the G8 fixture infrastructure expanded enough that the
  project-wide sample now reaches the legacy comment in
  `qa-gate.sh:450` and the fixture `bd` shims). Other dimensions
  unchanged.
- **Post Phase A (v3.2.0) — 87/100.** Δ versus Phase 0: none.
  Phase A's new files (`grader.md`, the rubric set, the rubric
  config, the `qa-gate-grade-record.test.sh` L1 spec, the
  `rubric-loop.sh` L2 spec, and the `rubric-revision-loop` e2e
  fixture) pass every deterministic detector in the same shape as
  the rest of the repo: no personal paths in the prompts or
  rubrics; no emphasis-keyword spam (I1/I2 pass); no new hook
  scripts (H1–H8 unchanged); no new workflows (S2 unchanged); no
  new permissions (H4 unchanged). The `rubric-revision-loop`
  fixture follows the existing fixture convention (a `bd` shim
  hardcoding `/Users/edk0/.local/bin/bd` and a fixture-local copy
  of `qa-gate.sh` carrying the legacy `_legacy_project_slug`
  example comment); both fall under the documented S7 override —
  fixtures are test infrastructure under `.claude/tests/`, never
  shipped to operators. AgentLint reports the same count of seven
  S7-flagged files as Phase 0; the override rationale in
  `CONTRIBUTING.md` is unchanged.
- **Post Phase B (v3.3.0) — 87/100.** Δ versus Phase A: none.
  Phase B replaced `code-context-mcp` with `code-graph-mcp` (the
  retired server was removed, the new server's 31 tests shipped
  under `.claude/mcp/code-graph-mcp/`) and added the
  `agent-mcp-tools-parity.test.sh` L1 + extended the
  `installer-mcp-config.sh` L2 with five Phase-B-specific
  assertions. No new agent files; no new permissions; no new
  workflows. The byte-compatible trio (`code_search`,
  `code_context`, `symbol_callers`) preserved the surface the
  rubric grader / orchestrator / QA prompts call by name, so the
  prompt-side detectors saw zero diff. AgentLint's S7 count is
  unchanged.
- **Post Phase C (v3.4.0) — 87/100.** Δ versus Phase B: none.
  Phase C's new files (`judge.md` agent prompt; the mutation
  tier under `.claude/tests/mutation/` with `mutation-sweep.sh`,
  `fault-classes.md`, `mutation.conf`, `judge-gate.sh`, the
  hand-labeled calibration set, and the two new L1 specs
  `mutation-harness.test.sh` + `judge-calibration.test.sh`;
  the `/mutation-sweep` Claude-invokable command; the
  `JUDGE-RELAY` block in `orchestrator.md` section 5b) all pass
  every deterministic detector in the same shape as the
  Phase A surface: no personal paths in the prompts or harness;
  no emphasis-keyword spam (I1/I2 pass); no new hook scripts
  (H1–H8 unchanged); no new workflows (S2 unchanged); no new
  permissions (H4 unchanged); the `agents[]` manifest covers
  `judge.md`. The `installer-mcp-config.sh` L2 spec was extended
  with 10 Phase A + C presence assertions covering the
  rendered-install surface (grader.md, judge.md, rubrics,
  mutation tier, model-ranking, LESSONS.md). The C.4 installer
  fix glob-copies all agents under `.claude/agents/*.md`
  (was hardcoded to the 5 v3.0 roles, silently dropped grader.md
  from v3.2.0 and judge.md from v3.4.0 in fresh installs). S7
  count is unchanged from Phase 0 / A / B; calibration `runs/`
  artefacts under `.claude/tests/mutation/calibration/runs/`
  are gitignored at the live-run-dir level (tracked
  per-checkpoint via the explicit `calibration-report.json` +
  `verdict.json` filenames), so no new S7-flagged personal-path
  surface is introduced.

## Phase A closeout — 2026-06-11

The Phase A release (v3.2.0) added 1 new agent prompt
(`.claude/agents/grader.md`), 5 new rubric files
(`.claude/rubrics/{default,backend,frontend,devops}.md` plus the
`bugfix.md` overlay), 1 new config file (`.claude/rubric-config`),
1 new L1 test (`qa-gate-grade-record.test.sh`, 87 assertions),
1 new L2 spec (`rubric-loop.sh`, 44 assertions), 1 new e2e fixture
(`rubric-revision-loop/`), substantive edits to two scripts
(`qa-gate.sh` for `grade-record` + the `rubric-pending` lifecycle;
`statusline.sh` for the rubric segment), one agent prompt
(`qa.md` section 6 — the grading loop), one doc (`docs/AGENTS.md`
— 5 → 6 agents), and one label-table refresh (`docs/WORKFLOW.md`).
The overall AgentLint score holds at **87/100** with no composition
change. Every dimension scored identically to the Post-Phase-0
column above.

The new files are structurally invisible to the deterministic
detector for the same reasons the Phase 0 additions were: the
grader prompt and rubrics are agent-style markdown (passing I1/I2
emphasis density and rule-specificity); the L1/L2 specs live under
`.claude/scripts/tests/` and `.claude/tests/component/specs/`
(W3 already counts the directory globally, not per-file); and the
fixture follows the existing G8 convention (no new hook scripts,
no new workflows, no new permissions). The `rubric-revision-loop`
fixture copies the `bd` shim and `qa-gate.sh` from the existing
fixture template — both already flagged under S7 and already
documented as overrides; the count of S7-flagged files holds at
seven because the detector's reporting groups by symbol pattern,
not per-file.

No new H-tier (hook harness) findings. No new W-tier (workability)
findings. No new I-tier (instructions) findings. The Phase 0
deductions (W4, W11, S2, S3, S7, S9, plus the H3 partial and the
H4 design override) carry forward unchanged.

The single manual live validation
(`make test-live FIXTURE=rubric-revision-loop`) is pending; it
exercises the grader subagent end-to-end against the fixture's
deliberately-under-tested prompt, and its recorded result will be
appended to the `claude-workflow-plugin-l1r.4` closeout notes when
run. AgentLint does not evaluate live runs, so this report's score
is final for the v3.2.0 release.

## Phase C closeout — 2026-06-12

The Phase C release (v3.4.0) added 1 new agent prompt
(`.claude/agents/judge.md`), a new tier under
`.claude/tests/mutation/` (`mutation-sweep.sh`, `fault-classes.md`,
`mutation.conf`, `judge-gate.sh`, `lib/generate.sh`,
`lib/rank-targets.sh`, the `calibration/` directory with a
24-mutant calibration-set, plus the README), 1 new Claude-invokable
command (`.claude/commands/mutation-sweep.md`), 2 new L1 tests
(`mutation-harness.test.sh` and `judge-calibration.test.sh`,
together carrying 83 assertions and 4 META-TESTs), extensions to
the `installer-mcp-config.sh` L2 spec (+10 presence assertions for
the Phase A + C surface), and substantive edits to two scripts
(`install.sh` glob-copies all 7 agents + ships rubrics + mutation
tier + LESSONS.md + model-ranking + `.worktreeinclude`; same in
`install.ps1`). One new agent file (`judge.md`) lands in
`plugin.json` agents[] in the same commit per the manifest-parity
lesson; agents[] now declares 7 entries. The overall AgentLint
score holds at **87/100** with no composition change. Every
dimension scored identically to the Post-Phase-B column above.

The new files are structurally invisible to the deterministic
detector for the same reasons the Phase 0 / A / B additions were:
the judge prompt is agent-style markdown (passing I1/I2 emphasis
density and rule-specificity); the harness + L1 specs live under
`.claude/tests/mutation/` and `.claude/scripts/tests/` (W3 counts
the directories globally); and the new command file follows the
existing `/workflow-model` convention. The mutation tier introduces
NO new permissions, NO new hook scripts (the harness is invoked
manually via `make` / `/mutation-sweep`, never wired into a hook
event), and NO new workflow files. The calibration-set's `runs/`
artefacts are tracked per-checkpoint with explicit filenames
(`2026-06-12-calibration-report.json` +
`2026-06-12-verdict.json`); the live run directories are gitignored
at the wildcard level so no per-session personal paths leak into
the tracked tree.

The S7 count holds at the same seven files as Phase 0 / A / B —
the legacy `qa-gate.sh:450` comment and the six fixture `bd` /
`qa-gate.sh` shims under `.claude/tests/e2e/fixtures/`. The
override rationale in `CONTRIBUTING.md` remains valid for both
classes; nothing in Phase C introduces a new fixture or new
shim. No new H-tier, W-tier, or I-tier findings. The Phase 0
deductions (W4, W11, S2, S3, S7, S9, H3 partial, H4 design
override) carry forward unchanged.

The single manual calibration round
(`/mutation-sweep` → JUDGE-RELAY with the 24-mutant calibration
set as packet) was run 2026-06-12 in-session (zero API spend via
the operator's existing Claude session): precision 0.9412 /
recall 0.9412 — GATE PASSED (0.8 threshold). The acceptance sweep
over `verify-before-stop.sh` + `post-edit.sh` (32 mutants, 4
killed, 28 survived; judge 27 genuine / 1 equivalent) generated
the 26-survivor backlog tracked as `claude-workflow-plugin-6ix`
and produced one killing test for survivor id 12 (8 new L2
assertions on `verify-before-stop.sh`). AgentLint does not
evaluate dev-cycle mutation runs, so this report's score is final
for the v3.4.0 release.

## Phase B closeout — 2026-06-12

The Phase B release (v3.3.0) replaced the `code-context-mcp` server
with `code-graph-mcp` (a tree-sitter + SQLite code graph; 7 tools;
31 server tests under `.claude/mcp/code-graph-mcp/`), added one new
L1 test (`agent-mcp-tools-parity.test.sh`, parity guard for
`mcp__*` tool references), extended the `installer-mcp-config.sh`
L2 spec with 5 Phase-B-specific assertions, and made substantive
edits to `orchestrator.md` (section 1a impact_of pre-delegation
step) + `qa.md` (section 3a impact_of regression scan) + both
manifests (`.mcp.json` and `.claude-plugin/plugin.json`; same
commit per the manifest-parity lesson). The byte-compatible trio
(`code_search`, `code_context`, `symbol_callers`) preserved the
input schemas and primary output keys; only the `tool` / `backend`
value strings changed (`"git-grep"` → `"graph-index"`). The
overall AgentLint score holds at **87/100** with no composition
change.

The new server lives under `.claude/mcp/code-graph-mcp/` with a
node-driven indexer + tool surface; the harness ships 10 vendored
wasm grammars (~9.6 MB) so first-tool-call builds the index lazily
with no SessionStart parse cost. AgentLint's S7 count is unchanged
— the new server brings no personal paths into the tracked tree.

No new H-tier (hook harness) findings. No new W-tier findings. No
new I-tier findings. The Phase 0 / A deductions carry forward
unchanged.

The Phase B live validation ran across 4 paid attempts
(~$16-26 total, 3 paid + 1 free pre-fix attempt): run 3 verified
beads capture, run 4 verified the `satisfiesInvariants` engine
end-to-end (3 invariants PASS, 1 SKIP, 2 FAIL — both FAIL paths
tracked as standalone carried bugs: `n6d` for the
`qa-queried-impact-of` invariant, `9ke` for the
`label-milestones` engine bug).

## Phase 0 closeout — 2026-06-11

The Phase 0 release (v3.1.0) added 5 new helper scripts
(`model-select.sh`, `workflow-model-apply.sh`, `lessons.sh`, plus 5
new L1 test files and 3 new L2 specs), one new top-level data file
(`LESSONS.md`), one new config file (`.claude/model-ranking`), one
new include manifest (`.worktreeinclude`), and substantive edits to
all six agent prompts (the shared time-budget block + per-agent
`effort: max` frontmatter + evidence-before-fix protocol). The
overall AgentLint score holds at **87/100** with one composition
change inside Safety:

| Check | Phase F | Post-0 | Direction |
| ----- | ------- | ------ | --------- |
| **S7** — No personal paths in source | 1 | **0** | Regressed |

The S7 regression is a detector-visibility artifact, not a Phase 0
introduction. AgentLint's pattern is "any `/Users/` or `/home/` in
tracked source"; the seven files now flagged contain either the
fictitious `/Users/foo/Desktop/projects/bar` comment used to document
the `_legacy_project_slug` transform in `qa-gate.sh:450` (also
present in the six G8 fixture copies of that script) or the
G8-era `.claude/tests/e2e/fixtures/<name>/.claude/bin/bd` shims that
hardcode `/Users/edk0/.local/bin/bd` for cassette recording. Both
predate Phase 0; the detector now sees them because the surrounding
fixtures grew in size from the 0.8 invariant work and the report
sample is project-wide. Documented as a design override in
`CONTRIBUTING.md` — fixtures are test infrastructure, never shipped
to operators. The math (S2 + S3 + S7 + S9 = 4 deductions =
Safety 6/10) holds the dimension flat versus Phase F since S2's
deduction is already counted there.

No other Phase 0 changes regressed any check. The shared time-budget
block, evidence-before-fix language, and new helper scripts pass I1
(emphasis), I2 (density), W1 (build/test docs), and W3 (test files)
in the same shape as before; the AgentLint harness checks (H1–H8)
are unchanged because the hook events and structure didn't move.

## Where the score lives now

The score stalls at 87/100 because the structural gaps from Phase F
(W4, W11, S2, S3, S9) plus the new visibility on S7 cover ground the
deterministic detector can't see through:

- **W4** — shellcheck-only setup not recognised.
- **W11** — runtime QA gate is invisible to the static detector.
- **S2** — `@v4` tag-pinning on actions (readability over SHA hardening).
- **S3** — gitleaks pre-commit / CI job is a tracked follow-up
  (`claude-workflow-plugin-a7y`, P2).
- **S7** — example slug comment + G8 fixture infrastructure
  (documented overrides, not personal-data exposure).
- **S9** — committer-email PII in git history (destructive to rewrite).

See "Why we didn't hit 96+" below for the original framing; the four
detector gaps are unchanged, and S7 joins the documented-overrides
list rather than blocking ship.

### What moved

Two checks flipped between the two runs:

| Check | Phase 7 | Phase F | Direction |
| ----- | ------- | ------- | --------- |
| **W2** — CI workflow exists | 0 | **1** | Improved |
| **S2** — Actions SHA-pinned | 1 | **0** | Regressed |

W2 is the headline win from G8 Phase E: `.github/workflows/test.yml`
lands a five-tier CI pipeline (lint → L1 → L2 → L3-unit → manifest →
L3-live → L4-drift) and the detector now sees a real CI signal.

S2 is the cost of W2: the new workflow tag-pins its actions
(`actions/checkout@v4`, `actions/setup-node@v4`, `actions/upload-artifact@v4`,
`actions/download-artifact@v4`) for readability rather than SHA-pinning
them. AgentLint reports 0/15 SHA-pinned action references. Net score
change is -3 (one fix worth 2 in Workability, one regression worth 4 in
Safety; the dimension weighting nets to -3 overall).

No new failures introduced by the `.claude/tests/` directory or the
e2e/component fixture tree. AgentLint's harness checks (H1, H2, H3, H4,
H5, H6, H7, H8) all returned the same scores as Phase 7 — the new tree
is structurally invisible to the static detectors.

The companion artifacts live alongside this file:

- `AGENTLINT_REPORT.html` — full HTML report from the AgentLint run.
- `AGENTLINT_REPORT.jsonl` — raw per-check measurements (machine-readable).

## Why we didn't hit 96+

The Phase F target was 96/100 conditional on W2, W4, and W11 all clearing
post-G8. In practice:

1. **W2 cleared** — CI now exists. Worth +2 in Workability.
2. **W4 did NOT clear.** AgentLint's W4 detector is JS/Python/Ruby/Go-
   centric and doesn't recognise shellcheck-only setups. `make lint`
   runs shellcheck across every hook script and the installers; the CI
   `lint` job runs the same thing. The substantive coverage is in
   place — the detector just can't see it. Documented in CONTRIBUTING.md
   under "Design overrides vs. AgentLint".
3. **W11 did NOT clear.** AgentLint looks for a `test-required.yml`
   workflow that gates feat/fix commits on paired test commits. The
   plugin enforces the same contract via `verify-before-stop.sh` (the
   QA gate refuses Stop without `qa-approved`, and `qa-approved`
   requires the gate to see passing tests). That's a runtime gate
   rather than a CI workflow; the detector can't see it either.
4. **S2 regressed** — the new actions in `test.yml` are tag-pinned
   (`@v4`) rather than SHA-pinned. -4 in Safety.

Net: W2 buys +2, S2 costs -4, W4 and W11 are unchanged structural
gaps in the detector. We end at 87, three points below the Phase 7
baseline.

## Deferred (Phase 7 baseline + Phase 0 additions)

These checks remain failing or partial. Each is logged so future
contributors don't try to "fix" them without reading this section.
S7 was added to the deferred list during the Phase 0 closeout.

1. **H3 — Stop hook circuit breaker (0.5/1, partial)**. The script
   contains the `stop_hook_active` guard. AgentLint's static analyzer
   in `extract_script_path` can't resolve `$CLAUDE_PROJECT_DIR` inside
   the hook command string and reports the path as unresolvable.
   Switching to a relative path or `bash -c '...'` would either break
   correctness under cwd-changing sessions or introduce a string-quoting
   nightmare in `settings.json`. We accept the partial score; the
   runtime behaviour is correct.
2. **H4 — dangerous Bash auto-approve (0/1)**. Principle 3 of the v3
   plan (`docs/plans/v3-upgrade.md`) is "full autonomy, no permission
   prompts." `Bash` in `permissions.allow` is intentional. Compensating
   controls: `prevent-orchestrator-edits.sh` (orchestrator can't write
   code), the QA gate (no Stop without `qa-approved`), and the
   structured-output contract that surfaces every action a specialist
   takes.
3. **W4 — linter configured (0/1)**. See "Why we didn't hit 96+" §2.
   shellcheck is wired through `make lint` and the CI `lint` job; the
   detector doesn't recognise shell-only setups.
4. **W11 — test-required gate (0/1)**. See "Why we didn't hit 96+" §3.
   The runtime QA gate enforces the same contract via
   `verify-before-stop.sh`.
5. **S3 — secret scanning configured (0/1)**. Gitleaks or pre-commit
   secret scanning is a CI concern. The `SECRETS` module in the QA
   agent's review pass already covers this on every commit the plugin
   gates; adding gitleaks is a tracked follow-up.
6. **S9 — personal email in git history (0/1)**. AgentLint flags the
   committer email `atsamaz@preql.com` in commit history. Rewriting
   committed history is destructive and can break downstream forks; we
   don't perform it without an explicit user request. New commits
   should prefer a project-anonymous email when feasible.
7. **S7 — no personal paths in source (0/1)**. Flagged in
   `.claude/scripts/qa-gate.sh:450` (a `/Users/foo/Desktop/projects/bar`
   example in the `_legacy_project_slug` comment — not a real path),
   the six fixture copies of `qa-gate.sh` carrying the same comment,
   and the six `.claude/tests/e2e/fixtures/<name>/.claude/bin/bd` shim
   files that hardcode `/Users/edk0/.local/bin/bd` for G8 cassette
   recording. Fixtures are test infrastructure under `.claude/tests/`,
   never shipped to operators. The example comment is documentation.
   Documented in `CONTRIBUTING.md` under "Design overrides vs.
   AgentLint".

## New (introduced by G8 Phase E)

1. **S2 — Actions SHA-pinned (0/1)**. New `.github/workflows/test.yml`
   uses `@v4` tag-pinning for `actions/checkout`, `actions/setup-node`,
   `actions/upload-artifact`, `actions/download-artifact`. Tag-pinning
   is industry-standard but AgentLint enforces SHA-pinning as a
   supply-chain hardening measure. Reasonable follow-up; not addressed
   in this phase.

## How to re-run

```bash
make check
# Equivalent to:
agentlint check --format md --output-dir docs/
```

The run is deterministic, local-only, and does not call any network
service or sub-agent. It overwrites this file's companion artifacts
(`AGENTLINT_REPORT.html` and `AGENTLINT_REPORT.jsonl`) on every run.

## Phase 8+ Roadmap

The deferred Safety findings recover the path to 91–93 with three
concrete tasks. None are blockers for v3 / G8 shipping; all are tracked
in Beads.

- **S2 — Migrate GitHub Actions to SHA-pinned versions** (recovers +4
  in Safety; tracked as Beads `claude-workflow-plugin-8oz`, P2). Replace
  `actions/checkout@v4` etc. with the resolved SHA, plus a Dependabot
  rule to keep them current.
- **S3 — Add gitleaks pre-commit + CI job** (recovers +2 in Safety;
  tracked as Beads `claude-workflow-plugin-a7y`, P2). Wires a
  `gitleaks detect` step into `.github/workflows/test.yml` and a
  pre-commit hook for local-first feedback.
- **S9 — Anonymize personal email in git history for shared
  distributions** (deferred — destructive operation, only on explicit
  user request). Rewriting committed history breaks downstream forks
  and signature chains; we do not perform it without an explicit ask.
  New commits should prefer a project-anonymous email.

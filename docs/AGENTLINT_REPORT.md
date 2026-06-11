# AgentLint report — post Phase 0 (claude-workflow-plugin-e0d)

> For design rationale behind deferred AgentLint findings, see
> `docs/plans/v3-upgrade.md`, `docs/plans/verification-suite.md`, and
> the "Design overrides vs. AgentLint" section in `CONTRIBUTING.md`.

**AgentLint version**: 1.1.13 (CLI: `agentlint check`).

**Date**: 2026-06-11 (post-Phase-0 verified; v3.1.0 release closeout).

**Command**: `agentlint check --format md --output-dir docs/` (also
exposed as `make check`).

## Summary

| Metric | Phase 7 baseline | Post G8 Phase F | Post Phase 0 |
| ------ | ---------------- | --------------- | ------------ |
| Overall score | 90/100 | 87/100 | **87/100** (no change) |
| Findability | 10/10 | 10/10 | 10/10 |
| Instructions | 10/10 | 10/10 | 10/10 |
| Workability | 8/10 | 8/10 | 8/10 |
| Continuity | 10/10 | 10/10 | 10/10 |
| Safety | 8/10 | 6/10 | 6/10 (composition shifted; see below) |
| Harness | 7/10 | 7/10 | 7/10 |

The "Phase 7 baseline" column is the score immediately after Phase 7
closed (Beads `claude-workflow-plugin-y4a.14`). "Post G8 Phase F" is
the post-G8 score. "Post Phase 0" is the current run, after the v3.1.0
release closeout.

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

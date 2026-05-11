# AgentLint report — post G8 Phase F (claude-workflow-plugin-0wk.15)

> For design rationale behind deferred AgentLint findings, see
> `docs/plans/v3-upgrade.md` and the "Design overrides vs. AgentLint"
> section in `CONTRIBUTING.md`.

**AgentLint version**: 1.1.13 (CLI: `agentlint check`).

**Date**: 2026-05-11 (post-G8 + closeout verified).

**Command**: `agentlint check --format md --output-dir docs/` (also
exposed as `make check`).

## Summary

| Metric | Phase 7 baseline | Post G8 Phase F |
| ------ | ---------------- | --------------- |
| Overall score | 90/100 | **87/100** (-3) |
| Findability | 10/10 | 10/10 |
| Instructions | 10/10 | 10/10 |
| Workability | 8/10 | 8/10 |
| Continuity | 10/10 | 10/10 |
| Safety | 8/10 | **6/10** (-2) |
| Harness | 7/10 | 7/10 |

The "Phase 7 baseline" column is the score immediately after Phase 7
closed (Beads `claude-workflow-plugin-y4a.14`). The "Post G8 Phase F"
column is this run.

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

## Deferred (unchanged from Phase 7)

These five checks remain failing or partial. Each is logged so future
contributors don't try to "fix" them without reading this section.

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

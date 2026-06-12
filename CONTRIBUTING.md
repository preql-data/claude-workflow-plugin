# Contributing

The fastest way to customize the plugin: clone this repo, open it in Claude
Code, and describe your change in plain English. The plugin runs on this
repo itself — the orchestrator will create a Beads epic, route the work to
the right specialist, and gate it through QA before anything ships. See
the **Customize / contribute** section of [`README.md`](README.md) for the
3-step walkthrough. This file covers the deeper extension points (a new
specialist agent, a new hook, the test pyramid, AgentLint reconciliation).

Thanks for considering a contribution. This file is intentionally short --
it covers the two extension points that come up most often (a new specialist
agent, a new hook), and points at the deferred testing strategy for anything
deeper.

The plugin lives in `.claude/` (agents, scripts, hooks, skills, settings) and
`.claude-plugin/plugin.json` (the manifest). The two installers
(`install.sh`, `install.ps1`) and the uninstallers (`uninstall.sh`,
`uninstall.ps1`) are at the repo root. After v3.0.0 the installers are
single-source-of-truth: they copy from the canonical repo files rather than
embedding agent prompts as heredocs, so you only edit the file in `.claude/`
and the installer picks it up automatically.

## Adding a new specialist agent

Drop a new file under `.claude/agents/<name>.md` with this frontmatter:

```markdown
---
name: <name>
description: <one-sentence description used by intent-based routing>
tools: Read, Glob, Grep, LS, Bash, Write, Edit
# model: pinned to a static identifier. SessionStart resolves the best
# available model and rewrites these pins via model-select.sh; the
# /workflow-model slash command is the manual override path.
model: claude-fable-5
---

You are a **<Domain> Engineering Specialist** using Beads for tracking.

Use extended thinking for all non-trivial work.

## When Starting Work
...

## Self-Check Questions
...

## When Completing Work
...
```

Conventions to keep:

1. **Tools list is broad.** v3 keeps the full tool set on every specialist
   (`Read, Glob, Grep, LS, Bash, Write, Edit`). The orchestrator is the only
   one with a narrowed list, and even that one is broad. Don't add scope
   restrictions per agent -- they break Phase 4's intent-based routing.
2. **Always include the extended-thinking line** near the role intro
   ("Use extended thinking for all non-trivial work."). Phase 0 added this
   to all five existing agents.
3. **Always include the `model:` field** in frontmatter. SessionStart's
   `model-select.sh` resolver rewrites every agent's `model:` line in
   lockstep (see `workflow-model-apply.sh`'s `AGENTS` array — add the
   new agent there too). The `/workflow-model` slash command and `make
   workflow-model` provide the manual override. Use whatever value the
   other agents currently carry — the resolver will normalise it on the
   next session start.
4. **Beads lifecycle.** Every specialist starts with
   `bd update $TASK_ID --status in_progress` and ends with
   `bd label add $TASK_ID qa-pending` (so the QA agent sees it). The QA
   agent is the only one that flips `qa-pending` -> `qa-approved`.
5. **Tone.** Plain prose. Emoji only at H1/H2 markers. No ALL CAPS WALLS OF
   TEXT. Phase 2 (C6) will tighten the existing prompts further.
6. **Effort level.** Set `effort: max` in frontmatter. `max` is the highest
   level subagent frontmatter accepts (per
   [docs/en/sub-agents](https://code.claude.com/docs/en/sub-agents)); the
   session-wide knobs go above it but can't be persisted in frontmatter.

### Why ultracode cannot be the durable default

Hotfix vlp.2 documents this so future contributors don't waste a cycle
trying to write it. From `code.claude.com/docs/en/model-config` (Adjust
effort level):

> Ultracode is a Claude Code setting rather than a model effort level: it
> sends `xhigh` to the model and additionally has Claude orchestrate
> dynamic workflows for substantive tasks. It applies to the current
> session only. Set it through `/effort`, or pass `"ultracode": true`
> via `--settings` or an Agent SDK control request. **It is not part of
> the `effortLevel` setting, the `--effort` flag, or
> `CLAUDE_CODE_EFFORT_LEVEL`.**

So the highest persistable configuration is what the plugin ships:

- `.claude/settings.json` `effortLevel`: `"xhigh"` (the cap that
  `effortLevel` accepts; `max` is invalid in this field and is silently
  ignored by some runtimes).
- `.claude/settings.json` `env.CLAUDE_CODE_EFFORT_LEVEL`: `"max"` (the
  env var accepts `max` and persists across sessions, unlike the
  `--effort` flag).
- `.claude/agents/*.md` frontmatter `effort`: `max` (subagent
  frontmatter caps at `max`).

To opt into ultracode for a session, the operator runs `/effort
ultracode` interactively, or passes `--settings '{"ultracode":true}'`
to a one-shot run, or adds `ultracode: true` to a control request when
embedding via the Agent SDK. The SessionStart hook surfaces a one-liner
naming what was applied so the operator sees the active level on every
load.

Then register the agent in `.claude-plugin/plugin.json`:

```json
"agents": [
  ".claude/agents/orchestrator.md",
  ".claude/agents/qa.md",
  ".claude/agents/backend.md",
  ".claude/agents/frontend.md",
  ".claude/agents/devops.md",
  ".claude/agents/<name>.md"
]
```

The orchestrator's prompt has a Domain -> Delegate-To table; if your new
specialist owns a clear domain, add a row to that table so the orchestrator
knows when to spawn it.

## Extending hooks

Five hook events are wired today: `SessionStart`, `UserPromptSubmit`,
`PostToolUse`, `Stop`, `SessionEnd`. Each has a script in
`.claude/scripts/` and a registration in `.claude/hooks/hooks.json`.

### Hook input/output contract

**Input** comes on stdin as a JSON object. Useful keys:

| Hook | Notable input keys |
|------|--------------------|
| `SessionStart` | (no payload of interest) |
| `UserPromptSubmit` | `prompt` (the user's message) |
| `PostToolUse` | `tool_input.file_path` (or `path`), `tool_name` |
| `Stop` | `stop_reason` (`end_turn`, `user_interrupt`, `max_turns`) |
| `SessionEnd` | (no payload of interest) |

**Output** is a JSON object on stdout. The two patterns we use:

```jsonc
// Inject context (any hook except Stop can do this)
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<arbitrary text injected into Claude's context>"
  }
}

// Block the operation (Stop hook only -- this is what enforces the QA gate)
{
  "decision": "block",
  "reason": "<message Claude shows the operator>"
}
```

For everything else, return `{}`.

### Adding a new hook

1. Drop your script in `.claude/scripts/<name>.sh`. Start with:

   ```bash
   #!/bin/bash
   set -e
   PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
   INPUT=$(cat)
   # ... your logic ...
   echo "{}"
   ```

2. Register it in `.claude/hooks/hooks.json` under the right event:

   ```json
   "PostToolUse": [
     {
       "matcher": "Write|Edit|MultiEdit",
       "hooks": [
         {
           "type": "command",
           "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/<name>.sh\""
         }
       ]
     }
   ]
   ```

   Anchor the matcher (`^(Write|Edit|MultiEdit)$`) if you want it to be
   strict. Phase 1 (B17) plans to anchor the existing matcher.

3. `chmod +x` the script. The installer does this automatically on copy,
   but local development needs it before you commit.

4. Test with a synthetic stdin payload:

   ```bash
   echo '{"stop_reason":"end_turn"}' | bash .claude/scripts/verify-before-stop.sh
   ```

### Things to avoid

- **No user prompts in hooks.** Hooks must run unattended. If you need to
  ask the user something, surface it as `additionalContext` and let Claude
  ask via `AskUserQuestionTool` instead.
- **Don't `set -e` and then forget the `|| true`.** A failing `bd` command
  must not break the hook -- that brings down the whole session.
- **Don't redirect stderr to /dev/null on test/lint commands.** Phase 4
  (B3) explicitly captures stderr+stdout to a tempfile and surfaces a tail
  on failure. Match that pattern when you add a new check.
- **Don't poll bd for the active task across multiple files.** Phase 4
  (F3) introduces `.claude/.qa-tracking/current-task` as the single source
  of truth. Read from there, not via repeated `bd list --status in_progress`.

## Versioning and the changelog

The plugin follows semantic versioning. See `CHANGELOG.md` for the full
policy and the version history. When you land a non-trivial change, add an
entry under the `[Unreleased]` section (or the current in-progress version)
in the appropriate category (`Added`, `Changed`, `Fixed`, `Removed`).

## Testing changes

The plugin ships with a five-tier test pyramid (G8). The full reference
is in **[`.claude/tests/README.md`](.claude/tests/README.md)** — when in
doubt, read that. The short version follows.

### Which tier does my new test go in?

Use the first row that matches:

| You changed... | Add the test at... |
| -------------- | ------------------ |
| Logic inside one hook script | **L1 bash unit** — `.claude/scripts/tests/<name>.sh` |
| How multiple hooks chain together | **L2 component** — `.claude/tests/component/specs/<name>.sh` |
| Harness internals (`runFixture`, `trace`, `goldenCompare`, matchers) | **L3 vitest unit** — `.claude/tests/e2e/specs/<name>.unit.spec.ts` |
| Plugin behaviour end-to-end (orchestrator → specialists → QA) | **L3 live** — `.claude/tests/e2e/specs/<name>.spec.ts` plus a fixture under `fixtures/<name>/` |
| Long-running drift detection on `main` | **L4** — re-uses the L3-live specs; no new code needed |

Prefer the lower (cheaper, more deterministic) tier when a test could
plausibly live at two. L3-live costs roughly **$5–10 per fixture per
recording session** against the SessionStart-resolved model with
`maxTurns=30`; if a synthetic Trace mutation at L3-unit can prove the
same contract, take
that path.

### Local commands

```bash
make test          # L1 — fast (~2s)
make test-all      # L1 + L2 (the offline gate; what you run before pushing)
make test-ci       # L1 + L2 + L3-unit + manifest (what CI runs without API key)
make test-e2e      # L3 live; requires ANTHROPIC_API_KEY
make cassette-diff # diff the most recent replay vs its committed golden
```

### Failure-injection convention (META-TESTs)

Every protection should ship with a corresponding **META-TEST** —
an assertion that proves the test is sensitive to the failure it claims
to catch. A passing test is consistent with two states ("SUT is correct"
and "test is too weak"); META-TESTs disambiguate by mutating the trace
in a way that should trip the assertion, and checking that it does.

See `.claude/tests/README.md` § "The META-TEST convention" for placement
and naming conventions. The CI summary surfaces META-TEST pass/fail
counts as a distinct line so regression-injection sensitivity stays
visible.

### Smoke tests (still manual)

1. Run `bash install.sh /tmp/test-project-$(date +%s)` against a fresh
   directory and confirm the install completes without errors.
2. Open Claude Code in the test project, ask for a small feature, and
   verify the orchestrator delegates rather than implementing directly.
3. Confirm the Stop hook blocks until you delegate to `@qa` and the
   agent sets `qa-approved`.
4. Run `bash uninstall.sh` and confirm the trash directory contains
   `.claude/`, `.claude-plugin/`, and `.beads/`.

## Design overrides vs. AgentLint

`agentlint check` (https://github.com/0xmariowu/AgentLint) runs 51
deterministic harness checks. Phase 7 of the v3 plan ran it against this
plugin and reconciled the findings against the cross-cutting principles.
A few AgentLint checks are intentionally not satisfied — the rationale
lives here so future contributors don't try to "fix" them.

- **H4 (no dangerous Bash auto-approve).** `Bash` is in
  `permissions.allow` in `.claude/settings.json` by design. Principle 3
  of the v3 plan is "full autonomy, no permission prompts". Scoping Bash
  to a per-command allowlist would re-introduce user-facing approval
  prompts and break unattended specialist runs. We accept the tradeoff;
  the structural compensating controls are
  `prevent-orchestrator-edits.sh` (orchestrator can't write code) and
  the QA gate (no Stop without `qa-approved`).
- **W2 — CI workflow exists.** Passes as of G8 Phase E.
  `.github/workflows/test.yml` runs the L1 + L2 + L3-unit + manifest
  tiers on every PR and the L3-live + L4-drift tiers on the schedule
  documented in `.claude/tests/README.md`.
- **W4 (linter configured).** Remains 0. AgentLint's W4 detector is
  JS/Python/Ruby/Go-centric and doesn't recognise shellcheck-only setups.
  `make lint` runs shellcheck across every hook script and installer; the
  CI workflow's `lint` job runs the same thing. We don't try to bend the
  AgentLint detector — the substantive coverage is in place.
- **W11 (test-required gate).** Remains 0. AgentLint looks for a
  `test-required.yml` workflow that gates feat/fix commits on paired test
  commits. We enforce the same contract via `verify-before-stop.sh` (the
  QA gate refuses Stop without `qa-approved`, and a `qa-approved` flip
  requires the gate to see passing tests). That's a runtime gate rather
  than a CI workflow, so the detector can't see it.
- **S2 (Actions SHA pinned).** Regressed to 0 with Phase E. The new
  `.github/workflows/test.yml` uses tag-pinned actions (`actions/checkout@v4`,
  `actions/setup-node@v4`, `actions/upload-artifact@v4`, etc.) for
  readability. SHA-pinning is a reasonable hardening to land in a follow-up
  but we don't pretend to have done it now.
- **S9 (no personal email in git history).** AgentLint flags committer
  emails as PII. Rewriting committed history is destructive and can
  break downstream forks; we don't perform it without an explicit user
  request. New commits should use a project-anonymous email when
  feasible (e.g., `noreply@github.com` or a role address).
- **S7 (no personal paths in source).** AgentLint flags seven files
  containing `/Users/` or `/home/` patterns; all are pre-existing and
  intentional. (1) The `_legacy_project_slug` comment in
  `.claude/scripts/qa-gate.sh:450` documents the slug transform via a
  fictitious `/Users/foo/Desktop/projects/bar` example — it is
  documentation, not a personal path, and the same comment is mirrored
  into the six G8 fixture copies of qa-gate.sh. (2) The
  `.claude/tests/e2e/fixtures/<name>/.claude/bin/bd` shim files
  hardcode `/Users/edk0/.local/bin/bd` as part of the G8 e2e
  infrastructure that records cassettes from this developer machine;
  fixtures are test infrastructure, not shipped plugin code. Both are
  contained inside `.claude/tests/` and never reach an installed
  target. Rewriting them is out of scope for Phase 0 (verification-
  suite spec 0.8 retires golden-equality entirely; the fixtures stay
  as a seed corpus for the invariant engine self-tests).

Re-run AgentLint after non-trivial changes:

```bash
agentlint check --format md --output-dir docs/
```

The latest report is at `docs/AGENTLINT_REPORT.md`.

## Beads conventions

This plugin dogfoods Beads for its own development. If you're tracking your
contribution, follow the labels convention from `CLAUDE.md`:

- `backend`, `frontend`, `devops` for the work domain.
- `qa-pending` while implementation is in flight.
- `qa-approved` once the QA agent has signed off.
- `bug`, `improvement` for the work type.

Use `bd ready` to see what's available, `bd blocked` to see what's stuck,
and the structured-notes format (`COMPLETED: ... | IN PROGRESS: ... |
KEY DECISIONS: ...`) for everything you write to a task.

## Multi-repo workflows (I8)

The QA gate is repo-aware. If you work across multiple repos -- e.g., a
service repo and a shared-library repo, or a monorepo plus a separate
infra repo -- the active task's repo is recorded alongside the task id
when you enter the gate. The Stop hook compares it to the cwd's repo and
refuses to auto-mark a task complete when those don't match.

### What gets recorded, where

Two files under `.claude/.qa-tracking/`:

| File | Contents | Written by |
|------|----------|------------|
| `current-task` | the active Beads task id (e.g. `acme-y4a.13`) | `current-task.sh set <id>` (called by `qa-gate.sh enter`) |
| `current-task.repo` | absolute path of `git rev-parse --show-toplevel` at `set` time | same call |

Read them via `current-task.sh`:

```bash
bash .claude/scripts/current-task.sh get          # task id
bash .claude/scripts/current-task.sh get-repo     # repo fingerprint
bash .claude/scripts/current-task.sh get-json     # {"task":"...","repo":"..."}
```

The single-repo case is unchanged: if `current-task.repo` is missing
(pre-I8 install) or if the cwd is not a git repo, the gate degrades to
the legacy single-repo behaviour and never raises a cross-repo block.

### Cross-repo Stop behaviour

When the recorded repo differs from the cwd's repo, the Stop hook emits a
`decision: "block"` with three options surfaced to the operator:

1. `cd` into the recorded repo and re-run the Stop flow there.
2. Treat each repo's gate independently -- claim a separate sibling task
   in the cwd's repo, finish its review, then return.
3. Reset the recording (rare) via `current-task.sh clear` followed by
   `qa-gate.sh enter <id>` -- only if the task genuinely lives in the
   cwd's repo and the recording is wrong.

The gate **does not** touch labels or status during the cross-repo block.
The intent is: cross-repo cases are explicit, never silent.

### Single Beads vs federated

You have two layouts to choose from when running multiple repos:

**Single Beads, multiple repos.** One `.beads/` lives in a "planning" repo
(or in your home directory) and tracks tasks across every code repo you
own. Beads's experimental `repos:` config (see comments in
`.beads/config.yaml`) supports hydrating from multiple repo paths. The
gate's I8 check still applies: even with one tracker, a Stop fired in the
"wrong" code repo won't auto-mark a task complete.

When to use: you have tight coupling across repos (e.g., one team owns
all of them and tasks frequently span boundaries). Easier to query and
report on.

**Federated -- one Beads per repo.** Each code repo has its own `.beads/`
and its own task ids (different prefixes per repo). Cross-repo work is
explicit: open an issue in repo A, link it from a parent task in repo B
via `bd_add_dep` or a `gh-link:` line. The QA gate never sees a stale
cross-repo recording because each repo's Beads is fully scoped.

When to use: independent teams, looser coupling, repos with very
different release cadences.

### Linking GitHub issues / PRs across repos

The plugin's I3 hook (`bd-github-link.sh`) follows the recorded mapping:

- A `gh-link:` line in a task's notes -- e.g., `gh-link: org/repo#42` --
  is the explicit cross-repo binding.
- When a task closes, the hook reads `gh-link:` and posts a back-link
  comment on the GitHub issue or PR via `gh`.
- When `gh pr create --body "Closes #42"` runs in the active session,
  the hook appends a `gh-link:` line to the active task's notes so the
  inverse direction is recorded too.

The hook short-circuits silently if `gh` is missing or if the GitHub
remote isn't on `github.com` (GitHub Enterprise hosts skip the comment
path; the inverse Beads-notes write still happens).

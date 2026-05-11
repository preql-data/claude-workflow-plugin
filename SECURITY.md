# Security policy

## Reporting a vulnerability

If you discover a security issue in this plugin — in the orchestrator, hook
scripts, the QA gate, the bd-mcp / code-context-mcp servers, or the install
scripts — please do **not** open a public GitHub issue.

Instead, email the maintainer at the address listed on the GitHub repository
profile. Include:

- A description of the issue and its impact.
- A reproduction (commands, file paths, hook payload if applicable).
- Your suggested severity (critical / high / medium / low) and reasoning.
- Whether you intend to disclose publicly, and on what timeline.

We aim to acknowledge reports within 5 business days and to issue a fix or
mitigation within 30 days for critical and high-severity findings. Lower
severities track with the next minor release.

## Scope

In scope for this policy:

- The plugin's hook scripts under `.claude/scripts/` (verify-before-stop,
  intent-router, post-edit, bd-github-link, qa-gate, epic-gate, etc.).
- The MCP servers under `.claude/mcp/` (bd-mcp, code-context-mcp).
- The install / uninstall scripts (`install.sh`, `install.ps1`,
  `uninstall.sh`, `uninstall.ps1`).
- The agent prompts in `.claude/agents/*.md` insofar as they contain
  instructions that could lead to dangerous tool invocations.

Out of scope:

- Vulnerabilities in upstream dependencies (Claude Code itself, Beads, jq,
  Node, gh) — please report those to the upstream maintainers.
- Issues that require already-compromised user credentials or a hostile
  package-manager registry.
- Findings that depend on the user explicitly disabling Phase 1's gate or
  removing `prevent-orchestrator-edits.sh`.

## Threat model

The plugin runs with full filesystem and Bash access by design (see Phase 1
principle 3: full autonomy, no permission prompts). The threat model assumes:

- The user trusts Claude Code and the model running in it.
- The user trusts the contents of `.claude/agents/*.md` after install.
- The user audits hook-script changes via `git diff` like any other code.

Findings that turn an *un*trusted input (e.g., a model-generated tool call,
a hostile MCP server response, a Beads sync from an untrusted repository,
or arbitrary file contents pulled in by `code-context-mcp`) into shell
execution outside the QA gate ARE in scope and treated as high severity.

## Handling AI-specific security issues

The QA agent's security pass already runs an 8-module sweep: SECRETS,
INJECTION, AUTH, CONFIG, DEPS, AI (LLM Top-10), MOBILE, DATA. If you find
a class of issue not covered there — for example a new prompt-injection
vector against the orchestrator or specialists — file it under this policy
and we will fold the new module into `qa.md`.

## Recognition

We credit reporters in `CHANGELOG.md` under each release notes section unless
you ask to remain anonymous.

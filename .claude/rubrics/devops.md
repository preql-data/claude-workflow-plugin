---
version: 1
name: devops
extends: default
---

# DevOps rubric (v1)

Applied additionally when the task carries the `devops` label. Default criteria still apply; these add domain-specific checks pulled from `.claude/agents/devops.md`. The leverage is default + bugfix — these are the few devops-specific failure modes that recur.

## Criteria

### D1. Scripts are idempotent and re-runnable.

Install, uninstall, hook, and CI scripts in the diff produce the same end state when run twice in a row. A second run of `install.sh` does not double-write hooks, clobber prior settings, or fail because a directory already exists. A migration script that exits non-zero on its second run fails this criterion.

Evidence that satisfies it: every new script uses `mkdir -p`, conditional inserts, and idempotent label operations (`bd label add` returns success if already present); the `decisions` array documents any deliberately non-idempotent step (e.g. a one-shot data migration) and pairs it with a guard (lock file, completion sentinel) so a re-run is detected.

### D2. Graceful degradation on missing optional tools.

When the diff depends on an optional tool (gitleaks, shellcheck, a particular bd version, a specific CI runner image), the missing-tool path is handled: log a structured warning, fall back to a safe default, exit zero where the workflow allows. A hook that exits non-zero because `gitleaks` is not installed fails this criterion — that is not a developer-machine-portable failure mode.

Evidence that satisfies it: every new tool dependency is probed (`command -v tool >/dev/null`); the fallback path is documented in the script comments and tested at L1; the `decisions` array names the dependency and its installation hint.

### D3. No new permission prompts; autonomy preserved.

The diff does not add `permissions.deny` rules to `settings.json`, narrow specialist tool lists below the broad allow set, or introduce any user-facing approval step the plugin previously ran without. Principle 3 of the v3 plan is "full autonomy, no permission prompts" — every deny rule becomes a future approval prompt and breaks the workflow.

Evidence that satisfies it: a diff of `.claude/settings.json` shows only `permissions.allow` expansions, never `deny`; specialist tool frontmatter is unchanged or expanded; the `decisions` array calls out any new tool the broadened allow set covers.

### D4. Secrets and PII stay out of source, logs, and history.

Hardcoded API keys, tokens, passwords, private keys, committer emails, and PII are absent from the diff. Logs that the diff adds redact sensitive fields before writing. A commit that introduces an `.env` file with values, a personal email address in a script header, or unredacted PII in a log line fails this criterion (extends C5 / SECRETS + DATA).

Evidence that satisfies it: secrets read from a secret manager or environment variable at runtime; PII fields in new log lines are redacted (`***@`, `user_id=***`); a `gitleaks`-equivalent pass on the diff is clean, and the `decisions` array names the secrets the diff touches.

# Technical debt

Deferred findings from QA gate runs. Each row was logged via
`.claude/scripts/tech-debt.sh add` (see plugin docs for J22 / Phase 4).

| severity | file:line | effort | description | added | resolved |
| -------- | --------- | ------ | ----------- | ----- | -------- |
| medium | .claude/scripts/verify-before-stop.sh:multiple | 2d | Mutation survivors (themes A-E, ids 1,2,3,6,8,9,11,13-24): block-reason wording, escalation boundaries, F1 doc-only fast path, git-status fallback, cross-repo detection. Backlog task claude-workflow-plugin-6ix. Verdict .claude/.mutation-runs/20260612T063107Z/verdict.json. Discovered-from claude-workflow-plugin-n45.3. | 2026-06-12 |  |
| medium | .claude/scripts/post-edit.sh:multiple | 1d | Mutation survivors (theme F, ids 25,26,28,29,30,31,32): tracking-file trim threshold, every-10th edit cadence, CLAUDE_PROJECT_DIR default, sort/wc pipeline, EDIT_COUNT increment. Backlog task claude-workflow-plugin-6ix. Verdict .claude/.mutation-runs/20260612T063107Z/verdict.json. Discovered-from claude-workflow-plugin-n45.3. | 2026-06-12 |  |

# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bash .claude/scripts/beads-ledger.sh reconcile --apply   # Sync database <-> ledger, both ways
                                                        # (dry-run without --apply)
bd export -o .beads/issues.jsonl                # One-way: database -> ledger. Overwrites the
                                                # ledger, so it DISCARDS anything only the
                                                # ledger has (e.g. just-pulled issues).
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up.
   A finding about work that is ALREADY CLOSED opens a **new** task — never a
   comment on the closed one, which no ready-work query will ever return. See
   CONTRIBUTING.md § "A finding discovered after a task closes opens a NEW task".
2. **Run quality gates** (if code changed) - Tests, linters, builds.
   Every number you then report carries the command that produced it and the
   commit it was measured at — CONTRIBUTING.md § "Every number carries the
   command that produced it and the commit it was measured at".
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   # 1. Fold local database work into the ledger BEFORE pulling. --apply is
   #    required: reconcile is dry-run by default.
   bash .claude/scripts/beads-ledger.sh reconcile --apply
   git pull --rebase
   # 2. Fold in whatever the pull brought. This step is why `export` is NOT
   #    used here: the pull may have added issues that exist ONLY in the
   #    ledger, and a plain export would overwrite them from the local
   #    database and then push the deletion. `reconcile` imports first, so
   #    the database ends up holding the union and nothing is discarded.
   bash .claude/scripts/beads-ledger.sh reconcile --apply
   git add .beads/issues.jsonl                   # the ledger is the portable ground truth
   git push
   git status  # MUST show "up to date with origin"
   ```

   > `bd sync` used to sit between the pull and the push. It was REMOVED in bd
   > 1.1.2, and it was BIDIRECTIONAL — replacing it with a one-way export is
   > what makes the ordering above load-bearing rather than cosmetic.
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds


#!/bin/bash
# workflow-denylist.sh — THE definition of "paths the workflow never treats
# as reviewable work" (claude-workflow-plugin-3mg.1, v4 Phase V4).
#
# WHY THIS FILE EXISTS
# --------------------
# Three scripts each need the same answer to "is this path reviewable?":
#
#   post-edit.sh           what gets TRACKED into changed-files.txt
#   impact-report.sh       what enters the canonical change set + its HASH
#   verify-before-stop.sh  what the Stop gate treats as needing REVIEW
#
# They each carried their own copy of the regex and the copies DRIFTED:
# only verify-before-stop's knew about `.claude/worktrees/` and the e2e
# fixture-churn alternation. The consequence was not cosmetic — post-edit
# tracked harness-worktree paths that the Stop gate could not see, so those
# paths entered the change-set hash while being invisible to the gate's own
# view of the change set. The hash and the gate disagreed about what "the
# changes" even were.
#
# One definition, three consumers. A change here changes all three at once,
# which is the point — see the HASH MIGRATION note below for the cost.
#
# CONTRACT
# --------
#   WORKFLOW_DENYLIST_REGEX   ERE, for `[[ "$p" =~ $WORKFLOW_DENYLIST_REGEX ]]`
#   workflow_denylisted <path>
#       exit 0  -> DROP the path (build artifact / workflow-internal churn)
#       exit 1  -> KEEP the path (reviewable work)
#
# Sourcing convention (all three consumers): resolve this file relative to
# ${BASH_SOURCE[0]} of the CONSUMER, never relative to $CLAUDE_PROJECT_DIR.
# A hook script may legitimately run with CLAUDE_PROJECT_DIR pointing at a
# DIFFERENT checkout than the one the script itself lives in (the primary's
# gate evaluating a worktree); the lib must always be the sibling of the
# script that sources it.
#
# No side effects: this file defines one variable and one function and does
# nothing else. bash 3.2 compatible (no associative arrays, no ${x^^}).
#
# WHAT IS DELIBERATELY *NOT* DENYLISTED
# -------------------------------------
#   CLAUDE.md   behaviour-bearing (session-start injects it) — reviewable.
#   LESSONS.md  audit deliverable — reviewable.
#   HANDOFF.md  audit deliverable — reviewable.
#   .beads/*.jsonl, .claude/.qa-tracking/*
#               NOT denylisted: they stay in the change set / audit trail.
#               verify-before-stop.sh classifies them separately via
#               is_beads_or_gate_path (a change set consisting solely of
#               them is fast-path eligible). Denylisting them would erase
#               them from the hash too, which is not the intent.
# The *.md doc-only fast path (F1) already handles the three .md files above
# when they change alone.
#
# HASH MIGRATION (fail-closed, one landing = one migration)
# ---------------------------------------------------------
# change_set_hash is a sha256 over the DENYLIST-FILTERED changed-files list.
# Editing this regex therefore changes the recomputed hash for any change set
# containing a newly-(un)matched path. An approval recorded before the edit no
# longer matches the hash the Stop hook recomputes after it, so the gate emits
# LABEL_WITHOUT_RECORD and re-blocks until a fresh `qa-gate.sh enter` +
# re-approve. That is the correct fail-closed direction (a stale approval must
# not release), but it is USER-VISIBLE friction: ship denylist additions in ONE
# landing so in-flight cycles pay the migration exactly once. See CHANGELOG
# and docs/HOOKS.md ("Denylist changes are a hash migration").

# Consolidated regex. Alternation order is cosmetic (ERE alternation is
# unordered for a boolean match); grouped by intent for readability.
#
#   1. build / dependency output directories
#   2. .claude/worktrees/       parallel-agent scratch checkouts. Never a
#                               deliverable; the worktree's own gate reviews
#                               its work in situ.
#   3. e2e fixture churn        .claude/tests/e2e/fixtures/<f>/.claude/{scripts,beads}
#                               and <f>/.beads — rewritten mechanically by the
#                               harness's run-start sync and by the live run's
#                               own bd writes. ANTI-OVERREACH: scoped to those
#                               subtrees only, so a real edit to a fixture's
#                               fixture.yaml / src/ is still reviewable.
#   4. memory files             MEMORY.md (the auto-memory index) and
#                               .claude/memory/. Agent-written recall state,
#                               not deliverables; they must leave the
#                               reviewable set BEFORE F1 doc-only
#                               classification so a memory-only change set is
#                               `empty` (nothing to review) rather than
#                               `doc-only` (auto-approved WITH a gate record).
#   5. lock / map / minified / compiled artifacts
WORKFLOW_DENYLIST_REGEX='(^|/)(node_modules|dist|build|coverage|\.git|\.next|\.nuxt|target|__pycache__)/|(^|/)\.claude/worktrees/|(^|/)\.claude/tests/e2e/fixtures/[^/]+/(\.claude/(scripts|beads)|\.beads)/|(^|/)MEMORY\.md$|(^|/)\.claude/memory/|\.(lock|lockb|map|pyc)$|\.min\.(js|css)$|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb|Cargo\.lock|poetry\.lock|go\.sum)$'

# workflow_denylisted <path> — 0 = drop it, 1 = keep it.
workflow_denylisted() {
    [ -n "${1:-}" ] || return 1
    [[ "$1" =~ $WORKFLOW_DENYLIST_REGEX ]]
}

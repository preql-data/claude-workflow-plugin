#!/bin/bash
# workflow-denylist.sh — THE definition of "paths the workflow never treats
# as reviewable work" (claude-workflow-plugin-3mg.1, v4 Phase V4).
#
# WHY THIS FILE EXISTS
# --------------------
# Four scripts each need the same answer to "is this path reviewable?":
#
#   post-edit.sh           what gets TRACKED into changed-files.txt
#   qa-gate.sh             what reconcile_tracker APPENDS to changed-files.txt
#                          (94d — the second writer of that file; it must apply
#                          the same filter as the first, or the two writers
#                          disagree about what belongs in the file they share)
#   impact-report.sh       what enters the canonical change set + its HASH
#   verify-before-stop.sh  what the Stop gate treats as needing REVIEW
#
# The first three carried their own copy of the regex and the copies DRIFTED:
# only verify-before-stop's knew about `.claude/worktrees/` and the e2e
# fixture-churn alternation. The consequence was not cosmetic — post-edit
# tracked harness-worktree paths that the Stop gate could not see, so those
# paths entered the change-set hash while being invisible to the gate's own
# view of the change set. The hash and the gate disagreed about what "the
# changes" even were.
#
# One definition, four consumers. A change here changes all four at once,
# which is the point — see the HASH MIGRATION note below for the cost.
#
# CONTRACT
# --------
#   WORKFLOW_DENYLIST_REGEX   ERE, for `[[ "$p" =~ $WORKFLOW_DENYLIST_REGEX ]]`
#   workflow_denylisted <path>
#       exit 0  -> DROP the path (build artifact / workflow-internal churn)
#       exit 1  -> KEEP the path (reviewable work)
#
# Sourcing convention (all four consumers): resolve this file relative to
# ${BASH_SOURCE[0]} of the CONSUMER, never relative to $CLAUDE_PROJECT_DIR.
# A hook script may legitimately run with CLAUDE_PROJECT_DIR pointing at a
# DIFFERENT checkout than the one the script itself lives in (the primary's
# gate evaluating a worktree); the lib must always be the sibling of the
# script that sources it.
#
# No side effects: this file defines TWO variables and TWO functions (rule 1
# below, then the SELF-WRITTEN rule at the bottom) and does nothing else.
# bash 3.2 compatible (no associative arrays, no ${x^^}).
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
#               READ THIS WITH THE SELF-WRITTEN RULE BELOW, or it misleads:
#               "not denylisted" is not "reaches the change set". Two of
#               these paths — .claude/.qa-tracking/** and
#               .beads/interactions.jsonl — are kept out by the SEPARATE
#               workflow_self_written rule, which the tracker's two writers
#               apply. .beads/issues.jsonl really does reach the change set,
#               and that one-file boundary is the whole point of keeping the
#               two rules apart.
#   /tmp/... and /var/folders/... AS A CLASS
#               NOT denylisted, and the reason is mechanical rather than
#               taste. Two component specs seed changed-files.txt with
#               ABSOLUTE paths rooted at `mktemp -d`'s parent:
#               specs/impact-report-paths.sh (the project / sibling-worktree
#               / foreign-repo / non-git-scratch mix that exists to prove
#               path relativisation) and specs/worktree-approval-resolution.sh
#               (the worktree-absolute spellings that exist to prove the
#               cross-worktree approval bridge). That parent is /tmp on a
#               Linux CI job and /var/folders/... on a macOS dev box, so
#               EITHER pattern would silently empty both change sets — the
#               two specs would keep passing while proving nothing. The
#               narrow `/tmp/claude-<session>/` form in group 7 below is safe
#               precisely because those fixtures are created as
#               `mktemp -d -t component-fixture.XXXXXX`, which never yields a
#               `claude-` prefix.
#               AGENT-CHOSEN SCRATCH OUTSIDE THAT PREFIX (/tmp/qa-p5n-probe/,
#               a bare /tmp/enc-diff.sh) IS NOT THIS RULE'S PROBLEM AND IS NO
#               LONGER UNSOLVED. Since claude-workflow-plugin-fkm.1.15 it is
#               dropped at RECORD TIME by post-edit.sh's containment check
#               (its `CONTAINMENT-FILTER` region), which compares the path
#               against $CLAUDE_PROJECT_DIR instead of matching a pattern —
#               so it drops those two probes while KEEPING the two specs'
#               fixture paths, because those sit INSIDE the `mktemp -d` root
#               their own fixture points CLAUDE_PROJECT_DIR at. That is the
#               distinction: a regex here cannot tell the two apart, and a
#               root comparison can. Prompt guidance (qa.md and the three
#               specialist prompts send throwaway probes to the session
#               scratchpad or .claude/.qa-tracking/) remains as the belt to
#               that braces. Widening THIS regex is still refused.
#               (claude-workflow-plugin-wg6 / prm; six recorded instances.
#               Pinned from both sides by specs/denylist-shared.sh D4 — rule 1
#               keeps them, the hook drops them — and by specs/post-edit.sh
#               section 13.)
# The *.md doc-only fast path (F1) already handles the three .md files above
# when they change alone.
#
# HASH MIGRATION (fail-closed, one landing = one migration)
# ---------------------------------------------------------
# change_set_hash is a sha256 over the DENYLIST-FILTERED changed-files list, so
# TWO independent things move it and both are hash migrations:
#
#   1. EDITING THIS REGEX. It changes the recomputed hash for any change set
#      containing a newly-(un)matched path.
#   2. CHANGING WHAT REACHES changed-files.txt IN THE FIRST PLACE. 94d added
#      qa-gate.sh's reconcile_tracker, which appends the git-visible paths no
#      Write/Edit hook recorded, widened post-edit.sh's matcher to NotebookEdit,
#      and (closing R2-F5) made post-edit.sh apply the SELF-WRITTEN rule below,
#      which SHRINKS the input for any session whose tracker had absorbed gate
#      state. Any session with git-visible dirt beyond what the tracker already
#      held therefore hashes DIFFERENTLY after that landing, with this regex
#      untouched. The list is the hash's input; growing OR shrinking the input is
#      the same migration as re-filtering it. All of it is ONE landing, so an
#      in-flight cycle pays the migration once.
#
# Either way an approval recorded before the change no longer matches the hash
# the Stop hook recomputes after it, so the gate emits LABEL_WITHOUT_RECORD and
# re-blocks until a fresh `qa-gate.sh enter` + re-approve. That is the correct
# fail-closed direction (a stale approval must not release), but it is
# USER-VISIBLE friction: ship each kind of change in ONE landing so in-flight
# cycles pay the migration exactly once. See CHANGELOG and docs/HOOKS.md
# ("Denylist changes are a hash migration").

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
#   6. .claude/plans/           plan-mode plan files, wherever they live. The
#                               branch anchors on (^|/) — start-of-string OR a
#                               path separator — not on ^, so it matches the
#                               real shape (~/.claude/plans/<slug>.md, OUTSIDE
#                               the repo) as well as a repo-relative
#                               .claude/plans/<slug>.md. A plan is the INPUT
#                               to the work, not the work — and because it is
#                               .md it classified doc-only, whose fast path
#                               auto-approves only WITH an active task, so a
#                               plan-mode session (which cannot create one)
#                               had no exit at all. Five recorded occurrences
#                               of THIS shape alone; one blocked a session
#                               across three Stop iterations up to J21
#                               escalation.
#                               ANTI-OVERREACH: docs/plans/ is a tracked
#                               deliverable and does NOT match.
#   7. session scratchpad       ^(/private)?/tmp/claude-<session>/ — the
#                               harness's own per-session scratch (grader
#                               verdict files, relay artifacts) that mutated
#                               the change-set hash mid-relay. ABSOLUTE and
#                               ^-anchored deliberately: an unanchored branch
#                               would also drop somebody's src/tmp/claude-1/,
#                               and ERE alternation keeps the ^ scoped to
#                               this branch alone. ANTI-OVERREACH: limited to
#                               the claude- prefix the harness itself creates;
#                               see "WHAT IS DELIBERATELY *NOT* DENYLISTED"
#                               above for why /tmp at large is a mechanical
#                               error, not a stylistic choice.
#   8. mutation harness state   .claude/.mutation-runs/ (per-run reports) and
#                               .claude/.mutation-worktrees/ (throwaway
#                               checkouts) from .claude/tests/mutation/
#                               mutation-sweep.sh. Gitignored, but reachable
#                               by Edit because --keep-worktrees exists so a
#                               human can debug a surviving mutant in situ.
#                               ANTI-OVERREACH: the harness's own SOURCE
#                               under .claude/tests/mutation/ is a
#                               deliverable and does NOT match.
WORKFLOW_DENYLIST_REGEX='(^|/)(node_modules|dist|build|coverage|\.git|\.next|\.nuxt|target|__pycache__)/|(^|/)\.claude/worktrees/|(^|/)\.claude/tests/e2e/fixtures/[^/]+/(\.claude/(scripts|beads)|\.beads)/|(^|/)MEMORY\.md$|(^|/)\.claude/memory/|\.(lock|lockb|map|pyc)$|\.min\.(js|css)$|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb|Cargo\.lock|poetry\.lock|go\.sum)$|(^|/)\.claude/plans/|^(/private)?/tmp/claude-[^/]+/|(^|/)\.claude/\.mutation-(runs|worktrees)/'

# workflow_denylisted <path> — 0 = drop it, 1 = keep it.
workflow_denylisted() {
    [ -n "${1:-}" ] || return 1
    [[ "$1" =~ $WORKFLOW_DENYLIST_REGEX ]]
}

# ---------------------------------------------------------------------------
# SELF-WRITTEN PATHS (claude-workflow-plugin-94d) — a SECOND, narrower rule.
#
# WHAT IT IS: the paths the workflow itself rewrites as a side effect of running.
# Membership test, and it is deliberately strict: rewritten by the gate's own
# machinery on essentially every invocation, and never authored by the work under
# review.
#
#   .claude/.qa-tracking/**      gate state — the tracker, the baseline, the
#                                impact report, the review artifacts. NOT
#                                gitignored in every install: install.sh writes
#                                that rule only when the target has no
#                                .gitignore at all.
#   .beads/interactions.jsonl    bd's interaction log. bd rewrites it on EVERY
#                                call, including the gate's own add_comment and
#                                `label add`.
#
# `.beads/issues.jsonl` is NOT a member: it is the committed ledger, a real
# deliverable, and bd 1.1.2 rewrites it only on an explicit export — so it is
# stable across a cycle and belongs in the change set.
#
# WHY IT IS SEPARATE FROM WORKFLOW_DENYLIST_REGEX, and must stay separate:
# folding these into the denylist would drop them from the change set ENTIRELY,
# which flips a beads-only change set from the `beads-state` fast path (releases
# WITH a gate record) to `empty` (releases with none). llh.3 made that
# classification call deliberately, in the other direction, for MEMORY.md. This
# rule answers a different question — "may this path enter the change set as a
# side effect of the gate running?" — and nothing else about denylist semantics
# changes.
#
# WHY IT EXISTS AT ALL: both halves of the change set MUST agree about it.
# `qa-gate.sh reconcile_tracker` refuses to append these paths, because a hash
# that moves when the gate writes its own state deadlocks a cycle by
# construction (enter generates impact-report-<tid>.json; approve reconciles,
# sees it as new, and the report it just enforced freshness on is stale against a
# hash the enforcement itself moved). `verify-before-stop.sh`'s git walk must
# skip them for the same reason in reverse: it once did not, and the tracker then
# excluded `.beads/interactions.jsonl` while the DETECTOR included it — so
# DOC_ONLY went false on every doc-only change set as soon as any bd call had
# run, and the F1 fast path died in production. That is precisely the
# "hash and gate disagree about what the changes are" failure the consolidation
# above exists to prevent, so this rule lives here, in one place, for both.
#
# THREE CONSUMERS APPLY IT, and getting that list wrong is not hypothetical:
#
#   post-edit.sh                   never records one (writer 1 of the tracker)
#   qa-gate.sh reconcile_tracker   never appends one (writer 2 of the tracker)
#   verify-before-stop.sh          reviewable_changes()'s git walk skips them
#
# `impact-report.sh` deliberately does NOT apply it. It READS the tracker the
# first two write, so by hash time a self-written path has already been filtered
# at the source; applying it at a reader would make that reader disagree with the
# other readers about an entry an older install had already recorded, which is
# the same disagreement class described above.
#
# post-edit.sh was MISSING from that list when this rule first shipped (QA
# finding R2-F5), and because post-edit.sh is the PRIMARY route into the tracker
# the omission inverted the rule on the path that matters most: a reviewer
# writing `.claude/.qa-tracking/review-artifact-<tid>-r<n>.json` with the Write
# tool moved change_set_hash, which staled the impact report `enter` had just
# generated, which made `approve` refuse with impact_report_stale. It went
# unnoticed for two review rounds because every OTHER writer of gate state uses a
# shell redirect, which no PostToolUse hook sees. Pinned now at three layers:
# denylist-source.test.sh asserts each applier CALLS the function,
# specs/post-edit.sh section 12 (+ its 12M strip-META) drives writer 1, and
# specs/denylist-shared.sh section E drives writer 2 and the boundary.
#
# Anchored on (^|/) so it matches an absolute path, a repo-relative one, and a
# nested checkout's copy alike — the consumers spell paths differently
# (post-edit and reconcile_tracker record absolute, porcelain is repo-relative)
# and every one of them must match.
WORKFLOW_SELF_WRITTEN_REGEX='(^|/)\.claude/\.qa-tracking/|(^|/)\.beads/interactions\.jsonl$'

# workflow_self_written <path> — 0 = the workflow wrote it (keep it OUT of the
# change set), 1 = it is not self-written.
workflow_self_written() {
    [ -n "${1:-}" ] || return 1
    [[ "$1" =~ $WORKFLOW_SELF_WRITTEN_REGEX ]]
}

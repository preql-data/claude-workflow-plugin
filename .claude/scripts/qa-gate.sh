#!/bin/bash
# QA Gate Lifecycle helper.
#
# Beads-backed design-gate lifecycle for the QA workflow. Replaces the legacy
# `.claude/.qa-tracking/approved` marker file (B1/D1/J2) and the comment-text
# fallback (B13). Single source of truth: Beads labels.
#
# Subcommands:
#   enter   <task-id>                       Mark gate as entered (label + comment).
#                                           Also generates the mechanical impact
#                                           report via impact-report.sh (G2.n6d;
#                                           tolerant — enter never fails on it).
#                                           Clears a PRIOR CYCLE's qa-approved in
#                                           both arms — the fresh one and the
#                                           already-entered one (jue). Does NOT
#                                           write a cycle record in the
#                                           already-entered arm, so a
#                                           qa-gate-entered label is not evidence
#                                           that enter ever ran.
#   status  <task-id>                       Print one of: not-entered, entered, approved, blocked.
#   approve <task-id> [--expect-hash <hash>] [--no-impact-report '<reason>']
#           [--no-review '<reason>'] <approval-summary>
#                                           --expect-hash <h> names the change set
#                                           the CALLER classified; approve REFUSES
#                                           (exit 2, expected_hash_mismatch) if that
#                                           is not the set it would bind, naming both
#                                           hashes (qzv). It proves bound == classified,
#                                           NOT that the set is complete.
#                                           Atomic (8zi): +qa-approved and -every
#                                           other QA cycle label (qa-blocked,
#                                           qa-gate-entered, qa-pending,
#                                           qa-escalated, qa-deferred,
#                                           rubric-pending), + comment. On any
#                                           failure the pre-call label set is
#                                           restored exactly and it exits 3.
#                                           rubric-satisfied is NOT in the cycle
#                                           set and is preserved as the audit
#                                           trail of the verdict that backed the
#                                           approval.
#                                           REFUSES (exit 2) when the impact report
#                                           (.qa-tracking/impact-report-<task-id>.json)
#                                           is missing or its change_set_hash no longer
#                                           matches the current changed-files list.
#                                           server:"absent" reports are accepted (the
#                                           documented degradation). The bypass flag
#                                           approves anyway and records the reason in
#                                           the approval comment + gate JSON.
#                                           ALSO REFUSES (exit 4) when independent
#                                           review is missing/non-independent/has open
#                                           findings, per review-check.sh gate (V3).
#                                           --no-review '<reason>' is the audited
#                                           bypass for that check.
#   block   <task-id> <reason>              Add qa-blocked label + comment. Keeps
#                                           qa-gate-entered, qa-pending,
#                                           rubric-pending and the escalation pair
#                                           — a block happens MID-cycle. Clears
#                                           qa-approved only (8zi): every label
#                                           reader in the tree tests qa-approved
#                                           first, so a surviving one would report
#                                           a blocked task as approved. Same
#                                           restore-exactly-then-exit-3 discipline
#                                           as approve.
#   baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]
#                                           Write .qa-tracking/gate-baseline (3mg.1): the
#                                           `git status --porcelain` snapshot the Stop gate
#                                           subtracts so it evaluates the session DELTA, not a
#                                           tree that was dirty on arrival. No task, no bd.
#   reconcile-tracker                       Fold every git-visible changed path the
#                                           Write/Edit/MultiEdit hook never saw (Bash
#                                           redirects, cp, generator scripts) into
#                                           .qa-tracking/changed-files.txt, so the
#                                           change-set hash covers the whole diff rather
#                                           than the subset post-edit.sh recorded (94d).
#                                           No task, no bd, no labels. Exit 2 when the
#                                           reconcile cannot be completed — callers must
#                                           treat that as refuse-to-proceed. `enter` and
#                                           `approve` call it themselves; the Stop hook
#                                           calls it at its detection stage.
#   choose  <approve|continue|tech-debt|defer> <task-id> <note> [extra args for tech-debt]
#                                           Spec 0.2: record a J21 decision while qa-escalated.
#                                           Each choice records a comment + acts on labels/state.
#   grade-record <task-id> [--file <path>]  Spec Phase A: record a grader verdict.
#                                           Reads strict-JSON verdict from --file or stdin.
#                                           Appends a Beads comment bound to the graded
#                                           change set; on satisfied flips
#                                           rubric-pending -> rubric-satisfied.
#   review-record <task-id> [--file <path>] Phase V2: validate a reviewer artifact via
#                                           review-check.sh then append the REVIEW-ARTIFACT
#                                           v1 record comment (record writer only).
#   resolve-finding <tid> <fid> --fix <ref> --test <ref> <summary>
#                                           Phase V2: append a RESOLVED <fid> comment
#                                           (id must be in the latest REVIEW-ARTIFACT).
#   arbitrate <tid> <fid> <overrule|sustain> <rationale>
#                                           Phase V2: append an ARBITRATION <fid> comment
#                                           (id must be in the latest REVIEW-ARTIFACT).
#
# Output: every subcommand prints structured JSON to stdout. Errors go to stderr.
# JSON shape (per principle #9 - free-form `observations` for LLM-side context):
#   {"ok": bool, "subcommand": "...", "task_id": "...", "status": "...", "observations": "..."}
#
# Exit codes:
#   0   success
#   1   missing args / usage error
#   2   bd unavailable, task lookup failed, or approve REFUSED for a
#       missing/invalid/stale impact report, or for a change-set tracker that
#       could not be reconciled against git (error_key names which)
#   3   atomic operation rolled back
#   4   approve REFUSED by the V3 review-separation gate: no independent
#       review artifact, the reviewer is also an implementer, findings at or
#       above the risk_threshold are still open, or the review predicate
#       itself is unavailable (fail-closed). error_key names which; the
#       remediation names the resolve-finding / arbitrate / review-record
#       command that clears it.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"

# TRACKER-RECONCILE BEGIN (94d)
# The shared path denylist. This script became a FOURTH consumer of the lib when
# reconcile_tracker landed: it WRITES into changed-files.txt, so it must apply
# exactly the filter post-edit.sh applies to the same file — otherwise the
# reconciler tracks build output the other writer is careful to drop, and the two
# writers of one file disagree about what belongs in it. Everything else in this
# script still defers to impact-report.sh --hash-only for canonicalisation
# (llh.18); this is a filter, not a second hash.
#
# Resolved relative to THIS script (BASH_SOURCE), never to $PROJECT_DIR — the
# gate may run with CLAUDE_PROJECT_DIR pointing at a different checkout than the
# install it lives in. Same convention as the other three consumers.
#
# Missing lib -> reconcile_tracker REFUSES (see its header). That matches the two
# gate-side consumers (impact-report.sh exits 3, verify-before-stop.sh blocks)
# rather than post-edit.sh's track-anyway, because an unfiltered reconcile would
# append build output to an append-only file and there is no way back.
_WFDL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || _WFDL_DIR=""
if [ -n "$_WFDL_DIR" ] && [ -f "$_WFDL_DIR/workflow-denylist.sh" ]; then
    # shellcheck source=.claude/scripts/workflow-denylist.sh
    . "$_WFDL_DIR/workflow-denylist.sh"
fi
# TRACKER-RECONCILE END (94d)

# ---------------------------------------------------------------------------
# Helpers

# sync-errors.log: structured trace for best-effort calls that previously
# silenced everything via `|| true`. SessionStart can surface recent entries.
log_sync_error() {
    local msg="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    printf '%s\t[qa-gate]\t%s\n' "$ts" "$msg" >> "$SYNC_ERRORS_LOG" 2>/dev/null || true
}

# F3 (Phase 4 fix pass): persist active task on `enter`, clear on `approve`.
# Two layers of robustness:
#   1. We pass CLAUDE_PROJECT_DIR explicitly when invoking current-task.sh
#      so the helper writes to the SAME .qa-tracking dir we read from. This
#      guards against cwd drift (e.g., an orchestrator invoking qa-gate.sh
#      from a different working directory than the project root).
#   2. If the helper fails, we fall back to writing the helper file
#      directly. If THAT fails, we log to sync-errors.log so the gap is
#      visible (previously the silent `|| true` is what caused the empty
#      helper file in this project's own claude-workflow-plugin-y4a.10).
write_current_task() {
    local tid="$1"
    local helper_rc=0
    local fallback_rc=0
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$CURRENT_TASK_HELPER" set "$tid" 2>/dev/null || helper_rc=$?
        # Verify the file landed where we expect; if the helper succeeded
        # but the file is missing/empty, treat as a failure and fall through.
        if [ "$helper_rc" -eq 0 ] && [ -s "$QA_TRACKING_DIR/current-task" ]; then
            return 0
        fi
        log_sync_error "current-task.sh set $tid: helper exit=$helper_rc, file_size=$(wc -c < "$QA_TRACKING_DIR/current-task" 2>/dev/null || echo missing); falling back to direct write"
    fi
    # Fallback: write the file directly. We've already mkdir'd the dir;
    # rare failures (read-only fs, perm denied) get logged.
    printf '%s\n' "$tid" > "$QA_TRACKING_DIR/current-task" 2>/dev/null || fallback_rc=$?
    if [ "$fallback_rc" -ne 0 ] || [ ! -s "$QA_TRACKING_DIR/current-task" ]; then
        log_sync_error "direct write of current-task failed for tid=$tid (rc=$fallback_rc)"
        return 1
    fi
    return 0
}

clear_current_task() {
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$CURRENT_TASK_HELPER" clear 2>/dev/null \
            || log_sync_error "current-task.sh clear failed; removing file directly"
    fi
    # Always also rm directly to be safe (idempotent).
    rm -f "$QA_TRACKING_DIR/current-task" 2>/dev/null || true
}

# has_git_repo — is $PROJECT_DIR inside a git checkout we can query?
#
# 3mg.1: the old test was `[ -d "$PROJECT_DIR/.git" ]`, which is FALSE in a
# LINKED WORKTREE (there `.git` is a FILE containing `gitdir: ...`). The
# baseline mechanism therefore silently disabled itself in exactly the
# topology the plugin tells agents to use — no snapshot on approve, and
# verify-before-stop's git fallback skipped entirely. Ask git instead.
# The identical predicate lives in verify-before-stop.sh; keep them in sync.
#
# Consequence worth naming: `rev-parse --git-dir` also succeeds when
# $PROJECT_DIR is a SUBDIRECTORY of a repo (git walks up), where `-d .git`
# failed. Porcelain output is repo-root-relative in that case — self-
# consistent between the baseline and the later comparison, and it moves the
# nested-subdir case from "fallback disabled => gate could release unreviewed
# work" to "fallback active", i.e. from fail-open to fail-closed.
has_git_repo() {
    command -v git >/dev/null 2>&1 || return 1
    git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1
}

# gate-baseline v2 (3mg.1), superseding the 0wk.2 `approved-baseline`.
#
# WHAT IT IS: a snapshot of `git status --porcelain` that says "this dirt was
# already here; it is not this session's work". verify-before-stop.sh's git
# fallback subtracts it, so the gate evaluates the DELTA rather than the whole
# working tree. Without it, a repo that is merely dirty on arrival makes every
# Stop fire "N file(s) changed - all require QA review" forever.
#
# WHY IT IS VERSIONED AND HEADERED: the 0wk.2 file was a bare line list with
# no provenance, so nothing could tell an approve-time snapshot from a
# session-start one, or detect a snapshot taken against a different HEAD.
#
#   # gate-baseline v1
#   head=<sha|none>
#   captured_at=<ISO-8601 UTC>
#   captured_by=session-start|qa-gate-enter|qa-gate-approve
#   --
#   <LC_ALL=C-sorted `git status --porcelain` lines>
#
# LC_ALL=C is load-bearing: the reader uses `comm -23`, which requires both
# inputs in the SAME collation. The writer and verify-before-stop.sh both pin
# C so a locale change between write and read cannot corrupt the diff.
#
# Options:
#   --if-missing        do nothing when a baseline already exists (enter).
#   --exclude-tracked   drop entries whose path is already in
#                       changed-files.txt, so work the session has ALREADY
#                       done can never be baselined as pre-existing (enter).
#
# Tolerances (unchanged from 0wk.2): no git repo -> remove stale baselines and
# succeed; git missing -> log + return 1 (no baseline means the reader treats
# everything as new, which is the fail-closed direction).
GATE_BASELINE_FILE="$QA_TRACKING_DIR/gate-baseline"
LEGACY_APPROVED_BASELINE="$QA_TRACKING_DIR/approved-baseline"

write_gate_baseline() {
    local captured_by="$1"; shift
    local if_missing=0 exclude_tracked=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --if-missing)      if_missing=1 ;;
            --exclude-tracked) exclude_tracked=1 ;;
        esac
        shift
    done

    if ! has_git_repo; then
        # No git repo (or no git): remove stale baselines so a later
        # git-init cannot inherit a snapshot from before the repo existed.
        rm -f "$GATE_BASELINE_FILE" "$LEGACY_APPROVED_BASELINE" 2>/dev/null || true
        command -v git >/dev/null 2>&1 || {
            log_sync_error "write_gate_baseline: git not on PATH (captured_by=$captured_by)"
            return 1
        }
        return 0
    fi

    if [ "$if_missing" = "1" ] && [ -f "$GATE_BASELINE_FILE" ]; then
        return 0
    fi

    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true

    local status_out head ts
    status_out=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort) || {
        log_sync_error "write_gate_baseline: git status failed (captured_by=$captured_by)"
        return 1
    }
    head=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null) || head=""
    [ -n "$head" ] || head="none"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

    if [ "$exclude_tracked" = "1" ]; then
        status_out=$(gate_baseline_exclude_tracked "$status_out")
    fi

    local tmp="$GATE_BASELINE_FILE.tmp.$$"
    {
        printf '# gate-baseline v1\n'
        printf 'head=%s\n' "$head"
        printf 'captured_at=%s\n' "$ts"
        printf 'captured_by=%s\n' "$captured_by"
        printf -- '--\n'
        # `if`, NOT `[ -n ... ] && printf` (94d). The body of a brace group takes
        # the exit status of its LAST command, so on an EMPTY snapshot the false
        # test made the whole group "fail": the handler below deleted the tmp file
        # it had just written correctly, logged "could not write", and returned 1.
        # An empty snapshot is the normal state of a CLEAN tree, and of an
        # --exclude-tracked capture where every dirty path is already tracked, so
        # the effect was that exactly those cases silently got NO baseline —
        # `baseline-capture` reported ok:false and exit 2 on a clean checkout, and
        # `enter --if-missing` could never find one to skip. Reproduced with one
        # variable isolated (clean tree fails, one dirty file succeeds) and pinned
        # by section 8 of specs/gate-baseline-v2.sh.
        if [ -n "$status_out" ]; then
            printf '%s\n' "$status_out"
        fi
    } > "$tmp" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        log_sync_error "write_gate_baseline: could not write $tmp (captured_by=$captured_by)"
        return 1
    }
    mv -f "$tmp" "$GATE_BASELINE_FILE" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        log_sync_error "write_gate_baseline: could not install $GATE_BASELINE_FILE (captured_by=$captured_by)"
        return 1
    }

    # First v2 write retires the legacy file. verify-before-stop.sh reads the
    # legacy one only when no v2 baseline exists (one-release fallback), so
    # leaving it behind would just be a confusing stale artifact.
    rm -f "$LEGACY_APPROVED_BASELINE" 2>/dev/null || true
    return 0
}

# gate_baseline_exclude_tracked <porcelain-lines> — drop the lines whose path
# is already in changed-files.txt.
#
# `enter` arms a review cycle mid-session: files the session ALREADY edited
# are dirty in git AND recorded by post-edit.sh. Baselining them would mark
# the session's own work "pre-existing" and hand it a free pass. Tracked
# entries are absolute (post-edit records `tool_input.file_path` verbatim)
# while porcelain paths are repo-relative, so we match on both spellings.
gate_baseline_exclude_tracked() {
    local status_out="$1"
    local tracking="$QA_TRACKING_DIR/changed-files.txt"
    [ -s "$tracking" ] || { printf '%s' "$status_out"; return 0; }

    local tmp_tracked
    tmp_tracked=$(mktemp -t gate-baseline-tracked.XXXXXX 2>/dev/null) || {
        printf '%s' "$status_out"; return 0
    }
    local t
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        printf '%s\n' "$t"
        case "$t" in
            "$PROJECT_DIR"/*) printf '%s\n' "${t#"$PROJECT_DIR"/}" ;;
        esac
    done < "$tracking" | LC_ALL=C sort -u > "$tmp_tracked"

    local line p kept=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        p="${line#???}"
        # Rename/copy entries are "R  old -> new"; the destination is the
        # path a tracker entry would name.
        case "$p" in *" -> "*) p="${p##* -> }" ;; esac
        if grep -qxF "$p" "$tmp_tracked" 2>/dev/null; then
            continue
        fi
        kept="$kept$line
"
    done <<< "$status_out"
    rm -f "$tmp_tracked" 2>/dev/null || true
    # Trim the single trailing newline the accumulator adds.
    printf '%s' "${kept%$'\n'}"
}

# gate_baseline_entries — the porcelain lines of the current gate baseline, or
# empty when there is none.
#
# The v2 file carries a provenance header terminated by a lone `--`; everything
# after it is the snapshot. The v1 file (`approved-baseline`, 0wk.2) was a bare
# line list and is read as a fallback for ONE release — any v2 write deletes it,
# so that arm only ever serves an install that upgraded mid-cycle.
#
# The IDENTICAL reader lives in verify-before-stop.sh (which cannot source this
# file: qa-gate.sh is a dispatching script, not a lib). Keep them in sync, the
# same standing pairing has_git_repo carries. Within THIS file there is exactly
# one copy of the header-skip awk — cmd_baseline_capture counts through here
# rather than repeating it.
gate_baseline_entries() {
    if [ -f "$GATE_BASELINE_FILE" ]; then
        awk 'body { print; next } /^--$/ { body = 1 }' "$GATE_BASELINE_FILE" 2>/dev/null || true
        return 0
    fi
    if [ -f "$LEGACY_APPROVED_BASELINE" ]; then
        cat "$LEGACY_APPROVED_BASELINE" 2>/dev/null || true
    fi
    return 0
}

# TRACKER-RECONCILE BEGIN (94d)
#
# reconcile_tracker — make changed-files.txt describe the WHOLE session delta,
# not just the subset a Write/Edit/MultiEdit tool call happened to produce.
#
# THE DEFECT THIS CLOSES. changed-files.txt is fed by exactly one writer:
# post-edit.sh, on the PostToolUse events that carry a path field. Anything
# written by a Bash redirect, `cp`, `mv`, `sed -i`, a generator script, or a
# subagent's shell therefore never enters it — measured live four times over two
# days, at one point with the tracker holding 37 of 71 changed files. That is not
# merely an under-reporting detector: `change_set_hash()` hashes THIS FILE's path
# list (impact-report.sh canonical_changed_files), so the gate could name N paths
# and release on an approval binding M < N, and the whole change-set binding —
# the approval record, the rubric verdict, the reviewed hash — certified less than
# the actual diff.
#
# WHY RECONCILE INTO THE TRACKER RATHER THAN UNION AT READ TIME. A read-time
# union in verify-before-stop.sh's reviewable_changes() fixes the DETECTOR and
# leaves the hash tracker-only, which produces a gate that reports 14 paths and
# releases on an approval binding 9 — the same hole, now with a confident
# readout. The tracker is the hash's input, so the repair has to land there.
#
# WHAT IT DOES. `git status --porcelain`, minus the gate baseline, minus the
# denylist, minus what the tracker already holds; the remainder is appended as
# ABSOLUTE paths. Modelled on gate_baseline_exclude_tracked above, whose
# absolute/relative matching and `R old -> new` rename handling this reuses.
#
# CONTRACT, and why each clause is the way it is:
#
#   NOT A GIT CHECKOUT -> NO-OP, rc 0. There is no delta to reconcile against;
#   the tracker is all the gate has and that is the pre-existing behaviour.
#
#   `git status` FAILS -> rc 1. That is the DIVERGENCE SIGNAL, not a pass: we
#   cannot prove the tracker is complete, so every caller treats it as
#   refuse-to-proceed (approve refuses with tracker_unreconcilable; the Stop
#   hook blocks). Same shape as impact-report.sh exiting 3 on a missing
#   denylist rather than hashing with an unknown filter.
#
#   ABSOLUTE PATHS. post-edit.sh records `tool_input.file_path` VERBATIM and the
#   runtime passes absolute paths, so the tracker is absolute in practice (the
#   live file was 129 lines / 87 unique, all absolute). Dedup happens at
#   canonical_changed_files() via `sort -u`, which collapses duplicates but NOT
#   two spellings of one file — so emitting a repo-relative path here would
#   double-count it into the hash. The prefix is $PROJECT_DIR when it IS the repo
#   toplevel (primary checkout or worktree root: the common case, and the
#   spelling post-edit would have used) and git's `--show-toplevel` otherwise
#   (a $PROJECT_DIR nested BELOW the toplevel, where porcelain paths are
#   root-relative and `$PROJECT_DIR/$p` would be wrong). The two are compared
#   through `pwd -P` because git returns symlink-RESOLVED paths while
#   CLAUDE_PROJECT_DIR may be the unresolved spelling — /var/folders/... vs
#   /private/var/folders/... on macOS, which is exactly how a mixed-spelling
#   double count would arrive.
#
#   `??` UNTRACKED AND `D` DELETIONS ARE BOTH INCLUDED. A new file nobody
#   reviewed and a deleted file nobody reviewed are both changes. Git COLLAPSES
#   an untracked directory into one `?? dir/` entry, so a surviving entry ending
#   in `/` is expanded with `status --porcelain -uall -- <dir>`; without that a
#   file added later INSIDE an already-listed directory would not move the hash.
#   The expansion runs only on survivors (rare) so the main call keeps the same
#   invocation as the baseline writer — `comm -23` needs both sides produced
#   identically, and a global `-uall` would make every baselined untracked
#   directory's contents read as new.
#
#   WHAT THE WORKFLOW ITSELF REWRITES IS EXCLUDED — two paths, one rule.
#   Membership test: rewritten by the gate's own machinery on essentially every
#   invocation, and never authored by the work under review.
#
#     .claude/.qa-tracking/**     per-session gate bookkeeping.
#                                verify-before-stop.sh's own is_beads_or_gate_path
#                                calls it "workflow machinery, never reviewable
#                                source", and it is NOT gitignored in every
#                                install: install.sh writes that rule only when
#                                the target has no .gitignore at all, so a project
#                                that already had one has the gate's state
#                                git-visible.
#     .beads/interactions.jsonl  bd's interaction log, rewritten by EVERY bd call
#                                including the gate's own add_comment and
#                                `label add`. Measured, not assumed: it was the
#                                one path that churned in every L2 gate fixture,
#                                and it is what put `.beads/interactions.jsonl`
#                                into an approval's bound file set.
#
#   Why the rule is not optional: reconciling either makes the change-set hash a
#   function of the gate's own progress, and DEADLOCKS a cycle by construction.
#   `enter` reconciles and then writes impact-report-<tid>.json; `approve`
#   reconciles, sees that json as new, appends it, and the report it just
#   enforced freshness on is now stale against a hash the enforcement itself
#   moved. The same shape applies to a bd write landing between the two.
#
#   `.beads/issues.jsonl` is deliberately NOT excluded: it is the committed
#   ledger, a real deliverable, and bd 1.1.2 rewrites it only on an explicit
#   export — so it is stable across a cycle and belongs in the change set, which
#   is what the denylist header means by "beads state stays in the change set".
#
#   FILTERED ON THE ABSOLUTE SPELLING, because that is the string that would
#   enter the tracker and the hash, and it is what post-edit.sh filters. The
#   Stop hook's git half filters the repo-relative spelling, so the two can
#   disagree only for the `^`-anchored absolute branches of the denylist (a repo
#   living inside /tmp/claude-<session>/). There the detector over-reports
#   relative to the hash, which is the fail-closed direction.
#
#   APPEND-ONLY, under the SAME lock post-edit.sh uses, so the two writers
#   serialise where flock exists. Nothing is ever removed: this function can
#   only grow the reviewed set.
#
# KNOWN LIMITS, named rather than left latent:
#   - THE BASELINE IS SUBTRACTED AT LINE GRANULARITY, so a RE-WRITE of an
#     already-baselined path is invisible. `comm -23` compares raw porcelain
#     lines, which are not content-addressed: a path that was dirty when the
#     baseline was captured stays subtracted however much it changes afterwards.
#     It reaches neither the tracker nor change_set_hash nor the block reason,
#     and this function still returns 0. Since 94d.1 it does NOT return silently:
#     `subtracted=N` is in every observation next to `denylisted=N`, and each
#     dropped path is named (inline up to the cap, in full in
#     .claude/.qa-tracking/reconcile-subtracted.txt). The hole is unchanged; only
#     its invisibility is closed.
#     NO COMMIT IS REQUIRED; a second write in the same session is enough, which
#     makes this strictly wider than the committed-work limit below (and wider
#     than claude-workflow-plugin-dpe, which frames the hole as needing an
#     intervening commit). Inherited from the gate baseline's FORMAT, not
#     introduced here — the Stop hook's git half shares the blind spot because
#     it subtracts the same file the same way — but it BOUNDS what this function
#     can promise: for the write classes named at the top (Bash redirect, cp,
#     mv, sed -i, generator scripts) it folds in the ones whose path was CLEAN
#     at baseline capture, or whose status CODE has since changed, and only
#     those. A collapsed `?? dir/` entry that was baselined is the same
#     mechanism: a file created inside it does not surface.
#
#     THE MAGNITUDE AND THE TRIGGER, measured rather than estimated — and both
#     are larger than the "re-write of one path" shape this limit was first
#     written for (94d.1). The trigger that matters is not an incremental second
#     write; it is a SESSION BOUNDARY. SessionStart deleted changed-files.txt
#     unconditionally (including on `compact`), and the very next reconcile then
#     re-derived the WHOLE change set through this subtraction, wholesale. On
#     94d's own review that cost 16 of 26 paths at once — 62%, or 54% counted
#     over QA's independent measurement of the same tree (60 git-visible, 29
#     baseline-identical, 21 denylisted, 10 recovered). It scales with BASELINE
#     AGE, because every path that has been dirty since the last capture is a
#     line the subtraction will match: the baseline in that occurrence was ~35h
#     old, written by an earlier cycle's approve. The deletion half is fixed at
#     the deleter (session-start.sh's TRACKER-PRESERVE region); this limit is
#     what remains once the tracker survives, and it is bounded by baseline age
#     rather than by write count.
#
#     Pinned in both directions by specs/gate-baseline-v2.sh 7.6 / 7.7, with 7R
#     forcing the subtraction branch alone to prove 7.6's cause, and 7S pinning
#     that the drop is now reported. Tracked as `dpe`; NOT fixed here because
#     content-addressing the baseline is its own change-set-hash migration, and
#     the cheaper candidate (invalidate entries against the recorded head) would
#     close only the committed variant.
#   - A path git QUOTES (`"src/na\303\257ve.ts"`, control chars) is appended in
#     its quoted spelling, because the baseline is written with the same
#     quoting and `comm -23` must see identical bytes. The result over-reports
#     a path that does not literally exist — fail-closed, and logged.
#   - Work already COMMITTED is invisible to `git status`, so a tracker
#     destroyed after a commit cannot be recovered from here.
#
# THIS IS NOT A RECOVERY PATH, and the distinction is structural rather than a
# matter of degree (claude-workflow-plugin-94d.1). If changed-files.txt is LOST
# — SessionStart used to delete it unconditionally, including on `compact` — what
# this function rebuilds is necessarily a SUBSET of what was lost, and no
# refinement of the baseline, the `comm`, or the filters can change that. Measured
# on the loss that produced 94d.1: 16 of 26 paths went, through TWO mechanisms,
# and only the first is even addressable here.
#   CHANNEL A — 14 paths whose porcelain line was byte-identical to a gate-baseline
#   entry, so `comm -23` subtracted them. Visible to git; reportable; that is what
#   the accounting below exists to say out loud.
#   CHANNEL B — 2 paths GIT CANNOT SEE AT ALL: `.claude/review-config`, whose
#   content had been reverted so it was not dirty, and a
#   `.claude/.qa-tracking/review-artifact-*.json`, which the shared self-written
#   rule keeps out of the change set by design. Those two existed ONLY in the
#   tracker. `git status` is this function's only source, so they are unrecoverable
#   here in principle, not by omission.
# Channel B is why prevention has to live at the deleter (session-start.sh's
# TRACKER-PRESERVE region) and why this function's job is to ANNOUNCE that it
# reconstructed, never to imply that it restored.
#
# Sets RECONCILE_ADDED (count added), RECONCILE_SUBTRACTED (count dropped as
# already-baselined and NOT covered by the tracker), RECONCILE_SUBTRACTED_PATHS
# (that list), RECONCILE_REBUILT_FROM_EMPTY (1 when the tracker was absent-or-
# empty and a rebuild happened) and RECONCILE_OBS (human-readable).
#
# WHY THE SUBTRACTION IS REPORTED BUT DOES NOT CHANGE THE RETURN CODE. rc!=0 is
# the "cannot determine the change set" signal, and every caller treats it as
# refuse-to-proceed (approve refuses, the Stop hook blocks). Baseline subtraction
# is the baseline's PURPOSE: in a repo that was merely dirty on arrival it drops
# dozens of genuinely pre-existing paths on every call, so returning non-zero for
# it would deadlock every cycle in every dirty checkout. The refusal that DOES
# fire on it is narrower and lives in cmd_approve (error_key
# change_set_reconstructed): reconstruction from an empty tracker AND a non-empty
# subtraction, which together mean the set being bound is provably a subset.
#
# Sentinels are load-bearing: an L2 META-TEST strips every TRACKER-RECONCILE
# region and asserts the Bash-written file stops entering the tracker and the
# block reason. Do not rename them.
RECONCILE_ADDED=0
RECONCILE_OBS=""
RECONCILE_SUBTRACTED=0
RECONCILE_SUBTRACTED_PATHS=""
RECONCILE_REBUILT_FROM_EMPTY=0
RECONCILE_SUBTRACTED_FILE="$QA_TRACKING_DIR/reconcile-subtracted.txt"
# How many subtracted paths are enumerated INLINE in RECONCILE_OBS. The rest are
# counted and pointed at the sidecar. A cap is not tidiness: this string lands in
# `enter`/`approve` JSON observations, and a repo dirty on arrival can subtract
# 150 paths on every call — an unbounded list there would bury the count, which
# is the part a reader acts on.
RECONCILE_SUBTRACTED_INLINE_CAP=12
reconcile_tracker() {
    RECONCILE_ADDED=0
    RECONCILE_OBS=""
    RECONCILE_SUBTRACTED=0
    RECONCILE_SUBTRACTED_PATHS=""
    RECONCILE_REBUILT_FROM_EMPTY=0

    # The full subtracted list, durable, because RECONCILE_OBS only carries the
    # first $RECONCILE_SUBTRACTED_INLINE_CAP and two of the three callers discard
    # the string entirely on the success path (the Stop hook reads RECONCILE_OUT
    # only when rc!=0). TRUNCATED HERE, before any early return: a stale file from
    # the previous call would otherwise read as this call's answer, which is the
    # same defect class as everything else on this task. Lives under
    # .claude/.qa-tracking/, so the self-written rule keeps it out of the change
    # set and it cannot move change_set_hash.
    RECONCILE_SUBTRACTED_FILE="$QA_TRACKING_DIR/reconcile-subtracted.txt"
    : > "$RECONCILE_SUBTRACTED_FILE" 2>/dev/null || true

    if [ -z "${WORKFLOW_DENYLIST_REGEX:-}" ]; then
        log_sync_error "reconcile_tracker: workflow-denylist.sh not loaded (looked in ${_WFDL_DIR:-<unresolvable script dir>}) — refusing to append to changed-files.txt with an unknown filter, which would put build output into an append-only file"
        RECONCILE_OBS="tracker reconcile FAILED: the shared path denylist (workflow-denylist.sh) is not loaded, so which paths belong in the tracker is unknowable"
        return 1
    fi

    if ! has_git_repo; then
        RECONCILE_OBS="tracker reconcile skipped: $PROJECT_DIR is not a git checkout we can query, so there is no git-visible delta to reconcile against"
        return 0
    fi

    local status_out
    status_out=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null) || {
        log_sync_error "reconcile_tracker: 'git status --porcelain' failed in $PROJECT_DIR — the git-visible change set is unknown, so changed-files.txt cannot be proven complete and the change-set hash may certify less than the actual diff"
        RECONCILE_OBS="tracker reconcile FAILED: 'git status --porcelain' could not be read in $PROJECT_DIR, so the tracker cannot be proven complete"
        return 1
    }

    # The absolute-path prefix for repo-root-relative porcelain paths.
    local prefix="" top canon_pd canon_top
    top=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || top=""
    if [ -n "$top" ]; then
        canon_pd=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P) || canon_pd=""
        canon_top=$(cd "$top" 2>/dev/null && pwd -P) || canon_top=""
        if [ -n "$canon_pd" ] && [ "$canon_pd" = "$canon_top" ]; then
            prefix="${PROJECT_DIR%/}"
        else
            prefix="${top%/}"
        fi
    fi
    if [ -z "$prefix" ]; then
        # A bare repo, or a toplevel we cannot resolve. `git status` would
        # normally have failed already; refuse rather than guess a prefix.
        log_sync_error "reconcile_tracker: could not resolve a working-tree root for $PROJECT_DIR (rev-parse --show-toplevel empty) — cannot spell porcelain paths absolutely, so the tracker cannot be reconciled"
        RECONCILE_OBS="tracker reconcile FAILED: no resolvable working-tree root for $PROJECT_DIR"
        return 1
    fi

    # Already-tracked set, in BOTH spellings — post-edit records absolute paths
    # but a caller (or a fixture) may have seeded relative ones, and appending
    # the other spelling of a file already present is the double count this
    # function exists to avoid.
    # Built by a plain loop rather than `$( ... | sort -u )`: bash 3.2's parser
    # mis-reads `${t#"$prefix"/}` nested inside a command substitution (macOS
    # ships 3.2, and the plugin supports it), and the set is only ever probed
    # with `grep -qxF`, which does not need it sorted.
    #
    # BUILT HERE, ahead of the baseline subtraction, rather than after it as it
    # was before 94d.1: the subtraction accounting below has to know which
    # subtracted paths the tracker ALREADY covers (those are harmless) to isolate
    # the ones it does not (those are the risk class), and it runs before the
    # survivors are walked.
    local tracking="$QA_TRACKING_DIR/changed-files.txt"
    local tracked_set="" t rel
    local tracker_was_empty=1
    if [ -s "$tracking" ]; then
        tracker_was_empty=0
        while IFS= read -r t; do
            [ -z "$t" ] && continue
            tracked_set="$tracked_set$t
"
            case "$t" in
                "$prefix"/*)
                    rel="${t#"$prefix"/}"
                    tracked_set="$tracked_set$rel
"
                    ;;
            esac
        done < "$tracking"
    fi

    # Subtract the baseline. LC_ALL=C on BOTH sides: comm -23 needs one
    # collation, and the writer pins C too (see write_gate_baseline).
    local baseline current survivors subtracted=""
    baseline=$(gate_baseline_entries | LC_ALL=C sort)
    current=$(printf '%s\n' "$status_out" | LC_ALL=C sort | grep -v '^$' || true)
    if [ -z "$current" ]; then
        RECONCILE_OBS="tracker reconcile: working tree clean relative to HEAD; nothing to add (subtracted=0)"
        return 0
    fi
    if [ -z "$baseline" ]; then
        survivors="$current"
    else
        survivors=$(comm -23 <(printf '%s\n' "$current") <(printf '%s\n' "$baseline") | grep -v '^$' || true)
        # SUBTRACTION-ACCOUNTING BEGIN (94d.1)
        # The COMPLEMENT of the line above, and the whole point of 94d.1's
        # visibility half: `comm -12` is the set `comm -23` threw away. Before
        # this it was computed, discarded, and never mentioned — so a call that
        # dropped 16 git-visible paths and a call that dropped none produced
        # indistinguishable output.
        subtracted=$(comm -12 <(printf '%s\n' "$current") <(printf '%s\n' "$baseline") | grep -v '^$' || true)
        # SUBTRACTION-ACCOUNTING END (94d.1)
    fi

    # The accounting clause, appended to every RECONCILE_OBS from here down.
    # DECLARED OUTSIDE the SUBTRACTION-ACCOUNTING region below so the 7SM META's
    # stripped copy stays coherent: with the region excised this stays the empty
    # string and every observation reverts EXACTLY to its pre-94d.1 text, which is
    # what makes that META measure the accounting rather than a syntax error.
    # Same discipline as post-edit.sh's _PE_RESOLVED and approve's impact_obs.
    local account_obs=""

    # SUBTRACTION-ACCOUNTING BEGIN (94d.1)
    # ---- ACCOUNT FOR WHAT THE BASELINE SUBTRACTED (94d.1) -------------------
    #
    # WHICH subtracted entries are reported, and why not all of them. A subtracted
    # path that the tracker ALREADY holds is covered by the change set either way,
    # so naming it would only dilute the count. What is reported is the residue:
    # git-visible, reviewable, dropped as pre-existing, and absent from the
    # tracker — i.e. every path that is in the working tree and outside
    # change_set_hash. That is exactly the set a lost tracker's contents fall
    # into, and also exactly the set genuine arrival dirt falls into. Reconcile
    # cannot tell those apart (that is the honest limit, stated in the readout
    # rather than resolved), so it reports the residue and says it cannot tell.
    #
    # NO `?? dir/` EXPANSION on this side, deliberately, unlike the survivors
    # walk below. A collapsed untracked directory that was baselined hides its
    # contents by the same mechanism; expanding it here would list files that were
    # never individually baselined and inflate the count with paths whose status
    # this function did not actually decide. The DIRECTORY is named instead, which
    # is the honest granularity of what was dropped.
    #
    # COST, named because this runs on every Stop: two `grep -qxF` per subtracted
    # entry, and the subtracted set can be much larger than the survivor set (in a
    # repo dirty on arrival it is most of the baseline). It is the SAME per-path
    # shape the append loop below already uses — deliberately, so the two
    # membership tests cannot drift apart — and it is skipped entirely when the
    # tracker is empty, which is the case this accounting exists for. A single
    # `grep -vxF -f` pass would be cheaper but would have to normalise every
    # tracked entry to one spelling first, which changes what the APPEND side
    # sees; that is not a change this task should make blind.
    local sub_line sub_p sub_abs
    local sub_paths="" sub_count=0
    if [ -n "$subtracted" ]; then
        while IFS= read -r sub_line; do
            [ -z "$sub_line" ] && continue
            sub_p="${sub_line#???}"
            case "$sub_p" in *" -> "*) sub_p="${sub_p##* -> }" ;; esac
            [ -n "$sub_p" ] || continue
            sub_abs="$prefix/$sub_p"
            # Same two filters the append side applies, for the same reason: a
            # denylisted or self-written path is not reviewable work, so its
            # absence from the change set is correct and reporting it is noise.
            if workflow_self_written "$sub_abs"; then
                continue
            fi
            if [[ "$sub_abs" =~ $WORKFLOW_DENYLIST_REGEX ]]; then
                continue
            fi
            # Already covered by the tracker in either spelling -> harmless.
            if [ -n "$tracked_set" ] && printf '%s\n' "$tracked_set" | grep -qxF -- "$sub_abs"; then
                continue
            fi
            if [ -n "$tracked_set" ] && printf '%s\n' "$tracked_set" | grep -qxF -- "$sub_p"; then
                continue
            fi
            sub_paths="$sub_paths$sub_abs
"
            sub_count=$((sub_count + 1))
        done <<< "$subtracted"
    fi
    RECONCILE_SUBTRACTED="$sub_count"
    RECONCILE_SUBTRACTED_PATHS="$sub_paths"
    if [ -n "$sub_paths" ]; then
        printf '%s' "$sub_paths" > "$RECONCILE_SUBTRACTED_FILE" 2>/dev/null || true
    fi

    # A rebuild from an absent-or-empty tracker. `current` is non-empty by the
    # early return above, so reaching here with an empty tracker means every path
    # the tracker ends up holding came from `git status` rather than from a
    # recorded edit.
    if [ "$tracker_was_empty" = "1" ]; then
        RECONCILE_REBUILT_FROM_EMPTY=1
    fi

    # `subtracted=N` is set unconditionally, next to `denylisted=N`, so a reader
    # can never wonder whether a zero means "none" or "not measured" — and
    # `added=0` can never again stand alone as the whole story.
    account_obs="; subtracted=$RECONCILE_SUBTRACTED"
    if [ "$RECONCILE_SUBTRACTED" -gt 0 ]; then
        local sub_shown sub_extra=0
        sub_shown=$(printf '%s' "$sub_paths" | head -n "$RECONCILE_SUBTRACTED_INLINE_CAP" | tr '\n' ' ')
        if [ "$RECONCILE_SUBTRACTED" -gt "$RECONCILE_SUBTRACTED_INLINE_CAP" ]; then
            sub_extra=$((RECONCILE_SUBTRACTED - RECONCILE_SUBTRACTED_INLINE_CAP))
        fi
        account_obs="; SUBTRACTED $RECONCILE_SUBTRACTED git-visible path(s) as already-baselined and NOT covered by changed-files.txt — they are outside the change set and outside change_set_hash. reconcile CANNOT distinguish pre-existing arrival dirt from session work whose tracker entry was lost (94d.1): $sub_shown"
        if [ "$sub_extra" -gt 0 ]; then
            account_obs="$account_obs(+$sub_extra not shown; full list in $RECONCILE_SUBTRACTED_FILE)"
        fi
    fi
    if [ "$RECONCILE_REBUILT_FROM_EMPTY" = "1" ]; then
        account_obs="$account_obs; REBUILT FROM AN EMPTY TRACKER: changed-files.txt was absent-or-empty when this reconcile ran, so every path it now holds came from 'git status', not from a recorded edit. ASSUMPTION MADE: that no tool edit had happened yet. reconcile cannot tell that from 'the tracker was destroyed', and it is NOT a recovery path — a file whose content was reverted and the gate's own artifacts are invisible to git, so a rebuild is only ever a SUBSET (94d.1)"
        # The narrow alarm, and the only sync-errors.log line this function writes
        # for the accounting. Gated on a cycle being in flight because an empty
        # tracker with no cycle open is unremarkable (a fresh session, nothing
        # recorded yet) and the Stop hook reconciles on EVERY stop — logging it
        # unconditionally would flood the log that warning 3 of session-start.sh
        # renders. With a cycle open the tracker is append-only by contract, so
        # empty means either "nothing recorded in this cycle" or "destroyed", and
        # both are worth a durable line.
        if [ -s "$QA_TRACKING_DIR/current-task" ]; then
            log_sync_error "reconcile_tracker: changed-files.txt was absent-or-empty while a gate cycle was in flight ($(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null | tr -d '[:space:]')), so the change set was REBUILT from git status alone; $RECONCILE_SUBTRACTED further git-visible path(s) were dropped as already-baselined (see $RECONCILE_SUBTRACTED_FILE). A rebuild can only be a subset — a reverted-content file and the gate's own artifacts are invisible to git (94d.1)"
        fi
    fi
    # SUBTRACTION-ACCOUNTING END (94d.1)

    if [ -z "$survivors" ]; then
        RECONCILE_OBS="tracker reconcile: every git-visible entry is already in the gate baseline (pre-existing dirt); nothing to add$account_obs"
        return 0
    fi

    local line code p abs quoted=0 denied=0
    local candidates="" expanded _exp_raw
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        code="${line:0:2}"
        p="${line#???}"
        # Rename/copy entries are "R  old -> new"; the destination is the path
        # a tracker entry would name.
        case "$p" in *" -> "*) p="${p##* -> }" ;; esac
        [ -n "$p" ] || continue
        case "$p" in '"'*) quoted=$((quoted + 1)) ;; esac
        # A collapsed untracked DIRECTORY: expand to the files inside it.
        case "$code" in
            '??')
                case "$p" in
                    */)
                        expanded=""
                        # Run from $prefix (the working-tree ROOT), not from
                        # $PROJECT_DIR: porcelain paths are root-relative, and a
                        # pathspec is CWD-relative — from a nested $PROJECT_DIR
                        # the pathspec would match nothing and every collapsed
                        # directory would silently stay collapsed.
                        if _exp_raw=$(git -C "$prefix" status --porcelain -uall -- "$p" 2>/dev/null); then
                            expanded=$(printf '%s\n' "$_exp_raw" | sed 's/^...//' | grep -v '^$' || true)
                        fi
                        if [ -n "$expanded" ]; then
                            candidates="$candidates$expanded
"
                            continue
                        fi
                        # Expansion unavailable: keep the directory entry rather
                        # than drop it (fail closed on something over nothing).
                        ;;
                esac
                ;;
        esac
        candidates="$candidates$p
"
    done <<< "$survivors"

    local to_add=""
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        abs="$prefix/$p"
        # PATHS THE WORKFLOW ITSELF REWRITES — the ONE rule, in the lib, because
        # verify-before-stop.sh's git walk must apply the IDENTICAL rule or the
        # tracker and the detector disagree about the change set (they did: the
        # tracker excluded .beads/interactions.jsonl while the detector included
        # it, which killed the F1 doc-only fast path for every change set once any
        # bd call had run). See workflow_self_written's header for the membership
        # test and for why it is not part of WORKFLOW_DENYLIST_REGEX.
        if workflow_self_written "$abs"; then
            continue
        fi
        if [[ "$abs" =~ $WORKFLOW_DENYLIST_REGEX ]]; then
            denied=$((denied + 1))
            continue
        fi
        # Already present in either spelling?
        if [ -n "$tracked_set" ] && printf '%s\n' "$tracked_set" | grep -qxF -- "$abs"; then
            continue
        fi
        if [ -n "$tracked_set" ] && printf '%s\n' "$tracked_set" | grep -qxF -- "$p"; then
            continue
        fi
        # Exact line match, not a substring test: one candidate path can be a
        # suffix of another and a `case` glob would silently drop it.
        if [ -n "$to_add" ] && printf '%s' "$to_add" | grep -qxF -- "$abs"; then
            continue
        fi
        to_add="$to_add$abs
"
    done <<< "$candidates"

    if [ -z "$to_add" ]; then
        RECONCILE_OBS="tracker reconcile: changed-files.txt already covers every reviewable git-visible path (denylisted=$denied)$account_obs"
        return 0
    fi

    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    # A tracker whose last line lacks its newline (hand-edited; post-edit.sh
    # always writes one) would otherwise get our first path concatenated onto it.
    if [ -s "$tracking" ] && [ "$(tail -c 1 "$tracking" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
        to_add="
$to_add"
    fi
    local lock="$QA_TRACKING_DIR/.changed-files.lock"
    local append_rc=0
    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 9
            printf '%s' "$to_add" >> "$tracking"
        ) 9>"$lock" || append_rc=$?
    else
        # One write() for the whole block: short appends to an O_APPEND fd do
        # not interleave, which is the same safety class post-edit.sh's
        # no-flock append relies on.
        printf '%s' "$to_add" >> "$tracking" || append_rc=$?
    fi
    if [ "$append_rc" -ne 0 ]; then
        log_sync_error "reconcile_tracker: could not append $(printf '%s' "$to_add" | grep -c . | tr -d ' ') reconciled path(s) to $tracking (rc=$append_rc) — the tracker still under-covers the git-visible change set"
        RECONCILE_OBS="tracker reconcile FAILED: append to $tracking returned rc=$append_rc$account_obs"
        return 1
    fi

    RECONCILE_ADDED=$(printf '%s' "$to_add" | grep -c . | tr -d ' ')
    RECONCILE_OBS="tracker reconciled: +$RECONCILE_ADDED git-visible path(s) that no Write/Edit hook recorded (denylisted=$denied)$account_obs"
    if [ "$quoted" -gt 0 ]; then
        log_sync_error "reconcile_tracker: $quoted porcelain entr(y|ies) carried a git-QUOTED path; they are reconciled in their quoted spelling, which over-reports a literal path that does not exist (fail-closed, see the function header)"
        RECONCILE_OBS="$RECONCILE_OBS; WARNING $quoted git-quoted path(s) reconciled in quoted spelling"
    fi
    return 0
}
# TRACKER-RECONCILE END (94d)

# 0wk.2 fix: paired with write_approved_baseline. The legacy approve path
# left changed-files.txt populated; the next post-edit.sh would append
# fresh lines on top of stale ones, and verify-before-stop.sh would treat
# the union as "must re-review". Truncating (rather than removing) keeps
# the file present so post-edit.sh's append-only path is undisturbed.
truncate_changed_files_tracker() {
    local tracking="$QA_TRACKING_DIR/changed-files.txt"
    if [ -f "$tracking" ]; then
        : > "$tracking"  # truncate, preserve file (post-edit.sh appends)
    fi
}

# F4 (Phase 4): wipe iteration counter, last test output, and any draft
# tech-debt artifacts on approval. Idempotent.
#
# Phase 4 fix pass / MATERIAL 5: the iteration counter is now keyed by
# task_id (e.g., iteration-count.<task-id>), so we wipe both the legacy
# unscoped path AND the per-task path for the task being approved. The
# task_id is passed as $1.
#
# Spec 0.2: also wipe escalation artifacts (cached test result, escalation
# comment marker) so a future cycle starts clean.
wipe_iteration_state() {
    local tid="$1"
    rm -f "$QA_TRACKING_DIR/iteration-count" 2>/dev/null || true
    if [ -n "$tid" ]; then
        local sanitized
        sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
        rm -f "$QA_TRACKING_DIR/iteration-count.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/last-test-rc.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/last-failed-checks.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/last-runner.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/escalation-posted.$sanitized" 2>/dev/null || true
    fi
    rm -f "$QA_TRACKING_DIR/last-test-output.log" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/last-lint-output.log" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/last-type-output.log" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/tech-debt-draft.md" 2>/dev/null || true
}

# V3 (claude-workflow-plugin-jio.1): drop the review round's on-disk scratch
# files once an approval completes. The durable record is the Beads comment
# set (REVIEW-ARTIFACT / RESOLVED / ARBITRATION) — these JSON files are only
# the hand-off medium between the request author, the reviewer, and the record
# writer, so leaving them behind means the next cycle's reviewer can pick up a
# previous round's artifact by path and record it as if it were fresh.
#
# Two naming conventions are cleaned because two producers exist: qa.md's
# section 6-prime writes `review-request-<task-id>.json` with the RAW id,
# while the driver writes `review-artifact-<sanitized>-r<n>.json`. We remove
# both spellings rather than assume. Idempotent and silent by design.
wipe_review_artifacts() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    local sanitized f
    sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
    rm -f "$QA_TRACKING_DIR/review-request-$tid.json" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/review-request-$sanitized.json" 2>/dev/null || true
    # Iteration-suffixed artifacts. The `[ -e ]` guard handles the no-match
    # case (bash leaves the literal pattern when nothing matches).
    for f in "$QA_TRACKING_DIR/review-artifact-$tid"-r*.json \
             "$QA_TRACKING_DIR/review-artifact-$sanitized"-r*.json; do
        [ -e "$f" ] && rm -f "$f" 2>/dev/null
    done
    return 0
}

# Spec 0.2: best-effort label clears for escalation labels. Used by approve,
# enter, and the choose subcommand for the "continue"/"approve" paths.
# We intentionally swallow errors — these labels may not be present and
# bd's remove-when-absent path is a no-op.
remove_escalation_labels() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    remove_label "$tid" "qa-escalated" 2>/dev/null || true
    remove_label "$tid" "qa-deferred" 2>/dev/null || true
}

# Spec Phase A: helpers for rubric labels. Kept separate from the escalation
# helper because the lifecycles are independent — a rubric verdict can be
# satisfied without ever entering escalation, and vice versa. Best-effort
# semantics match remove_escalation_labels.
remove_rubric_pending() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    remove_label "$tid" "rubric-pending" 2>/dev/null || true
}

remove_rubric_satisfied() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    remove_label "$tid" "rubric-satisfied" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# THE ONE TERMINAL-LABEL TRANSITION (8zi, l1r.3, jue).
#
# Every label the gate sets and clears inside one review cycle. A terminal label
# (qa-approved / qa-blocked) is the verdict of a cycle; the rest are its
# in-flight state. Callers name what they clear, and set_terminal_label refuses a
# name that is not in this set — see the guard for why silence is the failure mode
# that has to be designed out here specifically.
#
# rubric-satisfied IS DELIBERATELY NOT IN THIS SET, and its absence is the
# mechanism that protects it rather than a comment asking people to be careful.
# It is the audit trail of the grader verdict that backed an approval, which is
# why cmd_approve preserves it (the had_rubric_satisfied capture, the three-way
# "rubric-satisfied preserved (audit trail)" observation, and the
# [rubric mismatch: graded=... approved=...] override token that logs a
# sync_error when the satisfied verdict binds a different change set than the
# approval). cmd_enter owns the only clears, and bjx made them conditional on the
# verdict's change_set_hash. Because rubric-satisfied is not a member here, a
# future call site that tried to sweep it is REFUSED at the guard below instead of
# quietly destroying that trail.
QA_CYCLE_LABELS="qa-approved qa-blocked qa-gate-entered qa-pending qa-escalated qa-deferred rubric-pending"

# set_terminal_label's out-params, declared at file scope so a caller can read
# them without depending on the call having reached any particular branch.
#   TERMINAL_SWEEP_PHASE   "" | usage | add_terminal | sweep   (which step failed)
#   TERMINAL_SWEEP_REMOVED space-delimited labels actually removed (present -> gone)
#   TERMINAL_SWEEP_OBS     human-readable account, for the caller's envelope
TERMINAL_SWEEP_PHASE=""
TERMINAL_SWEEP_REMOVED=""
TERMINAL_SWEEP_OBS=""

# restore_labels <task-id> <snapshot> — put the label set back exactly.
#
# <snapshot> is a get_labels string (comma-joined). Both directions are applied:
# anything the snapshot had and the task no longer does is re-added, anything the
# task has and the snapshot did not is removed. Then the result is COMPARED back
# against the snapshot, so the restore has a provable postcondition rather than a
# best-effort one.
#
# The byte comparison is a set comparison here, MEASURED not assumed: bd 1.1.2
# returns labels sorted, and a remove-then-re-add of one label reproduces the
# identical joined string. If a future bd returned insertion order instead, this
# comparison could report a false failure on a correctly restored SET — which only
# ever degrades the message, never the outcome: the caller is already on its
# failure path and already exits 3 either way.
restore_labels() {
    local tid="$1" snapshot="$2"
    local current rc=0 l
    current="$(get_labels "$tid")"
    local IFS=,
    for l in $snapshot; do
        [ -n "$l" ] || continue
        case ",$current," in
            *",$l,"*) ;;
            *) add_label "$tid" "$l" || rc=1 ;;
        esac
    done
    for l in $current; do
        [ -n "$l" ] || continue
        case ",$snapshot," in
            *",$l,"*) ;;
            *) remove_label "$tid" "$l" || rc=1 ;;
        esac
    done
    [ "$(get_labels "$tid")" = "$snapshot" ] || rc=1
    return $rc
}

# set_terminal_label <task-id> <terminal-label> [<clear-label> ...]
#
# Sets <terminal-label> and clears each <clear-label> that is present, as one
# transition: on any failure the label set is restored to what it was before the
# call and a non-zero status is returned. Callers turn that into exit 3.
#
# WHY THIS EXISTS. cmd_approve used to walk the transition step by step, and the
# steps were not exhaustive across cycles: a block -> fix -> approve round trip
# ended with the task carrying BOTH qa-approved and qa-blocked, because approve
# cleared qa-gate-entered, qa-pending, the escalation pair and rubric-pending but
# never the previous cycle's terminal label. Observed live four times (uvk, q7n,
# 94d, and qzv.1 where the gate's own reviewer removed the label by hand mid-
# approval), which is the argument for one function over one more removal: the
# defect is not a missing line, it is that "what a cycle clears" was expressed as
# a list of independent steps that a future label can be added without.
#
# ORDER: the terminal label goes on FIRST, then the sweep. That is the gz3
# ordering rule the step-by-step version already followed, kept deliberately: the
# approval RECORD is written before this call, so from the moment the terminal
# label lands the {record, label} pair is coherent and a concurrent Stop sees
# either no approval yet or a complete one. The transient state this produces on
# approve is {qa-approved, qa-blocked} — the 8zi state — for the width of one bd
# call. Every reader in the tree resolves that to `approved`, because all four
# test qa-approved first: cmd_status, epic-gate.sh's qa_state_of, and
# statusline.sh's two label readers. Sweeping first would instead open a window
# with NO terminal label, which those same readers resolve to `entered` or `none`.
set_terminal_label() {
    local tid="$1" terminal="$2"
    shift 2 2>/dev/null || true
    TERMINAL_SWEEP_PHASE=""
    TERMINAL_SWEEP_REMOVED=""
    TERMINAL_SWEEP_OBS=""

    if [ -z "$tid" ] || [ -z "$terminal" ]; then
        TERMINAL_SWEEP_PHASE="usage"
        TERMINAL_SWEEP_OBS="set_terminal_label: <task-id> and <terminal-label> are both required"
        return 1
    fi

    # THE MEMBERSHIP GUARD. Refuse any label outside QA_CYCLE_LABELS rather than
    # issue the removal, because a typo'd or non-cycle label is the one error here
    # with NO observable symptom: bd exits 0 removing a label a task never had,
    # remove_label's read-back then finds it absent and also reports success, and
    # the sweep records a clean transition it never performed. Refusing converts
    # that silence into a usage error at the call site.
    local want
    for want in "$terminal" "$@"; do
        case " $QA_CYCLE_LABELS " in
            *" $want "*) ;;
            *)
                TERMINAL_SWEEP_PHASE="usage"
                TERMINAL_SWEEP_OBS="set_terminal_label: '$want' is not a QA cycle label (the set is: $QA_CYCLE_LABELS), and a removal of a non-member cannot be distinguished from success — refusing instead of reporting a transition that did not happen"
                return 1
            ;;
        esac
    done

    # SNAPSHOT BEFORE ANY MUTATION. This is what makes the rollback real rather
    # than a hand-maintained inverse of the steps above it.
    local snapshot
    snapshot="$(get_labels "$tid")"

    # Phase 1: the terminal label. Verified with has_label for the same reason
    # remove_label verifies (l1r.3) — bd's exit status is not evidence.
    if ! add_label "$tid" "$terminal" || ! has_label "$tid" "$terminal"; then
        TERMINAL_SWEEP_PHASE="add_terminal"
        TERMINAL_SWEEP_OBS="failed to set $terminal on $tid; no labels changed (pre-call set: ${snapshot:-<none>})"
        return 1
    fi

    # Phase 2: the sweep. has_label first so TERMINAL_SWEEP_REMOVED names only
    # labels that were PRESENT and are now gone — that is the semantics the
    # approve envelope's `removed qa-gate-entered=` / `removed qa-pending=`
    # counters have always reported, and readers grep them.
    local lbl
    for lbl in "$@"; do
        [ -n "$lbl" ] || continue
        [ "$lbl" = "$terminal" ] && continue
        has_label "$tid" "$lbl" || continue
        if remove_label "$tid" "$lbl"; then
            TERMINAL_SWEEP_REMOVED="$TERMINAL_SWEEP_REMOVED $lbl"
            continue
        fi
        TERMINAL_SWEEP_PHASE="sweep"
        TERMINAL_SWEEP_REMOVED=""
        local restore_obs=""
        if restore_labels "$tid" "$snapshot"; then
            restore_obs="pre-call label set restored exactly (${snapshot:-<none>})"
        else
            restore_obs="WARNING the restore itself did not complete: labels now read '$(get_labels "$tid")' against a pre-call set of '${snapshot:-<none>}' — reconcile by hand before re-running"
            log_sync_error "set_terminal_label: rollback INCOMPLETE on $tid after failing to remove $lbl; pre-call='${snapshot:-<none>}' now='$(get_labels "$tid")'"
        fi
        TERMINAL_SWEEP_OBS="failed to remove $lbl after $terminal was set; rolled back — $restore_obs"
        return 1
    done

    TERMINAL_SWEEP_REMOVED="${TERMINAL_SWEEP_REMOVED# }"
    TERMINAL_SWEEP_OBS="$terminal set; cleared [${TERMINAL_SWEEP_REMOVED:-none}] from the cycle set"
    return 0
}
# ---------------------------------------------------------------------------

# G2.n6d (claude-workflow-plugin-llh.2): mechanical impact-report helpers.
#
# The report file is the deterministic impact_of artifact that the QA
# agent cannot skip: enter generates it, approve refuses without a fresh
# one. Path uses the same task-id sanitisation as the iteration counter.
IMPACT_REPORT_SCRIPT="$PROJECT_DIR/.claude/scripts/impact-report.sh"

# Phase V2 (1vq.1): the ONE reviewer-record validator/counter. review-record
# validates artifacts through this subprocess rather than carrying a second
# schema validator (mirrors how compute_change_set_hash defers to
# impact-report.sh --hash-only). This script is reviewer-transport-agnostic.
REVIEW_CHECK_SCRIPT="$PROJECT_DIR/.claude/scripts/review-check.sh"

impact_report_path_for() {
    local sanitized
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/impact-report-%s.json' "$QA_TRACKING_DIR" "$sanitized"
}

# llh.18 (red-team P0/P1): the CANONICAL change-set hash, sourced from the
# ONE place that defines the canonicalisation — impact-report.sh --hash-only.
# We deliberately do NOT re-implement the sort/denylist/sha here (the
# denylist regex already lives in 3 copies; a 4th would be a fresh drift
# surface). Printing empty on any failure is intentional: the caller decides
# whether an unverifiable hash is fatal (approve's refusal block) or merely
# omits the change-set binding (best-effort comment write).
compute_change_set_hash() {
    [ -f "$IMPACT_REPORT_SCRIPT" ] || { printf ''; return 1; }
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$IMPACT_REPORT_SCRIPT" --hash-only 2>/dev/null || printf ''
}

# bjx: the literal impact-report.sh prints when NEITHER shasum NOR sha256sum is
# on PATH (see its sha256_stdin). It is a non-empty string, so every `[ -n
# "$h" ]` guard in this file reads it as a usable hash — and, being CONSTANT, it
# compares EQUAL to itself across two calls. That is harmless where a hash is
# only recorded, and NOT harmless where two hashes are compared to decide
# whether a verdict still covers the current work: on such a host the rubric
# preservation guard would match unconditionally. Both the writer and the reader
# below therefore treat this value as "no hash", which is what the surrounding
# contract already claims ("omitted, not faked, when the hash cannot be
# computed"). Named once so the two sites cannot drift apart.
#
# Deliberately NOT a fix to the sentinel itself: impact-report.sh owns the
# canonicalisation and its degraded-mode return is shared with approve and the
# Stop hook, so changing it belongs to that script's contract, not to this one.
CHANGE_SET_HASH_UNAVAILABLE="sha256-unavailable"

# bd_show_with_comments <task-id> — `bd show --json` that always carries
# comment BODIES, across the supported bd range.
#
# bd 1.1.2 stopped inlining comments in `bd show --json`: it returns a
# `comment_count` integer, and the bodies need the new --include-comments flag.
# bd 0.47.x has no such flag and exits 1 ("unknown flag: --include-comments"),
# but inlines .comments already. So try the new form, fall back to the plain
# one — pin the CHAIN, not the leg, exactly as add_comment() does for
# `bd comments add || bd comment add`. Callers keep the usual
# `(if type=="array" then .[0].comments else .comments end) // []` accessor,
# which reads both shapes correctly. Never fails the caller.
#
# Only readers of .comments need this. get_labels() and the other
# .labels/.status/.notes readers must NOT use it: the flag's own help warns it
# "may be slow on issues with many comments", and those fields are unaffected.
bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

# gz3 (v4.1 U1): the approval records THIS task already carries — one
# change_set_hash per `QA-GATE APPROVED ... change_set_hash=<h> ...` comment.
#
# The `select` + `capture` pair below is BYTE-IDENTICAL to
# verify-before-stop.sh's task_has_matching_approval_record. That is deliberate
# and load-bearing: this is the WRITER reading its own records back to decide
# whether an approval already covers the current change set, and if it used a
# looser or stricter grammar than the reader that decides RELEASE, the two would
# disagree about what counts as an approval — which is the class of bug gz3 is.
# The parity is asserted textually (both expressions extracted from the two
# scripts and compared) in
# .claude/tests/component/specs/approve-idempotency.sh.
#
# Never fails the caller: no bd, no task, unparseable JSON -> empty output,
# rc 0. An empty answer means "no record found", which makes approve PROCEED
# (write a fresh binding) rather than claim idempotency it cannot prove.
recorded_approval_hashes() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    command -v bd >/dev/null 2>&1 || return 0
    bd_show_with_comments "$tid" \
        | jq -r '
            (if type == "array" then .[0].comments else .comments end) // []
            | .[].text
            | select(test("QA-GATE APPROVED .*change_set_hash="))
            | capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h
        ' 2>/dev/null || true
    return 0
}

# gz3: does <tid> already carry an approval record bound to <hash>?
# An empty <hash> never matches (an unverifiable hash must not read as covered).
task_has_approval_record_for() {
    local tid="$1" hash="$2"
    [ -n "$hash" ] || return 1
    recorded_approval_hashes "$tid" | grep -qxF "$hash"
}

# bjx (v4.1 U1): the change set the task's CURRENT rubric verdict was graded
# against — empty unless the LATEST RUBRIC record is a `satisfied` one AND it
# carries a change_set_hash.
#
# Same shape, and the same reason, as recorded_approval_hashes above. llh.18
# stopped believing that the qa-approved LABEL meant "approved" because a label
# says an event happened and says nothing about WHICH files it covered;
# rubric-satisfied is the same kind of label, and `enter` needs the second
# question answered before it can tell a verdict that still covers the current
# work from one left over from a previous change set.
#
# Three deliberate properties:
#   - LATEST-WINS, not latest-satisfied-wins, and — R2-F3 — not last-PARSEABLE
#     either. A `satisfied` later superseded by a `needs_revision` must not read
#     as bound: the needs_revision path leaves labels alone (rubric-satisfied
#     would still be sitting on the task), so keying on "is there a satisfied
#     record anywhere" would resurrect an overruled verdict.
#
#     The first version of this got the SELECTOR wrong in a way that produced
#     exactly that resurrection. It applied `capture` across every comment and
#     took `last` of the RESULTS, so an unparseable latest record simply fell
#     out of the array and `last` silently returned an OLDER one. A `satisfied`
#     iteration 1 followed by a `needs_revision` iteration `1.5` (the writer
#     accepted any JSON number; the reader requires `[0-9]+`) therefore kept the
#     stale satisfied hash across re-entry. Reproduced, with an integer control.
#
#     So: SELECT the latest record FIRST (every comment that starts a RUBRIC
#     record), and only then parse it. An unparseable latest record now yields
#     unbound — stale — instead of deferring to its predecessor. This half is
#     the load-bearing one: validating `iteration` at the writer (which we also
#     do, below) cannot help for a record the writer never created — a legacy
#     one, or a hand-written comment — and that case was reproduced on the
#     shipped script. Pinned with a META in section J of
#     .claude/tests/component/specs/rubric-binding.sh.
#
#     `startswith("RUBRIC ")` rather than a regex: the selector must not itself
#     be a place where a metacharacter can change the meaning. A comment that
#     merely QUOTES a record mid-text does not start with the prefix and so is
#     not a record — correct, a quoted mention must not invalidate a verdict.
#   - ANCHORED at ^, walking the whole machine prefix rather than grepping for
#     the token anywhere on the line. The line's tail is the grader's free-text
#     summary; the anchor is what stops a summary that happens to contain the
#     token's spelling from being read as a binding. jq's `^` is STRING-anchored
#     (Oniguruma, no `m` flag), so a multi-line comment whose interior line
#     starts with a RUBRIC record does not match either — load-bearing, because
#     agents do paste RUBRIC text into ordinary comments.
#   - The version class is `[A-Za-z0-9._+-]+`, the SAME class cmd_grade_record
#     validates `.rubric_version` against, and the reason both exist is a
#     forgery QA reproduced end-to-end. `rubric_version` used to be validated
#     only as "non-empty string" and is interpolated into the record with spaces
#     around it, so a crafted version — `1 iteration 1: satisfied
#     change_set_hash=<real>` — moved the record's FIRST colon into the injected
#     text. The parse then read the injected prefix instead of the real one and
#     a `needs_revision` record came back `satisfied` AND bound. The writer is
#     where that is CLOSED (a class with no spaces and no colon cannot relocate
#     anything); this class is the reader half of the same contract, so the two
#     grammars agree about what a version may be. Section F of
#     .claude/tests/component/specs/rubric-binding.sh asserts the two spellings
#     are identical, extracted from both sites.
#     A record whose version is outside the class reads as UNBOUND, which
#     clears — the safe direction, and the pre-bjx behaviour.
#   - The sentinel hash is refused. See CHANGE_SET_HASH_UNAVAILABLE: on a host
#     with no sha tool the "hash" is a constant, so it would compare equal to
#     itself and preserve unconditionally. It is treated as no binding at all.
#
# The hash group is OPTIONAL so a pre-bjx record (no token) matches the record
# grammar and answers "" rather than not matching at all — the distinction
# never reaches the caller, but it keeps the expression honest about which
# records it recognises.
#
# NOT defended against, and inherited rather than introduced here: an agent with
# arbitrary shell can `bd comments add` a well-formed RUBRIC record by hand.
# That is the same threat-model boundary llh.18 documents for the approval
# record — this raises the bar from "a label" to "a change-set-bound record",
# it is not a cryptographic sandbox. What the writer-side validation closes is
# the strictly worse case: forging through the tool's own validated input.
#
# Never fails the caller: no bd, no task, unparseable JSON -> empty, rc 0.
latest_satisfied_rubric_hash() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    command -v bd >/dev/null 2>&1 || return 0
    bd_show_with_comments "$tid" \
        | jq -r --arg unavailable "$CHANGE_SET_HASH_UNAVAILABLE" '
            [ (if type == "array" then .[0].comments else .comments end) // []
              | .[].text
              | select(startswith("RUBRIC "))
            ]
            | last
            | if . == null then ""
              else
                ( [ capture("^RUBRIC (?<v>[A-Za-z0-9._+-]+) iteration (?<n>[0-9]+): (?<verdict>[A-Za-z_]+)( change_set_hash=(?<h>[A-Za-z0-9-]+))?") ]
                  | last
                  | if . == null then ""
                    elif .verdict != "satisfied" then ""
                    elif (.h // "") == $unavailable then ""
                    else (.h // "") end )
              end
        ' 2>/dev/null || true
    return 0
}

# gz3: the change_set_hash of the PERSISTED impact report for <tid>, or empty.
persisted_report_hash() {
    local report
    report=$(impact_report_path_for "$1")
    [ -f "$report" ] || { printf ''; return 0; }
    jq -r '.change_set_hash // empty' "$report" 2>/dev/null || printf ''
    return 0
}

# gz3: the hash an existing approval must carry for THIS approve to be a
# genuine no-op — i.e. the change set this approve would bind.
#
# Normally that is the live recompute. The exception is the state a PREVIOUS
# approve leaves behind: approve TRUNCATES changed-files.txt (0wk.2), so a
# recompute in this checkout answers with the EMPTY-LIST hash and the tracker no
# longer witnesses what was approved. LESSONS.md records the rule that follows
# from that ("any cross-checkout or after-the-fact verification must read the
# PERSISTED record — impact-report-<tid>.json, which survives approve — never
# recompute"), and this is an after-the-fact verification: with an empty tracker
# the persisted report is the only surviving witness of the approved change set.
#
# Consequence, and the reason the split exists: a plain double `approve` stays an
# idempotent no-op (report hash == the recorded hash), while an approve run after
# the change set MOVED compares against the live recompute and therefore
# proceeds. Always rc 0 — compute_change_set_hash returns 1 when
# impact-report.sh is missing, and a bare `x=$(f)` whose RHS exits non-zero
# aborts the script under `set -e` (line 70).
#
# KNOWN RESIDUAL of the empty-tracker arm, reproduced and pinned (section H of
# specs/approve-idempotency.sh): when the tracker is empty AND real
# un-baselined dirt exists — work written by a helper rather than the Edit tool,
# which never reaches changed-files.txt (LESSONS.md / bi3.2) — the Stop hook
# blocks on the git half of its predicate while the persisted report still
# witnesses the PREVIOUS approval, so a bare `approve` no-ops and the block
# stands. Following the remediation the block PRINTS resolves it: step 2
# (impact-report.sh) re-persists the report, after which no record binds it and
# approve proceeds. That is why the source of the reference hash is named in the
# no-op's observations — the operator can see that regenerating the report is
# the move. Closing it inside approve would mean a second copy of the Stop
# hook's baseline-relative git walk, i.e. a second thing to drift; the one place
# that walk lives is verify-before-stop.sh's reviewable_changes().
# RETURNS BY GLOBAL, and prints nothing, deliberately: the caller needs the hash
# AND the name of the reference it came from, and `h=$(f)` runs f in a SUBSHELL
# where the second value dies silently — the envelope then reads "... via )".
# (That is not hypothetical: this function was written to print, section H's
# assertion on the source name caught it immediately.) Same reason
# verify-before-stop.sh hands APPROVAL_RECORD_DETAIL back through a global.
IDEM_REF_HASH=""
IDEM_REF_SOURCE=""
set_idempotency_reference() {
    local tid="$1"
    IDEM_REF_HASH=""
    if [ -s "$QA_TRACKING_DIR/changed-files.txt" ]; then
        IDEM_REF_SOURCE="live recompute of the tracked change set"
        IDEM_REF_HASH=$(compute_change_set_hash) || IDEM_REF_HASH=""
    else
        IDEM_REF_SOURCE="persisted impact report (tracker empty, as approve leaves it)"
        IDEM_REF_HASH=$(persisted_report_hash "$tid") || IDEM_REF_HASH=""
    fi
    return 0
}

# 3mg.2 (Phase V4 pt2): WHERE this approval was reviewed — the approving
# checkout's absolute git toplevel, recorded in the approval comment as a
# `worktree=<tok>` token.
#
# WHY: the change-set hash is PER-CHECKOUT (it hashes the checkout's own
# changed-files list), so an approval granted inside a linked worktree can
# never match the hash a Stop hook computes in the primary checkout. The Stop
# hook's WORKTREE-RESOLUTION block (verify-before-stop.sh) uses this token to
# find the approving worktree in O(1) instead of scanning, and to name it when
# it has since been deleted.
#
# GRAMMAR CONTRACT — one space-terminated token:
#   - spaces become %20 and tabs %09, so `worktree=` never splits into two
#     fields and the v3.5 readers (which stop at whitespace) stay correct;
#   - a literal `%` becomes %25 FIRST, so the encoding is unambiguous: without
#     it a real path containing "%20" would decode to a space and the reader
#     would look for a directory that never existed;
#   - a path containing a NEWLINE is unrepresentable in a line-oriented record,
#     so we record `none` rather than emit something the reader could misparse;
#   - non-git / unresolvable checkout -> `none`. The token is NEVER omitted:
#     a stable grammar is what lets the reader tell "no worktree recorded"
#     (pre-3mg.2 record) from "recorded as unresolvable".
# The decoder is verify-before-stop.sh's wtres_decode; keep the two in step.
approval_worktree_token() {
    local top
    command -v git >/dev/null 2>&1 || { printf 'none'; return 0; }
    top=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || top=""
    [ -n "$top" ] || { printf 'none'; return 0; }
    case "$top" in
        *$'\n'*) printf 'none'; return 0 ;;
    esac
    top="${top//%/%25}"
    top="${top// /%20}"
    top="${top//$'\t'/%09}"
    printf '%s' "$top"
}

# generate_impact_report <task-id> — best-effort invocation for enter.
# Sets IMPACT_REPORT_OBS (appended to enter's JSON observations) and
# returns 0/1. NEVER allowed to fail the enter flow: failures are logged
# loudly to sync-errors.log + a per-task stderr log, and the observation
# tells the operator approve will refuse until the artifact exists.
IMPACT_REPORT_OBS=""
generate_impact_report() {
    local tid="$1"
    IMPACT_REPORT_OBS=""
    local report stderr_log rc=0
    report=$(impact_report_path_for "$tid")
    stderr_log="${report%.json}.log"

    if [ ! -f "$IMPACT_REPORT_SCRIPT" ]; then
        log_sync_error "enter: impact-report.sh missing at $IMPACT_REPORT_SCRIPT for $tid; approve will refuse without the artifact"
        IMPACT_REPORT_OBS=" WARNING: impact-report.sh missing — approve will refuse until the artifact exists (regenerate manually or use approve --no-impact-report '<reason>')."
        return 1
    fi

    # Thread CLAUDE_PROJECT_DIR explicitly (same cwd-drift guard as
    # write_current_task). Progress/diagnostics land in the per-task log.
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$IMPACT_REPORT_SCRIPT" "$tid" >/dev/null 2>"$stderr_log" || rc=$?
    if [ "$rc" -eq 0 ] && [ -s "$report" ]; then
        local server_mode
        server_mode=$(jq -r '.server // "?"' "$report" 2>/dev/null || echo "?")
        IMPACT_REPORT_OBS=" Impact report generated (server=$server_mode): $report"
        return 0
    fi

    log_sync_error "enter: impact-report.sh failed for $tid (rc=$rc); tail: $(tail -2 "$stderr_log" 2>/dev/null | tr '\n' ' ' | head -c 200)"
    IMPACT_REPORT_OBS=" WARNING: impact-report.sh failed (rc=$rc, see $stderr_log and sync-errors.log) — approve will refuse until the artifact is regenerated (bash .claude/scripts/impact-report.sh $tid) or bypassed."
    return 1
}

emit_json() {
    # emit_json <ok 0|1> <subcommand> <task_id> <status> <observations>
    local ok="$1" sub="$2" tid="$3" st="$4" obs="$5"
    local ok_str="false"
    [ "$ok" = "1" ] && ok_str="true"
    # shellcheck disable=SC2016
    printf '{"ok":%s,"subcommand":%s,"task_id":%s,"status":%s,"observations":%s}\n' \
        "$ok_str" \
        "$(printf '%s' "$sub" | jq -Rs .)" \
        "$(printf '%s' "$tid" | jq -Rs .)" \
        "$(printf '%s' "$st" | jq -Rs .)" \
        "$(printf '%s' "$obs" | jq -Rs .)"
}

usage() {
    cat >&2 <<'USAGE'
Usage: qa-gate.sh <subcommand> <task-id> [args]
  enter   <task-id>
              Reconciles changed-files.txt against `git status` (94d), then
              generates the mechanical impact report
              (.claude/.qa-tracking/impact-report-<task-id>.json) via
              impact-report.sh — in that order, so the report's
              change_set_hash covers the whole git-visible delta. Both steps
              are tolerant: enter never fails because of either.
  status  <task-id>
  approve <task-id> [--expect-hash <hash>] [--accept-reconstructed '<reason>']
          [--no-impact-report '<reason>'] [--no-review '<reason>']
          <approval-summary>
              --expect-hash <hash> is the change set the CALLER classified.
              REFUSES (exit 2, error_key expected_hash_mismatch) when that is
              not the set this approval would bind, naming BOTH hashes so the
              operator can see which one is stale and how big the delta is
              (qzv). The F1 doc-only fast path passes the hash of the set it
              classified, so a source file arriving mid-Stop can no longer be
              approved under a doc-only verdict that never saw it. It proves
              bound == classified; it does NOT prove the set is COMPLETE (both
              sides read one canonicalisation of one tracker, so it detects
              drift and is blind to loss — fkm.1.20).
              REFUSES (exit 2, error_key change_set_reconstructed) when all
              three hold: changed-files.txt was absent-or-empty when the
              reconcile ran (so the set was REBUILT from `git status`), the
              rebuild produced a NON-EMPTY set, and it ALSO dropped
              git-visible path(s) as already-baselined — i.e. real work is
              being certified over a proven SUBSET of the working tree
              (94d.1). The dropped paths are named in the refusal and in
              .claude/.qa-tracking/reconcile-subtracted.txt. An EMPTY rebuilt
              set is NOT refused: that is the normal shape of a no-op approve
              in a dirty checkout and is indistinguishable from it.
              --accept-reconstructed '<reason>' bypasses it (the observation is
              inferential: a destroyed tracker and an all-Bash session in a
              repo that was dirty on arrival look identical to the reconcile,
              and a human reading the paths can tell them apart). The reason is
              recorded in the approval comment and the gate JSON.

              REFUSES (exit 2, structured error) when the impact report is
              missing or stale (change_set_hash != current changed-files
              list). Regenerate with:
                bash .claude/scripts/impact-report.sh <task-id>
              server:"absent" reports are accepted (documented degradation).
              --no-impact-report '<reason>' bypasses the refusal; the reason
              is recorded in the approval comment and the gate JSON.

              ALSO REFUSES (exit 4) when independent review is not satisfied,
              as decided by the ONE predicate `review-check.sh gate <task-id>`:
                review_artifact_missing   no REVIEW-ARTIFACT v1 record — an
                                          independent reviewer must review and
                                          `qa-gate.sh review-record` it
                reviewer_not_independent  the reviewer is also a recorded
                                          IMPLEMENTER of this task
                unresolved_findings       finding(s) at/above the artifact's
                                          risk_threshold are still open —
                                          `resolve-finding` (with fix+test) or
                                          `arbitrate <id> overrule` each one
                review_check_unavailable  the predicate could not run — this
                                          FAILS CLOSED on purpose
              --no-review '<reason>' bypasses it; the reason lands in the
              approval comment as `[review bypass: <reason>]` (which the Stop
              hook's review-discipline check honours) and in the gate JSON.

              The approval comment records the reviewer AND the approving
              checkout (3mg.2 — `worktree=` is the %20-encoded git toplevel,
              or `none`; the Stop hook resolves cross-worktree approvals
              through it):
                QA-GATE APPROVED change_set_hash=<h> reviewed_by=<id>
                worktree=<tok> at <ts>: <summary>
                [ [impact-report bypass: ...]][ [review bypass: ...]]
                [ [reconstructed change set accepted: ...]]
  block   <task-id> <reason>
  baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]
              Write .claude/.qa-tracking/gate-baseline — the snapshot of
              `git status --porcelain` that verify-before-stop.sh subtracts
              so the Stop gate evaluates this session's DELTA rather than a
              working tree that was already dirty on arrival. No task id, no
              bd, no labels. session-start.sh calls this (--by session-start)
              when no review cycle is active; `enter` and `approve` write it
              themselves.
  reconcile-tracker
              Append every git-visible changed path that changed-files.txt is
              missing (94d). post-edit.sh only sees Write/Edit/MultiEdit/
              NotebookEdit, so a file written by a Bash redirect, `cp`, `sed
              -i` or a generator script never entered the tracker — and the
              tracker is what change_set_hash() hashes, so the gate could name
              N paths and release on an approval binding fewer. Non-git tree:
              no-op. Emits absolute paths; subtracts the gate baseline and the
              shared denylist; never removes anything. Exit 2 when the
              reconcile cannot be completed (git unreadable), which every
              caller treats as refuse-to-proceed. No task id, no bd, no
              labels.
  choose  <approve|continue|tech-debt|defer> <task-id> <note> [tech-debt: severity file:line effort]
              Record a J21 decision while qa-escalated. The note is the
              human-readable rationale; for `tech-debt` the note becomes
              the description and the optional trailing args are passed
              through to .claude/scripts/tech-debt.sh add.
              Effects:
                approve    -> delegates to `approve` (same atomic flow, so it
                              inherits BOTH refusals: a J21 decision does not
                              exempt the task from a fresh impact report or
                              from independent review)
                continue   -> clears qa-escalated + resets iteration counter
                tech-debt  -> tech-debt.sh add --bd-task + clears escalation
                defer      -> sets qa-deferred (allows Stop next time)
  grade-record <task-id> [--file <path>] [--graded-hash <h>]
              Spec Phase A: record a grader verdict. Reads a strict-JSON
              verdict from --file <path> or, if omitted, stdin. Required
              JSON keys:
                verdict          "satisfied" | "needs_revision"
                criterion_results array of {criterion, pass, justification}
                required_fixes   array
                iteration        non-negative integer
                rubric_version   string matching ^[A-Za-z0-9._+-]+$
              --graded-hash <h> names the change set the GRADER SAW — the
              change_set_hash from the grading packet's impact report. The
              relay passes it (orchestrator.md 5a step C). Without it the
              record binds the live change set only when the persisted
              impact report still corroborates it; if they disagree the
              verdict is recorded UNBOUND rather than bound to work that
              was never graded.
              Effects:
                - appends a Beads comment
                  `RUBRIC <rubric_version> iteration <n>: <verdict>
                   change_set_hash=<h> — <summary>`
                  (the hash names the change set that was graded; omitted
                  when it cannot be computed. `enter` reads it back to decide
                  whether a satisfied verdict still covers the current work.)
                - on satisfied: removes rubric-pending, adds rubric-satisfied
                - on needs_revision: labels unchanged (qa-blocked round-trip
                  is the QA agent's move, not this script's)
              Malformed input exits non-zero with a structured JSON error
              naming the offending key.
  review-record <task-id> [--file <path>]
              Phase V2: record a reviewer artifact. Validates the artifact
              JSON via review-check.sh (the ONE validator) then appends the
              load-bearing comment:
                REVIEW-ARTIFACT v1 iteration=<n> reviewer=<id> model=<m>
                reviewed_hash=<h> risk_threshold=<sev> verdict=<v>
                stopped_by=<s> findings=[<id>:<sev>,...] at <ts>: <summary>
              (empty findings render as findings=[]). Record writer only —
              no approve/Stop enforcement.
  resolve-finding <tid> <finding-id> --fix '<ref>' --test '<ref>' '<summary>'
              Phase V2: mark a review finding resolved. The id must appear in
              the latest REVIEW-ARTIFACT comment; empty --fix/--test exit 1.
              Appends: RESOLVED <id> at <ts>: fix=<ref> test=<ref> — <summary>
  arbitrate <tid> <finding-id> <overrule|sustain> '<rationale>'
              Phase V2: record an arbitration decision on a review finding.
              The id must appear in the latest REVIEW-ARTIFACT comment; empty
              rationale exits 1. Appends:
                ARBITRATION <id> decision=<d> at <ts>: <rationale>
USAGE
}

# emit_error_json: structured error envelope for the grade-record subcommand.
# Mirrors emit_json's shape but adds `error_key` and `usage` fields so the
# QA agent can re-prompt the grader with precision. Emitted to stdout.
emit_error_json() {
    # emit_error_json <subcommand> <task_id> <error_key> <observations> <usage_line>
    local sub="$1" tid="$2" ekey="$3" obs="$4" usage_line="$5"
    # shellcheck disable=SC2016
    printf '{"ok":false,"subcommand":%s,"task_id":%s,"status":"error","error_key":%s,"observations":%s,"usage":%s}\n' \
        "$(printf '%s' "$sub" | jq -Rs .)" \
        "$(printf '%s' "$tid" | jq -Rs .)" \
        "$(printf '%s' "$ekey" | jq -Rs .)" \
        "$(printf '%s' "$obs" | jq -Rs .)" \
        "$(printf '%s' "$usage_line" | jq -Rs .)"
}

require_bd() {
    if ! command -v bd >/dev/null 2>&1; then
        emit_json 0 "$1" "${2:-}" "error" "bd CLI not on PATH"
        exit 2
    fi
    if [ ! -d "$PROJECT_DIR/.beads" ]; then
        emit_json 0 "$1" "${2:-}" "error" "Beads not initialized in project ($PROJECT_DIR/.beads missing)"
        exit 2
    fi
}

# Read labels for a task as a comma-joined string (empty on miss).
# `bd show <id> --json` returns either an object or a 1-element array
# depending on the bd version, so we handle both shapes.
get_labels() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null \
        || echo ""
}

has_label() {
    # has_label <task-id> <label>
    local labels
    labels="$(get_labels "$1")"
    echo ",$labels," | grep -q ",$2,"
}

add_label() {
    # add_label <task-id> <label> -> 0 on success
    bd label add "$1" "$2" >/dev/null 2>&1
}

remove_label() {
    # remove_label <task-id> <label> -> 0 only when the label is ABSENT afterwards.
    #
    # l1r.3. This was a bare `bd label remove "$1" "$2" >/dev/null 2>&1` whose exit
    # status was the only evidence any caller had that a label went away, and that
    # evidence is worth nothing. MEASURED against bd 1.1.2, the version this repo
    # runs:
    #   - `bd label remove <tid> <label-the-task-never-had>` prints
    #     "Removed label ..." and exits 0;
    #   - `bd label remove <nonexistent-task-id> <label>` prints
    #     "Error resolving <id>: no issue found matching ..." and ALSO exits 0.
    # So the status could not distinguish "removed" from "did nothing at all", and
    # every rollback block in this file that branches on it was decorative.
    #
    # NOW: run the removal, then read the task back. The contract is a
    # POSTCONDITION — "this label is not on this task" — not "a removal was
    # applied". The difference is load-bearing in both directions:
    #   - removing an ABSENT label still succeeds, which is exactly what
    #     remove_escalation_labels and the two remove_rubric_* helpers rely on:
    #     they fire unconditionally on labels that are usually not there.
    #   - a task that cannot be READ reports its label set as empty (get_labels
    #     swallows the error and returns ""), so the postcondition holds vacuously
    #     and this returns 0. That is the honest limit of the check: it proves the
    #     label is gone, it cannot tell "gone" from "unreadable", and callers that
    #     need the task to exist establish that separately (require_bd, plus the
    #     has_label captures at the top of cmd_approve).
    #
    # SCOPE, against l1r.3's own reproduction rather than against its title. That
    # reproduction is a stale-JSONL auto-import RESURRECTING an already-removed
    # label, and its item 2 records that `bd show` immediately after the removal
    # agreed the label was gone — i.e. a read-back at this point would have passed,
    # and the label returned on a later read. One read-back cannot observe a future
    # import, so this closes the removal that never landed, not the removal that is
    # undone afterwards. The second half is a bd-level divergence between
    # beads.db-wal and issues.jsonl and has no fix inside this function.
    bd label remove "$1" "$2" >/dev/null 2>&1 || true
    ! has_label "$1" "$2"
}

add_comment() {
    # Newer Beads: `bd comments add` (plural). Older: `bd comment add`.
    # Try plural first, fall back if needed. Comments are non-authoritative
    # (labels are the source of truth) but failures are still logged to
    # sync-errors.log so SessionStart can surface them.
    bd comments add "$1" "$2" >/dev/null 2>&1 \
        || bd comment add "$1" "$2" >/dev/null 2>&1 \
        || log_sync_error "bd comments add failed for $1 (msg=$(printf '%s' "$2" | head -c 60))"
}

# ---------------------------------------------------------------------------
# Subcommands

cmd_enter() {
    local tid="$1"
    [ -z "$tid" ] && { usage; exit 1; }
    require_bd "enter" "$tid"

    # Spec 0.2: a fresh enter is the "resumes normal gating" signal for a
    # deferred task. Clearing the escalation labels + cached state on every
    # enter (idempotent path included) means a re-entered task starts a
    # clean review cycle. Doing this before the idempotent short-circuit
    # below also handles the case where the operator re-enters an
    # already-entered task that happens to carry qa-escalated/qa-deferred.
    local was_escalated=0 was_deferred=0
    has_label "$tid" "qa-escalated" && was_escalated=1
    has_label "$tid" "qa-deferred" && was_deferred=1
    if [ "$was_escalated" = "1" ] || [ "$was_deferred" = "1" ]; then
        remove_escalation_labels "$tid"
    fi
    # Spec 0.2: also wipe the per-iteration cache + counter so the next
    # Stop runs the full suite from scratch (resumes normal gating).
    wipe_iteration_state "$tid"

    # Spec Phase A + bjx (v4.1 U1): what an enter does to a rubric verdict
    # already on the task, and why that is now a decision rather than a wipe.
    #
    # WAS: clear rubric-satisfied unconditionally, re-arm rubric-pending. That
    # is right for the case it was written for — a satisfied verdict from a
    # PREVIOUS change set must never carry into a new review cycle — and wrong
    # for the ordering the relay actually walks. `grade-record` runs in the
    # ORCHESTRATOR's turn (RUBRIC-RELAY step C) and QA acts on the verdict in a
    # LATER spawn (step D); any Stop in between blocks and PRINTS
    # `qa-gate.sh enter <id>` — the QA-required block's "when entering review,
    # mark the gate" line, and the LABEL_WITHOUT_RECORD remediation, both in
    # verify-before-stop.sh. Following the gate's own printed instruction then
    # destroyed a verdict recorded seconds earlier against the IDENTICAL change
    # set, and the approve that followed warned "no satisfied verdict on file"
    # — false, and the thing qa.md 6f answers with a written OVERRIDE reason.
    # The gate was manufacturing overrides against its own audit trail, and
    # driving re-grades (a paid grader spawn) of an already-graded diff.
    #
    # That reachability is MECHANICAL, which is why the fix is here and not in
    # the relay's prompt text: the `enter` in that position is emitted by a
    # hook, so no ordering rule written into orchestrator.md or qa.md can be
    # relied on to avoid it.
    #
    # NOW: the clear is conditional on two independent tests, both conservative,
    # and it still fires whenever either is unmet.
    #
    #   1. THE CYCLE MUST ALREADY BE OPEN (qa-gate-entered set). A fresh enter
    #      opens a NEW review cycle and always clears — byte-identical to the
    #      old behaviour, and precisely the case the unconditional clear
    #      existed for. `approve` deliberately leaves rubric-satisfied behind
    #      as the audit trail of what backed it, so "a label survived an
    #      approve" is the normal input to this branch, not an anomaly.
    #   2. THE VERDICT MUST BIND THE CURRENT CHANGE SET. The latest RUBRIC
    #      record must be a `satisfied` one carrying a change_set_hash equal to
    #      the hash right now. A verdict recorded before the specialist touched
    #      three more files does not cover them and still clears.
    #
    # Test 2 needs positive evidence to preserve, so every way of failing to
    # produce it degrades to the pre-bjx behaviour: a pre-bjx RUBRIC comment
    # carries no token, a verdict superseded by a later needs_revision does not
    # answer, a version outside the validated class does not parse, and an
    # unavailable hash — in EITHER of its two spellings, empty or the
    # $CHANGE_SET_HASH_UNAVAILABLE sentinel — is refused. In all of them the
    # label is cleared, which is what the gate did before.
    #
    # THE SENTINEL IS CHECKED HERE, not only in the reader, because this is
    # where its shape actually bites: it is a CONSTANT, so on a host with
    # neither shasum nor sha256sum both sides of the comparison below would be
    # that same constant and the guard would match unconditionally — preserving
    # every verdict on the one class of machine where the hash means nothing.
    # The reader refuses it too (a legacy record may already carry it); the two
    # checks are not redundant, they cover a written record and a live recompute.
    #
    # KNOWN LIMIT, inherited and deliberately not narrowed here: the canonical
    # change-set hash is over the changed-file LIST, not file contents (see
    # impact-report.sh). Rewriting an ALREADY-TRACKED file after grading does
    # not move it, so a verdict can be preserved across content the grader never
    # saw. That is the single canonicalisation shared with the qa-approved
    # record (llh.18) and reviewed_hash (jio.1); computing a content hash here
    # would be a fourth definition of "the change set", which is exactly what
    # llh.18 exists to forbid. Pinned as documented behaviour by section B3 of
    # .claude/tests/component/specs/rubric-binding.sh rather than left latent.
    #
    # The live recompute is deliberate, rather than set_idempotency_reference's
    # tracker-or-persisted-report split: `enter` opens a cycle over the change
    # set that exists NOW, and the persisted report is a statement about when
    # the report was last written, not about when the verdict was graded — a
    # report refreshed after grading would vouch for a diff nobody graded.
    local was_rubric_satisfied=0 already_entered=0
    local rubric_preserved=0 rubric_verdict_obs=""
    has_label "$tid" "rubric-satisfied" && was_rubric_satisfied=1
    has_label "$tid" "qa-gate-entered" && already_entered=1
    if [ "$was_rubric_satisfied" = "1" ]; then
        if [ "$already_entered" = "1" ]; then
            local graded_hash="" current_hash=""
            graded_hash=$(latest_satisfied_rubric_hash "$tid") || graded_hash=""
            current_hash=$(compute_change_set_hash) || current_hash=""
            if [ "$current_hash" = "$CHANGE_SET_HASH_UNAVAILABLE" ]; then
                current_hash=""
            fi
            if [ -n "$current_hash" ] && [ "$graded_hash" = "$current_hash" ]; then
                rubric_preserved=1
                rubric_verdict_obs="; kept rubric-satisfied — the recorded verdict binds this exact change set (change_set_hash=$current_hash), so this re-entry resumes the open cycle rather than re-opening the rubric loop"
            else
                rubric_verdict_obs="; cleared stale rubric-satisfied (graded change set ${graded_hash:-<unbound>} does not match the current one ${current_hash:-<unavailable>})"
            fi
        else
            rubric_verdict_obs="; cleared stale rubric-satisfied (a fresh gate cycle re-opens the rubric loop)"
        fi
        if [ "$rubric_preserved" = "0" ]; then
            remove_rubric_satisfied "$tid"
        fi
    fi

    # jue: an enter does not leave a PRIOR CYCLE's qa-approved behind, in EITHER
    # arm. Decided here, above the early-return, for the same reason the rubric
    # decision is: both arms need an answer and only one of them reaches the code
    # below.
    #
    # THE FRESH ARM (no qa-gate-entered yet). Same reasoning as the legacy
    # approved-baseline removal further down this function — a new gate cycle
    # invalidates the previous cycle's credentials — and note that bjx's
    # conditional preservation of rubric-satisfied does NOT apply here: that
    # condition lives in the already-entered arm, and the fresh arm clears
    # rubric-satisfied unconditionally too, because a fresh cycle re-opens the
    # loop. jue was filed for two symptoms: approve short-circuiting as a no-op so
    # no fresh bound record was ever written (since narrowed by gz3's hash-aware
    # idempotency, which no longer no-ops when the change set has moved), and a
    # watcher polling the LABEL reading a prior-cycle approval as a verdict on new
    # commits. The second symptom is untouched by gz3 and is what this closes: the
    # label goes away when the cycle it belonged to ends.
    #
    # THE EARLY-RETURN ARM (qa-gate-entered already set). It clears too, and the
    # argument is different: {qa-gate-entered, qa-approved} is not reachable
    # through this script's own transitions, because approve removes
    # qa-gate-entered as part of the same sweep that adds qa-approved. So a task in
    # this arm holding qa-approved did not get it from a clean approve of the open
    # cycle. The two ways it arrives are label inheritance (bd 1.1.2's
    # `create --parent` copies gate labels from the parent, transitively — see rmz)
    # and a partially applied transition. Both are states where the label is not a
    # verdict on anything, and leaving it would hand a release credential to a task
    # whose review cycle is open.
    #
    # THIS ARM ALSO WRITES NO CYCLE RECORD, which is a separate open defect and NOT
    # fixed here: a task born with qa-gate-entered can be entered, take this arm,
    # and still have zero `QA-GATE: entered` records. Do not read a qa-gate-entered
    # label as evidence that this function ever ran on the task.
    local had_prior_approval=0 approval_clear_obs=""
    has_label "$tid" "qa-approved" && had_prior_approval=1
    if [ "$had_prior_approval" = "1" ]; then
        local approval_clear_why=""
        if [ "$already_entered" = "1" ]; then
            approval_clear_why="the label cannot be a verdict on an OPEN cycle — approve clears qa-gate-entered when it sets qa-approved, so this pair is unreachable through the gate's own transitions (inherited from a parent, or a partially applied transition)"
        else
            approval_clear_why="a fresh gate cycle supersedes the previous cycle's approval, the same way it invalidates that approval's legacy baseline"
        fi
        if remove_label "$tid" "qa-approved"; then
            approval_clear_obs="; cleared a prior cycle's qa-approved ($approval_clear_why) — re-approve to record a verdict on this cycle"
        else
            approval_clear_obs="; WARNING a prior cycle's qa-approved is set and could NOT be cleared ($approval_clear_why); a label-polling reader will still see it as an approval of the current change set"
            log_sync_error "enter: failed to clear a prior cycle's qa-approved on $tid; the label survives an enter and any label-polling reader will treat it as a verdict on the new cycle"
        fi
    fi

    if [ "$already_entered" = "1" ]; then
        # Idempotent re-enter: the label is already there, but we still
        # refresh current-task in case it drifted (e.g., a different task
        # claimed it earlier in this session).
        #
        # rubric-pending is re-armed unless the verdict above was PRESERVED:
        # an already-entered task that lost rubric-pending (e.g. via a stale
        # grade-record from a prior cycle) belongs back in the awaiting-verdict
        # state, but a task whose satisfied verdict still binds the current
        # change set is not awaiting anything — re-arming there would put both
        # rubric labels on one task and tell cmd_status's reader that a graded
        # cycle is still pending.
        local rubric_refresh_obs=""
        if [ "$rubric_preserved" = "1" ]; then
            rubric_refresh_obs="rubric-satisfied kept (no new grading round needed)"
        else
            add_label "$tid" "rubric-pending" || true
            rubric_refresh_obs="rubric-pending refreshed"
        fi
        local refreshed_obs="qa-gate-entered already set; current-task refreshed; $rubric_refresh_obs"
        if ! write_current_task "$tid"; then
            refreshed_obs="qa-gate-entered already set; WARNING current-task write failed (see sync-errors.log); $rubric_refresh_obs"
        fi
        if [ "$was_escalated" = "1" ] || [ "$was_deferred" = "1" ]; then
            refreshed_obs="$refreshed_obs; cleared prior escalation labels (escalated=$was_escalated deferred=$was_deferred) and reset iteration state"
        fi
        refreshed_obs="$refreshed_obs$rubric_verdict_obs$approval_clear_obs"
        # TRACKER-RECONCILE BEGIN (94d)
        # Before the report is generated, not after: the report records the
        # change_set_hash of the tracker AS IT IS when it runs, and approve
        # refuses on any later drift. Reconciling first is what makes the
        # artifact cover the whole git-visible delta rather than the subset the
        # Write/Edit hook saw. Tolerant here for the same reason the report
        # itself is (enter is documented tolerant, qa-gate.sh:1102-1106 class);
        # approve is where an unreconcilable tracker REFUSES.
        reconcile_tracker || true
        refreshed_obs="$refreshed_obs; $RECONCILE_OBS"
        # TRACKER-RECONCILE END (94d)
        # G2.n6d: refresh the mechanical impact report on re-enter too —
        # a resumed cycle reviews the CURRENT change set, so the artifact
        # must reflect it. Tolerant: enter never fails because of this.
        generate_impact_report "$tid" || true
        refreshed_obs="$refreshed_obs;$IMPACT_REPORT_OBS"
        emit_json 1 "enter" "$tid" "entered" "$refreshed_obs"
        return 0
    fi

    if ! add_label "$tid" "qa-gate-entered"; then
        emit_json 0 "enter" "$tid" "error" "failed to add qa-gate-entered label"
        exit 2
    fi

    # Spec Phase A: arm the rubric loop. Best-effort — a failed add is
    # logged but does not roll back the gate (the rubric workflow is an
    # input to QA, not a gate).
    if ! add_label "$tid" "rubric-pending"; then
        log_sync_error "enter: failed to add rubric-pending label on $tid"
    fi

    # 0wk.2 fix: a new gate cycle invalidates the previous approval's LEGACY
    # baseline. Without this, an approve from cycle N would leave its baseline
    # behind so verify-before-stop in cycle N+1 (post re-enter) would treat
    # ALL N+1 edits as already-approved.
    rm -f "$LEGACY_APPROVED_BASELINE" 2>/dev/null || true

    # gate-baseline v2 (3mg.1): WRITE-IF-MISSING, minus already-tracked files.
    #
    # Not an unconditional refresh, and not a delete either:
    #   - refresh would baseline the whole dirty tree at the moment a review
    #     cycle opens, i.e. hand this cycle's own work a free pass;
    #   - delete would leave the cycle with no reference point at all, so a
    #     repo that was merely dirty on arrival re-blocks every Stop (the
    #     0wk.2 symptom, and transcript scenario 1).
    # Write-if-missing gives a cycle started in a fresh session the
    # session-start baseline, and a cycle started in a session that never had
    # one a baseline captured now — with the session's ALREADY-tracked edits
    # excluded so they stay gated. Best-effort: enter never fails on it.
    if ! write_gate_baseline "qa-gate-enter" --if-missing --exclude-tracked; then
        log_sync_error "enter: gate-baseline capture failed for $tid (gate still correct; the Stop fallback treats all git dirt as new)"
    fi

    # F3: persist active task as side effect so hooks can find it. Failures
    # are logged to sync-errors.log AND surfaced in the JSON observation
    # (previously silently swallowed by `|| true`).
    local persist_warn=""
    if ! write_current_task "$tid"; then
        persist_warn=" WARNING: current-task helper write failed (see sync-errors.log); hooks will see no active task."
    fi

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    add_comment "$tid" "QA-GATE: entered at $ts"

    # TRACKER-RECONCILE BEGIN (94d)
    # Fold every git-visible path the Write/Edit hook never saw into the tracker
    # BEFORE the impact report binds a change_set_hash to it.
    #
    # AFTER write_gate_baseline above, and the order is not arbitrary. The
    # reconciler subtracts the baseline, so with one in place a cycle opening in
    # a dirty tree reconciles only this session's delta. Reversing the two would
    # be worse, not better: with no baseline yet, the reconciler would append the
    # ENTIRE dirty tree — someone else's half-finished refactor included — into
    # this task's change set and its approval binding, which is the 0wk.2 symptom
    # the baseline exists to prevent.
    #
    # RESIDUAL, inherited and unresolvable here: when NO baseline exists at this
    # point, write_gate_baseline --exclude-tracked can only exclude what the
    # TRACKER knows, so a Bash-written file gets baselined as "pre-existing" and
    # the reconcile below then finds nothing new. Reaching that state needs a
    # session with no session-start baseline AND no prior enter (session-start
    # skips the capture while a cycle is active, and enter/approve both write
    # one), so it is rare — but it is real, and it cannot be fixed by reordering:
    # without a baseline there is no signal that separates "dirty because this
    # session wrote it" from "dirty on arrival". The fix would be a session-start
    # capture that runs even mid-cycle, which is claude-workflow-plugin-fkm.1.2's
    # half (a), not this one's.
    #
    # Tolerant (enter is documented tolerant); approve is where this refuses.
    reconcile_tracker || true
    # TRACKER-RECONCILE END (94d)

    # G2.n6d: generate the mechanical impact report as part of packet
    # assembly. Tolerant by contract — a failed generation degrades to a
    # WARNING in the observations + sync-errors.log; enter still succeeds.
    # (approve is where the artifact is ENFORCED.)
    generate_impact_report "$tid" || true

    local extra_obs=""
    if [ "$was_escalated" = "1" ] || [ "$was_deferred" = "1" ]; then
        extra_obs=" cleared prior escalation labels (escalated=$was_escalated deferred=$was_deferred) and reset iteration state."
    fi
    # bjx: reaching here means already_entered was 0, so the rubric decision
    # above can only have been the fresh-cycle clear — preservation is
    # unreachable on this path by construction, and the observation says which
    # of the two clears fired rather than just that one did.
    extra_obs="$extra_obs$rubric_verdict_obs$approval_clear_obs"
    # TRACKER-RECONCILE BEGIN (94d)
    extra_obs="$extra_obs; $RECONCILE_OBS"
    # TRACKER-RECONCILE END (94d)
    emit_json 1 "enter" "$tid" "entered" "qa-gate-entered + rubric-pending labels set at $ts; current-task persisted.$persist_warn$extra_obs$IMPACT_REPORT_OBS"
}

cmd_status() {
    local tid="$1"
    [ -z "$tid" ] && { usage; exit 1; }
    require_bd "status" "$tid"

    # Spec Phase A: surface rubric state alongside the qa state. Precedence
    # matches the label semantics: satisfied > pending > none. The rubric
    # state is informational — it does NOT change the qa-state precedence
    # below (principle 6: qa-approved is the only Stop-hook signal).
    local rubric_state="none"
    local rubric_obs="no rubric labels present"
    if has_label "$tid" "rubric-satisfied"; then
        rubric_state="satisfied"
        rubric_obs="rubric-satisfied label present"
    elif has_label "$tid" "rubric-pending"; then
        rubric_state="pending"
        rubric_obs="rubric-pending label present"
    fi

    # Precedence: approved > blocked > entered > not-entered.
    if has_label "$tid" "qa-approved"; then
        emit_json 1 "status" "$tid" "approved" "qa-approved label present; rubric=$rubric_state ($rubric_obs)"
        return 0
    fi
    if has_label "$tid" "qa-blocked"; then
        emit_json 1 "status" "$tid" "blocked" "qa-blocked label present; rubric=$rubric_state ($rubric_obs)"
        return 0
    fi
    if has_label "$tid" "qa-gate-entered"; then
        emit_json 1 "status" "$tid" "entered" "qa-gate-entered label present, awaiting approve/block; rubric=$rubric_state ($rubric_obs)"
        return 0
    fi
    emit_json 1 "status" "$tid" "not-entered" "no qa lifecycle labels present; rubric=$rubric_state ($rubric_obs)"
}

cmd_approve() {
    local tid="${1:-}"
    shift || true

    # G2.n6d: parse the documented impact-report bypass. The flag may
    # appear anywhere after the task id; every other argument joins the
    # approval summary (preserving the historical `summary="$*"` shape
    # for multi-word callers).
    local bypass_impact=0
    local bypass_reason=""
    local bypass_review=0
    local review_bypass_reason=""
    local summary=""
    # CHANGE-SET-RECONSTRUCTED BEGIN (94d.1)
    local bypass_reconstructed=0
    local reconstructed_bypass_reason=""
    # CHANGE-SET-RECONSTRUCTED END (94d.1)
    # EXPECTED-HASH-REFUSAL BEGIN (qzv)
    local expect_hash_arg=""
    # EXPECTED-HASH-REFUSAL END (qzv)
    while [ $# -gt 0 ]; do
        case "$1" in
            # EXPECTED-HASH-REFUSAL BEGIN (qzv)
            --expect-hash)
                # qzv: the change set the CALLER classified, so approve can refuse
                # to bind a different one. Mirrors grade-record's --graded-hash
                # argument handling exactly; see the refusal block below for what
                # it does and why it sits where it does.
                expect_hash_arg="${2:-}"
                if [ -z "$expect_hash_arg" ]; then
                    emit_error_json "approve" "$tid" "missing_expected_hash" \
                        "--expect-hash requires a value (the change_set_hash of the set the caller classified; impact-report.sh --hash-only prints it)" \
                        "qa-gate.sh approve $tid --expect-hash <hash> '<summary>'"
                    exit 1
                fi
                # Validated for a DIFFERENT reason than --graded-hash's identical
                # check, and the difference is worth stating: this value is only
                # ever COMPARED, never written into a record's machine prefix, so
                # a stray character cannot relocate a field boundary. The check is
                # here so a caller who passed a shell-mangled or multi-word value
                # gets a usage error NAMING THE FLAG rather than an
                # `expected_hash_mismatch` that reads like a real drift detection
                # — a wrong answer that looks like the right one is the more
                # expensive failure.
                case "$expect_hash_arg" in
                    *[!A-Za-z0-9-]*)
                        emit_error_json "approve" "$tid" "expected_hash_invalid_chars" \
                            "--expect-hash='$expect_hash_arg' contains characters outside [A-Za-z0-9-], so it cannot be a canonical change-set hash; this is a usage error, NOT a change-set mismatch" \
                            "pass the value impact-report.sh --hash-only printed for the set you classified"
                        exit 1
                        ;;
                esac
                shift 2 || true
                ;;
            # EXPECTED-HASH-REFUSAL END (qzv)
            # CHANGE-SET-RECONSTRUCTED BEGIN (94d.1)
            --accept-reconstructed)
                # 94d.1: the audited bypass for the change_set_reconstructed
                # refusal below. Mirrors --no-impact-report / --no-review,
                # including the empty-reason refusal.
                #
                # This one HAS a bypass where tracker_unreconcilable deliberately
                # does not, and the difference is what the two predicates can
                # PROVE. "git status failed" is mechanical: the change set is
                # genuinely unknowable and no operator judgement can supply it.
                # "the tracker was empty and N paths were subtracted as
                # already-baselined" is INFERENTIAL: the same observation is
                # produced by a destroyed tracker and by a session whose work was
                # entirely Bash-mediated in a repo that was dirty on arrival.
                # reconcile cannot tell those apart (see its header) — a human
                # looking at the named paths can. Refusing with no exit would
                # deadlock the second case with nothing to fix.
                bypass_reconstructed=1
                reconstructed_bypass_reason="${2:-}"
                if [ -z "$reconstructed_bypass_reason" ]; then
                    emit_error_json "approve" "$tid" "bypass_reason_required" \
                        "--accept-reconstructed requires a non-empty reason; the bypass is recorded in the approval comment + gate JSON, and an unexplained bypass of the change-set completeness check is indistinguishable from approving a change set nobody established" \
                        "qa-gate.sh approve $tid --accept-reconstructed '<reason>' '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            # CHANGE-SET-RECONSTRUCTED END (94d.1)
            --no-impact-report)
                bypass_impact=1
                bypass_reason="${2:-}"
                if [ -z "$bypass_reason" ]; then
                    emit_error_json "approve" "$tid" "bypass_reason_required" \
                        "--no-impact-report requires a non-empty reason; the bypass is recorded in the audit trail and an unexplained bypass is indistinguishable from gate evasion" \
                        "qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            --no-review)
                # V3 (jio.1): the audited review-separation bypass. Mirrors
                # --no-impact-report exactly, including the empty-reason
                # refusal: a bypass with no recorded reason is
                # indistinguishable from gate evasion.
                bypass_review=1
                review_bypass_reason="${2:-}"
                if [ -z "$review_bypass_reason" ]; then
                    emit_error_json "approve" "$tid" "bypass_reason_required" \
                        "--no-review requires a non-empty reason; the bypass is recorded in the approval comment + gate JSON, and an unexplained bypass of the independent-review requirement is indistinguishable from signing off on your own work" \
                        "qa-gate.sh approve $tid --no-review '<reason>' '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            *)
                if [ -z "$summary" ]; then
                    summary="$1"
                else
                    summary="$summary $1"
                fi
                shift || true
                ;;
        esac
    done

    if [ -z "$tid" ] || [ -z "$summary" ]; then
        usage
        exit 1
    fi
    require_bd "approve" "$tid"

    # Capture rollback state up front.
    #
    # 8zi: qa-gate-entered and qa-pending are no longer captured here. They were
    # read only to decide whether to attempt a removal and to set the two envelope
    # counters, and set_terminal_label now does both from the state at sweep time —
    # which is after the reconcile, both refusals and the record write. Keeping a
    # copy taken earlier would be a second source of truth for the same question,
    # and the later one is the one that describes what the sweep did.
    local had_approved=0
    has_label "$tid" "qa-approved" && had_approved=1

    # Spec Phase A: snapshot rubric state for the warning + audit message.
    # NOTE per principle 6: approve does NOT hard-gate on rubric-satisfied.
    # The Stop-hook contract is touched only by qa-approved / qa-deferred;
    # the rubric is a QA input. The warning here surfaces the state so the
    # QA agent's prompt (A.2) can enforce the override-reason rule, and so
    # an audit reader can see whether approve happened with or without a
    # passing rubric verdict.
    local had_rubric_pending=0 had_rubric_satisfied=0
    has_label "$tid" "rubric-pending" && had_rubric_pending=1
    has_label "$tid" "rubric-satisfied" && had_rubric_satisfied=1

    # IDEMPOTENCY (gz3 / v4.1 U1) — HASH-AWARE, not label-aware.
    #
    # WAS: `had_approved = 1 -> no-op`. That made the LABEL mean "already
    # approved", which is exactly what llh.18 stopped believing on the Stop
    # side: release requires a RECORD bound to the current change set, because
    # the label is forgeable and says nothing about WHICH files were reviewed.
    # The two halves disagreeing produced a deadlock. A Stop blocked with
    # LABEL_WITHOUT_RECORD prints `enter -> impact-report -> approve`; `enter`
    # does not clear qa-approved; approve then short-circuited — so following
    # the printed remediation wrote no new record and the gate re-blocked
    # forever. The only working recovery was an undocumented
    # `bd label remove <tid> qa-approved` first.
    #
    # NOW: the no-op fires only when an existing record already binds the change
    # set this approve would bind (see set_idempotency_reference for which hash
    # that is, and why an empty tracker reads the persisted report instead of
    # recomputing). Otherwise approve PROCEEDS and re-verifies every
    # precondition — impact-report freshness, independent review, rubric state —
    # before writing a FRESH bound record. Nothing is waved through: a stale
    # label buys no exemption from the checks, it just stops being a dead end.
    #
    # The advertised contract ("re-approving an already-approved task is a
    # success no-op") is preserved for the case it was written for and dropped
    # exactly where it was wrong. Pinned in
    # .claude/tests/component/specs/approve-idempotency.sh (with a META that
    # reverts this guard to had_approved-only and shows the deadlock return).
    #
    # Both envelopes NAME THE REFERENCE they compared against
    # ($IDEM_REF_SOURCE). That is the diagnostic for the residual documented on
    # set_idempotency_reference: an operator staring at a gate that still
    # blocks after a no-op can see that approve matched the PERSISTED report and
    # that regenerating it (step 2 of the printed remediation) is the move.
    local stale_label_obs=""
    if [ "$had_approved" = "1" ]; then
        local idem_ref=""
        set_idempotency_reference "$tid"
        idem_ref="$IDEM_REF_HASH"
        if [ -n "$idem_ref" ] && task_has_approval_record_for "$tid" "$idem_ref"; then
            emit_json 1 "approve" "$tid" "approved" "qa-approved already set and an approval record already binds this change set (change_set_hash=$idem_ref via $IDEM_REF_SOURCE); idempotent no-op — nothing rewritten. If a Stop is still blocking, the change set has moved since that record: re-run impact-report.sh (step 2 of the block's remediation) and approve again"
            return 0
        fi
        # Fall through, loudly. The label is stale relative to the change set
        # this approve would bind, so a fresh record is exactly what is needed.
        log_sync_error "approve: qa-approved was already set on $tid but no approval record binds the current change set (reference hash=${idem_ref:-<unavailable>} via ${IDEM_REF_SOURCE:-<unavailable>}) — re-verifying preconditions and writing a fresh bound record instead of no-op'ing (gz3)"
        # The literal string "idempotent no-op" is deliberately NOT used here:
        # it is the discriminator for the no-op envelope above (tests and
        # operators grep for it), so reusing it in the OPPOSITE outcome's text
        # would make every such grep a silent false positive.
        stale_label_obs="; NOTE qa-approved was already set but no approval record bound this change set (reference hash=${idem_ref:-<unavailable>} via ${IDEM_REF_SOURCE:-<unavailable>}) — preconditions re-verified and a FRESH record written (stale-label re-bind, gz3)"
    fi

    # TRACKER-RECONCILE BEGIN (94d)
    # RECONCILE BEFORE THE IMPACT-REPORT REFUSAL, and refuse when it cannot be
    # done. Ordering is the whole point: the refusal below compares the report's
    # recorded change_set_hash against the CURRENT one, and this is what makes
    # "current" mean the git-visible change set rather than the subset a
    # Write/Edit hook recorded. Reconciling AFTER would bind an approval to a
    # hash computed over an under-covering list — the defect itself.
    #
    # This is a REFUSAL, not a warning, and unlike the impact-report refusal it
    # has NO bypass flag. An unreconcilable tracker means we cannot say what the
    # change set IS; every downstream credential this approve writes (the bound
    # approval record, the reviewed hash, the rubric binding) would be a claim
    # about an unknown quantity. --no-impact-report waives an ANALYSIS whose
    # degradation is documented; there is no comparable degraded mode for "we do
    # not know which files changed".
    #
    # Declared before the sentinel-wrapped block below so the META-TEST's
    # stripped copy stays coherent.
    if ! reconcile_tracker; then
        emit_error_json "approve" "$tid" "tracker_unreconcilable" \
            "approve refused: the change-set tracker could not be reconciled against git, so the change set this approval would bind is unprovable. $RECONCILE_OBS. Fix the underlying git error and re-run approve; there is deliberately no bypass flag — an approval bound to an unknown change set is worse than no approval (94d)." \
            "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] [--no-review '<reason>'] <summary>"
        exit 2
    fi
    local reconcile_obs="; $RECONCILE_OBS"
    # TRACKER-RECONCILE END (94d)

    # CHANGE-SET-RECONSTRUCTED BEGIN (94d.1)
    # THE MATERIALLY-SHORT REFUSAL — fkm.1.2 half (b), generalised because its
    # original form is now unreachable.
    #
    # fkm.1.2 (b) asked approve to refuse "when the change set is EMPTY while git
    # shows un-baselined dirt". That guard cannot fire any more, and P1 is why:
    # the tracker reconcile folds un-baselined dirt INTO the tracker before
    # anything reads it, so "empty tracker + un-baselined dirt" is not a state
    # approve can observe. (Spelled in prose rather than with the function's own
    # identifier deliberately: this comment sits OUTSIDE the TRACKER-RECONCILE
    # sentinels, and 7M asserts that stripping those regions leaves zero mentions
    # of that name — a prose mention here fails that leg, which is exactly how it
    # was caught.) The failure it was written for did not go away — it changed
    # shape.
    # On 94d's own review the same trigger (SessionStart deleting the tracker at a
    # compaction) produced a NON-EMPTY, plausible, 10-of-26-path set and a
    # confident `+10 git-visible path(s)`. There is no zero left to trip on, so
    # the predicate has to be "materially short" rather than "empty".
    #
    # WHAT "MATERIALLY SHORT" MEANS HERE, and why it is not a ratio. THREE facts
    # from the reconcile that just ran, none of them inferred from the tracker's
    # own contents:
    #   (1) RECONCILE_REBUILT_FROM_EMPTY — changed-files.txt was absent-or-empty
    #       when the reconcile ran, so every path in the set being bound came from
    #       `git status`, not from a recorded edit. The tracker is APPEND-ONLY
    #       during a cycle (post-edit appends, reconcile appends, nothing removes;
    #       only approve and the Stop's release paths truncate), so empty during
    #       an open cycle means either "nothing was ever recorded" or "it was
    #       destroyed".
    #   (2) RECONCILE_ADDED > 0 — the rebuild produced a NON-EMPTY change set, so
    #       this approve is about to certify actual work.
    #   (3) RECONCILE_SUBTRACTED > 0 — and it ALSO dropped N git-visible,
    #       reviewable paths as already-baselined. So the set being certified is a
    #       PROVEN SUBSET of the working tree's reviewable dirt.
    # Together they are the state where binding an approval is strictly worse than
    # not binding one: it converts an under-covered review into a signed
    # attestation of completeness. The live 94d.1 occurrence sits exactly here
    # (added=10, subtracted=16).
    #
    # WHY CLAUSE (2) IS THERE, MEASURED rather than assumed. Without it the
    # refusal also fires on `added=0, subtracted>0` — an EMPTY change set with
    # baselined dirt around it — and that is a common, legitimate state, not a
    # loss: a task closed with no code change, a doc-only fast path, or simply a
    # session that did nothing while the repo happened to be dirty on arrival.
    # It is the state of the L1 `qa-gate-choose` and `qa-gate-grade-record`
    # fixtures, whose approve calls this refusal broke before clause (2) was
    # added (their one "subtracted" entry is the fixture's own untracked
    # `.claude/scripts/` directory). The gate already treats an empty change set
    # as "nothing to review" everywhere else; refusing it here would be a wide
    # false positive for a narrow gain.
    #
    # WHAT CLAUSE (2) THEREFORE DOES NOT COVER, named rather than left latent: a
    # session whose work was ENTIRELY Bash-written to paths that were ALL already
    # dirty at baseline capture reads as `added=0` and is not refused, even though
    # its change set is hollow. That is fkm.1.2's ORIGINAL empty-binding concern,
    # and this predicate cannot separate it from the legitimate empty cases above
    # — the observations are identical. It is REPORTED either way (`subtracted=N`
    # plus the paths, and the rebuild announcement), which is the honest limit of
    # what this evidence supports: escalating to a refusal there would block every
    # no-op approve in a dirty checkout.
    #
    # WHY NOT A COMPARISON OF TWO COUNTS. Because both counts a truncated tracker
    # can offer are derived from the truncated tracker. That is precisely how the
    # impact-report freshness check missed this: `recorded_hash == current_hash`
    # holds when BOTH describe the shrunken set, so it detects DRIFT and is blind
    # to LOSS. Neither input above is read from the tracker's contents — (1) is the
    # emptiness of the file at a known instant, (2) is a count taken from `git
    # status` and the baseline.
    #
    # PLACED BEFORE THE IMPACT-REPORT REFUSAL, for the reason that block's own
    # header gives about the reconcile: what the change set IS has to be settled
    # before anything reasons about it. A report validated against a set nobody
    # established is a fresh answer to the wrong question.
    #
    # INERT WHEN THE TRACKER-RECONCILE REGION IS STRIPPED (`:-0` defaults), so the
    # 7M META's stripped copy keeps testing what it is aimed at rather than dying
    # on an unset variable.
    if [ "$bypass_reconstructed" != "1" ] \
        && [ "${RECONCILE_REBUILT_FROM_EMPTY:-0}" = "1" ] \
        && [ "${RECONCILE_ADDED:-0}" -gt 0 ] \
        && [ "${RECONCILE_SUBTRACTED:-0}" -gt 0 ]; then
        emit_error_json "approve" "$tid" "change_set_reconstructed" \
            "approve refused: the change set this approval would bind was RECONSTRUCTED, and is provably short. changed-files.txt was absent-or-empty when the reconcile ran, so all ${RECONCILE_ADDED:-0} path(s) in it came from 'git status' rather than from a recorded edit — and that rebuild dropped ${RECONCILE_SUBTRACTED:-0} further git-visible path(s) as already-baselined. Dropped (first ${RECONCILE_SUBTRACTED_INLINE_CAP:-12} shown; FULL list in $QA_TRACKING_DIR/reconcile-subtracted.txt): $(printf '%s' "${RECONCILE_SUBTRACTED_PATHS:-}" | head -n "${RECONCILE_SUBTRACTED_INLINE_CAP:-12}" | tr '\n' ' '). A rebuild can only ever be a SUBSET — a file whose content was reverted, and the gate's own artifacts, are invisible to git — so binding an approval here would certify less than shipped (94d.1). Decide which it is: if those paths ARE this session's work, the tracker was destroyed and the review has to cover them; if they are genuinely pre-existing dirt, say so and proceed: bash .claude/scripts/qa-gate.sh approve $tid --accept-reconstructed '<reason>' '<summary>'" \
            "qa-gate.sh approve <task-id> [--accept-reconstructed '<reason>'] [--no-impact-report '<reason>'] [--no-review '<reason>'] <summary>"
        exit 2
    fi
    local reconstructed_obs=""
    if [ "$bypass_reconstructed" = "1" ]; then
        reconstructed_obs="; reconstructed-change-set bypass: $reconstructed_bypass_reason (change_set_reconstructed refusal waived via --accept-reconstructed; rebuilt_from_empty=${RECONCILE_REBUILT_FROM_EMPTY:-0} added=${RECONCILE_ADDED:-0} subtracted=${RECONCILE_SUBTRACTED:-0}; reason recorded per 94d.1)"
    fi
    # CHANGE-SET-RECONSTRUCTED END (94d.1)

    # G2.n6d: impact-report audit note. Declared OUTSIDE the sentinel
    # block below so (a) the bypass audit trail survives even if the
    # refusal block is stripped, and (b) the stripped copy stays
    # syntactically coherent for the META-TEST.
    local impact_obs=""
    if [ "$bypass_impact" = "1" ]; then
        impact_obs="; impact-bypass: $bypass_reason (impact-report refusal bypassed via --no-impact-report; reason recorded per G2.n6d)"
    fi

    # IMPACT-REPORT-REFUSAL BEGIN (G2.n6d / claude-workflow-plugin-llh.2)
    #
    # Mechanical gate: approve refuses unless a FRESH impact report
    # exists for this task. "Fresh" = the report's change_set_hash equals
    # the sha256 of the CURRENT canonical changed-files list (computed by
    # the same script that generated the report, so the canonicalisation
    # cannot drift). A stale report is no report: it analysed a change
    # set that no longer matches what would ship.
    #
    # Deliberately NOT checked: the report's `server` field. A
    # server:"absent" report is the documented degradation (code-graph
    # not installed/bootable) and is a valid artifact — the refusal
    # exists to stop SKIPPED analysis, not degraded environments.
    #
    # The sentinel comments wrapping this block are load-bearing: the L2
    # META-TEST strips everything between them and asserts approve then
    # succeeds without the artifact (proving the refusal is what enforces
    # the contract). Do not rename them.
    if [ "$bypass_impact" != "1" ]; then
        local impact_report current_hash recorded_hash
        impact_obs=""
        impact_report=$(impact_report_path_for "$tid")
        if [ ! -f "$impact_report" ]; then
            emit_error_json "approve" "$tid" "impact_report_missing" \
                "approve refused: mechanical impact report missing at $impact_report. The QA workflow requires the impact_of analysis artifact (G2.n6d). Regenerate: bash .claude/scripts/impact-report.sh $tid — or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] <summary>"
            exit 2
        fi
        recorded_hash=$(jq -r '.change_set_hash // empty' "$impact_report" 2>/dev/null || echo "")
        if [ -z "$recorded_hash" ]; then
            emit_error_json "approve" "$tid" "impact_report_invalid" \
                "approve refused: impact report at $impact_report is unparseable or missing change_set_hash. Regenerate: bash .claude/scripts/impact-report.sh $tid — or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] <summary>"
            exit 2
        fi
        current_hash=$(compute_change_set_hash)
        if [ -z "$current_hash" ]; then
            emit_error_json "approve" "$tid" "impact_report_unverifiable" \
                "approve refused: cannot recompute the current change-set hash ($IMPACT_REPORT_SCRIPT missing or failing), so the report's freshness is unverifiable. Restore the script, or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] <summary>"
            exit 2
        fi
        if [ "$recorded_hash" != "$current_hash" ]; then
            emit_error_json "approve" "$tid" "impact_report_stale" \
                "approve refused: impact report is STALE — its change_set_hash ($recorded_hash) no longer matches the current changed-files list ($current_hash); files changed after the report was generated, so the impact analysis does not cover what would ship. Regenerate: bash .claude/scripts/impact-report.sh $tid — or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] <summary>"
            exit 2
        fi
        impact_obs="; impact-report verified (change_set_hash match: $current_hash)"
    fi
    # IMPACT-REPORT-REFUSAL END (G2.n6d / claude-workflow-plugin-llh.2)

    # llh.18 (red-team P0/P1): capture the canonical change-set hash that
    # this approval covers. Declared OUTSIDE the sentinel block above so:
    #   (a) the bypass path (which skips the refusal) still binds the
    #       approval to a change-set, and
    #   (b) the META-TEST's stripped copy (sentinels removed) still writes a
    #       change-set-bound record — keeping the stripped copy coherent.
    # The non-bypass path already computed current_hash inside the refusal
    # block; we recompute here unconditionally so the value exists on every
    # path. compute_change_set_hash prints empty on failure; an empty hash
    # degrades to the legacy unbound comment (logged) rather than aborting
    # the approval (labels remain the lifecycle source of truth).
    local approved_hash
    approved_hash=$(compute_change_set_hash)
    if [ -z "$approved_hash" ]; then
        log_sync_error "approve: could not compute change_set_hash for $tid (impact-report.sh missing/failing); writing approval comment WITHOUT a change-set binding — verify-before-stop will not be able to match it (re-run approve once impact-report.sh is restored)"
    fi

    # EXPECTED-HASH-REFUSAL BEGIN (claude-workflow-plugin-qzv)
    #
    # DID THE CALLER'S VERDICT COVER THE CHANGE SET THIS APPROVAL WILL BIND?
    #
    # THE DEFECT THIS CLOSES. `verify-before-stop.sh`'s F1 fast path classifies a
    # change set as doc-only / beads-state / empty, and THEN calls approve. Those
    # are two reads at two instants, in a process that runs `enter` (which
    # reconciles the tracker and regenerates the impact report) in between. A path
    # that arrives in that window is inside what approve binds and outside what F1
    # judged — so a "no reviewable source changed" verdict could be recorded over
    # a set containing reviewable source. On the v4.1.0 release task the recorded
    # approval bound `9942b2bd` while the work that actually shipped hashed to
    # `914ceeff`. `--expect-hash` makes the caller state the set it judged and
    # refuses when that is not the set being bound.
    #
    # WHERE IT SITS, AND WHY — cmd_approve now carries four refusals, and the
    # order is a claim about what each one can PROVE:
    #   1. tracker_unreconcilable / 2. change_set_reconstructed — what the change
    #      set IS. Nothing can be reasoned about a set nobody has established, so
    #      these come first (their own headers say so).
    #   3. THIS ONE. It compares the caller's expectation against `approved_hash`,
    #      the value this function will actually bind — which does not exist until
    #      the line above. Placing it earlier would compare against a different
    #      quantity than the one bound, which is exactly the "guard probes a
    #      weaker fact than the property it protects" shape that produced this
    #      release's R6-F1. It also has to precede every WRITE below, since a
    #      refusal must leave the task untouched.
    #   4. REVIEW-SEPARATION — the most expensive to remediate (a human/agent
    #      review round-trip) and, on the F1 path, bypassed outright. Same
    #      cheapest-first argument that block's own header makes about the
    #      impact-report refusal: a pure string compare over two values already in
    #      hand should not queue behind a review round, and a caller whose
    #      classification is stale has nothing to review yet anyway.
    #
    # ONE BOUNDARY, NAMED RATHER THAN LEFT LATENT. The hash-aware idempotency
    # no-op higher up in this function returns BEFORE this refusal. On that path
    # nothing new is bound, so there is nothing for this check to protect — but a
    # caller passing --expect-hash to an already-approved task whose existing
    # record binds a different set than it expected gets a success envelope (which
    # names the hash it matched) rather than a refusal. F1 cannot reach it: its
    # `case` arm excludes the `approved` status, so this is a manual-caller
    # boundary only.
    #
    # WHAT THIS DOES NOT ESTABLISH. It proves the bound set is the CLASSIFIED set.
    # It does NOT prove that set is COMPLETE — both sides come from the same
    # canonicalisation over the same tracker, so this detects drift and is
    # structurally blind to loss (claude-workflow-plugin-fkm.1.20). An independent
    # witness for completeness is a separate piece of work; nothing here supplies
    # one.
    #
    # BOTH HASHES ARE NAMED in the refusal, because "they differ" is unactionable:
    # which one is stale, and whether the delta is one doc or a source file, is the
    # whole decision the operator has to make.
    #
    # The sentinel comments are load-bearing: an L2 META-TEST strips this region
    # and asserts a mismatched --expect-hash then approves. Do not rename them.
    if [ -n "$expect_hash_arg" ] && [ "$expect_hash_arg" != "$approved_hash" ]; then
        emit_error_json "approve" "$tid" "expected_hash_mismatch" \
            "approve refused: the caller expected to approve change set $expect_hash_arg but this approval would bind $approved_hash. The two reads straddle something that moved the change set — most often a path that arrived after the caller classified it (the F1 doc-only fast path passes the hash of the set it classified, so a source file landing mid-Stop lands here rather than being approved under a doc-only verdict). NOTE: this proves the bound set is the CLASSIFIED set; it does NOT prove that set is complete (claude-workflow-plugin-fkm.1.20). Re-derive the current set and decide: bash .claude/scripts/impact-report.sh --hash-only — then either re-review at the new hash and approve without --expect-hash, or pass the hash you actually reviewed." \
            "qa-gate.sh approve <task-id> [--expect-hash <hash>] [--accept-reconstructed '<reason>'] [--no-impact-report '<reason>'] [--no-review '<reason>'] <summary>"
        exit 2
    fi
    local expect_hash_obs=""
    if [ -n "$expect_hash_arg" ]; then
        expect_hash_obs="; expected-hash verified (the caller classified change_set_hash=$expect_hash_arg and that is what this approval binds; NOT a completeness claim — see fkm.1.20)"
    fi
    # EXPECTED-HASH-REFUSAL END (claude-workflow-plugin-qzv)

    # R2-F2: does the satisfied verdict this approval is about to cite actually
    # cover the change set being approved?
    #
    # Nothing used to ask. The rubric audit line below was emitted from the
    # LABEL alone, so this sequence produced an approval claiming a verdict it
    # did not have, with no adversary and no forged anything: grade set A ->
    # enter (preserves, correctly) -> add path B -> regenerate the impact report
    # -> approve. approved_hash is A+B, the verdict graded A, and the envelope
    # said "rubric-satisfied preserved (audit trail)".
    #
    # WARN, DO NOT REFUSE — a deliberate call, and the one place in this change
    # where the safer-looking option is the wrong one:
    #   - qa.md 6f states the rule explicitly: "adding script-side denial of
    #     approve-without-satisfied would create a parallel gate and violate
    #     principle 6". The rubric is a QA INPUT; qa-approved + a bound record
    #     is the only release credential, and verify-before-stop reads neither
    #     rubric label nor RUBRIC comment. A refusal here would be a second,
    #     divergent gate on a signal the Stop side does not consult.
    #   - The remediation a refusal would print is either "re-run the relay" (a
    #     paid grader spawn, and impossible at the iteration cap) or "clear the
    #     label first" — which is the undocumented-label-removal dead end gz3
    #     spent a whole task eliminating. A refusal whose only exit is a bypass
    #     teaches the bypass.
    #   - The legitimate flow it would fire on is real: QA reviewing a change
    #     set that grew after grading and approving with a documented override
    #     is exactly what 6f describes.
    # So the fix is to stop the AUDIT TRAIL lying, which is the actual harm:
    # the claim below is now hash-checked, and a mismatch is recorded in the
    # durable approval comment as well as the envelope. If the project later
    # decides the rubric should hard-gate, this is the line to change — and
    # principle 6 and qa.md 6f have to change with it.
    local rubric_graded_hash=""
    rubric_graded_hash=$(latest_satisfied_rubric_hash "$tid") || rubric_graded_hash=""
    local rubric_mismatch=0
    if [ "$had_rubric_satisfied" = "1" ] && [ -n "$rubric_graded_hash" ] \
       && [ -n "$approved_hash" ] && [ "$rubric_graded_hash" != "$approved_hash" ]; then
        rubric_mismatch=1
        log_sync_error "approve: rubric-satisfied is set on $tid but the satisfied verdict binds change_set_hash=$rubric_graded_hash while this approval binds $approved_hash — the approval comment must carry an override reason (qa.md 6f); recorded as a [rubric mismatch: ...] token in the approval record"
    fi

    # V3 (claude-workflow-plugin-jio.1): the review-separation audit fields.
    # Declared OUTSIDE the sentinel block below for the same two reasons
    # impact_obs is: (a) the --no-review bypass path skips the block but must
    # still record WHO (nobody) reviewed and WHY it was waived, and (b) the
    # META-TEST's stripped copy stays syntactically coherent and still writes a
    # well-formed `reviewed_by=` token.
    local reviewed_by="none"
    local review_obs=""
    local review_artifact_hash=""
    if [ "$bypass_review" = "1" ]; then
        review_obs="; review-bypass: $review_bypass_reason (independent-review refusal bypassed via --no-review; reason recorded per V3)"
    fi

    # REVIEW-SEPARATION BEGIN (v4 V3 / claude-workflow-plugin-jio.1)
    #
    # Mechanical gate: NOBODY SIGNS OFF ON THEIR OWN WORK. approve refuses
    # unless the task carries a review record whose reviewer_identity differs
    # from EVERY recorded implementer, and no finding at/above the artifact's
    # risk_threshold is still unresolved and un-arbitrated.
    #
    # The predicate is NOT reimplemented here. review-check.sh `gate` is the
    # ONE place that parses the record grammars and counts — exactly like
    # compute_change_set_hash defers to impact-report.sh --hash-only. A second
    # counter would be a second thing to drift.
    #
    # FAIL CLOSED, deliberately: a MISSING or unrunnable helper refuses
    # (exit 4) rather than waving the approval through. An enforcement whose
    # absence is silently equivalent to a pass is not an enforcement — and
    # `rm .claude/scripts/review-check.sh` would otherwise be a one-line
    # bypass of the whole contract.
    #
    # Ordering: this runs AFTER the impact-report refusal on purpose. That one
    # is cheaper and its remediation is mechanical (re-run one script); this
    # one costs a human/agent review round-trip, so it should not fire while a
    # more basic artifact is still missing.
    #
    # The sentinel comments wrapping this block are load-bearing: an L2
    # META-TEST strips everything between them and asserts approve then
    # succeeds with NO review artifact at all. Do not rename them.
    if [ "$bypass_review" != "1" ]; then
        if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
            emit_error_json "approve" "$tid" "review_check_unavailable" \
                "approve refused: the review predicate is unavailable — $REVIEW_CHECK_SCRIPT is missing, so independent review cannot be verified. This FAILS CLOSED by design (a deleted checker must not read as a passing check). Restore the script, or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --no-review '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-review '<reason>'] <summary>"
            exit 4
        fi
        local review_out review_rc=0 review_key review_open
        review_out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" gate "$tid" 2>&1) || review_rc=$?
        case "$review_rc" in
            0)
                reviewed_by=$(printf '%s' "$review_out" | jq -r '.reviewer_identity // "unknown"' 2>/dev/null || echo "unknown")
                [ -z "$reviewed_by" ] && reviewed_by="unknown"
                review_artifact_hash=$(printf '%s' "$review_out" | jq -r '.artifact.reviewed_hash // ""' 2>/dev/null || echo "")
                review_obs="; independent review verified (reviewed_by=$reviewed_by; no open findings at/above the artifact's risk_threshold)"
                # D6: the artifact may legitimately predate the current
                # change-set — resolving a finding CHANGES the files, hence the
                # hash. That is a normal, healthy review loop, so staleness is
                # AUDITED, never blocking. (A stale-artifact refusal here would
                # make every resolve-then-approve cycle unclosable.)
                if [ -n "$review_artifact_hash" ] && [ -n "$approved_hash" ] \
                    && [ "$review_artifact_hash" != "$approved_hash" ]; then
                    review_obs="$review_obs; WARNING the review artifact recorded reviewed_hash=$review_artifact_hash but this approval binds change_set_hash=$approved_hash — the reviewed change-set is not byte-identical to the approved one (expected after a resolve-finding round; re-review if the delta is substantive)"
                fi
                ;;
            2)
                # bd unreachable — the same class require_bd refuses on.
                emit_error_json "approve" "$tid" "review_check_bd_unavailable" \
                    "approve refused: review-check.sh could not read $tid's records (bd unavailable). Independent review is unverifiable, so the gate fails closed. Restore bd, or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-review '<reason>' '<summary>'" \
                    "qa-gate.sh approve <task-id> [--no-review '<reason>'] <summary>"
                exit 2
                ;;
            4)
                review_key=$(printf '%s' "$review_out" | jq -r '.error_key // "review_check_violation"' 2>/dev/null || echo "review_check_violation")
                [ -z "$review_key" ] && review_key="review_check_violation"
                review_open=$(printf '%s' "$review_out" | jq -r '(.open_finding_ids // []) | join(", ")' 2>/dev/null || echo "")
                local review_remedy=""
                case "$review_key" in
                    review_artifact_missing)
                        review_remedy="No REVIEW-ARTIFACT v1 record exists for $tid. An independent reviewer must review this change set and record the artifact — QA's section 6-prime authors it (reviewer_identity=qa-claude) and records it with: bash .claude/scripts/qa-gate.sh review-record $tid --file <artifact.json>"
                        ;;
                    reviewer_not_independent)
                        review_remedy="The recorded reviewer is also a recorded IMPLEMENTER of this task, i.e. the change would be signed off by whoever wrote it. Have a DIFFERENT identity review the change set and record a fresh artifact (a QA-authored qa-claude artifact is independent of backend/frontend/devops implementers)."
                        ;;
                    unresolved_findings)
                        review_remedy="Open finding(s) at/above the artifact's risk_threshold: ${review_open:-<none reported>}. Each must be closed with evidence — bash .claude/scripts/qa-gate.sh resolve-finding $tid <finding-id> --fix '<ref>' --test '<ref>' '<summary>' — or explicitly overruled: bash .claude/scripts/qa-gate.sh arbitrate $tid <finding-id> overrule '<rationale>'"
                        ;;
                    review_artifact_malformed)
                        review_remedy="The latest review record is corrupted (no well-formed findings=[...] token), so it cannot be read as a clean review. Re-record a valid artifact via: bash .claude/scripts/qa-gate.sh review-record $tid --file <artifact.json>"
                        ;;
                    *)
                        review_remedy="review-check.sh gate $tid reported: $review_key. Re-run it directly for the full envelope."
                        ;;
                esac
                emit_error_json "approve" "$tid" "$review_key" \
                    "approve refused (review separation): $review_remedy — or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --no-review '<reason>' '<summary>'" \
                    "qa-gate.sh approve <task-id> [--no-review '<reason>'] <summary>"
                exit 4
                ;;
            *)
                # Usage error (1) or anything unexpected: still fail closed —
                # an unreadable verdict is not a passing verdict.
                emit_error_json "approve" "$tid" "review_check_unavailable" \
                    "approve refused: review-check.sh gate $tid exited $review_rc without a usable verdict, so independent review is unverifiable (fail-closed). Run it directly to see why, or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-review '<reason>' '<summary>'" \
                    "qa-gate.sh approve <task-id> [--no-review '<reason>'] <summary>"
                exit 4
                ;;
        esac
    fi
    # REVIEW-SEPARATION END (v4 V3 / claude-workflow-plugin-jio.1)

    # ---- APPROVE-COMMIT ORDER (gz3 / v4.1 U1) -----------------------------
    #
    # The steps below are ordered so that a Stop hook firing CONCURRENTLY never
    # observes a state that reads as "approved, but the change set is
    # unbindable". The gate has two processes and no lock: `qa-gate.sh approve`
    # runs in the QA subagent while the Stop hook runs in the parent session, so
    # every intermediate state of this function is observable. THREE such states
    # produced transient false blocks; all three were reproduced deterministically
    # against the pre-fix scripts before anything here moved (drive points, not
    # sleeps — see the spec named at the end of this note).
    #
    #   W1  a Stop between the label add and the record write -> the
    #       forged-label LABEL_WITHOUT_RECORD block, for a legitimate approval.
    #   W2  a Stop between clear_current_task and the truncation -> the
    #       "No active Beads task detected" block, for work just approved.
    #   W3  a Stop whose OWN two change-set reads straddle the truncation ->
    #       recomputes the empty-set hash, matches no record, same block.
    #
    # W1 and W2 are closed by the reordering below (rules 1 and 3). W3 cannot be:
    # both reads belong to the Stop process and straddle whatever approve does in
    # between, so it is closed on the Stop side by the VANISHED-CHANGE-SET
    # re-read in verify-before-stop.sh — which depends on rule 2 holding here.
    #
    #   1. RECORD BEFORE LABEL (CHANGED here). The Stop's release predicate is
    #      (label AND a record matching the current hash). Writing the label
    #      first opened W1 — two bd label calls wide. A record with no label is
    #      inert (the label is still required), so this direction has no
    #      symmetric hazard: a Stop landing there sees the ordinary
    #      not-yet-approved block instead of the alarming forged-label one.
    #   2. BASELINE BEFORE TRACKER (UNCHANGED, and now load-bearing). This was
    #      already the order 0wk.2 shipped; what is new is that something DEPENDS
    #      on it. Both are state a Stop reads to answer "is there anything to
    #      review?", and in this order an empty tracker always implies a
    #      refreshed baseline — so the Stop-side re-read that closes W3 cannot
    #      observe a half-finalized pair and conclude that un-baselined dirt is
    #      unreviewed. Flipping these two lines re-opens W3; that is why the
    #      order is pinned by a test rather than left to chance.
    #   3. SESSION STATE LAST (CHANGED here). clear_current_task used to run
    #      BEFORE the truncation, which is W2. After the truncation there is
    #      nothing left to review, so a missing task id cannot produce a block.
    #   4. NOTHING DESTRUCTIVE BEFORE THE LABELS LAND (UNCHANGED). The
    #      tracking-state finalization (baseline refresh + truncate) stays AFTER
    #      every step that can roll back. This is why the finalization is not
    #      simply hoisted to the top to make the whole thing look atomic: a
    #      rollback that had already truncated the tracker and refreshed the
    #      baseline would leave a session whose work is invisible to the gate —
    #      the next Stop would release unreviewed code on the "no changes" fast
    #      path. Fail-closed beats atomic-looking.
    #
    # Reproductions + regression coverage (W1/W2 at their drive points, W3, and
    # the source order): .claude/tests/component/specs/approve-idempotency.sh
    # sections E and F.

    # Step 1 (gz3: record BEFORE label): the approval record.
    # Non-fatal — labels remain the lifecycle source of truth.
    # G2.n6d: a bypass reason is appended so the audit trail names WHY the
    # mechanical impact gate was waived for this approval.
    #
    # llh.18 (red-team P0/P1): the comment is now the TAMPER-EVIDENT APPROVAL
    # RECORD that binds this approval to the reviewed change-set. The
    # `change_set_hash=<h>` token is what verify-before-stop.sh reads back and
    # matches against the CURRENT change-set hash before releasing. The label
    # `qa-approved` remains necessary (status precedence, idempotency); the
    # change-set-bound record is now ADDITIONALLY required at Stop time. A bare
    # `bd label add <task> qa-approved` writes no such record → Stop blocks
    # (P0); a decoy-task approval records the decoy's hash, not the shipping
    # change-set's → Stop blocks (P1); a post-approval edit shifts the current
    # hash away from the recorded one → Stop blocks (re-review).
    #
    # THREAT-MODEL BOUNDARY (documented, NOT overclaimed): an agent with
    # arbitrary shell + the hash tool could still forge this very comment
    # (`bd comment add "QA-GATE APPROVED change_set_hash=$(impact-report.sh
    # --hash-only)"`). This fix raises the bar from "trivially-forgeable
    # label" to "must reproduce a change-set-bound record", defeats
    # accidental / lazy / bare-`bd label add` drift, and binds approval to the
    # reviewed files (P1) — it is NOT a cryptographic sandbox against a
    # determined adversary. A signed/HMAC'd record keyed on a secret the
    # gated process cannot read would be required for that, which the
    # full-shell autonomy model (no secrets withheld from agents) precludes.
    #
    # V3 (jio.1): the record additionally names WHO reviewed
    # (`reviewed_by=<identity>`, or `none` on the audited --no-review bypass).
    # 3mg.2 (V4 pt2): and WHERE — `worktree=<tok>`, the approving checkout.
    #
    # Token ORDER is a compatibility contract: every token added since llh.18
    # goes AFTER the change_set_hash token, separated by a SPACE, so the Stop
    # hook's existing `capture("change_set_hash=(?<h>[A-Za-z0-9-]+)")` still
    # stops at that space and reads the same hash it always did — and the V3
    # `\breviewed_by=(\S+)` capture likewise stops before `worktree=`.
    # Prepending a token, or joining two with anything in [A-Za-z0-9-], would
    # silently corrupt every hash comparison. Regression: the L1
    # review-separation.test.sh section 4 compat + META assertions run the
    # readers' EXACT expressions against a freshly written record. Final shape:
    #   QA-GATE APPROVED change_set_hash=<h> reviewed_by=<id> worktree=<tok> at <ts>: <summary>
    #     [ [impact-report bypass: <reason>]][ [review bypass: <reason>]]
    local ts comment_suffix=""
    if [ "$bypass_impact" = "1" ]; then
        comment_suffix=" [impact-report bypass: $bypass_reason]"
    fi
    if [ "$bypass_review" = "1" ]; then
        # The literal `[review bypass:` marker is what verify-before-stop.sh
        # reads to skip its own review-discipline check for this record (the
        # F1 doc-only fast path is the intended producer).
        comment_suffix="$comment_suffix [review bypass: $review_bypass_reason]"
    fi
    # R2-F2: the mismatch goes in the DURABLE record, not only the envelope.
    # An envelope is read once by whoever ran the command; the audit question
    # ("did the verdict this approval cited actually cover it?") is asked later,
    # by someone reading the task. Same bracketed-suffix shape as the two
    # bypasses, and after every machine token, so the llh.18 / 3mg.2 readers
    # (`change_set_hash=`, `reviewed_by=`, `worktree=`) stop where they always
    # did.
    if [ "$rubric_mismatch" = "1" ]; then
        comment_suffix="$comment_suffix [rubric mismatch: graded=$rubric_graded_hash approved=$approved_hash]"
    fi
    # CHANGE-SET-RECONSTRUCTED BEGIN (94d.1)
    # Same reasoning as R2-F2 above, and it applies harder here: this bypass says
    # "the change set I am binding was rebuilt from git and is provably short, and
    # I judged the missing paths pre-existing". That judgement is exactly what a
    # later audit needs to see, and an envelope read once by whoever typed the
    # command is not where it survives. Bracketed suffix, after every machine
    # token, so the `change_set_hash=` / `reviewed_by=` / `worktree=` captures
    # stop where they always did.
    if [ "$bypass_reconstructed" = "1" ]; then
        comment_suffix="$comment_suffix [reconstructed change set accepted: $reconstructed_bypass_reason (subtracted=${RECONCILE_SUBTRACTED:-0})]"
    fi
    # CHANGE-SET-RECONSTRUCTED END (94d.1)
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local hash_field=""
    if [ -n "$approved_hash" ]; then
        hash_field="change_set_hash=$approved_hash "
    fi

    # Declared with an EMPTY default outside the sentinel block below (same
    # discipline as reviewed_by / approved_hash): stripping the block must
    # leave a coherent record — the pre-3mg.2 grammar, with no dangling
    # `worktree=` and no double space.
    local worktree_field=""
    # WORKTREE-TOKEN BEGIN (v4 V4 / claude-workflow-plugin-3mg.2)
    #
    # Every approve path reaches this ONE add_comment — the normal path, the
    # F1 `--no-review` fast path, and both audited bypasses — so recording the
    # token here covers all of them without a second write site.
    #
    # The L1 META strips these sentinels and asserts (a) the copy still
    # approves and writes the pre-3mg.2 record, and (b) the change_set_hash /
    # reviewed_by captures extract IDENTICAL values from both shapes. That is
    # the falsifiable form of "adding this token cannot regress the readers".
    worktree_field="worktree=$(approval_worktree_token) "
    # WORKTREE-TOKEN END (v4 V4 / claude-workflow-plugin-3mg.2)
    add_comment "$tid" "QA-GATE APPROVED ${hash_field}reviewed_by=$reviewed_by ${worktree_field}at $ts: $summary$comment_suffix"

    # Step 2 (gz3: after the record): THE terminal-label transition. One call
    # replaces what were four separate steps — add qa-approved, remove
    # qa-gate-entered with a rollback, remove qa-pending with a hand-written
    # inverse of that rollback, then two best-effort helper calls for the
    # escalation pair and rubric-pending. See set_terminal_label for the ordering
    # rationale (terminal first, then sweep) and for why the transition is one
    # function rather than one more step.
    #
    # WHAT THIS CLEARS: the cycle set below, minus qa-approved itself. What it does
    # NOT clear is rubric-satisfied, which is not a member of QA_CYCLE_LABELS at
    # all — the audit trail of the verdict that backed this approval, handled by
    # the had_rubric_satisfied / rubric_mismatch logic above and reported in
    # $rubric_obs below.
    #
    # The list is declared OUTSIDE the sentinel region that follows, with
    # qa-blocked appended INSIDE it. Same discipline as worktree_field's empty
    # default above: stripping the region must leave a copy that still performs a
    # coherent pre-8zi approve, otherwise the META asserting "qa-blocked survives
    # the stripped copy's approve" would be measuring a script that cannot approve
    # at all, and would pass for the wrong reason.
    local -a sweep_clear=(qa-gate-entered qa-pending qa-escalated qa-deferred rubric-pending)
    # TERMINAL-LABEL-SWEEP BEGIN (8zi)
    # THE 8zi DELTA, in one line: a previous cycle's qa-blocked is part of what an
    # approval ends. Without it the block -> fix -> approve round trip terminates
    # with both terminal labels set and no way for a reader to tell which is
    # current — reproduced live on uvk, q7n, 94d and qzv.1.
    sweep_clear+=(qa-blocked)
    # TERMINAL-LABEL-SWEEP END (8zi)
    if ! set_terminal_label "$tid" "qa-approved" "${sweep_clear[@]}"; then
        if [ "$TERMINAL_SWEEP_PHASE" = "add_terminal" ]; then
            # The record is already on the task and comments are append-only, so we
            # say so rather than claiming "nothing changed": without the label the
            # record cannot release anything (the Stop needs both), and re-running
            # approve writes a fresh record.
            log_sync_error "approve: qa-approved label add FAILED for $tid after the approval record was written; the record cannot release without the label — re-run approve (gz3 ordering)"
            emit_json 0 "approve" "$tid" "error" "failed to add qa-approved; no labels changed (the approval record was already written and cannot be unwritten — it is inert without the label; re-run approve). $TERMINAL_SWEEP_OBS"
            exit 3
        fi
        log_sync_error "approve: the terminal-label transition FAILED for $tid after the approval record was written; $TERMINAL_SWEEP_OBS"
        emit_json 0 "approve" "$tid" "error" "approve rolled back: $TERMINAL_SWEEP_OBS (the approval record was already written and cannot be unwritten — it is inert without the label; re-run approve once bd is healthy)"
        exit 3
    fi

    # The two counters the approve envelope has always reported. Derived from what
    # the sweep actually removed rather than from a has_label captured at the top
    # of this function, which is a slightly sharper claim: it reports the state
    # transition this call performed, not a presence check taken several refusals
    # and one record write earlier.
    local removed_entered=0 removed_pending=0
    case " $TERMINAL_SWEEP_REMOVED " in *" qa-gate-entered "*) removed_entered=1 ;; esac
    case " $TERMINAL_SWEEP_REMOVED " in *" qa-pending "*) removed_pending=1 ;; esac
    local sweep_obs="; cycle labels cleared: [${TERMINAL_SWEEP_REMOVED:-none}]"

    # ---- TRACKING-STATE FINALIZATION (gz3 ordering rules 2 and 4) ---------
    # Runs AFTER every step that can roll back (rule 4), and in the order
    # baseline-then-tracker (rule 2). Read the APPROVE-COMMIT ORDER note above
    # before reordering either of these two lines.

    # 0wk.2 fix: snapshot current git status to the gate baseline. Subsequent
    # Stop hook fires compare git status against this baseline and only
    # block if NEW uncommitted entries appear. Closes 0wk.2.
    #
    # FULL refresh (no --if-missing, no --exclude-tracked): approve means
    # "everything dirty right now has been reviewed", so the whole working
    # tree is the new reference point. Paired with the tracker truncation
    # below, a fresh approval starts a clean cycle.
    #
    # gz3: this MUST precede truncate_changed_files_tracker. An empty tracker
    # paired with a stale baseline is the state that made a Stop conclude
    # "un-baselined dirt, no bound approval" for work that had just been
    # approved; in this order that pairing is unreachable.
    if ! write_gate_baseline "qa-gate-approve"; then
        log_sync_error "approve: gate-baseline refresh failed for $tid (subsequent Stops will treat existing git dirt as new)"
    fi

    # 0wk.2 fix: truncate changed-files.txt - paired with the baseline, this
    # means a fresh approval starts a clean tracker. Closes 0wk.2.
    #
    # 3mg.2, load-bearing consequence (verified live): after this truncation a
    # recompute IN THIS CHECKOUT yields the EMPTY-LIST hash, never the approved
    # one. So the Stop hook's cross-worktree resolution can NOT re-derive an
    # approval by re-running --hash-only in the approving worktree; it must read
    # the persisted `impact-report-<tid>.json` (which survives approve and
    # carries both the approved hash and the approved file list). If you ever
    # make this truncation conditional, re-check that assumption first.
    truncate_changed_files_tracker

    # ---- SESSION STATE (gz3 ordering rule 3) ------------------------------
    # F3 + F4: clear active task and wipe per-iteration state. Still the LAST
    # side effects — if a previous step failed and rolled back we never reach
    # here, so a failed approval never wipes state — but now also strictly after
    # the tracking-state finalization above. Clearing current-task while a change
    # set was still visible made a concurrent Stop block with "No active Beads
    # task detected"; after the truncation there is nothing left to gate, so a
    # missing task id cannot produce a block.
    # Pass tid so wipe_iteration_state can clear the per-task counter
    # (Phase 4 fix pass / MATERIAL 5).
    clear_current_task
    wipe_iteration_state "$tid"

    # V3 (jio.1): the review round is over — drop its on-disk scratch files.
    # Deliberately NOT folded into wipe_iteration_state: that helper also runs
    # on `enter` and `choose continue`, and a continuing review round still
    # wants its request/artifact files on disk for the packet. Only a
    # COMPLETED approval ends the round. (Safe here: the review predicate reads
    # the durable Beads REVIEW-ARTIFACT records, never these files, so wiping
    # them cannot flip a concurrent Stop's review-discipline verdict.)
    wipe_review_artifacts "$tid"

    # Spec Phase A: build the rubric observation. The WARNING is the
    # loud signal the spec asks for when approve runs without a
    # satisfied verdict — the QA agent's prompt enforces the override
    # reason; we just surface the state.
    local rubric_obs=""
    if [ "$had_rubric_satisfied" = "1" ]; then
        # R2-F2: the claim is hash-checked now, not taken from the label.
        if [ "$rubric_mismatch" = "1" ]; then
            rubric_obs="; WARNING rubric-satisfied is set, but the satisfied verdict binds a DIFFERENT change set (graded=$rubric_graded_hash, approved=$approved_hash) — this approval covers work the grader did not see, so the approval comment must include an explicit override reason per spec Phase A / qa.md 6f; the mismatch is recorded in the approval record. To approve on a fresh verdict instead, re-run the rubric relay for the current change set"
        elif [ -z "$rubric_graded_hash" ]; then
            rubric_obs="; rubric-satisfied preserved (audit trail) — NOTE the verdict carries no change-set binding (pre-v4.1 record, or the hash was unavailable when it was recorded), so it could not be checked against this approval"
        else
            rubric_obs="; rubric-satisfied preserved (audit trail) and VERIFIED against this approval — the satisfied verdict binds the same change set (change_set_hash=$approved_hash)"
        fi
    elif [ "$had_rubric_pending" = "1" ]; then
        rubric_obs="; WARNING approving with rubric-pending still set (no satisfied verdict on file) — the QA approval comment must include an explicit override reason per spec Phase A; rubric-pending cleared as cycle ends"
    else
        rubric_obs="; no rubric labels present at approve (likely pre-Phase-A task)"
    fi

    # llh.18: surface whether the approval was bound to a change-set hash.
    local binding_obs
    if [ -n "$approved_hash" ]; then
        binding_obs="; change-set-bound approval record written (change_set_hash=$approved_hash) — verify-before-stop will release only while the current change-set matches this hash"
    else
        binding_obs="; WARNING approval comment written WITHOUT a change-set binding (hash unavailable) — verify-before-stop cannot match it; re-run approve once impact-report.sh is restored"
    fi

    # ${reconcile_obs:-} and ${reconstructed_obs:-} expand to empty when their
    # sentinel regions (TRACKER-RECONCILE / CHANGE-SET-RECONSTRUCTED) are stripped
    # by a META-TEST, keeping the stripped copy's envelope coherent.
    #
    # `removed qa-gate-entered=` and `removed qa-pending=` are PRESERVED VERBATIM
    # across the 8zi rewrite. Worth recording what that preservation is and is not
    # based on: a full-tree search for either literal (and for the shorter
    # `qa-gate-entered=` / `qa-pending=` forms) finds NO consumer anywhere —
    # not a spec, not a doc, not an agent prompt, not a hook. The only hits are
    # this line, the mirrored fixture copies of this script under
    # .claude/tests/e2e/fixtures/, and historical artifacts (grading-packet diffs,
    # mutation-run mutant dumps, one captured e2e transcript). They are kept
    # because keeping them is free and an operator may well be greping them from
    # memory; they are NOT kept because a test pins them. $sweep_obs is the token
    # that reports the FULL cleared set, which is what the counters cannot.
    emit_json 1 "approve" "$tid" "approved" "qa-approved set; removed qa-gate-entered=$removed_entered qa-pending=$removed_pending; summary recorded; current-task + iteration state cleared (escalation labels also cleared if present)$sweep_obs$rubric_obs${reconcile_obs:-}${reconstructed_obs:-}$impact_obs$review_obs$binding_obs${expect_hash_obs:-}$stale_label_obs"
}

# Phase 5 / E8: write a feedback-type memory entry when a block fires. The
# entry lives at ~/.claude/projects/<project-slug>/memory/qa-block-<fp>.md
# so subsequent sessions on the same project surface the pattern. Across
# repeats, the orchestrator can read these and pre-warn before delegating.
#
# The fingerprint is a short hash of the first 80 chars of the reason; the
# 60-char description is the first 60 chars truncated at a word boundary.
write_qa_block_memory() {
    local tid="$1"
    local reason="$2"
    local memory_dir
    # Derive the project slug the same way Claude Code does:
    # /Users/foo/Desktop/projects/bar -> -Users-foo-Desktop-projects-bar
    # The slug is the project path with `/` replaced by `-` and a leading `-`.
    local slug
    slug=$(printf '%s' "$PROJECT_DIR" | sed -e 's|/|-|g')
    memory_dir="$HOME/.claude/projects/${slug}/memory"

    mkdir -p "$memory_dir" 2>/dev/null || {
        log_sync_error "qa-block memory: mkdir $memory_dir failed; skipping write"
        return 1
    }

    # 1. Fingerprint: short SHA1 of the reason head. We use the first 80 chars
    #    so two blocks with the same root cause but different prose tails
    #    collapse to the same memory file (idempotent / dedup-friendly).
    local fp_input fp
    fp_input=$(printf '%s' "$reason" | head -c 80)
    if command -v shasum >/dev/null 2>&1; then
        fp=$(printf '%s' "$fp_input" | shasum -a 1 2>/dev/null | awk '{print $1}' | cut -c1-8)
    elif command -v sha1sum >/dev/null 2>&1; then
        fp=$(printf '%s' "$fp_input" | sha1sum 2>/dev/null | awk '{print $1}' | cut -c1-8)
    else
        # Last-resort fingerprint: tr/tail-based hex-ish slug.
        fp=$(printf '%s' "$fp_input" | tr -dc 'a-zA-Z0-9' | head -c 8)
    fi
    [ -z "$fp" ] && fp="unknown"

    # 2. Description: first 60 chars of reason, single line, no quotes.
    local desc
    desc=$(printf '%s' "$reason" | tr '\n' ' ' | tr -s ' ' | cut -c1-60 | sed -e 's/[[:space:]]*$//' -e 's/"/'"'"'/g')

    local memory_file="$memory_dir/qa-block-${fp}.md"

    # 3. Idempotent: if the file exists, refresh ONLY the trailing
    #    "Last seen: <ts>; Task: <id>" block. The body of the entry stays
    #    stable across re-blocks of the same pattern.
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ -f "$memory_file" ]; then
        # Append a "Last seen" line if the file does not already end with one
        # for this exact ts/tid pair.
        if ! grep -qF "Last seen: $ts; Task: $tid" "$memory_file" 2>/dev/null; then
            printf '\nLast seen: %s; Task: %s\n' "$ts" "$tid" >> "$memory_file" 2>/dev/null \
                || log_sync_error "qa-block memory: append to $memory_file failed"
        fi
        return 0
    fi

    # 4. New entry. Use the canonical feedback frontmatter shape per the
    #    auto-memory spec at the top of the system prompt.
    cat > "$memory_file" <<EOF
---
name: qa-block-${fp}
description: ${desc}
type: feedback
---

QA blocked task ${tid} for: ${reason}

Why: This pattern surfaced as a QA-gate block during the workflow. Recurring
matches indicate a systemic issue that should be checked before similar
future tasks are delegated.

How to apply: When working on similar future tasks (same domain, similar
diff shape), pre-check for this issue before declaring complete. If the
orchestrator opens a Beads task whose description or scope resembles the
block reason above, surface this memory entry as part of the delegation
brief.

First seen: ${ts}; Task: ${tid}
EOF

    if [ ! -s "$memory_file" ]; then
        log_sync_error "qa-block memory: write of $memory_file produced empty file"
        return 1
    fi

    # 5. Update MEMORY.md index. Idempotent — only add the line if not
    #    already present. Create MEMORY.md with a stub if it doesn't exist
    #    so the entry has a home.
    local index="$memory_dir/MEMORY.md"
    if [ ! -f "$index" ]; then
        cat > "$index" <<'EOF_INDEX'
# Memory Index

## Feedback

EOF_INDEX
    fi

    local index_line="- [qa-block-${fp}.md](qa-block-${fp}.md) - ${desc}"
    if ! grep -qF "qa-block-${fp}.md" "$index" 2>/dev/null; then
        # Try to insert under the "## Feedback" section if it exists; else
        # append.
        if grep -q '^## Feedback' "$index" 2>/dev/null; then
            # awk-based insert: print existing lines, and after the first
            # "## Feedback" header insert our line if not already present.
            if awk -v line="$index_line" '
                BEGIN{ inserted=0 }
                /^## Feedback/ && !inserted { print; print ""; print line; inserted=1; next }
                { print }
                END{ if (!inserted) print line }
            ' "$index" > "$index.tmp" 2>/dev/null; then
                mv "$index.tmp" "$index" 2>/dev/null \
                    || log_sync_error "qa-block memory: mv of awk output failed"
            else
                log_sync_error "qa-block memory: index update via awk failed; appending"
            fi
        else
            printf '\n%s\n' "$index_line" >> "$index"
        fi
    fi

    return 0
}

cmd_block() {
    local tid="$1"
    shift || true
    local reason="$*"
    if [ -z "$tid" ] || [ -z "$reason" ]; then
        usage
        exit 1
    fi
    require_bd "block" "$tid"

    # The same one transition approve uses, with a deliberately NARROW clear set.
    #
    # WHAT BLOCK CLEARS: qa-approved, and nothing else. WHAT IT PRESERVES, and why
    # each is a decision rather than an omission:
    #   - qa-gate-entered — documented contract ("Keeps qa-gate-entered") so the
    #     cycle stays open until an approve or an unblock-and-approve ends it.
    #   - qa-pending — the task IS still pending review; a block sends it back to
    #     the specialist and it returns for re-review.
    #   - rubric-pending, qa-escalated, qa-deferred — a block happens mid-cycle, so
    #     the rubric loop and any J21 escalation are still live. No filed defect
    #     says otherwise, and clearing them here would be an unrequested lifecycle
    #     change.
    # Only qa-approved is contradictory with a block, and that one is not cosmetic
    # the way 8zi's own direction is: every label reader in the tree tests
    # qa-approved FIRST (cmd_status, epic-gate.sh's qa_state_of, statusline.sh's
    # two readers), so a block that leaves a prior qa-approved in place reports the
    # task as APPROVED. That is the fail-open twin of the fail-closed noise 8zi
    # describes, and it is why block gets the sweep too rather than just approve.
    local -a block_clear=()
    # TERMINAL-LABEL-SWEEP BEGIN (8zi)
    block_clear+=(qa-approved)
    # TERMINAL-LABEL-SWEEP END (8zi)
    if ! set_terminal_label "$tid" "qa-blocked" "${block_clear[@]}"; then
        log_sync_error "block: the terminal-label transition FAILED for $tid; $TERMINAL_SWEEP_OBS"
        emit_json 0 "block" "$tid" "error" "failed to set qa-blocked: $TERMINAL_SWEEP_OBS"
        exit 3
    fi
    local block_sweep_obs=""
    if [ -n "$TERMINAL_SWEEP_REMOVED" ]; then
        block_sweep_obs="; cleared a prior cycle's [$TERMINAL_SWEEP_REMOVED] — a block and an approval cannot both be current"
    fi

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    add_comment "$tid" "QA-GATE BLOCKED at $ts: $reason"

    # E8: write a feedback memory entry. Best-effort — failures are logged
    # to sync-errors.log but never block the gate transition.
    local memory_obs="qa-block memory entry written"
    if ! write_qa_block_memory "$tid" "$reason"; then
        memory_obs="qa-block memory write failed (see sync-errors.log)"
    fi

    emit_json 1 "block" "$tid" "blocked" "qa-blocked label set at $ts (qa-gate-entered preserved if present); ${memory_obs}${block_sweep_obs}"
}

# Spec 0.2: record a J21 decision while qa-escalated. Signature is
# intentionally uniform across the four choices so callers don't have to
# branch on the choice in their shell:
#
#   choose approve   <task-id> <note>
#   choose continue  <task-id> <note>
#   choose tech-debt <task-id> <description> [severity] [file:line] [effort]
#   choose defer     <task-id> <note>
#
# Every choice:
#   - emits a comment "QA-GATE CHOICE <choice> at <ts>: <note>"
#   - drives the side effects spec'd in 0.2 (label flips, counter resets,
#     tech-debt entry, etc.)
#   - prints a JSON envelope to stdout via emit_json
#
# Keep this thin (principle 7): comments + labels are the record. Per-choice
# bookkeeping (counter wipe, escalation clear) reuses the existing helpers
# so behaviour stays in lockstep with approve/enter.
cmd_choose() {
    local choice="${1:-}"
    local tid="${2:-}"
    if [ -z "$choice" ] || [ -z "$tid" ]; then
        usage
        exit 1
    fi
    # Validate choice up front so a typo like `chose` doesn't silently
    # create a comment with garbage and no side effect.
    case "$choice" in
        approve|continue|tech-debt|defer) ;;
        *)
            printf 'qa-gate.sh: unknown choose value: %s (expected approve|continue|tech-debt|defer)\n' \
                "$choice" >&2
            usage
            exit 1
            ;;
    esac
    shift 2 || true

    # Collect the trailing args. For most choices this is just a single
    # note; for tech-debt we additionally accept severity, file:line, effort.
    local note="${1:-}"
    [ -z "$note" ] && { usage; exit 1; }
    shift || true
    local td_severity="${1:-medium}"
    local td_fileline="${2:-<unknown>}"
    local td_effort="${3:-unknown}"

    require_bd "choose" "$tid"

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    add_comment "$tid" "QA-GATE CHOICE $choice at $ts: $note"

    case "$choice" in
        approve)
            # Option 1: accept findings. Delegate to the existing atomic
            # approve flow so the rollback contract stays intact. The
            # approve flow itself clears escalation labels + iteration
            # state (see remove_escalation_labels above).
            cmd_approve "$tid" "$note"
            return $?
            ;;
        continue)
            # Option 2: re-enter the fix loop. Clear escalation, reset
            # iteration counter so the next Stop runs the suite from
            # scratch. We do NOT touch qa-pending here — the loop is
            # alive again, the cycle just starts at iteration 0.
            remove_escalation_labels "$tid"
            wipe_iteration_state "$tid"
            emit_json 1 "choose" "$tid" "continue" "choose continue at $ts: escalation labels cleared, iteration counter reset"
            ;;
        tech-debt)
            # Option 3: convert findings to deferred debt. Calls
            # tech-debt.sh add --bd-task; clears escalation; resets
            # counter. Best-effort on the tech-debt write — failure is
            # logged but does not prevent the label/counter side effects
            # (a stuck escalation is worse than a missing row).
            local td_script="$PROJECT_DIR/.claude/scripts/tech-debt.sh"
            local td_obs=""
            if [ -x "$td_script" ]; then
                if ! "$td_script" add "$td_severity" "$td_fileline" "$td_effort" "$note" --bd-task >/dev/null 2>&1; then
                    td_obs="tech-debt.sh add failed (see sync-errors.log); "
                    log_sync_error "choose tech-debt: tech-debt.sh add failed for $tid (severity=$td_severity fileline=$td_fileline)"
                fi
            else
                td_obs="tech-debt.sh missing or not executable; "
                log_sync_error "choose tech-debt: $td_script missing or not executable"
            fi
            remove_escalation_labels "$tid"
            wipe_iteration_state "$tid"
            emit_json 1 "choose" "$tid" "tech-debt" "${td_obs}choose tech-debt at $ts: tech-debt row queued + escalation cleared"
            ;;
        defer)
            # Option 4: stop iterating; surface to user. Set qa-deferred
            # so verify-before-stop allows the next Stop. Leave
            # qa-pending in place per spec — the task stays open, just
            # quiet, until the user acts. Counter is NOT reset here:
            # SessionStart can show "deferred at iteration N" usefully.
            local def_warn=""
            if ! add_label "$tid" "qa-deferred"; then
                def_warn=" WARNING: failed to add qa-deferred label; verify-before-stop may still block."
                log_sync_error "choose defer: failed to add qa-deferred label on $tid"
            fi
            emit_json 1 "choose" "$tid" "deferred" "choose defer at $ts: qa-deferred label set; qa-pending preserved; verify-before-stop will allow next Stop.$def_warn"
            ;;
    esac
}

# Spec Phase A: record a grader verdict.
#
# Input shape: strict JSON, read from `--file <path>` if provided, else
# stdin. The agent-facing contract is "paste the grader's JSON output",
# so both forms exist — file for scripting/replay, stdin for the natural
# pipe pattern (`grader_output | qa-gate.sh grade-record <tid>`).
#
# We deliberately keep this thin (principle 7): the Beads comment + label
# flip ARE the record. No internal state file is written; SessionStart and
# the QA agent's grading loop both read state from Beads. Malformed input
# is rejected with a STRUCTURED JSON error envelope (emit_error_json) so
# the agent can re-prompt the grader with precision — agent-centric error
# messages per bd-mcp conventions.
#
# Side effects:
#   - always: append a comment
#       "RUBRIC <rubric_version> iteration <n>: <verdict>[ change_set_hash=<h>]
#        — <summary>"
#     where <summary> is "all criteria pass" for satisfied, or a
#     comma-joined list of failed criterion names for needs_revision, and
#     change_set_hash (bjx) names the change set that was graded — the token
#     is omitted when the hash cannot be computed. See the composition site
#     for why the token sits between the verdict and the em-dash.
#   - on `satisfied`: remove rubric-pending; add rubric-satisfied.
#   - on `needs_revision`: labels unchanged. The qa-blocked round-trip is
#     the QA agent's move (it writes the block comment with required_fixes
#     and calls `qa-gate.sh block`); grade-record never sets qa-blocked.
cmd_grade_record() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        # Use stderr usage; emit a stdout JSON envelope for machine consumers.
        usage
        emit_error_json "grade-record" "" "missing_task_id" \
            "grade-record requires <task-id> as first positional argument" \
            "qa-gate.sh grade-record <task-id> [--file <path>]"
        exit 1
    fi
    shift || true

    # Parse optional --file flag. We do this manually (no getopts) to
    # match the shell-style of the rest of this script and so a typo
    # surfaces as a structured error rather than a getopts quirk.
    local input_path=""
    local graded_hash_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --file)
                input_path="${2:-}"
                if [ -z "$input_path" ]; then
                    emit_error_json "grade-record" "$tid" "missing_file_path" \
                        "--file requires a path argument" \
                        "qa-gate.sh grade-record $tid --file <path>"
                    exit 1
                fi
                shift 2 || true
                ;;
            --graded-hash)
                # R2-F1: the change set the grader ACTUALLY saw, taken from the
                # grading packet by the relay. See the binding block below for
                # why a recompute at record time is not the same thing.
                graded_hash_arg="${2:-}"
                if [ -z "$graded_hash_arg" ]; then
                    emit_error_json "grade-record" "$tid" "missing_graded_hash" \
                        "--graded-hash requires a value (the change_set_hash from the grading packet's impact report)" \
                        "qa-gate.sh grade-record $tid --graded-hash <hash>"
                    exit 1
                fi
                # Validated for the same reason rubric_version is: this value is
                # interpolated into the record's machine prefix, so anything
                # carrying a space could relocate a field boundary.
                case "$graded_hash_arg" in
                    *[!A-Za-z0-9-]*)
                        emit_error_json "grade-record" "$tid" "graded_hash_invalid_chars" \
                            "--graded-hash='$graded_hash_arg' contains characters outside [A-Za-z0-9-]; it is written into the RUBRIC record's machine prefix" \
                            "pass the change_set_hash verbatim from the grading packet's impact report"
                        exit 1
                        ;;
                esac
                shift 2 || true
                ;;
            -h|--help)
                usage
                exit 1
                ;;
            *)
                emit_error_json "grade-record" "$tid" "unknown_flag" \
                    "unknown argument: $1 (expected --file <path>, --graded-hash <hash>, or stdin)" \
                    "qa-gate.sh grade-record $tid [--file <path>] [--graded-hash <hash>]"
                exit 1
                ;;
        esac
    done

    require_bd "grade-record" "$tid"

    # Read the verdict JSON. --file takes precedence; stdin is the default.
    local raw=""
    if [ -n "$input_path" ]; then
        if [ ! -f "$input_path" ]; then
            emit_error_json "grade-record" "$tid" "file_not_found" \
                "verdict file does not exist: $input_path" \
                "qa-gate.sh grade-record $tid --file <existing-path>"
            exit 1
        fi
        if ! raw=$(cat -- "$input_path" 2>/dev/null); then
            emit_error_json "grade-record" "$tid" "file_unreadable" \
                "could not read verdict file: $input_path" \
                "qa-gate.sh grade-record $tid --file <readable-path>"
            exit 1
        fi
    else
        # Read all of stdin. tty detection: if stdin is a terminal, the
        # caller almost certainly forgot --file; bail with a helpful
        # message rather than hanging on a read.
        if [ -t 0 ]; then
            emit_error_json "grade-record" "$tid" "no_input" \
                "no --file given and stdin is a terminal; pipe the grader JSON or pass --file <path>" \
                "qa-gate.sh grade-record $tid --file <path>  OR  printf '%s' \"\$JSON\" | qa-gate.sh grade-record $tid"
            exit 1
        fi
        raw=$(cat)
    fi

    if [ -z "$raw" ]; then
        emit_error_json "grade-record" "$tid" "empty_input" \
            "verdict input is empty" \
            "qa-gate.sh grade-record $tid --file <path>  OR  stdin pipe"
        exit 1
    fi

    # Validate the JSON parses at all. jq -e exits 1 on parse error AND on
    # `false`/`null` result; we want the parse-error case only here, so we
    # short-circuit with a `type` check that returns a string for every
    # valid JSON value.
    if ! printf '%s' "$raw" | jq -e 'type' >/dev/null 2>&1; then
        emit_error_json "grade-record" "$tid" "invalid_json" \
            "verdict input is not valid JSON" \
            "expected a JSON object with keys verdict, criterion_results, required_fixes, iteration, rubric_version"
        exit 1
    fi

    # Top-level must be an object.
    local top_type
    top_type=$(printf '%s' "$raw" | jq -r 'type' 2>/dev/null || echo "unknown")
    if [ "$top_type" != "object" ]; then
        emit_error_json "grade-record" "$tid" "not_an_object" \
            "verdict input top-level is $top_type, expected object" \
            "expected a JSON object with keys verdict, criterion_results, required_fixes, iteration, rubric_version"
        exit 1
    fi

    # Validate each required key. We check existence + type per key so
    # the QA agent learns exactly what to fix. The error keys are stable
    # enough for the agent to branch on.
    local has_key
    for key in verdict criterion_results required_fixes iteration rubric_version; do
        has_key=$(printf '%s' "$raw" | jq -r --arg k "$key" 'has($k)' 2>/dev/null || echo "false")
        if [ "$has_key" != "true" ]; then
            emit_error_json "grade-record" "$tid" "missing_key:$key" \
                "verdict input missing required key: $key" \
                "required keys: verdict, criterion_results, required_fixes, iteration, rubric_version"
            exit 1
        fi
    done

    # verdict must be one of the two allowed strings.
    local verdict
    verdict=$(printf '%s' "$raw" | jq -r '.verdict' 2>/dev/null || echo "")
    case "$verdict" in
        satisfied|needs_revision) ;;
        *)
            emit_error_json "grade-record" "$tid" "verdict_invalid_enum" \
                "verdict='$verdict' is not in the allowed enum {satisfied, needs_revision}" \
                "set .verdict to either \"satisfied\" or \"needs_revision\""
            exit 1
            ;;
    esac

    # criterion_results must be an array of {criterion, pass, justification}.
    local cr_type
    cr_type=$(printf '%s' "$raw" | jq -r '.criterion_results | type' 2>/dev/null || echo "unknown")
    if [ "$cr_type" != "array" ]; then
        emit_error_json "grade-record" "$tid" "criterion_results_not_array" \
            "criterion_results is type=$cr_type, expected array" \
            "criterion_results must be an array of {criterion, pass, justification} objects"
        exit 1
    fi

    # Validate the per-item shape. We allow an empty array (a rubric with
    # zero criteria is degenerate but not corrupt). For non-empty arrays,
    # every element must be an object carrying criterion (string),
    # pass (boolean), justification (string).
    local cr_invalid
    cr_invalid=$(printf '%s' "$raw" | jq -r '
        .criterion_results
        | map(
            if type != "object" then "item_not_object"
            elif (has("criterion") and (.criterion | type == "string")) | not then "missing_or_bad_criterion"
            elif (has("pass") and (.pass | type == "boolean")) | not then "missing_or_bad_pass"
            elif (has("justification") and (.justification | type == "string")) | not then "missing_or_bad_justification"
            else "ok"
            end
        )
        | map(select(. != "ok"))
        | .[0] // ""
    ' 2>/dev/null || echo "")
    if [ -n "$cr_invalid" ]; then
        emit_error_json "grade-record" "$tid" "criterion_results_item_invalid:$cr_invalid" \
            "criterion_results contains an invalid item: $cr_invalid" \
            "every criterion_results item must be {criterion: string, pass: boolean, justification: string}"
        exit 1
    fi

    # required_fixes must be an array (may be empty).
    local rf_type
    rf_type=$(printf '%s' "$raw" | jq -r '.required_fixes | type' 2>/dev/null || echo "unknown")
    if [ "$rf_type" != "array" ]; then
        emit_error_json "grade-record" "$tid" "required_fixes_not_array" \
            "required_fixes is type=$rf_type, expected array" \
            "required_fixes must be an array (empty array allowed for satisfied)"
        exit 1
    fi

    # iteration must be a number, and — R2-F3 — an INTEGER one. The 0.2
    # escalation cap is still the agent's concern, not ours; the constraint here
    # is purely about the record grammar.
    #
    # It used to accept any JSON number and interpolate the raw value, while the
    # reader requires `[0-9]+` immediately followed by a colon. `1.5` therefore
    # produced a record the reader could not parse — and, before the selector
    # fix above, an unparseable LATEST record made the reader fall back to an
    # older one, so a needs_revision at iteration 1.5 failed to supersede the
    # satisfied verdict before it. Same lesson as rubric_version: the writer
    # must not be able to mint a record its own reader cannot read.
    #
    # This is the DEFENCE-IN-DEPTH half of R2-F3, not the fix. It stops the tool
    # creating unparseable records; it can do nothing about the ones it did not
    # create (legacy records, hand-written comments), which is why the selector
    # above had to change too. Verified in that order rather than assumed.
    local it_type it_val
    it_type=$(printf '%s' "$raw" | jq -r '.iteration | type' 2>/dev/null || echo "unknown")
    if [ "$it_type" != "number" ]; then
        emit_error_json "grade-record" "$tid" "iteration_not_number" \
            "iteration is type=$it_type, expected number" \
            "iteration must be a JSON number (1, 2, 3, ...)"
        exit 1
    fi
    it_val=$(printf '%s' "$raw" | jq -r '.iteration' 2>/dev/null || echo "?")
    case "$it_val" in
        ''|*[!0-9]*)
            emit_error_json "grade-record" "$tid" "iteration_not_integer" \
                "iteration=$it_val is not a non-negative integer; it is interpolated into the RUBRIC record's machine prefix, which the reader parses as [0-9]+ followed immediately by a colon — a value like 1.5 or 1e3 writes a record that cannot be read back and so cannot supersede an earlier verdict" \
                "iteration must be a non-negative integer (1, 2, 3, ...)"
            exit 1
            ;;
    esac

    # rubric_version must be a non-empty string.
    local rv_type rv_val
    rv_type=$(printf '%s' "$raw" | jq -r '.rubric_version | type' 2>/dev/null || echo "unknown")
    if [ "$rv_type" != "string" ]; then
        emit_error_json "grade-record" "$tid" "rubric_version_not_string" \
            "rubric_version is type=$rv_type, expected string" \
            "rubric_version must be a string (e.g. \"v1\")"
        exit 1
    fi
    rv_val=$(printf '%s' "$raw" | jq -r '.rubric_version' 2>/dev/null || echo "")
    if [ -z "$rv_val" ]; then
        emit_error_json "grade-record" "$tid" "rubric_version_empty" \
            "rubric_version is the empty string" \
            "rubric_version must be a non-empty string (e.g. \"v1\")"
        exit 1
    fi

    # bjx: rubric_version is the ONLY machine-prefix field of the RUBRIC record
    # that came from the grader, and it is interpolated with a space on each
    # side. Validated merely as "non-empty string" it was a GRAMMAR INJECTION:
    # the reader parses the verdict from immediately after the record's first
    # colon, so a version of the form
    #     1 iteration 1: satisfied change_set_hash=<the real current hash>
    # relocated that colon into the injected text, and a needs_revision verdict
    # was read back as satisfied AND bound to the current change set — enough to
    # carry a rubric-satisfied label across a re-enter that should have cleared
    # it. Reproduced end-to-end with a causation control (only the version
    # differed) and pinned in section I of
    # .claude/tests/component/specs/rubric-binding.sh.
    #
    # The class below has no space and no colon, so no value that passes here
    # can move a field boundary. It is deliberately the WRITER's job: the reader
    # cannot distinguish an injected prefix from a real one after the fact, so a
    # reader-only class would narrow the grammar without closing anything. The
    # reader carries the SAME class for parity (latest_satisfied_rubric_hash),
    # and section F asserts the two spellings match.
    #
    # Rejecting rather than sanitising: a silently-rewritten version would make
    # the record disagree with the verdict JSON the grader actually emitted,
    # and the structured envelope is what lets the orchestrator re-prompt with
    # precision (spec Phase A).
    case "$rv_val" in
        *[!A-Za-z0-9._+-]*)
            emit_error_json "grade-record" "$tid" "rubric_version_invalid_chars" \
                "rubric_version='$rv_val' contains characters outside [A-Za-z0-9._+-]; it is interpolated into the RUBRIC record's machine prefix, where a space or a colon would move a field boundary and let the recorded verdict be read back as a different one" \
                "rubric_version must match ^[A-Za-z0-9._+-]+$ (e.g. \"1\", \"v1\", \"1.2\")"
            exit 1
            ;;
    esac

    # Build the one-line summary. For satisfied, the summary is the fixed
    # "all criteria pass" string. For needs_revision, we list the criterion
    # names whose pass is false; if the grader marked needs_revision without
    # any failing criteria (degenerate but not corrupt), we fall back to
    # the required_fixes count.
    local summary
    if [ "$verdict" = "satisfied" ]; then
        summary="all criteria pass"
    else
        # Comma-join the failed criterion names. Defensive: if no failures
        # were listed, use the required_fixes count as a hint.
        local failed_names
        failed_names=$(printf '%s' "$raw" \
            | jq -r '[.criterion_results[] | select(.pass == false) | .criterion] | join(", ")' \
            2>/dev/null || echo "")
        if [ -n "$failed_names" ]; then
            summary="failed: $failed_names"
        else
            local rf_count
            rf_count=$(printf '%s' "$raw" | jq -r '.required_fixes | length' 2>/dev/null || echo "0")
            summary="needs_revision (no failing criteria listed; required_fixes count=$rf_count)"
        fi
    fi

    # Compose and post the comment. Format matches the spec exactly:
    # RUBRIC <rubric_version> iteration <n>: <verdict>[ change_set_hash=<h>] — <summary>
    #
    # bjx (v4.1 U1): the verdict now names the CHANGE SET it graded. A verdict
    # is an opinion about a specific diff, and the only durable statement of
    # which diff that was is this token — the same binding llh.18 put on the
    # approval record and jio.1 put on the review artifact (`reviewed_hash`).
    # `enter` reads it back (latest_satisfied_rubric_hash) to tell a verdict
    # that still covers the current work from one left over from a previous
    # change set; before it existed, `enter` could only assume the latter and
    # cleared rubric-satisfied unconditionally.
    #
    # PLACEMENT is a compatibility contract, and the same one cmd_approve
    # documents for its own record: the machine token goes AFTER the verdict
    # and BEFORE the em-dash, i.e. ahead of all free text. Every existing
    # reader keys on the prefix through the verdict — qa.md 6c's
    # `test("^RUBRIC [0-9]+ iteration")`, the L1 spec's
    # `^RUBRIC v1 iteration 1: satisfied`, rubric-loop.sh's
    # `RUBRIC 1 iteration 1: needs_revision` — so appending here leaves all of
    # them matching, while putting it after the summary would bury a machine
    # field inside grader-authored prose.
    #
    # Recorded on BOTH verdicts, not just satisfied: "which change set was
    # found wanting" is exactly as much of an audit question as "which one
    # passed", and the reader filters on the verdict itself.
    #
    # Best-effort, mirroring approve's hash_field: an unavailable hash omits
    # the token rather than writing a placeholder, because a token that does
    # not name a real change set would read as a binding to something. The
    # unbound record then behaves precisely as a pre-bjx one does — enter
    # cannot prove it covers the current work, so it clears.
    #
    # bjx: "unavailable" has TWO spellings. impact-report.sh returns empty when
    # it cannot run at all, and the CONSTANT $CHANGE_SET_HASH_UNAVAILABLE when
    # it runs on a host carrying neither shasum nor sha256sum. Only the first
    # was excluded by `[ -n ... ]`; the second is a non-empty string that would
    # be recorded as a binding and then compare EQUAL to itself at enter time,
    # preserving every verdict unconditionally on such a host. Both spellings
    # omit the token, which is what the paragraph above already promised.
    #
    # R2-F1 — WHERE THE HASH COMES FROM, which is the whole meaning of the
    # token. This used to be a live recompute of the tracker AT RECORD TIME.
    # That is not "the change set that was graded": grade-record runs after QA
    # assembled the packet and after the grader ran, so any path that landed in
    # between was silently folded into the binding. A verdict for set A was
    # recorded as covering A+B. Reproduced directly — packet hash 8685efdc,
    # record bound to e7bfaafe — and it is NOT the documented path-scoped
    # limitation: that one is about contents, this one leaked whole PATHS into
    # a verdict that never saw them.
    #
    # Three sources, in descending order of authority:
    #
    #   1. --graded-hash, passed by the relay from the grading packet's impact
    #      report (orchestrator.md 5a step C). This is the only value that
    #      actually witnesses what the grader was shown, so it wins outright.
    #      It cannot come from the grader's own JSON: that would let the graded
    #      party state what it graded, and it would change grader.md's schema.
    #
    #   2. A live recompute CORROBORATED by the persisted impact report. If the
    #      report the packet was built from still describes the current change
    #      set, then nothing was added between assembly and now, and the live
    #      value is the graded one. This is what makes the flag optional without
    #      making it a lie — the common relay, where nothing moves, still binds.
    #
    #   3. Nothing. If they DISAGREE, the change set moved and we cannot say
    #      which set was graded, so the record is written UNBOUND with the two
    #      hashes named. Unbound is not a failure mode: enter treats it as
    #      stale and clears, i.e. the pre-bjx behaviour, and approve's
    #      cross-check (R2-F2) has nothing to contradict.
    #
    # Note what case 2 still cannot see: if the persisted report was itself
    # REGENERATED after the packet was assembled (an `enter` between steps C
    # and D does exactly that), it agrees with live while describing a set the
    # grader never saw. That residual is why R2-F2's cross-check at approve
    # exists — the two findings are one gap at two ends, and only the flag
    # closes it at this end. The relay passes the flag; the fallback keeps an
    # un-updated caller honest rather than silently wrong.
    local graded_hash="" hash_token="" binding_source=""
    if [ -n "$graded_hash_arg" ]; then
        graded_hash="$graded_hash_arg"
        binding_source="--graded-hash supplied by the relay (the grading packet's change set)"
    else
        local live_hash="" persisted_hash=""
        live_hash=$(compute_change_set_hash) || live_hash=""
        persisted_hash=$(persisted_report_hash "$tid") || persisted_hash=""
        if [ -n "$live_hash" ] && [ "$live_hash" = "$persisted_hash" ]; then
            graded_hash="$live_hash"
            binding_source="live recompute, corroborated by the persisted impact report (no path moved since the report the packet was built from)"
        else
            binding_source="none — the live change set (${live_hash:-<unavailable>}) and the persisted impact report (${persisted_hash:-<absent>}) disagree, so which set was graded cannot be established here; pass --graded-hash from the grading packet to bind it"
        fi
    fi
    if [ "$graded_hash" = "$CHANGE_SET_HASH_UNAVAILABLE" ]; then
        graded_hash=""
        binding_source="none — the change-set hash is unavailable on this host (no shasum/sha256sum)"
    fi
    if [ -n "$graded_hash" ]; then
        hash_token=" change_set_hash=$graded_hash"
    fi
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local comment_text
    comment_text="RUBRIC $rv_val iteration $it_val: $verdict$hash_token — $summary"
    add_comment "$tid" "$comment_text"

    # Label flip on satisfied. needs_revision leaves labels alone.
    local label_obs=""
    if [ "$verdict" = "satisfied" ]; then
        # Best-effort: remove rubric-pending and add rubric-satisfied.
        # We surface any individual failures in the observations so the
        # agent can re-run, but we don't roll back the comment — the
        # comment is the audit trail and is the source of truth even
        # if the label flip races.
        local removed_pending=1 added_satisfied=1
        remove_rubric_pending "$tid" || removed_pending=0
        if ! add_label "$tid" "rubric-satisfied"; then
            added_satisfied=0
            log_sync_error "grade-record: failed to add rubric-satisfied label on $tid"
        fi
        label_obs="rubric-pending removed=$removed_pending; rubric-satisfied added=$added_satisfied"
    else
        label_obs="labels unchanged (qa-blocked round-trip is the QA agent's move)"
    fi

    # bjx: name the binding (or its absence) in the envelope. An unbound
    # verdict is not an error — it is a verdict `enter` will not be able to
    # carry across a re-entry, and the operator should be able to see that
    # from the record-writing call rather than from a later surprise.
    local binding_obs
    if [ -n "$graded_hash" ]; then
        binding_obs="; verdict bound to the graded change set (change_set_hash=$graded_hash; source: $binding_source)"
    else
        binding_obs="; WARNING verdict recorded WITHOUT a change-set binding (source: $binding_source) — a re-enter cannot prove this verdict covers the current work, so rubric-satisfied will be cleared as stale and the next relay round will re-grade"
    fi

    emit_json 1 "grade-record" "$tid" "$verdict" \
        "comment posted at $ts: $comment_text; $label_obs$binding_obs"
}

# ---------------------------------------------------------------------------
# Phase V2 (1vq.1): reviewer-record writers. These append the LOAD-BEARING
# review record grammars (byte-exact V3 contracts) as Beads comments. They are
# record writers ONLY — no approve/Stop enforcement lives here (that is V3).
# Validation is delegated to review-check.sh (the ONE validator); this file
# never re-implements the schema and never references any reviewer transport.

# finding_id_in_latest_artifact <tid> <finding-id> -> 0 if the id appears in the
# findings=[...] token of the LATEST /^REVIEW-ARTIFACT v1 / comment.
finding_id_in_latest_artifact() {
    local tid="$1" fid="$2"
    local comments art token
    comments=$(bd_show_with_comments "$tid" \
        | jq -r 'if type=="array" then .[0].comments else .comments end | (.[]?.text // empty)' 2>/dev/null || echo "")
    art=$(printf '%s\n' "$comments" | grep -E '^REVIEW-ARTIFACT v1 ' | tail -1 || true)
    [ -z "$art" ] && return 1
    token=$(printf '%s' "$art" | sed -nE 's/.*findings=\[([^]]*)\].*/\1/p' || true)
    [ -z "$token" ] && return 1
    # One id per line (strip the :severity and any intra-token spaces). Use
    # sed (line-oriented) NOT `tr -d` so the per-id newlines survive — merging
    # the ids onto one line would make the exact-match grep below never hit.
    printf '%s' "$token" | tr ',' '\n' | sed -E 's/:.*//; s/[[:space:]]//g' | grep -qxF "$fid"
}

# review-record <tid> [--file <path>]: validate an artifact via review-check.sh
# then post the REVIEW-ARTIFACT v1 record comment. Mirrors grade-record's shape.
cmd_review_record() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "review-record" "" "missing_task_id" \
            "review-record requires <task-id> as first positional argument" \
            "qa-gate.sh review-record <task-id> [--file <path>]"
        exit 1
    fi
    shift || true

    local input_path=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --file)
                input_path="${2:-}"
                if [ -z "$input_path" ]; then
                    emit_error_json "review-record" "$tid" "missing_file_path" \
                        "--file requires a path argument" \
                        "qa-gate.sh review-record $tid --file <path>"
                    exit 1
                fi
                shift 2 || true
                ;;
            -h|--help) usage; exit 1 ;;
            *)
                emit_error_json "review-record" "$tid" "unknown_flag" \
                    "unknown argument: $1 (expected --file <path> or stdin)" \
                    "qa-gate.sh review-record $tid [--file <path>]"
                exit 1
                ;;
        esac
    done

    require_bd "review-record" "$tid"

    local raw=""
    if [ -n "$input_path" ]; then
        if [ ! -f "$input_path" ]; then
            emit_error_json "review-record" "$tid" "file_not_found" \
                "artifact file does not exist: $input_path" \
                "qa-gate.sh review-record $tid --file <existing-path>"
            exit 1
        fi
        if ! raw=$(cat -- "$input_path" 2>/dev/null); then
            emit_error_json "review-record" "$tid" "file_unreadable" \
                "could not read artifact file: $input_path" \
                "qa-gate.sh review-record $tid --file <readable-path>"
            exit 1
        fi
    else
        if [ -t 0 ]; then
            emit_error_json "review-record" "$tid" "no_input" \
                "no --file given and stdin is a terminal; pipe the artifact JSON or pass --file <path>" \
                "qa-gate.sh review-record $tid --file <path>  OR  printf '%s' \"\$JSON\" | qa-gate.sh review-record $tid"
            exit 1
        fi
        raw=$(cat)
    fi

    if [ -z "$raw" ]; then
        emit_error_json "review-record" "$tid" "empty_input" \
            "artifact input is empty" \
            "qa-gate.sh review-record $tid --file <path>  OR  stdin pipe"
        exit 1
    fi

    # Validate via the ONE validator (subprocess). No second schema here.
    local tmpf vout ok ekey
    tmpf=$(mktemp -t qa-gate-review.XXXXXX 2>/dev/null) || tmpf="$QA_TRACKING_DIR/.review-record-$$.json"
    printf '%s' "$raw" > "$tmpf"
    vout=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" validate-artifact "$tmpf" 2>/dev/null || true)
    rm -f "$tmpf" 2>/dev/null || true
    ok=$(printf '%s' "$vout" | jq -r '.ok // false' 2>/dev/null || echo "false")
    if [ "$ok" != "true" ]; then
        ekey=$(printf '%s' "$vout" | jq -r '.error_key // "invalid_artifact"' 2>/dev/null || echo "invalid_artifact")
        emit_error_json "review-record" "$tid" "$ekey" \
            "artifact failed validation via review-check.sh: $ekey" \
            "provide a valid review artifact (see review-check.sh validate-artifact schema)"
        exit 1
    fi

    # Extract the grammar fields from the validated artifact.
    local iter reviewer model hash rt verdict stopped findings_token fc summary ts comment_text
    iter=$(printf '%s' "$raw" | jq -r '.iterations' 2>/dev/null)
    reviewer=$(printf '%s' "$raw" | jq -r '.reviewer_identity' 2>/dev/null)
    model=$(printf '%s' "$raw" | jq -r '.reviewer_model' 2>/dev/null)
    hash=$(printf '%s' "$raw" | jq -r '.reviewed_hash' 2>/dev/null)
    rt=$(printf '%s' "$raw" | jq -r '.risk_threshold' 2>/dev/null)
    verdict=$(printf '%s' "$raw" | jq -r '.verdict' 2>/dev/null)
    stopped=$(printf '%s' "$raw" | jq -r '.stopped_by' 2>/dev/null)
    findings_token=$(printf '%s' "$raw" | jq -r 'if (.findings|length)==0 then "" else (.findings|map(.id+":"+.severity)|join(",")) end' 2>/dev/null)
    fc=$(printf '%s' "$raw" | jq -r '.findings | length' 2>/dev/null)
    if [ "$verdict" = "approve" ]; then
        summary="approve — no findings at/above $rt"
    else
        summary="findings — $fc finding(s) reported"
    fi
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="REVIEW-ARTIFACT v1 iteration=$iter reviewer=$reviewer model=$model reviewed_hash=$hash risk_threshold=$rt verdict=$verdict stopped_by=$stopped findings=[$findings_token] at $ts: $summary"
    add_comment "$tid" "$comment_text"
    emit_json 1 "review-record" "$tid" "recorded" "comment posted at $ts: $comment_text"
}

# resolve-finding <tid> <finding-id> --fix '<ref>' --test '<ref>' '<summary>'
cmd_resolve_finding() {
    local tid="${1:-}" fid="${2:-}"
    if [ -z "$tid" ] || [ -z "$fid" ]; then
        usage
        emit_error_json "resolve-finding" "$tid" "missing_args" \
            "resolve-finding requires <task-id> <finding-id> --fix <ref> --test <ref> <summary>" \
            "qa-gate.sh resolve-finding <tid> <finding-id> --fix '<ref>' --test '<ref>' '<summary>'"
        exit 1
    fi
    shift 2 || true
    local fix="" testref="" summary=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --fix)  fix="${2:-}"; shift 2 || true ;;
            --test) testref="${2:-}"; shift 2 || true ;;
            -h|--help) usage; exit 1 ;;
            *) summary="$1"; shift || true ;;
        esac
    done

    require_bd "resolve-finding" "$tid"

    if [ -z "$fix" ]; then
        emit_error_json "resolve-finding" "$tid" "empty_fix" \
            "--fix reference is empty; a resolution must cite the fix" \
            "qa-gate.sh resolve-finding $tid $fid --fix '<commit/path:line>' --test '<ref>' '<summary>'"
        exit 1
    fi
    if [ -z "$testref" ]; then
        emit_error_json "resolve-finding" "$tid" "empty_test" \
            "--test reference is empty; a resolution must cite the covering test" \
            "qa-gate.sh resolve-finding $tid $fid --fix '<ref>' --test '<test path/name>' '<summary>'"
        exit 1
    fi
    if ! finding_id_in_latest_artifact "$tid" "$fid"; then
        emit_error_json "resolve-finding" "$tid" "finding_id_not_found" \
            "finding id '$fid' is not present in the latest REVIEW-ARTIFACT comment for $tid" \
            "resolve only ids that appear in the latest review artifact's findings=[...] token"
        exit 1
    fi

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="RESOLVED $fid at $ts: fix=$fix test=$testref — $summary"
    add_comment "$tid" "$comment_text"
    emit_json 1 "resolve-finding" "$tid" "resolved" "comment posted at $ts: $comment_text"
}

# arbitrate <tid> <finding-id> <overrule|sustain> '<rationale>'
cmd_arbitrate() {
    local tid="${1:-}" fid="${2:-}" decision="${3:-}" rationale="${4:-}"
    if [ -z "$tid" ] || [ -z "$fid" ] || [ -z "$decision" ]; then
        usage
        emit_error_json "arbitrate" "$tid" "missing_args" \
            "arbitrate requires <task-id> <finding-id> <overrule|sustain> <rationale>" \
            "qa-gate.sh arbitrate <tid> <finding-id> <overrule|sustain> '<rationale>'"
        exit 1
    fi
    case "$decision" in
        overrule|sustain) ;;
        *)
            emit_error_json "arbitrate" "$tid" "decision_invalid_enum" \
                "decision '$decision' is not in {overrule, sustain}" \
                "qa-gate.sh arbitrate $tid $fid <overrule|sustain> '<rationale>'"
            exit 1
            ;;
    esac

    require_bd "arbitrate" "$tid"

    if [ -z "$rationale" ]; then
        emit_error_json "arbitrate" "$tid" "empty_rationale" \
            "arbitration rationale is empty; an arbitration decision must be justified" \
            "qa-gate.sh arbitrate $tid $fid $decision '<rationale>'"
        exit 1
    fi
    if ! finding_id_in_latest_artifact "$tid" "$fid"; then
        emit_error_json "arbitrate" "$tid" "finding_id_not_found" \
            "finding id '$fid' is not present in the latest REVIEW-ARTIFACT comment for $tid" \
            "arbitrate only ids that appear in the latest review artifact's findings=[...] token"
        exit 1
    fi

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="ARBITRATION $fid decision=$decision at $ts: $rationale"
    add_comment "$tid" "$comment_text"
    emit_json 1 "arbitrate" "$tid" "arbitrated" "comment posted at $ts: $comment_text"
}

# cmd_baseline_capture — write the gate baseline outside the enter/approve
# lifecycle (3mg.1). Exists so session-start.sh has ONE implementation to call
# instead of a second copy of the format; deliberately does NOT require bd
# (no task is involved) and never touches labels.
#
# Usage: qa-gate.sh baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]
cmd_baseline_capture() {
    local by="manual"
    local -a passthru
    passthru=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --by) by="${2:-manual}"; shift ;;
            --if-missing|--exclude-tracked) passthru+=("$1") ;;
            *)
                emit_error_json "baseline-capture" "" "unknown_flag" \
                    "unknown flag '$1'" \
                    "qa-gate.sh baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]"
                exit 1
                ;;
        esac
        shift
    done

    if write_gate_baseline "$by" ${passthru[@]+"${passthru[@]}"}; then
        # Counted through the ONE header-skip reader in this file
        # (gate_baseline_entries), not a second copy of its awk.
        local n="0"
        n=$(gate_baseline_entries | grep -c . | tr -d ' ')
        n="${n:-0}"
        emit_json 1 "baseline-capture" "" "captured" \
            "gate-baseline captured_by=$by entries=$n at $GATE_BASELINE_FILE"
        return 0
    fi
    emit_json 0 "baseline-capture" "" "error" \
        "gate-baseline capture failed (captured_by=$by); see sync-errors.log"
    exit 2
}

# TRACKER-RECONCILE BEGIN (94d)
# cmd_reconcile_tracker — the subcommand form of reconcile_tracker, so
# verify-before-stop.sh has ONE implementation to call instead of a second copy
# of the walk (the same reason cmd_baseline_capture exists for session-start.sh,
# and the same reason compute_change_set_hash defers to impact-report.sh
# --hash-only). Deliberately does NOT require bd: no task is involved, no label
# is touched, and the Stop hook must be able to run it on a repo with no Beads
# workspace at all.
#
# Exit codes: 0 reconciled (or legitimately nothing to do), 2 the reconcile
# could not be completed — the caller must treat that as refuse-to-proceed.
cmd_reconcile_tracker() {
    if [ "$#" -gt 0 ]; then
        emit_error_json "reconcile-tracker" "" "unknown_flag" \
            "unknown argument '$1'; reconcile-tracker takes none" \
            "qa-gate.sh reconcile-tracker"
        exit 1
    fi
    if reconcile_tracker; then
        emit_json 1 "reconcile-tracker" "" "reconciled" \
            "${RECONCILE_OBS:-nothing to reconcile} (added=$RECONCILE_ADDED)"
        return 0
    fi
    emit_error_json "reconcile-tracker" "" "tracker_unreconcilable" \
        "${RECONCILE_OBS:-tracker reconcile failed}; the change-set hash would certify less than the actual diff, so callers must refuse to proceed rather than bind an unproven change set" \
        "qa-gate.sh reconcile-tracker"
    exit 2
}
# TRACKER-RECONCILE END (94d)

# ---------------------------------------------------------------------------
# Dispatch

SUB="${1:-}"
shift || true

case "$SUB" in
    enter)        cmd_enter "$@" ;;
    baseline-capture) cmd_baseline_capture "$@" ;;
# TRACKER-RECONCILE BEGIN (94d)
    reconcile-tracker) cmd_reconcile_tracker "$@" ;;
# TRACKER-RECONCILE END (94d)
    status)       cmd_status "$@" ;;
    approve)      cmd_approve "$@" ;;
    block)        cmd_block "$@" ;;
    choose)       cmd_choose "$@" ;;
    grade-record) cmd_grade_record "$@" ;;
    review-record)   cmd_review_record "$@" ;;
    resolve-finding) cmd_resolve_finding "$@" ;;
    arbitrate)       cmd_arbitrate "$@" ;;
    ""|-h|--help|help)
        usage
        exit 1
        ;;
    *)
        echo "qa-gate.sh: unknown subcommand: $SUB" >&2
        usage
        exit 1
        ;;
esac

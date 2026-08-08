#!/bin/bash
# Stop Hook: MANDATORY QA GATE - Blocks until QA approval via Beads.
#
# Phase 4 (claude-workflow-plugin-y4a.10) - major rewrite layered on top
# of the Phase 1 corrections. New responsibilities:
#
#   F3   Single source of truth for current task id (current-task.sh).
#   B2   Epic-level e2e gate (epic-gate.sh) on task completion.
#   B3   Test/lint/type timeouts: 1200s tests, 300s lint, 600s type;
#        configurable outer wrapper timeout (default 60s wraps just the
#        non-test post-processing; the long ops are timed individually).
#   F8/J17 Polyglot test/lint command via detect-stack.sh.
#   F1   Doc-only fast path: auto-approve when changes are documentation
#        or comment-only.
#   J18  Intent-based specialist recommendation surfaced in block reasons.
#   J19  Iterative loop with regression coverage; iteration counter.
#   J21  Decision-gate options surfaced when there are findings post-pass.
#
# Phase 1 properties retained:
#   B1/D1/J2  Marker file bypass deleted; sole source of truth = qa-approved label.
#   B13       Comment-text fallback removed.
#   B6        Allowlist replaced with denylist over build/lock artifacts.
#   B8        Claude-friendly placeholder when no task is detected.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"
QA_GATE="$PROJECT_DIR/.claude/scripts/qa-gate.sh"
EPIC_GATE="$PROJECT_DIR/.claude/scripts/epic-gate.sh"
DETECT_STACK="$PROJECT_DIR/.claude/scripts/detect-stack.sh"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"

# Per-iteration artifacts. The iteration counter is keyed by task_id (Phase 4
# fix pass / MATERIAL 5): a per-task path so abandoning task A at iter=3 and
# switching to task B does NOT make B start at iter=4. Resolved later via
# iteration_file_for() once we know the current task id.
ITERATION_FILE_LEGACY="$QA_TRACKING_DIR/iteration-count"
TEST_LOG="$QA_TRACKING_DIR/last-test-output.log"
LINT_LOG="$QA_TRACKING_DIR/last-lint-output.log"
TYPE_LOG="$QA_TRACKING_DIR/last-type-output.log"

# Sanitize a task id into a filesystem-safe suffix. Beads ids are normally
# already safe (alpha-num + dot + dash) but we belt-and-brace.
sanitize_task_id() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Path to the iteration counter for a specific task id. When task is empty
# we fall back to the legacy path (preserves single-task behaviour for users
# with no Beads).
iteration_file_for() {
    local tid="$1"
    if [ -z "$tid" ]; then
        printf '%s' "$ITERATION_FILE_LEGACY"
    else
        printf '%s/iteration-count.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
    fi
}

# Tunable timeouts. The outer wrapper is for post-processing only — the
# long-running test/lint/type subprocesses use their own GNU `timeout`.
STOP_TIMEOUT_FILE="$QA_TRACKING_DIR/stop-timeout"
TEST_TIMEOUT_S=1200
LINT_TIMEOUT_S=300
TYPE_TIMEOUT_S=600

# Maximum iterations before escalating via the decision gate.
MAX_ITERATIONS=3

# 2ty: how many ESCALATED Stops may pass with no recorded J21 choice before the
# gate auto-selects option 4 (defer). This used to be expressed as
# `ITER > MAX_ITERATIONS + 1`, i.e. it borrowed the ITERATION counter to count
# "chances the agent has had to answer". Those are two different quantities, and
# conflating them is the defect this task exists for: once the iteration counter
# stopped charging Stops that run nothing, it stopped advancing under escalation
# at all, and auto-defer — a legitimate STOP-counting rule — would have silently
# become unreachable. So the two now count separately.
#
# 2 preserves the previous timing Stop-for-Stop: cap-hit Stop shows the J21
# options, the FIRST escalated Stop after it still blocks (one more chance to
# record a choice), the SECOND auto-defers.
AUTO_DEFER_AFTER_ESCALATED_STOPS=2

mkdir -p "$QA_TRACKING_DIR"

# sync-errors.log: surface silently-failing best-effort calls (write_current_task,
# bd update --status closed, qa-gate enter/approve, etc.). SessionStart can
# read this and present recent entries. Mirrors Phase 1 / B11.
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"
log_sync_error() {
    local msg="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    printf '%s\t[verify-before-stop]\t%s\n' "$ts" "$msg" >> "$SYNC_ERRORS_LOG" 2>/dev/null || true
}

# Denylist (B6).
#
# 3mg.1: the regex itself moved to `.claude/scripts/workflow-denylist.sh` —
# ONE definition shared with post-edit.sh (what gets tracked) and
# impact-report.sh (what enters the change-set hash). Before that, this copy
# was the only one carrying `.claude/worktrees/` and the e2e fixture-churn
# alternation, so post-edit tracked worktree paths INTO the hash that this
# gate could not see: the hash and the gate disagreed about the change set.
# The rationale for each pattern now lives in the lib's header.
#
# Resolved relative to THIS script (BASH_SOURCE), not $PROJECT_DIR: the gate
# may run with CLAUDE_PROJECT_DIR pointing at a different checkout than the
# install it was launched from.
#
# Missing lib: BLOCK (fail closed). Without the filter we cannot tell
# reviewable work from build churn, which makes the change set — and every
# decision derived from it — unverifiable. The block is emitted AFTER the
# stop_hook_active circuit breaker below, never before it: blocking ahead of
# that guard would re-enter the Stop hook forever (AgentLint H3). Until then
# is_tracked_change treats EVERYTHING as reviewable, which is the fail-closed
# direction if any caller runs before the block.
WORKFLOW_DENYLIST_MISSING=0
_WFDL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || _WFDL_DIR=""
if [ -n "$_WFDL_DIR" ] && [ -f "$_WFDL_DIR/workflow-denylist.sh" ]; then
    # shellcheck source=.claude/scripts/workflow-denylist.sh
    . "$_WFDL_DIR/workflow-denylist.sh"
fi
if [ -n "${WORKFLOW_DENYLIST_REGEX:-}" ]; then
    DENYLIST_REGEX="$WORKFLOW_DENYLIST_REGEX"
else
    WORKFLOW_DENYLIST_MISSING=1
    DENYLIST_REGEX=""
fi

is_tracked_change() {
    local p="$1"
    [ -z "$p" ] && return 1
    if [ "$WORKFLOW_DENYLIST_MISSING" = "1" ]; then
        # Unfiltered: treat every path as reviewable rather than guess.
        return 0
    fi
    if [[ "$p" =~ $DENYLIST_REGEX ]]; then
        return 1
    fi
    return 0
}

# DOC-CONTENT-VETO BEGIN (claude-workflow-plugin-bbh)
#
# IS THIS PATH AFFIRMATIVELY EXECUTABLE CONTENT?
#
# Two facts about the FILE, neither of them about its name or its position:
#   - the executable bit is set on a regular file, i.e. the operating system
#     will run it;
#   - its first two bytes are `#!`, i.e. it names its own interpreter.
#
# This is the half of claude-workflow-plugin-bbh that does not merely delete a
# bad inference. The arms that survive in is_doc_only_path still read a content
# type off a name — `*.md`, or the exact basename `LICENSE` — so a matching name
# is NECESSARY and must not be SUFFICIENT. A file the OS will execute is not
# documentation whatever it is called, and that is a question about the file.
#
# POSITIVE EVIDENCE ONLY. This is the one deliberate asymmetry and it is load-
# bearing in the availability direction. A path that does not resolve to a
# regular file yields no evidence either way, and the name arms then decide
# exactly as they did before. Three ordinary states reach that branch:
#   * a DELETION — `git status` reports ` D docs/old-guide.md`, reviewable_
#     changes strips the status prefix, and the path arrives here with nothing
#     behind it. Deleting documentation is a legitimate doc-only commit, and a
#     deleted file ships no content, so "unresolvable => reviewable" would
#     deadlock it while buying no safety at all.
#   * the old side of a rename.
#   * a tracker entry spelled relative to a different cwd, or a change set
#     belonging to another worktree.
# So the veto only ever NARROWS the name arms. It cannot widen them, and it
# cannot turn an absent file into a refusal.
#
# THE ONE THING IT TRADES: on a filesystem that reports every file executable
# (some Windows/Cygwin-style mounts historically did), every doc-named path
# would be vetoed and F1 would stop firing — a FALSE BLOCK, never a false
# release. That is the survivable direction of this pair, and the log line the
# caller writes on each veto is what makes it diagnosable rather than baffling.
#
# Relative paths resolve against $PROJECT_DIR, not the process cwd: this hook is
# invoked from wherever the session happens to be, and post-edit.sh records
# absolute paths while `git status --porcelain` yields repo-relative ones — both
# spellings arrive here.
#
# `read -r -n 2` rather than `head -c 2`: no fork, and it is bounded to two
# bytes, so a doc-named file that is really a 200MB single-line blob cannot be
# slurped into memory. `|| true` guards the EOF return of a file shorter than
# two bytes — bash has already assigned the partial read by then, so the
# two-byte file containing exactly `#!` is still caught (verified against
# /bin/bash 3.2.57, which is what these hooks run under on macOS).
DOC_VETO_REASON=""
doc_path_is_executable_content() {
    local p="$1" abs first
    DOC_VETO_REASON=""
    [ -n "$p" ] || return 1
    case "$p" in
        /*) abs="$p" ;;
        *)  abs="$PROJECT_DIR/$p" ;;
    esac
    # Not a regular file: absent, deleted, a directory, a device. No evidence.
    [ -f "$abs" ] || return 1
    if [ -x "$abs" ]; then
        DOC_VETO_REASON="the executable bit is set"
        return 0
    fi
    first=""
    IFS= read -r -n 2 first < "$abs" 2>/dev/null || true
    if [ "$first" = '#!' ]; then
        DOC_VETO_REASON="the file begins with a #! shebang"
        return 0
    fi
    return 1
}
# DOC-CONTENT-VETO END (claude-workflow-plugin-bbh)

# Doc-only patterns (F1). A change matches doc-only if EVERY modified file
# matches one of these patterns AND no other tracked code changes are
# present. We keep this conservative: README, CHANGELOG, LICENSE and the
# documentation extensions count; .json/.yaml/.toml do NOT (they often
# influence behavior).
#
# ---------------------------------------------------------------------------
# NEITHER POSITION NOR A NAME GLOB MAY CONFER DOCUMENTATION STATUS
# (claude-workflow-plugin-bbh)
# ---------------------------------------------------------------------------
# TWO ARMS DID, and each was a live release-authorising bypass needing no
# privilege beyond where a file sits or what it is called:
#
#   */docs/*|docs/*   ANY path under ANY `docs/` directory, at any depth, in any
#                     tree. Probed against the shipped function (extracted by
#                     awk, sha256 0bdaee6e644689e5901d8223ce242a992846fca0c938
#                     d2acb74eac66ac0966f9): `docs/deploy.sh`,
#                     `docs/scripts/migrate.py`, `docs/Dockerfile`,
#                     `docs/.github/workflows/ci.yml` and `src/docs/handler.ts`
#                     all classified as documentation. QA reproduced the end of
#                     it against these hooks — a change set of exactly one
#                     EXECUTABLE `docs/deploy.sh`, zero IMPLEMENTER records,
#                     auto-approved and recorded `QA-GATE APPROVED …
#                     reviewed_by=none`.
#   LICENSE.*         ANY extension after the name LICENSE. Root-only, because
#                     that arm carried no `*/` prefix — so `src/LICENSE.sh` was
#                     already reviewable while `LICENSE.sh` and `LICENSE.py`
#                     were documentation. A filename alone sufficed; no `docs/`
#                     directory was even needed.
#
# BOTH ARE REMOVED RATHER THAN NARROWED, and that is a measurement rather than a
# preference. The filing's candidate — keep the `docs/` arm but require a
# documentation extension INSIDE it — is an exclusion list, i.e. a new place for
# the next extension to be missing, and it is also INERT: `docs/guide.md`
# already matches `*.md` and `docs/LICENSE` already matches `*/LICENSE`, so the
# arm's whole marginal contribution was the files that match nothing else.
# MEASURED over a 1120-path cross product (8 directory shapes x 10 basenames x
# 14 extensions), removing both arms moves 438 paths from doc-only to reviewable
# and 0 paths the other way. This can only ever narrow.
#
# WHAT IT COSTS, because this is a behaviour change on the most-travelled fast
# path and the cost is the point of the round rather than a footnote: a `docs/`
# tree carrying non-prose files stops fast-pathing. `docs/img/diagram.png`,
# `docs/fixtures/payload.json`, an extension-less `docs/Makefile` or
# `docs/README` now need a QA round when they change alone. That is the correct
# direction — F1's entire licence is that there is nothing to review — and
# `docs/README` is now merely consistent with the repo-root `README`, which has
# never had an arm here.
#
# NO "KNOWN-EXECUTABLE EXTENSION" ARM was added to the veto below, and the
# reason is vacuity, not scope. Every surviving arm is either suffix-anchored on
# a documentation extension or an EXACT extension-less basename, so "ends in
# .sh" and "ends in .md" cannot both hold and LICENSE/CHANGELOG/NOTICE/AUTHORS
# have no extension at all. Such a leg could not change any answer, and a guard
# whose failure nobody can produce is presumed vacuous. Add one only alongside
# an arm that is neither suffix-anchored nor an exact name — and with the test
# that makes it fire.
#
# WHAT THIS CLASSIFIER STILL CANNOT SEE, stated because a fast path that
# auto-approves is allowed to be narrow and is not allowed to be wrong: for
# everything that is not affirmatively executable it still reads content type
# off the NAME. A `.txt` that is a golden test assertion, a `.md` that is an
# agent prompt or a rubric (this repo's own CLAUDE.md, .claude/agents/*.md and
# .claude/rubrics/*.md are behaviour-bearing markdown), and a bare `LICENSE`
# that is really a data file all classify as documentation. Those are facts
# about a project's layout, not about a path or a file's first two bytes, and no
# shape or content check recovers them. They are the residual this round does
# NOT close.
is_doc_only_path() {
    local p="$1"
    [ -z "$p" ] && return 1
    case "$p" in
        *.md|*.markdown|*.mdx|*.rst|*.txt) ;;
        # Extension-LESS documentation filenames only. `LICENSE.<ext>` is
        # deliberately absent: `LICENSE.md` / `LICENSE.txt` / `LICENSE.rst`
        # already match the extension arm above, so the glob's only reach was
        # over extensions nobody enumerated.
        */LICENSE|LICENSE) ;;
        */CHANGELOG|CHANGELOG) ;;
        */NOTICE|NOTICE|*/AUTHORS|AUTHORS) ;;
        *) return 1 ;;
    esac
    # DOC-CONTENT-VETO BEGIN (claude-workflow-plugin-bbh)
    # A documentation NAME is necessary and no longer sufficient. See
    # doc_path_is_executable_content above for what counts as evidence and why
    # an unresolvable path is not evidence of anything.
    #
    # The sentinel comments are load-bearing: a META strips this region and
    # asserts an executable `docs/install.txt` classifies doc-only again. The
    # arms above end in `;;` with no `return 0`, so the stripped copy falls
    # through to the `return 0` below — the pre-veto, name-only classifier —
    # rather than to a syntax error. Do not rename them.
    if doc_path_is_executable_content "$p"; then
        log_sync_error "F1: $p carries a documentation name but is executable content ($DOC_VETO_REASON), so it is classified REVIEWABLE and the doc-only fast path does not apply to this change set (claude-workflow-plugin-bbh)"
        return 1
    fi
    # DOC-CONTENT-VETO END (claude-workflow-plugin-bbh)
    return 0
}

# G2.gate-friction (claude-workflow-plugin-llh.3): beads-state / gate-
# bookkeeping classifier. A path is "beads-or-gate state" — i.e., workflow
# machinery, never reviewable source — if it is:
#   - a Beads JSONL ledger:   .beads/*.jsonl (at any depth, incl. e2e fixtures)
#   - the Beads sqlite db:     beads.db (or .beads/*.db)
#   - gate bookkeeping:        anything under .claude/.qa-tracking/
# These are the files a `qa-gate.sh enter` label-write and the gate's own
# cache churn dirty. They are NOT denylisted (so they still show up in the
# change-set / audit trail), but a change-set consisting SOLELY of them is
# fast-path eligible (see is_fastpath_only_change + the F1 block below).
is_beads_or_gate_path() {
    local p="$1"
    [ -z "$p" ] && return 1
    case "$p" in
        */.beads/*.jsonl|.beads/*.jsonl) return 0 ;;
        */.beads/*.db|.beads/*.db) return 0 ;;
        */beads.db|beads.db) return 0 ;;
        # `*/.qa-tracking/*` already covers the canonical
        # `.claude/.qa-tracking/...` location at any depth (the `.claude/`
        # segment is absorbed by the leading `*/`).
        */.qa-tracking/*|.qa-tracking/*) return 0 ;;
    esac
    return 1
}

# G2.gate-friction (claude-workflow-plugin-llh.3): is the post-denylist
# change-set fast-path eligible on the beads/empty axis? Returns 0 (eligible)
# when EITHER:
#   (a) the change-set is empty after the denylist, OR
#   (b) every member is beads-state / gate-bookkeeping (is_beads_or_gate_path).
# Returns 1 (not eligible) the moment any real source path is present — that
# is the anti-overreach guard: a mixed diff (beads + one .ts file) is a real
# code change and MUST still go through the qa-approved-only release rule.
#
# Operates on the caller's ALL_CHANGED_FILES array (the same post-denylist set
# CODE_CHANGES_DETECTED is derived from), passed by name-expansion so this
# stays a pure function under `set -e`.
is_fastpath_only_change() {
    # "$@" is the already-filtered (post-denylist) change-set.
    if [ "$#" -eq 0 ]; then
        return 0   # (a) empty after denylist — nothing to review.
    fi
    local f
    for f in "$@"; do
        [ -z "$f" ] && continue
        if ! is_beads_or_gate_path "$f"; then
            return 1   # a real source path is present -> NOT fast-path.
        fi
    done
    return 0   # (b) every member is beads-state / gate-bookkeeping.
}

# F3 (Phase 4 fix pass): the persisted helper file is the single source of
# truth for the active task id. The previous implementation fell back to
# `bd list --status in_progress | jq .[0].id` when the file was empty, but
# that defeats F3 entirely under parallel epics: it would silently grab an
# arbitrary in_progress task and let the gate operate on the wrong row.
#
# New contract: empty helper file means "no active task". The caller MUST
# treat that as a hard signal (no auto-approve, no auto-close). When this
# happens we record an entry in sync-errors.log so SessionStart can surface
# it - the most common cause is a previous `qa-gate enter` whose
# best-effort `write_current_task` failed silently.
get_current_task() {
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        tid=$(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null | tr -d '\r\n[:space:]' || echo "")
    fi
    if [ -z "$tid" ]; then
        # No fallback: previous bd-list fallback was the F3 anti-pattern.
        # Surface the missing helper to the user once per Stop fire.
        log_sync_error "current-task helper file empty or missing; treating as 'no active task' (no fallback to bd list)."
    fi
    printf '%s' "$tid"
}

# I8 (Phase 6b): repo-aware helpers. The current-task helper records the
# repo fingerprint at `set` time; here we read it back and compare to the
# running cwd's repo toplevel.
get_recorded_repo() {
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        bash "$CURRENT_TASK_HELPER" get-repo 2>/dev/null || echo ""
    elif [ -s "$QA_TRACKING_DIR/current-task.repo" ]; then
        head -1 "$QA_TRACKING_DIR/current-task.repo" 2>/dev/null | tr -d '\r\n[:space:]' || echo ""
    fi
}

# Returns the current cwd's git toplevel. Empty if not a git repo.
# Display-only (the I8 block reason names it); the mismatch DECISION uses
# repo_identity below, not this.
get_current_repo_root() {
    if command -v git >/dev/null 2>&1; then
        git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo ""
    fi
}

# repo_identity <dir> — the canonical, symlink-resolved git COMMON-DIR of
# <dir>, i.e. the identity of the REPOSITORY rather than of the checkout.
# Prints empty (rc 0) when <dir> does not exist or is not a git checkout.
#
# 3mg.1 (I8 fix): the identity used to be `rev-parse --show-toplevel`, which
# is per-CHECKOUT. Two linked worktrees of ONE repo have different toplevels,
# so a Stop fired from a worktree of the same repo the task was claimed in
# tripped the cross-repo block — exactly the isolation:"worktree" topology
# the plugin itself tells agents to use. `--git-common-dir` is shared by every
# worktree of a repo and differs across repos, which is the property I8
# actually wants.
#
# Two normalisations are load-bearing:
#   - `--git-common-dir` is RELATIVE to the queried dir in a primary checkout
#     (".git") and typically ABSOLUTE in a linked worktree; resolve both.
#   - `pwd -P` strips symlinks, so /var/... and /private/var/... (macOS) or a
#     symlinked project root compare equal instead of spuriously mismatching.
repo_identity() {
    local dir="$1" raw candidate resolved
    [ -n "$dir" ] || return 0
    command -v git >/dev/null 2>&1 || return 0
    [ -d "$dir" ] || return 0
    raw=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0
    case "$raw" in
        /*) candidate="$raw" ;;
        *)  candidate="$dir/$raw" ;;
    esac
    resolved=$(cd "$candidate" 2>/dev/null && pwd -P) || resolved=""
    printf '%s' "$resolved"
}

# Decide whether the active task is cross-repo relative to the cwd. We
# return the recorded repo path when there's a mismatch, empty otherwise.
# A missing recorded repo (i.e., set under pre-I8 schema) is NOT a mismatch
# -- we degrade silently to the legacy single-repo behaviour.
#
# 3mg.1: the comparison is now between REPOSITORY identities (see
# repo_identity). Consequences, all intended:
#   - same repo via a linked worktree  -> no block (was: false block)
#   - genuinely different repo         -> still blocks
#   - recorded path deleted/unresolvable -> MISMATCH, fail closed. We cannot
#     prove the recorded repo is this one, and the whole point of I8 is to
#     refuse to auto-close a task whose home repo we cannot identify.
detect_cross_repo() {
    local recorded recorded_id current_id
    recorded=$(get_recorded_repo)
    [ -z "$recorded" ] && return 0   # no recorded repo -> no mismatch claim
    recorded="${recorded%/}"

    current_id=$(repo_identity "$PROJECT_DIR")
    [ -z "$current_id" ] && return 0 # cwd not a git repo -> no mismatch claim

    recorded_id=$(repo_identity "$recorded")
    if [ -z "$recorded_id" ] || [ "$recorded_id" != "$current_id" ]; then
        printf '%s' "$recorded"
        return 1
    fi
    return 0
}

# has_git_repo — is $PROJECT_DIR inside a git checkout we can query?
#
# 3mg.1: the old test was `[ -d "$PROJECT_DIR/.git" ]`, which is FALSE in a
# LINKED WORKTREE (there `.git` is a FILE containing `gitdir: ...`), so the
# git-status fallback and the diff summary silently disabled themselves in
# exactly the topology the plugin tells agents to use — the gate then had NO
# detector at all when changed-files.txt was empty, i.e. it failed OPEN.
# The identical predicate lives in qa-gate.sh; keep them in sync.
has_git_repo() {
    command -v git >/dev/null 2>&1 || return 1
    git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1
}

# gate_baseline_entries — the porcelain lines of the current gate baseline,
# or empty when there is none.
#
# v2 file (`gate-baseline`, 3mg.1) carries a provenance header terminated by a
# lone `--`; everything after it is the snapshot. The v1 file
# (`approved-baseline`, 0wk.2) was a bare line list and is read as a fallback
# for ONE release — any v2 write deletes it, so this arm only ever serves an
# install that upgraded mid-cycle.
gate_baseline_entries() {
    local v2="$QA_TRACKING_DIR/gate-baseline"
    local legacy="$QA_TRACKING_DIR/approved-baseline"
    if [ -f "$v2" ]; then
        awk 'body { print; next } /^--$/ { body = 1 }' "$v2" 2>/dev/null || true
        return 0
    fi
    if [ -f "$legacy" ]; then
        cat "$legacy" 2>/dev/null || true
    fi
    return 0
}

# reviewable_changes — the CURRENT reviewable change set, one path per line.
# Empty output means "there is nothing to review right now".
#
# THE RULE, in ONE place (gz3 / v4.1 U1). Two callers read it:
#   1. the detection stage in the main flow, which also derives
#      ALL_CHANGED_FILES / DOC_ONLY / CODE_CHANGES_DETECTED from it;
#   2. the vanished-change-set re-read on the LABEL_WITHOUT_RECORD path, which
#      only needs to know whether the set is empty.
# It is one function because a Stop that answered "there ARE changes" from one
# rule and "the approval does not bind them" from a differently-derived one is
# exactly the incoherence gz3 fixed — a second copy of this walk would be a
# second thing to drift (same reason the denylist regex lives in one lib).
#
# BOTH HALVES, ALWAYS — a UNION, not a fallback (94d). It used to short-circuit
# on `found=1`: the tracker was authoritative and the baseline-relative
# `git status` walk was consulted ONLY when the tracker yielded nothing. That made
# the detector a strict subset of git whenever post-edit.sh had recorded even one
# path, so a single Edit was enough to hide every file written by a Bash redirect,
# `cp` or a generator script. Measured live four times; the tracker once held 37
# of 71 changed files while this function reported exactly those 37.
#
# The primary repair for that is reconcile_tracker in qa-gate.sh, which folds the
# git-visible delta INTO the tracker so `change_set_hash` covers it too (a
# read-time union alone would fix this detector and leave the hash short — a gate
# that reports 14 paths and releases on an approval binding 9). Dropping the
# short-circuit is the belt to that braces: after a reconcile the git half finds
# nothing new, and if the reconcile was skipped or failed the detector STILL
# cannot under-report relative to git MINUS THE BASELINE — which is the delta
# both halves are defined against, and the qualifier is load-bearing. Neither
# half sees a RE-WRITE of a path the baseline already lists: the subtraction is
# over raw porcelain LINES, so a second write leaves " M path" byte-identical and
# `comm -23` drops it on both sides. See qa-gate.sh's reconcile_tracker header,
# KNOWN LIMITS, and claude-workflow-plugin-dpe.
#
# The git half skips paths the tracker already yielded, in either spelling: the
# tracker holds ABSOLUTE paths and porcelain is repo-relative, so an unfiltered
# union would emit both spellings of every file and double the reported count.
# The baseline is still subtracted only on the git side, because pre-existing dirt
# cannot enter the tracker and an edit to an already-dirty file must still gate.
#
# `comm -23 a b` prints lines in a but not in b and needs both inputs in the
# SAME collation, hence LC_ALL=C on both sides, matching write_gate_baseline.
# (A locale difference between write and read would surface phantom "new"
# entries.) Bash 3.2 supports the process substitution used here (verified on
# macOS bash 3.2.57).
reviewable_changes() {
    local line path emitted="" skip
    if [ -f "$TRACKING_FILE" ] && [ -s "$TRACKING_FILE" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if is_tracked_change "$line"; then
                printf '%s\n' "$line"
                emitted="$emitted$line
"
            fi
        done < <(sort -u "$TRACKING_FILE" 2>/dev/null)
    fi
    has_git_repo || return 0

    local baseline current new_entries abs_root
    baseline=$(gate_baseline_entries | LC_ALL=C sort)
    current=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort)
    if [ -z "$baseline" ]; then
        # No baseline — any git-detected change is "new". Preserves the
        # pre-0wk.2 behaviour for users who have not approved anything yet.
        new_entries=$(printf '%s\n' "$current" | grep -v '^$' || true)
    else
        new_entries=$(comm -23 <(printf '%s\n' "$current") <(printf '%s\n' "$baseline") | grep -v '^$' || true)
    fi
    [ -n "$new_entries" ] || return 0
    # The working-tree root, for comparing a repo-relative porcelain path against
    # an absolute tracker entry. Empty is tolerated: we then compare only the
    # relative spelling, which over-reports rather than under-reports.
    abs_root=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || abs_root=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        path="${line#???}"
        case "$path" in *" -> "*) path="${path##* -> }" ;; esac
        [ -n "$path" ] || continue
        # Explicit `if` rather than `grep ... && continue`: an AND-OR list whose
        # left side fails is exactly the shape that makes `set -e` behaviour
        # version-dependent, and this function runs inside a hook where an
        # aborted process emits nothing — which the hooks contract reads as
        # NON-blocking, i.e. it would fail OPEN.
        skip=0
        if [ -n "$emitted" ]; then
            if printf '%s' "$emitted" | grep -qxF -- "$path"; then
                skip=1
            elif printf '%s' "$emitted" | grep -qxF -- "$PROJECT_DIR/$path"; then
                skip=1
            elif [ -n "$abs_root" ] && printf '%s' "$emitted" | grep -qxF -- "$abs_root/$path"; then
                skip=1
            fi
        fi
        if [ "$skip" = "1" ]; then
            continue
        fi
        # PATHS THE WORKFLOW ITSELF REWRITES must be skipped here too, or this
        # half contradicts the hash (94d). reconcile_tracker refuses to APPEND
        # them, so without this the tracker excluded `.beads/interactions.jsonl`
        # while THIS walk included it — and since bd rewrites that file on every
        # single call, including the gate's own add_comment and `label add`,
        # DOC_ONLY went false on every doc-only change set as soon as any bd call
        # had run. The F1 fast path was dead in production: every documentation
        # Stop demanded a full QA round. Measured at
        # specs/verify-review-discipline.sh D4, where the tracker held exactly
        # `docs/notes.md` and the gate still blocked.
        #
        # This is NOT the denylist (see workflow_self_written's header for why the
        # two rules are separate): a change set consisting solely of beads/gate
        # state still reaches the `beads-state` fast path and still gets a gate
        # record. It only stops the gate's own bookkeeping from making somebody
        # else's change set look mixed.
        if [ -n "${WORKFLOW_SELF_WRITTEN_REGEX:-}" ] && workflow_self_written "$path"; then
            continue
        fi
        if is_tracked_change "$path"; then
            printf '%s\n' "$path"
        fi
    done <<< "$new_entries"
    return 0
}

# Run a command with optional `timeout` if available. Returns the
# command's exit code. Streams combined stdout+stderr to the given log file.
run_with_timeout() {
    local secs="$1" log="$2"; shift 2
    : > "$log"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}s" bash -c "$*" >"$log" 2>&1
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}s" bash -c "$*" >"$log" 2>&1
    else
        # No timeout available - run unbounded; log indicates this.
        bash -c "$*" >"$log" 2>&1
    fi
}

# Tail a log to the last N lines (default 50). Used to surface failures
# in block-reason text without overwhelming Claude's context window.
log_tail() {
    local file="$1" n="${2:-50}"
    [ -f "$file" ] || { echo "(no log)"; return; }
    tail -n "$n" "$file"
}

# Read the configurable outer timeout (default 60s).
read_stop_timeout() {
    local v=60
    if [ -s "$STOP_TIMEOUT_FILE" ]; then
        local raw
        raw=$(head -1 "$STOP_TIMEOUT_FILE" | tr -dc '0-9' || echo "")
        [ -n "$raw" ] && v="$raw"
    fi
    printf '%s' "$v"
}

# Increment the iteration counter at $1 (a per-task path); print the new
# value. The counter file is task-keyed (see iteration_file_for) so leaks
# across tasks no longer happen.
bump_iteration() {
    local file="$1"
    local n=0
    if [ -s "$file" ]; then
        n=$(head -1 "$file" | tr -dc '0-9' || echo "0")
        n="${n:-0}"
    fi
    n=$((n + 1))
    printf '%s\n' "$n" > "$file"
    printf '%s' "$n"
}

# Read the iteration counter at $1 without bumping.
#
# 2ty: this became LIVE code (it had no caller until the bump was made
# conditional), so it now carries bump_iteration's empty-value guard. A counter
# file holding anything with no digits in it — a truncated write, a stray
# newline — used to yield the EMPTY STRING here, and every consumer feeds the
# result to `[ "$ITER" -ge "$MAX_ITERATIONS" ]`, which on an empty operand emits
# "integer expression expected" on stderr and evaluates false. Printing 0 keeps
# an unreadable counter equivalent to an absent one.
read_iteration() {
    local file="$1" n=""
    if [ -s "$file" ]; then
        n=$(head -1 "$file" | tr -dc '0-9' || printf '')
    fi
    printf '%s' "${n:-0}"
}

# J21 decision-gate options block (Phase 4 fix pass / MATERIAL 6).
#
# Previously this block only fired on the FAILED_CHECKS path. The more
# common case — technical checks pass but no QA approval at iter>=3 —
# never saw the options. Factored into a helper so we can append it to
# either reason string. $1 = task id (may be "<TASK_ID_NEEDED>").
#
# Spec 0.2: this block is now driven by qa-gate.sh choose <choice>; the
# direct `qa-gate.sh approve` form still works (`choose approve` is a
# thin wrapper around it). Wording mirrors the spec.
j21_options_block() {
    local tid="$1"
    cat <<EOF

ESCALATION: Iteration $ITER ($(escalation_basis_claim)).
Use the J21 decision gate options to choose a path forward (record via
\`qa-gate.sh choose ...\` so the gate exits escalation):

Options:
  1. approve  — \`bash .claude/scripts/qa-gate.sh choose approve $tid '<summary>'\`
                (only if you genuinely accept the findings as known/non-blocking)
  2. continue — \`bash .claude/scripts/qa-gate.sh choose continue $tid '<note>'\`
                fix the underlying issue and re-run; clears qa-escalated and resets the iteration counter.
  3. tech-debt — \`bash .claude/scripts/qa-gate.sh choose tech-debt $tid '<description>' [severity] [file:line] [effort]\`
                 records a TECHNICAL_DEBT.md row + bd task, clears qa-escalated.
  4. defer — \`bash .claude/scripts/qa-gate.sh choose defer $tid '<note>'\`
             stops iteration; sets qa-deferred so the next Stop is allowed.

If no choice is recorded by the NEXT Stop, the gate auto-selects option 4
(defer) and surfaces the task on the next SessionStart.
EOF
}

# Spec 0.2 helpers ------------------------------------------------------------
#
# Cache + label inspection for the escalation state machine. The verify
# script uses these to:
#   - read qa-escalated / qa-deferred labels on the active task
#   - cache the most-recent test run so escalated Stops don't re-run the
#     full suite each loop (the production bug we're fixing)
#   - distinguish runner-failure ("environment broke") from
#     assertion-failure ("the code is wrong") in the block reason
#
# State files live alongside the iteration counter (per-task keyed). They
# survive across Stop fires until qa-gate.sh wipes them on
# approve / re-enter / choose continue / choose tech-debt.

# Path helpers ---------------------------------------------------------------
last_test_rc_file_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/last-test-rc"; return; }
    printf '%s/last-test-rc.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
}
last_failed_checks_file_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/last-failed-checks"; return; }
    printf '%s/last-failed-checks.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
}
last_runner_file_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/last-runner"; return; }
    printf '%s/last-runner.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
}
escalation_posted_file_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/escalation-posted"; return; }
    printf '%s/escalation-posted.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
}
# 2ty: the auto-defer counter — Stops that fired while qa-escalated was already
# set, i.e. chances the agent has had to record a J21 choice. Task-keyed like the
# rest, and wiped by the same qa-gate.sh wipe_iteration_state that clears the
# iteration counter; a count that survived `enter` or `choose continue` would
# make the FIRST escalated Stop of a fresh cycle auto-defer immediately.
escalated_stops_file_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/escalated-stops"; return; }
    printf '%s/escalated-stops.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
}

# task_has_label <task-id> <label> - 0 if present, 1 if absent or bd unavailable.
# Mirrors qa-gate.sh's has_label but lives here so verify-before-stop can
# read labels without sourcing qa-gate.sh.
task_has_label() {
    local tid="$1" label="$2"
    [ -z "$tid" ] && return 1
    command -v bd >/dev/null 2>&1 || return 1
    [ -d "$PROJECT_DIR/.beads" ] || return 1
    local labels
    labels=$(bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null \
        || echo "")
    echo ",$labels," | grep -q ",$label,"
}

# llh.18 (red-team P0/P1): the change-set-bound approval check.
#
# The Stop hook used to release on label-presence alone (GATE_STATUS ==
# approved == has_label qa-approved). That label is forgeable by any agent
# (`bd label add <task> qa-approved`, bypassing qa-gate.sh approve — P0) and
# is never bound to the tracked changed files (approve a decoy, redirect
# current-task — P1). We now ADDITIONALLY require a tamper-evident approval
# record on the current task whose change_set_hash matches the CURRENT
# change-set. qa-gate.sh approve writes that record (a
# `QA-GATE APPROVED change_set_hash=<h>` comment); a bare label-add does not.
IMPACT_REPORT_SCRIPT="$PROJECT_DIR/.claude/scripts/impact-report.sh"

# current_change_set_hash — the canonical sha256 of the current,
# denylist-filtered, sorted changed-files list. Sourced from the ONE place
# that defines the canonicalisation (impact-report.sh --hash-only), the same
# computation qa-gate.sh approve recorded. We do NOT re-implement the
# sort/denylist/sha here — sharing the function is what keeps the recorded
# hash and the recomputed hash from drifting. Prints empty on failure; the
# caller treats an unverifiable hash as a hard "cannot confirm" (block),
# never as a pass.
current_change_set_hash() {
    [ -f "$IMPACT_REPORT_SCRIPT" ] || { printf ''; return 1; }
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$IMPACT_REPORT_SCRIPT" --hash-only 2>/dev/null || printf ''
}

# bd_show_with_comments <task-id> — `bd show --json` that always carries
# comment BODIES, across the supported bd range.
#
# bd 1.1.2 stopped inlining comments in `bd show --json`: it returns a
# `comment_count` integer, and the bodies need the new --include-comments flag.
# bd 0.47.x has no such flag and exits 1 ("unknown flag: --include-comments"),
# but inlines .comments already. So try the new form, fall back to the plain
# one — pin the CHAIN, not the leg, the same shape the `bd comments add ||
# bd comment add` calls use. Callers keep the usual
# `(if type=="array" then .[0].comments else .comments end) // []` accessor,
# which reads both shapes correctly. Never fails the caller.
#
# This matters here more than anywhere: every reader below is a RELEASE
# predicate. Under 1.1.2 without the flag they all see zero comments, so the
# approval RECORD check silently degrades to "no record" — which fails closed
# (blocks), but would make a correctly-approved task unreleasable.
#
# Only readers of .comments need this. has_label() and the other .labels
# readers must NOT use it: the flag's own help warns it "may be slow on issues
# with many comments", and .labels is unaffected by the change.
bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

# task_has_matching_approval_record <task-id> <expected-hash> — 0 when the
# task carries a `QA-GATE APPROVED change_set_hash=<h>` comment whose <h>
# equals <expected-hash>, 1 otherwise (incl. bd unavailable / empty hash).
# This is the tamper-evident half of the gate: it reads the approval RECORD
# qa-gate.sh approve wrote, not the (forgeable) label. An empty expected hash
# never matches (so an unverifiable current hash cannot accidentally pass).
task_has_matching_approval_record() {
    local tid="$1" expected="$2"
    [ -z "$tid" ] && return 1
    [ -z "$expected" ] && return 1
    command -v bd >/dev/null 2>&1 || return 1
    [ -d "$PROJECT_DIR/.beads" ] || return 1
    # Pull every comment's text, keep the QA-GATE APPROVED records, extract
    # each record's change_set_hash token, and look for an exact match. The
    # `change_set_hash=` prefix is matched literally so a summary that merely
    # mentions a hex string cannot satisfy the gate.
    local recorded_hashes
    recorded_hashes=$(bd_show_with_comments "$tid" \
        | jq -r '
            (if type == "array" then .[0].comments else .comments end) // []
            | .[].text
            | select(test("QA-GATE APPROVED .*change_set_hash="))
            | capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h
        ' 2>/dev/null || echo "")
    [ -z "$recorded_hashes" ] && return 1
    printf '%s\n' "$recorded_hashes" | grep -qxF "$expected"
}

# V3 (claude-workflow-plugin-jio.1): the ONE review-separation predicate.
# The Stop hook CALLS it; it does not reimplement the counting (same
# discipline as current_change_set_hash deferring to impact-report.sh).
REVIEW_CHECK_SCRIPT="$PROJECT_DIR/.claude/scripts/review-check.sh"

# matching_approval_record_text <task-id> <expected-hash> — print the LAST
# `QA-GATE APPROVED ... change_set_hash=<expected-hash> ...` comment TEXT
# (empty when none matches). Same source and same literal-prefix matching as
# task_has_matching_approval_record; a separate function because the
# review-discipline check needs the record's text — specifically whether it
# carries the audited `[review bypass:` marker — not just a yes/no.
#
# Never fails the caller: every failure path (no bd, no Beads dir, jq error)
# yields empty output with rc 0, which the caller treats as "no marker", i.e.
# the check RUNS. Fail-closed by construction.
matching_approval_record_text() {
    local tid="$1" expected="$2"
    [ -z "$tid" ] && return 0
    [ -z "$expected" ] && return 0
    command -v bd >/dev/null 2>&1 || return 0
    [ -d "$PROJECT_DIR/.beads" ] || return 0
    bd_show_with_comments "$tid" \
        | jq -r --arg h "$expected" '
            (if type == "array" then .[0].comments else .comments end) // []
            | .[].text
            | select(test("QA-GATE APPROVED .*change_set_hash="))
            | select(capture("change_set_hash=(?<rh>[A-Za-z0-9-]+)").rh == $h)
        ' 2>/dev/null | tail -1 || true
}

# Spec 0.2: classify a test failure as a runner/infrastructure issue vs.
# assertion failure. Conservative heuristic — when in doubt we say
# "assertion" (the existing wording) so we never mis-direct an
# assertion failure to "fix the environment".
#
# Inputs:
#   $1 - test exit code (numeric)
#   $2 - tail of the test log
#
# Returns:
#   prints "runner" or "assertion" on stdout.
classify_test_failure() {
    local rc="$1" tail_log="$2"
    # Timeout has its own wording upstream; classify as assertion so the
    # callsite keeps the dedicated "Tests timed out" message.
    [ "$rc" = "124" ] && { printf 'assertion'; return; }
    # Exit 127 = command not found; 126 = found but not executable.
    # These are unambiguously environment problems — the runner itself
    # did not start.
    if [ "$rc" = "127" ] || [ "$rc" = "126" ]; then
        printf 'runner'; return
    fi
    # Pattern probe over the log tail. Conservative — only patterns that
    # are unambiguous runner-infra signals.
    if [ -n "$tail_log" ] && printf '%s' "$tail_log" \
            | grep -qE 'command not found|Cannot find module|No such file or directory|npm ERR! Missing script|No rule to make target|TS5057: Cannot find a tsconfig\.json|Error: Cannot find package|ENOENT.*node_modules|testcontainers.*TypeError'; then
        printf 'runner'; return
    fi
    printf 'assertion'
}

# Compute a JSON-encoded summary of changes for J18 intent-routing context.
# Shape: {"changed_files":[...], "diff_summary":"...", "recommended_focus":"<llm-fills>"}
compute_intent_payload() {
    local files_json
    if [ -f "$TRACKING_FILE" ]; then
        files_json=$(sort -u "$TRACKING_FILE" 2>/dev/null \
            | while IFS= read -r f; do
                if is_tracked_change "$f"; then printf '%s\n' "$f"; fi
              done \
            | jq -R . 2>/dev/null \
            | jq -s . 2>/dev/null \
            || echo "[]")
    else
        files_json="[]"
    fi
    [ -z "$files_json" ] && files_json="[]"

    # Generate a small diff summary if git is available. Cap at 80 lines so
    # we don't blow up the block reason. Set principled output: file:lines.
    local summary=""
    if has_git_repo; then
        summary=$(git -C "$PROJECT_DIR" diff --stat HEAD 2>/dev/null | head -80 || echo "")
        [ -z "$summary" ] && summary=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | head -80 || echo "")
    fi
    [ -z "$summary" ] && summary="(no diff stats available)"

    # Use -c (compact) for RFC-8259-clean output. Pretty-printed JSON could
    # contain literal newlines inside strings (the diff_summary), which the
    # outer block-reason envelope handles via jq -Rs but the LLM might
    # still extract the inner block as text and re-parse it. Compact form
    # avoids any control-character risk.
    jq -nc \
        --argjson files "$files_json" \
        --arg summary "$summary" \
        '{changed_files:$files, diff_summary:$summary,
          recommended_focus:"<<orchestrator-or-qa-fills-this: read the diff and decide which review pass to invoke; do NOT use regex over filenames>>"}'
}

# Emit a block-reason JSON envelope.
#
# E9 standardisation note: the Stop hook uses the **top-level** decision
# pattern per the Claude Code hooks reference — i.e., {"decision":"block",
# "reason":"..."} — NOT the hookSpecificOutput envelope. The hooks docs
# reserve hookSpecificOutput for PreToolUse/PermissionRequest/PermissionDenied
# /WorktreeCreate/Elicitation/ElicitationResult and use top-level decision
# for UserPromptSubmit/PostToolUse/Stop/SubagentStop/ConfigChange/PreCompact.
# The non-blocking note path below DOES use hookSpecificOutput because it's
# carrying additionalContext, not a decision.
emit_block() {
    local reason="$1"
    printf '{"decision":"block","reason":%s}\n' \
        "$(printf '%s' "$reason" | jq -Rs .)"
    exit 0
}

# ---------------------------------------------------------------------------
# Begin main flow.

INPUT=$(cat)
STOP_REASON=$(echo "$INPUT" | jq -r '.stop_reason // empty' 2>/dev/null || echo "")
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")

# Circuit breaker (AgentLint H3): when stop_hook_active is true Claude is already
# in a forced-continuation state from a previous block. Returning exit 0 here
# prevents the hook from re-blocking and producing an infinite loop.
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
    echo "{}"; exit 0
fi

# Skip for user interrupt / max turns.
if [[ "$STOP_REASON" == "user_interrupt" ]] || [[ "$STOP_REASON" == "max_turns" ]]; then
    echo "{}"; exit 0
fi

# 3mg.1 fail-closed: the shared denylist lib is missing, so "which paths are
# reviewable" is unknowable and every downstream classification (change set,
# doc-only, fast-path, change-set hash) is unverifiable. Refuse to release.
# Deliberately placed AFTER the stop_hook_active circuit breaker above — a
# block emitted before it would loop the Stop hook forever.
if [ "$WORKFLOW_DENYLIST_MISSING" = "1" ]; then
    log_sync_error "Stop blocked: workflow-denylist.sh missing (looked in ${_WFDL_DIR:-<unresolvable script dir>}); the reviewable change set is unverifiable"
    emit_block "QA gate cannot run: the shared path denylist is missing.

verify-before-stop.sh could not load its sibling \`workflow-denylist.sh\` from:
  ${_WFDL_DIR:-<unresolvable script dir>}

That file defines which paths count as reviewable work. Without it the gate
cannot classify the change set, compute a comparable change-set hash, or tell
build churn from deliverables — so it refuses to release rather than guess.

Fix (one of):
  1. Restore the file: it ships with the plugin at .claude/scripts/workflow-denylist.sh
     (re-run the plugin installer, or 'git checkout -- .claude/scripts/workflow-denylist.sh').
  2. If you are running a partially-synced fixture or worktree, re-sync the
     canonical hook scripts into it (make sync-fixtures)."
fi

# TRACKER-RECONCILE BEGIN (94d)
#
# FIRST, MAKE THE TRACKER COMPLETE. changed-files.txt is written by exactly one
# hook — post-edit.sh, on Write/Edit/MultiEdit/NotebookEdit — so a file produced
# by a Bash redirect, `cp`, `sed -i` or a generator script never entered it.
# Everything downstream of here reads that file, and not only as a detector:
#   - CHANGE_COUNT and the block reason's "Files changed:" list enumerate it;
#   - compute_intent_payload's changed_files[] enumerates it;
#   - change_set_hash() — the value this gate matches an approval record
#     against — is a sha256 of it.
# So an under-covering tracker did not merely hide files from the readout; it let
# the gate release on an approval bound to fewer paths than actually shipped.
# Reconciling here, before anything reads the file, is what makes every one of
# those four consumers describe the same change set.
#
# FAIL CLOSED. `qa-gate.sh reconcile-tracker` exits non-zero only when it cannot
# determine the git-visible delta at all (git unreadable, or the shared denylist
# missing so "which paths belong in the tracker" is unknowable). In that state we
# cannot say what the change set IS, so we refuse to release rather than evaluate
# a set we know may be short — the same call the denylist-missing block above
# makes. Placed AFTER the stop_hook_active circuit breaker, never before it: a
# block emitted ahead of that guard loops the Stop hook forever (AgentLint H3).
#
# A missing qa-gate.sh is ALSO a block: it is the script that owns this repair,
# and a gate whose own state machine is absent cannot vouch for a change set.
#
# Sentinels are load-bearing (an L2 META-TEST strips every TRACKER-RECONCILE
# region and asserts the Bash-written file stops reaching the tracker and the
# block reason). Do not rename them.
if [ ! -f "$QA_GATE" ]; then
    log_sync_error "Stop blocked: qa-gate.sh missing at $QA_GATE; the change-set tracker cannot be reconciled against git, so the change set is unprovable"
    emit_block "QA gate cannot run: qa-gate.sh is missing.

verify-before-stop.sh could not find its sibling gate script at:
  $QA_GATE

That script owns the change-set tracker reconcile (94d) — the step that folds
files written by Bash redirects, \`cp\` or generator scripts into
.claude/.qa-tracking/changed-files.txt. Without it the gate cannot prove the
change set it would release is the change set that actually changed, so it
refuses rather than guess.

Fix (one of):
  1. Restore the file: it ships with the plugin at .claude/scripts/qa-gate.sh
     (re-run the plugin installer, or 'git checkout -- .claude/scripts/qa-gate.sh').
  2. If you are running a partially-synced fixture or worktree, re-sync the
     canonical hook scripts into it (make sync-fixtures)."
fi
RECONCILE_OUT=""
RECONCILE_RC=0
RECONCILE_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$QA_GATE" reconcile-tracker 2>&1) || RECONCILE_RC=$?
if [ "$RECONCILE_RC" -ne 0 ]; then
    log_sync_error "Stop blocked: qa-gate.sh reconcile-tracker exited $RECONCILE_RC; the git-visible change set is undeterminable so changed-files.txt cannot be proven complete (94d)"
    emit_block "QA gate cannot run: the change-set tracker could not be reconciled against git.

\`qa-gate.sh reconcile-tracker\` exited $RECONCILE_RC in:
  $PROJECT_DIR

It reported:
$RECONCILE_OUT

That step folds every git-visible change into
.claude/.qa-tracking/changed-files.txt, which is what the change-set hash is
computed over and what this gate matches an approval record against. When it
cannot run, the gate cannot tell whether the tracker covers the whole diff — so
it refuses to release rather than certify a change set that may be short (94d).

Fix (usual causes, in order):
  1. Is \`git status\` working in this checkout? Run it by hand; an interrupted
     rebase, a stale index.lock, or a permissions problem all surface here.
  2. Is .claude/scripts/workflow-denylist.sh present? Without it there is no
     definition of which paths are reviewable.
  3. Re-run after fixing:
       bash .claude/scripts/qa-gate.sh reconcile-tracker"
fi
# TRACKER-RECONCILE END (94d)

# Detect tracked changes. The rule — the tracker UNION the baseline-relative
# git-status walk — lives in reviewable_changes() (ONE definition, two
# readers; see its header). This loop only derives the three things the rest of
# the flow needs from that set.
#
# 0wk.2 / 3mg.1 context for the git half, kept here because it is where a
# reader looks for it: the gate baseline (written by session-start, qa-gate
# enter and qa-gate approve) captures the git state already accounted for, so
# the gate evaluates the session DELTA. Without it every Stop fired
# "N file(s) changed - all require QA review" against the same pre-existing
# uncommitted state.
#
# There is STILL deliberately no hash-side subtraction, and 94d did not change
# that — it moved WHERE the subtraction happens rather than adding one. The
# tracker has two writers now: post-edit.sh (actual tool edits, unfiltered by the
# baseline, so an edit to an already-dirty file must still gate) and
# reconcile_tracker (the git-visible remainder, which subtracts the baseline
# before appending). Pre-existing dirt therefore still cannot enter the tracker
# from either writer, which is the property the no-subtraction rule rests on.
CODE_CHANGES_DETECTED=false
ALL_CHANGED_FILES=()
DOC_ONLY=true   # F1: stays true only if every changed file is doc-only.

while IFS= read -r line; do
    [ -z "$line" ] && continue
    CODE_CHANGES_DETECTED=true
    ALL_CHANGED_FILES+=("$line")
    if ! is_doc_only_path "$line"; then
        DOC_ONLY=false
    fi
done < <(reviewable_changes)

# If no changes at all, allow.
if [ "$CODE_CHANGES_DETECTED" = false ]; then
    echo "{}"; exit 0
fi

# Resolve current task id once.
CURRENT_TASK=$(get_current_task)

# I8 (Phase 6b): cross-repo detection. If the active task was claimed in a
# different repo than the cwd's, we treat that as a hard "do not auto-approve"
# signal: a Stop fired in repo Y must NOT silently sign off a task tracked in
# repo X's Beads database (or against repo X's HEAD). We:
#   - skip the F1 doc-only auto-approve fast path (kept for same-repo only)
#   - surface a clearly-formatted block reason explaining the mismatch
# A third bullet here used to read "skip the post-approval `bd update --status
# closed` short-circuit". That short-circuit no longer exists anywhere in this
# hook — qzv removed both call sites (see THE TASK IS NOT CLOSED HERE below and
# the note at the end of the approved-path flow) — so there is nothing left for
# I8 to skip, and leaving the bullet in place would have credited this check with
# suppressing a write that cannot happen. The APPROVAL is what it suppresses.
# Single-repo users see no behaviour change because get_recorded_repo
# returns empty for them (the helper file simply doesn't carry repo data).
CROSS_REPO_PEER=""
# detect_cross_repo prints the recorded repo when it differs from cwd's
# repo, exit code 1; prints nothing + exit 0 on match (or pre-I8 schema).
# We swallow the non-zero rc so `set -e` doesn't abort the gate.
cross_rc=0
cross_check=$(detect_cross_repo) || cross_rc=$?
if [ "$cross_rc" -ne 0 ] && [ -n "$cross_check" ]; then
    CROSS_REPO_PEER="$cross_check"
fi

if [ -n "$CROSS_REPO_PEER" ]; then
    # The CWD is in a different repo than the recorded task. Surface a block
    # reason and do not auto-approve. ("...and do not auto-close" used to be the
    # other half of this sentence; qzv removed every close from this hook, so the
    # only write left to withhold is the approval.)
    CURRENT_REPO_ROOT=$(get_current_repo_root)
    REASON="Cross-repo Stop detected (I8).

The active Beads task ($CURRENT_TASK) was claimed in repo:
  $CROSS_REPO_PEER

But this Stop hook fires from the cwd-rooted repo:
  ${CURRENT_REPO_ROOT:-(no git repo detected in cwd)}

The QA gate will not auto-approve a task from a foreign repo. Pick one:

  1. cd into $CROSS_REPO_PEER and re-run the Stop flow there. Tests/lint
     for the task's actual repo run against the right HEAD.
  2. If the work genuinely spans both repos, treat each repo's gate
     independently: claim a sibling task in the cwd's repo, do its review
     there, then return to $CROSS_REPO_PEER for the original task's gate.
  3. If this is a mis-recorded task (rare; usually means current-task.repo
     drifted), reset via:
       bash .claude/scripts/current-task.sh clear
       bash .claude/scripts/qa-gate.sh enter $CURRENT_TASK   # rewrites repo
     -- but only after confirming the task really lives in the cwd's repo.

The gate state for $CURRENT_TASK is preserved (no labels touched, no
status changes). The intent is: humans/Claude must explicitly handle the
cross-repo case, never the gate."
    log_sync_error "cross-repo Stop blocked for $CURRENT_TASK: recorded=$CROSS_REPO_PEER cwd=${CURRENT_REPO_ROOT:-unknown}"
    emit_block "$REASON"
fi

# F1: fast path. Auto-approve via qa-gate.sh and short-circuit. MUST run
# before test/lint to avoid spending 1200s on changes that need no review.
#
# Three eligible classes (FASTPATH_CLASS names which one fired, and lands in
# the audit comment):
#   doc-only     — every changed file is documentation (original F1).
#   beads-state  — every changed file is beads ledger / gate bookkeeping
#                  (.beads/*.jsonl, beads.db, .qa-tracking/*).
#                  G2.gate-friction (claude-workflow-plugin-llh.3).
#   empty        — nothing left after the denylist (belt-and-braces; the
#                  "no changes" check above usually catches this first).
#
# ANTI-OVERREACH: a mixed change-set (beads + one real source file) is NOT
# eligible — is_fastpath_only_change returns 1 the moment a non-beads source
# path appears, so the qa-approved-only release rule stays intact for every
# real code path. Doc-only precedence is preserved (it was here first).
# qzv: the verdict of the change-set/task binding predicate, and the operator-
# facing reason when it refuses.
#
# BOTH ARE DECLARED HERE, OUTSIDE the F1-CHANGE-SET-BINDING regions below, with
# the PRE-FIX (auto-approving) defaults — the same discipline
# REVIEW_DISCIPLINE_BLOCKED / APPROVAL_RECORD_DETAIL use further down. With those
# regions stripped nothing ever reassigns them, the guard is gone, the note stays
# empty, and the mid-implementation auto-approval returns: byte-for-byte the
# behaviour that shipped before qzv. That is what makes the L2 META measure the
# guard instead of dying on an unset variable.
F1_BINDING_VERDICT=safe
F1_BINDING_DETAIL=""
F1_BINDING_NOTE=""

FASTPATH_CLASS=""
if [ "$DOC_ONLY" = true ] && [ ${#ALL_CHANGED_FILES[@]} -gt 0 ]; then
    FASTPATH_CLASS="doc-only"
elif [ ${#ALL_CHANGED_FILES[@]} -eq 0 ]; then
    # Empty post-denylist set. (The earlier "no changes -> allow" check only
    # fires when CODE_CHANGES_DETECTED is false; this guards the rare path
    # where detection set the flag but every member was denylist-filtered.)
    if is_fastpath_only_change; then
        FASTPATH_CLASS="empty"
    fi
elif is_fastpath_only_change "${ALL_CHANGED_FILES[@]}"; then
    FASTPATH_CLASS="beads-state"
fi

if [ -n "$FASTPATH_CLASS" ]; then
    # Audit text naming the class that fired (mirrors the original F1
    # wording so existing log/observability greps still match on "F1").
    FASTPATH_REASON="Auto-approved: $FASTPATH_CLASS change-set detected (F1 fast path) — no reviewable source changed."
    if [ -n "$CURRENT_TASK" ] && [ -x "$QA_GATE" ]; then
        # Auto-approve only if the task is currently pending (not already
        # approved/blocked). This idempotency is enforced inside qa-gate.sh
        # too, but we check here to keep observations clear.
        GATE_STATUS=$("$QA_GATE" status "$CURRENT_TASK" 2>/dev/null | jq -r '.status // "error"' 2>/dev/null || echo "error")

        # The hash of the change set THIS Stop classified, captured BEFORE the
        # `enter` below. Declared outside the binding regions for the same
        # stripped-copy-stays-coherent reason as the verdict variables: with the
        # regions gone this is computed and simply never passed on, which is the
        # pre-qzv call shape.
        #
        # BEFORE `enter` is the whole point. `enter` reconciles the tracker and
        # regenerates the impact report, so a path that appeared between the
        # detection stage and here lands in the set `approve` will bind — and
        # F1's doc-only verdict was reached over the EARLIER set. Capturing here
        # is what makes `--expect-hash` an assertion about the classified set
        # rather than a tautology about the bound one.
        F1_CLASSIFIED_HASH=$(current_change_set_hash) || true
        # An array rather than `${var:+--expect-hash "$var"}`: the latter relies
        # on word splitting of an unquoted expansion to become two arguments,
        # which is correct only for as long as the value can never contain a
        # space. The array says what it means and degrades to zero arguments when
        # the hash is unavailable (that case is already handled by approve's own
        # unbound-record warning).
        F1_EXPECT_ARGS=()
        if [ -n "$F1_CLASSIFIED_HASH" ]; then
            F1_EXPECT_ARGS=(--expect-hash "$F1_CLASSIFIED_HASH")
        fi

        # F1-CHANGE-SET-BINDING BEGIN (qzv)
        #
        # F1 MAY NOT SPEAK FOR A TASK AN IMPLEMENTER IS STILL WORKING ON.
        #
        # THE DEFECT (reproduced live four times, most seriously on the v4.1.0
        # release task itself). F1's verdict is a statement about a CHANGE SET —
        # "no reviewable source changed". Its `qa-approved` label is a statement
        # about a TASK — "this task's work is approved". Any doc-only Stop that
        # lands while a task is open converts the first into the second. On
        # claude-workflow-plugin-0fc: gate entered 15:44:00Z, `IMPLEMENTER:
        # role=devops` posted 15:44:59Z, and at 15:46:39Z F1 recorded
        # `QA-GATE APPROVED change_set_hash=b1169536… reviewed_by=none` for work
        # that did not exist when the cycle opened.
        #
        # THE PREDICATE. Auto-approve only when no `IMPLEMENTER: role=… task=…
        # at <ts>` record on the active task is at-or-newer than the most recent
        # `QA-GATE: entered at <ts>`. Both grammars are single-line
        # ISO-8601-UTC, so the comparison is lexicographic.
        #
        # THE INPUTS ARE THE RECORDS THEMSELVES, via review-check.sh's existing
        # envelope. That is deliberate and it is the lesson of this release's own
        # R6-F1: a guard whose evidence is WEAKER than the property it protects
        # is not a guard. The rejected alternative was a sibling-file or
        # label-shaped probe — cheap to write, and false exactly when it matters.
        # There is no second parser here: review-check.sh already reads both
        # record classes to count implementers.
        #
        # NO IMPLEMENTER RECORD IS *SAFE*, NOT UNKNOWN. Doc-only work is
        # orchestrator-authored and never produces one, so requiring a record
        # would deadlock every documentation commit. Its absence is a fact, and
        # the fact says nothing is in flight.
        #
        # AND WHEN THE PREDICATE CANNOT BE ESTABLISHED, REFUSE — never
        # auto-approve, never allow. FIVE branches land in the `unestablished`
        # verdict, each with its own reason (docs/HOOKS.md enumerates the same
        # five; keep the two in step):
        #   1. review-check.sh is absent.
        #   2. it answers with no `cycle_opened_ts` / `latest_implementer_ts` at
        #      all — a pre-qzv or partially-synced install.
        #   3. it reports its own dependency failure instead
        #      (error_key=bd_unavailable|jq_missing: bd or jq off this hook's
        #      PATH, or no Beads workspace here). Split from 2 because the two
        #      send an operator to completely different fixes.
        #   4. a record exists whose timestamp is not single-line ISO-8601-UTC.
        #   5. the qa-gate-entered LABEL says a cycle is open while no
        #      `QA-GATE: entered` record comes back — the bd-1.1.2 cross-check
        #      below.
        # "Cannot establish" is mechanically distinct from "established as safe" —
        # the first has no usable pair of timestamps, the second has two and
        # compared them — and the block reason says which.
        #
        # THE EXIT CODE IS NOT THE DISCRIMINATOR, and this is the subtle part:
        # F1 fires on change sets with nothing to review, so `review-check.sh
        # gate` exits 4 (`review_artifact_missing`) on the NORMAL path here.
        # Keying on rc would refuse every doc-only Stop. The discriminator is
        # whether the two FIELDS came back.
        #
        # ONE CROSS-CHECK, for the failure this repo has already lived through:
        # bd 1.1.2 stopped inlining `.comments`, so every record reader can come
        # back empty while the LABELS still read fine. Empty records are
        # indistinguishable from "a task with no records" unless something
        # compares the two sources — so when the label says a cycle is open
        # (GATE_STATUS `entered`) and no `QA-GATE: entered` record came back, the
        # two disagree and that is `unestablished`, not `safe`.
        #
        # WHAT THIS DOES NOT ESTABLISH, stated because the temptation to
        # overclaim is the defect one layer up: binding F1's verdict to the
        # change set it classified does NOT establish that the change set is
        # COMPLETE. The freshness machinery behind it compares two reads of the
        # same source, so it detects drift and is structurally blind to loss
        # (claude-workflow-plugin-fkm.1.20). An independent witness for
        # completeness is a later phase's job; nothing here proves it.
        #
        # THE RECORD THIS READS IS RE-WRITTEN PER CYCLE, and it has to be
        # (claude-workflow-plugin-qzv.1). `subagent-start.sh record_implementer`
        # used to be idempotent per (role, task) — a re-spawn of the SAME role on
        # the SAME task posted nothing, ever — so `latest_implementer_ts` was that
        # role's FIRST spawn permanently and this compare read "previous cycle"
        # from the second cycle onward. QA reproduced the whole sequence live:
        # cycle 1 entered 18:31:36Z / spawned 18:31:38Z blocked correctly; a fresh
        # enter at 18:32:06Z plus a re-spawn that posted nothing left impl < cycle,
        # and F1 stamped `qa-approved` + `reviewed_by=none` mid-implementation.
        # That defect is CLOSED at the writer, not here: the idempotency key is now
        # (role, task, CYCLE), keyed on this same `QA-GATE: entered` record, so it
        # adds no state and no third parser. Nothing in this function changed for
        # it. See subagent-start.sh's IMPLEMENTER-CYCLE-KEY region.
        #
        # THE `qa` ROLE IS OUT OF SCOPE FOR THIS PREDICATE, deliberately, and a
        # reader of this header is entitled to know it rather than infer it.
        # `is_implementer_role` is backend|frontend|devops only, so a QA agent —
        # which holds Write/Edit/MultiEdit — produces no IMPLEMENTER record and
        # this compare has nothing of QA's to see. Recording `qa` was considered
        # and is WORSE in two measurable ways: the record would outlive the cycle
        # it was written in for every task QA has ever reviewed, so F1 would refuse
        # on any task with QA history — deadlocking exactly the documentation
        # commits this fast path exists for, the same anti-overreach argument that
        # makes a MISSING record `safe` — and it would put `qa` into the implementer
        # SET that `approve`'s review-separation reads, where it can only ever
        # refuse an approval that should stand.
        #
        # WHAT THAT EXEMPTION ACTUALLY LEAVES OPEN. F1 requires DOC_ONLY, i.e.
        # EVERY path in the change set matches `is_doc_only_path`. THE ONLY
        # ACCURATE STATEMENT OF WHICH PATHS THOSE ARE IS THE FUNCTION — read it,
        # it is at the top of this file and it is a short `case`;
        # `.claude/scripts/tests/doc-only-classifier.test.sh` drives it over 1120
        # paths if you want the answer generated rather than read.
        #
        # THAT INSTRUCTION REPLACES A HAND-WRITTEN COMPLEMENT, and the replacement
        # is the point rather than a tidy-up. The sentence that used to sit here
        # enumerated what is NOT doc-only in English ("only a file placed
        # elsewhere — a test at `tests/`, a hook at `.claude/scripts/` — makes
        # DOC_ONLY false"), and that sentence shipped FALSE in three consecutive
        # rounds, each written by a round that had just corrected the previous
        # one. Its last version was falsified by both of its own examples:
        # `tests/spec.txt` and `.claude/scripts/hook.txt` are doc-only via the
        # extension arm, at any location. The tell is worth carrying: the POSITIVE
        # claim beside it had a test and stayed true every time; the complement had
        # no test and was wrong every time. Do not write a fourth one — point at
        # the function, or generate the list from it.
        #
        # WHAT bbh CHANGED, named because a reader arriving from the git history
        # needs the old shape: two arms conferred documentation status by SHAPE
        # rather than by content — `*/docs/*|docs/*` (any file under any `docs/`
        # directory, any type, any depth) and `LICENSE.*` (any extension after
        # that one name, at the root). Both are removed, and a file that is
        # affirmatively executable — the executable bit, or a `#!` first line — is
        # now never doc-only whatever it is called. The reproduction this passage
        # used to disclose as LIVE — a change set of exactly one executable
        # `docs/deploy.sh`, zero IMPLEMENTER records, auto-approved with
        # `reviewed_by=none` — no longer classifies as doc-only, so it no longer
        # reaches this predicate at all.
        #
        # THE RESIDUAL THAT REMAINS, stated positively because that is the half
        # that keeps being true: `reviewed_by=none` over DOCUMENTATION its own
        # author wrote. For anything not affirmatively executable the classifier
        # still reads content type off the NAME, so a `.txt` that is a golden test
        # assertion and a `.md` that is an agent prompt or a rubric — this repo's
        # own CLAUDE.md and .claude/agents/*.md are behaviour-bearing markdown —
        # classify as documentation and reach this exemption. Those are facts about
        # a project's layout, not about a path or a file's first two bytes, and no
        # shape or content check recovers them. bbh narrowed this residual; it did
        # not remove it.
        #
        # WHAT STILL HOLDS, because the bound is narrower than "unbounded" and
        # overcorrecting would be the same error in the other direction: the set F1
        # classifies IS the set the approval binds, by hash. So this is an
        # unreviewed approval over its author's OWN work, never one that silently
        # covers a DIFFERENT change set.
        #
        # AND THE HASH IS A HASH OF THE PATH LIST — stated because "bound by hash"
        # invites a stronger reading than the code supports, and this passage has
        # already shipped one of those. impact-report.sh's change_set_hash is
        # `canonical_changed_files | sha256_stdin`, and canonical_changed_files
        # prints the sorted, deduped, denylist-filtered PATHS; it never reads a byte
        # of their content. Measured: appending a line to a file already in the
        # tracker leaves the hash IDENTICAL. So the binding pins WHICH files a
        # verdict covers, not what was in them — which is precisely what
        # --expect-hash was built for (a path arriving between classification and
        # approval) and is all it can do.
        #
        # HOW EARLIER VERSIONS OF THIS PASSAGE GOT IT WRONG, kept because the
        # failure mode is the instructive part and because it recurred. Round 7
        # asserted that a script or a fixture makes DOC_ONLY false, called itself
        # "measured", and had never probed the classifier — the `docs/` arm was
        # read in the same session and dismissed as an edge case. Round 8's
        # correction then claimed placement outside `docs/` was sufficient, which
        # is false for every `.txt` in the tree. A disclosure that overstates the
        # safety it discloses is worse than no disclosure, because it is what a
        # future maintainer reads INSTEAD of checking. That is the whole reason
        # this paragraph exists, so it was the worst possible place for it.
        #
        # The sentinel comments are load-bearing: an L2 META-TEST strips every
        # F1-CHANGE-SET-BINDING region and asserts the in-flight implementer's
        # task is auto-approved again. Do not rename them.
        f1_binding_verdict() {
            local rc_out="" has_fields="" ekey="" cycle="" impl="" oldest=""
            if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
                F1_BINDING_VERDICT="unestablished"
                F1_BINDING_DETAIL="the review predicate is missing ($REVIEW_CHECK_SCRIPT), so whether an implementer is in flight could not be established"
                return 0
            fi
            # rc is deliberately ignored (see the note above); the fields are the
            # discriminator. Command substitution keeps a non-zero rc from
            # aborting the hook under `set -e` — an aborted hook emits nothing,
            # which the hooks contract reads as NON-blocking, i.e. it would fail
            # OPEN.
            rc_out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" gate "$CURRENT_TASK" 2>/dev/null) || true
            has_fields=$(printf '%s' "$rc_out" | jq -r 'if (type == "object" and has("cycle_opened_ts") and has("latest_implementer_ts")) then "yes" else "no" end' 2>/dev/null) || has_fields="no"
            [ -n "$has_fields" ] || has_fields="no"
            if [ "$has_fields" != "yes" ]; then
                # Two very different causes reach here, and reporting the wrong
                # one sends the operator to the wrong fix. The predicate's own
                # dependency failures (`bd` or `jq` off PATH, no Beads workspace)
                # come back with an error_key on the terse envelope; anything else
                # answered in a shape that has no such fields at all, which means
                # the copy on disk predates qzv or was partially synced.
                ekey=$(printf '%s' "$rc_out" | jq -r '.error_key // ""' 2>/dev/null) || ekey=""
                case "$ekey" in
                    bd_unavailable|jq_missing)
                        F1_BINDING_VERDICT="unestablished"
                        F1_BINDING_DETAIL="the review predicate could not read $CURRENT_TASK's records (review-check.sh reported error_key=$ekey — bd or jq is not on this hook's PATH, or there is no Beads workspace here), so whether an implementer is in flight could not be established"
                        ;;
                    *)
                        F1_BINDING_VERDICT="unestablished"
                        F1_BINDING_DETAIL="review-check.sh answered without cycle_opened_ts / latest_implementer_ts (a pre-qzv or partially-synced copy of the script${ekey:+; error_key=$ekey}), so whether an implementer is in flight could not be established"
                        ;;
                esac
                return 0
            fi
            cycle=$(printf '%s' "$rc_out" | jq -r '.cycle_opened_ts // ""' 2>/dev/null) || cycle=""
            impl=$(printf '%s' "$rc_out" | jq -r '.latest_implementer_ts // ""' 2>/dev/null) || impl=""
            if [ "$cycle" = "unparseable" ] || [ "$impl" = "unparseable" ]; then
                F1_BINDING_VERDICT="unestablished"
                F1_BINDING_DETAIL="a QA-GATE-entered or IMPLEMENTER record on $CURRENT_TASK carries a timestamp that is not single-line ISO-8601-UTC (cycle_opened_ts=${cycle:-<none>} latest_implementer_ts=${impl:-<none>}), so the comparison could not be established"
                return 0
            fi
            if [ "$GATE_STATUS" = "entered" ] && [ -z "$cycle" ]; then
                F1_BINDING_VERDICT="unestablished"
                F1_BINDING_DETAIL="the qa-gate-entered LABEL says a review cycle is open on $CURRENT_TASK but no 'QA-GATE: entered' record came back from bd — the label and the record stream disagree (the bd-1.1.2 comment-inlining change produces exactly this), so the comparison could not be established"
                return 0
            fi
            if [ -z "$impl" ]; then
                F1_BINDING_VERDICT="safe"
                F1_BINDING_DETAIL="no IMPLEMENTER record on $CURRENT_TASK, so no implementation is in flight for this fast path to speak over"
                return 0
            fi
            if [ -z "$cycle" ]; then
                F1_BINDING_VERDICT="implementer-newer"
                F1_BINDING_DETAIL="an IMPLEMENTER record on $CURRENT_TASK (at $impl) exists and NO review cycle was ever opened on it, so there is nothing for that record to be older than"
                return 0
            fi
            if [ "$impl" = "$cycle" ]; then
                # A tie is REFUSED, and that is a deliberate strengthening of
                # "newer than". Both grammars stamp whole seconds, so an
                # `enter` and a spawn in the same second are genuinely
                # unorderable — and the two directions are not symmetric: a
                # false refusal costs one ordinary QA round, a false approval
                # is the defect.
                F1_BINDING_VERDICT="implementer-newer"
                F1_BINDING_DETAIL="an IMPLEMENTER record on $CURRENT_TASK carries the SAME second as the cycle open ($impl), which whole-second stamps cannot order — refused rather than guessed"
                return 0
            fi
            oldest=$(printf '%s\n%s\n' "$cycle" "$impl" | LC_ALL=C sort | head -1)
            if [ "$oldest" = "$impl" ]; then
                F1_BINDING_VERDICT="safe"
                F1_BINDING_DETAIL="the newest IMPLEMENTER record on $CURRENT_TASK (at $impl) predates the current cycle open (at $cycle), so it belongs to a previous cycle"
                return 0
            fi
            F1_BINDING_VERDICT="implementer-newer"
            F1_BINDING_DETAIL="an IMPLEMENTER record on $CURRENT_TASK (at $impl) is NEWER than the cycle this gate opened (QA-GATE: entered at $cycle), so implementation work is in flight that a doc-only verdict cannot speak for"
        }
        f1_binding_verdict
        #
        # THE NOTE IS COMPOSED HERE, not inside the `case` arm below, and that
        # placement is the fix for a real gap rather than a tidy-up. When bd is off
        # PATH `qa-gate.sh status` cannot answer either, so GATE_STATUS is `error`,
        # the arm never runs, and a note written inside it would never be set — the
        # Stop would block (correctly) while saying nothing about the refusal
        # (incorrectly). Composing it out here covers every status on which F1 was
        # eligible OR unreadable, which is exactly the set where "the fast path was
        # considered and declined" is information the operator needs.
        #
        # `blocked` and `approved` are excluded deliberately: F1 was never going to
        # fire on those, so the note would be noise about a path that was not taken
        # for an unrelated reason.
        if [ "$F1_BINDING_VERDICT" != "safe" ]; then
            case "$GATE_STATUS" in
                not-entered|entered|pending|error|"")
                    F1_BINDING_NOTE="The $FASTPATH_CLASS fast path (F1) did NOT auto-approve this Stop (claude-workflow-plugin-qzv).

Why: $F1_BINDING_DETAIL.

F1's verdict is a statement about a CHANGE SET (\"no reviewable source
changed\"); the qa-approved label it writes is a statement about a TASK. When an
implementer is in flight — or when whether one is in flight cannot be
established — those are not the same proposition, so the fast path declines and
the ordinary review path below applies. This is not a failure state: run the QA
round, or, if the implementation really is finished, let its completion contract
and review land first.

Diagnose the two records this compared:
  bash .claude/scripts/review-check.sh gate $CURRENT_TASK
(read cycle_opened_ts and latest_implementer_ts in the envelope)"
                    log_sync_error "Stop: F1 $FASTPATH_CLASS fast path declined to auto-approve $CURRENT_TASK (verdict=$F1_BINDING_VERDICT, gate_status=${GATE_STATUS:-<unreadable>}): $F1_BINDING_DETAIL (qzv)"
                    ;;
            esac
        fi
        # F1-CHANGE-SET-BINDING END (qzv)

        case "$GATE_STATUS" in
            not-entered|entered|pending)
                # F1-CHANGE-SET-BINDING BEGIN (qzv)
                # The guard. Its closing `fi` is in the region at the end of this
                # arm, so stripping both regions restores the pre-qzv arm exactly —
                # which is what the META measures. There is no `else`: the note and
                # the log line are composed above, where they are reachable on the
                # statuses this arm does not match. The arm's body keeps its
                # original indentation deliberately; re-indenting it would bury a
                # behavioural change in a whitespace diff.
                if [ "$F1_BINDING_VERDICT" = "safe" ]; then
                # F1-CHANGE-SET-BINDING END (qzv)
                # Ensure the gate is entered first (so approve is well-formed).
                "$QA_GATE" enter "$CURRENT_TASK" >/dev/null 2>&1 || log_sync_error "qa-gate enter failed during F1 $FASTPATH_CLASS fast path for $CURRENT_TASK"
                # V3 (jio.1): --no-review is REQUIRED on this path. A doc-only
                # / beads-state / empty change-set has no implementer and
                # nothing for an independent reviewer to review, so approve's
                # review-separation refusal would deadlock every documentation
                # commit. The flag records WHY in the approval comment
                # (`[review bypass: ...]`), which is also the marker the Stop
                # hook's review-discipline check skips on — so the audited
                # decision is made once, here, and honoured downstream.
                #
                # qzv: --expect-hash names the change set THIS Stop classified
                # (captured above, before `enter` could move it). approve refuses
                # if what it is about to bind is a different set, so a path that
                # arrived in the meantime can no longer be approved under a
                # doc-only verdict that never saw it. On the stripped-META copy
                # the variable is still computed and simply not passed, which is
                # the pre-qzv call.
                #
                # P7: --no-completion is REQUIRED on this path, for the same
                # reason --no-review is. approve now refuses without a recorded
                # F7 completion contract, and this path's whole premise is that
                # there was no specialist to write one — the change set is
                # documentation, Beads state, or empty. Without the flag every
                # doc-only Stop would deadlock on a payload nobody owes. The
                # reason lands in the approval comment as
                # `[completion bypass: ...]`, so the audited decision is made
                # once, here, and is visible to whoever reads the task later.
                #
                # NOTE this bypass is not "F1 tasks never have a specialist" —
                # a specialist may well have written the documentation. It is
                # "this VERDICT is about a change set with nothing reviewable in
                # it", which is the same scope --no-review has. A task whose
                # specialist DID post a contract still gets it recorded; the
                # flag only stops the absence from blocking.
                #
                # qzv.3: approve's OUTPUT is captured rather than discarded, and
                # its exit status is kept. Both are declared here, OUTSIDE the
                # F1-APPROVE-REFUSAL region below, carrying the PRE-FIX
                # (releasing) default — the same discipline F1_BINDING_VERDICT
                # uses. With that region stripped this call still runs, still
                # logs the same sync-error line, and still falls through to the
                # cleanup and `echo "{}"`: byte-for-byte the behaviour that
                # shipped before qzv.3, which is what makes the META measure the
                # guard instead of dying on an unset variable.
                #
                # `2>&1` into the variable, not `>/dev/null 2>&1`: approve's
                # refusals are structured JSON on STDOUT carrying error_key +
                # observations, and a block that cannot name which refusal fired
                # is a dead end for whoever has to fix it.
                F1_APPROVE_RC=0
                F1_APPROVE_OUT=""
                F1_APPROVE_OUT=$("$QA_GATE" approve "$CURRENT_TASK" \
                    --no-review "F1 $FASTPATH_CLASS fast path: no reviewable source changed" \
                    --no-completion "F1 $FASTPATH_CLASS fast path: no specialist, no completion payload" \
                    ${F1_EXPECT_ARGS[@]+"${F1_EXPECT_ARGS[@]}"} \
                    "$FASTPATH_REASON" 2>&1) || F1_APPROVE_RC=$?
                if [ "$F1_APPROVE_RC" -ne 0 ]; then
                    log_sync_error "qa-gate approve failed during F1 $FASTPATH_CLASS fast path for $CURRENT_TASK (change set classified as $FASTPATH_CLASS, hash=${F1_CLASSIFIED_HASH:-<unavailable>}, approve exit $F1_APPROVE_RC); no approval was recorded"
                fi
                # F1-APPROVE-REFUSAL BEGIN (claude-workflow-plugin-qzv.3)
                #
                # A REFUSED APPROVAL MUST NOT RELEASE THE STOP, AND MUST NOT
                # DESTROY THE CHANGE SET ON THE WAY OUT.
                #
                # THE DEFECT, reproduced against these scripts before this was
                # written (component fixture, shipped hooks, real qa-gate.sh;
                # remove .claude/scripts/impact-report.sh — a partially-synced
                # install, the degradation class vbs-qzv-4/-5 already model —
                # then drive a doc-only Stop on an entered task):
                #
                #   Stop decision            : ALLOW  (bare {} — it RELEASED)
                #   QA-GATE APPROVED records : 0      (nothing was approved)
                #   labels                   : devops,qa-gate-entered,qa-pending
                #   changed-files.txt        : WIPED
                #   current-task             : survives
                #   sync-errors.log          : "qa-gate approve failed … no
                #                               approval was recorded"
                #
                # The old form was `approve … >/dev/null 2>&1 || log_sync_error`,
                # then straight on to the `rm -f` cleanup and `echo "{}"; exit 0`.
                # So ANY non-zero approve was logged and ignored — the gate
                # released a change set, recorded no approval for it, and
                # destroyed the tracker that named it. One line in
                # sync-errors.log was the only trace, and the wipe is what made
                # the failure self-erasing rather than merely silent.
                #
                # WHAT REACHES HERE, so the availability cost is stated rather
                # than discovered. This turns a path that ALWAYS released into
                # one that can block, on all three fast-path classes:
                #   * impact_report_unverifiable / _missing / _invalid — a
                #     partially-synced or half-installed tree. This is the
                #     reproduction above, and it is exactly the shape LESSONS
                #     already records going undetected for a whole run.
                #   * expected_hash_mismatch — a path that arrived between F1's
                #     classification and this approval. NOT a degraded install:
                #     it is qzv's own refusal, and until now it was swallowed
                #     too, so the guard qzv shipped ended in a silent release.
                #   * exit 3 — approve rolled back a partial label write.
                # NOT reachable: change_set_reconstructed and
                # tracker_unreconcilable. The hook's own unconditional
                # reconcile-tracker fail-closes above, so the in-arm `enter` is
                # an idempotent reconcile — QA's round-8 reasoning on that point
                # was checked and holds.
                #
                # THE TRACKER SURVIVES BECAUSE THE CLEANUP IS NOW SCOPED TO A
                # SUCCESSFUL APPROVAL. emit_block exits before the `rm -f` block
                # below, and that ordering is the fix: a block whose recovery
                # needs the change set, delivered over a wiped change set, is
                # unrecoverable. NOTHING IN qa-gate.sh MOVED FOR THIS — in
                # particular the gz3 APPROVE-COMMIT ORDER (baseline before
                # tracker, session state last) is untouched, because approve's
                # refusals all exit BEFORE that finalization and never reach it.
                # This states the same rule from the hook's side that
                # claude-workflow-plugin-qzv.2 has to decide for the SUCCESS
                # path: the F1 arm may finalize tracking state only for an
                # approval that actually happened. qzv.2 narrows WHICH cycle's
                # state a successful approval may finalize; this fixes that a
                # FAILED one finalizes any.
                #
                # The sentinel comments are load-bearing: an L2 META strips this
                # region and asserts the identical Stop RELEASES with zero
                # approval records and a WIPED tracker — the live defect. Do not
                # rename them.
                if [ "$F1_APPROVE_RC" -ne 0 ]; then
                    F1_APPROVE_KEY=$(printf '%s' "$F1_APPROVE_OUT" | jq -r '.error_key // empty' 2>/dev/null) || F1_APPROVE_KEY=""
                    F1_APPROVE_OBS=$(printf '%s' "$F1_APPROVE_OUT" | jq -r '.observations // empty' 2>/dev/null) || F1_APPROVE_OBS=""
                    if [ -z "$F1_APPROVE_OBS" ]; then
                        # No parseable envelope. Under the pre-qzv.3 scripts this
                        # was the NORMAL shape of the failure rather than an edge
                        # case: `approve` died under `set -e` on an unguarded
                        # `current_hash=$(compute_change_set_hash)` and emitted
                        # empty stdout AND empty stderr. That is fixed in
                        # qa-gate.sh (ERREXIT-HASH-GUARD), so this arm now covers
                        # a genuinely unparseable answer — an older qa-gate.sh on
                        # disk, or a crash — and says so instead of printing an
                        # empty section.
                        F1_APPROVE_OBS="(approve produced no parseable JSON envelope; raw output follows)
${F1_APPROVE_OUT:-<empty — approve wrote nothing to stdout or stderr>}"
                    fi
                    log_sync_error "Stop BLOCKED: F1 $FASTPATH_CLASS fast path refused for $CURRENT_TASK (approve exit $F1_APPROVE_RC${F1_APPROVE_KEY:+, error_key=$F1_APPROVE_KEY}); the change-set tracker was preserved (qzv.3)"
                    emit_block "QA gate cannot release: the $FASTPATH_CLASS fast path (F1) tried to
auto-approve this change set and \`qa-gate.sh approve\` REFUSED.

Nothing was approved. This Stop does NOT release.

  task        : $CURRENT_TASK
  class       : $FASTPATH_CLASS
  change set  : ${F1_CLASSIFIED_HASH:-<hash unavailable>}
  approve exit: $F1_APPROVE_RC${F1_APPROVE_KEY:+
  error_key   : $F1_APPROVE_KEY}

approve reported:
$F1_APPROVE_OBS

Why this blocks rather than releasing (claude-workflow-plugin-qzv.3): F1's
whole claim is \"nothing reviewable changed, so this is approved without a
review\". When the approval it drives does not happen, that claim was never
recorded — releasing anyway would ship a change set with no approval and no
reviewer, which is the outcome the gate exists to prevent.

YOUR CHANGE SET IS INTACT. .claude/.qa-tracking/changed-files.txt is NOT
truncated on this path, so whatever you fix below, the set is still there to
re-approve. Confirm with:
  wc -l .claude/.qa-tracking/changed-files.txt
  bash .claude/scripts/impact-report.sh --hash-only

Fix, in the order these actually occur:
  1. A partially-synced install. impact_report_* means
     .claude/scripts/impact-report.sh is missing or failing — restore it from
     the plugin and re-run the Stop. Check the whole directory, not just that
     one file; a tree that lost one script has usually lost more.
  2. A change set that moved. expected_hash_mismatch means a file arrived
     between the moment F1 classified this set and the moment approve went to
     bind it, so the doc-only verdict does not cover what would ship. Re-derive
     and look at what appeared:
       bash .claude/scripts/impact-report.sh --hash-only
       cat .claude/.qa-tracking/changed-files.txt
     If the newcomer is reviewable source, this needs a real QA round.
  3. Anything else: run the same approval by hand and read the full envelope —
       bash .claude/scripts/qa-gate.sh approve $CURRENT_TASK \\
         --no-review 'F1 $FASTPATH_CLASS fast path: no reviewable source changed' \\
         --no-completion 'F1 $FASTPATH_CLASS fast path: no specialist, no completion payload' \\
         'manual re-run of the F1 approval'

The full history is in .claude/.qa-tracking/sync-errors.log."
                fi
                # F1-APPROVE-REFUSAL END (claude-workflow-plugin-qzv.3)
                #
                # THE TASK IS NOT CLOSED HERE (qzv). This used to run
                # `bd update <tid> --status closed`, and it was the second of the
                # live defect's four effects. A doc-only Stop is not evidence a
                # task is finished: the verdict above is about a CHANGE SET, and
                # closing is a claim about the TASK's work. Nothing in a change
                # set can tell you whether a task's acceptance criteria are met,
                # so the close was structurally a guess — one that also silently
                # overrode whatever the orchestrator intended for the task (the
                # v4.1.0 release task was closed this way, 22 seconds into its
                # implementer's spawn).
                #
                # No close HINT is emitted on this path either, deliberately, and
                # for the same reason: an F1 verdict is not evidence about the
                # task at all, so suggesting a close would re-commit the category
                # error in prose. The approved path further down does emit one,
                # because there a real review of a real change set happened.
                #
                # Clean up tracking artifacts. Includes per-task iteration
                # counter (legacy unscoped path is also cleared so users
                # upgrading don't keep stale state).
                rm -f "$QA_TRACKING_DIR/changed-files.txt" 2>/dev/null || true
                rm -f "$QA_TRACKING_DIR/edit-count" 2>/dev/null || true
                rm -f "$(iteration_file_for "$CURRENT_TASK")" 2>/dev/null || true
                rm -f "$ITERATION_FILE_LEGACY" 2>/dev/null || true
                # 2ty: the auto-defer counter is per-cycle state like the counter
                # above it, so an F1 approval clears it for the same reason.
                rm -f "$(escalated_stops_file_for "$CURRENT_TASK")" 2>/dev/null || true
                echo "{}"; exit 0
                # F1-CHANGE-SET-BINDING BEGIN (qzv)
                # Refused: fall THROUGH to the QA-required block — never
                # auto-approve, and never allow. The reason it declined is already
                # in F1_BINDING_NOTE, composed above.
                fi
                # F1-CHANGE-SET-BINDING END (qzv)
                ;;
        esac
    elif [ "$FASTPATH_CLASS" = "beads-state" ] || [ "$FASTPATH_CLASS" = "empty" ]; then
        # No active task AND nothing reviewable changed (beads/gate state or
        # an empty post-denylist set). There is no code to gate, so allow
        # immediately — blocking here is the exact false-block the bug report
        # captured (a Stop fired right after a gate label-write, no task set,
        # demanding QA on a `.beads/issues.jsonl | 2 +-` diff). doc-only with
        # no task still falls through (it MAY carry reviewable intent a human
        # wants to see; beads/empty never does).
        log_sync_error "Stop allowed: $FASTPATH_CLASS change-set with no active task (nothing reviewable; F1 fast path)"
        echo "{}"; exit 0
    fi
    # doc-only with no active task - we can't auto-approve, but we can still
    # skip the test/lint pass since the changes are doc-only. Fall through to
    # the QA-required messaging with a hint.
fi

# B3 + MATERIAL 5 fix: the iteration counter is keyed by CURRENT_TASK so
# abandoning task A at iter=3 and switching to task B does NOT make B start at
# iter=4. When CURRENT_TASK is empty we still use the legacy path (single-task /
# no-Beads users).
ITERATION_FILE=$(iteration_file_for "$CURRENT_TASK")

# Spec 0.2: escalation state machine. Read once and act before the suite
# runs so we never repeat the four-loops-past-the-cap behaviour the bug
# report captured. The label reads are best-effort — if bd is missing or
# the task id is empty we fall through to the legacy "always run tests"
# path so single-repo / no-Beads users see no regression.
#
# 2ty: these reads now happen BEFORE the counter is touched, because WHAT THE
# COUNTER MEANS depends on them. See the ITERATION-BUMP region below.
QA_DEFERRED=false
QA_ESCALATED=false
if [ -n "$CURRENT_TASK" ]; then
    if task_has_label "$CURRENT_TASK" "qa-deferred"; then QA_DEFERRED=true; fi
    if task_has_label "$CURRENT_TASK" "qa-escalated"; then QA_ESCALATED=true; fi
fi

# 2ty: the stack is detected ONCE, here, because the bump decision below has to
# know whether this Stop has anything to run before it charges an iteration for
# it. The suite section further down consumes THIS json rather than re-invoking
# the detector — one probe, one answer, and no way for the two reads to disagree
# about what this Stop was going to do. detect-stack.sh is a read-only file
# inspection, so the escalated/deferred paths pay a few milliseconds for a
# boolean they use and nothing else; RUNNER / TEST_CMD / LINT_CMD / TYPE_CMD are
# still parsed in the suite block, so the escalated REPLAY still takes its runner
# name from the cache exactly as before.
DETECT_JSON="{}"
if [ -x "$DETECT_STACK" ]; then
    DETECT_JSON=$("$DETECT_STACK" 2>/dev/null || echo "{}")
fi

# ITERATION-BUMP BEGIN (claude-workflow-plugin-2ty)
#
# THE COUNTER CHARGES VERIFICATION ITERATIONS, NOT STOP-HOOK PASSES.
#
# THE DEFECT, measured three times in one session (2026-08-05, recorded on this
# task with numbers): the counter incremented once per Stop fire, and an
# orchestrator waiting on a long review — or one interrupted by infrastructure —
# necessarily Stops repeatedly. So the cost of a THOROUGH review was charged to
# the same budget as defect rounds:
#   * qzv.1: counter 3, review verdicts 1, gate entries 6.
#   * 8zi:   counter 3, review artifacts 0, all three bumps caused by three 529
#            API errors and one stream-watchdog stall.
#   * 8zi:   counter 3 AGAIN, while the reviewer was actively mid-review.
# None of the three involved a finding or a failing test.
#
# WHY IT COSTS SOMETHING RATHER THAN BEING BOOKKEEPING: reaching the cap forces
# a J21 decision, and the DEFAULT when none is recorded by the next Stop is
# DEFER, which sets qa-deferred and lets the following Stop RELEASE. So an
# over-charging counter steers work toward release-without-approval on a timer,
# driven by nothing connected to review quality.
#
# THE RULE: bump only when this Stop will actually run a verification pass.
# Two states are excluded, and each was already charged before:
#   1. qa-escalated — the escalation contract explicitly does NOT re-run the
#      suite (see the replay branch below). The Stop that triggered escalation on
#      8zi said so in its own output while charging for it.
#   2. qa-deferred — the Stop is allowed through immediately; nothing runs.
# And one that was charged and should never have been:
#   3. no test/lint/type command is configured at all. There is no suite, so
#      "iteration N of 3" was pure poll-counting. On such a project the
#      escalation basis is now review ROUNDS alone (see ESCALATION-BASIS below),
#      which is the quantity J21 is named for.
#
# The read path uses read_iteration, which does NOT write, so a Stop that runs
# nothing also leaves the counter untouched for the next one.
#
# `jq -e` decides case 3 POSITIVELY: only a detector answer that proves all three
# commands are empty suppresses the bump. A malformed or unreadable answer keeps
# today's always-bump behaviour rather than silently freezing the counter — an
# unestablished input must never quietly disable the machinery it feeds.
VERIFY_CMD_PRESENT=true
if printf '%s' "$DETECT_JSON" \
    | jq -e '((.test_cmd // "") == "") and ((.lint_cmd // "") == "") and ((.type_cmd // "") == "")' \
        >/dev/null 2>&1; then
    VERIFY_CMD_PRESENT=false
fi
VERIFY_WILL_RUN=false
if [ "$QA_DEFERRED" != "true" ] && [ "$QA_ESCALATED" != "true" ] \
    && [ "$VERIFY_CMD_PRESENT" = "true" ]; then
    VERIFY_WILL_RUN=true
fi
if [ "$VERIFY_WILL_RUN" = "true" ]; then
    ITER=$(bump_iteration "$ITERATION_FILE")
else
    ITER=$(read_iteration "$ITERATION_FILE")
fi
# ITERATION-BUMP END (claude-workflow-plugin-2ty)

# Spec 0.2 escape valve: if qa-deferred is set on the active task, allow
# this Stop immediately. The user explicitly recorded "defer" (or the
# gate auto-deferred after escalation went unanswered) — re-running the
# block here would defeat the choice. Principle 6 says this is the
# single audited Stop-hook escape; we don't touch labels or counters,
# so a future re-enter on this task naturally resumes normal gating.
if [ "$QA_DEFERRED" = "true" ]; then
    log_sync_error "Stop allowed under qa-deferred label for $CURRENT_TASK (iteration $ITER)"
    echo "{}"; exit 0
fi

# Spec 0.2 auto-defer: if qa-escalated has been set for at least one
# prior Stop AND no recorded J21 choice has arrived in time, auto-pick
# option 4 (defer).
#
# 2ty: the THRESHOLD MOVED OFF THE ITERATION COUNTER onto its own. It used to
# read `ITER > MAX_ITERATIONS + 1`, i.e. "two Stops past the cap" — which worked
# only because the iteration counter charged every Stop, including the escalated
# ones that run nothing. With the counter now charging verification iterations
# only (see ITERATION-BUMP above), ITER FREEZES at the cap under escalation and
# that predicate could never fire again: a documented escape would have become
# silently unreachable, and the L2 acceptance ("lands on a recorded J21 decision
# by iteration 5 at the latest") would have been quietly false.
#
# So the quantity auto-defer actually wants is counted directly: how many Stops
# have fired while the task was ALREADY escalated, i.e. how many chances the
# agent has had to record a choice. That is legitimately a STOP count — nothing
# about it pretends to measure defect rounds — and counting it separately keeps
# BOTH signals honest. Timing is preserved Stop-for-Stop (see
# AUTO_DEFER_AFTER_ESCALATED_STOPS).
#
# The bump is here rather than beside the iteration counter because the
# qa-deferred escape above must exit BEFORE it: a deferred Stop is not a chance
# to answer, the question has already been answered.
ESCALATED_STOPS=0
if [ "$QA_ESCALATED" = "true" ]; then
    ESCALATED_STOPS=$(bump_iteration "$(escalated_stops_file_for "$CURRENT_TASK")")
fi
if [ "$QA_ESCALATED" = "true" ] && [ -n "$CURRENT_TASK" ] \
    && [ "$ESCALATED_STOPS" -ge "$AUTO_DEFER_AFTER_ESCALATED_STOPS" ]; then
    if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
        bd label add "$CURRENT_TASK" qa-deferred >/dev/null 2>&1 \
            || log_sync_error "auto-defer: bd label add qa-deferred failed for $CURRENT_TASK"
        # Use bd comments (qa-gate.sh's add_comment wraps this pair) so
        # the audit trail mirrors a manual `qa-gate.sh choose defer`.
        AUTO_DEFER_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
        AUTO_DEFER_NOTE="QA-GATE AUTO-DEFER at $AUTO_DEFER_TS: auto-deferred after $ESCALATED_STOPS escalated Stop(s) with no recorded J21 choice (verification iteration $ITER); task remains qa-pending"
        bd comments add "$CURRENT_TASK" "$AUTO_DEFER_NOTE" >/dev/null 2>&1 \
            || bd comment add "$CURRENT_TASK" "$AUTO_DEFER_NOTE" >/dev/null 2>&1 \
            || log_sync_error "auto-defer: comment add failed for $CURRENT_TASK"
    fi
    log_sync_error "Stop auto-deferred for $CURRENT_TASK after $ESCALATED_STOPS escalated Stop(s) with no J21 choice (verification iteration $ITER)"
    echo "{}"; exit 0
fi

# ESCALATION-BASIS BEGIN (claude-workflow-plugin-2ty)
#
# ESCALATE ON max(VERIFICATION ITERATIONS, REVIEW ROUNDS) — AND NOT AT ALL WHILE
# A REVIEWER HAS CLAIMED THE CYCLE AND NOT YET SPOKEN.
#
# Two independent signals, because the iteration counter alone was authoritative
# and should not be:
#
#   ROUNDS — how many `REVIEW-ARTIFACT v1` records on this task carry
#   `reviewed_hash=` equal to the CURRENT change-set hash. This is the quantity
#   J21 is named for ("this change set has needed N rounds"), it is immune to how
#   often the orchestrator polls, and it RESETS when the change set moves, which
#   is correct: a new change set has needed no rounds yet. Counted by
#   review-check.sh — the ONE record parser — not re-implemented here, the same
#   discipline current_change_set_hash follows for the hash itself.
#
#   REVIEW_IN_FLIGHT — a cycle is open (the qa-gate-entered LABEL agrees with a
#   `QA-GATE: entered` RECORD) and ZERO artifacts exist for the current hash.
#   That state means a reviewer has claimed this cycle and has not yet reported.
#   Escalating there is never useful: nobody has disagreed with anything, because
#   nobody has spoken. This is what makes the third measured instance — the
#   escalation that fired WHILE the reviewer was mid-review, racing the counter
#   against the reviewer for whether the verdict would matter — impossible rather
#   than merely less likely.
#
# THE SUPPRESSION IS SCOPED TO "NOTHING IS FAILING", and that scope is
# load-bearing rather than cautious. When the suite is RED the evidence for
# escalating is the red suite, not the reviewer's silence — J21 exists precisely
# to ask "you have tried three times to fix this; approve / continue / debt /
# defer". A cycle is open during almost all implementation work, so an unscoped
# suppression would delete the J21 escape from the failing-test loop entirely.
# The check therefore lives in mark_escalation_if_capped, guarded on an empty
# FAILED_CHECKS, and every one of the three measured instances was a
# nothing-failing Stop ("technical checks passed").
#
# NEVER FAIL OPEN, in the specific sense that matters here: if ROUNDS cannot be
# ESTABLISHED — no active task, no review-check.sh, no computable change-set
# hash, an envelope with no `rounds` key (a pre-2ty or partially-synced copy) —
# the basis falls back to ITER alone, suppression does not apply, and the
# escalation machinery behaves exactly as it does today. An unavailable new
# signal must not be able to disable the old one, and the block reason names
# which of the two it used (ROUNDS_UNAVAILABLE_REASON, rendered by
# escalation_basis_note) rather than printing a number whose provenance the
# reader has to infer.
#
# ORDERING: this runs BEFORE the suite. The change-set hash it compares against
# is therefore a pre-suite read, so a path that arrives during a 20-minute test
# run leaves ROUNDS counted against the older hash — which can only ever
# OVER-count (the older hash is the one the existing artifacts were written for),
# i.e. it degrades toward today's escalation behaviour and never toward
# suppressing one. The release predicate further down keeps its own post-suite
# read; see the review-discipline block.
ROUNDS=""                       # empty string = NOT established (never "0")
ROUNDS_HASH=""
REVIEW_IN_FLIGHT=false
ESCALATION_BASIS="$ITER"
ROUNDS_UNAVAILABLE_REASON=""   # set by the probe when rounds cannot be established
# Stored review-gate probe, so the release predicate below can reuse this Stop's
# read instead of taking a second one when nothing has happened in between.
REVIEW_GATE_PROBED=false
REVIEW_GATE_RC=0
REVIEW_GATE_OUT=""

review_rounds_probe() {
    local have="" ekey="" cycle=""
    if [ -z "$CURRENT_TASK" ]; then
        ROUNDS_UNAVAILABLE_REASON="review rounds unavailable (no active Beads task, so no review record can be attributed to this change set); escalation basis is the verification-iteration count alone"
        return 0
    fi
    if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
        ROUNDS_UNAVAILABLE_REASON="review rounds unavailable (the review predicate $REVIEW_CHECK_SCRIPT is missing); escalation basis is the verification-iteration count alone"
        return 0
    fi
    # `|| true` for the same set -e fail-open class the CURRENT_CS_HASH guard
    # below documents: current_change_set_hash returns 1 when impact-report.sh is
    # absent, and a bare assignment whose RHS exits non-zero aborts the hook —
    # which emits nothing, which the hooks contract reads as NON-blocking.
    ROUNDS_HASH=$(current_change_set_hash) || true
    if [ -z "$ROUNDS_HASH" ]; then
        ROUNDS_UNAVAILABLE_REASON="review rounds unavailable (the current change-set hash could not be recomputed, so no artifact can be matched to it); escalation basis is the verification-iteration count alone"
        return 0
    fi
    REVIEW_GATE_RC=0
    REVIEW_GATE_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" \
        gate "$CURRENT_TASK" --change-set-hash "$ROUNDS_HASH" 2>&1) || REVIEW_GATE_RC=$?
    REVIEW_GATE_PROBED=true
    # A NON-ZERO rc IS NOT THE DISCRIMINATOR — `gate` exits 4 for
    # review_artifact_missing, which is the normal answer on a task whose review
    # has not landed yet and exactly the state ROUNDS=0 has to describe. The
    # presence of the field is the discriminator, as it is for the F1 fast path's
    # cycle_opened_ts.
    have=$(printf '%s' "$REVIEW_GATE_OUT" | jq -r 'if (type == "object" and has("rounds")) then "yes" else "no" end' 2>/dev/null) || have="no"
    [ -n "$have" ] || have="no"
    if [ "$have" != "yes" ]; then
        ekey=$(printf '%s' "$REVIEW_GATE_OUT" | jq -r '.error_key // ""' 2>/dev/null) || ekey=""
        ROUNDS_UNAVAILABLE_REASON="review rounds unavailable (review-check.sh answered without a rounds field${ekey:+; error_key=$ekey} — a pre-2ty or partially-synced copy, or its own dependency is missing); escalation basis is the verification-iteration count alone"
        return 0
    fi
    ROUNDS=$(printf '%s' "$REVIEW_GATE_OUT" | jq -r '.rounds // 0' 2>/dev/null) || ROUNDS=""
    case "$ROUNDS" in
        ''|*[!0-9]*)
            ROUNDS=""
            ROUNDS_UNAVAILABLE_REASON="review rounds unavailable (review-check.sh reported a non-numeric rounds value); escalation basis is the verification-iteration count alone"
            return 0
            ;;
    esac
    # A cycle is OPEN only when the label and the record AGREE. bd 1.1.2 stopped
    # inlining comment bodies, so a record reader can come back empty while the
    # labels still read fine (the failure this repo has already lived through) —
    # requiring both means that degradation reads as "not in flight", i.e. it
    # falls back to today's escalation behaviour instead of suppressing on an
    # absence it could not verify.
    cycle=$(printf '%s' "$REVIEW_GATE_OUT" | jq -r '.cycle_opened_ts // ""' 2>/dev/null) || cycle=""
    if [ "$ROUNDS" = "0" ] && [ -n "$cycle" ] && [ "$cycle" != "unparseable" ] \
        && task_has_label "$CURRENT_TASK" "qa-gate-entered"; then
        REVIEW_IN_FLIGHT=true
    fi
}
review_rounds_probe
if [ -n "$ROUNDS" ] && [ "$ROUNDS" -gt "$ESCALATION_BASIS" ]; then
    ESCALATION_BASIS="$ROUNDS"
fi
# ESCALATION-BASIS END (claude-workflow-plugin-2ty)

# F8/J17 + B3: detect runner and run test/lint/type-check with timeouts.
# Spec 0.2: while qa-escalated is set we MUST NOT re-run the full suite;
# we reuse whatever the cap-hit Stop cached. This was the production bug.
RUNNER="none"
TEST_CMD=""
LINT_CMD=""
TYPE_CMD=""

FAILED_CHECKS=""
TEST_FAIL_TAIL=""
LINT_FAIL_TAIL=""
TYPE_FAIL_TAIL=""
TEST_FAIL_CLASS=""        # "runner" | "assertion" | "" (set when we re-run or replay)
SUITE_REUSED=false        # true when this Stop reused cached results

if [ "$QA_ESCALATED" = "true" ]; then
    # Replay the cached state. If anything is missing we fall back to
    # treating this as a generic block — better than running the suite
    # under escalation, which would reintroduce the bug. We do not
    # currently consume last-test-rc on the replay path (the cached
    # FAILED_CHECKS already carries the rendered wording), but the file
    # exists for diagnostics / future use.
    LFC_FILE=$(last_failed_checks_file_for "$CURRENT_TASK")
    LRN_FILE=$(last_runner_file_for "$CURRENT_TASK")
    if [ -s "$LFC_FILE" ]; then
        # Prefer the literal-newline form of the previously rendered
        # FAILED_CHECKS so we don't need to re-derive the tail. The
        # file may contain plain text including the rendered tails;
        # we just slurp it.
        FAILED_CHECKS=$(cat "$LFC_FILE" 2>/dev/null || echo "")
    fi
    [ -s "$LRN_FILE" ] && RUNNER=$(head -1 "$LRN_FILE" | tr -d '\r\n')
    SUITE_REUSED=true
else
    # 2ty: DETECT_JSON was captured ONCE, above the iteration-bump decision (the
    # bump has to know whether this Stop has a suite to run before it charges an
    # iteration for it). The detector is NOT re-invoked here — one probe, one
    # answer. `[ -x ]` still guards the parse so a missing detector leaves the
    # pre-existing RUNNER=none / empty-command defaults exactly as before.
    if [ -x "$DETECT_STACK" ]; then
        RUNNER=$(echo "$DETECT_JSON" | jq -r '.runner // "none"' 2>/dev/null || echo "none")
        TEST_CMD=$(echo "$DETECT_JSON" | jq -r '.test_cmd // ""' 2>/dev/null || echo "")
        LINT_CMD=$(echo "$DETECT_JSON" | jq -r '.lint_cmd // ""' 2>/dev/null || echo "")
        TYPE_CMD=$(echo "$DETECT_JSON" | jq -r '.type_cmd // ""' 2>/dev/null || echo "")
    fi

    # J19: regression-coverage framing. We always run the FULL test suite
    # + FULL type-check (when configured), not just for changed files.
    # This is essential because changes in module A might break module B's
    # contract; only running A's tests would miss B's failure. Document
    # this in the block reason when checks fail so the operator (or
    # Claude) understands why the suite is wider than the diff.
    #
    # NOTE on capturing exit codes under `set -e`:
    #   The pattern `if ! cmd; then rc=$?; fi` is BROKEN under `set -e`
    #   because the `if !` branch resets `$?` to 0 before the inner block
    #   runs. We must capture rc in the same statement as the call
    #   itself, e.g.:
    #       rc=0; cmd || rc=$?
    #   This preserves the real exit code (124 for GNU `timeout`, anything
    #   else for genuine failures) so downstream branches can distinguish
    #   timeout from failure.

    test_rc=0
    if [ -n "$TEST_CMD" ]; then
        run_with_timeout "$TEST_TIMEOUT_S" "$TEST_LOG" "$TEST_CMD" || test_rc=$?
        if [ "$test_rc" -ne 0 ]; then
            TEST_FAIL_TAIL=$(log_tail "$TEST_LOG" 50)
            # Spec 0.2: classify runner-vs-assertion BEFORE composing
            # the failure header so we lead with the right wording.
            TEST_FAIL_CLASS=$(classify_test_failure "$test_rc" "$TEST_FAIL_TAIL")
            if [ "$test_rc" = "124" ]; then
                FAILED_CHECKS+="- Tests timed out after ${TEST_TIMEOUT_S}s — see $TEST_LOG\n"
            elif [ "$TEST_FAIL_CLASS" = "runner" ]; then
                # Lead with the environment/runner hint per spec 0.2 so
                # the next iteration targets the environment first.
                FAILED_CHECKS+="- Test suite failed to run (environment/runner issue — fix the environment before changing code): exit $test_rc — see $TEST_LOG\n"
            else
                FAILED_CHECKS+="- Tests failing (exit $test_rc) — see $TEST_LOG\n"
            fi
        fi
    fi

    if [ -n "$LINT_CMD" ]; then
        lint_rc=0
        run_with_timeout "$LINT_TIMEOUT_S" "$LINT_LOG" "$LINT_CMD" || lint_rc=$?
        if [ "$lint_rc" -ne 0 ]; then
            if [ "$lint_rc" = "124" ]; then
                FAILED_CHECKS+="- Lint timed out after ${LINT_TIMEOUT_S}s — see $LINT_LOG\n"
            else
                FAILED_CHECKS+="- Lint errors (exit $lint_rc) — see $LINT_LOG\n"
            fi
            LINT_FAIL_TAIL=$(log_tail "$LINT_LOG" 50)
        fi
    fi

    if [ -n "$TYPE_CMD" ]; then
        type_rc=0
        run_with_timeout "$TYPE_TIMEOUT_S" "$TYPE_LOG" "$TYPE_CMD" || type_rc=$?
        if [ "$type_rc" -ne 0 ]; then
            if [ "$type_rc" = "124" ]; then
                FAILED_CHECKS+="- Type-check timed out after ${TYPE_TIMEOUT_S}s — see $TYPE_LOG\n"
            else
                FAILED_CHECKS+="- Type-check failing (exit $type_rc) — see $TYPE_LOG\n"
            fi
            TYPE_FAIL_TAIL=$(log_tail "$TYPE_LOG" 50)
        fi
    fi

    # Spec 0.2: persist what we just observed so the next Stop, if it
    # arrives while qa-escalated, can replay without re-running the
    # suite. We persist regardless of pass/fail — qa-gate.sh wipes the
    # files on approve/enter/choose so a stale cache can't follow a
    # task across cycles.
    if [ -n "$CURRENT_TASK" ]; then
        printf '%s' "$test_rc" > "$(last_test_rc_file_for "$CURRENT_TASK")" 2>/dev/null || true
        printf '%s' "$RUNNER" > "$(last_runner_file_for "$CURRENT_TASK")" 2>/dev/null || true
        # We persist the rendered failure body (already includes the
        # leading "- " bullets and the trailing newline). Including the
        # tails would bloat the cache — they get re-derived from the
        # log files which we leave on disk in the same dir.
        if [ -n "$FAILED_CHECKS" ]; then
            printf '%s' "$FAILED_CHECKS" > "$(last_failed_checks_file_for "$CURRENT_TASK")" 2>/dev/null || true
        else
            # Tech-checks passed; clear any stale cache so a future
            # cap-hit while passing tech checks doesn't replay an old
            # failure summary.
            rm -f "$(last_failed_checks_file_for "$CURRENT_TASK")" 2>/dev/null || true
        fi
    fi
fi

# ESCALATION READOUT (claude-workflow-plugin-2ty, QA round 1) -----------------
#
# THE ONE SUPPRESSION PREDICATE, AND WHY IT IS A FUNCTION.
#
# It shipped as three copies of one idea, and they disagreed. Two consulted
# FAILED_CHECKS; the third — the operator-facing paragraph — was COMPOSED IN THE
# ESCALATION-BASIS REGION, which runs BEFORE the suite, so it could not consult
# FAILED_CHECKS even in principle: the variable is not initialised until forty
# lines later. QA reproduced all three consequences on the shipped tree:
#   (a) iteration 1 with a RED suite — the ordinary post-block fix round, the
#       most common block in this workflow — printed "no technical check is
#       failing, the J21 escalation is SUPPRESSED";
#   (b) the cap-hit Stop printed SUPPRESSED one line above its own J21 options;
#   (c) an ALREADY-ESCALATED task whose change set had moved printed SUPPRESSED,
#       then the options, and the NEXT Stop auto-deferred into a release.
# In (c) every antecedent of the sentence holds — a cycle IS open, no artifact
# exists for this hash, nothing IS failing — so it is not a conditional that
# happens not to fire. It is FALSE, on the exact path that releases. An agent
# that believes it does not record the J21 choice that would stop that release,
# which is instance 3's failure mode arriving from a new direction with the gate
# asserting it is not happening.
#
# So the predicate is computed ONCE, HERE, after the suite has run and
# FAILED_CHECKS is real, and the label transition, the J21-options predicate and
# the paragraph all call it. Three callers, one answer, by construction.
#
# `${FAILED_CHECKS:-}` and `${REVIEW_IN_FLIGHT:-false}` are defensive under
# `set -u` rather than decorative: this function is defined above at least one
# path that could grow an earlier caller, and an unbound-variable abort here
# emits nothing, which the hooks contract reads as NON-blocking — i.e. release.
escalation_suppressed() {
    [ "${REVIEW_IN_FLIGHT:-false}" = "true" ] || return 1
    [ -z "${FAILED_CHECKS:-}" ] || return 1
    return 0
}

# escalation_basis_claim — the parenthetical the escalation banners carry.
#
# It exists because "cap reached" and "basis N >= 3" became FALSE-BUT-REACHABLE
# in this same change, and only in it: ITER used to bump on every Stop, so an
# escalated task always carried ITER >= MAX and the claim was safe. Now ITER
# FREEZES under the escalation contract and ROUNDS DROPS when the change set
# moves, while the banners and j21_options_due clause 1 key on the STICKY LABEL.
# QA measured the result: `gate ESCALATED (iteration 1 of 3; cap reached)` and
# `ESCALATION: Iteration 1 (basis 1 >= 3)`.
#
# The honest number is the basis that TRIGGERED the escalation, so that basis is
# persisted at the moment it triggers — into the escalation-posted marker, whose
# EXISTENCE already means "we escalated" and which `wipe_iteration_state` already
# clears with the rest of the per-cycle state. A marker written before this
# change (or by an upgrade mid-cycle) is zero bytes and reads back as 0, so the
# no-number phrasing is the fallback rather than a wrong number.
#
# Only ever rendered when the cap IS met or the label IS set (see the two
# banners and j21_options_due), so the two branches below are exhaustive.
escalation_basis_claim() {
    if [ "$ESCALATION_BASIS" -ge "$MAX_ITERATIONS" ]; then
        printf 'basis %s >= %s; cap reached' "$ESCALATION_BASIS" "$MAX_ITERATIONS"
        return 0
    fi
    local trig
    trig=$(read_iteration "$(escalation_posted_file_for "${CURRENT_TASK:-}")")
    if [ "${trig:-0}" -gt 0 ]; then
        printf 'escalated on an earlier Stop at basis %s; the current basis %s is BELOW the cap of %s' \
            "$trig" "$ESCALATION_BASIS" "$MAX_ITERATIONS"
    else
        printf 'escalated on an earlier Stop; the current basis %s is BELOW the cap of %s' \
            "$ESCALATION_BASIS" "$MAX_ITERATIONS"
    fi
}

# escalation_basis_note — the basis paragraph, composed AT EMISSION TIME.
#
# Called from both block-reason paths after the suite has run. The suppression
# clause is gated on the shared predicate AND on the escalation not already being
# live: an escalated task is by definition not suppressed, whatever the current
# basis says, and that combination is reproduction (c).
escalation_basis_note() {
    if [ -z "$ROUNDS" ]; then
        printf '%s' "${ROUNDS_UNAVAILABLE_REASON:-}"
        return 0
    fi
    printf 'Escalation basis: verification iterations=%s, independent review rounds against this change set=%s (change_set_hash=%s); the cap applies to the larger of the two.' \
        "$ITER" "$ROUNDS" "$ROUNDS_HASH"
    # The next line is a MUTATION ANCHOR, not a strippable region (deleting it
    # would orphan the `fi` below): two L2 METAs rewrite it by substitution, one
    # dropping each clause, because each clause answers a different reproduction —
    # the green-suite clause kills "SUPPRESSED at iteration 1 with a red suite",
    # the live-escalation clause kills "SUPPRESSED on an already-escalated task".
    # Both are load-bearing. Keep the text on ONE line so the anchor stays exact.
    if escalation_suppressed && [ "$QA_ESCALATED" != "true" ]; then
        printf '\n%s' 'A review cycle is OPEN on this task and no REVIEW-ARTIFACT record exists for this
change set yet, so no reviewer has disagreed with anything. While that holds and
no technical check is failing, the J21 escalation is SUPPRESSED — it would be
charging a review for taking time to happen (claude-workflow-plugin-2ty).'
    fi
}

# Spec 0.2: at the moment we first reach the cap, record qa-escalated +
# post the J21 options comment exactly once. The comment marker file
# prevents re-posting on subsequent escalated loops (idempotent).
mark_escalation_if_capped() {
    local tid="$1"
    [ -z "$tid" ] && return 0
    # 2ty: the cap applies to max(verification iterations, review rounds), never
    # to the iteration counter alone. See the ESCALATION-BASIS region.
    if [ "$ESCALATION_BASIS" -lt "$MAX_ITERATIONS" ]; then
        return 0
    fi
    # REVIEW-IN-FLIGHT SUPPRESSION BEGIN (claude-workflow-plugin-2ty)
    # A reviewer has claimed this cycle and has not yet spoken, and NOTHING is
    # failing — so there is nothing to escalate about. The scope (see
    # escalation_suppressed) is deliberate: a red suite is its own evidence and
    # must still reach J21. The sentinels are load-bearing — an L2 META
    # neutralizes this block and asserts the poll-during-review leg escalates
    # again. Do not rename them.
    if escalation_suppressed; then
        log_sync_error "Escalation SUPPRESSED for $tid: basis $ESCALATION_BASIS >= $MAX_ITERATIONS but a review cycle is open with zero REVIEW-ARTIFACT records for change_set_hash=$ROUNDS_HASH and no technical check is failing — the reviewer has not spoken yet (2ty)"
        return 0
    fi
    # REVIEW-IN-FLIGHT SUPPRESSION END (claude-workflow-plugin-2ty)
    if [ "$QA_ESCALATED" = "true" ]; then
        return 0  # already escalated; no relabel, no relog
    fi
    if ! command -v bd >/dev/null 2>&1 || [ ! -d "$PROJECT_DIR/.beads" ]; then
        return 0
    fi
    # Label.
    bd label add "$tid" qa-escalated >/dev/null 2>&1 \
        || log_sync_error "mark_escalation: bd label add qa-escalated failed for $tid"
    # One comment, idempotent via marker file.
    local marker
    marker=$(escalation_posted_file_for "$tid")
    if [ ! -f "$marker" ]; then
        local ts options_text
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
        options_text=$(j21_options_block "$tid")
        # 2ty: the record NAMES ITS BASIS. "iteration 3 >= 3" was the whole
        # problem when the 3 came from three Stop-hook passes and one review —
        # the operator reading this comment could not tell an iterated task from
        # a polled one, and the plan's own option (c) called that out as worth
        # fixing on its own. basis= is what the cap compared; the two components
        # follow so the number is auditable from the comment alone.
        local basis_text
        basis_text="basis $ESCALATION_BASIS >= $MAX_ITERATIONS; verification iterations=$ITER, review rounds=${ROUNDS:-unavailable}"
        bd comments add "$tid" "QA-GATE ESCALATED at $ts ($basis_text).$options_text" >/dev/null 2>&1 \
            || bd comment add "$tid" "QA-GATE ESCALATED at $ts ($basis_text).$options_text" >/dev/null 2>&1 \
            || log_sync_error "mark_escalation: comment add failed for $tid"
        # The marker's CONTENT is the basis that triggered this escalation, and
        # its EXISTENCE is still the idempotency signal (the `[ ! -f ]` above is
        # unchanged). A later Stop reads it back so the banners can name the
        # number that actually caused the escalation instead of asserting a
        # false inequality about the current one — see escalation_basis_claim.
        printf '%s\n' "$ESCALATION_BASIS" > "$marker" 2>/dev/null || true
    fi
    QA_ESCALATED=true
}

# 2ty: whether THIS Stop's block reason should carry the J21 options. Three
# clauses, in precedence order:
#   1. already escalated — always show them. The reason text says "record a J21
#      choice", so withholding the commands would be incoherent, and it is how a
#      task recovers from an escalation that pre-dates this cycle.
#   2. suppressed (review in flight, nothing failing) — never show them. Offering
#      a J21 decision on a basis the gate itself declined to escalate on would
#      invite exactly the spurious `choose defer` this task exists to prevent,
#      and defer is the option that RELEASES.
#   3. otherwise the cap, measured on the basis rather than on ITER.
# Mirrors mark_escalation_if_capped's predicate on purpose: the label and the
# printed options must never disagree about whether the cap was reached.
j21_options_due() {
    [ "$QA_ESCALATED" = "true" ] && return 0
    if escalation_suppressed; then
        return 1
    fi
    [ "$ESCALATION_BASIS" -ge "$MAX_ITERATIONS" ]
}

# J19: iterative loop. If checks fail, surface tail + iteration count +
# escalation hint when MAX_ITERATIONS is reached.
if [ -n "$FAILED_CHECKS" ]; then
    # Spec 0.2: at cap-hit, transition to escalated state (idempotent).
    # We do this BEFORE composing REASON so the wording can branch on
    # the post-transition QA_ESCALATED.
    mark_escalation_if_capped "${CURRENT_TASK:-}"

    if [ "$QA_ESCALATED" = "true" ]; then
        # Spec 0.2 wording: "escalated — record a J21 choice before
        # iterating further." Lead with the escalation banner; include
        # the cached failure summary so the agent still sees why.
        # 2ty QA R1-F2: the parenthetical is COMPUTED, never asserted. It used to
        # read "iteration N of 3; cap reached" unconditionally, which this same
        # change made reachable-and-false (ITER freezes under escalation, ROUNDS
        # drops when the change set moves, and this banner keys on the label).
        REASON="Verification gate ESCALATED (iteration $ITER; $(escalation_basis_claim)) — record a J21 choice before iterating further."
        if [ "$SUITE_REUSED" = "true" ]; then
            REASON="$REASON

Cached failure summary (test suite NOT re-run this loop per the
escalation contract — see qa-gate.sh choose ...):

$FAILED_CHECKS"
        else
            REASON="$REASON

Last failure summary:

$FAILED_CHECKS"
        fi
    else
        REASON="Verification failed (iteration $ITER of $MAX_ITERATIONS).

$FAILED_CHECKS

Regression coverage note: this gate runs the FULL test suite + FULL
type-check on every iteration, not just tests for changed files. Changes
to module A might break module B's contract; only running A's tests
would miss B's failure."
    fi

    REASON="$REASON

Detected runner: $RUNNER"

    if [ -n "$TEST_FAIL_TAIL" ]; then
        REASON="$REASON

--- last 50 lines of test output ---
$TEST_FAIL_TAIL"
    fi
    if [ -n "$LINT_FAIL_TAIL" ]; then
        REASON="$REASON

--- last 50 lines of lint output ---
$LINT_FAIL_TAIL"
    fi
    if [ -n "$TYPE_FAIL_TAIL" ]; then
        REASON="$REASON

--- last 50 lines of type-check output ---
$TYPE_FAIL_TAIL"
    fi

    REASON="$REASON

The gate is idempotent: fix the issue, then this Stop hook re-evaluates
on the next attempt. The iteration counter resets on QA approval."

    # 2ty: name the basis the cap was measured on, so the iteration number is
    # never the only figure the reader gets.
    #
    # COMPOSED HERE, NOT EARLIER (QA R1-F1). The previous version built this
    # paragraph in the ESCALATION-BASIS region and carried a comment asserting
    # "on this path the suppression clause never applies (FAILED_CHECKS is
    # non-empty by construction)". The clause is indeed unreachable HERE — but
    # the STRING was not, because it had already been rendered forty lines before
    # FAILED_CHECKS existed. QA reproduced it at iteration 1 with a red suite and
    # again at the cap-hit. The comment was a claim nothing checked, inside the
    # fix for claims nothing checked; calling the composer at emission time is
    # what makes the scoping real rather than asserted.
    BASIS_NOTE=$(escalation_basis_note)
    if [ -n "$BASIS_NOTE" ]; then
        REASON="$REASON

$BASIS_NOTE"
    fi

    if j21_options_due; then
        REASON="$REASON
$(j21_options_block "${CURRENT_TASK:-<TASK_ID_NEEDED>}")"
    fi

    emit_block "$REASON"
fi

# All technical checks passed. Now check QA approval.
#
# llh.18 (red-team P0/P1): the release predicate is NO LONGER "the
# qa-approved label is present". The label is a forgeable token the gated
# process can mint (`bd label add` — P0) and says nothing about WHICH change
# set was reviewed (P1). Release now requires BOTH:
#   (1) GATE_STATUS == approved  (the qa-approved label — still necessary for
#       status precedence + idempotency), AND
#   (2) a tamper-evident `QA-GATE APPROVED change_set_hash=<h>` record on the
#       current task whose <h> matches the CURRENT change-set hash.
# Condition (2) is what qa-gate.sh approve writes and a bare label-add does
# not. It also re-arms the gate after any post-approval edit (the current
# hash drifts away from the recorded one).
QA_APPROVED=false
# Distinguishes "label present but no change-set-bound record matches" (the
# forged-label / decoy-redirect / post-approval-edit cases) from "no approval
# at all", so we can give a precise block reason for the former.
LABEL_WITHOUT_RECORD=false
APPROVAL_RECORD_DETAIL=""

# V3 (jio.1): review-discipline outcome. Declared OUTSIDE the sentinel block
# below (like APPROVAL_RECORD_DETAIL) with a RELEASING default, so the
# META-TEST's stripped copy stays coherent — with the check removed nothing
# ever sets these, the dedicated block below never fires, and the forged
# open-finding release succeeds. That is exactly what the META proves.
REVIEW_DISCIPLINE_BLOCKED=false
REVIEW_DISCIPLINE_DETAIL=""

if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
    if [ -n "$CURRENT_TASK" ] && [ -x "$QA_GATE" ]; then
        GATE_STATUS=$("$QA_GATE" status "$CURRENT_TASK" 2>/dev/null | jq -r '.status // "error"' 2>/dev/null || echo "error")
        if [ "$GATE_STATUS" = "approved" ]; then
            # The label is set. Now demand the change-set-bound record.
            #
            # `|| true` is LOAD-BEARING under `set -e` (line 25), not cosmetic:
            # current_change_set_hash() returns 1 when impact-report.sh is
            # MISSING (it `printf ''; return 1`s). A bare command-substitution
            # ASSIGNMENT whose RHS exits non-zero trips set -e and ABORTS the
            # whole script -> empty stdout + exit 1, which the hooks contract
            # treats as NON-blocking (only exit 2 / decision:block blocks) ->
            # the Stop would FAIL OPEN, releasing unreviewed code (re-opening
            # the very P0 this gate closes; QA block, bd note 355). With the
            # guard the assignment yields rc 0 + an empty hash, so the
            # missing-script case falls into the fail-CLOSED LABEL_WITHOUT_RECORD
            # branch below (its `[ -z "$CURRENT_CS_HASH" ]` arm). The
            # present-but-failing case already fails closed (the function body
            # ends `|| printf ''` -> rc 0); this makes the MISSING case match.
            # Regression: verify-before-stop.sh spec, "vbs-llh18-miss" cases.
            CURRENT_CS_HASH=$(current_change_set_hash) || true
            if [ -n "$CURRENT_CS_HASH" ] && task_has_matching_approval_record "$CURRENT_TASK" "$CURRENT_CS_HASH"; then
                QA_APPROVED=true

                # REVIEW-DISCIPLINE BEGIN (v4 V3 / claude-workflow-plugin-jio.1)
                #
                # The approval record matches the change-set — but an approval
                # is only as good as the review behind it. Before releasing we
                # re-run the SAME independent-review predicate `qa-gate.sh
                # approve` ran (review-check.sh gate: reviewer independence +
                # zero open findings at/above the artifact's risk_threshold).
                #
                # Why re-check at Stop rather than trusting the approval: the
                # record is written once, but findings keep arriving. A review
                # finding recorded AFTER the approval (a second review round, a
                # re-opened issue) must re-arm the gate — otherwise "approve
                # early, discover later" silently ships the finding. This is
                # the same re-arming logic the change-set-hash comparison
                # applies to files, applied to review state.
                #
                # AUDITED ESCAPE: a record carrying the literal
                # `[review bypass:` marker was approved with --no-review, whose
                # reason is already in the audit trail. The F1 doc-only fast
                # path is the intended producer (a doc-only change has no
                # implementer and no reviewer, so demanding an artifact would
                # deadlock every doc commit). Re-litigating that decision here
                # would just make the bypass useless.
                #
                # FAIL CLOSED: a missing/unrunnable predicate BLOCKS. The `||`
                # guards are load-bearing under `set -e` (line 25) for the same
                # reason the CURRENT_CS_HASH guard above is — a bare assignment
                # whose RHS exits non-zero aborts the script, which the hooks
                # contract reads as NON-blocking, i.e. fails OPEN. Every
                # non-zero outcome here must land in the block branch instead.
                #
                # The sentinel comments are load-bearing: an L2 META-TEST
                # strips this block and asserts a task with an OPEN finding
                # then releases. Do not rename them.
                MATCHED_APPROVAL_TEXT=$(matching_approval_record_text "$CURRENT_TASK" "$CURRENT_CS_HASH") || true
                if printf '%s' "$MATCHED_APPROVAL_TEXT" | grep -qF '[review bypass:'; then
                    log_sync_error "Stop release: review-discipline SKIPPED for $CURRENT_TASK — the matching approval record carries an audited [review bypass:] marker (F1/doc-only class)"
                elif [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
                    QA_APPROVED=false
                    REVIEW_DISCIPLINE_BLOCKED=true
                    REVIEW_DISCIPLINE_DETAIL="the review predicate is missing ($REVIEW_CHECK_SCRIPT), so independent review cannot be verified (error_key=review_check_unavailable)"
                    log_sync_error "Stop blocked: review-check.sh missing; review-discipline fails closed for $CURRENT_TASK"
                else
                    # 2ty: STORE ONCE, REUSE — but only where reuse is sound.
                    #
                    # The escalation basis above already read this predicate for
                    # THIS Stop (review_rounds_probe), so re-reading it is a
                    # second `bd show --include-comments` for the same answer.
                    # Reuse is taken when BOTH hold:
                    #   * SUITE_REUSED — the suite did NOT run this loop, so
                    #     nothing long-running happened between the two points
                    #     and the stored read is still this Stop's answer. When
                    #     the suite DID run, minutes may have passed and a
                    #     finding recorded meanwhile MUST re-arm the gate: this
                    #     is a RELEASE predicate, and the whole reason it runs at
                    #     Stop as well as at approve is that findings keep
                    #     arriving. Staleness here would silently ship one.
                    #   * a numeric ROUNDS came back — which proves the probe's
                    #     `--change-set-hash` form was ACCEPTED. A pre-2ty
                    #     review-check.sh on disk (partially-synced install)
                    #     rejects that flag with error_key=usage and rc 1;
                    #     consuming that envelope here would block a legitimate
                    #     release on an argument-parsing error. Falling through
                    #     to the classic call shape keeps such an install on
                    #     exactly today's behaviour.
                    if [ "$REVIEW_GATE_PROBED" = "true" ] && [ "$SUITE_REUSED" = "true" ] \
                        && [ -n "$ROUNDS" ]; then
                        log_sync_error "Stop: review-discipline reused this Stop's stored review-gate read for $CURRENT_TASK (suite was not re-run this loop, so nothing arrived in between) — rc=$REVIEW_GATE_RC (2ty)"
                    else
                        REVIEW_GATE_RC=0
                        REVIEW_GATE_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" gate "$CURRENT_TASK" 2>&1) || REVIEW_GATE_RC=$?
                    fi
                    if [ "$REVIEW_GATE_RC" -ne 0 ]; then
                        REVIEW_GATE_KEY=$(printf '%s' "$REVIEW_GATE_OUT" | jq -r '.error_key // ""' 2>/dev/null || echo "")
                        [ -z "$REVIEW_GATE_KEY" ] && REVIEW_GATE_KEY="review_check_unavailable"
                        REVIEW_GATE_OPEN=$(printf '%s' "$REVIEW_GATE_OUT" | jq -r '(.open_finding_ids // []) | join(", ")' 2>/dev/null || echo "")
                        QA_APPROVED=false
                        REVIEW_DISCIPLINE_BLOCKED=true
                        REVIEW_DISCIPLINE_DETAIL="review-check.sh gate exited $REVIEW_GATE_RC with error_key=$REVIEW_GATE_KEY"
                        if [ -n "$REVIEW_GATE_OPEN" ]; then
                            REVIEW_DISCIPLINE_DETAIL="$REVIEW_DISCIPLINE_DETAIL; open finding(s): $REVIEW_GATE_OPEN"
                        fi
                        log_sync_error "Stop blocked: review-discipline violation on $CURRENT_TASK ($REVIEW_DISCIPLINE_DETAIL)"
                    fi
                fi
                # REVIEW-DISCIPLINE END (v4 V3 / claude-workflow-plugin-jio.1)
            else
                # qa-approved present, but no matching record. This is the
                # forged bare label (no record at all), the decoy redirect
                # (record's hash != current change-set), or a post-approval
                # edit (current hash drifted). Block with a precise reason.
                LABEL_WITHOUT_RECORD=true
                if [ -z "$CURRENT_CS_HASH" ]; then
                    APPROVAL_RECORD_DETAIL="the current change-set hash could not be recomputed (impact-report.sh missing/failing), so a change-set-bound approval cannot be verified"
                else
                    APPROVAL_RECORD_DETAIL="current change-set hash is $CURRENT_CS_HASH but no QA-GATE APPROVED record on $CURRENT_TASK carries a matching change_set_hash"
                fi
                log_sync_error "Stop blocked: qa-approved label present on $CURRENT_TASK but no change-set-bound approval record matches ($APPROVAL_RECORD_DETAIL) — forged bare label, decoy-task redirect, or post-approval edit (llh.18)"
            fi
        fi
    fi
fi

# VANISHED-CHANGE-SET BEGIN (gz3 / v4.1 U1)
#
# A change set that has VANISHED cannot be unapproved.
#
# THE RACE THIS CLOSES. Observed live during the v4.1 upgrade wave (the block
# reason named the empty-set hash e3b0c44298fc… as "current"; occurrence recorded
# on claude-workflow-plugin-gz3) and then reproduced deterministically at a drive
# point rather than with sleeps — see the spec named at the end of this note.
# This hook reads the change set TWICE: once at the
# detection stage above, and again — minutes later, after the test/lint pass —
# when it recomputes the change-set hash to match against the approval record.
# `qa-gate.sh approve` runs in a different process (the QA subagent) and, as its
# final act, TRUNCATES changed-files.txt and refreshes the gate baseline. A Stop
# whose two reads straddle that finalization therefore recomputes the EMPTY-LIST
# hash — a hash no honest approval of real work can carry — and concludes
# "label present, nothing binds it", i.e. it prints the forged-label block for a
# legitimate approval that landed seconds earlier. No approve-side ordering can
# close this: the two reads belong to THIS process and straddle whatever approve
# does in between.
#
# THE FIX. Before blocking, re-derive the very predicate the detection stage
# used — reviewable_changes(), the same one function — from FRESH state. If
# there is no longer anything to review, release: that is precisely the decision
# the detection stage would have made had it run now (line ~740's
# "no changes -> allow"), and it is the decision the NEXT Stop fire makes
# anyway. The block was transient; this just stops charging the operator a
# confusing round trip for it.
#
# WHY THIS IS NOT A HOLE. It grants nothing the gate does not already grant:
# "nothing to review -> allow" is the detection stage's own rule, reached before
# any label is consulted. In particular it does NOT release when the tracker is
# empty but real un-baselined dirt exists (the class where files are written by
# a helper rather than the Edit tool — LESSONS.md/bi3.2), because the git-status
# half of reviewable_changes still reports those. Both halves must come up
# empty. Pinned as an anti-overreach assertion in
# .claude/tests/component/specs/approve-idempotency.sh.
#
# ORDER DEPENDENCY: approve refreshes the baseline BEFORE truncating the tracker
# (see the APPROVE-COMMIT ORDER note in qa-gate.sh), so an empty tracker always
# pairs with a refreshed baseline and this re-read cannot see a half-finalized
# state. Flipping those two lines re-opens the race.
#
# Placed BEFORE the cross-worktree resolution on purpose: this is cheaper (two
# file reads and one `git status`, no worktree scan) and more fundamental — if
# there is nothing to review, there is nothing to go looking for an approval OF.
#
# The sentinel comments are load-bearing: an L2 META-TEST strips this block and
# asserts the raced Stop blocks again. Do not rename them.
if [ "$LABEL_WITHOUT_RECORD" = "true" ]; then
    # Command substitution, so a non-zero rc inside cannot abort the hook under
    # `set -e` (an aborted hook emits nothing, which the hooks contract reads as
    # NON-blocking — i.e. it would fail OPEN).
    VANISHED_PROBE=$(reviewable_changes 2>/dev/null || true)
    if [ -z "$VANISHED_PROBE" ]; then
        log_sync_error "Stop released: the change set VANISHED between this hook's detection stage and its gate evaluation on $CURRENT_TASK (approve landed concurrently — it truncates changed-files.txt and refreshes the gate baseline), so the recomputed hash was the empty-set hash and no record could match it. Nothing is left to review; releasing instead of emitting a transient LABEL_WITHOUT_RECORD block (gz3)"
        echo "{}"
        exit 0
    fi
fi
# VANISHED-CHANGE-SET END (gz3 / v4.1 U1)

# WORKTREE-RESOLUTION BEGIN (v4 V4 / claude-workflow-plugin-3mg.2)
#
# WHY THIS EXISTS. The change-set hash is PER-CHECKOUT: it hashes the
# checkout's OWN changed-files list. The tri-model workflow runs implementers
# and reviewers in linked worktrees, so a review that happened in `wt-<task>`
# records a hash that the primary checkout can never reproduce — the same
# reviewed work reads as "qa-approved label present but no matching record"
# (the LABEL_WITHOUT_RECORD branch above) and the session deadlocks: nothing
# the operator does in the primary checkout can produce the approved hash.
# Reproduced live before this block existed (transcript scenario 2).
#
# WHAT IT DOES. Only on that already-blocking path, try to bind the approval to
# ANOTHER worktree of the SAME repo before giving up. Release requires all four
# of the following to hold for one candidate worktree W, each POSITIVELY proven:
#   1. W's persisted impact report for THIS task exists and its
#      `.change_set_hash` is one of the hashes a real QA-GATE APPROVED record
#      on this task carries (so W's report corresponds to an actual approval);
#   2. W has no post-approval drift: W's own `git status --porcelain` minus W's
#      own gate-baseline is empty (approve refreshes that baseline, so any edit
#      in W after the approval shows up here);
#   3. every reviewable path in THIS checkout's change set is inside the file
#      set that report approved, compared REPO-RELATIVE (PR#2 technique: two
#      worktrees of one repo share a git common-dir, so the same repo-relative
#      key identifies the same file in both);
#   4. W really is a worktree of this repo (`--git-common-dir` identity, not a
#      toplevel string compare — 3mg.1/I8).
#
# RECORD-BASED, NOT RECOMPUTED — the constraint that shapes everything here:
# `qa-gate.sh approve` TRUNCATES changed-files.txt in the approving checkout,
# so re-running `impact-report.sh --hash-only` in W yields the EMPTY-LIST hash
# and can never reproduce the approved hash. The persisted
# `impact-report-<tid>.json` survives approve and carries both the approved
# hash and the approved file list; that file is the evidence. (Verified live:
# post-approve recompute in W returned the sha256 of the empty string.)
#
# READ-ONLY: file reads, `git worktree list`, `git rev-parse`, `git status`, jq.
# It writes NOTHING anywhere — in particular nothing in the candidate worktree
# — and NEVER boots the code-graph MCP server (no impact-report.sh invocation
# at all on this path).
#
# FAIL CLOSED: every failure, ambiguity or unreadable artifact `continue`s or
# returns 1, which falls through to the block below. A resolution must be
# proven; it is never assumed. The helpers are called from an `if` CONDITION,
# which suspends `set -e` inside them, so a non-zero rc from any probe cannot
# abort the hook mid-flight (an aborted hook emits nothing, and the hooks
# contract reads "no output" as NON-blocking — i.e. it would fail OPEN).
#
# THREAT-MODEL BOUNDARY (documented, not overclaimed — same boundary llh.18
# names for the approval record itself). The evidence here is an on-disk file in
# a sibling worktree, so an agent with arbitrary shell could hand-write an
# `impact-report-<tid>.json` citing a hash from a REAL earlier approval, list
# whatever files it wants approved, and drop a matching gate-baseline. That is
# the SAME adversary who can already forge the approval comment
# (`bd comment add "QA-GATE APPROVED change_set_hash=$(impact-report.sh
# --hash-only)"`) — this block does not lower that bar, and it does not raise it
# either. What it defends against is the accidental and structural case this
# release exists for: real work, really reviewed, in the wrong checkout. Sealing
# the forgery case needs a record signed with a secret the gated process cannot
# read, which the full-shell autonomy model precludes.
#
# The sentinel comments are load-bearing: an L2 META-TEST strips this whole
# block and asserts the cross-worktree release then BLOCKS. Do not rename them.

# Bounded search: at most this many candidate worktrees are probed.
WTRES_MAX_CANDIDATES=16
# Set by try_worktree_resolution for the log line / block reason.
WTRES_WORKTREE=""
WTRES_HASH=""
WTRES_CHECKED=0
WTRES_DELETED_TOKEN=""
# Non-empty when a resolvable approval was refused on REVIEW state (below).
WTRES_REVIEW_DETAIL=""

# wtres_decode <token> — the `worktree=` token's path spelling. Mirror of
# qa-gate.sh approval_worktree_token: %20/%09 first, then %25 back to `%`, so a
# path that genuinely contains "%20" round-trips instead of decoding to a space.
wtres_decode() {
    local t="$1"
    t="${t//%20/ }"
    t="${t//%09/	}"
    t="${t//%25/%}"
    printf '%s' "$t"
}

# Per-directory memo for wtres_repo_relative (bash 3.2: no associative arrays).
_WTRES_MEMO_DIR=""
_WTRES_MEMO_COMMON=""
_WTRES_MEMO_PREFIX=""

# wtres_repo_relative <path> <want-common-dir> — print <path>'s REPO-RELATIVE
# key, i.e. the spelling that identifies the same file in every worktree of the
# repo whose canonical common-dir is <want-common-dir>. rc 1 + no output when
# the path cannot be proven to belong to that repo (caller must fail closed).
#
# Three input spellings occur in practice:
#   - absolute, under this checkout       (post-edit records tool_input verbatim)
#   - absolute, under a SIBLING worktree  (the parent session's hooks record the
#                                          specialist's worktree path)
#   - already repo-relative               (the git-status fallback's `${line#???}`)
# git supplies the mapping (`--show-prefix` + basename) so nothing depends on
# how a path happened to be spelled (/var vs /private/var on macOS, symlinked
# project roots, trailing slashes).
wtres_repo_relative() {
    local p="$1" want="$2" d b
    [ -n "$p" ] || return 1
    [ -n "$want" ] || return 1
    case "$p" in
        /*) ;;
        *) printf '%s' "$p"; return 0 ;;
    esac
    d=$(dirname "$p") || return 1
    b=$(basename "$p") || return 1
    if [ "$d" != "$_WTRES_MEMO_DIR" ]; then
        _WTRES_MEMO_DIR="$d"
        _WTRES_MEMO_COMMON=$(repo_identity "$d")
        _WTRES_MEMO_PREFIX=$(git -C "$d" rev-parse --show-prefix 2>/dev/null) || _WTRES_MEMO_PREFIX=""
    fi
    [ -n "$_WTRES_MEMO_COMMON" ] || return 1
    [ "$_WTRES_MEMO_COMMON" = "$want" ] || return 1
    printf '%s%s' "$_WTRES_MEMO_PREFIX" "$b"
}

# wtres_no_drift_in <worktree> — 0 when <worktree> has NOTHING dirty beyond its
# own gate-baseline, i.e. nothing changed there after the approval refreshed it.
# A missing baseline returns 1: absence of evidence is not evidence of absence.
wtres_no_drift_in() {
    local w="$1" raw wstatus wbase leftover cmp_rc=0
    local v2="$w/.claude/.qa-tracking/gate-baseline"
    local legacy="$w/.claude/.qa-tracking/approved-baseline"
    # `git status` is captured on its OWN, not piped straight into sort: a
    # pipeline's rc is the LAST command's, so `git ... | sort` would report
    # success for a failed git and hand us an empty status — which reads as
    # "nothing dirty", i.e. it would fail OPEN on exactly the error case.
    raw=$(git -C "$w" status --porcelain 2>/dev/null) || return 1
    wstatus=$(printf '%s' "$raw" | LC_ALL=C sort) || return 1
    if [ -f "$v2" ]; then
        wbase=$(awk 'body { print; next } /^--$/ { body = 1 }' "$v2" 2>/dev/null | LC_ALL=C sort) || return 1
    elif [ -f "$legacy" ]; then
        wbase=$(LC_ALL=C sort "$legacy" 2>/dev/null) || return 1
    else
        return 1
    fi
    # Same collation on both sides as the writer used (see gate_baseline_entries).
    # comm's own failure must REFUSE, not read as an empty difference — same
    # fail-open trap as the pipeline above.
    leftover=$(comm -23 <(printf '%s\n' "$wstatus") <(printf '%s\n' "$wbase") 2>/dev/null) || cmp_rc=$?
    [ "$cmp_rc" -eq 0 ] || return 1
    leftover=$(printf '%s' "$leftover" | grep -v '^$') || leftover=""
    [ -z "$leftover" ]
}

# wtres_delta_is_subset <report-json> <want-common-dir> — 0 when EVERY path in
# this checkout's reviewable change set is in the file set that report approved.
# Empty on either side returns 1: a vacuous subset proves nothing.
wtres_delta_is_subset() {
    local j="$1" want="$2"
    local approved="" f key n=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # An approved path we cannot map is DROPPED, which shrinks the approved
        # set — the fail-closed direction.
        key=$(wtres_repo_relative "$f" "$want") || continue
        approved="$approved$key
"
    done < <(jq -r '(.files // [])[] | .file // empty' "$j" 2>/dev/null)
    [ -n "$approved" ] || return 1
    for f in ${ALL_CHANGED_FILES[@]+"${ALL_CHANGED_FILES[@]}"}; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        # A current path we cannot map is UNPROVABLE -> refuse outright.
        key=$(wtres_repo_relative "$f" "$want") || return 1
        printf '%s' "$approved" | grep -qxF "$key" || return 1
    done
    [ "$n" -gt 0 ]
}

# try_worktree_resolution — 0 (and WTRES_WORKTREE/WTRES_HASH set) when the
# approval on $CURRENT_TASK is proven to be bound to another worktree of this
# repo whose approved file set covers this checkout's change set.
try_worktree_resolution() {
    WTRES_WORKTREE=""; WTRES_HASH=""; WTRES_CHECKED=0; WTRES_DELETED_TOKEN=""

    [ -n "$CURRENT_TASK" ] || return 1
    # This bridge exists for a hash MISMATCH, never for a hash we could not
    # compute: an empty CURRENT_CS_HASH means the local machinery is broken
    # (impact-report.sh missing/failing), and a gate that cannot measure its own
    # checkout must not go looking for permission elsewhere.
    [ -n "${CURRENT_CS_HASH:-}" ] || return 1
    command -v git >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    command -v bd >/dev/null 2>&1 || return 1
    [ -d "$PROJECT_DIR/.beads" ] || return 1

    local current_id current_top
    current_id=$(repo_identity "$PROJECT_DIR")
    [ -n "$current_id" ] || return 1
    current_top=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || return 1
    current_top=$(cd "$current_top" 2>/dev/null && pwd -P) || return 1
    [ -n "$current_top" ] || return 1

    # The approval records. `gsub("\n"; " ")` flattens a multi-line summary so
    # the token scans below stay line-oriented.
    local approvals
    approvals=$(bd_show_with_comments "$CURRENT_TASK" \
        | jq -r '
            (if type == "array" then .[0].comments else .comments end) // []
            | .[].text
            | select(test("QA-GATE APPROVED .*change_set_hash="))
            | gsub("\n"; " ")
        ' 2>/dev/null) || approvals=""
    [ -n "$approvals" ] || return 1

    # First match per record, matching the readers' `capture(...)` semantics.
    local recorded_hashes recorded_token
    recorded_hashes=$(printf '%s\n' "$approvals" \
        | awk '{ if (match($0, /change_set_hash=[A-Za-z0-9-]+/)) print substr($0, RSTART + 16, RLENGTH - 16) }') \
        || recorded_hashes=""
    [ -n "$recorded_hashes" ] || return 1
    # The LATEST record that carries a token (bd returns comments in order).
    # Records written before 3mg.2 carry none, which just costs us the O(1)
    # short-cut — the bounded scan below still finds the worktree.
    recorded_token=$(printf '%s\n' "$approvals" \
        | awk '{ if (match($0, /worktree=[^ ]+/)) print substr($0, RSTART + 9, RLENGTH - 9) }' \
        | tail -1) || recorded_token=""

    local decoded="" decoded_canon=""
    if [ -n "$recorded_token" ] && [ "$recorded_token" != "none" ]; then
        decoded=$(wtres_decode "$recorded_token")
        decoded_canon=$(cd "$decoded" 2>/dev/null && pwd -P) || decoded_canon=""
    fi

    # Live worktrees of this repo, minus the current checkout.
    local wt_list c canon
    wt_list=$(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null) || return 1
    [ -n "$wt_list" ] || return 1
    local cands=()
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        canon=$(cd "$c" 2>/dev/null && pwd -P) || canon=""
        [ -n "$canon" ] || continue                 # pruned / vanished entry
        [ "$canon" = "$current_top" ] && continue   # never resolve against ourselves
        cands+=("$canon")
    done < <(printf '%s\n' "$wt_list" | sed -n 's/^worktree //p')

    # Record-first ordering: the recorded worktree is tried before the scan, so
    # the common case costs one candidate.
    local recorded_live=0
    if [ -n "$decoded_canon" ]; then
        for c in ${cands[@]+"${cands[@]}"}; do
            if [ "$c" = "$decoded_canon" ]; then recorded_live=1; fi
        done
    fi
    local ordered=()
    if [ "$recorded_live" = "1" ]; then
        ordered+=("$decoded_canon")
    fi
    for c in ${cands[@]+"${cands[@]}"}; do
        if [ "$recorded_live" = "1" ] && [ "$c" = "$decoded_canon" ]; then
            continue
        fi
        ordered+=("$c")
    done

    # A recorded token that names neither a live worktree nor THIS checkout is
    # gone — removed, moved, or never a worktree of this repo. Naming it in the
    # block reason is the difference between an actionable message and a dead
    # end. (The token pointing at this very checkout is the ordinary
    # post-approval-edit case, which the existing reason already explains.)
    if [ -n "$decoded" ] && [ "$recorded_live" != "1" ] \
        && [ "$decoded_canon" != "$current_top" ]; then
        WTRES_DELETED_TOKEN="$decoded"
    fi

    local w j wh
    for w in ${ordered[@]+"${ordered[@]}"}; do
        [ "$WTRES_CHECKED" -ge "$WTRES_MAX_CANDIDATES" ] && break
        WTRES_CHECKED=$((WTRES_CHECKED + 1))
        # 4. Same repo (a `worktree list` entry always is; a foreign or
        #    unreadable entry must not slip through). 3mg.1 identity, never a
        #    --show-toplevel string compare.
        [ "$(repo_identity "$w")" = "$current_id" ] || continue
        # 1. W's persisted approval evidence, which survives approve.
        j="$w/.claude/.qa-tracking/impact-report-$(sanitize_task_id "$CURRENT_TASK").json"
        [ -f "$j" ] || continue
        wh=$(jq -r '.change_set_hash // empty' "$j" 2>/dev/null) || continue
        [ -n "$wh" ] || continue
        printf '%s\n' "$recorded_hashes" | grep -qxF "$wh" || continue
        # 2. No post-approval drift in W.
        wtres_no_drift_in "$w" || continue
        # 3. This checkout's delta is covered by what W approved.
        wtres_delta_is_subset "$j" "$current_id" || continue
        WTRES_WORKTREE="$w"
        WTRES_HASH="$wh"
        return 0
    done
    return 1
}

# wtres_review_is_clean — the V3 review-discipline predicate, applied to the
# RESOLVED record. Same predicate, same audited `[review bypass:` escape, same
# fail-closed stance as the same-checkout release path above.
#
# WHY IT IS HERE (a deliberate strengthening, not in the pt2 spec's algorithm):
# without it, the cross-worktree release would be the ONE release path that does
# not re-check review state, and a finding recorded AFTER the approval would
# stop re-arming the gate — reopening the exact "approve early, discover later"
# hole V3 closed, in precisely the worktree flow V4 exists to support. It can
# only ever REFUSE a release, never grant one, so it cannot widen the gate.
wtres_review_is_clean() {
    WTRES_REVIEW_DETAIL=""
    local text rc=0 out key open
    text=$(matching_approval_record_text "$CURRENT_TASK" "$WTRES_HASH") || text=""
    if printf '%s' "$text" | grep -qF '[review bypass:'; then
        return 0    # audited escape (F1 / --no-review), honoured as upstream
    fi
    if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
        WTRES_REVIEW_DETAIL="the review predicate is missing ($REVIEW_CHECK_SCRIPT), so independent review cannot be verified (error_key=review_check_unavailable)"
        return 1
    fi
    out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" gate "$CURRENT_TASK" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && return 0
    key=$(printf '%s' "$out" | jq -r '.error_key // ""' 2>/dev/null) || key=""
    [ -n "$key" ] || key="review_check_unavailable"
    open=$(printf '%s' "$out" | jq -r '(.open_finding_ids // []) | join(", ")' 2>/dev/null) || open=""
    WTRES_REVIEW_DETAIL="review-check.sh gate exited $rc with error_key=$key"
    [ -n "$open" ] && WTRES_REVIEW_DETAIL="$WTRES_REVIEW_DETAIL; open finding(s): $open"
    return 1
}

if [ "$LABEL_WITHOUT_RECORD" = "true" ]; then
    if try_worktree_resolution; then
        if wtres_review_is_clean; then
            log_sync_error "Stop released via worktree resolution: the approval on $CURRENT_TASK is bound in $WTRES_WORKTREE (change_set_hash=$WTRES_HASH); that worktree has no post-approval drift and this checkout's change set is inside its approved file set (3mg.2)"
            echo "{}"
            exit 0
        fi
        log_sync_error "Stop blocked: worktree resolution matched $WTRES_WORKTREE for $CURRENT_TASK but the independent review is not clean ($WTRES_REVIEW_DETAIL) — refusing to release (3mg.2)"
    fi
    if [ -n "$WTRES_REVIEW_DETAIL" ]; then
        APPROVAL_RECORD_DETAIL="$APPROVAL_RECORD_DETAIL; an approval bound in worktree $WTRES_WORKTREE DOES cover this change set, but its independent review is not clean ($WTRES_REVIEW_DETAIL) — resolve-finding or arbitrate, then re-run"
    elif [ -n "$WTRES_DELETED_TOKEN" ]; then
        APPROVAL_RECORD_DETAIL="$APPROVAL_RECORD_DETAIL; the approval was bound in worktree $WTRES_DELETED_TOKEN, which no longer exists as a live worktree of this repo (removed or moved) — re-enter + re-review here"
    else
        APPROVAL_RECORD_DETAIL="$APPROVAL_RECORD_DETAIL (checked $WTRES_CHECKED worktree(s))"
    fi
fi
# WORKTREE-RESOLUTION END (v4 V4 / claude-workflow-plugin-3mg.2)

# llh.18: the label-without-record block. Emitted BEFORE the generic
# QA-required messaging so the reason names the exact failure mode and the
# correct remediation (approve via qa-gate.sh, not a bare label add). This is
# the load-bearing assertion the META-TEST strips to prove the check matters.
#
# gz3 (v4.1 U1): the printed remediation below is now COMPLETE, and that is a
# behavioural claim, not a wording one. It used to print `enter ->
# impact-report -> approve` while `approve` short-circuited on the mere presence
# of qa-approved — so following it exactly wrote no new record and this block
# fired again, unchanged, forever. The recipe worked only with an undocumented
# `bd label remove <tid> qa-approved` first. approve's idempotency guard is now
# hash-aware (it no-ops only when a record already binds the current change set),
# which is what makes these three lines a real recovery. Regression:
# .claude/tests/component/specs/approve-idempotency.sh drives the commands
# EXTRACTED FROM THIS TEXT, and denylist-shared.sh section C4 does the same after
# a denylist hash migration — so editing the recipe here without editing the
# behaviour fails a test.
if [ "$LABEL_WITHOUT_RECORD" = "true" ]; then
    emit_block "qa-approved label present but no change-set-bound approval record matches the current changes — approve via qa-gate.sh approve, not a bare label add.

Why this blocks ($APPROVAL_RECORD_DETAIL):
  - A bare \`bd label add $CURRENT_TASK qa-approved\` sets the label but writes
    NO change-set-bound record, so it cannot release (red-team P0).
  - Approving a decoy task and redirecting current-task records the DECOY's
    change-set hash, which will not match what is actually shipping (P1).
  - Editing a tracked file AFTER approval shifts the current change-set hash
    away from the approved one — the change must be re-reviewed.
  - A denylist change re-hashes the whole change set, so an approval recorded
    before it no longer matches (one migration per landing; see docs/HOOKS.md).

The release path requires a tamper-evident record that qa-gate.sh approve
writes (a \`QA-GATE APPROVED change_set_hash=<h>\` comment) AND a matching
current change-set. Re-run the gate properly:

  bash .claude/scripts/qa-gate.sh enter $CURRENT_TASK
  # regenerate the impact report so approve's freshness check passes:
  bash .claude/scripts/impact-report.sh $CURRENT_TASK
  bash .claude/scripts/qa-gate.sh approve $CURRENT_TASK '<approval summary>'

That is the WHOLE recipe: do NOT remove the qa-approved label first. Since
v4.1 approve's idempotency is hash-aware — with the label already set but no
record binding the current change set, it re-verifies every precondition
(impact-report freshness, independent review, rubric state) and writes a FRESH
bound record rather than reporting an idempotent no-op. Re-review the change set
before you run it; nothing here waives that.

Note: this binds approval to the reviewed files and defeats a forged or stale
label, but is not a cryptographic sandbox against an adversary with arbitrary
shell who reproduces the record by hand (documented residual, llh.18)."
fi

# V3 (jio.1): the review-discipline block. Emitted BEFORE the generic
# QA-required messaging so the reason names the review state (which finding is
# open, or which predicate failed) rather than the generic "QA approval
# required" — the change IS approved; what is missing is a clean independent
# review. The flags default to the releasing values and are only set inside
# the sentinel-wrapped check above, so stripping that check makes this branch
# unreachable (which is what the META-TEST proves).
if [ "$REVIEW_DISCIPLINE_BLOCKED" = "true" ]; then
    emit_block "Approved change-set, but the INDEPENDENT REVIEW is not clean — release refused.

Nobody signs off on their own work, and no approval releases while a review
finding at or above the artifact's risk_threshold is still open. The check
runs at Stop as well as at approve because a finding can be
recorded AFTER an approval (a second review round, a re-opened issue), and the
approval record — written once — cannot know about it. So the gate re-arms.

Why this blocks:
  $REVIEW_DISCIPLINE_DETAIL

Run the predicate directly for the full envelope:
  bash .claude/scripts/review-check.sh gate $CURRENT_TASK

Then clear it, by error_key:
  review_artifact_missing    an independent reviewer (identity != every
                             recorded IMPLEMENTER role) must review the change
                             set and record the artifact:
                               bash .claude/scripts/qa-gate.sh review-record $CURRENT_TASK --file <artifact.json>
  reviewer_not_independent   the recorded reviewer also implemented this task;
                             a different identity must review it.
  unresolved_findings        close each open finding with evidence:
                               bash .claude/scripts/qa-gate.sh resolve-finding $CURRENT_TASK <finding-id> --fix '<ref>' --test '<ref>' '<summary>'
                             or record an explicit, justified overrule:
                               bash .claude/scripts/qa-gate.sh arbitrate $CURRENT_TASK <finding-id> overrule '<rationale>'
  review_check_unavailable   the predicate itself could not run. This fails
                             CLOSED on purpose — restore
                             .claude/scripts/review-check.sh.

Once the review is clean, re-approve so the record carries the reviewer:
  bash .claude/scripts/qa-gate.sh approve $CURRENT_TASK '<approval summary>'

The audited escape is \`approve --no-review '<reason>'\`, which stamps
\`[review bypass: <reason>]\` on the approval record and skips this check. Use
it only when there is genuinely nothing to review (the doc-only fast path uses
it automatically); the reason is permanent in the audit trail."
fi

if [ "$QA_APPROVED" = false ]; then
    # Spec 0.2: at cap-hit, transition to escalated state (idempotent).
    # The QA-required path is the more common cap-hit case (clean tech
    # checks waiting on QA), so escalation must fire here too — without
    # this, an iteration-7 transcript like the bug report shows the
    # J21 options block but no qa-escalated label.
    mark_escalation_if_capped "${CURRENT_TASK:-}"

    # J18: surface intent-routing payload (LLM, not regex, decides scope).
    # Defensive `|| INTENT_JSON='{}'` for the same set -e fail-open class as
    # the CURRENT_CS_HASH guard above: compute_intent_payload ends in a bare
    # `jq -nc ...` whose non-zero exit (however unlikely with literal args)
    # would otherwise abort this QA-required BLOCK mid-emission under set -e
    # -> empty stdout -> fail open. The fallback keeps the block firing with a
    # valid (if empty) payload rather than aborting. This path is only reached
    # when NOT approved, so the conservative outcome is "still block".
    INTENT_JSON=$(compute_intent_payload) || INTENT_JSON='{}'

    # Get changed files for display.
    CHANGED_FILES=""
    CHANGE_COUNT=0
    if [ -f "$TRACKING_FILE" ]; then
        FILTERED=$(sort -u "$TRACKING_FILE" 2>/dev/null | while IFS= read -r f; do
            if is_tracked_change "$f"; then
                printf '%s\n' "$f"
            fi
        done || true)
        CHANGE_COUNT=$(printf '%s\n' "$FILTERED" | grep -c . || true)
        CHANGE_COUNT="${CHANGE_COUNT:-0}"
        if [ "$CHANGE_COUNT" -gt 15 ]; then
            CHANGED_FILES=$(printf '%s\n' "$FILTERED" | head -15)
            CHANGED_FILES="$CHANGED_FILES
...and $((CHANGE_COUNT - 15)) more files"
        else
            CHANGED_FILES="$FILTERED"
        fi
    else
        CHANGED_FILES="(check git status)"
        CHANGE_COUNT="?"
    fi

    if [ -n "$CURRENT_TASK" ]; then
        TASK_ID="$CURRENT_TASK"
        NO_TASK_NOTE=""
    else
        TASK_ID="<TASK_ID_NEEDED>"
        NO_TASK_NOTE="

No active Beads task detected. Create one (and write its id via
\`.claude/scripts/current-task.sh set <id>\`) before re-running, e.g.:
  bd create '...' -t task -p 1 -l <domain>,qa-pending
  bash .claude/scripts/qa-gate.sh enter <id>
"
    fi

    # J18: include the intent payload as a JSON block. The orchestrator/QA
    # agent reads this to decide which review pass to invoke (security,
    # perf, a11y, etc.) — driven by reading the diff, NOT regex.
    # Spec 0.2: when escalated, lead with the escalation wording (the cap
    # is what we're enforcing; the suite-reuse note disambiguates from
    # the FAILED_CHECKS path which DOES surface a failure summary).
    #
    # 2ty: THE SUITE CLAUSE IS NOW BRANCHED ON SUITE_REUSED, because the flat
    # version was FALSE on the cap-hit Stop and the falsehood cost real evidence.
    # mark_escalation_if_capped runs a few lines above and sets QA_ESCALATED
    # WITHIN this same Stop, so the very Stop that reaches the cap took this
    # branch while SUITE_REUSED was false — it had just run the full suite — and
    # announced "Test suite NOT re-run this loop per the escalation contract".
    # That sentence was then read back (twice, on two different tasks) as
    # first-hand evidence that the counter had charged for a Stop that ran
    # nothing. The defect was real; this particular readout was not evidence of
    # it. A gate that reports confidently on its own behaviour must be right
    # about it, so the two cases now say what actually happened. The FAILED_CHECKS
    # path above has always branched this way; this path simply did not.
    if [ "$QA_ESCALATED" = "true" ]; then
        if [ "$SUITE_REUSED" = "true" ]; then
            ESC_SUITE_CLAUSE="Test suite NOT re-run this loop per the escalation contract (runner=$RUNNER, technical checks previously passed)."
        else
            ESC_SUITE_CLAUSE="Technical checks RAN and passed this loop (runner=$RUNNER); the escalation contract skips them only on later loops."
        fi
        REASON="QA approval required — gate ESCALATED (iteration $ITER; $(escalation_basis_claim)) — record a J21 choice before iterating further. $ESC_SUITE_CLAUSE

$CHANGE_COUNT file(s) changed - all require QA review.$NO_TASK_NOTE"
    else
        REASON="QA approval required (iteration $ITER, runner=$RUNNER, technical checks passed).

$CHANGE_COUNT file(s) changed - all require QA review.$NO_TASK_NOTE"
    fi

    # 2ty: the basis readout. This is the path all three measured instances took
    # ("technical checks passed", waiting on review), so it is the one where the
    # operator most needs to see WHY the cap did or did not fire — and, when the
    # escalation is suppressed, why the J21 options are absent. Composed here so
    # the suppression clause is decided against the suite result and the live
    # escalation state, both of which are only known at this point (QA R1-F1).
    BASIS_NOTE=$(escalation_basis_note)
    if [ -n "$BASIS_NOTE" ]; then
        REASON="$REASON

$BASIS_NOTE"
    fi
    # qzv: when the F1 fast path was ELIGIBLE but declined, say so here. The
    # append is deliberately OUTSIDE the F1-CHANGE-SET-BINDING regions: with those
    # stripped, F1_BINDING_NOTE is never assigned, stays empty, and this is a
    # no-op — so the stripped copy keeps emitting the pre-qzv reason verbatim.
    if [ -n "$F1_BINDING_NOTE" ]; then
        REASON="$REASON

$F1_BINDING_NOTE"
    fi

    REASON="$REASON

Files changed:
$CHANGED_FILES

Intent-routing payload (J18) — orchestrator/QA reads this to pick the
review pass; the \`recommended_focus\` field is for the LLM to fill in,
NOT for a regex over filenames:

\`\`\`json
$INTENT_JSON
\`\`\`

Required: delegate to @qa now.

Task(\"@qa\", \"Mandatory review before delivery:

Files to review:
$CHANGED_FILES

Read the intent payload above and decide which review modules to run
(security/perf/a11y/etc.) based on what the diff means, not which words
appear in filenames.

Checklist:
- FIRST: read the mechanical impact report at
  .claude/.qa-tracking/impact-report-$TASK_ID.json — qa-gate.sh enter
  already ran impact_of (code-graph MCP) over every changed file and
  persisted the results there, and qa-gate.sh approve REFUSES when that
  artifact is missing or stale (regenerate:
  bash .claude/scripts/impact-report.sh $TASK_ID). Fold the high-fan-in
  callers it surfaces into the regression assessment; make follow-up
  impact_of calls (mcp__plugin_claude-workflow_code-graph) only for
  symbol-level questions the per-file report leaves open. A report with
  server: absent means the code-graph server was unavailable — note that
  degradation in llm_observations and fall back to grep/code_search for
  the impact pass.
- Tests cover user behavior (not implementation)
- Critical user journeys tested
- Failure modes handled
- All tests pass (already verified by gate)

When entering review, mark the gate:
  bash .claude/scripts/qa-gate.sh enter $TASK_ID

If approved (atomic — sets qa-approved, drops qa-pending and qa-gate-entered):
  bash .claude/scripts/qa-gate.sh approve $TASK_ID '<approval summary>'

If not approved:
  bash .claude/scripts/qa-gate.sh block $TASK_ID '<reason>'\")

Cannot complete without QA approval."

    # MATERIAL 6 fix: J21 decision-gate options must surface on the
    # QA-required path too, not just the FAILED_CHECKS path. This is the
    # MORE common case (clean tech-checks waiting on QA), so without it
    # users hit iter>=3 with no escalation guidance.
    # 2ty: gated on the same predicate the label transition uses, so the printed
    # options and the qa-escalated label can never disagree about the cap.
    if j21_options_due; then
        REASON="$REASON
$(j21_options_block "$TASK_ID")"
    fi

    emit_block "$REASON"
fi

# QA approved - check epic-level e2e gate (B2) before allowing the stop.
EPIC_DEFER_NOTE=""
if [ -n "$CURRENT_TASK" ] && [ -x "$EPIC_GATE" ] && command -v bd >/dev/null 2>&1; then
    SIBLINGS_JSON=$("$EPIC_GATE" siblings "$CURRENT_TASK" 2>/dev/null || echo '{}')
    EPIC_ID=$(echo "$SIBLINGS_JSON" | jq -r '.epic_id // empty' 2>/dev/null || echo "")
    SHARED_JSON=$("$EPIC_GATE" shared-files "$CURRENT_TASK" 2>/dev/null || echo '{}')
    SHARED_COUNT=$(echo "$SHARED_JSON" | jq '.intersections | length // 0' 2>/dev/null || echo "0")

    if [ -n "$EPIC_ID" ]; then
        EPIC_CHECK=$("$EPIC_GATE" check "$EPIC_ID" 2>/dev/null || echo '{}')
        EPIC_DEC=$(echo "$EPIC_CHECK" | jq -r '.decision // "pass"' 2>/dev/null || echo "pass")
        EPIC_REASON=$(echo "$EPIC_CHECK" | jq -r '.observations // ""' 2>/dev/null || echo "")

        case "$EPIC_DEC" in
            block)
                # Sibling is qa-blocked — the active task can still complete,
                # but we surface this prominently so the orchestrator
                # doesn't accidentally close the epic.
                EPIC_DEFER_NOTE="

Epic gate (B2): $EPIC_REASON
The active task can complete; the parent epic ($EPIC_ID) cannot close until
the blocked sibling clears."
                ;;
            defer)
                EPIC_DEFER_NOTE="

Epic gate (B2): $EPIC_REASON
The active task can complete; the parent epic ($EPIC_ID) stays open."
                ;;
            pass)
                EPIC_DEFER_NOTE="

Epic gate (B2): all sub-tasks under $EPIC_ID qa-approved; the epic can close."
                ;;
        esac

        if [ "${SHARED_COUNT:-0}" -gt 0 ]; then
            EPIC_DEFER_NOTE="$EPIC_DEFER_NOTE

Shared-files notice: this task overlaps with $SHARED_COUNT in-progress
sibling(s). An integration check is recommended before the epic closes.
Run \`bash .claude/scripts/epic-gate.sh shared-files $CURRENT_TASK\`
for the file list."
        fi
    fi
fi

# THE TASK IS NOT CLOSED HERE EITHER (qzv). This used to run
# `bd update <tid> --status closed`, and removing it is a judgement call, so the
# reasoning is recorded rather than implied.
#
# THE ARGUMENT FOR KEEPING IT was real: reaching this line means a genuine
# approval, a clean independent review, and a record bound to the current change
# set — the strongest evidence this workflow produces. The argument that wins is
# that none of that evidence is about the TASK. An approval binds a CHANGE SET;
# a task can legitimately carry more work after one reviewed change set, and this
# repo's own history is the demonstration — `claude-workflow-plugin-94d` was
# closed BY HAND after its approval precisely because the approval covered one
# landing and the task covered two. Nothing in a change set can tell you whether
# a task's acceptance criteria are met, so the close was structurally a guess,
# and it silently overrode whatever the caller intended (the v4.1.0 release
# implementer discovered the F1 twin of this only because `bd_update_task` echoed
# back `status=closed` when it had passed no such thing).
#
# WHAT DEPENDED ON IT, checked rather than assumed:
#   - No L1, L2 or L3 assertion required the task to reach `closed`. The one
#     nearby L2 assertion — the llh.20 "stdout is a single valid JSON envelope"
#     case — existed BECAUSE this call printed a `✓ Updated issue` banner onto
#     stdout, so removing the call removes that pollution source; the assertion
#     is kept and retargeted at the note below, which is now what that path
#     emits.
#   - `bd-github-link.sh` recognises `bd update <tid> --status closed`, but it is
#     a PostToolUse hook keyed on `tool_name == "Bash"`. This call was never a
#     Bash TOOL invocation (it ran inside the hook process), so it never reached
#     that pipeline and no GitHub linking is lost.
#   - `epic-gate.sh check` reads sub-task STATUS and defers an epic while any
#     sibling is `in_progress`. Its verdict is computed ABOVE this line, so on
#     the last child's own Stop the child already counted as in_progress and the
#     epic already deferred; the "epic can close" readout only ever appeared on a
#     LATER Stop. That is now reached when something closes the child, which is
#     the documented protocol in docs/AGENTS.md and docs/WORKFLOW.md ("closed:
#     set by the agent after QA approval").
#
# THE AFFORDANCE IS NOT SILENTLY DROPPED. Removing a side effect and saying
# nothing would trade one silent wrong claim for a silently un-closed task —
# which is the same class of failure, and it feeds the stale-`in_progress` pile
# Phase P is separately trying to drain. So the release path now NAMES the close
# as the caller's decision, in band, with the command. A decision the caller
# makes explicitly is auditable; one the hook made for it was not.
CLOSE_HINT_NOTE=""
if [ -n "$CURRENT_TASK" ] && command -v bd >/dev/null 2>&1; then
    CLOSE_HINT_NOTE="

The gate is clear for $CURRENT_TASK, and the hook did NOT close it (qzv). This
approval binds a CHANGE SET, which is not evidence that the task's work is
finished — only you know whether more remains. If it is done:
  bd close $CURRENT_TASK --reason '<what shipped>'
If more work remains, leave it open and re-enter the gate for the next change
set."
fi

# Clean up tracking. Note: the legacy .qa-tracking/approved marker is no
# longer authoritative (B1/D1/J2). We still rm it to clean up stale files
# from older installs. Iteration counter cleanup covers both the per-task
# path (Phase 4 fix MATERIAL 5) and the legacy unscoped path.
rm -f "$QA_TRACKING_DIR/approved" 2>/dev/null || true
rm -f "$QA_TRACKING_DIR/changed-files.txt" 2>/dev/null || true
rm -f "$QA_TRACKING_DIR/edit-count" 2>/dev/null || true
rm -f "$ITERATION_FILE" 2>/dev/null || true
rm -f "$ITERATION_FILE_LEGACY" 2>/dev/null || true
# Spec 0.2: clear per-task escalation cache so a future cycle starts fresh.
if [ -n "$CURRENT_TASK" ]; then
    rm -f "$(last_test_rc_file_for "$CURRENT_TASK")" 2>/dev/null || true
    rm -f "$(last_failed_checks_file_for "$CURRENT_TASK")" 2>/dev/null || true
    rm -f "$(last_runner_file_for "$CURRENT_TASK")" 2>/dev/null || true
    rm -f "$(escalation_posted_file_for "$CURRENT_TASK")" 2>/dev/null || true
    # 2ty: the auto-defer counter belongs to the cycle that just closed.
    rm -f "$(escalated_stops_file_for "$CURRENT_TASK")" 2>/dev/null || true
fi

# B2: if the epic gate had something to surface, emit it as a non-blocking
# note via additionalContext. qzv: the close hint rides the SAME envelope rather
# than a second mechanism — one note path, so nothing has to decide which of two
# non-blocking envelopes wins. `{}` is still emitted whenever there is nothing to
# say (no task, or no bd), which is what keeps a no-Beads user's release silent.
if [ -n "$EPIC_DEFER_NOTE" ] || [ -n "$CLOSE_HINT_NOTE" ]; then
    NOTE_TEXT="QA gate cleared for $CURRENT_TASK.$EPIC_DEFER_NOTE$CLOSE_HINT_NOTE"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":$(printf '%s' "$NOTE_TEXT" | jq -Rs .)}}
EOF
    exit 0
fi

echo "{}"

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
#   status  <task-id>                       Print one of: not-entered, entered, approved, blocked.
#   approve <task-id> [--no-impact-report '<reason>'] <approval-summary>
#                                           Atomic: -qa-gate-entered, -qa-pending, +qa-approved, comment.
#                                           REFUSES (exit 2) when the impact report
#                                           (.qa-tracking/impact-report-<task-id>.json)
#                                           is missing or its change_set_hash no longer
#                                           matches the current changed-files list.
#                                           server:"absent" reports are accepted (the
#                                           documented degradation). The bypass flag
#                                           approves anyway and records the reason in
#                                           the approval comment + gate JSON.
#   block   <task-id> <reason>              Add qa-blocked label + comment. Keeps qa-gate-entered.
#   choose  <approve|continue|tech-debt|defer> <task-id> <note> [extra args for tech-debt]
#                                           Spec 0.2: record a J21 decision while qa-escalated.
#                                           Each choice records a comment + acts on labels/state.
#   grade-record <task-id> [--file <path>]  Spec Phase A: record a grader verdict.
#                                           Reads strict-JSON verdict from --file or stdin.
#                                           Appends a Beads comment; on satisfied flips
#                                           rubric-pending -> rubric-satisfied.
#
# Output: every subcommand prints structured JSON to stdout. Errors go to stderr.
# JSON shape (per principle #9 - free-form `observations` for LLM-side context):
#   {"ok": bool, "subcommand": "...", "task_id": "...", "status": "...", "observations": "..."}
#
# Exit codes:
#   0   success
#   1   missing args / usage error
#   2   bd unavailable, task lookup failed, or approve REFUSED for a
#       missing/invalid/stale impact report (error_key names which)
#   3   atomic operation rolled back

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"

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

# 0wk.2 fix: snapshot `git status --porcelain` so verify-before-stop.sh can
# distinguish NEW uncommitted entries (those that should re-trigger the
# gate) from PRE-EXISTING ones (already approved in this approval cycle).
# Without this, every Stop hook fire surfaced the same uncommitted set
# even when the user hadn't touched anything in the current turn.
#
# Contract:
#   - Writes `$QA_TRACKING_DIR/approved-baseline` containing the SORTED
#     output of `git status --porcelain`. Sorted so verify-before-stop's
#     `comm -23` (sorted-input requirement) can diff against it directly.
#   - On no-git-repo: remove any stale baseline so a later git-init won't
#     inherit a baseline taken before the repo existed.
#   - On git-not-on-PATH: log and return 1; the gate stays correct (no
#     baseline means verify-before-stop falls back to legacy "all new").
#   - mkdir -p before write so a fresh project without .qa-tracking can
#     still approve.
write_approved_baseline() {
    local tid="$1"
    local baseline="$QA_TRACKING_DIR/approved-baseline"
    if [ ! -d "$PROJECT_DIR/.git" ]; then
        # No git repo - remove any stale baseline; nothing to snapshot.
        rm -f "$baseline" 2>/dev/null || true
        return 0
    fi
    if ! command -v git >/dev/null 2>&1; then
        log_sync_error "write_approved_baseline: git not on PATH for $tid"
        return 1
    fi
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    if ! git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | sort > "$baseline"; then
        log_sync_error "write_approved_baseline: git status failed for $tid"
        return 1
    fi
    return 0
}

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

# G2.n6d (claude-workflow-plugin-llh.2): mechanical impact-report helpers.
#
# The report file is the deterministic impact_of artifact that the QA
# agent cannot skip: enter generates it, approve refuses without a fresh
# one. Path uses the same task-id sanitisation as the iteration counter.
IMPACT_REPORT_SCRIPT="$PROJECT_DIR/.claude/scripts/impact-report.sh"

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
              Also generates the mechanical impact report
              (.claude/.qa-tracking/impact-report-<task-id>.json) via
              impact-report.sh — tolerant, enter never fails because of it.
  status  <task-id>
  approve <task-id> [--no-impact-report '<reason>'] <approval-summary>
              REFUSES (exit 2, structured error) when the impact report is
              missing or stale (change_set_hash != current changed-files
              list). Regenerate with:
                bash .claude/scripts/impact-report.sh <task-id>
              server:"absent" reports are accepted (documented degradation).
              --no-impact-report '<reason>' bypasses the refusal; the reason
              is recorded in the approval comment and the gate JSON.
  block   <task-id> <reason>
  choose  <approve|continue|tech-debt|defer> <task-id> <note> [tech-debt: severity file:line effort]
              Record a J21 decision while qa-escalated. The note is the
              human-readable rationale; for `tech-debt` the note becomes
              the description and the optional trailing args are passed
              through to .claude/scripts/tech-debt.sh add.
              Effects:
                approve    -> delegates to `approve` (same atomic flow)
                continue   -> clears qa-escalated + resets iteration counter
                tech-debt  -> tech-debt.sh add --bd-task + clears escalation
                defer      -> sets qa-deferred (allows Stop next time)
  grade-record <task-id> [--file <path>]
              Spec Phase A: record a grader verdict. Reads a strict-JSON
              verdict from --file <path> or, if omitted, stdin. Required
              JSON keys:
                verdict          "satisfied" | "needs_revision"
                criterion_results array of {criterion, pass, justification}
                required_fixes   array
                iteration        number
                rubric_version   string
              Effects:
                - appends a Beads comment
                  `RUBRIC <rubric_version> iteration <n>: <verdict> — <summary>`
                - on satisfied: removes rubric-pending, adds rubric-satisfied
                - on needs_revision: labels unchanged (qa-blocked round-trip
                  is the QA agent's move, not this script's)
              Malformed input exits non-zero with a structured JSON error
              naming the offending key.
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
    bd label remove "$1" "$2" >/dev/null 2>&1
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

    # Spec Phase A: a fresh enter invalidates the prior cycle's rubric
    # verdict. We always clear rubric-satisfied (a new review cycle is
    # not yet satisfied) and ensure rubric-pending is set (the new
    # cycle is awaiting a grader verdict). Both happen unconditionally
    # so the rubric labels stay in lockstep with the gate lifecycle.
    local was_rubric_satisfied=0
    has_label "$tid" "rubric-satisfied" && was_rubric_satisfied=1
    if [ "$was_rubric_satisfied" = "1" ]; then
        remove_rubric_satisfied "$tid"
    fi

    if has_label "$tid" "qa-gate-entered"; then
        # Idempotent re-enter: the label is already there, but we still
        # refresh current-task in case it drifted (e.g., a different task
        # claimed it earlier in this session).
        # Also re-add rubric-pending: an already-entered task that lost
        # rubric-pending (e.g. via a stale grade-record from a prior
        # cycle) should be brought back to the awaiting-verdict state.
        add_label "$tid" "rubric-pending" || true
        local refreshed_obs="qa-gate-entered already set; current-task refreshed; rubric-pending refreshed"
        if ! write_current_task "$tid"; then
            refreshed_obs="qa-gate-entered already set; WARNING current-task write failed (see sync-errors.log); rubric-pending refreshed"
        fi
        if [ "$was_escalated" = "1" ] || [ "$was_deferred" = "1" ]; then
            refreshed_obs="$refreshed_obs; cleared prior escalation labels (escalated=$was_escalated deferred=$was_deferred) and reset iteration state"
        fi
        if [ "$was_rubric_satisfied" = "1" ]; then
            refreshed_obs="$refreshed_obs; cleared stale rubric-satisfied"
        fi
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

    # 0wk.2 fix: a new gate cycle invalidates the previous approval's
    # baseline. Without this, an approve from cycle N would leave its
    # baseline behind so verify-before-stop in cycle N+1 (post re-enter)
    # would treat ALL N+1 edits as already-approved.
    rm -f "$QA_TRACKING_DIR/approved-baseline" 2>/dev/null || true

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

    # G2.n6d: generate the mechanical impact report as part of packet
    # assembly. Tolerant by contract — a failed generation degrades to a
    # WARNING in the observations + sync-errors.log; enter still succeeds.
    # (approve is where the artifact is ENFORCED.)
    generate_impact_report "$tid" || true

    local extra_obs=""
    if [ "$was_escalated" = "1" ] || [ "$was_deferred" = "1" ]; then
        extra_obs=" cleared prior escalation labels (escalated=$was_escalated deferred=$was_deferred) and reset iteration state."
    fi
    if [ "$was_rubric_satisfied" = "1" ]; then
        extra_obs="$extra_obs cleared stale rubric-satisfied."
    fi
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
    local summary=""
    while [ $# -gt 0 ]; do
        case "$1" in
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
    local had_entered=0 had_pending=0 had_approved=0
    has_label "$tid" "qa-gate-entered" && had_entered=1
    has_label "$tid" "qa-pending" && had_pending=1
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

    if [ "$had_approved" = "1" ]; then
        emit_json 1 "approve" "$tid" "approved" "qa-approved already set; idempotent no-op"
        return 0
    fi

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

    # Step 1: add qa-approved (the source of truth).
    if ! add_label "$tid" "qa-approved"; then
        emit_json 0 "approve" "$tid" "error" "failed to add qa-approved; nothing changed"
        exit 3
    fi

    # Step 2: remove qa-gate-entered (best-effort but tracked for rollback).
    local removed_entered=0
    if [ "$had_entered" = "1" ]; then
        if remove_label "$tid" "qa-gate-entered"; then
            removed_entered=1
        else
            # Roll back qa-approved.
            remove_label "$tid" "qa-approved" || true
            emit_json 0 "approve" "$tid" "error" "failed to remove qa-gate-entered; rolled back qa-approved"
            exit 3
        fi
    fi

    # Step 3: remove qa-pending.
    local removed_pending=0
    if [ "$had_pending" = "1" ]; then
        if remove_label "$tid" "qa-pending"; then
            removed_pending=1
        else
            # Roll back: re-add qa-gate-entered if we removed it, drop qa-approved.
            # NB: the older `[ X ] && Y || true` shorthand here trips shellcheck
            # SC2015 because `Y` is allowed to exit non-zero (add_label returns
            # the bd exit code), in which case the `|| true` would mask it AND
            # the meaning isn't quite if/then/else. The explicit `if` is what
            # the SC2015 advice recommends.
            if [ "$removed_entered" = "1" ]; then
                add_label "$tid" "qa-gate-entered" || true
            fi
            remove_label "$tid" "qa-approved" || true
            emit_json 0 "approve" "$tid" "error" "failed to remove qa-pending; rolled back"
            exit 3
        fi
    fi

    # Step 4: comment with summary (non-fatal — labels are the source of truth).
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
    local ts comment_suffix=""
    if [ "$bypass_impact" = "1" ]; then
        comment_suffix=" [impact-report bypass: $bypass_reason]"
    fi
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local hash_field=""
    if [ -n "$approved_hash" ]; then
        hash_field="change_set_hash=$approved_hash "
    fi
    add_comment "$tid" "QA-GATE APPROVED ${hash_field}at $ts: $summary$comment_suffix"

    # F3 + F4: clear active task and wipe per-iteration state. These are
    # the last-step side effects: if a previous step failed and rolled back,
    # we don't reach here, so we never wipe state on a failed approval.
    # Pass tid so wipe_iteration_state can clear the per-task counter
    # (Phase 4 fix pass / MATERIAL 5).
    clear_current_task
    wipe_iteration_state "$tid"

    # Spec 0.2: also clear any qa-escalated / qa-deferred labels so a
    # subsequent re-enter on this task (or a future bug regression) starts
    # from a clean lifecycle.
    remove_escalation_labels "$tid"

    # Spec Phase A: the rubric cycle is over once approve runs. Drop
    # rubric-pending (the cycle was either resolved by a satisfied
    # verdict or overridden by the QA agent with a documented reason).
    # rubric-satisfied is preserved if present — it is the audit
    # trail showing the final verdict that backed this approval.
    remove_rubric_pending "$tid"

    # 0wk.2 fix: snapshot current git status to approved-baseline. Subsequent
    # Stop hook fires compare git status against this baseline and only
    # block if NEW uncommitted entries appear. Closes 0wk.2.
    write_approved_baseline "$tid"

    # 0wk.2 fix: truncate changed-files.txt - paired with the baseline, this
    # means a fresh approval starts a clean tracker. Closes 0wk.2.
    truncate_changed_files_tracker

    # Spec Phase A: build the rubric observation. The WARNING is the
    # loud signal the spec asks for when approve runs without a
    # satisfied verdict — the QA agent's prompt enforces the override
    # reason; we just surface the state.
    local rubric_obs=""
    if [ "$had_rubric_satisfied" = "1" ]; then
        rubric_obs="; rubric-satisfied preserved (audit trail)"
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

    emit_json 1 "approve" "$tid" "approved" "qa-approved set; removed qa-gate-entered=$removed_entered qa-pending=$removed_pending; summary recorded; current-task + iteration state cleared (escalation labels also cleared if present)$rubric_obs$impact_obs$binding_obs"
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

    if ! add_label "$tid" "qa-blocked"; then
        emit_json 0 "block" "$tid" "error" "failed to add qa-blocked label"
        exit 3
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

    emit_json 1 "block" "$tid" "blocked" "qa-blocked label set at $ts (qa-gate-entered preserved if present); ${memory_obs}"
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
#       "RUBRIC <rubric_version> iteration <n>: <verdict> — <summary>"
#     where <summary> is "all criteria pass" for satisfied, or a
#     comma-joined list of failed criterion names for needs_revision.
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
            -h|--help)
                usage
                exit 1
                ;;
            *)
                emit_error_json "grade-record" "$tid" "unknown_flag" \
                    "unknown argument: $1 (expected --file <path> or stdin)" \
                    "qa-gate.sh grade-record $tid [--file <path>]"
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

    # iteration must be a number. We accept integers and floats from JSON;
    # the comment uses the raw value. The 0.2 escalation cap is the agent's
    # concern, not ours.
    local it_type it_val
    it_type=$(printf '%s' "$raw" | jq -r '.iteration | type' 2>/dev/null || echo "unknown")
    if [ "$it_type" != "number" ]; then
        emit_error_json "grade-record" "$tid" "iteration_not_number" \
            "iteration is type=$it_type, expected number" \
            "iteration must be a JSON number (1, 2, 3, ...)"
        exit 1
    fi
    it_val=$(printf '%s' "$raw" | jq -r '.iteration' 2>/dev/null || echo "?")

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
    # RUBRIC <rubric_version> iteration <n>: <verdict> — <summary>
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local comment_text
    comment_text="RUBRIC $rv_val iteration $it_val: $verdict — $summary"
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

    emit_json 1 "grade-record" "$tid" "$verdict" \
        "comment posted at $ts: $comment_text; $label_obs"
}

# ---------------------------------------------------------------------------
# Dispatch

SUB="${1:-}"
shift || true

case "$SUB" in
    enter)        cmd_enter "$@" ;;
    status)       cmd_status "$@" ;;
    approve)      cmd_approve "$@" ;;
    block)        cmd_block "$@" ;;
    choose)       cmd_choose "$@" ;;
    grade-record) cmd_grade_record "$@" ;;
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

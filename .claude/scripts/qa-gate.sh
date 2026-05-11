#!/bin/bash
# QA Gate Lifecycle helper.
#
# Beads-backed design-gate lifecycle for the QA workflow. Replaces the legacy
# `.claude/.qa-tracking/approved` marker file (B1/D1/J2) and the comment-text
# fallback (B13). Single source of truth: Beads labels.
#
# Subcommands:
#   enter   <task-id>                       Mark gate as entered (label + comment).
#   status  <task-id>                       Print one of: not-entered, entered, approved, blocked.
#   approve <task-id> <approval-summary>    Atomic: -qa-gate-entered, -qa-pending, +qa-approved, comment.
#   block   <task-id> <reason>              Add qa-blocked label + comment. Keeps qa-gate-entered.
#
# Output: every subcommand prints structured JSON to stdout. Errors go to stderr.
# JSON shape (per principle #9 - free-form `observations` for LLM-side context):
#   {"ok": bool, "subcommand": "...", "task_id": "...", "status": "...", "observations": "..."}
#
# Exit codes:
#   0   success
#   1   missing args / usage error
#   2   bd unavailable or task lookup failed
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
wipe_iteration_state() {
    local tid="$1"
    rm -f "$QA_TRACKING_DIR/iteration-count" 2>/dev/null || true
    if [ -n "$tid" ]; then
        local sanitized
        sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
        rm -f "$QA_TRACKING_DIR/iteration-count.$sanitized" 2>/dev/null || true
    fi
    rm -f "$QA_TRACKING_DIR/last-test-output.log" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/last-lint-output.log" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/last-type-output.log" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/tech-debt-draft.md" 2>/dev/null || true
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
  status  <task-id>
  approve <task-id> <approval-summary>
  block   <task-id> <reason>
USAGE
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

    if has_label "$tid" "qa-gate-entered"; then
        # Idempotent re-enter: the label is already there, but we still
        # refresh current-task in case it drifted (e.g., a different task
        # claimed it earlier in this session).
        local refreshed_obs="qa-gate-entered already set; current-task refreshed"
        if ! write_current_task "$tid"; then
            refreshed_obs="qa-gate-entered already set; WARNING current-task write failed (see sync-errors.log)"
        fi
        emit_json 1 "enter" "$tid" "entered" "$refreshed_obs"
        return 0
    fi

    if ! add_label "$tid" "qa-gate-entered"; then
        emit_json 0 "enter" "$tid" "error" "failed to add qa-gate-entered label"
        exit 2
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

    emit_json 1 "enter" "$tid" "entered" "qa-gate-entered label set at $ts; current-task persisted.$persist_warn"
}

cmd_status() {
    local tid="$1"
    [ -z "$tid" ] && { usage; exit 1; }
    require_bd "status" "$tid"

    # Precedence: approved > blocked > entered > not-entered.
    if has_label "$tid" "qa-approved"; then
        emit_json 1 "status" "$tid" "approved" "qa-approved label present"
        return 0
    fi
    if has_label "$tid" "qa-blocked"; then
        emit_json 1 "status" "$tid" "blocked" "qa-blocked label present"
        return 0
    fi
    if has_label "$tid" "qa-gate-entered"; then
        emit_json 1 "status" "$tid" "entered" "qa-gate-entered label present, awaiting approve/block"
        return 0
    fi
    emit_json 1 "status" "$tid" "not-entered" "no qa lifecycle labels present"
}

cmd_approve() {
    local tid="$1"
    shift || true
    local summary="$*"
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

    if [ "$had_approved" = "1" ]; then
        emit_json 1 "approve" "$tid" "approved" "qa-approved already set; idempotent no-op"
        return 0
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
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    add_comment "$tid" "QA-GATE APPROVED at $ts: $summary"

    # F3 + F4: clear active task and wipe per-iteration state. These are
    # the last-step side effects: if a previous step failed and rolled back,
    # we don't reach here, so we never wipe state on a failed approval.
    # Pass tid so wipe_iteration_state can clear the per-task counter
    # (Phase 4 fix pass / MATERIAL 5).
    clear_current_task
    wipe_iteration_state "$tid"

    # 0wk.2 fix: snapshot current git status to approved-baseline. Subsequent
    # Stop hook fires compare git status against this baseline and only
    # block if NEW uncommitted entries appear. Closes 0wk.2.
    write_approved_baseline "$tid"

    # 0wk.2 fix: truncate changed-files.txt - paired with the baseline, this
    # means a fresh approval starts a clean tracker. Closes 0wk.2.
    truncate_changed_files_tracker

    emit_json 1 "approve" "$tid" "approved" "qa-approved set; removed qa-gate-entered=$removed_entered qa-pending=$removed_pending; summary recorded; current-task + iteration state cleared"
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

# ---------------------------------------------------------------------------
# Dispatch

SUB="${1:-}"
shift || true

case "$SUB" in
    enter)   cmd_enter "$@" ;;
    status)  cmd_status "$@" ;;
    approve) cmd_approve "$@" ;;
    block)   cmd_block "$@" ;;
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

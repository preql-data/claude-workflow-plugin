#!/bin/bash
# SessionEnd Hook: Sync Beads state.
#
# Phase 1 changes (claude-workflow-plugin-y4a.5):
#   - B11: cd is guarded so a missing PROJECT_DIR no longer corrupts state.
#          bd sync exit code is captured; failures are appended to
#          .claude/.qa-tracking/sync-errors.log so SessionStart can surface
#          a one-line warning next session.
#
# Phase 5 / E9: SessionEnd has no decision control per the Claude Code hooks
# reference (it cannot block session termination). Output and exit code are
# ignored. We emit `{}` for clarity, even though stdout is not consumed.

set -e
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SYNC_LOG="$PROJECT_DIR/.claude/.qa-tracking/sync-errors.log"

if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
    cd "$PROJECT_DIR" || { echo '{}'; exit 0; }

    mkdir -p "$(dirname "$SYNC_LOG")" 2>/dev/null || true

    # Capture stderr for the log line.
    SYNC_ERR_FILE="$(mktemp -t bd-sync.XXXXXX 2>/dev/null || echo "${TMPDIR:-/tmp}/bd-sync.$$")"
    if ! bd sync >/dev/null 2>"$SYNC_ERR_FILE"; then
        TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        ERR_LINE=$(head -1 "$SYNC_ERR_FILE" 2>/dev/null | tr -d '\n' || echo "")
        printf '%s\tbd sync failed: %s\n' "$TS" "${ERR_LINE:-unknown error}" >> "$SYNC_LOG"
    fi
    rm -f "$SYNC_ERR_FILE" 2>/dev/null || true
fi

# v4.1 C1b (claude-workflow-plugin-8xv): worktree sweep, REPORT-ONLY.
#
# SESSIONEND CANNOT ENFORCE ANYTHING. Per the Claude Code hooks reference its
# output and exit code are IGNORED and it cannot block session termination, so
# this leg only PERSISTS a count for the next SessionStart to surface. It passes
# --report-only and NEVER --apply: removing a worktree is an operator action, and
# a hook whose result nobody reads is the worst possible place to do it from. The
# sweeper itself does no network I/O (its pushed/merged decision is local).
#
# ITS OWN LOG FILE, deliberately not sync-errors.log: session-start.sh renders
# that log's head line verbatim as "Last session's bd sync failed at ..."
# regardless of any tag, so a sweep line landing there first would be reported
# as a bd failure. session-start.sh read-and-truncates this file separately.
#
# `set -e` is in force from the top of this file, so EVERY leg below is guarded —
# an unguarded failure would kill the hook before the `echo "{}"` at the end.
SWEEP_SH="$PROJECT_DIR/.claude/scripts/worktree-sweep.sh"
SWEEP_LOG="$PROJECT_DIR/.claude/.qa-tracking/worktree-sweep.log"
if [ -f "$SWEEP_SH" ]; then
    mkdir -p "$(dirname "$SWEEP_LOG")" 2>/dev/null || true
    # Hard 8s bound where a timeout binary exists. macOS ships neither by
    # default, so the fallback leans on the script's own SWEEP_MAX_CANDIDATES=16
    # bound (the same bound verify-before-stop.sh uses for the same reason).
    SWEEP_JSON=""
    if command -v timeout >/dev/null 2>&1; then
        SWEEP_JSON=$(timeout 8 bash "$SWEEP_SH" --report-only --json 2>/dev/null || true)
    elif command -v gtimeout >/dev/null 2>&1; then
        SWEEP_JSON=$(gtimeout 8 bash "$SWEEP_SH" --report-only --json 2>/dev/null || true)
    else
        SWEEP_JSON=$(bash "$SWEEP_SH" --report-only --json 2>/dev/null || true)
    fi
    SWEEP_N=""
    if [ -n "$SWEEP_JSON" ] && command -v jq >/dev/null 2>&1; then
        SWEEP_N=$(printf '%s' "$SWEEP_JSON" | jq -r '.removable // empty' 2>/dev/null || true)
    fi
    # A non-numeric SWEEP_N makes `[` exit 2, which inside an `if` condition is
    # simply "false" and does not trip set -e.
    if [ "${SWEEP_N:-0}" -gt 0 ] 2>/dev/null; then
        printf '%s\t%s sweepable worktree(s) under .claude/worktrees/; review with: bash .claude/scripts/worktree-sweep.sh (then --apply to remove)\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" "$SWEEP_N" \
            >> "$SWEEP_LOG" 2>/dev/null || true
    fi
fi

echo "{}"

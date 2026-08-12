#!/bin/bash
# SessionEnd Hook: DETECT a Beads ledger divergence. It writes nothing.
#
# Phase 1 changes (claude-workflow-plugin-y4a.5):
#   - B11: cd is guarded so a missing PROJECT_DIR no longer corrupts state.
#          The check exit code is captured; divergences and failures are
#          appended to .claude/.qa-tracking/sync-errors.log so SessionStart
#          can surface a one-line warning next session.
#
# THIS HOOK NO LONGER WRITES THE LEDGER (claude-workflow-plugin-fkm.1.1 /
# R4-F1). It ran `bd sync` until bd 1.1.2 removed that command, then
# `beads-ledger.sh export`, then the classifier-driven `refresh`. Five separate
# defects came out of letting an unattended hook decide to write — each an
# evidence rule whose claim was weaker than the safety property it authorised —
# so the automatic write was REMOVED rather than guarded a fifth time. What
# remains is `beads-ledger.sh check`, which is read-only.
#
# A divergence is therefore RECORDED here, surfaced by the next SessionStart,
# and reported by workflow-doctor.sh's `beads_ledger` check. Repair is an
# explicit operator action: `beads-ledger.sh reconcile --apply`, which the
# Landing-the-Plane protocol in AGENTS.md runs around `git pull`.
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

    # Capture stderr for the log line. The helper prints its own one-line
    # diagnosis on stdout, so BOTH streams are captured and stdout is preferred
    # for the log text — `bd export`'s own stderr is usually empty on the
    # failure paths that matter (missing bd, unwritable ledger).
    LEDGER_SH="$PROJECT_DIR/.claude/scripts/beads-ledger.sh"
    SYNC_ERR_FILE="$(mktemp -t bd-ledger.XXXXXX 2>/dev/null || echo "${TMPDIR:-/tmp}/bd-ledger.$$")"
    if [ -f "$LEDGER_SH" ]; then
        # `check` ONLY (R4-F1). SessionEnd used to write the ledger — first via
        # a direction-blind `export`, then via the classifier-driven `refresh`.
        # Both are gone: no hook writes the ledger, because five separate
        # defects came out of letting a classifier verdict authorise a write.
        # A divergence is RECORDED here and surfaced by the next SessionStart;
        # repairing it is an explicit `reconcile --apply`.
        LEDGER_RC=0
        bash "$LEDGER_SH" check >"$SYNC_ERR_FILE" 2>&1 || LEDGER_RC=$?
        TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        ERR_LINE=$(head -1 "$SYNC_ERR_FILE" 2>/dev/null | tr -d '\n' || echo "")
        if [ "$LEDGER_RC" = "1" ] || [ "$LEDGER_RC" = "3" ]; then
            printf '%s\tledger NOT written — it diverges from the database and no hook may repair that automatically. Run: bash .claude/scripts/beads-ledger.sh reconcile --apply\n' \
                "$TS" >> "$SYNC_LOG"
        elif [ "$LEDGER_RC" != "0" ]; then
            printf '%s\tledger check failed: %s\n' "$TS" "${ERR_LINE:-unknown error}" >> "$SYNC_LOG"
        fi
    else
        # A partial install: report it rather than silently skipping the
        # workflow's only ledger-divergence detector.
        TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '%s\tledger check skipped: %s is missing (partial install)\n' \
            "$TS" ".claude/scripts/beads-ledger.sh" >> "$SYNC_LOG"
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
# that log's head line verbatim as "Last session logged a Beads sync error at ..."
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

# v5.0.0 Phase D0: BEST-EFFORT restore of a per-unit implementer escalation.
#
# `model-select.sh escalate <task-id>` repins the implementer lane; `restore`
# puts it back. This is ONE of three restore paths, deliberately, because a
# session that dies never reaches this hook at all:
#   1. here, at SessionEnd (the tidy case);
#   2. the next SessionStart's `model-select.sh apply`, which rewrites the
#      implementer lane from the resolved artifact whatever state it was left
#      in — so a crash self-heals at the next session even if this never ran;
#   3. `model-select.sh restore` by hand, which is idempotent.
#
# BEST-EFFORT IS THE WHOLE CONTRACT. SessionEnd's output and exit code are
# IGNORED by the runtime (it cannot block termination), so a failure here has
# no channel to report on — which is exactly why path 2 exists and why this leg
# must never be the only one. `restore` is a no-op when no escalation is
# active, so the common path costs one file test.
ESCALATION_STATE="$PROJECT_DIR/.claude/.qa-tracking/implementer-escalation.json"
MODEL_SELECT_SH="$PROJECT_DIR/.claude/scripts/model-select.sh"
if [ -f "$ESCALATION_STATE" ] && [ -f "$MODEL_SELECT_SH" ]; then
    if command -v timeout >/dev/null 2>&1; then
        timeout 8 bash "$MODEL_SELECT_SH" restore >/dev/null 2>&1 || true
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 8 bash "$MODEL_SELECT_SH" restore >/dev/null 2>&1 || true
    else
        bash "$MODEL_SELECT_SH" restore >/dev/null 2>&1 || true
    fi
fi

echo "{}"

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

echo "{}"

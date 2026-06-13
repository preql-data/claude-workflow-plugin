#!/bin/bash
# tech-debt.sh - TECHNICAL_DEBT.md helper (J22, Phase 4).
#
# Subcommands:
#   add <severity> <file:line> <effort> <description> [--bd-task]
#     Append a debt row to TECHNICAL_DEBT.md at the repo root, creating
#     the file if needed. If --bd-task is passed AND the active task is
#     known, also create a Beads task with --deps blocks:<active-task>.
#
#   list
#     Print the table on stdout (no decoration). Useful for the QA agent
#     when triaging.
#
# Severity is free-form (low|medium|high|critical recommended; the script
# does not enforce a vocabulary because the plan principle #5 is "intent-
# based, not keyword-driven").
#
# Effort is free-form (e.g., "30m", "2h", "1d", "S/M/L"). Not validated.
#
# Output: JSON on stdout for `add` (with the row that was appended);
# plain text for `list`. Errors go to stderr.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
DEBT_FILE="$PROJECT_DIR/TECHNICAL_DEBT.md"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"

usage() {
    cat >&2 <<'USAGE'
Usage: tech-debt.sh <subcommand> [args]
  add <severity> <file:line> <effort> <description> [--bd-task]
      Append a row to TECHNICAL_DEBT.md. With --bd-task, also create a
      Beads task linked back to the active task (if known) via
      --deps blocks:<active-task>.

  list
      Print the table contents on stdout.

Severity recommendation: low | medium | high | critical (free-form).
Effort recommendation: 30m | 2h | 1d | S | M | L (free-form).
USAGE
}

ensure_header() {
    if [ ! -f "$DEBT_FILE" ]; then
        cat > "$DEBT_FILE" <<'HEADER'
# Technical debt

Deferred findings from QA gate runs. Each row was logged via
`.claude/scripts/tech-debt.sh add` (see plugin docs for J22 / Phase 4).

| severity | file:line | effort | description | added | resolved |
| -------- | --------- | ------ | ----------- | ----- | -------- |
HEADER
    fi
}

cmd_add() {
    local severity="$1"; shift || true
    local fileline="$1"; shift || true
    local effort="$1"; shift || true
    local description=""
    local make_bd_task=false

    # Slurp remaining args; --bd-task can appear anywhere.
    while [ $# -gt 0 ]; do
        case "$1" in
            --bd-task) make_bd_task=true ;;
            *) description="${description:+$description }$1" ;;
        esac
        shift
    done

    if [ -z "$severity" ] || [ -z "$fileline" ] || [ -z "$effort" ] || [ -z "$description" ]; then
        usage
        exit 1
    fi

    ensure_header

    local now
    now=$(date -u +%Y-%m-%d)

    # Sanitize pipe characters in description so we don't break the table.
    local safe_desc safe_severity safe_effort safe_fileline
    safe_desc=$(printf '%s' "$description" | tr '|' '/')
    safe_severity=$(printf '%s' "$severity" | tr '|' '/')
    safe_effort=$(printf '%s' "$effort" | tr '|' '/')
    safe_fileline=$(printf '%s' "$fileline" | tr '|' '/')

    printf '| %s | %s | %s | %s | %s | %s |\n' \
        "$safe_severity" "$safe_fileline" "$safe_effort" "$safe_desc" "$now" "" \
        >> "$DEBT_FILE"

    local bd_task_id=""
    if [ "$make_bd_task" = true ] && command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
        local active=""
        if [ -x "$CURRENT_TASK_HELPER" ]; then
            active=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
        fi
        local -a deps_args=()
        [ -n "$active" ] && deps_args=(--deps "blocks:$active")
        # bd create returns json with --json. Title is the description.
        local title="Tech-debt ($severity): $description"
        # Best-effort: capture id, fall back silently on parse failure.
        bd_task_id=$(bd create "$title" -t task -p 2 "${deps_args[@]}" --json 2>/dev/null \
            | jq -r '.id // empty' 2>/dev/null || echo "")
    fi

    jq -n \
        --arg sev "$severity" \
        --arg fl "$fileline" \
        --arg eff "$effort" \
        --arg desc "$description" \
        --arg added "$now" \
        --arg bd "$bd_task_id" \
        --arg debt_file "$DEBT_FILE" \
        '{ok:true, subcommand:"add", row:{severity:$sev, "file:line":$fl, effort:$eff,
                                          description:$desc, added:$added},
          bd_task_id:(if $bd == "" then null else $bd end),
          debt_file:$debt_file,
          observations: (if $bd == "" then "Row appended; no Beads task created." else "Row appended; Beads task " + $bd + " created with blocks dependency on the active task." end)}'
}

cmd_list() {
    if [ ! -f "$DEBT_FILE" ]; then
        # shellcheck disable=SC2016  # literal backticks are intentional in user-facing hint.
        printf 'No TECHNICAL_DEBT.md yet. Use `tech-debt.sh add` to create one.\n'
        return 0
    fi
    cat "$DEBT_FILE"
}

SUB="${1:-}"
shift || true

case "$SUB" in
    add)  cmd_add "$@" ;;
    list) cmd_list "$@" ;;
    ""|-h|--help|help)
        usage
        exit 1
        ;;
    *)
        echo "tech-debt.sh: unknown subcommand: $SUB" >&2
        usage
        exit 1
        ;;
esac

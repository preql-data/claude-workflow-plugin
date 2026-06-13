#!/bin/bash
# lessons.sh — LESSONS.md helper (spec 0.7 / claude-workflow-plugin-e0d.7).
#
# Subcommands:
#   add <lesson text> --source <task-id>
#     Dedup-append a lesson to LESSONS.md at the repo root. Dedup is by
#     normalized-text match (case-insensitive, whitespace-collapsed).
#     If an existing entry matches, the new --source is appended to
#     that entry's sources list (de-duplicated within the line) and no
#     new entry is created. If no match, a new entry is appended with
#     today's date as the first-recorded date.
#
#   list
#     Print the ledger contents on stdout. Errors with usage if the
#     file doesn't exist yet (the seeded LESSONS.md is committed; if
#     someone deletes it the script should not silently re-create an
#     empty one because the seeds would be lost).
#
# Entry format (one line per lesson, machine-parseable via HTML
# comments so a markdown viewer renders the prose cleanly):
#
#   - <lesson text> <!-- sources: id1, id2 --> <!-- recorded: YYYY-MM-DD -->
#
# Conventions mirror tech-debt.sh: set -e, no jq for the core path,
# usage-on-stderr-exit-1 for malformed input, JSON on stdout for add
# so callers (qa.md's epic-close step) can read structured output.
#
# Why HTML comments: they don't render in markdown but are trivial to
# grep and sed. Each lesson stays one line, which keeps the dedup and
# source-append logic simple — no multi-line state machine.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LEDGER_FILE="$PROJECT_DIR/LESSONS.md"

usage() {
    cat >&2 <<'USAGE'
Usage: lessons.sh <subcommand> [args]
  add <lesson text> --source <task-id>
      Append a lesson to LESSONS.md, deduplicated by normalized text.
      If an existing entry matches, only the source list is updated.

  list
      Print the ledger contents on stdout.

The --source argument is required for `add`. Source ids are typically
Beads task ids (e.g. claude-workflow-plugin-e0d.7); the script does not
validate the format.
USAGE
}

# Normalize text for dedup comparison: lowercase, collapse whitespace
# runs to a single space, strip leading/trailing whitespace. POSIX
# tools only so the script runs anywhere bash runs.
normalize() {
    # tr -s '[:space:]' ' '  collapses any whitespace run to a single
    # space (covers tabs, newlines, multiple spaces); then sed trims
    # leading/trailing; then tr lowercases. Output goes to stdout.
    printf '%s' "$1" \
        | tr -s '[:space:]' ' ' \
        | sed -e 's/^ //' -e 's/ $//' \
        | tr '[:upper:]' '[:lower:]'
}

# Strip HTML comment payloads from a lesson line so we can normalize
# just the prose portion. Argument: the entire `- <text> <!-- ... -->`
# line. Output on stdout: just the `<text>`.
strip_comments() {
    # Drop everything from the first `<!--` onward; then drop the
    # leading `- ` marker; then strip surrounding whitespace.
    printf '%s' "$1" \
        | sed -e 's/<!--.*$//' -e 's/^- //' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Extract the sources list (comma-separated ids) from a lesson line.
extract_sources() {
    # Grab the substring between `<!-- sources:` and `-->`.
    printf '%s' "$1" \
        | sed -n 's/.*<!-- sources:[[:space:]]*\([^>]*\)[[:space:]]*-->.*/\1/p' \
        | sed -e 's/[[:space:]]*$//'
}

# Build a fresh sources list, adding $new to $existing if not present.
# Echoes the de-duplicated, comma-joined list on stdout.
merge_sources() {
    local existing="$1" new="$2"
    local id present=0
    # Split on commas. Trim each id. If any equals $new, mark present.
    local IFS=','
    # shellcheck disable=SC2086  # word-split on commas is the intent.
    for id in $existing; do
        id=$(printf '%s' "$id" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ "$id" = "$new" ]; then
            present=1
        fi
    done
    if [ "$present" -eq 1 ]; then
        printf '%s' "$existing"
    else
        if [ -z "$existing" ]; then
            printf '%s' "$new"
        else
            printf '%s, %s' "$existing" "$new"
        fi
    fi
}

cmd_add() {
    local lesson=""
    local source_id=""

    # Parse: --source consumes the next arg; everything else is part
    # of the lesson text (joined with spaces). This matches tech-debt.sh's
    # arg-slurp style.
    while [ $# -gt 0 ]; do
        case "$1" in
            --source)
                shift
                source_id="${1:-}"
                ;;
            *)
                lesson="${lesson:+$lesson }$1"
                ;;
        esac
        shift || true
    done

    if [ -z "$lesson" ] || [ -z "$source_id" ]; then
        usage
        exit 1
    fi

    if [ ! -f "$LEDGER_FILE" ]; then
        printf 'lessons.sh: %s does not exist. Seed file is required (do not auto-create).\n' \
            "$LEDGER_FILE" >&2
        exit 1
    fi

    local normalized_new
    normalized_new=$(normalize "$lesson")

    # Walk every list-item line in the ledger and look for a normalized
    # match. We use awk with a here-string is risky on macOS bash 3.2,
    # so we stream the file with a while-read loop.
    local matched_line_number=0
    local line_number=0
    local matched_existing_sources=""
    local matched_line=""

    while IFS= read -r line; do
        line_number=$((line_number + 1))
        # Skip non-list-item lines (header, prose, blank).
        case "$line" in
            "- "*) ;;
            *) continue ;;
        esac
        local prose normalized_existing
        prose=$(strip_comments "$line")
        normalized_existing=$(normalize "$prose")
        if [ "$normalized_existing" = "$normalized_new" ]; then
            matched_line_number=$line_number
            matched_existing_sources=$(extract_sources "$line")
            matched_line="$line"
            break
        fi
    done < "$LEDGER_FILE"

    local today
    today=$(date -u +%Y-%m-%d)

    if [ "$matched_line_number" -gt 0 ]; then
        # Update the matched line's sources in place. Build the new
        # sources string, then rewrite the line via a temp file (sed
        # in-place is non-portable across macOS / GNU; a temp-file
        # rewrite is the safe path).
        local merged
        merged=$(merge_sources "$matched_existing_sources" "$source_id")
        # If merged == existing, nothing changes — idempotent.
        if [ "$merged" = "$matched_existing_sources" ]; then
            printf '{"ok":true,"subcommand":"add","action":"noop","reason":"source already present","ledger":"%s","entry_line":%d}\n' \
                "$LEDGER_FILE" "$matched_line_number"
            return 0
        fi
        # Rebuild the line: same prose, new sources, same recorded date.
        local recorded_date
        recorded_date=$(printf '%s' "$matched_line" \
            | sed -n 's/.*<!-- recorded:[[:space:]]*\([0-9-]*\)[[:space:]]*-->.*/\1/p')
        [ -z "$recorded_date" ] && recorded_date="$today"
        local prose
        prose=$(strip_comments "$matched_line")
        local new_line
        new_line=$(printf -- '- %s <!-- sources: %s --> <!-- recorded: %s -->' \
            "$prose" "$merged" "$recorded_date")

        local tmp
        tmp=$(mktemp -t lessons-rewrite.XXXXXX)
        awk -v target="$matched_line_number" -v replacement="$new_line" '
            NR == target { print replacement; next }
            { print }
        ' "$LEDGER_FILE" > "$tmp"
        mv "$tmp" "$LEDGER_FILE"

        printf '{"ok":true,"subcommand":"add","action":"merged","ledger":"%s","entry_line":%d,"sources":"%s"}\n' \
            "$LEDGER_FILE" "$matched_line_number" "$merged"
        return 0
    fi

    # No match — append a fresh entry.
    local new_entry
    new_entry=$(printf -- '- %s <!-- sources: %s --> <!-- recorded: %s -->' \
        "$lesson" "$source_id" "$today")
    printf '%s\n' "$new_entry" >> "$LEDGER_FILE"

    printf '{"ok":true,"subcommand":"add","action":"appended","ledger":"%s","sources":"%s","recorded":"%s"}\n' \
        "$LEDGER_FILE" "$source_id" "$today"
}

cmd_list() {
    if [ ! -f "$LEDGER_FILE" ]; then
        printf 'lessons.sh: %s does not exist.\n' "$LEDGER_FILE" >&2
        exit 1
    fi
    cat "$LEDGER_FILE"
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
        echo "lessons.sh: unknown subcommand: $SUB" >&2
        usage
        exit 1
        ;;
esac

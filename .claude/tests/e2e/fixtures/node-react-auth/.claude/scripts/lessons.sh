#!/bin/bash
# lessons.sh — LESSONS.md helper.
#
# Spec 0.7 (claude-workflow-plugin-e0d.7) created it; tag scoping was added
# by claude-workflow-plugin-zerv (v5 phase P, plan item P8) so consumers can
# read a SLICE of the ledger instead of all of it.
#
# Subcommands:
#   add <lesson text> --source <task-id> --tag <tag> [--tag <tag>]...
#   add --stdin        --source <task-id> --tag <tag> [--tag <tag>]...
#     Dedup-append a lesson to LESSONS.md at the repo root. Dedup is by
#     normalized-text match (case-insensitive, whitespace-collapsed).
#     If an existing entry matches, the new --source and --tag values are
#     merged into that entry's lists and no new entry is created. If no
#     match, a new entry is appended with today's date as the
#     first-recorded date. --tag is REQUIRED: an untagged entry is
#     invisible to every scoped read below, which is the same as not
#     being in the ledger for the consumers that scope.
#
#   list [--tag <t>]... [--untagged] [--since <YYYY-MM-DD>] [--limit <n>]
#     With NO flags, print the ledger file verbatim — byte-identical to
#     `cat LESSONS.md`. This is the form the grading packet uses and it
#     must stay lossless (see "Who reads what" below). With any flag,
#     print only the matching entry lines, in ledger order.
#
# ---------------------------------------------------------------------------
# Entry format — ONE line per lesson, THREE HTML comments in a FIXED order:
#
#   - <text> <!-- sources: id1, id2 --> <!-- tags: gate, testing --> <!-- recorded: YYYY-MM-DD -->
#
# WHY A THIRD COMMENT AND NOT SECTIONS OR SORTING: `.claude/agents/grader.md`
# and `.claude/rubrics/default.md` cite lessons by ORDINAL POSITION ("lesson
# 1", "lesson 2"), and `.claude/agents/orchestrator.md` cites "entry 1".
# Grouping entries under headings, or sorting them by tag, repoints those
# citations at different lessons — SILENTLY, because nothing errors and the
# cite still reads plausibly. A third comment on the same line leaves the
# ledger's line order byte-identical, so every ordinal cite keeps its meaning.
#
# THE GRAMMAR IS THE SECURITY BOUNDARY. All three payloads live inside HTML
# comments on one line, so a field value containing `-->` closes its comment
# early and RELOCATES every later field on read-back: extract_sources would
# return the tag list, extract_tags the date, and a rewrite would then persist
# the relocation. Every writer-controlled field is validated and REJECTED on
# violation. Nothing is ever sanitised — silently rewriting an operator's text
# is how a ledger acquires entries nobody wrote. (Same discipline as
# qa-gate.sh's record writers; see claude-workflow-plugin-bjx.)
#
# Who reads what (keep this list current when you add a consumer):
#   - qa.md 6a step 5 assembles the GRADING PACKET and must pass the FULL
#     ledger. Lessons are criteria-by-reference for the grader — narrowing
#     its view narrows the criteria it can apply. Never add a filter there.
#   - orchestrator.md reads a RECENT slice before decomposing work.
#   - grader.md and rubrics/default.md cite lessons by ordinal.
#
# Conventions mirror tech-debt.sh: set -e, no jq for the core path,
# usage-on-stderr-exit-1 for malformed input, JSON on stdout for add
# so callers (qa.md's epic-close step) can read structured output.
# Structured errors go to STDERR as JSON with ok:false.
#
# Why HTML comments at all: they don't render in markdown but are trivial to
# grep and sed. Each lesson stays one line, which keeps the dedup and
# source-append logic simple — no multi-line state machine.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LEDGER_FILE="$PROJECT_DIR/LESSONS.md"

# The closed tag vocabulary. This list is ENFORCED here, not merely
# documented: an unenforced "closed vocabulary" is a claim the ledger cannot
# keep. It is mirrored in LESSONS.md's preamble so a human reading the ledger
# sees the same list; lessons-vocabulary-parity in lessons.test.sh asserts the
# two copies agree, so they cannot drift.
#
# Space-separated for bash 3.2 (macOS) — no associative arrays.
TAG_VOCABULARY="gate testing packaging agents evidence process"

usage() {
    cat >&2 <<'USAGE'
Usage: lessons.sh <subcommand> [args]

  add <lesson text> --source <task-id> --tag <tag> [--tag <tag>]...
  add --stdin       --source <task-id> --tag <tag> [--tag <tag>]...
      Append a lesson to LESSONS.md, deduplicated by normalized text.
      If an existing entry matches, only the source and tag lists update.
      --source and at least one --tag are REQUIRED.

  list [--tag <t>]... [--untagged] [--since <YYYY-MM-DD>] [--limit <n>]
      With no flags: print the ledger verbatim (same bytes as `cat`).
      --tag <t>     keep entries carrying tag <t>; repeatable, OR-combined.
      --untagged    keep entries with no tags (mutually exclusive with --tag).
      --since <d>   keep entries whose `recorded:` date is >= <d>.
      --limit <n>   keep the MOST RECENT <n> matches (ledger order preserved).

Tag vocabulary (closed): gate testing packaging agents evidence process
Each tag must match ^[a-z0-9][a-z0-9-]*$.

QUOTING — read this before writing a lesson inline:
  Neither quote style is safe for this corpus. Single quotes protect the
  backticks lessons routinely contain but END AT THE FIRST APOSTROPHE, which
  is how several entries lost their possessives ("the gate's own" -> "the gate
  own"); the helper dedups on normalized TEXT, so re-adding a corrected
  version appends a duplicate instead of replacing the damaged one. Double
  quotes protect apostrophes but let `backticks` run as command substitution.
  Use --stdin with a quoted heredoc, which is literal on both counts:

      bash .claude/scripts/lessons.sh add --stdin \
          --source <task-id> --tag gate --tag testing <<'LESSON'
      A gate's own bookkeeping can destroy the evidence a later check needs.
      LESSON

The --source argument is required. Source ids are typically Beads task ids
(e.g. claude-workflow-plugin-e0d.7); the script does not validate the format
beyond rejecting characters that would corrupt the entry grammar.
USAGE
}

# JSON-escape a value for embedding in an error message. This escapes for
# TRANSPORT only — the offending value is still rejected, never stored.
json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | tr '\n\r\t' '   ' \
        | LC_ALL=C tr -d '\001-\037'
}

# Structured error on stderr, then exit 1.
#   $1 subcommand, $2 error code, $3 offending field, $4 offending value,
#   $5 human detail.
err_json() {
    printf '{"ok":false,"subcommand":"%s","error":"%s","field":"%s","value":"%s","detail":"%s"}\n' \
        "$1" "$2" "$3" "$(json_escape "$4")" "$5" >&2
    exit 1
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

# Extract the tags list (comma-separated) from a lesson line. Twin of
# extract_sources. Empty output means "no tags comment" OR "empty tags
# comment"; both are `--untagged` for filtering purposes, and both are
# states `add` refuses to create.
extract_tags() {
    printf '%s' "$1" \
        | sed -n 's/.*<!-- tags:[[:space:]]*\([^>]*\)[[:space:]]*-->.*/\1/p' \
        | sed -e 's/[[:space:]]*$//'
}

# Extract the recorded date from a lesson line. Empty if absent.
extract_recorded() {
    printf '%s' "$1" \
        | sed -n 's/.*<!-- recorded:[[:space:]]*\([0-9-]*\)[[:space:]]*-->.*/\1/p'
}

# Build a fresh sources list, adding $new to $existing if not present.
# Echoes the de-duplicated, comma-joined list on stdout.
#
# Sources keep INSERTION order on purpose: the list is a chronology of which
# tasks produced the lesson, so reordering it destroys information. Tags do
# not (see merge_tags) — they are a set.
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

# Build a fresh tags list from $1 (existing comma-list, may be empty) plus
# every remaining argument. Echoes a de-duplicated, SORTED, comma-joined list.
#
# Unlike sources, tags render in canonical sorted order: a tag list is a set
# (a retrieval filter), not a history, so the same set must always produce the
# same bytes regardless of the order the flags were passed.
merge_tags() {
    local existing="$1"
    shift
    local joined="$existing" t
    for t in "$@"; do
        joined="${joined:+$joined,}$t"
    done
    printf '%s' "$joined" \
        | tr ',' '\n' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | LC_ALL=C sort -u \
        | tr '\n' ',' \
        | sed -e 's/,$//' -e 's/,/, /g'
}

# True when the comma-list $1 contains the exact tag $2.
tags_contain() {
    local list="$1" want="$2" t
    local IFS=','
    # shellcheck disable=SC2086  # word-split on commas is the intent.
    for t in $list; do
        t=$(printf '%s' "$t" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ "$t" = "$want" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Validation. Every writer-controlled field passes through here before it can
# reach the ledger. Reject, never sanitise.

# A value that would terminate an HTML comment early, relocating every field
# after it when the line is read back. Applies to prose, sources and tags.
assert_no_comment_grammar() {
    local sub="$1" field="$2" value="$3"
    case "$value" in
        *'<!--'*|*'-->'*)
            err_json "$sub" "comment-grammar-injection" "$field" "$value" \
                "value contains <!-- or --> which would close the HTML comment early and relocate every later field on read-back; rephrase it (the arrow -> is fine, --> is not)"
            ;;
    esac
}

# ^[a-z0-9][a-z0-9-]*$ , enforced without regex-engine or locale surprises.
# The trailing X sentinel matters: $(...) strips trailing newlines, so without
# it a tag ending in a newline would compare equal to a clean one.
tag_charset_ok() {
    local t="$1" residue
    [ -n "$t" ] || return 1
    residue=$(printf '%sX' "$t" | LC_ALL=C tr -d 'a-z0-9-')
    [ "$residue" = "X" ] || return 1
    case "$t" in -*) return 1 ;; esac
    return 0
}

tag_in_vocabulary() {
    local t="$1" known
    for known in $TAG_VOCABULARY; do
        [ "$t" = "$known" ] && return 0
    done
    return 1
}

# $1 = subcommand (for the error payload), $2 = tag.
validate_tag() {
    local sub="$1" t="$2"
    # Injection first: it is the failure that corrupts the FILE, not just the
    # call, so it gets the specific error code even for an in-vocabulary-
    # looking value.
    assert_no_comment_grammar "$sub" "tag" "$t"
    if ! tag_charset_ok "$t"; then
        err_json "$sub" "invalid-tag-charset" "tag" "$t" \
            "each tag must match ^[a-z0-9][a-z0-9-]*$"
    fi
    if ! tag_in_vocabulary "$t"; then
        err_json "$sub" "unknown-tag" "tag" "$t" \
            "tag vocabulary is closed: $TAG_VOCABULARY (extend TAG_VOCABULARY in lessons.sh and the LESSONS.md preamble together)"
    fi
}

# Source ids are joined with ", " inside an HTML comment and read back with a
# [^>]* capture, so a comma or an angle bracket silently splits or truncates
# the list on the next rewrite. Reject exactly those; everything else is a
# free-form id.
validate_source() {
    local sub="$1" s="$2"
    assert_no_comment_grammar "$sub" "source" "$s"
    case "$s" in
        *,*|*'<'*|*'>'*)
            err_json "$sub" "invalid-source-charset" "source" "$s" \
                "a source id may not contain a comma or an angle bracket: the list is comma-joined inside an HTML comment and would split or truncate on read-back"
            ;;
    esac
}

# Prose may contain < and > freely (strip_comments cuts at the first `<!--`,
# it does not scan for brackets) but must be one line and must not carry
# comment delimiters.
validate_prose() {
    local sub="$1" p="$2"
    assert_no_comment_grammar "$sub" "lesson" "$p"
    # $'\n' and NOT "$(printf '\n')": command substitution strips trailing
    # newlines, so the latter expands to the empty string and the pattern
    # degrades to `**`, which matches every lesson. Caught in smoke testing.
    local nl=$'\n'
    case "$p" in
        *"$nl"*)
            err_json "$sub" "multiline-lesson" "lesson" "$p" \
                "the ledger stores one line per entry; pass multi-line text via --stdin, which collapses it"
            ;;
    esac
}

# ---------------------------------------------------------------------------

cmd_add() {
    local lesson=""
    local source_id=""
    local use_stdin=0
    # bash 3.2: a plain array, no associative anything.
    local tags=()

    # Parse: --source and --tag consume the next arg; everything else is part
    # of the lesson text (joined with spaces). This matches tech-debt.sh's
    # arg-slurp style.
    while [ $# -gt 0 ]; do
        case "$1" in
            --source)
                shift
                source_id="${1:-}"
                ;;
            --tag)
                shift
                tags+=("${1:-}")
                ;;
            --stdin)
                use_stdin=1
                ;;
            *)
                lesson="${lesson:+$lesson }$1"
                ;;
        esac
        shift || true
    done

    if [ "$use_stdin" -eq 1 ]; then
        if [ -n "$lesson" ]; then
            err_json "add" "stdin-and-inline-text" "lesson" "$lesson" \
                "--stdin was given together with inline lesson text; pass the lesson one way or the other"
        fi
        if [ -t 0 ]; then
            err_json "add" "stdin-is-a-tty" "lesson" "" \
                "--stdin was given but stdin is a terminal; pipe the lesson in or use a heredoc"
        fi
        # Collapse the whole stream to one line: the ledger grammar is one
        # line per entry, and a heredoc is the point of --stdin.
        lesson=$(cat | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
    fi

    if [ -z "$lesson" ] || [ -z "$source_id" ] || [ "${#tags[@]}" -eq 0 ]; then
        usage
        exit 1
    fi

    validate_prose "add" "$lesson"
    validate_source "add" "$source_id"
    local t
    for t in "${tags[@]}"; do
        validate_tag "add" "$t"
    done

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
    local matched_existing_tags=""
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
            matched_existing_tags=$(extract_tags "$line")
            matched_line="$line"
            break
        fi
    done < "$LEDGER_FILE"

    local today
    today=$(date -u +%Y-%m-%d)

    if [ "$matched_line_number" -gt 0 ]; then
        # Update the matched line in place. Build the new sources and tags
        # strings, then rewrite the line via a temp file (sed in-place is
        # non-portable across macOS / GNU; a temp-file rewrite is the safe
        # path).
        local merged merged_tags
        merged=$(merge_sources "$matched_existing_sources" "$source_id")
        merged_tags=$(merge_tags "$matched_existing_tags" "${tags[@]}")
        # If NEITHER list changed, nothing changes — idempotent.
        if [ "$merged" = "$matched_existing_sources" ] && \
           [ "$merged_tags" = "$matched_existing_tags" ]; then
            printf '{"ok":true,"subcommand":"add","action":"noop","reason":"source and tags already present","ledger":"%s","entry_line":%d}\n' \
                "$LEDGER_FILE" "$matched_line_number"
            return 0
        fi
        # Rebuild the line: same prose, merged sources, merged tags, same
        # recorded date.
        local recorded_date
        recorded_date=$(extract_recorded "$matched_line")
        [ -z "$recorded_date" ] && recorded_date="$today"
        local prose
        prose=$(strip_comments "$matched_line")
        local new_line
        new_line=$(printf -- '- %s <!-- sources: %s --> <!-- tags: %s --> <!-- recorded: %s -->' \
            "$prose" "$merged" "$merged_tags" "$recorded_date")

        local tmp
        tmp=$(mktemp -t lessons-rewrite.XXXXXX)
        awk -v target="$matched_line_number" -v replacement="$new_line" '
            NR == target { print replacement; next }
            { print }
        ' "$LEDGER_FILE" > "$tmp"
        mv "$tmp" "$LEDGER_FILE"

        printf '{"ok":true,"subcommand":"add","action":"merged","ledger":"%s","entry_line":%d,"sources":"%s","tags":"%s"}\n' \
            "$LEDGER_FILE" "$matched_line_number" "$merged" "$merged_tags"
        return 0
    fi

    # No match — append a fresh entry.
    local new_tags
    new_tags=$(merge_tags "" "${tags[@]}")
    local new_entry
    new_entry=$(printf -- '- %s <!-- sources: %s --> <!-- tags: %s --> <!-- recorded: %s -->' \
        "$lesson" "$source_id" "$new_tags" "$today")
    printf '%s\n' "$new_entry" >> "$LEDGER_FILE"

    printf '{"ok":true,"subcommand":"add","action":"appended","ledger":"%s","sources":"%s","tags":"%s","recorded":"%s"}\n' \
        "$LEDGER_FILE" "$source_id" "$new_tags" "$today"
}

cmd_list() {
    local want_tags=()
    local untagged=0
    local since=""
    local limit=""
    local filtered=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --tag)
                shift
                want_tags+=("${1:-}")
                filtered=1
                ;;
            --untagged)
                untagged=1
                filtered=1
                ;;
            --since)
                shift
                since="${1:-}"
                filtered=1
                ;;
            --limit)
                shift
                limit="${1:-}"
                filtered=1
                ;;
            *)
                printf 'lessons.sh: list: unknown option: %s\n' "$1" >&2
                usage
                exit 1
                ;;
        esac
        shift || true
    done

    if [ ! -f "$LEDGER_FILE" ]; then
        printf 'lessons.sh: %s does not exist.\n' "$LEDGER_FILE" >&2
        exit 1
    fi

    # No flags: the ledger verbatim. The grading packet depends on these
    # bytes being the whole file.
    if [ "$filtered" -eq 0 ]; then
        cat "$LEDGER_FILE"
        return 0
    fi

    if [ "$untagged" -eq 1 ] && [ "${#want_tags[@]}" -gt 0 ]; then
        err_json "list" "contradictory-filters" "--untagged" "" \
            "--untagged and --tag select disjoint sets; pass one or the other"
    fi

    local t
    for t in ${want_tags[@]+"${want_tags[@]}"}; do
        validate_tag "list" "$t"
    done

    if [ -n "$since" ]; then
        case "$since" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
            *)
                err_json "list" "invalid-since" "--since" "$since" \
                    "expected a YYYY-MM-DD date; it is compared against the entry's recorded: field"
                ;;
        esac
    fi

    if [ -n "$limit" ]; then
        case "$limit" in
            ''|*[!0-9]*)
                err_json "list" "invalid-limit" "--limit" "$limit" \
                    "expected a positive integer"
                ;;
        esac
        if [ "$limit" -lt 1 ]; then
            err_json "list" "invalid-limit" "--limit" "$limit" \
                "expected a positive integer"
        fi
    fi

    local matches=()
    local line entry_tags entry_date keep
    while IFS= read -r line; do
        case "$line" in
            "- "*) ;;
            *) continue ;;
        esac

        entry_tags=$(extract_tags "$line")

        if [ "$untagged" -eq 1 ] && [ -n "$entry_tags" ]; then
            continue
        fi

        if [ "${#want_tags[@]}" -gt 0 ]; then
            keep=0
            for t in "${want_tags[@]}"; do
                if tags_contain "$entry_tags" "$t"; then
                    keep=1
                    break
                fi
            done
            [ "$keep" -eq 1 ] || continue
        fi

        if [ -n "$since" ]; then
            entry_date=$(extract_recorded "$line")
            # ISO-8601 dates compare correctly as strings. An entry with no
            # readable date cannot satisfy a --since bound, so it drops out.
            [ -n "$entry_date" ] || continue
            [ "$entry_date" \< "$since" ] && continue
        fi

        matches+=("$line")
    done < "$LEDGER_FILE"

    local total="${#matches[@]}"
    [ "$total" -eq 0 ] && return 0

    # --limit keeps the MOST RECENT n, because the ledger is append-ordered
    # and every consumer of --limit wants "what happened lately". Ledger order
    # is preserved within the kept window.
    local start=0
    if [ -n "$limit" ] && [ "$total" -gt "$limit" ]; then
        start=$((total - limit))
    fi

    local i
    for ((i = start; i < total; i++)); do
        printf '%s\n' "${matches[$i]}"
    done
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

#!/bin/bash
# beads-quarantine.sh — READ-ONLY reader for .beads/quarantine.tsv (M-2,
# claude-workflow-plugin-j7kk).
#
# DATA PLUMBING, NOT A CHECK. This script asserts nothing, so it incurs no
# pairing obligation under .claude/tests/README.md § "The pairing
# requirement" — stated here explicitly, so a later reader does not mistake
# it for an unpaired check.
#
# WHY A FILE, AND WHY THIS SCRIPT NEVER WRITES ONE. Quarantine marks live in
# .beads/quarantine.tsv — git-tracked, hand-authored, and NEVER written by a
# hook or by this script. Labelling the issue, or appending a note to it,
# were both measured and rejected as the marking mechanism (j7kk
# contamination census, section 2.3): `DESCRIBE labels` has no timestamp
# column, and every one of 1,125 measured label-change events carried an
# empty `new_value`, so a label-based mark would be UNDATEABLE and
# UNATTRIBUTABLE in this store — less auditable than the contamination it
# marks. A note-based mark is worse in a different way: it would land on the
# very stream being quarantined, in the same store, indistinguishable in
# shape from the thousands of entries it annotates. So this script only ever
# READS. Verify that claim in one line, independent of this header:
#   grep -nE '(^|[^a-zA-Z_-])bd (create|update|close|comment|label|dep|import)' \
#       .claude/scripts/beads-quarantine.sh
# must return nothing.
#
# THE PREDICATE COLUMN IS TRUSTED, NOT SANITISED. .beads/quarantine.tsv is
# hand-authored and git-reviewed like any other tracked file in this repo,
# not populated by runtime/agent input — `count` below interpolates its
# `predicate` column directly into a `dolt sql` WHERE-clause fragment. That
# is deliberate given the file's provenance (see its own header), not an
# oversight; do not wire this script to an untrusted or generated manifest
# without revisiting it.
#
# Usage:
#   beads-quarantine.sh list
#   beads-quarantine.sh check <issue-id>     # exit 3 if quarantined, 0 if not
#   beads-quarantine.sh count <issue-id>     # re-derive the LIVE count against
#                                             # the manifest's own predicate;
#                                             # a later count exceeding
#                                             # count_at_measure proves the
#                                             # writer is still armed.
#
# Exit codes:
#   0  ok (list; check/count on a clean id; count when dolt/store are
#      unavailable — informational, matches the honest-degradation
#      convention used elsewhere in this task rather than failing loudly
#      over an environment gap)
#   2  usage error, or the manifest is missing/unreadable
#   3  check: <issue-id> IS quarantined (appears in the manifest)

set -u

# This script lives at .claude/scripts/beads-quarantine.sh, so SELF_DIR is
# .../.claude/scripts — TWO levels up (../..), not one, reaches the project
# root. (Caught by actually running this script against the real manifest:
# the one-level form resolved .../.claude/.beads/quarantine.tsv and reported
# "manifest not found" against a real, present file.)
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || SELF_DIR=""
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$SELF_DIR/../.." 2>/dev/null && pwd)}"
MANIFEST="$PROJECT_DIR/.beads/quarantine.tsv"
STORE="$PROJECT_DIR/.beads/embeddeddolt/beads"

usage() {
    cat >&2 <<'USAGE'
Usage: beads-quarantine.sh <list|check|count> [issue-id]
  list              Print the quarantine manifest (.beads/quarantine.tsv).
  check <issue-id>  Exit 3 if <issue-id> appears in the manifest (any row),
                    0 otherwise. Prints a one-line verdict either way.
  count <issue-id>  Re-run the manifest's OWN predicate for <issue-id>
                    against the LIVE store and print "<id> [<scope>]:
                    manifest N / store M" per matching row. M > N means the
                    writer is still armed; re-quarantine before trusting
                    anything new on that scope as evidence.
USAGE
}

if [ ! -f "$MANIFEST" ]; then
    printf 'beads-quarantine.sh: manifest not found: %s\n' "$MANIFEST" >&2
    exit 2
fi

SUBCMD="${1:-}"
case "$SUBCMD" in
    list)
        cat "$MANIFEST"
        exit 0
        ;;
    check)
        TID="${2:-}"
        if [ -z "$TID" ]; then
            usage
            exit 2
        fi
        if awk -F'\t' -v id="$TID" 'NR>1 && $1==id {found=1} END{exit !found}' "$MANIFEST"; then
            printf 'QUARANTINED: %s appears in %s — read the manifest row before treating its comment stream as evidence (round counts, model pins, artifact-by-hash binding). See CLAUDE.md.\n' \
                "$TID" "$MANIFEST"
            exit 3
        fi
        printf 'clean: %s does not appear in %s\n' "$TID" "$MANIFEST"
        exit 0
        ;;
    count)
        TID="${2:-}"
        if [ -z "$TID" ]; then
            usage
            exit 2
        fi
        ROWS=$(awk -F'\t' -v id="$TID" 'NR>1 && $1==id {print}' "$MANIFEST")
        if [ -z "$ROWS" ]; then
            printf 'not quarantined: %s appears in no row of %s\n' "$TID" "$MANIFEST"
            exit 0
        fi
        if ! command -v dolt >/dev/null 2>&1 || [ ! -d "$STORE/.dolt" ]; then
            printf 'count: dolt unavailable, or %s has no embedded-Dolt store — cannot re-derive live counts. Manifest row(s) for %s:\n' \
                "$STORE" "$TID" >&2
            printf '%s\n' "$ROWS" >&2
            exit 0
        fi
        printf '%s\n' "$ROWS" | while IFS=$'\t' read -r r_id r_scope r_pred r_count _rest; do
            live=""
            case "$r_scope" in
                comments)
                    live=$(cd "$STORE" && dolt sql -r csv -q \
                        "SELECT COUNT(*) FROM comments WHERE issue_id='$r_id' AND $r_pred" 2>/dev/null | tail -n1)
                    ;;
                issue)
                    live=$(cd "$STORE" && dolt sql -r csv -q \
                        "SELECT COUNT(*) FROM issues WHERE $r_pred" 2>/dev/null | tail -n1)
                    ;;
                issue+comments)
                    live_issue=$(cd "$STORE" && dolt sql -r csv -q \
                        "SELECT COUNT(*) FROM issues WHERE $r_pred" 2>/dev/null | tail -n1)
                    live_comments=$(cd "$STORE" && dolt sql -r csv -q \
                        "SELECT COUNT(*) FROM comments WHERE issue_id='$r_id'" 2>/dev/null | tail -n1)
                    live="${live_issue:-?}+${live_comments:-?}"
                    ;;
                *)
                    live="? (unrecognised scope '$r_scope')"
                    ;;
            esac
            printf '%s [%s]: manifest %s / store %s\n' "$r_id" "$r_scope" "$r_count" "${live:-?}"
        done
        exit 0
        ;;
    ""|-h|--help)
        usage
        exit 0
        ;;
    *)
        printf 'beads-quarantine.sh: unknown subcommand: %s\n' "$SUBCMD" >&2
        usage
        exit 2
        ;;
esac

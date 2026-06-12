#!/bin/bash
# rank-targets.sh — rank candidate target scripts by likely-impact.
#
# Two paths:
#   1) code-graph path: if `.claude/.code-graph/index.db` exists AND
#      sqlite3 is on PATH, query it for fan-in (count of edges pointing
#      INTO each target). Higher fan-in -> higher rank.
#   2) coverage / centrality heuristic (fallback): for each candidate,
#      compute a score from (a) the number of L1/L2 test files that
#      reference the candidate by basename, and (b) the candidate's
#      line count. Higher (a) and higher (b) -> higher rank.
#
# Either path produces the same output shape on stdout:
#   <score>\t<absolute-path>
# sorted descending by score. Lines starting with `#` are commentary
# the caller can drop.
#
# Usage:
#   rank-targets.sh <candidate-path>...
#   rank-targets.sh --auto-discover    # rank every *.sh under .claude/scripts/
#
# Per the C.1 spec: the harness MUST run without code-graph. The
# fallback path is the always-available default; the code-graph path
# is a pure upgrade when the index happens to exist. Any code-graph
# failure (DB missing, sqlite3 missing, query error) drops the run
# back to the heuristic with a one-line warning to stderr — never
# aborts the rank.
#
# Exit codes:
#   0  success (stdout carries the ranking)
#   1  invocation error (no candidates given, --auto-discover finds
#      nothing, etc.)

set -u

# Resolve PROJECT_DIR with the same precedence the rest of the plugin
# uses. The scripts directory and the tests directory are derived from
# it so the ranker works in an installed target project, not just the
# plugin's own repo.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../../.." && pwd)}"
SCRIPTS_DIR="$PROJECT_DIR/.claude/scripts"
TESTS_DIRS=(
    "$PROJECT_DIR/.claude/scripts/tests"
    "$PROJECT_DIR/.claude/tests/component/specs"
)
CODE_GRAPH_DB="$PROJECT_DIR/.claude/.code-graph/index.db"

usage() {
    cat >&2 <<'USAGE'
Usage: rank-targets.sh <candidate-path>...
       rank-targets.sh --auto-discover

Stdout: <score>\t<path> per candidate, sorted descending by score.

Ranking path:
  - if .claude/.code-graph/index.db exists AND sqlite3 is on PATH,
    fan-in from the graph is used as the score.
  - otherwise (the default), score = test-reference-count + line-count.

The harness invokes this helper to choose which scripts to mutate
first. Without the code-graph index, the heuristic is the always-on
fallback.
USAGE
}

# --- Code-graph path -----------------------------------------------------

# Try fan-in via sqlite3. Returns the score on stdout or empty on any
# failure (caller treats empty as "fall back to heuristic"). We never
# let a sqlite query bubble a non-zero exit up.
code_graph_score_for() {
    local target="$1"
    if [ ! -f "$CODE_GRAPH_DB" ]; then
        return 1
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        return 1
    fi
    # The index schema is defined by code-graph-mcp/src/lib/db.js; we
    # do not couple to it here. Instead we use a best-effort COUNT(*)
    # against any table whose name suggests "edges" or "calls". Any
    # error or empty result -> caller falls back.
    local tables
    tables=$(sqlite3 "$CODE_GRAPH_DB" \
        "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '%edge%' OR name LIKE '%call%' OR name LIKE '%ref%');" \
        2>/dev/null)
    if [ -z "$tables" ]; then
        return 1
    fi
    local basename
    basename=$(basename "$target")
    local total=0
    local t row
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        # Best-effort: count rows whose target column references the
        # basename. We tolerate column-name drift by trying both
        # `target` and `to` and `callee`.
        for col in target to callee referenced_name; do
            row=$(sqlite3 "$CODE_GRAPH_DB" \
                "SELECT COUNT(*) FROM \"$t\" WHERE \"$col\" LIKE '%$basename%';" \
                2>/dev/null || echo "")
            if [ -n "$row" ] && [ "$row" -gt 0 ] 2>/dev/null; then
                total=$((total + row))
                break
            fi
        done
    done <<< "$tables"
    if [ "$total" -gt 0 ]; then
        printf '%d\n' "$total"
        return 0
    fi
    return 1
}

# --- Heuristic path ------------------------------------------------------

# Test-reference count: how many *.sh files in the known tests dirs
# mention the target's basename. Cheap proxy for "if this breaks, how
# many tests notice".
heuristic_test_refs() {
    local target="$1"
    local basename refs=0 tests_dir
    basename=$(basename "$target")
    for tests_dir in "${TESTS_DIRS[@]}"; do
        [ -d "$tests_dir" ] || continue
        # grep -l counts files, not lines. Trim the count.
        local subdir_refs
        subdir_refs=$(grep -lrF "$basename" "$tests_dir" 2>/dev/null | wc -l | tr -d ' ')
        refs=$((refs + subdir_refs))
    done
    printf '%d\n' "$refs"
}

# Line count contributes to score — bigger scripts have more surface
# area for a mutant to slip through.
heuristic_line_count() {
    local target="$1"
    if [ ! -f "$target" ]; then
        printf '0\n'
        return 0
    fi
    wc -l < "$target" | tr -d ' '
}

heuristic_score_for() {
    local target="$1"
    local refs lines score
    refs=$(heuristic_test_refs "$target")
    lines=$(heuristic_line_count "$target")
    # Weight test references at 100 so a single referenced test
    # dominates the line-count signal. The exact weight is documented
    # in README.md (cost model section).
    score=$((refs * 100 + lines))
    printf '%d\n' "$score"
}

# --- Driver --------------------------------------------------------------

candidates=()
if [ "${1:-}" = "--auto-discover" ]; then
    if [ ! -d "$SCRIPTS_DIR" ]; then
        printf 'rank-targets.sh: scripts dir not found: %s\n' "$SCRIPTS_DIR" >&2
        exit 1
    fi
    while IFS= read -r line; do
        candidates+=("$line")
    done < <(find "$SCRIPTS_DIR" -maxdepth 1 -type f -name '*.sh' | sort)
else
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi
    while [ $# -gt 0 ]; do
        candidates+=("$1")
        shift
    done
fi

if [ ${#candidates[@]} -eq 0 ]; then
    printf 'rank-targets.sh: no candidates\n' >&2
    exit 1
fi

# Decide path once, log it once on stderr so the harness can capture it.
USE_CODE_GRAPH=0
if [ -f "$CODE_GRAPH_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    USE_CODE_GRAPH=1
    printf '# rank-targets: using code-graph path (%s)\n' "$CODE_GRAPH_DB" >&2
else
    if [ ! -f "$CODE_GRAPH_DB" ]; then
        printf '# rank-targets: code-graph index not present; using heuristic fallback\n' >&2
    else
        printf '# rank-targets: sqlite3 not on PATH; using heuristic fallback\n' >&2
    fi
fi

results=()
for c in "${candidates[@]}"; do
    score=""
    if [ "$USE_CODE_GRAPH" = "1" ]; then
        if score=$(code_graph_score_for "$c" 2>/dev/null); then
            :
        else
            # Per-target code-graph failure also falls back to heuristic
            # so we never abort a sweep over a partial index. The
            # ranking path is logged per-target so the README's
            # ranking_fallback_proof claim has evidence at runtime.
            printf '# rank-targets: code-graph miss on %s; heuristic\n' "$c" >&2
            score=$(heuristic_score_for "$c")
        fi
    else
        score=$(heuristic_score_for "$c")
    fi
    results+=("$score	$c")
done

# Sort descending by the first (numeric) column.
printf '%s\n' "${results[@]}" | sort -t '	' -k1,1 -nr

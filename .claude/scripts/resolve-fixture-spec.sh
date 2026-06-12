#!/bin/bash
# resolve-fixture-spec.sh — Map an e2e fixture name to the spec file that
# drives it.
#
# Context — claude-workflow-plugin-366.4 (Phase B):
#   The Makefile's `test-live` target previously derived its vitest filter
#   as `$(FIXTURE).spec.ts`. That assumed 1:1 fixture↔spec naming, but
#   `specs/happy-path.spec.ts` drives the `node-react-auth` fixture, so
#   `make test-live FIXTURE=node-react-auth` (the form the Makefile's own
#   help text advertises) produced "No test files found, exiting with
#   code 1" without ever calling the API.
#
# This helper centralises the mapping in ONE place that:
#   - is shellable from the Makefile (no embedded recipe scripting),
#   - is unit-testable (component spec at
#     .claude/tests/component/specs/resolve-fixture-spec.sh),
#   - emits a friendly error listing available fixtures when the input
#     is unknown — so `make test-live FIXTURE=typo` fails loudly with
#     guidance instead of silently failing the vitest filter.
#
# Resolution strategy:
#   Scan `<plugin-root>/.claude/tests/e2e/specs/*.spec.ts` for a
#   `path.resolve(..., "fixtures", "<FIXTURE>")` reference. Each spec
#   has exactly one such reference (verified against all seven shipped
#   specs as of 2026-06-12). The first match wins; we sort the spec
#   files first so behaviour is deterministic if a future spec
#   accidentally references two fixtures.
#
# Why not maintain a static dispatch table?
#   The static table would drift the moment someone adds a spec/fixture
#   pair, and the Makefile's bug was a static assumption ("name matches")
#   in the first place. Scanning the source-of-truth (the spec's own
#   FIXTURE_PATH constant) means the resolver stays correct without an
#   extra maintenance burden.
#
# Usage:
#   resolve-fixture-spec.sh <fixture-name>           # prints "<spec>.spec.ts"
#   resolve-fixture-spec.sh --list                   # prints available fixtures (one per line)
#
# Exit codes:
#   0  resolved; spec filename on stdout
#   1  unknown fixture (with diagnostic + fixture list on stderr)
#   2  invocation error (no arg, no spec/fixture dirs, etc.)
#
# CLAUDE_PROJECT_DIR is honoured for fixture-from-installed-plugin scenarios;
# absence falls back to deriving plugin root from this script's path.

set -u

# --- Resolve plugin root (script lives at <root>/.claude/scripts/) ---
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SELF_DIR/../.." && pwd)}"
SPECS_DIR="$PLUGIN_ROOT/.claude/tests/e2e/specs"
FIXTURES_DIR="$PLUGIN_ROOT/.claude/tests/e2e/fixtures"

print_usage() {
    cat >&2 <<'EOF'
Usage: resolve-fixture-spec.sh <FIXTURE-NAME>
       resolve-fixture-spec.sh --list

Prints the spec filename (e.g. happy-path.spec.ts) that drives the given
e2e fixture. Used by `make test-live` to derive the vitest filter.

Exit 1 on unknown fixture (lists available fixtures on stderr).
Exit 2 on missing argument or missing specs/fixtures directories.
EOF
}

# Print available fixtures (one per line, sorted). Stdout-only so callers
# can capture; the unknown-fixture path also calls this to seed its error.
list_fixtures() {
    if [ ! -d "$FIXTURES_DIR" ]; then
        printf 'resolve-fixture-spec.sh: fixtures dir missing: %s\n' \
            "$FIXTURES_DIR" >&2
        exit 2
    fi
    # `find -maxdepth 1 -mindepth 1 -type d` excludes the fixtures dir
    # itself; ls sometimes follows symlinks differently across coreutils.
    find "$FIXTURES_DIR" -maxdepth 1 -mindepth 1 -type d -print 2>/dev/null \
        | sed -E 's#^.*/##' | sort
}

if [ $# -lt 1 ]; then
    print_usage
    exit 2
fi

if [ "$1" = "--list" ]; then
    list_fixtures
    exit 0
fi

FIXTURE="$1"

if [ ! -d "$SPECS_DIR" ]; then
    printf 'resolve-fixture-spec.sh: specs dir missing: %s\n' "$SPECS_DIR" >&2
    exit 2
fi

# --- Scan specs for the FIXTURE_PATH reference ---
# We accept either single- or double-quoted string and an arbitrary
# leading argv (path.resolve(__dirname, "..", "fixtures", "<name>")).
# Sort the spec list so behaviour is deterministic across filesystems.
match=""
while IFS= read -r spec_path; do
    # Match: path.resolve(...,"fixtures","<FIXTURE>") with any whitespace
    # / quoting. We grep for the literal fixture name preceded by
    # `"fixtures",` to avoid matching prose mentions in comments.
    if grep -E "[\"']fixtures[\"'][[:space:]]*,[[:space:]]*[\"']${FIXTURE}[\"']" \
        "$spec_path" >/dev/null 2>&1; then
        match=$(basename "$spec_path")
        break
    fi
done < <(find "$SPECS_DIR" -maxdepth 1 -type f -name '*.spec.ts' \
            ! -name '_*' -print 2>/dev/null | sort)

if [ -n "$match" ]; then
    printf '%s\n' "$match"
    exit 0
fi

# --- Unknown fixture: print actionable error to stderr ---
{
    printf 'resolve-fixture-spec.sh: unknown fixture: %s\n' "$FIXTURE"
    printf 'Available fixtures:\n'
    list_fixtures | sed 's/^/  /'
} >&2

exit 1

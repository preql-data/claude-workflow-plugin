#!/bin/bash
# resolve-fixture-spec.sh — L2 component spec for the fixture→spec resolver
# used by `make test-live` (and any future caller that needs the mapping).
#
# Context — claude-workflow-plugin-366.4 (Phase B):
#   The Makefile's old test-live recipe derived the vitest filter as
#   `$(FIXTURE).spec.ts`, but spec files are SCENARIO-named, not
#   fixture-named. Six of seven fixtures have spec names matching their
#   fixture, but `node-react-auth` is driven by `happy-path.spec.ts`.
#   The Makefile's OWN documentation (help text + cost table) advertises
#   FIXTURE=node-react-auth, so the public interface is the fixture name
#   and the recipe MUST resolve it.
#
# This spec exercises the resolver helper (`resolve-fixture-spec.sh`)
# the Makefile shells out to, so the test sees the real artifact rather
# than parsing make's recipe expansion.
#
# Acceptance contract (each maps to one or more assertions below):
#
#   1. node-react-auth resolves to happy-path.spec.ts (the mismatched pair
#      that motivated this bug; if this assertion fails the bug is back).
#   2. rubric-revision-loop resolves 1:1 (still works for the matched pair,
#      so the resolver doesn't introduce a regression for previously-OK
#      fixture names).
#   3. Every other shipped fixture resolves to a spec file that exists.
#      Defended by iterating the fixtures dir and asserting the resolver
#      output is a real file under specs/.
#   4. Unknown fixture name → exit non-zero, error mentions the unknown
#      name AND lists at least one available fixture (so the user can
#      recover without grepping the source).
#   5. Missing FIXTURE arg → exit 2 with a usage line (mirrors the
#      Makefile's --help convention).
#   6. The resolver is idempotent: invoking it twice for the same fixture
#      returns the same answer (catches a regression where caching state
#      bleeds across invocations).
#
# Run via the L2 component runner (.claude/tests/component/run.sh).

set -u

# Note: this spec deliberately does NOT call mk_fixture. The resolver
# under test is a pure read against the plugin's own specs/ and
# fixtures/ trees; a per-spec tempdir would only serve to mis-point
# CLAUDE_PROJECT_DIR and force every assertion to override it. The
# specs+fixtures we exercise are the real artifacts in the repo, which
# is what we want — the bug is in the plugin's own fixture↔spec map.

PLUGIN_ROOT=$(plugin_root)
RESOLVER="$PLUGIN_ROOT/.claude/scripts/resolve-fixture-spec.sh"
SPECS_DIR="$PLUGIN_ROOT/.claude/tests/e2e/specs"
FIXTURES_DIR="$PLUGIN_ROOT/.claude/tests/e2e/fixtures"

# The resolver honours CLAUDE_PROJECT_DIR (for installed-plugin
# scenarios). The runner may have any value in that env var inherited
# from its caller; unsetting it per invocation forces the resolver to
# fall back to its script-relative plugin-root derivation, which is the
# behaviour we want to test here (we're exercising the plugin's own
# fixture↔spec map).
run_resolver() {
    env -u CLAUDE_PROJECT_DIR "$RESOLVER" "$@"
}

# Sanity: the resolver exists and is executable. Failing this assertion
# yields a clear "helper missing" signal rather than every downstream
# assertion blowing up identically.
assert_eq "resolver: script exists" "0" "$([ -f "$RESOLVER" ] && echo 0 || echo 1)"
assert_eq "resolver: script executable" "0" "$([ -x "$RESOLVER" ] && echo 0 || echo 1)"

# === Acceptance 1: node-react-auth → happy-path.spec.ts ===
# The bug-was-here pair. The resolver scans specs for FIXTURE_PATH
# references; node-react-auth is referenced only by happy-path.spec.ts.
node_react_out=$(run_resolver node-react-auth 2>&1) || true
assert_eq "node-react-auth → happy-path.spec.ts" \
    "happy-path.spec.ts" "$node_react_out"

# === Acceptance 2: rubric-revision-loop resolves 1:1 ===
rubric_out=$(run_resolver rubric-revision-loop 2>&1) || true
assert_eq "rubric-revision-loop → rubric-revision-loop.spec.ts" \
    "rubric-revision-loop.spec.ts" "$rubric_out"

# === Acceptance 3: every shipped fixture resolves to a real spec file ===
# Iterate the fixtures dir, resolve each, assert the spec file exists.
# This is the regression-coverage assertion: if someone adds a new
# fixture without a spec (or renames a spec), this catches it.
for fdir in "$FIXTURES_DIR"/*/; do
    fname=$(basename "$fdir")
    out=$(run_resolver "$fname" 2>&1) || out="__RESOLVER_FAILED__"
    assert_eq "every fixture resolves: $fname is a known spec" \
        "0" "$([ -f "$SPECS_DIR/$out" ] && echo 0 || echo 1)"
done

# === Acceptance 4: unknown fixture name → exit non-zero + helpful error ===
unknown_out=$(run_resolver no-such-fixture-xyz 2>&1)
unknown_rc=$?
assert_eq "unknown fixture: non-zero exit" "0" \
    "$([ "$unknown_rc" -ne 0 ] && echo 0 || echo 1)"
assert_contains "unknown fixture: error names the bad input" \
    "no-such-fixture-xyz" "$unknown_out"
# Error must list at least one real fixture so the user can recover.
# We check for 'node-react-auth' specifically (it's always present and
# is the one most likely to be in the user's muscle memory from docs).
assert_contains "unknown fixture: error lists known fixtures" \
    "node-react-auth" "$unknown_out"

# === Acceptance 5: missing FIXTURE arg → exit 2 + usage ===
missing_out=$(run_resolver 2>&1)
missing_rc=$?
assert_eq "missing arg: exit 2" "2" "$missing_rc"
assert_match "missing arg: prints usage" \
    "[Uu]sage|FIXTURE" "$missing_out"

# === Acceptance 6: idempotent ===
first=$(run_resolver node-react-auth 2>&1) || true
second=$(run_resolver node-react-auth 2>&1) || true
assert_eq "idempotent: two invocations return the same value" \
    "$first" "$second"

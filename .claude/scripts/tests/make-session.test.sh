#!/bin/bash
# make-session.test.sh — v4.0.0 Phase V0 (cnz.1), grader iteration-1 required fix.
#
# LESSONS 366.4: any doc/help-advertised CLI surface needs an L2/L1 assertion
# that executes that EXACT invocation (dry-run where the real one costs money).
# The Makefile `session` target is advertised in `make help`, CONTRIBUTING.md,
# and the effort docs, and it launches `claude --effort <verdict>` — a paid,
# interactive session. This test runs the REAL repo Makefile's `session` target
# against a tempdir fixture with a STUB `claude` first on PATH (so nothing paid
# runs) and asserts:
#   (a) the resolved invocation uses the first non-comment line of
#       .claude/effort-verdict, and
#   (b) it defaults to `max` when the verdict file is missing or comment/blank
#       only.
# A META-TEST points the checker at a verdict-ignoring stub and proves the
# assertion then fails (i.e. it is anchored to the argv the stub actually
# received, not to the Makefile's own echo line). TEXT-anchored throughout.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
MAKEFILE="$PROJECT_DIR/Makefile"

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' \
            "$name" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    forbidden needle: %s\n    haystack:         %s\n' \
            "$name" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    fi
}

# Dependencies: we execute the real Makefile via `make`. If make is absent
# (unusual — CI and macOS both ship it), skip cleanly rather than fail.
if ! command -v make >/dev/null 2>&1; then
    printf 'make not on PATH; skipping\n' >&2
    exit 0
fi
if [ ! -f "$MAKEFILE" ]; then
    printf 'Makefile not found at %s; skipping\n' "$MAKEFILE" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Fixture: a tempdir cwd holding .claude/effort-verdict + a stub `claude`
# first on PATH. The stub echoes its argv with a distinctive marker so we can
# prove `exec claude --effort <v>` actually ran with the resolved value (the
# Makefile's own "launching 'claude --effort <v>'" echo line does NOT carry the
# marker, so assertions on the marker are not satisfied by the echo alone).
# ---------------------------------------------------------------------------

FIXTURE=$(mktemp -d -t make-session.XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/.claude" "$FIXTURE/bin"

cat > "$FIXTURE/bin/claude" <<'STUB'
#!/bin/bash
# Stub claude: echo the argv it received; never launch anything.
echo "CLAUDE_INVOKED $*"
exit 0
STUB
chmod +x "$FIXTURE/bin/claude"

# Run the EXACT advertised target (`make session`) of the REAL repo Makefile,
# with cwd = the fixture (so it reads the fixture's effort-verdict) and the
# stub claude first on PATH. -C sets the working directory; -f names the real
# Makefile by absolute path so no copy drifts from the shipped target.
run_session() {
    local fx="$1"
    PATH="$fx/bin:$PATH" make -C "$fx" -f "$MAKEFILE" session 2>&1 || true
}

# ---------------------------------------------------------------------------
# Case (a): the verdict's first non-comment line drives --effort.
# ---------------------------------------------------------------------------

printf '# effort-verdict fixture\nultracode\n# PROVISIONAL trailer\n' > "$FIXTURE/.claude/effort-verdict"
OUT_ULTRA=$(run_session "$FIXTURE")
assert_contains "make session: verdict 'ultracode' -> claude launched with --effort ultracode" \
    "CLAUDE_INVOKED --effort ultracode" "$OUT_ULTRA"

printf 'max\n' > "$FIXTURE/.claude/effort-verdict"
OUT_MAX=$(run_session "$FIXTURE")
assert_contains "make session: verdict 'max' -> claude launched with --effort max" \
    "CLAUDE_INVOKED --effort max" "$OUT_MAX"

# ---------------------------------------------------------------------------
# Case (b): default-to-max fallback when the verdict is missing or unusable.
# ---------------------------------------------------------------------------

rm -f "$FIXTURE/.claude/effort-verdict"
OUT_MISSING=$(run_session "$FIXTURE")
assert_contains "make session: missing verdict file -> defaults to --effort max" \
    "CLAUDE_INVOKED --effort max" "$OUT_MISSING"

printf '# only comments here\n\n   \n# and blank lines\n' > "$FIXTURE/.claude/effort-verdict"
OUT_BLANK=$(run_session "$FIXTURE")
assert_contains "make session: comment/blank-only verdict -> defaults to --effort max" \
    "CLAUDE_INVOKED --effort max" "$OUT_BLANK"

# ---------------------------------------------------------------------------
# META-TEST: point the checker at a verdict-IGNORING stub (always reports a
# fixed effort). With verdict='ultracode', the positive assertion for
# `CLAUDE_INVOKED --effort ultracode` MUST now fail — proving the assertion is
# anchored to the argv the stub actually received, not to the Makefile's echo.
# ---------------------------------------------------------------------------

cat > "$FIXTURE/bin/claude" <<'STUB'
#!/bin/bash
# Buggy stub: ignores whatever --effort it was handed, always reports max.
echo "CLAUDE_INVOKED --effort max"
exit 0
STUB
chmod +x "$FIXTURE/bin/claude"

printf 'ultracode\n' > "$FIXTURE/.claude/effort-verdict"
OUT_META=$(run_session "$FIXTURE")
assert_not_contains "META-TEST: verdict-ignoring stub -> the ultracode invocation assertion fails" \
    "CLAUDE_INVOKED --effort ultracode" "$OUT_META"
# Sanity: the buggy stub DID run (fixed marker present), so the miss above is a
# real sensitivity signal, not the stub failing to execute.
assert_contains "META-TEST: buggy stub actually executed (fixed marker present)" \
    "CLAUDE_INVOKED --effort max" "$OUT_META"

# Closure: restore the faithful stub; the ultracode assertion holds again.
cat > "$FIXTURE/bin/claude" <<'STUB'
#!/bin/bash
echo "CLAUDE_INVOKED $*"
exit 0
STUB
chmod +x "$FIXTURE/bin/claude"
OUT_CLOSE=$(run_session "$FIXTURE")
assert_contains "META-TEST closure: faithful stub re-emits the ultracode invocation" \
    "CLAUDE_INVOKED --effort ultracode" "$OUT_CLOSE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

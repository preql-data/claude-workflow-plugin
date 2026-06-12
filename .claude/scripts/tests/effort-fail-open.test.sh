#!/bin/bash
# effort-fail-open.test.sh — hotfix vlp.2.
#
# Covers the spec's fail-open + one-line-notice path for the persistable
# effort default. The settings.json carries effortLevel: "xhigh" and
# env.CLAUDE_CODE_EFFORT_LEVEL: "max". Per docs/en/model-config the
# levels actually supported by the resolved model vary; vlp.2's contract
# is that when the runtime can't honor the configured level, the helper:
#   (a) surfaces a single LOUD warning naming the applied level, and
#   (b) leaves the existing effort knob alone (no silent downgrade).
#
# Section 1: positive coverage. settings.json + the effort-level surfacing
# in session-start.sh produces a single "effort: applied <level>" line in
# the warnings envelope.
#
# Section 2: META-TEST. Stub session-start.sh's settings read to point at
# an UNSUPPORTED-model fixture (claude-sonnet-4-5; docs table omits
# effort entirely for this generation), assert the helper still emits
# the level + opt-in hint (it cannot prevent the runtime mismatch — the
# warning is the user-visible fail-open signal so the operator sees the
# disparity).
#
# Section 3: sensitivity META-TEST. Replace the surfacing block with a
# stripped variant that does NOT emit the line; assert section 1's
# expectation fails — proving the assertion is sensitive to the code
# under test, not vacuous.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SESSION_START="$PROJECT_DIR/.claude/scripts/session-start.sh"
SETTINGS_REAL="$PROJECT_DIR/.claude/settings.json"

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

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

# ---------------------------------------------------------------------------
# Section 0: settings.json baseline check (vlp.2 deliberate write).
# Confirms the file actually carries the values the rest of the test
# assumes. This is the trivial "the change landed" check.
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
    printf 'jq not on PATH; skipping\n' >&2
    exit 0
fi

EL_VAL=$(jq -r '.effortLevel // "<missing>"' "$SETTINGS_REAL" 2>/dev/null)
EL_ENV=$(jq -r '.env.CLAUDE_CODE_EFFORT_LEVEL // "<missing>"' "$SETTINGS_REAL" 2>/dev/null)

assert_eq "settings.effortLevel == xhigh (vlp.2 deliberate write)" "xhigh" "$EL_VAL"
assert_eq "settings.env.CLAUDE_CODE_EFFORT_LEVEL == max (vlp.2 deliberate write)" "max" "$EL_ENV"

# ---------------------------------------------------------------------------
# Section 1: positive — session-start.sh surfaces the applied effort
# level and the ultracode opt-in hint.
# ---------------------------------------------------------------------------

# Build a tempdir fixture that mimics the project layout enough for
# session-start.sh to run. We pass a fake bd via PATH that responds to
# the few commands the script invokes.
FIXTURE=$(mktemp -d -t effort-fail-open.XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.claude/skills/workflow-engine" "$FIXTURE/.beads" "$FIXTURE/bin"

# Copy the real session-start.sh so the test runs the real surface, not
# a symlink (we want the test isolated from the project's settings).
cp "$SESSION_START" "$FIXTURE/.claude/scripts/session-start.sh"
chmod +x "$FIXTURE/.claude/scripts/session-start.sh"

# Settings.json mirror of vlp.2 baseline.
cat > "$FIXTURE/.claude/settings.json" <<'SETTINGS'
{
  "additionalDirectories": ["../"],
  "effortLevel": "xhigh",
  "env": {
    "MAX_THINKING_TOKENS": "64000",
    "CLAUDE_CODE_EFFORT_LEVEL": "max",
    "CLAUDE_LATEST_OPUS": "claude-opus-4-7"
  }
}
SETTINGS

# Minimal SKILL.md so the workflow-engine block doesn't bail.
cat > "$FIXTURE/.claude/skills/workflow-engine/SKILL.md" <<'SKILL'
---
name: workflow-engine
description: stub
---

stub body
SKILL

# Empty CLAUDE.md so the project_memory section is a no-op.
: > "$FIXTURE/CLAUDE.md"

# Fake bd: stubs out every subcommand session-start.sh invokes. We use
# a small case dispatcher: --version returns a high enough version,
# prime returns a short context, every other command emits empty.
cat > "$FIXTURE/bin/bd" <<'BDSHIM'
#!/bin/bash
case "$1" in
    --version) echo "bd v1.0.0" ;;
    doctor)    exit 0 ;;
    prime)     echo "<beads_prime_stub>" ;;
    blocked)   shift; if [ "${1:-}" = "--json" ]; then echo "[]"; else echo ""; fi ;;
    list)      echo "[]" ;;
    *)         echo "" ;;
esac
exit 0
BDSHIM
chmod +x "$FIXTURE/bin/bd"

export CLAUDE_PROJECT_DIR="$FIXTURE"
export PATH="$FIXTURE/bin:$PATH"

# Run session-start.sh with empty stdin. We do not need its JSON
# envelope to be VALID for downstream consumers; we just need its
# additionalContext payload to contain the effort line.
OUT=$(echo '{}' | bash "$FIXTURE/.claude/scripts/session-start.sh" 2>&1 || true)

assert_contains "vlp.2: effort line names the applied level (max)" \
    "effort: applied 'max'" "$OUT"
assert_contains "vlp.2: effort line names the ultracode runtime opt-in" \
    "/effort ultracode" "$OUT"
assert_contains "vlp.2: effort line documents cannot-persist constraint" \
    "cannot be persisted" "$OUT"

# ---------------------------------------------------------------------------
# Section 2: fail-open under unsupported-model fixture. Stub the
# settings.json to declare a model the docs explicitly do NOT support
# effort levels for (sonnet-4-5 / haiku — docs table omits them). The
# surfacing helper has no model-aware downgrade today; the warning
# remains the operator-visible signal and the effort knob is preserved.
# ---------------------------------------------------------------------------

# Same fixture; tweak the settings to point at an unsupported model
# alias so the operator sees the level + the hint regardless of model
# support. The docs table tells us claude-sonnet-4-5 / claude-haiku
# generations have NO effort knob; we mirror that as an env override.
cat > "$FIXTURE/.claude/settings.json" <<'SETTINGS'
{
  "additionalDirectories": ["../"],
  "effortLevel": "xhigh",
  "env": {
    "CLAUDE_CODE_EFFORT_LEVEL": "max",
    "CLAUDE_LATEST_OPUS": "claude-sonnet-4-5"
  }
}
SETTINGS

OUT_FAILOPEN=$(echo '{}' | bash "$FIXTURE/.claude/scripts/session-start.sh" 2>&1 || true)

# The warning MUST still fire — the surfacing path is independent of the
# resolved model. Sensitivity: the operator sees the line whether the
# model supports max or not, so they can spot the mismatch themselves.
assert_contains "vlp.2 (fail-open): effort line still emitted under unsupported-model fixture" \
    "effort: applied 'max'" "$OUT_FAILOPEN"
assert_contains "vlp.2 (fail-open): ultracode opt-in still surfaced" \
    "/effort ultracode" "$OUT_FAILOPEN"

# ---------------------------------------------------------------------------
# Section 3: META-TEST — strip the effort block from session-start.sh,
# rerun, assert the assertion in section 1 would have failed. Proves
# section 1 is sensitive to the surfacing block, not vacuous.
# ---------------------------------------------------------------------------

# Build a stripped copy of session-start.sh whose effort surfacing block
# is removed. The block starts at "# Warning 4: hotfix vlp.2" and ends
# at "fi" before the bd_prime section. We use awk to skip lines between
# those markers.
STRIPPED="$FIXTURE/.claude/scripts/session-start-stripped.sh"
awk '
    /^# Warning 4: hotfix vlp.2/ { inblock=1; next }
    inblock && /^# 1\. Get bd prime output/ { inblock=0 }
    !inblock { print }
' "$FIXTURE/.claude/scripts/session-start.sh" > "$STRIPPED"
chmod +x "$STRIPPED"

# Restore the supported settings so the only difference is the script.
cat > "$FIXTURE/.claude/settings.json" <<'SETTINGS'
{
  "additionalDirectories": ["../"],
  "effortLevel": "xhigh",
  "env": {
    "MAX_THINKING_TOKENS": "64000",
    "CLAUDE_CODE_EFFORT_LEVEL": "max",
    "CLAUDE_LATEST_OPUS": "claude-opus-4-7"
  }
}
SETTINGS

OUT_STRIPPED=$(echo '{}' | bash "$STRIPPED" 2>&1 || true)

# META-TEST: the stripped script MUST NOT emit the effort line; if it
# does (e.g. someone moved the surfacing logic out of the block markers
# without updating this test), this assertion fails and the META-TEST
# correctly flags the gap.
assert_not_contains "META-TEST: stripped session-start.sh omits effort line (assertion is sensitive to the block)" \
    "effort: applied" "$OUT_STRIPPED"

# Closure: section 1's primary contract MUST hold against the unstripped
# script. Re-run as a regression check.
OUT_FINAL=$(echo '{}' | bash "$FIXTURE/.claude/scripts/session-start.sh" 2>&1 || true)
assert_contains "META-TEST closure: unstripped session-start still emits effort line" \
    "effort: applied 'max'" "$OUT_FINAL"

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

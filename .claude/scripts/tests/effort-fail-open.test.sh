#!/bin/bash
# effort-fail-open.test.sh — v4.0.0 Phase V0 (cnz.1), inverted from vlp.2.
#
# v4 REMOVED the persistable env pin env.CLAUDE_CODE_EFFORT_LEVEL: the live
# docs are explicit that any non-xhigh value there deactivates ultracode's
# workflow orchestration. The durable FLOOR is now effortLevel: "xhigh"
# alone; the live SESSION level is chosen at launch (`make session` ->
# `claude --effort <verdict>`), where <verdict> is the first non-comment line
# of .claude/effort-verdict (the A/B interference-test output). session-start.sh
# Warning 4 reconciles floor vs live vs verdict; Warning 5 guards the
# v2.1.219 nested-subagent-spawn platform knobs.
#
# Sections:
#   0. settings.json baseline — effortLevel==xhigh AND env.CLAUDE_CODE_EFFORT_LEVEL ABSENT.
#   1. positive — v4 fixture (no env pin, no verdict file): the effort line
#      names the effortLevel floor + "A/B verdict not recorded" + `make session`,
#      and the legacy-pin warning is ABSENT.
#   1b. verdict present (max) + injected CLAUDE_EFFORT=medium -> mismatch warning.
#   1c. legacy env pin present -> the 4a "settings still pin ..." warning fires.
#   2. META-TEST — strip the Warning 4/5 block from session-start.sh, assert the
#      effort line disappears (proves section 1 is sensitive to the block, not
#      vacuous). Anchored to TEXT patterns, never line numbers.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SESSION_START="$PROJECT_DIR/.claude/scripts/session-start.sh"
SETTINGS_REAL="$PROJECT_DIR/.claude/settings.json"

# Determinism: this session's own hook env may carry CLAUDE_EFFORT (the live
# effort of the harness's session). Drop it so the "floor / verdict" branches
# are not polluted by an ambient live value; sections that need it inject it
# explicitly per-invocation.
unset CLAUDE_EFFORT 2>/dev/null || true

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
# Section 0: settings.json baseline check (V0 deliberate write).
# The FLOOR is effortLevel=xhigh; the legacy env pin must be GONE.
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
    printf 'jq not on PATH; skipping\n' >&2
    exit 0
fi

EL_VAL=$(jq -r '.effortLevel // "<missing>"' "$SETTINGS_REAL" 2>/dev/null)
EL_ENV=$(jq -r '.env.CLAUDE_CODE_EFFORT_LEVEL // "<missing>"' "$SETTINGS_REAL" 2>/dev/null)

assert_eq "settings.effortLevel == xhigh (V0 floor)" "xhigh" "$EL_VAL"
assert_eq "settings.env.CLAUDE_CODE_EFFORT_LEVEL is ABSENT (V0 removed the pin)" \
    "<missing>" "$EL_ENV"

# ---------------------------------------------------------------------------
# Shared fixture: a tempdir project layout enough for session-start.sh to run,
# with a fake bd on PATH that answers the few commands the script invokes.
# ---------------------------------------------------------------------------

FIXTURE=$(mktemp -d -t effort-fail-open.XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.claude/skills/workflow-engine" "$FIXTURE/.beads" "$FIXTURE/bin"

cp "$SESSION_START" "$FIXTURE/.claude/scripts/session-start.sh"
chmod +x "$FIXTURE/.claude/scripts/session-start.sh"

# v4 settings.json mirror: effortLevel floor, NO env.CLAUDE_CODE_EFFORT_LEVEL.
cat > "$FIXTURE/.claude/settings.json" <<'SETTINGS'
{
  "additionalDirectories": ["../"],
  "effortLevel": "xhigh",
  "env": {
    "MAX_THINKING_TOKENS": "64000",
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1",
    "CLAUDE_LATEST_OPUS": "claude-opus-4-8"
  }
}
SETTINGS

cat > "$FIXTURE/.claude/skills/workflow-engine/SKILL.md" <<'SKILL'
---
name: workflow-engine
description: stub
---

stub body
SKILL

: > "$FIXTURE/CLAUDE.md"

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

# Run session-start.sh with empty stdin. We do not need its JSON envelope to
# be valid for downstream consumers; we just need the additionalContext to
# carry (or omit) the effort line.
run_ss() { echo '{}' | bash "$FIXTURE/.claude/scripts/session-start.sh" 2>&1 || true; }

# ---------------------------------------------------------------------------
# Section 1: positive — no verdict file, no legacy env. The effort line names
# the effortLevel floor, says the verdict isn't recorded yet, and points at
# `make session`. The legacy-pin warning must NOT appear.
# ---------------------------------------------------------------------------

rm -f "$FIXTURE/.claude/effort-verdict"
OUT=$(run_ss)

assert_contains "V0: effort line names the effortLevel floor (xhigh)" \
    "floor is effortLevel='xhigh'" "$OUT"
assert_contains "V0: effort line says the A/B verdict is not recorded yet" \
    "A/B verdict not recorded yet" "$OUT"
assert_contains "V0: effort line points at the make session launch path" \
    "make session" "$OUT"
assert_contains "V0: effort line references the runbook" \
    "docs/EFFORT-AB-TEST.md" "$OUT"
assert_not_contains "V0: no legacy-pin warning when env key is absent" \
    "settings still pin env.CLAUDE_CODE_EFFORT_LEVEL" "$OUT"

# ---------------------------------------------------------------------------
# Section 1b: verdict present (max) + injected CLAUDE_EFFORT=medium. Warning 4
# must flag the mismatch and name the corrective launch command.
# ---------------------------------------------------------------------------

cat > "$FIXTURE/.claude/effort-verdict" <<'VERDICT'
# effort-verdict test fixture
max
# PROVISIONAL until docs/EFFORT-AB-TEST.md is executed (cnz.2)
VERDICT

OUT_MISMATCH=$(echo '{}' | CLAUDE_EFFORT=medium bash "$FIXTURE/.claude/scripts/session-start.sh" 2>&1 || true)

assert_contains "V0: verdict mismatch names live vs verdict" \
    "live session effort='medium' != A/B verdict 'max'" "$OUT_MISMATCH"
assert_contains "V0: verdict mismatch names the corrective launch command" \
    "claude --effort max" "$OUT_MISMATCH"

# Same verdict, live effort MATCHES (max==max): no mismatch warning.
OUT_MATCH=$(echo '{}' | CLAUDE_EFFORT=max bash "$FIXTURE/.claude/scripts/session-start.sh" 2>&1 || true)
assert_not_contains "V0: no mismatch warning when live == verdict" \
    "!= A/B verdict" "$OUT_MATCH"

# ---------------------------------------------------------------------------
# Section 1c: legacy env pin present -> the 4a warning fires (migration nudge).
# ---------------------------------------------------------------------------

cat > "$FIXTURE/.claude/settings.json" <<'SETTINGS'
{
  "additionalDirectories": ["../"],
  "effortLevel": "xhigh",
  "env": {
    "CLAUDE_CODE_EFFORT_LEVEL": "max",
    "CLAUDE_LATEST_OPUS": "claude-opus-4-8"
  }
}
SETTINGS
rm -f "$FIXTURE/.claude/effort-verdict"

OUT_LEGACY=$(run_ss)
assert_contains "V0: legacy env pin trips the 4a migration warning" \
    "settings still pin env.CLAUDE_CODE_EFFORT_LEVEL='max'" "$OUT_LEGACY"
assert_contains "V0: legacy warning names the install.sh Update remediation" \
    "install.sh in Update mode" "$OUT_LEGACY"

# Restore the v4 (no-legacy) settings for the META section.
cat > "$FIXTURE/.claude/settings.json" <<'SETTINGS'
{
  "additionalDirectories": ["../"],
  "effortLevel": "xhigh",
  "env": {
    "MAX_THINKING_TOKENS": "64000",
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1",
    "CLAUDE_LATEST_OPUS": "claude-opus-4-8"
  }
}
SETTINGS

# ---------------------------------------------------------------------------
# Section 2: META-TEST — strip the Warning 4/5 block from session-start.sh,
# rerun, assert the effort line is gone. Proves section 1's assertion is
# sensitive to the surfacing block. The strip is anchored to the block's
# header TEXT ("# Warning 4:") and the first line after the block
# ("# 1. Get bd prime output") — never to line numbers (LESSONS: line
# anchors go stale).
# ---------------------------------------------------------------------------

STRIPPED="$FIXTURE/.claude/scripts/session-start-stripped.sh"
awk '
    /^# Warning 4:/ { inblock=1; next }
    inblock && /^# 1\. Get bd prime output/ { inblock=0 }
    !inblock { print }
' "$FIXTURE/.claude/scripts/session-start.sh" > "$STRIPPED"
chmod +x "$STRIPPED"

rm -f "$FIXTURE/.claude/effort-verdict"
OUT_STRIPPED=$(echo '{}' | bash "$STRIPPED" 2>&1 || true)

# The stripped script MUST NOT emit the effort line. "A/B verdict" is a phrase
# unique to Warning 4; if it survives the strip, the block markers drifted
# from the surfacing logic and this META-TEST correctly flags the gap.
assert_not_contains "META-TEST: stripped session-start.sh omits the effort line" \
    "A/B verdict" "$OUT_STRIPPED"

# Closure: the unstripped script still emits the effort line (regression check).
OUT_FINAL=$(run_ss)
assert_contains "META-TEST closure: unstripped session-start still emits the effort line" \
    "A/B verdict not recorded yet" "$OUT_FINAL"

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

#!/bin/bash
# agents-manifest-parity.test.sh — spec 0.5 (claude-workflow-plugin-l1r.5).
#
# Asserts bidirectional parity between the agents directory and the
# plugin manifest:
#
#   (a) every "*.md" under .claude/agents/ is registered in
#       .claude-plugin/plugin.json's "agents" array; and
#   (b) every entry in that array resolves to a file on disk.
#
# Motivation: in v3.2.0 / Phase A.2, grader.md was added to the agents
# directory but never registered in plugin.json. The SDK silently
# treats unregistered files as invisible — no error surfaces. The live
# rubric-revision-loop fixture ran for 20 minutes without ever
# spawning a grader subagent and QA never noticed. This test encodes
# that root cause as an offline assertion so the regression cannot
# reach live again.
#
# Includes a META-TEST with two fixtures:
#   1. an agents dir containing an unregistered "*.md" -> checker fails
#   2. a manifest listing a non-existent agent path        -> checker fails
# Each fixture proves the assertion is sensitive in one direction; the
# pair together proves the bidirectional property.
#
# Exit codes:
#   0 — real repo parity holds AND both META-TEST fixtures correctly
#       trip the checker
#   1 — one or more assertions failed
#   2 — invocation error (no jq, missing files)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
AGENTS_DIR="$PROJECT_DIR/.claude/agents"
MANIFEST="$PROJECT_DIR/.claude-plugin/plugin.json"

if ! command -v jq >/dev/null 2>&1; then
    printf 'agents-manifest-parity: jq is required but not on PATH\n' >&2
    exit 2
fi

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

# check_parity <agents_dir> <manifest_path>
#   Returns 0 if every .md in <agents_dir> is registered in <manifest_path>'s
#   "agents" array AND every entry in that array resolves to a file on disk.
#   Returns 1 if either direction has a mismatch. Returns 2 on invocation
#   error (missing manifest, malformed JSON).
#
#   Manifest entries may be relative paths (e.g. "./.claude/agents/qa.md"),
#   so we resolve them against the manifest's repo root — defined as the
#   parent of the directory holding the manifest (i.e. .claude-plugin/.. =
#   the project dir). This matches how the SDK loads plugins.
check_parity() {
    local agents_dir="$1" manifest="$2"

    if [ ! -d "$agents_dir" ]; then
        printf '    (check_parity) agents dir not found: %s\n' "$agents_dir" >&2
        return 2
    fi
    if [ ! -f "$manifest" ]; then
        printf '    (check_parity) manifest not found: %s\n' "$manifest" >&2
        return 2
    fi

    # The manifest lives at <root>/.claude-plugin/plugin.json; the entries
    # are relative to <root>.
    local manifest_dir manifest_root
    manifest_dir=$(cd "$(dirname "$manifest")" && pwd)
    manifest_root=$(dirname "$manifest_dir")

    # Pull the agents array as newline-separated paths. jq -r '.agents[]'
    # exits non-zero if .agents is missing or not an array, which we treat
    # as a parity failure (the SDK would reject the manifest too).
    local entries
    if ! entries=$(jq -r '.agents[]' "$manifest" 2>/dev/null); then
        printf '    (check_parity) manifest .agents is missing or not an array\n' >&2
        return 1
    fi

    # Build the on-disk set: every *.md under agents_dir, as relative paths
    # from manifest_root (so they line up with the manifest's "./..." form).
    # Use find + sort for deterministic ordering; macOS bash 3.2 friendly.
    local disk_paths
    disk_paths=$(cd "$manifest_root" && find ".claude/agents" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

    # Normalize manifest entries to the same form. Strip a leading "./"
    # so "./.claude/agents/foo.md" and ".claude/agents/foo.md" compare
    # equal. Then sort.
    local manifest_paths
    manifest_paths=$(printf '%s\n' "$entries" | sed 's|^\./||' | sort)

    local rc=0

    # Direction 1: every disk file must be in the manifest.
    local p
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        if ! printf '%s\n' "$manifest_paths" | grep -qxF "$p"; then
            printf '    (check_parity) on disk but NOT in manifest: %s\n' "$p" >&2
            rc=1
        fi
    done <<< "$disk_paths"

    # Direction 2: every manifest entry must exist on disk (resolve against
    # manifest_root so the same relative form lines up).
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        local stripped
        stripped=$(printf '%s' "$p" | sed 's|^\./||')
        if [ ! -f "$manifest_root/$stripped" ]; then
            printf '    (check_parity) in manifest but NOT on disk: %s\n' "$p" >&2
            rc=1
        fi
    done <<< "$entries"

    return "$rc"
}

# --- Real repo ----------------------------------------------------------

if check_parity "$AGENTS_DIR" "$MANIFEST"; then
    rc=0
else
    rc=$?
fi
assert_eq "agents-manifest-parity: real repo holds parity" "0" "$rc"

# --- META-TEST 1: unregistered file on disk -----------------------------
#
# Build a tempdir that mirrors the on-disk layout (agents/ + .claude-plugin/),
# copy one real agent so the manifest entry resolves, AND drop a stray
# .md in the agents dir that the manifest does not mention. Expect rc=1.

FIX1_TMP=$(mktemp -d -t agents-manifest-parity-fix1.XXXXXX)
mkdir -p "$FIX1_TMP/.claude/agents" "$FIX1_TMP/.claude-plugin"

# Use a stub file so we don't depend on a specific agent's contents.
cat > "$FIX1_TMP/.claude/agents/registered.md" <<'MD'
---
name: registered
description: stub registered agent
tools: Read
---
stub
MD

# The unregistered file — the regression we're guarding against.
cat > "$FIX1_TMP/.claude/agents/unregistered.md" <<'MD'
---
name: unregistered
description: stub unregistered agent (META-TEST trigger)
tools: Read
---
stub
MD

cat > "$FIX1_TMP/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "fix1",
  "version": "0.0.0",
  "agents": [
    "./.claude/agents/registered.md"
  ]
}
JSON

if check_parity "$FIX1_TMP/.claude/agents" "$FIX1_TMP/.claude-plugin/plugin.json"; then
    rc_meta1=0
else
    rc_meta1=$?
fi
assert_eq "META-TEST 1: unregistered file on disk trips the checker" "1" "$rc_meta1"

rm -rf "$FIX1_TMP"

# --- META-TEST 2: manifest entry without a file on disk -----------------

FIX2_TMP=$(mktemp -d -t agents-manifest-parity-fix2.XXXXXX)
mkdir -p "$FIX2_TMP/.claude/agents" "$FIX2_TMP/.claude-plugin"

cat > "$FIX2_TMP/.claude/agents/real.md" <<'MD'
---
name: real
description: stub real agent
tools: Read
---
stub
MD

# Manifest claims a ghost agent that does not exist on disk.
cat > "$FIX2_TMP/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "fix2",
  "version": "0.0.0",
  "agents": [
    "./.claude/agents/real.md",
    "./.claude/agents/ghost.md"
  ]
}
JSON

if check_parity "$FIX2_TMP/.claude/agents" "$FIX2_TMP/.claude-plugin/plugin.json"; then
    rc_meta2=0
else
    rc_meta2=$?
fi
assert_eq "META-TEST 2: manifest entry without a file trips the checker" "1" "$rc_meta2"

rm -rf "$FIX2_TMP"

# --- Summary ------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

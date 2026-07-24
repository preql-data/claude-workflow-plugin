#!/bin/bash
# platform-audit.test.sh — v4.0.0 Phase V0 (cnz.1).
#
# Static audit of the plugin surface against the platform facts V0 pins down.
# Every check runs against the REAL repo files (no live run, no network). The
# checker LOGIC is factored into functions so the two META sections can point
# the same checker at a crafted fixture and prove it fires — a green check is
# otherwise consistent with "the repo is fine" OR "the checker is vacuous".
#
# Checks (SPEC cnz.1 item 4):
#   (a) settings.json env: NO CLAUDE_CODE_EFFORT_LEVEL, NO CLAUDE_CODE_SUBAGENT_MODEL,
#       HAS CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=="1", and no `disableWorkflows` key.
#   (b) no .claude/agents/*.md frontmatter carries a `hooks:` key (v2.1.214:
#       agent-frontmatter hooks need folder trust; the plugin defines none).
#   (c) no deprecated Task-call `mode:` param (v2.1.212) in agents / commands /
#       the workflow-engine SKILL. permissionMode and prose "plan mode" excluded.
#   (d) .mcp.json + .claude-plugin/plugin.json parse; both bd + code-graph
#       entries are "type":"stdio"; .mcp.json uses the literal ${CLAUDE_PROJECT_DIR:-.}.
#   (e) every agent frontmatter `effort:` == max (the durable ceiling).
#   (f) settings.json and hooks.json agree on the SubagentStart entry.
#
# META:
#   - (a) a tempdir settings.json WITH the effort env key must trip checker (a).
#   - (b) a tempdir agent file WITH `hooks:` frontmatter must trip checker (b).

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SETTINGS="$PROJECT_DIR/.claude/settings.json"
HOOKS_JSON="$PROJECT_DIR/.claude/hooks/hooks.json"
MCP_JSON="$PROJECT_DIR/.mcp.json"
PLUGIN_JSON="$PROJECT_DIR/.claude-plugin/plugin.json"
SKILL="$PROJECT_DIR/.claude/skills/workflow-engine/SKILL.md"

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' "$name" "$needle" "$haystack"
    fi
}

if ! command -v jq >/dev/null 2>&1; then
    printf 'jq not on PATH; skipping\n' >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Checker functions (single source of truth for real assertions + META).
# ---------------------------------------------------------------------------

# Echo space-separated violation codes for a settings.json env audit; empty
# output == clean. READ_ERROR if the file can't be parsed.
audit_settings_env() {
    local f="$1"
    local out=""
    if ! jq -e . "$f" >/dev/null 2>&1; then
        printf 'READ_ERROR'; return 0
    fi
    jq -e '.env | has("CLAUDE_CODE_EFFORT_LEVEL")' "$f" >/dev/null 2>&1 && out="$out HAS_EFFORT_ENV"
    jq -e '.env | has("CLAUDE_CODE_SUBAGENT_MODEL")' "$f" >/dev/null 2>&1 && out="$out HAS_SUBAGENT_MODEL"
    local depth
    depth=$(jq -r '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH // "<missing>"' "$f" 2>/dev/null)
    [ "$depth" = "1" ] || out="$out DEPTH_NOT_1"
    jq -e 'has("disableWorkflows")' "$f" >/dev/null 2>&1 && out="$out HAS_DISABLE_WORKFLOWS"
    # Trim leading space.
    printf '%s' "${out# }"
}

# Echo "yes" if a markdown file's FIRST YAML frontmatter block carries a
# top-level `hooks:` key, else "no".
frontmatter_has_hooks() {
    local f="$1"
    local fm
    fm=$(awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n>=2) exit; next} n==1{print}' "$f" 2>/dev/null)
    if printf '%s\n' "$fm" | grep -qE '^hooks:'; then printf 'yes'; else printf 'no'; fi
}

# Echo the frontmatter `effort:` value (trimmed), or "<missing>".
frontmatter_effort() {
    local f="$1"
    local fm line
    fm=$(awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n>=2) exit; next} n==1{print}' "$f" 2>/dev/null)
    line=$(printf '%s\n' "$fm" | grep -E '^effort:' | head -1)
    if [ -z "$line" ]; then printf '<missing>'; return 0; fi
    printf '%s' "$line" | sed -e 's/^effort:[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Echo "file:line" for every deprecated Task-call `mode` param across the
# given files; empty == clean. Case-sensitive on purpose: `permissionMode`
# (capital M) and prose "... mode" are NOT matched; a real `mode=`/`mode:`
# argument line (the house multi-line Task() style) IS.
scan_mode_params() {
    local f
    for f in "$@"; do
        [ -f "$f" ] || continue
        grep -nE '^[[:space:]]*mode[[:space:]]*[=:]' "$f" 2>/dev/null | sed "s#^#$f:#"
    done
}

# ---------------------------------------------------------------------------
# (a) settings.json env audit — real repo must be clean.
# ---------------------------------------------------------------------------

echo "--- (a) settings.json env ---"
A_OUT=$(audit_settings_env "$SETTINGS")
assert_eq "(a) settings.json env is clean (no legacy pin, subagent-model, depth==1, no disableWorkflows)" \
    "" "$A_OUT"

# ---------------------------------------------------------------------------
# (b) no agent frontmatter carries hooks:
# ---------------------------------------------------------------------------

echo "--- (b) agent frontmatter has no hooks: key ---"
B_VIOLATIONS=""
for f in "$PROJECT_DIR"/.claude/agents/*.md; do
    [ -f "$f" ] || continue
    if [ "$(frontmatter_has_hooks "$f")" = "yes" ]; then
        B_VIOLATIONS="$B_VIOLATIONS $(basename "$f")"
    fi
done
assert_eq "(b) no .claude/agents/*.md declares frontmatter hooks:" "" "${B_VIOLATIONS# }"

# ---------------------------------------------------------------------------
# (c) no deprecated Task-call mode param.
# ---------------------------------------------------------------------------

echo "--- (c) no deprecated Task mode: param ---"
C_FILES=()
for f in "$PROJECT_DIR"/.claude/agents/*.md "$PROJECT_DIR"/.claude/commands/*.md "$SKILL"; do
    [ -f "$f" ] && C_FILES+=("$f")
done
C_OUT=$(scan_mode_params "${C_FILES[@]}")
assert_eq "(c) no Task-call mode= / mode: param in agents/commands/SKILL" "" "$C_OUT"

# ---------------------------------------------------------------------------
# (d) MCP manifests parse; both servers stdio; .mcp.json literal var form.
# ---------------------------------------------------------------------------

echo "--- (d) MCP manifests ---"
assert_eq "(d) .mcp.json parses" "ok" \
    "$(jq -e . "$MCP_JSON" >/dev/null 2>&1 && echo ok || echo bad)"
assert_eq "(d) .claude-plugin/plugin.json parses" "ok" \
    "$(jq -e . "$PLUGIN_JSON" >/dev/null 2>&1 && echo ok || echo bad)"
assert_eq "(d) .mcp.json bd is type stdio" "stdio" \
    "$(jq -r '.mcpServers.bd.type // "<none>"' "$MCP_JSON" 2>/dev/null)"
assert_eq "(d) .mcp.json code-graph is type stdio" "stdio" \
    "$(jq -r '.mcpServers["code-graph"].type // "<none>"' "$MCP_JSON" 2>/dev/null)"
assert_eq "(d) plugin.json bd is type stdio" "stdio" \
    "$(jq -r '.mcpServers.bd.type // "<none>"' "$PLUGIN_JSON" 2>/dev/null)"
assert_eq "(d) plugin.json code-graph is type stdio" "stdio" \
    "$(jq -r '.mcpServers["code-graph"].type // "<none>"' "$PLUGIN_JSON" 2>/dev/null)"
# The single quotes are intentional: we assert the LITERAL var form is present
# in the file, so it must NOT expand here.
# shellcheck disable=SC2016
assert_contains "(d) .mcp.json uses literal \${CLAUDE_PROJECT_DIR:-.}" \
    '${CLAUDE_PROJECT_DIR:-.}' "$(cat "$MCP_JSON")"

# ---------------------------------------------------------------------------
# (e) every agent frontmatter effort: == max.
# ---------------------------------------------------------------------------

echo "--- (e) agent frontmatter effort: == max ---"
E_BAD=""
E_COUNT=0
for f in "$PROJECT_DIR"/.claude/agents/*.md; do
    [ -f "$f" ] || continue
    E_COUNT=$((E_COUNT + 1))
    ev=$(frontmatter_effort "$f")
    [ "$ev" = "max" ] || E_BAD="$E_BAD $(basename "$f")=$ev"
done
assert_eq "(e) every agent frontmatter effort: == max ($E_COUNT agents)" "" "${E_BAD# }"

# ---------------------------------------------------------------------------
# (f) settings.json and hooks.json agree on the SubagentStart entry.
# ---------------------------------------------------------------------------

echo "--- (f) SubagentStart parity ---"
SS_SETTINGS=$(jq -S -c '.hooks.SubagentStart // null' "$SETTINGS" 2>/dev/null)
SS_HOOKS=$(jq -S -c '.hooks.SubagentStart // null' "$HOOKS_JSON" 2>/dev/null)
assert_eq "(f) settings.json defines a SubagentStart entry" \
    "no" "$([ "$SS_SETTINGS" = "null" ] && echo yes || echo no)"
assert_eq "(f) settings.json and hooks.json agree on SubagentStart" "$SS_HOOKS" "$SS_SETTINGS"

# ---------------------------------------------------------------------------
# META (a): a settings.json WITH the effort env key must trip checker (a).
# ---------------------------------------------------------------------------

echo "--- META (a) ---"
META_DIR=$(mktemp -d -t platform-audit.XXXXXX)
trap 'rm -rf "$META_DIR"' EXIT

cat > "$META_DIR/bad-settings.json" <<'JSON'
{
  "effortLevel": "xhigh",
  "env": {
    "MAX_THINKING_TOKENS": "64000",
    "CLAUDE_CODE_EFFORT_LEVEL": "max",
    "CLAUDE_LATEST_OPUS": "claude-opus-4-8"
  }
}
JSON
META_A=$(audit_settings_env "$META_DIR/bad-settings.json")
assert_contains "META (a): checker flags the legacy effort env key" "HAS_EFFORT_ENV" "$META_A"
# The same bad fixture also lacks the depth pin — proves the depth check fires.
assert_contains "META (a): checker flags the missing depth pin" "DEPTH_NOT_1" "$META_A"

# A clean fixture returns no violations (checker is not always-firing).
cat > "$META_DIR/good-settings.json" <<'JSON'
{
  "env": {
    "MAX_THINKING_TOKENS": "64000",
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1",
    "CLAUDE_LATEST_OPUS": "claude-opus-4-8"
  }
}
JSON
assert_eq "META (a): checker passes a clean settings fixture" "" "$(audit_settings_env "$META_DIR/good-settings.json")"

# ---------------------------------------------------------------------------
# META (b): an agent file WITH hooks: frontmatter must trip checker (b).
# ---------------------------------------------------------------------------

echo "--- META (b) ---"
cat > "$META_DIR/bad-agent.md" <<'MD'
---
name: rogue
description: has a forbidden hooks key
model: claude-opus-4-8
hooks:
  PreToolUse:
    - command: "echo nope"
effort: max
---

body
MD
assert_eq "META (b): checker flags an agent with hooks: frontmatter" "yes" \
    "$(frontmatter_has_hooks "$META_DIR/bad-agent.md")"

cat > "$META_DIR/good-agent.md" <<'MD'
---
name: clean
description: no hooks key
model: claude-opus-4-8
effort: max
---

body
MD
assert_eq "META (b): checker passes an agent without hooks: frontmatter" "no" \
    "$(frontmatter_has_hooks "$META_DIR/good-agent.md")"

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

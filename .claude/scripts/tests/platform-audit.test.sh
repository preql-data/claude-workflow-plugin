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
#   (f) settings.json and hooks.json agree on the WHOLE hook surface: the same
#       EVENT SET, and deep equality per event.
#
# WHY (f) IS NO LONGER SubagentStart-ONLY (v4.1 C1b, claude-workflow-plugin-8xv)
# ----------------------------------------------------------------------------
# The two files are hand-mirrored: settings.json is what a session actually
# loads, hooks.json is what the PLUGIN manifest ships. Until this release the
# check compared exactly one event, so a hook entry added to, removed from, or
# retimed in ONE file and not the other was invisible — the plugin and the
# installed project would silently run different hook sets, which is the same
# class of drift the shared denylist was consolidated to kill. The gap surfaced
# while wiring the worktree sweep into SessionEnd (an event the old checker did
# not cover); closing it is independent of the sweeper.
#
# META:
#   - (a) a tempdir settings.json WITH the effort env key must trip checker (a).
#   - (b) a tempdir agent file WITH `hooks:` frontmatter must trip checker (b).
#   - (f) a tempdir hooks.json with an EXTRA event must trip EVENT_SET_MISMATCH;
#         one with a changed SessionEnd command must trip EVENT_DIFF:SessionEnd;
#         an unparseable file must trip READ_ERROR (never read as clean); and a
#         faithful copy must return no violations at all.

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

# Echo space-separated violation codes for the settings.json <-> hooks.json
# hook-surface comparison; empty output == clean. READ_ERROR if either file
# fails to parse, NO_EVENTS if neither declares any hook (which would make
# every per-event comparison below vacuously true).
#
# The event union is built from TWO independent single-file jq calls rather than
# one `jq -s` over both: `-s` binds by POSITION, so a file that is secretly a
# multi-document stream shifts .[0]/.[1] and the comparison silently reads the
# wrong pair of documents (LESSONS.md). There is no position to get wrong here.
#
# `jq -S` sorts object keys recursively so formatting and key order cannot
# register as drift — but ARRAY order is preserved, because hook execution order
# is semantic and a reordered array IS a real difference.
audit_hooks_parity() {
    local a="$1" b="$2" out="" ka kb ev va vb n=0
    if ! jq -e . "$a" >/dev/null 2>&1 || ! jq -e . "$b" >/dev/null 2>&1; then
        printf 'READ_ERROR'; return 0
    fi
    ka=$(jq -S -c '(.hooks // {}) | keys' "$a" 2>/dev/null)
    kb=$(jq -S -c '(.hooks // {}) | keys' "$b" 2>/dev/null)
    [ "$ka" = "$kb" ] || out="$out EVENT_SET_MISMATCH"
    while IFS= read -r ev; do
        [ -n "$ev" ] || continue
        n=$((n + 1))
        va=$(jq -S -c --arg e "$ev" '.hooks[$e] // null' "$a" 2>/dev/null)
        vb=$(jq -S -c --arg e "$ev" '.hooks[$e] // null' "$b" 2>/dev/null)
        [ "$va" = "$vb" ] || out="$out EVENT_DIFF:$ev"
    done < <( { jq -r '(.hooks // {}) | keys[]' "$a" 2>/dev/null
                jq -r '(.hooks // {}) | keys[]' "$b" 2>/dev/null; } | LC_ALL=C sort -u )
    [ "$n" -gt 0 ] || out="$out NO_EVENTS"
    printf '%s' "${out# }"
}

# Echo the count of distinct hook events declared across both files. Reported
# as a completeness number rather than inferred from "no violations": a checker
# that compared zero events would also report no violations.
hooks_event_count() {
    { jq -r '(.hooks // {}) | keys[]' "$1" 2>/dev/null
      jq -r '(.hooks // {}) | keys[]' "$2" 2>/dev/null; } | LC_ALL=C sort -u | grep -c . || true
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
# (f) settings.json and hooks.json agree on the WHOLE hook surface.
# ---------------------------------------------------------------------------

echo "--- (f) hook-surface parity (event set + per-event deep equality) ---"
F_OUT=$(audit_hooks_parity "$SETTINGS" "$HOOKS_JSON")
# ONE difference is deliberate and documented (docs/HOOKS.md, under the
# settings.json example): hooks.json wires a SECOND PostToolUse matcher,
# `^Bash$` -> bd-github-link.sh, for plugin-scoped installs. It is pinned
# EXACTLY rather than waved through, in two steps: the violation set must be
# that one code and nothing else, AND the PostToolUse difference must be
# precisely "settings' list plus that entry". A drift in any other event, or a
# DIFFERENT drift in PostToolUse, still fails.
assert_eq "(f) the ONLY hook-surface difference is the documented PostToolUse one" \
    "EVENT_DIFF:PostToolUse" "$F_OUT"
# The single quotes are load-bearing: $CLAUDE_PROJECT_DIR is a LITERAL in the
# manifest and must not expand here.
# shellcheck disable=SC2016
F_BASH_ENTRY='{"matcher":"^Bash$","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/bd-github-link.sh\"","timeout":15000}]}'
assert_eq "(f) hooks.json PostToolUse == settings.json's PLUS exactly the ^Bash^ entry" \
    "$(jq -S -c --argjson x "$F_BASH_ENTRY" '(.hooks.PostToolUse // []) + [$x]' "$SETTINGS" 2>/dev/null)" \
    "$(jq -S -c '.hooks.PostToolUse // []' "$HOOKS_JSON" 2>/dev/null)"
# Completeness, not absence: N events were actually compared.
F_COUNT=$(hooks_event_count "$SETTINGS" "$HOOKS_JSON")
assert_eq "(f) Total: 7 hook events compared" "7" "$F_COUNT"
# The exact shipped set, so a hook DELETED FROM BOTH files (which the parity
# check alone would call clean) still fails here.
assert_eq "(f) the shipped event set is exactly the seven v4 hooks" \
    '["PostToolUse","PreToolUse","SessionEnd","SessionStart","Stop","SubagentStart","UserPromptSubmit"]' \
    "$(jq -S -c '(.hooks // {}) | keys' "$SETTINGS" 2>/dev/null)"
SS_SETTINGS=$(jq -S -c '.hooks.SubagentStart // null' "$SETTINGS" 2>/dev/null)
assert_eq "(f) settings.json defines a SubagentStart entry" \
    "no" "$([ "$SS_SETTINGS" = "null" ] && echo yes || echo no)"
assert_eq "(f) hooks.json defines a SessionEnd entry" "no" \
    "$([ "$(jq -S -c '.hooks.SessionEnd // null' "$HOOKS_JSON" 2>/dev/null)" = "null" ] && echo yes || echo no)"

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
# META (f): the generalised hook-parity checker must fire on each drift shape.
# Every fixture is derived from the REAL hooks.json so a change to the shipped
# file cannot leave these fixtures pinning a shape that no longer exists.
# ---------------------------------------------------------------------------

echo "--- META (f) ---"

# The baseline pair is hooks.json against a COPY OF ITSELF, not against
# settings.json: the real pair carries the documented PostToolUse allowance
# above, and a control that is already non-empty cannot show that the mutations
# below are what produced their codes.
cp "$HOOKS_JSON" "$META_DIR/hooks-clean.json"
assert_eq "META (f): checker passes a faithful pair with no violations at all" "" \
    "$(audit_hooks_parity "$HOOKS_JSON" "$META_DIR/hooks-clean.json")"

# 1. An event present in one file only.
jq '.hooks.PreCompact = [{"hooks":[{"type":"command","command":"echo drift"}]}]' \
    "$HOOKS_JSON" > "$META_DIR/hooks-extra-event.json" 2>/dev/null
assert_eq "META (f): the extra-event fixture really differs from the shipped file" "1" \
    "$(cmp -s "$HOOKS_JSON" "$META_DIR/hooks-extra-event.json" && echo 0 || echo 1)"
assert_contains "META (f): an event in ONE file only trips EVENT_SET_MISMATCH" \
    "EVENT_SET_MISMATCH" "$(audit_hooks_parity "$HOOKS_JSON" "$META_DIR/hooks-extra-event.json")"

# 2. Same event set, different content — the case the old SubagentStart-only
#    check could not see for any event but SubagentStart. SessionEnd is chosen
#    deliberately: it is the event v4.1 C1b added work to.
jq '.hooks.SessionEnd[0].hooks[0].timeout = 999999' \
    "$HOOKS_JSON" > "$META_DIR/hooks-diff-value.json" 2>/dev/null
assert_eq "META (f): the value-drift fixture really differs from the shipped file" "1" \
    "$(cmp -s "$HOOKS_JSON" "$META_DIR/hooks-diff-value.json" && echo 0 || echo 1)"
META_F_DIFF=$(audit_hooks_parity "$HOOKS_JSON" "$META_DIR/hooks-diff-value.json")
assert_eq "META (f): a per-event value change trips EXACTLY EVENT_DIFF:SessionEnd" \
    "EVENT_DIFF:SessionEnd" "$META_F_DIFF"

# 3. A corrupt manifest must never read as clean.
printf 'this is not json\n' > "$META_DIR/hooks-broken.json"
assert_eq "META (f): an unparseable manifest reports READ_ERROR, not clean" "READ_ERROR" \
    "$(audit_hooks_parity "$HOOKS_JSON" "$META_DIR/hooks-broken.json")"

# 4. A pair that declares no hooks at all must not pass by vacuity.
printf '{"env":{}}\n' > "$META_DIR/hooks-empty.json"
assert_contains "META (f): a hookless pair reports NO_EVENTS rather than clean" \
    "NO_EVENTS" "$(audit_hooks_parity "$META_DIR/hooks-empty.json" "$META_DIR/hooks-empty.json")"

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

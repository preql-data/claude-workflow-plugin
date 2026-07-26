#!/bin/bash
# packaging-parity.test.sh — L1 spec for the two installer merge expressions
# (claude-workflow-plugin-p5n, v4.1 Phase U0; absorbs claude-workflow-plugin-bzy).
#
# WHAT THIS PROTECTS
# ------------------
# `install.sh` mode 2 (Update) is the ONLY path an already-installed project
# takes to reach a new plugin version. THREE jq expressions decide what survives
# that path, all three duplicated verbatim into install.ps1:
#
#   SETTINGS_MERGE_JQ — replaces workflow-owned settings keys, preserves the
#   operator's, deletes the retired env.CLAUDE_CODE_EFFORT_LEVEL pin (v4: a
#   non-xhigh value there deactivates ultracode orchestration), and — new in
#   v4.1 — ADDS effortLevel / statusLine to a settings file of pre-v3.5
#   lineage that lacks them.
#
#   MCP_MERGE_JQ — unions the shipped MCP servers over the installed ones
#   (which is how a v3.5 tree gets the `${CLAUDE_PROJECT_DIR:-.}` form and
#   loses the code-context server retired in 3.3.0) while operator-added
#   servers and operator top-level keys pass through verbatim.
#
#   JSON_SINGLE_OBJECT_JQ — the gate BOTH merges pass their target through
#   first. Both slurp with `jq -s` and bind positionally (.[0] existing,
#   .[1] new), which is only sound when each input holds exactly one JSON
#   document. The `jq empty` check this replaced accepted an empty file and a
#   multi-document stream; a two-document target pushed the shipped file out
#   to .[2] and produced a config with none of the shipped servers (R1-F1).
#
# Until now the `del(.CLAUDE_CODE_EFFORT_LEVEL)` behaviour was proven only by a
# LIVE PROBE in a session transcript (RELEASE_AUDIT row TM13): a hand-run copy
# of the expression against a synthetic settings file. Nothing in `make test`
# caught a future break, and the expression is DUPLICATED as a PowerShell
# string literal in install.ps1 — the drift surface the "Keep this jq
# expression equivalent to install.sh's" comment can only ask about politely.
#
# THE CONTRACT THIS SPEC ENFORCES
#   1. Both expressions are extracted FROM THE INSTALLERS, between literal
#      sentinel comments, and executed through real jq. A copied literal in
#      this file would test the copy, not the shipped installer — the whole
#      point of bzy deliverable 1.
#   2. The extracted expressions are also the ones the installers RUN (the
#      wiring section): a hoisted-but-unused variable would make every
#      behavioural assertion below theatre.
#   3. bash and PowerShell carry token-identical expressions.
#
# ASSERTION ANCHORING: every check is anchored to TEXT (a sentinel token, a
# jq key, a fixture value) and never to a line number — install.sh's merge
# block has moved twice already.
#
# SECTIONS
#   0. Preflight: the two installers and jq exist.
#   1. Extraction: sentinels present exactly once, extraction non-empty.
#   1b. Wiring: the installers invoke the hoisted variables, each expression is
#       defined exactly once per file (no stale duplicate), both merges gate on
#       the validity helper, and the retired `jq empty` oracle is gone.
#   2. Settings fixture battery, driven by the EXTRACTED bash expression —
#      including the PRESENCE-not-truthiness battery (R1-F2): an operator's
#      explicit null/false survives an upgrade.
#   3. MCP fixture battery, driven by the EXTRACTED bash expression, against
#      the REAL shipped .mcp.json.
#   3b. Merge-input validity gate (R1-F1): empty / multi-document / malformed /
#      array / scalar inputs are rejected, the retired oracle's acceptance of
#      the first two is pinned as a regression witness, and the consequence of
#      accepting a multi-document target is demonstrated end-to-end.
#   4. Expression identity bash <-> ps1 (whitespace-normalised).
#   5. META-TESTs: each proves a check above is capable of failing.
#
# Exit codes:
#   0  all assertions pass
#   1  one or more assertions failed

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
INSTALL_SH="$PROJECT_DIR/install.sh"
INSTALL_PS1="$PROJECT_DIR/install.ps1"
SHIPPED_MCP="$PROJECT_DIR/.mcp.json"
SHIPPED_SETTINGS="$PROJECT_DIR/.claude/settings.json"

WORK=$(mktemp -d -t packaging-parity-test.XXXXXX)
# Invoked indirectly, by the EXIT trap immediately below.
# shellcheck disable=SC2329
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

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

# --- extraction helpers ----------------------------------------------------

# extract_block <file> <name> — print the lines strictly between
# `# BEGIN <name>` and `# END <name>`.
#
# Matched with index() rather than an anchored regex so the same extractor
# works for install.sh (sentinels at column 0) and install.ps1 (sentinels
# indented inside the install function). The BEGIN sentinel carries a
# trailing parenthetical in both files; only the token prefix is matched.
extract_block() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 1
    awk -v b="# BEGIN $name" -v e="# END $name" '
        !inb && index($0, b) { inb = 1; next }
        inb && index($0, e)  { exit }
        inb                  { print }
    ' "$file"
}

# strip_quoted_literal — stdin to stdout: drop the assignment head up to and
# including the FIRST single quote on the first line (`NAME='` in bash,
# `$Name = '` in PowerShell) and the trailing single quote on the last line.
# Neither jq expression contains a single quote, so this is unambiguous for
# both dialects; a quote appearing inside one later would be caught by the
# fixture batteries failing to parse.
strip_quoted_literal() {
    sed -e "1s/^[^']*'//" -e "\$s/'[[:space:]]*\$//"
}

# extract_expr <file> <name> — the runnable jq program text.
extract_expr() {
    extract_block "$1" "$2" | strip_quoted_literal
}

# normalize_expr — stdin to stdout: collapse every whitespace run to one
# space and trim. This is what makes the bash <-> ps1 comparison a TOKEN
# comparison: the two literals live at different indentation depths and the
# add-if-absent clauses are column-aligned with double spaces.
normalize_expr() {
    tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# sentinel_line_count <file> <token> — how many lines carry the token.
# Exactly 1 is the contract: 0 means the sentinel was renamed or deleted,
# 2+ means a second definition was pasted in (the drift this spec exists
# to prevent).
sentinel_line_count() {
    grep -c -- "$2" "$1" 2>/dev/null | tr -d ' \n'
}

# code_line_count <file> <literal> — fixed-string line count over CODE lines
# only; any line whose first non-space character is `#` (the comment marker in
# both bash and PowerShell) is excluded first.
#
# Comment-blindness is required, not cosmetic: the "this call no longer exists"
# assertions below would otherwise be satisfied by the prose that DESCRIBES the
# retired call, and the installers deliberately explain why `jq empty` was
# unsound. Counting prose as code would make those assertions unfailable.
code_line_count() {
    grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -c -F -- "$2" | tr -d ' \n'
}

# --- merge + checker helpers -----------------------------------------------
# Every checker takes FILE PATHS so the META-TESTs can run byte-identical
# logic against deliberately mutated merges.

# run_merge <expr> <existing.json> <new.json> <out.json> — mirrors the
# installers' invocation exactly: `jq -s <expr> <existing> <new>`.
run_merge() {
    jq -s "$1" "$2" "$3" > "$4" 2>/dev/null
}

# check_retired_key_deleted <merged.json> — 0 when env.CLAUDE_CODE_EFFORT_LEVEL
# is gone, 1 when it survived the merge, 2 when the file is unusable.
check_retired_key_deleted() {
    [ -f "$1" ] || return 2
    jq empty "$1" >/dev/null 2>&1 || return 2
    if jq -e '(.env // {}) | has("CLAUDE_CODE_EFFORT_LEVEL")' "$1" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# check_key_added <merged.json> <jq-path> <expected> — 0 when the key holds
# the expected value, 1 when it is absent or differs, 2 when unusable.
check_key_added() {
    [ -f "$1" ] || return 2
    jq empty "$1" >/dev/null 2>&1 || return 2
    local actual
    actual=$(jq -r "$2 // \"ABSENT\"" "$1" 2>/dev/null)
    [ "$actual" = "$3" ] || return 1
    return 0
}

# jq_get <file> <filter> — raw scalar read, "ERR" when jq fails.
jq_get() {
    jq -r "$2" "$1" 2>/dev/null || echo "ERR"
}

# jq_sorted <file> <filter> — canonical compact form of a subtree, for
# deep-equality comparisons.
jq_sorted() {
    jq -S -c "$2" "$1" 2>/dev/null || echo "ERR"
}

# ===========================================================================
echo "=== Section 0: preflight ==="

assert_eq "preflight: install.sh exists" "yes" \
    "$([ -f "$INSTALL_SH" ] && echo yes || echo no)"
assert_eq "preflight: install.ps1 exists" "yes" \
    "$([ -f "$INSTALL_PS1" ] && echo yes || echo no)"
assert_eq "preflight: jq on PATH" "yes" \
    "$(command -v jq >/dev/null 2>&1 && echo yes || echo no)"

if [ ! -f "$INSTALL_SH" ] || [ ! -f "$INSTALL_PS1" ] || ! command -v jq >/dev/null 2>&1; then
    printf '\nFAILED: %d (preflight; nothing downstream can run)\n' "$FAIL"
    exit 1
fi

# ===========================================================================
echo ""
echo "=== Section 1: expression extraction from the installers (bzy #1) ==="

# assert_extractable <label> <file> <name> — the four properties that make an
# expression followable from source: both sentinels present exactly once, and
# a non-empty extraction that looks like the merge program.
# shellcheck disable=SC2016 # literal `$existing`/`$new` are jq bindings being searched for, never shell expansions
assert_extractable() {
    local label="$1" file="$2" name="$3" expr
    assert_eq "$label: '# BEGIN $name' present exactly once" "1" \
        "$(sentinel_line_count "$file" "# BEGIN $name")"
    assert_eq "$label: '# END $name' present exactly once" "1" \
        "$(sentinel_line_count "$file" "# END $name")"
    expr=$(extract_expr "$file" "$name")
    assert_eq "$label: $name extraction is non-empty" "non-empty" \
        "$([ -n "$(printf '%s' "$expr" | tr -d '[:space:]')" ] && echo non-empty || echo EMPTY)"
    assert_eq "$label: $name extraction binds \$existing and \$new" "yes" \
        "$(printf '%s' "$expr" | grep -q '\.\[0\] as \$existing' \
           && printf '%s' "$expr" | grep -q '\.\[1\] as \$new' \
           && echo yes || echo no)"
}

# assert_extractable_scalar <label> <file> <name> <substring> — the same
# sentinel contract for a single-line expression that carries no $existing/$new
# bindings (the R1-F1 validity gate).
assert_extractable_scalar() {
    local label="$1" file="$2" name="$3" needle="$4" expr
    assert_eq "$label: '# BEGIN $name' present exactly once" "1" \
        "$(sentinel_line_count "$file" "# BEGIN $name")"
    assert_eq "$label: '# END $name' present exactly once" "1" \
        "$(sentinel_line_count "$file" "# END $name")"
    expr=$(extract_expr "$file" "$name")
    assert_eq "$label: $name extraction is non-empty" "non-empty" \
        "$([ -n "$(printf '%s' "$expr" | tr -d '[:space:]')" ] && echo non-empty || echo EMPTY)"
    assert_eq "$label: $name extraction carries the slurp-length check" "yes" \
        "$(printf '%s' "$expr" | grep -qF -- "$needle" && echo yes || echo no)"
}

assert_extractable "install.sh" "$INSTALL_SH" "SETTINGS_MERGE_JQ"
assert_extractable "install.sh" "$INSTALL_SH" "MCP_MERGE_JQ"
assert_extractable "install.ps1" "$INSTALL_PS1" "SETTINGS_MERGE_JQ"
assert_extractable "install.ps1" "$INSTALL_PS1" "MCP_MERGE_JQ"
assert_extractable_scalar "install.sh" "$INSTALL_SH" "JSON_SINGLE_OBJECT_JQ" "length == 1"
assert_extractable_scalar "install.ps1" "$INSTALL_PS1" "JSON_SINGLE_OBJECT_JQ" "length == 1"

SH_SETTINGS_EXPR=$(extract_expr "$INSTALL_SH" "SETTINGS_MERGE_JQ")
SH_MCP_EXPR=$(extract_expr "$INSTALL_SH" "MCP_MERGE_JQ")
SH_VALID_EXPR=$(extract_expr "$INSTALL_SH" "JSON_SINGLE_OBJECT_JQ")
PS_SETTINGS_EXPR=$(extract_expr "$INSTALL_PS1" "SETTINGS_MERGE_JQ")
PS_MCP_EXPR=$(extract_expr "$INSTALL_PS1" "MCP_MERGE_JQ")
PS_VALID_EXPR=$(extract_expr "$INSTALL_PS1" "JSON_SINGLE_OBJECT_JQ")

# Fail LOUDLY and stop: a silent empty extraction would turn every jq run
# below into a vacuous pass. This is bzy deliverable 1's whole point.
if [ -z "$(printf '%s' "$SH_SETTINGS_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$SH_MCP_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$SH_VALID_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$PS_SETTINGS_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$PS_MCP_EXPR" | tr -d '[:space:]')" ] \
   || [ -z "$(printf '%s' "$PS_VALID_EXPR" | tr -d '[:space:]')" ]; then
    printf '\nFAILED: %d (expression extraction empty — sentinels missing, renamed,\n' "$FAIL"
    printf '  or the assignment reshaped. Nothing downstream can run.)\n'
    exit 1
fi

# ===========================================================================
echo ""
echo "=== Section 1b: the installers RUN the hoisted expressions ==="
# Without these, someone could hoist the variables, leave the old inline
# expression in the jq call, and every behavioural assertion below would
# still pass while the shipped installer used something else entirely.

# shellcheck disable=SC2016 # the searched-for text IS a literal shell invocation line
assert_eq "wiring: install.sh invokes jq -s \"\$SETTINGS_MERGE_JQ\"" "1" \
    "$(code_line_count "$INSTALL_SH" 'jq -s "$SETTINGS_MERGE_JQ"')"
# shellcheck disable=SC2016 # the searched-for text IS a literal shell invocation line
assert_eq "wiring: install.sh invokes jq -s \"\$MCP_MERGE_JQ\"" "1" \
    "$(code_line_count "$INSTALL_SH" 'jq -s "$MCP_MERGE_JQ"')"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation line
assert_eq "wiring: install.ps1 invokes jq -s \$SettingsMergeJq" "1" \
    "$(code_line_count "$INSTALL_PS1" 'jq -s $SettingsMergeJq')"
# shellcheck disable=SC2016 # the searched-for text is a literal PowerShell invocation line
assert_eq "wiring: install.ps1 invokes jq -s \$McpMergeJq" "1" \
    "$(code_line_count "$INSTALL_PS1" 'jq -s $McpMergeJq')"

# One definition per file. A second copy of either signature line means the
# expression was duplicated back into an inline call.
assert_eq "wiring: install.sh defines del(.CLAUDE_CODE_EFFORT_LEVEL) exactly once" "1" \
    "$(code_line_count "$INSTALL_SH" 'del(.CLAUDE_CODE_EFFORT_LEVEL)')"
assert_eq "wiring: install.ps1 defines del(.CLAUDE_CODE_EFFORT_LEVEL) exactly once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'del(.CLAUDE_CODE_EFFORT_LEVEL)')"
assert_eq "wiring: install.sh defines del(.mcpServers[\"code-context\"]) exactly once" "1" \
    "$(code_line_count "$INSTALL_SH" 'del(.mcpServers["code-context"])')"
assert_eq "wiring: install.ps1 defines del(.mcpServers[\"code-context\"]) exactly once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'del(.mcpServers["code-context"])')"

# The THIRD duplicated jq expression: the bare-${VAR} detector that names an
# operator server whose config Claude Code cannot expand. It is not sentinel-
# wrapped (it is a readout probe, not a merge), but it is duplicated across the
# two installers just the same — so pin its detector line FILE-TO-FILE. No
# copied literal: both sides come from the installers, only the anchor
# `any(test(` is typed here.
probe_line() {
    grep -F -- 'any(test(' "$1" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
assert_eq "bare-var probe: install.sh carries exactly one detector line" "1" \
    "$(probe_line "$INSTALL_SH" | grep -c . | tr -d ' \n')"
assert_eq "bare-var probe: install.ps1 carries exactly one detector line" "1" \
    "$(probe_line "$INSTALL_PS1" | grep -c . | tr -d ' \n')"
assert_eq "bare-var probe: the two detector lines are byte-identical" \
    "$(probe_line "$INSTALL_SH")" "$(probe_line "$INSTALL_PS1")"

# R1-F1 wiring: BOTH merges must gate on the validity helper, and the retired
# `jq empty` oracle (which accepts empty AND multi-document input) must be gone
# from both installers. Two call sites each: .mcp.json and settings.json.
assert_eq "wiring: install.sh gates both merges on json_single_object" "2" \
    "$(code_line_count "$INSTALL_SH" 'if json_single_object "$')"
assert_eq "wiring: install.sh defines json_single_object() once" "1" \
    "$(code_line_count "$INSTALL_SH" 'json_single_object() {')"
# shellcheck disable=SC2016 # the searched-for text IS a literal shell invocation line
assert_eq "wiring: install.sh runs the gate as jq -s -e" "1" \
    "$(code_line_count "$INSTALL_SH" 'jq -s -e "$JSON_SINGLE_OBJECT_JQ"')"
assert_eq "wiring: install.ps1 gates both merges on Test-JsonSingleObject" "2" \
    "$(code_line_count "$INSTALL_PS1" 'if (Test-JsonSingleObject $')"
assert_eq "wiring: install.ps1 defines Test-JsonSingleObject once" "1" \
    "$(code_line_count "$INSTALL_PS1" 'function Test-JsonSingleObject')"
# The retired oracle: `jq empty` must appear in NEITHER installer. It is the
# exact check R1-F1 proved unsound, so its return is the regression to catch.
assert_eq "wiring: install.sh no longer uses the retired 'jq empty' oracle" "0" \
    "$(code_line_count "$INSTALL_SH" 'jq empty')"
assert_eq "wiring: install.ps1 no longer uses the retired 'jq empty' oracle" "0" \
    "$(code_line_count "$INSTALL_PS1" 'jq empty')"

# ===========================================================================
echo ""
echo "=== Section 2: settings merge battery (bzy #2) ==="

# The shipped values the add-if-absent clauses hand to a pre-v3.5 tree. If
# .claude/settings.json ever loses either key, the clause would write a null
# into the operator's file — so assert the real shipped surface first.
assert_eq "shipped settings.json carries effortLevel" "yes" \
    "$([ "$(jq_get "$SHIPPED_SETTINGS" '.effortLevel // "ABSENT"')" != "ABSENT" ] && echo yes || echo no)"
assert_eq "shipped settings.json carries statusLine" "yes" \
    "$([ "$(jq_get "$SHIPPED_SETTINGS" '.statusLine.command // "ABSENT"')" != "ABSENT" ] && echo yes || echo no)"

# --- fixtures --------------------------------------------------------------
# EXISTING (pre-v3.5 lineage): the retired env pin, an operator env key, an
# operator permissions block, an operator top-level key, stale hooks — and
# NO effortLevel / statusLine.
NEW_SETTINGS="$WORK/new-settings.json"
OLD_LEGACY="$WORK/existing-legacy.json"
OLD_PINNED="$WORK/existing-pinned.json"

cat > "$OLD_LEGACY" <<'JSON'
{
  "additionalDirectories": ["./legacy"],
  "env": {
    "CLAUDE_CODE_EFFORT_LEVEL": "xhigh",
    "OPERATOR_KEY": "operator-value",
    "MAX_THINKING_TOKENS": "32000"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash legacy-session-start.sh" }
        ]
      }
    ]
  },
  "permissions": { "allow": ["Read", "Bash", "OperatorTool"] },
  "operatorTopLevel": "keep-me"
}
JSON

# VARIANT: the operator pinned effortLevel and statusLine themselves, and has
# no permissions block. Proves both directions of add-if-absent.
cat > "$OLD_PINNED" <<'JSON'
{
  "effortLevel": "high",
  "env": { "OPERATOR_KEY": "operator-value" },
  "statusLine": { "type": "command", "command": "bash operator-statusline.sh" },
  "hooks": {}
}
JSON

# SHIPPED NEW: modelled on .claude/settings.json (same key shape, same
# effortLevel/statusLine/env/hook contract) with fixture-local values so the
# assertions stay stable when the real file's values move.
cat > "$NEW_SETTINGS" <<'JSON'
{
  "additionalDirectories": ["../"],
  "effortLevel": "xhigh",
  "env": {
    "MAX_THINKING_TOKENS": "64000",
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1",
    "CLAUDE_LATEST_OPUS": "claude-opus-5"
  },
  "statusLine": {
    "type": "command",
    "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/statusline.sh\""
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-start.sh\"", "timeout": 30000 }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/verify-before-stop.sh\"", "timeout": 1320000 }
        ]
      }
    ]
  },
  "permissions": { "allow": ["Read", "Write", "Edit", "Bash", "Task"] }
}
JSON

# Expected values read back from the fixture (never re-typed as a literal —
# a typo in an expectation is indistinguishable from a real failure).
NEW_STATUSLINE=$(jq_get "$NEW_SETTINGS" '.statusLine.command')
NEW_SESSIONSTART=$(jq_get "$NEW_SETTINGS" '.hooks.SessionStart[0].hooks[0].command')

MERGED_LEGACY="$WORK/merged-legacy.json"
MERGE_RC=0
run_merge "$SH_SETTINGS_EXPR" "$OLD_LEGACY" "$NEW_SETTINGS" "$MERGED_LEGACY" || MERGE_RC=$?
assert_eq "settings: extracted expression runs under real jq (exit 0)" "0" "$MERGE_RC"
assert_eq "settings: merged output is valid JSON" "0" \
    "$(jq empty "$MERGED_LEGACY" >/dev/null 2>&1 && echo 0 || echo 1)"

# The TM13 claim, now mechanical.
RC=0; check_retired_key_deleted "$MERGED_LEGACY" || RC=$?
assert_eq "settings: retired env.CLAUDE_CODE_EFFORT_LEVEL is deleted" "0" "$RC"

assert_eq "settings: operator env key survives the union" "operator-value" \
    "$(jq_get "$MERGED_LEGACY" '.env.OPERATOR_KEY // "ABSENT"')"
assert_eq "settings: shipped env key CLAUDE_LATEST_OPUS arrives" "claude-opus-5" \
    "$(jq_get "$MERGED_LEGACY" '.env.CLAUDE_LATEST_OPUS // "ABSENT"')"
assert_eq "settings: shipped env key CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH arrives" "1" \
    "$(jq_get "$MERGED_LEGACY" '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH // "ABSENT"')"
assert_eq "settings: shipped value wins on env collision (MAX_THINKING_TOKENS)" "64000" \
    "$(jq_get "$MERGED_LEGACY" '.env.MAX_THINKING_TOKENS // "ABSENT"')"

assert_eq "settings: hooks are replaced wholesale (SessionStart is the shipped one)" \
    "$NEW_SESSIONSTART" \
    "$(jq_get "$MERGED_LEGACY" '.hooks.SessionStart[0].hooks[0].command // "ABSENT"')"
assert_eq "settings: newly-shipped hook event arrives (Stop)" "true" \
    "$(jq_get "$MERGED_LEGACY" '.hooks | has("Stop")')"
assert_eq "settings: the stale hook command is gone" "absent" \
    "$(jq -c '.hooks' "$MERGED_LEGACY" 2>/dev/null | grep -q 'legacy-session-start' && echo present || echo absent)"

assert_eq "settings: operator permissions preserved (OperatorTool still allowed)" "true" \
    "$(jq_get "$MERGED_LEGACY" '(.permissions.allow // []) | index("OperatorTool") != null')"
assert_eq "settings: operator permissions NOT widened to the shipped list" "false" \
    "$(jq_get "$MERGED_LEGACY" '(.permissions.allow // []) | index("Task") != null')"

# The v4.1 add-if-absent clauses.
RC=0; check_key_added "$MERGED_LEGACY" '.effortLevel' "xhigh" || RC=$?
assert_eq "settings: effortLevel is ADDED from the shipped file" "0" "$RC"
RC=0; check_key_added "$MERGED_LEGACY" '.statusLine.command' "$NEW_STATUSLINE" || RC=$?
assert_eq "settings: statusLine is ADDED from the shipped file" "0" "$RC"

assert_eq "settings: operator top-level key survives" "keep-me" \
    "$(jq_get "$MERGED_LEGACY" '.operatorTopLevel // "ABSENT"')"
assert_eq "settings: additionalDirectories comes from the shipped file" '["../"]' \
    "$(jq_sorted "$MERGED_LEGACY" '.additionalDirectories')"

# --- operator-pinned variant ----------------------------------------------
MERGED_PINNED="$WORK/merged-pinned.json"
MERGE_RC=0
run_merge "$SH_SETTINGS_EXPR" "$OLD_PINNED" "$NEW_SETTINGS" "$MERGED_PINNED" || MERGE_RC=$?
assert_eq "settings(pinned): merge runs (exit 0)" "0" "$MERGE_RC"
assert_eq "settings(pinned): operator effortLevel is PRESERVED, not overwritten" "high" \
    "$(jq_get "$MERGED_PINNED" '.effortLevel // "ABSENT"')"
assert_eq "settings(pinned): operator statusLine is PRESERVED" "bash operator-statusline.sh" \
    "$(jq_get "$MERGED_PINNED" '.statusLine.command // "ABSENT"')"
assert_eq "settings(pinned): absent permissions block is ADDED from the shipped file" "true" \
    "$(jq_get "$MERGED_PINNED" '(.permissions.allow // []) | index("Task") != null')"

# --- R1-F2: add-if-absent means PRESENCE, not truthiness -------------------
# `if $existing.effortLevel then` reads an explicit null or false as "absent"
# and overwrites it. An operator who deliberately wrote `"effortLevel": null`
# (or `false`) owns that key just as much as one who wrote "high" — the upgrade
# must not silently replace it with the shipped value. The permissions clause
# carried the identical defect since v4.0.0 and is covered here too.
OLD_FALSY="$WORK/existing-falsy.json"
cat > "$OLD_FALSY" <<'JSON'
{
  "effortLevel": null,
  "statusLine": false,
  "permissions": null,
  "env": { "OPERATOR_KEY": "operator-value" },
  "hooks": {}
}
JSON

MERGED_FALSY="$WORK/merged-falsy.json"
MERGE_RC=0
run_merge "$SH_SETTINGS_EXPR" "$OLD_FALSY" "$NEW_SETTINGS" "$MERGED_FALSY" || MERGE_RC=$?
assert_eq "settings(falsy): merge runs (exit 0)" "0" "$MERGE_RC"
# Compact JSON, not raw: `jq -r` renders null as the string "null", which is
# indistinguishable from a literal "null" value.
assert_eq "settings(falsy): operator effortLevel:null is PRESERVED as null" "null" \
    "$(jq -c '.effortLevel' "$MERGED_FALSY" 2>/dev/null)"
assert_eq "settings(falsy): the effortLevel key is still present (not deleted)" "true" \
    "$(jq -c 'has("effortLevel")' "$MERGED_FALSY" 2>/dev/null)"
assert_eq "settings(falsy): operator statusLine:false is PRESERVED as false" "false" \
    "$(jq -c '.statusLine' "$MERGED_FALSY" 2>/dev/null)"
assert_eq "settings(falsy): operator permissions:null is PRESERVED as null" "null" \
    "$(jq -c '.permissions' "$MERGED_FALSY" 2>/dev/null)"
# Sanity: the rest of the merge still happened, so the assertions above are
# about presence semantics and not about a merge that silently did nothing.
assert_eq "settings(falsy): shipped hooks still arrived" "true" \
    "$(jq_get "$MERGED_FALSY" '.hooks | has("Stop")')"
assert_eq "settings(falsy): operator env key still preserved" "operator-value" \
    "$(jq_get "$MERGED_FALSY" '.env.OPERATOR_KEY // "ABSENT"')"

# --- idempotency -----------------------------------------------------------
# Re-running Update against an already-merged file must be a no-op. Compare
# canonicalised (jq -S) forms so key ORDER never decides the verdict.
MERGED_TWICE="$WORK/merged-legacy-twice.json"
MERGE_RC=0
run_merge "$SH_SETTINGS_EXPR" "$MERGED_LEGACY" "$NEW_SETTINGS" "$MERGED_TWICE" || MERGE_RC=$?
assert_eq "settings: second merge runs (exit 0)" "0" "$MERGE_RC"
jq -S . "$MERGED_LEGACY" > "$WORK/norm-1.json" 2>/dev/null
jq -S . "$MERGED_TWICE" > "$WORK/norm-2.json" 2>/dev/null
assert_eq "settings: merge is idempotent (normalised outputs byte-identical)" "same" \
    "$(cmp -s "$WORK/norm-1.json" "$WORK/norm-2.json" && echo same || echo different)"

# ===========================================================================
echo ""
echo "=== Section 3: .mcp.json merge battery ==="

# Real shipped config sanity — the MCP battery's "new" side IS the file the
# installer copies, so a regression there must surface here, not silently
# weaken the fixtures.
assert_eq "shipped .mcp.json parses" "0" \
    "$(jq empty "$SHIPPED_MCP" >/dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "shipped .mcp.json declares bd and code-graph, not code-context" "true" \
    "$(jq_get "$SHIPPED_MCP" '((.mcpServers | has("bd")) and (.mcpServers | has("code-graph")) and ((.mcpServers | has("code-context")) | not))')"

# EXISTING: an operator server (with a deliberately BARE ${SOMEVAR} arg —
# the installer must not rewrite operator config), the stale code-context
# entry, and an outdated bd entry carrying the bare ${CLAUDE_PROJECT_DIR}
# form that v3.5 shipped.
OLD_MCP="$WORK/existing-mcp.json"
cat > "$OLD_MCP" <<'JSON'
{
  "_comment": "operator's own note — must survive the upgrade",
  "operatorTopLevel": { "keep": true },
  "mcpServers": {
    "myserver": {
      "type": "stdio",
      "command": "node",
      "args": ["${SOMEVAR}/tools/myserver.js"],
      "env": { "MY_TOKEN": "${MY_TOKEN}" }
    },
    "code-context": {
      "type": "stdio",
      "command": "node",
      "args": ["${CLAUDE_PROJECT_DIR}/.claude/mcp/code-context-mcp/bin/code-context-mcp.js"],
      "env": {}
    },
    "bd": {
      "type": "stdio",
      "command": "node",
      "args": ["${CLAUDE_PROJECT_DIR}/.claude/mcp/bd-mcp/bin/bd-mcp.js"],
      "env": {}
    }
  }
}
JSON

MERGED_MCP="$WORK/merged-mcp.json"
MERGE_RC=0
run_merge "$SH_MCP_EXPR" "$OLD_MCP" "$SHIPPED_MCP" "$MERGED_MCP" || MERGE_RC=$?
assert_eq "mcp: extracted expression runs under real jq (exit 0)" "0" "$MERGE_RC"
assert_eq "mcp: merged output is valid JSON" "0" \
    "$(jq empty "$MERGED_MCP" >/dev/null 2>&1 && echo 0 || echo 1)"

assert_eq "mcp: operator server 'myserver' passes through verbatim" \
    "$(jq_sorted "$OLD_MCP" '.mcpServers.myserver')" \
    "$(jq_sorted "$MERGED_MCP" '.mcpServers.myserver')"
# shellcheck disable=SC2016 # `${SOMEVAR}` is the JSON payload under test, not a shell expansion
assert_eq "mcp: operator's bare \${SOMEVAR} is NOT rewritten by the merge" "true" \
    "$(jq_get "$MERGED_MCP" '.mcpServers.myserver.args[0] | contains("${SOMEVAR}")')"

assert_eq "mcp: retired code-context entry is deleted" "false" \
    "$(jq_get "$MERGED_MCP" '.mcpServers | has("code-context")')"

assert_eq "mcp: bd entry equals the shipped entry" \
    "$(jq_sorted "$SHIPPED_MCP" '.mcpServers.bd')" \
    "$(jq_sorted "$MERGED_MCP" '.mcpServers.bd')"
assert_eq "mcp: code-graph entry equals the shipped entry" \
    "$(jq_sorted "$SHIPPED_MCP" '.mcpServers["code-graph"]')" \
    "$(jq_sorted "$MERGED_MCP" '.mcpServers["code-graph"]')"
# The upgrade payload the plan asks for by name: the v3.5 bare form becomes
# the diagnostics-clean default form.
# shellcheck disable=SC2016 # `${CLAUDE_PROJECT_DIR:-.}` is the JSON payload under test
assert_eq "mcp: bd args carry the \${CLAUDE_PROJECT_DIR:-.} default form" "true" \
    "$(jq_get "$MERGED_MCP" '.mcpServers.bd.args[0] | contains("${CLAUDE_PROJECT_DIR:-.}")')"
assert_eq "mcp: no bd arg left in the bare \${CLAUDE_PROJECT_DIR} form" "false" \
    "$(jq_get "$MERGED_MCP" '.mcpServers.bd.args[0] | test("\\$\\{CLAUDE_PROJECT_DIR\\}")')"

assert_eq "mcp: operator top-level key survives" "true" \
    "$(jq_get "$MERGED_MCP" '.operatorTopLevel.keep')"
assert_eq "mcp: operator _comment is NOT replaced by the shipped one" \
    "operator's own note — must survive the upgrade" \
    "$(jq_get "$MERGED_MCP" '._comment // "ABSENT"')"
assert_eq "mcp: server set is exactly bd + code-graph + myserver" \
    "[\"bd\",\"code-graph\",\"myserver\"]" \
    "$(jq -c '.mcpServers | keys' "$MERGED_MCP" 2>/dev/null)"

MERGED_MCP_TWICE="$WORK/merged-mcp-twice.json"
MERGE_RC=0
run_merge "$SH_MCP_EXPR" "$MERGED_MCP" "$SHIPPED_MCP" "$MERGED_MCP_TWICE" || MERGE_RC=$?
assert_eq "mcp: second merge runs (exit 0)" "0" "$MERGE_RC"
jq -S . "$MERGED_MCP" > "$WORK/mcp-norm-1.json" 2>/dev/null
jq -S . "$MERGED_MCP_TWICE" > "$WORK/mcp-norm-2.json" 2>/dev/null
assert_eq "mcp: merge is idempotent (normalised outputs byte-identical)" "same" \
    "$(cmp -s "$WORK/mcp-norm-1.json" "$WORK/mcp-norm-2.json" && echo same || echo different)"

# ===========================================================================
echo ""
echo "=== Section 3b: merge-input validity gate (R1-F1) ==="
# Both merges bind positionally (.[0] existing, .[1] new) after `jq -s`. That
# binding is only sound if EACH input file holds exactly one JSON document.
# `jq empty` — the oracle this gate replaced — exits 0 for an empty file and
# for a multi-document stream, so a two-document target pushed the shipped file
# out to .[2] and produced a config with none of the shipped servers.

VF_SINGLE="$WORK/vf-single.json"
VF_EMPTY="$WORK/vf-empty.json"
VF_BLANK="$WORK/vf-blank.json"
VF_MULTI="$WORK/vf-multi.json"
VF_MALFORMED="$WORK/vf-malformed.json"
VF_ARRAY="$WORK/vf-array.json"
VF_SCALAR="$WORK/vf-scalar.json"

printf '{"mcpServers":{"myserver":{"command":"node"}}}\n' > "$VF_SINGLE"
: > "$VF_EMPTY"
printf '\n   \n' > "$VF_BLANK"
# Two documents: the exact shape that silently demoted the shipped config.
printf '{"mcpServers":{"myserver":{"command":"node"}}}\n{"mcpServers":{"decoy":{"command":"sh"}}}\n' > "$VF_MULTI"
printf '{ "mcpServers": \n' > "$VF_MALFORMED"
printf '[1,2,3]\n' > "$VF_ARRAY"
printf '42\n' > "$VF_SCALAR"

# validator_verdict <expr> <file> — "accepted"/"rejected", running the
# EXTRACTED gate exactly as install.sh's json_single_object() does.
validator_verdict() {
    if jq -s -e "$1" "$2" >/dev/null 2>&1; then echo accepted; else echo rejected; fi
}

# retired_oracle_verdict <file> — what the pre-fix `jq empty` check said. Kept
# so the regression is documented mechanically rather than in a comment.
retired_oracle_verdict() {
    if jq empty "$1" >/dev/null 2>&1; then echo accepted; else echo rejected; fi
}

assert_eq "gate: a single JSON object is ACCEPTED" "accepted" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_SINGLE")"
assert_eq "gate: the real shipped .mcp.json is ACCEPTED" "accepted" \
    "$(validator_verdict "$SH_VALID_EXPR" "$SHIPPED_MCP")"
assert_eq "gate: the real shipped settings.json is ACCEPTED" "accepted" \
    "$(validator_verdict "$SH_VALID_EXPR" "$SHIPPED_SETTINGS")"
assert_eq "gate: an EMPTY file is REJECTED (takes the loud fallback)" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_EMPTY")"
assert_eq "gate: a whitespace-only file is REJECTED" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_BLANK")"
assert_eq "gate: a MULTI-DOCUMENT file is REJECTED (takes the loud fallback)" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_MULTI")"
assert_eq "gate: a malformed file is REJECTED" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_MALFORMED")"
assert_eq "gate: a top-level ARRAY document is REJECTED (unindexable by the merge)" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_ARRAY")"
assert_eq "gate: a top-level scalar document is REJECTED" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_SCALAR")"

# The regression witness: the retired oracle accepted exactly the two shapes
# that corrupt the merge. If these two ever flip to "rejected", `jq empty`
# changed semantics and this whole section's premise needs revisiting.
assert_eq "gate: the retired 'jq empty' oracle ACCEPTED an empty file (the R1-F1 defect)" "accepted" \
    "$(retired_oracle_verdict "$VF_EMPTY")"
assert_eq "gate: the retired 'jq empty' oracle ACCEPTED a multi-document file (the R1-F1 defect)" "accepted" \
    "$(retired_oracle_verdict "$VF_MULTI")"

# CONSEQUENCE PROOF — what the gate is actually protecting. Feed the merge the
# multi-document target it used to accept and show the shipped servers vanish.
VF_MERGED="$WORK/vf-merged-multidoc.json"
run_merge "$SH_MCP_EXPR" "$VF_MULTI" "$SHIPPED_MCP" "$VF_MERGED" || true
assert_eq "gate: consequence — merging an accepted multi-doc target DROPS shipped bd" "false" \
    "$(jq_get "$VF_MERGED" '.mcpServers | has("bd")')"
assert_eq "gate: consequence — it DROPS shipped code-graph too" "false" \
    "$(jq_get "$VF_MERGED" '.mcpServers | has("code-graph")')"
assert_eq "gate: consequence — the target's SECOND document won the \$new binding" "true" \
    "$(jq_get "$VF_MERGED" '.mcpServers | has("decoy")')"
assert_eq "gate: which is why the gate rejects that input before the merge runs" "rejected" \
    "$(validator_verdict "$SH_VALID_EXPR" "$VF_MULTI")"

assert_eq "gate: JSON_SINGLE_OBJECT_JQ is token-identical in both installers" \
    "$(printf '%s' "$SH_VALID_EXPR" | normalize_expr)" \
    "$(printf '%s' "$PS_VALID_EXPR" | normalize_expr)"

# ===========================================================================
echo ""
echo "=== Section 4: expression identity, install.sh <-> install.ps1 (bzy #3) ==="

SH_SETTINGS_NORM=$(printf '%s' "$SH_SETTINGS_EXPR" | normalize_expr)
PS_SETTINGS_NORM=$(printf '%s' "$PS_SETTINGS_EXPR" | normalize_expr)
SH_MCP_NORM=$(printf '%s' "$SH_MCP_EXPR" | normalize_expr)
PS_MCP_NORM=$(printf '%s' "$PS_MCP_EXPR" | normalize_expr)

# Two empty strings compare equal. Pin a floor so the identity assertions
# cannot pass vacuously if extraction ever degrades to whitespace.
assert_eq "identity: normalised bash settings expression is substantial (>100 chars)" "yes" \
    "$([ "${#SH_SETTINGS_NORM}" -gt 100 ] && echo yes || echo no)"
assert_eq "identity: normalised bash mcp expression is substantial (>60 chars)" "yes" \
    "$([ "${#SH_MCP_NORM}" -gt 60 ] && echo yes || echo no)"

assert_eq "identity: SETTINGS_MERGE_JQ is token-identical in both installers" \
    "$SH_SETTINGS_NORM" "$PS_SETTINGS_NORM"
assert_eq "identity: MCP_MERGE_JQ is token-identical in both installers" \
    "$SH_MCP_NORM" "$PS_MCP_NORM"

# ===========================================================================
echo ""
echo "=== Section 5: META-TESTs (bzy #4) ==="
# Each META mutates a COPY and asserts the corresponding check above FAILS.
# Without them, a checker that always returns 0 would look identical to a
# passing suite.

# --- META 1: drop the del() call; the retired key must survive ------------
META_EXPR_NO_DEL=$(printf '%s' "$SH_SETTINGS_EXPR" | sed 's/ | del(\.CLAUDE_CODE_EFFORT_LEVEL)//')
assert_eq "META 1: the mutation actually changed the expression" "changed" \
    "$([ "$META_EXPR_NO_DEL" != "$SH_SETTINGS_EXPR" ] && echo changed || echo UNCHANGED)"
META_MERGED="$WORK/meta-no-del.json"
META_RC=0
run_merge "$META_EXPR_NO_DEL" "$OLD_LEGACY" "$NEW_SETTINGS" "$META_MERGED" || META_RC=$?
assert_eq "META 1: the mutated expression is still valid jq (exit 0)" "0" "$META_RC"
META_RC=0; check_retired_key_deleted "$META_MERGED" || META_RC=$?
assert_eq "META 1: without del(), the retired-key check FAILS (returns 1)" "1" "$META_RC"
assert_eq "META 1: and the retired key is demonstrably still there" "xhigh" \
    "$(jq_get "$META_MERGED" '.env.CLAUDE_CODE_EFFORT_LEVEL // "ABSENT"')"

# --- META 2: drop the effortLevel add-if-absent clause --------------------
# shellcheck disable=SC2016 # `$new` is jq program text inside a sed pattern
META_EXPR_NO_EFFORT=$(printf '%s' "$SH_SETTINGS_EXPR" | sed '/\.effortLevel = \$new\.effortLevel/d')
assert_eq "META 2: the mutation actually changed the expression" "changed" \
    "$([ "$META_EXPR_NO_EFFORT" != "$SH_SETTINGS_EXPR" ] && echo changed || echo UNCHANGED)"
META_MERGED_2="$WORK/meta-no-effort-clause.json"
META_RC=0
run_merge "$META_EXPR_NO_EFFORT" "$OLD_LEGACY" "$NEW_SETTINGS" "$META_MERGED_2" || META_RC=$?
assert_eq "META 2: the mutated expression is still valid jq (exit 0)" "0" "$META_RC"
META_RC=0; check_key_added "$META_MERGED_2" '.effortLevel' "xhigh" || META_RC=$?
assert_eq "META 2: without the clause, the added-key check FAILS (returns 1)" "1" "$META_RC"
# The surgical proof: only effortLevel went missing; statusLine still lands.
META_RC=0; check_key_added "$META_MERGED_2" '.statusLine.command' "$NEW_STATUSLINE" || META_RC=$?
assert_eq "META 2: the mutation is surgical — statusLine still lands" "0" "$META_RC"

# --- META 3: break one token in a COPY of the ps1 literal -----------------
# shellcheck disable=SC2016 # `$new`/`$existing` are jq program text inside a sed pattern
META_PS_EXPR=$(printf '%s' "$PS_SETTINGS_EXPR" | sed 's/\.hooks = \$new\.hooks/.hooks = $existing.hooks/')
assert_eq "META 3: the mutation actually changed the ps1 copy" "changed" \
    "$([ "$META_PS_EXPR" != "$PS_SETTINGS_EXPR" ] && echo changed || echo UNCHANGED)"
META_PS_NORM=$(printf '%s' "$META_PS_EXPR" | normalize_expr)
assert_eq "META 3: one drifted token makes the identity check FAIL" "different" \
    "$([ "$SH_SETTINGS_NORM" = "$META_PS_NORM" ] && echo same || echo different)"
# Companion: normalisation alone is not what makes them differ — the
# unmutated ps1 literal still matches after the same normalisation.
assert_eq "META 3 companion: the unmutated ps1 literal still matches" "same" \
    "$([ "$SH_SETTINGS_NORM" = "$PS_SETTINGS_NORM" ] && echo same || echo different)"

# --- META 4: extraction from a file with no sentinels ---------------------
# Proves section 1's fail-loud arm is reachable: a renamed/removed sentinel
# yields an empty extraction and a zero sentinel count, not a silent pass.
META_NO_SENTINEL="$WORK/no-sentinels.sh"
cat > "$META_NO_SENTINEL" <<'FIXTURE'
#!/bin/bash
SETTINGS_MERGE_JQ='
    .[0] as $existing |
    .[1] as $new |
    $existing | .hooks = $new.hooks
'
jq -s "$SETTINGS_MERGE_JQ" a.json b.json
FIXTURE
assert_eq "META 4: a file without sentinels yields an EMPTY extraction" "EMPTY" \
    "$([ -n "$(extract_expr "$META_NO_SENTINEL" "SETTINGS_MERGE_JQ" | tr -d '[:space:]')" ] && echo non-empty || echo EMPTY)"
assert_eq "META 4: and its BEGIN-sentinel count is 0" "0" \
    "$(sentinel_line_count "$META_NO_SENTINEL" "# BEGIN SETTINGS_MERGE_JQ")"

# --- META 5: a duplicated definition is caught ----------------------------
# The drift shape this spec exists to prevent: a second copy pasted back in.
META_DUP="$WORK/duplicated.sh"
{
    cat "$META_NO_SENTINEL"
    printf '# BEGIN SETTINGS_MERGE_JQ\n'
    printf 'SETTINGS_MERGE_JQ_COPY=1\n'
    printf '# END SETTINGS_MERGE_JQ\n'
    printf '# BEGIN SETTINGS_MERGE_JQ\n'
    printf 'SETTINGS_MERGE_JQ_COPY2=1\n'
    printf '# END SETTINGS_MERGE_JQ\n'
} > "$META_DUP"
assert_eq "META 5: two definitions make the exactly-once check FAIL (count 2)" "2" \
    "$(sentinel_line_count "$META_DUP" "# BEGIN SETTINGS_MERGE_JQ")"

# --- META 6 (R1-F1): weaken the gate back to pre-fix semantics -------------
# `length >= 1` is exactly what `jq empty` meant: "at least one document parses".
# Under it the multi-document rejection must FAIL — which is the assertion the
# whole of section 3b rests on.
META_VALID_WEAK=$(printf '%s' "$SH_VALID_EXPR" | sed 's/length == 1/length >= 1/')
assert_eq "META 6: the mutation actually changed the gate expression" "changed" \
    "$([ "$META_VALID_WEAK" != "$SH_VALID_EXPR" ] && echo changed || echo UNCHANGED)"
assert_eq "META 6: the weakened gate is still valid jq (single object accepted)" "accepted" \
    "$(validator_verdict "$META_VALID_WEAK" "$VF_SINGLE")"
assert_eq "META 6: with length >= 1 the MULTI-DOC rejection FAILS (accepted again)" "accepted" \
    "$(validator_verdict "$META_VALID_WEAK" "$VF_MULTI")"
# And the object arm is separately load-bearing: drop it and an array passes.
META_VALID_NOOBJ=$(printf '%s' "$SH_VALID_EXPR" | sed 's/ and (\.\[0\] | type == "object")//')
assert_eq "META 6: dropping the object arm actually changed the expression" "changed" \
    "$([ "$META_VALID_NOOBJ" != "$SH_VALID_EXPR" ] && echo changed || echo UNCHANGED)"
assert_eq "META 6: without the object arm a top-level ARRAY is accepted again" "accepted" \
    "$(validator_verdict "$META_VALID_NOOBJ" "$VF_ARRAY")"

# --- META 7 (R1-F2): revert the presence guard to truthiness ---------------
# The pre-fix shape. Under it an operator's explicit null must be clobbered —
# so the null-preservation assertion FAILS, proving it is not vacuous.
# shellcheck disable=SC2016 # `$existing` is jq program text inside sed patterns
META_EXPR_TRUTHY=$(printf '%s' "$SH_SETTINGS_EXPR" \
    | sed -e 's/(\$existing | has("effortLevel"))/$existing.effortLevel/' \
          -e 's/(\$existing | has("statusLine"))/$existing.statusLine/')
assert_eq "META 7: the mutation actually changed the expression" "changed" \
    "$([ "$META_EXPR_TRUTHY" != "$SH_SETTINGS_EXPR" ] && echo changed || echo UNCHANGED)"
META_MERGED_3="$WORK/meta-truthiness.json"
META_RC=0
run_merge "$META_EXPR_TRUTHY" "$OLD_FALSY" "$NEW_SETTINGS" "$META_MERGED_3" || META_RC=$?
assert_eq "META 7: the mutated expression is still valid jq (exit 0)" "0" "$META_RC"
assert_eq "META 7: under truthiness the operator's effortLevel:null is CLOBBERED" '"xhigh"' \
    "$(jq -c '.effortLevel' "$META_MERGED_3" 2>/dev/null)"
# The operator wrote a boolean; under truthiness it comes back as the shipped
# statusLine OBJECT. Comparing types states the clobber unambiguously.
assert_eq "META 7: under truthiness the operator's statusLine:false is CLOBBERED (boolean -> shipped object)" "object" \
    "$(jq -r '.statusLine | type' "$META_MERGED_3" 2>/dev/null)"
# The surgical proof: permissions was NOT part of this mutation, so it still
# survives — a blanket breakage would have taken it out too.
assert_eq "META 7: the mutation is surgical — permissions:null still preserved" "null" \
    "$(jq -c '.permissions' "$META_MERGED_3" 2>/dev/null)"

# --- Summary ---------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

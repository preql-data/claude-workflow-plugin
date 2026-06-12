#!/bin/bash
# agent-mcp-tools-parity.test.sh — claude-workflow-plugin-366.6.
#
# Asserts MCP-tool parity between every agent prompt body and the
# agent's `tools:` frontmatter allowlist:
#
#   For each agent file under .claude/agents/ that declares a `tools:`
#   frontmatter line (an allowlist; omitting `tools:` inherits everything
#   per code.claude.com/docs/en/sub-agents): if the agent's prompt body
#   references a plugin-MCP tool by name (impact_of, code_index_health,
#   bd_doc_read, etc.), the `tools:` line must include a matching grant
#   for that tool's server — either:
#
#     (a) the server-qualified prefix `mcp__plugin_claude-workflow_<server>`
#         and/or the project-scope prefix `mcp__<server>` as a bare grant
#         (code.claude.com/docs/en/permissions: "mcp__puppeteer matches
#         any tool provided by the puppeteer server"); or
#     (b) the wildcard form `mcp__<...>__*` covering the server; or
#     (c) the per-tool form `mcp__<...>__<tool_name>` enumerating the
#         specific tool the body uses.
#
# Motivation: Phase B live trace
# (cassettes/seed/node-react-auth-2026-06-11T23-34-49-784Z.jsonl) showed
# QA subagents make 0 `impact_of` calls and report "code-graph MCP
# unavailable" — accurate from QA's perspective because qa.md's `tools:`
# frontmatter enumerates a fixed list with no `mcp__*` entries, so the
# SDK strips every MCP tool from QA's surface. CLAUDE.md names the
# antipattern: "Specialist tool list narrowed below the broad set ->
# specialist hits an 'unauthorized tool' wall mid-task." This test
# encodes the parity property so the regression cannot reach live again.
#
# Exemption (grader.md): the grader is read-only by design (Read, Grep,
# Glob, LS) and has no MCP tool calls in its prompt body. The exemption
# is encoded as a hard-coded list of agent names; if you exempt a new
# agent, document why directly in the exemption block.
#
# Includes a META-TEST with two fixtures:
#   1. an agent file with body-mentioned MCP tool absent from tools: ->
#      checker fails
#   2. the same agent file with the matching server-level grant added ->
#      checker passes
# These prove the checker is sensitive in both directions.
#
# Exit codes:
#   0 — real repo passes parity AND both META-TEST fixtures behave as
#       expected
#   1 — one or more assertions failed
#   2 — invocation error (missing files, no awk)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
AGENTS_DIR="$PROJECT_DIR/.claude/agents"

# Agents exempt-by-design: each exemption MUST come with a one-line
# justification next to the entry. The exemption block is the audit
# trail; future editors who add a new exemption must justify it the
# same way.
EXEMPT_AGENTS=(
    # grader.md — separate-context rubric grader with read-only tool
    # set (Read, Grep, Glob, LS). Its prompt body has no MCP tool
    # references; it scores a pre-assembled packet. No MCP grants
    # needed.
    "grader"
    # judge.md — separate-context mutation judge with the same
    # read-only tool set (Read, Grep, Glob, LS). Its prompt body has
    # no MCP tool references; it classifies survivors from a packet
    # the orchestrator hands it. No MCP grants needed (Phase C.2).
    "judge"
)

# Tool-to-server registry. Hard-coded so the checker stays offline (no
# server boot). Update this list when a tool is added to bd-mcp or
# code-graph-mcp; the agent-bodies sweep will then surface the new tool
# and the parity check will require the corresponding grant.
#
# Form: "<tool_name>\t<server_name>"
MCP_TOOL_REGISTRY=$(cat <<'EOF'
impact_of	code-graph
code_search	code-graph
code_context	code-graph
code_index_health	code-graph
symbol_callers	code-graph
dead_code	code-graph
dependency_path	code-graph
bd_create_task	bd
bd_create_epic	bd
bd_update_task	bd
bd_close_task	bd
bd_show_task	bd
bd_list_tasks	bd
bd_get_ready	bd
bd_get_blocked	bd
bd_add_label	bd
bd_remove_label	bd
bd_list_labels	bd
bd_add_comment	bd
bd_list_comments	bd
bd_add_dep	bd
bd_list_deps	bd
bd_doc_read	bd
bd_doc_write	bd
bd_qa_enter	bd
bd_qa_status	bd
bd_qa_approve	bd
bd_qa_block	bd
EOF
)

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

# extract_frontmatter_field <agent_file> <field>
#   Echoes the value of the named field from the YAML frontmatter block
#   (between the first and second `---`). Empty if the field is absent.
extract_frontmatter_field() {
    local file="$1" field="$2"
    awk -v field="$field" '
        BEGIN { in_fm = 0; seen = 0 }
        NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
        in_fm && /^---[[:space:]]*$/ { in_fm = 0; exit }
        in_fm && $1 == field":" {
            # Strip leading "<field>:" and trim whitespace.
            sub("^[[:space:]]*"field"[[:space:]]*:[[:space:]]*", "", $0)
            print $0
            exit
        }
    ' "$file"
}

# has_tools_line <agent_file>
#   Returns 0 if the file declares a `tools:` line in frontmatter,
#   1 if not.
has_tools_line() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0; found = 1 }
        NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
        in_fm && /^---[[:space:]]*$/ { exit }
        in_fm && /^[[:space:]]*tools[[:space:]]*:/ { found = 0; exit }
        END { exit found }
    ' "$file"
}

# get_agent_body <agent_file>
#   Echoes everything after the closing `---` of the frontmatter.
get_agent_body() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0; past_fm = 0 }
        NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
        in_fm && /^---[[:space:]]*$/ { in_fm = 0; past_fm = 1; next }
        past_fm { print }
    ' "$file"
}

# tools_grants_server <tools_line> <server_name> <tool_name>
#   Returns 0 if the tools: allowlist grants access to <tool_name> from
#   <server_name>, 1 otherwise. Honors the three documented grant forms:
#     (a) server-level    mcp__<server>           or
#                          mcp__plugin_claude-workflow_<server>
#     (b) server wildcard mcp__<server>__*        or
#                          mcp__plugin_claude-workflow_<server>__*
#     (c) per-tool        mcp__<server>__<tool>   or
#                          mcp__plugin_claude-workflow_<server>__<tool>
tools_grants_server() {
    local tools_line="$1" server="$2" tool="$3"
    # Split the tools line on commas; trim each token.
    # Match forms:
    #   mcp__<server>                       — bare server name
    #   mcp__<server>__*                    — server wildcard
    #   mcp__<server>__<tool>               — explicit tool
    #   mcp__plugin_claude-workflow_<server>          — bare prefix
    #   mcp__plugin_claude-workflow_<server>__*       — prefix wildcard
    #   mcp__plugin_claude-workflow_<server>__<tool>  — prefix explicit
    local IFS=','
    # shellcheck disable=SC2086 # intentional word-splitting on $IFS=','
    set -- $tools_line
    local tok
    for tok in "$@"; do
        # Trim leading/trailing whitespace.
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        case "$tok" in
            "mcp__${server}"|"mcp__plugin_claude-workflow_${server}")
                return 0
                ;;
            "mcp__${server}__*"|"mcp__plugin_claude-workflow_${server}__*")
                return 0
                ;;
            "mcp__${server}__${tool}"|"mcp__plugin_claude-workflow_${server}__${tool}")
                return 0
                ;;
        esac
    done
    return 1
}

# is_exempt <agent_name>
#   Returns 0 if the agent is in the exemption list.
is_exempt() {
    local agent="$1" e
    for e in "${EXEMPT_AGENTS[@]}"; do
        if [ "$e" = "$agent" ]; then
            return 0
        fi
    done
    return 1
}

# check_agent <agent_file>
#   Returns 0 if the agent satisfies parity (no tools: line OR every
#   body-mentioned MCP tool is granted in tools:), 1 otherwise.
#   Returns 2 on invocation error.
check_agent() {
    local file="$1"
    if [ ! -f "$file" ]; then
        printf '    (check_agent) file not found: %s\n' "$file" >&2
        return 2
    fi
    local name
    name=$(extract_frontmatter_field "$file" name)
    if [ -z "$name" ]; then
        # No name: derive from filename for the error message.
        name=$(basename "$file" .md)
    fi
    if is_exempt "$name"; then
        # Exemption: agent is expected to have no MCP grants; the body
        # is not scanned. The justification lives in the EXEMPT_AGENTS
        # block above.
        return 0
    fi
    if ! has_tools_line "$file"; then
        # No tools: line means inherit everything, including all MCP
        # tools. Parity holds trivially.
        return 0
    fi
    local tools_line
    tools_line=$(extract_frontmatter_field "$file" tools)
    local body
    body=$(get_agent_body "$file")

    local missing=0
    local IFS_save="$IFS"
    while IFS=$'\t' read -r tool server; do
        [ -z "$tool" ] && continue
        # Whole-word match: tool name must appear as its own token in the
        # body. The simplest cheap check: literal substring with word
        # boundary on at least one side. grep -wF supports this for
        # alphanumeric+underscore tokens.
        if printf '%s' "$body" | grep -wF -q "$tool"; then
            if ! tools_grants_server "$tools_line" "$server" "$tool"; then
                printf '    (check_agent) %s: body references MCP tool %s (server=%s) but tools: line does not grant it\n' \
                    "$file" "$tool" "$server" >&2
                missing=1
            fi
        fi
    done <<< "$MCP_TOOL_REGISTRY"
    IFS="$IFS_save"

    if [ "$missing" = "1" ]; then
        return 1
    fi
    return 0
}

# --- Real repo ----------------------------------------------------------

if [ ! -d "$AGENTS_DIR" ]; then
    printf 'agent-mcp-tools-parity: agents dir not found: %s\n' "$AGENTS_DIR" >&2
    exit 2
fi

ANY_FAIL=0
for f in "$AGENTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    if check_agent "$f"; then
        : # PASS — keep going.
    else
        rc=$?
        if [ "$rc" -eq 2 ]; then exit 2; fi
        ANY_FAIL=1
    fi
done
assert_eq "agent-mcp-tools-parity: real repo holds parity" "0" "$ANY_FAIL"

# --- META-TEST 1: gap (body references a tool that tools: omits) -------

FIX1_TMP=$(mktemp -d -t agent-mcp-parity-fix1.XXXXXX)
mkdir -p "$FIX1_TMP/.claude/agents"
cat > "$FIX1_TMP/.claude/agents/qa.md" <<'MD'
---
name: qa
description: stub qa
tools: Read, Bash
---

Test body referencing the impact_of tool from code-graph:

`impact_of({symbol: "X", max_depth: 5})`
MD

# Drive the checker against the META-TEST agents dir. We re-export
# CLAUDE_PROJECT_DIR so PROJECT_DIR resolves correctly INSIDE check_agent
# (which uses absolute paths derived from the per-test invocation).
if check_agent "$FIX1_TMP/.claude/agents/qa.md"; then
    rc_meta1=0
else
    rc_meta1=$?
fi
assert_eq "META-TEST 1: body mentions impact_of but tools: lacks grant trips the checker" "1" "$rc_meta1"

# --- META-TEST 2: same file, with the matching grant added ------------

cat > "$FIX1_TMP/.claude/agents/qa.md" <<'MD'
---
name: qa
description: stub qa
tools: Read, Bash, mcp__plugin_claude-workflow_code-graph, mcp__code-graph
---

Test body referencing the impact_of tool from code-graph:

`impact_of({symbol: "X", max_depth: 5})`
MD

if check_agent "$FIX1_TMP/.claude/agents/qa.md"; then
    rc_meta2=0
else
    rc_meta2=$?
fi
assert_eq "META-TEST 2: same body with server-level mcp__ grant passes" "0" "$rc_meta2"

rm -rf "$FIX1_TMP"

# --- META-TEST 3: exempt agent name shortcircuits ----------------------

FIX3_TMP=$(mktemp -d -t agent-mcp-parity-fix3.XXXXXX)
mkdir -p "$FIX3_TMP/.claude/agents"
cat > "$FIX3_TMP/.claude/agents/grader.md" <<'MD'
---
name: grader
description: stub grader
tools: Read, Grep
---

This grader stub mentions impact_of in its body but is exempted from
the parity check by design (read-only tool set, no MCP needed).
MD

if check_agent "$FIX3_TMP/.claude/agents/grader.md"; then
    rc_meta3=0
else
    rc_meta3=$?
fi
assert_eq "META-TEST 3: exempt agent (grader) is shortcircuited" "0" "$rc_meta3"

rm -rf "$FIX3_TMP"

# --- META-TEST 4: no tools: line means inherit everything --------------

FIX4_TMP=$(mktemp -d -t agent-mcp-parity-fix4.XXXXXX)
mkdir -p "$FIX4_TMP/.claude/agents"
cat > "$FIX4_TMP/.claude/agents/no-tools.md" <<'MD'
---
name: no-tools
description: stub agent without tools: line
---

Body references impact_of but the agent has no tools: line, so it
inherits everything including MCP tools.
MD

if check_agent "$FIX4_TMP/.claude/agents/no-tools.md"; then
    rc_meta4=0
else
    rc_meta4=$?
fi
assert_eq "META-TEST 4: no tools: line means inherit all (parity holds)" "0" "$rc_meta4"

rm -rf "$FIX4_TMP"

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

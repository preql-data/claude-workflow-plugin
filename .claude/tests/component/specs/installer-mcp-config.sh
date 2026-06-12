#!/bin/bash
# installer-mcp-config.sh - L2 component spec for 0.1 (MCP path resolution).
#
# Covers Phase 0.1 (claude-workflow-plugin-e0d.1). Runs the real install.sh
# non-interactively into a fresh tempdir and asserts the rendered .mcp.json:
#
#   1. Parses as JSON.
#   2. Contains no bare `${VAR}` reference (the form that the Claude Code MCP
#      docs warn about for project-scoped configs:
#      https://code.claude.com/docs/en/mcp — "referencing it via ${VAR}
#      expansion in a project- or user-scoped .mcp.json command or args
#      requires a default such as ${CLAUDE_PROJECT_DIR:-.}"). The check
#      grep-walks command/args/env/url/headers values; a match without a
#      `:-` default form is a fail.
#
#   META-TEST: feed the asserter a synthetic config containing a bare
#   ${CLAUDE_PROJECT_DIR} and assert the check FAILS. This proves the
#   asserter is sensitive to the bug the regular assertions claim to catch.
#
# The spec deliberately does NOT require bd (the install.sh prerequisites
# include bd, but we just need the file-copy step to run — we set a stub
# bd on PATH to satisfy the prereq check without depending on the real CLI).

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# We need an isolated install target outside the fixture (the install
# itself writes to .claude/ and .claude-plugin/ which would conflict with
# the fixture's pre-built scaffold from mk_fixture). Use a sibling tempdir.
INSTALL_TARGET=$(mktemp -d -t cwp-install-test.XXXXXX)
__COMPONENT_FIXTURES_TO_CLEAN+=("$INSTALL_TARGET")

PLUGIN_ROOT=$(plugin_root)

# Helper: emit the asserter's exit code without aborting the spec. The
# asserter walks command/args/env/url/headers values in every mcpServers
# entry and reports a bare-form match as a failure. Pure jq; no shell
# string ops on JSON.
#
# Args:
#   $1 — path to a .mcp.json file to inspect
# Returns:
#   0 if no bare ${VAR} references found in MCP server fields
#   1 if any bare ${VAR} reference was found (the bug)
#   2 if jq fails / file unreadable
assert_no_unresolved_vars() {
    local cfg="$1"
    if [ ! -f "$cfg" ]; then
        printf '    diagnostic: %s does not exist\n' "$cfg" >&2
        return 2
    fi
    if ! jq empty "$cfg" >/dev/null 2>&1; then
        printf '    diagnostic: %s is not valid JSON\n' "$cfg" >&2
        return 2
    fi
    # Walk every string value inside mcpServers.*.{command,args,env,url,headers}.
    # We tolerate _-prefixed top-level keys (comments, forward-pointer
    # blocks like _phase7_codebase_graph_target are intentionally not in
    # mcpServers and not loaded by Claude Code, so a bare ${VAR} there is
    # diagnostic-only and not a real warning source). To be defensive
    # against future entries graduating into mcpServers, we also walk
    # any sibling block keyed under mcpServers OR matching the shape
    # {type,command,args} — and surface findings either way.
    local hits
    hits=$(jq -r '
        def walk_strings:
            if type == "string" then [.]
            elif type == "array" then map(walk_strings) | add // []
            elif type == "object" then [.[] | walk_strings] | add // []
            else [] end;
        # Active surface: every mcpServers entry, every field that may
        # carry an expanded var (command/args/env/url/headers).
        (.mcpServers // {}) | to_entries | map(
            .key as $name | .value |
            (.command, .args, .env, .url, .headers) | walk_strings
        ) | add // []
        # Find bare ${VAR} that lacks a :- default. Match conservatively:
        # ${BARE} with no colon-minus inside the braces.
        | map(select(test("\\$\\{[A-Z_][A-Z0-9_]*\\}")))
        | .[]
    ' "$cfg" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        printf '    diagnostic: bare ${VAR} reference(s) found:\n' >&2
        printf '%s\n' "$hits" | sed 's/^/      - /' >&2
        return 1
    fi
    return 0
}

# Pre-flight: install.sh requires bd on PATH; install.sh also requires
# git + jq (both present on dev machines and CI). We're inside the L2
# fixture which already prepended a bd wrapper onto PATH (mk_fixture) so
# the prerequisite check passes. Confirm.
bd_required_or_skip
command -v bd >/dev/null 2>&1 || {
    printf '    diagnostic: bd shim somehow absent post-mk_fixture; aborting\n' >&2
    exit 1
}

# Initialise a git repo inside INSTALL_TARGET so install.sh's interactive
# "Initialize git repository?" prompt is bypassed (the existing-repo branch
# is unconditional).
(
    cd "$INSTALL_TARGET" || exit 1
    git init -q >/dev/null 2>&1 || true
    # An empty commit is enough to keep `git rev-parse HEAD` happy if
    # any downstream step needs a commit hash.
    git -c user.email=test@example.com -c user.name=test \
        commit --allow-empty -m "test baseline" -q >/dev/null 2>&1 || true
)

# Run the real installer non-interactively. --mode=1 is the
# "Backup and install fresh" mode; combined with stdin redirected from
# /dev/null we force the "Fully non-interactive" path and avoid any
# /dev/tty fallbacks. We capture stdout+stderr but only surface the tail
# on failure (the install is chatty).
INSTALL_LOG=$(mktemp -t cwp-install.XXXXXX)
__COMPONENT_FIXTURES_TO_CLEAN+=("$INSTALL_LOG")
INSTALL_RC=0
bash "$PLUGIN_ROOT/install.sh" --mode=1 "$INSTALL_TARGET" \
    </dev/null >"$INSTALL_LOG" 2>&1 || INSTALL_RC=$?

if [ "$INSTALL_RC" -ne 0 ]; then
    printf '  diagnostic: install.sh exited %s; tail of log:\n' "$INSTALL_RC"
    tail -20 "$INSTALL_LOG" | sed 's/^/    /'
fi
assert_eq "installer-mcp-config: install.sh exit 0" "0" "$INSTALL_RC"

RENDERED_MCP="$INSTALL_TARGET/.mcp.json"
assert_eq "installer-mcp-config: rendered .mcp.json present" "0" \
    "$([ -f "$RENDERED_MCP" ] && echo 0 || echo 1)"

# 1. Parses as JSON.
JSON_RC=0
jq empty "$RENDERED_MCP" >/dev/null 2>&1 || JSON_RC=$?
assert_eq "installer-mcp-config: rendered .mcp.json parses as JSON" "0" "$JSON_RC"

# 2. No bare ${VAR} references in command/args/env/url/headers of any
#    mcpServers entry.
ASSERT_RC=0
assert_no_unresolved_vars "$RENDERED_MCP" || ASSERT_RC=$?
assert_eq "installer-mcp-config: no bare \${VAR} in mcpServers fields" "0" "$ASSERT_RC"

# 3. Spot-check: both expected servers are wired.
#    Phase B (v3.3.0) replaces code-context with code-graph; the entry
#    key is "code-graph" and the launcher path lives under
#    .claude/mcp/code-graph-mcp/. The old code-context entry MUST be
#    absent — leaving it would shadow the new server and produce a
#    diagnostics warning for a launcher path that no longer exists.
BD_ARGS=$(jq -r '.mcpServers.bd.args[0] // empty' "$RENDERED_MCP")
CG_ARGS=$(jq -r '.mcpServers["code-graph"].args[0] // empty' "$RENDERED_MCP")
CC_PRESENT=$(jq -r '.mcpServers["code-context"] // empty | length' "$RENDERED_MCP")
assert_contains "installer-mcp-config: bd server args reference bd-mcp" \
    "bd-mcp/bin/bd-mcp.js" "$BD_ARGS"
assert_contains "installer-mcp-config: code-graph server args reference code-graph-mcp" \
    "code-graph-mcp/bin/code-graph-mcp.js" "$CG_ARGS"
# Confirm the default form is present (positive case complementing the
# negative bare-form check above).
assert_contains "installer-mcp-config: bd args use :- default form" \
    '${CLAUDE_PROJECT_DIR:-.}' "$BD_ARGS"
assert_contains "installer-mcp-config: code-graph args use :- default form" \
    '${CLAUDE_PROJECT_DIR:-.}' "$CG_ARGS"
# Phase B migration: the retired code-context entry must be gone. A
# silent leftover here would mean the installer (or this spec) was
# updated only partially — the rendered .mcp.json would still try to
# spawn a launcher under a directory that the installer no longer
# copies.
assert_eq "installer-mcp-config: retired code-context server is absent from rendered .mcp.json" \
    "" "$CC_PRESENT"

# 3a. The code-graph-mcp directory must be present in the rendered
#     install (the generic MCP copy loop in install.sh globs
#     .claude/mcp/*/ — this is the spot-check that the loop picked it
#     up). The retired code-context-mcp directory must NOT have been
#     copied; the source tree no longer contains it (B.2 deleted it
#     in the same commit family as this assertion), so a copy here
#     would indicate the source had been resurrected.
assert_eq "installer-mcp-config: rendered install has .claude/mcp/code-graph-mcp/" "0" \
    "$([ -d "$INSTALL_TARGET/.claude/mcp/code-graph-mcp" ] && echo 0 || echo 1)"
assert_eq "installer-mcp-config: rendered install does NOT have .claude/mcp/code-context-mcp/" "0" \
    "$([ ! -e "$INSTALL_TARGET/.claude/mcp/code-context-mcp" ] && echo 0 || echo 1)"

# 3b. Spot-check that the vendored grammars rode along with the MCP
#     copy. The grammars directory is ~9.6 MB and the install.sh copy
#     uses rsync (or cp -R fallback) on the whole server dir, so any
#     of the 10 .wasm grammars is a reasonable single spot-check. If
#     this fails, the copy mechanism is skipping non-source files
#     (the rsync exclude patterns ship node_modules and *.log only;
#     anything else missing is a real regression).
assert_eq "installer-mcp-config: rendered install has at least one tree-sitter wasm grammar" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/mcp/code-graph-mcp/grammars/tree-sitter-typescript.wasm" ] && echo 0 || echo 1)"

# 3c. Phase A (v3.2.0) + Phase C (v3.4.0) surface presence.
#     The plugin manifest's agents[] declares all seven agents; if a
#     declared agent file is missing from the rendered install,
#     Claude Code will warn at session-start and the workflow will
#     degrade silently (a delegation Task call hits an unloaded
#     agent type and falls through to general-purpose). The same
#     applies to the @judge subagent path declared by /mutation-sweep
#     and the rubric files the grader reads. These assertions guard
#     install.sh against forgetting a newly-shipped agent / tier when
#     subsequent versions land more.
assert_eq "installer-mcp-config: rendered install has grader.md (Phase A)" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/agents/grader.md" ] && echo 0 || echo 1)"
assert_eq "installer-mcp-config: rendered install has judge.md (Phase C)" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/agents/judge.md" ] && echo 0 || echo 1)"
assert_eq "installer-mcp-config: rendered install has .claude/rubrics/default.md (Phase A)" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/rubrics/default.md" ] && echo 0 || echo 1)"
assert_eq "installer-mcp-config: rendered install has .claude/rubric-config (Phase A)" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/rubric-config" ] && echo 0 || echo 1)"
assert_eq "installer-mcp-config: rendered install has .claude/tests/mutation/mutation-sweep.sh (Phase C)" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/tests/mutation/mutation-sweep.sh" ] && echo 0 || echo 1)"
assert_eq "installer-mcp-config: rendered install has .claude/tests/mutation/judge-gate.sh (Phase C)" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/tests/mutation/judge-gate.sh" ] && echo 0 || echo 1)"
assert_eq "installer-mcp-config: rendered install has .claude/tests/mutation/calibration/calibration-set.json (Phase C)" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/tests/mutation/calibration/calibration-set.json" ] && echo 0 || echo 1)"
assert_eq "installer-mcp-config: rendered install has .claude/commands/mutation-sweep.md (Phase C)" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/commands/mutation-sweep.md" ] && echo 0 || echo 1)"
# Phase 0 (v3.1.0) — lessons ledger + model-ranking + worktreeinclude
# are user-discoverable assets the orchestrator + SessionStart hooks
# expect at the repo root / .claude/ root respectively.
assert_eq "installer-mcp-config: rendered install has LESSONS.md (Phase 0)" "0" \
    "$([ -f "$INSTALL_TARGET/LESSONS.md" ] && echo 0 || echo 1)"
assert_eq "installer-mcp-config: rendered install has .claude/model-ranking (Phase 0)" "0" \
    "$([ -f "$INSTALL_TARGET/.claude/model-ranking" ] && echo 0 || echo 1)"

# 4. META-TEST: feed the asserter a synthetic config with a bare
#    ${CLAUDE_PROJECT_DIR} (the exact bug shape the asserter must catch).
#    The asserter MUST return non-zero. If this passes through, the
#    asserter is too weak and the regular assertions above are theatre.
META_BAD=$(mktemp -t cwp-mcp-meta.XXXXXX)
__COMPONENT_FIXTURES_TO_CLEAN+=("$META_BAD")
cat > "$META_BAD" <<'JSON'
{
  "mcpServers": {
    "broken": {
      "type": "stdio",
      "command": "node",
      "args": ["${CLAUDE_PROJECT_DIR}/.claude/mcp/broken/bin/broken.js"],
      "env": {}
    }
  }
}
JSON
META_RC=0
assert_no_unresolved_vars "$META_BAD" >/dev/null 2>&1 || META_RC=$?
assert_eq "installer-mcp-config META-TEST: asserter fails on bare \${CLAUDE_PROJECT_DIR}" \
    "1" "$META_RC"

# 5. META-TEST companion: the default form ${CLAUDE_PROJECT_DIR:-.} must
#    pass through. Without this we can't tell if the META-TEST is failing
#    because the asserter is unconditionally permissive vs because the
#    asserter actually distinguishes the two forms. Two META-TESTs
#    together pin the asserter's discrimination.
META_GOOD=$(mktemp -t cwp-mcp-meta-ok.XXXXXX)
__COMPONENT_FIXTURES_TO_CLEAN+=("$META_GOOD")
cat > "$META_GOOD" <<'JSON'
{
  "mcpServers": {
    "ok": {
      "type": "stdio",
      "command": "node",
      "args": ["${CLAUDE_PROJECT_DIR:-.}/.claude/mcp/ok/bin/ok.js"],
      "env": {}
    }
  }
}
JSON
META_OK_RC=0
assert_no_unresolved_vars "$META_GOOD" >/dev/null 2>&1 || META_OK_RC=$?
assert_eq "installer-mcp-config META-TEST: asserter passes on \${CLAUDE_PROJECT_DIR:-.}" \
    "0" "$META_OK_RC"

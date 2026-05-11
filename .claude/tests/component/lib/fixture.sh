#!/bin/bash
# fixture.sh - Tempdir fixture builder for component-tier hook tests.
#
# Phase B (claude-workflow-plugin-0wk.11). Encapsulates the per-spec setup
# pattern: mktemp -d, scaffold .claude/.qa-tracking + .beads + scripts,
# install a bd wrapper (avoids daemon races on tempdir DBs), set
# CLAUDE_PROJECT_DIR, register cleanup. Specs call mk_fixture once, get
# back a path, and write/read against $FIXTURE/.claude/.qa-tracking/...
#
# Functions:
#   mk_fixture
#       Builds a fresh temp project root with:
#         - .claude/.qa-tracking/        (empty)
#         - .claude/scripts/             (symlinks to plugin's real scripts)
#         - .claude/settings.json        (minimal manifest, hooks-aware)
#         - .beads/                      (initialised via `bd init`)
#         - bin/bd                       (--no-daemon wrapper of real bd)
#       Exports CLAUDE_PROJECT_DIR + COMPONENT_FIXTURE_PATH and prepends
#       the fixture's bin/ to PATH.
#
#       CRITICAL: callers must invoke mk_fixture WITHOUT command substitution
#       so the exports reach the caller's shell:
#           mk_fixture
#           FIXTURE="$COMPONENT_FIXTURE_PATH"
#       NOT `FIXTURE=$(mk_fixture)` — that runs in a subshell and the
#       exported CLAUDE_PROJECT_DIR / PATH mutations are discarded.
#
#       Honours $KEEP_FIXTURE — when set to "1" the cleanup trap leaves the
#       directory in place and prints its path on exit.
#
#   cleanup_fixture <path>
#       Remove a fixture path. Idempotent. Called automatically by the trap
#       installed by mk_fixture, but exposed for specs that build multiple.
#
#   plugin_root
#       Absolute path of the plugin root (computed once, cached). Used for
#       resolving the real hook scripts to symlink/copy into the fixture.

if [ -n "${__COMPONENT_FIXTURE_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
__COMPONENT_FIXTURE_SH_SOURCED=1

# Best-effort: source shim.sh for mk_bd_shim. The runner sources both, but
# this lets specs stand-alone in interactive debugging.
if [ -z "${__COMPONENT_SHIM_SH_SOURCED:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/shim.sh" ]; then
    # shellcheck source=./shim.sh
    . "$(dirname "${BASH_SOURCE[0]}")/shim.sh"
fi

__PLUGIN_ROOT_CACHE=""

plugin_root() {
    if [ -z "$__PLUGIN_ROOT_CACHE" ]; then
        # This file is at <plugin>/.claude/tests/component/lib/fixture.sh.
        # Resolve plugin root by going up four dirs.
        local self
        self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
        __PLUGIN_ROOT_CACHE=$(cd "$self/../../../.." && pwd)
    fi
    printf '%s' "$__PLUGIN_ROOT_CACHE"
}

# Global trap state. The runner spawns each spec in a subshell, so traps
# don't leak between specs.
__COMPONENT_FIXTURES_TO_CLEAN=()

__component_fixture_cleanup() {
    # Bash 3.2 under `set -u` errors on empty-array `${a[@]}` expansion.
    # Guard with the array's length (which is always defined as 0 even
    # when no elements have been appended).
    if [ "${#__COMPONENT_FIXTURES_TO_CLEAN[@]}" -eq 0 ]; then
        return
    fi
    if [ "${KEEP_FIXTURE:-0}" = "1" ]; then
        local d
        for d in "${__COMPONENT_FIXTURES_TO_CLEAN[@]}"; do
            printf 'Fixture kept at: %s\n' "$d"
        done
        return
    fi
    local d
    for d in "${__COMPONENT_FIXTURES_TO_CLEAN[@]}"; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
}

# Install the trap only once per shell.
if [ -z "${__COMPONENT_FIXTURE_TRAP_INSTALLED:-}" ]; then
    trap __component_fixture_cleanup EXIT
    __COMPONENT_FIXTURE_TRAP_INSTALLED=1
fi

cleanup_fixture() {
    local d="$1"
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
}

# bd_required_or_skip — spec-level skip-with-log gate for environments that
# don't have the real `bd` CLI on PATH. Two-mode behaviour, chosen by env:
#
#   - Dev machine (bd present): returns 0; the spec proceeds normally.
#   - CI runner (BD_SHIM_ONLY=1 set, bd absent): prints a "SKIPPED:" line
#     identifying the spec, then `exit 0` so the runner records the spec as
#     passing. This is the same skip-with-log pattern bd-github-link.sh
#     uses for missing gh/git — CI doesn't have a public installer for bd,
#     and we don't want bd-dependent specs to block the gate.
#   - Anywhere else (bd absent, no BD_SHIM_ONLY): hard-fail with a clearer
#     message than the previous `mk_bd_shim: real bd not on PATH`. This
#     keeps dev-machine misconfigurations loud.
#
# Specs should call this near the top, AFTER mk_fixture but BEFORE the
# first `bd` invocation. Placing it after mk_fixture means the fixture
# is still constructed (so any non-bd assertions before it would have
# run) — but in practice every bd-dependent spec needs bd from the first
# action, so the placement is "first line after FIXTURE=$COMPONENT_FIXTURE_PATH".
bd_required_or_skip() {
    if command -v bd >/dev/null 2>&1; then
        return 0
    fi
    # bd is not on PATH.
    local spec_name="${BASH_SOURCE[1]##*/}"
    if [ -z "$spec_name" ]; then
        spec_name="<unknown spec>"
    fi
    if [ "${BD_SHIM_ONLY:-0}" = "1" ]; then
        printf 'SKIPPED: %s (bd not available; CI env BD_SHIM_ONLY=1)\n' "$spec_name"
        # Exit the spec cleanly. The runner's spec-wrapper interprets
        # exit 0 as PASS. PASS/FAIL counters are zero — we don't fake
        # assertions, we just record the skip.
        exit 0
    fi
    printf 'bd_required_or_skip: %s requires the real `bd` CLI on PATH.\n' "$spec_name" >&2
    printf '  Install Beads (https://github.com/beads-tracker/beads) or run with BD_SHIM_ONLY=1 to skip-with-log in CI.\n' >&2
    exit 1
}

mk_fixture() {
    # IMPORTANT: callers MUST invoke this WITHOUT command substitution. The
    # function exports CLAUDE_PROJECT_DIR + PATH into the caller's shell;
    # under `FIXTURE=$(mk_fixture)` the exports happen in a subshell and
    # are immediately discarded. Read the result via $COMPONENT_FIXTURE_PATH.
    local root
    root=$(mktemp -d -t component-fixture.XXXXXX)
    __COMPONENT_FIXTURES_TO_CLEAN+=("$root")
    # Export for legacy command-substitution callers AND set the global
    # for in-shell callers.
    export COMPONENT_FIXTURE_PATH="$root"

    mkdir -p "$root/.claude/.qa-tracking" "$root/.claude/scripts" \
        "$root/.claude/skills/workflow-engine" "$root/.beads" "$root/bin"

    local plugin
    plugin=$(plugin_root)

    # Symlink every script from the plugin into the fixture so the
    # script-under-test sees its sibling helpers (current-task.sh,
    # qa-gate.sh, detect-stack.sh, etc.) at the expected path. Symlinks
    # rather than copies because the script-under-test pulls its dependents
    # via relative paths from .claude/scripts/.
    local s
    for s in "$plugin"/.claude/scripts/*.sh; do
        [ -f "$s" ] || continue
        ln -sf "$s" "$root/.claude/scripts/$(basename "$s")"
    done

    # Workflow skill (needed by intent-router.sh + session-start.sh).
    if [ -f "$plugin/.claude/skills/workflow-engine/SKILL.md" ]; then
        ln -sf "$plugin/.claude/skills/workflow-engine/SKILL.md" \
            "$root/.claude/skills/workflow-engine/SKILL.md"
    fi

    # Minimal settings.json so the manifest is well-formed in case the
    # script-under-test inspects it. Hooks-aware shape; we don't actually
    # fire hooks from this file in component tests (specs invoke scripts
    # directly), but the file exists so any inspect-the-manifest path is
    # exercised against a valid stub.
    cat > "$root/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": ".claude/scripts/session-start.sh"}]}]
  }
}
JSON

    # Install the bd wrapper. mk_bd_shim writes into $root/bin/bd.
    mk_bd_shim "$root" >/dev/null

    # Prepend the shim dir to PATH so subsequent `bd` calls hit the wrapper.
    # We do NOT export at file-scope (would leak across specs); instead we
    # mutate PATH in the caller's shell. The runner subshells each spec,
    # so this is scoped correctly.
    export PATH="$root/bin:$PATH"
    export CLAUDE_PROJECT_DIR="$root"

    # Initialise Beads inside the fixture. Use the wrapper so --no-daemon
    # is injected. Cd into the project for the init; cd back so we don't
    # surprise the caller. `bd init` is silent on success.
    (cd "$root" && bd init >/dev/null 2>&1) || true

    # IMPORTANT: cd INTO the fixture in the caller's shell. The plugin's
    # hook scripts (qa-gate.sh, etc.) invoke `bd label add` etc. without
    # threading --db or --repo, relying on cwd to locate the right .beads.
    # If the caller's cwd is the real plugin root, the test would write to
    # the plugin's production Beads database — a major regression. Forcing
    # cwd into the fixture is the simplest correct contract.
    cd "$root"

    # Intentionally no `printf '%s' "$root"` — the path is available via
    # $COMPONENT_FIXTURE_PATH; emitting it on stdout would corrupt specs
    # that source this function without command substitution.
}

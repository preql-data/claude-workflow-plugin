#!/bin/bash
# shim.sh - PATH-shim builder for component tests.
#
# Phase B (claude-workflow-plugin-0wk.11). Extracted from the inline patterns
# in bd-github-link.test.sh:116-180. Lets specs stub external binaries
# (`gh`, `bd`, `git`, `npm`, etc.) without touching the real ones; every
# invocation is recorded so the spec can assert on what was called.
#
# Functions:
#   mk_shim_dir         <fixture>                 -> $FIXTURE/bin (created if needed)
#   mk_shim <cmd> <fixture> [exit-code] [stdout]
#       Create $FIXTURE/bin/<cmd> that:
#         - Records its full argv (space-joined) to $FIXTURE/bin/<cmd>.log
#         - Emits the optional <stdout> on stdout
#         - Exits with <exit-code> (default 0)
#       The shim takes precedence over the real command when the caller
#       prepends $FIXTURE/bin to PATH.
#
#   mk_bd_shim <fixture>
#       Special-case: shim that delegates to the real `bd` with --no-daemon
#       injected. Required because Beads' daemon-autostart can race on
#       freshly-init'd tempdir DBs (same rationale as bd-github-link.test.sh).
#
#   shim_log <fixture> <cmd>
#       Echo the path to the recorded log for <cmd>. Convenience.
#
#   shim_argv_contains <fixture> <cmd> <substring>
#       Returns 0 if any recorded invocation of <cmd> contains <substring>.

if [ -n "${__COMPONENT_SHIM_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
__COMPONENT_SHIM_SH_SOURCED=1

mk_shim_dir() {
    local fixture="$1"
    mkdir -p "$fixture/bin"
    printf '%s/bin' "$fixture"
}

mk_shim() {
    # mk_shim <cmd> <fixture> [exit-code] [stdout]
    local cmd="$1" fixture="$2" exit_code="${3:-0}" stdout="${4:-}"
    local bin
    bin=$(mk_shim_dir "$fixture")
    local script="$bin/$cmd"
    local log="$bin/${cmd}.log"
    : > "$log"

    # Build the shim. Note: we generate it via printf with the values
    # interpolated as literals so the resulting file has no $variable
    # references to the host shell. The log path is absolute so cwd drift
    # in the script-under-test doesn't lose invocations.
    {
        printf '#!/bin/bash\n'
        printf '# Auto-generated shim for %s; logs to %s\n' "$cmd" "$log"
        printf 'printf "%%s\\n" "$*" >> %q\n' "$log"
        if [ -n "$stdout" ]; then
            # Use printf %s + newline so newlines inside <stdout> survive.
            printf 'printf "%%s\\n" %q\n' "$stdout"
        fi
        printf 'exit %s\n' "$exit_code"
    } > "$script"
    chmod +x "$script"
    printf '%s' "$script"
}

mk_bd_shim() {
    # mk_bd_shim <fixture>
    # Find the real bd, generate a wrapper that injects --no-daemon.
    local fixture="$1"
    local bin
    bin=$(mk_shim_dir "$fixture")
    local script="$bin/bd"

    local real_bd
    real_bd=$(command -v bd 2>/dev/null || true)
    if [ -z "$real_bd" ]; then
        printf 'mk_bd_shim: real bd not on PATH\n' >&2
        return 1
    fi

    {
        printf '#!/bin/bash\n'
        printf '# bd wrapper: --no-daemon to avoid daemon-autostart races in tempdirs.\n'
        printf 'exec %q --no-daemon "$@"\n' "$real_bd"
    } > "$script"
    chmod +x "$script"
    printf '%s' "$script"
}

shim_log() {
    # shim_log <fixture> <cmd> -> path to the recorded argv log
    printf '%s/bin/%s.log' "$1" "$2"
}

shim_argv_contains() {
    # shim_argv_contains <fixture> <cmd> <substring>
    local log
    log=$(shim_log "$1" "$2")
    [ -f "$log" ] || return 1
    grep -qF -- "$3" "$log"
}

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
#       Special-case: shim that delegates straight to the real `bd`. It used to
#       inject --no-daemon (bd 0.47.x raced daemon-autostart on freshly-init'd
#       tempdir DBs); bd 1.1.2 removed both the flag and the daemon, so the
#       wrapper is now a pass-through that exists purely so specs can PATH-shim
#       and selectively override bd.
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
    # Find the real bd, generate a pass-through wrapper for it.
    local fixture="$1"
    local bin
    bin=$(mk_shim_dir "$fixture")
    local script="$bin/bd"

    local real_bd
    real_bd=$(command -v bd 2>/dev/null || true)
    # gz3: refuse to wrap OURSELVES. mk_fixture prepends $fixture/bin to PATH,
    # so a SECOND call for the same fixture resolves `command -v bd` to the shim
    # this call is about to overwrite — and the generated `exec <that path>`
    # would re-exec itself forever. That failure mode is a hang with no output
    # (the runner captures each spec's stdout in a command substitution, so a
    # spinning spec prints nothing at all), which is expensive to diagnose. A
    # spec that needs to restore the wrapper after temporarily replacing it must
    # write it from the real bd path it saved, not call this again.
    if [ -n "$real_bd" ] && [ "$real_bd" = "$script" ]; then
        printf 'mk_bd_shim: refusing to wrap the shim at %s with itself (PATH already prefers it; save the real bd path before replacing the wrapper)\n' \
            "$script" >&2
        return 1
    fi
    if [ -z "$real_bd" ]; then
        # In BD_SHIM_ONLY mode (CI runner without bd installed), stay
        # silent here — the spec's own `bd_required_or_skip` call will
        # emit a single SKIPPED line. Two warnings per spec is noise.
        # Outside BD_SHIM_ONLY we keep the warning so dev-machine
        # misconfiguration is loud.
        if [ "${BD_SHIM_ONLY:-0}" != "1" ]; then
            printf 'mk_bd_shim: real bd not on PATH\n' >&2
        fi
        return 1
    fi

    # The wrapper used to inject --no-daemon (bd 0.47.x autostarted a background
    # daemon that raced writes on freshly-init'd tempdir DBs). bd 1.1.2 REMOVED
    # the flag and the daemon with it: `bd dolt status` reports "embedded
    # (in-process, no server)", so every invocation is in-process against
    # .beads/embeddeddolt and there is nothing to race. Keeping the flag was not
    # merely inert — it broke every call, and in a way that does not look like a
    # flag error: cobra treats an unknown flag as value-taking, so
    # `bd --no-daemon show X --json` consumed `show` as the flag's value and
    # failed with `unknown command "X" for "bd"`.
    #
    # The wrapper itself is still required: specs PATH-shim on it, and several
    # replace it with a selective variant and then restore it. Those specs
    # recover the real bd path by parsing the exec line below — anchored on
    # `"$@"`, not on any flag, so a future bd flag change cannot silently
    # reintroduce this.
    {
        printf '#!/bin/bash\n'
        printf '# bd wrapper for component tests. bd 1.1.x runs an in-process embedded\n'
        printf '# Dolt engine, so there is no daemon to disable (--no-daemon: removed).\n'
        printf 'exec %q "$@"\n' "$real_bd"
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

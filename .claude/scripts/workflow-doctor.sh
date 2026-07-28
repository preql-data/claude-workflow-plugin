#!/bin/bash
# workflow-doctor.sh — FUNCTIONAL post-install verification for the plugin.
#
# WHY THIS EXISTS (v4.1 / claude-workflow-plugin-0fc, epic 2br).
#
# Every installer assertion in this repo was presence-or-sha256, never
# functional. `make install-test` was literally two `test` calls
# (`test -d .claude`, `test -f plugin.json`); the L2 installer specs assert
# file presence and hash parity; the closest thing to a behavioural check
# asserted that settings.json gained a hook KEY, never that the hook RUNS.
# The consequence shipped three times: targets installed by `curl | bash`
# got both MCP servers dead (their node_modules never existed in the shallow
# clone, so every boot died with ERR_MODULE_NOT_FOUND) and, separately, could
# run with no workflow context at all (a SessionStart bail that printed a bare
# {"error": ...} instead of a hookSpecificOutput envelope, so Claude Code got
# no delegation contract and nothing said so).
#
# This script is the surface that makes "installs cleanly" mean "orchestration
# demonstrably runs". Every check either EXECUTES the thing or reads a contract
# that a broken install cannot satisfy. Presence-only assertions belong to the
# installer specs; they are not what this file is for.
#
# Usage:
#   workflow-doctor.sh [--target <dir>] [--json-out <file>] [--skip <name,name>]
#                      [--quiet] [--help]
#
# Exit codes:
#   0  every non-skipped check PASSed
#   1  at least one check FAILed
#   2  usage error (bad flag, unknown --skip name, missing hard dependency)
#
# Dependencies: bash 3.2 (macOS), jq, find, sed, awk, node.
#
# SANDBOXING IS MANDATORY, NOT HYGIENE. Every dynamic check EXCEPT `beads` runs
# against a throwaway copy of the target. `session-start.sh` alone wipes
# .claude/.qa-tracking/approved, truncates changed-files.txt and
# sync-errors.log, calls `qa-gate.sh baseline-capture`, and calls
# `model-select.sh apply` — which REWRITES AGENT FRONTMATTER PINS. A human who
# ran the doctor mid-session against their live tree would clear their own QA
# approval and re-pin their agents as a side effect of asking "is my install
# healthy?". See mk_probe_sandbox().
#
# THE PRECISE GUARANTEE, and the one documented exception.
#
# What is guaranteed: no source file, configuration file, agent prompt, hook
# script, skill, manifest, or gate artifact in the target is modified. Agent
# `model:` pins, .claude/.qa-tracking/* (approved, changed-files.txt,
# gate-baseline, current-task, iteration counters), settings.json, .mcp.json,
# SKILL.md and .beads/issues.jsonl are all byte-identical after a full run.
#
# The exception: `beads` deliberately runs `bd doctor` against the REAL target,
# because a sandboxed copy would be checking a database that is not the one the
# workflow uses — a meaningless check. `bd doctor` is a read-mostly SQLite
# client: it writes no issue data, but opening the database in WAL mode
# creates/rewrites `.beads/beads.db-shm` and `.beads/beads.db-wal` and a
# CHECKPOINT rewrites `.beads/beads.db` itself (the WAL is left at zero bytes).
# The DB content is equivalent and issues.jsonl is never touched, but the file
# bytes and mtimes do change — so "the doctor writes nothing anywhere" would be
# a false claim and is not made.
#
# MEASURED, not assumed. On an isolated 6,936-file target: a full 11-check run
# changed exactly those three .beads/* files and nothing else; the same run with
# `--skip beads` left all 6,936 files byte-identical; and `beads` alone
# reproduced the change. (QA independently measured the same on a 10,358-file
# target.) So `--skip beads` is the run that provably touches nothing — use it
# on a read-only mount, mid-`bd` operation, or when you need that guarantee.

set -u

# ---------------------------------------------------------------------------
# Registries. Both are extracted by the L1 specs; keep the sentinels.
# ---------------------------------------------------------------------------

# The canonical check registry, in execution order (cheap/static first, then
# the dynamic ones that spawn processes). These names ARE the test contract:
# .claude/scripts/tests/workflow-doctor.test.sh asserts the sentinel block and
# the runtime registry agree exactly, and other specs assert on individual
# names. Renaming one is a breaking change to that contract.
# BEGIN DOCTOR_CHECK_NAMES (workflow-doctor.test.sh extracts this block; keep the sentinels)
DOCTOR_CHECK_NAMES="deps agents skill mcp_config settings_hooks beads session_start mcp_bd mcp_code_graph gate_pretooluse gate_stop"
# END DOCTOR_CHECK_NAMES

# Expected tools/list cardinality per shipped MCP server, as
# `<server-dir>:<count>` pairs. EXACT EQUALITY is the point: a `>=` bound
# passes for a server that boots and registers nothing, which is precisely
# the "server is up but useless" failure this table exists to catch. Both
# numbers were verified by booting the servers over stdio and counting
# `.result.tools | length` (bd-mcp 21, code-graph-mcp 7).
#
# Cross-checked by .claude/scripts/tests/mcp-deps.test.sh against both server
# READMEs' `N tools total.` sentences and the Tools column of
# docs/MCP_SERVERS.md, so a surface change has to update all four or fail.
# BEGIN DOCTOR_TOOL_COUNTS (mcp-deps.test.sh extracts this block; keep the sentinels)
DOCTOR_TOOL_COUNTS="bd-mcp:21 code-graph-mcp:7"
# END DOCTOR_TOOL_COUNTS

# Minimum tool versions the workflow depends on.
DOCTOR_MIN_BD_VERSION="0.47"
DOCTOR_MIN_NODE_VERSION="18.17"

# Minimum bytes of post-frontmatter SKILL.md body. The `skill` check exists to
# catch the one-line fallback stub session-start.sh substitutes when SKILL.md
# is missing; the real body is ~13KB, the stub is ~200 bytes.
DOCTOR_MIN_SKILL_BODY_BYTES=500

# Minimum bytes of injected SessionStart additionalContext. Same reasoning:
# the degraded shapes are short, the healthy one carries the whole skill body.
DOCTOR_MIN_CONTEXT_BYTES=1000

# The delegation-contract marker the SessionStart context MUST carry. Drawn
# from SKILL.md's own body (an H2 heading), so its presence in
# additionalContext proves the skill body was actually injected rather than
# replaced by the stub. If SKILL.md renames the heading, the session_start
# check says so explicitly instead of blaming the injection.
DOCTOR_DELEGATION_MARKER="Mandatory delegation flow"

# Minimum hook events the derived expectation set must contain before we are
# willing to assert anything with it. hooks.json declares 7 (SessionStart,
# UserPromptSubmit, SubagentStart, PreToolUse, PostToolUse, Stop, SessionEnd);
# a derived set smaller than that means we read a truncated/wrong file, and an
# assertion over a near-empty expectation set is vacuously green — the exact
# failure mode this whole script exists to stop shipping.
DOCTOR_MIN_HOOK_EVENTS=7

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
workflow-doctor.sh — functional verification that an installed
claude-workflow-plugin target actually orchestrates.

Usage:
  workflow-doctor.sh [--target <dir>] [--json-out <file>] [--skip <name,name>]
                     [--quiet] [--help]

Flags:
  --target <dir>     Project root to verify. Default: $CLAUDE_PROJECT_DIR when
                     set, else the install root two levels above this script
                     (so `bash .claude/scripts/workflow-doctor.sh` checks its
                     own install from anywhere).
  --json-out <file>  Also write a machine-readable report:
                       {"checks":[{"name","status","detail","fix"}],
                        "passed":N,"failed":N,"skipped":N}
  --skip <names>     Comma-separated check names to skip. UNKNOWN NAMES ARE
                     REJECTED (exit 2) — a typo'd --skip must never look like
                     a pass. Use it on a node-less host, e.g.
                     --skip mcp_bd,mcp_code_graph
                     and on an AIR-GAPPED host add `beads`: `bd doctor` contacts
                     GitHub for a release check, so with no network it can run
                     past this check's 30s bound and FAIL a healthy install.
                     `--skip beads` is also the way to guarantee the run touches
                     nothing at all in the target (see the note below).
  --quiet            Suppress PASS and SKIP lines. FAIL lines, their indented
                     `fix:` lines, and the final summary still print.
  -h, --help         Print this message and exit 0.

Exit codes:
  0  every non-skipped check PASSed
  1  at least one check FAILed
  2  usage error (bad flag, unknown --skip name, missing hard dependency)

Checks (the names are a stable contract; specs assert on them):
  deps             git / jq / bd / node / npm on PATH; bd >= 0.47; node >= 18.17
  agents           every .claude-plugin/plugin.json agents[] path exists, has
                   name/description/tools/model frontmatter, and carries BOTH
                   the mcp__plugin_claude-workflow_bd and mcp__bd tool tokens
  skill            .claude/skills/workflow-engine/SKILL.md exists and its
                   post-frontmatter body is a real body, not the fallback stub
  mcp_config       .mcp.json is ONE JSON object, declares bd + code-graph, and
                   uses no bare ${CLAUDE_PROJECT_DIR} (the :- default form is
                   required for project scope)
  settings_hooks   every event declared in .claude/hooks/hooks.json is wired in
                   .claude/settings.json AND its command resolves to a file
                   that exists in the target
  beads            .beads/ present and `bd doctor` reachable (tolerant: bd's
                   section wording varies by version, so text findings only
                   downgrade to a NOTE). THE ONE CHECK THAT RUNS AGAINST THE
                   REAL TARGET — see the note below.
  session_start    EXECUTES the target's session-start.sh and asserts a valid
                   SessionStart envelope carrying a non-empty additionalContext
                   with the workflow_engine block and the delegation contract
  mcp_bd           boots .claude/mcp/bd-mcp over stdio and asserts tools/list
                   returns EXACTLY the expected tool count
  mcp_code_graph   same for .claude/mcp/code-graph-mcp
  gate_pretooluse  EXECUTES prevent-orchestrator-edits.sh and asserts an
                   orchestrator Write is denied
  gate_stop        EXECUTES verify-before-stop.sh over a synthetic change set
                   with no approval and asserts the Stop is blocked

WHAT A RUN TOUCHES (safe to run mid-session; the exception is named)
  Every dynamic check EXCEPT `beads` runs in a throwaway sandbox copy of the
  target. No source file, config file, agent prompt, hook script, skill,
  manifest or gate artifact in the target is modified: your QA approval
  (.claude/.qa-tracking/approved), changed-files tracker, gate baseline,
  current-task pointer, settings.json, .mcp.json, SKILL.md, .beads/issues.jsonl
  and every agent's `model:` pin are byte-identical after a full run.

  The one exception is `beads`, which runs `bd doctor` against the REAL target
  on purpose — a sandboxed copy would be checking a database the workflow does
  not use. `bd doctor` writes no issue data, but opening the database in WAL
  mode creates/rewrites .beads/beads.db-shm and .beads/beads.db-wal, and a
  CHECKPOINT rewrites .beads/beads.db itself. No issue changes, no data loss,
  issues.jsonl never touched — but those three files' bytes and mtimes do
  change. Measured on a 6,936-file target: a full run changed exactly those
  three and nothing else, and the same run with `--skip beads` changed nothing
  at all. So pass `--skip beads` when you need a run that provably touches
  nothing (read-only mount, or a `bd` operation in flight).

AIR-GAPPED / OFFLINE INSTALL RECIPE
  The two MCP servers have no native dependencies (zero install scripts, zero
  dev packages, pure-WASM sql.js + web-tree-sitter) so they install from the
  committed lockfiles with no toolchain and no postinstall:

    cd <target>/.claude/mcp/bd-mcp         && npm ci --omit=dev --ignore-scripts
    cd <target>/.claude/mcp/code-graph-mcp && npm ci --omit=dev --ignore-scripts

  On a host with no registry access at all, copy each server's node_modules/
  from a machine that has run the above, then re-run:

    bash .claude/scripts/workflow-doctor.sh --target <target>

  If node cannot be installed at all, skip the two server checks explicitly so
  the rest of the report is still trustworthy:

    bash .claude/scripts/workflow-doctor.sh --skip mcp_bd,mcp_code_graph

  On a host with NO outbound network, also skip `beads`: `bd doctor` performs a
  GitHub release check and can otherwise run past this check's 30s bound and
  report a false FAIL on a healthy install:

    bash .claude/scripts/workflow-doctor.sh --skip beads,mcp_bd,mcp_code_graph
USAGE
}

usage_error() {
    printf 'workflow-doctor.sh: %s\n' "$1" >&2
    printf 'Run "workflow-doctor.sh --help" for usage.\n' >&2
    exit 2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

TARGET=""
JSON_OUT=""
SKIP_RAW=""
QUIET=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            [ "$#" -ge 2 ] || usage_error "--target requires a value"
            TARGET="$2"; shift 2 ;;
        --target=*)
            TARGET="${1#*=}"; shift ;;
        --json-out)
            [ "$#" -ge 2 ] || usage_error "--json-out requires a value"
            JSON_OUT="$2"; shift 2 ;;
        --json-out=*)
            JSON_OUT="${1#*=}"; shift ;;
        --skip)
            [ "$#" -ge 2 ] || usage_error "--skip requires a value"
            SKIP_RAW="$2"; shift 2 ;;
        --skip=*)
            SKIP_RAW="${1#*=}"; shift ;;
        --quiet)
            QUIET=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            usage_error "unrecognised argument '$1'" ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    printf 'workflow-doctor.sh: jq is required but not on PATH.\n' >&2
    printf '  Install jq (brew install jq / apt-get install jq) and re-run.\n' >&2
    exit 2
fi

# Default target: an explicit CLAUDE_PROJECT_DIR wins, otherwise the install
# root two levels above this script. Resolving from BASH_SOURCE means the
# doctor verifies the install it SHIPPED WITH regardless of cwd.
if [ -z "$TARGET" ]; then
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        TARGET="$CLAUDE_PROJECT_DIR"
    else
        _self_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || _self_dir=""
        if [ -n "$_self_dir" ]; then
            TARGET=$(cd "$_self_dir/../.." 2>/dev/null && pwd) || TARGET=""
        fi
        [ -n "$TARGET" ] || TARGET="$(pwd)"
    fi
fi

[ -d "$TARGET" ] || usage_error "--target is not a directory: $TARGET"
TARGET=$(cd "$TARGET" && pwd)

# Validate --skip against the registry BEFORE running anything. A typo'd skip
# name that silently ran the check (or silently skipped nothing) would make the
# exit code mean something different from what the operator asked for.
SKIP_LIST=""
if [ -n "$SKIP_RAW" ]; then
    _skip_one=""
    for _skip_one in $(printf '%s' "$SKIP_RAW" | tr ',' ' '); do
        [ -n "$_skip_one" ] || continue
        case " $DOCTOR_CHECK_NAMES " in
            *" $_skip_one "*) SKIP_LIST="$SKIP_LIST $_skip_one" ;;
            *) usage_error "--skip: unknown check name '$_skip_one' (known: $DOCTOR_CHECK_NAMES)" ;;
        esac
    done
    [ -n "$SKIP_LIST" ] || usage_error "--skip was given an empty list"
fi

is_skipped() {
    case " $SKIP_LIST " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Workdir + sandbox lifecycle
# ---------------------------------------------------------------------------

WORKDIR=$(mktemp -d -t workflow-doctor.XXXXXX) || {
    printf 'workflow-doctor.sh: could not create a temp workdir\n' >&2
    exit 2
}
CHECKS_JSONL="$WORKDIR/checks.jsonl"
: > "$CHECKS_JSONL"

SANDBOXES=()

# cleanup runs only via the EXIT trap; the static analyzer can't see that
# indirection (SC2329 on newer shellcheck, SC2317 on older CI builds).
# shellcheck disable=SC2329,SC2317
doctor_cleanup() {
    local d
    for d in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
    [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap doctor_cleanup EXIT

# mk_bd_shim <bin-dir> — write a `bd` wrapper into <bin-dir> that injects
# `--no-daemon`, and echo <bin-dir>. Returns non-zero (and writes nothing) when
# no real bd is on PATH; the `deps` check is what reports bd's absence.
#
# ONE definition, two callers (mk_probe_sandbox and check_beads). It used to be
# inline in the sandbox builder only, which meant the `beads` check invoked the
# raw `bd` while every other bd call in the doctor went through the shim — an
# inconsistency QA flagged: bd 0.47.1's daemon-autostart path crashes
# (cmd/bd/daemon_autostart.go:228), which is exactly why every e2e fixture
# pre-installs this same wrapper. A health checker that can itself be taken down
# by the bug the shim exists to dodge is not much of a health checker.
mk_bd_shim() {
    local bindir="$1" real_bd
    real_bd=$(command -v bd 2>/dev/null || echo "")
    [ -n "$real_bd" ] || return 1
    mkdir -p "$bindir" 2>/dev/null || return 1
    {
        printf '#!/bin/bash\n'
        printf '# workflow-doctor shim: bd 0.47.1 daemon autostart crashes.\n'
        printf 'exec %s --no-daemon "$@"\n' "$real_bd"
    } > "$bindir/bd" || return 1
    chmod +x "$bindir/bd" 2>/dev/null || true
    printf '%s' "$bindir"
}

# run_bounded <secs> <stdout-file> <stderr-file> <cmd> [args...]
#
# Run <cmd> with a wall-clock bound. Returns the command's exit code, or 124
# on timeout (GNU timeout's convention, kept so callers can distinguish).
#
# macOS ships no coreutils `timeout` and none of the repo's other bounded
# helpers can be reused here (session-start.sh's inline pattern falls back to
# "run unbounded", which is exactly what a health checker must not do). The
# fallback watchdog polls at 1s granularity inside a subshell whose OWN stderr
# is discarded, so bash's asynchronous "Terminated: 15" job notice cannot
# contaminate the doctor's stderr; the child's stderr goes to <stderr-file>
# and is unaffected.
#
# `set -m` INSIDE THE SUBSHELL IS LOAD-BEARING (R1-F2). Without job control the
# background child shares the doctor's process group, so `kill $pid` on timeout
# reaches only that one process — the child's own children survive. Every
# bounded call here spawns exactly that shape (`bash <driver>` whose grandchild
# is `node <server>`, `session-start.sh`, or the Stop hook's test/lint
# subprocesses), and a timeout is precisely the case where something is wedged
# and must not be left running. QA reproduced 3 orphans per timed-out call.
# With `set -m` the child becomes a process-group leader, so `kill -TERM -$pid`
# signals the whole group; the plain `kill -TERM $pid` stays as a fallback for
# the (theoretical) case where job control could not be enabled. Verified on
# bash 3.2.57: orphans 3 -> 0, rc 0/7/124/127 all still propagate, harness
# stderr still empty.
run_bounded() {
    local secs="$1" outf="$2" errf="$3"; shift 3
    local rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@" >"$outf" 2>"$errf" || rc=$?
        return "$rc"
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@" >"$outf" 2>"$errf" || rc=$?
        return "$rc"
    fi
    (
        set -m
        "$@" >"$outf" 2>"$errf" &
        pid=$!
        set +m
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$waited" -ge "$secs" ]; then
                kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
                sleep 1
                kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null
                exit 124
            fi
            sleep 1
            waited=$((waited + 1))
        done
        crc=0
        wait "$pid" || crc=$?
        exit "$crc"
    ) 2>/dev/null
    rc=$?
    return "$rc"
}

# mk_probe_sandbox — echo the path of a fresh throwaway copy of the target
# that every dynamic check runs against instead of the live project.
#
# What gets copied is exactly what the hook scripts read: the FLAT
# .claude/scripts/*.sh set (matching install.sh's glob — .claude/scripts/tests/
# is repo-only and never shipped, see workflow-manifest.sh's scan scopes), the
# skill, the agents (model-select.sh apply rewrites their frontmatter pins —
# in here, harmlessly), settings.json, hooks/, and the operator config files
# the resolvers read. A git repo with one empty commit so the gate's
# git-identity and baseline machinery work.
#
# Callers get a FRESH sandbox each time on purpose: session-start.sh truncates
# changed-files.txt, so sharing one sandbox between the session_start and
# gate_stop checks would let the first silently destroy the second's fixture.
mk_probe_sandbox() {
    local sb
    sb=$(mktemp -d -t workflow-doctor-probe.XXXXXX) || return 1
    SANDBOXES+=("$sb")

    mkdir -p "$sb/.claude/.qa-tracking" "$sb/.claude/scripts" "$sb/bin" || return 1

    # MIRROR the target's Beads-initialization state, do not fabricate it.
    # session-start.sh hard-exits (bare {"error": ...}, no hook envelope) when
    # $PROJECT_DIR/.beads is absent — that is symptom-1 candidate (4) of the
    # epic. A sandbox that always created .beads/ would make the session_start
    # check PASS for a target that cannot start a session at all, i.e. it would
    # hide the exact defect it exists to find. Contents are deliberately NOT
    # copied: every bd call in the hooks is read-only and guarded, and copying
    # a live task database into a probe is a risk with no upside.
    if [ -d "$TARGET/.beads" ]; then
        mkdir -p "$sb/.beads" || return 1
    fi

    local s
    for s in "$TARGET"/.claude/scripts/*.sh; do
        [ -f "$s" ] || continue
        cp "$s" "$sb/.claude/scripts/$(basename "$s")" 2>/dev/null || true
    done
    chmod +x "$sb/.claude/scripts"/*.sh 2>/dev/null || true

    local d
    for d in skills agents hooks rubrics; do
        if [ -d "$TARGET/.claude/$d" ]; then
            cp -R "$TARGET/.claude/$d" "$sb/.claude/" 2>/dev/null || true
        fi
    done

    local f
    for f in settings.json rubric-config review-config model-ranking model-roles effort-verdict; do
        if [ -f "$TARGET/.claude/$f" ]; then
            cp "$TARGET/.claude/$f" "$sb/.claude/$f" 2>/dev/null || true
        fi
    done

    mk_bd_shim "$sb/bin" >/dev/null || true

    (
        cd "$sb" 2>/dev/null || exit 1
        git init -q >/dev/null 2>&1 || true
        git -c user.email=doctor@example.invalid -c user.name=workflow-doctor \
            commit --allow-empty -q -m "workflow-doctor probe baseline" >/dev/null 2>&1 || true
    ) || true

    printf '%s' "$sb"
}

# run_in_sandbox <sandbox> <secs> <stdout-file> <stderr-file> <cmd> [args...]
#
# The env every sandbox invocation runs under. These are the scripts' OWN
# documented test seams, not invented ones:
#   ANTHROPIC_API_KEY=       model-select.sh's fetch_models_from_api returns
#                            early on an empty key (fail-open, no network).
#   CODEX_USER_CONFIG=<none> codex-detect.sh resolves config-absent -> lane
#                            claude without probing the operator's real
#                            ~/.claude.json.
#   CODEX_DETECT_TIMEOUT_S=1 keeps the advisory probe off the critical path.
# PATH carries the sandbox's bd shim first (bd 0.47.1 daemon autostart crash).
run_in_sandbox() {
    local sb="$1" secs="$2" outf="$3" errf="$4"; shift 4
    run_bounded "$secs" "$outf" "$errf" env \
        "CLAUDE_PROJECT_DIR=$sb" \
        "ANTHROPIC_API_KEY=" \
        "CODEX_USER_CONFIG=$sb/nonexistent.json" \
        "CODEX_DETECT_TIMEOUT_S=1" \
        "PATH=$sb/bin:$PATH" \
        "$@"
}

# ---------------------------------------------------------------------------
# Result recording
# ---------------------------------------------------------------------------

PASSED=0
FAILED=0
SKIPPED=0

# record <name> <PASS|FAIL|SKIP> <detail> [fix]
#
# `detail` may contain newlines (a degraded-block fix line is echoed verbatim);
# the human renderer indents continuation lines, and the JSON writer encodes
# them properly via jq.
record() {
    local name="$1" status="$2" detail="$3" fix="${4:-}"
    case "$status" in
        PASS) PASSED=$((PASSED + 1)) ;;
        FAIL) FAILED=$((FAILED + 1)) ;;
        SKIP) SKIPPED=$((SKIPPED + 1)) ;;
    esac

    jq -nc --arg name "$name" --arg status "$status" \
        --arg detail "$detail" --arg fix "$fix" \
        '{name:$name, status:$status, detail:$detail, fix:$fix}' \
        >> "$CHECKS_JSONL"

    if [ "$QUIET" = "1" ] && [ "$status" != "FAIL" ]; then
        return 0
    fi

    local first rest
    first=$(printf '%s' "$detail" | head -1)
    printf '%-4s %-16s %s\n' "$status" "$name" "$first"
    rest=$(printf '%s\n' "$detail" | tail -n +2 | grep -v '^$' || true)
    if [ -n "$rest" ]; then
        printf '%s\n' "$rest" | sed 's/^/       /'
    fi
    if [ "$status" = "FAIL" ] && [ -n "$fix" ]; then
        printf '%s\n' "$fix" | sed 's/^/       fix: /'
    fi
}

# ---------------------------------------------------------------------------
# Small shared helpers
# ---------------------------------------------------------------------------

# version_at_least <have> <want> — 0 when <have> >= <want> by dotted-numeric
# ordering. Mirrors session-start.sh's version_cmp so the doctor and the hook
# agree about what "older than the pin" means.
version_at_least() {
    local have="$1" want="$2" lowest
    [ -n "$have" ] || return 1
    [ "$have" = "$want" ] && return 0
    lowest=$(printf '%s\n%s\n' "$have" "$want" | sort -V 2>/dev/null | head -1)
    [ "$lowest" = "$want" ]
}

# frontmatter_of <file> — the first `---`-delimited block's body.
frontmatter_of() {
    awk 'NR==1 && /^---[[:space:]]*$/ {inb=1; next}
         inb && /^---[[:space:]]*$/ {exit}
         inb {print}' "$1" 2>/dev/null
}

# skill_body_of <file> — the post-frontmatter body, using the SAME awk
# session-start.sh:413 uses. Sharing the extraction is what makes the `skill`
# check's byte count mean "what the hook would inject", not "what a second
# parser thinks the body is".
skill_body_of() {
    awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; next} n>=2{print}' "$1" 2>/dev/null
}

# tools_has_token <tools-line> <token> — exact comma-separated token match, so
# `mcp__bd` does NOT match `mcp__bd_create_task` and vice versa.
tools_has_token() {
    printf '%s' "$1" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -qxF "$2"
}

# tool_count_for <server-dir> — the DOCTOR_TOOL_COUNTS entry, or empty.
tool_count_for() {
    local want="$1" pair
    for pair in $DOCTOR_TOOL_COUNTS; do
        case "$pair" in
            "$want":*) printf '%s' "${pair#*:}"; return 0 ;;
        esac
    done
    printf ''
}

# mcp_check_name_for <server-dir> — the check name a server dir maps to
# (bd-mcp -> mcp_bd, code-graph-mcp -> mcp_code_graph).
mcp_check_name_for() {
    printf 'mcp_%s' "$(printf '%s' "${1%-mcp}" | tr '-' '_')"
}

# ---------------------------------------------------------------------------
# Static drivers written once, invoked by the dynamic checks. Files rather
# than `bash -c "<string>"` so nothing depends on quoting a path through two
# shells, and so a failing probe can be re-run by hand from the workdir.
# ---------------------------------------------------------------------------

DRIVE_STDIN="$WORKDIR/drive-stdin.sh"
cat > "$DRIVE_STDIN" <<'DRIVER'
#!/bin/bash
# $1 = stdin payload, $2 = hook script to execute.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 90
printf '%s' "$1" | bash "$2"
DRIVER

DRIVE_MCP="$WORKDIR/drive-mcp.sh"
cat > "$DRIVE_MCP" <<'DRIVER'
#!/bin/bash
# $1 = server launcher (bin/<name>.js). Drives the minimum stdio handshake:
# initialize -> notifications/initialized -> tools/list. Same frame sequence
# and flush timing as .claude/tests/component/specs/code-graph-mcp.sh, which
# is the pattern already proven against both servers.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 90
{
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"workflow-doctor","version":"0.0.0"}}}'
    sleep 0.2
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.2
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    sleep 1.5
} | node "$1"
DRIVER

# ===========================================================================
# Check: deps
# ===========================================================================
check_deps() {
    local missing="" detail="" tool
    for tool in git jq bd node npm; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
        record deps FAIL "not on PATH:${missing}" \
"Install the missing tool(s), then re-run. git/jq are OS packages; bd is Beads
(https://github.com/steveyegge/beads); node+npm must be >= $DOCTOR_MIN_NODE_VERSION for the two
MCP servers. A non-interactive shell may also simply have a shorter PATH than
your login shell — compare \`bash -lc 'command -v bd'\` with \`bash -c 'command -v bd'\`."
        return
    fi

    local bd_raw bd_ver node_raw node_ver problems=""
    bd_raw=$(bd --version 2>/dev/null | head -1 || echo "")
    bd_ver=$(printf '%s' "$bd_raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "")
    node_raw=$(node --version 2>/dev/null | head -1 || echo "")
    node_ver=$(printf '%s' "$node_raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "")

    if [ -z "$bd_ver" ]; then
        problems="$problems bd-version-unparseable(${bd_raw:-empty});"
    elif ! version_at_least "$bd_ver" "$DOCTOR_MIN_BD_VERSION"; then
        problems="$problems bd $bd_ver < $DOCTOR_MIN_BD_VERSION;"
    fi
    if [ -z "$node_ver" ]; then
        problems="$problems node-version-unparseable(${node_raw:-empty});"
    elif ! version_at_least "$node_ver" "$DOCTOR_MIN_NODE_VERSION"; then
        problems="$problems node $node_ver < $DOCTOR_MIN_NODE_VERSION;"
    fi

    detail="git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1), jq $(jq --version 2>/dev/null | sed 's/^jq-//' | head -1), bd ${bd_ver:-?}, node ${node_ver:-?}, npm $(npm --version 2>/dev/null | head -1)"
    if [ -n "$problems" ]; then
        record deps FAIL "version floor(s) not met:$problems present: $detail" \
"Upgrade the flagged tool. bd: re-run the installer you originally used.
node: both MCP servers declare \"engines\": {\"node\": \">=$DOCTOR_MIN_NODE_VERSION\"} and their
dynamic-import launchers fail opaquely on older runtimes."
        return
    fi
    record deps PASS "$detail"
}

# ===========================================================================
# Check: agents
#
# WHICH AGENTS MUST CARRY THE bd MCP GRANTS, and why it is not "all of them".
#
# The epic's evidence ELIMINATED agent registration as a cause of the P0
# partly on the observation that every agent's `tools:` carries both the
# plugin-qualified (mcp__plugin_claude-workflow_bd) and project-scope
# (mcp__bd) grants. That observation is true of the FIVE workflow agents
# install.sh hard-requires. It is NOT true of grader.md / judge.md, which are
# read-only reviewers BY DESIGN (`tools: Read, Grep, Glob, LS`, no mcp__ grant
# at all) and are documented exemptions in
# .claude/scripts/tests/agent-mcp-tools-parity.test.sh.
#
# So the rule is mechanical rather than universal:
#   - the five core agents ALWAYS need both bd grants (they drive the Beads
#     lifecycle; losing one scope silently removes the surface in that scope);
#   - any OTHER agent that grants at least one mcp__ tool needs both too —
#     that is the partial-surface bug class (can reach code-graph but not bd,
#     or one bd scope but not the other);
#   - an agent with NO mcp__ grants is read-only by design and exempt, and the
#     exemption is reported as a NOTE so it can never become silent.
#
# Requiring bd grants on a deliberately read-only agent would make the doctor
# emit a FAIL on a correct install — the one property that guarantees a health
# checker gets ignored.
# ===========================================================================
DOCTOR_CORE_AGENTS="orchestrator qa backend frontend devops"

check_agents() {
    local manifest="$TARGET/.claude-plugin/plugin.json"
    if [ ! -f "$manifest" ]; then
        record agents FAIL "manifest missing: .claude-plugin/plugin.json" \
"Re-run the plugin installer against this target. Without the manifest there
is no declared agent set to verify."
        return
    fi
    if ! jq -e . "$manifest" >/dev/null 2>&1; then
        record agents FAIL "manifest is not valid JSON: .claude-plugin/plugin.json" \
"Fix or restore .claude-plugin/plugin.json (\`git checkout --\` it, or re-run
the installer). \`jq . .claude-plugin/plugin.json\` prints the parse error."
        return
    fi

    local declared count problems="" no_mcp_agents="" seen_orchestrator=0
    local rel abs fm tools_line base agent_name needs_bd
    declared=$(jq -r '(.agents // [])[]' "$manifest" 2>/dev/null || echo "")
    count=$(printf '%s\n' "$declared" | grep -c . || true)
    count="${count:-0}"
    if [ "$count" -eq 0 ]; then
        record agents FAIL "manifest declares zero agents[] entries" \
"Restore the agents[] array in .claude-plugin/plugin.json. An empty array
makes every agent invisible to the SDK with no error surfaced."
        return
    fi

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in ./*) rel="${rel#./}" ;; esac
        abs="$TARGET/$rel"
        base=$(basename "$rel")
        agent_name="${base%.md}"
        case "$rel" in */orchestrator.md) seen_orchestrator=1 ;; esac
        if [ ! -f "$abs" ]; then
            problems="$problems missing:$rel;"
            continue
        fi
        fm=$(frontmatter_of "$abs")
        if [ -z "$fm" ]; then
            problems="$problems no-frontmatter:$rel;"
            continue
        fi
        local key
        for key in name description tools model; do
            printf '%s\n' "$fm" | grep -q "^${key}:" \
                || problems="$problems ${rel}:no-${key};"
        done

        tools_line=$(printf '%s\n' "$fm" | sed -n 's/^tools:[[:space:]]*//p' | head -1)
        # An absent `tools:` line inherits every tool (per the sub-agents doc),
        # so there is no allowlist to audit; the missing-key problem above
        # already reported it.
        [ -n "$tools_line" ] || continue

        needs_bd=0
        case " $DOCTOR_CORE_AGENTS " in
            *" $agent_name "*) needs_bd=1 ;;
        esac
        if [ "$needs_bd" -eq 0 ] && printf '%s' "$tools_line" | grep -q 'mcp__'; then
            needs_bd=1
        fi
        if [ "$needs_bd" -eq 0 ]; then
            no_mcp_agents="$no_mcp_agents $agent_name"
            continue
        fi
        tools_has_token "$tools_line" "mcp__plugin_claude-workflow_bd" \
            || problems="$problems ${rel}:no-plugin-qualified-bd-tool;"
        tools_has_token "$tools_line" "mcp__bd" \
            || problems="$problems ${rel}:no-bare-mcp__bd-tool;"
    done <<EOF
$declared
EOF

    if [ "$seen_orchestrator" -eq 0 ]; then
        problems="$problems orchestrator.md-not-declared;"
    fi

    if [ -n "$problems" ]; then
        record agents FAIL "$count declared agent(s), problems:$problems" \
"Each agents[] path must exist and carry name/description/tools/model
frontmatter. Any agent that grants MCP tools at all — and always the five core
agents ($DOCTOR_CORE_AGENTS) — must list BOTH
mcp__plugin_claude-workflow_bd (plugin scope) and mcp__bd (project .mcp.json
scope): carrying only one of the two loses the Beads MCP surface in the other
scope, silently. Re-run the installer, or fix the named files."
        return
    fi
    local detail="$count declared agent(s), all present with name/description/tools/model; every MCP-granting agent carries both bd tool namespaces"
    if [ -n "$no_mcp_agents" ]; then
        detail="$detail
NOTE: read-only-by-design agent(s) with no mcp__ grant, exempt from the bd-grant rule:$no_mcp_agents"
    fi
    record agents PASS "$detail"
}

# ===========================================================================
# Check: skill
# ===========================================================================
check_skill() {
    local skill="$TARGET/.claude/skills/workflow-engine/SKILL.md" body bytes
    if [ ! -f "$skill" ]; then
        record skill FAIL "missing: .claude/skills/workflow-engine/SKILL.md" \
"Re-run the plugin installer. Without this file session-start.sh substitutes a
ONE-LINE stub for the entire delegation contract, so the session starts with
the workflow nominally installed and its rules absent."
        return
    fi
    body=$(skill_body_of "$skill")
    bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')
    bytes="${bytes:-0}"
    if [ "$bytes" -lt "$DOCTOR_MIN_SKILL_BODY_BYTES" ]; then
        record skill FAIL "post-frontmatter body is only ${bytes}B (< ${DOCTOR_MIN_SKILL_BODY_BYTES}B) — this is the fallback-stub shape, not a real skill body" \
"Restore the shipped SKILL.md (re-run the installer, or
\`git checkout -- .claude/skills/workflow-engine/SKILL.md\`). A truncated body
also means the file's frontmatter delimiters may be malformed: the body is
everything after the SECOND \`---\` line."
        return
    fi
    if ! printf '%s' "$body" | grep -qF "$DOCTOR_DELEGATION_MARKER"; then
        record skill FAIL "body is ${bytes}B but does not contain the delegation-contract marker '$DOCTOR_DELEGATION_MARKER'" \
"Either SKILL.md lost its delegation section, or the section was renamed. If
the rename was intentional, update DOCTOR_DELEGATION_MARKER in
.claude/scripts/workflow-doctor.sh in the same commit."
        return
    fi
    record skill PASS "post-frontmatter body is ${bytes}B and carries '$DOCTOR_DELEGATION_MARKER'"
}

# ===========================================================================
# Check: mcp_config
# ===========================================================================
check_mcp_config() {
    local cfg="$TARGET/.mcp.json"
    if [ ! -f "$cfg" ]; then
        record mcp_config FAIL "missing: .mcp.json" \
"Re-run the plugin installer. Without .mcp.json neither MCP server is
registered for project scope, so bd_* / code_* tools are absent from every
agent that declares them."
        return
    fi
    # `jq empty` is NOT a validity oracle for a merge input: it accepts an
    # EMPTY file and a MULTI-DOCUMENT stream, and both Update-mode merges slurp
    # with `jq -s` and index .[0]/.[1] positionally. Same predicate install.sh
    # gates its merges on (JSON_SINGLE_OBJECT_JQ).
    if ! jq -s -e 'length == 1 and (.[0] | type == "object")' "$cfg" >/dev/null 2>&1; then
        record mcp_config FAIL ".mcp.json is not exactly ONE JSON object (empty, multi-document, malformed, or a top-level array/scalar)" \
"Restore a single-object .mcp.json. This exact shape is what the installer's
Update-mode merge requires: a two-document file pushes the SHIPPED config out
to .[2] and the merge silently binds your second document instead, producing a
merged config with NONE of the shipped servers."
        return
    fi

    local problems="" key
    for key in bd code-graph; do
        jq -e --arg k "$key" '.mcpServers | has($k)' "$cfg" >/dev/null 2>&1 \
            || problems="$problems no-mcpServers.$key;"
    done

    # The bare `${CLAUDE_PROJECT_DIR}` form is unresolved at substitution time
    # in a PROJECT-scoped .mcp.json (Claude Code sets the variable in the
    # spawned server's environment, not in its own), which surfaces as an MCP
    # diagnostics warning and a dead server. The `:-` default form is the
    # documented fix and is what .mcp.json's own comment mandates.
    local servers_blob
    servers_blob=$(jq -c '.mcpServers // {}' "$cfg" 2>/dev/null || echo '{}')
    # shellcheck disable=SC2016  # the literal ${CLAUDE_PROJECT_DIR} text IS the pattern
    if printf '%s' "$servers_blob" | grep -qF '${CLAUDE_PROJECT_DIR}'; then
        problems="$problems bare-\${CLAUDE_PROJECT_DIR}-under-mcpServers;"
    fi

    # Surface a shipped server dir that no DOCTOR_TOOL_COUNTS row covers, so
    # the MCP surface cannot grow a third server that nothing boot-verifies.
    local note="" dir base
    for dir in "$TARGET"/.claude/mcp/*/; do
        [ -d "$dir" ] || continue
        base=$(basename "$dir")
        [ -n "$(tool_count_for "$base")" ] && continue
        note="$note $base"
    done

    if [ -n "$problems" ]; then
        record mcp_config FAIL "problems:$problems" \
"Use the \${CLAUDE_PROJECT_DIR:-.} default form for every path under
mcpServers (see the _comment in the shipped .mcp.json and
https://code.claude.com/docs/en/mcp), and keep both the bd and code-graph
entries. Re-running the installer restores the shipped config."
        return
    fi
    local detail="single JSON object; mcpServers declares bd + code-graph; no bare \${CLAUDE_PROJECT_DIR}"
    [ -n "$note" ] && detail="$detail
NOTE: MCP server dir(s) with no DOCTOR_TOOL_COUNTS row (not boot-verified):$note"
    record mcp_config PASS "$detail"
}

# ===========================================================================
# Check: settings_hooks
# ===========================================================================
check_settings_hooks() {
    local hooks_json="$TARGET/.claude/hooks/hooks.json"
    local settings="$TARGET/.claude/settings.json"

    if [ ! -f "$hooks_json" ]; then
        record settings_hooks FAIL "missing: .claude/hooks/hooks.json (cannot derive the expected hook-event set)" \
"Re-run the plugin installer. hooks.json is the plugin-scope hook declaration
this check derives its expectation from; without it there is nothing to
compare settings.json against and the check refuses to guess."
        return
    fi
    if [ ! -f "$settings" ]; then
        record settings_hooks FAIL "missing: .claude/settings.json (zero hooks wired)" \
"Re-run the plugin installer. An install whose settings.json never landed has
the whole plugin on disk and NOT ONE hook active — no gate, no router, no
SessionStart context."
        return
    fi

    local expected count
    expected=$(jq -r '(.hooks // {}) | keys[]' "$hooks_json" 2>/dev/null | sort || echo "")
    count=$(printf '%s\n' "$expected" | grep -c . || true)
    count="${count:-0}"
    # Vacuity guard: asserting "settings covers every expected event" over an
    # empty or truncated expectation set is green by construction. Refuse.
    if [ "$count" -lt "$DOCTOR_MIN_HOOK_EVENTS" ]; then
        record settings_hooks FAIL "hooks.json declares only $count event(s); refusing to assert against a set smaller than $DOCTOR_MIN_HOOK_EVENTS (a truncated expectation set makes this check vacuously green)" \
"Restore .claude/hooks/hooks.json from the plugin source. The shipped file
declares $DOCTOR_MIN_HOOK_EVENTS events (SessionStart, UserPromptSubmit, SubagentStart,
PreToolUse, PostToolUse, Stop, SessionEnd)."
        return
    fi
    if ! jq -e '.hooks | type == "object"' "$settings" >/dev/null 2>&1; then
        record settings_hooks FAIL "settings.json has no .hooks object (all $count declared event(s) unwired)" \
"Re-run the installer in Update mode. NOTE: the merge REFUSES and leaves the
file untouched when the existing settings.json is not exactly one JSON object
(empty / JSONC-with-comments / malformed) — check that first with
\`jq -s 'length == 1 and (.[0]|type==\"object\")' .claude/settings.json\`."
        return
    fi

    local problems="" event cmds cmd rel resolved tok
    while IFS= read -r event; do
        [ -n "$event" ] || continue
        cmds=$(jq -r --arg e "$event" '(.hooks[$e] // []) | .[]? | (.hooks // []) | .[]? | .command // empty' "$settings" 2>/dev/null || echo "")
        if [ -z "$cmds" ]; then
            problems="$problems $event:unwired;"
            continue
        fi
        resolved=0
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            # Prefer target-relative `.claude/**/*.sh` tokens: they are
            # space-proof and independent of which variable spelling the
            # command used ($CLAUDE_PROJECT_DIR / ${CLAUDE_PLUGIN_ROOT} / a
            # fixture's inline PATH prefix).
            for rel in $(printf '%s\n' "$cmd" | grep -oE '\.claude/[A-Za-z0-9._/-]+\.sh' || true); do
                if [ -f "$TARGET/$rel" ]; then resolved=1; break; fi
            done
            [ "$resolved" = "1" ] && break
            # Fall back to any absolute *.sh token that exists on disk (an
            # operator who hard-coded a path). \042 / \047 are `"` and `'`;
            # octal escapes rather than nested shell quoting because the
            # literal-quote form of this `tr` is unreadable and gets miscopied.
            for tok in $(printf '%s' "$cmd" | tr '\042\047' '  ' | tr ' ' '\n' | grep -E '^/.+\.sh$' || true); do
                if [ -f "$tok" ]; then resolved=1; break; fi
            done
            [ "$resolved" = "1" ] && break
        done <<EOF
$cmds
EOF
        [ "$resolved" = "1" ] || problems="$problems $event:command-does-not-resolve-to-an-existing-file;"
    done <<EOF
$expected
EOF

    if [ -n "$problems" ]; then
        record settings_hooks FAIL "derived $count expected event(s) from hooks.json; problems:$problems" \
"Re-run the plugin installer so settings.json regains every hook event and the
referenced scripts land under .claude/scripts/. A wired event whose command
points at a missing file is worse than an unwired one: the runtime reports a
hook failure per fire and the gate it belonged to is simply absent."
        return
    fi
    record settings_hooks PASS "all $count event(s) derived from hooks.json are wired in settings.json and resolve to existing files"
}

# ===========================================================================
# Check: beads
#
# DELIBERATELY TOLERANT. Presence of .beads/ and reachability of `bd doctor`
# are the only FAIL conditions. bd's section wording changes across versions
# (0.47.1 prints "⚠ CLI Version ... (latest: ...)" on a perfectly healthy
# install) and bd-compat.sh pins 0.47.1 only, so text parsing may downgrade to
# a NOTE and never to a failure. A doctor that cried wolf on cosmetic bd
# output would be turned off, which is worse than one that under-reports.
#
# THE ONE UNSANDBOXED CHECK, on purpose. `.beads/` is the workflow's live task
# state; a probe copy would be checking a database nothing uses, which is not a
# check at all. The cost is stated honestly rather than hidden: `bd doctor`
# writes no issue data, but opening the SQLite database can CHECKPOINT ITS WAL,
# which rewrites .beads/beads.db and .beads/beads.db-shm and truncates
# .beads/beads.db-wal to zero. issues.jsonl is untouched. This is the only file
# change a full run makes anywhere in the target (QA verified against an
# isolated 10,358-file tree), and it is why the file header, --help and
# commands/workflow-doctor.md all name `beads` as the documented exception
# instead of claiming the run touches nothing. `--skip beads` opts out.
#
# The invocation goes through the SAME `bd --no-daemon` shim mk_probe_sandbox
# installs (mk_bd_shim): bd 0.47.1's daemon-autostart path crashes, and a health
# checker that can be taken down by the bug the shim exists to dodge would
# report a false FAIL on a healthy install.
# ===========================================================================
check_beads() {
    if [ ! -d "$TARGET/.beads" ]; then
        record beads FAIL "missing: .beads/ (Beads not initialized in this target)" \
"Run \`bd init\` in the target. Every hook in the workflow reads task state
from .beads/; session-start.sh hard-exits without it."
        return
    fi
    if ! command -v bd >/dev/null 2>&1; then
        record beads FAIL ".beads/ present but bd is not on PATH — task state is unreachable" \
"Install Beads and make sure it resolves in a NON-interactive shell (hooks do
not read your login profile): compare \`bash -lc 'command -v bd'\` with
\`bash -c 'command -v bd'\`."
        return
    fi

    # Route through the --no-daemon shim (see the header note). Falls back to
    # the raw PATH only if the shim could not be written.
    local shim_path="$PATH"
    if mk_bd_shim "$WORKDIR/bin" >/dev/null 2>&1; then
        shim_path="$WORKDIR/bin:$PATH"
    fi

    local out="$WORKDIR/bd-doctor.out" err="$WORKDIR/bd-doctor.err" rc=0
    run_bounded 30 "$out" "$err" env "PATH=$shim_path" \
        bash -c "cd \"\$1\" && bd doctor" _ "$TARGET" || rc=$?
    if [ "$rc" = "124" ]; then
        record beads FAIL "\`bd doctor\` did not complete within 30s (unreachable)" \
"Two common causes. (1) NO NETWORK: bd doctor performs a GitHub release check,
so an air-gapped host can blow this 30s bound on an otherwise healthy install —
re-run with \`--skip beads\`. (2) A wedged daemon: this check already invokes bd
through a \`--no-daemon\` shim, so if plain \`bd --no-daemon doctor\` also hangs
in the target, the database itself needs attention."
        return
    fi
    if [ ! -s "$out" ] && [ "$rc" -ne 0 ]; then
        record beads FAIL "\`bd doctor\` exited $rc with no output (unreachable)" \
"Run \`bd doctor\` in the target by hand and fix what it reports. If it cannot
run at all, reinstall Beads."
        return
    fi

    # Text findings are informational ONLY (see the header note). bd 0.47.1
    # exits NON-ZERO on a perfectly healthy repo (advisory rows: "CLI Version
    # (latest: ...)", "Stale Closed Issues", "Uncommitted changes"), which is
    # exactly why exit status is not a FAIL condition here either.
    local warns flagged note=""
    warns=$(grep -c '⚠' "$out" 2>/dev/null | tr -d ' ' || echo "0")
    warns="${warns:-0}"
    flagged=$(grep -E '^[[:space:]]*(✗|x|X)[[:space:]]|[Ee][Rr][Rr][Oo][Rr]|FAIL' "$out" 2>/dev/null | head -3 || true)
    if [ -n "$flagged" ]; then
        note="
NOTE: bd doctor text findings (informational only; bd's wording varies by
version so these never fail this check):
$(printf '%s\n' "$flagged" | sed 's/^[[:space:]]*/  /')"
    elif [ "$warns" -gt 0 ] 2>/dev/null; then
        note="
NOTE: bd doctor reported $warns advisory warning(s) (informational only). Run
\`bd doctor\` in the target to read them."
    fi
    record beads PASS ".beads/ present; \`bd doctor\` reachable (exit $rc)$note"
}

# ===========================================================================
# Check: session_start — THE check.
#
# Symptom 1 of the P0 was "the plugin is installed and the session has no
# workflow at all". Its mechanism is that session-start.sh's two hard-exit
# paths print a bare {"error": ...} instead of a hookSpecificOutput envelope,
# so Claude Code receives NO workflow_engine block, NO delegation contract and
# NO gate instructions — and nothing says so. Nothing in this repo executed
# the hook against a rendered target before this check existed.
# ===========================================================================
check_session_start() {
    local script="$TARGET/.claude/scripts/session-start.sh"
    if [ ! -f "$script" ]; then
        record session_start FAIL "missing: .claude/scripts/session-start.sh" \
"Re-run the plugin installer. Without this hook the session gets no workflow
context whatsoever."
        return
    fi

    local sb
    sb=$(mk_probe_sandbox) || {
        record session_start FAIL "could not build a probe sandbox (mktemp/cp failed)" \
"Check that TMPDIR is writable and that the target's .claude tree is readable."
        return
    }

    local out="$WORKDIR/session-start.out" err="$WORKDIR/session-start.err" rc=0
    run_in_sandbox "$sb" 45 "$out" "$err" \
        bash "$DRIVE_STDIN" '{}' "$sb/.claude/scripts/session-start.sh" || rc=$?

    if [ "$rc" = "124" ]; then
        record session_start FAIL "session-start.sh did not complete within 45s" \
"The hook has a 30s runtime budget; a longer run means one of its bounded
sub-probes (model-select.sh's model fetch, codex-detect.sh's handshake) is
blocking. Run it by hand with CLAUDE_PROJECT_DIR set to a scratch dir and
watch which line stalls."
        return
    fi
    if [ "$rc" -ne 0 ]; then
        # Two separate head calls, not `head f1 f2`: the multi-file form emits
        # `==> file <==` banners that bury the actual message.
        local errline
        errline=$({ head -2 "$out"; head -2 "$err"; } 2>/dev/null | tr '\n' ' ' | cut -c1-240 || echo "")
        record session_start FAIL "session-start.sh exited $rc (expected 0); output: ${errline:-<empty>}" \
"A non-zero SessionStart exit means Claude Code gets NO additionalContext: the
session runs with the plugin installed and the orchestrator contract absent.
The two known bail paths are 'bd not found' and 'Beads not initialized' — both
of which print a bare {\"error\": ...} rather than a hook envelope. Fix the
underlying cause (bd on PATH in a NON-interactive shell; \`bd init\`)."
        return
    fi
    if ! jq -e . "$out" >/dev/null 2>&1; then
        record session_start FAIL "session-start.sh stdout is not valid JSON (first 200 bytes: $(head -c 200 "$out" 2>/dev/null | tr '\n' ' '))" \
"Claude Code silently ignores hook output that is not a JSON envelope. The
usual cause is a helper printing a banner to stdout inside the hook (bd's
\`✓ Updated issue\` line is the classic one) — every bd call in a hook must
redirect BOTH streams."
        return
    fi

    local event ctx bytes
    event=$(jq -r '.hookSpecificOutput.hookEventName // ""' "$out" 2>/dev/null || echo "")
    if [ "$event" != "SessionStart" ]; then
        record session_start FAIL "hookSpecificOutput.hookEventName is '${event:-<absent>}', expected 'SessionStart'" \
"The envelope shape is {\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",
\"additionalContext\":\"...\"}}. A bare {\"error\": ...} or a top-level
{\"decision\": ...} is dropped by the runtime with no diagnostic."
        return
    fi
    ctx=$(jq -r '.hookSpecificOutput.additionalContext // ""' "$out" 2>/dev/null || echo "")
    if [ -z "$ctx" ]; then
        record session_start FAIL "additionalContext is empty or not a string — the session would start with no workflow context" \
"Re-run the installer, then re-run the doctor. If additionalContext is empty
with every file present, the skill body extraction is failing: check that
SKILL.md still has its two \`---\` frontmatter delimiters."
        return
    fi
    bytes=$(printf '%s' "$ctx" | wc -c | tr -d ' ')
    bytes="${bytes:-0}"

    # A degraded block is a DELIBERATE signal from the hook, not a crash: it
    # means the hook stayed in-envelope and told us what is wrong. Echo its
    # own fix line verbatim rather than paraphrasing it.
    local degraded_fix=""
    if printf '%s' "$ctx" | grep -qF '<workflow_degraded'; then
        degraded_fix=$(printf '%s\n' "$ctx" \
            | awk '/<workflow_degraded/{inb=1} inb{print} /<\/workflow_degraded>/{if (inb) exit}' \
            | grep -E '^[[:space:]]*[Ff]ix:' | head -3 || true)
    fi

    local problems=""
    printf '%s' "$ctx" | grep -qF '<workflow_engine source=' \
        || problems="$problems no-<workflow_engine-source=-block;"
    if ! printf '%s' "$ctx" | grep -qF "$DOCTOR_DELEGATION_MARKER"; then
        # Discriminate the two causes rather than blaming the injection for
        # both: the marker can be missing because the injection failed, or
        # because SKILL.md no longer contains it (gutted body, or a rename).
        if [ -f "$TARGET/.claude/skills/workflow-engine/SKILL.md" ] \
           && ! grep -qF "$DOCTOR_DELEGATION_MARKER" "$TARGET/.claude/skills/workflow-engine/SKILL.md"; then
            problems="$problems SKILL.md-itself-lacks-the-'$DOCTOR_DELEGATION_MARKER'-section(see-the-skill-check;-if-the-rename-was-intentional-update-DOCTOR_DELEGATION_MARKER);"
        else
            problems="$problems SKILL.md-has-'$DOCTOR_DELEGATION_MARKER'-but-the-hook-did-not-inject-it;"
        fi
    fi
    [ "$bytes" -ge "$DOCTOR_MIN_CONTEXT_BYTES" ] \
        || problems="$problems additionalContext-only-${bytes}B(<${DOCTOR_MIN_CONTEXT_BYTES}B);"

    if [ -n "$problems" ]; then
        local detail="valid SessionStart envelope but the context is not usable:$problems"
        [ -n "$degraded_fix" ] && detail="$detail
<workflow_degraded> fix line (verbatim):
$degraded_fix"
        record session_start FAIL "$detail" \
"The delegation contract reaches Claude only through this block. Restore
.claude/skills/workflow-engine/SKILL.md (the fallback stub is a ONE-LINE
substitute for the whole contract) and re-run the doctor."
        return
    fi

    local detail="rc=0, valid SessionStart envelope, additionalContext ${bytes}B with <workflow_engine source=> and '$DOCTOR_DELEGATION_MARKER'"
    if [ -n "$degraded_fix" ]; then
        detail="$detail
NOTE: the context carries a <workflow_degraded> block. Its own fix line, verbatim:
$degraded_fix"
    fi
    record session_start PASS "$detail"
}

# ===========================================================================
# Checks: mcp_bd / mcp_code_graph
#
# Symptom 2 of the P0, caught the only way it can be: by BOOTING the server.
# Presence of bin/*.js proves nothing — both launchers are dynamic-import
# shims that die with ERR_MODULE_NOT_FOUND when node_modules is absent, and
# .gitignore excludes node_modules so the installer's shallow clone never had
# any to copy. Tool-count equality is exact, not >=, because "boots and
# registers nothing" is a real and otherwise-invisible failure.
# ===========================================================================
check_mcp_server() {
    local server_dir="$1"
    local name expected dir bin
    name=$(mcp_check_name_for "$server_dir")
    expected=$(tool_count_for "$server_dir")
    dir="$TARGET/.claude/mcp/$server_dir"
    bin="$dir/bin/$server_dir.js"

    if [ ! -d "$dir" ]; then
        record "$name" FAIL "missing server dir: .claude/mcp/$server_dir" \
"Re-run the plugin installer; it copies each .claude/mcp/*/ tree wholesale."
        return
    fi
    if [ ! -f "$bin" ]; then
        record "$name" FAIL "missing launcher: .claude/mcp/$server_dir/bin/$server_dir.js" \
"Re-run the plugin installer."
        return
    fi
    if ! command -v node >/dev/null 2>&1; then
        record "$name" FAIL "node is not on PATH, so the server cannot boot (see the deps check)" \
"Install node >= $DOCTOR_MIN_NODE_VERSION, or skip the server checks explicitly:
  workflow-doctor.sh --skip mcp_bd,mcp_code_graph"
        return
    fi
    # Named as a distinct failure because it is THE failure mode this whole
    # epic exists for, and its fix is one command.
    if [ ! -d "$dir/node_modules" ]; then
        record "$name" FAIL "dependencies never installed: .claude/mcp/$server_dir/node_modules is absent — the launcher is a dynamic-import shim and dies with ERR_MODULE_NOT_FOUND" \
"cd \"$dir\" && npm ci --omit=dev
(air-gapped: add --ignore-scripts; the lockfile has zero install scripts and
zero dev packages, so this needs no toolchain and no network beyond the
registry fetch.)"
        return
    fi

    local sb out err rc=0
    sb=$(mk_probe_sandbox) || sb="$WORKDIR"
    out="$WORKDIR/$name.jsonl"
    err="$WORKDIR/$name.err"
    run_in_sandbox "$sb" 30 "$out" "$err" bash "$DRIVE_MCP" "$bin" || rc=$?

    if [ "$rc" = "124" ]; then
        record "$name" FAIL "server did not answer the stdio handshake within 30s" \
"Run it by hand and watch stderr:
  cd \"$dir\" && node bin/$server_dir.js < /dev/null"
        return
    fi

    local init_frame list_frame server_name got
    init_frame=$(grep -F '"id":1' "$out" 2>/dev/null | head -1 || echo "")
    list_frame=$(grep -F '"id":2' "$out" 2>/dev/null | head -1 || echo "")
    server_name=$(printf '%s' "$init_frame" | jq -r '.result.serverInfo.name // ""' 2>/dev/null || echo "")

    if [ -z "$server_name" ]; then
        local stub
        stub=$(head -c 240 "$err" 2>/dev/null | tr '\n' ' ' || echo "")
        record "$name" FAIL "no serverInfo.name in the initialize response (exit $rc); stderr: ${stub:-<empty>}" \
"An ERR_MODULE_NOT_FOUND here means node_modules is present but incomplete:
  cd \"$dir\" && npm ci --omit=dev
Anything else: run the launcher by hand and read stderr."
        return
    fi

    got=$(printf '%s' "$list_frame" | jq -r '(.result.tools // []) | length' 2>/dev/null || echo "0")
    got="${got:-0}"

    if [ -z "$expected" ]; then
        # No table row: degrade to "boots and lists >= 1 tool" + a NOTE, so an
        # unlisted server is still smoke-tested rather than silently trusted.
        if [ "$got" -ge 1 ]; then
            record "$name" PASS "serverInfo.name=$server_name, tools/list returned $got tool(s)
NOTE: $server_dir has no DOCTOR_TOOL_COUNTS row, so this degraded to a >=1 check. Add \"$server_dir:<count>\" to the table in workflow-doctor.sh to pin the surface."
        else
            record "$name" FAIL "serverInfo.name=$server_name but tools/list returned 0 tools" \
"The server boots but registers nothing. Check its src/server.js tool
registration and re-run \`npm ci --omit=dev\` in $dir."
        fi
        return
    fi

    if [ "$got" -ne "$expected" ]; then
        local names
        names=$(printf '%s' "$list_frame" | jq -r '[(.result.tools // [])[].name] | sort | join(",")' 2>/dev/null || echo "")
        record "$name" FAIL "serverInfo.name=$server_name but tools/list returned $got tool(s), expected exactly $expected; got: ${names:-<none>}" \
"Either the server surface changed (then update DOCTOR_TOOL_COUNTS in
workflow-doctor.sh, both server READMEs' \`N tools total.\` sentences, and the
Tools column of docs/MCP_SERVERS.md in the SAME commit — mcp-deps.test.sh
cross-checks all four), or the install is partial:
  cd \"$dir\" && npm ci --omit=dev"
        return
    fi
    record "$name" PASS "serverInfo.name=$server_name, tools/list returned exactly $expected tool(s)"
}

# ===========================================================================
# Check: gate_pretooluse
# ===========================================================================
check_gate_pretooluse() {
    local script="$TARGET/.claude/scripts/prevent-orchestrator-edits.sh"
    if [ ! -f "$script" ]; then
        record gate_pretooluse FAIL "missing: .claude/scripts/prevent-orchestrator-edits.sh" \
"Re-run the plugin installer. Without this hook the orchestrator's
delegate-only contract has no defense-in-depth enforcement."
        return
    fi

    local sb
    sb=$(mk_probe_sandbox) || {
        record gate_pretooluse FAIL "could not build a probe sandbox" \
"Check that TMPDIR is writable."
        return
    }

    local payload='{"subagent_name":"orchestrator","tool_name":"Write","tool_input":{"file_path":"/tmp/x.ts"}}'
    local out="$WORKDIR/gate-pretooluse.out" err="$WORKDIR/gate-pretooluse.err" rc=0
    run_in_sandbox "$sb" 20 "$out" "$err" \
        bash "$DRIVE_STDIN" "$payload" "$sb/.claude/scripts/prevent-orchestrator-edits.sh" || rc=$?

    if [ "$rc" = "124" ]; then
        record gate_pretooluse FAIL "prevent-orchestrator-edits.sh did not complete within 20s" \
"The hook has a 5s runtime budget; a stall means jq is missing or wedged."
        return
    fi
    if [ "$rc" -ne 0 ]; then
        record gate_pretooluse FAIL "prevent-orchestrator-edits.sh exited $rc (expected 0)" \
"A PreToolUse hook must exit 0 and express its verdict in the JSON envelope.
Run it by hand with the same payload and read stderr."
        return
    fi

    local decision
    decision=$(jq -r '.hookSpecificOutput.permissionDecision // ""' "$out" 2>/dev/null || echo "")
    if [ "$decision" != "deny" ]; then
        record gate_pretooluse FAIL "an orchestrator Write was NOT denied: permissionDecision='${decision:-<absent>}' (expected 'deny'); raw: $(head -c 200 "$out" 2>/dev/null | tr '\n' ' ')" \
"This is the structural guard the plugin sells as its core value. Restore
.claude/scripts/prevent-orchestrator-edits.sh from the plugin source. Note the
envelope shape: PreToolUse uses hookSpecificOutput.permissionDecision, NOT a
top-level {\"decision\": ...}."
        return
    fi
    record gate_pretooluse PASS "orchestrator Write denied via hookSpecificOutput.permissionDecision=deny"
}

# ===========================================================================
# Check: gate_stop
#
# Drives the real Stop hook over a synthetic, non-doc, non-beads change set
# with NO active task and NO approval — the state in which the gate MUST
# block. Sandboxed, so it cannot see (or clear) the live project's tracker,
# baseline, iteration counters or approval.
# ===========================================================================
check_gate_stop() {
    local script="$TARGET/.claude/scripts/verify-before-stop.sh"
    if [ ! -f "$script" ]; then
        record gate_stop FAIL "missing: .claude/scripts/verify-before-stop.sh" \
"Re-run the plugin installer. Without the Stop hook there is no QA gate at
all: work reaches the user unreviewed."
        return
    fi

    local sb
    sb=$(mk_probe_sandbox) || {
        record gate_stop FAIL "could not build a probe sandbox" \
"Check that TMPDIR is writable."
        return
    }

    # A path that is (a) not denylisted, (b) not doc-only, (c) not
    # beads/gate bookkeeping — so none of the three fast paths can fire and
    # the gate has to reach its approval decision.
    printf 'src/workflow-doctor-probe.ts\n' > "$sb/.claude/.qa-tracking/changed-files.txt"
    rm -f "$sb/.claude/.qa-tracking/current-task" \
          "$sb/.claude/.qa-tracking/current-task.repo" \
          "$sb/.claude/.qa-tracking/approved" 2>/dev/null || true

    local out="$WORKDIR/gate-stop.out" err="$WORKDIR/gate-stop.err" rc=0
    run_in_sandbox "$sb" 90 "$out" "$err" \
        bash "$DRIVE_STDIN" '{"stop_reason":"end_turn"}' "$sb/.claude/scripts/verify-before-stop.sh" || rc=$?

    if [ "$rc" = "124" ]; then
        record gate_stop FAIL "verify-before-stop.sh did not complete within 90s" \
"The gate runs the project's full test suite when one is detected. The probe
sandbox carries no manifest, so a stall means detect-stack.sh resolved a
runner it should not have — run it by hand with CLAUDE_PROJECT_DIR set to an
empty dir and check its output."
        return
    fi
    if [ "$rc" -ne 0 ]; then
        record gate_stop FAIL "verify-before-stop.sh exited $rc (expected 0)" \
"A Stop hook that aborts emits nothing, and the hooks contract reads 'no
output' as ALLOW — i.e. an aborting gate FAILS OPEN and releases unreviewed
work. Run it by hand and read stderr."
        return
    fi
    if ! jq -e . "$out" >/dev/null 2>&1; then
        record gate_stop FAIL "Stop hook stdout is not valid JSON (first 200 bytes: $(head -c 200 "$out" 2>/dev/null | tr '\n' ' '))" \
"Non-JSON stdout is ignored by the runtime, which means the block never
happens. The usual cause is a bd banner leaking to stdout from inside the
hook — every bd call in a hook must redirect BOTH streams."
        return
    fi

    local decision
    decision=$(jq -r '.decision // ""' "$out" 2>/dev/null || echo "")
    if [ "$decision" != "block" ]; then
        record gate_stop FAIL "unapproved change set was NOT blocked: top-level .decision='${decision:-<absent>}' (expected 'block'); raw: $(head -c 240 "$out" 2>/dev/null | tr '\n' ' ')" \
"The QA gate is open — work can reach the user with no review. Restore
.claude/scripts/verify-before-stop.sh AND its siblings from the plugin source:
the gate fails CLOSED only when workflow-denylist.sh, impact-report.sh,
review-check.sh, current-task.sh and qa-gate.sh are all present. Note the
envelope shape: Stop uses a TOP-LEVEL {\"decision\":\"block\",\"reason\":...},
not hookSpecificOutput."
        return
    fi
    record gate_stop PASS "synthetic unapproved change set blocked via top-level .decision=block"
}

# ===========================================================================
# Runner
# ===========================================================================

# Internal consistency: the mcp_* names the tool-count table implies must all
# exist in the check registry. Catches "added a third server to the table and
# forgot to register its check" at run time rather than in review.
for _pair in $DOCTOR_TOOL_COUNTS; do
    _implied=$(mcp_check_name_for "${_pair%%:*}")
    case " $DOCTOR_CHECK_NAMES " in
        *" $_implied "*) ;;
        *)
            printf 'workflow-doctor.sh: internal error — DOCTOR_TOOL_COUNTS names %s but the check registry has no "%s" entry.\n' \
                "${_pair%%:*}" "$_implied" >&2
            exit 2
            ;;
    esac
done

if [ "$QUIET" != "1" ]; then
    printf 'workflow-doctor: verifying %s\n\n' "$TARGET"
fi

for _check in $DOCTOR_CHECK_NAMES; do
    if is_skipped "$_check"; then
        record "$_check" SKIP "skipped via --skip"
        continue
    fi
    case "$_check" in
        deps)            check_deps ;;
        agents)          check_agents ;;
        skill)           check_skill ;;
        mcp_config)      check_mcp_config ;;
        settings_hooks)  check_settings_hooks ;;
        beads)           check_beads ;;
        session_start)   check_session_start ;;
        mcp_bd)          check_mcp_server "bd-mcp" ;;
        mcp_code_graph)  check_mcp_server "code-graph-mcp" ;;
        gate_pretooluse) check_gate_pretooluse ;;
        gate_stop)       check_gate_stop ;;
        *)
            record "$_check" FAIL "no implementation bound to this registry name" \
"DOCTOR_CHECK_NAMES lists '$_check' but the runner's case statement has no arm
for it. Bind it or remove it from the registry."
            ;;
    esac
done

TOTAL=$((PASSED + FAILED + SKIPPED))

if [ -n "$JSON_OUT" ]; then
    if ! jq -s --argjson p "$PASSED" --argjson f "$FAILED" --argjson s "$SKIPPED" \
        '{checks: ., passed: $p, failed: $f, skipped: $s}' \
        "$CHECKS_JSONL" > "$JSON_OUT" 2>/dev/null; then
        printf 'workflow-doctor.sh: could not write the JSON report to %s\n' "$JSON_OUT" >&2
        exit 2
    fi
fi

printf '\nworkflow-doctor: %d check(s) — %d passed, %d failed, %d skipped (target: %s)\n' \
    "$TOTAL" "$PASSED" "$FAILED" "$SKIPPED" "$TARGET"

if [ "$FAILED" -gt 0 ]; then
    printf 'workflow-doctor: FAILED. Each FAIL above carries an indented fix: line.\n'
    exit 1
fi
exit 0

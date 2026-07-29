#!/bin/bash
# installer-target-functional.sh — L2 component spec: does a RENDERED TARGET
# ACTUALLY ORCHESTRATE? (v4.1 / claude-workflow-plugin-20e, epic 2br, C0c.)
#
# WHAT THIS PROVES, AND WHY IT IS UNLIKE EVERY OTHER INSTALLER SPEC HERE
# ---------------------------------------------------------------------
# The v4.1 P0 shipped three times behind a fully green suite because every
# installer assertion in this repo was PRESENCE or SHA256. installer-mcp-
# config.sh, installer-manifest-parity.sh and installer-v3-upgrade.sh ask "is
# the file there, does it hash right, did the key appear". `make install-test`
# was two `test` calls. The closest thing to a behavioural assertion anywhere
# was "settings.json gained the SubagentStart hook KEY" — the key, never the
# hook running. A target could therefore be byte-perfect, hash-parity-clean and
# COMPLETELY UNABLE TO ORCHESTRATE, and every test would stay green.
#
# So this spec asserts FUNCTION. Every section either executes something inside
# a rendered target or reads a workflow-doctor.sh verdict that was produced by
# executing something. "Complete" is not the claim; "works" is.
#
# DELIBERATE DEVIATION: NO bd_required_or_skip
# --------------------------------------------
# Every other bd-touching spec in this tier calls bd_required_or_skip, which
# exits 0 with a SKIPPED line when the real Beads CLI is absent — and CI sets
# BD_SHIM_ONLY=1 precisely because there is no public bd installer to curl. A
# spec guarded that way NEVER RUNS IN CI, which is exactly where the P0 needed
# catching. install.sh, workflow-doctor.sh and session-start.sh between them ask
# bd for six things (--version, init, hooks, doctor, prime, blocked/list), and
# every one of those is satisfiable by a stub, so we write a fake-bd into a bin
# dir prepended to PATH and run for real — in CI and on dev machines alike.
# mk_fixture is skipped for the same reason (it wraps the REAL bd); the fixture
# cleanup array from lib/fixture.sh is still used for teardown.
#
# SECTIONS
#   1. Fresh install, --skip-mcp-deps  — node_modules ABSENT in both server
#      dirs. This exists so section 3's presence assertion is a DISCRIMINATOR
#      rather than a tautology: without it, "node_modules exists" could be true
#      because the installer copied a developer tree and never proved anything.
#   2. Doctor with the two server checks skipped — exit 0, and five named checks
#      PASS BY NAME out of --json-out.
#   3. Fresh install, DEFAULT flags — @modelcontextprotocol/sdk present in both
#      server trees. Network-gated (net_available).
#   4. Full doctor, no skips — exit 0, all 11 checks PASS. THIS IS THE ASSERTION
#      THAT WOULD HAVE CAUGHT THE ORIGINAL P0.
#   5. Offline boot leg — a --skip-mcp-deps target plus a copied node_modules
#      boots both servers: mcp_bd 21 tools, mcp_code_graph 7. Runs with no
#      network, so the air-gapped recipe in docs/MCP_SERVERS.md is executed,
#      not merely written down.
#   6. Degraded SessionStart — the C0c fix. With bd off PATH, and again with
#      .beads/ removed, the hook must still emit a VALID envelope carrying BOTH
#      the workflow contract and a <workflow_degraded> block that names the
#      cause. 6e is the healthy control that keeps 6a/6b non-vacuous.
#   7. METAs — six mutations, each breaking a CONFIRMED cause from the epic's
#      root-cause record, each asserted to fail the doctor BY NAME, each undone
#      and re-asserted. 7g re-runs the whole check set afterwards so no META can
#      pass by permanently poisoning the fixture.
#   8. Installer-level META — a JSONC .claude/settings.json under --mode=2 and
#      --mode=3. This is symptom-1 candidate (5) from the epic record: the merge
#      refuses, the operator's file is left alone, and ZERO hooks end up wired.
#      Asserts it is now LOUD (exit 3, settings_hooks named) while STILL
#      non-destructive (the operator's bytes are untouched).
#
# RUNTIME. Measured on an M-series laptop: an install is ~7s, a doctor run with
# the two server checks skipped is ~5s, a full one ~9s. Section 3's `npm ci` is
# the only network step and the only slow one. The METAs use skip_all_but() so a
# mutation aimed at one check does not pay for the other ten.
#
# EVERY TARGET IS AN mktemp -d (claude-workflow-plugin-1nz). Nothing here writes
# to the live repo: workflow-doctor.test.sh carries a live-repo non-mutation
# assertion that fails spuriously if a concurrent spec touches the checkout.

set -u

PLUGIN_ROOT=$(plugin_root)

WORK=$(mktemp -d -t cwp-target-func.XXXXXX)
__COMPONENT_FIXTURES_TO_CLEAN+=("$WORK")
SAVE="$WORK/save"
mkdir -p "$SAVE"

# --- fake bd -----------------------------------------------------------------
# The whole `bd` surface install.sh, workflow-doctor.sh and session-start.sh
# touch. Two deliberate upgrades over installer-v3-upgrade.sh's copy, each of
# which is load-bearing HERE and was not there:
#
#   1. It strips a leading --no-daemon. workflow-doctor.sh's mk_bd_shim wraps bd
#      as `exec <real-bd> --no-daemon "$@"` (bd 0.47.1's daemon autostart
#      crashes), so every shim'd call arrives with the subcommand in $2. A fake
#      that dispatched on $1 would answer "ok (--no-daemon)" to `bd --version`,
#      the doctor's deps check would read that as bd-version-unparseable, and
#      the FAIL would look like a doctor bug.
#   2. `init` CREATES .beads/. Real bd does; the doctor's `beads` check FAILs
#      when the directory is absent. A print-only fake would make a correctly
#      installed target look broken.
#
# `doctor` output must never contain the string 'error' — install.sh greps for
# it case-insensitively and would print a spurious warning.
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/bd" <<'FAKE_BD'
#!/bin/bash
while [ "${1:-}" = "--no-daemon" ]; do shift; done
case "${1:-}" in
    --version|-v|version)
        printf 'bd 0.99.0 (fake-bd for installer specs)\n'
        ;;
    init)
        mkdir -p .beads 2>/dev/null || true
        printf 'fake-bd: initialized Beads workspace\n'
        ;;
    hooks)
        printf 'fake-bd: git hooks installed\n'
        ;;
    doctor)
        printf 'fake-bd: all checks passed\n'
        ;;
    prime)
        printf '# fake-bd prime: no workspace content\n'
        ;;
    blocked|list)
        if printf '%s\n' "$@" | grep -qx -- '--json'; then printf '[]\n'; fi
        ;;
    *)
        printf 'fake-bd: ok (%s)\n' "${1:-}"
        ;;
esac
exit 0
FAKE_BD
chmod +x "$FAKE_BIN/bd"
export PATH="$FAKE_BIN:$PATH"

# --- helpers -----------------------------------------------------------------

# yesno <command...> — "yes" when the command succeeds, "no" when it does not.
# The wrapped command's own output is discarded, and that is load-bearing: this
# runs inside $( ), so a command that PRINTS as well as returning a status would
# otherwise prepend its stdout to the yes/no and the comparison would silently
# be against garbage.
yesno() {
    if "$@" >/dev/null 2>&1; then printf 'yes'; else printf 'no'; fi
}

# mk_target <dir> — an empty git repo ready to be installed into. install.sh
# offers to `git init` when the target is not a repo; pre-initialising keeps
# that prompt off the critical path.
mk_target() {
    mkdir -p "$1"
    (
        cd "$1" || exit 1
        git init -q >/dev/null 2>&1 || true
        git -c user.email=test@example.com -c user.name=test \
            commit --allow-empty -q -m "target baseline" >/dev/null 2>&1 || true
    )
}

# install_into <dir> <log> [install.sh flags...] — the SHIPPED installer.
#
# </dev/null is load-bearing: install.sh reads stdin for its interactive mode
# prompt, and a spec that leaves stdin attached hangs the CI runner.
#
# Flags are passed per call rather than exported the way installer-v3-upgrade.sh
# exports CWP_SKIP_MCP_DEPS: section 3 needs the real `npm ci` path, so a
# file-scope export would disable the one thing that section exists to test.
install_into() {
    local dir="$1" log="$2"; shift 2
    bash "$PLUGIN_ROOT/install.sh" "$@" "$dir" </dev/null >"$log" 2>&1
}

# run_doctor <target> <json-out> <log> [doctor flags...] — returns the doctor's
# exit code (0 all passed / 1 a check failed / 2 usage). Always writes JSON: the
# per-check assertions read that, never the human rendering, because the JSON is
# a stable contract and the terminal output is not.
run_doctor() {
    local target="$1" json="$2" log="$3"; shift 3
    bash "$target/.claude/scripts/workflow-doctor.sh" \
        --target "$target" --json-out "$json" --quiet "$@" >"$log" 2>&1
}

# status_of <json> <check-name> — PASS / FAIL / SKIP, or "<absent>" when the
# report has no such check. "<absent>" rather than "" so a typo'd check name
# fails loudly instead of comparing empty-to-empty.
status_of() {
    local s
    s=$(jq -r --arg n "$2" \
        'first((.checks // [])[] | select(.name == $n) | .status) // "<absent>"' \
        "$1" 2>/dev/null || printf '<absent>')
    [ -n "$s" ] || s="<absent>"
    printf '%s' "$s"
}

# detail_of <json> <check-name> — the check's detail string (may be multi-line).
detail_of() {
    jq -r --arg n "$2" \
        'first((.checks // [])[] | select(.name == $n) | .detail) // ""' \
        "$1" 2>/dev/null || printf ''
}

# ctx_of <envelope-file> — hookSpecificOutput.additionalContext, or "".
ctx_of() {
    jq -r '.hookSpecificOutput.additionalContext // ""' "$1" 2>/dev/null || printf ''
}

# run_session_start <target> <out> <err> <PATH-to-use> — execute the TARGET's
# OWN session-start.sh the way Claude Code would: an empty JSON payload on
# stdin, cwd at the project root, CLAUDE_PROJECT_DIR set. Returns its exit code.
#
# CODEX_USER_CONFIG points at a nonexistent in-target path for the same reason
# mk_fixture does it: codex-detect.sh would otherwise read the host developer's
# ~/.claude.json and the reviewer lane would depend on whose laptop is running.
run_session_start() {
    local target="$1" out="$2" err="$3" use_path="$4" rc=0
    (
        cd "$target" || exit 90
        printf '{}' | env \
            "PATH=$use_path" \
            "HOME=${HOME:-/tmp}" \
            "CLAUDE_PROJECT_DIR=$target" \
            "ANTHROPIC_API_KEY=" \
            "CODEX_USER_CONFIG=$target/.no-codex-config.json" \
            "CODEX_DETECT_TIMEOUT_S=1" \
            bash "$target/.claude/scripts/session-start.sh"
    ) >"$out" 2>"$err" || rc=$?
    return "$rc"
}

# mcp_sdk_present <target> <server-dir> — 0 when the installed SDK package the
# launchers dynamic-import is really there. Asserted at the PACKAGE level, not
# `[ -d node_modules ]`: C0b's third defect was exactly that a failed `npm ci`
# leaves node_modules as a husk of empty directories, so the directory test
# answers "yes" for a tree that cannot boot.
mcp_sdk_present() {
    [ -d "$1/.claude/mcp/$2/node_modules/@modelcontextprotocol/sdk" ]
}

# --- the doctor's own check registry, read from the shipped script ------------
# Extracted rather than hardcoded so a renamed or added check updates this spec
# automatically instead of drifting. The count assertion below is the vacuity
# guard: if the extraction ever returns nothing, skip_all_but() would produce an
# empty --skip and every META would silently widen into a full run.
DOCTOR_CHECKS=$(sed -n 's/^DOCTOR_CHECK_NAMES="\(.*\)"$/\1/p' \
    "$PLUGIN_ROOT/.claude/scripts/workflow-doctor.sh" | head -1)
DOCTOR_CHECK_COUNT=$(printf '%s' "$DOCTOR_CHECKS" | wc -w | tr -d ' ')
DOCTOR_CHECK_COUNT="${DOCTOR_CHECK_COUNT:-0}"

# skip_all_but <name>... — a --skip value naming every registered check EXCEPT
# the ones passed, so a META that targets one check does not pay for the rest.
# The doctor REJECTS unknown --skip names with exit 2, which is what makes the
# derived list safe: a drifted name is an immediate hard error, never a silent
# no-op skip.
skip_all_but() {
    local keep=" $* " out="" n
    for n in $DOCTOR_CHECKS; do
        case "$keep" in
            *" $n "*) ;;
            *)        out="$out,$n" ;;
        esac
    done
    printf '%s' "${out#,}"
}

assert_eq "installer-target-functional 0: the doctor's check registry extracted (11 names)" \
    "11" "$DOCTOR_CHECK_COUNT"
for _n in deps agents skill mcp_config settings_hooks beads session_start mcp_bd mcp_code_graph gate_pretooluse gate_stop; do
    case " $DOCTOR_CHECKS " in
        *" $_n "*) ;;
        *)
            assert_eq "installer-target-functional 0: registry contains '$_n'" \
                "present" "absent"
            ;;
    esac
done

# node/npm gate. Five of the eight sections need a node runtime (the doctor's
# `deps` check hard-requires node AND npm, and the two server checks boot node).
# The other three — the degraded SessionStart section and the installer-level
# METAs — do not, so this gates SECTIONS rather than exiting the spec: a
# node-less host still gets the C0c regression coverage, and says which
# assertions it lost.
HAVE_NODE=no
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    HAVE_NODE=yes
fi

# ===========================================================================
# Section 1: fresh install with --skip-mcp-deps — dependencies really absent
# ===========================================================================
# --skip-verify as well, deliberately. install.sh runs the doctor itself and
# exits 3 when a check fails, and on a --skip-mcp-deps target the two server
# checks fail BY DESIGN. Letting that happen here would conflate "the copy
# worked" with "the verdict was green"; section 2 is where the verdict is read,
# from JSON, one check at a time. The exit-3 contract itself is covered by
# .claude/scripts/tests/installer-flags.test.sh.
T_SKIP="$WORK/t-skipdeps"
mk_target "$T_SKIP"
SKIP_RC=0
install_into "$T_SKIP" "$WORK/install-skip.log" --skip-mcp-deps --skip-verify || SKIP_RC=$?
if [ "$SKIP_RC" -ne 0 ]; then
    printf '  diagnostic: installer exited %s; tail of log:\n' "$SKIP_RC"
    tail -20 "$WORK/install-skip.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-target-functional 1: install --skip-mcp-deps --skip-verify exits 0" \
    "0" "$SKIP_RC"
assert_eq "installer-target-functional 1: target has .claude/scripts/session-start.sh" \
    "yes" "$(yesno test -f "$T_SKIP/.claude/scripts/session-start.sh")"
assert_eq "installer-target-functional 1: target has .claude/scripts/workflow-doctor.sh" \
    "yes" "$(yesno test -f "$T_SKIP/.claude/scripts/workflow-doctor.sh")"
# The discriminator for section 3. If this is ever "yes", section 3's presence
# assertion proves nothing at all.
assert_eq "installer-target-functional 1: bd-mcp/node_modules is ABSENT under --skip-mcp-deps" \
    "no" "$(yesno test -e "$T_SKIP/.claude/mcp/bd-mcp/node_modules")"
assert_eq "installer-target-functional 1: code-graph-mcp/node_modules is ABSENT under --skip-mcp-deps" \
    "no" "$(yesno test -e "$T_SKIP/.claude/mcp/code-graph-mcp/node_modules")"
# ...and the launcher IS there, so section 3's difference is dependencies and
# nothing else.
assert_eq "installer-target-functional 1: bd-mcp launcher present (only deps are missing)" \
    "yes" "$(yesno test -f "$T_SKIP/.claude/mcp/bd-mcp/bin/bd-mcp.js")"

# ===========================================================================
# Section 2: the doctor's verdict on that target, read BY NAME
# ===========================================================================
# Exit 0 with the two server checks skipped is the claim "everything that does
# not need npm works". The five by-name assertions are what make it specific:
# an aggregate "0 failed" is also what a doctor that ran nothing would report.
D2="$WORK/doctor-skip.json"
D2_RC=0
run_doctor "$T_SKIP" "$D2" "$WORK/doctor-skip.log" --skip mcp_bd,mcp_code_graph || D2_RC=$?
if [ "$D2_RC" -ne 0 ]; then
    printf '  diagnostic: doctor exited %s; failing checks:\n' "$D2_RC"
    jq -r '(.checks // [])[] | select(.status == "FAIL") | "    FAIL " + .name + ": " + ((.detail // "") | split("\n")[0])' \
        "$D2" 2>/dev/null || sed 's/^/    /' "$WORK/doctor-skip.log"
fi
if [ "$HAVE_NODE" = "yes" ]; then
    assert_eq "installer-target-functional 2: doctor --skip mcp_bd,mcp_code_graph exits 0" \
        "0" "$D2_RC"
else
    printf 'SKIPPED: section 2 exit-0 assertion (node/npm absent; the deps check cannot pass)\n'
fi
assert_eq "installer-target-functional 2: settings_hooks PASS" "PASS" "$(status_of "$D2" settings_hooks)"
assert_eq "installer-target-functional 2: session_start PASS"   "PASS" "$(status_of "$D2" session_start)"
assert_eq "installer-target-functional 2: agents PASS"          "PASS" "$(status_of "$D2" agents)"
assert_eq "installer-target-functional 2: gate_pretooluse PASS" "PASS" "$(status_of "$D2" gate_pretooluse)"
assert_eq "installer-target-functional 2: gate_stop PASS"       "PASS" "$(status_of "$D2" gate_stop)"
# The two skipped checks must read SKIP, not PASS. A --skip that silently
# recorded a pass would make every "exit 0" above meaningless.
assert_eq "installer-target-functional 2: mcp_bd is SKIP (not a silent PASS)" \
    "SKIP" "$(status_of "$D2" mcp_bd)"
assert_eq "installer-target-functional 2: mcp_code_graph is SKIP (not a silent PASS)" \
    "SKIP" "$(status_of "$D2" mcp_code_graph)"

# ===========================================================================
# Section 3: fresh install with DEFAULT flags — dependencies really installed
# ===========================================================================
# THE C0b FIX, executed. `npm ci` runs in the TARGET, so this needs the npm
# registry; net_available() gates it and the skip is logged rather than silent.
T_FULL=""
if [ "$HAVE_NODE" != "yes" ]; then
    printf 'SKIPPED: sections 3-5 (node/npm not on PATH)\n'
elif ! net_available; then
    printf 'SKIPPED: sections 3-4 (npm registry unreachable; set CWP_NET=1 to force)\n'
else
    T_FULL="$WORK/t-full"
    mk_target "$T_FULL"
    FULL_RC=0
    install_into "$T_FULL" "$WORK/install-full.log" || FULL_RC=$?
    if [ "$FULL_RC" -ne 0 ]; then
        printf '  diagnostic: installer exited %s; tail of log:\n' "$FULL_RC"
        tail -25 "$WORK/install-full.log" 2>/dev/null | sed 's/^/    /'
    fi
    assert_eq "installer-target-functional 3: install with DEFAULT flags exits 0" \
        "0" "$FULL_RC"
    assert_eq "installer-target-functional 3: bd-mcp has @modelcontextprotocol/sdk installed" \
        "yes" "$(yesno mcp_sdk_present "$T_FULL" bd-mcp)"
    assert_eq "installer-target-functional 3: code-graph-mcp has @modelcontextprotocol/sdk installed" \
        "yes" "$(yesno mcp_sdk_present "$T_FULL" code-graph-mcp)"

    # =======================================================================
    # Section 4: the full doctor, no skips — THE ASSERTION THAT WOULD HAVE
    # CAUGHT THE ORIGINAL P0
    # =======================================================================
    # Both MCP servers are BOOTED over stdio here and their tools/list is
    # counted. Nothing in this repo did that against a rendered target before
    # C0a, which is why "both servers dead in every curl install" shipped three
    # times behind a green suite.
    D4="$WORK/doctor-full.json"
    D4_RC=0
    run_doctor "$T_FULL" "$D4" "$WORK/doctor-full.log" || D4_RC=$?
    if [ "$D4_RC" -ne 0 ]; then
        printf '  diagnostic: full doctor exited %s; failing checks:\n' "$D4_RC"
        jq -r '(.checks // [])[] | select(.status == "FAIL") | "    FAIL " + .name + ": " + ((.detail // "") | split("\n")[0])' \
            "$D4" 2>/dev/null || true
    fi
    assert_eq "installer-target-functional 4: full doctor (no skips) exits 0" "0" "$D4_RC"
    assert_eq "installer-target-functional 4: 11 checks passed, 0 failed, 0 skipped" \
        "11 0 0" \
        "$(jq -r '"\(.passed) \(.failed) \(.skipped)"' "$D4" 2>/dev/null || echo "?")"
    for _c in $DOCTOR_CHECKS; do
        assert_eq "installer-target-functional 4: $_c PASS" "PASS" "$(status_of "$D4" "$_c")"
    done
fi

# ===========================================================================
# Section 5: the OFFLINE boot leg — no network, servers still boot
# ===========================================================================
# docs/MCP_SERVERS.md and workflow-doctor.sh --help both tell an air-gapped
# operator to copy node_modules/ from a machine that has run `npm ci`. This
# EXECUTES that recipe instead of asserting it reads well: a --skip-mcp-deps
# target plus a copied dependency tree must boot both servers and register
# exactly 21 / 7 tools. It also gives sections 7b its fixture.
T_OFFLINE=""
SEC5_RAN=no
if [ "$HAVE_NODE" != "yes" ]; then
    :
elif [ ! -d "$PLUGIN_ROOT/.claude/mcp/bd-mcp/node_modules/@modelcontextprotocol/sdk" ] \
  || [ ! -d "$PLUGIN_ROOT/.claude/mcp/code-graph-mcp/node_modules/@modelcontextprotocol/sdk" ]; then
    printf 'SKIPPED: section 5 (this checkout has no MCP node_modules to copy; run "npm ci" in .claude/mcp/*/)\n'
else
    SEC5_RAN=yes
    T_OFFLINE="$WORK/t-offline"
    mk_target "$T_OFFLINE"
    OFF_RC=0
    install_into "$T_OFFLINE" "$WORK/install-offline.log" --skip-mcp-deps --skip-verify || OFF_RC=$?
    assert_eq "installer-target-functional 5: air-gap fixture installs with --skip-mcp-deps" \
        "0" "$OFF_RC"
    # Pre-state: the servers CANNOT boot yet. Without this the section could
    # pass on a target that was already fine, proving nothing about the copy.
    D5A="$WORK/doctor-offline-before.json"
    run_doctor "$T_OFFLINE" "$D5A" "$WORK/doctor-offline-before.log" \
        --skip "$(skip_all_but mcp_bd mcp_code_graph)" || true
    assert_eq "installer-target-functional 5: BEFORE the copy, mcp_bd FAILs (no dependencies)" \
        "FAIL" "$(status_of "$D5A" mcp_bd)"

    cp -R "$PLUGIN_ROOT/.claude/mcp/bd-mcp/node_modules" \
          "$T_OFFLINE/.claude/mcp/bd-mcp/node_modules"
    cp -R "$PLUGIN_ROOT/.claude/mcp/code-graph-mcp/node_modules" \
          "$T_OFFLINE/.claude/mcp/code-graph-mcp/node_modules"

    D5B="$WORK/doctor-offline-after.json"
    D5B_RC=0
    run_doctor "$T_OFFLINE" "$D5B" "$WORK/doctor-offline-after.log" \
        --skip "$(skip_all_but mcp_bd mcp_code_graph)" || D5B_RC=$?
    assert_eq "installer-target-functional 5: AFTER the copy, the two server checks exit 0" \
        "0" "$D5B_RC"
    assert_eq "installer-target-functional 5: mcp_bd PASS" "PASS" "$(status_of "$D5B" mcp_bd)"
    assert_eq "installer-target-functional 5: mcp_code_graph PASS" "PASS" "$(status_of "$D5B" mcp_code_graph)"
    # The COUNTS, not just the verdict: "boots but registers nothing" is a real
    # failure that a status-only assertion cannot see.
    assert_contains "installer-target-functional 5: bd-mcp registers exactly 21 tools" \
        "exactly 21 tool(s)" "$(detail_of "$D5B" mcp_bd)"
    assert_contains "installer-target-functional 5: code-graph-mcp registers exactly 7 tools" \
        "exactly 7 tool(s)" "$(detail_of "$D5B" mcp_code_graph)"
fi

# ===========================================================================
# Section 6: DEGRADED SessionStart — the C0c fix
# ===========================================================================
# The hook used to `exit 1` and print a bare {"error": ...} when bd was off PATH
# or .beads/ was missing. Claude Code drops non-envelope output silently, so the
# session ran with the plugin installed, no delegation contract and no gate
# instructions — symptom 1 of the epic. Nothing in this repo asserted on those
# two outputs; they appeared only in docs/HOOKS.md prose and in six e2e fixture
# copies. A documented failure path with no test is not a failure path.
#
# PATH=/usr/bin:/bin is the reproduction of the LIKELIEST live trigger: hooks run
# in a non-interactive, non-login shell, so a bd under ~/.local/bin or a version
# manager resolves in the operator's terminal and not here.
BARE_PATH="/usr/bin:/bin"

# --- 6a: bd off PATH ---------------------------------------------------------
S6A_RC=0
run_session_start "$T_SKIP" "$WORK/ss-nobd.json" "$WORK/ss-nobd.err" "$BARE_PATH" || S6A_RC=$?
if [ "$S6A_RC" -ne 0 ]; then
    printf '  diagnostic: session-start.sh exited %s; stdout/stderr:\n' "$S6A_RC"
    head -5 "$WORK/ss-nobd.json" 2>/dev/null | sed 's/^/    out: /'
    head -5 "$WORK/ss-nobd.err" 2>/dev/null | sed 's/^/    err: /'
fi
assert_eq "installer-target-functional 6a: session-start.sh with NO bd on PATH exits 0" \
    "0" "$S6A_RC"
assert_eq "installer-target-functional 6a: its stdout is valid JSON" \
    "yes" "$(yesno jq -e . "$WORK/ss-nobd.json")"
assert_eq "installer-target-functional 6a: hookEventName is SessionStart" \
    "SessionStart" \
    "$(jq -r '.hookSpecificOutput.hookEventName // "<absent>"' "$WORK/ss-nobd.json" 2>/dev/null || echo "<absent>")"
S6A_CTX=$(ctx_of "$WORK/ss-nobd.json")
# BOTH markers. The contract must still ship (workflow_engine) AND the session
# must be told it cannot be enforced (workflow_degraded). Either one alone is a
# failure: contract-without-warning is the old silent bug wearing an envelope,
# warning-without-contract is a session with no delegation rules at all.
assert_contains "installer-target-functional 6a: context carries <workflow_engine source=" \
    '<workflow_engine source=' "$S6A_CTX"
assert_contains "installer-target-functional 6a: context carries <workflow_degraded" \
    '<workflow_degraded' "$S6A_CTX"
assert_contains "installer-target-functional 6a: the degraded block is severity=high" \
    '<workflow_degraded severity="high">' "$S6A_CTX"
assert_contains "installer-target-functional 6a: it names bd as the missing dependency" \
    'the Beads CLI (bd) does not resolve on PATH' "$S6A_CTX"
assert_contains "installer-target-functional 6a: PATH divergence is named as the likely cause" \
    'PATH DIVERGENCE' "$S6A_CTX"
assert_contains "installer-target-functional 6a: it gives the discriminating command" \
    "bash -lc 'command -v bd'" "$S6A_CTX"
assert_contains "installer-target-functional 6a: it says the delegation contract still applies" \
    'MUST still delegate' "$S6A_CTX"
assert_contains "installer-target-functional 6a: it says enforcement is advisory" \
    'ENFORCEMENT IS THEREFORE ADVISORY' "$S6A_CTX"
assert_contains "installer-target-functional 6a: it points at workflow-doctor.sh" \
    'workflow-doctor.sh' "$S6A_CTX"
# The OLD shape must be gone, not merely supplemented.
assert_not_contains "installer-target-functional 6a: the bare {\"error\": ...} bail is gone" \
    '{"error"' "$(cat "$WORK/ss-nobd.json")"
# The degraded block must lead. An LLM that reads 13KB of workflow rules before
# the warning has already decided how to behave by the time it arrives.
assert_eq "installer-target-functional 6a: the degraded block is the FIRST thing in the context" \
    "yes" \
    "$(printf '%s' "$S6A_CTX" | head -1 | grep -qF '<workflow_degraded' && printf 'yes' || printf 'no')"

# --- 6b: bd present, .beads/ removed ----------------------------------------
T_NOBEADS="$WORK/t-nobeads"
mkdir -p "$T_NOBEADS"
cp -R "$T_SKIP/.claude" "$T_NOBEADS/.claude"
rm -rf "$T_NOBEADS/.claude/.qa-tracking"/* 2>/dev/null || true
(
    cd "$T_NOBEADS" || exit 1
    git init -q >/dev/null 2>&1 || true
    git -c user.email=test@example.com -c user.name=test \
        commit --allow-empty -q -m "no-beads baseline" >/dev/null 2>&1 || true
)
assert_eq "installer-target-functional 6b: fixture really has no .beads/ (precondition)" \
    "no" "$(yesno test -e "$T_NOBEADS/.beads")"
S6B_RC=0
run_session_start "$T_NOBEADS" "$WORK/ss-nobeads.json" "$WORK/ss-nobeads.err" "$PATH" || S6B_RC=$?
assert_eq "installer-target-functional 6b: session-start.sh with bd but NO .beads/ exits 0" \
    "0" "$S6B_RC"
assert_eq "installer-target-functional 6b: its stdout is valid JSON" \
    "yes" "$(yesno jq -e . "$WORK/ss-nobeads.json")"
assert_eq "installer-target-functional 6b: hookEventName is SessionStart" \
    "SessionStart" \
    "$(jq -r '.hookSpecificOutput.hookEventName // "<absent>"' "$WORK/ss-nobeads.json" 2>/dev/null || echo "<absent>")"
S6B_CTX=$(ctx_of "$WORK/ss-nobeads.json")
assert_contains "installer-target-functional 6b: context carries <workflow_engine source=" \
    '<workflow_engine source=' "$S6B_CTX"
assert_contains "installer-target-functional 6b: context carries <workflow_degraded" \
    '<workflow_degraded' "$S6B_CTX"
assert_contains "installer-target-functional 6b: it names the missing Beads workspace" \
    'no Beads workspace' "$S6B_CTX"
assert_contains "installer-target-functional 6b: its fix line is 'bd init'" \
    'bd init' "$S6B_CTX"
# The two causes must not be confused: bd IS on PATH here, so the PATH-divergence
# advice would send the operator down the wrong road.
assert_not_contains "installer-target-functional 6b: it does NOT blame PATH divergence" \
    'PATH DIVERGENCE' "$S6B_CTX"

# --- 6c: the gate baseline still gets captured in a degraded session ---------
# session-start.sh's baseline capture is DELIBERATELY not gated on bd (measured:
# qa-gate.sh baseline-capture is git-only and exits 0 with bd absent). In a
# degraded session the Stop hook is the ONLY enforcement surface still standing,
# and without this baseline its git fallback counts every pre-existing dirty
# path as this session's unreviewed work. Pinned here so a future "tidy up the
# degraded path" change cannot quietly remove it.
assert_eq "installer-target-functional 6c: a degraded (no-bd) session still captured the gate baseline" \
    "yes" "$(yesno test -f "$T_SKIP/.claude/.qa-tracking/gate-baseline")"
assert_eq "installer-target-functional 6c: ...and logged no sync error doing it" \
    "no" "$(yesno test -s "$T_SKIP/.claude/.qa-tracking/sync-errors.log")"

# --- 6d: the envelope survives a jq-less host --------------------------------
# The old writer interpolated $(echo "$CONTEXT" | jq -Rs .) directly into a
# heredoc, so with jq absent the line became `"additionalContext": ` with
# NOTHING after it — invalid JSON, which the runtime discards, which is
# indistinguishable from having no hook at all. Built by symlinking every
# /usr/bin + /bin entry EXCEPT jq, because a PATH of "/usr/bin:/bin" still finds
# jq on macOS 15+ and on ubuntu runners: the obvious way to write this test
# silently does not test it.
NOJQ_BIN="$WORK/bin-nojq"
mkdir -p "$NOJQ_BIN"
for _f in /usr/bin/* /bin/*; do
    _b=$(basename "$_f")
    [ "$_b" = "jq" ] && continue
    ln -sf "$_f" "$NOJQ_BIN/$_b" 2>/dev/null || true
done
ln -sf "$FAKE_BIN/bd" "$NOJQ_BIN/bd" 2>/dev/null || true
assert_eq "installer-target-functional 6d: the jq-less PATH really has no jq (precondition)" \
    "no" "$(yesno env -i "PATH=$NOJQ_BIN" bash -c 'command -v jq')"
assert_eq "installer-target-functional 6d: ...and still has bd and awk (precondition)" \
    "yes" "$(yesno env -i "PATH=$NOJQ_BIN" bash -c 'command -v bd >/dev/null && command -v awk')"
S6D_RC=0
run_session_start "$T_SKIP" "$WORK/ss-nojq.json" "$WORK/ss-nojq.err" "$NOJQ_BIN" || S6D_RC=$?
assert_eq "installer-target-functional 6d: session-start.sh with NO jq exits 0" "0" "$S6D_RC"
assert_eq "installer-target-functional 6d: its stdout is STILL valid JSON (built-in encoder)" \
    "yes" "$(yesno jq -e . "$WORK/ss-nojq.json")"
assert_eq "installer-target-functional 6d: hookEventName is SessionStart" \
    "SessionStart" \
    "$(jq -r '.hookSpecificOutput.hookEventName // "<absent>"' "$WORK/ss-nojq.json" 2>/dev/null || echo "<absent>")"
S6D_CTX=$(ctx_of "$WORK/ss-nojq.json")
assert_contains "installer-target-functional 6d: the fallback-encoded context still carries the contract" \
    '<workflow_engine source=' "$S6D_CTX"
assert_contains "installer-target-functional 6d: ...and the delegation marker survives encoding" \
    'Mandatory delegation flow' "$S6D_CTX"
assert_contains "installer-target-functional 6d: ...and it says jq is what is missing" \
    'jq does not resolve on PATH' "$S6D_CTX"

# --- 6e: the HEALTHY control -------------------------------------------------
# Without this, 6a/6b/6d would all pass against a hook that emitted
# <workflow_degraded> unconditionally.
S6E_RC=0
run_session_start "$T_SKIP" "$WORK/ss-healthy.json" "$WORK/ss-healthy.err" "$PATH" || S6E_RC=$?
assert_eq "installer-target-functional 6e: CONTROL — a healthy session exits 0" "0" "$S6E_RC"
S6E_CTX=$(ctx_of "$WORK/ss-healthy.json")
assert_contains "installer-target-functional 6e: CONTROL — it carries the workflow contract" \
    '<workflow_engine source=' "$S6E_CTX"
assert_not_contains "installer-target-functional 6e: CONTROL — and NO degraded block" \
    '<workflow_degraded' "$S6E_CTX"

# --- 6f: a missing core utility does not kill the hook -----------------------
# THE THIRD CONTEXT-LOSING PATH, found by measurement rather than from the
# brief. The hook runs under `set -e`, so ANY command substitution whose binary
# is missing killed it before it printed a byte — and "no output" is read by the
# runtime as "no hook", the same symptom-1 shape as the two removed bails. awk
# is the one that mattered: it extracts the SKILL.md body. Measured on the
# pre-fix hook: rc=127, ZERO bytes on stdout.
NOAWK_BIN="$WORK/bin-noawk"
mkdir -p "$NOAWK_BIN"
for _f in /usr/bin/* /bin/*; do
    _b=$(basename "$_f")
    case "$_b" in awk|nawk|gawk|mawk) continue ;; esac
    ln -sf "$_f" "$NOAWK_BIN/$_b" 2>/dev/null || true
done
ln -sf "$FAKE_BIN/bd" "$NOAWK_BIN/bd" 2>/dev/null || true
assert_eq "installer-target-functional 6f: the awk-less PATH really has no awk (precondition)" \
    "no" "$(yesno env -i "PATH=$NOAWK_BIN" bash -c 'command -v awk')"
S6F_RC=0
run_session_start "$T_SKIP" "$WORK/ss-noawk.json" "$WORK/ss-noawk.err" "$NOAWK_BIN" || S6F_RC=$?
assert_eq "installer-target-functional 6f: session-start.sh with NO awk exits 0" "0" "$S6F_RC"
assert_eq "installer-target-functional 6f: its stdout is valid JSON" \
    "yes" "$(yesno jq -e . "$WORK/ss-noawk.json")"
S6F_CTX=$(ctx_of "$WORK/ss-noawk.json")
# It degrades to the skill STUB rather than to the emergency envelope: the
# delegation contract still reaches the model, in one line instead of 13KB.
assert_contains "installer-target-functional 6f: the contract block is still emitted" \
    '<workflow_engine source=' "$S6F_CTX"
assert_contains "installer-target-functional 6f: ...carrying the skill stub, which names the cause" \
    'Workflow skill body unavailable' "$S6F_CTX"
assert_contains "installer-target-functional 6f: ...and the delegation rule survives in the stub" \
    'MUST delegate' "$S6F_CTX"

# --- 6g: META-TEST — the emergency envelope catches what nothing anticipated --
# The guarantee "this hook always emits a valid envelope" is enforced at the
# EXIT trap, not at each call site, precisely because the next unanticipated
# death will not be awk. Injecting one proves the backstop is wired: the
# injection is anchored on a comment's text, never a line number.
T6G="$WORK/t-trap"
mkdir -p "$T6G"
cp -R "$T_SKIP/.claude" "$T6G/.claude"
mkdir -p "$T6G/.beads"
rm -rf "$T6G/.claude/.qa-tracking"/* 2>/dev/null || true
(
    cd "$T6G" || exit 1
    git init -q >/dev/null 2>&1 || true
    git -c user.email=test@example.com -c user.name=test \
        commit --allow-empty -q -m "trap baseline" >/dev/null 2>&1 || true
)
awk '{print} /^# 5\. Surface accumulated warnings/{print "META_TEST_nonexistent_binary_xyz"}' \
    "$T_SKIP/.claude/scripts/session-start.sh" > "$T6G/.claude/scripts/session-start.sh"
chmod +x "$T6G/.claude/scripts/session-start.sh"
assert_eq "installer-target-functional 6g: META-TEST precondition — the fault really got injected" \
    "yes" "$(yesno grep -qF 'META_TEST_nonexistent_binary_xyz' "$T6G/.claude/scripts/session-start.sh")"
assert_eq "installer-target-functional 6g: META-TEST precondition — the injected copy is still valid bash" \
    "yes" "$(yesno bash -n "$T6G/.claude/scripts/session-start.sh")"
S6G_RC=0
run_session_start "$T6G" "$WORK/ss-trap.json" "$WORK/ss-trap.err" "$PATH" || S6G_RC=$?
assert_eq "installer-target-functional 6g: META-TEST — a mid-script hard failure still exits 0" \
    "0" "$S6G_RC"
assert_eq "installer-target-functional 6g: META-TEST — and still emits valid JSON" \
    "yes" "$(yesno jq -e . "$WORK/ss-trap.json")"
assert_eq "installer-target-functional 6g: META-TEST — with the right hookEventName" \
    "SessionStart" \
    "$(jq -r '.hookSpecificOutput.hookEventName // "<absent>"' "$WORK/ss-trap.json" 2>/dev/null || echo "<absent>")"
S6G_CTX=$(ctx_of "$WORK/ss-trap.json")
assert_contains "installer-target-functional 6g: META-TEST — the emergency block says the hook died" \
    'exited unexpectedly' "$S6G_CTX"
assert_contains "installer-target-functional 6g: META-TEST — and still states the delegation contract" \
    'MUST delegate' "$S6G_CTX"
# ONE envelope, not two concatenated: the emit flag is set before the write, so
# a normal run cannot also trigger the trap. `jq -e .` above accepts a single
# value; this counts the objects to be sure.
assert_eq "installer-target-functional 6g: META-TEST — exactly ONE envelope was emitted" \
    "1" "$(jq -s 'length' "$WORK/ss-trap.json" 2>/dev/null || echo "?")"
assert_eq "installer-target-functional 6g: META-TEST CONTROL — an unfaulted run also emits exactly one" \
    "1" "$(jq -s 'length' "$WORK/ss-healthy.json" 2>/dev/null || echo "?")"

# --- 6h: the doctor and the degraded block meet -----------------------------
# TWO HALVES BUILT BY SEPARATE TASKS, never wired together by a test until now.
# workflow-doctor.sh (C0a) greps a <workflow_degraded> block for its own
# '^[[:space:]]*[Ff]ix:' lines and echoes up to three verbatim; session-start.sh
# (C0c) is what writes them. Either side could drift — a reworded block, a
# changed grep — and both tasks' own suites would stay green.
#
# The verdict is the interesting part: session_start must still PASS. The hook
# DID its job (valid envelope, contract delivered, cause named); it is `beads`
# that reports the actual defect. A doctor that failed session_start here would
# be blaming the messenger, and an operator would go looking in the wrong file.
D6H="$WORK/doctor-degraded.json"
run_doctor "$T_NOBEADS" "$D6H" "$WORK/doctor-degraded.log" \
    --skip "$(skip_all_but session_start)" || true
D6H_DETAIL=$(detail_of "$D6H" session_start)
assert_eq "installer-target-functional 6h: session_start still PASSes on a degraded target (the hook did its job)" \
    "PASS" "$(status_of "$D6H" session_start)"
assert_contains "installer-target-functional 6h: ...and the report SAYS the context is degraded" \
    "<workflow_degraded> block" "$D6H_DETAIL"
assert_contains "installer-target-functional 6h: ...echoing the hook's own fix line verbatim" \
    "bd init" "$D6H_DETAIL"
# Non-vacuity: the healthy target must NOT carry that note.
D6H2="$WORK/doctor-healthy-note.json"
run_doctor "$T_SKIP" "$D6H2" "$WORK/doctor-healthy-note.log" \
    --skip "$(skip_all_but session_start)" || true
assert_not_contains "installer-target-functional 6h: CONTROL — a healthy target's report carries no degraded note" \
    "<workflow_degraded> block" "$(detail_of "$D6H2" session_start)"

# ===========================================================================
# Section 7: META-TESTs — each breaks a CONFIRMED cause and is caught BY NAME
# ===========================================================================
# Discipline for every META here:
#   - mutate, then VERIFY THE MUTATION LANDED before asserting anything;
#   - assert the doctor fails on the SPECIFIC check, by name, not just "exit 1";
#   - undo the mutation and re-assert, so none of them can pass by permanently
#     poisoning the fixture for the ones that follow;
#   - anchor on text patterns, never line numbers.

# --- 7a: session-start.sh emits an EMPTY additionalContext -------------------
# THE LOAD-BEARING ONE. This stub exits 0 and emits a structurally perfect
# SessionStart envelope; only a check that reads the CONTENT can tell it from
# the real hook. If session_start ever weakens to "the script runs and emits
# JSON", this META goes green and says so.
cp "$T_SKIP/.claude/scripts/session-start.sh" "$SAVE/session-start.sh.orig"
cat > "$T_SKIP/.claude/scripts/session-start.sh" <<'STUB_SS'
#!/bin/bash
# META-TEST stub (installer-target-functional.sh 7a): valid envelope, no context.
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":""}}\n'
exit 0
STUB_SS
chmod +x "$T_SKIP/.claude/scripts/session-start.sh"
assert_eq "installer-target-functional 7a: META-TEST precondition — the stub really replaced the hook" \
    "yes" "$(yesno grep -qF 'META-TEST stub' "$T_SKIP/.claude/scripts/session-start.sh")"
M7A="$WORK/meta-7a.json"
M7A_RC=0
run_doctor "$T_SKIP" "$M7A" "$WORK/meta-7a.log" --skip "$(skip_all_but session_start)" || M7A_RC=$?
assert_eq "installer-target-functional 7a: META-TEST — an empty additionalContext FAILs session_start" \
    "FAIL" "$(status_of "$M7A" session_start)"
assert_eq "installer-target-functional 7a: META-TEST — and the doctor exits non-zero" \
    "1" "$M7A_RC"
assert_contains "installer-target-functional 7a: META-TEST — the detail names the empty context" \
    "additionalContext is empty" "$(detail_of "$M7A" session_start)"
cp "$SAVE/session-start.sh.orig" "$T_SKIP/.claude/scripts/session-start.sh"
chmod +x "$T_SKIP/.claude/scripts/session-start.sh"
M7A2="$WORK/meta-7a-restored.json"
M7A2_RC=0
run_doctor "$T_SKIP" "$M7A2" "$WORK/meta-7a-restored.log" --skip "$(skip_all_but session_start)" || M7A2_RC=$?
assert_eq "installer-target-functional 7a: META-TEST — restoring the hook exits 0 again" "0" "$M7A2_RC"
assert_eq "installer-target-functional 7a: META-TEST — session_start PASS after restore" \
    "PASS" "$(status_of "$M7A2" session_start)"

# --- 7b: one server's node_modules removed — PER-SERVER granularity ----------
# `mv` rather than `rm -rf`: the restore has to put back the exact tree, and a
# rename is instant on the same filesystem.
if [ "$SEC5_RAN" = "yes" ]; then
    mv "$T_OFFLINE/.claude/mcp/bd-mcp/node_modules" "$SAVE/bd-mcp-node_modules"
    assert_eq "installer-target-functional 7b: META-TEST precondition — bd-mcp deps really gone" \
        "no" "$(yesno test -e "$T_OFFLINE/.claude/mcp/bd-mcp/node_modules")"
    assert_eq "installer-target-functional 7b: META-TEST precondition — code-graph deps still there" \
        "yes" "$(yesno test -d "$T_OFFLINE/.claude/mcp/code-graph-mcp/node_modules")"
    M7B="$WORK/meta-7b.json"
    M7B_RC=0
    run_doctor "$T_OFFLINE" "$M7B" "$WORK/meta-7b.log" \
        --skip "$(skip_all_but mcp_bd mcp_code_graph)" || M7B_RC=$?
    assert_eq "installer-target-functional 7b: META-TEST — mcp_bd FAILs" \
        "FAIL" "$(status_of "$M7B" mcp_bd)"
    # The whole point: one dead server must not mask or condemn the other.
    assert_eq "installer-target-functional 7b: META-TEST — mcp_code_graph still PASSes (per-server granularity)" \
        "PASS" "$(status_of "$M7B" mcp_code_graph)"
    assert_eq "installer-target-functional 7b: META-TEST — the doctor exits non-zero" "1" "$M7B_RC"
    mv "$SAVE/bd-mcp-node_modules" "$T_OFFLINE/.claude/mcp/bd-mcp/node_modules"
    M7B2="$WORK/meta-7b-restored.json"
    M7B2_RC=0
    run_doctor "$T_OFFLINE" "$M7B2" "$WORK/meta-7b-restored.log" \
        --skip "$(skip_all_but mcp_bd mcp_code_graph)" || M7B2_RC=$?
    assert_eq "installer-target-functional 7b: META-TEST — restoring the deps exits 0 again" \
        "0" "$M7B2_RC"
else
    printf 'SKIPPED: section 7b META-TEST (no MCP dependency tree available to remove)\n'
fi

# --- 7c: the Stop hook deleted from settings.json ---------------------------
# Symptom-1 candidate (5) in miniature: a settings.json that parses fine and is
# missing one event. The gate it belonged to is simply absent, with no error
# anywhere at runtime.
cp "$T_SKIP/.claude/settings.json" "$SAVE/settings.json.orig"
jq 'del(.hooks.Stop)' "$SAVE/settings.json.orig" > "$T_SKIP/.claude/settings.json"
assert_eq "installer-target-functional 7c: META-TEST precondition — .hooks.Stop really removed" \
    "no" "$(yesno jq -e '.hooks.Stop' "$T_SKIP/.claude/settings.json")"
assert_eq "installer-target-functional 7c: META-TEST precondition — the file is still valid JSON" \
    "yes" "$(yesno jq -e . "$T_SKIP/.claude/settings.json")"
M7C="$WORK/meta-7c.json"
M7C_RC=0
run_doctor "$T_SKIP" "$M7C" "$WORK/meta-7c.log" --skip "$(skip_all_but settings_hooks)" || M7C_RC=$?
assert_eq "installer-target-functional 7c: META-TEST — settings_hooks FAILs" \
    "FAIL" "$(status_of "$M7C" settings_hooks)"
assert_contains "installer-target-functional 7c: META-TEST — the detail NAMES the missing Stop event" \
    "Stop" "$(detail_of "$M7C" settings_hooks)"
assert_eq "installer-target-functional 7c: META-TEST — the doctor exits non-zero" "1" "$M7C_RC"
cp "$SAVE/settings.json.orig" "$T_SKIP/.claude/settings.json"
M7C2="$WORK/meta-7c-restored.json"
M7C2_RC=0
run_doctor "$T_SKIP" "$M7C2" "$WORK/meta-7c-restored.log" --skip "$(skip_all_but settings_hooks)" || M7C2_RC=$?
assert_eq "installer-target-functional 7c: META-TEST — restoring settings.json exits 0 again" \
    "0" "$M7C2_RC"

# --- 7d: orchestrator.md deleted --------------------------------------------
# The installer silently dropped .claude/agents/grader.md for two releases while
# every test stayed green (LESSONS.md, 2026-06-12). A missing agent file is a
# missing agent, and the SDK says nothing.
mv "$T_SKIP/.claude/agents/orchestrator.md" "$SAVE/orchestrator.md"
assert_eq "installer-target-functional 7d: META-TEST precondition — orchestrator.md really gone" \
    "no" "$(yesno test -e "$T_SKIP/.claude/agents/orchestrator.md")"
M7D="$WORK/meta-7d.json"
M7D_RC=0
run_doctor "$T_SKIP" "$M7D" "$WORK/meta-7d.log" --skip "$(skip_all_but agents)" || M7D_RC=$?
assert_eq "installer-target-functional 7d: META-TEST — agents FAILs" "FAIL" "$(status_of "$M7D" agents)"
assert_contains "installer-target-functional 7d: META-TEST — the detail names orchestrator.md" \
    "orchestrator.md" "$(detail_of "$M7D" agents)"
assert_eq "installer-target-functional 7d: META-TEST — the doctor exits non-zero" "1" "$M7D_RC"
mv "$SAVE/orchestrator.md" "$T_SKIP/.claude/agents/orchestrator.md"
M7D2="$WORK/meta-7d-restored.json"
M7D2_RC=0
run_doctor "$T_SKIP" "$M7D2" "$WORK/meta-7d-restored.log" --skip "$(skip_all_but agents)" || M7D2_RC=$?
assert_eq "installer-target-functional 7d: META-TEST — restoring the agent exits 0 again" "0" "$M7D2_RC"

# --- 7e: the PreToolUse gate neutered ---------------------------------------
# Not deleted — REPLACED by a hook that emits a valid envelope, exits 0 and
# ALLOWS the write. Only a check that reads permissionDecision can tell the
# difference, which is the difference between "the file is there" and "the gate
# denies". This is the structural guard the plugin sells as its core value.
cp "$T_SKIP/.claude/scripts/prevent-orchestrator-edits.sh" "$SAVE/prevent-orchestrator-edits.sh.orig"
cat > "$T_SKIP/.claude/scripts/prevent-orchestrator-edits.sh" <<'STUB_PT'
#!/bin/bash
# META-TEST stub (installer-target-functional.sh 7e): valid envelope, allows all.
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
exit 0
STUB_PT
chmod +x "$T_SKIP/.claude/scripts/prevent-orchestrator-edits.sh"
assert_eq "installer-target-functional 7e: META-TEST precondition — the neutered gate is in place" \
    "yes" "$(yesno grep -qF 'META-TEST stub' "$T_SKIP/.claude/scripts/prevent-orchestrator-edits.sh")"
M7E="$WORK/meta-7e.json"
M7E_RC=0
run_doctor "$T_SKIP" "$M7E" "$WORK/meta-7e.log" --skip "$(skip_all_but gate_pretooluse)" || M7E_RC=$?
assert_eq "installer-target-functional 7e: META-TEST — gate_pretooluse FAILs" \
    "FAIL" "$(status_of "$M7E" gate_pretooluse)"
assert_contains "installer-target-functional 7e: META-TEST — the detail says the Write was not denied" \
    "was NOT denied" "$(detail_of "$M7E" gate_pretooluse)"
assert_eq "installer-target-functional 7e: META-TEST — the doctor exits non-zero" "1" "$M7E_RC"
cp "$SAVE/prevent-orchestrator-edits.sh.orig" "$T_SKIP/.claude/scripts/prevent-orchestrator-edits.sh"
chmod +x "$T_SKIP/.claude/scripts/prevent-orchestrator-edits.sh"
M7E2="$WORK/meta-7e-restored.json"
M7E2_RC=0
run_doctor "$T_SKIP" "$M7E2" "$WORK/meta-7e-restored.log" --skip "$(skip_all_but gate_pretooluse)" || M7E2_RC=$?
assert_eq "installer-target-functional 7e: META-TEST — restoring the gate exits 0 again" "0" "$M7E2_RC"

# --- 7f: .beads/ removed -----------------------------------------------------
mv "$T_SKIP/.beads" "$SAVE/beads-dir"
assert_eq "installer-target-functional 7f: META-TEST precondition — .beads/ really gone" \
    "no" "$(yesno test -e "$T_SKIP/.beads")"
M7F="$WORK/meta-7f.json"
M7F_RC=0
run_doctor "$T_SKIP" "$M7F" "$WORK/meta-7f.log" --skip "$(skip_all_but beads)" || M7F_RC=$?
assert_eq "installer-target-functional 7f: META-TEST — beads FAILs" "FAIL" "$(status_of "$M7F" beads)"
assert_eq "installer-target-functional 7f: META-TEST — the doctor exits non-zero" "1" "$M7F_RC"
mv "$SAVE/beads-dir" "$T_SKIP/.beads"
M7F2="$WORK/meta-7f-restored.json"
M7F2_RC=0
run_doctor "$T_SKIP" "$M7F2" "$WORK/meta-7f-restored.log" --skip "$(skip_all_but beads)" || M7F2_RC=$?
assert_eq "installer-target-functional 7f: META-TEST — restoring .beads/ exits 0 again" "0" "$M7F2_RC"

# --- 7g: fixture integrity ---------------------------------------------------
# Every META above re-asserted only the check it targeted. This re-runs the
# WHOLE non-server check set, so a mutation that was "restored" imperfectly —
# wrong mode, wrong content, a leftover file — cannot hide behind a narrow
# re-assertion. If section 2 was green and this is not, a META broke the fixture.
M7G="$WORK/meta-7g-integrity.json"
M7G_RC=0
run_doctor "$T_SKIP" "$M7G" "$WORK/meta-7g-integrity.log" --skip mcp_bd,mcp_code_graph || M7G_RC=$?
if [ "$M7G_RC" -ne 0 ]; then
    printf '  diagnostic: post-META integrity run failed; failing checks:\n'
    jq -r '(.checks // [])[] | select(.status == "FAIL") | "    FAIL " + .name + ": " + ((.detail // "") | split("\n")[0])' \
        "$M7G" 2>/dev/null || true
fi
if [ "$HAVE_NODE" = "yes" ]; then
    assert_eq "installer-target-functional 7g: after all METAs, the full check set is green again" \
        "0" "$M7G_RC"
fi
assert_eq "installer-target-functional 7g: 9 passed, 0 failed after the METAs" \
    "9 0" "$(jq -r '"\(.passed) \(.failed)"' "$M7G" 2>/dev/null || echo "?")"

# ===========================================================================
# Section 8: installer-level META — a JSONC settings.json is now LOUD
# ===========================================================================
# Symptom-1 candidate (5) from the epic's root-cause record, reproduced. An
# Update whose target has a .claude/settings.json that is not exactly one JSON
# object (empty, JSONC-with-comments, malformed) makes the merge REFUSE. The
# operator's file is left untouched — which is right — but the result was ZERO
# hooks wired and exit 0, with one red line mid-scroll followed by "Installation
# complete." That is the whole failure: not the refusal, the SILENCE about it.
#
# Both properties are asserted together on purpose, because the tempting "fix"
# for the silence is to overwrite the operator's file, and that trades a silent
# non-install for silent data loss.
jsonc_case() {
    local mode="$1" tag="$2"
    local t="$WORK/t-jsonc-$tag"
    mk_target "$t"
    mkdir -p "$t/.claude"
    # `#` is not valid JSON (nor, strictly, JSONC — which uses //), and neither
    # is any comment: jq refuses the file either way, which is exactly the
    # operator-file shape install.sh's json_single_object() gate rejects.
    printf '# my own settings, hand-written\n{}\n' > "$t/.claude/settings.json"
    cp "$t/.claude/settings.json" "$SAVE/settings-$tag.orig"

    local rc=0
    install_into "$t" "$WORK/install-jsonc-$tag.log" "--mode=$mode" --skip-mcp-deps || rc=$?

    # exit 3 = "every file landed and a functional check does not pass", which
    # is precisely this situation. 0 would be the old lie; 1 would say "nothing
    # was written", which is false and would send the operator to re-run.
    assert_eq "installer-target-functional 8: --mode=$mode with a JSONC settings.json exits 3" \
        "3" "$rc"
    assert_contains "installer-target-functional 8: --mode=$mode readout NAMES settings_hooks" \
        "settings_hooks" "$(cat "$WORK/install-jsonc-$tag.log")"
    # ...and the operator's bytes are untouched. Loudness must not have been
    # bought with a destructive change.
    local same
    same=$(yesno cmp -s "$SAVE/settings-$tag.orig" "$t/.claude/settings.json")
    if [ "$same" != "yes" ]; then
        printf '  diagnostic: the operator file changed. diff (orig vs after):\n'
        diff "$SAVE/settings-$tag.orig" "$t/.claude/settings.json" 2>/dev/null | head -10 | sed 's/^/    /'
    fi
    assert_eq "installer-target-functional 8: --mode=$mode leaves the operator's settings.json BYTE-UNCHANGED" \
        "yes" "$same"
    # The tree really did install; this is "installed but not working", not
    # "aborted". Otherwise exit 3 would be describing the wrong state.
    assert_eq "installer-target-functional 8: --mode=$mode still wrote the plugin tree" \
        "yes" "$(yesno test -f "$t/.claude/scripts/verify-before-stop.sh")"
}
jsonc_case 2 mode2
jsonc_case 3 mode3

# --- 8c: the CONTROL ---------------------------------------------------------
# Without this, section 8's "the readout names settings_hooks" would also pass
# for an installer that printed every check name on every run.
#
# Note what this control ALSO shows: it exits 3 as well, because --skip-mcp-deps
# leaves the two server checks failing. So THE EXIT CODE DOES NOT DISCRIMINATE
# between "your settings.json blocked every hook" and "you skipped npm ci" — only
# the named check does. That is the same shape as C0b's husk defect, where both
# arms exited 3 and the whole difference lived in the readout.
T8C="$WORK/t-jsonc-control"
mk_target "$T8C"
C8_RC=0
install_into "$T8C" "$WORK/install-jsonc-control.log" --mode=2 --skip-mcp-deps || C8_RC=$?
assert_eq "installer-target-functional 8c: CONTROL — the exit code alone does NOT discriminate (3 either way)" \
    "3" "$C8_RC"
assert_not_contains "installer-target-functional 8c: CONTROL — a target with NO pre-existing settings.json does not name settings_hooks" \
    "settings_hooks" "$(cat "$WORK/install-jsonc-control.log")"
assert_eq "installer-target-functional 8c: CONTROL — its settings.json is valid JSON with hooks wired" \
    "yes" "$(yesno jq -e '.hooks | type == "object"' "$T8C/.claude/settings.json")"

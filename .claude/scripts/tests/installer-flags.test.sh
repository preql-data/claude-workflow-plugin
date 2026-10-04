#!/bin/bash
# installer-flags.test.sh — L1 spec for install.sh's ARGUMENT CONTRACT
# (v4.1 Phase U0 / claude-workflow-plugin-pnf, closing x15 review finding
# R1-F4: the exclusivity exit was verified by hand and by nothing else).
#
# WHAT THIS PROTECTS
# ------------------
# `--upgrade` and `--mode` answer the same question by different mechanisms:
# --upgrade owns the whole decision (timestamped backup, per-file hash
# classification, verdict-driven writes) while --mode picks one flat behaviour
# for an existing .claude/. Letting one silently win would make the DESTRUCTIVE
# choice unpredictable — an operator who typed both would have no way to know
# whether their tree was about to be classified or clobbered. The installer
# refuses instead, and that refusal is what this spec pins.
#
# ORDERING IS PART OF THE CONTRACT. Argument validation runs BEFORE the
# prerequisite checks, so a wrong invocation is reported as a wrong invocation
# even on a machine with no git / jq / bd installed. If the checks ever migrate
# below the prereq block, an operator on a fresh machine would be told to
# install Beads when their real problem is two conflicting flags. Section 3
# runs the installer with a PATH that cannot see bd, and section 3's control
# proves that PATH really is prereq-hostile — otherwise "still exits 1" would
# be satisfied by a run that failed for the wrong reason.
#
# ASSERTION ANCHORING: every check is anchored to TEXT (a flag name, a message
# fragment, an exit code) and never to a line number.
#
# SECTIONS
#   0. Preflight: the script exists and parses.
#   1. --help: exit 0, both flags documented, exclusivity documented, and
#      (v4.1 / C0b) the three new flags plus the exit-3 contract documented.
#   2. --mode validation: the enum is enforced, and a VALID mode is let past
#      (so section 2 cannot pass by rejecting everything).
#   3. Exclusivity: both flag orders and the `--mode <n>` spelling, with and
#      without bd on PATH, plus the ordering proof.
#   3b. --verify (v4.1 / C0b): it runs the TARGET's doctor and propagates its
#      status, refuses to combine with --upgrade / --mode, exits 1 naming the
#      missing doctor on an un-installed dir, and NEVER reaches the prerequisite
#      block — which is what makes it usable on the node-less machine whose
#      missing runtime it is supposed to help diagnose.
#   4. META-TEST: a copy with the exclusivity block deleted stops exiting 1.
#   5. META-TEST (v4.1 / C0b): a copy with the --verify exclusivity blocks
#      deleted stops refusing `--verify --mode=2` and runs the doctor instead.
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

# A PATH with the system directories only. Beads installs to ~/.local/bin or
# /usr/local/bin (and jq to /usr/local/bin or /opt/homebrew/bin), so this is
# reliably prereq-hostile — but section 3 verifies that rather than assuming it.
MINIMAL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# NEUTRALISE THE REAL beads INSTALLER BEFORE ANY INVOCATION RUNS.
# install.sh's beads-upgrade step executes `sh -c "$BD_UPGRADE_COMMAND"`, whose
# default is `curl -fsSL .../beads/main/scripts/install.sh | bash` — the real
# upstream installer, which writes a bd binary over whatever is on PATH. This
# spec invokes install.sh 27 times and, until 2026-10-02, stubbed that command
# ZERO times, so any invocation reaching a complete install replaced the HOST's
# bd with whatever beads had most recently released.
#
# MEASURED, which is how this was found (claude-workflow-plugin-wyt3): running
# this spec in a container with bd 1.1.2 installed at /usr/local/bin left
# /usr/local/bin/bd at version 1.3.1, sha256 1db3b1b5… -> 21351856…. On CI that
# is exactly what breaks META-TEST 8a — the l1-unit job pins bd 1.1.2,
# sha256-verified, and the doctor later measures 1.3.1, because this spec
# overwrote the pinned binary mid-job. It also explains three unexplained
# upgrades of a developer's local bd across one work arc.
#
# The seam already exists for precisely this reason (see install.sh's
# BD_UPGRADE_COMMAND header: "a SEAM, not a hardcoded curl"), and the component
# tier's installer-beads-upgrade.sh already substitutes a fake. This spec is an
# ARGUMENT-CONTRACT spec; it has no business running a real installer at all,
# so the seam is closed here unconditionally rather than per-invocation.
export BD_UPGRADE_COMMAND='true'

WORK=$(mktemp -d -t installer-flags-test.XXXXXX)
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

# contains <haystack> <needle> -> yes/no. Fixed-string, so message fragments
# can be pasted verbatim without escaping.
contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then printf 'yes'; else printf 'no'; fi
}

# file_contains <file> <needle> -> yes/no. Same predicate, reading the file
# directly. Used wherever the haystack is a whole SCRIPT: `contains "$(cat f)"`
# pushes ~2,700 lines through a pipe that `grep -q` closes on the first match,
# and bash reports the resulting SIGPIPE as `printf: write error: Broken pipe`
# on stderr — noise in a test log that reads like a failure and is not one.
file_contains() {
    if grep -qF -- "$2" "$1" 2>/dev/null; then printf 'yes'; else printf 'no'; fi
}

# --- run helpers -------------------------------------------------------------
# Every invocation in this file goes through run_installer, so the section-4
# mutant can never differ from the subject by HOW it was run — only by what it
# contains. stdin is /dev/null throughout: the mode prompt and the git-init
# prompt both fall through to /dev/tty when one is openable, and a test that
# blocks on a developer's terminal is worse than no test.
#
# Output is captured combined (the refusal goes to stderr, the usage text to
# stdout) and the exit code lands in $RUN_RC.
RUN_OUT=""
RUN_RC=0
run_installer() {
    local script="$1"
    shift
    RUN_OUT=$(bash "$script" "$@" </dev/null 2>&1)
    RUN_RC=$?
    return 0
}

# Same, with PATH reduced to the system directories. `env` is what applies the
# new PATH to the command lookup for bash itself; passing the running bash by
# absolute path keeps the SUT on the same interpreter as the rest of the suite.
#
# EVERY invocation that is EXPECTED TO FALL THROUGH argument validation uses
# this form, and that is load-bearing rather than tidy: under the caller's real
# PATH an accepted invocation runs a COMPLETE INSTALL — 376 files, a real
# `bd init`, and a `git init` inside the fixture. An argument-contract spec has
# no business doing that, so the reduced PATH is what turns "the parser
# accepted this" into a two-second assertion that stops at the prereq block.
BASH_BIN="${BASH:-$(command -v bash)}"
run_installer_minimal_path() {
    local script="$1"
    shift
    RUN_OUT=$(env PATH="$MINIMAL_PATH" "$BASH_BIN" "$script" "$@" </dev/null 2>&1)
    RUN_RC=$?
    return 0
}

# Is the reduced PATH actually prereq-hostile? Beads installs to ~/.local/bin
# or /usr/local/bin, so normally yes — but a machine with bd in /usr/bin would
# let a fall-through run install for real, so the fall-through assertions are
# skipped there rather than silently doing something expensive.
#
# Probed through `env` + `sh -c` rather than a PATH assignment in a subshell:
# same answer, and it keeps the lookup in the same shape the runs below use.
if env PATH="$MINIMAL_PATH" sh -c 'command -v bd >/dev/null 2>&1'; then
    BD_HIDDEN=no
else
    BD_HIDDEN=yes
fi

# ---------------------------------------------------------------------------
echo "=== Section 0: the script under test ==="

assert_eq "install.sh exists at the repo root" \
    "yes" "$([ -f "$INSTALL_SH" ] && echo yes || echo no)"
if [ ! -f "$INSTALL_SH" ]; then
    printf '\nFAILED: %d (installer missing; remaining sections cannot run)\n' "$FAIL"
    exit 1
fi
assert_eq "install.sh parses under bash -n" "0" \
    "$(bash -n "$INSTALL_SH" 2>/dev/null && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: --help ==="

run_installer "$INSTALL_SH" --help
assert_eq "--help exits 0" "0" "$RUN_RC"
assert_eq "--help documents --upgrade" "yes" "$(contains "$RUN_OUT" "--upgrade")"
assert_eq "--help documents --mode" "yes" "$(contains "$RUN_OUT" "--mode")"
# The refusal is only defensible if the usage text says the two cannot be
# combined; an operator should not have to discover that by being refused.
assert_eq "--help states --mode cannot be combined with --upgrade" \
    "yes" "$(contains "$RUN_OUT" "Cannot be combined with --upgrade")"
assert_eq "--help states --upgrade cannot be combined with --mode" \
    "yes" "$(contains "$RUN_OUT" "Cannot be combined with --mode")"
assert_eq "--help lists all three mode values" "yes" \
    "$(contains "$RUN_OUT" "--mode=<1|2|3>")"
# -h is the same door.
run_installer "$INSTALL_SH" -h
assert_eq "-h exits 0 as well" "0" "$RUN_RC"
# The usage HEADER is version-dynamic (v4.1 / U0.8): it interpolates the version
# read from the source .claude-plugin/plugin.json, so the expected string is
# built from that same manifest rather than typed here. Through v4.0 this file
# asserted the literal "Claude Workflow Plugin v3 installer" — which is how a
# stale major survived two releases with a green suite.
PLUGIN_JSON="$PROJECT_DIR/.claude-plugin/plugin.json"
EXPECTED_VERSION=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$PLUGIN_JSON" 2>/dev/null | head -1)
assert_eq "the plugin manifest declares a readable version (guards the two checks below)" \
    "yes" "$([ -n "$EXPECTED_VERSION" ] && echo yes || echo no)"
assert_eq "-h prints the same usage block, naming the version from plugin.json" "yes" \
    "$(contains "$RUN_OUT" "Claude Workflow Plugin v$EXPECTED_VERSION installer")"
# And the retired hardcode is really gone — "no v3 anywhere in the header" is the
# regression, and it cannot be seen by a check that only looks for the right
# string. Skipped rather than inverted if the repo is ever legitimately on 3.x.
case "$EXPECTED_VERSION" in
    3.*) echo "  SKIPPED: the repo is on a 3.x version; the stale-v3 check is not meaningful" ;;
    *)   assert_eq "-h no longer carries the hardcoded v3 header" "no" \
             "$(contains "$RUN_OUT" "Claude Workflow Plugin v3 installer")" ;;
esac
# Printing usage must not be a side-effecting run.
assert_eq "--help never reaches the prerequisite checks" "no" \
    "$(contains "$RUN_OUT" "Checking prerequisites")"

# --- v4.1 / C0b: the three new flags and the exit-3 contract ----------------
# An operator whose install exits 3 has to be able to find out what 3 MEANS
# without reading the source. `--help` is the only surface that answers that,
# and an undocumented exit code is indistinguishable from a crash — which is
# precisely how a caller ends up treating "installed but not working" as
# "nothing happened" and retrying an install that does not need retrying.
run_installer "$INSTALL_SH" --help
assert_eq "--help documents --skip-mcp-deps" "yes" \
    "$(contains "$RUN_OUT" "--skip-mcp-deps")"
assert_eq "--help documents --skip-verify" "yes" \
    "$(contains "$RUN_OUT" "--skip-verify")"
assert_eq "--help documents --verify" "yes" \
    "$(contains "$RUN_OUT" "--verify")"
# The environment forms are the ONLY way to pass these under `curl | bash`,
# so an operator who cannot find them in --help cannot use them at all.
assert_eq "--help names the CWP_SKIP_MCP_DEPS environment form" "yes" \
    "$(contains "$RUN_OUT" "CWP_SKIP_MCP_DEPS")"
assert_eq "--help names the CWP_SKIP_VERIFY environment form" "yes" \
    "$(contains "$RUN_OUT" "CWP_SKIP_VERIFY")"
assert_eq "--help documents the exit codes at all" "yes" \
    "$(contains "$RUN_OUT" "Exit codes:")"
assert_eq "--help documents exit 3 as installed-but-unverified" "yes" \
    "$(contains "$RUN_OUT" "3  INSTALLED, VERIFICATION FAILED")"
# The 1/3 DISTINCTION is the contract, not just the existence of a 3: 1 has to
# keep meaning "nothing landed" or the split buys nothing.
assert_eq "--help distinguishes exit 1 as aborted" "yes" \
    "$(contains "$RUN_OUT" "1  ABORTED")"
# Anchored on the phrase unique to the --verify entry: a bare "Cannot be
# combined with" is already satisfied by the --upgrade and --mode entries, so it
# would pass on a usage text that never mentions --verify's exclusivity at all.
assert_eq "--help states --verify cannot be combined with --upgrade or --mode" "yes" \
    "$(contains "$RUN_OUT" "--upgrade or --mode")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: --mode value validation ==="

TARGET_A="$WORK/target-a"
mkdir -p "$TARGET_A"

run_installer "$INSTALL_SH" --mode=9 "$TARGET_A"
assert_eq "--mode=9 exits 1" "1" "$RUN_RC"
assert_eq "--mode=9 names the offending value" "yes" "$(contains "$RUN_OUT" "'9'")"
assert_eq "--mode=9 names the accepted values" "yes" \
    "$(contains "$RUN_OUT" "expected 1, 2, or 3")"
assert_eq "--mode=9 is rejected before the prerequisite checks" "no" \
    "$(contains "$RUN_OUT" "Checking prerequisites")"

run_installer "$INSTALL_SH" --mode=abc "$TARGET_A"
assert_eq "--mode=abc exits 1" "1" "$RUN_RC"

# Positive controls. Without these, section 2 would pass just as well against
# an installer that rejected every --mode value it was ever given. Both are
# expected to fall THROUGH validation, so both run on the reduced PATH.
if [ "$BD_HIDDEN" != "yes" ]; then
    echo "  SKIPPED: bd resolves under $MINIMAL_PATH; a fall-through run here would install for real"
else
    # An empty value is indistinguishable from "no override" by design (the
    # variable is tested with -n), so this must NOT be a hard error. Pinned so
    # the check is not "tightened" into rejecting a form the parser treats as
    # unset.
    run_installer_minimal_path "$INSTALL_SH" --mode= "$TARGET_A"
    assert_eq "--mode= (empty) is not a validation error; it falls through" "yes" \
        "$(contains "$RUN_OUT" "Checking prerequisites")"

    run_installer_minimal_path "$INSTALL_SH" --mode=2 "$TARGET_A"
    assert_eq "--mode=2 is accepted by the parser (no invalid-value message)" "no" \
        "$(contains "$RUN_OUT" "Invalid --mode value")"
    assert_eq "--mode=2 proceeds to the prerequisite checks" "yes" \
        "$(contains "$RUN_OUT" "Checking prerequisites")"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: --upgrade / --mode exclusivity ==="

EXCLUSIVITY_MSG="cannot be combined"

run_installer "$INSTALL_SH" --upgrade --mode=2 "$TARGET_A"
assert_eq "--upgrade --mode=2 exits 1" "1" "$RUN_RC"
assert_eq "--upgrade --mode=2 explains the refusal" "yes" \
    "$(contains "$RUN_OUT" "$EXCLUSIVITY_MSG")"
assert_eq "--upgrade --mode=2 names the mode the operator passed" "yes" \
    "$(contains "$RUN_OUT" "--mode=2 cannot be combined")"
assert_eq "--upgrade --mode=2 tells the operator what to do instead" "yes" \
    "$(contains "$RUN_OUT" "Pass exactly one of them")"

# Reverse order: the parser must not be order-sensitive.
run_installer "$INSTALL_SH" --mode=2 --upgrade "$TARGET_A"
assert_eq "--mode=2 --upgrade exits 1 (reverse order)" "1" "$RUN_RC"
assert_eq "--mode=2 --upgrade explains the refusal (reverse order)" "yes" \
    "$(contains "$RUN_OUT" "$EXCLUSIVITY_MSG")"

# The space-separated spelling goes through a different parser arm
# (`--mode` + $2) and must land in the same place.
run_installer "$INSTALL_SH" --upgrade --mode 3 "$TARGET_A"
assert_eq "--upgrade --mode 3 (space form) exits 1" "1" "$RUN_RC"
assert_eq "--upgrade --mode 3 (space form) explains the refusal" "yes" \
    "$(contains "$RUN_OUT" "$EXCLUSIVITY_MSG")"

# --- ordering: the refusal precedes the prerequisite checks -----------------
if [ "$BD_HIDDEN" != "yes" ]; then
    echo "  SKIPPED: bd resolves under $MINIMAL_PATH; cannot stage a bd-less run here"
else
    # Neither flag on its own is refused — otherwise the assertions above would
    # be satisfied by an installer that refused everything. Falls through, so
    # the reduced PATH again.
    run_installer_minimal_path "$INSTALL_SH" --upgrade "$TARGET_A"
    assert_eq "--upgrade alone is not refused" "no" \
        "$(contains "$RUN_OUT" "$EXCLUSIVITY_MSG")"


    # Control: the SAME reduced PATH, without conflicting flags, must fail in
    # the prerequisite block. This is what makes the assertion below mean
    # "validation ran first" instead of "something exited 1".
    run_installer_minimal_path "$INSTALL_SH" "$TARGET_A"
    assert_eq "control: with a prereq-hostile PATH a plain run exits 1" "1" "$RUN_RC"
    assert_eq "control: ...and it got there through the prerequisite checks" "yes" \
        "$(contains "$RUN_OUT" "Checking prerequisites")"
    assert_eq "control: ...reporting a missing REQUIRED tool" "yes" \
        "$(contains "$RUN_OUT" "REQUIRED")"

    run_installer_minimal_path "$INSTALL_SH" --upgrade --mode=2 "$TARGET_A"
    assert_eq "exclusivity still exits 1 with bd absent from PATH" "1" "$RUN_RC"
    assert_eq "exclusivity still explains the refusal with bd absent" "yes" \
        "$(contains "$RUN_OUT" "$EXCLUSIVITY_MSG")"
    # The proof: the same PATH that stopped the control at the prereq block
    # never got there at all this time.
    assert_eq "exclusivity is reported BEFORE the prerequisite checks" "no" \
        "$(contains "$RUN_OUT" "Checking prerequisites")"
    assert_eq "exclusivity does not blame the missing tool" "no" \
        "$(contains "$RUN_OUT" "Beads (bd) not found")"
fi

# The target must be untouched by any refused invocation: a run that exits on
# an argument error has no business creating .claude/.
assert_eq "no refused invocation created anything in the target" "0" \
    "$(find "$TARGET_A" -mindepth 1 2>/dev/null | grep -c . | tr -d ' \n')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3b: --verify (v4.1 / C0b) ==="

# A target that carries a STUB workflow-doctor.sh. The stub records the argv it
# was handed and exits with a code the test chooses, which is what makes
# "install.sh execs the TARGET's doctor and returns its status" measurable
# without running an install or a real 13-check doctor.
VERIFY_TARGET="$WORK/verify-target"
mkdir -p "$VERIFY_TARGET/.claude/scripts"
STUB_ARGV="$WORK/stub-argv.txt"
write_stub_doctor() {
    local rc="$1"
    cat > "$VERIFY_TARGET/.claude/scripts/workflow-doctor.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" > "$STUB_ARGV"
printf 'stub-doctor ran\n'
exit $rc
STUB
    chmod +x "$VERIFY_TARGET/.claude/scripts/workflow-doctor.sh"
}

write_stub_doctor 0
run_installer "$INSTALL_SH" --verify "$VERIFY_TARGET"
assert_eq "--verify exits 0 when the target's doctor exits 0" "0" "$RUN_RC"
assert_eq "--verify actually ran the TARGET's doctor" "yes" \
    "$(contains "$RUN_OUT" "stub-doctor ran")"
assert_eq "--verify passed --target to the doctor" "yes" \
    "$(contains "$(cat "$STUB_ARGV" 2>/dev/null)" "--target $VERIFY_TARGET")"
# The status has to be the DOCTOR's, not a normalised 0/1. A caller that wants
# to tell "a check failed" (1) from "you typo'd a --skip name" (2) can only do
# that if install.sh stops flattening it.
write_stub_doctor 7
run_installer "$INSTALL_SH" --verify "$VERIFY_TARGET"
assert_eq "--verify propagates the doctor's exit status verbatim (7)" "7" "$RUN_RC"
write_stub_doctor 2
run_installer "$INSTALL_SH" --verify "$VERIFY_TARGET"
assert_eq "--verify propagates a doctor usage error (2) rather than flattening it" "2" "$RUN_RC"
write_stub_doctor 0

# An un-installed directory: exit 1, and SAY WHICH FILE is missing. "verify
# failed" without the path sends an operator looking for a broken install where
# there is no install at all.
VERIFY_EMPTY="$WORK/verify-empty"
mkdir -p "$VERIFY_EMPTY"
run_installer "$INSTALL_SH" --verify "$VERIFY_EMPTY"
assert_eq "--verify on an un-installed dir exits 1" "1" "$RUN_RC"
assert_eq "--verify names the missing doctor by path" "yes" \
    "$(contains "$RUN_OUT" "$VERIFY_EMPTY/.claude/scripts/workflow-doctor.sh")"
assert_eq "--verify says the plugin is not installed there" "yes" \
    "$(contains "$RUN_OUT" "does not appear to be installed")"
assert_eq "--verify installed nothing into the un-installed dir" "0" \
    "$(find "$VERIFY_EMPTY" -mindepth 1 2>/dev/null | grep -c . | tr -d ' \n')"

# Exclusivity, both partners, both spellings of --mode.
run_installer "$INSTALL_SH" --verify --mode=2 "$VERIFY_TARGET"
assert_eq "--verify --mode=2 exits 1" "1" "$RUN_RC"
assert_eq "--verify --mode=2 explains the refusal" "yes" \
    "$(contains "$RUN_OUT" "$EXCLUSIVITY_MSG")"
assert_eq "--verify --mode=2 names the mode the operator passed" "yes" \
    "$(contains "$RUN_OUT" "--verify and --mode=2 cannot be combined")"
# The refusal must PREEMPT the doctor: a run that refused and still ran the
# doctor would have done half of what it declined to do.
assert_eq "--verify --mode=2 did not run the doctor anyway" "no" \
    "$(contains "$RUN_OUT" "stub-doctor ran")"

run_installer "$INSTALL_SH" --mode=2 --verify "$VERIFY_TARGET"
assert_eq "--mode=2 --verify exits 1 (reverse order)" "1" "$RUN_RC"
run_installer "$INSTALL_SH" --verify --mode 3 "$VERIFY_TARGET"
assert_eq "--verify --mode 3 (space form) exits 1" "1" "$RUN_RC"

run_installer "$INSTALL_SH" --verify --upgrade "$VERIFY_TARGET"
assert_eq "--verify --upgrade exits 1" "1" "$RUN_RC"
assert_eq "--verify --upgrade explains the refusal" "yes" \
    "$(contains "$RUN_OUT" "$EXCLUSIVITY_MSG")"
run_installer "$INSTALL_SH" --upgrade --verify "$VERIFY_TARGET"
assert_eq "--upgrade --verify exits 1 (reverse order)" "1" "$RUN_RC"

# --- ordering: --verify must PRECEDE the prerequisite block ------------------
# THE POINT OF THE FLAG. `--verify` is what an operator reaches for when the
# install is broken, and "node is missing" is one of the things it is supposed
# to tell them — through the doctor's own `deps` check, alongside every other
# check in the registry. If the prerequisite block ran first, a node-less
# machine would get "node and npm are REQUIRED" and learn nothing about the
# rest of the install's health.
if [ "$BD_HIDDEN" != "yes" ]; then
    echo "  SKIPPED: bd resolves under $MINIMAL_PATH; cannot stage a prereq-hostile run here"
else
    run_installer_minimal_path "$INSTALL_SH" --verify "$VERIFY_TARGET"
    assert_eq "--verify still runs the doctor on a prereq-hostile PATH" "yes" \
        "$(contains "$RUN_OUT" "stub-doctor ran")"
    assert_eq "--verify never reaches the prerequisite checks" "no" \
        "$(contains "$RUN_OUT" "Checking prerequisites")"
    assert_eq "--verify does not blame a missing tool" "no" \
        "$(contains "$RUN_OUT" "REQUIRED")"
    assert_eq "--verify still exits with the doctor's status on that PATH" "0" "$RUN_RC"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: META-TEST (the exclusivity check can actually fail) ==="

# Delete the exclusivity block from a COPY, anchored on the block's own `if`
# line and its closing column-0 `fi`. Anchoring on real code rather than a
# comment is deliberate: if the condition is ever reworded the sed matches
# nothing, the "copy differs" assertion below fails, and the META is repaired
# rather than silently rotting into a no-op.
MUTANT="$WORK/install-no-exclusivity.sh"
# shellcheck disable=SC2016  # sed script: the $VAR text is the installer's own source, not an expansion
sed '/^if \[ "\$FORCE_UPGRADE" = true \] && \[ -n "\$INSTALL_MODE_OVERRIDE" \]; then$/,/^fi$/d' \
    "$INSTALL_SH" > "$MUTANT"
assert_eq "META: the mutated copy really differs from install.sh" "1" \
    "$(cmp -s "$MUTANT" "$INSTALL_SH" && echo 0 || echo 1)"
assert_eq "META: the mutated copy is shorter (the block was removed)" "1" \
    "$([ "$(wc -l < "$MUTANT")" -lt "$(wc -l < "$INSTALL_SH")" ] && echo 1 || echo 0)"
assert_eq "META: the mutated copy is still syntactically valid bash" "0" \
    "$(bash -n "$MUTANT" 2>/dev/null && echo 0 || echo 1)"
# Anchored on the sentence THIS block owns, not on the shared "cannot be
# combined" phrase. v4.1 / C0b added two more exclusivity blocks (--verify with
# --upgrade, --verify with --mode) that use the same wording on purpose, so the
# shared phrase stopped discriminating: it survives this mutation because the
# OTHER blocks still carry it, and the assertion would fail while the mutation
# it measures had landed perfectly.
assert_eq "META: the mutated copy no longer carries the --upgrade/--mode refusal" "no" \
    "$(file_contains "$MUTANT" "--upgrade and --mode=")"
# ...and the --verify refusals it was NOT asked to touch are still there, so the
# sed is proven surgical rather than merely destructive.
assert_eq "META: the mutated copy still carries the untouched --verify refusals" "yes" \
    "$(file_contains "$MUTANT" "--verify and --mode=")"

# The mutant has to run to completion to show the exit code FLIP, and a
# completed run needs a plugin source: install.sh treats its own directory as
# the source when that directory looks like a checkout, and otherwise CLONES
# FROM THE NETWORK — which a unit test must never do. So the mutant is dropped
# into a minimal synthetic source carrying exactly the files install.sh
# requires, plus the real manifest generator so the install-manifest write is
# the real one. Nothing here touches the repo tree.
SYNTH="$WORK/synthetic-source"
mkdir -p "$SYNTH/.claude/agents" "$SYNTH/.claude/scripts" "$SYNTH/.claude/hooks" \
    "$SYNTH/.claude/commands" "$SYNTH/.claude/skills/workflow-engine" \
    "$SYNTH/.claude/vendor/superpowers/brainstorming" \
    "$SYNTH/.claude/mcp/bd-mcp" "$SYNTH/.claude/mcp/code-graph-mcp" \
    "$SYNTH/.claude-plugin" "$SYNTH/docs" "$SYNTH/bin"
# The synthetic agent set is READ OUT OF install.sh's own required-source
# list, not spelled out (v5.0.0 / D0).
#
# It WAS five names, and it broke the moment D0 added designer.md and
# design-reviewer.md to that list: install.sh aborted with "Plugin source
# missing" at the source check, BEFORE the flag-exclusivity flip this section
# measures, so three METAs failed for a reason that was not their own. That is
# the same failure this file already documents three times below for the
# helper list, the vendored tree and the shipped-docs subset — a synthetic
# source hand-maintained against a list that keeps growing.
#
# Deriving it closes the class instead of paying it a fourth time: whatever
# install.sh requires, the synthetic source now has.
SYNTH_AGENT_COUNT=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    SYNTH_AGENT_COUNT=$((SYNTH_AGENT_COUNT + 1))
    printf -- '---\nmodel: test\n---\nsynthetic %s agent\n' "$(basename "$rel" .md)" \
        > "$SYNTH/.claude/agents/$(basename "$rel")"
done <<EOF
$(sed -n 's/^[[:space:]]*"\(\.claude\/agents\/[^"]*\.md\)"[[:space:]]*\\$/\1/p' "$PROJECT_DIR/install.sh")
EOF
# Non-vacuity: if the extraction pattern ever stops matching install.sh's
# formatting it yields ZERO agents, the synthetic source is unusable, and every
# META below fails opaquely at the source check. Fail here instead, where the
# message says what actually went wrong.
assert_eq "synthetic source: agent list extracted from install.sh's required list (>= 5)" \
    "yes" "$([ "$SYNTH_AGENT_COUNT" -ge 5 ] && echo yes || echo "no($SYNTH_AGENT_COUNT)")"
# Every helper on install.sh's required-source list. workflow-doctor joined it
# in v4.1 / C0a; a missing entry aborts the mutant run with "Plugin source
# missing" before the exit-code flip this section measures can happen.
for helper in session-start intent-router post-edit verify-before-stop session-end \
    qa-gate review-check impact-report current-task prevent-orchestrator-edits \
    workflow-doctor; do
    printf '#!/bin/bash\nexit 0\n' > "$SYNTH/.claude/scripts/$helper.sh"
done
# Both MCP lockfiles joined the required-source list in the same change (the
# target's dependency install is `npm ci`, which refuses without one).
for mcp_server in bd-mcp code-graph-mcp; do
    printf '{"lockfileVersion":3,"packages":{}}\n' \
        > "$SYNTH/.claude/mcp/$mcp_server/package-lock.json"
done
cp "$PROJECT_DIR/.claude/scripts/workflow-manifest.sh" "$SYNTH/.claude/scripts/" 2>/dev/null || \
    printf '#!/bin/bash\nexit 1\n' > "$SYNTH/.claude/scripts/workflow-manifest.sh"
printf '{"hooks":{}}\n'            > "$SYNTH/.claude/hooks/hooks.json"
printf 'synthetic skill\n'         > "$SYNTH/.claude/skills/workflow-engine/SKILL.md"
# The vendored reference tree (v4.1 / U4) joined the required-source list. Same
# rule as every row above it: a missing entry aborts the mutant run with
# "Plugin source missing" at the source check, BEFORE the flag-exclusivity flip
# this section measures — so the META would fail for a reason that is not its
# own. (LESSONS.md: when a change adds a gate to a release path, every META
# isolating an earlier gate has to be re-seeded to satisfy the new one.)
printf 'synthetic vendor manifest\n' > "$SYNTH/.claude/vendor/superpowers/MANIFEST.md"
printf 'synthetic upstream licence\n' > "$SYNTH/.claude/vendor/superpowers/LICENSE.upstream"
printf 'synthetic vendored skill\n' > "$SYNTH/.claude/vendor/superpowers/brainstorming/SKILL.md"
printf 'synthetic command\n'       > "$SYNTH/.claude/commands/workflow-model.md"
printf '{"env":{}}\n'              > "$SYNTH/.claude/settings.json"
printf '{"name":"synthetic","version":"9.9.9-test"}\n' > "$SYNTH/.claude-plugin/plugin.json"
# The shipped-docs subset (v4.1 / U0.8) joined the required-source list, so a
# synthetic source without it aborts before the mutant can demonstrate the flip.
printf 'synthetic codex setup\n' > "$SYNTH/docs/CODEX_SETUP.md"
printf 'synthetic hooks reference\n' > "$SYNTH/docs/HOOKS.md"

# fake-bd: the whole `bd` surface install.sh touches (--version, init, hooks,
# doctor). `doctor` must never print the string 'error' — install.sh greps for
# it case-insensitively.
# The fixture must report a version AT OR ABOVE the floor, and that version is
# DERIVED from the doctor's validated set rather than hardcoded, so bumping the
# set cannot leave this fixture pinned to a version the release no longer
# validates. The set's HIGHEST member is taken — any validated member clears the
# floor, and tracking the ceiling keeps the fixture representative of what a
# current install actually has.
#
# This line said `bd 0.99.0` until 2026-10-02, which sorts BELOW the 1.1.2 floor
# and so drove install.sh into its beads-upgrade arm on every invocation — the
# arm that ran an unpinned `curl | bash` and replaced the HOST's bd
# (claude-workflow-plugin-wyt3). An argument-contract spec has no business
# manufacturing a below-floor install.
FIXTURE_BD_VER=$(sed -n 's/^DOCTOR_BD_SCHEMA_VALIDATED="\(.*\)"$/\1/p' \
    "$PROJECT_DIR/.claude/scripts/workflow-doctor.sh" 2>/dev/null \
    | head -1 | tr ' ' '\n' | cut -d: -f1 | grep -E '^[0-9]' | sort -V | tail -1)
assert_eq "8.0 the fixture's bd version is derivable from the validated set (else the fixture is vacuous)" \
    "yes" "$([ -n "$FIXTURE_BD_VER" ] && echo yes || echo no)"
: "${FIXTURE_BD_VER:=1.3.0}"

cat > "$SYNTH/bin/bd" <<FAKE_BD
#!/bin/bash
case "\${1:-}" in
    --version|-v|version) printf 'bd $FIXTURE_BD_VER (fake-bd for installer-flags)\n' ;;
    doctor)               printf 'fake-bd: all checks passed\n' ;;
    *)                    printf 'fake-bd: ok (%s)\n' "\${1:-}" ;;
esac
exit 0
FAKE_BD
chmod +x "$SYNTH/bin/bd"
assert_eq "8.0b ...and the generated fixture really reports it" "yes" \
    "$("$SYNTH/bin/bd" --version 2>/dev/null | grep -qF "bd $FIXTURE_BD_VER" && echo yes || echo no)"

MUTANT_TARGET="$WORK/mutant-target"
mkdir -p "$MUTANT_TARGET"
(
    cd "$MUTANT_TARGET" || exit 1
    git init -q >/dev/null 2>&1 || true
    git -c user.email=test@example.com -c user.name=test \
        commit --allow-empty -q -m "baseline" >/dev/null 2>&1 || true
)

if ! command -v git >/dev/null 2>&1; then
    echo "  SKIPPED: git unavailable; cannot run the mutant to completion"
else
    cp "$MUTANT" "$SYNTH/install.sh"
    MUTANT_OUT=$(env PATH="$SYNTH/bin:$PATH" "$BASH_BIN" "$SYNTH/install.sh" \
        --upgrade --mode=2 "$MUTANT_TARGET" </dev/null 2>&1)
    MUTANT_RC=$?
    if [ "$MUTANT_RC" -ne 0 ]; then
        printf '  diagnostic: mutant exited %s; tail of output:\n' "$MUTANT_RC"
        printf '%s\n' "$MUTANT_OUT" | tail -8 | sed 's/^/    /'
    fi
    # THE FLIP: install.sh exits 1 on these exact arguments (section 3);
    # without the exclusivity block the same arguments are accepted and the
    # install proceeds. An exit code of 1 here would mean section 3's
    # assertion was passing for some reason other than the check.
    assert_eq "META: without the exclusivity block, --upgrade --mode=2 no longer exits 1" \
        "no" "$([ "$MUTANT_RC" -eq 1 ] && echo yes || echo no)"
    assert_eq "META: the mutant accepts the conflicting flags and completes" \
        "0" "$MUTANT_RC"
    assert_eq "META: the mutant prints no refusal" "no" \
        "$(contains "$MUTANT_OUT" "$EXCLUSIVITY_MSG")"
    # It really installed — so the flip is "ran to completion", not "died
    # somewhere else quietly".
    assert_eq "META: the mutant went on to install into the target" "yes" \
        "$([ -f "$MUTANT_TARGET/.claude-plugin/plugin.json" ] && echo yes || echo no)"

    # And the control: the REAL installer, same arguments, same synthetic
    # source, same fake bd — still refuses.
    cp "$INSTALL_SH" "$SYNTH/install.sh"
    CONTROL_TARGET="$WORK/control-target"
    mkdir -p "$CONTROL_TARGET"
    CONTROL_OUT=$(env PATH="$SYNTH/bin:$PATH" "$BASH_BIN" "$SYNTH/install.sh" \
        --upgrade --mode=2 "$CONTROL_TARGET" </dev/null 2>&1)
    CONTROL_RC=$?
    assert_eq "META control: the unmutated installer still exits 1 on the same run" \
        "1" "$CONTROL_RC"
    assert_eq "META control: ...refusing for the documented reason" "yes" \
        "$(contains "$CONTROL_OUT" "$EXCLUSIVITY_MSG")"
    assert_eq "META control: ...and installs nothing" "0" \
        "$(find "$CONTROL_TARGET" -mindepth 1 2>/dev/null | grep -c . | tr -d ' \n')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: META-TEST (the --verify exclusivity check can actually fail) ==="

# Same construction as section 4, aimed at the two blocks C0b added. Anchored on
# the blocks' own `if` lines and their column-0 `fi`, never on a line number: if
# either condition is reworded the sed matches nothing, the "copy differs"
# assertion below fails, and the META is repaired rather than silently rotting
# into a no-op.
#
# WHY THE FLIP IS MEASURED ON A DOCTOR-BEARING TARGET. Without the exclusivity
# blocks, `--verify --mode=2` falls through to the --verify handler — which on
# an EMPTY dir also exits 1 ("no workflow-doctor.sh"), so an exit-code-only
# assertion would pass for the wrong reason and this META would prove nothing.
# Pointed at a target carrying the stub doctor, the mutant exits 0 (the stub's
# status) while the real installer exits 1 with the refusal: a flip in BOTH the
# code and the message.
VERIFY_MUTANT="$WORK/install-no-verify-exclusivity.sh"
# shellcheck disable=SC2016  # sed script: the $VAR text is the installer's own source, not an expansion
sed -e '/^if \[ "\$VERIFY_ONLY" = true \] && \[ "\$FORCE_UPGRADE" = true \]; then$/,/^fi$/d' \
    -e '/^if \[ "\$VERIFY_ONLY" = true \] && \[ -n "\$INSTALL_MODE_OVERRIDE" \]; then$/,/^fi$/d' \
    "$INSTALL_SH" > "$VERIFY_MUTANT"
assert_eq "META-TEST: the --verify-mutated copy really differs from install.sh" "1" \
    "$(cmp -s "$VERIFY_MUTANT" "$INSTALL_SH" && echo 0 || echo 1)"
assert_eq "META-TEST: the --verify-mutated copy is shorter (both blocks were removed)" "1" \
    "$([ "$(wc -l < "$VERIFY_MUTANT")" -lt "$(wc -l < "$INSTALL_SH")" ] && echo 1 || echo 0)"
assert_eq "META-TEST: the --verify-mutated copy is still syntactically valid bash" "0" \
    "$(bash -n "$VERIFY_MUTANT" 2>/dev/null && echo 0 || echo 1)"
# Both refusal sentences are gone, and they are checked separately: a sed that
# deleted only one block would otherwise look like a full mutation.
assert_eq "META-TEST: the mutant no longer carries the --verify/--mode refusal" "no" \
    "$(file_contains "$VERIFY_MUTANT" "--verify and --mode=")"
assert_eq "META-TEST: the mutant no longer carries the --verify/--upgrade refusal" "no" \
    "$(file_contains "$VERIFY_MUTANT" "--verify and --upgrade cannot be combined")"
# ...and the --upgrade/--mode refusal it was NOT asked to touch is still there,
# so the sed is proven surgical rather than merely destructive.
assert_eq "META-TEST: the mutant still carries the untouched --upgrade/--mode refusal" "yes" \
    "$(file_contains "$VERIFY_MUTANT" "--upgrade and --mode=")"

write_stub_doctor 0
RUN_OUT=$(bash "$VERIFY_MUTANT" --verify --mode=2 "$VERIFY_TARGET" </dev/null 2>&1)
VERIFY_MUTANT_RC=$?
assert_eq "META-TEST: without the blocks, --verify --mode=2 no longer exits 1" "no" \
    "$([ "$VERIFY_MUTANT_RC" -eq 1 ] && echo yes || echo no)"
assert_eq "META-TEST: the mutant accepts the conflicting flags and runs the doctor" "yes" \
    "$(contains "$RUN_OUT" "stub-doctor ran")"
assert_eq "META-TEST: the mutant prints no refusal" "no" \
    "$(contains "$RUN_OUT" "$EXCLUSIVITY_MSG")"
assert_eq "META-TEST: the mutant exits with the doctor's status instead" "0" "$VERIFY_MUTANT_RC"

# Control: the REAL installer, same arguments, same target — still refuses, and
# still does NOT run the doctor.
run_installer "$INSTALL_SH" --verify --mode=2 "$VERIFY_TARGET"
assert_eq "META-TEST control: the unmutated installer still exits 1 on the same run" "1" "$RUN_RC"
assert_eq "META-TEST control: ...refusing for the documented reason" "yes" \
    "$(contains "$RUN_OUT" "$EXCLUSIVITY_MSG")"
assert_eq "META-TEST control: ...and never reaches the doctor" "no" \
    "$(contains "$RUN_OUT" "stub-doctor ran")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9: a bd below the floor is REFUSED, not warned (wyt3) ==="

# v5 requires bd >= RECOMMENDED_BD_VERSION. Continuing on an older bd would
# write v5 over a working v4.1 install into a storage configuration v5 does not
# support, and only the POST-install doctor would notice — warning where the
# installer must refuse (claude-workflow-plugin-q5l6). The refusal has to land
# BEFORE anything is written, or "nothing has been changed" is a false claim.
OLD_BD_DIR="$WORK/old-bd-bin"
mkdir -p "$OLD_BD_DIR"
cat > "$OLD_BD_DIR/bd" <<'OLD_BD'
#!/bin/bash
case "${1:-}" in
    --version|-v|version) printf 'bd 0.47.1 (fake old bd)\n' ;;
    doctor)               printf 'fake-bd: all checks passed\n' ;;
    *)                    printf 'fake-bd: ok (%s)\n' "${1:-}" ;;
esac
exit 0
OLD_BD
chmod +x "$OLD_BD_DIR/bd"

FLOOR_TARGET="$WORK/floor-target"
mkdir -p "$FLOOR_TARGET"
FLOOR_OUT=$(env PATH="$OLD_BD_DIR:$PATH" "$BASH_BIN" "$INSTALL_SH" "$FLOOR_TARGET" </dev/null 2>&1)
FLOOR_RC=$?

assert_eq "9.1 a bd below the floor makes the installer EXIT NON-ZERO" "yes" \
    "$([ "$FLOOR_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "9.2 ...and says it is REFUSING, not warning" "yes" \
    "$(contains "$FLOOR_OUT" "REFUSING to install")"
assert_eq "9.3 ...and NOTHING was written into the target (no .claude/)" "no" \
    "$([ -d "$FLOOR_TARGET/.claude" ] && echo yes || echo no)"
assert_eq "9.4 ...and it names the one-way storage migration" "yes" \
    "$(contains "$FLOOR_OUT" "ONE WAY")"
assert_eq "9.5 ...and tells the operator to back up .beads FIRST" "yes" \
    "$(contains "$FLOOR_OUT" "Back up your issues FIRST")"
# PINNED, not latest: printing an install-latest command recreates by hand the
# moving target the automatic path was removed for.
BRIDGE_VER=$(sed -n 's/^BRIDGE_BD_VERSION="\(.*\)"$/\1/p' "$INSTALL_SH" | head -1)
assert_eq "9.6a the bridge version is readable from install.sh (else 9.6b is vacuous)" "yes" \
    "$([ -n "$BRIDGE_VER" ] && echo yes || echo no)"
assert_eq "9.6b ...and the refusal points at that EXACT pinned release, not install-latest" "yes" \
    "$(contains "$FLOOR_OUT" "releases/tag/v$BRIDGE_VER")"

# THE BRIDGE IS PINNED, AND THIS IS WHAT STOPS THE PIN GOING STALE SILENTLY.
# "Can migrate a 0.47.x store" was MEASURED on specific versions; it is not
# implied by membership of the validated set, nor by being its lowest member.
# If the set ever stops containing the bridge, the printed instruction is
# telling operators to install a version this release no longer validates, and
# a newer bd REFUSES a 0.47.x workspace outright. Failing here forces a
# re-measurement instead of a silent change (claude-workflow-plugin-wyt3).
VALIDATED_SET=$(sed -n 's/^DOCTOR_BD_SCHEMA_VALIDATED="\(.*\)"$/\1/p' \
    "$PROJECT_DIR/.claude/scripts/workflow-doctor.sh" 2>/dev/null | head -1)
assert_eq "9.6c the validated set is readable (else 9.6d is vacuous)" "yes" \
    "$([ -n "$VALIDATED_SET" ] && echo yes || echo no)"
assert_eq "9.6d ...and the PINNED bridge version is still a member of it" "yes" \
    "$(printf '%s' "$VALIDATED_SET" | tr ' ' '\n' | cut -d: -f1 | grep -qxF "$BRIDGE_VER" && echo yes || echo no)"

# DRY RUN BEFORE APPLY, IN THAT ORDER. "nothing was discarded" was the result on
# a 3-issue fixture, not a guarantee for anyone's ledger; --apply was made
# explicit precisely so a write's effect is visible first.
assert_eq "9.8a the procedure names the dry-run reconcile" "yes" \
    "$(contains "$FLOOR_OUT" "beads-ledger.sh reconcile")"
assert_eq "9.8b ...and the --apply form too" "yes" \
    "$(contains "$FLOOR_OUT" "beads-ledger.sh reconcile --apply")"
# ORDER, not mere presence: the bare form must appear BEFORE the --apply form.
FLOOR_DRY_LINE=$(printf '%s\n' "$FLOOR_OUT" | grep -n 'beads-ledger\.sh reconcile$' | head -1 | cut -d: -f1)
FLOOR_APPLY_LINE=$(printf '%s\n' "$FLOOR_OUT" | grep -n 'beads-ledger\.sh reconcile --apply' | head -1 | cut -d: -f1)
assert_eq "9.8c NON-VACUITY: both reconcile lines were actually located" "yes" \
    "$([ -n "$FLOOR_DRY_LINE" ] && [ -n "$FLOOR_APPLY_LINE" ] && echo yes || echo no)"
assert_eq "9.8d ...and the DRY RUN is printed BEFORE the --apply" "yes" \
    "$([ -n "$FLOOR_DRY_LINE" ] && [ -n "$FLOOR_APPLY_LINE" ] && [ "$FLOOR_DRY_LINE" -lt "$FLOOR_APPLY_LINE" ] && echo yes || echo no)"
# The installer's own exit code is part of the procedure, so it must be stated.
assert_eq "9.9 the procedure warns that the installer EXITS 3 at that point" "yes" \
    "$(contains "$FLOOR_OUT" "EXITS 3")"

# ---------------------------------------------------------------------------
# THREE SURFACES, ONE SEQUENCE — CHECKED, NOT ASSERTED IN A COMMENT.
#
# A teammate hits this ledger repair from any of three directions: install.sh
# prints it as step 4 of the cross-era upgrade, install.ps1 prints its own copy
# of that procedure, and workflow-doctor.sh prints it as the beads_ledger FAIL
# fix. If any two ever name different commands, or the same commands in a
# different order, one of them is teaching a dry-run-first discipline another
# quietly skips. install.ps1 did exactly that until claude-workflow-plugin-i4ac:
# its step 4 went straight to --apply. 9.10d-e check it; 9.15 checks the rest of
# its procedure line for line.
#
# This replaces a comment that said the two "must not diverge". A note telling
# future editors to keep two copies in step is exactly the mechanism behind this
# release's tally drift, its duplicated rubric pin, and its four copies of the
# doctor's side-effect inventory — in every case the note survived and the
# agreement did not. One assertion outlives the note.
# Scoped to RUNNABLE COMMAND LINES — two-space-indented `bash ...` — not to
# every mention of the string. The first version of this grepped the whole file
# and picked up a PROSE reference ("written only by an explicit
# `beads-ledger.sh reconcile --apply`") that sits above the fix blocks, so it
# reported a divergence that did not exist. The assertion caught that itself,
# which is the point: a comment saying the two must agree could not have.
DOCTOR_SH="$PROJECT_DIR/.claude/scripts/workflow-doctor.sh"
DOC_SEQ=$(grep -oE '^  bash \.claude/scripts/beads-ledger\.sh reconcile( --apply)?$' "$DOCTOR_SH" 2>/dev/null \
    | sed 's/^  bash \.claude\/scripts\///' | awk '!seen[$0]++')
INST_SEQ=$(printf '%s\n' "$FLOOR_OUT" | grep -oE 'beads-ledger\.sh reconcile( --apply)?' | awk '!seen[$0]++')
assert_eq "9.10a NON-VACUITY: both surfaces actually name the reconcile command" "yes" \
    "$([ -n "$DOC_SEQ" ] && [ -n "$INST_SEQ" ] && echo yes || echo no)"
assert_eq "9.10b the doctor's fix lines and the installer's steps name the SAME commands in the SAME order" \
    "$INST_SEQ" "$DOC_SEQ"
# And that shared order is dry-run first, in BOTH — checked on the doctor side
# here, since 9.8d already pins the installer side.
assert_eq "9.10c ...and the doctor leads with the DRY RUN, not --apply" \
    "beads-ledger.sh reconcile" "$(printf '%s\n' "$DOC_SEQ" | head -1)"

# The third surface. install.ps1's text is READ from the file, not run: this
# suite never executes install.ps1 (9.15 says why). ps1_procedure renders its
# printed steps 1-4 from source: each line is one `Write-Host "..."`, with
# PowerShell's backtick escapes undone, the pinned bridge substituted, and the
# installer's own re-run and check commands left as <RERUN> / <VERIFY>.
PS1_FILE="$PROJECT_DIR/install.ps1"
# Every `$` in the sed scripts below is PowerShell source being MATCHED, not a
# shell expansion, so the single quotes are the point.
# shellcheck disable=SC2016
ps1_procedure() { # <path to an install.ps1>
    local bridge
    bridge=$(sed -n 's/^\$BridgeBdVersion = "\(.*\)"$/\1/p' "$1" | head -1)
    awk '/^function Invoke-RefuseBelowFloor/{f=1} f && /Write-Host "    1\. Back up/{p=1} p{print} p && /Get-InstallerRerunCommand -Check/{exit}' "$1" \
        | sed -e 's/^[[:space:]]*Write-Host "//' -e 's/"$//' \
              -e 's/`"/"/g' -e 's/`\$/$/g' \
              -e "s/\\\$BridgeBdVersion/$bridge/g" \
              -e 's/\$(Get-InstallerRerunCommand -Check)/<VERIFY>/' \
              -e 's/\$(Get-InstallerRerunCommand)/<RERUN>/'
}
PS1_PROC=$(ps1_procedure "$PS1_FILE")
PS1_SEQ=$(printf '%s\n' "$PS1_PROC" | grep -oE 'beads-ledger\.sh reconcile( --apply)?' | awk '!seen[$0]++')
assert_eq "9.10d NON-VACUITY: install.ps1's procedure was rendered and names the reconcile command" "yes" \
    "$([ -n "$PS1_SEQ" ] && echo yes || echo no)"
assert_eq "9.10e install.ps1 names the SAME commands in the SAME order: the dry run, then --apply (i4ac)" \
    "$DOC_SEQ" "$PS1_SEQ"
assert_eq "9.7 ...and does NOT print an install-latest pipe-to-shell command" "no" \
    "$(contains "$FLOOR_OUT" "scripts/install.sh | bash")"

# NEGATIVE CONTROL: the refusal must be caused by the OLD bd, not by this
# fixture shape. Same invocation, same target, a bd AT the floor instead.
NEW_BD_DIR="$WORK/new-bd-bin"
mkdir -p "$NEW_BD_DIR"
sed 's/bd 0\.47\.1 (fake old bd)/bd 1.3.0 (fake current bd)/' "$OLD_BD_DIR/bd" > "$NEW_BD_DIR/bd"
chmod +x "$NEW_BD_DIR/bd"
assert_eq "9.C0 NON-VACUITY: the control fixture really reports a different version" "yes" \
    "$("$NEW_BD_DIR/bd" --version | grep -q '1\.3\.0' && echo yes || echo no)"
CTRL_TARGET="$WORK/floor-control-target"
mkdir -p "$CTRL_TARGET"
CTRL_OUT=$(env PATH="$NEW_BD_DIR:$PATH" "$BASH_BIN" "$INSTALL_SH" "$CTRL_TARGET" </dev/null 2>&1)
assert_eq "9.C1 CONTROL: a bd at the floor is NOT refused" "no" \
    "$(contains "$CTRL_OUT" "REFUSING to install")"

# NO PATH ADMITS A BD BELOW THE FLOOR (claude-workflow-plugin-ishe R5-F1).
# --skip-beads-upgrade / CWP_SKIP_BEADS_UPGRADE=1 used to return before the
# version was compared, which installed v5 over a fake 0.47.1 (6965 files,
# exit 3, measured by the review). Every failed opt-in step returned and
# continued on the old bd as well. Each leg below runs the SHIPPED installer
# end to end and must be refused, with nothing written. 9.14 is the runner's
# own stub (BD_UPGRADE_COMMAND=true) plus the opt-in: a no-op "upgrade" that
# used to report "still 0.47.1" and then carry on installing.
refused_cleanly() { # <label-prefix> <out> <rc> <target>
    local claude_state
    if [ ! -d "$4" ]; then
        claude_state="TARGET-MISSING"   # no target means "no .claude/" proves nothing
    elif [ -e "$4/.claude" ]; then
        claude_state="yes"
    else
        claude_state="no"
    fi
    assert_eq "$1 ...exits non-zero" "yes" "$([ "$3" -ne 0 ] && echo yes || echo no)"
    assert_eq "$1 ...says it is REFUSING" "yes" "$(contains "$2" "REFUSING to install")"
    assert_eq "$1 ...and wrote no .claude/ into the target" "no" "$claude_state"
}
SKIPF_T="$WORK/floor-skip-flag-target"; mkdir -p "$SKIPF_T"
SKIPF_OUT=$(env PATH="$OLD_BD_DIR:$PATH" CWP_BEADS_UPGRADE=1 "$BASH_BIN" "$INSTALL_SH" --skip-beads-upgrade "$SKIPF_T" </dev/null 2>&1); SKIPF_RC=$?
refused_cleanly "9.11 --skip-beads-upgrade on bd 0.47.1, opt-in also set:" "$SKIPF_OUT" "$SKIPF_RC" "$SKIPF_T"
assert_eq "9.11 ...and names the flag as not admitting the old bd" "yes" \
    "$(contains "$SKIPF_OUT" "does not admit a bd below")"

SKIPE_T="$WORK/floor-skip-env-target"; mkdir -p "$SKIPE_T"
SKIPE_OUT=$(env PATH="$OLD_BD_DIR:$PATH" CWP_SKIP_BEADS_UPGRADE=1 "$BASH_BIN" "$INSTALL_SH" "$SKIPE_T" </dev/null 2>&1); SKIPE_RC=$?
refused_cleanly "9.12 CWP_SKIP_BEADS_UPGRADE=1 on bd 0.47.1:" "$SKIPE_OUT" "$SKIPE_RC" "$SKIPE_T"

OPTF_T="$WORK/floor-optin-fails-target"; mkdir -p "$OPTF_T"
OPTF_OUT=$(env PATH="$OLD_BD_DIR:$PATH" BD_UPGRADE_COMMAND=false CWP_BEADS_UPGRADE=1 "$BASH_BIN" "$INSTALL_SH" "$OPTF_T" </dev/null 2>&1); OPTF_RC=$?
refused_cleanly "9.13 opt-in whose upgrade command FAILS:" "$OPTF_OUT" "$OPTF_RC" "$OPTF_T"
assert_eq "9.13 ...and it does not claim to be continuing" "no" \
    "$(contains "$OPTF_OUT" "Continuing on bd")"

OPTN_T="$WORK/floor-optin-noop-target"; mkdir -p "$OPTN_T"
OPTN_OUT=$(env PATH="$OLD_BD_DIR:$PATH" BD_UPGRADE_COMMAND=true CWP_BEADS_UPGRADE=1 "$BASH_BIN" "$INSTALL_SH" "$OPTN_T" </dev/null 2>&1); OPTN_RC=$?
refused_cleanly "9.14 opt-in with the runner's no-op stub (bd stays 0.47.1):" "$OPTN_OUT" "$OPTN_RC" "$OPTN_T"

# CONTROL for 9.11-9.12: the skip flag on a bd AT the floor is not refused, so
# those legs fail because the bd is old, not because the flag refuses.
SKIPC_T="$WORK/floor-skip-control-target"; mkdir -p "$SKIPC_T"
SKIPC_OUT=$(env PATH="$NEW_BD_DIR:$PATH" "$BASH_BIN" "$INSTALL_SH" --skip-beads-upgrade "$SKIPC_T" </dev/null 2>&1)
assert_eq "9.C2 CONTROL: --skip-beads-upgrade on a bd at the floor is NOT refused" "no" \
    "$(contains "$SKIPC_OUT" "REFUSING to install")"
assert_eq "9.C2 CONTROL: ...and it really installed (.claude/ present)" "yes" \
    "$([ -d "$SKIPC_T/.claude" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 9.15 — ONE PROCEDURE, TWO INSTALLERS (claude-workflow-plugin-i4ac).
#
# install.ps1 printed its own older copy of the cross-era procedure: no dry run
# before --apply, no exit code, the floor where the pinned bridge belongs, and a
# weaker reason not to install the newest bd. A comment asking two copies to
# stay in step is how that happened, so this compares them LINE FOR LINE. Only
# these differ, by design, and are mapped before comparing:
#   - install.sh's em-dash is "-" in install.ps1, whose output stays ASCII;
#   - the backup line and the `cd <project>; bd bootstrap` line use
#     PowerShell's own syntax;
#   - the re-run and check commands are each installer's own, compared here
#     as <RERUN> / <VERIFY> (9.16 checks the bash ones).
# HALF OF THIS IS A DOCUMENT CHECK, AND IT SAYS SO. The install.sh side RUNS
# (FLOOR_OUT is the shipped installer's own output). The install.ps1 side is
# READ from source: install.ps1 is never executed by this suite or anywhere
# else, and running it here, even under pwsh on Linux, would falsify the
# release text's "never executed on any host". The META below proves the
# comparison can fail. Nothing here proves PowerShell renders the strings as
# they read.
sh_procedure() { # <installer output>: steps 1-4 as printed, re-run/check as placeholders
    printf '%s\n' "$1" | awk '
        /^    1\. Back up/ { p = 1 }
        p && rerun  { print "         <RERUN>"; rerun = 0; next }
        p && verify { print "         <VERIFY>"; exit }
        p { print }
        p && /# rebuilds from the ledger$/ { rerun = 1 }
        p && /Then re-run the check:$/ { verify = 1 }'
}
# The `$(...)` on both sides of this sed are TEXT the two installers print.
# shellcheck disable=SC2016
ps1_mapped() { # <rendered install.ps1 procedure>: PowerShell syntax mapped to bash's
    printf '%s\n' "$1" | sed \
        -e 's#^         Copy-Item -Recurse \.beads "\.beads\.backup-\$(Get-Date -Format yyyyMMdd)"$#         cp -R .beads .beads.backup-$(date +%Y%m%d)#' \
        -e 's#^         cd <project>; bd bootstrap #         cd <project> \&\& bd bootstrap #'
}
SH_PROC=$(sh_procedure "$FLOOR_OUT" | sed 's/—/-/g')
PS1_PROC_MAPPED=$(ps1_mapped "$PS1_PROC")
assert_eq "9.15a NON-VACUITY: both procedures were rendered, steps 1 to 4, each ending in its check" "yes" \
    "$([ "$(printf '%s\n' "$SH_PROC" | grep -c .)" -gt 20 ] \
        && printf '%s\n' "$SH_PROC" | grep -qxF '         <VERIFY>' \
        && printf '%s\n' "$PS1_PROC_MAPPED" | grep -qxF '         <VERIFY>' && echo yes || echo no)"
assert_eq "9.15b install.ps1 prints install.sh's procedure LINE FOR LINE (only the mapped platform lines differ)" \
    "$SH_PROC" "$PS1_PROC_MAPPED"
# shellcheck disable=SC2016  # `$BridgeBdVersion` is PowerShell source being matched
assert_eq "9.15c ...and the two installers pin the SAME bridge version" "$BRIDGE_VER" \
    "$(sed -n 's/^\$BridgeBdVersion = "\(.*\)"$/\1/p' "$PS1_FILE" | head -1)"
# META: a copy of install.ps1 that skips the dry run, which is i4ac's defect.
PS1_MUT="$WORK/install.ps1.no-dry-run"
awk '/Write-Host "         bash \.claude\/scripts\/beads-ledger\.sh reconcile"$/ && !done { done = 1; next }
     { print }
     END { if (!done) exit 7 }' "$PS1_FILE" > "$PS1_MUT"; PS1_MUT_RC=$?
assert_eq "9.15 META non-vacuity: the dry-run line was found and dropped from the mutant copy" "0" "$PS1_MUT_RC"
assert_eq "9.15 META non-vacuity: ...so the mutant really differs from the shipped file" "yes" \
    "$(cmp -s "$PS1_FILE" "$PS1_MUT" && echo no || echo yes)"
assert_eq "9.15 META specific misbehaviour: a procedure that skips the dry run FAILS 9.15b" "no" \
    "$([ "$(ps1_mapped "$(ps1_procedure "$PS1_MUT")")" = "$SH_PROC" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 9.16 — THE RE-RUN THE PROCEDURE PRINTS (claude-workflow-plugin-s229).
#
# The procedure is addressed to people on bd 0.47.x, and they install with the
# README's curl one-liner: they have NO local install.sh. Until s229, steps 3
# and 4 printed `bash install.sh <project>` regardless, so step 3 of a one-way
# migration pointed the very people it addresses at a file that does not
# exist. The end-to-end measurement ran from a clone and could not see that.
# These legs run the SHIPPED installer down the path those people take, the
# script fed to bash on stdin, which is exactly what `curl ... | bash` does. The
# refusal fires before any source is fetched, so nothing touches the network.
CURL_T="$WORK/floor-curl-target"; mkdir -p "$CURL_T"
CURL_OUT=$(cd "$CURL_T" && env -u CLAUDE_WORKFLOW_REPO -u CLAUDE_WORKFLOW_BRANCH PATH="$OLD_BD_DIR:$PATH" \
    "$BASH_BIN" -s < "$INSTALL_SH" 2>&1); CURL_RC=$?
refused_cleanly "9.16 the shipped installer fed to bash on stdin (curl | bash), bd 0.47.1:" "$CURL_OUT" "$CURL_RC" "$CURL_T"
RAW_MAIN="https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.sh"
assert_eq "9.16a step 3 re-runs the installer with the curl one-liner" "yes" \
    "$(printf '%s\n' "$CURL_OUT" | grep -qxF "         curl -fsSL $RAW_MAIN | bash" && echo yes || echo no)"
assert_eq "9.16b ...and step 4's check is that one-liner with --verify" "yes" \
    "$(printf '%s\n' "$CURL_OUT" | grep -qxF "         curl -fsSL $RAW_MAIN | bash -s -- --verify" && echo yes || echo no)"
assert_eq "9.16c ...and no line sends the curl user to a local install.sh" "no" \
    "$(printf '%s\n' "$CURL_OUT" | grep -qE 'bash [^ ]*install\.sh' && echo yes || echo no)"
BR_T="$WORK/floor-curl-branch-target"; mkdir -p "$BR_T"
BR_OUT=$(cd "$BR_T" && env -u CLAUDE_WORKFLOW_REPO PATH="$OLD_BD_DIR:$PATH" CLAUDE_WORKFLOW_BRANCH=feature/x \
    "$BASH_BIN" -s < "$INSTALL_SH" 2>&1)
assert_eq "9.16d a run started against a branch re-runs THAT branch, not main" "yes" \
    "$(printf '%s\n' "$BR_OUT" | grep -qxF "         curl -fsSL https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/feature/x/install.sh | CLAUDE_WORKFLOW_BRANCH=feature/x bash" && echo yes || echo no)"
INSTALL_DIR_ABS=$(cd "$(dirname "$INSTALL_SH")" && pwd)
assert_eq "9.16e run from a clone, step 3 names that clone's installer by ABSOLUTE path (step 1 has cd'd away from it)" "yes" \
    "$(printf '%s\n' "$FLOOR_OUT" | grep -qxF "         bash \"$INSTALL_DIR_ABS/install.sh\" <project>" && echo yes || echo no)"
assert_eq "9.16f ...and so does step 4's check" "yes" \
    "$(printf '%s\n' "$FLOOR_OUT" | grep -qxF "         bash \"$INSTALL_DIR_ABS/install.sh\" --verify <project>" && echo yes || echo no)"
# META: the pre-s229 behaviour, restored in a copy by making the helper return
# the old local form at once.
SH_MUT="$WORK/install.sh.pre-s229"
# The line is bash SOURCE written into the mutant, so its `$1` must not expand.
# shellcheck disable=SC2016
MUT_LINE='    printf '\''bash install.sh%s <project>'\'' "${1:+ $1}"; return 0'
awk -v line="$MUT_LINE" '{ print } /^installer_rerun_cmd\(\) \{$/ { print line; hit = 1 } END { if (!hit) exit 7 }' \
    "$INSTALL_SH" > "$SH_MUT"; SH_MUT_RC=$?
assert_eq "9.16 META non-vacuity: the mutation landed (the old form is returned at the helper's first line)" "0" "$SH_MUT_RC"
assert_eq "9.16 META non-vacuity: ...and the mutant still parses" "yes" \
    "$("$BASH_BIN" -n "$SH_MUT" 2>/dev/null && echo yes || echo no)"
MUT_T="$WORK/floor-curl-mutant-target"; mkdir -p "$MUT_T"
MUT_OUT=$(cd "$MUT_T" && env -u CLAUDE_WORKFLOW_REPO -u CLAUDE_WORKFLOW_BRANCH PATH="$OLD_BD_DIR:$PATH" \
    "$BASH_BIN" -s < "$SH_MUT" 2>&1)
assert_eq "9.16 META specific misbehaviour: run the curl way, the pre-s229 installer sends the curl user to a local install.sh, so 9.16c goes red" "yes" \
    "$(printf '%s\n' "$MUT_OUT" | grep -qxF '         bash install.sh <project>' && echo yes || echo no)"
assert_eq "9.16 META specific misbehaviour: ...and prints no curl one-liner, so 9.16a goes red too" "no" \
    "$(printf '%s\n' "$MUT_OUT" | grep -qF "curl -fsSL $RAW_MAIN" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 9.17 — cd BEFORE THE BACKUP (claude-workflow-plugin-s229). With the copy
# first, a cp run from the wrong directory fails, and a hurried operator carries
# on into a one-way migration with no backup.
step1_order() { # <installer output>: "cd backup flush" line numbers
    local out="$1" cd_n cp_n fl_n
    cd_n=$(printf '%s\n' "$out" | grep -nxF '         cd <project>' | head -1 | cut -d: -f1)
    cp_n=$(printf '%s\n' "$out" | grep -nF 'cp -R .beads .beads.backup-' | head -1 | cut -d: -f1)
    fl_n=$(printf '%s\n' "$out" | grep -nF 'bd sync --flush-only' | head -1 | cut -d: -f1)
    printf '%s %s %s' "${cd_n:-x}" "${cp_n:-x}" "${fl_n:-x}"
}
read -r S1_CD S1_CP S1_FL <<< "$(step1_order "$CURL_OUT")"
assert_eq "9.17a NON-VACUITY: step 1's cd, backup and flush lines were all located" "yes" \
    "$([ "$S1_CD" != x ] && [ "$S1_CP" != x ] && [ "$S1_FL" != x ] && echo yes || echo no)"
assert_eq "9.17b step 1 changes into the project BEFORE it copies .beads" "yes" \
    "$([ "$S1_CD" != x ] && [ "$S1_CP" != x ] && [ "$S1_CD" -lt "$S1_CP" ] && echo yes || echo no)"
assert_eq "9.17c ...and copies .beads BEFORE the flush" "yes" \
    "$([ "$S1_CP" != x ] && [ "$S1_FL" != x ] && [ "$S1_CP" -lt "$S1_FL" ] && echo yes || echo no)"
# META: the backup-first order, restored in a copy.
SWAP_MUT="$WORK/install.sh.backup-first"
awk '/^    echo "         cd <project>"$/ && !held { held = $0; next }
     held && /cp -R \.beads \.beads\.backup-/ { print; print held; held = ""; swapped = 1; next }
     { print }
     END { if (!swapped) exit 7 }' "$INSTALL_SH" > "$SWAP_MUT"; SWAP_RC=$?
assert_eq "9.17 META non-vacuity: the cd and backup lines were found and swapped in the mutant copy" "0" "$SWAP_RC"
SWAP_T="$WORK/floor-swap-mutant-target"; mkdir -p "$SWAP_T"
SWAP_OUT=$(cd "$SWAP_T" && env -u CLAUDE_WORKFLOW_REPO -u CLAUDE_WORKFLOW_BRANCH PATH="$OLD_BD_DIR:$PATH" \
    "$BASH_BIN" -s < "$SWAP_MUT" 2>&1)
read -r M1_CD M1_CP _ <<< "$(step1_order "$SWAP_OUT")"
assert_eq "9.17 META specific misbehaviour: the backup-first copy prints the copy before the cd, so 9.17b goes red" "yes" \
    "$([ "$M1_CD" != x ] && [ "$M1_CP" != x ] && [ "$M1_CP" -lt "$M1_CD" ] && echo yes || echo no)"

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

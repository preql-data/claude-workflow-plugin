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
# without running an install or a real 11-check doctor.
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
# to tell them — through the doctor's own `deps` check, alongside the other ten.
# If the prerequisite block ran first, a node-less machine would get
# "node and npm are REQUIRED" and learn nothing about the other ten checks.
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
    "$SYNTH/.claude/mcp/bd-mcp" "$SYNTH/.claude/mcp/code-graph-mcp" \
    "$SYNTH/.claude-plugin" "$SYNTH/docs" "$SYNTH/bin"
for agent in orchestrator qa backend frontend devops; do
    printf -- '---\nmodel: test\n---\nsynthetic %s agent\n' "$agent" \
        > "$SYNTH/.claude/agents/$agent.md"
done
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
cat > "$SYNTH/bin/bd" <<'FAKE_BD'
#!/bin/bash
case "${1:-}" in
    --version|-v|version) printf 'bd 0.99.0 (fake-bd for installer-flags)\n' ;;
    doctor)               printf 'fake-bd: all checks passed\n' ;;
    *)                    printf 'fake-bd: ok (%s)\n' "${1:-}" ;;
esac
exit 0
FAKE_BD
chmod +x "$SYNTH/bin/bd"

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

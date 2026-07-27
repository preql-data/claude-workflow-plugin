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
#   1. --help: exit 0, both flags documented, exclusivity documented.
#   2. --mode validation: the enum is enforced, and a VALID mode is let past
#      (so section 2 cannot pass by rejecting everything).
#   3. Exclusivity: both flag orders and the `--mode <n>` spelling, with and
#      without bd on PATH, plus the ordering proof.
#   4. META-TEST: a copy with the exclusivity block deleted stops exiting 1.
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
assert_eq "-h prints the same usage block" "yes" \
    "$(contains "$RUN_OUT" "Claude Workflow Plugin v3 installer")"
# Printing usage must not be a side-effecting run.
assert_eq "--help never reaches the prerequisite checks" "no" \
    "$(contains "$RUN_OUT" "Checking prerequisites")"

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
assert_eq "META: the mutated copy no longer carries the refusal message" "no" \
    "$(contains "$(cat "$MUTANT")" "$EXCLUSIVITY_MSG")"

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
    "$SYNTH/.claude-plugin" "$SYNTH/bin"
for agent in orchestrator qa backend frontend devops; do
    printf -- '---\nmodel: test\n---\nsynthetic %s agent\n' "$agent" \
        > "$SYNTH/.claude/agents/$agent.md"
done
for helper in session-start intent-router post-edit verify-before-stop session-end \
    qa-gate review-check impact-report current-task prevent-orchestrator-edits; do
    printf '#!/bin/bash\nexit 0\n' > "$SYNTH/.claude/scripts/$helper.sh"
done
cp "$PROJECT_DIR/.claude/scripts/workflow-manifest.sh" "$SYNTH/.claude/scripts/" 2>/dev/null || \
    printf '#!/bin/bash\nexit 1\n' > "$SYNTH/.claude/scripts/workflow-manifest.sh"
printf '{"hooks":{}}\n'            > "$SYNTH/.claude/hooks/hooks.json"
printf 'synthetic skill\n'         > "$SYNTH/.claude/skills/workflow-engine/SKILL.md"
printf 'synthetic command\n'       > "$SYNTH/.claude/commands/workflow-model.md"
printf '{"env":{}}\n'              > "$SYNTH/.claude/settings.json"
printf '{"name":"synthetic","version":"9.9.9-test"}\n' > "$SYNTH/.claude-plugin/plugin.json"

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

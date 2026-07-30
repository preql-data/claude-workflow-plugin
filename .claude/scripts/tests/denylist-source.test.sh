#!/bin/bash
# denylist-source.test.sh — claude-workflow-plugin-3mg.1 (v4 Phase V4).
#
# ONE definition of "which paths the workflow treats as reviewable", three
# consumers. This L1 spec is the structural guard on that invariant: it reads
# the shipped scripts as TEXT and refuses a tree in which any consumer has
# grown its own copy of the regex again.
#
# WHY A STRUCTURAL TEST AND NOT ONLY A BEHAVIOURAL ONE
# ----------------------------------------------------
# The three copies that 3mg.1 consolidated did not diverge in one dramatic
# commit; they drifted, one alternative at a time, over three separate fixes.
# Only verify-before-stop.sh's copy ever learned about `.claude/worktrees/`
# and the e2e fixture churn, so post-edit.sh tracked worktree paths INTO the
# change-set hash that the Stop gate could not see — the hash and the gate
# disagreed about what "the changes" were. A behavioural spec catches a
# divergence only for the pattern it happens to probe (that is L2's
# denylist-shared.sh, which drives a canary through all three consumers).
# THIS spec catches the re-introduction itself, for every pattern at once,
# the moment someone pastes a literal regex back into a consumer.
#
# ASSERTIONS
#   1. .claude/scripts/workflow-denylist.sh exists, is FLAT under scripts/
#      (the fixture-sync glob and the vitest drift guard enumerate flat
#      `.claude/scripts/*.sh` only — a nested lib/ would silently not sync
#      into the 7 e2e fixtures and break their sourced hooks), defines
#      WORKFLOW_DENYLIST_REGEX + workflow_denylisted, and parses.
#   2. Each of the three consumers SOURCES it, resolved BASH_SOURCE-relative
#      (never $CLAUDE_PROJECT_DIR-relative: 3mg.2 runs the primary checkout's
#      hook with CLAUDE_PROJECT_DIR pointing at a worktree).
#   3. No consumer carries a literal `DENYLIST_REGEX='(^...` definition of
#      its own. Assigning FROM the shared variable is the sanctioned form.
#
# META-TEST: a fixture copy of a consumer that re-declares a literal regex
# must FAIL check 3, and one with its source line deleted must FAIL check 2.
# Without those, both checks could be vacuously green.
#
# Exit codes:
#   0  all assertions pass and the META-TESTs flag the broken fixtures
#   1  one or more assertions failed

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SCRIPTS_DIR="$PROJECT_DIR/.claude/scripts"
LIB="$SCRIPTS_DIR/workflow-denylist.sh"

# The three consumers, by design: what gets TRACKED, what enters the change
# set + its HASH, what the Stop gate treats as needing REVIEW.
CONSUMERS="impact-report.sh post-edit.sh verify-before-stop.sh"

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

# ---------------------------------------------------------------------------
# The two checkers. Both take a FILE so the META-TESTs can run them against
# deliberately broken fixture copies — the assertion and its sensitivity
# proof then exercise byte-identical logic.

# check_sources_lib <file> — 0 when the file sources workflow-denylist.sh
# BASH_SOURCE-relative; 1 when it sources it some other way (e.g. anchored on
# $CLAUDE_PROJECT_DIR); 2 when it does not source it at all; 3 no such file.
#
# Anchoring matters as much as sourcing: a $PROJECT_DIR-relative load reads
# the lib out of whatever checkout the hook was POINTED at rather than the
# one it was INSTALLED in, so a worktree missing the lib would silently
# degrade the primary's gate.
check_sources_lib() {
    local f="$1"
    [ -f "$f" ] || return 3
    grep -qE '(^|[[:space:]])(\.|source)[[:space:]]+"[^"]*/workflow-denylist\.sh"' "$f" || return 2
    grep -qF 'BASH_SOURCE' "$f" || return 1
    # The dir variable feeding the source must be derived from BASH_SOURCE,
    # not from PROJECT_DIR. One line, both tokens.
    grep -qE 'dirname "\$\{BASH_SOURCE\[0\]' "$f" || return 1
    return 0
}

# check_no_literal_regex <file> — 0 when the file contains NO literal
# denylist-regex definition, 1 when it does.
#
# The signature we forbid is an assignment whose right-hand side is a
# single-quoted ERE starting with the `(^|/)` path anchor every copy of this
# regex has always opened with. `DENYLIST_REGEX="$WORKFLOW_DENYLIST_REGEX"`
# (double-quoted, a reference) is the sanctioned form and is NOT matched.
# The lib's own canonical definition is not a consumer and is never passed
# to this checker.
check_no_literal_regex() {
    local f="$1"
    [ -f "$f" ] || return 2
    if grep -qE "^[[:space:]]*[A-Za-z0-9_]*DENYLIST_REGEX='\(\^" "$f"; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Assertion 1: the lib itself.

assert_eq "denylist-lib: .claude/scripts/workflow-denylist.sh exists (FLAT, syncable)" \
    "yes" "$([ -f "$LIB" ] && echo yes || echo no)"

if [ -f "$LIB" ]; then
    LIB_PARSE=0
    bash -n "$LIB" 2>/dev/null || LIB_PARSE=$?
    assert_eq "denylist-lib: parses under bash -n" "0" "$LIB_PARSE"

    assert_eq "denylist-lib: defines WORKFLOW_DENYLIST_REGEX" "1" \
        "$(grep -cE "^WORKFLOW_DENYLIST_REGEX='" "$LIB" | tr -d '[:space:]')"
    assert_eq "denylist-lib: defines workflow_denylisted()" "1" \
        "$(grep -cE '^workflow_denylisted\(\) \{' "$LIB" | tr -d '[:space:]')"

    # No side effects: sourcing the lib must not print, must not exit, and
    # must leave the caller's shell otherwise untouched. Anything else makes
    # it unsafe to load from a hook whose stdout IS the hook envelope.
    LIB_NOISE=$(bash -c ". '$LIB'" 2>&1)
    assert_eq "denylist-lib: sourcing is silent (hook stdout is the JSON envelope)" \
        "" "$LIB_NOISE"

    # And it actually answers: 0 = drop, 1 = keep.
    #
    # dl_verdict <path> — the shipped lib's own answer, as a word. Every
    # behavioural assertion below goes through it, so they all measure the
    # same function the three consumers call rather than a re-implementation.
    #
    # The lib path and the probe path are passed as ARGUMENTS to `bash -c`,
    # never interpolated into its script text: a path containing a quote would
    # otherwise rewrite the command rather than be tested by it.
    dl_verdict() {
        bash -c '. "$1"; workflow_denylisted "$2" && echo drop || echo keep' \
            _dl_verdict "$LIB" "$1"
    }

    assert_eq "denylist-lib: workflow_denylisted drops a build path" \
        "drop" "$(dl_verdict 'node_modules/x.js')"
    assert_eq "denylist-lib: workflow_denylisted keeps a source path" \
        "keep" "$(dl_verdict 'src/a.ts')"
    # Deliberately NOT denylisted — behaviour-bearing / audit deliverables.
    for keeper in CLAUDE.md LESSONS.md HANDOFF.md; do
        assert_eq "denylist-lib: $keeper stays reviewable" "keep" "$(dl_verdict "$keeper")"
    done

    # -----------------------------------------------------------------------
    # v4.1 landing (claude-workflow-plugin-wg6, absorbing prm): out-of-repo
    # and workflow-internal scratch.
    #
    # post-edit.sh records `tool_input.file_path` VERBATIM, so the change set
    # was never bounded by the repo — any absolute path an agent wrote entered
    # the change-set hash and the Stop gate. Six live instances in one
    # release; the worst hard-blocked a TASK-LESS plan-mode session across
    # three Stop iterations to J21 escalation, because the plan file is .md
    # (so F1 classifies it doc-only) and F1's fast path auto-approves only
    # WITH an active task, which plan mode forbids creating. No exit.
    #
    # These are BEHAVIOURAL pins on the shipped regex. The structural checks
    # above are pattern-agnostic by design and needed no change.
    # $HOME, not a literal: a hardcoded absolute home prefix is what CLAUDE.md
    # and AgentLint S7 forbid in source, and $HOME is the REAL prefix anyway
    # (a macOS dev box and a Linux CI runner spell it differently). The
    # alternative anchors on (^|/), so the verdict does not depend on it.
    assert_eq "denylist-lib: drops an OUT-OF-REPO plan-mode plan file (the J21 dead end)" \
        "drop" "$(dl_verdict "${HOME:-/nonexistent-home}/.claude/plans/v4-1-0-upgrade-gleaming-karp.md")"
    assert_eq "denylist-lib: drops a repo-relative .claude/plans/ file too" \
        "drop" "$(dl_verdict '.claude/plans/x.md')"
    assert_eq "denylist-lib: drops the macOS session scratchpad (/private/tmp/claude-<sess>/)" \
        "drop" "$(dl_verdict '/private/tmp/claude-501/sess/scratchpad/verdict.json')"
    # Linux CI has no /private prefix, so the `(/private)?` optionality is
    # only half-proven without this one — and CI is where the suite runs.
    assert_eq "denylist-lib: drops the Linux session scratchpad (/tmp/claude-<sess>/)" \
        "drop" "$(dl_verdict '/tmp/claude-501/sess/scratchpad/verdict.json')"
    assert_eq "denylist-lib: drops mutation-sweep per-run reports" \
        "drop" "$(dl_verdict '.claude/.mutation-runs/2026-07-29T12-00-00/report.json')"
    assert_eq "denylist-lib: drops mutation-sweep throwaway worktrees (--keep-worktrees)" \
        "drop" "$(dl_verdict '.claude/.mutation-worktrees/mut-014/src/a.ts')"

    # ANTI-OVERREACH. Each of these must stay REVIEWABLE, and each fails for
    # its own reason — a single over-broad alternative would take several out
    # at once.
    # The project's own planning deliverables live here and reviewers read them.
    assert_eq "denylist-lib: docs/plans/ stays reviewable (a deliverable, not a plan-mode file)" \
        "keep" "$(dl_verdict 'docs/plans/v4.1-upgrade-wave.md')"
    # Only the harness's per-run OUTPUT is dropped; its source is shipped code.
    assert_eq "denylist-lib: the mutation harness SOURCE stays reviewable" \
        "keep" "$(dl_verdict '.claude/tests/mutation/mutation-sweep.sh')"
    # POSITIVE PIN of the deliberate limit (see workflow-denylist.sh, "WHAT IS
    # DELIBERATELY *NOT* DENYLISTED"). Agent-chosen /tmp scratch is addressed
    # by PROMPT guidance, not by a /tmp pattern. If a future landing broadens
    # /tmp, this fails loudly and forces that block to be revisited first.
    assert_eq "denylist-lib: agent-chosen /tmp scratch stays reviewable (limit is deliberate)" \
        "keep" "$(dl_verdict '/tmp/qa-p5n-probe/notes.md')"
    # The ^ anchor is scoped to its own ERE branch: a repo-relative source
    # path that merely CONTAINS tmp/claude- is not the session scratchpad.
    assert_eq "denylist-lib: a repo-relative src/tmp/claude-*/ path stays reviewable (^ anchor holds)" \
        "keep" "$(dl_verdict 'src/tmp/claude-501/x/y')"
    # These two are why a general /tmp or /var/folders pattern is REJECTED:
    # impact-report-paths.sh and worktree-approval-resolution.sh seed
    # changed-files.txt with ABSOLUTE paths rooted at `mktemp -d`'s parent.
    # Either pattern would silently empty those change sets and both specs
    # would pass while proving nothing.
    assert_eq "denylist-lib: a macOS mktemp -d fixture path stays reviewable (/var/folders/)" \
        "keep" "$(dl_verdict '/var/folders/qr/T/component-fixture.aB3xYz/src/a.ts')"
    assert_eq "denylist-lib: a Linux mktemp -d fixture path stays reviewable (/tmp/)" \
        "keep" "$(dl_verdict '/tmp/component-fixture.aB3xYz/src/a.ts')"
fi

# ---------------------------------------------------------------------------
# Assertion 2 + 3: every consumer sources the lib and carries no copy.

for c in $CONSUMERS; do
    f="$SCRIPTS_DIR/$c"
    rc=0
    check_sources_lib "$f" || rc=$?
    assert_eq "denylist-source: $c sources workflow-denylist.sh (BASH_SOURCE-relative)" "0" "$rc"

    rc=0
    check_no_literal_regex "$f" || rc=$?
    assert_eq "denylist-source: $c carries NO literal denylist regex of its own" "0" "$rc"
done

# ---------------------------------------------------------------------------
# META-TEST 1: a consumer copy that re-declares a literal regex must FAIL
# check 3. This is the exact regression the spec exists to stop — someone
# pastes the old one-liner back in "to avoid the dependency".

# Quoted heredoc delimiters throughout: every fixture below is LITERAL shell
# text, never something this spec wants expanded.
META_LITERAL=$(mktemp -t denylist-source-literal.XXXXXX)
cat > "$META_LITERAL" <<'FIXTURE'
#!/bin/bash
_WFDL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
. "$_WFDL_DIR/workflow-denylist.sh"
# The re-introduced copy. Note this fixture ALSO still sources the lib, which
# is how the drift comes back for real: the source line stays, and the local
# literal quietly wins.
DENYLIST_REGEX='(^|/)(node_modules|dist)/'
FIXTURE

rc_meta=0
check_no_literal_regex "$META_LITERAL" || rc_meta=$?
assert_eq "META: checker flags a consumer that re-declares a literal regex" "1" "$rc_meta"
# ...and note it would have passed the source check, which is exactly why the
# literal-regex check has to exist separately.
rc_meta=0
check_sources_lib "$META_LITERAL" || rc_meta=$?
assert_eq "META: that same copy still passes the source check (checks are independent)" \
    "0" "$rc_meta"
rm -f "$META_LITERAL"

# ---------------------------------------------------------------------------
# META-TEST 2: a consumer copy with the source line removed must FAIL check 2.

META_NOSOURCE=$(mktemp -t denylist-source-nosource.XXXXXX)
cat > "$META_NOSOURCE" <<'FIXTURE'
#!/bin/bash
DENYLIST_REGEX="$WORKFLOW_DENYLIST_REGEX"
FIXTURE
rc_meta=0
check_sources_lib "$META_NOSOURCE" || rc_meta=$?
assert_eq "META: checker flags a consumer that does not source the lib" "2" "$rc_meta"
rm -f "$META_NOSOURCE"

# ---------------------------------------------------------------------------
# META-TEST 3: a consumer that sources the lib but anchors on
# $CLAUDE_PROJECT_DIR must FAIL check 2 as well. That form looks correct and
# behaves correctly on a single checkout, and breaks precisely in the
# cross-worktree topology 3mg.2 builds on.

META_PROJDIR=$(mktemp -t denylist-source-projdir.XXXXXX)
cat > "$META_PROJDIR" <<'FIXTURE'
#!/bin/bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
. "$PROJECT_DIR/.claude/scripts/workflow-denylist.sh"
DENYLIST_REGEX="$WORKFLOW_DENYLIST_REGEX"
FIXTURE
rc_meta=0
check_sources_lib "$META_PROJDIR" || rc_meta=$?
assert_eq "META: checker flags a PROJECT_DIR-anchored source (not BASH_SOURCE-relative)" \
    "1" "$rc_meta"
rm -f "$META_PROJDIR"

# --- Summary -------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

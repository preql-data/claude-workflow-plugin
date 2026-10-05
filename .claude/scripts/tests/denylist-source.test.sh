#!/bin/bash
# denylist-source.test.sh — claude-workflow-plugin-3mg.1 (v4 Phase V4),
# extended for the second rule and the fourth consumer in 94d.
#
# ONE definition of "which paths the workflow treats as reviewable", FOUR
# consumers. This L1 spec is the structural guard on that invariant: it reads
# the shipped scripts as TEXT and refuses a tree in which any consumer has
# grown its own copy of the regex again.
#
# WHY THE COUNTS IN THIS FILE ARE LOAD-BEARING (94d / R2-F5)
# ---------------------------------------------------------
# This spec used to say "three consumers" and assert only WORKFLOW_DENYLIST_REGEX
# + workflow_denylisted(). 94d added a SECOND rule (workflow_self_written) and a
# FOURTH consumer (qa-gate.sh, which became the second writer of
# changed-files.txt), and the canary was not extended with them. The cost was
# immediate and measurable: post-edit.sh — the PRIMARY writer of the tracker, and
# a file 94d itself modified — was never taught the second rule, so every
# Write-tool edit to `.claude/.qa-tracking/` entered the tracker, the change-set
# hash, and the Stop detector, in direct contradiction of the rule's own stated
# intent. A rule with four relevant writers, asserted against three, let the
# fourth diverge in the same change set that introduced the rule.
#
# So: when a consumer is added, add it to $CONSUMERS. When a rule is added, add
# its definition assertion, its behavioural pins, and its applier list. Both
# counts appear in prose above and in the arrays below; keep them in step.
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
# denylist-shared.sh, which drives a canary through all four consumers —
# sections A and E1).
# THIS spec catches the re-introduction itself, for every pattern at once,
# the moment someone pastes a literal regex back into a consumer.
#
# ASSERTIONS
#   1. .claude/scripts/workflow-denylist.sh exists, is FLAT under scripts/
#      (the fixture-sync glob and the vitest drift guard enumerate flat
#      `.claude/scripts/*.sh` only — a nested lib/ would silently not sync
#      into the 7 e2e fixtures and break their sourced hooks), defines BOTH
#      rules (WORKFLOW_DENYLIST_REGEX + workflow_denylisted,
#      WORKFLOW_SELF_WRITTEN_REGEX + workflow_self_written), and parses.
#   2. Each of the FOUR consumers SOURCES it, resolved BASH_SOURCE-relative
#      (never $CLAUDE_PROJECT_DIR-relative: 3mg.2 runs the primary checkout's
#      hook with CLAUDE_PROJECT_DIR pointing at a worktree).
#   3. No consumer carries a literal `DENYLIST_REGEX='(^...` (or
#      `SELF_WRITTEN_REGEX='(^...`) definition of its own. Assigning FROM the
#      shared variable is the sanctioned form.
#   4. Every consumer that WRITES OR CLASSIFIES tree state applies the second
#      rule by CALLING workflow_self_written — the check that would have caught
#      R2-F5 the day it landed.
#
# META-TEST: a fixture copy of a consumer that re-declares a literal regex
# must FAIL check 3, one with its source line deleted must FAIL check 2, and one
# that sources the lib but never calls workflow_self_written must FAIL check 4.
# Without those, the checks could be vacuously green.
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

# The FOUR consumers, by design: what gets TRACKED, what a reconcile APPENDS to
# the same tracker (94d — the second writer), what enters the change set + its
# HASH, what the Stop gate treats as needing REVIEW.
CONSUMERS="impact-report.sh post-edit.sh qa-gate.sh verify-before-stop.sh"

# The consumers that must apply the SECOND rule (workflow_self_written).
#
# These are the three that WRITE the tracker or CLASSIFY tree state:
# post-edit.sh (primary writer), qa-gate.sh (reconcile_tracker, second writer),
# verify-before-stop.sh (the Stop detector's git walk). impact-report.sh is
# deliberately NOT in this list: it READS the tracker the other two write, so by
# the time it hashes, a self-written path has already been filtered at the
# source. Adding the rule there as well would make a reader disagree with the
# other readers about a legacy entry an older install had already recorded,
# which is the hash-and-gate-disagree failure the shared lib exists to prevent.
#
# KNOWN GAP, filed not fixed: verify-before-stop.sh's `wtres_no_drift_in` is a
# fourth walk over tree state that does NOT apply the rule (QA R1-F4). It is a
# worktree-bridge recovery path rather than a certification path, and it is
# pre-existing. This spec checks per FILE, not per walk, so verify-before-stop.sh
# passes check 4 on reviewable_changes() alone — recorded here so the pass is not
# mistaken for full coverage of that file.
SELF_WRITTEN_APPLIERS="post-edit.sh qa-gate.sh verify-before-stop.sh"

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
# definition of EITHER shared regex, 1 when it does.
#
# The signature we forbid is an assignment whose right-hand side is a
# single-quoted ERE starting with the `(^|/)` path anchor every copy of these
# regexes has always opened with. `DENYLIST_REGEX="$WORKFLOW_DENYLIST_REGEX"`
# (double-quoted, a reference) is the sanctioned form and is NOT matched.
# The lib's own canonical definitions are not a consumer and are never passed
# to this checker.
#
# BOTH names are covered (94d): a re-pasted copy of the self-written rule drifts
# exactly the same way a re-pasted denylist does, and the two rules disagreeing
# is worse than either being wrong alone — one decides what enters the tracker,
# the other what may enter it as a side effect of the gate running.
check_no_literal_regex() {
    local f="$1"
    [ -f "$f" ] || return 2
    if grep -qE "^[[:space:]]*[A-Za-z0-9_]*(DENYLIST|SELF_WRITTEN)_REGEX='\(\^" "$f"; then
        return 1
    fi
    return 0
}

# check_applies_self_written <file> — 0 when the file CALLS
# workflow_self_written, 1 when it only mentions it (or not at all), 2 no file.
#
# Anchored on the CALL shape (`workflow_self_written "…`) rather than the bare
# identifier, because every one of these files also discusses the rule in prose:
# a comment naming it would satisfy a substring grep while the filter was absent,
# which is precisely the state post-edit.sh shipped in until R2-F5.
check_applies_self_written() {
    local f="$1"
    [ -f "$f" ] || return 2
    grep -qE '(^|[^A-Za-z0-9_])workflow_self_written[[:space:]]+"' "$f" || return 1
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
    # RULE 2 (94d). Same two structural pins as rule 1, in one place, so a
    # rename or a relocation of either half fails here rather than by silently
    # degrading a consumer's `[ -n "${WORKFLOW_SELF_WRITTEN_REGEX:-}" ]` guard
    # into a no-op — which is what an absent rule looks like from a consumer.
    assert_eq "denylist-lib: defines WORKFLOW_SELF_WRITTEN_REGEX (rule 2, 94d)" "1" \
        "$(grep -cE "^WORKFLOW_SELF_WRITTEN_REGEX='" "$LIB" | tr -d '[:space:]')"
    assert_eq "denylist-lib: defines workflow_self_written()" "1" \
        "$(grep -cE '^workflow_self_written\(\) \{' "$LIB" | tr -d '[:space:]')"

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
    # same function all four consumers call rather than a re-implementation.
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
    # "Never bounded by the repo" was true UNTIL claude-workflow-plugin-fkm.1.15,
    # which bounds it at the writer (post-edit.sh's containment check). These pins
    # are unaffected and still needed: they measure the LIB, which every consumer
    # applies — including the readers, which have no containment rule and can
    # still be handed an out-of-repo entry by a tracker an older install wrote or
    # by a spec that seeds the file directly.
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
    # DELIBERATELY *NOT* DENYLISTED"). If a future landing broadens /tmp, this
    # fails loudly and forces that block to be revisited first.
    #
    # THIS PINS THE LIB'S ANSWER, NOT THE TRACKER'S, and since
    # claude-workflow-plugin-fkm.1.15 the two differ for this path: post-edit.sh
    # drops it at record time via its containment check against
    # $CLAUDE_PROJECT_DIR, while rule 1 — correctly — still keeps it. A root
    # comparison can distinguish an agent's /tmp probe from this suite's own
    # /tmp fixture roots (the two assertions further down); a regex here cannot,
    # which is why the limit below is deliberate rather than an oversight.
    # Behavioural pins for the hook's side live in specs/post-edit.sh section 13
    # and specs/denylist-shared.sh D4.
    assert_eq "denylist-lib: agent-chosen /tmp scratch stays reviewable (limit is deliberate; the HOOK drops it by containment, not this rule)" \
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

    # -----------------------------------------------------------------------
    # RULE 2 — SELF-WRITTEN PATHS (claude-workflow-plugin-94d).
    #
    # A separate rule with separate semantics: the denylist answers "is this
    # reviewable work?", this one answers "may this path enter the change set as
    # a side effect of the GATE ITSELF running?". They must stay separate —
    # folding these into the denylist would erase them from the change set
    # entirely and flip a beads-only change set from the `beads-state` fast path
    # (releases WITH a gate record) to `empty` (releases with none).
    #
    # THE BOUNDARY IS THE WHOLE RULE, and until 94d/R2-F5 nothing anywhere
    # asserted it: `.beads/interactions.jsonl` is out (bd rewrites it on every
    # call, including the gate's own `label add`) while `.beads/issues.jsonl` is
    # IN (the committed ledger, a real deliverable, rewritten only on an explicit
    # export). One character of regex separates them.
    sw_verdict() {
        bash -c '. "$1"; workflow_self_written "$2" && echo self-written || echo reviewable' \
            _sw_verdict "$LIB" "$1"
    }

    # The gate's own state, in both spellings a consumer can hand it (post-edit
    # records absolute; git porcelain is repo-relative).
    assert_eq "self-written: the review ARTIFACT is self-written (the R2-F5 path)" \
        "self-written" "$(sw_verdict '/repo/.claude/.qa-tracking/review-artifact-cwp-94d-r2.json')"
    assert_eq "self-written: ...repo-relative too" \
        "self-written" "$(sw_verdict '.claude/.qa-tracking/review-artifact-cwp-94d-r2.json')"
    assert_eq "self-written: the tracker itself is self-written" \
        "self-written" "$(sw_verdict '.claude/.qa-tracking/changed-files.txt')"
    assert_eq "self-written: the impact report is self-written" \
        "self-written" "$(sw_verdict '.claude/.qa-tracking/impact-report-cwp-94d.json')"
    assert_eq "self-written: bd's interaction log is self-written" \
        "self-written" "$(sw_verdict '.beads/interactions.jsonl')"
    assert_eq "self-written: ...absolute too" \
        "self-written" "$(sw_verdict '/repo/.beads/interactions.jsonl')"

    # THE BOUNDARY, from the other side.
    assert_eq "self-written BOUNDARY: .beads/issues.jsonl is NOT self-written (committed ledger)" \
        "reviewable" "$(sw_verdict '.beads/issues.jsonl')"
    assert_eq "self-written BOUNDARY: ...absolute too" \
        "reviewable" "$(sw_verdict '/repo/.beads/issues.jsonl')"

    # ANTI-OVERREACH. Each leg falls to a DIFFERENT sloppy widening of the two
    # alternatives, so a single over-broad rewrite cannot take them all at once.
    assert_eq "self-written: ordinary source is not self-written" \
        "reviewable" "$(sw_verdict 'src/a.ts')"
    # The `.claude/` segment is required — `.qa-tracking` alone is a name anyone
    # may use for a source directory.
    assert_eq "self-written: src/.qa-tracking/x.ts stays reviewable (.claude/ segment required)" \
        "reviewable" "$(sw_verdict 'src/.qa-tracking/x.ts')"
    # ...and so is the leading dot on the directory name.
    assert_eq "self-written: .claude/qa-tracking/x.json stays reviewable (dotted name required)" \
        "reviewable" "$(sw_verdict '.claude/qa-tracking/x.json')"
    # The interactions branch is $-anchored: a sibling file is not the log.
    assert_eq "self-written: .beads/interactions.jsonl.bak stays reviewable (\$ anchor)" \
        "reviewable" "$(sw_verdict '.beads/interactions.jsonl.bak')"
    assert_eq "self-written: .beads/interactions-summary.jsonl stays reviewable" \
        "reviewable" "$(sw_verdict '.beads/interactions-summary.jsonl')"
    # And the two rules are INDEPENDENT: a self-written path is not denylisted,
    # which is what keeps a beads/gate-only change set on the `beads-state` fast
    # path (a gate record) rather than `empty` (none). If a future edit folded
    # rule 2 into the denylist, this fails and forces that call to be re-made
    # deliberately.
    assert_eq "self-written: a self-written path is NOT also denylisted (rules stay separate)" \
        "keep" "$(dl_verdict '.claude/.qa-tracking/changed-files.txt')"
    assert_eq "self-written: ...nor is bd's interaction log" \
        "keep" "$(dl_verdict '.beads/interactions.jsonl')"
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
    assert_eq "denylist-source: $c carries NO literal shared regex of its own" "0" "$rc"
done

# ---------------------------------------------------------------------------
# Assertion 4 (94d / R2-F5): every consumer that writes the tracker or
# classifies tree state actually CALLS the second rule.
#
# This is the check whose absence cost R2-F5. post-edit.sh sourced the lib
# (assertion 2 was green), carried no literal copy (assertion 3 was green), and
# still never consulted workflow_self_written — so the tracker it writes, the
# hash computed over that tracker, and the Stop detector's tracker half all
# absorbed the gate's own review artifact. Structural, not behavioural: L2's
# denylist-shared.sh section E drives the same rule through the consumers, but
# this catches the omission the moment a NEW consumer is added without it.
for c in $SELF_WRITTEN_APPLIERS; do
    f="$SCRIPTS_DIR/$c"
    rc=0
    check_applies_self_written "$f" || rc=$?
    assert_eq "self-written-source: $c CALLS workflow_self_written (94d)" "0" "$rc"
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

# ---------------------------------------------------------------------------
# META-TEST 4 (94d): a consumer that sources the lib, carries no literal copy,
# and merely TALKS about the second rule must FAIL check 4.
#
# This fixture is a faithful miniature of the R2-F5 state: correct source line,
# correct denylist reference, an accurate comment naming the rule — and no call.
# It passes checks 2 and 3, which is exactly why check 4 had to exist separately.

META_NOSW=$(mktemp -t denylist-source-nosw.XXXXXX)
cat > "$META_NOSW" <<'FIXTURE'
#!/bin/bash
_WFDL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
. "$_WFDL_DIR/workflow-denylist.sh"
DENYLIST_REGEX="$WORKFLOW_DENYLIST_REGEX"
# The lib defines workflow_self_written for gate state; see its header. (Prose
# only — this is the shape post-edit.sh shipped in until R2-F5.)
if [[ "$FILE_PATH" =~ $DENYLIST_REGEX ]]; then exit 0; fi
FIXTURE

rc_meta=0
check_applies_self_written "$META_NOSW" || rc_meta=$?
assert_eq "META: checker flags a consumer that only MENTIONS workflow_self_written" \
    "1" "$rc_meta"
# ...and it passes the other two checks, which is why check 4 is not redundant.
rc_meta=0
check_sources_lib "$META_NOSW" || rc_meta=$?
assert_eq "META: the rule-2-less copy still passes the SOURCE check (checks 2/4 independent)" \
    "0" "$rc_meta"
rc_meta=0
check_no_literal_regex "$META_NOSW" || rc_meta=$?
assert_eq "META: ...and the no-literal-regex check too (checks 3/4 independent)" "0" "$rc_meta"
rm -f "$META_NOSW"

# And the positive control for the checker itself: a call satisfies it.
META_SW=$(mktemp -t denylist-source-sw.XXXXXX)
cat > "$META_SW" <<'FIXTURE'
#!/bin/bash
_WFDL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
. "$_WFDL_DIR/workflow-denylist.sh"
if [ -n "${WORKFLOW_SELF_WRITTEN_REGEX:-}" ] && workflow_self_written "$FILE_PATH"; then exit 0; fi
FIXTURE
rc_meta=0
check_applies_self_written "$META_SW" || rc_meta=$?
assert_eq "META: checker accepts a consumer that CALLS workflow_self_written" "0" "$rc_meta"
rm -f "$META_SW"

# ---------------------------------------------------------------------------
# META-TEST 5 (94d): the literal-regex checker really covers the SECOND name.
# Without this leg, widening the pattern to `(DENYLIST|SELF_WRITTEN)_REGEX`
# could have been a typo and every consumer would still pass check 3.

META_SWLIT=$(mktemp -t denylist-source-swlit.XXXXXX)
cat > "$META_SWLIT" <<'FIXTURE'
#!/bin/bash
_WFDL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
. "$_WFDL_DIR/workflow-denylist.sh"
# The re-introduced copy of RULE 2, drifting the same way rule 1 once did.
SELF_WRITTEN_REGEX='(^|/)\.claude/\.qa-tracking/'
FIXTURE
rc_meta=0
check_no_literal_regex "$META_SWLIT" || rc_meta=$?
assert_eq "META: checker flags a re-declared literal SELF_WRITTEN regex too" "1" "$rc_meta"
rm -f "$META_SWLIT"

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

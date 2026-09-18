#!/bin/bash
# design-degradation.sh — L2 BEHAVIOURAL proof for D7 Piece D
# (claude-workflow-plugin-fkm.9, v5 Phase D7, release 5.0.0). Governing plan:
# docs/plans/v5-design-phase-plan.md:790-798. Cloned from
# .claude/tests/component/specs/reviewer-lane-degradation.sh, BEHAVIOURAL
# half only — see that file's own header and
# .claude/scripts/tests/design-structural.test.sh's header for why the
# STRUCTURAL half is NOT duplicated here: it lives at L1 from the start
# (claude-workflow-plugin-icn4 item 1's split, applied here without ever
# having been merged into one file the way the plan's own text at :795-798
# describes — that description is the PRE-icn4 shape).
#
# THIS FILE proves only:
#
#   BEHAVIOURAL: the identical review-record -> review-check GATE SEQUENCE
#   produces BYTE-IDENTICAL STDOUT (timestamps normalised) with
#   DESIGN_STORE=linear set in the environment, and with it explicitly
#   unset in a subshell (R1-F3 fix, see below).
#
# SCOPE, NARROWED (independent review round 1, R1-F3 + R1-F4 -- the original
# header overclaimed on two separate axes and both are corrected here rather
# than re-asserted):
#
#   "outputs" above means STDOUT ONLY. The original header also claimed
#   "and comments" -- no per-condition comment snapshot was ever taken, and
#   passing a FIXED --comments-json file to review-check.sh means the gate
#   never reads live posted bd comments in this fixture at all, so there
#   was nothing dynamic to compare there in the first place. Either narrow
#   the claim or actually compare comments; this narrows it.
#
#   This proves parity for exactly ONE sequence, not for "any path that
#   would observe DESIGN_STORE": review-record / review-check gate is the
#   only sequence that exists today which touches anything design-artifact-
#   adjacent, because DESIGN_STORE has ZERO readers anywhere in
#   .claude/scripts (re-measured below). If a future change gives
#   DESIGN_STORE a real reader elsewhere, THIS spec proves nothing about
#   that reader until it is extended to exercise it -- a byte-identical
#   result here would keep passing regardless. Catching that is not this
#   file's job either way: design-structural.test.sh is the piece that
#   would flag a new reader IF it reintroduces one of its three tracked
#   literal spellings into one of its three tracked files -- a tripwire,
#   not a completeness proof, per that file's own header.
#
# THE STRUCTURAL HALF LIVES AT L1
# (.claude/scripts/tests/design-structural.test.sh). That file's own header
# states this without overclaim (QA ROUND 2, R2-F1, RELEASE-BLOCKING — read
# it before citing this as more than what it says it is): "a TRIPWIRE for
# three literal spellings (DESIGN_STORE, capitalised Linear, bare lowercase
# linear as a code token) across exactly three files. It is cheap, fast,
# genuinely useful as an early warning, and it is NOT a proof that the
# invariant above holds." (That file's "THE INVARIANT": qa-gate.sh,
# verify-before-stop.sh and review-check.sh must never special-case WHERE a
# design artifact lives.) It is a sub-second grep-only check with its own
# META injection — it needs none of this file's Beads-backed fixture
# scaffolding. Read that file for the exact pattern, and for why a bare
# case-insensitive "linear" substring is NOT it (qa-gate.sh already
# contains that substring twice, in unrelated English prose — "non-linear",
# "a linear scan" — that this piece does not own and is not touching).
#
# WHY THIS BEHAVIOURAL HALF IS SIMPLER THAN ITS CODEX ANCESTOR. The optional
# Codex reviewer lane is a REAL, wired integration: reviewer-lane.json plus
# a registered stub MCP server actually change what the gate can observe, so
# reviewer-lane-degradation.sh builds two genuinely different fixture
# conditions and stubs a server to do it. None of the three PRODUCTION gate
# scripts (qa-gate.sh, verify-before-stop.sh, review-check.sh) currently
# contains any of the three tracked literal spellings (DESIGN_STORE,
# capitalised Linear, bare lowercase linear as a code token) -- the state
# this file's parity proof actually needs today, and the one
# design-structural.test.sh's own section A1 mechanically RE-CHECKS (a
# tripwire, not a completeness proof -- see that file's header) on every
# `make test` run, not merely asserted once here.
#
# RE-MEASURED at fix time (independent review round 1, R1-F4) because the
# ORIGINAL measurement command's own output is now stale by construction:
# these two new spec files mention DESIGN_STORE by name, intentionally, as
# the thing they test FOR, so the raw grep below is no longer zero:
#   $ grep -rn DESIGN_STORE .claude/scripts/*.sh .claude/scripts/tests/*.sh \
#         .claude/tests/component/specs/*.sh | wc -l
#   38
#   $ grep -rc DESIGN_STORE .claude/scripts/*.sh .claude/scripts/tests/*.sh \
#         .claude/tests/component/specs/*.sh | grep -v ':0$'
#   .claude/scripts/tests/design-structural.test.sh:11
#   .claude/tests/component/specs/design-degradation.sh:27
# Every OTHER file the same globs reach -- every production script under
# .claude/scripts/*.sh, and every other spec under .claude/scripts/tests/
# and .claude/tests/component/specs/ besides these two files -- reads zero.
# That is the load-bearing fact; the raw 38 is these two files talking
# about the thing they test (most of it this very header, discussing its
# own re-measurement — re-verify with the command above rather than
# trusting this number to survive the NEXT edit either), not a production
# reader appearing.
# "The only occurrence in the whole tree is the plan document" is ALSO now
# stale the same way: CHANGELOG.md, docs/RELEASE_AUDIT.md and HANDOFF.md all
# gained release-note mentions of DESIGN_STORE during this same release (the
# D7 audit ledger), and these two spec files are two more. None of those
# five files execute, so the production-script conclusion above is
# unaffected by any of them; only the raw tree-wide occurrence count and the
# exact quoted command output were wrong, and are corrected here rather
# than re-asserted unchecked.
# This is the honest state LIVE-3 already names ("NOT RUN ... there is no
# artifact at all"). So there is no stub server to register and no
# detection file to stage for the "linear" condition: this spec sets
# DESIGN_STORE=linear as a bare environment variable around the identical
# sequence and diffs the captured output against the same sequence with it
# explicitly unset — no fixture asymmetry beyond that one variable.
#
# A byte-identical STDOUT diff, for this ONE sequence, is the CORRECT and
# MEANINGFUL result today (QA ROUND 3, R3-F2 rewrites this passage, which
# used to claim more than that and contradicted the SCOPE, NARROWED
# paragraph above -- itself already accurate -- rather than agreeing with
# it). What the assertion below actually establishes is NORMALISED STDOUT
# EQUALITY, for the review-record -> review-check sequence, between
# DESIGN_STORE=linear and DESIGN_STORE unset -- not that nothing in the
# enforcement path treats DESIGN_STORE specially in any broader sense.
# Special treatment could change the exit status, stderr, persisted state,
# posted comments, or an unexercised branch and leave this one sequence's
# captured stdout identical either way; none of those are compared here.
# Symmetrically: if a future change ever wires DESIGN_STORE into any of the
# three gate scripts, this spec is NOT guaranteed to notice and is NOT
# guaranteed to need updating either -- only a change that also alters
# THIS sequence's stdout would make the assertion below fail. THE
# INVARIANT itself -- the gate machinery must behave IDENTICALLY
# regardless of which design-store backend produced the artifact it is
# enforcing against, the same discipline the codex/reviewer-lane pair
# already established -- is not something this file proves in general; it
# is only what motivates checking parity here, for the one sequence this
# file actually exercises.
#
# PAIRING (.claude/tests/README.md, "The pairing requirement"): this file
# carries no mutation of its own — both conditions run the REAL, unmodified
# qa-gate.sh / review-check.sh, only the environment differs, which is the
# correct shape for a parity proof (the mutation legs belong to the sibling
# L1 file, which mutates COPIES of the gate scripts and proves the
# structural check trips). What this file contributes: EXECUTION (leg 4) —
# the real gate scripts genuinely run end-to-end against a real Beads-backed
# fixture, not merely a comparison of static text — plus two non-vacuity
# legs proving the compared output is real and meaningful, not two
# trivially-matching empty files (the exact shape a diff-budget fixture
# built from two byte-identical files failed on earlier in this arc).

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

QAGATE="$FIXTURE/.claude/scripts/qa-gate.sh"
RCHECK="$FIXTURE/.claude/scripts/review-check.sh"
ISO='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# ---------------------------------------------------------------------------
# PRE-FLIGHT (independent review round 1, R1-F3): prove the mechanism the
# NONE condition below relies on actually works, BEFORE relying on it, and
# UNCONDITIONALLY (no bd dependency, so this still runs in an environment
# where bd_required_or_skip below would SKIP everything after it).
#
# The bug this closes: `DESIGN_STORE=linear run_sequence` (prefix
# assignment) always wins for the LINEAR condition regardless of ambient
# state, but the bare `run_sequence` call the NONE condition used to make
# does NOT itself clear an inherited *exported* DESIGN_STORE. If the
# process this spec runs in (the L2 component runner, or a leaked export
# from an earlier spec in the same batch) had DESIGN_STORE=linear exported,
# BOTH conditions would secretly BE the Linear condition, and the
# byte-identical assertion below would pass VACUOUSLY -- comparing the
# Linear condition against itself, never against NONE. The fix wraps the
# NONE condition in `( unset DESIGN_STORE; run_sequence )`; this proves
# that specific mechanism genuinely clears an inherited exported value,
# empirically, rather than merely asserting that `unset` "should" work:
UNSET_PROOF=$(DESIGN_STORE=linear bash -c '
    (
        unset DESIGN_STORE
        printf "DESIGN_STORE=[%s]" "${DESIGN_STORE:-}"
    )
')
assert_eq "pre-flight: unset inside a subshell genuinely clears an inherited EXPORTED DESIGN_STORE" \
    "DESIGN_STORE=[]" "$UNSET_PROOF"

# ---------------------------------------------------------------------------
# BEHAVIOURAL: the diff proof needs Beads (review-record posts a comment).
bd_required_or_skip

TID=$(bd create "design-degradation proof" -t task --json 2>/dev/null | jq -r '.id // empty')
[ -z "$TID" ] && TID=$(bd list --json 2>/dev/null | jq -r '.[0].id // empty')

# A fixed qa-claude artifact + a fixed comment-set for the gate. Using the
# --comments-json seam keeps the gate deterministic regardless of how many
# times review-record has appended to the live task.
cat > "$FIXTURE/art.json" <<EOF
{"contract_version":"1","task_id":"$TID","reviewer_identity":"qa-claude","reviewer_model":"claude","reviewer_pin":"claude","reviewed_hash":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef","risk_threshold":"high","stop_condition":"x","verdict":"findings","findings":[{"id":"R1-F1","severity":"critical","location":"a:1","evidence":"e","description":"d"}],"iterations":1,"stopped_by":"verdict"}
EOF
cat > "$FIXTURE/comments.json" <<'EOF'
["IMPLEMENTER: role=backend built it",
 "REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=claude reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:critical] at 2026-07-25T00:00:00Z: x"]
EOF

# run_sequence <output-file> — the identical sequence; outputs normalised.
run_sequence() {
    {
        # claude-workflow-plugin-rqer (v5 D2): --file now asserts the
        # CANONICAL derived path; piped via stdin instead — deterministic
        # given the FIXED $TID and identical content, so the byte-identical
        # comparison below (which already normalises the timestamp) is
        # unaffected.
        bash "$QAGATE" review-record "$TID" < "$FIXTURE/art.json" 2>/dev/null
        bash "$RCHECK" gate "$TID" --comments-json "$FIXTURE/comments.json" 2>/dev/null
    } | sed -E "s/${ISO}/<TS>/g"
}

# Condition LINEAR: DESIGN_STORE=linear set in the environment. Prefix
# assignment scopes the export to this one function call (and anything it
# spawns) and reverts afterward — verified directly before this file was
# written:
#   $ bash -c 'f(){ bash -c "echo \$FOO"; }; FOO=bar f; echo "${FOO:-unset}"'
#   bar
#   unset
DESIGN_STORE=linear run_sequence > "$FIXTURE/out_linear.txt"

# Condition NONE: DESIGN_STORE explicitly UNSET in a subshell — the
# default, and the only state this repository has ever actually run the
# gate scripts in (LIVE-3 is NOT RUN). R1-F3 fix: a bare `run_sequence`
# call here does NOT override an inherited *exported* DESIGN_STORE, which
# would make this condition secretly identical to the LINEAR condition
# above and the byte-identical assertion below pass vacuously -- see the
# PRE-FLIGHT proof earlier in this file for why the subshell-unset
# mechanism used here genuinely closes that gap. The subshell also means
# the unset can never leak back out and affect anything that runs after
# this file in the same batch.
( unset DESIGN_STORE; run_sequence ) > "$FIXTURE/out_none.txt"

# The captured outputs must be byte-identical. R2-F4 last bullet
# (independent review round 2): capture diff's exit status explicitly
# instead of discarding it. diff exits 0 (identical), 1 (differences
# found -- a real, expected-shape result if the two conditions ever DO
# diverge), or 2 (a real diff error, e.g. one input unreadable) --
# swallowing status entirely and judging only by whether stdout was empty
# would read a diff ERROR (stderr-only output, empty stdout) as a clean
# empty diff: the exact "tool failure classified as a clean result" defect
# this release is removing everywhere it appears (design-structural.test.sh,
# same round). rc is captured on its own line immediately after the command
# substitution, before anything else can clobber $?.
DIFF_OUT=$(diff "$FIXTURE/out_linear.txt" "$FIXTURE/out_none.txt" 2>/dev/null)
DIFF_RC=$?
if [ "$DIFF_RC" -gt 1 ]; then
    printf 'design-degradation: diff itself failed (rc=%s) comparing out_linear.txt and out_none.txt\n' "$DIFF_RC" >&2
    DIFF_OUT="ERROR:DIFF-TOOL-FAILURE(rc=$DIFF_RC)"
fi
assert_eq "behavioural: DESIGN_STORE=linear vs DESIGN_STORE unset outputs are byte-identical (empty diff)" \
    "" "$DIFF_OUT"

# Sanity: the sequence actually produced meaningful output (not two empty
# files that trivially match).
NONEMPTY=$([ -s "$FIXTURE/out_linear.txt" ] && echo 1 || echo 0)
assert_eq "behavioural: the captured sequence output is non-empty" "1" "$NONEMPTY"
assert_contains "behavioural: output includes the review-record envelope" \
    "REVIEW-ARTIFACT v1" "$(cat "$FIXTURE/out_linear.txt")"
assert_contains "behavioural: output includes the gate's unresolved_findings verdict" \
    "unresolved_findings" "$(cat "$FIXTURE/out_linear.txt")"

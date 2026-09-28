#!/bin/bash
# design-structural.test.sh — L1 unit fixture for D7 Piece D
# (claude-workflow-plugin-fkm.9, v5 Phase D7, release 5.0.0). Governing plan:
# docs/plans/v5-design-phase-plan.md:790-798 — the CHANGELOG's honesty that
# v5 ships no Linear integration at all (claude-workflow-plugin-qttq, F5 —
# this sentence originally read "the Linear adapter ships unproven — no
# live validation was run" until F4/F5 measured that no adapter existed to
# validate) gets an EARLY-WARNING TRIPWIRE (not a proof — see "WHAT THIS
# FILE ACTUALLY IS" below) from a pair of specs cloned from the SAME split
# reviewer-lane-structural.test.sh / reviewer-lane-degradation.sh already
# uses (claude-workflow-plugin-icn4 item 1): this file is the STRUCTURAL
# half; the BEHAVIOURAL half lives at L2,
# .claude/tests/component/specs/design-degradation.sh. This file follows the
# icn4 split from the start (built as two files, not built as one and
# re-split later) — the plan text at :795-798 describes the PRE-icn4 single
# L2 file shape; that shape was deliberately superseded for the reviewer-lane
# guard and there is no reason to reintroduce it here. See
# reviewer-lane-structural.test.sh:1-81 for the full rationale this file
# borrows: a structural grep-only check belongs at the cadence every
# `make test` runs at, not at L2's ~65-minute reserved cadence, because a
# violation that only a reserved-cadence check can see survives however many
# green runs happen between invocations ("guard cadence must be at least
# violation cadence").
#
# THE INVARIANT (plan:790-798, and the same "Sol-first must never touch the
# three gate scripts" discipline reviewer-lane-structural.test.sh already
# enforces for lane selection — same three files): qa-gate.sh,
# verify-before-stop.sh and review-check.sh must never special-case WHERE a
# design artifact lives. Whether a task's design document is the local
# docs/specs/<task-id>.md fallback or a Linear-connected document is a
# concern for whatever writes the artifact, never for the scripts that
# enforce against it — a gate that reasons about backend selection acquires
# a second, invisible way to refuse, exactly the failure mode the reviewer-
# lane invariant already exists to prevent for model/lane selection. LIVE-3
# (plan:790-798) was never run: the operator declined it (F5 of the
# finishing-pass brief) once measurement showed there was no adapter to
# validate in the first place — zero readers of DESIGN_STORE anywhere in
# .claude/scripts. DP17 (docs/RELEASE_AUDIT.md) accordingly moved from
# NOT-PROVEN to REMOVED rather than to PROVEN-WITH-CAVEAT: the claim was
# withdrawn, not downgraded to a caveat.
#
# WHAT THIS FILE ACTUALLY IS, STATED WITHOUT OVERCLAIM (QA ROUND 2,
# independent review, R2-F1, RELEASE-BLOCKING — read this before trusting
# anything below): a TRIPWIRE for three literal spellings (`DESIGN_STORE`,
# capitalised `Linear`, bare lowercase `linear` as a code token) across
# exactly three files. It is cheap, fast, genuinely useful as an early
# warning, and it is NOT a proof that the invariant above holds. A gate can
# select on DESIGN_STORE via a helper function this guard never scans, a
# re-cased comparison, or any of a dozen other spellings this guard has no
# way to enumerate in advance — "the detector recognises SPELLINGS, not
# backend-selection BEHAVIOUR" (the reviewer's own words, and the correct
# diagnosis). Round 1 of this review believed differently and shipped a
# header sentence claiming this guard "keeps [the NOT-PROVEN statement]
# mechanically true going forward" and a section comment claiming "every
# shape that constitutes actual wiring is still covered by signal 1 or
# signal 3." BOTH ARE FALSE. They are corrected in place below (not merely
# deleted, so the mistake stays visible where it was made) rather than
# silently removed: no lexical grep over three files can prove a negative
# about program behaviour in general, and claiming otherwise would make
# THIS spec the thing that is unproven — exactly backwards for a guard
# whose only job is honesty about what has and has not been checked. What
# is real and stays real: if a future change introduces one of these THREE
# SPELLINGS into one of these THREE FILES, this tripwire catches it, fast,
# in the `make test` tier, before a reserved-cadence or manual review
# would. That is the whole claim.
#
# =============================================================================
# QA ROUND 1 (independent, non-Claude review, sol-codex) FOUND THE ORIGINAL
# DETECTOR HERE — a single alternation `DESIGN_STORE|Linear|linear:` — HAD
# TWO REAL DEFECTS, one RELEASE-BLOCKING. Read this whole section before
# touching the detector below: it is a real design problem, not a regex
# tweak, and the fix is a small DETECTOR FUNCTION, not a single pattern.
#
# R1-F1 (RELEASE-BLOCKING). The original pattern is evaded completely by the
# most natural way to actually wire DESIGN_STORE=linear support in, because
# the plan itself (v5-design-phase-plan.md:519) defines the external-ref
# format as `linear:<issue-id>` — so the obvious implementation strips that
# prefix and switches on the bare value:
#     store="${external_ref%%:*}"
#     case "$store" in
#         linear) resolve_design_artifact "$external_ref" ;;
#     esac
# No DESIGN_STORE, no capitalised Linear, no literal `linear:` substring —
# the colon is CONSUMED by the prefix strip (`%%:*`) before the comparison
# ever happens. A guard whose entire purpose is to make "Linear ships
# unproven" mechanical would have stayed green through precisely the change
# it exists to detect.
#
# R1-F1 (narrowness half). The same review found the bare `Linear`
# alternative was not reliably NARROW either: it fires on innocent
# sentence-initial prose, e.g. a hypothetical comment
# `# Linear scans over this small list are acceptable.` — capitalised only
# because it is the first word of an English sentence, not because it names
# the product. The precision legs that shipped in round 0 only proved the
# two CURRENT lowercase phrases in qa-gate.sh were safe; they said nothing
# about prose in general, and this is a real, distinct gap from R1-F1's main
# finding, in the OPPOSITE direction (too loose, not too strict).
#
# R1-F2 (HIGH). The META injection arms only proved the pattern trips on
# `DESIGN_STORE=linear` (matching via the DESIGN_STORE alternative, not via
# anything sensitive to the bare lowercase value) and on `linear:CWP-123`
# and on capitalised `Linear` prose — none of the three shapes a bare
# lowercase `linear` actually takes in CODE (quoted comparison, unquoted
# assignment, case arm, flag value, pipe-alternation) were exercised at all,
# which is exactly why R1-F1's gap went unnoticed at review time: the arms
# tested what the pattern already covered, not what it was missing.
#
# THE FIX IS THREE INDEPENDENT SIGNALS, NOT ONE PATTERN, because no single
# `grep -E` expression can both (a) catch a bare lowercase `linear` used as
# a CODE token and (b) ignore a bare lowercase `linear` used as an English
# adjective, when the two are LOCALLY indistinguishable — `case ... in
# linear)` and `a linear scan` both present "linear" as a standalone token
# bounded by whitespace; the character immediately next to the word carries
# no reliable signal either way (the "flag value" shape, `--backend linear`,
# is followed by whitespace exactly like the English phrase "a linear
# scan" is). What DOES reliably separate them in this repository, measured
# rather than assumed (grep -ciE linear against the three real gate
# scripts, real BSD grep, see below): every existing English use of the
# bare lowercase word lives entirely inside a `#` comment, and every
# plausible CODE shape does not. So:
#
#   SIGNAL 1 — DESIGN_LINEAR_PATTERN='DESIGN_STORE|linear:' matched against
#     the FULL file, comment or code. Both are unambiguous literals with no
#     legitimate English-prose collision in this repository (verified below,
#     section A2/B) — a comment MENTIONING DESIGN_STORE or the `linear:`
#     ref-prefix is exactly as worth flagging as code using them, so there
#     is no reason to restrict this signal to code-only positions the way
#     signal 3 below has to be.
#
#   SIGNAL 2 (AS ROUND 1 SHIPPED IT — CHANGED IN ROUND 2, see "QA ROUND 2"
#     below) — Linear (capitalised), matched against the FULL file MINUS
#     lines where "Linear" is the very first word of a comment
#     (`^[[:space:]]*#+[[:space:]]*Linear\b` — sentence-initial
#     capitalisation, indistinguishable from proper-noun capitalisation by
#     grep alone, so excluded rather than guessed at). This kept catching
#     the shape this repo actually uses for the proper noun elsewhere
#     (design-artifact.test.sh:236 "The Linear adapter.",
#     subagent-start.sh:673 "Beads/Linear id" — note NEITHER of those is one
#     of the three files this guard scans; they are cited only to show the
#     shape is real somewhere in this repo), while no longer
#     false-positiving on prose that only happens to start a sentence with
#     a word that is also this product's name.
#
#     ROUND 1 then claimed this made the guard COMPLETE against Linear-
#     mention prose: "a comment alone does not wire behaviour; ... every
#     shape that constitutes actual wiring is still covered by signal 1 or
#     signal 3." THAT CLAIM WAS FALSE and is retracted in QA ROUND 2 below,
#     not merely reworded — a comment can be HEREDOC DATA a script reads
#     and acts on, so "a comment alone does not wire behaviour" does not
#     hold in general, and no amount of lexical narrowing fixes a claim
#     about program behaviour made from grepping source text. ROUND 2
#     REMOVED the sentence-initial exclusion entirely rather than trying to
#     patch the claim: see QA ROUND 2, "SIGNAL 2" below for the measurement
#     that justifies removal (not merely retraction of the completeness
#     sentence) for THIS signal specifically, as opposed to signal 3's
#     comment-stripping, which QA ROUND 2 measured and chose to KEEP.
#
#   SIGNAL 3 — a bare lowercase `linear`, as a standalone token (preceded by
#     start-of-line or a non-word-non-hyphen character, so it cannot fuse
#     into "non-linear"; followed by end-of-line or a non-word-non-hyphen
#     character), matched against the file with `#`-COMMENTS STRIPPED
#     FIRST. This is the R1-F1 fix. Stripping is what makes the boundary
#     check safe: without it, the boundary pattern alone still
#     false-positives on "a linear scan" (proven empirically below, section
#     B) because that phrase is ALSO a whitespace-delimited standalone
#     token — the same local shape as `case ... in linear)`. WITH comment
#     stripping, both of this repository's current benign lowercase
#     occurrences vanish before the boundary check ever sees them (both are
#     ENTIRELY inside `#` comments), while every code shape the finding and
#     this file's own header list — quoted (`"linear"`/`'linear'`), bare
#     assignment (`=linear`), pipe-alternation (`linear|`), flag value
#     (`--backend linear`), and the case arm itself (`linear)`) — survives
#     stripping untouched and still trips, because none of them is a
#     comment.
#
# THE COMMENT-STRIPPING HEURISTIC (`strip_line_comments` below): a `#` is
# treated as a comment start only when it is preceded by start-of-line or
# whitespace — the same convention idiomatic bash uses, and specifically
# chosen so a `#` glued to a preceding character is left alone: bash's own
# `${var#pattern}` / `${#array[@]}` operators use `#` immediately after a
# non-whitespace character and are NOT comments; the heuristic verifiably
# leaves them untouched (measured: `x=${store#linear}` is byte-identical
# before and after stripping). DISCLOSED LIMITATION, not hidden: this is a
# heuristic, not a shell tokenizer — a `#` inside a quoted STRING that
# happens to be preceded by whitespace (e.g. `echo "value #1 linear"`) is
# indistinguishable from a real comment by this rule and would be
# over-stripped too, silently losing whatever followed it on that line.
# Over-stripping only ever REMOVES a signal (a false NEGATIVE — the
# adversarial shape QA ROUND 2 (R2-F3) named, `target="x # linear"` losing
# its only lowercase evidence), never ADDS one (it cannot turn a clean line
# into a false positive). CORRECTION (QA ROUND 2, R2-F2): the sentence that
# used to stand here calling this "the fail-safe direction" had the
# polarity backwards. A false negative is FAIL-OPEN — the guard silently
# missing something — which is exactly the failure mode this whole file
# exists to avoid, not a safe direction to lean in. It is a DIFFERENT,
# narrower problem than R2-F2's fail-open bug (a tool that could not even
# RUN being misread as "found nothing," fixed separately below with a loud
# sentinel): this one is the stripping heuristic working exactly as
# designed and still losing information on an adversarial shape a real
# shell tokenizer would not. See QA ROUND 2 below, "SIGNAL 3 /
# comment-stripping," for why this file keeps the heuristic anyway
# (measured, not assumed) rather than removing it the way signal 2's
# sentence-initial exclusion was removed.
#
# THE ORIGINAL "why not a bare substring" REASONING BELOW STILL HOLDS AND IS
# UNCHANGED BY ANY OF THE ABOVE — it explains why signal 1/2 are not simply
# "grep -ci linear", which remains true regardless of the three-signal
# redesign.
#
# MEASURED against the real shipped files (this task's own reproduction,
# branch v5/design-phase, REAL /usr/bin/grep — BSD grep, GNU-compatible,
# 2.6.0-FreeBSD — not any interactive-shell grep wrapper; re-verify with
# `type grep` in a fresh `bash -c` before trusting a shell session's own
# `grep` for this measurement, the way round 1 of this fix had to):
#   $ grep -ciE linear .claude/scripts/qa-gate.sh            -> 2
#   $ grep -ciE linear .claude/scripts/verify-before-stop.sh -> 0
#   $ grep -ciE linear .claude/scripts/review-check.sh       -> 0
# The two qa-gate.sh hits are BOTH pre-existing, unrelated English prose that
# has nothing to do with the Linear design-store adapter:
#   qa-gate.sh:2329  "# two points are explicitly non-linear) -- citing a
#                      measurement is not the"
#   qa-gate.sh:2550  "    # a linear scan over at most a few dozen entries
#                      -- proportional to the"
# Neither line is reachable by this piece: D7 Piece D owns exactly this
# file, the sibling L2 spec, and the EXPECTED_SPEC_FILES array in
# run-tests.sh — qa-gate.sh belongs to a concurrent sibling piece and
# rewording its comments to dodge a grep pattern is out of scope (and would
# be the wrong fix regardless — the established discipline in this exact
# arc, mruw's reviewer-lane widening, is "preserve the information, drop the
# token" only when the token really is the hazard; these two comments are
# not the hazard, an imprecise pattern is). A bare `grep -ci linear` is
# therefore not merely imprecise, it is UNSHIPPABLE as this guard: it would
# read nonzero against the correct, Linear-adapter-free state of qa-gate.sh
# on the day this file is added, turning a permanently-green L1 tier red for
# a reason that has nothing to do with the invariant it claims to check —
# the same "measurement that never happened looks exactly like one that
# passed" family this whole task's own lineage (commit 261e09e, "four gate
# defects that each made a measurement that never happened look exactly like
# one that passed") exists to close, just approached from the opposite
# direction: a check that is falsely RED is exactly as dishonest as one that
# is falsely GREEN, because either way what it reports is not what it
# measured.
#
# =============================================================================
# QA ROUND 2 (independent, non-Claude review, sol-codex) — R2-F1 through
# R2-F4. Applies the operator's standing WAIVER RULING: "when a defect
# family survives repeated rounds against the same mechanism, remove the
# mechanism rather than guard it again." The mechanism being removed here
# is the COMPLETENESS CLAIM this file used to make, not the file itself —
# read "WHAT THIS FILE ACTUALLY IS" near the top first; this section is the
# fuller record of what changed and, for the two heuristics the ruling put
# in question, the measurement behind keeping one and dropping the other.
#
# R2-F1 (RELEASE-BLOCKING) — retracted the completeness claim. See "WHAT
# THIS FILE ACTUALLY IS" above. Nothing in the DETECTION PRIMITIVES or the
# assertions below claims coverage beyond "these three literal spellings,
# in these three files" from this round forward. The four META injection
# arms (section C) remain in the file: they are still real NON-VACUITY
# evidence that the three literal spellings, when present, ARE detected —
# that is a true and useful thing to show. What they no longer do, and are
# no longer labelled as doing, is stand in for a proof that no OTHER wiring
# shape exists. Two bypasses the reviewer supplied to make the point
# concrete (case-folding through `tr`, and `'lin''ear'` reassembled by
# shell quote removal) are deliberately NOT added as new arms: adding a
# fifth, sixth, twentieth lexical dodge is exactly the guard-it-again
# response the ruling forecloses — the reviewer's own point is that the
# list of dodges is unbounded, and a helper function outside the three
# scanned files defeats the whole mechanism without needing any dodge at
# all.
#
# R2-F2 (HIGH) — fail-open error handling, fixed. Every detector function
# below (strip_line_comments, linear_capitalised_hit_count,
# bare_lowercase_linear_code_count, count_design_linear_hits,
# count_design_linear_hits_text) now captures the exit status of every
# grep/sed it runs on its OWN line, immediately after the command
# substitution that produced it (`rc=$?`, nothing else on that line — a
# second statement first, including folding a `local` declaration into the
# same statement as the assignment, clobbers $? before it is read:
# `local x=$(cmd)` reads `local`'s own exit status, not `cmd`'s, which is
# exactly the mistake to avoid here — every function below declares its
# locals in a bare `local a b c` first and assigns via command substitution
# as a separate, later statement). On a real tool failure, four of these
# five -- linear_capitalised_hit_count, bare_lowercase_linear_code_count,
# count_design_linear_hits, count_design_linear_hits_text -- emit
# TOOL_FAILURE_SENTINEL on stdout and return nonzero. The fifth,
# strip_line_comments, is DIFFERENT (QA ROUND 3, R3-F1c corrects an earlier
# version of this paragraph, which wrongly listed it among the emitters
# too): on a sed failure it prints a diagnostic to stderr and returns 2 --
# see its own header below -- without ever putting the sentinel on stdout
# itself; its only caller, bare_lowercase_linear_code_count, is what
# TRANSLATES that nonzero return into TOOL_FAILURE_SENTINEL (see that
# function's own header). The BEHAVIOUR was always correct end-to-end; only
# this paragraph's account of which function does the emitting was wrong.
# Either way, on a real tool failure nothing downstream is meant to let an
# empty/partial result flow forward and get coerced to "0" the
# way `[ -z "$a" ] && a=0` used to. The sentinel is not "0", "1", "yes", or
# "no" — no value this file's assert_eq calls ever expect — so it always
# produces a visible, clearly-labelled FAILURE. This is deliberately NOT a
# top-level `exit`: every detector is reached through `$(...)` command
# substitution at its call sites, which forks a subshell, so a `return`
# inside the function cannot terminate the top-level script the way `exit`
# would need to (only the function's own exit STATUS, via `return`,
# reliably survives the subshell boundary — an `exit` inside one would only
# kill that subshell and the caller would see an empty captured string).
# Routing the failure through the existing FAILED_TESTS accounting is what
# actually works given that constraint, and it has the added benefit of
# not stopping the run before every other assertion has had a chance to
# report. Distinguishing a real tool failure from a legitimate "found
# nothing" result is grounded in measured exit-code behaviour, not assumed:
# BSD grep (this host) exits 1 for "ran fine, zero matches" and 2 for a
# real error (missing file, permission denied, a directory given without
# -r) — verified directly against all three cases before being encoded
# here — so the check used throughout is `rc -gt 1` for every grep call.
# BSD sed has no "legitimate nonzero" case at all in this file's usage: any
# `rc -ne 0` after `sed -E '...' "$file"` is a real failure (also verified
# directly: a missing/unreadable file produces rc=1 and no stdout, with the
# error on stderr; a real substitution against real content produces rc=0
# regardless of whether the pattern matched anything, because sed does not
# treat "pattern didn't match" as an error the way grep does).
#
# FAST-FOLLOW (this fix is a behavioural change and did not ship with a
# standing regression control the first time — flagged as a disclosed gap
# in the round-2 report rather than left silent, and closed immediately
# after): section E, near the end of this file, is a full four-part PAIR
# (.claude/tests/README.md "pairing requirement") for this exact fix —
# mutates a COPY back to the pre-fix shape, proves the mutation landed and
# nowhere else, drives the mutant and observes it silently report a clean
# count, then drives the REAL shipped function on the identical failing
# input and observes it correctly report the sentinel. Before section E
# existed, this fix's only evidence was a one-off manual demonstration in a
# review report — exactly the shape the pairing requirement forbids.
#
# R2-F3 (HIGH) — the two lexical heuristics, decided separately, each on
# its own measurement, per the operator's own framing ("if you believe
# stripping still earns its place on the narrowed tripwire terms, argue it
# with a measurement; otherwise delete it").
#
#   SIGNAL 3 / comment-stripping — KEPT. Removing it is not free the way
#   removing signal 2's exclusion (below) is: section B4 already proves the
#   bare-lowercase boundary pattern, UNSTRIPPED, false-positives on the
#   real, currently-shipped "a linear scan" comment in qa-gate.sh. Without
#   stripping, signal 3 would trip on that real, correct, Linear-adapter-
#   free line, and A1 would go permanently red against the correct shipped
#   state — the exact "falsely RED is exactly as dishonest as one that is
#   falsely GREEN" failure this file's own MEASURED section already argues
#   against for the naive pattern. The reviewer's dangerous-direction
#   concern is real but is about ACCURACY, not merely completeness, and is
#   MEASURED here rather than assumed either way:
#     $ grep -n ';#' .claude/scripts/qa-gate.sh \
#           .claude/scripts/verify-before-stop.sh \
#           .claude/scripts/review-check.sh
#       (zero hits — the "real comment not stripped because `#` follows `;`
#       not whitespace" shape the reviewer named does not occur in any of
#       the three files today)
#     $ grep -nE '"[^"]*[[:space:]]#[^"]*"' .claude/scripts/qa-gate.sh \
#           .claude/scripts/verify-before-stop.sh \
#           .claude/scripts/review-check.sh
#       qa-gate.sh:8829            "bash .claude/scripts/impact-report.sh
#                                    --hash-only   # diagnose directly"
#       verify-before-stop.sh:1211 DOC_VETO_REASON="the file begins with a
#                                    #! shebang"
#       (the quoted-string-containing-a-hash shape the reviewer named for
#       the DANGEROUS direction is not hypothetical — these two real lines
#       already have it — but NEITHER contains "linear" on either side of
#       the embedded `#`, so stripping does not destroy any real evidence
#       in either file today. This is a disclosed, MEASURED-CURRENTLY-
#       ABSENT gap, not a closed one: if either string, or a new one like
#       them, ever grows a `linear` substring after an embedded `#`,
#       stripping would silently lose it, and only re-running these two
#       greps would catch that this measurement had gone stale. Recorded
#       here so it stays checkable, the same discipline the file's own
#       MEASURED section already uses for the two benign real lines.)
#   The false-positive shape the reviewer also named
#   (`store=$1;# linear backend` — a real comment not stripped) is
#   confirmed absent above too, and in any case is the SAFE-direction
#   failure for a tripwire (an extra flag, read by a human), not the
#   dangerous one.
#
#   SIGNAL 2 / sentence-initial exclusion — REMOVED, not merely narrowed.
#   Unlike signal 3's stripping, this heuristic is NOT load-bearing against
#   any real content in the three scanned files: measured (this round),
#   `grep -nE 'Linear' qa-gate.sh verify-before-stop.sh review-check.sh`
#   returns ZERO hits, full stop — not "zero sentence-initial hits," zero
#   hits of any kind. The exclusion's only effect today was on the
#   SYNTHETIC probe in section B3, never on any real line, so removing it
#   costs nothing measured. What it bought was real, though bounded to
#   B3's synthetic shape: the reviewer's point that `# Linear` could be the
#   first line of a HEREDOC whose body is real wiring data is a live
#   structural risk in these specific files, not a hypothetical one — all
#   three use heredocs heavily (22 / 7 / 6 occurrences respectively,
#   `grep -cE '<<[-~]?'`), so a mechanism that suppresses a signal based on
#   a line merely LOOKING like sentence-initial prose is exactly the kind
#   of guess this file's own header already warns against elsewhere
#   ("indistinguishable from proper-noun capitalisation by grep alone, so
#   excluded rather than guessed at" — round 1 excluded rather than
#   guessed at whether it was prose, but excluding IS the guess). Section
#   B3 below is updated to match: it now asserts the synthetic
#   sentence-initial line DOES trip signal 2, and documents that this is
#   an accepted, intentional false alarm, not a regression.
#
# R2-F4 (MEDIUM) — assertion labels corrected to say only what they check;
# see each assertion at the call sites below (sections A1, C, D). The
# pattern in every case is the one this release has now named multiple
# times before this file: a label claiming a broader property than the
# single value being compared actually proves.
# `count_design_linear_hits_text` (used only in section D, for captured
# RUNTIME output) still deliberately omits signal 3 / bare-lowercase — see
# that function's own comment for why free-form program output has no
# comment/code distinction for stripping to exploit — so the three
# EXECUTION labels that used to say a runtime capture has "zero
# Linear-design-store references" now say what is actually checked: no
# occurrence of the two literal-spelling signals this text detector runs,
# not "no Linear reference of any kind."
#
# CONSEQUENCE OUTSIDE THIS FILE, NOT FIXED HERE (out of this piece's
# ownership — .claude/scripts/tests/design-structural.test.sh and one
# status-capture line in the L2 sibling only): docs/RELEASE_AUDIT.md's
# DP17 evidence line, if it cites this spec as proving the gate scripts are
# Linear-free, now overclaims the same way this file's own header used to
# and needs the same retraction. Flagged in this task's completion contract
# for the orchestrator to route; not edited here because it is outside this
# piece's file ownership for this task.
#
# PAIRING (.claude/tests/README.md, "The pairing requirement"):
#   1 NON-VACUITY   section C: each injection is asserted to have LANDED in
#                   its copy before anything is concluded from it.
#   2 MISBEHAVIOUR  section C: the SAME canonical detector (count_design_
#                   linear_hits) production code calls trips (nonzero) on
#                   each injected copy, naming the "tripwire: ... contains
#                   none of the three tracked literal spellings" assertion
#                   it would fail.
#   3 RESTORE       section A1: the detector reads 0 against the REAL
#                   shipped files.
#   4 EXECUTION     section D: each shipped script is actually RUN in its
#                   cheapest side-effect-free, bd-independent invocation, and
#                   a text-appropriate subset of the same detector is run
#                   over the CAPTURED RUNTIME OUTPUT — a source clean of the
#                   token could still print it at runtime (a concatenated
#                   string, a sourced constant, an env-derived message);
#                   this is what actually observes the shipped artifact
#                   RUNNING clean, not merely sitting clean on disk. Same
#                   three invocations reviewer-lane-structural.test.sh
#                   already established as empirically side-effect-free and
#                   bd-free (re-verified here directly, not merely
#                   inherited): qa-gate.sh / review-check.sh with no args ->
#                   usage() to stderr, exit 1; verify-before-stop.sh fed
#                   `stop_hook_active:true` -> the AgentLint H3 circuit
#                   breaker, `{}`, exit 0.
#   Section B is an ADDITIONAL set of legs beyond the four above: it proves
#   the chosen detector's PRECISION (reads 0 on the two known benign real
#   occurrences, a signal-3 concern -- B4) against a NAMED naive alternative
#   that fails that same precision test, and it proves WHICH mechanism
#   (hyphen-exclusion vs comment-stripping) defeats WHICH benign line,
#   rather than asserting the combined result and leaving the reader to
#   guess. Section B also carries the ONE case where the chosen detector is
#   intentionally NOT precise (QA ROUND 3, R3-F3 corrects this summary,
#   stale since R2-F3): under signal 2, the synthetic sentence-initial-
#   Linear probe now deliberately reads 1, not 0 -- B3, an accepted false
#   alarm since R2-F3 removed the exclusion that used to suppress it, not a
#   precision result. Grounded in the real
#   shipped lines (content-matched, never line-number-matched, so this
#   stays correct even if qa-gate.sh's line numbers drift under unrelated
#   future edits; only a removal of the phrases themselves would invalidate
#   section B's premise, and section A2 below would then fail loudly rather
#   than silently asserting a stale claim).
#
#   Section E is a SEPARATE pair, added as a QA ROUND 2 fast-follow, for a
#   DIFFERENT claim: not "which literal spellings are detected" (A-D's
#   subject) but "does a real tool failure get reported loudly instead of
#   as a clean count" (R2-F2's fix). It meets the same four-part standard
#   on its own terms — see section E's own header for the mapping — and
#   is not folded into A-D's accounting above because it is pairing a
#   different mechanism, not repeating this one.
#
# Offline. No bd dependency anywhere in this file — the L1 store canary in
# run-tests.sh cannot fire on a spec that never calls bd — and no fixture
# scaffolding: pure greps/sed, file copies under a plain mktemp scratch dir,
# and three cheap script invocations. Well under a second.
#
# Exit codes: 0 all pass / 1 any fail (including a detector tool failure —
# see TOOL_FAILURE_SENTINEL below; it surfaces as a normal, clearly-labelled
# FAIL, not a distinct exit code) / 2 invocation error (missing script)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SCRIPTS_DIR="$PROJECT_DIR/.claude/scripts"
QAGATE="$SCRIPTS_DIR/qa-gate.sh"
VBS="$SCRIPTS_DIR/verify-before-stop.sh"
RCHECK="$SCRIPTS_DIR/review-check.sh"

# =============================================================================
# DETECTION PRIMITIVES. THE canonical mechanism every "does the shipped
# state contain any of the tracked literal spellings" assertion in this
# file calls — never a re-typed literal or a one-off grep — so there is
# exactly one place to refine again if a future spelling or shape needs
# adding. See the header above for the full derivation, and "QA ROUND 2"
# for why this is a TRIPWIRE (three literal spellings, three files) rather
# than a completeness proof of anything about program BEHAVIOUR.

# TOOL_FAILURE_SENTINEL -- what every detector function below emits on its
# stdout (in place of a numeric count) when the grep/sed it depends on
# failed to run at all, as opposed to running cleanly and finding zero
# matches (the ordinary, common, expected "clean" result for most files
# this tripwire scans). R2-F2 (independent review round 2, HIGH): before
# this fix, every such tool failure was swallowed by `2>/dev/null || true`
# and the resulting empty string was then coerced to "0" at the call site —
# indistinguishable from a genuinely clean file, so a broken detector and a
# clean one produced the identical, silently-passing assertion. This
# sentinel makes that impossible: it is not "0", "1", "yes", "no", or any
# other string this file's assert_eq calls ever expect, so a tool failure
# always surfaces as a clearly-labelled FAILURE in the normal FAILED_TESTS
# summary — loud, never a clean count.
TOOL_FAILURE_SENTINEL='ERROR:TOOL-FAILURE'

# The one UNAMBIGUOUS literal signal that is safe to search across the FULL
# file, comment or code — no legitimate English-prose collision anywhere in
# this repository (verified: `grep -rni design_store .` outside this
# comment and the plan doc finds nothing; `linear:` colon-suffixed is
# specifically the `--external-ref linear:<issue-id>` form and does not
# occur as English prose).
DESIGN_LINEAR_PATTERN='DESIGN_STORE|linear:'

# Bare lowercase "linear" as a standalone token: not fused into a longer
# identifier or compound word (the preceding/following character may not be
# alphanumeric, underscore, or hyphen — the hyphen exclusion is what keeps
# "non-linear" safe even WITHOUT comment-stripping, proven separately in
# section B). Only ever run against comment-stripped content — see
# bare_lowercase_linear_code_count below and the header's SIGNAL 3.
DESIGN_LINEAR_BARE_CODE_PATTERN='(^|[^A-Za-z0-9_-])linear($|[^A-Za-z0-9_-])'

# The NAIVE pattern — a literal reading of the plan's "zero `linear`
# references" phrasing — kept ONLY for section B's precision demonstration
# of why it is not what this file uses. Never used to judge real files.
DESIGN_LINEAR_PATTERN_NAIVE='linear'

# strip_line_comments <file> -- see header for the full heuristic and its
# disclosed limitation. A '#' is a comment start only when preceded by
# start-of-line or whitespace; `${var#pattern}` / `${#arr[@]}` style
# operators (# glued to a preceding non-whitespace character) are left
# untouched. R2-F2: on a real sed failure (unreadable file, etc.) prints a
# loud diagnostic to stderr and returns 2 instead of silently emitting
# whatever partial/empty output sed produced, which a downstream grep would
# otherwise happily count as "zero hits".
strip_line_comments() {
    local file="$1" out rc
    out=$(sed -E 's/(^|[[:space:]])#.*$/\1/' "$file" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'design-structural.test: strip_line_comments: sed failed (rc=%s) reading %s\n' "$rc" "$file" >&2
        return 2
    fi
    printf '%s\n' "$out"
    return 0
}

# linear_capitalised_hit_count <file> -- SIGNAL 2: lines containing bare
# "Linear". R2-F3 (independent review round 2): the sentence-initial
# exclusion this used to carry is REMOVED here, not narrowed — measured
# (file header, QA ROUND 2) that no real line in any of the three scanned
# files needs it (zero capitalised "Linear" occurrences at all, sentence-
# initial or otherwise, in qa-gate.sh / verify-before-stop.sh /
# review-check.sh today), while the exclusion's own failure mode the
# reviewer named (`# Linear` as the first line of a HEREDOC whose body is
# real wiring data) is a live risk in these files: all three use heredocs
# heavily. A tripwire that occasionally flags a sentence-initial "Linear"
# comment as a false alarm is the accepted, safe direction; a human reads
# it (see section B3 below).
linear_capitalised_hit_count() {
    local file="$1" cnt rc
    cnt=$(grep -cE 'Linear' "$file" 2>/dev/null)
    rc=$?
    if [ "$rc" -gt 1 ]; then
        printf 'design-structural.test: linear_capitalised_hit_count: grep failed (rc=%s) on %s\n' "$rc" "$file" >&2
        printf '%s\n' "$TOOL_FAILURE_SENTINEL"
        return 2
    fi
    [ -z "$cnt" ] && cnt=0
    printf '%s\n' "$cnt"
    return 0
}

# bare_lowercase_linear_code_count <file> -- SIGNAL 3: comment-stripped
# content, bare lowercase "linear" as a standalone token. This is the R1-F1
# fix: catches quoted comparisons, bare assignments, pipe-alternations, flag
# values, and case arms (the exact bypass shape the review cited), while
# never seeing the two benign real comment-only prose lines because both
# are ENTIRELY comments and vanish under stripping. R2-F2: propagates a
# strip_line_comments or grep failure as TOOL_FAILURE_SENTINEL instead of
# letting it read as a clean zero.
bare_lowercase_linear_code_count() {
    local file="$1" stripped rc cnt
    stripped=$(strip_line_comments "$file")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$TOOL_FAILURE_SENTINEL"
        return 2
    fi
    cnt=$(printf '%s\n' "$stripped" | grep -cE "$DESIGN_LINEAR_BARE_CODE_PATTERN")
    rc=$?
    if [ "$rc" -gt 1 ]; then
        printf 'design-structural.test: bare_lowercase_linear_code_count: grep failed (rc=%s) on stripped %s\n' "$rc" "$file" >&2
        printf '%s\n' "$TOOL_FAILURE_SENTINEL"
        return 2
    fi
    printf '%s\n' "$cnt"
    return 0
}

# count_design_linear_hits <file> -- the canonical SOURCE detector: all
# three signals, summed. Used for real shell source (the three gate
# scripts, and the mutated copies section C builds from them) — source has
# a real, exploitable comment/code distinction. R2-F2: every sub-count
# captures $? on its own line immediately after the command substitution
# that produces it (a second statement on the same line, including a
# `local` prefix, clobbers $? before it is read). A sub-detector failure
# propagates as TOOL_FAILURE_SENTINEL rather than being silently coerced to
# 0 by an `[ -z ... ]` guard the way it used to be.
count_design_linear_hits() {
    local file="$1" a b c rc

    a=$(grep -cE "$DESIGN_LINEAR_PATTERN" "$file" 2>/dev/null)
    rc=$?
    if [ "$rc" -gt 1 ]; then
        printf 'design-structural.test: count_design_linear_hits: signal 1 grep failed (rc=%s) on %s\n' "$rc" "$file" >&2
        printf '%s\n' "$TOOL_FAILURE_SENTINEL"
        return 2
    fi
    [ -z "$a" ] && a=0

    b=$(linear_capitalised_hit_count "$file")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$TOOL_FAILURE_SENTINEL"
        return 2
    fi

    c=$(bare_lowercase_linear_code_count "$file")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$TOOL_FAILURE_SENTINEL"
        return 2
    fi

    echo $((a + b + c))
    return 0
}

# count_design_linear_hits_text <file> -- the canonical TEXT detector, for
# captured RUNTIME OUTPUT (section D): signals 1+2 only, deliberately
# WITHOUT signal 3. Free-form program output has no comment/code
# distinction for strip_line_comments to exploit — a bare '#' in help text
# (measured below: qa-gate.sh's own usage() text contains one, "decision #3
# of the fkm.7 D5 brief") is not a shell comment, and applying the
# source-only heuristic to it would be a category error, not an extra
# safety margin. Measured (real grep, section D below): none of the three
# captured runtime outputs contain the word "linear" in any case today, so
# this is not a live gap, only a documented scope boundary — and the
# assertions that use this detector are labelled accordingly (R2-F4): they
# claim only "none of the tracked DESIGN_STORE/Linear/linear: spellings",
# never "zero Linear references" in general.
count_design_linear_hits_text() {
    local file="$1" a b rc

    a=$(grep -cE "$DESIGN_LINEAR_PATTERN" "$file" 2>/dev/null)
    rc=$?
    if [ "$rc" -gt 1 ]; then
        printf 'design-structural.test: count_design_linear_hits_text: signal 1 grep failed (rc=%s) on %s\n' "$rc" "$file" >&2
        printf '%s\n' "$TOOL_FAILURE_SENTINEL"
        return 2
    fi
    [ -z "$a" ] && a=0

    b=$(linear_capitalised_hit_count "$file")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$TOOL_FAILURE_SENTINEL"
        return 2
    fi

    echo $((a + b))
    return 0
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

for f in "$QAGATE" "$VBS" "$RCHECK"; do
    if [ ! -f "$f" ]; then
        printf 'design-structural.test: script under test missing: %s\n' "$f" >&2
        exit 2
    fi
done

WORK=$(mktemp -d -t design-structural.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

GATE_SCRIPTS="qa-gate.sh verify-before-stop.sh review-check.sh"

# ---------------------------------------------------------------------------
# A1. STRUCTURAL (RESTORE control, leg 3): the three gate-critical scripts
# are clean under the canonical source detector, as shipped. R2-F1: this is
# a TRIPWIRE assertion, not a completeness proof — see "WHAT THIS FILE
# ACTUALLY IS" in the file header.
for f in $GATE_SCRIPTS; do
    CNT=$(count_design_linear_hits "$SCRIPTS_DIR/$f")
    assert_eq "tripwire: $f contains none of the three tracked literal spellings (not a completeness proof — see QA ROUND 2 in the file header)" "0" "$CNT"
done

# ---------------------------------------------------------------------------
# A2. GROUNDING for section B: the reason a naive pattern is unusable is not
# hypothetical. Prove the two benign occurrences this header cites are still
# really there, by CONTENT (never by line number, so unrelated future edits
# to qa-gate.sh cannot silently invalidate section B's premise — a removal
# would fail this loudly instead).
NONLINEAR_CNT=$(grep -cF 'non-linear' "$QAGATE" 2>/dev/null || true)
[ -z "$NONLINEAR_CNT" ] && NONLINEAR_CNT=0
assert_eq "grounding: qa-gate.sh still contains the benign phrase 'non-linear'" \
    "yes" "$([ "$NONLINEAR_CNT" -ge 1 ] && echo yes || echo no)"

LINEARSCAN_CNT=$(grep -cF 'linear scan' "$QAGATE" 2>/dev/null || true)
[ -z "$LINEARSCAN_CNT" ] && LINEARSCAN_CNT=0
assert_eq "grounding: qa-gate.sh still contains the benign phrase 'linear scan'" \
    "yes" "$([ "$LINEARSCAN_CNT" -ge 1 ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# B. PRECISION (why the chosen detector, not the naive pattern, and why it
# needed THREE signals rather than one). Tested against the ACTUAL shipped
# lines, extracted by content, not by line number, plus one SYNTHETIC probe
# line (clearly labelled as such) for the sentence-initial-Linear shape that
# does not exist in any real shipped file today.
NONLINEAR_LINE=$(grep -F 'non-linear' "$QAGATE" 2>/dev/null | head -1)
LINEARSCAN_LINE=$(grep -F 'linear scan' "$QAGATE" 2>/dev/null | head -1)
printf '%s\n' "$NONLINEAR_LINE" > "$WORK/b.nonlinear.txt"
printf '%s\n' "$LINEARSCAN_LINE" > "$WORK/b.linearscan.txt"

# B1. BEFORE: the naive case-insensitive bare "linear" substring cannot tell
# "non-linear" / "linear scan" apart from a genuine Linear-adapter
# reference.
NAIVE_ON_NONLINEAR=$(grep -ciE "$DESIGN_LINEAR_PATTERN_NAIVE" "$WORK/b.nonlinear.txt" 2>/dev/null || true)
[ -z "$NAIVE_ON_NONLINEAR" ] && NAIVE_ON_NONLINEAR=0
assert_eq "precision (BEFORE): the naive bare 'linear' pattern false-positives on the real 'non-linear' line" \
    "yes" "$([ "$NAIVE_ON_NONLINEAR" -gt 0 ] && echo yes || echo no)"

NAIVE_ON_LINEARSCAN=$(grep -ciE "$DESIGN_LINEAR_PATTERN_NAIVE" "$WORK/b.linearscan.txt" 2>/dev/null || true)
[ -z "$NAIVE_ON_LINEARSCAN" ] && NAIVE_ON_LINEARSCAN=0
assert_eq "precision (BEFORE): the naive bare 'linear' pattern false-positives on the real 'linear scan' line" \
    "yes" "$([ "$NAIVE_ON_LINEARSCAN" -gt 0 ] && echo yes || echo no)"

# B2. AFTER: the CHOSEN detector (the same count_design_linear_hits every
# real assertion in this file calls, not a hand-rolled stand-in) does NOT
# false-positive on either real benign line.
CHOSEN_ON_NONLINEAR=$(count_design_linear_hits "$WORK/b.nonlinear.txt")
assert_eq "precision (AFTER): the chosen detector does NOT false-positive on the real 'non-linear' line" \
    "0" "$CHOSEN_ON_NONLINEAR"

CHOSEN_ON_LINEARSCAN=$(count_design_linear_hits "$WORK/b.linearscan.txt")
assert_eq "precision (AFTER): the chosen detector does NOT false-positive on the real 'linear scan' line" \
    "0" "$CHOSEN_ON_LINEARSCAN"

# B3. TRIPWIRE FALSE-ALARM (R1-F1 established this shape as a risk; R2-F3
# removed the sentence-initial exclusion that used to suppress it here —
# see "QA ROUND 2" in the file header for why). A SYNTHETIC probe line, not
# drawn from any real shipped file (unlike B1/B2 above): capitalised
# "Linear" as the first word of a comment. THIS NOW TRIPS THE TRIPWIRE, ON
# PURPOSE: a false alarm on prose is the accepted, safe-direction cost of
# dropping a heuristic (the sentence-initial exclusion) whose own failure
# mode — silently excluding a HEREDOC's first line, which real wiring can
# read as data — was judged worse. Measured (file header, QA ROUND 2): none
# of the three scanned files contain ANY capitalised "Linear" today,
# sentence-initial or otherwise, so this change trips nothing real; it only
# changes what a FUTURE sentence-initial "Linear" comment would do, from
# "silently ignored" to "flagged for a human to read".
SENTENCE_INITIAL_LINEAR='# Linear scans over this small list are acceptable.'
printf '%s\n' "$SENTENCE_INITIAL_LINEAR" > "$WORK/b.sentence-initial.txt"
SENTENCE_INITIAL_CNT=$(count_design_linear_hits "$WORK/b.sentence-initial.txt")
assert_eq "tripwire (intentional false alarm, R2-F3): synthetic sentence-initial 'Linear' prose DOES trip the tripwire now that the sentence-initial exclusion is removed ('# Linear scans over this small list are acceptable.')" \
    "1" "$SENTENCE_INITIAL_CNT"

# B4. MECHANISM PROOF: which of the two safeguards (hyphen-exclusion vs
# comment-stripping) defeats which benign line — shown, not merely claimed.
# The boundary pattern ALONE (no stripping) still false-positives on
# "linear scan" (proving stripping is load-bearing for THIS line, not
# decorative); the hyphen exclusion alone is sufficient for "non-linear"
# even without any stripping at all.
BOUNDARY_ONLY_ON_LINEARSCAN=$(grep -cE "$DESIGN_LINEAR_BARE_CODE_PATTERN" "$WORK/b.linearscan.txt" 2>/dev/null || true)
[ -z "$BOUNDARY_ONLY_ON_LINEARSCAN" ] && BOUNDARY_ONLY_ON_LINEARSCAN=0
assert_eq "mechanism proof: the boundary pattern ALONE (no comment-stripping) DOES false-positive on 'linear scan' -- proving comment-stripping is load-bearing for signal 3, not decorative" \
    "yes" "$([ "$BOUNDARY_ONLY_ON_LINEARSCAN" -gt 0 ] && echo yes || echo no)"

# QA ROUND 3, R3-F1b: NOT `2>/dev/null || true` swallowed straight to a
# coerced "0" -- that shape makes a genuine tool failure (grep couldn't run,
# rc>1) indistinguishable from a genuine clean result (grep ran fine, found
# nothing, rc=1), because both produce empty stdout. This is a
# ZERO-EXPECTED check, so that collision is dangerous here (unlike the
# POSITIVE-expected `|| true` probes elsewhere in this file, which already
# fail closed on a tool failure): capture the real exit status and route a
# genuine failure (rc>1, BSD grep convention, see file header) to the same
# sentinel the DETECTION PRIMITIVES use, so it reads as a loud FAIL here too
# instead of a silent, wrong PASS.
BOUNDARY_ONLY_ON_NONLINEAR=$(grep -cE "$DESIGN_LINEAR_BARE_CODE_PATTERN" "$WORK/b.nonlinear.txt" 2>/dev/null)
BOUNDARY_NONLINEAR_RC=$?
if [ "$BOUNDARY_NONLINEAR_RC" -gt 1 ]; then
    BOUNDARY_ONLY_ON_NONLINEAR="$TOOL_FAILURE_SENTINEL"
else
    [ -z "$BOUNDARY_ONLY_ON_NONLINEAR" ] && BOUNDARY_ONLY_ON_NONLINEAR=0
fi
assert_eq "mechanism proof: the boundary pattern ALONE (no comment-stripping) does NOT false-positive on 'non-linear' -- the hyphen exclusion alone is sufficient for this benign line" \
    "0" "$BOUNDARY_ONLY_ON_NONLINEAR"

# ---------------------------------------------------------------------------
# C. META injection (legs 1+2, NON-VACUITY + MISBEHAVIOUR): inject a bare
# `linear` token (or the R1-F1 bypass shape itself) into a COPY of a gate
# script — independently realistic shapes, run through the SAME canonical
# detector (count_design_linear_hits) production code calls, so a gap
# between "what the meta arms test" and "what the real check does" (R1-F2's
# root cause) cannot recur silently. "Bare" token: in every shape below
# "linear" appears as its own delimited token (after "=", after ":", inside
# quotes, as a case-arm pattern, or as a capitalised standalone word) —
# never fused into a longer word the way it is in the two benign
# occurrences section B is about. Copy paths are qualified by BOTH file and
# label so two arms can safely target the same source script without
# clobbering each other's copy. R2-F1: these arms are NON-VACUITY evidence
# that the tracked spellings are detected when present — not, and never
# labelled as, proof that no other wiring shape exists (see the file
# header).
inject_and_check() {
    local file="$1" label="$2" line="$3"
    local copy="$WORK/${file}.${label}.injected"
    cp "$SCRIPTS_DIR/$file" "$copy"
    printf '\n%s\n' "$line" >> "$copy"

    local landed
    landed=$(grep -cF "$line" "$copy" 2>/dev/null || true)
    [ -z "$landed" ] && landed=0
    assert_eq "META non-vacuity: $file / $label injection landed in the copy" "1" "$landed"

    local tripped tripped_status
    tripped=$(count_design_linear_hits "$copy")
    # QA ROUND 3, R3-F1a: this used to be `[ "$tripped" != "0" ] && echo
    # yes`, which treated ANY non-"0" string as proof of detection --
    # including TOOL_FAILURE_SENTINEL, which is also != "0". A broken grep
    # would satisfy this arm exactly as well as a genuine detection would,
    # directly contradicting the header's claim (QA ROUND 2, R2-F1) that
    # these arms are real NON-VACUITY evidence the tracked spellings ARE
    # detected. Require a genuine positive count instead, and route the
    # sentinel to an explicit, LOUD failure -- the same way A1's plain
    # `assert_eq ... "0" "$CNT"` already fails loudly (raw value visible)
    # rather than through a yes/no boolean that would launder it.
    case "$tripped" in
        "$TOOL_FAILURE_SENTINEL") tripped_status="$tripped" ;;
        0) tripped_status="0" ;;
        *) tripped_status="positive" ;;
    esac
    assert_eq "META misbehaviour: $file / $label -- the 'tripwire: ... contains none of the three tracked literal spellings' assertion would now FAIL against a genuine positive count (QA ROUND 3, R3-F1a: a tool failure must FAIL this arm too, not be coerced into passing it)" \
        "positive" "$tripped_status"
}

inject_and_check "qa-gate.sh" "env-assignment" \
    '# selector: DESIGN_STORE=linear (deliberate injection for the META test)'
inject_and_check "verify-before-stop.sh" "external-ref-colon" \
    '  --external-ref linear:CWP-123 (deliberate injection for the META test)'
inject_and_check "review-check.sh" "capitalised-prose" \
    '# Out of scope: the Linear adapter (deliberate injection for the META test).'

# R1-F1 / R1-F2 (independent review round 1): the FOURTH arm this round
# adds. CODE-SHAPED (not a comment) and BARE LOWERCASE — the exact gap the
# first three arms left open, and the reviewer's own exact bypass snippet
# (docs/plans/v5-design-phase-plan.md:519's `linear:<issue-id>` external-ref
# format, prefix-stripped and switched on), condensed to one line with
# every token preserved verbatim so this is the real bypass, not a
# paraphrase of it. THIS IS THE ACCEPTANCE CRITERION FOR THIS ROUND: before
# this fix, this exact injection landed but did NOT trip the (then
# single-pattern) detector; it must trip now.
# Deliberately single-quoted: this is literal TEXT being appended to a copy
# for grep purposes, not code to be executed in THIS script, so $store /
# ${external_ref%%:*} must NOT expand here.
# shellcheck disable=SC2016
inject_and_check "qa-gate.sh" "bare-case-arm-R1-F1-bypass" \
    'store="${external_ref%%:*}"; case "$store" in linear) resolve_design_artifact "$external_ref" ;; esac'

# ---------------------------------------------------------------------------
# D. EXECUTION (leg 4): drive the ACTUAL shipped scripts running, in their
# cheapest side-effect-free, bd-independent invocation, and check the
# CAPTURED RUNTIME OUTPUT with the TEXT detector (signals 1+2 — see
# count_design_linear_hits_text's own header for why signal 3 does not
# apply to free-form output) — proving the running artifact is clean, not
# only its bytes at rest. Each invocation and its exit code was
# re-verified empirically before this file was written (same three
# invocations reviewer-lane-structural.test.sh already established as
# side-effect-free and bd-free; see that file's own section C header for the
# fuller caveat on verify-before-stop.sh's unconditional
# `mkdir -p "$QA_TRACKING_DIR"`, unaffected here for the identical reason).
#
# R1-F4 (independent review round 1): the exit-1 checks below used to be
# the ONLY assertion on each usage() invocation — a replacement script
# containing nothing but `exit 1` would have passed both. Strengthened to
# also require recognisable Usage: text, matching the standard the
# verify-before-stop.sh leg already met (exit code AND exact output).
# R2-F4 (independent review round 2): the exit-code assertions below are
# now labelled for exactly what they check (an exit code), not for the
# broader "runs its real usage() path" claim that only the PAIR of
# assertions (exit code + recognisable text) actually establishes.
QAGATE_OUT="$WORK/qa-gate-noarg.out"
qa_gate_rc=0
bash "$QAGATE" >"$QAGATE_OUT" 2>&1 || qa_gate_rc=$?
assert_eq "execution: qa-gate.sh with no args exits 1" "1" "$qa_gate_rc"
QAGATE_USAGE_CNT=$(grep -cF 'Usage: qa-gate.sh' "$QAGATE_OUT" 2>/dev/null || true)
[ -z "$QAGATE_USAGE_CNT" ] && QAGATE_USAGE_CNT=0
assert_eq "execution: qa-gate.sh's no-args output contains recognisable Usage text (not merely a bare exit 1) -- together with the exit-code assertion above, this establishes it is really the usage() path" \
    "yes" "$([ "$QAGATE_USAGE_CNT" -ge 1 ] && echo yes || echo no)"
QAGATE_OUT_CNT=$(count_design_linear_hits_text "$QAGATE_OUT")
assert_eq "execution: qa-gate.sh's RUNTIME usage output contains none of the tracked DESIGN_STORE/Linear/linear: literal spellings (bare-lowercase 'linear' is not checked in free-form text -- see count_design_linear_hits_text's own header)" "0" "$QAGATE_OUT_CNT"

RCHECK_OUT="$WORK/review-check-noarg.out"
rcheck_rc=0
bash "$RCHECK" >"$RCHECK_OUT" 2>&1 || rcheck_rc=$?
assert_eq "execution: review-check.sh with no args exits 1" "1" "$rcheck_rc"
RCHECK_USAGE_CNT=$(grep -cF 'Usage: review-check.sh' "$RCHECK_OUT" 2>/dev/null || true)
[ -z "$RCHECK_USAGE_CNT" ] && RCHECK_USAGE_CNT=0
assert_eq "execution: review-check.sh's no-args output contains recognisable Usage text (not merely a bare exit 1) -- together with the exit-code assertion above, this establishes it is really the usage() path" \
    "yes" "$([ "$RCHECK_USAGE_CNT" -ge 1 ] && echo yes || echo no)"
RCHECK_OUT_CNT=$(count_design_linear_hits_text "$RCHECK_OUT")
assert_eq "execution: review-check.sh's RUNTIME usage output contains none of the tracked DESIGN_STORE/Linear/linear: literal spellings (bare-lowercase 'linear' is not checked in free-form text -- see count_design_linear_hits_text's own header)" "0" "$RCHECK_OUT_CNT"

VBS_OUT="$WORK/vbs-circuit.out"
vbs_rc=0
printf '{"stop_hook_active": true}\n' | bash "$VBS" >"$VBS_OUT" 2>&1 || vbs_rc=$?
assert_eq "execution: verify-before-stop.sh with stop_hook_active=true exits 0" "0" "$vbs_rc"
assert_eq "execution: verify-before-stop.sh's circuit-breaker output is exactly {} -- together with the exit-code assertion above, this establishes it is really the AgentLint H3 circuit-breaker path" "{}" "$(cat "$VBS_OUT" 2>/dev/null)"
VBS_OUT_CNT=$(count_design_linear_hits_text "$VBS_OUT")
assert_eq "execution: verify-before-stop.sh's RUNTIME circuit-breaker output contains none of the tracked DESIGN_STORE/Linear/linear: literal spellings (bare-lowercase 'linear' is not checked in free-form text -- see count_design_linear_hits_text's own header)" "0" "$VBS_OUT_CNT"

# ---------------------------------------------------------------------------
# E. ERROR-HANDLING REGRESSION PIN (R2-F2 pairing leg, added as a fast-follow
# to QA ROUND 2). The fail-open fix in the DETECTION PRIMITIVES above IS a
# behavioural change, and until this section its only evidence was a set of
# one-off manual demonstrations in a review report -- exactly the shape
# .claude/tests/README.md's pairing requirement forbids: "a check whose
# negative control lives in a transcript rather than in the suite." This
# section guards the ERROR HANDLING (how a tool failure is reported), not
# the literal-spelling pattern (which spellings are detected) -- QA ROUND
# 2's waiver ruling ("do not guard the same mechanism again") retracted a
# claim about the SECOND of those, and does not apply to the first.
#
# Follows the same four-part standard section C's inject_and_check already
# meets (.claude/tests/README.md "pairing requirement"):
#   1 NON-VACUITY      the sed mutation is proven to have landed in the
#                       copy (and ONLY the copy -- the real running file is
#                       checked clean of it too).
#   2 MISBEHAVIOUR      the mutant is driven and asserted to reproduce
#                       EXACTLY the defect this leg exists to catch -- a
#                       clean "0" where TOOL_FAILURE_SENTINEL is owed --
#                       not merely "the mutant differs from the original".
#   3 RESTORE CONTROL   the REAL, currently-shipped function (already
#                       defined above in this same process -- no
#                       re-sourcing needed), same input, same call shape,
#                       still returns the sentinel.
#   4 EXECUTION         both the mutant's and the real function's code
#                       actually RUN against a genuinely failing input --
#                       this is not a byte comparison.
#
# TARGET: linear_capitalised_hit_count (SIGNAL 2), chosen over the two
# composite detectors deliberately, and the reason is itself a finding worth
# recording: a single-line mutation of ANY ONE signal inside
# count_design_linear_hits does NOT reproduce an end-to-end "clean count"
# regression, because the other two signals independently detect the same
# failure and still return the sentinel through their own (unmutated)
# checks -- confirmed empirically while building this leg, not assumed. The
# defense-in-depth this file's three-signal design provides is real. So the
# pin targets a SELF-CONTAINED primitive with no sibling to mask its own
# regression instead. linear_capitalised_hit_count is also called by BOTH
# count_design_linear_hits and count_design_linear_hits_text, so this one
# pin covers a code path shared by both canonical detectors.
SELF="$SCRIPTS_DIR/tests/design-structural.test.sh"
if [ ! -f "$SELF" ]; then
    printf 'design-structural.test: section E: cannot find own source at %s -- skipping the error-handling regression pin\n' "$SELF" >&2
    assert_eq "error-handling regression pin (R2-F2): own source file found at the expected self-path (prerequisite for this section)" "yes" "no"
else
    # Deliberately single-quoted below: this is a literal TEXT pattern
    # being grepped for in another file's source (this file's own, read as
    # data), not a variable to expand in THIS script -- same reason, and
    # the same directive, as the bare-case-arm-R1-F1-bypass injection line
    # further down in this file (see that line's own comment).
    # shellcheck disable=SC2016
    BOUNDARY_LINE=$(grep -n '^for f in "\$QAGATE" "\$VBS" "\$RCHECK"; do$' "$SELF" | head -1 | cut -d: -f1)
    TARGET_LINE=$(grep -n -F "grep -cE 'Linear'" "$SELF" | head -1 | cut -d: -f1)
    if [ -z "$BOUNDARY_LINE" ] || [ -z "$TARGET_LINE" ]; then
        printf 'design-structural.test: section E: could not locate the expected anchor line(s) in %s (boundary=%s target=%s) -- the file has drifted further than this pin tracks\n' \
            "$SELF" "${BOUNDARY_LINE:-<none>}" "${TARGET_LINE:-<none>}" >&2
        assert_eq "error-handling regression pin (R2-F2): the expected anchor lines were found in own source (prerequisite for this section)" "yes" "no"
    else
        MISSING_PATH="$WORK/does-not-exist-for-error-handling-pin.sh"
        MUTANT_COPY="$WORK/design-structural.mutant-signal2-failopen.sh"
        cp "$SELF" "$MUTANT_COPY"

        # The mutation: reintroduce the exact pre-R2-F2 shape on signal 2's
        # grep line, IN THE COPY ONLY -- append `|| true`, which forces the
        # command substitution's own exit status to 0 regardless of what
        # grep actually did, so the very next line's `rc=$?` reads a false
        # success, `if [ "$rc" -gt 1 ]` never fires, and a genuine tool
        # failure falls through to `[ -z "$cnt" ] && cnt=0` -- exactly the
        # shape every detector in this file used to have before this
        # round's fix.
        sed -i.bak -E "${TARGET_LINE}s#2>/dev/null\)\$#2>/dev/null || true)#" "$MUTANT_COPY"
        rm -f "$MUTANT_COPY.bak"

        # E-1 (NON-VACUITY): prove the mutation landed in the copy, and
        # that the real, running file is untouched by it.
        MUTANT_LANDED=$(grep -cF "grep -cE 'Linear' \"\$file\" 2>/dev/null || true" "$MUTANT_COPY" 2>/dev/null || true)
        [ -z "$MUTANT_LANDED" ] && MUTANT_LANDED=0
        assert_eq "error-handling regression pin (R2-F2), non-vacuity: the fail-open mutation landed in the copy" "1" "$MUTANT_LANDED"

        # QA ROUND 3, R3-F1b: same fix as B4's BOUNDARY_ONLY_ON_NONLINEAR
        # above -- this is also a ZERO-EXPECTED check, so a bare
        # `2>/dev/null || true` would let a genuine grep tool failure read
        # as "real file clean" instead of failing loudly.
        SELF_STILL_CLEAN=$(grep -cF "grep -cE 'Linear' \"\$file\" 2>/dev/null || true" "$SELF" 2>/dev/null)
        SELF_STILL_CLEAN_RC=$?
        if [ "$SELF_STILL_CLEAN_RC" -gt 1 ]; then
            SELF_STILL_CLEAN="$TOOL_FAILURE_SENTINEL"
        else
            [ -z "$SELF_STILL_CLEAN" ] && SELF_STILL_CLEAN=0
        fi
        assert_eq "error-handling regression pin (R2-F2), non-vacuity: the REAL shipped file does NOT contain the fail-open shape (the mutation is isolated to the copy)" "0" "$SELF_STILL_CLEAN"

        # E-2 (MISBEHAVIOUR): source the mutant's function definitions in a
        # SUBSHELL (command substitution already forks one) so the
        # redefinition cannot leak into this script's own functions, then
        # drive the mutant against a genuinely unreadable path.
        MUTANT_FUNCS="$WORK/design-structural.mutant-signal2-failopen.funcs.sh"
        sed -n "1,$((BOUNDARY_LINE - 1))p" "$MUTANT_COPY" > "$MUTANT_FUNCS"
        MUTANT_RESULT=$(
            # shellcheck disable=SC1090
            source "$MUTANT_FUNCS"
            linear_capitalised_hit_count "$MISSING_PATH"
        )
        assert_eq "error-handling regression pin (R2-F2), specific misbehaviour: the MUTATED linear_capitalised_hit_count silently reports a clean 0 on a genuinely unreadable path instead of the sentinel -- exactly the defect that would let a real tool failure hide behind a fabricated clean tripwire result" \
            "0" "$MUTANT_RESULT"

        # E-3 (RESTORE CONTROL + EXECUTION): the REAL function this script
        # is already running with -- defined above, no re-sourcing, so this
        # call cannot be affected by the subshell mutation above -- same
        # input, same call shape, still returns the sentinel. This drives
        # the shipped artifact RUNNING, not a byte comparison.
        REAL_RESULT=$(linear_capitalised_hit_count "$MISSING_PATH")
        assert_eq "error-handling regression pin (R2-F2), restore control: the REAL, currently-shipped linear_capitalised_hit_count returns TOOL_FAILURE_SENTINEL (not a clean 0) on the identical unreadable path -- confirms the subshell mutation above did not leak into this script's own functions either" \
            "$TOOL_FAILURE_SENTINEL" "$REAL_RESULT"
    fi
fi

# ---------------------------------------------------------------------------
if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

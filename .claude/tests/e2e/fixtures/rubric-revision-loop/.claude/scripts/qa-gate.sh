#!/bin/bash
# QA Gate Lifecycle helper.
#
# Beads-backed design-gate lifecycle for the QA workflow. Replaces the legacy
# `.claude/.qa-tracking/approved` marker file (B1/D1/J2) and the comment-text
# fallback (B13). Single source of truth: Beads labels.
#
# Subcommands:
#   enter   <task-id>                       Mark gate as entered (label + comment).
#                                           Also generates the mechanical impact
#                                           report via impact-report.sh (G2.n6d;
#                                           tolerant — enter never fails on it).
#                                           Clears a PRIOR CYCLE's qa-approved in
#                                           both arms — the fresh one and the
#                                           already-entered one (jue). Does NOT
#                                           write a cycle record in the
#                                           already-entered arm, so a
#                                           qa-gate-entered label is not evidence
#                                           that enter ever ran.
#   status  <task-id>                       Print one of: not-entered, entered, approved, blocked
#                                           — or, if the store could not be read at all (schema
#                                           skew, an unreachable store, any reason), "unavailable"
#                                           with ok:false and exit 3 (claude-workflow-plugin-j7kk,
#                                           39cy). Unavailable is not not-entered.
#   approve <task-id> [--expect-hash <hash>] [--no-impact-report '<reason>']
#           [--no-review '<reason>'] <approval-summary>
#                                           --expect-hash <h> names the change set
#                                           the CALLER classified; approve REFUSES
#                                           (exit 2, expected_hash_mismatch) if that
#                                           is not the set it would bind, naming both
#                                           hashes (qzv). It proves bound == classified,
#                                           NOT that the set is complete.
#                                           Atomic (8zi): +qa-approved and -every
#                                           other QA cycle label (qa-blocked,
#                                           qa-gate-entered, qa-pending,
#                                           qa-escalated, qa-deferred,
#                                           rubric-pending), + comment. On any
#                                           failure the pre-call label set is
#                                           restored exactly and it exits 3.
#                                           rubric-satisfied is NOT in the cycle
#                                           set and is preserved as the audit
#                                           trail of the verdict that backed the
#                                           approval.
#                                           REFUSES (exit 2) when the impact report
#                                           (.qa-tracking/impact-report-<task-id>.json)
#                                           is missing or its change_set_hash no longer
#                                           matches the current changed-files list.
#                                           server:"absent" reports are accepted (the
#                                           documented degradation). The bypass flag
#                                           approves anyway and records the reason in
#                                           the approval comment + gate JSON.
#                                           ALSO REFUSES (exit 4) when independent
#                                           review is missing/non-independent/has open
#                                           findings, per review-check.sh gate (V3).
#                                           --no-review '<reason>' is the audited
#                                           bypass for that check.
#                                           ALSO REFUSES (exit 2,
#                                           completion_record_missing) when no
#                                           COMPLETION v1 record exists for the task
#                                           — the F7 specialist completion contract
#                                           had zero runtime enforcement before P7.
#                                           --no-completion '<reason>' is the audited
#                                           bypass (the Stop hook's doc-only fast
#                                           path passes it: no specialist, no
#                                           payload). The approval additionally
#                                           REPORTS how many of the contract's
#                                           declared files_changed are absent from
#                                           the change set being bound — the
#                                           independent completeness witness the
#                                           freshness check structurally cannot be
#                                           (fkm.1.20). That is a report, not a
#                                           refusal; see
#                                           completion_files_crosscheck for why.
#   block   <task-id> <reason>              Add qa-blocked label + comment. Keeps
#                                           qa-gate-entered, qa-pending,
#                                           rubric-pending and the escalation pair
#                                           — a block happens MID-cycle. Clears
#                                           qa-approved only (8zi): every label
#                                           reader in the tree tests qa-approved
#                                           first, so a surviving one would report
#                                           a blocked task as approved. Same
#                                           restore-exactly-then-exit-3 discipline
#                                           as approve.
#   baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]
#                                           Write .qa-tracking/gate-baseline (3mg.1): the
#                                           `git status --porcelain` snapshot the Stop gate
#                                           subtracts so it evaluates the session DELTA, not a
#                                           tree that was dirty on arrival. No task, no bd.
#   reconcile-tracker                       Fold every git-visible changed path the
#                                           Write/Edit/MultiEdit hook never saw (Bash
#                                           redirects, cp, generator scripts) into
#                                           .qa-tracking/changed-files.txt, so the
#                                           change-set hash covers the whole diff rather
#                                           than the subset post-edit.sh recorded (94d).
#                                           No task, no bd, no labels. Exit 2 when the
#                                           reconcile cannot be completed — callers must
#                                           treat that as refuse-to-proceed. `enter` and
#                                           `approve` call it themselves; the Stop hook
#                                           calls it at its detection stage.
#   choose  <approve|continue|tech-debt|defer> <task-id> <note> [extra args for tech-debt]
#                                           Spec 0.2: record a J21 decision while qa-escalated.
#                                           Each choice records a comment + acts on labels/state.
#   grade-record <task-id> [--file <path>]  Spec Phase A: record a grader verdict.
#                                           Reads strict-JSON verdict from --file or stdin.
#                                           Appends a Beads comment bound to the graded
#                                           change set; on satisfied flips
#                                           rubric-pending -> rubric-satisfied.
#   review-record <task-id> [--file <path>] Phase V2: validate a reviewer artifact via
#                                           review-check.sh then append the REVIEW-ARTIFACT
#                                           v1 record comment (record writer only).
#   review-reconcile <task-id> --file <path> [--acknowledge-findings] <reason>
#                                           claude-workflow-plugin-k6re R13-F1/F2:
#                                           validate a HISTORIC, already-on-disk reviewer
#                                           artifact via review-check.sh, then append the
#                                           NON-GOVERNING REVIEW-ARTIFACT-RECONCILED v1
#                                           record comment. Accounted for by
#                                           review-check.sh recorded-hashes (so approve
#                                           stops refusing it) but never matched by
#                                           gate's K3 selector (so it can never win
#                                           release-verdict selection). For backfilling
#                                           rounds that already happened without
#                                           inverting cmd_gate's iteration-vs-timestamp
#                                           agreement requirement -- see the
#                                           review_artifact_unrecorded remedy below for
#                                           when to use this instead of review-record.
#                                           R14-F5: refuses (reconcile_open_findings_
#                                           unacknowledged) when the artifact carries a
#                                           finding at/above its own risk_threshold, unless
#                                           --acknowledge-findings is given -- the reason
#                                           is then embedded in the comment as a visible
#                                           marker so the open finding is never silently
#                                           dropped from the trust chain.
#   completion-record <task-id> [--file <path>]
#                                           P7: validate an F7 specialist completion
#                                           payload via review-check.sh
#                                           validate-completion (the ONE validator),
#                                           persist it to
#                                           .qa-tracking/completion-<task-id>.json,
#                                           and append:
#                                             COMPLETION v1 task=<tid> role=<r>
#                                             fields=<csv> payload_sha=<sha256>
#                                             at <ts>: <n> file(s), <m> test(s)
#                                           approve REFUSES without this record.
#   resolve-finding <tid> <fid> --fix <ref> --test <ref> <summary>
#                                           Phase V2: append a RESOLVED <fid> comment
#                                           (id must be in the latest REVIEW-ARTIFACT).
#   arbitrate <tid> <fid> <overrule|sustain> <rationale>
#                                           Phase V2: append an ARBITRATION <fid> comment
#                                           (id must be in the latest REVIEW-ARTIFACT).
#
#   quarantine-artifact -- REMOVED (claude-workflow-plugin-k6re, R2-F1). Used
#   to append a REVIEW-ARTIFACT-QUARANTINE v1 comment excusing a malformed
#   REVIEW-ARTIFACT candidate (R12-F1). Found forgeable on its own first
#   independent review (R2-F1: the comment stream carries no verifiable
#   author, the reader matched a bare prefix rather than the writer's full
#   grammar, and bd import/hand-typed comments reach the reader without ever
#   calling this writer's validation) and removed rather than re-guarded. See
#   the tombstone comment where cmd_quarantine_artifact used to be defined,
#   below, for the full finding. A malformed REVIEW-ARTIFACT candidate now
#   refuses review-check.sh gate / qa-gate.sh approve unconditionally and
#   permanently; the remedy is an operator repairing the record directly in
#   the store.
#
# Output: every subcommand prints structured JSON to stdout. Errors go to stderr.
# JSON shape (per principle #9 - free-form `observations` for LLM-side context):
#   {"ok": bool, "subcommand": "...", "task_id": "...", "status": "...", "observations": "..."}
#
# Exit codes:
#   0   success
#   1   missing args / usage error
#   2   bd unavailable, task lookup failed, or approve REFUSED for a
#       missing/invalid/stale impact report, or for a change-set tracker that
#       could not be reconciled against git (error_key names which)
#   3   atomic operation rolled back
#   4   approve REFUSED by the V3 review-separation gate: no independent
#       review artifact, the reviewer is also an implementer, findings at or
#       above the risk_threshold are still open, the latest review stopped at
#       a CAP rather than concluding on its own terms (v5 D2 / fkm.4:
#       review_cap_terminated), or the review predicate itself is unavailable
#       (fail-closed). error_key names which; the remediation names the
#       resolve-finding / arbitrate / review-record command that clears it.
#       ALSO exit 4 (error_key review_artifact_unrecorded, claude-workflow-
#       plugin-k6re): a review artifact on disk for this task binds no
#       well-formed REVIEW-ARTIFACT v1 record BY CONTENT HASH — the artifact
#       exists but was never recorded, currently silent before this fix.
#       --accept-unrecorded-review '<reason>' is the audited bypass.
#
# The P7 completion-contract refusal exits 2, not 5, deliberately: exit 2 is
# already this file's "refused because a mechanical artifact is missing, stale or
# unverifiable" code (impact_report_missing, tracker_unreconcilable,
# change_set_reconstructed), the error_key names which one, and a missing
# completion record is exactly that shape — one command by the party that did
# the work clears it. A new code would make every existing caller's `case` on
# the exit status silently incomplete for no gain.

set -e

# BARE-SUBSTITUTION-CENSUS BEGIN (claude-workflow-plugin-k6re R17-F1 class sweep)
#
# WHY THIS EXISTS. R16-F1 guarded ONE unguarded `review-check.sh gate`
# command substitution and its own fix comment asserted "this was the ONLY
# unguarded one" — true of the four call sites it actually checked, false of
# the file as a whole: the R16-F3 remedy, in the SAME change set, added a
# second bare substitution of the identical shape ~110 lines away
# (`unrecorded_content_iter=$(cat ... | jq ...)`, no guard), and it shipped
# unnoticed for a full review round (found later as R17-F1). The lesson: a
# claim that a CLASS is closed has to be checked against the whole file, not
# against however many call sites of one specific command prompted the fix.
# This census is that whole-file check, done once, honestly, with its own
# scope stated rather than implied: it is accurate against the change set
# it was written for (this task, R17), not a standing guarantee about
# anything added to this file afterward. The NEXT bare substitution added
# here is this census's blind spot, exactly as R17-F1 was R16-F1's.
#
# THE RULE THIS SCRIPT RUNS UNDER (bash 3.2.57, this file's own target,
# EMPIRICALLY VERIFIED before being relied on — see the probes cited below
# rather than assumed from general `set -e` folklore, which gets shell
# corner cases wrong often enough that this task's own root cause was one):
#
#   - `var=$(cmd)` (bare, no `local` on the SAME statement) — under `set -e`,
#     a non-zero exit from `cmd` (or, for a pipeline, its LAST stage) aborts
#     the whole script immediately, UNLESS the assignment sits inside an
#     `if`/`while`/`until` CONDITION, is a non-final element of an `&&`/`||`
#     list, or is negated with `!`.
#   - `var="$(cmd)"` (quoted) is IDENTICAL for this purpose: POSIX ties an
#     assignment's exit status to its command substitution's regardless of
#     quoting, and this was verified empirically, not assumed — a prior
#     round's census (this task, R17) initially missed an entire class of
#     sites for exactly this reason (a regex anchored on the bare `=$(` form
#     only), including a genuinely exploitable one: `has_label()`'s own
#     `labels="$(get_labels "$1")"`. Do not repeat that mistake by grepping
#     for only one of the two forms.
#   - `local var=$(cmd)` (declared and assigned in ONE statement) does NOT
#     abort — bash's `local` builtin returns ITS OWN status, masking the
#     substitution's, which is why this codebase's shellcheck pass (SC2155)
#     already forces "declare and assign separately" everywhere in this
#     file; every `local` in this file is followed by a SEPARATE bare
#     assignment line, which IS subject to the rule above.
#   - A substitution used as an ARGUMENT to another simple command (e.g.
#     `echo "$(cmd)"`, `printf '%s' "$(cmd)"`) does NOT propagate `cmd`'s
#     exit status to the enclosing command's own exit status — the enclosing
#     command's success is what `set -e` tests, and `echo`/`printf` succeed
#     regardless of what they were given. This is what makes every review-
#     record/-reconcile/completion-record field extraction below safe to
#     write as `field=$(printf '%s' "$raw" | jq ...)` — it is the ASSIGNMENT
#     form that is at risk, not merely "a jq call over untrusted input".
#   - A substitution embedded in a `${var:-$(cmd)}` parameter-expansion
#     default is NOT exempt — if the default branch actually runs, its
#     command substitution's exit status reaches the assignment exactly as
#     the bare form does. (PROJECT_DIR below is the one site in this file
#     with this shape; see its disposition.)
#   - COMMAND SUBSTITUTION `$(cmd)` does NOT enforce `errexit` WITHIN its own
#     subshell on this build. `set -e; x=$(false; echo AFTER-RAN)` yields
#     `x=[AFTER-RAN]`, the WHOLE invocation exiting 0: `false` failing does
#     NOT stop `echo AFTER-RAN` from running, and the substitution's own
#     exit status is simply whatever its LAST command produced. This is the
#     documented reason bash 4.4 added `shopt -s inherit_errexit` — the
#     option's own description states command substitution "inherit[s] the
#     value of the errexit option, INSTEAD OF UNSETTING IT in the subshell
#     environment" once enabled, naming UNSETTING as the pre-4.4 default it
#     changes. This build has no such option at all (`shopt -s
#     inherit_errexit` answers "invalid shell option name": it did not exist
#     before 4.4) and sets no `set -o posix` anywhere in this file, so the
#     pre-4.4 "unset inside `$( )`" behaviour is what actually runs here. An
#     explicit `( cmd )` SUBSHELL is the OTHER construct and behaves
#     OPPOSITELY: it DOES enforce errexit internally — `set -e; ( false;
#     echo SUBSHELL-AFTER )` never reaches the echo, whole invocation exit 1.
#     CONSEQUENCE FOR THIS FILE: any function invoked ONLY through `$(...)`
#     — every caller captures its output, never its bare/direct exit status
#     — executes its ENTIRE body in a zone where a bare internal command
#     substitution failing aborts nothing and skips no later line in that
#     same body, REGARDLESS of whether that internal substitution carries a
#     guard. `get_labels()` and `get_parent_epic()` are exactly this shape
#     (see their own, corrected disposition below — this is NOT the
#     "genuine defect" an earlier version of this census called it). The two
#     `( )`-body functions this file defines (review_dir_is_review_subdir,
#     design_dir_is_spec_dir) are the OTHER construct and WOULD enforce
#     errexit internally against any command substitution they contained —
#     checked directly: neither contains one, so nothing there is at risk
#     either way, but a reader relying on "subshells abort like the parent"
#     as a single rule cannot tell these two function KINDS apart, and this
#     entry is why the file states them separately rather than as one rule.
#
# All of the above was checked against this exact bash build with disposable
# probe scripts before being relied on (isolated `bash -c`/subshell
# invocations per shape, so a shape that DOES abort couldn't take a whole
# probe run down with it) — this file does not carry the probes themselves
# (they are throwaway harness-session scratch, not shipped source). ONE
# bullet in an earlier version of this list was not among the probes
# actually run before shipping — it asserted "set -e inherits into
# subshells (including command-substitution subshells)" opposite to the
# `$(cmd)` behaviour above, and was caught by independent review
# (claude-workflow-plugin-k6re R19-F1), which ran the missing probe and
# supplied the result now recorded here. It had manufactured two "genuine
# defects" that were not reachable on any call path (get_labels(),
# get_parent_epic()) and a forward-looking warning that does not hold
# either (see their disposition below) — named here rather than only fixed
# silently, on the same "a claim about a class has to be checked, not
# extrapolated" doctrine the R16-F1/R17-F1 history a few hundred lines below
# is itself the cautionary tale for. The specific, sometimes counterintuitive
# results above (`local var=$(false)` reaching its own next line at rc 0;
# `echo "$(false)"` reaching its own next line at rc 0; `${u:-$(false)}`
# NOT reaching; `$(false; echo AFTER)` reaching AFTER at rc 0 — the one that
# was missing; `( false; echo AFTER )` NOT reaching AFTER) are each
# independently reproducible in under five lines of bash if ever doubted
# again.
#
# METHOD: every `IDENT=$(` and `IDENT="$(` at the start of a (whitespace-
# trimmed) line in this file was located, its matching close-paren resolved
# with a quote/escape/nesting-aware scan (not a naive greedy regex — several
# of these substitutions embed multi-line jq programs and nested `$(...)`),
# and classified below. Two mixed forms (`var="literal text$(cmd)"` and one
# `${var:-$(cmd)}`) were additionally located by a broader sweep and folded
# into the same categories. Argument-embedded and condition-embedded
# substitutions are exempt BY CONSTRUCTION (see the rule above) and are not
# individually re-enumerated here — the file has many of them (e.g. the
# `[ "$(get_labels "$tid")" = "$snapshot" ]` a few hundred lines below, or
# the `.ok`-check brackets throughout the unrecorded-artifact walk), and
# listing every one would document a category that needs no per-site
# judgment, only the one rule above.
#
# CATEGORY: SAFE, already OUTER-guarded (`... ) || fallback`) or INNER-
# guarded (the substitution's own last pipeline stage ends `... || fallback`
# BEFORE its closing paren, so the substitution itself always "succeeds").
# The large majority of this file's command substitutions are one of these
# two shapes. Not enumerated individually — `grep -n '|| ' .claude/scripts/
# qa-gate.sh` finds them, and each was confirmed to guard the SAME statement
# it sits on, not a neighbour.
#
# CATEGORY: SAFE-BY-CALLEE-CONTRACT. Command substitutions whose callee is
# a function in THIS file already proven to always `return`/exit 0 on every
# path — either because its last statement is an unfailable `printf` with a
# fixed format string, or because every exit path is an explicit `return 0`.
# Confirmed by reading each function body, not assumed from its name:
# `impact_report_path_for`, `completion_payload_path_for`,
# `review_artifact_path_for`, `design_artifact_path_for`,
# `_design_unit_lock_root`, `design_declared_unit_ids`, and
# `approval_worktree_token`. Every bare call site of these seven (there are
# nearly twenty) is safe regardless of its own arguments' content, because
# the callee's own construction cannot produce a non-zero exit.
#
# CATEGORY: SAFE-BY-PIPELINE-MECHANICS. The substitution's LAST pipeline
# stage is a command that does not fail based on its input's content —
# `tr` (with or without `-c`/`-d`), `cut`, `head -c N` / `head -N`, `sed`
# running ONLY substitute commands with no failure mode of their own (a
# non-matching `s///` is not an error, it passes the line through), and
# bare `cat` reading stdin to EOF (never fails on empty or arbitrary input;
# each of this file's four `raw=$(cat)` stdin-reads is exactly this shape,
# gated beforehand by its own `[ -t 0 ]` terminal check). An upstream stage
# in the same pipe CAN exit non-zero (e.g. `grep -c` on zero matches exits
# 1) without it mattering, because a pipeline's exit status — absent
# `pipefail`, which this file does not set globally — is its LAST stage's.
# `unnorm_detail=$(head -5 "$actual_stderr_file" ...)` is the same category
# for a different reason: the file it reads was just created by the
# STDERR REDIRECT of the immediately preceding command, so its existence at
# read time is guaranteed by construction, not merely likely.
#
# CATEGORY: SAFE-BY-PRIOR-VALIDATION. Every field extraction inside
# `cmd_review_record`, `cmd_review_reconcile`, and `cmd_completion_record`
# that reads `$raw` (the caller-supplied artifact/payload bytes) does so
# ONLY after that exact `$raw` has already been round-tripped through
# `review-check.sh validate-artifact`/`validate-completion` via a temp file
# and confirmed `.ok == "true"` — itself via a GUARDED extraction
# (`... || echo "false"`). Since jq parses an entire document before
# evaluating any filter against it, a validator that successfully confirmed
# schema conformance on those bytes has already proven they parse; every
# LATER unguarded `$(printf '%s' "$raw" | jq -r '.field' ...)` in the same
# function, on the same unmodified `$raw`, cannot fail on a parse error it
# would have already hit at validation time. The same argument covers
# `unrecorded_ack_count` and its siblings against `$unrecorded_hashes_out`
# (gated by its own `.ok` check a few lines earlier in the same block) and
# `ack_findings_token` against `$ack_findings_json` (derived from an
# already-validated `$raw` by a STATIC jq filter with its own `[]` fallback,
# so it is always well-formed JSON text by construction, never a second
# unvalidated input). This argument depends on review-check.sh's validators
# genuinely refusing anything that fails to parse — reasonable to lean on,
# since that is their entire stated purpose, but named as a DEPENDENCY here
# rather than a proof independent of review-check.sh's own correctness.
#
# CATEGORY: not a command substitution at all. `$((...))` arithmetic
# expansion (`sub_count=$((sub_count + 1))` and its siblings) matches the
# same anchor regex used to find candidates but is a different construct
# entirely, with no realistic runtime failure mode for the fixed, simple
# integer expressions this file uses it for.
#
# CATEGORY: DELIBERATELY ALLOWED TO ABORT, with a stated reason.
#   - `PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"`, immediately below —
#     the `$(pwd)` default only runs if `$CLAUDE_PROJECT_DIR` is unset or
#     empty, and `pwd` failing means the process's own current working
#     directory cannot be read at all. This is bootstrap code, BEFORE
#     argument parsing and subcommand dispatch: there is no `$tid`, no
#     subcommand, and often no reliably resolvable filesystem location to
#     construct a meaningful per-subcommand JSON envelope INTO at this
#     point. Left unguarded deliberately, not merely unnoticed.
#   - The ~16 `ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` timestamp sites scattered
#     through this file's record-writing functions. `date` with a fixed,
#     valid format string and no external/variable input has no realistic
#     content-dependent failure mode on any platform this script targets —
#     unlike every genuine fix below, there is no untrusted byte on the
#     other end of this call. Two OTHER pre-existing timestamp sites in this
#     file (`ts=$(date ... 2>/dev/null || echo "?")` and `|| echo
#     "unknown")`) already guard defensively; this sweep did not force the
#     remaining ones into uniformity with those two, on the judgment that
#     patching sixteen near-zero-risk call sites for a class this task did
#     not reproduce there would be scope beyond what a P0 fix-and-verify
#     round should spend, not scope this census is unaware of.
#
# CATEGORY: GENUINE DEFECTS, FIXED THIS ROUND (each carries its own detailed
# comment at its own site; this is the index, not the explanation):
#   - `unrecorded_content_iter` (cmd_approve, the unrecorded-artifact walk)
#     — R17-F1 ITSELF, the task's named defect. `|| true`.
#   - `review_remedy` (cmd_approve, REVIEW-SEPARATION's rc=4 case-arms,
#     TWO call sites: review_artifact_malformed|... and
#     review_artifact_selection_disagreement) — R17-F2. Reachability
#     analysis (recorded at each site) concludes these are transitively
#     protected by the `review_key` extraction that gates entry to their
#     case arms, on the same jq document — guarded anyway with `|| true`,
#     on the same "a proof of safety today is not a substitute for
#     surviving being wrong" reasoning this whole census exists to apply
#     rather than merely state.
#   - `review_out` (cmd_approve, the same block's own gate consult) —
#     R17-F2's third named candidate. Narrowed from `2>&1` to `2>/dev/null`
#     (matching this file's other three `review-check.sh gate` call sites)
#     rather than guarded, since nothing downstream ever reads its raw
#     stderr content and the merge was the one plausible way an unrelated
#     diagnostic line could corrupt the JSON this whole case-arm parses.
#
# CATEGORY: CONTRACT-HYGIENE / DEFENSIVE HARDENING, NO REACHABLE DEFECT.
# claude-workflow-plugin-k6re R19-F1 corrected this whole category: an
# earlier version of this census placed `get_labels()`/`get_parent_epic()`
# under "genuine defects" and reasoned about `has_label`/`restore_labels`/
# `set_terminal_label` using the now-corrected-above `$(cmd)`-inherits-
# errexit rule. Both were wrong in the same direction (over-predicting an
# abort), independently re-derived by review, and independently reproduced
# again here before writing this correction — the code is UNCHANGED (every
# one of these guards is behaviour-preserving, confirmed by A/B below), only
# the claim about WHY is fixed.
#   - `get_labels()` and `get_parent_epic()` — each has a `raw=$(bd show
#     ... 2>/dev/null)` immediately followed by `rc=$?`. Both functions are
#     invoked ONLY through `$(...)` at every call site (every caller
#     captures their output) — meaning their ENTIRE body, on this
#     interpreter, executes in a zone where command substitution does not
#     enforce errexit (see the rule above). A/B, stubbing `bd` to fail,
#     across all four combinations of {original bare `rc=$?}` / this
#     round's `|| rc=$?`} x {the whole call bare / wrapped in `if`}: the
#     internal `rc=$?` line executes in EVERY case, captures bd's real exit
#     code identically in every case, and the OUTER caller's behaviour
#     (abort when bare, clean `if`-false when wrapped) is IDENTICAL between
#     the original and the changed form. The function's own documented
#     "exit status is the signal, not a global" contract was already true
#     before this change; `|| rc=$?` makes that contract explicit in the
#     source rather than dependent on an unstated interpreter quirk a
#     future reader would have to already know, and is the form that would
#     matter if this script were ever run under bash >= 4.4 with `shopt -s
#     inherit_errexit` explicitly enabled (nothing in this file sets it
#     today).
#   - `has_label()`'s `labels="$(get_labels "$1")"`, `restore_labels()`'s
#     `current="$(get_labels "$tid")"`, and `set_terminal_label()`'s
#     `snapshot="$(get_labels "$tid")"` and its rollback-path `restore_obs=`
#     — DIFFERENT reasoning from get_labels' own, and correctly so: these
#     three functions are called DIRECTLY (never through `$(...)`), so it is
#     THEIR OWN calling context, not command-substitution inertness, that
#     matters for them. Checked individually: every one of has_label's ten
#     call sites, both of set_terminal_label's, and restore_labels' one
#     currently sits inside an `if`/`&&`/`||`/`!` context, which (ordinary
#     function-call errexit exemption, confirmed separately from — and
#     unrelated to — the `$(cmd)` correction above: a DIRECTLY-called
#     function inherits its caller's "-e is being ignored" state through its
#     own body) transitively protects each of these three functions' entire
#     bodies for every call that exists today. Smoke-tested directly
#     (`qa-gate.sh status`/`block` against a nonexistent task id) and
#     confirmed with an isolated A/B revert against `block`: no behaviour
#     change either way. `|| true` kept as the same explicit-contract
#     hygiene as get_labels' own change, not because a caller-side accident
#     needs a backstop — DROPPED: the earlier "the next caller that writes
#     a plain, unwrapped `x=$(has_label ...)` reopens exactly this" warning.
#     It does not: writing the result through `$(...)` is itself the
#     command-substitution-inertness case above, not the direct-call case,
#     so that hypothetical caller would ALSO see no difference between the
#     guarded and unguarded forms.
#   - `art_prefix` (inside `finding_id_in_latest_artifact`) — same shape as
#     has_label: BOTH of this function's callers (`resolve-finding`,
#     `arbitrate`) invoke it directly as `if ! finding_id_in_latest_artifact
#     ...; then`, transitively protecting this whole function's body today.
#     Kept, same contract-hygiene reasoning, not a proof of an active
#     defect.
#
# `unrecorded_content_iter`, `review_remedy` (both sites) and `review_out`
# above remain GENUINE, independently-reproduced defects: `cmd_approve` is
# dispatched directly from this file's top-level `case` (never through
# `$(...)`), so its body runs where `set -e` is fully, literally active —
# unlike every function in the CONTRACT-HYGIENE category above.
#
# review-check.sh: CHECKED, does NOT set `-e` anywhere (only `set -u`,
# confirmed at its own line 108; grep for `set -` finds no other `set -e`/
# `set -o errexit` in that file). The ABORT mechanism this whole census is
# about therefore cannot occur there: a failing bare command substitution
# in review-check.sh degrades into a variable holding wrong or empty data
# and execution continuing, never an uncontrolled process exit. That is a
# DIFFERENT hazard class (silently wrong output, not a missing envelope),
# and R19-F1 found it is NOT confined to that one sibling script the way an
# earlier version of this sentence implied: the SAME silent-wrong-data class
# applies INSIDE any qa-gate.sh function invoked only through `$(...)` —
# get_labels() and get_parent_epic() among them — for exactly the reason the
# CONTRACT-HYGIENE entries above state: command substitution does not
# enforce errexit there either, so an unguarded internal failure would not
# abort, it would silently produce empty/wrong data that the calling
# `$(...)` then captures as if it were a normal result. Named as a residual
# the same way review-check.sh's is: out of scope for this sweep (which
# targets the missing-envelope/abort class specifically), not fixed here,
# and not silently absent from the record either.
# BARE-SUBSTITUTION-CENSUS END (claude-workflow-plugin-k6re R17-F1 class sweep)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"

# TRACKER-RECONCILE BEGIN (94d)
# The shared path denylist. This script became a FOURTH consumer of the lib when
# reconcile_tracker landed: it WRITES into changed-files.txt, so it must apply
# exactly the filter post-edit.sh applies to the same file — otherwise the
# reconciler tracks build output the other writer is careful to drop, and the two
# writers of one file disagree about what belongs in it. Everything else in this
# script still defers to impact-report.sh --hash-only for canonicalisation
# (llh.18); this is a filter, not a second hash.
#
# Resolved relative to THIS script (BASH_SOURCE), never to $PROJECT_DIR — the
# gate may run with CLAUDE_PROJECT_DIR pointing at a different checkout than the
# install it lives in. Same convention as the other three consumers.
#
# Missing lib -> reconcile_tracker REFUSES (see its header). That matches the two
# gate-side consumers (impact-report.sh exits 3, verify-before-stop.sh blocks)
# rather than post-edit.sh's track-anyway, because an unfiltered reconcile would
# append build output to an append-only file and there is no way back.
_WFDL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || _WFDL_DIR=""
if [ -n "$_WFDL_DIR" ] && [ -f "$_WFDL_DIR/workflow-denylist.sh" ]; then
    # shellcheck source=.claude/scripts/workflow-denylist.sh
    . "$_WFDL_DIR/workflow-denylist.sh"
fi
# TRACKER-RECONCILE END (94d)

# ---------------------------------------------------------------------------
# Helpers

# sync-errors.log: structured trace for best-effort calls that previously
# silenced everything via `|| true`. SessionStart can surface recent entries.
log_sync_error() {
    local msg="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    printf '%s\t[qa-gate]\t%s\n' "$ts" "$msg" >> "$SYNC_ERRORS_LOG" 2>/dev/null || true
}

# F3 (Phase 4 fix pass): persist active task on `enter`, clear on `approve`.
# Two layers of robustness:
#   1. We pass CLAUDE_PROJECT_DIR explicitly when invoking current-task.sh
#      so the helper writes to the SAME .qa-tracking dir we read from. This
#      guards against cwd drift (e.g., an orchestrator invoking qa-gate.sh
#      from a different working directory than the project root).
#   2. If the helper fails, we fall back to writing the helper file
#      directly. If THAT fails, we log to sync-errors.log so the gap is
#      visible (previously the silent `|| true` is what caused the empty
#      helper file in this project's own claude-workflow-plugin-y4a.10).
write_current_task() {
    local tid="$1"
    local helper_rc=0
    local fallback_rc=0
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$CURRENT_TASK_HELPER" set "$tid" 2>/dev/null || helper_rc=$?
        # Verify the file landed where we expect; if the helper succeeded
        # but the file is missing/empty, treat as a failure and fall through.
        if [ "$helper_rc" -eq 0 ] && [ -s "$QA_TRACKING_DIR/current-task" ]; then
            return 0
        fi
        log_sync_error "current-task.sh set $tid: helper exit=$helper_rc, file_size=$(wc -c < "$QA_TRACKING_DIR/current-task" 2>/dev/null || echo missing); falling back to direct write"
    fi
    # Fallback: write the file directly. We've already mkdir'd the dir;
    # rare failures (read-only fs, perm denied) get logged.
    printf '%s\n' "$tid" > "$QA_TRACKING_DIR/current-task" 2>/dev/null || fallback_rc=$?
    if [ "$fallback_rc" -ne 0 ] || [ ! -s "$QA_TRACKING_DIR/current-task" ]; then
        log_sync_error "direct write of current-task failed for tid=$tid (rc=$fallback_rc)"
        return 1
    fi
    return 0
}

clear_current_task() {
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$CURRENT_TASK_HELPER" clear 2>/dev/null \
            || log_sync_error "current-task.sh clear failed; removing file directly"
    fi
    # Always also rm directly to be safe (idempotent).
    rm -f "$QA_TRACKING_DIR/current-task" 2>/dev/null || true
}

# has_git_repo — is $PROJECT_DIR inside a git checkout we can query?
#
# 3mg.1: the old test was `[ -d "$PROJECT_DIR/.git" ]`, which is FALSE in a
# LINKED WORKTREE (there `.git` is a FILE containing `gitdir: ...`). The
# baseline mechanism therefore silently disabled itself in exactly the
# topology the plugin tells agents to use — no snapshot on approve, and
# verify-before-stop's git fallback skipped entirely. Ask git instead.
# The identical predicate lives in verify-before-stop.sh; keep them in sync.
#
# Consequence worth naming: `rev-parse --git-dir` also succeeds when
# $PROJECT_DIR is a SUBDIRECTORY of a repo (git walks up), where `-d .git`
# failed. Porcelain output is repo-root-relative in that case — self-
# consistent between the baseline and the later comparison, and it moves the
# nested-subdir case from "fallback disabled => gate could release unreviewed
# work" to "fallback active", i.e. from fail-open to fail-closed.
has_git_repo() {
    command -v git >/dev/null 2>&1 || return 1
    git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1
}

# gate-baseline v2 (3mg.1), superseding the 0wk.2 `approved-baseline`.
#
# WHAT IT IS: a snapshot of `git status --porcelain` that says "this dirt was
# already here; it is not this session's work". verify-before-stop.sh's git
# fallback subtracts it, so the gate evaluates the DELTA rather than the whole
# working tree. Without it, a repo that is merely dirty on arrival makes every
# Stop fire "N file(s) changed - all require QA review" forever.
#
# WHY IT IS VERSIONED AND HEADERED: the 0wk.2 file was a bare line list with
# no provenance, so nothing could tell an approve-time snapshot from a
# session-start one, or detect a snapshot taken against a different HEAD.
#
#   # gate-baseline v1
#   head=<sha|none>
#   captured_at=<ISO-8601 UTC>
#   captured_by=session-start|qa-gate-enter|qa-gate-approve
#   --
#   <LC_ALL=C-sorted `git status --porcelain` lines>
#
# LC_ALL=C is load-bearing: the reader uses `comm -23`, which requires both
# inputs in the SAME collation. The writer and verify-before-stop.sh both pin
# C so a locale change between write and read cannot corrupt the diff.
#
# Options:
#   --if-missing        do nothing when a baseline already exists (enter).
#   --exclude-tracked   drop entries whose path is already in
#                       changed-files.txt, so work the session has ALREADY
#                       done can never be baselined as pre-existing (enter).
#
# Tolerances (unchanged from 0wk.2): no git repo -> remove stale baselines and
# succeed; git missing -> log + return 1 (no baseline means the reader treats
# everything as new, which is the fail-closed direction).
#
# HEAD-BOUND READS (claude-workflow-plugin-bbes). `head=` above has been
# written since 3mg.1 and, until bbes, never read back: the reader
# (gate_baseline_entries) compared porcelain LINES only, so a path committed
# and then re-dirtied within one baseline's lifetime matched its own stale
# entry byte-for-byte and was subtracted as pre-existing — silently, because
# 94d.1's `change_set_reconstructed` refusal only fires on an EMPTY tracker
# and this leaves a NON-empty one merely incomplete. gate_baseline_entries now
# compares the header's `head=` against the current HEAD and, when they
# differ, drops any entry whose path was touched by a commit in between —
# see gate_baseline_bind_to_head's header for the full four-case breakdown.
GATE_BASELINE_FILE="$QA_TRACKING_DIR/gate-baseline"
LEGACY_APPROVED_BASELINE="$QA_TRACKING_DIR/approved-baseline"

write_gate_baseline() {
    local captured_by="$1"; shift
    local if_missing=0 exclude_tracked=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --if-missing)      if_missing=1 ;;
            --exclude-tracked) exclude_tracked=1 ;;
        esac
        shift
    done

    if ! has_git_repo; then
        # No git repo (or no git): remove stale baselines so a later
        # git-init cannot inherit a snapshot from before the repo existed.
        rm -f "$GATE_BASELINE_FILE" "$LEGACY_APPROVED_BASELINE" 2>/dev/null || true
        command -v git >/dev/null 2>&1 || {
            log_sync_error "write_gate_baseline: git not on PATH (captured_by=$captured_by)"
            return 1
        }
        return 0
    fi

    if [ "$if_missing" = "1" ] && [ -f "$GATE_BASELINE_FILE" ]; then
        return 0
    fi

    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true

    local status_out head ts
    # Scoped pipefail (i8cx): `sort` is the pipeline's LAST command, so without
    # it git's own failure never reached the handler below — the handler the
    # author wrote was dead code, and a failed `git status` captured an EMPTY
    # snapshot at rc 0 (a baseline that subtracts nothing, or worse: an
    # --exclude-tracked capture built over nothing). Subshell-scoped, never
    # file-wide, for the measured epic-gate.sh:1992 reasons: `grep -c` exits 1
    # on the healthy zero-match case and `head` SIGPIPEs its producer, so a
    # global pipefail manufactures failures on this file's common paths.
    status_out=$( set -o pipefail; git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort ) || {
        log_sync_error "write_gate_baseline: git status failed (captured_by=$captured_by)"
        return 1
    }
    head=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null) || head=""
    [ -n "$head" ] || head="none"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

    if [ "$exclude_tracked" = "1" ]; then
        # A failed exclude-tracked build is a REFUSAL TO CAPTURE (i8cx), never
        # a fall-through to the unfiltered snapshot: baselining paths the
        # session already edited marks its own work "pre-existing" and hands it
        # a free pass — the quiet inverse of the loud failure above, and the
        # worse one, because nothing downstream can tell a wrongly-baselined
        # path from genuine arrival dirt.
        status_out=$(gate_baseline_exclude_tracked "$status_out") || {
            log_sync_error "write_gate_baseline: exclude-tracked filter could not be built from changed-files.txt (captured_by=$captured_by) — REFUSING to capture a baseline that would mark the session's own edits pre-existing"
            return 1
        }
    fi

    local tmp="$GATE_BASELINE_FILE.tmp.$$"
    {
        printf '# gate-baseline v1\n'
        printf 'head=%s\n' "$head"
        printf 'captured_at=%s\n' "$ts"
        printf 'captured_by=%s\n' "$captured_by"
        printf -- '--\n'
        # `if`, NOT `[ -n ... ] && printf` (94d). The body of a brace group takes
        # the exit status of its LAST command, so on an EMPTY snapshot the false
        # test made the whole group "fail": the handler below deleted the tmp file
        # it had just written correctly, logged "could not write", and returned 1.
        # An empty snapshot is the normal state of a CLEAN tree, and of an
        # --exclude-tracked capture where every dirty path is already tracked, so
        # the effect was that exactly those cases silently got NO baseline —
        # `baseline-capture` reported ok:false and exit 2 on a clean checkout, and
        # `enter --if-missing` could never find one to skip. Reproduced with one
        # variable isolated (clean tree fails, one dirty file succeeds) and pinned
        # by section 8 of specs/gate-baseline-v2.sh.
        if [ -n "$status_out" ]; then
            printf '%s\n' "$status_out"
        fi
    } > "$tmp" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        log_sync_error "write_gate_baseline: could not write $tmp (captured_by=$captured_by)"
        return 1
    }
    mv -f "$tmp" "$GATE_BASELINE_FILE" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        log_sync_error "write_gate_baseline: could not install $GATE_BASELINE_FILE (captured_by=$captured_by)"
        return 1
    }

    # First v2 write retires the legacy file. verify-before-stop.sh reads the
    # legacy one only when no v2 baseline exists (one-release fallback), so
    # leaving it behind would just be a confusing stale artifact.
    rm -f "$LEGACY_APPROVED_BASELINE" 2>/dev/null || true
    return 0
}

# gate_baseline_exclude_tracked <porcelain-lines> — drop the lines whose path
# is already in changed-files.txt.
#
# `enter` arms a review cycle mid-session: files the session ALREADY edited
# are dirty in git AND recorded by post-edit.sh. Baselining them would mark
# the session's own work "pre-existing" and hand it a free pass. Tracked
# entries are absolute (post-edit records `tool_input.file_path` verbatim)
# while porcelain paths are repo-relative, so we match on both spellings.
gate_baseline_exclude_tracked() {
    local status_out="$1"
    local tracking="$QA_TRACKING_DIR/changed-files.txt"
    [ -s "$tracking" ] || { printf '%s' "$status_out"; return 0; }

    local tmp_tracked
    # No fall-through to the unfiltered snapshot on ANY failure below (i8cx):
    # printing $status_out unfiltered baselines the session's own edits, which
    # is the exact free pass --exclude-tracked exists to prevent. rc 1 is the
    # signal; the caller (write_gate_baseline) turns it into a refusal to
    # capture. The `[ -s ]` early return above stays rc 0 — an EMPTY tracker
    # legitimately excludes nothing, which is a different answer from "the
    # exclusion set could not be built".
    tmp_tracked=$(mktemp -t gate-baseline-tracked.XXXXXX 2>/dev/null) || return 1
    local t
    # Scoped pipefail (i8cx): the while-loop is the pipeline's FIRST stage, so
    # before this an unopenable $tracking (the redirect fails, the loop runs
    # zero times) or a failing `sort` still left the pipeline at rc 0 with an
    # EMPTY $tmp_tracked — and an empty exclusion set excludes nothing, so the
    # membership probe below kept every porcelain line and the session's own
    # edits were baselined as pre-existing.
    if ! ( set -o pipefail
        while IFS= read -r t; do
            [ -z "$t" ] && continue
            printf '%s\n' "$t"
            case "$t" in
                "$PROJECT_DIR"/*) printf '%s\n' "${t#"$PROJECT_DIR"/}" ;;
            esac
        done < "$tracking" | LC_ALL=C sort -u > "$tmp_tracked"
    ); then
        rm -f "$tmp_tracked" 2>/dev/null || true
        return 1
    fi

    local line p kept=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        p="${line#???}"
        # Rename/copy entries are "R  old -> new"; the destination is the
        # path a tracker entry would name.
        case "$p" in *" -> "*) p="${p##* -> }" ;; esac
        if grep -qxF "$p" "$tmp_tracked" 2>/dev/null; then
            continue
        fi
        kept="$kept$line
"
    done <<< "$status_out"
    rm -f "$tmp_tracked" 2>/dev/null || true
    # Trim the single trailing newline the accumulator adds.
    printf '%s' "${kept%$'\n'}"
}

# Ordinary code, NOT sentinel-wrapped: gate_baseline_entries below wraps only
# its own CALL to this function (the GATE-BASELINE-HEAD-BIND region there), so
# a strip of that region is the surgical, single-variable mutation — "what if
# the reader never consulted head-binding" — rather than also deleting this
# definition. A stripped copy that keeps this function merely unused is still
# valid, coherent bash, the same reasoning SUBTRACTION-ACCOUNTING's
# `account_obs` declaration applies one level up.
#
# gate_baseline_bind_to_head <body> — claude-workflow-plugin-bbes. <body> is
# the baseline's raw porcelain lines (gate_baseline_entries' own read, before
# this narrows it); prints the SUBSET of those lines still safe to treat as
# pre-existing dirt given the CURRENT HEAD, one per line.
#
# THE DEFECT THIS CLOSES. A porcelain line carries a status code and a path,
# never the commit it was diffed against. reconcile_tracker's own `comm`-based
# baseline comparisons below (survivor split and accounting complement alike),
# and verify-before-stop.sh's separate copy, both compared
# TEXT: ` M path` recorded at head A and ` M path` seen at head B matched
# byte-for-byte and were treated as the same fact, even when `path` was
# COMMITTED at A and re-dirtied only afterward — different content, same
# line, silently subtracted either way. write_gate_baseline has recorded
# `head=<sha|none>` in the baseline's own header since 3mg.1; nothing read it
# back until now.
#
# THE FOUR CASES (claude-workflow-plugin-bbes's own framing; every branch
# below is one of these, in the order asked):
#
#   1. baseline captured at current HEAD, HEAD unmoved. `recorded_head =
#      current_head` (including BOTH being "none" — a repo with zero commits
#      at capture time that still has zero commits now). EXACTLY today's
#      behaviour: <body> is returned unfiltered, with no git call beyond the
#      one `rev-parse HEAD` already needed to learn current_head. This is the
#      overwhelmingly common call — every gate cycle that opens and closes
#      without a commit landing in between — so it has to cost nothing and
#      change nothing.
#
#   2. baseline captured at an OLDER head. `recorded_head != current_head`
#      and both resolve. `git diff --name-only <recorded_head> <current_head>`
#      names every path whose committed content differs between the two —
#      i.e. every path "committed in between", the literal wording of the
#      task this closes. An entry whose path is in that set is DROPPED (not
#      printed): the dirt the baseline recorded for it belonged to a version
#      of the file that no longer exists in the same form, so the SAME
#      porcelain line seen now describes different content and must not be
#      trusted merely because the text matches. An entry whose path is NOT in
#      that set is untouched by every commit in the range — the same
#      un-committed dirt sitting through unrelated history elsewhere in the
#      tree — and stays, exactly as case 1 would have kept it.
#      "none" on either side of the diff (a baseline captured before the first
#      commit, or — pathologically — HEAD regressing to unborn) is spelled as
#      the well-known empty-tree object
#      (4b825dc642cb6eb9a060e54bf8d69288fbee4904, $GATE_EMPTY_TREE_SHA) rather
#      than a special code path: diffing against "no commits" and diffing
#      against the empty tree answer the same question — "what did this
#      range commit" — for both orientations.
#
#   3. no baseline at all. Never reaches this function: gate_baseline_entries
#      only calls it when $GATE_BASELINE_FILE exists AND has a non-empty
#      body. Unchanged by construction, not by a branch here.
#
#   4. HEAD unreadable, or git otherwise cannot answer. Two distinct ways this
#      happens, both FAIL CLOSED — nothing is printed, so every entry the
#      baseline can no longer vouch for reads as reviewable, the same
#      experience as case 3. Never a hard refusal: reconcile_tracker's rc
#      contract is reserved for "the change set is unknown", and a baseline
#      that cannot be verified is a narrower, survivable fact — the change
#      set is still knowable, it is just larger than the baseline can trim.
#        4a. $GATE_BASELINE_FILE has no `head=` line at all (hand-built,
#            corrupted, or a fixture predating 3mg.1's header). Nothing to
#            bind to, so nothing is trusted.
#        4b. `has_git_repo` is false, or `git diff` itself fails (most often:
#            recorded_head is no longer a reachable object — history was
#            rewritten or pruned since capture). Cannot prove EITHER
#            direction, so nothing is trusted, logged via log_sync_error so
#            the degrade is visible rather than silently narrower coverage.
#      Both are logged; neither aborts the caller. A caller checking rc alone
#      cannot tell 4 from "the diff legitimately touched nothing" (case 2's
#      empty-touched arm) — that is fine, because both outcomes choose the
#      same direction: trust fewer entries, never more.
#
# Reassignment, not return-on-filter: the caller (gate_baseline_entries) prints
# whatever this returns unconditionally, so this function's ONLY job is to
# decide what <body> narrows to. Always returns 0 — see the caller's own
# defensive `||` for why that is not load-bearing on its own.
GATE_EMPTY_TREE_SHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

gate_baseline_bind_to_head() {
    local body="$1"
    local recorded_head
    # `|| recorded_head=""`, not a bare substitution (set -e): a failed read
    # here (the file vanishing between the caller's `[ -f ]` and this awk is
    # the only realistic trigger) must fall into the SAME fail-closed branch
    # as "no head= line found", not abort the whole script mid-reconcile.
    recorded_head=$(awk '/^--$/ { exit } /^head=/ { print substr($0, 6); exit }' "$GATE_BASELINE_FILE" 2>/dev/null) || recorded_head=""
    if [ -z "$recorded_head" ]; then
        log_sync_error "gate_baseline_entries: $GATE_BASELINE_FILE has no parseable head= line — cannot verify its entries are still bound to un-committed content; treating it as providing no subtraction for this read (fail-closed, bbes)"
        return 0
    fi

    if ! has_git_repo; then
        log_sync_error "gate_baseline_entries: $PROJECT_DIR is not a git checkout we can query right now, so the baseline recorded at head=$recorded_head cannot be verified against the current HEAD; treating it as providing no subtraction for this read (fail-closed, bbes)"
        return 0
    fi

    local current_head
    current_head=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null) || current_head=""
    [ -n "$current_head" ] || current_head="none"

    if [ "$recorded_head" = "$current_head" ]; then
        printf '%s\n' "$body"
        return 0
    fi

    local old_ref="$recorded_head" new_ref="$current_head"
    [ "$old_ref" = "none" ] && old_ref="$GATE_EMPTY_TREE_SHA"
    [ "$new_ref" = "none" ] && new_ref="$GATE_EMPTY_TREE_SHA"

    # Scoped pipefail (matching write_gate_baseline's own status_out capture):
    # `sort` is the pipeline's last stage, so without this a failed `git diff`
    # (most commonly: recorded_head is no longer a reachable object) would
    # report `sort`'s own success and hand this function an EMPTY "touched"
    # set — which reads as case 2's legitimate "nothing committed in the
    # range" arm and keeps every entry, the wrong direction for an unprovable
    # diff.
    local touched touched_rc=0
    touched=$( set -o pipefail; git -C "$PROJECT_DIR" diff --name-only "$old_ref" "$new_ref" -- 2>/dev/null | LC_ALL=C sort ) || touched_rc=$?
    if [ "$touched_rc" -ne 0 ]; then
        log_sync_error "gate_baseline_entries: could not diff the baseline's recorded head ($recorded_head) against the current HEAD ($current_head) (git diff rc=$touched_rc) — cannot verify which entries are still bound to un-committed content; treating the baseline as providing no subtraction for this read (fail-closed, bbes)"
        return 0
    fi
    if [ -z "$touched" ]; then
        printf '%s\n' "$body"
        return 0
    fi

    local line p
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        p="${line#???}"
        # Rename/copy entries are "R  old -> new"; the destination is the path
        # a tracker entry — and this function's own caller — would name.
        case "$p" in *" -> "*) p="${p##* -> }" ;; esac
        if printf '%s\n' "$touched" | grep -qxF -- "$p"; then
            continue
        fi
        printf '%s\n' "$line"
    done <<< "$body"
    return 0
}

# gate_baseline_entries — the porcelain lines of the current gate baseline
# that are still bound to the commit they were captured at (see
# gate_baseline_bind_to_head above), or empty when there is none.
#
# The v2 file carries a provenance header terminated by a lone `--`; everything
# after it is the snapshot. The v1 file (`approved-baseline`, 0wk.2) was a bare
# line list and is read as a fallback for ONE release — any v2 write deletes it,
# so that arm only ever serves an install that upgraded mid-cycle. It predates
# `head=` entirely and is untouched by the binding above: there is nothing in
# it to bind to.
#
# The IDENTICAL reader USED TO live in verify-before-stop.sh too (which cannot
# source this file: qa-gate.sh is a dispatching script, not a lib), kept
# byte-for-byte in sync with this one. THAT IS NO LONGER TRUE as of
# claude-workflow-plugin-bbes: the head-binding above is qa-gate.sh-only (its
# stated scope). It is safe today because reconcile_tracker below — via the
# Stop hook's own `qa-gate.sh reconcile-tracker` shellout, and via approve's
# in-process call — always runs BEFORE verify-before-stop.sh's git-fallback
# walk, which is a UNION over the tracker rather than a fallback: whatever
# this file's reconcile recovers into changed-files.txt is picked up there
# regardless of what the Stop hook's own (still unfixed) copy of this
# function decides. The one path NOT covered by that ordering is
# verify-before-stop.sh's standalone LABEL_WITHOUT_RECORD / VANISHED_PROBE
# re-read (`reviewable_changes` called with nothing reconciling ahead of it)
# — that copy carries the identical staleness risk this closes, unaddressed.
# Filed as a follow-up rather than fixed here (task scope: this file only).
#
# Within THIS file there is exactly one copy of the header-skip awk —
# cmd_baseline_capture counts through here rather than repeating it.
gate_baseline_entries() {
    if [ -f "$GATE_BASELINE_FILE" ]; then
        # No `|| true` (i8cx): a failed or PARTIAL read must be reportable, so
        # awk's non-zero propagates as this function's rc and reconcile_tracker
        # refuses rather than treating "could not read the baseline" as "the
        # baseline subtracts nothing". A MISSING baseline (both -f tests false)
        # is still the legitimate empty answer at rc 0 — absent and unreadable
        # are different states and now return differently.
        local _gbe_body _gbe_rc=0
        _gbe_body=$(awk 'body { print; next } /^--$/ { body = 1 }' "$GATE_BASELINE_FILE" 2>/dev/null) || _gbe_rc=$?
        if [ "$_gbe_rc" -ne 0 ]; then
            return 1
        fi
        # GATE-BASELINE-HEAD-BIND BEGIN (bbes)
        # Only worth checking when there is something to filter — an empty
        # snapshot has nothing a head comparison could change, and skipping it
        # here is what keeps a clean-baseline call (the common case on a
        # freshly-captured or never-dirtied tree) from paying for a `git
        # rev-parse` it does not need. Reassigns _gbe_body rather than
        # returning, so a STRIP of this region leaves the unconditional printf
        # below exactly as it always was — the same discipline
        # SUBTRACTION-ACCOUNTING's `account_obs` uses (declared OUTSIDE its own
        # sentinels so a stripped copy stays coherent), applied here to keep
        # the fallback path byte-for-byte the pre-bbes function.
        if [ -n "$_gbe_body" ]; then
            _gbe_body=$(gate_baseline_bind_to_head "$_gbe_body") || {
                log_sync_error "gate_baseline_entries: gate_baseline_bind_to_head failed unexpectedly (rc=$?) for $GATE_BASELINE_FILE — treating the baseline as providing no subtraction for this read (fail-closed, bbes)"
                _gbe_body=""
            }
        fi
        # GATE-BASELINE-HEAD-BIND END (bbes)
        printf '%s\n' "$_gbe_body"
        return 0
    fi
    if [ -f "$LEGACY_APPROVED_BASELINE" ]; then
        cat "$LEGACY_APPROVED_BASELINE" 2>/dev/null || return 1
    fi
    return 0
}

# TRACKER-RECONCILE BEGIN (94d)
#
# reconcile_tracker — make changed-files.txt describe the WHOLE session delta,
# not just the subset a Write/Edit/MultiEdit tool call happened to produce.
#
# THE DEFECT THIS CLOSES. changed-files.txt is fed by exactly one writer:
# post-edit.sh, on the PostToolUse events that carry a path field. Anything
# written by a Bash redirect, `cp`, `mv`, `sed -i`, a generator script, or a
# subagent's shell therefore never enters it — measured live four times over two
# days, at one point with the tracker holding 37 of 71 changed files. That is not
# merely an under-reporting detector: `change_set_hash()` hashes THIS FILE's path
# list (impact-report.sh canonical_changed_files), so the gate could name N paths
# and release on an approval binding M < N, and the whole change-set binding —
# the approval record, the rubric verdict, the reviewed hash — certified less than
# the actual diff.
#
# WHY RECONCILE INTO THE TRACKER RATHER THAN UNION AT READ TIME. A read-time
# union in verify-before-stop.sh's reviewable_changes() fixes the DETECTOR and
# leaves the hash tracker-only, which produces a gate that reports 14 paths and
# releases on an approval binding 9 — the same hole, now with a confident
# readout. The tracker is the hash's input, so the repair has to land there.
#
# WHAT IT DOES. `git status --porcelain`, minus the gate baseline, minus the
# denylist, minus what the tracker already holds; the remainder is appended as
# ABSOLUTE paths. Modelled on gate_baseline_exclude_tracked above, whose
# absolute/relative matching and `R old -> new` rename handling this reuses.
#
# CONTRACT, and why each clause is the way it is:
#
#   NOT A GIT CHECKOUT -> NO-OP, rc 0. There is no delta to reconcile against;
#   the tracker is all the gate has and that is the pre-existing behaviour.
#
#   `git status` FAILS -> rc 1. That is the DIVERGENCE SIGNAL, not a pass: we
#   cannot prove the tracker is complete, so every caller treats it as
#   refuse-to-proceed (approve refuses with tracker_unreconcilable; the Stop
#   hook blocks). Same shape as impact-report.sh exiting 3 on a missing
#   denylist rather than hashing with an unknown filter.
#
#   ABSOLUTE PATHS. post-edit.sh records `tool_input.file_path` VERBATIM and the
#   runtime passes absolute paths, so the tracker is absolute in practice (the
#   live file was 129 lines / 87 unique, all absolute). Dedup happens at
#   canonical_changed_files() via `sort -u`, which collapses duplicates but NOT
#   two spellings of one file — so emitting a repo-relative path here would
#   double-count it into the hash. The prefix is $PROJECT_DIR when it IS the repo
#   toplevel (primary checkout or worktree root: the common case, and the
#   spelling post-edit would have used) and git's `--show-toplevel` otherwise
#   (a $PROJECT_DIR nested BELOW the toplevel, where porcelain paths are
#   root-relative and `$PROJECT_DIR/$p` would be wrong). The two are compared
#   through `pwd -P` because git returns symlink-RESOLVED paths while
#   CLAUDE_PROJECT_DIR may be the unresolved spelling — /var/folders/... vs
#   /private/var/folders/... on macOS, which is exactly how a mixed-spelling
#   double count would arrive.
#
#   `??` UNTRACKED AND `D` DELETIONS ARE BOTH INCLUDED. A new file nobody
#   reviewed and a deleted file nobody reviewed are both changes. Git COLLAPSES
#   an untracked directory into one `?? dir/` entry, so a surviving entry ending
#   in `/` is expanded with `status --porcelain -uall -- <dir>`; without that a
#   file added later INSIDE an already-listed directory would not move the hash.
#   The expansion runs only on survivors (rare) so the main call keeps the same
#   invocation as the baseline writer — `comm -23` needs both sides produced
#   identically, and a global `-uall` would make every baselined untracked
#   directory's contents read as new.
#
#   WHAT THE WORKFLOW ITSELF REWRITES IS EXCLUDED — two paths, one rule.
#   Membership test: rewritten by the gate's own machinery on essentially every
#   invocation, and never authored by the work under review.
#
#     .claude/.qa-tracking/**     per-session gate bookkeeping.
#                                verify-before-stop.sh's own is_beads_or_gate_path
#                                calls it "workflow machinery, never reviewable
#                                source", and it is NOT gitignored in every
#                                install: install.sh writes that rule only when
#                                the target has no .gitignore at all, so a project
#                                that already had one has the gate's state
#                                git-visible.
#     .beads/interactions.jsonl  bd's interaction log, rewritten by EVERY bd call
#                                including the gate's own add_comment and
#                                `label add`. Measured, not assumed: it was the
#                                one path that churned in every L2 gate fixture,
#                                and it is what put `.beads/interactions.jsonl`
#                                into an approval's bound file set.
#
#   Why the rule is not optional: reconciling either makes the change-set hash a
#   function of the gate's own progress, and DEADLOCKS a cycle by construction.
#   `enter` reconciles and then writes impact-report-<tid>.json; `approve`
#   reconciles, sees that json as new, appends it, and the report it just
#   enforced freshness on is now stale against a hash the enforcement itself
#   moved. The same shape applies to a bd write landing between the two.
#
#   `.beads/issues.jsonl` is deliberately NOT excluded: it is the committed
#   ledger, a real deliverable, and bd 1.1.2 rewrites it only on an explicit
#   export — so it is stable across a cycle and belongs in the change set, which
#   is what the denylist header means by "beads state stays in the change set".
#
#   FILTERED ON THE ABSOLUTE SPELLING, because that is the string that would
#   enter the tracker and the hash, and it is what post-edit.sh filters. The
#   Stop hook's git half filters the repo-relative spelling, so the two can
#   disagree only for the `^`-anchored absolute branches of the denylist (a repo
#   living inside /tmp/claude-<session>/). There the detector over-reports
#   relative to the hash, which is the fail-closed direction.
#
#   APPEND-ONLY, under the SAME lock post-edit.sh uses, so the two writers
#   serialise where flock exists. Nothing is ever removed: this function can
#   only grow the reviewed set.
#
# KNOWN LIMITS, named rather than left latent:
#   - THE BASELINE IS SUBTRACTED AT LINE GRANULARITY, so a RE-WRITE of an
#     already-baselined path is invisible. `comm -23` compares raw porcelain
#     lines, which are not content-addressed: a path that was dirty when the
#     baseline was captured stays subtracted however much it changes afterwards.
#     It reaches neither the tracker nor change_set_hash nor the block reason,
#     and this function still returns 0. Since 94d.1 it does NOT return silently:
#     `subtracted=N` is in every observation next to `denylisted=N`, and each
#     dropped path is named (inline up to the cap, in full in
#     .claude/.qa-tracking/reconcile-subtracted.txt). The hole is unchanged; only
#     its invisibility is closed.
#     NO COMMIT IS REQUIRED; a second write in the same session is enough, which
#     makes this strictly wider than the committed-work limit below (and wider
#     than claude-workflow-plugin-dpe, which frames the hole as needing an
#     intervening commit). Inherited from the gate baseline's FORMAT, not
#     introduced here — the Stop hook's git half shares the blind spot because
#     it subtracts the same file the same way — but it BOUNDS what this function
#     can promise: for the write classes named at the top (Bash redirect, cp,
#     mv, sed -i, generator scripts) it folds in the ones whose path was CLEAN
#     at baseline capture, or whose status CODE has since changed, and only
#     those. A collapsed `?? dir/` entry that was baselined is the same
#     mechanism: a file created inside it does not surface.
#
#     THE MAGNITUDE AND THE TRIGGER, measured rather than estimated — and both
#     are larger than the "re-write of one path" shape this limit was first
#     written for (94d.1). The trigger that matters is not an incremental second
#     write; it is a SESSION BOUNDARY. SessionStart deleted changed-files.txt
#     unconditionally (including on `compact`), and the very next reconcile then
#     re-derived the WHOLE change set through this subtraction, wholesale. On
#     94d's own review that cost 16 of 26 paths at once — 62%, or 54% counted
#     over QA's independent measurement of the same tree (60 git-visible, 29
#     baseline-identical, 21 denylisted, 10 recovered). It scales with BASELINE
#     AGE, because every path that has been dirty since the last capture is a
#     line the subtraction will match: the baseline in that occurrence was ~35h
#     old, written by an earlier cycle's approve. The deletion half is fixed at
#     the deleter (session-start.sh's TRACKER-PRESERVE region); this limit is
#     what remains once the tracker survives, and it is bounded by baseline age
#     rather than by write count.
#
#     Pinned in both directions by specs/gate-baseline-v2.sh 7.6 / 7.7, with 7R
#     forcing the subtraction branch alone to prove 7.6's cause, and 7S pinning
#     that the drop is now reported. Tracked as `dpe`; NOT fixed here because
#     content-addressing the baseline is its own change-set-hash migration, and
#     the cheaper candidate (invalidate entries against the recorded head) would
#     close only the committed variant.
#   - A path git QUOTES (`"src/na\303\257ve.ts"`, control chars) is appended in
#     its quoted spelling, because the baseline is written with the same
#     quoting and `comm -23` must see identical bytes. The result over-reports
#     a path that does not literally exist — fail-closed, and logged.
#   - Work already COMMITTED is invisible to `git status`, so a tracker
#     destroyed after a commit cannot be recovered from here.
#
# THIS IS NOT A RECOVERY PATH, and the distinction is structural rather than a
# matter of degree (claude-workflow-plugin-94d.1). If changed-files.txt is LOST
# — SessionStart used to delete it unconditionally, including on `compact` — what
# this function rebuilds is necessarily a SUBSET of what was lost, and no
# refinement of the baseline, the `comm`, or the filters can change that. Measured
# on the loss that produced 94d.1: 16 of 26 paths went, through TWO mechanisms,
# and only the first is even addressable here.
#   CHANNEL A — 14 paths whose porcelain line was byte-identical to a gate-baseline
#   entry, so `comm -23` subtracted them. Visible to git; reportable; that is what
#   the accounting below exists to say out loud.
#   CHANNEL B — 2 paths GIT CANNOT SEE AT ALL: `.claude/review-config`, whose
#   content had been reverted so it was not dirty, and a
#   `.claude/.qa-tracking/review-artifact-*.json`, which the shared self-written
#   rule keeps out of the change set by design. Those two existed ONLY in the
#   tracker. `git status` is this function's only source, so they are unrecoverable
#   here in principle, not by omission.
# Channel B is why prevention has to live at the deleter (session-start.sh's
# TRACKER-PRESERVE region) and why this function's job is to ANNOUNCE that it
# reconstructed, never to imply that it restored.
#
# Sets RECONCILE_ADDED (count added), RECONCILE_SUBTRACTED (count dropped as
# already-baselined and NOT covered by the tracker), RECONCILE_SUBTRACTED_PATHS
# (that list), RECONCILE_REBUILT_FROM_EMPTY (1 when the tracker was absent-or-
# empty and a rebuild happened) and RECONCILE_OBS (human-readable).
#
# WHY THE SUBTRACTION IS REPORTED BUT DOES NOT CHANGE THE RETURN CODE. rc!=0 is
# the "cannot determine the change set" signal, and every caller treats it as
# refuse-to-proceed (approve refuses, the Stop hook blocks). Baseline subtraction
# is the baseline's PURPOSE: in a repo that was merely dirty on arrival it drops
# dozens of genuinely pre-existing paths on every call, so returning non-zero for
# it would deadlock every cycle in every dirty checkout. The refusal that DOES
# fire on it is narrower and lives in cmd_approve (error_key
# change_set_reconstructed): reconstruction from an empty tracker AND a non-empty
# subtraction, which together mean the set being bound is provably a subset.
#
# Sentinels are load-bearing: an L2 META-TEST strips every TRACKER-RECONCILE
# region and asserts the Bash-written file stops entering the tracker and the
# block reason. Do not rename them.
RECONCILE_ADDED=0
RECONCILE_OBS=""
RECONCILE_SUBTRACTED=0
RECONCILE_SUBTRACTED_PATHS=""
RECONCILE_REBUILT_FROM_EMPTY=0
RECONCILE_SUBTRACTED_FILE="$QA_TRACKING_DIR/reconcile-subtracted.txt"
# How many subtracted paths are enumerated INLINE in RECONCILE_OBS. The rest are
# counted and pointed at the sidecar. A cap is not tidiness: this string lands in
# `enter`/`approve` JSON observations, and a repo dirty on arrival can subtract
# 150 paths on every call — an unbounded list there would bury the count, which
# is the part a reader acts on.
RECONCILE_SUBTRACTED_INLINE_CAP=12
reconcile_tracker() {
    RECONCILE_ADDED=0
    RECONCILE_OBS=""
    RECONCILE_SUBTRACTED=0
    RECONCILE_SUBTRACTED_PATHS=""
    RECONCILE_REBUILT_FROM_EMPTY=0

    # The full subtracted list, durable, because RECONCILE_OBS only carries the
    # first $RECONCILE_SUBTRACTED_INLINE_CAP and two of the three callers discard
    # the string entirely on the success path (the Stop hook reads RECONCILE_OUT
    # only when rc!=0). TRUNCATED HERE, before any early return: a stale file from
    # the previous call would otherwise read as this call's answer, which is the
    # same defect class as everything else on this task. Lives under
    # .claude/.qa-tracking/, so the self-written rule keeps it out of the change
    # set and it cannot move change_set_hash.
    RECONCILE_SUBTRACTED_FILE="$QA_TRACKING_DIR/reconcile-subtracted.txt"
    : > "$RECONCILE_SUBTRACTED_FILE" 2>/dev/null || true

    if [ -z "${WORKFLOW_DENYLIST_REGEX:-}" ]; then
        log_sync_error "reconcile_tracker: workflow-denylist.sh not loaded (looked in ${_WFDL_DIR:-<unresolvable script dir>}) — refusing to append to changed-files.txt with an unknown filter, which would put build output into an append-only file"
        RECONCILE_OBS="tracker reconcile FAILED: the shared path denylist (workflow-denylist.sh) is not loaded, so which paths belong in the tracker is unknowable"
        return 1
    fi

    if ! has_git_repo; then
        RECONCILE_OBS="tracker reconcile skipped: $PROJECT_DIR is not a git checkout we can query, so there is no git-visible delta to reconcile against"
        return 0
    fi

    local status_out
    status_out=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null) || {
        log_sync_error "reconcile_tracker: 'git status --porcelain' failed in $PROJECT_DIR — the git-visible change set is unknown, so changed-files.txt cannot be proven complete and the change-set hash may certify less than the actual diff"
        RECONCILE_OBS="tracker reconcile FAILED: 'git status --porcelain' could not be read in $PROJECT_DIR, so the tracker cannot be proven complete"
        return 1
    }

    # The absolute-path prefix for repo-root-relative porcelain paths.
    local prefix="" top canon_pd canon_top
    top=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || top=""
    if [ -n "$top" ]; then
        canon_pd=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P) || canon_pd=""
        canon_top=$(cd "$top" 2>/dev/null && pwd -P) || canon_top=""
        if [ -n "$canon_pd" ] && [ "$canon_pd" = "$canon_top" ]; then
            prefix="${PROJECT_DIR%/}"
        else
            prefix="${top%/}"
        fi
    fi
    if [ -z "$prefix" ]; then
        # A bare repo, or a toplevel we cannot resolve. `git status` would
        # normally have failed already; refuse rather than guess a prefix.
        log_sync_error "reconcile_tracker: could not resolve a working-tree root for $PROJECT_DIR (rev-parse --show-toplevel empty) — cannot spell porcelain paths absolutely, so the tracker cannot be reconciled"
        RECONCILE_OBS="tracker reconcile FAILED: no resolvable working-tree root for $PROJECT_DIR"
        return 1
    fi

    # Already-tracked set, in BOTH spellings — post-edit records absolute paths
    # but a caller (or a fixture) may have seeded relative ones, and appending
    # the other spelling of a file already present is the double count this
    # function exists to avoid.
    # Built by a plain loop rather than `$( ... | sort -u )`: bash 3.2's parser
    # mis-reads `${t#"$prefix"/}` nested inside a command substitution (macOS
    # ships 3.2, and the plugin supports it), and the set is only ever probed
    # with `grep -qxF`, which does not need it sorted.
    #
    # BUILT HERE, ahead of the baseline subtraction, rather than after it as it
    # was before 94d.1: the subtraction accounting below has to know which
    # subtracted paths the tracker ALREADY covers (those are harmless) to isolate
    # the ones it does not (those are the risk class), and it runs before the
    # survivors are walked.
    local tracking="$QA_TRACKING_DIR/changed-files.txt"
    local tracked_set="" t rel
    local tracker_was_empty=1
    if [ -s "$tracking" ]; then
        tracker_was_empty=0
        while IFS= read -r t; do
            [ -z "$t" ] && continue
            tracked_set="$tracked_set$t
"
            case "$t" in
                "$prefix"/*)
                    rel="${t#"$prefix"/}"
                    tracked_set="$tracked_set$rel
"
                    ;;
            esac
        done < "$tracking"
    fi

    # Subtract the baseline. LC_ALL=C on BOTH sides: comm -23 needs one
    # collation, and the writer pins C too (see write_gate_baseline).
    #
    # EVERY read below is rc-guarded (i8cx): these assignments are the
    # change-set evidence chain, and before this a failed `sort` or `comm`
    # fell through as an EMPTY set at rc 0 — which reads as "working tree
    # clean" / "nothing new" and silently disarms BOTH approve refusals
    # downstream (tracker_unreconcilable never fires because nothing failed,
    # and change_set_reconstructed never fires because subtracted reads 0).
    # The trailing `grep -v '^$'` stages are gone rather than guarded: on
    # empty input `grep -v` exits 1 — the healthy clean-tree case, the same
    # measured trap that forbids file-wide pipefail — and no producer here
    # can emit a blank line ($status_out is non-empty porcelain when its sort
    # runs; both comm inputs are the already-guarded non-empty sets). The
    # downstream walks skip blank lines regardless. rc is captured with
    # `|| rc=$?`, never read after a bare assignment: under `set -e` the
    # assignment itself would abort before a separate `rc=$?` line ran.
    local baseline current survivors subtracted=""
    local baseline_rc=0 current_rc=0 comm_rc=0
    baseline=$( set -o pipefail; gate_baseline_entries | LC_ALL=C sort ) || baseline_rc=$?
    # RECONCILE-READ-GUARD BEGIN (i8cx)
    if [ "$baseline_rc" -ne 0 ]; then
        log_sync_error "reconcile_tracker: the gate baseline could not be read (gate_baseline_entries|sort rc=$baseline_rc) — what the baseline subtracts is unknown, so the tracker cannot be proven complete"
        RECONCILE_OBS="tracker reconcile FAILED: the gate baseline at $GATE_BASELINE_FILE could not be read (rc=$baseline_rc), so what it subtracts from the git-visible change set is unknown"
        return 1
    fi
    # RECONCILE-READ-GUARD END (i8cx)
    if [ -n "$status_out" ]; then
        current=$( set -o pipefail; printf '%s\n' "$status_out" | LC_ALL=C sort ) || current_rc=$?
    else
        current=""
    fi
    # RECONCILE-READ-GUARD BEGIN (i8cx)
    if [ "$current_rc" -ne 0 ]; then
        log_sync_error "reconcile_tracker: could not sort the git status snapshot (rc=$current_rc) — the current git-visible change set is unknown, so the tracker cannot be proven complete"
        RECONCILE_OBS="tracker reconcile FAILED: the git-visible change set could not be sorted (rc=$current_rc), so what is currently dirty is unknown"
        return 1
    fi
    # RECONCILE-READ-GUARD END (i8cx)
    if [ -z "$current" ]; then
        RECONCILE_OBS="tracker reconcile: working tree clean relative to HEAD; nothing to add (subtracted=0)"
        return 0
    fi
    if [ -z "$baseline" ]; then
        survivors="$current"
    else
        survivors=$(comm -23 <(printf '%s\n' "$current") <(printf '%s\n' "$baseline")) || comm_rc=$?
        # SUBTRACTION-ACCOUNTING BEGIN (94d.1)
        # The COMPLEMENT of the line above, and the whole point of 94d.1's
        # visibility half: `comm -12` is the set `comm -23` threw away. Before
        # this it was computed, discarded, and never mentioned — so a call that
        # dropped 16 git-visible paths and a call that dropped none produced
        # indistinguishable output.
        subtracted=$(comm -12 <(printf '%s\n' "$current") <(printf '%s\n' "$baseline")) || comm_rc=$?
        # SUBTRACTION-ACCOUNTING END (94d.1)
        # RECONCILE-READ-GUARD BEGIN (i8cx)
        if [ "$comm_rc" -ne 0 ]; then
            log_sync_error "reconcile_tracker: comm failed while subtracting the gate baseline (rc=$comm_rc) — the survivor and subtracted sets are unknown, so the tracker cannot be proven complete"
            RECONCILE_OBS="tracker reconcile FAILED: comm could not subtract the gate baseline from the git-visible change set (rc=$comm_rc), so the survivor set is unknown"
            return 1
        fi
        # RECONCILE-READ-GUARD END (i8cx)
    fi

    # The accounting clause, appended to every RECONCILE_OBS from here down.
    # DECLARED OUTSIDE the SUBTRACTION-ACCOUNTING region below so the 7SM META's
    # stripped copy stays coherent: with the region excised this stays the empty
    # string and every observation reverts EXACTLY to its pre-94d.1 text, which is
    # what makes that META measure the accounting rather than a syntax error.
    # Same discipline as post-edit.sh's _PE_RESOLVED and approve's impact_obs.
    local account_obs=""

    # SUBTRACTION-ACCOUNTING BEGIN (94d.1)
    # ---- ACCOUNT FOR WHAT THE BASELINE SUBTRACTED (94d.1) -------------------
    #
    # WHICH subtracted entries are reported, and why not all of them. A subtracted
    # path that the tracker ALREADY holds is covered by the change set either way,
    # so naming it would only dilute the count. What is reported is the residue:
    # git-visible, reviewable, dropped as pre-existing, and absent from the
    # tracker — i.e. every path that is in the working tree and outside
    # change_set_hash. That is exactly the set a lost tracker's contents fall
    # into, and also exactly the set genuine arrival dirt falls into. Reconcile
    # cannot tell those apart (that is the honest limit, stated in the readout
    # rather than resolved), so it reports the residue and says it cannot tell.
    #
    # NO `?? dir/` EXPANSION on this side, deliberately, unlike the survivors
    # walk below. A collapsed untracked directory that was baselined hides its
    # contents by the same mechanism; expanding it here would list files that were
    # never individually baselined and inflate the count with paths whose status
    # this function did not actually decide. The DIRECTORY is named instead, which
    # is the honest granularity of what was dropped.
    #
    # COST, named because this runs on every Stop: two `grep -qxF` per subtracted
    # entry, and the subtracted set can be much larger than the survivor set (in a
    # repo dirty on arrival it is most of the baseline). It is the SAME per-path
    # shape the append loop below already uses — deliberately, so the two
    # membership tests cannot drift apart — and it is skipped entirely when the
    # tracker is empty, which is the case this accounting exists for. A single
    # `grep -vxF -f` pass would be cheaper but would have to normalise every
    # tracked entry to one spelling first, which changes what the APPEND side
    # sees; that is not a change this task should make blind.
    local sub_line sub_p sub_abs
    local sub_paths="" sub_count=0
    if [ -n "$subtracted" ]; then
        while IFS= read -r sub_line; do
            [ -z "$sub_line" ] && continue
            sub_p="${sub_line#???}"
            case "$sub_p" in *" -> "*) sub_p="${sub_p##* -> }" ;; esac
            [ -n "$sub_p" ] || continue
            sub_abs="$prefix/$sub_p"
            # Same two filters the append side applies, for the same reason: a
            # denylisted or self-written path is not reviewable work, so its
            # absence from the change set is correct and reporting it is noise.
            if workflow_self_written "$sub_abs"; then
                continue
            fi
            if [[ "$sub_abs" =~ $WORKFLOW_DENYLIST_REGEX ]]; then
                continue
            fi
            # Already covered by the tracker in either spelling -> harmless.
            if [ -n "$tracked_set" ] && printf '%s\n' "$tracked_set" | grep -qxF -- "$sub_abs"; then
                continue
            fi
            if [ -n "$tracked_set" ] && printf '%s\n' "$tracked_set" | grep -qxF -- "$sub_p"; then
                continue
            fi
            sub_paths="$sub_paths$sub_abs
"
            sub_count=$((sub_count + 1))
        done <<< "$subtracted"
    fi
    RECONCILE_SUBTRACTED="$sub_count"
    RECONCILE_SUBTRACTED_PATHS="$sub_paths"
    if [ -n "$sub_paths" ]; then
        printf '%s' "$sub_paths" > "$RECONCILE_SUBTRACTED_FILE" 2>/dev/null || true
    fi

    # A rebuild from an absent-or-empty tracker. `current` is non-empty by the
    # early return above, so reaching here with an empty tracker means every path
    # the tracker ends up holding came from `git status` rather than from a
    # recorded edit.
    if [ "$tracker_was_empty" = "1" ]; then
        RECONCILE_REBUILT_FROM_EMPTY=1
    fi

    # `subtracted=N` is set unconditionally, next to `denylisted=N`, so a reader
    # can never wonder whether a zero means "none" or "not measured" — and
    # `added=0` can never again stand alone as the whole story.
    account_obs="; subtracted=$RECONCILE_SUBTRACTED"
    if [ "$RECONCILE_SUBTRACTED" -gt 0 ]; then
        local sub_shown sub_extra=0
        sub_shown=$(printf '%s' "$sub_paths" | head -n "$RECONCILE_SUBTRACTED_INLINE_CAP" | tr '\n' ' ')
        if [ "$RECONCILE_SUBTRACTED" -gt "$RECONCILE_SUBTRACTED_INLINE_CAP" ]; then
            sub_extra=$((RECONCILE_SUBTRACTED - RECONCILE_SUBTRACTED_INLINE_CAP))
        fi
        account_obs="; SUBTRACTED $RECONCILE_SUBTRACTED git-visible path(s) as already-baselined and NOT covered by changed-files.txt — they are outside the change set and outside change_set_hash. reconcile CANNOT distinguish pre-existing arrival dirt from session work whose tracker entry was lost (94d.1): $sub_shown"
        if [ "$sub_extra" -gt 0 ]; then
            account_obs="$account_obs(+$sub_extra not shown; full list in $RECONCILE_SUBTRACTED_FILE)"
        fi
    fi
    if [ "$RECONCILE_REBUILT_FROM_EMPTY" = "1" ]; then
        account_obs="$account_obs; REBUILT FROM AN EMPTY TRACKER: changed-files.txt was absent-or-empty when this reconcile ran, so every path it now holds came from 'git status', not from a recorded edit. ASSUMPTION MADE: that no tool edit had happened yet. reconcile cannot tell that from 'the tracker was destroyed', and it is NOT a recovery path — a file whose content was reverted and the gate's own artifacts are invisible to git, so a rebuild is only ever a SUBSET (94d.1)"
        # The narrow alarm, and the only sync-errors.log line this function writes
        # for the accounting. Gated on a cycle being in flight because an empty
        # tracker with no cycle open is unremarkable (a fresh session, nothing
        # recorded yet) and the Stop hook reconciles on EVERY stop — logging it
        # unconditionally would flood the log that warning 3 of session-start.sh
        # renders. With a cycle open the tracker is append-only by contract, so
        # empty means either "nothing recorded in this cycle" or "destroyed", and
        # both are worth a durable line.
        if [ -s "$QA_TRACKING_DIR/current-task" ]; then
            log_sync_error "reconcile_tracker: changed-files.txt was absent-or-empty while a gate cycle was in flight ($(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null | tr -d '[:space:]')), so the change set was REBUILT from git status alone; $RECONCILE_SUBTRACTED further git-visible path(s) were dropped as already-baselined (see $RECONCILE_SUBTRACTED_FILE). A rebuild can only be a subset — a reverted-content file and the gate's own artifacts are invisible to git (94d.1)"
        fi
    fi
    # SUBTRACTION-ACCOUNTING END (94d.1)

    if [ -z "$survivors" ]; then
        RECONCILE_OBS="tracker reconcile: every git-visible entry is already in the gate baseline (pre-existing dirt); nothing to add$account_obs"
        return 0
    fi

    local line code p abs quoted=0 denied=0
    local candidates="" expanded _exp_raw
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        code="${line:0:2}"
        p="${line#???}"
        # Rename/copy entries are "R  old -> new"; the destination is the path
        # a tracker entry would name.
        case "$p" in *" -> "*) p="${p##* -> }" ;; esac
        [ -n "$p" ] || continue
        case "$p" in '"'*) quoted=$((quoted + 1)) ;; esac
        # A collapsed untracked DIRECTORY: expand to the files inside it.
        case "$code" in
            '??')
                case "$p" in
                    */)
                        expanded=""
                        # Run from $prefix (the working-tree ROOT), not from
                        # $PROJECT_DIR: porcelain paths are root-relative, and a
                        # pathspec is CWD-relative — from a nested $PROJECT_DIR
                        # the pathspec would match nothing and every collapsed
                        # directory would silently stay collapsed.
                        if _exp_raw=$(git -C "$prefix" status --porcelain -uall -- "$p" 2>/dev/null); then
                            expanded=$(printf '%s\n' "$_exp_raw" | sed 's/^...//' | grep -v '^$' || true)
                        fi
                        if [ -n "$expanded" ]; then
                            candidates="$candidates$expanded
"
                            continue
                        fi
                        # Expansion unavailable: keep the directory entry rather
                        # than drop it (fail closed on something over nothing).
                        ;;
                esac
                ;;
        esac
        candidates="$candidates$p
"
    done <<< "$survivors"

    local to_add=""
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        abs="$prefix/$p"
        # PATHS THE WORKFLOW ITSELF REWRITES — the ONE rule, in the lib, because
        # verify-before-stop.sh's git walk must apply the IDENTICAL rule or the
        # tracker and the detector disagree about the change set (they did: the
        # tracker excluded .beads/interactions.jsonl while the detector included
        # it, which killed the F1 doc-only fast path for every change set once any
        # bd call had run). See workflow_self_written's header for the membership
        # test and for why it is not part of WORKFLOW_DENYLIST_REGEX.
        if workflow_self_written "$abs"; then
            continue
        fi
        if [[ "$abs" =~ $WORKFLOW_DENYLIST_REGEX ]]; then
            denied=$((denied + 1))
            continue
        fi
        # Already present in either spelling?
        if [ -n "$tracked_set" ] && printf '%s\n' "$tracked_set" | grep -qxF -- "$abs"; then
            continue
        fi
        if [ -n "$tracked_set" ] && printf '%s\n' "$tracked_set" | grep -qxF -- "$p"; then
            continue
        fi
        # Exact line match, not a substring test: one candidate path can be a
        # suffix of another and a `case` glob would silently drop it.
        if [ -n "$to_add" ] && printf '%s' "$to_add" | grep -qxF -- "$abs"; then
            continue
        fi
        to_add="$to_add$abs
"
    done <<< "$candidates"

    if [ -z "$to_add" ]; then
        RECONCILE_OBS="tracker reconcile: changed-files.txt already covers every reviewable git-visible path (denylisted=$denied)$account_obs"
        return 0
    fi

    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    # A tracker whose last line lacks its newline (hand-edited; post-edit.sh
    # always writes one) would otherwise get our first path concatenated onto it.
    if [ -s "$tracking" ] && [ "$(tail -c 1 "$tracking" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
        to_add="
$to_add"
    fi
    local lock="$QA_TRACKING_DIR/.changed-files.lock"
    local append_rc=0
    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 9
            printf '%s' "$to_add" >> "$tracking"
        ) 9>"$lock" || append_rc=$?
    else
        # One write() for the whole block: short appends to an O_APPEND fd do
        # not interleave, which is the same safety class post-edit.sh's
        # no-flock append relies on.
        printf '%s' "$to_add" >> "$tracking" || append_rc=$?
    fi
    if [ "$append_rc" -ne 0 ]; then
        log_sync_error "reconcile_tracker: could not append $(printf '%s' "$to_add" | grep -c . | tr -d ' ') reconciled path(s) to $tracking (rc=$append_rc) — the tracker still under-covers the git-visible change set"
        RECONCILE_OBS="tracker reconcile FAILED: append to $tracking returned rc=$append_rc$account_obs"
        return 1
    fi

    RECONCILE_ADDED=$(printf '%s' "$to_add" | grep -c . | tr -d ' ')
    RECONCILE_OBS="tracker reconciled: +$RECONCILE_ADDED git-visible path(s) that no Write/Edit hook recorded (denylisted=$denied)$account_obs"
    if [ "$quoted" -gt 0 ]; then
        log_sync_error "reconcile_tracker: $quoted porcelain entr(y|ies) carried a git-QUOTED path; they are reconciled in their quoted spelling, which over-reports a literal path that does not exist (fail-closed, see the function header)"
        RECONCILE_OBS="$RECONCILE_OBS; WARNING $quoted git-quoted path(s) reconciled in quoted spelling"
    fi
    return 0
}
# TRACKER-RECONCILE END (94d)

# 0wk.2 fix: paired with write_approved_baseline. The legacy approve path
# left changed-files.txt populated; the next post-edit.sh would append
# fresh lines on top of stale ones, and verify-before-stop.sh would treat
# the union as "must re-review". Truncating (rather than removing) keeps
# the file present so post-edit.sh's append-only path is undisturbed.
truncate_changed_files_tracker() {
    local tracking="$QA_TRACKING_DIR/changed-files.txt"
    if [ -f "$tracking" ]; then
        : > "$tracking"  # truncate, preserve file (post-edit.sh appends)
    fi
}

# F4 (Phase 4): wipe iteration counter, last test output, and any draft
# tech-debt artifacts on approval. Idempotent.
#
# Phase 4 fix pass / MATERIAL 5: the iteration counter is now keyed by
# task_id (e.g., iteration-count.<task-id>), so we wipe both the legacy
# unscoped path AND the per-task path for the task being approved. The
# task_id is passed as $1.
#
# Spec 0.2: also wipe escalation artifacts (cached test result, escalation
# comment marker) so a future cycle starts clean. 2ty adds the auto-defer
# counter to that set.
wipe_iteration_state() {
    local tid="$1"
    rm -f "$QA_TRACKING_DIR/iteration-count" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/escalated-stops" 2>/dev/null || true
    if [ -n "$tid" ]; then
        local sanitized
        sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
        # claude-workflow-plugin-gsfd fix round 3 (R3-F2, independent
        # cross-family review): bump the per-task CYCLE GENERATION counter
        # FIRST, before any of the deletions below, not last. Round 2 bumped
        # last, on the theory that a
        # concurrent Stop's generation re-check would see the state AFTER this
        # whole function finished. MEASURED wrong by the reviewer: a Stop's own
        # pre-write generation re-check can land in the WINDOW BETWEEN this
        # function's deletions (which have already run) and its bump (which
        # has not yet run) — at that exact instant the counter still reads the
        # OLD generation, so the Stop's re-check sees "unchanged" and proceeds
        # to REPOPULATE the files this call JUST deleted, with stale-cycle
        # data, under what is now the NEW cycle. Bumping FIRST closes that
        # specific ordering gap: by the time ANY deletion below can run, a
        # concurrent re-reader already sees the new generation and refuses.
        #
        # The read-modify-write itself (read current, add 1, write back) is
        # NOT atomic on its own — two overlapping wipe_iteration_state calls
        # could both read the same starting value and each publish the SAME
        # "+1" result, losing one bump (also R3-F2). Guarded with a `mkdir`
        # lock: `mkdir` is a single atomic test-and-set on every POSIX
        # filesystem this repo runs on, so at most one call at a time can hold
        # it. Best-effort and bounded (up to ~1s), matching this whole
        # function's own "a degradation, never a reason to block the gate"
        # convention elsewhere — proceeding without the lock after the bound
        # is a rare, disclosed residual (a lost bump under EXTREME concurrent
        # enter/choose contention), not a hang.
        #
        # R4-F4 fix (independent cross-family review, round 4): `mkdir` locks
        # have no built-in expiry, and this one previously recorded no
        # holder identity — if a holder died (SIGKILL, a crash) between
        # acquiring here and releasing below, the lock directory was left
        # behind FOREVER, and every LATER call would spend its own ~1s
        # budget failing to acquire it and then proceed unlocked, silently,
        # permanently, from that point on — broader than this comment's own
        # "extreme contention" framing: ONE interrupted holder was enough,
        # not sustained contention. Fixed with stale-lock recovery: the
        # winning `mkdir` now records its own pid inside the lock directory;
        # a waiter whose `mkdir` fails reads that pid and, if it is no
        # longer alive (`kill -0`), removes the stale lock and retries
        # within the SAME bounded loop rather than waiting out the full
        # budget and degrading. This does not need pid-reuse-proof
        # certainty the way tree-lease.sh's own lease identity does (R1-F2/
        # R2-F1) — the failure mode of a false "still held" reading here is
        # only ever a repeat of the PRE-fix behaviour (one more bounded,
        # disclosed unlocked degradation for THIS call), never worse, while
        # the common case (a genuinely dead holder) now self-heals instead
        # of wedging permanently.
        #
        # R5-F3 fix (independent cross-family review, round 5): R4-F4 only
        # covers a holder that got as far as recording a NUMERIC pid before
        # dying. It missed the ACQUISITION-TO-OWNER-RECORD WINDOW itself —
        # a crash or SIGKILL between the winning `mkdir` succeeding and its
        # very next line (the pid printf) landing, or a printf that fails
        # outright (a full disk, a permissions change mid-run) — which
        # leaves a lock directory with NO valid pid file: either absent
        # entirely, or present but empty/garbage from an interrupted write.
        # The pre-fix code's handling of that state was a bare no-op
        # (`''|*[!0-9]*) : ;;`) — it neither recovered the lock nor even
        # LOOKED again differently on a later iteration, so an ownerless
        # lock persisted FOREVER, wider than R4-F4's own fix: every later
        # call spent its ~1s budget, found nothing to recover, and proceeded
        # UNLOCKED, permanently, from that point on — the exact defect R4-F4
        # believed it had already closed. Two unlocked callers can then both
        # read the same starting generation and each publish the identical
        # "+1", losing a bump (the read-modify-write race this whole lock
        # exists to prevent in the first place).
        #
        # Fixed by treating "no confirmable numeric owner" as ONE recoverable
        # state regardless of whether it got there via an absent file or an
        # empty/garbage one, reclaimed after giving it exactly one retry's
        # grace (this loop's own 0.1s sleep) rather than on first sighting.
        # The grace matters: for a FEW MICROSECONDS after a genuinely live
        # winner's `mkdir` succeeds and before its own printf lands, this
        # exact state (lock dir exists, pid file not yet readable as
        # numeric) is indistinguishable from the crashed case — reclaiming
        # on the very first sighting would let a waiter steal a lock its
        # live holder is a moment from legitimately owning. By the SECOND
        # sighting, at least one full 0.1s sleep has elapsed since the first
        # — orders of magnitude longer than a single local `printf` to a
        # small file ever takes to land — so persistence past that point is
        # strong evidence the original writer will never complete it.
        local gen_file gen_lock gen_cur gen_tmp gen_lock_held _gli _gl_holder
        gen_file="$QA_TRACKING_DIR/qa-cycle-gen.$sanitized"
        gen_lock="$QA_TRACKING_DIR/qa-cycle-gen.$sanitized.lock"
        gen_lock_held="no"
        for _gli in 1 2 3 4 5 6 7 8 9 10; do
            if mkdir "$gen_lock" 2>/dev/null; then
                printf '%s' "$$" > "$gen_lock/pid" 2>/dev/null || true
                gen_lock_held="yes"
                break
            fi
            _gl_holder=""
            if [ -f "$gen_lock/pid" ]; then
                _gl_holder=$(cat "$gen_lock/pid" 2>/dev/null) || _gl_holder=""
            fi
            case "$_gl_holder" in
                ''|*[!0-9]*)
                    # R5-F3: no confirmable numeric owner (missing or
                    # empty/garbage pid file). Give it exactly one retry's
                    # grace (see the header note above for why) before
                    # reclaiming — never on the very first sighting.
                    [ "$_gli" != "1" ] && { rm -rf "$gen_lock" 2>/dev/null || true; }
                    ;;
                *) kill -0 "$_gl_holder" 2>/dev/null || rm -rf "$gen_lock" 2>/dev/null || true ;;
            esac
            sleep 0.1
        done
        gen_cur=0
        if [ -f "$gen_file" ]; then
            gen_cur=$(cat "$gen_file" 2>/dev/null) || gen_cur=""
            case "$gen_cur" in ''|*[!0-9]*) gen_cur=0 ;; esac
        fi
        gen_tmp="$gen_file.tmp.$$"
        if printf '%s' "$((gen_cur + 1))" > "$gen_tmp" 2>/dev/null; then
            mv -f "$gen_tmp" "$gen_file" 2>/dev/null || rm -f "$gen_tmp" 2>/dev/null || true
        fi
        [ "$gen_lock_held" = "yes" ] && rm -rf "$gen_lock" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/iteration-count.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/last-test-rc.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/last-failed-checks.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/last-runner.$sanitized" 2>/dev/null || true
        # claude-workflow-plugin-j7kk (9xl4 cheap half): the skip-when-unchanged
        # cache — verify-before-stop.sh's record_verified_state/
        # verified_state_unchanged. MUST die with the rest of the per-cycle
        # state: a stale record surviving `enter` or `choose continue` could
        # match a NEW cycle's tree by coincidence (extremely unlikely, but the
        # other four caches in this function are wiped on the same belt-and-
        # braces reasoning, not because a collision is likely) and replay a
        # PREVIOUS cycle's result instead of running the fresh one this
        # transition exists to demand.
        rm -f "$QA_TRACKING_DIR/last-verified-state.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/escalation-posted.$sanitized" 2>/dev/null || true
        # 2ty: the auto-defer counter (Stops that fired while qa-escalated was
        # already set). It MUST die with the rest of the per-cycle state: a count
        # that survived `enter` or `choose continue` would make the FIRST
        # escalated Stop of the next cycle auto-defer immediately, and
        # auto-defer's consequence is that the following Stop is ALLOWED.
        rm -f "$QA_TRACKING_DIR/escalated-stops.$sanitized" 2>/dev/null || true
        # claude-workflow-plugin-gsfd R1-F6: the captured-tail cache (the
        # ACTUAL point-in-time TEST_FAIL_TAIL/LINT_FAIL_TAIL/TYPE_FAIL_TAIL
        # text a cached replay shows instead of only the "see <stable log>"
        # pointer) is per-cycle state on the same footing as last-failed-
        # checks above — it MUST NOT survive to a NEW cycle, or a stale
        # tail from a previous cycle's failure could be shown under a
        # DIFFERENT cycle's replayed verdict.
        rm -f "$QA_TRACKING_DIR/last-test-tail.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/last-lint-tail.$sanitized" 2>/dev/null || true
        rm -f "$QA_TRACKING_DIR/last-type-tail.$sanitized" 2>/dev/null || true
    fi
    # claude-workflow-plugin-gsfd: these three are now an ADVISORY
    # human/agent-facing convenience copy of the last run's output
    # (verify-before-stop.sh's TEST_LOG_STABLE/LINT_LOG_STABLE/TYPE_LOG_STABLE),
    # not the load-bearing capture path — that moved to a per-run scratch
    # directory precisely so a wipe landing here mid-capture (this function
    # running concurrently with another session's Stop hook) can no longer
    # delete a log a live run is still writing. Four measured occurrences of
    # exactly that collision (this rm racing a concurrent verify-before-stop.sh)
    # are what gsfd's member 1 fixes; this wipe stays because a stale
    # convenience copy from a previous cycle is still worth clearing, and a
    # race on it now costs nothing but a stale display for one cycle.
    rm -f "$QA_TRACKING_DIR/last-test-output.log" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/last-lint-output.log" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/last-type-output.log" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/tech-debt-draft.md" 2>/dev/null || true
}

# V3 (claude-workflow-plugin-jio.1): drop the review round's on-disk scratch
# files once an approval completes. The durable record is the Beads comment
# set (REVIEW-ARTIFACT / RESOLVED / ARBITRATION) — these JSON files are only
# the hand-off medium between the request author, the reviewer, and the record
# writer, so leaving them behind means the next cycle's reviewer can pick up a
# previous round's artifact by path and record it as if it were fresh.
#
# Two naming conventions are cleaned because two producers exist: qa.md's
# section 6-prime writes `review-request-<task-id>.json` with the RAW id,
# while the driver used to write `review-artifact-<sanitized>-r<n>.json` here
# too. We remove both spellings rather than assume. Idempotent and silent by
# design.
#
# WHAT THIS DELIBERATELY DOES NOT REACH (v5 D2 / claude-workflow-plugin-rqer):
# the canonical review-artifact copy now lives OUTSIDE this directory, at
# $REVIEW_ARTIFACT_SUBDIR (docs/reviews/) — see review_artifact_path_for's
# header for why. Nothing below globs that directory, and it must not start:
# that copy is the evidence the artifact_hash= binding above was made
# against, so it has to outlive the cycle exactly as
# completion-payload-<tid>.json and impact-report-<tid>.json already do (see
# the COMPLETION CONTRACT note earlier in this file). The scratch-file wipe
# below is scoped to $QA_TRACKING_DIR alone, by construction, not by omission.
wipe_review_artifacts() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    local sanitized f
    sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
    rm -f "$QA_TRACKING_DIR/review-request-$tid.json" 2>/dev/null || true
    rm -f "$QA_TRACKING_DIR/review-request-$sanitized.json" 2>/dev/null || true
    # Iteration-suffixed artifacts. The `[ -e ]` guard handles the no-match
    # case (bash leaves the literal pattern when nothing matches).
    for f in "$QA_TRACKING_DIR/review-artifact-$tid"-r*.json \
             "$QA_TRACKING_DIR/review-artifact-$sanitized"-r*.json; do
        [ -e "$f" ] && rm -f "$f" 2>/dev/null
    done
    return 0
}

# Spec 0.2: best-effort label clears for escalation labels. Used by approve,
# enter, and the choose subcommand for the "continue"/"approve" paths.
# We intentionally swallow errors — these labels may not be present and
# bd's remove-when-absent path is a no-op.
remove_escalation_labels() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    remove_label "$tid" "qa-escalated" 2>/dev/null || true
    remove_label "$tid" "qa-deferred" 2>/dev/null || true
}

# Spec Phase A: helpers for rubric labels. Kept separate from the escalation
# helper because the lifecycles are independent — a rubric verdict can be
# satisfied without ever entering escalation, and vice versa. Best-effort
# semantics match remove_escalation_labels.
remove_rubric_pending() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    remove_label "$tid" "rubric-pending" 2>/dev/null || true
}

remove_rubric_satisfied() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    remove_label "$tid" "rubric-satisfied" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# THE ONE TERMINAL-LABEL TRANSITION (8zi, l1r.3, jue).
#
# Every label the gate sets and clears inside one review cycle. A terminal label
# (qa-approved / qa-blocked) is the verdict of a cycle; the rest are its
# in-flight state. Callers name what they clear, and set_terminal_label refuses a
# name that is not in this set — see the guard for why silence is the failure mode
# that has to be designed out here specifically.
#
# rubric-satisfied IS DELIBERATELY NOT IN THIS SET, and its absence is the
# mechanism that protects it rather than a comment asking people to be careful.
# It is the audit trail of the grader verdict that backed an approval, which is
# why cmd_approve preserves it (the had_rubric_satisfied capture, the three-way
# "rubric-satisfied preserved (audit trail)" observation, and the
# [rubric mismatch: graded=... approved=...] override token that logs a
# sync_error when the satisfied verdict binds a different change set than the
# approval). cmd_enter owns the only clears, and bjx made them conditional on the
# verdict's change_set_hash. Because rubric-satisfied is not a member here, a
# future call site that tried to sweep it is REFUSED at the guard below instead of
# quietly destroying that trail.
QA_CYCLE_LABELS="qa-approved qa-blocked qa-gate-entered qa-pending qa-escalated qa-deferred rubric-pending"

# set_terminal_label's out-params, declared at file scope so a caller can read
# them without depending on the call having reached any particular branch.
#   TERMINAL_SWEEP_PHASE   "" | usage | add_terminal | sweep   (which step failed)
#   TERMINAL_SWEEP_REMOVED space-delimited labels actually removed (present -> gone)
#   TERMINAL_SWEEP_OBS     human-readable account, for the caller's envelope
TERMINAL_SWEEP_PHASE=""
TERMINAL_SWEEP_REMOVED=""
TERMINAL_SWEEP_OBS=""

# restore_labels <task-id> <snapshot> — put the label set back exactly.
#
# <snapshot> is a get_labels string (comma-joined). Both directions are applied:
# anything the snapshot had and the task no longer does is re-added, anything the
# task has and the snapshot did not is removed. Then the result is COMPARED back
# against the snapshot, so the restore has a provable postcondition rather than a
# best-effort one.
#
# The byte comparison is a set comparison here, MEASURED not assumed: bd 1.1.2
# returns labels sorted, and a remove-then-re-add of one label reproduces the
# identical joined string. If a future bd returned insertion order instead, this
# comparison could report a false failure on a correctly restored SET — which only
# ever degrades the message, never the outcome: the caller is already on its
# failure path and already exits 3 either way.
restore_labels() {
    local tid="$1" snapshot="$2"
    local current rc=0 l
    # claude-workflow-plugin-k6re R17 class sweep: bare quoted command-
    # substitution assignment under `set -e` (line 196) -- if get_labels
    # returned non-zero (bd unreachable, task vanished mid-rollback), this
    # line would abort the whole process before `current` was ever compared
    # to anything. THIS function is called DIRECTLY (never through `$(...)`),
    # so — unlike get_labels itself, whose own internal guard turned out to
    # be behaviour-preserving rather than defect-fixing, see its header,
    # corrected under R19-F1 — it is restore_labels' OWN calling context
    # that determines whether this line is at real risk, not command-
    # substitution inertness.
    # REACHABILITY: this function's one caller (set_terminal_label, a few
    # hundred lines below) invokes it as `if restore_labels ...; then`,
    # which transitively exempts this whole body from `set -e` for that
    # call — so this specific line was not reachable through the one path
    # that exists today (checked, not assumed). Guarded anyway: that is a
    # property of set_terminal_label's OWN calling convention, not a
    # contract restore_labels documents or enforces, and `|| true` accepts
    # an empty `current` on failure, which this function's own remaining
    # logic already treats safely (an empty snapshot-vs-current diff adds/
    # removes nothing).
    current="$(get_labels "$tid")" || true
    local IFS=,
    for l in $snapshot; do
        [ -n "$l" ] || continue
        case ",$current," in
            *",$l,"*) ;;
            *) add_label "$tid" "$l" || rc=1 ;;
        esac
    done
    for l in $current; do
        [ -n "$l" ] || continue
        case ",$snapshot," in
            *",$l,"*) ;;
            *) remove_label "$tid" "$l" || rc=1 ;;
        esac
    done
    [ "$(get_labels "$tid")" = "$snapshot" ] || rc=1
    return $rc
}

# set_terminal_label <task-id> <terminal-label> [<clear-label> ...]
#
# Sets <terminal-label> and clears each <clear-label> that is present, as one
# transition: on any failure the label set is restored to what it was before the
# call and a non-zero status is returned. Callers turn that into exit 3.
#
# WHY THIS EXISTS. cmd_approve used to walk the transition step by step, and the
# steps were not exhaustive across cycles: a block -> fix -> approve round trip
# ended with the task carrying BOTH qa-approved and qa-blocked, because approve
# cleared qa-gate-entered, qa-pending, the escalation pair and rubric-pending but
# never the previous cycle's terminal label. Observed live four times (uvk, q7n,
# 94d, and qzv.1 where the gate's own reviewer removed the label by hand mid-
# approval), which is the argument for one function over one more removal: the
# defect is not a missing line, it is that "what a cycle clears" was expressed as
# a list of independent steps that a future label can be added without.
#
# ORDER: the terminal label goes on FIRST, then the sweep. That is the gz3
# ordering rule the step-by-step version already followed, kept deliberately: the
# approval RECORD is written before this call, so from the moment the terminal
# label lands the {record, label} pair is coherent and a concurrent Stop sees
# either no approval yet or a complete one. The transient state this produces on
# approve is {qa-approved, qa-blocked} — the 8zi state — for the width of one bd
# call. Every reader in the tree resolves that to `approved`, because all four
# test qa-approved first: cmd_status, epic-gate.sh's qa_state_of, and
# statusline.sh's two label readers. Sweeping first would instead open a window
# with NO terminal label, which those same readers resolve to `entered` or `none`.
set_terminal_label() {
    local tid="$1" terminal="$2"
    shift 2 2>/dev/null || true
    TERMINAL_SWEEP_PHASE=""
    TERMINAL_SWEEP_REMOVED=""
    TERMINAL_SWEEP_OBS=""

    if [ -z "$tid" ] || [ -z "$terminal" ]; then
        TERMINAL_SWEEP_PHASE="usage"
        TERMINAL_SWEEP_OBS="set_terminal_label: <task-id> and <terminal-label> are both required"
        return 1
    fi

    # THE MEMBERSHIP GUARD. Refuse any label outside QA_CYCLE_LABELS rather than
    # issue the removal, because a typo'd or non-cycle label is the one error here
    # with NO observable symptom: bd exits 0 removing a label a task never had,
    # remove_label's read-back then finds it absent and also reports success, and
    # the sweep records a clean transition it never performed. Refusing converts
    # that silence into a usage error at the call site.
    local want
    for want in "$terminal" "$@"; do
        case " $QA_CYCLE_LABELS " in
            *" $want "*) ;;
            *)
                TERMINAL_SWEEP_PHASE="usage"
                TERMINAL_SWEEP_OBS="set_terminal_label: '$want' is not a QA cycle label (the set is: $QA_CYCLE_LABELS), and a removal of a non-member cannot be distinguished from success — refusing instead of reporting a transition that did not happen"
                return 1
            ;;
        esac
    done

    # SNAPSHOT BEFORE ANY MUTATION. This is what makes the rollback real rather
    # than a hand-maintained inverse of the steps above it.
    #
    # claude-workflow-plugin-k6re R17 class sweep: same bare-quoted-
    # substitution-under-set-e hazard as restore_labels' own `current=`, a
    # few dozen lines above. REACHABILITY: this function's only two callers
    # (cmd_approve, cmd_block) both invoke it as `if ! set_terminal_label
    # ...; then`, which transitively exempts this entire body from `set -e`
    # for those calls — checked directly, including an A/B that reverted
    # only this guard and ran `qa-gate.sh block <nonexistent-id>` through
    # it: no abort, the exact same clean refusal envelope either way. Not
    # reachable through either existing caller today, guarded anyway for
    # the same reason restore_labels' own `current=` is: `|| true`, an
    # unreadable pre-call snapshot degrades to "<none>" downstream via the
    # existing `${snapshot:-<none>}` defaults used everywhere below, never
    # to a bare process abort — a property this function should hold on
    # its own, not one it should have to borrow from whoever happens to
    # call it.
    local snapshot
    snapshot="$(get_labels "$tid")" || true

    # Phase 1: the terminal label. Verified with has_label for the same reason
    # remove_label verifies (l1r.3) — bd's exit status is not evidence.
    if ! add_label "$tid" "$terminal" || ! has_label "$tid" "$terminal"; then
        TERMINAL_SWEEP_PHASE="add_terminal"
        TERMINAL_SWEEP_OBS="failed to set $terminal on $tid; no labels changed (pre-call set: ${snapshot:-<none>})"
        return 1
    fi

    # Phase 2: the sweep. has_label first so TERMINAL_SWEEP_REMOVED names only
    # labels that were PRESENT and are now gone — that is the semantics the
    # approve envelope's `removed qa-gate-entered=` / `removed qa-pending=`
    # counters have always reported, and readers grep them.
    local lbl
    for lbl in "$@"; do
        [ -n "$lbl" ] || continue
        [ "$lbl" = "$terminal" ] && continue
        has_label "$tid" "$lbl" || continue
        if remove_label "$tid" "$lbl"; then
            TERMINAL_SWEEP_REMOVED="$TERMINAL_SWEEP_REMOVED $lbl"
            continue
        fi
        TERMINAL_SWEEP_PHASE="sweep"
        TERMINAL_SWEEP_REMOVED=""
        local restore_obs=""
        if restore_labels "$tid" "$snapshot"; then
            restore_obs="pre-call label set restored exactly (${snapshot:-<none>})"
        else
            # claude-workflow-plugin-k6re R17 class sweep: the two
            # `$(get_labels "$tid")` reads below used to be re-run live,
            # inline, inside a plain (mixed literal+substitution) assignment
            # and inside a function-call argument respectively. The
            # assignment form is the SAME bare-command-substitution-under-
            # set-e hazard as every other get_labels call site fixed this
            # round (POSIX: the exit status of an assignment whose value
            # contains a command substitution IS that substitution's exit
            # status, quoting and surrounding literal text notwithstanding).
            # Same reachability caveat as this function's own `snapshot=`
            # above: this whole function is currently only ever entered via
            # `if ! set_terminal_label ...; then`, which transitively
            # exempts this branch too, so this was not an actively firing
            # abort through either existing caller — but this branch is
            # specifically the DIAGNOSTIC for an already-degraded rollback,
            # exactly the wrong place to depend on a caller-side accident
            # for whether it can even run to completion. Captured ONCE into
            # a local, guarded, and reused for both messages — also removes
            # a redundant second `bd show` for the same fact.
            local now_labels=""
            now_labels="$(get_labels "$tid")" || now_labels="<unreadable>"
            restore_obs="WARNING the restore itself did not complete: labels now read '$now_labels' against a pre-call set of '${snapshot:-<none>}' — reconcile by hand before re-running"
            log_sync_error "set_terminal_label: rollback INCOMPLETE on $tid after failing to remove $lbl; pre-call='${snapshot:-<none>}' now='$now_labels'"
        fi
        TERMINAL_SWEEP_OBS="failed to remove $lbl after $terminal was set; rolled back — $restore_obs"
        return 1
    done

    TERMINAL_SWEEP_REMOVED="${TERMINAL_SWEEP_REMOVED# }"
    TERMINAL_SWEEP_OBS="$terminal set; cleared [${TERMINAL_SWEEP_REMOVED:-none}] from the cycle set"
    return 0
}
# ---------------------------------------------------------------------------

# G2.n6d (claude-workflow-plugin-llh.2): mechanical impact-report helpers.
#
# The report file is the deterministic impact_of artifact that the QA
# agent cannot skip: enter generates it, approve refuses without a fresh
# one. Path uses the same task-id sanitisation as the iteration counter.
IMPACT_REPORT_SCRIPT="$PROJECT_DIR/.claude/scripts/impact-report.sh"

# Phase V2 (1vq.1): the ONE reviewer-record validator/counter. review-record
# validates artifacts through this subprocess rather than carrying a second
# schema validator (mirrors how compute_change_set_hash defers to
# impact-report.sh --hash-only). This script is reviewer-transport-agnostic.
REVIEW_CHECK_SCRIPT="$PROJECT_DIR/.claude/scripts/review-check.sh"

impact_report_path_for() {
    local sanitized
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/impact-report-%s.json' "$QA_TRACKING_DIR" "$sanitized"
}

# llh.18 (red-team P0/P1): the CANONICAL change-set hash, sourced from the
# ONE place that defines the canonicalisation — impact-report.sh --hash-only.
# We deliberately do NOT re-implement the sort/denylist/sha here (the
# denylist regex already lives in 3 copies; a 4th would be a fresh drift
# surface). Printing empty on any failure is intentional: the caller decides
# whether an unverifiable hash is fatal (approve's refusal block) or merely
# omits the change-set binding (best-effort comment write).
compute_change_set_hash() {
    [ -f "$IMPACT_REPORT_SCRIPT" ] || { printf ''; return 1; }
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$IMPACT_REPORT_SCRIPT" --hash-only 2>/dev/null || printf ''
}

# bjx: the literal impact-report.sh prints when NEITHER shasum NOR sha256sum is
# on PATH (see its sha256_stdin). It is a non-empty string, so every `[ -n
# "$h" ]` guard in this file reads it as a usable hash — and, being CONSTANT, it
# compares EQUAL to itself across two calls. That is harmless where a hash is
# only recorded, and NOT harmless where two hashes are compared to decide
# whether a verdict still covers the current work: on such a host the rubric
# preservation guard would match unconditionally. Both the writer and the reader
# below therefore treat this value as "no hash", which is what the surrounding
# contract already claims ("omitted, not faked, when the hash cannot be
# computed"). Named once so the two sites cannot drift apart.
#
# Deliberately NOT a fix to the sentinel itself: impact-report.sh owns the
# canonicalisation and its degraded-mode return is shared with approve and the
# Stop hook, so changing it belongs to that script's contract, not to this one.
CHANGE_SET_HASH_UNAVAILABLE="sha256-unavailable"

# bd_show_with_comments <task-id> — `bd show --json` that always carries
# comment BODIES, across the supported bd range.
#
# bd 1.1.2 stopped inlining comments in `bd show --json`: it returns a
# `comment_count` integer, and the bodies need the new --include-comments flag.
# bd 0.47.x has no such flag and exits 1 ("unknown flag: --include-comments"),
# but inlines .comments already. So try the new form, fall back to the plain
# one — pin the CHAIN, not the leg, exactly as add_comment() does for
# `bd comments add || bd comment add`. Callers keep the usual
# `(if type=="array" then .[0].comments else .comments end) // []` accessor,
# which reads both shapes correctly. Never fails the caller.
#
# Only readers of .comments need this. get_labels() and the other
# .labels/.status/.notes readers must NOT use it: the flag's own help warns it
# "may be slow on issues with many comments", and those fields are unaffected.
bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

# design_comments_json <tid> — the comment stream for <tid> as a compact JSON
# array on stdout, rc 0 — but ONLY when retrieval can be PROVEN. rc 3 with no
# stdout otherwise. THE STRICT SIBLING of bd_show_with_comments above, and the
# one every DESIGN reader uses (xsu1 H2R2-F1).
#
# WHY THE LEGACY HELPER IS WRONG FOR DESIGN READERS. bd_show_with_comments
# never fails its caller, and its callers all read `.comments // []` — which
# converts a response that OMITS the comment stream into a confirmed-empty
# one. Measured on bd 1.2.2 (this repo's own store, 2026-08-25): a plain
# `bd show --json` on a task carrying 13 comments returns comment_count=13
# and NO comments key at all. So the moment the --include-comments leg fails
# (old bd, transient failure), the fallback leg "succeeds" while silently
# dropping every record — and for the design readers a dropped stream used to
# read as no-DESIGN-ARTIFACT / no-binding / no-verdict, each of which maps to
# a PERMISSIVE downstream answer (design-gate-precheck "ready",
# design-unit-bind "no existing binding", design-status
# "no_design_attempted"). The legacy readers keep the legacy helper by
# documented design: their empty answers are either fail-closed downstream
# (completion/grilling readers) or deliberately fail-open with the reason
# stated at their own definition (recorded_approval_hashes, whose empty
# answer makes approve write a FRESH record rather than claim idempotency).
#
# THE PROOF RULE, form-independent (measured, not assumed — BOTH bd 1.2.2
# show forms omit `comments` on a zero-comment task, so requiring the
# explicit array alone would refuse every pristine task):
#   - an EXPLICIT `comments` array proves the stream was retrieved (modern
#     --include-comments, or old bd inlining), OR
#   - `comment_count == 0` proves there was nothing to retrieve.
# Anything else — comment_count > 0 with no array (the masquerade above), no
# count and no array, a non-object task, unparseable output — is rc 3: the
# stream was NOT retrieved, which is not the same claim as "retrieved and
# empty". A malformed individual RECORD is still each reader's own business
# (its anchored capture drops it — a determined answer); this rule is only
# about whether the STREAM those captures run over was actually obtained.
#
# A FAILING first leg's partial stdout is DISCARDED before the fallback runs
# — unlike a bare `a || b` chain inside one command substitution, where both
# legs' output concatenates.
design_comments_json() {
    local tid="$1"
    [ -n "$tid" ] || return 3
    command -v bd >/dev/null 2>&1 || return 3
    local raw=""
    raw=$(bd show "$tid" --json --include-comments 2>/dev/null) || raw=""
    if [ -z "$raw" ]; then
        raw=$(bd show "$tid" --json 2>/dev/null) || raw=""
    fi
    [ -n "$raw" ] || return 3
    local out="" out_rc=0
    out=$(printf '%s' "$raw" | jq -ce '
        # design-comments proven-retrieval read (xsu1 H2R2-F1)
        (if type == "array" then .[0] else . end) as $t
        | if ($t | type) != "object" then error("task-not-an-object")
          elif (($t.comments? // null) | type) == "array" then $t.comments
          elif (($t.comment_count? // null) == 0) then []
          else error("comment-stream-not-retrieved")
          end
    ' 2>/dev/null) || out_rc=$?
    if [ "$out_rc" -ne 0 ] || [ -z "$out" ]; then
        return 3
    fi
    printf '%s' "$out"
    return 0
}

# gz3 (v4.1 U1): the approval records THIS task already carries — one
# change_set_hash per `QA-GATE APPROVED ... change_set_hash=<h> ...` comment.
#
# The `select` + `capture` pair below is BYTE-IDENTICAL to
# verify-before-stop.sh's task_has_matching_approval_record. That is deliberate
# and load-bearing: this is the WRITER reading its own records back to decide
# whether an approval already covers the current change set, and if it used a
# looser or stricter grammar than the reader that decides RELEASE, the two would
# disagree about what counts as an approval — which is the class of bug gz3 is.
# The parity is asserted textually (both expressions extracted from the two
# scripts and compared) in
# .claude/tests/component/specs/approve-idempotency.sh.
#
# Never fails the caller: no bd, no task, unparseable JSON -> empty output,
# rc 0. An empty answer means "no record found", which makes approve PROCEED
# (write a fresh binding) rather than claim idempotency it cannot prove.
#
# APPROVAL-SELECTOR-ANCHOR (claude-workflow-plugin-yrij): `select(test(...))`
# below is ANCHORED at `^` — see verify-before-stop.sh's
# task_has_matching_approval_record for the full rationale (this expression
# is byte-identical to that one by the parity contract above, so the fix and
# its evidence live there once rather than being re-derived at every call
# site). One-line summary: unanchored, a comment whose first line is ordinary
# prose and whose LATER line fabricates a `QA-GATE APPROVED ...
# change_set_hash=<h> ...` satisfied this exact selector with no
# `qa-gate.sh approve` ever having run — which for THIS function meant a
# forged hash could satisfy task_has_approval_record_for and make cmd_approve
# treat a change set as already-covered (idempotent no-op, nothing
# re-verified) when no genuine approval had ever bound it.
recorded_approval_hashes() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    command -v bd >/dev/null 2>&1 || return 0
    bd_show_with_comments "$tid" \
        | jq -r '
            (if type == "array" then .[0].comments else .comments end) // []
            | .[].text
            | select(test("^QA-GATE APPROVED .*change_set_hash="))
            | capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h
        ' 2>/dev/null || true
    return 0
}

# gz3: does <tid> already carry an approval record bound to <hash>?
# An empty <hash> never matches (an unverifiable hash must not read as covered).
task_has_approval_record_for() {
    local tid="$1" hash="$2"
    [ -n "$hash" ] || return 1
    recorded_approval_hashes "$tid" | grep -qxF "$hash"
}

# bjx (v4.1 U1): the change set the task's CURRENT rubric verdict was graded
# against — empty unless the LATEST RUBRIC record is a `satisfied` one AND it
# carries a change_set_hash.
#
# Same shape, and the same reason, as recorded_approval_hashes above. llh.18
# stopped believing that the qa-approved LABEL meant "approved" because a label
# says an event happened and says nothing about WHICH files it covered;
# rubric-satisfied is the same kind of label, and `enter` needs the second
# question answered before it can tell a verdict that still covers the current
# work from one left over from a previous change set.
#
# Three deliberate properties:
#   - LATEST-WINS, not latest-satisfied-wins, and — R2-F3 — not last-PARSEABLE
#     either. A `satisfied` later superseded by a `needs_revision` must not read
#     as bound: the needs_revision path leaves labels alone (rubric-satisfied
#     would still be sitting on the task), so keying on "is there a satisfied
#     record anywhere" would resurrect an overruled verdict.
#
#     The first version of this got the SELECTOR wrong in a way that produced
#     exactly that resurrection. It applied `capture` across every comment and
#     took `last` of the RESULTS, so an unparseable latest record simply fell
#     out of the array and `last` silently returned an OLDER one. A `satisfied`
#     iteration 1 followed by a `needs_revision` iteration `1.5` (the writer
#     accepted any JSON number; the reader requires `[0-9]+`) therefore kept the
#     stale satisfied hash across re-entry. Reproduced, with an integer control.
#
#     So: SELECT the latest record FIRST (every comment that starts a RUBRIC
#     record), and only then parse it. An unparseable latest record now yields
#     unbound — stale — instead of deferring to its predecessor. This half is
#     the load-bearing one: validating `iteration` at the writer (which we also
#     do, below) cannot help for a record the writer never created — a legacy
#     one, or a hand-written comment — and that case was reproduced on the
#     shipped script. Pinned with a META in section J of
#     .claude/tests/component/specs/rubric-binding.sh.
#
#     `startswith("RUBRIC ")` rather than a regex: the selector must not itself
#     be a place where a metacharacter can change the meaning. A comment that
#     merely QUOTES a record mid-text does not start with the prefix and so is
#     not a record — correct, a quoted mention must not invalidate a verdict.
#   - ANCHORED at ^, walking the whole machine prefix rather than grepping for
#     the token anywhere on the line. The line's tail is the grader's free-text
#     summary; the anchor is what stops a summary that happens to contain the
#     token's spelling from being read as a binding. jq's `^` is STRING-anchored
#     (Oniguruma, no `m` flag), so a multi-line comment whose interior line
#     starts with a RUBRIC record does not match either — load-bearing, because
#     agents do paste RUBRIC text into ordinary comments.
#   - The version class is `[A-Za-z0-9._+-]+`, the SAME class cmd_grade_record
#     validates `.rubric_version` against, and the reason both exist is a
#     forgery QA reproduced end-to-end. `rubric_version` used to be validated
#     only as "non-empty string" and is interpolated into the record with spaces
#     around it, so a crafted version — `1 iteration 1: satisfied
#     change_set_hash=<real>` — moved the record's FIRST colon into the injected
#     text. The parse then read the injected prefix instead of the real one and
#     a `needs_revision` record came back `satisfied` AND bound. The writer is
#     where that is CLOSED (a class with no spaces and no colon cannot relocate
#     anything); this class is the reader half of the same contract, so the two
#     grammars agree about what a version may be. Section F of
#     .claude/tests/component/specs/rubric-binding.sh asserts the two spellings
#     are identical, extracted from both sites.
#     A record whose version is outside the class reads as UNBOUND, which
#     clears — the safe direction, and the pre-bjx behaviour.
#   - The sentinel hash is refused. See CHANGE_SET_HASH_UNAVAILABLE: on a host
#     with no sha tool the "hash" is a constant, so it would compare equal to
#     itself and preserve unconditionally. It is treated as no binding at all.
#
# The hash group is OPTIONAL so a pre-bjx record (no token) matches the record
# grammar and answers "" rather than not matching at all — the distinction
# never reaches the caller, but it keeps the expression honest about which
# records it recognises.
#
# NOT defended against, and inherited rather than introduced here: an agent with
# arbitrary shell can `bd comments add` a well-formed RUBRIC record by hand.
# That is the same threat-model boundary llh.18 documents for the approval
# record — this raises the bar from "a label" to "a change-set-bound record",
# it is not a cryptographic sandbox. What the writer-side validation closes is
# the strictly worse case: forging through the tool's own validated input.
#
# Never fails the caller: no bd, no task, unparseable JSON -> empty, rc 0.
latest_satisfied_rubric_hash() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    command -v bd >/dev/null 2>&1 || return 0
    bd_show_with_comments "$tid" \
        | jq -r --arg unavailable "$CHANGE_SET_HASH_UNAVAILABLE" '
            [ (if type == "array" then .[0].comments else .comments end) // []
              | .[].text
              | select(startswith("RUBRIC "))
            ]
            | last
            | if . == null then ""
              else
                ( [ capture("^RUBRIC (?<v>[A-Za-z0-9._+-]+) iteration (?<n>[0-9]+): (?<verdict>[A-Za-z_]+)( change_set_hash=(?<h>[A-Za-z0-9-]+))?") ]
                  | last
                  | if . == null then ""
                    elif .verdict != "satisfied" then ""
                    elif (.h // "") == $unavailable then ""
                    else (.h // "") end )
              end
        ' 2>/dev/null || true
    return 0
}

# gz3: the change_set_hash of the PERSISTED impact report for <tid>, or empty.
persisted_report_hash() {
    local report
    report=$(impact_report_path_for "$1")
    [ -f "$report" ] || { printf ''; return 0; }
    jq -r '.change_set_hash // empty' "$report" 2>/dev/null || printf ''
    return 0
}

# gz3: the hash an existing approval must carry for THIS approve to be a
# genuine no-op — i.e. the change set this approve would bind.
#
# Normally that is the live recompute. The exception is the state a PREVIOUS
# approve leaves behind: approve TRUNCATES changed-files.txt (0wk.2), so a
# recompute in this checkout answers with the EMPTY-LIST hash and the tracker no
# longer witnesses what was approved. LESSONS.md records the rule that follows
# from that ("any cross-checkout or after-the-fact verification must read the
# PERSISTED record — impact-report-<tid>.json, which survives approve — never
# recompute"), and this is an after-the-fact verification: with an empty tracker
# the persisted report is the only surviving witness of the approved change set.
#
# Consequence, and the reason the split exists: a plain double `approve` stays an
# idempotent no-op (report hash == the recorded hash), while an approve run after
# the change set MOVED compares against the live recompute and therefore
# proceeds. Always rc 0 — compute_change_set_hash returns 1 when
# impact-report.sh is missing, and a bare `x=$(f)` whose RHS exits non-zero
# aborts the script under `set -e` (line 70).
#
# KNOWN RESIDUAL of the empty-tracker arm, reproduced and pinned (section H of
# specs/approve-idempotency.sh): when the tracker is empty AND real
# un-baselined dirt exists — work written by a helper rather than the Edit tool,
# which never reaches changed-files.txt (LESSONS.md / bi3.2) — the Stop hook
# blocks on the git half of its predicate while the persisted report still
# witnesses the PREVIOUS approval, so a bare `approve` no-ops and the block
# stands. Following the remediation the block PRINTS resolves it: step 2
# (impact-report.sh) re-persists the report, after which no record binds it and
# approve proceeds. That is why the source of the reference hash is named in the
# no-op's observations — the operator can see that regenerating the report is
# the move. Closing it inside approve would mean a second copy of the Stop
# hook's baseline-relative git walk, i.e. a second thing to drift; the one place
# that walk lives is verify-before-stop.sh's reviewable_changes().
# RETURNS BY GLOBAL, and prints nothing, deliberately: the caller needs the hash
# AND the name of the reference it came from, and `h=$(f)` runs f in a SUBSHELL
# where the second value dies silently — the envelope then reads "... via )".
# (That is not hypothetical: this function was written to print, section H's
# assertion on the source name caught it immediately.) Same reason
# verify-before-stop.sh hands APPROVAL_RECORD_DETAIL back through a global.
IDEM_REF_HASH=""
IDEM_REF_SOURCE=""
set_idempotency_reference() {
    local tid="$1"
    IDEM_REF_HASH=""
    if [ -s "$QA_TRACKING_DIR/changed-files.txt" ]; then
        IDEM_REF_SOURCE="live recompute of the tracked change set"
        IDEM_REF_HASH=$(compute_change_set_hash) || IDEM_REF_HASH=""
    else
        IDEM_REF_SOURCE="persisted impact report (tracker empty, as approve leaves it)"
        IDEM_REF_HASH=$(persisted_report_hash "$tid") || IDEM_REF_HASH=""
    fi
    return 0
}

# 3mg.2 (Phase V4 pt2): WHERE this approval was reviewed — the approving
# checkout's absolute git toplevel, recorded in the approval comment as a
# `worktree=<tok>` token.
#
# WHY: the change-set hash is PER-CHECKOUT (it hashes the checkout's own
# changed-files list), so an approval granted inside a linked worktree can
# never match the hash a Stop hook computes in the primary checkout. The Stop
# hook's WORKTREE-RESOLUTION block (verify-before-stop.sh) uses this token to
# find the approving worktree in O(1) instead of scanning, and to name it when
# it has since been deleted.
#
# GRAMMAR CONTRACT — one space-terminated token:
#   - spaces become %20 and tabs %09, so `worktree=` never splits into two
#     fields and the v3.5 readers (which stop at whitespace) stay correct;
#   - a literal `%` becomes %25 FIRST, so the encoding is unambiguous: without
#     it a real path containing "%20" would decode to a space and the reader
#     would look for a directory that never existed;
#   - a path containing a NEWLINE is unrepresentable in a line-oriented record,
#     so we record `none` rather than emit something the reader could misparse;
#   - non-git / unresolvable checkout -> `none`. The token is NEVER omitted:
#     a stable grammar is what lets the reader tell "no worktree recorded"
#     (pre-3mg.2 record) from "recorded as unresolvable".
# The decoder is verify-before-stop.sh's wtres_decode; keep the two in step.
approval_worktree_token() {
    local top
    command -v git >/dev/null 2>&1 || { printf 'none'; return 0; }
    top=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || top=""
    [ -n "$top" ] || { printf 'none'; return 0; }
    case "$top" in
        *$'\n'*) printf 'none'; return 0 ;;
    esac
    top="${top//%/%25}"
    top="${top// /%20}"
    top="${top//$'\t'/%09}"
    printf '%s' "$top"
}

# ---------------------------------------------------------------------------
# COMPLETION CONTRACT (P7 / claude-workflow-plugin-qbhw): the F7 specialist
# payload, recorded and read back.
#
# WHY THESE LIVE HERE. `completion-record` writes a durable record and persists
# the validated payload; `approve` reads both back. Same split, and the same
# reasons, as the approval record (llh.18) and the rubric verdict (bjx): the
# Beads comment is a disclosure record — a cross-checkout-visible statement
# that a contract was submitted, forgeable by hand exactly as llh.18 documents
# for the approval record (claude-workflow-plugin-pqnd corrects the word, not
# the mechanism) — and the on-disk artifact is the content that statement is a
# digest of. Neither is a second copy of the other — the record cannot carry a
# file list without becoming a multi-line record, and the artifact cannot
# survive a different checkout.
#
# NOT wiped by wipe_review_artifacts and NOT truncated by approve, deliberately:
# it is the evidence the cross-check below was made against, so it has to
# outlive the cycle exactly as impact-report-<tid>.json does.

# completion_payload_path_for <tid> <role> — KEYED ON BOTH, and the role half is
# the fix for QA finding R1-F4.
#
# It was keyed on the task alone, so the SECOND contract recorded against a task
# silently overwrote the first. That is not a corner case, it is the flow this
# release mandates: the implementer records its contract, then QA records its
# own on the same task, and QA's `files_changed` is legitimately `[]` because QA
# verifies files rather than authoring them. The implementer's declaration — the
# entire independent witness the completeness cross-check exists to read — was
# gone, replaced by an empty list, and the cross-check then reported an
# affirmative PASS over zero declared files. Reproduced over the 94d.1 shape
# before this fix: `declared=8 bound=2 matched=2 missing=6` became
# `PASSED — every one of the 0 declared file(s)`, with no token in the durable
# record at all.
#
# Two contracts on one task are now two artifacts. The role is sanitised with
# the same class as the task id even though assert_record_scalar has already
# constrained it — this function is also reachable from the READ side, where the
# role comes off a parsed record rather than a validated payload.
completion_payload_path_for() {
    local sanitized role_part
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    role_part=$(printf '%s' "${2:-unknown}" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/completion-%s-%s.json' "$QA_TRACKING_DIR" "$sanitized" "$role_part"
}

# THE ROLES WHOSE COMPLETION CONTRACT DESCRIBES THE WORK (R1-F4).
#
# An ALLOWLIST, not a denylist of reviewer roles, and the direction is the whole
# safety argument. Get it wrong one way and an unrecognised IMPLEMENTER role
# makes the cross-check report `unestablished` — loud, recorded, and honest.
# Get it wrong the other way and an unrecognised REVIEWER role is read as an
# implementer, its `files_changed: []` is taken as the declaration, and the
# check reports an affirmative PASS over nothing. That second outcome is exactly
# the defect this list exists to close, so the list must fail toward
# "unestablished" and never toward "PASS".
#
# `implementer` is included ahead of its use: v5 Phase D0 collapses
# backend/frontend/devops into one implementer class, and a list that lags that
# rename would silently disarm the check at the moment the roles change.
# WHEN YOU ADD A ROLE: add it here only if that role WRITES CODE. A reviewing
# role (qa, grader, judge, a design reviewer) must NOT be added — its contract
# describes a review, and its file list is not a claim about what shipped.
COMPLETION_IMPLEMENTER_ROLES_JSON='["backend","frontend","devops","implementer"]'

# sha256_file <path> — hex digest of a file, or the host-level "no sha tool"
# sentinel.
#
# This is NOT a second change-set canonicalisation and must never become one:
# every change-set hash in this file still defers to impact-report.sh
# --hash-only (llh.18). This digests ONE named blob, which is a different
# question with no canonicalisation to drift. The sentinel is reused from
# CHANGE_SET_HASH_UNAVAILABLE rather than spelled again — the CONDITION it names
# is "this host has neither shasum nor sha256sum", not anything about change
# sets, and two literals for one condition is the drift this file avoids
# elsewhere.
sha256_file() {
    # Returns NON-ZERO on a failed digest instead of printing an empty string
    # (i8cx): `awk` was the pipeline's last command, so an unreadable or
    # vanished file digested to "" at rc 0, and the consumer's `[ -n ]` guard
    # silently SKIPPED the digest binding it exists to feed. The no-tool
    # sentinel arm is unchanged: "this host cannot hash" is a condition the
    # callers handle by NAME, not a failed read of this one file.
    local out=""
    if command -v shasum >/dev/null 2>&1; then
        out=$( set -o pipefail; shasum -a 256 -- "$1" 2>/dev/null | awk '{print $1}' ) || return 1
    elif command -v sha256sum >/dev/null 2>&1; then
        out=$( set -o pipefail; sha256sum -- "$1" 2>/dev/null | awk '{print $1}' ) || return 1
    else
        printf '%s' "$CHANGE_SET_HASH_UNAVAILABLE"
        return 0
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# latest_completion_record <tid> — the text of the LAST `COMPLETION v1 `
# comment on the task, or empty.
#
# `startswith("COMPLETION v1 ")` rather than a regex or a substring search, for
# the reason latest_satisfied_rubric_hash documents at length and review-count's
# "prose-only mention" leg pins: agents QUOTE record grammars in comments
# constantly. A comment that merely mentions the grammar mid-sentence does not
# START with it, so it is not a record — and here that direction is the safe
# one, because a prose mention must not be able to SATISFY the refusal below.
#
# LATEST-WINS. A specialist re-spawned in a second review round posts a second
# contract; the newest one is the one that describes the work being approved.
#
# Never fails the caller: no bd, no task, unparseable JSON -> empty, rc 0.
latest_completion_record() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    command -v bd >/dev/null 2>&1 || return 0
    bd_show_with_comments "$tid" \
        | jq -r '
            [ (if type == "array" then .[0].comments else .comments end) // []
              | .[].text
              | select(startswith("COMPLETION v1 "))
            ]
            | last // ""
        ' 2>/dev/null || true
    return 0
}

# latest_implementer_completion_record <tid> — the last COMPLETION record whose
# role WROTE CODE (see COMPLETION_IMPLEMENTER_ROLES_JSON), or empty.
#
# WHY THIS IS A SEPARATE SELECTOR FROM THE ONE ABOVE, which is the substance of
# the R1-F4 fix. The two questions the gate asks of these records are different:
#   - THE REFUSAL asks "did anyone hand back a validated contract for this
#     task?". Any contract answers that, QA's included, so it reads
#     latest_completion_record and latest-wins is correct there.
#   - THE COMPLETENESS CROSS-CHECK asks "what did the party that DID THE WORK
#     say it touched?". Only an implementer's contract answers that. QA's
#     `files_changed` is the files QA itself edited — normally none — and its
#     analogue is `files_verified`, which is deliberately NOT read here: a
#     reviewer's reading list is not a claim about what shipped.
# Conflating them is what made a QA record silently disarm the check, so they
# are two functions rather than one with a flag.
#
# LATEST-WINS WITHIN THE IMPLEMENTER SET: a specialist re-spawned in a second
# review round posts a second contract, and the newer one describes the work
# being approved.
#
# The role is parsed with the SAME character class the writer validates it
# against, anchored from the start of the record, so a role token appearing
# inside the free-text tail cannot be mistaken for the real one.
#
# Never fails the caller: no bd, no task, unparseable JSON -> empty, rc 0.
latest_implementer_completion_record() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    command -v bd >/dev/null 2>&1 || return 0
    bd_show_with_comments "$tid" \
        | jq -r --argjson impl "$COMPLETION_IMPLEMENTER_ROLES_JSON" '
            [ (if type == "array" then .[0].comments else .comments end) // []
              | .[].text
              | select(startswith("COMPLETION v1 "))
              | select(
                  ( [ capture("^COMPLETION v1 task=[A-Za-z0-9._+-]+ role=(?<r>[A-Za-z0-9._+-]+) ") ]
                    | first | .r? // "" ) as $r
                  | ($impl | index($r)) != null )
            ]
            | last // ""
        ' 2>/dev/null || true
    return 0
}

# completion_roles_seen <tid> — every distinct role that recorded a contract on
# the task, comma-joined. Diagnostic only: when the cross-check reports
# `unestablished` because no IMPLEMENTER contract exists, the operator's next
# question is "then whose contracts are on this task?", and an answer that names
# them turns an unexplained degradation into a one-line diagnosis.
completion_roles_seen() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    command -v bd >/dev/null 2>&1 || return 0
    bd_show_with_comments "$tid" \
        | jq -r '
            [ (if type == "array" then .[0].comments else .comments end) // []
              | .[].text
              | select(startswith("COMPLETION v1 "))
              | ( [ capture("^COMPLETION v1 task=[A-Za-z0-9._+-]+ role=(?<r>[A-Za-z0-9._+-]+) ") ]
                  | first | .r? // "?" )
            ] | unique | join(",")
        ' 2>/dev/null || true
    return 0
}

# assert_record_scalar <subcommand> <tid> <field> <value> — THE bjx GRAMMAR-
# INJECTION GUARD. Refuses (exit 1) any value that could move a field boundary
# in a one-line record, and REJECTS rather than sanitising.
#
# THE DEFECT CLASS, twice reproduced in this repo and once LIVE IN SHIPPED CODE:
#   - bjx: `rubric_version` was validated only as "non-empty string" and is
#     interpolated with a space on each side, so a version of the form
#     `1 iteration 1: satisfied change_set_hash=<real>` relocated the record's
#     first colon into attacker-supplied text and a needs_revision verdict read
#     back as satisfied AND bound.
#   - P8 (`lessons.sh`): `--source 'evil --> <!-- recorded: 1999-01-01'` wrote
#     an attacker-supplied field into the ledger's entry grammar. Its guard
#     covers tag, prose AND source — three scalars — because guarding one field
#     of a multi-field grammar just relocates the same defect to the next field.
#
# So every scalar this file interpolates into the COMPLETION record passes
# through here: the task id, the role, and each field name in the `fields=` csv.
# The class has no space, no colon, no comma and no bracket, so nothing that
# passes can relocate a token, split the csv, or terminate the machine prefix.
#
# REJECT, NEVER SANITISE, for bjx's reason: a silently-rewritten value would
# make the record disagree with the payload the specialist actually submitted,
# and the structured envelope is what lets the caller fix it precisely.
assert_record_scalar() {
    local sub="$1" tid="$2" field="$3" value="$4"
    if [ -z "$value" ]; then
        emit_error_json "$sub" "$tid" "${field}_empty" \
            "$field is empty; it is interpolated into the COMPLETION record's machine prefix, where an empty value collapses two tokens into one" \
            "qa-gate.sh $sub <task-id> [--file <path>]"
        exit 1
    fi
    case "$value" in
        *[!A-Za-z0-9._+-]*)
            emit_error_json "$sub" "$tid" "${field}_invalid_chars" \
                "$field='$value' contains characters outside [A-Za-z0-9._+-]; it is interpolated into the COMPLETION record's machine prefix, where a space, a colon, a comma or a bracket would move a field boundary and let the record be read back as something the payload never said (the claude-workflow-plugin-bjx class). Rejected, not sanitised: a rewritten value would make the record disagree with the payload" \
                "qa-gate.sh $sub <task-id> [--file <path>]"
            exit 1
            ;;
    esac
    return 0
}

# assert_record_model_scalar <subcommand> <tid> <field> <value> — the SAME
# bjx discipline as assert_record_scalar (reject, never sanitise; a space, a
# colon or a comma would still move a field boundary the same way), but with
# a WIDER class for a MODEL ID specifically (claude-workflow-plugin-46w9):
# `[A-Za-z0-9._+-]` truncates `claude-opus-5[1m]` at the bracket — a real,
# observed runtime id (see the ledger note on claude-workflow-plugin-gz3) —
# which would make the guard refuse to record a specialist's own honest
# self-report. Deliberately a SEPARATE function rather than widening
# assert_record_scalar's class: task/role/field_name/payload_sha have no
# legitimate reason to contain a bracket, colon or slash, and loosening their
# shared guard to accommodate a different data type would widen the security
# boundary for fields that never asked for it. The class still excludes
# space and comma — the two characters actually implicated in the historical
# bjx/P8 defects this guard's sibling documents — so relocating a field
# boundary or splitting a csv is still impossible.
assert_record_model_scalar() {
    local sub="$1" tid="$2" field="$3" value="$4"
    if [ -z "$value" ]; then
        emit_error_json "$sub" "$tid" "${field}_empty" \
            "$field is empty; it is interpolated into the record's machine prefix, where an empty value collapses two tokens into one" \
            "qa-gate.sh $sub <task-id> [--file <path>]"
        exit 1
    fi
    # BASH CASE/GLOB, not `grep -qE`, and that is load-bearing rather than a
    # style choice: `grep` is LINE-ORIENTED, so `printf '%s' "$value" | grep
    # -qE '^CLASS$'` returns success as soon as ANY line of a multi-line
    # value matches — an embedded-newline value like "claude-sonnet-5\nDROP
    # TABLE students" would be ACCEPTED because its first line alone passes,
    # which is exactly the vg8/bjx defect shape this file exists to close.
    # Measured directly while building this check (a grep-based first draft
    # accepted that exact input). `case` pattern-matches the PARAMETER'S
    # FULL VALUE as one string, so an embedded control character is just
    # another character outside the class — no line-splitting possible.
    case "$value" in
        *[!]A-Za-z0-9._:/[-]*)
            emit_error_json "$sub" "$tid" "${field}_invalid_chars" \
                "$field='$value' contains a character outside the model-id class [A-Za-z0-9._:/\\[\\]-]; it is interpolated into the record's machine prefix, where a space, a comma or a newline would move a field boundary (the claude-workflow-plugin-bjx class). Rejected, not sanitised. If this is a genuine model id the class needs widening — test against the real id first" \
                "qa-gate.sh $sub <task-id> [--file <path>]"
            exit 1
            ;;
    esac
    return 0
}

# assert_unit_id_scalar <subcommand> <tid> <field> <value> — v5 D4
# (claude-workflow-plugin-fkm.6). The SAME bjx discipline as
# assert_record_scalar (reject, never sanitise — a space or colon would move
# a field boundary the same way), but held to the STRICTER class
# review-check.sh's OWN schema enforces for a unit_id
# (`^[A-Za-z0-9._-]+$`, review-check.sh:733 — no `+`), not the wider
# default [A-Za-z0-9._+-] assert_record_scalar uses for task/designer/hash
# fields. A unit_id the schema could never have produced can never match ANY
# unit a real design declares, so refusing it HERE, at the writer, gives a
# precise "wrong shape" answer — the alternative (accepting it through the
# wider class and letting the artifact-membership check fail later) would
# report `unit_not_in_artifact` for a value that was never going to match
# regardless of what the artifact says, a confusing "refused, for the wrong
# reason" a caller would have to think past.
assert_unit_id_scalar() {
    local sub="$1" tid="$2" field="$3" value="$4"
    if [ -z "$value" ]; then
        emit_error_json "$sub" "$tid" "${field}_empty" \
            "$field is empty; it is interpolated into the DESIGN-UNIT record's machine prefix, where an empty value collapses two tokens into one" \
            "qa-gate.sh $sub <task-id> --design-task <id> --unit-id <U-n>"
        exit 1
    fi
    case "$value" in
        *[!A-Za-z0-9._-]*)
            emit_error_json "$sub" "$tid" "${field}_invalid_chars" \
                "$field='$value' contains characters outside [A-Za-z0-9._-] — the SAME class review-check.sh's schema enforces for a unit_id. A value outside it could never match any unit a design declares, so this is refused HERE rather than failing later with a confusing unit_not_in_artifact/unit_not_in_design. Rejected, not sanitised (the claude-workflow-plugin-bjx class)" \
                "qa-gate.sh $sub <task-id> --design-task <id> --unit-id <U-n>"
            exit 1
            ;;
    esac
    return 0
}

# completion_files_crosscheck <tid> <recorded-payload-sha> — THE INDEPENDENT
# COMPLETENESS WITNESS (claude-workflow-plugin-fkm.1.20).
#
# THE GAP IT FILLS. approve's impact-report freshness check compares the
# report's recorded change_set_hash against a recompute. That is sound for DRIFT
# (the set moved after the report was written) and STRUCTURALLY BLIND TO LOSS
# (the set shrank before it was written), because both numbers are derived from
# the same tracker. MEASURED LIVE on 94d.1: after SessionStart destroyed
# changed-files.txt and the reconcile rebuilt a 10-path subset of a 26-path
# change set, `enter` generated a report over the shrunken set and approve's
# freshness enforcement PASSED — vacuously, because recorded and current both
# faithfully described the shrunken set. Six of the eight files the
# implementer's own F7 contract declared were absent from what the approval
# would have bound. The enforcement did not fail; it succeeded about the wrong
# question.
#
# The general rule that instance proves: two numbers derived from the same
# truncated source cannot detect the truncation. Completeness needs a witness
# that is INDEPENDENT of the tracker — and the F7 contract's `files_changed` is
# the cheapest one already on disk, declared by the party that did the work,
# before and outside any gate bookkeeping.
#
# ===========================================================================
# WHY THIS REPORTS AND DOES NOT REFUSE. A deliberate call, made against the
# instinct that the safer-looking option is the safer one. Five reasons, in
# descending weight:
#
#   0. A REFUSAL WOULD HAVE DEADLOCKED THE TASK THAT INTRODUCED IT. This is not
#      a constructed argument; it is the measurement from P7's own approval.
#      That task declared 40 files and the change set bound 19, missing 21 — and
#      all 21 were the e2e fixture byte-copies that `make sync-fixtures` writes.
#      post-edit.sh records the paths of Write/Edit TOOL calls, so files produced
#      by a Makefile recipe are STRUCTURALLY invisible to it; they reach the
#      change set only if a later reconcile happens to see them as git dirt. A
#      refusal here would have blocked the change that added the refusal, on a
#      21-file delta that was entirely correct. Any task whose work includes a
#      generator, a codemod, or a build step is in that same class. (Credit where
#      due: QA found this while reviewing P7, and it is a better argument than
#      the path-spelling one below because it is self-demonstrating.)
#   1. THE TWO LISTS ARE SPELLED DIFFERENTLY BY CONSTRUCTION, and a refusal
#      keyed on a set difference would therefore fire on healthy tasks.
#      post-edit.sh records `tool_input.file_path` VERBATIM — usually absolute —
#      and reconcile_tracker "emits absolute paths"; specialists declare
#      RELATIVE paths (every F7 example in every prompt does). The
#      normalisation below strips $PROJECT_DIR/ from both sides, which aligns
#      the common case and CANNOT align a symlinked checkout, a path recorded
#      through a different mount, or a worktree. A gate whose false-positive
#      mode is "everything looks missing" must not be a refusal.
#   2. LEGITIMATE ASYMMETRY IS NORMAL. A file that was already dirty at
#      gate-baseline capture is correctly declared by the specialist and
#      correctly ABSENT from the change set (the baseline is subtracted on
#      purpose). Same for a path created and then deleted, a path outside the
#      project dir, and anything the shared denylist filters. Each is a
#      declared-but-not-bound entry that is not loss.
#   3. IT WOULD MAKE A MECHANICAL GATE DEPEND ON AN AGENT'S SELF-REPORT. A
#      specialist could deadlock its own approval by mistyping one path, and
#      the only exit would be a bypass flag — which is the shape the R2-F2
#      note in cmd_approve rejects in as many words: "a refusal whose only exit
#      is a bypass teaches the bypass".
#   4. THE PRECEDENT IS EXPLICIT. R2-F2 faced the same choice about the rubric
#      binding and chose to stop the AUDIT TRAIL lying rather than to add a
#      second gate. The harm in 94d.1 was not that approve proceeded; it was
#      that NOTHING SAID the bound set was short. That is what this fixes.
#
# So the result is recorded in the DURABLE approval record as well as the
# envelope, on the same bracketed-suffix shape as the rubric mismatch and after
# every machine token. `unestablished` is recorded too: silence would read as
# "checked and clean", which is exactly the false confidence 94d.1 was approved
# under.
#
# READ THE NUMBERS THIS WAY. `matched=0` with BOTH lists non-empty is the
# signature of a path-spelling mismatch, not of loss — no real session declares
# eight files and touches eight entirely different ones. The 94d.1 shape is
# PARTIAL overlap: matched=2, missing=6. The observation text says so, because a
# report that can be misread in the alarming direction will be.
#
# Returns 0 ALWAYS, by globals (the caller needs five values, and `x=$(f)` runs
# f in a subshell where the other four die silently — the same reason
# set_idempotency_reference hands its pair back this way).
COMPLETION_XCHECK_STATE=""
COMPLETION_XCHECK_DETAIL=""
COMPLETION_XCHECK_DECLARED=0
COMPLETION_XCHECK_BOUND=0
COMPLETION_XCHECK_MATCHED=0
COMPLETION_XCHECK_MISSING=0
COMPLETION_XCHECK_MISSING_PATHS=""
COMPLETION_XCHECK_INLINE_CAP=12
completion_files_crosscheck() {
    local tid="$1" recorded_sha="${2:-}" role="${3:-}"
    COMPLETION_XCHECK_STATE="unestablished"
    COMPLETION_XCHECK_DETAIL=""
    COMPLETION_XCHECK_DECLARED=0
    COMPLETION_XCHECK_BOUND=0
    COMPLETION_XCHECK_MATCHED=0
    COMPLETION_XCHECK_MISSING=0
    COMPLETION_XCHECK_MISSING_PATHS=""

    # R1-F4: the caller passes the role of the IMPLEMENTER record it selected,
    # and the artifact is looked up under that role. Without it this read went to
    # a task-keyed path that whichever contract was recorded LAST had overwritten.
    if [ -z "$role" ]; then
        COMPLETION_XCHECK_DETAIL="no implementer role was resolved for this task, so there is no contract to read a declared file list from"
        return 0
    fi

    local payload_file report
    payload_file=$(completion_payload_path_for "$tid" "$role")
    if [ ! -f "$payload_file" ]; then
        COMPLETION_XCHECK_DETAIL="the validated payload artifact is absent at $payload_file — the record proves a contract was validated, but the file list it declared is not on this disk (expected when the record was written in another checkout, or the tracking dir was cleaned)"
        return 0
    fi

    # The record's digest is what binds the artifact to the record. A mismatch
    # means the file on disk is not the one that was recorded, so reading a file
    # list out of it would be reading an unrecorded claim.
    local disk_sha="" disk_sha_rc=0
    disk_sha=$(sha256_file "$payload_file") || disk_sha_rc=$?
    # COMPLETION-XCHECK-DIGEST-GUARD BEGIN (i8cx)
    if [ "$disk_sha_rc" -ne 0 ] || [ -z "$disk_sha" ]; then
        COMPLETION_XCHECK_DETAIL="the persisted payload at $payload_file exists but could NOT be digested (sha256_file rc=$disk_sha_rc), so whether it is the artifact the COMPLETION record bound is unestablished and no file list is read from it. Before i8cx a failed digest read as an empty string, which skipped this binding check and let the cross-check report as if verified"
        return 0
    fi
    # COMPLETION-XCHECK-DIGEST-GUARD END (i8cx)
    if [ -n "$recorded_sha" ] && [ -n "$disk_sha" ] && [ "$recorded_sha" != "$disk_sha" ]; then
        COMPLETION_XCHECK_DETAIL="the persisted payload at $payload_file digests to $disk_sha, but the COMPLETION record binds payload_sha=$recorded_sha — the artifact on disk is NOT the one that was recorded, so no file list is read from it"
        return 0
    fi

    # The bound change set's FILE LIST. It comes from the persisted impact
    # report because that artifact is the only thing that carries it:
    # impact-report.sh --hash-only yields a digest, and re-deriving the list here
    # would be a second copy of canonical_changed_files (sort + denylist), i.e.
    # exactly the drift surface llh.18 refuses to open.
    report=$(impact_report_path_for "$tid")
    if [ ! -f "$report" ]; then
        COMPLETION_XCHECK_DETAIL="the impact report is absent at $report, so the file list of the change set being bound is unavailable (only the report carries it; --hash-only yields a digest). Regenerate it to enable the cross-check: bash .claude/scripts/impact-report.sh $tid"
        return 0
    fi

    local xj
    xj=$(jq -n --slurpfile p "$payload_file" --slurpfile r "$report" --arg root "$PROJECT_DIR" '
        def norm: ltrimstr($root + "/") | ltrimstr("./");
        ( ($p[0].files_changed // []) | map(select(type == "string")) | map(norm) | unique ) as $declared
        | ( ($r[0].files // []) | map(.file // "") | map(select(type == "string" and . != "")) | map(norm) | unique ) as $bound
        | ( $declared - $bound ) as $missing
        | { declared: ($declared|length),
            bound: ($bound|length),
            matched: (($declared|length) - ($missing|length)),
            missing: ($missing|length),
            missing_paths: $missing }
    ' 2>/dev/null) || xj=""
    if [ -z "$xj" ]; then
        COMPLETION_XCHECK_DETAIL="could not compare the two lists (the payload at $payload_file or the report at $report is unparseable)"
        return 0
    fi

    COMPLETION_XCHECK_DECLARED=$(printf '%s' "$xj" | jq -r '.declared' 2>/dev/null || echo 0)
    COMPLETION_XCHECK_BOUND=$(printf '%s' "$xj" | jq -r '.bound' 2>/dev/null || echo 0)
    COMPLETION_XCHECK_MATCHED=$(printf '%s' "$xj" | jq -r '.matched' 2>/dev/null || echo 0)
    COMPLETION_XCHECK_MISSING=$(printf '%s' "$xj" | jq -r '.missing' 2>/dev/null || echo 0)
    COMPLETION_XCHECK_MISSING_PATHS=$(printf '%s' "$xj" | jq -r '.missing_paths[]?' 2>/dev/null || echo "")
    COMPLETION_XCHECK_STATE="checked"
    return 0
}

# generate_impact_report <task-id> — best-effort invocation for enter.
# Sets IMPACT_REPORT_OBS (appended to enter's JSON observations) and
# returns 0/1. NEVER allowed to fail the enter flow: failures are logged
# loudly to sync-errors.log + a per-task stderr log, and the observation
# tells the operator approve will refuse until the artifact exists.
IMPACT_REPORT_OBS=""
generate_impact_report() {
    local tid="$1"
    IMPACT_REPORT_OBS=""
    local report stderr_log rc=0
    report=$(impact_report_path_for "$tid")
    stderr_log="${report%.json}.log"

    if [ ! -f "$IMPACT_REPORT_SCRIPT" ]; then
        log_sync_error "enter: impact-report.sh missing at $IMPACT_REPORT_SCRIPT for $tid; approve will refuse without the artifact"
        IMPACT_REPORT_OBS=" WARNING: impact-report.sh missing — approve will refuse until the artifact exists (regenerate manually or use approve --no-impact-report '<reason>')."
        return 1
    fi

    # Thread CLAUDE_PROJECT_DIR explicitly (same cwd-drift guard as
    # write_current_task). Progress/diagnostics land in the per-task log.
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$IMPACT_REPORT_SCRIPT" "$tid" >/dev/null 2>"$stderr_log" || rc=$?
    if [ "$rc" -eq 0 ] && [ -s "$report" ]; then
        local server_mode
        server_mode=$(jq -r '.server // "?"' "$report" 2>/dev/null || echo "?")
        IMPACT_REPORT_OBS=" Impact report generated (server=$server_mode): $report"
        return 0
    fi

    log_sync_error "enter: impact-report.sh failed for $tid (rc=$rc); tail: $(tail -2 "$stderr_log" 2>/dev/null | tr '\n' ' ' | head -c 200)"
    IMPACT_REPORT_OBS=" WARNING: impact-report.sh failed (rc=$rc, see $stderr_log and sync-errors.log) — approve will refuse until the artifact is regenerated (bash .claude/scripts/impact-report.sh $tid) or bypassed."
    return 1
}

emit_json() {
    # emit_json <ok 0|1> <subcommand> <task_id> <status> <observations>
    local ok="$1" sub="$2" tid="$3" st="$4" obs="$5"
    local ok_str="false"
    [ "$ok" = "1" ] && ok_str="true"
    # shellcheck disable=SC2016
    printf '{"ok":%s,"subcommand":%s,"task_id":%s,"status":%s,"observations":%s}\n' \
        "$ok_str" \
        "$(printf '%s' "$sub" | jq -Rs .)" \
        "$(printf '%s' "$tid" | jq -Rs .)" \
        "$(printf '%s' "$st" | jq -Rs .)" \
        "$(printf '%s' "$obs" | jq -Rs .)"
}

usage() {
    cat >&2 <<'USAGE'
Usage: qa-gate.sh <subcommand> <task-id> [args]
  enter   <task-id>
              Reconciles changed-files.txt against `git status` (94d), then
              generates the mechanical impact report
              (.claude/.qa-tracking/impact-report-<task-id>.json) via
              impact-report.sh — in that order, so the report's
              change_set_hash covers the whole git-visible delta. Both steps
              are tolerant: enter never fails because of either.
  status  <task-id>
              Precedence: approved > blocked > entered > not-entered. Reads
              labels via ONE `bd show`. If that read fails for any reason —
              schema skew, an unreachable store, a wedged daemon — prints
              {"ok":false,"status":"unavailable",...} and exits 3, rather
              than falling through to "not-entered" (claude-workflow-plugin-
              j7kk, 39cy: an unreachable store used to be indistinguishable
              from a task that was simply never entered).
  approve <task-id> [--expect-hash <hash>] [--accept-reconstructed '<reason>']
          [--no-impact-report '<reason>'] [--no-review '<reason>']
          [--accept-unrecorded-review '<reason>']
          [--no-completion '<reason>'] [--no-design '<reason>']
          <approval-summary>
              --expect-hash <hash> is the change set the CALLER classified.
              REFUSES (exit 2, error_key expected_hash_mismatch) when that is
              not the set this approval would bind, naming BOTH hashes so the
              operator can see which one is stale and how big the delta is
              (qzv). The F1 doc-only fast path passes the hash of the set it
              classified, so a source file arriving mid-Stop can no longer be
              approved under a doc-only verdict that never saw it. It proves
              bound == classified; it does NOT prove the set is COMPLETE (both
              sides read one canonicalisation of one tracker, so it detects
              drift and is blind to loss — fkm.1.20).
              REFUSES (exit 2, error_key change_set_reconstructed) when all
              three hold: changed-files.txt was absent-or-empty when the
              reconcile ran (so the set was REBUILT from `git status`), the
              rebuild produced a NON-EMPTY set, and it ALSO dropped
              git-visible path(s) as already-baselined — i.e. real work is
              being certified over a proven SUBSET of the working tree
              (94d.1). The dropped paths are named in the refusal and in
              .claude/.qa-tracking/reconcile-subtracted.txt. An EMPTY rebuilt
              set is NOT refused: that is the normal shape of a no-op approve
              in a dirty checkout and is indistinguishable from it.
              --accept-reconstructed '<reason>' bypasses it (the observation is
              inferential: a destroyed tracker and an all-Bash session in a
              repo that was dirty on arrival look identical to the reconcile,
              and a human reading the paths can tell them apart). The reason is
              recorded in the approval comment and the gate JSON.

              REFUSES (exit 2, structured error) when the impact report is
              missing or stale (change_set_hash != current changed-files
              list). Regenerate with:
                bash .claude/scripts/impact-report.sh <task-id>
              server:"absent" reports are accepted (documented degradation).
              --no-impact-report '<reason>' bypasses the refusal; the reason
              is recorded in the approval comment and the gate JSON.

              ALSO REFUSES (exit 4) when independent review is not satisfied,
              as decided by the ONE predicate `review-check.sh gate <task-id>`:
                review_artifact_missing   no REVIEW-ARTIFACT v1 record — an
                                          independent reviewer must review and
                                          `qa-gate.sh review-record` it
                reviewer_not_independent  the reviewer is also a recorded
                                          IMPLEMENTER of this task
                unresolved_findings       finding(s) at/above the artifact's
                                          risk_threshold are still open —
                                          `resolve-finding` (with fix+test) or
                                          `arbitrate <id> overrule` each one
                review_check_unavailable  the predicate could not run — this
                                          FAILS CLOSED on purpose
                review_cap_terminated    (v5 D2 / fkm.4) the latest review
                                          stopped at a CAP (max_findings /
                                          max_review_iterations / timeout)
                                          rather than at a verdict or a
                                          stated stop_condition — incomplete
                                          by construction, cannot certify the
                                          change set on its own
              --no-review '<reason>' bypasses it; the reason lands in the
              approval comment as `[review bypass: <reason>]` (which the Stop
              hook's review-discipline check honours) and in the gate JSON.

              ALSO REFUSES (exit 4, error_key review_artifact_unrecorded —
              claude-workflow-plugin-k6re, the HEADLINE defect) when
              docs/reviews/<task-id>-r*.json holds an artifact whose CONTENT
              HASH (never mtime — a checkout, copy or restore can move an
              mtime without changing a byte) binds no well-formed
              REVIEW-ARTIFACT v1 record for this task, per
              `review-check.sh recorded-hashes`. The external reviewer
              driver writes the artifact and exits; nothing calls
              `review-record` for it unless a human/agent remembers to — this
              refusal is what makes that omission loud instead of silent, for
              every review pathway (the external driver, Claude's own
              in-session review, or a hand-run review), not only the one a
              fix to the driver could reach. Reconcile the named file(s) with:
                bash .claude/scripts/qa-gate.sh review-record <task-id> \
                    --file <path>
              --accept-unrecorded-review '<reason>' is the audited bypass —
              for a task carrying a legitimate HISTORIC backlog (e.g. one
              reopened after nine WAVE-1-era artifacts were never recorded)
              that should not be permanently stranded by a refusal with no
              escape. The reason lands in the approval comment as
              `[unrecorded review artifact accepted: <reason>]` and in the
              gate JSON.

              ALSO REFUSES (exit 2, error_key completion_record_missing) when
              the task carries no `COMPLETION v1` record — the F7 specialist
              completion contract, which had NO runtime enforcement before P7
              (twelve documents described it; nothing rejected a payload).
              Record one with:
                bash .claude/scripts/qa-gate.sh completion-record <task-id> \
                    --file <payload.json>
              --no-completion '<reason>' is the audited bypass, for the case
              where there was no specialist and no payload is owed (the Stop
              hook's doc-only fast path passes it). The reason lands in the
              approval comment as `[completion bypass: <reason>]` and in the
              gate JSON.
              A successful approval additionally REPORTS the completeness
              cross-check: how many of the contract's declared `files_changed`
              are absent from the change set being bound. That is the
              INDEPENDENT witness the impact-report freshness check cannot be —
              freshness compares two reads of the same tracker, so it detects
              DRIFT and is blind to LOSS (fkm.1.20; measured live on 94d.1,
              where 6 of 8 declared files were absent and freshness passed
              vacuously). It REPORTS rather than refuses, because the two lists
              are spelled differently by construction and legitimate asymmetry
              is normal — see completion_files_crosscheck for the full argument.
              The verdict is recorded in the approval comment as
              `[completion cross-check: ...]` whenever it is not clean.

              ALSO REFUSES (exit 2, error_key names which — v5 D2 / fkm.4)
              unless design-satisfied holds: a DESIGN-REVIEW v1 verdict exists
              for the task, its verdict is `satisfied`, and a live re-hash of
              docs/specs/<task-id>.md still agrees with the design_hash that
              verdict names:
                no_design_attempted        no DESIGN-ARTIFACT record at all
                design_verdict_missing      an artifact exists, no verdict yet
                design_not_satisfied        latest verdict is needs_revision
                design_hash_unreadable      the verdict's design_hash is not
                                            64 hex characters
                design_artifact_unreadable  docs/specs/<task-id>.md is
                                            missing, escaped its directory,
                                            or could not be hashed
                design_verdict_stale        the artifact changed since the
                                            satisfied verdict was recorded
              --no-design '<reason>' is the audited bypass — the ordinary exit
              for a task with no design phase at all. Record one with:
                bash .claude/scripts/qa-gate.sh design-review-record <task-id> \
                    --design-hash <sha256> --file <verdict.json>
              The reason lands in the approval comment as
              `[design bypass: <reason>]` and in the gate JSON.

              The approval comment records the reviewer, the approving
              checkout (3mg.2 — `worktree=` is the %20-encoded git toplevel,
              or `none`; the Stop hook resolves cross-worktree approvals
              through it) AND, since v5 D1, the design artifact's content hash
              when a DESIGN-ARTIFACT record exists AND a live re-hash of
              docs/specs/<task-id>.md still agrees with it (otherwise the token
              is omitted and the envelope names why), AND (since rqer) the
              REVIEW-ARTIFACT file's own content hash under the same rule, AND
              (since v5 D2) the design VERDICT's design_hash once
              design-satisfied verifies:
                QA-GATE APPROVED change_set_hash=<h> reviewed_by=<id>
                worktree=<tok> design_hash=<h> artifact_hash=<h>
                design_verdict_hash=<h> at <ts>: <summary>
              Every optional MACHINE field carries its own trailing space and
              defaults to empty. The bracketed suffixes are free-text audit
              prose appended AFTER the summary, all eight of them:
                [ [impact-report bypass: ...]][ [review bypass: ...]]
                [ [unrecorded review artifact accepted: ...]]
                [ [rubric mismatch: ...]][ [reconstructed change set accepted: ...]]
                [ [completion bypass: ...]][ [completion cross-check: ...]]
                [ [design bypass: ...]]
  block   <task-id> <reason>
  baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]
              Write .claude/.qa-tracking/gate-baseline — the snapshot of
              `git status --porcelain` that verify-before-stop.sh subtracts
              so the Stop gate evaluates this session's DELTA rather than a
              working tree that was already dirty on arrival. No task id, no
              bd, no labels. session-start.sh calls this (--by session-start)
              when no review cycle is active; `enter` and `approve` write it
              themselves.
  reconcile-tracker
              Append every git-visible changed path that changed-files.txt is
              missing (94d). post-edit.sh only sees Write/Edit/MultiEdit/
              NotebookEdit, so a file written by a Bash redirect, `cp`, `sed
              -i` or a generator script never entered the tracker — and the
              tracker is what change_set_hash() hashes, so the gate could name
              N paths and release on an approval binding fewer. Non-git tree:
              no-op. Emits absolute paths; subtracts the gate baseline and the
              shared denylist; never removes anything. Exit 2 when the
              reconcile cannot be completed (git unreadable), which every
              caller treats as refuse-to-proceed. No task id, no bd, no
              labels.
  choose  <approve|continue|tech-debt|defer> <task-id> <note> [tech-debt: severity file:line effort]
              Record a J21 decision while qa-escalated. The note is the
              human-readable rationale; for `tech-debt` the note becomes
              the description and the optional trailing args are passed
              through to .claude/scripts/tech-debt.sh add.
              Effects:
                approve    -> delegates to `approve` (same atomic flow, so it
                              inherits EVERY refusal: a J21 decision does not
                              exempt the task from a fresh impact report, from
                              independent review, or from a recorded completion
                              contract)
                continue   -> clears qa-escalated + resets iteration counter
                tech-debt  -> tech-debt.sh add --bd-task + clears escalation
                defer      -> sets qa-deferred (allows Stop next time)
  grade-record <task-id> [--file <path>] [--graded-hash <h>]
              Spec Phase A: record a grader verdict. Reads a strict-JSON
              verdict from --file <path> or, if omitted, stdin. Required
              JSON keys:
                verdict          "satisfied" | "needs_revision"
                criterion_results array of {criterion, pass, justification}
                required_fixes   array
                iteration        non-negative integer
                rubric_version   string matching ^[A-Za-z0-9._+-]+$
              --graded-hash <h> names the change set the GRADER SAW — the
              change_set_hash from the grading packet's impact report. The
              relay passes it (orchestrator.md 5a step C). Without it the
              record binds the live change set only when the persisted
              impact report still corroborates it; if they disagree the
              verdict is recorded UNBOUND rather than bound to work that
              was never graded.
              Effects:
                - appends a Beads comment
                  `RUBRIC <rubric_version> iteration <n>: <verdict>
                   change_set_hash=<h> — <summary>`
                  (the hash names the change set that was graded; omitted
                  when it cannot be computed. `enter` reads it back to decide
                  whether a satisfied verdict still covers the current work.)
                - on satisfied: removes rubric-pending, adds rubric-satisfied
                - on needs_revision: labels unchanged (qa-blocked round-trip
                  is the QA agent's move, not this script's)
              Malformed input exits non-zero with a structured JSON error
              naming the offending key.
  review-record <task-id> [--file <path>]
              Phase V2: record a reviewer artifact. Validates the artifact
              JSON via review-check.sh (the ONE validator) then appends the
              load-bearing comment:
                REVIEW-ARTIFACT v1 iteration=<n> reviewer=<id> model=<m>
                pin=<p> reviewed_hash=<h> risk_threshold=<sev> verdict=<v>
                stopped_by=<s> findings=[<id>:<sev>,...] at <ts>: <summary>
              (empty findings render as findings=[]). `model`/`pin` (46w9) are
              reviewer_model (a runtime self-report, not a restated
              frontmatter pin) / reviewer_pin (the frontmatter reading, moved
              to its own field). Record writer only — no approve/Stop
              enforcement.
              REFUSALS (claude-workflow-plugin-wob2), each named so an
              operator or agent reading this first does not have to
              rediscover them from a failed call:
                - the artifact's own task_id must equal the task being
                  recorded under (artifact_task_id_mismatch) — a review
                  recorded on a task it does not describe would make
                  approve's binding attest to the wrong task's change set.
                - reviewed_hash must be exactly 64 lowercase hex characters
                  and is refused when it is the SHA-256 empty-content
                  sentinel e3b0c442... (reviewed_hash_unusable, enforced by
                  review-check.sh validate-artifact — the sentinel is a
                  degradation constant that would compare equal to itself
                  and to every other unread artifact forever). The SAME
                  sentinel is now refused earlier still, at validate-request
                  (change_set_hash_unusable) — before any review turn is
                  spent, not merely at the recorder. A genuinely empty
                  change set (or one whose every entry is denylisted) is
                  the documented case for skipping review entirely via
                  `approve --no-review '<reason>'` rather than requesting
                  or recording a review over nothing. "Doc-only" is a
                  DIFFERENT concept (verify-before-stop.sh's F1 fast path,
                  is_doc_only_path) and does not apply here: a change set
                  whose every entry is a real document still hashes to a
                  real, non-sentinel digest and reviews normally.
                - risk_threshold must rank in the severity enum
                  (risk_threshold_invalid_enum, same enum and error-key
                  spelling as the REQUEST schema's own check, applied here to
                  the ARTIFACT schema).
                - iterations/reviewer_identity/risk_threshold/reviewed_hash
                  are each REJECTED, never sanitised, outside the class
                  ^[A-Za-z0-9._+-]+$ (the field name suffixed
                  `_invalid_chars`, the claude-workflow-plugin-bjx class) —
                  they are interpolated into this record's own machine
                  prefix, where a space or bracket would move a field
                  boundary and let the record be read back as something the
                  artifact never said. reviewer_model/reviewer_pin,
                  verdict/stopped_by, and findings[] are each guarded by an
                  earlier, schema-level check instead (a model-id class, a
                  closed enum, and an id/severity grammar respectively), so
                  they are not re-asserted here.
  review-reconcile <task-id> --file <path> [--acknowledge-findings] <reason>
              claude-workflow-plugin-k6re (R13-F1/F2): account for a HISTORIC
              review artifact that already exists on disk without letting it
              govern the release verdict. Same validation, canonical-path
              derivation, containment check and hashing discipline as
              review-record, but --file is REQUIRED (no stdin mode — there is
              nothing to write, only existing bytes to verify) and <reason>
              is REQUIRED (a non-empty explanation, recorded verbatim).
              Appends:
                REVIEW-ARTIFACT-RECONCILED v1 iteration=<n>
                artifact_hash=<h> at <ts>: <reason>
              This grammar is deliberately NOT `REVIEW-ARTIFACT v1` — it
              diverges at the character immediately after "REVIEW-ARTIFACT",
              so review-check.sh gate's K3 selector (which requires a record
              to be simultaneously max(iteration) AND max(at-timestamp))
              never matches it and can never select it. WHY THIS EXISTS:
              review-record stamps WRITE time, not review time, so
              backfilling several historic rounds through review-record in
              any order the caller does not carefully control can make a
              low-iteration round the newest by write-time while the
              highest-iteration round stays older — the two axes disagree,
              and gate refuses with review_artifact_selection_disagreement.
              Reconciling every historic round through this command instead
              means only the round that should actually govern the release
              verdict is ever recorded through review-record — see the
              review_artifact_unrecorded remedy for when to use which.
              recorded-hashes accounts for a RECONCILED record exactly like
              a governing one, so approve stops refusing on it.
              --acknowledge-findings (R14-F5): REQUIRED when the artifact
              carries a findings[] entry ranked at or above its own
              risk_threshold — a RECONCILED record is non-governing and
              carries no findings of its own, so reconciling one that still
              has an open at-threshold finding would let it leave the trust
              chain silently (gate's open-findings count only ever reads
              GOVERNING records). Without the flag, refuses (exit 1,
              reconcile_open_findings_unacknowledged) naming the qualifying
              finding id(s)/severity and pointing at review-record +
              resolve-finding as the alternative ("this finding was actually
              resolved by a different round — make THAT one govern"). With
              the flag, the comment gains a visible
              "[open findings acknowledged: <id>:<severity>,...]" marker
              ahead of <reason>. review-check.sh recorded-hashes surfaces
              this too (acknowledged_hashes/acknowledged_count, R15-F3), and
              approve's own success observations note the count when any
              accounted-for artifact carries one — so the acknowledgment
              reaches a human reading the comment stream AND the two
              mechanical readers on this path, though it still never governs:
              gate's own open-findings count correctly stays at the
              GOVERNING record only, by design, unaffected by this marker.
  completion-record <task-id> [--file <path>]
              P7: record the F7 specialist completion contract. Validates the
              payload JSON via review-check.sh `validate-completion` (the ONE
              validator — no second schema lives here), persists the validated
              bytes to .claude/.qa-tracking/completion-<task-id>.json, and
              appends:
                COMPLETION v1 task=<tid> role=<r> model=<m> pin=<p> fields=<csv>
                payload_sha=<sha256> at <ts>: <n> file(s), <m> test(s)
              Required payload keys: the canonical seven (task_id,
              files_changed, tests_added, decisions, blockers,
              llm_observations, context_coverage) plus `role`, `model` and
              `pin` (46w9) — `pin` is the specialist's own static frontmatter
              `model:` reading, `model` is a RUNTIME SELF-REPORT, and their
              divergence across a task's records is the production
              measurement of whether the runtime honours a frontmatter model
              change. The four free-form fields are NEVER interpolated — only
              their presence and the digest reach the record, which is the
              injection boundary. task/role/each field name/the digest must
              match ^[A-Za-z0-9._+-]+$; model/pin use the WIDER model-id class
              [A-Za-z0-9._:/\[\]-]$ (a real id like claude-opus-5[1m] would be
              truncated by the stricter class) — both REJECTED, never
              sanitised (the claude-workflow-plugin-bjx class).
              `approve` REFUSES without this record.
  grilling-record <task-id> --rounds <n> --questions <n> --approaches <n>
                  --unresolved <n> ['<summary>']
              v5 D3 (fkm.5): record that a grilling dialogue happened before
              the design phase (.claude/vendor/superpowers/brainstorming/
              SKILL.md). Written by the ORCHESTRATOR, AT ROOT — it ran the
              dialogue; the designer's own tool list omits Bash, so it
              cannot invoke this. Every counter must be a non-negative
              integer; `--approaches` additionally REFUSES below 2
              (insufficient_approaches — the vendored method's own bar:
              "Propose 2-3 different approaches with trade-offs"). Appends:
                GRILLING v1 rounds=<n> questions=<n> approaches=<n>
                unresolved=<n> vendor_hash=<h> at <ts>: <summary>
              `vendor_hash` is NOT a flag — it is a live workflow-manifest.sh
              `hash-file` recompute over the vendored SKILL.md, taken at
              record time, so the record names WHICH METHOD TEXT was in
              force. `design-record` REFUSES (grilling_record_missing)
              without at least one of these on the task or its parent epic,
              unless `--no-grilling '<reason>'`.
  design-record <task-id> [--file <artifact>] [--designer <id>]
                [--accept-foreign-paths '<reason>'] [--no-grilling '<reason>']
                ['<summary>']
              v5 D1: record the DESIGNER's artifact and bind its bytes.
              Validates via review-check.sh `validate-design` (the ONE
              validator), hashes the artifact's RAW BYTES through
              workflow-manifest.sh `hash-file` (which refuses BEFORE hashing on
              a missing/unreadable/EMPTY path), and appends:
                DESIGN-ARTIFACT v1 task=<tid> designer=<id> design_hash=<h>
                units=<n> at <ts>: <summary>[ [foreign paths accepted: <r>]]
              --file is an ASSERTION, not an input: the artifact is always
              docs/specs/<task-id>.md, and --file may only say so (absolute or
              repo-relative), or be omitted — the record carries the hash and
              NO path, which is only sound while the path is derivable from the
              task id. Anything else -> `artifact_path_not_derived`.
              THE EDIT BAN'S SECOND LAYER. Refuses `artifact_outside_spec_dir`
              when what sits at the derived path does not resolve into
              docs/specs/ (a symlinked leaf, a moved directory), and
              `designer_touched_source` when the change set holds a path that
              is not this task's design artifact — a source file, a second file
              beside it in docs/specs/, or another task's design — while no
              IMPLEMENTER record exists on the task (the check switches off at
              implementer SPAWN, not at completion). The change set is the
              SESSION's, so the audited --accept-foreign-paths records a reason
              for work that was not the designer's. Both resolve the DIRECTORY
              through ONE physical predicate (`..` and intermediate symlinks)
              and differ only in the LEAF: the record follows it, because the
              question is which bytes those are; the tracker does not, because
              the question is which path was written. Both return an exit
              status rather than a path, so no pathname crosses a command
              substitution.
              Refuses `design_artifact_changed_during_record` when the artifact
              moves between the validator's read and the hash — in CONTENT or
              in CONTAINMENT — rather than binding bytes no validator saw, or
              bytes never shown to be the declared directory's.
              REFUSES `grilling_record_missing` (v5 D3) unless a `GRILLING v1`
              record exists on this task or its parent epic — see
              grilling-record above. `--no-grilling '<reason>'` is the audited
              bypass (the F1 doc-only class, or a genuinely single-line-typo
              design); the reason lands in the record as
              `[grilling bypass: <reason>]`.
  design-review-record <task-id> --design-hash <sha256> [--file <path>]
              v5 D2 (fkm.4): record the design REVIEWER's verdict — the split
              D1's design-record documents ("that is D2's own record, with its
              own grammar, its own author and its own lifetime"). Reads a
              strict-JSON verdict from --file <path> or, if omitted, stdin.
              Required JSON keys (mirrors grade-record's shape, plus the one
              key the code rubric has no analogue for):
                verdict            "satisfied" | "needs_revision"
                criterion_results  array of {criterion, pass, justification}
                required_fixes     array
                iteration          non-negative integer, GREATER than the
                                   task's latest recorded DESIGN-REVIEW
                                   iteration (a repeat at the same or an
                                   earlier number is refused)
                rubric_version     string matching ^[A-Za-z0-9._+-]+$
                reviewer_identity  string matching ^[A-Za-z0-9._+-]+$
              --design-hash <sha256> is REQUIRED — a CLAIM about which bytes
              were reviewed, not a live recompute (same reasoning as
              grade-record's --graded-hash: recomputing here would bind
              whatever docs/specs/<task-id>.md happens to be AT RECORD TIME,
              not necessarily what the reviewer actually read). Ordinarily
              latest_design_artifact_hash's value, read right before the
              reviewer spawns.
              REFUSES `design_reviewer_not_independent` when reviewer_identity
              equals the designer= on the task's latest DESIGN-ARTIFACT
              record — nobody reviews their own work — and
              `design_artifact_record_missing` when no DESIGN-ARTIFACT record
              exists at all (nothing to check independence against).
              A repeat recording against an artifact revised in place (its
              Revision log gains a row, so design_hash moves) is an
              AMENDMENT: the record carries `[amends: <prev-design-hash>]`.
              Appends:
                DESIGN-REVIEW v1 task=<tid> reviewer=<id>
                verdict=<satisfied|needs_revision> design_hash=<h>
                iteration=<n> rubric_version=<v> at <ts>: <summary>[ [amends: <h>]]
              `approve` REFUSES without a satisfied, fresh one of these (see
              approve's own help above) unless `--no-design '<reason>'`.
  design-gate-precheck <task-id>
              v5 D2 (fkm.4), B5: a PRE-DELEGATION convenience the orchestrator
              MAY run before its first Task() spawn on a task — never
              enforced from here (nothing can force a prompt to run a script
              before deciding to delegate; `approve`'s own design-satisfied
              refusal is the real, unavoidable backstop). Exits 0 when either
              design-satisfied holds OR no design has been started at all
              (`no_design_attempted` — deliberately NOT a failure here, unlike
              at `approve`: the overwhelming majority of tasks never have a
              design phase, and treating "nothing started" as a precheck
              failure would fire on nearly every ordinary task). Exits 4 with
              a structured error_key (see approve's design-satisfied list
              above) when a design WAS started but is not yet satisfied — the
              case worth stopping to fix before paying for an implementer
              spawn.
  design-unit-bind <task-id> --design-task <design-tid> --unit-id <U-n>
                   [--rebind '<reason>'] ['<summary>']
              v5 D4 (fkm.6): bind <task-id> (the IMPLEMENTING task) to a
              specific unit in <design-tid>'s design artifact — the carrier
              task-per-unit needs since review-check.sh's schema has no
              per-unit `task_id`. Hashes the artifact (workflow-manifest.sh
              `hash-file`), validates it via review-check.sh `validate-design`,
              and REFUSES `unit_not_in_artifact` unless --unit-id is among
              its CURRENT unit_ids — a binding to a nonexistent unit is worse
              than none. Bracketed hash-then-validate-then-rehash, same
              TOCTOU discipline as design-record's own window. Appends (ON
              <task-id>, never on <design-tid>):
                DESIGN-UNIT v1 task=<tid> design_task=<design-tid>
                unit_id=<U-n> design_hash=<h> at <ts>: <summary>[ [rebind: <r>]]
              An EXISTING binding on <task-id> — to ANY unit, even the same
              one — refuses a second write with `design_binding_exists`
              unless `--rebind '<reason>'`: silent re-binding is dangerous
              (an injected spec, an in-flight implementer, or a prior
              design-conform result would all silently disagree), a
              permanent refusal would deadlock a legitimate re-plan.
  design-conform <task-id>
              v5 D4 (fkm.6): deterministic, no LLM, NO BYPASS FLAG. Resolves
              <task-id>'s DESIGN-UNIT binding, requires the governing design
              to be design-satisfied (propagates compute_design_satisfied's
              own key verbatim otherwise), confirms the bound unit_id is
              STILL declared (`unit_not_in_design` if an amendment dropped
              it), then computes undeclared = actual - declared and
              unbuilt = declared - actual over the SAME canonical,
              denylist-filtered change set `approve` hashes
              (impact-report.sh --relativized-changed-files, so an
              absolute-vs-relative spelling of the same file never shows up
              as both). `undeclared_files` non-empty is the ONLY failure —
              an extra file is scope the design never reviewed; a missing
              file (`unbuilt`) is reported but never gates. Exactly two
              remedies for undeclared_files: drop the file, or land an
              amendment and re-bind (design-unit-bind ... --rebind). NOT
              wired into `approve` in this slice — built and tested
              standalone.
  design-unit-show <task-id>
              v5 D4b (fkm.6): READ-ONLY accessor over
              latest_design_unit_binding — the ONE authoritative reader,
              exposed so a SEPARATE process (epic-gate.sh plan-batches)
              never needs its own copy of the DESIGN-UNIT grammar or a
              second `bd_show_with_comments` (the doctrine review-check.sh's
              own header and design-unit-bind's UNIT-MEMBERSHIP-GATE both
              state: one parser per grammar). Exits 0 ONLY on a DETERMINED
              read: `bound:true` with a fully-validated design_task/
              unit_id/design_hash triple, or `bound:false` read from a
              successfully-parsed comment stream. Since xsu1 H2-F2/F3 an
              UNREADABLE source (bd show failing, unparseable comments) is
              ok:false/design_binding_unreadable/exit 2, and a partial or
              malformed binding object is ok:false/
              design_binding_malformed/exit 2 — never reported as either
              determined answer.
  design-status <task-id>
              v5 D4b (fkm.6): READ-ONLY, UNFILTERED accessor over
              compute_design_satisfied — deliberately NOT design-gate-
              precheck, whose `no_design_attempted` leniency (mapped to
              "ready", B5's own documented, correct choice for a pre-
              delegation convenience) would be indistinguishable here from
              a genuinely satisfied design: both read `ok:true` with no
              way to tell them apart. A caller that needs the RAW verdict
              (plan-batches: no design means no units to batch, which must
              degrade, not silently pass) gets every one of
              compute_design_satisfied's keys verbatim, including
              `no_design_attempted`, plus the derived artifact_path
              (design_artifact_path_for, always defined even when the file
              itself does not exist yet). Exits 0 on a determined read:
              `satisfied:true` with design_hash, or `satisfied:false` with
              error_key naming why. Since xsu1 H2-F5 an UNREADABLE Beads
              source is its own key (design_source_unreadable) with
              ok:false and exit 2, no longer conflated with
              no_design_attempted — "could not look" is not "looked, and
              found no design".
  design-conflict <task-id> --unit <unit-id> [--design-hash <h>] '<statement>'
              v5 D5 (fkm.7; R2-F3 fix, independent review round 2): the implementer's
              structured way to say "the design is wrong here" without
              silently improvising or stalling forever. --unit MUST name a
              unit_id currently declared in docs/specs/<task-id>.md
              (`unit_not_in_artifact` otherwise, same key design-unit-bind
              uses). --design-hash is OPTIONAL: given, it must CONFIRM the
              artifact's CURRENT live hash (`design_hash_not_current`
              otherwise — no longer a trusted claim); omitted, it is the
              same live recompute (strict 64-hex). Appends:
                DESIGN-CONFLICT <unit-id> design_hash=<h> unit_hash=<h2> at <ts>: <statement>
              where unit_hash is a live hash of --unit's OWN current content
              (not the whole artifact). `approve` REFUSES (exit 2,
              design_conflict_open) UNCONDITIONALLY while ANY filed
              conflict's unit_hash still equals its unit's CURRENT content
              hash, OR no current satisfied DESIGN-REVIEW covers the
              artifact at all — every record considered, not just the
              latest (fkm.1.19 discipline: a later record simply silent
              about an earlier one must not retire it). The single legal
              clearing path is a superseding, independently-reviewed,
              SATISFIED DESIGN-REVIEW under which THAT SAME UNIT's own
              content changed (a content edit alone, with no accompanying
              satisfied review, does NOT clear it — claude-workflow-plugin-
              i8cx R6-F4; an edit to a different unit still never clears
              it either) — never `arbitrate`, which is keyed to
              REVIEW-ARTIFACT finding ids. `design-gate-precheck` (the
              Stop-time recheck path) ALSO refuses on an open conflict, not
              only `approve` (R2-F2 fix). `--no-design '<reason>'` does
              NOT cover an open conflict (claude-workflow-plugin-i8cx,
              operator ruling on rounds 6/7/8 independent review — REMOVED
              after four independent HIGH findings against the waiver
              mechanism this paragraph used to describe; it bypasses only
              the requirement for a satisfied verdict, same as when no
              conflict was ever filed).
  resolve-finding <tid> <finding-id> --fix '<ref>' --test '<ref>' '<summary>'
              Phase V2: mark a review finding resolved. The id must appear in
              the latest REVIEW-ARTIFACT comment; empty --fix/--test exit 1.
              Appends: RESOLVED <id> at <ts>: fix=<ref> test=<ref> — <summary>
  arbitrate <tid> <finding-id> <overrule|sustain> '<rationale>'
              Phase V2: record an arbitration decision on a review finding.
              The id must appear in the latest REVIEW-ARTIFACT comment; empty
              rationale exits 1. Appends:
                ARBITRATION <id> decision=<d> at <ts>: <rationale>
  quarantine-artifact -- REMOVED (claude-workflow-plugin-k6re, R2-F1: found
              forgeable on its own first independent review -- no verifiable
              author, a bare-prefix match, and a write path bd import /
              hand-typed comments could reach without validation). A
              malformed REVIEW-ARTIFACT candidate now refuses
              unconditionally and permanently; see the tombstone comment
              where cmd_quarantine_artifact used to be defined.
USAGE
}

# emit_error_json: structured error envelope for the grade-record subcommand.
# Mirrors emit_json's shape but adds `error_key` and `usage` fields so the
# QA agent can re-prompt the grader with precision. Emitted to stdout.
emit_error_json() {
    # emit_error_json <subcommand> <task_id> <error_key> <observations> <usage_line>
    local sub="$1" tid="$2" ekey="$3" obs="$4" usage_line="$5"
    # shellcheck disable=SC2016
    printf '{"ok":false,"subcommand":%s,"task_id":%s,"status":"error","error_key":%s,"observations":%s,"usage":%s}\n' \
        "$(printf '%s' "$sub" | jq -Rs .)" \
        "$(printf '%s' "$tid" | jq -Rs .)" \
        "$(printf '%s' "$ekey" | jq -Rs .)" \
        "$(printf '%s' "$obs" | jq -Rs .)" \
        "$(printf '%s' "$usage_line" | jq -Rs .)"
}

require_bd() {
    if ! command -v bd >/dev/null 2>&1; then
        emit_json 0 "$1" "${2:-}" "error" "bd CLI not on PATH"
        exit 2
    fi
    if [ ! -d "$PROJECT_DIR/.beads" ]; then
        emit_json 0 "$1" "${2:-}" "error" "Beads not initialized in project ($PROJECT_DIR/.beads missing)"
        exit 2
    fi
}

# Read labels for a task as a comma-joined string (empty on miss). Also
# returns — as THIS FUNCTION'S OWN EXIT STATUS, not a global variable — the
# underlying `bd show` exit code (claude-workflow-plugin-j7kk, 39cy), so a
# caller that needs to distinguish "confirmed zero labels" from "could not
# check at all" can: `labels="$(get_labels "$tid")"; rc=$?`. cmd_status is
# the one that does.
#
# EXIT STATUS, NOT A GLOBAL — and this is not a style preference, it is the
# fix for a bug this file SHIPPED once already. The first draft set a global
# GET_LABELS_RC from inside get_labels() and had cmd_status read it back
# after `labels="$(get_labels "$tid")"`. MEASURED, by actually running the
# paired test below (not by reasoning about it): that never worked. A
# command substitution forks a SUBSHELL, so GET_LABELS_RC=1 assigned inside
# get_labels() dies with that subshell — the parent's GET_LABELS_RC stayed
# at its unset-by-the-caller value (0) on every single call, so cmd_status's
# reachability check never fired at all, and `bash -x` had to be read to see
# it (`bash -x qa-gate.sh status <id>` shows `++ GET_LABELS_RC=1` inside the
# subshell's own trace depth, then control returns to the parent with the
# global untouched). This codebase already has the general form of this
# gotcha written down twice — model-select.sh's ROLE_FALLBACK_FILE and
# session-start.sh's ss_context() both route a subshell-local fact out
# through a FILE instead of a variable — but a function's own RETURN STATUS
# is not subject to it: `var=$(fn)` sets `$?` to fn's exit status in the
# PARENT shell, even though nothing fn assigned survives.
#
# `bd show <id> --json` returns either an object or a 1-element array
# depending on the bd version, so we handle both shapes.
#
# claude-workflow-plugin-k6re R17 class sweep, CORRECTED by R19-F1: this
# function's `raw=$(bd show "$1" --json 2>/dev/null)` was changed from a
# bare assignment to `|| rc=$?` on the theory that the bare form aborted the
# whole process before `rc=$?` next line ever ran. That theory does not
# reproduce, and is corrected here (the code is unchanged — it is
# behaviour-preserving either way, see the A/B below — only the claim about
# why is fixed): this function is invoked ONLY through `$(...)` at every
# call site (every caller captures its output), and command substitution
# does NOT enforce `errexit` within its own subshell on this bash build (see
# the BARE-SUBSTITUTION-CENSUS block after `set -e` near the top of this
# file for the probe that establishes this). So `raw=$(bd show ...)` failing
# never stopped `rc=$?` from running, in EITHER form — A/B, stubbing `bd` to
# fail, confirms the internal `rc=$?` line executes and captures the same
# real exit code whether the assignment is bare or guarded, and the OUTER
# caller's behaviour (abort when the whole call is written bare and
# unwrapped; clean `if`-false when wrapped) is IDENTICAL between the two
# forms. The "EXIT STATUS, NOT A GLOBAL" contract this header already
# claims was already true on its own terms before this change, for a reason
# this comment previously misdiagnosed.
#
# `|| rc=$?` (matching this file's own established idiom for exactly this
# shape — see `review_out=$(... gate ...) || review_rc=$?`, further down in
# this file) is kept anyway: it states the contract explicitly in the
# source rather than leaving a future reader to already know that command
# substitution is errexit-inert here, and it is the form that would start
# to matter functionally if this script were ever run under bash >= 4.4
# with `shopt -s inherit_errexit` explicitly enabled (nothing in this file
# sets it today).
get_labels() {
    local raw rc=0
    raw=$(bd show "$1" --json 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    printf '%s' "$raw" \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null
    # No explicit `return` after the pipe on purpose: this function's exit
    # status is jq's — a bd-succeeded-but-unparseable response is ALSO
    # "could not determine the labels", the same as a bd failure above.
}

has_label() {
    # has_label <task-id> <label>
    #
    # claude-workflow-plugin-k6re R17 class sweep, corrected by R19-F1's
    # review (the conclusion below survives; ONE sentence describing WHY was
    # wrong and is fixed here — see get_labels()'s own comment for the
    # broader correction, which does NOT apply to this function the same
    # way: has_label is called DIRECTLY by every existing caller, never
    # through `$(...)`, so — unlike get_labels — its OWN calling context is
    # what actually matters here, not command-substitution inertness.
    # `labels="$(get_labels "$1")"` is a bare quoted command-substitution
    # assignment (POSIX ties an assignment's exit status to its command
    # substitution's regardless of quoting — verified empirically, not
    # assumed).
    #
    # REACHABILITY: every call site of has_label() in this file today (10 of
    # them, checked individually) sits inside an `if`/`!`/non-final `&&`/`||`
    # context — e.g. `has_label ... && was_x=1`, `has_label ... || continue`
    # — each of which transitively exempts this function's OWN body from
    # `set -e` for that invocation (ordinary function-call errexit exemption
    # — confirmed with an isolated probe that this holds independent of the
    # `$(...)`-inertness question, which is a different mechanism entirely).
    # So, as of this change set, nothing currently calls has_label() in a
    # way this specific line could abort through. Guarded anyway: that
    # protection is a property of how today's ten callers happen to be
    # written, not a contract this function documents or enforces.
    # CORRECTED EXAMPLE of what would actually reopen it (an earlier version
    # of this comment named `x=$(has_label ...)` and `present=$(has_label
    # ...; echo $?)` — both WRONG: wrapping the whole call in `$(...)` puts
    # it inside the same command-substitution-inertness zone get_labels
    # benefits from, unconditionally, regardless of this guard): a caller
    # that invokes `has_label "$tid" "$lbl"` as a fully BARE, UNTESTED
    # statement — no `if`, no `&&`/`||`, no `$(...)` around it at all, from
    # a context that is itself not exempt (e.g. directly inside a `cmd_*`
    # dispatched straight from this file's top-level `case`) — is the shape
    # that would still abort without this guard, because that is the one
    # shape where has_label's own body runs where `set -e` is genuinely
    # enforced.
    # `|| true`, not a captured rc: this function does not need to
    # distinguish "confirmed absent" from "unreadable" — either way
    # `$labels` reads empty, `,,` never contains `,$2,`, and has_label
    # correctly reports "not present" for both.
    local labels
    labels="$(get_labels "$1")" || true
    echo ",$labels," | grep -q ",$2,"
}

# label_in <labels-csv> <label> — membership test over an ALREADY-FETCHED
# comma-joined label list (same bounding-comma convention has_label uses),
# so a caller that already called get_labels once does not re-query bd per
# label. cmd_status is the caller: it used to call has_label up to five
# times per invocation (rubric-satisfied, rubric-pending, qa-approved,
# qa-blocked, qa-gate-entered), each re-running `bd show`.
label_in() {
    case "$1" in
        *",$2,"*) return 0 ;;
        *)        return 1 ;;
    esac
}

add_label() {
    # add_label <task-id> <label> -> 0 on success
    bd label add "$1" "$2" >/dev/null 2>&1
}

remove_label() {
    # remove_label <task-id> <label> -> 0 only when the label is ABSENT afterwards.
    #
    # l1r.3. This was a bare `bd label remove "$1" "$2" >/dev/null 2>&1` whose exit
    # status was the only evidence any caller had that a label went away, and that
    # evidence is worth nothing. MEASURED against bd 1.1.2, the version this repo
    # runs:
    #   - `bd label remove <tid> <label-the-task-never-had>` prints
    #     "Removed label ..." and exits 0;
    #   - `bd label remove <nonexistent-task-id> <label>` prints
    #     "Error resolving <id>: no issue found matching ..." and ALSO exits 0.
    # So the status could not distinguish "removed" from "did nothing at all", and
    # every rollback block in this file that branches on it was decorative.
    #
    # NOW: run the removal, then read the task back. The contract is a
    # POSTCONDITION — "this label is not on this task" — not "a removal was
    # applied". The difference is load-bearing in both directions:
    #   - removing an ABSENT label still succeeds, which is exactly what
    #     remove_escalation_labels and the two remove_rubric_* helpers rely on:
    #     they fire unconditionally on labels that are usually not there.
    #   - a task that cannot be READ reports its label set as empty (get_labels
    #     swallows the error and returns ""), so the postcondition holds vacuously
    #     and this returns 0. That is the honest limit of the check: it proves the
    #     label is gone, it cannot tell "gone" from "unreadable", and callers that
    #     need the task to exist establish that separately (require_bd, plus the
    #     has_label captures at the top of cmd_approve).
    #
    # SCOPE, against l1r.3's own reproduction rather than against its title. That
    # reproduction is a stale-JSONL auto-import RESURRECTING an already-removed
    # label, and its item 2 records that `bd show` immediately after the removal
    # agreed the label was gone — i.e. a read-back at this point would have passed,
    # and the label returned on a later read. One read-back cannot observe a future
    # import, so this closes the removal that never landed, not the removal that is
    # undone afterwards. The second half is a bd-level divergence between
    # beads.db-wal and issues.jsonl and has no fix inside this function.
    bd label remove "$1" "$2" >/dev/null 2>&1 || true
    ! has_label "$1" "$2"
}

add_comment() {
    # Newer Beads: `bd comments add` (plural). Older: `bd comment add`.
    # Try plural first, fall back if needed. Comments are non-authoritative
    # (labels are the source of truth) but failures are still logged to
    # sync-errors.log so SessionStart can surface them.
    bd comments add "$1" "$2" >/dev/null 2>&1 \
        || bd comment add "$1" "$2" >/dev/null 2>&1 \
        || log_sync_error "bd comments add failed for $1 (msg=$(printf '%s' "$2" | head -c 60))"
}

# ---------------------------------------------------------------------------
# Subcommands

cmd_enter() {
    local tid="$1"
    [ -z "$tid" ] && { usage; exit 1; }
    require_bd "enter" "$tid"

    # Spec 0.2: a fresh enter is the "resumes normal gating" signal for a
    # deferred task. Clearing the escalation labels + cached state on every
    # enter (idempotent path included) means a re-entered task starts a
    # clean review cycle. Doing this before the idempotent short-circuit
    # below also handles the case where the operator re-enters an
    # already-entered task that happens to carry qa-escalated/qa-deferred.
    local was_escalated=0 was_deferred=0
    has_label "$tid" "qa-escalated" && was_escalated=1
    has_label "$tid" "qa-deferred" && was_deferred=1
    if [ "$was_escalated" = "1" ] || [ "$was_deferred" = "1" ]; then
        remove_escalation_labels "$tid"
    fi
    # Spec 0.2: also wipe the per-iteration cache + counter so the next
    # Stop runs the full suite from scratch (resumes normal gating).
    wipe_iteration_state "$tid"

    # Spec Phase A + bjx (v4.1 U1): what an enter does to a rubric verdict
    # already on the task, and why that is now a decision rather than a wipe.
    #
    # WAS: clear rubric-satisfied unconditionally, re-arm rubric-pending. That
    # is right for the case it was written for — a satisfied verdict from a
    # PREVIOUS change set must never carry into a new review cycle — and wrong
    # for the ordering the relay actually walks. `grade-record` runs in the
    # ORCHESTRATOR's turn (RUBRIC-RELAY step C) and QA acts on the verdict in a
    # LATER spawn (step D); any Stop in between blocks and PRINTS
    # `qa-gate.sh enter <id>` — the QA-required block's "when entering review,
    # mark the gate" line, and the LABEL_WITHOUT_RECORD remediation, both in
    # verify-before-stop.sh. Following the gate's own printed instruction then
    # destroyed a verdict recorded seconds earlier against the IDENTICAL change
    # set, and the approve that followed warned "no satisfied verdict on file"
    # — false, and the thing qa.md 6f answers with a written OVERRIDE reason.
    # The gate was manufacturing overrides against its own audit trail, and
    # driving re-grades (a paid grader spawn) of an already-graded diff.
    #
    # That reachability is MECHANICAL, which is why the fix is here and not in
    # the relay's prompt text: the `enter` in that position is emitted by a
    # hook, so no ordering rule written into orchestrator.md or qa.md can be
    # relied on to avoid it.
    #
    # NOW: the clear is conditional on two independent tests, both conservative,
    # and it still fires whenever either is unmet.
    #
    #   1. THE CYCLE MUST ALREADY BE OPEN (qa-gate-entered set). A fresh enter
    #      opens a NEW review cycle and always clears — byte-identical to the
    #      old behaviour, and precisely the case the unconditional clear
    #      existed for. `approve` deliberately leaves rubric-satisfied behind
    #      as the audit trail of what backed it, so "a label survived an
    #      approve" is the normal input to this branch, not an anomaly.
    #   2. THE VERDICT MUST BIND THE CURRENT CHANGE SET. The latest RUBRIC
    #      record must be a `satisfied` one carrying a change_set_hash equal to
    #      the hash right now. A verdict recorded before the specialist touched
    #      three more files does not cover them and still clears.
    #
    # Test 2 needs positive evidence to preserve, so every way of failing to
    # produce it degrades to the pre-bjx behaviour: a pre-bjx RUBRIC comment
    # carries no token, a verdict superseded by a later needs_revision does not
    # answer, a version outside the validated class does not parse, and an
    # unavailable hash — in EITHER of its two spellings, empty or the
    # $CHANGE_SET_HASH_UNAVAILABLE sentinel — is refused. In all of them the
    # label is cleared, which is what the gate did before.
    #
    # THE SENTINEL IS CHECKED HERE, not only in the reader, because this is
    # where its shape actually bites: it is a CONSTANT, so on a host with
    # neither shasum nor sha256sum both sides of the comparison below would be
    # that same constant and the guard would match unconditionally — preserving
    # every verdict on the one class of machine where the hash means nothing.
    # The reader refuses it too (a legacy record may already carry it); the two
    # checks are not redundant, they cover a written record and a live recompute.
    #
    # KNOWN LIMIT, inherited and deliberately not narrowed here: the canonical
    # change-set hash is over the changed-file LIST, not file contents (see
    # impact-report.sh). Rewriting an ALREADY-TRACKED file after grading does
    # not move it, so a verdict can be preserved across content the grader never
    # saw. That is the single canonicalisation shared with the qa-approved
    # record (llh.18) and reviewed_hash (jio.1); computing a content hash here
    # would be a fourth definition of "the change set", which is exactly what
    # llh.18 exists to forbid. Pinned as documented behaviour by section B3 of
    # .claude/tests/component/specs/rubric-binding.sh rather than left latent.
    #
    # The live recompute is deliberate, rather than set_idempotency_reference's
    # tracker-or-persisted-report split: `enter` opens a cycle over the change
    # set that exists NOW, and the persisted report is a statement about when
    # the report was last written, not about when the verdict was graded — a
    # report refreshed after grading would vouch for a diff nobody graded.
    local was_rubric_satisfied=0 already_entered=0
    local rubric_preserved=0 rubric_verdict_obs=""
    has_label "$tid" "rubric-satisfied" && was_rubric_satisfied=1
    has_label "$tid" "qa-gate-entered" && already_entered=1
    if [ "$was_rubric_satisfied" = "1" ]; then
        if [ "$already_entered" = "1" ]; then
            local graded_hash="" current_hash=""
            graded_hash=$(latest_satisfied_rubric_hash "$tid") || graded_hash=""
            current_hash=$(compute_change_set_hash) || current_hash=""
            if [ "$current_hash" = "$CHANGE_SET_HASH_UNAVAILABLE" ]; then
                current_hash=""
            fi
            if [ -n "$current_hash" ] && [ "$graded_hash" = "$current_hash" ]; then
                rubric_preserved=1
                rubric_verdict_obs="; kept rubric-satisfied — the recorded verdict binds this exact change set (change_set_hash=$current_hash), so this re-entry resumes the open cycle rather than re-opening the rubric loop"
            else
                rubric_verdict_obs="; cleared stale rubric-satisfied (graded change set ${graded_hash:-<unbound>} does not match the current one ${current_hash:-<unavailable>})"
            fi
        else
            rubric_verdict_obs="; cleared stale rubric-satisfied (a fresh gate cycle re-opens the rubric loop)"
        fi
        if [ "$rubric_preserved" = "0" ]; then
            remove_rubric_satisfied "$tid"
        fi
    fi

    # jue: an enter does not leave a PRIOR CYCLE's qa-approved behind, in EITHER
    # arm. Decided here, above the early-return, for the same reason the rubric
    # decision is: both arms need an answer and only one of them reaches the code
    # below.
    #
    # THE FRESH ARM (no qa-gate-entered yet). Same reasoning as the legacy
    # approved-baseline removal further down this function — a new gate cycle
    # invalidates the previous cycle's credentials — and note that bjx's
    # conditional preservation of rubric-satisfied does NOT apply here: that
    # condition lives in the already-entered arm, and the fresh arm clears
    # rubric-satisfied unconditionally too, because a fresh cycle re-opens the
    # loop. jue was filed for two symptoms: approve short-circuiting as a no-op so
    # no fresh bound record was ever written (since narrowed by gz3's hash-aware
    # idempotency, which no longer no-ops when the change set has moved), and a
    # watcher polling the LABEL reading a prior-cycle approval as a verdict on new
    # commits. The second symptom is untouched by gz3 and is what this closes: the
    # label goes away when the cycle it belonged to ends.
    #
    # THE EARLY-RETURN ARM (qa-gate-entered already set). It clears too, and the
    # argument is different: {qa-gate-entered, qa-approved} is not reachable
    # through this script's own transitions, because approve removes
    # qa-gate-entered as part of the same sweep that adds qa-approved. So a task in
    # this arm holding qa-approved did not get it from a clean approve of the open
    # cycle. The two ways it arrives are label inheritance (bd 1.1.2's
    # `create --parent` copies gate labels from the parent, transitively — see rmz)
    # and a partially applied transition. Both are states where the label is not a
    # verdict on anything, and leaving it would hand a release credential to a task
    # whose review cycle is open.
    #
    # THIS ARM ALSO WRITES NO CYCLE RECORD, which is a separate open defect and NOT
    # fixed here: a task born with qa-gate-entered can be entered, take this arm,
    # and still have zero `QA-GATE: entered` records. Do not read a qa-gate-entered
    # label as evidence that this function ever ran on the task.
    local had_prior_approval=0 approval_clear_obs=""
    has_label "$tid" "qa-approved" && had_prior_approval=1
    if [ "$had_prior_approval" = "1" ]; then
        local approval_clear_why=""
        if [ "$already_entered" = "1" ]; then
            approval_clear_why="the label cannot be a verdict on an OPEN cycle — approve clears qa-gate-entered when it sets qa-approved, so this pair is unreachable through the gate's own transitions (inherited from a parent, or a partially applied transition)"
        else
            approval_clear_why="a fresh gate cycle supersedes the previous cycle's approval, the same way it invalidates that approval's legacy baseline"
        fi
        if remove_label "$tid" "qa-approved"; then
            approval_clear_obs="; cleared a prior cycle's qa-approved ($approval_clear_why) — re-approve to record a verdict on this cycle"
        else
            approval_clear_obs="; WARNING a prior cycle's qa-approved is set and could NOT be cleared ($approval_clear_why); a label-polling reader will still see it as an approval of the current change set"
            log_sync_error "enter: failed to clear a prior cycle's qa-approved on $tid; the label survives an enter and any label-polling reader will treat it as a verdict on the new cycle"
        fi
    fi

    if [ "$already_entered" = "1" ]; then
        # Idempotent re-enter: the label is already there, but we still
        # refresh current-task in case it drifted (e.g., a different task
        # claimed it earlier in this session).
        #
        # rubric-pending is re-armed unless the verdict above was PRESERVED:
        # an already-entered task that lost rubric-pending (e.g. via a stale
        # grade-record from a prior cycle) belongs back in the awaiting-verdict
        # state, but a task whose satisfied verdict still binds the current
        # change set is not awaiting anything — re-arming there would put both
        # rubric labels on one task and tell cmd_status's reader that a graded
        # cycle is still pending.
        local rubric_refresh_obs=""
        if [ "$rubric_preserved" = "1" ]; then
            rubric_refresh_obs="rubric-satisfied kept (no new grading round needed)"
        else
            add_label "$tid" "rubric-pending" || true
            rubric_refresh_obs="rubric-pending refreshed"
        fi
        local refreshed_obs="qa-gate-entered already set; current-task refreshed; $rubric_refresh_obs"
        if ! write_current_task "$tid"; then
            refreshed_obs="qa-gate-entered already set; WARNING current-task write failed (see sync-errors.log); $rubric_refresh_obs"
        fi
        if [ "$was_escalated" = "1" ] || [ "$was_deferred" = "1" ]; then
            refreshed_obs="$refreshed_obs; cleared prior escalation labels (escalated=$was_escalated deferred=$was_deferred) and reset iteration state"
        fi
        refreshed_obs="$refreshed_obs$rubric_verdict_obs$approval_clear_obs"
        # TRACKER-RECONCILE BEGIN (94d)
        # Before the report is generated, not after: the report records the
        # change_set_hash of the tracker AS IT IS when it runs, and approve
        # refuses on any later drift. Reconciling first is what makes the
        # artifact cover the whole git-visible delta rather than the subset the
        # Write/Edit hook saw. Tolerant here for the same reason the report
        # itself is (enter is documented tolerant, qa-gate.sh:1102-1106 class);
        # approve is where an unreconcilable tracker REFUSES.
        reconcile_tracker || true
        refreshed_obs="$refreshed_obs; $RECONCILE_OBS"
        # TRACKER-RECONCILE END (94d)
        # G2.n6d: refresh the mechanical impact report on re-enter too —
        # a resumed cycle reviews the CURRENT change set, so the artifact
        # must reflect it. Tolerant: enter never fails because of this.
        generate_impact_report "$tid" || true
        refreshed_obs="$refreshed_obs;$IMPACT_REPORT_OBS"
        emit_json 1 "enter" "$tid" "entered" "$refreshed_obs"
        return 0
    fi

    if ! add_label "$tid" "qa-gate-entered"; then
        emit_json 0 "enter" "$tid" "error" "failed to add qa-gate-entered label"
        exit 2
    fi

    # Spec Phase A: arm the rubric loop. Best-effort — a failed add is
    # logged but does not roll back the gate (the rubric workflow is an
    # input to QA, not a gate).
    if ! add_label "$tid" "rubric-pending"; then
        log_sync_error "enter: failed to add rubric-pending label on $tid"
    fi

    # 0wk.2 fix: a new gate cycle invalidates the previous approval's LEGACY
    # baseline. Without this, an approve from cycle N would leave its baseline
    # behind so verify-before-stop in cycle N+1 (post re-enter) would treat
    # ALL N+1 edits as already-approved.
    rm -f "$LEGACY_APPROVED_BASELINE" 2>/dev/null || true

    # gate-baseline v2 (3mg.1): WRITE-IF-MISSING, minus already-tracked files.
    #
    # Not an unconditional refresh, and not a delete either:
    #   - refresh would baseline the whole dirty tree at the moment a review
    #     cycle opens, i.e. hand this cycle's own work a free pass;
    #   - delete would leave the cycle with no reference point at all, so a
    #     repo that was merely dirty on arrival re-blocks every Stop (the
    #     0wk.2 symptom, and transcript scenario 1).
    # Write-if-missing gives a cycle started in a fresh session the
    # session-start baseline, and a cycle started in a session that never had
    # one a baseline captured now — with the session's ALREADY-tracked edits
    # excluded so they stay gated. Best-effort: enter never fails on it.
    if ! write_gate_baseline "qa-gate-enter" --if-missing --exclude-tracked; then
        log_sync_error "enter: gate-baseline capture failed for $tid (gate still correct; the Stop fallback treats all git dirt as new)"
    fi

    # F3: persist active task as side effect so hooks can find it. Failures
    # are logged to sync-errors.log AND surfaced in the JSON observation
    # (previously silently swallowed by `|| true`).
    local persist_warn=""
    if ! write_current_task "$tid"; then
        persist_warn=" WARNING: current-task helper write failed (see sync-errors.log); hooks will see no active task."
    fi

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    add_comment "$tid" "QA-GATE: entered at $ts"

    # TRACKER-RECONCILE BEGIN (94d)
    # Fold every git-visible path the Write/Edit hook never saw into the tracker
    # BEFORE the impact report binds a change_set_hash to it.
    #
    # AFTER write_gate_baseline above, and the order is not arbitrary. The
    # reconciler subtracts the baseline, so with one in place a cycle opening in
    # a dirty tree reconciles only this session's delta. Reversing the two would
    # be worse, not better: with no baseline yet, the reconciler would append the
    # ENTIRE dirty tree — someone else's half-finished refactor included — into
    # this task's change set and its approval binding, which is the 0wk.2 symptom
    # the baseline exists to prevent.
    #
    # RESIDUAL, inherited and unresolvable here: when NO baseline exists at this
    # point, write_gate_baseline --exclude-tracked can only exclude what the
    # TRACKER knows, so a Bash-written file gets baselined as "pre-existing" and
    # the reconcile below then finds nothing new. Reaching that state needs a
    # session with no session-start baseline AND no prior enter (session-start
    # skips the capture while a cycle is active, and enter/approve both write
    # one), so it is rare — but it is real, and it cannot be fixed by reordering:
    # without a baseline there is no signal that separates "dirty because this
    # session wrote it" from "dirty on arrival". The fix would be a session-start
    # capture that runs even mid-cycle, which is claude-workflow-plugin-fkm.1.2's
    # half (a), not this one's.
    #
    # Tolerant (enter is documented tolerant); approve is where this refuses.
    reconcile_tracker || true
    # TRACKER-RECONCILE END (94d)

    # G2.n6d: generate the mechanical impact report as part of packet
    # assembly. Tolerant by contract — a failed generation degrades to a
    # WARNING in the observations + sync-errors.log; enter still succeeds.
    # (approve is where the artifact is ENFORCED.)
    generate_impact_report "$tid" || true

    local extra_obs=""
    if [ "$was_escalated" = "1" ] || [ "$was_deferred" = "1" ]; then
        extra_obs=" cleared prior escalation labels (escalated=$was_escalated deferred=$was_deferred) and reset iteration state."
    fi
    # bjx: reaching here means already_entered was 0, so the rubric decision
    # above can only have been the fresh-cycle clear — preservation is
    # unreachable on this path by construction, and the observation says which
    # of the two clears fired rather than just that one did.
    extra_obs="$extra_obs$rubric_verdict_obs$approval_clear_obs"
    # TRACKER-RECONCILE BEGIN (94d)
    extra_obs="$extra_obs; $RECONCILE_OBS"
    # TRACKER-RECONCILE END (94d)
    emit_json 1 "enter" "$tid" "entered" "qa-gate-entered + rubric-pending labels set at $ts; current-task persisted.$persist_warn$extra_obs$IMPACT_REPORT_OBS"
}

cmd_status() {
    local tid="$1"
    [ -z "$tid" ] && { usage; exit 1; }
    require_bd "status" "$tid"

    # ONE bd show call for the whole subcommand (was up to five: has_label
    # re-queried bd per label — rubric-satisfied, rubric-pending, qa-approved,
    # qa-blocked, qa-gate-entered). This is ALSO the reachability check
    # (claude-workflow-plugin-j7kk, 39cy): `bd show` failing for ANY reason —
    # schema skew, an unreachable store, a wedged daemon — must not be
    # reported as "no labels present". That reading is indistinguishable from
    # a task that has simply never been entered, to every caller of this
    # subcommand — MEASURED: this exact confusion shipped live as
    # {"ok":true,"status":"not-entered"} against a store that could not be
    # read at all, during the schema-skew incident this task fixes.
    # Unavailable is not not-entered, so it gets its OWN status, ok:false, and
    # a distinct non-zero exit code — never folded into the precedence
    # cascade below, which is only ever reached once the read is confirmed to
    # have worked.
    local labels labels_rc=0
    # THIS FILE RUNS UNDER `set -e` (line 196 as of the R17 class sweep —
    # this comment previously said "line 155", stale even before this round;
    # corrected in passing while re-verifying it, the way any other line
    # number cited from memory in this file should be). A bare
    # `labels="$(get_labels "$tid")"` on its own line is NOT one of set -e's
    # exemptions (an `if`/
    # `while`/`until` condition, or a command before `&&`/`||`) — MEASURED,
    # by actually running the paired test below: when get_labels() returned
    # non-zero, the script ABORTED right there under `set -e`, before a
    # following `labels_rc=$?` line ever ran (bash -x showed the trace stop
    # dead after `+ labels=`, no `exit 3`, no JSON, just termination). Using
    # the command substitution as an `if` CONDITION is the documented set -e
    # exemption, so the exit status is captured instead of triggering it.
    if labels="$(get_labels "$tid")"; then
        labels_rc=0
    else
        labels_rc=$?
    fi
    # --- STATUS-UNAVAILABLE-BEGIN (claude-workflow-plugin-j7kk) -------------
    # $labels_rc, captured via the if/else above (not a global variable
    # get_labels() might have set from inside it) — see get_labels()'s own
    # header for why a global does not work (a subshell-boundary bug this
    # file shipped once already), and the paragraph above for why even a
    # plain `$?` read on the next line does not, under this file's `set -e`.
    if [ "$labels_rc" -ne 0 ]; then
        emit_json 0 "status" "$tid" "unavailable" "bd show $tid --json failed (rc=$labels_rc) — the store could not be read, so qa lifecycle state is UNKNOWN, not absent. Check bd reachability (bd doctor), bd-version-vs-store-schema compatibility (workflow-doctor.sh's beads check), and .beads/daemon.log before treating this as a task that needs QA entry."
        exit 3
    fi
    # --- STATUS-UNAVAILABLE-END (claude-workflow-plugin-j7kk) ---------------
    labels=",$labels,"

    # Spec Phase A: surface rubric state alongside the qa state. Precedence
    # matches the label semantics: satisfied > pending > none. The rubric
    # state is informational — it does NOT change the qa-state precedence
    # below (principle 6: qa-approved is the only Stop-hook signal).
    local rubric_state="none"
    local rubric_obs="no rubric labels present"
    if label_in "$labels" "rubric-satisfied"; then
        rubric_state="satisfied"
        rubric_obs="rubric-satisfied label present"
    elif label_in "$labels" "rubric-pending"; then
        rubric_state="pending"
        rubric_obs="rubric-pending label present"
    fi

    # Precedence: approved > blocked > entered > not-entered.
    if label_in "$labels" "qa-approved"; then
        emit_json 1 "status" "$tid" "approved" "qa-approved label present; rubric=$rubric_state ($rubric_obs)"
        return 0
    fi
    if label_in "$labels" "qa-blocked"; then
        emit_json 1 "status" "$tid" "blocked" "qa-blocked label present; rubric=$rubric_state ($rubric_obs)"
        return 0
    fi
    if label_in "$labels" "qa-gate-entered"; then
        emit_json 1 "status" "$tid" "entered" "qa-gate-entered label present, awaiting approve/block; rubric=$rubric_state ($rubric_obs)"
        return 0
    fi
    emit_json 1 "status" "$tid" "not-entered" "no qa lifecycle labels present; rubric=$rubric_state ($rubric_obs)"
}

# APPROVE-SUCCESS-GATE BEGIN (claude-workflow-plugin-k6re R6-F2)
#
# THE SECOND REACH-AROUND OF THE SAME ARM, same shape as the first. A2
# (claude-workflow-plugin-i8cx) found that the hash-aware idempotency no-op
# inside cmd_approve (see IDEMPOTENCY, and IDEMPOTENT-APPROVE-CONFLICT-
# RECHECK nested inside it, below) could report status=approved without
# ever consulting compute_design_conflict_open — fixed by hand-adding a
# second call site of that predicate INSIDE the arm. Independent review
# (claude-workflow-plugin-k6re, round 6, finding R6-F2) found the SAME arm
# skips a second, unrelated precondition the identical way: --expect-hash.
# The documented contract (EXPECTED-HASH-REFUSAL below, and this
# subcommand's own usage text) states it unconditionally — "REFUSES ...
# when that is not the set this approval would bind" — but the check that
# enforces it sat only on the path AFTER the idempotent arm's OWN
# `return 0`, so a caller passing a stale or wrong --expect-hash to an
# already-bound task got a success envelope naming a hash it explicitly
# said it did not expect, never a refusal.
#
# WHY A GATE FUNCTION, NOT A THIRD HAND-COPIED GUARD. Two independent
# precondition gaps found in the SAME ~100-line arm, by two SEPARATE
# independent review passes, is the definition of a recurring family: the
# arm's `return 0` is a success-emitting exit, and every precondition that
# must hold before ANY exit of cmd_approve reports success has to be
# manually remembered and re-added to it, with nothing in the language
# stopping a third one from being forgotten the same way. This function is
# the single funnel: a raw `status=approved` envelope for this subcommand
# is never printed directly anywhere else in cmd_approve — both
# of its success-reporting exits (the idempotent no-op, and the
# fresh-approval path's own success line at the end of the function) call
# THIS function instead, so a precondition placed here applies identically
# at both, by construction, rather than by two authors each remembering to
# duplicate it by hand. approve-success-gate.test.sh's structural leg fails
# loudly if a THIRD `status=approved` emission is ever added to cmd_approve
# outside this function (it greps the literal count, which this fix makes
# exactly 1 for the raw emit and exactly 2 for calls into this gate), and
# its non-vacuity leg proves that assertion would actually catch one.
# approve-idempotency.sh's own Section J/JM proves the BEHAVIOUR end to
# end against a real approve invocation, with an anchor-revert META that
# strips the check below and watches the R6-F2 forgery reappear.
#
# WHAT THIS DELIBERATELY DOES NOT COVER. compute_design_conflict_open is
# NOT folded in here. Its two existing call sites (A2's copy inside the
# idempotent arm, and the main path's own DESIGN-CONFLICT-REFUSAL block)
# are untouched — both are proven, independently reviewed across ten
# rounds, and already documented in detail as to why they are the right
# shape; moving them into a new function on a task scoped to a DIFFERENT
# finding would risk a working mechanism for no evidenced gain. THE
# RESIDUAL, stated rather than assumed: a FIFTH reach-around of this same
# arm looks like a THIRD precondition (a rubric-hash recheck, a
# review-separation recheck, or a later consolidation of design-conflict
# into this same gate) added as a fourth hand-copied inline guard instead
# of being placed here — nothing in bash stops that by construction, only
# the structural test above (which catches a stray new success emission)
# and this comment (which tells that future author where the existing ones
# live). Whether compute_design_conflict_open should ALSO move here is an
# open question this fix leaves for whoever next touches this arm, the
# same way A2 itself left --expect-hash's gap open rather than auditing
# every one of the arm's other skipped refusal families (see
# IDEMPOTENT-APPROVE-CONFLICT-RECHECK's own "WHY THIS IS THE ONLY AXIS
# RE-VERIFIED HERE" paragraph, below).
#
# EXPLICIT PARAMETERS, NOT AMBIENT SCOPE. bash resolves a caller's `local`
# through the call stack — verified directly: a function called from
# inside another function DOES see that function's locals — so this could
# have read cmd_approve's own $expect_hash_arg without it ever being
# passed. It takes it as a parameter instead, matching the convention every
# other cmd_approve helper already uses (compute_design_conflict_open
# "$tid", task_has_approval_record_for "$tid" "$hash"): a function whose
# behaviour depends on which local variable NAME its caller happens to have
# chosen is harder to audit in isolation than one whose inputs are all in
# its own signature.
#
# error_key and remediation text are byte-similar to the main path's own
# EXPECTED-HASH-REFUSAL below on purpose (same reasoning A2 gives for
# design_conflict_open: a caller or test keyed on error_key must not care
# which of cmd_approve's two success exits caught the mismatch).
emit_approve_success() {
    local tid="$1" bound_hash="$2" expect_hash="$3" observations="$4"

    # APPROVE-SUCCESS-GATE-EXPECT-HASH BEGIN (claude-workflow-plugin-k6re R6-F2)
    if [ -n "$expect_hash" ] && [ "$expect_hash" != "$bound_hash" ]; then
        emit_error_json "approve" "$tid" "expected_hash_mismatch" \
            "approve refused: the caller expected to approve change set $expect_hash but this approval would bind $bound_hash. The two reads straddle something that moved the change set — most often a path that arrived after the caller classified it (the F1 doc-only fast path passes the hash of the set it classified, so a source file landing mid-Stop lands here rather than being approved under a doc-only verdict). NOTE: this proves the bound set is the CLASSIFIED set; it does NOT prove that set is complete (claude-workflow-plugin-fkm.1.20). Re-derive the current set and decide: bash .claude/scripts/impact-report.sh --hash-only — then either re-review at the new hash and approve without --expect-hash, or pass the hash you actually reviewed." \
            "qa-gate.sh approve <task-id> [--expect-hash <hash>] [--accept-reconstructed '<reason>'] [--no-impact-report '<reason>'] [--no-review '<reason>'] <summary>"
        exit 2
    fi
    # APPROVE-SUCCESS-GATE-EXPECT-HASH END (claude-workflow-plugin-k6re R6-F2)

    emit_json 1 "approve" "$tid" "approved" "$observations"
}
# APPROVE-SUCCESS-GATE END (claude-workflow-plugin-k6re R6-F2)

cmd_approve() {
    local tid="${1:-}"
    shift || true

    # G2.n6d: parse the documented impact-report bypass. The flag may
    # appear anywhere after the task id; every other argument joins the
    # approval summary (preserving the historical `summary="$*"` shape
    # for multi-word callers).
    local bypass_impact=0
    local bypass_reason=""
    local bypass_review=0
    local review_bypass_reason=""
    # UNRECORDED-REVIEW-ARTIFACT-REFUSAL (claude-workflow-plugin-k6re):
    # declared OUTSIDE the sentinel-wrapped block further down, for the same
    # two reasons impact_obs / review_obs are — the bypass path skips the
    # block but must still record WHY, and a stripped-copy META test stays
    # syntactically coherent.
    local bypass_unrecorded_review=0
    local unrecorded_review_bypass_reason=""
    local summary=""
    # CHANGE-SET-RECONSTRUCTED BEGIN (94d.1)
    local bypass_reconstructed=0
    local reconstructed_bypass_reason=""
    # CHANGE-SET-RECONSTRUCTED END (94d.1)
    # EXPECTED-HASH-REFUSAL BEGIN (qzv)
    local expect_hash_arg=""
    # EXPECTED-HASH-REFUSAL END (qzv)
    # COMPLETION-CONTRACT-REFUSAL (P7): declared OUTSIDE the sentinel-wrapped
    # block below, for the same two reasons impact_obs and review_obs are — the
    # bypass path skips the block but must still record WHY, and the META-TEST's
    # stripped copy has to stay syntactically coherent.
    local bypass_completion=0
    local completion_bypass_reason=""
    # DESIGN-SATISFIED-REFUSAL (v5 D2 / claude-workflow-plugin-fkm.4): same
    # discipline as the four bypass pairs above — declared OUTSIDE the
    # sentinel-wrapped block further down, for the same two reasons.
    local bypass_design=0
    local design_bypass_reason=""
    while [ $# -gt 0 ]; do
        case "$1" in
            # EXPECTED-HASH-REFUSAL BEGIN (qzv)
            --expect-hash)
                # qzv: the change set the CALLER classified, so approve can refuse
                # to bind a different one. Mirrors grade-record's --graded-hash
                # argument handling exactly; see the refusal block below for what
                # it does and why it sits where it does.
                expect_hash_arg="${2:-}"
                if [ -z "$expect_hash_arg" ]; then
                    emit_error_json "approve" "$tid" "missing_expected_hash" \
                        "--expect-hash requires a value (the change_set_hash of the set the caller classified; impact-report.sh --hash-only prints it)" \
                        "qa-gate.sh approve $tid --expect-hash <hash> '<summary>'"
                    exit 1
                fi
                # Validated for a DIFFERENT reason than --graded-hash's identical
                # check, and the difference is worth stating: this value is only
                # ever COMPARED, never written into a record's machine prefix, so
                # a stray character cannot relocate a field boundary. The check is
                # here so a caller who passed a shell-mangled or multi-word value
                # gets a usage error NAMING THE FLAG rather than an
                # `expected_hash_mismatch` that reads like a real drift detection
                # — a wrong answer that looks like the right one is the more
                # expensive failure.
                case "$expect_hash_arg" in
                    *[!A-Za-z0-9-]*)
                        emit_error_json "approve" "$tid" "expected_hash_invalid_chars" \
                            "--expect-hash='$expect_hash_arg' contains characters outside [A-Za-z0-9-], so it cannot be a canonical change-set hash; this is a usage error, NOT a change-set mismatch" \
                            "pass the value impact-report.sh --hash-only printed for the set you classified"
                        exit 1
                        ;;
                esac
                shift 2 || true
                ;;
            # EXPECTED-HASH-REFUSAL END (qzv)
            # CHANGE-SET-RECONSTRUCTED BEGIN (94d.1)
            --accept-reconstructed)
                # 94d.1: the audited bypass for the change_set_reconstructed
                # refusal below. Mirrors --no-impact-report / --no-review,
                # including the empty-reason refusal.
                #
                # This one HAS a bypass where tracker_unreconcilable deliberately
                # does not, and the difference is what the two predicates can
                # PROVE. "git status failed" is mechanical: the change set is
                # genuinely unknowable and no operator judgement can supply it.
                # "the tracker was empty and N paths were subtracted as
                # already-baselined" is INFERENTIAL: the same observation is
                # produced by a destroyed tracker and by a session whose work was
                # entirely Bash-mediated in a repo that was dirty on arrival.
                # reconcile cannot tell those apart (see its header) — a human
                # looking at the named paths can. Refusing with no exit would
                # deadlock the second case with nothing to fix.
                bypass_reconstructed=1
                reconstructed_bypass_reason="${2:-}"
                if [ -z "$reconstructed_bypass_reason" ]; then
                    emit_error_json "approve" "$tid" "bypass_reason_required" \
                        "--accept-reconstructed requires a non-empty reason; the bypass is recorded in the approval comment + gate JSON, and an unexplained bypass of the change-set completeness check is indistinguishable from approving a change set nobody established" \
                        "qa-gate.sh approve $tid --accept-reconstructed '<reason>' '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            # CHANGE-SET-RECONSTRUCTED END (94d.1)
            --no-impact-report)
                bypass_impact=1
                bypass_reason="${2:-}"
                if [ -z "$bypass_reason" ]; then
                    emit_error_json "approve" "$tid" "bypass_reason_required" \
                        "--no-impact-report requires a non-empty reason; the bypass is recorded in the audit trail and an unexplained bypass is indistinguishable from gate evasion" \
                        "qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            --no-review)
                # V3 (jio.1): the audited review-separation bypass. Mirrors
                # --no-impact-report exactly, including the empty-reason
                # refusal: a bypass with no recorded reason is
                # indistinguishable from gate evasion.
                bypass_review=1
                review_bypass_reason="${2:-}"
                if [ -z "$review_bypass_reason" ]; then
                    emit_error_json "approve" "$tid" "bypass_reason_required" \
                        "--no-review requires a non-empty reason; the bypass is recorded in the approval comment + gate JSON, and an unexplained bypass of the independent-review requirement is indistinguishable from signing off on your own work" \
                        "qa-gate.sh approve $tid --no-review '<reason>' '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            --accept-unrecorded-review)
                # claude-workflow-plugin-k6re (the HEADLINE defect): the
                # audited bypass for the review_artifact_unrecorded refusal
                # below. Mirrors --accept-reconstructed / --no-review exactly,
                # including the empty-reason refusal.
                #
                # A DEDICATED flag, not a reuse of --no-review, deliberately:
                # --no-review waives the WHOLE independent-review predicate
                # (including "no open findings", "reviewer independent") —
                # strictly more than this narrower fact ("a stray unrecorded
                # artifact sits on disk") needs waived, and folding the two
                # together would force an operator who only wants to
                # acknowledge the backlog to also silently waive findings
                # resolution they never intended to skip. THE INTENDED
                # PRODUCER is an operator reconciling a task with a legitimate
                # HISTORIC backlog (e.g. claude-workflow-plugin-i8cx, 9
                # WAVE-1-era artifacts never recorded) that needs a fresh
                # approval without being permanently stranded — see the
                # refusal's own comment for why a bypass-free refusal here
                # would convert an old silence into a new dead end.
                bypass_unrecorded_review=1
                unrecorded_review_bypass_reason="${2:-}"
                if [ -z "$unrecorded_review_bypass_reason" ]; then
                    emit_error_json "approve" "$tid" "bypass_reason_required" \
                        "--accept-unrecorded-review requires a non-empty reason; the bypass is recorded in the approval comment + gate JSON, and an unexplained bypass of the unrecorded-review-artifact check is indistinguishable from certifying a review that was never actually recorded" \
                        "qa-gate.sh approve $tid --accept-unrecorded-review '<reason>' '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            --no-completion)
                # P7: the audited completion-contract bypass. Mirrors
                # --no-impact-report / --no-review exactly, including the
                # empty-reason refusal — a bypass with no recorded reason is
                # indistinguishable from gate evasion.
                #
                # THE INTENDED PRODUCER is the Stop hook's F1 fast path, which
                # approves change sets that had no specialist and therefore owe
                # no completion payload. It passes
                #   --no-completion 'F1 <class> fast path: no specialist, no completion payload'
                bypass_completion=1
                completion_bypass_reason="${2:-}"
                if [ -z "$completion_bypass_reason" ]; then
                    emit_error_json "approve" "$tid" "bypass_reason_required" \
                        "--no-completion requires a non-empty reason; the bypass is recorded in the approval comment + gate JSON, and an unexplained bypass of the completion-contract requirement is indistinguishable from approving work nobody described" \
                        "qa-gate.sh approve $tid --no-completion '<reason>' '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            --no-design)
                # v5 D2 (claude-workflow-plugin-fkm.4): the audited bypass for
                # the design-satisfied refusal below. Mirrors --no-completion /
                # --no-review / --no-impact-report exactly, including the
                # empty-reason refusal — an unexplained bypass is
                # indistinguishable from gate evasion.
                #
                # THE INTENDED PRODUCERS are (a) a task that never had a
                # design phase — the ordinary case for most tasks — and (b) an
                # operator override when a design-satisfied refusal is judged
                # wrong for this task. Neither is assumed; both require the
                # reason, recorded in the approval comment as
                # `[design bypass: <reason>]` and in the gate JSON.
                bypass_design=1
                design_bypass_reason="${2:-}"
                if [ -z "$design_bypass_reason" ]; then
                    emit_error_json "approve" "$tid" "bypass_reason_required" \
                        "--no-design requires a non-empty reason; the bypass is recorded in the approval comment + gate JSON, and an unexplained bypass of the design-satisfied requirement is indistinguishable from approving unreviewed design work" \
                        "qa-gate.sh approve $tid --no-design '<reason>' '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            *)
                if [ -z "$summary" ]; then
                    summary="$1"
                else
                    summary="$summary $1"
                fi
                shift || true
                ;;
        esac
    done

    if [ -z "$tid" ] || [ -z "$summary" ]; then
        usage
        exit 1
    fi
    require_bd "approve" "$tid"

    # Capture rollback state up front.
    #
    # 8zi: qa-gate-entered and qa-pending are no longer captured here. They were
    # read only to decide whether to attempt a removal and to set the two envelope
    # counters, and set_terminal_label now does both from the state at sweep time —
    # which is after the reconcile, both refusals and the record write. Keeping a
    # copy taken earlier would be a second source of truth for the same question,
    # and the later one is the one that describes what the sweep did.
    local had_approved=0
    has_label "$tid" "qa-approved" && had_approved=1

    # Spec Phase A: snapshot rubric state for the warning + audit message.
    # NOTE per principle 6: approve does NOT hard-gate on rubric-satisfied.
    # The Stop-hook contract is touched only by qa-approved / qa-deferred;
    # the rubric is a QA input. The warning here surfaces the state so the
    # QA agent's prompt (A.2) can enforce the override-reason rule, and so
    # an audit reader can see whether approve happened with or without a
    # passing rubric verdict.
    local had_rubric_pending=0 had_rubric_satisfied=0
    has_label "$tid" "rubric-pending" && had_rubric_pending=1
    has_label "$tid" "rubric-satisfied" && had_rubric_satisfied=1

    # IDEMPOTENCY (gz3 / v4.1 U1) — HASH-AWARE, not label-aware.
    #
    # WAS: `had_approved = 1 -> no-op`. That made the LABEL mean "already
    # approved", which is exactly what llh.18 stopped believing on the Stop
    # side: release requires a RECORD bound to the current change set, because
    # the label is forgeable and says nothing about WHICH files were reviewed.
    # The two halves disagreeing produced a deadlock. A Stop blocked with
    # LABEL_WITHOUT_RECORD prints `enter -> impact-report -> approve`; `enter`
    # does not clear qa-approved; approve then short-circuited — so following
    # the printed remediation wrote no new record and the gate re-blocked
    # forever. The only working recovery was an undocumented
    # `bd label remove <tid> qa-approved` first.
    #
    # NOW: the no-op fires only when an existing record already binds the change
    # set this approve would bind (see set_idempotency_reference for which hash
    # that is, and why an empty tracker reads the persisted report instead of
    # recomputing). Otherwise approve PROCEEDS and re-verifies every
    # precondition — impact-report freshness, independent review, rubric state —
    # before writing a FRESH bound record. Nothing is waved through: a stale
    # label buys no exemption from the checks, it just stops being a dead end.
    #
    # The advertised contract ("re-approving an already-approved task is a
    # success no-op") is preserved for the case it was written for and dropped
    # exactly where it was wrong. Pinned in
    # .claude/tests/component/specs/approve-idempotency.sh (with a META that
    # reverts this guard to had_approved-only and shows the deadlock return).
    #
    # Both envelopes NAME THE REFERENCE they compared against
    # ($IDEM_REF_SOURCE). That is the diagnostic for the residual documented on
    # set_idempotency_reference: an operator staring at a gate that still
    # blocks after a no-op can see that approve matched the PERSISTED report and
    # that regenerating it (step 2 of the printed remediation) is the move.
    local stale_label_obs=""
    if [ "$had_approved" = "1" ]; then
        local idem_ref=""
        set_idempotency_reference "$tid"
        idem_ref="$IDEM_REF_HASH"
        if [ -n "$idem_ref" ] && task_has_approval_record_for "$tid" "$idem_ref"; then
# IDEMPOTENT-APPROVE-CONFLICT-RECHECK BEGIN (A2 / claude-workflow-plugin-i8cx,
# TIER 0 — a live reach-around of the design-conflict gate that TEN
# independent review rounds on this same axis did not catch, shipped in
# 18c9319)
            #
            # WHAT THIS ARM WAS ASSERTING, UNVERIFIED. "qa-approved is set AND
            # a record already binds change_set_hash=$idem_ref" was read as
            # "nothing has changed since that approval, so re-approving is a
            # safe no-op" — true for every refusal family whose truth is a
            # function of the FILES (tracker-reconcile, change-set-
            # reconstructed, impact-report, expect-hash all read the SAME
            # hash this idempotency check already matched), false for the one
            # family that is not: an open DESIGN-CONFLICT is a Beads comment
            # filed against a design UNIT, never against a change-set hash —
            # `design-conflict` takes no file argument and moves no tracked
            # path. Filing one after an approval, on a task nobody touches
            # again, produces exactly the state this arm used to read as
            # "safe": had_approved=1, idem_ref unchanged, a bound record for
            # it. Reproduced against the shipped script: approve -> file a
            # design-conflict --unit U1 -> a second approve reported
            # status=approved, exit 0 — the same open conflict
            # `design-gate-precheck` (correctly) exits 4 on.
            #
            # WHY THIS IS THE ONLY AXIS RE-VERIFIED HERE, not every refusal
            # this arm skips (tracker_unreconcilable, change_set_reconstructed,
            # REVIEW-SEPARATION, COMPLETION-CONTRACT-REFUSAL,
            # DESIGN-SATISFIED-REFUSAL — see this function's own
            # EXPECTED-HASH-REFUSAL comment above for the full seven-family
            # enumeration; --expect-hash used to belong on this list too,
            # until claude-workflow-plugin-k6re R6-F2 found the identical
            # reach-around shape here and closed it via emit_approve_success
            # — APPROVE-SUCCESS-GATE, above cmd_approve — rather than a
            # fourth hand-copied guard). Turning this arm into a full
            # re-verification would delete the no-op this block exists to
            # provide — pinned by approve-idempotency.sh and cited by this
            # function's own IDEMPOTENCY comment above — for a cost none of
            # the other five families is evidenced to justify here.
            # DESIGN-CONFLICT is the one family the operator ruling on
            # i8cx rounds 6-8 already made
            # UNCONDITIONAL and UNWAIVABLE (see DESIGN-CONFLICT-REFUSAL below:
            # "no flag, marker, label, or free-text phrase clears it") — an
            # explicit, reviewed decision that this axis tolerates no
            # exemption anywhere in this function, which the idempotency arm
            # was an unaudited exemption from. Whether REVIEW-SEPARATION or
            # DESIGN-SATISFIED have the same reach-around shape is a real,
            # open question, deliberately NOT decided here: bundling an
            # unaudited guess about a second axis into this leaf fix is the
            # same locally-reasonable-step drift the i8cx operator ruling
            # already named once (four such steps produced the waiver
            # mechanism removed wholesale in item 10 of this file's own
            # design-review-record.test.sh header). One evidenced
            # reach-around, one fix; see this task's own report for the
            # enumeration of the others.
            #
            # SAME PREDICATE, A THIRD CALL SITE — not a reimplementation.
            # compute_design_conflict_open is already called from two places
            # (cmd_approve's own DESIGN-CONFLICT-REFUSAL below, and
            # cmd_design_gate_precheck), each owning its own refusal text and
            # exit code because the remediation and caller differ — the same
            # division this file already draws between review-check.sh `gate`
            # (one predicate) and its several callers. This is a third call
            # site of the same kind. error_key and exit code are IDENTICAL to
            # the block below on purpose: a caller or test keyed on
            # design_conflict_open must not care which of the two call sites
            # inside cmd_approve caught it.
            #
            # NO GLOBAL-STATE HAZARD (the class cmd_design_gate_precheck had
            # to guard against explicitly, R9-F1): compute_design_conflict_open
            # calls compute_design_satisfied internally and overwrites its
            # globals, but every path out of THIS check is function-terminal
            # (return 0 just below, or exit 2 in the two refusals) — there is
            # no later code in cmd_approve that runs after this check and
            # still expects the pre-call globals, unlike design-gate-precheck,
            # which had to capture into locals because it keeps running past
            # its own conflict check.
            #
            # WHY NOT HOIST THE MAIN BLOCK UP HERE INSTEAD (the tempting
            # alternative, and design-gate-precheck's own R9-F1 fix chose
            # exactly that shape for a simpler two-arm branch): this
            # function's refusals are ordered by what each can prove and how
            # expensive its remediation is, cheapest/most-fundamental first
            # (see the EXPECTED-HASH-REFUSAL comment above) — DESIGN-CONFLICT-
            # REFUSAL is placed LAST in that ladder deliberately. Moving it to
            # run before tracker-reconcile/impact-report/review/completion
            # would reorder it for the ORDINARY (non-idempotent) approval path
            # too, contradicting that documented rationale, for a diff far
            # larger than this leaf fix needs. A second, narrowly-scoped call
            # site costs one extra read on the no-op path and touches nothing
            # else.
            local idem_design_conflict_rc=0
            compute_design_conflict_open "$tid" || idem_design_conflict_rc=$?
            if [ "$idem_design_conflict_rc" -ne 0 ]; then
                emit_error_json "approve" "$tid" "design_conflict_source_unreadable" \
                    "approve refused: qa-approved is already set and change_set_hash=$idem_ref matches a prior approval record, which would ordinarily make this call an idempotent no-op — but the DESIGN-CONFLICT history for $tid could not be read right now (bd unreachable, the comment stream not retrievable, or a record read back malformed), so whether a conflict has been filed SINCE that approval is unknown. Refusing to treat unreadable as no-conflict rather than assuming the earlier approval still covers it. This cannot be bypassed by --no-design, which covers only the satisfied-verdict requirement, never an unreadable conflict source. Re-run once bd is reachable" \
                    "qa-gate.sh approve <task-id> <summary>"
                exit 2
            fi
            if [ "$DESIGN_CONFLICT_OPEN" = "true" ]; then
                emit_error_json "approve" "$tid" "design_conflict_open" \
                    "approve refused: qa-approved is already set and change_set_hash=$idem_ref matches a prior approval record, which would ordinarily make this call an idempotent no-op — but $DESIGN_CONFLICT_OPEN_OBS Affected unit(s): $DESIGN_CONFLICT_OPEN_UNITS. The files staying unchanged proves the REVIEWED CONTENT is the same; it does not prove the DESIGN is still undisputed — a design conflict is filed against a unit, never against a change-set hash, so it can post-date an approval that no file-level check will ever see move. The single legal clearing path is a superseding, independently-reviewed, SATISFIED DESIGN-REVIEW whose entry for the affected unit(s) changed — amend docs/specs/$tid.md and record a fresh verdict: qa-gate.sh design-review-record $tid --design-hash <h> --file <verdict.json>. This cannot be waived by --no-design or any other flag" \
                    "qa-gate.sh design-review-record <task-id> --design-hash <sha256> --file <path>"
                exit 2
            fi
# IDEMPOTENT-APPROVE-CONFLICT-RECHECK END (A2 / claude-workflow-plugin-i8cx)
            # claude-workflow-plugin-k6re R6-F2: this arm's success emission
            # now runs through emit_approve_success (APPROVE-SUCCESS-GATE,
            # above cmd_approve), which refuses when --expect-hash was given
            # and does not match $idem_ref — the hash this no-op is about to
            # report as bound. See that function's own header for why this
            # is a shared gate rather than a fourth hand-copied guard.
            local idem_expect_hash_obs=""
            if [ -n "$expect_hash_arg" ]; then
                idem_expect_hash_obs="; expected-hash verified (the caller classified change_set_hash=$expect_hash_arg and that is what this idempotent no-op binds; NOT a completeness claim — see fkm.1.20)"
            fi
            emit_approve_success "$tid" "$idem_ref" "$expect_hash_arg" \
                "qa-approved already set and an approval record already binds this change set (change_set_hash=$idem_ref via $IDEM_REF_SOURCE); idempotent no-op — nothing rewritten.${idem_expect_hash_obs} If a Stop is still blocking, the change set has moved since that record: re-run impact-report.sh (step 2 of the block's remediation) and approve again"
            return 0
        fi
        # Fall through, loudly. The label is stale relative to the change set
        # this approve would bind, so a fresh record is exactly what is needed.
        log_sync_error "approve: qa-approved was already set on $tid but no approval record binds the current change set (reference hash=${idem_ref:-<unavailable>} via ${IDEM_REF_SOURCE:-<unavailable>}) — re-verifying preconditions and writing a fresh bound record instead of no-op'ing (gz3)"
        # The literal string "idempotent no-op" is deliberately NOT used here:
        # it is the discriminator for the no-op envelope above (tests and
        # operators grep for it), so reusing it in the OPPOSITE outcome's text
        # would make every such grep a silent false positive.
        stale_label_obs="; NOTE qa-approved was already set but no approval record bound this change set (reference hash=${idem_ref:-<unavailable>} via ${IDEM_REF_SOURCE:-<unavailable>}) — preconditions re-verified and a FRESH record written (stale-label re-bind, gz3)"
    fi

    # TRACKER-RECONCILE BEGIN (94d)
    # RECONCILE BEFORE THE IMPACT-REPORT REFUSAL, and refuse when it cannot be
    # done. Ordering is the whole point: the refusal below compares the report's
    # recorded change_set_hash against the CURRENT one, and this is what makes
    # "current" mean the git-visible change set rather than the subset a
    # Write/Edit hook recorded. Reconciling AFTER would bind an approval to a
    # hash computed over an under-covering list — the defect itself.
    #
    # This is a REFUSAL, not a warning, and unlike the impact-report refusal it
    # has NO bypass flag. An unreconcilable tracker means we cannot say what the
    # change set IS; every downstream credential this approve writes (the bound
    # approval record, the reviewed hash, the rubric binding) would be a claim
    # about an unknown quantity. --no-impact-report waives an ANALYSIS whose
    # degradation is documented; there is no comparable degraded mode for "we do
    # not know which files changed".
    #
    # Declared before the sentinel-wrapped block below so the META-TEST's
    # stripped copy stays coherent.
    if ! reconcile_tracker; then
        emit_error_json "approve" "$tid" "tracker_unreconcilable" \
            "approve refused: the change-set tracker could not be reconciled against git, so the change set this approval would bind is unprovable. $RECONCILE_OBS. Fix the underlying git error and re-run approve; there is deliberately no bypass flag — an approval bound to an unknown change set is worse than no approval (94d)." \
            "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] [--no-review '<reason>'] <summary>"
        exit 2
    fi
    local reconcile_obs="; $RECONCILE_OBS"
    # TRACKER-RECONCILE END (94d)

    # CHANGE-SET-RECONSTRUCTED BEGIN (94d.1)
    # THE MATERIALLY-SHORT REFUSAL — fkm.1.2 half (b), generalised because its
    # original form is now unreachable.
    #
    # fkm.1.2 (b) asked approve to refuse "when the change set is EMPTY while git
    # shows un-baselined dirt". That guard cannot fire any more, and P1 is why:
    # the tracker reconcile folds un-baselined dirt INTO the tracker before
    # anything reads it, so "empty tracker + un-baselined dirt" is not a state
    # approve can observe. (Spelled in prose rather than with the function's own
    # identifier deliberately: this comment sits OUTSIDE the TRACKER-RECONCILE
    # sentinels, and 7M asserts that stripping those regions leaves zero mentions
    # of that name — a prose mention here fails that leg, which is exactly how it
    # was caught.) The failure it was written for did not go away — it changed
    # shape.
    # On 94d's own review the same trigger (SessionStart deleting the tracker at a
    # compaction) produced a NON-EMPTY, plausible, 10-of-26-path set and a
    # confident `+10 git-visible path(s)`. There is no zero left to trip on, so
    # the predicate has to be "materially short" rather than "empty".
    #
    # WHAT "MATERIALLY SHORT" MEANS HERE, and why it is not a ratio. THREE facts
    # from the reconcile that just ran, none of them inferred from the tracker's
    # own contents:
    #   (1) RECONCILE_REBUILT_FROM_EMPTY — changed-files.txt was absent-or-empty
    #       when the reconcile ran, so every path in the set being bound came from
    #       `git status`, not from a recorded edit. The tracker is APPEND-ONLY
    #       during a cycle (post-edit appends, reconcile appends, nothing removes;
    #       only approve and the Stop's release paths truncate), so empty during
    #       an open cycle means either "nothing was ever recorded" or "it was
    #       destroyed".
    #   (2) RECONCILE_ADDED > 0 — the rebuild produced a NON-EMPTY change set, so
    #       this approve is about to certify actual work.
    #   (3) RECONCILE_SUBTRACTED > 0 — and it ALSO dropped N git-visible,
    #       reviewable paths as already-baselined. So the set being certified is a
    #       PROVEN SUBSET of the working tree's reviewable dirt.
    # Together they are the state where binding an approval is strictly worse than
    # not binding one: it converts an under-covered review into a signed
    # attestation of completeness. The live 94d.1 occurrence sits exactly here
    # (added=10, subtracted=16).
    #
    # WHY CLAUSE (2) IS THERE, MEASURED rather than assumed. Without it the
    # refusal also fires on `added=0, subtracted>0` — an EMPTY change set with
    # baselined dirt around it — and that is a common, legitimate state, not a
    # loss: a task closed with no code change, a doc-only fast path, or simply a
    # session that did nothing while the repo happened to be dirty on arrival.
    # It is the state of the L1 `qa-gate-choose` and `qa-gate-grade-record`
    # fixtures, whose approve calls this refusal broke before clause (2) was
    # added (their one "subtracted" entry is the fixture's own untracked
    # `.claude/scripts/` directory). The gate already treats an empty change set
    # as "nothing to review" everywhere else; refusing it here would be a wide
    # false positive for a narrow gain.
    #
    # WHAT CLAUSE (2) THEREFORE DOES NOT COVER, named rather than left latent: a
    # session whose work was ENTIRELY Bash-written to paths that were ALL already
    # dirty at baseline capture reads as `added=0` and is not refused, even though
    # its change set is hollow. That is fkm.1.2's ORIGINAL empty-binding concern,
    # and this predicate cannot separate it from the legitimate empty cases above
    # — the observations are identical. It is REPORTED either way (`subtracted=N`
    # plus the paths, and the rebuild announcement), which is the honest limit of
    # what this evidence supports: escalating to a refusal there would block every
    # no-op approve in a dirty checkout.
    #
    # WHY NOT A COMPARISON OF TWO COUNTS. Because both counts a truncated tracker
    # can offer are derived from the truncated tracker. That is precisely how the
    # impact-report freshness check missed this: `recorded_hash == current_hash`
    # holds when BOTH describe the shrunken set, so it detects DRIFT and is blind
    # to LOSS. Neither input above is read from the tracker's contents — (1) is the
    # emptiness of the file at a known instant, (2) is a count taken from `git
    # status` and the baseline.
    #
    # PLACED BEFORE THE IMPACT-REPORT REFUSAL, for the reason that block's own
    # header gives about the reconcile: what the change set IS has to be settled
    # before anything reasons about it. A report validated against a set nobody
    # established is a fresh answer to the wrong question.
    #
    # INERT WHEN THE TRACKER-RECONCILE REGION IS STRIPPED (`:-0` defaults), so the
    # 7M META's stripped copy keeps testing what it is aimed at rather than dying
    # on an unset variable.
    if [ "$bypass_reconstructed" != "1" ] \
        && [ "${RECONCILE_REBUILT_FROM_EMPTY:-0}" = "1" ] \
        && [ "${RECONCILE_ADDED:-0}" -gt 0 ] \
        && [ "${RECONCILE_SUBTRACTED:-0}" -gt 0 ]; then
        emit_error_json "approve" "$tid" "change_set_reconstructed" \
            "approve refused: the change set this approval would bind was RECONSTRUCTED, and is provably short. changed-files.txt was absent-or-empty when the reconcile ran, so all ${RECONCILE_ADDED:-0} path(s) in it came from 'git status' rather than from a recorded edit — and that rebuild dropped ${RECONCILE_SUBTRACTED:-0} further git-visible path(s) as already-baselined. Dropped (first ${RECONCILE_SUBTRACTED_INLINE_CAP:-12} shown; FULL list in $QA_TRACKING_DIR/reconcile-subtracted.txt): $(printf '%s' "${RECONCILE_SUBTRACTED_PATHS:-}" | head -n "${RECONCILE_SUBTRACTED_INLINE_CAP:-12}" | tr '\n' ' '). A rebuild can only ever be a SUBSET — a file whose content was reverted, and the gate's own artifacts, are invisible to git — so binding an approval here would certify less than shipped (94d.1). Decide which it is: if those paths ARE this session's work, the tracker was destroyed and the review has to cover them; if they are genuinely pre-existing dirt, say so and proceed: bash .claude/scripts/qa-gate.sh approve $tid --accept-reconstructed '<reason>' '<summary>'" \
            "qa-gate.sh approve <task-id> [--accept-reconstructed '<reason>'] [--no-impact-report '<reason>'] [--no-review '<reason>'] <summary>"
        exit 2
    fi
    local reconstructed_obs=""
    if [ "$bypass_reconstructed" = "1" ]; then
        reconstructed_obs="; reconstructed-change-set bypass: $reconstructed_bypass_reason (change_set_reconstructed refusal waived via --accept-reconstructed; rebuilt_from_empty=${RECONCILE_REBUILT_FROM_EMPTY:-0} added=${RECONCILE_ADDED:-0} subtracted=${RECONCILE_SUBTRACTED:-0}; reason recorded per 94d.1)"
    fi
    # CHANGE-SET-RECONSTRUCTED END (94d.1)

    # G2.n6d: impact-report audit note. Declared OUTSIDE the sentinel
    # block below so (a) the bypass audit trail survives even if the
    # refusal block is stripped, and (b) the stripped copy stays
    # syntactically coherent for the META-TEST.
    local impact_obs=""
    if [ "$bypass_impact" = "1" ]; then
        impact_obs="; impact-bypass: $bypass_reason (impact-report refusal bypassed via --no-impact-report; reason recorded per G2.n6d)"
    fi

    # IMPACT-REPORT-REFUSAL BEGIN (G2.n6d / claude-workflow-plugin-llh.2)
    #
    # Mechanical gate: approve refuses unless a FRESH impact report
    # exists for this task. "Fresh" = the report's change_set_hash equals
    # the sha256 of the CURRENT canonical changed-files list (computed by
    # the same script that generated the report, so the canonicalisation
    # cannot drift). A stale report is no report: it analysed a change
    # set that no longer matches what would ship.
    #
    # Deliberately NOT checked: the report's `server` field. A
    # server:"absent" report is the documented degradation (code-graph
    # not installed/bootable) and is a valid artifact — the refusal
    # exists to stop SKIPPED analysis, not degraded environments.
    #
    # The sentinel comments wrapping this block are load-bearing: the L2
    # META-TEST strips everything between them and asserts approve then
    # succeeds without the artifact (proving the refusal is what enforces
    # the contract). Do not rename them.
    if [ "$bypass_impact" != "1" ]; then
        local impact_report current_hash recorded_hash
        impact_obs=""
        impact_report=$(impact_report_path_for "$tid")
        if [ ! -f "$impact_report" ]; then
            emit_error_json "approve" "$tid" "impact_report_missing" \
                "approve refused: mechanical impact report missing at $impact_report. The QA workflow requires the impact_of analysis artifact (G2.n6d). Regenerate: bash .claude/scripts/impact-report.sh $tid — or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] <summary>"
            exit 2
        fi
        recorded_hash=$(jq -r '.change_set_hash // empty' "$impact_report" 2>/dev/null || echo "")
        if [ -z "$recorded_hash" ]; then
            emit_error_json "approve" "$tid" "impact_report_invalid" \
                "approve refused: impact report at $impact_report is unparseable or missing change_set_hash. Regenerate: bash .claude/scripts/impact-report.sh $tid — or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] <summary>"
            exit 2
        fi
        # ERREXIT-HASH-GUARD (claude-workflow-plugin-qzv.3). `|| current_hash=""`
        # is not defensive noise: without it this refusal is DEAD CODE.
        #
        # compute_change_set_hash returns 1 on exactly one condition —
        # IMPACT_REPORT_SCRIPT missing — and this file runs under `set -e`, so a
        # BARE assignment from it aborts the whole script three lines above the
        # refusal that exists for that condition. Measured against the shipped
        # script before the fix (component fixture, real bd, impact-report.sh
        # removed after `enter` had written the artifact):
        #
        #   ARM A  shipped, `set -e`   -> rc=1, stdout EMPTY, stderr EMPTY
        #   ARM B  same call, `set +e` -> rc=2, error_key=impact_report_unverifiable
        #
        # and `bash -x` on ARM A ends at `+ current_hash=`. The two-arm control
        # is what makes that a fact about this line rather than a reading of
        # errexit semantics. rc=1 is `return 1` propagating through errexit.
        #
        # WHY IT MATTERED MORE THAN A MUTE REFUSAL: verify-before-stop.sh's F1
        # fast path called this and discarded both streams, so an empty-output
        # exit 1 was indistinguishable from any other failure — it logged one
        # sync-error line, wiped the tracker and RELEASED the Stop with zero
        # approval records. The pair is one failure path and landed as one change
        # set; see the F1-APPROVE-REFUSAL region in verify-before-stop.sh.
        #
        # The same slip was in the second call site below (`approved_hash`), on
        # the --no-impact-report bypass path, and is fixed there with the same
        # note. Those were the only two unguarded assignments in this file: the
        # three others (IDEM_REF_HASH, cmd_enter's current_hash, live_hash) were
        # already written `|| var=""`, which is what makes this a slip rather
        # than a design choice.
        #
        # The negative control does NOT strip a sentinel region — deleting the
        # assignment would leave `current_hash` unset and the refusal firing
        # spuriously, which is not the pre-fix behaviour. It removes the
        # ` || current_hash=""` SUFFIX, restoring the pre-fix text exactly, and
        # asserts approve then exits 1 with empty stdout and empty stderr.
        # Anchored on that text; do not reflow this line.
        current_hash=$(compute_change_set_hash) || current_hash=""
        if [ -z "$current_hash" ]; then
            emit_error_json "approve" "$tid" "impact_report_unverifiable" \
                "approve refused: cannot recompute the current change-set hash ($IMPACT_REPORT_SCRIPT missing or failing), so the report's freshness is unverifiable. Restore the script, or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] <summary>"
            exit 2
        fi
        if [ "$recorded_hash" != "$current_hash" ]; then
            emit_error_json "approve" "$tid" "impact_report_stale" \
                "approve refused: impact report is STALE — its change_set_hash ($recorded_hash) no longer matches the current changed-files list ($current_hash); files changed after the report was generated, so the impact analysis does not cover what would ship. Regenerate: bash .claude/scripts/impact-report.sh $tid — or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-impact-report '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-impact-report '<reason>'] <summary>"
            exit 2
        fi
        impact_obs="; impact-report verified (change_set_hash match: $current_hash)"
    fi
    # IMPACT-REPORT-REFUSAL END (G2.n6d / claude-workflow-plugin-llh.2)

    # llh.18 (red-team P0/P1): capture the canonical change-set hash that
    # this approval covers. Declared OUTSIDE the sentinel block above so:
    #   (a) the bypass path (which skips the refusal) still binds the
    #       approval to a change-set, and
    #   (b) the META-TEST's stripped copy (sentinels removed) still writes a
    #       change-set-bound record — keeping the stripped copy coherent.
    # The non-bypass path already computed current_hash inside the refusal
    # block; we recompute here unconditionally so the value exists on every
    # path. compute_change_set_hash prints empty on failure; an empty hash
    # degrades to the legacy unbound comment (logged) rather than aborting
    # the approval (labels remain the lifecycle source of truth).
    #
    # ERREXIT-HASH-GUARD (claude-workflow-plugin-qzv.3). The `|| approved_hash=""`
    # is what makes the sentence directly above TRUE; without it the paragraph
    # described behaviour this line did not have. This is the SECOND unguarded
    # assignment the qzv.3 round found, and the one reachable through the
    # documented `--no-impact-report` bypass — the refusal block above is skipped
    # there, so this is the first compute_change_set_hash on that path and, under
    # `set -e`, a missing impact-report.sh aborted the script here. Measured
    # against the shipped script: `approve <tid> --no-impact-report '<reason>'
    # --no-review '<reason>' --no-completion '<reason>' '<summary>'` with the
    # script absent gave rc=1, EMPTY stdout, EMPTY stderr, 0 approval records and
    # no label written, and `bash -x` ended at `+ approved_hash=`. So the audited
    # bypass — the exit an operator is TOLD to take when the mechanical artifact
    # is unavailable — was itself unusable in the one situation that produces it.
    #
    # Negative control, as for the first site: remove the ` || approved_hash=""`
    # SUFFIX and assert the bypassed approve exits 1 with empty output. Anchored
    # on that text; do not reflow this line.
    local approved_hash
    approved_hash=$(compute_change_set_hash) || approved_hash=""
    if [ -z "$approved_hash" ]; then
        log_sync_error "approve: could not compute change_set_hash for $tid (impact-report.sh missing/failing); writing approval comment WITHOUT a change-set binding — verify-before-stop will not be able to match it (re-run approve once impact-report.sh is restored)"
    fi

    # EXPECTED-HASH-REFUSAL BEGIN (claude-workflow-plugin-qzv)
    #
    # DID THE CALLER'S VERDICT COVER THE CHANGE SET THIS APPROVAL WILL BIND?
    #
    # THE DEFECT THIS CLOSES. `verify-before-stop.sh`'s F1 fast path classifies a
    # change set as doc-only / beads-state / empty, and THEN calls approve. Those
    # are two reads at two instants, in a process that runs `enter` (which
    # reconciles the tracker and regenerates the impact report) in between. A path
    # that arrives in that window is inside what approve binds and outside what F1
    # judged — so a "no reviewable source changed" verdict could be recorded over
    # a set containing reviewable source. On the v4.1.0 release task the recorded
    # approval bound `9942b2bd` while the work that actually shipped hashed to
    # `914ceeff`. `--expect-hash` makes the caller state the set it judged and
    # refuses when that is not the set being bound.
    #
    # WHERE IT SITS, AND WHY — cmd_approve now carries SEVEN post-argparse
    # refusal families (this comment previously said "four" and had drifted
    # to under-count even that — rqer added completion-contract without
    # updating the enumeration below; v5 D2 / claude-workflow-plugin-fkm.4
    # both fixes that gap and adds design-satisfied, per AC 4.12), and the
    # order is a claim about what each one can PROVE:
    #   1. tracker_unreconcilable / 2. change_set_reconstructed — what the change
    #      set IS. Nothing can be reasoned about a set nobody has established, so
    #      these come first (their own headers say so).
    #   3. THIS ONE. It compares the caller's expectation against `approved_hash`,
    #      the value this function will actually bind — which does not exist until
    #      the line above. Placing it earlier would compare against a different
    #      quantity than the one bound, which is exactly the "guard probes a
    #      weaker fact than the property it protects" shape that produced this
    #      release's R6-F1. It also has to precede every WRITE below, since a
    #      refusal must leave the task untouched.
    #   4. REVIEW-SEPARATION — the most expensive to remediate (a human/agent
    #      review round-trip) and, on the F1 path, bypassed outright. Same
    #      cheapest-first argument that block's own header makes about the
    #      impact-report refusal: a pure string compare over two values already in
    #      hand should not queue behind a review round, and a caller whose
    #      classification is stale has nothing to review yet anyway.
    #   5. COMPLETION-CONTRACT-REFUSAL — a claim about the WHOLE task rather
    #      than about one artifact; its own header states why it goes after
    #      REVIEW-SEPARATION rather than before it.
    #   6. DESIGN-SATISFIED-REFUSAL (v5 D2) — placed last among the refusals
    #      for the identical reason completion-contract is: cheap to
    #      remediate, but a whole-task claim, so firing it while a more basic
    #      precondition is missing would send the operator to fix the wrong
    #      thing first. Its own header explains why it is a NEW block rather
    #      than a converted DESIGN-BINDING-TOKEN arm.
    #
    # ONE BOUNDARY, PREVIOUSLY LEFT OPEN AS A NAMED RESIDUAL, NOW CLOSED
    # (claude-workflow-plugin-k6re R6-F2). This paragraph used to argue that
    # the hash-aware idempotency no-op higher up in this function returns
    # BEFORE this refusal ever runs, and that this was safe because "nothing
    # new is bound" on that path. Independent review found that reasoning
    # wrong: a caller passing --expect-hash to an already-approved task
    # whose bound record covers a DIFFERENT set than it expected got an
    # unqualified success envelope, never the refusal --expect-hash exists
    # to provide — "nothing new is bound" is a fact about the FILES, not
    # about whether the CALLER's stated expectation was honoured. See
    # emit_approve_success (APPROVE-SUCCESS-GATE, defined just above
    # cmd_approve) for the fix: every one of this function's
    # success-reporting exits, including the idempotent no-op, now calls
    # the SAME check this block performs before it is allowed to report
    # success. F1 still cannot reach it (its `case` arm excludes the
    # `approved` status), so this remains a manual-caller-only concern —
    # but it is no longer an unchecked one.
    #
    # WHAT THIS DOES NOT ESTABLISH. It proves the bound set is the CLASSIFIED set.
    # It does NOT prove that set is COMPLETE — both sides come from the same
    # canonicalisation over the same tracker, so this detects drift and is
    # structurally blind to loss (claude-workflow-plugin-fkm.1.20). An independent
    # witness for completeness is a separate piece of work; nothing here supplies
    # one.
    #
    # BOTH HASHES ARE NAMED in the refusal, because "they differ" is unactionable:
    # which one is stale, and whether the delta is one doc or a source file, is the
    # whole decision the operator has to make.
    #
    # The sentinel comments are load-bearing: an L2 META-TEST strips this region
    # and asserts a mismatched --expect-hash then approves. Do not rename them.
    if [ -n "$expect_hash_arg" ] && [ "$expect_hash_arg" != "$approved_hash" ]; then
        emit_error_json "approve" "$tid" "expected_hash_mismatch" \
            "approve refused: the caller expected to approve change set $expect_hash_arg but this approval would bind $approved_hash. The two reads straddle something that moved the change set — most often a path that arrived after the caller classified it (the F1 doc-only fast path passes the hash of the set it classified, so a source file landing mid-Stop lands here rather than being approved under a doc-only verdict). NOTE: this proves the bound set is the CLASSIFIED set; it does NOT prove that set is complete (claude-workflow-plugin-fkm.1.20). Re-derive the current set and decide: bash .claude/scripts/impact-report.sh --hash-only — then either re-review at the new hash and approve without --expect-hash, or pass the hash you actually reviewed." \
            "qa-gate.sh approve <task-id> [--expect-hash <hash>] [--accept-reconstructed '<reason>'] [--no-impact-report '<reason>'] [--no-review '<reason>'] <summary>"
        exit 2
    fi
    local expect_hash_obs=""
    if [ -n "$expect_hash_arg" ]; then
        expect_hash_obs="; expected-hash verified (the caller classified change_set_hash=$expect_hash_arg and that is what this approval binds; NOT a completeness claim — see fkm.1.20)"
    fi
    # EXPECTED-HASH-REFUSAL END (claude-workflow-plugin-qzv)

    # R2-F2: does the satisfied verdict this approval is about to cite actually
    # cover the change set being approved?
    #
    # Nothing used to ask. The rubric audit line below was emitted from the
    # LABEL alone, so this sequence produced an approval claiming a verdict it
    # did not have, with no adversary and no forged anything: grade set A ->
    # enter (preserves, correctly) -> add path B -> regenerate the impact report
    # -> approve. approved_hash is A+B, the verdict graded A, and the envelope
    # said "rubric-satisfied preserved (audit trail)".
    #
    # WARN, DO NOT REFUSE — a deliberate call, and the one place in this change
    # where the safer-looking option is the wrong one:
    #   - qa.md 6f states the rule explicitly: "adding script-side denial of
    #     approve-without-satisfied would create a parallel gate and violate
    #     principle 6". The rubric is a QA INPUT; qa-approved + a bound record
    #     is the only release credential, and verify-before-stop reads neither
    #     rubric label nor RUBRIC comment. A refusal here would be a second,
    #     divergent gate on a signal the Stop side does not consult.
    #   - The remediation a refusal would print is either "re-run the relay" (a
    #     paid grader spawn, and impossible at the iteration cap) or "clear the
    #     label first" — which is the undocumented-label-removal dead end gz3
    #     spent a whole task eliminating. A refusal whose only exit is a bypass
    #     teaches the bypass.
    #   - The legitimate flow it would fire on is real: QA reviewing a change
    #     set that grew after grading and approving with a documented override
    #     is exactly what 6f describes.
    # So the fix is to stop the AUDIT TRAIL lying, which is the actual harm:
    # the claim below is now hash-checked, and a mismatch is recorded in the
    # durable approval comment as well as the envelope. If the project later
    # decides the rubric should hard-gate, this is the line to change — and
    # principle 6 and qa.md 6f have to change with it.
    local rubric_graded_hash=""
    rubric_graded_hash=$(latest_satisfied_rubric_hash "$tid") || rubric_graded_hash=""
    local rubric_mismatch=0
    if [ "$had_rubric_satisfied" = "1" ] && [ -n "$rubric_graded_hash" ] \
       && [ -n "$approved_hash" ] && [ "$rubric_graded_hash" != "$approved_hash" ]; then
        rubric_mismatch=1
        log_sync_error "approve: rubric-satisfied is set on $tid but the satisfied verdict binds change_set_hash=$rubric_graded_hash while this approval binds $approved_hash — the approval comment must carry an override reason (qa.md 6f); recorded as a [rubric mismatch: ...] token in the approval record"
    fi

    # V3 (claude-workflow-plugin-jio.1): the review-separation audit fields.
    # Declared OUTSIDE the sentinel block below for the same two reasons
    # impact_obs is: (a) the --no-review bypass path skips the block but must
    # still record WHO (nobody) reviewed and WHY it was waived, and (b) the
    # META-TEST's stripped copy stays syntactically coherent and still writes a
    # well-formed `reviewed_by=` token.
    local reviewed_by="none"
    local review_obs=""
    local review_artifact_hash=""
    if [ "$bypass_review" = "1" ]; then
        review_obs="; review-bypass: $review_bypass_reason (independent-review refusal bypassed via --no-review; reason recorded per V3)"
    fi

    # REVIEW-SEPARATION BEGIN (v4 V3 / claude-workflow-plugin-jio.1)
    #
    # Mechanical gate: NOBODY SIGNS OFF ON THEIR OWN WORK. approve refuses
    # unless the task carries a review record whose reviewer_identity differs
    # from EVERY recorded implementer, and no finding at/above the artifact's
    # risk_threshold is still unresolved and un-arbitrated.
    #
    # The predicate is NOT reimplemented here. review-check.sh `gate` is the
    # ONE place that parses the record grammars and counts — exactly like
    # compute_change_set_hash defers to impact-report.sh --hash-only. A second
    # counter would be a second thing to drift.
    #
    # FAIL CLOSED, deliberately: a MISSING or unrunnable helper refuses
    # (exit 4) rather than waving the approval through. An enforcement whose
    # absence is silently equivalent to a pass is not an enforcement — and
    # `rm .claude/scripts/review-check.sh` would otherwise be a one-line
    # bypass of the whole contract.
    #
    # Ordering: this runs AFTER the impact-report refusal on purpose. That one
    # is cheaper and its remediation is mechanical (re-run one script); this
    # one costs a human/agent review round-trip, so it should not fire while a
    # more basic artifact is still missing.
    #
    # The sentinel comments wrapping this block are load-bearing: an L2
    # META-TEST strips everything between them and asserts approve then
    # succeeds with NO review artifact at all. Do not rename them.
    if [ "$bypass_review" != "1" ]; then
        if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
            emit_error_json "approve" "$tid" "review_check_unavailable" \
                "approve refused: the review predicate is unavailable — $REVIEW_CHECK_SCRIPT is missing, so independent review cannot be verified. This FAILS CLOSED by design (a deleted checker must not read as a passing check). Restore the script, or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --no-review '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-review '<reason>'] <summary>"
            exit 4
        fi
        local review_out review_rc=0 review_key review_open
        # claude-workflow-plugin-k6re R17-F2 / class sweep: this was the
        # ONLY one of this file's four `review-check.sh gate` call sites
        # merging stderr into the captured variable (`2>&1`) rather than
        # discarding it (`2>/dev/null`, matching the other three). Narrowed
        # for two independent reasons, verified rather than assumed: (1)
        # nothing downstream of `$review_out` in this case-arm ever reads
        # its raw text for display — every consumer (below) extracts a named
        # JSON field via jq, and the one arm that does NOT recognize a
        # specific error_key (the trailing `*)`) reports `$review_rc`, never
        # `$review_out` itself — so the `2>&1` bought no observable benefit;
        # (2) it was the one plausible way an unrelated stderr line (e.g.
        # from a `mktemp` failure inside review-check.sh's own `cmd_gate`,
        # itself unguarded — see review-check.sh:2078, out of scope for a
        # qa-gate.sh-only sweep) could prepend non-JSON text ahead of the
        # real envelope and break every jq parse below at once, including
        # the R17-F1-class ones a few lines down. Removing the corruption
        # vector at its source is strictly better than guarding every
        # consumer against a shape review-check.sh's own three OTHER call
        # sites in this file never have to worry about.
        review_out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" gate "$tid" 2>/dev/null) || review_rc=$?
        case "$review_rc" in
            0)
                # REVIEW-CAP-TERMINATED-REFUSAL BEGIN (v5 D2 / claude-workflow-plugin-fkm.4)
                #
                # nq5f/fkm.4 B4: "cap_terminated becomes a predicate." The
                # primitive has existed since nq5f (review-check.sh:1228-1231,
                # exposed on this exact envelope) with ZERO consumers in this
                # file before this line (`grep -c cap_terminated
                # .claude/scripts/qa-gate.sh` was 0 at fkm.4 start). A review
                # that stopped at a CAP (max_findings / max_review_iterations /
                # timeout) ran out of turns or budget, not out of things to
                # find — it is incomplete by construction, the same principle
                # `.claude/rubrics/design.md`'s DS8 states for the
                # design-review loop, applied here to its sibling: the code
                # review that gates THIS approval.
                #
                # Checked BEFORE the observation strings below are composed:
                # rc=0 from review-check.sh gate means "no open findings,
                # reviewer independent", which is necessary but, for a capped
                # review, not sufficient — `verdict` and `stop_condition` are
                # the only two ways a review concludes on its own terms, and
                # every `cap:*` value is the other case.
                #
                # `has("cap_terminated")` rather than `// false`, deliberately
                # (the pairing plan's own caution): `//` treats a literal JSON
                # `false` as "absent" and falls through to its right-hand
                # side, which would silently misreport every ordinary non-cap
                # review if that fallback were ever anything but "false"
                # itself — review-count.test.sh already carries the regression
                # leg for exactly this shape. Absence (an envelope from a
                # review-check.sh predating this field) reads as "false" — not
                # cap-terminated — on purpose: this must not newly block an
                # approve whose review-check.sh copy is merely older, only one
                # that is actually capped.
                #
                # Same audited bypass as the rest of REVIEW-SEPARATION
                # (--no-review): this whole case arm runs only when
                # bypass_review != 1, so no second bypass flag is needed.
                local review_cap_terminated review_stopped_by
                review_cap_terminated=$(printf '%s' "$review_out" | jq -r '.artifact | if has("cap_terminated") then (.cap_terminated | tostring) else "false" end' 2>/dev/null || echo "false")
                if [ "$review_cap_terminated" = "true" ]; then
                    review_stopped_by=$(printf '%s' "$review_out" | jq -r '.artifact.stopped_by // "?"' 2>/dev/null || echo "?")
                    emit_error_json "approve" "$tid" "review_cap_terminated" \
                        "approve refused: the latest independent review for $tid stopped at a CAP (stopped_by=$review_stopped_by) rather than at a verdict or a stated stop_condition. A capped review ran out of iterations, findings budget or time — not out of things to find — and is incomplete by construction; it cannot certify the change set on its own merits (the same principle .claude/rubrics/design.md's DS8 states for the design-review loop). Record a fresh review that concludes on its own terms, or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --no-review '<reason>' '<summary>'" \
                        "qa-gate.sh approve <task-id> [--no-review '<reason>'] <summary>"
                    exit 4
                fi
                # REVIEW-CAP-TERMINATED-REFUSAL END (v5 D2 / claude-workflow-plugin-fkm.4)

                reviewed_by=$(printf '%s' "$review_out" | jq -r '.reviewer_identity // "unknown"' 2>/dev/null || echo "unknown")
                [ -z "$reviewed_by" ] && reviewed_by="unknown"
                review_artifact_hash=$(printf '%s' "$review_out" | jq -r '.artifact.reviewed_hash // ""' 2>/dev/null || echo "")
                review_obs="; independent review verified (reviewed_by=$reviewed_by; no open findings at/above the artifact's risk_threshold)"
                # D6: the artifact may legitimately predate the current
                # change-set — resolving a finding CHANGES the files, hence the
                # hash. That is a normal, healthy review loop, so staleness is
                # AUDITED, never blocking. (A stale-artifact refusal here would
                # make every resolve-then-approve cycle unclosable.)
                if [ -n "$review_artifact_hash" ] && [ -n "$approved_hash" ] \
                    && [ "$review_artifact_hash" != "$approved_hash" ]; then
                    review_obs="$review_obs; WARNING the review artifact recorded reviewed_hash=$review_artifact_hash but this approval binds change_set_hash=$approved_hash — the reviewed change-set is not byte-identical to the approved one (expected after a resolve-finding round; re-review if the delta is substantive)"
                fi
                ;;
            2)
                # bd unreachable — the same class require_bd refuses on.
                emit_error_json "approve" "$tid" "review_check_bd_unavailable" \
                    "approve refused: review-check.sh could not read $tid's records (bd unavailable). Independent review is unverifiable, so the gate fails closed. Restore bd, or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-review '<reason>' '<summary>'" \
                    "qa-gate.sh approve <task-id> [--no-review '<reason>'] <summary>"
                exit 2
                ;;
            4)
                review_key=$(printf '%s' "$review_out" | jq -r '.error_key // "review_check_violation"' 2>/dev/null || echo "review_check_violation")
                [ -z "$review_key" ] && review_key="review_check_violation"
                review_open=$(printf '%s' "$review_out" | jq -r '(.open_finding_ids // []) | join(", ")' 2>/dev/null || echo "")
                local review_remedy=""
                case "$review_key" in
                    review_artifact_missing)
                        review_remedy="No REVIEW-ARTIFACT v1 record exists for $tid. An independent reviewer must review this change set and record the artifact — QA's section 6-prime authors it (reviewer_identity=qa-claude) and records it with: bash .claude/scripts/qa-gate.sh review-record $tid --file <artifact.json>"
                        ;;
                    reviewer_not_independent)
                        review_remedy="The recorded reviewer is also a recorded IMPLEMENTER of this task, i.e. the change would be signed off by whoever wrote it. Have a DIFFERENT identity review the change set and record a fresh artifact (a QA-authored qa-claude artifact is independent of backend/frontend/devops implementers)."
                        ;;
                    unresolved_findings)
                        review_remedy="Open finding(s) at/above the artifact's risk_threshold: ${review_open:-<none reported>}. Each must be closed with evidence — bash .claude/scripts/qa-gate.sh resolve-finding $tid <finding-id> --fix '<ref>' --test '<ref>' '<summary>' — or explicitly overruled: bash .claude/scripts/qa-gate.sh arbitrate $tid <finding-id> overrule '<rationale>'"
                        ;;
                    review_artifact_malformed|review_artifact_iteration_unparseable|review_artifact_timestamp_unparseable)
                        # claude-workflow-plugin-k6re: relay review-check.sh's
                        # OWN observations verbatim rather than a second,
                        # independently-worded remedy that can drift from it
                        # -- which is exactly what happened to the ORIGINAL
                        # text here ("re-record a valid artifact": posting a
                        # NEW record does nothing for an EXISTING malformed
                        # one still blocking the selector). R12-F1 replaced
                        # that with a relay naming an explicit
                        # quarantine-artifact recovery command; R2-F1 found
                        # that recovery command's own record forgeable (no
                        # verifiable author, a bare-prefix match) and removed
                        # it entirely rather than re-guarding it -- so
                        # review-check.sh's own observations now says there
                        # is NO recovery path at all, and this relay carries
                        # that message unchanged. Still a single source of
                        # truth, never duplicated here: nothing in this
                        # case-arm should independently name a remedy that
                        # could tempt a future maintainer into re-adding one.
                        # Falls back to the generic line only if
                        # review-check.sh's own envelope somehow carried no
                        # observations at all.
                        #
                        # claude-workflow-plugin-k6re R17-F2 / class sweep:
                        # `|| true` added defensively. Reachability analysis
                        # (not merely asserted — see the census after `set -e`
                        # near the top of this file): reaching THIS case arm
                        # at all requires `review_key` (a few lines above,
                        # itself guarded by its own `|| echo
                        # "review_check_violation"`) to have ALREADY
                        # extracted one of this arm's literal match strings
                        # from `$review_out` via the identical `.foo`-on-an-
                        # object jq operation this line performs on a
                        # DIFFERENT field of the SAME already-parsed value —
                        # which is only possible if `$review_out` is a
                        # complete, valid JSON object (jq 1.8.1, empirically
                        # confirmed: a top-level parse failure or a non-
                        # object top level makes `.error_key` fail exactly
                        # like `.observations` would, and `//` does NOT
                        # swallow that class of error, only a `null`/`false`
                        # value). So this specific jq call should not be able
                        # to fail once reached. Guarded anyway, for the same
                        # reason the R16-F1 comment's "this was the ONLY
                        # unguarded one" claim is being retracted a few
                        # hundred lines below rather than trusted a second
                        # time: a proof that a call site is safe TODAY is not
                        # a substitute for making it survive being wrong.
                        review_remedy=$(printf '%s' "$review_out" | jq -r '.observations // empty' 2>/dev/null) || true
                        [ -z "$review_remedy" ] && review_remedy="review-check.sh gate $tid reported: $review_key. Re-run it directly for the full envelope."
                        ;;
                    review_artifact_selection_disagreement)
                        # claude-workflow-plugin-k6re R13-F1: this used to
                        # fall into the generic `*)` arm below, which named
                        # ONLY --no-review -- a blanket waiver of the whole
                        # independent-review predicate -- for a state that
                        # usually needs neither waiving nor re-reviewing, only
                        # a record correctly timestamped. review-check.sh's
                        # own observations (relayed first, same discipline as
                        # the malformed case above) names the conflicting
                        # records by iteration and timestamp; the remedy
                        # appended here names the two REAL fixes review-record
                        # alone cannot express: going forward, historic rounds
                        # belong through review-reconcile (never a K3
                        # candidate, so it cannot recreate this disagreement);
                        # to repair a task that already carries it, re-run
                        # review-record on the SAME artifact that has the
                        # HIGHEST iteration number among those named above
                        # (even though it is already recorded) so its
                        # timestamp becomes the newest, making it win both
                        # axes at once.
                        #
                        # claude-workflow-plugin-k6re R17-F2 / class sweep:
                        # `|| true`, same reasoning as this case's sibling
                        # arm immediately above (review_artifact_malformed
                        # et al.) — reaching this arm already proves
                        # `$review_out` parsed as a valid JSON object, via
                        # the identical `review_key` extraction a few lines
                        # up. Guarded anyway, not trusted on that proof alone.
                        review_remedy=$(printf '%s' "$review_out" | jq -r '.observations // empty' 2>/dev/null) || true
                        [ -z "$review_remedy" ] && review_remedy="review-check.sh gate $tid reported: $review_key."
                        review_remedy="$review_remedy TWO REAL FIXES, not a review-separation waiver: (1) to repair THIS task now, identify which of the conflicting records named above has the HIGHEST iteration number, then re-run review-record on that SAME artifact again (it is already recorded; re-recording refreshes its timestamp to the newest, which is what makes it win both the iteration and the timestamp axis at once) -- bash .claude/scripts/qa-gate.sh review-record $tid --file <path-to-that-artifact>. (2) going forward, every OTHER historic round should be accounted for via review-reconcile, never review-record -- bash .claude/scripts/qa-gate.sh review-reconcile $tid --file <path> '<reason>' -- a REVIEW-ARTIFACT-RECONCILED v1 record is never a K3 selection candidate, so it cannot recreate this disagreement no matter what order it is written in."
                        ;;
                    *)
                        review_remedy="review-check.sh gate $tid reported: $review_key. Re-run it directly for the full envelope."
                        ;;
                esac
                emit_error_json "approve" "$tid" "$review_key" \
                    "approve refused (review separation): $review_remedy — or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --no-review '<reason>' '<summary>'" \
                    "qa-gate.sh approve <task-id> [--no-review '<reason>'] <summary>"
                exit 4
                ;;
            *)
                # Usage error (1) or anything unexpected: still fail closed —
                # an unreadable verdict is not a passing verdict.
                emit_error_json "approve" "$tid" "review_check_unavailable" \
                    "approve refused: review-check.sh gate $tid exited $review_rc without a usable verdict, so independent review is unverifiable (fail-closed). Run it directly to see why, or bypass: bash .claude/scripts/qa-gate.sh approve $tid --no-review '<reason>' '<summary>'" \
                    "qa-gate.sh approve <task-id> [--no-review '<reason>'] <summary>"
                exit 4
                ;;
        esac
    fi
    # REVIEW-SEPARATION END (v4 V3 / claude-workflow-plugin-jio.1)

    # UNRECORDED-REVIEW-ARTIFACT-REFUSAL BEGIN (claude-workflow-plugin-k6re)
    #
    # THE HEADLINE DEFECT THIS TASK FIXES. The external reviewer driver
    # writes docs/reviews/<tid>-r<n>.json and exits; nothing calls `qa-gate.sh
    # review-record` for it unless an agent remembers to (orchestrator.md 5c
    # Step D / qa.md 6-prime are PROSE instructions, not a mechanical driver —
    # LESSONS.md entry 8: "when a workflow REQUIRES a tool call, make it
    # mechanical... don't prompt for it"). MEASURED on this task's own
    # tracking: claude-workflow-plugin-i8cx accumulated 12 artifacts on disk
    # against 3 recorded rounds; pqnd, 9 against 5. REVIEW-SEPARATION above
    # already proved there EXISTS a valid, independent, complete review for
    # the CURRENT governing record — this block asks a DIFFERENT question: is
    # there ALSO a review artifact on disk for this task that never entered
    # the trust chain at all. "independent review verified" in the
    # observations above is not a lie when that is true, but it is not the
    # whole truth either: an operator reading it has no way to see that a
    # nine-round-stale, or simply unrecorded, artifact sits beside it — the
    # gate reporting confidence its evidence does not fully support.
    #
    # OPTION 2 OF THE TASK'S OWN TWO CANDIDATES, CHOSEN OVER OPTION 1
    # (deliberately not also shipped — see the completion report). The
    # description offered: (1) the external reviewer driver calls
    # review-record itself; (2) approve refuses when an unrecorded artifact
    # exists. Option 1 closes only that DRIVER's own pathway — a review
    # authored inside an agent turn (qa.md 6-prime) has no deterministic
    # driver to wire at all, so a fix confined to the driver would look
    # complete while leaving half the surface on prose (this task's own
    # "REQUIREMENT 1 CHARACTERISED" comment). Option 2 catches every review
    # pathway — the external driver, an agent's own in-session review, and
    # a hand-typed review-record — because it checks the RESULT (bytes on
    # disk, records in bd) rather than the PATH that produced it.
    #
    # CONTENT HASH, NEVER MTIME. The description's own framing was an
    # artifact "NEWER than the newest record" — mtime is the wrong
    # instrument: a `git checkout`, a file copy, or a filesystem restore
    # (`make sync-fixtures`, a backup) all move mtime without changing a
    # single byte, and a bd comment's `at <ts>` field and a file's mtime are
    # not even the same clock. This block instead asks, PER FILE, "does ANY
    # well-formed REVIEW-ARTIFACT v1 record for this task bind this exact
    # sha256" — answered by review-check.sh's `recorded-hashes` (the UNION of
    # every recorded round, never `gate`'s single K3 winner — see that
    # subcommand's own header for why the distinction matters here: the very
    # corpus this fix targets, i8cx, is nine SUPERSEDED-but-real rounds that a
    # single-winner selector would never surface).
    #
    # WHY A DEDICATED BYPASS, NOT --no-review. --no-review waives the WHOLE
    # independent-review predicate; this refusal is about a narrower,
    # orthogonal fact (a stray artifact exists) that can be true even when the
    # CURRENT governing review is perfectly valid, independent and clean.
    # Folding the two together would force an operator who wants to
    # acknowledge only the backlog to also silently waive findings-resolution
    # they never intended to skip. See --accept-unrecorded-review's own
    # comment (option parsing, above) for the historic-backlog case it exists
    # for: a task with a large historic review-artifact backlog (i8cx and
    # pqnd are the two concrete examples that motivated this refusal, i8cx
    # nine SUPERSEDED-but-real rounds as noted above) needs an escape that is
    # not "run review-record on nine-round-stale history nobody asked to
    # relitigate" the next time it comes back through approve — per the task
    # brief's own warning that a refusal with no bypass converts an old
    # silence into a new dead end. NEITHER TASK'S CURRENT STATUS is
    # load-bearing for that point, so this comment does not claim one
    # (claude-workflow-plugin-k6re R14-F3: an earlier draft asserted both
    # were CLOSED, which was already false for i8cx at the time it was
    # written — checked directly with `bd show claude-workflow-plugin-i8cx
    # --json`, reporting status=in_progress, rather than re-asserted from an
    # unchecked earlier claim).
    #
    # DOES NOT NEST inside "if bypass_review" — it is independent of whether
    # --no-review waived the review-separation predicate above: a stray
    # unrecorded artifact is a fact about the filesystem and the comment
    # stream, orthogonal to whether THIS approval is relying on review
    # evidence at all. It has its own, separate bypass instead (declared with
    # the other bypass locals, above).
    local unrecorded_review_obs=""
    if [ "$bypass_unrecorded_review" = "1" ]; then
        unrecorded_review_obs="; unrecorded-artifact bypass: $unrecorded_review_bypass_reason (review_artifact_unrecorded refusal waived via --accept-unrecorded-review; reason recorded per claude-workflow-plugin-k6re)"
    fi
    if [ "$bypass_unrecorded_review" != "1" ]; then
        if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
            emit_error_json "approve" "$tid" "review_check_unavailable" \
                "approve refused: the unrecorded-review-artifact predicate is unavailable — $REVIEW_CHECK_SCRIPT is missing, so whether every on-disk review artifact for $tid is recorded cannot be verified. This FAILS CLOSED by design (a deleted checker must not read as a passing check). Restore the script, or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --accept-unrecorded-review '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--accept-unrecorded-review '<reason>'] <summary>"
            exit 4
        fi
        local unrecorded_sanitized_tid
        unrecorded_sanitized_tid=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
        # claude-workflow-plugin-k6re R16-F2: AN UNLISTABLE DIRECTORY IS
        # INDISTINGUISHABLE FROM AN EMPTY ONE TO A GLOB, and this whole
        # block's job is to detect exactly the shape "an artifact exists
        # but nobody can see it" -- so an unreadable docs/reviews/ used to
        # make one invisible to the glob below, landing in the SAME
        # affirmative "nothing to reconcile" PASS a genuinely clean task
        # prints (MEASURED: docs/reviews at 0000 or 0111, same records,
        # same files, only the permission bit differing -> approve rc=0,
        # qa-approved SET, while the unrecorded artifact was still present
        # and still unrecorded the whole time). This block's own two
        # SIBLING unavailability modes a few lines up both fail CLOSED by
        # explicit design (review_check_unavailable: "a deleted checker
        # must not read as a passing check"; review_recorded_hashes_
        # unavailable: "this FAILS CLOSED") -- the directory being
        # enumerated was the one mode that read as a pass, newly introduced
        # by this change set, not pre-existing.
        #
        # THE CENSUS (claude-workflow-plugin-k6re, R16), because R13, R14,
        # R15 and R16 each found the unavailability mode the round before
        # had not enumerated, and a fifth patch discovered by a sixth
        # reviewer is not an acceptable way to keep finding them. Every mode
        # this block (directory enumeration) and the gate-consult a few
        # lines below can be in, and its disposition:
        #   - directory ABSENT           -> PASS, "nothing to reconcile".
        #     Legitimate: a task that never had a review yet has nothing
        #     under docs/reviews/ at all, and that is not an error.
        #   - directory present, r+x (the ordinary case) -> glob runs
        #     normally, enumerates real files.
        #   - directory present, NOT readable and/or NOT traversable
        #     (0000, 0111, any missing r or x bit) -> FAIL CLOSED here,
        #     review_dir_unreadable, exit 4. THE FIX THIS FINDING IS ABOUT.
        #   - directory path is a DANGLING SYMLINK (points nowhere) ->
        #     FAIL CLOSED here too, same error_key. `-d`/`-e` alone cannot
        #     distinguish this from "absent" (both read false), which would
        #     silently re-open the same class this fix closes if the real
        #     directory were ever swapped for a broken link; checked
        #     explicitly rather than left to the same blind spot.
        #   - directory path is a PLAIN FILE, not a directory -> `-d` is
        #     false, so this guard does not fire, and the glob below cannot
        #     expand into it either; behaves like "absent". Verified SAFE
        #     rather than merely unhandled: nothing can ever have written a
        #     review artifact "inside" a non-directory, so "nothing to
        #     reconcile" is not just the code's answer here, it is the true
        #     answer.
        #   - directory is a symlink to a REAL, readable directory ->
        #     transparent; behaves exactly like an ordinary directory.
        #   - review-check.sh (the script FILE) absent -> already caught
        #     above, review_check_unavailable, FAILS CLOSED (pre-existing).
        #   - review-check.sh present but UNREADABLE -> not given a
        #     dedicated error_key; `bash "$REVIEW_CHECK_SCRIPT" gate` fails
        #     to produce parseable JSON, so every jq extraction below falls
        #     to its `// ""`/`// false` default and the gate-consult's own
        #     catch-all `else` branch (a few lines down) fires -- still
        #     FAILS CLOSED, just not under its own specific message. Named
        #     here rather than left unenumerated; not worth a fourth
        #     error_key for a mode indistinguishable in practice from "gate
        #     produced garbage" below.
        #   - review-check.sh present, runs, EXITS NON-ZERO for any reason
        #     (a crash, a refusal, a malformed candidate) -> the gate-
        #     consult's `else` branch, FAILS CLOSED (this round's R16-F1
        #     fix is what keeps this branch reachable at all).
        #   - review-check.sh TIMES OUT -> NOT GUARDED. This host has no
        #     `timeout` binary, and none of the other three `review-check.sh
        #     gate` call sites in this file guard against a hang either.
        #     Named explicitly as OUT OF SCOPE for this round rather than
        #     left unenumerated, not silently absent.
        #   - review-check.sh returns MALFORMED JSON -> every jq extraction
        #     falls to its default, same as "unreadable" above; FAILS
        #     CLOSED via the catch-all `else` branch.
        #   - review-check.sh returns valid JSON, ok:true, but with NO
        #     numeric .artifact.iteration -> structurally impossible per
        #     gate's own construction (its one `emit_gate 0` call site is
        #     reached only after a numeric iteration is already
        #     established), not merely untested.
        #   - review-check.sh returns valid JSON, ok:false, with an
        #     error_key OTHER than review_artifact_missing -> the gate-
        #     consult's `else` branch, FAILS CLOSED (covers selection
        #     disagreement, a malformed record, an unreadable comment set,
        #     and an empty/absent error_key alike).
        local unrecorded_review_dir="$PROJECT_DIR/$REVIEW_ARTIFACT_SUBDIR"
        if [ -L "$unrecorded_review_dir" ] && [ ! -e "$unrecorded_review_dir" ]; then
            emit_error_json "approve" "$tid" "review_dir_unreadable" \
                "approve refused: $unrecorded_review_dir is a dangling symlink (it resolves to nothing), so whether any review artifact exists under it cannot be verified -- an unlistable path is indistinguishable from an empty one to a glob, and this FAILS CLOSED rather than reading that ambiguity as a pass. Repair or remove the symlink, or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --accept-unrecorded-review '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--accept-unrecorded-review '<reason>'] <summary>"
            exit 4
        fi
        if [ -d "$unrecorded_review_dir" ] && { [ ! -r "$unrecorded_review_dir" ] || [ ! -x "$unrecorded_review_dir" ]; }; then
            emit_error_json "approve" "$tid" "review_dir_unreadable" \
                "approve refused: $unrecorded_review_dir exists but is not readable and/or not traversable (checked separately: a directory needs BOTH bits to be listable), so whether any review artifact for $tid sits inside it cannot be verified -- an unlistable directory is indistinguishable from an empty one to a glob, and this FAILS CLOSED rather than reading that ambiguity as a pass. Restore the directory's permissions, or bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --accept-unrecorded-review '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--accept-unrecorded-review '<reason>'] <summary>"
            exit 4
        fi
        # Glob mirrors review_artifact_path_for's own format string
        # byte-for-byte (sanitized task id, literal "-r", wildcard iteration,
        # ".json"), so it matches exactly what the external reviewer driver
        # and cmd_review_record derive — never a looser pattern that could catch
        # the docs/reviews/impact-report-approve_XXXXXX_*.json litter files a
        # DIFFERENT generator (impact-report.sh, invoked from approve itself)
        # leaves in the same directory: those never carry this exact task
        # id immediately followed by "-r", so this anchored glob cannot match
        # them regardless of how many sit alongside real artifacts.
        local -a unrecorded_disk_artifacts=()
        local unrecorded_f
        for unrecorded_f in "$unrecorded_review_dir/$unrecorded_sanitized_tid"-r*.json; do
            [ -e "$unrecorded_f" ] || continue
            unrecorded_disk_artifacts+=("$unrecorded_f")
        done
        if [ "${#unrecorded_disk_artifacts[@]}" -eq 0 ]; then
            unrecorded_review_obs="; no on-disk review artifact for $tid under $REVIEW_ARTIFACT_SUBDIR/ (nothing to reconcile)"
        else
            local unrecorded_hashes_out unrecorded_hashes_rc=0
            unrecorded_hashes_out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" recorded-hashes "$tid" 2>/dev/null) || unrecorded_hashes_rc=$?
            if [ "$unrecorded_hashes_rc" -ne 0 ] || [ "$(printf '%s' "$unrecorded_hashes_out" | jq -r '.ok // false' 2>/dev/null)" != "true" ]; then
                emit_error_json "approve" "$tid" "review_recorded_hashes_unavailable" \
                    "approve refused: could not enumerate recorded review-artifact hashes for $tid (review-check.sh recorded-hashes exited $unrecorded_hashes_rc), so whether every on-disk review artifact is accounted for is unverifiable. This FAILS CLOSED. Re-run it directly to see why, or bypass: bash .claude/scripts/qa-gate.sh approve $tid --accept-unrecorded-review '<reason>' '<summary>'" \
                    "qa-gate.sh approve <task-id> [--accept-unrecorded-review '<reason>'] <summary>"
                exit 4
            fi
            # claude-workflow-plugin-k6re R13-F1: track the HIGHEST iteration
            # among the genuinely-unrecorded files (hashable, hash confirmed
            # absent from the recorded set) — used ONLY as a fallback signal
            # (see R15-F1 below) for the one case where nothing better
            # exists: no governing record anywhere yet. It is NOT used to
            # decide whether something ELSE already governs — that question
            # is answered by consulting review-check.sh gate directly, below,
            # never by comparing on-disk files against each other.
            local -a unrecorded_missing=()
            local unrecorded_file_hash unrecorded_hash_rc
            local unrecorded_max_iter="" unrecorded_max_iter_file=""
            for unrecorded_f in "${unrecorded_disk_artifacts[@]}"; do
                unrecorded_hash_rc=0
                if ! review_path_is_contained "$unrecorded_f"; then
                    unrecorded_missing+=("$unrecorded_f (outside $REVIEW_ARTIFACT_SUBDIR/ -- a symlink out of the declared directory; cannot corroborate)")
                    continue
                fi
                # R13-F6: [ -e ] above admits a directory or other non-regular
                # object; naming the true cause here rather than letting it
                # fall through to a generic "unhashable" from the hash tool.
                if [ ! -f "$unrecorded_f" ]; then
                    unrecorded_missing+=("$unrecorded_f (not a regular file -- a directory or other non-file object at this path; cannot corroborate)")
                    continue
                fi
                unrecorded_file_hash=$(bash "$PROJECT_DIR/.claude/scripts/workflow-manifest.sh" hash-file "$unrecorded_f" 2>/dev/null) || unrecorded_hash_rc=$?
                if [ "$unrecorded_hash_rc" -ne 0 ] || ! is_sha256_hex "$unrecorded_file_hash"; then
                    unrecorded_missing+=("$unrecorded_f (unhashable, rc=$unrecorded_hash_rc -- cannot corroborate)")
                    continue
                fi
                if ! printf '%s' "$unrecorded_hashes_out" | jq -e --arg h "$unrecorded_file_hash" '.hashes | index($h) != null' >/dev/null 2>&1; then
                    local unrecorded_this_iter
                    unrecorded_this_iter=$(basename "$unrecorded_f" | sed -E "s/^${unrecorded_sanitized_tid}-r([0-9]+)\.json\$/\1/")
                    # claude-workflow-plugin-k6re R16-F3: the filename-
                    # derived iteration above is a fast proxy, not the
                    # source of truth -- review_artifact_path_for (the
                    # derivation review-record AND review-reconcile both
                    # actually enforce) computes a file's CANONICAL path
                    # from the artifact's OWN .iterations content field, not
                    # from whatever this file happens to be named. When the
                    # two disagree (a hand-placed or hand-renamed file), the
                    # filename-derived iteration this loop would otherwise
                    # promote to "the round to record" names a --file
                    # argument review-record/review-reconcile will BOTH
                    # refuse (artifact_path_not_derived), since neither
                    # writer ever trusts a filename over its own content --
                    # so recommending either command here would be
                    # unfollowable advice. Reading .iterations directly
                    # (never trusting the filename for this specific
                    # decision) and refusing to let a mismatched file become
                    # unrecorded_max_iter_file closes that: a mismatched
                    # file is still correctly reported as unrecorded (the
                    # sha256= entry below still fires), it is just never
                    # RECOMMENDED for review-record, since no path this loop
                    # could name for it would ever be accepted.
                    local unrecorded_content_iter
                    # claude-workflow-plugin-k6re R17-F1: `|| true`. This was
                    # a bare command substitution under `set -e` (line 196):
                    # `$unrecorded_f` is a file this loop does NOT control
                    # the contents of (it can be anything left on disk under
                    # docs/reviews/ by an external reviewer driver, or by
                    # hand), and a TRUNCATED or otherwise malformed-but-
                    # hashable file makes `jq` exit non-zero on the parse
                    # itself — `.iterations // ""` is a jq FILTER-LANGUAGE
                    # default, which only ever fires once jq has successfully
                    # parsed its input; it is invisible to a parse failure,
                    # exactly as `emit_gate`'s own `// default` operators are
                    # (see review-check.sh's `printf '{"x":%s}\n' "$(false)"`
                    # comment, the same mechanism from the argument-embedded
                    # side). REPRODUCED end to end through the shipped
                    # `approve`, A/B, with only one on-disk file's JSON
                    # validity differing: well-formed -> exit 4, a real
                    # envelope, error_key=review_artifact_unrecorded (the
                    # correct, documented refusal — the file IS genuinely
                    # unrecorded); malformed-but-hashable -> exit 5 (jq's own
                    # parse-error code), ZERO bytes on stdout, no error_key,
                    # no envelope at all — a silent process abort in place of
                    # that same documented refusal. `|| true` accepts an
                    # empty `unrecorded_content_iter` on failure, which the
                    # `if` below already treats safely: an empty value is not
                    # digit-only, so the mismatch branch is skipped and this
                    # file is reported as an ordinary unrecorded artifact
                    # (the `else` arm, a few lines down) — the same outcome a
                    # well-formed file with no `.iterations` field at all
                    # already produces today, which is the correct behaviour
                    # for "could not determine a content-derived iteration",
                    # regardless of WHY it could not be determined.
                    unrecorded_content_iter=$(cat -- "$unrecorded_f" 2>/dev/null | jq -r '.iterations // ""' 2>/dev/null) || true
                    if printf '%s' "$unrecorded_content_iter" | grep -qE '^[0-9]+$' \
                        && [ "$unrecorded_content_iter" != "$unrecorded_this_iter" ]; then
                        unrecorded_missing+=("$unrecorded_f (sha256=$unrecorded_file_hash; filename says iteration=$unrecorded_this_iter but its own content says iterations=$unrecorded_content_iter -- neither review-record nor review-reconcile will accept this path for either number; remove it, rename it to match its content, or bypass with --accept-unrecorded-review)")
                    else
                        unrecorded_missing+=("$unrecorded_f (sha256=$unrecorded_file_hash)")
                        if printf '%s' "$unrecorded_this_iter" | grep -qE '^[0-9]+$'; then
                            if [ -z "$unrecorded_max_iter" ] || [ "$unrecorded_this_iter" -gt "$unrecorded_max_iter" ] 2>/dev/null; then
                                unrecorded_max_iter="$unrecorded_this_iter"
                                unrecorded_max_iter_file="$unrecorded_f"
                            fi
                        fi
                    fi
                fi
                # A file already accounted for (hash present in recorded-
                # hashes) needs no further handling here: whether it is the
                # GOVERNING round is answered below, from the record stream
                # via review-check.sh gate, never from this loop.
            done
            if [ "${#unrecorded_missing[@]}" -gt 0 ]; then
                # claude-workflow-plugin-k6re R13-F1: two commands, named
                # explicitly for which files, NOT one command against an
                # unordered list. See review-reconcile's own header for the
                # full mechanism (the K3 selector in gate requires the
                # highest-iteration record to also be the latest by
                # write-time timestamp; review-record stamps write time, so
                # backfilling several historic rounds through it in
                # uncontrolled order can invert that agreement and produce
                # review_artifact_selection_disagreement on a LATER approve
                # attempt — reproduced independently on both a backlog whose
                # highest iteration is itself unrecorded, where numeric
                # ordering happens to avoid it, and one whose highest
                # iteration is already recorded, where no ordering of the
                # remainder can).
                # claude-workflow-plugin-k6re R15-F1/F2 (THIRD ROUND against
                # this one comparison: R13-F1, R14-F1, now R15-F1, all
                # patched the SAME assumption and were each wrong the same
                # way -- the two-bounce signal that the ASSUMPTION, not the
                # comparison, was the defect). THE CLAIM THIS REPLACES, held
                # as fact here for two rounds: "this in-loop derivation --
                # over the exact same on-disk files this refusal already
                # reports on -- is the more robust source [than gate], not a
                # second computation of something gate already knows." It
                # was not more robust. It answered "what is the highest
                # iteration among ON-DISK FILES whose hash is recorded" -- a
                # question about the filesystem -- when the question that
                # matters is "what is the highest iteration among RECORDS",
                # a question about the bd comment stream. Those differ
                # exactly when a governing record's FILE is missing or
                # unreadable (deleted, chmod 000, or simply untracked in git
                # -- confirmed true of THIS repo's own r13/r14 artifacts via
                # `git ls-files --others --exclude-standard`, so any fresh
                # clone or `git clean -fdx` reproduces the shape) -- the
                # governing round is then invisible to a loop over
                # unrecorded_disk_artifacts no matter how the comparison
                # inside it is written, because that loop only ever sees the
                # filesystem. R15-F2 is the same root cause on the other
                # branch: recorded-hashes is deliberately the UNION over
                # every record INCLUDING non-governing REVIEW-ARTIFACT-
                # RECONCILED v1 ones (see recorded-hashes' own header), so a
                # disk-side "is this hash recorded" check could mistake a
                # RECONCILED iteration for a governing one.
                #
                # THE FIX IS NOT A FOURTH PATCH TO THIS COMPARISON'S DISK-
                # DERIVED INPUT: it is retiring the DISK as a source for it.
                # The comparison itself (is anything unrecorded NEWER than
                # what currently governs?) still has to exist -- an
                # unrecorded file can legitimately be a fresher round that
                # should be PROMOTED to governing, the ordinary i8cx-shaped
                # case -- but its "what currently governs" side now comes
                # from review-check.sh gate's K3 selector, the ONE place in
                # this codebase that already answers that question
                # authoritatively over the RECORD stream, the same doctrine
                # this repo applies to the DESIGN-UNIT grammar
                # (latest_design_unit_binding: "the ONE authoritative
                # reader... nothing should carry its own copy"). Consult it;
                # never re-derive a second opinion of THAT ONE FACT from the
                # filesystem. If gate itself cannot establish a governing
                # record for any reason other than "none exist yet", this
                # refusal does NOT guess a file -- losing the guess is
                # strictly better than a FOURTH wrong one, since reconciling
                # every listed file is always safe (reconcile never creates a
                # new REVIEW-ARTIFACT v1 record, so it can never invert what
                # gate selects) while recording the wrong one is not.
                # R15-GATE-CONSULT BEGIN (claude-workflow-plugin-k6re)
                # claude-workflow-plugin-k6re R16-F1: `|| true`, matching the
                # OTHER three `review-check.sh gate` call sites in this file
                # (4705's own `|| review_rc=$?`; two more further down, both
                # `|| true`).
                #
                # THE CLAIM THIS REPLACES, held as fact here for one review
                # round: "this was the ONLY unguarded one." That claim was
                # already false the moment it was written: the R16-F3 remedy
                # in this SAME change set added a second bare command
                # substitution of the identical shape ~110 lines below this
                # one (`unrecorded_content_iter=$(cat ... | jq ...)`, no
                # guard) — found and fixed as R17-F1, a full review round
                # later, by an independent reviewer who had ALSO read this
                # exact comment earlier in the same session and, by their own
                # account, took its "ONLY" on trust instead of re-deriving
                # it against the change set that contained it. The lesson is
                # not "sweep harder" — R16-F1's own sweep was thorough for
                # what it checked, four call sites of ONE specific function
                # call (`review-check.sh gate`) — it is that a comment
                # asserting a CLASS is closed ("the only one") is a claim
                # about the whole file, not about the four sites actually
                # inspected, and it goes stale the instant a sibling
                # unguarded substitution is added anywhere else in the same
                # script, guarded or not by this comment's own vigilance.
                # R17 replaced the per-call-site sweep with a file-wide
                # census (see the BARE-SUBSTITUTION-CENSUS block just after
                # `set -e` near the top of this file) precisely so the next
                # version of this sentence has something broader than "I
                # checked these four" to stand on — and even that census
                # states its own scope rather than claiming permanence: it is
                # accurate as of the change set it was written against, not a
                # standing guarantee about every substitution added after it.
                #
                # THE REST OF THIS COMMENT'S REASONING STANDS UNCHANGED: `gate`
                # EXITS 4 ON EVERY REFUSAL, and this whole file runs under
                # `set -e` (line 196), so a bare command substitution here
                # aborts cmd_approve outright the moment gate has anything to
                # say other than a clean ok:true -- which is to say, on every
                # path except the one where a governing record already
                # exists and everything else is fine. That is EXACTLY the two
                # branches (elif review_artifact_missing; else, "will NOT
                # guess") this whole mechanism exists to reach: review-
                # check.sh has exactly one `emit_gate 0`, reached only once a
                # numeric iteration is already established, so a NON-zero
                # gate exit is the ONLY way either of those two branches
                # could ever run -- and a non-zero exit is precisely what a
                # bare substitution here would turn into an immediate, silent
                # process abort (zero bytes on stdout AND stderr, no
                # error_key, nothing for verify-before-stop.sh's own
                # review_artifact_unrecorded documentation, added THIS round,
                # to ever actually see on the shape it documents). Same
                # mechanism ERREXIT-HASH-GUARD (claude-workflow-plugin-qzv.3,
                # a few hundred lines above in this same function) already
                # named exactly once: "this is not defensive noise: without
                # it this refusal is DEAD CODE."
                local unrecorded_gate_out unrecorded_gate_iter unrecorded_gate_ok unrecorded_gate_ekey
                unrecorded_gate_out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" gate "$tid" 2>/dev/null || true)
                unrecorded_gate_ok=$(printf '%s' "$unrecorded_gate_out" | jq -r '.ok // false' 2>/dev/null || echo "false")
                unrecorded_gate_ekey=$(printf '%s' "$unrecorded_gate_out" | jq -r '.error_key // ""' 2>/dev/null || echo "")
                unrecorded_gate_iter=$(printf '%s' "$unrecorded_gate_out" | jq -r '.artifact.iteration // ""' 2>/dev/null || echo "")
                local unrecorded_current_advice
                if printf '%s' "$unrecorded_gate_iter" | grep -qE '^[0-9]+$'; then
                    # gate ESTABLISHED a governing record: emit_gate always
                    # populates .artifact.iteration from the SAME K3-selected
                    # record every LATER check (unresolved_findings,
                    # reviewer_not_independent, ...) still runs against, so
                    # this is non-empty whenever a governing record exists at
                    # all -- regardless of whether gate's overall ok is true
                    # or false, and regardless of whether that round's FILE
                    # is present, missing, or unreadable on disk.
                    #
                    # THE COMPARISON ITSELF SURVIVES (only its SOURCE changed
                    # from a disk-walk to this gate consultation): a governing
                    # record existing does not by itself mean every listed
                    # file is historic -- an unrecorded file can be a NEWER
                    # round than the one gate currently selects (the ordinary
                    # i8cx-shaped case: review round 1 governs, a fresher
                    # round 4 sits unrecorded and should be PROMOTED, not
                    # reconciled). Only when NOTHING unrecorded outranks the
                    # governing iteration is "reconcile everything, record
                    # nothing" the correct advice; collapsing this to "a
                    # governing record exists, therefore reconcile
                    # everything" would silently break that ordinary case.
                    # claude-workflow-plugin-k6re R16-F4: `-ge`, not `-gt`.
                    # An unrecorded file whose FILENAME-derived iteration
                    # EQUALS the governing one is not "newer" -- it is the
                    # same round, whose bytes have drifted from what is
                    # recorded (the reachable trigger: record iteration N
                    # through the real writer, then overwrite that SAME file
                    # afterward without re-recording, so its hash no longer
                    # matches recorded-hashes and it reads as "unrecorded"
                    # despite sharing a round number with something that
                    # already governs). Recommending review-record on it
                    # would post a SECOND REVIEW-ARTIFACT v1 record at the
                    # SAME iteration, deciding between the two only by
                    # write-time -- exactly the ambiguity this whole
                    # mechanism exists to avoid. `-ge` folds the equal case
                    # into "already recorded, reconcile" (never record),
                    # which is always safe regardless of which of the two
                    # same-numbered artifacts is the "right" one.
                    if [ -z "$unrecorded_max_iter" ] || [ "$unrecorded_gate_iter" -ge "$unrecorded_max_iter" ] 2>/dev/null; then
                        unrecorded_current_advice="the round that should GOVERN this approval (iteration=$unrecorded_gate_iter) is ALREADY recorded -- per \`review-check.sh gate $tid\`, the ONE authoritative selector for this question. Do NOT run review-record on ANY of the files listed above, or you will invert cmd_gate's iteration-vs-timestamp agreement and wedge a selector that currently works (MEASURED: review-check.sh gate reports iteration=$unrecorded_gate_iter as today's governing round; gate's own ok=$unrecorded_gate_ok). Reconcile EVERY listed file instead, none of them governing: bash .claude/scripts/qa-gate.sh review-reconcile $tid --file <path> '<reason>' for each"
                    else
                        unrecorded_current_advice="review-check.sh gate reports iteration=$unrecorded_gate_iter as the CURRENT governing round, but the highest-iteration listed file, $unrecorded_max_iter_file (iteration=$unrecorded_max_iter), is a NEWER round than that and is ordinarily the one that should GOVERN this approval instead -- record THAT one with: bash .claude/scripts/qa-gate.sh review-record $tid --file $unrecorded_max_iter_file -- every OTHER listed file is historic and must be reconciled WITHOUT letting it govern: bash .claude/scripts/qa-gate.sh review-reconcile $tid --file <path> '<reason>'"
                    fi
                elif [ "$unrecorded_gate_ekey" = "review_artifact_missing" ]; then
                    # gate found ZERO REVIEW-ARTIFACT v1 records at all: there
                    # is genuinely nothing to consult yet, so (and ONLY so)
                    # picking a file from the currently-unrecorded set on
                    # disk is the best available signal -- the ordinary
                    # first-review case this branch has always covered.
                    if [ -n "$unrecorded_max_iter_file" ]; then
                        unrecorded_current_advice="review-check.sh gate reports no governing record exists yet (review_artifact_missing), so the highest-iteration listed file, $unrecorded_max_iter_file (iteration=$unrecorded_max_iter), is ordinarily the round that should GOVERN this approval -- record THAT one with: bash .claude/scripts/qa-gate.sh review-record $tid --file $unrecorded_max_iter_file -- every OTHER listed file is historic and must be reconciled WITHOUT letting it govern: bash .claude/scripts/qa-gate.sh review-reconcile $tid --file <path> '<reason>'"
                    else
                        unrecorded_current_advice="review-check.sh gate reports no governing record exists yet (review_artifact_missing); if one of the listed files is the round that should GOVERN this approval, record THAT one with: bash .claude/scripts/qa-gate.sh review-record $tid --file <path> -- every OTHER listed file is historic and must be reconciled WITHOUT letting it govern: bash .claude/scripts/qa-gate.sh review-reconcile $tid --file <path> '<reason>'"
                    fi
                else
                    # gate could not establish a single governing record for
                    # a reason OTHER than "none exist" (selection
                    # disagreement, a malformed candidate, an unreadable
                    # comment set, or the gate call itself producing no
                    # parseable envelope) -- do NOT guess which file should
                    # govern. This refusal will not name one.
                    unrecorded_current_advice="review-check.sh gate could not establish which round governs (ok=$unrecorded_gate_ok, error_key=${unrecorded_gate_ekey:-<none -- the gate call itself may have produced no parseable output>}) -- this refusal will NOT guess which listed file should be recorded, since a wrong guess can wedge a working selector while reconciling everything cannot. Run \`bash .claude/scripts/review-check.sh gate $tid\` directly to diagnose which round should govern, resolve that first, then reconcile every OTHER listed file: bash .claude/scripts/qa-gate.sh review-reconcile $tid --file <path> '<reason>'"
                fi
                # R15-GATE-CONSULT END (claude-workflow-plugin-k6re)
                emit_error_json "approve" "$tid" "review_artifact_unrecorded" \
                    "approve refused: ${#unrecorded_missing[@]} of ${#unrecorded_disk_artifacts[@]} review artifact(s) on disk for $tid have NO corresponding record (REVIEW-ARTIFACT v1 or REVIEW-ARTIFACT-RECONCILED v1), checked by CONTENT HASH (never mtime): $(printf '%s; ' "${unrecorded_missing[@]}"). The gate would otherwise report 'independent review verified' while a review round nobody folded into the trust chain sits beside it. DO NOT record every listed file the same way: $unrecorded_current_advice. Or, for a legitimate historic backlog that should not permanently strand this task, bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --accept-unrecorded-review '<reason>' '<summary>'" \
                    "qa-gate.sh approve <task-id> [--accept-unrecorded-review '<reason>'] <summary>"
                exit 4
            fi
            unrecorded_review_obs="; unrecorded-artifact check PASSED -- all ${#unrecorded_disk_artifacts[@]} on-disk review artifact(s) for $tid are bound by a REVIEW-ARTIFACT v1 or REVIEW-ARTIFACT-RECONCILED v1 record (verified by content hash)"
            # claude-workflow-plugin-k6re R15-F3: --accept-unrecorded-review's
            # bypass reason reaches this same observations string (branch
            # above), so an acknowledged historic finding must too, or the
            # one audited escape on this path whose subject is an unresolved
            # finding is the one that leaves no trace where an approver
            # looks. recorded-hashes' acknowledged_count is the SAME
            # instrument this block already calls (unrecorded_hashes_out),
            # never a second computation of the ack-marker grammar.
            local unrecorded_ack_count
            unrecorded_ack_count=$(printf '%s' "$unrecorded_hashes_out" | jq -r '.acknowledged_count // 0' 2>/dev/null)
            case "$unrecorded_ack_count" in ''|*[!0-9]*) unrecorded_ack_count=0 ;; esac
            if [ "$unrecorded_ack_count" -gt 0 ]; then
                unrecorded_review_obs="$unrecorded_review_obs; $unrecorded_ack_count of the recorded artifact(s) for $tid carry an acknowledged open finding (review-reconcile --acknowledge-findings; see the REVIEW-ARTIFACT-RECONCILED v1 comment(s) for which finding and why)"
            fi
        fi
    fi
    # UNRECORDED-REVIEW-ARTIFACT-REFUSAL END (claude-workflow-plugin-k6re)

    # P7: the completion-contract audit fields. Declared OUTSIDE the sentinel
    # block below for the same two reasons impact_obs and review_obs are —
    # the --no-completion path skips the block but must still record WHY, and
    # the META-TEST's stripped copy must stay coherent and still write a
    # well-formed approval record.
    local completion_obs=""
    local completion_suffix=""
    if [ "$bypass_completion" = "1" ]; then
        completion_obs="; completion-bypass: $completion_bypass_reason (completion-contract refusal bypassed via --no-completion; reason recorded per P7)"
        completion_suffix=" [completion bypass: $completion_bypass_reason]"
    fi

    # COMPLETION-CONTRACT-REFUSAL BEGIN (P7 / claude-workflow-plugin-qbhw)
    #
    # DID THE PARTY THAT DID THE WORK DESCRIBE IT?
    #
    # THE DEFECT THIS CLOSES. The F7 completion contract shipped with ZERO
    # runtime enforcement. Twelve documents describe it, an L1 parity spec keeps
    # those twelve in step, and nothing anywhere rejected a payload — so
    # `context_coverage` (v4.1) and every field the v5 design phase is about to
    # add (`unit_id`, `green_before`, `green_after`, `design_hash`) were, and
    # would be, documentation. This is the ONE validation point
    # docs/plans/v5-design-phase.md Phase P asks for, wired where it can refuse:
    # a task cannot be approved unless a VALIDATED contract was recorded for it.
    #
    # WHY AT approve AND NOT AT enter. `enter` is documented TOLERANT — it never
    # fails on a missing artifact, and the Stop hook's F1 fast path calls it on
    # exactly the change-set classes that have no specialist and therefore no
    # completion payload at all. A refusal there would deadlock every doc-only
    # Stop, which is the majority of them.
    #
    # WHERE IT SITS, and why here rather than earlier. cmd_approve's refusals are
    # ordered by what each can PROVE and how expensive its remediation is (see
    # the EXPECTED-HASH block's own note). This one goes LAST:
    #   - it needs `$approved_hash` and the reconciled tracker, so it cannot
    #     precede those;
    #   - its remediation is the cheapest of all of them — one
    #     `completion-record` call by whoever did the work — but it is a claim
    #     about the WHOLE task rather than about one artifact, so firing it while
    #     a more basic precondition is still missing would tell the operator to
    #     fix the wrong thing;
    #   - and it must precede every WRITE below, because a refusal has to leave
    #     the task untouched.
    #
    # WHAT IT ESTABLISHES, stated narrowly. That a payload passing
    # review-check.sh `validate-completion` was recorded for THIS task. It does
    # NOT establish that the payload is TRUE, that the change set is complete
    # (see completion_files_crosscheck, which reports on that and deliberately
    # does not refuse), or that the specialist read what it claims to have read
    # — the last is a quality judgement the rubric grader owns (C8).
    #
    # THREAT-MODEL BOUNDARY, inherited rather than introduced: an agent with
    # arbitrary shell can `bd comments add` a well-formed COMPLETION line by
    # hand, exactly as llh.18 documents for the approval record and bjx for the
    # rubric verdict. This raises the bar from "nothing at all" to "a validated
    # payload plus a digest-bound artifact"; it is not a cryptographic sandbox,
    # and the full-shell autonomy model precludes one.
    #
    # The sentinel comments wrapping this block are load-bearing: an L2
    # META-TEST strips everything between them and asserts approve then succeeds
    # with NO completion record at all. Do not rename them.
    if [ "$bypass_completion" != "1" ]; then
        local completion_rec="" completion_sha=""
        completion_rec=$(latest_completion_record "$tid") || completion_rec=""
        if [ -z "$completion_rec" ]; then
            emit_error_json "approve" "$tid" "completion_record_missing" \
                "approve refused: no COMPLETION v1 record exists for $tid, so nothing on this task states what was done, which files it touched, or what the implementer read to ground it. The F7 completion contract is the specialist's structured hand-off (docs/AGENTS.md, 'Specialist Completion Contract (F7)'); until P7 nothing rejected a missing one, which made every field in it documentation. Record it — the specialist writes its F7 payload plus a \"role\" key to a file and runs: bash .claude/scripts/qa-gate.sh completion-record $tid --file <payload.json> — or, when there was no specialist and no payload is owed (the doc-only Stop fast path), bypass with a recorded reason: bash .claude/scripts/qa-gate.sh approve $tid --no-completion '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-completion '<reason>'] <summary>"
            exit 2
        fi
        completion_sha=$(printf '%s' "$completion_rec" | grep -oE 'payload_sha=[A-Za-z0-9._+-]+' | head -1 | cut -d= -f2- || true)
        local completion_role=""
        completion_role=$(printf '%s' "$completion_rec" | grep -oE 'role=[A-Za-z0-9._+-]+' | head -1 | cut -d= -f2- || true)
        completion_obs="; completion contract verified (role=${completion_role:-<unreadable>}, payload_sha=${completion_sha:-<unreadable>})"

        # fkm.1.20: the completeness cross-check. Reports, never refuses — the
        # helper's header gives the four reasons.
        #
        # R1-F4: it reads the IMPLEMENTER's contract, NOT the latest one. The
        # refusal above is satisfied by any contract (the question there is "did
        # anyone hand one back"); this question is "what did the party that DID
        # THE WORK declare", and only an implementer's contract answers it. When
        # QA records its own contract — which this release's qa.md tells it to —
        # the latest record is QA's, whose files_changed is legitimately empty,
        # and reading THAT produced an affirmative "PASSED, every one of the 0
        # declared file(s)" on the very change set the check exists to catch.
        local impl_rec="" impl_sha="" impl_role=""
        impl_rec=$(latest_implementer_completion_record "$tid") || impl_rec=""
        if [ -n "$impl_rec" ]; then
            impl_sha=$(printf '%s' "$impl_rec" | grep -oE 'payload_sha=[A-Za-z0-9._+-]+' | head -1 | cut -d= -f2- || true)
            impl_role=$(printf '%s' "$impl_rec" | grep -oE 'role=[A-Za-z0-9._+-]+' | head -1 | cut -d= -f2- || true)
            completion_files_crosscheck "$tid" "$impl_sha" "$impl_role"
        else
            # No implementer contract. Report it and NAME THE ROLES THAT DID
            # record, because "unestablished" with no cause is the kind of
            # degradation nobody chases.
            COMPLETION_XCHECK_STATE="unestablished"
            COMPLETION_XCHECK_DETAIL="no COMPLETION record on this task carries an implementer role (roles seen: $(completion_roles_seen "$tid" || echo "<unreadable>"); implementer roles are $COMPLETION_IMPLEMENTER_ROLES_JSON). A reviewer's contract declares the files IT edited, which is not a claim about what shipped, so it is deliberately not read here"
        fi
        if [ "$COMPLETION_XCHECK_STATE" != "checked" ]; then
            completion_obs="$completion_obs; completeness cross-check UNESTABLISHED — $COMPLETION_XCHECK_DETAIL (the impact-report freshness check above proves the report is not STALE; it cannot prove the change set is not SHORT, because both of its numbers come from the same tracker — fkm.1.20)"
            completion_suffix=" [completion cross-check: unestablished]"
        elif [ "$COMPLETION_XCHECK_MISSING" -gt 0 ]; then
            local xnote=""
            if [ "$COMPLETION_XCHECK_MATCHED" = "0" ] && [ "$COMPLETION_XCHECK_BOUND" -gt 0 ]; then
                xnote=" NOTE matched=0 with both lists non-empty is the signature of a PATH-SPELLING mismatch (absolute vs relative, a symlinked checkout, a linked worktree), not of loss; the loss shape is PARTIAL overlap"
            fi
            completion_obs="$completion_obs; WARNING completeness cross-check: $COMPLETION_XCHECK_MISSING of $COMPLETION_XCHECK_DECLARED declared file(s) are NOT in the change set this approval binds (declared=$COMPLETION_XCHECK_DECLARED bound=$COMPLETION_XCHECK_BOUND matched=$COMPLETION_XCHECK_MATCHED missing=$COMPLETION_XCHECK_MISSING). Missing (first $COMPLETION_XCHECK_INLINE_CAP): $(printf '%s' "$COMPLETION_XCHECK_MISSING_PATHS" | head -n "$COMPLETION_XCHECK_INLINE_CAP" | tr '\n' ' '). Decide which it is: if those paths ARE this session's work the tracker under-covers and the review does not reach them (94d.1's shape was 2 of 8 matched); if they are baselined-on-arrival dirt, deleted scratch, or denylisted paths, the delta is expected$xnote"
            completion_suffix=" [completion cross-check: $COMPLETION_XCHECK_MISSING of $COMPLETION_XCHECK_DECLARED declared file(s) absent from the bound change set]"
        else
            completion_obs="$completion_obs; completeness cross-check PASSED — every one of the $COMPLETION_XCHECK_DECLARED declared file(s) is in the bound change set of $COMPLETION_XCHECK_BOUND (an INDEPENDENT witness: the declaration predates the tracker bookkeeping, so it can see a truncation the freshness check cannot — fkm.1.20)"
        fi
    fi
    # COMPLETION-CONTRACT-REFUSAL END (P7 / claude-workflow-plugin-qbhw)

    # Declared OUTSIDE the sentinel-wrapped block below — same discipline as
    # design_field/design_binding_obs and worktree_field above: a build with
    # the DESIGN-SATISFIED-REFUSAL region stripped must still leave these
    # bound to their empty defaults, so the write and the final envelope
    # further down stay syntactically and semantically coherent (no dangling
    # token, no unset-variable surprise) even with the whole block gone.
    local design_verdict_field="" design_satisfied_obs=""

    # DESIGN-SATISFIED-REFUSAL BEGIN (v5 D2 / claude-workflow-plugin-fkm.4)
    #
    # DID AN INDEPENDENT DESIGN REVIEW ACTUALLY PASS THIS TASK'S DESIGN?
    #
    # A GENUINE CHOICE, MADE DELIBERATELY: ADD A NEW BLOCK, DO NOT CONVERT
    # DESIGN-BINDING-TOKEN. The scope this task was audited against — and the
    # comment on DESIGN-BINDING-TOKEN's arm 4, below — both invite converting
    # that ladder's "no record" arm into a refusal. This does something else,
    # and here is why. DESIGN-BINDING-TOKEN answers "does a design ARTIFACT
    # exist, and does it still hash to what was recorded" — a fact about
    # PROVENANCE, orthogonal to whether anyone ever reviewed it, and it ALSO
    # computes the `design_field` token the write below still needs on every
    # path (including a task with no review at all, once --no-design is
    # given). Converting its arm 4 would make one block answer two unrelated
    # questions — "what are these bytes" and "were they reviewed" — and would
    # entangle its token-computation duty with a refusal duty the rest of
    # this file keeps separate (REVIEW-SEPARATION refuses; the two
    # *-BINDING-TOKEN ladders only observe). rqer faced the identical decision
    # for the review artifact's OWN file-hash-provenance question and chose
    # to ADD a sibling ladder (REVIEW-ARTIFACT-BINDING-TOKEN) rather than fold
    # it into REVIEW-SEPARATION, which is the refusal that already existed
    # for that axis. This block is the design axis's REVIEW-SEPARATION — the
    # refusal — and DESIGN-BINDING-TOKEN keeps doing exactly what it did
    # before: reporting the artifact's own provenance, nothing more.
    #
    # THE PREDICATE IS NOT REIMPLEMENTED HERE. compute_design_satisfied (see
    # the DESIGN-REVIEW block near the end of this file) is the ONE place
    # that reads the DESIGN-ARTIFACT/DESIGN-REVIEW record grammars and
    # decides — exactly like review-check.sh `gate` is the one place for the
    # code review, and compute_change_set_hash defers to impact-report.sh
    # --hash-only. Reused by cmd_design_gate_precheck (B5) and by nothing
    # else, so there is exactly one place to change this logic.
    #
    # UNCONDITIONAL, LIKE COMPLETION-CONTRACT-REFUSAL ABOVE — NOT CONDITIONED
    # ON "did this task ever start a design". D1's own comment on
    # DESIGN-BINDING-TOKEN's arm 4 (below) states the direction explicitly:
    # "D2 turns this arm into a refusal". A task that never had (or needed) a
    # design phase clears this the same way a doc-only Stop clears
    # completion_record_missing — with an explicit, audited, reasoned
    # `--no-design '<reason>'`, never silently. The alternative (refuse only
    # when a DESIGN-ARTIFACT record already exists) would make the refusal
    # invisible on every ordinary task, which is not what "D2 turns this arm
    # into a refusal" says, and would leave `--no-design` an unused flag.
    #
    # ORDERING. Placed AFTER every other refusal (tracker / change-set /
    # impact-report / expect-hash / review-separation / completion-contract),
    # for the same reason COMPLETION-CONTRACT-REFUSAL itself goes last among
    # the refusals that preceded this phase: it is a claim about the WHOLE
    # task, its remediation is comparatively cheap, and firing it while a
    # more basic precondition is still missing would send the operator to
    # fix the wrong thing first. It is placed BEFORE the two *-BINDING-TOKEN
    # observation ladders that follow (DESIGN-BINDING-TOKEN,
    # REVIEW-ARTIFACT-BINDING-TOKEN) — matching this file's existing
    # convention of refusals-before-audit-tokens — and is, consequently, the
    # LAST refusal before the write at the end of this function.
    # COMPLETION-CONTRACT-REFUSAL's own header no longer claims the last
    # refusal SLOT for itself (see the note on its own placement above); it
    # still correctly claims it must precede every write, which every
    # refusal in this function does, this one included.
    #
    # EXIT 2, NOT 4 (OQ 6.2, resolved by measurement, AC 4.9's "no new exit
    # code" honoured): this is the SAME shape as completion_record_missing —
    # "is a required, non-stale record present" — not the shape exit 4
    # documents ("no independent review artifact / reviewer also implementer
    # / open findings / predicate unavailable"). Independence is ALREADY
    # guaranteed by the time this runs: a non-independent verdict is refused
    # at design-review-record's OWN record time (AC 4.4), so cmd_approve
    # never has an identity question left to ask here — only "does a
    # satisfied, fresh record exist", which is exit 2's family.
    #
    # The sentinel comments are load-bearing: an L1/L2 META strips everything
    # between them and asserts approve then succeeds on a task with no
    # DESIGN-REVIEW record at all. Do not rename them.
    if [ "$bypass_design" = "1" ]; then
        design_satisfied_obs="; design-bypass: $design_bypass_reason (design-satisfied refusal bypassed via --no-design; reason recorded per fkm.4 — this bypasses ONLY the satisfied-verdict requirement; an open DESIGN-CONFLICT is never bypassed by --no-design, see DESIGN-CONFLICT-REFUSAL below, which is unconditional)"
    else
        compute_design_satisfied "$tid"
        if [ "$DESIGN_SATISFIED" != "true" ]; then
            emit_error_json "approve" "$tid" "$DESIGN_SATISFIED_KEY" \
                "approve refused: $DESIGN_SATISFIED_OBS. Record a satisfied, independent design verdict — qa-gate.sh design-review-record $tid --design-hash <h> --file <verdict.json> — or, when this task has no design phase, bypass with a recorded reason: qa-gate.sh approve $tid --no-design '<reason>' '<summary>'" \
                "qa-gate.sh approve <task-id> [--no-design '<reason>'] <summary>"
            exit 2
        fi

        design_verdict_field="design_verdict_hash=$DESIGN_VERDICT_HASH "
        design_satisfied_obs="; $DESIGN_SATISFIED_OBS"
    fi
    # DESIGN-SATISFIED-REFUSAL END (v5 D2 / claude-workflow-plugin-fkm.4)

# DESIGN-CONFLICT-REFUSAL BEGIN (v5 D5 / claude-workflow-plugin-fkm.7; UNCONDITIONAL since
# claude-workflow-plugin-i8cx, operator ruling on rounds 6/7/8 independent review)
    #
    # design_conflict_open joins DESIGN_SATISFIED_KEY's own vocabulary
    # (no_design_attempted, design_verdict_missing, design_not_satisfied,
    # ...) AS A REFUSAL, but is its OWN block — nested inside neither arm of
    # the DESIGN-SATISFIED-REFUSAL if/else above, and NOT folded into
    # compute_design_satisfied itself, because that predicate is ALSO
    # consulted by design-gate-precheck (exit 4) and design-conform (a
    # DIFFERENT failure shape, emit_design_conform), and folding a conflict
    # check into the shared predicate would change THEIR behaviour too. This
    # block only ever runs from cmd_approve.
    #
    # RUNS UNCONDITIONALLY, AFTER THE if/else ABOVE, REGARDLESS OF
    # bypass_design — this is the load-bearing shape of the fix, not
    # cosmetic.
    #
    # "UNCONDITIONALLY" ABOVE DESCRIBES THIS BLOCK'S OWN BEHAVIOUR RELATIVE
    # TO bypass_design — it does not by itself mean "on every call to
    # cmd_approve", and that gap was real, not hypothetical. A2 (claude-
    # workflow-plugin-i8cx, TIER 0, found after TEN independent review rounds
    # on this same axis) is the fix: the hash-aware idempotency no-op far
    # above in this function (see IDEMPOTENCY, and
    # IDEMPOTENT-APPROVE-CONFLICT-RECHECK nested inside it) RETURNS before
    # this block is ever reached, on every call where qa-approved is already
    # set and the change set has not moved. Filing a DESIGN-CONFLICT touches
    # no file and moves no change-set hash, so that early return could report
    # "approved" over an open, evidenced conflict with THIS block never once
    # evaluated. Closed by giving the idempotency arm its OWN copy of this
    # exact check (same predicate, same error_key, same exit code — see that
    # block's own header for why a second call site and not a restructure)
    # rather than by moving this one — moving it would reorder it ahead of
    # tracker/impact-report/review/completion for the ORDINARY approval path
    # too, contradicting the cost-ordering rationale the rest of this
    # function's refusals document (see the EXPECTED-HASH-REFUSAL comment
    # above). The function-wide guarantee — no approve call can report
    # success while an open, un-amended design conflict exists — now holds
    # across BOTH call sites inside cmd_approve; this text alone never
    # guaranteed it on its own, and no longer claims to.
    #
    # Formerly (through independent review round 5) this block was
    # nested INSIDE the `else` (non-bypass) arm only, so --no-design skipped
    # it entirely and could waive a real, evidenced, open objection with the
    # SAME flag used for "no design phase at all". Independent review rounds
    # 6-8 on claude-workflow-plugin-i8cx found FOUR HIGH findings against
    # the waiver mechanism that grew out of that placement (R6-F1: the
    # waiver was forgeable — any approval summary containing the literal
    # bracket text `[design conflict waived: units=<ids>]` was read back as
    # a real waiver by a later reader, because the record's own free-text
    # summary space is self-asserted, exactly the DESIGN-BINDING-TOKEN
    # block above already warns is true of every bracketed suffix in this
    # file; R6-F2: the reader took the LATEST QA-GATE APPROVED comment
    # without checking it governs the CURRENT change-set hash, so a waiver
    # from a stale, superseded approval could authorize an unrelated
    # release; R6-F3: subtraction was by unit ID with no per-record
    # identity, so a waiver silently covered every FUTURE conflict filed on
    # that unit, not only the one the operator actually saw; R6-F4: the
    # clearing predicate the waiver's own disclosure reader depended on
    # cleared on unit CONTENT CHANGE ALONE, without requiring the
    # accompanying superseding review the v5 plan specifies — an edit is
    # not an approved review). The operator's ruling: a record invented to
    # make a bypass OBSERVABLE had been promoted into a control that
    # AUTHORIZES releases, and disclosure and authorization carry different
    # evidentiary requirements — remove the mechanism rather than guard it
    # a fifth time. There is now exactly one way an open conflict stops
    # blocking: a superseding, independently-reviewed, SATISFIED
    # DESIGN-REVIEW under which the disputed unit's own content changed
    # (compute_design_conflict_open's own header documents the exact
    # predicate, including the R6-F4 fix requiring the satisfied review,
    # not merely a content edit). No flag, marker, label, or free-text
    # phrase clears it. --no-design bypasses ONLY the DESIGN_SATISFIED
    # check in the if/else above; it has no effect on this block, which
    # would run identically (and refuse identically) whether or not
    # bypass_design is set — hence its placement AFTER, not inside, that
    # if/else.
    #
    # THE fkm.1.19 DISCIPLINE, APPLIED HERE: compute_design_conflict_open
    # reads EVERY DESIGN-CONFLICT record on $tid, never just the latest.
    # review-check.sh's own gate reads only the latest review artifact,
    # which is what let a later artifact silently retire an earlier open
    # finding by never mentioning it (fkm.1.19, an OPEN P0 against that
    # exact class of reader). A DESIGN-CONFLICT record carries no
    # "supersedes" marker of its own, so "read the latest one" would
    # reproduce the identical defect one record-grammar over: a second
    # conflict on a DIFFERENT unit, filed after the first was addressed,
    # would silently un-list the first the moment it became merely
    # "not the latest". Every record is evaluated independently instead
    # (see compute_design_conflict_open's own header for the exact
    # per-record predicate). NOT arbitrate: that verb is keyed to
    # REVIEW-ARTIFACT finding ids via finding_id_in_latest_artifact (this
    # file, defined once, grep for it rather than trust a line number here
    # — this exact block's own edits already moved it once); introducing a
    # second id-space into it would break that reader, and the plan states
    # this as a decision, not a preference.
    #
    # EXIT 2, MATCHING THE CONVENTION ALREADY IN FORCE FOR THIS AXIS:
    # DESIGN_SATISFIED_KEY's own refusal, immediately above, already chose
    # exit 2 over exit 4 for this same axis and documented why ("EXIT 2, NOT
    # 4 (OQ 6.2 ...)" on DESIGN-SATISFIED-REFUSAL's own header — this is the
    # identical shape, "is a required, satisfied, unconflicted state
    # established", not REVIEW-SEPARATION's "no independent review /
    # reviewer also implementer / open findings / predicate unavailable").
    # Exit 5 is a DIFFERENT command's convention entirely — design-unit-
    # bind's write-unconfirmed refusals (fkm.6; grep '^\s*exit 5$' this file
    # rather than trust a line number) — reusing it here would put two
    # unrelated meanings on one exit code for no reason this block's own
    # ordering rationale would recognise.
    #
    # FAIL CLOSED ON AN UNREADABLE SOURCE, never as "no conflict" — the SAME
    # xsu1 discipline design_source_unreadable/design_verdict_missing
    # already draw a hard line for the satisfied-verdict axis above, and
    # --no-design does not relax it here either: an unreadable conflict
    # history is unknown, not cleared, whether or not the operator typed
    # --no-design.
    #
    # The sentinel comments are load-bearing: an L1 META strips everything
    # between them and asserts approve then succeeds on a task carrying an
    # OPEN, un-amended design_conflict record, WITH OR WITHOUT --no-design
    # (the negative-control legs in design-review-record.test.sh Section 8e
    # exercise both). Do not rename them.
    local design_conflict_rc=0
    compute_design_conflict_open "$tid" || design_conflict_rc=$?
    if [ "$design_conflict_rc" -ne 0 ]; then
        emit_error_json "approve" "$tid" "design_conflict_source_unreadable" \
            "approve refused: the DESIGN-CONFLICT history for $tid could not be read right now (bd unreachable, the comment stream not retrievable, or a record read back malformed), so whether an open design conflict exists is unknown; refusing to report this as no-conflict. This cannot be bypassed by --no-design, which covers only the satisfied-verdict requirement, never an unreadable conflict source. Re-run once bd is reachable" \
            "qa-gate.sh approve <task-id> <summary>"
        exit 2
    fi
    if [ "$DESIGN_CONFLICT_OPEN" = "true" ]; then
        emit_error_json "approve" "$tid" "design_conflict_open" \
            "approve refused: $DESIGN_CONFLICT_OPEN_OBS Affected unit(s): $DESIGN_CONFLICT_OPEN_UNITS. The single legal clearing path is a superseding, independently-reviewed, SATISFIED DESIGN-REVIEW whose entry for the affected unit(s) changed — amend docs/specs/$tid.md and record a fresh verdict: qa-gate.sh design-review-record $tid --design-hash <h> --file <verdict.json>. This cannot be waived by --no-design or any other flag: an open, evidenced design objection has exactly one legal clearing path, and a content edit alone is not enough without an accompanying satisfied review" \
            "qa-gate.sh design-review-record <task-id> --design-hash <sha256> --file <path>"
        exit 2
    fi
# DESIGN-CONFLICT-REFUSAL END (v5 D5 / claude-workflow-plugin-fkm.7)

    # ---- APPROVE-COMMIT ORDER (gz3 / v4.1 U1) -----------------------------
    #
    # The steps below are ordered so that a Stop hook firing CONCURRENTLY never
    # observes a state that reads as "approved, but the change set is
    # unbindable". The gate has two processes and no lock: `qa-gate.sh approve`
    # runs in the QA subagent while the Stop hook runs in the parent session, so
    # every intermediate state of this function is observable. THREE such states
    # produced transient false blocks; all three were reproduced deterministically
    # against the pre-fix scripts before anything here moved (drive points, not
    # sleeps — see the spec named at the end of this note).
    #
    #   W1  a Stop between the label add and the record write -> the
    #       forged-label LABEL_WITHOUT_RECORD block, for a legitimate approval.
    #   W2  a Stop between clear_current_task and the truncation -> the
    #       "No active Beads task detected" block, for work just approved.
    #   W3  a Stop whose OWN two change-set reads straddle the truncation ->
    #       recomputes the empty-set hash, matches no record, same block.
    #
    # W1 and W2 are closed by the reordering below (rules 1 and 3). W3 cannot be:
    # both reads belong to the Stop process and straddle whatever approve does in
    # between, so it is closed on the Stop side by the VANISHED-CHANGE-SET
    # re-read in verify-before-stop.sh — which depends on rule 2 holding here.
    #
    #   1. RECORD BEFORE LABEL (CHANGED here). The Stop's release predicate is
    #      (label AND a record matching the current hash). Writing the label
    #      first opened W1 — two bd label calls wide. A record with no label is
    #      inert (the label is still required), so this direction has no
    #      symmetric hazard: a Stop landing there sees the ordinary
    #      not-yet-approved block instead of the alarming forged-label one.
    #   2. BASELINE BEFORE TRACKER (UNCHANGED, and now load-bearing). This was
    #      already the order 0wk.2 shipped; what is new is that something DEPENDS
    #      on it. Both are state a Stop reads to answer "is there anything to
    #      review?", and in this order an empty tracker always implies a
    #      refreshed baseline — so the Stop-side re-read that closes W3 cannot
    #      observe a half-finalized pair and conclude that un-baselined dirt is
    #      unreviewed. Flipping these two lines re-opens W3; that is why the
    #      order is pinned by a test rather than left to chance.
    #   3. SESSION STATE LAST (CHANGED here). clear_current_task used to run
    #      BEFORE the truncation, which is W2. After the truncation there is
    #      nothing left to review, so a missing task id cannot produce a block.
    #   4. NOTHING DESTRUCTIVE BEFORE THE LABELS LAND (UNCHANGED). The
    #      tracking-state finalization (baseline refresh + truncate) stays AFTER
    #      every step that can roll back. This is why the finalization is not
    #      simply hoisted to the top to make the whole thing look atomic: a
    #      rollback that had already truncated the tracker and refreshed the
    #      baseline would leave a session whose work is invisible to the gate —
    #      the next Stop would release unreviewed code on the "no changes" fast
    #      path. Fail-closed beats atomic-looking.
    #
    # Reproductions + regression coverage (W1/W2 at their drive points, W3, and
    # the source order): .claude/tests/component/specs/approve-idempotency.sh
    # sections E and F.

    # Step 1 (gz3: record BEFORE label): the approval record.
    # Non-fatal — labels remain the lifecycle source of truth.
    # G2.n6d: a bypass reason is appended so the audit trail names WHY the
    # mechanical impact gate was waived for this approval.
    #
    # llh.18 (red-team P0/P1): the comment is now the CHANGE-SET-BOUND APPROVAL
    # RECORD that binds this approval to the reviewed change-set. The
    # `change_set_hash=<h>` token is what verify-before-stop.sh reads back and
    # matches against the CURRENT change-set hash before releasing. The label
    # `qa-approved` remains necessary (status precedence, idempotency); the
    # change-set-bound record is now ADDITIONALLY required at Stop time. A bare
    # `bd label add <task> qa-approved` writes no such record → Stop blocks
    # (P0); a decoy-task approval records the decoy's hash, not the shipping
    # change-set's → Stop blocks (P1); a post-approval edit shifts the current
    # hash away from the recorded one → Stop blocks (re-review).
    #
    # THREAT-MODEL BOUNDARY (documented, NOT overclaimed): an agent with
    # arbitrary shell + the hash tool could still forge this very comment
    # (`bd comment add "QA-GATE APPROVED change_set_hash=$(impact-report.sh
    # --hash-only)"`). This fix raises the bar from "trivially-forgeable
    # label" to "must reproduce a change-set-bound record", defeats
    # accidental / lazy / bare-`bd label add` drift, and binds approval to the
    # reviewed files (P1) — it is NOT a cryptographic sandbox against a
    # determined adversary. A signed/HMAC'd record keyed on a secret the
    # gated process cannot read would be required for that, which the
    # full-shell autonomy model (no secrets withheld from agents) precludes.
    #
    # V3 (jio.1): the record additionally names WHO reviewed
    # (`reviewed_by=<identity>`, or `none` on the audited --no-review bypass).
    # 3mg.2 (V4 pt2): and WHERE — `worktree=<tok>`, the approving checkout.
    #
    # Token ORDER is a compatibility contract: every token added since llh.18
    # goes AFTER the change_set_hash token, separated by a SPACE, so the Stop
    # hook's existing `capture("change_set_hash=(?<h>[A-Za-z0-9-]+)")` still
    # stops at that space and reads the same hash it always did — and the V3
    # `\breviewed_by=(\S+)` capture likewise stops before `worktree=`.
    # Prepending a token, or joining two with anything in [A-Za-z0-9-], would
    # silently corrupt every hash comparison. Regression: the L1
    # review-separation.test.sh section 4 compat + META assertions run the
    # readers' EXACT expressions against a freshly written record. Final shape
    # (v5 D2 / claude-workflow-plugin-fkm.4 adds `design_verdict_hash=`, last
    # among the machine tokens per the placement rule rqer established for
    # `artifact_hash=`; fkm.4 also corrects this example, which had drifted —
    # `artifact_hash=` was already shipping at :3944 without ever being added
    # here):
    #   QA-GATE APPROVED change_set_hash=<h> reviewed_by=<id> worktree=<tok>
    #     design_hash=<h> artifact_hash=<h> design_verdict_hash=<h> at <ts>: <summary>
    #     [ [impact-report bypass: <reason>]][ [review bypass: <reason>]]
    #     [ [unrecorded review artifact accepted: <reason>]]
    #     [ [rubric mismatch: …]][ [reconstructed change set accepted: …]]
    #     [ [completion bypass: …]][ [completion cross-check: …]]
    #     [ [design bypass: <reason>]]
    # Eight suffix spellings from seven sites (claude-workflow-plugin-k6re
    # added the unrecorded-review-artifact bypass); the two `completion
    # cross-check` bodies differ in text and share the marker.
    # claude-workflow-plugin-i8cx
    # (operator ruling on rounds 6/7/8 independent review) REMOVED an eighth,
    # `[design conflict waived: units=<ids>]` — it existed only to shape the
    # marker a reader consumed, and that reader is gone; an open DESIGN-
    # CONFLICT now refuses `approve` unconditionally (see DESIGN-CONFLICT-
    # REFUSAL above) instead of being disclosed as a waived bypass. Keep this
    # list and the `approve` usage text in step — both had drifted by two
    # releases before D1, and the `artifact_hash=` omission just fixed above
    # shows it can drift again in one.
    # Every optional MACHINE field carries its own trailing space and defaults to
    # empty, so a build with any one of their sentinel regions stripped writes a
    # record with no dangling token and no double space. Every optional SUFFIX is
    # free-text audit prose appended after the summary.
    local ts comment_suffix=""
    if [ "$bypass_impact" = "1" ]; then
        comment_suffix=" [impact-report bypass: $bypass_reason]"
    fi
    if [ "$bypass_review" = "1" ]; then
        # The literal `[review bypass:` marker is what verify-before-stop.sh
        # reads to skip its own review-discipline check for this record (the
        # F1 doc-only fast path is the intended producer).
        comment_suffix="$comment_suffix [review bypass: $review_bypass_reason]"
    fi
    # claude-workflow-plugin-k6re: same reasoning as every bracketed suffix
    # here — "was a stray unrecorded review artifact known and waived, and
    # why" is an audit question asked LATER, by someone reading the task, and
    # an envelope read once by whoever typed the command is not where it
    # survives. Bracketed suffix, after every machine token, so the
    # `change_set_hash=` / `reviewed_by=` / `worktree=` captures stop where
    # they always did.
    if [ "$bypass_unrecorded_review" = "1" ]; then
        comment_suffix="$comment_suffix [unrecorded review artifact accepted: $unrecorded_review_bypass_reason]"
    fi
    # R2-F2: the mismatch goes in the DURABLE record, not only the envelope.
    # An envelope is read once by whoever ran the command; the audit question
    # ("did the verdict this approval cited actually cover it?") is asked later,
    # by someone reading the task. Same bracketed-suffix shape as the two
    # bypasses, and after every machine token, so the llh.18 / 3mg.2 readers
    # (`change_set_hash=`, `reviewed_by=`, `worktree=`) stop where they always
    # did.
    if [ "$rubric_mismatch" = "1" ]; then
        comment_suffix="$comment_suffix [rubric mismatch: graded=$rubric_graded_hash approved=$approved_hash]"
    fi
    # CHANGE-SET-RECONSTRUCTED BEGIN (94d.1)
    # Same reasoning as R2-F2 above, and it applies harder here: this bypass says
    # "the change set I am binding was rebuilt from git and is provably short, and
    # I judged the missing paths pre-existing". That judgement is exactly what a
    # later audit needs to see, and an envelope read once by whoever typed the
    # command is not where it survives. Bracketed suffix, after every machine
    # token, so the `change_set_hash=` / `reviewed_by=` / `worktree=` captures
    # stop where they always did.
    if [ "$bypass_reconstructed" = "1" ]; then
        comment_suffix="$comment_suffix [reconstructed change set accepted: $reconstructed_bypass_reason (subtracted=${RECONCILE_SUBTRACTED:-0})]"
    fi
    # CHANGE-SET-RECONSTRUCTED END (94d.1)
    # P7: the completion-contract token — the audited bypass, or the
    # completeness cross-check's verdict when it is anything other than clean.
    # Same reasoning as R2-F2 and 94d.1 above, and it applies with full force
    # here: "the bound change set omits 6 of the 8 files the implementer
    # declared" is an audit question asked LATER, by someone reading the task,
    # and an envelope read once by whoever typed the command is not where it
    # survives. Bracketed suffix, after every machine token, so the
    # `change_set_hash=` / `reviewed_by=` / `worktree=` captures stop where they
    # always did. Expanded with :- so a stripped sentinel region leaves the
    # record coherent.
    comment_suffix="$comment_suffix${completion_suffix:-}"
    # v5 D2 (claude-workflow-plugin-fkm.4): the design-satisfied bypass token —
    # same reasoning as every bracketed suffix above: the audit question ("was
    # this task's design phase waived, and why") is asked LATER, by someone
    # reading the task, and an envelope read once by whoever typed the command
    # is not where it survives.
    #
    # fkm.4 R1-F1 fix round (R1-F5): appended AFTER the completion suffix
    # (this block originally sat BEFORE it, immediately after the
    # CHANGE-SET-RECONSTRUCTED arm above) so it lands LAST among the seven
    # bracketed suffixes — matching the order both `usage()`'s approve grammar
    # and this function's OWN "final shape" comment above already document.
    # Those two comments warn IN SO MANY WORDS that they can drift apart from
    # each other ("Keep this list and the `approve` usage text in step — both
    # had drifted by two releases before D1"); this was the same drift one
    # level down, between the documented order and the code that was supposed
    # to produce it, caught before it shipped a third divergence.
    if [ "$bypass_design" = "1" ]; then
        comment_suffix="$comment_suffix [design bypass: $design_bypass_reason]"
        # claude-workflow-plugin-i8cx (operator ruling on rounds 6/7/8
        # independent review): this USED to be followed by an eighth,
        # conditional bracket — `[design conflict waived: units=<ids>]` —
        # disclosing when --no-design had also waived an open DESIGN-
        # CONFLICT. That waiver mechanism is REMOVED: an open conflict now
        # refuses `approve` unconditionally (DESIGN-CONFLICT-REFUSAL above
        # runs regardless of bypass_design), so this branch can never be
        # reached while a conflict is open — there is nothing left to
        # disclose. Kept as observability-only was considered and rejected:
        # since the state it would describe (a released approval with an
        # open conflict) can no longer occur, the code would be unreachable
        # by construction, which is worse than absent — dead code that
        # LOOKS load-bearing is exactly the shape that invited this
        # mechanism's four rounds of "fix the reader" instead of "remove
        # it". Rely on refusal alone.
    fi
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local hash_field=""
    if [ -n "$approved_hash" ]; then
        hash_field="change_set_hash=$approved_hash "
    fi

    # Declared with an EMPTY default outside the sentinel block below (same
    # discipline as reviewed_by / approved_hash): stripping the block must
    # leave a coherent record — the pre-3mg.2 grammar, with no dangling
    # `worktree=` and no double space.
    local worktree_field=""
    # WORKTREE-TOKEN BEGIN (v4 V4 / claude-workflow-plugin-3mg.2)
    #
    # Every approve path reaches this ONE add_comment — the normal path, the
    # F1 `--no-review` fast path, and both audited bypasses — so recording the
    # token here covers all of them without a second write site.
    #
    # The L1 META strips these sentinels and asserts (a) the copy still
    # approves and writes the pre-3mg.2 record, and (b) the change_set_hash /
    # reviewed_by captures extract IDENTICAL values from both shapes. That is
    # the falsifiable form of "adding this token cannot regress the readers".
    worktree_field="worktree=$(approval_worktree_token) "
    # WORKTREE-TOKEN END (v4 V4 / claude-workflow-plugin-3mg.2)

    # Same empty-default-outside-the-sentinels discipline as worktree_field: the
    # L1 META strips this region and asserts the copy still approves and still
    # writes a coherent pre-D1 record with no double space.
    local design_field="" design_binding_obs=""
    local review_file_hash_field="" review_file_binding_obs=""
    # DESIGN-BINDING-TOKEN BEGIN (v5 D1 / claude-workflow-plugin-fkm.3)
    #
    # A FOURTH MACHINE TOKEN, not a bracketed suffix, and the choice is
    # load-bearing rather than stylistic:
    #
    #   * THE SUFFIX SPACE IS SELF-ASSERTED. `$summary` is built from bare
    #     positionals with no validation and is interpolated on this same line,
    #     immediately before $comment_suffix — and both readers of the existing
    #     markers use `grep -qF '[review bypass:'` over the whole comment text
    #     (verify-before-stop.sh, two sites). So `approve <tid> 'done [review
    #     bypass: x]'` already satisfies that skip today, which is filed
    #     separately as claude-workflow-plugin-yrij. A value the gate must TRUST
    #     cannot live in a space the person typing the command controls. Every
    #     one of the six existing suffix bodies is unvalidated human prose; none
    #     is a value a program extracts and compares.
    #   * THERE IS NO TOKEN BUDGET. The compatibility contract above constrains
    #     token ORDER, not COUNT: everything since llh.18 goes AFTER
    #     change_set_hash, separated by a space. Every reader is an anchored
    #     capture that a further appended key=value cannot disturb, and this
    #     token goes last, immediately before ` at <ts>`.
    #
    # THE LADDER, four arms, the same shape and the same doctrine as
    # grade-record's change-set binding ladder — "unbound with the reason named"
    # is the bottom, never silence:
    #   1. A DESIGN-ARTIFACT record exists AND a live re-hash of the artifact
    #      agrees with it -> BIND. That agreement is the whole enforcement: it
    #      is a live recompute rather than a label, so a one-byte post-approval
    #      edit to the design moves the artifact away from every record that
    #      names it, exactly as a post-approval code edit moves change_set_hash.
    #   2. A record exists but the artifact on disk hashes differently -> NO
    #      token, both hashes named. The design moved after it was recorded and
    #      this approval cannot say which bytes it covers.
    #   3. A record exists but the artifact cannot be hashed at all (absent,
    #      unreadable, empty) -> NO token, reason named. Never a placeholder:
    #      zero bytes digest to a constant that would compare equal to itself
    #      forever.
    #   4. No record -> NO token, reason named. Ordinary today: nothing has a
    #      design yet. D1 records the fact; D2 did NOT convert THIS arm — see
    #      DESIGN-SATISFIED-REFUSAL above (before this ladder runs) for where
    #      the refusal D1 anticipated actually landed, and why it is a new
    #      block rather than this arm converted in place. This ladder still
    #      answers only "what are these bytes", exactly as it did before D2.
    #
    # ARM 1a IS THE CONTAINMENT ONE, and it uses the SAME predicate design-record
    # uses (fkm.3 QA round 2, R2-F2). This is the THIRD caller of that question,
    # and the round that added it was about two callers answering it differently:
    # without this arm, replacing the recorded artifact with a symlink to an
    # outside file would have this re-hash follow the link, agree with the
    # recorded digest whenever the outside bytes matched, and report VERIFIED for
    # a document the declaration in workflow-manifest.sh does not govern.
    local recorded_design_hash live_design_hash design_artifact_path dh_rc=0
    recorded_design_hash=$(latest_design_artifact_hash "$tid") || recorded_design_hash=""
    if [ -z "$recorded_design_hash" ]; then
        design_binding_obs="; no design binding (no DESIGN-ARTIFACT record on $tid)"
    elif ! is_sha256_hex "$recorded_design_hash"; then
        design_binding_obs="; WARNING no design binding — the DESIGN-ARTIFACT record's design_hash='$recorded_design_hash' is not 64 hex characters, so it names no reproducible bytes"
    else
        design_artifact_path=$(design_artifact_path_for "$tid")
        if ! design_path_is_contained "$design_artifact_path"; then
            design_binding_obs="; WARNING no design binding — $design_artifact_path does not resolve INSIDE $DESIGN_SPEC_SUBDIR/ (a symlink out of the declared directory, or a directory that has moved), so whatever it hashes to now is not the artifact that declaration governs"
        else
            live_design_hash=$(bash "$PROJECT_DIR/.claude/scripts/workflow-manifest.sh" \
                hash-file "$design_artifact_path" 2>/dev/null) || dh_rc=$?
            if [ "$dh_rc" -ne 0 ] || ! is_sha256_hex "$live_design_hash"; then
                design_binding_obs="; WARNING no design binding — $design_artifact_path could not be hashed now (rc=$dh_rc), so the recorded design_hash=$recorded_design_hash cannot be corroborated against the bytes on disk"
            elif [ "$live_design_hash" != "$recorded_design_hash" ]; then
                design_binding_obs="; WARNING no design binding — the design artifact has CHANGED since it was recorded (recorded=$recorded_design_hash, on disk now=$live_design_hash). Re-record it (qa-gate.sh design-record $tid) so the approval names the bytes it covers"
            else
                design_field="design_hash=$recorded_design_hash "
                design_binding_obs="; design binding VERIFIED — $design_artifact_path still hashes to the recorded design_hash=$recorded_design_hash"
            fi
        fi
    fi
    # DESIGN-BINDING-TOKEN END (v5 D1 / claude-workflow-plugin-fkm.3)

    # REVIEW-ARTIFACT-BINDING-TOKEN BEGIN (v5 D2 / claude-workflow-plugin-rqer)
    #
    # AC-3's mirror of the DESIGN-BINDING-TOKEN ladder immediately above: a
    # live re-hash of the review artifact, not a label, so a one-byte
    # post-record edit moves the artifact away from every record that names
    # it — same doctrine, same four-arm ladder ("BIND" / "changed since
    # recorded" / "cannot be hashed now" / "no record"), same "no token,
    # reason named" floor instead of silence.
    #
    # INDEPENDENT of --no-review, deliberately: a fresh call to review-check.sh
    # gate is made here rather than reusing $review_out from the
    # REVIEW-SEPARATION block above, because that block's call is SKIPPED
    # entirely on the --no-review bypass path, and whether the review artifact
    # file still matches its own record is a fact about the FILE, not about
    # whether the review-separation POLICY gate was waived for this approval.
    local recorded_review_hash="" recorded_review_iter="" live_review_hash=""
    local review_artifact_path="" review_hash_rc=0 art_gate_out=""
    art_gate_out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" gate "$tid" 2>/dev/null || true)
    recorded_review_hash=$(printf '%s' "$art_gate_out" | jq -r '.artifact.artifact_hash // ""' 2>/dev/null || echo "")
    recorded_review_iter=$(printf '%s' "$art_gate_out" | jq -r '.artifact.iteration // ""' 2>/dev/null || echo "")
    if [ -z "$recorded_review_hash" ]; then
        review_file_binding_obs="; no review-artifact binding (no artifact_hash= on the latest REVIEW-ARTIFACT v1 record for $tid — pre-rqer record, or no review recorded yet)"
    elif ! is_sha256_hex "$recorded_review_hash"; then
        review_file_binding_obs="; WARNING no review-artifact binding — the latest record's artifact_hash='$recorded_review_hash' is not 64 hex characters, so it names no reproducible bytes"
    else
        review_artifact_path=$(review_artifact_path_for "$tid" "$recorded_review_iter")
        if ! review_path_is_contained "$review_artifact_path"; then
            review_file_binding_obs="; WARNING no review-artifact binding — $review_artifact_path does not resolve INSIDE $REVIEW_ARTIFACT_SUBDIR/ (a symlink out of the declared directory, or a directory that has moved), so whatever it hashes to now is not the artifact that record governs"
        else
            live_review_hash=$(bash "$PROJECT_DIR/.claude/scripts/workflow-manifest.sh" \
                hash-file "$review_artifact_path" 2>/dev/null) || review_hash_rc=$?
            if [ "$review_hash_rc" -ne 0 ] || ! is_sha256_hex "$live_review_hash"; then
                review_file_binding_obs="; WARNING no review-artifact binding — $review_artifact_path could not be hashed now (rc=$review_hash_rc), so the recorded artifact_hash=$recorded_review_hash cannot be corroborated against the bytes on disk"
            elif [ "$live_review_hash" != "$recorded_review_hash" ]; then
                review_file_binding_obs="; WARNING no review-artifact binding — the review artifact has CHANGED since it was recorded (recorded=$recorded_review_hash, on disk now=$live_review_hash). Re-run review-record so the approval names the bytes it covers"
            else
                review_file_hash_field="artifact_hash=$recorded_review_hash "
                review_file_binding_obs="; review-artifact binding VERIFIED — $review_artifact_path still hashes to the recorded artifact_hash=$recorded_review_hash"
            fi
        fi
    fi
    # REVIEW-ARTIFACT-BINDING-TOKEN END (v5 D2 / claude-workflow-plugin-rqer)

    add_comment "$tid" "QA-GATE APPROVED ${hash_field}reviewed_by=$reviewed_by ${worktree_field}${design_field}${review_file_hash_field}${design_verdict_field}at $ts: $summary$comment_suffix"

    # Step 2 (gz3: after the record): THE terminal-label transition. One call
    # replaces what were four separate steps — add qa-approved, remove
    # qa-gate-entered with a rollback, remove qa-pending with a hand-written
    # inverse of that rollback, then two best-effort helper calls for the
    # escalation pair and rubric-pending. See set_terminal_label for the ordering
    # rationale (terminal first, then sweep) and for why the transition is one
    # function rather than one more step.
    #
    # WHAT THIS CLEARS: the cycle set below, minus qa-approved itself. What it does
    # NOT clear is rubric-satisfied, which is not a member of QA_CYCLE_LABELS at
    # all — the audit trail of the verdict that backed this approval, handled by
    # the had_rubric_satisfied / rubric_mismatch logic above and reported in
    # $rubric_obs below.
    #
    # The list is declared OUTSIDE the sentinel region that follows, with
    # qa-blocked appended INSIDE it. Same discipline as worktree_field's empty
    # default above: stripping the region must leave a copy that still performs a
    # coherent pre-8zi approve, otherwise the META asserting "qa-blocked survives
    # the stripped copy's approve" would be measuring a script that cannot approve
    # at all, and would pass for the wrong reason.
    local -a sweep_clear=(qa-gate-entered qa-pending qa-escalated qa-deferred rubric-pending)
    # TERMINAL-LABEL-SWEEP BEGIN (8zi)
    # THE 8zi DELTA, in one line: a previous cycle's qa-blocked is part of what an
    # approval ends. Without it the block -> fix -> approve round trip terminates
    # with both terminal labels set and no way for a reader to tell which is
    # current — reproduced live on uvk, q7n, 94d and qzv.1.
    sweep_clear+=(qa-blocked)
    # TERMINAL-LABEL-SWEEP END (8zi)
    if ! set_terminal_label "$tid" "qa-approved" "${sweep_clear[@]}"; then
        if [ "$TERMINAL_SWEEP_PHASE" = "add_terminal" ]; then
            # The record is already on the task and comments are append-only, so we
            # say so rather than claiming "nothing changed": without the label the
            # record cannot release anything (the Stop needs both), and re-running
            # approve writes a fresh record.
            log_sync_error "approve: qa-approved label add FAILED for $tid after the approval record was written; the record cannot release without the label — re-run approve (gz3 ordering)"
            emit_json 0 "approve" "$tid" "error" "failed to add qa-approved; no labels changed (the approval record was already written and cannot be unwritten — it is inert without the label; re-run approve). $TERMINAL_SWEEP_OBS"
            exit 3
        fi
        log_sync_error "approve: the terminal-label transition FAILED for $tid after the approval record was written; $TERMINAL_SWEEP_OBS"
        emit_json 0 "approve" "$tid" "error" "approve rolled back: $TERMINAL_SWEEP_OBS (the approval record was already written and cannot be unwritten — it is inert without the label; re-run approve once bd is healthy)"
        exit 3
    fi

    # The two counters the approve envelope has always reported. Derived from what
    # the sweep actually removed rather than from a has_label captured at the top
    # of this function, which is a slightly sharper claim: it reports the state
    # transition this call performed, not a presence check taken several refusals
    # and one record write earlier.
    local removed_entered=0 removed_pending=0
    case " $TERMINAL_SWEEP_REMOVED " in *" qa-gate-entered "*) removed_entered=1 ;; esac
    case " $TERMINAL_SWEEP_REMOVED " in *" qa-pending "*) removed_pending=1 ;; esac
    local sweep_obs="; cycle labels cleared: [${TERMINAL_SWEEP_REMOVED:-none}]"

    # ---- TRACKING-STATE FINALIZATION (gz3 ordering rules 2 and 4) ---------
    # Runs AFTER every step that can roll back (rule 4), and in the order
    # baseline-then-tracker (rule 2). Read the APPROVE-COMMIT ORDER note above
    # before reordering either of these two lines.

    # 0wk.2 fix: snapshot current git status to the gate baseline. Subsequent
    # Stop hook fires compare git status against this baseline and only
    # block if NEW uncommitted entries appear. Closes 0wk.2.
    #
    # FULL refresh (no --if-missing, no --exclude-tracked): approve means
    # "everything dirty right now has been reviewed", so the whole working
    # tree is the new reference point. Paired with the tracker truncation
    # below, a fresh approval starts a clean cycle.
    #
    # gz3: this MUST precede truncate_changed_files_tracker. An empty tracker
    # paired with a stale baseline is the state that made a Stop conclude
    # "un-baselined dirt, no bound approval" for work that had just been
    # approved; in this order that pairing is unreachable.
    if ! write_gate_baseline "qa-gate-approve"; then
        log_sync_error "approve: gate-baseline refresh failed for $tid (subsequent Stops will treat existing git dirt as new)"
    fi

    # 0wk.2 fix: truncate changed-files.txt - paired with the baseline, this
    # means a fresh approval starts a clean tracker. Closes 0wk.2.
    #
    # 3mg.2, load-bearing consequence (verified live): after this truncation a
    # recompute IN THIS CHECKOUT yields the EMPTY-LIST hash, never the approved
    # one. So the Stop hook's cross-worktree resolution can NOT re-derive an
    # approval by re-running --hash-only in the approving worktree; it must read
    # the persisted `impact-report-<tid>.json` (which survives approve and
    # carries both the approved hash and the approved file list). If you ever
    # make this truncation conditional, re-check that assumption first.
    truncate_changed_files_tracker

    # ---- SESSION STATE (gz3 ordering rule 3) ------------------------------
    # F3 + F4: clear active task and wipe per-iteration state. Still the LAST
    # side effects — if a previous step failed and rolled back we never reach
    # here, so a failed approval never wipes state — but now also strictly after
    # the tracking-state finalization above. Clearing current-task while a change
    # set was still visible made a concurrent Stop block with "No active Beads
    # task detected"; after the truncation there is nothing left to gate, so a
    # missing task id cannot produce a block.
    # Pass tid so wipe_iteration_state can clear the per-task counter
    # (Phase 4 fix pass / MATERIAL 5).
    clear_current_task
    wipe_iteration_state "$tid"

    # V3 (jio.1): the review round is over — drop its on-disk scratch files.
    # Deliberately NOT folded into wipe_iteration_state: that helper also runs
    # on `enter` and `choose continue`, and a continuing review round still
    # wants its request/artifact files on disk for the packet. Only a
    # COMPLETED approval ends the round. (Safe here: the review predicate reads
    # the durable Beads REVIEW-ARTIFACT records, never these files, so wiping
    # them cannot flip a concurrent Stop's review-discipline verdict.)
    wipe_review_artifacts "$tid"

    # Spec Phase A: build the rubric observation. The WARNING is the
    # loud signal the spec asks for when approve runs without a
    # satisfied verdict — the QA agent's prompt enforces the override
    # reason; we just surface the state.
    local rubric_obs=""
    if [ "$had_rubric_satisfied" = "1" ]; then
        # R2-F2: the claim is hash-checked now, not taken from the label.
        if [ "$rubric_mismatch" = "1" ]; then
            rubric_obs="; WARNING rubric-satisfied is set, but the satisfied verdict binds a DIFFERENT change set (graded=$rubric_graded_hash, approved=$approved_hash) — this approval covers work the grader did not see, so the approval comment must include an explicit override reason per spec Phase A / qa.md 6f; the mismatch is recorded in the approval record. To approve on a fresh verdict instead, re-run the rubric relay for the current change set"
        elif [ -z "$rubric_graded_hash" ]; then
            rubric_obs="; rubric-satisfied preserved (audit trail) — NOTE the verdict carries no change-set binding (pre-v4.1 record, or the hash was unavailable when it was recorded), so it could not be checked against this approval"
        else
            rubric_obs="; rubric-satisfied preserved (audit trail) and VERIFIED against this approval — the satisfied verdict binds the same change set (change_set_hash=$approved_hash)"
        fi
    elif [ "$had_rubric_pending" = "1" ]; then
        rubric_obs="; WARNING approving with rubric-pending still set (no satisfied verdict on file) — the QA approval comment must include an explicit override reason per spec Phase A; rubric-pending cleared as cycle ends"
    else
        rubric_obs="; no rubric labels present at approve (likely pre-Phase-A task)"
    fi

    # llh.18: surface whether the approval was bound to a change-set hash.
    local binding_obs
    if [ -n "$approved_hash" ]; then
        binding_obs="; change-set-bound approval record written (change_set_hash=$approved_hash) — verify-before-stop will release only while the current change-set matches this hash"
    else
        binding_obs="; WARNING approval comment written WITHOUT a change-set binding (hash unavailable) — verify-before-stop cannot match it; re-run approve once impact-report.sh is restored"
    fi

    # ${reconcile_obs:-} and ${reconstructed_obs:-} expand to empty when their
    # sentinel regions (TRACKER-RECONCILE / CHANGE-SET-RECONSTRUCTED) are stripped
    # by a META-TEST, keeping the stripped copy's envelope coherent.
    #
    # `removed qa-gate-entered=` and `removed qa-pending=` are PRESERVED VERBATIM
    # across the 8zi rewrite. Worth recording what that preservation is and is not
    # based on: a full-tree search for either literal (and for the shorter
    # `qa-gate-entered=` / `qa-pending=` forms) finds NO consumer anywhere —
    # not a spec, not a doc, not an agent prompt, not a hook. The only hits are
    # this line, the mirrored fixture copies of this script under
    # .claude/tests/e2e/fixtures/, and historical artifacts (grading-packet diffs,
    # mutation-run mutant dumps, one captured e2e transcript). They are kept
    # because keeping them is free and an operator may well be greping them from
    # memory; they are NOT kept because a test pins them. $sweep_obs is the token
    # that reports the FULL cleared set, which is what the counters cannot.
    #
    # claude-workflow-plugin-k6re R6-F2: routed through emit_approve_success
    # (APPROVE-SUCCESS-GATE, above cmd_approve) rather than a direct
    # emit_json call. On THIS path the internal --expect-hash check is
    # necessarily a no-op — EXPECTED-HASH-REFUSAL above already verified
    # expect_hash_arg against this same $approved_hash before any write in
    # this function ran, and nothing reassigns approved_hash afterward — but
    # calling the shared gate here anyway is what makes "every
    # status=approved exit checks this" true by construction rather than by
    # two authors each remembering to duplicate the check.
    emit_approve_success "$tid" "$approved_hash" "$expect_hash_arg" \
        "qa-approved set; removed qa-gate-entered=$removed_entered qa-pending=$removed_pending; summary recorded; current-task + iteration state cleared (escalation labels also cleared if present)$sweep_obs$rubric_obs${reconcile_obs:-}${reconstructed_obs:-}$impact_obs$review_obs${unrecorded_review_obs:-}${completion_obs:-}${design_satisfied_obs:-}$binding_obs${design_binding_obs:-}${review_file_binding_obs:-}${expect_hash_obs:-}$stale_label_obs"
}

# Phase 5 / E8: write a feedback-type memory entry when a block fires. The
# entry lives at ~/.claude/projects/<project-slug>/memory/qa-block-<fp>.md
# so subsequent sessions on the same project surface the pattern. Across
# repeats, the orchestrator can read these and pre-warn before delegating.
#
# The fingerprint is a short hash of the first 80 chars of the reason; the
# 60-char description is the first 60 chars truncated at a word boundary.
write_qa_block_memory() {
    local tid="$1"
    local reason="$2"
    local memory_dir
    # Derive the project slug the same way Claude Code does:
    # /Users/foo/Desktop/projects/bar -> -Users-foo-Desktop-projects-bar
    # The slug is the project path with `/` replaced by `-` and a leading `-`.
    local slug
    slug=$(printf '%s' "$PROJECT_DIR" | sed -e 's|/|-|g')
    memory_dir="$HOME/.claude/projects/${slug}/memory"

    mkdir -p "$memory_dir" 2>/dev/null || {
        log_sync_error "qa-block memory: mkdir $memory_dir failed; skipping write"
        return 1
    }

    # 1. Fingerprint: short SHA1 of the reason head. We use the first 80 chars
    #    so two blocks with the same root cause but different prose tails
    #    collapse to the same memory file (idempotent / dedup-friendly).
    local fp_input fp
    fp_input=$(printf '%s' "$reason" | head -c 80)
    if command -v shasum >/dev/null 2>&1; then
        fp=$(printf '%s' "$fp_input" | shasum -a 1 2>/dev/null | awk '{print $1}' | cut -c1-8)
    elif command -v sha1sum >/dev/null 2>&1; then
        fp=$(printf '%s' "$fp_input" | sha1sum 2>/dev/null | awk '{print $1}' | cut -c1-8)
    else
        # Last-resort fingerprint: tr/tail-based hex-ish slug.
        fp=$(printf '%s' "$fp_input" | tr -dc 'a-zA-Z0-9' | head -c 8)
    fi
    [ -z "$fp" ] && fp="unknown"

    # 2. Description: first 60 chars of reason, single line, no quotes.
    local desc
    desc=$(printf '%s' "$reason" | tr '\n' ' ' | tr -s ' ' | cut -c1-60 | sed -e 's/[[:space:]]*$//' -e 's/"/'"'"'/g')

    local memory_file="$memory_dir/qa-block-${fp}.md"

    # 3. Idempotent: if the file exists, refresh ONLY the trailing
    #    "Last seen: <ts>; Task: <id>" block. The body of the entry stays
    #    stable across re-blocks of the same pattern.
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ -f "$memory_file" ]; then
        # Append a "Last seen" line if the file does not already end with one
        # for this exact ts/tid pair.
        if ! grep -qF "Last seen: $ts; Task: $tid" "$memory_file" 2>/dev/null; then
            printf '\nLast seen: %s; Task: %s\n' "$ts" "$tid" >> "$memory_file" 2>/dev/null \
                || log_sync_error "qa-block memory: append to $memory_file failed"
        fi
        return 0
    fi

    # 4. New entry. Use the canonical feedback frontmatter shape per the
    #    auto-memory spec at the top of the system prompt.
    cat > "$memory_file" <<EOF
---
name: qa-block-${fp}
description: ${desc}
type: feedback
---

QA blocked task ${tid} for: ${reason}

Why: This pattern surfaced as a QA-gate block during the workflow. Recurring
matches indicate a systemic issue that should be checked before similar
future tasks are delegated.

How to apply: When working on similar future tasks (same domain, similar
diff shape), pre-check for this issue before declaring complete. If the
orchestrator opens a Beads task whose description or scope resembles the
block reason above, surface this memory entry as part of the delegation
brief.

First seen: ${ts}; Task: ${tid}
EOF

    if [ ! -s "$memory_file" ]; then
        log_sync_error "qa-block memory: write of $memory_file produced empty file"
        return 1
    fi

    # 5. Update MEMORY.md index. Idempotent — only add the line if not
    #    already present. Create MEMORY.md with a stub if it doesn't exist
    #    so the entry has a home.
    local index="$memory_dir/MEMORY.md"
    if [ ! -f "$index" ]; then
        cat > "$index" <<'EOF_INDEX'
# Memory Index

## Feedback

EOF_INDEX
    fi

    local index_line="- [qa-block-${fp}.md](qa-block-${fp}.md) - ${desc}"
    if ! grep -qF "qa-block-${fp}.md" "$index" 2>/dev/null; then
        # Try to insert under the "## Feedback" section if it exists; else
        # append.
        if grep -q '^## Feedback' "$index" 2>/dev/null; then
            # awk-based insert: print existing lines, and after the first
            # "## Feedback" header insert our line if not already present.
            if awk -v line="$index_line" '
                BEGIN{ inserted=0 }
                /^## Feedback/ && !inserted { print; print ""; print line; inserted=1; next }
                { print }
                END{ if (!inserted) print line }
            ' "$index" > "$index.tmp" 2>/dev/null; then
                mv "$index.tmp" "$index" 2>/dev/null \
                    || log_sync_error "qa-block memory: mv of awk output failed"
            else
                log_sync_error "qa-block memory: index update via awk failed; appending"
            fi
        else
            printf '\n%s\n' "$index_line" >> "$index"
        fi
    fi

    return 0
}

cmd_block() {
    local tid="$1"
    shift || true
    local reason="$*"
    if [ -z "$tid" ] || [ -z "$reason" ]; then
        usage
        exit 1
    fi
    require_bd "block" "$tid"

    # The same one transition approve uses, with a deliberately NARROW clear set.
    #
    # WHAT BLOCK CLEARS: qa-approved, and nothing else. WHAT IT PRESERVES, and why
    # each is a decision rather than an omission:
    #   - qa-gate-entered — documented contract ("Keeps qa-gate-entered") so the
    #     cycle stays open until an approve or an unblock-and-approve ends it.
    #   - qa-pending — the task IS still pending review; a block sends it back to
    #     the specialist and it returns for re-review.
    #   - rubric-pending, qa-escalated, qa-deferred — a block happens mid-cycle, so
    #     the rubric loop and any J21 escalation are still live. No filed defect
    #     says otherwise, and clearing them here would be an unrequested lifecycle
    #     change.
    # Only qa-approved is contradictory with a block, and that one is not cosmetic
    # the way 8zi's own direction is: every label reader in the tree tests
    # qa-approved FIRST (cmd_status, epic-gate.sh's qa_state_of, statusline.sh's
    # two readers), so a block that leaves a prior qa-approved in place reports the
    # task as APPROVED. That is the fail-open twin of the fail-closed noise 8zi
    # describes, and it is why block gets the sweep too rather than just approve.
    local -a block_clear=()
    # TERMINAL-LABEL-SWEEP BEGIN (8zi)
    block_clear+=(qa-approved)
    # TERMINAL-LABEL-SWEEP END (8zi)
    if ! set_terminal_label "$tid" "qa-blocked" "${block_clear[@]}"; then
        log_sync_error "block: the terminal-label transition FAILED for $tid; $TERMINAL_SWEEP_OBS"
        emit_json 0 "block" "$tid" "error" "failed to set qa-blocked: $TERMINAL_SWEEP_OBS"
        exit 3
    fi
    local block_sweep_obs=""
    if [ -n "$TERMINAL_SWEEP_REMOVED" ]; then
        block_sweep_obs="; cleared a prior cycle's [$TERMINAL_SWEEP_REMOVED] — a block and an approval cannot both be current"
    fi

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    add_comment "$tid" "QA-GATE BLOCKED at $ts: $reason"

    # E8: write a feedback memory entry. Best-effort — failures are logged
    # to sync-errors.log but never block the gate transition.
    local memory_obs="qa-block memory entry written"
    if ! write_qa_block_memory "$tid" "$reason"; then
        memory_obs="qa-block memory write failed (see sync-errors.log)"
    fi

    emit_json 1 "block" "$tid" "blocked" "qa-blocked label set at $ts (qa-gate-entered preserved if present); ${memory_obs}${block_sweep_obs}"
}

# Spec 0.2: record a J21 decision while qa-escalated. Signature is
# intentionally uniform across the four choices so callers don't have to
# branch on the choice in their shell:
#
#   choose approve   <task-id> <note>
#   choose continue  <task-id> <note>
#   choose tech-debt <task-id> <description> [severity] [file:line] [effort]
#   choose defer     <task-id> <note>
#
# Every choice:
#   - emits a comment "QA-GATE CHOICE <choice> at <ts>: <note>"
#   - drives the side effects spec'd in 0.2 (label flips, counter resets,
#     tech-debt entry, etc.)
#   - prints a JSON envelope to stdout via emit_json
#
# Keep this thin (principle 7): comments + labels are the record. Per-choice
# bookkeeping (counter wipe, escalation clear) reuses the existing helpers
# so behaviour stays in lockstep with approve/enter.
cmd_choose() {
    local choice="${1:-}"
    local tid="${2:-}"
    if [ -z "$choice" ] || [ -z "$tid" ]; then
        usage
        exit 1
    fi
    # Validate choice up front so a typo like `chose` doesn't silently
    # create a comment with garbage and no side effect.
    case "$choice" in
        approve|continue|tech-debt|defer) ;;
        *)
            printf 'qa-gate.sh: unknown choose value: %s (expected approve|continue|tech-debt|defer)\n' \
                "$choice" >&2
            usage
            exit 1
            ;;
    esac
    shift 2 || true

    # Collect the trailing args. For most choices this is just a single
    # note; for tech-debt we additionally accept severity, file:line, effort.
    local note="${1:-}"
    [ -z "$note" ] && { usage; exit 1; }
    shift || true
    local td_severity="${1:-medium}"
    local td_fileline="${2:-<unknown>}"
    local td_effort="${3:-unknown}"

    require_bd "choose" "$tid"

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    add_comment "$tid" "QA-GATE CHOICE $choice at $ts: $note"

    case "$choice" in
        approve)
            # Option 1: accept findings. Delegate to the existing atomic
            # approve flow so the rollback contract stays intact. The
            # approve flow itself clears escalation labels + iteration
            # state (see remove_escalation_labels above).
            cmd_approve "$tid" "$note"
            return $?
            ;;
        continue)
            # Option 2: re-enter the fix loop. Clear escalation, reset
            # iteration counter so the next Stop runs the suite from
            # scratch. We do NOT touch qa-pending here — the loop is
            # alive again, the cycle just starts at iteration 0.
            remove_escalation_labels "$tid"
            wipe_iteration_state "$tid"
            emit_json 1 "choose" "$tid" "continue" "choose continue at $ts: escalation labels cleared, iteration counter reset"
            ;;
        tech-debt)
            # Option 3: convert findings to deferred debt. Calls
            # tech-debt.sh add --bd-task; clears escalation; resets
            # counter. Best-effort on the tech-debt write — failure is
            # logged but does not prevent the label/counter side effects
            # (a stuck escalation is worse than a missing row).
            local td_script="$PROJECT_DIR/.claude/scripts/tech-debt.sh"
            local td_obs=""
            if [ -x "$td_script" ]; then
                if ! "$td_script" add "$td_severity" "$td_fileline" "$td_effort" "$note" --bd-task >/dev/null 2>&1; then
                    td_obs="tech-debt.sh add failed (see sync-errors.log); "
                    log_sync_error "choose tech-debt: tech-debt.sh add failed for $tid (severity=$td_severity fileline=$td_fileline)"
                fi
            else
                td_obs="tech-debt.sh missing or not executable; "
                log_sync_error "choose tech-debt: $td_script missing or not executable"
            fi
            remove_escalation_labels "$tid"
            wipe_iteration_state "$tid"
            emit_json 1 "choose" "$tid" "tech-debt" "${td_obs}choose tech-debt at $ts: tech-debt row queued + escalation cleared"
            ;;
        defer)
            # Option 4: stop iterating; surface to user. Set qa-deferred
            # so verify-before-stop allows the next Stop. Leave
            # qa-pending in place per spec — the task stays open, just
            # quiet, until the user acts. Counter is NOT reset here:
            # SessionStart can show "deferred at iteration N" usefully.
            local def_warn=""
            if ! add_label "$tid" "qa-deferred"; then
                def_warn=" WARNING: failed to add qa-deferred label; verify-before-stop may still block."
                log_sync_error "choose defer: failed to add qa-deferred label on $tid"
            fi
            emit_json 1 "choose" "$tid" "deferred" "choose defer at $ts: qa-deferred label set; qa-pending preserved; verify-before-stop will allow next Stop.$def_warn"
            ;;
    esac
}

# Spec Phase A: record a grader verdict.
#
# Input shape: strict JSON, read from `--file <path>` if provided, else
# stdin. The agent-facing contract is "paste the grader's JSON output",
# so both forms exist — file for scripting/replay, stdin for the natural
# pipe pattern (`grader_output | qa-gate.sh grade-record <tid>`).
#
# We deliberately keep this thin (principle 7): the Beads comment + label
# flip ARE the record. No internal state file is written; SessionStart and
# the QA agent's grading loop both read state from Beads. Malformed input
# is rejected with a STRUCTURED JSON error envelope (emit_error_json) so
# the agent can re-prompt the grader with precision — agent-centric error
# messages per bd-mcp conventions.
#
# Side effects:
#   - always: append a comment
#       "RUBRIC <rubric_version> iteration <n>: <verdict>[ change_set_hash=<h>]
#        — <summary>"
#     where <summary> is "all criteria pass" for satisfied, or a
#     comma-joined list of failed criterion names for needs_revision, and
#     change_set_hash (bjx) names the change set that was graded — the token
#     is omitted when the hash cannot be computed. See the composition site
#     for why the token sits between the verdict and the em-dash.
#   - on `satisfied`: remove rubric-pending; add rubric-satisfied.
#   - on `needs_revision`: labels unchanged. The qa-blocked round-trip is
#     the QA agent's move (it writes the block comment with required_fixes
#     and calls `qa-gate.sh block`); grade-record never sets qa-blocked.
cmd_grade_record() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        # Use stderr usage; emit a stdout JSON envelope for machine consumers.
        usage
        emit_error_json "grade-record" "" "missing_task_id" \
            "grade-record requires <task-id> as first positional argument" \
            "qa-gate.sh grade-record <task-id> [--file <path>]"
        exit 1
    fi
    shift || true

    # Parse optional --file flag. We do this manually (no getopts) to
    # match the shell-style of the rest of this script and so a typo
    # surfaces as a structured error rather than a getopts quirk.
    local input_path=""
    local graded_hash_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --file)
                input_path="${2:-}"
                if [ -z "$input_path" ]; then
                    emit_error_json "grade-record" "$tid" "missing_file_path" \
                        "--file requires a path argument" \
                        "qa-gate.sh grade-record $tid --file <path>"
                    exit 1
                fi
                shift 2 || true
                ;;
            --graded-hash)
                # R2-F1: the change set the grader ACTUALLY saw, taken from the
                # grading packet by the relay. See the binding block below for
                # why a recompute at record time is not the same thing.
                graded_hash_arg="${2:-}"
                if [ -z "$graded_hash_arg" ]; then
                    emit_error_json "grade-record" "$tid" "missing_graded_hash" \
                        "--graded-hash requires a value (the change_set_hash from the grading packet's impact report)" \
                        "qa-gate.sh grade-record $tid --graded-hash <hash>"
                    exit 1
                fi
                # Validated for the same reason rubric_version is: this value is
                # interpolated into the record's machine prefix, so anything
                # carrying a space could relocate a field boundary.
                case "$graded_hash_arg" in
                    *[!A-Za-z0-9-]*)
                        emit_error_json "grade-record" "$tid" "graded_hash_invalid_chars" \
                            "--graded-hash='$graded_hash_arg' contains characters outside [A-Za-z0-9-]; it is written into the RUBRIC record's machine prefix" \
                            "pass the change_set_hash verbatim from the grading packet's impact report"
                        exit 1
                        ;;
                esac
                shift 2 || true
                ;;
            -h|--help)
                usage
                exit 1
                ;;
            *)
                emit_error_json "grade-record" "$tid" "unknown_flag" \
                    "unknown argument: $1 (expected --file <path>, --graded-hash <hash>, or stdin)" \
                    "qa-gate.sh grade-record $tid [--file <path>] [--graded-hash <hash>]"
                exit 1
                ;;
        esac
    done

    require_bd "grade-record" "$tid"

    # Read the verdict JSON. --file takes precedence; stdin is the default.
    local raw=""
    if [ -n "$input_path" ]; then
        if [ ! -f "$input_path" ]; then
            emit_error_json "grade-record" "$tid" "file_not_found" \
                "verdict file does not exist: $input_path" \
                "qa-gate.sh grade-record $tid --file <existing-path>"
            exit 1
        fi
        if ! raw=$(cat -- "$input_path" 2>/dev/null); then
            emit_error_json "grade-record" "$tid" "file_unreadable" \
                "could not read verdict file: $input_path" \
                "qa-gate.sh grade-record $tid --file <readable-path>"
            exit 1
        fi
    else
        # Read all of stdin. tty detection: if stdin is a terminal, the
        # caller almost certainly forgot --file; bail with a helpful
        # message rather than hanging on a read.
        if [ -t 0 ]; then
            emit_error_json "grade-record" "$tid" "no_input" \
                "no --file given and stdin is a terminal; pipe the grader JSON or pass --file <path>" \
                "qa-gate.sh grade-record $tid --file <path>  OR  printf '%s' \"\$JSON\" | qa-gate.sh grade-record $tid"
            exit 1
        fi
        raw=$(cat)
    fi

    if [ -z "$raw" ]; then
        emit_error_json "grade-record" "$tid" "empty_input" \
            "verdict input is empty" \
            "qa-gate.sh grade-record $tid --file <path>  OR  stdin pipe"
        exit 1
    fi

    # Validate the JSON parses at all. jq -e exits 1 on parse error AND on
    # `false`/`null` result; we want the parse-error case only here, so we
    # short-circuit with a `type` check that returns a string for every
    # valid JSON value.
    if ! printf '%s' "$raw" | jq -e 'type' >/dev/null 2>&1; then
        emit_error_json "grade-record" "$tid" "invalid_json" \
            "verdict input is not valid JSON" \
            "expected a JSON object with keys verdict, criterion_results, required_fixes, iteration, rubric_version"
        exit 1
    fi

    # Top-level must be an object.
    local top_type
    top_type=$(printf '%s' "$raw" | jq -r 'type' 2>/dev/null || echo "unknown")
    if [ "$top_type" != "object" ]; then
        emit_error_json "grade-record" "$tid" "not_an_object" \
            "verdict input top-level is $top_type, expected object" \
            "expected a JSON object with keys verdict, criterion_results, required_fixes, iteration, rubric_version"
        exit 1
    fi

    # Validate each required key. We check existence + type per key so
    # the QA agent learns exactly what to fix. The error keys are stable
    # enough for the agent to branch on.
    local has_key
    for key in verdict criterion_results required_fixes iteration rubric_version; do
        has_key=$(printf '%s' "$raw" | jq -r --arg k "$key" 'has($k)' 2>/dev/null || echo "false")
        if [ "$has_key" != "true" ]; then
            emit_error_json "grade-record" "$tid" "missing_key:$key" \
                "verdict input missing required key: $key" \
                "required keys: verdict, criterion_results, required_fixes, iteration, rubric_version"
            exit 1
        fi
    done

    # verdict must be one of the two allowed strings.
    local verdict
    verdict=$(printf '%s' "$raw" | jq -r '.verdict' 2>/dev/null || echo "")
    case "$verdict" in
        satisfied|needs_revision) ;;
        *)
            emit_error_json "grade-record" "$tid" "verdict_invalid_enum" \
                "verdict='$verdict' is not in the allowed enum {satisfied, needs_revision}" \
                "set .verdict to either \"satisfied\" or \"needs_revision\""
            exit 1
            ;;
    esac

    # criterion_results must be an array of {criterion, pass, justification}.
    local cr_type
    cr_type=$(printf '%s' "$raw" | jq -r '.criterion_results | type' 2>/dev/null || echo "unknown")
    if [ "$cr_type" != "array" ]; then
        emit_error_json "grade-record" "$tid" "criterion_results_not_array" \
            "criterion_results is type=$cr_type, expected array" \
            "criterion_results must be an array of {criterion, pass, justification} objects"
        exit 1
    fi

    # Validate the per-item shape. We allow an empty array (a rubric with
    # zero criteria is degenerate but not corrupt). For non-empty arrays,
    # every element must be an object carrying criterion (string),
    # pass (boolean), justification (string).
    local cr_invalid
    cr_invalid=$(printf '%s' "$raw" | jq -r '
        .criterion_results
        | map(
            if type != "object" then "item_not_object"
            elif (has("criterion") and (.criterion | type == "string")) | not then "missing_or_bad_criterion"
            elif (has("pass") and (.pass | type == "boolean")) | not then "missing_or_bad_pass"
            elif (has("justification") and (.justification | type == "string")) | not then "missing_or_bad_justification"
            else "ok"
            end
        )
        | map(select(. != "ok"))
        | .[0] // ""
    ' 2>/dev/null || echo "")
    if [ -n "$cr_invalid" ]; then
        emit_error_json "grade-record" "$tid" "criterion_results_item_invalid:$cr_invalid" \
            "criterion_results contains an invalid item: $cr_invalid" \
            "every criterion_results item must be {criterion: string, pass: boolean, justification: string}"
        exit 1
    fi

    # required_fixes must be an array (may be empty).
    local rf_type
    rf_type=$(printf '%s' "$raw" | jq -r '.required_fixes | type' 2>/dev/null || echo "unknown")
    if [ "$rf_type" != "array" ]; then
        emit_error_json "grade-record" "$tid" "required_fixes_not_array" \
            "required_fixes is type=$rf_type, expected array" \
            "required_fixes must be an array (empty array allowed for satisfied)"
        exit 1
    fi

    # iteration must be a number, and — R2-F3 — an INTEGER one. The 0.2
    # escalation cap is still the agent's concern, not ours; the constraint here
    # is purely about the record grammar.
    #
    # It used to accept any JSON number and interpolate the raw value, while the
    # reader requires `[0-9]+` immediately followed by a colon. `1.5` therefore
    # produced a record the reader could not parse — and, before the selector
    # fix above, an unparseable LATEST record made the reader fall back to an
    # older one, so a needs_revision at iteration 1.5 failed to supersede the
    # satisfied verdict before it. Same lesson as rubric_version: the writer
    # must not be able to mint a record its own reader cannot read.
    #
    # This is the DEFENCE-IN-DEPTH half of R2-F3, not the fix. It stops the tool
    # creating unparseable records; it can do nothing about the ones it did not
    # create (legacy records, hand-written comments), which is why the selector
    # above had to change too. Verified in that order rather than assumed.
    local it_type it_val
    it_type=$(printf '%s' "$raw" | jq -r '.iteration | type' 2>/dev/null || echo "unknown")
    if [ "$it_type" != "number" ]; then
        emit_error_json "grade-record" "$tid" "iteration_not_number" \
            "iteration is type=$it_type, expected number" \
            "iteration must be a JSON number (1, 2, 3, ...)"
        exit 1
    fi
    it_val=$(printf '%s' "$raw" | jq -r '.iteration' 2>/dev/null || echo "?")
    case "$it_val" in
        ''|*[!0-9]*)
            emit_error_json "grade-record" "$tid" "iteration_not_integer" \
                "iteration=$it_val is not a non-negative integer; it is interpolated into the RUBRIC record's machine prefix, which the reader parses as [0-9]+ followed immediately by a colon — a value like 1.5 or 1e3 writes a record that cannot be read back and so cannot supersede an earlier verdict" \
                "iteration must be a non-negative integer (1, 2, 3, ...)"
            exit 1
            ;;
    esac

    # rubric_version must be a non-empty string.
    local rv_type rv_val
    rv_type=$(printf '%s' "$raw" | jq -r '.rubric_version | type' 2>/dev/null || echo "unknown")
    if [ "$rv_type" != "string" ]; then
        emit_error_json "grade-record" "$tid" "rubric_version_not_string" \
            "rubric_version is type=$rv_type, expected string" \
            "rubric_version must be a string (e.g. \"v1\")"
        exit 1
    fi
    rv_val=$(printf '%s' "$raw" | jq -r '.rubric_version' 2>/dev/null || echo "")
    if [ -z "$rv_val" ]; then
        emit_error_json "grade-record" "$tid" "rubric_version_empty" \
            "rubric_version is the empty string" \
            "rubric_version must be a non-empty string (e.g. \"v1\")"
        exit 1
    fi

    # bjx: rubric_version is the ONLY machine-prefix field of the RUBRIC record
    # that came from the grader, and it is interpolated with a space on each
    # side. Validated merely as "non-empty string" it was a GRAMMAR INJECTION:
    # the reader parses the verdict from immediately after the record's first
    # colon, so a version of the form
    #     1 iteration 1: satisfied change_set_hash=<the real current hash>
    # relocated that colon into the injected text, and a needs_revision verdict
    # was read back as satisfied AND bound to the current change set — enough to
    # carry a rubric-satisfied label across a re-enter that should have cleared
    # it. Reproduced end-to-end with a causation control (only the version
    # differed) and pinned in section I of
    # .claude/tests/component/specs/rubric-binding.sh.
    #
    # The class below has no space and no colon, so no value that passes here
    # can move a field boundary. It is deliberately the WRITER's job: the reader
    # cannot distinguish an injected prefix from a real one after the fact, so a
    # reader-only class would narrow the grammar without closing anything. The
    # reader carries the SAME class for parity (latest_satisfied_rubric_hash),
    # and section F asserts the two spellings match.
    #
    # Rejecting rather than sanitising: a silently-rewritten version would make
    # the record disagree with the verdict JSON the grader actually emitted,
    # and the structured envelope is what lets the orchestrator re-prompt with
    # precision (spec Phase A).
    case "$rv_val" in
        *[!A-Za-z0-9._+-]*)
            emit_error_json "grade-record" "$tid" "rubric_version_invalid_chars" \
                "rubric_version='$rv_val' contains characters outside [A-Za-z0-9._+-]; it is interpolated into the RUBRIC record's machine prefix, where a space or a colon would move a field boundary and let the recorded verdict be read back as a different one" \
                "rubric_version must match ^[A-Za-z0-9._+-]+$ (e.g. \"1\", \"v1\", \"1.2\")"
            exit 1
            ;;
    esac

    # Build the one-line summary. For satisfied, the summary is the fixed
    # "all criteria pass" string. For needs_revision, we list the criterion
    # names whose pass is false; if the grader marked needs_revision without
    # any failing criteria (degenerate but not corrupt), we fall back to
    # the required_fixes count.
    local summary
    if [ "$verdict" = "satisfied" ]; then
        summary="all criteria pass"
    else
        # Comma-join the failed criterion names. Defensive: if no failures
        # were listed, use the required_fixes count as a hint.
        local failed_names
        failed_names=$(printf '%s' "$raw" \
            | jq -r '[.criterion_results[] | select(.pass == false) | .criterion] | join(", ")' \
            2>/dev/null || echo "")
        if [ -n "$failed_names" ]; then
            summary="failed: $failed_names"
        else
            local rf_count
            rf_count=$(printf '%s' "$raw" | jq -r '.required_fixes | length' 2>/dev/null || echo "0")
            summary="needs_revision (no failing criteria listed; required_fixes count=$rf_count)"
        fi
    fi

    # Compose and post the comment. Format matches the spec exactly:
    # RUBRIC <rubric_version> iteration <n>: <verdict>[ change_set_hash=<h>] — <summary>
    #
    # bjx (v4.1 U1): the verdict now names the CHANGE SET it graded. A verdict
    # is an opinion about a specific diff, and the only durable statement of
    # which diff that was is this token — the same binding llh.18 put on the
    # approval record and jio.1 put on the review artifact (`reviewed_hash`).
    # `enter` reads it back (latest_satisfied_rubric_hash) to tell a verdict
    # that still covers the current work from one left over from a previous
    # change set; before it existed, `enter` could only assume the latter and
    # cleared rubric-satisfied unconditionally.
    #
    # PLACEMENT is a compatibility contract, and the same one cmd_approve
    # documents for its own record: the machine token goes AFTER the verdict
    # and BEFORE the em-dash, i.e. ahead of all free text. Every existing
    # reader keys on the prefix through the verdict — qa.md 6c's
    # `test("^RUBRIC [0-9]+ iteration")`, the L1 spec's
    # `^RUBRIC v1 iteration 1: satisfied`, rubric-loop.sh's
    # `RUBRIC 1 iteration 1: needs_revision` — so appending here leaves all of
    # them matching, while putting it after the summary would bury a machine
    # field inside grader-authored prose.
    #
    # Recorded on BOTH verdicts, not just satisfied: "which change set was
    # found wanting" is exactly as much of an audit question as "which one
    # passed", and the reader filters on the verdict itself.
    #
    # Best-effort, mirroring approve's hash_field: an unavailable hash omits
    # the token rather than writing a placeholder, because a token that does
    # not name a real change set would read as a binding to something. The
    # unbound record then behaves precisely as a pre-bjx one does — enter
    # cannot prove it covers the current work, so it clears.
    #
    # bjx: "unavailable" has TWO spellings. impact-report.sh returns empty when
    # it cannot run at all, and the CONSTANT $CHANGE_SET_HASH_UNAVAILABLE when
    # it runs on a host carrying neither shasum nor sha256sum. Only the first
    # was excluded by `[ -n ... ]`; the second is a non-empty string that would
    # be recorded as a binding and then compare EQUAL to itself at enter time,
    # preserving every verdict unconditionally on such a host. Both spellings
    # omit the token, which is what the paragraph above already promised.
    #
    # R2-F1 — WHERE THE HASH COMES FROM, which is the whole meaning of the
    # token. This used to be a live recompute of the tracker AT RECORD TIME.
    # That is not "the change set that was graded": grade-record runs after QA
    # assembled the packet and after the grader ran, so any path that landed in
    # between was silently folded into the binding. A verdict for set A was
    # recorded as covering A+B. Reproduced directly — packet hash 8685efdc,
    # record bound to e7bfaafe — and it is NOT the documented path-scoped
    # limitation: that one is about contents, this one leaked whole PATHS into
    # a verdict that never saw them.
    #
    # Three sources, in descending order of authority:
    #
    #   1. --graded-hash, passed by the relay from the grading packet's impact
    #      report (orchestrator.md 5a step C). This is the only value that
    #      actually witnesses what the grader was shown, so it wins outright.
    #      It cannot come from the grader's own JSON: that would let the graded
    #      party state what it graded, and it would change grader.md's schema.
    #
    #   2. A live recompute CORROBORATED by the persisted impact report. If the
    #      report the packet was built from still describes the current change
    #      set, then nothing was added between assembly and now, and the live
    #      value is the graded one. This is what makes the flag optional without
    #      making it a lie — the common relay, where nothing moves, still binds.
    #
    #   3. Nothing. If they DISAGREE, the change set moved and we cannot say
    #      which set was graded, so the record is written UNBOUND with the two
    #      hashes named. Unbound is not a failure mode: enter treats it as
    #      stale and clears, i.e. the pre-bjx behaviour, and approve's
    #      cross-check (R2-F2) has nothing to contradict.
    #
    # Note what case 2 still cannot see: if the persisted report was itself
    # REGENERATED after the packet was assembled (an `enter` between steps C
    # and D does exactly that), it agrees with live while describing a set the
    # grader never saw. That residual is why R2-F2's cross-check at approve
    # exists — the two findings are one gap at two ends, and only the flag
    # closes it at this end. The relay passes the flag; the fallback keeps an
    # un-updated caller honest rather than silently wrong.
    local graded_hash="" hash_token="" binding_source=""
    if [ -n "$graded_hash_arg" ]; then
        graded_hash="$graded_hash_arg"
        binding_source="--graded-hash supplied by the relay (the grading packet's change set)"
    else
        local live_hash="" persisted_hash=""
        live_hash=$(compute_change_set_hash) || live_hash=""
        persisted_hash=$(persisted_report_hash "$tid") || persisted_hash=""
        if [ -n "$live_hash" ] && [ "$live_hash" = "$persisted_hash" ]; then
            graded_hash="$live_hash"
            binding_source="live recompute, corroborated by the persisted impact report (no path moved since the report the packet was built from)"
        else
            binding_source="none — the live change set (${live_hash:-<unavailable>}) and the persisted impact report (${persisted_hash:-<absent>}) disagree, so which set was graded cannot be established here; pass --graded-hash from the grading packet to bind it"
        fi
    fi
    if [ "$graded_hash" = "$CHANGE_SET_HASH_UNAVAILABLE" ]; then
        graded_hash=""
        binding_source="none — the change-set hash is unavailable on this host (no shasum/sha256sum)"
    fi
    if [ -n "$graded_hash" ]; then
        hash_token=" change_set_hash=$graded_hash"
    fi
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local comment_text
    comment_text="RUBRIC $rv_val iteration $it_val: $verdict$hash_token — $summary"
    add_comment "$tid" "$comment_text"

    # Label flip on satisfied. needs_revision leaves labels alone.
    local label_obs=""
    if [ "$verdict" = "satisfied" ]; then
        # Best-effort: remove rubric-pending and add rubric-satisfied.
        # We surface any individual failures in the observations so the
        # agent can re-run, but we don't roll back the comment — the
        # comment is the audit trail and is the source of truth even
        # if the label flip races.
        local removed_pending=1 added_satisfied=1
        remove_rubric_pending "$tid" || removed_pending=0
        if ! add_label "$tid" "rubric-satisfied"; then
            added_satisfied=0
            log_sync_error "grade-record: failed to add rubric-satisfied label on $tid"
        fi
        label_obs="rubric-pending removed=$removed_pending; rubric-satisfied added=$added_satisfied"
    else
        label_obs="labels unchanged (qa-blocked round-trip is the QA agent's move)"
    fi

    # bjx: name the binding (or its absence) in the envelope. An unbound
    # verdict is not an error — it is a verdict `enter` will not be able to
    # carry across a re-entry, and the operator should be able to see that
    # from the record-writing call rather than from a later surprise.
    local binding_obs
    if [ -n "$graded_hash" ]; then
        binding_obs="; verdict bound to the graded change set (change_set_hash=$graded_hash; source: $binding_source)"
    else
        binding_obs="; WARNING verdict recorded WITHOUT a change-set binding (source: $binding_source) — a re-enter cannot prove this verdict covers the current work, so rubric-satisfied will be cleared as stale and the next relay round will re-grade"
    fi

    emit_json 1 "grade-record" "$tid" "$verdict" \
        "comment posted at $ts: $comment_text; $label_obs$binding_obs"
}

# ---------------------------------------------------------------------------
# Phase V2 (1vq.1): reviewer-record writers. These append the LOAD-BEARING
# review record grammars (byte-exact V3 contracts) as Beads comments. They are
# record writers ONLY — no approve/Stop enforcement lives here (that is V3).
# Validation is delegated to review-check.sh (the ONE validator); this file
# never re-implements the schema and never references any reviewer transport.

# ---------------------------------------------------------------------------
# REVIEW-ARTIFACT CANONICAL PATH (v5 D2 / claude-workflow-plugin-rqer).
#
# WHY THIS EXISTS. Before this, the external reviewer driver and Claude's own
# in-session review both wrote the review artifact into .claude/.qa-tracking/, which
# wipe_review_artifacts (above) deletes on every COMPLETED approve — by
# design, per its own header — and which workflow_self_written
# (workflow-denylist.sh:265) excludes from the change set. So the artifact
# never outlived a review cycle and no approval ever attested to it (the
# operator directive on this task's Beads record: "an artifact outside the
# change set is an artifact no approval attests to"). This block gives the
# artifact a SECOND, DURABLE home: a committed, task-derived path OUTSIDE
# .claude/.qa-tracking/, so it survives approve and enters the change set —
# deliberately the SAME shape as a design artifact (see DESIGN_SPEC_SUBDIR /
# design_artifact_path_for / design_path_is_contained below; this block
# mirrors all three).
#
# THE PATH IS DERIVED, NEVER SUPPLIED. cmd_review_record's --file, if given,
# must ASSERT this derivation rather than name arbitrary bytes — see its
# artifact_path_not_derived refusal, which mirrors design-record's exactly.
#
# KEYED ON (task id, iteration), not task id alone: a review has MANY rounds
# (review-artifact-<tid>-r1.json, -r2.json, ...), unlike a design's single
# artifact. The iteration is read from the artifact's OWN `iterations` field
# (schema-checked by review-check.sh's validate-artifact by the time this
# runs — KEY PRESENCE always, and, as of claude-workflow-plugin-k6re R11-F1,
# TYPE (must be a JSON number) and FORMAT (its string form must match
# ^[0-9]+$) too, closing the exact gap this comment used to flag: an
# unparseable `iterations` value used to be accepted here and then poison
# the REVIEW-ARTIFACT selector in review-check.sh permanently, since bd
# comments are append-only and no later record could ever clear the
# resulting refusal) rather than a second CLI argument, so there is exactly
# one source of truth for "which round is this". The path derivation below
# does not rely on that guarantee alone, though: the SAME sanitisation that
# makes the task id safe to interpolate into a path makes an `iterations`
# value safe too, REGARDLESS of what validate-artifact does or does not
# check -- `tr -c 'A-Za-z0-9._-' '_'` cannot emit a slash, so neither input
# can carry a `..` segment, an intermediate directory, or a newline into the
# derived path. Belt and suspenders: the type/format guard stops a bad
# record from ever being WRITTEN; this sanitisation independently stops a
# bad value from ever corrupting the PATH, and neither depends on the other.
#
# The external reviewer driver writes here directly now (no
# .claude/.qa-tracking hand-off copy) and its own path computation MUST match
# this format string byte for byte — pinned against drift by the driver's own
# review-recording component spec under .claude/tests/component/specs/ — its
# art_path() helper independently re-derives this same path and asserts a
# file does/does not exist there across its C1-C9 legs (R1-F3, QA round 1:
# this comment previously cited review-artifact-durability.sh's Leg A, which
# drives the CLAUDE lane through cmd_review_record over stdin and never
# invokes the external driver at all, so it cannot pin the DRIVER's own path
# computation — only that component spec drives the driver).
REVIEW_ARTIFACT_SUBDIR="docs/reviews"

# review_artifact_path_for <tid> <iteration> — the ONE derivation of the
# review artifact path from (task id, iteration). Same sanitisation as
# impact_report_path_for / completion_payload_path_for / design_artifact_path_for.
review_artifact_path_for() {
    local sanitized iter_sanitized
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    iter_sanitized=$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/%s/%s-r%s.json' "$PROJECT_DIR" "$REVIEW_ARTIFACT_SUBDIR" "$sanitized" "$iter_sanitized"
}

# review_dir_is_review_subdir <path> — 0 when <path>'s PARENT DIRECTORY,
# resolved PHYSICALLY, IS the declared review-artifact directory. THE SHARED
# CORE, mirroring design_dir_is_spec_dir byte for byte (same `cd -P`
# discipline — see its own comment above for why bare `cd` is wrong here:
# LOGICAL mode collapses `..` LEXICALLY, so a directory symlink can make the
# predicate answer for the SPELLING while the kernel opens a different
# parent).
review_dir_is_review_subdir() (
    local p="${1:-}" here
    [ -n "$p" ] || return 1
    case "$p" in /*) ;; *) p="$PROJECT_DIR/$p" ;; esac
    while [ "${p%/}" != "$p" ] && [ -n "${p%/}" ]; do p="${p%/}"; done
    p="${p%/*}"
    [ -n "$p" ] || p="/"
    cd -P "$p" 2>/dev/null || return 1
    here="$PWD"
    cd -P "$PROJECT_DIR/$REVIEW_ARTIFACT_SUBDIR" 2>/dev/null || return 1
    [ "$here" = "$PWD" ]
)

# review_path_is_contained <path> — 0 when <path>'s FINAL TARGET sits DIRECTLY
# in the declared review-artifact directory. Mirrors design_path_is_contained's
# bounded, `-ef`-checked symlink walk byte for byte (see its comment for the
# R3-F3 rationale: `readlink`'s output is the one command substitution here,
# and `-ef` is what makes the reconstruction honest rather than trusting a
# possibly-truncated read-back). Never fails the caller: an unresolvable path,
# a symlink loop, and an empty argument are all "not contained".
review_path_is_contained() {
    local p="${1:-}" hops=0 target prev
    [ -n "$p" ] || return 1
    case "$p" in /*) ;; *) p="$PROJECT_DIR/$p" ;; esac
    while [ -L "$p" ]; do
        [ "$hops" -lt 40 ] || return 1
        target=$(readlink "$p" 2>/dev/null) || target=""
        [ -n "$target" ] || return 1
        prev="$p"
        case "$target" in
            /*) p="$target" ;;
            *)  p="${p%/*}/$target" ;;
        esac
        [ "$prev" -ef "$p" ] || return 1
        hops=$((hops + 1))
    done
    review_dir_is_review_subdir "$p"
}

# finding_id_in_latest_artifact <tid> <finding-id> -> 0 if the id appears in the
# findings=[...] token of the LATEST /^REVIEW-ARTIFACT v1 / comment.
#
# "LATEST" here is still `tail -1` (last in bd's comment order), NOT the
# review-check.sh cmd_gate K3 selector (highest iteration AND latest
# timestamp, refusing on disagreement — see that file's ART-ITERATION-SELECT
# comment). That is a real, separate gap this function inherits rather than
# closes: claude-workflow-plugin-k6re R3-F1 is a fix to the PARSE BOUNDARY
# (which characters of a firstline are a machine token vs. free-text
# summary), not to WHICH firstline governs when several exist. Unifying the
# two selectors is a larger change than this fix and is out of scope here;
# noted so a future pass does not assume this function already matches
# cmd_gate's selection semantics.
finding_id_in_latest_artifact() {
    local tid="$1" fid="$2"
    local comments art token art_prefix
    # ART-FIRSTLINE-GUARD (claude-workflow-plugin-k6re R4-F1, independent
    # review round 4). Each comment is reduced to its FIRST LINE
    # (`split("\n")[0]`) before anything below ever looks for a
    # `^REVIEW-ARTIFACT v1 ` candidate -- the exact technique
    # review-check.sh's cmd_gate uses to build $firstlines (see that
    # file's "First line of each comment" comment, right above its own
    # `jq -r '.[] | split("\n")[0]'` call, and normalize_comments()).
    #
    # THE DEFECT THIS CLOSES. The pre-R4-F1 jq filter here
    # (`(.[]?.text // empty)`) emitted each comment's RAW text with every
    # embedded newline intact -- `-r` only strips the JSON string's
    # surrounding quotes, it does not collapse interior "\n" bytes. Once
    # that raw, still-multi-line text was flattened through `printf '%s\n'
    # "$comments" | grep -E '^REVIEW-ARTIFACT v1 '` (below), each embedded
    # line became its OWN independent grep candidate, indistinguishable
    # from a genuine top-level record. MEASURED: a comment whose own
    # free-text SUMMARY continues past a literal newline into something
    # shaped like a second, well-formed-looking REVIEW-ARTIFACT firstline
    # -- `... findings=[R4-F1:high] ... at <ts>: real record` followed by
    # `REVIEW-ARTIFACT v1 iteration=999 ... findings=[R9-F9:high] ... at
    # <ts2>: injected line` on the next line -- made `tail -1` (last
    # MATCHING LINE in the flattened stream, not last COMMENT) select the
    # injected line over the genuine record that opened the very same
    # comment; ART_PREFIX then sliced that already-wrong selection and
    # reported R9-F9, never R4-F1. ART_PREFIX (R3-F1) polices which BYTES
    # of the winning LINE are a machine token vs. free-text summary; it has
    # no way to notice the winning line was never a top-level record to
    # begin with, because by the time it runs the substitution has already
    # happened.
    #
    # WHY MIRRORED, NOT SHARED. Shelling out to `review-check.sh gate`
    # would additionally import its FULL K3 selector (highest well-formed
    # iteration= AND latest well-formed timestamp, refusing on
    # disagreement -- review-check.sh's ART-ITERATION-SELECT) in place of
    # THIS function's deliberately different "last in comment order"
    # selection -- a gap this function's own header comment (above)
    # already documents as intentional and separately tracked. Importing
    # that selector here would flip claude-workflow-plugin-fkm.1.1 from
    # "resolve-finding reads the tail-1 record" to "refuses with
    # review_artifact_selection_disagreement", a behaviour change well
    # outside R4-F1's scope. So only the narrow, self-contained piece
    # R4-F1 actually needs -- reduce each comment to its first line before
    # pattern-matching -- is mirrored here by hand, the same discipline
    # already used for art_prefix_len() below (see ART-PREFIX-GUARD) and
    # for the RUBRIC / QA-GATE APPROVED capture patterns shared between
    # qa-gate.sh and verify-before-stop.sh.
    #
    # SIBLING SURVEY (asked for at R4-F1): RUBRIC, COMPLETION,
    # DESIGN-REVIEW, DESIGN-CONFLICT, DESIGN-ARTIFACT and GRILLING all
    # already read via `select(startswith(...))` / an anchored `^`
    # `test()`/`capture()` applied to the whole (un-split) comment text --
    # since jq's `^`/`$` are STRING-anchored with no `m` flag, that is
    # already equivalent to first-line-only for a per-comment `.text`
    # stream, so none of them share this defect. IMPLEMENTER, RESOLVED and
    # ARBITRATION have NO selector of their own in this file or
    # verify-before-stop.sh at all (both are write-only here; the only
    # readers are review-check.sh's, already reading through $firstlines).
    # QA-GATE APPROVED's four readers (this file's
    # recorded_approval_hashes; verify-before-stop.sh's
    # task_has_matching_approval_record, matching_approval_record_text and
    # try_worktree_resolution) USED TO BE all UNANCHORED
    # `select(test("QA-GATE APPROVED .*change_set_hash="))` over the whole
    # un-split text, sharing the multi-line-selection half of this shape --
    # measured directly (a comment whose first line is prose and whose
    # second line is a fabricated record extracted the fabricated hash) --
    # NOT fixed in this round (different files, different call sites, the
    # Stop-hook release gate itself and its cross-worktree bridge; reported
    # for follow-up instead, per the evidence-before-fix discipline of one
    # variable at a time — the full survey is on this task's own comment
    # stream, cross-linked to claude-workflow-plugin-yrij).
    #
    # FIXED, same task (claude-workflow-plugin-yrij, APPROVAL-SELECTOR-
    # ANCHOR): all four now anchor `select(test("^QA-GATE APPROVED
    # .*change_set_hash="))` at `^` -- see task_has_matching_approval_record
    # in verify-before-stop.sh for the full rationale, the anchor-vs-split
    # measurement, and the accepted-boundary scope note (a fully standalone,
    # well-formed forged comment is not and cannot be closed by an anchor).
    # This function's OWN selector (art_prefix_len, just below) is a
    # DIFFERENT shape -- REVIEW-ARTIFACT, not QA-GATE APPROVED -- and was
    # already fixed at R3-F1/R4-F1; it is unaffected by and unrelated to the
    # yrij fix, restated here only because this comment block is where the
    # four-reader survey was first written down.
    comments=$(bd_show_with_comments "$tid" \
        | jq -r 'if type=="array" then .[0].comments else .comments end | (.[]?.text // empty) | split("\n")[0]' 2>/dev/null || echo "")
    art=$(printf '%s\n' "$comments" | grep -E '^REVIEW-ARTIFACT v1 ' | tail -1 || true)
    [ -z "$art" ] && return 1
    # ART-PREFIX-GUARD (claude-workflow-plugin-k6re R3-F1). The SAME
    # anchored, end-to-end grammar review-check.sh's cmd_gate applies to a
    # REVIEW-ARTIFACT firstline (see that file's ART-PARSE-SHARED comment
    # for the full defect and the two measured reproductions), mirrored
    # here rather than shared: this function does its own independent read
    # of the comment stream instead of shelling out to review-check.sh, so
    # there is no single implementation to call into. Kept byte-consistent
    # by hand with review-check.sh's art_prefix_len() -- the same
    # discipline this codebase already uses for the RUBRIC / QA-GATE
    # APPROVED capture patterns shared between qa-gate.sh and
    # verify-before-stop.sh (see recorded_approval_hashes()'s own comment:
    # "The parity is asserted textually... in approve-idempotency.sh").
    #
    # WHY THIS WAS NEEDED: the pre-R3-F1 line here was `sed -nE
    # 's/.*findings=\[([^]]*)\].*/\1/p'` applied to the WHOLE $art string --
    # byte-identical to the defect in review-check.sh's own ART_FINDINGS
    # extraction, and vulnerable to the identical two reproductions: a
    # malformed record whose bracket swallows a real, later token, and a
    # perfectly well-formed record whose free-text summary merely mentions
    # `findings=[...]`. Both would previously make `token` read back the
    # WRONG (or empty) value here, silently letting resolve-finding /
    # arbitrate accept a finding id that was never really open, or reject
    # one that was.
    art_prefix=$(LC_ALL=C awk -v ART_SOFT='( reviewer=[A-Za-z0-9._-]+)?( model=[]A-Za-z0-9._:/[-]+)?( pin=[]A-Za-z0-9._:/[-]+)?( reviewed_hash=[A-Za-z0-9._-]+)?( risk_threshold=[A-Za-z0-9_]+)?( verdict=[A-Za-z]+)?( stopped_by=[A-Za-z0-9_:]+)?' '
        function art_prefix_len(line,    re, n) {
            re = "^REVIEW-ARTIFACT v1 iteration=[0-9]+" ART_SOFT \
                 " findings=\\[[^][:space:]]*\\]( artifact_hash=[A-Za-z0-9._-]+)?" \
                 " at [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z: "
            n = match(line, re)
            return (n == 1) ? RLENGTH : 0
        }
        { n = art_prefix_len($0); if (n > 0) print substr($0, 1, n) }
    ' <<<"$art" 2>/dev/null) || true
    # claude-workflow-plugin-k6re R17 class sweep: `|| true` added for
    # consistency with this function's own `comments=`/`art=` assignments a
    # few lines above (both already guarded) and defensively rather than in
    # response to a reproduced failure — `$art` is free-text pulled straight
    # from a bd comment, not JSON review-check.sh has already validated the
    # way the review-record/-reconcile/completion-record functions' `$raw`
    # is, so this awk invocation does not get the same "provably safe"
    # argument the census gives those. awk's own match()/substr() do not
    # error on non-matching input (a static, well-formed program simply
    # prints nothing), so no failure mode was found here — but the class
    # this whole sweep exists to close is exactly "not yet been shown to
    # fail" standing in for "cannot fail", so it is guarded rather than left
    # to make that argument implicitly. SEPARATELY (R19-F1 re-audit): this
    # whole function (`finding_id_in_latest_artifact`) is called directly by
    # both of its callers as `if ! finding_id_in_latest_artifact ...; then`
    # — an exempt context that would transitively protect this line's own
    # body regardless, the same reasoning as `has_label`'s (see its own
    # comment) — so even an awk failure here would not currently reach
    # either caller. Both reasons are independent; neither depends on the
    # other.
    [ -z "$art_prefix" ] && return 1
    token=$(printf '%s' "$art_prefix" | sed -nE 's/.*findings=\[([^]]*)\].*/\1/p' || true)
    [ -z "$token" ] && return 1
    # One id per line (strip the :severity and any intra-token spaces). Use
    # sed (line-oriented) NOT `tr -d` so the per-id newlines survive — merging
    # the ids onto one line would make the exact-match grep below never hit.
    printf '%s' "$token" | tr ',' '\n' | sed -E 's/:.*//; s/[[:space:]]//g' | grep -qxF "$fid"
}

# review-record <tid> [--file <path>]: validate an artifact via review-check.sh
# then post the REVIEW-ARTIFACT v1 record comment. Mirrors grade-record's shape.
cmd_review_record() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "review-record" "" "missing_task_id" \
            "review-record requires <task-id> as first positional argument" \
            "qa-gate.sh review-record <task-id> [--file <path>]"
        exit 1
    fi
    shift || true

    local input_path=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --file)
                input_path="${2:-}"
                if [ -z "$input_path" ]; then
                    emit_error_json "review-record" "$tid" "missing_file_path" \
                        "--file requires a path argument" \
                        "qa-gate.sh review-record $tid --file <path>"
                    exit 1
                fi
                shift 2 || true
                ;;
            -h|--help) usage; exit 1 ;;
            *)
                emit_error_json "review-record" "$tid" "unknown_flag" \
                    "unknown argument: $1 (expected --file <path> or stdin)" \
                    "qa-gate.sh review-record $tid [--file <path>]"
                exit 1
                ;;
        esac
    done

    require_bd "review-record" "$tid"

    local raw=""
    if [ -n "$input_path" ]; then
        if [ ! -f "$input_path" ]; then
            emit_error_json "review-record" "$tid" "file_not_found" \
                "artifact file does not exist: $input_path" \
                "qa-gate.sh review-record $tid --file <existing-path>"
            exit 1
        fi
        if ! raw=$(cat -- "$input_path" 2>/dev/null); then
            emit_error_json "review-record" "$tid" "file_unreadable" \
                "could not read artifact file: $input_path" \
                "qa-gate.sh review-record $tid --file <readable-path>"
            exit 1
        fi
    else
        if [ -t 0 ]; then
            emit_error_json "review-record" "$tid" "no_input" \
                "no --file given and stdin is a terminal; pipe the artifact JSON or pass --file <path>" \
                "qa-gate.sh review-record $tid --file <path>  OR  printf '%s' \"\$JSON\" | qa-gate.sh review-record $tid"
            exit 1
        fi
        raw=$(cat)
    fi

    if [ -z "$raw" ]; then
        emit_error_json "review-record" "$tid" "empty_input" \
            "artifact input is empty" \
            "qa-gate.sh review-record $tid --file <path>  OR  stdin pipe"
        exit 1
    fi

    # Validate via the ONE validator (subprocess). No second schema here.
    local tmpf vout ok ekey
    tmpf=$(mktemp -t qa-gate-review.XXXXXX 2>/dev/null) || tmpf="$QA_TRACKING_DIR/.review-record-$$.json"
    printf '%s' "$raw" > "$tmpf"
    vout=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" validate-artifact "$tmpf" 2>/dev/null || true)
    rm -f "$tmpf" 2>/dev/null || true
    ok=$(printf '%s' "$vout" | jq -r '.ok // false' 2>/dev/null || echo "false")
    if [ "$ok" != "true" ]; then
        ekey=$(printf '%s' "$vout" | jq -r '.error_key // "invalid_artifact"' 2>/dev/null || echo "invalid_artifact")
        emit_error_json "review-record" "$tid" "$ekey" \
            "artifact failed validation via review-check.sh: $ekey" \
            "provide a valid review artifact (see review-check.sh validate-artifact schema)"
        exit 1
    fi

    # --- THE DECOY-ARTIFACT CHECK (claude-workflow-plugin-wob2 RRV) --------
    # completion-record documents this exact shape for its own payload (see
    # its own "THE DECOY-PAYLOAD CHECK" comment, below in this file): an
    # artifact whose OWN task_id names a different task is cheaper to refuse
    # here than to reason about later — the record would claim to review
    # task A's change set while sitting on task B, and approve's binding
    # would attest to the wrong task entirely. Both sibling recorders
    # (completion-record, design-record) already have this check; this one
    # was simply omitted.
    #
    # READ STRAIGHT OFF $raw (the validated bytes), never off $vout:
    # validate-artifact's envelope (emit_validate) carries only {ok,
    # subcommand, error_key, observations} — unlike validate-design's
    # emit_validate_design, there is no echoed task_id to read back here.
    #
    # UNCONDITIONAL, matching completion-record's shape rather than
    # design-record's (which only fires when its artifact's task_id is
    # NON-EMPTY): validate-artifact's has() loop above only proves the KEY
    # is present, never that the VALUE is a non-empty string, so an artifact
    # carrying task_id=null or task_id="" must still be refused here rather
    # than waved through on an emptiness exemption design-record's schema
    # does not need (validate-design enforces task_id_missing on a
    # non-string/empty value before that recorder ever reaches this point).
    # `jq -r` on an absent or JSON-null task_id both print the literal
    # string "null", which cannot equal a real task id and is refused for
    # the same reason a mismatched one is.
    # RRV-GUARD BEGIN (claude-workflow-plugin-wob2 R1-F1; load-bearing —
    # review-separation-records.sh's R7 META strips to END to prove THIS
    # block, not some other refusal, is what catches a foreign task_id)
    local art_tid
    art_tid=$(printf '%s' "$raw" | jq -r '.task_id' 2>/dev/null)
    if [ "$art_tid" != "$tid" ]; then
        emit_error_json "review-record" "$tid" "artifact_task_id_mismatch" \
            "the artifact's own task_id='$art_tid' is not the task being recorded ('$tid'). A review recorded on a task it does not describe would make approve's binding attest to the wrong task's change set" \
            "qa-gate.sh review-record $art_tid --file <path>  OR  printf '%s' \"\$JSON\" | qa-gate.sh review-record $art_tid"
        exit 1
    fi
    # RRV-GUARD END (claude-workflow-plugin-wob2 R1-F1)

    # --- CANONICAL PATH (v5 D2 / claude-workflow-plugin-rqer) ---------------
    # The artifact is DERIVED, never supplied — --file only ASSERTS that
    # derivation, the same discipline design-record's --file already
    # enforces (see review_artifact_path_for's header for why this is the
    # same shape). `iter` is read here, ahead of the "extract the grammar
    # fields" section below, because the derivation needs it first.
    local iter derived derived_rel
    iter=$(printf '%s' "$raw" | jq -r '.iterations' 2>/dev/null)
    derived=$(review_artifact_path_for "$tid" "$iter")
    derived_rel="${derived#"$PROJECT_DIR"}"
    derived_rel="${derived_rel#/}"
    if [ -n "$input_path" ] && [ "$input_path" != "$derived" ] && [ "$input_path" != "$derived_rel" ]; then
        emit_error_json "review-record" "$tid" "artifact_path_not_derived" \
            "--file names '$input_path', which is not the artifact this round can record. The record carries the HASH and no path, so the path must be derivable from the task id and iteration: $derived, or its repo-relative spelling $derived_rel. --file ASSERTS that derivation; it cannot point the record at other bytes. Write the artifact there, or pipe it via stdin instead — review-record then writes it there for you" \
            "qa-gate.sh review-record $tid --file $derived  OR  printf '%s' \"\$JSON\" | qa-gate.sh review-record $tid"
        exit 1
    fi

    # Whatever is CURRENTLY at $derived (nothing, an earlier round of ours, or
    # — what this refuses — something a symlink or a same-named directory has
    # put there) is checked BEFORE we touch it. `-e` alone would miss a
    # dangling symlink; `-L` catches that case too. A same-named DIRECTORY is
    # refused explicitly and separately: `review_path_is_contained` only asks
    # where the entry SITS, not what kind of thing it is, and `mv` into an
    # existing directory renames INTO it rather than replacing it — silently
    # landing the artifact somewhere other than $derived, which is exactly
    # the unchecked-mv failure shape reported alongside this fix for the
    # external reviewer driver's own writer, reproduced here on purpose
    # rather than inherited.
    if { [ -e "$derived" ] || [ -L "$derived" ]; } && ! review_path_is_contained "$derived"; then
        emit_error_json "review-record" "$tid" "artifact_outside_review_dir" \
            "the review artifact must live directly in $PROJECT_DIR/$REVIEW_ARTIFACT_SUBDIR, and '$derived' does not resolve to a file there — check whether it is a symlink out of the directory. Refusing rather than recording bytes never shown to belong to the declared directory" \
            "inspect and remove $derived, then re-run qa-gate.sh review-record $tid"
        exit 1
    fi
    if [ -d "$derived" ]; then
        emit_error_json "review-record" "$tid" "artifact_path_is_directory" \
            "the canonical review-artifact path $derived is a directory, not a file — cannot write or hash an artifact there" \
            "remove or rename the directory at $derived, then re-run qa-gate.sh review-record $tid"
        exit 1
    fi

    mkdir -p "$(dirname "$derived")" 2>/dev/null || true

    if [ -n "$input_path" ]; then
        # The caller already placed the (now derivation-checked, now
        # containment-checked) bytes at $derived; nothing to write.
        if [ ! -f "$derived" ]; then
            emit_error_json "review-record" "$tid" "artifact_not_found" \
                "no review artifact at $derived. The record binds a hash of the bytes on disk, so there is nothing to bind" \
                "qa-gate.sh review-record $tid --file $derived"
            exit 1
        fi
    else
        # stdin path: review-record IS the writer. This is what closes the
        # Claude-lane gap by CONSEQUENCE rather than by prose instruction —
        # qa.md used to instruct authoring the artifact with the Write tool at
        # a specific path with nothing downstream able to tell if that step
        # was skipped; piping to this command now produces a real, hashed
        # file regardless of whether the caller performed a separate write.
        local write_tmp
        write_tmp="$derived.tmp.$$"
        if ! printf '%s' "$raw" > "$write_tmp" 2>/dev/null; then
            rm -f "$write_tmp" 2>/dev/null || true
            emit_error_json "review-record" "$tid" "artifact_write_failed" \
                "could not stage the review artifact for writing at $derived (disk full, or the directory is not writable)" \
                "qa-gate.sh review-record $tid --file <path>  OR  stdin pipe"
            exit 1
        fi
        if ! mv "$write_tmp" "$derived" 2>/dev/null; then
            rm -f "$write_tmp" 2>/dev/null || true
            emit_error_json "review-record" "$tid" "artifact_write_failed" \
                "could not move the review artifact into place at $derived" \
                "qa-gate.sh review-record $tid --file <path>  OR  stdin pipe"
            exit 1
        fi
    fi

    # --- the hash, over the RAW BYTES now resting at the canonical path -----
    # Same instrument the design side uses (AC-3): workflow-manifest.sh
    # hash-file, which refuses BEFORE hashing on missing/unreadable/EMPTY
    # (never the constant e3b0c442… degradation sentinel — see its own header
    # for why that matters: a binding over it would compare equal to itself
    # forever).
    local manifest_tool artifact_hash art_hash_rc=0
    manifest_tool="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
    if [ ! -f "$manifest_tool" ]; then
        emit_error_json "review-record" "$tid" "hash_tool_unavailable" \
            "cannot hash the review artifact: workflow-manifest.sh is missing at $manifest_tool. FAILS CLOSED — a record without a real binding is a record the gate would trust for nothing" \
            "restore .claude/scripts/workflow-manifest.sh"
        exit 2
    fi
    artifact_hash=$(bash "$manifest_tool" hash-file "$derived" 2>/dev/null) || art_hash_rc=$?
    if [ "$art_hash_rc" -ne 0 ] || ! is_sha256_hex "$artifact_hash"; then
        emit_error_json "review-record" "$tid" "artifact_hash_unavailable" \
            "the review artifact at $derived could not be hashed into 64 hex characters (workflow-manifest.sh hash-file exited $art_hash_rc, produced '${artifact_hash:-<empty>}'). Refused rather than recorded with a placeholder" \
            "bash .claude/scripts/workflow-manifest.sh hash-file $derived"
        exit 2
    fi
    assert_record_scalar "review-record" "$tid" "artifact_hash" "$artifact_hash"

    # Extract the grammar fields from the validated artifact. `pin` (46w9) is
    # reviewer_pin, abbreviated the same way reviewer_model already is to
    # `model` — see the ART_REVIEWER_PIN comment in review-check.sh's cmd_gate
    # for why "pin=" cannot collide with any other token in this grammar.
    #
    # WHICH SCALARS ARE RE-GUARDED HERE, AND WHICH ARE NOT (claude-workflow-
    # plugin-wob2 KGRAM). Of the ten scalars this function interpolates into
    # the machine prefix (iteration, reviewer, model, pin, reviewed_hash,
    # risk_threshold, verdict, stopped_by, findings, artifact_hash):
    #   - model and pin already passed validate-artifact's control-character
    #     AND model-id-class (id_ok) checks above (ok=true would not have
    #     been reached otherwise) — that class already excludes space, so no
    #     second bjx guard is added here.
    #   - verdict and stopped_by are each a closed enum validate-artifact
    #     already checks (approve|findings; verdict|stop_condition|
    #     cap:max_findings|cap:max_review_iterations|cap:timeout) — every
    #     member of both sets is already free of space/comma/bracket, so
    #     re-asserting them through assert_record_scalar's [A-Za-z0-9._+-]
    #     class would be redundant at best and WRONG at worst: stopped_by's
    #     "cap:max_findings" shape legitimately contains a colon, which that
    #     class forbids.
    #   - findings_token is built exclusively from findings[].id (already
    #     schema-anchored to ^R[0-9]+-F[0-9]+$) and findings[].severity
    #     (already a closed 5-member enum) — safe by construction.
    #   - iterations, reviewer_identity, risk_threshold and reviewed_hash had
    #     NO character-class guard anywhere in the pipeline until this round.
    #     REPRODUCED (this task's own record): an unguarded reviewer_identity
    #     let a single crafted value embed a complete second REVIEW-ARTIFACT
    #     head — its own reviewer=/model=/pin=/reviewed_hash=/risk_threshold=
    #     /verdict=/stopped_by=/findings=[]/at TIMESTAMP: — ahead of every
    #     REAL field the template appends afterward. review-check.sh's
    #     anchored art_prefix_len matches only up to the FIRST such
    #     " at TS: " it finds, so the fake head became the ENTIRE record as
    #     far as every downstream reader was concerned: a real
    #     critical finding went uncounted (open_findings 0 instead of 1), an
    #     actual self-review read as reviewer_identity="independent-auditor"
    #     (independent: true, when the task's only IMPLEMENTER record names
    #     the same role), and a real stopped_by=cap:max_findings (incomplete
    #     by construction — qa.md 6-prime) read back as stopped_by=verdict,
    #     cap_terminated: false. One unguarded field, three simultaneous
    #     false readings, through the shipped writer and the shipped gate
    #     reader, no bd access beyond an isolated fixture required.
    #     reviewed_hash and risk_threshold now also gained shape/enum checks
    #     in validate-artifact itself (see its own comments) — but a shape
    #     check is not a bjx grammar-injection guard, and iterations' own
    #     digit-only check happens in a SEPARATE subprocess, over a copy of
    #     the same bytes this function re-reads independently from $raw.
    #     These four get assert_record_scalar below, on the same "ours, but
    #     checked anyway" discipline completion-record's payload_sha already
    #     documents: an assumption that a value is safe because of where it
    #     came from is exactly the assumption bjx's rubric_version was
    #     shipped on.
    local reviewer model pin hash rt verdict stopped findings_token fc summary ts comment_text
    reviewer=$(printf '%s' "$raw" | jq -r '.reviewer_identity' 2>/dev/null)
    model=$(printf '%s' "$raw" | jq -r '.reviewer_model' 2>/dev/null)
    pin=$(printf '%s' "$raw" | jq -r '.reviewer_pin' 2>/dev/null)
    hash=$(printf '%s' "$raw" | jq -r '.reviewed_hash' 2>/dev/null)
    rt=$(printf '%s' "$raw" | jq -r '.risk_threshold' 2>/dev/null)
    verdict=$(printf '%s' "$raw" | jq -r '.verdict' 2>/dev/null)
    stopped=$(printf '%s' "$raw" | jq -r '.stopped_by' 2>/dev/null)
    findings_token=$(printf '%s' "$raw" | jq -r 'if (.findings|length)==0 then "" else (.findings|map(.id+":"+.severity)|join(",")) end' 2>/dev/null)
    fc=$(printf '%s' "$raw" | jq -r '.findings | length' 2>/dev/null)
    assert_record_scalar "review-record" "$tid" "iterations" "$iter"
    # KGRAM-REVIEWER-IDENTITY-GUARD BEGIN (claude-workflow-plugin-wob2 R1-F1;
    # load-bearing — review-separation-records.sh's R8 META strips to END to
    # prove THIS line, not some other guard, is what stops the fake-head
    # injection documented above (the reviewer= field is the ONLY one of the
    # four re-guarded here with no upstream shape/enum check at all).
    assert_record_scalar "review-record" "$tid" "reviewer_identity" "$reviewer"
    # KGRAM-REVIEWER-IDENTITY-GUARD END (claude-workflow-plugin-wob2 R1-F1)
    assert_record_scalar "review-record" "$tid" "risk_threshold" "$rt"
    assert_record_scalar "review-record" "$tid" "reviewed_hash" "$hash"
    if [ "$verdict" = "approve" ]; then
        summary="approve — no findings at/above $rt"
    else
        summary="findings — $fc finding(s) reported"
    fi
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="REVIEW-ARTIFACT v1 iteration=$iter reviewer=$reviewer model=$model pin=$pin reviewed_hash=$hash risk_threshold=$rt verdict=$verdict stopped_by=$stopped findings=[$findings_token] artifact_hash=$artifact_hash at $ts: $summary"
    add_comment "$tid" "$comment_text"
    emit_json 1 "review-record" "$tid" "recorded" "comment posted at $ts: $comment_text; artifact $derived bound at artifact_hash=$artifact_hash over its RAW BYTES (reproduce with: shasum -a 256 $derived)"
}

# ---------------------------------------------------------------------------
# review-reconcile <tid> --file <path> [--acknowledge-findings] <reason>
# (claude-workflow-plugin-k6re R13-F1/F2, implementing the 2026-09-01
# BACKFILL CONSTRAINT this task recorded on itself five days before the
# headline fix shipped; --acknowledge-findings is R14-F5, see the
# R14F5-FINDINGS-GUARD block below for what it guards)
#
# THE DEFECT THIS CLOSES. review-record writes the GOVERNING
# REVIEW-ARTIFACT v1 grammar, stamped at WRITE time. review-check.sh gate's
# K3 selector (ART-ITERATION-SELECT) requires a single record to be
# SIMULTANEOUSLY max(iteration) AND max(at-timestamp), refusing with
# review_artifact_selection_disagreement on disagreement. Backfilling
# several historic, already-on-disk rounds through review-record in any
# order the caller does not carefully control almost always produces that
# disagreement: a low-iteration round backfilled LAST becomes the newest by
# write-time while carrying the lowest iteration number of the set, so the
# two axes point at different records. MEASURED, independently, on two
# distinct shapes: an artifact set where the globally-highest iteration is
# itself among the unrecorded ones (ordering the backfill numerically
# ascending happens to fix this shape, by construction, because the highest
# iteration is then also written last), and one where the globally-highest
# iteration is ALREADY recorded (no order of backfilling the REMAINING,
# lower-numbered set can ever make one of them simultaneously max-iteration,
# so this shape wedges regardless of order). The second shape is why
# "sort the backfill ascending" is not a fix, only a narrower trap: the L1
# negative control below is built on exactly that shape rather than on the
# shape that happens to look fixed.
#
# THE FIX IS NOT TO GOVERN. review-reconcile writes a SEPARATE,
# NON-GOVERNING grammar -- REVIEW-ARTIFACT-RECONCILED v1 -- that
# review-check.sh recorded-hashes accounts for (so qa-gate.sh approve's
# UNRECORDED-REVIEW-ARTIFACT-REFUSAL stops firing on the reconciled file)
# but that cmd_gate's K3 selector never matches at all (confirmed
# structurally: the trigger pattern in gate requires "REVIEW-ARTIFACT v1 "
# starting at position 1, and this grammar diverges at the very next
# character after "REVIEW-ARTIFACT" -- a hyphen here, a space there -- so no
# governing-selector code path is reachable from a reconciled record,
# regardless of its iteration or timestamp). A historic round backfilled
# this way is accounted for without ever becoming a K3 candidate, which is
# the only shape of fix that works for BOTH backlog shapes above rather than
# only the one that happens to look fixed under an ordering rule.
#
# WHAT review-reconcile IS FOR, and what it is NOT for: a review round that
# genuinely happened in the past and needs to be accounted for without
# retroactively changing which round governs the release verdict. The round
# that SHOULD currently govern still belongs through review-record, not
# through this command -- reconciling the CURRENT round would account for
# its bytes without ever letting it win a selection, which defeats review
# separation rather than repairing it. This command does not attempt to
# detect that case; the operator names it via the required reason argument
# instead, matching every other audited action in this file that could be
# misused (an unexplained one is indistinguishable from evasion; an
# explained one is visible in the audit trail for a human to question).
#
# --file, NOT stdin: unlike review-record, there is no Claude-lane
# equivalent here (an in-session review authors a FRESH artifact; a
# reconciliation is inherently about bytes that ALREADY exist on disk from a
# past round), so this command has nothing to write and everything to
# verify. Same canonical-path derivation, same containment check, same
# validate-artifact schema check, same "hash the bytes that are actually
# there" discipline as review-record -- copied rather than shared, one
# function, matching this file's own convention of NOT abstracting a shared
# recorder for design-record / review-record / completion-record, each of
# which independently re-derives the same shape for its own grammar.
cmd_review_reconcile() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "review-reconcile" "" "missing_task_id" \
            "review-reconcile requires <task-id> as first positional argument" \
            "qa-gate.sh review-reconcile <task-id> --file <path> '<reason>'"
        exit 1
    fi
    shift || true

    local input_path="" reason="" ack_findings=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --file)
                input_path="${2:-}"
                if [ -z "$input_path" ]; then
                    emit_error_json "review-reconcile" "$tid" "missing_file_path" \
                        "--file requires a path argument" \
                        "qa-gate.sh review-reconcile $tid --file <path> '<reason>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            # claude-workflow-plugin-k6re R14-F5: the audited escape for the
            # findings-acknowledgment guard below. A boolean, not a second
            # reason -- the <reason> argument this command already requires
            # is where the operator explains WHY reconciling over an open
            # finding is correct (most often: it was addressed in a later
            # round), and that same text is what a future reader sees next
            # to the marker this flag causes to be written.
            --acknowledge-findings) ack_findings=1; shift || true ;;
            -h|--help) usage; exit 1 ;;
            *)
                if [ -z "$reason" ]; then
                    reason="$1"
                else
                    reason="$reason $1"
                fi
                shift || true
                ;;
        esac
    done

    if [ -z "$input_path" ]; then
        emit_error_json "review-reconcile" "$tid" "missing_file_path" \
            "review-reconcile requires --file <path> naming an EXISTING review artifact already at its canonical derived path -- there is no stdin mode, because reconciliation is about bytes that already exist on disk from a past round, not a fresh artifact to write" \
            "qa-gate.sh review-reconcile $tid --file <path> '<reason>'"
        exit 1
    fi
    if [ -z "$reason" ]; then
        emit_error_json "review-reconcile" "$tid" "bypass_reason_required" \
            "review-reconcile requires a non-empty reason explaining why this historic round is being accounted for without governing the release verdict; the reason is recorded in the durable comment, and an unexplained reconciliation is indistinguishable from quietly hiding a round that should have governed" \
            "qa-gate.sh review-reconcile $tid --file <path> '<reason>'"
        exit 1
    fi

    require_bd "review-reconcile" "$tid"

    if [ ! -f "$input_path" ]; then
        emit_error_json "review-reconcile" "$tid" "file_not_found" \
            "artifact file does not exist: $input_path" \
            "qa-gate.sh review-reconcile $tid --file <existing-path> '<reason>'"
        exit 1
    fi
    local raw
    if ! raw=$(cat -- "$input_path" 2>/dev/null); then
        emit_error_json "review-reconcile" "$tid" "file_unreadable" \
            "could not read artifact file: $input_path" \
            "qa-gate.sh review-reconcile $tid --file <readable-path> '<reason>'"
        exit 1
    fi
    if [ -z "$raw" ]; then
        emit_error_json "review-reconcile" "$tid" "empty_input" \
            "artifact file is empty: $input_path" \
            "qa-gate.sh review-reconcile $tid --file <path> '<reason>'"
        exit 1
    fi

    # Validate via the ONE validator (subprocess). Reconciling a malformed
    # file would defeat the purpose of reconciling at all -- the grammar
    # governs nothing, but the bytes it points at must still be a real
    # review artifact, not arbitrary content.
    local tmpf vout ok ekey
    tmpf=$(mktemp -t qa-gate-reconcile.XXXXXX 2>/dev/null) || tmpf="$QA_TRACKING_DIR/.review-reconcile-$$.json"
    printf '%s' "$raw" > "$tmpf"
    vout=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" validate-artifact "$tmpf" 2>/dev/null || true)
    rm -f "$tmpf" 2>/dev/null || true
    ok=$(printf '%s' "$vout" | jq -r '.ok // false' 2>/dev/null || echo "false")
    if [ "$ok" != "true" ]; then
        ekey=$(printf '%s' "$vout" | jq -r '.error_key // "invalid_artifact"' 2>/dev/null || echo "invalid_artifact")
        emit_error_json "review-reconcile" "$tid" "$ekey" \
            "artifact failed validation via review-check.sh: $ekey" \
            "provide a valid review artifact (see review-check.sh validate-artifact schema)"
        exit 1
    fi

    # THE DECOY-ARTIFACT CHECK, same as review-record RRV-GUARD: an artifact
    # whose own task_id names a different task would make this reconciliation
    # attest to the wrong task entirely.
    local art_tid
    art_tid=$(printf '%s' "$raw" | jq -r '.task_id' 2>/dev/null)
    if [ "$art_tid" != "$tid" ]; then
        emit_error_json "review-reconcile" "$tid" "artifact_task_id_mismatch" \
            "the artifact's own task_id='$art_tid' is not the task being reconciled ('$tid')" \
            "qa-gate.sh review-reconcile $art_tid --file <path> '<reason>'"
        exit 1
    fi

    # CANONICAL PATH: same derivation review-record and the external
    # reviewer driver both use. --file must ASSERT it, never name arbitrary
    # bytes -- this is a read-only recorder (see below), so unlike
    # review-record there is no write branch to fall back on if the file
    # sits somewhere else.
    local iter derived derived_rel
    iter=$(printf '%s' "$raw" | jq -r '.iterations' 2>/dev/null)
    derived=$(review_artifact_path_for "$tid" "$iter")
    derived_rel="${derived#"$PROJECT_DIR"}"
    derived_rel="${derived_rel#/}"
    if [ "$input_path" != "$derived" ] && [ "$input_path" != "$derived_rel" ]; then
        emit_error_json "review-reconcile" "$tid" "artifact_path_not_derived" \
            "--file names '$input_path', which is not the canonical path for this artifact iteration: $derived, or its repo-relative spelling $derived_rel. review-reconcile only reads bytes already at their canonical location; it does not write" \
            "qa-gate.sh review-reconcile $tid --file $derived '<reason>'"
        exit 1
    fi
    if ! review_path_is_contained "$derived"; then
        emit_error_json "review-reconcile" "$tid" "artifact_outside_review_dir" \
            "the review artifact must live directly in $PROJECT_DIR/$REVIEW_ARTIFACT_SUBDIR, and '$derived' does not resolve to a file there -- check whether it is a symlink out of the directory" \
            "inspect $derived, then re-run qa-gate.sh review-reconcile $tid --file $derived '<reason>'"
        exit 1
    fi
    if [ ! -f "$derived" ]; then
        emit_error_json "review-reconcile" "$tid" "artifact_not_found" \
            "no review artifact at $derived -- review-reconcile only accounts for bytes that already exist there, it never writes them" \
            "qa-gate.sh review-reconcile $tid --file $derived '<reason>'"
        exit 1
    fi

    # THE HASH, over the RAW BYTES resting at the canonical path -- same
    # instrument review-record uses, same refuse-before-hashing-a-placeholder
    # discipline.
    local manifest_tool artifact_hash art_hash_rc=0
    manifest_tool="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
    if [ ! -f "$manifest_tool" ]; then
        emit_error_json "review-reconcile" "$tid" "hash_tool_unavailable" \
            "cannot hash the review artifact: workflow-manifest.sh is missing at $manifest_tool. FAILS CLOSED -- a record without a real binding is a record the gate would trust for nothing" \
            "restore .claude/scripts/workflow-manifest.sh"
        exit 2
    fi
    artifact_hash=$(bash "$manifest_tool" hash-file "$derived" 2>/dev/null) || art_hash_rc=$?
    if [ "$art_hash_rc" -ne 0 ] || ! is_sha256_hex "$artifact_hash"; then
        emit_error_json "review-reconcile" "$tid" "artifact_hash_unavailable" \
            "the review artifact at $derived could not be hashed into 64 hex characters (workflow-manifest.sh hash-file exited $art_hash_rc, produced '${artifact_hash:-<empty>}')" \
            "bash .claude/scripts/workflow-manifest.sh hash-file $derived"
        exit 2
    fi
    assert_record_scalar "review-reconcile" "$tid" "artifact_hash" "$artifact_hash"
    assert_record_scalar "review-reconcile" "$tid" "iterations" "$iter"

    # THE FINDINGS-ACKNOWLEDGMENT GUARD (claude-workflow-plugin-k6re R14-F5).
    # review-reconcile already validated .verdict and .findings[].severity
    # via validate-artifact above but never looked at them — a historic
    # round carrying an unresolved finding at/above its OWN risk_threshold
    # could be reconciled silently, and since the RECONCILED comment below
    # deliberately carries no findings (that data already has a home in the
    # on-disk artifact), that finding would never enter the trust chain at
    # all: gate's open-findings count only ever reads GOVERNING records.
    # NOT a regression — with this whole mechanism absent, the same approve
    # already succeeded and left no record at all, so the prior state was
    # already "silently dropped, and unaudited" — but the review_artifact_
    # unrecorded refusal now actively instructs operators to reconcile
    # "every OTHER listed file" with no severity qualifier, so the edge sits
    # directly downstream of a printed instruction rather than only in
    # expert hands.
    #
    # NOT A BLANKET REFUSAL, deliberately: a historic critical is more often
    # than not already addressed by a later round — that is close to what
    # "historic" means in this exact context — so refusing unconditionally
    # would strand a legitimate backlog reconciliation on precisely the case
    # this mechanism exists to serve. The escape is the same "explain
    # yourself" discipline every other guard in this file uses:
    # --acknowledge-findings, required only when there is something to
    # acknowledge, with the existing <reason> argument carrying the human
    # explanation (most often: which later round actually addressed it).
    #
    # THE RANK TABLE is the same closed 5-value severity enum validate-
    # artifact already enforces on this exact field (critical > high >
    # medium > low > info) — not a second copy of review-check.sh's
    # sev_rank/threshold_rank, which are private to that file's own K3
    # machinery and answer a different question (which record GOVERNS);
    # this is a one-shot membership test over a single already-validated
    # artifact, computed once, not a running selector.
    # R14F5-FINDINGS-GUARD BEGIN (claude-workflow-plugin-k6re)
    local ack_findings_json ack_findings_count ack_findings_token
    ack_findings_json=$(printf '%s' "$raw" | jq -c '
        {"critical":5,"high":4,"medium":3,"low":2,"info":1} as $rank
        | .risk_threshold as $rt
        | (.findings // [])
        | map(select(($rank[.severity] // 0) >= ($rank[$rt] // 999)))
    ' 2>/dev/null)
    [ -n "$ack_findings_json" ] || ack_findings_json="[]"
    ack_findings_count=$(printf '%s' "$ack_findings_json" | jq 'length' 2>/dev/null || echo 0)
    if [ "$ack_findings_count" -gt 0 ] && [ "$ack_findings" != "1" ]; then
        ack_findings_token=$(printf '%s' "$ack_findings_json" | jq -r 'map(.id+":"+.severity) | join(",")' 2>/dev/null)
        emit_error_json "review-reconcile" "$tid" "reconcile_open_findings_unacknowledged" \
            "review-reconcile refused: the artifact at $derived (artifact_hash=$artifact_hash) carries $ack_findings_count finding(s) at or above its own risk_threshold=$(printf '%s' "$raw" | jq -r '.risk_threshold' 2>/dev/null) that would never enter the trust chain if reconciled as-is: $ack_findings_token. A REVIEW-ARTIFACT-RECONCILED v1 record carries no findings, so gate's open-findings count would read this round as clean. If this finding was actually resolved, record the round that resolved it through review-record and resolve-finding instead of reconciling this one. If it is genuinely historic (addressed or superseded in a LATER round already governing this task), re-run with --acknowledge-findings and state why in the reason: bash .claude/scripts/qa-gate.sh review-reconcile $tid --file $input_path --acknowledge-findings '<reason naming the round that addressed it>'" \
            "qa-gate.sh review-reconcile $tid --file <path> --acknowledge-findings '<reason>'"
        exit 1
    fi
    # R14F5-FINDINGS-GUARD END (claude-workflow-plugin-k6re)

    # THE COMMENT ITSELF: deliberately minimal, and structurally distinct
    # from REVIEW-ARTIFACT v1 starting at the very next character (a
    # hyphen, not a space) so no shared prefix can ever let cmd_gate select
    # on it. No reviewer/model/pin/verdict — those already exist in the
    # on-disk artifact this comment points at by iteration and hash;
    # duplicating them into a non-governing pointer record would be a second
    # copy of data that already has one home. findings[] is the ONE
    # exception, and only when non-empty at/above threshold: the bracketed
    # marker below is NOT a copy of the findings data (no location/evidence/
    # description, just id:severity), it is the audit trail proving this
    # reconciliation was not a silent drop — see the guard immediately
    # above. The reason argument is free text after the mandatory
    # "at <ts>: " marker, matching every other writer in this file
    # (resolve-finding own summary, arbitrate own rationale) -- anchored
    # parsers never need to read past the marker they require, so free text
    # after it is safe by the same construction the whole grammar family
    # already relies on.
    local ts comment_text ack_marker=""
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$ack_findings_count" -gt 0 ]; then
        ack_marker="[open findings acknowledged: $(printf '%s' "$ack_findings_json" | jq -r 'map(.id+":"+.severity) | join(",")' 2>/dev/null)] "
    fi
    comment_text="REVIEW-ARTIFACT-RECONCILED v1 iteration=$iter artifact_hash=$artifact_hash at $ts: ${ack_marker}${reason}"
    add_comment "$tid" "$comment_text"
    emit_json 1 "review-reconcile" "$tid" "reconciled" "comment posted at $ts: $comment_text; artifact $derived accounted for at artifact_hash=$artifact_hash WITHOUT becoming a K3 selection candidate (reproduce the hash with: shasum -a 256 $derived)"
}

# ---------------------------------------------------------------------------
# completion-record <tid> [--file <path>] (P7 / claude-workflow-plugin-qbhw)
#
# THE F7 COMPLETION CONTRACT'S ONE RUNTIME RECORDING POINT. Mirrors
# cmd_review_record exactly, including the SUBPROCESS call to the ONE validator
# — review-check.sh `validate-completion`. No schema lives here, and none may:
# the whole reason that script exists is that a second copy of a contract's
# rules is a second thing to drift (see its header, and the way
# compute_change_set_hash defers to impact-report.sh --hash-only).
#
# RECORD GRAMMAR, one line, machine prefix first:
#   COMPLETION v1 task=<tid> role=<r> model=<m> pin=<p> fields=<csv> payload_sha=<sha256> at <ts>: <n> file(s), <m> test(s)
#
# model=/pin= (claude-workflow-plugin-46w9), added right after role=: `pin` is
# the specialist's own STATIC frontmatter `model:` reading, `model` is a
# RUNTIME SELF-REPORT (what the specialist states about its own identity —
# never re-derived from the frontmatter a second time). Their NAMES already
# reach `fields_csv` below (both are required, validated payload keys), but a
# name in a csv only answers "was this field present" — the VALUE is what the
# 46w9 measurement needs, and the persisted payload file is NOT the durable
# side of this record (see completion_payload_path_for's header: the bd
# comment is the cross-checkout-visible statement, the on-disk file is only
# what it digests), so the values are embedded here exactly as role's already
# is. Validated by assert_record_model_scalar — the WIDER model-id class, not
# assert_record_scalar's — see that function's header for why they are
# deliberately separate guards rather than one sharing a widened class.
#
# WHAT IS AND IS NOT IN IT. The four FREE-FORM fields (`decisions`, `blockers`,
# `llm_observations`, `context_coverage`) are NEVER interpolated: only their
# presence — established by the validator — and the payload digest reach the
# record. That is not a size optimisation, it is the injection boundary. Those
# fields are unconstrained prose by design; the moment one of them is embedded
# in a one-line grammar, every apostrophe, colon and newline in a specialist's
# honest narrative becomes a parser input. `payload_sha` is how the record still
# BINDS that prose: the persisted artifact carries it, and approve re-digests
# the artifact and compares.
#
# THE COUNTS are `files_changed | length` and `tests_added | length`. They are
# the cheapest thing an auditor reading the task can compare against the diff,
# and they cost nothing to record. `file(s)` / `test(s)` is deliberately not
# pluralised by count: a fixed spelling is one grammar, not two.
cmd_completion_record() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "completion-record" "" "missing_task_id" \
            "completion-record requires <task-id> as first positional argument" \
            "qa-gate.sh completion-record <task-id> [--file <path>]"
        exit 1
    fi
    shift || true

    local input_path=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --file)
                input_path="${2:-}"
                if [ -z "$input_path" ]; then
                    emit_error_json "completion-record" "$tid" "missing_file_path" \
                        "--file requires a path argument" \
                        "qa-gate.sh completion-record $tid --file <path>"
                    exit 1
                fi
                shift 2 || true
                ;;
            -h|--help) usage; exit 1 ;;
            *)
                emit_error_json "completion-record" "$tid" "unknown_flag" \
                    "unknown argument: $1 (expected --file <path> or stdin)" \
                    "qa-gate.sh completion-record $tid [--file <path>]"
                exit 1
                ;;
        esac
    done

    require_bd "completion-record" "$tid"

    local raw=""
    if [ -n "$input_path" ]; then
        if [ ! -f "$input_path" ]; then
            emit_error_json "completion-record" "$tid" "file_not_found" \
                "completion payload file does not exist: $input_path" \
                "qa-gate.sh completion-record $tid --file <existing-path>"
            exit 1
        fi
        if ! raw=$(cat -- "$input_path" 2>/dev/null); then
            emit_error_json "completion-record" "$tid" "file_unreadable" \
                "could not read completion payload file: $input_path" \
                "qa-gate.sh completion-record $tid --file <readable-path>"
            exit 1
        fi
    else
        if [ -t 0 ]; then
            emit_error_json "completion-record" "$tid" "no_input" \
                "no --file given and stdin is a terminal; pipe the completion JSON or pass --file <path>" \
                "qa-gate.sh completion-record $tid --file <path>  OR  printf '%s' \"\$JSON\" | qa-gate.sh completion-record $tid"
            exit 1
        fi
        raw=$(cat)
    fi

    if [ -z "$raw" ]; then
        emit_error_json "completion-record" "$tid" "empty_input" \
            "completion payload input is empty" \
            "qa-gate.sh completion-record $tid --file <path>  OR  stdin pipe"
        exit 1
    fi

    # FAIL CLOSED on a missing validator, and say which it is. review-record
    # runs `bash $REVIEW_CHECK_SCRIPT` unguarded, so a deleted checker there
    # produces an empty envelope and the generic `invalid_artifact` key — a
    # SCHEMA error for an INFRASTRUCTURE failure. That is the "wrong answer that
    # looks like the right one" shape the --expect-hash validation note in
    # cmd_approve names, and it is cheap to not repeat: an absent validator is
    # reported as an absent validator.
    if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
        emit_error_json "completion-record" "$tid" "validator_unavailable" \
            "cannot record a completion contract: the ONE validator is missing at $REVIEW_CHECK_SCRIPT, so the payload cannot be schema-checked. This FAILS CLOSED by design — recording an unvalidated payload would put a record on the task that approve then trusts. Restore the script and re-run" \
            "qa-gate.sh completion-record $tid --file <path>"
        exit 2
    fi

    # Validate via the ONE validator (subprocess). No second schema here.
    local tmpf vout ok ekey vobs
    tmpf=$(mktemp -t qa-gate-completion.XXXXXX 2>/dev/null) || tmpf="$QA_TRACKING_DIR/.completion-record-$$.json"
    printf '%s' "$raw" > "$tmpf"
    vout=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" validate-completion "$tmpf" 2>/dev/null || true)
    rm -f "$tmpf" 2>/dev/null || true
    ok=$(printf '%s' "$vout" | jq -r '.ok // false' 2>/dev/null || echo "false")
    if [ "$ok" != "true" ]; then
        ekey=$(printf '%s' "$vout" | jq -r '.error_key // "invalid_completion_payload"' 2>/dev/null || echo "invalid_completion_payload")
        [ -z "$ekey" ] && ekey="invalid_completion_payload"
        vobs=$(printf '%s' "$vout" | jq -r '.observations // ""' 2>/dev/null || echo "")
        emit_error_json "completion-record" "$tid" "$ekey" \
            "completion payload failed validation via review-check.sh: $ekey${vobs:+ — $vobs}" \
            "provide a valid F7 completion payload (see review-check.sh validate-completion)"
        exit 1
    fi

    # Grammar fields from the validated payload. `fields_csv` is NOT read here —
    # it is BUILT below from the keys this function has individually validated.
    local payload_tid role model pin nfiles ntests
    payload_tid=$(printf '%s' "$raw" | jq -r '.task_id' 2>/dev/null)
    role=$(printf '%s' "$raw" | jq -r '.role' 2>/dev/null)
    # model/pin (46w9): embedded as explicit VALUE tokens, same treatment as
    # role — their NAMES already reach `fields_csv` below (they are validated
    # payload keys), but a name in a csv answers "was this field present", not
    # "what did it say". The comment is the durable, cross-checkout record
    # (the persisted payload file is not — see completion_payload_path_for's
    # header); embedding the values here is what lets a LATER analysis (the
    # review-round baseline backfill this task was discovered from) query
    # model attribution from `bd show` alone, on a task closed long ago.
    model=$(printf '%s' "$raw" | jq -r '.model' 2>/dev/null)
    pin=$(printf '%s' "$raw" | jq -r '.pin' 2>/dev/null)
    nfiles=$(printf '%s' "$raw" | jq -r '.files_changed | length' 2>/dev/null)
    ntests=$(printf '%s' "$raw" | jq -r '.tests_added | length' 2>/dev/null)

    # THE DECOY-PAYLOAD CHECK. A payload whose own task_id names a different
    # task is the shape llh.18 documents for approvals (P1: "a decoy-task
    # approval records the decoy's hash, not the shipping change-set's"), and it
    # is cheaper to refuse than to reason about later: the record would claim
    # task A's completion while sitting on task B, and approve's cross-check
    # would compare task B's change set against task A's declared files.
    if [ "$payload_tid" != "$tid" ]; then
        emit_error_json "completion-record" "$tid" "task_id_mismatch" \
            "the payload's task_id='$payload_tid' is not the task being recorded ('$tid'). A contract recorded on a task it does not describe would make approve cross-check one task's change set against another's declared files" \
            "qa-gate.sh completion-record $tid --file <path with task_id=\"$tid\">"
        exit 1
    fi

    # THE bjx GUARD, over every scalar this function interpolates — see
    # assert_record_scalar. Payload KEY NAMES are specialist-controlled (the
    # payload is an arbitrary JSON object that merely has the required keys), so
    # they are exactly as untrusted as the role.
    #
    # VALIDATE-THEN-BUILD, not build-then-validate. This loop is the ONLY
    # producer of `fields_csv`: each key is checked and then appended, so the
    # string that reaches the record is composed of members this function proved
    # legal. That is a structural property, not a careful one.
    #
    # THE DEFECT THAT FORCED IT (QA R1-F1, both shapes reproduced before the
    # fix). The first version built the csv with jq's `join(",")` and then
    # validated it by re-splitting with `IFS=','` and an UNQUOTED `for fname in
    # $fields_csv`. Two independent holes, and the guard passed both while the
    # record was written from the untouched original:
    #   - COMMA, deterministic and needing no adversary: a key literally named
    #     `a,b` was split by IFS into two legal words `a` and `b`, so the guard
    #     never saw the comma it existed to reject. `ok=true`, and the record
    #     read `fields=...,context_coverage,a,b` — one key rendered as two csv
    #     members. This file's own header claimed "a comma ... cannot split the
    #     csv"; it could.
    #   - GLOB, and this one is worse than a bypass: an unquoted expansion also
    #     performs PATHNAME EXPANSION. A key `[c]lean1` expanded to `clean1` —
    #     legal — when a file of that name happened to sit in the process's
    #     working directory, and stayed `[c]lean1` — rejected — when it did not.
    #     The same payload got opposite verdicts decided by unrelated files in
    #     an unrelated directory, and on the passing side the brackets reached
    #     the record.
    # The general shape, which is the part worth carrying forward: A GUARD MUST
    # INSPECT THE BYTES THAT ARE WRITTEN. Validating a transformation of them —
    # a re-split, a re-join, a normalisation — validates a different string, and
    # the difference is where the payload hides.
    #
    # NUL-DELIMITED, and read through PROCESS SUBSTITUTION rather than a pipe.
    # NUL because it is the one byte a JSON key cannot contain, so no key can
    # forge a separator (a newline could, and a newline in a key is exactly the
    # vg8 control-character shape). Process substitution because the loop body
    # calls assert_record_scalar, which `exit 1`s on refusal: behind a pipe the
    # loop runs in a SUBSHELL, that exit would kill only the subshell, and the
    # function would carry on and write the record it had just refused.
    assert_record_scalar "completion-record" "$tid" "task" "$tid"
    assert_record_scalar "completion-record" "$tid" "role" "$role"
    # model/pin use the WIDER model-id class (assert_record_model_scalar), not
    # assert_record_scalar's — see that function's header for why the two are
    # deliberately separate rather than one guard sharing a widened class.
    assert_record_model_scalar "completion-record" "$tid" "model" "$model"
    assert_record_model_scalar "completion-record" "$tid" "pin" "$pin"
    local fname fields_csv=""
    while IFS= read -r -d '' fname; do
        assert_record_scalar "completion-record" "$tid" "field_name" "$fname"
        fields_csv="${fields_csv:+$fields_csv,}$fname"
    done < <(printf '%s' "$raw" | jq -j 'keys_unsorted[] | . + "\u0000"' 2>/dev/null)
    if [ -z "$fields_csv" ]; then
        emit_error_json "completion-record" "$tid" "fields_unreadable" \
            "the payload's key names could not be enumerated, so the record's fields= token cannot be built from validated members; refusing rather than writing an unvalidated or empty token" \
            "qa-gate.sh completion-record $tid --file <path>"
        exit 1
    fi

    # Persist the payload, THEN digest the file. In that order deliberately: the
    # digest then describes bytes that exist on disk, so `shasum -a 256 <path>`
    # by hand reproduces the token in the record. Digesting the in-memory string
    # and writing separately would leave two things that are only equal by
    # construction.
    # R1-F4: KEYED ON THE ROLE as well as the task, so a QA contract recorded
    # after an implementer's no longer overwrites the declaration the
    # completeness cross-check reads. `role` has already passed the character
    # class above, so it cannot escape the filename.
    local payload_file payload_sha
    payload_file=$(completion_payload_path_for "$tid" "$role")
    if ! mkdir -p "$QA_TRACKING_DIR" 2>/dev/null; then
        emit_error_json "completion-record" "$tid" "tracking_dir_unwritable" \
            "cannot create $QA_TRACKING_DIR, so the validated payload cannot be persisted; approve reads that artifact for its completeness cross-check" \
            "qa-gate.sh completion-record $tid --file <path>"
        exit 2
    fi
    if ! printf '%s' "$raw" > "$payload_file" 2>/dev/null; then
        emit_error_json "completion-record" "$tid" "payload_unwritable" \
            "could not persist the validated payload to $payload_file; refusing to write a record whose payload_sha names bytes nothing kept" \
            "qa-gate.sh completion-record $tid --file <path>"
        exit 2
    fi
    # sha256_file returns non-zero on a failed digest since i8cx. This WRITE
    # side keeps its documented degradation — the sentinel — rather than
    # refusing; the `|| payload_sha=""` is what routes the new rc into that
    # fallback instead of letting errexit kill the record write mid-flight.
    payload_sha=$(sha256_file "$payload_file") || payload_sha=""
    [ -z "$payload_sha" ] && payload_sha="$CHANGE_SET_HASH_UNAVAILABLE"
    # Ours, not the caller's — but checked anyway, because "this value is ours"
    # is exactly the assumption bjx's rubric_version was shipped on.
    assert_record_scalar "completion-record" "$tid" "payload_sha" "$payload_sha"

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # model=/pin= sit right after role= and before fields= (46w9). Every
    # reader of this grammar extracts by NAME (grep -oE 'role=...',
    # 'payload_sha=...'), never by position, so inserting new name=value
    # tokens here is safe for the readers above (completion_role,
    # completion_roles_seen, latest_implementer_completion_record) exactly as
    # it was for REVIEW-ARTIFACT's model= and IMPLEMENTER's model=/pin=.
    comment_text="COMPLETION v1 task=$tid role=$role model=$model pin=$pin fields=$fields_csv payload_sha=$payload_sha at $ts: $nfiles file(s), $ntests test(s)"
    add_comment "$tid" "$comment_text"
    emit_json 1 "completion-record" "$tid" "recorded" \
        "comment posted at $ts: $comment_text; validated payload persisted at $payload_file (approve re-digests it and cross-checks files_changed against the change set it binds)"
}

# ---------------------------------------------------------------------------
# DESIGN-ARTIFACT BEGIN (v5 Phase D1 / claude-workflow-plugin-fkm.3)
#
# design-record <tid> [--file <artifact>] [--designer <id>]
#               [--accept-foreign-paths '<reason>'] ['<summary>']
#
# THE DESIGNER'S RECORD: this artifact, at these bytes, is the design for this
# task. It is NOT the design reviewer's verdict — that is D2's own record, with
# its own grammar, its own author and its own lifetime. The v5 plan folded both
# into one subcommand name; they are split here because D2's independence check
# ("a verdict whose reviewer identity equals the designer's is refused") needs a
# durable statement of WHO the designer was, which only a separate record can
# carry. One subcommand writing two grammars would have to invent that anyway.
#
#   DESIGN-ARTIFACT v1 task=<tid> designer=<id> design_hash=<h> units=<n> at <ts>: <summary>
#
# Same shape as REVIEW-ARTIFACT / COMPLETION / ARBITRATION: machine prefix first,
# ` at <ISO-8601-UTC>` last before the colon, free text after it. No schema lives
# here — validation is the subprocess call to review-check.sh `validate-design`,
# the ONE validator, exactly as review-record and completion-record do.
#
# THE EDIT BAN'S SECOND LAYER LIVES IN THIS FUNCTION. Layer 1 is designer.md's
# tools list, which omits Bash and Edit; it is NOT airtight and is not claimed to
# be, because `Write` is retained (the designer has to author its own artifact)
# and Write overwrites any path in the tree. Layer 1 closes the shell vector and
# the patch vector. THIS is the layer that makes writing a source file
# consequential:
#
#   artifact_path_not_derived   --file is not the path derived from the task id
#   artifact_outside_spec_dir   what sits at that path does not resolve into
#                               docs/specs/ (a symlinked leaf, a moved directory)
#   designer_touched_source     the change set holds a path that is not this
#                               task's one design artifact — a source file, a
#                               second file beside it in docs/specs/, or ANOTHER
#                               task's design — while NO IMPLEMENTER record
#                               exists on the task
#
# The second is PHASE-SCOPED, and the phase boundary is the IMPLEMENTER record
# `subagent-start.sh` posts at SPAWN — not the COMPLETION record, which is
# written at FINISH and would leave the check armed through the entire
# implementation window. Once an implementer has spawned, source paths in the
# change set are the expected state and the check is off.
#
# TWO HONEST LIMITS, stated rather than discovered later:
#   * The change set is the SESSION's, not the designer's. Nothing attributes a
#     tracked path to an agent. So an orchestrator edit made before the designer
#     was spawned reads identically to a designer edit — hence the audited
#     `--accept-foreign-paths '<reason>'`, whose reason lands in the record.
#   * `record_implementer` is BEST-EFFORT (subagent-start.sh returns early with
#     no bd, no .beads, or no resolvable task). Absence of the record is not
#     proof implementation has not started, which is why the check REFUSES on an
#     unestablished answer rather than assuming the permissive branch.
#
# WHY NOT A PreToolUse PATH SCOPE, which the release directive asked for: the
# repo already paid for that. LESSONS.md records the P0 where fail-closing
# prevent-orchestrator-edits.sh on an identity the runtime does not surface to
# PreToolUse denied legitimate specialist Write/Edit — a P0 traded for a P2. That
# hook is untouched here, deliberately.
DESIGN_SPEC_SUBDIR="docs/specs"

# design_artifact_path_for <tid> — the ONE derivation of the artifact path from
# the task id. The record carries the HASH and no path, which is only sound
# because the path is derivable: an unfindable artifact and a hash that names
# bytes nobody can locate are the same defect. Same task-id sanitisation as
# impact_report_path_for and completion_payload_path_for.
#
# SINCE ROUND 5 THIS IS THE *ONLY* SOURCE OF AN ARTIFACT PATH — `--file` asserts
# this value rather than supplying one — so `tr -c 'A-Za-z0-9._-' '_'` is now
# load-bearing for every caller rather than for `approve` alone. It cannot emit a
# slash, so no `..` segment, no intermediate directory and no newline can enter a
# derived path; that was already why R4-F1's escape had two live sites and not
# three. Admit `/` (or a newline) to this class and every one of them reopens,
# with no other edit anywhere in the file.
#
# TWO COMMAND SUBSTITUTIONS SURVIVE HERE, named rather than left to look like
# oversights: the `tr` capture cannot end in a newline (a newline is IN the
# complement class and becomes `_`), and the CALLERS' capture of this function
# cannot lose a byte because the format string ends in a literal `d`.
design_artifact_path_for() {
    local sanitized
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/%s/%s.md' "$PROJECT_DIR" "$DESIGN_SPEC_SUBDIR" "$sanitized"
}

# ONE PHYSICAL NOTION OF *WHERE*, AND TWO QUESTIONS THAT SHARE IT (fkm.3 QA
# rounds 2-6).
#
# READ THIS BEFORE "RE-UNIFYING" THE PREDICATES. The split below is
# NOT THE ROUND-2 SHAPE RESTORED, and the difference is the whole finding.
# Round 2 found a LEXICAL tracker beside a PHYSICAL design-record: two
# notions of "inside", so one `..` segment made a source path read as NOT FOREIGN
# while the same path spelled plainly was refused, and a symlinked leaf made the
# record bind an outside file's bytes. Round 5 collapsed the pair into one
# predicate, which was right. Round 6 (R6-F1) then found that the collapse had
# given BOTH callers the RECORD caller's answer — and the two callers do not ask
# the same question:
#
#   `design-record` and `approve` ask "are the BYTES here the declared
#   artifact?", and for them the LEAF MUST BE FOLLOWED: `docs/specs/<tid>.md ->
#   ../../outside/x.md` otherwise hashes the outside file, which is R2-F2 and is
#   the whole reason the follow exists.
#
#   the tracker scan asks "is this ENTRY the one file this design may touch?",
#   and for it THE LEAF MUST NOT BE FOLLOWED. The entry names a location in the
#   source tree; where it points is a different fact about a different file.
#   Following it classified `src/runtime -> ../docs/specs/<tid>.md` by its
#   target, so a source-tree symlink vanished from the foreign set — and, worse
#   because it needs no symlink and no filesystem precondition at all, it let
#   `docs/specs/<OTHER-TASK>.md` and `docs/specs/notes.txt` read as CONTAINED. A
#   designer holding only `Write` could clobber another task's design artifact
#   and still record. All three instances were measured against the round-5
#   bytes; the middle one is what set the severity.
#
# WHAT THE TWO SHARE IS THE ONLY THING THAT WAS EVER WRONG WHEN THEY DIVERGED:
# the DIRECTORY comparison. `design_dir_is_spec_dir` is its single copy, it is
# PHYSICAL, and neither caller has one of its own — so there is no second notion
# of "inside" here to drift. The split is one statement wide: whether the leaf is
# resolved before that comparison runs.
#
# WHY THE PREDICATES RETURN A STATUS AND NOT A PATH — the round-5 shape fix, and
# the reason four consecutive rounds of findings all landed here. Every one of
# them had ONE root: a PATHNAME crossed a COMMAND SUBSTITUTION. `$( )` strips
# EVERY trailing newline and cannot tell a newline that terminates a command's
# output from a newline that is the last byte of a filename. The class had eleven
# spellings in this region — two `$(dirname …)`, four `$(basename …)`, and five
# CALLER captures of the answer these functions used to print. That last group is
# the one nobody reported and the one that makes a partial fix DECORATIVE: a
# byte-preserving walk whose result is captured with `$( )` is truncated at the
# caller instead, and for a container ending in a newline that turns "outside"
# into "inside" one frame later (measured: with the walk fixed and the capture
# left, a tracker line reaching `docs/specs\n/pwn.sh` through a symlink read as
# NOT foreign). So no path is printed at all now: both directories are compared
# INSIDE one subshell, as `$PWD`, and the only thing that crosses the boundary is
# an exit status. The SEAM THIS ROUND INTRODUCES OBEYS THE SAME RULE — the
# resolved leaf reaches the shared core as an ARGUMENT, which preserves every
# byte. `docs/specs\n` and `docs/specs` are different directories here, which is
# what the kernel has always thought.

# design_dir_is_spec_dir <path> — 0 when <path>'s PARENT DIRECTORY, resolved
# PHYSICALLY, IS the declared design directory; 1 for everything else. THE SHARED
# CORE. It never inspects <path>'s own last component and never follows it: a
# caller that wants the leaf followed resolves it first and hands the result in.
#
#   * A RELATIVE path is taken against $PROJECT_DIR — the tracker's spelling
#     (reconcile_tracker and `git status` produce repo-relative paths). `--file`
#     no longer arrives here in any spelling but the derived one, so one path
#     spelling cannot mean two different files; see cmd_design_record.
#   * THE WALK IS PHYSICAL, AND `cd -P` IS WHAT MAKES IT SO (fkm.3 QA round 4,
#     R4-F1). Bare `cd` is bash LOGICAL mode: it collapses `..` LEXICALLY and
#     falls back to physical resolution only when the reduced path fails to
#     chdir. So `docs/specs/<dirlink>/../x` reduced to `docs/specs`, which
#     exists, so the fallback never ran and the predicate answered for the
#     SPELLING while the kernel opened <dirlink>'s real parent. `pwd -P` cannot
#     repair that — it reports where the `cd` landed, by which time the wrong
#     directory is already chosen, which is why the sentence that used to sit
#     here crediting `pwd -P` with resolving `..` was not merely imprecise but
#     the reason nobody added `-P`.
#   * `dirname` IS SPELLED IN PARAMETER EXPANSION, and the trailing-slash loop is
#     part of the spelling rather than defensive noise. `${p%/*}` alone is NOT
#     `dirname`: dirname strips trailing slashes FIRST, which is what makes the
#     bare entry `docs/specs/` answer `docs`. Same answer as the subprocess for
#     `/a/b`, `/a/b/`, `/a`, `/`, `//` and `/a/b//` — and, unlike the subprocess,
#     the same BYTES.
#   * NESTED IS FOREIGN. `docs/specs/sub/deep.md`'s parent is not the declared
#     directory: one directory level is exactly what the declaration in
#     workflow-manifest.sh scans (`-maxdepth 1`), so the Stop-gate veto could not
#     see a nested file either. The design phase produces ONE file, in ONE
#     directory.
#   * FAIL-CLOSED: an empty argument, an unreachable path and an unreachable
#     declared directory are all "not the declared directory" (a location we
#     cannot prove is the declared one is not it).
design_dir_is_spec_dir() (
    local p="${1:-}" here
    [ -n "$p" ] || return 1
    case "$p" in /*) ;; *) p="$PROJECT_DIR/$p" ;; esac
    while [ "${p%/}" != "$p" ] && [ -n "${p%/}" ]; do p="${p%/}"; done
    p="${p%/*}"
    [ -n "$p" ] || p="/"
    cd -P "$p" 2>/dev/null || return 1
    here="$PWD"
    cd -P "$PROJECT_DIR/$DESIGN_SPEC_SUBDIR" 2>/dev/null || return 1
    [ "$here" = "$PWD" ]
)

# design_path_is_contained <path> — 0 when <path>'s FINAL TARGET sits DIRECTLY in
# the declared design directory. THE RECORD SIDE'S QUESTION ("are the bytes here
# the artifact?"), so it FOLLOWS the leaf, bounded, and then asks the shared core
# about what it landed on. Never fails the caller: an unresolvable path, a
# symlink loop and an empty argument are all "not contained".
#
#   * LEAF SYMLINKS ARE FOLLOWED, bounded. `readlink -f` / `realpath` would each
#     be one line and neither is portable enough for this file: BSD readlink had
#     no -f before macOS 12.3 and coreutils realpath is not on a stock macOS at
#     all, while this script runs on both. A symlink LOOP exhausts the hop budget
#     (and now fails `-ef` first) and resolves to not-contained.
#   * `readlink`'S OUTPUT IS THE ONE COMMAND SUBSTITUTION LEFT, AND `-ef` IS WHAT
#     MAKES IT HONEST (fkm.3 QA round 3, R3-F3 — CLOSED here, not disclosed). A
#     link pointing at `alias\n` reads back as `alias`, so the walk inspected one
#     path while the kernel opened another; driven end to end it produced a
#     record binding an OUTSIDE decoy's digest. There is no portable
#     byte-preserving reader (`readlink -z` is not on a stock macOS), so the
#     reconstruction is CHECKED instead: `[ "$prev" -ef "$p" ]` is bash's
#     device+inode comparison and it follows both sides, so a truncated target
#     names a different file (or none) and is FALSE, while an honest link —
#     relative, absolute, or a chain — stays TRUE. Both directions measured. One
#     verdict changes with it: a DANGLING link inside the directory is now
#     not-contained rather than inheriting its dirname's answer — fail-closed,
#     and not a contradiction of workflow-manifest.sh declaring dangling links,
#     because "governed by the veto" and "provably the artifact" are different
#     questions.
#   * `-ef` IS A DEVICE+INODE TEST AND NOT A NAME TEST, so it is DEFEATED BY A
#     HARDLINK — the one case where a name truncated by `$(dirname …)` still
#     names the same file (fkm.3 QA round 6, R6-F2, which built it in six lines
#     after round 5 claimed no such case existed). That is why the IN-LOOP
#     dirname is spelled `${p%/*}` too, and why the consequence is driven rather
#     than argued: design-artifact.test.sh section 9.5 inverts the verdict from
#     foreign to CONTAINED against that one mutation.
design_path_is_contained() {
    local p="${1:-}" hops=0 target prev
    [ -n "$p" ] || return 1
    case "$p" in /*) ;; *) p="$PROJECT_DIR/$p" ;; esac
    while [ -L "$p" ]; do
        [ "$hops" -lt 40 ] || return 1
        target=$(readlink "$p" 2>/dev/null) || target=""
        [ -n "$target" ] || return 1
        prev="$p"
        case "$target" in
            /*) p="$target" ;;
            *)  p="${p%/*}/$target" ;;
        esac
        [ "$prev" -ef "$p" ] || return 1
        hops=$((hops + 1))
    done
    design_dir_is_spec_dir "$p"
}

# design_entry_is_artifact <path> <leaf-name> — 0 when <path>, TAKEN AS THE NAME
# IT IS, is this task's one design artifact: its parent directory resolves
# physically to the declared one AND its own last component is <leaf-name>. THE
# TRACKER SIDE'S QUESTION. It reads no link target, so an entry is judged where
# it SITS, and a file is not the artifact merely by being in the directory.
#
#   * THE DIRECTORY ARM RUNS FIRST, and the order is deliberate. Both arms must
#     hold, so the VERDICT is identical either way; what the order decides is
#     which arm a refusal is ATTRIBUTABLE to, and therefore which arm the
#     historical legs still exercise — R2-F1's `..`, R4-F1's `..` after a
#     directory symlink, the symlinked root, the maxdepth-1 rule. After this
#     split a hostile source path is refused by its NAME long before its
#     directory is interesting, so sections 6.11 and 6.12 of
#     design-artifact.test.sh pin each arm with legs the other cannot satisfy.
#   * NO TRAILING-SLASH RULE HERE, deliberately — this is where it would be WRONG
#     rather than redundant. `docs/specs/` has an EMPTY last component, which is
#     not the artifact's name, so the bare directory entry is refused; and
#     `docs/specs/<tid>.md/` (a file spelled as a directory) is refused too. Both
#     are the fail-closed answer for spellings nothing in the workflow emits —
#     `docs/specs/` reaches the tracker only when reconcile_tracker's `?? dir/`
#     expansion is unavailable, where refusing (with the audited bypass
#     available) is the fail-closed answer under an unreadable git.
#   * FAIL-CLOSED ON AN EMPTY NAME: with no <leaf-name>, nothing is the artifact,
#     so every entry is foreign and design-record refuses. The one caller derives
#     the name from the task id, where the format string guarantees a `.md` tail.
design_entry_is_artifact() {
    local p="${1:-}" want="${2:-}"
    [ -n "$p" ] && [ -n "$want" ] || return 1
    design_dir_is_spec_dir "$p" || return 1
    [ "${p##*/}" = "$want" ]
}

# design_foreign_paths <artifact-leaf-name> — the denylist-filtered tracked paths
# that are NOT this task's design artifact, one per line. The denylist is the
# shared one (workflow-denylist.sh), so the gate's own churn — .qa-tracking,
# .beads, the spawn log the designer's own spawn appends to — is not mistaken
# for work.
#
# THE CALLER'S CAPTURE OF THIS FUNCTION IS ONE OF THE TWO EXCEPTIONS SECTION 8
# SUBTRACTS, and it is safe for a reason rather than by convention: what crosses
# the substitution is a LINE-DELIMITED LIST, counted and printed into a
# diagnostic and never opened. changed-files.txt is line-delimited, so no entry
# can carry the byte `$( )` eats.
design_foreign_paths() {
    local want="${1:-}"
    local tracking="$QA_TRACKING_DIR/changed-files.txt" line _sorted
    [ -s "$tracking" ] || return 0
    # rc 2 = COULD NOT READ, distinct from rc 0 with no output (= read fine,
    # nothing foreign). The `[ -s ]` guard above has already proven the file
    # non-empty, which is what makes the failure decidable at all. Before i8cx
    # this was a process substitution whose rc was unobservable: the loop
    # simply ran zero times, a tracker full of source paths counted as
    # foreign_n=0, and the designer_touched_source refusal was skipped.
    _sorted=$(LC_ALL=C sort -u "$tracking" 2>/dev/null) || return 2
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ -n "${WORKFLOW_DENYLIST_REGEX:-}" ] && [[ "$line" =~ $WORKFLOW_DENYLIST_REGEX ]]; then
            continue
        fi
        if ! design_entry_is_artifact "$line" "$want"; then
            printf '%s\n' "$line"
        fi
    done <<< "$_sorted"
}

# is_sha256_hex <value> — A SHAPE TEST, NEVER AN IDENTITY TEST, borrowed
# verbatim in spirit from verify-before-stop.sh's _vl_is_hash and its rationale.
# It refuses `sha256-unavailable`, any truncation of it, the empty string, and a
# digest a hash tool cut short — including whatever the next degradation
# spelling turns out to be. An identity test can only refuse a value somebody has
# already been surprised by.
#
# CASE-INSENSITIVE, DELIBERATELY (claude-workflow-plugin-wob2 R1-F4) — this is
# a CROSS-REFERENCE, read the other side before changing either. review-check.sh's
# REVIEWED-HASH-GUARD (cmd_validate_artifact) accepts LOWERCASE ONLY on
# reviewed_hash, and the two are not a drift to be unified: they gate two
# different kinds of claim. design_hash/vendor_hash (gated here) are
# RECOMPUTED and compared for VALUE equality — case carries no information,
# and a real cross-platform producer of one really does emit uppercase:
# install.ps1's own Get-FileSha256 documents "Get-FileHash returns UPPERCASE
# hex; the manifest is lowercase ... The ToLowerInvariant() is therefore
# load-bearing" for exactly this reason, in this same repo's toolchain.
# reviewed_hash instead asserts a COPY — verbatim, from a review request's
# change_set_hash — so a case mismatch there IS the signal ("the reviewer did
# not actually copy the value they were handed"); tolerating case on that
# field would erase the one thing it exists to catch. No known producer in
# this repo emits an uppercase design_hash/vendor_hash today (every one goes
# through workflow-manifest.sh hash-file, always lowercase), so this is
# currently belt-and-suspenders — kept case-insensitive anyway because the
# Windows install-path precedent above shows the risk is real, not
# hypothetical, and because loosening it costs nothing a live producer relies
# on. If either class is ever tightened or loosened, update this comment and
# review-check.sh's, together.
is_sha256_hex() {
    local v="${1:-}"
    case "$v" in
        "" | *[!0-9a-fA-F]*) return 1 ;;
    esac
    [ "${#v}" -eq 64 ]
}

# get_parent_epic <tid> — <tid>'s parent id, or empty (no parent, or bd could
# not be read). Same "exit status is the signal, not a global" shape as
# get_labels: `p="$(get_parent_epic "$tid")"; rc=$?` lets a caller that needs
# to distinguish "confirmed no parent" from "could not check at all" do so.
#
# `bd show <id> --json` inlines `.parent` as a top-level scalar — measured
# directly (bd 1.2.2): the key is ABSENT (not null) on a parentless task, and
# a plain string on one with a parent. Same array-or-object shape ambiguity
# get_labels already handles across the bd version range, so the same
# ternary; `// ""` collapses "absent key" and "present but empty" to the one
# answer a caller actually needs (falsy either way).
#
# claude-workflow-plugin-k6re R17 class sweep, CORRECTED by R19-F1 (see
# get_labels()'s own comment above for the full correction — this function
# is a byte-for-byte structural copy of get_labels() and the same correction
# applies verbatim): `raw=$(bd show ...)` followed by `rc=$?` was never at
# risk of an abort skipping `rc=$?` in the first place, because this
# function too is invoked ONLY through `$(...)` (its one caller,
# `parent=$(get_parent_epic "$tid") || parent=""` in grilling_record_exists,
# still captures output via command substitution regardless of the `||`
# beside it), and command substitution does not enforce errexit within its
# own subshell on this build. `|| rc=$?` is kept as the same explicit-
# contract hygiene get_labels' own comment describes, not as a fix for a
# reachable defect.
get_parent_epic() {
    local raw rc=0
    raw=$(bd show "$1" --json 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    printf '%s' "$raw" \
        | jq -r 'if type == "array" then .[0].parent else .parent end // ""' 2>/dev/null
}

# _grilling_comment_on <tid> — 0 when <tid> ITSELF (never a relative) carries a
# comment matching the FULL GRILLING v1 machine prefix; 1 otherwise, including
# on any read failure.
#
# QA R1-F1 (claude-workflow-plugin-fkm.5, reviewed_hash 1a0c9f53): the first
# version of this check was `startswith("GRILLING v1 ")` alone, MEASURED to
# accept a hand-posted comment reading exactly
# `GRILLING v1 totally informal, no counters, no vendor_hash` — design-record
# recorded over it. That is a lower forgery bar than every sibling reader:
# latest_design_artifact_hash captures a real `design_hash=` value,
# `approve` binds `change_set_hash=`, completion binds `payload_sha=` — each
# requires the forger to approximate a SHAPED field, not just twelve literal
# prefix characters. The anchored `test(...)` below requires the reader to
# see the SAME grammar the one real writer (cmd_grilling_record) always
# produces — four `[0-9]+` counters and a 64-hex `vendor_hash=`, in order,
# immediately before ` at ` — which is backward-compatible with every record
# the shipped writer has ever produced (it cannot emit anything else) and
# closes the forgery gap to the same bar the siblings already hold. This is
# also what makes the ERROR TEXT on `rounds_not_integer` et al. true: those
# messages say "the precondition reader parses [each counter] as [0-9]+" —
# before this fix that was false of THIS reader (which parsed nothing), and
# is genuinely true of it now.
#
# Still anchored at the START only (`^`, no trailing `$`) and never a
# substring test — the same reasoning latest_design_artifact_hash documents
# at length: agents quote record grammars in prose constantly (this very
# file's --help text is a standing example), and a quotation must not
# satisfy a precondition a real dialogue is supposed to gate. The free-text
# `<summary>` after `at <ts>: ` is deliberately UNconstrained here, same as
# every sibling reader leaves its own trailing prose unparsed.
_grilling_comment_on() {
    local tid="${1:-}" raw
    [ -n "$tid" ] || return 1
    raw=$(bd_show_with_comments "$tid") || return 1
    [ -n "$raw" ] || return 1
    printf '%s' "$raw" | jq -e '
        (if type == "array" then .[0].comments else .comments end) // []
# GRILLING-READER-GRAMMAR BEGIN (R1-F1)
        | any(.[]; .text | test(
            "^GRILLING v1 rounds=[0-9]+ questions=[0-9]+ approaches=[0-9]+ unresolved=[0-9]+ vendor_hash=[0-9a-f]{64} at "
          ))
# GRILLING-READER-GRAMMAR END (R1-F1)
    ' >/dev/null 2>&1
}

# grilling_record_exists <tid> — 0 when a `GRILLING v1 ` record exists on <tid>
# OR ON ITS PARENT EPIC; 1 otherwise, INCLUDING when bd or the task cannot be
# reached at all. FAIL-CLOSED, matching designer_touched_source's own choice
# for the identical reason (this function's own header, and the block below
# that calls it): an unestablished answer is not proof a grilling happened.
#
# The record carries no `iteration=` field and this reader does not ask
# "is the LATEST one still fresh" — unlike DESIGN-REVIEW's amendment
# discipline, a grilling is not re-validated against a later artifact hash by
# this check. It answers one question only: did AT LEAST ONE grilling happen
# on this task or its epic, ever. The vendor_hash each record carries is for a
# HUMAN auditor asking "was the method text current when this happened" —
# this precondition does not read it.
grilling_record_exists() {
    local tid="${1:-}"
    [ -n "$tid" ] || return 1
    command -v bd >/dev/null 2>&1 || return 1
    if _grilling_comment_on "$tid"; then
        return 0
    fi
    local parent
    parent=$(get_parent_epic "$tid") || parent=""
    [ -n "$parent" ] || return 1
    _grilling_comment_on "$parent"
}

# cmd_grilling_record — v5 D3 (claude-workflow-plugin-fkm.5).
#
#   grilling-record <task-id> --rounds <n> --questions <n> --approaches <n>
#                   --unresolved <n> '<summary>'
#
#   GRILLING v1 rounds=<n> questions=<n> approaches=<n> unresolved=<n>
#     vendor_hash=<h> at <ts>: <summary>
#
# Same validation-ladder shape as grade-record / design-review-record.
#
# WRITTEN BY THE ORCHESTRATOR, AT ROOT — it ran the dialogue this records.
# Nothing HERE checks that identity, and that is a considered choice rather
# than an omission: the record carries no `who=` field for a check to compare
# against, because there is no second identity in this picture the way
# designer/reviewer is a pair — only the orchestrator conducted the actual
# dialogue with the human, so only it can honestly state rounds/questions/
# approaches/unresolved. The structural guarantee is upstream of this script:
# designer.md's tool list omits Bash entirely, so the designer cannot invoke
# this subcommand at all, and no specialist prompt ever instructs one to.
#
# approaches >= 2 IS THE VENDORED METHOD'S OWN BAR (else insufficient_
# approaches) — .claude/vendor/superpowers/brainstorming/SKILL.md: "Propose
# 2-3 different approaches with trade-offs".
#
# vendor_hash IS NOT A FLAG — a caller cannot assert it, only this script can
# measure it. It is a live workflow-manifest.sh `hash-file` recompute over the
# vendored brainstorming SKILL.md, taken at record time: the SAME instrument
# design-record uses for the design artifact, under the SAME "continuous
# enforcement is the live recompute, not a label" doctrine. The point is
# naming WHICH METHOD TEXT was in force when the dialogue happened, so later
# drift in the vendored file cannot retroactively validate a dialogue that
# never followed it. This is a SEPARATE, orthogonal integrity claim from
# MANIFEST.md's own recorded hash (vendored-skills.test.sh section 13): that
# one asserts the MANIFEST is honest about the file's CURRENT bytes; this one
# asserts what a PAST dialogue's record saw. Neither reads the other.
cmd_grilling_record() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "grilling-record" "" "missing_task_id" \
            "grilling-record requires <task-id> as first positional argument" \
            "qa-gate.sh grilling-record <task-id> --rounds <n> --questions <n> --approaches <n> --unresolved <n> '<summary>'"
        exit 1
    fi
    shift || true

    local rounds="" questions="" approaches="" unresolved="" summary=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --rounds)
                rounds="${2:-}"
                if [ -z "$rounds" ]; then
                    emit_error_json "grilling-record" "$tid" "missing_rounds" \
                        "--rounds requires a value" \
                        "qa-gate.sh grilling-record $tid --rounds <n> --questions <n> --approaches <n> --unresolved <n> '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            --questions)
                questions="${2:-}"
                if [ -z "$questions" ]; then
                    emit_error_json "grilling-record" "$tid" "missing_questions" \
                        "--questions requires a value" \
                        "qa-gate.sh grilling-record $tid --rounds <n> --questions <n> --approaches <n> --unresolved <n> '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            --approaches)
                approaches="${2:-}"
                if [ -z "$approaches" ]; then
                    emit_error_json "grilling-record" "$tid" "missing_approaches" \
                        "--approaches requires a value" \
                        "qa-gate.sh grilling-record $tid --rounds <n> --questions <n> --approaches <n> --unresolved <n> '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            --unresolved)
                unresolved="${2:-}"
                if [ -z "$unresolved" ]; then
                    emit_error_json "grilling-record" "$tid" "missing_unresolved" \
                        "--unresolved requires a value" \
                        "qa-gate.sh grilling-record $tid --rounds <n> --questions <n> --approaches <n> --unresolved <n> '<summary>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            -h|--help) usage; exit 1 ;;
            *)
                if [ -z "$summary" ]; then summary="$1"; else summary="$summary $1"; fi
                shift || true
                ;;
        esac
    done

    require_bd "grilling-record" "$tid"

    # --- each counter: required, and a non-negative integer -----------------
    # This is a CLI argument — already a string, so there is no JSON "type" to
    # check first, unlike grade-record's iteration. Go straight to the shape
    # the machine prefix needs: [0-9]+, matching iteration_not_integer's own
    # reasoning (interpolated unguarded, a negative or fractional value would
    # write a record this file's own readers could not parse back).
    local field val
    for field in rounds questions approaches unresolved; do
        case "$field" in
            rounds) val="$rounds" ;;
            questions) val="$questions" ;;
            approaches) val="$approaches" ;;
            unresolved) val="$unresolved" ;;
        esac
        if [ -z "$val" ]; then
            emit_error_json "grilling-record" "$tid" "missing_$field" \
                "--$field is required" \
                "qa-gate.sh grilling-record $tid --rounds <n> --questions <n> --approaches <n> --unresolved <n> '<summary>'"
            exit 1
        fi
        case "$val" in
            ''|*[!0-9]*)
                emit_error_json "grilling-record" "$tid" "${field}_not_integer" \
                    "--$field='$val' is not a non-negative integer; it is interpolated into the GRILLING record's machine prefix, which the precondition reader parses as [0-9]+ — a negative or fractional value writes a record no reader can tell from absent" \
                    "qa-gate.sh grilling-record $tid --$field <non-negative integer>"
                exit 1
                ;;
        esac
    done

    # --- the vendored method's own bar --------------------------------------
    if [ "$approaches" -lt 2 ]; then
        emit_error_json "grilling-record" "$tid" "insufficient_approaches" \
            "approaches=$approaches is below the vendored brainstorming method's own bar of at least 2 (.claude/vendor/superpowers/brainstorming/SKILL.md: \"Propose 2-3 different approaches with trade-offs\"). Grill again — a genuine second approach, not a restatement of the first — before recording" \
            "qa-gate.sh grilling-record $tid --rounds <n> --questions <n> --approaches 2 --unresolved <n> '<summary>'"
        exit 1
    fi

    [ -n "$summary" ] || summary="grilling recorded"

    # --- vendor_hash: a live recompute, never a caller-supplied value -------
    local vendored_skill manifest_tool vendor_hash vh_rc=0
    vendored_skill="$PROJECT_DIR/.claude/vendor/superpowers/brainstorming/SKILL.md"
    manifest_tool="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
    if [ ! -f "$manifest_tool" ]; then
        emit_error_json "grilling-record" "$tid" "hash_tool_unavailable" \
            "cannot hash the vendored brainstorming method: workflow-manifest.sh is missing at $manifest_tool. FAILS CLOSED — a record that cannot name which method text was in force is a record the gate would trust for nothing" \
            "restore .claude/scripts/workflow-manifest.sh"
        exit 2
    fi
    vendor_hash=$(bash "$manifest_tool" hash-file "$vendored_skill" 2>/dev/null) || vh_rc=$?
    if [ "$vh_rc" -ne 0 ] || ! is_sha256_hex "$vendor_hash"; then
        emit_error_json "grilling-record" "$tid" "vendor_hash_unavailable" \
            "the vendored brainstorming method ($vendored_skill) could not be hashed into 64 hex characters (workflow-manifest.sh hash-file exited $vh_rc, produced '${vendor_hash:-<empty>}'). Refused rather than recorded with a placeholder, for the same reason design-record refuses an unhashable artifact: a degradation sentinel is CONSTANT and would compare equal to itself forever" \
            "bash .claude/scripts/workflow-manifest.sh hash-file $vendored_skill"
        exit 2
    fi

    # --- write ---------------------------------------------------------------
    assert_record_scalar "grilling-record" "$tid" "task" "$tid"

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="GRILLING v1 rounds=$rounds questions=$questions approaches=$approaches unresolved=$unresolved vendor_hash=$vendor_hash at $ts: $summary"
    add_comment "$tid" "$comment_text"
    emit_json 1 "grilling-record" "$tid" "recorded" \
        "comment posted at $ts: $comment_text"
}

# validate_design_envelope_ok <rc> <envelope> — did `review-check.sh
# validate-design` SUCCEED, judged by its WHOLE contract? True iff the
# validator exited 0 AND printed exactly the ok:true envelope, type-checked
# field by field.
#
# (xsu1 R7-F4) The three consumers below (design-record, design-unit-bind,
# design-conform step 3) all used to run the validator with `|| true` and
# compare `jq -r '.ok // false'` textually — which trusted (a) a shape-valid
# ok:true body from a validator that EXITED NONZERO (a command reporting its
# own failure out-of-band; epic-gate.sh's R4-F2/R5-F1 consumer ladder names
# why the parsed body cannot outrank the exit status), and (b) `"ok":"true"`
# — a JSON STRING — because `jq -r` renders it identically to the boolean.
# This helper is the ONE pattern for all three sites, mirroring epic-gate's
# ladder: rc first, then exact types for every field a consumer reads
# downstream (units number, unit_ids array, task_id string,
# unit_files/unit_deps/unit_content objects), with `.ok == true` type-strict
# in jq.
#
# unit_content (v5 D5 R4-F1 remediation, independent review round 4) joined
# this exact-match list the SAME cycle review-check.sh's OWN copy
# (emit_validate_design's shape_prog, VALIDATE-DESIGN-ENVELOPE-SHAPE-GATE)
# gained it. The two copies MUST agree: this helper does an EXACT `keys |
# sort` match, so a field added to the real validator's envelope without a
# matching addition here makes design-record/design-unit-bind/design-conform
# start refusing every otherwise-valid artifact — extending the envelope is
# only safe when both copies move together.
#
# A refusal envelope (ok:false + nonzero exit — the validator's NORMAL
# refusal shape) returns 1 here and each site's own refusal arm still reads
# error_key/observations out of the body for its message, exactly as
# before: this gate only decides SUCCESS, it never rewrites failure text.
validate_design_envelope_ok() {
    local rc="$1" envelope="$2"
# VALIDATE-DESIGN-CONSUMER-RC-GATE BEGIN (xsu1 R7-F4)
    # A validator that prints ok:true and exits nonzero said it failed;
    # believing the body over the status is the R7-F4 defect. Stripping
    # this region resurrects exactly that (the L1 META in
    # design-accessors.test.sh does, and watches a stub validator that
    # exits 3 get its binding recorded anyway).
    [ "$rc" -eq 0 ] || return 1
# VALIDATE-DESIGN-CONSUMER-RC-GATE END (xsu1 R7-F4)
    [ -n "$envelope" ] || return 1
    printf '%s' "$envelope" | jq -e '
        # validate-design consumer success-shape check (xsu1 R7-F4)
        type == "object"
        and (keys | sort) == ["error_key", "observations", "ok", "subcommand", "task_id", "unit_content", "unit_deps", "unit_files", "unit_ids", "units"]
        and .ok == true  # type-strict: the STRING "true" must not pass (R7-F4)
        and .subcommand == "validate-design"
        and (.error_key | type) == "string"
        and (.observations | type) == "string"
        and (.units | type) == "number"
        and (.unit_ids | type) == "array"
        and (.task_id | type) == "string"
        and (.unit_files | type) == "object"
        and (.unit_deps | type) == "object"
        and (.unit_content | type) == "object"
    ' >/dev/null 2>&1
}

cmd_design_record() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "design-record" "" "missing_task_id" \
            "design-record requires <task-id> as first positional argument" \
            "qa-gate.sh design-record <task-id> [--file <path>] [--designer <id>]"
        exit 1
    fi
    shift || true

    local artifact="" designer="designer" summary="" accept_foreign=0 foreign_reason=""
    local no_grilling=0 grilling_bypass_reason=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-grilling)
                grilling_bypass_reason="${2:-}"
                if [ -z "$grilling_bypass_reason" ]; then
                    emit_error_json "design-record" "$tid" "missing_grilling_bypass_reason" \
                        "--no-grilling requires a reason; it is recorded in the audit trail" \
                        "qa-gate.sh design-record $tid --no-grilling '<reason>'"
                    exit 1
                fi
                no_grilling=1
                shift 2 || true
                ;;
            --file)
                artifact="${2:-}"
                if [ -z "$artifact" ]; then
                    emit_error_json "design-record" "$tid" "missing_file_path" \
                        "--file requires a path argument" \
                        "qa-gate.sh design-record $tid --file <path>"
                    exit 1
                fi
                shift 2 || true
                ;;
            --designer)
                designer="${2:-}"
                if [ -z "$designer" ]; then
                    emit_error_json "design-record" "$tid" "missing_designer" \
                        "--designer requires an identity argument" \
                        "qa-gate.sh design-record $tid --designer <identity>"
                    exit 1
                fi
                shift 2 || true
                ;;
            --accept-foreign-paths)
                foreign_reason="${2:-}"
                if [ -z "$foreign_reason" ]; then
                    emit_error_json "design-record" "$tid" "missing_bypass_reason" \
                        "--accept-foreign-paths requires a reason; it is recorded in the audit trail" \
                        "qa-gate.sh design-record $tid --accept-foreign-paths '<reason>'"
                    exit 1
                fi
                accept_foreign=1
                shift 2 || true
                ;;
            -h|--help) usage; exit 1 ;;
            *)
                if [ -z "$summary" ]; then summary="$1"; else summary="$summary $1"; fi
                shift || true
                ;;
        esac
    done
    [ -n "$summary" ] || summary="design artifact recorded"

    require_bd "design-record" "$tid"

    # --- GRILLING-PRECONDITION -------------------------------------------
    # v5 D3 (claude-workflow-plugin-fkm.5). The design phase begins with a
    # grilling dialogue (.claude/vendor/superpowers/brainstorming/SKILL.md);
    # design-record refuses to bind an artifact for a task nobody grilled for.
    # THIS IS THE PRE-DELEGATION PATH AND IT IS A SCRIPT, so the check is
    # mechanical rather than living at Stop — the same reasoning the v4.1
    # closure gives for the brainstorming ceremony generally: a Stop-time
    # change-set classifier fires AFTER the work it would gate, and by the
    # time an implementer's Stop hook runs, the moment to have grilled is long
    # past. Checked here, first, before any of the containment/hash work below
    # — a task with no grilling record should fail fast on that, not on an
    # unrelated path or hash detail three checks later.
    #
    # Carve-out `--no-grilling '<reason>'` for the F1 doc-only class and the
    # single-line-typo path — the SAME two exemptions orchestrator.md already
    # names for skipping the brainstorming read (and therefore the whole
    # design phase) entirely, reused here for the rarer case where a design
    # record is still produced for work that fell under them.
# GRILLING-PRECONDITION BEGIN
    if [ "$no_grilling" != "1" ] && ! grilling_record_exists "$tid"; then
        emit_error_json "design-record" "$tid" "grilling_record_missing" \
            "no GRILLING v1 record exists on $tid or its parent epic. The design phase begins with a grilling dialogue (.claude/vendor/superpowers/brainstorming/SKILL.md); design-record refuses to bind an artifact nobody grilled for. Record it (run by the orchestrator, at root — it is the one that ran the dialogue): qa-gate.sh grilling-record $tid --rounds <n> --questions <n> --approaches <n> --unresolved <n> '<summary>'. For the F1 doc-only class or a genuinely single-line-typo-fix design, bypass instead: qa-gate.sh design-record $tid --no-grilling '<reason>'" \
            "qa-gate.sh grilling-record $tid --rounds <n> --questions <n> --approaches <n> --unresolved <n> '<summary>'"
        exit 1
    fi
# GRILLING-PRECONDITION END

    # --- the artifact is DERIVED; --file only ASSERTS that derivation --------
    #
    # `--file` IS AN ASSERTION, NOT AN INPUT (fkm.3 QA round 5, and the reason
    # this region stopped growing). Containment forces the artifact into
    # $DESIGN_SPEC_SUBDIR and the record's own soundness condition forces the
    # NAME to <tid>.md — the record carries the HASH and no path, which is only
    # sound while the path is derivable from the task id. So the only value the
    # argument can legitimately hold is the path this function already computes.
    #
    # Every hostile spelling four review rounds found here arrived through it —
    # R2-F1's `..` traversal, R2-F2's symlinked leaf, R4-F1's `..` after a
    # directory symlink, R5-F1's component named with a trailing newline, R5-F2's
    # second file named `<tid>.md\n`. None of them is filtered now; none can be
    # CARRIED. That is the difference between removing an input and hardening a
    # predicate, and it is why the predicate above is left doing the one job that
    # still HAS an attacker-supplied input: the TRACKER.
    #
    # It stays an argument because callers pass it and an explicit mismatch is a
    # better answer than silently recording something else. Two spellings are
    # accepted, both compared as STRINGS against values computed here and never
    # resolved: the absolute derived path, and its repo-relative spelling, which
    # is what a designer types and what designer.md's handoff block prints.
    local derived derived_rel
    derived=$(design_artifact_path_for "$tid")
    derived_rel="${derived#"$PROJECT_DIR"}"
    derived_rel="${derived_rel#/}"
    if [ -n "$artifact" ] && [ "$artifact" != "$derived" ] && [ "$artifact" != "$derived_rel" ]; then
        emit_error_json "design-record" "$tid" "artifact_path_not_derived" \
            "--file names '$artifact', which is not the artifact this task can record. The record carries the HASH and no path, so the path must be derivable from the task id: $derived, or its repo-relative spelling $derived_rel. --file ASSERTS that derivation; it cannot point the record at other bytes. Write the design there and pass it, or pass nothing" \
            "qa-gate.sh design-record $tid --file $derived"
        exit 1
    fi
    artifact="$derived"
    if ! ( cd -P "$PROJECT_DIR/$DESIGN_SPEC_SUBDIR" 2>/dev/null ); then
        emit_error_json "design-record" "$tid" "design_spec_dir_missing" \
            "the design spec directory does not exist at $PROJECT_DIR/$DESIGN_SPEC_SUBDIR, so no artifact can be under it. Create it and write the artifact to $derived" \
            "qa-gate.sh design-record $tid --file $derived"
        exit 1
    fi
    if [ ! -f "$artifact" ]; then
        emit_error_json "design-record" "$tid" "artifact_not_found" \
            "no design artifact at $artifact. The record binds a hash of the bytes on disk, so there is nothing to bind" \
            "qa-gate.sh design-record $tid --file $derived"
        exit 1
    fi
    # THE SAME PREDICATE THE TRACKER SCAN USES, so the two halves of the edit ban
    # cannot disagree about what "inside" means. Still load-bearing after the
    # argument was closed, because the derived path is a SPELLING and what sits
    # at it is not: `-f` above follows a leaf symlink, so
    # `docs/specs/<tid>.md -> ../../outside/x.md` would otherwise be hashed as
    # the outside file's bytes (measured; R2-F2).
    if ! design_path_is_contained "$artifact"; then
        emit_error_json "design-record" "$tid" "artifact_outside_spec_dir" \
            "the design artifact must live directly in $PROJECT_DIR/$DESIGN_SPEC_SUBDIR, and '$artifact' does not resolve to a file there — check whether it is a symlink out of the directory, or whether the directory itself has moved. A designer holding Write can create any file in the tree; this is the consequence that makes doing so unrecordable, and therefore ungateable, rather than a sandbox that prevents it" \
            "qa-gate.sh design-record $tid --file $derived"
        exit 1
    fi

    # --- designer_touched_source -------------------------------------------
    # Phase-scoped on the IMPLEMENTER record, read through review-check.sh — the
    # ONE record parser — rather than re-grepping the grammar here. `gate` exits
    # 4 with error_key=review_artifact_missing on a task with no review yet,
    # which is exactly this task's state, and that envelope still carries
    # latest_implementer_ts. The rc is therefore ignored and the KEY is read;
    # a MISSING key is UNESTABLISHED (review-check.sh's own contract says so) and
    # is treated as "cannot prove implementation has started", i.e. armed.
    local impl_ts="" impl_established=0
    if [ -f "$REVIEW_CHECK_SCRIPT" ]; then
        local rc_out
        rc_out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" gate "$tid" 2>/dev/null || true)
        if printf '%s' "$rc_out" | jq -e 'has("latest_implementer_ts")' >/dev/null 2>&1; then
            impl_established=1
            impl_ts=$(printf '%s' "$rc_out" | jq -r '.latest_implementer_ts // ""' 2>/dev/null || echo "")
        fi
    fi
    local foreign="" foreign_n=0 foreign_note=""
    if [ "$impl_established" = "1" ] && [ -n "$impl_ts" ]; then
        foreign_note="; designer_touched_source is OFF — an implementer has already spawned on this task (latest IMPLEMENTER record at $impl_ts), so source paths in the change set are the expected state"
    else
        # THE LEAF NAME IS THE SECOND ARGUMENT, and passing it is what makes the
        # tracker's question answerable without following a target (R6-F1). It is
        # taken from the DERIVED path by parameter expansion — never `basename`,
        # which is the class round 5 deleted from this region.
        local dfp_rc=0
        foreign=$(design_foreign_paths "${derived##*/}") || dfp_rc=$?
        # DESIGN-FOREIGN-READ-GUARD BEGIN (i8cx)
        if [ "$dfp_rc" -ne 0 ]; then
            emit_error_json "design-record" "$tid" "change_set_unreadable" \
                "the change-set tracker at $QA_TRACKING_DIR/changed-files.txt is non-empty but could NOT be read (design_foreign_paths rc=$dfp_rc), so whether the designer touched source paths is unknowable. Refusing to record: before i8cx this read failed to an empty set, which counted as foreign_n=0 and skipped the designer_touched_source refusal entirely. Fix the read (is sort on PATH and healthy? is the file readable?) and re-run" \
                "qa-gate.sh design-record $tid --file $derived"
            exit 2
        fi
        # DESIGN-FOREIGN-READ-GUARD END (i8cx)
        foreign_n=$(printf '%s' "$foreign" | grep -c . | tr -d ' \n')
        [ -n "$foreign_n" ] || foreign_n=0
        if [ "$foreign_n" -gt 0 ] && [ "$accept_foreign" != "1" ]; then
            emit_error_json "design-record" "$tid" "designer_touched_source" \
                "the change set holds $foreign_n path(s) that are not this task's design artifact ($DESIGN_SPEC_SUBDIR/${derived##*/}) and no IMPLEMENTER record exists on $tid$([ "$impl_established" = "1" ] || printf '%s' " (and the implementer question could not be answered at all, so it is treated as unstarted)"), so this design cannot be recorded over them: $(printf '%s' "$foreign" | head -12 | tr '\n' ' '). The design phase produces ONE file: a source path, a second file beside the artifact in $DESIGN_SPEC_SUBDIR/, and ANOTHER task's design artifact are all equally not this one. If those paths are someone else's session work rather than the designer's, say so and proceed: qa-gate.sh design-record $tid --accept-foreign-paths '<reason>'" \
                "qa-gate.sh design-record $tid --accept-foreign-paths '<reason>'"
            exit 1
        fi
        if [ "$foreign_n" -gt 0 ]; then
            foreign_note="; ACCEPTED $foreign_n foreign path(s) on the audited bypass"
        fi
    fi

    # --- the OPENING bracket of the record's read window --------------------
    # (fkm.3 QA round 2, R2-F3.) The record's whole claim is "these bytes are a
    # valid design". Validation and hashing are two SEPARATE opens of one path —
    # and the validator itself opens it a dozen times (one grep per required
    # section, two sentinel counts, an awk extraction). Nothing pinned the
    # content across any of that, and the consequence was reproduced rather than
    # reasoned about: with a writer landing between the validator's read and
    # hash-file's, design-record posted design_hash(B) where B was
    # schema-invalid (it re-validated as design_section_missing), and a later
    # approve — rehashing the same B — would report "design binding VERIFIED"
    # over bytes no validator ever accepted.
    #
    # So the bytes are BRACKETED: hashed here, hashed again after the validator
    # returns, and the record is refused unless the two agree. That covers the
    # validator's own repeated reads as well as the gap after them, which a
    # "hash once, then validate the same path" ordering would not.
    #
    # THE BRACKET CLOSES OVER CONTAINMENT TOO (fkm.3 QA round 3, R3-F4). The
    # first version of it bracketed only CONTENT, so replacing the leaf with a
    # symlink to a BYTE-IDENTICAL file outside the declared directory, inside
    # this window, left both hashes agreeing and produced a record over bytes
    # never shown to belong to the declared directory. So the closing bracket
    # re-runs the SAME predicate the opening containment check ran and compares
    # the two answers — two lines, the existing predicate, and the existing
    # error key. It does not make the window atomic (nothing check-then-use
    # can); it raises containment to the fidelity content already had, so the
    # residual below is ONE caveat covering both rather than two side by side.
    #
    # THE FAILURE IS DEFERRED, not reported here, so the ERROR KEYS keep their
    # order: an empty or unhashable artifact must still be named by the
    # validator (design_artifact_empty) rather than by the hasher, exactly as it
    # was before this bracket existed.
    #
    # WHAT IT DOES NOT CLOSE, stated rather than left for the next reviewer: an
    # A -> B -> A oscillation that restores the original state before the second
    # read, where the validator happened to see B — the same shape for the bytes
    # and for the directory entry. Both brackets then agree and the record binds
    # A. Closing that needs a snapshot the validator reads instead of the path,
    # which would put a temp path into every diagnostic the designer sees; the
    # exposure is a writer that can both time sub-second oscillation and restore
    # the exact original state, which is a smaller risk than a validator whose
    # error messages name a file the designer never wrote.
    #
    # THE SAME RESIDUAL HAS A SECOND, NARROWER INSTANCE (fkm.3 QA round 6,
    # R6-F3): `[ "$prev" -ef "$p" ]` in the containment walk is TWO stat calls,
    # so a replace landing between them is invisible to it. Only that case is
    # genuinely uncaught — a bind mount answers with a different st_dev and a
    # dangling target answers with nothing, both FALSE and therefore
    # fail-closed, and a hardlink answers TRUE, which is correct because the
    # same inode is the same bytes.
    local manifest_tool pre_hash="" pre_rc=0 hash_tool_missing=0
    manifest_tool="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
    if [ -f "$manifest_tool" ]; then
        pre_hash=$(bash "$manifest_tool" hash-file "$artifact" 2>/dev/null) || pre_rc=$?
    else
        hash_tool_missing=1
    fi

    # --- schema, through the ONE validator ---------------------------------
    if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
        emit_error_json "design-record" "$tid" "validator_unavailable" \
            "cannot record a design: the ONE validator is missing at $REVIEW_CHECK_SCRIPT, so the artifact cannot be schema-checked. FAILS CLOSED by design — an unvalidated record is one the gate would then trust" \
            "qa-gate.sh design-record $tid --file $artifact"
        exit 2
    fi
    local vout="" vout_rc=0 vkey vobs units
    vout=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" validate-design "$artifact" 2>/dev/null) || vout_rc=$?
    if ! validate_design_envelope_ok "$vout_rc" "$vout"; then
        vkey=$(printf '%s' "$vout" | jq -r '.error_key // "invalid_design_artifact"' 2>/dev/null || echo "invalid_design_artifact")
        [ -z "$vkey" ] && vkey="invalid_design_artifact"
        vobs=$(printf '%s' "$vout" | jq -r '.observations // ""' 2>/dev/null || echo "")
        emit_error_json "design-record" "$tid" "$vkey" \
            "the design artifact failed validation via review-check.sh (validator exit rc=$vout_rc): $vkey${vobs:+ — $vobs}" \
            "see review-check.sh validate-design $artifact"
        exit 1
    fi
    units=$(printf '%s' "$vout" | jq -r '.units // 0' 2>/dev/null || echo "0")
    case "$units" in ''|*[!0-9]*) units="0" ;; esac

    # --- the artifact's own task_id must be this task -----------------------
    # The decoy check completion-record documents, in its design form: a record
    # on task B binding an artifact whose units name task A would send every
    # downstream reader to the wrong design.
    #
    # READ OFF THE VALIDATOR'S ENVELOPE, never re-extracted here. An awk/sed pass
    # over the DESIGN-UNITS block in this file would be a SECOND parser for one
    # grammar — precisely what review-check.sh exists to prevent, and what its
    # header and the F1 counting note both say in as many words.
    local art_tid
    art_tid=$(printf '%s' "$vout" | jq -r '.task_id // ""' 2>/dev/null || echo "")
    if [ -n "$art_tid" ] && [ "$art_tid" != "$tid" ]; then
        emit_error_json "design-record" "$tid" "artifact_task_id_mismatch" \
            "the artifact's own task_id='$art_tid' is not the task being recorded ('$tid')" \
            "qa-gate.sh design-record $art_tid --file $artifact"
        exit 1
    fi

    # --- the hash, and the proof it names the bytes that were validated ------
    # Delegated to workflow-manifest.sh `hash-file`, which refuses BEFORE hashing
    # on a missing, unreadable or EMPTY path. That ordering is the point: zero
    # bytes digest to e3b0c442…, which is 64 valid hex, constant across calls,
    # and identical to the empty change set's hash — so a binding taken over an
    # absent artifact would compare EQUAL to itself forever and every "the
    # binding must fail" assertion downstream would pass vacuously.
    local design_hash post_hash="" post_rc=0
    if [ "$hash_tool_missing" = "1" ]; then
        emit_error_json "design-record" "$tid" "hash_tool_unavailable" \
            "cannot hash the design artifact: workflow-manifest.sh is missing at $manifest_tool. FAILS CLOSED — a record without a real binding is a record the gate would trust for nothing" \
            "restore .claude/scripts/workflow-manifest.sh"
        exit 2
    fi
    if [ "$pre_rc" -ne 0 ] || ! is_sha256_hex "$pre_hash"; then
        emit_error_json "design-record" "$tid" "design_hash_unavailable" \
            "the design artifact could not be hashed into 64 hex characters (workflow-manifest.sh hash-file exited $pre_rc, produced '${pre_hash:-<empty>}'). Refused rather than recorded with a placeholder: a degradation sentinel is CONSTANT, so it compares equal to itself and to every other artifact, and the binding becomes unfailable" \
            "bash .claude/scripts/workflow-manifest.sh hash-file $artifact"
        exit 2
    fi
    # THE CLOSING BRACKET. Same call, after the validator has finished reading.
    post_hash=$(bash "$manifest_tool" hash-file "$artifact" 2>/dev/null) || post_rc=$?
    if [ "$post_rc" -ne 0 ] || ! is_sha256_hex "$post_hash"; then
        emit_error_json "design-record" "$tid" "design_hash_unavailable" \
            "the design artifact hashed cleanly before validation and could NOT be hashed after it (workflow-manifest.sh hash-file exited $post_rc, produced '${post_hash:-<empty>}'). Something changed the artifact while this command was reading it; nothing is recorded" \
            "bash .claude/scripts/workflow-manifest.sh hash-file $artifact"
        exit 2
    fi
    if [ "$post_hash" != "$pre_hash" ]; then
        emit_error_json "design-record" "$tid" "design_artifact_changed_during_record" \
            "the design artifact changed WHILE it was being recorded: it hashed $pre_hash before validation and $post_hash after it. The record would have bound bytes the validator never saw, so nothing is recorded. Re-run once the artifact has stopped moving" \
            "qa-gate.sh design-record $tid --file $artifact"
        exit 1
    fi
    # THE CONTAINMENT HALF OF THE SAME BRACKET. Identical bytes at a path that
    # has moved OUT of the declared directory pass every check above. Re-ASKING
    # the predicate is the same guarantee the old two-answers comparison gave —
    # there is only one declared directory, so "still contained" and "contained
    # where it was" are one statement — without carrying a path across the
    # window in a variable to make it.
    if ! design_path_is_contained "$artifact"; then
        emit_error_json "design-record" "$tid" "design_artifact_changed_during_record" \
            "the design artifact MOVED while it was being recorded: '$artifact' resolved INSIDE $PROJECT_DIR/$DESIGN_SPEC_SUBDIR before validation and does not after it. The record would have bound bytes never established as the declared directory's, so nothing is recorded. Re-run once the artifact has stopped moving" \
            "qa-gate.sh design-record $tid --file $artifact"
        exit 1
    fi
    design_hash="$pre_hash"

    # --- write ---------------------------------------------------------------
    # Every scalar interpolated into the one-line record passes the bjx grammar
    # guard. `design_hash` is ours, and is checked anyway — "this value is ours"
    # is exactly the assumption bjx's rubric_version shipped on.
    assert_record_scalar "design-record" "$tid" "task" "$tid"
    assert_record_scalar "design-record" "$tid" "designer" "$designer"
    assert_record_scalar "design-record" "$tid" "design_hash" "$design_hash"
    assert_record_scalar "design-record" "$tid" "units" "$units"

    # The bracketed suffix carries FREE-TEXT AUDIT PROSE and nothing a program
    # compares — the distinction ruling 1 of this phase turns on. `$summary` is
    # unvalidated positional text sitting on the same line, so a value the gate
    # must TRUST cannot live in that space; `design_hash` is a machine token
    # before the timestamp for precisely that reason.
    local record_suffix=""
    [ "$accept_foreign" = "1" ] && record_suffix="$record_suffix [foreign paths accepted: $foreign_reason]"
    [ "$no_grilling" = "1" ] && record_suffix="$record_suffix [grilling bypass: $grilling_bypass_reason]"

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="DESIGN-ARTIFACT v1 task=$tid designer=$designer design_hash=$design_hash units=$units at $ts: $summary$record_suffix"
    add_comment "$tid" "$comment_text"
    emit_json 1 "design-record" "$tid" "recorded" \
        "comment posted at $ts: $comment_text; artifact $artifact bound at design_hash=$design_hash over its RAW BYTES (reproduce with: shasum -a 256 $artifact)$foreign_note"
}

# latest_design_artifact_hash <tid> — the design_hash of the LAST
# `DESIGN-ARTIFACT v1 ` record on the task, or empty.
#
# `startswith("DESIGN-ARTIFACT v1 ")` rather than a substring search, for the
# reason latest_completion_record and review-check.sh's ROUNDS block both
# document at length: agents QUOTE record grammars in comments constantly, and a
# prose mention must not be able to satisfy a binding. The token is read with a
# SINGLE anchored capture carrying the SAME character class the writer validated
# — `[A-Za-z0-9-]`, the class every other hash reader in this workflow uses
# (verify-before-stop.sh's change_set_hash captures) — so writer and reader
# cannot diverge in a way only a live record would reveal.
#
# THE TWO GUARDS ARE REDUNDANT BY CONSTRUCTION, NOT HALF-TESTED, and a mutation
# run will say so: removing either the startswith() filter or the `^` in the
# capture reddens NOTHING, because startswith guarantees the anchor position the
# `^` re-asserts over the same single-line string. Redundancy that survives
# single-point removal is what a guard should look like; making each
# individually load-bearing would mean each covers a case the other does not,
# i.e. LESS overlap and more holes. THE CAVEAT, because it is the thing a future
# edit can break silently: the redundancy holds only while BOTH read the SAME
# string. Let the filter see one value and the capture another — a pre-processed
# variable, a joined multi-line body — and this stops being two guards and
# becomes one, with no test change to announce it.
#
# Never fails the caller: no bd, no task, unparseable JSON -> empty, rc 0.
latest_design_artifact_hash() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    command -v bd >/dev/null 2>&1 || return 0
    bd_show_with_comments "$tid" \
        | jq -r '
            [ (if type == "array" then .[0].comments else .comments end) // []
              | .[].text
              | select(startswith("DESIGN-ARTIFACT v1 "))
              | ( [ capture("^DESIGN-ARTIFACT v1 task=[A-Za-z0-9._+-]+ designer=[A-Za-z0-9._+-]+ design_hash=(?<h>[A-Za-z0-9-]+) ") ]
                  | first | .h? // "" )
              | select(. != "")
            ]
            | last // ""
        ' 2>/dev/null || true
    return 0
}
# DESIGN-ARTIFACT END (v5 Phase D1 / claude-workflow-plugin-fkm.3)

# ---------------------------------------------------------------------------
# DESIGN-REVIEW BEGIN (v5 D2 / claude-workflow-plugin-fkm.4)
#
# design-review-record <tid> --design-hash <sha256> [--file <path>]
#
# THE DESIGN REVIEWER'S RECORD: D1's own split made good on. D1's comment at
# the top of the DESIGN-ARTIFACT block above says the verdict "is D2's own
# record, with its own grammar, its own author and its own lifetime" —
# `design-record` states WHO the designer was and WHAT bytes they produced;
# this states WHO reviewed it and WHETHER it passed.
#
#   DESIGN-REVIEW v1 task=<tid> reviewer=<id> verdict=<satisfied|needs_revision>
#     design_hash=<h> iteration=<n> rubric_version=<v> at <ts>: <summary>[ [amends: <prev-h>]]
#
# Same house shape as DESIGN-ARTIFACT / REVIEW-ARTIFACT / COMPLETION: machine
# prefix first, ` at <ISO-8601-UTC>` last before the colon, free text after.
# The new token this phase ALSO adds — `design_verdict_hash=` — goes on the
# APPROVAL record, not here; see cmd_approve's DESIGN-SATISFIED-REFUSAL.
#
# INPUT SHAPE MIRRORS cmd_grade_record's required-key loop and record grammar
# almost exactly (the code rubric's verdict has no notion of "who reviewed",
# because the grader's own identity is never independence-checked against
# anything — the design reviewer's IS, against `designer=`, so this record
# carries one more required key: `reviewer_identity`). No second parser: this
# validates the VERDICT's shape inline, the same way grade-record does for
# the code rubric's verdict — there is no "review-check.sh validate-X" for
# either, because neither is a document with its own file-based schema the
# way the design ARTIFACT is (that one already has validate-design, and nor
# does the design artifact get re-validated here — see the --design-hash note
# just below for why this record does not re-open the artifact at all).
#
# --design-hash IS REQUIRED AND IS A CLAIM, NOT A RECOMPUTE — deliberately the
# SAME choice grade-record made for --graded-hash, and for the same reason
# stated on that flag above: "the change set the grader ACTUALLY saw ... a
# recompute at record time is not the same thing". Recomputing
# docs/specs/<tid>.md's live hash HERE would bind whatever the artifact
# happens to be AT RECORD TIME, which is not necessarily what the reviewer
# actually read — a designer edit landing between the reviewer's spawn and
# this call would silently rebind the verdict to bytes nobody reviewed. The
# caller (the root-orchestrated relay) supplies the hash it handed the
# reviewer in the packet — ordinarily `latest_design_artifact_hash <tid>`,
# read right before the reviewer spawns. Validated for SHAPE only
# (is_sha256_hex): a claim about which bytes were reviewed is not verified
# against anything at record time, exactly as --graded-hash is not; the
# STALENESS check (does this still match what is on disk NOW) is
# compute_design_satisfied's job, at approve/precheck time, the same split
# DESIGN-BINDING-TOKEN already draws for design-record's own artifact.
#
# --design-hash IS REQUIRED, UNLIKE --graded-hash, and that divergence is
# deliberate rather than an oversight: an unbound rubric verdict is a legal,
# audited state (qa.md 6f: "the rubric is a QA INPUT", never a hard gate,
# so grade-record may record one unbound and let `enter` treat it as stale).
# This record IS meant to gate — AC 4.5/4.6 ask cmd_approve to REFUSE without
# a fresh, bound one — so "recorded but unbound" is not an acceptable state
# to write here at all; refusing at record time is the fail-closed choice.
#
# INDEPENDENCE IS ENFORCED HERE, AT RECORD TIME, NOT AT APPROVE TIME (AC 4.4).
# A verdict whose reviewer_identity equals the designer= on the task's latest
# DESIGN-ARTIFACT record is refused before it is ever written — the record
# never exists for cmd_approve to have to reason about, and
# compute_design_satisfied therefore never re-checks independence at all.
# This mirrors D1's own choice to phase-scope designer_touched_source at
# RECORD time rather than at approve time: catch the defect where it
# originates. Fails closed on an UNESTABLISHED designer identity too — no
# DESIGN-ARTIFACT record at all means there is nothing to check independence
# against, so recording a verdict would certify independence nobody
# verified (the same "unestablished is not permissive" rule
# designer_touched_source states for its own phase gate, above).
#
# STRING EQUALITY, NOT A ROLE-MEMBERSHIP TEST (OQ 6.1, resolved by
# measurement at fkm.4 Part A): `reviewer_identity` is fixed to the literal
# "design-claude" (design-reviewer.md) and `designer=` defaults to the
# literal "designer" (cmd_design_record above) — textually distinct,
# confirmed by Part A's own diff. review-check.sh's cmd_gate independence
# computation is NOT reusable here (the audited scope's own measurement: it
# is a membership test against IMPLEMENTER ROLE TOKENS and returns
# `independent:true` vacuously for any non-role identity) — what is reusable
# is the SHAPE (build the comparator, test it, refuse and name it), not the
# computation itself.
#
# AMENDMENTS (B2): the SAME subcommand records again at `iteration=n+1`
# against an artifact revised in place — design_hash moves because the
# Revision log gained a row, never because a second `<!-- DESIGN-UNITS -->`
# block was merged in (review-check.sh's validate-design refuses that
# structurally; see its own header, and D1's design-record, which re-runs
# it on every record). Two structural facts enforced here, not options:
#   * a NEW record's iteration must be GREATER than the latest recorded one
#     for this task, or the record is refused — "a second record at the same
#     iteration" is exactly the misbehaviour the pairing plan (P6) names.
#   * when a PRIOR record exists and its design_hash differs from this one,
#     the bracketed suffix carries `[amends: <prev-design-hash>]` — free-text
#     audit prose, the same shape design-record's own `record_suffix` is,
#     never a value a program compares (the trust boundary is the colon,
#     same as every other record in this file).
# `--file` on D1's design-record is an ASSERTION, not an input (the path is
# always derived) — this subcommand needs no analogous flag at all: it binds
# a HASH, supplied by the caller, never a path, so there is no "artifact
# path" question here to assert or derive.

# latest_design_artifact_designer <tid> — the designer= of the LAST
# `DESIGN-ARTIFACT v1 ` record on the task, or empty. Byte-identical shape to
# latest_design_artifact_hash above (same startswith() filter, same single
# anchored capture — first and last cannot diverge because there is only one
# regex), differing only in which named group it returns.
#
# FAILURE CHANNEL (xsu1 H2-F5): empty output + rc 0 means "the comment stream
# was READ AND PARSED and carries no DESIGN-ARTIFACT record" — a determined
# absence. rc 3 (no stdout) means the source could not be read at all: bd is
# not on PATH, both `bd show` forms failed (task unreadable or nonexistent),
# the returned JSON did not parse, or (xsu1 H2R2-F1) the response did not
# PROVABLY carry the comment stream — design_comments_json owns that proof
# rule. The two used to be conflated (rc 0,
# empty, always), which let compute_design_satisfied report a broken bd as
# `no_design_attempted` — and design-gate-precheck maps THAT key to "ready".
# Callers that keep the old fail-open semantics do so explicitly at their own
# call site (`|| designer_identity=""` — design-review-record's independence
# check, where empty already REFUSES with design_artifact_record_missing, so
# the conflation there is fail-closed either way).
latest_design_artifact_designer() {
    local tid="$1"
    local comments="" c_rc=0
    comments=$(design_comments_json "$tid") || c_rc=$?
    [ "$c_rc" -eq 0 ] || return 3
    local out="" out_rc=0
    out=$(printf '%s' "$comments" \
        | jq -r '
            [ .[].text
              | select(startswith("DESIGN-ARTIFACT v1 "))
              | ( [ capture("^DESIGN-ARTIFACT v1 task=[A-Za-z0-9._+-]+ designer=(?<d>[A-Za-z0-9._+-]+) design_hash=[A-Za-z0-9-]+ ") ]
                  | first | .d? // "" )
              | select(. != "")
            ]
            | last // ""
        ' 2>/dev/null) || out_rc=$?
    [ "$out_rc" -eq 0 ] || return 3
    printf '%s' "$out"
    return 0
}

# latest_design_review <tid> — JSON {reviewer, verdict, design_hash,
# iteration, rubric_version} from the LAST `DESIGN-REVIEW v1 ` comment on the
# task, or `{}` when none exists. ONE anchored capture over every field the
# two callers below need (cmd_design_review_record's own amendment check, and
# compute_design_satisfied's staleness ladder) — not five separate greps —
# so no caller can read one field from a different underlying match than
# another.
#
# FAILURE CHANNEL (xsu1 H2R2-F3): `{}` + rc 0 means the comment stream was
# retrieved (design_comments_json's proof rule) and carries no matching
# DESIGN-REVIEW record — a determined "never reviewed". rc 3 with NO stdout
# means the answer is NOT determined: bd absent, both `bd show` forms failed,
# the comment stream not provably retrieved, the selector's own jq failed, or
# the selected record read back as neither `{}` nor a complete five-field
# object in the writer's own classes (the union-shape check below — a
# selective jq failure must not hand a consumer a partial record it then
# splits into empty fields). The old contract ("never fails the caller:
# ... -> `{}`, rc 0") let compute_design_satisfied report a failed read as
# design_verdict_missing, and — worse — let cmd_design_review_record skip its
# iteration-advance comparison over an erased prior_iter and write a
# duplicate or non-advancing verdict. Both consumers now refuse on rc 3 at
# their own call sites. A malformed COMMENT is still a determined answer (the
# anchored capture drops it, exactly as before — design-review-record.test.sh
# 7.3f depends on that); rc 3 is only for a read that did not happen.
latest_design_review() {
    local tid="$1"
    local comments="" c_rc=0
    comments=$(design_comments_json "$tid") || c_rc=$?
    [ "$c_rc" -eq 0 ] || return 3
    local out="" out_rc=0
    out=$(printf '%s' "$comments" \
        | jq -c '
            # latest-design-review record selector (xsu1 H2R2-F3)
            [ .[].text
              | select(startswith("DESIGN-REVIEW v1 "))
              | capture("^DESIGN-REVIEW v1 task=[A-Za-z0-9._+-]+ reviewer=(?<reviewer>[A-Za-z0-9._+-]+) verdict=(?<verdict>[A-Za-z_]+) design_hash=(?<design_hash>[A-Za-z0-9-]+) iteration=(?<iteration>[0-9]+) rubric_version=(?<rubric_version>[A-Za-z0-9._+-]+) ")
            ]
            | last // {}
        ' 2>/dev/null) || out_rc=$?
    if [ "$out_rc" -ne 0 ] || [ -z "$out" ]; then
        return 3
    fi
    # THE UNION-SHAPE CHECK: exactly `{}`, or exactly the five captured
    # fields with writer-compatible classes. capture() already guarantees
    # this for any well-formed stream, so a failure here can only be a jq
    # malfunction mid-run — an UNREADABLE read, never a determined answer.
    # iteration is a digit STRING (capture yields strings); both consumers
    # already treat it as one.
    printf '%s' "$out" | jq -e '
        # latest-design-review union-shape check (xsu1 H2R2-F3)
        if type != "object" then false
        elif . == {} then true
        else ( (keys | sort) == ["design_hash", "iteration", "reviewer", "rubric_version", "verdict"]
               and (.reviewer       | type == "string" and test("^[A-Za-z0-9._+-]+$"))
               and (.verdict        | type == "string" and test("^[A-Za-z_]+$"))
               and (.design_hash    | type == "string" and test("^[A-Za-z0-9-]+$"))
               and (.iteration      | type == "string" and test("^[0-9]+$"))
               and (.rubric_version | type == "string" and test("^[A-Za-z0-9._+-]+$")) )
        end
    ' >/dev/null 2>&1 || return 3
    printf '%s' "$out"
    return 0
}

# compute_design_satisfied <tid> — THE ONE PREDICATE, consulted by
# cmd_approve's DESIGN-SATISFIED-REFUSAL AND by cmd_design_gate_precheck (B5):
# whichever asks, the answer is computed once, here. Sets globals (never
# prints): DESIGN_SATISFIED (true|false), DESIGN_SATISFIED_KEY (empty when
# true), DESIGN_SATISFIED_OBS (a full sentence, never empty; names the
# reviewer inline — neither current caller needs it as a separate field, so
# there is no DESIGN_VERDICT_REVIEWER global to drift out of sync with it),
# DESIGN_VERDICT_HASH. Never fails the caller.
#
# STATUS VOCABULARY (DESIGN_SATISFIED_KEY when DESIGN_SATISFIED=false):
#   no_design_attempted        no DESIGN-ARTIFACT record at all exists for
#                              this task. cmd_approve treats this the SAME as
#                              every other non-satisfied key — it still
#                              refuses, and --no-design is the audited exit,
#                              mirroring completion_record_missing's own
#                              unconditional-plus-bypass shape. Precheck (B5)
#                              treats it specially: see that function's own
#                              header for why that split is deliberate.
#   design_verdict_missing     a DESIGN-ARTIFACT record exists (so a designer
#                              identity is known) but no DESIGN-REVIEW v1
#                              record has ever been written for this task.
#   design_not_satisfied       the latest DESIGN-REVIEW verdict is
#                              needs_revision (or unreadable).
#   design_hash_unreadable     the latest satisfied verdict's design_hash is
#                              not 64 hex characters — the writer refuses
#                              that shape, so this names a record this tool
#                              did not write.
#   design_artifact_unreadable docs/specs/<tid>.md is missing, resolves
#                              outside the declared directory, or could not
#                              be hashed right now.
#   design_verdict_stale       the artifact's LIVE hash differs from the
#                              satisfied verdict's design_hash — the design
#                              moved after the review that approved it.
#   design_source_unreadable   (xsu1 H2-F5) the Beads comment stream for
#                              this task could not be read AT ALL right now
#                              (bd absent, both `bd show` forms failed,
#                              unparseable JSON, or — H2R2-F1 — a response
#                              that did not provably carry the comment
#                              stream), so whether a design was ever
#                              attempted is UNKNOWN, not "no". Since
#                              H2R2-F3 the same key also covers the
#                              DESIGN-REVIEW history read failing after a
#                              successful designer read (the second guard
#                              inside compute_design_satisfied) — a failed
#                              verdict read is not design_verdict_missing.
#                              Every
#                              caller stays fail-closed on this key exactly
#                              as on the others (approve refuses, precheck's
#                              no_design_attempted leniency does NOT apply,
#                              design-conform propagates it verbatim), and
#                              design-status additionally maps it to
#                              ok:false + exit 2 so a consumer can tell an
#                              unreadable source from a determined answer.
compute_design_satisfied() {
    local tid="$1"
    DESIGN_SATISFIED="false"
    DESIGN_SATISFIED_KEY=""
    DESIGN_SATISFIED_OBS=""
    DESIGN_VERDICT_HASH=""

    local designer_identity="" designer_rc=0
    designer_identity=$(latest_design_artifact_designer "$tid") || designer_rc=$?
    # DESIGN-SOURCE-UNREADABLE GUARD BEGIN (xsu1 H2-F5)
    # Without this arm, a bd that cannot be read collapses into the empty
    # string below and reports `no_design_attempted` — ordinary absence —
    # which design-gate-precheck then maps to "ready". The L1 META
    # (design-accessors.test.sh) strips this region and watches exactly that
    # masquerade come back. Do not rename the sentinels.
    if [ "$designer_rc" -ne 0 ]; then
        DESIGN_SATISFIED_KEY="design_source_unreadable"
        DESIGN_SATISFIED_OBS="the Beads comment stream for $tid could not be read right now (bd unavailable, task unreadable, or unparseable comments), so whether a design was ever recorded is unknown; refusing to report this as ordinary no-design absence"
        return 0
    fi
    # DESIGN-SOURCE-UNREADABLE GUARD END (xsu1 H2-F5)
    if [ -z "$designer_identity" ]; then
        DESIGN_SATISFIED_KEY="no_design_attempted"
        DESIGN_SATISFIED_OBS="no DESIGN-ARTIFACT record exists for $tid; no design has been recorded for this task"
        return 0
    fi

    local review_json="" review_rc=0 reviewer verdict design_hash
    review_json=$(latest_design_review "$tid") || review_rc=$?
    # DESIGN-REVIEW-SOURCE-UNREADABLE GUARD BEGIN (xsu1 H2R2-F3)
    # The designer read above succeeded, so a failure HERE is a second,
    # independent read failing (bd dying between the two calls, or a fault
    # confined to this reader's own jq). Without this arm the old
    # `|| review_json="{}"` fell through to reviewer="" and reported
    # design_verdict_missing — a DETERMINED verdict-absence claim about a
    # history that was never actually read. Same key as the designer arm
    # (both mean "the Beads comment stream could not be read right now"),
    # distinct observation so an operator can see WHICH read failed. The L1
    # META (design-accessors.test.sh) strips this region and watches exactly
    # that masquerade come back. Do not rename the sentinels.
    if [ "$review_rc" -ne 0 ]; then
        DESIGN_SATISFIED_KEY="design_source_unreadable"
        DESIGN_SATISFIED_OBS="the DESIGN-REVIEW history for $tid could not be read right now (the DESIGN-ARTIFACT read succeeded but the verdict read did not: bd became unreachable, the comment stream was not retrievable, or the latest record read back malformed), so whether a satisfied verdict exists is unknown; refusing to report this as design_verdict_missing"
        return 0
    fi
    # DESIGN-REVIEW-SOURCE-UNREADABLE GUARD END (xsu1 H2R2-F3)
    reviewer=$(printf '%s' "$review_json" | jq -r '.reviewer // ""' 2>/dev/null || echo "")
    verdict=$(printf '%s' "$review_json" | jq -r '.verdict // ""' 2>/dev/null || echo "")
    design_hash=$(printf '%s' "$review_json" | jq -r '.design_hash // ""' 2>/dev/null || echo "")
    if [ -z "$reviewer" ]; then
        DESIGN_SATISFIED_KEY="design_verdict_missing"
        DESIGN_SATISFIED_OBS="a DESIGN-ARTIFACT record exists on $tid (designer=$designer_identity) but no DESIGN-REVIEW v1 verdict has been recorded"
        return 0
    fi
    if [ "$verdict" != "satisfied" ]; then
        DESIGN_SATISFIED_KEY="design_not_satisfied"
        DESIGN_SATISFIED_OBS="the latest DESIGN-REVIEW verdict for $tid is verdict=${verdict:-<unreadable>} (reviewer=$reviewer), not satisfied"
        return 0
    fi
    if [ -z "$design_hash" ] || ! is_sha256_hex "$design_hash"; then
        DESIGN_SATISFIED_KEY="design_hash_unreadable"
        DESIGN_SATISFIED_OBS="the latest satisfied DESIGN-REVIEW verdict for $tid carries no readable 64-hex design_hash ('${design_hash:-<empty>}')"
        return 0
    fi

    local artifact_path live_hash hash_rc=0
    artifact_path=$(design_artifact_path_for "$tid")
    if [ ! -f "$artifact_path" ] || ! design_path_is_contained "$artifact_path"; then
        DESIGN_SATISFIED_KEY="design_artifact_unreadable"
        DESIGN_SATISFIED_OBS="the design artifact for $tid is not currently readable at $artifact_path (missing, or resolves outside $DESIGN_SPEC_SUBDIR/), so the satisfied verdict's design_hash=$design_hash cannot be corroborated"
        return 0
    fi
    live_hash=$(bash "$PROJECT_DIR/.claude/scripts/workflow-manifest.sh" hash-file "$artifact_path" 2>/dev/null) || hash_rc=$?
    if [ "$hash_rc" -ne 0 ] || ! is_sha256_hex "$live_hash"; then
        DESIGN_SATISFIED_KEY="design_artifact_unreadable"
        DESIGN_SATISFIED_OBS="$artifact_path could not be hashed now (rc=$hash_rc), so the satisfied verdict's design_hash=$design_hash cannot be corroborated against the bytes on disk"
        return 0
    fi
    if [ "$live_hash" != "$design_hash" ]; then
        DESIGN_SATISFIED_KEY="design_verdict_stale"
        DESIGN_SATISFIED_OBS="the design artifact has CHANGED since the satisfied verdict was recorded (verdict design_hash=$design_hash, on disk now=$live_hash); it needs a fresh review of the current revision"
        return 0
    fi

    DESIGN_SATISFIED="true"
    DESIGN_VERDICT_HASH="$design_hash"
    DESIGN_SATISFIED_OBS="design-satisfied verified (reviewer=$reviewer; verdict=satisfied; design_hash=$design_hash matches $artifact_path on disk)"
    return 0
}

cmd_design_review_record() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "design-review-record" "" "missing_task_id" \
            "design-review-record requires <task-id> as first positional argument" \
            "qa-gate.sh design-review-record <task-id> --design-hash <sha256> [--file <path>]"
        exit 1
    fi
    shift || true

    local input_path="" design_hash_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --file)
                input_path="${2:-}"
                if [ -z "$input_path" ]; then
                    emit_error_json "design-review-record" "$tid" "missing_file_path" \
                        "--file requires a path argument" \
                        "qa-gate.sh design-review-record $tid --design-hash <sha256> --file <path>"
                    exit 1
                fi
                shift 2 || true
                ;;
            --design-hash)
                design_hash_arg="${2:-}"
                if [ -z "$design_hash_arg" ]; then
                    emit_error_json "design-review-record" "$tid" "missing_design_hash" \
                        "--design-hash requires a value" \
                        "qa-gate.sh design-review-record $tid --design-hash <sha256> [--file <path>]"
                    exit 1
                fi
                shift 2 || true
                ;;
            -h|--help) usage; exit 1 ;;
            *)
                emit_error_json "design-review-record" "$tid" "unknown_flag" \
                    "unknown argument: $1 (expected --design-hash <sha256>, --file <path>, or stdin)" \
                    "qa-gate.sh design-review-record $tid --design-hash <sha256> [--file <path>]"
                exit 1
                ;;
        esac
    done

    require_bd "design-review-record" "$tid"

    # --design-hash IS REQUIRED — see the block header for why this diverges
    # from grade-record's OPTIONAL --graded-hash: an unbound design verdict
    # cannot support the hard refusal AC 4.5/4.6 ask cmd_approve to enforce,
    # so "recorded but unbound" is not an acceptable state to write here the
    # way it is for the rubric (qa.md 6f: the rubric is a QA INPUT, never a
    # hard gate — this record IS meant to gate).
    if [ -z "$design_hash_arg" ]; then
        emit_error_json "design-review-record" "$tid" "missing_design_hash" \
            "--design-hash requires the sha256 hash of the design artifact this verdict reviewed — ordinarily latest_design_artifact_hash's value at the moment the reviewer was spawned, or a fresh workflow-manifest.sh hash-file docs/specs/$tid.md. A verdict recorded with no hash binding could never be checked for staleness later, so it is refused rather than recorded unbound" \
            "qa-gate.sh design-review-record $tid --design-hash <sha256> --file <path>"
        exit 1
    fi
    if ! is_sha256_hex "$design_hash_arg"; then
        emit_error_json "design-review-record" "$tid" "design_hash_invalid" \
            "--design-hash='$design_hash_arg' is not 64 hex characters, so it names no reproducible bytes. Never a placeholder — pass the value workflow-manifest.sh hash-file printed" \
            "qa-gate.sh design-review-record $tid --design-hash <sha256> --file <path>"
        exit 1
    fi

    local raw=""
    if [ -n "$input_path" ]; then
        if [ ! -f "$input_path" ]; then
            emit_error_json "design-review-record" "$tid" "file_not_found" \
                "verdict file does not exist: $input_path" \
                "qa-gate.sh design-review-record $tid --design-hash <sha256> --file <existing-path>"
            exit 1
        fi
        if ! raw=$(cat -- "$input_path" 2>/dev/null); then
            emit_error_json "design-review-record" "$tid" "file_unreadable" \
                "could not read verdict file: $input_path" \
                "qa-gate.sh design-review-record $tid --design-hash <sha256> --file <readable-path>"
            exit 1
        fi
    else
        if [ -t 0 ]; then
            emit_error_json "design-review-record" "$tid" "no_input" \
                "no --file given and stdin is a terminal; pipe the design reviewer's JSON or pass --file <path>" \
                "qa-gate.sh design-review-record $tid --design-hash <sha256> --file <path>  OR  printf '%s' \"\$JSON\" | qa-gate.sh design-review-record $tid --design-hash <sha256>"
            exit 1
        fi
        raw=$(cat)
    fi

    if [ -z "$raw" ]; then
        emit_error_json "design-review-record" "$tid" "empty_input" \
            "verdict input is empty" \
            "qa-gate.sh design-review-record $tid --design-hash <sha256> --file <path>  OR  stdin pipe"
        exit 1
    fi

    if ! printf '%s' "$raw" | jq -e 'type' >/dev/null 2>&1; then
        emit_error_json "design-review-record" "$tid" "invalid_json" \
            "verdict input is not valid JSON" \
            "expected a JSON object with keys verdict, criterion_results, required_fixes, iteration, rubric_version, reviewer_identity"
        exit 1
    fi
    local top_type
    top_type=$(printf '%s' "$raw" | jq -r 'type' 2>/dev/null || echo "unknown")
    if [ "$top_type" != "object" ]; then
        emit_error_json "design-review-record" "$tid" "not_an_object" \
            "verdict input top-level is $top_type, expected object" \
            "expected a JSON object with keys verdict, criterion_results, required_fixes, iteration, rubric_version, reviewer_identity"
        exit 1
    fi

    # Required-key loop mirrors cmd_grade_record's exactly, plus
    # reviewer_identity — the one key the code rubric's verdict has no
    # analogue for, because the grader's own identity is never
    # independence-checked against anything.
    local has_key
    for key in verdict criterion_results required_fixes iteration rubric_version reviewer_identity; do
        has_key=$(printf '%s' "$raw" | jq -r --arg k "$key" 'has($k)' 2>/dev/null || echo "false")
        if [ "$has_key" != "true" ]; then
            emit_error_json "design-review-record" "$tid" "missing_key:$key" \
                "verdict input missing required key: $key" \
                "required keys: verdict, criterion_results, required_fixes, iteration, rubric_version, reviewer_identity"
            exit 1
        fi
    done

    local verdict
    verdict=$(printf '%s' "$raw" | jq -r '.verdict' 2>/dev/null || echo "")
    case "$verdict" in
        satisfied|needs_revision) ;;
        *)
            emit_error_json "design-review-record" "$tid" "verdict_invalid_enum" \
                "verdict='$verdict' is not in the allowed enum {satisfied, needs_revision}" \
                "set .verdict to either \"satisfied\" or \"needs_revision\""
            exit 1
            ;;
    esac

    local cr_type
    cr_type=$(printf '%s' "$raw" | jq -r '.criterion_results | type' 2>/dev/null || echo "unknown")
    if [ "$cr_type" != "array" ]; then
        emit_error_json "design-review-record" "$tid" "criterion_results_not_array" \
            "criterion_results is type=$cr_type, expected array" \
            "criterion_results must be an array of {criterion, pass, justification} objects"
        exit 1
    fi
    local cr_invalid
    cr_invalid=$(printf '%s' "$raw" | jq -r '
        .criterion_results
        | map(
            if type != "object" then "item_not_object"
            elif (has("criterion") and (.criterion | type == "string")) | not then "missing_or_bad_criterion"
            elif (has("pass") and (.pass | type == "boolean")) | not then "missing_or_bad_pass"
            elif (has("justification") and (.justification | type == "string")) | not then "missing_or_bad_justification"
            else "ok"
            end
        )
        | map(select(. != "ok"))
        | .[0] // ""
    ' 2>/dev/null || echo "")
    if [ -n "$cr_invalid" ]; then
        emit_error_json "design-review-record" "$tid" "criterion_results_item_invalid:$cr_invalid" \
            "criterion_results contains an invalid item: $cr_invalid" \
            "every criterion_results item must be {criterion: string, pass: boolean, justification: string}"
        exit 1
    fi

    local rf_type
    rf_type=$(printf '%s' "$raw" | jq -r '.required_fixes | type' 2>/dev/null || echo "unknown")
    if [ "$rf_type" != "array" ]; then
        emit_error_json "design-review-record" "$tid" "required_fixes_not_array" \
            "required_fixes is type=$rf_type, expected array" \
            "required_fixes must be an array (empty array allowed for satisfied)"
        exit 1
    fi

    local it_type it_val
    it_type=$(printf '%s' "$raw" | jq -r '.iteration | type' 2>/dev/null || echo "unknown")
    if [ "$it_type" != "number" ]; then
        emit_error_json "design-review-record" "$tid" "iteration_not_number" \
            "iteration is type=$it_type, expected number" \
            "iteration must be a JSON number (1, 2, 3, ...)"
        exit 1
    fi
    it_val=$(printf '%s' "$raw" | jq -r '.iteration' 2>/dev/null || echo "?")
    case "$it_val" in
        ''|*[!0-9]*)
            emit_error_json "design-review-record" "$tid" "iteration_not_integer" \
                "iteration=$it_val is not a non-negative integer; it is interpolated into the DESIGN-REVIEW record's machine prefix, which the reader parses as [0-9]+ — a value like 1.5 or 1e3 writes a record that cannot be read back" \
                "iteration must be a non-negative integer (1, 2, 3, ...)"
            exit 1
            ;;
    esac

    local rv_type rv_val
    rv_type=$(printf '%s' "$raw" | jq -r '.rubric_version | type' 2>/dev/null || echo "unknown")
    if [ "$rv_type" != "string" ]; then
        emit_error_json "design-review-record" "$tid" "rubric_version_not_string" \
            "rubric_version is type=$rv_type, expected string" \
            "rubric_version must be a string (e.g. \"1\")"
        exit 1
    fi
    rv_val=$(printf '%s' "$raw" | jq -r '.rubric_version' 2>/dev/null || echo "")
    if [ -z "$rv_val" ]; then
        emit_error_json "design-review-record" "$tid" "rubric_version_empty" \
            "rubric_version is the empty string" \
            "rubric_version must be a non-empty string (e.g. \"1\")"
        exit 1
    fi

    local reviewer_identity
    reviewer_identity=$(printf '%s' "$raw" | jq -r '.reviewer_identity' 2>/dev/null || echo "")
    if [ -z "$reviewer_identity" ]; then
        emit_error_json "design-review-record" "$tid" "reviewer_identity_empty" \
            "reviewer_identity is the empty string" \
            "reviewer_identity must be a non-empty string (design-reviewer.md's own contract: the fixed literal \"design-claude\")"
        exit 1
    fi

    # THE INDEPENDENCE CHECK (AC 4.4). Read at record time, refused before
    # anything is written — see the block header for why this cannot be
    # deferred to approve time.
    local designer_identity
    designer_identity=$(latest_design_artifact_designer "$tid") || designer_identity=""
    if [ -z "$designer_identity" ]; then
        emit_error_json "design-review-record" "$tid" "design_artifact_record_missing" \
            "no DESIGN-ARTIFACT v1 record exists for $tid, so there is no established designer identity to check this verdict's independence against. Record the design first" \
            "qa-gate.sh design-record $tid"
        exit 1
    fi
    if [ "$reviewer_identity" = "$designer_identity" ]; then
        emit_error_json "design-review-record" "$tid" "design_reviewer_not_independent" \
            "reviewer_identity='$reviewer_identity' equals designer='$designer_identity' on $tid's latest DESIGN-ARTIFACT record — nobody reviews their own work. Have a genuinely independent identity review this design and record a fresh verdict" \
            "qa-gate.sh design-review-record $tid --design-hash <h> --file <a verdict from a different reviewer>"
        exit 1
    fi

    # THE AMENDMENT / DUPLICATE-ITERATION CHECK (B2 / P6). Read the LATEST
    # DESIGN-REVIEW record (if any) through the ONE reader above, never a
    # second parser.
    local prior_json="" prior_rc=0 prior_iter prior_hash amends_field=""
    prior_json=$(latest_design_review "$tid") || prior_rc=$?
# DESIGN-REVIEW-HISTORY-GUARD BEGIN (xsu1 H2R2-F3)
    # An UNREADABLE history is not an EMPTY history. The old
    # `|| prior_json="{}"` erased prior_iter on a failed read, which skipped
    # the iteration-advance comparison entirely and let a duplicate or
    # non-advancing DESIGN-REVIEW record be written — the exact misbehaviour
    # the B2/P6 check exists to refuse — and also erased prior_hash, so a
    # genuine amendment lost its [amends: <hash>] audit suffix. Refused HERE,
    # before anything is written. Exit 2 = infrastructure, matching
    # require_bd's own convention for "the store cannot be consulted".
    if [ "$prior_rc" -ne 0 ]; then
        emit_error_json "design-review-record" "$tid" "design_review_history_unreadable" \
            "the existing DESIGN-REVIEW history for $tid could not be read right now (bd unreachable, the comment stream not retrievable, or the latest record read back malformed), so the iteration-advance and amendment checks cannot run. A verdict written over an unread history could silently duplicate or fail to advance an existing iteration — refusing before anything is written" \
            "re-run once bd is reachable: qa-gate.sh design-review-record $tid --design-hash <sha256> --file <verdict>"
        exit 2
    fi
# DESIGN-REVIEW-HISTORY-GUARD END (xsu1 H2R2-F3)
    prior_iter=$(printf '%s' "$prior_json" | jq -r '.iteration // ""' 2>/dev/null || echo "")
    prior_hash=$(printf '%s' "$prior_json" | jq -r '.design_hash // ""' 2>/dev/null || echo "")
    if [ -n "$prior_iter" ]; then
        if [ "$it_val" -le "$prior_iter" ]; then
            emit_error_json "design-review-record" "$tid" "design_review_iteration_not_advancing" \
                "iteration=$it_val is not greater than the latest recorded DESIGN-REVIEW's iteration=$prior_iter for $tid. Each recorded verdict must advance the iteration count — a second record at the same (or an earlier) number is refused rather than silently accepted as a fresh round" \
                "qa-gate.sh design-review-record $tid --design-hash <h> --file <verdict with iteration=$((prior_iter + 1))>"
            exit 1
        fi
        if [ -n "$prior_hash" ] && [ "$prior_hash" != "$design_hash_arg" ]; then
            amends_field=" [amends: $prior_hash]"
        fi
    fi

    # --- write ---------------------------------------------------------------
    assert_record_scalar "design-review-record" "$tid" "reviewer" "$reviewer_identity"
    assert_record_scalar "design-review-record" "$tid" "rubric_version" "$rv_val"

    local summary
    if [ "$verdict" = "satisfied" ]; then
        summary="all criteria pass"
    else
        local failed_names
        failed_names=$(printf '%s' "$raw" | jq -r '[.criterion_results[] | select(.pass == false) | .criterion] | join(", ")' 2>/dev/null || echo "")
        if [ -n "$failed_names" ]; then
            summary="failed: $failed_names"
        else
            local rf_count
            rf_count=$(printf '%s' "$raw" | jq -r '.required_fixes | length' 2>/dev/null || echo "0")
            summary="needs_revision (no failing criteria listed; required_fixes count=$rf_count)"
        fi
    fi

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="DESIGN-REVIEW v1 task=$tid reviewer=$reviewer_identity verdict=$verdict design_hash=$design_hash_arg iteration=$it_val rubric_version=$rv_val at $ts: $summary$amends_field"
    add_comment "$tid" "$comment_text"
    emit_json 1 "design-review-record" "$tid" "recorded" "comment posted at $ts: $comment_text"
}

# design-gate-precheck <tid> (v5 D2 / claude-workflow-plugin-fkm.4, B5)
#
# A PRE-DELEGATION CONVENIENCE, run by the orchestrator BEFORE its first
# Task() spawn on a task — never enforced from here, because nothing can
# force an orchestrator prompt to run a script before deciding to delegate.
# The real, unavoidable backstop is cmd_approve's own DESIGN-SATISFIED-REFUSAL
# above; this exists so the orchestrator can find out it is about to spawn an
# implementer on an unreviewed design BEFORE paying for that spawn, rather
# than discovering it only when approve refuses at the end.
#
# DELIBERATELY LENIENT ON `no_design_attempted`, UNLIKE cmd_approve. approve's
# own refusal is unconditional (matching completion_record_missing's own
# shape: every task needs a bypass or a record) because approve is the LAST
# word — a silently design-optional task must still say so explicitly. This
# precheck runs FIRST, before any work exists, and the overwhelming majority
# of tasks never have (or need) a design phase at all; treating "nothing
# started" as a precheck failure would make it fire on almost every ordinary
# task, which trains an operator to ignore its output rather than act on it.
# What this check exists to catch is narrower and more useful: a design that
# WAS started (a DESIGN-ARTIFACT record exists) but is not yet REVIEWED —
# don't spawn the implementer on that. compute_design_satisfied's other keys
# (design_verdict_missing, design_not_satisfied, design_hash_unreadable,
# design_artifact_unreadable, design_verdict_stale) all mean exactly that, so
# this is a targeted read of ONE key from the shared predicate, not a second
# implementation of it.
cmd_design_gate_precheck() {
    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "design-gate-precheck" "" "missing_task_id" \
            "design-gate-precheck requires <task-id> as first positional argument" \
            "qa-gate.sh design-gate-precheck <task-id>"
        exit 1
    fi
    shift || true
    if [ "$#" -gt 0 ]; then
        emit_error_json "design-gate-precheck" "$tid" "unknown_flag" \
            "unknown argument '$1'; design-gate-precheck takes only <task-id>" \
            "qa-gate.sh design-gate-precheck <task-id>"
        exit 1
    fi

    require_bd "design-gate-precheck" "$tid"

    compute_design_satisfied "$tid"
    # R9-F1 (independent review round 9, claude-workflow-plugin-i8cx):
    # CAPTURE INTO LOCALS IMMEDIATELY — compute_design_conflict_open below
    # evaluates its own R6-F4 clearing predicate by calling
    # compute_design_satisfied AGAIN internally (see that function's own
    # header, "THE RESIDUAL THIS CLOSES") whenever at least one
    # DESIGN-CONFLICT record exists, which overwrites the GLOBAL
    # DESIGN_SATISFIED / DESIGN_SATISFIED_KEY / DESIGN_SATISFIED_OBS this
    # function still needs below. Reading the globals again after that call
    # would silently rebind them to a second, independent read a few
    # milliseconds later — the same TOCTOU shape this file's xsu1 discipline
    # forecloses elsewhere. cmd_approve's own DESIGN-CONFLICT-REFUSAL avoids
    # this the same way, one call earlier: it stashes what it needs
    # (design_verdict_field, design_satisfied_obs) into locals before ever
    # reaching its own unconditional conflict check.
    local design_satisfied="$DESIGN_SATISFIED"
    local design_satisfied_key="$DESIGN_SATISFIED_KEY"
    local design_satisfied_obs="$DESIGN_SATISFIED_OBS"

# DESIGN-GATE-PRECHECK-CONFLICT BEGIN (v5 D5 R2-F2 fix / independent review
# round 2; made UNCONDITIONAL-BEFORE-ANY-BRANCH at R9-F1 / round 9)
    #
    # R2-F2's original fix (still the reason this check exists at all):
    # design-gate-precheck IS the Stop-time recheck path, not only the
    # pre-delegation convenience its own header above describes —
    # verify-before-stop.sh's DESIGN-DISCIPLINE block (v5 D2 / fkm.4) shells
    # out to exactly this subcommand and blocks the release on ANY non-zero
    # exit, keyed on nothing but the exit status. compute_design_satisfied's
    # own vocabulary has no conflict arm (deliberately — see
    # compute_design_conflict_open's header and cmd_approve's own
    # DESIGN-CONFLICT-REFUSAL comment for why that split is not being undone
    # here), so this function has to ask both predicates itself. NOT FOLDED
    # INTO compute_design_satisfied ITSELF — that predicate is ALSO
    # consulted by design-conform (fkm.6), and folding a conflict check into
    # the shared predicate would change design-conform's behaviour too:
    # extend the CALLER that needs the new fact, never the fact-finder every
    # caller reads.
    #
    # R9-F1 (independent review round 9): THE FIFTH independent HIGH against
    # reaching this exact predicate correctly (R2-F2 itself; R3-F2a/b;
    # R6-F1 through F4 against the since-removed waiver mechanism; this
    # one). Every prior fix was locally correct on its own terms and still
    # left a path in, because each one added or repaired a check WITHOUT
    # changing the fact that the check lived inside one arm of a branch on
    # DESIGN_SATISFIED. Historically this block was nested inside
    # `if [ "$DESIGN_SATISFIED" = "true" ]` below — so `no_design_attempted`
    # (and every other non-true DESIGN_SATISFIED_KEY) returned "ready"
    # WITHOUT EVER CALLING compute_design_conflict_open. Concretely: approve
    # a task --no-design while it is satisfied-and-unconflicted (or before
    # any design phase exists at all), THEN file a genuine DESIGN-CONFLICT —
    # the Stop-time recheck never re-entered the branch that would have seen
    # it, because filing a conflict is a Beads-only change that moves
    # neither the change-set hash nor DESIGN_SATISFIED itself.
    #
    # THE FIX IS STRUCTURAL, NOT ANOTHER LOCAL GUARD: this block now runs
    # ONCE, UNCONDITIONALLY, BEFORE either `if` below ever inspects
    # design_satisfied or design_satisfied_key. There is no longer a branch
    # PRECEDING the conflict check for a future arm to hide behind — every
    # existing DESIGN_SATISFIED_KEY value (true, no_design_attempted,
    # design_verdict_missing, design_not_satisfied, design_hash_unreadable,
    # design_artifact_unreadable, design_verdict_stale,
    # design_source_unreadable) and any NEW key compute_design_satisfied
    # grows in the future inherit this refusal for free, because the
    # branching on that vocabulary happens strictly AFTER this block returns
    # without exiting. A sixth escape would require an entirely NEW code
    # path reaching "ready" or the not-ready emit_error_json below WITHOUT
    # going through this function's own top-to-bottom control flow at all —
    # not a sixth DESIGN_SATISFIED_KEY value, which is the shape every prior
    # finding against this predicate exploited.
    #
    # claude-workflow-plugin-i8cx (operator ruling on rounds 6/7/8
    # independent review, unaffected by this fix): the unit-scoped waiver
    # subtraction this block used to perform (DESIGN-GATE-PRECHECK-UNIT-SCOPE,
    # R3-F2b) is gone — ANY open conflict refuses here, unconditionally,
    # exactly as it already does at `approve`; there is no unit to subtract
    # because there is no longer a waiver that could have named one.
    #
    # EXIT 4, matching THIS subcommand's OWN established convention for
    # every other "not ready" outcome — NOT exit 2, which is cmd_approve's
    # own convention for the identical vocabulary (see cmd_approve's
    # DESIGN-CONFLICT-REFUSAL header for the full cross-command exit-code
    # rationale). FAIL-CLOSED ORDERING PRESERVED: an unreadable conflict
    # source (design_conflict_rc != 0) refuses BEFORE an open conflict is
    # even asked about, exactly as before — "unknown" must never collapse
    # into "no conflict" any more than it may collapse into "ready" the long
    # way around.
    #
    # WORDING NOTE: the source-unreadable message below no longer opens with
    # "the design is satisfied, but" — now false on every path except the
    # one arm it used to be nested in. The error_key, exit code, and
    # remediation are otherwise unchanged, and design_conflict_open's own
    # message is untouched (it never made that assumption).
    #
    # NO CALLER-SIDE CHANGE NEEDED (verified by reading verify-before-stop.sh,
    # not by assumption): its DESIGN-DISCIPLINE block branches on the exit
    # status alone, so this refusal is picked up by an UNMODIFIED caller the
    # first time it runs after this ships — the same property R2-F2's own
    # fix already established and this one does not disturb.
    #
    # The sentinel comments are load-bearing: an L1 META
    # (design-review-record.test.sh) strips this region and watches a task
    # carrying no_design_attempted PLUS an open, un-amended DESIGN-CONFLICT
    # report "ready" anyway. Do not rename the sentinels.
    local design_conflict_rc=0
    compute_design_conflict_open "$tid" || design_conflict_rc=$?
    if [ "$design_conflict_rc" -ne 0 ]; then
        emit_error_json "design-gate-precheck" "$tid" "design_conflict_source_unreadable" \
            "design-gate-precheck: the DESIGN-CONFLICT history for $tid could not be read right now (bd unreachable, the comment stream not retrievable, or a record read back malformed), so whether an open conflict exists is unknown; refusing to report this as ready, regardless of the task's own design-satisfied state. Re-run once bd is reachable" \
            "qa-gate.sh design-review-record <task-id> --design-hash <sha256> --file <path>"
        exit 4
    fi
    if [ "$DESIGN_CONFLICT_OPEN" = "true" ]; then
        emit_error_json "design-gate-precheck" "$tid" "design_conflict_open" \
            "design-gate-precheck: not ready — $DESIGN_CONFLICT_OPEN_OBS Affected unit(s): $DESIGN_CONFLICT_OPEN_UNITS. The single legal clearing path is a superseding, independently-reviewed, SATISFIED DESIGN-REVIEW whose entry for the affected unit(s) changed — amend docs/specs/$tid.md and record a fresh, independent verdict: qa-gate.sh design-review-record $tid --design-hash <h> --file <verdict.json>. This cannot be waived; a content edit alone is not enough without an accompanying satisfied review" \
            "qa-gate.sh design-review-record <task-id> --design-hash <sha256> --file <path>"
        exit 4
    fi
# DESIGN-GATE-PRECHECK-CONFLICT END (v5 D5 R2-F2 fix; R9-F1 unconditional)

    if [ "$design_satisfied" = "true" ]; then
        emit_json 1 "design-gate-precheck" "$tid" "ready" "$design_satisfied_obs"
        return 0
    fi
    if [ "$design_satisfied_key" = "no_design_attempted" ]; then
        emit_json 1 "design-gate-precheck" "$tid" "ready" "${design_satisfied_obs} — proceeding is fine; this precheck only blocks a design that was STARTED but is not yet reviewed"
        return 0
    fi
    emit_error_json "design-gate-precheck" "$tid" "$design_satisfied_key" \
        "design-gate-precheck: not ready to delegate implementation — $design_satisfied_obs. Record a satisfied, independent design verdict first: qa-gate.sh design-review-record $tid --design-hash <h> --file <verdict.json>" \
        "qa-gate.sh design-review-record <task-id> --design-hash <sha256> --file <path>"
    exit 4
}
# DESIGN-REVIEW END (v5 D2 / claude-workflow-plugin-fkm.4)

# ---------------------------------------------------------------------------
# DESIGN-UNIT BEGIN (fkm.6)
#
# design-unit-bind <task-id> --design-task <design-owning-task-id>
#                  --unit-id <U-n> [--rebind '<reason>'] ['<summary>']
#
# THE UNIT<->TASK BINDING RECORD — the carrier task-per-unit needs and does
# not yet have. D1/D2 (fkm.3/fkm.4) gave the design ARTIFACT and its REVIEW
# their own records, both keyed by the task that OWNS the design (typically
# an epic). Neither carries a per-unit `task_id`: review-check.sh's schema
# (review-check.sh:719-764) has no such field, and adding one would touch
# `validate-design` and its parity tests for a fact that is about
# ORCHESTRATION (which Beads task implements which unit), not about the
# design document itself. This record is that fact, kept separate on
# purpose — the same reasoning D1's own header gives for splitting
# DESIGN-ARTIFACT from DESIGN-REVIEW rather than folding both into one
# grammar.
#
#   DESIGN-UNIT v1 task=<tid> design_task=<design-tid> unit_id=<U-n>
#     design_hash=<h> at <ts>: <summary>[ [rebind: <reason>]]
#
# Posted ON THE IMPLEMENTING TASK (<tid>), never on the design-owning task —
# unlike GRILLING (which deliberately checks "task OR its parent epic",
# because one grilling dialogue legitimately covers every unit under an
# epic), a unit binding names WHICH task implements WHICH unit, and that is
# a fact about <tid> specifically. There is no "epic-level" binding to fall
# back to: every unit-task needs its OWN distinct unit_id.
#
# `design_task` IS A REQUIRED MACHINE TOKEN, NOT PROSE. `design-conform`
# needs to programmatically resolve which artifact governs <tid>, and this
# file's own convention (cmd_design_record's `record_suffix` comment, just
# above) is explicit that the bracketed suffix carries free text a program
# never compares — a value a reader depends on belongs in the machine
# prefix. Nothing here assumes <design-tid> is <tid>'s Beads PARENT: the
# caller (the orchestrator, which just created the tasks from the artifact
# and therefore knows both ids) states it explicitly, rather than this
# script inferring it through a parent-child walk that may not hold for
# every re-plan or restructuring.
#
# `design_hash` IS A LIVE RECOMPUTE, NEVER A CALLER-SUPPLIED CLAIM — the
# SAME "continuous enforcement is the live recompute, not a label" doctrine
# grilling-record's vendor_hash and design-record's own hash both follow.
# It is bracketed exactly like design-record's hash-vs-validate window
# (fkm.3 R2-F3/R3-F4: hash BEFORE validating, re-hash AND re-check
# containment AFTER, refuse on any disagreement) because this record's
# whole claim — "unit_id was declared in the artifact at these bytes" — is
# only sound when the membership check below and the hash were taken from
# the SAME read.
#
# REFUSES `unit_not_in_artifact` when --unit-id is not among the artifact's
# CURRENT unit_ids — a binding to a nonexistent unit is worse than none,
# per this phase's own non-negotiable.
#
# RE-BINDING (the question this phase asks to be decided explicitly): an
# EXISTING `DESIGN-UNIT` record on <tid> — to ANY unit_id, even the same one
# — refuses a second write without `--rebind '<reason>'`. Silent
# overwriting is dangerous (a spec already injected at spawn, an in-flight
# implementer, or an earlier `design-conform` result would all silently
# disagree with a changed binding and nobody would know); a permanent
# refusal would deadlock a legitimate re-plan (units get split, merged, or
# renumbered through the D2 amendment loop same as the artifact itself). The
# audited bypass is the same shape as grilling's `--no-grilling` and
# design-record's `--accept-foreign-paths`: always available, always
# recorded, never silent. Unlike DESIGN-REVIEW's iteration-must-ADVANCE
# discipline, there is no natural counter to advance here (a binding is a
# static fact, not an iterative verdict), so the flag is required on ANY
# repeat write rather than only on a DIFFERING one — simpler to reason
# about, and it costs nothing on the common path (a task is normally bound
# exactly once).

# _design_unit_lock_root — the directory design-unit-bind's rebind lock
# file lives under (R2-F2, review round 2). Prefers git's own COMMON
# directory, symlink-resolved exactly like verify-before-stop.sh's
# repo_identity (never a --show-toplevel string compare, which is
# per-checkout and would reintroduce the exact gap this closes): every
# worktree of ONE repo resolves to the SAME common directory, and D4/D5
# runs each unit in its own worktree against one SHARED Beads database
# (docs/HOOKS.md, "Cross-worktree approval resolution"), so a lock keyed
# off it is genuinely shared across the callers that matter. Falls back to
# $QA_TRACKING_DIR — the ORIGINAL, per-checkout location — when git is
# unavailable or $PROJECT_DIR is not a git checkout at all; the cross-
# worktree window is NOT closed in that fallback, only same-checkout
# callers are mutually excluded, same as before this fix. Never fails the
# caller: always prints a non-empty path.
_design_unit_lock_root() {
    local raw candidate resolved
# CROSS-WORKTREE-LOCK-ROOT BEGIN (fkm.6, R2-F2)
    if command -v git >/dev/null 2>&1; then
        raw=$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null) || raw=""
        if [ -n "$raw" ]; then
            case "$raw" in
                /*) candidate="$raw" ;;
                *)  candidate="$PROJECT_DIR/$raw" ;;
            esac
            resolved=$(cd "$candidate" 2>/dev/null && pwd -P) || resolved=""
            if [ -n "$resolved" ]; then
                printf '%s/claude-workflow-design-unit-locks' "$resolved"
                return 0
            fi
        fi
    fi
# CROSS-WORKTREE-LOCK-ROOT END (fkm.6, R2-F2)
    printf '%s' "$QA_TRACKING_DIR"
    return 0
}

cmd_design_unit_bind() {
    # jq AVAILABILITY IS CHECKED FIRST (R1-F5, review round 1) —
    # the SAME property design-conform's own first line has, and for the
    # identical reason: every other path through this function reaches
    # emit_error_json, which builds its JSON THROUGH jq. Missing that check
    # here reproduced exactly the defect the design-conform fix was written
    # to close. The hand-built literal below keeps the SAME safety property
    # the reviewer confirmed on design-conform's own jq-free message: it
    # emits `task_id:null` and interpolates NO caller-supplied text (not the
    # task id, not any flag value), so it is valid JSON for every input,
    # never needing jq to escape anything a hostile or malformed argument
    # might contain.
    if ! command -v jq >/dev/null 2>&1; then
        printf '{"ok":false,"subcommand":"design-unit-bind","task_id":null,"status":"error","error_key":"jq_unavailable","observations":"jq is required to validate and hash the design artifact and is not on PATH; refusing rather than reporting a binding that was never actually checked","usage":"qa-gate.sh design-unit-bind <task-id> --design-task <design-tid> --unit-id <U-n>"}\n'
        exit 2
    fi

    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "design-unit-bind" "" "missing_task_id" \
            "design-unit-bind requires <task-id> as first positional argument" \
            "qa-gate.sh design-unit-bind <task-id> --design-task <design-tid> --unit-id <U-n>"
        exit 1
    fi
    shift || true

    local design_task="" unit_id="" summary="" rebind=0 rebind_reason=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --design-task)
                design_task="${2:-}"
                if [ -z "$design_task" ]; then
                    emit_error_json "design-unit-bind" "$tid" "missing_design_task" \
                        "--design-task requires a task-id argument — the task whose docs/specs/<id>.md artifact governs this binding" \
                        "qa-gate.sh design-unit-bind $tid --design-task <design-tid> --unit-id <U-n>"
                    exit 1
                fi
                shift 2 || true
                ;;
            --unit-id)
                unit_id="${2:-}"
                if [ -z "$unit_id" ]; then
                    emit_error_json "design-unit-bind" "$tid" "missing_unit_id" \
                        "--unit-id requires a value — the unit_id $tid implements, as declared in the design artifact" \
                        "qa-gate.sh design-unit-bind $tid --design-task <design-tid> --unit-id <U-n>"
                    exit 1
                fi
                shift 2 || true
                ;;
            --rebind)
                rebind_reason="${2:-}"
                if [ -z "$rebind_reason" ]; then
                    emit_error_json "design-unit-bind" "$tid" "missing_rebind_reason" \
                        "--rebind requires a reason; it is recorded in the audit trail" \
                        "qa-gate.sh design-unit-bind $tid --design-task <design-tid> --unit-id <U-n> --rebind '<reason>'"
                    exit 1
                fi
                rebind=1
                shift 2 || true
                ;;
            -h|--help) usage; exit 1 ;;
            *)
                if [ -z "$summary" ]; then summary="$1"; else summary="$summary $1"; fi
                shift || true
                ;;
        esac
    done
    [ -n "$summary" ] || summary="unit bound"

    require_bd "design-unit-bind" "$tid"

    if [ -z "$design_task" ]; then
        emit_error_json "design-unit-bind" "$tid" "missing_design_task" \
            "--design-task is required — the task whose docs/specs/<id>.md artifact $tid's unit belongs to" \
            "qa-gate.sh design-unit-bind $tid --design-task <design-tid> --unit-id <U-n>"
        exit 1
    fi
    if [ -z "$unit_id" ]; then
        emit_error_json "design-unit-bind" "$tid" "missing_unit_id" \
            "--unit-id is required — which unit in $design_task's design $tid implements" \
            "qa-gate.sh design-unit-bind $tid --design-task <design-tid> --unit-id <U-n>"
        exit 1
    fi
    # THIS EARLY CALL IS DELIBERATE, not an oversight duplicating the
    # write-section one below. Without it, a malformed --unit-id (a typo
    # carrying a space or colon) would run the full artifact
    # resolve/hash/validate sequence only to be refused by
    # `unit_not_in_artifact` — TRUE (a malformed value can never be a real
    # declared unit) but less specific than naming the actual defect, and
    # not free (the artifact work already happened for a request that could
    # never have succeeded). Refusing here is a cheap, specific fail-fast.
    # The write-section call is NOT redundant-to-delete, either: schema
    # validation guarantees every REAL unit_id already matches this class,
    # so by the time a value reaches the write section here it is
    # (currently) unreachable in practice — it is defense in depth against a
    # future bug in review-check.sh's own validator, the SAME shape
    # design-record's redundant is_sha256_hex + assert_record_scalar check
    # on design_hash already is.
    assert_unit_id_scalar "design-unit-bind" "$tid" "unit_id" "$unit_id"

    # --- resolve the GOVERNING artifact, same derivation design-record uses
    local artifact
    artifact=$(design_artifact_path_for "$design_task")
    if [ ! -f "$artifact" ]; then
        emit_error_json "design-unit-bind" "$tid" "design_artifact_not_found" \
            "no design artifact at $artifact for --design-task=$design_task; nothing to bind against" \
            "qa-gate.sh design-record $design_task --file $artifact"
        exit 1
    fi
    if ! design_path_is_contained "$artifact"; then
        emit_error_json "design-unit-bind" "$tid" "design_artifact_outside_spec_dir" \
            "$artifact does not resolve inside $PROJECT_DIR/$DESIGN_SPEC_SUBDIR/; refusing to bind against it" \
            "qa-gate.sh design-record $design_task --file $artifact"
        exit 1
    fi

    # --- OPENING bracket: hash before validating (fkm.3 R2-F3's discipline,
    # reused rather than re-derived) --------------------------------------
    local manifest_tool pre_hash="" pre_rc=0
    manifest_tool="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
    if [ ! -f "$manifest_tool" ]; then
        emit_error_json "design-unit-bind" "$tid" "hash_tool_unavailable" \
            "cannot hash the design artifact: workflow-manifest.sh is missing at $manifest_tool" \
            "restore .claude/scripts/workflow-manifest.sh"
        exit 2
    fi
    pre_hash=$(bash "$manifest_tool" hash-file "$artifact" 2>/dev/null) || pre_rc=$?
    if [ "$pre_rc" -ne 0 ] || ! is_sha256_hex "$pre_hash"; then
        emit_error_json "design-unit-bind" "$tid" "design_hash_unavailable" \
            "the design artifact at $artifact could not be hashed into 64 hex characters (workflow-manifest.sh hash-file exited $pre_rc, produced '${pre_hash:-<empty>}')" \
            "bash .claude/scripts/workflow-manifest.sh hash-file $artifact"
        exit 2
    fi

    if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
        emit_error_json "design-unit-bind" "$tid" "validator_unavailable" \
            "cannot bind: the ONE validator is missing at $REVIEW_CHECK_SCRIPT" \
            "qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id"
        exit 2
    fi
    local vout="" vout_rc=0 vkey vobs
    vout=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" validate-design "$artifact" 2>/dev/null) || vout_rc=$?
    if ! validate_design_envelope_ok "$vout_rc" "$vout"; then
        vkey=$(printf '%s' "$vout" | jq -r '.error_key // "invalid_design_artifact"' 2>/dev/null || echo "invalid_design_artifact")
        [ -z "$vkey" ] && vkey="invalid_design_artifact"
        vobs=$(printf '%s' "$vout" | jq -r '.observations // ""' 2>/dev/null || echo "")
        emit_error_json "design-unit-bind" "$tid" "$vkey" \
            "the design artifact governing $design_task failed validation (validator exit rc=$vout_rc): $vkey${vobs:+ — $vobs}" \
            "see review-check.sh validate-design $artifact"
        exit 1
    fi

    # --- REFUSE a binding to a unit_id the artifact does not declare -------
# UNIT-MEMBERSHIP-GATE BEGIN (fkm.6)
    local has_unit known
    has_unit=$(printf '%s' "$vout" | jq -r --arg u "$unit_id" '(.unit_ids // []) | index($u) != null' 2>/dev/null || echo "false")
    if [ "$has_unit" != "true" ]; then
        known=$(printf '%s' "$vout" | jq -r '(.unit_ids // []) | join(", ")' 2>/dev/null || echo "")
        emit_error_json "design-unit-bind" "$tid" "unit_not_in_artifact" \
            "unit_id='$unit_id' is not declared in $artifact (design_hash=$pre_hash). Declared unit(s): ${known:-<none>}. A binding to a nonexistent unit is worse than none — refusing" \
            "qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id <one of: ${known:-<none>}>"
        exit 1
    fi
# UNIT-MEMBERSHIP-GATE END (fkm.6)

    # --- CLOSING bracket: re-hash + re-contain (fkm.3 R3-F4's discipline) --
    # the membership check just ran against $vout, which read the artifact
    # ONCE; if it moved (content OR containment) since, the membership
    # answer is not provably about the bytes design_hash names below.
    local post_hash="" post_rc=0
    post_hash=$(bash "$manifest_tool" hash-file "$artifact" 2>/dev/null) || post_rc=$?
    if [ "$post_rc" -ne 0 ] || ! is_sha256_hex "$post_hash" || [ "$post_hash" != "$pre_hash" ]; then
        emit_error_json "design-unit-bind" "$tid" "design_artifact_changed_during_bind" \
            "the design artifact at $artifact changed while this command was reading it (before=$pre_hash, after=${post_hash:-<unreadable>}, rc=$post_rc); nothing is bound. Re-run once the artifact has stopped moving" \
            "qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id"
        exit 1
    fi
    if ! design_path_is_contained "$artifact"; then
        emit_error_json "design-unit-bind" "$tid" "design_artifact_changed_during_bind" \
            "the design artifact at $artifact MOVED out of $DESIGN_SPEC_SUBDIR/ while this command was reading it; nothing is bound" \
            "qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id"
        exit 1
    fi
    local design_hash="$pre_hash"

    # --- assemble the record BEFORE the rebind check, not after -------------
    # (moved up from its original position, R1-F6, review round 1):
    # the flock-guarded critical section below needs $comment_text ready to
    # write atomically with the check, not built afterward outside the lock.
    assert_record_scalar "design-unit-bind" "$tid" "task" "$tid"
    assert_record_scalar "design-unit-bind" "$tid" "design_task" "$design_task"
    assert_unit_id_scalar "design-unit-bind" "$tid" "unit_id" "$unit_id"
    assert_record_scalar "design-unit-bind" "$tid" "design_hash" "$design_hash"

    local record_suffix=""
    [ "$rebind" = "1" ] && record_suffix=" [rebind: $rebind_reason]"

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="DESIGN-UNIT v1 task=$tid design_task=$design_task unit_id=$unit_id design_hash=$design_hash at $ts: $summary$record_suffix"

    # --- an EXISTING binding requires the audited --rebind, made
    # concurrency-safe with flock where available (R1-F6, review round 1).
    # "Any repeat write requires --rebind" held only SEQUENTIALLY:
    # two design-unit-bind processes could both read no existing binding
    # before either wrote, then both proceed without --rebind — the exact
    # ambiguity ("which binding is authoritative") the refusal exists to
    # prevent, left unenforced against a real concurrent caller.
    #
    # R2-F2 (review round 2): the lock used to be keyed off $QA_TRACKING_DIR
    # ($PROJECT_DIR/.claude/.qa-tracking), which is per-CHECKOUT by
    # documented design (docs/HOOKS.md, "Everything here is per-checkout").
    # D4/D5's own topology runs each unit in its own worktree (v5-design-
    # phase.md: "implement each unit in its own worktree"), and one Beads
    # database is shared across every worktree of a repo (docs/HOOKS.md,
    # "Cross-worktree approval resolution" — the same fact
    # worktree-approval-resolution.sh drives against a real `git worktree
    # add`) — so two binds for the SAME task from two DIFFERENT worktrees
    # used to take two DIFFERENT lock files while reading and writing the
    # SAME store: both see "no binding", both append, unlocked against each
    # other. _design_unit_lock_root below prefers a location every worktree
    # of one repo resolves to identically — git's own common directory,
    # symlink-resolved the SAME way verify-before-stop.sh's repo_identity
    # already does for the analogous "is W a worktree of this repo" question
    # (never a --show-toplevel string compare, which is per-checkout too).
    # Verified against a REAL `git worktree add`, not reasoned about: a
    # linked worktree and its main checkout resolve to the byte-identical
    # lock root; two unrelated repos do not.
    #
    # What this does NOT close: bd could be configured to point at a store
    # unrelated to this repo's own git structure (an exotic BEADS_DIR
    # override) — this fix assumes the store-sharing topology matches the
    # git-worktree topology, which is the documented, tested arrangement,
    # not a guess. And when git itself is unavailable, or PROJECT_DIR is not
    # a git checkout at all, _design_unit_lock_root falls back to
    # $QA_TRACKING_DIR — the ORIGINAL per-checkout behaviour, unchanged —
    # and the cross-worktree window this fix closes reopens in that
    # degraded case. Stated, not hidden.
    local rebind_lock rebind_rc=0 rebind_lock_root
    rebind_lock_root=$(_design_unit_lock_root)
    rebind_lock="$rebind_lock_root/.design-unit-bind-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').lock"
    mkdir -p "$rebind_lock_root" "$QA_TRACKING_DIR" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        # The read (latest_design_unit_binding), the decision, and the write
        # (add_comment) all run inside ONE flock -x critical section keyed
        # per-task-id, so a second design-unit-bind on the SAME tid blocks
        # until the first has either written or refused — closing the
        # check-then-act race rather than merely documenting it. A DIFFERENT
        # tid uses a DIFFERENT lock file, so unrelated bindings never
        # serialize against each other. The subshell calls emit_error_json
        # itself (its stdout is the same fd as the parent's, so the envelope
        # still reaches the real caller) because bash variables assigned
        # inside a `(...)` subshell do not survive it — only its EXIT STATUS
        # does, which the parent below re-raises.
        #
        # The refusal itself is sentinel-wrapped SEPARATELY from the write
        # (REBIND-GATE-FLOCKED, not REBIND-GATE — the no-flock branch below
        # owns that name): add_comment stays OUTSIDE either sentinel region
        # in BOTH branches on purpose, so a META test that excises just the
        # refusal still observes a REAL write landing unconditionally,
        # rather than excising the write along with the check and getting a
        # "recorded" verdict from the unconditional success emit at the
        # bottom of this function that never actually wrote anything.
        #
        # The subshell is joined with `|| rebind_rc=$?`, not a bare
        # statement followed by a separate `rebind_rc=$?` line: under `set
        # -e` (line 156) a FAILING bare compound command — subshell or
        # assignment alike — exits the WHOLE SCRIPT right there, before any
        # later line runs. Harmless on the refusal path today (the subshell
        # already printed the envelope and called `exit 1`, so an errexit-
        # forced exit 1 one line early looks identical) and on the success
        # path (add_comment's own trailing `|| log_sync_error` always
        # returns 0, so the subshell never fails there) — but a bare flock
        # -x 9 failure ahead of either branch would otherwise die silently
        # with no envelope at all, the exact failure mode R1-F1 named next
        # door. Do not "simplify" this back to a two-line form.
        (
            _rb_lock_rc=0
            flock -x 9 || _rb_lock_rc=$?
# REBIND-LOCK-GUARD BEGIN (xsu1 R7-F6)
            # A failed flock must NOT fall through into the critical
            # section. Errexit is DISABLED inside this subshell — the whole
            # `( ... )` is the left side of `|| rebind_rc=$?`, and bash
            # ignores set -e in any context whose result is tested
            # (`set -e; ( false; echo continued ) || rc=$?` prints
            # "continued" and ends rc 0) — so a bare `flock -x 9` failure
            # used to continue through the read and add_comment WITHOUT the
            # lock: the exact race this section exists to close, run
            # silently unlocked. Refused as infrastructure instead; nothing
            # has been read or written yet. The || capture above makes the
            # already-disarmed errexit explicit rather than accidental.
            if [ "$_rb_lock_rc" -ne 0 ]; then
                emit_error_json "design-unit-bind" "$tid" "design_binding_lock_unavailable" \
                    "flock -x failed (rc=$_rb_lock_rc) on $rebind_lock, so the existing-binding check cannot run under the lock that makes check-then-write atomic. Proceeding unlocked would reopen the concurrent-rebind race — refusing before anything is read or written" \
                    "re-run: qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id"
                exit 2
            fi
# REBIND-LOCK-GUARD END (xsu1 R7-F6)
            _rb_rc=0
            _rb_existing=$(latest_design_unit_binding "$tid") || _rb_rc=$?
# REBIND-READ-GUARD-FLOCKED BEGIN (xsu1 H2R2-F2)
            # rc 3 here means the existing-binding read FAILED — not that no
            # binding exists. The old `|| _rb_existing="{}"` converted that
            # failure into "no existing binding" BEFORE add_comment ran, so
            # a transient outage permitted an unaudited repeat binding
            # without --rebind; if the write and confirmation then
            # succeeded, the earlier authoritative binding was silently
            # superseded and the command still reported "recorded". Refused
            # before the write. Exit 2 = infrastructure, re-raised by the
            # parent's rebind_rc check below.
            if [ "$_rb_rc" -ne 0 ]; then
                emit_error_json "design-unit-bind" "$tid" "design_binding_unreadable" \
                    "the existing-binding read for $tid failed before the write (bd unreachable, the comment stream not retrievable, or unparseable), so whether $tid is already bound is unknown. Proceeding could silently supersede an authoritative binding without --rebind — refusing before anything is written" \
                    "re-run once bd is reachable: qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id"
                exit 2
            fi
# REBIND-READ-GUARD-FLOCKED END (xsu1 H2R2-F2)
            _rb_eu=$(printf '%s' "$_rb_existing" | jq -r '.unit_id // ""' 2>/dev/null || echo "")
            _rb_et=$(printf '%s' "$_rb_existing" | jq -r '.design_task // ""' 2>/dev/null || echo "")
# REBIND-GATE-FLOCKED BEGIN (fkm.6)
            if [ -n "$_rb_eu" ] && [ "$rebind" != "1" ]; then
                emit_error_json "design-unit-bind" "$tid" "design_binding_exists" \
                    "$tid is already bound to unit_id=$_rb_eu under design_task=$_rb_et. Re-binding a task to a different unit silently is dangerous (an already-injected spec, an in-flight implementer, or a prior design-conform result would all disagree with the change and nobody would know); refusing outright would deadlock a legitimate re-plan. Pass --rebind '<reason>' to record a new binding with the reason in the audit trail" \
                    "qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id --rebind '<reason>'"
                exit 1
            fi
# REBIND-GATE-FLOCKED END (fkm.6)
            add_comment "$tid" "$comment_text"
        ) 9>"$rebind_lock" || rebind_rc=$?
    else
        # NO FLOCK ON THIS HOST — documented, not theoretical: post-editable
        # .sh's own TRACKING_FILE append carries the IDENTICAL gap for the
        # IDENTICAL reason (macOS ships no flock by default; this is the
        # live path on a dev box, not a hypothetical one). The check-then-
        # write below is NOT atomic against a second concurrent design-
        # unit-bind on the SAME task id here. What remains guaranteed:
        # sequential correctness — the property design-conform.test.sh
        # Sections 3 and 9.2 actually exercise.
        local existing="" existing_rc=0 existing_unit existing_task
        existing=$(latest_design_unit_binding "$tid") || existing_rc=$?
# REBIND-READ-GUARD BEGIN (xsu1 H2R2-F2)
        # Same guard as REBIND-READ-GUARD-FLOCKED above, same reason: a
        # failed read is not "no existing binding". Sequential-only on this
        # host (no flock), but the fail-open conversion was identical.
        if [ "$existing_rc" -ne 0 ]; then
            emit_error_json "design-unit-bind" "$tid" "design_binding_unreadable" \
                "the existing-binding read for $tid failed before the write (bd unreachable, the comment stream not retrievable, or unparseable), so whether $tid is already bound is unknown. Proceeding could silently supersede an authoritative binding without --rebind — refusing before anything is written" \
                "re-run once bd is reachable: qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id"
            exit 2
        fi
# REBIND-READ-GUARD END (xsu1 H2R2-F2)
        existing_unit=$(printf '%s' "$existing" | jq -r '.unit_id // ""' 2>/dev/null || echo "")
        existing_task=$(printf '%s' "$existing" | jq -r '.design_task // ""' 2>/dev/null || echo "")
# REBIND-GATE BEGIN (fkm.6)
        if [ -n "$existing_unit" ] && [ "$rebind" != "1" ]; then
            emit_error_json "design-unit-bind" "$tid" "design_binding_exists" \
                "$tid is already bound to unit_id=$existing_unit under design_task=$existing_task. Re-binding a task to a different unit silently is dangerous (an already-injected spec, an in-flight implementer, or a prior design-conform result would all disagree with the change and nobody would know); refusing outright would deadlock a legitimate re-plan. Pass --rebind '<reason>' to record a new binding with the reason in the audit trail" \
                "qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id --rebind '<reason>'"
            exit 1
        fi
# REBIND-GATE END (fkm.6)
        add_comment "$tid" "$comment_text"
    fi
    [ "$rebind_rc" -ne 0 ] && exit "$rebind_rc"

    # R2-F3 (review round 2): add_comment() ends in `|| log_sync_error ...`
    # (itself ending in `|| true`), so it ALWAYS returns success — a
    # transient store failure, a wedged daemon, schema skew, or a deleted
    # task could all make the actual write silently not happen while this
    # function still reached "recorded" below. add_comment has 17 call
    # sites and is fail-open by DOCUMENTED design ("comments are non-
    # authoritative, labels are the source of truth") — a premise v5 broke
    # by adding comment-ONLY record subcommands, where the comment IS the
    # authority. Fixing the shared helper is wider than this slice (filed
    # separately: claude-workflow-plugin-nod4). The LOCAL fix: re-read the
    # EXACT predicate design-conform will later evaluate — this function
    # itself, not a weaker proxy — and refuse if what comes back does not
    # show what was just written as the latest record. This proves the
    # write actually landed rather than trusting add_comment's exit status,
    # which proves nothing.
    local confirm_json="" confirm_rc=0 confirm_unit confirm_hash retry_rebind_hint=""
    [ "$rebind" = "1" ] && retry_rebind_hint=" --rebind '<reason>'"
    confirm_json=$(latest_design_unit_binding "$tid") || confirm_rc=$?
    # (xsu1 H2R2-F2) A FAILED confirmation read is reported as exactly that —
    # never converted to {} and then described as "found unit_id=<none>
    # instead", which is a determined claim about a stream that was never
    # read. The write above may or may not have landed. Exit 5, same class as
    # the unconfirmed-write refusal below, because the caller's remedy is
    # identical: check the store, then design-unit-show $tid.
    if [ "$confirm_rc" -ne 0 ]; then
        emit_error_json "design-unit-bind" "$tid" "design_binding_confirm_unreadable" \
            "the write was submitted but the confirmation re-read of $tid's own comment stream failed (bd unreachable, the stream not retrievable, or unparseable) — whether the binding landed is unknown, and no claim is made about which record is latest. Once bd is reachable, verify with: qa-gate.sh design-unit-show $tid; re-run if absent: qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id$retry_rebind_hint" \
            "qa-gate.sh design-unit-show $tid"
        exit 5
    fi
    confirm_unit=$(printf '%s' "$confirm_json" | jq -r '.unit_id // ""' 2>/dev/null || echo "")
    confirm_hash=$(printf '%s' "$confirm_json" | jq -r '.design_hash // ""' 2>/dev/null || echo "")
# WRITE-CONFIRMATION-GATE BEGIN (fkm.6, R2-F3)
    if [ "$confirm_unit" != "$unit_id" ] || [ "$confirm_hash" != "$design_hash" ]; then
        emit_error_json "design-unit-bind" "$tid" "design_binding_write_unconfirmed" \
            "the write appeared to complete but a fresh read of $tid's own comments does not show unit_id=$unit_id design_hash=$design_hash as the latest DESIGN-UNIT record (found unit_id=${confirm_unit:-<none>} instead). add_comment() cannot distinguish a transient store failure from success (claude-workflow-plugin-nod4), so this is refused rather than reported recorded on unconfirmed evidence. Re-run: qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id$retry_rebind_hint; if this persists, check bd connectivity and $SYNC_ERRORS_LOG" \
            "qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id"
        exit 5
    fi
# WRITE-CONFIRMATION-GATE END (fkm.6, R2-F3)

    emit_json 1 "design-unit-bind" "$tid" "recorded" \
        "comment posted at $ts: $comment_text"
}

# latest_design_unit_binding <tid> — JSON {design_task, unit_id, design_hash}
# from the LAST `DESIGN-UNIT v1 ` comment ON <tid> itself, or `{}` when none
# exists. Deliberately NEVER falls back to a parent epic (contrast
# grilling_record_exists): a binding names WHICH task implements WHICH unit,
# a fact about <tid> specifically, and there is no "one binding covers every
# unit under this epic" analogue the way one grilling dialogue can cover
# every unit's design.
#
# Byte-identical shape to latest_design_review: ONE anchored capture over
# every field a caller needs, so first/last cannot diverge — `startswith
# ("DESIGN-UNIT v1 ")` plus a single `capture(...)` carrying the SAME
# classes the writer above validated: design_task [A-Za-z0-9._+-]+ (the bjx
# default task-id class), unit_id [A-Za-z0-9._-]+ (the STRICTER schema
# class), design_hash EXACTLY [0-9a-fA-F]{64} — not the looser
# [A-Za-z0-9-]+ this reader shipped with (R1-F4, review round 1):
# the writer only ever emits a value that ALREADY passed is_sha256_hex
# (exactly 64 hex, either case), so a reader accepting anything shorter, or
# carrying non-hex letters, or of the wrong length, accepts a hand-written
# or corrupted record the writer could never have produced. The capture
# additionally requires the literal ` at ` boundary immediately after the
# hash — the writer's own next token is always `at <ts>: <summary>` — so
# `design_hash=<h> anything-that-is-not-at` is refused rather than silently
# matched on a bare trailing space.
#
# FAILURE CHANNEL (xsu1 H2-F2): `{}` + rc 0 now means exactly one thing — the
# comment stream was RETRIEVED (design_comments_json's proof rule, xsu1
# H2R2-F1) and carries no matching DESIGN-UNIT record (a determined "never
# bound"). rc 3 with NO stdout means the source could not be read: bd absent,
# both `bd show` forms failed (task unreadable or nonexistent), unparseable
# JSON, or a response that did not provably carry the comment stream. The old
# contract ("never fails the caller: no bd, no task, unparseable JSON -> {},
# rc 0") conflated the two, which made design-unit-show report an unreadable
# source as the legitimate determined result bound:false. As of H2R2-F2 there
# are NO fail-open call sites left: design-unit-bind's two pre-write checks
# and its post-write confirmation, design-conform's resolution step, and
# design-unit-show all capture rc 3 and refuse with their own named key
# (design_binding_unreadable / design_binding_confirm_unreadable) instead of
# reading the failure as an absent binding.
#
# R2-F1 (review round 2): R1-F4 tightened hash width/class and the ` at `
# boundary, but two gaps remained. FIRST, `task=` was matched but never
# named or checked against <tid> — bd_show_with_comments already scopes to
# comments ON <tid>, but nothing stopped a comment carrying a FOREIGN
# `task=` value (copied, mis-posted, or hand-forged) from reading as a valid
# binding on the task it happens to sit on. `task` is now a named capture,
# compared against $tid via a jq --arg (never interpolated into the regex
# source — the same capture-then-compare shape used everywhere else in this
# file, so a task id containing a regex metacharacter cannot alter the
# pattern). A non-matching task drops the record the same way a malformed
# hash already does (jq's capture() produces NO output on a failed match —
# it does not throw here, verified directly against this exact pipeline
# shape before shipping it — so this select is a plain, safe filter, not a
# new failure mode). SECOND, nothing after the ` at ` boundary was
# validated at all, so `at garbage` (no timestamp) still matched. The
# writer's $ts is always `date -u +%Y-%m-%dT%H:%M:%SZ`; the anchor now
# requires that exact shape plus the literal `: ` the writer's own
# `at $ts: $summary` template always emits next. Not captured/returned
# (no caller reads a timestamp) — validated inline only, so a forged or
# corrupted timestamp is refused the same way a forged hash already is.
# The returned object is reshaped back to the documented {design_task,
# unit_id, design_hash} above — `task` is consumed by the filter, not
# exposed, so this function's return CONTRACT is unchanged.
latest_design_unit_binding() {
    local tid="$1"
    local comments="" c_rc=0
    comments=$(design_comments_json "$tid") || c_rc=$?
    [ "$c_rc" -eq 0 ] || return 3
    local out="" out_rc=0
    out=$(printf '%s' "$comments" \
        | jq -c --arg tid "$tid" '
            [ .[].text
              | select(startswith("DESIGN-UNIT v1 "))
              | capture("^DESIGN-UNIT v1 task=(?<task>[A-Za-z0-9._+-]+) design_task=(?<design_task>[A-Za-z0-9._+-]+) unit_id=(?<unit_id>[A-Za-z0-9._-]+) design_hash=(?<design_hash>[0-9a-fA-F]{64}) at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: ")
              | select(.task == $tid)
              | {design_task, unit_id, design_hash}
            ]
            | last // {}
        ' 2>/dev/null) || out_rc=$?
    if [ "$out_rc" -ne 0 ] || [ -z "$out" ]; then
        return 3
    fi
    printf '%s' "$out"
    return 0
}
# DESIGN-UNIT END (fkm.6)

# ---------------------------------------------------------------------------
# DESIGN-CONFORM BEGIN (fkm.6)
#
# design-conform <task-id> — deterministic, no LLM, no bypass flag.
#
# Answers one question: did <task-id> — bound (via DESIGN-UNIT above) to a
# unit in a SATISFIED design — touch any file its unit did not declare?
# `undeclared` (actual - declared) is the ONLY failure; `unbuilt` (declared -
# actual) is reported but never gates — an extra file is scope the design
# never reviewed, while a missing file is under-delivery the acceptance
# criteria already catch. Exactly two remedies for `undeclared_files`: drop
# the file from the change set, or land a design amendment (through D2's
# review loop) and re-bind. NO OVERRULE PATH — deliberately no flag exists
# to pass one.
#
# NOT WIRED INTO `approve` IN THIS SLICE. Built and tested standalone; the
# enforcement decision (where, and under what bypass if any) is deferred.
#
# RESOLUTION ORDER, each step reusing an existing predicate rather than
# re-deriving it:
#   1. Resolve the binding (latest_design_unit_binding). Absent -> the SAME
#      `unit_not_in_design` key step 2 below also uses — from the caller's
#      side, "never bound" and "bound to a unit that no longer exists" are
#      the same actionable fact: this task is not currently mapped into any
#      unit design-conform can check. UNREADABLE (reader rc 3) is a
#      DIFFERENT fact with a different key (xsu1 H2R2-F2):
#      `design_binding_unreadable`, exit 2 — the source was never read, so
#      neither "bind it first" nor any conformance verdict can honestly be
#      offered.
#   2. compute_design_satisfied on the RESOLVED design_task. This IS the
#      "recompute the live hash; a mismatch is design_hash_stale" step —
#      not reimplemented here, because compute_design_satisfied's own
#      staleness ladder already ends in exactly that comparison, and a
#      second hash-vs-hash check beside it would be a second implementation
#      of one predicate, free to disagree with the first the way this
#      file's own history warns against. Every one of compute_design_
#      satisfied's non-satisfied keys (no_design_attempted,
#      design_verdict_missing, design_not_satisfied, design_hash_unreadable,
#      design_artifact_unreadable, design_verdict_stale) propagates
#      VERBATIM as design-conform's own error_key.
#   3. Re-validate via review-check.sh validate-design (the ONE validator)
#      and confirm the bound unit_id is STILL declared — an amendment can
#      rename or drop units between binding and conform time — else
#      `unit_not_in_design`, naming the stale bound hash so a human can see
#      whether a re-bind is warranted.
#   4. declared = unit_files[unit_id] from validate-design's envelope (v5
#      D4 addition, review-check.sh emit_validate_design) — no second
#      parser for the DESIGN-UNITS grammar.
#   5. actual = impact-report.sh --relativized-changed-files — the SAME
#      canonical, denylist-filtered change set `approve`/`--hash-only`
#      hash, relativized so a Write/Edit-tracked absolute path and a
#      reconcile_tracker-appended git-relative path compare equal to the
#      design's always-relative `files[]` declarations. Deliberately NOT
#      re-derived from $QA_TRACKING_DIR/changed-files.txt directly here:
#      the tracker mixes absolute (post-edit.sh writes tool_input.file_path
#      VERBATIM) and repo-relative (reconcile_tracker's git-status backfill)
#      spellings for the SAME file, and a naive string-set diff would show
#      the identical file as BOTH undeclared (its absolute spelling) AND
#      unbuilt (its declared relative spelling) — reusing
#      relativize_for_impact's git-aware, sibling-worktree-safe
#      normalisation (impact-report.sh's own "Path relativisation for
#      impact_of" header) is what closes that, and reusing it is cheaper
#      and safer than a second, naive implementation.
#   6. undeclared = actual - declared, unbuilt = declared - actual. Gate on
#      undeclared only.
#
# DEGRADE HONESTLY, PER STEP: jq missing, the validator missing, the design
# artifact unreadable, the fence unparseable, or the change-set read itself
# failing (impact-report.sh's own FATAL guard, e.g. workflow-denylist.sh
# missing) all refuse with a DISTINCT error_key and a non-zero exit. None of
# them fall through to an empty actual/declared set that would silently read
# as "conforms" — the ONE thing this subcommand's own spec forbids.
#
# EXIT CODES: 1 usage/argument error; 2 infrastructure unavailable (bd, jq,
# the validator, the hash tool, impact-report.sh itself, or — xsu1 H2R2-F2 —
# a binding source that could not be read at all); 4 a substantive
# gate failure (no/unmatched binding, an unsatisfied or stale governing
# design, or undeclared_files itself) — matching design-gate-precheck's own
# use of 4 for "not ready", the closest existing precedent for this family.

# emit_design_conform <ok> <error_key> <observations> <undeclared-json>
#                     <unbuilt-json> [unit_id] [design_task] [task_id]
# Same custom-envelope shape emit_validate_design uses for the SAME reason:
# the generic emit_json/emit_error_json envelopes have no room for the
# structured undeclared_files/unbuilt_files arrays a caller needs to act on
# without re-parsing free text.
emit_design_conform() {
    local ok="$1" ekey="$2" obs="$3" undeclared="$4" unbuilt="$5" \
          unit_id="${6:-}" design_task="${7:-}" tid="${8:-}"
    # shellcheck disable=SC2016
    printf '{"ok":%s,"subcommand":"design-conform","task_id":%s,"error_key":%s,"observations":%s,"unit_id":%s,"design_task":%s,"undeclared_files":%s,"unbuilt_files":%s}\n' \
        "$ok" \
        "$(printf '%s' "$tid" | jq -Rs .)" \
        "$(printf '%s' "$ekey" | jq -Rs .)" \
        "$(printf '%s' "$obs" | jq -Rs .)" \
        "$(printf '%s' "$unit_id" | jq -Rs .)" \
        "$(printf '%s' "$design_task" | jq -Rs .)" \
        "$undeclared" \
        "$unbuilt"
}

cmd_design_conform() {
    # jq AVAILABILITY IS CHECKED FIRST, before anything else in this
    # function, and reported WITHOUT emit_design_conform — deliberately.
    # Every emit_design_conform call (like every emit_error_json/emit_json
    # call in this whole file) builds its JSON THROUGH jq (`jq -Rs .` per
    # interpolated field). A check that discovers jq is missing and then
    # tries to REPORT that fact via the SAME jq-dependent emitter produces
    # exactly the bug this guards against: `jq: command not found` on
    # stderr (once per interpolated field) and a SYNTACTICALLY INVALID JSON
    # object on stdout — bare commas where string values belong
    # (`"task_id":,"error_key":,...`) — that no downstream reader, including
    # this repo's own `json_field` test helper, can parse. Measured directly
    # building this rather than assumed. This is the ONE message in the
    # subcommand that is hand-built without jq: every field is either a
    # fixed literal or JSON `null`/`[]`, so there is nothing here for a
    # missing jq to have to escape.
    if ! command -v jq >/dev/null 2>&1; then
        printf '{"ok":false,"subcommand":"design-conform","task_id":null,"error_key":"jq_unavailable","observations":"jq is required to compute the declared/actual file-set difference and is not on PATH; refusing rather than silently reporting an empty (vacuously conforming) set","unit_id":null,"design_task":null,"undeclared_files":[],"unbuilt_files":[]}\n'
        exit 2
    fi

    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_design_conform "false" "missing_task_id" \
            "design-conform requires <task-id> as first positional argument" \
            "[]" "[]" "" "" ""
        exit 1
    fi
    shift || true
    if [ "$#" -gt 0 ]; then
        emit_design_conform "false" "unknown_flag" \
            "unknown argument '$1'; design-conform takes only <task-id> — there is no bypass flag by design (undeclared_files has exactly two remedies: drop the file, or land a design amendment and re-bind)" \
            "[]" "[]" "" "" "$tid"
        exit 1
    fi

    require_bd "design-conform" "$tid"

    # --- 1: resolve the binding ---------------------------------------------
    local binding_json="" binding_rc=0 design_task unit_id
    binding_json=$(latest_design_unit_binding "$tid") || binding_rc=$?
    # (xsu1 H2R2-F2) An UNREADABLE binding source is not "never bound". The
    # old `|| binding_json="{}"` rewrote a failed read as unit_not_in_design
    # — a determined claim whose remedy ("bind it first") is wrong when the
    # source was simply not readable. The rc-capture line above is spelled
    # BYTE-IDENTICALLY to design-unit-show's own so design-accessors.test.sh
    # Section 3's mutant restores the historical fail-open shape at both
    # call sites in one substitution.
    if [ "$binding_rc" -ne 0 ]; then
        emit_design_conform "false" "design_binding_unreadable" \
            "the DESIGN-UNIT binding source for $tid could not be read (both bd show forms failed, the comment stream was not retrievable, or it did not parse); whether a binding exists is unknown — refusing rather than rewriting an unread source as unit_not_in_design" \
            "[]" "[]" "" "" "$tid"
        exit 2
    fi
    design_task=$(printf '%s' "$binding_json" | jq -r '.design_task // ""' 2>/dev/null || echo "")
    unit_id=$(printf '%s' "$binding_json" | jq -r '.unit_id // ""' 2>/dev/null || echo "")
    if [ -z "$design_task" ] || [ -z "$unit_id" ]; then
        emit_design_conform "false" "unit_not_in_design" \
            "no DESIGN-UNIT binding record exists for $tid; nothing to conform against. Bind it first: qa-gate.sh design-unit-bind $tid --design-task <design-tid> --unit-id <U-n>" \
            "[]" "[]" "" "" "$tid"
        exit 4
    fi

    # --- 2: the governing design must be satisfied AND fresh ----------------
    compute_design_satisfied "$design_task"
    if [ "$DESIGN_SATISFIED" != "true" ]; then
        emit_design_conform "false" "$DESIGN_SATISFIED_KEY" \
            "$DESIGN_SATISFIED_OBS (governing design task: $design_task)" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 4
    fi
    # Snapshot the confirmed-fresh hash into a LOCAL right away (R1-F2,
    # review round 1): the global DESIGN_VERDICT_HASH is compute_design
    # _satisfied's own output variable, and pinning it to a local here means
    # nothing later in this function can observe a value some other call
    # changed out from under it — the same discipline the bracket below needs
    # to be meaningful at all.
    local expected_design_hash="$DESIGN_VERDICT_HASH"

    # --- 3: the bound unit_id must still be declared in the CURRENT artifact
    local artifact vout vout_rc=0 vkey vobs unit_files declared_json
    artifact=$(design_artifact_path_for "$design_task")
    if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
        emit_design_conform "false" "validator_unavailable" \
            "cannot conform: the ONE validator is missing at $REVIEW_CHECK_SCRIPT" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 2
    fi
    vout=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" validate-design "$artifact" 2>/dev/null) || vout_rc=$?
    if ! validate_design_envelope_ok "$vout_rc" "$vout"; then
        vkey=$(printf '%s' "$vout" | jq -r '.error_key // "invalid_design_artifact"' 2>/dev/null || echo "invalid_design_artifact")
        [ -z "$vkey" ] && vkey="invalid_design_artifact"
        vobs=$(printf '%s' "$vout" | jq -r '.observations // ""' 2>/dev/null || echo "")
        emit_design_conform "false" "$vkey" \
            "design-conform could not re-validate the artifact governing $design_task (validator exit rc=$vout_rc): $vkey${vobs:+ — $vobs}" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 4
    fi

    # --- CLOSING BRACKET (R1-F2, review round 1) ------------------
    # compute_design_satisfied (step 2) confirmed the artifact matched the
    # reviewed hash at ITS OWN read. validate-design, just above, is a
    # SEPARATE, LATER read of the same path — unbracketed, a schema-valid
    # artifact B swapped in between the two drives the set difference below
    # with declarations no reviewer ever confirmed, and could still reach
    # ok:true. Re-hash NOW, before trusting anything validate-design just
    # read, and refuse if the artifact moved. Same TOCTOU discipline as
    # design-record's and design-unit-bind's own pre/post brackets — reused
    # (the same workflow-manifest.sh instrument, the same is_sha256_hex
    # shape check), not invented.
    # `x=$(cmd); rc=$?` is NOT errexit-safe here either: under `set -e`
    # (line 156), if hash-file itself fails (not just returns a mismatched
    # hash — e.g. the artifact was DELETED rather than merely edited between
    # validate-design and this re-hash), the bare assignment's own exit
    # status IS the failing status, and the whole script exits right there,
    # before `post_conform_rc=$?` or the mismatch check below ever run —
    # crashing with no envelope instead of reaching design_verdict_stale.
    # `cmd || rc=$?` avoids this the same way the R1-F1 checkpoints below
    # do: see the comment on actual_json further down for the full
    # explanation. Do not "simplify" this back to a two-line form.
    local post_conform_hash="" post_conform_rc=0
    post_conform_hash=$(bash "$PROJECT_DIR/.claude/scripts/workflow-manifest.sh" hash-file "$artifact" 2>/dev/null) || post_conform_rc=$?
    if [ "$post_conform_rc" -ne 0 ] || ! is_sha256_hex "$post_conform_hash" \
        || [ "$post_conform_hash" != "$expected_design_hash" ]; then
        emit_design_conform "false" "design_verdict_stale" \
            "the design artifact governing $design_task changed between the satisfaction check and the declarations read (expected design_hash=$expected_design_hash, now ${post_conform_hash:-<unreadable, rc=$post_conform_rc>}); refusing rather than computing undeclared/unbuilt against declarations no reviewer confirmed. Re-run once the artifact has stopped moving, or re-review it if the change was deliberate" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 4
    fi

    unit_files=$(printf '%s' "$vout" | jq -c '.unit_files // {}' 2>/dev/null || echo "{}")
    declared_json=$(printf '%s' "$unit_files" | jq -c --arg u "$unit_id" '.[$u] // null' 2>/dev/null || echo "null")
    if [ "$declared_json" = "null" ]; then
        local bound_hash
        bound_hash=$(printf '%s' "$binding_json" | jq -r '.design_hash // "?"' 2>/dev/null || echo "?")
        emit_design_conform "false" "unit_not_in_design" \
            "unit_id=$unit_id (bound at design_hash=$bound_hash) is no longer declared in $artifact's CURRENT DESIGN-UNITS block — the design was likely amended without re-binding this task. Amend and re-bind: qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id <current-unit-id> --rebind '<reason>'" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 4
    fi

    # --- 4/5: actual — the SAME canonical, denylist-filtered, relativized ---
    # change set the gate hashes.
    local impact_tool actual_raw actual_rc=0
    impact_tool="$PROJECT_DIR/.claude/scripts/impact-report.sh"
    if [ ! -f "$impact_tool" ]; then
        emit_design_conform "false" "impact_tool_unavailable" \
            "cannot compute the actual change set: impact-report.sh is missing at $impact_tool" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 2
    fi
    # stderr is captured to a file (not discarded) so an UNNORMALIZABLE
    # refusal below can name the specific path(s) rather than just the fact
    # (R1-F3, review round 1).
    local actual_stderr_file
    actual_stderr_file=$(mktemp -t design-conform-stderr.XXXXXX 2>/dev/null) || actual_stderr_file="$QA_TRACKING_DIR/.design-conform-stderr-$$.txt"
    actual_raw=$(bash "$impact_tool" --relativized-changed-files 2>"$actual_stderr_file") || actual_rc=$?
    # R1-F3 (review round 1): exit 4 from --relativized-changed-
    # files is a SPECIFIC, distinct signal — one or more tracked paths could
    # not be normalised to a project-relative spelling at all (not merely
    # "the whole computation failed", which is what a GENERIC nonzero exit
    # below still means). undeclared_files means "the design didn't declare
    # this file"; this means "this file's path could not even be compared" —
    # two different claims that used to be conflated into one.
    if [ "$actual_rc" -eq 4 ]; then
        local unnorm_detail=""
        unnorm_detail=$(head -5 "$actual_stderr_file" 2>/dev/null)
        rm -f "$actual_stderr_file"
        emit_design_conform "false" "change_set_path_unnormalizable" \
            "one or more tracked paths could not be normalised to a project-relative spelling (neither a sibling-worktree match nor an unambiguous \$PROJECT_DIR-prefixed path — most commonly a path whose containing directory no longer exists on disk in a way this could not resolve). This is NOT the same claim as undeclared_files: the design may have declared exactly this file. Remedy: restore the directory if the deletion was accidental, or if the tracked entry is stale, reconcile/trim it from the tracker (qa-gate.sh reconcile-tracker) before re-running conform.${unnorm_detail:+ Detail: $unnorm_detail}" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 4
    fi
    rm -f "$actual_stderr_file"
    if [ "$actual_rc" -ne 0 ]; then
        emit_design_conform "false" "change_set_unreadable" \
            "impact-report.sh --relativized-changed-files exited $actual_rc; refusing to compute undeclared/unbuilt over a change set that could not be read (never reporting \"conforms\" on evidence that was never actually read)" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 2
    fi

    # --- 6: the difference ---------------------------------------------------
    # R1-F1 (review round 1): every step here used to be `cmd ||
    # var="[]"`/`"0"`, so a jq EXECUTION failure (present, but crashing mid
    # -computation — not the "jq missing" case cmd_design_conform's own first
    # line already refuses) fell through to an EMPTY difference and reached
    # the ok:true emitter below. undeclared_files has deliberately no
    # overrule path, so THIS is the one direction that must never fail open:
    # a set difference that did not compute must never read as an empty one.
    # Every jq call below is now checked on ITS OWN exit status AND the shape
    # of what it produced (never trusted from a bare rc==0 alone), and ANY
    # failure refuses with a dedicated, fail-closed error_key rather than
    # silently defaulting toward "conforms".
    local actual_json diff_json undeclared_json unbuilt_json undeclared_n unbuilt_n
    local aj_rc=0 diff_rc=0
    # `x=$(cmd); rc=$?` is NOT errexit-safe: under `set -e` (line 156) a bare
    # assignment statement's exit status IS the substitution's, so a failing
    # cmd exits the WHOLE SCRIPT at the assignment itself — `rc=$?` on the
    # next line never runs. This is what design-conform.test.sh Section 10
    # (R1-F1 regression coverage) originally caught: the process died with
    # the jq shim's own raw exit code and no envelope at all, instead of
    # reaching the fail-closed check below. `cmd || rc=$?` is the fix: the
    # `||` makes the compound command's own status 0 whichever side ran, so
    # errexit never fires, and rc still gets the real failing status (the
    # right-hand assignment only runs, and only overwrites rc, on failure).
    actual_json=$(printf '%s' "$actual_raw" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || aj_rc=$?
    if [ "$aj_rc" -ne 0 ] || ! printf '%s' "${actual_json:-}" | jq -e 'type == "array"' >/dev/null 2>&1; then
        emit_design_conform "false" "set_computation_failed" \
            "could not parse the actual (relativized) change set as a JSON array — jq exited $aj_rc turning impact-report.sh's output into JSON. Refusing rather than computing undeclared/unbuilt over a set that did not actually compute" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 2
    fi

    # Same errexit hazard, same `cmd || rc=$?` fix — see the comment on
    # actual_json above; do not "simplify" this back to a two-line `x=$(...);
    # rc=$?` form.
    diff_json=$(jq -nc --argjson a "$actual_json" --argjson d "$declared_json" '
        ($a - $d) as $undeclared | ($d - $a) as $unbuilt
        | { undeclared: ($undeclared | sort), unbuilt: ($unbuilt | sort),
            undeclared_n: ($undeclared | length), unbuilt_n: ($unbuilt | length) }
    ' 2>/dev/null) || diff_rc=$?
    if [ "$diff_rc" -ne 0 ] || ! printf '%s' "${diff_json:-}" | jq -e '
            (.undeclared | type) == "array" and (.unbuilt | type) == "array"
            and (.undeclared_n | type) == "number" and (.unbuilt_n | type) == "number"
        ' >/dev/null 2>&1; then
        emit_design_conform "false" "set_computation_failed" \
            "could not compute the undeclared/unbuilt set difference — jq exited $diff_rc. Refusing rather than computing an assumed-empty difference" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 2
    fi
    undeclared_json=$(printf '%s' "$diff_json" | jq -c '.undeclared' 2>/dev/null) || undeclared_json=""
    unbuilt_json=$(printf '%s' "$diff_json" | jq -c '.unbuilt' 2>/dev/null) || unbuilt_json=""
    undeclared_n=$(printf '%s' "$diff_json" | jq -r '.undeclared_n' 2>/dev/null) || undeclared_n=""
    unbuilt_n=$(printf '%s' "$diff_json" | jq -r '.unbuilt_n' 2>/dev/null) || unbuilt_n=""
    if [ -z "$undeclared_json" ] || [ -z "$unbuilt_json" ] \
        || ! [[ "$undeclared_n" =~ ^[0-9]+$ ]] || ! [[ "$unbuilt_n" =~ ^[0-9]+$ ]]; then
        emit_design_conform "false" "set_computation_failed" \
            "could not extract the already-validated undeclared/unbuilt result. Refusing rather than guessing at a set that did not extract cleanly" \
            "[]" "[]" "$unit_id" "$design_task" "$tid"
        exit 2
    fi

# UNDECLARED-FILES-GATE BEGIN (fkm.6)
    # THE ONLY FAILURE THIS SUBCOMMAND HAS. Sentinel-wrapped on its own
    # (narrower than the DESIGN-CONFORM block around it) so a META test can
    # excise exactly the enforcement point without also deleting the
    # subcommand it lives in — the difference between "the gate is
    # load-bearing" and "the subcommand doesn't exist".
    if [ "${undeclared_n:-0}" != "0" ]; then
        emit_design_conform "false" "undeclared_files" \
            "$undeclared_n file(s) touched for $tid (unit_id=$unit_id, design_task=$design_task) are outside its declared file set — scope the design never reviewed. Exactly two remedies: drop the file(s) from the change set, or land a design amendment (qa-gate.sh design-review-record) declaring them and re-bind (qa-gate.sh design-unit-bind $tid --design-task $design_task --unit-id $unit_id --rebind '<reason>'). No overrule path" \
            "$undeclared_json" "$unbuilt_json" "$unit_id" "$design_task" "$tid"
        exit 4
    fi
# UNDECLARED-FILES-GATE END (fkm.6)

    local obs="conforms: $tid (unit_id=$unit_id, design_task=$design_task) touched no files outside its declared set"
    [ "${unbuilt_n:-0}" != "0" ] && obs="$obs; $unbuilt_n declared file(s) not yet touched (informational — unbuilt never gates)"
    emit_design_conform "true" "" "$obs" "[]" "$unbuilt_json" "$unit_id" "$design_task" "$tid"
}
# DESIGN-CONFORM END (fkm.6)

# ---------------------------------------------------------------------------
# DESIGN-UNIT-SHOW / DESIGN-STATUS BEGIN (v5 D4b, fkm.6)
#
# Two thin, read-only accessors built for exactly one caller:
# epic-gate.sh plan-batches, which runs as a SEPARATE PROCESS and therefore
# cannot call latest_design_unit_binding / compute_design_satisfied
# directly. Both predicates are ALREADY the one authoritative implementation
# of their question (review-check.sh's own header states the doctrine:
# extracting data with a second parser "is the thing this script exists to
# prevent"; qa-gate.sh:8142-8144 restates it for DESIGN-UNITS specifically).
# These two functions add ZERO new logic — they format an EXISTING global-
# setting function's result as a JSON envelope and nothing else. Neither
# writes anything (no add_comment, no lock, no record).
#
# WHY TWO, NOT ONE. design-unit-show answers "what unit is <tid> bound to"
# (a fact about an IMPLEMENTING task). design-status answers "is <tid>'s
# OWN design satisfied" (a fact about a DESIGN-OWNING task — typically an
# epic). plan-batches needs BOTH, about DIFFERENT tasks (each child, and the
# epic itself) — folding them into one accessor would conflate two
# questions that happen to share a return-JSON-about-a-task shape but not a
# subject.
#
# WHY NOT design-gate-precheck FOR THE SECOND ONE. design-gate-precheck
# (B5, v5 D2) is a correct, DELIBERATE UI simplification for its own one
# caller: it maps `no_design_attempted` to "ready" because the overwhelming
# majority of tasks never have a design phase, and firing on all of them
# "trains an operator to ignore its output" (qa-gate.sh:7527-7534). That
# same leniency, reused here, would make plan-batches indistinguishable
# between "this epic's design is satisfied — compute real batches" and
# "this epic never had a design — there is nothing to batch" — both would
# read ok:true/status:"ready" with no way to tell them apart. Guard
# condition 4 (docs/plans/v5-design-phase.md:158-159, the D4b delegation
# brief) is explicit that BOTH must degrade, just with a different tone in
# the prose (quiet for "never started", loud for "started but not
# reviewed") — a distinction design-gate-precheck's own envelope cannot
# carry. So this is a SEPARATE, UNFILTERED reader of the SAME predicate,
# not a second implementation of it and not a reuse of the filtered one.

# print_envelope_checked <subcommand> <envelope-json> <build-rc>
# (xsu1 H2-F4) The accessors below build every envelope that carries
# caller-derived data with ONE guarded `jq -nc` assignment at the call site
# (`envelope=$(jq -nc ...) || env_rc=$?`) — never with jq substitutions
# inlined into printf arguments, because under `set -e` a failed inner
# substitution does NOT abort when the outer printf succeeds
# (`printf '{"x":%s}\n' "$(false)"` prints `{"x":}` and continues, rc 0 —
# reproduced before this fix). This helper is the second half of that
# discipline: it checks the build rc, non-emptiness AND (R7-F5) the exact
# per-subcommand envelope SHAPE — parseability alone accepts [] / {} / a
# wrong object, because `jq -n -e '[]'` is rc 0 — prints
# the envelope on success, and on ANY failure prints a CALLER-DATA-FREE
# literal error envelope instead — <subcommand> is a fixed literal at every
# call site, never caller input — and returns 1 so the caller exits nonzero
# rather than reporting malformed output with a success status. The literal
# carries the full accessor field set (bound/satisfied and their siblings
# are deliberately ABSENT here: a consumer must not read a determined answer
# out of a construction failure; epic-gate.sh's well-formedness checks
# require those keys via has(), so their absence degrades the consumer
# loudly, which is the point).
print_envelope_checked() {
    local sub="$1" envelope="$2" build_rc="$3"
    # (xsu1 R7-F5) The expected shape is selected per subcommand; an
    # UNREGISTERED subcommand gets jq `false` (always the literal fallback),
    # so a future accessor cannot inherit the weaker check by forgetting to
    # add its shape here. Stripping the sentinel region leaves the
    # historical parseability-only `.` — the L1 META does exactly that and
    # watches a parseable-but-wrong build ([] at rc 0) print under a
    # success status.
    local shape_prog='.'
# ENVELOPE-SHAPE-GATE BEGIN (xsu1 R7-F5)
    case "$sub" in
        design-unit-show)
            shape_prog='
                # design-unit-show envelope shape (xsu1 R7-F5)
                type == "object"
                and (keys | sort) == ["bound", "design_hash", "design_task", "error_key", "observations", "ok", "subcommand", "task_id", "unit_id"]
                and (.ok | type) == "boolean"
                and .subcommand == "design-unit-show"
                and (.task_id | type) == "string"
                and (.error_key | type) == "string"
                and (.bound | type) == "boolean"
                and (.design_task | type) == "string"
                and (.unit_id | type) == "string"
                and (.design_hash | type) == "string"
                and (.observations | type) == "string"
            ' ;;
        design-status)
            shape_prog='
                # design-status envelope shape (xsu1 R7-F5)
                type == "object"
                and (keys | sort) == ["artifact_path", "design_hash", "error_key", "observations", "ok", "satisfied", "subcommand", "task_id"]
                and (.ok | type) == "boolean"
                and .subcommand == "design-status"
                and (.task_id | type) == "string"
                and (.satisfied | type) == "boolean"
                and (.error_key | type) == "string"
                and (.observations | type) == "string"
                and (.design_hash | type) == "string"
                and (.artifact_path | type) == "string"
            ' ;;
        *) shape_prog='false' ;;
    esac
# ENVELOPE-SHAPE-GATE END (xsu1 R7-F5)
    if [ "$build_rc" -eq 0 ] && [ -n "$envelope" ] \
       && printf '%s' "$envelope" | jq -e "$shape_prog" >/dev/null 2>&1; then
        printf '%s\n' "$envelope"
        return 0
    fi
    printf '{"ok":false,"subcommand":"%s","task_id":null,"error_key":"envelope_construction_failed","observations":"the response envelope could not be constructed (jq failed, or produced unparseable or wrong-shaped output); refusing to print it under a success status. No caller-supplied data is included in this message"}\n' "$sub"
    return 1
}

# design-unit-show <task-id>
# Envelope: {ok, subcommand, task_id, error_key, bound, design_task,
#            unit_id, design_hash, observations}. `bound` is the
# caller-facing signal; design_task/unit_id/design_hash are "" (not null —
# matching this file's OWN convention for an absent string field, e.g.
# emit_design_conform's unit_id/design_task on every error path) when
# bound=false, and error_key is "" on every ok:true envelope (the same
# convention design-status has always used).
# Exit 0 ONLY for a DETERMINED answer — bound:true with the full validated
# triple, or bound:false read from a successfully-parsed comment stream.
# Exit 1 usage. Exit 2 infra: jq/bd unavailable, AND (xsu1 H2-F2/F3/F4)
#   design_binding_unreadable    the binding source could not be read (both
#                                `bd show` forms failed, unparseable comment
#                                JSON, or — xsu1 H2R2-F1 — a response that
#                                did not provably carry the comment stream)
#                                — previously misreported as
#                                the determined answer bound:false;
#   design_binding_malformed     the reader returned something that is
#                                neither {} nor a complete, valid
#                                {design_task, unit_id, design_hash} triple
#                                (64-hex hash, non-empty class-checked ids)
#                                — refused rather than emitted partially;
#   envelope_construction_failed the final JSON encode itself failed (see
#                                print_envelope_checked above).
cmd_design_unit_show() {
    if ! command -v jq >/dev/null 2>&1; then
        printf '{"ok":false,"subcommand":"design-unit-show","task_id":null,"error_key":"jq_unavailable","observations":"jq is required to read the DESIGN-UNIT binding and is not on PATH","bound":false,"design_task":"","unit_id":"","design_hash":""}\n'
        exit 2
    fi

    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "design-unit-show" "" "missing_task_id" \
            "design-unit-show requires <task-id> as first positional argument" \
            "qa-gate.sh design-unit-show <task-id>"
        exit 1
    fi
    shift || true
    if [ "$#" -gt 0 ]; then
        emit_error_json "design-unit-show" "$tid" "unknown_flag" \
            "unknown argument '$1'; design-unit-show takes only <task-id>" \
            "qa-gate.sh design-unit-show <task-id>"
        exit 1
    fi

    require_bd "design-unit-show" "$tid"

    local envelope="" env_rc=0
    local binding_json="" binding_rc=0
    binding_json=$(latest_design_unit_binding "$tid") || binding_rc=$?
    if [ "$binding_rc" -ne 0 ]; then
        # (xsu1 H2-F2) The source could not be read — this is NOT the
        # determined answer bound:false, and is no longer reported as one.
        envelope=$(jq -nc --arg tid "$tid" '
            # design-unit-show refusal envelope (xsu1 H2-F2/F3)
            {ok: false, subcommand: "design-unit-show", task_id: $tid,
             error_key: "design_binding_unreadable",
             bound: false, design_task: "", unit_id: "", design_hash: "",
             observations: "the DESIGN-UNIT binding source for \($tid) could not be read (both bd show forms failed, or the comment stream did not parse); whether a binding exists is unknown, which is not the same answer as bound:false"}
        ' 2>/dev/null) || env_rc=$?
        print_envelope_checked "design-unit-show" "$envelope" "$env_rc" || true
        exit 2
    fi

    # (xsu1 H2-F3) ONE validation of the whole union shape — either {} for a
    # confirmed absence, or a complete triple whose fields all satisfy the
    # writer's own classes — instead of three independent extractions of
    # which only unit_id was ever tested (a selective jq failure could emit
    # bound:true with required fields empty).
    local bshape="" bshape_rc=0
    bshape=$(printf '%s' "$binding_json" | jq -er '
        # design-unit-show binding-shape classifier (xsu1 H2-F3)
        if type != "object" then "malformed"
        elif . == {} then "absent"
        elif ( (keys | sort) == ["design_hash", "design_task", "unit_id"]
               and (.design_task | type == "string" and test("^[A-Za-z0-9._+-]+$"))
               and (.unit_id     | type == "string" and test("^[A-Za-z0-9._-]+$"))
               and (.design_hash | type == "string" and test("^[0-9a-fA-F]{64}$")) )
          then "bound"
        else "malformed" end
    ' 2>/dev/null) || bshape_rc=$?

    if [ "$bshape_rc" -ne 0 ] || { [ "$bshape" != "absent" ] && [ "$bshape" != "bound" ]; }; then
        envelope=$(jq -nc --arg tid "$tid" '
            # design-unit-show refusal envelope (xsu1 H2-F2/F3)
            {ok: false, subcommand: "design-unit-show", task_id: $tid,
             error_key: "design_binding_malformed",
             bound: false, design_task: "", unit_id: "", design_hash: "",
             observations: "the DESIGN-UNIT binding read for \($tid) produced neither a confirmed absence ({}) nor a complete valid {design_task, unit_id, design_hash} triple; refusing to report a partial or malformed binding as a determined answer"}
        ' 2>/dev/null) || env_rc=$?
        print_envelope_checked "design-unit-show" "$envelope" "$env_rc" || true
        exit 2
    fi

    local bound_bool="false" design_task="" unit_id="" design_hash="" obs=""
    if [ "$bshape" = "bound" ]; then
        # The triple was validated as a whole above; these splits re-read the
        # validated object, and any failure here (jq breaking mid-run) is
        # refused rather than emitted as bound:true with empty fields.
        local trip_rc=0
        design_task=$(printf '%s' "$binding_json" | jq -re '.design_task' 2>/dev/null) || trip_rc=$?
        unit_id=$(printf '%s' "$binding_json" | jq -re '.unit_id' 2>/dev/null) || trip_rc=$?
        design_hash=$(printf '%s' "$binding_json" | jq -re '.design_hash' 2>/dev/null) || trip_rc=$?
        if [ "$trip_rc" -ne 0 ] || [ -z "$design_task" ] || [ -z "$unit_id" ] || [ -z "$design_hash" ]; then
            envelope=$(jq -nc --arg tid "$tid" '
                # design-unit-show refusal envelope (xsu1 H2-F2/F3)
                {ok: false, subcommand: "design-unit-show", task_id: $tid,
                 error_key: "design_binding_malformed",
                 bound: false, design_task: "", unit_id: "", design_hash: "",
                 observations: "the validated DESIGN-UNIT binding for \($tid) could not be split into its three fields (jq failed mid-run); refusing to report bound:true with required fields missing"}
            ' 2>/dev/null) || env_rc=$?
            print_envelope_checked "design-unit-show" "$envelope" "$env_rc" || true
            exit 2
        fi
        bound_bool="true"
        obs="$tid bound to unit_id=$unit_id under design_task=$design_task"
    else
        obs="no DESIGN-UNIT v1 binding record exists for $tid (the comment stream was read and parsed — this is a determined absence, distinguishable since xsu1 H2-F2 from an unreadable source, which reports ok:false/design_binding_unreadable instead)"
    fi

    envelope=$(jq -nc --arg tid "$tid" --argjson bound "$bound_bool" \
        --arg dt "$design_task" --arg uid "$unit_id" --arg dh "$design_hash" \
        --arg obs "$obs" '
        # design-unit-show success envelope (xsu1 H2-F4)
        {ok: true, subcommand: "design-unit-show", task_id: $tid,
         error_key: "", bound: $bound, design_task: $dt, unit_id: $uid,
         design_hash: $dh, observations: $obs}
    ' 2>/dev/null) || env_rc=$?
    print_envelope_checked "design-unit-show" "$envelope" "$env_rc" || exit 2
    return 0
}

# design-status <task-id>
# Envelope: {ok, subcommand, task_id, satisfied, error_key, observations,
#            design_hash, artifact_path}. error_key is "" when
#            satisfied=true, else compute_design_satisfied's OWN key
#            VERBATIM (including no_design_attempted — no leniency).
#            design_hash is "" unless satisfied=true. artifact_path is
#            ALWAYS populated (design_artifact_path_for is a pure string
#            derivation with no filesystem access, defined even when the
#            file does not exist). Exit 0 for EITHER determined answer.
#            Exit 1 usage, exit 2 infra (jq/bd unavailable) — and, since
#            xsu1 H2-F5, exit 2 with ok:false (satisfied:false RETAINED,
#            error_key=design_source_unreadable verbatim) when the Beads
#            comment stream could not be read at all: an unreadable source
#            used to be indistinguishable from a task that genuinely has no
#            design (both read ok:true/no_design_attempted), which violates
#            "a failed computation degrades loudly rather than masquerading
#            as ordinary absence". envelope_construction_failed (exit 2) is
#            the H2-F4 final-encoder guard, shared with design-unit-show —
#            see print_envelope_checked above.
cmd_design_status() {
    if ! command -v jq >/dev/null 2>&1; then
        printf '{"ok":false,"subcommand":"design-status","task_id":null,"error_key":"jq_unavailable","observations":"jq is required to check design satisfaction and is not on PATH","satisfied":false,"design_hash":"","artifact_path":""}\n'
        exit 2
    fi

    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "design-status" "" "missing_task_id" \
            "design-status requires <task-id> as first positional argument" \
            "qa-gate.sh design-status <task-id>"
        exit 1
    fi
    shift || true
    if [ "$#" -gt 0 ]; then
        emit_error_json "design-status" "$tid" "unknown_flag" \
            "unknown argument '$1'; design-status takes only <task-id>" \
            "qa-gate.sh design-status <task-id>"
        exit 1
    fi

    require_bd "design-status" "$tid"

    compute_design_satisfied "$tid"
    local artifact_path sat_str="false" ok_str="true"
    artifact_path=$(design_artifact_path_for "$tid")
    [ "$DESIGN_SATISFIED" = "true" ] && sat_str="true"

    # DESIGN-STATUS UNREADABLE-SOURCE MAPPING BEGIN (xsu1 H2-F5)
    # design_source_unreadable is the one key that is NOT a determined
    # answer about the design — it means the predicate could not read its
    # source. It keeps satisfied:false (fail-safe for any consumer that only
    # reads that field) but flips ok to false and the exit to 2, so a
    # consumer that checks rc or .ok (epic-gate.sh's design-status ladder
    # checks BOTH) degrades as design_status_unavailable instead of
    # treating "could not look" as "looked, and found no design".
    if [ "$DESIGN_SATISFIED_KEY" = "design_source_unreadable" ]; then
        ok_str="false"
    fi
    # DESIGN-STATUS UNREADABLE-SOURCE MAPPING END (xsu1 H2-F5)

    local envelope="" env_rc=0
    envelope=$(jq -nc --arg tid "$tid" \
        --argjson ok "$ok_str" --argjson sat "$sat_str" \
        --arg ekey "$DESIGN_SATISFIED_KEY" --arg obs "$DESIGN_SATISFIED_OBS" \
        --arg dh "$DESIGN_VERDICT_HASH" --arg ap "$artifact_path" '
        # design-status envelope (xsu1 H2-F4)
        {ok: $ok, subcommand: "design-status", task_id: $tid,
         satisfied: $sat, error_key: $ekey, observations: $obs,
         design_hash: $dh, artifact_path: $ap}
    ' 2>/dev/null) || env_rc=$?
    print_envelope_checked "design-status" "$envelope" "$env_rc" || exit 2
    [ "$ok_str" = "true" ] || exit 2
    return 0
}
# DESIGN-UNIT-SHOW / DESIGN-STATUS END (v5 D4b, fkm.6)

# ---------------------------------------------------------------------------
# DESIGN-CONFLICT BEGIN (v5 D5 / claude-workflow-plugin-fkm.7)
#
# design-conflict <task-id> --unit <unit-id> [--design-hash <h>] '<statement>'
#
# THE PROBLEM THIS RECORD SOLVES. D5's own text: "When a unit's acceptance
# criteria cannot be satisfied as written — the design is wrong, incomplete,
# or contradicted by the code — the implementer returns a design_conflict
# blocker with evidence and stops. It does not reinterpret, improvise, or
# partially satisfy." Before this command existed, an implementer facing
# that choice had exactly two options, both wrong: silently improvise (the
# dilution this whole release exists to stop), or stall with no structured
# record of WHY. This gives a third: file the objection, stop, and let
# cmd_approve's own DESIGN-CONFLICT-REFUSAL block (an unconditional sibling
# of DESIGN-SATISFIED-REFUSAL since claude-workflow-plugin-i8cx) hold the
# line until a design amendment, independently re-reviewed and found
# satisfied, addresses it — there is no longer an operator override that
# waives an open conflict; see that block's own header for the four
# independent review findings that led to removing it. The reader half
# (compute_design_conflict_open) and its wiring into approve are the OTHER
# function; this comment only covers the writer.
#
# UPDATE (claude-workflow-plugin-268l): THE SUBJECT WAS WRONG. Every "$tid"
# above described where a conflict is FILED, but under v5 task-per-unit
# <tid> (the implementer's own task) and the task that owns docs/specs/
# <id>.md can differ BY CONSTRUCTION — this writer used to hard-refuse
# (design_artifact_not_found) on every such task, because it looked for its
# design artifact at the wrong path. It now resolves the subject through
# resolve_design_conflict_subject (above) FIRST: <tid>'s own DESIGN-UNIT
# binding, when one exists, names the actual design_task this is filed
# against; when none exists, <tid> remains its own subject exactly as
# before. See that function's own header for the full rationale, including
# the answered design question for the no-binding case. The GRAMMAR below is
# UNCHANGED by this fix — only WHICH task's stream the record lands on
# moved, never its shape.
#
# GRAMMAR — single line, no version tag, matching the LIGHTER-weight
# records this file already ships (IMPLEMENTER, RESOLVED, ARBITRATION),
# because a conflict is not a schema-versioned artifact binding the way
# DESIGN-ARTIFACT/DESIGN-REVIEW/DESIGN-UNIT are:
#   DESIGN-CONFLICT <unit-id> design_hash=<h> at <ts>: <statement>
# <unit-id> is a BARE positional token (mirrors RESOLVED/ARBITRATION's own
# `<id>` right after the record's type tag), not `unit_id=<val>` — matching
# the exact grammar this task was specified against.
#
# design_hash IS OPTIONAL ON THE COMMAND LINE, NEVER OPTIONAL IN THE
# RECORD, AND — SINCE R2-F3 (independent review round 2, claude-workflow-plugin-i8cx)
# — NEVER MERELY TRUSTED EITHER WAY. When --design-hash is omitted, it is a
# LIVE RECOMPUTE over docs/specs/<task-id>.md (design_artifact_path_for,
# workflow-manifest.sh hash-file) — the SAME "design_hash is a live
# recompute, never a placeholder" doctrine design-unit-bind's own header
# states, checked here with the STRICT is_sha256_hex test because this file
# controls that read end to end. When --design-hash IS given, it is now a
# CONFIRMATION of that SAME live recompute, never an independent source of
# truth — the identical "asserts, never a second source" contract
# epic-gate.sh's own `--design <path>` flag already documents for a sibling
# flag (epic-gate.sh usage(), plan-batches). A value that does not equal the
# live hash is REFUSED (design_hash_not_current), not recorded: the
# ORIGINAL framing here ("a CLAIM the caller makes about what was current
# when they observed the conflict") was exactly the gap Sol's review named
# — a stale or mistyped claim was recorded verbatim and then read back as
# ALREADY not the current design, which is compute_design_conflict_open's
# own CLEARED arm, so the conflict was born cleared. The CHARACTER CLASS
# stays the LOOSER `[A-Za-z0-9-]+`, deliberately still not an is_sha256_hex
# SHAPE check on its own (a future hashing scheme's output need not be 64
# hex either) — but the value now ALSO has to equal whatever the live
# recompute produces right now, whatever shape that happens to be, so the
# looser class no longer means "unverified".
#
# THE bjx SCALAR-CLASS DISCIPLINE — see the DESIGN-CONFLICT-SCALAR-CLASS
# block inside cmd_design_conflict below: unit_id reuses assert_unit_id_
# scalar VERBATIM (D4's own [A-Za-z0-9._-]+ class, review-check.sh's
# schema, fkm.6) rather than a second copy of the identical regex;
# design_hash gets its own inline check for the looser class above. Reject,
# never sanitise, for the usual reason: a silently-rewritten value would
# make the record disagree with what the implementer actually said.
# <statement> is deliberately NOT class-validated — free text, exactly like
# every other record's trailing summary field (DESIGN-REVIEW's `: <summary>`,
# GRILLING's, DESIGN-ARTIFACT's) — because it is the LAST field in the
# grammar: nothing after it can relocate a field boundary that comes
# before it, which is the entire threat class the scalar-class discipline
# exists to close.
#
# WHAT THIS WRITER NOW CHECKS, AND WHY THAT CHANGED (R2-F3, independent review round
# 2). It now DOES validate --unit against the artifact's OWN declared
# unit_ids (unit_not_in_artifact, the SAME key design-unit-bind's own
# UNIT-MEMBERSHIP-GATE already uses for the identical fact) — not a
# re-litigation of the original "lighter, advisory-but-audited claim, not a
# binding assertion" framing, but a STRUCTURAL CONSEQUENCE of R2-F3's fix:
# the record now pins a per-unit content hash (unit_hash=, see
# compute_design_conflict_open's own header for why the clearing predicate
# had to move there), and pinning that to a unit_id nothing declares would
# be meaningless — there would be no bytes for a future amendment to ever
# change. Establishing the unit's current content is therefore required to
# file a conflict against it at all, via design_unit_json (below), which —
# as of independent review round 2's own follow-up fix — asks
# review-check.sh's validate-design for the unit_ids and its new
# design-unit-json subcommand for the one unit's own canonical bytes, rather
# than reading the artifact's machine block directly. See design_unit_json's
# own header for why that changed.
#
# STILL NO INDEPENDENCE CHECK, unchanged from the original design: unlike
# design-review-record, a design_conflict's author is not compared against
# any designer= identity. That question was never in this task's scope and
# R2-F3 does not touch it.
#
# design_unit_json / design_declared_unit_ids / design_unit_content_hash —
# R2-F3's shared machinery, used by BOTH this writer (membership + the
# pinned unit_hash) and compute_design_conflict_open below (the live
# re-derive the clearing predicate compares against).
#
# ROUND 2 OF INDEPENDENT REVIEW ON THIS SAME FINDING (claude-workflow-plugin-
# i8cx) REVERSED HOW THESE READ THE ARTIFACT. The version this file shipped
# first parsed the DESIGN-UNITS machine block directly — an awk sentinel
# scan plus its own fence handling — documented at the time as "a
# DELIBERATE, NARROW exception to 'review-check.sh is the ONE DESIGN-UNITS
# parser'" because review-check.sh's validate-design exposed only
# unit_ids/unit_files/unit_deps (SETS, never per-unit CONTENT), so there was
# no envelope field this could read instead. That WAS a second parser, not
# an exception to needing one, and design-artifact.test.sh section 5
# (5.7b/5.7c) asserts the invariant structurally rather than leaving it to
# review: qa-gate.sh must carry ZERO DESIGN-UNITS sentinel extraction of its
# own; review-check.sh, the ONE parser, must.
#
# THE FIX: review-check.sh gained a new subcommand, design-unit-json,
# built on top of the SAME validate-design cmd_validate_design already
# ships — it calls validate-design first and refuses unless it answers
# ok:true with the requested unit declared, then returns that ONE unit's own
# canonical JSON (see that subcommand's header in review-check.sh for why
# this is a fetch behind the real validator's verdict, never a second one).
# design_unit_json below is now a thin wrapper over that subcommand;
# design_declared_unit_ids is a thin wrapper over the EXISTING, unmodified
# validate-design's own unit_ids field. Neither reads the artifact's machine
# block directly any more. design_unit_content_hash (further below) needed
# no changes at all: it already only ever consumed design_unit_json's
# output and hashed it via workflow-manifest.sh, so its external contract
# carried straight through this fix.
#
# UPDATE (v5 D5 R4-F1 remediation, independent review round 4):
# design-unit-json's OWN internals changed — it no longer re-reads the
# artifact after calling validate-design; it now projects the unit's body
# off validate-design's own unit_content envelope field instead (see
# review-check.sh for the mechanism and validate_design_envelope_ok, above,
# for the matching shape-check update). design_unit_json here did NOT
# change: its external contract (subcommand name, .ok/.error_key/.unit_json
# fields) is identical, so this wrapper, design_declared_unit_ids, and
# design_unit_content_hash all carry straight through UNCHANGED.
#
# design_unit_json <artifact-path> <unit-id> — canonical (compact, keys
# sorted, so incidental reformatting or key reordering elsewhere in the
# unit's own object never changes the hash a caller derives from this) JSON
# for ONE declared unit, or empty. Empty + rc 0 = the artifact validates and
# unit_id is simply not among its units (a DETERMINED absence — the same
# "empty + rc 0" convention every other reader in this file uses for
# "checked, and it is not there"). rc 3 = the artifact did not validate, or
# review-check.sh's own read of it failed, propagated as unreadable (never
# to be read as "not declared" — the same distinction the previous, local
# implementation of this function already drew).
design_unit_json() {
    local artifact="${1:-}" unit_id="${2:-}"
    [ -n "$artifact" ] && [ -f "$artifact" ] || return 3
    [ -n "$unit_id" ] || return 3
    local out="" out_rc=0
    out=$(bash "$REVIEW_CHECK_SCRIPT" design-unit-json "$artifact" "$unit_id" 2>/dev/null) || out_rc=$?
    local ok="false"
    if [ "$out_rc" -eq 0 ] && [ -n "$out" ]; then
        ok=$(printf '%s' "$out" | jq -r '(.ok == true) as $b | if $b then "true" else "false" end' 2>/dev/null) || ok="false"
    fi
    if [ "$ok" = "true" ]; then
        printf '%s' "$out" | jq -r '.unit_json // ""' 2>/dev/null
        return 0
    fi
    # A DETERMINED "not declared" verdict is read from the body regardless
    # of exit status, the same way validate_design_envelope_ok's own header
    # says a refusal envelope is read for its error_key/observations rather
    # than discarded just because the exit was nonzero.
    local ekey=""
    ekey=$(printf '%s' "$out" | jq -r '.error_key // ""' 2>/dev/null) || ekey=""
    if [ "$ekey" = "unit_not_in_design" ]; then
        printf ''
        return 0
    fi
    return 3
}

# design_declared_unit_ids <artifact-path> — comma-space-joined unit_ids, for
# an error message's "Declared unit(s): ..." text only (the SAME shape
# design-unit-bind's own UNIT-MEMBERSHIP-GATE already prints) — empty on any
# failure, since nothing gates on this, only a message reads it. Reads
# review-check.sh's EXISTING, unmodified validate-design envelope; no new
# surface was needed for this one, since unit_ids was already on it.
design_declared_unit_ids() {
    local artifact="${1:-}"
    [ -n "$artifact" ] && [ -f "$artifact" ] || return 0
    local out="" out_rc=0
    out=$(bash "$REVIEW_CHECK_SCRIPT" validate-design "$artifact" 2>/dev/null) || out_rc=$?
    [ "$out_rc" -eq 0 ] || return 0
    printf '%s' "$out" | jq -r '(.unit_ids // []) | join(", ")' 2>/dev/null || true
    return 0
}

# design_unit_content_hash <artifact-path> <unit-id> — sha256 (lowercase
# hex) of design_unit_json's canonical output for <unit-id>, via
# workflow-manifest.sh hash-file — the ONE hash-tool dispatch this file
# already trusts (sha256sum -> shasum -> openssl, whichever is on PATH),
# never a second one. A temp file is used ONLY because hash-file takes a
# PATH, never stdin; mktemp with the same QA_TRACKING_DIR fallback this file
# already uses at three other call sites, removed in every exit path. Rc 0
# + empty = unit not declared (design_unit_json's own determined absence,
# propagated); rc 3 = could not be determined at all (unit_json's own
# failure, a missing/unreadable hash tool, or a hash that did not come back
# 64 lowercase hex).
design_unit_content_hash() {
    local artifact="${1:-}" unit_id="${2:-}"
    local unit_json="" uj_rc=0
    unit_json=$(design_unit_json "$artifact" "$unit_id") || uj_rc=$?
    [ "$uj_rc" -eq 0 ] || return 3
    [ -n "$unit_json" ] || return 0

    local manifest_tool="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
    [ -f "$manifest_tool" ] || return 3
    local tmpf
    tmpf=$(mktemp -t design-unit-hash.XXXXXX 2>/dev/null) || tmpf="$QA_TRACKING_DIR/.design-unit-hash-$$.json"
    if ! printf '%s\n' "$unit_json" > "$tmpf" 2>/dev/null; then
        rm -f "$tmpf" 2>/dev/null
        return 3
    fi
    local h="" h_rc=0
    h=$(bash "$manifest_tool" hash-file "$tmpf" 2>/dev/null) || h_rc=$?
    rm -f "$tmpf" 2>/dev/null
    [ "$h_rc" -eq 0 ] && is_sha256_hex "$h" || return 3
    printf '%s' "$h"
    return 0
}

# resolve_design_conflict_subject <tid> — claude-workflow-plugin-268l. Both
# cmd_design_conflict (the writer) and compute_design_conflict_open (the
# reader) used to take <tid> itself as the task whose docs/specs/<id>.md and
# comment stream a design-conflict is filed against and read from. Under v5
# task-per-unit that is frequently wrong BY CONSTRUCTION: <tid> may be a unit
# task bound (via DESIGN-UNIT, see latest_design_unit_binding above — "the
# ONE authoritative reader", :3063) to a DIFFERENT task that actually owns
# the design. This resolves the correct subject ONCE, through that ONE
# reader, so the writer and the reader can never disagree about which task a
# given <tid> maps to (the class of bug design-unit-show's own header, :3065,
# warns a second copy of the DESIGN-UNIT grammar would risk).
#
# Sets globals (never prints):
#   DESIGN_CONFLICT_SUBJECT        the task-id design-conflict must read/
#                                  write against for <tid>
#   DESIGN_CONFLICT_SUBJECT_BOUND  "true" when resolution went through a
#                                  DESIGN-UNIT binding; "false" when it fell
#                                  back to <tid> itself (no binding exists).
#                                  Kept as an EXPLICIT, separate signal —
#                                  never inferred from DESIGN_CONFLICT_
#                                  SUBJECT == <tid>, which would be wrong the
#                                  rare time a task binds to ITSELF (nothing
#                                  refuses design_task == tid at bind time) —
#                                  so a caller, and a human reading the
#                                  observations text this drives, can always
#                                  tell bound apart from unbound.
#
# Returns 0 on a DETERMINED read: BOUND (subject = design_task from the
# binding) or DETERMINED-ABSENT (subject = <tid> itself — see "THE ANSWERED
# DESIGN QUESTION" below) both return 0. Returns 3 — and sets neither global
# to anything a caller should trust past that point — when latest_design_
# unit_binding's own source could not be read at all (its own rc 3): the
# SAME xsu1 discipline compute_design_satisfied's DESIGN-SOURCE-UNREADABLE
# guard established (:8500ff) applied to this predicate. Unreadable is never
# silently folded into "no binding, fall back to self" — that would risk
# misfiling or misreading a conflict against a task other than the one that
# actually governs <tid>, on evidence that was never actually read.
#
# THE ANSWERED DESIGN QUESTION (claude-workflow-plugin-268l task notes:
# "what is the correct behaviour when a unit task has NO DESIGN-UNIT
# binding?"). <tid> becomes its OWN subject — byte-identical to this
# command's pre-268l behaviour in every way an existing caller can observe.
# This is NOT a vacuous "nothing to check, report no conflict" default: it
# is a real, executed check of <tid>'s own docs/specs/<tid>.md and its own
# comment stream, which happens to honestly find nothing on a task that
# never had a design phase of its own (the common case today — most tasks
# are not v5 units at all), and which can just as honestly find a genuine,
# open DESIGN-CONFLICT on a task that owns its design DIRECTLY:
# worktree-approval-resolution.sh section 8b and design-gate-precheck-
# wiring.test.sh section 1b both file and detect a DESIGN-CONFLICT against a
# task with NO DESIGN-UNIT binding anywhere in its history, and both must
# keep passing unmodified. Collapsing "unbound" to "no governing design,
# nothing to check" would silently disable that entire, currently-exercised
# pathway — a strictly worse regression than the misdirection this fix
# closes. Bound and unbound are not a spectrum from "more v5" to "less v5";
# they are two ways a real design can be organised, and this predicate has
# to serve both because today's store contains both.
resolve_design_conflict_subject() {
    local tid="$1"
    DESIGN_CONFLICT_SUBJECT="$tid"
    DESIGN_CONFLICT_SUBJECT_BOUND="false"
    local binding_json="" binding_rc=0
    binding_json=$(latest_design_unit_binding "$tid") || binding_rc=$?
    [ "$binding_rc" -eq 0 ] || return 3
    local design_task=""
    design_task=$(printf '%s' "$binding_json" | jq -r '.design_task // ""' 2>/dev/null || echo "")
    if [ -n "$design_task" ]; then
        DESIGN_CONFLICT_SUBJECT="$design_task"
        DESIGN_CONFLICT_SUBJECT_BOUND="true"
    fi
    return 0
}

cmd_design_conflict() {
    # jq availability is checked FIRST and reported WITHOUT emit_error_json
    # — the same reason cmd_design_unit_bind and cmd_design_conform both do
    # this ahead of everything else: every emit_error_json/emit_json call
    # builds its JSON THROUGH jq, so discovering jq is missing and then
    # trying to report that fact via the same jq-dependent emitter produces
    # `jq: command not found` on stderr and unparseable JSON on stdout. This
    # literal interpolates no caller-supplied text, so there is nothing here
    # for a missing jq to have needed to escape.
    if ! command -v jq >/dev/null 2>&1; then
        printf '{"ok":false,"subcommand":"design-conflict","task_id":null,"status":"error","error_key":"jq_unavailable","observations":"jq is required and not on PATH; refusing rather than writing a record nothing downstream could read back","usage":"qa-gate.sh design-conflict <task-id> --unit <unit-id> [--design-hash <h>] <statement>"}\n'
        exit 2
    fi

    local tid="${1:-}"
    if [ -z "$tid" ]; then
        usage
        emit_error_json "design-conflict" "" "missing_task_id" \
            "design-conflict requires <task-id> as first positional argument" \
            "qa-gate.sh design-conflict <task-id> --unit <unit-id> [--design-hash <h>] '<statement>'"
        exit 1
    fi
    shift || true

    # Argument-parsing shape mirrors cmd_design_unit_bind's exactly (flags
    # plus a trailing free-text field), not design-review-record's (no
    # trailing summary there — its payload comes from --file/stdin, so ANY
    # bare word is an unknown_flag). Here a bare word is the statement.
    local unit_id="" design_hash_arg="" statement=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --unit)
                unit_id="${2:-}"
                if [ -z "$unit_id" ]; then
                    emit_error_json "design-conflict" "$tid" "missing_unit_id" \
                        "--unit requires a value — the unit_id whose acceptance criteria cannot be satisfied as designed" \
                        "qa-gate.sh design-conflict $tid --unit <U-n> [--design-hash <h>] '<statement>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            --design-hash)
                design_hash_arg="${2:-}"
                if [ -z "$design_hash_arg" ]; then
                    emit_error_json "design-conflict" "$tid" "missing_design_hash" \
                        "--design-hash requires a value when the flag is given; omit it entirely to auto-derive the current artifact's live hash instead" \
                        "qa-gate.sh design-conflict $tid --unit <U-n> [--design-hash <h>] '<statement>'"
                    exit 1
                fi
                shift 2 || true
                ;;
            -h|--help) usage; exit 1 ;;
            *)
                if [ -z "$statement" ]; then statement="$1"; else statement="$statement $1"; fi
                shift || true
                ;;
        esac
    done

    require_bd "design-conflict" "$tid"

    # Redundant-looking re-checks (unit_id was already checked non-empty
    # inline above when --unit WAS given) cover the case it was never
    # given at all — the same belt-and-suspenders shape design-unit-bind's
    # own header documents as deliberate rather than an oversight.
    if [ -z "$unit_id" ]; then
        emit_error_json "design-conflict" "$tid" "missing_unit_id" \
            "--unit is required — which unit's acceptance criteria cannot be satisfied as designed" \
            "qa-gate.sh design-conflict $tid --unit <U-n> [--design-hash <h>] '<statement>'"
        exit 1
    fi
    if [ -z "$statement" ]; then
        emit_error_json "design-conflict" "$tid" "missing_statement" \
            "a <statement> is required — the evidence for why the design cannot be satisfied as written. A conflict with no stated reason is indistinguishable from an implementer improvising instead of stopping, which is exactly what this record exists to prevent" \
            "qa-gate.sh design-conflict $tid --unit <U-n> [--design-hash <h>] '<statement>'"
        exit 1
    fi

# DESIGN-CONFLICT-SCALAR-CLASS BEGIN (fkm.7)
    # bjx: reject, never sanitise. See this block's own function-header
    # comment above for why unit_id and design_hash carry DIFFERENT classes
    # from each other (and why design_hash's is looser than is_sha256_hex).
    assert_unit_id_scalar "design-conflict" "$tid" "unit_id" "$unit_id"
    if [ -n "$design_hash_arg" ]; then
        case "$design_hash_arg" in
            *[!A-Za-z0-9-]*)
                emit_error_json "design-conflict" "$tid" "design_hash_invalid_chars" \
                    "design_hash='$design_hash_arg' contains characters outside [A-Za-z0-9-]; it is interpolated into the DESIGN-CONFLICT record's machine prefix, where a space, a colon or a bracket would move a field boundary and let the record be read back as something the caller never said (the claude-workflow-plugin-bjx class). Rejected, not sanitised" \
                    "qa-gate.sh design-conflict $tid --unit $unit_id --design-hash <h> '<statement>'"
                exit 1
                ;;
        esac
    fi
# DESIGN-CONFLICT-SCALAR-CLASS END (fkm.7)

    # --- claude-workflow-plugin-268l: resolve the SUBJECT before touching
    # any artifact. <tid> may be a v5 unit task bound (via DESIGN-UNIT) to a
    # DIFFERENT task that owns docs/specs/<id>.md — see resolve_design_
    # conflict_subject's own header for the full rationale and the answered
    # design question (bound / unbound / unreadable). The region below
    # contains ONLY the resolution call and its fail-closed exit; $subject
    # is initialised to $tid immediately above it, so stripping the region
    # reproduces the EXACT pre-268l behaviour (always operate on <tid>
    # directly) rather than crashing on an unset variable — see design-
    # conflict-subject-resolution.test.sh's META for the mutant this shape
    # is built to support.
    local subject="$tid" subject_bound="false"
# DESIGN-CONFLICT-WRITER-SUBJECT-RESOLUTION BEGIN (268l)
    local subject_rc=0
    resolve_design_conflict_subject "$tid" || subject_rc=$?
    if [ "$subject_rc" -ne 0 ]; then
        emit_error_json "design-conflict" "$tid" "design_binding_unreadable" \
            "the DESIGN-UNIT binding source for $tid could not be read right now (both bd show forms failed, the comment stream was not retrievable, or a record read back malformed); whether $tid is bound to a governing design task is unknown, so there is no way to know which task's docs/specs/<id>.md this conflict would even be filed against. Refusing rather than guessing — falling back to $tid itself here could silently misfile a conflict that belongs on a different, unreadable-to-check design task. Re-run once bd is reachable" \
            "qa-gate.sh design-conflict $tid --unit <U-n> [--design-hash <h>] '<statement>'"
        exit 2
    fi
    subject="$DESIGN_CONFLICT_SUBJECT"
    subject_bound="$DESIGN_CONFLICT_SUBJECT_BOUND"
# DESIGN-CONFLICT-WRITER-SUBJECT-RESOLUTION END (268l)

    # --- R2-F3: confirm --unit is a REAL, declared unit; resolve the LIVE
    # whole-artifact hash unconditionally; an explicit --design-hash must
    # equal it (a CONFIRMATION, never a second source); pin unit_hash to
    # the DISPUTED unit's OWN current content, over which clearing is now
    # decided (see compute_design_conflict_open's own header) ------------
    # claude-workflow-plugin-268l: every "$tid" below this point that means
    # "the task whose docs/specs/<id>.md governs this conflict" is now
    # "$subject" instead — $subject equals $tid unless a DESIGN-UNIT
    # binding resolved it to something else. $tid remains the envelope's
    # own task_id field throughout (matching design-conform's own
    # precedent): this command was invoked ON $tid, even when it acts on
    # $subject's artifact.
    local artifact
    artifact=$(design_artifact_path_for "$subject")
    if [ ! -f "$artifact" ]; then
        if [ "$subject_bound" = "true" ]; then
            emit_error_json "design-conflict" "$tid" "design_artifact_not_found" \
                "$tid is bound (via DESIGN-UNIT) to design_task=$subject, but no design artifact exists at $artifact; a conflict needs a design to be filed against (required even with an explicit --design-hash, so the value can be CONFIRMED rather than merely trusted). Record the design first: qa-gate.sh design-record $subject" \
                "qa-gate.sh design-conflict $tid --unit $unit_id --design-hash <h> '<statement>'"
            exit 1
        fi
        emit_error_json "design-conflict" "$tid" "design_artifact_not_found" \
            "no design artifact exists at $artifact, and $tid carries no DESIGN-UNIT binding either; a conflict needs a design to be filed against. If $tid implements a unit of ANOTHER task's design, bind it first: qa-gate.sh design-unit-bind $tid --design-task <design-tid> --unit-id <U-n>. Otherwise record a design directly on $tid: qa-gate.sh design-record $tid" \
            "qa-gate.sh design-conflict $tid --unit $unit_id --design-hash <h> '<statement>'"
        exit 1
    fi
    local manifest_tool
    manifest_tool="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
    if [ ! -f "$manifest_tool" ]; then
        emit_error_json "design-conflict" "$tid" "hash_tool_unavailable" \
            "cannot derive the current design_hash: workflow-manifest.sh is missing at $manifest_tool" \
            "qa-gate.sh design-conflict $tid --unit $unit_id --design-hash <h> '<statement>'"
        exit 2
    fi
    local live_hash="" hash_rc=0
    live_hash=$(bash "$manifest_tool" hash-file "$artifact" 2>/dev/null) || hash_rc=$?
    # STRICT is_sha256_hex here (not the looser write class the CLI flag
    # accepts): this is OUR OWN live computation, and hash-file can
    # legitimately emit a non-empty degradation sentinel on failure
    # (is_sha256_hex's own header: "refuses sha256-unavailable, any
    # truncation of it") that the looser [A-Za-z0-9-]+ class would let
    # through as if it were a real hash.
    if [ "$hash_rc" -ne 0 ] || ! is_sha256_hex "$live_hash"; then
        emit_error_json "design-conflict" "$tid" "design_hash_unavailable" \
            "$artifact could not be hashed into 64 hex characters (workflow-manifest.sh hash-file exited $hash_rc, produced '${live_hash:-<empty>}')" \
            "qa-gate.sh design-conflict $tid --unit $unit_id --design-hash <h> '<statement>'"
        exit 2
    fi

    local design_hash
    if [ -n "$design_hash_arg" ]; then
        # R2-F3 (independent review round 2): an explicit --design-hash is now a
        # CONFIRMATION of the CURRENT artifact hash, never an independent
        # claim the writer merely trusts — trusting it is exactly how a
        # stale or mistyped value used to be recorded verbatim and then read
        # back by compute_design_conflict_open as ALREADY not the current
        # design (its own CLEARED arm), a conflict born cleared. Reject,
        # don't sanitise: the same discipline every other caller-supplied
        # value in this file gets.
        if [ "$design_hash_arg" != "$live_hash" ]; then
            emit_error_json "design-conflict" "$tid" "design_hash_not_current" \
                "--design-hash='$design_hash_arg' does not match $artifact's CURRENT hash ($live_hash); a conflict must be filed against the artifact as it exists right now, never a stale or mistyped value. Omit --design-hash to auto-derive the current one, or pass exactly what 'workflow-manifest.sh hash-file $artifact' prints" \
                "qa-gate.sh design-conflict $tid --unit $unit_id --design-hash <h> '<statement>'"
            exit 1
        fi
        design_hash="$design_hash_arg"
    else
        design_hash="$live_hash"
    fi

# UNIT-MEMBERSHIP-GATE BEGIN (fkm.7 R2-F3 fix / independent review round 2)
    # A conflict pinned to a unit_id nothing declares could never be
    # cleared or read back meaningfully (there is no content for a future
    # amendment to ever change) — the SAME reasoning, and the SAME error
    # key, design-unit-bind's own UNIT-MEMBERSHIP-GATE already applies to
    # the identical fact.
    local unit_json="" uj_rc=0
    unit_json=$(design_unit_json "$artifact" "$unit_id") || uj_rc=$?
    if [ "$uj_rc" -ne 0 ]; then
        emit_error_json "design-conflict" "$tid" "design_units_block_unreadable" \
            "$artifact did not validate via review-check.sh validate-design right now (missing sentinels, unparseable JSON, an unanchored/malformed fence, a schema violation, or a cyclic dependency graph — see that command's own error_key for which); a conflict cannot be pinned to a unit whose current content is unknown" \
            "qa-gate.sh design-conflict $tid --unit $unit_id --design-hash <h> '<statement>'"
        exit 2
    fi
    if [ -z "$unit_json" ]; then
        local known
        known=$(design_declared_unit_ids "$artifact")
        emit_error_json "design-conflict" "$tid" "unit_not_in_artifact" \
            "unit_id='$unit_id' is not declared in $artifact (design_hash=$live_hash). Declared unit(s): ${known:-<none>}. A conflict pinned to a nonexistent unit is worse than none — refusing" \
            "qa-gate.sh design-conflict $tid --unit <one of: ${known:-<none>}> --design-hash <h> '<statement>'"
        exit 1
    fi
    local unit_hash="" uh_rc=0
    unit_hash=$(design_unit_content_hash "$artifact" "$unit_id") || uh_rc=$?
    if [ "$uh_rc" -ne 0 ] || [ -z "$unit_hash" ] || ! is_sha256_hex "$unit_hash"; then
        emit_error_json "design-conflict" "$tid" "unit_hash_unavailable" \
            "unit_id='$unit_id' is declared in $artifact but its own content could not be hashed into 64 hex characters right now — nothing is recorded" \
            "qa-gate.sh design-conflict $tid --unit $unit_id --design-hash <h> '<statement>'"
        exit 2
    fi
# UNIT-MEMBERSHIP-GATE END (fkm.7 R2-F3 fix / independent review round 2)

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="DESIGN-CONFLICT $unit_id design_hash=$design_hash unit_hash=$unit_hash at $ts: $statement"
    # claude-workflow-plugin-268l: posted on $subject, never $tid directly.
    # compute_design_conflict_open resolves the SAME binding to the SAME
    # subject, so a record filed here is where that reader will actually
    # look — this is the producer half of the fix, not merely a rename:
    # posting on $tid instead (the pre-268l behaviour, when $tid even owned
    # an artifact at all) is exactly the misdirection this task exists to
    # close.
    add_comment "$subject" "$comment_text"

    # claude-workflow-plugin-268l R1-F1 (QA round 1, HIGH): add_comment ends
    # in `|| log_sync_error ...`, and log_sync_error ends in `printf ... ||
    # true`, so add_comment ALWAYS returns 0 — a transient store failure, a
    # wedged daemon, or a deleted task all leave this function reporting
    # "recorded" for a write that never happened, and design-gate-precheck /
    # approve then read the resulting silence as no-conflict: the ONE
    # comment-only record in this file whose ABSENCE is the PERMISSIVE
    # state, so a lost write here is a false PASS, not a confusing refusal
    # (claude-workflow-plugin-nod4's own P1-not-P0 bounding argument is
    # exactly inverted for this record type and does not transfer). Same
    # WRITE-CONFIRMATION-GATE doctrine cmd_design_unit_bind already applies
    # 80 lines away (:9562-9569): re-read the exact thing that was just
    # written and refuse rather than trust add_comment's exit status, which
    # proves nothing. The confirmation read failing OUTRIGHT (bd unreachable,
    # stream unretrievable) is a DIFFERENT fact from a confirmation read that
    # SUCCEEDS but does not show the record — same distinction xsu1 draws
    # everywhere else in this file — so it is refused with its own key
    # BEFORE the sentinel-wrapped guard below, matching design-unit-bind's
    # own confirm_rc-then-mismatch ordering exactly.
    local confirm_comments="" confirm_rc=0
    confirm_comments=$(design_comments_json "$subject") || confirm_rc=$?
    if [ "$confirm_rc" -ne 0 ]; then
        emit_error_json "design-conflict" "$tid" "design_conflict_confirm_unreadable" \
            "the write was submitted but the confirmation re-read of $subject's own comment stream failed right now (bd unreachable, the stream not retrievable, or unparseable) — whether the conflict record landed is unknown, and no claim is made about it either way. Once bd is reachable, verify with: qa-gate.sh design-gate-precheck $tid; re-run if absent: qa-gate.sh design-conflict $tid --unit $unit_id --design-hash $design_hash '$statement'" \
            "qa-gate.sh design-gate-precheck $tid"
        exit 5
    fi
    # Raw exact-text presence, not a second copy of compute_design_conflict_
    # open's anchored capture: confirmation only needs to prove the BYTES we
    # asked to be written landed verbatim, which is a strictly stronger and
    # simpler check than re-parsing the grammar a second time (and comment_
    # text is unique per call — it embeds the to-the-second timestamp and
    # the free-text statement — so an exact match cannot mean "some OTHER
    # conflict record happens to be present").
    local confirm_present="false"
    confirm_present=$(printf '%s' "$confirm_comments" | jq -r --arg t "$comment_text" '([.[].text] | any(. == $t)) | tostring' 2>/dev/null || echo "false")
# WRITE-CONFIRMATION-GATE BEGIN (268l, R1-F1)
    if [ "$confirm_present" != "true" ]; then
        emit_error_json "design-conflict" "$tid" "design_conflict_write_unconfirmed" \
            "the write appeared to complete but a fresh read of $subject's own comments does not show this DESIGN-CONFLICT record (unit_id=$unit_id design_hash=$design_hash unit_hash=$unit_hash) as present. add_comment() cannot distinguish a transient store failure from success (claude-workflow-plugin-nod4), so this is refused rather than reported recorded on unconfirmed evidence. Re-run: qa-gate.sh design-conflict $tid --unit $unit_id --design-hash $design_hash '$statement'; if this persists, check bd connectivity and $SYNC_ERRORS_LOG" \
            "qa-gate.sh design-conflict $tid --unit $unit_id --design-hash $design_hash '$statement'"
        exit 5
    fi
# WRITE-CONFIRMATION-GATE END (268l, R1-F1)

    local posted_obs="comment posted at $ts on $subject: $comment_text"
    [ "$subject" != "$tid" ] && posted_obs="comment posted at $ts on $subject (resolved from $tid's DESIGN-UNIT binding): $comment_text"

    # claude-workflow-plugin-268l R1-F4 (QA round 1, LOW, envelope-only):
    # design_task now a first-class field, matching the precedent this
    # change's own header already cites (emit_design_conform, design-unit-
    # show both expose it structurally) — previously named only inside the
    # free-text observations string. unit_id rides along for the same
    # reason design-unit-show's own envelope carries both together. This is
    # NOT a DESIGN-CONFLICT record-grammar change (the persisted bd comment
    # is untouched, still `DESIGN-CONFLICT <unit-id> design_hash=<h>
    # unit_hash=<h> at <ts>: <statement>`) — purely the transient CLI
    # envelope nothing else in this file machine-reads. `envelope=$(jq -nc
    # ...) || rc=$?` per print_envelope_checked's own xsu1 H2-F4 discipline:
    # inlining a failed jq substitution straight into printf's arguments
    # would print malformed JSON at ok:true (that helper's own measured
    # `printf '{"x":%s}\n' "$(false)"` -> `{"x":}` rc 0). jq availability was
    # already confirmed at this function's own first line, so a failure here
    # is a runtime fault building THIS object, not a missing binary; the
    # write is already CONFIRMED present above, so degrading to the
    # original, unstructured envelope on that fault can never turn into a
    # false "recorded" claim — only a less-structured true one, not worth a
    # dedicated error path for a LOW-severity structural nicety.
    local success_envelope="" success_rc=0
    success_envelope=$(jq -nc \
        --arg tid "$tid" --arg obs "$posted_obs" --arg dt "$subject" --arg u "$unit_id" \
        '{ok:true, subcommand:"design-conflict", task_id:$tid, status:"recorded", observations:$obs, design_task:$dt, unit_id:$u}' \
        2>/dev/null) || success_rc=$?
    if [ "$success_rc" -eq 0 ] && [ -n "$success_envelope" ]; then
        printf '%s\n' "$success_envelope"
    else
        emit_json 1 "design-conflict" "$tid" "recorded" "$posted_obs"
    fi
}

# compute_design_conflict_open <tid> — sets globals (never prints):
# DESIGN_CONFLICT_OPEN (true|false), DESIGN_CONFLICT_OPEN_UNITS
# (space-joined unit_ids carrying at least one open conflict), DESIGN_CONFLICT_
# OPEN_OBS (a full sentence). Returns 0 on a DETERMINED read — including "no
# DESIGN-CONFLICT record was ever filed", which is a determined answer, the
# SAME distinction design_comments_json's own header draws for absence versus
# unreadability — and non-zero when the comment stream could not be read or a
# jq failure means the answer is unknown. The caller MUST NOT treat a non-zero
# return as "no conflict"; see cmd_approve's own DESIGN-CONFLICT-REFUSAL for
# how it fails closed on this.
#
# UPDATE (claude-workflow-plugin-268l): THE SUBJECT WAS WRONG. This used to
# read <tid>'s OWN comment stream unconditionally, which under v5
# task-per-unit is frequently a task with no docs/specs/<id>.md and no
# DESIGN-CONFLICT records of its own — a comment stream that structurally
# cannot hold the record it was asked about, not evidence of no conflict.
# Every read below now runs against $subject (resolve_design_conflict_
# subject's output for <tid>: the design_task from <tid>'s DESIGN-UNIT
# binding when one exists, else <tid> itself, unchanged from before this
# fix), including the internal compute_design_satisfied re-check the R6-F4
# clearing predicate needs — checking $subject's records while asking
# compute_design_satisfied about <tid> would be a NEW self-inconsistent
# predicate this fix does not introduce. See resolve_design_conflict_
# subject's own header for the answered no-binding design question.
#
# SINGLE ARGUMENT since claude-workflow-plugin-i8cx (operator ruling on
# rounds 6/7/8 independent review). A historical second positional argument,
# <verdict-design-hash>, was accepted-but-ignored between independent review
# round 3 and this fix — every remaining call site has been updated to stop
# passing it, and it is no longer part of this function's contract.
#
# EVERY RECORD, NOT JUST THE LATEST (claude-workflow-plugin-fkm.1.19, applied
# rather than merely cited). fkm.1.19 is an OPEN P0 against review-check.sh's
# own gate: it reads only the LATEST review artifact, so a later artifact
# simply silent about an earlier open finding retires it BY OMISSION. A
# DESIGN-CONFLICT record has no "supersedes" marker of its own, so "read the
# latest one and call it the answer" would reproduce the identical defect one
# record-grammar over — a second conflict filed on a DIFFERENT unit after the
# first was addressed would silently un-list the first the moment it became
# merely "not the latest" comment. Nothing here takes `last`: every
# DESIGN-CONFLICT record ever filed on <tid> is collected into an array and
# evaluated INDEPENDENTLY, below.
#
# THE PER-RECORD PREDICATE KEYS ON THE DISPUTED UNIT, NOT THE WHOLE ARTIFACT
# (R2-F3, independent review round 2 — this replaces the whole-artifact-hash
# predicate this function originally shipped with), AND REQUIRES A CURRENT
# SATISFIED REVIEW, NOT A CONTENT CHANGE ALONE (R6-F4, independent review
# round 6 — see "THE RESIDUAL THIS CLOSES" below). For each filed conflict
# record (unit_id, pinned unit_hash):
#   design_unit_content_hash(<current artifact>, unit_id) == pinned unit_hash
#       -> OPEN, regardless of review state. Nothing about THIS unit's own
#          declared content (its goal, acceptance, files, interfaces,
#          depends_on, risks — the FULL per-unit object, canonicalised) has
#          changed since the conflict was filed against it — including an
#          amendment that changed a DIFFERENT unit, or a re-review of the
#          SAME unchanged artifact (iteration advances, no unit's content
#          moves). Both are exactly the retirement-by-omission shape this
#          reader exists to refuse, one level more precise than the
#          whole-artifact version was. This is the fkm.1.19 anti-regression
#          case this record type's own paired test targets.
#   design_unit_content_hash(...) != pinned unit_hash
#     AND compute_design_satisfied reports DESIGN_SATISFIED=true for <tid>'s
#     CURRENT artifact bytes (established ONCE per call in the function body,
#     not once per record — it is a fact about the current artifact as a
#     whole, never about any one conflict)
#       -> CLEARED. THIS unit's own content demonstrably changed, AND a
#          superseding, independently-reviewed, SATISFIED DESIGN-REVIEW
#          currently covers the bytes that change produced — together this
#          is the v5 plan's own clearing predicate, verbatim: "a superseding
#          approved DESIGN-REVIEW whose unit entry changed".
#   design_unit_content_hash(...) != pinned unit_hash, BUT
#     compute_design_satisfied does NOT report true (verdict missing, stale,
#     needs_revision, or the source unreadable)
#       -> OPEN. An edit happened, but nothing independently reviewed and
#          approved the result yet — the exact case R6-F4 found this
#          predicate getting wrong before this fix: it cleared on the
#          content-hash difference alone, with no review requirement at all.
#   design_unit_content_hash(...) could not be established at all (the unit
#   is no longer declared, or the current DESIGN-UNITS block could not be
#   read) -> OPEN, fail-closed. Absence of positive evidence that THIS
#          unit's own content changed is not evidence that it did; a unit
#          vanishing from the artifact is exactly the fact design-unit-
#          bind's own rebind requirement already treats as needing an
#          audited operator action elsewhere in this file, not a silent
#          pass in either direction here.
#
# THE RESIDUAL THIS CLOSES, named rather than silently declared fixed.
# R2-F3's own evidence was "editing and approving unrelated unit U2 changes
# the whole-artifact hash and silently clears U1" — a per-unit content hash
# cannot be moved by an edit to a DIFFERENT unit's object, so that specific
# reproduction is closed (design-review-record.test.sh section 8f pins it).
# R6-F4 (independent review round 6, claude-workflow-plugin-i8cx) found the
# NEXT residual, one level deeper: the R2-F3 predicate by itself clears on
# ANY content change to the disputed unit, with no check that a satisfied
# review ever covered the result — "the per-unit inequality proves an edit,
# not the required superseding approved DESIGN-REVIEW" (independent review's
# own words). Concretely: file a conflict against U1, edit U1, record NO new
# design review at all (or one that is stale or needs_revision) — the
# R2-F3-only predicate cleared it anyway, because DESIGN_SATISFIED=true was
# established by the CALLER before calling in, and one caller (cmd_approve's
# former --no-design branch, since removed) could reach this function
# without ever establishing it. Closed by making the satisfied-review
# requirement a property of THIS FUNCTION, established fresh inside it
# (below) rather than trusted from whichever caller happens to invoke it —
# deliberately, because the bug was ALWAYS a caller-ordering mistake: every
# prior fix to this axis (R2-F3, R3-F1, R3-F2a/b) was locally reasonable on
# its own terms and still left a way to reach this predicate with the
# precondition unestablished. Moving the requirement here forecloses that
# class for callers not yet written, not only the ones already reviewed.
# What remains OUT of scope, stated rather than assumed solved: this still
# trusts that an INDEPENDENT reviewer actually read the unit whose content
# changed (compute_design_satisfied proves the WHOLE artifact was reviewed
# and satisfied, not that the reviewer's attention fell on this particular
# unit) — the same trust every OTHER whole-document review in this file
# already extends to its own reviewer, and not a new gap this fix
# introduces.
#
# ANCHOR AND CLASSES MATCH THE WRITER, and the reader shape mirrors
# latest_design_review's ONE-anchored-capture discipline exactly:
# startswith("DESIGN-CONFLICT ") (trailing space, so a hypothetical future
# "DESIGN-CONFLICT-RESOLVED ..." record type could never false-match) plus
# a SINGLE capture(...) per candidate carrying THREE named groups (unit_id,
# design_hash, unit_hash — R2-F3 adds the third), so no caller can read one
# field from a different match than another. Verified directly against jq
# 1.8.1 (not assumed) that a comment which starts with the literal prefix
# but fails the full anchored pattern contributes ZERO elements to the
# resulting array — capture() is a generator that emits nothing on a
# non-match, it does not error and does not emit null — so a malformed
# record (including any record filed under the PRE-R2-F3 two-field grammar,
# which carries no unit_hash= token at all) is silently excluded rather
# than aborting the whole read. THAT EXCLUSION IS A DELIBERATE GRAMMAR
# BUMP, named rather than hidden: this feature shipped hours earlier in the
# SAME session (fkm.7) and a live-store search across the tasks this change
# touches came back empty of any DESIGN-CONFLICT record — accepted as a
# clean cut rather than carrying a dual-grammar reader for a record type
# with no production history yet.
compute_design_conflict_open() {
    # Single argument (claude-workflow-plugin-i8cx) — see this function's
    # own header for the history of the historical, now-removed second
    # positional argument.
    local tid="$1"
    DESIGN_CONFLICT_OPEN="false"
    DESIGN_CONFLICT_OPEN_UNITS=""
    DESIGN_CONFLICT_OPEN_OBS="no open design_conflict record on $tid"

    # claude-workflow-plugin-268l: resolve the SUBJECT before reading any
    # comment stream — see resolve_design_conflict_subject's own header. The
    # region below contains ONLY the resolution call and its fail-closed
    # return; $subject/$subject_bound are initialised immediately above it,
    # so stripping the region reproduces the EXACT pre-268l behaviour
    # (always read <tid>'s own stream) rather than crashing on an unset
    # variable. The returned rc==3 case (binding source unreadable) is
    # propagated exactly like the pre-fix "comment stream on <tid>
    # unreadable" case already was: both mean "cannot determine anything
    # about this task's design-conflict status right now", so this is not a
    # NEW failure surface, only a more precisely named one.
    local subject="$tid" subject_bound="false"
# DESIGN-CONFLICT-READER-SUBJECT-RESOLUTION BEGIN (268l)
    local subject_rc=0
    resolve_design_conflict_subject "$tid" || subject_rc=$?
    [ "$subject_rc" -eq 0 ] || return 3
    subject="$DESIGN_CONFLICT_SUBJECT"
    subject_bound="$DESIGN_CONFLICT_SUBJECT_BOUND"
# DESIGN-CONFLICT-READER-SUBJECT-RESOLUTION END (268l)
    if [ "$subject_bound" = "true" ]; then
        DESIGN_CONFLICT_OPEN_OBS="no open design_conflict record on $subject (resolved from $tid's DESIGN-UNIT binding)"
    fi

    local comments="" c_rc=0
    comments=$(design_comments_json "$subject") || c_rc=$?
    [ "$c_rc" -eq 0 ] || return 3

    local out="" out_rc=0
    out=$(printf '%s' "$comments" \
        | jq -c '
            # every-DESIGN-CONFLICT selector (v5 D5, fkm.7; R2-F3 adds
            # unit_hash) — an ARRAY, not `last`: the fkm.1.19 discipline is
            # every record considered, none retired by a later record
            # simply being silent about it.
            [ .[].text
              | select(startswith("DESIGN-CONFLICT "))
              | capture("^DESIGN-CONFLICT (?<unit_id>[A-Za-z0-9._-]+) design_hash=(?<design_hash>[A-Za-z0-9-]+) unit_hash=(?<unit_hash>[A-Za-z0-9-]+) ")
            ]
        ' 2>/dev/null) || out_rc=$?
    if [ "$out_rc" -ne 0 ] || [ -z "$out" ]; then
        # jq -c on a genuinely empty selection prints "[]" (2 bytes, not
        # empty) — the SAME distinction latest_design_review's own `last //
        # {}` draws — so [-z "$out"] only trips on an actual jq/read failure.
        return 3
    fi
    # Defense-in-depth, not a shape this file expects to ever actually see:
    # capture()'s own named groups already guarantee this for anything that
    # reaches the array (see the header above, verified against jq 1.8.1
    # directly). Guards only against a jq malfunction mid-run.
    printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 3

    local n_records=0
    n_records=$(printf '%s' "$out" | jq 'length' 2>/dev/null) || return 3
    case "$n_records" in ''|*[!0-9]*) return 3 ;; esac
    if [ "$n_records" -eq 0 ]; then
        return 0
    fi

    # R6-F4 (independent review round 6, claude-workflow-plugin-i8cx):
    # established ONCE per call, never per record — it is a fact about the
    # CURRENT artifact as a whole ("does a superseding, independently-
    # reviewed, satisfied DESIGN-REVIEW currently cover it"), not about any
    # one conflict. Deliberately established HERE, inside this function,
    # rather than trusted from the caller: see this function's own header
    # ("THE RESIDUAL THIS CLOSES") for why every prior fix that instead
    # relied on caller ordering left a way in. A record can now NEVER clear
    # while $satisfied_now != "true", regardless of what any caller did or
    # did not establish before calling in — this can only make the answer
    # MORE conservative (more records stay OPEN), never less, so it needs no
    # refusal of its own the way an unreadable DESIGN-CONFLICT stream does
    # above.
    #
    # claude-workflow-plugin-268l: checked against $subject, not $tid — the
    # SAME resolved task the DESIGN-CONFLICT records above were just read
    # from. Checking $tid's own satisfaction here while reading $subject's
    # records above would be a self-inconsistent predicate: whether a
    # record clears depends on whether the design that GOVERNS the disputed
    # unit was re-reviewed and found satisfied, not on whatever compute_
    # design_satisfied says about a task that (under v5 task-per-unit) most
    # likely never had a design artifact of its own at all.
    compute_design_satisfied "$subject"
    local satisfied_now="$DESIGN_SATISFIED"

    # R2-F3: the clearing predicate keys on the DISPUTED UNIT's own current
    # content, not the whole artifact — see this function's own header for
    # the exact per-record predicate. Resolve the current artifact path
    # ONCE; each record's own unit_id gets its current content hash
    # re-derived (design_unit_content_hash), never assumed unchanged.
    local artifact
    artifact=$(design_artifact_path_for "$subject")

    local rows="" row_rc=0
    rows=$(printf '%s' "$out" | jq -r '.[] | [.unit_id, .unit_hash] | @tsv' 2>/dev/null) || row_rc=$?
    [ "$row_rc" -eq 0 ] || return 3

    local open_units="" seen=" " row_uid row_hash current_hash ch_rc
    while IFS=$'\t' read -r row_uid row_hash; do
        [ -n "$row_uid" ] || continue
        current_hash="" ch_rc=0
        current_hash=$(design_unit_content_hash "$artifact" "$row_uid") || ch_rc=$?
        # Fail CLOSED on ambiguity: an unreadable source (ch_rc != 0), a
        # unit no longer declared (rc 0, empty), a hash that still matches
        # the pinned one, OR no current satisfied review covering the
        # artifact (satisfied_now != "true" — R6-F4) all count as OPEN.
        # Only a POSITIVELY established, DIFFERENT current hash for THIS
        # unit, UNDER A CURRENT SATISFIED DESIGN-REVIEW, clears it.
        if [ "$ch_rc" -ne 0 ] || [ -z "$current_hash" ] || [ "$current_hash" = "$row_hash" ] || [ "$satisfied_now" != "true" ]; then
            case "$seen" in
                *" $row_uid "*) ;;
                *) open_units="${open_units:+$open_units }$row_uid"; seen="$seen$row_uid " ;;
            esac
        fi
    done <<EOF
$rows
EOF

    if [ -n "$open_units" ]; then
        DESIGN_CONFLICT_OPEN="true"
        DESIGN_CONFLICT_OPEN_UNITS="$open_units"
        local subject_note=""
        [ "$subject_bound" = "true" ] && subject_note=" (resolved from $tid's DESIGN-UNIT binding)"
        DESIGN_CONFLICT_OPEN_OBS="open design_conflict record(s) exist on $subject$subject_note — for each affected unit, either ITS OWN current content in the design artifact still matches (or could not be independently re-derived from) what the conflict was filed against, or no current satisfied DESIGN-REVIEW covers the artifact at all; only a change to the DISPUTED UNIT's OWN content, under a superseding satisfied review, clears it (affected unit(s) are in DESIGN_CONFLICT_OPEN_UNITS, the caller's own field for that — not repeated here so the two never drift apart in wording)"
    fi
    return 0
}
# DESIGN-CONFLICT END (v5 D5 / claude-workflow-plugin-fkm.7)

# resolve-finding <tid> <finding-id> --fix '<ref>' --test '<ref>' '<summary>'
cmd_resolve_finding() {
    local tid="${1:-}" fid="${2:-}"
    if [ -z "$tid" ] || [ -z "$fid" ]; then
        usage
        emit_error_json "resolve-finding" "$tid" "missing_args" \
            "resolve-finding requires <task-id> <finding-id> --fix <ref> --test <ref> <summary>" \
            "qa-gate.sh resolve-finding <tid> <finding-id> --fix '<ref>' --test '<ref>' '<summary>'"
        exit 1
    fi
    shift 2 || true
    local fix="" testref="" summary=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --fix)  fix="${2:-}"; shift 2 || true ;;
            --test) testref="${2:-}"; shift 2 || true ;;
            -h|--help) usage; exit 1 ;;
            *) summary="$1"; shift || true ;;
        esac
    done

    require_bd "resolve-finding" "$tid"

    if [ -z "$fix" ]; then
        emit_error_json "resolve-finding" "$tid" "empty_fix" \
            "--fix reference is empty; a resolution must cite the fix" \
            "qa-gate.sh resolve-finding $tid $fid --fix '<commit/path:line>' --test '<ref>' '<summary>'"
        exit 1
    fi
    if [ -z "$testref" ]; then
        emit_error_json "resolve-finding" "$tid" "empty_test" \
            "--test reference is empty; a resolution must cite the covering test" \
            "qa-gate.sh resolve-finding $tid $fid --fix '<ref>' --test '<test path/name>' '<summary>'"
        exit 1
    fi
    if ! finding_id_in_latest_artifact "$tid" "$fid"; then
        emit_error_json "resolve-finding" "$tid" "finding_id_not_found" \
            "finding id '$fid' is not present in the latest REVIEW-ARTIFACT comment for $tid" \
            "resolve only ids that appear in the latest review artifact's findings=[...] token"
        exit 1
    fi

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="RESOLVED $fid at $ts: fix=$fix test=$testref — $summary"
    add_comment "$tid" "$comment_text"
    emit_json 1 "resolve-finding" "$tid" "resolved" "comment posted at $ts: $comment_text"
}

# arbitrate <tid> <finding-id> <overrule|sustain> '<rationale>'
cmd_arbitrate() {
    local tid="${1:-}" fid="${2:-}" decision="${3:-}" rationale="${4:-}"
    if [ -z "$tid" ] || [ -z "$fid" ] || [ -z "$decision" ]; then
        usage
        emit_error_json "arbitrate" "$tid" "missing_args" \
            "arbitrate requires <task-id> <finding-id> <overrule|sustain> <rationale>" \
            "qa-gate.sh arbitrate <tid> <finding-id> <overrule|sustain> '<rationale>'"
        exit 1
    fi
    case "$decision" in
        overrule|sustain) ;;
        *)
            emit_error_json "arbitrate" "$tid" "decision_invalid_enum" \
                "decision '$decision' is not in {overrule, sustain}" \
                "qa-gate.sh arbitrate $tid $fid <overrule|sustain> '<rationale>'"
            exit 1
            ;;
    esac

    require_bd "arbitrate" "$tid"

    if [ -z "$rationale" ]; then
        emit_error_json "arbitrate" "$tid" "empty_rationale" \
            "arbitration rationale is empty; an arbitration decision must be justified" \
            "qa-gate.sh arbitrate $tid $fid $decision '<rationale>'"
        exit 1
    fi
    if ! finding_id_in_latest_artifact "$tid" "$fid"; then
        emit_error_json "arbitrate" "$tid" "finding_id_not_found" \
            "finding id '$fid' is not present in the latest REVIEW-ARTIFACT comment for $tid" \
            "arbitrate only ids that appear in the latest review artifact's findings=[...] token"
        exit 1
    fi

    local ts comment_text
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment_text="ARBITRATION $fid decision=$decision at $ts: $rationale"
    add_comment "$tid" "$comment_text"
    emit_json 1 "arbitrate" "$tid" "arbitrated" "comment posted at $ts: $comment_text"
}

# cmd_quarantine_artifact -- REMOVED (claude-workflow-plugin-k6re, R2-F1).
#
# THIS USED TO BE HERE (R12-F1): the writer half of the ONLY recovery path
# for a malformed REVIEW-ARTIFACT candidate, once review-check.sh's selector
# stopped inferring safety from comment position (bd's own comment order
# reflects a content-supplied created_at, not true insertion order -- `bd
# import` preserves a supplied created_at verbatim even onto an
# already-existing issue, so position was never trustworthy to begin with).
# It validated a 64-hex-char hash and a non-empty reason, then posted
# REVIEW-ARTIFACT-QUARANTINE v1 hash=<hex> at <ts>: <reason> via add_comment.
#
# WHY IT IS GONE, NOT MERELY RE-GUARDED. Independent review round 2 of this
# same task (R2-F1) found the record this command produced forgeable on its
# own first independent review: the comment stream review-check.sh reads has
# no verifiable author (normalize_comments() keeps text only, for every
# reader, not only this mechanism), the READER matched on a bare
# `REVIEW-ARTIFACT-QUARANTINE v1 hash=<64 hex>` PREFIX rather than this
# writer's full `at <ts>: <reason>` grammar, and a hand-typed comment or a
# `bd import` reaches that reader directly without ever calling THIS
# function's own hash/reason validation. Validating the writer's own inputs
# carefully bought nothing when the reader never required anything to have
# come through this writer at all -- the identical unauthenticated channel
# that can post a malformed REVIEW-ARTIFACT candidate could equally forge an
# excuse for one. See the tombstone in review-check.sh (where
# ART-QUARANTINE-HASH used to sit) for the full finding and the reader-side
# removal.
#
# THE RESIDUAL. A malformed REVIEW-ARTIFACT record now deadlocks its task's
# gate permanently, with no in-band recovery -- deliberate, not an
# oversight: see review-check.sh's tombstone for why a forgeable escape
# hatch was worse than no escape hatch. Do not re-add this command, or any
# equivalent, without first solving who is allowed to say so, verifiably --
# not merely which record they are talking about.

# cmd_baseline_capture — write the gate baseline outside the enter/approve
# lifecycle (3mg.1). Exists so session-start.sh has ONE implementation to call
# instead of a second copy of the format; deliberately does NOT require bd
# (no task is involved) and never touches labels.
#
# Usage: qa-gate.sh baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]
cmd_baseline_capture() {
    local by="manual"
    local -a passthru
    passthru=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --by) by="${2:-manual}"; shift ;;
            --if-missing|--exclude-tracked) passthru+=("$1") ;;
            *)
                emit_error_json "baseline-capture" "" "unknown_flag" \
                    "unknown flag '$1'" \
                    "qa-gate.sh baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]"
                exit 1
                ;;
        esac
        shift
    done

    if write_gate_baseline "$by" ${passthru[@]+"${passthru[@]}"}; then
        # Counted through the ONE header-skip reader in this file
        # (gate_baseline_entries), not a second copy of its awk.
        # Do NOT wrap the count in pipefail: `grep -c` exits 1 at count zero,
        # which is the healthy clean-checkout case (entries=0, ok:true). The
        # reader's own rc is checked FIRST instead (i8cx), so a count-back
        # failure says "unreadable" rather than reporting the same 0 a clean
        # checkout reports — 0 and "could not read" are different answers.
        local n="0" entries="" entries_rc=0
        entries=$(gate_baseline_entries) || entries_rc=$?
        if [ "$entries_rc" -eq 0 ]; then
            n=$(printf '%s' "$entries" | grep -c . | tr -d ' ') || true
            n="${n:-0}"
        else
            n="unreadable"
        fi
        emit_json 1 "baseline-capture" "" "captured" \
            "gate-baseline captured_by=$by entries=$n at $GATE_BASELINE_FILE"
        return 0
    fi
    emit_json 0 "baseline-capture" "" "error" \
        "gate-baseline capture failed (captured_by=$by); see sync-errors.log"
    exit 2
}

# TRACKER-RECONCILE BEGIN (94d)
# cmd_reconcile_tracker — the subcommand form of reconcile_tracker, so
# verify-before-stop.sh has ONE implementation to call instead of a second copy
# of the walk (the same reason cmd_baseline_capture exists for session-start.sh,
# and the same reason compute_change_set_hash defers to impact-report.sh
# --hash-only). Deliberately does NOT require bd: no task is involved, no label
# is touched, and the Stop hook must be able to run it on a repo with no Beads
# workspace at all.
#
# Exit codes: 0 reconciled (or legitimately nothing to do), 2 the reconcile
# could not be completed — the caller must treat that as refuse-to-proceed.
cmd_reconcile_tracker() {
    if [ "$#" -gt 0 ]; then
        emit_error_json "reconcile-tracker" "" "unknown_flag" \
            "unknown argument '$1'; reconcile-tracker takes none" \
            "qa-gate.sh reconcile-tracker"
        exit 1
    fi
    if reconcile_tracker; then
        emit_json 1 "reconcile-tracker" "" "reconciled" \
            "${RECONCILE_OBS:-nothing to reconcile} (added=$RECONCILE_ADDED)"
        return 0
    fi
    emit_error_json "reconcile-tracker" "" "tracker_unreconcilable" \
        "${RECONCILE_OBS:-tracker reconcile failed}; the change-set hash would certify less than the actual diff, so callers must refuse to proceed rather than bind an unproven change set" \
        "qa-gate.sh reconcile-tracker"
    exit 2
}
# TRACKER-RECONCILE END (94d)

# ---------------------------------------------------------------------------
# Dispatch

SUB="${1:-}"
shift || true

case "$SUB" in
    enter)        cmd_enter "$@" ;;
    baseline-capture) cmd_baseline_capture "$@" ;;
# TRACKER-RECONCILE BEGIN (94d)
    reconcile-tracker) cmd_reconcile_tracker "$@" ;;
# TRACKER-RECONCILE END (94d)
    status)       cmd_status "$@" ;;
    approve)      cmd_approve "$@" ;;
    block)        cmd_block "$@" ;;
    choose)       cmd_choose "$@" ;;
    grade-record) cmd_grade_record "$@" ;;
    review-record)   cmd_review_record "$@" ;;
    review-reconcile) cmd_review_reconcile "$@" ;;
    completion-record) cmd_completion_record "$@" ;;
    grilling-record) cmd_grilling_record "$@" ;;
    design-record)   cmd_design_record "$@" ;;
    design-review-record) cmd_design_review_record "$@" ;;
    design-gate-precheck) cmd_design_gate_precheck "$@" ;;
    design-unit-bind) cmd_design_unit_bind "$@" ;;
    design-conform) cmd_design_conform "$@" ;;
    design-unit-show) cmd_design_unit_show "$@" ;;
    design-status)    cmd_design_status "$@" ;;
    design-conflict)  cmd_design_conflict "$@" ;;
    resolve-finding) cmd_resolve_finding "$@" ;;
    arbitrate)       cmd_arbitrate "$@" ;;
    # quarantine-artifact dispatch -- REMOVED (claude-workflow-plugin-k6re,
    # R2-F1). See the tombstone above cmd_quarantine_artifact's former
    # definition. Falls through to the "unknown subcommand" arm below.
    ""|-h|--help|help)
        usage
        exit 1
        ;;
    *)
        echo "qa-gate.sh: unknown subcommand: $SUB" >&2
        usage
        exit 1
        ;;
esac

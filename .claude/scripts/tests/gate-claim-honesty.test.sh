#!/bin/bash
# gate-claim-honesty.test.sh — L1 unit fixture for the claims the gate makes
# ABOUT ITSELF (claude-workflow-plugin-fkm.1.11 and claude-workflow-plugin-ko82).
#
# ONE THEME, ONE GUARD PER META BLOCK: operator-facing output must not claim
# more than the mechanism delivers. No guard count lives in this line: the one
# it used to carry ("SIX GUARDS") sat here stale through three rounds that
# added guards, contradicting the paragraph written to stop that number being
# wrong (R8-F4) — THE COUNT below is the single authoritative number, and a
# second copy is the drift qa-gate.sh:1640 names. The shipped defects that
# motivated this file, all measured:
#
#   fkm.1.11  The Stop block reason ended in the flat literal "technical checks
#             passed". What it covered was the DETECTED RUNNER'S DEFAULT target
#             — on this repo `make test` (the L1 tier) plus `make lint`, with
#             type_cmd resolving EMPTY so the type stage ran nothing. With four
#             L2 specs red and 28 assertion failures outstanding, every Stop of
#             that session printed "technical checks passed".
#   fkm.1.11  ...and the readout that replaced it then claimed the ledger's
#   (R1-F1)   record had been written by the command it names — "the command
#             recorded its own result". `record_verification` takes the label
#             and the exit code as ARGUMENTS and the ledger line carries no
#             writer field, so nothing distinguishes a record `make` wrote from
#             one a person typed — and the only record this repo's ledger held
#             had been typed by hand. Corrected in review, then shipped with NO
#             control: a mutant restoring the deleted wording at both sites
#             passed every leg in this file, so reverting a HIGH fix turned
#             nothing red (R2-F1). Section 4's 4.8b/4.10b and the 4N META are
#             that control.
#   fkm.1.11  ...and the FINGERPRINT that readout compares was a CONSTANT on any
#   (R3-F1)   host carrying neither shasum nor sha256sum. `_vl_sha256` degrades
#             to a fixed string, `cut -c1-16` truncates it to another fixed
#             string, and two fixed strings compare EQUAL — so the readout
#             stated "The working tree is UNCHANGED since that run ... so it
#             does describe these changes" over a tree rewritten end to end,
#             from inside the block promising the design degrades "to cannot
#             tell, never to a false match". The project had already met this
#             sentinel hazard in change_set_hash and fixed it at BOTH ends
#             (qa-gate.sh's CHANGE_SET_HASH_UNAVAILABLE, pinned by
#             rubric-binding.sh I4); this region copied the writer and left the
#             reader behind. Section 4's 4.11-4.20 and the 4P META are that
#             control.
#   fkm.1.11  ...and the SAME false sentence then turned out to have three more
#   (R4-F1,   ways in, each found in the round that fixed the previous one: a
#    R4-F3,   `git diff HEAD` that FAILS on a completely normal host (a
#    +one)    .gitattributes textconv driver configured but not installed), a
#             STAGED never-committed file that is in neither the untracked set
#             nor any diff, and a missing `cut` that makes the return value the
#             empty string. Four findings, one function, one shape: an input
#             degrades to a constant and nothing refuses it. The fix is ONE
#             invariant — every producer must exit 0 and every hash must have a
#             hash's shape — and section 4's 4.21-4.37 assert all three new
#             routes against the SINGLE refusal that now covers them, which is
#             what the 4P META mutates.
#   ko82      The LABEL_WITHOUT_RECORD block reason told operators that
#             "editing a tracked file AFTER approval shifts the current
#             change-set hash". change_set_hash is a sha256 over the sorted,
#             denylist-filtered PATH LIST; contents are never hashed. It sat
#             third in a list of four whose other three are accurate.
#
# WHY THIS TIER. Every assertion here is over a pure function of its inputs —
# an extracted shell function, or `impact-report.sh --hash-only` against a
# seeded tracker. No bd, no network, no LLM. It deliberately does NOT need bd
# (claude-workflow-plugin-a9hh: when this was written, CI ran L1 under
# BD_SHIM_ONLY=1 and a spec that skipped on absent bd exited 0 having
# executed nothing; a9hh since installed real bd in CI, deleted the L1 skip
# arms, and made the runner refuse to count a zero-assertion exit-0 as a
# pass). Nothing in this file has a skip-to-exit-0 arm.
#
# THE ASSERTIONS ARE ANCHORED TO MEASURED BEHAVIOUR, NOT TO FIXED STRINGS.
# Section 1 MEASURES what the shipped hash does; sections 2 onward assert that
# the shipped TEXT agrees with that measurement. If change_set_hash ever becomes
# content-sensitive, section 1's verdict flips and section 2's expectation flips
# with it — instead of a pinned string quietly going stale, which is the failure
# mode this whole file exists to catch.
#
# PAIRING (see .claude/tests/README.md "The pairing requirement"). Every guard
# below ships with a negative control meeting all four parts: a mutation with an
# explicit leg proving it LANDED, an assertion that the mutant misbehaves in the
# way the guard prevents (naming the check that would fail), a restore control
# on the shipped artifact, and — the discriminator — at least one leg that
# OBSERVES THE SHIPPED ARTIFACT RUNNING. Every section here drives an
# executable: `impact-report.sh`, functions extracted verbatim from
# `verify-before-stop.sh`, and `make` against the real Makefile's guard lines.
#
# Sections:
#   1  MEASURE the shipped change-set hash: content-invariant, membership-
#      sensitive, and the exact-set-re-entry case
#   2  ko82 — the approval-binding text must AGREE with section 1
#   2M ko82 META — re-insert the false bullet; the section-2 check must fail
#   3  fkm.1.11 — the check-scope claim names the commands that ran
#   3M fkm.1.11 META — restore the flat literal; the section-3 check must fail
#   4  fkm.1.11(b) — the tree fingerprint is content-sensitive and excludes the
#      workflow's own state; the readout built on it claims NO provenance for
#      the record it reads (4.8b / 4.10b); and neither reports a comparison it
#      could not make — no sha256 tool (4.11-4.20), a broken diff driver the
#      flags now render harmless (4.21-4.28), an unborn HEAD with a staged file
#      (4.29-4.33), no `cut` (4.34-4.37), a diff that genuinely fails
#      (4.38-4.42b), a WORKING-but-lossy textconv driver (4.43-4.47), an
#      unreadable path in the untracked set (4.48-4.53c), a C-QUOTED
#      (newline-carrying) name in that set while the fallback runs (4.54-4.58c),
#      and a WORKING-but-lossy clean FILTER over the untracked set, whose
#      tracked half is the measured KNOWN LIMITS residual (4.59-4.63)
#   4M META — drop the self-written filter; recording a result moves the tree
#   4N META — restore the deleted provenance claim; 4.8b/4.10b must fail
#   4P META — the invariant: remove the single refusal and all four degradation
#             sandboxes read as real fingerprints again; then remove the
#             empty-tree base and the unborn-HEAD case stops being measurable
#   4Q META — restore the swallowed hash-object failure; one broken symlink
#             freezes the fingerprint again, and only in one sort order
#   4R META — remove `--no-ext-diff --no-textconv`; a driver that WORKS blinds
#             input 2 with nothing failing and nothing malformed
#   4S META — hand the fallback its names as ARGV again; a READABLE newline-
#             named file reads as UNREADABLE and the fingerprint freezes
#   4T META — hash the untracked set through the attributes machinery again;
#             a file behind a WORKING clean filter hashes to one constant on
#             both routes and the fingerprint freezes
#   5  the Makefile dry-run guard: `make -n` must not mint a verification record
#   5M META — remove the guard; the dry run mints a false green
#   6  claude-workflow-plugin-j7kk (9xl4 cheap half) — the skip-when-unchanged
#      predicate requires BOTH tree_fingerprint (content) and
#      current_change_set_hash (path list) to match a persisted record before
#      it says "unchanged"; the write side refuses to persist a sentinel and
#      the read side refuses to match one, the same "both the writer and the
#      reader refuse it" discipline section 4/rubric-binding.sh I4 already
#      apply to change_set_hash. checks_scope_claim/note are also re-asserted
#      here (6.11) for the new SUITE_REUSE_REASON/SUITE_REUSE_DETAIL
#      parameters, including the pre-j7kk caller's unchanged default.
#   6M META — the k0mc gap this section exists to close, reproduced on demand:
#             narrow the predicate to the path-list hash alone (dropping the
#             tree_fingerprint half) and a real content-only edit to an
#             already-tracked file is WRONGLY read as "unchanged"
#
# THE COUNT, spelled out because it has been wrong once in this paragraph
# (R1-F2) and once in the headline (R8-F4): ELEVEN guards and SIX numbered
# sections, and the two numbers are not meant to agree. Section 1 is a
# MEASUREMENT and is no guard; section 4 carries SEVEN — the fingerprint's
# content sensitivity (paired by 4M), the readout's provenance claim (paired by
# 4N), the fingerprint's INVARIANT (paired by 4P), the per-path fallback over the
# untracked set (paired by 4Q), the diff flags that keep drivers out of input 2
# (paired by 4R), the fallback's QUOTING CONVENTION (paired by 4S), and the
# untracked hashes' FILTER BYPASS (paired by 4T). Section 6 carries ONE — the
# two-instrument requirement, paired by 6M; 6.11's checks_scope_claim/note
# reassertion is coverage of an existing guard (3, paired by 3M) extended to a
# new parameter, not a second guard of its own. The check is mechanical, one
# META per guard: 2M, 3M, 4M, 4N, 4P, 4Q, 4R, 4S, 4T, 5M, 6M.
#
# 4P CARRIES TWO MUTATIONS UNDER ONE BANNER, and that is deliberate rather than
# a miscount. The invariant has two halves — an input must CARRY CONTENT wherever
# its producer can read the repository, and the function must REFUSE when a
# producer fails — and neutralising either half leaves the other unexercised. It
# is still ONE guard: the degradations it covers share a single refusal, and the
# first mutation breaks every leg that depends on it at once.
#
# 4Q AND 4R ARE SEPARATE GUARDS, NOT A THIRD AND FOURTH MUTATION OF 4P, and the
# reason is the design result of the round that added them. 4Q's defect SURVIVED
# the invariant by being the one call deliberately exempted from it, so `if
# false` was never lethal there. 4R's defect cannot be refused AT ALL — its
# producer exits 0 and its digest is 64 valid hex characters, so there is nothing
# for any guard to detect and the cure is to stop the degradation rather than
# catch it. Folding either into 4P would assert a shared mechanism that does not
# exist.
#
# 4S IS SEPARATE FROM 4Q FOR THE SAME KIND OF REASON, one level down: 4Q
# mutates the fallback's EXISTENCE, 4S its CALLING CONVENTION. A mutant that
# keeps the fallback but hands it names as argv passes every 4Q leg — 4Q's
# sandbox carries plain names, which argv reads correctly — and it shares 4R's
# signature: nothing fails and nothing is malformed, so no refusal is
# reachable. Measured before this META existed: reverting the R7-F1 fix left
# all 194 prior checks green.
#
# 4T IS 4R'S SHAPE ONE INPUT OVER, and a separate guard for the same reason 4R
# is separate from 4P: same signature (every producer rc=0, every digest
# well-formed, no refusal reachable), DIFFERENT input and different switch. 4R
# pins the flags that keep drivers out of the DIFF; 4T pins the flag that
# keeps the attributes machinery — clean filters, eol/text, working-tree-
# encoding — out of the UNTRACKED hashes, on the batch call and the per-path
# fallback both. A mutant lacking either switch passes every leg of the other:
# 4R's sandbox has no filter and 4T's has no textconv. Measured before this
# META existed: reverting the R8-F1 fix left all 213 prior checks green.
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
VBS="$PROJECT_DIR/.claude/scripts/verify-before-stop.sh"
IMPACT="$PROJECT_DIR/.claude/scripts/impact-report.sh"
DENYLIST_LIB="$PROJECT_DIR/.claude/scripts/workflow-denylist.sh"
MAKEFILE="$PROJECT_DIR/Makefile"

for f in "$VBS" "$IMPACT" "$DENYLIST_LIB" "$MAKEFILE"; do
    if [ ! -f "$f" ]; then
        printf 'gate-claim-honesty.test: artifact under test missing: %s\n' "$f" >&2
        exit 2
    fi
done

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

# Counts rather than `grep -q`: a haystack piped into `grep -q` closes the pipe
# on first match, which prints "printf: write error: Broken pipe" mid-run when
# the haystack is large (the same reason approve-idempotency.sh counts).
contains_count() {
    printf '%s' "$2" | grep -cF -- "$1" 2>/dev/null || true
}

assert_contains() {
    local name="$1" needle="$2" hay="$3" n
    n=$(contains_count "$needle" "$hay" | tr -d '[:space:]')
    if [ "${n:-0}" -gt 0 ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected to CONTAIN: %s\n' "$name" "$needle"
    fi
}

assert_absent() {
    local name="$1" needle="$2" hay="$3" n
    n=$(contains_count "$needle" "$hay" | tr -d '[:space:]')
    if [ "${n:-0}" -eq 0 ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected NOT to contain: %s\n' "$name" "$needle"
    fi
}

WORK=$(mktemp -d -t gate-claim-honesty.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# extract_region <src> <BEGIN-marker> <END-marker> <out>
# Text-anchored, never line-numbered, and it REPORTS A MISS: exit 7 when the
# sentinels are absent, so a rename cannot turn this file into a set of vacuous
# passes over an empty extraction. That is part 1 of the pairing standard
# applied to the test's own dependency.
extract_region() {
    local src="$1" b="$2" e="$3" out="$4"
    awk -v b="$b" -v e="$e" '
        index($0, b) == 1 { inr = 1; found = 1 }
        inr { print }
        index($0, e) == 1 { inr = 0 }
        END { if (!found) exit 7 }
    ' "$src" > "$out"
}

# ===========================================================================
# 1. MEASURE the shipped change-set hash.
#
# This section is the GROUND TRUTH the text assertions are compared against,
# and it drives the shipped `impact-report.sh --hash-only` rather than a copy
# of its logic. Three questions, in the shape an operator actually hits them.
# ===========================================================================
printf '\n--- 1. MEASURED: what the shipped change_set_hash is sensitive to ---\n'

M1="$WORK/m1"
mkdir -p "$M1/.claude/.qa-tracking" "$M1/src"
TRACK="$M1/.claude/.qa-tracking/changed-files.txt"
hash_now() { CLAUDE_PROJECT_DIR="$M1" bash "$IMPACT" --hash-only 2>/dev/null; }

printf 'original\n' > "$M1/src/x.js"
printf 'original\n' > "$M1/src/y.js"
printf '%s\n%s\n' "$M1/src/x.js" "$M1/src/y.js" > "$TRACK"
H_BASE=$(hash_now)

assert_eq "1.0 non-vacuity: the shipped script produced a hash at all (not an empty string)" \
    "yes" "$([ -n "$H_BASE" ] && echo yes || echo no)"

# (a) CONTENT: rewrite a listed file end to end. Same path, different bytes.
printf 'ENTIRELY DIFFERENT CONTENT\nwith\nmore\nlines\n' > "$M1/src/x.js"
H_CONTENT=$(hash_now)
CONTENT_SENSITIVE=$([ "$H_CONTENT" != "$H_BASE" ] && echo yes || echo no)
assert_eq "1.1 the file's bytes really did change (the mutation landed)" \
    "yes" "$([ "$(shasum -a 256 "$M1/src/x.js" | awk '{print $1}')" != "$(printf 'original\n' | shasum -a 256 | awk '{print $1}')" ] && echo yes || echo no)"
assert_eq "1.2 MEASURED: rewriting a listed file does NOT move change_set_hash" \
    "no" "$CONTENT_SENSITIVE"

# (b) MEMBERSHIP: add a path.
printf 'new\n' > "$M1/src/z.js"
printf '%s\n' "$M1/src/z.js" >> "$TRACK"
H_ADDED=$(hash_now)
assert_eq "1.3 MEASURED: adding a path DOES move change_set_hash" \
    "yes" "$([ "$H_ADDED" != "$H_CONTENT" ] && echo yes || echo no)"

# (c) EXACT-SET RE-ENTRY: what `approve` leaves behind. approve truncates
#     changed-files.txt (qa-gate.sh truncate_changed_files_tracker), so the live
#     hash afterwards covers the paths touched SINCE. Touch precisely the
#     approved set again and the hash returns to the approved value.
printf '%s\n%s\n' "$M1/src/x.js" "$M1/src/y.js" > "$TRACK"
H_APPROVED=$(hash_now)
: > "$TRACK"                                   # <- the truncation
H_EMPTY=$(hash_now)
assert_eq "1.4 truncation yields a DIFFERENT hash (the empty-set hash)" \
    "yes" "$([ "$H_EMPTY" != "$H_APPROVED" ] && echo yes || echo no)"
printf 'REWRITTEN AFTER APPROVAL\n' > "$M1/src/x.js"
printf 'REWRITTEN AFTER APPROVAL\n' > "$M1/src/y.js"
printf '%s\n%s\n' "$M1/src/x.js" "$M1/src/y.js" >> "$TRACK"
H_REENTERED=$(hash_now)
assert_eq "1.5 MEASURED: re-touching EXACTLY the approved set returns the approved hash" \
    "$H_APPROVED" "$H_REENTERED"
# And the partial case, which is what normally produces the block.
: > "$TRACK"
printf '%s\n' "$M1/src/x.js" >> "$TRACK"
assert_eq "1.6 MEASURED: re-touching a SUBSET of the approved set does NOT match" \
    "yes" "$([ "$(hash_now)" != "$H_APPROVED" ] && echo yes || echo no)"

# ===========================================================================
# 2. ko82 — the approval-binding TEXT must agree with section 1.
#
# The predicate is derived from CONTENT_SENSITIVE, so this is not a pinned
# string: make the hash content-sensitive and the expectation inverts.
# ===========================================================================
printf '\n--- 2. ko82: the block-reason text agrees with the measured mechanism ---\n'

ABT="$WORK/abt.sh"
ABT_RC=0
extract_region "$VBS" "# APPROVAL-BINDING-TEXT BEGIN" "# APPROVAL-BINDING-TEXT END" "$ABT" || ABT_RC=$?
assert_eq "2.0 non-vacuity: the APPROVAL-BINDING-TEXT sentinels exist in the shipped hook" \
    "0" "$ABT_RC"
ABT_PARSE=0; bash -n "$ABT" 2>/dev/null || ABT_PARSE=$?
assert_eq "2.1 the extracted region is valid bash on its own" "0" "$ABT_PARSE"

# shellcheck disable=SC1090  # the region is extracted at runtime; its path is not constant by design
emit_binding_text() { ( . "$1"; approval_record_causes 'proj-42'; printf '\n'; approval_binding_attests ); }
SHIPPED_TEXT=$(emit_binding_text "$ABT")

assert_eq "2.2 the shipped region EMITTED text (it ran, it is not empty)" \
    "yes" "$([ -n "$SHIPPED_TEXT" ] && echo yes || echo no)"

# THE CENTRAL ASSERTION. `claims_content_shift` is the misbehaviour predicate:
# does this text tell an operator that EDITING a file moves the hash?
claims_content_shift() {
    local n
    n=$(printf '%s' "$1" | grep -ciE 'editing a tracked file[^.]*shift' 2>/dev/null || true)
    printf '%s' "$(printf '%s' "${n:-0}" | tr -d '[:space:]')"
}
if [ "$CONTENT_SENSITIVE" = "no" ]; then
    assert_eq "2.3 hash measured content-INVARIANT, so the text must NOT claim editing shifts it" \
        "0" "$(claims_content_shift "$SHIPPED_TEXT")"
else
    assert_eq "2.3 hash measured content-SENSITIVE, so the text MUST say so" \
        "1" "$([ "$(claims_content_shift "$SHIPPED_TEXT")" -gt 0 ] && echo 1 || echo 0)"
fi

# The positive half: it must state what the binding DOES attest, and the two
# residuals. A text that merely deleted the false sentence would pass 2.3 and
# fail these.
assert_contains "2.4 the text states the attestation (membership + review-at-review-time)" \
    "MEMBERSHIP PLUS REVIEW-AT-REVIEW-TIME" "$SHIPPED_TEXT"
assert_contains "2.5 the text says explicitly that content is NOT attested" \
    "does NOT attest CONTENT" "$SHIPPED_TEXT"
assert_contains "2.6 the text names the exact-set re-entry residual measured at 1.5" \
    "Re-editing EXACTLY the approved set" "$SHIPPED_TEXT"
assert_contains "2.7 the membership bullet explains the block by path-set divergence" \
    "DIFFERENT SET OF FILES after approval" "$SHIPPED_TEXT"
# Do not overcorrect: the four things that DO block must still be named.
assert_contains "2.8 the text still names the forged-label defence" \
    "forged or stale label" "$SHIPPED_TEXT"
assert_contains "2.9 the text still names the decoy-redirect defence" \
    "decoy" "$SHIPPED_TEXT"

# THE EARNED-WARNING DISCRIMINATOR, asserted from both sides.
# "Never verify a removal by grepping for the removed pattern": the region
# header quotes the false sentence in order to explain the fix, so a grep over
# the FILE finds it. The grep above is over the FUNCTION'S OUTPUT, where a
# comment cannot reach. Both halves are pinned so the escape cannot silently
# stop working — if someone later inlines the text back into the file, 2.11
# fails and says why.
# Anchored on `^#` so it asserts the sentence survives AS A COMMENT. Without
# that anchor this check passes on a tree where the sentence is still the LIVE
# bullet — i.e. on the unfixed tree — which would make the discriminator
# meaningless in exactly the state it is meant to distinguish.
FILE_HAS=$(grep -ciE '^#.*editing a tracked file[^.]*shift' "$VBS" 2>/dev/null || true)
FILE_HAS=$(printf '%s' "$FILE_HAS" | tr -d '[:space:]')
assert_eq "2.10 the FILE still contains the false sentence AS A COMMENT (explaining its removal)" \
    "yes" "$([ "${FILE_HAS:-0}" -gt 0 ] && echo yes || echo no)"
LIVE_HAS=$(grep -ciE '^[^#]*- Editing a tracked file[^.]*shift' "$VBS" 2>/dev/null || true)
LIVE_HAS=$(printf '%s' "$LIVE_HAS" | tr -d '[:space:]')
assert_eq "2.10b ...and NOT as a live bullet anywhere in the file" \
    "0" "${LIVE_HAS:-0}"
assert_eq "2.11 the OUTPUT does not — which is why 2.3 greps output, never the file" \
    "0" "$(claims_content_shift "$SHIPPED_TEXT")"

# ---------------------------------------------------------------------------
# 2M. META — put the false bullet back and prove 2.3 catches it.
# ---------------------------------------------------------------------------
printf '\n--- 2M. META: re-inserting the false bullet must break check 2.3 ---\n'

ABT_MUT="$WORK/abt-mut.sh"
sed "s|'  - Working on a DIFFERENT SET OF FILES after approval. The hash is over the'|'  - Editing a tracked file AFTER approval shifts the current change-set hash'|" \
    "$ABT" > "$ABT_MUT"
assert_eq "2M.0 non-vacuity: the mutant differs from the shipped region (the substitution LANDED)" \
    "yes" "$([ "$(shasum -a 256 "$ABT_MUT" | awk '{print $1}')" != "$(shasum -a 256 "$ABT" | awk '{print $1}')" ] && echo yes || echo no)"
MUT_PARSE=0; bash -n "$ABT_MUT" 2>/dev/null || MUT_PARSE=$?
assert_eq "2M.1 the mutant is still valid bash (so a failure is the mutation, not a syntax error)" \
    "0" "$MUT_PARSE"
MUT_TEXT=$(emit_binding_text "$ABT_MUT")
assert_eq "2M.2 the mutant still emits text (it RAN — the mutation did not just break it)" \
    "yes" "$([ -n "$MUT_TEXT" ] && echo yes || echo no)"
# SPECIFIC MISBEHAVIOUR, naming the check that would fail:
assert_eq "2M.3 SPECIFIC: the mutant claims editing shifts the hash, so check 2.3 FAILS on it" \
    "yes" "$([ "$(claims_content_shift "$MUT_TEXT")" -gt 0 ] && echo yes || echo no)"
# RESTORE CONTROL: same predicate, same call shape, shipped artifact.
assert_eq "2M.4 RESTORE CONTROL: the shipped region passes the identical predicate" \
    "0" "$(claims_content_shift "$SHIPPED_TEXT")"

# ===========================================================================
# 3. fkm.1.11 — the check-scope claim names the commands that actually ran.
# ===========================================================================
printf '\n--- 3. fkm.1.11: the gate names what it ran, and what it did not ---\n'

LEDGER_REGION="$WORK/ledger.sh"
SCOPE_REGION="$WORK/scope.sh"
LR_RC=0; SR_RC=0
extract_region "$VBS" "# VERIFICATION-LEDGER BEGIN" "# VERIFICATION-LEDGER END" "$LEDGER_REGION" || LR_RC=$?
extract_region "$VBS" "# CHECK-SCOPE BEGIN" "# CHECK-SCOPE END" "$SCOPE_REGION" || SR_RC=$?
assert_eq "3.0 non-vacuity: the VERIFICATION-LEDGER sentinels exist" "0" "$LR_RC"
assert_eq "3.1 non-vacuity: the CHECK-SCOPE sentinels exist" "0" "$SR_RC"
assert_eq "3.2 the extracted CHECK-SCOPE region is valid bash" \
    "0" "$(bash -n "$SCOPE_REGION" 2>/dev/null; echo $?)"

# Drive the shipped functions with THIS REPO'S measured detect-stack values:
# runner=make, test and lint present, type_cmd EMPTY.
drive_scope() {
    # drive_scope <scope-region> <test_cmd> <lint_cmd> <type_cmd> <suite_reused> <what>
    local reg="$1" t="$2" l="$3" y="$4" reused="$5" what="$6"
    (
        set -u
        PROJECT_DIR="$WORK/noproj"; QA_TRACKING_DIR="$WORK/noproj/.claude/.qa-tracking"
        mkdir -p "$QA_TRACKING_DIR"
        # shellcheck disable=SC1090
        . "$LEDGER_REGION"
        # shellcheck disable=SC1090
        . "$reg"
        # These five are the INPUTS the sourced shipped functions read as
        # globals — assigned here, consumed there. `export` rather than a
        # disable directive because that is literally what SC2034 asks for
        # ("or export if used externally"), and a directive would cover only
        # the first assignment of a semicolon-separated line anyway. Harmless:
        # the functions run in this same subshell.
        # shellcheck disable=SC2030,SC2031  # deliberately subshell-scoped —
        # this function and drive_scope_reason (Section 6.11) both export the
        # same names into THEIR OWN separate ( ) subshells so neither leaks
        # into the shared top-level scope; each subshell's export is read only
        # by the case arm three lines below it, never by the other subshell.
        export RUNNER="make" TEST_CMD="$t" LINT_CMD="$l" TYPE_CMD="$y" SUITE_REUSED="$reused"
        case "$what" in
            claim) checks_scope_claim ;;
            note)  checks_scope_note ;;
        esac
    )
}

REAL_TEST='cd "/repo" && make test'
REAL_LINT='cd "/repo" && make lint'
CLAIM=$(drive_scope "$SCOPE_REGION" "$REAL_TEST" "$REAL_LINT" "" false claim)
NOTE=$(drive_scope "$SCOPE_REGION" "$REAL_TEST" "$REAL_LINT" "" false note)

assert_eq "3.3 the shipped claim function RAN and produced output" \
    "yes" "$([ -n "$CLAIM" ] && echo yes || echo no)"
# The defect, stated as an assertion: the phrase that overclaimed is gone.
assert_absent "3.4 the claim no longer says the unqualified 'technical checks passed'" \
    "technical checks passed" "$CLAIM"
assert_absent "3.5 nor does the scope note" \
    "technical checks passed" "$NOTE"
assert_contains "3.6 the claim names the stages that ran" "tests + lint" "$CLAIM"
assert_contains "3.7 the claim says explicitly that nothing else ran" "nothing else ran" "$CLAIM"
# The note names the literal commands, so the reader can re-run them.
assert_contains "3.8 the note names the literal test command" "$REAL_TEST" "$NOTE"
assert_contains "3.9 the note names the literal lint command" "$REAL_LINT" "$NOTE"
assert_contains "3.10 the note marks the EMPTY type stage as NOT RUN (this repo's real state)" \
    "NOT RUN  type-check" "$NOTE"
assert_contains "3.11 the note states that a wider tier is not covered" \
    "is not part of them, is not run here" "$NOTE"
assert_contains "3.12 the note carries the broader-verification readout" \
    "Broader verification" "$NOTE"

# No runner at all: the claim must say nothing ran, not fall silent.
CLAIM_NONE=$(drive_scope "$SCOPE_REGION" "" "" "" false claim)
assert_contains "3.13 with no commands detected the claim says NO check ran" \
    "NO technical check ran" "$CLAIM_NONE"
# Escalated replay: it must not claim this loop ran anything.
CLAIM_REUSED=$(drive_scope "$SCOPE_REGION" "$REAL_TEST" "$REAL_LINT" "" true claim)
assert_contains "3.14 under SUITE_REUSED the claim says the checks were NOT re-run" \
    "NOT re-run this loop" "$CLAIM_REUSED"

# ---------------------------------------------------------------------------
# 3M. META — restore the pre-fix flat literal and prove checks 3.4/3.6 catch it.
# ---------------------------------------------------------------------------
printf '\n--- 3M. META: the flat "technical checks passed" claim must break 3.4/3.6 ---\n'

SCOPE_MUT="$WORK/scope-mut.sh"
# Replace the body of checks_scope_claim with the literal it shipped as before
# fkm.1.11. Anchored on the function header, never on a line number.
awk '
    /^checks_scope_claim\(\) \{/ { print; print "    printf %s \"technical checks passed\"; return 0"; skip=1; found=1; next }
    skip && /^\}/ { print; skip=0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$SCOPE_REGION" > "$SCOPE_MUT"
SCOPE_MUT_RC=$?
assert_eq "3M.0 non-vacuity: checks_scope_claim was found and replaced (awk exit 0, not 7)" \
    "0" "$SCOPE_MUT_RC"
assert_eq "3M.1 non-vacuity: the mutant's bytes differ from the shipped region" \
    "yes" "$([ "$(shasum -a 256 "$SCOPE_MUT" | awk '{print $1}')" != "$(shasum -a 256 "$SCOPE_REGION" | awk '{print $1}')" ] && echo yes || echo no)"
assert_eq "3M.2 the mutant is still valid bash" \
    "0" "$(bash -n "$SCOPE_MUT" 2>/dev/null; echo $?)"
CLAIM_MUT=$(drive_scope "$SCOPE_MUT" "$REAL_TEST" "$REAL_LINT" "" false claim)
assert_eq "3M.3 the mutant RAN and produced output" \
    "yes" "$([ -n "$CLAIM_MUT" ] && echo yes || echo no)"
# SPECIFIC MISBEHAVIOUR, naming the checks that would fail:
assert_eq "3M.4 SPECIFIC: the mutant emits the overclaim, so check 3.4 FAILS on it" \
    "1" "$(contains_count 'technical checks passed' "$CLAIM_MUT" | tr -d '[:space:]')"
assert_eq "3M.5 SPECIFIC: the mutant names no command, so check 3.6 FAILS on it" \
    "0" "$(contains_count 'tests + lint' "$CLAIM_MUT" | tr -d '[:space:]')"
assert_absent "3M.6 RESTORE CONTROL: the shipped claim, same inputs, carries no overclaim" \
    "technical checks passed" "$CLAIM"

# ===========================================================================
# 4. fkm.1.11(b) — the tree fingerprint, and the readout built on it.
#
# The fingerprint must be sensitive to CONTENT (a porcelain-derived fingerprint
# would carry the same blind spot as change_set_hash — section 1.2) and it must
# EXCLUDE the workflow's own state (or writing the record moves the tree past
# the run it just recorded). Paired by 4M.
#
# The READOUT is the section's second guard, paired by 4N: it must report what
# the ledger holds WITHOUT claiming who wrote it. Both halves are asserted over
# the emitted TEXT and never over the file — the region header quotes the
# deleted sentence in order to explain the deletion, so a file grep finds it by
# design. That is the same escape 2.10/2.11 pins from both sides.
#
# The THIRD guard (4.11-4.37, paired by 4P) is the one neither of those catches,
# because both of them run on a host where every input works. Four separate
# configurations make an input degrade to a CONSTANT — no sha256 tool, a failed
# `git diff`, an unborn HEAD with a staged file, no `cut` — and a constant equals
# itself, so the comparison stopped being a measurement while the sentence built
# on it went on sounding like one. They are asserted as four sandboxes against
# ONE refusal, which is the whole subject of the round that added the last three:
# a guard per remembered degradation cannot refuse the one nobody has met yet.
# Asserted over emitted text for the same reason as the rest — and, like them,
# never by grepping the file, since the region header names the sentinel in
# order to explain the refusal.
# ===========================================================================
printf '\n--- 4. fkm.1.11(b): a content-sensitive, self-exclusive fingerprint — and a readout that vouches for nobody ---\n'

if ! command -v git >/dev/null 2>&1; then
    printf 'gate-claim-honesty.test: git is required for section 4/5 and is absent\n' >&2
    exit 2
fi

G="$WORK/gitproj"
mkdir -p "$G"
( cd "$G" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'one\n' > tracked.txt && git add tracked.txt && git commit -qm init ) >/dev/null 2>&1

# NOTE: no .gitignore here ON PURPOSE. In this repo .claude/.qa-tracking/ is
# gitignored, which HIDES the defect 4M reproduces; an installed target only
# gets that ignore rule when it had no .gitignore at all, so the unignored
# case is the one that has to be pinned.
drive_ledger() {
    # drive_ledger <ledger-region> <fn> [args...]
    local reg="$1"; shift
    (
        set -u
        PROJECT_DIR="$G"; QA_TRACKING_DIR="$G/.claude/.qa-tracking"; mkdir -p "$QA_TRACKING_DIR"
        # shellcheck disable=SC1090
        . "$DENYLIST_LIB"
        # shellcheck disable=SC1090
        . "$reg"
        "$@"
    )
}

FP0=$(drive_ledger "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.0 the shipped tree_fingerprint RAN and produced a value" \
    "yes" "$([ -n "$FP0" ] && [ "$FP0" != "no-git" ] && echo yes || echo no)"

drive_ledger "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
assert_eq "4.1 recording a result wrote the ledger (the write really happened)" \
    "yes" "$([ -s "$G/.claude/.qa-tracking/verification-ledger" ] && echo yes || echo no)"
FP_AFTER_RECORD=$(drive_ledger "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.2 the gate's OWN write does NOT move the fingerprint (self-written excluded)" \
    "$FP0" "$FP_AFTER_RECORD"

printf 'ENTIRELY DIFFERENT\n' > "$G/tracked.txt"
FP_CONTENT=$(drive_ledger "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.3 rewriting a TRACKED file DOES move it (the section-1.2 blind spot is absent)" \
    "yes" "$([ "$FP_CONTENT" != "$FP0" ] && echo yes || echo no)"
( cd "$G" && git checkout -q -- tracked.txt )
assert_eq "4.4 reverting that file restores the original fingerprint (it is a function of state)" \
    "$FP0" "$(drive_ledger "$LEDGER_REGION" tree_fingerprint)"

printf 'u1\n' > "$G/untracked.txt"
FP_UNTRACKED=$(drive_ledger "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.5 a NEW untracked file moves it" \
    "yes" "$([ "$FP_UNTRACKED" != "$FP0" ] && echo yes || echo no)"
printf 'u2-different\n' > "$G/untracked.txt"
assert_eq "4.6 rewriting an untracked file's CONTENT moves it (hashed by content, not by name)" \
    "yes" "$([ "$(drive_ledger "$LEDGER_REGION" tree_fingerprint)" != "$FP_UNTRACKED" ] && echo yes || echo no)"
rm -f "$G/untracked.txt"

# THE PROVENANCE PREDICATE — one rule, applied to both readout branches and to
# the 4N mutant, so a claim that merely MOVED from one branch to the other
# cannot slip past it.
#
# THESE TWO FIXED STRINGS, AND DELIBERATELY NOT A LOOSER PATTERN. The
# empty-ledger branch still prints `make test-ci (runs every offline tier and
# records its own exit status)` — true of that ONE recipe and deliberately
# kept. A needle like `records? its own` would forbid that true sentence and
# fire on the FIXED tree. What R1-F1 deleted was the GENERALISATION from that
# recipe to the ledger, and these are the two sentences that made it.
#
# Whitespace is flattened first, which is load-bearing rather than tidy: both
# strings sit inside wrapped multi-line printfs, so a re-wrap that pushed one
# across a line break would leave `grep -F` matching nothing and this guard
# silently green. That is not hypothetical — it is the trap the round-2 fix
# caught in itself while grepping the same phrase out of a comment.
#
# KNOWN LIMIT, stated rather than implied: this is a REVERT control, not a
# paraphrase control. It goes red on the wording R1-F1 deleted (measured at 4N);
# the same claim re-introduced in different words would pass it, and nothing in
# this tier can do better — the true sentence and the false one differ by what
# they are ABOUT, not by their vocabulary.
flatten() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }
vouches_for_provenance() {
    local n
    n=$(flatten "$1" | grep -cF -e 'recorded its own result' \
                               -e 'cannot claim a run that did not happen' 2>/dev/null || true)
    printf '%s' "$(printf '%s' "${n:-0}" | tr -d '[:space:]')"
}

# The readout branches.
NOTE_FRESH=$(drive_ledger "$LEDGER_REGION" broader_verification_note)
assert_contains "4.7 with a matching tree the note says UNCHANGED" "is UNCHANGED since that run" "$NOTE_FRESH"
# NAMED FOR WHAT ITS NEEDLE TESTS, which is half of what this leg used to claim.
# It read "the note DISCLAIMS the run rather than vouching for it" over this
# same needle — and the pre-fix text disclaimed AND vouched in one sentence
# ("...does not vouch for it — the command recorded its own result..."), so the
# needle was green on the UNFIXED readout while the name told an auditor reading
# the run log that the disclaimer had been verified. A green line claiming more
# than its needle can see is this file's own subject, one tier down. The
# "rather than vouching" half is now a leg of its own, with its own needle: 4.8b.
assert_contains "4.8 the note says THIS GATE DID NOT RUN the recorded command" \
    "this gate did not run it" "$NOTE_FRESH"
assert_eq "4.8b ...and vouches for NO writer — the R1-F1 claim is absent from the OUTPUT" \
    "0" "$(vouches_for_provenance "$NOTE_FRESH")"
printf 'moved\n' > "$G/tracked.txt"
assert_contains "4.9 once the tree moves the note says so" \
    "has MOVED since that run" "$(drive_ledger "$LEDGER_REGION" broader_verification_note)"
( cd "$G" && git checkout -q -- tracked.txt )
rm -f "$G/.claude/.qa-tracking/verification-ledger"
NOTE_EMPTY=$(drive_ledger "$LEDGER_REGION" broader_verification_note)
assert_contains "4.10 with no record at all the note says NONE RECORDED (never a silent blank)" \
    "NONE RECORDED" "$NOTE_EMPTY"
assert_eq "4.10b ...and the empty-ledger branch makes no provenance claim either" \
    "0" "$(vouches_for_provenance "$NOTE_EMPTY")"

# ---------------------------------------------------------------------------
# 4.11-4.20 — R3-F1: a host with NEITHER shasum NOR sha256sum.
#
# `_vl_sha256` degrades to a CONSTANT there, and a constant equals itself. Until
# tree_fingerprint refused it, every fingerprint on such a host was that same
# value: record_verification wrote it, the readout compared it against itself,
# and the gate stated "The working tree is UNCHANGED since that run ... so it
# does describe these changes" over a tree rewritten end to end. Not a missing
# warning — an affirmative, wrong sentence from the one function whose job is
# telling an operator whether a recorded result still applies.
#
# THE HOST IS BUILT, NOT SIMULATED: a directory of symlinks to every executable
# on the current PATH, minus the two names the region probes for. Stubbing
# `_vl_sha256` instead would test a copy of the mechanism, and the finding is
# precisely that a REAL host configuration reaches a false statement.
#
# THE OMISSION LIST IS EXACTLY THOSE TWO NAMES, not "every sha-ish binary". If a
# third backend is ever added to `_vl_sha256`, this PATH will still carry it,
# 4.13 will find a working hash instead of the refusal and go RED — which is the
# direction a test made stale by a code change has to fail in. Everything else
# is kept ON PURPOSE: a farm missing `tail`, for one, sends
# broader_verification_note down its "last line is unreadable" branch, and the
# probe then measures nothing while looking like it measured something. That
# confound is real (it cost a review round), and 4.12 is what stops it being
# silent.
# ---------------------------------------------------------------------------
# build_path_farm <dir> [name-to-omit...]
#
# ONE BUILDER, TWO FARMS. Section 4 now constructs two degraded hosts — one
# without either hash tool (4.11-4.20) and one without `cut` (4.32-4.34) — and
# a second hand-rolled copy of this loop is a second place for the ARG_MAX and
# first-wins reasoning below to be got wrong independently.
build_path_farm() {
    local dest="$1"; shift
    mkdir -p "$dest"
    local d n
    # `local IFS` restores on return, so the caller's field splitting is not
    # disturbed by a helper.
    local IFS=:
    for d in $PATH; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        # One `ln` per PATH DIRECTORY, not per file. Measured on this machine:
        # 27 PATH entries resolving to ~1750 names, 0.16s batched against 2.62s
        # with a fork per file — seconds of L1 wall clock for nothing. No `-f`,
        # so `ln` refuses a name already present and PATH's own first-wins
        # precedence survives. `--` because a filename may begin with a dash. A
        # handful of those names are DIRECTORIES rather than executables; they
        # are harmless here, because a PATH search skips anything that is not a
        # regular executable file (measured, not assumed).
        ln -s -- "$d"/* "$dest"/ 2>/dev/null || true
    done
    # "$@" does not field-split, so the still-local IFS=: is harmless here.
    for n in "$@"; do rm -f "$dest/$n"; done
}

NOHASH_BIN="$WORK/nohash-bin"
build_path_farm "$NOHASH_BIN" shasum sha256sum

# A SUBSHELL IS ENOUGH HERE, and that was checked rather than assumed: bash
# discards its command hash table when PATH is assigned, so `command -v shasum`
# below cannot resolve through an entry cached by this file's own earlier
# `shasum` calls (4M.1, 4N.0). Measured under the same bash that runs L1.
have_under() { ( PATH="$1"; command -v "$2" >/dev/null 2>&1 && echo yes || echo no ); }
have_under_nohash() { have_under "$NOHASH_BIN" "$1"; }

# drive_ledger with ONE difference, the PATH. A separate function rather than a
# parameter on drive_ledger, so nothing above this line changes behaviour.
drive_ledger_nohash() {
    # drive_ledger_nohash <ledger-region> <fn> [args...]
    local reg="$1"; shift
    (
        set -u
        PATH="$NOHASH_BIN"
        PROJECT_DIR="$G"; QA_TRACKING_DIR="$G/.claude/.qa-tracking"; mkdir -p "$QA_TRACKING_DIR"
        # shellcheck disable=SC1090
        . "$DENYLIST_LIB"
        # shellcheck disable=SC1090
        . "$reg"
        "$@"
    )
}

assert_eq "4.11 non-vacuity: the constructed host has NEITHER shasum NOR sha256sum" \
    "no/no" "$(have_under_nohash shasum)/$(have_under_nohash sha256sum)"
NOHASH_MISSING=""
for t in git awk cut sort tail date tr cat mkdir; do
    [ "$(have_under_nohash "$t")" = "yes" ] || NOHASH_MISSING="$NOHASH_MISSING $t"
done
assert_eq "4.12 non-vacuity: ...and still carries every other tool the region needs (no confound)" \
    "" "$NOHASH_MISSING"

rm -rf "$G/.claude"
( cd "$G" && git checkout -q -- tracked.txt )
FP_NOHASH=$(drive_ledger_nohash "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.13 the SHIPPED tree_fingerprint refuses the degraded digest and returns no-hash" \
    "no-hash" "$FP_NOHASH"
# THE TRUNCATION TRAP, pinned from this side too: `cut -c1-16` reshapes the
# 18-character sentinel into `sha256-unavailab`, so a refusal placed AFTER the
# cut — or any reader comparing an emitted fingerprint against the full literal
# — would never fire and would look exactly like a refusal that never had to.
# 4P.4 measures that the unguarded copy emits precisely that truncation.
assert_eq "4.14 ...and NOT the truncated sentinel that a post-cut guard would have to match" \
    "no" "$([ "$FP_NOHASH" = "sha256-unavailab" ] && echo yes || echo no)"

drive_ledger_nohash "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
# Bracket the rewrite with two NORMAL-PATH fingerprints rather than comparing
# against FP0 captured further up: the difference then has exactly one cause,
# the rewrite, and the leg cannot pass because something else moved in between.
FP_BEFORE_REWRITE=$(drive_ledger "$LEDGER_REGION" tree_fingerprint)
printf 'ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$G/tracked.txt"
assert_eq "4.15 non-vacuity: that rewrite really did move the tree (same sandbox, hash tools present)" \
    "yes" "$([ "$(drive_ledger "$LEDGER_REGION" tree_fingerprint)" != "$FP_BEFORE_REWRITE" ] && echo yes || echo no)"
NOTE_NOHASH=$(drive_ledger_nohash "$LEDGER_REGION" broader_verification_note)
assert_contains "4.16 over that rewritten tree the readout says the comparison CANNOT BE DETERMINED" \
    "CANNOT BE DETERMINED" "$NOTE_NOHASH"
assert_absent "4.17 ...and never states the tree is UNCHANGED (the R3-F1 false match)" \
    "is UNCHANGED since that run" "$NOTE_NOHASH"
assert_contains "4.18 ...and names the reason it cannot tell, rather than leaving it bare" \
    "neither shasum nor sha256sum" "$NOTE_NOHASH"

# THE MIXED CASE — recorded on the degraded host, READ on a normal one. The
# ledger still holds `no-hash` while `now` is a perfectly good fingerprint, so
# the equality test would say MOVED: not a false claim of currency, but still an
# assertion about a tree nobody measured. It is also the configuration that
# decides the WORDING: a sentence blaming "this host" for having no sha256 tool
# would be false right here, which is why the shipped one says "at least one of
# the two fingerprints".
NOTE_MIXED=$(drive_ledger "$LEDGER_REGION" broader_verification_note)
assert_contains "4.19 a record made on the degraded host, read on a normal one, still says CANNOT BE DETERMINED" \
    "CANNOT BE DETERMINED" "$NOTE_MIXED"
assert_absent "4.20 ...and does not assert MOVED either — nobody measured that" \
    "has MOVED since that run" "$NOTE_MIXED"
( cd "$G" && git checkout -q -- tracked.txt )
rm -rf "$G/.claude"

# ---------------------------------------------------------------------------
# 4.21-4.34 — THE OTHER THREE WAYS IN, and the reason the guard they share is
# ONE INVARIANT rather than a third, fourth and fifth point-patch.
#
# 4.11-4.20 above pin ONE route to a false statement of currency: the hash tool
# is missing, so an input degrades to a CONSTANT, and a constant equals itself.
# Three more routes reach the identical sentence, and each was found in the
# round that fixed the previous one:
#
#   R4-F1  `git diff HEAD` FAILS on a completely normal host — a .gitattributes
#          textconv driver that is configured but not installed is enough — and
#          the old `|| true` turned that into the sha256 of the empty string.
#          The fingerprint then went blind to every TRACKED modification while
#          HEAD still resolved, so input 3 could not compensate.
#   (new)  NOTHING COMMITTED but something STAGED: `ls-files --others` excludes
#          a staged path and `diff HEAD` cannot run, so all three inputs were
#          constants and rewriting the staged file moved nothing. The block this
#          change set rewrote said of that configuration that "EVERY file is
#          untracked", which is true only while the index is empty.
#   R4-F3  No `cut` on PATH: the return value is the EMPTY STRING, the ledger
#          records a blank tree column, and two blanks compare equal.
#
# They are asserted here as three sandboxes and ONE guard: every one of them is
# refused by the single `unusable` branch in tree_fingerprint, and the 4P META
# below mutates that ONE branch and watches all three go red together. That is
# the difference this round is about — a guard per remembered degradation cannot
# refuse the degradation nobody has met yet, and this region has now met three
# it had not.
#
# drive_in is a THIRD driver rather than a parameter on drive_ledger, so nothing
# above this line changes behaviour. It runs the region under `set -e` as well
# as `set -u` — the shipped script sets `-e` at line 25, the region's FAIL-OPEN
# contract is stated in those terms, and the guards this round added exist partly
# to keep a missing tool from aborting the hook rather than degrading it. A
# driver that dropped `-e` could not observe that.
# ---------------------------------------------------------------------------
drive_in() {
    # drive_in <project-dir> <bindir-or-empty> <region> <fn> [args...]
    local g="$1" bin="$2" reg="$3"; shift 3
    (
        set -eu
        [ -z "$bin" ] || PATH="$bin"
        PROJECT_DIR="$g"; QA_TRACKING_DIR="$g/.claude/.qa-tracking"; mkdir -p "$QA_TRACKING_DIR"
        # shellcheck disable=SC1090
        . "$DENYLIST_LIB"
        # shellcheck disable=SC1090
        . "$reg"
        "$@"
    )
}

# --- R4-F1's route, and why this sandbox no longer reaches a refusal --------
#
# THE SANDBOX IS UNCHANGED AND ITS MEANING IS INVERTED, which is worth stating
# because the legs below used to assert the opposite. A `.gitattributes` textconv
# driver naming a binary that cannot exist made `git diff HEAD` exit 128 having
# written nothing; round 5 turned that into a refusal, correctly, since a
# fingerprint over a failed diff is blind. tree_fingerprint now runs the diff
# `--no-ext-diff --no-textconv`, so git never invokes the driver at all and this
# host is MEASURED instead of being told "cannot tell". The refusal is still
# pinned — by 4.38-4.42, over a diff that fails for a reason no flag can remove.
#
# THE DRIVER IS A PATH THAT CANNOT EXIST, not `pdftotext`. The finding was
# measured with the textconv example git's own documentation gives, which fails
# only because poppler is not installed — on a machine where it IS installed the
# fixture would quietly stop reproducing and go green for the wrong reason.
# 4.21/4.22 still assert that the driver really does break a PLAIN diff, so a
# future git that stopped failing there turns them red rather than leaving the
# section vacuous, and 4.23b is the discriminator: the invocation the region
# ACTUALLY makes succeeds where the plain one does not.
#
# THE FILENAMES ARE LOAD-BEARING. git walks paths in sorted order and stops at
# the first failure, so `aaa.pdf` (the file with the broken driver) must sort
# BEFORE `zzz_app.js` (the file whose rewrite must not go unnoticed). Measured
# with the order reversed: git streams the earlier hunks and no false match
# occurs — which is why the defect was intermittent in the field rather than
# rare, and why the fixture pins the order.
GBD="$WORK/gitproj-brokendiff"
mkdir -p "$GBD"
( cd "$GBD" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'aaa.pdf diff=pdf\n' > .gitattributes \
    && git config diff.pdf.textconv /nonexistent/no-such-textconv-fkm111 \
    && printf 'PDF ONE\n' > aaa.pdf && printf 'console.log(1);\n' > zzz_app.js \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
printf 'PDF TWO\n' > "$GBD/aaa.pdf"

BD_DIFF_RC=$( (cd "$GBD" && git diff HEAD >/dev/null 2>&1); echo $? )
BD_DIFF_BYTES=$( (cd "$GBD" && git diff HEAD 2>/dev/null | wc -c) | tr -d '[:space:]' )
BD_REV_RC=$( (cd "$GBD" && git rev-parse HEAD >/dev/null 2>&1); echo $? )
assert_eq "4.21 non-vacuity: the configured diff driver really does fail (a PLAIN git diff HEAD exits non-zero)" \
    "yes" "$([ "$BD_DIFF_RC" != "0" ] && echo yes || echo no)"
assert_eq "4.22 non-vacuity: ...having written ZERO bytes, which is what used to blind input 2 entirely" \
    "0" "$BD_DIFF_BYTES"
# THE DISCRIMINATOR, asserted rather than assumed. With HEAD unborn a failing
# diff is harmless because every file is untracked and input 3 carries the tree;
# that is the configuration the KNOWN LIMITS block analysed. Here rev-parse
# SUCCEEDS, so the files are tracked and input 3 cannot see them.
assert_eq "4.23 non-vacuity: HEAD RESOLVES here, so the files are tracked and input 3 cannot compensate" \
    "0" "$BD_REV_RC"
# THE INVOCATION THE REGION ACTUALLY MAKES, measured beside the plain one. Two
# facts in one assertion on purpose: it exits 0 AND it carries bytes. Either
# alone would be satisfiable by the defect this round is about — a producer that
# succeeds while carrying nothing is exactly R5-F2.
BD_FLAG_RC=$( (cd "$GBD" && git diff --no-ext-diff --no-textconv HEAD >/dev/null 2>&1); echo $? )
BD_FLAG_BYTES=$( (cd "$GBD" && git diff --no-ext-diff --no-textconv HEAD 2>/dev/null | wc -c) | tr -d '[:space:]' )
assert_eq "4.23b the FLAGGED diff — the one tree_fingerprint runs — exits 0 AND carries real content on the same host" \
    "0/yes" "$BD_FLAG_RC/$([ "${BD_FLAG_BYTES:-0}" -gt 0 ] && echo yes || echo no)"

FP_BD=$(drive_in "$GBD" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.24 so the shipped tree_fingerprint MEASURES this host (a real 16-hex value), where it used to refuse" \
    "yes" "$(printf '%s' "$FP_BD" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"
drive_in "$GBD" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'console.log("ENTIRELY DIFFERENT, NOTHING IN COMMON");\n' > "$GBD/zzz_app.js"
NOTE_BD=$(drive_in "$GBD" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4.25 over a tree rewritten end to end the readout says MOVED, not that it cannot tell" \
    "has MOVED since that run" "$NOTE_BD"
assert_absent "4.26 ...and never states the tree is UNCHANGED (the R4-F1 false match)" \
    "is UNCHANGED since that run" "$NOTE_BD"

# CONFIGURATION-INDEPENDENCE, WHICH IS THE ACTUAL DESIGN CLAIM. R5-F2's fix is
# not "the fingerprint moves here too"; it is that repository configuration can
# no longer decide what input 2 shows. So: same tree, same files, driver
# configured vs driver unset, and the fingerprint must be the SAME VALUE.
# `git config --unset` rather than deleting `.gitattributes`, because that file
# is TRACKED — removing it would change the diff and the two readings would no
# longer be of one tree.
FP_BD_CFG=$(drive_in "$GBD" "" "$LEDGER_REGION" tree_fingerprint)
( cd "$GBD" && git config --unset diff.pdf.textconv ) >/dev/null 2>&1
FP_BD_NOCFG=$(drive_in "$GBD" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.27 the fingerprint is CONFIGURATION-INDEPENDENT: a broken textconv driver, configured or not, yields one value over one tree" \
    "$FP_BD_CFG" "$FP_BD_NOCFG"
assert_eq "4.27b non-vacuity: ...and that shared value is a real fingerprint, not two refusals compared equal" \
    "yes" "$(printf '%s' "$FP_BD_CFG" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"

# THE SANDBOX IS OTHERWISE HEALTHY, and this leg is what proves 4.24 is about
# the region rather than about a repo that cannot produce a fingerprint at all.
rm -f "$GBD/.gitattributes"
FP_BD_OK1=$(drive_in "$GBD" "" "$LEDGER_REGION" tree_fingerprint)
printf 'console.log("AND DIFFERENT AGAIN");\n' > "$GBD/zzz_app.js"
FP_BD_OK2=$(drive_in "$GBD" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.28 CONTROL: with the driver and the attributes file gone the SAME sandbox yields a real fingerprint that MOVES" \
    "yes" "$([ "$FP_BD_OK1" != "no-hash" ] && [ "$FP_BD_OK1" != "$FP_BD_OK2" ] && echo yes || echo no)"

# --- The unborn-HEAD staged file: the case the KNOWN LIMITS block missed -----
#
# Nothing committed, one file STAGED and never committed. `ls-files --others`
# excludes it because it is in the index; `git diff HEAD` cannot run because
# HEAD is unborn. Before this round all three inputs were therefore constants
# and the fingerprint sat at 9d9c545c09de3fcf across an end-to-end rewrite.
# tree_fingerprint now diffs against the EMPTY TREE when HEAD is unborn, so
# input 2 carries the staged content and the case is measured rather than
# refused — a repo mid-first-commit is ordinary, and answering "cannot tell"
# there would be a worse gate, not a safer one.
GNS="$WORK/gitproj-nocommit-staged"
mkdir -p "$GNS"
( cd "$GNS" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'STAGED ORIGINAL\n' > s.txt && git add s.txt ) >/dev/null 2>&1
NS_REV_RC=$( (cd "$GNS" && git rev-parse HEAD >/dev/null 2>&1); echo $? )
NS_OTHERS=$( (cd "$GNS" && git ls-files --others --exclude-standard) | tr -d '[:space:]' )
NS_INDEX=$( (cd "$GNS" && git ls-files) | tr -d '[:space:]' )
assert_eq "4.29 non-vacuity: HEAD is unborn here (rev-parse fails), the discriminator from 4.23" \
    "yes" "$([ "$NS_REV_RC" != "0" ] && echo yes || echo no)"
assert_eq "4.30 non-vacuity: the staged file is in the INDEX and NOT in the untracked set" \
    "s.txt/" "$NS_INDEX/$NS_OTHERS"

FP_NS1=$(drive_in "$GNS" "" "$LEDGER_REGION" tree_fingerprint)
drive_in "$GNS" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'STAGED ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$GNS/s.txt"
FP_NS2=$(drive_in "$GNS" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.31 with nothing committed the fingerprint is still a real one (16 hex), not a refusal" \
    "yes" "$(printf '%s' "$FP_NS1" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"
assert_eq "4.32 rewriting a STAGED, never-committed file MOVES it (input 2 now diffs the empty tree)" \
    "yes" "$([ "$FP_NS1" != "$FP_NS2" ] && echo yes || echo no)"
NOTE_NS=$(drive_in "$GNS" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4.33 ...so the readout says MOVED, where it used to say UNCHANGED" \
    "has MOVED since that run" "$NOTE_NS"

# --- R4-F3: a host with every tool except `cut` ------------------------------
#
# `cut` is POSIX-mandatory, so this needs a genuinely broken host and the
# readout it produced was visibly garbage rather than plausibly green — which is
# why QA recorded it LOW. It is pinned anyway because it is the case that proves
# the guard validates the RETURNED VALUE and not merely the digest: the digest
# here is a perfectly good sha256 and the fingerprint built from it is the empty
# string. A check placed on the digest alone cannot see that.
NOCUT_BIN="$WORK/nocut-bin"
build_path_farm "$NOCUT_BIN" cut
NOCUT_MISSING=""
for t in git awk sort tail date tr cat mkdir; do
    [ "$(have_under "$NOCUT_BIN" "$t")" = "yes" ] || NOCUT_MISSING="$NOCUT_MISSING $t"
done
assert_eq "4.34 non-vacuity: the no-cut host lacks cut but has BOTH hash tools and every other tool" \
    "no/yes/yes/" "$(have_under "$NOCUT_BIN" cut)/$(have_under "$NOCUT_BIN" shasum)/$(have_under "$NOCUT_BIN" sha256sum)/$NOCUT_MISSING"

rm -rf "$G/.claude"
( cd "$G" && git checkout -q -- tracked.txt )
FP_NOCUT=$(drive_in "$G" "$NOCUT_BIN" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.35 with no cut the shipped tree_fingerprint returns no-hash, NOT the empty string" \
    "no-hash" "$FP_NOCUT"
drive_in "$G" "$NOCUT_BIN" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$G/tracked.txt"
NOTE_NOCUT=$(drive_in "$G" "$NOCUT_BIN" "$LEDGER_REGION" broader_verification_note)
# NON-VACUITY BEFORE THE ABSENCE ASSERTION, and this leg caught a live defect
# rather than guarding a hypothetical one. `broader_verification_note` parses the
# ledger line with five `cut` calls; under the `set -e` the shipped script sets,
# the first of them aborted the function on this host and it emitted NOTHING —
# so 4.37 passed over an empty string while the operator saw no readout at all.
# The refusal at 4.35 was correct and invisible. An `assert_absent` with no
# non-vacuity leg beside it is a green line that means nothing.
assert_eq "4.36a non-vacuity: the readout is NON-EMPTY on this host (it did not abort under set -e)" \
    "yes" "$([ -n "$NOTE_NOCUT" ] && echo yes || echo no)"
assert_contains "4.36 ...and the readout says CANNOT BE DETERMINED over the rewritten tree" \
    "CANNOT BE DETERMINED" "$NOTE_NOCUT"
assert_absent "4.37 ...never 'is UNCHANGED since that run (tree )' with an empty tree field" \
    "is UNCHANGED since that run" "$NOTE_NOCUT"
( cd "$G" && git checkout -q -- tracked.txt )
rm -rf "$G/.claude"

# ---------------------------------------------------------------------------
# 4.38-4.42 — A DIFF THAT GENUINELY FAILS: the damaged object store.
#
# THIS BLOCK EXISTS BECAUSE THE FIX FOR R5-F2 MOVED THE OLD ONE. Until this round
# the "failed diff is refused" half of the invariant was pinned on the broken-
# textconv sandbox above. `--no-textconv` makes git ignore that driver, so that
# host stopped failing — an improvement, and it would have left the refusal
# UNPINNED had the leg simply been deleted. A diff can still fail, for reasons no
# flag removes, and this is one of them.
#
# THE BASE BLOB IS DELETED FROM THE OBJECT STORE and the file it belongs to is
# then modified, so producing the diff requires reading an object that is gone. A
# truncated clone, an interrupted fetch or a bad disk reach the same place.
#
# UID-INDEPENDENT ON PURPOSE. The obvious alternative — a tracked file at mode
# 000 — reproduces identically (measured, rc=128 both with and without the
# flags), but it stops reproducing for root, so a container job running as root
# would turn this leg red for a reason that has nothing to do with the guard.
# Nothing here depends on who is running it.
#
# THE REST OF GIT IS HEALTHY, asserted at 4.38, which is what makes this a test
# of the DIFF rather than of a repository too broken to fingerprint at all:
# rev-parse succeeds, `git status` reports the file modified, and ls-files
# --others works. git itself says the tree moved; only the diff cannot say how.
# ---------------------------------------------------------------------------
GDO="$WORK/gitproj-damaged-objects"
mkdir -p "$GDO"
( cd "$GDO" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'ONE\n' > aaa.txt && printf 'console.log(1);\n' > zzz_app.js \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
DO_BLOB=$( (cd "$GDO" && git rev-parse HEAD:aaa.txt) 2>/dev/null )
rm -f "$GDO/.git/objects/${DO_BLOB%"${DO_BLOB#??}"}/${DO_BLOB#??}"
# The damaged blob must be NEEDED: an unmodified file is resolved from the index
# stat cache and the diff never reads the object. Measured — without this write
# the flagged diff exits 0 and the whole block goes vacuous.
printf 'TWO\n' > "$GDO/aaa.txt"

DO_REV_RC=$( (cd "$GDO" && git rev-parse HEAD >/dev/null 2>&1); echo $? )
DO_STATUS=$( (cd "$GDO" && git status --porcelain 2>/dev/null) | tr -d '[:space:]' )
DO_OTHERS_RC=$( (cd "$GDO" && git ls-files --others --exclude-standard >/dev/null 2>&1); echo $? )
assert_eq "4.38 non-vacuity: the rest of git is healthy here — HEAD resolves, status sees the change, the untracked walk works" \
    "0/Maaa.txt/0" "$DO_REV_RC/$DO_STATUS/$DO_OTHERS_RC"
DO_DIFF_RC=$( (cd "$GDO" && git diff --no-ext-diff --no-textconv HEAD >/dev/null 2>&1); echo $? )
DO_DIFF_BYTES=$( (cd "$GDO" && git diff --no-ext-diff --no-textconv HEAD 2>/dev/null | wc -c) | tr -d '[:space:]' )
assert_eq "4.39 non-vacuity: the FLAGGED diff still fails here (rc non-zero, zero bytes) — no flag can remove this cause" \
    "yes/0" "$([ "$DO_DIFF_RC" != "0" ] && echo yes || echo no)/$DO_DIFF_BYTES"

FP_DO=$(drive_in "$GDO" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.40 the shipped tree_fingerprint refuses a FAILED diff and returns no-hash" \
    "no-hash" "$FP_DO"
drive_in "$GDO" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'console.log("ENTIRELY DIFFERENT, NOTHING IN COMMON");\n' > "$GDO/zzz_app.js"
NOTE_DO=$(drive_in "$GDO" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4.41 over a tree rewritten end to end the readout says CANNOT BE DETERMINED" \
    "CANNOT BE DETERMINED" "$NOTE_DO"
assert_absent "4.41b ...and never states the tree is UNCHANGED" \
    "is UNCHANGED since that run" "$NOTE_DO"
assert_contains "4.42 ...and names the failing diff as a cause it has met, not just a missing hash tool" \
    "exited non-zero" "$NOTE_DO"
# THE CAUSE LIST HAS TO TRACK THE MECHANISM, and this is the same defect class
# the whole change set is about, one layer down. The readout used to attribute a
# non-zero diff to "a configured but missing textconv or external diff driver".
# The flags made that FALSE — those hosts now exit 0 — so the sentence was
# rewritten to name the causes that still reach it.
#
# WHAT THIS LEG CATCHES, MEASURED RATHER THAN ASSERTED IN PROSE: restoring the
# old sentence while leaving the code correct turns THIS ASSERTION red and
# nothing else — driven against a copy carrying exactly that edit, 1 failure out
# of 194. Reverting the flags while leaving the sentence is the other direction
# and is caught elsewhere, by 4.45-4.47. The two halves are pinned separately
# because they can be reverted separately.
assert_absent "4.42b ...and no longer blames a textconv or external driver, which the flags made false" \
    "textconv" "$NOTE_DO"
rm -rf "$GDO/.claude"
( cd "$GDO" && git checkout -q -- zzz_app.js ) >/dev/null 2>&1 || printf 'console.log(1);\n' > "$GDO/zzz_app.js"

# ---------------------------------------------------------------------------
# 4.43-4.47 — R5-F2: a textconv driver that is INSTALLED, WORKING and LOSSY.
#
# A DEGRADATION NO REFUSAL CAN REACH — the first FOUND of a family, not "THE
# ONE", which is what this banner used to say: a lossy-but-working clean
# filter shares the whole signature and the flags do not touch it (R8-F1;
# 4.59-4.63 and 4T pin it, one input over). Every instance before this one had
# a producer that FAILED or a hash that came back MALFORMED. Here the driver
# runs, exits 0, and prints text that did not change when the file's bytes
# did: `git status` reports ` M data.bin`, `git diff` exits 0 having written
# ZERO bytes, and the sha256 of the empty string is 64 perfectly good hex
# characters. Nothing is wrong for a guard to detect. Measured before the fix:
# f801c30b833bb924 either side of an end-to-end rewrite, with the readout
# stating UNCHANGED.
#
# THE DRIVER IS BUILT AND EXECUTED, NEVER STUBBED OUT OF THE PATH. A fixture
# whose driver is missing tests the PREVIOUS finding (R4-F1); the whole point
# here is that everything succeeds. 4.43 asserts the script really runs and
# really is lossy, so a fixture that quietly stopped being either goes red
# instead of vacuous.
#
# IT STANDS IN FOR EVERY REAL LOSSY CONVERTER: pdftotext over a PDF whose text is
# unchanged but whose bytes are not, `strings`, `exiftool`, `unzip -p`.
# ---------------------------------------------------------------------------
LOSSY_TEXTCONV="$WORK/lossy-textconv.sh"
# SC2016: `$1` is the GENERATED script's positional parameter, written out
# verbatim. Expanding it here would bake this test's own `$1` into the driver.
# shellcheck disable=SC2016
{
    printf '#!/bin/sh\n'
    printf '[ -r "$1" ] || exit 1\n'
    printf 'printf %s\n' "'EXTRACTED TEXT (constant)\\n'"
    printf 'exit 0\n'
} > "$LOSSY_TEXTCONV"
chmod 0755 "$LOSSY_TEXTCONV"

GLT="$WORK/gitproj-lossy-textconv"
mkdir -p "$GLT"
( cd "$GLT" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'data.bin diff=lossy\n' > .gitattributes \
    && git config diff.lossy.textconv "$LOSSY_TEXTCONV" \
    && printf 'BINARY ORIGINAL PAYLOAD\n' > data.bin \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
printf 'BINARY ENTIRELY DIFFERENT PAYLOAD, NOTHING IN COMMON\n' > "$GLT/data.bin"

LT_DRIVER_OUT=$("$LOSSY_TEXTCONV" "$GLT/data.bin" 2>/dev/null); LT_DRIVER_RC=$?
LT_PLAIN_RC=$( (cd "$GLT" && git diff HEAD >/dev/null 2>&1); echo $? )
LT_PLAIN_BYTES=$( (cd "$GLT" && git diff HEAD 2>/dev/null | wc -c) | tr -d '[:space:]' )
LT_STATUS=$( (cd "$GLT" && git status --porcelain 2>/dev/null) | tr -d '[:space:]' )
assert_eq "4.43 non-vacuity: the driver is INSTALLED and WORKING (exits 0, prints text) — this is not a missing-binary fixture" \
    "0/EXTRACTED TEXT (constant)" "$LT_DRIVER_RC/$LT_DRIVER_OUT"
assert_eq "4.44 non-vacuity: THE SHAPE OF THE DEFECT — git says the file is modified while an UNFLAGGED diff exits 0 with zero bytes" \
    "Mdata.bin/0/0" "$LT_STATUS/$LT_PLAIN_RC/$LT_PLAIN_BYTES"

FP_LT1=$(drive_in "$GLT" "" "$LEDGER_REGION" tree_fingerprint)
drive_in "$GLT" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'BINARY REWRITTEN AGAIN, STILL NOTHING IN COMMON WITH EITHER\n' > "$GLT/data.bin"
FP_LT2=$(drive_in "$GLT" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.45 the shipped fingerprint is a real 16-hex value here and MOVES when the file is rewritten" \
    "yes" "$(printf '%s' "$FP_LT1" | grep -qE '^[0-9a-f]{16}$' && [ "$FP_LT1" != "$FP_LT2" ] && echo yes || echo no)"
NOTE_LT=$(drive_in "$GLT" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4.46 ...so the readout says MOVED, where before this round it said UNCHANGED" \
    "has MOVED since that run" "$NOTE_LT"
assert_absent "4.46b ...and never states the tree is UNCHANGED (the R5-F2 false match)" \
    "is UNCHANGED since that run" "$NOTE_LT"
# THE DESIGN CLAIM, not just the symptom: a WORKING driver cannot change the
# fingerprint either. Same tree, driver configured vs unset, one value.
FP_LT_CFG=$(drive_in "$GLT" "" "$LEDGER_REGION" tree_fingerprint)
( cd "$GLT" && git config --unset diff.lossy.textconv ) >/dev/null 2>&1
FP_LT_NOCFG=$(drive_in "$GLT" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.47 CONFIGURATION-INDEPENDENT: a working-but-lossy driver, configured or not, yields one value over one tree" \
    "$FP_LT_CFG" "$FP_LT_NOCFG"
( cd "$GLT" && git config diff.lossy.textconv "$LOSSY_TEXTCONV" ) >/dev/null 2>&1
rm -rf "$GLT/.claude"

# ---------------------------------------------------------------------------
# 4.48-4.53 — R5-F1: one unreadable path in the UNTRACKED set.
#
# THE PLACE THE INVARIANT WAS DELIBERATELY EXEMPTED IS WHERE THE NEXT INSTANCE
# LIVED. Round 5 kept exactly one `|| true`, over the batch `git hash-object
# --stdin-paths` call, on the reasoning that the sorted NAME LIST still reaches
# the hash so the loss is "name-sensitive rather than blind". The mechanism half
# was true. The consequence — that the gate then AFFIRMATIVELY states currency
# over a tree rewritten end to end — was not: measured at 63e4abbe578dae06
# before and after, on a fully normal host with every tool present.
#
# ORDER IS LOAD-BEARING, R4-F1'S SIGNATURE EXACTLY. `--stdin-paths` streams and
# aborts at the FIRST unreadable path, so `aaa-dangling` (sorting before `u.txt`)
# freezes the fingerprint while `zzz-dangling` lets the earlier hash stream and
# nothing looks wrong. 4.53 measures that the fix removes the order dependence
# rather than getting lucky on one ordering.
#
# TWO KINDS, because the previous KNOWN LIMITS bullet asked only one: a dangling
# SYMLINK and a mode-000 FILE both sit IN the untracked set and both make
# hash-object exit 128 (measured). A mode-000 DIRECTORY does not — ls-files
# --others warns and exits 0 and its contents are simply absent — which is the
# case that bullet reasoned about before concluding there was no failure to
# detect.
#
# THE MODE-000 FILE LEG IS SKIPPED FOR ROOT, and that is not a hole: the dangling
# symlink is unreadable for every uid, so the guard is pinned either way, and
# 4.50 records which arm ran rather than passing silently.
# ---------------------------------------------------------------------------
GUP="$WORK/gitproj-unreadable-untracked"
mkdir -p "$GUP"
( cd "$GUP" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'TRACKED\n' > tracked.txt && git add -A && git commit -qm init ) >/dev/null 2>&1
printf 'UNTRACKED ORIGINAL\n' > "$GUP/u.txt"
ln -s /nonexistent/no-such-target-fkm111 "$GUP/aaa-dangling"

UP_SET=$( (cd "$GUP" && git ls-files --others --exclude-standard 2>/dev/null) | tr '\n' ' ' | sed 's/ $//' )
UP_BATCH_RC=$( (cd "$GUP" && git ls-files --others --exclude-standard | git hash-object --stdin-paths >/dev/null 2>&1); echo $? )
UP_BATCH_BYTES=$( (cd "$GUP" && git ls-files --others --exclude-standard | git hash-object --stdin-paths 2>/dev/null | wc -c) | tr -d '[:space:]' )
assert_eq "4.48 non-vacuity: the dangling symlink IS in the untracked set and sorts FIRST (the freezing order)" \
    "aaa-dangling u.txt" "$UP_SET"
assert_eq "4.49 non-vacuity: the batch hash-object call fails on it and streams ZERO bytes — every content hash is lost" \
    "yes/0" "$([ "$UP_BATCH_RC" != "0" ] && echo yes || echo no)/$UP_BATCH_BYTES"

FP_UP1=$(drive_in "$GUP" "" "$LEDGER_REGION" tree_fingerprint)
drive_in "$GUP" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'UNTRACKED ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$GUP/u.txt"
FP_UP2=$(drive_in "$GUP" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.50 rewriting a DIFFERENT untracked file MOVES the fingerprint despite the unreadable path (per-path fallback)" \
    "yes" "$(printf '%s' "$FP_UP1" | grep -qE '^[0-9a-f]{16}$' && [ "$FP_UP1" != "$FP_UP2" ] && echo yes || echo no)"
NOTE_UP=$(drive_in "$GUP" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4.51 ...so the readout says MOVED, where before this round it said UNCHANGED" \
    "has MOVED since that run" "$NOTE_UP"
assert_absent "4.51b ...and never states the tree is UNCHANGED (the R5-F1 false match)" \
    "is UNCHANGED since that run" "$NOTE_UP"
# READABILITY ITSELF IS CARRIED. An unreadable path contributes its name and the
# fact that it could not be read, so crossing that boundary moves the
# fingerprint. This is what distinguishes the fallback from silently dropping
# the path.
FP_UP_BROKEN=$(drive_in "$GUP" "" "$LEDGER_REGION" tree_fingerprint)
rm -f "$GUP/aaa-dangling"
ln -s tracked.txt "$GUP/aaa-dangling"
FP_UP_FIXED=$(drive_in "$GUP" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.52 a path crossing the unreadable/readable boundary MOVES it (the marker is not a silent drop)" \
    "yes" "$([ "$FP_UP_BROKEN" != "$FP_UP_FIXED" ] && echo yes || echo no)"
# THE OTHER ORDERING, which used to be the one that accidentally worked. It has
# to keep working: a fix that only handled the freezing order would leave the
# fingerprint's value depending on a filename.
rm -f "$GUP/aaa-dangling"
ln -s /nonexistent/no-such-target-fkm111 "$GUP/zzz-dangling"
printf 'UNTRACKED ORIGINAL AGAIN\n' > "$GUP/u.txt"
FP_UP_Z1=$(drive_in "$GUP" "" "$LEDGER_REGION" tree_fingerprint)
printf 'UNTRACKED THIRD CONTENT, NOTHING IN COMMON WITH EITHER\n' > "$GUP/u.txt"
FP_UP_Z2=$(drive_in "$GUP" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.53 with the broken path sorting LAST it still moves — the fix is not order-dependent either" \
    "yes" "$([ "$FP_UP_Z1" != "$FP_UP_Z2" ] && echo yes || echo no)"
rm -f "$GUP/zzz-dangling"
# THE WIDER CLASS: a mode-000 FILE, not a symlink. Skipped for root, where
# chmod 000 does not make a file unreadable and the fixture would be vacuous.
printf 'LOCKED CONTENT\n' > "$GUP/aaa-locked.bin"
chmod 000 "$GUP/aaa-locked.bin" 2>/dev/null || true
UP_LOCKED_RC=$( (cd "$GUP" && git hash-object -- aaa-locked.bin >/dev/null 2>&1); echo $? )
if [ "$UP_LOCKED_RC" != "0" ]; then
    printf 'UNTRACKED ORIGINAL ONCE MORE\n' > "$GUP/u.txt"
    FP_UP_L1=$(drive_in "$GUP" "" "$LEDGER_REGION" tree_fingerprint)
    printf 'UNTRACKED FOURTH CONTENT, NOTHING IN COMMON\n' > "$GUP/u.txt"
    FP_UP_L2=$(drive_in "$GUP" "" "$LEDGER_REGION" tree_fingerprint)
    assert_eq "4.53b the class is wider than symlinks: a mode-000 untracked FILE behaves identically" \
        "yes" "$([ "$FP_UP_L1" != "$FP_UP_L2" ] && echo yes || echo no)"
else
    printf '  SKIP: 4.53b mode-000 files are readable for this uid (root?) — the symlink arm above pins the guard\n'
fi
chmod 0644 "$GUP/aaa-locked.bin" 2>/dev/null || true
rm -f "$GUP/aaa-locked.bin"
# A mode-000 DIRECTORY is the case the old KNOWN LIMITS bullet reasoned about,
# and it really does behave differently — asserted so the bullet's rewrite is
# pinned to a measurement rather than to a memory.
mkdir -p "$GUP/aaa-lockeddir" && printf 'inner\n' > "$GUP/aaa-lockeddir/inner.txt"
chmod 000 "$GUP/aaa-lockeddir" 2>/dev/null || true
UP_DIR_RC=$( (cd "$GUP" && git ls-files --others --exclude-standard >/dev/null 2>&1); echo $? )
UP_DIR_IN_SET=$( (cd "$GUP" && git ls-files --others --exclude-standard 2>/dev/null) | grep -c 'aaa-lockeddir' | tr -d '[:space:]' )
assert_eq "4.53c non-vacuity for the rewritten bullet: a mode-000 DIRECTORY leaves ls-files at rc=0 and nothing under it in the set" \
    "0/0" "$UP_DIR_RC/$UP_DIR_IN_SET"
chmod 0755 "$GUP/aaa-lockeddir" 2>/dev/null || true
rm -rf "$GUP/aaa-lockeddir" "$GUP/.claude"

# --- R7-F1's route: a C-QUOTED name while the fallback runs -----------------
#
# THE SIXTH INSTANCE, AND THE FIRST THE INVARIANT CANNOT SEE. `ls-files
# --others` emits a path carrying a control character C-QUOTED onto one line —
# a file named a<newline>b arrives as the six bytes `"a\nb"` — and
# `hash-object --stdin-paths` un-quotes that convention on the way in, so the
# BATCH call handles such names correctly. The per-path fallback used to hand
# the same bytes to `git hash-object -- "$p"`, and command-line pathnames are
# NOT un-quoted: git failed on a file it could read perfectly well, the
# fallback emitted `UNREADABLE "a\nb"` — a constant — every producer exited 0,
# every digest was well-formed, and the fingerprint froze across an end-to-end
# rewrite of the readable file. BOTH HALVES OF THE CONFIGURATION ARE
# LOAD-BEARING: the quoted name alone never fails the batch call (no fallback
# runs), and the dangling symlink alone carries no quoted name (round 6's
# fixture, which is how the round that added the fallback measured the batch
# half and missed the argv half). The legs below DRIVE the function and
# compare fingerprints and outputs — never the source text, which quotes the
# old behaviour in order to explain the fix.
GQN="$WORK/gitproj-quoted-name"
mkdir -p "$GQN"
( cd "$GQN" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'TRACKED\n' > tracked.txt && git add -A && git commit -qm init ) >/dev/null 2>&1
QN_FILE="$GQN/$(printf 'a\nb')"
printf 'QUOTED-NAME ORIGINAL\n' > "$QN_FILE"
ln -s /nonexistent/no-such-target-fkm111 "$GQN/dangling"

QN_SET=$( (cd "$GQN" && git ls-files --others --exclude-standard 2>/dev/null) | tr '\n' ' ' | sed 's/ $//' )
QN_BATCH_RC=$( (cd "$GQN" && git ls-files --others --exclude-standard | git hash-object --stdin-paths >/dev/null 2>&1); echo $? )
assert_eq "4.54 non-vacuity: the newline-named file IS C-quoted onto one line, beside the symlink" \
    '"a\nb" dangling' "$QN_SET"
assert_eq "4.55 non-vacuity: the batch call still fails here, so the per-path fallback really runs" \
    "yes" "$([ "$QN_BATCH_RC" != "0" ] && echo yes || echo no)"

FP_QN1=$(drive_in "$GQN" "" "$LEDGER_REGION" tree_fingerprint)
drive_in "$GQN" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'QUOTED-NAME REWRITTEN END TO END, NOTHING IN COMMON\n' > "$QN_FILE"
FP_QN2=$(drive_in "$GQN" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.56 rewriting the READABLE newline-named file MOVES the fingerprint while the fallback is engaged" \
    "yes" "$(printf '%s' "$FP_QN1" | grep -qE '^[0-9a-f]{16}$' && [ "$FP_QN1" != "$FP_QN2" ] && echo yes || echo no)"
NOTE_QN=$(drive_in "$GQN" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4.57 ...so the readout says MOVED, where the argv fallback said UNCHANGED" \
    "has MOVED since that run" "$NOTE_QN"
assert_absent "4.57b ...and never states the tree is UNCHANGED (the R7-F1 false match)" \
    "is UNCHANGED since that run" "$NOTE_QN"

# THE MECHANISM, OBSERVED AT THE FALLBACK'S OWN OUTPUT — by running it, not by
# reading it. The readable quoted name contributes its OBJECT ID, computed
# independently here by handing git the REAL name as argv (the case argv
# handles); the genuinely unreadable path still contributes its marker, which
# is R5-F1's fix still working in the presence of a quoted name.
QN_OID=$( (cd "$GQN" && git hash-object -- "$(printf 'a\nb')" 2>/dev/null) )
assert_eq "4.58a non-vacuity: the expected object id was computed from the REAL name, independent of the fallback" \
    "yes" "$(printf '%s' "$QN_OID" | grep -qE '^[0-9a-f]{40}([0-9a-f]{24})?$' && echo yes || echo no)"
# SC2016: the eval string must expand inside drive_in's sourced subshell,
# where _vl_untracked_paths exists — expanding it here would run nothing.
# shellcheck disable=SC2016
QN_FB=$(drive_in "$GQN" "" "$LEDGER_REGION" eval 'paths=$(_vl_untracked_paths | LC_ALL=C sort); _vl_hash_each "$paths"')
assert_contains "4.58 the fallback carries the newline-named file BY CONTENT (its real object id)" \
    "$QN_OID" "$QN_FB"
assert_contains "4.58b ...and still marks the genuinely unreadable path beside it (R5-F1's marker stays reachable)" \
    "UNREADABLE dangling" "$QN_FB"
assert_absent "4.58c ...and never marks the readable file unreadable" \
    'UNREADABLE "a\nb"' "$QN_FB"
rm -rf "$GQN/.claude"

# --- R8-F1's route: a clean FILTER that is INSTALLED, WORKING and LOSSY -----
#
# THE SEVENTH INSTANCE, AND THE THIRD THE INVARIANT CANNOT SEE. `git
# hash-object` runs the checkin attributes machinery by default — clean
# filters, eol/text, working-tree-encoding — so an UNTRACKED file behind a
# lossy-but-working filter (this one is an nbstripout analogue: strip the
# output cells, keep the code) hashed to ONE object id across an end-to-end
# rewrite, on the batch call and the per-path fallback alike: every producer
# rc=0, every digest 64 hex, fingerprint frozen, readout UNCHANGED. The cure
# is `--no-filters` on both calls, and these legs DRIVE the shipped region
# over that exact configuration.
#
# THE FILTER IS CONFIGURED AND EXECUTED BY GIT, NEVER PROBED DIRECTLY: 4.59
# asserts git's own DEFAULT hash is constant while the raw ids move, so a
# fixture whose filter quietly stopped running or stopped being lossy goes red
# instead of vacuous (the 4.43 discipline, one input over).
#
# THE TRACKED HALF OF THE SAME CONFIGURATION IS A RESIDUAL, NOT A GUARD. `git
# diff` has no filter bypass the way hash-object has `--no-filters`, so a
# tracked file behind this filter still freezes the fingerprint — that is the
# attributes-family bullet in KNOWN LIMITS, and 4.63 MEASURES its signature
# (git itself says ` M` while the flagged diff exits 0 with zero bytes) so the
# bullet is pinned to a live measurement rather than a memory, the same job
# 4.53c does for the mode-000-directory sentence.
GCF="$WORK/gitproj-clean-filter"
mkdir -p "$GCF"
( cd "$GCF" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && git config filter.stripout.clean "sed 's/^OUT:.*/OUT:/'" \
    && printf '*.ipynb filter=stripout\n' > .gitattributes \
    && printf 'CODE: print(1)\nOUT: original run\n' > nb.ipynb \
    && git add -A && git commit -qm init ) >/dev/null 2>&1

printf 'CODE: cell\nOUT: first payload\n' > "$GCF/u.ipynb"
CF_OID_A=$( (cd "$GCF" && git hash-object -- u.ipynb 2>/dev/null) )
CF_OID_A_RAW=$( (cd "$GCF" && git hash-object --no-filters -- u.ipynb 2>/dev/null) )
printf 'CODE: cell\nOUT: second payload, nothing in common\n' > "$GCF/u.ipynb"
CF_OID_B=$( (cd "$GCF" && git hash-object -- u.ipynb 2>/dev/null) )
CF_OID_B_RAW=$( (cd "$GCF" && git hash-object --no-filters -- u.ipynb 2>/dev/null) )
assert_eq "4.59 non-vacuity: the filter is INSTALLED, WORKING and LOSSY — git's DEFAULT hash of the untracked file is ONE constant across an end-to-end rewrite" \
    "yes" "$([ -n "$CF_OID_A" ] && [ "$CF_OID_A" = "$CF_OID_B" ] && echo yes || echo no)"
assert_eq "4.59b non-vacuity: ...while the raw object ids really differ (the worktree bytes DID move)" \
    "yes" "$([ -n "$CF_OID_A_RAW" ] && [ "$CF_OID_A_RAW" != "$CF_OID_B_RAW" ] && echo yes || echo no)"

printf 'CODE: cell\nOUT: first payload\n' > "$GCF/u.ipynb"
FP_CF1=$(drive_in "$GCF" "" "$LEDGER_REGION" tree_fingerprint)
drive_in "$GCF" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'CODE: cell\nOUT: second payload, nothing in common\n' > "$GCF/u.ipynb"
FP_CF2=$(drive_in "$GCF" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4.60 rewriting the untracked FILTERED file MOVES the shipped fingerprint (the flag reaches the batch call)" \
    "yes" "$(printf '%s' "$FP_CF1" | grep -qE '^[0-9a-f]{16}$' && [ "$FP_CF1" != "$FP_CF2" ] && echo yes || echo no)"
NOTE_CF=$(drive_in "$GCF" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4.61 ...so the readout says MOVED, where before this round it said UNCHANGED" \
    "has MOVED since that run" "$NOTE_CF"
assert_absent "4.61b ...and never states the tree is UNCHANGED (the R8-F1 false match)" \
    "is UNCHANGED since that run" "$NOTE_CF"

# THE FALLBACK ROUTE CARRIES THE FLAG TOO: a dangling symlink beside the
# filtered file forces the per-path loop, which must return the RAW id —
# computed independently here, the 4.58a discipline — and still mark the
# symlink. R5-F1's marker and R8-F1's flag, one output.
ln -s /nonexistent/no-such-target-fkm111 "$GCF/dangling"
CF_RAW_NOW=$( (cd "$GCF" && git hash-object --no-filters -- u.ipynb 2>/dev/null) )
assert_eq "4.62a non-vacuity: the raw id was computed independently of the fallback, and the batch call really fails here" \
    "yes/yes" "$(printf '%s' "$CF_RAW_NOW" | grep -qE '^[0-9a-f]{40}([0-9a-f]{24})?$' && echo yes || echo no)/$( (cd "$GCF" && git ls-files --others --exclude-standard | git hash-object --stdin-paths >/dev/null 2>&1) && echo no || echo yes)"
# SC2016: the eval string expands inside drive_in's subshell, as at 4.58.
# shellcheck disable=SC2016
CF_FB=$(drive_in "$GCF" "" "$LEDGER_REGION" eval 'paths=$(_vl_untracked_paths | LC_ALL=C sort); _vl_hash_each "$paths"')
assert_contains "4.62 the per-path fallback carries the filtered file's RAW object id (the flag reaches both routes)" \
    "$CF_RAW_NOW" "$CF_FB"
assert_contains "4.62b ...and still marks the genuinely unreadable path beside it (R5-F1's marker survives the flag)" \
    "UNREADABLE dangling" "$CF_FB"
rm -f "$GCF/dangling"

# THE INPUT-2 RESIDUAL, measured so the KNOWN LIMITS bullet cannot outlive the
# behaviour: rewrite the TRACKED filtered file end to end — git itself calls
# it modified while the flagged diff carries nothing. If a future git grows a
# filter bypass the diff picks up, or stops reporting ` M` here, this leg goes
# red and the bullet is re-derived rather than trusted.
printf 'CODE: print(1)\nOUT: rewritten tracked output, nothing in common\n' > "$GCF/nb.ipynb"
CF_TSTATUS=$( (cd "$GCF" && git status --porcelain 2>/dev/null) | grep -c '^ M nb.ipynb' | tr -d '[:space:]' )
CF_TDIFF_RC=$( (cd "$GCF" && git diff --no-ext-diff --no-textconv HEAD >/dev/null 2>&1); echo $? )
CF_TDIFF_BYTES=$( (cd "$GCF" && git diff --no-ext-diff --no-textconv HEAD 2>/dev/null | wc -c) | tr -d '[:space:]' )
assert_eq "4.63 non-vacuity for the KNOWN LIMITS bullet: the TRACKED half keeps the residual — git status says M while the flagged diff exits 0 with ZERO bytes" \
    "1/0/0" "$CF_TSTATUS/$CF_TDIFF_RC/$CF_TDIFF_BYTES"
( cd "$GCF" && git checkout -q -- nb.ipynb )
rm -rf "$GCF/.claude"

# ---------------------------------------------------------------------------
# 4M. META — drop the self-written filter; the measured regression returns.
# ---------------------------------------------------------------------------
printf '\n--- 4M. META: without the self-written filter, recording moves the tree ---\n'

LEDGER_MUT="$WORK/ledger-mut.sh"
awk '
    /workflow_self_written "\$p"/ { print "        if false; then"; found=1; next }
    { print }
    END { if (!found) exit 7 }
' "$LEDGER_REGION" > "$LEDGER_MUT"
LEDGER_MUT_RC=$?
assert_eq "4M.0 non-vacuity: the self-written call was found and neutralised (awk exit 0, not 7)" \
    "0" "$LEDGER_MUT_RC"
assert_eq "4M.1 non-vacuity: the mutant's bytes differ from the shipped region" \
    "yes" "$([ "$(shasum -a 256 "$LEDGER_MUT" | awk '{print $1}')" != "$(shasum -a 256 "$LEDGER_REGION" | awk '{print $1}')" ] && echo yes || echo no)"
assert_eq "4M.2 the mutant is still valid bash" \
    "0" "$(bash -n "$LEDGER_MUT" 2>/dev/null; echo $?)"
rm -rf "$G/.claude"
FP_MUT_BEFORE=$(drive_ledger "$LEDGER_MUT" tree_fingerprint)
drive_ledger "$LEDGER_MUT" record_verification "make test-ci" 0 >/dev/null
FP_MUT_AFTER=$(drive_ledger "$LEDGER_MUT" tree_fingerprint)
# SPECIFIC MISBEHAVIOUR, naming the check that would fail:
assert_eq "4M.3 SPECIFIC: without the filter the gate's own write moves the tree — check 4.2 FAILS" \
    "yes" "$([ "$FP_MUT_BEFORE" != "$FP_MUT_AFTER" ] && echo yes || echo no)"
rm -rf "$G/.claude"
FP_CTL_BEFORE=$(drive_ledger "$LEDGER_REGION" tree_fingerprint)
drive_ledger "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
assert_eq "4M.4 RESTORE CONTROL: the shipped region, identical sequence, does not move" \
    "$FP_CTL_BEFORE" "$(drive_ledger "$LEDGER_REGION" tree_fingerprint)"

# ---------------------------------------------------------------------------
# 4N. META — put the deleted provenance claim back; 4.8b/4.10b must fail.
#
# THIS IS THE CONTROL R2-F1 FOUND MISSING, and the finding is worth restating
# because it is the reason this block is not optional: before it existed, a
# mutant restoring the pre-fix wording at BOTH sites left the whole file green —
# 4.7, 4.8 and 4.10 all passed on it — so reverting a HIGH-severity fix turned
# nothing red.
#
# A SECOND mutation of the same region, under its own banner rather than folded
# into 4M: different mutation, different misbehaviour, so a red line in the run
# log names which guard broke without a reader having to work it out.
# ---------------------------------------------------------------------------
printf '\n--- 4N. META: restoring the deleted provenance claim must break 4.8b/4.10b ---\n'

LEDGER_PROV="$WORK/ledger-prov.sh"
# ASCII-ONLY ANCHORS, on purpose. Both target lines carry an em dash a few words
# away; a UTF-8 sed pattern is a portability bet (BSD sed under a C locale
# rejects an invalid multibyte sequence outright) and these anchors need none.
# Each anchor occurs exactly ONCE in the region — and 4N.3/4N.4 below prove each
# substitution landed independently, which a single sha256 over the whole file
# cannot do.
sed -e 's|re-run it to check|the command recorded its own result, re-run it to check|' \
    -e 's|so record only what you actually ran|so the record cannot claim a run that did not happen|' \
    "$LEDGER_REGION" > "$LEDGER_PROV"
assert_eq "4N.0 non-vacuity: the mutant's bytes differ from the shipped region" \
    "yes" "$([ "$(shasum -a 256 "$LEDGER_PROV" | awk '{print $1}')" != "$(shasum -a 256 "$LEDGER_REGION" | awk '{print $1}')" ] && echo yes || echo no)"
assert_eq "4N.1 the mutant is still valid bash (so a failure below is the wording, not a parse error)" \
    "0" "$(bash -n "$LEDGER_PROV" 2>/dev/null; echo $?)"

rm -rf "$G/.claude"
drive_ledger "$LEDGER_PROV" record_verification "make test-ci" 0 >/dev/null
PROV_FRESH=$(drive_ledger "$LEDGER_PROV" broader_verification_note)
assert_eq "4N.2 the mutant RAN and produced a readout" \
    "yes" "$([ -n "$PROV_FRESH" ] && echo yes || echo no)"
assert_eq "4N.3 non-vacuity: substitution 1 LANDED — the recorded branch vouches again" \
    "1" "$(contains_count 'recorded its own result' "$(flatten "$PROV_FRESH")" | tr -d '[:space:]')"
rm -f "$G/.claude/.qa-tracking/verification-ledger"
PROV_EMPTY=$(drive_ledger "$LEDGER_PROV" broader_verification_note)
assert_eq "4N.4 non-vacuity: substitution 2 LANDED — the empty branch vouches again" \
    "1" "$(contains_count 'cannot claim a run that did not happen' "$(flatten "$PROV_EMPTY")" | tr -d '[:space:]')"
# SPECIFIC MISBEHAVIOUR, naming the checks that would fail:
assert_eq "4N.5 SPECIFIC: the mutant's recorded branch vouches for a writer — check 4.8b FAILS on it" \
    "yes" "$([ "$(vouches_for_provenance "$PROV_FRESH")" -gt 0 ] && echo yes || echo no)"
assert_eq "4N.6 SPECIFIC: the mutant's empty branch does too — check 4.10b FAILS on it" \
    "yes" "$([ "$(vouches_for_provenance "$PROV_EMPTY")" -gt 0 ] && echo yes || echo no)"

# RESTORE CONTROLS: the shipped region, re-driven through the IDENTICAL sequence
# rather than compared against the notes captured earlier — same reason 4M.4
# re-drives instead of reusing FP0.
#
# Each control is preceded by a non-vacuity leg, because vouches_for_provenance
# returns 0 for the EMPTY STRING: a control that silently drove nothing would
# otherwise pass and mean nothing, which is the exact failure this whole META
# exists to prevent.
rm -rf "$G/.claude"
drive_ledger "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
CTL_FRESH=$(drive_ledger "$LEDGER_REGION" broader_verification_note)
rm -f "$G/.claude/.qa-tracking/verification-ledger"
CTL_EMPTY=$(drive_ledger "$LEDGER_REGION" broader_verification_note)
assert_contains "4N.7a the control readout is the real one (non-vacuous: it names the recorded command)" \
    "make test-ci" "$CTL_FRESH"
assert_eq "4N.7 RESTORE CONTROL: the shipped recorded branch, identical sequence, vouches for nobody" \
    "0" "$(vouches_for_provenance "$CTL_FRESH")"
assert_contains "4N.8a the control's empty branch is the real one (non-vacuous: NONE RECORDED)" \
    "NONE RECORDED" "$CTL_EMPTY"
assert_eq "4N.8 RESTORE CONTROL: ...and the shipped empty branch does not either" \
    "0" "$(vouches_for_provenance "$CTL_EMPTY")"

# ---------------------------------------------------------------------------
# 4P. META — THE INVARIANT, MUTATED. One mutation, four sandboxes, every leg
# that depends on it goes red together.
#
# THIS IS THE POINT OF THE ROUND, SO IT IS WORTH SAYING PLAINLY. The three
# degradations pinned above — no hash tool, a failed diff, no `cut` — used to
# need three guards, and the file was on course for a fourth when the fourth
# degradation turned up. They now share ONE refusal: `if [ -n "$unusable" ]`.
# Mutating that single branch to `if false` is the whole META, and it must break
# 4.13/4.16/4.17/4.19/4.20 (no hash tool), 4.40/4.41/4.41b (failed diff) AND
# 4.35/4.36/4.37 (no cut) at once. If a future point-patch re-introduces a
# per-case early return, this mutation stops being lethal for that case and the
# corresponding SPECIFIC leg below goes green while the guard it names is gone —
# which is the failure this file exists to make impossible.
#
# LEG 2 MOVED SANDBOX THIS ROUND, from the broken-textconv host to the damaged
# object store. That is not a weakening: `--no-textconv` means the textconv host
# no longer produces a failed diff at all, so driving the mutant over it would
# prove nothing about the refusal. The damaged object store still fails for a
# reason no flag removes, and 4.39 is the non-vacuity leg that says so.
#
# A SECOND MUTATION FOLLOWS IT, under the same banner, because the invariant has
# two halves and neutralising one does not exercise the other: an input must
# CARRY CONTENT wherever its producer can read the repository (the empty-tree
# base, 4P.20-4P.23), and the function must REFUSE when a producer fails (the
# branch above). Two mutations of one invariant, not two invariants.
#
# AND TWO MORE METAS FOLLOW, 4Q AND 4R, one per fix this round — the per-path
# fallback and the diff flags. They are SEPARATE banners rather than a third and
# fourth mutation here because neither is a mutation of the refusal: 4Q's defect
# survived the refusal by being exempted from it, and 4R's cannot be refused at
# all.
# ---------------------------------------------------------------------------
printf '\n--- 4P. META: without the single refusal, every degradation reads as a real fingerprint ---\n'

LEDGER_NOREFUSE="$WORK/ledger-norefuse.sh"
# ANCHORED ON THE REFUSAL'S CONDITION, which occurs exactly once in the region
# (asserted at 4P.0b). SC2016 throughout this block: `$unusable` is REGION text
# being matched literally, and expanding it here would search for the empty
# string.
# shellcheck disable=SC2016
awk '
    index($0, "if [ -n \"$unusable\" ]; then") { print "    if false; then"; found=1; next }
    { print }
    END { if (!found) exit 7 }
' "$LEDGER_REGION" > "$LEDGER_NOREFUSE"
LEDGER_NOREFUSE_RC=$?
assert_eq "4P.0 non-vacuity: the single refusal was found and neutralised (awk exit 0, not 7)" \
    "0" "$LEDGER_NOREFUSE_RC"
# shellcheck disable=SC2016
assert_eq "4P.0b non-vacuity: exactly ONE line in the region carries it (one refusal, not three)" \
    "1" "$(grep -cF -- 'if [ -n "$unusable" ]; then' "$LEDGER_REGION" | tr -d '[:space:]')"
assert_eq "4P.1 non-vacuity: the mutant's bytes differ from the shipped region" \
    "yes" "$([ "$(shasum -a 256 "$LEDGER_NOREFUSE" | awk '{print $1}')" != "$(shasum -a 256 "$LEDGER_REGION" | awk '{print $1}')" ] && echo yes || echo no)"
assert_eq "4P.2 the mutant is still valid bash (so a failure below is the refusal, not a parse error)" \
    "0" "$(bash -n "$LEDGER_NOREFUSE" 2>/dev/null; echo $?)"

# --- leg 1 of 3: the host with no hash tool (4.11-4.20) ---------------------
rm -rf "$G/.claude"
( cd "$G" && git checkout -q -- tracked.txt )
MUT_FP_CLEAN=$(drive_ledger_nohash "$LEDGER_NOREFUSE" tree_fingerprint)
assert_eq "4P.3 the mutant RAN and produced a fingerprint" \
    "yes" "$([ -n "$MUT_FP_CLEAN" ] && echo yes || echo no)"
# SPECIFIC MISBEHAVIOUR, naming the checks that would fail:
#
# THE TRUNCATION TRAP, AND WHY IT NOW COSTS NOTHING. The mutant emits
# `sha256-unavailab` — 16 characters, not the 18 of the sentinel — so the
# identity test this round replaced had to sit BEFORE `cut -c1-16` or it could
# never have fired. The shipped guard is a SHAPE test (`_vl_is_hash`), and that
# string is 16 characters of non-hex, so it is refused after the cut as readily
# as before it. This leg is the evidence for both halves of that claim: the
# truncation is real, and the shape test catches it anyway (4.13, 4.35).
assert_eq "4P.4 SPECIFIC: the mutant emits the CUT-TRUNCATED sentinel — check 4.13 FAILS, and an IDENTITY guard on the 18-char literal could never have fired here" \
    "sha256-unavailab" "$MUT_FP_CLEAN"
drive_ledger_nohash "$LEDGER_NOREFUSE" record_verification "make test-ci" 0 >/dev/null
printf 'ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$G/tracked.txt"
assert_eq "4P.5 SPECIFIC: two fingerprints either side of a full rewrite COMPARE EQUAL under the mutant" \
    "$MUT_FP_CLEAN" "$(drive_ledger_nohash "$LEDGER_NOREFUSE" tree_fingerprint)"
MUT_NOTE=$(drive_ledger_nohash "$LEDGER_NOREFUSE" broader_verification_note)
assert_eq "4P.6 SPECIFIC: so the mutant declares the rewritten tree UNCHANGED — check 4.17 FAILS on it" \
    "1" "$(contains_count 'is UNCHANGED since that run' "$MUT_NOTE" | tr -d '[:space:]')"
assert_eq "4P.7 SPECIFIC: ...and never says it cannot tell — check 4.16 FAILS on it" \
    "0" "$(contains_count 'CANNOT BE DETERMINED' "$MUT_NOTE" | tr -d '[:space:]')"
# The mixed case under the mutant: its ledger holds the truncated constant while
# a normal-PATH read produces a real fingerprint, so it asserts MOVED over a tree
# whose recorded fingerprint was never a measurement.
MUT_NOTE_MIXED=$(drive_ledger "$LEDGER_NOREFUSE" broader_verification_note)
assert_eq "4P.7b SPECIFIC: read back on a normal host the mutant asserts MOVED instead — checks 4.19/4.20 FAIL on it" \
    "1" "$(contains_count 'has MOVED since that run' "$MUT_NOTE_MIXED" | tr -d '[:space:]')"

# --- leg 2 of 3: a diff that genuinely fails — the damaged object store (4.40-4.42)
#
# THE SAME MUTATION, A DIFFERENT DEGRADATION, AND NO SECOND GUARD TO REMOVE.
# This is the leg that distinguishes an invariant from three point-patches: had
# the diff been fixed with its own early return, `if false` on the shared branch
# would leave THIS case still refusing and 4P.10 would go green over a fix that
# is gone.
rm -rf "$GDO/.claude"
printf 'console.log(1);\n' > "$GDO/zzz_app.js"
# ASSERTED RATHER THAN ASSUMED, for the reason the old broken-driver version of
# this leg asserted it: if the sandbox had healed between 4.39 and here, 4P.10
# would compare two fingerprints of a WORKING repo, and the only way those could
# still match is if the mutant were broken some other way — a green leg meaning
# nothing.
DO_MUT_DIFF_RC=$( (cd "$GDO" && git diff --no-ext-diff --no-textconv HEAD >/dev/null 2>&1); echo $? )
assert_eq "4P.9b non-vacuity: the diff still fails in this sandbox (the damaged object was not restored by anything above)" \
    "yes" "$([ "$DO_MUT_DIFF_RC" != "0" ] && echo yes || echo no)"
MUT_FP_DO1=$(drive_in "$GDO" "" "$LEDGER_NOREFUSE" tree_fingerprint)
assert_eq "4P.10a non-vacuity: the mutant produced a REAL-LOOKING 16-hex fingerprint over that failed diff" \
    "yes" "$(printf '%s' "$MUT_FP_DO1" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"
drive_in "$GDO" "" "$LEDGER_NOREFUSE" record_verification "make test-ci" 0 >/dev/null
printf 'console.log("REWRITTEN END TO END UNDER THE MUTANT");\n' > "$GDO/zzz_app.js"
assert_eq "4P.10 SPECIFIC: with the refusal gone a FAILED diff reads as UNCHANGED again — check 4.40 FAILS" \
    "$MUT_FP_DO1" "$(drive_in "$GDO" "" "$LEDGER_NOREFUSE" tree_fingerprint)"
MUT_NOTE_DO=$(drive_in "$GDO" "" "$LEDGER_NOREFUSE" broader_verification_note)
assert_eq "4P.11 SPECIFIC: so it declares the rewritten tree UNCHANGED — checks 4.41/4.41b FAIL on it" \
    "1" "$(contains_count 'is UNCHANGED since that run' "$MUT_NOTE_DO" | tr -d '[:space:]')"

# --- leg 3 of 3: the host with no `cut` (4.35-4.37) -------------------------
rm -rf "$G/.claude"
( cd "$G" && git checkout -q -- tracked.txt )
MUT_FP_NOCUT=$(drive_in "$G" "$NOCUT_BIN" "$LEDGER_NOREFUSE" tree_fingerprint)
assert_eq "4P.12 SPECIFIC: with the refusal gone and no cut the fingerprint is the EMPTY STRING — check 4.35 FAILS" \
    "0" "${#MUT_FP_NOCUT}"
drive_in "$G" "$NOCUT_BIN" "$LEDGER_NOREFUSE" record_verification "make test-ci" 0 >/dev/null
printf 'ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$G/tracked.txt"
MUT_NOTE_NOCUT=$(drive_in "$G" "$NOCUT_BIN" "$LEDGER_NOREFUSE" broader_verification_note)
assert_eq "4P.13 SPECIFIC: and two blank tree fields compare equal, so it says UNCHANGED — checks 4.36/4.37 FAIL on it" \
    "1" "$(contains_count 'is UNCHANGED since that run' "$MUT_NOTE_NOCUT" | tr -d '[:space:]')"

# RESTORE CONTROLS: the shipped region, same constructed hosts, same sequences,
# same rewritten trees — re-driven rather than compared against the notes
# captured earlier, for the reason 4M.4 and 4N.7 re-drive.
rm -rf "$G/.claude"
( cd "$G" && git checkout -q -- tracked.txt )
drive_ledger_nohash "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$G/tracked.txt"
CTL_NOHASH=$(drive_ledger_nohash "$LEDGER_REGION" broader_verification_note)
assert_contains "4P.8a the control readout is the real one (non-vacuous: it names the recorded command)" \
    "make test-ci" "$CTL_NOHASH"
assert_contains "4P.8 RESTORE CONTROL: the shipped region, identical sequence, says CANNOT BE DETERMINED" \
    "CANNOT BE DETERMINED" "$CTL_NOHASH"
assert_absent "4P.9 RESTORE CONTROL: ...and never states the tree is UNCHANGED" \
    "is UNCHANGED since that run" "$CTL_NOHASH"
( cd "$G" && git checkout -q -- tracked.txt )
rm -rf "$G/.claude"

rm -rf "$GDO/.claude"
printf 'console.log(1);\n' > "$GDO/zzz_app.js"
drive_in "$GDO" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'console.log("REWRITTEN END TO END UNDER THE SHIPPED REGION");\n' > "$GDO/zzz_app.js"
CTL_DO=$(drive_in "$GDO" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4P.14a the failed-diff control readout is the real one (non-vacuous: it names the recorded command)" \
    "make test-ci" "$CTL_DO"
assert_contains "4P.14 RESTORE CONTROL: the shipped region, same damaged object store, says CANNOT BE DETERMINED" \
    "CANNOT BE DETERMINED" "$CTL_DO"
assert_absent "4P.15 RESTORE CONTROL: ...and never states the tree is UNCHANGED" \
    "is UNCHANGED since that run" "$CTL_DO"

rm -rf "$G/.claude"
( cd "$G" && git checkout -q -- tracked.txt )
drive_in "$G" "$NOCUT_BIN" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$G/tracked.txt"
CTL_NOCUT=$(drive_in "$G" "$NOCUT_BIN" "$LEDGER_REGION" broader_verification_note)
assert_absent "4P.16 RESTORE CONTROL: the shipped region on the no-cut host never states the tree is UNCHANGED" \
    "is UNCHANGED since that run" "$CTL_NOCUT"
( cd "$G" && git checkout -q -- tracked.txt )
rm -rf "$G/.claude"

# ---------------------------------------------------------------------------
# 4P (second mutation) — the OTHER half of the invariant: an input has to carry
# content before there is anything to refuse.
#
# tree_fingerprint diffs against the EMPTY TREE when HEAD is unborn, so a staged
# never-committed file reaches input 2. Put `HEAD` back as the base and that
# diff fails, which the refusal above then catches — so the mutant does not
# produce a false match, it produces a REFUSAL where the shipped region produces
# a MEASUREMENT. That is the specific misbehaviour: the case stops being
# answerable at all, and 4.31/4.32 go red.
# ---------------------------------------------------------------------------
LEDGER_HEADBASE="$WORK/ledger-headbase.sh"
awk '
    index($0, "hash-object -t tree /dev/null") { print "        base=\"HEAD\""; found=1; next }
    { print }
    END { if (!found) exit 7 }
' "$LEDGER_REGION" > "$LEDGER_HEADBASE"
LEDGER_HEADBASE_RC=$?
assert_eq "4P.20 non-vacuity: the empty-tree base was found and replaced by HEAD (awk exit 0, not 7)" \
    "0" "$LEDGER_HEADBASE_RC"
# THE ANCHOR MUST BE UNIQUE, asserted for the reason 4P.0b asserts it: the awk
# above rewrites EVERY matching line, and the region's own KNOWN LIMITS block
# names `git hash-object -t tree /dev/null` in prose to explain the base. It
# currently escapes only because that sentence wraps between "tree" and
# "/dev/null" — a re-wrap would put a second match in a comment, and the mutation
# would then inject a bare assignment at region scope instead of only inside the
# function. That is a corrupted mutant, not a failed one, so it is pinned.
assert_eq "4P.20c non-vacuity: exactly ONE line in the region carries that anchor (no comment match)" \
    "1" "$(grep -cF -- 'hash-object -t tree /dev/null' "$LEDGER_REGION" | tr -d '[:space:]')"
assert_eq "4P.20b non-vacuity: the mutant's bytes differ, and it is still valid bash" \
    "yes/0" "$([ "$(shasum -a 256 "$LEDGER_HEADBASE" | awk '{print $1}')" != "$(shasum -a 256 "$LEDGER_REGION" | awk '{print $1}')" ] && echo yes || echo no)/$(bash -n "$LEDGER_HEADBASE" 2>/dev/null; echo $?)"

rm -rf "$GNS/.claude"
MUT_FP_NS=$(drive_in "$GNS" "" "$LEDGER_HEADBASE" tree_fingerprint)
assert_eq "4P.21 SPECIFIC: with HEAD as the base the unborn-HEAD case is not measurable at all — check 4.31 FAILS" \
    "no-hash" "$MUT_FP_NS"
printf 'STAGED DIFFERENT AGAIN, NOTHING IN COMMON\n' > "$GNS/s.txt"
assert_eq "4P.22 SPECIFIC: ...so rewriting the staged file cannot move it either — check 4.32 FAILS" \
    "$MUT_FP_NS" "$(drive_in "$GNS" "" "$LEDGER_HEADBASE" tree_fingerprint)"

CTL_NS1=$(drive_in "$GNS" "" "$LEDGER_REGION" tree_fingerprint)
printf 'STAGED ONE MORE REWRITE, STILL NOTHING IN COMMON\n' > "$GNS/s.txt"
CTL_NS2=$(drive_in "$GNS" "" "$LEDGER_REGION" tree_fingerprint)
assert_eq "4P.23 RESTORE CONTROL: the shipped region, same sandbox, measures it and MOVES" \
    "yes" "$(printf '%s' "$CTL_NS1" | grep -qE '^[0-9a-f]{16}$' && [ "$CTL_NS1" != "$CTL_NS2" ] && echo yes || echo no)"
rm -rf "$GNS/.claude"

# ---------------------------------------------------------------------------
# 4Q. META — put back the swallowed hash-object failure (R5-F1).
#
# THE MUTATION IS THE PRE-FIX CODE, LINE FOR LINE, not an approximation of it.
# Round 5 kept `|| true` over the batch `git hash-object --stdin-paths`, so a
# failure contributed whatever the call had already streamed — which is NOTHING
# when the unreadable path sorts first, and the earlier hashes when it sorts
# last. The replacement below restores exactly that expression.
#
# THE OBVIOUS SHORTER MUTATION IS WRONG AND WAS MEASURED WRONG. Replacing the
# fallback with `contents=""` also freezes the fingerprint, so it looks lethal
# and passes 4Q.3/4Q.4 — but it discards the PARTIAL output the pre-fix code
# kept, so it freezes in BOTH sort orders and 4Q.5 goes red on it. A mutant that
# is harsher than the code it stands in for cannot measure the defect's shape,
# and the shape is half of this finding.
#
# THIS IS A SEPARATE BANNER FROM 4P BECAUSE IT IS A SEPARATE FAILURE MODE. 4P
# mutates the refusal; this defect SURVIVED the refusal by being exempted from
# it, so `if false` was never lethal here and this leg is what makes the
# exemption's removal checkable.
# ---------------------------------------------------------------------------
printf '\n--- 4Q. META: with the untracked failure swallowed again, one broken symlink freezes the tree ---\n'

LEDGER_NOFALLBACK="$WORK/ledger-nofallback.sh"
# SC2016 throughout: `$paths`, `$contents` and `$PROJECT_DIR` are REGION text
# being matched and emitted literally; expanding them here would search for, and
# write, the empty string.
# shellcheck disable=SC2016
awk '
    index($0, "|| contents=$(_vl_hash_each \"$paths\")") {
        print "            || contents=$(printf '"'"'%s\\n'"'"' \"$paths\" \\"
        print "                | git -C \"$PROJECT_DIR\" hash-object --stdin-paths 2>/dev/null || true)"
        found=1; next
    }
    { print }
    END { if (!found) exit 7 }
' "$LEDGER_REGION" > "$LEDGER_NOFALLBACK"
LEDGER_NOFALLBACK_RC=$?
assert_eq "4Q.0 non-vacuity: the per-path fallback was found and neutralised (awk exit 0, not 7)" \
    "0" "$LEDGER_NOFALLBACK_RC"
# shellcheck disable=SC2016
assert_eq "4Q.0b non-vacuity: exactly ONE line in the region calls it (one fallback, not a scattering)" \
    "1" "$(grep -cF -- '|| contents=$(_vl_hash_each "$paths")' "$LEDGER_REGION" | tr -d '[:space:]')"
assert_eq "4Q.1 non-vacuity: the mutant's bytes differ, and it is still valid bash" \
    "yes/0" "$([ "$(shasum -a 256 "$LEDGER_NOFALLBACK" | awk '{print $1}')" != "$(shasum -a 256 "$LEDGER_REGION" | awk '{print $1}')" ] && echo yes || echo no)/$(bash -n "$LEDGER_NOFALLBACK" 2>/dev/null; echo $?)"

# Rebuilt to the freezing order: the broken path sorts FIRST, so nothing streams.
rm -rf "$GUP/.claude"
rm -f "$GUP/aaa-dangling" "$GUP/zzz-dangling"
ln -s /nonexistent/no-such-target-fkm111 "$GUP/aaa-dangling"
printf 'UNTRACKED ORIGINAL\n' > "$GUP/u.txt"
MUT_FP_UP1=$(drive_in "$GUP" "" "$LEDGER_NOFALLBACK" tree_fingerprint)
assert_eq "4Q.2 the mutant RAN and produced a REAL-LOOKING 16-hex fingerprint" \
    "yes" "$(printf '%s' "$MUT_FP_UP1" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"
drive_in "$GUP" "" "$LEDGER_NOFALLBACK" record_verification "make test-ci" 0 >/dev/null
printf 'UNTRACKED ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$GUP/u.txt"
# SPECIFIC MISBEHAVIOUR, naming the checks that would fail:
assert_eq "4Q.3 SPECIFIC: with the failure swallowed, an end-to-end rewrite does not move it — check 4.50 FAILS" \
    "$MUT_FP_UP1" "$(drive_in "$GUP" "" "$LEDGER_NOFALLBACK" tree_fingerprint)"
MUT_NOTE_UP=$(drive_in "$GUP" "" "$LEDGER_NOFALLBACK" broader_verification_note)
assert_eq "4Q.4 SPECIFIC: so the mutant declares the rewritten tree UNCHANGED — checks 4.51/4.51b FAIL on it" \
    "1" "$(contains_count 'is UNCHANGED since that run' "$MUT_NOTE_UP" | tr -d '[:space:]')"
# THE ORDERING SIGNATURE, under the mutant: the identical defect DISAPPEARS when
# the broken path sorts last. It is the property that made R4-F1 intermittent
# rather than rare, and pinning it here is what stops a future reader concluding
# the fixture was simply lucky.
rm -f "$GUP/aaa-dangling"
ln -s /nonexistent/no-such-target-fkm111 "$GUP/zzz-dangling"
printf 'UNTRACKED ORIGINAL\n' > "$GUP/u.txt"
MUT_FP_UPZ1=$(drive_in "$GUP" "" "$LEDGER_NOFALLBACK" tree_fingerprint)
printf 'UNTRACKED ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$GUP/u.txt"
assert_eq "4Q.5 SPECIFIC: ...and with the broken path sorting LAST the same mutant moves — the defect is ORDER-DEPENDENT, not rare" \
    "yes" "$([ "$MUT_FP_UPZ1" != "$(drive_in "$GUP" "" "$LEDGER_NOFALLBACK" tree_fingerprint)" ] && echo yes || echo no)"

# RESTORE CONTROL: shipped region, freezing order, identical sequence.
rm -rf "$GUP/.claude"
rm -f "$GUP/zzz-dangling"
ln -s /nonexistent/no-such-target-fkm111 "$GUP/aaa-dangling"
printf 'UNTRACKED ORIGINAL\n' > "$GUP/u.txt"
drive_in "$GUP" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'UNTRACKED ENTIRELY DIFFERENT CONTENT, NOTHING IN COMMON\n' > "$GUP/u.txt"
CTL_UP=$(drive_in "$GUP" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4Q.6a the control readout is the real one (non-vacuous: it names the recorded command)" \
    "make test-ci" "$CTL_UP"
assert_contains "4Q.6 RESTORE CONTROL: the shipped region, same symlink, same order, says MOVED" \
    "has MOVED since that run" "$CTL_UP"
assert_absent "4Q.7 RESTORE CONTROL: ...and never states the tree is UNCHANGED" \
    "is UNCHANGED since that run" "$CTL_UP"
rm -rf "$GUP/.claude"

# ---------------------------------------------------------------------------
# 4R. META — take the two diff flags away (R5-F2).
#
# THE ONE MUTATION NEITHER 4P NOR 4Q CAN STAND IN FOR, and that is the whole
# reason this fix is not a fifth guard. Removing `--no-ext-diff --no-textconv`
# hands input 2 back to `.gitattributes`, and over a driver that WORKS and is
# LOSSY the producer still exits 0 and its digest is still 64 hex — so the
# refusal 4P mutates never fires, the fallback 4Q mutates is not involved, and
# the only thing that changes is that the fingerprint stops seeing the file.
# The frozen value the mutant yields is the one measured on the unfixed shipped
# script before this round.
# ---------------------------------------------------------------------------
printf '\n--- 4R. META: without the diff flags, a working-but-lossy driver blinds the fingerprint ---\n'

LEDGER_NOFLAGS="$WORK/ledger-noflags.sh"
# SC2016: `$PROJECT_DIR` and `$base` are REGION text being matched and emitted
# literally. The replacement is the PRE-FIX line, trailing continuation and all.
# shellcheck disable=SC2016
awk '
    index($0, "diff --no-ext-diff --no-textconv \"$base\"") {
        print "                 git -C \"$PROJECT_DIR\" diff \"$base\" 2>/dev/null \\"; found=1; next
    }
    { print }
    END { if (!found) exit 7 }
' "$LEDGER_REGION" > "$LEDGER_NOFLAGS"
LEDGER_NOFLAGS_RC=$?
assert_eq "4R.0 non-vacuity: the flagged diff was found and reverted (awk exit 0, not 7)" \
    "0" "$LEDGER_NOFLAGS_RC"
# THE ANCHOR MUST BE UNIQUE, for the reason 4P.20c pins its own: the awk rewrites
# EVERY matching line, and this region's comments discuss the flags at length. It
# escapes only because no comment names them alongside `"$base"` — a reworded
# comment that did would inject a second copy of the diff at comment scope, which
# is a corrupted mutant rather than a failed one.
# shellcheck disable=SC2016
assert_eq "4R.0b non-vacuity: exactly ONE line in the region carries that anchor (no comment match)" \
    "1" "$(grep -cF -- 'diff --no-ext-diff --no-textconv "$base"' "$LEDGER_REGION" | tr -d '[:space:]')"
assert_eq "4R.1 non-vacuity: the mutant's bytes differ, and it is still valid bash" \
    "yes/0" "$([ "$(shasum -a 256 "$LEDGER_NOFLAGS" | awk '{print $1}')" != "$(shasum -a 256 "$LEDGER_REGION" | awk '{print $1}')" ] && echo yes || echo no)/$(bash -n "$LEDGER_NOFLAGS" 2>/dev/null; echo $?)"

rm -rf "$GLT/.claude"
printf 'BINARY ORIGINAL PAYLOAD\n' > "$GLT/data.bin"
( cd "$GLT" && git config diff.lossy.textconv "$LOSSY_TEXTCONV" ) >/dev/null 2>&1
MUT_FP_LT1=$(drive_in "$GLT" "" "$LEDGER_NOFLAGS" tree_fingerprint)
assert_eq "4R.2 the mutant RAN and produced a REAL-LOOKING 16-hex fingerprint (nothing failed, nothing was malformed)" \
    "yes" "$(printf '%s' "$MUT_FP_LT1" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"
drive_in "$GLT" "" "$LEDGER_NOFLAGS" record_verification "make test-ci" 0 >/dev/null
printf 'BINARY ENTIRELY DIFFERENT PAYLOAD, NOTHING IN COMMON\n' > "$GLT/data.bin"
# SPECIFIC MISBEHAVIOUR, naming the checks that would fail:
assert_eq "4R.3 SPECIFIC: without the flags an end-to-end rewrite does not move it — check 4.45 FAILS" \
    "$MUT_FP_LT1" "$(drive_in "$GLT" "" "$LEDGER_NOFLAGS" tree_fingerprint)"
MUT_NOTE_LT=$(drive_in "$GLT" "" "$LEDGER_NOFLAGS" broader_verification_note)
assert_eq "4R.4 SPECIFIC: so the mutant declares the rewritten tree UNCHANGED — checks 4.46/4.46b FAIL on it" \
    "1" "$(contains_count 'is UNCHANGED since that run' "$MUT_NOTE_LT" | tr -d '[:space:]')"
assert_eq "4R.5 SPECIFIC: ...and it never says it cannot tell — no refusal is reachable here, which is the finding" \
    "0" "$(contains_count 'CANNOT BE DETERMINED' "$MUT_NOTE_LT" | tr -d '[:space:]')"
# AND THE SECOND HALF OF THE MUTANT'S DAMAGE: repository configuration decides
# the fingerprint again. Same tree, driver configured vs unset, two values —
# which is check 4.47's negation.
MUT_FP_LT_CFG=$(drive_in "$GLT" "" "$LEDGER_NOFLAGS" tree_fingerprint)
( cd "$GLT" && git config --unset diff.lossy.textconv ) >/dev/null 2>&1
MUT_FP_LT_NOCFG=$(drive_in "$GLT" "" "$LEDGER_NOFLAGS" tree_fingerprint)
assert_eq "4R.6 SPECIFIC: under the mutant the fingerprint DEPENDS on .gitattributes — check 4.47 FAILS" \
    "yes" "$([ "$MUT_FP_LT_CFG" != "$MUT_FP_LT_NOCFG" ] && echo yes || echo no)"

# RESTORE CONTROL: shipped region, same sandbox, same sequence.
( cd "$GLT" && git config diff.lossy.textconv "$LOSSY_TEXTCONV" ) >/dev/null 2>&1
rm -rf "$GLT/.claude"
printf 'BINARY ORIGINAL PAYLOAD\n' > "$GLT/data.bin"
drive_in "$GLT" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'BINARY ENTIRELY DIFFERENT PAYLOAD, NOTHING IN COMMON\n' > "$GLT/data.bin"
CTL_LT=$(drive_in "$GLT" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4R.7a the control readout is the real one (non-vacuous: it names the recorded command)" \
    "make test-ci" "$CTL_LT"
assert_contains "4R.7 RESTORE CONTROL: the shipped region, same working-but-lossy driver, says MOVED" \
    "has MOVED since that run" "$CTL_LT"
assert_absent "4R.8 RESTORE CONTROL: ...and never states the tree is UNCHANGED" \
    "is UNCHANGED since that run" "$CTL_LT"
rm -rf "$GLT/.claude"

# ---------------------------------------------------------------------------
# 4S. META — hand the fallback its names as ARGV again (R7-F1).
#
# THE MUTATION IS THE PRE-FIX CODE, LINE FOR LINE: the per-path pipe through
# `--stdin-paths` goes back to `git hash-object -- "$p"`. What 4Q cannot see,
# this pins: 4Q mutates the fallback's EXISTENCE over a sandbox of PLAIN
# names, which argv reads correctly, so an argv fallback passes every 4Q leg —
# measured before this META existed, reverting the R7-F1 fix left all 194
# prior checks green. The defect also shares 4R's signature — producer rc=0,
# every digest well-formed — so no refusal is reachable and only a behavioural
# leg can catch it.
#
# SINCE THE ROUND AFTER, THE SHIPPED LINE ALSO CARRIES `--no-filters` (R8-F1),
# so this byte-faithful pre-R7 revert now moves TWO variables. The second is
# INERT here and that is measured, not assumed: GQN configures no attribute,
# where filtered and raw hashing return identical ids (4.58's expected id is
# computed by an UNFLAGGED direct call and the shipped fallback matches it),
# so everything these legs observe is attributable to the calling convention.
# The 4T sandbox is where the two variables part company.
# ---------------------------------------------------------------------------
printf '\n--- 4S. META: with the fallback fed argv again, a readable newline-named file reads as UNREADABLE ---\n'

LEDGER_ARGVFB="$WORK/ledger-argvfb.sh"
# SC2016 throughout this block: `$p` and `$PROJECT_DIR` are REGION text being
# matched and emitted literally. The replacement is the PRE-FIX line, trailing
# continuation and all.
# shellcheck disable=SC2016
awk '
    index($0, "\"$p\" | git -C \"$PROJECT_DIR\" hash-object --stdin-paths") {
        print "        git -C \"$PROJECT_DIR\" hash-object -- \"$p\" 2>/dev/null \\"; found=1; next
    }
    { print }
    END { if (!found) exit 7 }
' "$LEDGER_REGION" > "$LEDGER_ARGVFB"
LEDGER_ARGVFB_RC=$?
assert_eq "4S.0 non-vacuity: the per-path --stdin-paths feed was found and reverted to argv (awk exit 0, not 7)" \
    "0" "$LEDGER_ARGVFB_RC"
# THE ANCHOR MUST BE UNIQUE, for the reason 4P.20c pins its own: the awk
# rewrites EVERY matching line, and the region's comments name --stdin-paths
# repeatedly. The pipe from `"$p"` into git is what no comment and no other
# line — the batch call pipes from `"$paths"` — carries.
# shellcheck disable=SC2016
assert_eq "4S.0b non-vacuity: exactly ONE line in the region carries that anchor (no comment match, not the batch call)" \
    "1" "$(grep -cF -- '"$p" | git -C "$PROJECT_DIR" hash-object --stdin-paths' "$LEDGER_REGION" | tr -d '[:space:]')"
assert_eq "4S.1 non-vacuity: the mutant's bytes differ, and it is still valid bash" \
    "yes/0" "$([ "$(shasum -a 256 "$LEDGER_ARGVFB" | awk '{print $1}')" != "$(shasum -a 256 "$LEDGER_REGION" | awk '{print $1}')" ] && echo yes || echo no)/$(bash -n "$LEDGER_ARGVFB" 2>/dev/null; echo $?)"

# Rebuilt to R7-F1's exact configuration: a READABLE newline-named file AND a
# dangling symlink together, so the batch call fails and the fallback runs.
rm -rf "$GQN/.claude"
rm -f "$GQN/dangling"
ln -s /nonexistent/no-such-target-fkm111 "$GQN/dangling"
printf 'QUOTED-NAME ORIGINAL\n' > "$QN_FILE"
MUT_FP_QN1=$(drive_in "$GQN" "" "$LEDGER_ARGVFB" tree_fingerprint)
assert_eq "4S.2 the mutant RAN and produced a REAL-LOOKING 16-hex fingerprint (nothing failed, nothing malformed — the 4R signature)" \
    "yes" "$(printf '%s' "$MUT_FP_QN1" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"
drive_in "$GQN" "" "$LEDGER_ARGVFB" record_verification "make test-ci" 0 >/dev/null
printf 'QUOTED-NAME REWRITTEN END TO END, NOTHING IN COMMON\n' > "$QN_FILE"
# SPECIFIC MISBEHAVIOUR, naming the checks that would fail:
assert_eq "4S.3 SPECIFIC: under argv an end-to-end rewrite of the READABLE file does not move it — check 4.56 FAILS" \
    "$MUT_FP_QN1" "$(drive_in "$GQN" "" "$LEDGER_ARGVFB" tree_fingerprint)"
MUT_NOTE_QN=$(drive_in "$GQN" "" "$LEDGER_ARGVFB" broader_verification_note)
assert_eq "4S.4 SPECIFIC: so the mutant declares the rewritten tree UNCHANGED — checks 4.57/4.57b FAIL on it" \
    "1" "$(contains_count 'is UNCHANGED since that run' "$MUT_NOTE_QN" | tr -d '[:space:]')"
# THE MECHANISM, pinned at the fallback's own output: same tree, same tool,
# two calling conventions — the mutant reports the READABLE file as
# UNREADABLE where the shipped code returns its object id (4.58).
# SC2016: the eval string expands inside drive_in's subshell, as at 4.58.
# shellcheck disable=SC2016
MUT_FB_QN=$(drive_in "$GQN" "" "$LEDGER_ARGVFB" eval 'paths=$(_vl_untracked_paths | LC_ALL=C sort); _vl_hash_each "$paths"')
assert_contains "4S.5 SPECIFIC: the mutant's fallback emits UNREADABLE for a file git can read — checks 4.58/4.58c FAIL on it" \
    'UNREADABLE "a\nb"' "$MUT_FB_QN"

# RESTORE CONTROL: shipped region, identical configuration and sequence.
rm -rf "$GQN/.claude"
printf 'QUOTED-NAME ORIGINAL\n' > "$QN_FILE"
drive_in "$GQN" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'QUOTED-NAME REWRITTEN END TO END, NOTHING IN COMMON\n' > "$QN_FILE"
CTL_QN=$(drive_in "$GQN" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4S.6a the control readout is the real one (non-vacuous: it names the recorded command)" \
    "make test-ci" "$CTL_QN"
assert_contains "4S.6 RESTORE CONTROL: the shipped region, same quoted name, same symlink, says MOVED" \
    "has MOVED since that run" "$CTL_QN"
assert_absent "4S.7 RESTORE CONTROL: ...and never states the tree is UNCHANGED" \
    "is UNCHANGED since that run" "$CTL_QN"
rm -rf "$GQN/.claude"

# ---------------------------------------------------------------------------
# 4T. META — hash the untracked set through the attributes machinery again
# (R8-F1).
#
# THE MUTATION IS THE PRE-FIX CODE: ` --no-filters` stripped from BOTH
# hash-object calls, which is one guard at two sites rather than two guards —
# either site alone re-opens the hole on its own route (the batch call in the
# common case, the fallback whenever an unreadable path forces it), and the
# awk requires BOTH to be found so a partial future edit cannot leave this
# META half-vacuous. The defect shares 4R's signature — every producer rc=0,
# every digest well-formed, the refusal never reachable — so, as there, the
# cure stops the degradation instead of catching it, and only a behavioural
# leg can pin it. Measured before this META existed: reverting the R8-F1 fix
# left all 213 prior checks green, the third time this file has watched a
# whole control set stay green over a live HIGH (4S: 194, R2-F1: every leg).
# ---------------------------------------------------------------------------
printf '\n--- 4T. META: with the filters honoured again, a lossy clean filter freezes the untracked hashes ---\n'

LEDGER_FILTERED="$WORK/ledger-filtered.sh"
# SC2016: `$PROJECT_DIR` is REGION text matched literally. The gsub removes
# the flag; everything else on both lines survives byte for byte.
# shellcheck disable=SC2016
awk '
    index($0, "hash-object --stdin-paths --no-filters") {
        gsub(/ --no-filters/, ""); found++
    }
    { print }
    END { if (found != 2) exit 7 }
' "$LEDGER_REGION" > "$LEDGER_FILTERED"
LEDGER_FILTERED_RC=$?
assert_eq "4T.0 non-vacuity: the flag was found and stripped at BOTH call sites (awk exit 0, not 7)" \
    "0" "$LEDGER_FILTERED_RC"
# THE ANCHOR MUST BE UNIQUE TO THE TWO EXECUTABLE LINES, for the reason 4S.0b
# pins its own: the awk rewrites EVERY matching line, and this region's
# comments discuss the flag at length. They escape by never spelling the
# full `--stdin-paths --no-filters` pair — a comment that did would be
# stripped into nonsense at comment scope, a corrupted mutant rather than a
# failed one.
# shellcheck disable=SC2016
assert_eq "4T.0b non-vacuity: exactly TWO lines in the region carry that anchor (batch + fallback, no comment match)" \
    "2" "$(grep -cF -- 'hash-object --stdin-paths --no-filters' "$LEDGER_REGION" | tr -d '[:space:]')"
assert_eq "4T.1 non-vacuity: the mutant's bytes differ, and it is still valid bash" \
    "yes/0" "$([ "$(shasum -a 256 "$LEDGER_FILTERED" | awk '{print $1}')" != "$(shasum -a 256 "$LEDGER_REGION" | awk '{print $1}')" ] && echo yes || echo no)/$(bash -n "$LEDGER_FILTERED" 2>/dev/null; echo $?)"

# Rebuilt to R8-F1's configuration: one untracked file behind the working
# filter, nothing unreadable — the BATCH call is the route.
rm -rf "$GCF/.claude"
printf 'CODE: cell\nOUT: first payload\n' > "$GCF/u.ipynb"
MUT_FP_CF1=$(drive_in "$GCF" "" "$LEDGER_FILTERED" tree_fingerprint)
assert_eq "4T.2 the mutant RAN and produced a REAL-LOOKING 16-hex fingerprint (nothing failed, nothing malformed — the 4R signature)" \
    "yes" "$(printf '%s' "$MUT_FP_CF1" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"
drive_in "$GCF" "" "$LEDGER_FILTERED" record_verification "make test-ci" 0 >/dev/null
printf 'CODE: cell\nOUT: second payload, nothing in common\n' > "$GCF/u.ipynb"
# SPECIFIC MISBEHAVIOUR, naming the checks that would fail:
assert_eq "4T.3 SPECIFIC: with filters honoured an end-to-end rewrite does not move it — check 4.60 FAILS" \
    "$MUT_FP_CF1" "$(drive_in "$GCF" "" "$LEDGER_FILTERED" tree_fingerprint)"
MUT_NOTE_CF=$(drive_in "$GCF" "" "$LEDGER_FILTERED" broader_verification_note)
assert_eq "4T.4 SPECIFIC: so the mutant declares the rewritten tree UNCHANGED — checks 4.61/4.61b FAIL on it" \
    "1" "$(contains_count 'is UNCHANGED since that run' "$MUT_NOTE_CF" | tr -d '[:space:]')"
# THE MECHANISM, pinned at the fallback's own output: same tree, same loop,
# one flag — the mutant carries the FILTERED constant where the shipped code
# carries the raw id (4.62's negation, on the route 4T.3 does not drive).
ln -s /nonexistent/no-such-target-fkm111 "$GCF/dangling"
MUT_CF_RAW=$( (cd "$GCF" && git hash-object --no-filters -- u.ipynb 2>/dev/null) )
MUT_CF_FILTERED=$( (cd "$GCF" && git hash-object -- u.ipynb 2>/dev/null) )
# SC2016: the eval string expands inside drive_in's subshell, as at 4.58.
# shellcheck disable=SC2016
MUT_FB_CF=$(drive_in "$GCF" "" "$LEDGER_FILTERED" eval 'paths=$(_vl_untracked_paths | LC_ALL=C sort); _vl_hash_each "$paths"')
assert_contains "4T.5 SPECIFIC: the mutant's fallback carries the FILTERED constant id — check 4.62 FAILS on it" \
    "$MUT_CF_FILTERED" "$MUT_FB_CF"
assert_eq "4T.5b SPECIFIC: ...and never the raw one (the two ids really differ here, so 4T.5 is not vacuous)" \
    "0/yes" "$(contains_count "$MUT_CF_RAW" "$MUT_FB_CF" | tr -d '[:space:]')/$([ "$MUT_CF_RAW" != "$MUT_CF_FILTERED" ] && echo yes || echo no)"
rm -f "$GCF/dangling"

# RESTORE CONTROL: shipped region, identical configuration and sequence.
rm -rf "$GCF/.claude"
printf 'CODE: cell\nOUT: first payload\n' > "$GCF/u.ipynb"
drive_in "$GCF" "" "$LEDGER_REGION" record_verification "make test-ci" 0 >/dev/null
printf 'CODE: cell\nOUT: second payload, nothing in common\n' > "$GCF/u.ipynb"
CTL_CF=$(drive_in "$GCF" "" "$LEDGER_REGION" broader_verification_note)
assert_contains "4T.6a the control readout is the real one (non-vacuous: it names the recorded command)" \
    "make test-ci" "$CTL_CF"
assert_contains "4T.6 RESTORE CONTROL: the shipped region, same filter, same rewrite, says MOVED" \
    "has MOVED since that run" "$CTL_CF"
assert_absent "4T.7 RESTORE CONTROL: ...and never states the tree is UNCHANGED" \
    "is UNCHANGED since that run" "$CTL_CF"
rm -rf "$GCF/.claude"

# ===========================================================================
# 5. The Makefile dry-run guard.
#
# `make -n` does NOT skip a recipe line containing $(MAKE) — it runs it. The
# first version of test-ci therefore recorded "make test-ci exited 0" on a dry
# run that executed no suite at all. The guard lines are EXTRACTED FROM THE REAL
# MAKEFILE, never re-typed, so a probe cannot pass over a guard the repo does
# not actually ship.
# ===========================================================================
printf '\n--- 5. the Makefile dry-run guard: a dry run must mint no record ---\n'

if ! command -v make >/dev/null 2>&1; then
    printf 'gate-claim-honesty.test: make is required for section 5 and is absent\n' >&2
    exit 2
fi

GUARD_LINES="$WORK/guard.txt"
# SC2016: `$$mf_first` is MAKEFILE syntax being matched literally — a double-quoted
# pattern would have the shell eat the `$$` before grep ever saw it.
# A no-match is not silently tolerated: assertion 5.0 requires exactly 2 lines.
# shellcheck disable=SC2016
grep -E 'mf_first=|case "\$\$mf_first" in' "$MAKEFILE" > "$GUARD_LINES" 2>/dev/null || true
GUARD_N=$(grep -c . "$GUARD_LINES" 2>/dev/null || echo 0)
GUARD_N=$(printf '%s' "$GUARD_N" | tr -d '[:space:]')
assert_eq "5.0 non-vacuity: both guard lines were found in the real Makefile" "2" "$GUARD_N"

# The extracted lines ALREADY end in ` ; \` (they are continuation lines in the
# real recipe), so they are re-emitted verbatim under a fresh leading tab —
# appending another backslash produces a literal `\` in the command and make
# dies with a syntax error. awk, not sed, because BSD sed does not expand \t in
# a replacement.
MK="$WORK/probe.mk"
# SC2016 throughout this block: `$(MAKE)`, `$$rc` and `$$dry` are MAKEFILE
# syntax being written verbatim into a Makefile. Shell expansion here would
# produce a probe that tests nothing.
# shellcheck disable=SC2016
{
    printf 'probe:\n'
    printf '\t@rc=0 ; \\\n'
    awk '{ sub(/^[[:space:]]+/, ""); printf "\t%s\n", $0 }' "$GUARD_LINES"
    printf '\t$(MAKE) --no-print-directory -f %s inner || rc=$$? ; \\\n' "$MK"
    printf '\tif [ "$$dry" = "1" ]; then : > %s/skipped.marker ; else echo "recorded rc=$$rc" >> %s/record.txt ; fi ; \\\n' "$WORK" "$WORK"
    printf '\texit $$rc\n'
    printf 'inner:\n'
    printf '\t@true\n'
} > "$MK"
assert_eq "5.0b non-vacuity: the probe Makefile parses (make can read the extracted guard)" \
    "0" "$( (cd "$WORK" && make -n -f "$MK" inner >/dev/null 2>&1); echo $?)"

# OBSERVED AS A SIDE EFFECT, NEVER AS STDOUT TEXT — and that is not fastidious,
# it is a defect this file caught in itself. The first version asserted that the
# dry run's OUTPUT contained the guarded branch's echo. `make -n` PRINTS the
# recipe, so that string is present whichever branch runs: the assertion passed
# identically on the guarded and unguarded Makefile, i.e. it was vacuous. Its own
# 5M leg is what exposed it. A marker FILE is created only by the branch that
# actually executes, so presence is an observation rather than an echo of the
# source.
rm -f "$WORK/record.txt" "$WORK/skipped.marker"
(cd "$WORK" && make -f "$MK" probe) >/dev/null 2>&1; REAL_RC=$?
assert_eq "5.1 the probe recipe RAN normally (exit 0)" "0" "$REAL_RC"
assert_eq "5.2 a real run DOES write a record" \
    "yes" "$([ -s "$WORK/record.txt" ] && echo yes || echo no)"
assert_eq "5.2b a real run does NOT take the guarded branch" \
    "no" "$([ -f "$WORK/skipped.marker" ] && echo yes || echo no)"

rm -f "$WORK/record.txt" "$WORK/skipped.marker"
(cd "$WORK" && make -n -f "$MK" probe) >/dev/null 2>&1; DRY_RC=$?
assert_eq "5.3 the dry run itself succeeded" "0" "$DRY_RC"
assert_eq "5.4 the dry run DID take the guarded branch (marker file, not printed text)" \
    "yes" "$([ -f "$WORK/skipped.marker" ] && echo yes || echo no)"
assert_eq "5.5 a dry run writes NO record" \
    "no" "$([ -s "$WORK/record.txt" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 5M. META — remove the guard; the dry run mints a false green.
# ---------------------------------------------------------------------------
printf '\n--- 5M. META: without the guard, "make -n" records a run that never happened ---\n'

# The mutation: delete the `case ... esac` line that sets dry=1, leaving dry at
# its initialised 0. Matched on `mf_first" in` — the line's distinguishing
# content — and it reports a miss (exit 7) so a reworded guard cannot silently
# turn this META into a no-op.
MK_MUT="$WORK/probe-mut.mk"
awk -v self="$MK_MUT" -v orig="$MK" '
    index($0, "mf_first\" in") { print "\tdry=0 ; \\"; found=1; next }
    { gsub(orig, self); print }
    END { if (!found) exit 7 }
' "$MK" > "$MK_MUT"
MK_MUT_RC=$?
assert_eq "5M.0a non-vacuity: the guard line was found and removed (awk exit 0, not 7)" \
    "0" "$MK_MUT_RC"
assert_eq "5M.0 non-vacuity: the mutant Makefile differs from the probe" \
    "yes" "$([ "$(shasum -a 256 "$MK_MUT" | awk '{print $1}')" != "$(shasum -a 256 "$MK" | awk '{print $1}')" ] && echo yes || echo no)"
assert_eq "5M.1 non-vacuity: the mutant really has the case-guard removed" \
    "0" "$(grep -c 'mf_first" in' "$MK_MUT" | tr -d '[:space:]')"

rm -f "$WORK/record.txt" "$WORK/skipped.marker"
(cd "$WORK" && make -n -f "$MK_MUT" probe) >/dev/null 2>&1; MUT_DRY_RC=$?
assert_eq "5M.2 the mutant dry run executed (so the next assertion is about the guard)" \
    "0" "$MUT_DRY_RC"
# SPECIFIC MISBEHAVIOUR, naming the checks that would fail:
assert_eq "5M.3 SPECIFIC: without the guard a DRY run writes a record — check 5.5 FAILS" \
    "yes" "$([ -s "$WORK/record.txt" ] && echo yes || echo no)"
assert_eq "5M.4 SPECIFIC: ...and it never takes the guarded branch — check 5.4 FAILS" \
    "no" "$([ -f "$WORK/skipped.marker" ] && echo yes || echo no)"

rm -f "$WORK/record.txt" "$WORK/skipped.marker"
(cd "$WORK" && make -n -f "$MK" probe) >/dev/null 2>&1
assert_eq "5M.5 RESTORE CONTROL: the real guard, identical dry invocation, writes nothing" \
    "no" "$([ -s "$WORK/record.txt" ] && echo yes || echo no)"
assert_eq "5M.6 RESTORE CONTROL: ...and does take the guarded branch" \
    "yes" "$([ -f "$WORK/skipped.marker" ] && echo yes || echo no)"

# ===========================================================================
# 6. claude-workflow-plugin-j7kk (9xl4 cheap half) — the skip-when-unchanged
# predicate: BOTH tree_fingerprint (content) and current_change_set_hash (path
# list) must match a persisted record before a Stop may replay it instead of
# re-running the suite. Neither instrument is invented for this feature —
# tree_fingerprint is section 4's own subject, and current_change_set_hash is
# the SAME sha256 section 1 measures via impact-report.sh --hash-only — so this
# section is short: it exercises the ONE new comparison, not two instruments
# already pinned above.
#
# THE PROPERTY UNDER TEST, stated once because every leg below is a facet of
# it: change_set_hash is a hash of WHICH PATHS changed, not their bytes (this
# is section 1.2/2's own subject — "rewriting a listed file does NOT move
# change_set_hash"). A second edit to a file ALREADY in the tracked set is
# therefore invisible to it. A skip gated on change_set_hash alone would
# replay a stale PASS or FAIL over new, unverified content. Requiring
# tree_fingerprint too closes it, because tree_fingerprint hashes the DIFF
# ITSELF (section 4's whole subject), which the second edit always moves.
# ===========================================================================
printf '\n--- 6. claude-workflow-plugin-j7kk: the skip predicate requires BOTH instruments ---\n'

SKIP_REGION="$WORK/skip.sh"
SKIP_RC=0
extract_region "$VBS" "# SKIP-UNCHANGED BEGIN" "# SKIP-UNCHANGED END" "$SKIP_REGION" || SKIP_RC=$?
assert_eq "6.0a non-vacuity: the SKIP-UNCHANGED sentinels exist" "0" "$SKIP_RC"
assert_eq "6.0b the extracted region is valid bash on its own" \
    "0" "$(bash -n "$SKIP_REGION" 2>/dev/null; echo $?)"

# current_change_set_hash is NOT sentinel-wrapped (it is a general-purpose
# instrument with three OTHER call sites in verify-before-stop.sh, not
# SKIP-UNCHANGED-specific — wrapping it in a feature-named sentinel would
# mislabel it for the next reader). Extracted by function name instead, the
# same technique 3M's mutant construction already uses in this file.
CCSH_REGION="$WORK/ccsh.sh"
CCSH_RC=0
awk '
    $0 == "current_change_set_hash() {" { inf=1; found=1 }
    inf { print }
    inf && /^}$/ { inf=0 }
    END { if (!found) exit 7 }
' "$VBS" > "$CCSH_REGION" || CCSH_RC=$?
assert_eq "6.0c non-vacuity: current_change_set_hash was found and extracted by name" \
    "0" "$CCSH_RC"
assert_eq "6.0d the extracted function is valid bash on its own" \
    "0" "$(bash -n "$CCSH_REGION" 2>/dev/null; echo $?)"

# last_verified_state_file_for (inside SKIP_REGION) calls sanitize_task_id,
# which is declared near the top of verify-before-stop.sh (outside every
# sentinel region — it is a file-wide helper, shared with iteration_file_for
# and every other per-task cache path). Extracted the same way as
# current_change_set_hash, by name, for the same reason: not feature-specific,
# so not worth a sentinel of its own.
SANID_REGION="$WORK/sanid.sh"
SANID_RC=0
awk '
    $0 == "sanitize_task_id() {" { inf=1; found=1 }
    inf { print }
    inf && /^}$/ { inf=0 }
    END { if (!found) exit 7 }
' "$VBS" > "$SANID_REGION" || SANID_RC=$?
assert_eq "6.0e non-vacuity: sanitize_task_id was found and extracted by name" \
    "0" "$SANID_RC"

# A real git sandbox, like section 4's $G — current_change_set_hash shells out
# to the REAL impact-report.sh, which needs a real tracker file to hash.
G6="$WORK/gitproj-skip"
mkdir -p "$G6/src" "$G6/.claude/.qa-tracking"
( cd "$G6" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'one\n' > src/a.ts && git add src/a.ts && git commit -qm init ) >/dev/null 2>&1
printf 'src/a.ts\n' > "$G6/.claude/.qa-tracking/changed-files.txt"

# drive_skip_at <project-dir> <region> <fn> [args...] — sources the denylist
# lib, the ledger region (tree_fingerprint + its sentinels), the
# current_change_set_hash function and the given SKIP-UNCHANGED region (shipped
# or mutant) into one subshell scoped at <project-dir>, then calls <fn>.
drive_skip_at() {
    local pd="$1" reg="$2" fn="$3"; shift 3
    (
        set -u
        PROJECT_DIR="$pd"; QA_TRACKING_DIR="$pd/.claude/.qa-tracking"
        # shellcheck disable=SC2034  # read by current_change_set_hash() after
        # it is sourced from $CCSH_REGION below — shellcheck cannot trace a
        # reader defined in a file generated at runtime by awk.
        IMPACT_REPORT_SCRIPT="$IMPACT"
        mkdir -p "$QA_TRACKING_DIR"
        # shellcheck disable=SC1090
        . "$DENYLIST_LIB"
        # shellcheck disable=SC1090
        . "$LEDGER_REGION"
        # shellcheck disable=SC1090
        . "$CCSH_REGION"
        # shellcheck disable=SC1090
        . "$SANID_REGION"
        # shellcheck disable=SC1090
        . "$reg"
        "$fn" "$@"
    )
}
drive_skip() { drive_skip_at "$G6" "$SKIP_REGION" "$@"; }

# drive_record_at <project-dir> <region> <task-id> [args...] — claude-workflow-
# plugin-j7kk R1-F1: record_verified_state now takes the pre-dispatch fp/hash
# as explicit arguments (see its header in verify-before-stop.sh) instead of
# reading them itself, so it can refuse to persist when its OWN post-run
# reading disagrees with what the caller read before dispatch. This helper
# reads both instruments through the SAME drive_skip_at harness immediately
# before calling the writer — reproducing "nothing moved between the
# pre-dispatch read and the persist", which is every 6.x/6M leg's own
# precondition (nothing runs a "suite" between the two in this isolated
# harness). The mid-suite-mutation case — pre disagrees with post — is Leg K
# / META K in escalation-basis.sh, driven against the real, unmodified script
# end to end rather than the extracted region.
drive_record_at() {
    local pd="$1" reg="$2" tid="$3" fp hash
    fp=$(drive_skip_at "$pd" "$reg" tree_fingerprint)
    hash=$(drive_skip_at "$pd" "$reg" current_change_set_hash)
    drive_skip_at "$pd" "$reg" record_verified_state "$tid" "$fp" "$hash"
}
drive_record() { drive_record_at "$G6" "$SKIP_REGION" "$@"; }

assert_eq "6.1 fresh sandbox, no prior record: verified_state_unchanged is false (nothing to reuse yet)" \
    "false" "$(drive_skip verified_state_unchanged tsk1)"

drive_record tsk1 >/dev/null
STATE_FILE="$G6/.claude/.qa-tracking/last-verified-state.tsk1"
assert_eq "6.2a record_verified_state wrote a state file" \
    "yes" "$([ -s "$STATE_FILE" ] && echo yes || echo no)"
assert_eq "6.2b the record is exactly one line" \
    "1" "$(wc -l < "$STATE_FILE" | tr -d '[:space:]')"
assert_eq "6.2c the record carries exactly 3 tab-separated fields (ts, fp, hash — VERIFICATION_LEDGER's own tab-separated convention, scoped per-task instead of appended)" \
    "3" "$(awk -F'\t' '{print NF}' "$STATE_FILE")"

assert_eq "6.3 immediately after persisting, with nothing else touched: verified_state_unchanged is true" \
    "true" "$(drive_skip verified_state_unchanged tsk1)"

# --- 6.4: THE k0mc PROPERTY, MEASURED before it is asserted -----------------
HASH_BEFORE_EDIT=$(drive_skip current_change_set_hash)
printf 'one-DIFFERENT\n' > "$G6/src/a.ts"
HASH_AFTER_EDIT=$(drive_skip current_change_set_hash)
assert_eq "6.4a MEASURED (k0mc): editing an ALREADY-TRACKED file's content does NOT move change_set_hash (the path list is unchanged) — the gap tree_fingerprint exists to close" \
    "$HASH_BEFORE_EDIT" "$HASH_AFTER_EDIT"
assert_eq "6.4b so change_set_hash ALONE would say 'unchanged' here, and it would be WRONG: the shipped predicate (both instruments) correctly says false" \
    "false" "$(drive_skip verified_state_unchanged tsk1)"

( cd "$G6" && git checkout -q -- src/a.ts )
assert_eq "6.5 reverting the edit restores 'unchanged' — a pure function of state, matching tree_fingerprint's own section-4.4 precedent" \
    "true" "$(drive_skip verified_state_unchanged tsk1)"

printf 'two\n' > "$G6/src/b.ts"
printf 'src/a.ts\nsrc/b.ts\n' > "$G6/.claude/.qa-tracking/changed-files.txt"
assert_eq "6.6 a NEW file entering the tracked change set moves BOTH instruments: verified_state_unchanged is false" \
    "false" "$(drive_skip verified_state_unchanged tsk1)"

drive_record tsk1 >/dev/null
assert_eq "6.7 re-persisting against the new state makes it the new baseline: verified_state_unchanged is true again" \
    "true" "$(drive_skip verified_state_unchanged tsk1)"

# --- 6.8/6.9: BOTH the writer and the reader refuse a sentinel --------------
NOGIT="$WORK/no-git-skip"
mkdir -p "$NOGIT/.claude/.qa-tracking"
FP_NOGIT=$(drive_skip_at "$NOGIT" "$SKIP_REGION" tree_fingerprint)
assert_eq "6.8a non-vacuity: the no-git target really produces the no-git sentinel" \
    "no-git" "$FP_NOGIT"
# Pass the JUST-PROVEN sentinel as fp-pre (the caller's pre-dispatch reading)
# — record_verified_state's sentinel check runs on fp-pre BEFORE it ever
# looks at hash-pre or takes its own post-run reading, so this exercises
# exactly the fp-pre-is-a-sentinel branch regardless of the placeholder
# hash-pre value.
drive_skip_at "$NOGIT" "$SKIP_REGION" record_verified_state tskx "$FP_NOGIT" "deadbeef" >/dev/null
assert_eq "6.8b WRITE-SIDE REFUSAL: record_verified_state persists NOTHING when the pre-dispatch tree_fingerprint reading is a sentinel (a transient failure costs one redundant re-run later, never a false skip)" \
    "no" "$([ -e "$NOGIT/.claude/.qa-tracking/last-verified-state.tskx" ] && echo yes || echo no)"

# A record whose fingerprint IS the sentinel, planted by hand (never by this
# region's own writer, per 6.8b) — the shape a corrupted or hand-edited cache
# file could take. The CURRENT read on this same no-git target is ALSO the
# sentinel, so a naive identity comparison would call the two equal and say
# "unchanged". Both sides refuse instead — the same discipline rubric-
# binding.sh I4 states for change_set_hash ("Both the writer and the reader
# refuse it"), applied here to tree_fingerprint.
printf '2026-01-01T00:00:00Z\tno-git\tdeadbeef\n' > "$NOGIT/.claude/.qa-tracking/last-verified-state.tsky"
assert_eq "6.9 READ-SIDE REFUSAL: a planted no-git record is refused even though the CURRENT read is ALSO no-git" \
    "false" "$(drive_skip_at "$NOGIT" "$SKIP_REGION" verified_state_unchanged tsky)"

DETAIL=$(drive_skip verified_state_unchanged_detail tsk1)
assert_contains "6.10a the detail sentence names WHEN the reused run was recorded (same voice as broader_verification_note's LAST RECORDED paragraph)" \
    "recorded at" "$DETAIL"
assert_contains "6.10b ...and the current change-set hash, so a reader can verify it independently by re-running impact-report.sh --hash-only" \
    "$(drive_skip current_change_set_hash)" "$DETAIL"

# --- 6.11: checks_scope_claim/note, parameterised by SUITE_REUSE_REASON -----
# Extends the EXISTING 3M-paired guard (checks_scope_claim/note must not
# overclaim) to the new parameter, rather than adding a second guard: 3.14
# already pins "NOT re-run this loop" for SUITE_REUSED=true; this pins that the
# REASON clause is no longer hardcoded to "escalation contract".
drive_scope_reason() {
    local reason="$1" detail="$2" what="$3"
    (
        set -u
        PROJECT_DIR="$WORK/noproj"; QA_TRACKING_DIR="$WORK/noproj/.claude/.qa-tracking"
        mkdir -p "$QA_TRACKING_DIR"
        # shellcheck disable=SC1090
        . "$LEDGER_REGION"
        # shellcheck disable=SC1090
        . "$SCOPE_REGION"
        # shellcheck disable=SC2030,SC2031  # deliberately subshell-scoped —
        # see drive_scope's identical note above; this is the second, separate
        # subshell that never shares state with the first.
        export RUNNER="make" TEST_CMD="$REAL_TEST" LINT_CMD="$REAL_LINT" TYPE_CMD="" \
               SUITE_REUSED=true SUITE_REUSE_REASON="$reason" SUITE_REUSE_DETAIL="$detail"
        case "$what" in
            claim) checks_scope_claim ;;
            note)  checks_scope_note ;;
        esac
    )
}
REASON_SKIPUNCH="tree and change-set unchanged since the last full run"
CLAIM_SKIPUNCH=$(drive_scope_reason "$REASON_SKIPUNCH" "" claim)
assert_contains "6.11a checks_scope_claim, given a non-escalation SUITE_REUSE_REASON, prints THAT reason" \
    "$REASON_SKIPUNCH" "$CLAIM_SKIPUNCH"
assert_absent "6.11b ...and never claims 'escalation contract' when the reason is something else" \
    "escalation contract" "$CLAIM_SKIPUNCH"
DETAIL_TEXT="the tree (fingerprint abc123) and the reviewable change set (hash def456) have not moved since the full run recorded at 2026-01-01T00:00:00Z"
NOTE_SKIPUNCH=$(drive_scope_reason "$REASON_SKIPUNCH" "$DETAIL_TEXT" note)
assert_contains "6.11c checks_scope_note names the SPECIFIC reason (not 'escalation contract')" \
    "$REASON_SKIPUNCH" "$NOTE_SKIPUNCH"
assert_contains "6.11d ...and, when SUITE_REUSE_DETAIL is set, appends the concrete evidence sentence (same voice as Broader verification, LAST RECORDED, which also names concrete values rather than asserting currency)" \
    "Reused because $DETAIL_TEXT" "$NOTE_SKIPUNCH"
CLAIM_DEFAULT=$(drive_scope "$SCOPE_REGION" "$REAL_TEST" "$REAL_LINT" "" true claim)
assert_contains "6.11e BACKWARD COMPAT: with SUITE_REUSE_REASON unset (the pre-j7kk escalation caller's own shape, re-asserting 3.14), the claim still defaults to 'escalation contract'" \
    "escalation contract" "$CLAIM_DEFAULT"

# ---------------------------------------------------------------------------
# 6M. META — narrow the predicate to the path-list hash alone. The k0mc gap
# this section exists to close must reopen: a real content-only edit to an
# already-tracked file is then WRONGLY read as "unchanged".
# ---------------------------------------------------------------------------
printf '\n--- 6M. META: drop the tree_fingerprint half — the k0mc gap reopens ---\n'

SKIP_MUT="$WORK/skip-mut.sh"
# shellcheck disable=SC2016  # single-quoted on purpose: these are LITERAL
# shell-source patterns to match/replace in the extracted region's text, not
# expressions meant to expand against this script's own variables.
sed 's/if \[ "\$fp" = "\$cur_fp" \] && \[ "\$hash" = "\$cur_hash" \]; then/if [ "$hash" = "$cur_hash" ]; then/' \
    "$SKIP_REGION" > "$SKIP_MUT"
# shellcheck disable=SC2016  # same reason: matching literal source text.
assert_eq "6M.0a non-vacuity: the mutant's comparison really dropped the tree_fingerprint half" \
    "0" "$(grep -c '\$fp" = "\$cur_fp"' "$SKIP_MUT" | tr -d '[:space:]')"
# shellcheck disable=SC2016  # same reason: matching literal source text.
assert_eq "6M.0b non-vacuity: ...and a hash-only comparison landed in its place" \
    "1" "$(grep -c 'if \[ "\$hash" = "\$cur_hash" \]; then' "$SKIP_MUT" | tr -d '[:space:]')"
assert_eq "6M.1 non-vacuity: the mutant differs from the shipped region" \
    "yes" "$([ "$(shasum -a 256 "$SKIP_MUT" | awk '{print $1}')" != "$(shasum -a 256 "$SKIP_REGION" | awk '{print $1}')" ] && echo yes || echo no)"
assert_eq "6M.2 the mutant is still valid bash" \
    "0" "$(bash -n "$SKIP_MUT" 2>/dev/null; echo $?)"

# A FRESH sandbox for the META, so it does not depend on $G6's accumulated
# state from 6.1-6.11 above.
G6M="$WORK/gitproj-skip-meta"
mkdir -p "$G6M/src" "$G6M/.claude/.qa-tracking"
( cd "$G6M" && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'one\n' > src/a.ts && git add src/a.ts && git commit -qm init ) >/dev/null 2>&1
printf 'src/a.ts\n' > "$G6M/.claude/.qa-tracking/changed-files.txt"

# Baseline through the SHIPPED writer (record_verified_state is untouched by
# this mutation — only the COMPARISON changes), so both legs below read the
# exact same persisted record.
drive_record_at "$G6M" "$SKIP_REGION" tskm >/dev/null
HASH_BASE_M=$(drive_skip_at "$G6M" "$SKIP_REGION" current_change_set_hash)
printf 'one-DIFFERENT\n' > "$G6M/src/a.ts"
HASH_AFTER_M=$(drive_skip_at "$G6M" "$SKIP_REGION" current_change_set_hash)
assert_eq "6M.3 precondition: same k0mc shape as 6.4 — a content-only edit leaves the path list (and so change_set_hash) unchanged" \
    "$HASH_BASE_M" "$HASH_AFTER_M"

assert_eq "6M.4 SPECIFIC MISBEHAVIOUR: the mutant (hash-only comparison) WRONGLY reports 'true' over this real content edit — check 6.4b would FAIL on it" \
    "true" "$(drive_skip_at "$G6M" "$SKIP_MUT" verified_state_unchanged tskm)"
assert_eq "6M.5 RESTORE CONTROL: the SHIPPED predicate, the identical on-disk state, correctly says false" \
    "false" "$(drive_skip_at "$G6M" "$SKIP_REGION" verified_state_unchanged tskm)"

# ===========================================================================
# 7. claude-workflow-plugin-j7kk R1-F3 — the F1-declined NOTE composition arm
# (immediately before the F1 dispatch case, qzv) must cover EVERY status on
# which F1 was eligible or unreadable, including `unavailable` (qa-gate.sh
# status's own spelling for "the store could not be read at all" — distinct
# from this hook's generic `error` fallback). Message-only: the dispatch arm
# a few lines below already excludes `unavailable` from the fast path
# correctly either way, so nothing here can change WHETHER the Stop blocks,
# only whether it explains why.
#
# Extracted by literal text range rather than the surrounding
# F1-CHANGE-SET-BINDING sentinel: that sentinel wraps ~300 lines including
# review-check.sh subprocess calls this arm does not need. The snippet below
# is a plain `if/case/fi` reading only FASTPATH_CLASS/F1_BINDING_VERDICT/
# F1_BINDING_DETAIL/GATE_STATUS/CURRENT_TASK and calling log_sync_error —
# fully self-contained, so it sources and runs directly with no stub beyond
# log_sync_error itself.
# ===========================================================================
printf '\n--- 7. claude-workflow-plugin-j7kk R1-F3: F1_BINDING_NOTE composition covers GATE_STATUS=unavailable ---\n'

F1NOTE_REGION="$WORK/f1note.sh"
awk '
    $0 == "        if [ \"$F1_BINDING_VERDICT\" != \"safe\" ]; then" { infound=1; found=1 }
    infound { print }
    infound && $0 == "        fi" { exit }
    END { if (!found) exit 7 }
' "$VBS" > "$F1NOTE_REGION"
F1NOTE_RC=$?
assert_eq "7.0a non-vacuity: the F1_BINDING_NOTE composition arm was found and extracted" "0" "$F1NOTE_RC"
assert_eq "7.0b the extraction really produced a non-empty region" \
    "yes" "$([ -s "$F1NOTE_REGION" ] && echo yes || echo no)"
assert_eq "7.0c the extracted region is valid bash on its own" \
    "0" "$(bash -n "$F1NOTE_REGION" 2>/dev/null; echo $?)"
assert_contains "7.0d sanity: the extraction really ends at the case's own esac, not a truncated slice" \
    "esac" "$(cat "$F1NOTE_REGION")"

# drive_f1note <region> <verdict> <status> — sources a stub log_sync_error
# (a plain no-op: the snippet's diagnostic-log call is not this test's
# subject) plus the given region with the four inputs preset, then prints
# whatever F1_BINDING_NOTE the region composed (empty if the arm's case did
# not match).
drive_f1note() {
    local reg="$1" verdict="$2" status="$3"
    (
        set -u
        # shellcheck disable=SC2034  # read by the region after it is sourced
        # from $reg below — shellcheck cannot trace a reader defined in a
        # file extracted at runtime by awk (same reasoning as
        # $CCSH_REGION's IMPACT_REPORT_SCRIPT above).
        FASTPATH_CLASS="doc-only"
        # shellcheck disable=SC2034  # see FASTPATH_CLASS above
        F1_BINDING_VERDICT="$verdict"
        # shellcheck disable=SC2034  # see FASTPATH_CLASS above
        F1_BINDING_DETAIL="stub detail for drive_f1note"
        # shellcheck disable=SC2034  # see FASTPATH_CLASS above
        GATE_STATUS="$status"
        # shellcheck disable=SC2034  # see FASTPATH_CLASS above
        CURRENT_TASK="tsk-f1note"
        F1_BINDING_NOTE=""
        # shellcheck disable=SC2329  # invoked from $reg after it is sourced
        # below, not from this subshell directly — same reason the five
        # assignments above need SC2034.
        log_sync_error() { :; }
        # shellcheck disable=SC1090
        . "$reg"
        printf '%s' "$F1_BINDING_NOTE"
    )
}

assert_eq "7.1 precondition: a SAFE verdict composes no note regardless of status (the arm is gated on non-safe)" \
    "" "$(drive_f1note "$F1NOTE_REGION" safe entered)"
assert_eq "7.2 precondition: the ALREADY-COVERED not-entered status composes a note (regression check, unaffected by this fix)" \
    "yes" "$([ -n "$(drive_f1note "$F1NOTE_REGION" unestablished not-entered)" ] && echo yes || echo no)"

assert_eq "7.3 FIXED BEHAVIOUR (R1-F3): GATE_STATUS=unavailable with a non-safe verdict NOW composes an F1-declined explanation" \
    "yes" "$([ -n "$(drive_f1note "$F1NOTE_REGION" unestablished unavailable)" ] && echo yes || echo no)"
assert_contains "7.4 ...naming the verdict's own detail text (the same voice as every other status in this arm)" \
    "stub detail for drive_f1note" "$(drive_f1note "$F1NOTE_REGION" unestablished unavailable)"

# ---------------------------------------------------------------------------
# META 7 — drop `unavailable` from the case pattern (the pre-R1-F3 shape).
# The SAME inputs that composed a note at 7.3 must then compose NOTHING —
# reproducing the silent-refusal message gap this fix closes.
# ---------------------------------------------------------------------------
F1NOTE_MUT="$WORK/f1note-mut.sh"
sed 's/not-entered|entered|pending|error|unavailable|"")/not-entered|entered|pending|error|"")/' \
    "$F1NOTE_REGION" > "$F1NOTE_MUT"
assert_eq "META 7.0a non-vacuity: the mutant differs from the extracted region (unavailable was dropped)" \
    "yes" "$([ "$(shasum -a 256 "$F1NOTE_MUT" | awk '{print $1}')" != "$(shasum -a 256 "$F1NOTE_REGION" | awk '{print $1}')" ] && echo yes || echo no)"
assert_eq "META 7.0b non-vacuity: specifically, unavailable| is gone from the mutant's case pattern" \
    "0" "$(grep -c 'unavailable|""' "$F1NOTE_MUT" | tr -d '[:space:]')"
assert_eq "META 7.0c the mutant is still valid bash" \
    "0" "$(bash -n "$F1NOTE_MUT" 2>/dev/null; echo $?)"
assert_eq "META 7.1 SPECIFIC MISBEHAVIOUR: the SAME inputs that composed a note at 7.3 now compose NOTHING" \
    "" "$(drive_f1note "$F1NOTE_MUT" unestablished unavailable)"
assert_eq "META 7.2 RESTORE CONTROL: the mutant still covers the pre-existing not-entered status (only unavailable was removed)" \
    "yes" "$([ -n "$(drive_f1note "$F1NOTE_MUT" unestablished not-entered)" ] && echo yes || echo no)"

# ===========================================================================
printf '\n=== gate-claim-honesty.test.sh ===\n'
printf 'PASSED: %d assertion(s)\n' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d assertion(s)\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
exit 0

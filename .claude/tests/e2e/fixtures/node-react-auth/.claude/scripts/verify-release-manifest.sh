#!/bin/bash
# verify-release-manifest.sh [release_tag]
#
# claude-workflow-plugin-h2zz waiver ruling (round 4). THE CHECK THIS
# REPLACES used to live inside workflow-manifest.test.sh's Section 6 (an L1
# spec, run on every `make test` and every CI push): "the frozen table named
# by .claude-plugin/plugin.json reproduces byte-for-byte from the tree of
# the tag it names, under the current generator." That claim CANNOT hold on
# a pre-release ref — the tag the section archives may not exist yet, by
# definition, until release day — and five independent-review rounds of
# trying to exempt L1 from that fact narrowly enough failed six times over:
#   R1-F1  the emission predicate proved local history completeness, not
#          remote tag existence
#   R1-F2  the exempt-token regex was an unanchored substring a passing
#          assertion's own prose could satisfy
#   R2-F1  the fix for R1-F1 put a live network call inside a tier
#          documented offline (.claude/tests/README.md, Makefile's
#          "Composes the offline tiers")
#   R3-F1  the timeout guarding that network call was disableable via its
#          own public argument (TIMEOUT_S="0" disabled the cap on GNU
#          timeout; the fallback treated the same "0" as instant-timeout)
#   R3-F2  the control added to prove the R2-F1 fallback path is actually
#          exercised in CI was itself vacuous there (a PATH prepend left
#          the real timeout resolvable)
#   R4-F1  the R3-F1 fix rejected only the byte-exact string "0", letting
#          "00"/"000" reproduce the original cross-platform split
# Six findings, one mechanism, four rounds. This project's standing waiver
# ruling (claude-workflow-plugin-gytz, the STORE-CANARY ATTRIBUTION removal
# in run-tests.sh) is exactly for this shape: remove the mechanism rather
# than guard it again. See run-tests.sh's PRE-RELEASE-REF EXEMPTION: REMOVED
# tombstone for where the exemption used to live.
#
# THE UNDERLYING CLAIM IS NOT WRONG, only its PLACEMENT was: it belongs in a
# context where "the tag is not reachable yet" cannot occur by construction.
# This script is deliberately the same invocation in all three contexts
# where it actually runs:
#   (a) LOCALLY, against a deliberately-local tag, before it is pushed —
#       `make verify-release`, run as part of a release checklist. The tag
#       exists in the local object database (created but not yet pushed),
#       so `git archive` and `git rev-parse --verify` both work against it
#       with no network at all.
#   (b) IN CI, tag-triggered, after the tag is pushed —
#       .github/workflows/release-verify.yml, `on: push: tags: 'v*'`. By the
#       time this job runs, the tag that triggered it is definitionally on
#       the remote, so there is no "not reachable yet" case to handle.
#   (c) IN L1 (verify-release-manifest.test.sh, registered in run-tests.sh
#       and run on every `make test`), against CONSTRUCTED FIXTURE
#       repositories carrying their OWN local tags, created moments earlier
#       inside the test — never this project's own release tag, and never a
#       network call. This is the SAME "always locally reachable" property
#       as (a), just against a throwaway repo instead of this one, which is
#       what makes this script's own logic testable from an offline tier
#       without ever asserting anything about THIS repo's tag.
# (a) and (b) are the two PRODUCTION invocations; (c) is test coverage of
# this same shipped script, not a separate reimplementation of the claim
# (round 5, claude-workflow-plugin-h2zz, R5-F6 — this paragraph previously
# claimed the script is "never invoked by `make test` or any L1 spec",
# which stopped being true the moment (c) was added; the invocation exists,
# it is simply never pointed at this repo's own tag). All three share the
# property that actually matters here: the live git operations below (git
# archive, git show) never touch a tag that might not exist yet, so they
# are unconditionally fine in every context this script runs in, including
# its own L1 coverage.
#
# USAGE: verify-release-manifest.sh [release_tag]
#   release_tag   Optional. Defaults to "v$(jq -r .version .claude-plugin/
#                 plugin.json)" — the same derivation workflow-manifest.
#                 test.sh's removed Section 6 used. Pass explicitly to check
#                 a tag other than the one plugin.json currently names.
#
# EXIT CODES:
#   0  the frozen table reproduces byte-for-byte from the tag's tree, AND
#      the tag itself carries a committed copy of that table matching the
#      working tree's — both halves of the claim, not just the first (round
#      5, claude-workflow-plugin-h2zz, R5-F1: the first half alone reproduces
#      cleanly for a tag that ships no table at all, since regeneration is
#      compared against the WORKING-TREE table and never reads the tag's own
#      copy unless this second half checks it).
#   1  it does not: the tag does not carry manifests/<tag>.sha256 at all, its
#      committed copy differs from the working tree's, or regenerating from
#      the tag's tree produces a different table than either (a genuine
#      mismatch — see the diagnostic printed above the failing line for
#      which of the three moved)
#   2  usage/precondition error (tag unreachable, table missing, jq absent,
#      etc.) — unlike the removed L1 section, this is NOT a silent skip: a
#      script invoked ONLY in a context where the check is expected to be
#      meaningful has nothing honest to skip to.
set -u

# SCRIPT resolves against THIS script's own real location, always -- it is
# "the current generator" the check is about, and must stay the genuine
# shipped copy no matter which tree PROJECT_DIR below ends up pointing at.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/workflow-manifest.sh"

# PROJECT_DIR, separately, takes a CLAUDE_PROJECT_DIR override -- the same
# convention workflow-manifest.test.sh itself uses -- so this script can be
# driven against a constructed fixture tree for its own test coverage
# (verify-release-manifest.test.sh), without which it could only ever be
# exercised against the real, live project: the exact "cannot test this
# without touching production" trap the removed Section 6 never had to
# navigate, since a spec always has its own PROJECT_DIR variable to hand.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

if [ ! -f "$SCRIPT" ]; then
    printf 'verify-release-manifest.sh: %s not found\n' "$SCRIPT" >&2
    exit 2
fi

if [ -n "${1:-}" ]; then
    RELEASE_TAG="$1"
else
    if ! command -v jq >/dev/null 2>&1; then
        printf 'verify-release-manifest.sh: no release_tag argument given and jq is not on PATH to derive one from .claude-plugin/plugin.json\n' >&2
        exit 2
    fi
    RELEASE_VERSION=$(jq -r '.version // empty' "$PROJECT_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo "")
    if [ -z "$RELEASE_VERSION" ]; then
        printf 'verify-release-manifest.sh: could not read .version from .claude-plugin/plugin.json (jq absent, or the manifest moved)\n' >&2
        exit 2
    fi
    RELEASE_TAG="v$RELEASE_VERSION"
fi
RELEASE_TABLE="$PROJECT_DIR/manifests/$RELEASE_TAG.sha256"

if [ ! -f "$RELEASE_TABLE" ]; then
    printf 'verify-release-manifest.sh: manifests/%s.sha256 has not been frozen yet -- nothing to compare against\n' "$RELEASE_TAG" >&2
    exit 2
fi
if ! git -C "$PROJECT_DIR" rev-parse -q --verify "$RELEASE_TAG^{commit}" >/dev/null 2>&1; then
    printf 'verify-release-manifest.sh: the %s tag is not reachable here -- create it locally before running this (pre-push), or push it first (post-push, CI)\n' "$RELEASE_TAG" >&2
    exit 2
fi

WORK=$(mktemp -d -t verify-release-manifest.XXXXXX) || {
    printf 'verify-release-manifest.sh: mktemp failed\n' >&2
    exit 2
}
trap 'rm -rf "$WORK"' EXIT

FAIL=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
}

# (iii)/(iv) — round 5 (claude-workflow-plugin-h2zz, R5-F1). UNCONDITIONAL,
# before any success can be reported: does the TAG ITSELF carry
# manifests/<tag>.sha256, and does its committed copy match the working
# tree's? Before this round both questions were answered ONLY as a post-hoc
# diagnostic further down, reached solely once the (v) regeneration
# comparison below had already failed — so a table added to the working
# tree AFTER the tag was already cut, never committed into the tag at all,
# reproduced cleanly: (v) compares the regeneration against the
# WORKING-TREE table, never the tag's own committed copy, so it cannot see
# this case on its own, and the script exited 0 having never looked at what
# the tag actually shipped (reproduced live: tag a repo before its
# manifests/ table exists, then generate the table afterward — the unfixed
# script prints "OK ... reproduces byte-for-byte" and exits 0).
#
# Both exit 1 (genuine mismatch), not 2 (precondition/usage): by this point
# the tag is reachable (checked above) and the working-tree table exists
# (checked above), so nothing about the invocation or the environment is
# wrong. What these two find, when they find something, is a defect in the
# RELEASE ITSELF — the tag does not ship the artifact it is named for, or
# ships a stale copy of it — exactly the class of problem this script
# exists to catch, not a setup step the caller skipped.
TAGCOPY="$WORK/release-table-at-tag.sha256"
SHOW_RC=0
git -C "$PROJECT_DIR" show "$RELEASE_TAG:manifests/$RELEASE_TAG.sha256" > "$TAGCOPY" 2>/dev/null || SHOW_RC=$?
TAG_HAS_TABLE=1
TAG_COPY_MATCHES=1
if [ "$SHOW_RC" -ne 0 ]; then
    TAG_HAS_TABLE=0
    TAG_COPY_MATCHES=0
    fail "the $RELEASE_TAG tag does not carry manifests/$RELEASE_TAG.sha256 at all (git show exited $SHOW_RC) -- a release gate cannot report OK for a tag that ships no frozen table"
elif ! cmp -s "$TAGCOPY" "$RELEASE_TABLE"; then
    TAG_COPY_MATCHES=0
    fail "manifests/$RELEASE_TAG.sha256 has been EDITED since the $RELEASE_TAG tag was created (working tree differs from the tag's own committed copy)"
fi

TAGTREE="$WORK/release-tag-tree"
mkdir -p "$TAGTREE"
# pipefail inside the subshell: without it a failing `git archive` is masked
# by tar exiting 0 on an empty stream, and this would go on to compare a
# real table against a 0-row manifest and blame the generator.
ARCHIVE_RC=0
( set -o pipefail; git -C "$PROJECT_DIR" archive "$RELEASE_TAG" | tar -x -C "$TAGTREE" ) \
    || ARCHIVE_RC=$?
if [ "$ARCHIVE_RC" -ne 0 ]; then
    fail "git archive $RELEASE_TAG exited $ARCHIVE_RC"
fi
if [ ! -f "$TAGTREE/.claude-plugin/plugin.json" ]; then
    fail "the extracted tree does not carry .claude-plugin/plugin.json"
fi

REGEN="$WORK/release-tag-manifest.tsv"
GEN_RC=0
bash "$SCRIPT" generate "$TAGTREE" > "$REGEN" 2>"$WORK/release-tag-generate.err" || GEN_RC=$?
if [ "$GEN_RC" -ne 0 ]; then
    printf 'diagnostic: generate over the %s tree exited %s; stderr:\n' "$RELEASE_TAG" "$GEN_RC" >&2
    sed 's/^/  /' "$WORK/release-tag-generate.err" 2>/dev/null | head -10 >&2
    fail "generate over the tag tree exits 0"
fi

REGEN_ROWS=$(wc -l < "$REGEN" 2>/dev/null | tr -d ' ')
TABLE_ROWS=$(wc -l < "$RELEASE_TABLE" 2>/dev/null | tr -d ' ')
if [ "${REGEN_ROWS:-0}" -eq 0 ]; then
    fail "the regeneration produced zero rows (would compare empty-vs-empty and prove nothing)"
fi
if [ "${REGEN_ROWS:-0}" != "${TABLE_ROWS:-0}" ]; then
    fail "regenerated row count ($REGEN_ROWS) does not equal the frozen table's ($TABLE_ROWS)"
fi

if ! cmp -s "$REGEN" "$RELEASE_TABLE"; then
    printf 'diagnostic: first differing rows (regenerated from %s vs frozen):\n' "$RELEASE_TAG" >&2
    diff "$REGEN" "$RELEASE_TABLE" 2>/dev/null | head -10 | sed 's/^/  /' >&2
    fail "manifests/$RELEASE_TAG.sha256 is NOT byte-identical to the regenerated tag manifest"

    # WHICH SIDE MOVED -- a REFINEMENT of the (iii)/(iv) checks above, which
    # already ran unconditionally and already recorded the answer; this
    # reuses that result rather than re-fetching the tag's copy a second
    # time. (Round 5, R5-F1: those checks used to be diagnosed ONLY once
    # this claim had already failed -- now they always run, and this block
    # just restates their verdict at the point a reader will actually ask
    # the question: was the table hand-edited after the tag, or did the
    # generator change under it?)
    if [ "$TAG_HAS_TABLE" -eq 0 ]; then
        printf 'diagnostic: the tag tree does not even carry the table it is named for (see the FAIL above)\n' >&2
    elif [ "$TAG_COPY_MATCHES" -eq 0 ]; then
        printf 'diagnostic: the committed table has been EDITED since the tag was created (see the FAIL above)\n' >&2
    else
        printf 'diagnostic: the committed table is UNCHANGED since the tag -- the GENERATOR has changed under it instead\n' >&2
    fi
fi

if [ "$FAIL" -gt 0 ]; then
    printf '\nverify-release-manifest.sh: FAILED (%d check(s)) for %s\n' "$FAIL" "$RELEASE_TAG" >&2
    exit 1
fi
printf 'verify-release-manifest.sh: OK -- manifests/%s.sha256 reproduces byte-for-byte from %s (%s rows)\n' \
    "$RELEASE_TAG" "$RELEASE_TAG" "$TABLE_ROWS"
exit 0

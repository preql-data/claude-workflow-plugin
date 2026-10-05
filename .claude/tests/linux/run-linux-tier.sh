#!/bin/bash
# run-linux-tier.sh — run the offline test tiers inside a Linux container.
#
# WHAT PROBLEM THIS SOLVES. Every hook script, runner, gate and installer branch
# in this repo is authored and measured on macOS: BSD find, BSD sed, BSD stat,
# `shasum`, bash 3.2. The CI tiers run on ubuntu-latest: GNU findutils, GNU
# coreutils, `sha256sum`, bash 5.2. Until this target, the only way to learn
# what that difference costs was to PUSH — and a first push would have conflated
# two independent unknowns, because the l1-unit job itself was substantially
# rewired (real bd, five whole-file skip arms deleted, STRICT_SECTIONS=1 armed)
# and had never run either. A red push could not have told you which of the two
# it was. This runs the SAME tier bytes on Linux locally, so the two unknowns
# separate.
#
# IT IS NOT A CI SUBSTITUTE, and the report says so every run rather than in a
# comment nobody reads. What differs from .github/workflows/test.yml is listed
# in the Dockerfile beside this file; the biggest one is ARCHITECTURE (this
# builds native — linux/arm64 on an Apple Silicon box — while CI is
# linux/amd64).
#
# THE REPO IS MOUNTED, NOT COPIED, and the mount is READ-ONLY.
#   * Mounted, because a copy is a second set of bytes that can drift from the
#     tree you are about to certify. The mount is verified per run: repo-bytes.sh
#     runs on the host and inside the container and the two digests must agree,
#     so "the real bytes" is a CHECKED claim rather than an asserted one.
#   * Read-only, because this is a target you should be able to run in the
#     middle of a live session. A container writing into .beads/ or
#     .claude/.qa-tracking/ would corrupt the state of the session that launched
#     it, and on a Linux host it would leave root-owned files in your checkout.
#     Measured: the whole L1 tier runs to completion against a read-only mount —
#     every spec builds its fixtures under the container's own /tmp — so the
#     guarantee costs nothing. If a future spec DOES need to write into the
#     tree it will fail loudly with EROFS naming the path, which is the honest
#     outcome and a finding worth having.
#
# EVERY TIER'S STATUS IS REPORTED, INCLUDING THE ONES THAT DID NOT RUN. A
# container target that silently runs a subset is the defect this release
# exists to close, so "not run" is a first-class row in the report and is never
# scored as a pass.
#
# DEGRADING WITHOUT DOCKER. No docker, no daemon, or a failed image build is a
# LOUD SKIP: a named reason and exit 2, never a silent 0. Exit 2 is "the tier
# could not run" — deliberately distinct from exit 1, "a tier ran and failed" —
# which is the same three-outcome discipline the L1 runner applies to specs.
#
# Usage:
#   bash .claude/tests/linux/run-linux-tier.sh [options]
#     --tiers <list>    comma-separated: l1, l2, or l1,l2   (default: l1)
#     --filter <pat>    pass --filter <pat> through to the tier runner(s)
#     --no-strict       do NOT set STRICT_SECTIONS=1 (default: set, mirroring CI)
#     --no-build        fail instead of building a missing image
#     --rebuild         rebuild the image even when it exists
#     --keep-going      run every requested tier even after one fails
#     -h | --help       this text
#
# Environment:
#   CWP_LINUX_IMAGE     image tag           (default cwp-linux-tier:24.04)
#   CWP_LINUX_BASE      base image          (default ubuntu:24.04)
#   CWP_LINUX_PLATFORM  docker --platform   (default: unset = host native)
#   DOCKER              docker binary       (default: docker)
#
# Exit codes:
#   0  every REQUESTED tier ran, and every one of them passed
#   1  every requested tier ran, and at least one failed
#   2  could not run: no docker, no daemon, build failure, byte mismatch, byte
#      verification that could not be PERFORMED, a tree edited under the run,
#      docker's own infrastructure failure (rc 125/126/127), bad arguments —
#      i.e. the bar was not measured. Never confuse with 1.
#
# CANNOT-MEASURE IS EXIT 2 EVEN WHEN EVERY TIER PASSED, and that sentence is
# here because the first version of this driver got it wrong. A byte MISMATCH
# refused; a byte check that could not RUN fell through, and with green tiers the
# run printed `every requested tier ran on Linux and passed` and exited 0. The
# only thing a `make test-linux && ...` or a CI consumer reads is the exit code,
# so an unmeasured mount that exits 0 turns the design's CHECKED claim back into
# the ASSERTED one the design rejected — silently. Same for docker's own rcs:
# 125/126/127 come from docker rather than from the tier runner (which exits 0,
# 1 or 2 only), so a container that never started is NOT RUN, not a failure.
# (claude-workflow-plugin-mdnc R1-F2/R1-F4; paired by
# .claude/scripts/tests/linux-tier-driver.test.sh.)

set -u

DOCKER_BIN="${DOCKER:-docker}"
IMAGE="${CWP_LINUX_IMAGE:-cwp-linux-tier:24.04}"
BASE_IMAGE="${CWP_LINUX_BASE:-ubuntu:24.04}"
PLATFORM="${CWP_LINUX_PLATFORM:-}"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$HERE/../../.." && pwd)
CONTAINER_REPO="/repo"

TIERS="l1"
FILTER=""
STRICT=1
BUILD_MODE="auto"     # auto | never | always
KEEP_GOING=0

usage() {
    sed -n '2,80p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

# refuse <reason...> — the ONE exit-2 path. Prints a report block first so a
# machine-parsed run still gets the tier table (all NOT RUN) rather than a bare
# error line.
refuse() {
    printf '\n=== Linux tier: NOT RUN ===\n'
    printf 'reason: %s\n' "$1"
    shift
    while [ "$#" -gt 0 ]; do
        printf '        %s\n' "$1"
        shift
    done
    printf 'This is a SKIP, not a pass: nothing was measured on Linux by this invocation.\n'
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tiers)     TIERS="${2:-}"; shift 2 || refuse "--tiers needs a value" ;;
        --filter)    FILTER="${2:-}"; shift 2 || refuse "--filter needs a value" ;;
        --no-strict) STRICT=0; shift ;;
        --no-build)  BUILD_MODE="never"; shift ;;
        --rebuild)   BUILD_MODE="always"; shift ;;
        --keep-going) KEEP_GOING=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           refuse "unknown argument: $1" "run with --help for the accepted set" ;;
    esac
done

# Tier list validation up front. An unknown tier name must not silently reduce
# the run to the tiers that happened to parse.
REQUESTED=""
_ifs_save="$IFS"
IFS=','
for t in $TIERS; do
    case "$t" in
        l1|l2) REQUESTED="$REQUESTED $t" ;;
        '')    ;;
        *)     IFS="$_ifs_save"; refuse "unknown tier '$t' in --tiers '$TIERS'" "accepted: l1, l2" ;;
    esac
done
IFS="$_ifs_save"
REQUESTED="${REQUESTED# }"
[ -n "$REQUESTED" ] || refuse "--tiers '$TIERS' selected no tiers" "accepted: l1, l2"

# --- preflight -------------------------------------------------------------
command -v "$DOCKER_BIN" >/dev/null 2>&1 || \
    refuse "docker is not on PATH (looked for '$DOCKER_BIN')" \
           "Install Docker Desktop / podman-docker, or set DOCKER=<binary>." \
           "The Linux tier is the only place this repo's scripts meet GNU tooling before CI does."

DOCKER_ERR=$("$DOCKER_BIN" info --format '{{.ServerVersion}}' 2>&1) || \
    refuse "the docker daemon is not reachable" \
           "\`$DOCKER_BIN info\` said: $(printf '%s' "$DOCKER_ERR" | head -2 | tr '\n' ' ')" \
           "Start Docker Desktop (or the daemon) and re-run."
SERVER_VERSION="$DOCKER_ERR"
SERVER_ARCH=$("$DOCKER_BIN" info --format '{{.Architecture}}' 2>/dev/null || printf 'unknown')
SERVER_OS=$("$DOCKER_BIN" info --format '{{.OperatingSystem}}' 2>/dev/null || printf 'unknown')

# --- image -----------------------------------------------------------------
# THE IMAGE CARRIES THE DIGEST OF THE DOCKERFILE THAT BUILT IT, and `auto`
# rebuilds when they disagree. This is not polish — it is a defect this driver
# shipped with and hit on its second run: the Dockerfile gained a package, the
# image already existed, `auto` reused it, and the tier reported the same two
# failures over an image that did not contain the fix. "Ran against a stale
# build and reported it as a result" is the exact family of silent-subset
# defect this whole target exists to close, so the staleness is detected rather
# than trusted, and the report prints which of the three states it was in.
image_exists() { "$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1; }

hash_file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum < "$1"
    else
        shasum -a 256 < "$1"
    fi
}
DOCKERFILE_SHA=$(hash_file_sha256 "$HERE/Dockerfile" 2>/dev/null) || DOCKERFILE_SHA=""
DOCKERFILE_SHA="${DOCKERFILE_SHA%% *}"

image_label_sha() {
    "$DOCKER_BIN" image inspect --format '{{ index .Config.Labels "cwp.dockerfile.sha256" }}' \
        "$IMAGE" 2>/dev/null || printf ''
}

BUILD_NOTE="reused existing image"
build_image() {
    printf '=== building %s from %s (base %s) ===\n' "$IMAGE" "$HERE/Dockerfile" "$BASE_IMAGE"
    set -- build -f "$HERE/Dockerfile" -t "$IMAGE" --build-arg "BASE=$BASE_IMAGE"
    [ -n "$DOCKERFILE_SHA" ] && set -- "$@" --label "cwp.dockerfile.sha256=$DOCKERFILE_SHA"
    [ -n "$PLATFORM" ] && set -- "$@" --platform "$PLATFORM"
    set -- "$@" "$HERE"
    "$DOCKER_BIN" "$@"
}

case "$BUILD_MODE" in
    always)
        build_image || refuse "the image build failed (see the build log above)" \
            "The build needs the network: it fetches node and bd from pinned, checksum-verified URLs."
        BUILD_NOTE="rebuilt (--rebuild)"
        ;;
    never)
        image_exists || refuse "image '$IMAGE' does not exist and --no-build was given" \
            "Drop --no-build, or build it: $DOCKER_BIN build -f $HERE/Dockerfile -t $IMAGE $HERE"
        if [ -z "$DOCKERFILE_SHA" ]; then
            BUILD_NOTE="reused existing image — staleness UNCHECKED (no sha256sum/shasum on this host)"
        elif [ "$(image_label_sha)" != "$DOCKERFILE_SHA" ]; then
            BUILD_NOTE="STALE — built from a DIFFERENT Dockerfile, and --no-build forbade a rebuild"
        fi
        ;;
    auto)
        if ! image_exists; then
            build_image || refuse "the image build failed (see the build log above)" \
                "The build needs the network: it fetches node and bd from pinned, checksum-verified URLs."
            BUILD_NOTE="built (was absent)"
        elif [ -z "$DOCKERFILE_SHA" ]; then
            # NO DIGEST WAS COMPUTED, so NOTHING WAS COMPARED. This branch used
            # to fall through to the `else` below, and the report then asserted
            # `reused (Dockerfile digest matches the image label)` over a check
            # that had not run — the asserted-not-checked family this driver
            # exists to eliminate, one severity down from the byte verification
            # doing the same thing (claude-workflow-plugin-mdnc R1-F4). Neither
            # `sha256sum` nor `shasum` is guaranteed: a stripped container, a
            # BusyBox host, a PATH-restricted CI step.
            BUILD_NOTE="reused — staleness UNCHECKED (no sha256sum/shasum on this host, so no digest was computed to compare)"
        elif [ "$(image_label_sha)" != "$DOCKERFILE_SHA" ]; then
            printf '=== the existing image was built from a different Dockerfile — rebuilding ===\n'
            build_image || refuse "the image rebuild failed (see the build log above)" \
                "The existing image does not match $HERE/Dockerfile, so reusing it would report a result for bytes you are not shipping."
            BUILD_NOTE="rebuilt (Dockerfile changed since the image was built)"
        else
            BUILD_NOTE="reused (Dockerfile digest matches the image label)"
        fi
        ;;
esac

IMAGE_ID=$("$DOCKER_BIN" image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || printf 'unknown')

# --- the mount is the real bytes: check it, do not assert it ---------------
BYTES_STATUS="UNCHECKED"
BYTES_NOTE=""
HOST_BYTES=$(bash "$HERE/repo-bytes.sh" "$REPO_ROOT" 2>&1) || HOST_BYTES=""
CONTAINER_BYTES=$("$DOCKER_BIN" run --rm \
    ${PLATFORM:+--platform "$PLATFORM"} \
    -v "$REPO_ROOT:$CONTAINER_REPO:ro" \
    "$IMAGE" \
    bash "$CONTAINER_REPO/.claude/tests/linux/repo-bytes.sh" "$CONTAINER_REPO" 2>&1) || CONTAINER_BYTES=""

HOST_DIGEST=$(printf '%s\n' "$HOST_BYTES" | awk '$1 == "digest" { print $2 }')
CONTAINER_DIGEST=$(printf '%s\n' "$CONTAINER_BYTES" | awk '$1 == "digest" { print $2 }')
BYTES_COUNTS=$(printf '%s\n' "$HOST_BYTES" | awk '$1 == "files" { f=$2 } $1 == "links" { l=$2 } END { printf "%s file(s), %s link(s)", f, l }')

if [ -z "$HOST_DIGEST" ] || [ -z "$CONTAINER_DIGEST" ]; then
    # CANNOT MEASURE. Distinct from MISMATCH, and it is NOT a fall-through: it
    # reaches the exit code and the verdict line at the bottom of this script.
    # Left as a report row alone (the shipped behaviour), a green run printed
    # the unqualified pass verdict and exited 0 over a mount nothing had
    # verified. See the exit-code block at the end and the header note.
    BYTES_STATUS="UNCHECKED"
    BYTES_NOTE="repo-bytes.sh did not produce a digest on one or both sides (host: '$(printf '%s' "$HOST_BYTES" | head -1)', container: '$(printf '%s' "$CONTAINER_BYTES" | head -1)')"
elif [ "$HOST_DIGEST" = "$CONTAINER_DIGEST" ]; then
    BYTES_STATUS="MATCH"
    # TRACKED paths only. `.beads/` is NOT wholly outside this — seven of its
    # paths are tracked, `issues.jsonl` included — so a `bd` write during a run
    # is real drift and the post-run recheck will say so (mdnc R1). The note
    # says which, because the previous wording sent a reader looking for the
    # cause somewhere it could not be.
    BYTES_NOTE="sha256 $HOST_DIGEST over $BYTES_COUNTS (tracked paths only: node_modules, .claude/.qa-tracking and the gitignored half of .beads are outside the digest; the TRACKED .beads/*.jsonl are inside it, so do not run bd while a tier runs)"
else
    refuse "the container is NOT seeing this working tree" \
        "host      sha256 $HOST_DIGEST" \
        "container sha256 $CONTAINER_DIGEST" \
        "A mount that does not carry your bytes makes every tier result below meaningless, so the run stops here."
fi

# --- run the tiers ---------------------------------------------------------
# Each tier is one container. Separate containers rather than one shell running
# both, so a tier that wedges cannot take the other's result with it and the
# per-tier rc is the container's own.
tier_runner() {
    case "$1" in
        l1) printf '%s/.claude/scripts/tests/run-tests.sh' "$CONTAINER_REPO" ;;
        l2) printf '%s/.claude/tests/component/run.sh' "$CONTAINER_REPO" ;;
    esac
}

run_tier() {
    local tier="$1" runner
    runner=$(tier_runner "$tier")
    printf '\n=== Linux %s: %s ===\n' "$tier" "$runner"
    set -- run --rm
    [ -n "$PLATFORM" ] && set -- "$@" --platform "$PLATFORM"
    set -- "$@" -v "$REPO_ROOT:$CONTAINER_REPO:ro" -e "CLAUDE_PROJECT_DIR=$CONTAINER_REPO"
    # STRICT_SECTIONS is an L1 concept (the L2 runner reads no such variable),
    # but it is exported for both so a future L2 arm inherits the same policy
    # rather than a silently different one.
    [ "$STRICT" = "1" ] && set -- "$@" -e "STRICT_SECTIONS=1"
    set -- "$@" "$IMAGE" bash "$runner"
    [ -n "$FILTER" ] && set -- "$@" --filter "$FILTER"
    "$DOCKER_BIN" "$@"
}

RESULT_L1="NOT RUN"; RC_L1="-"; NOTE_L1="not requested (pass --tiers l1,l2)"
RESULT_L2="NOT RUN"; RC_L2="-"; NOTE_L2="not requested (pass --tiers l1,l2)"
WORST=0
ABORTED=0

# DOCKER'S OWN FAILURES ARE NOT TIER FAILURES (claude-workflow-plugin-mdnc
# R1-F4). `docker run` returns 125 when the run itself failed (a bad flag, an
# unavailable platform, an OOM at start), 126 when the command could not be
# invoked, and 127 when it was not found in the image. The tier runners exit 0,
# 1 or 2 and nothing else, so these three are unambiguously "the container never
# got as far as the tier". Scoring them as `RAN` + rc 1 claimed a measurement
# that did not happen — the same category confusion as an unmeasured mount
# exiting 0, pointing the other way. It errs toward a FALSE RED, which is the
# safer direction and still wrong: a false red sends someone to debug a test
# suite that never executed.
is_docker_infra_rc() {
    case "$1" in
        125|126|127) return 0 ;;
        *)           return 1 ;;
    esac
}

for tier in $REQUESTED; do
    if [ "$ABORTED" = "1" ]; then
        case "$tier" in
            l1) NOTE_L1="skipped: an earlier tier failed and --keep-going was not given" ;;
            l2) NOTE_L2="skipped: an earlier tier failed and --keep-going was not given" ;;
        esac
        continue
    fi
    rc=0
    run_tier "$tier" || rc=$?
    if is_docker_infra_rc "$rc"; then
        note="docker itself failed (rc $rc) — the container never reached $(tier_runner "$tier"); this tier was NOT measured"
        case "$tier" in
            l1) RESULT_L1="NOT RUN"; RC_L1="$rc"; NOTE_L1="$note" ;;
            l2) RESULT_L2="NOT RUN"; RC_L2="$rc"; NOTE_L2="$note" ;;
        esac
        # Deliberately NOT folded into WORST: WORST is the worst TIER outcome,
        # and this tier produced none. The requested-but-NOT-RUN check below is
        # what turns this into exit 2.
        [ "$KEEP_GOING" = "0" ] && ABORTED=1
        continue
    fi
    case "$tier" in
        l1) RESULT_L1="RAN"; RC_L1="$rc"; NOTE_L1="$(tier_runner l1)${FILTER:+ --filter $FILTER}" ;;
        l2) RESULT_L2="RAN"; RC_L2="$rc"; NOTE_L2="$(tier_runner l2)${FILTER:+ --filter $FILTER}" ;;
    esac
    [ "$rc" -gt "$WORST" ] && WORST="$rc"
    if [ "$rc" -ne 0 ] && [ "$KEEP_GOING" = "0" ]; then
        ABORTED=1
    fi
done

# --- did the tree move UNDER the run? --------------------------------------
# A READ-ONLY mount stops the CONTAINER writing to your checkout. It does not
# stop YOU: the mount is live, so an edit made on the host while a tier is
# running is visible to the very next spec that opens the file, and the run then
# reports a verdict for bytes that never existed as a whole.
#
# THIS IS NOT HYPOTHETICAL — it happened on this driver's second run. Editing
# verify-before-stop.sh while the L2 tier was mid-flight made the L2
# verify-before-stop spec fail 13 assertions in the container; the identical
# spec, re-run on the host against the settled bytes, passed 220/220. Without
# this check the only evidence was a wrong result that looked exactly like a
# regression, which is the most expensive shape a false red can take.
#
# So the digest is taken again at the end and compared with the one taken at the
# start. A mismatch does not fail the tiers — they already ran, and their output
# is real — it MARKS THE RESULT as measured over a moving tree, which is the one
# thing the reader has to know before believing it. Same discipline the repo
# applies to timing runs (LESSONS.md: stop measuring under concurrent writers).
#
# DRIFT IS ITS OWN STATUS, not a value of BYTES_STATUS, and that separation is a
# fix rather than tidiness (claude-workflow-plugin-mdnc R1-F2). This block used
# to be gated on `BYTES_STATUS = MATCH`, so the one condition that already
# failed open — the mount check being unable to RUN — ALSO switched off the
# moved-under-the-run detector, and the driver shipped that detector precisely
# because it had bitten. The two questions are independent: "does the container
# see my bytes" needs BOTH sides to answer, while "did my bytes move" needs only
# the HOST side, which is a strictly weaker precondition. Gating the weaker
# question on the stronger one's success is what made a single missing digest
# disable two checks at once.
DRIFT_STATUS="UNCHECKED"
DRIFT_NOTE="the host-side digest was unavailable, so the tree could not be re-read after the run"
BYTES_AFTER=""
if [ -n "$HOST_DIGEST" ]; then
    BYTES_AFTER=$(bash "$HERE/repo-bytes.sh" "$REPO_ROOT" 2>/dev/null | awk '$1 == "digest" { print $2 }')
    if [ -z "$BYTES_AFTER" ]; then
        DRIFT_STATUS="UNCHECKED"
        DRIFT_NOTE="the post-run re-read produced no digest, so drift could not be ruled out"
    elif [ "$BYTES_AFTER" != "$HOST_DIGEST" ]; then
        DRIFT_STATUS="MOVED UNDER THE RUN"
        DRIFT_NOTE="the tracked tree changed WHILE the tiers were running: sha256 $HOST_DIGEST at start, $BYTES_AFTER at end. The mount is live, so specs opened different bytes at different moments and NO verdict below describes a single tree. Re-run without editing the checkout."
    else
        DRIFT_STATUS="STABLE"
        DRIFT_NOTE="the tracked tree is byte-identical before and after the run"
    fi
fi

# --- the report ------------------------------------------------------------
printf '\n=== Linux tier report ===\n'
printf '  image        %s  (id %s, %s)\n' "$IMAGE" "$(printf '%s' "$IMAGE_ID" | cut -c1-19)" "$BUILD_NOTE"
printf '  base         %s\n' "$BASE_IMAGE"
printf '  daemon       %s, %s, arch %s%s\n' "$SERVER_OS" "$SERVER_VERSION" "$SERVER_ARCH" \
    "${PLATFORM:+, --platform $PLATFORM}"
printf '  repo         %s -> %s  (bind mount, READ-ONLY)\n' "$REPO_ROOT" "$CONTAINER_REPO"
printf '  bytes        %s  %s\n' "$BYTES_STATUS" "$BYTES_NOTE"
printf '  drift        %s  %s\n' "$DRIFT_STATUS" "$DRIFT_NOTE"
printf '  strictness   %s\n' \
    "$([ "$STRICT" = "1" ] && printf 'STRICT_SECTIONS=1 (as the CI l1-unit job sets it)' || printf 'STRICT_SECTIONS unset (--no-strict)')"
printf '  ------------------------------------------------------------------\n'
printf '  %-5s %-8s %-4s %s\n' "TIER" "STATUS" "rc" "WHAT"
printf '  %-5s %-8s %-4s %s\n' "l1" "$RESULT_L1" "$RC_L1" "$NOTE_L1"
printf '  %-5s %-8s %-4s %s\n' "l2" "$RESULT_L2" "$RC_L2" "$NOTE_L2"
printf '  ------------------------------------------------------------------\n'
printf '  NOT RUN is never a pass. A tier is measured on Linux only where its\n'
printf '  row above reads RAN.\n'

# --- the verdict, in precedence order --------------------------------------
# EVERY exit-2 CONDITION REACHES THIS BLOCK. The rule the driver's contract
# states is that 2 means "the bar was not measured", and the only way that stays
# true is if each way of failing to measure ends here rather than in a report
# row. Precedence runs most-specific-first, and the losing facts are still
# printed, because a reader who is told the run was inconclusive still needs to
# know a tier failed.
#
# `tier_outcome_phrase` exists so the tier result is never DROPPED by a verdict
# that is about something else — the shape 3.4b in linux-tier-driver.test.sh
# pins.
tier_outcome_phrase() {
    if [ "$WORST" -eq 0 ]; then
        printf 'every tier that ran, passed'
    else
        printf 'a tier that ran also FAILED (worst rc=%s)' "$WORST"
    fi
}

# 1. A requested tier that did not run at all — including one where docker
#    itself failed before the runner started.
for tier in $REQUESTED; do
    case "$tier" in
        l1) [ "$RESULT_L1" = "RAN" ] || { printf '\nVERDICT: INCOMPLETE — l1 was requested and did not run (%s)\n' "$NOTE_L1"; exit 2; } ;;
        l2) [ "$RESULT_L2" = "RAN" ] || { printf '\nVERDICT: INCOMPLETE — l2 was requested and did not run (%s)\n' "$NOTE_L2"; exit 2; } ;;
    esac
done

# 2. The tree moved while the tiers were running: the output is real but does
#    not describe one tree.
if [ "$DRIFT_STATUS" = "MOVED UNDER THE RUN" ]; then
    printf '\nVERDICT: INCONCLUSIVE — the checkout was edited while the tiers were running.\n'
    printf '  %s\n' "$DRIFT_NOTE"
    printf '  (%s.)\n' "$(tier_outcome_phrase)"
    printf '  The tier output above is real, but it does not describe one tree. Re-run.\n'
    exit 2
fi

# 3. The mount could not be VERIFIED. Not a mismatch — a mismatch already
#    refused above — but a check that could not be performed, which leaves the
#    "real bytes, not a copy" claim unbacked. Exiting 0 here is the R1-F2 false
#    green: the tiers pass, the verdict reads as an unqualified pass, and the
#    exit code carries none of the doubt.
if [ "$BYTES_STATUS" != "MATCH" ]; then
    printf '\nVERDICT: INCOMPLETE — the mount was not verified (bytes %s).\n' "$BYTES_STATUS"
    printf '  %s\n' "$BYTES_NOTE"
    printf '  (%s.)\n' "$(tier_outcome_phrase)"
    printf '  The tier output above is real, but nothing here proves the container ran YOUR bytes.\n'
    printf '  Re-run once repo-bytes.sh can answer on both sides, or read the rows above as unverified.\n'
    exit 2
fi

# 4. The drift check itself could not run, with a verified mount. Weaker than 2
#    and 3 — the mount WAS verified at the start — but still an unmeasured bar.
if [ "$DRIFT_STATUS" != "STABLE" ]; then
    printf '\nVERDICT: INCOMPLETE — the mount matched, but drift could not be ruled out (%s).\n' "$DRIFT_STATUS"
    printf '  %s\n' "$DRIFT_NOTE"
    printf '  (%s.)\n' "$(tier_outcome_phrase)"
    exit 2
fi

if [ "$WORST" -eq 0 ]; then
    printf '\nVERDICT: every requested tier ran on Linux and passed.\n'
    exit 0
fi
printf '\nVERDICT: a requested tier ran on Linux and FAILED (worst rc=%s). Read the tier output above.\n' "$WORST"
exit 1

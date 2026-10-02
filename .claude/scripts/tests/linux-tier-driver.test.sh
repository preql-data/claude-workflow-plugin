#!/bin/bash
# linux-tier-driver.test.sh — L1 unit fixture for .claude/tests/linux/run-linux-tier.sh.
#
# WHY THIS TIER, AND WHY IT EXISTS AT ALL. `run-linux-tier.sh` shipped four new
# checks — mount identity, mid-run drift, stale-image detection, and
# tier-status/exit discipline — with no negative control and no UNPAIRED
# declaration, and the very first thing a control found was a false green: when
# the byte verification could not RUN (as opposed to running and disagreeing)
# the driver fell through, printed the unqualified verdict `every requested tier
# ran on Linux and passed`, and exited 0. A target whose stated purpose is
# "every failure mode is loud" cannot ship without a leg that watches a failure
# mode being loud. That is `.claude/tests/README.md`'s pairing requirement, and
# this file is it (claude-workflow-plugin-mdnc R1-F2/F3/F4).
#
# HOW IT DRIVES THE DRIVER WITHOUT DOCKER. `run-linux-tier.sh` reads its docker
# binary from `${DOCKER:-docker}`, a seam it already had by design. Every cell
# below runs the REAL driver bytes with `DOCKER=` pointed at a stub that records
# its argv and returns whatever the cell configures. Nothing here re-implements
# the driver; a copy of its logic in this file would be a second definition free
# to drift from the one the operator runs.
#
# AND WITHOUT HASHING THE WHOLE REPO. The driver derives `REPO_ROOT` from its
# own location (`$HERE/../../..`), so each cell gets a THREE-FILE git repo with
# the three tier files copied into `.claude/tests/linux/`. `repo-bytes.sh` is
# the real one, running for real, over a tree small enough to hash twice per
# cell without the spec needing a timeout budget.
#
# EVERY CELL IS A PAIR. A leg asserting "exit 2 when X" is satisfiable by a
# driver that exits 2 always, so each refusal is driven beside the same cell
# with X removed, which must exit 0 (or 1) and print the unqualified verdict.
#
# Sections:
#   1  the stub, the fixture, and their own preconditions
#   2  MOUNT IDENTITY — a digest disagreement refuses; agreement does not
#   3  CANNOT MEASURE — a byte check that could not RUN reaches the exit code
#      and the verdict line, on either side, and does not disable the drift
#      detector (R1-F2)
#   4  MID-RUN DRIFT — a tree edited under the run is INCONCLUSIVE, including
#      when the byte check itself was unmeasurable
#   5  TIER STATUS AND EXIT DISCIPLINE — 0 ran-and-passed, 1 ran-and-failed,
#      2 could-not-run; docker's own infrastructure rcs are could-not-run
#      rather than a tier failure (R1-F4)
#   6  STALE IMAGE — a label/Dockerfile mismatch rebuilds, a match does not,
#      and an unmeasurable digest says UNCHECKED instead of claiming a match
#   7  WHAT THE DIGEST COVERS — tracked in, untracked out, measured rather than
#      described, because the report line describing it was wrong
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
TIER_DIR="$PROJECT_DIR/.claude/tests/linux"
DRIVER="$TIER_DIR/run-linux-tier.sh"

if [ ! -f "$DRIVER" ]; then
    printf 'linux-tier-driver.test: driver under test missing: %s\n' "$DRIVER" >&2
    exit 2
fi
if ! command -v git >/dev/null 2>&1; then
    printf 'linux-tier-driver.test: git is required (the driver hashes a tracked set)\n' >&2
    exit 2
fi

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

assert_contains() {
    local name="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    missing needle: %s\n    in: %s\n' "$name" "$needle" "$file"
        sed -n '1,200p' "$file" 2>/dev/null | sed 's/^/      | /'
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    forbidden needle present: %s\n    in: %s\n' "$name" "$needle" "$file"
        sed -n '1,200p' "$file" 2>/dev/null | sed 's/^/      | /'
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    fi
}

WORK=$(mktemp -d -t linux-tier-driver.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. THE STUB, THE FIXTURE, AND THEIR PRECONDITIONS
# ---------------------------------------------------------------------------
# THE STUB IS ~70 LINES because the driver only ever asks docker five things:
# is the daemon there, does the image exist, what label does it carry, build,
# and run. `run` is the only one that needs disambiguating, and the driver's own
# argv does it: the repo-bytes invocation ends in `.../repo-bytes.sh <root>`
# while a tier invocation ends in the tier runner's path.
STUB="$WORK/docker-stub"
cat > "$STUB" <<'STUB_EOF'
#!/bin/bash
# Recorded docker stub. Configuration arrives by environment so a cell can vary
# one fact at a time; every invocation is appended to $STUB_LOG argv-per-line.
set -u
{ printf 'INVOKE'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$STUB_LOG"

case "${1:-}" in
    info)
        [ "${STUB_INFO_RC:-0}" = "0" ] || { printf 'stub: daemon unreachable\n' >&2; exit "${STUB_INFO_RC}"; }
        case "${3:-}" in
            '{{.ServerVersion}}')   printf 'stub-27.0.0\n' ;;
            '{{.Architecture}}')    printf 'aarch64\n' ;;
            '{{.OperatingSystem}}') printf 'Stub Linux\n' ;;
            *)                      printf 'stub\n' ;;
        esac
        exit 0
        ;;
    image)
        # `image inspect --format <fmt> <img>` or `image inspect <img>`
        if [ "${3:-}" = "--format" ]; then
            case "${4:-}" in
                '{{.Id}}') printf 'sha256:stubimageid0000000000\n'; exit 0 ;;
                *)         printf '%s\n' "${STUB_IMAGE_LABEL:-}"; exit 0 ;;
            esac
        fi
        [ "${STUB_IMAGE_EXISTS:-1}" = "1" ] || { printf 'stub: no such image\n' >&2; exit 1; }
        printf '[{"Id":"sha256:stubimageid0000000000"}]\n'
        exit 0
        ;;
    build)
        printf 'stub: build invoked\n'
        exit "${STUB_BUILD_RC:-0}"
        ;;
    run)
        # The last non-flag argument tells us which of the two runs this is.
        _last=""
        for a in "$@"; do _last="$a"; done
        case " $* " in
            *repo-bytes.sh*)
                # The tree may be asked to move under the run BEFORE the tier
                # container is even reached; drift is applied on the tier call.
                printf '%s' "${STUB_BYTES_OUT:-}"
                exit "${STUB_BYTES_RC:-0}"
                ;;
            *)
                if [ -n "${STUB_DRIFT_FILE:-}" ]; then
                    printf 'moved under the run\n' >> "$STUB_DRIFT_FILE"
                fi
                if [ -n "${STUB_BREAK_GIT:-}" ] && [ -d "$STUB_BREAK_GIT" ]; then
                    mv "$STUB_BREAK_GIT" "$STUB_BREAK_GIT.off"
                fi
                printf 'stub: tier runner would run here (%s)\n' "$_last"
                exit "${STUB_TIER_RC:-0}"
                ;;
        esac
        ;;
esac
printf 'stub: unhandled docker subcommand: %s\n' "${1:-}" >&2
exit 64
STUB_EOF
chmod +x "$STUB"

# mk_fixture <dir> [--no-git] — a minimal tracked tree carrying the REAL tier
# files, so the driver's REPO_ROOT ($HERE/../../..) is this tree and repo-bytes
# hashes three files instead of the whole plugin.
mk_fixture() {
    local root="$1" nogit="${2:-}"
    mkdir -p "$root/.claude/tests/linux" "$root/.claude/scripts/tests" "$root/.claude/tests/component"
    cp "$TIER_DIR/run-linux-tier.sh" "$TIER_DIR/repo-bytes.sh" "$TIER_DIR/Dockerfile" \
       "$root/.claude/tests/linux/"
    printf '# fixture\n' > "$root/README.md"
    printf '#!/bin/bash\nexit 0\n' > "$root/.claude/scripts/tests/run-tests.sh"
    printf '#!/bin/bash\nexit 0\n' > "$root/.claude/tests/component/run.sh"
    if [ "$nogit" != "--no-git" ]; then
        git -C "$root" init -q
        git -C "$root" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
        git -C "$root" -c user.email=t@t -c user.name=t commit -q -m fixture >/dev/null 2>&1
    fi
}

# host_digest <root> — what the driver's host-side call will produce.
host_digest() { bash "$1/.claude/tests/linux/repo-bytes.sh" "$1" 2>/dev/null | awk '$1 == "digest" { print $2 }'; }

# bytes_payload <digest> — a well-formed repo-bytes.sh stdout carrying <digest>.
bytes_payload() { printf 'digest %s\nfiles  3\nlinks  0\n' "$1"; }

# run_driver <out-file> <root> [driver args...] — one cell. Returns the rc.
# Every STUB_* knob is reset here and set by the caller through the environment
# of THIS function, so a cell cannot inherit a neighbour's configuration.
run_driver() {
    local out="$1" root="$2"; shift 2
    STUB_LOG="$WORK/stub.log" \
    DOCKER="$STUB" \
    STUB_INFO_RC="${CELL_INFO_RC:-0}" \
    STUB_IMAGE_EXISTS="${CELL_IMAGE_EXISTS:-1}" \
    STUB_IMAGE_LABEL="${CELL_IMAGE_LABEL:-}" \
    STUB_BUILD_RC="${CELL_BUILD_RC:-0}" \
    STUB_BYTES_OUT="${CELL_BYTES_OUT:-}" \
    STUB_BYTES_RC="${CELL_BYTES_RC:-0}" \
    STUB_TIER_RC="${CELL_TIER_RC:-0}" \
    STUB_DRIFT_FILE="${CELL_DRIFT_FILE:-}" \
    STUB_BREAK_GIT="${CELL_BREAK_GIT:-}" \
        bash "$root/.claude/tests/linux/run-linux-tier.sh" "$@" > "$out" 2>&1
    return $?
}

# cell_reset — clear every knob. Called at the top of each cell so the
# configuration of a cell is exactly what that cell sets.
cell_reset() {
    CELL_INFO_RC=0; CELL_IMAGE_EXISTS=1; CELL_IMAGE_LABEL=""; CELL_BUILD_RC=0
    CELL_BYTES_OUT=""; CELL_BYTES_RC=0; CELL_TIER_RC=0; CELL_DRIFT_FILE=""
    CELL_BREAK_GIT=""
}
cell_reset

FIX="$WORK/fix-ok"
mk_fixture "$FIX"
: > "$WORK/stub.log"

DOCKERFILE_SHA=$( { command -v sha256sum >/dev/null 2>&1 && sha256sum < "$TIER_DIR/Dockerfile"; } \
                  || shasum -a 256 < "$TIER_DIR/Dockerfile" )
DOCKERFILE_SHA="${DOCKERFILE_SHA%% *}"
HOST_D=$(host_digest "$FIX")

assert_eq "1.1 precondition: the fixture is a git repo the real repo-bytes.sh can digest" "64" \
    "${#HOST_D}"
assert_eq "1.2 precondition: the driver copy under test is byte-identical to the shipped one" "identical" \
    "$(cmp -s "$DRIVER" "$FIX/.claude/tests/linux/run-linux-tier.sh" && echo identical || echo differs)"
assert_eq "1.3 precondition: the Dockerfile digest is computable on this host" "64" \
    "${#DOCKERFILE_SHA}"
# shellcheck disable=SC2016  # matching the LITERAL text `${DOCKER:-docker}` in
# the driver's source, not expanding it.
assert_eq "1.4 precondition: the stub is what the driver will call (the \${DOCKER:-docker} seam)" "1" \
    "$(grep -c 'DOCKER_BIN="\${DOCKER:-docker}"' "$DRIVER" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# 2. MOUNT IDENTITY
# ---------------------------------------------------------------------------
# The design's claim is that the mount is "a CHECKED claim rather than an
# asserted one". Both halves of that are legs: a disagreement must stop the run,
# and an agreement must not.
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
run_driver "$WORK/c-match.out" "$FIX" --tiers l1; RC=$?
assert_eq "2.1 bytes AGREE + tier passes -> exit 0" "0" "$RC"
assert_contains "2.1b ...and the report says MATCH" "bytes        MATCH" "$WORK/c-match.out"
assert_contains "2.1c ...with the unqualified pass verdict" \
    "VERDICT: every requested tier ran on Linux and passed" "$WORK/c-match.out"

cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "0000000000000000000000000000000000000000000000000000000000000000")"
run_driver "$WORK/c-mismatch.out" "$FIX" --tiers l1; RC=$?
assert_eq "2.2 NEGATIVE CONTROL: bytes DISAGREE -> exit 2" "2" "$RC"
assert_contains "2.2b ...named as a refusal, not a failure" \
    "the container is NOT seeing this working tree" "$WORK/c-mismatch.out"
assert_contains "2.2c ...and says a skip is not a pass" \
    "This is a SKIP, not a pass" "$WORK/c-mismatch.out"
assert_not_contains "2.2d ...and never prints the pass verdict" \
    "every requested tier ran on Linux and passed" "$WORK/c-mismatch.out"

# ---------------------------------------------------------------------------
# 3. CANNOT MEASURE (claude-workflow-plugin-mdnc R1-F2)
# ---------------------------------------------------------------------------
# The driver's contract: "2 could not run ... i.e. the bar was not measured".
# A byte MISMATCH already refused. The case that fell through was CANNOT
# MEASURE — repo-bytes yielding no digest on either side — where the tiers ran,
# every one passed, and the driver printed the unqualified pass verdict and
# exited 0. The claim silently reverted to the asserted one the design rejects,
# and the exit code (the only thing `make test-linux && ...` or CI reads) said
# nothing at all.
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT=""            # container side yields nothing
run_driver "$WORK/c-nocont.out" "$FIX" --tiers l1; RC=$?
assert_eq "3.1 container side cannot measure + tier PASSES -> exit 2 (not 0)" "2" "$RC"
assert_contains "3.1b ...and the VERDICT LINE says so, not only a report row" \
    "VERDICT: INCOMPLETE — the mount was not verified" "$WORK/c-nocont.out"
assert_not_contains "3.1c ...and the unqualified pass verdict is NOT printed" \
    "VERDICT: every requested tier ran on Linux and passed" "$WORK/c-nocont.out"
assert_contains "3.1d ...while the tier's own outcome stays visible in the report" \
    "l1    RAN" "$WORK/c-nocont.out"

# The other side of the same condition: the HOST cannot measure. A non-git tree
# makes the real repo-bytes.sh exit 2 with no digest, which is the honest way to
# produce this rather than stubbing the script the driver is supposed to trust.
FIX_NOGIT="$WORK/fix-nogit"
mk_fixture "$FIX_NOGIT" --no-git
assert_eq "3.2 precondition: the non-git fixture really yields no host digest" "" \
    "$(host_digest "$FIX_NOGIT")"
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
run_driver "$WORK/c-nohost.out" "$FIX_NOGIT" --tiers l1; RC=$?
assert_eq "3.3 HOST side cannot measure + tier PASSES -> exit 2" "2" "$RC"
assert_contains "3.3b ...and names which side could not answer" \
    "repo-bytes.sh did not produce a digest" "$WORK/c-nohost.out"

# Cannot-measure must not be readable as "the tier failed", and a tier failure
# must not be readable as "we could not measure". When both are true the run is
# unmeasured — the same precedence the driver already gives MOVED UNDER THE RUN
# — and the verdict has to name both facts, or the reader loses one of them.
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT=""
CELL_TIER_RC=1
run_driver "$WORK/c-nocont-fail.out" "$FIX" --tiers l1; RC=$?
assert_eq "3.4 cannot measure + tier FAILS -> exit 2 (unmeasured dominates)" "2" "$RC"
assert_contains "3.4b ...and the verdict still reports the tier failure" \
    "worst rc=1" "$WORK/c-nocont-fail.out"

# NEGATIVE CONTROL for the whole section: the identical cell with the byte
# check able to run exits 1, so 3.4 is about the measurement and not about the
# tier rc.
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
CELL_TIER_RC=1
run_driver "$WORK/c-fail.out" "$FIX" --tiers l1; RC=$?
assert_eq "3.5 NEGATIVE CONTROL: byte check runs + tier FAILS -> exit 1" "1" "$RC"
assert_contains "3.5b ...with the ran-and-failed verdict" \
    "VERDICT: a requested tier ran on Linux and FAILED" "$WORK/c-fail.out"

# ---------------------------------------------------------------------------
# 4. MID-RUN DRIFT
# ---------------------------------------------------------------------------
# The detector exists because it bit: editing verify-before-stop.sh while L2 was
# mid-flight produced 13 bogus failures. The stub edits a TRACKED file during
# the tier container's turn, which is exactly when a human's editor would.
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
CELL_DRIFT_FILE="$FIX/README.md"
run_driver "$WORK/c-drift.out" "$FIX" --tiers l1; RC=$?
assert_eq "4.1 the tree moved under the run -> exit 2" "2" "$RC"
assert_contains "4.1b ...as INCONCLUSIVE rather than a tier failure" \
    "VERDICT: INCONCLUSIVE" "$WORK/c-drift.out"
assert_contains "4.1c ...naming the two digests" "MOVED UNDER THE RUN" "$WORK/c-drift.out"
git -C "$FIX" -c user.email=t@t -c user.name=t checkout -q -- README.md

# THE R1-F2 SECOND HALF. The recheck used to be gated on BYTES_STATUS = MATCH,
# so the very condition that already failed open ALSO switched the drift
# detector off. Here the container side cannot answer, the host side can, and
# the tree moves: the drift must still be detected.
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT=""
CELL_DRIFT_FILE="$FIX/README.md"
run_driver "$WORK/c-drift-unchecked.out" "$FIX" --tiers l1; RC=$?
assert_eq "4.2 drift is detected even when the MOUNT check could not run" "2" "$RC"
assert_contains "4.2b ...and the drift is named, not silently folded into the mount row" \
    "MOVED UNDER THE RUN" "$WORK/c-drift-unchecked.out"
git -C "$FIX" -c user.email=t@t -c user.name=t checkout -q -- README.md

# NEGATIVE CONTROL: the same cell without the edit is not INCONCLUSIVE.
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
run_driver "$WORK/c-nodrift.out" "$FIX" --tiers l1; RC=$?
assert_eq "4.3 NEGATIVE CONTROL: no edit -> exit 0" "0" "$RC"
assert_not_contains "4.3b ...and no drift is claimed" "MOVED UNDER THE RUN" "$WORK/c-nodrift.out"
assert_contains "4.3c ...and the drift row says it was actually checked" "drift        STABLE" "$WORK/c-nodrift.out"

# The drift check ITSELF being unable to run is the same category as the mount
# check being unable to run, so it lands in the same place: exit 2. The stub
# takes the fixture's .git away during the tier's turn, so the FIRST host read
# succeeded and the second cannot — which is exactly the shape a mid-run `git
# worktree` move or a vanished checkout produces.
mv "$FIX/.git" "$FIX/.git-probe"
DRIFT_PRECOND=$([ -z "$(host_digest "$FIX")" ] && echo yes || echo no)
mv "$FIX/.git-probe" "$FIX/.git"
assert_eq "4.4 precondition: taking .git away really does stop repo-bytes.sh answering" "yes" \
    "$DRIFT_PRECOND"
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
CELL_BREAK_GIT="$FIX/.git"
run_driver "$WORK/c-driftunk.out" "$FIX" --tiers l1; RC=$?
[ -d "$FIX/.git.off" ] && mv "$FIX/.git.off" "$FIX/.git"
assert_eq "4.5 the drift check could not run -> exit 2, even with the mount verified" "2" "$RC"
assert_contains "4.5b ...named as INCOMPLETE rather than folded into a pass" \
    "drift could not be ruled out" "$WORK/c-driftunk.out"

# ---------------------------------------------------------------------------
# 5. TIER STATUS AND EXIT DISCIPLINE
# ---------------------------------------------------------------------------
# A requested tier that did not run is exit 2, and an argument the driver cannot
# honour is exit 2 — never a quietly reduced run.
cell_reset
run_driver "$WORK/c-badtier.out" "$FIX" --tiers l1,l9; RC=$?
assert_eq "5.1 an unknown tier name refuses rather than running the subset" "2" "$RC"
assert_contains "5.1b ...naming it" "unknown tier 'l9'" "$WORK/c-badtier.out"

cell_reset
CELL_INFO_RC=1
run_driver "$WORK/c-nodaemon.out" "$FIX" --tiers l1; RC=$?
assert_eq "5.2 no reachable daemon -> exit 2" "2" "$RC"
assert_contains "5.2b ...as a named skip" "the docker daemon is not reachable" "$WORK/c-nodaemon.out"

# BOTH tiers requested, the first fails, --keep-going absent: the second must be
# reported NOT RUN and must not be scored as a pass.
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
CELL_TIER_RC=1
run_driver "$WORK/c-abort.out" "$FIX" --tiers l1,l2; RC=$?
assert_eq "5.3 a requested tier that did NOT run -> exit 2, not the tier's own 1" "2" "$RC"
assert_contains "5.3b ...named as INCOMPLETE" "VERDICT: INCOMPLETE — l2 was requested and did not run" "$WORK/c-abort.out"
assert_contains "5.3c ...and its row reads NOT RUN" "l2    NOT RUN" "$WORK/c-abort.out"

# R1-F4: DOCKER'S OWN FAILURES ARE NOT TIER FAILURES. 125 (the run itself
# failed), 126 (the command could not be invoked) and 127 (command not found)
# come from docker, not from the tier runner — which exits 0, 1 or 2 only. A
# container that never started reported as "a tier RAN and FAILED" is the same
# category confusion as R1-F2 pointing the other way: it errs toward a false
# red, but it is still a claim about a measurement that did not happen.
for infra_rc in 125 126 127; do
    cell_reset
    CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
    CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
    CELL_TIER_RC="$infra_rc"
    run_driver "$WORK/c-infra-$infra_rc.out" "$FIX" --tiers l1; RC=$?
    assert_eq "5.4 docker infrastructure rc $infra_rc -> exit 2 (could not run), not 1" "2" "$RC"
    assert_contains "5.4b rc $infra_rc: ...and the row does not claim the tier ran" \
        "l1    NOT RUN" "$WORK/c-infra-$infra_rc.out"
done
# NEGATIVE CONTROL: an rc the tier runner really does emit stays a tier failure.
for tier_rc in 1 2; do
    cell_reset
    CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
    CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
    CELL_TIER_RC="$tier_rc"
    run_driver "$WORK/c-tierrc-$tier_rc.out" "$FIX" --tiers l1; RC=$?
    assert_eq "5.5 NEGATIVE CONTROL: tier rc $tier_rc is a TIER outcome -> exit 1" "1" "$RC"
    assert_contains "5.5b rc $tier_rc: ...and the row says the tier RAN" \
        "l1    RAN" "$WORK/c-tierrc-$tier_rc.out"
done

# ---------------------------------------------------------------------------
# 6. STALE IMAGE
# ---------------------------------------------------------------------------
# The staleness check is here because it bit on the driver's second run: the
# Dockerfile gained a package, the image already existed, `auto` reused it, and
# the tier reported a result for bytes that were not being shipped.
cell_reset
CELL_IMAGE_LABEL="deadbeef"          # not the Dockerfile's digest
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
: > "$WORK/stub.log"
run_driver "$WORK/c-stale.out" "$FIX" --tiers l1; RC=$?
assert_eq "6.1 a stale image rebuilds and the run still completes" "0" "$RC"
assert_contains "6.1b ...a build really was invoked" "INVOKE [build]" "$WORK/stub.log"
assert_contains "6.1c ...and the report says which of the three states it was in" \
    "rebuilt (Dockerfile changed since the image was built)" "$WORK/c-stale.out"

cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"   # matches
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
: > "$WORK/stub.log"
run_driver "$WORK/c-fresh.out" "$FIX" --tiers l1; RC=$?
assert_eq "6.2 NEGATIVE CONTROL: a matching label does NOT rebuild" "0" "$RC"
assert_not_contains "6.2b ...no build was invoked" "INVOKE [build]" "$WORK/stub.log"
assert_contains "6.2c ...and the note says the digest was compared" \
    "reused (Dockerfile digest matches the image label)" "$WORK/c-fresh.out"

cell_reset
CELL_IMAGE_EXISTS=0
CELL_IMAGE_LABEL=""
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
: > "$WORK/stub.log"
run_driver "$WORK/c-absent.out" "$FIX" --tiers l1; RC=$?
assert_eq "6.3 an absent image is built" "0" "$RC"
assert_contains "6.3b ...and the note says so rather than claiming a comparison" \
    "built (was absent)" "$WORK/c-absent.out"

# R1-F4 (the report-line half). With no sha256 tool on PATH the digest is empty,
# the staleness test short-circuits, and the `auto` arm used to fall through to
# `reused (Dockerfile digest matches the image label)` — a report line asserting
# a check that never ran, which is the asserted-not-checked family this driver
# exists to eliminate.
#
# The PATH sandbox holds symlinks to everything the driver and repo-bytes.sh
# actually invoke, and deliberately NOT sha256sum / shasum. repo-bytes.sh needs
# a hasher too, so this cell ALSO cannot verify the mount — that is real, not an
# artefact, and it is why the assertion below reads the BUILD note rather than
# the exit code.
SANDBOX="$WORK/nosha-bin"
mkdir -p "$SANDBOX"
SANDBOX_OK=1
for t in bash awk sed grep cut head tr sort git readlink cat printf mktemp rm cmp; do
    p=$(command -v "$t" 2>/dev/null) || p=""
    if [ -n "$p" ]; then ln -sf "$p" "$SANDBOX/$t"; fi
done
for t in bash awk git; do
    [ -x "$SANDBOX/$t" ] || SANDBOX_OK=0
done
# ...and the HOST must have a hasher, or the cell proves nothing: DOCKERFILE_SHA
# would already be empty in every other cell too, and "the note says UNCHECKED"
# would be true for a reason that has nothing to do with the sandbox.
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    SANDBOX_OK=0
fi
SANDBOX_HAS_HASHER=no
if [ -e "$SANDBOX/sha256sum" ] || [ -e "$SANDBOX/shasum" ]; then SANDBOX_HAS_HASHER=yes; fi
assert_eq "6.4 precondition: the no-sha256 PATH sandbox is usable on this host" "1" "$SANDBOX_OK"
assert_eq "6.4b precondition: ...and it really has no hasher in it" "no" "$SANDBOX_HAS_HASHER"
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "$HOST_D")"
STUB_LOG="$WORK/stub.log" DOCKER="$STUB" \
STUB_INFO_RC=0 STUB_IMAGE_EXISTS=1 STUB_IMAGE_LABEL="$DOCKERFILE_SHA" \
STUB_BUILD_RC=0 STUB_BYTES_OUT="$CELL_BYTES_OUT" STUB_BYTES_RC=0 STUB_TIER_RC=0 STUB_DRIFT_FILE="" \
PATH="$SANDBOX" \
    bash "$FIX/.claude/tests/linux/run-linux-tier.sh" --tiers l1 > "$WORK/c-nosha.out" 2>&1
assert_contains "6.5 with no sha256 tool the note says UNCHECKED, not 'matches'" \
    "staleness UNCHECKED" "$WORK/c-nosha.out"
assert_not_contains "6.5b ...and never claims a digest match it did not compute" \
    "Dockerfile digest matches the image label" "$WORK/c-nosha.out"

# ---------------------------------------------------------------------------
# 7. WHAT THE DIGEST ACTUALLY COVERS
# ---------------------------------------------------------------------------
# The driver's report states the digest's scope in one line, and everything
# above trusts that line: the mount claim and the drift claim are only as good
# as "tracked paths, all of them". The line was WRONG when this spec was
# written — it said `.beads` was outside the digest, while seven `.beads/` paths
# are tracked in this repo, so a `bd` write during a run is real drift and the
# operator was pointed away from the cause. These legs pin the scope by
# measurement instead of by comment (claude-workflow-plugin-mdnc R1).
BASE_DIGEST=$(host_digest "$FIX")
printf 'transient\n' > "$FIX/untracked-scratch.txt"
mkdir -p "$FIX/.claude/.qa-tracking"
printf 'transient\n' > "$FIX/.claude/.qa-tracking/changed-files.txt"
assert_eq "7.1 an UNTRACKED file does not move the digest" "$BASE_DIGEST" "$(host_digest "$FIX")"
rm -f "$FIX/untracked-scratch.txt"
rm -rf "$FIX/.claude/.qa-tracking"

printf 'edited\n' >> "$FIX/README.md"
assert_eq "7.2 NEGATIVE CONTROL: a TRACKED file's content does move it" "differs" \
    "$([ "$(host_digest "$FIX")" = "$BASE_DIGEST" ] && echo same || echo differs)"
git -C "$FIX" -c user.email=t@t -c user.name=t checkout -q -- README.md
assert_eq "7.3 ...and restoring it restores the digest (so 7.2 was the edit, not the clock)" \
    "$BASE_DIGEST" "$(host_digest "$FIX")"

# The scope line the report prints must name the tracked-jsonl case rather than
# claiming .beads is outside the digest, because a reader debugging a MOVED
# verdict reads exactly this line.
cell_reset
CELL_IMAGE_LABEL="$DOCKERFILE_SHA"
CELL_BYTES_OUT="$(bytes_payload "$(host_digest "$FIX")")"
run_driver "$WORK/c-scope.out" "$FIX" --tiers l1; RC=$?
assert_eq "7.4 the scope cell still passes (so 7.5 reads a real report)" "0" "$RC"
assert_contains "7.5 the report's scope line names the TRACKED .beads paths" \
    "do not run bd while a tier runs" "$WORK/c-scope.out"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

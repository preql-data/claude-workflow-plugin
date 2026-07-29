#!/bin/bash
# upgrade-gate-compat.sh - L2 component spec for the QA GATE on a tree that was
# UPGRADED FROM v3.5 (v4.1 Phase U0 / claude-workflow-plugin-ehv).
#
# WHAT THIS PROVES
# ----------------
# installer-v3-upgrade.sh proves the v3.5 -> v4 upgrade puts the right FILES on
# disk. It says nothing about whether the GATE those files implement still works
# once they are there - and an upgrade is exactly where gate state is at risk,
# because a v3.5 install carries approval records written in a grammar that
# predates every v4 token. Two failure directions matter and they pull opposite
# ways:
#
#   TOO STRICT  a pre-v4 record (`QA-GATE APPROVED change_set_hash=<h>` with no
#               reviewed_by= / worktree= token) stops being recognised, so the
#               first Stop after the upgrade re-arms the gate over work that was
#               already reviewed. The worst version of this is a CLOSED task -
#               history the gate has no business re-litigating at all.
#   TOO LOOSE   the upgrade smuggles in a release path that does not exist in a
#               fresh v4 install. The forged bare `qa-approved` label is the
#               canonical one (llh.18 red-team P0).
#
# So this spec runs the REAL gate, with the REAL bd CLI, on a tree built by
# v3.5.0's OWN installer and then upgraded in place by the shipped installer
# with NO FLAGS. It pins retention in both directions, and adds the two
# upgrade-topology guards that nothing else covers (sections 5 and 6).
#
# ZERO production-code change is expected from it. Every assertion below
# describes behaviour that already exists; this is a RETENTION spec, and its job
# is to make a future deletion or "simplification" of that behaviour fail a test
# whose NAME says `upgrade`.
#
# WHY REAL bd HERE, AND WHY THE FLAGSHIP DELIBERATELY DOES NOT
# ------------------------------------------------------------
# installer-v3-upgrade.sh documents a deliberate deviation: it writes a fake-bd
# stub and skips `bd_required_or_skip`, because install.sh only ever asks bd for
# four things and that spec MUST run in CI (where there is no public bd
# installer to curl). This spec cannot make the same trade. Gate semantics are
# bd-bound repo-wide: the approval RECORD is a Beads comment, the release LABEL
# is a Beads label, `qa-gate.sh status` reads labels through bd, the review
# artifact is recorded as a Beads comment, and the whole point here is the
# interplay between those rows and the Stop hook. A stub would have to
# reimplement the half of Beads that the assertions actually measure, at which
# point the spec measures the stub.
#
# So: `bd_required_or_skip` + `mk_bd_shim` (the standard L2 conventions from
# lib/shim.sh and lib/fixture.sh), which means this spec SKIPS in CI exactly
# like every other bd-bound spec in the tier - by design. The flagship remains
# the CI guard for the upgrade path itself; this one is the dev-machine guard
# for the gate on top of it. The bd gate runs BEFORE the tag gate below for the
# same reason: in CI (bd absent, BD_SHIM_ONLY=1) we skip and never reach the
# tag check, and a hard tag failure there would be noise about an environment
# this spec has already declined to run in.
#
# mk_fixture is NOT used: it builds a symlink farm around the CURRENT plugin
# tree, and the subject here is a tree the INSTALLER produced. Its two
# load-bearing services are reproduced by hand and documented at the call sites
# (the bd wrapper, and cwd pinned into the fixture).
#
# SECTIONS (in run order; they share ONE upgraded fixture - see ORDERING)
#   1. Tag gate + upgraded fixture - v3.5.0's own installer, then the shipped
#      installer with no flags (auto-detection is part of the subject), then the
#      normalisation that makes gate assertions measurable at all.
#   2. Closed-task tolerance - a v3.5-format approval record on a CLOSED task
#      survives a session-start + Stop flow byte-for-byte. Never re-validated,
#      never re-blocked, not even when the same Stop blocks for other reasons.
#   3. Forgery still blocked - a bare `bd label add qa-approved` on a NEW task
#      does not release after the upgrade either.
#   4. The v4 release path - the same task, run legitimately, releases; the
#      record it writes carries reviewed_by= AND worktree=. 4b is the companion:
#      a PRE-v4 record on an OPEN task releases too, i.e. the two new tokens are
#      structurally OPTIONAL for the READER.
#   5. v1 `approved-baseline` fallback, RE-PINNED FROM THE UPGRADE TOPOLOGY.
#   6. Post-upgrade gate smoke - a task created after the upgrade round-trips
#      enter -> records -> approve -> Stop-release, and the upgraded approve
#      writes the v2 baseline format section 5 only READS.
#   7. META-TEST - section 4b's scenario with the `change_set_hash=` token
#      stripped BLOCKS instead of releasing.
#
# ORDERING (deliberate; one fixture, ~3.5s to build, so it is built once)
#   1 -> everything (nothing else builds a tree).
#   3 -> 4:   section 4 re-runs the gate legitimately on section 3's task, so
#             the same row goes forged-and-blocked -> reviewed-and-released.
#   4 -> 5:   section 5 needs NO active review cycle and no gate baseline of
#             either version; it clears both explicitly and asserts it.
#   5 -> 6:   section 5 restores the tree to clean, which section 6 asserts as a
#             precondition.
#   4b -> 7:  the META is 4b's scenario minus one token, re-seeded on a parallel
#             task, so 4b must have established the positive first.
# Every cross-section dependency above is re-asserted as a precondition where it
# is consumed, so a reordering breaks loudly instead of silently.
#
# RUNTIME. One v3.5 install + one upgrade (~3.5s), one session-start, three
# legitimate gate cycles and ~14 Stop fires. No network, no LLM, and no
# code-graph server: CODE_GRAPH_MCP_BIN is pointed at a nonexistent path (a
# documented seam of impact-report.sh) so the impact report degrades to
# server=absent immediately. That is what every mk_fixture-based spec gets for
# free - those fixtures have no .claude/mcp/ at all - whereas an INSTALLED tree
# does ship the server entry point but not its node_modules, so leaving it alone
# would mean paying for a node boot that can only fail. The transport itself is
# covered by code-graph-mcp.sh; the change_set_hash is identical either way.
#
# KNOWN DEFECT, NOT PINNED HERE (found while writing this spec; filed
# separately, evidence-before-fix): `write_gate_baseline` in qa-gate.sh reports
# FAILURE and writes no file when `git status --porcelain` is EMPTY, because the
# brace group that composes the file ends with `[ -n "$status_out" ] && printf
# ...` and that test is what supplies the group's exit status. Consequence for
# this spec: nothing here may assume a baseline exists merely because
# session-start / enter / approve ran on a clean tree. Section 5 deletes both
# baseline files and asserts their absence rather than relying on it, and
# section 6 approves with real dirt on disk so its v2-write assertion measures
# the writer rather than that bug. The gate's DECISIONS are unaffected (with a
# clean tree there is nothing to subtract), so this is not pinned as behaviour
# either way - it is called out so a reader does not mistake the avoidance for
# an accident.

set -u

# INSTALLER FLAGS FOR THE L2 TIER (v4.1 / C0b) -------------------------------
# install.sh now does two things after the copy loops that this spec has no
# business paying for:
#   1. `npm ci` per MCP server IN THE TARGET. That needs the npm registry, so
#      leaving it on would make assertions about FILE COPYING fail on an
#      offline machine — a network dependency in the component tier.
#   2. workflow-doctor.sh, exiting 3 ("installed, verification FAILED") when a
#      functional check does not pass. This spec's fixtures are not built to
#      satisfy eleven functional checks, and every `install.sh exits 0`
#      assertion here would start reporting a fixture gap as an installer bug.
# Both are covered for real by `make install-test`, which installs into a
# tempdir and requires a fully green doctor — that is the surface that proves
# dependency provisioning works, and it is now expected to be GREEN.
# Exported once so every installer invocation in this file inherits them
# without a per-call-site flag; the v3.5-era installer some of these specs also
# run ignores unknown environment variables.
export CWP_SKIP_MCP_DEPS=1
export CWP_SKIP_VERIFY=1

PLUGIN_ROOT=$(plugin_root)
TAG="v3.5.0"
ISO='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# The v3.5 approval record this spec plants on the closed task carries a hash
# that is deliberately NOT any hash the current tree can produce: the claim
# under test is "closed tasks are not re-validated", so the record must be one
# that WOULD fail a hash comparison if anything ever ran one on it. Hyphens keep
# it inside the readers' `[A-Za-z0-9-]+` token grammar.
LEGACY_CLOSED_HASH="v35legacyclosedhash-000000000000000000000000000000000000"

# ===========================================================================
# Section 1: tag gate + the upgraded fixture
# ===========================================================================

# bd FIRST (see header). On a dev machine this returns; in CI it prints one
# SKIPPED line and exits 0.
bd_required_or_skip

WORK=$(mktemp -d -t cwp-upgrade-gate.XXXXXX)
__COMPONENT_FIXTURES_TO_CLEAN+=("$WORK")

SRC35="$WORK/src35"
T="$WORK/upgraded"

# yesno <command...> - "yes" when the command succeeds, "no" when it does not.
# Copied from installer-v3-upgrade.sh rather than shared: that spec is the
# flagship and is not modified by this task. The wrapped command's output is
# discarded on purpose - this runs inside $( ), so a command that PRINTS as well
# as returning a status (git rev-parse echoes the sha) would otherwise prepend
# its stdout to the yes/no.
yesno() {
    if "$@" >/dev/null 2>&1; then printf 'yes'; else printf 'no'; fi
}

TAG_PRESENT=$(yesno git -C "$PLUGIN_ROOT" rev-parse -q --verify "$TAG^{commit}")
if [ "$TAG_PRESENT" != "yes" ]; then
    # Same convention as the flagship: in CI a silent skip would let the path
    # rot, so it is a hard failure there. (Unreachable today - the bd gate above
    # already skipped - but correct the day a CI runner grows a bd.)
    if [ "${CI:-}" = "true" ]; then
        assert_eq "upgrade-gate 1: $TAG tag reachable (CI must fetch tags)" \
            "yes" "$TAG_PRESENT"
        printf '  diagnostic: git -C %s rev-parse %s^{commit} failed.\n' "$PLUGIN_ROOT" "$TAG"
        printf '  diagnostic: the l2-component job needs actions/checkout with fetch-depth: 0.\n'
        exit 1
    fi
    printf 'SKIPPED: upgrade-gate-compat.sh (%s tag unavailable: shallow clone or tagless worktree)\n' "$TAG"
    exit 0
fi
assert_eq "upgrade-gate 1: $TAG tag reachable" "yes" "$TAG_PRESENT"

# The bd wrapper. mk_bd_shim writes $WORK/bin/bd, a wrapper that exec's the REAL
# bd with --no-daemon injected (Beads' daemon-autostart races on freshly-init'd
# tempdir DBs). Prepended to PATH so the installers' own `bd init` /
# `bd hooks install` / `bd doctor` calls, and every call the hook scripts make,
# all go through it.
mk_bd_shim "$WORK" >/dev/null
export PATH="$WORK/bin:$PATH"

# --- v3.5.0's own installer -------------------------------------------------
# A genuine v3.5 tree, not a hand-rolled "v3.5-shaped" one: a fixture built to
# match the code under test can hide a detection bug in that code.
mkdir -p "$SRC35"
ARCHIVE_RC=0
( set -o pipefail; git -C "$PLUGIN_ROOT" archive "$TAG" | tar -x -C "$SRC35" ) || ARCHIVE_RC=$?
assert_eq "upgrade-gate 1: git archive $TAG extracts cleanly" "0" "$ARCHIVE_RC"
assert_eq "upgrade-gate 1: the extracted tag tree carries its own install.sh" \
    "yes" "$(yesno test -f "$SRC35/install.sh")"

mkdir -p "$T"
(
    cd "$T" || exit 1
    git init -q >/dev/null 2>&1 || true
    # An empty commit keeps `git rev-parse HEAD` consumers happy and stops the
    # installer's "Initialize git repository?" prompt path (which would also
    # write a .gitignore this spec wants to own).
    git -c user.email=test@example.com -c user.name=test \
        commit --allow-empty -q -m "v3.5 baseline" >/dev/null 2>&1 || true
)
V35_RC=0
bash "$SRC35/install.sh" --mode=1 "$T" </dev/null >"$WORK/install-v35.log" 2>&1 || V35_RC=$?
if [ "$V35_RC" -ne 0 ]; then
    printf '  diagnostic: v3.5.0 installer exited %s; tail of log:\n' "$V35_RC"
    tail -15 "$WORK/install-v35.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "upgrade-gate 1: v3.5.0's own installer exits 0 with the real bd on PATH" \
    "0" "$V35_RC"
assert_eq "upgrade-gate 1: the fixture manifest declares version 3.5.0 pre-upgrade" \
    "3.5.0" "$(jq -r '.version // empty' "$T/.claude-plugin/plugin.json" 2>/dev/null || echo "")"
# review-check.sh is the v4 independent-review predicate. Its ABSENCE here is
# what makes sections 4 and 6 meaningful: the review-discipline re-check they
# exercise at Stop time is a capability the pre-upgrade tree did not have.
assert_eq "upgrade-gate 1: the pre-upgrade tree lacks the v4 review predicate review-check.sh" \
    "no" "$(yesno test -e "$T/.claude/scripts/review-check.sh")"

# --- the upgrade, NO FLAGS --------------------------------------------------
UPGRADE_RC=0
bash "$PLUGIN_ROOT/install.sh" "$T" </dev/null >"$WORK/upgrade.log" 2>&1 || UPGRADE_RC=$?
if [ "$UPGRADE_RC" -ne 0 ]; then
    printf '  diagnostic: upgrade exited %s; tail of log:\n' "$UPGRADE_RC"
    tail -25 "$WORK/upgrade.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "upgrade-gate 1: install.sh with NO flags exits 0 on the v3.5 target" \
    "0" "$UPGRADE_RC"
UPGRADE_LOG=$(cat "$WORK/upgrade.log" 2>/dev/null || echo "")
assert_contains "upgrade-gate 1: auto-detection (not a flag) chose the upgrade path" \
    "Detected v3.5.0 plugin installation" "$UPGRADE_LOG"
SOURCE_VERSION=$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo "")
assert_eq "upgrade-gate 1: the upgraded fixture declares the shipped source version" \
    "$SOURCE_VERSION" "$(jq -r '.version // empty' "$T/.claude-plugin/plugin.json" 2>/dev/null || echo "")"
assert_eq "upgrade-gate 1: the upgraded tree now carries the v4 review predicate" \
    "yes" "$(yesno test -f "$T/.claude/scripts/review-check.sh")"

# --- script handles + cwd pinning ------------------------------------------
QG="$T/.claude/scripts/qa-gate.sh"
CT="$T/.claude/scripts/current-task.sh"
VBS="$T/.claude/scripts/verify-before-stop.sh"
IR="$T/.claude/scripts/impact-report.sh"
SS="$T/.claude/scripts/session-start.sh"
TRACKING="$T/.claude/.qa-tracking"
TRACKER="$TRACKING/changed-files.txt"
BASE_V2="$TRACKING/gate-baseline"
BASE_V1="$TRACKING/approved-baseline"

mkdir -p "$TRACKING"
export CLAUDE_PROJECT_DIR="$T"
# See the RUNTIME note in the header.
export CODE_GRAPH_MCP_BIN="$T/.claude/mcp/.absent-code-graph-mcp.js"
# Pin the fixture's own Codex-registration path at a NONEXISTENT file, exactly
# as mk_fixture does, so codex-detect.sh cannot read the host developer's
# ~/.claude.json and the reviewer lane resolves deterministically.
export CODEX_USER_CONFIG="$T/.claude/.no-codex-config.json"

# CWD IS LOAD-BEARING, TWICE OVER, and this is the one service mk_fixture would
# have provided:
#   1. `bd` resolves its database by walking UP from the cwd. The component
#      runner's cwd is the PLUGIN ROOT, which has a real .beads/ - a bare
#      `bd create` from there would write into the plugin's production ledger.
#   2. current-task.sh records the I8 repo fingerprint from `git rev-parse
#      --show-toplevel` OF THE CWD (deliberately, not of CLAUDE_PROJECT_DIR), so
#      a `set` run from the plugin root would stamp the PLUGIN's toplevel onto
#      the fixture's active task and every Stop below would trip the cross-repo
#      block instead of reaching the gate.
cd "$T" || exit 1

# bdt <args...> - `bd`, pinned to the fixture, belt-and-braces over the cd
# above. Every direct bd call in this spec goes through it so a future edit that
# moves the cwd cannot silently retarget the production database.
bdt() { ( cd "$T" && bd "$@" ); }

assert_eq "upgrade-gate 1: bd answers inside the upgraded fixture" \
    "yes" "$(yesno bdt list --json)"
# The safety assertion: an EMPTY ledger proves we are talking to the fixture's
# own .beads and not the plugin's (which has hundreds of rows).
assert_eq "upgrade-gate 1: the fixture's Beads ledger is empty (NOT the plugin's production db)" \
    "0" "$(bdt list --json 2>/dev/null | jq 'length' 2>/dev/null || echo "?")"

# --- normalisation ---------------------------------------------------------
# Three edits, each one making a later assertion measurable rather than
# incidental:
#
#   detect-stack stub  an empty test_cmd so the Stop hook's test/lint pass is
#                      skipped. Same stub the verify-before-stop and
#                      gate-baseline-v2 specs use; the subject is the QA-approval
#                      stage, not the runner.
#   src/ with a
#   COMMITTED file     git collapses a wholly-untracked directory into ONE
#                      porcelain entry, so an untracked src/ would report `?? src/`
#                      no matter how many files appeared inside it - and section
#                      5's "add a path that is not in the snapshot" would produce
#                      no new entry at all. One tracked file inside src/ makes
#                      git name its siblings individually (the same reason
#                      gate-baseline-v2 uses committed-then-modified files).
#   .gitignore +
#   one commit         the gate's own bookkeeping (.claude/.qa-tracking/), the
#                      Beads ledger (rewritten by every bd call) and
#                      model-select's meta-task marker are per-session ephemera;
#                      leaving them tracked would make the tree go dirty
#                      mid-spec and every ALLOW/BLOCK below would be measuring
#                      that churn. Everything else is committed so `git status`
#                      starts EMPTY and each section can create exactly the dirt
#                      it means to measure.
rm -f "$T/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$T/.claude/scripts/detect-stack.sh"
chmod +x "$T/.claude/scripts/detect-stack.sh"

mkdir -p "$T/src"
printf 'export const preUpgrade = 0;\n' > "$T/src/pre-upgrade-dirt.ts"

# Appended, not written: today the installer leaves no .gitignore behind on a
# target that was already a git repo, but a duplicate line is harmless and
# clobbering a shipped one silently would not be.
printf '%s\n' \
    '.claude/.qa-tracking/' \
    '.claude/.session-start' \
    '.claude/.model-select-meta-task' \
    '.beads/' >> "$T/.gitignore"
# --no-verify: `bd hooks install` (run by both installers) puts a pre-commit
# hook in this repo that syncs the Beads ledger. Letting it fire would make
# every commit in this spec depend on bd's git integration, which is not the
# subject.
git -C "$T" -c user.email=test@example.com -c user.name=test add -A >/dev/null 2>&1
git -C "$T" -c user.email=test@example.com -c user.name=test \
    commit -q --no-verify -m "upgraded baseline" >/dev/null 2>&1

# porcelain_count / dirt_lines - the tree's own view, for preconditions that
# have to say exactly what is dirty.
dirt_lines() { git -C "$T" status --porcelain 2>/dev/null | LC_ALL=C sort; }
porcelain_count() { dirt_lines | grep -c . | tr -d '[:space:]'; }

assert_eq "upgrade-gate 1: the upgraded tree is committed clean (baseline for every later ALLOW/BLOCK)" \
    "0" "$(porcelain_count)"

# ---------------------------------------------------------------------------
# Shared machinery for sections 2-7.

# stop_run - fire the Stop hook ONCE and keep its verdict line in STOP_OUT, so a
# section can read the decision AND the reason from a single fire. That is not
# just tidy: every BLOCK bumps the per-task iteration counter, and at
# MAX_ITERATIONS the gate starts relabelling (qa-escalated) and eventually
# auto-defers into an ALLOW. Firing twice to read two fields would make later
# assertions depend on how many times earlier ones measured.
STOP_OUT=""
stop_run() {
    STOP_OUT=$(printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | CLAUDE_PROJECT_DIR="$T" bash "$VBS" 2>/dev/null | tail -1)
}
# ALLOW is signalled by ABSENCE (`{}` / no decision key) - there is no "approve"
# decision on a Stop hook.
stop_decision() { printf '%s' "$STOP_OUT" | jq -r '.decision // "ALLOW"' 2>/dev/null; }
stop_reason() { printf '%s' "$STOP_OUT" | jq -r '.reason // empty' 2>/dev/null; }

# task_state <tid> - the canonical, sorted JSON of everything this spec claims
# the gate must not touch on a closed task: its labels and its full comment
# list. jq -cS makes it a byte-comparable string; ids and created_at are fixed
# at write time, so including them makes the comparison STRICTER, not flakier.
task_state() {
    bdt show "$1" --json 2>/dev/null \
        | jq -cS '(if type == "array" then .[0] else . end)
                  | {labels: (.labels // []), comments: (.comments // [])}' 2>/dev/null \
        || echo ""
}

# approval_records <tid> - every `QA-GATE APPROVED ...` comment on the task, one
# per line. Same source the Stop hook reads.
approval_records() {
    bdt show "$1" --json 2>/dev/null \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // []
                 | .[].text' 2>/dev/null \
        | grep '^QA-GATE APPROVED ' || true
}

# add_note <tid> <text> - the plural/singular fallback the real writers use
# (qa-gate.sh add_comment, lib/fixture.sh seed_review_records).
add_note() {
    bdt comments add "$1" "$2" >/dev/null 2>&1 || bdt comment add "$1" "$2" >/dev/null 2>&1
}

# new_task <title> - create a task and print its id.
new_task() {
    bdt create "$1" -t task -p 1 -l devops,qa-pending --json 2>/dev/null \
        | jq -r '.id // empty' 2>/dev/null
}

# seed_legacy_approval <tid> <hash-or-empty> <summary> - plant an approval record
# in the PRE-v4 grammar: `QA-GATE APPROVED change_set_hash=<h> at <ts>: <summary>`
# with no reviewed_by= and no worktree= token, plus the label transition a v3.5
# approve performed atomically (+qa-approved, -qa-gate-entered, -qa-pending). The
# label moves matter for fidelity, not for the assertions: a row carrying both
# qa-gate-entered and qa-approved is a state no real approve ever produced, and
# leaving it that way would put a confound in the middle of the META.
#
# An EMPTY <hash> omits the change_set_hash token entirely. That is the one knob
# section 7's META turns: 4b and 7 call this same function with the same
# arguments except that one, so the difference between release and block is
# provably that token and nothing else.
seed_legacy_approval() {
    local tid="$1" hash="$2" summary="$3"
    local hash_field="" ts
    [ -n "$hash" ] && hash_field="change_set_hash=$hash "
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    add_note "$tid" "QA-GATE APPROVED ${hash_field}at $ts: $summary"
    bdt label add "$tid" qa-approved >/dev/null 2>&1
    bdt label remove "$tid" qa-gate-entered >/dev/null 2>&1
    bdt label remove "$tid" qa-pending >/dev/null 2>&1
}

# gate_cycle <tid> <tracked-path> <summary> - the LEGITIMATE v4 flow, in the
# order the Stop hook's own block reason prescribes it: enter (which arms the
# gate, persists current-task and generates the impact report), the independent
# review records, an explicit impact-report regeneration, then approve. Prints
# approve's JSON envelope; everything earlier is discarded.
#
# seed_review_records is lib/fixture.sh's helper, not a local re-implementation:
# it drives the REAL writers (`bd comments add` for the IMPLEMENTER record that
# subagent-start.sh writes on spawn, `qa-gate.sh review-record` for the
# artifact), so if either grammar changes this spec moves with it.
gate_cycle() {
    local tid="$1" path="$2" summary="$3"
    printf '%s\n' "$path" > "$TRACKER"
    if ! bash "$QG" enter "$tid" >/dev/null 2>&1; then
        printf '  diagnostic: qa-gate.sh enter failed for %s\n' "$tid"
        return 1
    fi
    if ! seed_review_records "$tid" "qa-claude" "backend" "$T" >/dev/null 2>"$WORK/seed.err"; then
        printf '  diagnostic: seed_review_records failed for %s: %s\n' \
            "$tid" "$(tail -2 "$WORK/seed.err" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi
    CLAUDE_PROJECT_DIR="$T" bash "$IR" "$tid" >/dev/null 2>&1 || true
    bash "$CT" set "$tid" >/dev/null 2>&1 || true
    bash "$QG" approve "$tid" "$summary" 2>&1 | tail -1
}

# arm_stop <tid> <tracked-path> - approve deliberately clears current-task and
# TRUNCATES changed-files.txt (a fresh approval starts a clean cycle), so a Stop
# fired straight afterwards would find no change set and release for the trivial
# reason. Restoring both makes the Stop fire against the SAME reviewed change
# set, which is the state the release assertion is about. Same idiom as
# verify-before-stop.sh's own llh.18 section.
arm_stop() {
    bash "$CT" set "$1" >/dev/null 2>&1
    printf '%s\n' "$2" > "$TRACKER"
}

# baseline_header_field <file> <key> - read one provenance header field of a v2
# gate-baseline. Mirrors gate-baseline-v2.sh.
baseline_header_field() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# review_gate_rc <tid> - the exit code of the v4 independent-review predicate,
# i.e. the EXACT check the Stop hook re-runs before releasing an approved change
# set. Sections 4b and 7 assert it is 0 as a precondition, which is what makes
# their verdicts attributable to the approval RECORD: with the review side
# provably clean, a block can only come from the record, and the META's block can
# only come from the token it removed.
review_gate_rc() {
    local rc=0
    CLAUDE_PROJECT_DIR="$T" bash "$T/.claude/scripts/review-check.sh" gate "$1" \
        >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ===========================================================================
# Section 2: a v3.5-format approval record on a CLOSED task is never
#            re-validated and never re-blocked.
#
# WHY THIS IS THE SHARPEST CASE. The v4 readers require exactly one token to
# recognise an approval record - `change_set_hash=` - and treat reviewed_by= /
# worktree= as structurally optional, so a v3.5 record is still parseable. But
# its hash was computed against a change set that no longer exists, and the v4
# gate ALSO re-runs the independent-review predicate before releasing, which a
# v3.5-era task has no artifact for. If closed tasks were in scope, an upgrade
# would therefore re-arm the gate over finished history and the first Stop after
# it would demand a review of work that shipped releases ago.
#
# They are NOT in scope: every validation in verify-before-stop.sh is keyed on
# CURRENT_TASK, and there is no task-wide scan anywhere in the hook (the
# bd-list fallback for the active id was removed as the F3 antipattern). This
# section pins that, including the non-vacuous half - the closed row stays
# untouched even on a Stop that DOES block.
# ===========================================================================
TID_CLOSED=$(new_task "v3.5-era task, approved and closed before the upgrade")
assert_eq "upgrade-gate 2: precondition - the closed-task fixture row was created" \
    "yes" "$(yesno test -n "$TID_CLOSED")"

seed_legacy_approval "$TID_CLOSED" "$LEGACY_CLOSED_HASH" "legacy"
bdt close "$TID_CLOSED" -r "shipped in v3.5" >/dev/null 2>&1

CLOSED_RECORD=$(approval_records "$TID_CLOSED")
assert_match "upgrade-gate 2: the seeded record is in the v3.5 grammar (hash token, then the timestamp)" \
    "^QA-GATE APPROVED change_set_hash=$LEGACY_CLOSED_HASH at $ISO: legacy$" \
    "$CLOSED_RECORD"
assert_not_contains "upgrade-gate 2: the seeded v3.5 record carries NO reviewed_by= token" \
    "reviewed_by=" "$CLOSED_RECORD"
assert_not_contains "upgrade-gate 2: the seeded v3.5 record carries NO worktree= token" \
    "worktree=" "$CLOSED_RECORD"
assert_eq "upgrade-gate 2: the task is CLOSED" "closed" \
    "$(bdt show "$TID_CLOSED" --json 2>/dev/null \
        | jq -r '(if type == "array" then .[0] else . end).status // empty' 2>/dev/null || echo "")"

# Snapshot BEFORE anything runs, so the comparison covers session-start and every
# Stop fire below - the releasing one, the blocking one, and the falsification
# pair at the end of the section.
CLOSED_BEFORE=$(task_state "$TID_CLOSED")
assert_eq "upgrade-gate 2: precondition - the closed task's state snapshot is non-empty" \
    "yes" "$(yesno test -n "$CLOSED_BEFORE")"

# The upgrade-arrival moment: no review cycle in flight, clean tracker.
bash "$CT" clear >/dev/null 2>&1
: > "$TRACKER"

SS_RC=0
SS_OUT=$(printf '%s' '{}' | CLAUDE_PROJECT_DIR="$T" bash "$SS" 2>/dev/null) || SS_RC=$?
assert_eq "upgrade-gate 2: the upgraded session-start hook exits 0 on a v3.5-upgraded tree" \
    "0" "$SS_RC"
assert_json_field "upgrade-gate 2: ...and emits a valid SessionStart envelope" \
    "$SS_OUT" '.hookSpecificOutput.hookEventName' "SessionStart"

# session-start runs model-select.sh apply, whose JOB is to rewrite the model
# pins in .claude/settings.json when a better snapshot exists. That is correct
# behaviour and nothing here should assert against it - but it is tracked churn,
# and the assertions below need a clean tree to be about the CLOSED TASK rather
# than about settings drift. Restore tracked files to HEAD and assert the result
# so a surprise (an untracked stray this .gitignore does not cover) fails loudly
# instead of silently turning the next ALLOW into a BLOCK.
git -C "$T" checkout -- . >/dev/null 2>&1 || true
: > "$TRACKER"
assert_eq "upgrade-gate 2: precondition - the tree is clean and the tracker empty before the Stop" \
    "0" "$(porcelain_count)"
assert_eq "upgrade-gate 2: precondition - no active task (the closed row is not current)" \
    "" "$(bash "$CT" get 2>/dev/null || echo "")"

stop_run
assert_eq "upgrade-gate 2: Stop RELEASES after the upgrade with only closed history on file" \
    "ALLOW" "$(stop_decision)"
assert_eq "upgrade-gate 2: the closed task's labels + comments are byte-unchanged by the flow" \
    "$CLOSED_BEFORE" "$(task_state "$TID_CLOSED")"

# NON-VACUITY. The release above could be read as "the gate did nothing because
# there was nothing to do". So: give it something to do. A tracked change with
# still no active task must BLOCK - and the closed row must STILL be untouched,
# and must not even be NAMED in the block reason. A gate that re-validated
# closed history would have to mention it to explain itself.
printf 'src/unreviewed-after-upgrade.ts\n' > "$TRACKER"
stop_run
BLOCK_REASON=$(stop_reason)
assert_eq "upgrade-gate 2: an unreviewed change with no active task BLOCKS (the gate is awake)" \
    "block" "$(stop_decision)"
assert_contains "upgrade-gate 2: ...with the generic QA-required reason" \
    "QA approval required" "$BLOCK_REASON"
assert_not_contains "upgrade-gate 2: ...and the block reason never names the closed task" \
    "$TID_CLOSED" "$BLOCK_REASON"
assert_eq "upgrade-gate 2: the closed task survives a BLOCKING Stop byte-unchanged too" \
    "$CLOSED_BEFORE" "$(task_state "$TID_CLOSED")"

# FALSIFIABILITY. Everything above would also hold if the gate never looked at
# approval records at all. So put the CLOSED row IN scope - make it current-task,
# same tracked change - and the verdict must turn into a block, because its v3.5
# record binds a hash the current tree cannot produce. That is the TOO STRICT
# failure mode this section exists to rule out, executed on purpose: it proves
# the tolerance above comes from closed rows being OUT OF SCOPE, not from a stale
# record being waved through. (Verified by probe before this spec landed:
# out-of-scope ALLOW / in-scope block, on the identical row and change set.)
bash "$CT" set "$TID_CLOSED" >/dev/null 2>&1
stop_run
assert_eq "upgrade-gate 2 falsification: the SAME row IN scope blocks on its stale v3.5 hash" \
    "block" "$(stop_decision)"
assert_contains "upgrade-gate 2 falsification: ...because no record on it matches the current change set" \
    "no change-set-bound approval record matches" "$(stop_reason)"
assert_eq "upgrade-gate 2 falsification: ...and even THAT block relabels nothing on the row" \
    "$CLOSED_BEFORE" "$(task_state "$TID_CLOSED")"

# Out of scope again, clean tracker: the release returns, so the ALLOW above was
# not a latch.
bash "$CT" clear >/dev/null 2>&1
: > "$TRACKER"
stop_run
assert_eq "upgrade-gate 2 falsification: taking the row back OUT of scope restores the release" \
    "ALLOW" "$(stop_decision)"

# ===========================================================================
# Section 3: the forged bare label still does not release after an upgrade.
#
# llh.18's red-team P0: `bd label add <task> qa-approved` flips every
# label-shaped signal (including `qa-gate.sh status`) without writing the
# change-set-bound RECORD that qa-gate.sh approve writes. The release predicate
# needs both. An upgraded tree must not be a way around that.
# ===========================================================================
TID_OPEN=$(new_task "post-upgrade work, forged label first")
assert_eq "upgrade-gate 3: precondition - the forgery fixture row was created" \
    "yes" "$(yesno test -n "$TID_OPEN")"

WORK_PATH="src/upgrade-feature.ts"
printf '%s\n' "$WORK_PATH" > "$TRACKER"
bash "$QG" enter "$TID_OPEN" >/dev/null 2>&1
bash "$CT" set "$TID_OPEN" >/dev/null 2>&1

stop_run
assert_eq "upgrade-gate 3: control - entered, not approved, real change -> BLOCK" \
    "block" "$(stop_decision)"

bdt label add "$TID_OPEN" qa-approved >/dev/null 2>&1
assert_eq "upgrade-gate 3: the bare label flips qa-gate status to approved (the forgeable signal)" \
    "approved" "$(bash "$QG" status "$TID_OPEN" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || echo "")"
assert_eq "upgrade-gate 3: ...and the task carries NO approval record at all" \
    "" "$(approval_records "$TID_OPEN")"

stop_run
FORGED_REASON=$(stop_reason)
assert_eq "upgrade-gate 3: the forged bare label still BLOCKS on the upgraded tree" \
    "block" "$(stop_decision)"
# The label-without-record branch is identified by its reason text; the internal
# flag name never reaches the envelope.
assert_contains "upgrade-gate 3: ...via the label-without-record branch, named in the reason" \
    "no change-set-bound approval record matches" "$FORGED_REASON"
assert_contains "upgrade-gate 3: ...which steers to qa-gate.sh approve, not a bare label add" \
    "not a bare label add" "$FORGED_REASON"

# ===========================================================================
# Section 4: the legitimate v4 path releases the SAME task, and the record it
#            writes carries both v4 tokens.
#
# THE ONE CLEANUP STEP, AND WHY IT IS HERE: it puts section 3's row back into the
# not-approved state, so what this section measures is the LEGITIMATE v4 path from
# a clean start rather than a recovery-from-forgery. Historically it was also
# mandatory — approve used to no-op on the mere presence of qa-approved
# ("qa-approved already set; idempotent no-op"), so a legitimate approve under
# section 3's forged label wrote no record and the task stayed blocked forever.
# Since claude-workflow-plugin-gz3 approve's idempotency is HASH-AWARE (it no-ops
# only when a record already binds the current change set), so recovery THROUGH a
# stale/forged label now works too — that path is pinned in
# specs/approve-idempotency.sh (section A) and specs/denylist-shared.sh (C4). The
# removal stays here on purpose: this section's subject is the upgraded tree's
# happy path, and it is spelled out rather than hidden in a helper because it is
# the only reason this section can reuse section 3's row.
# ===========================================================================
bdt label remove "$TID_OPEN" qa-approved >/dev/null 2>&1
assert_eq "upgrade-gate 4: precondition - the forged label is cleared (the row is back to entered)" \
    "entered" "$(bash "$QG" status "$TID_OPEN" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || echo "")"

APPROVE_OUT=$(gate_cycle "$TID_OPEN" "$WORK_PATH" "reviewed after the upgrade; ships safely")
assert_json_field "upgrade-gate 4: the legitimate flow approves" "$APPROVE_OUT" '.status' "approved"
assert_contains "upgrade-gate 4: ...and reports the change-set-bound record it wrote" \
    "change-set-bound approval record written" "$APPROVE_OUT"
assert_contains "upgrade-gate 4: ...and reports the independent review it verified" \
    "independent review verified (reviewed_by=qa-claude" "$APPROVE_OUT"

arm_stop "$TID_OPEN" "$WORK_PATH"
# Captured BEFORE the release fire: a releasing Stop cleans up changed-files.txt,
# after which --hash-only would answer with the empty-set hash.
CUR_HASH=$(CLAUDE_PROJECT_DIR="$T" bash "$IR" --hash-only 2>/dev/null || echo "")
V4_RECORD=$(approval_records "$TID_OPEN")
assert_match "upgrade-gate 4: the NEW record is in the v4 grammar (hash, reviewed_by, worktree, then the timestamp)" \
    "^QA-GATE APPROVED change_set_hash=[A-Za-z0-9-]+ reviewed_by=qa-claude worktree=[^ ]+ at $ISO: " \
    "$V4_RECORD"
assert_eq "upgrade-gate 4: ...whose change_set_hash is the hash of the reviewed change set" \
    "$CUR_HASH" \
    "$(printf '%s' "$V4_RECORD" | sed -nE 's/.*change_set_hash=([A-Za-z0-9-]+).*/\1/p' | head -1)"
assert_eq "upgrade-gate 4: ...and whose worktree= token names the approving checkout" \
    "yes" "$(yesno test -n "$(printf '%s' "$V4_RECORD" | sed -nE 's/.*worktree=([^ ]+).*/\1/p' | head -1)")"

stop_run
assert_eq "upgrade-gate 4: the full v4 path RELEASES on the upgraded tree" \
    "ALLOW" "$(stop_decision)"

# ---------------------------------------------------------------------------
# 4b COMPANION: a PRE-v4 record on an OPEN task releases too.
#
# This is the retention claim section 2 could not make, because a closed task is
# never read at all: on the task the gate DOES read, a record carrying only
# `change_set_hash=` - no reviewed_by=, no worktree= - is still a valid approval.
# The two v4 tokens are additive metadata for the AUDIT trail, not part of the
# reader's predicate. An upgrader whose in-flight cycle was approved by v3.5
# therefore keeps its release.
#
# Everything else about the cycle is real: the review artifact is recorded
# through qa-gate.sh review-record, because the v4 Stop hook re-runs the
# independent-review predicate before releasing regardless of which grammar the
# approval record is written in.
# ---------------------------------------------------------------------------
TID_LEGACY=$(new_task "in-flight cycle approved by v3.5, resumed after the upgrade")
assert_eq "upgrade-gate 4b: precondition - the pre-v4-record fixture row was created" \
    "yes" "$(yesno test -n "$TID_LEGACY")"

LEGACY_PATH="src/legacy-approved.ts"
printf '%s\n' "$LEGACY_PATH" > "$TRACKER"
bash "$QG" enter "$TID_LEGACY" >/dev/null 2>&1
seed_review_records "$TID_LEGACY" "qa-claude" "backend" "$T" >/dev/null 2>&1
LEGACY_HASH=$(CLAUDE_PROJECT_DIR="$T" bash "$IR" --hash-only 2>/dev/null || echo "")
assert_eq "upgrade-gate 4b: precondition - the current change-set hash is computable" \
    "yes" "$(yesno test -n "$LEGACY_HASH")"
assert_eq "upgrade-gate 4b: precondition - the independent-review predicate is CLEAN (records seeded)" \
    "0" "$(review_gate_rc "$TID_LEGACY")"
seed_legacy_approval "$TID_LEGACY" "$LEGACY_HASH" "approved by v3.5 before the upgrade"
arm_stop "$TID_LEGACY" "$LEGACY_PATH"

LEGACY_RECORD=$(approval_records "$TID_LEGACY")
assert_match "upgrade-gate 4b: the record on file is the pre-v4 grammar (hash straight to the timestamp)" \
    "^QA-GATE APPROVED change_set_hash=$LEGACY_HASH at $ISO: " "$LEGACY_RECORD"
assert_not_contains "upgrade-gate 4b: ...carrying NO reviewed_by= token" "reviewed_by=" "$LEGACY_RECORD"
assert_not_contains "upgrade-gate 4b: ...and NO worktree= token" "worktree=" "$LEGACY_RECORD"

stop_run
assert_eq "upgrade-gate 4b: a PRE-v4 record on the OPEN current task still RELEASES" \
    "ALLOW" "$(stop_decision)"

# ===========================================================================
# Section 5: the v1 `approved-baseline` fallback, RE-PINNED FROM THE UPGRADE
#            TOPOLOGY.
#
# WHY THIS SECTION EXISTS SEPARATELY FROM gate-baseline-v2.sh SECTION 5.
# 3mg.1 replaced the v1 baseline (a bare porcelain line list at
# .qa-tracking/approved-baseline) with the provenanced v2 `gate-baseline`, and
# left the v1 file readable as a ONE-RELEASE fallback so an install that
# upgraded mid-cycle would not lose its reference point and eat a spurious
# full-tree block. gate-baseline-v2.sh section 5 pins that read path and, by
# naming the licence, invites its removal one release later.
#
# The upgrade topology says that licence has not expired. v3.5 upgraders do not
# walk the release train one stop at a time - they run the current installer and
# land on v4.1 directly, carrying whatever .qa-tracking/ their v3.5 install
# accumulated, INCLUDING a v1 approved-baseline written by a v3.5-era approve.
# The fallback's real expiry condition is therefore not "one release after
# 3mg.1" but "the first release a v3.5 tree can no longer upgrade to directly".
# So the read path is re-pinned HERE, under a spec whose name is `upgrade`:
# deleting the fallback must break THIS spec, not only the one that licenses its
# removal.
#
# Measured as a BLOCK/RELEASE pair around one variable, because the observable
# is the DECISION: on the git-status fallback the block reason does not
# enumerate paths (the enumerated list comes from changed-files.txt, which is
# empty by construction whenever the fallback is what fired).
#
# LOAD-BEARING, verified rather than asserted: deleting the two-line legacy arm
# from verify-before-stop.sh's `gate_baseline_entries` was executed against this
# fixture before the spec landed, and the RE-PIN assertion below flipped from
# ALLOW to block. So the claim "removing the fallback breaks an upgrade-named
# spec" is measured, not hoped for.
# ===========================================================================
bash "$CT" clear >/dev/null 2>&1
: > "$TRACKER"
rm -f "$BASE_V2" "$BASE_V1"
git -C "$T" checkout -- . >/dev/null 2>&1 || true
assert_eq "upgrade-gate 5: precondition - no v2 gate-baseline exists" \
    "no" "$(yesno test -e "$BASE_V2")"
assert_eq "upgrade-gate 5: precondition - no v1 approved-baseline exists yet" \
    "no" "$(yesno test -e "$BASE_V1")"
assert_eq "upgrade-gate 5: precondition - no active review cycle (the git fallback is the surface under test)" \
    "" "$(bash "$CT" get 2>/dev/null || echo "")"

# The dirt a v3.5-era session left behind: committed-then-modified, so porcelain
# names the FILE.
printf 'export const preUpgrade = 1; // half-finished before the upgrade\n' > "$T/src/pre-upgrade-dirt.ts"
assert_eq "upgrade-gate 5: precondition - the tree is dirty with exactly the pre-upgrade file" \
    "1" "$(porcelain_count)"

stop_run
assert_eq "upgrade-gate 5: control - pre-upgrade dirt with NO baseline of either version BLOCKS" \
    "block" "$(stop_decision)"

# Seed the v1 file in its own format: a BARE porcelain line list, no provenance
# header and no `--` terminator (that is the v2 shape). Same seeding semantics as
# gate-baseline-v2.sh section 5.
dirt_lines > "$BASE_V1"
assert_eq "upgrade-gate 5: the seeded v1 file is a bare line list, not a v2 header" \
    "no" "$(yesno grep -q '^# gate-baseline' "$BASE_V1")"
assert_contains "upgrade-gate 5: ...carrying the pre-upgrade path" \
    "src/pre-upgrade-dirt.ts" "$(cat "$BASE_V1")"
assert_eq "upgrade-gate 5: precondition - still no v2 file, so only the fallback can fire" \
    "no" "$(yesno test -e "$BASE_V2")"

: > "$TRACKER"
stop_run
assert_eq "upgrade-gate 5: THE RE-PIN - a v3.5-era v1 approved-baseline is still honoured, so the upgrade does not eat a spurious block" \
    "ALLOW" "$(stop_decision)"

# A path the v1 snapshot does not know about is still NEW. `src/` already holds a
# tracked file, so git names this one individually instead of collapsing the
# directory.
printf 'export const unseeded = 1;\n' > "$T/src/unseeded-after-legacy-baseline.ts"
: > "$TRACKER"
stop_run
assert_eq "upgrade-gate 5: dirt that is NOT in the v1 snapshot still BLOCKS" \
    "block" "$(stop_decision)"

# CAUSATION: remove only the unseeded path and the release comes back, with the
# baselined dirt still dirty throughout. Block -> release with one variable moved
# is the falsifiable form of "the reviewer's set is the delta against the v1
# snapshot", and it also proves the ALLOW above was not a latch.
rm -f "$T/src/unseeded-after-legacy-baseline.ts"
: > "$TRACKER"
assert_eq "upgrade-gate 5: precondition - the baselined pre-upgrade file is STILL dirty" \
    "1" "$(dirt_lines | grep -c 'src/pre-upgrade-dirt\.ts' | tr -d '[:space:]')"
stop_run
assert_eq "upgrade-gate 5: removing ONLY the unseeded path restores the release" \
    "ALLOW" "$(stop_decision)"

# Hand section 6 a clean tree (asserted there as a precondition).
rm -f "$BASE_V1"
git -C "$T" checkout -- . >/dev/null 2>&1 || true

# ===========================================================================
# Section 6: post-upgrade gate smoke - a task that never existed under v3.5
#            round-trips the whole cycle in the upgraded tree.
#
# Sections 2-5 all carry pre-upgrade residue by design. This one carries none:
# a fresh row, a real file on disk, and the full enter -> records -> approve ->
# Stop-release path executed by the UPGRADED scripts. That is the acceptance
# point of the whole spec - the gate does not merely tolerate the upgrade, it
# WORKS after it - so the assertions are about the lifecycle end to end: the
# labels approve moves, the v4 review predicate that only exists post-upgrade
# actually running, the release, and the v2 baseline the upgraded writer
# produces.
#
# The change set is a REAL file, not just a tracker line: approve's baseline
# refresh is what section 6.6 measures, and a snapshot of a clean tree would
# measure nothing.
# ===========================================================================
assert_eq "upgrade-gate 6: precondition - the tree is clean before the smoke cycle" \
    "0" "$(porcelain_count)"
TID_SMOKE=$(new_task "first task created after the upgrade")
assert_eq "upgrade-gate 6: precondition - the smoke fixture row was created" \
    "yes" "$(yesno test -n "$TID_SMOKE")"

SMOKE_PATH="src/post-upgrade-feature.ts"
printf 'export const postUpgrade = 1;\n' > "$T/$SMOKE_PATH"
ENTER_OUT=$(bash "$QG" enter "$TID_SMOKE" 2>&1 | tail -1)
assert_json_field "upgrade-gate 6: enter arms the gate in the upgraded tree" \
    "$ENTER_OUT" '.status' "entered"

SMOKE_APPROVE=$(gate_cycle "$TID_SMOKE" "$SMOKE_PATH" "post-upgrade smoke: reviewed end to end")
assert_json_field "upgrade-gate 6: approve completes the cycle" "$SMOKE_APPROVE" '.status' "approved"
assert_contains "upgrade-gate 6: ...having run the v4 review predicate that the pre-upgrade tree did not ship" \
    "independent review verified (reviewed_by=qa-claude" "$SMOKE_APPROVE"

SMOKE_LABELS=$(bdt show "$TID_SMOKE" --json 2>/dev/null \
    | jq -r '(if type == "array" then .[0] else . end).labels // [] | join(",")' 2>/dev/null || echo "")
assert_contains "upgrade-gate 6: the lifecycle labels land - qa-approved set" "qa-approved" "$SMOKE_LABELS"
assert_not_contains "upgrade-gate 6: ...qa-pending cleared" "qa-pending" "$SMOKE_LABELS"
assert_not_contains "upgrade-gate 6: ...qa-gate-entered cleared" "qa-gate-entered" "$SMOKE_LABELS"

arm_stop "$TID_SMOKE" "$SMOKE_PATH"
stop_run
assert_eq "upgrade-gate 6: Stop RELEASES - the gate works end to end after the upgrade" \
    "ALLOW" "$(stop_decision)"

# The write side of section 5's read side: the upgraded approve produces the v2
# format, so the v1 file section 5 exercised is a read-only compatibility path
# and nothing in the upgraded tree keeps writing it.
assert_eq "upgrade-gate 6: the upgraded approve wrote a v2 gate-baseline" \
    "yes" "$(yesno test -f "$BASE_V2")"
assert_eq "upgrade-gate 6: ...with the v2 version header" \
    "# gate-baseline v1" "$(head -1 "$BASE_V2" 2>/dev/null || echo "")"
assert_eq "upgrade-gate 6: ...and provenance naming qa-gate-approve" \
    "qa-gate-approve" "$(baseline_header_field "$BASE_V2" captured_by)"
assert_eq "upgrade-gate 6: ...and no v1 approved-baseline is written alongside it" \
    "no" "$(yesno test -e "$BASE_V1")"

# ===========================================================================
# Section 7 META-TEST: section 4b's release is driven by the RECORD, not by the
#            label, the review artifact, or the fact that a comment exists.
#
# Same construction as 4b - same helper, same review records, same tracker, same
# `qa-approved` label - with `change_set_hash=` omitted from the record. If 4b
# were passing for any other reason, this would release too.
#
# Then the sharpest form available: post the MISSING token's record on the SAME
# task (Beads comments are append-only, so a second record is the only way to
# add one) and watch the release come back. One variable, both directions.
# ===========================================================================
TID_META=$(new_task "META: 4b's scenario with the change_set_hash token stripped")
assert_eq "upgrade-gate 7 META: precondition - the META fixture row was created" \
    "yes" "$(yesno test -n "$TID_META")"

printf '%s\n' "$LEGACY_PATH" > "$TRACKER"
bash "$QG" enter "$TID_META" >/dev/null 2>&1
seed_review_records "$TID_META" "qa-claude" "backend" "$T" >/dev/null 2>&1
META_HASH=$(CLAUDE_PROJECT_DIR="$T" bash "$IR" --hash-only 2>/dev/null || echo "")
assert_eq "upgrade-gate 7 META: precondition - the independent-review predicate is CLEAN here too" \
    "0" "$(review_gate_rc "$TID_META")"
# The empty second argument is the whole mutation.
seed_legacy_approval "$TID_META" "" "approved by v3.5 before the upgrade"
arm_stop "$TID_META" "$LEGACY_PATH"

META_RECORD=$(approval_records "$TID_META")
assert_match "upgrade-gate 7 META: the mutilated record is on file" \
    "^QA-GATE APPROVED at $ISO: " "$META_RECORD"
assert_not_contains "upgrade-gate 7 META: ...with the change_set_hash token stripped" \
    "change_set_hash=" "$META_RECORD"
assert_eq "upgrade-gate 7 META: ...while every other 4b ingredient is present - the label still reads approved" \
    "approved" "$(bash "$QG" status "$TID_META" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || echo "")"
assert_eq "upgrade-gate 7 META: ...and the change set is the same one 4b released" \
    "$LEGACY_HASH" "$META_HASH"

stop_run
assert_eq "upgrade-gate 7 META: without the hash token the Stop BLOCKS (4b's release assertion WOULD fail)" \
    "block" "$(stop_decision)"
assert_contains "upgrade-gate 7 META: ...naming the missing change-set-bound record" \
    "no change-set-bound approval record matches" "$(stop_reason)"

# Both directions: add the token back, on the same row, and the release returns.
seed_legacy_approval "$TID_META" "$META_HASH" "approved by v3.5 before the upgrade"
arm_stop "$TID_META" "$LEGACY_PATH"
stop_run
assert_eq "upgrade-gate 7 META: restoring ONLY the hash token restores the release (the token is the variable)" \
    "ALLOW" "$(stop_decision)"

[ "$FAIL" -eq 0 ]

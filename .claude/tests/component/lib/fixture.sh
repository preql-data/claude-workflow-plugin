#!/bin/bash
# fixture.sh - Tempdir fixture builder for component-tier hook tests.
#
# Phase B (claude-workflow-plugin-0wk.11). Encapsulates the per-spec setup
# pattern: mktemp -d, scaffold .claude/.qa-tracking + .beads + scripts,
# install a bd wrapper (one PATH-controlled bd entry point), set
# CLAUDE_PROJECT_DIR, register cleanup. Specs call mk_fixture once, get
# back a path, and write/read against $FIXTURE/.claude/.qa-tracking/...
#
# Functions:
#   mk_fixture
#       Builds a fresh temp project root with:
#         - .claude/.qa-tracking/        (empty)
#         - .claude/scripts/             (symlinks to plugin's real scripts)
#         - .claude/settings.json        (minimal manifest, hooks-aware)
#         - .beads/                      (initialised via `bd init`)
#         - bin/bd                       (pass-through wrapper of real bd)
#       Exports CLAUDE_PROJECT_DIR + COMPONENT_FIXTURE_PATH and prepends
#       the fixture's bin/ to PATH.
#
#       CRITICAL: callers must invoke mk_fixture WITHOUT command substitution
#       so the exports reach the caller's shell:
#           mk_fixture
#           FIXTURE="$COMPONENT_FIXTURE_PATH"
#       NOT `FIXTURE=$(mk_fixture)` — that runs in a subshell and the
#       exported CLAUDE_PROJECT_DIR / PATH mutations are discarded.
#
#       Honours $KEEP_FIXTURE — when set to "1" the cleanup trap leaves the
#       directory in place and prints its path on exit.
#
#   cleanup_fixture <path>
#       Remove a fixture path. Idempotent. Called automatically by the trap
#       installed by mk_fixture, but exposed for specs that build multiple.
#
#   plugin_root
#       Absolute path of the plugin root (computed once, cached). Used for
#       resolving the real hook scripts to symlink/copy into the fixture.
#
#   seed_review_records <task-id> [reviewer] [implementer-role] [root]
#       V3 (jio.1): seed the IMPLEMENTER + REVIEW-ARTIFACT records a task
#       needs before `qa-gate.sh approve` will succeed. See the function's
#       own header for the contract. Since v5 D2 (claude-workflow-plugin-
#       fkm.4) this ALSO seeds a satisfied, independent DESIGN-REVIEW verdict
#       via seed_design_verdict — approve's design-satisfied refusal is the
#       same kind of acquired precondition completion-record was, and this is
#       the one place a spec already says "make this task approvable".
#
#   seed_design_verdict <task-id> [root]
#       v5 D2 (fkm.4): a minimal valid design artifact, a real design-record,
#       and a satisfied design-review-record from a genuinely different
#       identity ("design-claude") — the design-satisfied precondition
#       `qa-gate.sh approve` now REFUSES without (unless --no-design). Folded
#       into seed_review_records above; specs testing the design refusal
#       itself simply do not call it. Since v5 D3 (fkm.5) this ALSO seeds a
#       GRILLING v1 record first, via seed_grilling_record below — design-
#       record now refuses grilling_record_missing without one.
#
#   seed_grilling_record <task-id> [root]
#       v5 D3 (fkm.5): a real `qa-gate.sh grilling-record` — the precondition
#       `design-record` now REFUSES without (unless --no-grilling). Folded
#       into seed_design_verdict above; specs testing the grilling
#       precondition itself do not call it (see grilling-record.test.sh).
#
#   bd_show_with_comments <task-id>
#       `bd show --json` that always carries comment BODIES, across the
#       supported bd range. Specs that assert on records (IMPLEMENTER,
#       REVIEW-ARTIFACT, QA-GATE APPROVED, RUBRIC, ...) must read through
#       this, not through a bare `bd show --json`. See its own header.
#
#   assert_mutant_applied <label> <source> <mutant>
#       The MUTANT DID NOT APPLY guard. Every mutation-META in this tier must
#       call it immediately after building its mutant copy. See its header.

if [ -n "${__COMPONENT_FIXTURE_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
__COMPONENT_FIXTURE_SH_SOURCED=1

# Best-effort: source shim.sh for mk_bd_shim. The runner sources both, but
# this lets specs stand-alone in interactive debugging.
if [ -z "${__COMPONENT_SHIM_SH_SOURCED:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/shim.sh" ]; then
    # shellcheck source=./shim.sh
    . "$(dirname "${BASH_SOURCE[0]}")/shim.sh"
fi

__PLUGIN_ROOT_CACHE=""

plugin_root() {
    if [ -z "$__PLUGIN_ROOT_CACHE" ]; then
        # This file is at <plugin>/.claude/tests/component/lib/fixture.sh.
        # Resolve plugin root by going up four dirs.
        local self
        self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
        __PLUGIN_ROOT_CACHE=$(cd "$self/../../../.." && pwd)
    fi
    printf '%s' "$__PLUGIN_ROOT_CACHE"
}

# Global trap state. The runner spawns each spec in a subshell, so traps
# don't leak between specs.
__COMPONENT_FIXTURES_TO_CLEAN=()

__component_fixture_cleanup() {
    # Bash 3.2 under `set -u` errors on empty-array `${a[@]}` expansion.
    # Guard with the array's length (which is always defined as 0 even
    # when no elements have been appended).
    if [ "${#__COMPONENT_FIXTURES_TO_CLEAN[@]}" -eq 0 ]; then
        return
    fi
    if [ "${KEEP_FIXTURE:-0}" = "1" ]; then
        local d
        for d in "${__COMPONENT_FIXTURES_TO_CLEAN[@]}"; do
            printf 'Fixture kept at: %s\n' "$d"
        done
        return
    fi
    local d
    for d in "${__COMPONENT_FIXTURES_TO_CLEAN[@]}"; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
}

# Install the trap only once per shell.
if [ -z "${__COMPONENT_FIXTURE_TRAP_INSTALLED:-}" ]; then
    trap __component_fixture_cleanup EXIT
    __COMPONENT_FIXTURE_TRAP_INSTALLED=1
fi

cleanup_fixture() {
    local d="$1"
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
}

# bd_required_or_skip — spec-level skip-with-log gate for environments that
# don't have the real `bd` CLI on PATH. Two-mode behaviour, chosen by env:
#
#   - Dev machine (bd present): returns 0; the spec proceeds normally.
#   - CI runner (BD_SHIM_ONLY=1 set, bd absent): prints a "SKIPPED:" line
#     identifying the spec, then `exit 0` so the runner records the spec as
#     passing. This is the same skip-with-log pattern bd-github-link.sh
#     uses for missing gh/git — CI doesn't have a public installer for bd,
#     and we don't want bd-dependent specs to block the gate.
#   - Anywhere else (bd absent, no BD_SHIM_ONLY): hard-fail with a clearer
#     message than the previous `mk_bd_shim: real bd not on PATH`. This
#     keeps dev-machine misconfigurations loud.
#
# Specs should call this near the top, AFTER mk_fixture but BEFORE the
# first `bd` invocation. Placing it after mk_fixture means the fixture
# is still constructed (so any non-bd assertions before it would have
# run) — but in practice every bd-dependent spec needs bd from the first
# action, so the placement is "first line after FIXTURE=$COMPONENT_FIXTURE_PATH".
bd_required_or_skip() {
    if command -v bd >/dev/null 2>&1; then
        return 0
    fi
    # bd is not on PATH.
    local spec_name="${BASH_SOURCE[1]##*/}"
    if [ -z "$spec_name" ]; then
        spec_name="<unknown spec>"
    fi
    if [ "${BD_SHIM_ONLY:-0}" = "1" ]; then
        printf 'SKIPPED: %s (bd not available; CI env BD_SHIM_ONLY=1)\n' "$spec_name"
        # Exit the spec cleanly. The runner's spec-wrapper interprets
        # exit 0 as PASS. PASS/FAIL counters are zero — we don't fake
        # assertions, we just record the skip.
        exit 0
    fi
    printf 'bd_required_or_skip: %s requires the real `bd` CLI on PATH.\n' "$spec_name" >&2
    printf '  Install Beads (https://github.com/beads-tracker/beads) or run with BD_SHIM_ONLY=1 to skip-with-log in CI.\n' >&2
    exit 1
}

# net_available — 0 when the npm registry is reachable, 1 when it is not.
#
# v4.1 / claude-workflow-plugin-20e (C0c). The PREDICATE half of the pair below.
# Some specs need the network for ONE section and can run every other section
# offline; those call this and log their own skip, exactly as
# installer-target-functional.sh does for its `npm ci` legs. Specs that are
# network-dependent end-to-end call net_required_or_skip instead.
#
# The probe asks the question the caller actually has: "can `npm ci` fetch?" —
# not "is a DNS server up". A HEAD against the registry with a hard 8s bound is
# the cheapest honest answer; `npm ping` is the fallback when curl is absent.
#
# CWP_NET=1 / CWP_NET=0 overrides the probe. That exists for two real cases:
# a CI runner behind a proxy where the probe lies, and reproducing an offline
# failure on a machine that does have network. An override is honoured verbatim
# and never re-probed.
net_available() {
    case "${CWP_NET:-}" in
        1|yes|true)  return 0 ;;
        0|no|false)  return 1 ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 8 -o /dev/null "https://registry.npmjs.org/" >/dev/null 2>&1 \
            && return 0
        return 1
    fi
    if command -v npm >/dev/null 2>&1; then
        npm ping --registry "https://registry.npmjs.org/" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# net_required_or_skip — the POLICY half, mirroring bd_required_or_skip.
#
# Prints one "SKIPPED:" line naming the spec and exits 0 (the runner records a
# spec that exits 0 as passing, with zero assertions — we do not fake them).
# Use it at the top of a spec that cannot do anything useful offline.
#
# Deliberately NOT gated on a CI env var the way bd_required_or_skip is gated on
# BD_SHIM_ONLY: bd's absence in CI is a fixed, known property of the runner
# image, whereas network reachability is a per-run condition that can change
# under the same spec. So this one always skips-with-log rather than hard-failing
# anywhere, and the log line is what makes the loss of coverage visible.
net_required_or_skip() {
    if net_available; then
        return 0
    fi
    local spec_name="${BASH_SOURCE[1]##*/}"
    if [ -z "$spec_name" ]; then
        spec_name="<unknown spec>"
    fi
    printf 'SKIPPED: %s (npm registry unreachable; set CWP_NET=1 to force)\n' "$spec_name"
    exit 0
}

# seed_review_records <task-id> [reviewer-identity] [implementer-role] [root]
#
# V3 (claude-workflow-plugin-jio.1): make a task APPROVABLE under the
# review-separation gate. Since V3, `qa-gate.sh approve` refuses unless the
# task carries a review artifact whose reviewer differs from every recorded
# implementer and has no open finding at/above its risk_threshold — so every
# spec whose flow reaches a SUCCESSFUL approve has to model the real review
# flow first. This helper is that model, in one line per call site.
#
# It deliberately goes through the REAL writers rather than hand-crafting
# comment text: `bd comments add` for the IMPLEMENTER record that
# subagent-start.sh writes on spawn, and `qa-gate.sh review-record` (which
# re-validates through review-check.sh) for the artifact. If either grammar
# ever changes, these seeds change with it instead of silently drifting into
# a shape the gate no longer recognises.
#
# Defaults model the common single-agent flow: a backend implementer and the
# QA agent's own `qa-claude` artifact (section 6-prime), which is independent.
# Pass an empty implementer-role ('') to seed a reviewer with NO implementer
# on file; pass reviewer == role to build the non-independent case.
#
# reviewed_hash is pinned to the CURRENT canonical change-set hash so the
# seeded artifact does not trip approve's staleness WARNING. Specs asserting
# on that warning should seed and then mutate the change set themselves.
#
# Returns non-zero (and prints to stderr) if the artifact could not be
# recorded, so a spec that silently lost its seed fails loudly.
# BD_ID_RE — ERE matching a well-formed bd issue id. Use it for the
# "seed task created" sanity assertions.
#
# These assertions used to spell the pattern '^[a-z0-9-]+\.' inline. That only
# ever matched by accident: mk_fixture's tempdir is `component-fixture.XXXXXX.
# <rand>`, `bd init` derives the issue prefix from the directory name, and on
# bd 0.47.x the dots came through verbatim — so every id began
# "component-fixture." and the leading-dot pattern matched. bd 1.1.2 sanitizes
# the derived prefix (`.` -> `_`), producing
# `component-fixture_XXXXXX_<rand>-<suffix>`, and the old pattern matches
# nothing — while the property those assertions are NAMED for ("bd create
# returned a task id") still holds exactly as before.
#
# So this pins the id SHAPE rather than the fixture's directory name: a prefix,
# a hyphen, and an alphanumeric suffix, with a trailing `.<n>` permitted for
# dotted child ids. It still rejects the empty string (the real regression these
# guard against — `jq '.id // empty'` yielding nothing) and any bd error text,
# which contains spaces and colons.
BD_ID_RE='^[A-Za-z0-9._-]+-[A-Za-z0-9.]+$'

# bd_show_with_comments <task-id> — `bd show --json` that always carries
# comment BODIES, across the supported bd range (>=0.47).
#
# bd 1.1.2 stopped inlining comments in `bd show --json`: it returns a
# `comment_count` integer, and the bodies need the new --include-comments flag.
# bd 0.47.x has no such flag and exits 1 ("unknown flag: --include-comments"),
# but inlines .comments already. So try the new form and fall back to the plain
# one — pin the CHAIN, not the leg, the same shape seed_review_records uses for
# `bd comments add || bd comment add`. This mirrors, byte for byte, the helper
# the production scripts (qa-gate.sh, verify-before-stop.sh, review-check.sh,
# subagent-start.sh, bd-github-link.sh) now read through.
#
# Specs asserting on RECORDS must use this. A bare `bd show --json` under 1.1.2
# yields zero comments, so an assertion like "the approval record was written"
# would go green->red for a reason that has nothing to do with the code under
# test — or, worse, a "no record present" assertion would pass vacuously.
#
# Never fails the caller; callers keep the usual
# `(if type=="array" then .[0].comments else .comments end) // []` accessor.
#
# The optional <root> runs the read inside that directory, so specs with a
# `bdq()`/`bdt()`-style `( cd "$root" && bd ... )` wrapper use this ONE helper
# too instead of growing a second, subtly-different variant.
bd_show_with_comments() {
    local tid="$1" root="${2:-}"
    if [ -n "$root" ]; then
        ( cd "$root" 2>/dev/null || exit 0
          bd show "$tid" --json --include-comments 2>/dev/null \
            || bd show "$tid" --json 2>/dev/null \
            || true )
        return 0
    fi
    bd show "$tid" --json --include-comments 2>/dev/null \
        || bd show "$tid" --json 2>/dev/null \
        || true
}

# assert_mutant_applied <label> <source> <mutant> — the MUTANT DID NOT APPLY
# guard. Call it immediately after building a mutant copy, before any assertion
# that only means something against a real mutant.
#
# WHY IT EXISTS (claude-workflow-plugin-94d, QA finding R4-F4). A mutation META
# earns its keep by changing ONE thing and watching exactly one leg flip. If the
# mutation never applied, the "mutant" IS the shipped script: every leg then
# measures shipped behaviour while reporting on a mutant, and the spec goes
# GREEN. That is measured, not hypothesised — two mutants in the `dmi` round were
# built with `\|` alternation, a GNU sed extension BSD sed does not support (this
# tier runs on macOS). The copies came out byte-identical to the original, the
# spec reported 97 pass / 0 fail, and that reads exactly like a healthy run. It
# was caught by eye, which is not a mechanism. This is the mechanism.
#
# A byte-identical mutant is never a legitimate state: a mutation that changes
# nothing tests nothing. So `cmp -s` and fail loudly.
#
# Returns 0 when the mutant differs from its source, 1 when it does not (or when
# it is missing/empty), so call sites can gate their dependent legs:
#
#     if assert_mutant_applied "gbv2-9M" "$SRC" "$MUT"; then
#         ... legs that are only meaningful against a real mutant ...
#     fi
#
# Skipping those legs is the right answer: they cannot pass honestly. The guard
# counts exactly one PASS or FAIL through assert_eq, so the runner still goes red
# and names the guard rather than silently losing assertions.
#
# NOT a replacement for the per-mutant textual sanity checks ("the +2 form is
# present", "the original +1 form is gone", "the strip removed lines"). Those pin
# WHICH mutation landed; this pins THAT one did, which is the half that hides.
assert_mutant_applied() {
    local label="$1" src="$2" mut="$3"
    if ! type assert_eq >/dev/null 2>&1; then
        # No counter to bump: say so on stderr rather than return a silent 0,
        # which is the exact class of failure this guard exists to prevent.
        printf 'assert_mutant_applied: assert.sh is not sourced, so the guard for %s could not be COUNTED\n' \
            "$label" >&2
        return 1
    fi
    local state="applied"
    if [ ! -f "$mut" ]; then
        state="MISSING: the mutant file was never written"
    elif [ ! -s "$mut" ]; then
        state="EMPTY: the mutant file was written with no content"
    elif [ ! -f "$src" ]; then
        state="NO SOURCE: $src is not a readable file to compare against"
    elif cmp -s "$src" "$mut"; then
        state="MUTANT DID NOT APPLY: byte-identical to its source, so the edit matched nothing (a GNU-only sed/awk construct on BSD sed is the recorded cause)"
    fi
    assert_eq "$label: mutant applied (differs from its source)" "applied" "$state"
    [ "$state" = "applied" ]
}

# baseline_incidental_dirt <root> — account for a fixture's INCIDENTAL git dirt
# so the change set under test is the one the spec seeded.
#
# WHY THIS EXISTS (claude-workflow-plugin-94d). `qa-gate.sh reconcile-tracker`
# folds every git-visible path that is NOT in the gate baseline into
# changed-files.txt, because that file is what `change_set_hash` is computed over
# and a path missing from it is a path no approval covers. A component fixture
# that `git init`s but never captures a baseline therefore has ALL of its dirt —
# the harness's own `bin/bd` wrapper and `detect-stack.sh` stub, whatever `bd
# init` scaffolded (`.gitignore`, `CLAUDE.md`, `AGENTS.md`, `.codex/`), the
# fixture's untracked directories — read as this session's work. Assertions then
# fail for reasons that have nothing to do with the code under test: a change set
# stops being doc-only because `.gitignore` is in it, a hash moves between `enter`
# and `approve`, or a worktree delta stops being a subset of the approved set.
#
# THAT STATE IS NOT REALISTIC, which is why the fix belongs in the fixture. In
# production `session-start.sh` captures a baseline on arrival for exactly this
# purpose (see "The gate baseline" in docs/HOOKS.md, and gate-baseline-v2.sh
# section 1.1 which pins that writer). A git repo with dirt and no baseline is a
# state the runtime does not produce.
#
# `--exclude-tracked` is load-bearing: it drops paths already in
# changed-files.txt, so the SUBJECT of the spec — whatever the spec seeded, or
# post-edit recorded — is never baselined and stays gated. Only incidental dirt
# is absorbed. Call it AFTER the tracker is seeded and BEFORE the Stop/approve
# under test.
#
# Silent and best-effort by design: a spec that calls this on a non-git fixture
# gets a no-op, which is the same thing the reconciler does there.
baseline_incidental_dirt() {
    local root="$1"
    [ -n "$root" ] || return 0
    [ -x "$root/.claude/scripts/qa-gate.sh" ] || [ -f "$root/.claude/scripts/qa-gate.sh" ] || return 0
    ( cd "$root" 2>/dev/null || exit 0
      CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" \
          baseline-capture --by session-start --exclude-tracked >/dev/null 2>&1 ) || true
    return 0
}

seed_review_records() {
    local tid="$1"
    local reviewer="${2:-qa-claude}"
    local role="${3:-backend}"
    local root="${4:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    if [ -z "$tid" ]; then
        printf 'seed_review_records: <task-id> is required\n' >&2
        return 1
    fi

    local sanitized
    sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')

    if [ -n "$role" ]; then
        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
        (cd "$root" && bd comments add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1) \
            || (cd "$root" && bd comment add "$tid" "IMPLEMENTER: role=$role task=$tid at $ts" >/dev/null 2>&1) \
            || { printf 'seed_review_records: could not add IMPLEMENTER comment on %s\n' "$tid" >&2; return 1; }
    fi

    # v5 D2 (claude-workflow-plugin-fkm.4): seed the design-satisfied
    # precondition BEFORE the review artifact below, deliberately — it writes
    # a NEW tracked path (docs/specs/<tid>.md) exactly as review-record's own
    # canonical artifact does, and the reconcile + impact-report refresh a
    # few lines down (already here for review-record's sake) must see BOTH
    # new paths in one pass rather than staling itself against this one.
    # design-record's own edit-ban (designer_touched_source) is already
    # disarmed by the IMPLEMENTER comment just posted, so it does not matter
    # what else a caller has staged in the tracker before this call.
    seed_design_verdict "$tid" "$root" || return 1

    local hash=""
    if [ -f "$root/.claude/scripts/impact-report.sh" ]; then
        hash=$(CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
    fi
    # claude-workflow-plugin-wob2 (L2), FALLBACK ONLY — never a preemptive
    # append, and applied ONLY here (not to the post-review-record reconcile
    # a few lines down, which stays exactly as it shipped — see that block's
    # own comment for why growing the tracker there regressed a sibling
    # spec that resets changed-files.txt to an exact list and expects a
    # Stop/gate check to see THAT list). review-check.sh validate-artifact
    # now refuses reviewed_hash outright when it is not 64 lowercase hex,
    # OR when it is the SHA-256 empty-content digest specifically (a
    # degradation sentinel that would compare equal to itself forever; see
    # that check's own header) — and $hash reads back as exactly that
    # digest whenever changed-files.txt is absent-or-empty at this instant
    # (impact-report.sh's own documented behaviour, reachable here because
    # this is already the ONE place a spec says "make this task
    # approvable" and not every caller stages a subject file first).
    # MEASURED (this task's own reproduction): appending unconditionally —
    # even when a caller had ALREADY staged its own subject file before
    # calling this function — grows the tracker the caller's later
    # `approve` binds to beyond what that caller controls. So: recompute is
    # tried FIRST, unmodified, and the design doc seed_design_verdict
    # already wrote is used to break the tie ONLY when that recompute came
    # back degenerate — i.e., only in the exact state (qa-gate.sh's own
    # "seed_review_records with nothing else staged" case) this fix exists
    # to correct, never disturbing a caller whose tracker was already
    # producing a real answer.
    if [ -z "$hash" ] || [ "$hash" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
        mkdir -p "$root/.claude/.qa-tracking" 2>/dev/null || true
        printf '%s\n' "$root/docs/specs/$sanitized.md" >> "$root/.claude/.qa-tracking/changed-files.txt"
        if [ -f "$root/.claude/scripts/impact-report.sh" ]; then
            hash=$(CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
        fi
    fi
    [ -z "$hash" ] && hash="unverified"

    # Real artifact path convention (review-artifact-<sanitized>-r<n>.json) so
    # approve's post-approval scratch-file cleanup is exercised too.
    local art="$root/.claude/.qa-tracking/review-artifact-$sanitized-r1.json"
    mkdir -p "$root/.claude/.qa-tracking" 2>/dev/null || true
    cat > "$art" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"$reviewer","reviewer_model":"seeded-fixture","reviewer_pin":"seeded-fixture","reviewed_hash":"$hash","risk_threshold":"high","stop_condition":"seeded fixture: every acceptance criterion traced","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}
JSON

    # claude-workflow-plugin-rqer (v5 D2): review-record's --file now asserts
    # the CANONICAL derived path (docs/reviews/<tid>-r<n>.json) rather than
    # accepting an arbitrary one — see review_artifact_path_for in
    # qa-gate.sh. Piped via stdin instead: review-record writes the canonical
    # copy itself, so this seed's `$art` scratch file (left at its
    # .qa-tracking path above, on purpose — a seed fixture, not the artifact
    # under test) needs no renaming to satisfy the new check.
    if ! CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" \
            review-record "$tid" < "$art" >/dev/null 2>&1; then
        printf 'seed_review_records: qa-gate.sh review-record failed for %s\n' "$tid" >&2
        return 1
    fi
    # claude-workflow-plugin-rqer (v5 D2), AC-6's explicitly-named seam: the
    # canonical artifact review-record just wrote (docs/reviews/<tid>-r1.json)
    # is itself a real, tracked path now (AC-4 — it enters the change set),
    # so any impact report already generated for $tid (by a caller's own
    # `enter`) is stale the instant this returns. RECONCILE FIRST so the
    # tracker already carries the new path when impact-report.sh hashes it —
    # impact-report.sh only reads the tracker as it stands, it does not
    # itself discover git-visible dirt (that is reconcile_tracker's job,
    # normally run by `approve` itself). Regenerating before reconciling
    # would just re-hash the SAME stale list, and approve's own reconcile a
    # moment later would move the tracker again, staling the report a
    # second time. Best-effort: a caller with no git repo or no impact
    # report yet is unaffected either way.
    if [ -f "$root/.claude/scripts/impact-report.sh" ]; then
        CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" \
            reconcile-tracker >/dev/null 2>&1 || true
        CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" \
            "$tid" >/dev/null 2>&1 || true
    fi
    seed_completion_record "$tid" "${role:-backend}" "$root" || return 1
    return 0
}

# seed_completion_record <tid> [role] [root] [files-json] — the F7 completion
# contract record (P7 / claude-workflow-plugin-qbhw).
#
# WHY IT IS FOLDED INTO seed_review_records ABOVE. approve now REFUSES (exit 2,
# error_key=completion_record_missing) unless the task carries a validated
# COMPLETION v1 record, so every spec that drives approve to SUCCESS acquired a
# precondition it predates. seed_review_records is already the ONE place a spec
# says "make this task approvable" — it exists because the V3 review-separation
# refusal created exactly this migration — so the new precondition belongs
# there rather than at eighty call sites. Specs testing the completion refusal
# itself simply do not call it.
#
# SEEDED THROUGH THE REAL WRITER, like the review artifact above: a change to
# the record grammar or the payload schema must break these specs loudly
# instead of leaving them asserting against a shape nothing produces.
#
# files_changed DEFAULTS TO [] and that is deliberate. Most fixtures stage a
# change set that is the SUBJECT of their own assertions, and a fabricated
# declaration would put approve's completeness cross-check (fkm.1.20) into the
# observations those assertions read. An empty declaration is the accurate one
# for a fixture that authored no files. Specs exercising the cross-check pass
# their own JSON array as the fourth argument.
seed_completion_record() {
    local tid="$1"
    local role="${2:-backend}"
    local root="${3:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    local files_json="${4:-[]}"
    if [ -z "$tid" ]; then
        printf 'seed_completion_record: <task-id> is required\n' >&2
        return 1
    fi
    local sanitized pay
    sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
    pay="$root/.claude/.qa-tracking/completion-draft-$sanitized.json"
    mkdir -p "$root/.claude/.qa-tracking" 2>/dev/null || true
    cat > "$pay" <<JSON
{"task_id":"$tid","role":"$role","model":"seeded","pin":"seeded","files_changed":$files_json,"tests_added":[],"decisions":["seeded fixture"],"blockers":[],"llm_observations":"seeded by the component fixture harness","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown"}
JSON
    if ! CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" \
            completion-record "$tid" --file "$pay" >/dev/null 2>&1; then
        printf 'seed_completion_record: qa-gate.sh completion-record failed for %s\n' "$tid" >&2
        return 1
    fi
    return 0
}

# seed_design_verdict <tid> [root] — the design-satisfied precondition (v5 D2
# / claude-workflow-plugin-fkm.4): a minimal schema-valid design artifact, a
# real `design-record`, and a satisfied `design-review-record` from a
# genuinely DIFFERENT identity ("design-claude" — the fixed literal
# design-reviewer.md emits, distinct from design-record's own "designer"
# default, so this never trips the independence refusal it is seeding
# AROUND). Folded into seed_review_records for the identical reason
# seed_completion_record is (see that function's own header): approve now
# REFUSES (exit 2, error_key names which) unless design-satisfied holds,
# UNLESS --no-design.
#
# THE COMPLETENESS CLAIM THAT USED TO BE HERE WAS FALSE, MEASURED (fkm.4
# R2-F1). This function folding into seed_review_records means every spec
# that SEEDS THROUGH THIS SHARED HELPER acquired the precondition for free —
# it does NOT mean "every spec driving approve to SUCCESS acquired this
# precondition too", which is what an earlier revision of this comment
# claimed. A spec with its OWN spec-local seed helper (one that composes the
# real writers directly instead of calling seed_review_records — the pattern
# this file's own seed_completion_record header recommends for specs needing
# per-record control) does NOT pick this up automatically, and five specs
# doing exactly that were measured red by execution: 91 assertions across
# verify-review-discipline.sh, arbitration-acceptance.sh,
# review-artifact-durability.sh, worktree-approval-resolution.sh, and
# qa-gate.sh's P7 family, every one seeding through a spec-local helper that
# predates this function and was never told to call it. Each of those five
# was fixed individually — all 13 call sites via `--no-design '<reason>'`
# at the approve call site; NONE via a seeded design-review-record (an
# earlier revision of this paragraph claimed some were, which was also
# false, measured — fkm.4 R3-F1) — see that task's fix history for the
# enumerated per-spec reasoning. Specs testing the design refusal itself
# simply do not call this function (or call approve with --no-design
# directly), which is the one part of the original claim that was already
# correct.
#
# SEEDED THROUGH THE REAL WRITERS, like every other record this file seeds: a
# change to either grammar must break these specs loudly instead of leaving
# them asserting against a shape nothing produces.
#
# WRITES A REAL TRACKED FILE (docs/specs/<tid>.md) — unlike the review
# artifact's scratch hand-off copy above, design-record's OWN containment
# rule means there is no denylisted-scratch-copy option here; the artifact
# IS the file `qa-gate.sh design-record` binds. Callers must reconcile +
# refresh the impact report AFTER this returns (seed_review_records already
# does, for review-record's own new path, and this function is called before
# that refresh specifically so one pass covers both).
# seed_grilling_record <tid> [root] — the grilling-record precondition (v5 D3
# / claude-workflow-plugin-fkm.5): design-record now REFUSES
# (grilling_record_missing) unless a `GRILLING v1` record exists on the task
# or its parent epic. Folded into seed_design_verdict for the identical
# reason seed_completion_record and seed_design_verdict are folded into
# seed_review_records (see their own headers): every spec seeding through the
# shared helper acquires the precondition for free. Specs testing the
# grilling precondition itself, or the design refusal in isolation
# (verify-design-discipline.sh, which calls design-record directly and does
# NOT go through this shared helper), call this directly or pass
# --no-grilling themselves — see grilling-record.test.sh for the dedicated
# spec.
#
# SEEDED THROUGH THE REAL WRITER, like every other record this file seeds: a
# change to the record grammar must break these specs loudly instead of
# leaving them asserting against a shape nothing produces. This is also why
# mk_fixture symlinks .claude/vendor now — this writer hashes the vendored
# brainstorming SKILL.md, and without it this call refuses
# vendor_hash_unavailable.
seed_grilling_record() {
    local tid="$1"
    local root="${2:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    if [ -z "$tid" ]; then
        printf 'seed_grilling_record: <task-id> is required\n' >&2
        return 1
    fi
    if ! CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" \
            grilling-record "$tid" --rounds 3 --questions 5 --approaches 2 --unresolved 0 \
            "seeded fixture: component-tier harness only" >/dev/null 2>&1; then
        printf 'seed_grilling_record: qa-gate.sh grilling-record failed for %s\n' "$tid" >&2
        return 1
    fi
    return 0
}

seed_design_verdict() {
    local tid="$1"
    local root="${2:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    if [ -z "$tid" ]; then
        printf 'seed_design_verdict: <task-id> is required\n' >&2
        return 1
    fi
    # v5 D3 (claude-workflow-plugin-fkm.5): design-record now refuses
    # `grilling_record_missing` without a GRILLING v1 record on the task or
    # its parent epic — seed one FIRST, through the real writer, exactly as
    # this function already does for every other precondition it acquires.
    seed_grilling_record "$tid" "$root" || return 1
    local sanitized art design_hash
    sanitized=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
    mkdir -p "$root/docs/specs" 2>/dev/null || true
    art="$root/docs/specs/$sanitized.md"
    cat > "$art" <<DESIGNDOC
# Design — $tid

## Problem
Seeded fixture design (component-tier harness only).

## Approaches considered
1. A second, richer seed convention — rejected: no reuse to justify one.
2. This minimal artifact — chosen: matches every other seed helper's "just
   enough to validate" shape.

## Chosen approach
Seed a schema-valid design so approve's design-satisfied refusal does not
block specs that are not testing it.

## Units
See the machine block.

## Global constraints
None.

## Out of scope
Everything this fixture does not seed.

## Verification plan
make test-component

## Revision log
- v1 seeded by the component fixture harness.

<!-- DESIGN-UNITS BEGIN -->
\`\`\`json
{
  "contract_version": "1",
  "task_id": "$tid",
  "designer_identity": "designer",
  "units": [
    {
      "unit_id": "U1",
      "role": "devops",
      "goal": "seeded unit",
      "acceptance": [ { "id": "AC1", "text": "seeded fixture: nothing asserted" } ],
      "files": [ ".claude/scripts/qa-gate.sh" ],
      "verification": "make test-component",
      "depends_on": []
    }
  ]
}
\`\`\`
<!-- DESIGN-UNITS END -->
DESIGNDOC
    if ! CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" \
            design-record "$tid" >/dev/null 2>&1; then
        printf 'seed_design_verdict: qa-gate.sh design-record failed for %s\n' "$tid" >&2
        return 1
    fi
    design_hash=$(CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/workflow-manifest.sh" hash-file "$art" 2>/dev/null) || design_hash=""
    if [ -z "$design_hash" ]; then
        printf 'seed_design_verdict: could not hash the seeded design artifact for %s\n' "$tid" >&2
        return 1
    fi
    if ! CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" \
            design-review-record "$tid" --design-hash "$design_hash" \
            <<< '{"verdict":"satisfied","criterion_results":[{"criterion":"DS1","pass":true,"justification":"seeded fixture"}],"required_fixes":[],"iteration":1,"rubric_version":"1","reviewer_identity":"design-claude"}' \
            >/dev/null 2>&1; then
        printf 'seed_design_verdict: qa-gate.sh design-review-record failed for %s\n' "$tid" >&2
        return 1
    fi
    return 0
}

mk_fixture() {
    # IMPORTANT: callers MUST invoke this WITHOUT command substitution. The
    # function exports CLAUDE_PROJECT_DIR + PATH into the caller's shell;
    # under `FIXTURE=$(mk_fixture)` the exports happen in a subshell and
    # are immediately discarded. Read the result via $COMPONENT_FIXTURE_PATH.
    local root
    root=$(mktemp -d -t component-fixture.XXXXXX)
    __COMPONENT_FIXTURES_TO_CLEAN+=("$root")
    # Export for legacy command-substitution callers AND set the global
    # for in-shell callers.
    export COMPONENT_FIXTURE_PATH="$root"

    mkdir -p "$root/.claude/.qa-tracking" "$root/.claude/scripts" \
        "$root/.claude/skills/workflow-engine" "$root/.beads" "$root/bin"

    local plugin
    plugin=$(plugin_root)

    # Symlink every script from the plugin into the fixture so the
    # script-under-test sees its sibling helpers (current-task.sh,
    # qa-gate.sh, detect-stack.sh, etc.) at the expected path. Symlinks
    # rather than copies because the script-under-test pulls its dependents
    # via relative paths from .claude/scripts/.
    local s
    for s in "$plugin"/.claude/scripts/*.sh; do
        [ -f "$s" ] || continue
        ln -sf "$s" "$root/.claude/scripts/$(basename "$s")"
    done

    # Workflow skill (needed by intent-router.sh + session-start.sh).
    if [ -f "$plugin/.claude/skills/workflow-engine/SKILL.md" ]; then
        ln -sf "$plugin/.claude/skills/workflow-engine/SKILL.md" \
            "$root/.claude/skills/workflow-engine/SKILL.md"
    fi

    # v5 D3 (claude-workflow-plugin-fkm.5): the vendor tree, needed by
    # `qa-gate.sh grilling-record` — it hashes
    # .claude/vendor/superpowers/brainstorming/SKILL.md via
    # workflow-manifest.sh hash-file, and without it every call refuses
    # `vendor_hash_unavailable`. ONE symlink of the whole directory (like the
    # workflow-engine skill above), not a per-file copy: the vendor tree is
    # read-only reference material nothing in this tier writes to.
    #
    # `-n` (QA R1-F4): `mk_fixture` mints a fresh `mktemp -d` root per call
    # and takes no root parameter, so `$root/.claude/vendor` never pre-exists
    # today — the hazard `-n` closes is UNREACHABLE at present. It is real
    # though, measured directly: `ln -sf <dir> <existing-symlink-to-dir>`
    # DEREFERENCES the existing link and creates a stray same-named link
    # INSIDE the real target instead of re-pointing the original — reproduced
    # in a scratch dir before this line was written. `-n` (POSIX `-h`'s
    # cross-implementation alias; present on this BSD `ln` per its own man
    # page, and standard GNU coreutils) treats the destination as an ordinary
    # entry rather than following it, so a future caller that adds a `root`
    # parameter or a re-init path cannot reopen this latently.
    if [ -d "$plugin/.claude/vendor" ]; then
        ln -sfn "$plugin/.claude/vendor" "$root/.claude/vendor"
    fi

    # Minimal settings.json so the manifest is well-formed in case the
    # script-under-test inspects it. Hooks-aware shape; we don't actually
    # fire hooks from this file in component tests (specs invoke scripts
    # directly), but the file exists so any inspect-the-manifest path is
    # exercised against a valid stub.
    cat > "$root/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": ".claude/scripts/session-start.sh"}]}]
  }
}
JSON

    # Install the bd wrapper. mk_bd_shim writes into $root/bin/bd.
    mk_bd_shim "$root" >/dev/null

    # Prepend the shim dir to PATH so subsequent `bd` calls hit the wrapper.
    # We do NOT export at file-scope (would leak across specs); instead we
    # mutate PATH in the caller's shell. The runner subshells each spec,
    # so this is scoped correctly.
    export PATH="$root/bin:$PATH"
    export CLAUDE_PROJECT_DIR="$root"

    # Phase V2 (1vq.1): host isolation for the optional Codex reviewer lane.
    # codex-detect.sh (invoked by session-start.sh and by model-select.sh's
    # detect_reviewer_lane seam) reads the Codex MCP registration from
    # ${CODEX_USER_CONFIG:-$HOME/.claude.json}. Pin it to a NONEXISTENT
    # in-fixture path so component specs never depend on the host developer's
    # ~/.claude.json (which may or may not register codex): the reviewer lane
    # then deterministically resolves to config-absent -> claude. Specs that
    # exercise the codex lane override CODEX_USER_CONFIG / CODEX_MCP_BIN
    # themselves. The ONLY consumer of this var is codex-detect.sh, so this is
    # purely additive host-isolation.
    export CODEX_USER_CONFIG="$root/.claude/.no-codex-config.json"

    # Initialise Beads inside the fixture, through the PATH wrapper. Cd into
    # the project for the init; cd back so we don't surprise the caller.
    # `bd init` is silent on success.
    (cd "$root" && bd init >/dev/null 2>&1) || true

    # Undo the repo `bd init` now creates. bd 1.1.2's init runs `git init` and
    # scaffolds CLAUDE.md / AGENTS.md / .claude/settings.json / .codex/; 0.47.x
    # created neither. A component fixture is a BARE TEMPDIR by contract, and
    # several specs depend on that directly:
    #   - denylist-shared.sh asserts "intentionally NOT a git repo"
    #   - verify-before-stop.sh's ALLOW paths rely on the Stop hook's
    #     `git status` fallback finding nothing, which a fresh repo full of
    #     untracked fixture files does not
    # Leaving the repo in place turns those into failures that have nothing to
    # do with the code under test. Specs that WANT a git checkout run their own
    # `git init` after mk_fixture, so removing it here cannot take one away.
    # bd is unaffected: its store is .beads/embeddeddolt, not git.
    #
    # `--skip-agents --skip-hooks` suppresses the CLAUDE.md/.claude scaffolding
    # but NOT the git init, so this removal is the only way back to the
    # documented fixture shape. Guarded on the path so a bug in $root can never
    # turn this into an `rm -rf` somewhere else.
    if [ -n "$root" ] && [ -d "$root/.git" ]; then
        rm -rf "$root/.git"
    fi

    # IMPORTANT: cd INTO the fixture in the caller's shell. The plugin's
    # hook scripts (qa-gate.sh, etc.) invoke `bd label add` etc. without
    # threading --db or --repo, relying on cwd to locate the right .beads.
    # If the caller's cwd is the real plugin root, the test would write to
    # the plugin's production Beads database — a major regression. Forcing
    # cwd into the fixture is the simplest correct contract.
    cd "$root"

    # Intentionally no `printf '%s' "$root"` — the path is available via
    # $COMPONENT_FIXTURE_PATH; emitting it on stdout would corrupt specs
    # that source this function without command substitution.
}

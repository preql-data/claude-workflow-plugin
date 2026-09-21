#!/bin/bash
# model-roles.test.sh — L1 unit tests for role-aware model selection:
# v4.0.0 Phase V1 (claude-workflow-plugin-bi3.1) and the v5.0.0 Phase D0
# expansion from three role classes to five (claude-workflow-plugin-fkm.2).
#
# Everything here is offline and self-contained: each case builds a tempdir
# sandbox with the plugin scripts symlinked in and drives the real
# model-select.sh / workflow-model-apply.sh / statusline.sh against crafted
# .claude/model-roles + artifact fixtures. No network, no bd, no API key.
#
# Sections:
#   1. role_strategy parsing (via `model-select.sh roles`): valid /
#      whitespace-tolerant / unknown-strategy->top+warn / unknown-key-ignored
#      / missing-file->all-top. The reported role set is derived from
#      ALL_ROLES rather than listed.
#   2. reviewer_lane resolution (via `model-select.sh status`): config
#      default / claude force / env seam / codex-detect.sh probe deferral /
#      unknown-value->auto+warn.
#   3. workflow-model-apply.sh --print-role-map: covers exactly the agents on
#      disk, and CONCRETE_ROLES agrees with model-select.sh's ALL_ROLES.
#   4. statusline role rendering: the five-role group-and-truncate render
#      (4.7-4.12, the D0 plan's exact table), the v4 three-role artifact still
#      rendering (4.3), lane=codex `sol` substitution per lane, the
#      artifact-absent fallback, short_id shapes, and a MAX_GROUPS META.
#   5. packaging parity: install.sh ships .claude/model-roles, install.ps1
#      carries the matching asset, and a META strip proves the check fails
#      when the copy line is removed.
#   6. current_pin has an arm per role — the D0 SILENT-SKIP hazard. The META
#      strips the `designer)` arm and proves the lane goes unwritten at exit 0.
#   7. family-class strategy grammar (`<family>-class`) and the typo guard;
#      the META reverts the rule to the pre-D0 `opus-class` literal.
#   8. per-unit escalation: escalate / idempotency / restore / idempotent
#      restore. FILE STATE AND REVERSIBILITY ONLY — see correction 13.
#   9. identity collapse, missing_keys, and the session-model guard
#      (read-compare-write, plus the "cannot compare != no drift" control).
#
# Sections 6-9 each ship a paired negative control: a mutation of the SHIPPED
# artifact with a leg proving the mutation landed, an assertion naming the
# check that would fail, a restore control, and at least one leg that RUNS the
# shipped script rather than reading it.
#
#   12. apply --check is DETECT-AND-WARN, never a write (claude-workflow-
#       plugin-j7kk, B2, R4-F1 ruling): a drifted sandbox is reported (naming
#       role, current pin, resolved pin and the explicit apply command) with
#       nothing written; a settled sandbox says so plainly; `apply` WITHOUT
#       --check is unchanged (still writes, the same call site 6.1 already
#       exercises); the META neutralises the CHECK_ONLY gate at BOTH of its
#       call sites and proves --check would then ALSO write — the exact
#       regression this flag exists to prevent.
#   14. check-parity (claude-workflow-plugin-a13r) is a HARD exit-code gate
#       over the identical config/file comparison --check (12) reports
#       advisory-only: agreement, single-role drift (landing-proven, then
#       fixed by apply and re-checked), no-cache UNVERIFIABLE (never a
#       false pass), an active implementer escalation excluded rather than
#       misread as drift, a missing agent file excluded the same way, and a
#       META that neutralises the comparison in a copy of the shipped
#       script to prove a broken check-parity would silently pass real
#       drift. ROUND 2 (independent review) added four more false-success
#       controls, each pairing a landing-proven fixture with a META that
#       reverts JUST that fix in a copy of the shipped script: 14.7 a cache
#       whose `.models` is present but not the documented array shape (an
#       object) must read as UNVERIFIABLE, never a coincidental OK; 14.8 a
#       role with NO strategy key in .claude/model-roles at all is still
#       evaluated against the fail-open `top` default, but the OK/
#       DISAGREEMENT wording must say so rather than claiming a declaration
#       that was never made; 14.9 an agent file that EXISTS but whose
#       `model:` pin cannot be read (malformed frontmatter, or — where the
#       test does not run as root — chmod 000) must be folded into
#       DISAGREEMENT, never silently excluded the way a genuinely absent
#       file is; 14.10 is the WIDENED-COVERAGE proof itself: every
#       discovered agent file in a role class is compared, not one
#       representative, so a sibling drift (e.g. devops.md disagreeing with
#       backend.md, both `implementer`) is caught by name — the META here
#       reverts to a representative-only comparison and shows it would
#       silently miss exactly that drift.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

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

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' \
            "$name" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    forbidden: %s\n    haystack:  %s\n' \
            "$name" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    fi
}

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
MS="$PROJECT_DIR/.claude/scripts/model-select.sh"
APPLY="$PROJECT_DIR/.claude/scripts/workflow-model-apply.sh"
SL="$PROJECT_DIR/.claude/scripts/statusline.sh"
CURRENT_TASK="$PROJECT_DIR/.claude/scripts/current-task.sh"
INSTALL_SH="$PROJECT_DIR/install.sh"
INSTALL_PS1="$PROJECT_DIR/install.ps1"

if ! command -v jq >/dev/null 2>&1; then
    printf 'model-roles.test.sh: jq required but not on PATH\n' >&2
    exit 2
fi

TESTROOT=$(mktemp -d "${TMPDIR:-/tmp}/model-roles-l1.XXXXXX")
trap 'rm -rf "$TESTROOT"' EXIT

# --- BD-ISOLATION-BEGIN (claude-workflow-plugin-j7kk) -----------------------
# THIS FILE WAS CAN-REACH(WRITE) AGAINST THE PRODUCTION BEADS STORE.
# MEASURED (census refutation run, claude-workflow-plugin-j7kk): a
# PATH-shimmed, non-executing `bd` driven over every section of this file
# recorded 417 repo-root-cwd bd calls (186 comment, 151 show, 35 create, 35
# list, 10 --version), bodies `MODEL SWITCH [role] claude-base-0 -> ...`,
# landing on this repo's real .beads store — corroborated store-side: the
# task claude-workflow-plugin-ofd carried 9,937 such comments before this
# fix, and RE-MEASURED during this fix's own session at 10,123 (exactly one
# more 186-comment run), proving the exposure was still live, not merely
# historical.
#
# THE MECHANISM new_sandbox() BELIEVED PROTECTED IT DID NOT. bd resolves its
# store from CWD alone (census, section 1.0) — CLAUDE_PROJECT_DIR, BEADS_DIR,
# BEADS_DB and --db are all INERT as store redirects on bd 1.2.2. This file
# never changes cwd away from the repo root, so a real `bd` on PATH always
# resolves the real .beads regardless of the CLAUDE_PROJECT_DIR each
# new_sandbox() carries. find_or_create_meta_task()'s only availability
# guard is `command -v bd` (model-select.sh:927) — no check that a .beads/
# directory exists anywhere — so a real bd being reachable at all was
# sufficient for every `... apply` call below to write a live audit comment.
#
# FIX: mechanism C (bd stub on PATH), chosen over mechanism A (cd into a
# fixture store) because this file's subject is model-select.sh's DECISIONS,
# not bd's storage, and it never relocates cwd today. ONE top-level PATH
# mutation, not a per-sandbox stub inside new_sandbox(): every call site
# below is `SB=$(new_sandbox)`, a command-substitution SUBSHELL — an
# `export PATH=` executed inside new_sandbox() would die with that subshell
# and never reach the caller, so a per-function fix would need every call
# site individually re-taught `PATH="$SB/bin:$PATH"`, and the next one added
# here would as reliably forget it as model-select.sh:927 forgot the
# `.beads`-presence half of its own guard (census, section 1.3). A single
# prepend, done once, before ANY sandbox exists, covers every current AND
# future invocation in this file structurally.
#
# The stub REFUSES every subcommand (exit 1) rather than emulating one:
# model-select.sh's own callers already tolerate a missing/failing bd
# (find_or_create_meta_task returns 1 on `! command -v bd`; record_switch and
# record_switch_role both `|| return 0`), so refusing changes no assertion in
# this file — nothing here inspects the meta-task audit trail, only the
# model PINS written to agent .md files and the warning text on stderr.
BD_STUB_LOG="$TESTROOT/bd-stub-calls.log"
BD_STUB_BIN=$(mktemp -d "$TESTROOT/bd-stub-bin.XXXXXX")
cat > "$BD_STUB_BIN/bd" <<STUB
#!/bin/bash
# Isolation stub — claude-workflow-plugin-j7kk. Logs the subcommand (for
# this file's own non-vacuity check, Section 11 below) and refuses, so no
# invocation anywhere in this spec can reach a real Beads store.
printf '%s\n' "\${1:-<empty>}" >> "$BD_STUB_LOG"
exit 1
STUB
chmod +x "$BD_STUB_BIN/bd"
export PATH="$BD_STUB_BIN:$PATH"

# The read-only witness that the fix actually holds, not merely that it was
# written: same predicate the L1 harness canary (run-tests.sh) uses — a
# plain `SELECT hashof('HEAD')` never moves on a read (12 consecutive reads,
# zero false positives, claude-workflow-plugin-j7kk census) — captured
# BEFORE any sandbox in this file runs and compared after the LAST one, at
# the foot of this file (Section 11). Gracefully DISARMED (informational,
# non-fatal) when dolt or the store's embedded-Dolt layout is unavailable,
# matching every other DISARM path this task adds; this is a defense-in-depth
# self-check, not a substitute for the tier-wide guard, which is a separate,
# paired addition to run-tests.sh / runner-completeness.test.sh.
BD_ISOLATION_STORE="$PROJECT_DIR/.beads/embeddeddolt/beads"
BD_ISOLATION_ARMED=0
BD_ISOLATION_HASH_BEFORE=""
if command -v dolt >/dev/null 2>&1 && [ -d "$BD_ISOLATION_STORE/.dolt" ]; then
    BD_ISOLATION_HASH_BEFORE=$(cd "$BD_ISOLATION_STORE" 2>/dev/null \
        && dolt sql -r csv -q "SELECT hashof('HEAD')" 2>/dev/null | tail -n1)
    case "$BD_ISOLATION_HASH_BEFORE" in
        ''|*[Hh]ashof*) BD_ISOLATION_ARMED=0 ;;
        *)              BD_ISOLATION_ARMED=1 ;;
    esac
fi
# --- BD-ISOLATION-END (claude-workflow-plugin-j7kk) -------------------------

# new_sandbox — print a fresh project-root path with the plugin scripts
# symlinked in and seven base-pinned agent files. Callers write their own
# .claude/model-roles / model-ranking / artifact fixtures.
#
# bd ISOLATION IS NOT DONE HERE (claude-workflow-plugin-j7kk). This used to
# be the whole bug: CLAUDE_PROJECT_DIR=$d (below) redirects the FILE surfaces
# this sandbox builds, but bd itself resolves its store from cwd alone, so a
# per-sandbox stub would need every `bash "$MS"/"$APPLY"/"$SL"/"$SS"` call
# site to also carry `PATH="$d/bin:$PATH"` — and `new_sandbox` runs inside
# `SB=$(new_sandbox)`, a command-substitution SUBSHELL, so an `export PATH=`
# in here would die with it. See the BD-ISOLATION block at the top of this
# file for the actual fix: one PATH mutation, done once, before any sandbox
# exists.
new_sandbox() {
    local d
    d=$(mktemp -d "$TESTROOT/sb.XXXXXX")
    mkdir -p "$d/.claude/scripts" "$d/.claude/agents" "$d/.claude/.qa-tracking"
    ln -sf "$MS" "$d/.claude/scripts/model-select.sh"
    ln -sf "$APPLY" "$d/.claude/scripts/workflow-model-apply.sh"
    ln -sf "$SL" "$d/.claude/scripts/statusline.sh"
    ln -sf "$CURRENT_TASK" "$d/.claude/scripts/current-task.sh"
    local a
    for a in orchestrator qa backend frontend devops grader judge; do
        printf -- '---\nname: %s\nmodel: claude-base-0\n---\nbody\n' "$a" \
            > "$d/.claude/agents/$a.md"
    done
    printf '%s' "$d"
}

# roles_strategy <sandbox> <role> — the strategy column from `roles`.
roles_strategy() {
    CLAUDE_PROJECT_DIR="$1" bash "$MS" roles 2>/dev/null \
        | awk -F'\t' -v r="$2" '$1 == r { print $2 }'
}

# status_lane <sandbox> [env-assignment] — the reviewer lane from `status`.
status_lane() {
    local sb="$1"
    CLAUDE_PROJECT_DIR="$sb" bash "$MS" status 2>/dev/null \
        | grep '^reviewer lane:' | head -1 | sed -E 's/^reviewer lane:[[:space:]]*//'
}

# ---------------------------------------------------------------------------
echo "=== Section 1: role_strategy parsing ==="

SB=$(new_sandbox)
printf 'orchestrator=top\nimplementer=opus-class\nreviewer=top\n' > "$SB/.claude/model-roles"
assert_eq "1.1 valid: orchestrator=top" "top" "$(roles_strategy "$SB" orchestrator)"
assert_eq "1.1 valid: implementer=opus-class" "opus-class" "$(roles_strategy "$SB" implementer)"
assert_eq "1.1 valid: reviewer=top" "top" "$(roles_strategy "$SB" reviewer)"

SB=$(new_sandbox)
printf 'orchestrator = top\n  implementer =   opus-class  \nreviewer=top\n' > "$SB/.claude/model-roles"
assert_eq "1.2 whitespace-tolerant: implementer" "opus-class" "$(roles_strategy "$SB" implementer)"
assert_eq "1.2 whitespace-tolerant: orchestrator" "top" "$(roles_strategy "$SB" orchestrator)"

SB=$(new_sandbox)
printf 'orchestrator=top\nimplementer=banana\nreviewer=top\n' > "$SB/.claude/model-roles"
assert_eq "1.3 unknown-strategy value falls back to top" "top" "$(roles_strategy "$SB" implementer)"
WARN_13=$(CLAUDE_PROJECT_DIR="$SB" bash "$MS" roles 2>&1 >/dev/null)
assert_contains "1.3 unknown-strategy warns loudly" "unknown strategy 'banana'" "$WARN_13"

SB=$(new_sandbox)
printf 'foobar=top\norchestrator=opus-class\nimplementer=opus-class\nreviewer=top\n' > "$SB/.claude/model-roles"
# Unknown key is ignored; the real roles still resolve from their keys.
#
# EXPECTED SET IS DERIVED, not spelled out: it comes from ALL_ROLES in
# model-select.sh, the same constant the subcommand iterates. Hardcoding five
# role names here would re-create in the test the coupling D0 removed from the
# script — and a test that knows the answer independently of the source of
# truth stops testing agreement and starts testing itself.
EXPECTED_ROLES=$(sed -n 's/^ALL_ROLES="\(.*\)"$/\1/p' "$MS" | head -1 | tr ' ' '\n' | sort | tr '\n' ',')
assert_eq "1.4 precondition: ALL_ROLES is readable from model-select.sh" \
    "yes" "$([ -n "$EXPECTED_ROLES" ] && [ "$EXPECTED_ROLES" != "," ] && echo yes || echo no)"
ROLES_14=$(CLAUDE_PROJECT_DIR="$SB" bash "$MS" roles 2>/dev/null | awk -F'\t' '{print $1}' | sort | tr '\n' ',')
assert_eq "1.4 unknown key ignored (exactly the ALL_ROLES set is reported)" \
    "$EXPECTED_ROLES" "$ROLES_14"
assert_eq "1.4 unknown key does not shadow a real role" "opus-class" "$(roles_strategy "$SB" orchestrator)"
# The escalation key is a STRATEGY, not a role: it must never appear as a row
# in `roles` (specs/model-roles-parity.sh's check_parity walks the role map and
# would look for an agent file to match it).
assert_not_contains "1.4 implementer_class_high is NOT reported as a role" \
    "implementer_class_high" "$(CLAUDE_PROJECT_DIR="$SB" bash "$MS" roles 2>/dev/null | awk -F'\t' '{print $1}')"

SB=$(new_sandbox)
# No model-roles file at all -> every role defaults to top (v3.5 parity).
assert_eq "1.5 missing-file: orchestrator->top" "top" "$(roles_strategy "$SB" orchestrator)"
assert_eq "1.5 missing-file: implementer->top" "top" "$(roles_strategy "$SB" implementer)"
assert_eq "1.5 missing-file: reviewer->top" "top" "$(roles_strategy "$SB" reviewer)"
# Missing-file is the quiet default: no unknown-strategy warning.
WARN_15=$(CLAUDE_PROJECT_DIR="$SB" bash "$MS" roles 2>&1 >/dev/null)
assert_not_contains "1.5 missing-file is quiet (no unknown-strategy warn)" "unknown strategy" "$WARN_15"

# ---------------------------------------------------------------------------
echo "=== Section 2: reviewer_lane resolution ==="

SB=$(new_sandbox)
printf 'orchestrator=top\nimplementer=opus-class\nreviewer=top\n' > "$SB/.claude/model-roles"
assert_eq "2.1 default (no reviewer_lane key) -> claude" "claude" "$(status_lane "$SB")"

SB=$(new_sandbox)
printf 'reviewer=top\nreviewer_lane=claude\n' > "$SB/.claude/model-roles"
assert_eq "2.2 reviewer_lane=claude forces claude" "claude" "$(status_lane "$SB")"

SB=$(new_sandbox)
printf 'reviewer=top\nreviewer_lane=auto\n' > "$SB/.claude/model-roles"
assert_eq "2.3 reviewer_lane=auto, no probe -> claude" "claude" "$(status_lane "$SB")"

SB=$(new_sandbox)
printf 'reviewer=top\nreviewer_lane=auto\n' > "$SB/.claude/model-roles"
LANE_ENV=$(WORKFLOW_REVIEWER_LANE=codex CLAUDE_PROJECT_DIR="$SB" bash "$MS" status 2>/dev/null \
    | grep '^reviewer lane:' | sed -E 's/^reviewer lane:[[:space:]]*//')
assert_eq "2.4 WORKFLOW_REVIEWER_LANE env seam overrides to codex" "codex" "$LANE_ENV"

SB=$(new_sandbox)
printf 'reviewer=top\nreviewer_lane=auto\n' > "$SB/.claude/model-roles"
# A V2-style probe: an executable codex-detect.sh that reports the lane.
cat > "$SB/.claude/scripts/codex-detect.sh" <<'PROBE'
#!/bin/bash
printf 'codex'
PROBE
chmod +x "$SB/.claude/scripts/codex-detect.sh"
assert_eq "2.5 reviewer_lane=auto defers to executable codex-detect.sh probe" \
    "codex" "$(status_lane "$SB")"

SB=$(new_sandbox)
printf 'reviewer=top\nreviewer_lane=banana\n' > "$SB/.claude/model-roles"
assert_eq "2.6 unknown reviewer_lane value falls back to auto->claude" "claude" "$(status_lane "$SB")"
WARN_26=$(CLAUDE_PROJECT_DIR="$SB" bash "$MS" status 2>&1 >/dev/null)
assert_contains "2.6 unknown reviewer_lane warns" "unknown reviewer_lane 'banana'" "$WARN_26"

# ---------------------------------------------------------------------------
echo "=== Section 3: --print-role-map coverage + role_agents() parity ==="

MAP=$(bash "$APPLY" --print-role-map)
# Every line is role<TAB>agent.
MAP_AGENTS=$(printf '%s\n' "$MAP" | awk -F'\t' '{print $2}' | sort)

# The expected agent set is DISCOVERED from .claude/agents/*.md, not listed.
# Through v4.1 this was seven names spelled out twice (the set and the count),
# so shipping an agent meant editing a test that had no other reason to change
# — and forgetting to edit it produced a RED, not a gap, which is why it
# survived. The map and the directory are now compared to each other, which is
# the property actually worth asserting: `--print-role-map` is the rewrite
# target set, so an agent on disk and absent from the map is an agent whose
# `model:` pin nothing maintains.
DISCOVERED_AGENTS=$(for f in "$PROJECT_DIR"/.claude/agents/*.md; do basename "$f" .md; done | sort)
assert_eq "3.1 print-role-map covers exactly the agents on disk, each once" \
    "$DISCOVERED_AGENTS" "$MAP_AGENTS"
assert_eq "3.1 print-role-map emits one line per discovered agent" \
    "$(printf '%s\n' "$DISCOVERED_AGENTS" | grep -c .)" "$(printf '%s\n' "$MAP" | grep -c '	')"
# Non-vacuity: a discovery pair where BOTH sides came back empty would compare
# equal and prove nothing.
assert_eq "3.1 non-vacuity: the discovered agent set is non-empty" \
    "yes" "$([ -n "$DISCOVERED_AGENTS" ] && echo yes || echo no)"

# CONCRETE_ROLES in workflow-model-apply.sh must agree with ALL_ROLES in
# model-select.sh. They are separate constants in separate scripts — one names
# the classes that own agents, the other the classes that get resolved — and a
# role present in one and absent from the other is exactly the silent-skip
# failure current_pin's catch-all used to hide (section 6).
APPLY_ROLES=$(sed -n 's/^CONCRETE_ROLES="\(.*\)"$/\1/p' "$APPLY" | head -1 | tr ' ' '\n' | sort | tr '\n' ',')
assert_eq "3.1b CONCRETE_ROLES (apply) == ALL_ROLES (select)" "$EXPECTED_ROLES" "$APPLY_ROLES"

# 3.1c cmd_check_parity's _expected_members() (claude-workflow-plugin-a13r
# ROUND 4, ITEM (a)) is a DELIBERATE duplicate of role_agents()'s member
# list — a completeness guard has no map to trust, because the map is the
# very thing being validated (see that function's own header).
#
# THIS IS A BEHAVIOURAL COMPARISON, not a text comparison, as of ROUND 6 —
# a WAIVER RULING, the operator's call, not mine, attributed here per their
# instruction: "when a defect family survives repeated rounds against the
# same mechanism, remove the mechanism rather than guard it again." Text
# comparison was guarded five times across rounds 4-6, each fix closing the
# previous gap and opening the next one exactly one layer up: a whole-file
# grep counted a set the mutation never touched; the scoped grep replacing
# it could match an empty range; the selector could drop an arm from BOTH
# sides at once (a shared reindent); the completeness loop's own role-key
# source could itself parse empty; and finally the completeness predicate's
# `.*printf` was a SUBSTRING test a COMMENT could satisfy — round 6 built a
# valid, `bash -n`-clean, multi-line case arm whose label line
# ("designer)        # printf payload follows") is byte-identical on both
# sides and contains the word "printf" only in a comment, while the real
# payload lived on a second line no selector ever captured. Every text
# guard passed. The two functions, EXECUTED, returned "designer" and
# "WRONG". Every one of those five guards existed only to make TEXT
# approximate a BEHAVIOURAL question — do these two functions produce the
# SAME OUTPUT for every role — so the question is now answered directly:
# for each role, RUN both and diff what they print. No selector to go
# empty, no indentation to drift, no substring to spoof, no split arm to
# hide a payload in, no comment to fool a grep.
#
# role_agents()'s side uses the SHIPPED, REAL entry point already proven
# out in section 3.1 above ($MAP there is one fixed sample of it, against
# the real $APPLY only) — satisfying .claude/tests/README.md's pairing-
# requirement leg 4 (observe the shipped artifact RUNNING). compare_role_
# outputs() below does NOT reuse that cached $MAP: it re-invokes
# `--print-role-map` FRESH on every call (round 7, R7-F2 — corrected here
# after review found the earlier wording claimed reuse that does not
# happen), because it must work generically against WHATEVER apply-script
# it is handed, including the mutant copies 3.1c-META-1 builds below — a
# cached sample of the real file would be silently wrong for those calls.
# _expected_members() has no shipped CLI surface of its own (it exists
# purely to back cmd_check_parity's internal completeness check), so it is
# extracted and SOURCED IN ISOLATION — never the whole model-select.sh
# file, which runs its own unconditional bottom-of-script dispatch (a trap
# this task already hit once) — guarded by a non-empty precondition on the
# extraction, a `bash -n` parse check, and a SENTINEL call (an unknown role
# must return non-zero) proving the sourced function is genuinely live
# before its output is trusted for anything.
#
# compare_role_outputs <apply-script> <ms-script> -- prints one line per
# MISMATCHING role (empty = every role agrees). SET semantics, deliberately
# order-independent: each side's per-role output is piped through `sort`
# before comparison, so role_agents() and _expected_members() printing
# implementer's three members in a different sequence is not a mismatch --
# membership is the invariant this check owns, not print order, and
# nothing downstream (cmd_check_parity's own per-file loop) depends on
# ordering either. A function, not inline code, so 3.1c's own live check
# below and 3.1c-META-1 (further down, the
# ONLY mutation test that exercises this particular helper — 3.1c-META-2
# validates a different property, the ROLE LIST itself, through
# validate_role_keys() below) run the IDENTICAL logic — not a re-typed
# copy free to drift from what actually ships. Assumes its caller's
# ALL_ROLES source is already sound (validate_role_keys(), immediately
# below, is what establishes that for $MS).
compare_role_outputs() {
    local apply_script="$1" ms_script="$2"
    local map em_src em_dir em_file role_keys role agents_out expected_out mismatch=""
    map=$(bash "$apply_script" --print-role-map 2>/dev/null)
    em_src=$(sed -n '/^_expected_members() {/,/^}/p' "$ms_script")
    em_dir=$(mktemp -d "$TESTROOT/expmembers-cmp.XXXXXX")
    em_file="$em_dir/_expected_members.sh"
    printf '%s\n' "$em_src" > "$em_file"
    role_keys=$(sed -n 's/^ALL_ROLES="\(.*\)"$/\1/p' "$ms_script" | head -1)
    for role in $role_keys; do
        agents_out=$(printf '%s\n' "$map" | awk -F'\t' -v r="$role" '$1 == r { print $2 }' | sort)
        # $em_file is a mktemp'd extraction of the function under test (see
        # em_dir above), not a static path -- nothing on disk at authoring
        # time for shellcheck to follow, by construction.
        # shellcheck source=/dev/null
        expected_out=$( (source "$em_file"; _expected_members "$role" 2>/dev/null) | sort)
        # TWO EMPTY OUTPUTS ARE NOT AGREEMENT. Checked as its OWN condition,
        # BEFORE the equality test below, and deliberately worded
        # differently in the message: a concrete role legitimately having
        # zero members is not a real state (every role in ALL_ROLES owns at
        # least one agent), so an empty/empty pair is a finding in its own
        # right, never silently absorbed into "matches". This is the sixth
        # level of the family this whole section exists to close: replacing
        # a text comparison with a behavioural one is worthless if the
        # behavioural comparison can itself pass on no output vs no output.
        if [ -z "$agents_out" ] && [ -z "$expected_out" ]; then
            mismatch="${mismatch:+$mismatch; }$role: BOTH SIDES EMPTY -- not treated as agreement (a concrete role must resolve to at least one member on each side for this comparison to mean anything)"
        elif [ -z "$agents_out" ]; then
            mismatch="${mismatch:+$mismatch; }$role: role_agents() produced NO output (expected_members=[$(printf '%s' "$expected_out" | tr '\n' ',')])"
        elif [ -z "$expected_out" ]; then
            mismatch="${mismatch:+$mismatch; }$role: _expected_members() produced NO output (role_agents=[$(printf '%s' "$agents_out" | tr '\n' ',')])"
        elif [ "$agents_out" != "$expected_out" ]; then
            mismatch="${mismatch:+$mismatch; }$role: role_agents=[$(printf '%s' "$agents_out" | tr '\n' ',')] expected_members=[$(printf '%s' "$expected_out" | tr '\n' ',')]"
        fi
    done
    printf '%s' "$mismatch"
}

EXPECTED_MEMBERS_SRC=$(sed -n '/^_expected_members() {/,/^}/p' "$MS")
assert_eq "3.1c precondition: _expected_members() was found and extracted (non-empty)" \
    "yes" "$([ -n "$EXPECTED_MEMBERS_SRC" ] && echo yes || echo no)"
EXPECTED_MEMBERS_ISOLATED_DIR=$(mktemp -d "$TESTROOT/expmembers.XXXXXX")
EXPECTED_MEMBERS_ISOLATED="$EXPECTED_MEMBERS_ISOLATED_DIR/_expected_members.sh"
printf '%s\n' "$EXPECTED_MEMBERS_SRC" > "$EXPECTED_MEMBERS_ISOLATED"
assert_eq "3.1c precondition: the isolated extraction still parses" \
    "0" "$(bash -n "$EXPECTED_MEMBERS_ISOLATED" >/dev/null 2>&1 && echo 0 || echo 1)"
# SENTINEL: an unknown role must return NON-ZERO. A silently-empty or
# broken extraction (a `source` that failed, a function that never got
# defined) would make ANY call return emptily just as readily as a genuine
# "not implemented" case -- the sentinel's job is to prove the function is
# actually live and running its own case statement, not merely that it
# exists as text on disk.
EM_SENTINEL_RC=0
# $EXPECTED_MEMBERS_ISOLATED is a mktemp'd extraction of the function under
# test, not a static path.
# shellcheck source=/dev/null
( source "$EXPECTED_MEMBERS_ISOLATED"; _expected_members __r6_sentinel_unknown_role__ ) >/dev/null 2>&1 || EM_SENTINEL_RC=$?
assert_eq "3.1c precondition: the sourced _expected_members() is genuinely live (an unknown role returns non-zero)" \
    "1" "$EM_SENTINEL_RC"

# validate_role_keys <ms-script> <apply-script> -- prints a diagnostic
# naming what is wrong with <ms-script>'s ALL_ROLES (empty = sound:
# present, no duplicates, and set-IDENTICAL to <apply-script>'s
# CONCRETE_ROLES, parsed fresh and independently -- a different constant in
# a different file, not via 3.1b's own EXPECTED_ROLES/APPLY_ROLES
# variables, so this does not silently depend on that section existing or
# staying unedited: the exact coupling R6-F2 named). A function, not
# inline code -- round 7, R7-F1: the prior shape computed this arithmetic
# inline once for the live check, and 3.1c-META-2 RE-TYPED an entire
# second copy of it for its own mutant, so weakening or deleting the live
# assertion below would not have reddened META-2's separately-typed
# arithmetic at all. Now the live check, META-2's mutant leg and META-2's
# restore control all call this SAME function, so there is one place this
# logic can be wrong, not two silently drifting from each other.
#
# COMPLETENESS SURVIVES THE ROUND-6 CHANGE (round 6, R6-F2 -- fixed
# properly, not merely re-guarded): comparing outputs role-by-role is still
# vacuous if the ROLE LIST itself is empty, short, or carries a duplicate
# standing in for a missing role. R6-F2's own proof: "designer designer
# design_reviewer orchestrator implementer" is five WORDS, four ROLES, and
# reviewer is never iterated -- a bare word-count pin reads this as
# healthy.
validate_role_keys() {
    local ms_script="$1" apply_script="$2"
    local role_keys role_keys_sorted_unique role_keys_raw role_keys_unique
    local concrete_keys concrete_sorted_unique problems=""
    role_keys=$(sed -n 's/^ALL_ROLES="\(.*\)"$/\1/p' "$ms_script" | head -1)
    if [ -z "$role_keys" ]; then
        printf '%s' "ALL_ROLES parsed empty from $ms_script"
        return
    fi
    # BASH-SPECIFIC, noted rather than silently relied on: unquoted
    # word-splitting of a space-separated value, correct in bash (this
    # suite's shebang and every invocation in this repo) but NOT the same
    # under zsh, where unquoted parameter expansion does not word-split by
    # default. Not a portability bug here -- this file only ever runs
    # under bash.
    # shellcheck disable=SC2086  # word-splitting IS the point; quoting
    # would count 1 line, not N words.
    role_keys_sorted_unique=$(printf '%s\n' $role_keys | sort -u)
    # shellcheck disable=SC2086  # same rationale as the line above.
    role_keys_raw=$(printf '%s\n' $role_keys | grep -c .)
    role_keys_unique=$(printf '%s\n' "$role_keys_sorted_unique" | grep -c .)
    if [ "$role_keys_raw" != "$role_keys_unique" ]; then
        problems="${problems:+$problems; }ALL_ROLES has duplicate(s): raw count $role_keys_raw, unique count $role_keys_unique"
    fi
    concrete_keys=$(sed -n 's/^CONCRETE_ROLES="\(.*\)"$/\1/p' "$apply_script" | head -1)
    if [ -z "$concrete_keys" ]; then
        printf '%s' "${problems:+$problems; }CONCRETE_ROLES parsed empty from $apply_script"
        return
    fi
    # shellcheck disable=SC2086  # same word-splitting rationale as above.
    concrete_sorted_unique=$(printf '%s\n' $concrete_keys | sort -u)
    if [ "$role_keys_sorted_unique" != "$concrete_sorted_unique" ]; then
        problems="${problems:+$problems; }ALL_ROLES set != CONCRETE_ROLES set: ALL_ROLES=[$(printf '%s' "$role_keys_sorted_unique" | tr '\n' ',')] CONCRETE_ROLES=[$(printf '%s' "$concrete_sorted_unique" | tr '\n' ',')]"
    fi
    printf '%s' "$problems"
}

assert_eq "3.1c role-set precondition: ALL_ROLES (model-select.sh) is sound — present, unique, and set-identical to CONCRETE_ROLES (workflow-model-apply.sh)" \
    "" "$(validate_role_keys "$MS" "$APPLY")"

# THE COMPARISON ITSELF: role_agents()'s REAL, executed output (via a
# fresh `--print-role-map` invocation inside compare_role_outputs(), NOT
# the cached $MAP from section 3.1 -- see that function's own header) must
# equal _expected_members()'s REAL, executed output (the sourced,
# sentinel-proven function, actually called) for every verified role key.
assert_eq "3.1c _expected_members() produces the SAME OUTPUT as role_agents() for every role (behavioural, not textual)" \
    "" "$(compare_role_outputs "$APPLY" "$MS")"

echo ""
echo "--- 3.1c-META-1: the comment-bearing split arm from R6-F1, SHIPPED as a named control (round 6, R6-F3) ---"
#
# Round 6's own proof-of-concept, reproduced here as a committed mutant so
# it runs every time this file does -- not a one-off scratch measurement
# (R6-F3: "the pairing requirement is not met... the control must SHIP").
# This is exactly the shape that defeated every text-comparison guard
# added across rounds 4-6; it is what the behavioural replacement above
# exists to close, and shipping only a simpler mutant would "pin the
# instance we already knew and leave the class open again" (the operator's
# own words).
MUT_R6F1_APPLY_DIR=$(mktemp -d "$TESTROOT/r6f1apply.XXXXXX")
MUT_R6F1_APPLY="$MUT_R6F1_APPLY_DIR/workflow-model-apply.sh"
# NOTE the doubled backslashes below (`\\\\n`, not `\\n`): `awk -v` applies
# its OWN escape processing on top of bash's, so a value meant to contain
# the two LITERAL characters backslash+n (matching the file's actual
# `printf 'designer\n' ;;` source text) needs FOUR backslashes in this
# double-quoted bash string -- bash collapses them to two (`\\`), and
# awk's -v then collapses THAT pair to one literal backslash, leaving the
# trailing `n` untouched. Measured directly: with only `\\n`, awk -v turns
# it into an actual newline BYTE, the exact-line match against `old` never
# fires, `cmp` reports the mutant identical to the shipped file, and the
# non-vacuity legs below catch it -- exactly the discipline this section's
# own non-vacuity checks exist to enforce, applied to the harness that
# builds the fixture and not just the fixture itself.
awk -v old="        designer)        printf 'designer\\\\n' ;;" \
    -v new1="        designer)        # printf payload follows" \
    -v new2="            printf 'designer\\\\n' ;;" \
    '$0 == old { print new1; print new2; next } { print }' "$APPLY" > "$MUT_R6F1_APPLY"

MUT_R6F1_MS_DIR=$(mktemp -d "$TESTROOT/r6f1ms.XXXXXX")
MUT_R6F1_MS="$MUT_R6F1_MS_DIR/model-select.sh"
awk -v old="        designer)        printf 'designer\\\\n' ;;" \
    -v new1="        designer)        # printf payload follows" \
    -v new2="            printf 'WRONG\\\\n' ;;" \
    '$0 == old { print new1; print new2; next } { print }' "$MS" > "$MUT_R6F1_MS"

assert_eq "3.1c-META-1 non-vacuity: the split-arm mutation landed in workflow-model-apply.sh (differs from shipped)" \
    "differs" "$(cmp -s "$MUT_R6F1_APPLY" "$APPLY" && echo same || echo differs)"
assert_eq "3.1c-META-1 non-vacuity: the split-arm mutation landed in model-select.sh (differs from shipped)" \
    "differs" "$(cmp -s "$MUT_R6F1_MS" "$MS" && echo same || echo differs)"
assert_eq "3.1c-META-1 non-vacuity: both mutants still parse" \
    "0 0" "$(bash -n "$MUT_R6F1_APPLY" >/dev/null 2>&1 && echo 0 || echo 1) $(bash -n "$MUT_R6F1_MS" >/dev/null 2>&1 && echo 0 || echo 1)"
# Non-vacuity of the DIVERGENCE itself, via ISOLATED extraction on BOTH
# sides (never source either file whole: workflow-model-apply.sh, like
# model-select.sh, runs its own unconditional bottom-of-script dispatch --
# `case "${1:-}" in "") usage; exit 1 ;; ...` -- when sourced with no
# args, which would exit the subshell before role_agents ever ran; measured
# directly, not assumed). The two mutants must genuinely disagree at
# runtime before the "catches it" leg below can mean anything.
MUT_R6F1_RA_DIR=$(mktemp -d "$TESTROOT/r6f1ra.XXXXXX")
MUT_R6F1_RA="$MUT_R6F1_RA_DIR/role_agents.sh"
sed -n '/^role_agents() {/,/^}/p' "$MUT_R6F1_APPLY" > "$MUT_R6F1_RA"
MUT_R6F1_EM_DIR=$(mktemp -d "$TESTROOT/r6f1em.XXXXXX")
MUT_R6F1_EM="$MUT_R6F1_EM_DIR/_expected_members.sh"
sed -n '/^_expected_members() {/,/^}/p' "$MUT_R6F1_MS" > "$MUT_R6F1_EM"
# $MUT_R6F1_RA / $MUT_R6F1_EM are mktemp'd extractions of the functions
# under test, not static paths.
# shellcheck source=/dev/null
assert_eq "3.1c-META-1 non-vacuity: the mutants genuinely diverge at runtime (designer vs WRONG)" \
    "differs" "$( [ "$( (source "$MUT_R6F1_RA"; role_agents designer) 2>/dev/null)" \
                  != "$( (source "$MUT_R6F1_EM"; _expected_members designer) 2>/dev/null)" ] \
                  && echo differs || echo same )"
assert_eq "3.1c-META-1 SPECIFIC MISBEHAVIOUR (of the OLD text-based design): the old whole-arm selector still selects an IDENTICAL label line on both sides" \
    "identical" "$( [ "$(sed -n '/^role_agents() {/,/^}/p' "$MUT_R6F1_APPLY" | grep -E '^        [a-z_]+\)' | grep -v '^        all)')" \
                     = "$(sed -n '/^_expected_members() {/,/^}/p' "$MUT_R6F1_MS" | grep -E '^        [a-z_]+\)' | grep -v '^        all)')" ] \
                     && echo identical || echo different )"
assert_eq "3.1c-META-1 SPECIFIC MISBEHAVIOUR: the NEW behavioural comparison catches the divergence the OLD text comparison could not" \
    "designer: role_agents=[designer] expected_members=[WRONG]" \
    "$(compare_role_outputs "$MUT_R6F1_APPLY" "$MUT_R6F1_MS")"

# RESTORE CONTROL: the SHIPPED, unmutated pair -- still agrees on every role.
assert_eq "3.1c-META-1 RESTORE CONTROL: the SHIPPED pair, same comparison, agrees on every role" \
    "" "$(compare_role_outputs "$APPLY" "$MS")"

echo ""
echo "--- 3.1c-META-2: the duplicated-role-key shape from R6-F2, SHIPPED as a named control ---"
#
# R6-F2's own proof: a role LIST with a duplicate standing in for a missing
# role reads as healthy under a bare word-count pin. "designer designer
# design_reviewer orchestrator implementer" is five words; four roles;
# reviewer is never iterated.
#
# ROUND 7, R7-F1 (independent review): the ORIGINAL shape of this control
# re-typed the raw-count/sort-u/unique-count/set-comparison arithmetic into
# its own MUT_R6F2_* variables instead of calling validate_role_keys(), and
# its restore legs compared previously-computed OUTER variables rather than
# invoking anything fresh -- so weakening or deleting the LIVE role-set
# assertion above would not have reddened this control at all; its
# separately-typed copy would have stayed green. Fixed: every leg below
# calls validate_role_keys(), the SAME function the live check calls, and a
# NEW behavioural leg actually runs model-select.sh's shipped `roles`
# surface against both the mutant and the restored file, so the control
# also observes the shipped artifact RUNNING, not just re-parsing text.
MUT_R6F2_MS_DIR=$(mktemp -d "$TESTROOT/r6f2ms.XXXXXX")
MUT_R6F2_MS="$MUT_R6F2_MS_DIR/model-select.sh"
sed 's/^ALL_ROLES="designer design_reviewer orchestrator implementer reviewer"$/ALL_ROLES="designer designer design_reviewer orchestrator implementer"/' "$MS" > "$MUT_R6F2_MS"
assert_eq "3.1c-META-2 non-vacuity: the duplicate-role mutation landed (differs from shipped)" \
    "differs" "$(cmp -s "$MUT_R6F2_MS" "$MS" && echo same || echo differs)"
assert_eq "3.1c-META-2 non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT_R6F2_MS" >/dev/null 2>&1 && echo 0 || echo 1)"
assert_eq "3.1c-META-2 SPECIFIC MISBEHAVIOUR (of a bare word-count pin, the OLD design): raw word count alone reads healthy" \
    "5" "$(sed -n 's/^ALL_ROLES="\(.*\)"$/\1/p' "$MUT_R6F2_MS" | head -1 | tr ' ' '\n' | grep -c .)"
MUT_R6F2_VALIDATION=$(validate_role_keys "$MUT_R6F2_MS" "$APPLY")
assert_eq "3.1c-META-2 SPECIFIC MISBEHAVIOUR: validate_role_keys() -- the SAME helper the live check calls -- catches it (non-empty diagnostic)" \
    "yes" "$([ -n "$MUT_R6F2_VALIDATION" ] && echo yes || echo no)"
assert_contains "3.1c-META-2 ...names the duplicate specifically" \
    "ALL_ROLES has duplicate(s): raw count 5, unique count 4" "$MUT_R6F2_VALIDATION"
assert_contains "3.1c-META-2 ...and names the set mismatch against CONCRETE_ROLES (the missing 'reviewer')" \
    "ALL_ROLES set != CONCRETE_ROLES set" "$MUT_R6F2_VALIDATION"

# BEHAVIOURAL LEG: the duplicate/missing-role shape has a REAL, observable
# runtime consequence via model-select.sh's own shipped `roles` subcommand
# -- not just a text parse. cmd_roles() iterates the file's OWN ALL_ROLES
# value exactly as written, so running it against the mutant genuinely
# prints 'designer' TWICE and 'reviewer' NEVER.
MUT_R6F2_ROLES_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUT_R6F2_MS" roles 2>/dev/null)
assert_eq "3.1c-META-2 behavioural: the SHIPPED 'roles' surface, run for real against the mutant, prints designer TWICE" \
    "2" "$(printf '%s\n' "$MUT_R6F2_ROLES_OUT" | awk -F'\t' '$1 == "designer"' | grep -c .)"
assert_eq "3.1c-META-2 behavioural: ...and 'reviewer' NEVER (the missing role, genuinely absent at runtime, not just absent from a text parse)" \
    "0" "$(printf '%s\n' "$MUT_R6F2_ROLES_OUT" | awk -F'\t' '$1 == "reviewer"' | grep -c .)"

# RESTORE CONTROL: the SHIPPED, unmutated files -- validate_role_keys()
# reports sound, freshly re-invoked rather than reusing the live check's
# own result, and the SAME shipped `roles` surface, run for real, shows
# every role exactly once.
assert_eq "3.1c-META-2 RESTORE CONTROL: validate_role_keys() reports the SHIPPED files sound (fresh call)" \
    "" "$(validate_role_keys "$MS" "$APPLY")"
SHIPPED_ROLES_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MS" roles 2>/dev/null)
assert_eq "3.1c-META-2 RESTORE CONTROL: ...and the SHIPPED 'roles' surface prints designer exactly once" \
    "1" "$(printf '%s\n' "$SHIPPED_ROLES_OUT" | awk -F'\t' '$1 == "designer"' | grep -c .)"
assert_eq "3.1c-META-2 RESTORE CONTROL: ...and reviewer exactly once" \
    "1" "$(printf '%s\n' "$SHIPPED_ROLES_OUT" | awk -F'\t' '$1 == "reviewer"' | grep -c .)"

# Each agent maps to the expected role class (matches role_agents()).
role_of() { printf '%s\n' "$MAP" | awk -F'\t' -v a="$1" '$2 == a { print $1 }'; }
assert_eq "3.2 orchestrator -> orchestrator" "orchestrator" "$(role_of orchestrator)"
assert_eq "3.2 backend -> implementer" "implementer" "$(role_of backend)"
assert_eq "3.2 frontend -> implementer" "implementer" "$(role_of frontend)"
assert_eq "3.2 devops -> implementer" "implementer" "$(role_of devops)"
assert_eq "3.2 qa -> reviewer" "reviewer" "$(role_of qa)"
assert_eq "3.2 grader -> reviewer" "reviewer" "$(role_of grader)"
assert_eq "3.2 judge -> reviewer" "reviewer" "$(role_of judge)"
# D0: the two design lanes, and the deliberate role/filename spelling split
# (`design_reviewer` the role, `design-reviewer.md` the file).
assert_eq "3.2 designer -> designer" "designer" "$(role_of designer)"
assert_eq "3.2 design-reviewer -> design_reviewer" "design_reviewer" "$(role_of design-reviewer)"

# ---------------------------------------------------------------------------
echo "=== Section 4: statusline role rendering + short_id ==="

# Helper: render the statusline for a sandbox and echo the model segment.
render_statusline() {
    echo '{}' | CLAUDE_PROJECT_DIR="$1" bash "$SL" 2>/dev/null
}

# 4.1 Artifact absent -> fallback to the full orchestrator.md pin (v3.5
# byte-for-byte behavior; NO short_id applied on the fallback path).
SB=$(new_sandbox)
printf -- '---\nname: orchestrator\nmodel: claude-opus-4-8\n---\n' > "$SB/.claude/agents/orchestrator.md"
OUT_41=$(render_statusline "$SB")
assert_contains "4.1 fallback shows full orchestrator pin" "• model: claude-opus-4-8" "$OUT_41"

# 4.2 Collapse: all three roles equal AND lane=claude -> short single model.
SB=$(new_sandbox)
printf '{"roles":{"orchestrator":"claude-opus-4-8","implementer":"claude-opus-4-8","reviewer":"claude-opus-4-8"},"reviewer_lane":"claude"}' \
    > "$SB/.claude/.qa-tracking/model-roles-resolved.json"
OUT_42=$(render_statusline "$SB")
assert_contains "4.2 collapse renders short single-model view" "• model: opus-4-8" "$OUT_42"
assert_not_contains "4.2 collapse does not render the triple" "orch:" "$OUT_42"

# 4.3 A leftover THREE-ROLE v4 artifact still renders (D0 rule 4: render over
# the roles PRESENT in .roles). The output CHANGED at D0 — it was
# `orch:.. impl:.. rev:..` and is now grouped, because orchestrator and
# reviewer share a value. The grouping is the point: it is what keeps five
# roles on one line, and it applies to three roles identically.
SB=$(new_sandbox)
printf '{"roles":{"orchestrator":"claude-fable-9","implementer":"claude-opus-5-0","reviewer":"claude-fable-9"},"reviewer_lane":"claude"}' \
    > "$SB/.claude/.qa-tracking/model-roles-resolved.json"
OUT_43=$(render_statusline "$SB")
assert_contains "4.3 v4 three-role artifact renders grouped, no upgrade step" \
    "• orch+rev:fable-9 impl:opus-5-0" "$OUT_43"
assert_not_contains "4.3 absent design roles are absent, not empty labels" "des" "$OUT_43"

# 4.4 lane=codex -> reviewer segment collapses to the literal `sol`, and an
# otherwise-collapsible (all-equal) mapping stays grouped. TIGHTENED at D0 from
# two substring probes to the exact string: `rev:sol` matched the old triple
# and the new grouping alike, so on its own it could not tell a correct render
# from a regressed one.
SB=$(new_sandbox)
printf '{"roles":{"orchestrator":"claude-opus-4-8","implementer":"claude-opus-4-8","reviewer":"claude-opus-4-8"},"reviewer_lane":"codex"}' \
    > "$SB/.claude/.qa-tracking/model-roles-resolved.json"
OUT_44=$(render_statusline "$SB")
assert_contains "4.4 lane=codex renders the exact grouped string with rev:sol" \
    "• orch+impl:opus-4-8 rev:sol" "$OUT_44"
assert_not_contains "4.4 lane=codex is NOT collapsed to single model" "• model:" "$OUT_44"

# 4.5 short_id strips a -2NNNNNNN date suffix and keeps the [1m] marker.
SB=$(new_sandbox)
printf '{"roles":{"orchestrator":"claude-opus-4-20260514[1m]","implementer":"claude-opus-4-20260514[1m]","reviewer":"claude-opus-4-20260514[1m]"},"reviewer_lane":"claude"}' \
    > "$SB/.claude/.qa-tracking/model-roles-resolved.json"
OUT_45=$(render_statusline "$SB")
assert_contains "4.5 short_id strips date suffix, preserves [1m]" "• model: opus-4[1m]" "$OUT_45"

# 4.6 Malformed artifact -> fallback (never errors).
SB=$(new_sandbox)
printf -- '---\nname: orchestrator\nmodel: claude-base-0\n---\n' > "$SB/.claude/agents/orchestrator.md"
printf 'not-json{' > "$SB/.claude/.qa-tracking/model-roles-resolved.json"
OUT_46=$(render_statusline "$SB")
assert_contains "4.6 malformed artifact falls back to full pin" "• model: claude-base-0" "$OUT_46"

# --- 4.7 - 4.12: the five-role render (v5.0.0 / D0) -----------------------
#
# The seven rows below are the render table from the D0 plan, asserted as EXACT
# strings rather than substrings. Each row is one rule; together they pin the
# fixed order (des dsr orch impl rev), the grouping, the `sol` substitution per
# lane, the MAX_GROUPS truncation and the flag suffixes.

# five_role_artifact <sandbox> <des> <dsr> <orch> <impl> <rev> <rlane> <dlane> [extra-json]
five_role_artifact() {
    local sb="$1" des="$2" dsr="$3" orch="$4" impl="$5" rev="$6" rl="$7" dl="$8" extra="${9:-}"
    printf '{"roles":{"designer":"%s","design_reviewer":"%s","orchestrator":"%s","implementer":"%s","reviewer":"%s"},"reviewer_lane":"%s","design_reviewer_lane":"%s"%s}' \
        "$des" "$dsr" "$orch" "$impl" "$rev" "$rl" "$dl" "${extra:+,$extra}" \
        > "$sb/.claude/.qa-tracking/model-roles-resolved.json"
}

# model_segment <sandbox> [stdin-json] — the model suffix alone, so the
# assertions are exact rather than substring probes over the whole line.
model_segment() {
    printf '%s' "${2:-\{\}}" | CLAUDE_PROJECT_DIR="$1" bash "$SL" 2>/dev/null \
        | sed 's/^.*files changed//'
}

# 4.7 Both lanes claude: group by identical value, fixed order.
SB=$(new_sandbox)
five_role_artifact "$SB" claude-fable-5 claude-fable-5 claude-fable-5 claude-sonnet-5 claude-fable-5 claude claude
assert_eq "4.7 both lanes claude -> grouped, design lanes first" \
    " • des+dsr+orch+rev:fable-5 impl:sonnet-5" "$(model_segment "$SB")"

# 4.8 Both lanes codex: BOTH review lanes substitute the literal `sol`, and
# they group together because their display value is now identical.
SB=$(new_sandbox)
five_role_artifact "$SB" claude-fable-5 claude-fable-5 claude-fable-5 claude-sonnet-5 claude-fable-5 codex codex
assert_eq "4.8 both lanes codex -> dsr+rev group as sol" \
    " • des+orch:fable-5 dsr+rev:sol impl:sonnet-5" "$(model_segment "$SB")"

# 4.9 The lanes are INDEPENDENT: a codex design lane with a claude review lane
# substitutes `sol` for dsr only. This is the row that would pass if the two
# lanes were wired to one variable, so it is the one that proves they are not.
SB=$(new_sandbox)
five_role_artifact "$SB" claude-fable-5 claude-fable-5 claude-fable-5 claude-sonnet-5 claude-fable-5 claude codex
assert_eq "4.9 design lane codex + review lane claude -> only dsr is sol" \
    " • des+orch+rev:fable-5 dsr:sol impl:sonnet-5" "$(model_segment "$SB")"

# 4.10 All five equal AND both lanes claude -> single-model collapse.
SB=$(new_sandbox)
five_role_artifact "$SB" claude-fable-5 claude-fable-5 claude-fable-5 claude-fable-5 claude-fable-5 claude claude
assert_eq "4.10 all equal + both lanes claude -> single-model collapse" \
    " • model: fable-5" "$(model_segment "$SB")"

# 4.11 Flags. `!esc` rides the escalation state file; `!id` rides
# identity_collapse in the artifact; `!sess` rides a live/expected mismatch in
# the stdin envelope. Order is fixed: !esc !id !sess.
SB=$(new_sandbox)
five_role_artifact "$SB" claude-fable-5 claude-fable-5 claude-fable-5 claude-opus-5 claude-fable-5 claude claude
printf '{"task_id":"t","previous_pin":"claude-sonnet-5","resolved":"claude-opus-5"}' \
    > "$SB/.claude/.qa-tracking/implementer-escalation.json"
assert_eq "4.11 active escalation renders !esc" \
    " • des+dsr+orch+rev:fable-5 impl:opus-5 !esc" "$(model_segment "$SB")"
rm -f "$SB/.claude/.qa-tracking/implementer-escalation.json"

SB=$(new_sandbox)
five_role_artifact "$SB" claude-fable-5 claude-fable-5 claude-fable-5 claude-sonnet-5 claude-fable-5 claude claude '"identity_collapse":true'
assert_eq "4.11b identity collapse + session drift render !id !sess" \
    " • des+dsr+orch+rev:fable-5 impl:sonnet-5 !id !sess" \
    "$(model_segment "$SB" '{"model":{"id":"claude-opus-4-5"}}')"

# 4.12 MAX_GROUPS truncation: five distinct display values -> three groups then
# ` +2 more`.
SB=$(new_sandbox)
five_role_artifact "$SB" claude-fable-5 claude-fable-5 claude-mythos-2 claude-sonnet-5 claude-haiku-1 claude codex
OUT_412=$(model_segment "$SB")
assert_eq "4.12 five distinct values truncate at MAX_GROUPS with a +N more tail" \
    " • des:fable-5 dsr:sol orch:mythos-2 +2 more" "$OUT_412"

# 4.12-META: the truncation is load-bearing, not incidental.
#
# NON-VACUITY: raise MAX_GROUPS in a COPY of the shipped statusline and prove
# the substitution landed (the copy differs, still parses, and no longer
# carries the shipped value).
# SPECIFIC MISBEHAVIOUR: the mutant renders all five groups, so 4.12's exact
# assertion fails — i.e. the ` +2 more` tail comes from MAX_GROUPS and not from
# some incidental truncation elsewhere.
# EXECUTION: the mutant and the control are both RUN, not read.
MUT_DIR=$(mktemp -d "$TESTROOT/slmut.XXXXXX")
MUT_SL="$MUT_DIR/statusline.sh"
awk '/^MAX_GROUPS=3$/ { print "MAX_GROUPS=99"; found=1; next } { print }
     END { if (!found) exit 7 }' "$SL" > "$MUT_SL"
AWK_RC_412=$?
assert_eq "4.12-META non-vacuity: the MAX_GROUPS substitution landed" "0" "$AWK_RC_412"
assert_eq "4.12-META non-vacuity: the mutant differs from the shipped script" \
    "differs" "$(cmp -s "$MUT_SL" "$SL" && echo same || echo differs)"
assert_eq "4.12-META non-vacuity: the mutant still parses (it fails for its own reason)" \
    "0" "$(bash -n "$MUT_SL" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_MUT=$(new_sandbox)
# rm THEN cp. new_sandbox SYMLINKS the canonical scripts in, so a bare `cp`
# over that path writes THROUGH the link and overwrites the shipped
# statusline.sh with the mutant — a test that corrupts the artifact it is
# testing, and one whose damage would outlive the run.
rm -f "$SB_MUT/.claude/scripts/statusline.sh"
cp "$MUT_SL" "$SB_MUT/.claude/scripts/statusline.sh"
chmod +x "$SB_MUT/.claude/scripts/statusline.sh"
assert_eq "4.12-META guard: the canonical statusline.sh still carries the shipped MAX_GROUPS" \
    "MAX_GROUPS=3" "$(grep -m1 '^MAX_GROUPS=' "$SL")"
five_role_artifact "$SB_MUT" claude-fable-5 claude-fable-5 claude-mythos-2 claude-sonnet-5 claude-haiku-1 claude codex
OUT_412_MUT=$(echo '{}' | CLAUDE_PROJECT_DIR="$SB_MUT" bash "$SB_MUT/.claude/scripts/statusline.sh" 2>/dev/null \
    | sed 's/^.*files changed//')
assert_not_contains "4.12-META: with MAX_GROUPS raised, the +N more tail is GONE (4.12 would fail)" \
    "+2 more" "$OUT_412_MUT"
assert_contains "4.12-META: the mutant instead renders the truncated tail groups inline" \
    "impl:sonnet-5" "$OUT_412_MUT"
assert_eq "4.12-META restore control: the SHIPPED script still truncates" \
    " • des:fable-5 dsr:sol orch:mythos-2 +2 more" "$(model_segment "$SB")"

# ---------------------------------------------------------------------------
echo "=== Section 5: packaging parity (install.sh / install.ps1) ==="

# install_sh_ships_model_roles <path> — the CHECK: does install.sh copy the
# model-roles config? Sensitive to the copy_file line, not comments.
install_sh_ships_model_roles() {
    # `$SOURCE_DIR` is a literal to match in install.sh's source text, not a
    # variable to expand — single quotes are deliberate.
    # shellcheck disable=SC2016
    grep -Eq 'copy_file[[:space:]]+"\$SOURCE_DIR/\.claude/model-roles"' "$1"
}

if install_sh_ships_model_roles "$INSTALL_SH"; then
    assert_eq "5.1 install.sh ships .claude/model-roles" "0" "0"
else
    assert_eq "5.1 install.sh ships .claude/model-roles" "0" "1"
fi

if grep -Eq 'Src = "\.claude/model-roles"' "$INSTALL_PS1"; then
    assert_eq "5.2 install.ps1 carries the model-roles asset entry" "0" "0"
else
    assert_eq "5.2 install.ps1 carries the model-roles asset entry" "0" "1"
fi

# 5.3 META: strip the model-roles copy line from a throwaway install.sh copy;
# the check MUST then report the file does NOT ship it. Proves 5.1 is
# sensitive to the copy line rather than vacuously green.
STRIP_DIR=$(mktemp -d "$TESTROOT/strip.XXXXXX")
grep -v '\.claude/model-roles' "$INSTALL_SH" > "$STRIP_DIR/install.sh"
if install_sh_ships_model_roles "$STRIP_DIR/install.sh"; then
    assert_eq "5.3 META: stripped install.sh fails the ships-model-roles check" "1" "0"
else
    assert_eq "5.3 META: stripped install.sh fails the ships-model-roles check" "1" "1"
fi

# ===========================================================================
echo ""
echo "=== Section 6: current_pin has an arm per role (the D0 silent-skip) ==="
#
# THE HAZARD. Through v4.1 current_pin()'s last arm was `orchestrator|*)` — a
# SILENT catch-all. A role with no arm read orchestrator.md's pin, so
# _apply_role compared the new lane's DESIRED model against the ORCHESTRATOR's
# CURRENT one; on the common case where both resolve to `top` they are equal,
# _apply_role returns "no switch needed", and the lane is never written. No
# error. No warning. Exit 0. The lane reports as pinned and is not.
#
# This section is the pair required before that guard can ship.

# ms_sandbox_with_listing <pin-for-everything> <orchestrator-pin> — a sandbox
# with a fresh cached listing (no network, no API key) and per-agent pins.
ms_sandbox_with_listing() {
    local base="$1" orch="$2" d
    d=$(new_sandbox)
    local a
    for a in designer design-reviewer; do
        printf -- '---\nname: %s\nmodel: %s\n---\nbody\n' "$a" "$base" > "$d/.claude/agents/$a.md"
    done
    for a in qa backend frontend devops grader judge; do
        printf -- '---\nname: %s\nmodel: %s\n---\nbody\n' "$a" "$base" > "$d/.claude/agents/$a.md"
    done
    printf -- '---\nname: orchestrator\nmodel: %s\n---\nbody\n' "$orch" > "$d/.claude/agents/orchestrator.md"
    printf 'designer=top\ndesign_reviewer=top\norchestrator=top\nimplementer=top\nreviewer=top\n' \
        > "$d/.claude/model-roles"
    printf 'claude-fable\nclaude-opus\n' > "$d/.claude/model-ranking"
    cat > "$d/.claude/.qa-tracking/model-select-cache.json" <<JSON
{"timestamp": $(date +%s), "models": [
  {"id":"claude-fable-9","max_input_tokens":1000000,"created_at":"2026-07-01T00:00:00Z"},
  {"id":"claude-opus-5-0","max_input_tokens":400000,"created_at":"2026-06-01T00:00:00Z"}]}
JSON
    printf '%s' "$d"
}

agent_pin_of() { grep -E '^model:' "$1" | head -1 | awk '{print $2}'; }

# 6.1 CONTROL — the SHIPPED resolver writes the designer lane even when the
# orchestrator is ALREADY at the target id. This is the exact configuration the
# stripped-arm mutant gets wrong.
SB_61=$(ms_sandbox_with_listing "claude-base-0" "claude-fable-9")
CLAUDE_PROJECT_DIR="$SB_61" bash "$MS" apply --quiet >/dev/null 2>&1
assert_eq "6.1 control: shipped resolver pins the designer lane" \
    "claude-fable-9" "$(agent_pin_of "$SB_61/.claude/agents/designer.md")"
assert_eq "6.1 control: shipped resolver pins the design-reviewer lane" \
    "claude-fable-9" "$(agent_pin_of "$SB_61/.claude/agents/design-reviewer.md")"
assert_eq "6.1 control: the orchestrator was already at the target (the trap condition)" \
    "claude-fable-9" "$(agent_pin_of "$SB_61/.claude/agents/orchestrator.md")"

# 6.2 Every role in ALL_ROLES reads ITS OWN file. Distinct pins per lane, read
# back through the shipped `status` table — so this drives the real script
# rather than re-implementing its case statement.
SB_62=$(ms_sandbox_with_listing "claude-base-0" "claude-orch-1")
printf -- '---\nname: designer\nmodel: claude-des-1\n---\n' > "$SB_62/.claude/agents/designer.md"
printf -- '---\nname: design-reviewer\nmodel: claude-dsr-1\n---\n' > "$SB_62/.claude/agents/design-reviewer.md"
printf -- '---\nname: backend\nmodel: claude-impl-1\n---\n' > "$SB_62/.claude/agents/backend.md"
printf -- '---\nname: qa\nmodel: claude-rev-1\n---\n' > "$SB_62/.claude/agents/qa.md"
rm -f "$SB_62/.claude/.qa-tracking/model-select-cache.json"
# status_pin <sandbox> <role> — the `pinned` column for one role from the
# status table.
#
# The `/^  /` anchor is load-bearing: `status` also prints an unindented
# `reviewer lane: <lane>` summary line whose first field is likewise
# `reviewer`, so an unanchored `$1 == r` match returns TWO values for that one
# role and every comparison against it fails for a reason that has nothing to
# do with current_pin. Table rows are indented two spaces; summary lines are
# not.
status_pin() {
    CLAUDE_PROJECT_DIR="$1" bash "$MS" status 2>/dev/null \
        | awk -v r="$2" '/^  / && $1 == r { print $3 }'
}
assert_eq "6.2 designer reads designer.md" "claude-des-1" "$(status_pin "$SB_62" designer)"
assert_eq "6.2 design_reviewer reads design-reviewer.md" "claude-dsr-1" "$(status_pin "$SB_62" design_reviewer)"
assert_eq "6.2 orchestrator reads orchestrator.md" "claude-orch-1" "$(status_pin "$SB_62" orchestrator)"
assert_eq "6.2 implementer reads backend.md" "claude-impl-1" "$(status_pin "$SB_62" implementer)"
assert_eq "6.2 reviewer reads qa.md" "claude-rev-1" "$(status_pin "$SB_62" reviewer)"

# 6.3 META — strip the `designer)` arm and prove the silent skip returns.
#
# NON-VACUITY: awk exits 7 if the arm is not found, so a strip that matched
# nothing fails loudly instead of producing a mutant identical to the original.
# The mutant is also byte-compared against the shipped script and parsed.
MUT6_DIR=$(mktemp -d "$TESTROOT/pinmut.XXXXXX")
MUT6="$MUT6_DIR/model-select.sh"
awk '/^        designer\)        printf .%s. "\$DESIGNER_AGENT" ;;$/ { found=1; next } { print }
     END { if (!found) exit 7 }' "$MS" > "$MUT6"
AWK_RC_63=$?
assert_eq "6.3-META non-vacuity: the designer) arm strip landed (awk exit)" "0" "$AWK_RC_63"
assert_eq "6.3-META non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT6" "$MS" && echo same || echo differs)"
assert_eq "6.3-META non-vacuity: the mutant still parses (it fails for its own reason)" \
    "0" "$(bash -n "$MUT6" >/dev/null 2>&1 && echo 0 || echo 1)"
# The arm is gone from the case statement, and ONLY from there: the constant's
# own definition line (`DESIGNER_AGENT="..."`) must survive, or the mutant
# would fail for a second, unrelated reason (an unbound variable) and the
# specific-misbehaviour assertion below would prove nothing about the arm.
#
# `$DESIGNER_AGENT` is a literal to match in the resolver's source text, not a
# variable to expand — single quotes are deliberate.
#
# SCOPED to _role_agent_file()'s own extracted body (claude-workflow-plugin-
# a13r round 4 fix) rather than grep'd across the WHOLE mutant file. A
# whole-file grep for this exact text shape is not specific to the arm being
# mutated: this file's own case-arm column-alignment convention means ANY
# other case statement over the same five role names formats its `designer)`
# arm identically ("designer)" + spaces + "printf"), and round 4 added
# exactly one -- cmd_check_parity's _expected_members(). That made this
# assertion fail for the WRONG reason: the strip landed correctly (the
# non-vacuity legs above all still passed) but a second, unrelated line
# elsewhere in the file kept the whole-file count at 1, not 0. Scoping the
# search to the mutated function's own body makes the non-vacuity check
# specific to the mutation it exists to prove landed, regardless of what
# else in the file happens to share its formatting -- closing the class of
# collision, not just this one instance of it.
#
# POSITIVE CONTROL, ADDED IMMEDIATELY BESIDE IT (round 4, second pass): the
# whole-file grep this replaced could never be vacuous (the file is never
# empty); a SCOPED extraction can be -- if _role_agent_file is ever renamed,
# the sed range yields NOTHING, `grep -c` yields 0, and the assertion below
# would PASS reporting "the arm was stripped" on the strength of a range
# that matched nothing at all. A measurement that did not happen would look
# identical to one that passed (measured on a rename mutant: 432 passed / 1
# failed -- this leg is what catches it; without it the suite would read
# 433/0, wrongly). So the scope is proven real FIRST, on the UNMUTATED
# resolver, matching 3.1c's own precedent exactly (extract, assert
# non-empty, THEN compare/count): this leg reddens exactly when the
# extraction itself breaks, which is the only way the mutant's "0" below
# could lie.
#
# A DIFFERENT hazard sits next to renaming and neither leg below catches it
# (independent review, round 5, R5-F2a -- corrected here after the original
# text overclaimed): if _role_agent_file's closing `}` stops being a bare
# `}` at column 0, the range does NOT empty -- it WIDENS, continuing to the
# next bare `}` at column 0, which is current_pin()'s. Measured: indenting
# only the closer at :1050 in a scratch copy grows the extracted range from
# 14 to 22 lines (current_pin()'s body absorbed into it), and BOTH legs
# below still read their expected 1 and 0 -- neither reddens. Emptying and
# widening are different failure shapes; only emptying (the rename case) is
# currently detected. Left as a named, disclosed gap rather than a third
# guard: LOW severity, and this section already carries two completeness
# legs plus the two live ones below.
#
# WHAT THESE TWO LEGS PROVE, AND WHAT THEY DO NOT (round 5, R5-F2b,
# corrected after independent review showed the ORIGINAL name overclaimed):
# both are SOURCE-TEXT SHAPE checks -- "does the exact `designer)
# printf` text appear in the selected range" -- not a claim about runtime
# BEHAVIOUR. The reviewer demonstrated the gap: insert a second,
# differently-spaced `designer) printf ...` fallback arm into the mutant
# alongside the stripped one, and both counts below are unaffected (still
# 1 on $MS, still 0 on $MUT6) while `_role_agent_file designer` would still
# resolve correctly at runtime, because bash's case statement does not care
# how an arm is spaced. Confirmed independently: the scoped counts are
# unaffected by that insertion (verified directly); the resolver's
# continued success follows from ordinary case-statement parsing, which
# does not depend on inter-token whitespace. The SEMANTIC claim -- that the
# mutant actually stops resolving designer -- is proven separately, by the
# SPECIFIC MISBEHAVIOUR and RESTORE CONTROL legs immediately below, which
# run `apply` for real and read back the file it did or did not write.
# shellcheck disable=SC2016
assert_eq "6.3-META non-vacuity: ...and the scope itself is real — the same extraction finds that exact text shape on the UNMUTATED resolver" \
    "1" "$(sed -n '/^_role_agent_file() {/,/^}/p' "$MS" | grep -c 'designer)        printf' || true)"
# shellcheck disable=SC2016
assert_eq "6.3-META non-vacuity: the mutant's source no longer contains that exact designer)+printf text shape (source-shape removal — see SPECIFIC MISBEHAVIOUR below for the resolution claim)" \
    "0" "$(sed -n '/^_role_agent_file() {/,/^}/p' "$MUT6" | grep -c 'designer)        printf' || true)"
# shellcheck disable=SC2016
assert_eq "6.3-META non-vacuity: ...while the DESIGNER_AGENT constant survives" \
    "1" "$(grep -c '^DESIGNER_AGENT=' "$MUT6" || true)"

# SPECIFIC MISBEHAVIOUR, live and behavioural (this is where the SEMANTIC
# claim -- "the mutant no longer resolves designer" -- is actually proven,
# not in the source-shape legs above): run the mutant over 6.1's exact
# configuration. The designer lane must now go UNWRITTEN — the mutant reads
# orchestrator.md's pin (already claude-fable-9), finds it equal to the
# desired id, and skips.
SB_63=$(ms_sandbox_with_listing "claude-base-0" "claude-fable-9")
rm -f "$SB_63/.claude/scripts/model-select.sh"   # never cp over the symlink
cp "$MUT6" "$SB_63/.claude/scripts/model-select.sh"
chmod +x "$SB_63/.claude/scripts/model-select.sh"
CLAUDE_PROJECT_DIR="$SB_63" bash "$SB_63/.claude/scripts/model-select.sh" apply --quiet >/dev/null 2>&1
MUT_RC_63=$?
assert_eq "6.3-META: the mutant still EXITS 0 — the defect is silent, which is why it needs a test" \
    "0" "$MUT_RC_63"
assert_eq "6.3-META: with the arm stripped the designer lane is NEVER WRITTEN (6.1 would fail)" \
    "claude-base-0" "$(agent_pin_of "$SB_63/.claude/agents/designer.md")"
# Discriminator: the mutant is not simply broken — the lanes that KEPT their
# arms are still written correctly, so 6.1's failure is specifically the
# missing arm and not a resolver that stopped resolving.
assert_eq "6.3-META discriminator: the implementer lane is still written by the mutant" \
    "claude-fable-9" "$(agent_pin_of "$SB_63/.claude/agents/backend.md")"
# RESTORE CONTROL: same inputs, shipped script, correct behaviour (6.1 above),
# re-asserted here against a freshly-built sandbox so the control is not a
# stale reading.
SB_63C=$(ms_sandbox_with_listing "claude-base-0" "claude-fable-9")
CLAUDE_PROJECT_DIR="$SB_63C" bash "$MS" apply --quiet >/dev/null 2>&1
assert_eq "6.3-META restore control: the SHIPPED resolver writes the designer lane" \
    "claude-fable-9" "$(agent_pin_of "$SB_63C/.claude/agents/designer.md")"

# 6.5 A lane whose representative agent file is ABSENT is skipped entirely —
# no rewrite, no switch count, no meta-task audit comment.
#
# THE DEFECT THIS GUARDS. current_pin returns EMPTY for a missing file, so
# `"" != "$desired"` holds on EVERY run: the lane would be "switched" forever,
# counted forever, and audited forever, for a file that does not exist. D0 made
# it reachable — designer.md / design-reviewer.md legitimately do not exist on
# a v4 install mid-upgrade — and it was latent before that for any of the five.
#
# The observable is the switch COUNT in the result line, which is why the
# assertion reads it rather than reading the pins: pins cannot show a rewrite
# that did not happen.
SB_65=$(ms_sandbox_with_listing "claude-base-0" "claude-base-0")
rm -f "$SB_65/.claude/agents/designer.md" "$SB_65/.claude/agents/design-reviewer.md"
RES_65=$(CLAUDE_PROJECT_DIR="$SB_65" bash "$MS" apply --quiet 2>&1 >/dev/null | grep '^model-select: roles:')
assert_contains "6.5 the three present lanes switch" "(3 switched)" "$RES_65"
assert_not_contains "6.5 the two ABSENT lanes are not counted as switches" "(5 switched)" "$RES_65"
# Second apply: everything present is now settled, so the count must reach
# ZERO. A phantom lane makes it stick at the number of missing files forever —
# that is the unbounded-audit-stream failure, and this is the leg that sees it.
RES_65B=$(CLAUDE_PROJECT_DIR="$SB_65" bash "$MS" apply --quiet 2>&1 >/dev/null | grep '^model-select: roles:')
assert_contains "6.5 a settled re-apply reports ZERO switches (no phantom lane)" \
    "(0 switched)" "$RES_65B"
# Control: with the files PRESENT the same two lanes DO switch, so 6.5's zero
# means "absent lanes are skipped" and not "this resolver never switches".
SB_65C=$(ms_sandbox_with_listing "claude-base-0" "claude-base-0")
RES_65C=$(CLAUDE_PROJECT_DIR="$SB_65C" bash "$MS" apply --quiet 2>&1 >/dev/null | grep '^model-select: roles:')
assert_contains "6.5 control: with the design agent files present all five lanes switch" \
    "(5 switched)" "$RES_65C"
assert_eq "6.5 control: ...and the designer lane really was written" \
    "claude-fable-9" "$(agent_pin_of "$SB_65C/.claude/agents/designer.md")"

# 6.4 The catch-all WARNS rather than resolving silently. Driven through the
# shipped script with a role that has no arm by construction.
WARN_64=$(CLAUDE_PROJECT_DIR="$SB_62" bash -c '
    awk "/^case \\\"\\\$SUBCMD\\\" in\$/{exit} {print}" "$1" > "$2/prefix.sh"
    # shellcheck disable=SC1090
    . "$2/prefix.sh"
    current_pin not_a_role >/dev/null
' _ "$MS" "$MUT6_DIR" 2>&1)
assert_contains "6.4 an unknown role WARNS instead of silently reading another lane" \
    "has no representative agent file" "$WARN_64"

# ===========================================================================
echo ""
echo "=== Section 7: family-class strategy grammar + typo guard ==="

# ms_sandbox_families — a sandbox whose cached listing carries three families.
ms_sandbox_families() {
    local d
    d=$(new_sandbox)
    printf -- '---\nname: designer\nmodel: claude-base-0\n---\n' > "$d/.claude/agents/designer.md"
    printf -- '---\nname: design-reviewer\nmodel: claude-base-0\n---\n' > "$d/.claude/agents/design-reviewer.md"
    printf 'claude-fable\nclaude-opus\nclaude-sonnet\n' > "$d/.claude/model-ranking"
    cat > "$d/.claude/.qa-tracking/model-select-cache.json" <<JSON
{"timestamp": $(date +%s), "models": [
  {"id":"claude-fable-9","max_input_tokens":1000000,"created_at":"2026-07-01T00:00:00Z"},
  {"id":"claude-sonnet-7","max_input_tokens":400000,"created_at":"2026-06-15T00:00:00Z"},
  {"id":"claude-opus-5-0","max_input_tokens":400000,"created_at":"2026-06-01T00:00:00Z"}]}
JSON
    printf '%s' "$d"
}

# 7.1 sonnet-class resolves INSIDE the sonnet family, not to the top pick.
SB_71=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=sonnet-class\nreviewer=top\n' > "$SB_71/.claude/model-roles"
CLAUDE_PROJECT_DIR="$SB_71" bash "$MS" apply --quiet >/dev/null 2>&1
assert_eq "7.1 sonnet-class picks the newest sonnet, not the top pick" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_71/.claude/agents/backend.md")"
assert_eq "7.1 top still picks the top family (fable), so the split is real" \
    "claude-fable-9" "$(agent_pin_of "$SB_71/.claude/agents/orchestrator.md")"
assert_eq "7.1 the strategy is recorded verbatim in the artifact" "sonnet-class" \
    "$(jq -r '.strategies.implementer' "$SB_71/.claude/.qa-tracking/model-roles-resolved.json")"

# 7.2 opus-class still works — the generalisation must not regress the only
# class strategy that existed before D0.
SB_72=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=opus-class\nreviewer=top\n' > "$SB_72/.claude/model-roles"
CLAUDE_PROJECT_DIR="$SB_72" bash "$MS" apply --quiet >/dev/null 2>&1
assert_eq "7.2 opus-class is unchanged by the generalisation" \
    "claude-opus-5-0" "$(agent_pin_of "$SB_72/.claude/agents/backend.md")"

# 7.3 A family present in the ranking tiers but absent from the LISTING falls
# back to top and warns — WITHOUT the typo hint, because the family is known.
SB_73=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=haiku-class\nreviewer=top\n' > "$SB_73/.claude/model-roles"
printf 'claude-fable\nclaude-opus\nclaude-sonnet\nclaude-haiku\n' > "$SB_73/.claude/model-ranking"
WARN_73=$(CLAUDE_PROJECT_DIR="$SB_73" bash "$MS" apply --quiet 2>&1 >/dev/null)
assert_contains "7.3 an absent-but-known family warns and falls back to top" \
    "no claude-haiku-* model in listing" "$WARN_73"
assert_not_contains "7.3 a KNOWN family gets NO typo hint" "check for a typo" "$WARN_73"
assert_eq "7.3 the fallback landed on the top pick" \
    "claude-fable-9" "$(agent_pin_of "$SB_73/.claude/agents/backend.md")"
assert_eq "7.3 the artifact records the fallback for that role" "true" \
    "$(jq -r '.fallbacks.implementer' "$SB_73/.claude/.qa-tracking/model-roles-resolved.json")"

# 7.4 TYPO GUARD: a misspelt family is in neither the listing nor the ranking,
# so the warning gains the typo hint. This is the whole compensation for NOT
# gating selection on the tier list.
SB_74=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=sonnnet-class\nreviewer=top\n' > "$SB_74/.claude/model-roles"
WARN_74=$(CLAUDE_PROJECT_DIR="$SB_74" bash "$MS" apply --quiet 2>&1 >/dev/null)
assert_contains "7.4 an unknown family adds the typo hint" "check for a typo" "$WARN_74"
assert_contains "7.4 the typo hint names the family it could not place" "claude-sonnnet" "$WARN_74"
assert_eq "7.4 selection is NOT gated on the tier list — it still resolves" \
    "claude-fable-9" "$(agent_pin_of "$SB_74/.claude/agents/backend.md")"

# 7.5 A value that is not `top` and not `<family>-class` is still a loud
# misconfiguration, exactly as before D0.
SB_75=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=banana\nreviewer=top\n' > "$SB_75/.claude/model-roles"
WARN_75=$(CLAUDE_PROJECT_DIR="$SB_75" bash "$MS" roles 2>&1 >/dev/null)
assert_contains "7.5 a non-class garbage value still warns" "unknown strategy 'banana'" "$WARN_75"
assert_eq "7.5 ...and falls back to top" "top" "$(roles_strategy "$SB_75" implementer)"

# 7.6 META — revert the family rule to the pre-D0 `opus-class` literal and
# prove sonnet-class stops working.
#
# NON-VACUITY: the substitution is anchored on the shipped `*-class)` case arm
# and exits 7 if absent; the mutant is byte-compared and parsed.
MUT7_DIR=$(mktemp -d "$TESTROOT/fammut.XXXXXX")
MUT7="$MUT7_DIR/model-select.sh"
awk '/^        \*-class\)$/ { print "        opus-class)"; found=1; next } { print }
     END { if (!found) exit 7 }' "$MS" > "$MUT7"
AWK_RC_76=$?
assert_eq "7.6-META non-vacuity: the *-class -> opus-class revert landed" "0" "$AWK_RC_76"
assert_eq "7.6-META non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT7" "$MS" && echo same || echo differs)"
assert_eq "7.6-META non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT7" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_76=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=sonnet-class\nreviewer=top\n' > "$SB_76/.claude/model-roles"
rm -f "$SB_76/.claude/scripts/model-select.sh"
cp "$MUT7" "$SB_76/.claude/scripts/model-select.sh"
chmod +x "$SB_76/.claude/scripts/model-select.sh"
CLAUDE_PROJECT_DIR="$SB_76" bash "$SB_76/.claude/scripts/model-select.sh" apply --quiet >/dev/null 2>&1
assert_eq "7.6-META: with the literal restored, sonnet-class falls through to top (7.1 would fail)" \
    "claude-fable-9" "$(agent_pin_of "$SB_76/.claude/agents/backend.md")"
assert_eq "7.6-META discriminator: opus-class still works in the mutant, so it is the GENERALISATION that broke" \
    "claude-opus-5-0" "$(printf 'orchestrator=top\nimplementer=opus-class\nreviewer=top\n' > "$SB_76/.claude/model-roles"; \
        CLAUDE_PROJECT_DIR="$SB_76" bash "$SB_76/.claude/scripts/model-select.sh" apply --quiet >/dev/null 2>&1; \
        agent_pin_of "$SB_76/.claude/agents/backend.md")"
SB_76C=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=sonnet-class\nreviewer=top\n' > "$SB_76C/.claude/model-roles"
CLAUDE_PROJECT_DIR="$SB_76C" bash "$MS" apply --quiet >/dev/null 2>&1
assert_eq "7.6-META restore control: the SHIPPED resolver still honours sonnet-class" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_76C/.claude/agents/backend.md")"

# ===========================================================================
echo ""
echo "=== Section 8: per-unit escalation (declared, audited, reversible) ==="
#
# HONESTY CONSTRAINT (correction 13). Every assertion below is about FILE
# STATE, ARTIFACT CONTENT or REVERSIBILITY. None of them claims — and none of
# them could establish — that a subagent RAN on the escalated model. Whether
# the runtime honours a mid-session frontmatter `model:` change is not
# established anywhere in this tree and is not observable offline.

SB_8=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=sonnet-class\nreviewer=top\nimplementer_class_high=opus-class\n' \
    > "$SB_8/.claude/model-roles"
CLAUDE_PROJECT_DIR="$SB_8" bash "$MS" apply --quiet >/dev/null 2>&1
ESC_STATE_8="$SB_8/.claude/.qa-tracking/implementer-escalation.json"

assert_eq "8.1 the escalation strategy is resolved into the artifact" "claude-opus-5-0" \
    "$(jq -r '.escalation.resolved' "$SB_8/.claude/.qa-tracking/model-roles-resolved.json")"
assert_eq "8.1 ...under escalation{}, NEVER under roles{}" "null" \
    "$(jq -r '.roles.implementer_class_high // "null"' "$SB_8/.claude/.qa-tracking/model-roles-resolved.json")"
assert_eq "8.1 pre-escalation the implementer lane is on its configured strategy" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_8/.claude/agents/backend.md")"

CLAUDE_PROJECT_DIR="$SB_8" bash "$MS" escalate unit-U3 >/dev/null 2>&1
assert_eq "8.2 escalate repins the whole implementer class (backend)" \
    "claude-opus-5-0" "$(agent_pin_of "$SB_8/.claude/agents/backend.md")"
assert_eq "8.2 ...and frontend, so the class stays in lockstep" \
    "claude-opus-5-0" "$(agent_pin_of "$SB_8/.claude/agents/frontend.md")"
assert_eq "8.2 escalate leaves the ORCHESTRATOR lane alone" \
    "claude-fable-9" "$(agent_pin_of "$SB_8/.claude/agents/orchestrator.md")"
assert_eq "8.2 the state file records the task it was escalated for" "unit-U3" \
    "$(jq -r '.task_id' "$ESC_STATE_8")"
assert_eq "8.2 the state file records the pin to return to" "claude-sonnet-7" \
    "$(jq -r '.previous_pin' "$ESC_STATE_8")"
assert_contains "8.2 the record states what it does NOT claim" \
    "NOT evidence that any subagent ran on this model" "$(cat "$ESC_STATE_8")"

# 8.3 IDEMPOTENT. Re-escalating must not overwrite previous_pin with the
# ESCALATED id — that would record the escalated model as the thing to restore
# to, and restore would become a permanent no-op.
CLAUDE_PROJECT_DIR="$SB_8" bash "$MS" escalate unit-U3 >/dev/null 2>&1
assert_eq "8.3 re-escalating preserves previous_pin (restore stays possible)" \
    "claude-sonnet-7" "$(jq -r '.previous_pin' "$ESC_STATE_8")"

# 8.4 REVERSIBLE, and idempotently so.
CLAUDE_PROJECT_DIR="$SB_8" bash "$MS" restore >/dev/null 2>&1
assert_eq "8.4 restore returns the implementer lane to its previous pin" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_8/.claude/agents/backend.md")"
assert_eq "8.4 restore clears the state file" "gone" \
    "$([ -f "$ESC_STATE_8" ] && echo present || echo gone)"
OUT_84=$(CLAUDE_PROJECT_DIR="$SB_8" bash "$MS" restore 2>&1)
assert_contains "8.4 a second restore is a clean no-op" "no active escalation" "$OUT_84"

# 8.5 META — strip the repin from cmd_restore and prove restore stops
# restoring while still REPORTING success. That is the failure mode worth
# guarding: a reversal that says it happened.
#
# The anchor moved in the R1-F5 round (the call is now `… || ar_rc=$?` so each
# outcome gets its own answer), and the exit-7 discipline is what said so: the
# old anchor stopped matching and this leg went red instead of quietly
# mutating nothing. Replacing the call with a bare `ar_rc=0` is the same
# mutation as before — restore takes its success arm having repinned nothing.
MUT8_DIR=$(mktemp -d "$TESTROOT/escmut.XXXXXX")
MUT8="$MUT8_DIR/model-select.sh"
awk '/^    _apply_role implementer "\$prev" \|\| ar_rc=\$\?$/ { print "    ar_rc=0"; found=1; next } { print }
     END { if (!found) exit 7 }' "$MS" > "$MUT8"
AWK_RC_85=$?
assert_eq "8.5-META non-vacuity: the restore-repin strip landed" "0" "$AWK_RC_85"
assert_eq "8.5-META non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT8" "$MS" && echo same || echo differs)"
assert_eq "8.5-META non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT8" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_85=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=sonnet-class\nreviewer=top\nimplementer_class_high=opus-class\n' \
    > "$SB_85/.claude/model-roles"
CLAUDE_PROJECT_DIR="$SB_85" bash "$MS" apply --quiet >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$SB_85" bash "$MS" escalate unit-U9 >/dev/null 2>&1
rm -f "$SB_85/.claude/scripts/model-select.sh"
cp "$MUT8" "$SB_85/.claude/scripts/model-select.sh"
chmod +x "$SB_85/.claude/scripts/model-select.sh"
OUT_85=$(CLAUDE_PROJECT_DIR="$SB_85" bash "$SB_85/.claude/scripts/model-select.sh" restore 2>&1)
assert_contains "8.5-META: the mutant still REPORTS a successful restore" \
    "returned to claude-sonnet-7" "$OUT_85"
assert_eq "8.5-META: ...while the pin is STILL ESCALATED (8.4 would fail)" \
    "claude-opus-5-0" "$(agent_pin_of "$SB_85/.claude/agents/backend.md")"
SB_85C=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=sonnet-class\nreviewer=top\nimplementer_class_high=opus-class\n' \
    > "$SB_85C/.claude/model-roles"
CLAUDE_PROJECT_DIR="$SB_85C" bash "$MS" apply --quiet >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$SB_85C" bash "$MS" escalate unit-U9 >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$SB_85C" bash "$MS" restore >/dev/null 2>&1
assert_eq "8.5-META restore control: the SHIPPED restore really repins" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_85C/.claude/agents/backend.md")"

# 8.6 previous_pin is the PRE-ESCALATION pin, across a SUPERSEDING escalation
# (QA R1-F5). 8.3 covers re-escalating the SAME task; this is the other one —
# a second task escalated while the first is still live. That fell through 8.3's
# guard and recorded previous_pin=<the escalated id>, after which restore
# returned the lane to the escalated model and every later restore was a no-op.
#
# D0 ships no caller. D4/D5 run parallel unit batches over ONE implementer lane,
# which is precisely where the second escalation arrives.
esc_sandbox() {
    local d
    d=$(ms_sandbox_families)
    printf 'orchestrator=top\nimplementer=sonnet-class\nreviewer=top\nimplementer_class_high=opus-class\n' \
        > "$d/.claude/model-roles"
    CLAUDE_PROJECT_DIR="$d" bash "$MS" apply --quiet >/dev/null 2>&1
    printf '%s' "$d"
}
SB_86=$(esc_sandbox)
ESC_STATE_86="$SB_86/.claude/.qa-tracking/implementer-escalation.json"
CLAUDE_PROJECT_DIR="$SB_86" bash "$MS" escalate unit-A >/dev/null 2>&1
assert_eq "8.6 a FIRST escalation records no supersedes key" "null" \
    "$(jq -r '.supersedes // "null"' "$ESC_STATE_86")"
WARN_86=$(CLAUDE_PROJECT_DIR="$SB_86" bash "$MS" escalate unit-B 2>&1 >/dev/null)
assert_eq "8.6 the record now names the NEW task" "unit-B" "$(jq -r '.task_id' "$ESC_STATE_86")"
assert_eq "8.6 previous_pin is still the PRE-escalation pin, not the escalated one" \
    "claude-sonnet-7" "$(jq -r '.previous_pin' "$ESC_STATE_86")"
assert_eq "8.6 the displaced task stays in the audit trail" "unit-A" \
    "$(jq -r '.supersedes' "$ESC_STATE_86")"
assert_contains "8.6 ...and the operator is told a live escalation was superseded" \
    "is already live on the implementer lane" "$WARN_86"
CLAUDE_PROJECT_DIR="$SB_86" bash "$MS" restore >/dev/null 2>&1
assert_eq "8.6 restore after a supersede returns the lane to its PRE-escalation pin" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_86/.claude/agents/backend.md")"
assert_eq "8.6 ...and the whole class with it" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_86/.claude/agents/devops.md")"

# 8.6 META — revert the carry-forward and prove the lane stops being
# restorable. NON-VACUITY: awk exits 7 if the guard is not found; the mutant is
# byte-compared and parsed.
MUT86_DIR=$(mktemp -d "$TESTROOT/carrymut.XXXXXX")
MUT86="$MUT86_DIR/model-select.sh"
awk '/^        if \[ -n "\$live_prev" \]; then$/ { print "        if false; then"; found=1; next } { print }
     END { if (!found) exit 7 }' "$MS" > "$MUT86"
AWK_RC_86=$?
assert_eq "8.6-META non-vacuity: the previous_pin carry-forward strip landed" "0" "$AWK_RC_86"
assert_eq "8.6-META non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT86" "$MS" && echo same || echo differs)"
assert_eq "8.6-META non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT86" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_86M=$(esc_sandbox)
CLAUDE_PROJECT_DIR="$SB_86M" bash "$MS" escalate unit-A >/dev/null 2>&1
rm -f "$SB_86M/.claude/scripts/model-select.sh"
cp "$MUT86" "$SB_86M/.claude/scripts/model-select.sh"
chmod +x "$SB_86M/.claude/scripts/model-select.sh"
CLAUDE_PROJECT_DIR="$SB_86M" bash "$SB_86M/.claude/scripts/model-select.sh" escalate unit-B >/dev/null 2>&1
assert_eq "8.6-META: without the carry-forward previous_pin becomes the ESCALATED id (8.6 would fail)" \
    "claude-opus-5-0" "$(jq -r '.previous_pin' "$SB_86M/.claude/.qa-tracking/implementer-escalation.json")"
# Discriminator, read BEFORE the restore below because a successful restore
# consumes the record: the mutant is not simply broken — its second escalation
# still resolved and recorded normally, so 8.6's failure is specifically the
# lost previous_pin. (The first draft of this leg read the record after the
# restore and failed for that reason, which is the assertion doing its job.)
assert_eq "8.6-META discriminator: the mutant's escalation itself still works" \
    "claude-opus-5-0" "$(jq -r '.resolved' "$SB_86M/.claude/.qa-tracking/implementer-escalation.json")"
CLAUDE_PROJECT_DIR="$SB_86M" bash "$SB_86M/.claude/scripts/model-select.sh" restore >/dev/null 2>&1
assert_eq "8.6-META: ...so restore leaves the lane ESCALATED — a reversal that cannot reverse" \
    "claude-opus-5-0" "$(agent_pin_of "$SB_86M/.claude/agents/backend.md")"
SB_86C=$(esc_sandbox)
CLAUDE_PROJECT_DIR="$SB_86C" bash "$MS" escalate unit-A >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$SB_86C" bash "$MS" escalate unit-B >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$SB_86C" bash "$MS" restore >/dev/null 2>&1
assert_eq "8.6-META restore control: the SHIPPED resolver restores after a supersede" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_86C/.claude/agents/backend.md")"

# 8.7 A REWRITE FAILURE IS REPORTED AS ONE, and the record survives it (QA
# R1-F5). _apply_role returned 1 for no-op, missing-file and helper-failure
# alike, so escalate and restore both answered a failure with "already at <id>
# (no rewrite needed)" — one line after the helper's own failure line — and
# restore then deleted the only artifact that made the lane restorable.
#
# The failure is induced through the shipped seam: an apply helper that is
# executable (so the -x guard passes) and exits non-zero.
break_apply_helper() {
    rm -f "$1/.claude/scripts/workflow-model-apply.sh"
    printf '#!/bin/bash\nprintf "apply-helper: simulated failure\\n" >&2\nexit 1\n' \
        > "$1/.claude/scripts/workflow-model-apply.sh"
    chmod +x "$1/.claude/scripts/workflow-model-apply.sh"
}
SB_87=$(esc_sandbox)
ESC_STATE_87="$SB_87/.claude/.qa-tracking/implementer-escalation.json"
CLAUDE_PROJECT_DIR="$SB_87" bash "$MS" escalate unit-F >/dev/null 2>&1
break_apply_helper "$SB_87"
OUT_87=$(CLAUDE_PROJECT_DIR="$SB_87" bash "$MS" restore 2>&1)
assert_contains "8.7 restore reports a failed rewrite AS a failure" \
    "the rewrite helper FAILED" "$OUT_87"
assert_not_contains "8.7 ...and never as a no-op (the conflation this fixes)" \
    "already at claude-sonnet-7 (no rewrite needed)" "$OUT_87"
assert_eq "8.7 the escalation record SURVIVES the failure (the lane stays restorable)" \
    "present" "$([ -f "$ESC_STATE_87" ] && echo present || echo gone)"
assert_eq "8.7 ...and the pin is still escalated, as the message says" \
    "claude-opus-5-0" "$(agent_pin_of "$SB_87/.claude/agents/backend.md")"
# The retry closes the loop: with the helper working again the KEPT record is
# what lets restore finish the job. This is the leg the old behaviour could not
# pass at all, because the record was already gone.
rm -f "$SB_87/.claude/scripts/workflow-model-apply.sh"
ln -sf "$APPLY" "$SB_87/.claude/scripts/workflow-model-apply.sh"
CLAUDE_PROJECT_DIR="$SB_87" bash "$MS" restore >/dev/null 2>&1
assert_eq "8.7 a retry after the helper is fixed really restores the lane" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_87/.claude/agents/backend.md")"
assert_eq "8.7 ...and only THEN is the record cleared" "gone" \
    "$([ -f "$ESC_STATE_87" ] && echo present || echo gone)"

# 8.7b The same distinction on the escalate side: a failed repin must not be
# reported as "already at <the escalated id>" while the lane sits unescalated.
SB_87B=$(esc_sandbox)
break_apply_helper "$SB_87B"
OUT_87B=$(CLAUDE_PROJECT_DIR="$SB_87B" bash "$MS" escalate unit-G 2>&1)
assert_contains "8.7b escalate reports a failed rewrite AS a failure" \
    "the rewrite helper FAILED" "$OUT_87B"
assert_not_contains "8.7b ...and does not claim the lane is already escalated" \
    "already at claude-opus-5-0" "$OUT_87B"
assert_eq "8.7b the lane really did not move" \
    "claude-sonnet-7" "$(agent_pin_of "$SB_87B/.claude/agents/backend.md")"

# 8.7c And the third outcome: no representative agent file. Nothing was
# rewritten, but the OTHER members of the class are still escalated, so the
# record must be kept rather than dropped on a skip.
SB_87C=$(esc_sandbox)
CLAUDE_PROJECT_DIR="$SB_87C" bash "$MS" escalate unit-H >/dev/null 2>&1
rm -f "$SB_87C/.claude/agents/backend.md"
OUT_87C=$(CLAUDE_PROJECT_DIR="$SB_87C" bash "$MS" restore 2>&1)
assert_contains "8.7c restore says the lane has no agent file rather than claiming success" \
    "no agent file for the implementer lane" "$OUT_87C"
assert_eq "8.7c the record is KEPT — frontend/devops are still escalated" "present" \
    "$([ -f "$SB_87C/.claude/.qa-tracking/implementer-escalation.json" ] && echo present || echo gone)"
assert_eq "8.7c ...and they demonstrably are" \
    "claude-opus-5-0" "$(agent_pin_of "$SB_87C/.claude/agents/frontend.md")"

# 8.7 META — map every non-zero outcome back onto the no-op arm, which is
# exactly the pre-fix conflation, and prove 8.7 goes red.
MUT87_DIR=$(mktemp -d "$TESTROOT/rcmut.XXXXXX")
MUT87="$MUT87_DIR/model-select.sh"
awk '/^    _apply_role implementer "\$prev" \|\| ar_rc=\$\?$/ { print "    _apply_role implementer \"$prev\" || ar_rc=1"; found=1; next } { print }
     END { if (!found) exit 7 }' "$MS" > "$MUT87"
AWK_RC_87=$?
assert_eq "8.7-META non-vacuity: the outcome-status collapse landed" "0" "$AWK_RC_87"
assert_eq "8.7-META non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT87" "$MS" && echo same || echo differs)"
assert_eq "8.7-META non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT87" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_87M=$(esc_sandbox)
CLAUDE_PROJECT_DIR="$SB_87M" bash "$MS" escalate unit-F >/dev/null 2>&1
break_apply_helper "$SB_87M"
rm -f "$SB_87M/.claude/scripts/model-select.sh"
cp "$MUT87" "$SB_87M/.claude/scripts/model-select.sh"
chmod +x "$SB_87M/.claude/scripts/model-select.sh"
OUT_87M=$(CLAUDE_PROJECT_DIR="$SB_87M" bash "$SB_87M/.claude/scripts/model-select.sh" restore 2>&1)
assert_contains "8.7-META: the mutant answers a FAILURE with 'no rewrite needed' (8.7 would fail)" \
    "already at claude-sonnet-7 (no rewrite needed)" "$OUT_87M"
assert_eq "8.7-META: ...and deletes the record it cannot act on, stranding the escalated lane" \
    "gone" "$([ -f "$SB_87M/.claude/.qa-tracking/implementer-escalation.json" ] && echo present || echo gone)"
assert_eq "8.7-META discriminator: the pin the mutant claimed to restore never moved" \
    "claude-opus-5-0" "$(agent_pin_of "$SB_87M/.claude/agents/backend.md")"
SB_87MC=$(esc_sandbox)
CLAUDE_PROJECT_DIR="$SB_87MC" bash "$MS" escalate unit-F >/dev/null 2>&1
break_apply_helper "$SB_87MC"
OUT_87MC=$(CLAUDE_PROJECT_DIR="$SB_87MC" bash "$MS" restore 2>&1)
assert_contains "8.7-META restore control: the SHIPPED restore still reports the failure" \
    "the rewrite helper FAILED" "$OUT_87MC"
assert_eq "8.7-META restore control: ...and still keeps the record" "present" \
    "$([ -f "$SB_87MC/.claude/.qa-tracking/implementer-escalation.json" ] && echo present || echo gone)"

# ===========================================================================
echo ""
echo "=== Section 9: identity collapse + missing keys + session-model guard ==="

# 9.1 Collapse is DETECTED, WARNED, FLAGGED — and never blocks.
SB_91=$(ms_sandbox_families)
printf 'designer=top\ndesign_reviewer=top\norchestrator=top\nimplementer=sonnet-class\nreviewer=top\n' \
    > "$SB_91/.claude/model-roles"
WARN_91=$(CLAUDE_PROJECT_DIR="$SB_91" bash "$MS" apply --quiet 2>&1 >/dev/null)
RC_91=$?
assert_eq "9.1 collapse does NOT block (exit 0)" "0" "$RC_91"
assert_contains "9.1 collapse warns loudly" "identity collapse" "$WARN_91"
assert_contains "9.1 the warning names both clearances" "installing Codex" "$WARN_91"
assert_eq "9.1 the artifact records the collapse" "true" \
    "$(jq -r '.identity_collapse' "$SB_91/.claude/.qa-tracking/model-roles-resolved.json")"
assert_eq "9.1 the flag file is written" "present" \
    "$([ -f "$SB_91/.claude/.qa-tracking/design-family-collapse" ] && echo present || echo gone)"
assert_eq "9.1 PINS ARE STILL WRITTEN — the collapse is a report, not a refusal" \
    "claude-fable-9" "$(agent_pin_of "$SB_91/.claude/agents/designer.md")"

# 9.2 A distinct design_reviewer strategy clears it, and the flag file is
# REMOVED rather than left behind (a stale flag is a false alarm forever).
SB_92=$(ms_sandbox_families)
printf 'designer=top\ndesign_reviewer=opus-class\norchestrator=top\nimplementer=sonnet-class\nreviewer=top\n' \
    > "$SB_92/.claude/model-roles"
touch "$SB_92/.claude/.qa-tracking/design-family-collapse"
CLAUDE_PROJECT_DIR="$SB_92" bash "$MS" apply --quiet >/dev/null 2>&1
assert_eq "9.2 distinct strategies clear the collapse" "false" \
    "$(jq -r '.identity_collapse' "$SB_92/.claude/.qa-tracking/model-roles-resolved.json")"
assert_eq "9.2 a pre-existing flag file is REMOVED, not left stale" "gone" \
    "$([ -f "$SB_92/.claude/.qa-tracking/design-family-collapse" ] && echo present || echo gone)"

# 9.3 The Codex design lane also clears it: on that lane the reviewing identity
# is not the Claude model the pin names, so equal pins collapse nothing.
SB_93=$(ms_sandbox_families)
printf 'designer=top\ndesign_reviewer=top\norchestrator=top\nimplementer=sonnet-class\nreviewer=top\n' \
    > "$SB_93/.claude/model-roles"
WORKFLOW_DESIGN_REVIEWER_LANE=codex CLAUDE_PROJECT_DIR="$SB_93" bash "$MS" apply --quiet >/dev/null 2>&1
assert_eq "9.3 the codex design lane clears the collapse" "false" \
    "$(jq -r '.identity_collapse' "$SB_93/.claude/.qa-tracking/model-roles-resolved.json")"
assert_eq "9.3 the design lane is recorded independently of the reviewer lane" "codex" \
    "$(jq -r '.design_reviewer_lane' "$SB_93/.claude/.qa-tracking/model-roles-resolved.json")"
assert_eq "9.3 ...and the REVIEWER lane is untouched by the design env seam" "claude" \
    "$(jq -r '.reviewer_lane' "$SB_93/.claude/.qa-tracking/model-roles-resolved.json")"

# 9.4 missing_keys — correction 14's visibility surface. A v4-shaped
# model-roles (three roles, no escalation key) must SAY what it lacks.
SB_94=$(ms_sandbox_families)
printf 'orchestrator=top\nimplementer=opus-class\nreviewer=top\n' > "$SB_94/.claude/model-roles"
CLAUDE_PROJECT_DIR="$SB_94" bash "$MS" apply --quiet >/dev/null 2>&1
MISSING_94=$(jq -r '.missing_keys | sort | join(",")' "$SB_94/.claude/.qa-tracking/model-roles-resolved.json")
assert_eq "9.4 a v4-shaped model-roles reports every key it lacks" \
    "design_reviewer,designer,implementer_class_high" "$MISSING_94"
assert_eq "9.4 the v5 shipped config reports NO missing keys (the control)" "" \
    "$(cp "$PROJECT_DIR/.claude/model-roles" "$SB_94/.claude/model-roles"; \
       CLAUDE_PROJECT_DIR="$SB_94" bash "$MS" apply --quiet >/dev/null 2>&1; \
       jq -r '.missing_keys | join(",")' "$SB_94/.claude/.qa-tracking/model-roles-resolved.json")"

# 9.5 Session-model guard. The statusline is the ONLY place the live session
# model is observable, so the comparison happens there and the result is
# persisted for session-start.sh to re-validate.
SB_95=$(new_sandbox)
printf '{"roles":{"orchestrator":"claude-fable-5","implementer":"claude-sonnet-5","reviewer":"claude-fable-5"},"reviewer_lane":"claude"}' \
    > "$SB_95/.claude/.qa-tracking/model-roles-resolved.json"
DRIFT_95="$SB_95/.claude/.qa-tracking/session-model-drift.json"
OUT_95=$(printf '{"model":{"id":"claude-opus-4-5"}}' | CLAUDE_PROJECT_DIR="$SB_95" bash "$SL" 2>/dev/null)
assert_contains "9.5 a session on the wrong model renders !sess" "!sess" "$OUT_95"
assert_eq "9.5 ...and the drift record names the expected id" "claude-fable-5" \
    "$(jq -r '.expected' "$DRIFT_95")"
assert_eq "9.5 ...and the live id" "claude-opus-4-5" "$(jq -r '.live' "$DRIFT_95")"
assert_contains "9.5 ...and carries the fix verbatim" "/model claude-fable-5" "$(cat "$DRIFT_95")"

# 9.6 READ-COMPARE-WRITE. The statusline runs on EVERY render, so an unchanged
# drift state must not rewrite the file — otherwise its mtime is noise and the
# hook writes continuously for the whole session.
#
# Detected with `find -newer` against a reference file rather than by comparing
# formatted mtimes: -newer compares timestamps directly, so the assertion never
# becomes a function of wall-clock elapsed time (the failure mode LESSONS.md
# records for age-based guards), and it does not parse `ls` output.
#
# The POSITIVE CONTROL below is what makes the negative meaningful: a
# statusline that never wrote the file at all would also pass 9.6.
REF_96="$TESTROOT/ref-96"
sleep 1
touch "$REF_96"
printf '{"model":{"id":"claude-opus-4-5"}}' | CLAUDE_PROJECT_DIR="$SB_95" bash "$SL" >/dev/null 2>&1
printf '{"model":{"id":"claude-opus-4-5"}}' | CLAUDE_PROJECT_DIR="$SB_95" bash "$SL" >/dev/null 2>&1
assert_eq "9.6 an unchanged drift state is NOT rewritten across repeated renders" \
    "0" "$(find "$DRIFT_95" -newer "$REF_96" 2>/dev/null | grep -c . || true)"
# Positive control: a CHANGED drift state IS written, so 9.6's zero means "did
# not write" rather than "cannot write".
printf '{"model":{"id":"claude-mythos-2"}}' | CLAUDE_PROJECT_DIR="$SB_95" bash "$SL" >/dev/null 2>&1
assert_eq "9.6 positive control: a CHANGED drift state IS rewritten" \
    "1" "$(find "$DRIFT_95" -newer "$REF_96" 2>/dev/null | grep -c . || true)"
assert_eq "9.6 positive control: ...with the new live id" "claude-mythos-2" \
    "$(jq -r '.live' "$DRIFT_95")"
# Put the record back to the 9.5 state for 9.7/9.8 below.
printf '{"model":{"id":"claude-opus-4-5"}}' | CLAUDE_PROJECT_DIR="$SB_95" bash "$SL" >/dev/null 2>&1

# 9.7 A render with NO model in the envelope must NOT clear the record: "no
# comparison was possible" is not "no drift". This is the discriminating
# control — a checker that cleared on absent evidence would look identical to a
# correct one on every other row.
printf '{}' | CLAUDE_PROJECT_DIR="$SB_95" bash "$SL" >/dev/null 2>&1
assert_eq "9.7 an envelope with no .model.id leaves the record alone" "present" \
    "$([ -f "$DRIFT_95" ] && echo present || echo gone)"

# 9.8 A matching model DOES clear it (a completed comparison finding no drift).
OUT_98=$(printf '{"model":{"id":"claude-fable-5"}}' | CLAUDE_PROJECT_DIR="$SB_95" bash "$SL" 2>/dev/null)
assert_eq "9.8 a matching session model clears the record" "gone" \
    "$([ -f "$DRIFT_95" ] && echo present || echo gone)"
assert_not_contains "9.8 ...and drops the !sess flag" "!sess" "$OUT_98"

# 9.9 META — strip the comparison call and prove the guard is load-bearing.
MUT9_DIR=$(mktemp -d "$TESTROOT/sessmut.XXXXXX")
MUT9="$MUT9_DIR/statusline.sh"
awk '/^        drift=\$\(evaluate_session_model "\$orch_id"\)$/ { print "        drift=\"\""; found=1; next } { print }
     END { if (!found) exit 7 }' "$SL" > "$MUT9"
AWK_RC_99=$?
assert_eq "9.9-META non-vacuity: the comparison-call strip landed" "0" "$AWK_RC_99"
assert_eq "9.9-META non-vacuity: the mutant differs from the shipped statusline" \
    "differs" "$(cmp -s "$MUT9" "$SL" && echo same || echo differs)"
assert_eq "9.9-META non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT9" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_99=$(new_sandbox)
rm -f "$SB_99/.claude/scripts/statusline.sh"
cp "$MUT9" "$SB_99/.claude/scripts/statusline.sh"
chmod +x "$SB_99/.claude/scripts/statusline.sh"
printf '{"roles":{"orchestrator":"claude-fable-5","implementer":"claude-sonnet-5","reviewer":"claude-fable-5"},"reviewer_lane":"claude"}' \
    > "$SB_99/.claude/.qa-tracking/model-roles-resolved.json"
OUT_99=$(printf '{"model":{"id":"claude-opus-4-5"}}' \
    | CLAUDE_PROJECT_DIR="$SB_99" bash "$SB_99/.claude/scripts/statusline.sh" 2>/dev/null)
assert_not_contains "9.9-META: with the comparison stripped there is NO !sess (9.5 would fail)" \
    "!sess" "$OUT_99"
assert_eq "9.9-META: ...and no drift record is written for session-start to read" "gone" \
    "$([ -f "$SB_99/.claude/.qa-tracking/session-model-drift.json" ] && echo present || echo gone)"
assert_contains "9.9-META discriminator: the mutant still renders the model segment normally" \
    "orch+rev:fable-5" "$OUT_99"
SB_99C=$(new_sandbox)
printf '{"roles":{"orchestrator":"claude-fable-5","implementer":"claude-sonnet-5","reviewer":"claude-fable-5"},"reviewer_lane":"claude"}' \
    > "$SB_99C/.claude/.qa-tracking/model-roles-resolved.json"
assert_contains "9.9-META restore control: the SHIPPED statusline still renders !sess" "!sess" \
    "$(printf '{"model":{"id":"claude-opus-4-5"}}' | CLAUDE_PROJECT_DIR="$SB_99C" bash "$SL" 2>/dev/null)"

# 9.10 THE COMPARISON IS BY MODEL IDENTITY, NOT BY ID STRING (QA R1-F4).
#
# It shipped as literal equality, so `claude-fable-5[1m]` — the 1M-context
# variant of the model the resolver picked — read as drift on every render,
# forever, with a fix line telling the operator to move to a smaller window.
# This repo's own drift record carried that exact shape.
#
# The rule is deliberately asymmetric, and 9.10c is why: when the RESOLVER
# named a variant, a session that is not on it really is not on what was
# resolved, and the fix line is actionable. A flat both-sides strip would have
# traded this true positive away for the false one above.
sl_sandbox_orch() {   # <resolved-orchestrator-id> — sandbox + a 3-role artifact
    local d
    d=$(new_sandbox)
    printf '{"roles":{"orchestrator":"%s","implementer":"claude-sonnet-5","reviewer":"%s"},"reviewer_lane":"claude"}' \
        "$1" "$1" > "$d/.claude/.qa-tracking/model-roles-resolved.json"
    printf '%s' "$d"
}
SB_910=$(sl_sandbox_orch "claude-fable-5")
DRIFT_910="$SB_910/.claude/.qa-tracking/session-model-drift.json"
OUT_910=$(printf '{"model":{"id":"claude-fable-5[1m]"}}' | CLAUDE_PROJECT_DIR="$SB_910" bash "$SL" 2>/dev/null)
assert_not_contains "9.10 the 1M variant of the RESOLVED model is not drift" "!sess" "$OUT_910"
assert_eq "9.10 ...and no drift record is written for session-start to report" "gone" \
    "$([ -f "$DRIFT_910" ] && echo present || echo gone)"
# 9.10b A record left by the pre-fix comparison is CLEARED on the next render,
# so an operator who ignored the bad advice stops being told to act on it.
printf '{"expected":"claude-fable-5","live":"claude-fable-5[1m]","observed_at":"2026-01-01T00:00:00Z","fix":"/model claude-fable-5"}' \
    > "$DRIFT_910"
printf '{"model":{"id":"claude-fable-5[1m]"}}' | CLAUDE_PROJECT_DIR="$SB_910" bash "$SL" >/dev/null 2>&1
assert_eq "9.10b a stale record from the literal comparison is cleared" "gone" \
    "$([ -f "$DRIFT_910" ] && echo present || echo gone)"
# 9.10c THE TRUE POSITIVE THE ASYMMETRY KEEPS. pick_best sorts _ctx DESC, so a
# resolved `[1m]` is a deliberate pick; a session on the bare id is not on it.
SB_910C=$(sl_sandbox_orch "claude-fable-5[1m]")
DRIFT_910C="$SB_910C/.claude/.qa-tracking/session-model-drift.json"
OUT_910C=$(printf '{"model":{"id":"claude-fable-5"}}' | CLAUDE_PROJECT_DIR="$SB_910C" bash "$SL" 2>/dev/null)
assert_contains "9.10c a session on the bare id when the RESOLVER named [1m] is still drift" \
    "!sess" "$OUT_910C"
assert_contains "9.10c ...and the fix line names the variant, so it is actionable" \
    "/model claude-fable-5[1m]" "$(cat "$DRIFT_910C")"
# 9.10d Discriminator: a different family is still drift, so 9.10's silence is
# "same model, different window" and not "this guard stopped comparing".
OUT_910D=$(printf '{"model":{"id":"claude-opus-4-5[1m]"}}' | CLAUDE_PROJECT_DIR="$SB_910" bash "$SL" 2>/dev/null)
assert_contains "9.10d a DIFFERENT model is still drift even when it carries [1m]" "!sess" "$OUT_910D"
assert_eq "9.10d ...and the record names the live id verbatim, suffix included" \
    "claude-opus-4-5[1m]" "$(jq -r '.live' "$DRIFT_910")"

# 9.11 META — put the literal string equality back and prove 9.10 goes red.
MUT911_DIR=$(mktemp -d "$TESTROOT/sessmut2.XXXXXX")
MUT911="$MUT911_DIR/statusline.sh"
awk '/^    if session_model_matches "\$expected" "\$live"; then$/ { print "    if [ \"$live\" = \"$expected\" ]; then"; found=1; next } { print }
     END { if (!found) exit 7 }' "$SL" > "$MUT911"
AWK_RC_911=$?
assert_eq "9.11-META non-vacuity: the identity-comparison revert landed" "0" "$AWK_RC_911"
assert_eq "9.11-META non-vacuity: the mutant differs from the shipped statusline" \
    "differs" "$(cmp -s "$MUT911" "$SL" && echo same || echo differs)"
assert_eq "9.11-META non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT911" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_911=$(sl_sandbox_orch "claude-fable-5")
rm -f "$SB_911/.claude/scripts/statusline.sh"
cp "$MUT911" "$SB_911/.claude/scripts/statusline.sh"
chmod +x "$SB_911/.claude/scripts/statusline.sh"
OUT_911=$(printf '{"model":{"id":"claude-fable-5[1m]"}}' \
    | CLAUDE_PROJECT_DIR="$SB_911" bash "$SB_911/.claude/scripts/statusline.sh" 2>/dev/null)
assert_contains "9.11-META: with literal equality the 1M variant is drift again (9.10 would fail)" \
    "!sess" "$OUT_911"
assert_contains "9.11-META: ...and the fix line tells the operator to shrink their context window" \
    "/model claude-fable-5" "$(cat "$SB_911/.claude/.qa-tracking/session-model-drift.json")"
# Discriminator: the mutant is not broken wholesale — an exact match still
# clears, so what regressed is specifically the variant rule.
printf '{"model":{"id":"claude-fable-5"}}' \
    | CLAUDE_PROJECT_DIR="$SB_911" bash "$SB_911/.claude/scripts/statusline.sh" >/dev/null 2>&1
assert_eq "9.11-META discriminator: the mutant still clears on an EXACT match" "gone" \
    "$([ -f "$SB_911/.claude/.qa-tracking/session-model-drift.json" ] && echo present || echo gone)"
SB_911C=$(sl_sandbox_orch "claude-fable-5")
assert_not_contains "9.11-META restore control: the SHIPPED statusline renders no !sess for [1m]" \
    "!sess" "$(printf '{"model":{"id":"claude-fable-5[1m]"}}' | CLAUDE_PROJECT_DIR="$SB_911C" bash "$SL" 2>/dev/null)"

# ===========================================================================
echo ""
echo "=== Section 10: SessionStart Warnings 8/9/10 (the operator surface) ==="
#
# WHY THIS SECTION EXISTS (QA R1-F1). The three D0 notices shipped as 63 lines
# of session-start.sh with NO assertion in any tier and no UNPAIRED row. They
# were correct — QA drove the hook by hand and all three fired — and that is
# exactly the problem: nothing would have noticed them going quiet.
#
# WARNING 10 IS THE ONE THAT MATTERS MOST. `.claude/model-roles` is manifest
# class `operator`, so an install whose copy was edited gets the v5 defaults as
# a `.new` sidecar and keeps its old key set; every missing key fails OPEN to
# `top`. Warning 10 is the ONLY thing anywhere that says so, and its regression
# mode is SILENCE — the same silence it exists to break. A guard like that
# cannot be left resting on the fact that it worked the day it was written.
#
# Every leg here RUNS session-start.sh and parses the envelope it emitted.

SS="$PROJECT_DIR/.claude/scripts/session-start.sh"
SS_RC_FILE="$TESTROOT/ss-rc"

# ss_sandbox — a sandbox that can run session-start.sh HERMETICALLY.
#
# The hook resolves its sibling helpers from its OWN path
# (`dirname "${BASH_SOURCE[0]}"`), so it is symlinked INTO the sandbox and
# invoked from there. SS_SCRIPT_DIR is then the sandbox's scripts dir, which
# carries no qa-gate.sh and no beads-ledger.sh — so the gate-baseline capture
# and the ledger probe skip themselves instead of running against this repo.
# There is no .beads/ either, so every bd call is gated off. What is left is
# the model-select apply and the warning block, which is what is under test.
ss_sandbox() {
    local d
    d=$(ms_sandbox_families)
    ln -sf "$SS" "$d/.claude/scripts/session-start.sh"
    printf '%s' "$d"
}

# ss_context <sandbox> — run the hook the way the runtime does (no stdin) and
# print the additionalContext it emitted.
#
# The exit status goes to a FILE, not a variable: every caller invokes this
# through `$(...)`, and a variable assigned inside command substitution is
# invisible to the parent. Same subshell constraint model-select.sh's
# ROLE_FALLBACK_FILE works around, and it bit this file's first draft.
ss_context() {
    local out rc
    out=$(CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/scripts/session-start.sh" </dev/null 2>/dev/null)
    rc=$?
    printf '%s' "$rc" > "$SS_RC_FILE"
    printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // "<NO ENVELOPE>"' 2>/dev/null
}

# ss_v4_config <sandbox> — the correction-14 shape: a v4-era model-roles that
# an upgrade could not overwrite. Three keys, so three are missing, and the two
# design lanes both fall open to `top` (hence a collapse too).
ss_v4_config() {
    printf 'orchestrator=top\nimplementer=opus-class\nreviewer=top\n' > "$1/.claude/model-roles"
}

# 10.1 POSITIVE — all three notices, over state produced by the SHIPPED
# resolver and the SHIPPED statusline rather than hand-written artifacts.
SB_101=$(ss_sandbox)
ss_v4_config "$SB_101"
CLAUDE_PROJECT_DIR="$SB_101" bash "$MS" apply --quiet >/dev/null 2>&1
printf '{"model":{"id":"claude-opus-5-0"}}' | CLAUDE_PROJECT_DIR="$SB_101" bash "$SL" >/dev/null 2>&1
CTX_101=$(ss_context "$SB_101")
assert_eq "10.1 the hook exits 0 (the notices are never blocking)" "0" "$(cat "$SS_RC_FILE")"
assert_contains "10.1 the envelope still carries its workflow context" "<workflow_engine" "$CTX_101"
assert_contains "10.1 Warning 8 reports the session-model drift" "session-model drift" "$CTX_101"
assert_contains "10.1 ...naming the id the session last rendered on" "claude-opus-5-0" "$CTX_101"
assert_contains "10.1 ...and the fix verbatim" "/model claude-fable-9" "$CTX_101"
assert_contains "10.1 Warning 9 reports the design identity collapse" "design identity collapse" "$CTX_101"
assert_contains "10.1 ...with the Codex clearance" "install Codex" "$CTX_101"
assert_contains "10.1 ...and the config clearance" "design_reviewer=<family>-class" "$CTX_101"
assert_contains "10.1 Warning 10 names every key this install lacks" \
    "missing key(s): designer, design_reviewer, implementer_class_high" "$CTX_101"
assert_contains "10.1 ...and points at the sidecar an edited copy would have" \
    ".claude/model-roles.new" "$CTX_101"

# 10.2 NEGATIVE — a STALE drift record. Its `expected` no longer matches the
# artifact (the resolver adopted a new model since it was written), so
# reporting it would send the operator to a /model command for a model the
# workflow no longer wants. Warnings 9 and 10 in the same run are the
# discriminator: this is Warning 8 declining, not the block going dark.
SB_102=$(ss_sandbox)
ss_v4_config "$SB_102"
CLAUDE_PROJECT_DIR="$SB_102" bash "$MS" apply --quiet >/dev/null 2>&1
printf '{"expected":"claude-adopted-last-week","live":"claude-opus-5-0","observed_at":"2026-01-01T00:00:00Z","fix":"/model claude-adopted-last-week"}' \
    > "$SB_102/.claude/.qa-tracking/session-model-drift.json"
CTX_102=$(ss_context "$SB_102")
assert_not_contains "10.2 a stale drift record is NOT reported" "session-model drift" "$CTX_102"
assert_not_contains "10.2 ...so its wrong fix line never reaches the operator" \
    "claude-adopted-last-week" "$CTX_102"
assert_contains "10.2 discriminator: Warning 9 still fires in the same run" \
    "design identity collapse" "$CTX_102"
assert_contains "10.2 discriminator: ...and Warning 10 with it" "is missing key(s)" "$CTX_102"

# 10.3 NEGATIVE — a fully v5 config whose design lanes resolve apart: no
# collapse, no missing keys, no drift record. None of the three may fire.
SB_103=$(ss_sandbox)
printf 'designer=top\ndesign_reviewer=opus-class\norchestrator=top\nimplementer=sonnet-class\nreviewer=top\nimplementer_class_high=opus-class\n' \
    > "$SB_103/.claude/model-roles"
CLAUDE_PROJECT_DIR="$SB_103" bash "$MS" apply --quiet >/dev/null 2>&1
CTX_103=$(ss_context "$SB_103")
assert_eq "10.3 the hook exits 0" "0" "$(cat "$SS_RC_FILE")"
assert_contains "10.3 ...and emitted a real envelope, so the silence is an answer" \
    "<workflow_engine" "$CTX_103"
assert_not_contains "10.3 no collapse line when the design lanes resolve apart" \
    "design identity collapse" "$CTX_103"
assert_not_contains "10.3 no missing-keys line when the config carries every key" \
    "is missing key(s)" "$CTX_103"
assert_not_contains "10.3 no drift line when no comparison ever recorded one" \
    "session-model drift" "$CTX_103"

# 10.4 NEGATIVE — no artifact at all (the resolver never ran; a v4 install
# mid-upgrade, or a target whose model-select.sh is absent). A drift record
# alone must not produce a warning: Warning 8 re-validates against the
# artifact, and with no artifact there is nothing to validate against.
SB_104=$(ss_sandbox)
ss_v4_config "$SB_104"
rm -f "$SB_104/.claude/scripts/model-select.sh"
rm -f "$SB_104/.claude/.qa-tracking/model-roles-resolved.json"
printf '{"expected":"claude-fable-9","live":"claude-opus-5-0","observed_at":"2026-01-01T00:00:00Z","fix":"/model claude-fable-9"}' \
    > "$SB_104/.claude/.qa-tracking/session-model-drift.json"
CTX_104=$(ss_context "$SB_104")
assert_eq "10.4 the hook exits 0 with no artifact" "0" "$(cat "$SS_RC_FILE")"
assert_contains "10.4 ...and still carries its workflow context" "<workflow_engine" "$CTX_104"
assert_not_contains "10.4 no drift line without an artifact to re-validate against" \
    "session-model drift" "$CTX_104"
assert_not_contains "10.4 no collapse line" "design identity collapse" "$CTX_104"
assert_not_contains "10.4 no missing-keys line" "is missing key(s)" "$CTX_104"

# --- METAs -----------------------------------------------------------------
#
# One mutant per warning, each disabling exactly ONE emission by replacing its
# guard with `if false; then` — the block stays structurally intact, so the
# mutant fails for its own reason and nothing else moves. Every mutation is
# anchored on the EXACT shipped line and awk exits 7 when it is not found, so a
# strip that matched nothing cannot pass as a control.
MUT10_DIR=$(mktemp -d "$TESTROOT/ssmut.XXXXXX")

# ss_mutant <exact-source-line> <outfile> — see above. Returns awk's status.
ss_mutant() {
    awk -v want="$1" '$0 == want { print "        if false; then"; found=1; next } { print }
         END { if (!found) exit 7 }' "$SS" > "$2"
}

# ss_install_mutant <sandbox> <mutant> — never cp over the symlink.
ss_install_mutant() {
    rm -f "$1/.claude/scripts/session-start.sh"
    cp "$2" "$1/.claude/scripts/session-start.sh"
    chmod +x "$1/.claude/scripts/session-start.sh"
}

# ss_positive_sandbox — 10.1's exact state: all three notices due.
ss_positive_sandbox() {
    local d
    d=$(ss_sandbox)
    ss_v4_config "$d"
    CLAUDE_PROJECT_DIR="$d" bash "$MS" apply --quiet >/dev/null 2>&1
    printf '{"model":{"id":"claude-opus-5-0"}}' | CLAUDE_PROJECT_DIR="$d" bash "$SL" >/dev/null 2>&1
    printf '%s' "$d"
}

# Each anchor below is a LITERAL LINE OF session-start.sh's SOURCE TEXT to
# match, not a variable to expand — single quotes are required, and the exact
# leading indentation is part of the match (`$0 == want`). Same convention as
# the 6.3 anchor above; the disable sits on each call because a directive
# binds to the NEXT COMMAND, not to the rest of the block.

# 10.5 META — Warning 10, the correction-14 surface.
MUT_W10="$MUT10_DIR/ss-w10.sh"
# shellcheck disable=SC2016
ss_mutant '        if [ -n "$SS_MISSING_KEYS" ]; then' "$MUT_W10"
AWK_RC_105=$?
assert_eq "10.5-META non-vacuity: the Warning 10 emission strip landed" "0" "$AWK_RC_105"
assert_eq "10.5-META non-vacuity: the mutant differs from the shipped hook" \
    "differs" "$(cmp -s "$MUT_W10" "$SS" && echo same || echo differs)"
assert_eq "10.5-META non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT_W10" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_105=$(ss_positive_sandbox)
ss_install_mutant "$SB_105" "$MUT_W10"
CTX_105=$(ss_context "$SB_105")
assert_eq "10.5-META: the mutant still EXITS 0 — the regression is silent, which is the point" \
    "0" "$(cat "$SS_RC_FILE")"
assert_not_contains "10.5-META: the missing-keys line is GONE (10.1 would fail)" \
    "is missing key(s)" "$CTX_105"
assert_contains "10.5-META discriminator: Warning 8 still fires from the same mutant" \
    "session-model drift" "$CTX_105"
assert_contains "10.5-META discriminator: ...and Warning 9 too" \
    "design identity collapse" "$CTX_105"
SB_105C=$(ss_positive_sandbox)
assert_contains "10.5-META restore control: the SHIPPED hook emits the missing-keys line" \
    "is missing key(s)" "$(ss_context "$SB_105C")"

# 10.6 META — Warning 8, the session-model guard's warn half.
MUT_W8="$MUT10_DIR/ss-w8.sh"
# shellcheck disable=SC2016
ss_mutant '        if [ -n "$SS_DRIFT_EXPECTED" ] && [ "$SS_DRIFT_EXPECTED" = "$SS_ORCH_NOW" ]; then' "$MUT_W8"
AWK_RC_106=$?
assert_eq "10.6-META non-vacuity: the Warning 8 emission strip landed" "0" "$AWK_RC_106"
assert_eq "10.6-META non-vacuity: the mutant differs from the shipped hook" \
    "differs" "$(cmp -s "$MUT_W8" "$SS" && echo same || echo differs)"
assert_eq "10.6-META non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT_W8" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_106=$(ss_positive_sandbox)
ss_install_mutant "$SB_106" "$MUT_W8"
CTX_106=$(ss_context "$SB_106")
assert_not_contains "10.6-META: the drift line is GONE (10.1 would fail)" \
    "session-model drift" "$CTX_106"
assert_contains "10.6-META discriminator: Warning 9 still fires" \
    "design identity collapse" "$CTX_106"
assert_contains "10.6-META discriminator: ...and Warning 10 too" "is missing key(s)" "$CTX_106"
SB_106C=$(ss_positive_sandbox)
assert_contains "10.6-META restore control: the SHIPPED hook emits the drift line" \
    "session-model drift" "$(ss_context "$SB_106C")"

# 10.7 META — Warning 9, the identity-collapse notice.
MUT_W9="$MUT10_DIR/ss-w9.sh"
# shellcheck disable=SC2016
ss_mutant '        if [ "$(jq -r '"'"'.identity_collapse // false'"'"' "$SS_ROLES_ARTIFACT" 2>/dev/null || echo false)" = "true" ]; then' "$MUT_W9"
AWK_RC_107=$?
assert_eq "10.7-META non-vacuity: the Warning 9 emission strip landed" "0" "$AWK_RC_107"
assert_eq "10.7-META non-vacuity: the mutant differs from the shipped hook" \
    "differs" "$(cmp -s "$MUT_W9" "$SS" && echo same || echo differs)"
assert_eq "10.7-META non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT_W9" >/dev/null 2>&1 && echo 0 || echo 1)"
SB_107=$(ss_positive_sandbox)
ss_install_mutant "$SB_107" "$MUT_W9"
CTX_107=$(ss_context "$SB_107")
assert_not_contains "10.7-META: the collapse line is GONE (10.1 would fail)" \
    "design identity collapse" "$CTX_107"
assert_contains "10.7-META discriminator: Warning 8 still fires" "session-model drift" "$CTX_107"
assert_contains "10.7-META discriminator: ...and Warning 10 too" "is missing key(s)" "$CTX_107"
SB_107C=$(ss_positive_sandbox)
assert_contains "10.7-META restore control: the SHIPPED hook emits the collapse line" \
    "design identity collapse" "$(ss_context "$SB_107C")"

# ===========================================================================
echo ""
echo "=== Section 12: apply --check is DETECT-AND-WARN, never a write (claude-workflow-plugin-j7kk, B2, R4-F1 ruling) ==="
#
# THE DEFECT (filed, dated 2026-08-14T04:58:10): the OLD unconditional
# session-start.sh -> `model-select.sh apply` call rewrote four TRACKED files
# (three agent .md + settings.json, one shared mtime) mid an OPEN, UNRELATED
# change set, with no files_changed list naming them — an approval covering
# the rest of that change set would have attested to bytes no specialist
# wrote and no reviewer read. R4-F1's ruling — already applied elsewhere in
# this repo (beads-ledger.sh, session-start.sh's own ledger-divergence check,
# session-end.sh) — is DETECT-AND-WARN, with an explicit apply step still
# reachable. --check is the new flag; session-start.sh's automatic call now
# passes it (a session-start.sh change, not exercised here — this file's
# subject is model-select.sh's own contract).
#
# Placed BEFORE Section 11 on purpose: Section 11 takes its "production
# store untouched across this ENTIRE file's run" snapshot at the bottom, so
# 12.3's write-path call (the one assertion below that reaches _apply_role,
# same as every other write-path assertion elsewhere in this file) has to
# run before that snapshot to be covered by it.

# 12.1: a config that would resolve EVERY role to a DIFFERENT pin than what
# the agent files currently carry — the same base/orch shape as 6.1
# (base=orch=claude-base-0, so every lane drifts against the resolved
# claude-fable-9) but read through --check instead of driving a write.
SB_121=$(ms_sandbox_with_listing "claude-base-0" "claude-base-0")
BEFORE_121_DESIGNER=$(agent_pin_of "$SB_121/.claude/agents/designer.md")
BEFORE_121_ORCH=$(agent_pin_of "$SB_121/.claude/agents/orchestrator.md")
BEFORE_121_SETTINGS=$(cat "$SB_121/.claude/settings.json" 2>/dev/null || echo "<absent>")
RES_121=$(CLAUDE_PROJECT_DIR="$SB_121" bash "$MS" apply --quiet --check 2>&1 >/dev/null | grep '^model-select:' | tail -1)
assert_eq "12.1 --check does NOT rewrite the drifted designer lane" \
    "$BEFORE_121_DESIGNER" "$(agent_pin_of "$SB_121/.claude/agents/designer.md")"
assert_eq "12.1 --check does NOT rewrite the drifted orchestrator lane either" \
    "$BEFORE_121_ORCH" "$(agent_pin_of "$SB_121/.claude/agents/orchestrator.md")"
assert_eq "12.1 --check does NOT touch settings.json (the OTHER tracked file the filed defect named)" \
    "$BEFORE_121_SETTINGS" "$(cat "$SB_121/.claude/settings.json" 2>/dev/null || echo "<absent>")"
assert_contains "12.1 the ONE surfaced stderr line (session-start.sh's tail -1 'most recent line' collapse target) names the drift" \
    "resolver drift" "$RES_121"
assert_contains "12.1 ...naming the specific role, current pin and resolved pin" \
    "designer: agent file has 'claude-base-0', config resolves 'claude-fable-9'" "$RES_121"
assert_contains "12.1 ...and the exact explicit command that applies it" \
    "/workflow-model --role designer claude-fable-9" "$RES_121"
assert_contains "12.1 ...and states plainly that nothing auto-applied (R4-F1)" \
    "NOTHING auto-applied" "$RES_121"

# 12.2: NO drift (pins already match the resolved config) — --check must say
# so plainly, distinctly from "N switched", so an operator cannot mistake a
# check-only run for one that resolved anything.
SB_122=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
RES_122=$(CLAUDE_PROJECT_DIR="$SB_122" bash "$MS" apply --quiet --check 2>&1 >/dev/null | grep '^model-select:' | tail -1)
assert_not_contains "12.2 no drift: the summary never claims 'resolver drift'" \
    "resolver drift" "$RES_122"
assert_contains "12.2 ...and says so explicitly (0 written)" \
    "0 written" "$RES_122"
assert_eq "12.2 ...and the designer lane is genuinely untouched" \
    "claude-fable-9" "$(agent_pin_of "$SB_122/.claude/agents/designer.md")"

# 12.3 RESTORE CONTROL / regression guard: the IDENTICAL drifted shape as
# 12.1, but `apply` WITHOUT --check — still WRITES exactly as every other
# section in this file already exercises. This is what proves --check is an
# ADDITIVE flag on an unchanged default, not a behaviour change to `apply`
# itself (which model-roles.test.sh's other ~250 assertions depend on).
SB_123=$(ms_sandbox_with_listing "claude-base-0" "claude-base-0")
CLAUDE_PROJECT_DIR="$SB_123" bash "$MS" apply --quiet >/dev/null 2>&1
assert_eq "12.3 RESTORE CONTROL: apply WITHOUT --check still writes the designer lane (default behaviour is unchanged)" \
    "claude-fable-9" "$(agent_pin_of "$SB_123/.claude/agents/designer.md")"

# ---------------------------------------------------------------------------
# 12M. META — neutralise the CHECK_ONLY gate at BOTH its call sites (the
# per-role compare-vs-write branch AND the reporting branch share the exact
# text `if [ "$CHECK_ONLY" -eq 1 ]; then`, so one substitution mutates both).
# The R4-F1 regression this guards against: --check would then ALSO write,
# silently defeating the whole reason the flag exists.
# ---------------------------------------------------------------------------
MUT12_DIR=$(mktemp -d "$TESTROOT/checkmut.XXXXXX")
MUT12="$MUT12_DIR/model-select.sh"
# shellcheck disable=SC2016
sed 's/if \[ "\$CHECK_ONLY" -eq 1 \]; then$/if [ "$CHECK_ONLY" -eq 9 ]; then/' "$MS" > "$MUT12"
# shellcheck disable=SC2016  # single-quoted on purpose: matching LITERAL
# shell-source text in the mutant file, not expanding this script's own vars.
assert_eq "12M.0a non-vacuity: BOTH call sites were found and neutralised" \
    "2" "$(grep -c 'if \[ "\$CHECK_ONLY" -eq 9 \]; then' "$MUT12" | tr -d '[:space:]')"
# shellcheck disable=SC2016  # same reason as above.
assert_eq "12M.0b non-vacuity: the ORIGINAL comparison is gone from both" \
    "0" "$(grep -c 'if \[ "\$CHECK_ONLY" -eq 1 \]; then' "$MUT12" | tr -d '[:space:]')"
assert_eq "12M.1 non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT12" "$MS" && echo same || echo differs)"
assert_eq "12M.2 non-vacuity: the mutant still parses" \
    "0" "$(bash -n "$MUT12" >/dev/null 2>&1 && echo 0 || echo 1)"

SB_12M=$(ms_sandbox_with_listing "claude-base-0" "claude-base-0")
rm -f "$SB_12M/.claude/scripts/model-select.sh"   # never cp over the symlink
cp "$MUT12" "$SB_12M/.claude/scripts/model-select.sh"
chmod +x "$SB_12M/.claude/scripts/model-select.sh"
# workflow-model-apply.sh only touches settings.json for the implementer (or
# `all`) role, and neither ms_sandbox_with_listing nor new_sandbox creates one
# by default (they seed only .claude/agents/*.md) — seed the minimal shape
# `_apply_role`'s helper reads/writes (`.env.CLAUDE_LATEST_OPUS`) so this leg
# can observe that write path too, not just the agent-file one.
printf '{"env":{}}' > "$SB_12M/.claude/settings.json"
CLAUDE_PROJECT_DIR="$SB_12M" bash "$SB_12M/.claude/scripts/model-select.sh" apply --quiet --check >/dev/null 2>&1
assert_eq "12M.3 SPECIFIC MISBEHAVIOUR: with the gate neutralised, --check WRITES the designer lane anyway (12.1's own assertion would FAIL on this mutant)" \
    "claude-fable-9" "$(agent_pin_of "$SB_12M/.claude/agents/designer.md")"
assert_eq "12M.4 SPECIFIC: ...and settings.json too (the second tracked file the filed defect named; implementer's representative is backend.md, also seeded at claude-base-0 -> claude-fable-9 by ms_sandbox_with_listing)" \
    "yes" "$(jq -e '.env.CLAUDE_LATEST_OPUS == "claude-fable-9"' "$SB_12M/.claude/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
# RESTORE CONTROL: the identical scenario, shipped script, --check genuinely
# writes nothing to EITHER tracked file (12.1 above re-asserted against a
# freshly-built sandbox so the control is not a stale reading).
SB_12MC=$(ms_sandbox_with_listing "claude-base-0" "claude-base-0")
printf '{"env":{}}' > "$SB_12MC/.claude/settings.json"
CLAUDE_PROJECT_DIR="$SB_12MC" bash "$MS" apply --quiet --check >/dev/null 2>&1
assert_eq "12M.5 RESTORE CONTROL: the SHIPPED script, --check, the identical scenario, writes NOTHING to the designer lane" \
    "claude-base-0" "$(agent_pin_of "$SB_12MC/.claude/agents/designer.md")"
assert_eq "12M.6 RESTORE CONTROL: ...nor to settings.json" \
    "no" "$(jq -e '.env.CLAUDE_LATEST_OPUS == "claude-fable-9"' "$SB_12MC/.claude/settings.json" >/dev/null 2>&1 && echo yes || echo no)"

# ===========================================================================
echo ""
echo "=== Section 13: a ranking-file READ FAILURE must not masquerade as \"no ranking file\" (claude-workflow-plugin-i8cx wave 2) ==="
#
# THE HAZARD. load_ranking_raw's sed stage used to be the LEFT side of a raw
# pipe (`sed ... | grep -v '^$'`), and load_exclusions/load_tiers piped THAT
# straight into another filter (`awk` / `grep -v '^!'`). Without pipefail the
# pipe's exit status is whichever of those LAST stages happened to exit —
# both routinely exit 0 (or a 1 that already means "legitimately no lines",
# not "upstream broke") regardless of whether sed actually ran. pick_best
# then fed the result into `jq -R -s`, which succeeds on EMPTY input too
# (`[]`), so a masked sed failure on an EXISTING ranking file was silently
# indistinguishable from "no ranking file configured": class_for() puts
# every candidate in the top class and excluded() drops nothing — the en9
# defect (recency-only ordering) reachable through a masked pipeline instead
# of a masked jq. MEASURED, and the reason scoped pipefail alone would not
# have been enough for load_tiers's `grep -v` tail:
#   ( set -o pipefail; false | grep -v x ); echo $?      # -> 1
#   ( set -o pipefail; printf 'a\n' | grep -v x ); echo $?  # -> 1 (from the a
#                                                              line NOT matching)
# both a real upstream failure and a legitimate zero-survivors read report the
# SAME code once the last stage has its own no-match convention — so the fix
# captures load_ranking_raw's own rc directly (an unpiped, solo `sed`) instead
# of inferring it from a downstream filter.

# rank_sandbox — a real two-tier exclusion+tier ranking file (haiku excluded,
# fable > mythos) and a fresh cache with one candidate per family, dated so
# recency ALONE would pick the WRONG one (the newest is the excluded haiku) —
# that is what proves the ranking file is actually being read, not merely
# present on disk.
rank_sandbox() {
    local d
    d=$(new_sandbox)
    printf '!claude-haiku\nclaude-fable\nclaude-mythos\n' > "$d/.claude/model-ranking"
    cat > "$d/.claude/.qa-tracking/model-select-cache.json" <<JSON
{"timestamp": $(date +%s), "models": [
  {"id":"claude-fable-2","max_input_tokens":200000,"created_at":"2026-06-01T00:00:00Z"},
  {"id":"claude-mythos-3","max_input_tokens":200000,"created_at":"2026-07-01T00:00:00Z"},
  {"id":"claude-haiku-9","max_input_tokens":200000,"created_at":"2026-08-01T00:00:00Z"}]}
JSON
    printf '%s' "$d"
}

# resolve_id <sandbox> [path-prefix] — the picked id from `resolve`.
resolve_id() {
    CLAUDE_PROJECT_DIR="$1" PATH="${2:-}${2:+:}$PATH" bash "$MS" resolve 2>/dev/null \
        | awk -F'\t' '{print $1}'
}
# resolve_warn <sandbox> [path-prefix] — resolve's stderr only.
#
# shellcheck disable=SC2069  # intentional: send stderr to THIS function's own
# stdout (its caller's $(...) capture) and discard resolve's real stdout to
# /dev/null. shellcheck's "2>&1 must be last" heuristic assumes the goal is
# combining both streams into one FILE; here the goal is routing them to two
# DIFFERENT places, which is what this order does correctly. The identical
# order is used inline (not behind a function) at every other `2>&1
# >/dev/null` call site in this file and shellcheck does not flag those,
# because it can see straight through to their enclosing $(...) — it cannot
# see through a function-call boundary, which is the only difference here.
resolve_warn() {
    CLAUDE_PROJECT_DIR="$1" PATH="${2:-}${2:+:}$PATH" bash "$MS" resolve 2>&1 >/dev/null
}

# 13.1 CONTROL — healthy ranking file, no fault injection: tier beats
# recency (fable, not the newer-but-lower-tier mythos) and the excluded
# family (haiku, the newest of all three) never wins. Establishes the
# fixture is sound before any fault is injected.
SB_131=$(rank_sandbox)
assert_eq "13.1 control: tier + exclusion respected, fable wins over newer mythos/haiku" \
    "claude-fable-2" "$(resolve_id "$SB_131")"

# 13.2 MUTATION — fault injection against the SHIPPED script (not a source
# mutation: the guard under test is a runtime rc check, so only a runtime
# failure can trip it). A `sed` on PATH ahead of the real one that behaves
# like a genuine read failure: nothing on stdout, non-zero exit — the SAME
# ranking file and cache are left untouched underneath it.
FAULT_BIN_13=$(mktemp -d "$TESTROOT/fault-sed-13.XXXXXX")
FAULT_LOG_13="$TESTROOT/fault-sed-13.log"
: > "$FAULT_LOG_13"
cat > "$FAULT_BIN_13/sed" <<STUB
#!/bin/bash
printf 'invoked\n' >> "$FAULT_LOG_13"
exit 9
STUB
chmod +x "$FAULT_BIN_13/sed"

SB_132=$(rank_sandbox)
PICK_132=$(resolve_id "$SB_132" "$FAULT_BIN_13")
WARN_132=$(resolve_warn "$SB_132" "$FAULT_BIN_13")
assert_eq "13.2 non-vacuity: the fault-injected sed was actually invoked" \
    "yes" "$([ -s "$FAULT_LOG_13" ] && echo yes || echo no)"
# SPECIFIC misbehaviour: the masked read is not merely cosmetic. It reverts
# to recency-only ordering, so the EXCLUDED, newest-of-three haiku model
# wins over the correctly-ranked fable — same as if no ranking file existed.
assert_eq "13.2 SPECIFIC: read failure degrades to recency-only (excluded/newest haiku wins, matching \"no ranking file\")" \
    "claude-haiku-9" "$PICK_132"
# ...but is fail-open, per spec 0.3 principle 1 (never block selection): a
# candidate IS still resolved, not an empty string or a crash.
assert_eq "13.2 fail-open: a candidate is still resolved (not blocked)" \
    "yes" "$([ -n "$PICK_132" ] && echo yes || echo no)"
# THE FIX ITSELF: unlike the pre-i8cx-wave-2 shape, the failure is now named
# on stderr rather than silent — twice, once per read (exclusions, tiers).
assert_contains "13.2 THE FIX: names the exclusions read failure" \
    "could not read" "$WARN_132"
assert_contains "13.2 THE FIX: ...and specifically calls out exclusions" \
    "for exclusions" "$WARN_132"
assert_contains "13.2 THE FIX: ...and specifically calls out capability tiers" \
    "for capability tiers" "$WARN_132"
# The warning must say this is a READ FAILURE, not "no ranking file" — an
# operator debugging a wrong pin needs to know these are different problems.
assert_contains "13.2 THE FIX: distinguishes read-failed from missing/empty" \
    "not a missing/empty file" "$WARN_132"

# 13.3 RESTORE CONTROL — same sandbox, fault-injected sed removed: tier
# ranking resumes and the warning is gone.
PICK_133=$(resolve_id "$SB_132")
WARN_133=$(resolve_warn "$SB_132")
assert_eq "13.3 RESTORE CONTROL: shim removed, same sandbox, fable wins again" \
    "claude-fable-2" "$PICK_133"
assert_not_contains "13.3 RESTORE CONTROL: no 'could not read' warning on the healthy path" \
    "could not read" "$WARN_133"

# 13.4 A LEGITIMATE empty ranking file (comments/blank only — an operator who
# has not configured anything yet) must NOT be conflated with a read
# failure: no warning, matching pre-i8cx behaviour exactly.
SB_134=$(new_sandbox)
printf '# nothing configured yet\n\n' > "$SB_134/.claude/model-ranking"
cat > "$SB_134/.claude/.qa-tracking/model-select-cache.json" <<JSON
{"timestamp": $(date +%s), "models": [
  {"id":"claude-fable-2","max_input_tokens":200000,"created_at":"2026-06-01T00:00:00Z"}]}
JSON
WARN_134=$(resolve_warn "$SB_134")
assert_not_contains "13.4 legitimate-empty (comments-only) ranking file does not warn 'could not read'" \
    "could not read" "$WARN_134"
assert_eq "13.4 legitimate-empty ranking file still resolves the sole candidate" \
    "claude-fable-2" "$(resolve_id "$SB_134")"

# 13.5-META — strip the rc-guard from a COPY of the shipped script and prove
# the ORIGINAL bug returns: the same fault injection is masked SILENTLY
# again. A permanent regression guard against the fix being reverted or
# "simplified" back into a bare pipe.
#
# NON-VACUITY: awk exits 7 unless EXACTLY one copy of the guard line is
# found — a strip that matched zero or several lines would produce a mutant
# that is not the intended one, or not one at all.
MUT13_DIR=$(mktemp -d "$TESTROOT/rankmut.XXXXXX")
MUT13="$MUT13_DIR/model-select.sh"
awk '/^    \[ "\$rc" -eq 0 \] \|\| return 2$/ { found++; next } { print }
     END { if (found != 1) exit 7 }' "$MS" > "$MUT13"
AWK_RC_135=$?
assert_eq "13.5-META non-vacuity: exactly one rc-guard line stripped from load_ranking_raw" "0" "$AWK_RC_135"
assert_eq "13.5-META non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT13" "$MS" && echo same || echo differs)"
assert_eq "13.5-META non-vacuity: the mutant still parses (fails for its own reason, not a syntax error)" \
    "0" "$(bash -n "$MUT13" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT13"

SB_135=$(rank_sandbox)
MUT_PICK_135=$(CLAUDE_PROJECT_DIR="$SB_135" PATH="$FAULT_BIN_13:$PATH" bash "$MUT13" resolve 2>/dev/null \
    | awk -F'\t' '{print $1}')
MUT_WARN_135=$(CLAUDE_PROJECT_DIR="$SB_135" PATH="$FAULT_BIN_13:$PATH" bash "$MUT13" resolve 2>&1 >/dev/null)
assert_eq "13.5-META SPECIFIC: with the guard stripped, the same fault injection is masked again (haiku wins, the original bug)" \
    "claude-haiku-9" "$MUT_PICK_135"
assert_not_contains "13.5-META SPECIFIC: ...with NO warning at all -- the exact silent failure this section exists to close" \
    "could not read" "$MUT_WARN_135"

# ===========================================================================
echo ""
echo "=== Section 14: check-parity is a hard CONFIG/FILE agreement gate (claude-workflow-plugin-a13r) ==="
#
# THE DEFECT THIS GUARDS: claude-workflow-plugin-fkm.10 closed on a
# .claude/model-roles edit (orchestrator: top -> opus-class) whose EFFECT
# never happened -- the agent file's frontmatter pin was never rewritten to
# match, and nothing failed. `apply --check` (Section 12) already computes
# the identical comparison but is deliberately advisory: it ALWAYS exits 0
# (SessionStart must never block on an enumeration hiccup -- see that
# flag's own header). check-parity reuses the SAME comparison primitives
# (role_strategy, pick_for_role) but makes the verdict a real exit-code
# contract, so THIS is the subcommand a human/CI/workflow-doctor can
# actually assert on.
#
# 14.1 POSITIVE, 14.2 NEGATIVE (single-role drift, landing-proven before the
# check ever runs), 14.3 RESTORE CONTROL (apply fixes it, re-check agrees),
# 14.4 UNVERIFIABLE (no cache -- never a false pass), 14.5 an ACTIVE
# per-unit escalation on `implementer` must not read as drift, 14.6 a role
# missing its agent file is excluded rather than reported as drift. 14M is
# the META: a copy of the shipped script with the disagreement comparison
# neutralised WOULD wrongly pass 14.2's drifted fixture -- the exact failure
# mode this section exists to rule out -- with a restore control proving the
# SHIPPED script still fails it correctly.
#
# ROUND 2 (independent review, sol-codex): the comparison this section
# exercises now checks EVERY discovered agent file per role, not one
# representative (14.10), the cache's `.models` shape is validated before
# it is trusted (14.7), an undeclared role's evaluation is distinguished in
# the wording from a declared one (14.8), and a file that exists but cannot
# be read is folded into DISAGREEMENT rather than silently excluded (14.9).
# `checked` therefore now counts FILES, not roles: 14.1's fixture (every
# role class fully populated: 1 designer + 1 design-reviewer + 1
# orchestrator + 3 implementer [backend/frontend/devops] + 3 reviewer
# [qa/grader/judge] = 9) reports "9 file(s) checked", and 14.5/14.6 below
# are updated to the file counts their (still role-level) exclusions now
# produce.
#
# ROUND 3 (independent review, sol-codex, third pass): 14.5's
# assert_not_contains was VACUOUS -- "implementer: agent file" can never be
# emitted (the format is always "$role/$agent:", and implementer's members
# are backend/frontend/devops, never bare "implementer") -- fixed to
# "implementer/backend: agent file", and 14.5M added to prove the corrected
# string actually discriminates (item 1). --print-role-map's own exit
# status and map completeness are now load-bearing rather than discarded
# (`|| true`): a nonzero exit or a clean exit with a whole role missing
# both fail the ENTIRE run closed (UNVERIFIABLE), never trusting whatever
# partial output happened to print first (14.11, 14.12). The OK/DISAGREEMENT
# wording no longer claims "across every discovered agent" -- a claim that
# overstated coverage whenever a MANUAL/no-candidate role or an active
# escalation dropped a whole role with no trace in the text -- role-level
# exclusions are now named by reason in both branches (14.5's added
# assertion, 14.13).

# 14.1 POSITIVE -- every role agrees (same recipe as 12.2). Shipped
# check-parity RUNS (leg 4 of the pairing requirement) and reports OK, exit
# 0, and its own output carries the CRITICAL-CONSTRAINT disclaimer (config
# agreement only, never a runtime claim).
SB_141=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
OUT_141=$(CLAUDE_PROJECT_DIR="$SB_141" bash "$MS" check-parity 2>&1)
RC_141=$?
assert_eq "14.1 POSITIVE: full agreement exits 0" "0" "$RC_141"
assert_contains "14.1 ...and says OK" "check-parity: OK" "$OUT_141"
assert_contains "14.1 ...and explicitly disclaims any runtime claim (the CRITICAL-CONSTRAINT this subcommand exists to satisfy)" \
    "does not and cannot claim any agent actually ran" "$OUT_141"

# 14.2 NEGATIVE -- ONE role (orchestrator) deliberately drifted; every other
# seeded lane already agrees, so a FAIL here is provably about that one
# role, not a blanket mismatch. LANDING PROOF first: assert the fixture is
# genuinely drifted before check-parity ever runs against it (non-vacuity --
# a fixture that accidentally already agreed would prove nothing).
SB_142=$(ms_sandbox_with_listing "claude-fable-9" "claude-base-0")
assert_eq "14.2 landing proof: the orchestrator lane really is drifted before the check runs" \
    "claude-base-0" "$(agent_pin_of "$SB_142/.claude/agents/orchestrator.md")"
assert_eq "14.2 landing proof: every OTHER seeded lane already agrees (backend, the implementer role's representative)" \
    "claude-fable-9" "$(agent_pin_of "$SB_142/.claude/agents/backend.md")"
OUT_142=$(CLAUDE_PROJECT_DIR="$SB_142" bash "$MS" check-parity 2>&1)
RC_142=$?
assert_eq "14.2 SPECIFIC MISBEHAVIOUR: single-role drift exits 1 (disagreement), not 0 or 2" "1" "$RC_142"
assert_contains "14.2 ...names the drifted role and its current pin" \
    "orchestrator: agent file has 'claude-base-0'" "$OUT_142"
assert_contains "14.2 ...and the id it should be" "resolves 'claude-fable-9'" "$OUT_142"
assert_contains "14.2 ...and the exact fix command" \
    "/workflow-model --role orchestrator claude-fable-9" "$OUT_142"

# 14.3 RESTORE CONTROL -- the SAME drifted sandbox, `apply` (the existing,
# unchanged write path) fixes it, and check-parity -- the SHIPPED script,
# identical call shape -- now reports agreement. Proves 14.2's FAIL was a
# real, fixable finding, not an artefact of the harness.
CLAUDE_PROJECT_DIR="$SB_142" bash "$MS" apply --quiet >/dev/null 2>&1
OUT_143=$(CLAUDE_PROJECT_DIR="$SB_142" bash "$MS" check-parity 2>&1)
RC_143=$?
assert_eq "14.3 RESTORE CONTROL: after apply, the SAME sandbox's check-parity exits 0" "0" "$RC_143"
assert_contains "14.3 ...and says OK" "check-parity: OK" "$OUT_143"

# 14.4 UNVERIFIABLE -- no cached listing at all. Must NOT read as agreement:
# exit 2 (distinct from both 0 and 1), and the message must never carry the
# OK marker -- an operator grepping for "OK" must not be misled.
SB_144=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
rm -f "$SB_144/.claude/.qa-tracking/model-select-cache.json"
OUT_144=$(CLAUDE_PROJECT_DIR="$SB_144" bash "$MS" check-parity 2>&1)
RC_144=$?
assert_eq "14.4 UNVERIFIABLE: no cache exits 2, not 0" "2" "$RC_144"
assert_contains "14.4 ...says UNVERIFIABLE" "UNVERIFIABLE" "$OUT_144"
assert_not_contains "14.4 ...and is never mistaken for a pass (no OK marker)" "check-parity: OK" "$OUT_144"

# 14.5 ESCALATION EXCLUSION -- an ACTIVE per-unit escalation on `implementer`
# pins that lane away from its BASE strategy on purpose (see cmd_escalate's
# header: "declared, audited, reversible", not drift). Drift the backend
# (implementer) pin deliberately, mark an escalation active, and assert the
# implementer lane drops out of the picture entirely -- while a genuinely
# drifted orchestrator alongside it is STILL caught, proving the exclusion
# is role-specific, not a global suppression that would hide real drift.
SB_145=$(ms_sandbox_with_listing "claude-fable-9" "claude-base-0")
printf -- '---\nname: backend\nmodel: claude-opus-5-0\n---\nbody\n' > "$SB_145/.claude/agents/backend.md"
cat > "$SB_145/.claude/.qa-tracking/implementer-escalation.json" <<'JSON'
{"task_id":"section-14-fixture","previous_pin":"claude-fable-9","resolved":"claude-opus-5-0"}
JSON
OUT_145=$(CLAUDE_PROJECT_DIR="$SB_145" bash "$MS" check-parity 2>&1)
RC_145=$?
assert_eq "14.5 an active implementer escalation still exits 1 (the orchestrator drift alongside it is real)" "1" "$RC_145"
assert_contains "14.5 ...names orchestrator" "orchestrator: agent file has 'claude-base-0'" "$OUT_145"
# ROUND 3 CORRECTION (independent review, item 1): the OLD string here was
# "implementer: agent file" -- but production's per-file format is always
# "$role/$agent:", and implementer's members are backend/frontend/devops
# (workflow-model-apply.sh's role_agents()), so "implementer:" with NO
# "/backend" (etc.) after it can NEVER be emitted, drift or no drift. That
# made the control VACUOUS: it passed whether or not the escalation
# exclusion actually worked, which is the exact defect class this task is
# about, inside this task's own control. Fixed to the string production
# WOULD emit if the exclusion broke: backend is the specific drifted member
# in this fixture (frontend/devops still agree with the seeded pin, so they
# would stay silent either way -- see 14.5M below, which proves this by
# actually breaking the exclusion and observing the string appear).
assert_not_contains "14.5 ...but NEVER names implementer/backend (the escalated lane is excluded, not misread as drift)" \
    "implementer/backend: agent file" "$OUT_145"
# 6 = 9 total files minus the 3 implementer members (backend/frontend/devops)
# the active escalation excludes wholesale.
assert_contains "14.5 ...and only 6 of the 9 files were evaluated (all 3 implementer members genuinely excluded, not silently correct by luck)" \
    "(6 file(s) checked)" "$OUT_145"
# round 3, item 3: the DISAGREEMENT message itself now NAMES why implementer
# dropped out, not just a smaller count a reader has to infer the reason for.
assert_contains "14.5 ...and (round 3, item 3) the message itself names WHY implementer was excluded" \
    "excluded from this run entirely (not counted, not compared): implementer (active per-unit escalation)" "$OUT_145"

# 14.5M META (round 3, item 1): neutralise the escalation-exclusion check in
# a COPY of the shipped script and prove the EXACT regression the corrected
# assertion above now catches: an ACTIVE per-unit escalation would be
# misread as ordinary drift -- the escalated member (backend) gets NAMED and
# COUNTED instead of excluded. This is what makes 14.5's assert_not_contains
# a real negative control rather than a string nothing can ever produce.
MUT145_DIR=$(mktemp -d "$TESTROOT/paritymut145.XXXXXX")
MUT145="$MUT145_DIR/model-select.sh"
# shellcheck disable=SC2016
sed 's/if \[ "\$role" = "implementer" \] && \[ -f "\$ESCALATION_STATE" \]; then/if false; then/' "$MS" > "$MUT145"
# shellcheck disable=SC2016
assert_eq "14.5M non-vacuity: the escalation-exclusion condition was found and neutralised" \
    "1" "$(grep -c 'if false; then' "$MUT145" | tr -d '[:space:]')"
assert_eq "14.5M non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT145" "$MS" && echo same || echo differs)"
assert_eq "14.5M non-vacuity: the mutant still parses (fails for its own reason)" \
    "0" "$(bash -n "$MUT145" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT145"
SB_145M=$(ms_sandbox_with_listing "claude-fable-9" "claude-base-0")
printf -- '---\nname: backend\nmodel: claude-opus-5-0\n---\nbody\n' > "$SB_145M/.claude/agents/backend.md"
cat > "$SB_145M/.claude/.qa-tracking/implementer-escalation.json" <<'JSON'
{"task_id":"section-14-fixture","previous_pin":"claude-fable-9","resolved":"claude-opus-5-0"}
JSON
MUT_OUT_145M=$(CLAUDE_PROJECT_DIR="$SB_145M" bash "$MUT145" check-parity 2>&1)
MUT_RC_145M=$?
assert_eq "14.5M SPECIFIC MISBEHAVIOUR: with the exclusion neutralised, the run still exits 1 (orchestrator alone would do that)" \
    "1" "$MUT_RC_145M"
assert_contains "14.5M ...but NOW for the WRONG additional reason: the escalated member (backend) is named as drifted instead of excluded" \
    "implementer/backend: agent file has 'claude-opus-5-0'" "$MUT_OUT_145M"
assert_contains "14.5M ...and all 9 files are WRONGLY counted (the escalation no longer removes the 3 implementer members)" \
    "(9 file(s) checked)" "$MUT_OUT_145M"

# RESTORE CONTROL: the SAME fixture shape, freshly built, the SHIPPED
# script -- correctly excludes backend again. This is the leg that proves
# 14.5's assert_not_contains above is discriminating on REAL behaviour, not
# an artefact of the mutant harness: same inputs, shipped code, and the
# string the mutant just proved production CAN emit is once again absent.
SB_145MC=$(ms_sandbox_with_listing "claude-fable-9" "claude-base-0")
printf -- '---\nname: backend\nmodel: claude-opus-5-0\n---\nbody\n' > "$SB_145MC/.claude/agents/backend.md"
cat > "$SB_145MC/.claude/.qa-tracking/implementer-escalation.json" <<'JSON'
{"task_id":"section-14-fixture","previous_pin":"claude-fable-9","resolved":"claude-opus-5-0"}
JSON
CTRL_OUT_145M=$(CLAUDE_PROJECT_DIR="$SB_145MC" bash "$MS" check-parity 2>&1)
CTRL_RC_145M=0
CLAUDE_PROJECT_DIR="$SB_145MC" bash "$MS" check-parity >/dev/null 2>&1 || CTRL_RC_145M=$?
assert_eq "14.5M RESTORE CONTROL: the SHIPPED script, identical fixture shape, still excludes backend (exits 1 for orchestrator alone)" \
    "1" "$CTRL_RC_145M"
assert_not_contains "14.5M RESTORE CONTROL: ...and never names implementer/backend" \
    "implementer/backend: agent file" "$CTRL_OUT_145M"
assert_contains "14.5M RESTORE CONTROL: ...and still checks only 6 (backend/frontend/devops genuinely excluded)" \
    "(6 file(s) checked)" "$CTRL_OUT_145M"

# 14.6 MISSING-AGENT-FILE EXCLUSION -- a role with no representative agent
# file (a v4 install upgrading, or any install rendered before D0 shipped
# designer/design_reviewer) is excluded, not reported as drift -- mirrors
# Section 6.5 and CHECK_ONLY's identical rule inside cmd_apply.
SB_146=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
rm -f "$SB_146/.claude/agents/designer.md"
OUT_146=$(CLAUDE_PROJECT_DIR="$SB_146" bash "$MS" check-parity 2>&1)
RC_146=$?
assert_eq "14.6 a role missing its agent file does not block a clean verdict" "0" "$RC_146"
assert_not_contains "14.6 ...and is never named as drifted" "designer: agent file" "$OUT_146"
# 8 = 9 total files minus the 1 designer member the missing file excludes.
assert_contains "14.6 ...and only 8 of the 9 files were evaluated (designer genuinely excluded)" \
    "8 file(s) checked" "$OUT_146"

# ---------------------------------------------------------------------------
# 14.7 MALFORMED CACHE SHAPE (round 2, item 2a) -- a valid-JSON cache whose
# .models is PRESENT but not the documented array (here: an object) must
# read as UNVERIFIABLE, never as a coincidental OK. jq's `.[]`/`map()` are
# polymorphic over arrays and objects, so an object's VALUES can flow
# through pick_best exactly like array elements and produce a plausible
# resolved id -- the landing proof below confirms the fixture really is the
# wrong shape, not merely empty, before check-parity ever sees it.
# ---------------------------------------------------------------------------
SB_147=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
cat > "$SB_147/.claude/.qa-tracking/model-select-cache.json" <<JSON
{"timestamp": $(date +%s), "models": {"a": {"id":"claude-fable-9","max_input_tokens":1000000,"created_at":"2026-07-01T00:00:00Z"}, "b": {"id":"claude-opus-5-0","max_input_tokens":400000,"created_at":"2026-06-01T00:00:00Z"}}}
JSON
assert_eq "14.7 landing proof: the fixture's .models is genuinely an object, not the documented array" \
    "object" "$(jq -r '.models | type' "$SB_147/.claude/.qa-tracking/model-select-cache.json" 2>/dev/null)"
OUT_147=$(CLAUDE_PROJECT_DIR="$SB_147" bash "$MS" check-parity 2>&1)
RC_147=$?
assert_eq "14.7 SPECIFIC MISBEHAVIOUR: a wrong-shaped .models exits 2 (UNVERIFIABLE), never 0" "2" "$RC_147"
assert_contains "14.7 ...says UNVERIFIABLE" "UNVERIFIABLE" "$OUT_147"
assert_not_contains "14.7 ...and is never mistaken for a pass (no OK marker)" "check-parity: OK" "$OUT_147"
assert_contains "14.7 ...and names the actual type found, not just 'wrong'" \
    "has .models of type 'object'" "$OUT_147"

# 14.7M META: disable the shape check in a COPY of the shipped script and
# prove the EXACT regression: the malformed cache would then flow through
# and produce a coincidental OK.
MUT147_DIR=$(mktemp -d "$TESTROOT/paritymut147.XXXXXX")
MUT147="$MUT147_DIR/model-select.sh"
# shellcheck disable=SC2016
sed 's/elif \[ "\$shape" != "array" \] && \[ "\$shape" != "null" \]; then/elif false; then/' "$MS" > "$MUT147"
# shellcheck disable=SC2016
assert_eq "14.7M non-vacuity: the shape-check condition was found and neutralised" \
    "1" "$(grep -c 'elif false; then' "$MUT147" | tr -d '[:space:]')"
assert_eq "14.7M non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT147" "$MS" && echo same || echo differs)"
assert_eq "14.7M non-vacuity: the mutant still parses (fails for its own reason)" \
    "0" "$(bash -n "$MUT147" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT147"
SB_147M=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
cat > "$SB_147M/.claude/.qa-tracking/model-select-cache.json" <<JSON
{"timestamp": $(date +%s), "models": {"a": {"id":"claude-fable-9","max_input_tokens":1000000,"created_at":"2026-07-01T00:00:00Z"}, "b": {"id":"claude-opus-5-0","max_input_tokens":400000,"created_at":"2026-06-01T00:00:00Z"}}}
JSON
MUT_OUT_147M=$(CLAUDE_PROJECT_DIR="$SB_147M" bash "$MUT147" check-parity 2>&1)
MUT_RC_147M=$?
assert_eq "14.7M SPECIFIC MISBEHAVIOUR: with the shape check neutralised, the wrong-shaped cache WRONGLY exits 0" \
    "0" "$MUT_RC_147M"
assert_contains "14.7M ...and wrongly claims OK over a cache that was never the documented shape" \
    "check-parity: OK" "$MUT_OUT_147M"
SB_147MC=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
cat > "$SB_147MC/.claude/.qa-tracking/model-select-cache.json" <<JSON
{"timestamp": $(date +%s), "models": {"a": {"id":"claude-fable-9","max_input_tokens":1000000,"created_at":"2026-07-01T00:00:00Z"}, "b": {"id":"claude-opus-5-0","max_input_tokens":400000,"created_at":"2026-06-01T00:00:00Z"}}}
JSON
CTRL_RC_147M=0
CLAUDE_PROJECT_DIR="$SB_147MC" bash "$MS" check-parity >/dev/null 2>&1 || CTRL_RC_147M=$?
assert_eq "14.7M RESTORE CONTROL: the SHIPPED script, identical fixture shape, still correctly exits 2" \
    "2" "$CTRL_RC_147M"

# ---------------------------------------------------------------------------
# 14.8 UNDECLARED ROLE (round 2, item 2b) -- a role with NO strategy key in
# .claude/model-roles is still evaluated against the fail-open `top`
# default (that IS what a spawn would get), but the wording must say the
# role was undeclared rather than claim a declaration that was never made.
# Two legs: (i) the undeclared role's pin happens to already agree with the
# default -- OK, but the summary must still name it as undeclared, not fold
# it silently into "declared"; (ii) the undeclared role's pin does NOT
# agree -- still caught as DISAGREEMENT, worded as "fail-open default",
# never ".claude/model-roles (strategy=...)" (which would be a lie: there
# is no strategy line for this role at all).
# ---------------------------------------------------------------------------
SB_148=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf 'designer=top\ndesign_reviewer=top\norchestrator=top\nimplementer=top\n' > "$SB_148/.claude/model-roles"
assert_eq "14.8 landing proof: 'reviewer' genuinely has no key in model-roles" \
    "0" "$(grep -c '^reviewer=' "$SB_148/.claude/model-roles" | tr -d '[:space:]')"
OUT_148=$(CLAUDE_PROJECT_DIR="$SB_148" bash "$MS" check-parity 2>&1)
RC_148=$?
assert_eq "14.8i an undeclared role that happens to agree still exits 0" "0" "$RC_148"
assert_contains "14.8i ...OK, but names the undeclared role explicitly" \
    "NO strategy declared in .claude/model-roles, evaluated only against the fail-open default 'top': reviewer" \
    "$OUT_148"

SB_148B=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf 'designer=top\ndesign_reviewer=top\norchestrator=top\nimplementer=top\n' > "$SB_148B/.claude/model-roles"
printf -- '---\nname: qa\nmodel: claude-base-0\n---\nbody\n' > "$SB_148B/.claude/agents/qa.md"
assert_eq "14.8ii landing proof: the reviewer (qa) pin is genuinely drifted from what top resolves" \
    "claude-base-0" "$(agent_pin_of "$SB_148B/.claude/agents/qa.md")"
OUT_148B=$(CLAUDE_PROJECT_DIR="$SB_148B" bash "$MS" check-parity 2>&1)
RC_148B=$?
assert_eq "14.8ii an undeclared AND drifted role still exits 1" "1" "$RC_148B"
assert_contains "14.8ii ...and says fail-open DEFAULT, not a declared strategy" \
    "the fail-open default 'top' (role 'reviewer' has NO strategy declared in .claude/model-roles) resolves 'claude-fable-9'" \
    "$OUT_148B"
assert_not_contains "14.8ii ...and NEVER claims a declaration that does not exist" \
    "reviewer/qa: agent file has 'claude-base-0', .claude/model-roles (strategy=" "$OUT_148B"

# 14.8M META: neutralise the declared/undeclared tracking in a COPY of the
# shipped script (both the notation site and the wording branch collapse to
# an unconditional "declared" reading) and prove the EXACT regression: the
# undeclared role's drift would still be CAUGHT (the exit-code contract is
# untouched by this bug), but it would be wrongly narrated as a declared
# strategy, and the NOTE naming it undeclared would silently disappear.
MUT148_DIR=$(mktemp -d "$TESTROOT/paritymut148.XXXXXX")
MUT148="$MUT148_DIR/model-select.sh"
# shellcheck disable=SC2016
sed 's/\[ -n "\$declared_val" \]/true/g' "$MS" > "$MUT148"
# shellcheck disable=SC2016
assert_eq "14.8M non-vacuity: both declared_val checks were found and neutralised" \
    "0" "$(grep -c '\[ -n "\$declared_val" \]' "$MUT148" | tr -d '[:space:]')"
assert_eq "14.8M non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT148" "$MS" && echo same || echo differs)"
assert_eq "14.8M non-vacuity: the mutant still parses (fails for its own reason)" \
    "0" "$(bash -n "$MUT148" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT148"
SB_148M=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf 'designer=top\ndesign_reviewer=top\norchestrator=top\nimplementer=top\n' > "$SB_148M/.claude/model-roles"
printf -- '---\nname: qa\nmodel: claude-base-0\n---\nbody\n' > "$SB_148M/.claude/agents/qa.md"
MUT_OUT_148M=$(CLAUDE_PROJECT_DIR="$SB_148M" bash "$MUT148" check-parity 2>&1)
MUT_RC_148M=$?
assert_eq "14.8M SPECIFIC MISBEHAVIOUR: the drift is still caught (rc unaffected by this specific bug)" \
    "1" "$MUT_RC_148M"
assert_contains "14.8M ...but WRONGLY claims a declared strategy for an undeclared role" \
    "reviewer/qa: agent file has 'claude-base-0', .claude/model-roles (strategy=top) resolves" "$MUT_OUT_148M"
assert_not_contains "14.8M ...and the undeclared NOTE silently disappears" \
    "NO strategy declared in .claude/model-roles" "$MUT_OUT_148M"
SB_148MC=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf 'designer=top\ndesign_reviewer=top\norchestrator=top\nimplementer=top\n' > "$SB_148MC/.claude/model-roles"
printf -- '---\nname: qa\nmodel: claude-base-0\n---\nbody\n' > "$SB_148MC/.claude/agents/qa.md"
CTRL_OUT_148M=$(CLAUDE_PROJECT_DIR="$SB_148MC" bash "$MS" check-parity 2>&1)
assert_contains "14.8M RESTORE CONTROL: the SHIPPED script, identical fixture shape, still says fail-open DEFAULT" \
    "the fail-open default 'top' (role 'reviewer' has NO strategy declared" "$CTRL_OUT_148M"

# ---------------------------------------------------------------------------
# 14.9 UNREADABLE/MALFORMED AGENT FILE (round 2, item 2c) -- a file that
# EXISTS but whose model: pin cannot be read must be folded into
# DISAGREEMENT, never silently excluded the way a genuinely absent file is
# (current_pin()'s old `grep | head -1 | awk` pipeline masked exactly this).
# Two triggers for the identical code path: (i) malformed frontmatter (no
# `model:` line at all) -- deterministic and portable; (ii) permission
# denied (chmod 000) -- gracefully DISARMED when the test itself runs as
# root, matching every other root-aware DISARM in this file, since root
# reads a 000 file anyway and the trigger would not fire.
# ---------------------------------------------------------------------------
SB_149=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf -- '---\nname: qa\ndescription: no model line here\n---\nbody\n' > "$SB_149/.claude/agents/qa.md"
assert_eq "14.9i landing proof: qa.md genuinely has zero 'model:' lines" \
    "0" "$(grep -c '^model:' "$SB_149/.claude/agents/qa.md" | tr -d '[:space:]')"
OUT_149=$(CLAUDE_PROJECT_DIR="$SB_149" bash "$MS" check-parity 2>&1)
RC_149=$?
assert_eq "14.9i a malformed agent file (no model: line) exits 1, not excluded" "1" "$RC_149"
assert_contains "14.9i ...names the file and says NOT excluded" \
    "reviewer/qa: agent file exists at" "$OUT_149"
assert_contains "14.9i ...cannot confirm agreement, NOT excluded" \
    "cannot confirm agreement, NOT excluded" "$OUT_149"
assert_contains "14.9i ...and it IS counted (9, not silently dropped to 8)" \
    "(9 file(s) checked)" "$OUT_149"

if [ "$(id -u)" = "0" ]; then
    printf '  note: 14.9ii SKIPPED - running as root, chmod 000 does not block a read, so this trigger cannot fire here (14.9i already covers the code path via malformed frontmatter)\n'
else
    SB_149B=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
    chmod 000 "$SB_149B/.claude/agents/qa.md"
    assert_eq "14.9ii landing proof: qa.md is genuinely unreadable by this process" \
        "no" "$([ -r "$SB_149B/.claude/agents/qa.md" ] && echo yes || echo no)"
    OUT_149B=$(CLAUDE_PROJECT_DIR="$SB_149B" bash "$MS" check-parity 2>&1)
    RC_149B=$?
    chmod 644 "$SB_149B/.claude/agents/qa.md"
    assert_eq "14.9ii a permission-denied agent file ALSO exits 1, not excluded" "1" "$RC_149B"
    assert_contains "14.9ii ...names the file and says NOT excluded" \
        "reviewer/qa: agent file exists at" "$OUT_149B"
fi

# 14.9M META: drop just the "unreadable -> fold into drifted" finding in a
# COPY of the shipped script, falling back to the OLD silent-exclude shape,
# and prove the EXACT regression: an unreadable file lets the run report a
# clean OK if every readable pin happens to agree.
MUT149_DIR=$(mktemp -d "$TESTROOT/paritymut149.XXXXXX")
MUT149="$MUT149_DIR/model-select.sh"
sed '/cannot confirm agreement, NOT excluded/d' "$MS" > "$MUT149"
assert_eq "14.9M non-vacuity: the finding line was found and dropped" \
    "0" "$(grep -c 'cannot confirm agreement, NOT excluded' "$MUT149" | tr -d '[:space:]')"
assert_eq "14.9M non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT149" "$MS" && echo same || echo differs)"
assert_eq "14.9M non-vacuity: the mutant still parses (fails for its own reason)" \
    "0" "$(bash -n "$MUT149" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT149"
SB_149M=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf -- '---\nname: qa\ndescription: no model line here\n---\nbody\n' > "$SB_149M/.claude/agents/qa.md"
MUT_OUT_149M=$(CLAUDE_PROJECT_DIR="$SB_149M" bash "$MUT149" check-parity 2>&1)
MUT_RC_149M=$?
assert_eq "14.9M SPECIFIC MISBEHAVIOUR: with the finding dropped, the malformed file is silently excluded and WRONGLY exits 0" \
    "0" "$MUT_RC_149M"
assert_contains "14.9M ...and wrongly claims OK over a file that was never actually read" \
    "check-parity: OK" "$MUT_OUT_149M"
SB_149MC=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf -- '---\nname: qa\ndescription: no model line here\n---\nbody\n' > "$SB_149MC/.claude/agents/qa.md"
CTRL_RC_149M=0
CLAUDE_PROJECT_DIR="$SB_149MC" bash "$MS" check-parity >/dev/null 2>&1 || CTRL_RC_149M=$?
assert_eq "14.9M RESTORE CONTROL: the SHIPPED script, identical fixture shape, still correctly exits 1" \
    "1" "$CTRL_RC_149M"

# ---------------------------------------------------------------------------
# 14.10 WIDENED FILE COVERAGE / SIBLING-FILE DRIFT (round 2, item 2d) --
# EVERY discovered agent file in a role class is compared, not one
# representative. backend.md is the `implementer` role's representative
# (current_pin()'s single-file read for every OTHER subcommand); this
# fixture drifts a DIFFERENT member, devops.md, while backend.md still
# agrees -- exactly the shape a representative-only check would miss.
# ---------------------------------------------------------------------------
SB_1410=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf -- '---\nname: devops\nmodel: claude-base-0\n---\nbody\n' > "$SB_1410/.claude/agents/devops.md"
assert_eq "14.10 landing proof: backend.md (the OLD representative) still agrees" \
    "claude-fable-9" "$(agent_pin_of "$SB_1410/.claude/agents/backend.md")"
assert_eq "14.10 landing proof: devops.md (a sibling member) is genuinely drifted" \
    "claude-base-0" "$(agent_pin_of "$SB_1410/.claude/agents/devops.md")"
OUT_1410=$(CLAUDE_PROJECT_DIR="$SB_1410" bash "$MS" check-parity 2>&1)
RC_1410=$?
assert_eq "14.10 SPECIFIC MISBEHAVIOUR (of the OLD design): a sibling-file drift exits 1" "1" "$RC_1410"
assert_contains "14.10 ...names the SPECIFIC file, devops, not just the role" \
    "implementer/devops: agent file has 'claude-base-0'" "$OUT_1410"
assert_not_contains "14.10 ...and does NOT also blame backend (which genuinely agrees)" \
    "implementer/backend: agent file has" "$OUT_1410"
assert_contains "14.10 ...and all 9 files were checked (full role-class coverage, not one representative)" \
    "(9 file(s) checked)" "$OUT_1410"

# 14.10M META: revert to a REPRESENTATIVE-ONLY comparison in a COPY of the
# shipped script (only the FIRST member role_agents() lists per role is
# ever compared -- for `implementer` that is backend, for `reviewer` that
# is qa, structurally identical to round 1's current_pin()-per-role design)
# and prove the EXACT regression this section exists to rule out: a sibling
# drift the representative does not share is invisible to it.
MUT1410_DIR=$(mktemp -d "$TESTROOT/paritymut1410.XXXXXX")
MUT1410="$MUT1410_DIR/model-select.sh"
# shellcheck disable=SC2016  # matching LITERAL shell-source text, not expanding this script's own vars
sed "s/r { print \\\$2 }')/r { print \\\$2 }' | head -1)/" "$MS" > "$MUT1410"
assert_eq "14.10M non-vacuity: the member-discovery line was found and truncated to one" \
    "1" "$(grep -c "head -1)\$" "$MUT1410" | tr -d '[:space:]')"
assert_eq "14.10M non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT1410" "$MS" && echo same || echo differs)"
assert_eq "14.10M non-vacuity: the mutant still parses (fails for its own reason)" \
    "0" "$(bash -n "$MUT1410" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT1410"
SB_1410M=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf -- '---\nname: devops\nmodel: claude-base-0\n---\nbody\n' > "$SB_1410M/.claude/agents/devops.md"
MUT_OUT_1410M=$(CLAUDE_PROJECT_DIR="$SB_1410M" bash "$MUT1410" check-parity 2>&1)
MUT_RC_1410M=$?
assert_eq "14.10M SPECIFIC MISBEHAVIOUR: representative-only WRONGLY exits 0 over a real sibling drift" \
    "0" "$MUT_RC_1410M"
assert_contains "14.10M ...and checks only 5 files (one per role), not 9 (the coverage this whole item exists to widen)" \
    "5 file(s) checked" "$MUT_OUT_1410M"
SB_1410MC=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
printf -- '---\nname: devops\nmodel: claude-base-0\n---\nbody\n' > "$SB_1410MC/.claude/agents/devops.md"
CTRL_RC_1410M=0
CLAUDE_PROJECT_DIR="$SB_1410MC" bash "$MS" check-parity >/dev/null 2>&1 || CTRL_RC_1410M=$?
assert_eq "14.10M RESTORE CONTROL: the SHIPPED script, identical fixture shape, still correctly exits 1" \
    "1" "$CTRL_RC_1410M"

# ---------------------------------------------------------------------------
# 14.11 / 14.12 FAIL CLOSED ON A PARTIAL/FAILED --print-role-map (round 3,
# item 3) -- the OLD `role_map=$(... || true)` discarded the helper's own
# exit status entirely, so a helper that printed output and then died left
# that output IN USE -- only `checked == 0` (every role excluded) produced
# UNVERIFIABLE, so a handful of surviving, agreeing files could yield a
# coincidental OK while other roles silently never entered the comparison.
# TWO independent guards, TWO independent fixtures and mutants, because
# either alone is not sufficient: 14.11 covers a NONZERO exit (even over a
# map that LOOKS complete -- proving the exit status alone is disqualifying,
# not merely a proxy for incompleteness); 14.12 covers a CLEAN exit (0)
# whose map is still missing a whole role role_agents() always lists (a
# helper that "succeeds" while truncated).
#
# Each fixture REPLACES the sandbox's OWN copy of workflow-model-apply.sh
# with a test stub. new_sandbox() SYMLINKS that path to the real, shared
# $APPLY -- `rm -f` first is load-bearing: without it, writing through the
# symlink would truncate the REAL repo file every other fixture in this
# suite also relies on, not just this one sandbox's copy.
# ---------------------------------------------------------------------------

# 14.11 NONZERO EXIT, EVEN OVER A COMPLETE, FULLY-AGREEING MAP -- the
# strongest form of the coincidental-OK trap: every one of the 9 real
# members is printed, correctly, and would show full agreement if trusted.
SB_1411=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
rm -f "$SB_1411/.claude/scripts/workflow-model-apply.sh"
cat > "$SB_1411/.claude/scripts/workflow-model-apply.sh" <<'STUB'
#!/bin/bash
# TEST STUB (14.11, claude-workflow-plugin-a13r round 3): prints the exact,
# COMPLETE role map the real helper would for this fixture, then exits
# nonzero anyway -- simulating a helper whose output looked fine but which
# still signalled failure (a cleanup step at the end that failed, a trap
# that fired late). The exit status alone must be disqualifying.
printf 'designer\tdesigner\n'
printf 'design_reviewer\tdesign-reviewer\n'
printf 'orchestrator\torchestrator\n'
printf 'implementer\tbackend\n'
printf 'implementer\tfrontend\n'
printf 'implementer\tdevops\n'
printf 'reviewer\tqa\n'
printf 'reviewer\tgrader\n'
printf 'reviewer\tjudge\n'
exit 7
STUB
chmod +x "$SB_1411/.claude/scripts/workflow-model-apply.sh"
assert_eq "14.11 landing proof: the stub genuinely exits nonzero" \
    "7" "$(bash "$SB_1411/.claude/scripts/workflow-model-apply.sh" --print-role-map >/dev/null 2>&1; echo $?)"
assert_eq "14.11 landing proof: the stub's map is genuinely COMPLETE (all 9 members, the coincidental-OK trap if trusted)" \
    "9" "$(bash "$SB_1411/.claude/scripts/workflow-model-apply.sh" --print-role-map 2>/dev/null | grep -c . | tr -d '[:space:]')"
OUT_1411=$(CLAUDE_PROJECT_DIR="$SB_1411" bash "$MS" check-parity 2>&1)
RC_1411=$?
assert_eq "14.11 SPECIFIC MISBEHAVIOUR (of the OLD design): a nonzero --print-role-map exit is caught even over a complete map -- exits 2 (UNVERIFIABLE), never 0" \
    "2" "$RC_1411"
assert_contains "14.11 ...names the nonzero exit" "print-role-map exited 7" "$OUT_1411"
assert_not_contains "14.11 ...and is never mistaken for a pass" "check-parity: OK" "$OUT_1411"

# 14.11M META: neutralise ONLY the exit-status capture in a COPY of the
# shipped script (restoring the OLD `|| true` idiom for that one line,
# leaving the missing-roles guard untouched) and prove the EXACT
# regression: with the exit status discarded again, 14.11's own
# complete-but-failing fixture WRONGLY reports OK -- proving the exit-status
# guard specifically is load-bearing, not merely redundant with the
# missing-roles guard below.
MUT1411_DIR=$(mktemp -d "$TESTROOT/paritymut1411.XXXXXX")
MUT1411="$MUT1411_DIR/model-select.sh"
# shellcheck disable=SC2016
sed 's/|| role_map_rc=\$?$/|| true/' "$MS" > "$MUT1411"
# shellcheck disable=SC2016
assert_eq "14.11M non-vacuity: the exit-status capture was found and reverted to '|| true'" \
    "0" "$(grep -c 'role_map_rc=\$?' "$MUT1411" | tr -d '[:space:]')"
assert_eq "14.11M non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT1411" "$MS" && echo same || echo differs)"
assert_eq "14.11M non-vacuity: the mutant still parses (fails for its own reason)" \
    "0" "$(bash -n "$MUT1411" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT1411"
MUT_OUT_1411M=$(CLAUDE_PROJECT_DIR="$SB_1411" bash "$MUT1411" check-parity 2>&1)
MUT_RC_1411M=$?
assert_eq "14.11M SPECIFIC MISBEHAVIOUR: with the exit status discarded again, the SAME nonzero-exit fixture WRONGLY exits 0" \
    "0" "$MUT_RC_1411M"
assert_contains "14.11M ...and wrongly claims OK over a helper that exited 7" \
    "check-parity: OK" "$MUT_OUT_1411M"

# RESTORE CONTROL: the SAME stub fixture (SB_1411, not rebuilt), the
# SHIPPED script -- still correctly fails closed.
CTRL_OUT_1411M=$(CLAUDE_PROJECT_DIR="$SB_1411" bash "$MS" check-parity 2>&1)
CTRL_RC_1411M=$?
assert_eq "14.11M RESTORE CONTROL: the SHIPPED script, the SAME nonzero-exit fixture, still exits 2" \
    "2" "$CTRL_RC_1411M"
assert_not_contains "14.11M RESTORE CONTROL: ...and never claims OK" "check-parity: OK" "$CTRL_OUT_1411M"

# 14.12 CLEAN (0) EXIT, BUT THE MAP IS MISSING WHOLE ROLES -- "succeeded
# while truncated". The three roles it DOES print (designer,
# design_reviewer, orchestrator) all genuinely agree with the seeded pin.
SB_1412=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
rm -f "$SB_1412/.claude/scripts/workflow-model-apply.sh"
cat > "$SB_1412/.claude/scripts/workflow-model-apply.sh" <<'STUB'
#!/bin/bash
# TEST STUB (14.12, claude-workflow-plugin-a13r round 3): exits 0 but its
# role map omits TWO roles entirely (implementer, reviewer) that
# role_agents() always lists regardless of what is installed -- simulating
# a helper that "succeeds" while truncated (a write cut off after the
# exit-code path already committed, a future refactor that forgets a role).
printf 'designer\tdesigner\n'
printf 'design_reviewer\tdesign-reviewer\n'
printf 'orchestrator\torchestrator\n'
exit 0
STUB
chmod +x "$SB_1412/.claude/scripts/workflow-model-apply.sh"
assert_eq "14.12 landing proof: the stub genuinely exits 0" \
    "0" "$(bash "$SB_1412/.claude/scripts/workflow-model-apply.sh" --print-role-map >/dev/null 2>&1; echo $?)"
assert_eq "14.12 landing proof: the stub's map genuinely omits 'implementer'" \
    "0" "$(bash "$SB_1412/.claude/scripts/workflow-model-apply.sh" --print-role-map 2>/dev/null | awk -F'\t' '$1=="implementer"' | grep -c . | tr -d '[:space:]')"
OUT_1412=$(CLAUDE_PROJECT_DIR="$SB_1412" bash "$MS" check-parity 2>&1)
RC_1412=$?
assert_eq "14.12 SPECIFIC MISBEHAVIOUR (of the OLD design): a role map missing whole roles despite exit 0 is caught -- exits 2 (UNVERIFIABLE), never 0" \
    "2" "$RC_1412"
assert_contains "14.12 ...names the missing role(s)" "missing role(s)" "$OUT_1412"
assert_contains "14.12 ...specifically implementer" "implementer" "$OUT_1412"
assert_contains "14.12 ...specifically reviewer" "reviewer" "$OUT_1412"
assert_not_contains "14.12 ...and is never mistaken for a pass" "check-parity: OK" "$OUT_1412"

# 14.12M META: neutralise ONLY the missing-roles enforcement in a COPY of
# the shipped script (the exit-status guard stays intact and untouched) and
# prove the EXACT regression: with it disarmed, 14.12's own clean-exit,
# partial-map fixture WRONGLY reports OK over the three roles it happened
# to print.
MUT1412_DIR=$(mktemp -d "$TESTROOT/paritymut1412.XXXXXX")
MUT1412="$MUT1412_DIR/model-select.sh"
# shellcheck disable=SC2016
sed 's/if \[ -n "\$_prc_missing" \]; then/if false; then/' "$MS" > "$MUT1412"
# shellcheck disable=SC2016
assert_eq "14.12M non-vacuity: the missing-roles enforcement was found and disarmed" \
    "1" "$(grep -c 'if false; then' "$MUT1412" | tr -d '[:space:]')"
assert_eq "14.12M non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT1412" "$MS" && echo same || echo differs)"
assert_eq "14.12M non-vacuity: the mutant still parses (fails for its own reason)" \
    "0" "$(bash -n "$MUT1412" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT1412"
MUT_OUT_1412M=$(CLAUDE_PROJECT_DIR="$SB_1412" bash "$MUT1412" check-parity 2>&1)
MUT_RC_1412M=$?
assert_eq "14.12M SPECIFIC MISBEHAVIOUR: with the enforcement disarmed, the SAME partial-map fixture WRONGLY exits 0" \
    "0" "$MUT_RC_1412M"
assert_contains "14.12M ...and wrongly claims OK over a map that never listed implementer or reviewer at all" \
    "check-parity: OK" "$MUT_OUT_1412M"

# RESTORE CONTROL: the SAME stub fixture (SB_1412, not rebuilt), the
# SHIPPED script -- still correctly fails closed.
CTRL_OUT_1412M=$(CLAUDE_PROJECT_DIR="$SB_1412" bash "$MS" check-parity 2>&1)
CTRL_RC_1412M=$?
assert_eq "14.12M RESTORE CONTROL: the SHIPPED script, the SAME partial-map fixture, still exits 2" \
    "2" "$CTRL_RC_1412M"
assert_not_contains "14.12M RESTORE CONTROL: ...and never claims OK" "check-parity: OK" "$CTRL_OUT_1412M"

# ---------------------------------------------------------------------------
# 14.13 THE OK/DISAGREEMENT WORDING NO LONGER OVERCLAIMS UNDER A ROLE-LEVEL
# EXCLUSION (round 3, item 3, second half) -- an ACTIVE escalation excludes
# the whole `implementer` role from the count, same shape as 14.5, but here
# EVERY evaluated file still agrees (rc=0, OK) -- proving the OK wording
# itself, not just DISAGREEMENT's, now NAMES what was excluded and no
# longer claims "every discovered agent" when a whole role -- one that DOES
# have real, on-disk agent files, unlike 14.6's legitimately-absent
# designer.md -- was silently dropped from the count.
# ---------------------------------------------------------------------------
SB_1413=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
cat > "$SB_1413/.claude/.qa-tracking/implementer-escalation.json" <<'JSON'
{"task_id":"section-14-fixture-1413","previous_pin":"claude-fable-9","resolved":"claude-opus-5-0"}
JSON
OUT_1413=$(CLAUDE_PROJECT_DIR="$SB_1413" bash "$MS" check-parity 2>&1)
RC_1413=$?
assert_eq "14.13 an active escalation alongside total agreement elsewhere still exits 0" "0" "$RC_1413"
assert_contains "14.13 ...OK, and only 6 of 9 were checked" "6 file(s) checked" "$OUT_1413"
assert_not_contains "14.13 ...and no longer claims coverage over every discovered agent when a role was excluded" \
    "across every discovered agent" "$OUT_1413"
assert_contains "14.13 ...and instead NAMES the excluded role and reason" \
    "excluded from this run entirely (not counted, not compared): implementer (active per-unit escalation)" "$OUT_1413"

# 14.13M META: drop the excluded_note wiring in a COPY of the shipped
# script (the exclusion itself stays correct -- implementer is still
# excluded from `checked`, rc is still 0 -- only the NARRATION regresses)
# and prove the EXACT regression: the OK message falls silent about WHY
# only 6 of 9 were checked, the exact overclaim shape item 3 exists to rule
# out.
MUT1413_DIR=$(mktemp -d "$TESTROOT/paritymut1413.XXXXXX")
MUT1413="$MUT1413_DIR/model-select.sh"
# shellcheck disable=SC2016  # matching LITERAL shell-source text, not expanding this script's own vars
sed 's/\[ -n "\$excluded" \] && excluded_note=.*/excluded_note=""/' "$MS" > "$MUT1413"
# shellcheck disable=SC2016
assert_eq "14.13M non-vacuity: the excluded_note wiring was found and neutralised" \
    "0" "$(grep -c '\[ -n "\$excluded" \] && excluded_note=' "$MUT1413" | tr -d '[:space:]')"
assert_eq "14.13M non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT1413" "$MS" && echo same || echo differs)"
assert_eq "14.13M non-vacuity: the mutant still parses (fails for its own reason)" \
    "0" "$(bash -n "$MUT1413" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT1413"
SB_1413M=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
cat > "$SB_1413M/.claude/.qa-tracking/implementer-escalation.json" <<'JSON'
{"task_id":"section-14-fixture-1413","previous_pin":"claude-fable-9","resolved":"claude-opus-5-0"}
JSON
MUT_OUT_1413M=$(CLAUDE_PROJECT_DIR="$SB_1413M" bash "$MUT1413" check-parity 2>&1)
MUT_RC_1413M=$?
assert_eq "14.13M SPECIFIC MISBEHAVIOUR: the exclusion itself is unaffected (still exits 0)" \
    "0" "$MUT_RC_1413M"
assert_contains "14.13M ...still only checks 6 of 9 (the exclusion logic is untouched)" \
    "6 file(s) checked" "$MUT_OUT_1413M"
assert_not_contains "14.13M ...but the WHY silently disappears from the message" \
    "excluded from this run entirely" "$MUT_OUT_1413M"

# RESTORE CONTROL: fresh identical fixture, the SHIPPED script -- the
# exclusion reason is named again.
SB_1413MC=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
cat > "$SB_1413MC/.claude/.qa-tracking/implementer-escalation.json" <<'JSON'
{"task_id":"section-14-fixture-1413","previous_pin":"claude-fable-9","resolved":"claude-opus-5-0"}
JSON
CTRL_OUT_1413M=$(CLAUDE_PROJECT_DIR="$SB_1413MC" bash "$MS" check-parity 2>&1)
assert_contains "14.13M RESTORE CONTROL: the SHIPPED script, identical fixture shape, still names the exclusion" \
    "excluded from this run entirely (not counted, not compared): implementer (active per-unit escalation)" "$CTRL_OUT_1413M"

# ---------------------------------------------------------------------------
# 14.14 CLEAN (0) EXIT, EVERY ROLE PRESENT, BUT MEMBERS WITHIN A ROLE ARE
# MISSING (claude-workflow-plugin-a13r round 4, item (a)) -- the reviewer's
# own proof-of-concept: a map that satisfies 14.12's whole-role guard on its
# own (every one of the 5 roles appears at least once) while implementer and
# reviewer are each missing two of their three members. "checks 5 files,
# SILENTLY IGNORES frontend, devops, grader and judge, and reaches the OK
# branch" was the exact finding.
# ---------------------------------------------------------------------------
SB_1414=$(ms_sandbox_with_listing "claude-fable-9" "claude-fable-9")
rm -f "$SB_1414/.claude/scripts/workflow-model-apply.sh"
cat > "$SB_1414/.claude/scripts/workflow-model-apply.sh" <<'STUB'
#!/bin/bash
# TEST STUB (14.14, claude-workflow-plugin-a13r round 4 item (a)): exits 0
# and every ROLE NAME appears at least once -- satisfying 14.12's
# whole-role guard on its own -- but implementer and reviewer are each
# missing two of their three members. This is the reviewer's own
# proof-of-concept fixture, reproduced verbatim.
printf 'designer\tdesigner\n'
printf 'design_reviewer\tdesign-reviewer\n'
printf 'orchestrator\torchestrator\n'
printf 'implementer\tbackend\n'
printf 'reviewer\tqa\n'
exit 0
STUB
chmod +x "$SB_1414/.claude/scripts/workflow-model-apply.sh"
assert_eq "14.14 landing proof: the stub genuinely exits 0" \
    "0" "$(bash "$SB_1414/.claude/scripts/workflow-model-apply.sh" --print-role-map >/dev/null 2>&1; echo $?)"
assert_eq "14.14 landing proof: the stub's map genuinely contains every ROLE at least once (would satisfy the OLD whole-role-only guard alone)" \
    "5" "$(bash "$SB_1414/.claude/scripts/workflow-model-apply.sh" --print-role-map 2>/dev/null | awk -F'\t' '{print $1}' | sort -u | grep -c .)"
assert_eq "14.14 landing proof: the stub's map genuinely omits implementer/frontend" \
    "0" "$(bash "$SB_1414/.claude/scripts/workflow-model-apply.sh" --print-role-map 2>/dev/null | awk -F'\t' '$1=="implementer" && $2=="frontend"' | grep -c .)"
OUT_1414=$(CLAUDE_PROJECT_DIR="$SB_1414" bash "$MS" check-parity 2>&1)
RC_1414=$?
assert_eq "14.14 SPECIFIC MISBEHAVIOUR (of the OLD design): a role map with every role present but members truncated is caught -- exits 2 (UNVERIFIABLE), never 0" \
    "2" "$RC_1414"
assert_contains "14.14 ...names the missing member(s)" "missing member(s)" "$OUT_1414"
assert_contains "14.14 ...specifically implementer/frontend" "implementer/frontend" "$OUT_1414"
assert_contains "14.14 ...specifically implementer/devops" "implementer/devops" "$OUT_1414"
assert_contains "14.14 ...specifically reviewer/grader" "reviewer/grader" "$OUT_1414"
assert_contains "14.14 ...specifically reviewer/judge" "reviewer/judge" "$OUT_1414"
assert_not_contains "14.14 ...and is never mistaken for a pass" "check-parity: OK" "$OUT_1414"

# 14.14M META: neutralise ONLY the member-level completeness enforcement in
# a COPY of the shipped script (the whole-role guard from 14.12 stays intact
# and untouched) and prove the EXACT regression: with it disarmed, 14.14's
# own clean-exit, role-complete-but-member-truncated fixture WRONGLY reports
# OK over the 5 files it happened to print -- this is the reviewer's own
# scenario, reproduced end to end.
MUT1414_DIR=$(mktemp -d "$TESTROOT/paritymut1414.XXXXXX")
MUT1414="$MUT1414_DIR/model-select.sh"
# shellcheck disable=SC2016  # matching LITERAL shell-source text, not expanding this script's own vars
sed 's/if \[ -n "\$_prc_member_missing" \]; then/if false; then/' "$MS" > "$MUT1414"
# shellcheck disable=SC2016
assert_eq "14.14M non-vacuity: the member-completeness enforcement was found and disarmed" \
    "1" "$(grep -c 'if false; then' "$MUT1414" | tr -d '[:space:]')"
assert_eq "14.14M non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT1414" "$MS" && echo same || echo differs)"
assert_eq "14.14M non-vacuity: the mutant still parses (fails for its own reason)" \
    "0" "$(bash -n "$MUT1414" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT1414"
MUT_OUT_1414M=$(CLAUDE_PROJECT_DIR="$SB_1414" bash "$MUT1414" check-parity 2>&1)
MUT_RC_1414M=$?
assert_eq "14.14M SPECIFIC MISBEHAVIOUR: with the enforcement disarmed, the SAME member-truncated fixture WRONGLY exits 0" \
    "0" "$MUT_RC_1414M"
assert_contains "14.14M ...and wrongly claims OK, checking only the 5 files that survived" \
    "5 file(s) checked" "$MUT_OUT_1414M"

# RESTORE CONTROL: the SAME stub fixture (SB_1414, not rebuilt), the SHIPPED
# script -- still correctly fails closed.
CTRL_OUT_1414M=$(CLAUDE_PROJECT_DIR="$SB_1414" bash "$MS" check-parity 2>&1)
CTRL_RC_1414M=$?
assert_eq "14.14M RESTORE CONTROL: the SHIPPED script, the SAME member-truncated fixture, still exits 2" \
    "2" "$CTRL_RC_1414M"
assert_not_contains "14.14M RESTORE CONTROL: ...and never claims OK" "check-parity: OK" "$CTRL_OUT_1414M"

# ---------------------------------------------------------------------------
# 14M. META -- neutralise the disagreement comparison in a COPY of the
# shipped script and prove the EXACT regression this section exists to rule
# out: a check-parity that reports agreement regardless of real drift.
# ---------------------------------------------------------------------------
MUT14_DIR=$(mktemp -d "$TESTROOT/paritymut.XXXXXX")
MUT14="$MUT14_DIR/model-select.sh"
# shellcheck disable=SC2016  # matching LITERAL shell-source text, not expanding this script's own vars
sed 's/if \[ "\$pin" != "\$resolved" \]; then$/if [ "$pin" != "$pin" ]; then/' "$MS" > "$MUT14"
# shellcheck disable=SC2016
assert_eq "14M.0a non-vacuity: the comparison line was found and neutralised" \
    "1" "$(grep -c 'if \[ "\$pin" != "\$pin" \]; then' "$MUT14" | tr -d '[:space:]')"
# shellcheck disable=SC2016
assert_eq "14M.0b non-vacuity: the ORIGINAL comparison is gone from the mutant" \
    "0" "$(grep -c 'if \[ "\$pin" != "\$resolved" \]; then' "$MUT14" | tr -d '[:space:]')"
assert_eq "14M.1 non-vacuity: the mutant differs from the shipped resolver" \
    "differs" "$(cmp -s "$MUT14" "$MS" && echo same || echo differs)"
assert_eq "14M.2 non-vacuity: the mutant still parses (fails for its own reason, not a syntax error)" \
    "0" "$(bash -n "$MUT14" >/dev/null 2>&1 && echo 0 || echo 1)"
chmod +x "$MUT14"

# Drive the MUTANT against 14.2's exact drifted fixture shape (a fresh
# sandbox, not the now-fixed SB_142).
SB_14M=$(ms_sandbox_with_listing "claude-fable-9" "claude-base-0")
MUT_OUT_14M=$(CLAUDE_PROJECT_DIR="$SB_14M" bash "$MUT14" check-parity 2>&1)
MUT_RC_14M=$?
assert_eq "14M.3 SPECIFIC MISBEHAVIOUR: with the comparison neutralised, a genuinely drifted role WRONGLY exits 0" \
    "0" "$MUT_RC_14M"
assert_contains "14M.4 ...and wrongly claims OK on a fixture that IS drifted (naming the exact defect: a check-parity that would silently ship this)" \
    "check-parity: OK" "$MUT_OUT_14M"

# RESTORE CONTROL: the identical fixture shape, freshly built, run against
# the SHIPPED script -- still correctly fails.
SB_14MC=$(ms_sandbox_with_listing "claude-fable-9" "claude-base-0")
CTRL_RC_14M=0
CLAUDE_PROJECT_DIR="$SB_14MC" bash "$MS" check-parity >/dev/null 2>&1 || CTRL_RC_14M=$?
assert_eq "14M.5 RESTORE CONTROL: the SHIPPED script, identical fixture shape, still correctly exits 1" \
    "1" "$CTRL_RC_14M"

# ===========================================================================
echo ""
echo "=== Section 11: bd isolation holds for the file that used to be CAN-REACH(WRITE) (claude-workflow-plugin-j7kk) ==="
#
# Non-vacuity FIRST: the stub log must be non-empty, or "isolation held"
# would be indistinguishable from "nothing in this file calls bd at all" —
# and the census measured 417 calls, so it does not go untested by accident.
BD_STUB_CALL_COUNT=0
[ -f "$BD_STUB_LOG" ] && BD_STUB_CALL_COUNT=$(grep -c . "$BD_STUB_LOG" 2>/dev/null || echo 0)
assert_eq "11.1 NON-VACUITY: this file DOES call bd somewhere (the stub logged >=1 invocation — isolation had something to isolate)" \
    "yes" "$([ "${BD_STUB_CALL_COUNT:-0}" -ge 1 ] && echo yes || echo no)"
# NOT "comment": the stub REFUSES unconditionally (exit 1, no stdout), so
# `bd create ... --json | jq -r '.id // empty'` always yields an empty id and
# find_or_create_meta_task() always returns 1 before record_switch_role ever
# reaches its OWN `bd comment` call — `|| return 0` bails the caller out
# first (MEASURED: 0/382 logged calls are `comment`, all `create`/`list`/
# `--version`). That short-circuit is a property of a stub that always
# fails, not evidence isolation is incomplete; what it call-shape DOES prove
# is the two calls find_or_create_meta_task always attempts before it can
# give up — the title lookup, and the create attempt behind it.
assert_contains "11.2 the logged subcommands include find_or_create_meta_task's create attempt (the one this file used to write live, 35/run in the census)" \
    "create" "$(cat "$BD_STUB_LOG" 2>/dev/null || true)"
assert_contains "11.3 ...and the title lookup it tries first (list)" \
    "list" "$(cat "$BD_STUB_LOG" 2>/dev/null || true)"

# THE DIRECT WITNESS: the production store's HEAD did not move across this
# entire file's run — not "the stub was installed", but "production was
# provably untouched". Gracefully SKIPPED (never a silent pass, and never a
# hard failure of the tier) when dolt or the embedded-Dolt layout is
# unavailable, matching every DISARM path elsewhere in this task.
if [ "$BD_ISOLATION_ARMED" = "1" ]; then
    BD_ISOLATION_HASH_AFTER=$(cd "$BD_ISOLATION_STORE" 2>/dev/null \
        && dolt sql -r csv -q "SELECT hashof('HEAD')" 2>/dev/null | tail -n1)
    assert_eq "11.4 SPECIFIC: the production Beads store's HEAD is UNCHANGED across this entire file's run ($BD_STUB_CALL_COUNT stubbed bd invocation(s) were logged)" \
        "$BD_ISOLATION_HASH_BEFORE" "$BD_ISOLATION_HASH_AFTER"
else
    printf '  note: 11.4 SKIPPED - dolt not on PATH or %s has no embedded Dolt store; cannot read the production store HEAD to verify\n' "$BD_ISOLATION_STORE"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== model-roles.test.sh Summary ==="
printf 'Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'Failed tests:\n'
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0

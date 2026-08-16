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
# shellcheck disable=SC2016
assert_eq "6.3-META non-vacuity: the mutant no longer resolves designer to its own file" \
    "0" "$(grep -c 'designer)        printf' "$MUT6" || true)"
# shellcheck disable=SC2016
assert_eq "6.3-META non-vacuity: ...while the DESIGNER_AGENT constant survives" \
    "1" "$(grep -c '^DESIGNER_AGENT=' "$MUT6" || true)"

# SPECIFIC MISBEHAVIOUR: run the mutant over 6.1's exact configuration. The
# designer lane must now go UNWRITTEN — the mutant reads orchestrator.md's pin
# (already claude-fable-9), finds it equal to the desired id, and skips.
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

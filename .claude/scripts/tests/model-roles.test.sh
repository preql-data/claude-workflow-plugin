#!/bin/bash
# model-roles.test.sh — L1 unit tests for v4.0.0 Phase V1 role-aware model
# selection (claude-workflow-plugin-bi3.1).
#
# Everything here is offline and self-contained: each case builds a tempdir
# sandbox with the plugin scripts symlinked in and drives the real
# model-select.sh / workflow-model-apply.sh / statusline.sh against crafted
# .claude/model-roles + artifact fixtures. No network, no bd, no API key.
#
# Sections:
#   1. role_strategy parsing (via `model-select.sh roles`): valid /
#      whitespace-tolerant / unknown-strategy->top+warn / unknown-key-ignored
#      / missing-file->all-top.
#   2. reviewer_lane resolution (via `model-select.sh status`): config
#      default / claude force / env seam / codex-detect.sh probe deferral /
#      unknown-value->auto+warn.
#   3. workflow-model-apply.sh --print-role-map: covers all seven agents
#      exactly once and agrees with role_agents().
#   4. statusline role rendering: collapse (all-equal + lane=claude) vs
#      triple vs lane=codex `sol` vs artifact-absent fallback; short_id
#      shapes (date suffix stripped, [1m] preserved).
#   5. packaging parity: install.sh ships .claude/model-roles, install.ps1
#      carries the matching asset, and a META strip proves the check fails
#      when the copy line is removed.

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

# new_sandbox — print a fresh project-root path with the plugin scripts
# symlinked in and seven base-pinned agent files. Callers write their own
# .claude/model-roles / model-ranking / artifact fixtures.
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
# Unknown key is ignored; the three real roles still resolve from their keys.
ROLES_14=$(CLAUDE_PROJECT_DIR="$SB" bash "$MS" roles 2>/dev/null | awk -F'\t' '{print $1}' | sort | tr '\n' ',')
assert_eq "1.4 unknown key ignored (only the three roles reported)" \
    "implementer,orchestrator,reviewer," "$ROLES_14"
assert_eq "1.4 unknown key does not shadow a real role" "opus-class" "$(roles_strategy "$SB" orchestrator)"

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
EXPECTED_AGENTS=$(printf '%s\n' backend devops frontend grader judge orchestrator qa | sort)
assert_eq "3.1 print-role-map covers all seven agents exactly once" \
    "$EXPECTED_AGENTS" "$MAP_AGENTS"
assert_eq "3.1 print-role-map emits exactly seven lines" \
    "7" "$(printf '%s\n' "$MAP" | grep -c '	')"

# Each agent maps to the expected role class (matches role_agents()).
role_of() { printf '%s\n' "$MAP" | awk -F'\t' -v a="$1" '$2 == a { print $1 }'; }
assert_eq "3.2 orchestrator -> orchestrator" "orchestrator" "$(role_of orchestrator)"
assert_eq "3.2 backend -> implementer" "implementer" "$(role_of backend)"
assert_eq "3.2 frontend -> implementer" "implementer" "$(role_of frontend)"
assert_eq "3.2 devops -> implementer" "implementer" "$(role_of devops)"
assert_eq "3.2 qa -> reviewer" "reviewer" "$(role_of qa)"
assert_eq "3.2 grader -> reviewer" "reviewer" "$(role_of grader)"
assert_eq "3.2 judge -> reviewer" "reviewer" "$(role_of judge)"

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

# 4.3 Triple: roles differ, lane=claude -> orch/impl/rev shorts.
SB=$(new_sandbox)
printf '{"roles":{"orchestrator":"claude-fable-9","implementer":"claude-opus-5-0","reviewer":"claude-fable-9"},"reviewer_lane":"claude"}' \
    > "$SB/.claude/.qa-tracking/model-roles-resolved.json"
OUT_43=$(render_statusline "$SB")
assert_contains "4.3 triple renders role shorts" "• orch:fable-9 impl:opus-5-0 rev:fable-9" "$OUT_43"

# 4.4 lane=codex -> reviewer segment collapses to the literal `sol`, and an
# otherwise-collapsible (all-equal) mapping stays a triple.
SB=$(new_sandbox)
printf '{"roles":{"orchestrator":"claude-opus-4-8","implementer":"claude-opus-4-8","reviewer":"claude-opus-4-8"},"reviewer_lane":"codex"}' \
    > "$SB/.claude/.qa-tracking/model-roles-resolved.json"
OUT_44=$(render_statusline "$SB")
assert_contains "4.4 lane=codex renders rev:sol" "rev:sol" "$OUT_44"
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

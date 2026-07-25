#!/bin/bash
# model-roles-parity.sh — L2 component spec for v4.0.0 Phase V1 role-aware
# model selection (claude-workflow-plugin-bi3.1).
#
# The apply path rewrites each agent's `model:` frontmatter PER ROLE and
# writes the resolved mapping to model-roles-resolved.json. This spec proves
# the two stay in agreement: after an apply, every agent's frontmatter model
# equals artifact.roles[role_of(agent)], where role_of comes from the single
# source of truth `workflow-model-apply.sh --print-role-map`.
#
# Specs:
#   P1. Positive parity — an opus-class apply lands orchestrator/reviewer on
#       the top pick and implementer on the newest opus, and EVERY agent's
#       frontmatter matches its role's id in the artifact.
#   P2. all-`top` model-roles reproduces v3.5 lockstep — all seven agents
#       end on one identical id.
#   P3. META-TEST (required by the plan): a liar `pick_for_role` that
#       misroutes the implementer lane (returns the top pick instead of the
#       opus subset) makes the frontmatter diverge from the honest resolved
#       mapping, so the parity check MUST FAIL. Reuses the spec-I liar-wrapper
#       technique (source the real prefix, override, re-dispatch), TEXT-
#       anchored on `case "$SUBCMD" in`.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Exercises the full apply path (bd comment on the meta-task). Skip cleanly
# on BD_SHIM_ONLY CI.
bd_required_or_skip

MS="$FIXTURE/.claude/scripts/model-select.sh"
APPLY="$FIXTURE/.claude/scripts/workflow-model-apply.sh"
SL="$FIXTURE/.claude/scripts/statusline.sh"
CACHE="$FIXTURE/.claude/.qa-tracking/model-select-cache.json"
RANKING="$FIXTURE/.claude/model-ranking"
ROLES_FILE="$FIXTURE/.claude/model-roles"
ARTIFACT="$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json"
HONEST="$FIXTURE/.claude/.qa-tracking/honest-artifact.json"
AGENTS_DIR="$FIXTURE/.claude/agents"
META_PTR="$FIXTURE/.claude/.model-select-meta-task"

mkdir -p "$AGENTS_DIR"

# Tie-break-only ranking (no exclusions); opus is a first-class family.
cat > "$RANKING" <<'RANKING'
claude-opus
RANKING

# Seed all seven agents at a common base pin.
seed_agents() {
    local pin="$1" agent
    for agent in orchestrator qa backend frontend devops grader judge; do
        cat > "$AGENTS_DIR/$agent.md" <<EOF
---
name: $agent
description: stub
model: $pin
---
stub body for $agent
EOF
    done
}
seed_agents "claude-base-0"

cat > "$FIXTURE/.claude/settings.json" <<'JSON'
{
  "env": {
    "CLAUDE_LATEST_OPUS": "claude-base-0"
  }
}
JSON

# Curl shim helper (mirrors the model-select spec).
ms_set_curl_payload() {
    mk_shim "curl" "$FIXTURE" 0 "$1" >/dev/null
}

# LISTING_OPUS_PRESENT: fable-9 newest overall; opus-5-0 the newest opus.
LISTING_OPUS_PRESENT='{
  "data": [
    {"id":"claude-fable-9","max_input_tokens":1000000,"created_at":"2026-07-01T00:00:00Z","capabilities":{}},
    {"id":"claude-opus-5-0","max_input_tokens":400000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}},
    {"id":"claude-opus-4-8","max_input_tokens":200000,"created_at":"2026-05-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

export ANTHROPIC_API_KEY="sk-spec-fake"

# agent_pin <agent> — the model: frontmatter value.
agent_pin() {
    grep -E '^model:' "$AGENTS_DIR/$1.md" | head -1 | awk '{print $2}'
}

# check_parity <artifact-path> — return 0 when every agent's frontmatter
# model equals artifact.roles[role_of(agent)] (role_of from --print-role-map),
# 1 on any mismatch. This is the single checker reused by the positive
# assertion AND the META-TEST, so a green META proves the checker is
# sensitive to a real misroute (not vacuously passing).
check_parity() {
    local art="$1" role agent expected actual rc=0
    while IFS="$(printf '\t')" read -r role agent; do
        [ -z "$agent" ] && continue
        [ -f "$AGENTS_DIR/$agent.md" ] || continue
        expected=$(jq -r --arg r "$role" '.roles[$r] // empty' "$art" 2>/dev/null)
        actual=$(agent_pin "$agent")
        if [ "$expected" != "$actual" ]; then
            rc=1
        fi
    done <<EOF
$(bash "$APPLY" --print-role-map)
EOF
    return $rc
}

# ---------------------------------------------------------------------------
# Spec P1: positive parity after an opus-class apply.
# ---------------------------------------------------------------------------
cat > "$ROLES_FILE" <<'ROLES'
orchestrator=top
implementer=opus-class
reviewer=top
ROLES
rm -f "$CACHE" "$ARTIFACT" "$META_PTR"
seed_agents "claude-base-0"
ms_set_curl_payload "$LISTING_OPUS_PRESENT"
bash "$MS" apply --quiet 2>/dev/null >/dev/null

assert_eq "P1: orchestrator lands the top pick" "claude-fable-9" "$(agent_pin orchestrator)"
assert_eq "P1: implementer (backend) lands the newest opus" "claude-opus-5-0" "$(agent_pin backend)"
assert_eq "P1: reviewer (qa) lands the top pick" "claude-fable-9" "$(agent_pin qa)"

if check_parity "$ARTIFACT"; then
    PASS=$((PASS + 1))
    printf '  PASS: P1: every agent frontmatter matches artifact.roles[role_of(agent)]\n'
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("P1: parity check failed against the honest apply")
    printf '  FAIL: P1: parity check failed against the honest apply\n'
fi

# Snapshot the honest artifact for the META-TEST below.
cp "$ARTIFACT" "$HONEST"

# ---------------------------------------------------------------------------
# Spec P2: all-`top` model-roles reproduces v3.5 lockstep (all seven equal).
# ---------------------------------------------------------------------------
cat > "$ROLES_FILE" <<'ROLES'
orchestrator=top
implementer=top
reviewer=top
ROLES
rm -f "$CACHE" "$ARTIFACT"
seed_agents "claude-base-0"
ms_set_curl_payload "$LISTING_OPUS_PRESENT"
bash "$MS" apply --quiet 2>/dev/null >/dev/null

P2_ALL_EQUAL=1
P2_FIRST=$(agent_pin orchestrator)
for agent in qa backend frontend devops grader judge; do
    if [ "$(agent_pin "$agent")" != "$P2_FIRST" ]; then
        P2_ALL_EQUAL=0
    fi
done
assert_eq "P2: all-top pins every agent to one id (v3.5 lockstep)" "1" "$P2_ALL_EQUAL"
assert_eq "P2: the lockstep id is the top pick (fable-9)" "claude-fable-9" "$P2_FIRST"

# ---------------------------------------------------------------------------
# Spec P3: META-TEST — a liar pick_for_role misroutes the implementer lane.
#
# We restore the honest opus-class state (P1), then run a wrapper whose
# pick_for_role returns the TOP pick for EVERY strategy (so the implementer
# lane is misrouted to fable-9 instead of opus-5-0). The wrapper re-dispatches
# the REAL cmd_apply, so backend/frontend/devops are rewritten to fable-9.
# The parity check is then run against the HONEST snapshot (implementer=
# opus-5-0): the misrouted frontmatter diverges from it, so check_parity MUST
# return non-zero. If it does NOT, the parity assertion is not sensitive to a
# misroute — that is the regression this META-TEST guards.
# ---------------------------------------------------------------------------
cat > "$ROLES_FILE" <<'ROLES'
orchestrator=top
implementer=opus-class
reviewer=top
ROLES
rm -f "$CACHE" "$ARTIFACT"
# Restore the honest opus-class pins so the liar has a real delta to misroute.
seed_agents "claude-base-0"
ms_set_curl_payload "$LISTING_OPUS_PRESENT"
bash "$MS" apply --quiet 2>/dev/null >/dev/null
# (backend is now opus-5-0; orchestrator/qa are fable-9 — the honest state.)

LIAR="$FIXTURE/.claude/scripts/model-select-liar-role.sh"
cat > "$LIAR" <<'WRAP'
#!/bin/bash
# Wrapper: source the real model-select.sh prefix, then override
# pick_for_role to misroute EVERY role to the top pick (pick_best over the
# full listing). This corrupts the implementer (opus-class) lane while
# leaving the orchestrator/reviewer (top) lanes correct.
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
REAL_MS="$PROJECT_DIR/.claude/scripts/model-select.sh"

# TEXT-anchored cut at the dispatch block (identical technique to spec-I).
awk '/^case "\$SUBCMD" in$/{exit} {print}' "$REAL_MS" > "$PROJECT_DIR/.claude/scripts/.ms-role-prefix.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/.claude/scripts/.ms-role-prefix.sh"

# Liar override: ignore the strategy; always return the account-wide top
# pick. This is exactly a misrouted implementer lane.
pick_for_role() {
    local models="$1"
    [ -n "${ROLE_FALLBACK_FILE:-}" ] && printf 'false' > "$ROLE_FALLBACK_FILE"
    pick_best "$models"
}

case "${SUBCMD:-}" in
    resolve)  cmd_resolve ;;
    apply)    cmd_apply ;;
    status)   cmd_status ;;
    roles)    cmd_roles ;;
    *)        printf 'unknown subcommand\n' >&2; exit 2 ;;
esac
WRAP
chmod +x "$LIAR"

rm -f "$CACHE"
ms_set_curl_payload "$LISTING_OPUS_PRESENT"
bash "$LIAR" apply --quiet 2>/dev/null >/dev/null || true

# Sanity: the misroute actually landed — the implementer lane is now the top
# pick (fable-9), NOT the honest opus (opus-5-0).
assert_eq "P3: liar misrouted the implementer lane to the top pick" \
    "claude-fable-9" "$(agent_pin backend)"

# The META assertion: parity against the HONEST mapping MUST now fail.
if check_parity "$HONEST"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("P3: META-TEST — parity check PASSED against a misrouted apply (not sensitive)")
    printf '  FAIL: P3: META-TEST — parity check passed against a misrouted implementer lane; the check is NOT sensitive to misrouting\n'
else
    PASS=$((PASS + 1))
    printf '  PASS: P3: META-TEST — parity check correctly fails when the implementer lane is misrouted\n'
fi

# Closure: the orchestrator/reviewer lanes were NOT misrouted, so on their own
# they still match the honest mapping — proving P3's failure is specifically
# the implementer divergence, not a blanket mismatch.
assert_eq "P3 closure: orchestrator lane still honest (fable-9)" \
    "claude-fable-9" "$(agent_pin orchestrator)"
assert_eq "P3 closure: reviewer lane still honest (fable-9)" \
    "claude-fable-9" "$(agent_pin qa)"

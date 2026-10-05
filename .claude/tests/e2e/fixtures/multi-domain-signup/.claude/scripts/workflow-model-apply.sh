#!/bin/bash
# workflow-model-apply.sh — rewrite the model: pin across workflow agents
# and (for the implementer/all lanes) update env.CLAUDE_LATEST_OPUS in
# settings.json.
#
# Spec 0.3 (claude-workflow-plugin-e0d.3): the model-select.sh helper and
# the /workflow-model slash command both need the same idempotent rewrite
# step, so the logic lives here once and both call into it. /workflow-model
# stays a thin shell over this script; model-select.sh's apply path calls
# it once a better model has been resolved.
#
# v4.0.0 Phase V1 (claude-workflow-plugin-bi3.1): the flat agent list is
# now factored into ROLE CLASSES so model-select.sh can pin each class to a
# different model tier. The single-arg form still pins EVERY agent (the
# rollback path stays "pin everything"); the new --role form scopes the
# rewrite to one class.
#
# Usage:
#   workflow-model-apply.sh <new-model-id>
#       == `--role all <new-model-id>`. Rewrites every agent's model: line
#       and updates settings.json's env.CLAUDE_LATEST_OPUS. This is the
#       UNCHANGED single-arg / rollback contract: `/workflow-model <id>`
#       pins the whole workflow to <id>.
#
#   workflow-model-apply.sh --role <role> <new-model-id>
#       Rewrites only the agents in <role> (designer | design_reviewer |
#       orchestrator | implementer | reviewer | all). env.CLAUDE_LATEST_OPUS
#       is updated ONLY when the role is `all` or `implementer` (the env hint
#       now means "the implementer lane's current id").
#
#   workflow-model-apply.sh --print-role-map
#       Emit `role<TAB>agent` lines — one per agent, each agent exactly
#       once — the single source of truth for role->agent parity tests.
#
# Roles (v5.0.0 Phase D0 added the two design lanes):
#   designer        -> designer
#   design_reviewer -> design-reviewer
#   orchestrator    -> orchestrator
#   implementer     -> backend frontend devops
#   reviewer        -> qa grader judge
#   all             -> every agent (the nine above)
#
# NOTE the spelling split, which is deliberate and load-bearing: the ROLE is
# `design_reviewer` (underscore — it is a shell-safe key in .claude/model-roles
# and a JSON key in the resolved artifact) while the AGENT FILE is
# `design-reviewer.md` (hyphen — matching every other agent filename and the
# `@design-reviewer` invocation form). role_agents() is the only place the two
# meet.
#
# Exit codes:
#   0  rewrite completed (zero or more files actually changed; idempotent)
#   1  invalid arguments, invalid model id, or write failure
#
# Environment:
#   CLAUDE_PROJECT_DIR  project root (defaults to pwd). Same convention as
#                       every other hook script in the plugin.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

usage() {
    printf 'usage: %s <new-model-id>\n' "$(basename "$0")" >&2
    printf '       %s --role <designer|design_reviewer|orchestrator|implementer|reviewer|all> <new-model-id>\n' "$(basename "$0")" >&2
    printf '       %s --print-role-map\n' "$(basename "$0")" >&2
}

# role_agents <role> — print the agent basenames (one per line) that make
# up a role class. Returns non-zero for an unknown role. This is the single
# source of truth for the class->agent mapping; print_role_map and every
# per-role rewrite derive from it so a class change lands in one place.
#
# grader.md / judge.md were added in later phases, and designer.md /
# design-reviewer.md in v5.0.0; the rewrite loop tolerates a missing file, so
# listing them here is safe even before the files exist in a given install.
# CONCRETE_ROLES — the role classes that own agents, in the order
# print_role_map emits them. `all` is excluded: it is their UNION, not a class.
# Mirrors ALL_ROLES in model-select.sh; the two are kept in agreement by
# model-roles.test.sh section 3.
CONCRETE_ROLES="designer design_reviewer orchestrator implementer reviewer"

role_agents() {
    local r
    case "$1" in
        designer)        printf 'designer\n' ;;
        design_reviewer) printf 'design-reviewer\n' ;;
        orchestrator)    printf 'orchestrator\n' ;;
        implementer)     printf 'backend\nfrontend\ndevops\n' ;;
        reviewer)        printf 'qa\ngrader\njudge\n' ;;
        # `all` is DERIVED, never a second hand-maintained list. Through v4.1
        # it was spelled out, so every new agent had to be added in two arms
        # and the union was one edit away from disagreeing with the classes it
        # is supposed to be the union of.
        all)             for r in $CONCRETE_ROLES; do role_agents "$r"; done ;;
        *)               return 1 ;;
    esac
}

# print_role_map — emit `role<TAB>agent` for every agent across the concrete
# role classes, each agent exactly once. Derived directly from role_agents()
# so the map can never drift from the rewrite target set.
print_role_map() {
    local role agent
    for role in $CONCRETE_ROLES; do
        while IFS= read -r agent; do
            [ -z "$agent" ] && continue
            printf '%s\t%s\n' "$role" "$agent"
        done <<EOF
$(role_agents "$role")
EOF
    done
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
ROLE="all"
NEW_MODEL=""

case "${1:-}" in
    --print-role-map)
        print_role_map
        exit 0
        ;;
    --role)
        ROLE="${2:-}"
        NEW_MODEL="${3:-}"
        if [ -z "$ROLE" ] || [ -z "$NEW_MODEL" ]; then
            usage
            exit 1
        fi
        if ! role_agents "$ROLE" >/dev/null 2>&1; then
            printf 'Refusing: unknown role %q (want %s|all).\n' \
                "$ROLE" "$(printf '%s' "$CONCRETE_ROLES" | tr ' ' '|')" >&2
            exit 1
        fi
        ;;
    "")
        usage
        exit 1
        ;;
    --*)
        printf 'Refusing: unknown flag %q.\n' "$1" >&2
        usage
        exit 1
        ;;
    *)
        # Bare id — the UNCHANGED single-arg contract: pin everything.
        ROLE="all"
        NEW_MODEL="$1"
        ;;
esac

# Accept kebab-case ids plus the optional [1m] context-window suffix
# documented at /docs/en/model-config (e.g. claude-opus-4-8[1m]). Aliases
# like "opus" / "fable" / "best" are also kebab-case lowercase so they
# fall through the same regex.
if ! printf '%s' "$NEW_MODEL" | grep -Eq '^[a-z0-9][a-z0-9.-]*(\[1m\])?$'; then
    printf 'Refusing: %q does not look like a model id (need lowercase kebab-case, optional [1m] suffix).\n' "$NEW_MODEL" >&2
    exit 1
fi

# Resolve the target agent set for this role.
AGENTS=()
while IFS= read -r a; do
    [ -n "$a" ] && AGENTS+=("$a")
done <<EOF
$(role_agents "$ROLE")
EOF

CHANGED=0
SKIPPED=0
SKIPPED_NAMES=""

for agent in "${AGENTS[@]}"; do
    f="$PROJECT_DIR/.claude/agents/${agent}.md"
    if [ ! -f "$f" ]; then
        # A missing agent file is COUNTED, never name-tested (D0).
        #
        # Through v4.1 this arm read `if [ "$agent" != "grader" ] && [ "$agent"
        # != "judge" ]` — a hardcoded pair of "these two may legitimately be
        # absent" names. That list could only ever be right for the release
        # that wrote it: every agent shipped afterwards (designer,
        # design-reviewer) would have printed a scary per-file `skip:` line on
        # every pre-upgrade install, and every agent RETIRED afterwards would
        # have kept its silence forever.
        #
        # So the loop no longer judges WHICH absence is expected. It counts
        # them and prints ONE summary line naming all of them, below. The
        # operator gets strictly more information, and the check has nothing
        # left to go stale.
        SKIPPED=$((SKIPPED + 1))
        SKIPPED_NAMES="${SKIPPED_NAMES:+$SKIPPED_NAMES, }$agent"
        continue
    fi
    OLD=$(grep -E '^model:' "$f" | head -1 | awk '{print $2}')
    if [ "$OLD" = "$NEW_MODEL" ]; then
        printf 'unchanged: %s (already %s)\n' "$agent" "$NEW_MODEL"
        continue
    fi
    # Cross-platform sed-equivalent via awk: rewrite the first model:
    # frontmatter line, then move atomically.
    if ! awk -v new="$NEW_MODEL" '
        /^model:/ && !done { print "model: " new; done=1; next }
        { print }
    ' "$f" > "$f.tmp"; then
        printf 'error: failed to rewrite %s\n' "$f" >&2
        rm -f "$f.tmp"
        exit 1
    fi
    mv "$f.tmp" "$f"
    printf 'updated: %s: %s -> %s\n' "$agent" "${OLD:-<none>}" "$NEW_MODEL"
    CHANGED=$((CHANGED + 1))
done

# Settings.json env hint. CLAUDE_LATEST_OPUS retains its historical name
# but its meaning is now "latest opus-class = the implementer lane". We
# therefore refresh it only when the rewrite covered the implementer lane
# (role `all` or role `implementer`); an orchestrator- or reviewer-scoped
# rewrite leaves the opus hint alone.
if [ "$ROLE" = "all" ] || [ "$ROLE" = "implementer" ]; then
    SETTINGS="$PROJECT_DIR/.claude/settings.json"
    if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
        OLD_HINT=$(jq -r '.env.CLAUDE_LATEST_OPUS // ""' "$SETTINGS")
        if [ "$OLD_HINT" != "$NEW_MODEL" ]; then
            if ! jq --arg m "$NEW_MODEL" '.env.CLAUDE_LATEST_OPUS = $m' "$SETTINGS" > "$SETTINGS.tmp"; then
                printf 'error: jq failed to update %s\n' "$SETTINGS" >&2
                rm -f "$SETTINGS.tmp"
                exit 1
            fi
            mv "$SETTINGS.tmp" "$SETTINGS"
            printf 'updated: settings.json env.CLAUDE_LATEST_OPUS: %s -> %s\n' \
                "${OLD_HINT:-<none>}" "$NEW_MODEL"
        fi
    fi
fi

if [ "$SKIPPED" -gt 0 ]; then
    printf 'skipped: %d agent file(s) not present (%s)\n' "$SKIPPED" "$SKIPPED_NAMES"
fi
printf '\nSummary: %d agent file(s) updated to %s (role: %s).\n' "$CHANGED" "$NEW_MODEL" "$ROLE"
exit 0

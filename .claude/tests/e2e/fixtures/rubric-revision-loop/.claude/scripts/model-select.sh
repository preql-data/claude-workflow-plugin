#!/bin/bash
# model-select.sh — automatic best-model selection (spec 0.3 + hotfix vlp.1
# + v4.0.0 Phase V1 role-aware resolution / bi3.1).
#
# Resolves the best model available to this account, ranks it against
# .claude/model-ranking, and (in the `apply` path) rewrites each agent's
# model: pin PER ROLE via the shared workflow-model-apply.sh helper.
#
# Role-aware resolution (V1, expanded to FIVE roles by v5.0.0 Phase D0):
#   .claude/model-roles maps each role to a strategy. The roles are
#   designer, design_reviewer, orchestrator, implementer and reviewer —
#   enumerated ONCE, in ALL_ROLES. A strategy is `top` (the single best pick,
#   exactly v3.5) or `<family>-class` (the newest claude-<family>-* in the
#   listing, auto-adopting the next generation of that family the moment the
#   account lists it). `resolve` still prints the account-wide top pick;
#   `apply` resolves every role and rewrites each lane independently; the
#   resolved mapping is written to
#   .claude/.qa-tracking/model-roles-resolved.json (schema 2) for the
#   statusline.
#
#   Two surfaces are NOT roles and never appear under `roles` in the artifact:
#   `implementer_class_high` (the per-unit escalation strategy, resolved
#   through the same path and recorded under `escalation`) and the two lane
#   keys (`reviewer_lane`, `design_reviewer_lane`), which decide WHICH
#   reviewer is engaged, never what any frontmatter pin says.
#
# Subcommands:
#   resolve [--quiet] [--refresh]
#       Print "<model-id>\t<source>" on stdout (source is one of
#       "cache","api"). This is the account-wide TOP pick (role-agnostic),
#       preserved for the smoke path and backward-compat. Returns 0 if a
#       model was resolved or the operator wanted a fail-open warning; exits
#       0 either way so SessionStart never blocks on an enumeration failure
#       (spec principle: "never block the session"). On fail-open, the
#       message goes to stderr and stdout is empty. --refresh bypasses the
#       cache and forces an API round-trip (no-op without an API key).
#
#   apply [--quiet] [--refresh] [--check]
#       Resolve ALL THREE roles first; if a role's resolved id differs from
#       that lane's current pin, invoke workflow-model-apply.sh --role and
#       record a role-tagged switch on the standing "Model selection log"
#       Beads meta-task. All-or-nothing on a manual-adopt/no-candidate
#       listing (keep every pin, no artifact). Quiet suppresses per-file
#       rewrite chatter; the one-line summary still prints. --refresh
#       bypasses the cache (same semantics as resolve).
#
#       --check (claude-workflow-plugin-j7kk, B2, R4-F1 ruling): DETECT AND
#       WARN, never write. Runs the identical resolution (including the
#       resolved-mapping artifact, which is workflow bookkeeping under
#       .claude/.qa-tracking/ — never a tracked file — so recording it is not
#       what R4-F1 forbids), but the per-role step compares current_pin()
#       against the resolved pick instead of calling workflow-model-apply.sh.
#       Any disagreement is named in the ONE summary line session-start.sh's
#       `tail -1 model-select:` collapse surfaces, together with the
#       `/workflow-model --role <role> <id>` command that applies it. This is
#       what SessionStart calls; the write path above is reachable only by an
#       explicit invocation without --check (a human/agent running this
#       script directly, or /workflow-model for a single role). Filed
#       defect: four TRACKED files (three agent .md + settings.json) were
#       rewritten by the OLD unconditional auto-apply mid an unrelated open
#       change set, sharing one mtime, claimed by no files_changed list.
#
#   status
#       Print the per-role table (role, strategy, pinned id, resolved id),
#       cache state, reviewer lane, and any intra-role lockstep drift.
#
#   roles
#       Print "role\tstrategy\tresolved-id" (strategy from model-roles,
#       resolved id from the resolved-mapping artifact).
#
# Caching:
#   .claude/.qa-tracking/model-select-cache.json
#     { "timestamp": <unix-ts>, "models": [ { "id":..., "max_input_tokens":..., "created_at":... }, ... ] }
#   TTL is 3600s. A stale cache is ignored (we refresh); a missing cache
#   triggers an API fetch. --refresh ignores TTL outright.
#
# Ranking semantics (hotfix vlp.1; capability-class fix en9):
#   `.claude/model-ranking` is an EXCLUSION list plus a CAPABILITY-TIER
#   order. Lines starting with `!` are exclusion patterns ("!claude-haiku"
#   drops every id whose family prefix is `claude-haiku-`) and are applied
#   FIRST, before any ranking. Every other line is a family prefix, listed
#   best-tier-first (fable > mythos > opus > sonnet > haiku today); a
#   candidate's position in that list is its capability CLASS. The picker
#   still does NOT restrict candidates to ranked families: an UNKNOWN
#   family is given the TOP class, so a newly-launched tier above Fable
#   still wins on recency without editing this file (day-zero adoption).
#
# Sort (primary -> tertiary) — en9:
#   1. capability class ASC (ranking-file tier position; unknown family =
#      top class). A KNOWN lower-tier family NEVER outranks a known
#      higher-tier family however much newer it is. That was the en9
#      defect: with recency primary, claude-opus-5 (2026-07-24) displaced
#      claude-fable-5 (2026-06-07) as `top` and dragged the orchestrator
#      and reviewer lanes onto Opus, collapsing the v4 role split.
#   2. created_at DESC (newest first WITHIN the class; parsed ISO 8601).
#   3. max_input_tokens DESC (larger context wins on a date tie).
#   Residual (deliberate, documented): a brand-new family name that is
#   really BELOW Fable also lands in the top class and would win on
#   recency. The "new family/families in listing" warning names every
#   unknown family so the operator can place it in the tier order or drop
#   it with `!<family>`.
#   When a winner's created_at is missing or unparseable, the helper
#   emits a LOUD notice naming the id and the `/workflow-model <id>`
#   adopt command — and refuses to auto-adopt. The session keeps the
#   current pin until the operator runs the adopt command explicitly.
#   Because class outranks recency, a TOP-class entry with an unparseable
#   created_at now beats a well-formed LOWER-class entry and so takes that
#   manual-adopt path instead of silently falling through to the lower
#   tier — loud-and-unchanged beats a silent downgrade.
#
# pick_best stdout contract (defect 3fn fix — never silent stale pin):
#   Happy path:        `<id>\n`
#   Manual-adopt path: `MANUAL\t<id>\n`
#   The MANUAL prefix is parsed by every caller — cmd_apply uses it to
#   short-circuit BEFORE current-pin comparison or rewrite; cmd_resolve
#   strips it and prints the id (so the operator sees "what *would*
#   be picked"); cmd_status surfaces the qualifier on its cached-best
#   line. We do NOT use a parent-shell global because pick_best is
#   always invoked via `$(...)` command substitution and a subshell
#   variable assignment is invisible to the parent — encoding the
#   signal on stdout is the only channel that survives the subshell.
#
# Fail-open contract (spec 0.3 principle 1):
#   - No ANTHROPIC_API_KEY and no fresh cache: emit warning, exit 0.
#   - curl failure / timeout: emit warning, exit 0.
#   - empty model list / no candidates after exclusion: emit warning, exit 0.
#   - unparseable created_at on winner: emit loud manual-adopt notice, exit 0.
#   - Never trigger inference, drift, or any paid call on switch.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CACHE_FILE="$PROJECT_DIR/.claude/.qa-tracking/model-select-cache.json"
CACHE_TTL_SECONDS=3600
RANKING_FILE="$PROJECT_DIR/.claude/model-ranking"
META_TASK_FILE="$PROJECT_DIR/.claude/.model-select-meta-task"
APPLY_HELPER="$PROJECT_DIR/.claude/scripts/workflow-model-apply.sh"
ORCH_AGENT="$PROJECT_DIR/.claude/agents/orchestrator.md"

# v4.0.0 Phase V1 (bi3.1): role-aware resolution surfaces.
IMPL_AGENT="$PROJECT_DIR/.claude/agents/backend.md"   # implementer lane representative
REVIEWER_AGENT="$PROJECT_DIR/.claude/agents/qa.md"    # reviewer lane representative
# v5.0.0 Phase D0 (fkm.2): the two design lanes. Each role in ALL_ROLES MUST
# have a representative-file constant AND an explicit arm in current_pin() —
# see the hazard note on that function.
DESIGNER_AGENT="$PROJECT_DIR/.claude/agents/designer.md"
DESIGN_REVIEWER_AGENT="$PROJECT_DIR/.claude/agents/design-reviewer.md"
MODEL_ROLES_FILE="$PROJECT_DIR/.claude/model-roles"
ROLES_ARTIFACT="$PROJECT_DIR/.claude/.qa-tracking/model-roles-resolved.json"
CODEX_DETECT="$PROJECT_DIR/.claude/scripts/codex-detect.sh"

# ALL_ROLES — the role set, defined ONCE. cmd_status, cmd_roles and cmd_apply
# all iterate this; adding a sixth role means editing this line, adding a
# current_pin() arm, and adding a workflow-model-apply.sh role_agents() arm.
# Nothing else enumerates roles.
#
# ORDER IS LOAD-BEARING for the statusline: it is the fixed render order
# `des dsr orch impl rev`.
#
# `implementer_class_high` is deliberately ABSENT. It is a STRATEGY, not a
# role: it owns no agent files and must never appear under `roles` in the
# artifact, because specs/model-roles-parity.sh's check_parity walks
# `--print-role-map` and would look for an agent file to match it.
ALL_ROLES="designer design_reviewer orchestrator implementer reviewer"

# The escalation strategy key. Not a role (see ALL_ROLES).
ESCALATION_KEY="implementer_class_high"
ESCALATION_STATE="$PROJECT_DIR/.claude/.qa-tracking/implementer-escalation.json"
COLLAPSE_FLAG="$PROJECT_DIR/.claude/.qa-tracking/design-family-collapse"
# Filesystem side-channel: pick_for_role writes "true"/"false" here so
# cmd_apply can read the implementer opus-class fallback flag across the
# $(...) subshell boundary (a shell variable set inside command
# substitution never propagates to the parent — the same subshell-loss
# constraint that shaped pick_best's MANUAL stdout contract). Empty by
# default so pick_for_role is a silent no-op writer outside apply.
ROLE_FALLBACK_FILE=""

QUIET=0
REFRESH=0
CHECK_ONLY=0
SUBCMD="${1:-}"
shift || true

# ARG1 — the first NON-FLAG positional after the subcommand. `escalate` needs
# a task id; every other subcommand ignores it. Unknown flags stay ignored (the
# pre-D0 contract) so a future flag added to one subcommand cannot break the
# others.
#
# --check (claude-workflow-plugin-j7kk, B2): a GLOBAL flag, parsed here like
# --quiet/--refresh, but only cmd_apply reads it. Kept global rather than
# apply-specific so the "unknown flags are ignored" contract stays true of
# every other subcommand that sees it on its argv (none currently do, but
# nothing has to change here if one starts to).
ARG1=""
while [ "${1:-}" != "" ]; do
    case "$1" in
        --quiet|-q) QUIET=1 ;;
        --refresh)  REFRESH=1 ;;
        --check)    CHECK_ONLY=1 ;;
        --*)        ;;  # ignore unknown flags
        *)          [ -z "$ARG1" ] && ARG1="$1" ;;
    esac
    shift
done

# Manual-adopt signal traveling between pick_best and its callers.
# History (defect 3fn): a parent-shell global was tried first and lost
# every time because pick_best is always invoked via `$(...)` command
# substitution — Bash subshell assignments don't propagate. We now
# encode the signal as a `MANUAL\t<id>` stdout prefix from pick_best;
# callers parse the prefix. See the file-header contract for details.

# Logging helpers: stderr only (stdout is reserved for resolved values).
#
# Spec 0.3 requires SessionStart to surface a one-line "model-select:
# <result>" message even in the quiet path. We therefore distinguish:
#   _result — always prints (the canonical outcome line; one per run);
#   _warn   — always prints (diagnostic; would be a no-op to hide).
# A fail-open outcome IS the result, and the operator needs to see it
# even when invoked with --quiet. The --quiet flag only suppresses the
# per-file rewrite chatter inside cmd_apply.
_result() {
    printf 'model-select: %s\n' "$1" >&2
}
_warn() {
    printf 'model-select: %s\n' "$1" >&2
}

# ---------------------------------------------------------------------------
# Cache helpers.
# ---------------------------------------------------------------------------

# now_s — current unix timestamp; portable across BSD and GNU date.
now_s() { date +%s; }

# cache_age_s — seconds since cache was written, or -1 when absent.
cache_age_s() {
    if [ ! -f "$CACHE_FILE" ]; then
        printf '%s' "-1"
        return
    fi
    local ts
    ts=$(jq -r '.timestamp // 0' "$CACHE_FILE" 2>/dev/null)
    if [ -z "$ts" ] || [ "$ts" = "0" ]; then
        printf '%s' "-1"
        return
    fi
    printf '%s' "$(( $(now_s) - ts ))"
}

# cache_fresh — exit 0 if cache exists, parses, and is within TTL.
# --refresh forces this to return non-zero so get_models falls through to
# the API path. We deliberately treat --refresh as "ignore cache" rather
# than "delete cache" so a fail-open after --refresh can still surface the
# stale entries with the "using stale cache" warning if the API call
# fails — the operator should never lose state because they asked for a
# refresh that the network couldn't deliver.
cache_fresh() {
    [ "$REFRESH" = "1" ] && return 1
    local age
    age=$(cache_age_s)
    [ "$age" -ge 0 ] && [ "$age" -lt "$CACHE_TTL_SECONDS" ]
}

# write_cache <json-models-array>
write_cache() {
    local models="$1"
    mkdir -p "$(dirname "$CACHE_FILE")"
    local ts
    ts=$(now_s)
    if ! printf '%s' "$models" | jq --argjson ts "$ts" '{timestamp:$ts, models:.}' > "$CACHE_FILE.tmp" 2>/dev/null; then
        rm -f "$CACHE_FILE.tmp"
        return 1
    fi
    mv "$CACHE_FILE.tmp" "$CACHE_FILE"
}

# read_cache_models — print the cached models array on stdout, or empty.
read_cache_models() {
    [ -f "$CACHE_FILE" ] || { printf '[]'; return; }
    jq -c '.models // []' "$CACHE_FILE" 2>/dev/null || printf '[]'
}

# ---------------------------------------------------------------------------
# Enumeration.
# ---------------------------------------------------------------------------

# fetch_models_from_api — GET /v1/models, print models array on stdout,
# return non-zero on failure. Honors $ANTHROPIC_API_KEY. Bounded by a
# 5-second hard timeout per curl spec.
fetch_models_from_api() {
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        return 2  # distinct from network failure: caller decides messaging
    fi
    local raw
    # --silent so an HTTP 401 / 429 doesn't spam the SessionStart context.
    # We pull the body; on any parse failure we treat it as a soft failure.
    raw=$(curl --silent --show-error --max-time 5 \
        -H "X-Api-Key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        "https://api.anthropic.com/v1/models?limit=1000" 2>/dev/null)
    if [ -z "$raw" ]; then
        return 1
    fi
    # Validate shape: must have .data array.
    if ! printf '%s' "$raw" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
        return 1
    fi
    # Project the fields we need. context_window comes from max_input_tokens
    # per the /v1/models response shape.
    printf '%s' "$raw" | jq -c '[.data[] | {id, max_input_tokens, created_at, capabilities}]'
    return 0
}

# get_models — print the models array on stdout. Reads cache when fresh,
# refreshes via API otherwise. Returns 0 with stdout when a list is
# available, 2 when no API key is set and no cache exists, 1 when the
# API call failed and no cache exists. Callers use the exit code to
# emit the right diagnostic on fail-open.
get_models() {
    if cache_fresh; then
        read_cache_models
        return 0
    fi
    local fetched rc
    fetched=$(fetch_models_from_api)
    rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$fetched" ]; then
        write_cache "$fetched" || _warn "failed to write cache"
        printf '%s' "$fetched"
        return 0
    fi
    # API failed or no key. If a stale cache exists, use it rather than
    # blocking — stale data beats no data on a flaky network.
    if [ -f "$CACHE_FILE" ]; then
        _warn "using stale model cache (api fetch unavailable)"
        read_cache_models
        return 0
    fi
    # Propagate the no-key (2) vs network-failure (1) distinction so the
    # caller's diagnostic line matches reality.
    return "$rc"
}

# ---------------------------------------------------------------------------
# Ranking (hotfix vlp.1: exclusion + tertiary tie-break, no family-gating).
# ---------------------------------------------------------------------------

# load_ranking_raw — print every non-empty, non-comment line from the
# ranking file in file order. Includes any leading `!` so callers can
# split exclusions from tie-break entries.
load_ranking_raw() {
    [ -f "$RANKING_FILE" ] || return 0
    sed -E -e 's/#.*$//' -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
        "$RANKING_FILE" | grep -v '^$'
}

# load_exclusions — print one family prefix per line, in file order,
# stripped of the leading `!`. Lines without `!` are skipped.
load_exclusions() {
    load_ranking_raw | awk '/^!/{sub(/^!/, ""); print}'
}

# load_tiers — print one family prefix per line, in file order, of the
# non-exclusion entries. File order IS the capability-tier order (best
# first): a line's index is the class pick_best sorts on FIRST (en9).
# They still do not restrict candidate selection — an id matching no
# prefix is an unknown family and gets the TOP class (see pick_best).
load_tiers() {
    load_ranking_raw | grep -v '^!'
}

# pick_best <models-json> — print the best id on stdout, return 0 on
# success. Returns 1 when no candidate survives the exclusion + sort.
#
# Stdout contract (defect 3fn fix):
#   Happy path:        `<id>\n`
#   Manual-adopt path: `MANUAL\t<id>\n`
# Manual-adopt fires when the winner's created_at is missing or
# unparseable. cmd_apply parses the `MANUAL\t` prefix to refuse the
# auto-rewrite; cmd_resolve strips it and prints the id; cmd_status
# surfaces a qualifier on the cached-best line. A parent-shell global
# is NOT used because pick_best is always invoked via `$(...)` and
# Bash subshell assignments do not propagate.
#
# Algorithm (hotfix vlp.1; capability-class primary since en9):
#   1. Drop entries whose id starts with any "!<excl>-" prefix from the
#      ranking file. Exclusions are applied FIRST, before any ranking.
#   2. Sort surviving entries by:
#        primary:   capability class ASC — the index of the first
#                   ranking-file tier prefix the id matches (fable=0,
#                   mythos=1, opus=2, sonnet=3, haiku=4 with the shipped
#                   file). An id matching NO tier prefix is an unknown
#                   family and gets class 0, the same class as the top
#                   tier, so it competes for the win on recency.
#        secondary: created_at DESC within the class (parsed as ISO 8601;
#                   unparseable gets -1 so it sorts to the bottom of its
#                   class — but if it ends up the winner anyway, the
#                   MANUAL prefix is emitted on stdout and the apply path
#                   refuses auto-rewrite).
#        tertiary:  max_input_tokens DESC (larger context wins on a tie).
#   3. Emit the head's id (with the MANUAL prefix when appropriate).
#
# Why class is primary (en9): the tri-model design wants `top` to be the
# newest model in the MOST CAPABLE family, not the newest model overall.
# With recency primary, claude-opus-5 (2026-07-24) beat claude-fable-5
# (2026-06-07) and the orchestrator + reviewer lanes silently collapsed
# onto the implementer's Opus lane.
#
# We still deliberately DO NOT family-gate. Unknown families are
# first-class candidates AT THE TOP CLASS, so a newly-launched tier above
# the listed families wins by recency without an edit to the ranking file.
# The residual — an unknown family that is actually BELOW Fable also
# lands in the top class — is handled by the operator: the helper
# unknown_families_warning() names every unknown family and `!<family>`
# excludes it. The file-header doc covers this trade-off in full.
pick_best() {
    local models="$1"

    local exclusions_json tiers_json
    exclusions_json=$(load_exclusions | jq -R -s -c 'split("\n") | map(select(length>0))')
    tiers_json=$(load_tiers | jq -R -s -c 'split("\n") | map(select(length>0))')

    # Single-pass jq:
    #   - Filter out excluded ids (any id starting with "<excl>-").
    #   - Annotate each with _class (capability tier: the index of the
    #     first ranking-file tier prefix the id matches, or 0 — the TOP
    #     class — for an unknown family), _ts (created_at parsed to epoch
    #     via fromdate?, or -1 when missing/unparseable) and _ctx
    #     (max_input_tokens).
    #   - Sort by _class ASC, then _ts DESC, then _ctx DESC (en9: class is
    #     PRIMARY so a newer LOWER-tier family can never take the top lane;
    #     recency only decides inside a class, which is where day-zero
    #     adoption of a new top-class family happens).
    #   - Emit the head (or null when no candidates).
    local pick
    pick=$(jq -n -c \
        --argjson models "$models" \
        --argjson excludes "$exclusions_json" \
        --argjson tiers "$tiers_json" '
        def class_for($id; $tiers):
            # Bind each tier entry as $e before the pipe — `.value` inside
            # a `select($id | ...)` body would be evaluated against $id (a
            # string), tripping "Cannot index string with string". The
            # `as $e` binding scopes the lookup outside the pipe.
            #
            # No match -> 0. jq only treats null/false as falsy, so a
            # genuine index of 0 (the top tier) survives the `//` intact;
            # only the null from an empty match list falls through. That
            # is the en9 unknown-family rule: an unrecognised family is
            # ranked WITH the top tier and wins on recency, never below a
            # known lower tier.
            ($tiers | to_entries
             | map(. as $e | select($id | startswith($e.value + "-")))
             | (first | .key) // 0);

        def excluded($id; $excludes):
            ($excludes | any(. as $e | $id | startswith($e + "-")));

        ($models // [])
        | map(select(excluded(.id; $excludes) | not))
        | map(. + {
            _class: class_for(.id; $tiers),
            _ts: ((.created_at // "")
                  | if . == "" then -1
                    else (fromdate? // -1)
                    end),
            _ctx: (.max_input_tokens // 0)
          })
        | sort_by([._class, -(._ts), -(._ctx)])
        | (first // null)
    ' 2>/dev/null)

    if [ -z "$pick" ] || [ "$pick" = "null" ]; then
        local seen
        seen=$(printf '%s' "$models" | jq -r '[.[].id | capture("^(?<fam>claude-[a-z]+)").fam] | unique | join(",")' 2>/dev/null)
        if [ -n "$seen" ]; then
            _warn "no candidates after applying ranking exclusions. Families seen in listing: $seen. Review $RANKING_FILE."
        else
            _warn "no candidates after applying ranking exclusions and no recognisable model ids in listing."
        fi
        return 1
    fi

    local picked_id picked_ts
    picked_id=$(printf '%s' "$pick" | jq -r '.id')
    picked_ts=$(printf '%s' "$pick" | jq -r '._ts')

    # Unparseable created_at on the winner -> loud notice + MANUAL stdout
    # prefix. The apply path parses the prefix and refuses to rewrite;
    # the resolve path strips the prefix and prints the id so the
    # operator can see what would have been picked. We use a tab
    # separator so the parse is unambiguous even if some future id ever
    # contains the literal "MANUAL" substring; "MANUAL\t" can never
    # collide with a model id, which is restricted to [a-z0-9-]+.
    if [ -z "$picked_ts" ] || [ "$picked_ts" = "-1" ] || [ "$picked_ts" = "null" ]; then
        _warn "winner '$picked_id' has missing/unparseable created_at; manual adoption required: /workflow-model $picked_id"
        printf 'MANUAL\t%s\n' "$picked_id"
        return 0
    fi

    printf '%s\n' "$picked_id"
}

# unknown_families_warning <models-json> — surface families seen in the
# listing that are NOT in the ranking file's tier list (exclusions are
# omitted from this check; an explicitly-excluded family is intentional).
# This is the "brand-new family is here, you may want to place it in the
# tier order" affordance — it never blocks selection. Under the en9
# contract an unknown family is ranked in the TOP capability class, so it
# is SELECTED automatically as soon as it is newer than the top tier
# (day-zero adoption). That is also the residual this warning exists to
# cover: a new family that is really BELOW Fable gets the same top class,
# so the operator needs to see the name to either place it in the tier
# list or drop it with `!<family>`.
unknown_families_warning() {
    local models="$1"
    local tiers excluded
    tiers=$(load_tiers)
    excluded=$(load_exclusions)
    [ -n "$tiers$excluded" ] || return 0
    local listed
    listed=$(printf '%s' "$models" | jq -r '[.[].id | capture("^(?<fam>claude-[a-z]+)").fam] | unique | .[]' 2>/dev/null)
    [ -n "$listed" ] || return 0
    local unknown=""
    local fam
    while IFS= read -r fam; do
        [ -z "$fam" ] && continue
        # Known if the family appears either as a tier or an exclusion.
        if ! printf '%s\n' "$tiers" | grep -qx "$fam" \
            && ! printf '%s\n' "$excluded" | grep -qx "$fam"; then
            unknown="${unknown:+$unknown,}$fam"
        fi
    done <<EOF
$listed
EOF
    if [ -n "$unknown" ]; then
        _warn "new family/families in listing (ranked in the TOP capability class, so they are selected as soon as they are newer than the top tier — add to $RANKING_FILE to place them in the tier order, or exclude with '!<family>'): $unknown"
    fi
}

# ---------------------------------------------------------------------------
# Role-aware resolution (v4.0.0 Phase V1 / bi3.1).
# ---------------------------------------------------------------------------

# _model_roles_value <key> — print the raw value for a key= line in
# .claude/model-roles, whitespace-tolerant around the `=`. Empty when the
# file or key is absent. Mirrors the rubric-config parse discipline.
_model_roles_value() {
    local key="$1"
    [ -f "$MODEL_ROLES_FILE" ] || return 0
    # Strip comments, trim, match "key = value", print the value.
    sed -E -e 's/#.*$//' "$MODEL_ROLES_FILE" 2>/dev/null \
        | grep -E "^[[:space:]]*${key}[[:space:]]*=" \
        | head -1 \
        | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/[[:space:]]+$//"
}

# STRATEGY_CLASS_RE — the family-class strategy grammar (v5.0.0 / D0).
#
# Before D0 the only class strategy was the LITERAL `opus-class`, spelled out
# in the enum, in the pick_for_role jq filter and in two warnings. That literal
# is now ONE rule: any `<family>-class` where <family> is a lowercase
# alphanumeric token. `opus-class`, `sonnet-class`, `fable-class`,
# `haiku-class` and every family shipped in the future parse from it with no
# edit here.
#
# The family is NOT validated against .claude/model-ranking. Gating selection
# on the tier list would kill day-zero adoption of a new family — the exact
# property pick_best:class_for() exists to preserve (an unknown family is
# ranked in the TOP class, proven by ms-T3). The cost of not gating is that a
# typo (`sonnnet-class`) resolves to an empty subset and silently falls back to
# `top`; pick_for_role's empty-subset warning therefore adds a
# "not a known tier — check for a typo" hint when the family is absent from
# BOTH the tier list and the exclusion list. Diagnostic, never a gate.
STRATEGY_CLASS_RE='^[a-z][a-z0-9]*-class$'

# role_strategy <role> — resolve a role (or the escalation key) to its
# selection strategy (`top` | `<family>-class`). Fail-open: a missing file or
# missing key is the quiet v3.5-parity default of `top`; a PRESENT-but-
# unrecognised value is a surprising misconfiguration, so that path warns
# loudly before falling back to `top`.
role_strategy() {
    local role="$1" val
    val=$(_model_roles_value "$role")
    case "$val" in
        top) printf 'top' ;;
        "")  printf 'top' ;;   # missing key/file: quiet v3.5 default
        *)
            if printf '%s' "$val" | grep -Eq "$STRATEGY_CLASS_RE"; then
                printf '%s' "$val"
            else
                _warn "unknown strategy '$val' for role '$role' in $MODEL_ROLES_FILE; falling back to top"
                printf 'top'
            fi
            ;;
    esac
}

# _family_known <family> — exit 0 when `claude-<family>` appears in the ranking
# file as either a capability tier or an exclusion. An EXCLUDED family counts
# as known: `!claude-haiku` is the operator saying they know about haiku and
# dropped it deliberately, which is not a typo.
_family_known() {
    local fam="$1"
    if load_tiers | grep -qx "claude-$fam"; then
        return 0
    fi
    if load_exclusions | grep -qx "claude-$fam"; then
        return 0
    fi
    return 1
}

# _typo_hint <family> — the trailing clause appended to the empty-subset
# warning when the family is in neither ranking list. Empty otherwise.
_typo_hint() {
    local fam="$1"
    if _family_known "$fam"; then
        printf ''
    else
        printf " (claude-%s is not a known tier in %s — check for a typo)" \
            "$fam" "$RANKING_FILE"
    fi
}

# _lane_config <key> — read a lane key (auto|claude), default auto. An
# unrecognised value warns and falls back to auto. Shared by reviewer_lane and
# design_reviewer_lane so the two can never drift in parse semantics.
_lane_config() {
    local key="$1" val
    val=$(_model_roles_value "$key")
    case "$val" in
        auto|claude) printf '%s' "$val" ;;
        "")          printf 'auto' ;;
        *)
            _warn "unknown $key '$val' in $MODEL_ROLES_FILE; falling back to auto"
            printf 'auto'
            ;;
    esac
}

# reviewer_lane_config — read the reviewer_lane key (auto|claude), default
# auto. An unrecognised value warns and falls back to auto.
reviewer_lane_config() {
    _lane_config "reviewer_lane"
}

# design_reviewer_lane_config — the design lane's equivalent (v5.0.0 / D0).
design_reviewer_lane_config() {
    _lane_config "design_reviewer_lane"
}

# ---------------------------------------------------------------------------
# Codex probe memoisation (v5.0.0 / D0).
#
# Two lanes now consult .claude/scripts/codex-detect.sh. The probe must run
# ONCE PER INVOCATION, not once per lane — it shells out, and doubling that on
# every SessionStart is a cost with no information in it.
#
# CALL THIS AS A STATEMENT, NOT INSIDE $(...). A subshell assignment never
# propagates to its parent (the same Bash constraint that shaped pick_best's
# MANUAL stdout contract — see the file header), so the memo is only shared
# when the probe runs in a shell that is an ANCESTOR of both `$(detect_*)`
# substitutions. cmd_apply and cmd_status therefore prime it explicitly before
# resolving lanes. Each detect_* function still primes it itself, so a caller
# that forgets is CORRECT and merely pays for two probes.
#
# The prime is UNCONDITIONAL, which costs one probe on the paths where an env
# seam or `<lane>=claude` would have short-circuited it. That is deliberate:
# the alternative is re-deriving each lane's precedence rules at the call site
# to decide whether a probe could be needed, which duplicates the logic these
# functions own (and would emit a second warning for a bad lane value). One
# bounded, exit-0-by-contract probe per invocation is the cheaper trade. The
# outer bound is unchanged and still lives at the caller: session-start.sh
# wraps the whole `apply` in `timeout 8`.
# ---------------------------------------------------------------------------
_CODEX_PROBE_STATE="unrun"
_CODEX_PROBE_VALUE=""

_codex_probe_once() {
    [ "$_CODEX_PROBE_STATE" = "done" ] && return 0
    _CODEX_PROBE_STATE="done"
    _CODEX_PROBE_VALUE=""
    if [ -x "$CODEX_DETECT" ]; then
        _CODEX_PROBE_VALUE=$(bash "$CODEX_DETECT" 2>/dev/null || true)
    fi
    return 0
}

# detect_reviewer_lane — resolve the effective reviewer lane. Never blocks;
# never runs in the statusline. Precedence:
#   (a) WORKFLOW_REVIEWER_LANE env non-empty -> use verbatim (test/operator seam).
#   (b) model-roles reviewer_lane=claude     -> claude (force the Claude path).
#   (c) executable .claude/scripts/codex-detect.sh (ships V2) -> defer to it.
#   (d) otherwise                            -> claude (V1 default).
# The reviewer agents always carry a Claude model: pin regardless of lane;
# the lane only decides which reviewer is engaged and how the statusline
# renders (claude vs the literal `sol`).
detect_reviewer_lane() {
    if [ -n "${WORKFLOW_REVIEWER_LANE:-}" ]; then
        printf '%s' "$WORKFLOW_REVIEWER_LANE"
        return
    fi
    if [ "$(reviewer_lane_config)" = "claude" ]; then
        printf 'claude'
        return
    fi
    _codex_probe_once
    if [ -n "$_CODEX_PROBE_VALUE" ]; then
        printf '%s' "$_CODEX_PROBE_VALUE"
        return
    fi
    printf 'claude'
}

# detect_design_reviewer_lane — the design lane's equivalent (v5.0.0 / D0).
# Identical precedence with the design keys/env seam. Sol-first is already what
# `auto` means, so no separate ordering rule is needed.
#
# Like the reviewer lane, this NEVER changes a frontmatter pin: design-reviewer
# agents always carry a Claude `model:` pin, and the lane decides only which
# reviewer is engaged and how the statusline renders (`claude` vs `sol`).
detect_design_reviewer_lane() {
    if [ -n "${WORKFLOW_DESIGN_REVIEWER_LANE:-}" ]; then
        printf '%s' "$WORKFLOW_DESIGN_REVIEWER_LANE"
        return
    fi
    if [ "$(design_reviewer_lane_config)" = "claude" ]; then
        printf 'claude'
        return
    fi
    _codex_probe_once
    if [ -n "$_CODEX_PROBE_VALUE" ]; then
        printf '%s' "$_CODEX_PROBE_VALUE"
        return
    fi
    printf 'claude'
}

# pick_for_role <models-json> <strategy> — resolve one role's best id,
# preserving pick_best's stdout contract (`<id>` | `MANUAL\t<id>` | rc=1).
#
#   top             -> pick_best over the full listing (unchanged).
#   <family>-class  -> pick_best over the claude-<family>-* subset. Ranking
#                      exclusions still apply (pick_best applies them inside
#                      the subset). An empty subset OR a fully-excluded subset
#                      warns and falls back to pick_best over the full listing.
#
# The family is derived from the strategy (`family="${strategy%-class}"`,
# `prefix="claude-$family-"`) rather than matched against an enum, so
# `sonnet-class` / `fable-class` / `haiku-class` and every future family work
# with no edit here. See STRATEGY_CLASS_RE for why the family is not validated
# against the ranking file and what replaces that validation.
#
# When ROLE_FALLBACK_FILE is set, writes "true" on the class fallback path and
# "false" otherwise so cmd_apply can record the per-role fallback flag in the
# artifact (see the constant's comment for the subshell rationale).
pick_for_role() {
    local models="$1" strategy="$2"
    case "$strategy" in
        top)
            [ -n "$ROLE_FALLBACK_FILE" ] && printf 'false' > "$ROLE_FALLBACK_FILE"
            pick_best "$models"
            ;;
        *-class)
            local family prefix subset n
            family="${strategy%-class}"
            prefix="claude-$family-"
            subset=$(printf '%s' "$models" \
                | jq -c --arg p "$prefix" '[.[] | select(.id | startswith($p))]' 2>/dev/null)
            n=$(printf '%s' "$subset" | jq -r 'length' 2>/dev/null)
            if [ -z "$n" ] || [ "$n" = "0" ]; then
                _warn "no ${prefix}* model in listing; '$strategy' falls back to top$(_typo_hint "$family")"
                [ -n "$ROLE_FALLBACK_FILE" ] && printf 'true' > "$ROLE_FALLBACK_FILE"
                pick_best "$models"
                return
            fi
            local sub_pick sub_rc
            sub_pick=$(pick_best "$subset")
            sub_rc=$?
            if [ "$sub_rc" -ne 0 ] || [ -z "$sub_pick" ]; then
                _warn "all ${prefix}* models excluded by ranking; '$strategy' falls back to top"
                [ -n "$ROLE_FALLBACK_FILE" ] && printf 'true' > "$ROLE_FALLBACK_FILE"
                pick_best "$models"
                return
            fi
            [ -n "$ROLE_FALLBACK_FILE" ] && printf 'false' > "$ROLE_FALLBACK_FILE"
            printf '%s\n' "$sub_pick"
            ;;
        *)
            # Unreachable via role_strategy (which returns `top` or a value
            # matching STRATEGY_CLASS_RE). Kept so a direct caller with a
            # malformed strategy degrades to the fail-open default rather than
            # falling out of the case with no output.
            [ -n "$ROLE_FALLBACK_FILE" ] && printf 'false' > "$ROLE_FALLBACK_FILE"
            pick_best "$models"
            ;;
    esac
}

# _missing_role_keys — print the space-separated subset of the config keys this
# install's .claude/model-roles does NOT carry.
#
# WHY THIS EXISTS (correction 14). `.claude/model-roles` is manifest class
# `operator`, so an install whose copy was EDITED receives the v5 defaults as a
# `.claude/model-roles.new` SIDECAR and keeps running its old key set — which
# on a v4 install means no `designer`, no `design_reviewer`, no
# `implementer_class_high`, and `implementer=opus-class`. Every one of those
# fails OPEN (a missing key is `top`), so nothing errors and nothing is
# visible. This list is what makes it visible: it rides the artifact, the
# statusline reads the rest of the artifact anyway, and session-start.sh turns
# it into a one-line warning naming the sidecar.
_missing_role_keys() {
    local k out=""
    for k in $ALL_ROLES "$ESCALATION_KEY"; do
        if [ -z "$(_model_roles_value "$k")" ]; then
            out="${out:+$out }$k"
        fi
    done
    printf '%s' "$out"
}

# write_roles_artifact — atomically write the resolved-mapping artifact
# (SCHEMA 2, v5.0.0 / D0).
#
# Args:
#   $1 tsv    path to a `role<TAB>strategy<TAB>pick<TAB>fallback` file, one
#             line per role, in ALL_ROLES order
#   $2 reviewer_lane   $3 design_reviewer_lane
#   $4 implementer_fallback (json bool)
#   $5 escalation_strategy  $6 escalation_resolved
#   $7 identity_collapse    (json bool)
#   $8 missing_keys         (space-separated; may be empty)
#   $9 listing source
#
# The nine flat variables schema 1 used are gone: five roles x three fields
# would have been fifteen. The TSV is built by ONE loop in cmd_apply and
# consumed by ONE jq pass here — bash 3.2 is the floor, so no associative
# arrays.
#
# `implementer_fallback` is RETAINED as a top-level boolean even though
# `fallbacks.implementer` now carries the same fact: ms-R1 and ms-R2 assert on
# the top-level key, and a schema bump is not a licence to break the readers
# that motivated the field.
#
# On any failure the previous artifact is left untouched (stale-beats-none).
write_roles_artifact() {
    local tsv="$1" rlane="$2" dlane="$3" fb="$4" escs="$5" escr="$6" \
          collapse="$7" missing="$8" src="$9"
    mkdir -p "$(dirname "$ROLES_ARTIFACT")"
    local ts missing_json
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    missing_json=$(printf '%s' "$missing" \
        | jq -R -c 'split(" ") | map(select(length > 0))' 2>/dev/null) \
        || missing_json='[]'
    [ -n "$missing_json" ] || missing_json='[]'
    if jq -R -s \
        --arg ts "$ts" --arg src "$src" \
        --arg rlane "$rlane" --arg dlane "$dlane" \
        --argjson fb "$fb" \
        --arg escs "$escs" --arg escr "$escr" \
        --argjson collapse "$collapse" \
        --argjson missing "$missing_json" \
        '
        [ split("\n")[] | select(length > 0) | split("\t") ] as $rows
        | { schema: 2,
            resolved_at: $ts,
            listing_source: $src,
            roles:      ($rows | map({key: .[0], value: .[2]}) | from_entries),
            strategies: ($rows | map({key: .[0], value: .[1]}) | from_entries),
            fallbacks:  ($rows | map({key: .[0], value: (.[3] == "true")}) | from_entries),
            implementer_fallback: $fb,
            reviewer_lane: $rlane,
            design_reviewer_lane: $dlane,
            escalation: { strategy: $escs, resolved: $escr },
            identity_collapse: $collapse,
            missing_keys: $missing }
        ' < "$tsv" > "$ROLES_ARTIFACT.tmp" 2>/dev/null; then
        mv "$ROLES_ARTIFACT.tmp" "$ROLES_ARTIFACT"
    else
        rm -f "$ROLES_ARTIFACT.tmp"
        _warn "failed to write $ROLES_ARTIFACT (kept previous artifact)"
    fi
}

# ---------------------------------------------------------------------------
# Pin reading.
# ---------------------------------------------------------------------------

# current_pin [role] — read model: from a representative agent file for the
# given role. Roles map to one representative file each (the whole class is
# kept in lockstep by workflow-model-apply.sh --role, so reading one member
# is enough). The no-arg form defaults to `orchestrator` — that preserves
# the pre-V1 contract (current_pin == orchestrator pin) for any caller or
# test wrapper that invokes it without a role.
#
# EVERY ROLE IN ALL_ROLES NEEDS AN ARM HERE, AND THE CATCH-ALL WARNS.
#
# Through v4.1 the last arm was `orchestrator|*)`, a SILENT catch-all, and it
# is the sharpest hazard D0 had to disarm. A role with no arm read
# orchestrator.md's pin, so _apply_role compared the NEW lane's desired model
# against the ORCHESTRATOR's current one, found them equal on the common case
# where both resolve to `top`, and returned 1 — "no switch needed". No error,
# no warning, exit 0. Both design lanes would have reported as pinned and never
# been written, and the only observable would have been a switch count one or
# two lower than expected in a line nobody diffs.
#
# So `orchestrator` is now its own arm and `*)` is a loud fallback. It still
# reads the orchestrator file (fail-open: a diagnostic must not make the
# resolver stop resolving) but it says so, and the message names the failure
# mode rather than the symptom. Guarded by model-roles.test.sh section 6,
# whose reddening mutation deletes the `designer)` arm from a copy and asserts
# the copy reads orchestrator.md's pin for the designer role.
# _role_agent_file <role> — the path of the role's representative agent file.
# Extracted so current_pin (which READS the pin) and _apply_role (which decides
# whether the lane is present at all) resolve it through one arm set. Two
# copies of this case statement is exactly the drift the catch-all note below
# is about.
_role_agent_file() {
    local role="$1"
    case "$role" in
        designer)        printf '%s' "$DESIGNER_AGENT" ;;
        design_reviewer) printf '%s' "$DESIGN_REVIEWER_AGENT" ;;
        orchestrator)    printf '%s' "$ORCH_AGENT" ;;
        implementer)     printf '%s' "$IMPL_AGENT" ;;
        reviewer)        printf '%s' "$REVIEWER_AGENT" ;;
        *)
            _warn "role '$role' has no representative agent file; falling back to the orchestrator's. A role missing an arm here reads ANOTHER lane's pin, so _apply_role can compare it against the wrong current value and skip that lane's rewrite with no error. Add an arm to _role_agent_file() in $0."
            printf '%s' "$ORCH_AGENT"
            ;;
    esac
}

current_pin() {
    local role="${1:-orchestrator}"
    local f
    f=$(_role_agent_file "$role")
    [ -f "$f" ] || return 0
    grep -E '^model:' "$f" | head -1 | awk '{print $2}'
}

# ---------------------------------------------------------------------------
# Meta-task helpers.
# ---------------------------------------------------------------------------

# find_or_create_meta_task — print the meta-task id on stdout. Uses
# .claude/.model-select-meta-task as a memoised pointer; creates the task
# via bd create when neither the pointer nor a title match exists.
find_or_create_meta_task() {
    if ! command -v bd >/dev/null 2>&1; then
        return 1
    fi
    if [ -f "$META_TASK_FILE" ]; then
        local cached
        cached=$(cat "$META_TASK_FILE" 2>/dev/null)
        if [ -n "$cached" ] && bd show "$cached" >/dev/null 2>&1; then
            printf '%s' "$cached"
            return 0
        fi
    fi
    # Look up by title before creating to avoid duplicates on re-init.
    local existing
    existing=$(bd list --json 2>/dev/null \
        | jq -r '[.[] | select(.title == "Model selection log") | .id] | first // empty' 2>/dev/null)
    if [ -n "$existing" ]; then
        printf '%s' "$existing" > "$META_TASK_FILE"
        printf '%s' "$existing"
        return 0
    fi
    # Create. Use a meta label and priority 4 (lowest) so this doesn't
    # surface in `bd ready` queries.
    local created
    created=$(bd create "Model selection log" -t task -p 4 -l meta \
        -d "Audit log of automatic model switches performed by model-select.sh (spec 0.3). Each comment records old pin, new pin, timestamp, and rollback command." \
        --json 2>/dev/null \
        | jq -r '.id // empty' 2>/dev/null)
    if [ -z "$created" ]; then
        return 1
    fi
    printf '%s' "$created" > "$META_TASK_FILE"
    printf '%s' "$created"
}

# record_switch <old> <new> — write a comment on the meta-task with the
# old->new transition plus the rollback /workflow-model line. The V1 apply
# path uses record_switch_role below; this un-tagged variant is retained
# for the manual /workflow-model flow and for the model-select spec's
# stripped/liar wrappers, which source this file's prefix and invoke it
# indirectly (hence the SC2329 suppression — it is NOT dead code).
# shellcheck disable=SC2329
record_switch() {
    local old="$1" new="$2"
    local meta
    meta=$(find_or_create_meta_task) || return 0  # silent fail; not fatal
    [ -z "$meta" ] && return 0
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comment "$meta" "MODEL SWITCH ${old:-<none>} -> $new
Timestamp: $ts
Rollback: /workflow-model ${old:-<unknown>}
Source: SessionStart (.claude/scripts/model-select.sh apply)" >/dev/null 2>&1 || true
}

# record_switch_role <role> <old> <new> — role-tagged variant of
# record_switch. The rollback line carries the `--role <role>` scope so
# reverting one lane doesn't disturb the others.
record_switch_role() {
    local role="$1" old="$2" new="$3"
    local meta
    meta=$(find_or_create_meta_task) || return 0  # silent fail; not fatal
    [ -z "$meta" ] && return 0
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd comment "$meta" "MODEL SWITCH [$role] ${old:-<none>} -> $new
Timestamp: $ts
Rollback: /workflow-model --role $role ${old:-<unknown>}
Source: SessionStart (.claude/scripts/model-select.sh apply)" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Subcommand: resolve.
# ---------------------------------------------------------------------------

cmd_resolve() {
    local models rc
    models=$(get_models)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$rc" in
            2) _result "no ANTHROPIC_API_KEY set and no cached model list; keeping current pin" ;;
            *) _result "model listing unavailable (api fetch failed; no cache); keeping current pin" ;;
        esac
        return 0
    fi
    unknown_families_warning "$models"
    local raw_best best
    raw_best=$(pick_best "$models") || { _result "ranking produced no candidate"; return 0; }
    # pick_best may emit "MANUAL\t<id>" on the manual-adopt path. The
    # resolve contract is "tell me what would have been picked" — we
    # strip the prefix and print the id. The LOUD notice already fired
    # via stderr inside pick_best, so the operator still sees the
    # manual-adopt instruction. See file-header stdout contract.
    case "$raw_best" in
        MANUAL$'\t'*) best="${raw_best#MANUAL$'\t'}" ;;
        *)            best="$raw_best" ;;
    esac
    local source="api"
    cache_fresh && source="cache"
    printf '%s\t%s\n' "$best" "$source"
}

# ---------------------------------------------------------------------------
# Subcommand: apply.
# ---------------------------------------------------------------------------

# _apply_role <role> <new-id> — rewrite one lane when its representative
# pin differs from <new-id>, and record a role-tagged switch. Honors QUIET for
# the per-file rewrite chatter.
#
# THE EXIT STATUS IS AN INTERFACE, NOT A BOOLEAN (QA R1-F5). It returned 1 for
# three outcomes that are not interchangeable, and both escalate and restore
# read that 1 as "already there":
#
#   0  switched  the rewrite ran and the pin moved.
#   1  no-op     the lane is already at <new-id>. Nothing to do, nothing wrong.
#   2  skipped   no representative agent file — the lane does not exist here.
#                NOTHING was rewritten; the helper was never called.
#   3  failed    the helper ran and FAILED. The pin did not move, and a
#                multi-file class may have moved PARTIALLY.
#
# Measured on the shipped code before the fix: with a helper that exits 1,
# `restore` printed "rewrite helper failed for role implementer" and then
# "restore: implementer lane already at claude-sonnet-7 (no rewrite needed)"
# — while the pin was still claude-opus-5-0 — and deleted the escalation
# record, leaving a lane that `restore` could no longer put back. Deleting a
# record on the strength of a failure is the part that made it unrecoverable,
# and a status that cannot tell a failure from a no-op is what let it.
#
# cmd_apply's `_apply_role … && switched=$((switched + 1))` is unaffected: it
# counts only 0, and 1/2/3 are all "did not switch" there.
_apply_role() {
    local role="$1" new="$2" cur apply_out f

    # A LANE WHOSE REPRESENTATIVE AGENT FILE DOES NOT EXIST IS SKIPPED
    # ENTIRELY — no rewrite, no switch count, no audit comment.
    #
    # Without this the lane PHANTOM-SWITCHES on every single run. current_pin
    # returns EMPTY for a missing file, so `"" != "$new"` holds forever: the
    # helper is invoked (it skips the missing file and exits 0), the switch is
    # counted, and a `MODEL SWITCH [<role>] <none> -> <id>` comment is written
    # to the meta-task. The file never appears, so it repeats at every
    # SessionStart — an unbounded stream of audit entries for a rewrite that
    # never happened, and a switch count that never reaches zero.
    #
    # D0 made this reachable: designer.md / design-reviewer.md legitimately do
    # not exist on a v4 install being upgraded, or on any install rendered
    # before this release. It was latent for implementer/reviewer too (a
    # missing backend.md or qa.md would do the same), and install.sh
    # hard-requiring those five is the only reason it was never seen.
    #
    # Caught by ms-G's `(0 switched)` assertion: an apply where every existing
    # pin already matched reported `(2 switched)`.
    f=$(_role_agent_file "$role")
    if [ ! -f "$f" ]; then
        [ "$QUIET" -ne 1 ] && _warn "skipping role '$role': no agent file at $f (nothing to pin)"
        return 2
    fi

    cur=$(current_pin "$role")
    if [ "$cur" = "$new" ]; then
        return 1
    fi
    if ! apply_out=$(bash "$APPLY_HELPER" --role "$role" "$new" 2>&1); then
        _result "rewrite helper failed for role $role (kept pin ${cur:-<none>})"
        [ "$QUIET" -ne 1 ] && printf '%s\n' "$apply_out" >&2
        return 3
    fi
    [ "$QUIET" -ne 1 ] && printf '%s\n' "$apply_out" >&2
    record_switch_role "$role" "$cur" "$new"
    return 0
}

# _scratch_path <label> — a writable scratch path, preferring mktemp and
# falling back inside .claude/.qa-tracking when TMPDIR is unusable. Shared by
# the fallback side-channel and the role TSV so both degrade the same way.
_scratch_path() {
    local label="$1" p
    p=$(mktemp "${TMPDIR:-/tmp}/model-roles-$label.XXXXXX" 2>/dev/null || true)
    if [ -z "$p" ]; then
        mkdir -p "$PROJECT_DIR/.claude/.qa-tracking" 2>/dev/null || true
        p="$PROJECT_DIR/.claude/.qa-tracking/.model-roles-$label"
    fi
    printf '%s' "$p"
}

cmd_apply() {
    local models rc
    models=$(get_models)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$rc" in
            2) _result "no ANTHROPIC_API_KEY set and no cached model list; keeping current pin" ;;
            *) _result "model listing unavailable (api fetch failed; no cache); keeping current pin" ;;
        esac
        return 0
    fi
    unknown_families_warning "$models"

    # ONE loop over ALL_ROLES resolves every lane into a TSV
    # (`role<TAB>strategy<TAB>pick<TAB>fallback`), and ONE jq pass turns that
    # into the artifact. v4.1 carried nine flat variables for three roles; five
    # roles would have been fifteen, and bash 3.2 (the floor) has no
    # associative arrays. Adding a sixth role now costs one word in ALL_ROLES.
    #
    # Resolution happens for EVERY role BEFORE any pin is touched, unchanged
    # from V1: the manual-adopt gate is all-or-nothing, so a partially-bogus
    # listing must never leave the lanes straddling model generations.
    ROLE_FALLBACK_FILE=$(_scratch_path fb)
    : > "$ROLE_FALLBACK_FILE" 2>/dev/null || true
    local tsv
    tsv=$(_scratch_path tsv)
    : > "$tsv" 2>/dev/null || true

    # Prime the codex probe HERE, in the parent shell, so both
    # $(detect_*_lane) subshells below inherit the memo and the probe shells
    # out once per invocation rather than once per lane.
    _codex_probe_once

    local role strat pick fb pick_id
    local manual=0 no_candidate=0 impl_fallback="false"
    local designer_pick="" design_reviewer_pick=""
    for role in $ALL_ROLES; do
        strat=$(role_strategy "$role")
        : > "$ROLE_FALLBACK_FILE" 2>/dev/null || true
        pick=$(pick_for_role "$models" "$strat")
        fb=$(cat "$ROLE_FALLBACK_FILE" 2>/dev/null || printf 'false')
        [ -n "$fb" ] || fb="false"
        [ "$role" = "implementer" ] && impl_fallback="$fb"

        # pick_best's MANUAL path prefixes the id with `MANUAL<TAB>`, and a TAB
        # inside a TSV cell would silently shift every later column. Strip it
        # here and carry the flag in $manual instead; the MANUAL path bails
        # before the artifact is written, so the stripped row is never
        # serialised.
        case "$pick" in
            MANUAL$'\t'*)
                manual=1
                pick_id="${pick#MANUAL$'\t'}"
                _result "manual adoption required for $role '$pick_id' — run /workflow-model --role $role $pick_id"
                ;;
            "")
                no_candidate=1
                pick_id=""
                ;;
            *) pick_id="$pick" ;;
        esac
        [ "$role" = "designer" ]        && designer_pick="$pick_id"
        [ "$role" = "design_reviewer" ] && design_reviewer_pick="$pick_id"
        printf '%s\t%s\t%s\t%s\n' "$role" "$strat" "$pick_id" "$fb" >> "$tsv"
    done

    # Escalation (v5.0.0 / D0). Resolved through the SAME role_strategy +
    # pick_for_role path so it can never drift from the lanes, but recorded
    # under `escalation` rather than `roles`: it owns no agent files, so a
    # roles[] entry would make check_parity look for one.
    local esc_strat esc_pick
    esc_strat=$(role_strategy "$ESCALATION_KEY")
    : > "$ROLE_FALLBACK_FILE" 2>/dev/null || true
    esc_pick=$(pick_for_role "$models" "$esc_strat")
    case "$esc_pick" in
        MANUAL$'\t'*) esc_pick="${esc_pick#MANUAL$'\t'}" ;;
    esac

    rm -f "$ROLE_FALLBACK_FILE" 2>/dev/null || true
    ROLE_FALLBACK_FILE=""

    # No-candidate on ANY role -> fail-open, keep every pin, no artifact.
    if [ "$no_candidate" -eq 1 ]; then
        rm -f "$tsv" 2>/dev/null || true
        _result "ranking produced no candidate for one or more roles; keeping current pin"
        return 0
    fi

    if [ "$manual" -eq 1 ]; then
        rm -f "$tsv" 2>/dev/null || true
        _result "manual adoption required for one or more roles; keeping ALL pins unchanged (no artifact written)"
        return 0
    fi

    if [ ! -x "$APPLY_HELPER" ]; then
        rm -f "$tsv" 2>/dev/null || true
        _result "missing apply helper at $APPLY_HELPER; skipping rewrite"
        return 0
    fi

    local lane dlane source
    lane=$(detect_reviewer_lane)
    dlane=$(detect_design_reviewer_lane)
    source="api"; cache_fresh && source="cache"

    # IDENTITY COLLAPSE (decision 3): the designer and its reviewer resolving
    # to one identity is a LOUD WARNING plus flags, never a block — a block
    # would make the Codex-absent arm unrunnable, which is the whole fallback
    # path. Condition: identical resolved id AND the design lane is `claude`.
    # On the Sol lane the reviewing identity is not a Claude model at all, so
    # equal Claude pins do not collapse anything.
    #
    # On a stock install without Codex, `designer` and `design_reviewer` are
    # both `top` and this flag is therefore PERMANENTLY LIT. That is a known
    # consequence of the locked default, documented with its two clearances in
    # the .claude/model-roles header (install Codex, or set
    # design_reviewer=<family>-class).
    local collapse="false"
    if [ -n "$designer_pick" ] && [ "$designer_pick" = "$design_reviewer_pick" ] \
        && [ "$dlane" = "claude" ]; then
        collapse="true"
        _warn "identity collapse: designer and design_reviewer both resolve to '$designer_pick' on the claude design lane, so a design would be reviewed by its own model identity. Pins are still written and the session is NOT blocked. Clear it by installing Codex (design_reviewer_lane=auto then resolves to the Sol lane) or by setting design_reviewer to a family-class distinct from top in $MODEL_ROLES_FILE."
    fi
    mkdir -p "$(dirname "$COLLAPSE_FLAG")" 2>/dev/null || true
    if [ "$collapse" = "true" ]; then
        printf 'designer=%s design_reviewer=%s design_reviewer_lane=%s\n' \
            "$designer_pick" "$design_reviewer_pick" "$dlane" > "$COLLAPSE_FLAG" 2>/dev/null || true
    else
        rm -f "$COLLAPSE_FLAG" 2>/dev/null || true
    fi

    # Persist the resolved mapping atomically BEFORE the rewrites (a rewrite
    # crash still leaves a truthful artifact of intent; fail-open paths above
    # leave the previous artifact untouched — stale beats none).
    write_roles_artifact "$tsv" "$lane" "$dlane" "$impl_fallback" \
        "$esc_strat" "$esc_pick" "$collapse" "$(_missing_role_keys)" "$source"

    # Per-role apply, driven by the same TSV. Reading the picks back from the
    # file the artifact was written from means the rewrite and the artifact
    # cannot disagree about what was resolved.
    #
    # claude-workflow-plugin-j7kk (B2, R4-F1 ruling): CHECK_ONLY branches this
    # loop between WRITE (unchanged: _apply_role, exactly as every existing
    # caller of `apply` without --check still gets) and DETECT-AND-WARN
    # (current_pin() vs the resolved pick, compared, never written). An EMPTY
    # current_pin (missing agent file) is not drift to report — it is
    # _apply_role's own "nothing to pin" case, kept consistent here so
    # --check and the write path agree about what counts as a lane worth
    # naming.
    local switched=0 summary="" drifted=""
    while IFS="$(printf '\t')" read -r role strat pick fb; do
        [ -n "$role" ] || continue
        summary="${summary:+$summary }$role=$pick"
        if [ "$CHECK_ONLY" -eq 1 ]; then
            local cur
            cur=$(current_pin "$role")
            if [ -n "$cur" ] && [ "$cur" != "$pick" ]; then
                drifted="${drifted:+$drifted; }$role: agent file has '$cur', config resolves '$pick' (apply: /workflow-model --role $role $pick)"
            fi
        else
            _apply_role "$role" "$pick" && switched=$((switched + 1))
        fi
    done < "$tsv"
    rm -f "$tsv" 2>/dev/null || true

    local lane_note=""
    [ "$lane" != "claude" ] && lane_note=" reviewer_lane=$lane"
    [ "$dlane" != "claude" ] && lane_note="$lane_note design_reviewer_lane=$dlane"
    [ "$collapse" = "true" ] && lane_note="$lane_note identity_collapse=true"
    if [ "$CHECK_ONLY" -eq 1 ]; then
        # ONE _result call, deliberately never a separate _warn: session-
        # start.sh keeps only the LAST "model-select:"-prefixed stderr line
        # ("keep the most recent line so a chain of warnings collapses to
        # one"), so the drift detail has to BE that line, not a warning
        # printed before a summary line that would eclipse it.
        if [ -n "$drifted" ]; then
            _result "resolver drift (config vs applied pins) — NOTHING auto-applied (R4-F1): $drifted"
        else
            _result "roles: $summary${lane_note} (check-only: applied pins already match the config; 0 written)"
        fi
        return 0
    fi
    _result "roles: $summary${lane_note} ($switched switched)"
}

# ---------------------------------------------------------------------------
# Subcommands: escalate / restore (per-unit implementer escalation, D0).
#
# WHAT THIS IS, EXACTLY. A design unit may declare `implementer_class: high`;
# that declaration is mechanised as the Beads label `impl-class-high`, and the
# label is the ONLY machine surface. `escalate` resolves the
# `implementer_class_high` strategy through the same role_strategy +
# pick_for_role path the lanes use, records the intent, and repins the
# implementer lane. `restore` puts the previous pin back.
#
# WHAT THIS IS NOT. Whether the Claude Code runtime honours a frontmatter
# `model:` change made MID-SESSION is not established anywhere in this tree and
# cannot be verified offline. So the claim this makes — in tests, in docs, in
# release notes — is exactly: a declared, audited, reversible pin change. Never
# "the unit ran on Opus."
#
# WHY IT IS NOT WIRED INTO qa-gate.sh. The gate stays free of model concerns.
# `.claude/scripts/tests/reviewer-lane-structural.test.sh` (hoisted from
# `reviewer-lane-degradation.sh`'s structural half, claude-workflow-plugin-icn4
# item 1 — that L2 file still carries the behavioural half) already asserts
# zero codex/reviewer-lane references — ANY spelling, not just the historical
# dot/underscore-only reading a prior version of this pattern used
# (claude-workflow-plugin-mruw) — in the three gate scripts for the same
# reason: a gate that reasons about model selection acquires a second,
# invisible way to refuse.
#
# CRASH SELF-HEALS THREE WAYS: session-end.sh calls `restore` best-effort, the
# next SessionStart `cmd_apply` rewrites the implementer lane from the resolved
# artifact regardless of the escalation state, and `restore` is idempotent so
# an operator can always run it by hand.
# ---------------------------------------------------------------------------

cmd_escalate() {
    local task="$ARG1"
    if [ -z "$task" ]; then
        _result "escalate: missing <task-id> (usage: model-select.sh escalate <task-id>)"
        return 0
    fi

    local models rc
    models=$(get_models)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        _result "escalate: model listing unavailable; keeping the current implementer pin"
        return 0
    fi

    local strat pick
    strat=$(role_strategy "$ESCALATION_KEY")
    pick=$(pick_for_role "$models" "$strat")
    case "$pick" in
        MANUAL$'\t'*)
            _result "escalate: winner '${pick#MANUAL$'\t'}' needs manual adoption; keeping the current implementer pin"
            return 0
            ;;
        "")
            _result "escalate: ranking produced no candidate for '$strat'; keeping the current implementer pin"
            return 0
            ;;
    esac

    local cur
    cur=$(current_pin implementer)

    # IDEMPOTENT. Re-escalating the same task to the same id is a no-op, and
    # must NOT overwrite previous_pin — doing so would record the escalated id
    # as the thing to restore to, and `restore` would then be a no-op forever.
    if [ -f "$ESCALATION_STATE" ] && command -v jq >/dev/null 2>&1; then
        local prev_task prev_res
        prev_task=$(jq -r '.task_id // empty' "$ESCALATION_STATE" 2>/dev/null || true)
        prev_res=$(jq -r '.resolved // empty' "$ESCALATION_STATE" 2>/dev/null || true)
        if [ "$prev_task" = "$task" ] && [ "$prev_res" = "$pick" ] && [ "$cur" = "$pick" ]; then
            _result "escalate: '$task' already escalated to $pick (no change)"
            return 0
        fi
    fi

    if [ ! -x "$APPLY_HELPER" ]; then
        _result "escalate: missing apply helper at $APPLY_HELPER; skipping rewrite"
        return 0
    fi

    # previous_pin IS THE PRE-ESCALATION PIN, NOT "WHATEVER THE PIN IS NOW"
    # (QA R1-F5). The idempotency guard above only catches a re-escalation of
    # the SAME task to the SAME id; escalating a DIFFERENT task while one is
    # live fell through to here and recorded previous_pin=$cur — which by then
    # is the ESCALATED id. Measured: escalate A, escalate B, restore, and the
    # lane came back to claude-opus-5-0 instead of claude-sonnet-7, with every
    # later restore a no-op against a record that could not undo anything.
    #
    # So a live record's previous_pin is carried forward verbatim. D0 ships no
    # caller, but D4/D5 run parallel unit batches over ONE implementer lane,
    # which is exactly where a second escalation arrives while the first is up.
    # `supersedes` keeps the displaced task id in the audit trail rather than
    # dropping it, and it is present only when there was one.
    local prev_pin="$cur" superseded="" live_prev live_task
    if [ -f "$ESCALATION_STATE" ] && command -v jq >/dev/null 2>&1; then
        live_prev=$(jq -r '.previous_pin // empty' "$ESCALATION_STATE" 2>/dev/null || true)
        live_task=$(jq -r '.task_id // empty' "$ESCALATION_STATE" 2>/dev/null || true)
        if [ -n "$live_prev" ]; then
            prev_pin="$live_prev"
            if [ "$live_task" != "$task" ]; then
                superseded="$live_task"
                _warn "escalate: an escalation for '${live_task:-<unknown>}' is already live on the implementer lane; previous_pin stays '$prev_pin' so restore still returns the lane to its pre-escalation model"
            fi
        fi
    fi

    # WRITE THE STATE BEFORE THE REWRITE. If the rewrite crashes half way, the
    # recorded previous_pin is what makes the lane recoverable; a state file
    # written afterwards would be missing in exactly the case it is needed.
    mkdir -p "$(dirname "$ESCALATION_STATE")" 2>/dev/null || true
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if jq -n --arg task "$task" --arg ts "$ts" --arg strat "$strat" \
        --arg pick "$pick" --arg prev "$prev_pin" --arg sup "$superseded" \
        '{task_id:$task, escalated_at:$ts, strategy:$strat, resolved:$pick,
          previous_pin:$prev,
          restore_command:"bash .claude/scripts/model-select.sh restore",
          claim:"declared, audited, reversible pin change; NOT evidence that any subagent ran on this model"}
         + (if $sup == "" then {} else {supersedes:$sup} end)' \
        > "$ESCALATION_STATE.tmp" 2>/dev/null; then
        mv "$ESCALATION_STATE.tmp" "$ESCALATION_STATE"
    else
        rm -f "$ESCALATION_STATE.tmp" 2>/dev/null || true
        _result "escalate: could not record escalation state; refusing to repin (the lane would not be restorable)"
        return 0
    fi

    # Each _apply_role outcome gets its own answer. `|| ar_rc=$?` rather than
    # `if`, because the interesting statuses are the non-zero ones.
    local ar_rc=0
    _apply_role implementer "$pick" || ar_rc=$?
    case "$ar_rc" in
        0) _result "escalate: implementer lane pinned to $pick for '$task' (was ${cur:-<none>}); reverse with: model-select.sh restore" ;;
        1) _result "escalate: implementer lane already at $pick for '$task' (no rewrite needed)" ;;
        2)
            # Nothing was rewritten — the skip happens BEFORE the helper call —
            # so a record here would claim an escalation that provably did not
            # happen and would light !esc on the statusline until someone ran
            # restore. Drop it. This is not the crash case the write-first rule
            # above protects: we know exactly what did not happen.
            rm -f "$ESCALATION_STATE" 2>/dev/null || true
            _result "escalate: no agent file for the implementer lane; NOTHING was repinned for '$task' and the escalation record was dropped"
            ;;
        *)
            _result "escalate: the rewrite helper FAILED; the implementer lane was NOT pinned to $pick for '$task'. The escalation record is KEPT so 'model-select.sh restore' can undo a partial rewrite — run it before retrying."
            ;;
    esac
}

cmd_restore() {
    if [ ! -f "$ESCALATION_STATE" ]; then
        _result "restore: no active escalation (nothing to do)"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _result "restore: jq unavailable; cannot read $ESCALATION_STATE"
        return 0
    fi
    local prev task
    prev=$(jq -r '.previous_pin // empty' "$ESCALATION_STATE" 2>/dev/null || true)
    task=$(jq -r '.task_id // empty' "$ESCALATION_STATE" 2>/dev/null || true)
    if [ -z "$prev" ]; then
        # No previous pin recorded (the lane was unpinned when it escalated).
        # Dropping the state is still the right move: leaving it would make
        # every later restore a no-op against a record it cannot act on.
        rm -f "$ESCALATION_STATE" 2>/dev/null || true
        _result "restore: escalation record for '${task:-<unknown>}' had no previous pin; cleared the record, left the pin alone"
        return 0
    fi
    if [ ! -x "$APPLY_HELPER" ]; then
        _result "restore: missing apply helper at $APPLY_HELPER; escalation record kept for a later retry"
        return 0
    fi
    # THE RECORD IS DROPPED ONLY WHEN THE LANE IS PROVABLY BACK (QA R1-F5). It
    # used to be `rm -f` unconditionally, one line after a rewrite failure the
    # helper had already reported — so the single artifact that made the lane
    # restorable was deleted on exactly the runs where it was still needed.
    #
    # Keeping it on failure cannot strand anything: session-end.sh runs restore
    # best-effort every session, and once the pin is back the retry lands on the
    # rc=1 no-op arm, which clears the record. A stale !esc flag is visible and
    # self-healing; a lost record is neither.
    local ar_rc=0
    _apply_role implementer "$prev" || ar_rc=$?
    case "$ar_rc" in
        0)
            _result "restore: implementer lane returned to $prev (was escalated for '${task:-<unknown>}')"
            rm -f "$ESCALATION_STATE" 2>/dev/null || true
            ;;
        1)
            _result "restore: implementer lane already at $prev (no rewrite needed)"
            rm -f "$ESCALATION_STATE" 2>/dev/null || true
            ;;
        2)
            _result "restore: no agent file for the implementer lane, so nothing could be repinned to $prev; the escalation record is KEPT (other members of the class may still be escalated)"
            ;;
        *)
            _result "restore: the rewrite helper FAILED; the implementer lane was NOT returned to $prev. The escalation record is KEPT — fix the helper and rerun: model-select.sh restore"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Subcommand: status.
# ---------------------------------------------------------------------------

# _drift_check <role> — warn when members of a role class hold different pins
# (intra-role lockstep drift). Silent when they agree or a member file is
# absent.
#
# DISCOVERY, not a hardcoded member list (D0): the class members come from
# `workflow-model-apply.sh --print-role-map`, which derives them from
# role_agents() — the single source of truth the rewrite itself uses. Before
# D0 this function was called with the member names spelled out, so a class
# that gained an agent kept checking the old set and reported "no drift" over
# a member it never read.
_drift_check() {
    local role="$1"
    local first="" agent pin f maprole
    while IFS="$(printf '\t')" read -r maprole agent; do
        [ "$maprole" = "$role" ] || continue
        [ -n "$agent" ] || continue
        f="$PROJECT_DIR/.claude/agents/$agent.md"
        [ -f "$f" ] || continue
        pin=$(grep -E '^model:' "$f" | head -1 | awk '{print $2}')
        if [ -z "$first" ]; then
            first="$pin"
        elif [ "$pin" != "$first" ]; then
            _warn "intra-role drift in '$role': $agent pinned '$pin' but '$first' expected — run model-select.sh apply or /workflow-model --role $role <id>"
        fi
    done <<EOF
$(bash "$APPLY_HELPER" --print-role-map 2>/dev/null || true)
EOF
}

cmd_status() {
    local age models role strat pin resolved raw
    age=$(cache_age_s)

    models=""
    if [ -f "$CACHE_FILE" ]; then
        models=$(read_cache_models)
    fi

    # Prime the codex probe once for both lane reads below.
    _codex_probe_once

    printf 'role              strategy       pinned                    resolved\n'
    for role in $ALL_ROLES; do
        strat=$(role_strategy "$role")
        pin=$(current_pin "$role")
        resolved="<no cache>"
        if [ -n "$models" ] && [ "$models" != "[]" ]; then
            # stderr from pick_best/pick_for_role (incl. the LOUD manual-adopt
            # notice) is intentionally preserved so `status` surfaces it too.
            raw=$(pick_for_role "$models" "$strat") || raw=""
            case "$raw" in
                MANUAL$'\t'*) resolved="${raw#MANUAL$'\t'} (manual adopt required)" ;;
                "")           resolved="<no candidate>" ;;
                *)            resolved="$raw" ;;
            esac
        fi
        printf '  %-16s%-15s%-26s%s\n' "$role" "$strat" "${pin:-<unset>}" "$resolved"
    done

    # The escalation strategy is reported OUTSIDE the role table, because it is
    # not a role: it owns no agent files, so it has no "pinned" column.
    printf '  %-16s%-15s%-26s%s\n' "(escalation)" "$(role_strategy "$ESCALATION_KEY")" \
        "-" "$([ -f "$ESCALATION_STATE" ] && printf 'ACTIVE' || printf 'inactive')"

    if [ "$age" -lt 0 ]; then
        printf 'cache:              absent\n'
    elif cache_fresh; then
        printf 'cache:              fresh (%ds old, TTL %ds)\n' "$age" "$CACHE_TTL_SECONDS"
    else
        printf 'cache:              stale (%ds old, TTL %ds)\n' "$age" "$CACHE_TTL_SECONDS"
    fi
    printf 'reviewer lane: %s\n' "$(detect_reviewer_lane)"
    printf 'design reviewer lane: %s\n' "$(detect_design_reviewer_lane)"
    local missing
    missing=$(_missing_role_keys)
    [ -n "$missing" ] && printf 'missing model-roles keys: %s\n' "$missing"

    # Intra-role lockstep drift warnings, over every class in the role map.
    for role in $ALL_ROLES; do
        _drift_check "$role"
    done
}

# ---------------------------------------------------------------------------
# Subcommand: roles.
# ---------------------------------------------------------------------------

# cmd_roles — print `role<TAB>strategy<TAB>resolved-id` for each role. The
# strategy comes from .claude/model-roles; the resolved id from the last
# written artifact (model-roles-resolved.json). A stable, greppable read
# interface for tests and operators.
cmd_roles() {
    local role strat rid
    for role in $ALL_ROLES; do
        strat=$(role_strategy "$role")
        rid=""
        if [ -f "$ROLES_ARTIFACT" ]; then
            rid=$(jq -r --arg r "$role" '.roles[$r] // empty' "$ROLES_ARTIFACT" 2>/dev/null || true)
        fi
        printf '%s\t%s\t%s\n' "$role" "$strat" "${rid:-<unresolved>}"
    done
}

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------

case "$SUBCMD" in
    resolve)  cmd_resolve ;;
    apply)    cmd_apply ;;
    status)   cmd_status ;;
    roles)    cmd_roles ;;
    escalate) cmd_escalate ;;
    restore)  cmd_restore ;;
    ""|help|-h|--help)
        cat <<'USAGE'
model-select.sh — automatic best-model selection (spec 0.3 + V1 roles + D0
five-role expansion).

Usage:
  model-select.sh resolve [--quiet] [--refresh]
      print "<id>\t<source>" on stdout (the top pick for the whole account)
  model-select.sh apply   [--quiet] [--refresh]
      resolve every role -> rewrite each lane's pins -> record switches
  model-select.sh status
      print the per-role table (role, strategy, pinned id, resolved id),
      cache state, both review lanes, missing config keys, intra-role drift
  model-select.sh roles
      print "role\tstrategy\tresolved-id" (config + resolved artifact)
  model-select.sh escalate <task-id>
      resolve `implementer_class_high` and repin the implementer lane to it,
      recording the previous pin first so the change is reversible
  model-select.sh restore
      undo an escalation: put the recorded previous implementer pin back

Roles (designer, design_reviewer, orchestrator, implementer, reviewer) and
their strategies live in .claude/model-roles. A strategy is `top` or
`<family>-class` (opus-class, sonnet-class, ... — any lowercase family; the
grammar is one rule, not an enum). Optional: reviewer_lane and
design_reviewer_lane (auto|claude), and implementer_class_high, which is a
strategy rather than a role and owns no agent files. The resolved mapping is
written to .claude/.qa-tracking/model-roles-resolved.json (schema 2).

Escalation is a DECLARED, AUDITED, REVERSIBLE pin change. Whether the runtime
honours a mid-session frontmatter model: change is not established here and is
not verifiable offline, so nothing in this tree claims an escalated unit RAN
on the escalated model.

Honors $ANTHROPIC_API_KEY for the /v1/models lookup. Caches results in
.claude/.qa-tracking/model-select-cache.json for 3600 seconds. Fails open
on any error: prints a warning, leaves the pins alone, exits 0.
USAGE
        ;;
    *)
        printf 'model-select.sh: unknown subcommand %q\n' "$SUBCMD" >&2
        exit 2
        ;;
esac

exit 0

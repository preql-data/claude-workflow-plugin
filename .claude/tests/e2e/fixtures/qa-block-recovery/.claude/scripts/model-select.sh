#!/bin/bash
# model-select.sh — automatic best-model selection (spec 0.3 + hotfix vlp.1
# + v4.0.0 Phase V1 role-aware resolution / bi3.1).
#
# Resolves the best model available to this account, ranks it against
# .claude/model-ranking, and (in the `apply` path) rewrites each agent's
# model: pin PER ROLE via the shared workflow-model-apply.sh helper.
#
# Role-aware resolution (V1):
#   .claude/model-roles maps each role to a strategy — orchestrator/reviewer
#   default to `top` (the single best pick, exactly v3.5), implementer to
#   `opus-class` (the newest claude-opus-* in the listing, auto-adopting the
#   next Opus generation the moment the account lists it). `resolve` still
#   prints the account-wide top pick; `apply` resolves all three roles and
#   rewrites each lane independently; the resolved mapping is written to
#   .claude/.qa-tracking/model-roles-resolved.json for the statusline.
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
#   apply [--quiet] [--refresh]
#       Resolve ALL THREE roles first; if a role's resolved id differs from
#       that lane's current pin, invoke workflow-model-apply.sh --role and
#       record a role-tagged switch on the standing "Model selection log"
#       Beads meta-task. All-or-nothing on a manual-adopt/no-candidate
#       listing (keep every pin, no artifact). Quiet suppresses per-file
#       rewrite chatter; the one-line summary still prints. --refresh
#       bypasses the cache (same semantics as resolve).
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
MODEL_ROLES_FILE="$PROJECT_DIR/.claude/model-roles"
ROLES_ARTIFACT="$PROJECT_DIR/.claude/.qa-tracking/model-roles-resolved.json"
CODEX_DETECT="$PROJECT_DIR/.claude/scripts/codex-detect.sh"
# Filesystem side-channel: pick_for_role writes "true"/"false" here so
# cmd_apply can read the implementer opus-class fallback flag across the
# $(...) subshell boundary (a shell variable set inside command
# substitution never propagates to the parent — the same subshell-loss
# constraint that shaped pick_best's MANUAL stdout contract). Empty by
# default so pick_for_role is a silent no-op writer outside apply.
ROLE_FALLBACK_FILE=""

QUIET=0
REFRESH=0
SUBCMD="${1:-}"
shift || true

while [ "${1:-}" != "" ]; do
    case "$1" in
        --quiet|-q) QUIET=1 ;;
        --refresh)  REFRESH=1 ;;
        *) ;;  # ignore unknown args; subcommand-specific positional args are absent today
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

# role_strategy <role> — resolve a role to its selection strategy
# (top|opus-class). Fail-open: a missing file or missing key is the quiet
# v3.5-parity default of `top`; a PRESENT-but-unrecognised value is a
# surprising misconfiguration, so that path warns loudly before falling
# back to `top`.
role_strategy() {
    local role="$1" val
    val=$(_model_roles_value "$role")
    case "$val" in
        top|opus-class) printf '%s' "$val" ;;
        "")             printf 'top' ;;   # missing key/file: quiet v3.5 default
        *)
            _warn "unknown strategy '$val' for role '$role' in $MODEL_ROLES_FILE; falling back to top"
            printf 'top'
            ;;
    esac
}

# reviewer_lane_config — read the reviewer_lane key (auto|claude), default
# auto. An unrecognised value warns and falls back to auto.
reviewer_lane_config() {
    local val
    val=$(_model_roles_value "reviewer_lane")
    case "$val" in
        auto|claude) printf '%s' "$val" ;;
        "")          printf 'auto' ;;
        *)
            _warn "unknown reviewer_lane '$val' in $MODEL_ROLES_FILE; falling back to auto"
            printf 'auto'
            ;;
    esac
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
    if [ -x "$CODEX_DETECT" ]; then
        local probed
        probed=$(bash "$CODEX_DETECT" 2>/dev/null || true)
        if [ -n "$probed" ]; then
            printf '%s' "$probed"
            return
        fi
    fi
    printf 'claude'
}

# pick_for_role <models-json> <strategy> — resolve one role's best id,
# preserving pick_best's stdout contract (`<id>` | `MANUAL\t<id>` | rc=1).
#
#   top         -> pick_best over the full listing (unchanged).
#   opus-class  -> pick_best over the claude-opus-* subset. Ranking
#                  exclusions still apply (pick_best applies them inside the
#                  subset). An empty subset OR a fully-excluded subset warns
#                  and falls back to pick_best over the full listing.
#
# When ROLE_FALLBACK_FILE is set, writes "true" on the opus-class fallback
# path and "false" otherwise so cmd_apply can record implementer_fallback
# in the artifact (see the constant's comment for the subshell rationale).
pick_for_role() {
    local models="$1" strategy="$2"
    case "$strategy" in
        opus-class)
            local subset n
            subset=$(printf '%s' "$models" \
                | jq -c '[.[] | select(.id | startswith("claude-opus-"))]' 2>/dev/null)
            n=$(printf '%s' "$subset" | jq -r 'length' 2>/dev/null)
            if [ -z "$n" ] || [ "$n" = "0" ]; then
                _warn "no claude-opus-* model in listing; implementer falls back to top"
                [ -n "$ROLE_FALLBACK_FILE" ] && printf 'true' > "$ROLE_FALLBACK_FILE"
                pick_best "$models"
                return
            fi
            local sub_pick sub_rc
            sub_pick=$(pick_best "$subset")
            sub_rc=$?
            if [ "$sub_rc" -ne 0 ] || [ -z "$sub_pick" ]; then
                _warn "all claude-opus-* models excluded by ranking; implementer falls back to top"
                [ -n "$ROLE_FALLBACK_FILE" ] && printf 'true' > "$ROLE_FALLBACK_FILE"
                pick_best "$models"
                return
            fi
            [ -n "$ROLE_FALLBACK_FILE" ] && printf 'false' > "$ROLE_FALLBACK_FILE"
            printf '%s\n' "$sub_pick"
            ;;
        top|*)
            [ -n "$ROLE_FALLBACK_FILE" ] && printf 'false' > "$ROLE_FALLBACK_FILE"
            pick_best "$models"
            ;;
    esac
}

# write_roles_artifact — atomically write the resolved-mapping artifact.
# Args: orch_id impl_id rev_id orch_strat impl_strat rev_strat impl_fallback lane source
# On any failure the previous artifact is left untouched (stale-beats-none).
write_roles_artifact() {
    local orch="$1" impl="$2" rev="$3" os="$4" is="$5" rs="$6" fb="$7" lane="$8" src="$9"
    mkdir -p "$(dirname "$ROLES_ARTIFACT")"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if jq -n \
        --arg ts "$ts" --arg src "$src" \
        --arg orch "$orch" --arg impl "$impl" --arg rev "$rev" \
        --arg os "$os" --arg is "$is" --arg rs "$rs" \
        --argjson fb "$fb" --arg lane "$lane" \
        '{resolved_at:$ts, listing_source:$src,
          roles:{orchestrator:$orch, implementer:$impl, reviewer:$rev},
          strategies:{orchestrator:$os, implementer:$is, reviewer:$rs},
          implementer_fallback:$fb, reviewer_lane:$lane}' \
        > "$ROLES_ARTIFACT.tmp" 2>/dev/null; then
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
current_pin() {
    local role="${1:-orchestrator}"
    local f
    case "$role" in
        implementer) f="$IMPL_AGENT" ;;
        reviewer)    f="$REVIEWER_AGENT" ;;
        orchestrator|*) f="$ORCH_AGENT" ;;
    esac
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
# pin differs from <new-id>, and record a role-tagged switch. Returns 0
# when a switch happened (so the caller can count switches), 1 on no-op or
# a rewrite failure. Honors QUIET for the per-file rewrite chatter.
_apply_role() {
    local role="$1" new="$2" cur apply_out
    cur=$(current_pin "$role")
    if [ "$cur" = "$new" ]; then
        return 1
    fi
    if ! apply_out=$(bash "$APPLY_HELPER" --role "$role" "$new" 2>&1); then
        _result "rewrite helper failed for role $role (kept pin ${cur:-<none>})"
        [ "$QUIET" -ne 1 ] && printf '%s\n' "$apply_out" >&2
        return 1
    fi
    [ "$QUIET" -ne 1 ] && printf '%s\n' "$apply_out" >&2
    record_switch_role "$role" "$cur" "$new"
    return 0
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

    # Strategy per role (fail-open to top on a missing/bad model-roles).
    local orch_strat impl_strat rev_strat
    orch_strat=$(role_strategy orchestrator)
    impl_strat=$(role_strategy implementer)
    rev_strat=$(role_strategy reviewer)

    # Resolve ALL THREE roles FIRST, before touching any pin. The
    # implementer opus-class fallback flag rides a filesystem side-channel
    # (ROLE_FALLBACK_FILE) so it survives the pick_for_role $(...) subshell.
    ROLE_FALLBACK_FILE=$(mktemp "${TMPDIR:-/tmp}/model-roles-fb.XXXXXX" 2>/dev/null || true)
    if [ -z "$ROLE_FALLBACK_FILE" ]; then
        mkdir -p "$PROJECT_DIR/.claude/.qa-tracking" 2>/dev/null || true
        ROLE_FALLBACK_FILE="$PROJECT_DIR/.claude/.qa-tracking/.model-roles-fb"
    fi
    : > "$ROLE_FALLBACK_FILE" 2>/dev/null || true

    local orch_pick impl_pick rev_pick impl_fallback
    orch_pick=$(pick_for_role "$models" "$orch_strat")
    impl_pick=$(pick_for_role "$models" "$impl_strat")
    impl_fallback=$(cat "$ROLE_FALLBACK_FILE" 2>/dev/null || printf 'false')
    rev_pick=$(pick_for_role "$models" "$rev_strat")
    rm -f "$ROLE_FALLBACK_FILE" 2>/dev/null || true
    ROLE_FALLBACK_FILE=""
    [ -n "$impl_fallback" ] || impl_fallback="false"

    # No-candidate on ANY role -> fail-open, keep every pin, no artifact.
    if [ -z "$orch_pick" ] || [ -z "$impl_pick" ] || [ -z "$rev_pick" ]; then
        _result "ranking produced no candidate for one or more roles; keeping current pin"
        return 0
    fi

    # All-or-nothing manual-adopt gate: if ANY role's winner needs manual
    # adoption (unparseable created_at, surfaced by pick_best as a MANUAL\t
    # stdout prefix), emit a loud per-role notice, keep EVERY pin unchanged,
    # and do NOT write the artifact. A partially-bogus listing must never
    # leave the lanes straddling mixed model generations.
    local manual=0 mid
    case "$orch_pick" in
        MANUAL$'\t'*)
            manual=1; mid="${orch_pick#MANUAL$'\t'}"
            _result "manual adoption required for orchestrator '$mid' — run /workflow-model --role orchestrator $mid"
            ;;
    esac
    case "$impl_pick" in
        MANUAL$'\t'*)
            manual=1; mid="${impl_pick#MANUAL$'\t'}"
            _result "manual adoption required for implementer '$mid' — run /workflow-model --role implementer $mid"
            ;;
    esac
    case "$rev_pick" in
        MANUAL$'\t'*)
            manual=1; mid="${rev_pick#MANUAL$'\t'}"
            _result "manual adoption required for reviewer '$mid' — run /workflow-model --role reviewer $mid"
            ;;
    esac
    if [ "$manual" -eq 1 ]; then
        _result "manual adoption required for one or more roles; keeping ALL pins unchanged (no artifact written)"
        return 0
    fi

    if [ ! -x "$APPLY_HELPER" ]; then
        _result "missing apply helper at $APPLY_HELPER; skipping rewrite"
        return 0
    fi

    # Determine the reviewer lane, then persist the resolved mapping
    # atomically BEFORE the rewrites (a rewrite crash still leaves a
    # truthful artifact of intent; fail-open paths above leave the previous
    # artifact untouched — stale beats none).
    local lane source
    lane=$(detect_reviewer_lane)
    source="api"; cache_fresh && source="cache"
    write_roles_artifact "$orch_pick" "$impl_pick" "$rev_pick" \
        "$orch_strat" "$impl_strat" "$rev_strat" "$impl_fallback" "$lane" "$source"

    # Per-role apply.
    local switched=0
    _apply_role orchestrator "$orch_pick" && switched=$((switched + 1))
    _apply_role implementer  "$impl_pick" && switched=$((switched + 1))
    _apply_role reviewer     "$rev_pick"  && switched=$((switched + 1))

    local lane_note=""
    [ "$lane" != "claude" ] && lane_note=" lane=$lane"
    _result "roles: orch=$orch_pick impl=$impl_pick rev=$rev_pick${lane_note} ($switched switched)"
}

# ---------------------------------------------------------------------------
# Subcommand: status.
# ---------------------------------------------------------------------------

# _drift_check <role> <agent...> — warn when members of a role class hold
# different pins (intra-role lockstep drift). Silent when they agree or a
# member file is absent.
_drift_check() {
    local role="$1"; shift
    local first="" agent pin f
    for agent in "$@"; do
        f="$PROJECT_DIR/.claude/agents/$agent.md"
        [ -f "$f" ] || continue
        pin=$(grep -E '^model:' "$f" | head -1 | awk '{print $2}')
        if [ -z "$first" ]; then
            first="$pin"
        elif [ "$pin" != "$first" ]; then
            _warn "intra-role drift in '$role': $agent pinned '$pin' but '$first' expected — run model-select.sh apply or /workflow-model --role $role <id>"
        fi
    done
}

cmd_status() {
    local age models role strat pin resolved raw
    age=$(cache_age_s)

    models=""
    if [ -f "$CACHE_FILE" ]; then
        models=$(read_cache_models)
    fi

    printf 'role           strategy    pinned                    resolved\n'
    for role in orchestrator implementer reviewer; do
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
        printf '  %-13s%-12s%-26s%s\n' "$role" "$strat" "${pin:-<unset>}" "$resolved"
    done

    if [ "$age" -lt 0 ]; then
        printf 'cache:         absent\n'
    elif cache_fresh; then
        printf 'cache:         fresh (%ds old, TTL %ds)\n' "$age" "$CACHE_TTL_SECONDS"
    else
        printf 'cache:         stale (%ds old, TTL %ds)\n' "$age" "$CACHE_TTL_SECONDS"
    fi
    printf 'reviewer lane: %s\n' "$(detect_reviewer_lane)"

    # Intra-role lockstep drift warnings (implementer/reviewer classes).
    _drift_check implementer backend frontend devops
    _drift_check reviewer qa grader judge
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
    for role in orchestrator implementer reviewer; do
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
    ""|help|-h|--help)
        cat <<'USAGE'
model-select.sh — automatic best-model selection (spec 0.3 + V1 roles).

Usage:
  model-select.sh resolve [--quiet] [--refresh]
      print "<id>\t<source>" on stdout (the top pick for the whole account)
  model-select.sh apply   [--quiet] [--refresh]
      resolve every role -> rewrite each lane's pins -> record switches
  model-select.sh status
      print the per-role table (role, strategy, pinned id, resolved id),
      cache state, reviewer lane, and any intra-role drift
  model-select.sh roles
      print "role\tstrategy\tresolved-id" (config + resolved artifact)

Roles and strategies live in .claude/model-roles (orchestrator/implementer/
reviewer -> top|opus-class; optional reviewer_lane=auto|claude). The
resolved mapping is written to .claude/.qa-tracking/model-roles-resolved.json.

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

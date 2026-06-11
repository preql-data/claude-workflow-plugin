#!/bin/bash
# model-select.sh — automatic best-model selection (spec 0.3).
#
# Resolves the best model available to this account, ranks it against
# .claude/model-ranking, and (in the `apply` path) rewrites every agent's
# model: pin via the shared workflow-model-apply.sh helper.
#
# Subcommands:
#   resolve [--quiet]
#       Print "<model-id>\t<source>" on stdout (source is one of
#       "cache","api"). Returns 0 if a model was resolved or the operator
#       wanted a fail-open warning; exits 0 either way so SessionStart
#       never blocks on an enumeration failure (spec principle: "never
#       block the session"). On fail-open, the message goes to stderr and
#       stdout is empty.
#
#   apply [--quiet]
#       Resolve as above; if the resolved id differs from the current
#       pin, invoke workflow-model-apply.sh and record the switch on the
#       standing "Model selection log" Beads meta-task. Quiet suppresses
#       per-file rewrite chatter; the one-line summary still prints.
#
#   status
#       Print current pin (from orchestrator.md), cached best (if cache
#       is fresh), and cache age.
#
# Caching:
#   .claude/.qa-tracking/model-select-cache.json
#     { "timestamp": <unix-ts>, "models": [ { "id":..., "max_input_tokens":..., "created_at":... }, ... ] }
#   TTL is 3600s. A stale cache is ignored (we refresh); a missing cache
#   triggers an API fetch.
#
# Fail-open contract (spec 0.3 principle 1):
#   - No ANTHROPIC_API_KEY and no fresh cache: emit warning, exit 0.
#   - curl failure / timeout: emit warning, exit 0.
#   - empty model list / ranking match miss: emit warning, exit 0.
#   - Never trigger inference, drift, or any paid call on switch.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CACHE_FILE="$PROJECT_DIR/.claude/.qa-tracking/model-select-cache.json"
CACHE_TTL_SECONDS=3600
RANKING_FILE="$PROJECT_DIR/.claude/model-ranking"
META_TASK_FILE="$PROJECT_DIR/.claude/.model-select-meta-task"
APPLY_HELPER="$PROJECT_DIR/.claude/scripts/workflow-model-apply.sh"
ORCH_AGENT="$PROJECT_DIR/.claude/agents/orchestrator.md"

QUIET=0
SUBCMD="${1:-}"
shift || true

while [ "${1:-}" != "" ]; do
    case "$1" in
        --quiet|-q) QUIET=1 ;;
        *) ;;  # ignore unknown args; subcommand-specific positional args are absent today
    esac
    shift
done

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
cache_fresh() {
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
# Ranking.
# ---------------------------------------------------------------------------

# load_ranking — print one family-prefix per line, in preference order;
# strip comments and blank lines.
load_ranking() {
    [ -f "$RANKING_FILE" ] || return 0
    sed -E -e 's/#.*$//' -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
        "$RANKING_FILE" | grep -v '^$'
}

# pick_best <models-json> — print the best id (with optional [1m] suffix)
# on stdout, return 0 on success. Returns 1 when ranking yields no match.
#
# Algorithm:
#   1. Read families in order (load_ranking).
#   2. For each model, find the longest matching family prefix among
#      configured families. Models in unknown families are skipped with
#      a single warning naming them (spec: "unknown families ignored
#      with a warning").
#   3. Within the chosen-family pool: sort by version tuple DESC, then by
#      max_input_tokens DESC; the head is the winner. Version tuple is
#      extracted from the id with `claude-<family>-<v0>-<v1>[-<v2>]`
#      style ids (e.g. claude-opus-4-7 -> [4,7]; claude-fable-5 -> [5,0]).
#   4. If the winner's id has a sibling with the same version but a
#      larger context window AND there's no separate entry (i.e. the
#      shape Anthropic ships is one id with two context modes), keep the
#      base id — Claude Code applies the [1m] suffix at the model: layer.
#      In practice we just emit the bare id; the rewriter accepts the
#      [1m] suffix when callers want to force it.
#
# Note: the "[1m] preferred variant" path triggers only when the API
# listing distinguishes by id (we'd see a separate model entry). When it
# doesn't, the shape is identical and the suffix is a settings-level
# concern documented in /workflow-model. We don't auto-add the suffix
# from this helper to avoid an opinion that hurts under model rotation.
pick_best() {
    local models="$1"
    local ranking
    ranking=$(load_ranking)
    if [ -z "$ranking" ]; then
        _warn "ranking file empty or absent at $RANKING_FILE"
        return 1
    fi

    # Build a jq filter that, for each ranked family in order, scans the
    # models array for entries whose id starts with the family prefix
    # (followed by `-` to avoid claude-opus matching claude-opusplan-like
    # accidents). Returns the first non-empty family bucket as
    # [{id, version, max_input_tokens}], sorted DESC by version then DESC
    # by max_input_tokens. Empty buckets fall through.
    local families_json
    families_json=$(printf '%s\n' "$ranking" | jq -R -s -c 'split("\n") | map(select(length>0))')

    # The jq program:
    #   - For each family (in order), filter the model list to entries
    #     whose id matches "^<family>-".
    #   - For each match, parse a version array from the part after the
    #     family prefix: split on '-' (or '.') and keep numeric tokens.
    #   - Sort DESC by version tuple, then DESC by max_input_tokens, and
    #     emit the head as the winner of that family.
    #   - The outer `first(...)` picks the first family that produced a
    #     match.
    local pick
    pick=$(jq -n -c \
        --argjson models "$models" \
        --argjson families "$families_json" '
        def parse_version($id; $fam):
            ($id | ltrimstr($fam + "-"))
            | split("-")
            | map(select(test("^[0-9]+(\\.[0-9]+)?$"))
                  | tonumber);

        def family_pick($fam):
            ($models // [])
            | map(select(.id | startswith($fam + "-")))
            | map({id, version: parse_version(.id; $fam),
                   max_input_tokens: (.max_input_tokens // 0)})
            | sort_by(.version, .max_input_tokens)
            | reverse
            | (first // null);

        ($families | map(family_pick(.)) | map(select(. != null)) | first)
        // null
    ' 2>/dev/null)

    if [ -z "$pick" ] || [ "$pick" = "null" ]; then
        # Surface which families WERE present in the listing so the
        # operator knows whether the ranking file needs editing (spec:
        # "unknown families ignored with a warning naming them").
        local seen
        seen=$(printf '%s' "$models" | jq -r '[.[].id | capture("^(?<fam>claude-[a-z]+)").fam] | unique | join(",")' 2>/dev/null)
        if [ -n "$seen" ]; then
            _warn "no ranking match. Families seen in listing: $seen. Edit $RANKING_FILE to add."
        else
            _warn "no ranking match and no recognisable model ids in listing."
        fi
        return 1
    fi

    printf '%s\n' "$pick" | jq -r '.id'
}

# unknown_families_warning <models-json> — surface families seen in the
# listing that are NOT in the ranking file. This is the "brand-new family
# is a one-line edit away" affordance: when Anthropic ships a new tier,
# this prints once per SessionStart so the operator sees the name they
# need to add.
unknown_families_warning() {
    local models="$1"
    local ranking_families
    ranking_families=$(load_ranking)
    [ -n "$ranking_families" ] || return 0
    local listed
    listed=$(printf '%s' "$models" | jq -r '[.[].id | capture("^(?<fam>claude-[a-z]+)").fam] | unique | .[]' 2>/dev/null)
    [ -n "$listed" ] || return 0
    local unknown=""
    local fam
    while IFS= read -r fam; do
        [ -z "$fam" ] && continue
        if ! printf '%s\n' "$ranking_families" | grep -qx "$fam"; then
            unknown="${unknown:+$unknown,}$fam"
        fi
    done <<EOF
$listed
EOF
    if [ -n "$unknown" ]; then
        _warn "unknown family/families in listing (add to $RANKING_FILE if newer): $unknown"
    fi
}

# ---------------------------------------------------------------------------
# Pin reading.
# ---------------------------------------------------------------------------

# current_pin — read model: from the orchestrator agent file. We treat the
# orchestrator as the source of truth; workflow-model-apply.sh enforces all
# agents stay in lockstep, so reading one is enough.
current_pin() {
    [ -f "$ORCH_AGENT" ] || return 0
    grep -E '^model:' "$ORCH_AGENT" | head -1 | awk '{print $2}'
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
# old->new transition plus the rollback /workflow-model line.
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
    local best
    best=$(pick_best "$models") || { _result "ranking produced no candidate"; return 0; }
    local source="api"
    cache_fresh && source="cache"
    printf '%s\t%s\n' "$best" "$source"
}

# ---------------------------------------------------------------------------
# Subcommand: apply.
# ---------------------------------------------------------------------------

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
    local best
    best=$(pick_best "$models")
    if [ -z "$best" ]; then
        _result "ranking produced no candidate; keeping current pin"
        return 0
    fi
    local cur
    cur=$(current_pin)
    if [ "$cur" = "$best" ]; then
        _result "no change (current pin already $cur)"
        return 0
    fi
    # Post-switch validation (free): confirm the resolved id is in the
    # listing. Strip any [1m] suffix for the comparison.
    local stripped
    stripped=$(printf '%s' "$best" | sed -E 's/\[1m\]$//')
    if ! printf '%s' "$models" | jq -e --arg id "$stripped" 'any(.id == $id)' >/dev/null 2>&1; then
        _result "resolved $best but it is not in the listing — refusing to switch (fail-open)"
        return 0
    fi
    if [ ! -x "$APPLY_HELPER" ]; then
        _result "missing apply helper at $APPLY_HELPER; skipping rewrite"
        return 0
    fi
    local apply_out
    if ! apply_out=$(bash "$APPLY_HELPER" "$best" 2>&1); then
        _result "rewrite helper failed (kept pin $cur)"
        if [ "$QUIET" -ne 1 ]; then
            printf '%s\n' "$apply_out" >&2
        fi
        return 0
    fi
    if [ "$QUIET" -ne 1 ]; then
        printf '%s\n' "$apply_out" >&2
    fi
    record_switch "$cur" "$best"
    _result "switched ${cur:-<none>} -> $best"
}

# ---------------------------------------------------------------------------
# Subcommand: status.
# ---------------------------------------------------------------------------

cmd_status() {
    local cur best age
    cur=$(current_pin)
    age=$(cache_age_s)
    printf 'current pin: %s\n' "${cur:-<unset>}"
    if [ "$age" -lt 0 ]; then
        printf 'cache:       absent\n'
    elif cache_fresh; then
        local models
        models=$(read_cache_models)
        best=$(pick_best "$models" 2>/dev/null) || best=""
        printf 'cache:       fresh (%ds old, TTL %ds)\n' "$age" "$CACHE_TTL_SECONDS"
        printf 'cached best: %s\n' "${best:-<unranked>}"
    else
        printf 'cache:       stale (%ds old, TTL %ds)\n' "$age" "$CACHE_TTL_SECONDS"
    fi
}

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------

case "$SUBCMD" in
    resolve)  cmd_resolve ;;
    apply)    cmd_apply ;;
    status)   cmd_status ;;
    ""|help|-h|--help)
        cat <<'USAGE'
model-select.sh — automatic best-model selection (spec 0.3).

Usage:
  model-select.sh resolve [--quiet]   print "<id>\t<source>" on stdout
  model-select.sh apply   [--quiet]   resolve + rewrite pins + record switch
  model-select.sh status              print current pin / cache state

Honors $ANTHROPIC_API_KEY for the /v1/models lookup. Caches results in
.claude/.qa-tracking/model-select-cache.json for 3600 seconds. Fails open
on any error: prints a warning, leaves the pin alone, exits 0.
USAGE
        ;;
    *)
        printf 'model-select.sh: unknown subcommand %q\n' "$SUBCMD" >&2
        exit 2
        ;;
esac

exit 0

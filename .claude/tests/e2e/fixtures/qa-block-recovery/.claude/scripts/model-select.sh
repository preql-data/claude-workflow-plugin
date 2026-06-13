#!/bin/bash
# model-select.sh — automatic best-model selection (spec 0.3 + hotfix vlp.1).
#
# Resolves the best model available to this account, ranks it against
# .claude/model-ranking, and (in the `apply` path) rewrites every agent's
# model: pin via the shared workflow-model-apply.sh helper.
#
# Subcommands:
#   resolve [--quiet] [--refresh]
#       Print "<model-id>\t<source>" on stdout (source is one of
#       "cache","api"). Returns 0 if a model was resolved or the operator
#       wanted a fail-open warning; exits 0 either way so SessionStart
#       never blocks on an enumeration failure (spec principle: "never
#       block the session"). On fail-open, the message goes to stderr and
#       stdout is empty. --refresh bypasses the cache and forces an API
#       round-trip (no-op without an API key).
#
#   apply [--quiet] [--refresh]
#       Resolve as above; if the resolved id differs from the current
#       pin, invoke workflow-model-apply.sh and record the switch on the
#       standing "Model selection log" Beads meta-task. Quiet suppresses
#       per-file rewrite chatter; the one-line summary still prints.
#       --refresh bypasses the cache (same semantics as resolve).
#
#   status
#       Print current pin (from orchestrator.md), cached best (if cache
#       is fresh), and cache age.
#
# Caching:
#   .claude/.qa-tracking/model-select-cache.json
#     { "timestamp": <unix-ts>, "models": [ { "id":..., "max_input_tokens":..., "created_at":... }, ... ] }
#   TTL is 3600s. A stale cache is ignored (we refresh); a missing cache
#   triggers an API fetch. --refresh ignores TTL outright.
#
# Ranking semantics (hotfix vlp.1):
#   `.claude/model-ranking` is an EXCLUSION + TERTIARY-TIE-BREAK file.
#   Lines starting with `!` are exclusion patterns ("!claude-haiku" drops
#   every id whose family prefix is `claude-haiku-`). All other lines are
#   family prefixes used only to break ties when two surviving entries
#   have identical `created_at` AND `max_input_tokens`. The picker DOES
#   NOT restrict candidates to ranked families; unknown families are
#   first-class candidates so a newly-launched tier above Fable wins
#   automatically without editing this file.
#
# Sort (primary -> tertiary):
#   1. created_at DESC (newest first; parsed as ISO 8601).
#   2. max_input_tokens DESC (larger context wins on tie).
#   3. Ranking-file position ASC (families listed earlier preferred).
#   When a winner's created_at is missing or unparseable, the helper
#   emits a LOUD notice naming the id and the `/workflow-model <id>`
#   adopt command — and refuses to auto-adopt. The session keeps the
#   current pin until the operator runs the adopt command explicitly.
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
# non-exclusion entries. These are the tertiary tie-break preference;
# they no longer restrict candidate selection.
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
# Algorithm (hotfix vlp.1):
#   1. Drop entries whose id starts with any "!<excl>-" prefix from the
#      ranking file.
#   2. Sort surviving entries by:
#        primary:   created_at DESC (parsed as ISO 8601; unparseable
#                   gets -1 so it sorts to the bottom — but if it ends
#                   up the winner anyway, the MANUAL prefix is emitted
#                   on stdout and the apply path refuses auto-rewrite).
#        secondary: max_input_tokens DESC (larger context wins on tie).
#        tertiary:  ranking-file position ASC (families listed earlier
#                   preferred; unknown families slot after every listed
#                   family for the tie-break).
#   3. Emit the head's id (with the MANUAL prefix when appropriate).
#
# We deliberately DO NOT family-gate. Unknown families are first-class
# candidates so a newly-launched tier above the listed families wins
# without an edit to the ranking file. The header doc covers this.
pick_best() {
    local models="$1"

    local exclusions_json tiers_json
    exclusions_json=$(load_exclusions | jq -R -s -c 'split("\n") | map(select(length>0))')
    tiers_json=$(load_tiers | jq -R -s -c 'split("\n") | map(select(length>0))')

    # Single-pass jq:
    #   - Filter out excluded ids (any id starting with "<excl>-").
    #   - Annotate each with _ts (created_at parsed to epoch via fromdate?,
    #     or -1 when missing/unparseable), _ctx (max_input_tokens), and
    #     _rank (lowest index of a tier whose prefix matches, or
    #     |tiers| for "unranked" — places unknown families at the back
    #     of the tertiary tie-break).
    #   - Sort by _ts DESC, _ctx DESC, _rank ASC.
    #   - Emit the head (or null when no candidates).
    local pick
    pick=$(jq -n -c \
        --argjson models "$models" \
        --argjson excludes "$exclusions_json" \
        --argjson tiers "$tiers_json" '
        def rank_for($id; $tiers):
            # Bind each tier entry as $e before the pipe — `.value` inside
            # a `select($id | ...)` body would be evaluated against $id (a
            # string), tripping "Cannot index string with string". The
            # `as $e` binding scopes the lookup outside the pipe.
            ($tiers | to_entries
             | map(. as $e | select($id | startswith($e.value + "-")))
             | (first | .key) // ($tiers | length));

        def excluded($id; $excludes):
            ($excludes | any(. as $e | $id | startswith($e + "-")));

        ($models // [])
        | map(select(excluded(.id; $excludes) | not))
        | map(. + {
            _ts: ((.created_at // "")
                  | if . == "" then -1
                    else (fromdate? // -1)
                    end),
            _ctx: (.max_input_tokens // 0),
            _rank: rank_for(.id; $tiers)
          })
        | sort_by([-(._ts), -(._ctx), ._rank])
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
# This is the "brand-new family is here, you may want to bump its rank"
# affordance — it never blocks selection. Under the new contract,
# unknown families are SELECTED automatically; the warning is just a
# heads-up so the operator can curate the tier list if they want a
# different tie-break order in the future.
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
        _warn "new family/families in listing (selected when newest, add to $RANKING_FILE to influence tie-break order or exclude with '!<family>'): $unknown"
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
    local raw_best best
    raw_best=$(pick_best "$models")
    if [ -z "$raw_best" ]; then
        _result "ranking produced no candidate; keeping current pin"
        return 0
    fi
    # Manual-adopt gate (defect 3fn fix): pick_best emits "MANUAL\t<id>"
    # when the winner's created_at is missing/unparseable. We parse the
    # prefix here BEFORE current-pin comparison and BEFORE any rewrite.
    # The session keeps the current pin and surfaces the LOUD adopt
    # instruction so a malformed listing can never silently switch us.
    # Previous implementation used a parent-shell global; that variable
    # was set inside a $(...) subshell and was invisible here, leaving
    # this gate unreachable and rewrites silent.
    case "$raw_best" in
        MANUAL$'\t'*)
            local manual_id="${raw_best#MANUAL$'\t'}"
            _result "manual adoption required for '$manual_id' (unparseable created_at) — run /workflow-model $manual_id"
            return 0
            ;;
        *)
            best="$raw_best"
            ;;
    esac
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
    local cur raw_best best age
    cur=$(current_pin)
    age=$(cache_age_s)
    printf 'current pin: %s\n' "${cur:-<unset>}"
    if [ "$age" -lt 0 ]; then
        printf 'cache:       absent\n'
    elif cache_fresh; then
        local models
        models=$(read_cache_models)
        # Run pick_best with stderr preserved (defect 3fn fix): the LOUD
        # manual-adopt notice surfaces here so the operator gets the
        # adopt instruction from `model-select.sh status` as well. The
        # previous `2>/dev/null` swallowed it.
        raw_best=$(pick_best "$models") || raw_best=""
        case "$raw_best" in
            MANUAL$'\t'*)
                best="${raw_best#MANUAL$'\t'} (manual adopt required)"
                ;;
            *)
                best="$raw_best"
                ;;
        esac
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

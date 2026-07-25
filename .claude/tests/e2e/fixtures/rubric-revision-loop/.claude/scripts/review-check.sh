#!/bin/bash
# review-check.sh — the ONE reviewer-record validator + independence/finding
# counter (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# WHY THIS EXISTS: the review workflow needs a single, subprocess-invokable
# implementation of (a) request/artifact schema validation and (b) the
# gate-count predicate over review records — mirroring how impact-report.sh
# --hash-only is the ONE place that defines the change-set canonicalisation.
# qa-gate.sh review-record calls `validate-artifact` here rather than carrying
# a second validator; a future gate-enforcement step calls `gate` here.
#
# STRUCTURAL PURITY (D5): this script is reviewer-agnostic. It contains no
# reference to any specific reviewer transport or lane — it only parses the
# generic record grammars (REVIEW-ARTIFACT / RESOLVED / ARBITRATION /
# IMPLEMENTER) and the JSON schemas. A structural test enforces this.
#
# Subcommands (strict JSON envelope on stdout):
#   validate-request  <file>                    schema-check a review request
#   validate-artifact <file>                    schema-check a review artifact
#   gate <task-id> [--comments-json <file>]     independence + open-finding count
#
# Exit codes:
#   0  ok / clean
#   4  contract violation (schema invalid, non-independent, open findings)
#   2  bd unavailable (gate could not read comments and no --comments-json)
#   1  usage error
#
# Severity enum (D8, ordered): critical > high > medium > low > info. The
# risk_threshold uses the same enum. `gate` counts a finding as open when its
# severity rank is >= the artifact's risk_threshold rank.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if ! command -v jq >/dev/null 2>&1; then
    printf '{"ok":false,"subcommand":"%s","error_key":"jq_missing","observations":"jq is required and not on PATH"}\n' "${1:-}"
    exit 2
fi

# sev_rank <severity> -> integer rank (0 = unknown/invalid).
sev_rank() {
    case "$1" in
        critical) echo 5 ;;
        high)     echo 4 ;;
        medium)   echo 3 ;;
        low)      echo 2 ;;
        info)     echo 1 ;;
        *)        echo 0 ;;
    esac
}

# threshold_rank <threshold> -> integer rank; an unknown threshold defaults to
# `high` (the risk_threshold_default) so the gate never silently under-counts.
threshold_rank() {
    local r
    r=$(sev_rank "$1")
    [ "$r" = "0" ] && r=4
    echo "$r"
}

# emit_validate <subcommand> <ok true|false> <error_key> <observations>
emit_validate() {
    local sub="$1" ok="$2" ekey="$3" obs="$4"
    # shellcheck disable=SC2016
    printf '{"ok":%s,"subcommand":%s,"error_key":%s,"observations":%s}\n' \
        "$ok" \
        "$(printf '%s' "$sub" | jq -Rs .)" \
        "$(printf '%s' "$ekey" | jq -Rs .)" \
        "$(printf '%s' "$obs" | jq -Rs .)"
}

# ---------------------------------------------------------------------------
# validate-request
# ---------------------------------------------------------------------------
cmd_validate_request() {
    local file="${1:-}"
    if [ -z "$file" ]; then
        emit_validate "validate-request" "false" "usage" "validate-request requires <file>"
        exit 1
    fi
    if [ ! -f "$file" ]; then
        emit_validate "validate-request" "false" "usage" "file not found: $file"
        exit 1
    fi
    local raw
    raw=$(cat -- "$file" 2>/dev/null)
    if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
        emit_validate "validate-request" "false" "invalid_json" "request is not a JSON object"
        exit 4
    fi

    local k has
    for k in contract_version task_id iteration change_set_hash spec diff completion_contract impact_report; do
        has=$(printf '%s' "$raw" | jq -r --arg k "$k" 'has($k)' 2>/dev/null || echo "false")
        if [ "$has" != "true" ]; then
            emit_validate "validate-request" "false" "missing_key:$k" "request missing required key: $k"
            exit 4
        fi
    done

    # Extract the two mandatory-non-empty fields up front so the guard block
    # below is self-contained and strippable (the L1 META-test removes it to
    # prove the guards are load-bearing; the enum check after still needs $rt).
    local rt sc
    rt=$(printf '%s' "$raw" | jq -r 'if has("risk_threshold") then (.risk_threshold // "" | tostring) else "" end' 2>/dev/null || echo "")
    sc=$(printf '%s' "$raw" | jq -r 'if has("stop_condition") then (.stop_condition // "" | tostring) else "" end' 2>/dev/null || echo "")
    # MANDATORY-NONEMPTY-START (load-bearing; the L1 META-test strips to END)
    if [ -z "$rt" ]; then
        emit_validate "validate-request" "false" "missing_risk_threshold" "risk_threshold is absent or empty"
        exit 4
    fi
    if [ -z "$sc" ]; then
        emit_validate "validate-request" "false" "missing_stop_condition" "stop_condition is absent or empty"
        exit 4
    fi
    # MANDATORY-NONEMPTY-END
    if [ "$(sev_rank "$rt")" = "0" ]; then
        emit_validate "validate-request" "false" "risk_threshold_invalid_enum" "risk_threshold '$rt' not in critical>high>medium>low>info"
        exit 4
    fi

    emit_validate "validate-request" "true" "" "request valid"
    exit 0
}

# ---------------------------------------------------------------------------
# validate-artifact
# ---------------------------------------------------------------------------
cmd_validate_artifact() {
    local file="${1:-}"
    if [ -z "$file" ]; then
        emit_validate "validate-artifact" "false" "usage" "validate-artifact requires <file>"
        exit 1
    fi
    if [ ! -f "$file" ]; then
        emit_validate "validate-artifact" "false" "usage" "file not found: $file"
        exit 1
    fi
    local raw
    raw=$(cat -- "$file" 2>/dev/null)
    if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
        emit_validate "validate-artifact" "false" "invalid_json" "artifact is not a JSON object"
        exit 4
    fi

    local k has
    for k in contract_version task_id reviewer_identity reviewer_model reviewed_hash risk_threshold stop_condition verdict findings iterations stopped_by; do
        has=$(printf '%s' "$raw" | jq -r --arg k "$k" 'has($k)' 2>/dev/null || echo "false")
        if [ "$has" != "true" ]; then
            emit_validate "validate-artifact" "false" "missing_key:$k" "artifact missing required key: $k"
            exit 4
        fi
    done

    # Control characters in GRAMMAR-BEARING scalars (claude-workflow-plugin-vg8).
    #
    # THE DEFECT CLASS: the record writer embeds these scalars verbatim into a
    # ONE-LINE record comment. An embedded newline splits that record, pushing
    # the findings=[...] token onto a second line; a line-oriented counter then
    # reads a record with no findings token and reports ZERO open findings —
    # silently SUPPRESSING a real critical finding. Rejecting control chars here
    # kills the class at the source (layer 1); the counter additionally treats a
    # findings-token-less record as malformed (layer 2, below).
    #
    # Scope is deliberately PRECISE: only the scalars the record grammar embeds.
    # The reviewer's free-form prose (location / evidence / description) and the
    # non-embedded stop_condition may legitimately span lines, and a blanket ban
    # would reject good reviewer output for no safety gain.
    local ctrl_field
    ctrl_field=$(printf '%s' "$raw" | jq -r '
        def ctrl: (type == "string") and test("[[:cntrl:]]");
        . as $a
        | ((["contract_version","task_id","reviewer_identity","reviewer_model",
             "reviewed_hash","risk_threshold","verdict","stopped_by"]
            | map(select(($a[.]? // "") | ctrl)))
           + (($a.findings? // [])
              | map(select(type == "object"))
              | map(if ((.id? // "") | ctrl) then "findings[].id"
                    elif ((.severity? // "") | ctrl) then "findings[].severity"
                    else empty end))
          )[0] // ""
    ' 2>/dev/null || echo "")
    if [ -n "$ctrl_field" ]; then
        emit_validate "validate-artifact" "false" "scalar_contains_control_char:$ctrl_field" \
            "$ctrl_field contains a control character (newline/CR/tab); record-grammar scalars must be single-line"
        exit 4
    fi

    local verdict
    verdict=$(printf '%s' "$raw" | jq -r '.verdict // ""' 2>/dev/null || echo "")
    case "$verdict" in
        approve|findings) ;;
        *)
            emit_validate "validate-artifact" "false" "verdict_invalid_enum" "verdict '$verdict' not in {approve, findings}"
            exit 4
            ;;
    esac

    local stopped_by
    stopped_by=$(printf '%s' "$raw" | jq -r '.stopped_by // ""' 2>/dev/null || echo "")
    case "$stopped_by" in
        verdict|stop_condition|cap:max_findings|cap:max_review_iterations|cap:timeout) ;;
        *)
            emit_validate "validate-artifact" "false" "stopped_by_invalid_enum" "stopped_by '$stopped_by' not in {verdict, stop_condition, cap:max_findings, cap:max_review_iterations, cap:timeout}"
            exit 4
            ;;
    esac

    local ftype
    ftype=$(printf '%s' "$raw" | jq -r '.findings | type' 2>/dev/null || echo "unknown")
    if [ "$ftype" != "array" ]; then
        emit_validate "validate-artifact" "false" "finding_item_invalid:not_array" "findings is type=$ftype, expected array"
        exit 4
    fi

    # Per-finding validation. First offending reason wins. Each item must be an
    # object carrying id/severity/location/evidence/description; id must match
    # ^R[0-9]+-F[0-9]+$; severity must be a valid enum member.
    local finding_err
    finding_err=$(printf '%s' "$raw" | jq -r '
        (["critical","high","medium","low","info"]) as $sev
        | .findings
        | map(
            . as $f
            | if ($f|type) != "object" then "finding_item_invalid:not_object"
              elif (($f|has("id")) and ($f.id|type=="string")) | not then "finding_item_invalid:missing_id"
              elif (($f|has("severity")) and ($f.severity|type=="string")) | not then "finding_item_invalid:missing_severity"
              elif ($f|has("location")) | not then "finding_item_invalid:missing_location"
              elif ($f|has("evidence")) | not then "finding_item_invalid:missing_evidence"
              elif ($f|has("description")) | not then "finding_item_invalid:missing_description"
              elif ($f.id | test("^R[0-9]+-F[0-9]+$")) | not then "finding_id_malformed"
              elif ($sev | index($f.severity)) == null then "severity_invalid_enum"
              else "ok" end
          )
        | map(select(. != "ok"))
        | .[0] // ""
    ' 2>/dev/null || echo "")
    if [ -n "$finding_err" ]; then
        emit_validate "validate-artifact" "false" "$finding_err" "a findings[] item failed validation: $finding_err"
        exit 4
    fi

    emit_validate "validate-artifact" "true" "" "artifact valid"
    exit 0
}

# ---------------------------------------------------------------------------
# gate — independence + open-finding count over the record comments.
# ---------------------------------------------------------------------------

# emit_gate <exit-code> <ok> <error_key> <observations>  (reads the parsed
# globals: ART_*, REVIEWER, THRESHOLD, IMPL_JSON, OPEN_JSON, OPEN_COUNT,
# INDEPENDENT). Prints the rich envelope, then exits with <exit-code>.
emit_gate() {
    local code="$1" ok="$2" ekey="$3" obs="$4"
    local artifact_json
    artifact_json=$(jq -nc \
        --arg it "${ART_ITER:-}" \
        --arg rev "${REVIEWER:-}" \
        --arg model "${ART_MODEL:-}" \
        --arg hash "${ART_HASH:-}" \
        --arg thr "${THRESHOLD:-}" \
        --arg verdict "${ART_VERDICT:-}" \
        --arg stopped "${ART_STOPPED:-}" \
        --arg findings "${ART_FINDINGS:-}" \
        '{iteration:$it, reviewer:$rev, model:$model, reviewed_hash:$hash, risk_threshold:$thr, verdict:$verdict, stopped_by:$stopped, findings_token:$findings}')
    # shellcheck disable=SC2016
    printf '{"ok":%s,"subcommand":"gate","artifact":%s,"reviewer_identity":%s,"implementers":%s,"independent":%s,"open_findings":%s,"open_finding_ids":%s,"error_key":%s,"observations":%s}\n' \
        "$ok" \
        "$artifact_json" \
        "$(printf '%s' "${REVIEWER:-}" | jq -Rs .)" \
        "${IMPL_JSON:-[]}" \
        "${INDEPENDENT:-true}" \
        "${OPEN_COUNT:-0}" \
        "${OPEN_JSON:-[]}" \
        "$(printf '%s' "$ekey" | jq -Rs .)" \
        "$(printf '%s' "$obs" | jq -Rs .)"
    exit "$code"
}

# normalize_comments — stdin: bd-show JSON | {comments:[...]} | [texts] ;
# stdout: a JSON array of comment TEXT strings.
normalize_comments() {
    jq -c '
        def texts(a): (a // []) | map(if type=="string" then . else (.text // "") end);
        if (type=="array" and (length>0) and (.[0]|type=="object") and (.[0]|has("comments")))
            then texts(.[0].comments)
        elif (type=="object" and has("comments"))
            then texts(.comments)
        elif (type=="array")
            then texts(.)
        else [] end
    ' 2>/dev/null || printf '[]'
}

cmd_gate() {
    local tid="${1:-}"
    shift || true
    local comments_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --comments-json)
                comments_file="${2:-}"
                if [ -z "$comments_file" ]; then
                    emit_validate "gate" "false" "usage" "--comments-json requires a path"
                    exit 1
                fi
                shift 2 || true
                ;;
            *)
                emit_validate "gate" "false" "usage" "unknown argument: $1"
                exit 1
                ;;
        esac
    done
    if [ -z "$tid" ]; then
        emit_validate "gate" "false" "usage" "gate requires <task-id>"
        exit 1
    fi

    # Source the comments (offline seam substitutes bd show --json output).
    local comments_json
    if [ -n "$comments_file" ]; then
        if [ ! -f "$comments_file" ]; then
            emit_validate "gate" "false" "usage" "--comments-json file not found: $comments_file"
            exit 1
        fi
        comments_json=$(normalize_comments < "$comments_file")
    else
        if ! command -v bd >/dev/null 2>&1; then
            emit_validate "gate" "false" "bd_unavailable" "bd CLI not on PATH and no --comments-json given"
            exit 2
        fi
        if [ ! -d "$PROJECT_DIR/.beads" ]; then
            emit_validate "gate" "false" "bd_unavailable" "Beads not initialized ($PROJECT_DIR/.beads missing)"
            exit 2
        fi
        local show
        show=$(bd show "$tid" --json 2>/dev/null || echo "")
        if [ -z "$show" ]; then
            emit_validate "gate" "false" "bd_unavailable" "bd show $tid returned nothing"
            exit 2
        fi
        comments_json=$(printf '%s' "$show" | normalize_comments)
    fi

    # First line of each comment (all grammar records are single-line, so
    # line-oriented matching is correct and multi-line-comment safe).
    local work firstlines
    work=$(mktemp -d -t review-check.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$work' 2>/dev/null || true" RETURN
    firstlines="$work/firstlines.txt"
    printf '%s' "$comments_json" | jq -r '.[] | split("\n")[0]' > "$firstlines" 2>/dev/null || : > "$firstlines"

    # Parsed-artifact globals consumed by emit_gate.
    REVIEWER=""; THRESHOLD=""; ART_ITER=""; ART_MODEL=""; ART_HASH=""
    ART_VERDICT=""; ART_STOPPED=""; ART_FINDINGS=""; IMPL_JSON="[]"
    OPEN_JSON="[]"; OPEN_COUNT="0"; INDEPENDENT="true"

    # art = LAST comment matching /^REVIEW-ARTIFACT v1 /.
    local art
    art=$(grep -E '^REVIEW-ARTIFACT v1 ' "$firstlines" | tail -1 || true)
    if [ -z "$art" ]; then
        emit_gate 4 "false" "review_artifact_missing" "no REVIEW-ARTIFACT v1 comment found for $tid"
    fi

    REVIEWER=$(printf '%s' "$art" | grep -oE 'reviewer=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    THRESHOLD=$(printf '%s' "$art" | grep -oE 'risk_threshold=[A-Za-z0-9_]+' | head -1 | cut -d= -f2- || true)
    ART_ITER=$(printf '%s' "$art" | grep -oE 'iteration=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    ART_MODEL=$(printf '%s' "$art" | grep -oE 'model=[A-Za-z0-9._:/-]+' | head -1 | cut -d= -f2- || true)
    ART_HASH=$(printf '%s' "$art" | grep -oE 'reviewed_hash=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    ART_VERDICT=$(printf '%s' "$art" | grep -oE 'verdict=[A-Za-z]+' | head -1 | cut -d= -f2- || true)
    ART_STOPPED=$(printf '%s' "$art" | grep -oE 'stopped_by=[A-Za-z0-9_:]+' | head -1 | cut -d= -f2- || true)
    ART_FINDINGS=$(printf '%s' "$art" | sed -nE 's/.*findings=\[([^]]*)\].*/\1/p' || true)

    # MALFORMED-ARTIFACT-GUARD-START (load-bearing; the L1 META strips to END)
    # Defense in depth for claude-workflow-plugin-vg8: a record line carrying no
    # WELL-FORMED findings=[...] token is MALFORMED — it must NEVER be read as
    # "zero findings". Both corruption shapes land here: a control character
    # that split the record (the token was pushed to a later line, so this line
    # has no token at all) and a control character inside a finding id (the
    # token is present but its bracket never closes). Reporting malformed keeps
    # a corrupted record from masquerading as a clean review.
    if ! printf '%s' "$art" | grep -qE 'findings=\[[^]]*\]'; then
        emit_gate 4 "false" "review_artifact_malformed" \
            "the latest review record carries no well-formed findings=[...] token (corrupted or truncated record); refusing to read it as zero findings"
    fi
    # MALFORMED-ARTIFACT-GUARD-END

    # impl = unique captures /^IMPLEMENTER: role=([a-z]+) / over comments.
    local impl_lines
    impl_lines=$(grep -oE '^IMPLEMENTER: role=[a-z]+' "$firstlines" | sed -E 's/^IMPLEMENTER: role=//' | sort -u || true)
    if [ -n "$impl_lines" ]; then
        IMPL_JSON=$(printf '%s\n' "$impl_lines" | jq -R . | jq -sc .)
    else
        IMPL_JSON="[]"
    fi

    # independent = (impl empty) OR (reviewer NOT IN impl).
    INDEPENDENT="true"
    if [ -n "$impl_lines" ] && printf '%s\n' "$impl_lines" | grep -qxF "$REVIEWER"; then
        INDEPENDENT="false"
    fi
    if [ "$INDEPENDENT" = "false" ]; then
        emit_gate 4 "false" "reviewer_not_independent" "reviewer '$REVIEWER' is also an implementer role; a reviewer must be independent"
    fi

    # open = findings at/above threshold, minus resolved, minus latest-overrule.
    local tr
    tr=$(threshold_rank "$THRESHOLD")
    local open_ids=()
    local item fid fsev fr rline aline dec
    local oldIFS="$IFS"
    IFS=','
    for item in $ART_FINDINGS; do
        IFS="$oldIFS"
        item=$(printf '%s' "$item" | tr -d '[:space:]')
        [ -z "$item" ] && { IFS=','; continue; }
        fid=${item%%:*}
        fsev=${item#*:}
        [ -z "$fid" ] && { IFS=','; continue; }
        fr=$(sev_rank "$fsev")
        if [ "$fr" -lt "$tr" ]; then
            IFS=','; continue           # below threshold -> ignored
        fi
        # resolved: a /^RESOLVED <id> / comment with non-empty fix= AND test=.
        rline=$(grep -E "^RESOLVED ${fid} " "$firstlines" | tail -1 || true)
        if [ -n "$rline" ] \
            && printf '%s' "$rline" | grep -qE 'fix=[^[:space:]]' \
            && printf '%s' "$rline" | grep -qE 'test=[^[:space:]]'; then
            IFS=','; continue           # resolved
        fi
        # arbitration: LATEST /^ARBITRATION <id> / with decision=overrule clears.
        aline=$(grep -E "^ARBITRATION ${fid} " "$firstlines" | tail -1 || true)
        if [ -n "$aline" ]; then
            dec=$(printf '%s' "$aline" | grep -oE 'decision=[a-z]+' | head -1 | cut -d= -f2- || true)
            if [ "$dec" = "overrule" ]; then
                IFS=','; continue        # overruled
            fi
        fi
        open_ids+=("$fid")
        IFS=','
    done
    IFS="$oldIFS"

    OPEN_COUNT=${#open_ids[@]}
    if [ "$OPEN_COUNT" -gt 0 ]; then
        OPEN_JSON=$(printf '%s\n' "${open_ids[@]}" | jq -R . | jq -sc .)
        emit_gate 4 "false" "unresolved_findings" "$OPEN_COUNT finding(s) at/above risk_threshold=$THRESHOLD remain open"
    fi

    OPEN_JSON="[]"
    emit_gate 0 "true" "" "independent review; no open findings at/above risk_threshold=$THRESHOLD"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
SUB="${1:-}"
shift || true
case "$SUB" in
    validate-request)  cmd_validate_request "$@" ;;
    validate-artifact) cmd_validate_artifact "$@" ;;
    gate)              cmd_gate "$@" ;;
    ""|-h|--help)
        cat >&2 <<'USAGE'
Usage: review-check.sh <subcommand> [args]
  validate-request  <file>                    schema-check a review request
  validate-artifact <file>                    schema-check a review artifact
  gate <task-id> [--comments-json <file>]     independence + open-finding count
Exit: 0 ok | 4 violation | 2 bd-unavailable | 1 usage.
USAGE
        exit 1
        ;;
    *)
        printf 'review-check.sh: unknown subcommand: %s\n' "$SUB" >&2
        exit 1
        ;;
esac

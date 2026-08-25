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
#   validate-completion <file>                  schema-check an F7 completion payload
#   validate-design   <file>                    schema-check a v5 design artifact
#                                               (prose sections + the one
#                                               DESIGN-UNITS machine block)
#   gate <task-id> [--comments-json <file>] [--change-set-hash <h>]
#                                               independence + open-finding count
#                                               + the ROUNDS count (see below)
#
# Exit codes:
#   0  ok / clean
#   4  contract violation (schema invalid, non-independent, open findings)
#   2  bd unavailable (gate could not read comments and no --comments-json)
#   1  usage error
#
# ROUNDS (claude-workflow-plugin-2ty). `gate` additionally reports how many
# review ROUNDS have landed against ONE change set: the number of
# `REVIEW-ARTIFACT v1` FIRSTLINES whose `reviewed_hash=` equals the reference
# hash. The reference is `--change-set-hash <h>` when given, else the LATEST
# artifact's own `reviewed_hash` (so the field is self-consistent with the
# `artifact` block on the same envelope). Two keys carry it: `rounds` (integer)
# and `rounds_hash` (the reference it counted against, so the number is
# auditable rather than merely asserted).
#
# WHO NEEDS IT: verify-before-stop.sh's J21 escalation cap used to charge
# STOP-HOOK PASSES against the defect budget, so a thorough review or a run of
# infrastructure failures could trip a cap that is named for review rounds —
# measured three times in one session, twice with ZERO reviews on the task and
# once while the reviewer was still mid-review. Escalating on
# max(iterations, rounds) makes the counter non-authoritative on its own. Note
# `rounds` is present on the `review_artifact_missing` envelope too (it is 0
# there) — that state is exactly the one the caller must be able to see.
#
# ABSENT rather than zero on the terse envelopes: a usage error or
# `bd_unavailable` answers through emit_validate, which carries NO `rounds` key
# at all. Callers must treat "the key is missing" as UNESTABLISHED and fall back
# to their own signal, never as "zero rounds" — the same discriminator the F1
# fast path applies to `cycle_opened_ts`.
#
# ROUNDS SURVIVE A CYCLE'S OWN HOUSEKEEPING (claude-workflow-plugin-0in1). Pure
# hash-equality silently zeroes a real, findings-bearing review the moment
# `change_set_hash` moves for ANY reason — including reconcile_tracker, which
# the Stop hook runs on EVERY fire and which only ever ADDS git-visible paths
# the post-edit tracker missed (same bytes, wider tracker). Measured on
# claude-workflow-plugin-fkm.3: four HIGH findings landed, reconcile grew the
# tracker with no specialist touching a file, and `gate --change-set-hash
# <post-reconcile hash>` reported rounds=0 — verify-before-stop.sh then printed
# "no reviewer has disagreed with anything" over a task carrying four open HIGH
# findings. See the CYCLE-SURVIVAL region in `cmd_gate` for the counting rule
# (an exception that requires positive evidence — a cycle marker, an in-cycle
# round timestamp, no newer IMPLEMENTER record — never a default), and its two
# new envelope keys: `rounds_basis` (`"cycle"` when that evidence was available
# to consult, `"hash_equality"` when it was not — a reader is never left to
# infer which rule produced the number) and `rounds_stale_hash_count` (how many
# of the counted rounds needed the exception rather than an exact hash match —
# the "say so instead of going silent" half of the fix; the script cannot
# invert a hash back into the path list it was taken over, so it reports how
# many rounds are affected rather than fabricating a per-path diff).
#
# Severity enum (D8, ordered): critical > high > medium > low > info. The
# risk_threshold uses the same enum. `gate` counts a finding as open when its
# severity rank is >= the artifact's risk_threshold rank.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if ! command -v jq >/dev/null 2>&1; then
    # R1-F7 (review round 1, claude-workflow-plugin-fkm.6): this
    # generic pre-dispatch guard runs before subcommand dispatch and so
    # bypasses emit_validate_design entirely — every OTHER error path for
    # validate-design carries unit_files:{} (added for D4's design-conform
    # consumer), but this one, unqualified, did not. Not currently
    # exploitable (design-conform checks jq itself, first, and checks .ok
    # before ever reading .unit_files) but the "every error path defaults
    # to {}" claim was not universally true, so make it true rather than
    # merely disclaim it: when the subcommand IS validate-design, emit the
    # full envelope shape (with the same defaults emit_validate_design's own
    # error paths use — task_id "", not null, matching what `printf '%s' ""
    # | jq -Rs .` actually produces there) instead of the terse 4-key one
    # every OTHER subcommand still gets unchanged.
    if [ "${1:-}" = "validate-design" ]; then
        printf '{"ok":false,"subcommand":"%s","error_key":"jq_missing","observations":"jq is required and not on PATH","units":0,"unit_ids":[],"task_id":"","unit_files":{},"unit_deps":{}}\n' "${1:-}"
    else
        printf '{"ok":false,"subcommand":"%s","error_key":"jq_missing","observations":"jq is required and not on PATH"}\n' "${1:-}"
    fi
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
    for k in contract_version task_id reviewer_identity reviewer_model reviewer_pin reviewed_hash risk_threshold stop_condition verdict findings iterations stopped_by; do
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
        | ((["contract_version","task_id","reviewer_identity","reviewer_model","reviewer_pin",
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

    # CHARACTER CLASS for reviewer_model/reviewer_pin (claude-workflow-plugin-
    # bjx class, applied to a model id — same reasoning and same tested corpus
    # as validate-completion's model/pin check; see that function's comment).
    # reviewer_model is now a RUNTIME SELF-REPORT (qa.md 6-prime) rather than a
    # restated frontmatter value, and reviewer_pin is the frontmatter reading
    # moved to its own honest field name — both need this check for the same
    # reason model/pin do: a class that rejects the session's own model id
    # (`claude-opus-5[1m]`, `gpt-5.6-sol`) is worse than none.
    local rclass_err
    rclass_err=$(printf '%s' "$raw" | jq -r '
        def id_ok: (type == "string") and test("^[]A-Za-z0-9._:/[-]+$");
        . as $a
        | ([ "reviewer_model", "reviewer_pin" ] | map(select(($a[.]? // "") | id_ok | not)))[0] // ""
    ' 2>/dev/null || echo "")
    if [ -n "$rclass_err" ]; then
        emit_validate "validate-artifact" "false" "field_invalid_chars:$rclass_err" \
            "$rclass_err contains a character outside the model-id class [A-Za-z0-9._:/\\[\\]-]; if this is a genuine model id the class needs widening (test against the real id first — see bjx), never work around this by sanitising the value"
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
# validate-completion (P7 / claude-workflow-plugin-qbhw)
# ---------------------------------------------------------------------------
#
# THE F7 SPECIALIST COMPLETION CONTRACT, validated at runtime. Until now the
# contract had ZERO runtime enforcement: an L1 parity spec guarded the
# DOCUMENTS that describe it, and nothing anywhere rejected a payload. A field
# nothing validates is documentation, and `context_coverage` shipped in v4.1
# exactly that way. This is the ONE validation point the v5 plan asks for
# (docs/plans/v5-design-phase.md, Phase P "Runtime contract validation"), and
# every field added to the contract later reuses it rather than growing a
# second checker.
#
# It lives HERE, next to validate-request/validate-artifact, for the reason
# this whole script exists: qa-gate.sh `completion-record` calls it as a
# SUBPROCESS instead of carrying a second copy of the schema, exactly as
# `review-record` calls validate-artifact and as compute_change_set_hash defers
# to impact-report.sh --hash-only. One schema, one place to change it.
#
# STRUCTURAL PURITY (see the file header): nothing below names a transport or a
# lane. It parses a generic payload shape, and the L2 structural-purity test
# that greps this file stays green.
#
# WHAT IT CHECKS, and the deliberate limit on each:
#
#   1. The canonical SEVEN are present. A missing key is `missing_key:<k>` —
#      the same error-key spelling validate-request and validate-artifact use,
#      so a caller has one thing to parse across all three.
#   2. `role` is present. It sits OUTSIDE the seven-key loop on purpose: it is
#      NOT an F7 field (the seven documented in docs/AGENTS.md are unchanged,
#      and the prompts' contract fences still carry exactly those), it is the
#      one grammar-bearing scalar the record writer cannot derive — the record
#      says WHO completed, and nothing else on the payload answers that. Same
#      shape as validate-request's MANDATORY-NONEMPTY block, which likewise
#      guards required fields after its own key loop.
#   3. Control characters in GRAMMAR-BEARING scalars only — `task_id` and
#      `role`. Identical reasoning, and identical failure class, to the
#      validate-artifact scan above (claude-workflow-plugin-vg8): the writer
#      embeds these two verbatim into a ONE-LINE record comment, so an embedded
#      newline splits the record and pushes every later token onto a second
#      line where no line-oriented reader will find it. Scope is deliberately
#      PRECISE: the four free-form fields (`decisions`, `blockers`,
#      `llm_observations`, `context_coverage`) are never interpolated — only
#      their PRESENCE and the payload digest reach the record — and they
#      legitimately span lines. A blanket ban would reject good specialist
#      output for no safety gain.
#   4. Per-field types. The four array fields must be arrays (empty is legal —
#      "no blockers" is a real answer); `files_changed` items must be STRINGS
#      because approve consumes that list as the independent witness for its
#      completeness cross-check (claude-workflow-plugin-fkm.1.20).
#   5. `llm_observations` and `context_coverage` must be non-empty after
#      whitespace trimming. docs/AGENTS.md says a payload without either "is
#      malformed"; this is that sentence made mechanical. A whitespace-only
#      value is the same lie as an empty one, which is why the check trims.
#
# WHAT IT DELIBERATELY DOES NOT CHECK: quality. "Read the relevant code" is a
# non-answer and this validator will accept it. Judging whether a coverage note
# is substantive is the rubric grader's job (default rubric C8) and QA's; the
# validator owns SHAPE. Conflating the two would put a taste judgement in a
# mechanical gate, which is the failure mode the gate exists to avoid.
cmd_validate_completion() {
    local file="${1:-}"
    if [ -z "$file" ]; then
        emit_validate "validate-completion" "false" "usage" "validate-completion requires <file>"
        exit 1
    fi
    if [ ! -f "$file" ]; then
        emit_validate "validate-completion" "false" "usage" "file not found: $file"
        exit 1
    fi
    local raw
    raw=$(cat -- "$file" 2>/dev/null)
    if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
        emit_validate "validate-completion" "false" "invalid_json" "completion payload is not a JSON object"
        exit 4
    fi

    local k has
    for k in task_id files_changed tests_added decisions blockers llm_observations context_coverage; do
        has=$(printf '%s' "$raw" | jq -r --arg k "$k" 'has($k)' 2>/dev/null || echo "false")
        if [ "$has" != "true" ]; then
            emit_validate "validate-completion" "false" "missing_key:$k" \
                "completion payload missing required key: $k (the canonical seven are task_id, files_changed, tests_added, decisions, blockers, llm_observations, context_coverage)"
            exit 4
        fi
    done

    # See note 2 above: required, but not one of the seven.
    has=$(printf '%s' "$raw" | jq -r 'has("role")' 2>/dev/null || echo "false")
    if [ "$has" != "true" ]; then
        emit_validate "validate-completion" "false" "missing_key:role" \
            "completion payload missing required key: role — the record names WHO completed the task and nothing else in the payload answers that. It is transport metadata for the record grammar, NOT an eighth F7 field"
        exit 4
    fi

    # model/pin (claude-workflow-plugin-46w9): required in the SAME shape as
    # role — transport metadata for the record grammar, not F7 fields. `pin`
    # is the specialist's own STATIC frontmatter `model:` reading; `model` is
    # a RUNTIME SELF-REPORT (what the specialist states about its own
    # identity, not derived by re-reading its frontmatter a second time).
    # Recording both is the point: their divergence is the production
    # measurement of whether the runtime honours the frontmatter pin, and
    # that measurement needs BOTH present on every completion record to mean
    # anything, not just when they happen to agree.
    for k in model pin; do
        has=$(printf '%s' "$raw" | jq -r --arg k "$k" 'has($k)' 2>/dev/null || echo "false")
        if [ "$has" != "true" ]; then
            emit_validate "validate-completion" "false" "missing_key:$k" \
                "completion payload missing required key: $k — recorded alongside role; $k is transport metadata for the record grammar (46w9), not an F7 field"
            exit 4
        fi
    done

    # Note 3: control characters in the scalars the record grammar embeds.
    local ctrl_field
    ctrl_field=$(printf '%s' "$raw" | jq -r '
        def ctrl: (type == "string") and test("[[:cntrl:]]");
        . as $p
        | ((["task_id","role","model","pin"] | map(select(($p[.]? // "") | ctrl)))
          )[0] // ""
    ' 2>/dev/null || echo "")
    if [ -n "$ctrl_field" ]; then
        emit_validate "validate-completion" "false" "scalar_contains_control_char:$ctrl_field" \
            "$ctrl_field contains a control character (newline/CR/tab); it is embedded verbatim in the one-line COMPLETION record, and a control character there splits the record so every later token lands on a line no reader parses"
        exit 4
    fi

    # Note 4/5: per-field types, then the mandatory non-empty strings. ONE jq
    # pass, first offending field wins, so the error names a field rather than
    # reporting "something was wrong". Runs BEFORE the character-class check
    # below on purpose: a non-string or empty model/pin should be reported as
    # a type/empty problem, not as "wrong characters" — id_ok would also
    # reject it, but with a more confusing message.
    local type_err
    type_err=$(printf '%s' "$raw" | jq -r '
        def nonempty_string: (type == "string") and ((gsub("[[:space:]]";"")) != "");
        . as $p
        | [ (if ($p.task_id | type) != "string" then "field_type_invalid:task_id"
             elif ($p.task_id | nonempty_string) | not then "field_empty:task_id"
             else empty end),
            (if ($p.role | type) != "string" then "field_type_invalid:role"
             elif ($p.role | nonempty_string) | not then "field_empty:role"
             else empty end),
            (["model","pin"]
             | map(. as $k
                   | if ($p[$k] | type) != "string" then "field_type_invalid:" + $k
                     elif ($p[$k] | nonempty_string) | not then "field_empty:" + $k
                     else empty end)
             | .[]),
            (["files_changed","tests_added","decisions","blockers"]
             | map(select(($p[.] | type) != "array") | "field_type_invalid:" + .)
             | .[]),
            (if ($p.files_changed | type) == "array"
                and (($p.files_changed | map(select(type != "string")) | length) > 0)
             then "field_type_invalid:files_changed[]" else empty end),
            (["llm_observations","context_coverage"]
             | map(select(($p[.] | type) != "string") | "field_type_invalid:" + .)
             | .[]),
            (["llm_observations","context_coverage"]
             | map(select((($p[.] | type) == "string") and (($p[.] | nonempty_string) | not))
                   | "field_empty:" + .)
             | .[])
          ]
        | .[0] // ""
    ' 2>/dev/null || echo "")
    if [ -n "$type_err" ]; then
        local detail="a field failed its type check: $type_err"
        case "$type_err" in
            field_empty:llm_observations|field_empty:context_coverage)
                detail="$type_err — this field is mandatory free-form text; docs/AGENTS.md states a completion payload without it is malformed, and a whitespace-only value is the same claim as an empty one"
                ;;
            field_type_invalid:files_changed*)
                detail="$type_err — files_changed must be an array of strings; approve reads it as the INDEPENDENT witness of what the session touched (claude-workflow-plugin-fkm.1.20), so a non-string item makes that cross-check unanswerable"
                ;;
        esac
        emit_validate "validate-completion" "false" "$type_err" "$detail"
        exit 4
    fi

    # CHARACTER CLASS for model/pin (claude-workflow-plugin-bjx class, applied
    # to a model id): reject, never sanitise. Real model ids in this tree
    # contain letters, digits, `.`, `-`, `:`, `/` AND BRACKETS —
    # `claude-opus-5[1m]` is a real, observed runtime id (see the ledger note
    # on claude-workflow-plugin-gz3: "the model that actually performed the
    # review rather than the pin that would normally apply"). The class below
    # is tested against that exact corpus (subagent-start.sh's
    # model_id_class_ok is the byte-identical sibling check on the writing
    # side); a class that rejected the session's own model id would be worse
    # than none, because it would make the self-report mechanism unusable on
    # the one id it most needs to carry. Runs AFTER type_err above, which
    # already established both fields are non-empty strings, so a failure
    # here is unambiguously about the characters and nothing else.
    local class_err
    class_err=$(printf '%s' "$raw" | jq -r '
        def id_ok: (type == "string") and test("^[]A-Za-z0-9._:/[-]+$");
        . as $p
        | ([ "model", "pin" ] | map(select(($p[.]? // "") | id_ok | not)))[0] // ""
    ' 2>/dev/null || echo "")
    if [ -n "$class_err" ]; then
        emit_validate "validate-completion" "false" "field_invalid_chars:$class_err" \
            "$class_err contains a character outside the model-id class [A-Za-z0-9._:/\\[\\]-]; if this is a genuine model id the class needs widening (test against the real id first — see bjx), never work around this by sanitising the value"
        exit 4
    fi

    emit_validate "validate-completion" "true" "" "completion payload valid"
    exit 0
}

# ---------------------------------------------------------------------------
# validate-design (v5 Phase D1 / claude-workflow-plugin-fkm.3)
# ---------------------------------------------------------------------------
#
# THE DESIGN ARTIFACT is a Markdown document a human reads, carrying ONE machine
# block a program reads. This validates the machine block, plus the presence of
# the prose sections the artifact is required to have. It does not judge design
# quality — `.claude/rubrics/design.md` and the design reviewer do that (D2), the
# same division validate-completion's tail states for coverage notes.
#
# THE EXTRACTION IS SPECIFIED HERE FROM SCRATCH, and deliberately not modelled on
# `epic-gate.sh files_changed_of`, which the v5 plan pointed at as "the same
# discipline". Measured against that idiom at acc4ce1: it is four piped `jq`
# invocations whose selector is `jq -R 'capture("(?<j>\\{[^{}]*\"files_changed\"
# [^{}]*\\})"; "g")'`. `jq -R` is LINE-ORIENTED, so a PRETTY-PRINTED object never
# matches (each line is a separate input and no single line contains the whole
# object), and `[^{}]*` cannot cross a brace, so any NESTED object never matches
# either. Both return `[]` — indistinguishable from "no block", from "malformed
# block", and from "jq is missing", all four with no error key. An LLM writing a
# fenced JSON block pretty-prints it essentially always, and every unit in this
# schema is a nested object, so that idiom would report ZERO UNITS for the normal
# case and every coherence check downstream would pass vacuously over nothing.
#
# THE FOUR RULES THIS ONE FOLLOWS INSTEAD, each with the precedent it comes from:
#
#   1. COUNT THE SENTINELS; REFUSE ON ANYTHING BUT EXACTLY ONE PAIR, in order.
#      Nothing enforces "one machine block", and an artifact amended in place
#      across D2 review rounds will plausibly grow a second. An `awk /BEGIN/,/END/`
#      range silently RE-OPENS on a second BEGIN and concatenates two blocks into
#      one unparseable string; a `tail -1` selector would silently pick the last.
#      Refusing is the only answer that cannot be wrong quietly.
#
#   2. THE SENTINELS MUST OWN THEIR LINE. `review-check.sh`'s own ROUNDS block
#      records why: on claude-workflow-plugin-8zi, BEFORE any artifact existed,
#      `grep -c REVIEW-ARTIFACT` returned 1 and the hit was PROSE inside a
#      reviewer's note. Agents quote record grammars constantly, and a design
#      artifact is a document ABOUT a design — the single most likely place for
#      someone to write the sentinel inside a sentence. Whole-line anchoring makes
#      a quoted mention a non-match; a quoted mention that IS alone on its line
#      makes the count 2 and is refused by rule 1, which is the safe direction.
#
#   3. UNPARSEABLE IS NEVER ZERO. Every failure below has its own error_key and a
#      non-zero exit. `cmd_gate`'s MALFORMED-ARTIFACT-GUARD refuses to read a
#      token-less record as zero findings for exactly this reason, and
#      `max_record_ts` prints the literal `unparseable` rather than empty so a
#      caller can tell "absent" from "unreadable". Zero units must mean the
#      designer declared none, never that this function could not read them.
#
#   4. FENCE STRIPPING IS ANCHORED TO THE BLOCK. The repo's only prior fence
#      handling (in the external-review helper under .claude/scripts/, named
#      there rather than here — this file is required to carry zero references to
#      any specific review transport, and a structural spec greps for exactly
#      that) strips ``` lines unconditionally over the whole input, which would
#      concatenate a nested example fence into the JSON. Here the block must be
#      EITHER bare JSON or exactly one fence pair wrapping it, and any other
#      arrangement is named and refused.
#
# WHY THE PROSE SECTIONS ARE CHECKED HERE TOO: they are a SHAPE fact ("does the
# document have a Problem section?"), not a quality judgement, and the release
# directive asks for "missing required section rejected" as an L1 assertion. The
# check is presence of the heading, nothing more.
DESIGN_UNITS_BEGIN_RE='^[[:space:]]*<!-- DESIGN-UNITS BEGIN -->[[:space:]]*$'
DESIGN_UNITS_END_RE='^[[:space:]]*<!-- DESIGN-UNITS END -->[[:space:]]*$'

# The prose sections a design artifact must carry, as `## ` headings. Matched
# case-insensitively on the heading text and nothing else.
DESIGN_REQUIRED_SECTIONS="Problem|Approaches considered|Chosen approach|Units|Global constraints|Out of scope|Verification plan|Revision log"

# emit_validate_design <ok> <error_key> <observations> <unit-count> <unit-ids-json> [task-id] [unit-files-json] [unit-deps-json]
# emit_validate's four keys plus the FIVE a caller needs in order to write a
# record or compute a per-unit conformance/batching check without
# re-parsing the block: how many units were declared, which, the task the
# artifact says it designs, each unit's OWN declared `files` array (v5 D4,
# claude-workflow-plugin-fkm.6), and (v5 D4b, claude-workflow-plugin-fkm.6,
# plan-batches) each unit's OWN declared `depends_on` array, BOTH keyed by
# unit_id — `{"U1":["a.sh"],"U2":[...]}` / `{"U1":[],"U2":["U1"]}` — `{}` on
# every error path (the 14 error call sites below all omit the 7th/8th
# argument and get the default). `task_id` was already on the envelope
# DELIBERATELY — qa-gate.sh's design-record needs it for its decoy check —
# for the reason `unit_files` joined it for and `unit_deps` joins it for
# too: extracting any of these there with a second awk/jq pass would be a
# SECOND parser for one grammar, which is the thing this script exists to
# prevent (see the header, and the way compute_change_set_hash defers to
# impact-report.sh --hash-only).
# qa-gate.sh design-conform is `unit_files`'s consumer: it needs one
# resolved unit's declared file set to compute undeclared/unbuilt.
# epic-gate.sh plan-batches is `unit_deps`'s consumer: dependency order
# (docs/plans/v5-design-phase.md:158, ":159" tests) cannot be computed from
# `depends_on` without ALSO reparsing the block, so it gets the same
# treatment. Both are read from the SAME validated `$block`
# `cmd_validate_design` already holds at the one point it is known
# schema-valid — never a re-read of the artifact from disk.
# (xsu1 H2R2-F4) Built as ONE guarded `jq -nc` assignment, validated, THEN
# printed — never as jq substitutions spliced into a printf argument list. A
# failing inner substitution does NOT abort the outer printf even under
# `set -e` (`printf '{"x":%s}\n' "$(false)"` prints `{"x":}` and continues,
# rc 0 — the same reproduction print_envelope_checked in qa-gate.sh cites),
# so the old shape could emit malformed JSON at exit 0 from the SUCCESS call
# site. On any construction failure this prints a CALLER-DATA-FREE literal
# carrying the full field set (units 0, empty ids, {} maps — the error-path
# defaults consumers already handle) and returns 1; the success call site
# checks that status (`|| exit 2`), and every error call site already exits
# nonzero on its own next line. jq presence is guaranteed here by the
# pre-dispatch jq-missing literal (this file's own R1-F7 fix), so a failure
# in this build is a jq MALFUNCTION, not absence. (R7-F5) Validation is
# rc + non-emptiness + the EXACT envelope shape — parseability alone lets a
# parseable-but-wrong build ([] at rc 0) through, since `jq -e` only fails
# on false/null.
emit_validate_design() {
    local ok="$1" ekey="$2" obs="$3" n="$4" ids="$5" tid="${6:-}" ufiles="${7:-}" udeps="${8:-}"
    [ -n "$ufiles" ] || ufiles="{}"
    [ -n "$udeps" ] || udeps="{}"
    local envelope="" env_rc=0
    envelope=$(jq -nc \
        --argjson ok "$ok" --arg ekey "$ekey" --arg obs "$obs" \
        --argjson n "$n" --argjson ids "$ids" --arg tid "$tid" \
        --argjson ufiles "$ufiles" --argjson udeps "$udeps" '
        # validate-design envelope construction (xsu1 H2R2-F4)
        {ok: $ok, subcommand: "validate-design", error_key: $ekey,
         observations: $obs, units: $n, unit_ids: $ids, task_id: $tid,
         unit_files: $ufiles, unit_deps: $udeps}
    ' 2>/dev/null) || env_rc=$?
    # (xsu1 R7-F5) SHAPE, not just parseability: `jq -n -e '[]'` is rc 0
    # (-e fails only on false/null), so a build that "succeeded" into [] /
    # {} / a wrong object would print under a success status if this only
    # asked "does it parse?". Stripping the sentinel region leaves the
    # historical parseability-only `.` — the L1 META does exactly that and
    # watches a parseable-but-wrong build print at exit 0.
    local shape_prog='.'
# VALIDATE-DESIGN-ENVELOPE-SHAPE-GATE BEGIN (xsu1 R7-F5)
    shape_prog='
        # validate-design envelope shape (xsu1 R7-F5)
        type == "object"
        and (keys | sort) == ["error_key", "observations", "ok", "subcommand", "task_id", "unit_deps", "unit_files", "unit_ids", "units"]
        and (.ok | type) == "boolean"
        and .subcommand == "validate-design"
        and (.error_key | type) == "string"
        and (.observations | type) == "string"
        and (.units | type) == "number"
        and (.unit_ids | type) == "array"
        and (.task_id | type) == "string"
        and (.unit_files | type) == "object"
        and (.unit_deps | type) == "object"
    '
# VALIDATE-DESIGN-ENVELOPE-SHAPE-GATE END (xsu1 R7-F5)
    if [ "$env_rc" -eq 0 ] && [ -n "$envelope" ] \
       && printf '%s' "$envelope" | jq -e "$shape_prog" >/dev/null 2>&1; then
        printf '%s\n' "$envelope"
        return 0
    fi
    printf '{"ok":false,"subcommand":"validate-design","error_key":"envelope_construction_failed","observations":"the validate-design envelope could not be constructed (jq failed, or produced unparseable or wrong-shaped output); refusing to print it under a success status. No caller-supplied data is included in this message","units":0,"unit_ids":[],"task_id":"","unit_files":{},"unit_deps":{}}\n'
    return 1
}

cmd_validate_design() {
    local file="${1:-}"
    if [ -z "$file" ]; then
        emit_validate_design "false" "usage" "validate-design requires <file>" "0" "[]"
        exit 1
    fi
    if [ ! -f "$file" ]; then
        emit_validate_design "false" "usage" "file not found: $file" "0" "[]"
        exit 1
    fi
    if [ ! -s "$file" ]; then
        emit_validate_design "false" "design_artifact_empty" \
            "the design artifact at $file is zero bytes; an empty artifact is refused here rather than read as a design with no units" "0" "[]"
        exit 4
    fi

    # --- prose sections -----------------------------------------------------
    # Read line by line rather than `for s in $LIST` under a swapped IFS. An
    # unquoted expansion performs PATHNAME EXPANSION as well as word splitting,
    # and this file's sibling records what that costs: a completion-payload key
    # named `[c]lean1` expanded to `clean1` when a file of that name happened to
    # exist in the process's working directory and stayed `[c]lean1` when it did
    # not, so one payload got opposite verdicts decided by an unrelated
    # directory. The list here is a constant with no metacharacter in it today,
    # which makes this structural rather than a fix — the next section name to be
    # added cannot reintroduce it.
    local section missing_sections=""
    while IFS= read -r section; do
        [ -n "$section" ] || continue
        if ! grep -qiE "^##+[[:space:]]+${section}[[:space:]]*\$" "$file" 2>/dev/null; then
            missing_sections="${missing_sections:+$missing_sections, }$section"
        fi
    done <<< "$(printf '%s' "$DESIGN_REQUIRED_SECTIONS" | tr '|' '\n')"
    if [ -n "$missing_sections" ]; then
        emit_validate_design "false" "design_section_missing" \
            "the design artifact is missing required section heading(s): $missing_sections. Each must appear as its own '## <name>' heading" "0" "[]"
        exit 4
    fi

    # --- rule 1 + 2: exactly one sentinel pair, each owning its line ---------
    local n_begin n_end
    n_begin=$(grep -cE "$DESIGN_UNITS_BEGIN_RE" "$file" 2>/dev/null) || n_begin=0
    n_end=$(grep -cE "$DESIGN_UNITS_END_RE" "$file" 2>/dev/null) || n_end=0
    n_begin=$(printf '%s' "$n_begin" | tr -d ' \n')
    n_end=$(printf '%s' "$n_end" | tr -d ' \n')
    if [ "$n_begin" != "1" ] || [ "$n_end" != "1" ]; then
        emit_validate_design "false" "design_units_sentinels" \
            "the artifact must carry EXACTLY ONE '<!-- DESIGN-UNITS BEGIN -->' / '<!-- DESIGN-UNITS END -->' pair, each alone on its own line; found begin=$n_begin end=$n_end. Two blocks (an in-place amendment that appended rather than revised) or none are both refused rather than guessed at" "0" "[]"
        exit 4
    fi
    local ln_begin ln_end
    ln_begin=$(grep -nE "$DESIGN_UNITS_BEGIN_RE" "$file" | head -1 | cut -d: -f1)
    ln_end=$(grep -nE "$DESIGN_UNITS_END_RE" "$file" | head -1 | cut -d: -f1)
    if [ "$ln_end" -le "$ln_begin" ]; then
        emit_validate_design "false" "design_units_sentinels_disordered" \
            "the DESIGN-UNITS END sentinel (line $ln_end) precedes or equals BEGIN (line $ln_begin)" "0" "[]"
        exit 4
    fi

    # --- extract strictly between them --------------------------------------
    local block
    block=$(awk -v b="$ln_begin" -v e="$ln_end" 'NR > b && NR < e' "$file" 2>/dev/null)

    # --- rule 4: anchored fence handling ------------------------------------
    # Trim blank lines at both ends, then accept either bare JSON or exactly one
    # fence pair wrapping it. Any other arrangement is named.
    block=$(printf '%s\n' "$block" | awk 'NF {p = 1} p' | awk '{a[NR] = $0} END {last = 0; for (i = 1; i <= NR; i++) if (a[i] ~ /[^ \t]/) last = i; for (i = 1; i <= last; i++) print a[i]}')
    local n_fence
    n_fence=$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*```' 2>/dev/null) || n_fence=0
    n_fence=$(printf '%s' "$n_fence" | tr -d ' \n')
    if [ "$n_fence" != "0" ]; then
        if [ "$n_fence" != "2" ]; then
            emit_validate_design "false" "design_block_fences" \
                "the DESIGN-UNITS block contains $n_fence code-fence line(s); it must contain either none (bare JSON) or exactly two (one fence pair wrapping the JSON). A nested fence would otherwise be concatenated into the JSON" "0" "[]"
            exit 4
        fi
        local first_line last_line
        first_line=$(printf '%s\n' "$block" | head -1)
        last_line=$(printf '%s\n' "$block" | tail -1)
        if ! printf '%s' "$first_line" | grep -qE '^[[:space:]]*```' \
            || ! printf '%s' "$last_line" | grep -qE '^[[:space:]]*```[[:space:]]*$'; then
            emit_validate_design "false" "design_block_fences_unanchored" \
                "the DESIGN-UNITS block has two fence lines but they do not open and close the block; the JSON must be the whole of the fenced body" "0" "[]"
            exit 4
        fi
        block=$(printf '%s\n' "$block" | sed '1d;$d')
    fi
    if [ -z "$(printf '%s' "$block" | tr -d '[:space:]')" ]; then
        emit_validate_design "false" "design_block_empty" \
            "the DESIGN-UNITS block is empty; refusing to read an empty block as a design with zero units" "0" "[]"
        exit 4
    fi

    # --- rule 3: parse, or say so -------------------------------------------
    if ! printf '%s' "$block" | jq -e 'type == "object"' >/dev/null 2>&1; then
        emit_validate_design "false" "design_block_unparseable" \
            "the DESIGN-UNITS block is not a parseable JSON object. It is refused rather than read as zero units — a design nothing can parse is not a design with no work in it" "0" "[]"
        exit 4
    fi

    # --- schema -------------------------------------------------------------
    # ONE jq pass, first offending item wins, so the error names a field rather
    # than reporting "something was wrong". Structured exactly like
    # validate-completion's type_err pass, for the same reason.
    local schema_err
    schema_err=$(printf '%s' "$block" | jq -r '
        def nonempty_string: (type == "string") and ((gsub("[[:space:]]";"")) != "");
        def strarray: (type == "array") and (length > 0) and (all(.[]; nonempty_string));
        . as $d
        | (if ($d.units? | type) == "array" then $d.units else [] end) as $u
        | [ ( if ($d.contract_version? // "") != "1" then "contract_version_invalid" else empty end),
            ( if ($d.task_id? | nonempty_string) | not then "task_id_missing" else empty end),
            ( if ($d.designer_identity? | nonempty_string) | not then "designer_identity_missing" else empty end),
            ( if ($d.units? | type) != "array" then "units_not_an_array"
              elif ($u | length) == 0 then "units_empty" else empty end),
            ( $u | to_entries[]
              | .key as $i | .value as $x
              | ( if ($x | type) != "object" then "unit_not_an_object:\($i)"
                  elif ($x.unit_id? | nonempty_string) | not then "unit_id_missing:\($i)"
                  elif ($x.unit_id | test("^[A-Za-z0-9._-]+$") | not) then "unit_id_invalid_chars:\($x.unit_id)"
                  elif ($x.goal? | nonempty_string) | not then "unit_goal_missing:\($x.unit_id)"
                  elif ($x.verification? | nonempty_string) | not then "unit_verification_missing:\($x.unit_id)"
                  elif ($x.files? | strarray) | not then "unit_files_missing:\($x.unit_id)"
                  elif ($x.acceptance? | type) != "array" or ($x.acceptance | length) == 0
                       then "unit_acceptance_missing:\($x.unit_id)"
                  elif ($x.acceptance | any(.[]; (type != "object")
                                                 or ((.id? | nonempty_string) | not)
                                                 or ((.text? | nonempty_string) | not)))
                       then "unit_acceptance_id_missing:\($x.unit_id)"
                  elif ($x.depends_on? | type) != "array" then "unit_depends_on_not_an_array:\($x.unit_id)"
                  elif ($x.implementer_class? // "standard") == "high"
                       and (($x.escalation_reason? | (type == "string") and (gsub("[[:space:]]";"") != "")) | not)
                       then "unit_escalation_without_reason:\($x.unit_id)"
                  else empty end ) ),
            ( ($u | map(.unit_id?) | group_by(.) | map(select(length > 1) | .[0]))[]? | "unit_id_duplicate:\(.)" ),
            ( [ $u[] | .acceptance? // [] | .[]? | .id? ] | group_by(.) | map(select(length > 1) | .[0])[]?
              | "acceptance_id_duplicate:\(.)" ),
            # `index($dep)` with the dependency BOUND FIRST, never `index(.)`.
            # A function argument in jq is evaluated against that function s
            # INPUT, so `$ids | index(.)` searches $ids for $ids and returns 0
            # for every dependency — the check would pass unconditionally.
            # Measured before the fix: a unit depending on an undeclared "U9"
            # validated clean.
            ( ($u | map(.unit_id?)) as $ids
              | $u[] | .unit_id as $me | (.depends_on? // [])[]? | . as $dep
              | if $dep == $me then "unit_depends_on_self:\($me)"
                elif ($ids | index($dep)) == null then "unit_depends_on_undeclared:\($me)->\($dep)"
                else empty end )
          ]
        | .[0] // ""
    ' 2>/dev/null) || schema_err="jq_failed"
    if [ -n "$schema_err" ]; then
        local detail="the design contract failed its schema check: $schema_err"
        case "$schema_err" in
            unit_files_missing:*)
                detail="$schema_err — every unit must declare a NON-EMPTY \`files\` array of paths. That field is not documentation: D4 computes parallel batches from the intersection of declared file sets and D5 checks what a unit touched against it, so a unit with no declared files makes both checks pass over nothing"
                ;;
            unit_acceptance_id_missing:*)
                detail="$schema_err — every acceptance criterion must be an object with a non-empty \`id\` and \`text\`. The id is what the coherence rollup maps a passing test back to; a criterion without one cannot be reported as covered or uncovered"
                ;;
            unit_escalation_without_reason:*)
                detail="$schema_err — a unit marked \`implementer_class: high\` must carry \`escalation_reason\`. Escalation is a declared, audited, reversible pin change and the reason is the audit"
                ;;
            unit_depends_on_undeclared:*)
                detail="$schema_err — a unit depends on an id no unit declares, so the dependency graph cannot be scheduled"
                ;;
            jq_failed)
                detail="the schema check could not be run (jq failed on the parsed block); refusing rather than reporting a design that was never checked"
                ;;
        esac
        emit_validate_design "false" "$schema_err" "$detail" "0" "[]"
        exit 4
    fi

    # --- acyclicity, computed rather than judged ----------------------------
    # Kahn's algorithm: repeatedly drop units all of whose dependencies are
    # already dropped. Anything left is in a cycle. A cyclic artifact is
    # unschedulable by construction, and finding that out at D4 (after tasks are
    # created) rather than here is strictly worse.
    #
    # `index($i)` with the id BOUND FIRST, for the reason spelled out in the
    # schema pass above. The unbound spelling `index(.id)` does not merely
    # return a wrong answer here, it makes jq ABORT ("Cannot index array with
    # string \"id\""), and the abort is only reachable once something becomes
    # ready — so a pure two-unit cycle was still caught while every graph with a
    # root silently reported "acyclic" from a jq that never ran. Both shapes were
    # reproduced before this fix.
    #
    # A FAILED COMPUTATION IS NOT "NO CYCLE". The rc is captured and reported
    # rather than swallowed into an empty string, per rule 3 above.
    local cyclic cyc_rc=0
    cyclic=$(printf '%s' "$block" | jq -r '
        def kahn:
            . as $s
            | ([ $s.left[] | select( ([.deps[]] - $s.done) == [] ) ] | map(.id)) as $ready
            | if ($ready | length) == 0
              then $s
              else { done: ($s.done + $ready),
                     left: [ $s.left[] | select( .id as $i | ($ready | index($i)) == null ) ] } | kahn
              end;
        { done: [], left: [ .units[] | {id: .unit_id, deps: (.depends_on // [])} ] }
        | kahn | .left | map(.id) | join(",")
    ' 2>/dev/null) || cyc_rc=$?
    if [ "$cyc_rc" -ne 0 ]; then
        emit_validate_design "false" "design_units_cycle_check_failed" \
            "the unit dependency graph could not be checked for cycles (jq exited $cyc_rc); refusing rather than reporting an artifact whose schedulability was never established" "0" "[]"
        exit 4
    fi
    if [ -n "$cyclic" ]; then
        emit_validate_design "false" "design_units_cyclic" \
            "the unit dependency graph has a cycle; these units can never become ready: $cyclic" "0" "[]"
        exit 4
    fi

    # --- final extraction — ONE guarded jq pass (xsu1 H2-F1) ----------------
    # The previous shape here was FIVE consecutive `$(...) || <default>`
    # extractions (defaults 0 / [] / "" / {} / {}) followed by an
    # unconditional ok:true — the sixth instance of the fail-open class this
    # slice kept reintroducing. A failed `.units | length` read as "zero
    # units"; a failed `depends_on` read as "no dependencies", which lets
    # plan-batches co-batch units that genuinely depend on each other. Rule 3
    # of this subcommand's own header ("unparseable is never zero") applies
    # to the SUCCESS path too: everything a consumer will read is now
    # computed in one jq invocation whose rc is checked, and whose output is
    # shape-validated INSIDE the same program — both maps must be objects
    # keyed exactly by the declared unit_ids with array values — before
    # anything is emitted. `{}` on the success envelope is therefore
    # unreachable for these maps (the schema pass refuses units_empty), and
    # on an error envelope it is emit_validate_design's default, never the
    # residue of a computation that silently failed.
    #
    # unit_id uniqueness is already enforced by the schema pass above
    # (unit_id_duplicate), so `from_entries` here never silently drops a
    # unit behind a repeated key — by the time this runs, the keys are
    # already known distinct. task_id is already known to be a non-empty
    # string (task_id_missing), so the string-type check below can only fire
    # on a jq malfunction, never on a schema-valid artifact.
    local n="0" ids="[]" art_tid="" ufiles="{}" udeps="{}"
    local extracted="" ext_rc=0
    extracted=$(printf '%s' "$block" | jq -ce '
        # validate-design-final-extraction (xsu1 H2-F1) — fault-injection
        # marker: the L1 shim matches THIS comment to fail exactly this call.
        (.units // []) as $u
        | ($u | map(.unit_id)) as $ids
        | { n: ($u | length),
            ids: $ids,
            task_id: (.task_id // ""),
            unit_files: ([ $u[] | {key: .unit_id, value: (.files // [])} ] | from_entries),
            unit_deps:  ([ $u[] | {key: .unit_id, value: (.depends_on // [])} ] | from_entries) }
        | if ( (.task_id | type) == "string"
               and (.unit_files | type) == "object"
               and (.unit_deps  | type) == "object"
               and ((.unit_files | keys | sort) == ($ids | sort))
               and ((.unit_deps  | keys | sort) == ($ids | sort))
               and ([ .unit_files[] | type ] | all(. == "array"))
               and ([ .unit_deps[]  | type ] | all(. == "array"))
               and (.n == ($ids | length)) )
          then .
          else error("extraction shape mismatch")
          end
    ' 2>/dev/null) || ext_rc=$?
    if [ "$ext_rc" -eq 0 ] && [ -n "$extracted" ]; then
        n=$(printf '%s' "$extracted" | jq -r '.n' 2>/dev/null) || ext_rc=$?
        ids=$(printf '%s' "$extracted" | jq -c '.ids' 2>/dev/null) || ext_rc=$?
        art_tid=$(printf '%s' "$extracted" | jq -r '.task_id # validate-design task_id split (xsu1 H2R2-F4)' 2>/dev/null) || ext_rc=$?
        ufiles=$(printf '%s' "$extracted" | jq -c '.unit_files' 2>/dev/null) || ext_rc=$?
        udeps=$(printf '%s' "$extracted" | jq -c '.unit_deps' 2>/dev/null) || ext_rc=$?
        # These splits re-read the ALREADY-VALIDATED single-pass output, so a
        # failure here means jq itself broke mid-run — refuse on that too,
        # and re-check the spliced shapes (a jq that exits 0 while printing
        # nothing would otherwise splice empty strings into the envelope,
        # which is malformed JSON emitted under ok:true).
        case "$n" in (''|*[!0-9]*) ext_rc=5 ;; esac
        case "$ids" in ('['*) : ;; (*) ext_rc=5 ;; esac
        case "$ufiles" in ('{'*) : ;; (*) ext_rc=5 ;; esac
        case "$udeps" in ('{'*) : ;; (*) ext_rc=5 ;; esac
        # (xsu1 H2R2-F4) task_id was the ONE residual split without a
        # successful-but-empty check. The schema pass already refused an
        # empty task_id (task_id_missing) and the single-pass extraction
        # re-validated it as a string, so an empty value HERE can only be a
        # jq that exited 0 while printing nothing — a malfunction, refused
        # like the four above rather than emitted as ok:true with task_id "".
        [ -n "$art_tid" ] || ext_rc=5
    else
        [ "$ext_rc" -ne 0 ] || ext_rc=5
    fi
    # VALIDATE-DESIGN-EXTRACTION-REFUSAL BEGIN (xsu1 H2-F1)
    # A failed computation is not "zero units / no ids / no dependencies".
    # This refusal is what stands between an extraction failure and an
    # ok:true envelope carrying the fail-open defaults declared above; the
    # L1 META (design-artifact.test.sh section 2b) strips this region and
    # watches exactly that envelope come back under an induced jq failure.
    # Do not rename the sentinels.
    if [ "$ext_rc" -ne 0 ]; then
        emit_validate_design "false" "design_units_extraction_failed" \
            "the final unit_ids/unit_files/unit_deps extraction could not be computed from the validated block (jq exited $ext_rc, or produced an unexpected shape); refusing rather than reporting a design whose declarations were never actually read" "0" "[]"
        exit 4
    fi
    # VALIDATE-DESIGN-EXTRACTION-REFUSAL END (xsu1 H2-F1)
    # (xsu1 H2R2-F4) the ONE call site whose fall-through exit is 0: a
    # construction failure here must not report success. Exit 2 matches the
    # pre-dispatch jq-missing literal's own code (infrastructure, not a
    # judgement about the artifact).
    emit_validate_design "true" "" "design contract valid: $n unit(s)" "$n" "$ids" "$art_tid" "$ufiles" "$udeps" || exit 2
    exit 0
}

# ---------------------------------------------------------------------------
# gate — independence + open-finding count over the record comments.
# ---------------------------------------------------------------------------

# emit_gate <exit-code> <ok> <error_key> <observations>  (reads the parsed
# globals: ART_*, REVIEWER, THRESHOLD, IMPL_JSON, OPEN_JSON, OPEN_COUNT,
# INDEPENDENT, CYCLE_OPENED_TS, LATEST_IMPLEMENTER_TS, ROUNDS, ROUNDS_HASH,
# ROUNDS_BASIS, ROUNDS_STALE_HASH_COUNT, ART_CAP_TERMINATED, ART_REVIEWER_PIN,
# ART_FILE_HASH).
# Prints the rich envelope, then exits with <exit-code>.
emit_gate() {
    local code="$1" ok="$2" ekey="$3" obs="$4"
    local artifact_json
    artifact_json=$(jq -nc \
        --arg it "${ART_ITER:-}" \
        --arg rev "${REVIEWER:-}" \
        --arg model "${ART_MODEL:-}" \
        --arg pin "${ART_REVIEWER_PIN:-}" \
        --arg hash "${ART_HASH:-}" \
        --arg thr "${THRESHOLD:-}" \
        --arg verdict "${ART_VERDICT:-}" \
        --arg stopped "${ART_STOPPED:-}" \
        --arg findings "${ART_FINDINGS:-}" \
        --argjson capterm "${ART_CAP_TERMINATED:-false}" \
        --arg filehash "${ART_FILE_HASH:-}" \
        '{iteration:$it, reviewer:$rev, model:$model, reviewer_pin:$pin, reviewed_hash:$hash, risk_threshold:$thr, verdict:$verdict, stopped_by:$stopped, findings_token:$findings, cap_terminated:$capterm, artifact_hash:$filehash}')
    # shellcheck disable=SC2016
    printf '{"ok":%s,"subcommand":"gate","artifact":%s,"reviewer_identity":%s,"implementers":%s,"cycle_opened_ts":%s,"latest_implementer_ts":%s,"independent":%s,"open_findings":%s,"open_finding_ids":%s,"rounds":%s,"rounds_hash":%s,"rounds_basis":%s,"rounds_stale_hash_count":%s,"error_key":%s,"observations":%s}\n' \
        "$ok" \
        "$artifact_json" \
        "$(printf '%s' "${REVIEWER:-}" | jq -Rs .)" \
        "${IMPL_JSON:-[]}" \
        "$(printf '%s' "${CYCLE_OPENED_TS:-}" | jq -Rs .)" \
        "$(printf '%s' "${LATEST_IMPLEMENTER_TS:-}" | jq -Rs .)" \
        "${INDEPENDENT:-true}" \
        "${OPEN_COUNT:-0}" \
        "${OPEN_JSON:-[]}" \
        "${ROUNDS:-0}" \
        "$(printf '%s' "${ROUNDS_HASH:-}" | jq -Rs .)" \
        "$(printf '%s' "${ROUNDS_BASIS:-hash_equality}" | jq -Rs .)" \
        "${ROUNDS_STALE_HASH_COUNT:-0}" \
        "$(printf '%s' "$ekey" | jq -Rs .)" \
        "$(printf '%s' "$obs" | jq -Rs .)"
    exit "$code"
}

# CYCLE / IMPLEMENTER TIMESTAMPS (claude-workflow-plugin-qzv)
#
# WHY THEY LIVE HERE. The Stop hook's F1 fast path needs to know whether an
# implementer is in flight before it may auto-approve a doc-only change set, and
# the two facts that answer it are records THIS function already reads: the
# `IMPLEMENTER: role=… task=… at <ts>` lines it derives the implementer set from,
# and the `QA-GATE: entered at <ts>` line that opens a review cycle. Parsing them
# in verify-before-stop.sh instead would be a SECOND parser for one grammar —
# the thing this script exists to prevent (see the header, and the way
# compute_change_set_hash defers to impact-report.sh --hash-only).
#
# THE TIMESTAMP IS THE LEXICOGRAPHIC MAX, not the last line in comment order. bd
# returns comments chronologically today, so the two coincide; keying on the
# record's OWN timestamp means the answer does not silently change if that
# ordering ever does.
#
# THREE DISTINCT ANSWERS, and the third one is the point. A caller must be able
# to tell "there is no such record" from "there is one and I could not read it",
# because those demand opposite decisions: the first is ordinary (doc-only work
# is orchestrator-authored and never gets an IMPLEMENTER record), the second
# means the predicate is unestablished and the caller must fail closed. So a
# record that exists but carries no well-formed timestamp prints the literal
# `unparseable` — a value no valid ISO-8601-UTC stamp can collide with — rather
# than the empty string.
QZV_ISO_UTC_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# max_record_ts <firstlines-file> <record-prefix-ERE>
max_record_ts() {
    local file="$1" prefix="$2" lines ts
    lines=$(grep -E "$prefix" "$file" 2>/dev/null) || lines=""
    if [ -z "$lines" ]; then
        printf ''
        return 0
    fi
    # Anchored at END OF LINE on purpose: both grammars put the timestamp last,
    # so a hex-or-date-looking token inside a free-text summary cannot be
    # mistaken for one. LC_ALL=C because the compare must be byte order; the
    # operands are fixed-shape, so the first differing character is always a
    # digit, and pinning the collation makes that independent of the host locale
    # rather than merely true on it.
    ts=$(printf '%s\n' "$lines" \
        | grep -oE " at $QZV_ISO_UTC_RE\$" 2>/dev/null \
        | sed -E 's/^ at //' \
        | LC_ALL=C sort \
        | tail -1)
    if [ -z "$ts" ]; then
        printf 'unparseable'
        return 0
    fi
    printf '%s' "$ts"
}

# bd_show_with_comments <task-id> — `bd show --json` that always carries
# comment BODIES, across the supported bd range.
#
# bd 1.1.2 stopped inlining comments in `bd show --json`: it returns a
# `comment_count` integer, and the bodies need the new --include-comments flag.
# bd 0.47.x has no such flag and exits 1 ("unknown flag: --include-comments"),
# but inlines .comments already. So try the new form, fall back to the plain
# one — pin the CHAIN, not the leg, exactly as add_comment() does for
# `bd comments add || bd comment add`. Callers keep the usual
# `(if type=="array" then .[0].comments else .comments end) // []` accessor,
# which reads both shapes correctly. Never fails the caller.
#
# Only readers of .comments need this. Calls that read .labels/.status/.notes/
# .dependencies must NOT use it: the flag's own help warns it "may be slow on
# issues with many comments", and those fields are unaffected by the change.
bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
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
    local want_hash=""
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
            --change-set-hash)
                # 2ty: the reference hash the ROUNDS count is taken against.
                # Optional — omitted, the count falls back to the latest
                # artifact's own reviewed_hash (see the ROUNDS block below).
                want_hash="${2:-}"
                if [ -z "$want_hash" ]; then
                    emit_validate "gate" "false" "usage" "--change-set-hash requires a hash"
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
        show=$(bd_show_with_comments "$tid" || echo "")
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
    ART_CAP_TERMINATED="false"; ART_REVIEWER_PIN=""; ART_FILE_HASH=""
    OPEN_JSON="[]"; OPEN_COUNT="0"; INDEPENDENT="true"
    CYCLE_OPENED_TS=""; LATEST_IMPLEMENTER_TS=""
    ROUNDS="0"; ROUNDS_HASH=""; ROUNDS_BASIS="hash_equality"; ROUNDS_STALE_HASH_COUNT="0"

    # qzv: resolved BEFORE the artifact gate below, deliberately. The F1 fast
    # path's only caller state is a task with NO review artifact — F1 fires on
    # doc-only change sets, which have nothing to review — so these two fields
    # have to be on the `review_artifact_missing` envelope or they would never
    # reach the caller that needs them. That is why they are not computed
    # alongside `implementers`, which still resolves after the gate and therefore
    # still reports `[]` on that envelope; the asymmetry is named rather than
    # tidied because widening the artifact-missing envelope further is a change
    # to a release predicate's inputs, not a cleanup.
    CYCLE_OPENED_TS=$(max_record_ts "$firstlines" '^QA-GATE: entered at ')
    LATEST_IMPLEMENTER_TS=$(max_record_ts "$firstlines" '^IMPLEMENTER: role=[a-z]+ ')

    # art = LAST comment matching /^REVIEW-ARTIFACT v1 /.
    local art
    art=$(grep -E '^REVIEW-ARTIFACT v1 ' "$firstlines" | tail -1 || true)

    # ROUNDS (claude-workflow-plugin-2ty) --------------------------------------
    #
    # COUNTED BEFORE the artifact-missing refusal below, deliberately: zero
    # artifacts is precisely the state the caller needs a number for ("has any
    # reviewer spoken about THIS change set yet?"), and an envelope that omits
    # the field there would force the caller to infer it from an error_key.
    #
    # IT ANCHORS ON THE FIRSTLINE GRAMMAR, AND THAT IS THE WHOLE POINT. A bare
    # substring count is wrong in the most misleading possible direction: on
    # claude-workflow-plugin-8zi, BEFORE any artifact existed,
    # `bd show 8zi | grep -c REVIEW-ARTIFACT` returned 1 — and the hit was PROSE
    # inside a reviewer's own note, the sentence "zero REVIEW-ARTIFACT
    # firstlines". Agents quote record grammars in comments constantly, so prose
    # mentions are the NORMAL case on any task with review history, not an edge
    # case. A count that includes them reports rounds a reviewer never ran, which
    # would make the escalation cap it feeds fire on discussion of reviews rather
    # than reviews. The regression leg lives in review-count.test.sh
    # ("prose-only mention"): a comment set whose ONLY mention is prose must
    # measure 0.
    #
    # THE ANCHOR IS DELIBERATELY ONE NOTCH LOOSER THAN THE `art` SELECTOR ABOVE
    # (`^[[:space:]]*` vs `^`), which is an asymmetry rather than an oversight.
    # `art` decides WHICH record the release predicate reads, and widening that
    # is a change to a release input nothing here asked for. The count only ever
    # decides whether an escalation may fire, and there the safe direction is to
    # COUNT an ambiguous record: a leading-whitespace record then reads as "a
    # reviewer has spoken", which leaves today's escalation behaviour intact,
    # whereas ignoring it could SUPPRESS an escalation on the strength of a
    # record that exists. Never fail toward suppression on ambiguity.
    #
    # The reference hash: `--change-set-hash` when the caller named one, else the
    # latest artifact's own reviewed_hash. `match()` takes the FIRST token on the
    # line, mirroring the `grep -oE ... | head -1` semantics every other token
    # read here uses, so a summary that mentions a second `reviewed_hash=` cannot
    # move the comparison. An empty reference counts 0: the awk guard requires a
    # non-empty token, so "no hash to compare" can never be read as "everything
    # matches".
    ROUNDS_HASH="$want_hash"
    if [ -z "$ROUNDS_HASH" ] && [ -n "$art" ]; then
        ROUNDS_HASH=$(printf '%s' "$art" | grep -oE 'reviewed_hash=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    fi

    # CYCLE-SURVIVAL BEGIN (claude-workflow-plugin-0in1)
    #
    # A round whose OWN reviewed_hash differs from the reference can still
    # count — but only on POSITIVE evidence that nothing besides the gate's own
    # housekeeping (reconcile_tracker) could explain the difference. That
    # evidence is: a review cycle is open (CYCLE_OPENED_TS established), the
    # round's own record timestamp falls inside it, and no `IMPLEMENTER: role=`
    # record is newer than the round. reconcile_tracker posts no bd comment of
    # its own and is the only other writer of the tracker that feeds
    # change_set_hash (see qa-gate.sh's cmd_reconcile_tracker header), so "no
    # implementer has been active since this round" leaves reconcile as the only
    # thing that could have moved the hash.
    #
    # THIS IS DELIBERATELY NARROWER than "count everything in the open cycle".
    # claude-workflow-plugin-2ty made rounds reset when a change set moves for
    # GENUINE new work ("a new change set has needed no rounds yet"), and
    # escalation-basis.sh legs C and H are the tested proof that property must
    # survive — reconcile-only growth and genuine-new-work growth move
    # change_set_hash identically (it hashes the path LIST, not contents), so
    # only a per-round, evidence-gated exception can tell them apart without
    # reopening either of those legs. Missing evidence (an unestablished cycle,
    # an unparseable round timestamp) never manufactures the exception — only
    # equality counts then, i.e. today's shipped behaviour, unchanged. That
    # mirrors 6.7's convention below (an unattributable record is not a match
    # for everything) rather than the anchor-width convention above (count on
    # ambiguity): this exception is a POSITIVE claim and needs evidence, not
    # its absence.
    CYCLE_ESTABLISHED="0"
    if [ -n "$CYCLE_OPENED_TS" ] && [ "$CYCLE_OPENED_TS" != "unparseable" ]; then
        CYCLE_ESTABLISHED="1"
    fi
    ROUNDS_BASIS="hash_equality"
    [ "$CYCLE_ESTABLISHED" = "1" ] && ROUNDS_BASIS="cycle"

    # An unparseable LATEST_IMPLEMENTER_TS means there IS an implementer record
    # but its timestamp could not be read — never treated as "an implementer
    # might be newer" (that would fail TOWARD suppression, the direction this
    # counter must never fail in); treated the same as no record at all.
    IMPL_TS_FOR_CMP="$LATEST_IMPLEMENTER_TS"
    [ "$IMPL_TS_FOR_CMP" = "unparseable" ] && IMPL_TS_FOR_CMP=""

    ROUNDS_PAIR=$(LC_ALL=C awk -v ref="$ROUNDS_HASH" -v cycok="$CYCLE_ESTABLISHED" \
        -v cyc="$CYCLE_OPENED_TS" -v implts="$IMPL_TS_FOR_CMP" '
        BEGIN { n = 0; stale = 0 }
        ref == "" { next }
        /^[[:space:]]*REVIEW-ARTIFACT v1 / {
            h = ""
            if (match($0, /reviewed_hash=[A-Za-z0-9._-]+/)) {
                h = substr($0, RSTART + 14, RLENGTH - 14)
            }
            if (h == ref) { n++; next }
            if (cycok != "1") { next }
            if (h == "") { next }
            ownts = ""
            if (match($0, / at [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z:/)) {
                ownts = substr($0, RSTART + 4, RLENGTH - 5)
            }
            if (ownts == "") { next }
            if (ownts < cyc) { next }
            if (implts != "" && implts > ownts) { next }
            n++; stale++
        }
        END { print (n + 0), (stale + 0) }
    ' "$firstlines" 2>/dev/null) || ROUNDS_PAIR="0 0"
    ROUNDS=$(printf '%s' "$ROUNDS_PAIR" | awk '{print $1}' 2>/dev/null) || ROUNDS="0"
    ROUNDS_STALE_HASH_COUNT=$(printf '%s' "$ROUNDS_PAIR" | awk '{print $2}' 2>/dev/null) || ROUNDS_STALE_HASH_COUNT="0"
    case "$ROUNDS" in
        ''|*[!0-9]*) ROUNDS="0" ;;
    esac
    case "$ROUNDS_STALE_HASH_COUNT" in
        ''|*[!0-9]*) ROUNDS_STALE_HASH_COUNT="0" ;;
    esac
    # CYCLE-SURVIVAL END (claude-workflow-plugin-0in1)
    # ROUNDS end ---------------------------------------------------------------

    if [ -z "$art" ]; then
        emit_gate 4 "false" "review_artifact_missing" "no REVIEW-ARTIFACT v1 comment found for $tid"
    fi

    REVIEWER=$(printf '%s' "$art" | grep -oE 'reviewer=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    THRESHOLD=$(printf '%s' "$art" | grep -oE 'risk_threshold=[A-Za-z0-9_]+' | head -1 | cut -d= -f2- || true)
    ART_ITER=$(printf '%s' "$art" | grep -oE 'iteration=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    # bjx: widened to include brackets (claude-workflow-plugin-46w9) — a real
    # observed runtime id, `claude-opus-5[1m]`, was truncated at the `[` by
    # the pre-46w9 class and silently lost its bracket suffix on read-back.
    # `]` must be the character immediately after the opening `[` and `-` must
    # be last: POSIX ERE does not treat `\[`/`\]` as escapes INSIDE a bracket
    # expression (measured directly while building this check).
    ART_MODEL=$(printf '%s' "$art" | grep -oE 'model=[]A-Za-z0-9._:/[-]+' | head -1 | cut -d= -f2- || true)
    # "pin=" mirrors the SAME abbreviation "model=" already uses for the JSON
    # field reviewer_model — the JSON payload key stays reviewer_pin (matching
    # validate-artifact's schema), the comment TOKEN is short, consistent with
    # this grammar's existing convention, and unambiguous (no other token name
    # in this grammar contains "pin" as a substring).
    ART_REVIEWER_PIN=$(printf '%s' "$art" | grep -oE 'pin=[]A-Za-z0-9._:/[-]+' | head -1 | cut -d= -f2- || true)
    ART_HASH=$(printf '%s' "$art" | grep -oE 'reviewed_hash=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    # artifact_hash= (v5 D2 / claude-workflow-plugin-rqer): the byte digest of
    # the canonical artifact FILE (docs/reviews/<tid>-r<n>.json), as opposed
    # to ART_HASH above, which is reviewed_hash — the CHANGE-SET hash the
    # reviewer read. The two must never be conflated: one names bytes on
    # disk today, the other names a claim about the past. Absent on any
    # record written before this field existed — an empty string, read by
    # cmd_approve's REVIEW-ARTIFACT-BINDING-TOKEN ladder as "no binding".
    ART_FILE_HASH=$(printf '%s' "$art" | grep -oE 'artifact_hash=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    ART_VERDICT=$(printf '%s' "$art" | grep -oE 'verdict=[A-Za-z]+' | head -1 | cut -d= -f2- || true)
    ART_STOPPED=$(printf '%s' "$art" | grep -oE 'stopped_by=[A-Za-z0-9_:]+' | head -1 | cut -d= -f2- || true)
    ART_FINDINGS=$(printf '%s' "$art" | sed -nE 's/.*findings=\[([^]]*)\].*/\1/p' || true)

    # ARTIFACT-COMPLETENESS (claude-workflow-plugin-nq5f). A review that stopped
    # at a CAP (max_findings / max_review_iterations / timeout) ran out of TURNS
    # or BUDGET, not out of things to find — it is incomplete by construction and
    # its verdict is a FLOOR, not a ceiling (qa-claude treated a cap-terminated
    # Sol round exactly this way BY HAND during D1 and immediately found a
    # sibling defect one screen from Sol's own finding). `verdict` and
    # `stop_condition` are the only two ways a review concludes on its own terms;
    # every `cap:*` value is the other case. Exposed as a boolean so a caller
    # never has to re-derive that split itself — see qa.md 6-prime's
    # "cap-terminated" guidance for the one CURRENT consumer, and this is the
    # primitive a future design-satisfied gate (D2) would consult rather than
    # re-parsing `stopped_by`'s enum a second time.
    ART_CAP_TERMINATED="false"
    case "$ART_STOPPED" in
        cap:*) ART_CAP_TERMINATED="true" ;;
    esac

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
    validate-completion) cmd_validate_completion "$@" ;;
    validate-design)   cmd_validate_design "$@" ;;
    gate)              cmd_gate "$@" ;;
    ""|-h|--help)
        cat >&2 <<'USAGE'
Usage: review-check.sh <subcommand> [args]
  validate-request  <file>                    schema-check a review request
  validate-artifact <file>                    schema-check a review artifact
  validate-completion <file>                  schema-check an F7 completion
                                              payload: the canonical seven keys
                                              (task_id, files_changed,
                                              tests_added, decisions, blockers,
                                              llm_observations,
                                              context_coverage) plus `role`;
                                              control chars rejected in the two
                                              scalars the record grammar embeds
                                              (task_id, role); the four array
                                              fields must be arrays and
                                              files_changed[] strings;
                                              llm_observations and
                                              context_coverage must be non-empty
                                              after trimming
  validate-design <file>                      schema-check a v5 design artifact:
                                              the eight required '## ' prose
                                              sections; EXACTLY ONE
                                              <!-- DESIGN-UNITS BEGIN/END -->
                                              pair, each alone on its line; the
                                              block is bare JSON or exactly one
                                              fence pair; contract_version "1",
                                              task_id, designer_identity, and a
                                              non-empty units[] where every unit
                                              declares unit_id (unique),
                                              goal, verification, a NON-EMPTY
                                              files[], acceptance[] of
                                              {id, text}, an array depends_on
                                              naming only declared unit_ids, and
                                              escalation_reason whenever
                                              implementer_class is high; the
                                              dependency graph must be acyclic.
                                              Reports units / unit_ids /
                                              task_id / unit_files (files[]
                                              keyed by unit_id) / unit_deps
                                              (depends_on[] keyed by unit_id)
                                              on the envelope. Never reads an
                                              unparseable block as zero units
  gate <task-id> [--comments-json <file>] [--change-set-hash <h>]
                                              independence + open-finding count,
                                              plus rounds/rounds_hash: how many
                                              REVIEW-ARTIFACT firstlines carry
                                              reviewed_hash=<h> (default <h> is
                                              the latest artifact's own hash),
                                              PLUS a round recorded inside the
                                              currently open cycle whose hash
                                              differs from <h> but no
                                              IMPLEMENTER record is newer than
                                              it (0in1 — reconcile_tracker's own
                                              housekeeping must not zero a real
                                              review). rounds_basis names which
                                              rule produced the number ("cycle"
                                              or "hash_equality");
                                              rounds_stale_hash_count is how many
                                              counted rounds needed the
                                              exception rather than an exact
                                              hash match
Exit: 0 ok | 4 violation | 2 bd-unavailable | 1 usage.
USAGE
        exit 1
        ;;
    *)
        printf 'review-check.sh: unknown subcommand: %s\n' "$SUB" >&2
        exit 1
        ;;
esac

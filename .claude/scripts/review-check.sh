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
#   design-unit-json  <file> <unit-id>          ONE declared unit's own
#                                               canonical JSON (v5 D5 R2-F3
#                                               remediation round 2,
#                                               claude-workflow-plugin-i8cx):
#                                               calls validate-design first
#                                               and refuses unless it
#                                               answers ok:true with the
#                                               unit declared, then projects
#                                               the unit's body off THAT
#                                               call's own unit_content map
#                                               — never a second read of
#                                               <file> (i8cx R4-F1)
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
    # every OTHER subcommand still gets unchanged. unit_content (v5 D5
    # R4-F1 remediation, independent review round 4) joined the reserved-{}
    # set the same way unit_files did here: this literal predates and
    # bypasses emit_validate_design, so a field added there must be added
    # here too or "every error path defaults to {}" stops being true again.
    if [ "${1:-}" = "validate-design" ]; then
        printf '{"ok":false,"subcommand":"%s","error_key":"jq_missing","observations":"jq is required and not on PATH","units":0,"unit_ids":[],"task_id":"","unit_files":{},"unit_deps":{},"unit_content":{}}\n' "${1:-}"
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

    # ITERATIONS TYPE + INTEGER GUARD (claude-workflow-plugin-k6re, R11-F1).
    #
    # THE DEFECT THIS CLOSES: the has() loop above only checked that
    # `iterations` was PRESENT, never that it was a usable value. The
    # legitimate writer (qa-gate.sh cmd_review_record) reads it back with
    # `jq -r '.iterations'` and interpolates the result VERBATIM into the
    # REVIEW-ARTIFACT record's machine prefix as `iteration=$iter` --
    # `iteration=1.5`, `iteration=oops`, or (worse) a MULTI-LINE compact
    # rendering of an array/object value, which is what `jq -r` produces for
    # any non-scalar (verified empirically: `jq -r` on `[1,2]` prints one
    # element per line, which would split the one-line record grammar the
    # same way an embedded control character does elsewhere in this file).
    # That record then reaches the REVIEW-ARTIFACT selector below
    # (ART-ITERATION-SELECT), whose own comment documents the consequence:
    # an unparseable `iteration=` token makes the selector refuse the WHOLE
    # candidate set, and because bd comments are append-only, no later,
    # well-formed record could ever clear that refusal -- a PERMANENT
    # deadlock for whichever task carried the bad record, discovered at
    # review round 11 of claude-workflow-plugin-i8cx.
    #
    # SAME TWO-STEP SHAPE as the RUBRIC record's `iteration` field
    # (qa-gate.sh cmd_grade_record, claude-workflow-plugin-R2-F3): type ==
    # "number" first (rejects strings, booleans, null, arrays and objects
    # under one specific, branchable key -- `iterations_not_number` --
    # rather than lumping them in with a bad digit shape), then the
    # NUMBER'S OWN string form must match ^[0-9]+$ (rejects decimals like
    # 1.5, negatives like -3, and non-normalised exponent forms -- this jq
    # version renders the JSON literal `1e3` back out as the literal string
    # "1E+3", not "1000"; verified directly rather than assumed, since the
    # whole point is that the writer must not be able to mint a value its
    # own reader cannot read back). Deliberately a DIFFERENT error-key
    # spelling (`iterations_` plural) than the RUBRIC check's (`iteration_`
    # singular): these are two distinct record grammars belonging to two
    # different writers, and a caller branching on error_key must not
    # conflate them.
    #
    # WHY THE MESSAGE IS SAFE TO INTERPOLATE VERBATIM (the same structural-
    # purity discipline named above for the external review lane, and the
    # same reasoning safe_summary() below documents for
    # iteration=/reviewed_hash=/at=): $it_type is always one of jq's six
    # fixed type-name strings, never influenced by the value's own content,
    # and $it_val is only ever printed once $it_type=="number" is already
    # established -- a JSON number's lexical grammar is limited to digits,
    # '.', '-', 'e'/'E' and '+', which cannot spell the token that guard
    # forbids regardless of what the reviewer supplied.
    #
    # THIS IS THE ONE VALIDATOR for the REVIEW-ARTIFACT schema (see
    # cmd_review_record's own comment: "Validate via the ONE validator
    # (subprocess). No second schema here."). The check lives HERE and
    # ONLY here, never duplicated in qa-gate.sh, for the same reason
    # completion-record's schema lives in validate-completion and nowhere
    # else -- one schema, one place to change it.
    local it_type it_val
    it_type=$(printf '%s' "$raw" | jq -r '.iterations | type' 2>/dev/null || echo "unknown")
    it_val=$(printf '%s' "$raw" | jq -r '.iterations' 2>/dev/null || echo "?")
    # ITERATIONS-GUARD-START (load-bearing; review-check.test.sh Section 2c strips to END)
    if [ "$it_type" != "number" ]; then
        emit_validate "validate-artifact" "false" "iterations_not_number" \
            "iterations is type=$it_type, expected number"
        exit 4
    fi
    case "$it_val" in
        ''|*[!0-9]*)
            emit_validate "validate-artifact" "false" "iterations_not_integer" \
                "iterations=$it_val is not a non-negative integer; it is read back verbatim by qa-gate.sh cmd_review_record and interpolated into the REVIEW-ARTIFACT record's machine prefix as iteration=\$iter, which the selector in this file parses as [0-9]+ immediately after 'iteration=' -- a value like 1.5 or 1e3 writes a record the selector can never parse, and because that selector refuses the ENTIRE candidate set on any one unparseable iteration, such a record permanently deadlocks review-record for this task (claude-workflow-plugin-k6re R11-F1)"
            exit 4
            ;;
    esac

    # ITERATIONS SAFE-MAGNITUDE GUARD (claude-workflow-plugin-k6re, R1-F1).
    #
    # THE DEFECT THIS CLOSES: everything above this point confirms $it_val is
    # type=number and matches ^[0-9]+$ -- SHAPE only, never MAGNITUDE. The
    # selector below (ART-ITER-CMP) is now exact for ANY non-negative-integer
    # digit string, however long, so this guard is not the thing standing
    # between a huge iterations value and a wrong selection -- but a value
    # this large can never describe a real review round, and once written it
    # is permanent (bd comments are append-only, same as every other record
    # this file guards at write time). Rejecting it here catches the same
    # class of upstream bug ITERATIONS-GUARD above already catches for shape:
    # something computed a nonsense value, and the record should never be
    # written at all rather than merely tolerated downstream. This guard is
    # NOT a substitute for the selector fix -- a malformed or oversized value
    # can still reach $firstlines via `bd import` or a hand-typed comment,
    # bypassing this function entirely (the exact bypass claude-workflow-
    # plugin-k6re R12-F1 already established as real and load-bearing for
    # this file's threat model) -- it is a defence-in-depth addition on the
    # one path this function DOES see.
    #
    # THE BOUND: 9007199254740991 = 2^53-1 = Number.MAX_SAFE_INTEGER. Not an
    # arbitrary "no real review has this many rounds" guess: it is the
    # largest integer for which N and N+1 are both exactly representable AND
    # distinguishable as an IEEE-754 double -- the representation JSON
    # numbers are conventionally read into (JavaScript, many JSON libraries,
    # and -- the actual R1-F1 defect -- awk's own `+0` numeric coercion,
    # MEASURED on this host: `awk 'BEGIN{a="9007199254740992"+0;
    # b="9007199254740993"+0; print (a==b)}'` prints 1). Measured directly,
    # not assumed: THIS host's jq (1.8.1) round-trips `.iterations` several
    # digits past this bound exactly (9007199254740993 prints back
    # 9007199254740993, not 9007199254740992) -- so this jq does not need the
    # guard for its own sake. The guard exists for every OTHER consumer of
    # this JSON that is not this exact jq version, and to catch an
    # almost-certainly-buggy value before it becomes an unfixable append-only
    # record, mirroring ITERATIONS-GUARD's own reasoning one level up.
    #
    # NEVER COMPARED AS A NUMBER for the general case (bash arithmetic is a
    # fixed-width 64-bit integer and would only push the identical failure
    # mode a few more digits out, not remove it, on a sufficiently long
    # adversarial digit string) -- pure string LENGTH compare first, leading
    # zeros stripped so a padded value ("0009007199254740991") is not
    # rejected for a cosmetic reason. A numeric `-gt` is used only in the
    # one branch where both operands are already known to share the SAME
    # length as the bound literal above (16 digits, fixed at this file's own
    # source, always far inside 64-bit range) -- never on $it_val's own
    # unbounded length. Same normalisation technique, independently applied
    # in awk, as the selector's own norm_iter()/iter_cmp() below.
    local it_norm it_safe_max="9007199254740991"
    it_norm=$(printf '%s' "$it_val" | sed 's/^0*//')
    [ -z "$it_norm" ] && it_norm="0"
    local it_exceeds=0
    if [ "${#it_norm}" -gt "${#it_safe_max}" ]; then
        it_exceeds=1
    elif [ "${#it_norm}" -eq "${#it_safe_max}" ] && [ "$it_norm" -gt "$it_safe_max" ]; then
        it_exceeds=1
    fi
    if [ "$it_exceeds" -eq 1 ]; then
        emit_validate "validate-artifact" "false" "iterations_exceeds_safe_bound" \
            "iterations=$it_val exceeds $it_safe_max (2^53-1, the largest integer safely representable as an IEEE-754 double / JSON number); a review round count this large cannot be genuine and is almost certainly a bug upstream of this record -- rejecting before it becomes a permanent, unfixable append-only record (claude-workflow-plugin-k6re R1-F1)"
        exit 4
    fi
    # ITERATIONS-GUARD-END

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

# emit_validate_design <ok> <error_key> <observations> <unit-count> <unit-ids-json> [task-id] [unit-files-json] [unit-deps-json] [unit-content-json]
# emit_validate's four keys plus the SIX a caller needs in order to write a
# record or compute a per-unit conformance/batching check without
# re-parsing the block: how many units were declared, which, the task the
# artifact says it designs, each unit's OWN declared `files` array (v5 D4,
# claude-workflow-plugin-fkm.6), (v5 D4b, claude-workflow-plugin-fkm.6,
# plan-batches) each unit's OWN declared `depends_on` array, and (v5 D5
# R4-F1 remediation, independent review round 4) each unit's OWN FULL
# canonical (compact, keys sorted) JSON body as a STRING, ALL THREE keyed by
# unit_id — `{"U1":["a.sh"],"U2":[...]}` / `{"U1":[],"U2":["U1"]}` /
# `{"U1":"{\"unit_id\":\"U1\",...}"}` — `{}` on every error path (the 14
# error call sites below all omit the 7th/8th/9th argument and get the
# default). `task_id` was already on the envelope DELIBERATELY — qa-gate.sh's
# design-record needs it for its decoy check — for the reason `unit_files`
# joined it for and `unit_deps` joins it for too: extracting any of these
# there with a second awk/jq pass would be a SECOND parser for one grammar,
# which is the thing this script exists to prevent (see the header, and the
# way compute_change_set_hash defers to impact-report.sh --hash-only).
# qa-gate.sh design-conform is `unit_files`'s consumer: it needs one
# resolved unit's declared file set to compute undeclared/unbuilt.
# epic-gate.sh plan-batches is `unit_deps`'s consumer: dependency order
# (docs/plans/v5-design-phase.md:158, ":159" tests) cannot be computed from
# `depends_on` without ALSO reparsing the block, so it gets the same
# treatment. `unit_content`'s consumer is THIS FILE'S OWN design-unit-json
# subcommand (below): independent review round 4 found that subcommand
# re-deriving a unit's full body from a SECOND read of the artifact — after
# already calling this validator once — did not preserve the single-parser
# guarantee, and named the concrete cost: a file swapped in the gap between
# the validator's read and the second one lets an authentic task_id ride
# out combined with content nobody validated. `unit_content` closes that gap
# structurally rather than narrowing its timing: design-unit-json now reads
# ONLY this envelope, never the file a second time, so there is no second
# read left to race. ALL THREE projection fields are read from the SAME
# validated `$block` `cmd_validate_design` already holds at the one point it
# is known schema-valid — never a re-read of the artifact from disk.
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
    local ok="$1" ekey="$2" obs="$3" n="$4" ids="$5" tid="${6:-}" ufiles="${7:-}" udeps="${8:-}" ubodies="${9:-}"
    [ -n "$ufiles" ] || ufiles="{}"
    [ -n "$udeps" ] || udeps="{}"
    [ -n "$ubodies" ] || ubodies="{}"
    local envelope="" env_rc=0
    envelope=$(jq -nc \
        --argjson ok "$ok" --arg ekey "$ekey" --arg obs "$obs" \
        --argjson n "$n" --argjson ids "$ids" --arg tid "$tid" \
        --argjson ufiles "$ufiles" --argjson udeps "$udeps" --argjson ubodies "$ubodies" '
        # validate-design envelope construction (xsu1 H2R2-F4)
        {ok: $ok, subcommand: "validate-design", error_key: $ekey,
         observations: $obs, units: $n, unit_ids: $ids, task_id: $tid,
         unit_files: $ufiles, unit_deps: $udeps, unit_content: $ubodies}
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
        and (keys | sort) == ["error_key", "observations", "ok", "subcommand", "task_id", "unit_content", "unit_deps", "unit_files", "unit_ids", "units"]
        and (.ok | type) == "boolean"
        and .subcommand == "validate-design"
        and (.error_key | type) == "string"
        and (.observations | type) == "string"
        and (.units | type) == "number"
        and (.unit_ids | type) == "array"
        and (.task_id | type) == "string"
        and (.unit_files | type) == "object"
        and (.unit_deps | type) == "object"
        and (.unit_content | type) == "object"
    '
# VALIDATE-DESIGN-ENVELOPE-SHAPE-GATE END (xsu1 R7-F5)
    if [ "$env_rc" -eq 0 ] && [ -n "$envelope" ] \
       && printf '%s' "$envelope" | jq -e "$shape_prog" >/dev/null 2>&1; then
        printf '%s\n' "$envelope"
        return 0
    fi
    printf '{"ok":false,"subcommand":"validate-design","error_key":"envelope_construction_failed","observations":"the validate-design envelope could not be constructed (jq failed, or produced unparseable or wrong-shaped output); refusing to print it under a success status. No caller-supplied data is included in this message","units":0,"unit_ids":[],"task_id":"","unit_files":{},"unit_deps":{},"unit_content":{}}\n'
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
    # i8cx wave 2. `grep -nE ... | head -1 | cut -d: -f1` reports cut's rc
    # (always 0 on the empty stdin an upstream failure leaves behind), same
    # masking shape as the count above -- but by itself that would only be
    # cosmetically wrong here (see this fix's devops report for why the
    # count check above is classified benign: it still refuses either way).
    # What makes THIS site worse than cosmetic is what a masked failure hands
    # to the next line: `[ "$ln_end" -le "$ln_begin" ]` is a numeric test, and
    # bash's `[` treats an EMPTY operand as a syntax error ("integer
    # expression expected"), not as 0 -- so a masked read failure here does
    # not cleanly refuse, it prints a shell-level error to stderr and the
    # malformed comparison's own non-zero status happens to fall through
    # (unasserted) to the block-extraction below, which eventually refuses
    # via design_block_empty several lines down for the wrong stated reason.
    # Guarding on emptiness directly avoids the crash-shaped comparison and
    # names the real problem instead of a misleading one. rc is not checked
    # here (unlike max_record_ts/impl_lines above): by this point n_begin/
    # n_end are ALREADY known to be exactly 1 each, so a `grep -n` on the very
    # same pattern coming back with nothing is itself the anomaly worth
    # naming, whichever of grep or cut produced it.
    # SENTINEL-LINE-READ-GUARD BEGIN (i8cx wave 2)
    local ln_begin ln_end
    ln_begin=$(grep -nE "$DESIGN_UNITS_BEGIN_RE" "$file" 2>/dev/null | head -1 | cut -d: -f1)
    ln_end=$(grep -nE "$DESIGN_UNITS_END_RE" "$file" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$ln_begin" ] || [ -z "$ln_end" ]; then
        emit_validate_design "false" "design_units_sentinels_unreadable" \
            "could not establish the DESIGN-UNITS sentinel line numbers for $file even though the count above found exactly one of each — a read failure or a race between the two checks, not a genuine absence; refusing rather than comparing line numbers that might be empty" "0" "[]"
        exit 4
    fi
    # SENTINEL-LINE-READ-GUARD END (i8cx wave 2)
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
    local n="0" ids="[]" art_tid="" ufiles="{}" udeps="{}" ubodies="{}"
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
            unit_deps:  ([ $u[] | {key: .unit_id, value: (.depends_on // [])} ] | from_entries),
            unit_content: ([ $u[] | {key: .unit_id,
                value: (walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson)}
              ] | from_entries) }
        | if ( (.task_id | type) == "string"
               and (.unit_files | type) == "object"
               and (.unit_deps  | type) == "object"
               and (.unit_content | type) == "object"
               and ((.unit_files | keys | sort) == ($ids | sort))
               and ((.unit_deps  | keys | sort) == ($ids | sort))
               and ((.unit_content | keys | sort) == ($ids | sort))
               and ([ .unit_files[] | type ] | all(. == "array"))
               and ([ .unit_deps[]  | type ] | all(. == "array"))
               and ([ .unit_content[] | type ] | all(. == "string"))
               # (v5 D5 R4-F1) round-trip each unit_content string back to an
               # object naming ITS OWN map key — this is the ONE place the
               # walk/tojson serialisation above is checked, so a jq that
               # produced garbled text (not just a wrong TYPE) is caught here
               # rather than trusted because it merely typechecks as a string.
               and ([ .unit_content | to_entries[]
                      | (.value | fromjson) as $b
                      | ($b | type) == "object" and ($b.unit_id == .key) ]
                    | all(.))
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
        ubodies=$(printf '%s' "$extracted" | jq -c '.unit_content' 2>/dev/null) || ext_rc=$?
        # These splits re-read the ALREADY-VALIDATED single-pass output, so a
        # failure here means jq itself broke mid-run — refuse on that too,
        # and re-check the spliced shapes (a jq that exits 0 while printing
        # nothing would otherwise splice empty strings into the envelope,
        # which is malformed JSON emitted under ok:true).
        case "$n" in (''|*[!0-9]*) ext_rc=5 ;; esac
        case "$ids" in ('['*) : ;; (*) ext_rc=5 ;; esac
        case "$ufiles" in ('{'*) : ;; (*) ext_rc=5 ;; esac
        case "$udeps" in ('{'*) : ;; (*) ext_rc=5 ;; esac
        case "$ubodies" in ('{'*) : ;; (*) ext_rc=5 ;; esac
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
            "the final unit_ids/unit_files/unit_deps/unit_content extraction could not be computed from the validated block (jq exited $ext_rc, or produced an unexpected shape); refusing rather than reporting a design whose declarations were never actually read" "0" "[]"
        exit 4
    fi
    # VALIDATE-DESIGN-EXTRACTION-REFUSAL END (xsu1 H2-F1)
    # (xsu1 H2R2-F4) the ONE call site whose fall-through exit is 0: a
    # construction failure here must not report success. Exit 2 matches the
    # pre-dispatch jq-missing literal's own code (infrastructure, not a
    # judgement about the artifact).
    emit_validate_design "true" "" "design contract valid: $n unit(s)" "$n" "$ids" "$art_tid" "$ufiles" "$udeps" "$ubodies" || exit 2
    exit 0
}

# ---------------------------------------------------------------------------
# design-unit-json (v5 D5 R2-F3 remediation round 2, claude-workflow-plugin-
# i8cx independent review round 2; re-founded on validate-design's OWN
# envelope in independent review round 4 — see the R4-F1 note below)
# ---------------------------------------------------------------------------
#
# design-unit-json <file> <unit-id> -> the ONE declared unit's own canonical
# (compact, keys sorted — matching historical `jq -cS` output byte for byte,
# so incidental reformatting or key reordering elsewhere in the unit's own
# object never changes what a caller derives from it) JSON, returned as a
# STRING field (unit_json) rather than a nested value, so a caller that
# writes it straight to a file for hashing (qa-gate.sh design-conflict /
# compute_design_conflict_open, the consumer this was added for) gets back
# the EXACT bytes, never jq's own re-serialization of an already-serialized
# value. R2-F3's own finding: a WHOLE-ARTIFACT hash comparison let an
# amendment to an UNRELATED unit silently clear a DIFFERENT unit's open
# conflict — this exists so that predicate can key on ONE unit's own content
# instead.
#
# NOT A SECOND PARSER. This subcommand makes no independent judgement about
# whether the artifact is schema-valid, well-fenced, acyclic, or anything
# else validate-design above already decides — it calls the REAL validator
# FIRST (as a subprocess: cmd_validate_design exits directly on every path,
# the same CLI-dispatch convention every subcommand in this file follows, so
# it cannot be called in-process without ending THIS subcommand's own run
# too — re-invoking this same script from inside its own process is no less
# safe than qa-gate.sh's existing callers already doing exactly that from a
# different process) and refuses immediately, propagating that verdict,
# unless it answers ok:true AND the requested unit_id is among ITS OWN
# unit_ids — membership is judged using validate-design's authoritative
# list, never re-derived here.
#
# R4-F1 (independent review round 4, docs/reviews/claude-workflow-plugin-
# i8cx-r4.json): the previous shape here, once membership was confirmed,
# RE-READ $file — re-counting sentinels, re-locating the block, re-handling
# fences, and re-parsing/selecting the unit, reusing validate-design's own
# regex constants but never its parse. That second extraction did not
# preserve the single-parser guarantee: "reusing regex constants does not
# make those operations the validator's original parse" (the finding,
# quoted). The concrete cost was a TOCTOU with a well-formed success shape —
# swap $file for one with a lone sentinel pair and parseable JSON naming the
# SAME unit_id but missing required sections or unit schema fields, in the
# gap between validate-design's read (above) and the second one, and the
# rereader — checking neither schema nor task identity a second time —
# would emit ok:true with task_id from the ORIGINAL validated artifact and
# unit_json from the UNVALIDATED replacement: an authentic identity riding
# out combined with content nobody validated, which reads as MORE
# trustworthy than a plain parse failure, not less.
#
# THE FIX: validate-design's envelope (emit_validate_design, above) now
# carries unit_content — a map, unit_id -> that unit's own canonical JSON
# body as a string, computed in the SAME guarded single jq pass that already
# produces unit_files/unit_deps from the SAME in-memory, already-proven-
# valid $block. This subcommand no longer reads $file a second time at all:
# once validate-design (below) answers ok:true with the unit declared, the
# unit's own bytes are a straight projection out of THAT call's own result
# ($vout), never a fresh read of the path. There is no second parse left for
# a concurrent edit to land in between, because there is no second read.
#
# emit_design_unit_json <ok> <error_key> <observations> <task_id> <unit_id> <unit_json>
# Same guarded-build discipline as emit_validate_design: ONE jq -nc
# construction, shape-validated before printing, with a caller-data-free
# literal fallback on construction failure. unit_json is passed through
# UNCHANGED (already a compact, sorted-keys JSON string, or empty) — never
# re-parsed or re-serialized here.
emit_design_unit_json() {
    local ok="$1" ekey="$2" obs="$3" tid="${4:-}" uid="${5:-}" ujson="${6:-}"
    local envelope="" env_rc=0
    envelope=$(jq -nc \
        --argjson ok "$ok" --arg ekey "$ekey" --arg obs "$obs" \
        --arg tid "$tid" --arg uid "$uid" --arg ujson "$ujson" '
        {ok: $ok, subcommand: "design-unit-json", error_key: $ekey,
         observations: $obs, task_id: $tid, unit_id: $uid, unit_json: $ujson}
    ' 2>/dev/null) || env_rc=$?
    if [ "$env_rc" -eq 0 ] && [ -n "$envelope" ] \
       && printf '%s' "$envelope" | jq -e '
            type == "object"
            and (keys | sort) == ["error_key", "observations", "ok", "subcommand", "task_id", "unit_id", "unit_json"]
            and (.ok | type) == "boolean"
            and .subcommand == "design-unit-json"
            and (.error_key | type) == "string"
            and (.observations | type) == "string"
            and (.task_id | type) == "string"
            and (.unit_id | type) == "string"
            and (.unit_json | type) == "string"
          ' >/dev/null 2>&1; then
        printf '%s\n' "$envelope"
        return 0
    fi
    printf '{"ok":false,"subcommand":"design-unit-json","error_key":"envelope_construction_failed","observations":"the design-unit-json envelope could not be constructed (jq failed, or produced unparseable or wrong-shaped output); refusing to print it under a success status. No caller-supplied data is included in this message","task_id":"","unit_id":"","unit_json":""}\n'
    return 1
}

cmd_design_unit_json() {
    local file="${1:-}" unit_id="${2:-}"
    if [ -z "$file" ] || [ -z "$unit_id" ]; then
        emit_design_unit_json "false" "usage" "design-unit-json requires <file> <unit-id>" "" "${unit_id:-}" ""
        exit 1
    fi

    local self_dir="" self_script=""
    self_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || self_dir=""
    if [ -n "$self_dir" ]; then
        self_script="$self_dir/$(basename "${BASH_SOURCE[0]:-$0}")"
    else
        self_script="${BASH_SOURCE[0]:-$0}"
    fi

    local vout="" vout_rc=0
    vout=$(bash "$self_script" validate-design "$file" 2>/dev/null) || vout_rc=$?
    local v_ok="false"
    if [ "$vout_rc" -eq 0 ] && [ -n "$vout" ]; then
        v_ok=$(printf '%s' "$vout" | jq -r '(.ok == true) as $b | if $b then "true" else "false" end' 2>/dev/null) || v_ok="false"
    fi
    if [ "$v_ok" != "true" ]; then
        local v_ekey="" v_obs=""
        v_ekey=$(printf '%s' "$vout" | jq -r '.error_key // "unknown"' 2>/dev/null) || v_ekey="unknown"
        v_obs=$(printf '%s' "$vout" | jq -r '.observations // ""' 2>/dev/null) || v_obs=""
        emit_design_unit_json "false" "design_invalid" \
            "the design artifact at $file did not validate (validate-design error_key=$v_ekey: $v_obs); a unit's content cannot be extracted from an artifact that is not itself known-valid" \
            "" "$unit_id" ""
        exit 4
    fi

    local v_tid="" has_unit="false"
    v_tid=$(printf '%s' "$vout" | jq -r '.task_id // ""' 2>/dev/null) || v_tid=""
    has_unit=$(printf '%s' "$vout" | jq -r --arg u "$unit_id" '((.unit_ids // []) | index($u)) != null' 2>/dev/null) || has_unit="false"
    if [ "$has_unit" != "true" ]; then
        local known=""
        known=$(printf '%s' "$vout" | jq -r '(.unit_ids // []) | join(", ")' 2>/dev/null) || known=""
        emit_design_unit_json "false" "unit_not_in_design" \
            "unit_id=$unit_id is not among $file's declared unit_ids per the just-validated artifact. Declared unit(s): ${known:-<none>}" \
            "$v_tid" "$unit_id" ""
        exit 1
    fi

    # DESIGN-UNIT-JSON-AUTHORITATIVE-FETCH BEGIN (i8cx R4-F1)
    # THE FIX (independent review round 4): no read of $file happens below
    # this line. The unit's own canonical JSON comes straight out of
    # validate-design's OWN envelope ($vout, already in memory above) —
    # unit_content, a map keyed by unit_id, built inside the SAME single
    # guarded jq pass that already produces unit_files/unit_deps from the
    # SAME in-memory $block validate-design proved schema-valid. The file is
    # read exactly once — inside the validate-design call above — and every
    # field this subcommand emits, including the unit's full body, is a
    # projection of THAT ONE call's result. There is no second parse left
    # for a concurrent edit to land in between.
    local unit_json=""
    unit_json=$(printf '%s' "$vout" | jq -r --arg u "$unit_id" '.unit_content[$u] // empty' 2>/dev/null)
    if [ -z "$unit_json" ]; then
        # has_unit was true a moment ago, off unit_ids on this SAME $vout.
        # validate-design's own envelope-shape gate (VALIDATE-DESIGN-
        # ENVELOPE-SHAPE-GATE, above) already proves unit_content is keyed
        # by EXACTLY unit_ids, so has_unit true with an empty lookup here can
        # only be a jq malfunction reading an in-memory string, never a
        # genuine absence. "Unparseable is never zero" (validate-design's
        # own header, rule 3) applies to this projection too — refuse rather
        # than report a state the envelope's own shape gate should make
        # unreachable.
        emit_design_unit_json "false" "design_unit_content_missing" \
            "unit_id=$unit_id is declared per validate-design's unit_ids but carries no entry in the SAME envelope's unit_content map; refusing rather than guessing at a state the envelope's own shape gate should make unreachable" \
            "$v_tid" "$unit_id" ""
        exit 4
    fi
    # DESIGN-UNIT-JSON-AUTHORITATIVE-FETCH END (i8cx R4-F1)
    emit_design_unit_json "true" "" "unit $unit_id extracted" "$v_tid" "$unit_id" "$unit_json" || exit 2
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
    local file="$1" prefix="$2" lines lines_rc=0 ts
    # i8cx wave 2. `grep -E ... "$file" 2>/dev/null || lines=""` collapsed TWO
    # different outcomes into the same empty string: grep's own rc 1 ("no
    # record of this class exists" -- a clean no-match) and rc >1 ("the file
    # could not even be read" -- permission, ENOENT, a vanished temp dir).
    # This function's header, three paragraphs up, already states why that
    # distinction has to survive: "a caller must be able to tell 'there is no
    # such record' from 'there is one and I could not read it' ... a record
    # that exists but carries no well-formed timestamp prints the literal
    # 'unparseable' rather than the empty string" -- but the implementation
    # only delivered that promise for the "found records, bad timestamp" case,
    # never for "could not even look".
    #
    # THE CONSEQUENCE reaches further than this function's own callers. This
    # script's `gate` envelope publishes LATEST_IMPLEMENTER_TS verbatim (see
    # emit_gate), and verify-before-stop.sh's F1 fast path reads it back:
    # `if [ -z "$impl" ]; then F1_BINDING_VERDICT="safe" ...`. A masked read
    # failure here would have reported latest_implementer_ts="" -- exactly
    # the shape F1 treats as "no implementer in flight, safe to auto-approve
    # a doc-only change set" -- over a task whose implementer status could
    # not actually be established. Reusing the EXISTING 'unparseable' sentinel
    # (rather than inventing a new one) is deliberate: F1's own comparison
    # already treats "unparseable" as "unestablished, fail closed"
    # (`[ "$cycle" = "unparseable" ] || [ "$impl" = "unparseable" ]`), and so
    # does this function's OWN CYCLE_ESTABLISHED / IMPL_TS_FOR_CMP logic just
    # below -- so this fix needs no change anywhere else. A brand-new sentinel
    # value would reach that `oldest=$(printf ... | sort | head -1)` timestamp
    # comparison as an uninterpreted string with no defined ordering, which is
    # a worse, unproven failure mode this fix has no reason to introduce.
    #
    # Only rc 1 (a clean no-match) is safe to treat as "no evidence"; rc 0
    # falls through to the extraction below as before.
    # MAX-RECORD-TS-READ-GUARD BEGIN (i8cx wave 2)
    lines=$(grep -E "$prefix" "$file" 2>/dev/null)
    lines_rc=$?
    if [ "$lines_rc" -gt 1 ]; then
        printf 'unparseable'
        return 0
    fi
    if [ -z "$lines" ]; then
        printf ''
        return 0
    fi
    # MAX-RECORD-TS-READ-GUARD END (i8cx wave 2)
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

    # art = the REVIEW-ARTIFACT v1 record that is SIMULTANEOUSLY the highest
    # well-formed iteration= AND the latest well-formed timestamp, never the
    # last one in comment order (claude-workflow-plugin-k6re TIER-0 K3).
    #
    # THE DEFECT THIS REPLACES: `grep ... | tail -1` read "latest" as "last
    # in bd's comment order". bd is append-only, so ANY record added after
    # the fact -- hand-typed, or a backfill of an EARLIER round's history --
    # lands last in that order regardless of what iteration number it
    # carries. MEASURED: the same three comments, reordered, flipped the
    # gate between ok:false/open_findings:2 and ok:true/open_findings:0 --
    # order alone decided which record governed a release predicate.
    #
    # WHY NOT ITERATION ALONE (measured against the live store, not assumed):
    # a first draft of this fix selected by max(iteration) alone, tie-broken
    # by timestamp. claude-workflow-plugin-fkm.1.1's REAL review history
    # falsifies that design: one reviewer identity posted a single record at
    # iteration=2 with the OLDEST timestamp, while another posted FIVE MORE
    # records — against three DIFFERENT reviewed_hash values, spanning
    # nearly a full day, ending in a genuine `verdict=approve` — every one
    # of them still carrying iteration=1. The second identity's iteration
    # counter never incremented at all; it is not a per-cycle reset (two of
    # the five share one reviewed_hash and still both say 1), it is a
    # stagnant counter. Iteration number is NOT a reliable global-across-
    # writers recency signal — it can freeze while real, sequential review
    # rounds keep landing. A max(iteration)-only selector would have picked
    # the single record with the OLDEST timestamp over five newer ones, on a
    # hash that five later rounds had already superseded.
    #
    # WHY NOT TIMESTAMP ALONE either: the record's `at <ts>` field is
    # stamped at RECORD-WRITE time (qa-gate.sh review-record: `ts="$(date -u
    # ...)"`), not at review time. A backfill that (re)posts an historical
    # round through that same path would stamp it "now" — chronologically
    # LATEST by construction, however old the review it describes. Pure
    # recency is exactly as exploitable by a naive backfill as pure position
    # was.
    #
    # THE RULE: a record governs only if it is the SAME record under BOTH
    # orderings — the highest iteration AND (independently, across the
    # WHOLE candidate set, not just the iteration-tied group) the latest
    # timestamp. This is a strict superset of the plain "max iteration, tie
    # broken by timestamp" rule: when the global timestamp-max already sits
    # inside the iteration-max tied group (the ordinary case — see i8cx and
    # the reproduction below), it degenerates to exactly that. It only
    # DIFFERS when the two signals point at different records, and that
    # disagreement is precisely what fkm.1.1 exhibits and a naive backfill
    # can manufacture — in both cases neither signal is trustworthy enough
    # to overrule the other silently, so this refuses instead
    # (review_artifact_selection_disagreement), naming both the iteration-
    # winning and the timestamp-winning record so an operator has the actual
    # evidence, not just a bare "ambiguous". A backfill mechanism therefore
    # has to preserve each round's REAL historical timestamp (not "now") for
    # this selector to resolve automatically — a concrete, testable
    # constraint on claude-workflow-plugin-k6re's own remaining work, not
    # merely a comment.
    #
    # AN UNPARSEABLE iteration= OR timestamp (missing, non-digit for
    # iteration; missing or not ISO-8601-UTC for timestamp) must never rank
    # as 0 and lose silently -- the sibling shape this task was explicitly
    # told not to reproduce (sev_rank's `*) echo 0 ;;` a few screens up drops
    # an unrecognised severity below EVERY threshold, including info). It
    # must not silently WIN either. So it is never ranked: a malformed
    # candidate is EXCLUDED from the max-iteration/max-timestamp computation
    # entirely, the same as before (review_artifact_iteration_unparseable /
    # review_artifact_timestamp_unparseable name the specific class) -- the
    # same "refuse rather than silently coerce" convention MALFORMED-
    # ARTIFACT-GUARD and REVIEWER-NONEMPTY-GUARD below already use.
    #
    # THIS USED TO REFUSE THE WHOLE SELECTION UNCONDITIONALLY, with no way
    # back: bd comments are append-only, so a single malformed candidate
    # ANYWHERE in a task's history deadlocked review-record PERMANENTLY. Two
    # recovery mechanisms were tried after that, in order, and BOTH were
    # removed again:
    #
    #   claude-workflow-plugin-k6re R11-F1 (found at i8cx review round 11:
    #   validate-artifact accepted a non-integer `iterations` value, which
    #   the legitimate writer then recorded verbatim) excused a malformed
    #   candidate that sat STRICTLY BEFORE an unambiguous well-formed
    #   winner, reasoning that bd's append-only comment order means an
    #   earlier POSITION could never be a corrupted later round in
    #   disguise. R12-F1 falsified that premise against the actual bd 1.2.2
    #   source: `bd show --include-comments` orders by a content-supplied
    #   created_at, never true insertion order, and `bd import` (which this
    #   repository's own mandatory reconciliation runs unconditionally)
    #   preserves a supplied created_at verbatim even onto an
    #   already-existing issue -- position was never trustworthy, not
    #   merely in the one case that was measured.
    #
    #   R12-F1's replacement required an explicit, content-hash-addressed
    #   operator decision instead. Independent review round 2 of THIS SAME
    #   TASK (R2-F1) found that mechanism forgeable in turn -- see the
    #   tombstone comment below, where ART-QUARANTINE-HASH used to sit, for
    #   the full finding and why it was removed rather than patched again.
    #
    # THERE IS NO RECOVERY MECHANISM TODAY. A malformed candidate refuses
    # the whole selection, unconditionally and permanently, regardless of
    # where it sits or what is posted about it afterward. The concern this
    # paragraph describes therefore applies to EVERY malformed candidate
    # without exception -- "it can't have been the highest/latest" is only
    # ever established by comment position, never by the malformed record's
    # own unreadable content, and position is no longer consulted for
    # anything at all.
    #
    # A record that is simultaneously tied for BOTH the max iteration AND
    # the max timestamp with another record (both fields byte-identical
    # between them) has no further principled signal to resolve it with,
    # and refuses too (review_artifact_selection_tie_unresolved) rather than
    # falling back to position -- which is the exact defect this rewrite
    # exists to remove.
    #
    # ART-SELECT READ GUARD (i8cx discipline: every read of $firstlines gets
    # a guard distinguishing "could not read" from "read cleanly, nothing
    # there" -- see MAX-RECORD-TS-READ-GUARD and IMPLEMENTER-SET-READ-GUARD
    # elsewhere in this function). awk's OWN exit-code convention differs
    # from grep's: 0 means "ran successfully", covering BOTH "matched
    # records" and "matched none" -- unlike grep's 0/1/>1 three-way split. A
    # non-zero exit here can only mean awk could not even open/read
    # $firstlines (measured on this platform: rc=2 for both a missing file
    # and a permission failure), so ANY non-zero rc is treated as a hard
    # read failure, never as "no records".
    #
    # DIAGNOSTIC DETAIL IS A SAFE SUMMARY, NEVER THE RAW RECORD
    # (claude-workflow-plugin-icn4 correction 10): this script is one of
    # three scripts a structural purity guard keeps free of any reference to
    # the external review lane's own name -- and that guard scans not only
    # these files' own bytes but their CAPTURED RUNTIME OUTPUT, because a
    # source clean of the forbidden token can still print it at runtime. A
    # REVIEW-ARTIFACT record's reviewer= field is operator-supplied data,
    # and nothing stops a real one from naming that excluded lane's
    # identity (confirmed live on two tasks in this repo's own store).
    # Quoting a candidate record verbatim in an error message would echo
    # that identity straight into this gate's own JSON output the moment it
    # ever refused on real data carrying it -- reintroducing the exact
    # reference the guard exists to keep out, from the data path rather
    # than from static prose. safe_summary() below reports only
    # iteration=/reviewed_hash=/at= -- fields whose OWN character classes
    # ([0-9]+; hex; a fixed ISO-8601-UTC shape with no free-form letters at
    # all) make them structurally incapable of spelling the forbidden
    # token, not merely happening not to today.
    # ART-PARSE-SHARED (claude-workflow-plugin-k6re R3-F1, independent review
    # round 3). ONE anchored, end-to-end grammar for a REVIEW-ARTIFACT v1
    # firstline's machine-token region. $ART_SOFT_FIELDS_RE (below) is the
    # part actually SHARED by textual interpolation (`-v ART_SOFT=...`, awk
    # has no cross-invocation `source`) between the per-candidate awk
    # program right below and the post-selection re-verification further
    # down (see ART-PREFIX-GUARD) -- each site defines its own small
    # function(s) using that one fragment, kept byte-consistent by hand,
    # the same discipline qa-gate.sh's RUBRIC/QA-GATE-APPROVED capture
    # patterns already use for the WRITER reading its own records back
    # (that comment: "The parity is asserted textually... in
    # approve-idempotency.sh"), applied here within one file instead of
    # across two.
    #
    # THE DEFECT THIS CLOSES. The pre-R3-F1 findings=[...] guard was a bare
    # substring test (`$0 !~ /findings=\[[^]]*\]/`), matched ANYWHERE on the
    # line, while the extraction beside it (`sed -nE
    # 's/.*findings=\[([^]]*)\].*/\1/p'`) is GREEDY and prefers the LAST such
    # occurrence. Two independent reproductions, both measured directly:
    #
    #   1. A record whose bracket does not close where the grammar says it
    #      must (the literal R3-F1 finding, round 3) can swallow a REAL,
    #      later artifact_hash=/at <ts> pair as bracket "content" while
    #      simultaneously presenting a second, well-formed-looking
    #      `findings=[]` inside that swallowed text. The substring guard
    #      finds A match (the swallowing one) and passes; greedy sed then
    #      prefers the fake trailing one; ART_FINDINGS reads back empty.
    #      Nothing here needed the removed R2-F1 quarantine mechanism.
    #
    #   2. WORSE, and needing no malformation at all: a perfectly well-formed
    #      record whose free-text SUMMARY merely mentions the token --
    #      `... findings=[R3-F1:high] artifact_hash=ah at <ts>: fixed the bug
    #      where findings=[] was mis-parsed` -- suffers the identical
    #      suppression. Reachable non-adversarially by anyone describing this
    #      very defect in a review summary.
    #
    # THE FIX. Walk the grammar ONCE, left to right, ANCHORED at ^ every
    # time, so a token's position is never inferred from "found somewhere"
    # but always from "immediately follows the token before it". Once the
    # walk reaches the mandatory `at <ts>: ` that opens the free-text
    # summary, EVERYTHING from there on is summary, and nothing below this
    # point ever scans it again -- the anchor IS the fix, not a separate
    # step layered on top of it (see art_prefix_len() below, and
    # ART-PREFIX-GUARD, which is the ONE thing every extractor downstream now
    # reads from, in place of the raw winning line).
    #
    # THE SEVEN SOFT FIELDS (reviewer=/model=/pin=/reviewed_hash=/
    # risk_threshold=/verdict=/stopped_by=, between iteration= and
    # findings=[...]) are each INDEPENDENTLY optional -- the selector has
    # never required them for "well-formed" (only iteration=, findings=[...],
    # and the trailing `at <ts>:` are; REVIEWER-NONEMPTY-GUARD below
    # separately refuses an empty reviewer AFTER selection) -- and three real
    # grammar generations coexist in the live store: pin= (46w9) and
    # artifact_hash= (rqer) were each added AFTER earlier rounds were already
    # written. MEASURED against the live store: claude-workflow-plugin-
    # fkm.1.1's six real REVIEW-ARTIFACT records (review-count.test.sh
    # section 11.8, reproduced from `dolt sql`) carry NEITHER pin= NOR
    # artifact_hash=, and all six still parse under this grammar. None of
    # these fields' classes admit a space, so none can smuggle a later
    # field's keyword into an earlier position regardless of which are
    # present.
    #
    # THE ONE CONTENT-CLASS CHANGE: findings=[...] used to accept ANY
    # character except `]` inside the brackets (`[^]]*`). That is what let
    # reproduction 1 above swallow real, later tokens as bracket "content".
    # Every OTHER field in this grammar was already safe from that specific
    # confusion for a simpler reason: none of their classes ever admitted a
    # space to begin with. findings=[...] was the one exception, and a
    # legitimate finding list (`Rn-Fn:severity[,Rn-Fn:severity]*`) never
    # needed one either -- excluding whitespace (`[^][:space:]]*`, verified
    # directly against this host's awk: a literal `]` immediately after `[^`
    # is a literal member of the excluded set per POSIX, and a named class
    # may follow it in the same bracket expression) costs nothing real and
    # closes the swallowing class structurally: a bracket can no longer
    # extend across a field boundary, because every field boundary in this
    # grammar is a space.
    #
    # ITERATION IS CHECKED FIRST, not findings-first as the pre-R3-F1 code
    # documented. This is not an arbitrary reordering: art_findings_ok()
    # below can only locate findings=[...] by first walking PAST a
    # syntactically valid iteration= token (that is what "anchored" means --
    # you cannot validate what follows a token without knowing where the
    # token itself ends), so "findings checked independently of iteration"
    # and "iteration position never inferred from an unanchored scan" are the
    # same defect from two angles; the pre-R3-F1 precedence was only
    # achievable BECAUSE the findings check ignored position entirely. This
    # only changes behaviour for a record with MULTIPLE simultaneous defects
    # (no existing test pins that combination); every single-defect fixture
    # in review-count.test.sh classifies identically under either order.
    local ART_SOFT_FIELDS_RE
    ART_SOFT_FIELDS_RE='( reviewer=[A-Za-z0-9._-]+)?( model=[]A-Za-z0-9._:/[-]+)?( pin=[]A-Za-z0-9._:/[-]+)?( reviewed_hash=[A-Za-z0-9._-]+)?( risk_threshold=[A-Za-z0-9_]+)?( verdict=[A-Za-z]+)?( stopped_by=[A-Za-z0-9_:]+)?'

    # ART-FINDINGS-ITEM-GRAMMAR (claude-workflow-plugin-k6re, OPERATOR RULING).
    # FIFTH recurrence of the review-artifact-parse-boundary defect family:
    # (1) greedy sed preferring the last match; (2) a machine token sharing a
    # line with operator free text; (3) `=` inside findings content
    # impersonating a FIELD (R5-F1); (4) `[` inside findings content
    # impersonating the DELIMITER (R7-F1); (5) THIS ONE -- ERE metacharacters
    # and shell glob metacharacters inside findings content impersonating a
    # PATTERN, reaching three separate sinks fed by the SAME value below:
    #   (a) `IFS=','; for item in $ART_FINDINGS` is unquoted, and this file
    #       sets no `set -f` anywhere, so a value containing `*`/`?`/a bracket
    #       expression undergoes PATHNAME EXPANSION against whatever this
    #       process's CWD happens to hold. MEASURED: findings=[*:high] in a
    #       CWD containing a file named `a:b:high` rewrites $item to that
    #       filename; the resulting $fsev is not a recognised severity,
    #       sev_rank returns 0, and a real declared HIGH silently drops below
    #       threshold.
    #   (b) `grep -E "^RESOLVED ${fid} " "$firstlines"` (below) interpolates
    #       $fid -- sourced from splitting $ART_FINDINGS -- UNESCAPED into an
    #       ERE. MEASURED: findings=[.*:high] makes $fid literally `.*`,
    #       which matches ANY `RESOLVED <anything> fix=... test=...` record
    #       anywhere in the stream regardless of finding id, clearing a
    #       declared HIGH that nothing actually resolved.
    #   (c) `grep -E "^ARBITRATION ${fid} " "$firstlines"` (below): the
    #       identical injection, and worse -- needs only one
    #       decision=overrule record anywhere in the stream, with no
    #       fix=/test= corroboration required at all.
    #
    # THE FIX IS INGEST-SIDE, BY OPERATOR RULING, NOT THREE LOOP-LOCAL
    # ESCAPES. "Escape correctly at every sink" has failed five times running
    # -- each recurrence was a new way past the same shape of denylist. Every
    # content-class fix through R7-F1 EXCLUDED a growing set of characters
    # (`]`, then `[`, then whitespace) while PERMITTING everything else,
    # including every ERE metacharacter (`. * ^ $ + ? ( ) | \`) and every
    # glob metacharacter (`* ? [...]`) -- an allowlist was never tried. This
    # replaces the denylist with the exact ALLOWLIST validate-artifact
    # already enforces for the JSON schema above (cmd_validate_artifact):
    # finding id `R[0-9]+-F[0-9]+`, severity
    # `critical|high|medium|low|info` -- REUSED, not reinvented, because two
    # independently-maintained copies of the same grammar is how this file
    # accumulated five duplicated copies of the findings grammar in the
    # first place. A value in this class has no ERE metacharacter and no
    # glob metacharacter in its alphabet at all (`R F 0-9 - : ,` and the five
    # severity words), so sinks (a)/(b)/(c) receive nothing they can ever
    # misparse -- structurally, not because each was individually hardened
    # against inputs enumerated after the fact -- and a future sink fed by
    # this SAME value inherits the guarantee for free. A findings=[...] token
    # outside this grammar now fails art_findings_ok() exactly as a
    # structurally-broken bracket already did: review_artifact_malformed,
    # refused unconditionally (see ART-ITERATION-SELECT above for why there
    # is no recovery path), before the loop below or either grep ever runs.
    #
    # DERIVED FROM THE REAL CORPUS, not imposed from the grammar alone. Every
    # live REVIEW-ARTIFACT record read directly from bd already fits this
    # class byte-for-byte: all 6 on claude-workflow-plugin-fkm.1.1, all 7 on
    # claude-workflow-plugin-xsu1 (iterations 1-5, 7, 10), all 3 on
    # claude-workflow-plugin-i8cx (iterations 1, 9, 10 -- including
    # model=gpt-5.6-sol/pin=gpt-5.6-sol, a SEPARATE field from this one, its
    # own bracket-permitting class from claude-workflow-plugin-46w9 untouched
    # here), and the 1 on claude-workflow-plugin-6im2. Three on-disk
    # docs/reviews/*.json artifacts use a non-`R[0-9]+-F[0-9]+` id scheme
    # (H2-F*/H2R2-F*/S6-F*, from a "hunt"-phase sub-process with its own
    # numbering) and were checked against their corresponding LIVE bd comment
    # streams: absent. cmd_validate_artifact already refuses that id shape
    # for the JSON schema, so the legitimate writer (qa-gate.sh
    # review-record) never turned them into a REVIEW-ARTIFACT comment to
    # begin with (the gap is named on its own task: claude-workflow-plugin-
    # 36mk). This grammar therefore changes nothing for any record ever
    # written through the legitimate writer, and refuses a hand-typed or
    # bd-imported comment using that same non-conforming shape for the
    # identical reason validate-artifact already refuses it on write --
    # closing the gap between the two paths, not opening a new one.
    local ART_FINDINGS_LIST_RE
    ART_FINDINGS_LIST_RE='(R[0-9]+-F[0-9]+:(critical|high|medium|low|info)(,R[0-9]+-F[0-9]+:(critical|high|medium|low|info))*)?'

    local art ART_SELECT_ERR="" ART_SELECT_DETAIL=""
    # ART-ITERATION-SELECT BEGIN (claude-workflow-plugin-k6re)

    # ART-QUARANTINE-HASH -- REMOVED (claude-workflow-plugin-k6re, R2-F1).
    #
    # THIS USED TO BE HERE (R12-F1): a sha256 of every REVIEW-ARTIFACT
    # candidate's raw first line, computed in bash, never inside the awk
    # program below (a malformed candidate's raw text is untrusted content;
    # piping it through a shell command built by string-interpolating that
    # content -- what awk `system()`/`| getline` would require -- is the
    # shell-injection shape backend.md's OWASP guidance forbids for the
    # identical reason it forbids interpolating user input into SQL). An
    # `is_quarantined(pos)` awk function then consulted a set of hashes
    # read from any REVIEW-ARTIFACT-QUARANTINE v1 record in $firstlines
    # before a malformed candidate could ever set badfindings/baditer/badts.
    #
    # WHY IT IS GONE, NOT MERELY TIGHTENED. Independent review round 2 of
    # this same task (R2-F1) found the mechanism forgeable on its own first
    # independent review:
    #
    #   1. normalize_comments() (this file, above) reduces every comment to
    #      its TEXT string alone before anything downstream ever sees it --
    #      author and every other column is discarded, for every reader of
    #      this comment stream, not only this one. A "durable,
    #      actor-attributed operator decision" is unverifiable by
    #      construction from data shaped this way: there was never an
    #      author field left to check.
    #   2. The matcher accepted any comment whose FIRST LINE merely started
    #      with `REVIEW-ARTIFACT-QUARANTINE v1 hash=<64 hex>` -- it did not
    #      require the writer's own `at <ts>: <reason>` grammar, so anything
    #      sharing just that prefix matched regardless of what followed it.
    #   3. `qa-gate.sh quarantine-artifact` validated the hash shape and
    #      required a non-empty reason, but a hand-typed comment or a `bd
    #      import` reaches this file's read path directly and was never
    #      required to pass through that validation at all.
    #
    # Put together: the same unauthenticated write path that can post a
    # malformed REVIEW-ARTIFACT candidate in the first place could equally
    # post a record that excuses one -- a second guard built on an
    # unauthenticated channel is still an unauthenticated channel. Removing
    # it costs nothing beyond the residual below: the writer-side guards
    # that keep the LEGITIMATE writer from producing a malformed record to
    # begin with (R11-F1's `iterations` type+integer check; R1-F1's
    # magnitude bound, both still in force above validate-artifact and in
    # ART-ITER-CMP below) are unrelated to this mechanism and untouched by
    # this removal.
    #
    # THE RESIDUAL, STATED EXPLICITLY. A malformed REVIEW-ARTIFACT record
    # posted via `bd import` or a hand-typed `bd comments add` -- the same
    # two channels that already reach this selector without ever calling
    # validate-artifact -- now deadlocks this task's gate PERMANENTLY, with
    # no recovery through review-check.sh or qa-gate.sh. This is deliberate,
    # not an oversight: the actor able to plant such a record is, by
    # construction, also able to write any OTHER record directly (including
    # a forged quarantine, which is exactly what this removal closes), so a
    # forgeable escape hatch bought no real defence -- only a second thing
    # to forge. The remedy is an operator repairing the affected comment
    # directly in the store, outside this script.
    #
    # DO NOT RE-ADD A QUARANTINE, ALLOWLIST, OR SIMILAR OVERRIDE HERE. Any
    # future in-band recovery must solve authentication FIRST (an
    # attributable, verifiable signer this file's own read path can check)
    # -- solving only "which record" (R12-F1's content hash) without
    # solving "who says so" reproduces this exact finding.

    local art_out art_rc=0
    art_out=$(LC_ALL=C awk -v ART_SOFT="$ART_SOFT_FIELDS_RE" -v ART_FLIST="$ART_FINDINGS_LIST_RE" '
        # safe_summary <line> -> "iteration=.. reviewed_hash=.. at=.." using
        # ONLY strictly-numeric/hex character classes for the two fields the
        # raw record could otherwise carry free-form text in -- structurally
        # incapable of reproducing the forbidden token regardless of what a
        # hand-crafted or corrupted reviewer=/model=/pin= value says, because
        # those fields are never read here at all. See the comment above this
        # block for why raw records are never quoted.
        function safe_summary(line,    it, hs, ts2) {
            it = "unparseable"
            if (match(line, /iteration=[0-9]+/)) {
                it = substr(line, RSTART + 10, RLENGTH - 10)
            }
            hs = "absent"
            if (match(line, /reviewed_hash=[0-9a-fA-F]+/)) {
                hs = substr(line, RSTART + 14, RLENGTH - 14)
            }
            ts2 = "unparseable"
            if (match(line, / at [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z:/)) {
                ts2 = substr(line, RSTART + 4, RLENGTH - 5)
            }
            return "iteration=" it " reviewed_hash=" hs " at=" ts2
        }
        # safe_summary_malformed() and is_quarantined() -- REMOVED
        # (claude-workflow-plugin-k6re, R2-F1). See the tombstone comment
        # above this awk invocation, where ART-QUARANTINE-HASH used to sit,
        # for the finding and the full reasoning. Every call site below now
        # uses plain safe_summary() -- no hash is computed or printed for a
        # malformed candidate any more, because nothing reads one.
        # ART-ITER-CMP BEGIN (claude-workflow-plugin-k6re, R1-F1)
        #
        # THE DEFECT. `iters[n] = itraw + 0` (a few lines below) forced an
        # UNBOUNDED validated digit string (itraw already matched ^[0-9]+$
        # upstream) into awk own numeric type -- a C double -- before the
        # max/winner computation ever ran. A double mantissa is 53 bits, so
        # two DISTINCT decimal integers above 2^53 (9007199254740992) can
        # silently collapse to the identical double. MEASURED on this host,
        # via awk itself: assigning "9007199254740992"+0 to one variable and
        # "9007199254740993"+0 to another and comparing them with == reports
        # equal; both print back as 9007199254740992. Consequence: a record
        # at iteration=9007199254740993 (older) and one at
        # iteration=9007199254740992 (newer timestamp) compare
        # iteration-EQUAL, so the newer-timestamp record reads as
        # simultaneously max-iteration AND max-timestamp and is silently
        # SELECTED as governing -- a wrong-record selection and a regression
        # of the refuse-on-ambiguity property this whole selector exists to
        # provide (review_artifact_selection_disagreement never fires when
        # it should have).
        #
        # THE FIX. iteration values are never converted to awk numeric type
        # anywhere in this selector, at any length. norm_iter() strips
        # leading zeros (so "007" and "7" compare EQUAL -- they are the same
        # iteration number under any other reading; this also makes a bare
        # LENGTH compare a correct magnitude test, which it is not on
        # un-normalised digit strings: a value padded with many leading
        # zeros is a LONGER string than an unpadded smaller number while
        # representing a SMALLER value once those zeros are removed).
        # iter_cmp() then compares normalised LENGTH first -- exact for
        # arbitrary-length non-negative integers, no magic constant, no
        # double involved -- and only falls back to a character-by-character
        # compare when both operands have the SAME normalised length, which
        # is exactly the case (two huge, equal-length digit strings) a
        # numeric coercion would get wrong again. That fallback is forced
        # into STRING semantics via a non-digit sentinel (Z) appended to
        # both sides: awk own numeric-string (strnum) auto-coercion would
        # otherwise silently promote an equal-length all-digit comparison
        # back to a numeric one -- the identical failure this whole fix
        # removes, wearing a different hat. Verified empirically, not
        # assumed (this file own standing discipline): a bare digit-string
        # equality test inside this awk risks exactly that auto-promotion;
        # appending Z makes the operand string form not look like a number
        # at all, so no implementation strnum rule can apply.
        #
        # Only ever called with itraw / maxit, both already validated
        # ^[0-9]+$ upstream (a value that fails that regex is baditer, never
        # reaches n++/iters[]) -- norm_iter() does not need to guard
        # non-digit input.
        function norm_iter(s) {
            sub(/^0+/, "", s)
            if (s == "") s = "0"
            return s
        }
        function iter_cmp(a, b,    na, nb) {
            na = norm_iter(a); nb = norm_iter(b)
            if (length(na) != length(nb)) return (length(na) < length(nb)) ? -1 : 1
            if ((na "Z") == (nb "Z")) return 0
            return ((na "Z") < (nb "Z")) ? -1 : 1
        }
        # ART-ITER-CMP END
        # ART-PARSE-FNS BEGIN (claude-workflow-plugin-k6re R3-F1). See the
        # ART-PARSE-SHARED comment in the bash caller (right before this
        # awk program is built) for the full defect, fix, and backward-
        # compatibility reasoning -- these four functions ARE that fix.
        # Each is a STRICT SUPERSET of the one before it (art_findings_ok
        # itself re-requires a valid iteration=; art_ts_ok in turn
        # re-requires a valid findings=[...]) rather than three unrelated
        # checks -- deliberate, not incidental: that is what "anchored"
        # means here. You cannot validate what follows a token without
        # first knowing where that token itself ends, so each stage regex
        # has to re-walk everything the stage before it already confirmed. One
        # consequence, verified directly while wiring the selector below: a
        # record with a malformed findings=[...] token is refused by BOTH
        # art_findings_ok() (badfindings) AND, independently, by art_ts_ok()
        # (badts) -- removing the DEDICATED findings check alone still
        # leaves the selector refusing such a record, just under
        # badts/review_artifact_timestamp_unparseable instead of
        # badfindings/review_artifact_malformed. review-count.test.sh
        # section 4b documents this precisely (see the updated comment on
        # test 4b.6) rather than asserting a stale error_key.
        #
        # art_iter_ok(line): two-step -- loose capture
        # (iteration=[A-Za-z0-9._-]+, the SAME class the pre-existing itraw
        # capture used) then strict ^[0-9]+$ on the FULL captured token.
        # A single-step `iteration=[0-9]+` would silently accept only the
        # digit PREFIX of something like "iteration=1.5" (matching just
        # "1") and let the ".5" fall through to be misclassified downstream
        # as a findings- or timestamp-stage failure instead of the
        # iteration failure it actually is -- verified directly while
        # building this fix.
        function art_iter_ok(line,    m, tok_start, tok_len, tok) {
            m = match(line, /^REVIEW-ARTIFACT v1 iteration=[A-Za-z0-9._-]+/)
            if (m != 1) return 0
            tok_start = length("REVIEW-ARTIFACT v1 iteration=") + 1
            tok_len = RLENGTH - tok_start + 1
            tok = substr(line, tok_start, tok_len)
            return (tok ~ /^[0-9]+$/)
        }
        # art_findings_ok(line): the anchored walk through the seven
        # optional soft fields (ART_SOFT, passed in via -v) to a
        # WELL-FORMED findings=[...] token, content excluding whitespace
        # (the content-class fix: see ART-PARSE-SHARED for why a legitimate
        # finding list never needed a space either, so this costs nothing
        # real and makes a bracket structurally unable to swallow a later,
        # space-separated field as its own "content"). claude-workflow-
        # plugin-k6re R7-F1 (independent review round 7) widened this SAME
        # exclusion to `[` as well: the space-only class still let a
        # bracket swallow its OWN delimiter when a declared finding value
        # itself contained the literal text "findings=[", closing the
        # bracket at that nested `[...]` instead of the real one -- see the
        # R7-F1 comment above the ART_FINDINGS extractor below for the full
        # defect and fix. This function, art_ts_ok, and art_prefix_len
        # (both copies) all needed the identical one-character widening, by
        # the same ART-PARSE-SHARED hand-kept-consistency this comment
        # already documents.
        function art_findings_ok(line,    re) {
            re = "^REVIEW-ARTIFACT v1 iteration=[0-9]+" ART_SOFT \
                 " findings=\\[" ART_FLIST "\\]"
            return (match(line, re) == 1)
        }
        # art_ts_ok(line): the FULL anchored grammar, iteration= through the
        # mandatory `at <ts>:` that opens the summary (artifact_hash=
        # optional, same reasoning as the seven soft fields).
        function art_ts_ok(line,    re) {
            re = "^REVIEW-ARTIFACT v1 iteration=[0-9]+" ART_SOFT \
                 " findings=\\[" ART_FLIST "\\]( artifact_hash=[A-Za-z0-9._-]+)?" \
                 " at [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z:"
            return (match(line, re) == 1)
        }
        # art_prefix_len(line): same grammar as art_ts_ok(), but returns the
        # LENGTH of the machine-token prefix (through the space after the
        # summary colon) rather than a boolean. Not used by the selector
        # below (art_ts_ok already establishes well-formedness; extraction
        # then reuses the plain leftmost match, see the comment in the rule
        # below for why that is safe once well-formedness is established) --
        # this is the function the POST-SELECTION re-verification further
        # down calls, on the single WINNING record, to compute the actual
        # slice every field extractor reads from. Defined here, in the ONE
        # shared text, so both call sites see the identical grammar.
        function art_prefix_len(line,    re, n) {
            re = "^REVIEW-ARTIFACT v1 iteration=[0-9]+" ART_SOFT \
                 " findings=\\[" ART_FLIST "\\]( artifact_hash=[A-Za-z0-9._-]+)?" \
                 " at [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z: "
            n = match(line, re)
            return (n == 1) ? RLENGTH : 0
        }
        # ART-PARSE-FNS END
        BEGIN {
            n = 0; badfindings = 0; baditer = 0; badts = 0
        }
        /^REVIEW-ARTIFACT v1 / {
            # Three sequential, ANCHORED checks -- iteration, then findings,
            # then timestamp, in that order. This precedence is not
            # arbitrary and, unlike the pre-R3-F1 code, is not merely a
            # style choice either: art_findings_ok() can only locate
            # findings=[...] by first walking PAST a syntactically valid
            # iteration= token, so "findings checked independently of
            # iteration" and "a token position never inferred from an
            # unanchored scan" cannot both be true at once -- the pre-R3-F1
            # "findings checked first" precedence was only achievable
            # BECAUSE its findings check ignored position entirely, which is
            # the defect this rewrite removes. This only changes observable
            # behaviour for a record with MULTIPLE simultaneous defects (no
            # existing fixture pins that combination); every single-defect
            # fixture in review-count.test.sh classifies identically
            # either way.
            if (!art_iter_ok($0)) {
                baditer = 1; baditerline = $0
                next
            }
            # ART-SELECT-FINDINGS-GUARD BEGIN (claude-workflow-plugin-k6re, R3-F1 rewrite)
            if (!art_findings_ok($0)) {
                badfindings = 1; badfindingsline = $0
                next
            }
            # ART-SELECT-FINDINGS-GUARD END
            if (!art_ts_ok($0)) {
                badts = 1; badtsline = $0
                next
            }
            # Well-formed under all three anchored checks. iteration/
            # timestamp are extracted via a PLAIN leftmost match -- safe
            # here, and deliberately the SAME extraction the pre-R3-F1 code
            # used, because a leftmost match can only ever find a LATER,
            # summary-embedded lookalike AFTER the real, anchored occurrence
            # the three checks above already proved exists first: no field
            # before the summary can contain a space (findings=[...] now
            # included, per the content-class fix), so nothing before the
            # summary can smuggle a later field keyword= earlier than its
            # own true position.
            itraw = ""
            if (match($0, /iteration=[A-Za-z0-9._-]+/)) {
                itraw = substr($0, RSTART + 10, RLENGTH - 10)
            }
            ts = ""
            if (match($0, / at [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z:/)) {
                ts = substr($0, RSTART + 4, RLENGTH - 5)
            }
            lines[n] = $0
            # iters[n] stores the VALIDATED (^[0-9]+$), UNMODIFIED digit
            # string -- never `+ 0`. See ART-ITER-CMP above: converting to
            # awk numeric type here is exactly the R1-F1 precision-loss
            # defect. Every comparison against iters[] below goes through
            # iter_cmp(), never a bare </>/==.
            iters[n] = itraw
            tss[n] = ts
            n++
        }
        END {
            # ART-SELECT-RECOVER -- REMOVED (claude-workflow-plugin-k6re,
            # R2-F1; full history in the tombstone above, where
            # ART-QUARANTINE-HASH used to sit). Reaching this END block with
            # badfindings/baditer/badts still set means a malformed
            # candidate exists; refuse unconditionally, regardless of where
            # it sits or what is posted about it afterward -- there is
            # nothing upstream that could have excluded it any more.
            if (badfindings) { print "MALFORMED"; print safe_summary(badfindingsline); exit }
            if (baditer) { print "ITER_UNPARSEABLE"; print safe_summary(baditerline); exit }
            if (badts) { print "TS_UNPARSEABLE"; print safe_summary(badtsline); exit }
            if (n == 0) { print "NONE"; exit }
            # maxit is computed via iter_cmp() (claude-workflow-plugin-k6re,
            # R1-F1) -- never `iters[i] > maxit`, which would coerce both
            # sides to awk numeric type and reintroduce the precision-loss
            # defect this fix removes. "" is a safe not-yet-set sentinel:
            # every iters[i] is a non-empty ^[0-9]+$ string (minimum "0"),
            # so it can never collide with the sentinel.
            maxit = ""
            for (i = 0; i < n; i++) { if (maxit == "" || iter_cmp(iters[i], maxit) > 0) maxit = iters[i] }
            maxts = ""
            for (i = 0; i < n; i++) { if (tss[i] > maxts) maxts = tss[i] }
            winners = 0
            winline = ""
            for (i = 0; i < n; i++) {
                if (iter_cmp(iters[i], maxit) == 0 && tss[i] == maxts) { winners++; winline = lines[i] }
            }
            # OK below prints the WINNING RECORD ITSELF (winline), never a
            # summary: this becomes $art, and everything downstream
            # (REVIEWER, THRESHOLD, ART_VERDICT, reviewer_identity in the
            # final envelope, ...) already reads real reviewer= data from it
            # -- pre-existing, legitimate behaviour this fix does not touch.
            # Every OTHER exit here is diagnostic-only ($art stays "" for
            # all of them, per the case statement below this awk program)
            # and uses safe_summary().
            if (winners == 1) { print "OK"; print winline; exit }
            if (winners >= 2) { print "TIE_UNRESOLVED"; print safe_summary(winline); exit }
            iterwinline = ""
            for (i = 0; i < n; i++) { if (iter_cmp(iters[i], maxit) == 0) { iterwinline = lines[i]; break } }
            tswinline = ""
            for (i = 0; i < n; i++) { if (tss[i] == maxts) { tswinline = lines[i]; break } }
            print "DISAGREEMENT"
            print safe_summary(iterwinline) " ||| " safe_summary(tswinline)
        }
    ' "$firstlines" 2>/dev/null)
    art_rc=$?
    if [ "$art_rc" -ne 0 ]; then
        emit_gate 4 "false" "review_artifact_set_unreadable" \
            "could not read the REVIEW-ARTIFACT record set for $tid (awk exit $art_rc reading the comment firstlines); refusing rather than treating an unestablished set as having no records"
    fi
    local art_select_status
    art_select_status="${art_out%%$'\n'*}"
    if [ "$art_select_status" = "$art_out" ]; then
        ART_SELECT_DETAIL=""
    else
        ART_SELECT_DETAIL="${art_out#*$'\n'}"
    fi
    case "$art_select_status" in
        OK)                 art="$ART_SELECT_DETAIL" ;;
        NONE)               art="" ;;
        MALFORMED)          art=""; ART_SELECT_ERR="review_artifact_malformed" ;;
        ITER_UNPARSEABLE)   art=""; ART_SELECT_ERR="review_artifact_iteration_unparseable" ;;
        TS_UNPARSEABLE)     art=""; ART_SELECT_ERR="review_artifact_timestamp_unparseable" ;;
        TIE_UNRESOLVED)     art=""; ART_SELECT_ERR="review_artifact_selection_tie_unresolved" ;;
        DISAGREEMENT)       art=""; ART_SELECT_ERR="review_artifact_selection_disagreement" ;;
        *)                  art=""; ART_SELECT_ERR="review_artifact_selection_internal_error" ;;
    esac
    # ART-ITERATION-SELECT END

    # ART-PREFIX-GUARD (claude-workflow-plugin-k6re R3-F1). The SECOND,
    # independent invocation of the anchored grammar art_ts_ok() already
    # applied inside the selector above -- computed here, on the single
    # WINNING record, in a SEPARATE awk process, so a future bug in the
    # selector's OWN wiring (e.g. an edit that forgets to gate
    # `lines[n]=$0` behind art_ts_ok()) does not silently propagate an
    # unverified `art` all the way to the field extractors below. This is
    # the direct descendant of the pre-R3-F1 MALFORMED-ARTIFACT-GUARD (same
    # defense-in-depth role: `art` must never reach the extractors as
    # anything other than a fully anchored record) -- moved EARLIER, ahead
    # of the extractions themselves, because $ART_PREFIX (not $art) is what
    # every extractor below now reads FROM; computing it after the
    # extractions had already run would defeat the point.
    #
    # ART_PREFIX is also what closes reproduction 2 of R3-F1: even a record
    # that legitimately passed the selector's art_ts_ok() can carry a
    # SUMMARY that independently mentions `findings=[...]`-shaped text --
    # art_ts_ok() says nothing about the summary's own content, by design
    # (it is free text, and is meant to be). Slicing here, once, is what
    # makes that summary structurally unreachable by every extractor below,
    # including ART_FINDINGS's sed command, whose GREEDY leading `.*` would
    # otherwise prefer a LATER, summary-embedded occurrence over the real
    # one -- exactly the defect measured against a perfectly well-formed
    # record: `... findings=[R3-F1:high] artifact_hash=ah at <ts>: fixed the
    # bug where findings=[] was mis-parsed` read back ART_FINDINGS="" before
    # this fix, silently suppressing an open HIGH with no malformed input
    # anywhere. The other nine fields below (REVIEWER, THRESHOLD, ...) use
    # `grep -oE | head -1`, which is leftmost-first rather than greedy-last
    # and so was never fooled by a LATER summary occurrence the same way --
    # they are scoped to $ART_PREFIX here anyway, uniformly, so the
    # invariant this file states is simply true ("every extractor reads
    # from the prefix, never the raw winning line") rather than true for
    # nine fields for one reason and true for a tenth for a different one.
    ART_PREFIX=""
    if [ -n "$art" ]; then
        ART_PREFIX=$(LC_ALL=C awk -v ART_SOFT="$ART_SOFT_FIELDS_RE" -v ART_FLIST="$ART_FINDINGS_LIST_RE" '
            function art_prefix_len(line,    re, n) {
                re = "^REVIEW-ARTIFACT v1 iteration=[0-9]+" ART_SOFT \
                     " findings=\\[" ART_FLIST "\\]( artifact_hash=[A-Za-z0-9._-]+)?" \
                     " at [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z: "
                n = match(line, re)
                return (n == 1) ? RLENGTH : 0
            }
            { n = art_prefix_len($0); if (n > 0) print substr($0, 1, n) }
        ' <<<"$art" 2>/dev/null)
    fi
    # MALFORMED-ARTIFACT-GUARD-START (load-bearing; the L1 META strips to END)
    # Defense in depth for claude-workflow-plugin-vg8: a winning record that
    # cannot produce a machine-token prefix is MALFORMED -- it must NEVER be
    # read as "zero findings". Independent of the selector's own art_ts_ok()
    # gate above (see ART-PREFIX-GUARD): if $art is non-empty but
    # $ART_PREFIX came back empty, something reached this point without
    # going through, or surviving, that gate.
    if [ -n "$art" ] && [ -z "$ART_PREFIX" ]; then
        emit_gate 4 "false" "review_artifact_malformed" \
            "the latest review record carries no well-formed findings=[...] token (corrupted or truncated record); refusing to read it as zero findings"
    fi
    # MALFORMED-ARTIFACT-GUARD-END

    # ART-PREFIX-PARTITION (claude-workflow-plugin-k6re R5-F1, independent
    # review round 5). See the comment above the REVIEWER=... extractor
    # below for how each field now reads from this partition -- this comment
    # covers the defect and the fix itself.
    #
    # THE DEFECT (R5-F1). findings=[...] is the ONE span inside $ART_PREFIX
    # whose content class (`[^][:space:]]*`, everything except `]` and
    # whitespace) admits `=`. Every OTHER field value class in this grammar
    # (reviewer=/model=/pin=/reviewed_hash=/risk_threshold=/verdict=/
    # stopped_by=/artifact_hash=/iteration=) forbids `=` outright, so none of
    # THEM can ever forge a nested `key=value` pair -- verified directly,
    # none of those nine classes contains `=` as a member. A record that
    # OMITS the seven soft fields (every one is independently optional; see
    # ART_SOFT_FIELDS_RE above) and instead plants `reviewer=<forged>`,
    # `risk_threshold=<forged>`, `verdict=<forged>`, `reviewed_hash=<forged>`
    # INSIDE the brackets is accepted by art_ts_ok() -- an absent soft field
    # is not a grammar violation -- and every extractor below used to scan
    # the WHOLE of $ART_PREFIX with `grep -oE ... | head -1`, brackets
    # included. Measured directly against:
    #   REVIEW-ARTIFACT v1 iteration=99 findings=[R1-F1,reviewer=example-name,
    #     risk_threshold=low,verdict=approve,reviewed_hash=deadbeefdeadbeef]
    #     at 2026-09-02T00:00:00Z: benign looking summary
    # this read back REVIEWER=example-name, THRESHOLD=low,
    # ART_HASH=deadbeefdeadbeef, and ART_VERDICT=approve -- none of them
    # ever declared -- which bypassed REVIEWER-NONEMPTY-GUARD below (an
    # attacker-chosen "independent" identity where none was named) and fed a
    # forged risk_threshold/verdict/reviewed_hash straight into emit_gate's
    # reported envelope. A forged `artifact_hash=` planted the same way
    # reaches ART_FILE_HASH identically -- verified separately, one field
    # later in the grammar, same mechanism.
    #
    # THE FIX removes the mechanism ("grep the whole region for key=value")
    # rather than guarding this one instance of it, per the operator
    # standing ruling on this arc: a defect family that survives repeated
    # rounds against the same mechanism gets the mechanism removed, not
    # guarded again. This is the THIRD recurrence of "an unanchored scan
    # reads text the grammar never assigned to that field" against this one
    # parse (greedy findings= sed, the summary boundary, now the bracket
    # content). $ART_PREFIX is partitioned into the two regions the anchored
    # grammar already proves are disjoint from the bracket, using the SAME
    # technique art_prefix_len() itself uses (an anchored match, then
    # substr() on RLENGTH) -- not a new mechanism, pointed at the boundary on
    # each side of the one span that needs excluding:
    #
    #   ART_PREFIX_HEAD -- "REVIEW-ARTIFACT v1 iteration=N" plus whichever of
    #     the seven soft fields are present, ending at the space immediately
    #     before "findings=[". Nowhere else in this grammar defines
    #     iteration=, reviewer=, model=, pin=, reviewed_hash=,
    #     risk_threshold=, verdict=, or stopped_by=, so this is the only
    #     region that ever needs to be searched for any of them.
    #   ART_PREFIX_TAIL -- everything from immediately after the findings
    #     bracket close through the end of $ART_PREFIX (the optional
    #     artifact_hash= token and the mandatory " at <ts>: "). artifact_hash=
    #     is the only field the grammar ever places after the bracket, so
    #     this is the only region that ever needs to be searched for it.
    #
    # Neither region contains one byte of the bracket content -- not "the
    # bracket minus a denylisted substring", the bracket is simply outside
    # both regions -- so a value planted inside findings=[...] can never
    # again be read back as a different field declaration, regardless of
    # what content that bracket is asked to hold in the future.
    # ART_FINDINGS (below) is the one extractor that is SUPPOSED to read the
    # bracket; it is unchanged and keeps reading $ART_PREFIX directly. Every
    # OTHER extractor in this function now reads from ART_PREFIX_HEAD or
    # ART_PREFIX_TAIL, never from $ART_PREFIX itself.
    #
    # MEASURED: against the crafted record above, ART_PREFIX_HEAD is exactly
    # "REVIEW-ARTIFACT v1 iteration=99" (no soft fields present) and every
    # one of REVIEWER/THRESHOLD/ART_HASH/ART_VERDICT/ART_FILE_HASH reads back
    # empty -- identical to how a genuinely bare record (no soft fields
    # declared; the live claude-workflow-plugin-fkm.1.1 shape, all six real
    # records) has always read. Also measured against a fully-populated
    # legitimate record (all seven soft fields plus artifact_hash=, including
    # a model= value that legitimately contains `[`/`]` per the 46w9 bracket
    # widening): every extracted value is byte-identical to the pre-fix
    # extraction -- no regression on the well-formed path.
    ART_PREFIX_HEAD=""
    ART_PREFIX_TAIL=""
    if [ -n "$ART_PREFIX" ]; then
        local _art_prefix_regions
        _art_prefix_regions=$(LC_ALL=C awk -v ART_SOFT="$ART_SOFT_FIELDS_RE" -v ART_FLIST="$ART_FINDINGS_LIST_RE" '
            function art_head_len(line,    re, n) {
                re = "^REVIEW-ARTIFACT v1 iteration=[0-9]+" ART_SOFT
                n = match(line, re)
                return (n == 1) ? RLENGTH : 0
            }
            function art_bracket_end_len(line,    re, n) {
                re = "^REVIEW-ARTIFACT v1 iteration=[0-9]+" ART_SOFT \
                     " findings=\\[" ART_FLIST "\\]"
                n = match(line, re)
                return (n == 1) ? RLENGTH : 0
            }
            {
                h = art_head_len($0)
                b = art_bracket_end_len($0)
                print substr($0, 1, h)
                print substr($0, b + 1)
            }
        ' <<<"$ART_PREFIX" 2>/dev/null)
        ART_PREFIX_HEAD="${_art_prefix_regions%%$'\n'*}"
        ART_PREFIX_TAIL="${_art_prefix_regions#*$'\n'}"
    fi
    # ART-PREFIX-PARTITION-GUARD. HEAD is never empty when ART_PREFIX is
    # non-empty -- ART_PREFIX always contains at least "REVIEW-ARTIFACT v1
    # iteration=N" (iteration= is mandatory, not one of the seven optional
    # soft fields), and art_head_len()'s regex is anchored on exactly that
    # same mandatory literal. An empty ART_PREFIX_HEAD here can only mean
    # this awk invocation itself failed to run (rather than ran and found
    # nothing) -- refuse rather than silently reading every extractor below
    # as "no soft fields declared", which would misreport a well-formed
    # record's real reviewer=/model=/... as absent.
    if [ -n "$ART_PREFIX" ] && [ -z "$ART_PREFIX_HEAD" ]; then
        emit_gate 4 "false" "review_artifact_partition_failed" \
            "could not partition the REVIEW-ARTIFACT v1 record for $tid into its head/findings/tail regions (awk failed to reproduce a result that must always be non-empty here); refusing rather than reading every soft field as undeclared"
    fi
    # ART-PREFIX-PARTITION END

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
    # reviewed_hash= is a soft field (see ART_SOFT_FIELDS_RE); it only ever
    # legitimately appears in ART_PREFIX_HEAD (claude-workflow-plugin-k6re
    # R5-F1 -- see ART-PREFIX-PARTITION above). The guard below still checks
    # ART_PREFIX (not ART_PREFIX_HEAD) as the "a record exists at all"
    # signal -- the two are non-empty/empty together by construction.
    if [ -z "$ROUNDS_HASH" ] && [ -n "$ART_PREFIX" ]; then
        ROUNDS_HASH=$(printf '%s' "$ART_PREFIX_HEAD" | grep -oE 'reviewed_hash=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
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
    # escalation-basis.sh legs C and H are the tests proving this property
    # must survive — reconcile-only growth and genuine-new-work growth move
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
        # The three MALFORMED/ITER_UNPARSEABLE/TS_UNPARSEABLE classes share
        # one remediation. claude-workflow-plugin-k6re R2-F1 removed the
        # quarantine-artifact recovery path R12-F1 had put here (a forged
        # quarantine record could clear a malformed candidate exactly as
        # easily as the malformed record itself was posted -- see the
        # tombstone above the awk invocation): there is no recovery command
        # to name any more, and this message says so rather than pointing at
        # one that no longer exists.
        case "$ART_SELECT_ERR" in
            review_artifact_malformed|review_artifact_iteration_unparseable|review_artifact_timestamp_unparseable)
                emit_gate 4 "false" "$ART_SELECT_ERR" \
                    "a REVIEW-ARTIFACT v1 candidate for $tid is malformed (record: ${ART_SELECT_DETAIL:-<none>}); refusing unconditionally and permanently, regardless of where this candidate sits in bd's comment history or what any later comment claims about it. There is no recovery path through review-check.sh or qa-gate.sh (claude-workflow-plugin-k6re R2-F1 removed the prior comment-based override that used to exist for this: the read side could not verify who posted an excusing record, and matched it too loosely, so the same unauthenticated write path able to post a malformed record could equally forge an excuse for one). An operator must repair the underlying record directly in the store; nothing posted through an ordinary bd comment can clear this"
                ;;
        esac
        if [ -n "$ART_SELECT_ERR" ]; then
            emit_gate 4 "false" "$ART_SELECT_ERR" \
                "could not determine which REVIEW-ARTIFACT v1 record governs for $tid without relying on comment position (offending record: ${ART_SELECT_DETAIL:-<none>}); refusing rather than falling back to the last comment in bd's append order, which is the exact defect this selector replaces"
        fi
        emit_gate 4 "false" "review_artifact_missing" "no REVIEW-ARTIFACT v1 comment found for $tid"
    fi

    # Every extractor below reads from $ART_PREFIX, never from $art -- see
    # ART-PREFIX-GUARD above for why that is the whole fix, not an
    # incidental cleanup: $ART_PREFIX ends at the space after the summary
    # colon, so a free-text summary that mentions any of these tokens'
    # spelling is not merely unlikely to confuse the extraction below, it is
    # structurally absent from the string these commands ever see.
    #
    # AS OF claude-workflow-plugin-k6re R5-F1 (see ART-PREFIX-PARTITION
    # above), that is necessary but no longer sufficient on its own:
    # iteration=/reviewer=/model=/pin=/reviewed_hash=/risk_threshold=/
    # verdict=/stopped_by= now read from ART_PREFIX_HEAD (the span before
    # the findings bracket) and artifact_hash= reads from ART_PREFIX_TAIL
    # (the span after it) -- neither can contain a byte of the bracket's own
    # content, so nothing planted inside findings=[...] can be read back as
    # one of these fields. Only ART_FINDINGS itself still reads the raw
    # $ART_PREFIX, because it is the one extractor meant to see the bracket.
    REVIEWER=$(printf '%s' "$ART_PREFIX_HEAD" | grep -oE 'reviewer=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    THRESHOLD=$(printf '%s' "$ART_PREFIX_HEAD" | grep -oE 'risk_threshold=[A-Za-z0-9_]+' | head -1 | cut -d= -f2- || true)
    ART_ITER=$(printf '%s' "$ART_PREFIX_HEAD" | grep -oE 'iteration=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    # bjx: widened to include brackets (claude-workflow-plugin-46w9) — a real
    # observed runtime id, `claude-opus-5[1m]`, was truncated at the `[` by
    # the pre-46w9 class and silently lost its bracket suffix on read-back.
    # `]` must be the character immediately after the opening `[` and `-` must
    # be last: POSIX ERE does not treat `\[`/`\]` as escapes INSIDE a bracket
    # expression (measured directly while building this check).
    ART_MODEL=$(printf '%s' "$ART_PREFIX_HEAD" | grep -oE 'model=[]A-Za-z0-9._:/[-]+' | head -1 | cut -d= -f2- || true)
    # "pin=" mirrors the SAME abbreviation "model=" already uses for the JSON
    # field reviewer_model — the JSON payload key stays reviewer_pin (matching
    # validate-artifact's schema), the comment TOKEN is short, consistent with
    # this grammar's existing convention, and unambiguous (no other token name
    # in this grammar contains "pin" as a substring).
    ART_REVIEWER_PIN=$(printf '%s' "$ART_PREFIX_HEAD" | grep -oE 'pin=[]A-Za-z0-9._:/[-]+' | head -1 | cut -d= -f2- || true)
    ART_HASH=$(printf '%s' "$ART_PREFIX_HEAD" | grep -oE 'reviewed_hash=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    # artifact_hash= (v5 D2 / claude-workflow-plugin-rqer): the byte digest of
    # the canonical artifact FILE (docs/reviews/<tid>-r<n>.json), as opposed
    # to ART_HASH above, which is reviewed_hash — the CHANGE-SET hash the
    # reviewer read. The two must never be conflated: one names bytes on
    # disk today, the other names a claim about the past. Absent on any
    # record written before this field existed — an empty string, read by
    # cmd_approve's REVIEW-ARTIFACT-BINDING-TOKEN ladder as "no binding".
    # Unlike the other nine fields on this page, artifact_hash= is placed
    # AFTER the findings bracket in the grammar (see art_ts_ok()), so it
    # reads from ART_PREFIX_TAIL, not ART_PREFIX_HEAD (claude-workflow-
    # plugin-k6re R5-F1 — see ART-PREFIX-PARTITION above).
    ART_FILE_HASH=$(printf '%s' "$ART_PREFIX_TAIL" | grep -oE 'artifact_hash=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2- || true)
    ART_VERDICT=$(printf '%s' "$ART_PREFIX_HEAD" | grep -oE 'verdict=[A-Za-z]+' | head -1 | cut -d= -f2- || true)
    ART_STOPPED=$(printf '%s' "$ART_PREFIX_HEAD" | grep -oE 'stopped_by=[A-Za-z0-9_:]+' | head -1 | cut -d= -f2- || true)
    # ART-FINDINGS-EXTRACT BEGIN (claude-workflow-plugin-k6re R7-F1).
    # Sentinel-anchored (not line-numbered) so the L1 spec's mutant can swap
    # this region for the pre-fix one-liner without drifting off target as
    # the file is edited around it -- same convention as
    # MALFORMED-ARTIFACT-GUARD and IMPLEMENTER-SET-READ-GUARD elsewhere in
    # this function.
    # ART_FINDINGS is the field R3-F1 was filed against: sed's leading `.*`
    # is GREEDY and prefers the LAST findings=[...] occurrence on a line, so
    # this command was never safe to run against anything wider than the
    # anchored prefix -- see ART-PREFIX-GUARD above for the measured
    # reproduction.
    #
    # claude-workflow-plugin-k6re R7-F1 (independent review round 7,
    # reproduced by the orchestrator before dispatch). The comment this
    # replaces asserted: "$ART_PREFIX contains AT MOST one findings=[...]
    # occurrence by construction (the regex used by art_prefix_len requires
    # the WHOLE prefix to match exactly once, end to end), so greedy-vs-
    # leftmost is no longer a live question here: there is only one
    # occurrence left to find." MEASURED FALSE, and nothing had ever tested
    # it:
    #   ... findings=[R7-F1:high,findings=[] at <ts>: summary
    # was a WELL-FORMED record under the pre-fix grammar (the content class
    # below used to read `[^][:space:]]*`, excluding only `]` and
    # whitespace -- it PERMITTED a literal `[`), and its $ART_PREFIX
    # genuinely contained the literal text "findings=[" TWICE: once for the
    # real field, and once again planted inside the declared finding value
    # itself. The anchored grammar closes the bracket at the FIRST `]` it
    # meets, and this record arranges for that to be the nested one rather
    # than a real closing bracket -- so BOTH the shipped GREEDY sed
    # (preferring the LAST occurrence) and a LEFTMOST rewrite (preferring
    # the FIRST) read back ART_FINDINGS="" against it, verified directly in
    # both directions. Greediness direction was never the defect: the
    # CONTENT CLASS admitting the bracket delimiter itself as legal content
    # was. A declared HIGH finding vanished with no malformed input
    # anywhere -- open_findings read 0 and the gate reported a clean
    # review.
    #
    # THE FIX excludes `[` from the findings content class everywhere this
    # grammar bracket is matched: art_findings_ok / art_ts_ok /
    # art_prefix_len above, and the ART-PREFIX-GUARD / ART-PREFIX-PARTITION
    # duplicates of art_prefix_len / art_bracket_end_len (the ART-PARSE-
    # SHARED hand-kept-consistent copies -- awk has no cross-invocation
    # `source`, so each site keeps its own). A legitimate finding list
    # (`Rn-Fn:severity[,Rn-Fn:severity]*`) never needs `[` any more than it
    # needs a space or an `=` -- verified against every fixture in the
    # review-count.test.sh sections covering this grammar -- so this costs
    # nothing real, the exact R3-F1 reasoning extended one character class
    # further. Once no candidate can carry a nested `[` inside the bracket
    # and still satisfy art_findings_ok(), a record shaped like the one
    # above is refused at SELECTION as review_artifact_malformed and never
    # reaches this extractor at all.
    #
    # THIS EXTRACTOR NO LONGER TRUSTS THAT UPSTREAM REFUSAL ALONE (defense
    # in depth -- the same reasoning ART-PREFIX-GUARD above already states
    # for not trusting the wiring of the selector exclusively, and the
    # exact discipline the predecessor of this comment skipped by
    # declaring the remainder safe with an argument instead of a re-walk):
    # it re-derives its own anchored open/close offsets from $ART_PREFIX
    # under the SAME tightened grammar, rather than scanning $ART_PREFIX
    # with sed, greedy or leftmost. ART-FINDINGS-EXTRACT-GUARD below
    # refuses rather than reading a wiring mismatch between this and the
    # checks above as "zero findings" -- the same failure mode this whole
    # fix exists to close, now guarded against a second cause (a future
    # drift between the duplicated copies) as well as the first (the
    # permissive class).
    ART_FINDINGS=""
    if [ -n "$ART_PREFIX" ]; then
        local _art_findings_out _art_findings_status _art_findings_detail
        _art_findings_out=$(LC_ALL=C awk -v ART_SOFT="$ART_SOFT_FIELDS_RE" -v ART_FLIST="$ART_FINDINGS_LIST_RE" '
            function art_findings_open_len(line,    re, n) {
                re = "^REVIEW-ARTIFACT v1 iteration=[0-9]+" ART_SOFT " findings=\\["
                n = match(line, re)
                return (n == 1) ? RLENGTH : 0
            }
            function art_bracket_end_len(line,    re, n) {
                re = "^REVIEW-ARTIFACT v1 iteration=[0-9]+" ART_SOFT \
                     " findings=\\[" ART_FLIST "\\]"
                n = match(line, re)
                return (n == 1) ? RLENGTH : 0
            }
            {
                ol = art_findings_open_len($0)
                bl = art_bracket_end_len($0)
                if (ol > 0 && bl > ol) { print "OK"; print substr($0, ol + 1, bl - ol - 1) }
                else { print "FAIL" }
            }
        ' <<<"$ART_PREFIX" 2>/dev/null)
        _art_findings_status="${_art_findings_out%%$'\n'*}"
        if [ "$_art_findings_status" = "$_art_findings_out" ]; then
            _art_findings_detail=""
        else
            _art_findings_detail="${_art_findings_out#*$'\n'}"
        fi
        # ART-FINDINGS-EXTRACT-GUARD (claude-workflow-plugin-k6re R7-F1).
        # $ART_PREFIX is already validated well-formed above (a non-empty
        # art_prefix_len result under this SAME tightened grammar,
        # MALFORMED-ARTIFACT-GUARD) -- so finding no bracket here means
        # these two functions have drifted out of sync with art_prefix_len,
        # not that the record is legitimately bracket-less (a bracket-less
        # record fails art_ts_ok upstream and never reaches this point at
        # all). Refuse rather than silently reading that drift as "zero
        # findings".
        if [ "$_art_findings_status" = "OK" ]; then
            ART_FINDINGS="$_art_findings_detail"
        else
            emit_gate 4 "false" "review_artifact_malformed" \
                "the latest review record findings=[...] token could not be re-extracted from its already machine-token-validated prefix for $tid (internal grammar mismatch between this extractor and the checks above); refusing rather than reading it as zero findings"
        fi
    fi
    # ART-FINDINGS-EXTRACT END (claude-workflow-plugin-k6re R7-F1)

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

    # MALFORMED-ARTIFACT-GUARD moved: this used to be here, re-checking
    # `findings=\[[^]]*\]` as a bare substring test against $art. It is now
    # ART-PREFIX-GUARD, above, ahead of the extractions rather than after
    # them -- see that comment for why (it computes $ART_PREFIX, which
    # every extractor below reads from, so it has to run before them, not
    # after) and for the vg8 defense-in-depth reasoning this block used to
    # carry. Still load-bearing, still what the L1 META strips (sentinels
    # moved with it: MALFORMED-ARTIFACT-GUARD-START/-END now bracket the
    # $ART_PREFIX computation above, not this now-removed second copy).

    # REVIEWER-NONEMPTY-GUARD BEGIN (i8cx wave 2, adjacent gap noted alongside
    # the impl_lines fix below). Not a pipefail defect -- REVIEWER is
    # extracted from an in-memory string a few lines up (`printf '%s'
    # "$ART_PREFIX" | grep -oE 'reviewer=...' | head -1 | cut ...`), which cannot mask a
    # read failure the way a FILE read can. The gap is a missing VALIDATION:
    # nothing between the artifact-missing check above and the independence
    # check below required `reviewer=` to actually be present on the record.
    # `validate-artifact` (this script's OWN schema, `cmd_validate_artifact`)
    # makes reviewer_identity mandatory for anything written through the
    # proper writer (`qa-gate.sh review-record`) -- but a `bd comments add`
    # typed by hand, or a record from a source that bypasses that writer,
    # is not re-validated here, and the MALFORMED-ARTIFACT-GUARD above only
    # checks for a well-formed findings=[...] token, not for reviewer=. An
    # empty REVIEWER then reaches `grep -qxF "$REVIEWER"` below: `-x` requires
    # a whole-line match, no IMPLEMENTER role is ever the empty string, so an
    # empty REVIEWER can NEVER equal a line in impl_lines and always reads as
    # "independent" -- a record that never named its reviewer would pass the
    # gate that exists specifically to check who the reviewer was.
    if [ -z "$REVIEWER" ]; then
        emit_gate 4 "false" "reviewer_identity_missing" \
            "the latest review record carries no reviewer=<identity> token (malformed or hand-written, not written through qa-gate.sh review-record); refusing rather than reading an unnamed reviewer as independent"
    fi
    # REVIEWER-NONEMPTY-GUARD END (i8cx wave 2)

    # impl = unique captures /^IMPLEMENTER: role=([a-z]+) / over comments.
    #
    # i8cx wave 2 (the audit's fourth must-fix, THE highest-value item in the
    # phase). The old body piped `grep -oE ... "$firstlines" | sed ... |
    # sort -u`, closed with a blanket `|| true`: sort is always last and
    # succeeds trivially on the empty stdin a failed grep leaves behind, so
    # grep genuinely failing to READ "$firstlines" (permission, ENOENT, a
    # vanished mktemp dir -- e.g. from a failed `mktemp -d` upstream making
    # $firstlines resolve to something unwritable) was byte-identical to grep
    # cleanly finding ZERO IMPLEMENTER records. Both landed on impl_lines="",
    # and the trailing `|| true` doubly guaranteed the assignment could never
    # itself signal the difference either.
    #
    # THE CONSEQUENCE: `[ -n "$impl_lines" ] && ... grep -qxF "$REVIEWER"`
    # short-circuits on empty impl_lines, so INDEPENDENT keeps its "true"
    # default and the reviewer_not_independent refusal three lines down never
    # fires. A failed read makes a NON-independent reviewer look independent
    # -- the review-separation gate's whole job is to catch exactly a
    # implementer reviewing their own work, and a masked read failure is a
    # silent, content-independent way past it.
    #
    # THE FIX does not need pipefail to see this: grep is the FIRST stage,
    # captured on its own statement before sed/sort ever run, and POSIX grep's
    # own exit code already distinguishes the two cases (measured against
    # this repo's BSD grep): 0 = match, 1 = a CLEAN no-match, >1 = a real
    # error (unreadable/missing file). Only rc 1 means "no implementer
    # records" and is safe to treat as doc-only work (an orchestrator-authored
    # documentation commit legitimately has no IMPLEMENTER record, and must
    # not be refused for lacking one -- that would deadlock every doc-only
    # task). rc >1 refuses with a NEW, dedicated error_key rather than
    # reusing reviewer_not_independent: a read failure does not establish
    # that the reviewer IS an implementer -- it establishes that whether they
    # are could not be checked, which is a different, honest claim, and
    # qa-gate.sh's `case "$review_key"` already has a generic remedy arm for
    # any key it does not special-case (`review-check.sh gate $tid reported:
    # $review_key`), so a new key needs no change there to refuse correctly.
    # IMPLEMENTER-SET-READ-GUARD BEGIN (i8cx wave 2). Sentinel-anchored (not
    # line-numbered) so the L1 spec's mutant can swap this region for the
    # pre-fix one-liner without drifting off target as the file is edited
    # around it — same convention as MALFORMED-ARTIFACT-GUARD above.
    local impl_raw impl_rc=0
    impl_raw=$(grep -oE '^IMPLEMENTER: role=[a-z]+' "$firstlines" 2>/dev/null)
    impl_rc=$?
    if [ "$impl_rc" -gt 1 ]; then
        emit_gate 4 "false" "implementer_set_unreadable" \
            "could not read the implementer record set for $tid (grep exit $impl_rc reading the comment firstlines); refusing rather than treating an unestablished set as vacuously independent"
    fi
    local impl_lines=""
    # IMPLEMENTER-SET-TRANSFORM-GUARD BEGIN (i8cx R2-F1, independent review round 2).
    # The read guard above stops a FAILED GREP from being read as "zero
    # implementer records", but the very next statement piped that clean
    # grep output through `sed | sort -u` and threw the pipe's own exit
    # status away. printf cannot fail, but sed and sort can — and without
    # pipefail, a pipeline's "$?" is only the LAST stage's, so a sed failure
    # is invisible whenever the sort after it still exits 0 on the
    # empty/partial stdin the failed sed left behind. Either stage failing
    # collapsed to the exact same impl_lines="" the read guard above exists
    # to prevent one statement earlier: a reviewer who IS an implementer
    # read as vacuously independent (measured directly: shimming EITHER sed
    # or sort to exit nonzero with empty output reproduced independent=true
    # against a self-review comment set, pre-fix).
    #
    # Split into two single-fallible-command pipelines rather than reaching
    # for `set -o pipefail`. printf cannot fail, so in each pipeline below
    # exactly one command can fail and it is always the LAST stage — its own
    # "$?" IS the pipeline's "$?", pipefail or not, with none of the
    # "pipefail cannot tell a real failure from a downstream filter's
    # ordinary nonzero" ambiguity a bare `(set -o pipefail; ...)` wrap would
    # have for something like `grep -v` (measured while building this fix:
    # `false | grep -v x` and `printf 'a\n' | grep -v x` both exit 1 under
    # pipefail). Neither `sed 's///'` nor `sort -u` shares that ambiguity:
    # neither exits nonzero merely for finding nothing to change/order, only
    # for an actual failure to run.
    #
    # SAME KEY AS THE READ GUARD ABOVE, not a new one: a failed transform is
    # the same honest claim a failed read is — "the implementer set could
    # not be established" — never "the reviewer IS an implementer" (that
    # would smuggle back the exact inference the read guard exists to
    # refuse). qa-gate.sh's generic per-key remedy arm already handles this
    # key with no change needed there.
    if [ "$impl_rc" -eq 0 ]; then
        local impl_sed impl_sed_rc impl_sort_rc
        impl_sed=$(printf '%s\n' "$impl_raw" | sed -E 's/^IMPLEMENTER: role=//')
        impl_sed_rc=$?
        impl_lines=$(printf '%s\n' "$impl_sed" | sort -u)
        impl_sort_rc=$?
        if [ "$impl_sed_rc" -ne 0 ] || [ "$impl_sort_rc" -ne 0 ]; then
            emit_gate 4 "false" "implementer_set_unreadable" \
                "could not read the implementer record set for $tid (sed exit $impl_sed_rc, sort exit $impl_sort_rc transforming the grep match set); refusing rather than treating an unestablished set as vacuously independent"
        fi
    fi
    # IMPLEMENTER-SET-TRANSFORM-GUARD END (i8cx R2-F1, independent review round 2)
    # IMPLEMENTER-SET-READ-GUARD END (i8cx wave 2)
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
    design-unit-json)  cmd_design_unit_json "$@" ;;
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
                                              / unit_content (each unit's OWN
                                              full canonical JSON body, as a
                                              string, keyed by unit_id) on
                                              the envelope. Never reads an
                                              unparseable block as zero units
  design-unit-json <file> <unit-id>           ONE declared unit's own
                                              canonical JSON (compact, keys
                                              sorted), as a string field
                                              unit_json. Calls validate-design
                                              first and refuses
                                              (design_invalid /
                                              unit_not_in_design) unless it
                                              answers ok:true with the unit
                                              declared, then projects
                                              unit_content[<unit-id>] straight
                                              off THAT call's own envelope —
                                              never a second read of <file>
                                              (i8cx R4-F1). Hashing stays the
                                              caller's job.
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

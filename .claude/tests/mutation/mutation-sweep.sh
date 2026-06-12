#!/bin/bash
# mutation-sweep.sh — Phase C.1 entry point for the mutation harness.
#
# Spec: docs/plans/verification-suite.md, Phase C. Beads:
# claude-workflow-plugin-n45.1.
#
# This script is the deterministic half of the sweep. It:
#
#   1. Selects target scripts (rank-targets.sh; impact_of-or-heuristic).
#   2. Generates mutants per fault-class catalog (lib/generate.sh).
#   3. Applies each mutant in a THROWAWAY git worktree.
#   4. Runs an offline L1+L2 subset per mutant under a per-mutant timeout.
#   5. Classifies each as KILLED (tests failed) or SURVIVED (tests passed).
#   6. Emits a survivors report — JSON and human summary — naming
#      file:line, fault-class, and the diff snippet.
#
# What this script does NOT do (those are C.2/C.3):
#   - call the LLM judge directly. C.1 only ships the seam.
#   - write Beads tasks or tech-debt entries. C.1 emits a report only.
#
# Containment: every mutant is applied inside a worktree under
# .claude/.mutation-worktrees/<id>/. A trap-based cleanup prunes every
# worktree on exit, including failure paths and SIGINT. The main tree is
# never touched. The worktree dir is gitignored.
#
# Cost gate: after the deterministic pass, the script prints
#   "Survivors: <N>  estimated judge cost: <USD>  proceed to judge? (y/N)"
# and waits for confirmation. `--no-judge` skips the judge entirely;
# `--confirm-judge` auto-confirms; `--judge-cmd <path>` sets the seam
# command C.2 will plug into. Without confirmation the script exits 0 with
# the deterministic report already on disk — no paid step has run.
#
# Usage:
#   mutation-sweep.sh [--targets t1,t2,...]    # default: --auto-discover
#                    [--fault-classes F1,F2,...]  # default: ALL
#                    [--output <path>]         # default: stdout + .claude/.mutation-runs/<ts>/
#                    [--no-judge]              # skip judge seam
#                    [--confirm-judge]         # auto-confirm cost gate
#                    [--judge-cmd <path>]      # judge seam command (C.2 plugs in)
#                    [--max-mutants <N>]       # override MAX_MUTANTS_PER_RUN
#                    [--keep-worktrees]        # for debugging only
#                    [--help]
#
# Exit codes:
#   0  success (report generated; judge step optional)
#   1  invocation error
#   2  no targets to mutate
#   3  containment failure (worktree leaked, refused to proceed)

set -u

# ---------------------------------------------------------------------------
# Bootstrap

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# MUTATION_LIB_DIR / MUTATION_CONF env overrides let the L1 test invoke
# a copied-and-patched harness from outside the plugin tree (the patched
# script still needs lib/ from the canonical location). In normal use
# both default to the script's neighbour directory.
LIB_DIR="${MUTATION_LIB_DIR:-$SCRIPT_DIR/lib}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
CONF="${MUTATION_CONF:-$SCRIPT_DIR/mutation.conf}"

# Conf is shell-sourceable; defaults below stay in sync with mutation.conf.
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
MAX_MUTANTS_PER_FILE="${MAX_MUTANTS_PER_FILE:-24}"
MAX_MUTANTS_PER_RUN="${MAX_MUTANTS_PER_RUN:-60}"
MUTANT_TEST_TIMEOUT_S="${MUTANT_TEST_TIMEOUT_S:-60}"
SWEEP_TIMEOUT_S="${SWEEP_TIMEOUT_S:-1800}"
JUDGE_COST_PER_CALL_USD="${JUDGE_COST_PER_CALL_USD:-0.03}"
JUDGE_MAX_CALLS="${JUDGE_MAX_CALLS:-50}"

# Override knobs (arg parsing fills these).
ARG_TARGETS=""
ARG_FAULTS="ALL"
ARG_OUTPUT=""
ARG_NO_JUDGE=0
ARG_CONFIRM_JUDGE=0
ARG_JUDGE_CMD=""
ARG_MAX_MUTANTS=""
ARG_KEEP_WORKTREES=0
# --test-cmd is the test command run per-mutant inside the worktree. It
# defaults to a curated L1+L2 subset (everything except this harness's own
# tests, which would re-recurse). Overridable for the L1 test harness so
# unit tests can supply a toy test instead of running the full suite.
ARG_TEST_CMD=""
# --skip-rank-warn lets the test harness suppress the heuristic-fallback
# stderr warning so the L1 test output stays clean. Default is on (warn).
ARG_QUIET=0

usage() {
    cat >&2 <<'USAGE'
Usage: mutation-sweep.sh [options]

Options:
  --targets <t1,t2,...>     Explicit paths to mutate; default --auto-discover.
  --fault-classes <ids>     Comma-separated fault ids (F1..F8 or ALL).
  --output <dir>            Write report dir here; default .claude/.mutation-runs/<ts>/.
  --no-judge                Skip the judge seam (deterministic-only sweep).
  --confirm-judge           Auto-confirm the cost gate (CI / scripted use).
  --judge-cmd <path>        Judge seam command path (C.2 owns the binary).
  --max-mutants <N>         Override MAX_MUTANTS_PER_RUN for this invocation.
  --test-cmd <cmd>          Override per-mutant test command (default: L1 subset).
  --keep-worktreees         (Debug) skip worktree cleanup on exit.
  --quiet                   Suppress informational warnings to stderr.
  --help                    Print this and exit.

The script generates mutants from the catalog at fault-classes.md, runs
them in throwaway worktrees, classifies each KILLED/SURVIVED, and emits a
report. After the deterministic pass it prints survivor count + estimated
judge cost; the judge seam is gated behind --confirm-judge (or y/N).

See .claude/tests/mutation/README.md for the cost model, the judge seam
contract, and the ranking-fallback proof.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --targets) ARG_TARGETS="${2:-}"; shift 2 ;;
        --fault-classes) ARG_FAULTS="${2:-}"; shift 2 ;;
        --output) ARG_OUTPUT="${2:-}"; shift 2 ;;
        --no-judge) ARG_NO_JUDGE=1; shift ;;
        --confirm-judge) ARG_CONFIRM_JUDGE=1; shift ;;
        --judge-cmd) ARG_JUDGE_CMD="${2:-}"; shift 2 ;;
        --max-mutants) ARG_MAX_MUTANTS="${2:-}"; shift 2 ;;
        --test-cmd) ARG_TEST_CMD="${2:-}"; shift 2 ;;
        --keep-worktrees) ARG_KEEP_WORKTREES=1; shift ;;
        --quiet) ARG_QUIET=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *)
            printf 'mutation-sweep.sh: unknown arg: %s\n' "$1" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -n "$ARG_MAX_MUTANTS" ]; then
    MAX_MUTANTS_PER_RUN="$ARG_MAX_MUTANTS"
fi

log() {
    [ "$ARG_QUIET" = "1" ] && return 0
    printf '%s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# Containment: throwaway worktree + trap-based cleanup.
#
# We register cleanup BEFORE the first worktree call so a SIGINT or an
# early failure still prunes whatever was created. The cleanup is
# idempotent — calling it twice is safe.

WORKTREE_ROOT="$PROJECT_DIR/.claude/.mutation-worktrees"
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
if [ -n "$ARG_OUTPUT" ]; then
    OUTPUT_DIR="$ARG_OUTPUT"
else
    OUTPUT_DIR="$PROJECT_DIR/.claude/.mutation-runs/$RUN_TS"
fi
mkdir -p "$OUTPUT_DIR" "$WORKTREE_ROOT"

CREATED_WORKTREES=()

# shellcheck disable=SC2329  # invoked via `trap` below; shellcheck can't see it.
cleanup_worktrees() {
    if [ "$ARG_KEEP_WORKTREES" = "1" ]; then
        log "# mutation-sweep: --keep-worktrees set; preserving ${#CREATED_WORKTREES[@]} worktree(s) under $WORKTREE_ROOT"
        return 0
    fi
    local wt
    for wt in "${CREATED_WORKTREES[@]:-}"; do
        [ -z "$wt" ] && continue
        # Prune via git so the parent .git/worktrees/ registry is also cleaned.
        # Fall back to plain rm if the worktree was never registered (e.g.,
        # mkdir succeeded but git worktree add failed).
        if [ -d "$wt" ]; then
            git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
        fi
    done
    # Best-effort: prune dangling entries the registry may still hold.
    git -C "$PROJECT_DIR" worktree prune >/dev/null 2>&1 || true
}

trap cleanup_worktrees EXIT INT TERM

# ---------------------------------------------------------------------------
# Step 1: target selection.

select_targets() {
    if [ -n "$ARG_TARGETS" ]; then
        local IFS=','
        # shellcheck disable=SC2206  # word-split is intentional here.
        local arr=($ARG_TARGETS)
        local t
        for t in "${arr[@]}"; do
            [ -z "$t" ] && continue
            printf '%s\n' "$t"
        done
        return 0
    fi
    # Auto-discover via rank-targets.sh; emit just the path column.
    if [ ! -x "$LIB_DIR/rank-targets.sh" ]; then
        bash "$LIB_DIR/rank-targets.sh" --auto-discover \
            | awk -F'\t' 'NF>=2 && $1 !~ /^#/ {print $2}'
    else
        "$LIB_DIR/rank-targets.sh" --auto-discover \
            | awk -F'\t' 'NF>=2 && $1 !~ /^#/ {print $2}'
    fi
}

TARGETS=()
while IFS= read -r t; do
    [ -z "$t" ] && continue
    TARGETS+=("$t")
done < <(select_targets)

if [ "${#TARGETS[@]}" -eq 0 ]; then
    printf 'mutation-sweep: no targets selected (use --targets or check rank-targets.sh)\n' >&2
    exit 2
fi

log "# mutation-sweep: ${#TARGETS[@]} target(s) selected"

# ---------------------------------------------------------------------------
# Step 2: generate mutants per target.
#
# The generator writes a line-oriented wire format (see lib/generate.sh).
# We slurp every mutant into one file (mutants.txt), then iterate. We cap
# at MAX_MUTANTS_PER_FILE per target and MAX_MUTANTS_PER_RUN overall.

MUTANTS_FILE="$OUTPUT_DIR/mutants.txt"
: > "$MUTANTS_FILE"

# Convert fault list (comma-separated or ALL) to a list of fault ids.
FAULT_IDS=()
if [ "$ARG_FAULTS" = "ALL" ]; then
    FAULT_IDS=(F1 F2 F3 F4 F5 F6 F7 F8)
else
    IFS=',' read -r -a FAULT_IDS <<< "$ARG_FAULTS"
fi

TOTAL_MUTANTS=0
for target in "${TARGETS[@]}"; do
    if [ ! -f "$target" ]; then
        log "# mutation-sweep: skipping missing target: $target"
        continue
    fi
    PER_FILE_COUNT=0
    for fid in "${FAULT_IDS[@]}"; do
        # Generate; cap per-file.
        while IFS= read -r line; do
            # The wire format is 4-line records. We re-emit verbatim and
            # tag each record with the target so the consumer doesn't
            # need to track it separately. The TAG line precedes each
            # MUTANT block so the inner parser can pick the target up.
            if [ "$PER_FILE_COUNT" -ge "$MAX_MUTANTS_PER_FILE" ]; then
                break
            fi
            if [ "$TOTAL_MUTANTS" -ge "$MAX_MUTANTS_PER_RUN" ]; then
                break
            fi
            case "$line" in
                MUTANT*) printf 'TARGET %s\n' "$target" >> "$MUTANTS_FILE" ;;
            esac
            printf '%s\n' "$line" >> "$MUTANTS_FILE"
            case "$line" in
                END)
                    PER_FILE_COUNT=$((PER_FILE_COUNT + 1))
                    TOTAL_MUTANTS=$((TOTAL_MUTANTS + 1))
                    ;;
            esac
        done < <(bash "$LIB_DIR/generate.sh" "$target" "$fid")
        if [ "$TOTAL_MUTANTS" -ge "$MAX_MUTANTS_PER_RUN" ]; then
            log "# mutation-sweep: cap MAX_MUTANTS_PER_RUN ($MAX_MUTANTS_PER_RUN) reached; truncating"
            break 2
        fi
    done
done

log "# mutation-sweep: generated $TOTAL_MUTANTS mutant(s) across ${#TARGETS[@]} target(s)"

if [ "$TOTAL_MUTANTS" -eq 0 ]; then
    # Emit empty report and exit successfully — zero mutants is a valid
    # outcome (e.g., a target with no F1/F6/F8 triggers).
    cat > "$OUTPUT_DIR/report.json" <<'JSON'
{"ok":true,"mutants":0,"killed":0,"survived":0,"survivors":[],"cost_model":{"deterministic":"free","judge":"unused"}}
JSON
    printf 'mutation-sweep: zero mutants generated (no triggers in selected targets). Report at %s\n' "$OUTPUT_DIR/report.json"
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 3+4+5: apply mutant in worktree, run tests, classify.
#
# Worktree creation:
#   git worktree add --detach <wt-path> HEAD
# This makes <wt-path> a detached copy of HEAD with its own index. We mutate
# the file in that worktree only; the main checkout is untouched.
#
# Test execution:
#   inside the worktree, run bash <test-cmd> with a per-mutant timeout. The
#   default test-cmd is a curated offline subset (see DEFAULT_TEST_CMD).
#   Tests that fail in the worktree => KILLED. Tests that pass => SURVIVED.
#
# Cleanup:
#   worktree-remove is delegated to the trap above. No mutant gets to leak
#   a worktree, even on SIGINT.

DEFAULT_TEST_CMD="bash .claude/scripts/tests/run-tests.sh"
if [ -n "$ARG_TEST_CMD" ]; then
    TEST_CMD="$ARG_TEST_CMD"
else
    TEST_CMD="$DEFAULT_TEST_CMD"
fi

# Pre-flight: refuse to proceed if not in a git repo (worktrees require one).
if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'mutation-sweep: %s is not a git repo (worktrees require a .git directory)\n' "$PROJECT_DIR" >&2
    exit 3
fi

# We have a portable timeout wrapper to avoid the macOS-vs-Linux split
# (BSD lacks `timeout` by default; macOS users typically have gtimeout
# via coreutils). Fall back to `perl` if neither is present.
timeout_cmd() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}s" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}s" "$@"
    else
        # POSIX-ish perl fallback: spawn child, alarm after secs.
        perl -e '
            my $secs = shift;
            my $pid = fork();
            if (!defined $pid) { die "fork failed: $!"; }
            if ($pid == 0) { exec @ARGV; exit 127; }
            local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 1; kill "KILL", $pid; exit 124; };
            alarm $secs;
            waitpid($pid, 0);
            exit($? >> 8);
        ' "$secs" "$@"
    fi
}

# apply_mutant_to_target <worktree> <target-rel-to-project> <line-no> <orig> <mut>
#   Replace line <line-no> of <target> with <mut> inside <worktree>. We use
#   awk for the in-place rewrite so we don't depend on GNU sed's -i variant.
apply_mutant_to_target() {
    local wt="$1" target_rel="$2" lineno="$3" orig="$4" mut="$5"
    local f="$wt/$target_rel"
    if [ ! -f "$f" ]; then
        return 1
    fi
    local tmp
    tmp=$(mktemp -t mutation-sweep.XXXXXX)
    awk -v ln="$lineno" -v repl="$mut" 'NR==ln{print repl; next} {print}' "$f" > "$tmp"
    # Sanity: the mutant file must DIFFER from the original. If awk emitted
    # a byte-identical copy, the mutant doesn't actually mutate anything
    # (regex mismatch / wire-format desync) and would falsely appear to
    # survive. Refusing to proceed on a no-op mutant keeps the report honest.
    if cmp -s "$tmp" "$f"; then
        rm -f "$tmp"
        return 2
    fi
    mv "$tmp" "$f"
    # Preserve executability — git worktrees preserve mode on checkout but
    # mktemp may emit a 0600 file. Mirror the original's permissions.
    chmod --reference="$f" "$f" 2>/dev/null || chmod +x "$f"
    return 0
}

# Read the wire format and run each mutant.
SURVIVORS_FILE="$OUTPUT_DIR/survivors.jsonl"
KILLED=0
SURVIVED=0
SKIPPED=0
: > "$SURVIVORS_FILE"

# Parse state machine: TARGET <path>, MUTANT <fid> <ln> :<rat>, <orig>, <mut>, END.
CURR_TARGET=""
CURR_FID=""
CURR_LINE=""
CURR_RAT=""
CURR_ORIG=""
CURR_MUT=""
STATE="idle"
MUTANT_IDX=0

run_mutant() {
    local fid="$1" target="$2" lineno="$3" rat="$4" orig="$5" mut="$6"
    MUTANT_IDX=$((MUTANT_IDX + 1))

    # Resolve target relative to PROJECT_DIR so the worktree path matches.
    local target_rel="${target#"$PROJECT_DIR/"}"

    # Make a fresh worktree per mutant. The worktree directory name encodes
    # the run timestamp + mutant index so a SIGINT mid-run leaves a
    # diagnose-able trail (and the trap still prunes it).
    local wt="$WORKTREE_ROOT/m-$RUN_TS-$MUTANT_IDX"
    if ! git -C "$PROJECT_DIR" worktree add --detach "$wt" HEAD >/dev/null 2>&1; then
        log "  ... mutant $MUTANT_IDX [${fid} ${target_rel}:${lineno}] FAILED to create worktree; skipping"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi
    CREATED_WORKTREES+=("$wt")

    # Apply the mutant.
    local apply_rc=0
    apply_mutant_to_target "$wt" "$target_rel" "$lineno" "$orig" "$mut" || apply_rc=$?
    if [ "$apply_rc" -ne 0 ]; then
        log "  ... mutant $MUTANT_IDX [${fid} ${target_rel}:${lineno}] apply rc=$apply_rc; skipping"
        SKIPPED=$((SKIPPED + 1))
        git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
        return 0
    fi

    # Run the test command in the worktree. We export CLAUDE_PROJECT_DIR so
    # any helper that reads it sees the worktree's tree (not the main one).
    local test_rc=0
    (
        cd "$wt" || exit 1
        CLAUDE_PROJECT_DIR="$wt" timeout_cmd "$MUTANT_TEST_TIMEOUT_S" bash -c "$TEST_CMD"
    ) >/dev/null 2>&1 || test_rc=$?

    if [ "$test_rc" -eq 0 ]; then
        # Tests passed -> mutant survived -> RECORD.
        SURVIVED=$((SURVIVED + 1))
        # Emit one JSONL row. We deliberately use printf-quoting rather than
        # jq -n so this works on machines without jq (jq is a hard dep at
        # the suite level but the survivors file is plain JSONL so the
        # report viewer doesn't need to spawn jq per row).
        printf '{"id":%d,"fault":"%s","target":"%s","line":%s,"rationale":"%s","orig":%s,"mut":%s,"status":"SURVIVED"}\n' \
            "$MUTANT_IDX" \
            "$fid" \
            "$(json_escape "$target_rel")" \
            "$lineno" \
            "$(json_escape "$rat")" \
            "$(json_escape_as_string "$orig")" \
            "$(json_escape_as_string "$mut")" \
            >> "$SURVIVORS_FILE"
    else
        KILLED=$((KILLED + 1))
    fi

    git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
}

# Minimal JSON escaping for the survivors JSONL row. Order matters:
# backslash first, then double-quote, then control chars.
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=$(printf '%s' "$s" | tr -d '\r' | tr '\n' ' ' | tr '\t' ' ')
    printf '%s' "$s"
}

# Emit a JSON-quoted string (surrounded by double-quotes). Used for fields
# whose value is itself a JSON string.
json_escape_as_string() {
    printf '"%s"' "$(json_escape "$1")"
}

# Drive the parser.
while IFS= read -r line || [ -n "$line" ]; do
    case "$STATE" in
        idle)
            case "$line" in
                TARGET\ *) CURR_TARGET="${line#TARGET }" ;;
                MUTANT\ *)
                    # Strip leading "MUTANT " then split fid, lineno, rationale.
                    rest="${line#MUTANT }"
                    CURR_FID="${rest%% *}"
                    rest="${rest#* }"
                    CURR_LINE="${rest%% *}"
                    rest="${rest#* }"
                    CURR_RAT="${rest#:}"
                    STATE="orig"
                    ;;
            esac
            ;;
        orig)
            CURR_ORIG="$line"
            STATE="mut"
            ;;
        mut)
            CURR_MUT="$line"
            STATE="end"
            ;;
        end)
            if [ "$line" = "END" ]; then
                run_mutant "$CURR_FID" "$CURR_TARGET" "$CURR_LINE" \
                    "$CURR_RAT" "$CURR_ORIG" "$CURR_MUT"
                STATE="idle"
            fi
            ;;
    esac
done < "$MUTANTS_FILE"

# ---------------------------------------------------------------------------
# Step 6: emit report + cost-confirmation gate.

# Compute estimated judge cost.
# We use bc only if it's on PATH; otherwise integer multiply and divide
# manually (USD * 100 stored as cents to avoid floating point).
estimate_judge_cost_usd() {
    local n="$1"
    if command -v awk >/dev/null 2>&1; then
        awk -v n="$n" -v c="$JUDGE_COST_PER_CALL_USD" 'BEGIN { printf "%.2f", n * c }'
    else
        printf '%.2f' "$((n * 3))" # cheap fallback assuming 0.03 — never trips on tested platforms
    fi
}

JUDGE_COST=$(estimate_judge_cost_usd "$SURVIVED")

# Final summary report (JSON for downstream tooling, human-readable for the
# terminal). The JSON shape is what C.2/C.3 will read.
REPORT_JSON="$OUTPUT_DIR/report.json"
{
    printf '{"ok":true,'
    printf '"run_ts":"%s",' "$RUN_TS"
    printf '"targets":%d,' "${#TARGETS[@]}"
    printf '"mutants":%d,' "$TOTAL_MUTANTS"
    printf '"killed":%d,' "$KILLED"
    printf '"survived":%d,' "$SURVIVED"
    printf '"skipped":%d,' "$SKIPPED"
    printf '"caps":{"per_file":%d,"per_run":%d,"timeout_s":%d},' \
        "$MAX_MUTANTS_PER_FILE" "$MAX_MUTANTS_PER_RUN" "$MUTANT_TEST_TIMEOUT_S"
    printf '"cost_model":{"deterministic_usd":"0.00","judge_estimated_usd":"%s","judge_called":false},' \
        "$JUDGE_COST"
    printf '"survivors_file":"%s",' "$(json_escape "$SURVIVORS_FILE")"
    printf '"survivors":'
    if [ "$SURVIVED" -gt 0 ] && [ -s "$SURVIVORS_FILE" ]; then
        # Wrap JSONL in a JSON array.
        printf '['
        # awk joins JSONL rows with commas.
        awk 'BEGIN{first=1} NF{ if(first) {first=0} else {printf ","}; printf "%s", $0 }' "$SURVIVORS_FILE"
        printf ']'
    else
        printf '[]'
    fi
    printf '}\n'
} > "$REPORT_JSON"

SUMMARY_TXT="$OUTPUT_DIR/summary.txt"
{
    printf 'Mutation sweep summary (run %s)\n' "$RUN_TS"
    printf '  targets:    %d\n' "${#TARGETS[@]}"
    printf '  mutants:    %d\n' "$TOTAL_MUTANTS"
    printf '  killed:     %d\n' "$KILLED"
    printf '  survived:   %d\n' "$SURVIVED"
    printf '  skipped:    %d (apply/worktree failures; not regressions)\n' "$SKIPPED"
    printf '  caps:       per-file=%d per-run=%d timeout=%ds\n' \
        "$MAX_MUTANTS_PER_FILE" "$MAX_MUTANTS_PER_RUN" "$MUTANT_TEST_TIMEOUT_S"
    # shellcheck disable=SC2016  # literal '$0.00' in human-readable summary.
    printf '  deterministic cost:  $0.00 (no paid calls in this phase)\n'
    printf '  judge estimated:     $%s (%d survivors x $%s/call)\n' \
        "$JUDGE_COST" "$SURVIVED" "$JUDGE_COST_PER_CALL_USD"
    printf '\n'
    if [ "$SURVIVED" -gt 0 ]; then
        printf 'Survivors (file:line  fault  rationale)\n'
        # Human-readable survivor list. Prefer jq when available — it's the
        # only dependency-free way to handle escaped quotes in the JSONL.
        if command -v jq >/dev/null 2>&1; then
            jq -r '"  " + .target + ":" + (.line|tostring) + "  " + .fault + "  " + .rationale' \
                "$SURVIVORS_FILE"
        else
            # Fallback: extract named fields with regex anchors. Each
            # ("key":"value") match is captured separately so escaped
            # quotes inside one field don't shift the others.
            awk '
                /SURVIVED/ {
                    fault = ""; target = ""; rat = ""; ln = ""
                    if (match($0, /"fault":"[^"]*"/))
                        fault = substr($0, RSTART+9, RLENGTH-10)
                    if (match($0, /"target":"[^"]*"/))
                        target = substr($0, RSTART+10, RLENGTH-11)
                    if (match($0, /"rationale":"[^"]*"/))
                        rat = substr($0, RSTART+13, RLENGTH-14)
                    if (match($0, /"line":[0-9]+/))
                        ln = substr($0, RSTART+7, RLENGTH-7)
                    printf "  %s:%s  %s  %s\n", target, ln, fault, rat
                }' "$SURVIVORS_FILE"
        fi
    fi
} > "$SUMMARY_TXT"

cat "$SUMMARY_TXT"

# Always emit a stable pointer to the report so the L1 tests and C.2 can
# find it without hunting for the timestamp dir.
echo "$REPORT_JSON" > "$PROJECT_DIR/.claude/.mutation-runs/latest.report.json.path"

# ---------------------------------------------------------------------------
# Cost-confirmation gate + judge seam.
#
# The seam contract:
#
#   - The judge command is invoked as:
#       <judge-cmd> --packet <path-to-packet.json>
#     where packet.json is a single file containing the deterministic
#     report PLUS the per-survivor block (target, line, rationale, orig,
#     mut, and a diff snippet). C.2 (judge subagent) reads the packet
#     from disk, writes its verdict to stdout as JSON conforming to the
#     schema documented in README.md.
#
#   - If --no-judge is set, we exit here with the deterministic report.
#
#   - Otherwise we print the cost gate, and proceed only if the user
#     confirms (or --confirm-judge is set). The user's "n" is treated
#     identically to --no-judge: deterministic report on disk, exit 0.
#
#   - The judge call itself is NOT implemented in C.1. C.1 ships the
#     seam. If --judge-cmd is set AND confirmation passes, we invoke it
#     and capture its stdout as the verdict file. C.2 owns the binary.
#     If --judge-cmd is unset, we print a "judge step ready" message
#     describing how C.2 plugs in, then exit 0.

if [ "$ARG_NO_JUDGE" = "1" ]; then
    log "# mutation-sweep: --no-judge set; skipping cost gate. Report: $REPORT_JSON"
    exit 0
fi

if [ "$SURVIVED" -eq 0 ]; then
    log "# mutation-sweep: 0 survivors; judge step has nothing to filter. Exit 0."
    exit 0
fi

# Cost confirmation. If the survivor count exceeds JUDGE_MAX_CALLS, we
# refuse to even prompt unless the caller raised --max-mutants — the cap
# is a budget guardrail, not a courtesy.
if [ "$SURVIVED" -gt "$JUDGE_MAX_CALLS" ]; then
    printf '\nmutation-sweep: survivors (%d) exceed JUDGE_MAX_CALLS (%d).\n' \
        "$SURVIVED" "$JUDGE_MAX_CALLS" >&2
    printf 'Rerun with --judge-max <N> (in mutation.conf) or --no-judge to skip.\n' >&2
    exit 0
fi

if [ "$ARG_CONFIRM_JUDGE" = "1" ]; then
    reply="y"
else
    printf '\nProceed to judge (%d calls, ~$%s)? (y/N) ' "$SURVIVED" "$JUDGE_COST"
    read -r reply
fi

case "${reply:-N}" in
    y|Y|yes|YES) ;;
    *)
        log "# mutation-sweep: judge step declined. Deterministic report at $REPORT_JSON."
        exit 0
        ;;
esac

# Confirmed. Assemble a packet for the judge.
PACKET_FILE="$OUTPUT_DIR/judge-packet.json"
{
    printf '{"survivors":'
    if [ "$SURVIVED" -gt 0 ] && [ -s "$SURVIVORS_FILE" ]; then
        printf '['
        awk 'BEGIN{first=1} NF{ if(first) {first=0} else {printf ","}; printf "%s", $0 }' "$SURVIVORS_FILE"
        printf ']'
    else
        printf '[]'
    fi
    printf ',"report":"%s"' "$(json_escape "$REPORT_JSON")"
    printf ',"contract_version":"1"'
    printf '}\n'
} > "$PACKET_FILE"

if [ -z "$ARG_JUDGE_CMD" ]; then
    printf '\nmutation-sweep: judge seam ready.\n'
    printf '  packet: %s\n' "$PACKET_FILE"
    printf '  invoke C.2 manually with: <judge-cmd> --packet %s\n' "$PACKET_FILE"
    printf '  contract: see .claude/tests/mutation/README.md (judge seam)\n'
    exit 0
fi

# Invoke the judge seam.
VERDICT_FILE="$OUTPUT_DIR/verdict.json"
log "# mutation-sweep: invoking judge: $ARG_JUDGE_CMD --packet $PACKET_FILE"
if ! "$ARG_JUDGE_CMD" --packet "$PACKET_FILE" > "$VERDICT_FILE"; then
    printf 'mutation-sweep: judge command failed; partial output at %s\n' "$VERDICT_FILE" >&2
    exit 1
fi
printf 'mutation-sweep: judge verdict at %s\n' "$VERDICT_FILE"
exit 0

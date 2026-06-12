#!/bin/bash
# generate.sh — deterministic mutant generator.
#
# Reads a target file and a fault-class id; writes one or more
# mutant patches to stdout in the harness's wire format:
#
#   MUTANT <fault-id> <line-number> <colon-rationale>
#   <verbatim original line>
#   <verbatim mutated line>
#   END
#
# This wire shape is line-oriented and grep-friendly so the harness
# can stream-process it without a JSON parser inside the inner loop.
# Each mutant is one minimal change: exactly one line replaced.
#
# Generation is deterministic (no `$RANDOM`, no `date`-keyed
# ordering): given the same input file and fault id, the output is
# byte-identical across runs. This is the property that makes META
# tests reliable.
#
# Usage:
#   generate.sh <target-file> <fault-id>
#
# Returns 0 on success even when zero mutants are produced (empty
# stdout is a valid "this file has no triggers for this class").
# Returns 1 on invocation error.

set -u

if [ "$#" -lt 2 ]; then
    printf 'Usage: generate.sh <target-file> <fault-id>\n' >&2
    exit 1
fi

TARGET="$1"
FAULT="$2"

if [ ! -f "$TARGET" ]; then
    printf 'generate.sh: target not found: %s\n' "$TARGET" >&2
    exit 1
fi

# Resolve config path. The conf file is shell-sourceable; we read
# SENTINELS and COMMAND_EXCLUSIONS from it.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$SCRIPT_DIR/../mutation.conf"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
SENTINELS="${SENTINELS:-qa-approved qa-pending qa-blocked}"
COMMAND_EXCLUSIONS="${COMMAND_EXCLUSIONS:-rm mv cp curl wget gh}"

# Emit one mutant record. Args: fault-id, line-number, rationale,
# original-line, mutated-line.
emit() {
    local fid="$1" line="$2" rat="$3" orig="$4" mut="$5"
    # Skip no-op mutations (orig == mut).
    if [ "$orig" = "$mut" ]; then
        return 0
    fi
    printf 'MUTANT %s %s :%s\n' "$fid" "$line" "$rat"
    printf '%s\n' "$orig"
    printf '%s\n' "$mut"
    printf 'END\n'
}

# Skip comments, blank lines, and lines whose first token is in
# COMMAND_EXCLUSIONS. Returns 0 (skip) or 1 (proceed).
should_skip() {
    local line="$1"
    case "$line" in
        \#*|"") return 0 ;;
    esac
    local first
    first=$(printf '%s' "$line" | awk '{print $1}' | tr -d '\t ')
    local ex
    for ex in $COMMAND_EXCLUSIONS; do
        if [ "$first" = "$ex" ]; then
            return 0
        fi
    done
    return 1
}

# F1 — condition negation.
# Flip `= -> !=`, `!= -> =`, `-eq -> -ne`, `-ne -> -eq`, etc.
gen_f1() {
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        should_skip "$line" && continue
        # Only mutate lines that look like a test (have `[ ` or `test `).
        case "$line" in
            *"[ "*|*"test "*) ;;
            *) continue ;;
        esac
        local mut="$line"
        # Try operators in priority order. Stop after the first
        # successful substitution so each mutant is one minimal change.
        local before="$line"
        # Long forms first so `-eq` does not interfere with `==`.
        for pair in '-eq:-ne' '-ne:-eq' '-lt:-ge' '-gt:-le' '-le:-gt' '-ge:-lt' '!=:=' '==:!=' '=:!='; do
            local from to
            from=$(printf '%s' "$pair" | cut -d: -f1)
            to=$(printf '%s' "$pair" | cut -d: -f2)
            # Match the operator with whitespace boundaries so `==` does
            # not collide with `=` and `local x=1` does not match.
            if printf '%s' "$line" | grep -q -E "[[:space:]]${from}[[:space:]]"; then
                mut=$(printf '%s' "$line" | sed "s| ${from} | ${to} |")
                if [ "$mut" != "$before" ]; then
                    emit F1 "$lineno" "negate comparison ${from} -> ${to}" "$line" "$mut"
                    break
                fi
            fi
        done
    done < "$TARGET"
}

# F2 — guard deletion. Comment out a line that looks like an early-exit
# guard (stop_hook_active, qa-approved, etc.). Each mutated line is
# left in place but prefixed with `# MUTATED:` so the diff is visible.
gen_f2() {
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # should_skip() covers comments, blank lines, and lines whose
        # first token is in COMMAND_EXCLUSIONS — uniform with F1/F3/F6
        # so a destructive `rm`/`mv`/`curl` prefix can never produce a
        # mutant, even when the line also matches the F2 trigger
        # pattern (e.g., `rm -rf qa-approved/ && exit 0`).
        should_skip "$line" && continue
        # Triggers: lines with stop_hook_active, qa-approved label
        # check, or an early `&& exit` / `&& return` guard.
        case "$line" in
            *stop_hook_active*|*qa-approved*|*qa-deferred*) ;;
            *) continue ;;
        esac
        case "$line" in
            *"exit "*|*"return "*|*"return"*|*"continue"*) ;;
            *) continue ;;
        esac
        local mut="# MUTATED-F2: $line"
        emit F2 "$lineno" "delete guard (comment out early-exit on label/state)" "$line" "$mut"
    done < "$TARGET"
}

# F3 — exit-code swallowing. Append ` || true` to known-interesting
# command lines.
gen_f3() {
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        should_skip "$line" && continue
        case "$line" in
            *"|| true"*|*"|| return"*) continue ;;
        esac
        local first
        first=$(printf '%s' "$line" | awk '{print $1}' | tr -d '\t ')
        # Only mutate lines whose first token is a known interesting
        # command. This keeps the candidate set small and the rationale
        # explicit.
        case "$first" in
            bd|git|jq|awk|sed|grep|printf) ;;
            *) continue ;;
        esac
        # Skip lines already ending in a redirect or pipe (mutating
        # them is ambiguous).
        case "$line" in
            *"|"*|*">"*|*"<"*) continue ;;
        esac
        local mut="$line || true"
        emit F3 "$lineno" "swallow exit code (append || true)" "$line" "$mut"
    done < "$TARGET"
}

# F4 — variable-default removal. `${X:-foo}` -> `$X`.
gen_f4() {
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # should_skip() covers comments, blank lines, and the
        # COMMAND_EXCLUSIONS set — uniform with F1/F3/F6.
        should_skip "$line" && continue
        if ! printf '%s' "$line" | grep -q -E '\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\}'; then
            continue
        fi
        # Strip the default of the first occurrence on the line.
        local mut
        mut=$(printf '%s' "$line" | sed -E 's/\$\{([A-Za-z_][A-Za-z0-9_]*):-[^}]*\}/${\1}/')
        emit F4 "$lineno" "remove variable default (\${X:-foo} -> \${X})" "$line" "$mut"
    done < "$TARGET"
}

# F5 — pipeline-segment drop. Drop the middle segment of a 3+ pipeline.
gen_f5() {
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # should_skip() covers comments, blank lines, and the
        # COMMAND_EXCLUSIONS set — uniform with F1/F3/F6.
        should_skip "$line" && continue
        # Count `|` occurrences (rough proxy for pipeline length).
        local pipes
        pipes=$(printf '%s' "$line" | awk -F'|' '{print NF-1}')
        if [ "$pipes" -lt 2 ]; then
            continue
        fi
        # Skip `||` (logical or) — we only want pipeline pipes.
        if printf '%s' "$line" | grep -q '||'; then
            continue
        fi
        # Drop the middle segment via awk.
        local mut
        mut=$(printf '%s' "$line" | awk -F' \\| ' '{
            if (NF >= 3) {
                out = $1;
                for (i = 3; i <= NF; i++) out = out " | " $i;
                print out;
            } else {
                print $0;
            }
        }')
        emit F5 "$lineno" "drop middle pipeline segment" "$line" "$mut"
    done < "$TARGET"
}

# F6 — comparison-operator flip (off-by-one).
gen_f6() {
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        should_skip "$line" && continue
        case "$line" in
            *"[ "*|*"test "*) ;;
            *) continue ;;
        esac
        local mut="$line"
        local before="$line"
        for pair in '-gt:-ge' '-ge:-gt' '-lt:-le' '-le:-lt'; do
            local from to
            from=$(printf '%s' "$pair" | cut -d: -f1)
            to=$(printf '%s' "$pair" | cut -d: -f2)
            if printf '%s' "$line" | grep -q -E "[[:space:]]${from}[[:space:]]"; then
                mut=$(printf '%s' "$line" | sed "s| ${from} | ${to} |")
                if [ "$mut" != "$before" ]; then
                    emit F6 "$lineno" "off-by-one ${from} -> ${to}" "$line" "$mut"
                    break
                fi
            fi
        done
    done < "$TARGET"
}

# F7 — string-literal mutation of sentinel names.
gen_f7() {
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # should_skip() covers comments, blank lines, and the
        # COMMAND_EXCLUSIONS set — uniform with F1/F3/F6. This stops
        # destructive lines that happen to mention a sentinel string
        # (e.g., `rm -rf qa-approved.lock`) from producing a mutant.
        should_skip "$line" && continue
        local s
        for s in $SENTINELS; do
            if printf '%s' "$line" | grep -qF "$s"; then
                # Build a neighbour: drop the last character.
                local len=${#s}
                if [ "$len" -lt 4 ]; then continue; fi
                local neighbour="${s%?}"
                # Replace only the first occurrence per line. The
                # mutant is one-character-different from the sentinel,
                # so the rationale call-out is the diff itself.
                local mut
                mut=$(printf '%s' "$line" | sed "s|$s|$neighbour|")
                emit F7 "$lineno" "sentinel '$s' -> '$neighbour' (typo)" "$line" "$mut"
                break
            fi
        done
    done < "$TARGET"
}

# F8 — arithmetic off-by-one (` + 1 -> + 2`, ` - 1 -> + 1`).
gen_f8() {
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # should_skip() covers comments, blank lines, and the
        # COMMAND_EXCLUSIONS set — uniform with F1/F3/F6.
        should_skip "$line" && continue
        # Trigger only when arithmetic expansion appears. We grep for the
        # `$((...))` shape on the line; literal `$(` inside the case glob
        # is the trigger token (no expansion intended).
        # shellcheck disable=SC2016  # `$(` in glob is intentional pattern.
        case "$line" in
            *'$(('*'+ 1'*'))'*|*'$(('*'- 1'*'))'*) ;;
            *) continue ;;
        esac
        local mut
        if printf '%s' "$line" | grep -q '+ 1'; then
            mut=$(printf '%s' "$line" | sed 's|+ 1|+ 2|')
            emit F8 "$lineno" "increment + 1 -> + 2" "$line" "$mut"
        elif printf '%s' "$line" | grep -q '\- 1'; then
            mut=$(printf '%s' "$line" | sed 's|- 1|+ 1|')
            emit F8 "$lineno" "decrement - 1 -> + 1 (sign flip)" "$line" "$mut"
        fi
    done < "$TARGET"
}

case "$FAULT" in
    F1) gen_f1 ;;
    F2) gen_f2 ;;
    F3) gen_f3 ;;
    F4) gen_f4 ;;
    F5) gen_f5 ;;
    F6) gen_f6 ;;
    F7) gen_f7 ;;
    F8) gen_f8 ;;
    ALL)
        gen_f1
        gen_f2
        gen_f3
        gen_f4
        gen_f5
        gen_f6
        gen_f7
        gen_f8
        ;;
    *)
        printf 'generate.sh: unknown fault id: %s\n' "$FAULT" >&2
        exit 1
        ;;
esac

exit 0

#!/bin/bash
# sha256-escape-decode.test.sh — L1 fixture for the ONE invariant shared by the
# three shipped sha256 helpers that pass a PATH to the hashing tool
# (claude-workflow-plugin-18fc).
#
# THE INVARIANT. A file's digest does not depend on how its path is SPELLED.
# FIVE helpers broke it:
#
#   workflow-manifest.sh  hash_file      (sha256sum / shasum / openssl chain)
#   qa-gate.sh            sha256_file    (shasum / sha256sum)
#   beads-ledger.sh       sha256_file    (shasum / sha256sum)
#   install.sh            mcp_sha256_of  (sha256sum / shasum / openssl chain)
#   uninstall.sh          hash_of        (sha256sum / shasum / openssl chain)
#
# 18fc filed the first three. The last two were found while implementing it:
# the filed census grepped .claude/scripts, and install.sh / uninstall.sh are
# at the repo root. Both carry the identical `${raw%% *}` idiom and both are
# length-guarded, so like helper 1 they fail CLOSED — a correct digest is
# REFUSED and the caller degrades (npm ci re-runs; an unverifiable file is left
# on disk) rather than binding a wrong value.
#
# GNU coreutils and perl's Digest::SHA ESCAPE their output line when the
# filename contains a backslash or a newline (coreutils also for a carriage
# return): the LINE is prefixed with ONE backslash and the problematic bytes
# inside the NAME are escaped. coreutils manual, "cksum output modes" — "the
# line is started with a backslash, and each problematic character in the file
# name is escaped with a backslash ... any other backslash escape sequences are
# reserved for future use". Field 1 therefore reads `\<64 hex>` = 65 chars.
# hash_file is length-guarded and so REFUSED a correct digest (that is
# design-artifact.test.sh 9.2, red on Linux at 157e6f4); the other two are
# guarded only for emptiness/rc and EMITTED the 65-char value as if it were a
# digest.
#
# WHY A DEDICATED SPEC. The defect is one property of three scripts. Splitting
# it across workflow-manifest.test.sh / beads-ledger.test.sh / qa-gate-*.test.sh
# would give three specs that each pass while the invariant they jointly assert
# is not stated anywhere, and the next helper added to the family would inherit
# no check at all. Section 5 asserts the family membership itself.
#
# PAIRING (.claude/tests/README.md, "The pairing requirement"), all four parts:
#   1 NON-VACUITY  — section 4 strips the decode from a COPY of each shipped
#                    script and proves the strip landed: an exact expected hit
#                    count (awk exits 7 otherwise), a byte-difference against
#                    the shipped file, and `bash -n` on the result.
#   2 SPECIFIC MISBEHAVIOUR — each mutant is asserted to fail in the way the
#                    decode prevents, naming the consumer check that goes red.
#   3 RESTORE CONTROL — section 2 is the same inputs through the shipped
#                    artifacts, and 4.6/4.8a-b pin that mutant and shipped
#                    still AGREE on an unescaped path, so the mutant's failure
#                    cannot be a harness artefact.
#   4 EXECUTION    — section 2's helper-1 legs run the SHIPPED
#                    workflow-manifest.sh as a process (`hash-file <path>`),
#                    and section 4 runs the MUTANT of it the same way.
#                    Helpers 2-5 are function-level: their definitions are
#                    extracted VERBATIM from the shipped scripts by sed (the
#                    doc-only-classifier.test.sh pattern), never re-typed, so
#                    they cannot drift from what ships — but they are not
#                    driven through a subcommand. Stated rather than implied,
#                    because it is the weaker half: qa-gate.sh's sha256_file
#                    needs a completion payload whose PATH it derives from a
#                    task id; beads-ledger.sh's needs a fixture Beads store
#                    plus a resolved ledger path; install.sh's and
#                    uninstall.sh's need a full install/uninstall against a
#                    newline-named target tree. None can be handed such a path
#                    from outside without building a second harness, and the
#                    tier already has specs that drive those scripts
#                    end-to-end for other reasons (installer-flags,
#                    mcp-deps, packaging-parity, workflow-manifest,
#                    beads-ledger). Leg 4 is carried by helper 1 for the
#                    family.
#
# HOST HONESTY. Apple's /sbin/sha256sum ("sha256sum (Darwin) 1.0") does NOT
# escape, which is the only reason macOS ever passed. Section 1 MEASURES which
# of this host's tools escape rather than assuming a platform, and every leg
# that needs an escaping tool is SKIPPED BY NAME when the host has none — a leg
# that cannot fail is worse than an absent one (design-artifact.test.sh 1.4's
# rule, applied to the tool instead of to the user).
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
SKIPPED=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
WM="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
QG="$PROJECT_DIR/.claude/scripts/qa-gate.sh"
BL="$PROJECT_DIR/.claude/scripts/beads-ledger.sh"
IN="$PROJECT_DIR/install.sh"
UN="$PROJECT_DIR/uninstall.sh"

for s in "$WM" "$QG" "$BL" "$IN" "$UN"; do
    if [ ! -f "$s" ]; then
        printf 'sha256-escape-decode.test: script under test missing: %s\n' "$s" >&2
        exit 2
    fi
done

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}
assert_ne() {
    local name="$1" unexpected="$2" actual="$3"
    if [ "$unexpected" != "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected anything BUT: %s\n' "$name" "$unexpected"
    fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name" ;;
        *) FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
           printf '  FAIL: %s\n    expected to contain: %s\n    actual:   %s\n' \
               "$name" "$needle" "$(printf '%s' "$hay" | tr '\n' '~' | cut -c1-200)" ;;
    esac
}
skip() { SKIPPED=$((SKIPPED + 1)); printf '  SKIP: %s\n' "$1"; }

# Predicates live at top level, never inline in a command substitution: inside
# "$( ... )" bash ends the substitution at the first unbalanced `)`, and a
# `case` arm's pattern terminator is exactly that. Written inline, every one of
# these silently truncated and the assertion compared against the REMAINDER of
# its own source text.
# All four are predicates; `yn` runs one by NAME (`yn contains_newline "$p"`),
# which is a dispatch shellcheck cannot follow — hence SC2329 on the three that
# have no direct call site as well. starts_with_backslash is exempt only
# because tool_escapes happens to call it directly; the reachability is the
# same for all four.
starts_with_backslash() { case "$1" in \\*) return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2329  # invoked by name through yn(), e.g. `yn contains_backslash "$P_BS"`.
contains_backslash()    { case "$1" in *\\*) return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2329  # invoked by name through yn(), e.g. `yn contains_newline "$P_NL"`.
contains_newline()      { case "$1" in *"$NL"*) return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2329  # invoked by name through yn(), e.g. `yn is_64_lower_hex "$TRUTH"`.
is_64_lower_hex() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in *[!0-9a-f]*) return 1 ;; *) return 0 ;; esac
}
yn() { if "$@"; then echo yes; else echo no; fi; }

WORK=$(mktemp -d -t sha256-escape-decode.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { chmod 644 "$WORK/unreadable.md" 2>/dev/null || true; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 0. FIXTURES — three paths, IDENTICAL bytes, three spellings
# ---------------------------------------------------------------------------
# `$(printf '\n')` is the EMPTY STRING: command substitution strips trailing
# newlines, so the obvious spelling silently builds a fixture with no newline
# in it at all and every assertion below would pass over the wrong file. This
# is the same byte-eating that design-artifact.test.sh 9.2 exists for, and it
# bit the probe that produced 18fc's own evidence, so the fixture proves itself.
NL=$(printf 'x\nx'); NL=${NL#x}; NL=${NL%x}
BYTES='identical-bytes-under-three-spellings'
P_PLAIN="$WORK/plain.md"
P_NL="$WORK/with${NL}newline.md"
P_BS="$WORK/with\\backslash.md"
printf '%s\n' "$BYTES" > "$P_PLAIN"
printf '%s\n' "$BYTES" > "$P_NL"
printf '%s\n' "$BYTES" > "$P_BS"
P_ABSENT="$WORK/no-such-file.md"
printf '%s\n' "$BYTES" > "$WORK/unreadable.md"
chmod 000 "$WORK/unreadable.md" 2>/dev/null || true

printf '=== 0. fixture self-check ===\n'
assert_eq "0.1 the newline fixture's NAME really carries a newline byte" "yes" \
    "$(yn contains_newline "$P_NL")"
assert_eq "0.2 the backslash fixture's NAME really carries a backslash byte" "yes" \
    "$(yn contains_backslash "$P_BS")"
assert_eq "0.2a ...and the PLAIN one carries neither, so it is a real control" "no-no" \
    "$(printf '%s-%s' "$(yn contains_newline "$P_PLAIN")" "$(yn contains_backslash "$P_PLAIN")")"
assert_eq "0.3 all three spellings exist on disk as regular files" "3" \
    "$(n=0; for p in "$P_PLAIN" "$P_NL" "$P_BS"; do [ -f "$p" ] && n=$((n+1)); done; echo "$n")"
assert_eq "0.4 all three hold byte-identical content" "same" \
    "$(if cmp -s "$P_PLAIN" "$P_NL" && cmp -s "$P_PLAIN" "$P_BS"; then echo same; else echo differ; fi)"

# TRUTH comes from STDIN, where no filename can appear in the output and so no
# escaping is possible. It is the value every helper must return for all three
# spellings.
TRUTH=$(printf '%s\n' "$BYTES" | { shasum -a 256 2>/dev/null || sha256sum; } 2>/dev/null | awk '{print $1}')
assert_eq "0.5 the stdin TRUTH digest is 64 lowercase hex" "yes" \
    "$(yn is_64_lower_hex "$TRUTH")"

# ---------------------------------------------------------------------------
# 1. HOST PROBE — which of this host's tools actually escape
# ---------------------------------------------------------------------------
# Measured, never assumed: the same probe that produced 18fc's 2x2. A tool
# "escapes" iff its output line for the newline-named fixture starts with a
# backslash.
printf '\n=== 1. host probe (measured, not assumed) ===\n'
tool_line() {
    case "$1" in
        sha256sum) sha256sum "$2" 2>/dev/null ;;
        shasum)    shasum -a 256 "$2" 2>/dev/null ;;
    esac
}
tool_escapes() {
    local raw; raw=$(tool_line "$1" "$P_NL")
    starts_with_backslash "$raw"
}
SHA256SUM_ESCAPES=no; SHASUM_ESCAPES=no
command -v sha256sum >/dev/null 2>&1 && tool_escapes sha256sum && SHA256SUM_ESCAPES=yes
command -v shasum    >/dev/null 2>&1 && tool_escapes shasum    && SHASUM_ESCAPES=yes
printf '  host: %s | sha256sum=%s escapes=%s | shasum=%s escapes=%s\n' \
    "$(uname -s)" "$(command -v sha256sum || echo none)" "$SHA256SUM_ESCAPES" \
    "$(command -v shasum || echo none)" "$SHASUM_ESCAPES"

# The escape is what makes field 1 65 chars. Assert that relationship directly
# on whichever tool escapes here, so a host whose tools stopped escaping cannot
# make the rest of this file pass for the wrong reason.
ESCAPING_TOOL=""
[ "$SHASUM_ESCAPES" = yes ] && ESCAPING_TOOL="shasum"
[ -z "$ESCAPING_TOOL" ] && [ "$SHA256SUM_ESCAPES" = yes ] && ESCAPING_TOOL="sha256sum"
if [ -n "$ESCAPING_TOOL" ]; then
    RAW_NL=$(tool_line "$ESCAPING_TOOL" "$P_NL")
    RAW_BS=$(tool_line "$ESCAPING_TOOL" "$P_BS")
    RAW_PL=$(tool_line "$ESCAPING_TOOL" "$P_PLAIN")
    assert_eq "1.1 the escaped line for a NEWLINE name has 65-char field 1 ($ESCAPING_TOOL)" \
        "65" "$(f=${RAW_NL%% *}; echo "${#f}")"
    assert_eq "1.2 the escaped line for a BACKSLASH name has 65-char field 1 ($ESCAPING_TOOL)" \
        "65" "$(f=${RAW_BS%% *}; echo "${#f}")"
    assert_eq "1.3 the marker is exactly ONE leading backslash, not one per escaped byte" "1" \
        "$(r="$RAW_NL"; n=0; while [ "${r#\\}" != "$r" ]; do n=$((n+1)); r="${r#\\}"; done; echo "$n")"
    assert_eq "1.4 an UNESCAPED line has no marker, so the decode is a no-op there" "64" \
        "$(f=${RAW_PL%% *}; echo "${#f}")"
    assert_eq "1.5 stripping the marker recovers the TRUE digest (the format claim itself)" \
        "$TRUTH" "$(f=${RAW_NL%% *}; echo "${f#\\}")"
else
    skip "1.1-1.5 escape-format legs: NO tool on this host escapes (sha256sum=$SHA256SUM_ESCAPES shasum=$SHASUM_ESCAPES), so there is nothing to decode here"
fi

# workflow-manifest.sh prefers sha256sum. Where that binary does NOT escape
# (Apple's /sbin/sha256sum), its first arm can never reach the decode, so the
# leg would pass vacuously. Shim an ESCAPING tool into first place — the
# escaped bytes still come from a real implementation on this host, never
# re-typed here. This is the qa-gate-pipefail.test.sh shim pattern.
mkdir -p "$WORK/bin"
WM_ENV_PATH="$PATH"
WM_ARM_NOTE="host sha256sum (escapes=$SHA256SUM_ESCAPES), unshimmed"
if [ "$SHA256SUM_ESCAPES" = no ] && [ "$SHASUM_ESCAPES" = yes ]; then
    REAL_SHASUM=$(command -v shasum)
    { printf '#!/bin/bash\n'; printf 'exec %s -a 256 "$@"\n' "$REAL_SHASUM"; } > "$WORK/bin/sha256sum"
    chmod +x "$WORK/bin/sha256sum"
    WM_ENV_PATH="$WORK/bin:$PATH"
    WM_ARM_NOTE="sha256sum arm shimmed to the real $REAL_SHASUM (host sha256sum does not escape)"
fi
printf '  helper-1 arm under test: %s\n' "$WM_ARM_NOTE"

# ---------------------------------------------------------------------------
# 2. POSITIVE — the three SHIPPED helpers agree across all three spellings
# ---------------------------------------------------------------------------
# Helper 1 runs as a PROCESS (the execution leg). Helpers 2 and 3 are extracted
# verbatim and driven as functions.
# extract_fn <src-script> <dst> <fn-name> — pull ONE function's definition
# verbatim, plus the two bits of surrounding state its callers set up:
# qa-gate.sh's sentinel constant, and uninstall.sh's HASH_TOOL resolver (whose
# result hash_of switches on, so extracting hash_of alone yields a function
# that always takes the `*)` arm and returns empty).
extract_fn() {
    local src="$1" dst="$2" fn="${3:-sha256_file}"
    : > "$dst"
    grep -m1 '^CHANGE_SET_HASH_UNAVAILABLE=' "$src" >> "$dst" 2>/dev/null || true
    if [ "$fn" = "hash_of" ]; then
        printf 'HASH_TOOL=""\n' >> "$dst"
        sed -n '/^resolve_hash_tool() {$/,/^}$/p' "$src" >> "$dst"
        grep -q '^resolve_hash_tool() {$' "$dst" || return 1
    fi
    sed -n "/^$fn() {\$/,/^}\$/p" "$src" >> "$dst"
    [ -s "$dst" ] || return 1
    grep -q "^$fn() {\$" "$dst" || return 1
    bash -n "$dst" 2>/dev/null || return 1
}
call_wm()  { env PATH="$WM_ENV_PATH" bash "$WM" hash-file "$1" 2>&1; }
# <fn-file> <path> [entry-fn]. PATH carries the escaping-tool shim so a helper
# that prefers sha256sum reaches its decode on a host whose sha256sum does not
# escape; helpers that prefer shasum are unaffected by it.
call_fn() {
    ( PATH="$WM_ENV_PATH"
      # shellcheck disable=SC1090  # runtime extraction output, not constant
      . "$1"
      case "${3:-sha256_file}" in
          hash_of) resolve_hash_tool; hash_of "$2" ;;
          mcp_sha256_of) mcp_sha256_of "$2" ;;
          *) sha256_file "$2" ;;
      esac )
}

printf '\n=== 2. POSITIVE: shipped helpers, three spellings, one digest ===\n'
extract_fn "$QG" "$WORK/qg-fn.sh"
assert_eq "2.0a qa-gate.sh sha256_file extracted verbatim and parses" "0" "$?"
extract_fn "$BL" "$WORK/bl-fn.sh"
assert_eq "2.0b beads-ledger.sh sha256_file extracted verbatim and parses" "0" "$?"
extract_fn "$IN" "$WORK/in-fn.sh" mcp_sha256_of
assert_eq "2.0c install.sh mcp_sha256_of extracted verbatim and parses" "0" "$?"
extract_fn "$UN" "$WORK/un-fn.sh" hash_of
assert_eq "2.0d uninstall.sh hash_of (+ resolve_hash_tool) extracted verbatim and parses" "0" "$?"

assert_eq "2.1 helper1 workflow-manifest.sh hash-file: PLAIN path" "$TRUTH" "$(call_wm "$P_PLAIN")"
assert_eq "2.2 helper1 workflow-manifest.sh hash-file: NEWLINE-named path" "$TRUTH" "$(call_wm "$P_NL")"
assert_eq "2.3 helper1 workflow-manifest.sh hash-file: BACKSLASH-named path" "$TRUTH" "$(call_wm "$P_BS")"
assert_eq "2.4 helper2 qa-gate.sh sha256_file: PLAIN path" "$TRUTH" "$(call_fn "$WORK/qg-fn.sh" "$P_PLAIN")"
assert_eq "2.5 helper2 qa-gate.sh sha256_file: NEWLINE-named path" "$TRUTH" "$(call_fn "$WORK/qg-fn.sh" "$P_NL")"
assert_eq "2.6 helper2 qa-gate.sh sha256_file: BACKSLASH-named path" "$TRUTH" "$(call_fn "$WORK/qg-fn.sh" "$P_BS")"
assert_eq "2.7 helper3 beads-ledger.sh sha256_file: PLAIN path" "$TRUTH" "$(call_fn "$WORK/bl-fn.sh" "$P_PLAIN")"
assert_eq "2.8 helper3 beads-ledger.sh sha256_file: NEWLINE-named path" "$TRUTH" "$(call_fn "$WORK/bl-fn.sh" "$P_NL")"
assert_eq "2.9 helper3 beads-ledger.sh sha256_file: BACKSLASH-named path" "$TRUTH" "$(call_fn "$WORK/bl-fn.sh" "$P_BS")"
# Helpers 4 and 5 are OUTSIDE .claude/scripts and were not in 18fc's filed
# census, which searched that directory only. Same idiom, same exposure, both
# fail-CLOSED like helper 1: a refused digest degrades (npm ci re-runs; an
# unverifiable file is left on disk) rather than corrupting anything.
assert_eq "2.12 helper4 install.sh mcp_sha256_of: PLAIN path" "$TRUTH" "$(call_fn "$WORK/in-fn.sh" "$P_PLAIN" mcp_sha256_of)"
assert_eq "2.13 helper4 install.sh mcp_sha256_of: NEWLINE-named path" "$TRUTH" "$(call_fn "$WORK/in-fn.sh" "$P_NL" mcp_sha256_of)"
assert_eq "2.14 helper4 install.sh mcp_sha256_of: BACKSLASH-named path" "$TRUTH" "$(call_fn "$WORK/in-fn.sh" "$P_BS" mcp_sha256_of)"
assert_eq "2.15 helper5 uninstall.sh hash_of: PLAIN path" "$TRUTH" "$(call_fn "$WORK/un-fn.sh" "$P_PLAIN" hash_of)"
assert_eq "2.16 helper5 uninstall.sh hash_of: NEWLINE-named path" "$TRUTH" "$(call_fn "$WORK/un-fn.sh" "$P_NL" hash_of)"
assert_eq "2.17 helper5 uninstall.sh hash_of: BACKSLASH-named path" "$TRUTH" "$(call_fn "$WORK/un-fn.sh" "$P_BS" hash_of)"

# openssl is the third arm of helper 1's chain and is NOT escape-affected: it
# prints the name RAW, so its output for a newline-named file SPANS LINES and
# the existing `${raw##* }` (last field) already lands on the hash. Pinned
# here because "we checked and it does not need decoding" is a claim, and an
# unchecked claim about a shipped arm is how the next person adds a decode
# there and breaks it.
if command -v openssl >/dev/null 2>&1; then
    OSSL_NL=$(openssl dgst -sha256 "$P_NL" 2>/dev/null)
    assert_eq "2.10 openssl does NOT escape: its line for a newline name is not marked" "no" \
        "$(yn starts_with_backslash "$OSSL_NL")"
    assert_eq "2.10a ...it prints the name RAW instead, so its output SPANS 2 lines here" "2" \
        "$(printf '%s\n' "$OSSL_NL" | wc -l | tr -d ' ')"
    assert_eq "2.11 openssl's LAST field is the true digest even across the split lines" \
        "$TRUTH" "${OSSL_NL##* }"
else
    skip "2.10-2.11 openssl legs: openssl is not on this host's PATH"
fi

# ---------------------------------------------------------------------------
# 3. NEGATIVE CONTROL — a real failure is still a failure
# ---------------------------------------------------------------------------
# The decode must not convert a refusal into a digest. Each helper keeps its
# OWN failure shape, which differ on purpose and are asserted as they are:
#   helper 1 dies (rc 1, naming the reason)
#   helper 2 returns rc 1 with no output (i8cx)
#   helper 3 returns rc 0 with EMPTY output (its documented contract)
printf '\n=== 3. NEGATIVE CONTROL: absent / unreadable still refuse ===\n'
WM_ABS=$(call_wm "$P_ABSENT"); WM_ABS_RC=$?
assert_eq "3.1 helper1 REFUSES an absent path (rc 1)" "1" "$WM_ABS_RC"
assert_contains "3.1a ...naming absence, not emitting a digest" "no such file" "$WM_ABS"
assert_ne "3.1b ...and the zero-byte constant never leaks out as the answer" "$TRUTH" "$WM_ABS"

QG_ABS=$(call_fn "$WORK/qg-fn.sh" "$P_ABSENT" 2>/dev/null); QG_ABS_RC=$?
assert_eq "3.2 helper2 returns NON-ZERO for an absent path (i8cx contract kept)" "1" "$QG_ABS_RC"
assert_eq "3.2a ...and emits nothing" "" "$QG_ABS"

BL_ABS=$(call_fn "$WORK/bl-fn.sh" "$P_ABSENT" 2>/dev/null); BL_ABS_RC=$?
assert_eq "3.3 helper3 keeps its rc-0/empty contract for an absent path" "0" "$BL_ABS_RC"
assert_eq "3.3a ...and emits the empty string, never a digest" "" "$BL_ABS"

IN_ABS=$(call_fn "$WORK/in-fn.sh" "$P_ABSENT" mcp_sha256_of 2>/dev/null); IN_ABS_RC=$?
assert_eq "3.3b helper4 emits nothing for an absent path (its documented 'cannot prove current')" "" "$IN_ABS"
assert_eq "3.3c ...at its documented rc 0" "0" "$IN_ABS_RC"
UN_ABS=$(call_fn "$WORK/un-fn.sh" "$P_ABSENT" hash_of 2>/dev/null); UN_ABS_RC=$?
assert_eq "3.3d helper5 emits nothing for an absent path (its documented 'leave it alone')" "" "$UN_ABS"
assert_eq "3.3e ...at its documented rc 0" "0" "$UN_ABS_RC"

if [ -r "$WORK/unreadable.md" ]; then
    skip "3.4-3.6 unreadable-path refusals (this user can read a chmod-000 file; likely root)"
else
    WM_UNR=$(call_wm "$WORK/unreadable.md"); WM_UNR_RC=$?
    assert_eq "3.4 helper1 REFUSES an unreadable path (rc 1)" "1" "$WM_UNR_RC"
    assert_contains "3.4a ...naming unreadability" "not readable" "$WM_UNR"
    QG_UNR=$(call_fn "$WORK/qg-fn.sh" "$WORK/unreadable.md" 2>/dev/null); QG_UNR_RC=$?
    assert_eq "3.5 helper2 returns NON-ZERO for an unreadable path" "1" "$QG_UNR_RC"
    assert_eq "3.5a ...and emits nothing" "" "$QG_UNR"
    BL_UNR=$(call_fn "$WORK/bl-fn.sh" "$WORK/unreadable.md" 2>/dev/null); BL_UNR_RC=$?
    assert_eq "3.6 helper3 emits the empty string for an unreadable path" "" "$BL_UNR"
    assert_eq "3.6a ...at its documented rc 0" "0" "$BL_UNR_RC"
fi

# ---------------------------------------------------------------------------
# 4. MUTATION — strip the decode, prove the strip landed, drive the mutant
# ---------------------------------------------------------------------------
# Every decode site carries the marker `SHA256-ESCAPE-DECODE`. Removing those
# lines is exactly the pre-18fc code, so the mutant reproduces the shipped
# defect rather than approximating it.
printf '\n=== 4. MUTATION: remove the decode and the defect returns ===\n'
mutate() {  # <src> <dst> <expected-hits> ; rc 0 iff exactly that many landed
    local src="$1" dst="$2" want="$3"
    awk -v want="$want" '
        /SHA256-ESCAPE-DECODE/ { hit++; next }
        { print }
        END { if (want < 1 || hit != want) exit 7 }
    ' "$src" > "$dst"
}
MUT_WM="$WORK/mut-workflow-manifest.sh"
MUT_QG="$WORK/mut-qa-gate.sh"
MUT_BL="$WORK/mut-beads-ledger.sh"
MUT_IN="$WORK/mut-install.sh"
MUT_UN="$WORK/mut-uninstall.sh"
mutate "$WM" "$MUT_WM" 2; MUT_WM_RC=$?
mutate "$QG" "$MUT_QG" 1; MUT_QG_RC=$?
mutate "$BL" "$MUT_BL" 1; MUT_BL_RC=$?
mutate "$IN" "$MUT_IN" 2; MUT_IN_RC=$?
mutate "$UN" "$MUT_UN" 2; MUT_UN_RC=$?

assert_eq "4.0a NON-VACUITY: the strip landed on workflow-manifest.sh, exactly 2 sites" "0" "$MUT_WM_RC"
assert_eq "4.0b NON-VACUITY: the strip landed on qa-gate.sh, exactly 1 site" "0" "$MUT_QG_RC"
assert_eq "4.0c NON-VACUITY: the strip landed on beads-ledger.sh, exactly 1 site" "0" "$MUT_BL_RC"
assert_eq "4.0c1 NON-VACUITY: the strip landed on install.sh, exactly 2 sites" "0" "$MUT_IN_RC"
assert_eq "4.0c2 NON-VACUITY: the strip landed on uninstall.sh, exactly 2 sites" "0" "$MUT_UN_RC"
assert_eq "4.0d NON-VACUITY: no marker survives in any mutant" "0" \
    "$(n=0
       for m in "$MUT_WM" "$MUT_QG" "$MUT_BL" "$MUT_IN" "$MUT_UN"; do
           grep -q 'SHA256-ESCAPE-DECODE' "$m" && n=$((n+1))
       done
       echo "$n")"
assert_eq "4.0e NON-VACUITY: every mutant differs in BYTES from what ships" "5-differ" \
    "$(n=0
       cmp -s "$WM" "$MUT_WM" || n=$((n+1))
       cmp -s "$QG" "$MUT_QG" || n=$((n+1))
       cmp -s "$BL" "$MUT_BL" || n=$((n+1))
       cmp -s "$IN" "$MUT_IN" || n=$((n+1))
       cmp -s "$UN" "$MUT_UN" || n=$((n+1))
       echo "$n-differ")"
assert_eq "4.0f NON-VACUITY: every mutant still PARSES, so a failure below is behavioural" "5-ok" \
    "$(n=0
       for m in "$MUT_WM" "$MUT_QG" "$MUT_BL" "$MUT_IN" "$MUT_UN"; do
           bash -n "$m" 2>/dev/null && n=$((n+1))
       done
       echo "$n-ok")"

if [ -z "$ESCAPING_TOOL" ]; then
    skip "4.1-4.6 mutant misbehaviour legs: no tool on this host escapes, so the mutant cannot reproduce the defect and a green here would mean nothing"
else
    extract_fn "$MUT_QG" "$WORK/mut-qg-fn.sh"
    extract_fn "$MUT_BL" "$WORK/mut-bl-fn.sh"
    MUT_WM_NL=$(env PATH="$WM_ENV_PATH" bash "$MUT_WM" hash-file "$P_NL" 2>&1); MUT_WM_NL_RC=$?
    MUT_QG_NL=$(call_fn "$WORK/mut-qg-fn.sh" "$P_NL" 2>/dev/null)
    MUT_BL_NL=$(call_fn "$WORK/mut-bl-fn.sh" "$P_NL" 2>/dev/null)

    # SPECIFIC MISBEHAVIOUR, each naming the consumer check that goes red.
    assert_eq "4.1 MUTANT helper1 REFUSES the newline-named path (rc 1) -- this is design-artifact.test.sh 9.2 going red" \
        "1" "$MUT_WM_NL_RC"
    assert_contains "4.1a ...with the 65-char complaint over a CORRECT digest" \
        "was not 64 chars" "$MUT_WM_NL"
    assert_contains "4.1b ...the refused value being the true digest wearing the escape marker" \
        "'\\$TRUTH'" "$MUT_WM_NL"

    assert_eq "4.2 MUTANT helper2 EMITS a 65-char value -- fail-OPEN, so design_hash binds \\<hash> and approve's 'the design artifact has CHANGED' ladder compares unequal against the same bytes" \
        "65" "${#MUT_QG_NL}"
    assert_eq "4.2a ...and it is the true digest behind the marker, so nothing downstream can tell it is wrong by shape alone" \
        "$TRUTH" "${MUT_QG_NL#\\}"
    assert_ne "4.2b ...so the mutant disagrees with the stdin TRUTH" "$TRUTH" "$MUT_QG_NL"

    assert_eq "4.3 MUTANT helper3 EMITS a 65-char value -- fail-OPEN, so cmd_check's fresh_sha/disk_sha comparison reports a backslash-named ledger STALE against itself" \
        "65" "${#MUT_BL_NL}"
    assert_eq "4.3a ...same true digest behind the marker" "$TRUTH" "${MUT_BL_NL#\\}"
    assert_ne "4.3b ...so the mutant disagrees with the stdin TRUTH" "$TRUTH" "$MUT_BL_NL"

    # The mutation is SPECIFIC: it must not have broken the refusals, or 4.1
    # could be passing because the mutant is broken generally rather than
    # because the decode is gone.
    MUT_WM_ABS=$(env PATH="$WM_ENV_PATH" bash "$MUT_WM" hash-file "$P_ABSENT" 2>&1); MUT_WM_ABS_RC=$?
    assert_eq "4.4 DISCRIMINATOR: the mutant still refuses an ABSENT path the same way" "1" "$MUT_WM_ABS_RC"
    assert_contains "4.4a ...for the same reason, so the mutation touched only the decode" \
        "no such file" "$MUT_WM_ABS"
    assert_eq "4.5 DISCRIMINATOR: mutant helper2 still returns rc 1 for an absent path" "1" \
        "$(call_fn "$WORK/mut-qg-fn.sh" "$P_ABSENT" >/dev/null 2>&1; echo $?)"

    # RESTORE CONTROL, inline: on an UNESCAPED path mutant and shipped agree
    # exactly. Without this, 4.1-4.3 could be an artefact of the copy rather
    # than of the removed line.
    assert_eq "4.6 RESTORE CONTROL: on a PLAIN path the mutant and the shipped helper1 agree" \
        "$(call_wm "$P_PLAIN")" "$(env PATH="$WM_ENV_PATH" bash "$MUT_WM" hash-file "$P_PLAIN" 2>&1)"
    assert_eq "4.6a RESTORE CONTROL: ...and so do helper2's two builds" \
        "$(call_fn "$WORK/qg-fn.sh" "$P_PLAIN")" "$(call_fn "$WORK/mut-qg-fn.sh" "$P_PLAIN")"
    assert_eq "4.6b RESTORE CONTROL: ...and helper3's" \
        "$(call_fn "$WORK/bl-fn.sh" "$P_PLAIN")" "$(call_fn "$WORK/mut-bl-fn.sh" "$P_PLAIN")"

    # Helpers 4 and 5: fail-CLOSED, so the mutant's misbehaviour is a REFUSAL
    # of a correct digest (empty output), not a malformed emission.
    extract_fn "$MUT_IN" "$WORK/mut-in-fn.sh" mcp_sha256_of
    extract_fn "$MUT_UN" "$WORK/mut-un-fn.sh" hash_of
    assert_eq "4.7 MUTANT helper4 install.sh returns EMPTY for the newline-named path -- the 64-char guard rejects a correct digest, so mcp_deps re-runs npm ci on every invocation for such a target" \
        "" "$(call_fn "$WORK/mut-in-fn.sh" "$P_NL" mcp_sha256_of)"
    assert_eq "4.8 MUTANT helper5 uninstall.sh returns EMPTY for the newline-named path -- so every manifest row for such a target reads unverifiable and the file is left on disk" \
        "" "$(call_fn "$WORK/mut-un-fn.sh" "$P_NL" hash_of)"
    assert_eq "4.8a RESTORE CONTROL: on a PLAIN path helper4's two builds agree" \
        "$(call_fn "$WORK/in-fn.sh" "$P_PLAIN" mcp_sha256_of)" \
        "$(call_fn "$WORK/mut-in-fn.sh" "$P_PLAIN" mcp_sha256_of)"
    assert_eq "4.8b RESTORE CONTROL: ...and helper5's" \
        "$(call_fn "$WORK/un-fn.sh" "$P_PLAIN" hash_of)" \
        "$(call_fn "$WORK/mut-un-fn.sh" "$P_PLAIN" hash_of)"
fi

# ---------------------------------------------------------------------------
# 5. FAMILY MEMBERSHIP — every path-passing hasher carries the decode
# ---------------------------------------------------------------------------
# The defect was "three helpers, only one of them guarded". A fourth helper
# added tomorrow inherits nothing from sections 2-4, so the membership is
# asserted directly: every site that hands a PATH to sha256sum/shasum must
# carry a decode marker in its function. The stdin-fed hashers
# (impact-report.sh, verify-before-stop.sh) are NOT members -- no filename ever
# reaches their output -- and are pinned as such so a future author does not
# "fix" them into a decode they do not need.
printf '\n=== 5. family membership ===\n'
assert_eq "5.1 all FIVE path-passing helpers carry a decode marker" "5" \
    "$(n=0
       for f in "$WM" "$QG" "$BL" "$IN" "$UN"; do
           grep -q 'SHA256-ESCAPE-DECODE' "$f" && n=$((n+1))
       done
       echo "$n")"
# 18fc's filed census searched .claude/scripts only, and so missed install.sh
# and uninstall.sh — two more members found while implementing it. This leg
# generalises that miss: EVERY shipped shell file that hands a PATH argument to
# sha256sum or shasum must carry a decode. Written as a search over the tree
# rather than a list, so a sixth helper added anywhere trips here instead of
# waiting for the next person to grep by hand.
#
# HONEST LABEL: this one IS a text scan, and a text scan is evidence about
# text. It is a membership TRIPWIRE, not the behavioural check — sections 2
# and 4 drive all five helpers, and those are where the behaviour is pinned.
# Its value is catching a sixth member on the round it is added, which no
# behavioural leg over the five known ones can do.
# A path-passing call site: the tool name followed by a quoted expansion, i.e.
# an argument. `-a 256` is consumed so `shasum -a 256 <path>` is caught while
# `shasum -a 256 | awk` (the stdin form) is not.
path_passing_files() {
    local root="$1" f
    for f in "$root"/install.sh "$root"/uninstall.sh "$root"/.claude/scripts/*.sh; do
        [ -f "$f" ] || continue
        grep -qE '(sha256sum|shasum -a 256)( --)? "\$' "$f" || continue
        printf '%s\n' "$f"
    done
}
undecoded_in() {
    local root="$1" f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -q 'SHA256-ESCAPE-DECODE' "$f" || printf '%s ' "${f##*/}"
    done < <(path_passing_files "$root")
}
assert_eq "5.1a no shipped script passes a PATH to a hasher without decoding the escape" \
    "" "$(undecoded_in "$PROJECT_DIR")"
assert_eq "5.1b ...and the detector actually SEES all five, so 5.1a is not empty-because-blind" "5" \
    "$(path_passing_files "$PROJECT_DIR" | wc -l | tr -d ' ')"
# NON-VACUITY for 5.1a: build a tree from the section-4 mutants and confirm the
# detector NAMES them. Without this, 5.1a passes identically whether the tree is
# clean or the grep is broken.
MUTROOT="$WORK/mutroot"
mkdir -p "$MUTROOT/.claude/scripts"
cp "$MUT_IN" "$MUTROOT/install.sh"
cp "$MUT_UN" "$MUTROOT/uninstall.sh"
cp "$MUT_WM" "$MUTROOT/.claude/scripts/workflow-manifest.sh"
cp "$MUT_QG" "$MUTROOT/.claude/scripts/qa-gate.sh"
cp "$MUT_BL" "$MUTROOT/.claude/scripts/beads-ledger.sh"
assert_eq "5.1c NON-VACUITY: over the decode-stripped mutant tree the detector names every member" \
    "beads-ledger.sh install.sh qa-gate.sh uninstall.sh workflow-manifest.sh " \
    "$(undecoded_in "$MUTROOT" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/^ //')"
NON_MEMBER_N=0
for nm in impact-report.sh verify-before-stop.sh; do
    f="$PROJECT_DIR/.claude/scripts/$nm"
    [ -f "$f" ] || continue
    NON_MEMBER_N=$((NON_MEMBER_N + 1))
    # grep -c exits 1 on no match but still PRINTS 0; capture the count and
    # ignore the status rather than `|| echo 0`, which emits a second line.
    assert_eq "5.2.$NON_MEMBER_N $nm hashes STDIN, so it is not a member and carries no decode" "0" \
        "$(grep -c 'SHA256-ESCAPE-DECODE' "$f" 2>/dev/null)"
done
assert_eq "5.3 ...and both non-members were actually found and checked, not skipped away" "2" \
    "$NON_MEMBER_N"

# ---------------------------------------------------------------------------
printf '\n=== Summary ===\n\n'
printf 'Total: %s assertion(s) run\n' "$((PASS + FAIL))"
if [ "$FAIL" -eq 0 ]; then
    printf 'PASSED: %s assertion(s)\n' "$PASS"
    [ "$SKIPPED" -gt 0 ] && printf 'SKIPPED: %s leg(s)\n' "$SKIPPED"
    exit 0
fi
printf 'PASSED: %s assertion(s)\nFAILED: %s assertion(s)\n' "$PASS" "$FAIL"
for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
exit 1

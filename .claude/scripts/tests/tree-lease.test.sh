#!/bin/bash
# tree-lease.test.sh — claude-workflow-plugin-gsfd (member 5, the lease).
#
# Direct, executable tests of .claude/scripts/tree-lease.sh: the library
# sourced by run-tests.sh (L1), .claude/tests/component/run.sh (L2), and
# verify-before-stop.sh to answer "who owns this tree right now". This spec
# sources the SHIPPED file directly (no re-typed copy, no awk-extraction —
# the library is designed to be sourced, so sourcing it IS driving the
# shipped artifact) and, for each guard, also builds a deliberately-mutated
# COPY to prove the assertion is sensitive to the specific defect it guards
# against, per the four-part pairing convention (.claude/tests/README.md).
#
# DESIGN COLLAPSE (round 6): the lease is now report-only — lease_acquire no
# longer self-heals via lease_reclaim_stale, and the status grammar dropped
# from four values (STALE/LIVE/LIVE-BUT-OLD/UNCONFIRMED, gated by two
# independent age thresholds) to two (LIVE/STALE, gated by nothing — age is
# informational only). This file's sections below were cut to match: the
# heartbeat section (old section 9) and the dead_grace_s-specific section
# (old section 14) are DELETED outright rather than repaired, because the
# mechanisms they guarded — lease_heartbeat, and the dead_grace_s threshold
# — no longer exist anywhere in this codebase. Section numbers below are NOT
# renumbered (claude-workflow-plugin-gsfd R6-F5 correction: this comment used
# to claim they were, which the catalogue and the executable body both
# falsify) — they keep their ORIGINAL values with the deleted sections'
# numbers simply absent: both jump straight from 8 to 10, and 14 does not
# exist at all. Do not assume a contiguous 1..N run, and do not cross-
# reference an old number against this file's own git history without
# checking what actually moved.
#
# ASSERTIONS
#   1. lease_acquire creates a well-formed lease file (all five fields
#      present: owner_pid is this shell's own $$, tier/label round-trip,
#      owner_host round-trips to this host's own hostname, and started_at is
#      numeric, not in the future, and — the real check (1h) — agrees with
#      the independent _lease_pid_start_matches verifier for this shell's
#      own pid. NOT a raw acquire-call wall-clock window: lease_acquire
#      back-computes started_at from this pid's own measured elapsed
#      runtime, so it is a fact about the PROCESS, stable for its whole
#      life, and can legitimately predate the acquire call once this spec
#      itself has been running a while.
#   2. Same-tier double-acquire without releasing produces TWO DISTINCT
#      files, neither clobbering the other — a real, previously-shipped bug
#      in this exact file (a mktemp template with a trailing suffix after
#      XXXXXX is not substituted on BSD/macOS mktemp) — META-TEST 2
#      reintroduces that exact template shape and proves the shipped file's
#      2c assertion is genuinely sensitive to it, by PROBING this platform's
#      own mktemp behaviour for the identical template shape (portable
#      across BSD and GNU, neither hardcoded nor skipped).
#   3. lease_conflicts classifies a same-host DEAD pid STALE regardless of
#      the lease's own age — age is informational only now, never a
#      threshold a status must wait out. META-TEST 3 mutates the dead-pid
#      check to always report "alive" and proves a genuinely-dead lease
#      then reads LIVE, the false negative this rule exists to prevent.
#   3b. Restore control: a fresh-mtime lease for the CALLER's own (alive)
#      pid classifies LIVE.
#   4. A CONFIRMED-alive pid (kill -0 succeeds AND started_at matches that
#      pid's own measured elapsed runtime) with an ANCIENT mtime still
#      classifies LIVE, never STALE, and lease_reclaim_stale never removes
#      it — the age backstop must not override a positive liveness
#      confirmation. META-TEST 4 removes just the guard that lets a
#      confirmed-live pid skip the age question and proves the bug's exact
#      symptom (STALE) returns.
#   4b. A pid that IS alive (kill -0 succeeds) but whose recorded started_at
#      does NOT match that pid's own measured elapsed runtime (pid reuse:
#      the OS only recycles a pid number after the original process fully
#      exits) classifies STALE, not LIVE, regardless of age — a reused pid
#      is proof the ORIGINAL owner died, not proof of continued life. META-
#      TEST 4b disables the pid-reuse comparison and proves the recycled-pid
#      fixture then reads LIVE forever.
#   4c. claude-workflow-plugin-gsfd R6-F4: a pid that IS alive but whose
#      elapsed runtime could not be MEASURED at all (a stubbed, unusable
#      `ps` placed first on PATH) classifies LIVE, hedged — not STALE —
#      because _lease_pid_start_matches's own contract treats "unknown" as
#      "cannot rule out a match". The previously missing leg between 4
#      ("yes") and 4b ("no"). META-TEST 4c narrows the classification to
#      accept only a literal "yes" and proves the identical fixture then
#      reads STALE.
#   5. lease_conflicts excludes the caller's OWN lease file when passed as
#      "self" (no false self-conflict), and INCLUDES it when self="" is
#      passed instead.
#   6. lease_reclaim_stale removes exactly the STALE entries and leaves a
#      co-located LIVE one untouched (non-vacuity: file counts before/after,
#      not just exit code) — called EXPLICITLY here, never automatically:
#      lease_acquire below (section 6b) proves it does NOT call this on
#      anyone's behalf any more.
#   6b. lease_acquire does NOT reclaim a stale lease as a side effect of
#      acquiring a new one — the design-collapse's own core behavioural
#      change. A pre-existing STALE lease survives an unrelated acquire
#      call untouched.
#   7. SET -e SAFETY (the reason every function in this library ends in an
#      explicit `return 0`): lease_conflict_summary must not abort a caller
#      running under `set -e` on the COMMON case — zero conflicts, where
#      the pipeline's last stage (`grep`) exits 1 by construction. META-TEST
#      7 mutates the function to remove its trailing guard and proves a
#      `set -e` caller genuinely aborts against the mutant.
#   8. lease_acquire degrades to printing "" and returning 1 (never aborting
#      the caller, never fabricating a path) when the lease directory cannot
#      be created — a file sitting where a directory needs to go.
#  10. lease_release's defining effect (the file is gone) — exercised dozens
#      of times in this file's own cleanup but never itself asserted before
#      the fix that added this assertion. META-TEST 10 makes it a no-op and
#      proves the file survives its own release call.
#  11. Sourcing this file must not change the CALLER's own `set -u`
#      (nounset) state — a file-scope `set -u` used to leak into every
#      sourcing caller. META-TEST 11 restores a file-scope `set -u` in a
#      mutant copy and proves the SAME caller-shape genuinely picks it up.
#  12. lease_acquire back-computes started_at from THIS pid's own measured
#      elapsed runtime rather than recording the acquire-call moment, driven
#      with a REAL 7s delay (not simulated — this property is about actual
#      OS-measured elapsed time, which cannot be backdated the way an mtime
#      can): a lease acquired after that delay still reads LIVE to a
#      concurrent checker. META-TEST 12 neuters just the correction and
#      proves the IDENTICAL scenario then reads STALE, not LIVE — a live,
#      legitimate lease misread as pid-reuse purely because of how long its
#      owner took to reach lease_acquire.
#  13. lease_release must survive a failing `rm -f` (target is a directory)
#      under a `set -e` + bare-call caller. META-TEST 13 restores the
#      historical bare form (no `|| true`) and proves the identical scenario
#      now genuinely aborts the set -e caller.
#
# NOT re-proven here: the GNU-stat-first/BSD-stat-second mtime ordering is a
# platform fact already measured and cited in tree-lease.sh's own header,
# lifted from workflow-doctor.test.sh's independent CI-crash measurement — a
# second assertion of the same platform behaviour would be a false pair (this
# repo's authoring box is macOS; proving the GNU branch requires a GNU stat,
# which is exactly the Linux-tier's job, not this spec's). The GNU/BSD
# agreement on `ps -o etime=`'s format (used by _lease_pid_elapsed_s) is
# handled the same way: verified directly on this (BSD) box in
# tree-lease.sh's own PORTABILITY header, not re-proven with a second
# platform-specific assertion here.
#
# Exit codes:
#   0  every assertion passed
#   1  one or more assertions failed
#   2  invocation error (the shipped library is missing or fails to source)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
LIB="$PROJECT_DIR/.claude/scripts/tree-lease.sh"

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

if [ ! -f "$LIB" ]; then
    printf 'tree-lease.test.sh: shipped library missing: %s\n' "$LIB" >&2
    exit 2
fi
# shellcheck source=.claude/scripts/tree-lease.sh
. "$LIB" || { printf 'tree-lease.test.sh: failed to source %s\n' "$LIB" >&2; exit 2; }

WORK=$(mktemp -d -t tree-lease-test.XXXXXX)
# shellcheck disable=SC2329  # invoked via trap.
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# A pid guaranteed not to be alive right now, for the dead-pid guards.
dead_pid() {
    local p=99999
    while kill -0 "$p" 2>/dev/null; do p=$((p + 1)); done
    printf '%s' "$p"
}

# self_started_at -- an ACCURATE started_at for a fixture claiming
# owner_pid=$$. This file's fixtures used to fabricate with a bare
# `date +%s` (the FABRICATION moment, not this shell's TRUE start time) —
# harmless before R1-F2, which now cross-checks started_at against $$'s
# actual measured elapsed runtime. A fixture claiming to be a genuine alive
# lease for $$ has to record a start time consistent with $$'s real elapsed
# runtime, the same way a real lease_acquire call would (via _lease_now at
# actual creation time).
self_started_at() {
    local now elapsed
    now=$(date +%s)
    elapsed=$(_lease_pid_elapsed_s "$$" 2>/dev/null) || elapsed=""
    case "$elapsed" in ''|*[!0-9]*) elapsed=0 ;; esac
    printf '%s' "$((now - elapsed))"
}

# The full set of library function names every mutant subshell below must
# unset before re-sourcing a mutant copy, so the mutant's OWN definitions are
# what gets exercised rather than leftover shipped ones from this file's own
# top-level sourcing. lease_heartbeat is gone (design collapse, round 6) —
# not listed here any more.
LIB_FUNCS="lease_acquire lease_release lease_conflicts lease_reclaim_stale lease_conflict_summary _lease_field _lease_mtime_epoch _lease_hostname _lease_now _lease_pid_elapsed_s _lease_pid_start_matches"

# awk_mutate <find> <replace> <output_file> -- writes a mutant copy of the
# shipped library to <output_file> with every line CONTAINING the exact
# literal substring <find> rewritten to have <find> spliced out for
# <replace>, via index()/substr() -- NOT a regex substitution, so none of
# this pattern's own `[`, `]`, `$`, `"` characters need escaping the way a
# sed or awk-regex substitution would. Returns 7 (awk's own END block) if
# <find> was not found anywhere -- non-vacuity is built into the call.
# Avoids bash's own `${var//find/replace}` pattern-matching engine on
# purpose: measured CATASTROPHICALLY slow on this box's bash 3.2 once
# <find> is longer and genuinely matches against this ~20KB file (a 36-char
# pattern did not finish in 10s; this helper does the same substitution in
# ~14ms).
awk_mutate() {
    local find="$1" repl="$2" out="$3"
    # awk's `-v` assignment interprets C-style escape sequences in the
    # ASSIGNED VALUE — doubling any literal backslash before the assignment
    # is exactly undone by awk's own escape-collapsing, restoring the
    # original byte sequence (a no-op for every call site below, none of
    # which contain a backslash; load-bearing only for a future one that
    # does).
    find="${find//\\/\\\\}"
    repl="${repl//\\/\\\\}"
    awk -v find="$find" -v repl="$repl" '
        {
            line = $0
            idx = index(line, find)
            if (idx > 0) {
                line = substr(line, 1, idx - 1) repl substr(line, idx + length(find))
                hit_count++
            }
            print line
        }
        END { if (hit_count == 0) exit 7 }
    ' "$LIB" > "$out"
}

# ---------------------------------------------------------------------------
# 1. Well-formed lease file.
D1="$WORK/t1"; mkdir -p "$D1"
L1=$(lease_acquire "$D1" "L1" "assertion 1")
AFTER_ACQUIRE=$(date +%s)
assert_eq "1a: lease_acquire returns a path that exists" \
    "yes" "$([ -f "$L1" ] && echo yes || echo no)"
assert_eq "1b: owner_pid field is this shell's own \$\$" \
    "$$" "$(_lease_field "$L1" owner_pid)"
assert_eq "1c: tier field round-trips" "L1" "$(_lease_field "$L1" tier)"
assert_eq "1d: label field round-trips" "assertion 1" "$(_lease_field "$L1" label)"
assert_eq "1e: owner_host field round-trips to this host's own hostname" \
    "$(hostname 2>/dev/null || printf 'unknown-host')" "$(_lease_field "$L1" owner_host)"
STARTED_1=$(_lease_field "$L1" started_at)
STARTED_1_NUMERIC="yes"
case "$STARTED_1" in ''|*[!0-9]*) STARTED_1_NUMERIC="no" ;; esac
assert_eq "1f: started_at field is present and numeric" \
    "yes" "$STARTED_1_NUMERIC"
assert_eq "1g: started_at is not in the future (sanity bound, non-vacuity: not a hardcoded/frozen value)" \
    "yes" "$([ "$STARTED_1" -le "$AFTER_ACQUIRE" ] 2>/dev/null && echo yes || echo no)"
# 1h: NOT a raw BEFORE_ACQUIRE<=started_at<=AFTER_ACQUIRE window check.
# lease_acquire back-computes started_at from THIS pid's own measured
# elapsed runtime: a caller whose own preamble work runs long before it
# ever reaches lease_acquire must not have its OWN fresh lease misread as
# pid-reuse by a concurrent checker's tolerance window. That makes
# started_at a fact about the PROCESS (stable for its whole life), not
# about the moment this call happened to run, so it can legitimately fall
# BEFORE BEFORE_ACQUIRE once this spec itself has been running a while.
# The independent verifier is the real check: does _lease_pid_start_matches
# (the function this correction's own reclaim-safety depended on, and
# which STILL governs LIVE-vs-STALE post-collapse) agree this is a match
# for the CALLER's own pid, right after acquiring it.
assert_eq "1h: the independent pid-start verifier agrees this started_at matches $$'s own actual start" \
    "yes" "$(_lease_pid_start_matches "$$" "$STARTED_1" "$(date +%s)")"
lease_release "$L1"

# META-TEST 1e: assertion 1e (owner_host round-trips to this host's own
# hostname) had NO discriminating mutation proving it is sensitive to
# owner_host being written wrong. Mutate lease_acquire's own owner_host
# write to a fixed, wrong string and prove the shipped assertion's check
# (owner_host round-trips to the REAL hostname) would have failed against
# it.
MUT1E=$(mktemp -t tree-lease-mut1e.XXXXXX)
# shellcheck disable=SC2016  # single quotes intentional, see META-TEST 3's note.
_M1E_SEARCH="printf 'owner_host=%s\\n' \"\$host\""
_M1E_REPLACE="printf 'owner_host=%s\\n' \"META-TEST-BOGUS-HOST\""
awk_mutate "$_M1E_SEARCH" "$_M1E_REPLACE" "$MUT1E"
rc_hit=$?
assert_eq "META 1e: the mutation actually landed (non-vacuity: owner_host write is now hardcoded)" "0" "$rc_hit"
bash -n "$MUT1E" 2>/dev/null
assert_eq "META 1e: mutant copy still parses" "0" "$?"
(
    # shellcheck disable=SC2086
    unset -f $LIB_FUNCS 2>/dev/null
    # shellcheck disable=SC1090
    . "$MUT1E"
    D1EM="$WORK/t1em"; mkdir -p "$D1EM"
    L1EM=$(lease_acquire "$D1EM" "L1" "meta1e")
    _lease_field "$L1EM" owner_host
) > "$WORK/meta1e.out" 2>/dev/null
assert_eq "META 1e: with owner_host hardcoded, the written field carries the injected value, not this host's real hostname -- the shipped 1e check (compares against the REAL hostname) would have failed against this mutant (specific misbehaviour)" \
    "META-TEST-BOGUS-HOST" "$(cat "$WORK/meta1e.out")"
rm -f "$MUT1E"

# ---------------------------------------------------------------------------
# 2. mktemp's XXXXXX placeholder is genuinely substituted (the shipped
# template bug, fixed during this task): BSD/macOS mktemp does NOT substitute
# a trailing suffix after the X run — `mktemp foo.XXXXXX.lease` creates the
# LITERAL path "foo.XXXXXX.lease" unchanged (measured directly while building
# this file). A same-tier double-acquire does not actually collide even under
# that bug, because lease_acquire's mktemp-missing FALLBACK also catches a
# mktemp FAILURE (the second call's O_EXCL create fails against the first
# call's already-created literal path) and produces a distinct RANDOM-suffixed
# name anyway — so double-acquire is the wrong signal to assert on. The
# direct, honest signal is simpler: does the FIRST acquired filename for a
# fresh tier ever literally contain the word "XXXXXX"?
D2="$WORK/t2"; mkdir -p "$D2"
L2A=$(lease_acquire "$D2" "L1" "first")
L2B=$(lease_acquire "$D2" "L1" "second")
assert_eq "2a: same-tier double-acquire still yields distinct paths (via mktemp or its fallback)" \
    "distinct" "$([ "$L2A" != "$L2B" ] && echo distinct || echo COLLIDED)"
assert_eq "2b: both files exist simultaneously" \
    "yes:yes" "$([ -f "$L2A" ] && echo yes || echo no):$([ -f "$L2B" ] && echo yes || echo no)"
assert_eq "2c: the shipped acquire's filename never contains the literal placeholder" \
    "no" "$(printf '%s' "$(basename "$L2A")" | grep -q 'XXXXXX' && echo yes || echo no)"
lease_release "$L2A"; lease_release "$L2B"

# META-TEST 2: reintroduce the historical bug (X's followed by a literal
# suffix) in a mutant copy and prove its FIRST acquire's literal-placeholder
# outcome matches THIS PLATFORM'S OWN measured mktemp behaviour for that
# template shape. The previous version of this assertion hardcoded "yes"
# (BSD's un-substituted behaviour) and read FAILED on GNU coreutils 9.7,
# where the identical template IS substituted (measured in
# debian:stable-slim: `mktemp lease.L1.XXXXXX.lease` -> rc=0,
# `lease.L1.SATf8R.lease`); CI runs L1 on ubuntu-latest, so the guard was
# green where the bug cannot occur (this authoring box) and red where it can
# (Linux CI). Fixed by PROBING this platform's own mktemp for the exact
# template shape, independent of lease_acquire, and asserting the mutant's
# outcome equals the probe's outcome — a real, non-skipped assertion on
# every platform, derived from measured local behaviour rather than an
# assumed one (neither platform is ever silently skipped).
MUT2=$(mktemp -t tree-lease-mut2.XXXXXX)
# shellcheck disable=SC2016  # single quotes are intentional: this is a sed
# script matching LITERAL bash variable references in the target file, not
# an expression for THIS shell to expand.
sed 's|mktemp "\$lease_dir/lease\.\${tier}\.XXXXXX"|mktemp "$lease_dir/lease.${tier}.XXXXXX.lease"|' \
    "$LIB" > "$MUT2"
rc_hit=1
# shellcheck disable=SC2016
grep -q 'lease\.\${tier}\.XXXXXX\.lease' "$MUT2" && rc_hit=0
assert_eq "META 2: the mutation actually landed in the copy (non-vacuity)" "0" "$rc_hit"
bash -n "$MUT2" 2>/dev/null
assert_eq "META 2: mutant copy still parses" "0" "$?"

# The PLATFORM PROBE: run the exact historical template shape directly
# through THIS box's own mktemp, independent of any acquire logic, so the
# expected outcome below is measured, not assumed.
PROBE2_DIR="$WORK/mktemp-probe"; mkdir -p "$PROBE2_DIR"
PROBE2_FILE=$(mktemp "$PROBE2_DIR/probe.XXXXXX.lease" 2>/dev/null)
assert_eq "META 2 probe: this platform's mktemp accepted the historical template (non-vacuity of the probe itself)" \
    "yes" "$([ -n "$PROBE2_FILE" ] && [ -e "$PROBE2_FILE" ] && echo yes || echo no)"
PROBE2_HAS_LITERAL=$(printf '%s' "$(basename "${PROBE2_FILE:-}")" | grep -q 'XXXXXX' && echo yes || echo no)
rm -f "$PROBE2_FILE" 2>/dev/null

(
    # shellcheck disable=SC2086
    unset -f $LIB_FUNCS 2>/dev/null
    # shellcheck disable=SC1090
    . "$MUT2"
    D2M="$WORK/t2m"; mkdir -p "$D2M"
    MA=$(lease_acquire "$D2M" "L1" "first")
    printf '%s' "$(basename "$MA")" | grep -q 'XXXXXX' && echo yes || echo no
) > "$WORK/meta2.out" 2>/dev/null
assert_eq "META 2: with the historical template shape, the first acquire's literal-placeholder outcome matches THIS platform's own measured mktemp behaviour (specific misbehaviour, portable across BSD and GNU)" \
    "$PROBE2_HAS_LITERAL" "$(cat "$WORK/meta2.out")"
rm -f "$MUT2"

# ---------------------------------------------------------------------------
# 3. Dead-pid staleness. DESIGN COLLAPSE (round 6): a same-host dead pid
# classifies STALE regardless of the lease's own age — there is no more
# UNCONFIRMED intermediate state and no age threshold gating this decision,
# because nothing acts on the reading automatically any more (see
# tree-lease.sh's own DESIGN COLLAPSE header). A hostname-string collision
# with a genuinely-live different machine is still possible (KNOWN
# LIMITATION, unchanged), but it no longer risks an auto-delete of a live
# foreign lease — it costs a reader one wrong word in a notice, which this
# collapse accepts explicitly.
D3="$WORK/t3"; mkdir -p "$D3/leases"
DEADPID=$(dead_pid)
LEASE3="$D3/leases/lease.L1.deadprobe"
{
    printf 'tier=L1\nlabel=dead\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
        "$DEADPID" "$(hostname 2>/dev/null || echo h)" "$(date +%s)"
} > "$LEASE3"
OUT3=$(lease_conflicts "$D3" "")
assert_eq "3a: a fresh-mtime lease for a DEAD pid classifies STALE (age is informational only, never a gate)" \
    "yes" "$(printf '%s\n' "$OUT3" | grep -q '^STALE.*owner_pid='"$DEADPID"'\b' && echo yes || echo no)"
assert_eq "3a2: ...and is NEVER asserted LIVE" \
    "no" "$(printf '%s\n' "$OUT3" | grep -q '^LIVE .*owner_pid='"$DEADPID"'\b' && echo yes || echo no)"
BEFORE3=$(find "$D3/leases" -type f | wc -l | tr -d ' ')
lease_reclaim_stale "$D3" >/dev/null
AFTER3=$(find "$D3/leases" -type f | wc -l | tr -d ' ')
assert_eq "3a3: an EXPLICIT lease_reclaim_stale call does remove a fresh-mtime dead-pid lease (non-vacuity: file count decreases)" \
    "yes" "$([ "$AFTER3" -lt "$BEFORE3" ] && echo yes || echo no)"
assert_eq "3a4: ...specifically, the file itself is gone" \
    "yes" "$([ ! -f "$LEASE3" ] && echo yes || echo no)"

# 3b restore control: the identical shape with THIS shell's own (alive) pid
# classifies LIVE. started_at must be THIS shell's actual start time (see
# self_started_at) now that R1-F2 cross-checks it — fabricating "now" here
# would itself look like a pid-reuse mismatch and misreport this control as
# STALE for the wrong reason.
LEASE3B="$D3/leases/lease.L1.aliveprobe"
{
    printf 'tier=L1\nlabel=alive\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
        "$$" "$(hostname 2>/dev/null || echo h)" "$(self_started_at)"
} > "$LEASE3B"
OUT3B=$(lease_conflicts "$D3" "")
assert_eq "3b restore: a fresh-mtime lease for the CALLER's own (alive) pid classifies LIVE" \
    "yes" "$(printf '%s\n' "$OUT3B" | grep -q '^LIVE .*owner_pid='"$$"'\b' && echo yes || echo no)"
rm -f "$LEASE3B"

# META-TEST 3: mutate the dead-pid check to always report "alive" and prove
# a genuinely-dead lease then reads LIVE (the false negative this rule
# exists to prevent). awk_mutate (see its own header above), not bash
# substring replacement or sed.
MUT3=$(mktemp -t tree-lease-mut3.XXXXXX)
# shellcheck disable=SC2016  # single quotes intentional: this is the LITERAL
# text to find/replace in the shipped file, not an expression for THIS shell
# to expand.
_M3_SEARCH='if kill -0 "$pid" 2>/dev/null; then'
_M3_REPLACE='if true; then'
awk_mutate "$_M3_SEARCH" "$_M3_REPLACE" "$MUT3"
rc_hit=$?
assert_eq "META 3: the mutation actually landed (non-vacuity)" "0" "$rc_hit"
bash -n "$MUT3" 2>/dev/null
assert_eq "META 3: mutant copy still parses" "0" "$?"
(
    # shellcheck disable=SC2086
    unset -f $LIB_FUNCS 2>/dev/null
    # shellcheck disable=SC1090
    . "$MUT3"
    D3M="$WORK/t3m"; mkdir -p "$D3M/leases"
    DP=$(dead_pid)
    printf 'tier=L1\nlabel=dead\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
        "$DP" "$(hostname 2>/dev/null || echo h)" "$(date +%s)" > "$D3M/leases/lease.L1.x"
    lease_conflicts "$D3M" "" | grep -o '^[A-Z-]*' | head -1
) > "$WORK/meta3.out" 2>/dev/null
assert_eq "META 3: with the dead-pid check disabled, a dead lease reads LIVE (specific misbehaviour)" \
    "LIVE" "$(cat "$WORK/meta3.out")"
rm -f "$MUT3"

# ---------------------------------------------------------------------------
# 4. A CONFIRMED-alive pid (kill -0 succeeds AND started_at matches this
# pid's own measured elapsed runtime) with an ANCIENT mtime classifies LIVE,
# NEVER STALE — the age backstop must not override a positive liveness
# confirmation (this lease is advisory, not a mutex: an unreclaimed wedge
# costs visibility, a wrongly-reclaimed live owner costs a second runner
# proceeding as though it holds the tree). This fixture constructs its
# ANCIENT mtime directly.
D4="$WORK/t4"; mkdir -p "$D4/leases"
LEASE4="$D4/leases/lease.L2.oldmtime"
{
    printf 'tier=L2\nlabel=old\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
        "$$" "$(hostname 2>/dev/null || echo h)" "$(self_started_at)"
} > "$LEASE4"
touch -t 202001010000 "$LEASE4" 2>/dev/null || touch -d '2020-01-01' "$LEASE4" 2>/dev/null
OUT4=$(lease_conflicts "$D4" "")
assert_eq "4a: an ancient-mtime lease for a CONFIRMED-alive pid still classifies LIVE (age never demotes a confirmed-alive owner)" \
    "yes" "$(printf '%s\n' "$OUT4" | grep -q '^LIVE ' && echo yes || echo no)"
assert_eq "4b: ...and is NEVER classified STALE" \
    "no" "$(printf '%s\n' "$OUT4" | grep -q '^STALE' && echo yes || echo no)"
BEFORE4=$(find "$D4/leases" -type f | wc -l | tr -d ' ')
lease_reclaim_stale "$D4" >/dev/null
AFTER4=$(find "$D4/leases" -type f | wc -l | tr -d ' ')
assert_eq "4c: an explicit lease_reclaim_stale call does NOT remove a confirmed-LIVE lease, however old (non-vacuity: file count unchanged)" \
    "$BEFORE4" "$AFTER4"
assert_eq "4d: ...the file itself survives" "yes" "$([ -f "$LEASE4" ] && echo yes || echo no)"
rm -f "$LEASE4"

# META-TEST 4: make the confirmed-live branch unreachable and prove the SAME
# ancient-but-alive fixture then reads STALE again — the exact symptom this
# fix removes. Mutating the confirmed_live CONDITION itself to an impossible
# comparison (`= "never"`, a value this variable is never actually set to)
# makes the fixture fall through to the STALE branch unconditionally.
MUT4=$(mktemp -t tree-lease-mut4.XXXXXX)
# shellcheck disable=SC2016  # single quotes intentional, see META-TEST 3's note.
_M4_SEARCH='if [ "$confirmed_live" = "yes" ]; then'
# shellcheck disable=SC2016
_M4_REPLACE='if [ "$confirmed_live" = "never" ]; then'
awk_mutate "$_M4_SEARCH" "$_M4_REPLACE" "$MUT4"
rc_hit=$?
assert_eq "META 4: the mutation actually landed (non-vacuity: the confirmed_live guard is gone)" "0" "$rc_hit"
bash -n "$MUT4" 2>/dev/null
assert_eq "META 4: mutant copy still parses" "0" "$?"
(
    # shellcheck disable=SC2086
    unset -f $LIB_FUNCS 2>/dev/null
    # shellcheck disable=SC1090
    . "$MUT4"
    D4M="$WORK/t4m"; mkdir -p "$D4M/leases"
    printf 'tier=L2\nlabel=old\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
        "$$" "$(hostname 2>/dev/null || echo h)" "$(self_started_at)" > "$D4M/leases/lease.L2.x"
    touch -t 202001010000 "$D4M/leases/lease.L2.x" 2>/dev/null || touch -d '2020-01-01' "$D4M/leases/lease.L2.x" 2>/dev/null
    lease_conflicts "$D4M" "" | grep -o '^[A-Z-]*' | head -1
) > "$WORK/meta4.out" 2>/dev/null
assert_eq "META 4: without the confirmed_live guard, an ancient-but-alive lease reads STALE again (specific misbehaviour)" \
    "STALE" "$(cat "$WORK/meta4.out")"
rm -f "$MUT4"

# ---------------------------------------------------------------------------
# 4b. A pid that IS alive (kill -0 succeeds) but whose recorded started_at
# does NOT match that pid's own measured elapsed runtime classifies STALE,
# never LIVE, regardless of age — the OS only recycles a pid number after
# the original process fully exits, so a mismatch here is proof the
# ORIGINAL owner died and something unrelated now holds the same pid, not
# proof of continued life.
D4B="$WORK/t4b"; mkdir -p "$D4B/leases"
LEASE4B="$D4B/leases/lease.L1.recycled"
# A started_at far in the past relative to THIS pid's actual (short) elapsed
# runtime — exactly the shape a genuinely recycled pid would leave behind
# (the lease file remembers when the ORIGINAL, now-dead, owner started).
{
    printf 'tier=L1\nlabel=recycled\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
        "$$" "$(hostname 2>/dev/null || echo h)" "$(( $(date +%s) - 999999 ))"
} > "$LEASE4B"
OUT4B=$(lease_conflicts "$D4B" "")
assert_eq "4b-a: an alive pid whose started_at does not match its measured elapsed runtime (pid reuse) classifies STALE, not LIVE" \
    "yes" "$(printf '%s\n' "$OUT4B" | grep -q '^STALE.*owner_pid='"$$"'\b' && echo yes || echo no)"
assert_eq "4b-b: _lease_pid_start_matches itself reports the mismatch directly" \
    "no" "$(_lease_pid_start_matches "$$" "$(( $(date +%s) - 999999 ))" "$(date +%s)")"
assert_eq "4b-c restore: _lease_pid_start_matches reports a match for an accurate started_at" \
    "yes" "$(_lease_pid_start_matches "$$" "$(self_started_at)" "$(date +%s)")"
rm -f "$LEASE4B"

# META-TEST 4b: disable just the pid-reuse comparison (fall through to
# "confirmed live" unconditionally whenever kill -0 succeeds, the pre-fix
# rule) and prove the SAME recycled-pid fixture then reads LIVE forever.
MUT4B=$(mktemp -t tree-lease-mut4b.XXXXXX)
# shellcheck disable=SC2016  # single quotes intentional, see META-TEST 3's note.
_M4B_SEARCH='[ "$pid_check" != "no" ] && confirmed_live="yes"'
_M4B_REPLACE='confirmed_live="yes"'
awk_mutate "$_M4B_SEARCH" "$_M4B_REPLACE" "$MUT4B"
rc_hit=$?
assert_eq "META 4b: the mutation actually landed (non-vacuity: the pid-reuse check is disabled)" "0" "$rc_hit"
bash -n "$MUT4B" 2>/dev/null
assert_eq "META 4b: mutant copy still parses" "0" "$?"
(
    # shellcheck disable=SC2086
    unset -f $LIB_FUNCS 2>/dev/null
    # shellcheck disable=SC1090
    . "$MUT4B"
    D4BM="$WORK/t4bm"; mkdir -p "$D4BM/leases"
    printf 'tier=L1\nlabel=recycled\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
        "$$" "$(hostname 2>/dev/null || echo h)" "$(( $(date +%s) - 999999 ))" > "$D4BM/leases/lease.L1.x"
    lease_conflicts "$D4BM" "" | grep -o '^[A-Z-]*' | head -1
) > "$WORK/meta4b.out" 2>/dev/null
assert_eq "META 4b: without the pid-reuse check, a recycled pid reads LIVE forever (specific misbehaviour)" \
    "LIVE" "$(cat "$WORK/meta4b.out")"
rm -f "$MUT4B"

# ---------------------------------------------------------------------------
# 4c. claude-workflow-plugin-gsfd R6-F4: the UNKNOWN elapsed-runtime path —
# kill -0 succeeds but the elapsed-runtime check itself could not be
# completed (no usable `ps`), so _lease_pid_start_matches returns "unknown"
# rather than a definite "yes"/"no". Its own contract is "cannot rule out a
# match", and lease_conflicts's conversion (`!= "no"`, not `= "yes"`) maps
# that to confirmed-live — a HEDGED LIVE, same bucket as a confirmed match,
# never STALE. Missing before this fix: 4 above exercises "yes" and 4b
# exercises "no", but nothing exercised "unknown" at all. A minimal `ps`
# double placed FIRST on PATH (the rest of PATH is untouched, so every other
# external command this function needs still resolves normally) simulates
# the unusable-ps case without touching the real environment.
mkdir -p "$WORK/fakeps-bin"
cat > "$WORK/fakeps-bin/ps" <<'SHIM'
#!/bin/bash
# Unusable `ps` double for the unknown-path leg: exits non-zero with no
# output, simulating a minimal ps build that cannot answer `-o etime=` at
# all. Restore-control purposes only -- the real ps on this same box is
# used, unstubbed, everywhere else in this file.
exit 1
SHIM
chmod +x "$WORK/fakeps-bin/ps"
assert_eq "4c precondition: the stubbed PATH makes _lease_pid_elapsed_s genuinely fail for this shell's own (alive) pid (non-vacuity: the mutation of state landed)" \
    "yes" "$(PATH="$WORK/fakeps-bin:$PATH" _lease_pid_elapsed_s "$$" >/dev/null 2>&1 && echo no || echo yes)"
assert_eq "4c precondition: with elapsed runtime unmeasurable, _lease_pid_start_matches reports unknown (neither yes nor no)" \
    "unknown" "$(PATH="$WORK/fakeps-bin:$PATH" _lease_pid_start_matches "$$" "$(self_started_at)" "$(date +%s)")"

D4C="$WORK/t4c"; mkdir -p "$D4C/leases"
LEASE4C="$D4C/leases/lease.L1.unknownps"
{
    printf 'tier=L1\nlabel=unknown-ps\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
        "$$" "$(hostname 2>/dev/null || echo h)" "$(self_started_at)"
} > "$LEASE4C"
OUT4C=$(PATH="$WORK/fakeps-bin:$PATH" lease_conflicts "$D4C" "")
assert_eq "4c-a: an alive pid whose elapsed runtime cannot be measured (unknown) classifies LIVE, hedged, matching _lease_pid_start_matches's own contract" \
    "yes" "$(printf '%s\n' "$OUT4C" | grep -q '^LIVE .*owner_pid='"$$"'\b' && echo yes || echo no)"
assert_eq "4c-b: ...and is NEVER classified STALE" \
    "no" "$(printf '%s\n' "$OUT4C" | grep -q '^STALE.*owner_pid='"$$"'\b' && echo yes || echo no)"
rm -f "$LEASE4C"

# META-TEST 4c: narrow the conversion to accept ONLY a confirmed "yes",
# rejecting "unknown" the same way it already rejects "no" — the false
# negative a caller who ignored _lease_pid_start_matches's own "cannot rule
# out a match" contract would introduce — and prove the SAME unknown-ps
# fixture then reads STALE.
MUT4C=$(mktemp -t tree-lease-mut4c.XXXXXX)
# shellcheck disable=SC2016  # single quotes intentional, see META-TEST 3's note.
_M4C_SEARCH='[ "$pid_check" != "no" ] && confirmed_live="yes"'
# shellcheck disable=SC2016
_M4C_REPLACE='[ "$pid_check" = "yes" ] && confirmed_live="yes"'
awk_mutate "$_M4C_SEARCH" "$_M4C_REPLACE" "$MUT4C"
rc_hit=$?
assert_eq "META 4c: the mutation actually landed (non-vacuity: the conversion now requires a literal yes)" "0" "$rc_hit"
bash -n "$MUT4C" 2>/dev/null
assert_eq "META 4c: mutant copy still parses" "0" "$?"
(
    # shellcheck disable=SC2086
    unset -f $LIB_FUNCS 2>/dev/null
    # shellcheck disable=SC1090
    . "$MUT4C"
    D4CM="$WORK/t4cm"; mkdir -p "$D4CM/leases"
    printf 'tier=L1\nlabel=unknown-ps\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
        "$$" "$(hostname 2>/dev/null || echo h)" "$(self_started_at)" > "$D4CM/leases/lease.L1.x"
    PATH="$WORK/fakeps-bin:$PATH" lease_conflicts "$D4CM" "" | grep -o '^[A-Z-]*' | head -1
) > "$WORK/meta4c.out" 2>/dev/null
assert_eq "META 4c: requiring a literal yes (rejecting unknown) makes the SAME unknown-ps fixture read STALE — the exact hedge this leg protects (specific misbehaviour)" \
    "STALE" "$(cat "$WORK/meta4c.out")"
rm -f "$MUT4C"

# ---------------------------------------------------------------------------
# 5. Self-exclusion.
D5="$WORK/t5"; mkdir -p "$D5"
L5=$(lease_acquire "$D5" "L1" "self")
assert_eq "5a: passing self excludes the caller's own lease" \
    "" "$(lease_conflicts "$D5" "$L5")"
assert_eq "5b: passing self=\"\" includes it" \
    "yes" "$(lease_conflicts "$D5" "" | grep -q "$L5"'$' && echo yes || echo no)"
lease_release "$L5"

# ---------------------------------------------------------------------------
# 6. Reclaim removes STALE, leaves LIVE (non-vacuity via file counts) —
# called EXPLICITLY here. There is no threshold parameter to pass any more
# (DESIGN COLLAPSE, round 6): a dead pid is STALE from the moment its lease
# exists, so a fresh-mtime dead pid is already reclaimable without
# fabricating an ancient mtime.
D6="$WORK/t6"; mkdir -p "$D6/leases"
L6_LIVE=$(lease_acquire "$D6" "L1" "keep me")
DP6=$(dead_pid)
printf 'tier=L1\nlabel=reclaim me\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
    "$DP6" "$(hostname 2>/dev/null || echo h)" "$(date +%s)" > "$D6/leases/lease.L1.reclaimme"
BEFORE_COUNT=$(find "$D6/leases" -type f | wc -l | tr -d ' ')
lease_reclaim_stale "$D6" >/dev/null
AFTER_COUNT=$(find "$D6/leases" -type f | wc -l | tr -d ' ')
assert_eq "6a: reclaim removed exactly one file (the stale one)" "2:1" "$BEFORE_COUNT:$AFTER_COUNT"
assert_eq "6b: the LIVE lease survives reclaim" "yes" "$([ -f "$L6_LIVE" ] && echo yes || echo no)"
assert_eq "6c: the STALE lease is gone" "yes" "$([ ! -f "$D6/leases/lease.L1.reclaimme" ] && echo yes || echo no)"
lease_release "$L6_LIVE"

# 6b. DESIGN COLLAPSE's own core behavioural change: lease_acquire does NOT
# call lease_reclaim_stale on anyone's behalf any more. A pre-existing STALE
# lease must survive an unrelated acquire call untouched -- this is the
# direct test of "the lease reports; it never auto-reclaims" from the
# operator's own directive, not an inference from reading the source.
D6B="$WORK/t6b"; mkdir -p "$D6B/leases"
DP6B=$(dead_pid)
printf 'tier=L1\nlabel=pre-existing stale\nowner_pid=%s\nowner_host=%s\nstarted_at=%s\n' \
    "$DP6B" "$(hostname 2>/dev/null || echo h)" "$(date +%s)" > "$D6B/leases/lease.L1.preexisting"
BEFORE6B=$(find "$D6B/leases" -type f | wc -l | tr -d ' ')
L6B_NEW=$(lease_acquire "$D6B" "L1" "unrelated acquire")
AFTER6B=$(find "$D6B/leases" -type f | wc -l | tr -d ' ')
assert_eq "6b-a: acquiring a NEW lease does not remove a co-located STALE one (file count grows by exactly one, the new lease, not net-zero)" \
    "yes" "$([ "$AFTER6B" -eq $((BEFORE6B + 1)) ] && echo yes || echo no)"
assert_eq "6b-b: ...the pre-existing stale lease's own file is still there, byte for byte" \
    "yes" "$([ -f "$D6B/leases/lease.L1.preexisting" ] && echo yes || echo no)"
lease_release "$L6B_NEW"
rm -f "$D6B/leases/lease.L1.preexisting"

# ---------------------------------------------------------------------------
# 7. set -e / pipefail safety on the common (zero-conflict) case, called as a
# BARE STATEMENT — the call shape that actually exposes the risk. The
# pipeline's final `grep` legitimately exits 1 on "nothing live to report",
# and under `set -o pipefail` that becomes the pipeline's own aggregate
# status. This does NOT reach production today through EITHER integrated
# call site (verify-before-stop.sh, run-tests.sh, run.sh): all three capture
# the result via `VAR=$(lease_conflict_summary ...) || VAR=""`, and bash's
# command substitution runs with `errexit` effectively suspended for its OWN
# internal execution unless `shopt -s inherit_errexit` is set (measured
# directly while pairing this test — none of the three callers, nor this
# spec's own shell, enables it). A BARE call (redirected to a file, not
# command-substitution-captured) is not shielded that way — it is the shape
# a future direct/uncaptured call, or a caller with `inherit_errexit` on,
# would use, and it is what tree-lease.sh's own ERREXIT SAFETY header note
# is about.
D7="$WORK/t7"; mkdir -p "$D7"
L7=$(lease_acquire "$D7" "L1" "only one")
(
    set -e
    set -o pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    lease_conflict_summary "$D7" "$L7" > "$WORK/bare-shipped.txt"
    echo "SURVIVED"
) > "$WORK/set-e-shipped.out" 2>&1
assert_eq "7a: lease_conflict_summary does not abort a set -e + pipefail caller, called bare, on zero conflicts" \
    "SURVIVED" "$(cat "$WORK/set-e-shipped.out")"
lease_release "$L7"

# META-TEST 7: strip the `|| true` guard from lease_conflict_summary's
# pipeline statement in a mutant copy and prove a set -e + pipefail caller
# genuinely aborts against it, over the identical BARE call shape.
MUT7=$(mktemp -t tree-lease-mut7.XXXXXX)
_M7_SEARCH="| grep '^concurrent ' 2>/dev/null || true"
_M7_REPLACE="| grep '^concurrent ' 2>/dev/null"
awk_mutate "$_M7_SEARCH" "$_M7_REPLACE" "$MUT7"
rc_hit=$?
assert_eq "META 7: the mutation actually removed the ' || true' guard (non-vacuity)" "0" "$rc_hit"
bash -n "$MUT7" 2>/dev/null
assert_eq "META 7: mutant copy still parses" "0" "$?"
(
    set -e
    set -o pipefail
    # shellcheck disable=SC1090
    . "$MUT7"
    D7M="$WORK/t7m"; mkdir -p "$D7M"
    L7M=$(lease_acquire "$D7M" "L1" "only one")
    lease_conflict_summary "$D7M" "$L7M" > "$WORK/bare-mutant.txt"
    echo "SURVIVED"
) > "$WORK/set-e-mutant.out" 2>&1
MUT_RESULT=$(cat "$WORK/set-e-mutant.out")
assert_eq "META 7: without the guard, a set -e + pipefail caller called bare genuinely aborts on zero conflicts (specific misbehaviour)" \
    "no" "$(printf '%s' "$MUT_RESULT" | grep -q '^SURVIVED' && echo yes || echo no)"
rm -f "$MUT7"

# ---------------------------------------------------------------------------
# 8. lease_acquire degrades gracefully when the lease directory cannot be
# created (a FILE sitting where the directory needs to go).
D8="$WORK/t8-is-a-file"
: > "$D8"
L8=$(lease_acquire "$D8" "L1" "should fail")
RC8=$?
assert_eq "8a: lease_acquire returns empty when the lease dir cannot be created" "" "$L8"
assert_eq "8b: lease_acquire returns non-zero in that case" \
    "nonzero" "$([ "$RC8" -ne 0 ] && echo nonzero || echo zero)"
rm -f "$D8"

# ---------------------------------------------------------------------------
# 10. lease_release's defining effect (the file is gone) — exercised many
# times in this file's own cleanup calls but was never itself ASSERTED — a
# mutant making it a no-op passed all pre-fix assertions.
D10="$WORK/t10"; mkdir -p "$D10"
L10=$(lease_acquire "$D10" "L1" "release me")
assert_eq "10a: precondition — the lease file exists before release" \
    "yes" "$([ -f "$L10" ] && echo yes || echo no)"
lease_release "$L10"
assert_eq "10b: lease_release actually removes the file" \
    "yes" "$([ ! -f "$L10" ] && echo yes || echo no)"

# META-TEST 10: a no-op lease_release leaves the file in place.
MUT10=$(mktemp -t tree-lease-mut10.XXXXXX)
# shellcheck disable=SC2016  # single quotes intentional, see META-TEST 3's note.
_M10_SEARCH='rm -f "$f" 2>/dev/null || true'
# shellcheck disable=SC2016
_M10_REPLACE=':'
awk_mutate "$_M10_SEARCH" "$_M10_REPLACE" "$MUT10"
rc_hit=$?
assert_eq "META 10: the mutation actually removed the rm -f call (non-vacuity)" "0" "$rc_hit"
bash -n "$MUT10" 2>/dev/null
assert_eq "META 10: mutant copy still parses" "0" "$?"
(
    # shellcheck disable=SC2086
    unset -f $LIB_FUNCS 2>/dev/null
    # shellcheck disable=SC1090
    . "$MUT10"
    D10M="$WORK/t10m"; mkdir -p "$D10M"
    L10M=$(lease_acquire "$D10M" "L1" "release me")
    lease_release "$L10M"
    [ -f "$L10M" ] && echo yes || echo no
) > "$WORK/meta10.out" 2>/dev/null
assert_eq "META 10: with release a no-op, the file survives its own release call (specific misbehaviour)" \
    "yes" "$(cat "$WORK/meta10.out")"
rm -f "$MUT10"

# ---------------------------------------------------------------------------
# 11. Sourcing this file must not change the CALLER's own `set -u` (nounset)
# state — the file's own header promises "nothing here mutates the caller's
# shell state". Driven as a real subprocess (`bash -c`), not a bare
# subshell: `$-` is per-shell-process state, and a subshell forked from THIS
# spec's own shell would just inherit whatever `$-` this spec already has
# (this file itself runs under `set -u`), masking the very thing under test.
BEFORE_U=$(bash -c 'set +u; printf "%s" "$-"')
AFTER_U=$(bash -c 'set +u; . "$1"; printf "%s" "$-"' _ "$LIB")
HAD_U_BEFORE="no"; case "$BEFORE_U" in *u*) HAD_U_BEFORE="yes" ;; esac
HAD_U_AFTER="no"; case "$AFTER_U" in *u*) HAD_U_AFTER="yes" ;; esac
assert_eq "11a: sourcing the shipped library does not add nounset to a caller that did not have it" \
    "$HAD_U_BEFORE" "$HAD_U_AFTER"
assert_eq "11b: ...concretely, the caller does NOT end up with nounset set" \
    "no" "$HAD_U_AFTER"

# META-TEST 11: reintroduce a file-scope `set -u` in a mutant copy (prepended
# ahead of the shipped content, which still parses fine as a harmless
# duplicate shebang comment) and prove the SAME caller-shape genuinely picks
# up nounset from sourcing it.
MUT11=$(mktemp -t tree-lease-mut11.XXXXXX)
{
    printf '#!/bin/bash\nset -u\n'
    cat "$LIB"
} > "$MUT11"
rc_hit=1
head -2 "$MUT11" | grep -qx 'set -u' && rc_hit=0
assert_eq "META 11: the mutation actually added a file-scope set -u (non-vacuity)" "0" "$rc_hit"
bash -n "$MUT11" 2>/dev/null
assert_eq "META 11: mutant copy still parses" "0" "$?"
AFTER_U_MUT=$(bash -c 'set +u; . "$1"; printf "%s" "$-"' _ "$MUT11")
HAD_U_AFTER_MUT="no"; case "$AFTER_U_MUT" in *u*) HAD_U_AFTER_MUT="yes" ;; esac
assert_eq "META 11: with a file-scope set -u restored, the SAME caller-shape DOES pick up nounset (specific misbehaviour)" \
    "yes" "$HAD_U_AFTER_MUT"
rm -f "$MUT11"

# ---------------------------------------------------------------------------
# 12. lease_acquire's started_at must be THIS pid's actual OS start time,
# not the moment lease_acquire happened to be called — verify-before-stop.sh
# alone does substantial work (task detection, doc-only classification,
# escalation checks, DETECT_STACK) between its own process start and
# reaching lease_acquire, and high-contention conditions stretch that gap
# furthest. Recording the call moment would make a caller's OWN fresh,
# legitimate lease look like a pid-reuse mismatch to any concurrent checker
# moments later, once that gap exceeds _lease_pid_start_matches's 5s
# tolerance — DIRECTLY measured below with a real (bounded, 7s) delay, not
# simulated, because this is exactly the kind of property that cannot be
# faked by backdating a file's mtime: it is about this PROCESS's real,
# OS-measured elapsed runtime.
D12="$WORK/t12"; mkdir -p "$D12"
sleep 7
L12=$(lease_acquire "$D12" "stop-hook" "simulated slow preamble")
OUT12=$(lease_conflicts "$D12" "")
assert_eq "12a: a lease acquired after a 7s preamble still reads LIVE to a concurrent checker moments later" \
    "yes" "$(printf '%s\n' "$OUT12" | grep -q '^LIVE ' && echo yes || echo no)"
lease_release "$L12"

# META-TEST 12: revert started_at to the acquire MOMENT (the pre-correction
# shape) and prove the IDENTICAL 7s-preamble scenario then reads STALE — a
# live, legitimate lease misread as pid-reuse purely because of how long the
# caller took to reach lease_acquire.
MUT12=$(mktemp -t tree-lease-mut12.XXXXXX)
# shellcheck disable=SC2016  # single quotes intentional, see META-TEST 3's note.
_M12_SEARCH='*) started=$((started - acquire_elapsed)) ;;'
_M12_REPLACE='*) : ;; # started_at correction neutered by META-TEST 12'
awk_mutate "$_M12_SEARCH" "$_M12_REPLACE" "$MUT12"
rc_hit=$?
assert_eq "META 12: the mutation actually landed (non-vacuity: the started_at correction is gone)" "0" "$rc_hit"
bash -n "$MUT12" 2>/dev/null
assert_eq "META 12: mutant copy still parses" "0" "$?"
(
    # shellcheck disable=SC2086
    unset -f $LIB_FUNCS 2>/dev/null
    # shellcheck disable=SC1090
    . "$MUT12"
    D12M="$WORK/t12m"; mkdir -p "$D12M"
    sleep 7
    lease_acquire "$D12M" "stop-hook" "simulated slow preamble" >/dev/null
    lease_conflicts "$D12M" "" | grep -o '^[A-Z-]*' | head -1
) > "$WORK/meta12.out" 2>/dev/null
assert_eq "META 12: without the correction, the SAME 7s-preamble lease reads STALE, not LIVE (specific misbehaviour — a live lease fails to read as confirmed-alive purely because of preamble timing)" \
    "STALE" "$(cat "$WORK/meta12.out")"
rm -f "$MUT12"

# ---------------------------------------------------------------------------
# 13. lease_release must survive a failing `rm -f` under a `set -e` +
# bare-call caller — the exact shape verify-before-stop.sh uses it in (see
# tree-lease.sh's own docstring for lease_release). `rm -f` reliably fails
# "Is a directory" against a DIRECTORY target on both BSD and GNU rm,
# independent of privilege level — so a directory standing in for the lease
# "file" is the portable way to force the exact failure mode without relying
# on filesystem permission games. Measured directly while building this
# test: the identical bare statement WITHOUT `|| true` genuinely aborts a
# `set -e` shell before it ever reaches a later `echo`.
D13="$WORK/t13"; mkdir -p "$D13"
LEASE13_DIR="$D13/lease-is-a-directory"
mkdir -p "$LEASE13_DIR"
(
    set -e
    # shellcheck disable=SC1090
    . "$LIB"
    lease_release "$LEASE13_DIR"
    echo "SURVIVED"
) > "$WORK/set-e-release-shipped.out" 2>&1
assert_eq "13a: lease_release survives a failing rm -f (target is a directory) under a set -e + bare-call caller" \
    "SURVIVED" "$(cat "$WORK/set-e-release-shipped.out")"
assert_eq "13b: ...and the directory (which rm -f cannot remove without -r) is still there, proving the rm really did fail rather than silently succeeding" \
    "yes" "$([ -d "$LEASE13_DIR" ] && echo yes || echo no)"
rm -rf "$LEASE13_DIR"

# META-TEST 13: restore the historical bare form (no `|| true` on the rm)
# and prove the IDENTICAL scenario now genuinely aborts the set -e caller
# before it ever reaches "SURVIVED".
MUT13=$(mktemp -t tree-lease-mut13.XXXXXX)
# shellcheck disable=SC2016  # single quotes intentional, see META-TEST 3's note.
_M13_SEARCH='[ -n "$f" ] && { rm -f "$f" 2>/dev/null || true; }'
# shellcheck disable=SC2016
_M13_REPLACE='[ -n "$f" ] && rm -f "$f" 2>/dev/null'
awk_mutate "$_M13_SEARCH" "$_M13_REPLACE" "$MUT13"
rc_hit=$?
assert_eq "META 13: the mutation actually landed (non-vacuity: the || true guard is gone)" "0" "$rc_hit"
bash -n "$MUT13" 2>/dev/null
assert_eq "META 13: mutant copy still parses" "0" "$?"
LEASE13B_DIR="$WORK/t13b-lease-is-a-directory"
mkdir -p "$LEASE13B_DIR"
(
    set -e
    # shellcheck disable=SC1090
    . "$MUT13"
    lease_release "$LEASE13B_DIR"
    echo "SURVIVED"
) > "$WORK/set-e-release-mutant.out" 2>&1
MUT13_RESULT=$(cat "$WORK/set-e-release-mutant.out")
assert_eq "META 13: without the guard, the SAME failing-rm scenario genuinely aborts the set -e caller before reaching SURVIVED (specific misbehaviour)" \
    "no" "$(printf '%s' "$MUT13_RESULT" | grep -q '^SURVIVED' && echo yes || echo no)"
rm -f "$MUT13"
rm -rf "$LEASE13B_DIR"

# ---------------------------------------------------------------------------
if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

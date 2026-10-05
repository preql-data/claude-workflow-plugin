#!/bin/bash
# tree-lease.sh — shared ownership primitive. claude-workflow-plugin-gsfd.
#
# ANSWERS ONE QUESTION: who owns this tree right now? Before this task,
# nothing could answer it except an agent hand-inspecting ppid/start-time —
# claude-workflow-plugin-9xl4 recorded THREE near-misses in one session, each
# caught by an agent's care rather than by any mechanism: a timed-out Codex
# MCP call left a writer alive for 2h41m; a reviewer's own baseline overlapped
# a component tier for ~19 minutes and only noticed because it checked; a
# specialist nearly killed a QA reviewer's `run-tests.sh` processes on the
# strength of the word "stragglers" and stopped only because it happened to
# compare timestamps first.
#
# WHAT THIS IS NOT: a mutex. It cannot stop a non-participating writer (a
# human's own shell, an MCP host that never sourced this file) from touching
# the tree, and it does not try to.
#
# WHAT THIS IS: every PARTICIPATING runner (L1 run-tests.sh, L2
# .claude/tests/component/run.sh, the Stop hook's verify-before-stop.sh)
# acquires a lease before doing tree-sensitive work, and releases it when
# done. Any other participant — or a human running `bash tree-lease.sh
# status` — can read who else claims to be active, since when, and whether
# that claim is currently confirmable as alive.
#
# LEASE FILE FORMAT: plain `key=value` lines, one per file, under
# <dir>/leases/lease.<tier>.XXXXXX. No jq dependency on purpose — this file
# must be sourceable by verify-before-stop.sh, which documents its own
# graceful degradation with no jq at all (F8/J17 header).
#   tier=<L1|L2|stop-hook|...>
#   label=<free text, single line>
#   owner_pid=<pid>
#   owner_host=<hostname>
#   started_at=<epoch seconds — owner_pid's own OS start time, back-computed
#     at acquire time from its measured elapsed runtime, NOT the moment
#     lease_acquire was called (R1-F2 correction; see lease_acquire's own
#     header for why the difference matters)>
#
# ============================================================================
# DESIGN COLLAPSE (claude-workflow-plugin-gsfd, operator-directed, round 6).
# ============================================================================
# Five rounds of independent cross-family review on this task's own lease
# and heartbeat machinery produced this causal chain: R2-F1 (a lease could
# read a live cross-host owner as reclaimable) -> fixed with an UNCONFIRMED
# status -> R3-F3 (that made the ordinary same-host crash path sit
# UNCONFIRMED, rendered as a live-seeming notice, for the full 3h stale_s
# backstop) -> fixed with a heartbeat -> R4-F1/F2/F3 (the heartbeat's own
# daemon orphaned a child, then its in-process replacement reset per spec)
# -> fixed by rewriting run_with_timeout in-process -> R5-F1/F4 (the
# rewrite could itself under-report completion via setsid, and the
# heartbeat still accumulated background processes). Each fix was legitimate
# work against a real defect the previous fix had introduced. The operator's
# decision: stop fixing the chain and remove the load-bearing consequence
# that made each round's precision matter for CORRECTNESS rather than for
# message quality.
#
# THE LEASE IS NOW REPORT-ONLY. lease_acquire no longer calls
# lease_reclaim_stale. Nothing in this codebase removes a lease file on the
# strength of a liveness guess, ever, automatically. A lease whose owner
# crashed simply sits in <dir>/leases/ until something else cleans it up —
# there is no accumulation problem in practice (a handful of small text
# files), and `lease_reclaim_stale` remains defined and callable directly by
# an operator who wants to sweep them (`bash -c '. tree-lease.sh;
# lease_reclaim_stale "$dir"'`), just never invoked on anyone's behalf.
# `lease_release` is unaffected — it is the happy path, and it already
# works: a lease only ever lingers after a crash, not after an ordinary
# exit.
#
# Once nothing is ever removed on the strength of this file's own read, the
# precision that read used to need disappears with it. The four-way STALE /
# LIVE / LIVE-BUT-OLD / UNCONFIRMED split — and the two independent age
# thresholds (stale_s, dead_grace_s) that decided which of those four a
# borderline case got — existed ONLY to gate lease_reclaim_stale's own
# decision about what was safe to delete. There is no such decision left to
# drive. The grammar collapses to what a NOTICE actually needs to say:
#
#   LIVE  — this host, a recorded pid that answers `kill -0`, AND EITHER
#           that pid's own measured elapsed runtime is consistent with the
#           lease's recorded started_at (same PROCESS, not merely a reused
#           pid number) OR that measurement could not be taken at all — no
#           usable `ps` where this check ran, or the pid exited between the
#           `kill -0` above and this check. claude-workflow-plugin-gsfd
#           R6-F4: this second case is a HEDGED LIVE, not a STALE — it used
#           to read the other way in this bullet, disagreeing with both the
#           code (lease_conflicts converts anything other than a confirmed
#           MISMATCH to confirmed-live) and with _lease_pid_start_matches's
#           own header, which documents exactly this contract: an
#           unconfirmable reading is "cannot rule out a match", never a new
#           way to fail a live owner. Report-only is what makes the hedge
#           defensible — nothing is ever deleted on the strength of this
#           read, so leaning toward LIVE costs a reader one wrong word in a
#           notice at worst, while leaning toward STALE would, on a genuinely
#           live owner, look identical to the R2-F1 risk this collapse
#           otherwise removed. Age never demotes either case — a
#           long-running LIVE owner is still LIVE, for as long as the
#           process genuinely is.
#   STALE — everything else: a different host, no pid recorded, a
#           confirmed-dead pid, or a pid that now belongs to a DIFFERENT
#           process than the one that wrote the lease — a MEASURED
#           elapsed-runtime mismatch (reuse), never merely an unmeasurable
#           one. These used to need separating because getting one wrong
#           meant either deleting a genuinely live foreign owner's lease
#           (the R2-F1 risk) or leaving an ordinary crash looking alive for
#           three hours (the R3-F3 risk). Neither risk exists once nothing
#           is deleted automatically — a STALE reading that turns out to be
#           a live foreign owner now costs a reader a wrong impression from
#           a notice, not a lost lease.
#
# age_s is still printed for both statuses — "how long has this been sitting
# / how long ago did this last look confirmed" remains useful information
# for a human deciding whether to go look — but nothing in this file treats
# any age as a threshold to cross anymore. `lease_conflicts` and
# `lease_reclaim_stale` no longer take stale_s/dead_grace_s parameters; there
# is nothing left for them to gate.
#
# The heartbeat this design collapse retires (`lease_heartbeat`, previously
# called every ~30s from run-tests.sh, component/run.sh, and
# verify-before-stop.sh's run_with_timeout) existed ONLY to keep a
# genuinely-alive owner's mtime fresh enough to clear dead_grace_s quickly
# and to keep a genuinely-alive foreign owner's collision-risk window short.
# Neither purpose survives report-only: age no longer gates anything, so
# there is nothing left for a heartbeat to protect. It has been deleted from
# every caller AND from this file — R4-F3, R5-F2, and R5-F4 (all findings
# about the heartbeat's own cost or correctness) are moot by removal, not by
# further patching.
#
# KNOWN LIMITATION, unchanged by this round: hostname equality is the only
# same-host signal this file uses, and it is not proof of MACHINE identity —
# two genuinely different hosts or containers that happen to report the
# identical hostname string will each treat the other's lease as same-host.
# A local `kill -0` against a foreign pid reliably fails (or, rarer,
# coincidentally matches an unrelated local process holding the same pid
# number), so a genuinely-live remote owner sharing this hostname string can
# read STALE here. Under the old design that mattered for correctness (it
# risked an auto-delete of a live lease); under report-only it costs a
# reader one wrong word in a notice, which is the entire reason this
# collapse is safe to make.
#
# Functions (source this file; nothing here mutates the caller's shell state,
# unlike mk_fixture's documented CLAUDE_PROJECT_DIR/PATH export convention —
# every value comes back as a return-on-stdout):
#   lease_acquire <dir> <tier> <label>
#       Creates a new lease file (no self-heal step anymore — see DESIGN
#       COLLAPSE above) and prints its PATH on stdout. Prints "" and returns
#       1 on total failure (e.g. <dir>/leases not creatable) — callers must
#       treat that as "proceed without a lease", never as a reason to abort
#       the run.
#   lease_release <lease_file>
#       `rm -f`. Best-effort; always returns 0 — INCLUDING when the rm
#       itself fails (R2-F3: a bare trailing `return 0` is not enough under
#       a caller's `set -e`; see ERREXIT SAFETY below).
#   lease_conflicts <dir> <self_lease_file>
#       One line per OTHER lease on record (self excluded by path match; pass
#       "" to include everything), each prefixed LIVE or STALE, with the
#       owner fields and age (see DESIGN COLLAPSE above). Empty output = no
#       other lease recorded. Always returns 0 — a directory that does not
#       exist yet is "no leases", not an error.
#   lease_reclaim_stale <dir>
#       Removes every lease lease_conflicts classifies STALE and prints one
#       RECLAIMED line per file actually removed. NOT called automatically
#       by anything in this codebase (see DESIGN COLLAPSE above) — an
#       explicit, standalone operator action only. Always returns 0.
#   lease_conflict_summary <dir> <self_lease_file>
#       Same as lease_conflicts but LIVE only (STALE is never surfaced here
#       — a reader gets told about active-seeming conflicts, not about
#       everything this file has ever seen), reworded for direct inclusion
#       in an operator-facing message (member 2's hedge, and the L1/L2
#       concurrent-run notice). Empty output = nothing to report.
#
# ERREXIT SAFETY — A TRAILING `return 0` IS NOT ENOUGH ON ITS OWN. This was
# measured wrong once while pairing this file's own test (tree-lease.test.sh
# META-TEST 7): under a caller with `set -e` AND `set -o pipefail` active, a
# bare pipeline STATEMENT that fails trips errexit at that statement,
# immediately — a `return 0` two lines later never runs, because the
# function never reaches it. `lease_conflict_summary`'s pipeline ends in a
# `grep` stage that legitimately exits 1 on the COMMON case (nothing live to
# report), and pipefail makes that the pipeline's own aggregate exit status
# even though later stages exit 0. The fix is `|| true` on the PIPELINE
# STATEMENT ITSELF, not on the function's tail.
#
# WHERE THIS ACTUALLY BITES, PRECISELY (measured, not assumed, while pairing
# tree-lease.test.sh): every integrated caller captures the result via
# `VAR=$(lease_conflict_summary ...) || VAR=""`, and bash's command
# substitution runs with `errexit` effectively SUSPENDED for its OWN internal
# execution unless `shopt -s inherit_errexit` is set — none of the three
# callers (or their shells) enable it, so a failing internal pipeline there
# does not abort anything; the function simply keeps running and reaches its
# own `return 0` regardless of the guard. The guard matters for a BARE call
# (no command substitution around it — a future direct/uncaptured use, or a
# caller with `inherit_errexit` on): THERE, under `set -e` + `pipefail`, a
# failing pipeline statement aborts the function immediately, before any
# later `return 0` is ever reached. So: currently latent rather than observed
# in production through the shipped call sites, but a real defect in the
# function's own behaviour under the call shape its docstring promises is
# safe for ("Always returns 0"), and cheap enough to fix regardless of which
# callers happen to be shielded today.
#
# PORTABILITY. Three mac/Linux traps this file deliberately avoids:
#   - mtime-as-epoch: GNU `stat -c %Y` MUST be tried before BSD `stat -f %m`.
#     BSD's `-f` is not a clean no-op under GNU stat, where `-f` means
#     --file-system and takes no format argument — `%m` and the path parse as
#     two OPERANDS, `%m` errors but the path succeeds and prints filesystem
#     info beginning `File: "..."` on stdout, so a naive `||` fallback
#     concatenates that garbage onto the "real" reading instead of skipping
#     to it. GNU-first fails cleanly on BSD (usage to stderr, nothing on
#     stdout) in both directions. Convention lifted from
#     .claude/scripts/tests/workflow-doctor.test.sh, which measured the CI
#     crash this ordering prevents; re-verified directly on this box (macOS):
#     `stat -c %Y <path>` -> `stat: illegal option -- c` (exit 1, nothing on
#     stdout), `stat -f %m <path>` -> a clean epoch integer. On total
#     failure (neither form works — e.g. the path vanished between the
#     caller's own listing and this read) the helper prints EMPTY, never a
#     numeric sentinel: an earlier version printed literal '0', which is
#     indistinguishable from a real epoch-zero mtime to the sanitiser
#     downstream (`case ... in ''|*[!0-9]*)`) and silently forced maximum
#     age, i.e. an unmeasurable mtime read as "ancient" instead of as
#     "unknown, treat as now" (R1-F3).
#   - RANDOM/mktemp fallback: `$RANDOM` is a bash builtin present since 3.2
#     (macOS's shipped bash), so the mktemp-less fallback path needs no new
#     dependency.
#   - pid start-time verification: `ps -o etime=` is used rather than the
#     GNU-only `ps -o etimes=` (plain integer seconds) BECAUSE `etime` is the
#     one keyword BSD and GNU ps actually agree on — its
#     `[[dd-]hh:]mm:ss` format is parsed by hand (_lease_pid_elapsed_s)
#     instead of reaching for a second stat-style GNU/BSD fork. Verified
#     directly on this box (macOS/BSD ps): `ps -o etime= -p <pid>` returns
#     "00:00" for a fresh process and "29-23:03:44" (the `dd-hh:mm:ss` shape)
#     for a month-old one — both parsed by the same case-based split. `ps
#     -o etimes=` on the same box fails outright ("etimes: keyword not
#     found"), confirming it is not a safe primary choice here.
#
# NOTE: there is deliberately no file-scope `set -u` here — see the R1-F5
# fix note at the bottom of this file, next to the one place `set -u` is
# now applied.

_lease_hostname() {
    hostname 2>/dev/null || printf 'unknown-host'
    return 0
}

_lease_now() {
    date +%s 2>/dev/null || printf '0'
    return 0
}

_lease_mtime_epoch() {
    local file="$1"
    # R1-F3 fix: empty, never '0', on total failure — see the mtime-as-epoch
    # PORTABILITY bullet above for why '0' was unsafe as a sentinel here.
    stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || printf ''
    return 0
}

_lease_field() {
    local file="$1" key="$2"
    grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2-
    return 0
}

# _lease_pid_elapsed_s <pid> -- this host's own measurement of how many
# seconds <pid> has been running, via `ps -o etime=` (see the PORTABILITY
# note above for why this keyword, not `etimes`). Prints nothing and returns
# 1 if <pid> is not found (already exited) or `ps` itself is unusable (e.g.
# a minimal container's busybox ps lacking -o support).
_lease_pid_elapsed_s() {
    local pid="$1" raw days=0 hh=0 mm ss
    raw=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ -z "$raw" ] && { printf ''; return 1; }
    case "$raw" in
        *-*) days="${raw%%-*}"; raw="${raw#*-}" ;;
    esac
    case "$raw" in
        *:*:*) hh="${raw%%:*}"; raw="${raw#*:}" ;;
    esac
    mm="${raw%%:*}"
    ss="${raw#*:}"
    case "${days}${hh}${mm}${ss}" in
        ''|*[!0-9]*) printf ''; return 1 ;;
    esac
    # 10# forces base-10: a zero-padded field like "09" is an invalid octal
    # literal and would otherwise abort the arithmetic expression.
    printf '%s' "$((10#$days * 86400 + 10#$hh * 3600 + 10#$mm * 60 + 10#$ss))"
    return 0
}

# _lease_pid_start_matches <pid> <recorded_started_at> <now> -- claude-
# workflow-plugin-gsfd R1-F2 fix. "yes" if <pid>'s CURRENT holder has an
# actual elapsed runtime consistent with having started at
# <recorded_started_at>; "no" if it demonstrably does not (pid reuse: a
# different, newer process holds this pid number now); "unknown" if elapsed
# runtime could not be measured (no usable `ps`, or the process exited
# between the caller's own kill -0 and this check). Callers MUST treat
# "unknown" as "cannot rule out a match" (degrade to the pre-fix kill -0-only
# trust level), never as a new failure mode — a capability that cannot
# always confirm liveness must not make an already-confirmable case worse
# than before it existed.
#
# The 5s tolerance absorbs measurement skew: <recorded_started_at> and <now>
# are two separate `date +%s` reads (acquire time vs. this check's own
# caller), and `ps -o etime=` is whole-second-rounded — both are ordinary
# clock/sampling jitter, not a timeout being widened.
_lease_pid_start_matches() {
    local pid="$1" started="$2" now="$3" observed expected diff
    case "$started" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
    observed=$(_lease_pid_elapsed_s "$pid") || { printf 'unknown'; return 0; }
    case "$observed" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
    expected=$((now - started))
    [ "$expected" -lt 0 ] 2>/dev/null && expected=0
    diff=$((expected - observed))
    [ "$diff" -lt 0 ] && diff=$((-diff))
    if [ "$diff" -le 5 ]; then
        printf 'yes'
    else
        printf 'no'
    fi
    return 0
}

lease_acquire() {
    local dir="$1" tier="$2" label="$3"
    local lease_dir lease_file pid host started clean_label acquire_elapsed
    lease_dir="$dir/leases"
    mkdir -p "$lease_dir" 2>/dev/null || { printf ''; return 1; }
    pid=$$
    host=$(_lease_hostname)
    started=$(_lease_now)
    # R1-F2 fix, correction (same review round, caught while re-checking the
    # shipped fix against a REAL caller rather than only the test fixtures):
    # started_at must record this PID's actual OS start time, not the moment
    # THIS CALL happened to run. verify-before-stop.sh alone does substantial
    # work (task detection, doc-only classification, escalation checks,
    # DETECT_STACK) between its own process start and reaching this call —
    # exactly the high-contention conditions this batch targets are the ones
    # that stretch that gap furthest. Recording the acquire MOMENT here would
    # make _lease_pid_start_matches's own tolerance window (5s) misfire on
    # that gap: a caller whose preamble took longer than the tolerance would
    # have its own fresh, legitimate lease read as a pid-reuse mismatch by
    # ANY concurrent checker moments later. Back-computed the same way
    # _lease_pid_start_matches verifies it later — now minus this pid's own
    # measured elapsed runtime — so started_at is a STABLE fact about the
    # process (true for its whole life) rather than a fact about when this
    # function happened to be called. Falls back to the acquire moment only
    # if elapsed runtime cannot be measured at all (no usable `ps`) —
    # degrading to the pre-fix behaviour, never to something worse.
    acquire_elapsed=$(_lease_pid_elapsed_s "$pid" 2>/dev/null) || acquire_elapsed=""
    case "$acquire_elapsed" in
        ''|*[!0-9]*) ;;
        *) started=$((started - acquire_elapsed)) ;;
    esac
    clean_label=$(printf '%s' "$label" | tr '\n' ' ')
    lease_file=""
    if command -v mktemp >/dev/null 2>&1; then
        # X's MUST be the last characters of the template — nothing after
        # them. BSD/macOS mktemp does not substitute a trailing suffix after
        # the X run (measured: `mktemp foo.XXXXXX.lease` creates the LITERAL
        # path "foo.XXXXXX.lease" unchanged, rc=0, no randomisation at all —
        # so a second acquire for the same tier would silently collide with
        # or overwrite the first, defeating the one property this function
        # exists to provide). GNU mktemp tolerates a trailing suffix, but
        # dropping it entirely is the one template shape that is correct on
        # BOTH platforms, so that is what ships. "lease." is a PREFIX instead,
        # keeping the population globbable as `lease.*` in lease_conflicts.
        lease_file=$(mktemp "$lease_dir/lease.${tier}.XXXXXX" 2>/dev/null) || lease_file=""
    fi
    if [ -z "$lease_file" ]; then
        lease_file="$lease_dir/lease.${tier}.pid${pid}.${started}.${RANDOM:-0}"
    fi
    {
        printf 'tier=%s\n' "$tier"
        printf 'label=%s\n' "$clean_label"
        printf 'owner_pid=%s\n' "$pid"
        printf 'owner_host=%s\n' "$host"
        printf 'started_at=%s\n' "$started"
    } > "$lease_file" 2>/dev/null || { printf ''; return 1; }
    printf '%s' "$lease_file"
    return 0
}

lease_release() {
    local f="$1"
    # claude-workflow-plugin-gsfd fix round 2 (R2-F3, sol-codex review): a
    # bare `[ -n "$f" ] && rm -f "$f"` is not always-0 despite the docstring
    # promise above -- when `-n "$f"` is true, the STATEMENT's own exit
    # status becomes rm's, and a failing rm (the lease directory's
    # permissions changing mid-suite, a read-only remount, anything that
    # makes unlink() fail) makes this whole line nonzero. verify-before-
    # stop.sh calls this bare under its own `set -e`: that nonzero status
    # aborted the CALLER right here, before the `return 0` two lines down
    # was ever reached -- silently, with no JSON ever emitted. A Stop hook
    # that produces no output is NON-BLOCKING, so the failure direction was
    # release-on-error, the worst direction available. `|| true` on the rm
    # itself (not just a trailing `return 0`) is what closes it -- the exact
    # reasoning lease_conflict_summary's own ERREXIT SAFETY header already
    # gives for why a trailing `return 0` alone is not enough under a bare,
    # uncaptured call.
    [ -n "$f" ] && { rm -f "$f" 2>/dev/null || true; }
    return 0
}

lease_conflicts() {
    local dir="$1" self="${2:-}"
    local lease_dir f now my_host
    local pid host tier label started mtime age status confirmed_live pid_check
    lease_dir="$dir/leases"
    [ -d "$lease_dir" ] || return 0
    now=$(_lease_now)
    my_host=$(_lease_hostname)
    for f in "$lease_dir"/lease.*; do
        [ -e "$f" ] || continue
        if [ -n "$self" ] && [ "$f" = "$self" ]; then
            continue
        fi
        pid=$(_lease_field "$f" owner_pid)
        host=$(_lease_field "$f" owner_host)
        tier=$(_lease_field "$f" tier)
        label=$(_lease_field "$f" label)
        started=$(_lease_field "$f" started_at)
        mtime=$(_lease_mtime_epoch "$f")
        case "$mtime" in ''|*[!0-9]*) mtime="$now" ;; esac
        age=$((now - mtime))
        [ "$age" -lt 0 ] 2>/dev/null && age=0
        confirmed_live="no"
        if [ "$host" = "$my_host" ] && [ -n "$pid" ]; then
            if kill -0 "$pid" 2>/dev/null; then
                # claude-workflow-plugin-gsfd R1-F2 fix: kill -0 succeeding
                # only proves SOME process holds this pid right now, not
                # that it is the SAME process that wrote this lease —
                # started_at is cross-checked against the CURRENT holder's
                # actual elapsed runtime; a mismatch means a different
                # process now owns this pid number (reuse), which is not
                # confirmed-live.
                pid_check=$(_lease_pid_start_matches "$pid" "$started" "$now")
                # claude-workflow-plugin-gsfd R6-F4: "!= no" (not "= yes") is
                # deliberate — it accepts BOTH a confirmed match ("yes") and
                # an unconfirmable reading ("unknown": no usable `ps`, or the
                # pid exited between the `kill -0` above and this check) as
                # confirmed-live, and rejects only a confirmed MISMATCH
                # ("no"). "unknown" is a HEDGED live, per
                # _lease_pid_start_matches's own contract ("cannot rule out a
                # match", never a new way to fail a live owner) — this line,
                # the file's own LIVE/STALE header above, and CHANGELOG.md
                # all now say so; this is the third time code and docs have
                # disagreed on this exact grammar (R3-F4, section 16, R6-F4)
                # — if you touch this line, touch those two too.
                [ "$pid_check" != "no" ] && confirmed_live="yes"
            fi
        fi
        # DESIGN COLLAPSE (round 6): confirmed-live is LIVE, unconditionally
        # and regardless of age — the ONLY case the old grammar ever let age
        # override was a confirmed-live positive turning STALE past stale_s,
        # which was itself the R1-F3 bug this file no longer has any way to
        # reintroduce (there is no age check on this branch at all now).
        # Everything else — dead, reused, or cross-host — is STALE, and so is
        # a same-host pid whose elapsed runtime was MEASURED not to match
        # (reuse). An UNVERIFIABLE reading is not in this list (R6-F4
        # correction: it used to be, which contradicted the confirmed_live
        # assignment two lines above) — it is a hedged LIVE, same bucket as a
        # confirmed match. Age is reported (below) as information only; no
        # threshold of any kind decides the word.
        if [ "$confirmed_live" = "yes" ]; then
            status="LIVE"
        else
            status="STALE"
        fi
        printf '%s tier=%s label=%s owner_pid=%s owner_host=%s started_at=%s age_s=%s lease_file=%s\n' \
            "$status" "${tier:-?}" "${label:-?}" "${pid:-?}" "${host:-?}" "${started:-?}" "$age" "$f"
    done
    return 0
}

lease_reclaim_stale() {
    local dir="$1"
    local line lf
    # `|| true` on the pipeline itself, same reasoning as
    # lease_conflict_summary: lease_conflicts always returns 0 by construction
    # and a `while read` loop that ends normally (EOF, no break/return inside)
    # returns 0 regardless of the read that failed to end it — belt-and-
    # braces against a FUTURE change to either side rather than an active
    # defect.
    lease_conflicts "$dir" "" | while IFS= read -r line; do
        case "$line" in
            STALE*)
                lf=$(printf '%s\n' "$line" | sed -n 's/.*lease_file=//p')
                if [ -n "$lf" ] && [ -f "$lf" ]; then
                    rm -f "$lf" 2>/dev/null && printf 'RECLAIMED %s\n' "$line"
                fi
                ;;
        esac
    done || true
    return 0
}

lease_conflict_summary() {
    local dir="$1" self="${2:-}"
    # `|| true` guards THIS STATEMENT directly — a trailing `return 0` alone
    # is not enough (measured while pairing this function's own test): under
    # a caller with `set -e` AND `set -o pipefail` active, a bare pipeline
    # statement that fails trips errexit AT THAT STATEMENT, before a later
    # `return 0` is ever reached. The final `grep` stage legitimately exits 1
    # on the COMMON case (no live conflict to report), and pipefail makes that
    # the pipeline's own aggregate status even though earlier stages exit 0.
    #
    # DESIGN COLLAPSE (round 6): STALE is never surfaced here — a reader is
    # told about conflicts that look ACTIVE, not about every lease this file
    # has ever seen sit around after a crash. STALE lines match neither
    # substitution below and are dropped by the final grep, same as before.
    lease_conflicts "$dir" "$self" \
        | sed -e 's/^LIVE /concurrent /' \
        | grep '^concurrent ' 2>/dev/null || true
    return 0
}

# Direct-execution CLI: `bash tree-lease.sh status [dir]` answers "who owns
# this tree right now" as a plain read, no sourcing needed. Standard
# sourced-vs-executed idiom: BASH_SOURCE[0] (this file's own path) equals $0
# (the invoked script's path) only when run directly, never when sourced
# into another script's shell.
#
# `set -u` is scoped to THIS block, not file-wide (R1-F5 fix, sol-codex
# review): every function above defines but never EXECUTES anything at
# source time, so a file-wide `set -u` bought this block nothing it doesn't
# already have from its own `${1:-}`/`${2:-}` defaults — its only observed
# effect was leaking into a SOURCING caller's shell, contradicting this
# file's own "nothing here mutates the caller's shell state" promise.
# Reproduced pre-fix: `bash -c 'set +u; . tree-lease.sh; printf "%s\n" "$-"'`
# printed a `$-` containing `u` even though the caller started without it.
if [ "${BASH_SOURCE[0]:-$0}" = "${0:-}" ]; then
    set -u
    case "${1:-}" in
        status)
            _cli_dir="${2:-${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/.qa-tracking}"
            _cli_out=$(lease_conflicts "$_cli_dir" "")
            if [ -z "$_cli_out" ]; then
                printf 'tree-lease: no recorded lease under %s/leases\n' "$_cli_dir"
            else
                printf '%s\n' "$_cli_out"
            fi
            ;;
        *)
            printf 'usage: tree-lease.sh status [dir]\n' >&2
            exit 2
            ;;
    esac
fi

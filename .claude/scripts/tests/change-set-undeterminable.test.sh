#!/bin/bash
# change-set-undeterminable.test.sh — claude-workflow-plugin-i8cx U1 (+ the
# verify-before-stop half of U7): a FAILED read of the change set must never
# be read as an EMPTY change set.
#
# THE DEFECT THIS FILE GUARDS AGAINST, measured live against the shipped hook
# (ee7ce328…) before the fix:
#   - `chmod 000` on a non-empty .claude/.qa-tracking/changed-files.txt made
#     the Stop hook RELEASE (`{}`, exit 0) an unreviewed change set — with the
#     FULL shipped stack, no shims: reviewable_changes()'s tracker half read
#     `done < <(sort -u "$TRACKING_FILE")`, a process substitution whose rc is
#     structurally unobservable, so the loop ran zero times.
#   - a failing `sort` (scoped to the tracker path in argv) RELEASED the same
#     way.
#   - a failing `git status --porcelain` RELEASED wherever qa-gate.sh's
#     reconcile stage was not already in front of it: `git ... | LC_ALL=C sort`
#     reports the LAST command's rc, so git's failure vanished. Nothing sits in
#     front of the VANISHED-CHANGE-SET probe (:5362), so on that path the same
#     masked failure released a LABEL_WITHOUT_RECORD Stop — reproduced at the
#     W3 drive point (detect-stack.sh, the seam approve-idempotency.sh already
#     documents) with a false "change set VANISHED" log for a tracker that
#     still held real work and was merely unreadable.
#   - an unreadable current-task.repo DISARMED the I8 cross-repo guard
#     (`get_recorded_repo`'s `|| echo ""` laundered the failure into "nothing
#     recorded" -> "no mismatch claim"), and an unreadable current-task marker
#     logged the false claim "helper file empty or missing".
#
# THE FIX SHAPE (why not pipefail): with `set -e` in force, wrapping
# reviewable_changes in `set -o pipefail` aborts AFTER earlier lines were
# already emitted — the caller reads a silently TRUNCATED change set, strictly
# worse than the empty one. Instead every producer is captured on its own line
# with an explicit rc (wtres_no_drift_in's shape), output is BUFFERED, and an
# undeterminable state is emitted as a single OUT-OF-BAND SENTINEL LINE
# (RC_UNDETERMINABLE_SENTINEL + reason) INSTEAD of the set — in-band because
# an rc cannot cross `done < <(...)` or `$( ... || true)`, which is exactly
# how both callers consume the function. Section 1c below is the leg that
# discriminates the buffered design from the pipefail design: a git-half
# failure AFTER the tracker half was computed must suppress the tracker lines
# too.
#
# SECTIONS
#   0  extraction sanity (functions + the shipped sentinel constant)
#   1  the extracted-from-shipped function, driven under `set -e`: healthy
#      union, sentinel-only on each induced failure (unreadable tracker,
#      failing git status, failing comm, failing tracker-scoped sort), the
#      1c anti-truncation discriminator, clean-empty negative control, and a
#      restore control
#   2  the SHIPPED HOOK run end-to-end as a Stop hook: ordinary block on a
#      healthy dirty sandbox; the guard's SPECIFIC block on a failing
#      tracker sort / an unreadable tracker (full stack) / a failing git
#      status (with qa-gate's reconcile stage neutralised by a stub so the
#      fault reaches the detection guard rather than the 94d block — and once
#      WITH the real qa-gate, where the assertion is only "blocks, never {}",
#      deliberately unpinned from which layer answers so this spec cannot
#      flake against qa-gate.sh's own concurrent hardening); `{}` release +
#      no sentinel byte on a clean sandbox; restore control
#   3  the VANISHED-CHANGE-SET probe at the W3 drive point (detect-stack.sh
#      is the documented seam between the hook's two change-set reads):
#      a fault injected there must KEEP the LABEL_WITHOUT_RECORD block with a
#      "probe UNDETERMINABLE" log — and a GENUINE vanish (tracker truncated,
#      as qa-gate.sh approve does) must STILL release (the gz3 anti-overreach
#      control this fix must not break)
#   4  i8cx U7, the verify-before-stop half: an unreadable current-task.repo
#      ARMS the I8 cross-repo block instead of disarming it; an absent marker
#      still degrades to single-repo behaviour; an unreadable current-task
#      marker still blocks and logs the honest "read FAILED" line; a readable
#      marker logs nothing of the kind
#   META  strip the CHANGE-SET-UNDETERMINABLE block from a COPY of the hook
#      (sentinel comments are load-bearing), prove the strip landed, and show
#      the copy RELEASES `{}` on the identical unreadable-tracker fixture the
#      shipped hook blocks on — the exact pre-fix misbehaviour, reproduced by
#      mutation, with the shipped-hook leg as the restore control
#
# Exit codes: 0 all assertions passed; 1 failures; 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
VBS="$PROJECT_DIR/.claude/scripts/verify-before-stop.sh"
DENY="$PROJECT_DIR/.claude/scripts/workflow-denylist.sh"
CTH="$PROJECT_DIR/.claude/scripts/current-task.sh"
QAG="$PROJECT_DIR/.claude/scripts/qa-gate.sh"
TREE_LEASE="$PROJECT_DIR/.claude/scripts/tree-lease.sh"

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

# assert_has <name> <needle> <haystack> — substring containment as a PASS/FAIL
# line (fixed-string match, so reasons with regex metacharacters stay safe).
assert_has() {
    local name="$1" needle="$2" haystack="$3"
    local got=no
    case "$haystack" in *"$needle"*) got=yes ;; esac
    assert_eq "$name" "yes" "$got"
}

for f in "$VBS" "$DENY" "$CTH" "$QAG"; do
    if [ ! -f "$f" ]; then
        printf 'change-set-undeterminable.test.sh: shipped script missing: %s\n' "$f" >&2
        exit 2
    fi
done

WORK=$(mktemp -d -t change-set-undet.XXXXXX)
# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    chmod -R u+w "$WORK" 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

REAL_SORT=$(command -v sort)
REAL_GIT=$(command -v git)
SENTINEL_BYTE=$(printf '\001')

# ---------------------------------------------------------------------------
# 0. Extraction: the shipped function bodies and the shipped sentinel
# constant, never a re-typed copy free to drift (the doc-only-classifier /
# scoped-log-dir convention).
LIB="$WORK/shipped-lib.sh"
{
    grep '^RC_UNDETERMINABLE_SENTINEL=' "$VBS"
    printf '\n'
    awk '/^gate_baseline_entries\(\) \{/,/^\}/' "$VBS"
    printf '\n'
    awk '/^has_git_repo\(\) \{/,/^\}/' "$VBS"
    printf '\n'
    awk '/^reviewable_changes\(\) \{/,/^\}/' "$VBS"
} > "$LIB"

assert_eq "0.1 the shipped sentinel constant was extracted" "1" \
    "$(grep -c '^RC_UNDETERMINABLE_SENTINEL=' "$LIB" | tr -d '[:space:]')"
assert_eq "0.2 the extraction defines reviewable_changes" "1" \
    "$(grep -c '^reviewable_changes() {$' "$LIB" | tr -d '[:space:]')"
assert_eq "0.3 the extraction defines gate_baseline_entries and has_git_repo" "2" \
    "$(grep -cE '^(gate_baseline_entries|has_git_repo)\(\) \{$' "$LIB" | tr -d '[:space:]')"
assert_eq "0.4 the extraction parses" "0" \
    "$(bash -n "$LIB" 2>/dev/null && echo 0 || echo 1)"
# Non-vacuity: the extracted body carries the rc-guarded tracker read this
# spec exists to exercise (if this line moves, re-anchor the spec).
# shellcheck disable=SC2016  # single quotes intentional: literal text to find
# in the extraction, not an expression for THIS shell to expand.
assert_eq "0.5 non-vacuity: the guarded tracker sort is in the extraction" "yes" \
    "$(grep -q 'tracker_lines=\$(LC_ALL=C sort -u "\$TRACKING_FILE"' "$LIB" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# Function-level fixture: a git repo whose tracker names a gitignored file
# (visible ONLY to the tracker half) and whose src/app.ts is dirty (visible
# ONLY to the git half). No gate baseline unless a case writes one.
F1="$WORK/f1"
mkdir -p "$F1/.claude/.qa-tracking" "$F1/notes" "$F1/src"
( cd "$F1" \
    && "$REAL_GIT" init -q \
    && "$REAL_GIT" config user.email t@example.com \
    && "$REAL_GIT" config user.name t \
    && printf '.claude/\nnotes/\n' > .gitignore \
    && printf 'code\n' > src/app.ts \
    && "$REAL_GIT" add .gitignore src >/dev/null \
    && "$REAL_GIT" commit -qm init >/dev/null )
printf 'x\n' > "$F1/notes/impl.ts"
printf 'edited\n' >> "$F1/src/app.ts"
printf '%s\n' "$F1/notes/impl.ts" > "$F1/.claude/.qa-tracking/changed-files.txt"

# drive_func <fixture-root> [extra-PATH-dir] — run the extracted function the
# way the hook runs it: under `set -e`, with the harness supplying the two
# pure-bash dependencies the extraction does not carry (is_tracked_change,
# workflow_self_written stays undefined behind its own [ -n ] guard).
drive_func() {
    local root="$1" xp="${2:-}"
    # PROJECT_DIR/QA_TRACKING_DIR/TRACKING_FILE are consumed inside the
    # dynamically-sourced $LIB (shellcheck cannot see into it — same reason
    # scoped-log-dir.test.sh carries this note), and the PATH prefix is
    # DELIBERATELY subshell-local: the shim must vanish when the subshell
    # exits so later legs run unshimmed.
    # shellcheck disable=SC2030,SC2031,SC2034
    (
        set -e
        [ -n "$xp" ] && PATH="$xp:$PATH"
        PROJECT_DIR="$root"
        QA_TRACKING_DIR="$root/.claude/.qa-tracking"
        TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"
        # shellcheck disable=SC1090
        . "$LIB"
        # shellcheck disable=SC2329  # invoked from inside the sourced $LIB.
        is_tracked_change() { [ -n "$1" ]; }
        reviewable_changes
    )
}

# 1a. Healthy: BOTH halves, no sentinel byte.
OUT_1A=$(drive_func "$F1"); RC_1A=$?
assert_eq "1a rc 0 on the healthy union" "0" "$RC_1A"
assert_has "1a2 tracker half present (gitignored path via tracker)" "$F1/notes/impl.ts" "$OUT_1A"
assert_has "1a3 git half present (dirty src via porcelain)" "src/app.ts" "$OUT_1A"
assert_eq "1a4 no sentinel byte in healthy output" "no" \
    "$(printf '%s' "$OUT_1A" | LC_ALL=C grep -q "$SENTINEL_BYTE" && echo yes || echo no)"

# 1b. Unreadable non-empty tracker: sentinel-only, still rc 0 under set -e.
chmod 000 "$F1/.claude/.qa-tracking/changed-files.txt"
OUT_1B=$(drive_func "$F1"); RC_1B=$?
chmod 644 "$F1/.claude/.qa-tracking/changed-files.txt"
assert_eq "1b rc stays 0 (an rc cannot cross the callers; the sentinel is the channel)" "0" "$RC_1B"
assert_eq "1b2 output starts with the sentinel" "yes" \
    "$(case "$OUT_1B" in ("$SENTINEL_BYTE"*) echo yes ;; (*) echo no ;; esac)"
assert_eq "1b3 sentinel-ONLY: exactly one line" "1" \
    "$(printf '%s\n' "$OUT_1B" | grep -c . | tr -d '[:space:]')"
assert_has "1b4 the reason names the tracker" "changed-files.txt" "$OUT_1B"

# 1c. Failing `git status` AFTER a healthy tracker half: the buffered design
# must suppress the already-computed tracker lines (the anti-truncation
# discriminator — a pipefail design emits them, then aborts).
mkdir -p "$WORK/shim-git"
cat > "$WORK/shim-git/git" <<EOG
#!/bin/bash
for a in "\$@"; do case "\$a" in status) exit 128 ;; esac; done
exec "$REAL_GIT" "\$@"
EOG
chmod +x "$WORK/shim-git/git"
OUT_1C=$(drive_func "$F1" "$WORK/shim-git")
assert_eq "1c git-status failure emits the sentinel" "yes" \
    "$(case "$OUT_1C" in ("$SENTINEL_BYTE"*) echo yes ;; (*) echo no ;; esac)"
assert_eq "1c2 ...and SUPPRESSES the tracker half computed before the fault (no truncated set)" "no" \
    "$(case "$OUT_1C" in (*"$F1/notes/impl.ts"*) echo yes ;; (*) echo no ;; esac)"
assert_has "1c3 the reason names git status" "git status" "$OUT_1C"

# 1d. Failing comm (a gate baseline must exist for the comm arm to run).
printf 'captured_by=test\n--\n M other.txt\n' > "$F1/.claude/.qa-tracking/gate-baseline"
mkdir -p "$WORK/shim-comm"
printf '#!/bin/bash\nexit 2\n' > "$WORK/shim-comm/comm"
chmod +x "$WORK/shim-comm/comm"
OUT_1D=$(drive_func "$F1" "$WORK/shim-comm")
assert_eq "1d comm failure emits the sentinel" "yes" \
    "$(case "$OUT_1D" in ("$SENTINEL_BYTE"*) echo yes ;; (*) echo no ;; esac)"
rm -f "$F1/.claude/.qa-tracking/gate-baseline"

# 1e. Failing sort, scoped to the tracker path in argv (the tracker read is
# the one sort in this walk that takes a FILE argument).
mkdir -p "$WORK/shim-sort"
cat > "$WORK/shim-sort/sort" <<EOS
#!/bin/bash
for a in "\$@"; do case "\$a" in *changed-files.txt) exit 2 ;; esac; done
exec "$REAL_SORT" "\$@"
EOS
chmod +x "$WORK/shim-sort/sort"
OUT_1E=$(drive_func "$F1" "$WORK/shim-sort")
assert_eq "1e tracker-scoped sort failure emits the sentinel" "yes" \
    "$(case "$OUT_1E" in ("$SENTINEL_BYTE"*) echo yes ;; (*) echo no ;; esac)"

# 1f. Negative control: genuinely clean (empty tracker, clean tree) is EMPTY
# output — the sentinel must not turn every clean read into a refusal.
F2="$WORK/f2"
mkdir -p "$F2/.claude/.qa-tracking"
( cd "$F2" \
    && "$REAL_GIT" init -q \
    && "$REAL_GIT" config user.email t@example.com \
    && "$REAL_GIT" config user.name t \
    && printf '.claude/\n' > .gitignore \
    && "$REAL_GIT" add .gitignore >/dev/null \
    && "$REAL_GIT" commit -qm init >/dev/null )
: > "$F2/.claude/.qa-tracking/changed-files.txt"
OUT_1F=$(drive_func "$F2"); RC_1F=$?
assert_eq "1f clean fixture: rc 0" "0" "$RC_1F"
assert_eq "1f2 clean fixture: EMPTY output (no sentinel, no phantom entries)" "" "$OUT_1F"

# 1g. Restore control: the 1c fixture with the shim gone yields the real set.
OUT_1G=$(drive_func "$F1")
assert_has "1g restore: tracker half back" "$F1/notes/impl.ts" "$OUT_1G"
assert_has "1g2 restore: git half back" "src/app.ts" "$OUT_1G"

# ---------------------------------------------------------------------------
# Shipped-hook sandboxes. mk_sb <root> <qa-gate: real|stub> builds a sandbox
# whose .claude/scripts carries the SHIPPED hook + its real collaborators
# (denylist lib, current-task.sh, tree-lease.sh when present) and a quiet
# detect-stack stub (empty test/lint/type commands — the gate decision is the
# subject, not a toolchain run). No .beads dir, so the hook's bd-backed gate
# region self-skips and the protected store is never touched.
mk_sb() {
    local root="$1" qam="$2"
    mkdir -p "$root/.claude/scripts" "$root/.claude/.qa-tracking" "$root/notes" "$root/src"
    cp "$VBS" "$DENY" "$CTH" "$root/.claude/scripts/"
    [ -f "$TREE_LEASE" ] && cp "$TREE_LEASE" "$root/.claude/scripts/"
    if [ "$qam" = "real" ]; then
        cp "$QAG" "$root/.claude/scripts/qa-gate.sh"
    else
        # Neutralised collaborator: reconcile-tracker (and anything else)
        # no-ops, so an induced fault reaches THIS hook's detection guard
        # instead of qa-gate's own (already fail-closed) 94d refusal.
        printf '#!/bin/bash\nexit 0\n' > "$root/.claude/scripts/qa-gate.sh"
    fi
    printf '#!/bin/bash\nprintf %%s %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
        > "$root/.claude/scripts/detect-stack.sh"
    chmod +x "$root/.claude/scripts/qa-gate.sh" "$root/.claude/scripts/detect-stack.sh"
    ( cd "$root" \
        && "$REAL_GIT" init -q \
        && "$REAL_GIT" config user.email t@example.com \
        && "$REAL_GIT" config user.name t \
        && printf '.claude/\nnotes/\n' > .gitignore \
        && printf 'code\n' > src/app.ts \
        && "$REAL_GIT" add .gitignore src >/dev/null \
        && "$REAL_GIT" commit -qm init >/dev/null )
    printf 'x\n' > "$root/notes/impl.ts"
}

# run_hook <root> [extra-PATH-dir] — one Stop fire against the sandbox's hook.
# Output on stdout; rc in RUN_HOOK_RC.
run_hook() {
    local root="$1" xp="${2:-}" out rc=0
    # shellcheck disable=SC2031  # the PATH prefix is deliberately scoped to
    # this one hook invocation (env), never the spec's own environment.
    out=$(cd "$root" && printf '{"stop_hook_active": false}' \
        | env ${xp:+PATH="$xp:$PATH"} CLAUDE_PROJECT_DIR="$root" \
              bash "$root/.claude/scripts/verify-before-stop.sh" 2>/dev/null) || rc=$?
    printf '%s' "$out"
    return "$rc"
}

# 2a/2b/2c/2f/2g share one real-qa-gate sandbox.
SB1="$WORK/sb1"
mk_sb "$SB1" real
printf '%s\n' "$SB1/notes/impl.ts" > "$SB1/.claude/.qa-tracking/changed-files.txt"

OUT_2A=$(run_hook "$SB1")
assert_has "2a healthy dirty sandbox: ordinary block" '"decision":"block"' "$OUT_2A"
assert_has "2a2 ...for the ordinary reason" "QA approval required" "$OUT_2A"
assert_eq "2a3 ...with no sentinel byte in the envelope" "no" \
    "$(printf '%s' "$OUT_2A" | LC_ALL=C grep -q "$SENTINEL_BYTE" && echo yes || echo no)"

OUT_2B=$(run_hook "$SB1" "$WORK/shim-sort")
assert_has "2b failing tracker sort: the guard's SPECIFIC block" \
    "the reviewable change set could not be established" "$OUT_2B"
assert_has "2b2 ...naming the tracker read" "changed-files.txt exists and is non-empty but could not be read/sorted" "$OUT_2B"

chmod 000 "$SB1/.claude/.qa-tracking/changed-files.txt"
OUT_2C=$(run_hook "$SB1")
chmod 644 "$SB1/.claude/.qa-tracking/changed-files.txt"
assert_has "2c unreadable non-empty tracker, FULL shipped stack: blocks (pre-fix: released {})" \
    "the reviewable change set could not be established" "$OUT_2C"

# 2d/2e: the git half needs git-visible dirt and an EMPTY tracker.
SB2="$WORK/sb2"
mk_sb "$SB2" stub
printf 'edited\n' >> "$SB2/src/app.ts"
: > "$SB2/.claude/.qa-tracking/changed-files.txt"
OUT_2D=$(run_hook "$SB2" "$WORK/shim-git")
assert_has "2d failing git status (reconcile neutralised): the guard's SPECIFIC block" \
    "the reviewable change set could not be established" "$OUT_2D"
assert_has "2d2 ...naming git status" "git status --porcelain" "$OUT_2D"

SB3="$WORK/sb3"
mk_sb "$SB3" real
printf 'edited\n' >> "$SB3/src/app.ts"
: > "$SB3/.claude/.qa-tracking/changed-files.txt"
OUT_2E=$(run_hook "$SB3" "$WORK/shim-git")
assert_has "2e failing git status, REAL qa-gate: still a block (whichever layer answers), never {}" \
    '"decision":"block"' "$OUT_2E"

: > "$SB1/.claude/.qa-tracking/changed-files.txt"
( cd "$SB1" && "$REAL_GIT" checkout -q -- src/app.ts 2>/dev/null || true )
OUT_2F=$(run_hook "$SB1")
RC_2F=$?
assert_eq "2f clean sandbox: releases {}" "{}" "$OUT_2F"
assert_eq "2f2 ...rc 0" "0" "$RC_2F"
assert_eq "2f3 ...no sentinel byte" "no" \
    "$(printf '%s' "$OUT_2F" | LC_ALL=C grep -q "$SENTINEL_BYTE" && echo yes || echo no)"

printf '%s\n' "$SB1/notes/impl.ts" > "$SB1/.claude/.qa-tracking/changed-files.txt"
OUT_2G=$(run_hook "$SB1")
assert_has "2g restore control: unshimmed dirty sandbox blocks for the ordinary reason again" \
    "QA approval required" "$OUT_2G"
assert_eq "2g2 ...not the undeterminable one" "no" \
    "$(case "$OUT_2G" in (*"could not be established"*) echo yes ;; (*) echo no ;; esac)"

# ---------------------------------------------------------------------------
# 3. The VANISHED-CHANGE-SET probe at the W3 drive point. detect-stack.sh runs
# BETWEEN the hook's two change-set reads (approve-idempotency.sh documents
# this seam), so a stub that damages the tracker there is a deterministic
# mid-hook fault: the detection stage saw real changes, the probe cannot.
# Staging LABEL_WITHOUT_RECORD needs: bd on PATH (a canned fake — the real
# store is never touched), a .beads dir, a current task, and a qa-gate stub
# answering status=approved while impact-report.sh is absent (so no record
# can match and the hook reaches the probe).
SB4="$WORK/sb4"
mk_sb "$SB4" stub
cat > "$SB4/.claude/scripts/qa-gate.sh" <<'QG'
#!/bin/bash
case "${1:-}" in
  status) printf '{"status":"approved"}\n' ;;
  *) exit 0 ;;
esac
QG
chmod +x "$SB4/.claude/scripts/qa-gate.sh"
mkdir -p "$SB4/.beads" "$SB4/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB4/bin/bd"
chmod +x "$SB4/bin/bd"
# bin/ and .beads/ are harness scaffolding, not subject matter: keep them out
# of the sandbox's git view (same call approve-idempotency.sh's fixture
# hygiene note makes), or the probe's git half legitimately reports them and
# the genuine-vanish leg (3b) can never see an empty set.
printf '.claude/\nnotes/\nbin/\n.beads/\n' > "$SB4/.gitignore"
( cd "$SB4" && "$REAL_GIT" add .gitignore >/dev/null && "$REAL_GIT" commit -qm scaffolding-ignored >/dev/null )
printf 'task-123\n' > "$SB4/.claude/.qa-tracking/current-task"
cat > "$SB4/.claude/scripts/detect-stack.sh" <<DS
#!/bin/bash
chmod 000 "$SB4/.claude/.qa-tracking/changed-files.txt" 2>/dev/null
printf '%s' '{"runner":"npm","test_cmd":"","lint_cmd":"","type_cmd":""}'
DS
chmod +x "$SB4/.claude/scripts/detect-stack.sh"
printf '%s\n' "$SB4/notes/impl.ts" > "$SB4/.claude/.qa-tracking/changed-files.txt"
rm -f "$SB4/.claude/.qa-tracking/sync-errors.log"
OUT_3A=$(run_hook "$SB4" "$SB4/bin")
chmod 644 "$SB4/.claude/.qa-tracking/changed-files.txt" 2>/dev/null
assert_has "3a probe fault: the LABEL_WITHOUT_RECORD block STANDS (pre-fix: released {} with a false VANISHED log)" \
    '"decision":"block"' "$OUT_3A"
assert_eq "3a2 ...and the log names the real reason" "yes" \
    "$(grep -q 'probe UNDETERMINABLE' "$SB4/.claude/.qa-tracking/sync-errors.log" 2>/dev/null && echo yes || echo no)"
assert_eq "3a3 ...never the false 'VANISHED' release" "no" \
    "$(grep -q 'change set VANISHED' "$SB4/.claude/.qa-tracking/sync-errors.log" 2>/dev/null && echo yes || echo no)"

# 3b. gz3 anti-overreach restore control: a GENUINE vanish (the tracker
# truncated mid-hook, exactly what qa-gate.sh approve does as its final act)
# must STILL release. An over-eager sentinel here would re-open the very
# race gz3 closed.
cat > "$SB4/.claude/scripts/detect-stack.sh" <<DS
#!/bin/bash
: > "$SB4/.claude/.qa-tracking/changed-files.txt"
printf '%s' '{"runner":"npm","test_cmd":"","lint_cmd":"","type_cmd":""}'
DS
chmod +x "$SB4/.claude/scripts/detect-stack.sh"
printf '%s\n' "$SB4/notes/impl.ts" > "$SB4/.claude/.qa-tracking/changed-files.txt"
rm -f "$SB4/.claude/.qa-tracking/sync-errors.log"
OUT_3B=$(run_hook "$SB4" "$SB4/bin")
assert_eq "3b genuine vanish still releases {} (gz3 preserved)" "{}" "$OUT_3B"
assert_eq "3b2 ...with the gz3 release log" "yes" \
    "$(grep -q 'change set VANISHED' "$SB4/.claude/.qa-tracking/sync-errors.log" 2>/dev/null && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 4. i8cx U7 (verify-before-stop half): the current-task reads.
SB5="$WORK/sb5"
mk_sb "$SB5" real
printf '%s\n' "$SB5/notes/impl.ts" > "$SB5/.claude/.qa-tracking/changed-files.txt"

# 4a. Unreadable current-task.repo ARMS I8 (pre-fix: silently disarmed).
printf 'fp-not-this-repo\n' > "$SB5/.claude/.qa-tracking/current-task.repo"
chmod 000 "$SB5/.claude/.qa-tracking/current-task.repo"
OUT_4A=$(run_hook "$SB5")
chmod 644 "$SB5/.claude/.qa-tracking/current-task.repo"
assert_has "4a unreadable current-task.repo: the I8 cross-repo block fires" \
    "Cross-repo Stop detected (I8)" "$OUT_4A"
assert_has "4a2 ...naming the unreadable marker, not a phantom path" \
    "(unknown: current-task.repo exists but could not be read" "$OUT_4A"

# 4b. Restore control: an ABSENT repo marker keeps the documented single-repo
# degradation — no cross-repo claim, the ordinary block instead.
rm -f "$SB5/.claude/.qa-tracking/current-task.repo"
OUT_4B=$(run_hook "$SB5")
assert_eq "4b absent repo marker: no cross-repo block" "no" \
    "$(case "$OUT_4B" in (*"Cross-repo Stop detected"*) echo yes ;; (*) echo no ;; esac)"
assert_has "4b2 ...the ordinary block instead" "QA approval required" "$OUT_4B"

# 4c. Unreadable current-task marker: still blocks, and the sync log carries
# the honest read-FAILED line instead of the false "empty or missing" claim.
printf 'task-999\n' > "$SB5/.claude/.qa-tracking/current-task"
chmod 000 "$SB5/.claude/.qa-tracking/current-task"
rm -f "$SB5/.claude/.qa-tracking/sync-errors.log"
OUT_4C=$(run_hook "$SB5")
chmod 644 "$SB5/.claude/.qa-tracking/current-task"
assert_has "4c unreadable current-task marker: still blocks" '"decision":"block"' "$OUT_4C"
assert_eq "4c2 ...and the log names the read failure honestly" "yes" \
    "$(grep -q 'current-task read FAILED' "$SB5/.claude/.qa-tracking/sync-errors.log" 2>/dev/null && echo yes || echo no)"

# 4d. Restore control: a READABLE marker takes the normal path (no read-FAILED
# line; the hook still blocks, now with a task attached).
rm -f "$SB5/.claude/.qa-tracking/sync-errors.log"
OUT_4D=$(run_hook "$SB5")
assert_has "4d readable marker: still blocks" '"decision":"block"' "$OUT_4D"
assert_eq "4d2 ...with no read-FAILED line" "no" \
    "$(grep -q 'current-task read FAILED' "$SB5/.claude/.qa-tracking/sync-errors.log" 2>/dev/null && echo yes || echo no)"
rm -f "$SB5/.claude/.qa-tracking/current-task"

# ---------------------------------------------------------------------------
# 5. i8cx WAVE 2: current-task.sh's OWN read (the "helper half" section 4's
# header names as the still-open work) + subagent-start.sh's own copy of the
# same read. Both used to pipe `head -1 FILE | tr ... | sed ...` straight
# through: sed is always last and succeeds trivially on the empty stdin a
# failed head leaves behind, so a genuine read failure and a merely-blank
# file both landed on the same empty tid. current-task.sh's OWN pre-fix rc
# for the unreadable case was already measured non-zero by accident (1, from
# the trailing `[ -n "$tid" ] && printf ...` idiom returning false on ANY
# empty tid, for ANY reason) — never the "rc 0" some earlier notes assumed;
# what was missing was a DEDICATED, distinguishable code (now 3) and any
# stderr trail at all, plus a genuine bug where a merely-blank BUT READABLE
# file also read rc 1, misreported by this file's own section 4 caller
# (verify-before-stop.sh's get_current_task) as a "read FAILED" that never
# happened.

# 5a. current-task.sh get: a merely-blank but READABLE file now correctly
# returns rc 0 (this function's own documented contract: "exits 0 with empty
# stdout if the file is missing/empty") — pre-fix this returned rc 1, the
# SAME rc a genuine read failure produced, making the two indistinguishable
# even by rc alone.
SB7="$WORK/sb7"
mkdir -p "$SB7/.claude/.qa-tracking"
printf '   \n' > "$SB7/.claude/.qa-tracking/current-task"
CT_5A_OUT=$(CLAUDE_PROJECT_DIR="$SB7" bash "$CTH" get 2>/dev/null); CT_5A_RC=$?
assert_eq "5a whitespace-only READABLE current-task file: rc 0" "0" "$CT_5A_RC"
assert_eq "5a2 ...and empty stdout (not the literal whitespace)" "" "$CT_5A_OUT"

# 5b. current-task.sh get: a non-empty but UNREADABLE file now returns the
# DEDICATED rc 3 (matching impact-report.sh's own "tracked file exists but
# could not be read" convention), plus a stderr diagnostic naming the file
# and head's own exit code — pre-fix this was rc 1 (see 5a: the SAME value a
# healthy blank read produced) with NO diagnostic at all.
printf 'task-999\n' > "$SB7/.claude/.qa-tracking/current-task"
chmod 000 "$SB7/.claude/.qa-tracking/current-task"
CT_5B_ERR="$WORK/ct-5b.stderr"
CT_5B_OUT=$(CLAUDE_PROJECT_DIR="$SB7" bash "$CTH" get 2>"$CT_5B_ERR"); CT_5B_RC=$?
chmod 644 "$SB7/.claude/.qa-tracking/current-task"
assert_eq "5b unreadable current-task file: rc 3 (dedicated, distinct from 5a's rc 0)" "3" "$CT_5B_RC"
assert_eq "5b2 ...empty stdout (same as 5a, by design -- rc is the only distinguisher)" "" "$CT_5B_OUT"
assert_has "5b3 ...and a stderr diagnostic naming the read failure" \
    "failed to read" "$(cat "$CT_5B_ERR" 2>/dev/null)"

# 5c. Restore control: a readable, real task id still round-trips (rc 0,
# correct value) -- the ordinary case is unaffected by this fix.
printf 'proj-42\n' > "$SB7/.claude/.qa-tracking/current-task"
CT_5C_OUT=$(CLAUDE_PROJECT_DIR="$SB7" bash "$CTH" get 2>/dev/null); CT_5C_RC=$?
assert_eq "5c restore control: readable real task id: rc 0" "0" "$CT_5C_RC"
assert_eq "5c2 ...and the correct value" "proj-42" "$CT_5C_OUT"

# 5d. current-task.sh get-repo: same rc-3 contract, mirrored for the repo-
# fingerprint file (feeds get_recorded_repo's I8 cross-repo guard, section 4
# above).
printf '/some/repo\n' > "$SB7/.claude/.qa-tracking/current-task.repo"
chmod 000 "$SB7/.claude/.qa-tracking/current-task.repo"
CT_5D_OUT=$(CLAUDE_PROJECT_DIR="$SB7" bash "$CTH" get-repo 2>/dev/null); CT_5D_RC=$?
chmod 644 "$SB7/.claude/.qa-tracking/current-task.repo"
assert_eq "5d current-task.sh get-repo: unreadable file: rc 3" "3" "$CT_5D_RC"
assert_eq "5d2 ...empty stdout" "" "$CT_5D_OUT"

# 5e. META (load-bearing): revert cmd_get to its exact pre-fix one-liner on a
# copy of current-task.sh, and re-run 5a/5b's SAME fixtures. The mutant must
# reproduce rc 1 for BOTH cases -- proving the fix's value (a dedicated,
# distinguishable code) is real, not merely re-labelling what was already
# distinguishable.
CTH_MUT="$WORK/current-task-precmdget.sh"
{
    sed -n '1,/^cmd_get() {$/p' "$CTH"
    cat <<'OLDCMDGET'
    if [ ! -s "$CURRENT_TASK_FILE" ]; then
        return 0
    fi
    local tid
    tid=$(head -1 "$CURRENT_TASK_FILE" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$tid" ] && printf '%s\n' "$tid"
}
OLDCMDGET
    sed -n '/^cmd_get_repo() {$/,$p' "$CTH"
} > "$CTH_MUT"
chmod +x "$CTH_MUT"
assert_eq "5e META: the mutant differs from the shipped script" "differs" \
    "$(cmp -s "$CTH" "$CTH_MUT" && echo same || echo differs)"
assert_eq "5e2 ...and still parses" "0" \
    "$(bash -n "$CTH_MUT" 2>/dev/null && echo 0 || echo 1)"

printf '   \n' > "$SB7/.claude/.qa-tracking/current-task"
MUT_5A2_RC=0
MUT_5A2_OUT=$(CLAUDE_PROJECT_DIR="$SB7" bash "$CTH_MUT" get 2>/dev/null) || MUT_5A2_RC=$?
assert_eq "5e3 SPECIFIC MISBEHAVIOUR: the mutant's whitespace-only case is rc 1, not 5a's fixed rc 0" \
    "1" "$MUT_5A2_RC"
assert_eq "5e3b ...stdout is still empty either way (rc is what this fix changed, not stdout)" \
    "" "$MUT_5A2_OUT"

printf 'task-999\n' > "$SB7/.claude/.qa-tracking/current-task"
chmod 000 "$SB7/.claude/.qa-tracking/current-task"
MUT_5B_RC=0
MUT_5B_OUT=$(CLAUDE_PROJECT_DIR="$SB7" bash "$CTH_MUT" get 2>/dev/null) || MUT_5B_RC=$?
chmod 644 "$SB7/.claude/.qa-tracking/current-task"
assert_eq "5e4 SPECIFIC MISBEHAVIOUR: the mutant's unreadable case is ALSO rc 1 -- byte-identical to 5e3's healthy-blank rc, the pre-fix ambiguity" \
    "1" "$MUT_5B_RC"
assert_eq "5e5 ...and stdout is the same empty string either way (matches 5b2 -- the STDOUT-level ambiguity was never fixable this way; only rc was)" \
    "" "$MUT_5B_OUT"

# Discriminator: the mutant, on the ordinary readable-with-content case,
# still round-trips correctly.
printf 'proj-42\n' > "$SB7/.claude/.qa-tracking/current-task"
MUT_5F_OUT=$(CLAUDE_PROJECT_DIR="$SB7" bash "$CTH_MUT" get 2>/dev/null)
assert_eq "5f discriminator: the mutant still round-trips a real task id (ran the real predicate otherwise)" \
    "proj-42" "$MUT_5F_OUT"
rm -f "$SB7/.claude/.qa-tracking/current-task" "$SB7/.claude/.qa-tracking/current-task.repo"

# ---------------------------------------------------------------------------
# 5g-5j. subagent-start.sh's OWN get_current_task, mirroring the SAME fix
# shape verify-before-stop.sh's (section 4) and current-task.sh's (5a-5f)
# already carry. Unlike those two, a masked read failure here does NOT flip
# any release/block decision -- subagent-start.sh already degraded to the
# SAME `{}` output on any current-task failure, before and after this fix
# (a SubagentStart hook must never block a spawn). What the fix adds is
# AUDITABILITY: pre-fix, that branch was 100% silent, so a spawn whose
# record_implementer call got silently skipped (the input half of
# review-check.sh:1417's independence check) left no trace. The
# discriminating property this section tests is therefore the sync-errors.log
# TRAIL, not the JSON output, which is `{}` on both sides of the fix for the
# unreadable-marker case.
# shellcheck disable=SC2031  # PROJECT_DIR is set once at file scope, above
# every subshell in this file; shellcheck's conflict detector cannot see
# past the earlier `(cd ... )` blocks that never touch it. Same false
# positive run_hook's own SC2031 disable (below) documents.
SAS="$PROJECT_DIR/.claude/scripts/subagent-start.sh"
SB8="$WORK/sb8"
mkdir -p "$SB8/.claude/scripts" "$SB8/.claude/.qa-tracking"
cp "$VBS" "$CTH" "$SAS" "$SB8/.claude/scripts/" 2>/dev/null
chmod +x "$SB8/.claude/scripts/"*.sh

# run_subagent_start <root> [extra-PATH-dir] — one SubagentStart fire against
# the sandbox's hook. Output on stdout; rc via return. Same shape as
# run_hook above, for the sibling hook.
run_subagent_start() {
    local root="$1" xp="${2:-}" out rc=0
    # shellcheck disable=SC2031  # the PATH prefix is deliberately scoped to
    # this one hook invocation (env), never the spec's own environment —
    # same rationale as run_hook's identical disable above.
    out=$(cd "$root" && printf '{"agent_type": "backend"}' \
        | env ${xp:+PATH="$xp:$PATH"} CLAUDE_PROJECT_DIR="$root" \
              bash "$root/.claude/scripts/subagent-start.sh" 2>/dev/null) || rc=$?
    printf '%s' "$out"
    return "$rc"
}

# 5g. Unreadable current-task marker: the hook still emits {} (never blocks
# a spawn, unchanged), but sync-errors.log now names the read failure.
printf 'proj-77\n' > "$SB8/.claude/.qa-tracking/current-task"
chmod 000 "$SB8/.claude/.qa-tracking/current-task"
rm -f "$SB8/.claude/.qa-tracking/sync-errors.log"
SAS_5G_OUT=$(run_subagent_start "$SB8")
chmod 644 "$SB8/.claude/.qa-tracking/current-task"
assert_eq "5g unreadable marker: subagent-start.sh still emits {} (never blocks a spawn)" "{}" "$SAS_5G_OUT"
assert_eq "5g2 ...but sync-errors.log now carries the honest read-FAILED trail" "yes" \
    "$(grep -q 'current-task read FAILED' "$SB8/.claude/.qa-tracking/sync-errors.log" 2>/dev/null && echo yes || echo no)"

# 5h. Restore control: a readable marker produces a real additionalContext
# envelope (not {}), naming the task, with no log noise.
rm -f "$SB8/.claude/.qa-tracking/sync-errors.log"
SAS_5H_OUT=$(run_subagent_start "$SB8")
assert_eq "5h readable marker: NOT {} (a real additionalContext is emitted)" "no" \
    "$([ "$SAS_5H_OUT" = "{}" ] && echo yes || echo no)"
assert_has "5h2 ...naming the actual task id" "proj-77" "$SAS_5H_OUT"
assert_eq "5h3 ...with no read-FAILED line" "no" \
    "$(grep -q 'current-task read FAILED' "$SB8/.claude/.qa-tracking/sync-errors.log" 2>/dev/null && echo yes || echo no)"

# 5i. Negative control: NO marker at all (genuinely idle session) -- {} with
# NO log entry, proving the fix does not confuse "no active task" with "read
# failed".
rm -f "$SB8/.claude/.qa-tracking/current-task" "$SB8/.claude/.qa-tracking/sync-errors.log"
SAS_5I_OUT=$(run_subagent_start "$SB8")
assert_eq "5i no marker at all: {}" "{}" "$SAS_5I_OUT"
assert_eq "5i2 ...and no log entry (genuinely idle, not a read failure)" "no" \
    "$(grep -q 'current-task read FAILED' "$SB8/.claude/.qa-tracking/sync-errors.log" 2>/dev/null && echo yes || echo no)"

# 5j. META: strip subagent-start.sh's get_current_task down to the pre-fix
# shape (splice, matching current-task.sh's 5e technique -- a plain sentinel
# strip would remove the `local tid="" tid_rc=0` declaration this function's
# OWN later reference to $tid_rc needs). On the SAME 5g fixture (unreadable
# marker), the mutant must still emit {} (the JSON-level behaviour never
# flips either side of this fix -- see this section's own header) but MUST
# NOT log the read failure.
SAS_MUT="$SB8/.claude/scripts/subagent-start.mutant.sh"
{
    sed -n '1,/^get_current_task() {$/p' "$SAS"
    cat <<'OLDGCT'
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        tid=$(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null | tr -d '\r\n[:space:]' || echo "")
    fi
    printf '%s' "$tid"
}
OLDGCT
    sed -n '/^normalize_agent_type() {$/,$p' "$SAS"
} > "$SAS_MUT"
chmod +x "$SAS_MUT"
assert_eq "5j META: the mutant differs from the shipped script" "differs" \
    "$(cmp -s "$SAS" "$SAS_MUT" && echo same || echo differs)"
assert_eq "5j2 ...and still parses" "0" \
    "$(bash -n "$SAS_MUT" 2>/dev/null && echo 0 || echo 1)"

printf 'proj-77\n' > "$SB8/.claude/.qa-tracking/current-task"
chmod 000 "$SB8/.claude/.qa-tracking/current-task"
rm -f "$SB8/.claude/.qa-tracking/sync-errors.log"
SAS_MUT_OUT=$(cd "$SB8" && printf '{"agent_type": "backend"}' \
    | CLAUDE_PROJECT_DIR="$SB8" bash "$SB8/.claude/scripts/subagent-start.mutant.sh" 2>/dev/null)
chmod 644 "$SB8/.claude/.qa-tracking/current-task"
assert_eq "5j3 SPECIFIC MISBEHAVIOUR: the mutant, unreadable marker: still {} (the outcome does not flip -- see header)" \
    "{}" "$SAS_MUT_OUT"
assert_eq "5j4 ...but NO read-FAILED trail (the pre-fix silence -- the property this fix actually adds)" "no" \
    "$(grep -q 'current-task read FAILED' "$SB8/.claude/.qa-tracking/sync-errors.log" 2>/dev/null && echo yes || echo no)"

# Discriminator: the mutant, readable marker, still assigns the task normally.
rm -f "$SB8/.claude/.qa-tracking/sync-errors.log"
SAS_MUT_CTRL=$(cd "$SB8" && printf '{"agent_type": "backend"}' \
    | CLAUDE_PROJECT_DIR="$SB8" bash "$SB8/.claude/scripts/subagent-start.mutant.sh" 2>/dev/null)
assert_has "5k discriminator: the mutant, readable marker, still assigns the real task (ran the real predicate otherwise)" \
    "proj-77" "$SAS_MUT_CTRL"
rm -f "$SB8/.claude/.qa-tracking/current-task"

# ---------------------------------------------------------------------------
# META: strip the CHANGE-SET-UNDETERMINABLE block from a COPY of the shipped
# hook (the BEGIN/END sentinel comments are load-bearing for exactly this),
# prove the strip landed, and drive the IDENTICAL unreadable-tracker fixture
# 2c used. The copy must RELEASE `{}` — the exact pre-fix misbehaviour —
# while the shipped hook blocked (2c above is the restore-control leg; both
# run in this same file, so the pairing is self-contained).
SB6="$WORK/sb6"
mk_sb "$SB6" real
awk '
    /# CHANGE-SET-UNDETERMINABLE BEGIN/ { skipping=1; found=1; next }
    /# CHANGE-SET-UNDETERMINABLE END/   { skipping=0; next }
    skipping { next }
    { print }
    END { exit(found ? 0 : 3) }
' "$VBS" > "$SB6/.claude/scripts/verify-before-stop.sh"
STRIP_RC=$?
assert_eq "META.1 the strip found the sentinel region (non-vacuous mutation)" "0" "$STRIP_RC"
# The sentinel CONSTANT survives the strip by design (it sits outside the
# region); what must be gone is the refusal REGION itself.
assert_eq "META.2 the stripped copy carries NO undeterminable refusal region" "0" \
    "$(grep -cE '# CHANGE-SET-UNDETERMINABLE (BEGIN|END)' "$SB6/.claude/scripts/verify-before-stop.sh" | tr -d '[:space:]')"
assert_eq "META.3 the stripped copy parses" "0" \
    "$(bash -n "$SB6/.claude/scripts/verify-before-stop.sh" 2>/dev/null && echo 0 || echo 1)"
printf '%s\n' "$SB6/notes/impl.ts" > "$SB6/.claude/.qa-tracking/changed-files.txt"
chmod 000 "$SB6/.claude/.qa-tracking/changed-files.txt"
OUT_M=$(run_hook "$SB6")
chmod 644 "$SB6/.claude/.qa-tracking/changed-files.txt"
assert_eq "META.4 the mutant RELEASES {} on the unreadable tracker — the specific pre-fix misbehaviour (2c is the shipped-hook control)" \
    "{}" "$OUT_M"

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

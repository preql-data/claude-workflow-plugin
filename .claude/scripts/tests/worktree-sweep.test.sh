#!/bin/bash
# worktree-sweep.test.sh — L1 unit spec for .claude/scripts/worktree-sweep.sh
# (v4.1 C1b, claude-workflow-plugin-8xv).
#
# WHAT THIS TIER OWNS
# -------------------
# The sweeper is the only script in the plugin that can DELETE an operator's
# working tree, so its two cheapest-to-break properties are pinned here as
# TEXT and as behaviour, ahead of the full-lifecycle L2 spec:
#
#   A. STRUCTURE — removal goes through `git worktree remove` and nothing else.
#      No `rm -rf`, no `rm` against a candidate path, no `--force` override of
#      git's own refusal. A behavioural spec can only prove this for the inputs
#      it happens to try; the text check covers every future edit at once.
#   B. CONTAINMENT — three shapes that a string-prefix test gets WRONG, all
#      built from a real `git worktree add`:
#        B1 a worktree plainly outside .claude/worktrees/
#        B2 a SIBLING whose name EXTENDS the root's (`…/worktrees-extra`),
#           which is the live hazard: `<repo>-impactfix` string-prefixes
#           `<repo>` in this very checkout
#        B3 a symlink UNDER .claude/worktrees/ that physically resolves
#           outside — `git worktree list` prints the contained-looking path
#           and only `pwd -P` sees through it
#
# META-TEST: strip the containment guard from a COPY of the script and the B1
# verdict must flip from not-contained to something else; restore and it must
# come back. Without the flip the containment assertions are consistent with
# "the guard works" AND with "nothing ever reaches the guard".
#
# Exit: 0 all assertions pass · 1 any failure.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SCRIPT="$PROJECT_DIR/.claude/scripts/worktree-sweep.sh"

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' "$name" "$needle" "$haystack"
    fi
}

if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    printf 'SKIPPED: worktree-sweep.test.sh (jq and git are both required)\n'
    exit 0
fi

T=$(mktemp -d -t worktree-sweep.XXXXXX)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# Section A — structure. Whole-line comments are stripped first: the header
# above deliberately CONTAINS the strings we are forbidding, and matching them
# there would make every assertion below un-failable.
# ---------------------------------------------------------------------------

echo "--- A: structure ---"

assert_eq "A1: worktree-sweep.sh is FLAT under .claude/scripts/" "yes" \
    "$([ -f "$SCRIPT" ] && echo yes || echo no)"

bash -n "$SCRIPT" 2>/dev/null
assert_eq "A2: parses under bash -n" "0" "$?"

CODE=$(grep -v '^[[:space:]]*#' "$SCRIPT")

assert_eq "A3: zero 'rm -rf' in executable text" "0" \
    "$(printf '%s\n' "$CODE" | grep -c 'rm -rf' || true)"
assert_eq "A4: zero 'rm' against ANY candidate/path variable" "0" \
    "$(printf '%s\n' "$CODE" | grep -cE '(^|[^[:alnum:]_])rm[[:space:]]' || true)"
# The single quotes are load-bearing: `\$` is a BRE escape matching a LITERAL
# dollar sign in the script's text, not a shell expansion.
# shellcheck disable=SC2016
assert_eq "A5: removal is 'git worktree remove'" "1" \
    "$(printf '%s\n' "$CODE" | grep -c 'git -C "\$PROJECT_DIR" worktree remove' || true)"
assert_eq "A6: 'worktree remove' is never --force'd" "0" \
    "$(printf '%s\n' "$CODE" | grep -c 'worktree remove --force' || true)"
# Dry-run by default: ARG_APPLY starts at 0 and exactly ONE line raises it —
# the --apply branch. A second raise anywhere (a hook shortcut, an env read)
# would make "nothing is removed unless you ask" untrue without failing B5.
assert_eq "A7: ARG_APPLY initialises to 0" "1" \
    "$(printf '%s\n' "$CODE" | grep -c '^ARG_APPLY=0$' || true)"
assert_eq "A8: exactly one ARG_APPLY=1, and it is on the --apply branch" "1" \
    "$(printf '%s\n' "$CODE" | grep -c '\-\-apply)[[:space:]]*ARG_APPLY=1' || true)"
assert_eq "A9: ARG_APPLY is raised in exactly ONE place, total" "1" \
    "$(printf '%s\n' "$CODE" | grep -c 'ARG_APPLY=1' || true)"

HELP=$(bash "$SCRIPT" --help 2>&1)
assert_eq "A10: --help exits 0" "0" "$?"
assert_contains "A11: --help documents --apply" "--apply" "$HELP"
assert_contains "A12: --help states nothing is removed without --apply" \
    "WITHOUT THIS" "$HELP"

bash "$SCRIPT" --definitely-not-a-flag >/dev/null 2>&1
assert_eq "A13: unknown flag exits 2" "2" "$?"

bash "$SCRIPT" --age-days seven >/dev/null 2>&1
assert_eq "A14: --age-days rejects a non-numeric value with exit 2" "2" "$?"

bash "$SCRIPT" --max-candidates 0 >/dev/null 2>&1
assert_eq "A15: --max-candidates rejects 0 with exit 2" "2" "$?"

# --json is jq-encoded; without jq the encoder would emit NOTHING and exit 0,
# which reads exactly like "no worktrees found". A jq-less PATH is built by hand
# because PATH=/usr/bin:/bin is NOT jq-less on macOS 15+ or on ubuntu runners
# (LESSONS.md) — so the precondition is asserted before the behaviour.
mkdir -p "$T/nojq-bin" "$T/nojq-proj"
for b in bash git sed awk grep find date head tr cmp; do
    bp=$(command -v "$b" 2>/dev/null) && ln -sf "$bp" "$T/nojq-bin/$b"
done
assert_eq "A16: precondition — the restricted PATH really has no jq" "yes" \
    "$(PATH="$T/nojq-bin" command -v jq >/dev/null 2>&1 && echo no || echo yes)"
NOJQ_OUT=$(PATH="$T/nojq-bin" CLAUDE_PROJECT_DIR="$T/nojq-proj" "$T/nojq-bin/bash" "$SCRIPT" --json 2>&1)
assert_eq "A17: --json without jq exits 2 instead of printing nothing" "2" "$?"
assert_contains "A18: ...and says so" "needs jq on PATH" "$NOJQ_OUT"
NOJQ_TXT=$(PATH="$T/nojq-bin" CLAUDE_PROJECT_DIR="$T/nojq-proj" "$T/nojq-bin/bash" "$SCRIPT" 2>&1)
assert_eq "A19: text mode still reports on a jq-less host" "0" "$?"
assert_contains "A20: ...with its completeness line intact" "Total: 0" "$NOJQ_TXT"

# ---------------------------------------------------------------------------
# Section B — containment, against a real repo in a tempdir. NEVER the live
# checkout: it has real worktrees and a sweeper bug here is destructive.
# ---------------------------------------------------------------------------

echo "--- B: containment (real git, tempdir) ---"

mkdir -p "$T/bin"
cat > "$T/bin/bd" <<'STUB'
#!/bin/bash
# Case-dispatch bd stub: one closed task, everything else unknown.
ARGS="$*"
case "$1" in
    show)
        case "$2" in
            l1-task-closed) printf '%s\n' '{"status":"closed"}'; exit 0 ;;
            *) printf 'unknown id in: %s\n' "$ARGS" >&2; exit 1 ;;
        esac ;;
esac
exit 0
STUB
chmod +x "$T/bin/bd"

REPO="$T/repo"
mkdir -p "$REPO/src" "$T/outside"
printf '.claude/.qa-tracking/\n.claude/worktrees/\n' > "$REPO/.gitignore"
printf 'base\n' > "$REPO/src/a.txt"
(
  cd "$REPO" && git init -q -b main . && git config user.email t@t.t \
    && git config user.name t && git add -A && git commit -qm base
) >/dev/null 2>&1
mkdir -p "$REPO/.claude/worktrees"

wt_add() { git -C "$REPO" worktree add -q -b "$2" "$1" main >/dev/null 2>&1; }
wt_add "$REPO/.claude/worktrees/inscope" l1-inscope
wt_add "$T/outside/plain"                l1-plain
wt_add "$REPO/.claude/worktrees-extra"   l1-extra
wt_add "$T/outside/aliased"              l1-aliased

# B3: alias `outside/aliased` INTO the worktrees dir and repoint git's admin
# record at the symlink, which is what a moved/aliased worktree looks like on
# disk. `git worktree add` itself resolves symlinks (probed), so this is the
# only way the hazard actually reaches `git worktree list`.
ln -s "$T/outside/aliased" "$REPO/.claude/worktrees/lnk"
printf '%s\n' "$REPO/.claude/worktrees/lnk/.git" > "$REPO/.git/worktrees/aliased/gitdir"

# `inscope` carries closed-task evidence and an old mtime, so it is the single
# removable candidate and B5 is not vacuous. `outside/plain` is given the SAME
# evidence deliberately: it satisfies every gate EXCEPT containment, so the META
# below can show that stripping the guard promotes an out-of-scope checkout to
# REMOVABLE — the catastrophic outcome, not merely a different reason string.
for w in "$REPO/.claude/worktrees/inscope" "$T/outside/plain"; do
    mkdir -p "$w/.claude/.qa-tracking"
    printf 'l1-task-closed\n' > "$w/.claude/.qa-tracking/current-task"
done
touch -t 202001010000 "$REPO/.claude/worktrees/inscope" "$T/outside/plain" \
    "$REPO/.claude/worktrees-extra" "$T/outside/aliased"

sweep_json() {
    # sweep_json [script] [extra args...] -> the --json report
    local s="${1:-$SCRIPT}"; shift 2>/dev/null || true
    PATH="$T/bin:$PATH" CLAUDE_PROJECT_DIR="$REPO" bash "$s" --json "$@" 2>/dev/null
}
reason_of() {
    # reason_of <json> <basename-of-PHYSICAL-path>
    printf '%s' "$1" \
        | jq -r --arg b "$2" '[.candidates[] | select(.path | endswith("/" + $b)) | .reason][0] // "<absent>"' \
            2>/dev/null
}

J=$(sweep_json)
assert_eq "B1: a worktree plainly outside .claude/worktrees/ is not-contained" \
    "not-contained" "$(reason_of "$J" plain)"
assert_eq "B2: the sibling '<root>-extra' is not-contained (boundary char, not prefix)" \
    "not-contained" "$(reason_of "$J" worktrees-extra)"
assert_eq "B3: a symlink UNDER the root resolving outside is not-contained" \
    "not-contained" "$(reason_of "$J" aliased)"
assert_eq "B4: control — the in-scope worktree passes containment" \
    "ok" "$(reason_of "$J" inscope)"
assert_eq "B5: default run is a DRY RUN (removable found, nothing removed)" \
    "1 0" "$(printf '%s' "$J" | jq -r '"\(.removable) \(.removed)"' 2>/dev/null)"
assert_eq "B5b: the removable worktree is still on disk after the default run" \
    "yes" "$([ -d "$REPO/.claude/worktrees/inscope" ] && echo yes || echo no)"
assert_eq "B5c: and git still lists it" "1" \
    "$(git -C "$REPO" worktree list --porcelain | grep -c 'worktrees/inscope$' || true)"
assert_contains "B6: the text report carries a completeness line" "Total: 4" \
    "$(PATH="$T/bin:$PATH" CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPT" 2>/dev/null)"

# ---------------------------------------------------------------------------
# META — strip the containment guard from a COPY and prove B1 flips.
# Anchored on a unique TEXT pattern, never a line number (LESSONS.md).
# ---------------------------------------------------------------------------

echo "--- META: containment guard is load-bearing ---"

MUT="$T/worktree-sweep.mutated.sh"
awk 'index($0, "SWEEP_REASON=\"not-contained\"") { print "    :  # MUTATED: containment guard removed"; next } { print }' \
    "$SCRIPT" > "$MUT"

assert_eq "META-1a: the strip actually changed the file (non-vacuous mutation)" "1" \
    "$(cmp -s "$SCRIPT" "$MUT" && echo 0 || echo 1)"
bash -n "$MUT" 2>/dev/null
assert_eq "META-1b: the mutated copy still parses (it fails for its own reason)" "0" "$?"

JM=$(sweep_json "$MUT")
assert_eq "META-1c: with the guard stripped, the OUTSIDE worktree passes every gate" \
    "ok" "$(reason_of "$JM" plain)"
assert_eq "META-1d: ...and is reported REMOVABLE — the outcome containment prevents" \
    "REMOVABLE" \
    "$(printf '%s' "$JM" | jq -r '[.candidates[] | select(.path | endswith("/plain")) | .status][0] // "<absent>"' 2>/dev/null)"
assert_eq "META-1e: restore control — the shipped script says not-contained again" \
    "not-contained" "$(reason_of "$(sweep_json)" plain)"
assert_eq "META-1f: restore control — and reports exactly ONE removable, in scope" \
    "1 inscope" \
    "$(sweep_json | jq -r '"\(.removable) \([.candidates[]|select(.status=="REMOVABLE")|.path|split("/")|last]|join(","))"' 2>/dev/null)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0

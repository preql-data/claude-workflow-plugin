#!/bin/bash
# post-edit.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers B5/B6/B9: append tracked
# file path to .qa-tracking/changed-files.txt, denylist build artifacts,
# race-safe dedup.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
PE="$FIXTURE/.claude/scripts/post-edit.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"
FILE="$TRACK/changed-files.txt"

# EVERY PROBE PATH BELOW IS ROOTED AT $FIXTURE, and that is load-bearing rather
# than tidiness (claude-workflow-plugin-fkm.1.15). These legs used to use
# `/tmp/foo.ts`-style paths as stand-ins for "an ordinary file", which stopped
# being valid when the hook grew the record-time containment rule (section 13):
# $FIXTURE is what mk_fixture points CLAUDE_PROJECT_DIR at, so a /tmp path is now
# out-of-project and would be dropped by rule 3 no matter what rule 1 or the
# dedup logic did.
#
# The denylist legs (4-7) are the ones that would have DECAYED SILENTLY: their
# acceptance is an absence, so under a /tmp path they would keep passing with the
# denylist deleted — dropped by containment instead, proving nothing about the
# regex they name. In-fixture paths make containment a non-factor and leave each
# leg measuring exactly the rule in its own title. Keep them that way.
PE_TS="$FIXTURE/src/foo.ts"
PE_MD="$FIXTURE/docs/bar.md"
PE_PY="$FIXTURE/src/baz.py"
PE_NB="$FIXTURE/notebooks/analysis.ipynb"

# 1. Write a TS file -> appended to changed-files.txt + {} envelope.
OUT=$(printf '{"tool_input":{"file_path":"%s"}}' "$PE_TS" | bash "$PE")
assert_empty_envelope "post-edit: TS write emits {}" "$OUT"
assert_eq "post-edit: changed-files.txt created" "0" \
    "$([ -s "$FILE" ] && echo 0 || echo 1)"
LINES=$(grep -c -x -F "$PE_TS" "$FILE")
assert_eq "post-edit: TS path recorded once" "1" "$LINES"

# 2. Second write of the SAME file -> dedup-on-write IF flock is available,
# else dedup-at-read (the file may have duplicates which `sort -u` flattens).
# Either way, the UNIQUE count after a repeat write must be 1.
printf '{"tool_input":{"file_path":"%s"}}' "$PE_TS" | bash "$PE" >/dev/null
LINES=$(sort -u "$FILE" | grep -c -x -F "$PE_TS")
assert_eq "post-edit: dedup on repeat write (unique count)" "1" "$LINES"

# 3. Different file appended as a new line.
printf '{"tool_input":{"file_path":"%s"}}' "$PE_MD" | bash "$PE" >/dev/null
UNIQUE=$(sort -u "$FILE" | wc -l | tr -d ' ')
assert_eq "post-edit: different file added" "2" "$UNIQUE"

# 4. Denylist: node_modules path -> NOT tracked, {} envelope.
OUT=$(printf '{"tool_input":{"file_path":"%s/node_modules/foo/bar.js"}}' "$FIXTURE" | bash "$PE")
assert_empty_envelope "post-edit: denylist envelope" "$OUT"
DENIED=$(grep -c 'node_modules' "$FILE" 2>/dev/null || true)
DENIED=$(printf '%s' "$DENIED" | head -1 | tr -d '[:space:]')
assert_eq "post-edit: node_modules NOT in tracking" "0" "${DENIED:-0}"

# 5. Denylist: .git path -> NOT tracked. (`grep -c` always prints the count
# on stdout AND exits non-zero when 0 — no need for `|| echo 0`.)
printf '{"tool_input":{"file_path":"%s/.git/index"}}' "$FIXTURE" | bash "$PE" >/dev/null
GIT_LINES=$(grep -c '/\.git/' "$FILE" 2>/dev/null || true)
GIT_LINES=$(printf '%s' "$GIT_LINES" | head -1 | tr -d '[:space:]')
assert_eq "post-edit: .git NOT tracked" "0" "${GIT_LINES:-0}"

# 6. Denylist: lockfile -> NOT tracked.
printf '{"tool_input":{"file_path":"%s/package-lock.json"}}' "$FIXTURE" | bash "$PE" >/dev/null
LOCK_LINES=$(grep -c 'package-lock' "$FILE" 2>/dev/null || true)
LOCK_LINES=$(printf '%s' "$LOCK_LINES" | head -1 | tr -d '[:space:]')
assert_eq "post-edit: package-lock NOT tracked" "0" "${LOCK_LINES:-0}"

# 7. Denylist: .min.js -> NOT tracked.
printf '{"tool_input":{"file_path":"%s/dist/app.min.js"}}' "$FIXTURE" | bash "$PE" >/dev/null
MIN_LINES=$(grep -c 'app\.min\.js' "$FILE" 2>/dev/null || true)
MIN_LINES=$(printf '%s' "$MIN_LINES" | head -1 | tr -d '[:space:]')
assert_eq "post-edit: .min.js NOT tracked" "0" "${MIN_LINES:-0}"

# 8. Missing file_path -> {} envelope, no tracking change.
BEFORE=$(wc -l < "$FILE" | tr -d ' ')
OUT=$(printf '%s' '{"tool_input":{}}' | bash "$PE")
assert_empty_envelope "post-edit: missing file_path returns {}" "$OUT"
AFTER=$(wc -l < "$FILE" | tr -d ' ')
assert_eq "post-edit: missing file_path doesn't append" "$BEFORE" "$AFTER"

# 9. Alternative field name `path` (vs `file_path`) is also probed.
OUT=$(printf '{"tool_input":{"path":"%s"}}' "$PE_PY" | bash "$PE")
assert_empty_envelope "post-edit: path-field envelope" "$OUT"
ALT=$(grep -c -x -F "$PE_PY" "$FILE")
assert_eq "post-edit: tool_input.path also tracked" "1" "$ALT"

# 10. Permissive extensions (denylist not allowlist): .md / .json / .toml
# / .proto all tracked (B6 — replaced allowlist with denylist).
for f in "$FIXTURE/README.md" "$FIXTURE/config.json" "$FIXTURE/Cargo.toml" "$FIXTURE/service.proto"; do
    printf '{"tool_input":{"file_path":"%s"}}' "$f" | bash "$PE" >/dev/null
done
for f in "README.md" "config.json" "Cargo.toml" "service.proto"; do
    LN=$(grep -c "$f" "$FILE")
    assert_eq "post-edit: $f tracked (denylist not allowlist)" "1" "$LN"
done

# ---------------------------------------------------------------------------
# 11. THE TWO PostToolUse SHAPES THIS HOOK MUST TELL APART (94d).
#
# The hook is wired to `^(Write|Edit|MultiEdit|NotebookEdit)$`. Those four are
# exactly the tools whose tool_input carries a path, and the two assertions
# below pin the boundary from both sides:
#
#   11a NotebookEdit spells its path `notebook_path` — neither `file_path` nor
#       `path`. Before 94d the extraction knew only the latter two, so a
#       notebook edit produced a valid `{}` envelope and tracked NOTHING: the
#       file stayed out of changed-files.txt and therefore out of
#       change_set_hash, which is the same silent under-coverage the reconcile
#       exists to repair. Widening the matcher without widening the extraction
#       would have looked like a fix and changed nothing.
#
#       WHAT THIS LEG DOES NOT PROVE, stated because the distinction was missed
#       for four review rounds: it proves the hook READS the field this test
#       SENDS, not that the runtime sends it. That second half is a claim about
#       an external boundary and it is sourced in post-edit.sh's own header —
#       the tool's `strictObject({notebook_path: …})` input schema and the
#       `{tool_name: …, tool_input: <call>.input}` payload construction, both
#       read out of the shipping Claude Code binary with its version recorded.
#       If this leg is ever the ONLY evidence again, it is not evidence.
#
#   11b Bash CANNOT be handled here, and this asserts the reason rather than
#       the consequence: `tool_input.command` carries no path field, so there is
#       nothing for any extraction to read — a `^Bash$` matcher for this hook is
#       unbuildable, not merely unimplemented (v5 plan, correction 6). The hook
#       must emit its `{}` envelope and track nothing, which is what makes the
#       git-status reconcile in qa-gate.sh the only possible repair for that
#       class. If this ever starts tracking something, the reconcile's scope
#       assumption has changed and both need revisiting.
# ---------------------------------------------------------------------------
NB_OUT=$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s","new_source":"print(1)"}}' "$PE_NB" | bash "$PE")
assert_empty_envelope "post-edit 11a: NotebookEdit payload emits {}" "$NB_OUT"
NB_LINES=$(grep -c -x -F "$PE_NB" "$FILE" 2>/dev/null || true)
NB_LINES=$(printf '%s' "$NB_LINES" | head -1 | tr -d '[:space:]')
assert_eq "post-edit 11a: NotebookEdit's notebook_path IS tracked (94d)" "1" "${NB_LINES:-0}"

BASH_BEFORE=$(sort -u "$FILE" | grep -c . | tr -d '[:space:]')
BASH_OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"printf x > /tmp/written-by-bash.ts","description":"write a file"}}' | bash "$PE")
assert_empty_envelope "post-edit 11b: a Bash-shaped payload still emits a valid {} envelope" "$BASH_OUT"
BASH_AFTER=$(sort -u "$FILE" | grep -c . | tr -d '[:space:]')
assert_eq "post-edit 11b: ...and tracks nothing — tool_input.command has no path field to read" \
    "$BASH_BEFORE" "$BASH_AFTER"
BASH_LEAK=$(grep -c 'written-by-bash' "$FILE" 2>/dev/null || true)
BASH_LEAK=$(printf '%s' "$BASH_LEAK" | head -1 | tr -d '[:space:]')
assert_eq "post-edit 11b: ...and the path inside the command string is NOT scraped out of it" \
    "0" "${BASH_LEAK:-0}"

# ---------------------------------------------------------------------------
# 12. THE SECOND RULE: paths the WORKFLOW ITSELF writes never enter the tracker
#     (94d / R2-F5).
#
# workflow-denylist.sh carries TWO rules, and until R2-F5 this hook applied only
# the first. The second — workflow_self_written, "0 = the workflow wrote it (keep
# it OUT of the change set)" — names `.claude/.qa-tracking/**` ("the tracker, the
# baseline, the impact report, THE REVIEW ARTIFACTS") and
# `.beads/interactions.jsonl`. Its own header states the intent; this hook did
# not achieve it on the primary route in.
#
# WHY THAT MATTERED, measured rather than argued. A reviewer writing the review
# artifact to the path qa.md 6p.2 prescribes, with the Write tool, took the
# tracker from 23 to 24 paths and moved change_set_hash abe62c33… -> 752729a4…,
# after which `qa-gate.sh approve` refused (exit 2, error_key=
# impact_report_stale) against the report `enter` had generated minutes earlier.
# The tracker is the hash's input, so the gate's own bookkeeping was certifying
# itself. It also made an otherwise doc-only change set MIXED at the Stop
# detector's tracker half and killed the F1 fast path — the same
# hash-and-gate-disagree class the rule was introduced to end.
#
# The three assertions that matter are the two DROPS and the one KEEP: the KEEP
# is the whole boundary the regex turns on. `.beads/issues.jsonl` is the
# committed ledger — a real deliverable, rewritten only on an explicit export —
# and a rule that swallowed it would erase the audit trail from the change set.
# Anti-overreach legs pin both anchors ((^|/) and the trailing $) so a future
# widening of either fails here rather than in production.
#
# `$FILE` is truncated per probe from here on. Nothing after this section reads
# it (the mutation-survivor block below builds a fresh fixture).
# ---------------------------------------------------------------------------
# pe_track <path> — drive the hook exactly as PostToolUse does, against a clean
# tracker, and report whether the path landed.
pe_track() {
    : > "$FILE"
    printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$PE" >/dev/null 2>&1
    if grep -qxF "$1" "$FILE" 2>/dev/null; then printf 'tracked'; else printf 'skipped'; fi
}

SW_ART="$FIXTURE/.claude/.qa-tracking/review-artifact-cwp-94d-r2.json"
SW_TRACKER="$FIXTURE/.claude/.qa-tracking/changed-files.txt"
SW_INTER="$FIXTURE/.beads/interactions.jsonl"
SW_LEDGER="$FIXTURE/.beads/issues.jsonl"

# The envelope contract survives the new early exit: a self-written path must
# still produce `{}`, not silence (silence reads as a malformed hook).
SW_OUT=$(printf '{"tool_input":{"file_path":"%s"}}' "$SW_ART" | bash "$PE")
assert_empty_envelope "post-edit 12: a self-written path still emits {}" "$SW_OUT"

# --- the DROPS -------------------------------------------------------------
assert_eq "post-edit 12a: a review artifact under .qa-tracking/ is NOT tracked (94d/R2-F5)" \
    "skipped" "$(pe_track "$SW_ART")"
# The tracker itself, written with the Write tool, is the reductio: it would
# make the change set a function of its own contents.
assert_eq "post-edit 12a: ...nor changed-files.txt itself" \
    "skipped" "$(pe_track "$SW_TRACKER")"
# Repo-relative spelling: the rule anchors on (^|/), and the runtime is not the
# only caller (a fixture or a reconcile may hand either spelling).
assert_eq "post-edit 12a: ...nor a repo-relative .claude/.qa-tracking/ path" \
    "skipped" "$(pe_track ".claude/.qa-tracking/impact-report-cwp-94d.json")"
# bd rewrites this on EVERY call, including the gate's own `label add`.
assert_eq "post-edit 12b: .beads/interactions.jsonl is NOT tracked" \
    "skipped" "$(pe_track "$SW_INTER")"
assert_eq "post-edit 12b: ...in its repo-relative spelling too" \
    "skipped" "$(pe_track ".beads/interactions.jsonl")"

# --- the KEEP: THE boundary the regex turns on -----------------------------
assert_eq "post-edit 12c BOUNDARY: .beads/issues.jsonl IS still tracked (committed ledger)" \
    "tracked" "$(pe_track "$SW_LEDGER")"
assert_eq "post-edit 12c BOUNDARY: ...in its repo-relative spelling too" \
    "tracked" "$(pe_track ".beads/issues.jsonl")"

# --- ANTI-OVERREACH: each leg would fall to a DIFFERENT sloppy widening ----
# `.qa-tracking` outside `.claude/` is somebody's source directory.
assert_eq "post-edit 12d: src/.qa-tracking/x.ts stays reviewable (the .claude/ segment is required)" \
    "tracked" "$(pe_track "src/.qa-tracking/x.ts")"
# ...and the leading dot on `.qa-tracking` is required too.
assert_eq "post-edit 12d: .claude/qa-tracking/x.json stays reviewable (dotted name required)" \
    "tracked" "$(pe_track ".claude/qa-tracking/x.json")"
# The interactions branch is $-anchored: a sibling file is not the log.
assert_eq "post-edit 12d: .beads/interactions.jsonl.bak stays reviewable (\$ anchor holds)" \
    "tracked" "$(pe_track ".beads/interactions.jsonl.bak")"
assert_eq "post-edit 12d: .beads/interactions-summary.jsonl stays reviewable" \
    "tracked" "$(pe_track ".beads/interactions-summary.jsonl")"

# --- META: the filter is load-bearing, and the strip is not a no-op -------
# Excise the sentinel-delimited region from a copy and re-run 12a: the artifact
# path must come BACK. Without this leg every "skipped" above could be produced
# by a lib that fails to load rather than by the rule.
#
# The copy lives in the fixture's `.claude/scripts/` — NOT the fixture root.
# post-edit.sh loads workflow-denylist.sh BASH_SOURCE-relative, so a copy parked
# anywhere else has no lib at all, takes the degraded track-everything arm, and
# would report "tracked" for a reason unrelated to the region under test. Same
# constraint the mut32 META below documents.
PE_REAL=$(readlink "$PE" || printf '%s' "$PE")
PE_NOSW="$FIXTURE/.claude/scripts/post-edit-nosw.sh"
awk '/^# SELF-WRITTEN-FILTER BEGIN \(/{skip=1} !skip{print} /^# SELF-WRITTEN-FILTER END \(/{skip=0}' \
    "$PE_REAL" > "$PE_NOSW"
chmod +x "$PE_NOSW"
assert_mutant_applied "post-edit 12M META" "$PE_REAL" "$PE_NOSW"
assert_eq "post-edit 12M META: the SELF-WRITTEN-FILTER region is gone from the copy" "0" \
    "$(grep -c 'SELF-WRITTEN-FILTER' "$PE_NOSW" 2>/dev/null | tr -d '[:space:]')"
assert_eq "post-edit 12M META: excising it actually removed lines (strip is not a no-op)" "yes" \
    "$([ "$(wc -l < "$PE_NOSW")" -lt "$(wc -l < "$PE_REAL")" ] && echo yes || echo no)"
assert_eq "post-edit 12M META: the stripped copy still parses as bash" "0" \
    "$(bash -n "$PE_NOSW" 2>/dev/null && echo 0 || echo 1)"
pe_track_with() {
    : > "$FILE"
    printf '{"tool_input":{"file_path":"%s"}}' "$2" | bash "$1" >/dev/null 2>&1
    if grep -qxF "$2" "$FILE" 2>/dev/null; then printf 'tracked'; else printf 'skipped'; fi
}
# DISCRIMINATING CONTROL: the stripped copy must still be a WORKING denylist.
# If the strip had broken the lib load, node_modules would also come back and
# the "tracked" below would prove nothing about the self-written rule.
assert_eq "post-edit 12M META control: the stripped copy still applies the PATH DENYLIST" \
    "skipped" "$(pe_track_with "$PE_NOSW" "$FIXTURE/node_modules/x.js")"
assert_eq "post-edit 12M META: without the region the review artifact IS tracked (12a WOULD fail — the R2-F5 defect)" \
    "tracked" "$(pe_track_with "$PE_NOSW" "$SW_ART")"
assert_eq "post-edit 12M META: ...and so is .beads/interactions.jsonl (12b WOULD fail)" \
    "tracked" "$(pe_track_with "$PE_NOSW" "$SW_INTER")"
# ...and the real script still drops it, so the difference is the region.
assert_eq "post-edit 12M META: the shipped hook still drops it (the region is the cause)" \
    "skipped" "$(pe_track "$SW_ART")"

# ---------------------------------------------------------------------------
# 13. THE THIRD RULE: a path OUTSIDE $CLAUDE_PROJECT_DIR never enters the
#     tracker (claude-workflow-plugin-fkm.1.15 — acceptance item (2) of the
#     2026-07-29 15:52 bug report).
#
# That report documents TWO failure modes and closes with two numbered
# acceptance items. Item (1) shipped as `qa-gate.sh reconcile-tracker` (the
# under-coverage half: git-visible paths no Write/Edit hook recorded). Item (2)
# — "drop paths outside CLAUDE_PROJECT_DIR at record time" — did not, and went
# unmentioned across four review rounds until the rubric grader read the
# acceptance list back. It is the OVER-coverage half of the same certification
# defect: `post-edit.sh` records `tool_input.file_path` VERBATIM, so the change
# set was never bounded by the project. The recorded instance is exact — a QA
# scratch file at `/tmp/enc-diff.sh`, written with the Write tool, moved
# change_set_hash a950fa6b… -> cb000516… and made `qa-gate.sh approve` refuse
# the CORRECT impact report as stale. Reproduced before the fix on six shapes
# (a bare /tmp file, a different repo, a `mktemp -d` dir, a lexical `..`
# escape, /etc/hosts, ~/.claude/settings.json): all six TRACKED.
#
# WHY THIS IS NOT THE `/tmp` DENYLIST WIDENING THE LIB REFUSES. Two different
# questions. The lib's rule 1 asks "is this shape reviewable work?" and must
# NOT name /tmp or /var/folders, because `specs/impact-report-paths.sh` and
# `specs/worktree-approval-resolution.sh` SEED changed-files.txt with absolute
# paths rooted at `mktemp -d`'s parent — either pattern would empty both change
# sets and both specs would keep passing while proving nothing. This rule asks
# "is this path inside the project THIS session is certifying?", and the answer
# for those two specs' paths is YES: they sit inside the `mktemp -d` root their
# own fixture points CLAUDE_PROJECT_DIR at. 13a's first leg is that exact shape,
# measured through this hook, and it is why the containment check does not carry
# the objection recorded against widening the regex. Both /tmp pins in
# `denylist-source.test.sh` stay green and untouched: they pin the LIB's answer.
#
# The DROP is LOGGED (13d), not silent. Direction matters here: an untracked
# edit is an edit the Stop gate never sees, so a drop this hook makes must leave
# a trace an operator can find — `sync-errors.log` is the channel SessionStart
# already surfaces, and it is the same idiom the flock-less trim skip uses.
# ---------------------------------------------------------------------------
CT_LOG="$FIXTURE/.claude/.qa-tracking/sync-errors.log"
CT_FOREIGN=$(mktemp -d -t pe-foreign.XXXXXX)   # "a different repo"
CT_STRAY=$(mktemp -d -t pe-stray.XXXXXX)       # an agent's own `mktemp -d` probe
CT_SIBLING="${FIXTURE}-sibling"                # STRING-prefixed by the root, not INSIDE it
mkdir -p "$FIXTURE/src" "$CT_FOREIGN/src" "$CT_SIBLING"

# --- 13a THE KEEPS. The first is the one QA's note turns on -----------------
# $FIXTURE *is* a `mktemp -d` root (mk_fixture: mktemp -d -t
# component-fixture.XXXXXX) and CLAUDE_PROJECT_DIR points at it, so this single
# leg is the whole reason a containment check is safe where a /tmp pattern is
# not. If containment ever starts anchoring on a literal prefix instead of the
# runtime root, this fails first and loudest.
assert_eq "post-edit 13a BOUNDARY: an in-project absolute path INSIDE the mktemp root CLAUDE_PROJECT_DIR points at IS tracked (fkm.1.15)" \
    "tracked" "$(pe_track "$FIXTURE/src/a.ts")"
# A relative path has no root to compare against and is resolved AGAINST the
# project root — which is exactly how every reader of the tracker interprets one
# (impact-report.sh relativises, porcelain hands them relative). Dropping these
# would be under-coverage, the failure this task exists to close.
assert_eq "post-edit 13a: a repo-RELATIVE path IS tracked (resolved against the root, never dropped)" \
    "tracked" "$(pe_track "src/a.ts")"
# The PHYSICAL spelling of the same root. On macOS `mktemp -d` yields
# /var/folders/... while `pwd -P` yields /private/var/folders/..., so the
# runtime can hand a path spelled through a symlinked ancestor while
# CLAUDE_PROJECT_DIR carries the logical one. On Linux the two coincide and this
# leg degenerates into a repeat of 13a rather than a skip — stated so the pass
# is not read as proof on a platform that cannot produce the shape.
CT_PHYS=$(cd "$FIXTURE" && pwd -P)
assert_eq "post-edit 13a: the PHYSICAL spelling of the project root IS tracked (macOS /private prefix; a no-op leg on Linux)" \
    "tracked" "$(pe_track "$CT_PHYS/src/a.ts")"

# --- 13b THE DROPS: the three shapes QA measured live, plus the escape ------
# DISCRIMINATING CONTROLS FIRST. Every "skipped" below is an ABSENCE, and rules
# 1 and 2 produce the same observable. So prove neither of them claims these
# paths: if the lib ever grows a /tmp branch, these two fail and force the
# question ("which rule dropped it?") to be re-answered before the legs below
# can be read as containment at all.
ct_lib_verdict() {
    bash -c '. "$1"; workflow_denylisted "$2" && echo drop || echo keep' \
        _ct "$FIXTURE/.claude/scripts/workflow-denylist.sh" "$1" 2>/dev/null
}
ct_sw_verdict() {
    bash -c '. "$1"; workflow_self_written "$2" && echo self-written || echo reviewable' \
        _ct "$FIXTURE/.claude/scripts/workflow-denylist.sh" "$1" 2>/dev/null
}
assert_eq "post-edit 13b control: rule 1 does NOT claim /tmp/enc-diff.sh (so a skip below is containment, not the denylist)" \
    "keep" "$(ct_lib_verdict '/tmp/enc-diff.sh')"
assert_eq "post-edit 13b control: ...nor does rule 2" \
    "reviewable" "$(ct_sw_verdict '/tmp/enc-diff.sh')"
assert_eq "post-edit 13b control: rule 1 does NOT claim the foreign-repo path either" \
    "keep" "$(ct_lib_verdict "$CT_FOREIGN/src/x.ts")"

# The recorded instance, spelled exactly as the bug report recorded it.
assert_eq "post-edit 13b: /tmp/enc-diff.sh is NOT tracked (the recorded over-coverage instance)" \
    "skipped" "$(pe_track "/tmp/enc-diff.sh")"
assert_eq "post-edit 13b: a path in a DIFFERENT repo is NOT tracked" \
    "skipped" "$(pe_track "$CT_FOREIGN/src/x.ts")"
assert_eq "post-edit 13b: an agent's own mktemp -d probe path is NOT tracked" \
    "skipped" "$(pe_track "$CT_STRAY/probe.sh")"
# The `..` leg pins NORMALISATION, not merely the prefix test: this path IS
# string-prefixed by the project root and still resolves outside it. A
# containment check written as a bare `case` on the raw string keeps it.
assert_eq "post-edit 13b: a lexical .. escape out of the project is NOT tracked (the path is normalised, not string-matched)" \
    "skipped" "$(pe_track "$FIXTURE/../escape.ts")"
# ANTI-OVERREACH IN THE OTHER DIRECTION: a sibling directory whose name merely
# STARTS with the root's name is not inside the root. This fails if the
# comparison forgets the path separator (`$root*` rather than `$root/*`), which
# would silently re-admit every sibling worktree of a `mktemp -d` fixture.
assert_eq "post-edit 13b: a SIBLING dir string-prefixed by the root is NOT tracked (the boundary is a path separator)" \
    "skipped" "$(pe_track "$CT_SIBLING/x.ts")"

# --- 13c the envelope contract survives the third early exit ---------------
CT_OUT=$(printf '{"tool_input":{"file_path":"%s"}}' "/tmp/enc-diff.sh" | bash "$PE")
assert_empty_envelope "post-edit 13c: an out-of-project path still emits {}" "$CT_OUT"

# --- 13d the drop is VISIBLE, not silent ----------------------------------
: > "$CT_LOG"
pe_track "$CT_STRAY/probe.sh" >/dev/null
CT_LOGGED=$(grep -c -F "$CT_STRAY/probe.sh" "$CT_LOG" 2>/dev/null || true)
CT_LOGGED=$(printf '%s' "$CT_LOGGED" | head -1 | tr -d '[:space:]')
assert_eq "post-edit 13d: the dropped path is LOGGED to sync-errors.log (SessionStart surfaces it)" \
    "1" "${CT_LOGGED:-0}"
assert_match "post-edit 13d: ...and the log line names the project root it was compared against" \
    "$FIXTURE" "$(cat "$CT_LOG" 2>/dev/null)"
# ...and a KEPT path logs nothing, so the log is a signal rather than a tick.
: > "$CT_LOG"
pe_track "$FIXTURE/src/a.ts" >/dev/null
assert_eq "post-edit 13d: a tracked in-project path logs NOTHING (the log is a signal, not a tick)" \
    "0" "$(wc -c < "$CT_LOG" | tr -d '[:space:]')"

# --- 13e SYMLINKS ACROSS THE BOUNDARY: no symlink is resolved on the KEEP path,
#     so a boundary-crossing symlink is tracked in EITHER direction -----------
# This block exists because the region's own header stated the OPPOSITE for one
# of these shapes and shipped it to docs/HOOKS.md: "a symlink INSIDE the repo
# whose target is outside resolves to the target and is DROPPED" (QA finding
# R5-F1, claude-workflow-plugin-dmi). It is not dropped. No executable line of
# `post-edit.sh` calls readlink/realpath/stat or tests -L, and both `pwd -P` uses
# are `cd <DIRECTORY> && pwd -P`, so nothing in the hook can follow the leaf.
#
# The three legs are three DIFFERENT mechanisms, not one repeated:
#   dirlink   spelled THROUGH the root, so the lexical comparison answers
#             "inside" and the physical retry never runs. Had it run it would
#             have DROPPED this one — its dirname resolves outside.
#   filelink  same first comparison; and the retry would have kept it anyway,
#             because it resolves the DIRNAME (here, the root itself) and
#             reattaches the leaf by name.
#   inlink    the converse direction, and the ONLY shape that reaches the retry.
#             13N excises the retry alone and flips exactly this leg.
#
# THE THIRD LEG IS NOT macOS-ONLY, and that is its point. The residual this task
# shipped claimed the retry was reachable "only in shapes macOS produces". A
# symlink crossing the project boundary is not a `/private` spelling: the region
# carries no platform conditional and `cd <symlink> && pwd -P` is POSIX. Stated
# precisely rather than overclaimed — that reasoning was verified by measurement
# on darwin only, and THIS LEG is what will run it elsewhere; if it ever fails on
# a non-darwin runner, the reasoning was wrong and this comment is the record of
# it. 13a's CT_PHYS leg is the genuinely macOS-specific one, and it exercises
# _PE_ROOT_PHYSICAL rather than this branch — different paths through the region.
CT_SYMOUT=$(mktemp -d -t pe-symout.XXXXXX)
mkdir -p "$CT_SYMOUT"
: > "$CT_SYMOUT/real.ts"
ln -s "$CT_SYMOUT" "$FIXTURE/dirlink"                # in-repo DIRECTORY symlink -> out
ln -s "$CT_SYMOUT/real.ts" "$FIXTURE/filelink.ts"    # in-repo FILE symlink -> out
ln -s "$FIXTURE/src" "$CT_SYMOUT/inlink"             # out-of-repo symlink -> IN

# ANTI-VACUITY CONTROL, and it has to come first: every leg below is a KEEP, and
# rules 1 and 2 can only ever DROP, so the thing that could make these pass for
# nothing is $CT_SYMOUT not actually being outside the root. Prove it is: a plain
# path in the very directory `dirlink` points at is DROPPED.
assert_eq "post-edit 13e control: a plain path in the symlink TARGET directory is NOT tracked (so the target really is outside the root)" \
    "skipped" "$(pe_track "$CT_SYMOUT/x.ts")"

: > "$CT_LOG"
assert_eq "post-edit 13e: a path under an in-repo DIRECTORY symlink pointing OUT of the repo IS tracked (R5-F1: the region used to claim it was dropped)" \
    "tracked" "$(pe_track "$FIXTURE/dirlink/g.ts")"
assert_eq "post-edit 13e: ...silently — a keep, not a drop and not the fail-open track-and-log arm" \
    "0" "$(wc -c < "$CT_LOG" | tr -d '[:space:]')"
: > "$CT_LOG"
assert_eq "post-edit 13e: an in-repo FILE symlink whose target is outside IS tracked (the leaf is never followed)" \
    "tracked" "$(pe_track "$FIXTURE/filelink.ts")"
assert_eq "post-edit 13e: ...silently too" \
    "0" "$(wc -c < "$CT_LOG" | tr -d '[:space:]')"
# The retry's own shape. Lexically outside the root in both spellings; kept only
# because the dirname resolves back inside.
: > "$CT_LOG"
assert_eq "post-edit 13e: an OUT-of-repo symlink pointing INTO the project IS tracked (the SECOND-CHANCE retry's only shape; 13N proves it)" \
    "tracked" "$(pe_track "$CT_SYMOUT/inlink/x.ts")"
assert_eq "post-edit 13e: ...silently too" \
    "0" "$(wc -c < "$CT_LOG" | tr -d '[:space:]')"

# --- 13M META: the region is load-bearing and the strip is not a no-op -----
# Same construction as 12M, same reason: without it every "skipped" above could
# come from a lib that failed to load rather than from the rule under test. The
# copy again lives in the fixture's `.claude/scripts/` so it keeps its sibling
# lib (BASH_SOURCE-relative load).
PE_NOCT="$FIXTURE/.claude/scripts/post-edit-noct.sh"
awk '/^# CONTAINMENT-FILTER BEGIN \(/{skip=1} !skip{print} /^# CONTAINMENT-FILTER END \(/{skip=0}' \
    "$PE_REAL" > "$PE_NOCT"
chmod +x "$PE_NOCT"
assert_mutant_applied "post-edit 13M META" "$PE_REAL" "$PE_NOCT"
assert_eq "post-edit 13M META: the CONTAINMENT-FILTER region is gone from the copy" "0" \
    "$(grep -c 'CONTAINMENT-FILTER' "$PE_NOCT" 2>/dev/null | tr -d '[:space:]')"
assert_eq "post-edit 13M META: excising it actually removed lines (strip is not a no-op)" "yes" \
    "$([ "$(wc -l < "$PE_NOCT")" -lt "$(wc -l < "$PE_REAL")" ] && echo yes || echo no)"
assert_eq "post-edit 13M META: the stripped copy still parses as bash" "0" \
    "$(bash -n "$PE_NOCT" 2>/dev/null && echo 0 || echo 1)"
# DISCRIMINATING CONTROLS: the stripped copy must still be a WORKING hook with
# BOTH other rules intact. If the strip had broken the lib load, the "tracked"
# below would prove nothing about containment.
assert_eq "post-edit 13M META control: the stripped copy still applies the PATH DENYLIST (rule 1)" \
    "skipped" "$(pe_track_with "$PE_NOCT" "$FIXTURE/node_modules/x.js")"
assert_eq "post-edit 13M META control: ...and the SELF-WRITTEN rule (rule 2)" \
    "skipped" "$(pe_track_with "$PE_NOCT" "$SW_ART")"
assert_eq "post-edit 13M META: without the region the out-of-project path IS tracked (13b WOULD fail — the fkm.1.15 defect)" \
    "tracked" "$(pe_track_with "$PE_NOCT" "/tmp/enc-diff.sh")"
assert_eq "post-edit 13M META: ...and so is the foreign-repo path" \
    "tracked" "$(pe_track_with "$PE_NOCT" "$CT_FOREIGN/src/x.ts")"
# ...and the shipped hook still drops it, so the difference is the region.
assert_eq "post-edit 13M META: the shipped hook still drops it (the region is the cause)" \
    "skipped" "$(pe_track "/tmp/enc-diff.sh")"

# --- 13N META: the SECOND-CHANCE retry is load-bearing ----------------------
# 13M strips the WHOLE region, which tells you containment exists but nothing
# about its two comparisons. This strips the INNER SECOND-CHANCE region only —
# one variable — and the discriminating result is that exactly one of 13e's three
# legs moves. Written because the fix round shipped "no assertion distinguishes
# this branch from its absence" as a residual, having also believed the branch
# was macOS-only; QA measured otherwise and this is the committed form of that
# measurement.
#
# WHY A SENTINEL REGION AND NOT A LINE-NUMBER `sed`: an excision anchored on
# absolute line numbers decays the moment anything above it moves, and this round
# proved the point on itself: the comment introducing this META cited the retry's
# line numbers, and its own insertion had already invalidated them. The sentinels
# make the excision line-number-independent, exactly as 12M/13M's do, and no
# assertion or comment in 13e/13N names a line number. `_PE_RESOLVED=""` is
# initialised OUTSIDE them on purpose (see the hook), so the stripped copy leaves
# it EMPTY rather than UNSET and the drop below is a stated behaviour rather than
# an artifact of the hook not running under `set -u`.
#
# THE STRIP PATTERNS ARE ANCHORED (`^ *#`), matching the paired assertion below
# (QA finding R4-F5). Unanchored, they matched the sentinel name ANYWHERE on a
# line — so a future prose line quoting `# SECOND-CHANCE BEGIN (` mid-sentence
# would start the strip early, delete real code above the region, and the
# assertions could not tell: "the retry's line is gone" and "lines were removed"
# would both still pass, and the flip below would still flip. The sentinel lines
# are indented inside the hook's `if`, hence `^ *#` rather than 13M's `^#`.
PE_NOSC="$FIXTURE/.claude/scripts/post-edit-nosc.sh"
awk '/^ *# SECOND-CHANCE BEGIN \(/{skip=1} !skip{print} /^ *# SECOND-CHANCE END \(/{skip=0}' \
    "$PE_REAL" > "$PE_NOSC"
chmod +x "$PE_NOSC"
assert_mutant_applied "post-edit 13N META" "$PE_REAL" "$PE_NOSC"
# The region's CODE is what must be gone, and that is what is asserted. A bare
# `grep -c SECOND-CHANCE` (12M/13M's idiom for their own sentinels) is WRONG here
# and was measured wrong: the hook's header names this region in prose three
# times, outside the sentinels, so the token count on a correctly stripped copy is
# 3 rather than 0. Assert the retry's own line, then the sentinel LINES.
assert_eq "post-edit 13N META: the retry's own line is gone from the copy (the strip removed the CODE, not just a marker)" "0" \
    "$(grep -c '_PE_DIR=$(cd' "$PE_NOSC" 2>/dev/null | tr -d '[:space:]')"
assert_eq "post-edit 13N META: ...and both SECOND-CHANCE sentinel lines with it" "0" \
    "$(grep -cE '^ *# SECOND-CHANCE (BEGIN|END) \(' "$PE_NOSC" 2>/dev/null | tr -d '[:space:]')"
assert_eq "post-edit 13N META: excising it actually removed lines (strip is not a no-op)" "yes" \
    "$([ "$(wc -l < "$PE_NOSC")" -lt "$(wc -l < "$PE_REAL")" ] && echo yes || echo no)"
assert_eq "post-edit 13N META: the stripped copy still parses as bash" "0" \
    "$(bash -n "$PE_NOSC" 2>/dev/null && echo 0 || echo 1)"
# STRUCTURAL CONTROL: the strip is SURGICAL. Both CONTAINMENT-FILTER sentinels
# must survive, or this is 13M's experiment wearing 13N's name.
assert_eq "post-edit 13N META control: the enclosing CONTAINMENT-FILTER region SURVIVES the strip (both sentinel lines present)" \
    "2" "$(grep -cE '^# CONTAINMENT-FILTER (BEGIN|END) \(' "$PE_NOSC" 2>/dev/null | tr -d '[:space:]')"
# BEHAVIOURAL CONTROLS: all three other rules, and containment's FIRST
# comparison, must still work in the stripped copy — otherwise the flip below
# could be a broken hook rather than a missing retry.
assert_eq "post-edit 13N META control: the stripped copy still applies the PATH DENYLIST (rule 1)" \
    "skipped" "$(pe_track_with "$PE_NOSC" "$FIXTURE/node_modules/x.js")"
assert_eq "post-edit 13N META control: ...and the SELF-WRITTEN rule (rule 2)" \
    "skipped" "$(pe_track_with "$PE_NOSC" "$SW_ART")"
assert_eq "post-edit 13N META control: ...and still tracks an in-project path (the hook works)" \
    "tracked" "$(pe_track_with "$PE_NOSC" "$FIXTURE/src/a.ts")"
assert_eq "post-edit 13N META control: ...and still drops a plainly out-of-project path (containment's FIRST comparison is intact)" \
    "skipped" "$(pe_track_with "$PE_NOSC" "$CT_SYMOUT/x.ts")"
# THE FLIP: the one leg the retry is the cause of.
assert_eq "post-edit 13N META: without the retry the out-of-repo symlink pointing IN is DROPPED (13e's third leg WOULD fail)" \
    "skipped" "$(pe_track_with "$PE_NOSC" "$CT_SYMOUT/inlink/x.ts")"
assert_eq "post-edit 13N META: the shipped hook still tracks it (the retry is the cause)" \
    "tracked" "$(pe_track "$CT_SYMOUT/inlink/x.ts")"
# AND THE TWO LEGS IT IS *NOT* THE CAUSE OF. This is the corrected R5-F1
# mechanism as an assertion rather than as prose: the in-repo symlink shapes never
# reach the retry, so removing it cannot move them.
assert_eq "post-edit 13N META: the in-repo DIRECTORY symlink is tracked WITH the retry gone (it never reached it — the lexical comparison keeps it)" \
    "tracked" "$(pe_track_with "$PE_NOSC" "$FIXTURE/dirlink/g.ts")"
assert_eq "post-edit 13N META: ...and so is the in-repo FILE symlink" \
    "tracked" "$(pe_track_with "$PE_NOSC" "$FIXTURE/filelink.ts")"

# --- 13R META: the two in-repo shapes are kept by DIFFERENT mechanisms -------
# 13N's last two legs prove neither in-repo shape REACHES the retry. That pair is
# SYMMETRIC — it says nothing about how the two would differ if the retry DID
# run, which is exactly the asymmetry the region's header and the `dmi`
# completion contract assert: the DIRECTORY symlink would have been dropped
# (its dirname resolves outside the root), the FILE symlink kept regardless (its
# dirname is the root, and the leaf is reattached by name and never followed).
# QA finding R4-F3: that counterfactual was true but prose-only, while the
# contract described it as asserted. This block is the assertion.
#
# ONE VARIABLE, and it is the guard rather than the body: the lexical test that
# decides whether the retry runs is forced TRUE, so every path takes the retry.
# The region between the sentinels is asserted byte-identical to the shipped
# copy, which is what makes each flip attributable to the resolution the retry
# performs rather than to a rewritten branch.
#
# Text-anchored on the guard, never a line number (LESSONS llh.20), and gated on
# assert_mutant_applied: a substitution mutant's failure mode is a byte-identical
# copy that reports green, and this spec's own history has two of those.
pe_second_chance_region() {
    # The SECOND-CHANCE region, sentinels included. Same anchored patterns 13N
    # strips with, so "the body is untouched" is measured over the same bytes
    # 13N's excision removes.
    awk '/^ *# SECOND-CHANCE BEGIN \(/{inr=1} inr{print} /^ *# SECOND-CHANCE END \(/{inr=0}' "$1"
}
PE_FORCED="$FIXTURE/.claude/scripts/post-edit-forced-retry.sh"
awk '
    !done && /^[[:space:]]*if ! _pe_within "\$_PE_CANDIDATE"; then[[:space:]]*$/ {
        print "    if true; then"; done=1; next
    }
    { print }
' "$PE_REAL" > "$PE_FORCED"
chmod +x "$PE_FORCED"
if assert_mutant_applied "post-edit 13R META" "$PE_REAL" "$PE_FORCED"; then
    assert_eq "post-edit 13R META: the lexical guard is gone from the copy (the mutation landed where it was aimed)" \
        "0" "$(grep -c 'if ! _pe_within' "$PE_FORCED" | tr -d '[:space:]')"
    assert_eq "post-edit 13R META: ...replaced by exactly one forced branch" \
        "1" "$(grep -c '^    if true; then$' "$PE_FORCED" | tr -d '[:space:]')"
    assert_eq "post-edit 13R META: the retry region is BYTE-IDENTICAL to the shipped one (one variable, and it is not the body)" \
        "$(pe_second_chance_region "$PE_REAL")" "$(pe_second_chance_region "$PE_FORCED")"
    assert_eq "post-edit 13R META: the copy still parses as bash" "0" \
        "$(bash -n "$PE_FORCED" 2>/dev/null && echo 0 || echo 1)"
    # CONTROLS FIRST: with every path taking the retry, the retry must still be a
    # WORKING containment check in both directions, or a flip below could be a
    # broken mutant rather than a resolved dirname.
    assert_eq "post-edit 13R META control: an ordinary in-project path is still tracked (the forced retry resolves back inside)" \
        "tracked" "$(pe_track_with "$PE_FORCED" "$FIXTURE/src/a.ts")"
    assert_eq "post-edit 13R META control: a plainly out-of-project path is still dropped (the retry cannot rescue it)" \
        "skipped" "$(pe_track_with "$PE_FORCED" "$CT_SYMOUT/x.ts")"
    assert_eq "post-edit 13R META control: the out-of-repo symlink pointing IN is still tracked (the shape the retry exists for)" \
        "tracked" "$(pe_track_with "$PE_FORCED" "$CT_SYMOUT/inlink/x.ts")"
    # THE ASYMMETRY. Same mutant, same call, two in-repo shapes, opposite answers.
    : > "$CT_LOG"
    assert_eq "post-edit 13R META: with the retry FORCED, the in-repo DIRECTORY symlink is DROPPED (its dirname resolves outside)" \
        "skipped" "$(pe_track_with "$PE_FORCED" "$FIXTURE/dirlink/g.ts")"
    assert_eq "post-edit 13R META: ...through the containment arm, which LOGS the drop (not some other early exit)" \
        "1" "$(grep -c -F "$FIXTURE/dirlink/g.ts" "$CT_LOG" 2>/dev/null | tr -d '[:space:]')"
    assert_eq "post-edit 13R META: while the in-repo FILE symlink is STILL TRACKED (dirname is the root; the leaf is never followed)" \
        "tracked" "$(pe_track_with "$PE_FORCED" "$FIXTURE/filelink.ts")"
    # ...and the shipped hook keeps BOTH, so the divergence is the forced retry
    # rather than anything about the two shapes on the real code path.
    assert_eq "post-edit 13R META: the shipped hook tracks the DIRECTORY symlink (the retry never runs for it)" \
        "tracked" "$(pe_track "$FIXTURE/dirlink/g.ts")"
    assert_eq "post-edit 13R META: ...and the FILE symlink too (13e, unchanged)" \
        "tracked" "$(pe_track "$FIXTURE/filelink.ts")"
fi
: > "$CT_LOG"
rm -rf "$CT_FOREIGN" "$CT_STRAY" "$CT_SIBLING" "$CT_SYMOUT"
rm -f "$FIXTURE/dirlink" "$FIXTURE/filelink.ts"

# ===========================================================================
# Mutation-survivor kills (G2.6ix / claude-workflow-plugin-llh.5).
#
# The original C.3 sweep (task claude-workflow-plugin-6ix, theme F) left the
# post-edit.sh tracking/cadence logic uncovered: the L2 spec above asserts the
# dedup/denylist/envelope contract but NEVER drives the trim-at-1000 threshold,
# the every-10th-edit comment cadence, the sort|wc pipeline, the EDIT_COUNT
# increment, the CLAUDE_PROJECT_DIR default, or the LINE_COUNT default. Each
# block below kills one surviving mutant; every kill was proven mutant->FAIL /
# original->PASS during development. Survivor ids map to
# .claude/.mutation-runs/20260612T063107Z/verdict.json (the original record);
# the current re-sweep is .claude/.mutation-runs/20260613T102846Z.
#
# These need a SECOND fixture (bd-initialised, isolated counters) because the
# fixture above has accumulated tracking/edit-count state and no .beads. We
# build a fresh one per the mk_fixture contract.
mk_fixture
FIXTURE2="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
PE2="$FIXTURE2/.claude/scripts/post-edit.sh"
TRACK2="$FIXTURE2/.claude/.qa-tracking"
FILE2="$TRACK2/changed-files.txt"
ECF="$TRACK2/edit-count"

# Helper: seed changed-files.txt with N synthetic unique tracked paths.
seed_tracking_lines() {
    awk -v n="$1" 'BEGIN{for(i=1;i<=n;i++)print "src/f"i".ts"}' > "$FILE2"
}
# Helper: run post-edit once for a given file path (returns its stdout).
run_pe2() {
    printf '%s' "{\"tool_input\":{\"file_path\":\"$1\"}}" | bash "$PE2"
}
# Helper: count Progress: comments on a task.
progress_comment_count() {
    bd_show_with_comments "$1" \
        | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | map(select(.text|test("Progress:")))|length' \
        2>/dev/null || echo "0"
}

# --- id32 (F8, line 114): EDIT_COUNT increment + 1 vs + 2 -----------------
# A single edit from a zero counter must leave the persisted edit-count at 1.
# The +2 mutant writes 2 (and halves the comment cadence). Needs an active
# task + .beads so the EDIT_COUNT block runs.
TID_INC=$(cd "$FIXTURE2" && bd create "pe increment" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf '%s\n' "$TID_INC" > "$TRACK2/current-task"
rm -f "$ECF"
run_pe2 "src/inc.ts" >/dev/null
INC_AFTER=$(cat "$ECF" 2>/dev/null | tr -d '[:space:]')
assert_eq "post-edit mut32: one edit increments edit-count by exactly 1 (not 2)" \
    "1" "$INC_AFTER"

# --- id26 (F1, line 117): comment cadence % 10 -eq 0 vs -ne 0 -------------
# At edit #9 (not a multiple of 10) the original posts NO progress comment.
# The -ne mutant posts on every non-multiple, so #9 would post one.
TID_CAD=$(cd "$FIXTURE2" && bd create "pe cadence" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf '%s\n' "$TID_CAD" > "$TRACK2/current-task"
seed_tracking_lines 3
printf '8' > "$ECF"            # next edit -> 9
run_pe2 "src/cad.ts" >/dev/null
CAD9=$(progress_comment_count "$TID_CAD")
assert_eq "post-edit mut26: NO progress comment at edit #9 (cadence fires only on multiples of 10)" \
    "0" "$CAD9"

# --- id30 (F5, line 120): drop the wc -l pipeline segment -----------------
# At edit #10 the original posts "Progress: <integer> files edited". Dropping
# wc -l makes UNIQUE_COUNT the newline-joined file list, so the comment reads
# "Progress: <path>\n<path>... files edited". Assert the count field is a bare
# integer immediately followed by " files edited".
TID_PIPE=$(cd "$FIXTURE2" && bd create "pe pipeline" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf '%s\n' "$TID_PIPE" > "$TRACK2/current-task"
seed_tracking_lines 3
printf '9' > "$ECF"            # next edit -> 10
run_pe2 "src/f1.ts" >/dev/null
PIPE_TEXT=$(bd_show_with_comments "$TID_PIPE" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | map(select(.text|test("Progress:")))|.[0].text // ""' 2>/dev/null)
assert_match "post-edit mut30: progress comment count is a bare integer (wc -l pipeline intact)" \
    "Progress: [0-9]+ files edited" "$PIPE_TEXT"
# Negative: the file-list form (a slash path before 'files edited') must NOT appear.
PIPE_BADFORM=$(printf '%s' "$PIPE_TEXT" | grep -c 'src/.*files edited' || true)
PIPE_BADFORM=$(printf '%s' "$PIPE_BADFORM" | tr -d '[:space:]')
assert_eq "post-edit mut30: progress comment is NOT the raw file list" "0" "$PIPE_BADFORM"

# --- id25 (F1, line 98): trim threshold -gt 1000 vs -le 1000 --------------
# A small tracking file (well under 1000 lines) must NOT be trimmed. The -le
# mutant trims on every edit (sort -u | tail -500). Seed 500 unique lines,
# add one NEW path; the original leaves 501 (no trim), the mutant collapses
# to 500. Use a fixture with NO active task / no .beads churn so only the
# trim path is exercised. We reuse FIXTURE2 but clear the task first.
rm -f "$TRACK2/current-task"
seed_tracking_lines 500
run_pe2 "src/trim-new-small.ts" >/dev/null
SMALL_COUNT=$(wc -l < "$FILE2" | tr -d ' ')
assert_eq "post-edit mut25: small tracking file (<=1000) is NOT trimmed (count stays 501)" \
    "501" "$SMALL_COUNT"

# --- id31 (F6, line 98): trim boundary -gt 1000 vs -ge 1000 ---------------
# At exactly 1000 lines the original must NOT trim ([1000 -gt 1000] = false);
# the -ge mutant trims to 500. Seed 999 unique lines then append one NEW path
# (this platform's no-flock append makes wc == 1000 exactly).
seed_tracking_lines 999
run_pe2 "src/trim-boundary-new.ts" >/dev/null
BOUNDARY_COUNT=$(wc -l < "$FILE2" | tr -d ' ')
assert_eq "post-edit mut31: at exactly 1000 lines the file is NOT trimmed (boundary; count stays 1000)" \
    "1000" "$BOUNDARY_COUNT"

# --- id28 (F4, line 16): CLAUDE_PROJECT_DIR default removal ----------------
# Running the hook with CLAUDE_PROJECT_DIR UNSET must still work via the
# $(pwd) fallback: rc 0 and the tracking file lands under the cwd. The mutant
# ${CLAUDE_PROJECT_DIR} (no default) yields PROJECT_DIR='', mkdir -p
# '/.claude/.qa-tracking' fails under set -e, the hook aborts non-zero and no
# tracking file is written. Run in a throwaway cwd so we don't write into the
# fixture root.
ID28_CWD=$(mktemp -d -t pe-id28-cwd.XXXXXX)
ID28_RC=0
( cd "$ID28_CWD" && env -u CLAUDE_PROJECT_DIR bash "$PE2" <<<'{"tool_input":{"file_path":"src/env.ts"}}' >/dev/null 2>&1 ) || ID28_RC=$?
ID28_TRACKED="no"
[ -s "$ID28_CWD/.claude/.qa-tracking/changed-files.txt" ] && ID28_TRACKED="yes"
rm -rf "$ID28_CWD"
assert_eq "post-edit mut28: CLAUDE_PROJECT_DIR unset -> hook still exits 0 (pwd fallback)" \
    "0" "$ID28_RC"
assert_eq "post-edit mut28: CLAUDE_PROJECT_DIR unset -> tracking still written (pwd fallback)" \
    "yes" "$ID28_TRACKED"

# --- id29 (F4, line 98): LINE_COUNT default removal ------------------------
# When wc emits an empty string the original's ${LINE_COUNT:-0} normalises to
# "0" so [ 0 -gt 1000 ] is clean. The mutant ${LINE_COUNT} leaves it empty so
# [ "" -gt 1000 ] prints an 'integer/unary' error on stderr. Stub wc to emit
# empty and assert the hook's stderr carries NO such error. (No .beads dir in
# this throwaway cwd so the cadence block is skipped — isolates the LINE_COUNT
# path.)
ID29_DIR=$(mktemp -d -t pe-id29.XXXXXX)
mkdir -p "$ID29_DIR/.claude/.qa-tracking" "$ID29_DIR/bin"
printf 'src/seed.ts\n' > "$ID29_DIR/.claude/.qa-tracking/changed-files.txt"
printf '#!/bin/bash\nprintf ""\n' > "$ID29_DIR/bin/wc"; chmod +x "$ID29_DIR/bin/wc"
ID29_ERR=$( cd "$ID29_DIR" && PATH="$ID29_DIR/bin:$PATH" CLAUDE_PROJECT_DIR="$ID29_DIR" bash "$PE2" <<<'{"tool_input":{"file_path":"src/seed.ts"}}' 2>&1 1>/dev/null )
rm -rf "$ID29_DIR"
ID29_BAD=$(printf '%s' "$ID29_ERR" | grep -cE 'integer expression expected|unary operator expected' || true)
ID29_BAD=$(printf '%s' "$ID29_BAD" | tr -d '[:space:]')
assert_eq "post-edit mut29: empty LINE_COUNT does NOT trip an integer-expression error (\${LINE_COUNT:-0} default intact)" \
    "0" "$ID29_BAD"

# --- META-TEST: prove the mut32 increment assertion is load-bearing -------
# Build a copy of post-edit.sh with the +1 increment mutated to +2 and re-run
# the increment scenario; the edit-count must read 2 (so the mut32 assertion
# would FAIL). This proves the assertion is sensitive to the regression it
# names, not passing for an incidental reason.
#
# TEXT-anchored on the increment statement, never on a line number (LESSONS
# llh.20). The previous `NR==114` form silently un-landed the moment 3mg.1
# added the shared-denylist source block above it: the mutation never
# applied, and only the sanity assertion caught it.
#
# The copy lives in the fixture's `.claude/scripts/` — NOT the fixture root.
# Since 3mg.1 post-edit.sh loads `workflow-denylist.sh` from its OWN
# directory (BASH_SOURCE-relative); a copy parked anywhere else loses the
# denylist and takes the degraded "track everything" arm, so the mutant
# would no longer be a faithful copy of the script under test.
PE2_REAL=$(readlink "$PE2" || printf '%s' "$PE2")
PE2_MUT="$FIXTURE2/.claude/scripts/post-edit-mut32.sh"
awk '
    !done && /^[[:space:]]*EDIT_COUNT=\$\(\(EDIT_COUNT \+ 1\)\)[[:space:]]*$/ {
        print "    EDIT_COUNT=$((EDIT_COUNT + 2))"; done=1; next
    }
    { print }
' "$PE2_REAL" > "$PE2_MUT"
chmod +x "$PE2_MUT"
# THE GUARD FIRST (R4-F4): a mutation that matched nothing yields a byte-identical
# copy, and every leg below then measures the SHIPPED hook while reporting on a
# mutant — the +2 assertion would read edit-count 1 and look like a code defect
# rather than a harness one. The textual sanity checks that follow pin WHICH
# mutation landed; this pins THAT one did.
assert_mutant_applied "post-edit META (mut32)" "$PE2_REAL" "$PE2_MUT"
# Sanity: the mutation landed exactly once and the original statement is gone.
MUT_LANDED=$(grep -c 'EDIT_COUNT + 2' "$PE2_MUT" || true)
MUT_LANDED=$(printf '%s' "$MUT_LANDED" | tr -d '[:space:]')
assert_eq "post-edit META: +2 mutation applied to copy (text-anchored)" "1" "$MUT_LANDED"
MUT_ORIG_GONE=$(grep -c 'EDIT_COUNT=\$((EDIT_COUNT + 1))' "$PE2_MUT" || true)
MUT_ORIG_GONE=$(printf '%s' "$MUT_ORIG_GONE" | tr -d '[:space:]')
assert_eq "post-edit META: original +1 increment replaced in the copy" "0" "$MUT_ORIG_GONE"
# Sanity: the mutant still resolves the shared denylist (it is a sibling of
# the fixture's workflow-denylist.sh), so it exercises the real filter path.
MUT_LIB_SIBLING=$([ -e "$FIXTURE2/.claude/scripts/workflow-denylist.sh" ] && echo yes || echo no)
assert_eq "post-edit META: mutant copy sits next to workflow-denylist.sh" "yes" "$MUT_LIB_SIBLING"
TID_META=$(cd "$FIXTURE2" && bd create "pe meta increment" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf '%s\n' "$TID_META" > "$TRACK2/current-task"
rm -f "$ECF"
printf '%s' '{"tool_input":{"file_path":"src/meta.ts"}}' | bash "$PE2_MUT" >/dev/null
META_AFTER=$(cat "$ECF" 2>/dev/null | tr -d '[:space:]')
assert_eq "post-edit META: under +2 mutant one edit yields edit-count 2 (mut32 assertion WOULD fail)" \
    "2" "$META_AFTER"

[ "$FAIL" -eq 0 ]

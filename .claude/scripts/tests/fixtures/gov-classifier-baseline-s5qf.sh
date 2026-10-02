# ===========================================================================
# FROZEN BASELINE — the doc-only classifier as it stood at 0de5ceb, i.e. the
# s5qf-era `is_doc_only_path` + its two vetoes, BEFORE claude-workflow-plugin-
# mdnc rewrote the governing veto's path reduction.
#
# THIS FILE IS NOT MAINTAINED AND MUST NOT BE "UPDATED". It is a reference
# point, not a second definition: nothing in the plugin sources it, and
# `doc-only-classifier.test.sh` section 10 drives it ONLY as the left-hand side
# of a monotonicity differential — "every path the s5qf classifier refused the
# fast path to, the shipped classifier still refuses". Refreshing it to match
# whatever is shipped today would silently discard that invariant, which is why
# section 10 pins this file's sha256 and fails on any edit.
#
# WHY A SECOND COPY IS ALLOWED HERE, given the test file's own header warns
# against exactly that. The warning is about a copy used AS the thing under
# test — that copy can drift from the one that gates releases and nobody
# notices. This copy is never the thing under test; it is the OLD artifact a
# monotonicity claim is measured against, the same role a golden file plays.
# A monotonicity claim is a claim about the DIFFERENCE between two artifacts,
# so it cannot be made by running one of them.
#
# WHY IT WAS ADDED. R1-F1 on mdnc: `cd -P "$dir"` was substituted for
# `cd "$dir" && pwd -P` at two sites. Those are different functions — they
# diverge when a symlink precedes a `..` — so the substitution DELETED a
# reduction, and the deletion failed OPEN: a declared governing artifact took
# the doc-only fast path with reviewed_by=none in shapes this baseline vetoes.
# 109 new assertions were green over it, because every one of them ran the
# shipped bytes alone.
#
# REGENERATION (only ever to verify provenance, never to move the pin):
#   git show 0de5ceb:.claude/scripts/verify-before-stop.sh > /tmp/vbs.sh
#   { awk '/^# DOC-CONTENT-VETO BEGIN/,/^# DOC-CONTENT-VETO END/' /tmp/vbs.sh
#     printf '\n'
#     awk '/^# GOVERNING-ARTIFACT-VETO BEGIN/,/^# GOVERNING-ARTIFACT-VETO END/' /tmp/vbs.sh
#     printf '\n'
#     awk '/^is_doc_only_path\(\) \{/,/^\}/' /tmp/vbs.sh; }
# i.e. `extract_classifier` from doc-only-classifier.test.sh, applied to that
# commit. Everything below this header is that output, byte for byte.
# ===========================================================================
# DOC-CONTENT-VETO BEGIN (claude-workflow-plugin-bbh)
#
# IS THIS PATH AFFIRMATIVELY EXECUTABLE CONTENT?
#
# Two facts about the FILE, neither of them about its name or its position:
#   - the executable bit is set on a regular file, i.e. the operating system
#     will run it;
#   - its first two bytes are `#!`, i.e. it names its own interpreter.
#
# This is the half of claude-workflow-plugin-bbh that does not merely delete a
# bad inference. The arms that survive in is_doc_only_path still read a content
# type off a name — `*.md`, or the exact basename `LICENSE` — so a matching name
# is NECESSARY and must not be SUFFICIENT. A file the OS will execute is not
# documentation whatever it is called, and that is a question about the file.
#
# POSITIVE EVIDENCE ONLY. This is the one deliberate asymmetry and it is load-
# bearing in the availability direction. A path that does not resolve to a
# regular file yields no evidence either way, and the name arms then decide
# exactly as they did before. Three ordinary states reach that branch:
#   * a DELETION — `git status` reports ` D docs/old-guide.md`, reviewable_
#     changes strips the status prefix, and the path arrives here with nothing
#     behind it. Deleting documentation is a legitimate doc-only commit, and a
#     deleted file ships no content, so "unresolvable => reviewable" would
#     deadlock it while buying no safety at all.
#   * the old side of a rename.
#   * a tracker entry spelled relative to a different cwd, or a change set
#     belonging to another worktree.
# So the veto only ever NARROWS the name arms. It cannot widen them, and it
# cannot turn an absent file into a refusal.
#
# THE ONE THING IT TRADES: on a filesystem that reports every file executable
# (some Windows/Cygwin-style mounts historically did), every doc-named path
# would be vetoed and F1 would stop firing — a FALSE BLOCK, never a false
# release. That is the survivable direction of this pair, and the log line the
# caller writes on each veto is what makes it diagnosable rather than baffling.
#
# Relative paths resolve against $PROJECT_DIR, not the process cwd: this hook is
# invoked from wherever the session happens to be, and post-edit.sh records
# absolute paths while `git status --porcelain` yields repo-relative ones — both
# spellings arrive here.
#
# `read -r -n 2` rather than `head -c 2`: no fork, and it is bounded to two
# bytes, so a doc-named file that is really a 200MB single-line blob cannot be
# slurped into memory. `|| true` guards the EOF return of a file shorter than
# two bytes — bash has already assigned the partial read by then, so the
# two-byte file containing exactly `#!` is still caught (verified against
# /bin/bash 3.2.57, which is what these hooks run under on macOS).
DOC_VETO_REASON=""
doc_path_is_executable_content() {
    local p="$1" abs first
    DOC_VETO_REASON=""
    [ -n "$p" ] || return 1
    case "$p" in
        /*) abs="$p" ;;
        *)  abs="$PROJECT_DIR/$p" ;;
    esac
    # Not a regular file: absent, deleted, a directory, a device. No evidence.
    [ -f "$abs" ] || return 1
    if [ -x "$abs" ]; then
        DOC_VETO_REASON="the executable bit is set"
        return 0
    fi
    first=""
    IFS= read -r -n 2 first < "$abs" 2>/dev/null || true
    if [ "$first" = '#!' ]; then
        DOC_VETO_REASON="the file begins with a #! shebang"
        return 0
    fi
    return 1
}
# DOC-CONTENT-VETO END (claude-workflow-plugin-bbh)

# GOVERNING-ARTIFACT-VETO BEGIN (claude-workflow-plugin-s5qf)
#
# IS THIS PATH PART OF THE PLUGIN'S OWN DECLARED SURFACE?
#
# The second veto, and the one the content veto above cannot express. An agent
# prompt, a rubric, a skill and the lessons ledger are markdown; they carry no
# executable bit and no `#!`, so `doc_path_is_executable_content` correctly and
# by construction has no opinion about them. They are nevertheless EXECUTABLE
# POLICY IN PROSE — the runtime loads `.claude/agents/*.md` as the agent, the
# grader reads `.claude/rubrics/*.md` as its criteria and `LESSONS.md` as
# criteria by reference, and `.claude/skills/**/SKILL.md` is loaded and
# followed. Auto-approving a change to one of them with `reviewed_by=none`
# because it ends in `.md` is the same category error `LICENSE.sh` was: a NAME
# asserting a content type the file does not have. The live illustration is on
# the filing — `.claude/agents/qa.md` was a member of bbh's own change set, and
# had that edit landed alone F1 would have released an unreviewed change to the
# QA agent's own prompt.
#
# THIS IS NOT A THIRD SHAPE INFERENCE. bbh deleted `*/docs/*|docs/*` and
# `LICENSE.*` because a path's POSITION and a path's NAME cannot tell you what
# is inside it, and the direction was "remove the inference, do not widen the
# pattern list". A `docs/specs/` arm or a `.claude/agents/` arm here would be
# that identical inference wearing a different suffix. So this asks a question
# with a factual answer instead: is the path one the PROJECT ITSELF declares it
# ships? That answer already exists, in the one artifact whose whole purpose is
# to enumerate the shipped surface — `workflow-manifest.sh`, which install.sh
# copies from and every frozen table under manifests/ is cut from. No second
# vocabulary is minted here; see that file's GOVERNING-ARTIFACT-SURFACE region
# for what is in the set, what deliberately is not, and the measured cost.
#
# POSITIVE EVIDENCE ONLY, the same asymmetry the content veto states and for
# the same reason. If the query cannot be answered — the manifest script is
# missing, or it failed — the set is EMPTY, nothing is vetoed, and F1 behaves
# exactly as it did before this region existed. That is deliberate: the
# alternative (treat an unanswerable query as "everything is governing")
# refuses EVERY documentation commit on a partial install, trading a narrow
# residual for total loss of the most-travelled fast path. The failure is
# logged once per Stop so it surfaces at SessionStart rather than being
# baffling. An install that never declares a surface is likewise unaffected,
# which is what makes this safe to ship into arbitrary projects.
#
# COST IS BOUNDED BY THE PLUGIN'S FOOTPRINT, NOT THE PROJECT'S. The query is
# maxdepth-1 scans plus three pruned walks over `.claude/`, and it carries no
# digests at all, so it needs no sha256 tool and does not grow with the size of
# the operator's repo. Measured on this repo at b8f0095: 0.032s for 134 rows
# (`time bash .claude/scripts/workflow-manifest.sh governing .`), versus 0.339s
# for the hashed `generate`. It runs at most once per Stop — see the memo
# below, and note that the result is deliberately NOT captured through `$( )`
# at the call site, because a subshell would discard the memo and re-fork the
# query for every path (LESSONS.md, 2026-06-12).
GOV_VETO_ORIGIN=""
_GOV_SET=""
_GOV_LOADED=0
_GOV_ROOT=""
_GOV_ROOT_PHYS=""

# Resolved relative to THIS script (BASH_SOURCE), not $PROJECT_DIR — the same
# rule, and the same reason, as the workflow-denylist lookup above: the gate may
# run with CLAUDE_PROJECT_DIR pointing at a different checkout than the install
# it was launched from, and the manifest generator is one product with this
# hook. The TREE being enumerated is still $PROJECT_DIR; those are two
# different questions and are answered separately.
_GOV_TOOL=""
_gov_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || _gov_dir=""
if [ -n "$_gov_dir" ]; then
    _GOV_TOOL="$_gov_dir/workflow-manifest.sh"
fi

# load_governing_set — populate $_GOV_SET once, then never again. Always
# returns 0: an unanswerable query is a logged no-op, never a gate failure.
#
# The rc of the query is captured rather than swallowed, because an EMPTY set
# is a legitimate answer (a tree with no plugin surface declares nothing) and
# an empty set from a FAILED run is not. Collapsing the two would make a broken
# query indistinguishable from a correct one — the failure shape LESSONS.md
# records for absence-shaped assertions (2026-07-28).
load_governing_set() {
    [ "$_GOV_LOADED" = "1" ] && return 0
    _GOV_LOADED=1
    _GOV_SET=""
    # Two spellings of the same root, both trailing-slash-free. `${x%/}` keeps
    # the FIRST reduction attempt correct on its own terms: with
    # PROJECT_DIR="/a/b/" the literal prefix would otherwise be "/a/b//", which
    # no recorded path starts with.
    #
    # It is DEFENCE IN DEPTH, not the thing that makes that case work, and the
    # difference is stated because it was measured: removing this strip reddens
    # NOTHING, because `pwd -P` never yields a trailing slash, so attempt 2
    # already catches the case, and attempt 3 catches it again. Do not read the
    # trailing-slash leg in doc-only-classifier.test.sh as a control on this
    # line — it pins the OUTCOME, which three arms cover.
    _GOV_ROOT="${PROJECT_DIR%/}"
    _GOV_ROOT_PHYS=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P) || _GOV_ROOT_PHYS=""
    _GOV_ROOT_PHYS="${_GOV_ROOT_PHYS%/}"
    if [ -z "$_GOV_TOOL" ] || [ ! -f "$_GOV_TOOL" ]; then
        log_sync_error "F1: the governing-artifact query is unavailable (workflow-manifest.sh not found beside this hook), so the doc-only fast path classifies exactly as it did before claude-workflow-plugin-s5qf; a change to an agent prompt, a rubric or CLAUDE.md alone can auto-approve"
        return 0
    fi
    local out="" rc=0
    out=$(bash "$_GOV_TOOL" governing "$PROJECT_DIR" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        log_sync_error "F1: the governing-artifact query failed (workflow-manifest.sh governing '$PROJECT_DIR' exited $rc), so the doc-only fast path classifies exactly as it did before claude-workflow-plugin-s5qf"
        return 0
    fi
    _GOV_SET="$out"
    return 0
}

# governing_artifact_origin <path> — 0 when the path is a governing artifact,
# with $GOV_VETO_ORIGIN naming which surface said so (its manifest class, or
# `runtime-contract`). 1 otherwise. Mirrors DOC_VETO_REASON's contract above:
# the answer is a global rather than stdout precisely so no call site is
# tempted into a subshell.
#
# Membership is EXACT STRING EQUALITY against the enumeration, never a pattern
# match — a declared path containing a glob metacharacter must not widen the
# veto.
#
# REDUCING AN ABSOLUTE PATH, which is where this gets its sharp edges. Paths
# arrive in both spellings: post-edit.sh records `tool_input.file_path`
# verbatim (absolute) while `git status --porcelain` yields repo-relative ones.
# A relative path is already in the enumeration's spelling; an absolute one has
# to be reduced, and getting that wrong fails OPEN and SILENTLY — the veto
# simply never fires. The four spellings were probed against this function
# rather than reasoned about, because two of them were wrong the first time:
#
#   PROJECT_DIR       incoming path      before   now
#   /var/x            /var/x/f.md        HIT      HIT   literal prefix
#   /var/x            /private/var/x/f.md MISS->  HIT   resolved-root prefix
#   /var/x/           /var/x/f.md        MISS     HIT   trailing slash stripped
#   /private/var/x    /var/x/f.md        MISS     HIT   resolve the PATH too
#
# The last row is why the third attempt exists: when PROJECT_DIR is already
# physical there is no second root spelling left to try, so the only way to
# meet a symlinked incoming path is to resolve that path's own directory. It
# costs one subshell, and ONLY on paths the two string attempts missed — the
# common case stays fork-free. A path whose directory cannot be resolved (a
# deletion) yields no reduction, which is the deletion residual the region
# header already states rather than a new one.
#
# An absolute path under none of these belongs to ANOTHER tree, and another
# tree's layout is not something this project declared anything about.
governing_artifact_origin() {
    local p="$1"
    local rel="" pdir pbase gpath gorigin
    GOV_VETO_ORIGIN=""
    [ -n "$p" ] || return 1
    load_governing_set
    [ -n "$_GOV_SET" ] || return 1
    case "$p" in
        /*)
            if [ -n "$_GOV_ROOT" ] && [ "${p#"$_GOV_ROOT"/}" != "$p" ]; then
                rel=${p:$(( ${#_GOV_ROOT} + 1 ))}
            elif [ -n "$_GOV_ROOT_PHYS" ] && [ "${p#"$_GOV_ROOT_PHYS"/}" != "$p" ]; then
                rel=${p:$(( ${#_GOV_ROOT_PHYS} + 1 ))}
            elif [ -n "$_GOV_ROOT_PHYS" ]; then
                pbase="${p##*/}"
                pdir="${p%/*}"
                [ -n "$pdir" ] || pdir="/"
                pdir=$(cd "$pdir" 2>/dev/null && pwd -P) || pdir=""
                if [ -z "$pdir" ] || [ -z "$pbase" ]; then
                    return 1
                elif [ "$pdir" = "$_GOV_ROOT_PHYS" ]; then
                    rel="$pbase"
                elif [ "${pdir#"$_GOV_ROOT_PHYS"/}" != "$pdir" ]; then
                    rel="${pdir:$(( ${#_GOV_ROOT_PHYS} + 1 ))}/$pbase"
                else
                    return 1
                fi
            else
                return 1
            fi
            ;;
        *) rel="$p" ;;
    esac
    [ -n "$rel" ] || return 1
    while IFS=$'\t' read -r gpath gorigin; do
        if [ "$gpath" = "$rel" ]; then
            GOV_VETO_ORIGIN="$gorigin"
            break
        fi
    done <<< "$_GOV_SET"
    [ -n "$GOV_VETO_ORIGIN" ] || return 1
    return 0
}
# GOVERNING-ARTIFACT-VETO END (claude-workflow-plugin-s5qf)

is_doc_only_path() {
    local p="$1"
    [ -z "$p" ] && return 1
    case "$p" in
        *.md|*.markdown|*.mdx|*.rst|*.txt) ;;
        # Extension-LESS documentation filenames only. `LICENSE.<ext>` is
        # deliberately absent: `LICENSE.md` / `LICENSE.txt` / `LICENSE.rst`
        # already match the extension arm above, so the glob's only reach was
        # over extensions nobody enumerated.
        */LICENSE|LICENSE) ;;
        */CHANGELOG|CHANGELOG) ;;
        */NOTICE|NOTICE|*/AUTHORS|AUTHORS) ;;
        *) return 1 ;;
    esac
    # DOC-CONTENT-VETO BEGIN (claude-workflow-plugin-bbh)
    # A documentation NAME is necessary and no longer sufficient. See
    # doc_path_is_executable_content above for what counts as evidence and why
    # an unresolvable path is not evidence of anything.
    #
    # The sentinel comments are load-bearing: a META strips this region and
    # asserts an executable `docs/install.txt` classifies doc-only again. The
    # arms above end in `;;` with no `return 0`, so the stripped copy falls
    # through to the `return 0` below — the pre-veto, name-only classifier —
    # rather than to a syntax error. Do not rename them.
    if doc_path_is_executable_content "$p"; then
        log_sync_error "F1: $p carries a documentation name but is executable content ($DOC_VETO_REASON), so it is classified REVIEWABLE and the doc-only fast path does not apply to this change set (claude-workflow-plugin-bbh)"
        return 1
    fi
    # DOC-CONTENT-VETO END (claude-workflow-plugin-bbh)
    # GOVERNING-ARTIFACT-VETO BEGIN (claude-workflow-plugin-s5qf)
    # A documentation name is necessary, and neither the name nor the file's
    # first two bytes can tell you that a document IS the system rather than
    # documentation about it. See governing_artifact_origin above.
    #
    # Same strippability contract as the region above, for the same META: the
    # arms end in `;;` with no `return 0`, so a copy with both regions excised
    # falls through to the `return 0` below — the pre-veto, name-only
    # classifier — rather than to a syntax error. Do not rename the sentinels.
    if governing_artifact_origin "$p"; then
        log_sync_error "F1: $p carries a documentation name but is a GOVERNING ARTIFACT — the project declares it as part of its own surface ($GOV_VETO_ORIGIN), so it is classified REVIEWABLE and the doc-only fast path does not apply to this change set (claude-workflow-plugin-s5qf)"
        return 1
    fi
    # GOVERNING-ARTIFACT-VETO END (claude-workflow-plugin-s5qf)
    return 0
}

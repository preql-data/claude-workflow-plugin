#!/bin/bash
# doc-only-classifier.test.sh — L1 unit fixture for verify-before-stop.sh's
# `is_doc_only_path` and its DOC-CONTENT-VETO (claude-workflow-plugin-bbh).
#
# WHY THIS TIER. `is_doc_only_path` is the predicate the F1 fast path's entire
# licence rests on: DOC_ONLY stays true only if EVERY changed path matches it,
# and a change set that is DOC_ONLY is auto-approved with `reviewed_by=none`. It
# is a pure function of a path plus (now) two facts about the file on disk, so
# it can be driven exhaustively offline. The hook-level consequences — a Stop
# that releases, a record that gets written — belong to the component tier and
# live in specs/verify-before-stop.sh; this file answers "what does the
# classifier say", deterministically and by the thousand.
#
# THE FUNCTIONS UNDER TEST ARE EXTRACTED FROM THE SHIPPED SCRIPT by awk, never
# re-typed here. A copy of the classifier in this file would be a second
# definition free to drift from the one that gates releases, which is the exact
# failure class bbh is about.
#
# Sections:
#   1  extraction + self-check (the extraction is the test's own dependency)
#   2  the bbh probe table — position and name-glob no longer confer doc status
#   3  the REMOVAL proves itself: re-insert the two deleted arms and the
#      measured defect returns, over a 1120-path cross product
#   4  the DOC-CONTENT-VETO: executable content is never doc-only
#   5  VETO META: strip the region and the veto's own leg goes green-to-defect
#   6  the GOVERNING-ARTIFACT-VETO (s5qf): a document the project declares as
#      part of its own surface is not documentation about the system, it IS
#      the system — driven against the SHIPPED workflow-manifest.sh, running
#   7  an EMPTY or ABSENT declaration changes nothing, both arms, with a
#      discriminator so the absence cannot be satisfied by a broken query
#   8  GOVERNING-VETO META: strip the region and section 6 goes back to the
#      defect
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
VBS="$PROJECT_DIR/.claude/scripts/verify-before-stop.sh"

if [ ! -f "$VBS" ]; then
    printf 'doc-only-classifier.test: script under test missing: %s\n' "$VBS" >&2
    exit 2
fi

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

WORK=$(mktemp -d -t doc-only-classifier.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. EXTRACTION
# ---------------------------------------------------------------------------
# Three pieces, all text-anchored, never line-numbered:
#   - the DOC-CONTENT-VETO helper region. Its sentinels sit at COLUMN 0 while
#     the call-site region's are indented inside the function, so `^#` selects
#     the helper and only the helper. Pulling both would drop an orphaned `if`
#     at top level and the extraction would not parse.
#   - the GOVERNING-ARTIFACT-VETO helper region, on the same column-0 rule.
#   - is_doc_only_path itself, by its `name() {` .. `}` range.
extract_classifier() {
    local src="$1" out="$2"
    {
        awk '/^# DOC-CONTENT-VETO BEGIN/,/^# DOC-CONTENT-VETO END/' "$src"
        printf '\n'
        awk '/^# GOVERNING-ARTIFACT-VETO BEGIN/,/^# GOVERNING-ARTIFACT-VETO END/' "$src"
        printf '\n'
        awk '/^is_doc_only_path\(\) \{/,/^\}/' "$src"
    } > "$out"
}

SHIPPED_LIB="$WORK/shipped.sh"
extract_classifier "$VBS" "$SHIPPED_LIB"

assert_eq "1.1 the extraction defines is_doc_only_path" "1" \
    "$(grep -c '^is_doc_only_path() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"
assert_eq "1.2 the extraction defines the veto helper" "1" \
    "$(grep -c '^doc_path_is_executable_content() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"
assert_eq "1.3 the extraction parses" "0" \
    "$(bash -n "$SHIPPED_LIB" 2>/dev/null && echo 0 || echo 1)"
assert_eq "1.4 the extraction defines the governing-artifact helper" "1" \
    "$(grep -c '^governing_artifact_origin() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"

# classify_all <lib> <project-dir> <paths-file> -> "<verdict>\t<path>" per line.
#
# One bash per call, `log_sync_error` stubbed to stderr so the classifier's own
# diagnostic is capturable without pulling the rest of the hook in. Stdout
# carries only verdicts.
classify_all() {
    local lib="$1" pdir="$2" paths="$3"
    bash -c '
        set -u
        PROJECT_DIR="$1"
        log_sync_error() { printf "SYNCERR %s\n" "$1" >&2; }
        . "$2"
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            if is_doc_only_path "$p"; then printf "DOC-ONLY\t%s\n" "$p"
            else printf "reviewable\t%s\n" "$p"; fi
        done < "$3"
    ' _ "$pdir" "$lib" "$paths"
}

# verdict_of <classified-output> <path>
verdict_of() {
    printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$2 == p { print $1; found=1 } END { if (!found) print "MISSING" }'
}

# ---------------------------------------------------------------------------
# 2. THE bbh PROBE TABLE
# ---------------------------------------------------------------------------
# NO FILE EXISTS for any of these paths, deliberately: this section measures the
# NAME/POSITION half on its own, with the veto unable to contribute an opinion.
# Section 4 supplies the files.
cat > "$WORK/table.txt" <<'EOF'
docs/HOOKS.md
docs/guide.markdown
docs/api.mdx
docs/spec.rst
docs/notes.txt
docs/examples/setup.sh
docs/scripts/migrate.py
docs/fixtures/payload.json
docs/Dockerfile
docs/Makefile
docs/.github/workflows/ci.yml
docs/settings.json
docs/img/diagram.png
docs/deploy.sh
docs/README
src/docs/handler.ts
packages/web/docs/build.gradle
/abs/root/docs/deploy.sh
LICENSE
LICENSE.md
LICENSE.txt
LICENSE.sh
LICENSE.py
LICENSE.yml
src/LICENSE.sh
CHANGELOG
CHANGELOG.md
NOTICE
AUTHORS
README.md
README
tests/spec.txt
.claude/scripts/hook.txt
src/handler.rst
install.sh
.claude/scripts/qa-gate.sh
src/index.ts
package.json
Dockerfile
EOF
TABLE=$(classify_all "$SHIPPED_LIB" "$WORK/nonexistent-root" "$WORK/table.txt" 2>/dev/null)

# 2a. The bypass the task was filed for: POSITION no longer confers doc status.
for p in docs/examples/setup.sh docs/scripts/migrate.py docs/fixtures/payload.json \
         docs/Dockerfile docs/Makefile docs/.github/workflows/ci.yml docs/settings.json \
         docs/img/diagram.png docs/deploy.sh docs/README src/docs/handler.ts \
         packages/web/docs/build.gradle /abs/root/docs/deploy.sh; do
    assert_eq "2a position: $p is REVIEWABLE (was DOC-ONLY via */docs/*)" \
        "reviewable" "$(verdict_of "$TABLE" "$p")"
done

# 2b. A NAME GLOB no longer confers doc status on an arbitrary extension.
for p in LICENSE.sh LICENSE.py LICENSE.yml; do
    assert_eq "2b name glob: $p is REVIEWABLE (was DOC-ONLY via LICENSE.*)" \
        "reviewable" "$(verdict_of "$TABLE" "$p")"
done
# The asymmetry that made the old arm's reach non-obvious: it had no `*/`
# prefix, so this one was ALREADY reviewable. Pinned so the two are not
# conflated when reading the section above.
assert_eq "2b control: src/LICENSE.sh was reviewable before this change too" \
    "reviewable" "$(verdict_of "$TABLE" "src/LICENSE.sh")"

# 2c. ANTI-OVERREACH. Documentation must not lose the fast path — F1 exists for
# exactly these commits, and a fix that deadlocks them is the same error in the
# other direction.
for p in docs/HOOKS.md docs/guide.markdown docs/api.mdx docs/spec.rst docs/notes.txt \
         LICENSE LICENSE.md LICENSE.txt CHANGELOG CHANGELOG.md NOTICE AUTHORS \
         README.md tests/spec.txt .claude/scripts/hook.txt src/handler.rst; do
    assert_eq "2c anti-overreach: $p is still DOC-ONLY" \
        "DOC-ONLY" "$(verdict_of "$TABLE" "$p")"
done

# 2d. Unchanged in both directions — reviewable before, reviewable after.
for p in install.sh .claude/scripts/qa-gate.sh src/index.ts package.json Dockerfile README; do
    assert_eq "2d unchanged: $p is reviewable" "reviewable" "$(verdict_of "$TABLE" "$p")"
done

# ---------------------------------------------------------------------------
# 3. THE REMOVAL PROVES ITSELF
# ---------------------------------------------------------------------------
# A deletion cannot be measured by stripping a sentinel — there is nothing left
# to strip. The negative control is the inverse: RE-INSERT the two removed arms
# into a copy and assert the measured defect comes back. Anything this section
# asserts about the shipped classifier is then attributable to the removal and
# to nothing else in the function.
#
# The veto is stripped from the reconstruction as well, so the copy is the
# pre-bbh classifier in behaviour rather than a hybrid; section 4 measures the
# veto separately, on its own.
VETO_STRIPPED_SRC="$WORK/vbs-noveto.sh"
awk '/^ *# DOC-CONTENT-VETO BEGIN/ { skip = 1; next }
     /^ *# DOC-CONTENT-VETO END/   { skip = 0; next }
     !skip { print }' "$VBS" > "$VETO_STRIPPED_SRC"
PREFIX_LIB="$WORK/prefix.sh"
extract_classifier "$VETO_STRIPPED_SRC" "$PREFIX_LIB"
# Re-insert, text-anchored on the arms as they are written today.
sed -e 's#^        \*/LICENSE|LICENSE) ;;$#        */LICENSE|LICENSE|LICENSE.*) ;;#' \
    -e 's#^        \*) return 1 ;;$#        */docs/*|docs/*) ;;\
        *) return 1 ;;#' \
    "$PREFIX_LIB" > "$PREFIX_LIB.tmp" && mv "$PREFIX_LIB.tmp" "$PREFIX_LIB"

if cmp -s "$SHIPPED_LIB" "$PREFIX_LIB"; then
    assert_eq "3.0 GUARD: the re-insertion APPLIED (mutant differs from shipped)" \
        "differs" "identical"
else
    assert_eq "3.0 GUARD: the re-insertion APPLIED (mutant differs from shipped)" \
        "differs" "differs"
    assert_eq "3.1 the reconstruction parses" "0" \
        "$(bash -n "$PREFIX_LIB" 2>/dev/null && echo 0 || echo 1)"
    assert_eq "3.2 the */docs/* arm is back" "1" \
        "$(grep -c '^        \*/docs/\*|docs/\*) ;;$' "$PREFIX_LIB" | tr -d '[:space:]')"
    assert_eq "3.3 the LICENSE.* glob is back" "1" \
        "$(grep -c '^        \*/LICENSE|LICENSE|LICENSE\.\*) ;;$' "$PREFIX_LIB" | tr -d '[:space:]')"
    # CODE lines only. A bare name grep here counted PROSE: the s5qf region's
    # header explains why the content veto has no opinion about an agent
    # prompt, names the function to say so, and is extracted alongside the
    # classifier — so the mention survives a strip that removed every call and
    # the removal looked like it had failed. That is the exact failure
    # LESSONS.md records (2026-08-08: "grepping for the deleted pattern returns
    # the prose"). Dropping comment lines keeps the assertion spelling-agnostic
    # — any call form is still caught — while making it immune to being
    # described.
    assert_eq "3.4 ...and the veto call did NOT survive into the reconstruction" "0" \
        "$(grep -v '^[[:space:]]*#' "$PREFIX_LIB" | grep -c 'doc_path_is_executable_content' | tr -d '[:space:]')"

    PRE_TABLE=$(classify_all "$PREFIX_LIB" "$WORK/nonexistent-root" "$WORK/table.txt" 2>/dev/null)
    # THE DEFECT, reproduced. Each of these is one of the paths measured on the
    # task; with the arms back they are documentation again.
    for p in docs/examples/setup.sh docs/scripts/migrate.py docs/Dockerfile \
             docs/deploy.sh src/docs/handler.ts LICENSE.sh LICENSE.py; do
        assert_eq "3.5 DEFECT REPRODUCED: with the arms re-inserted, $p is DOC-ONLY again" \
            "DOC-ONLY" "$(verdict_of "$PRE_TABLE" "$p")"
    done
    # ...and the one the arms never reached, so the reconstruction is the
    # pre-fix classifier rather than something merely more permissive.
    assert_eq "3.6 DEFECT REPRODUCED: src/LICENSE.sh stays reviewable (the arm had no */ prefix)" \
        "reviewable" "$(verdict_of "$PRE_TABLE" "src/LICENSE.sh")"

    # ---- the cross product ------------------------------------------------
    # 8 directory shapes x 10 basenames x 14 extensions. The question is not
    # "does it classify these correctly" — it is what the REMOVAL did to the
    # function as a whole, in both directions.
    : > "$WORK/cross.txt"
    for d in "" "docs/" "docs/sub/" "src/" "src/docs/" "a/b/docs/c/" "/abs/docs/" "/abs/src/"; do
        for b in README LICENSE CHANGELOG NOTICE AUTHORS deploy handler golden Dockerfile Makefile; do
            for e in "" .md .markdown .mdx .rst .txt .sh .py .ts .json .yml .png .Md .MD; do
                printf '%s%s%s\n' "$d" "$b" "$e" >> "$WORK/cross.txt"
            done
        done
    done
    assert_eq "3.7 cross product is the expected size" "1120" \
        "$(grep -c . "$WORK/cross.txt" | tr -d '[:space:]')"
    classify_all "$SHIPPED_LIB" "$WORK/nonexistent-root" "$WORK/cross.txt" 2>/dev/null \
        | cut -f1 > "$WORK/cross.now"
    classify_all "$PREFIX_LIB" "$WORK/nonexistent-root" "$WORK/cross.txt" 2>/dev/null \
        | cut -f1 > "$WORK/cross.pre"
    paste -d' ' "$WORK/cross.pre" "$WORK/cross.now" "$WORK/cross.txt" > "$WORK/cross.joined"

    # (a) It can only NARROW. A single path gaining doc status would be a new
    #     bypass introduced by the fix, which is the one outcome that must be
    #     impossible.
    assert_eq "3.8 the change NEVER widens: 0 paths went reviewable -> DOC-ONLY" "0" \
        "$(awk '$1=="reviewable" && $2=="DOC-ONLY"' "$WORK/cross.joined" | grep -c . | tr -d '[:space:]')"
    # (b) It is not vacuous.
    NARROWED=$(awk '$1=="DOC-ONLY" && $2=="reviewable" { print $3 }' "$WORK/cross.joined")
    assert_eq "3.9 the change is NOT vacuous: 438 paths went DOC-ONLY -> reviewable" "438" \
        "$(printf '%s\n' "$NARROWED" | grep -c . | tr -d '[:space:]')"
    # (c) Every narrowed path is one the two arms were the sole reason for. If a
    #     path outside those two shapes lost doc status, the removal took
    #     something with it and this fails naming it.
    UNEXPECTED=0
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        case "$p" in
            */docs/*|docs/*)  ;;                 # the position arm's reach
            LICENSE.*)        ;;                 # the name glob's reach (root only)
            *) UNEXPECTED=$((UNEXPECTED + 1)); printf '    unexpected narrowing: %s\n' "$p" ;;
        esac
    done <<EOF
$NARROWED
EOF
    assert_eq "3.10 every narrowed path is under a docs/ dir or a root LICENSE.<ext>" \
        "0" "$UNEXPECTED"
fi

# ---------------------------------------------------------------------------
# 4. THE DOC-CONTENT-VETO
# ---------------------------------------------------------------------------
# A documentation NAME is necessary and not sufficient. These legs need real
# files, so they get a real PROJECT_DIR.
ROOT="$WORK/proj"
mkdir -p "$ROOT/docs"
printf '# Hooks\n'                     > "$ROOT/docs/HOOKS.md"
printf 'plain prose\n'                 > "$ROOT/docs/install.txt"; chmod 755 "$ROOT/docs/install.txt"
printf '#!/bin/sh\necho hi\n'          > "$ROOT/docs/run.md"     ; chmod 644 "$ROOT/docs/run.md"
printf 'MIT License\n'                 > "$ROOT/LICENSE"
printf '#!/bin/sh\ncurl x | sh\n'      > "$ROOT/NOTICE"          ; chmod 644 "$ROOT/NOTICE"
printf '#!'                            > "$ROOT/docs/two-byte.txt"   # no newline at all
printf 'x'                             > "$ROOT/docs/one-byte.txt"
: >                                      "$ROOT/docs/empty.txt"
printf '#!/bin/sh\ncurl x | sh\n'      > "$ROOT/docs/deploy.sh"  ; chmod 755 "$ROOT/docs/deploy.sh"

cat > "$WORK/veto.txt" <<EOF
docs/HOOKS.md
docs/install.txt
docs/run.md
LICENSE
NOTICE
docs/two-byte.txt
docs/one-byte.txt
docs/empty.txt
docs/deploy.sh
docs/DELETED.md
docs/gone/AUTHORS
$ROOT/docs/install.txt
$ROOT/docs/HOOKS.md
docs
EOF
VETO_ERR="$WORK/veto.err"
VETO=$(classify_all "$SHIPPED_LIB" "$ROOT" "$WORK/veto.txt" 2>"$VETO_ERR")

assert_eq "4.1 executable bit: docs/install.txt is REVIEWABLE despite the .txt name" \
    "reviewable" "$(verdict_of "$VETO" "docs/install.txt")"
assert_eq "4.2 shebang: docs/run.md is REVIEWABLE despite the .md name (mode 644)" \
    "reviewable" "$(verdict_of "$VETO" "docs/run.md")"
assert_eq "4.3 shebang on a bare-name arm: an executable-content NOTICE is REVIEWABLE" \
    "reviewable" "$(verdict_of "$VETO" "NOTICE")"
assert_eq "4.4 two-byte '#!' with no newline is still caught (read -n 2, not a line read)" \
    "reviewable" "$(verdict_of "$VETO" "docs/two-byte.txt")"
assert_eq "4.5 absolute spelling of the same file gets the same verdict" \
    "reviewable" "$(verdict_of "$VETO" "$ROOT/docs/install.txt")"

# CONTROLS — the veto must not eat ordinary documentation.
assert_eq "4.6 control: a plain docs/HOOKS.md is DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/HOOKS.md")"
assert_eq "4.7 control: absolute docs/HOOKS.md is DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "$ROOT/docs/HOOKS.md")"
assert_eq "4.8 control: a plain LICENSE is DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "LICENSE")"
assert_eq "4.9 control: a 1-byte file is DOC-ONLY (partial read is not a shebang)" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/one-byte.txt")"
assert_eq "4.10 control: an EMPTY file is DOC-ONLY (read returns EOF, no veto)" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/empty.txt")"

# THE DELETION CONTRACT. A path with no file behind it is not evidence of
# anything, so the name arms decide — which is what keeps a documentation
# DELETION on the fast path. This is the one asymmetry in the veto and it is the
# leg that pins it.
assert_eq "4.11 a DELETED doc (no file on disk) stays DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/DELETED.md")"
assert_eq "4.12 a DELETED extension-less doc stays DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/gone/AUTHORS")"

# Not a doc name at all -> the veto never runs; unchanged from section 2.
assert_eq "4.13 docs/deploy.sh is reviewable by NAME, before the veto is consulted" \
    "reviewable" "$(verdict_of "$VETO" "docs/deploy.sh")"
assert_eq "4.14 a directory named docs is reviewable" \
    "reviewable" "$(verdict_of "$VETO" "docs")"

# DIAGNOSABILITY. A block whose cause the operator cannot see is a dead end, so
# each veto writes a sync-error naming the path and the evidence.
# Anchored immediately after `F1: ` so the relative and absolute spellings of
# the SAME file are counted separately — an unanchored `docs/install.txt`
# matches both lines and the leg then asserts a number rather than a fact.
assert_eq "4.15 the veto logs the executable-bit case, naming the path" "1" \
    "$(grep -c 'SYNCERR F1: docs/install.txt carries .*executable bit is set' "$VETO_ERR" | tr -d '[:space:]')"
assert_eq "4.16 the veto logs the shebang case, naming the evidence" "1" \
    "$(grep -c 'SYNCERR F1: docs/run.md carries .*#! shebang' "$VETO_ERR" | tr -d '[:space:]')"
assert_eq "4.17 the absolute spelling logs its own line, under its own path" "1" \
    "$(grep -c "SYNCERR F1: $ROOT/docs/install.txt carries .*executable bit is set" "$VETO_ERR" | tr -d '[:space:]')"
assert_eq "4.18 ...and NOTHING is logged for the documentation controls" "0" \
    "$(grep -c 'SYNCERR.*HOOKS.md' "$VETO_ERR" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# 5. VETO META
# ---------------------------------------------------------------------------
# Strip the DOC-CONTENT-VETO regions and the section-4 legs must go back to the
# behaviour the veto exists to prevent. Without this the veto is a guard whose
# failure nobody has produced.
NOVETO_LIB="$WORK/noveto.sh"
extract_classifier "$VETO_STRIPPED_SRC" "$NOVETO_LIB"
if cmp -s "$SHIPPED_LIB" "$NOVETO_LIB"; then
    assert_eq "5.0 GUARD: the veto strip APPLIED (mutant differs from shipped)" \
        "differs" "identical"
else
    assert_eq "5.0 GUARD: the veto strip APPLIED (mutant differs from shipped)" \
        "differs" "differs"
    assert_eq "5.1 the stripped copy parses" "0" \
        "$(bash -n "$NOVETO_LIB" 2>/dev/null && echo 0 || echo 1)"
    # CODE lines only, for the reason spelled out at 3.4 above.
    assert_eq "5.2 no veto call survives the strip" "0" \
        "$(grep -v '^[[:space:]]*#' "$NOVETO_LIB" | grep -c 'doc_path_is_executable_content' | tr -d '[:space:]')"
    assert_eq "5.3 ...while the name arms survive outside the region" "1" \
        "$(grep -c '^        \*.md|\*.markdown|\*.mdx|\*.rst|\*.txt) ;;$' "$NOVETO_LIB" | tr -d '[:space:]')"

    NOVETO=$(classify_all "$NOVETO_LIB" "$ROOT" "$WORK/veto.txt" 2>/dev/null)
    assert_eq "5.4 META: without the veto, an EXECUTABLE docs/install.txt is DOC-ONLY (4.1 WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$NOVETO" "docs/install.txt")"
    assert_eq "5.5 META: ...and a shebang-carrying docs/run.md is DOC-ONLY (4.2 WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$NOVETO" "docs/run.md")"
    assert_eq "5.6 META: ...and an executable-content NOTICE is DOC-ONLY (4.3 WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$NOVETO" "NOTICE")"
    # Discriminator: the stripped copy still ran the real classifier, so the
    # difference above is the veto and nothing else about the extraction.
    assert_eq "5.7 META: the stripped copy still classifies docs/deploy.sh reviewable (it ran the real arms)" \
        "reviewable" "$(verdict_of "$NOVETO" "docs/deploy.sh")"
    assert_eq "5.8 META: ...and still classifies a plain docs/HOOKS.md DOC-ONLY" \
        "DOC-ONLY" "$(verdict_of "$NOVETO" "docs/HOOKS.md")"
    # RESTORE CONTROL: the shipped copy, same inputs, same call shape.
    RESTORE=$(classify_all "$SHIPPED_LIB" "$ROOT" "$WORK/veto.txt" 2>/dev/null)
    assert_eq "5.9 restore control: the SHIPPED copy vetoes the identical file" \
        "reviewable" "$(verdict_of "$RESTORE" "docs/install.txt")"
fi

# ---------------------------------------------------------------------------
# 6. THE GOVERNING-ARTIFACT VETO (claude-workflow-plugin-s5qf)
# ---------------------------------------------------------------------------
# A documentation NAME survives the content veto whenever the file carries
# neither an exec bit nor a `#!` — which is every agent prompt, every rubric,
# CLAUDE.md and the lessons ledger. Those are executable policy in prose, and
# this section is what pins that they stop being fast-pathable.
#
# THE QUERY IS THE SHIPPED workflow-manifest.sh, RUNNING. The classifier
# resolves it as its own SIBLING, so the extraction gets a real one placed next
# to it rather than a stub — a stub would let this whole section pass over a
# query that does not exist. The copy is byte-compared against $SHIPPED_LIB
# below so section 6 is provably driving the same classifier as sections 2-5,
# differing only in whether the tool is reachable.
GOVDIR="$WORK/gov-scripts"
mkdir -p "$GOVDIR"
GOV_LIB="$GOVDIR/shipped.sh"
extract_classifier "$VBS" "$GOV_LIB"
cp "$PROJECT_DIR/.claude/scripts/workflow-manifest.sh" "$GOVDIR/workflow-manifest.sh"
assert_eq "6.0 the section-6 extraction is byte-identical to the section-2 one" \
    "identical" "$(cmp -s "$SHIPPED_LIB" "$GOV_LIB" && echo identical || echo differs)"
assert_eq "6.0b the query tool really is beside it (not a stub, not absent)" "1" \
    "$(grep -c '^cmd_governing() {$' "$GOVDIR/workflow-manifest.sh" | tr -d '[:space:]')"

# A synthetic project declaring a plugin surface. Deliberately NOT this repo:
# the legs must measure the RULE, not this checkout's contents.
GROOT="$WORK/gov-project"
mkdir -p "$GROOT/.claude/agents" "$GROOT/.claude/rubrics" "$GROOT/.claude/commands" \
         "$GROOT/.claude/skills/workflow-engine" "$GROOT/.claude/scripts" \
         "$GROOT/docs/specs" "$GROOT/docs/design-notes"
printf '# project memory\n'   > "$GROOT/CLAUDE.md"
printf '# readme\n'           > "$GROOT/README.md"
printf '# changelog\n'        > "$GROOT/CHANGELOG.md"
printf '# lessons\n'          > "$GROOT/LESSONS.md"
printf 'qa agent\n'           > "$GROOT/.claude/agents/qa.md"
printf 'reviewer agent\n'     > "$GROOT/.claude/agents/design-reviewer.md"
printf 'scratch notes\n'      > "$GROOT/.claude/agents/notes.txt"
printf 'default rubric\n'     > "$GROOT/.claude/rubrics/default.md"
printf 'a command\n'          > "$GROOT/.claude/commands/workflow-model.md"
printf 'a skill\n'            > "$GROOT/.claude/skills/workflow-engine/SKILL.md"
printf '#!/bin/bash\n'        > "$GROOT/.claude/scripts/qa-gate.sh"
printf '# hooks reference\n'  > "$GROOT/docs/HOOKS.md"
printf '# architecture\n'     > "$GROOT/docs/ARCHITECTURE.md"
printf '# a design record\n'  > "$GROOT/docs/specs/claude-workflow-plugin-abc.md"
# The anti-overreach partner for the design-artifact declaration (fkm.3 / D1):
# a sibling directory under docs/ that the project declares NOTHING about. If
# this ever classified reviewable, the declaration would have become the
# path-shape inference bbh removed, wearing a different suffix.
printf '# an operator note\n' > "$GROOT/docs/design-notes/idea.md"
# A SYMLINKED design artifact (fkm.3 QA round 2, R2-F2). The declaration scanned
# `find -maxdepth 1 -type f`, which EXCLUDES symlinks, so this path produced no
# governing row at all and the F1 doc-only fast path reopened for the one
# document the design phase exists to review. Its anti-overreach partner is a
# symlink of the same shape in the undeclared sibling directory: the fix must be
# "the DECLARED directory is scanned for entries", never "symlinks are special".
mkdir -p "$GROOT/outside"
printf '# a design record reached through a link\n' > "$GROOT/outside/linked-design.md"
ln -sfn "../../outside/linked-design.md" "$GROOT/docs/specs/claude-workflow-plugin-lnk.md"
ln -sfn "../../outside/linked-design.md" "$GROOT/docs/design-notes/linked-idea.md"
# NOT created yet — 6f measures what happens when D0 adds it.
GOV_ABSENT_AGENT=".claude/agents/designer.md"

cat > "$WORK/gov.txt" <<EOF
CLAUDE.md
.claude/agents/qa.md
.claude/agents/design-reviewer.md
.claude/rubrics/default.md
.claude/commands/workflow-model.md
.claude/skills/workflow-engine/SKILL.md
LESSONS.md
docs/HOOKS.md
$GOV_ABSENT_AGENT
README.md
CHANGELOG.md
docs/ARCHITECTURE.md
.claude/agents/notes.txt
docs/specs/claude-workflow-plugin-abc.md
docs/specs/claude-workflow-plugin-lnk.md
docs/design-notes/idea.md
docs/design-notes/linked-idea.md
.claude/scripts/qa-gate.sh
$GROOT/.claude/agents/qa.md
$GROOT/README.md
/some/other/tree/.claude/agents/qa.md
EOF
GOV_ERR="$WORK/gov.err"
GOV=$(classify_all "$GOV_LIB" "$GROOT" "$WORK/gov.txt" 2>"$GOV_ERR")

# 6a. DECLARED GOVERNING ARTIFACTS ARE REVIEWABLE. Each is markdown with no
# exec bit and no shebang, so before s5qf every one of these was DOC-ONLY and
# a change set of exactly one of them auto-approved with reviewed_by=none.
for p in CLAUDE.md .claude/agents/qa.md .claude/agents/design-reviewer.md \
         .claude/rubrics/default.md .claude/commands/workflow-model.md \
         .claude/skills/workflow-engine/SKILL.md LESSONS.md docs/HOOKS.md; do
    assert_eq "6a governing: $p is REVIEWABLE (was DOC-ONLY on the .md name)" \
        "reviewable" "$(verdict_of "$GOV" "$p")"
done

# 6b. ANTI-OVERREACH. Ordinary documentation must keep the fast path — F1
# exists for exactly these commits. `.claude/agents/notes.txt` is the sharpest
# of them: it sits in the SAME directory as the agent prompts and is still
# DOC-ONLY, because the manifest scans that directory for `*.md` and does not
# declare it. That is the leg that distinguishes "reads the enumeration" from
# "reads the directory", which is the whole difference between this and the
# path-shape inference bbh removed.
for p in README.md CHANGELOG.md docs/ARCHITECTURE.md .claude/agents/notes.txt; do
    assert_eq "6b anti-overreach: $p is still DOC-ONLY" \
        "DOC-ONLY" "$(verdict_of "$GOV" "$p")"
done

# 6c. THE RESIDUAL THIS LEG USED TO PIN IS CLOSED (claude-workflow-plugin-fkm.3
# / v5 D1). It read: "docs/specs/<task-id>.md is still DOC-ONLY", and it was
# written so that D1 closing it would be a loud test change rather than a silent
# behaviour drift. This is that change.
#
# The design artifact is the one document the whole design phase exists to
# review, and while it was doc-only a change set consisting of exactly the design
# auto-approved with reviewed_by=none. D1 declares docs/specs/*.md in
# runtime_contract_rows beside CLAUDE.md, with its own origin token, so the
# governing query sees it. It is still a DECLARATION and not the path-shape
# inference bbh removed — the row exists because the workflow writes its design
# artifact there, which is a fact about the project's layout, not because the
# name ends in .md or sits under docs/.
#
# NOTE THIS LEG DEPENDS ON THE ARTIFACT EXISTING in the synthetic tree: the
# enumeration is built from files that exist (the same deletion asymmetry the
# region header states). classify_all's tree seeds it, so a leg that silently
# stopped seeding it would fail here rather than pass.
assert_eq "6c CLOSED: docs/specs/<task-id>.md is REVIEWABLE — the declared design artifact (fkm.3 / D1)" \
    "reviewable" "$(verdict_of "$GOV" "docs/specs/claude-workflow-plugin-abc.md")"
# ANTI-OVERREACH for the new declaration, and it is the leg that distinguishes
# "declared directory" from "anything under docs/": a sibling directory in docs/
# is the operator's and must keep the fast path.
assert_eq "6c anti-overreach: docs/design-notes/idea.md (NOT the declared dir) is still DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$GOV" "docs/design-notes/idea.md")"
# 6c2. THE SAME CLAIM FOR A SYMLINKED ARTIFACT (fkm.3 QA round 2, R2-F2). The
# declaration's scan excluded symlinks, so this exact path had NO governing row
# and auto-approved with reviewed_by=none — the F1 hole D1 exists to close,
# reopened for the design artifact itself by one `ln -s`. The partner leg is
# what keeps the fix a DECLARATION rather than a rule about link types.
assert_eq "6c2 CLOSED: a SYMLINKED artifact in the declared dir is REVIEWABLE too" \
    "reviewable" "$(verdict_of "$GOV" "docs/specs/claude-workflow-plugin-lnk.md")"
assert_eq "6c2 anti-overreach: an identical symlink in the UNDECLARED sibling dir is DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$GOV" "docs/design-notes/linked-idea.md")"

# 6d. Not a doc name at all -> unchanged; the veto is never consulted.
assert_eq "6d .claude/scripts/qa-gate.sh is reviewable by NAME, before any veto" \
    "reviewable" "$(verdict_of "$GOV" ".claude/scripts/qa-gate.sh")"

# 6e. SPELLING PARITY. post-edit.sh records absolute paths and `git status`
# yields repo-relative ones; both arrive here and must get the same verdict.
# The third leg is the containment half: an absolute path under a DIFFERENT
# root is another project's layout, about which this one has declared nothing.
assert_eq "6e absolute spelling of a governing artifact is REVIEWABLE too" \
    "reviewable" "$(verdict_of "$GOV" "$GROOT/.claude/agents/qa.md")"
assert_eq "6e absolute spelling of an ordinary doc is still DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$GOV" "$GROOT/README.md")"
assert_eq "6e an identically-shaped path in ANOTHER tree is DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$GOV" "/some/other/tree/.claude/agents/qa.md")"

# 6e2. THE SPELLINGS OF THE ROOT ITSELF. Reducing an absolute path is where this
# fails OPEN and SILENTLY when it fails at all — the veto just never fires — so
# the spellings are driven rather than reasoned about. Two of these four were
# wrong on the first implementation: a trailing slash on PROJECT_DIR made the
# literal prefix "/a/b//", which nothing matches, and a PROJECT_DIR already in
# its physical form left no second root spelling to try.
GROOT_PHYS=$(cd "$GROOT" && pwd -P)
printf '%s\n' "$GROOT/.claude/agents/qa.md" > "$WORK/gov-abs-logical.txt"
printf '%s\n' "$GROOT_PHYS/.claude/agents/qa.md" > "$WORK/gov-abs-physical.txt"
assert_eq "6e2 trailing slash on PROJECT_DIR still resolves" "reviewable" \
    "$(verdict_of "$(classify_all "$GOV_LIB" "$GROOT/" "$WORK/gov-abs-logical.txt" 2>/dev/null)" \
       "$GROOT/.claude/agents/qa.md")"
# The symlink pair only exists where the two spellings actually differ (macOS
# /var -> /private/var). Asserted rather than assumed: on a platform where they
# are equal these two legs would be re-runs of 6e above, and a leg that cannot
# fail is worse than an absent one.
if [ "$GROOT_PHYS" != "$GROOT" ]; then
    assert_eq "6e2 precondition: the root has two distinct spellings on this platform" \
        "differ" "$([ "$GROOT_PHYS" != "$GROOT" ] && echo differ || echo same)"
    assert_eq "6e2 PROJECT_DIR logical + path physical resolves" "reviewable" \
        "$(verdict_of "$(classify_all "$GOV_LIB" "$GROOT" "$WORK/gov-abs-physical.txt" 2>/dev/null)" \
           "$GROOT_PHYS/.claude/agents/qa.md")"
    assert_eq "6e2 PROJECT_DIR physical + path logical resolves" "reviewable" \
        "$(verdict_of "$(classify_all "$GOV_LIB" "$GROOT_PHYS" "$WORK/gov-abs-logical.txt" 2>/dev/null)" \
           "$GROOT/.claude/agents/qa.md")"
else
    printf '  note: 6e2 symlink-spelling legs SKIPPED - this platform spells the\n'
    printf '        temp root identically physically and logically. Moves neither counter.\n'
fi
# CONTAINMENT. The third reduction attempt resolves an ARBITRARY path's
# directory, so it is exactly where an out-of-tree path could leak in. A second
# project with the IDENTICAL layout, a real file on disk, must stay DOC-ONLY:
# `.claude/agents/qa.md` being declared over THERE says nothing about a change
# set being judged over HERE.
#
# THE SIBLING'S NAME IS THE SAME LENGTH AS $GROOT'S, and that is the whole leg
# rather than a detail. Reduction tests the prefix WITH its separator and then
# slices at a fixed `${#root} + 1`. Delete the containment test — the plausible
# bug, since the slice looks like it already did the work — and the two disagree
# by however many characters the sibling's name differs in, so the leak only
# materialises when they are EQUAL. Measured, three shapes, mutant = attempt 3's
# containment test replaced by `true`, PROJECT_DIR = <work>/gov-project:
#
#   <work>/oth-project    (11 = 11)  -> LEAKS: reduces to .claude/agents/qa.md
#   <work>/other-project  (13)       -> stays DOC-ONLY (slice yields garbage)
#   <work>/gov-project2   (12)       -> stays DOC-ONLY (slice keeps a leading /)
#
# So the two obvious fixtures — an unrelated name, and a strict string-prefix
# extension — BOTH pass under the broken build. Only the equal-length one is a
# control. Do not rename this directory without re-running that mutation.
OTHER_ROOT="$WORK/oth-project"
mkdir -p "$OTHER_ROOT/.claude/agents"
printf 'someone else s qa agent\n' > "$OTHER_ROOT/.claude/agents/qa.md"
printf '%s\n' "$OTHER_ROOT/.claude/agents/qa.md" > "$WORK/gov-other.txt"
assert_eq "6e2 containment precondition: the other tree's file really exists" "yes" \
    "$([ -f "$OTHER_ROOT/.claude/agents/qa.md" ] && echo yes || echo no)"
assert_eq "6e2 containment precondition: its root name is the SAME LENGTH as this one's" \
    "yes" "$([ "${#OTHER_ROOT}" = "${#GROOT}" ] && echo yes || echo no)"
assert_eq "6e2 containment: an EXISTING identical path in another tree is still DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$(classify_all "$GOV_LIB" "$GROOT" "$WORK/gov-other.txt" 2>/dev/null)" \
       "$OTHER_ROOT/.claude/agents/qa.md")"

# 6f. IT GENERALISES WITHOUT AN EDIT. The operator's requirement was that this
# cover "artifacts nobody has thought of yet". `.claude/agents/designer.md` is
# one: D0 has not created it, so it is absent above and correctly DOC-ONLY (an
# absent path is not evidence of anything — the same contract as 4.11). Create
# it and it is disqualified immediately, with no list touched anywhere.
assert_eq "6f before: an agent prompt that does not exist yet is DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$GOV" "$GOV_ABSENT_AGENT")"
printf 'designer agent\n' > "$GROOT/$GOV_ABSENT_AGENT"
GOV2=$(classify_all "$GOV_LIB" "$GROOT" "$WORK/gov.txt" 2>/dev/null)
assert_eq "6f after: creating it makes it REVIEWABLE with no list edited (D0's two prompts)" \
    "reviewable" "$(verdict_of "$GOV2" "$GOV_ABSENT_AGENT")"
assert_eq "6f discriminator: the controls did not move with it" \
    "DOC-ONLY" "$(verdict_of "$GOV2" ".claude/agents/notes.txt")"

# 6g. DIAGNOSABILITY. A block whose cause the operator cannot see is a dead
# end, so each veto logs the path AND which surface disqualified it.
assert_eq "6g the veto logs the workflow-class case, naming path and origin" "1" \
    "$(grep -c 'SYNCERR F1: \.claude/agents/qa\.md carries .*GOVERNING ARTIFACT.*(workflow)' "$GOV_ERR" | tr -d '[:space:]')"
assert_eq "6g ...the operator-class case" "1" \
    "$(grep -c 'SYNCERR F1: \.claude/rubrics/default\.md carries .*GOVERNING ARTIFACT.*(operator)' "$GOV_ERR" | tr -d '[:space:]')"
assert_eq "6g ...and the runtime-contract case" "1" \
    "$(grep -c 'SYNCERR F1: CLAUDE\.md carries .*GOVERNING ARTIFACT.*(runtime-contract)' "$GOV_ERR" | tr -d '[:space:]')"
assert_eq "6g ...and NOTHING is logged for the anti-overreach controls" "0" \
    "$(grep -c 'GOVERNING ARTIFACT.*\(ARCHITECTURE\.md\|notes\.txt\|CHANGELOG\.md\)' "$GOV_ERR" | tr -d '[:space:]')"
assert_eq "6g ...and the query did not report itself unavailable (it really ran)" "0" \
    "$(grep -c 'governing-artifact query is unavailable\|governing-artifact query failed' "$GOV_ERR" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# 7. AN EMPTY OR ABSENT DECLARATION CHANGES NOTHING
# ---------------------------------------------------------------------------
# This plugin installs into arbitrary projects. A project that declares no
# surface must classify exactly as it did before s5qf, and so must one where
# the query cannot run at all — otherwise the fix would deadlock documentation
# commits everywhere it is not needed, which is the same error as the release
# it prevents, pointed the other way.
#
# THE REFERENCE IS AN INDEPENDENT ORACLE, and that is the whole design of this
# section. The obvious reference — the SAME classifier run against a root that
# also declares nothing — is a mirror, not an oracle: a mutation that changes
# what an EMPTY set means moves both sides of the comparison together and the
# `cmp` still says "identical". That was measured, not reasoned about: a
# fail-CLOSED mutation (`[ -n "$_GOV_SET" ] || { GOV_VETO_ORIGIN=...; return 0; }`)
# reddened 37 assertions in this file and NEITHER 7a nor 7b, because the mirror
# reference had gone fail-closed too. So the reference is the PRE-s5qf function
# — the shipped source with the s5qf regions excised, which no mutation inside
# those regions can reach. This is LESSONS.md's rule for exactly this shape
# (2026-07-28: a validation built from the same operation as the mutation
# cannot see that operation's own distortion).
GOV_STRIPPED_SRC="$WORK/vbs-nogov.sh"
awk '/^ *# GOVERNING-ARTIFACT-VETO BEGIN/ { skip = 1; next }
     /^ *# GOVERNING-ARTIFACT-VETO END/   { skip = 0; next }
     !skip { print }' "$VBS" > "$GOV_STRIPPED_SRC"
NOGOV_LIB="$GOVDIR/nogov.sh"
extract_classifier "$GOV_STRIPPED_SRC" "$NOGOV_LIB"
assert_eq "7.0 the pre-s5qf oracle really is a different artifact (the strip landed)" \
    "differs" "$(cmp -s "$GOV_LIB" "$NOGOV_LIB" && echo identical || echo differs)"
assert_eq "7.0b the oracle parses and carries no query code" "0" \
    "$(bash -n "$NOGOV_LIB" 2>/dev/null && [ "$(grep -v '^[[:space:]]*#' "$NOGOV_LIB" | grep -c 'governing_artifact_origin')" = "0" ] && echo 0 || echo 1)"

# 7a. THE QUERY RUNS AND FINDS NOTHING. A real tree, the real tool, no declared
# surface: an empty set vetoes nothing, so the shipped classifier must agree
# with the pre-s5qf one PATH FOR PATH on that tree.
EMPTY_ROOT="$WORK/undeclared-project"
mkdir -p "$EMPTY_ROOT/docs"
printf '# readme\n' > "$EMPTY_ROOT/README.md"
printf '# guide\n'  > "$EMPTY_ROOT/docs/guide.md"
assert_eq "7a precondition: the query really returns an empty set for this tree" "0" \
    "$(bash "$GOVDIR/workflow-manifest.sh" governing "$EMPTY_ROOT" | grep -c . | tr -d '[:space:]')"
classify_all "$NOGOV_LIB" "$EMPTY_ROOT" "$WORK/table.txt" 2>/dev/null > "$WORK/verdicts-pre-empty.txt"
classify_all "$GOV_LIB"   "$EMPTY_ROOT" "$WORK/table.txt" 2>/dev/null > "$WORK/verdicts-empty.txt"
assert_eq "7.0c the reference table is non-empty (so 'identical' means something)" \
    "yes" "$([ -s "$WORK/verdicts-pre-empty.txt" ] && echo yes || echo no)"
assert_eq "7a an undeclared project classifies EXACTLY as the PRE-s5qf classifier" \
    "identical" "$(cmp -s "$WORK/verdicts-pre-empty.txt" "$WORK/verdicts-empty.txt" && echo identical || echo differs)"

# 7b. THE QUERY CANNOT RUN. $SHIPPED_LIB has no workflow-manifest.sh sibling,
# so the tool is absent — a partial install, or a tree carrying only the hook.
# Fail-OPEN, and say so once rather than silently. Measured against the same
# independent oracle, on the DECLARED root: if an unanswerable query vetoed
# anything, this is where it would show.
ABSENT_ERR="$WORK/absent-tool.err"
classify_all "$NOGOV_LIB"  "$GROOT" "$WORK/table.txt" 2>/dev/null      > "$WORK/verdicts-pre-declared.txt"
classify_all "$SHIPPED_LIB" "$GROOT" "$WORK/table.txt" 2>"$ABSENT_ERR" > "$WORK/verdicts-absent.txt"
assert_eq "7b with the query tool ABSENT, classification EXACTLY matches the PRE-s5qf classifier" \
    "identical" "$(cmp -s "$WORK/verdicts-pre-declared.txt" "$WORK/verdicts-absent.txt" && echo identical || echo differs)"
assert_eq "7b ...and the unavailability is logged, exactly once per run" "1" \
    "$(grep -c 'governing-artifact query is unavailable' "$ABSENT_ERR" | tr -d '[:space:]')"

# 7c. DISCRIMINATOR. Section 7 asserts an ABSENCE of change, and a query that
# simply never fired would satisfy both arms above. The same classifier, the
# same table and the same oracle, against the DECLARED root WITH the tool
# reachable, must DIFFER — and must differ on a path the declaration names.
mkdir -p "$GROOT/docs"
printf '# hooks reference\n' > "$GROOT/docs/HOOKS.md"
classify_all "$GOV_LIB" "$GROOT" "$WORK/table.txt" 2>/dev/null > "$WORK/verdicts-declared.txt"
assert_eq "7c discriminator: the DECLARED root does NOT match the pre-s5qf classifier" \
    "differs" "$(cmp -s "$WORK/verdicts-pre-declared.txt" "$WORK/verdicts-declared.txt" && echo identical || echo differs)"
assert_eq "7c ...and docs/HOOKS.md is the path that moved" "reviewable" \
    "$(verdict_of "$(cat "$WORK/verdicts-declared.txt")" "docs/HOOKS.md")"
assert_eq "7c ...while it is DOC-ONLY under the pre-s5qf classifier" "DOC-ONLY" \
    "$(verdict_of "$(cat "$WORK/verdicts-pre-declared.txt")" "docs/HOOKS.md")"

# ---------------------------------------------------------------------------
# 8. GOVERNING-ARTIFACT-VETO META
# ---------------------------------------------------------------------------
# Strip the s5qf regions and section 6 must go back to the behaviour the veto
# exists to prevent. Without this the veto is a guard whose failure nobody has
# produced. `^ *#` matches BOTH the column-0 helper region and the indented
# call site inside is_doc_only_path, which is what leaves a copy that parses:
# the name arms end in `;;` and fall through to `return 0`.
#
# $NOGOV_LIB is built in section 7, where it serves as the independent
# pre-s5qf oracle. It is the same artifact and the same claim — "this is what
# the classifier did before the region existed" — so building a second copy
# here would be a second definition free to drift from the one section 7's
# identity legs rest on.
if cmp -s "$GOV_LIB" "$NOGOV_LIB"; then
    assert_eq "8.0 GUARD: the governing-veto strip APPLIED (mutant differs from shipped)" \
        "differs" "identical"
else
    assert_eq "8.0 GUARD: the governing-veto strip APPLIED (mutant differs from shipped)" \
        "differs" "differs"
    assert_eq "8.1 the stripped copy parses" "0" \
        "$(bash -n "$NOGOV_LIB" 2>/dev/null && echo 0 || echo 1)"
    assert_eq "8.2 no governing-veto call survives the strip" "0" \
        "$(grep -c 'governing_artifact_origin' "$NOGOV_LIB" | tr -d '[:space:]')"
    assert_eq "8.3 ...while the name arms survive outside the region" "1" \
        "$(grep -c '^        \*.md|\*.markdown|\*.mdx|\*.rst|\*.txt) ;;$' "$NOGOV_LIB" | tr -d '[:space:]')"
    # shellcheck disable=SC2016  # matching the LITERAL call `doc_path_is_executable_content "$p"`
    # in the extracted classifier, not expanding $p.
    assert_eq "8.4 ...and so does the bbh content veto (this strip took ONE thing)" "1" \
        "$(grep -c 'doc_path_is_executable_content "\$p"' "$NOGOV_LIB" | tr -d '[:space:]')"

    NOGOV=$(classify_all "$NOGOV_LIB" "$GROOT" "$WORK/gov.txt" 2>/dev/null)
    assert_eq "8.5 META: without the veto, .claude/agents/qa.md is DOC-ONLY (6a WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$NOGOV" ".claude/agents/qa.md")"
    assert_eq "8.6 META: ...and CLAUDE.md is DOC-ONLY (6a WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$NOGOV" "CLAUDE.md")"
    assert_eq "8.7 META: ...and .claude/rubrics/default.md is DOC-ONLY (6a WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$NOGOV" ".claude/rubrics/default.md")"
    # Discriminators: the stripped copy still ran the real classifier and the
    # OTHER veto, so 8.5-8.7 are attributable to this region and nothing else.
    assert_eq "8.8 META: the stripped copy still classifies qa-gate.sh reviewable (real arms ran)" \
        "reviewable" "$(verdict_of "$NOGOV" ".claude/scripts/qa-gate.sh")"
    NOGOV_VETO=$(classify_all "$NOGOV_LIB" "$ROOT" "$WORK/veto.txt" 2>/dev/null)
    assert_eq "8.9 META: ...and the bbh content veto still fires on an executable docs/install.txt" \
        "reviewable" "$(verdict_of "$NOGOV_VETO" "docs/install.txt")"
    # RESTORE CONTROL: the shipped copy, same inputs, same call shape.
    GOV_RESTORE=$(classify_all "$GOV_LIB" "$GROOT" "$WORK/gov.txt" 2>/dev/null)
    assert_eq "8.10 restore control: the SHIPPED copy disqualifies the identical prompt" \
        "reviewable" "$(verdict_of "$GOV_RESTORE" ".claude/agents/qa.md")"
fi

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

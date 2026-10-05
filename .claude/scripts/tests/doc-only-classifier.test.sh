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
#   9  PATH-REDUCTION META: which sentinel region carries the mdnc fix, by
#      stripping one at a time and re-driving section 6h's exact inputs
#  10  MONOTONICITY: the differential against what shipped BEFORE — a frozen,
#      sha256-pinned copy of the 0de5ceb classifier plus (when the tree is
#      dirty) HEAD's. Sections 1-9 all drive ONE artifact, and a monotonicity
#      claim is a claim about the DIFFERENCE between two, which is why 109
#      green assertions could not see mdnc's R1-F1 fail-open.
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
# claude-workflow-plugin-h2zz (= claude-workflow-plugin-hzv8): the second
# spelling used to be BORROWED from the host's own incidental layout (macOS's
# /var -> /private/var puts $WORK itself behind a symlink, so $GROOT_PHYS came
# out different from $GROOT for free; Linux's `mktemp -d` returns an
# already-physical /tmp path, so they coincided and the two legs below were
# honestly SKIPPED, printing a note explaining why). That made the leg absent
# on exactly the platform CI runs — under STRICT_SECTIONS=1 an honest skip is
# still red, so this was never actually a "does not apply here" case, it was a
# missing leg wearing a skip marker. Per the principle two paragraphs up ("a
# leg that cannot fail is worse than an absent one"), the fix is not to weaken
# or route around the assertions below — it is to make the second spelling
# exist BY CONSTRUCTION instead of by host accident: an explicit alias symlink
# placed beside $GROOT, pointing straight at it. $GROOT and $GROOT_ALIAS are
# two textually different strings on every platform (different literal
# basenames, chosen right here), and — because `pwd -P` fully resolves every
# symlink component in its path, including the alias hop AND whatever $WORK
# itself may or may not be sitting behind — both reduce to the SAME physical
# directory through `cd + pwd -P`. Proven below rather than assumed: the
# non-vacuity leg confirms the alias's physical resolution is byte-identical
# to $GROOT_PHYS before either is used to assert anything about the veto.
GROOT_ALIAS="$WORK/gov-project-alias"
ln -sfn "$GROOT" "$GROOT_ALIAS"
GROOT_ALIAS_PHYS=$(cd "$GROOT_ALIAS" 2>/dev/null && pwd -P)
assert_eq "6e2 non-vacuity: the constructed alias is a real symlink resolving to \$GROOT's own physical directory" \
    "$GROOT_PHYS" "$GROOT_ALIAS_PHYS"
assert_eq "6e2 precondition: the root has two distinct spellings BY CONSTRUCTION, on every platform" \
    "differ" "$([ "$GROOT_ALIAS" != "$GROOT" ] && echo differ || echo same)"
printf '%s\n' "$GROOT_ALIAS/.claude/agents/qa.md" > "$WORK/gov-abs-alias.txt"
assert_eq "6e2 PROJECT_DIR canonical + path via the ALIAS resolves" "reviewable" \
    "$(verdict_of "$(classify_all "$GOV_LIB" "$GROOT" "$WORK/gov-abs-alias.txt" 2>/dev/null)" \
       "$GROOT_ALIAS/.claude/agents/qa.md")"
assert_eq "6e2 PROJECT_DIR via the ALIAS + path canonical resolves" "reviewable" \
    "$(verdict_of "$(classify_all "$GOV_LIB" "$GROOT_ALIAS" "$WORK/gov-abs-logical.txt" 2>/dev/null)" \
       "$GROOT/.claude/agents/qa.md")"
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
# 6h. EVERY SPELLING OF A DECLARED PATH (claude-workflow-plugin-mdnc)
# ---------------------------------------------------------------------------
# THE MEASURED DEFECT THIS SECTION EXISTS FOR. The veto's membership test is an
# EXACT STRING MATCH against the enumeration, which is right — but until mdnc
# the REDUCTION that produced the string chained its attempts with `elif`, so
# the first attempt that produced ANY string won and the rest were never tried.
# A bare dot was enough to defeat it. Measured against the shipped classifier,
# with the canonical spellings measuring `reviewable` beside them:
#
#   $ROOT/./docs/specs/T-1.md        -> DOC-ONLY
#   docs/./specs/T-1.md              -> DOC-ONLY
#   docs/specs/../specs/T-1.md       -> DOC-ONLY
#   .claude/agents/../agents/qa.md   -> DOC-ONLY
#
# uniformly across EVERY declared path — agent prompts, rubrics, CLAUDE.md and
# the design artifact. That is a release-authorising bypass reachable by any
# tool that records a path with a dot in it, and it made two ANNOUNCED claims
# false at once: bbh announced that path-shape inference was gone, and s5qf
# announced that governing artifacts are disqualified from the fast path.
#
# EVERY ROW IS A PAIR. A spelling leg alone would pass just as well under a
# classifier that had given up and called everything reviewable, so each
# spelling is driven TWICE — once against a declared artifact (expect
# `reviewable`) and once against an ordinary document reached by the identical
# spelling machinery (expect `DOC-ONLY`). The controls are what make the legs
# above mean "the reduction is correct" rather than "the veto got greedy".
#
# THE FIXTURE'S SHAPE IS ITSELF EVIDENCE, and two parts of it are here because
# reasoning got them wrong first:
#   * THE ROOT NAME CARRIES A SPACE AND A NON-ASCII CHARACTER. A character-class
#     filter over paths was proposed during this arc, read correct, and would
#     have refused every project living under `/My Drive`. Only measurement
#     caught it, so the root is named to make that class of mistake fail here.
#   * A HARDLINK to a declared artifact, under an UNDECLARED name, must stay
#     DOC-ONLY. D1 measured that a hardlink defeats `-ef` — same inode, wrong
#     name — so this leg is the control that keeps the reduction PATH-based. It
#     is the leg that goes red the day someone "simplifies" this into an inode
#     comparison.
# ---------------------------------------------------------------------------

# The root: a space AND a non-ASCII character, deliberately.
SPELL_ROOT="$WORK/gov spéc project"
mkdir -p "$SPELL_ROOT/.claude/agents" "$SPELL_ROOT/.claude/rubrics" \
         "$SPELL_ROOT/.claude/scripts" "$SPELL_ROOT/docs/specs" \
         "$SPELL_ROOT/docs/design-notes" "$SPELL_ROOT/outside"
printf '# project memory\n'   > "$SPELL_ROOT/CLAUDE.md"
printf '# readme\n'           > "$SPELL_ROOT/README.md"
printf 'qa agent\n'           > "$SPELL_ROOT/.claude/agents/qa.md"
printf 'scratch notes\n'      > "$SPELL_ROOT/.claude/agents/notes.txt"
printf 'default rubric\n'     > "$SPELL_ROOT/.claude/rubrics/default.md"
printf '#!/bin/bash\n'        > "$SPELL_ROOT/.claude/scripts/qa-gate.sh"
printf '# a design record\n'  > "$SPELL_ROOT/docs/specs/T-1.md"
printf '# spaced design\n'    > "$SPELL_ROOT/docs/specs/T 2 spaced.md"
printf '# unicode design\n'   > "$SPELL_ROOT/docs/specs/T-3-café.md"
printf 'not markdown\n'       > "$SPELL_ROOT/docs/specs/sidecar.txt"
printf '# an operator note\n' > "$SPELL_ROOT/docs/design-notes/idea.md"
printf '# spaced note\n'      > "$SPELL_ROOT/docs/design-notes/n 2 spaced.md"
printf '# unicode note\n'     > "$SPELL_ROOT/docs/design-notes/n-3-café.md"
printf '# linked design\n'    > "$SPELL_ROOT/outside/linked-design.md"
printf '# linked note\n'      > "$SPELL_ROOT/outside/linked-note.md"
# a declared artifact that IS a symlink, and its undeclared twin
ln -sfn "../../outside/linked-design.md" "$SPELL_ROOT/docs/specs/T-4-link.md"
ln -sfn "../../outside/linked-note.md"   "$SPELL_ROOT/docs/design-notes/linked-idea.md"
# a DIRECTORY symlink mid-path, one into the declared dir and one into the
# undeclared sibling, so the control travels the same machinery
ln -sfn "specs"        "$SPELL_ROOT/docs/speclink"
ln -sfn "design-notes" "$SPELL_ROOT/docs/notelink"
# a HARDLINK to a declared artifact under an undeclared name
ln "$SPELL_ROOT/.claude/agents/qa.md" "$SPELL_ROOT/docs/design-notes/hardlink-to-qa.md"

# Preconditions. Each one is a fact a later leg's meaning depends on; without
# them a leg could pass because the fixture never got built.
assert_eq "6h.0 precondition: the project root name contains a SPACE" "yes" \
    "$([ "${SPELL_ROOT#* }" != "$SPELL_ROOT" ] && echo yes || echo no)"
assert_eq "6h.0b precondition: ...and a non-ASCII character" "yes" \
    "$(printf '%s' "$SPELL_ROOT" | LC_ALL=C grep -q '[^ -~]' && echo yes || echo no)"
assert_eq "6h.0c precondition: the declared leaf T-4-link.md really is a symlink" "yes" \
    "$([ -L "$SPELL_ROOT/docs/specs/T-4-link.md" ] && echo yes || echo no)"
assert_eq "6h.0d precondition: docs/speclink really is a directory symlink" "yes" \
    "$([ -L "$SPELL_ROOT/docs/speclink" ] && [ -d "$SPELL_ROOT/docs/speclink" ] && echo yes || echo no)"
assert_eq "6h.0e precondition: the hardlink really shares qa.md's inode" "same" \
    "$([ "$SPELL_ROOT/.claude/agents/qa.md" -ef "$SPELL_ROOT/docs/design-notes/hardlink-to-qa.md" ] && echo same || echo different)"
assert_eq "6h.0f precondition: ...under a DIFFERENT name (that is the whole leg)" "differ" \
    "$([ "$(basename "$SPELL_ROOT/.claude/agents/qa.md")" != "hardlink-to-qa.md" ] && echo differ || echo same)"

# THE DECLARED half of every pair.
cat > "$WORK/spell-gov.txt" <<EOF
docs/specs/T-1.md
$SPELL_ROOT/docs/specs/T-1.md
$SPELL_ROOT/./docs/specs/T-1.md
./docs/specs/T-1.md
docs/./specs/T-1.md
docs/specs/../specs/T-1.md
$SPELL_ROOT/docs/specs/../specs/T-1.md
.claude/agents/qa.md
./.claude/agents/qa.md
.claude/agents/../agents/qa.md
$SPELL_ROOT/./.claude/agents/qa.md
$SPELL_ROOT/.claude/agents/../agents/qa.md
CLAUDE.md
./CLAUDE.md
$SPELL_ROOT/./CLAUDE.md
.claude/rubrics/../rubrics/default.md
docs/speclink/T-1.md
$SPELL_ROOT/docs/speclink/T-1.md
$SPELL_ROOT/./docs/speclink/T-1.md
docs/specs/T-4-link.md
$SPELL_ROOT/./docs/specs/T-4-link.md
docs/speclink/T-4-link.md
docs/specs/T 2 spaced.md
$SPELL_ROOT/./docs/specs/T 2 spaced.md
docs/speclink/T 2 spaced.md
docs/specs/T-3-café.md
$SPELL_ROOT/./docs/specs/T-3-café.md
docs/speclink/T-3-café.md
EOF
# THE ORDINARY-DOCUMENT half: the same spellings, aimed at documents the
# project declares nothing about. Every one of these must keep the fast path.
cat > "$WORK/spell-doc.txt" <<EOF
docs/design-notes/idea.md
$SPELL_ROOT/docs/design-notes/idea.md
$SPELL_ROOT/./docs/design-notes/idea.md
./docs/design-notes/idea.md
docs/./design-notes/idea.md
docs/design-notes/../design-notes/idea.md
$SPELL_ROOT/docs/design-notes/../design-notes/idea.md
.claude/agents/notes.txt
./.claude/agents/notes.txt
.claude/agents/../agents/notes.txt
$SPELL_ROOT/./.claude/agents/notes.txt
README.md
./README.md
$SPELL_ROOT/./README.md
docs/notelink/idea.md
$SPELL_ROOT/./docs/notelink/idea.md
docs/design-notes/linked-idea.md
$SPELL_ROOT/./docs/design-notes/linked-idea.md
docs/notelink/linked-idea.md
docs/design-notes/n 2 spaced.md
$SPELL_ROOT/./docs/design-notes/n 2 spaced.md
docs/design-notes/n-3-café.md
$SPELL_ROOT/./docs/design-notes/n-3-café.md
docs/specs/sidecar.txt
$SPELL_ROOT/./docs/specs/sidecar.txt
docs/design-notes/hardlink-to-qa.md
$SPELL_ROOT/./docs/design-notes/hardlink-to-qa.md
$SPELL_ROOT/docs/design-notes/../design-notes/hardlink-to-qa.md
EOF

SPELL_GOV=$(classify_all "$GOV_LIB" "$SPELL_ROOT" "$WORK/spell-gov.txt" 2>/dev/null)
SPELL_DOC=$(classify_all "$GOV_LIB" "$SPELL_ROOT" "$WORK/spell-doc.txt" 2>/dev/null)

while IFS= read -r sp; do
    [ -z "$sp" ] && continue
    assert_eq "6h declared, every spelling: $sp is REVIEWABLE" \
        "reviewable" "$(verdict_of "$SPELL_GOV" "$sp")"
done < "$WORK/spell-gov.txt"
while IFS= read -r sp; do
    [ -z "$sp" ] && continue
    assert_eq "6h control, same spelling machinery: $sp still fast-paths" \
        "DOC-ONLY" "$(verdict_of "$SPELL_DOC" "$sp")"
done < "$WORK/spell-doc.txt"

# 6h.1 THE DECLARED DIRECTORY IS ITSELF A SYMLINK OUT OF THE TREE. fkm.3's
# R4-F3 already had to teach the SCAN about this shape (`find -H`), and the
# artifact is declared under its `docs/specs/...` spelling. Resolve that path's
# parent PHYSICALLY and the answer leaves the root entirely — so a
# resolution-only reduction stops vetoing the one document the design phase
# exists to review. Measured: with only the physical candidate,
# `$ROOT/./docs/specs/T-9.md` here read DOC-ONLY. This is the leg the LOGICAL
# candidate exists for.
OUTDIR_ROOT="$WORK/gov-outdir-project"
mkdir -p "$OUTDIR_ROOT/docs" "$OUTDIR_ROOT/.claude/agents" "$WORK/outdir-specs"
printf '# project memory\n' > "$OUTDIR_ROOT/CLAUDE.md"
printf '# readme\n'         > "$OUTDIR_ROOT/README.md"
printf 'qa agent\n'         > "$OUTDIR_ROOT/.claude/agents/qa.md"
printf '# design\n'         > "$WORK/outdir-specs/T-9.md"
printf '# a note\n'         > "$WORK/outdir-specs/note.txt"
# The link sits AT $OUTDIR_ROOT/docs/specs, so a relative target resolves from
# $OUTDIR_ROOT/docs — two levels up is $WORK. Written out because getting it
# wrong produced a DANGLING link the first time, which fails as a missing
# governing row two legs later rather than as a broken fixture.
ln -sfn "../../outdir-specs" "$OUTDIR_ROOT/docs/specs"
OUTDIR_ROOT_PHYS=$(cd -P "$OUTDIR_ROOT" && pwd)
OUTDIR_SPECS_PHYS=$(cd -P "$OUTDIR_ROOT/docs/specs" 2>/dev/null && pwd)
assert_eq "6h.1 precondition: docs/specs is a symlink whose target is OUTSIDE the root" "outside" \
    "$([ -L "$OUTDIR_ROOT/docs/specs" ] && [ -n "$OUTDIR_SPECS_PHYS" ] && \
       { [ "${OUTDIR_SPECS_PHYS#"$OUTDIR_ROOT_PHYS"/}" = "$OUTDIR_SPECS_PHYS" ] && echo outside || echo inside; })"
assert_eq "6h.1b precondition: the declaration still emits a row for it (find -H, fkm.3 R4-F3)" "1" \
    "$(bash "$GOVDIR/workflow-manifest.sh" governing "$OUTDIR_ROOT" | grep -c '^docs/specs/T-9\.md	' | tr -d '[:space:]')"
cat > "$WORK/outdir.txt" <<EOF
docs/specs/T-9.md
$OUTDIR_ROOT/docs/specs/T-9.md
$OUTDIR_ROOT/./docs/specs/T-9.md
./docs/specs/T-9.md
README.md
$OUTDIR_ROOT/./README.md
docs/specs/note.txt
EOF
OUTDIR_OUT=$(classify_all "$GOV_LIB" "$OUTDIR_ROOT" "$WORK/outdir.txt" 2>/dev/null)
for sp in "docs/specs/T-9.md" "$OUTDIR_ROOT/docs/specs/T-9.md" \
          "$OUTDIR_ROOT/./docs/specs/T-9.md" "./docs/specs/T-9.md"; do
    assert_eq "6h.1c out-of-tree declared dir: $sp is REVIEWABLE" \
        "reviewable" "$(verdict_of "$OUTDIR_OUT" "$sp")"
done
for sp in "README.md" "$OUTDIR_ROOT/./README.md" "docs/specs/note.txt"; do
    assert_eq "6h.1d control: $sp still fast-paths" \
        "DOC-ONLY" "$(verdict_of "$OUTDIR_OUT" "$sp")"
done

# 6h.2 CONTAINMENT SURVIVES THE NEW REDUCTION. The section-6e2 containment leg
# drives the string attempts; this drives the KERNEL one, which resolves an
# arbitrary directory and is therefore the new place an out-of-tree path could
# leak in. Same equal-length-sibling discipline as 6e2 — see that leg's note for
# why a differently-sized name is not a control.
SPELL_SIB="$WORK/gov spéc projeXX"
mkdir -p "$SPELL_SIB/.claude/agents"
printf 'someone else s qa agent\n' > "$SPELL_SIB/.claude/agents/qa.md"
assert_eq "6h.2 precondition: the sibling root is the SAME LENGTH as the declaring one" "yes" \
    "$([ "${#SPELL_SIB}" = "${#SPELL_ROOT}" ] && echo yes || echo no)"
cat > "$WORK/spell-other.txt" <<EOF
$SPELL_SIB/.claude/agents/qa.md
$SPELL_SIB/./.claude/agents/qa.md
$SPELL_SIB/.claude/agents/../agents/qa.md
EOF
SPELL_OTHER=$(classify_all "$GOV_LIB" "$SPELL_ROOT" "$WORK/spell-other.txt" 2>/dev/null)
while IFS= read -r sp; do
    [ -z "$sp" ] && continue
    assert_eq "6h.2b containment: another tree's identical path stays DOC-ONLY — $sp" \
        "DOC-ONLY" "$(verdict_of "$SPELL_OTHER" "$sp")"
done < "$WORK/spell-other.txt"

# 6h.3 THE DELETION RESIDUAL, PINNED RATHER THAN CLAIMED CLOSED. mdnc has two
# halves and this change fixes ONE of them. The enumeration is built from
# entries that EXIST, so after `rm .claude/agents/qa.md` there is no row to
# match and no reduction can invent one: the deletion of a governing artifact
# still takes the fast path with reviewed_by=none. These legs assert the
# CURRENT behaviour so that closing it later is a loud test change rather than
# a silent drift — the same convention 6c used for the design artifact before
# D1 closed it. Do not read them as endorsement; read them as the residual
# being measured instead of described.
DEL_ROOT="$WORK/gov-deletion-project"
mkdir -p "$DEL_ROOT/.claude/agents" "$DEL_ROOT/.claude/rubrics" "$DEL_ROOT/docs/specs"
printf '# project memory\n' > "$DEL_ROOT/CLAUDE.md"
printf '# readme\n'         > "$DEL_ROOT/README.md"
printf 'qa agent\n'         > "$DEL_ROOT/.claude/agents/qa.md"
printf 'keeper agent\n'     > "$DEL_ROOT/.claude/agents/keeper.md"
printf 'default rubric\n'   > "$DEL_ROOT/.claude/rubrics/default.md"
printf '# a design\n'       > "$DEL_ROOT/docs/specs/T-1.md"
cat > "$WORK/del.txt" <<'EOF'
.claude/agents/qa.md
.claude/rubrics/default.md
CLAUDE.md
docs/specs/T-1.md
.claude/agents/keeper.md
README.md
EOF
DEL_BEFORE=$(classify_all "$GOV_LIB" "$DEL_ROOT" "$WORK/del.txt" 2>/dev/null)
assert_eq "6h.3 precondition: BEFORE deletion the artifact is REVIEWABLE" "reviewable" \
    "$(verdict_of "$DEL_BEFORE" ".claude/agents/qa.md")"
rm -f "$DEL_ROOT/.claude/agents/qa.md" "$DEL_ROOT/.claude/rubrics/default.md" \
      "$DEL_ROOT/CLAUDE.md" "$DEL_ROOT/docs/specs/T-1.md"
DEL_AFTER=$(classify_all "$GOV_LIB" "$DEL_ROOT" "$WORK/del.txt" 2>/dev/null)
for sp in ".claude/agents/qa.md" ".claude/rubrics/default.md" "CLAUDE.md" "docs/specs/T-1.md"; do
    assert_eq "6h.3b OPEN RESIDUAL (mdnc, unfixed): DELETING $sp still fast-paths" \
        "DOC-ONLY" "$(verdict_of "$DEL_AFTER" "$sp")"
done
assert_eq "6h.3c discriminator: a surviving declared sibling is still REVIEWABLE" "reviewable" \
    "$(verdict_of "$DEL_AFTER" ".claude/agents/keeper.md")"
assert_eq "6h.3d discriminator: an ordinary doc is DOC-ONLY for its own reason" "DOC-ONLY" \
    "$(verdict_of "$DEL_AFTER" "README.md")"

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
# 9. PATH-REDUCTION META (claude-workflow-plugin-mdnc)
# ---------------------------------------------------------------------------
# Section 6h asserts that every spelling of a declared path is refused. On its
# own that is satisfiable by a classifier that refuses everything, and section
# 6h's own DOC-ONLY controls rule that out — but neither says WHICH code
# carries the fix. This section does, by removing one sentinel region at a
# time from a copy of the shipped script and re-driving 6h's exact inputs.
#
# TWO REGIONS, TWO DIFFERENT CLAIMS, and the second one is deliberately not the
# first one repeated:
#   GOV-PATH-RESOLUTION  — strip it and the dot / dot-dot / directory-symlink
#                          spellings return to DOC-ONLY. That is the measured
#                          mdnc defect, reproduced on demand.
#   GOV-LITERAL-PREFIX   — strip it and NOTHING in the 6h matrix moves. That is
#                          the honest claim about that region: it is a fork-free
#                          fast path, not the fix, and this leg is what would
#                          catch it silently becoming load-bearing again.
# A region whose removal changes nothing is normally a dead-code smell; the
# reason this one stays is written where it lives, and its residual (a parent
# directory that cannot be traversed) is declared UNPAIRED there rather than
# dressed up in a fixture that cannot reach it.
mk_region_mutant() {
    local region="$1" out="$2" lib="$3"
    awk -v r="$region" '
        $0 ~ ("^ *# --- " r "-BEGIN") { skip = 1; next }
        $0 ~ ("^ *# --- " r "-END")   { skip = 0; next }
        !skip { print }' "$VBS" > "$out"
    extract_classifier "$out" "$lib"
}

# code_grep_count <pattern> <file> — occurrences on NON-COMMENT lines only.
#
# EVERY PRESENCE PROBE IN SECTIONS 9 AND 10 GOES THROUGH THIS, and the reason is
# that the bare form was measured wrong DURING this round. These regions
# describe their own code at length; adding one sentence to the resolution
# region's header — "`cd -P "$pdir"` in place of ..." — took 9.5d from 1 to 2
# without touching a line of code, because the sentence quotes the pattern. That
# is the same defect section 3.4 already carries a note about (LESSONS.md,
# 2026-08-08: "grepping for the deleted pattern returns the prose"), and the
# same defence: read code lines only, so a probe cannot be satisfied — or
# defeated — by being described.
code_grep_count() {
    grep -v '^[[:space:]]*#' "$2" | grep -c "$1" | tr -d '[:space:]'
}

RES_SRC="$WORK/vbs-nores.sh"
RES_LIB="$GOVDIR/nores.sh"
mk_region_mutant "GOV-PATH-RESOLUTION" "$RES_SRC" "$RES_LIB"
assert_eq "9.0 GUARD: the resolution strip APPLIED (mutant differs from shipped)" "differs" \
    "$(cmp -s "$GOV_LIB" "$RES_LIB" && echo identical || echo differs)"
assert_eq "9.0b the mutant parses" "0" \
    "$(bash -n "$RES_LIB" 2>/dev/null && echo 0 || echo 1)"
# shellcheck disable=SC2016  # matching the LITERAL text `cd -P "$pdir"` in the
# extracted classifier, not expanding $pdir. Same for the `${abs:` reads below.
assert_eq "9.0c the strip took the resolution region and nothing of it survives" "0" \
    "$(code_grep_count 'cd -P "\$pdir"' "$RES_LIB")"
# shellcheck disable=SC2016
assert_eq "9.0d discriminator: the literal-prefix region SURVIVED (this strip took ONE thing)" "1" \
    "$(code_grep_count 'c_logical=\${abs:' "$RES_LIB")"

RES_GOV=$(classify_all "$RES_LIB" "$SPELL_ROOT" "$WORK/spell-gov.txt" 2>/dev/null)
# The four spellings the task filed, by name, each one back to the defect.
for sp in "$SPELL_ROOT/./docs/specs/T-1.md" \
          "docs/./specs/T-1.md" \
          "docs/specs/../specs/T-1.md" \
          ".claude/agents/../agents/qa.md" \
          "./CLAUDE.md" \
          "docs/speclink/T-1.md" \
          "$SPELL_ROOT/./docs/specs/T 2 spaced.md" \
          "$SPELL_ROOT/./docs/specs/T-3-café.md"; do
    assert_eq "9.1 META: without resolution, $sp is DOC-ONLY (6h WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$RES_GOV" "$sp")"
done
# Discriminators: the mutant still classifies the CANONICAL spellings correctly,
# so 9.1 is attributable to the reduction and not to a broken query or a
# classifier that stopped working.
for sp in "docs/specs/T-1.md" ".claude/agents/qa.md" "CLAUDE.md" \
          "$SPELL_ROOT/docs/specs/T-1.md"; do
    assert_eq "9.2 META discriminator: the mutant still refuses the CANONICAL $sp" \
        "reviewable" "$(verdict_of "$RES_GOV" "$sp")"
done
# ...and it still fast-paths ordinary documentation, so it has not simply died.
RES_DOC=$(classify_all "$RES_LIB" "$SPELL_ROOT" "$WORK/spell-doc.txt" 2>/dev/null)
assert_eq "9.2b META discriminator: the mutant still fast-paths an ordinary doc" "DOC-ONLY" \
    "$(verdict_of "$RES_DOC" "docs/design-notes/idea.md")"
# RESTORE CONTROL: the shipped copy, same inputs, same call shape.
assert_eq "9.3 restore control: the SHIPPED copy refuses the identical dot spelling" "reviewable" \
    "$(verdict_of "$SPELL_GOV" "$SPELL_ROOT/./docs/specs/T-1.md")"

# The out-of-tree declared directory is the case the LOGICAL half of the region
# answers; strip the region and it goes too, which is what separates 6h.1 from
# a re-run of the legs above.
RES_OUTDIR=$(classify_all "$RES_LIB" "$OUTDIR_ROOT" "$WORK/outdir.txt" 2>/dev/null)
assert_eq "9.4 META: without resolution, the out-of-tree declared dir loses the dot spelling too" \
    "DOC-ONLY" "$(verdict_of "$RES_OUTDIR" "$OUTDIR_ROOT/./docs/specs/T-9.md")"
assert_eq "9.4b META discriminator: ...while its canonical spelling still resolves" "reviewable" \
    "$(verdict_of "$RES_OUTDIR" "$OUTDIR_ROOT/docs/specs/T-9.md")"

LIT_SRC="$WORK/vbs-nolit.sh"
LIT_LIB="$GOVDIR/nolit.sh"
mk_region_mutant "GOV-LITERAL-PREFIX" "$LIT_SRC" "$LIT_LIB"
assert_eq "9.5 GUARD: the literal-prefix strip APPLIED (mutant differs from shipped)" "differs" \
    "$(cmp -s "$GOV_LIB" "$LIT_LIB" && echo identical || echo differs)"
assert_eq "9.5b the mutant parses" "0" \
    "$(bash -n "$LIT_LIB" 2>/dev/null && echo 0 || echo 1)"
# shellcheck disable=SC2016  # literal text in the extracted classifier, as above.
assert_eq "9.5c no literal-prefix reduction survives the strip" "0" \
    "$(code_grep_count 'c_logical=\${abs:' "$LIT_LIB")"
# shellcheck disable=SC2016
assert_eq "9.5d discriminator: the resolution region SURVIVED (this strip took ONE thing)" "1" \
    "$(code_grep_count 'cd -P "\$pdir"' "$LIT_LIB")"
# 3b lives inside GOV-LITERAL-PREFIX, so the strip must take it too — otherwise
# 9.6's "nothing moves" would be measuring a region that still carries a
# reduction. shellcheck disable=SC2016 as above.
# shellcheck disable=SC2016
assert_eq "9.5e ...and candidate 3b went with it (it lives in this region)" "0" \
    "$(code_grep_count 'c_lphys=\${abs:' "$LIT_LIB")"
classify_all "$LIT_LIB" "$SPELL_ROOT" "$WORK/spell-gov.txt" 2>/dev/null > "$WORK/lit-gov.txt"
classify_all "$LIT_LIB" "$SPELL_ROOT" "$WORK/spell-doc.txt" 2>/dev/null > "$WORK/lit-doc.txt"
printf '%s\n' "$SPELL_GOV" > "$WORK/ship-gov.txt"
printf '%s\n' "$SPELL_DOC" > "$WORK/ship-doc.txt"
assert_eq "9.6 the literal-prefix region is an OPTIMISATION: strip it and every 6h declared verdict is unchanged" \
    "identical" "$(cmp -s "$WORK/ship-gov.txt" "$WORK/lit-gov.txt" && echo identical || echo differs)"
assert_eq "9.6b ...and every 6h control verdict too" \
    "identical" "$(cmp -s "$WORK/ship-doc.txt" "$WORK/lit-doc.txt" && echo identical || echo differs)"
assert_eq "9.6c ...over a NON-EMPTY comparison (so 'identical' means something)" "yes" \
    "$([ -s "$WORK/lit-gov.txt" ] && [ -s "$WORK/lit-doc.txt" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 10. MONOTONICITY — THE DIFFERENTIAL AGAINST WHAT SHIPPED BEFORE
#     (claude-workflow-plugin-mdnc R1-F1)
# ---------------------------------------------------------------------------
# WHY THIS SECTION EXISTS, and it is a lesson about test SHAPE rather than about
# path resolution. mdnc's first cut shipped 109 new assertions and a stated
# safety invariant — "every candidate can only ADD a hit", "the change can only
# turn DOC-ONLY into reviewable and never the reverse". The invariant was FALSE,
# in the fail-open direction, at two sites: `cd -P "$d"` had been substituted for
# `cd "$d" && pwd -P`, which is a different function (they diverge exactly when a
# symlink precedes a `..`), so a reduction was DELETED rather than added and a
# declared governing artifact went back to taking the doc-only fast path with
# reviewed_by=none.
#
# NOT ONE of those 109 assertions could see it, and the reason generalises:
# THEY ALL RAN ONE ARTIFACT. Section 6h drives spellings against the shipped
# bytes; section 9 compares the shipped bytes against a REGION-STRIPPED copy of
# themselves. A monotonicity claim is a claim about the DIFFERENCE BETWEEN TWO
# ARTIFACTS — the old one and the new one — so no amount of exercising the new
# one alone can test it. This section runs BOTH.
#
# THE BASELINES, and why there are two:
#   FROZEN  .claude/scripts/tests/fixtures/gov-classifier-baseline-s5qf.sh —
#           the classifier as it stood at 0de5ceb, checked in and sha256-pinned.
#           This one is ALWAYS available (no git, no network, no history depth)
#           and never becomes vacuous, because the pin cannot move. It carries
#           the durable invariant: every path s5qf refused the fast path to, the
#           shipped classifier still refuses.
#   HEAD    the same extraction from `git show HEAD:` — the review-time arm,
#           and the one that would have caught R1-F1 in round 1. It is live
#           exactly while the change is uncommitted, which is when QA reads it.
#           On a clean tree HEAD and the worktree are the same bytes, so this
#           arm has nothing to compare and says so; the FROZEN arm is what keeps
#           the section load-bearing either way. Announced rather than silent —
#           a baseline that quietly stopped running is the failure mode this
#           whole section is about.
#
# THE NEGATIVE CONTROL is the defect itself, reconstructed: strip the GOV-LPHYS
# region from the shipped script and you have the bytes that were blocked, so
# the differential must report the two measured shapes moving reviewable ->
# DOC-ONLY. Without that leg "0 regressions" is satisfiable by a comparison that
# never ran.
#
# HARNESS CONTROLS, because this harness has already been fooled once. QA's
# first container run of the same differential returned `reviewable` for every
# path — an empty bind mount, the classifier never loaded — and that is the
# third recorded instance of the ALL-ONE-ANSWER shape on this task family. So
# before any verdict is believed: each side must produce BOTH verdicts over the
# sweep, and the two sides must produce the same NUMBER of verdicts as the sweep
# had inputs.
# ---------------------------------------------------------------------------

# The sweep is a list of (project-dir, paths-file) pairs. Most of it is fixtures
# sections 3 and 6h already built — reusing them is deliberate: they are the
# anti-overreach controls, so "zero ordinary documents moved" is measured over
# the same inputs that pin the fix, not over a friendlier set invented here.
MONO_PDIR=()
MONO_PATHS=()
mono_pair() { MONO_PDIR+=("$1"); MONO_PATHS+=("$2"); }

# 10.A THE ALIAS ROUTE — the first shape the substitution broke. The project is
# reached through a symlink to its root, and a `..` follows a symlink that
# points OUT of the tree. The kernel's `..` and bash's lexical `..` then name
# different directories, and BOTH exist, so `cd -P` succeeds and lands somewhere
# plausible and wrong.
ALIAS_BASE="$WORK/gov-alias"
mkdir -p "$ALIAS_BASE/proj/.claude/agents" "$ALIAS_BASE/proj/docs/specs" \
         "$ALIAS_BASE/elsewhere/hole/dir" "$ALIAS_BASE/elsewhere/hole/agents"
printf '# project memory\n' > "$ALIAS_BASE/proj/CLAUDE.md"
printf '# readme\n'         > "$ALIAS_BASE/proj/README.md"
printf 'qa agent\n'         > "$ALIAS_BASE/proj/.claude/agents/qa.md"
printf 'scratch notes\n'    > "$ALIAS_BASE/proj/.claude/agents/notes.txt"
printf '# a design\n'       > "$ALIAS_BASE/proj/docs/specs/T-1.md"
# The decoy: the kernel's answer for `.claude/x/..` has an `agents` child too,
# so candidate 4 produces a real directory rather than failing. A fixture where
# `cd -P` merely fails would understate the defect.
printf 'another tree\n'     > "$ALIAS_BASE/elsewhere/hole/agents/qa.md"
ln -sfn "proj"                              "$ALIAS_BASE/alias"
ln -sfn "$ALIAS_BASE/elsewhere/hole/dir"    "$ALIAS_BASE/proj/.claude/x"
ALIAS_PATH="$ALIAS_BASE/alias/.claude/x/../agents/qa.md"
ALIAS_PDIR="${ALIAS_PATH%/*}"
ALIAS_KERNEL=$(cd -P "$ALIAS_PDIR" 2>/dev/null && pwd)
ALIAS_LOGPHYS=$(cd "$ALIAS_PDIR" 2>/dev/null && pwd -P)
assert_eq "10.A0 precondition: the alias really is a symlink to the project root" "yes" \
    "$([ -L "$ALIAS_BASE/alias" ] && [ -d "$ALIAS_BASE/alias" ] && echo yes || echo no)"
assert_eq "10.A0b precondition: .claude/x really is a symlink pointing OUT of the tree" "outside" \
    "$([ -L "$ALIAS_BASE/proj/.claude/x" ] && \
       { [ "${ALIAS_KERNEL#"$(cd -P "$ALIAS_BASE/proj" && pwd)"/}" = "$ALIAS_KERNEL" ] && echo outside || echo inside; })"
assert_eq "10.A0c precondition: BOTH readings of the parent exist (so 'cd -P' does not merely fail)" "yes" \
    "$([ -n "$ALIAS_KERNEL" ] && [ -n "$ALIAS_LOGPHYS" ] && echo yes || echo no)"
assert_eq "10.A0d precondition: ...and they DISAGREE — without this the leg is vacuous" "differ" \
    "$([ "$ALIAS_KERNEL" != "$ALIAS_LOGPHYS" ] && echo differ || echo same)"
cat > "$WORK/mono-alias.txt" <<EOF
$ALIAS_PATH
$ALIAS_BASE/alias/.claude/agents/qa.md
$ALIAS_BASE/proj/.claude/agents/qa.md
$ALIAS_BASE/alias/./docs/specs/T-1.md
.claude/agents/qa.md
CLAUDE.md
$ALIAS_BASE/alias/.claude/x/../agents/notes.txt
$ALIAS_BASE/alias/README.md
README.md
EOF
mono_pair "$ALIAS_BASE/proj" "$WORK/mono-alias.txt"

# 10.B A `..`-BEARING PROJECT_DIR — the second shape, and the worse one: the
# ROOT itself is computed wrong, so every absolute governing path misses every
# candidate at once. CLAUDE_PROJECT_DIR is whatever the launching environment
# put there; this is not an exotic spelling for a wrapper script to produce.
DD_BASE="$WORK/gov-dotdot"
DD_ROOT="$DD_BASE/root"
mkdir -p "$DD_ROOT/.claude/agents" "$DD_ROOT/docs/specs" "$DD_BASE/far/deep/inner"
printf '# project memory\n' > "$DD_ROOT/CLAUDE.md"
printf '# readme\n'         > "$DD_ROOT/README.md"
printf 'qa agent\n'         > "$DD_ROOT/.claude/agents/qa.md"
printf 'scratch notes\n'    > "$DD_ROOT/.claude/agents/notes.txt"
printf '# a design\n'       > "$DD_ROOT/docs/specs/T-1.md"
ln -sfn "$DD_BASE/far/deep/inner" "$DD_ROOT/.claude/x"
DD_PD="$DD_ROOT/.claude/x/../.."
DD_KERNEL=$(cd -P "$DD_PD" 2>/dev/null && pwd)
DD_LOGPHYS=$(cd "$DD_PD" 2>/dev/null && pwd -P)
DD_ROOT_PHYS=$(cd -P "$DD_ROOT" 2>/dev/null && pwd)
assert_eq "10.B0 precondition: the two readings of PROJECT_DIR DISAGREE" "differ" \
    "$([ -n "$DD_KERNEL" ] && [ -n "$DD_LOGPHYS" ] && [ "$DD_KERNEL" != "$DD_LOGPHYS" ] && echo differ || echo same)"
assert_eq "10.B0b precondition: the LOGICAL reading is the real root (so the kernel one is the wrong answer)" "yes" \
    "$([ "$DD_LOGPHYS" = "$DD_ROOT_PHYS" ] && echo yes || echo no)"
cat > "$WORK/mono-dotdot.txt" <<EOF
$DD_ROOT/.claude/agents/qa.md
$DD_ROOT/CLAUDE.md
$DD_ROOT/docs/specs/T-1.md
.claude/agents/qa.md
CLAUDE.md
docs/specs/T-1.md
$DD_ROOT/.claude/agents/notes.txt
$DD_ROOT/README.md
README.md
EOF
mono_pair "$DD_PD"   "$WORK/mono-dotdot.txt"
mono_pair "$DD_ROOT" "$WORK/mono-dotdot.txt"

# ...and the fixtures the earlier sections already built. These carry the
# anti-overreach half: 27 declared spellings, 27 ordinary-document controls, the
# equal-length sibling root, the out-of-tree declared directory, the deletion
# residual, and — when section 3 ran its else-branch — 1120 name/position shapes
# that have nothing to do with the governing veto at all.
mono_pair "$SPELL_ROOT"  "$WORK/spell-gov.txt"
mono_pair "$SPELL_ROOT"  "$WORK/spell-doc.txt"
mono_pair "$SPELL_ROOT"  "$WORK/spell-other.txt"
mono_pair "$OUTDIR_ROOT" "$WORK/outdir.txt"
mono_pair "$DEL_ROOT"    "$WORK/del.txt"
[ -f "$WORK/cross.txt" ] && mono_pair "$WORK/nonexistent-root" "$WORK/cross.txt"

MONO_INPUTS=0
for _f in "${MONO_PATHS[@]}"; do
    MONO_INPUTS=$((MONO_INPUTS + $(grep -c . "$_f" | tr -d '[:space:]')))
done
# Pinned, for the same reason EXPECTED_SPECS is pinned one tier up: a sweep that
# quietly shrank is a differential that quietly stopped looking. 1219 = 9 alias
# + 9+9 dot-dot-PROJECT_DIR (two roots) + 28 declared spellings + 28 ordinary
# controls + 3 sibling-root + 7 out-of-tree + 6 deletion + 1120 name/position.
assert_eq "10.0 the sweep is NON-EMPTY and the expected size (9 pairs, 1219 paths)" "1219" "$MONO_INPUTS"
assert_eq "10.0b ...over the expected number of (project-dir, paths) pairs" "9" "${#MONO_PDIR[@]}"

# mono_sweep <baseline-lib> <candidate-lib> <tag>
#   Drives every pair through both libs and writes, into $WORK:
#     mono-<tag>.cmp   baseline-verdict TAB candidate-verdict TAB path
#     mono-<tag>.reg   the paths that went reviewable -> DOC-ONLY  (FAIL-OPEN)
#     mono-<tag>.imp   the paths that went DOC-ONLY -> reviewable  (the fix)
#   `paste` is safe here because classify_all emits one line per NON-EMPTY input
#   line in input order; the line-count guard below is what keeps that true
#   rather than assumed.
mono_sweep() {
    local blib="$1" clib="$2" tag="$3" i=0 n
    : > "$WORK/mono-$tag.cmp"
    n=${#MONO_PDIR[@]}
    while [ "$i" -lt "$n" ]; do
        grep . "${MONO_PATHS[$i]}" > "$WORK/mono-in.txt"
        classify_all "$blib" "${MONO_PDIR[$i]}" "$WORK/mono-in.txt" 2>/dev/null | cut -f1 > "$WORK/mono-b.txt"
        classify_all "$clib" "${MONO_PDIR[$i]}" "$WORK/mono-in.txt" 2>/dev/null | cut -f1 > "$WORK/mono-c.txt"
        paste "$WORK/mono-b.txt" "$WORK/mono-c.txt" "$WORK/mono-in.txt" >> "$WORK/mono-$tag.cmp"
        i=$((i + 1))
    done
    awk -F'\t' '$1=="reviewable" && $2=="DOC-ONLY" { print $3 }' "$WORK/mono-$tag.cmp" > "$WORK/mono-$tag.reg"
    awk -F'\t' '$1=="DOC-ONLY" && $2=="reviewable" { print $3 }' "$WORK/mono-$tag.cmp" > "$WORK/mono-$tag.imp"
}
mono_count() { grep -c . "$WORK/mono-$1.$2" 2>/dev/null | tr -d '[:space:]'; }
mono_verdicts() { awk -F'\t' -v c="$2" '{ print $c }' "$WORK/mono-$1.cmp" | sort -u | tr '\n' ',' ; }

# --- the FROZEN baseline ---------------------------------------------------
BASELINE_SRC="$PROJECT_DIR/.claude/scripts/tests/fixtures/gov-classifier-baseline-s5qf.sh"
# The pin. It is not decoration: without it, "refresh the baseline to match what
# we ship" is a one-line change that silently deletes the invariant and leaves
# every assertion below green. Regenerating the file from 0de5ceb reproduces
# this digest; see the fixture's own header for the command.
BASELINE_SHA_EXPECTED="620d631e12ab59421acdea7f3606b8cbf9d855fa2c315691bcd79e307ec6c41f"
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1
    else shasum -a 256 < "$1" | cut -d' ' -f1; fi
}
assert_eq "10.1 the frozen baseline fixture is present" "yes" \
    "$([ -f "$BASELINE_SRC" ] && echo yes || echo no)"
assert_eq "10.1b ...and is the PINNED bytes (an 'update' to match today's ship is the failure this catches)" \
    "$BASELINE_SHA_EXPECTED" "$(sha256_of "$BASELINE_SRC" 2>/dev/null)"
BASE_LIB="$GOVDIR/baseline-s5qf.sh"
cp "$BASELINE_SRC" "$BASE_LIB"
assert_eq "10.1c the baseline parses" "0" \
    "$(bash -n "$BASE_LIB" 2>/dev/null && echo 0 || echo 1)"
assert_eq "10.1d the baseline defines the classifier and the governing veto" "2" \
    "$(grep -cE '^(is_doc_only_path|governing_artifact_origin)\(\) \{$' "$BASE_LIB" | tr -d '[:space:]')"
assert_eq "10.1e ANTI-VACUITY: the baseline is NOT the shipped bytes (else this compares a file with itself)" \
    "differs" "$(cmp -s "$GOV_LIB" "$BASE_LIB" && echo identical || echo differs)"

mono_sweep "$BASE_LIB" "$GOV_LIB" "frozen"
# HARNESS CONTROLS FIRST — see the all-one-answer note in this section's header.
assert_eq "10.2 harness: the comparison covers every swept path" "$MONO_INPUTS" \
    "$(grep -c . "$WORK/mono-frozen.cmp" | tr -d '[:space:]')"
assert_eq "10.2b harness: the BASELINE produced both verdicts (not all-one-answer)" "DOC-ONLY,reviewable," \
    "$(mono_verdicts frozen 1)"
assert_eq "10.2c harness: the SHIPPED classifier produced both verdicts too" "DOC-ONLY,reviewable," \
    "$(mono_verdicts frozen 2)"

# THE CLAIM. Zero paths lost the veto; the fix is not vacuous.
MONO_REG=$(mono_count frozen reg)
if [ "$MONO_REG" != "0" ]; then
    printf '  differential: paths that LOST the governing veto since 0de5ceb:\n'
    while IFS= read -r _p; do [ -n "$_p" ] && printf '    %s\n' "$_p"; done < "$WORK/mono-frozen.reg"
fi
printf '  differential: 0de5ceb -> shipped over %s path(s): %s gained the veto, %s lost it\n' \
    "$MONO_INPUTS" "$(mono_count frozen imp)" "$MONO_REG"
assert_eq "10.3 MONOTONE vs the frozen s5qf baseline: 0 paths went reviewable -> DOC-ONLY" "0" "$MONO_REG"
assert_eq "10.3b ...and the sweep is not vacuous: the fix moved paths the OTHER way" "yes" \
    "$([ "$(mono_count frozen imp)" -gt 0 ] && echo yes || echo no)"

# --- the NEGATIVE CONTROL: the defect, reconstructed ------------------------
# Strip GOV-LPHYS and the shipped script becomes the bytes QA blocked: the
# kernel-physical reduction alone, with s5qf's composition deleted. Three spans
# carry the region (the root in load_governing_set, candidate 3b, candidate 6);
# the variables they assign are declared OUTSIDE them, so the strip leaves empty
# candidates rather than an unbound-variable crash — which would fail this leg
# for the wrong reason and prove nothing about resolution.
LPH_SRC="$WORK/vbs-nolphys.sh"
LPH_LIB="$GOVDIR/nolphys.sh"
mk_region_mutant "GOV-LPHYS" "$LPH_SRC" "$LPH_LIB"
assert_eq "10.4 GUARD: the GOV-LPHYS strip APPLIED (mutant differs from shipped)" "differs" \
    "$(cmp -s "$GOV_LIB" "$LPH_LIB" && echo identical || echo differs)"
assert_eq "10.4b the mutant parses" "0" \
    "$(bash -n "$LPH_LIB" 2>/dev/null && echo 0 || echo 1)"
# shellcheck disable=SC2016  # literal text in the extracted classifier.
assert_eq "10.4c the strip took all three GOV-LPHYS spans: the root capture is gone" "0" \
    "$(code_grep_count '_GOV_ROOT_LPHYS=\$(cd' "$LPH_LIB")"
# shellcheck disable=SC2016
assert_eq "10.4c2 ...candidate 3b is gone" "0" \
    "$(code_grep_count 'c_lphys=\${abs:' "$LPH_LIB")"
# shellcheck disable=SC2016
assert_eq "10.4c3 ...and candidate 6 is gone" "0" \
    "$(code_grep_count 'pdir_lphys=\$(cd' "$LPH_LIB")"
# shellcheck disable=SC2016
assert_eq "10.4d discriminator: candidate 4 SURVIVED (this strip took ONE thing)" "1" \
    "$(code_grep_count 'cd -P "\$pdir"' "$LPH_LIB")"
# shellcheck disable=SC2016
assert_eq "10.4e discriminator: ...and so did candidate 5" "1" \
    "$(code_grep_count 'pdir_log=\$(cd' "$LPH_LIB")"

mono_sweep "$BASE_LIB" "$LPH_LIB" "nolphys"
assert_eq "10.5 harness: the negative control's comparison covers every swept path" "$MONO_INPUTS" \
    "$(grep -c . "$WORK/mono-nolphys.cmp" | tr -d '[:space:]')"
assert_eq "10.5b NEGATIVE CONTROL: without GOV-LPHYS the differential REPORTS the fail-open" "yes" \
    "$([ "$(mono_count nolphys reg)" -gt 0 ] && echo yes || echo no)"
# ...and it reports the two shapes that were actually measured, by name, so the
# control cannot be satisfied by some unrelated path drifting.
assert_eq "10.5c NEGATIVE CONTROL names the alias route" "1" \
    "$(grep -cxF "$ALIAS_PATH" "$WORK/mono-nolphys.reg" | tr -d '[:space:]')"
assert_eq "10.5d NEGATIVE CONTROL names the \`..\`-bearing PROJECT_DIR's artifacts" "3" \
    "$(grep -cxF -e "$DD_ROOT/.claude/agents/qa.md" -e "$DD_ROOT/CLAUDE.md" \
        -e "$DD_ROOT/docs/specs/T-1.md" "$WORK/mono-nolphys.reg" | tr -d '[:space:]')"
# ATTRIBUTION. The mutant has not simply died: it still refuses the canonical
# spellings and still fast-paths ordinary documentation, so 10.5b-d are about
# the deleted reduction rather than about a classifier that stopped working.
LPH_SPELL=$(classify_all "$LPH_LIB" "$SPELL_ROOT" "$WORK/spell-gov.txt" 2>/dev/null)
LPH_DOC=$(classify_all "$LPH_LIB" "$SPELL_ROOT" "$WORK/spell-doc.txt" 2>/dev/null)
assert_eq "10.5e attribution: the mutant still refuses the canonical .claude/agents/qa.md" "reviewable" \
    "$(verdict_of "$LPH_SPELL" ".claude/agents/qa.md")"
assert_eq "10.5f attribution: ...and still fast-paths an ordinary document" "DOC-ONLY" \
    "$(verdict_of "$LPH_DOC" "docs/design-notes/idea.md")"
# ...and it moved NOTHING in the section-6h matrix, which is precisely why 109
# green assertions could not see the defect. This leg is the record of that.
assert_eq "10.5g THE REASON 6h COULD NOT SEE IT: the mutant's 6h declared verdicts are UNCHANGED" \
    "identical" "$(printf '%s\n' "$LPH_SPELL" > "$WORK/lph-gov.txt"; \
                   cmp -s "$WORK/ship-gov.txt" "$WORK/lph-gov.txt" && echo identical || echo differs)"

# --- the HEAD arm ----------------------------------------------------------
# Live while the change is uncommitted, which is when it matters. Silent about
# nothing: it prints which state it was in.
HEAD_STATE="unavailable"
HEAD_LIB="$GOVDIR/head.sh"
if command -v git >/dev/null 2>&1 && \
   git -C "$PROJECT_DIR" rev-parse --verify -q HEAD >/dev/null 2>&1 && \
   git -C "$PROJECT_DIR" show "HEAD:.claude/scripts/verify-before-stop.sh" > "$WORK/vbs-head.sh" 2>/dev/null; then
    extract_classifier "$WORK/vbs-head.sh" "$HEAD_LIB"
    if cmp -s "$GOV_LIB" "$HEAD_LIB"; then
        HEAD_STATE="clean"
    else
        HEAD_STATE="differs"
    fi
fi
printf '  differential: frozen baseline ACTIVE (0de5ceb, pinned); HEAD arm %s\n' "$HEAD_STATE"
case "$HEAD_STATE" in
    differs)
        mono_sweep "$HEAD_LIB" "$GOV_LIB" "head"
        assert_eq "10.6 harness: the HEAD comparison covers every swept path" "$MONO_INPUTS" \
            "$(grep -c . "$WORK/mono-head.cmp" | tr -d '[:space:]')"
        assert_eq "10.6b harness: HEAD produced both verdicts (not all-one-answer)" "DOC-ONLY,reviewable," \
            "$(mono_verdicts head 1)"
        MONO_HREG=$(mono_count head reg)
        printf '  differential: HEAD -> worktree over %s path(s): %s gained the veto, %s lost it\n' \
            "$MONO_INPUTS" "$(mono_count head imp)" "$MONO_HREG"
        if [ "$MONO_HREG" != "0" ]; then
            printf '  differential: paths this WORKING TREE takes away from HEAD:\n'
            while IFS= read -r _p; do [ -n "$_p" ] && printf '    %s\n' "$_p"; done < "$WORK/mono-head.reg"
        fi
        assert_eq "10.6c MONOTONE vs HEAD: the uncommitted change removes no veto" "0" "$MONO_HREG"
        ;;
    clean|unavailable)
        # NOT A SKIP MARKER, deliberately, and the assertion below is why this
        # is honest rather than convenient. `clean` means the worktree's
        # classifier IS HEAD's, so there is no second artifact to compare;
        # `unavailable` means git or the object is missing, which every other
        # git-dependent spec in this tier already fails outright on. In both
        # states the load-bearing claim is the same one, so it is ASSERTED
        # rather than announced: the frozen arm ran over the whole sweep and was
        # not vacuous. That can fail — a shrunken sweep or a baseline refreshed
        # to match today's ship makes it fail — which is what separates it from
        # a line of prose.
        assert_eq "10.6 HEAD arm $HEAD_STATE — the FROZEN arm carried the section (full sweep, non-vacuous)" "yes" \
            "$([ "$(grep -c . "$WORK/mono-frozen.cmp" | tr -d '[:space:]')" = "$MONO_INPUTS" ] && \
               [ "$(mono_count frozen imp)" -gt 0 ] && echo yes || echo no)"
        ;;
esac

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0

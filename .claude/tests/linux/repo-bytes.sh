#!/bin/bash
# repo-bytes.sh <repo-root> — one sha256 over the repo's tracked WORKING-TREE
# bytes, plus the counts that digest was taken over.
#
# WHY IT EXISTS. run-linux-tier.sh bind-mounts the checkout into the container
# instead of copying it, and the constraint driving that choice is "the tier
# must run against the repo's REAL BYTES, not a copy that can drift". A mount
# is only worth more than a copy if that claim is CHECKED — an unchecked mount
# is a copy whose drift nobody can see. So the driver runs THIS script twice,
# once on the host and once inside the container, and refuses the run when the
# two digests disagree.
#
# ONE IMPLEMENTATION, TWO EXECUTIONS. The script is the artifact both sides
# run; nothing is re-typed on the container side, so the comparison cannot pass
# because two copies of the logic agreed with each other while both were wrong.
#
# THE HASHER IS FED ON STDIN, NEVER GIVEN A FILENAME, and that is not
# fastidiousness — it is the first thing the Linux container found. GNU
# coreutils `sha256sum` ESCAPES a filename containing a newline or a backslash:
# it prefixes the whole output line with `\` and writes `\n` for the newline, so
# `${raw%% *}` reads a 65-character token beginning with a backslash. BSD
# `shasum` does not escape. Passing names to the hasher would therefore make
# THIS script's digest depend on the platform for exactly the paths that are
# most interesting, which is the failure mode it exists to detect.
# (See the finding recorded against claude-workflow-plugin-mdnc's container run:
# workflow-manifest.sh's hash_file has this bug for real.)
#
# WHAT IT COVERS, stated so the digest is not over-read:
#   * every path `git ls-files` reports, hashed by CONTENT for regular files.
#   * symlinks by TARGET STRING rather than by content, so the `tests ->
#     .claude/scripts/tests` shim is compared as a link rather than followed.
#     Residual, named: `readlink` output is captured through `$( )`, which
#     strips trailing newlines, so a link target ENDING in a newline would
#     compare equal to the same target without it. This is a drift diagnostic,
#     not a containment predicate — the LESSONS entry that bans the round-trip
#     is about predicates that decide whether one path is inside another.
#   * NOT untracked files. node_modules, `.claude/.qa-tracking/` and the
#     gitignored half of `.beads/` are outside the digest: they differ between
#     any two machines and would make the check cry wolf on every run. What
#     that costs is stated in the driver's report rather than hidden.
#
#     `.beads/` IS ONLY PARTLY OUTSIDE IT, and the distinction is operational
#     rather than pedantic. Measured at claude-workflow-plugin-mdnc: seven
#     `.beads/` paths are TRACKED — `issues.jsonl` and `interactions.jsonl`
#     among them — so a `bd` write lands squarely inside this digest, and the
#     driver's post-run recheck then reports MOVED UNDER THE RUN for a tier
#     run that was otherwise fine. That is the detector working, not a false
#     positive: the tree did move. The consequence for whoever runs the tier
#     is simply DO NOT TOUCH BEADS WHILE IT RUNS, which is also the standing
#     rule for any measurement in this repo (LESSONS.md: stop measuring under
#     concurrent writers). An earlier version of this comment said `.beads`
#     runtime state was outside the digest full stop, which would have sent
#     the reader looking for the drift somewhere it could not be.
#
# Output (three lines, stable order):
#   digest <64-hex>
#   files  <count of regular files hashed>
#   links  <count of symlinks recorded>
#
# Exit codes: 0 ok · 2 unusable (not a git repo, no git, no sha256 tool)

set -u

ROOT="${1:-.}"

hash_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256
    else
        return 3
    fi
}

if ! command -v git >/dev/null 2>&1; then
    printf 'repo-bytes.sh: git is not on PATH — cannot enumerate the tracked set\n' >&2
    exit 2
fi
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    printf 'repo-bytes.sh: neither sha256sum nor shasum is on PATH\n' >&2
    exit 2
fi

cd "$ROOT" 2>/dev/null || {
    printf 'repo-bytes.sh: cannot cd into %s\n' "$ROOT" >&2
    exit 2
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'repo-bytes.sh: %s is not inside a git work tree\n' "$ROOT" >&2
    exit 2
fi

# The per-path stream is built first, then hashed as a whole. Sorted with
# LC_ALL=C so a collation difference between the host and the container cannot
# reorder it — the same reason workflow-manifest.sh sorts that way.
n_files=0
n_links=0
stream=""
while IFS= read -r -d '' f; do
    if [ -L "$f" ]; then
        n_links=$((n_links + 1))
        stream="$stream""L	$(readlink "$f")	$f
"
    elif [ -f "$f" ]; then
        h=$(hash_stdin < "$f") || {
            printf 'repo-bytes.sh: could not hash %s\n' "$f" >&2
            exit 2
        }
        n_files=$((n_files + 1))
        stream="$stream""F	${h%% *}	$f
"
    else
        # Tracked but neither a regular file nor a link in this tree (a
        # gitlink/submodule, or a path that vanished under us). Recorded as its
        # own kind rather than skipped: a path that exists on one side and not
        # the other is exactly the drift this digest is for.
        stream="$stream""?	-	$f
"
    fi
done < <(git ls-files -z)

digest=$(printf '%s' "$stream" | LC_ALL=C sort | hash_stdin)
printf 'digest %s\n' "${digest%% *}"
printf 'files  %s\n' "$n_files"
printf 'links  %s\n' "$n_links"

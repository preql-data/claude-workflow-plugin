# Linux tier image — the environment `make test-linux` runs L1 (and L2) in.
#
# WHY THIS EXISTS. Every hook script, runner and gate in this repo is authored
# and measured on macOS (BSD find, BSD sed, BSD stat, bash 3.2), and shipped to
# a CI tier that runs on ubuntu-latest (GNU coreutils, bash 5.2). Until this
# image there was no way to run the tiers on Linux without pushing, so "it works
# on Linux" was an inference from two spot-checked `find` behaviours. A first
# push would also have conflated NEW CI WIRING with FIRST LINUX EXPOSURE: a red
# run could not tell you which of the two it was.
#
# WHAT IT MIRRORS, and where it deliberately differs from .github/workflows/
# test.yml — read this list before concluding that a green run here implies a
# green CI run:
#
#   MIRRORED
#     * ubuntu:24.04 — the same distro release ubuntu-latest currently is.
#     * bd 1.1.2, from the pinned release tarball, sha256-verified, installed
#       to /usr/local/bin. The path is load-bearing exactly as it is in CI:
#       installer-flags.test.sh probes a prereq-hostile PATH of
#       /usr/bin:/bin:/usr/sbin:/sbin and SKIPS three positive-control sections
#       if bd resolves under it, so bd must NOT land in /usr/bin.
#     * node 20 (nodejs.org tarball, sha256-verified) — the major
#       actions/setup-node@v4 pins in every job here. Ubuntu 24.04's own
#       `nodejs` package is 18.19, which satisfies both MCP servers' engines
#       field but is not what CI runs; matching CI matters more than saving a
#       download.
#     * A NON-ROOT default user. Two L1 sections (workflow-manifest 532,
#       gate-claim-honesty 1247) skip when euid is 0, and GitHub runners are
#       the unprivileged `runner` user. Running this image as root would
#       silently drop them.
#
#   DIFFERENT — stated, not hidden
#     * ARCHITECTURE. This builds for the host's native arch. On an Apple
#       Silicon dev box that is linux/arm64; CI is linux/amd64. Pass
#       CWP_LINUX_PLATFORM=linux/amd64 to cross-check under emulation (slow).
#       The digests below cover both arches so either resolves.
#     * NO `gh`. GitHub runners ship it preinstalled; bd-github-link's gh arm
#       therefore behaves differently here than in CI. Left out on purpose:
#       installing gh would need another apt source, and the arm's absence is
#       visible as a skip marker rather than silently passing.
#     * NO ambient git identity (user.name / user.email). actions/checkout does
#       not set one either, so a spec that depends on ambient identity is
#       equally broken in both places — and setting one here would hide that.
#     * NO npm install of the two MCP servers. The repo is bind-mounted
#       READ-ONLY (see run-linux-tier.sh), so their node_modules come from the
#       host checkout. Both are pure JS + WASM (no .node binaries — verified:
#       `find .claude/mcp/*/node_modules -name '*.node'` returns nothing), so a
#       macOS-installed tree is loadable here. If yours is absent, the specs
#       keyed on it skip and the runner reds the tier, which is the honest
#       outcome.
#
# The base image is a TAG, not a digest, and that is deliberate: ubuntu-latest
# is itself a moving target, so pinning this by digest would make the mirror
# LESS faithful while adding a bump chore. Override with CWP_LINUX_BASE.

ARG BASE=ubuntu:24.04
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive

# The tiers' measured command surface. Collected with:
#   grep -hoE 'command -v [a-zA-Z0-9_.-]+' .claude/scripts/tests/*.sh \
#       .claude/tests/component/specs/*.sh .claude/tests/component/lib/*.sh \
#     | sort | uniq -c | sort -rn
# which at 0de5ceb reports: bd 39, jq 22, node 9, shasum 6, npm 5, git 4,
# sha256sum 3, perl 2, make 2, awk 2, and one each of sqlite3, rsync, openssl,
# mktemp, gh, curl, bash. Everything on that list except `gh` (see the header)
# is provided here; `shasum` rides in with perl, `sha256sum`/`mktemp`/`awk`
# with coreutils. procps is for ps(1) — both runners' process-group sweeps and
# kill escalations are built on `ps -axo`, so without it every survivor sweep
# would silently see an empty world.
#
# python3 IS ON THE LIST AND THE GREP DID NOT FIND IT, which is the point of
# recording how the list was built. lessons.test.sh:609 and
# mutation-harness.test.sh:448 shell out to python3 with NO `command -v` guard,
# so on the first run of this image (python3 absent) they did not skip — they
# printed `python3: command not found` and FAILED an assertion with a wrong
# number. GitHub's ubuntu-24.04 runner ships python3, so CI never saw it; a
# leaner runner image would. Provisioned here to match CI, and the unguarded
# dependency is filed rather than papered over.
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        git \
        jq \
        make \
        openssl \
        perl \
        procps \
        python3 \
        rsync \
        sqlite3 \
        xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && jq --version && git --version && perl -e 'print "perl ok\n"' \
    && command -v shasum && command -v sha256sum && command -v ps && command -v python3

# --- node 20 ---------------------------------------------------------------
# Pinned version + per-arch sha256. Digests taken from the publisher's own
# manifest, not from a local download:
#   curl -fsSL https://nodejs.org/dist/v20.20.2/SHASUMS256.txt \
#     | grep -E 'node-v20.20.2-linux-(x64|arm64)\.tar\.xz$'
# (run 2026-08-13). A tag can move; a digest cannot.
ARG NODE_VERSION=v20.20.2
ARG NODE_SHA256_ARM64=73093db209e4e9e09dd7d15a47aeaab1b74833830df03efa5f942a1122c5fa71
ARG NODE_SHA256_X64=df770b2a6f130ed8627c9782c988fda9669fa23898329a61a871e32f965e007d
RUN set -eu; \
    deb_arch="$(dpkg --print-architecture)"; \
    case "$deb_arch" in \
        amd64) node_arch=x64;   node_sha="$NODE_SHA256_X64" ;; \
        arm64) node_arch=arm64; node_sha="$NODE_SHA256_ARM64" ;; \
        *) echo "unsupported architecture: $deb_arch" >&2; exit 1 ;; \
    esac; \
    tarball="node-${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSL --retry 3 -o "/tmp/$tarball" \
        "https://nodejs.org/dist/${NODE_VERSION}/${tarball}"; \
    printf '%s  /tmp/%s\n' "$node_sha" "$tarball" | sha256sum -c -; \
    tar -xJf "/tmp/$tarball" -C /usr/local --strip-components=1 \
        --exclude CHANGELOG.md --exclude LICENSE --exclude README.md; \
    rm -f "/tmp/$tarball"; \
    node --version; \
    npm --version

# --- bd (Beads CLI) --------------------------------------------------------
# Same version + same provenance as the CI l1-unit job, extended to arm64 so
# this image builds on an Apple Silicon dev box. Digests from the release's own
# checksums.txt, cross-checked against an independent download:
#   curl -fsSL https://github.com/steveyegge/beads/releases/download/v1.1.2/checksums.txt \
#     | grep -E 'linux_(amd64|arm64)'
# The amd64 line is byte-identical to the one pinned in .github/workflows/
# test.yml, which is the point: same artifact, verified the same way.
#
# /usr/local/bin, NOT /usr/bin — see the header note on installer-flags.
ARG BD_VERSION=1.1.2
ARG BD_SHA256_AMD64=a72d71ed374955dc9f83a0f90b54bd7b6a0016709dd1676ae2e368651ed401c2
ARG BD_SHA256_ARM64=a134015faf4be0a43f8681a8d602eaf0b7c255c957f09d3c933257c8c92fdd10
RUN set -eu; \
    deb_arch="$(dpkg --print-architecture)"; \
    case "$deb_arch" in \
        amd64) bd_sha="$BD_SHA256_AMD64" ;; \
        arm64) bd_sha="$BD_SHA256_ARM64" ;; \
        *) echo "unsupported architecture: $deb_arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 -o /tmp/beads.tar.gz \
        "https://github.com/steveyegge/beads/releases/download/v${BD_VERSION}/beads_${BD_VERSION}_linux_${deb_arch}.tar.gz"; \
    printf '%s  /tmp/beads.tar.gz\n' "$bd_sha" | sha256sum -c -; \
    tar -xzf /tmp/beads.tar.gz -C /usr/local/bin bd; \
    rm -f /tmp/beads.tar.gz; \
    chmod 0755 /usr/local/bin/bd; \
    bd version

# The repo arrives as a bind mount owned by whatever uid the host checkout uses.
# git 2.35.2+ refuses to operate on a tree it thinks belongs to someone else,
# and several specs shell out to git against /repo. Scoped to the one path this
# image ever mounts rather than the '*' wildcard.
RUN git config --system --add safe.directory /repo

# ubuntu:24.04 ships a non-root `ubuntu` user at uid/gid 1000. Two L1 sections
# skip when euid is 0 (see the header), so root is the wrong default here even
# though it is the convenient one.
USER ubuntu
ENV HOME=/home/ubuntu
WORKDIR /repo
CMD ["bash"]

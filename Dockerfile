# syntax = docker/dockerfile:1

# INSTRUCTIONS
#
# Build local context (chainweb-node repo):
#
# ```sh
# docker buildx build .
# ```
#
# Build remote context from github:
#
# ```
# docker buildx build --build-arg BUILDKIT_CONTEXT_KEEP_GIT_DIR=1 https://github.com/kadena-io/chainweb-node.git#master
# ```
#
# Setting `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1` is optional but enables some
# additional sanity checks.
#
# Skipping tests:
#
# ```sh
# docker buildx build --target=chainweb-node .
# ```
#
# Usefull target values are:
#
# - chainweb-node, image with only chainweb-node
# - chainweb-applications, image with all executables from the repository
# - chainweb-node-tested (default), just chainweb-node, runs tests during build
#
# Troubleshooting:
#
# If the build is failing because of unavailable disk space, try pruning the
# build cache with
#
# ```sh
# docker buildx prune --all
# ```

# ############################################################################ #
# Parameters
# ############################################################################ #

# changing the ubuntu version will most likely break the build. In order to
# support this we would have to define dedicated runtime images and build
# images.

ARG UBUNTU_VERSION=22.04
ARG GHC_VERSION=9.10.2
ARG PROJECT_NAME=chainweb

# ############################################################################ #
# Chainweb Application Runtime Image
# ############################################################################ #

FROM ubuntu:${UBUNTU_VERSION} AS chainweb-runtime
ARG GHC_VERSION
ARG UBUNTU_VERSION
ARG TARGETPLATFORM
ARG DEBIAN_FRONTEND=noninteractive
RUN <<EOF
    apt-get update -y
    apt-get install -yqq \
        --no-install-recommends \
        ca-certificates \
        libbz2-1.0 \
        libffi8 \
        libgmp10 \
        liblz4-1 \
        libncurses5 \
        libsnappy1v5 \
        libssl3 \
        libtinfo5 \
        locales \
        zlib1g \
        libgflags2.2 \
        libmpfr6
    if [ "${TARGETPLATFORM}" = "linux/arm64" ] ; then
        apt-get install -yqq \
            --no-install-recommends \
            llvm-12 \
            libnuma1
    fi
    rm -rf /var/lib/apt/lists/*
    locale-gen en_US.UTF-8
    update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
EOF
ENV LANG=en_US.UTF-8
WORKDIR /chainweb
LABEL com.chainweb.docker.image.compiler="ghc-${GHC_VERSION}"
LABEL com.chainweb.docker.image.os="ubuntu-${UBUNTU_VERSION}"

# ############################################################################ #
# Chainweb Build Image
# ############################################################################ #

FROM chainweb-runtime AS chainweb-build
RUN <<EOF
  echo "BUILDPLATFORM: $BUILDPLATFORM"
  echo "TARGETPLATFORM: $TARGETPLATFORM"
EOF
ARG GHC_VERSION
ARG TARGETPLATFORM
ARG DEBIAN_FRONTEND=noninteractive
RUN <<EOF
    apt-get update -y
    apt-get install -yqq \
        --no-install-recommends \
        binutils \
        build-essential \
        ca-certificates \
        curl \
        git \
        libbz2-dev \
        libclang-dev \
        libffi-dev \
        libgflags-dev \
        libgmp-dev \
        liblz4-dev \
        libmpfr-dev \
        libncurses-dev \
        libsnappy-dev \
        libssl-dev \
        libzstd-dev \
        neovim \
        pkg-config \
        zlib1g-dev
    if [ ${TARGETPLATFORM} = "linux/arm64" ] ; then
        echo plat: ${TARGETPLATFORM}
        apt-get install -yqq \
            --no-install-recommends \
            libnuma-dev
    fi
EOF

# Install Haskell toolchain
ENV CABAL_DIR=/root/.cabal
ENV PATH=/root/.local/bin:/root/.ghcup/bin:$PATH
ENV BOOTSTRAP_HASKELL_NONINTERACTIVE=1
ENV BOOTSTRAP_HASKELL_MINIMAL=1
ENV BOOTSTRAP_HASKELL_NO_UPGRADE=1
ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu/:$LD_LIBRARY_PATH
RUN --mount=type=cache,target=/root/.ghcup/cache,id=${TARGETPLATFORM} <<EOF
    curl -sSf https://get-ghcup.haskell.org | sh
    ghcup --cache install cabal latest
    ghcup set cabal latest
    ghcup --cache install ghc ${GHC_VERSION}
    ghcup set ghc ${GHC_VERSION}
    cabal --version
    ghc --version
EOF
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} <<EOF
    cabal update
EOF

# ############################################################################ #
# Builds
# ############################################################################ #

# ############################################################################ #
# Setup Context

FROM chainweb-build as chainweb-build-ctx
ARG TARGETPLATFORM
# RUN git clone --filter=tree:0 https://github.com/kadena-io/chainweb-node
# WORKDIR /chainweb/chainweb-node
COPY . .
ENV GIT_DISCOVERY_ACROSS_FILESYSTEM=1
RUN mkdir -p /tools
COPY --chmod=0755 <<EOF /tools/check-git-clean.sh
#!/bin/sh
if [ -d ".git" ] && ! [ -f "/tools/wip" ] && ! git diff --exit-code; then \
    echo "Git working tree is not clean. The build changed some file that is checked into git." 1>&2 ; \
    exit 1 ; \
fi
EOF
RUN sh /tools/check-git-clean.sh || touch /tools/wip

# ############################################################################ #
# Build Dependencies

FROM chainweb-build-ctx as chainweb-build-dependencies
ARG TARGETPLATFORM
ARG PROJECT_NAME
ENV GIT_DISCOVERY_ACROSS_FILESYSTEM=1
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked \
    [ -f cabal.project.freeze ] || cabal --enable-tests --enable-benchmarks freeze
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked \
    cabal build --enable-tests --enable-benchmarks --only-download
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked \
    cabal build --enable-tests --enable-benchmarks --only-dependencies

# ############################################################################ #
# Build Chainweb Library

FROM chainweb-build-dependencies AS chainweb-build-lib
ARG TARGETPLATFORM
ARG PROJECT_NAME
ENV GIT_DISCOVERY_ACROSS_FILESYSTEM=1
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked \
    cabal build --enable-tests --enable-benchmarks chainweb:lib:chainweb
RUN sh /tools/check-git-clean.sh

# ############################################################################ #
# Build Chainweb Tests

FROM chainweb-build-lib AS chainweb-build-tests
ARG TARGETPLATFORM
ARG PROJECT_NAME
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked \
    cabal build --enable-tests --enable-benchmarks chainweb:test:chainweb-tests
RUN sh /tools/check-git-clean.sh
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked <<EOF
    mkdir -p artifacts
    cp $(cabal list-bin --enable-tests --enable-benchmarks chainweb:test:chainweb-tests) artifacts/
EOF

# ############################################################################ #
# Build cwtools (ea) - fixed for dev branch (cwtools package, not chainweb:cwtool)

FROM chainweb-build-lib AS chainweb-build-cwtool
ARG TARGETPLATFORM
ARG PROJECT_NAME
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked \
    cabal build --enable-tests --enable-benchmarks cwtools:exe:ea
RUN sh /tools/check-git-clean.sh
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked \
    cabal run --enable-tests --enable-benchmarks cwtools:exe:ea
RUN <<EOF
    sh /tools/check-git-clean.sh ||
    { echo "Inconsistent genesis headers detected. Did you forget to run ea?" 1>&2 ; exit 1 ; }
EOF
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked <<EOF
    mkdir -p artifacts
    cp $(cabal list-bin --enable-tests --enable-benchmarks cwtools:exe:ea) artifacts/
EOF

# ############################################################################ #
# Build benchmarks

FROM chainweb-build-lib AS chainweb-build-bench
ARG TARGETPLATFORM
ARG PROJECT_NAME
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked \
    cabal build --enable-tests --enable-benchmarks chainweb:bench:bench
RUN sh /tools/check-git-clean.sh
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=chainweb-${TARGETPLATFORM},sharing=locked <<EOF
    mkdir -p artifacts
    cp $(cabal list-bin --enable-tests --enable-benchmarks chainweb:bench:bench) artifacts/
EOF

# ############################################################################ #
# Build Chainweb Node Application

FROM chainweb-build-lib AS chainweb-build-node
ARG TARGETPLATFORM
ARG PROJECT_NAME
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked \
    cabal build --enable-tests --enable-benchmarks chainweb-node:exe:chainweb-node
RUN sh /tools/check-git-clean.sh
RUN --mount=type=cache,target=/root/.cabal,id=${TARGETPLATFORM} \
    --mount=type=cache,target=./dist-newstyle,id=${PROJECT_NAME}-${TARGETPLATFORM},sharing=locked <<EOF
    mkdir -p artifacts
    cp $(cabal list-bin --enable-tests --enable-benchmarks chainweb-node:exe:chainweb-node) artifacts/
EOF

# ############################################################################ #
# Run Tests and Benchmarks
# ############################################################################ #

# ############################################################################ #
# Run Chainweb Tests

FROM chainweb-runtime AS chainweb-run-tests
COPY --from=chainweb-build-tests /chainweb/artifacts/chainweb-tests .
COPY --from=chainweb-build-tests /chainweb/test/pact test/pact
COPY --from=chainweb-build-tests /chainweb/pact pact
RUN <<EOF
    ulimit -n 10000
    ./chainweb-tests --hide-successes --results-json test-results.json -p '!/chainweb216Test/'
EOF

# ############################################################################ #
# Run slow tests (DISABLED - cwtool slow-tests doesn't exist in dev branch)

# FROM chainweb-runtime AS chainweb-run-slowtests
# COPY --from=chainweb-build-cwtool /chainweb/artifacts/ea .
# RUN <<EOF
#     ulimit -n 10000
#     ./ea slow-tests
# EOF

# ############################################################################ #
# Run benchmarks

FROM chainweb-runtime AS chainweb-run-bench
COPY --from=chainweb-build-bench /chainweb/artifacts/bench .
RUN <<EOF
    ulimit -n 10000
    ./bench
EOF

# ############################################################################ #
# Applications
# ############################################################################ #

# ############################################################################ #
# Chainweb-node Application

FROM chainweb-runtime AS chainweb-node
ENV PATH=/chainweb:$PATH
COPY --from=chainweb-build-node /chainweb/artifacts/chainweb-node .
COPY --from=chainweb-build-node /chainweb/LICENSE .
COPY --from=chainweb-build-node /chainweb/README.md .
COPY --from=chainweb-build-node /chainweb/CHANGELOG.md .
COPY --from=chainweb-build-node /chainweb/chainweb.cabal .
COPY --from=chainweb-build-node /chainweb/cabal.project .
COPY --from=chainweb-build-node /chainweb/cabal.project.freeze .
STOPSIGNAL SIGTERM
HEALTHCHECK CMD \
    [ $(ulimit -Sn) -gt 65535 ] \
    && exec 3<>/dev/tcp/localhost/1848 \
    && printf "GET /health-check HTTP/1.1\r\nhost: http://localhost:1848\r\nConnection: close\r\n\r\n" >&3 \
    && grep -q "200 OK" <&3 \
    || exit 1
ENTRYPOINT ["/chainweb/chainweb-node"]

# ############################################################################ #
# All binaries (for testing and debugging)

FROM chainweb-node AS chainweb-applications
COPY --from=chainweb-build-bench /chainweb/artifacts/bench .
COPY --from=chainweb-build-cwtool /chainweb/artifacts/ea .
COPY --from=chainweb-build-tests /chainweb/artifacts/chainweb-tests .
COPY --from=chainweb-build-tests /chainweb/test/pact test/pact
COPY --from=chainweb-build-tests /chainweb/pact pact

# ############################################################################ #
# Tested Chainweb-node Application

FROM chainweb-node AS chainweb-node-tested
# Phony dependencies on tests
COPY --from=chainweb-build-cwtool /etc/hostname /tmp/run-ea
COPY --from=chainweb-run-tests /etc/hostname /tmp/run-tests
# COPY --from=chainweb-run-slowtests /etc/hostname /tmp/run-slowtests  # DISABLED - doesn't exist in dev
COPY --from=chainweb-run-bench /etc/hostname /tmp/run-bench
RUN rm -f /tmp/run-tests /tmp/run-ea /tmp/run-bench

# ############################################################################ #
# (Optional) Initialize and Validate Database
# ############################################################################ #

# FROM CHAINWEB_BUILD AS CHAINWEB_INITIALIZE_DB
#
# TODO
# - Create image that only rocksdb database to volume, so that it can be
#   done during the build?
# - Just start the node on it?

# ############################################################################ #
# StoaChain Node — hub-driven container
# ############################################################################ #
#
# Extends `chainweb-node` (untested, fast build) with a shell entrypoint that
# translates environment variables into chainweb-node CLI flags. Designed for
# orchestration by the Stoa Hub, which sets env vars and issues `docker run`
# without needing to know the full chainweb-node --help surface.
#
# This is the DEFAULT target — because it's the last stage, a plain
# `docker build .` produces the hub-ready image. The full, tested node image
# is still available via `docker build --target chainweb-node-tested .`
# (kept upstream-compatible — no behavioural changes to earlier stages).
#
# Build:
#   docker build -t stoa-node:latest .
#
# Run (minimal):
#   docker run -d --name stoa-node \
#     -p 1789:1789 -p 1848:1848 \
#     -v stoa-data:/data \
#     -e P2P_HOSTNAME=node1.stoachain.com \
#     stoa-node:latest
#
# Run (mining):
#   docker run -d --name stoa-node \
#     -p 1789:1789 -p 1848:1848 \
#     -v stoa-data:/data \
#     -e P2P_HOSTNAME=node1.stoachain.com \
#     -e ENABLE_MINING=true \
#     -e MINING_PUBKEY=<hex-pubkey> \
#     stoa-node:latest
#
# Full env-var surface is documented at the top of docker/entrypoint.sh.

FROM chainweb-node AS stoa-node
COPY --chmod=0755 docker/entrypoint.sh /chainweb/entrypoint.sh

# `.dockerignore` excludes `.git` (it would add ~1 GB to every build context),
# so the revision that `chainweb-node --version` prints is an empty string.
# Carry provenance in OCI labels instead, supplied at build time:
#
#   docker build --target stoa-node -t stoa-node:v3.2.1-stoa.1 \
#     --build-arg STOA_VERSION=v3.2.1-stoa.1 \
#     --build-arg STOA_REVISION="$(git rev-parse HEAD)" .
#
# Operators verify a pulled image without starting it:
#
#   docker inspect --format \
#     '{{index .Config.Labels "org.opencontainers.image.revision"}}' <image>
#
# and verify the compiled consensus rules from a *running* node with
# `GET /info` -> `nodeLatestBehaviorHeight`, which is the highest fork height
# baked into the version table plus one (525001 for v3.2.1-stoa.1).
ARG STOA_VERSION=dev
ARG STOA_REVISION=unknown
LABEL org.opencontainers.image.title="StoaChain node"
LABEL org.opencontainers.image.description="chainweb-node built for the StoaChain (stoa) network"
LABEL org.opencontainers.image.source="https://github.com/StoaChain/stoa-chain"
LABEL org.opencontainers.image.licenses="BSD-3-Clause"
LABEL org.opencontainers.image.version="${STOA_VERSION}"
LABEL org.opencontainers.image.revision="${STOA_REVISION}"
VOLUME ["/data"]
EXPOSE 1789 1848
STOPSIGNAL SIGTERM

# Replace the HEALTHCHECK inherited from the `chainweb-node` stage, which can
# never pass in this image. Verified on 2026-08-24 against a fresh container
# from the *published* image, which sat `unhealthy` forever, for two reasons:
#
#  1. `HEALTHCHECK CMD <string>` is executed as `/bin/sh -c`, and `/bin/sh` is
#     dash here. `/dev/tcp/...` is a bash builtin, so dash answers
#     "cannot create /dev/tcp/localhost/1848: Directory nonexistent".
#  2. Its `[ $(ulimit -Sn) -gt 65535 ]` gate reads the *healthcheck exec's*
#     rlimits, which do not inherit from the container init process. Under
#     Docker 29 that exec gets soft nofile 1024 while PID 1 has 524288.
#
# The ulimit gate is also redundant: `checkRLimits` in `main`
# (node/src/Utils/CheckRLimits.hs) already exits at startup when the hard limit
# is below 32768, and raises the soft limit to the hard limit otherwise. A
# health check is the wrong place for a startup precondition.
#
# Production has been masking this with a docker-compose `healthcheck:`
# override, so a broken built-in went unnoticed. This makes the image correct
# on its own, and follows SERVICE_PORT rather than hard-coding 1848.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --retries=5 CMD \
    bash -c 'exec 3<>/dev/tcp/localhost/${SERVICE_PORT:-1848} && printf "GET /health-check HTTP/1.1\r\nhost: localhost\r\nConnection: close\r\n\r\n" >&3 && grep -q "200 OK" <&3'

ENTRYPOINT ["/chainweb/entrypoint.sh"]


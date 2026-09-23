FROM node:22-bookworm-slim

# The target repo and how to configure it come from targets/<name>.env via
# --build-arg; these defaults are the Core profile.
ARG TARGET_NAME=core
ARG REPO_URL=https://github.com/bitcoin/bitcoin.git
ARG REPO_REF=master
ARG CMAKE_FLAGS="-DBUILD_GUI=OFF -DWITH_ZMQ=OFF -DENABLE_IPC=OFF"
ARG APT_PACKAGES="libboost-dev libevent-dev libsqlite3-dev"
ARG TU_HEADER_UNITS=""
ARG BIPS_REPO=https://github.com/bitcoin/bips.git
ARG BIPS_REF=master
# Depth of the shallow clones. Bump it if you want the agent to inspect history.
ARG CLONE_DEPTH=1

LABEL org.mutant-harness.kind="core-mutant-gen"
# Bump when the image gains something a run now depends on; the harness rebuilds
# any older image rather than failing inside the container.
LABEL org.mutant-harness.version="4"
LABEL org.mutant-harness.target="${TARGET_NAME}"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        jq \
        ripgrep \
        less \
        python3 \
        procps \
    # A compiler and the target's build dependencies, so one translation unit
    # can be syntax-checked.
        build-essential \
        cmake \
        pkgconf \
        ${APT_PACKAGES} \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

# The target's source, baked into the image so a run needs no network for the
# repo. It lives at /src/bitcoin whatever the target is.
RUN git clone --depth "${CLONE_DEPTH}" --branch "${REPO_REF}" "${REPO_URL}" /src/bitcoin \
    && git -C /src/bitcoin log -1 --format='%H %cI %s' > /src/bitcoin-commit.txt

# The whole BIP repository. A mutant is only interesting where it breaks a rule
# somebody wrote down, so the agent reads the specs governing the target file
# before deciding where to cut.
RUN git clone --depth "${CLONE_DEPTH}" --branch "${BIPS_REF}" "${BIPS_REPO}" /src/bips \
    && git -C /src/bips log -1 --format='%H %cI %s' > /src/bips-commit.txt

# The container runs as the invoking host uid so bind-mounted output stays owned
# by the user. That uid is unknown at build time, so make the tree group-writable
# and world-writable where the agent (and `git apply`) needs to write.
#
# /src/bitcoin/build is where the verification phase builds. It is a mount point
# for a named volume, and Docker seeds a fresh volume with this directory's
# permissions - so it has to be world-writable here, or the first verify run
# cannot write to its own build dir.
RUN chmod -R a+rwX /src/bitcoin /src/bips \
    && mkdir -p /work /out /home/agent /src/bitcoin/build \
    && chmod -R a+rwX /work /out /home/agent /src/bitcoin/build

COPY tu-check /usr/local/bin/tu-check
# Configure the tree - configure only, no target is built. That is what writes
# compile_commands.json and the generated headers a single translation unit
# needs, in about a minute and a few MB rather than a full build. Non-fatal: if
# it fails, the run still works and the entrypoint says the check is off. The
# commit is recorded so the entrypoint can tell whether this build dir still
# describes the tree it is pointed at.
RUN chmod +x /usr/local/bin/tu-check; \
    if cmake -B /src/build -S /src/bitcoin \
             -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
             ${CMAKE_FLAGS}; then \
        git -C /src/bitcoin rev-parse HEAD > /src/build-commit.txt; \
        chmod -R a+rwX /src/build /src/build-commit.txt; \
    else \
        echo 'cmake configure failed; tu-check will be unavailable at run time' >&2; \
        rm -rf /src/build; \
    fi

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY verify-entrypoint.sh /usr/local/bin/verify-entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/verify-entrypoint.sh

ENV HOME=/home/agent \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    BITCOIN_SRC=/src/bitcoin \
    BITCOIN_BUILD=/src/build \
    BIPS_SRC=/src/bips \
    TARGET_NAME=${TARGET_NAME} \
    CMAKE_FLAGS="${CMAKE_FLAGS}" \
    TU_HEADER_UNITS="${TU_HEADER_UNITS}" \
    GIT_CONFIG_GLOBAL=/home/agent/.gitconfig

WORKDIR /src/bitcoin
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

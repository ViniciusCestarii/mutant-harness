FROM node:22-bookworm-slim

ARG BITCOIN_REPO=https://github.com/bitcoin/bitcoin.git
ARG BITCOIN_REF=master
ARG BIPS_REPO=https://github.com/bitcoin/bips.git
ARG BIPS_REF=master
# Depth of the shallow clones. Bump it if you want the agent to inspect history.
ARG CLONE_DEPTH=1

LABEL org.mutant-harness.kind="core-mutant-gen"
# Bump when the image gains something a run now depends on; the harness rebuilds
# any older image rather than failing inside the container.
LABEL org.mutant-harness.version="1"

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
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

# Bitcoin Core source, baked into the image so a run needs no network for the repo.
RUN git clone --depth "${CLONE_DEPTH}" --branch "${BITCOIN_REF}" "${BITCOIN_REPO}" /src/bitcoin \
    && git -C /src/bitcoin log -1 --format='%H %cI %s' > /src/bitcoin-commit.txt

# The whole BIP repository. A mutant is only interesting where it breaks a rule
# somebody wrote down, so the agent reads the specs governing the target file
# before deciding where to cut.
RUN git clone --depth "${CLONE_DEPTH}" --branch "${BIPS_REF}" "${BIPS_REPO}" /src/bips \
    && git -C /src/bips log -1 --format='%H %cI %s' > /src/bips-commit.txt

# The container runs as the invoking host uid so bind-mounted output stays owned
# by the user. That uid is unknown at build time, so make the tree group-writable
# and world-writable where the agent (and `git apply`) needs to write.
RUN chmod -R a+rwX /src/bitcoin /src/bips \
    && mkdir -p /work /out /home/agent \
    && chmod -R a+rwX /work /out /home/agent

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV HOME=/home/agent \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    BITCOIN_SRC=/src/bitcoin \
    BIPS_SRC=/src/bips \
    GIT_CONFIG_GLOBAL=/home/agent/.gitconfig

WORKDIR /src/bitcoin
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

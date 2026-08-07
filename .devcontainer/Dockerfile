FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG en_US.utf8
ARG USERNAME=vscode

RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    git \
    build-essential \
    gdb \
    lldb \
    strace \
    ltrace \
    bash-completion \
    nodejs \
    minisign && \
    apt-get autoremove -y && \
    apt-get clean autoclean && \
    rm -rf /var/lib/apt/lists/*

# UV
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
    && mkdir /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R $USERNAME /commandhistory \
    && echo "$SNIPPET" >> "/home/$USERNAME/.bashrc"

RUN echo 'source /usr/share/bash-completion/bash_completion' >> /home/vscode/.bashrc

# Official Zig release signing key (https://ziglang.org/download/).
ARG ZIG_MINISIGN_KEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG ZIG_VERSION=0.16.0
RUN ARCH=$(uname -m) && \
    URL="https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" && \
    curl -fL "$URL" -o /tmp/zig.tar.xz && \
    curl -fL "${URL}.minisig" -o /tmp/zig.tar.xz.minisig && \
    minisign -Vm /tmp/zig.tar.xz -P "$ZIG_MINISIGN_KEY" && \
    tar xf /tmp/zig.tar.xz -C /opt \
    && mv "/opt/zig-${ARCH}-linux-${ZIG_VERSION}" /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz /tmp/zig.tar.xz.minisig

RUN zig version

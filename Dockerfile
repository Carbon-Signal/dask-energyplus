# syntax=docker/dockerfile:1.7

ARG UBUNTU_VERSION=24.04
ARG PYTHON_VERSION=3.11
FROM --platform=$TARGETPLATFORM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1

# Base runtime (no 'expect' here—keep it out of the final layer)
RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl \
      python${PYTHON_VERSION} python${PYTHON_VERSION}-distutils python3-pip \
      libgomp1 libx11-6 && \
    rm -rf /var/lib/apt/lists/*

# Run the EnergyPlus installer with a bind-mount + Dockerfile heredoc
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=bind,source=energyplus-installer.sh,target=/tmp/energyplus-installer.sh \
<<'BASH'
set -euxo pipefail
apt-get update
apt-get install -y --no-install-recommends expect
chmod +x /tmp/energyplus-installer.sh
cat > /tmp/install.exp <<'EOF'
set timeout -1
spawn /tmp/energyplus-installer.sh
expect -re {Do you accept the license.*:}
send "y\r"
expect -re {EnergyPlus install directory.*:}
send "\r"
expect -re {Symbolic link location.*:}
send "\r"
expect eof
EOF
expect /tmp/install.exp
apt-get purge -y --auto-remove expect
rm -f /tmp/install.exp
rm -rf /var/lib/apt/lists/*
BASH

# Dask on the chosen Python
RUN python${PYTHON_VERSION} -m pip install --upgrade pip && \
    python${PYTHON_VERSION} -m pip install "dask[distributed]"

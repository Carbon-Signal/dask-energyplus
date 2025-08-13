# syntax=docker/dockerfile:1.7
# Lean, multi-arch, Python via uv, installer mounted (not copied)

ARG UBUNTU_VERSION=24.04
ARG PYTHON_VERSION=3.11
FROM --platform=$TARGETPLATFORM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1

# Base runtime: only what we actually need
RUN --mount=type=cache,target=/var/cache/apt \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl \
      libgomp1 libx11-6; \
    rm -rf /var/lib/apt/lists/*

# Install the uv toolchain manager, then install CPython ${PYTHON_VERSION}
# and make it the system default (python, python3, python${PYTHON_VERSION})
RUN set -eux; \
    curl -fsSL https://astral.sh/uv/install.sh | sh -s -- -y; \
    ln -sf /root/.local/bin/uv /usr/local/bin/uv; \
    uv python install ${PYTHON_VERSION}; \
    PYBIN="$(uv python find ${PYTHON_VERSION})"; \
    ln -sf "$PYBIN" /usr/local/bin/python${PYTHON_VERSION}; \
    ln -sf "$PYBIN" /usr/local/bin/python3; \
    ln -sf "$PYBIN" /usr/local/bin/python; \
    "$PYBIN" -VV

# Run the EnergyPlus .sh installer with BuildKit bind-mount + Dockerfile heredoc
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

# Install Dask into the uv-provisioned Python (no system python needed)
RUN set -eux; \
    PYBIN="$(uv python find ${PYTHON_VERSION})"; \
    "$PYBIN" -m ensurepip --upgrade; \
    "$PYBIN" -m pip install --upgrade pip; \
    "$PYBIN" -m pip install "dask[distributed]"

# Optional: non-root user
RUN useradd -ms /bin/bash app && chown -R app:app /usr/local
USER app
WORKDIR /home/app

# Default command
CMD ["python", "-c", "import sys, dask, distributed; print('Python:', sys.version)"]

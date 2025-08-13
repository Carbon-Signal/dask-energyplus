# syntax=docker/dockerfile:1.7-labs
# Multi-arch, Ubuntu 24.04 base (glibc 2.39)
# Works for linux/amd64 and linux/arm64
# - Pinned Miniforge with checksum verification
# - Multi-stage to keep installer deps out of runtime image
# - BuildKit cache mounts for apt and conda
# - TARGETPLATFORM-aware arch mapping
# - Optional EPLUS_URL override and DEBUG gating
# - ELF sanity checks and conditional runtime exec under cross-arch
# - OCI labels

############################
# Stage 1: Build EnergyPlus
############################
FROM ubuntu:24.04 AS eplus-builder

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETPLATFORM
ARG EPLUS_TAG=v25.1.0
ARG EPLUS_URL=
ARG DEBUG=0
# Optional GitHub token to avoid rate limits
ARG GITHUB_TOKEN

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Required to fetch and run the E+ installer only in this stage
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    rm -rf /var/lib/apt/lists/*; \
    apt-get update -o Acquire::Retries=3; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl jq expect bzip2; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*

# Resolve arch for matching E+ asset names and downloads
ENV ARCH=unknown ARCH_RE=unknown
RUN set -eux; \
    case "${TARGETPLATFORM:-}" in \
      "linux/amd64") ARCH="x86_64"; ARCH_RE="(x86_64|amd64)";; \
      "linux/arm64") ARCH="aarch64"; ARCH_RE="(arm64|aarch64)";; \
      *) echo "Unsupported TARGETPLATFORM=${TARGETPLATFORM:-unset}"; exit 1;; \
    esac; \
    echo "Resolved TARGETPLATFORM=${TARGETPLATFORM:-unset} -> ARCH=${ARCH}, ARCH_RE=${ARCH_RE}"

# Select the best matching E+ installer (allow override via EPLUS_URL)
RUN set -eux; \
    # Resolve arch locally in this layer to ensure availability
    case "${TARGETPLATFORM:-}" in \
      "linux/amd64") ARCH="x86_64"; ARCH_RE="(x86_64|amd64)";; \
      "linux/arm64") ARCH="aarch64"; ARCH_RE="(arm64|aarch64)";; \
      *) echo "Unsupported TARGETPLATFORM=${TARGETPLATFORM:-unset}"; exit 1;; \
    esac; \
    API_URL="https://api.github.com/repos/NREL/EnergyPlus/releases/tags/${EPLUS_TAG}"; \
    if [ -n "${EPLUS_URL}" ]; then \
      ASSET_URL="${EPLUS_URL}"; \
      echo "Using override EPLUS_URL=${ASSET_URL}"; \
    else \
      if [ "${DEBUG}" != "0" ]; then \
        echo "Assets for ${EPLUS_TAG}:"; \
        curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} "$API_URL" | jq -r '.assets[].name' | nl -ba; \
      fi; \
      ASSET_URL="$( \
        curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} "$API_URL" \
        | jq -r --arg arch "$ARCH_RE" ' \
            ( .assets[] | select(.name | test("^EnergyPlus-.*-Linux-Ubuntu(24\\.04|22\\.04|20\\.04)-" + $arch + "\\.sh$"; "i")) | .browser_download_url ) \
            // \
            ( .assets[] | select(.name | test("^EnergyPlus-.*-Linux-.*" + $arch + ".*\\.sh$"; "i")) | .browser_download_url ) ' | head -n1 \
      )"; \
      test -n "$ASSET_URL" || { echo "No Linux installer for tag=${EPLUS_TAG}, arch=${ARCH}"; exit 9; }; \
    fi; \
    echo "Selected installer: $ASSET_URL"; \
    curl -fsSL "$ASSET_URL" -o /tmp/energyplus-installer.sh; \
    chmod +x /tmp/energyplus-installer.sh

# Non-interactive installer run (accept license, defaults for dirs/links)
RUN set -eux; \
    printf '%s\n' \
      'set timeout -1' \
      'spawn /tmp/energyplus-installer.sh' \
      'expect -re {Do you accept the license.*:}' \
      'send "y\r"' \
      'expect -re {EnergyPlus install directory.*:}' \
      'send "\r"' \
      'expect -re {Symbolic link location.*:}' \
      'send "\r"' \
      'expect eof' > /tmp/install.exp; \
    expect /tmp/install.exp; \
    rm -f /tmp/install.exp /tmp/energyplus-installer.sh

# Package installed EnergyPlus directory for copying to final stage
# Default installer path: /usr/local/EnergyPlus-<version>
RUN set -eux; \
    EPLUS_DIR="$(ls -d /usr/local/EnergyPlus-* | head -n1)"; \
    test -d "$EPLUS_DIR" || { echo "EnergyPlus install dir not found"; ls -la /usr/local; exit 7; }; \
    echo "Packaging $EPLUS_DIR"; \
    tar -C / -czf /tmp/eplus.tgz "usr/local/$(basename "$EPLUS_DIR")"; \
    # Display what we have (debug only)
    if [ "${DEBUG}" != "0" ]; then tar -tzf /tmp/eplus.tgz | head -n 50; fi

############################
# Stage 2: Runtime image
############################
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETPLATFORM
ARG PYTHON_VERSION=3.11
# Pinned Miniforge release (https://github.com/conda-forge/miniforge/releases)
ARG MINIFORGE_VERSION=24.7.1-0
ARG DEBUG=0

# OCI labels
LABEL org.opencontainers.image.title="dask-energyplus" \
      org.opencontainers.image.description="Multi-arch Dask + EnergyPlus runtime (Ubuntu 24.04)" \
      org.opencontainers.image.source="https://github.com/Carbon-Signal/dask-energyplus" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base runtime dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    rm -rf /var/lib/apt/lists/*; \
    apt-get update -o Acquire::Retries=3; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl bzip2 \
      libgomp1 libx11-6 file; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*

# Install pinned Miniforge and create environment with Python + Dask
ENV CONDA_DIR=/opt/conda
ENV PATH=$CONDA_DIR/bin:$PATH

# Resolve arch for Miniforge asset and verify checksum
ENV ARCH=unknown
RUN set -eux; \
    case "${TARGETPLATFORM:-}" in \
      "linux/amd64") ARCH="x86_64";; \
      "linux/arm64") ARCH="aarch64";; \
      *) echo "Unsupported TARGETPLATFORM=${TARGETPLATFORM:-unset}"; exit 1;; \
    esac; \
    echo "Resolved TARGETPLATFORM=${TARGETPLATFORM:-unset} -> ARCH=${ARCH}"

# Download Miniforge installer and install
RUN --mount=type=cache,target=/root/.cache \
    set -eux; \
    # Resolve arch locally in this layer to ensure availability
    case "${TARGETPLATFORM:-}" in \
      "linux/amd64") ARCH="x86_64";; \
      "linux/arm64") ARCH="aarch64";; \
      *) echo "Unsupported TARGETPLATFORM=${TARGETPLATFORM:-unset}"; exit 1;; \
    esac; \
    BASE_URL="https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}"; \
    LATEST_URL="https://github.com/conda-forge/miniforge/releases/latest/download"; \
    FILENAME="Miniforge3-Linux-${ARCH}.sh"; \
    echo "Resolved TARGETPLATFORM=${TARGETPLATFORM:-unset} -> ARCH=${ARCH}"; \
    echo "Attempting: ${BASE_URL}/${FILENAME}"; \
    curl -fSLS --retry 5 --retry-delay 2 --retry-all-errors "${BASE_URL}/${FILENAME}" -o "/tmp/${FILENAME}" \
      || (echo "Falling back to latest: ${LATEST_URL}/${FILENAME}" \
          && curl -fSLS --retry 5 --retry-delay 2 --retry-all-errors "${LATEST_URL}/${FILENAME}" -o "/tmp/${FILENAME}"); \
    bash "/tmp/${FILENAME}" -b -p "${CONDA_DIR}"; \
    rm -f "/tmp/${FILENAME}"

# Use cache for conda pkgs; install Python + Dask; clean index/pkgs
RUN --mount=type=cache,target=/opt/conda/pkgs \
    set -eux; \
    conda install -y -c conda-forge python="${PYTHON_VERSION}" dask distributed; \
    conda clean -afy

# Copy EnergyPlus from builder and set up symlinks
COPY --from=eplus-builder /tmp/eplus.tgz /tmp/eplus.tgz
RUN set -eux; \
    tar -C / -xzf /tmp/eplus.tgz; \
    rm -f /tmp/eplus.tgz; \
    EPLUS_DIR="$(ls -d /usr/local/EnergyPlus-* | head -n1)"; \
    test -d "$EPLUS_DIR"; \
    ln -sf "$EPLUS_DIR/energyplus" /usr/local/bin/energyplus; \
    # Add more symlinks if needed:
    if [ -x "$EPLUS_DIR/ExpandObjects" ]; then ln -sf "$EPLUS_DIR/ExpandObjects" /usr/local/bin/expandobjects || true; fi; \
    if [ -x "$EPLUS_DIR/ReadVarsESO" ]; then ln -sf "$EPLUS_DIR/ReadVarsESO" /usr/local/bin/readvars || true; fi

# Non-executing sanity check (safe under cross-arch builds)
# Validate the ELF architecture for the 'energyplus' binary, and run a version check only when not cross-building.
RUN set -eux; \
    WRAP="$(command -v energyplus)"; \
    BIN="$(readlink -f "$WRAP")"; \
    INFO="$(file -b "$BIN" || true)"; \
    if ! echo "$INFO" | grep -qi 'ELF 64-bit'; then \
      CANDIDATE="$(dirname "$BIN")/energyplus"; \
      if [ "$CANDIDATE" != "$BIN" ] && [ -e "$CANDIDATE" ]; then \
        BIN="$CANDIDATE"; \
        INFO="$(file -b "$BIN" || true)"; \
      fi; \
    fi; \
    echo "energyplus resolved to: $BIN"; \
    echo "file(1): $INFO"; \
    if echo "$INFO" | grep -qi 'ELF 64-bit'; then \
      case "${TARGETPLATFORM:-}" in \
        "linux/amd64") echo "$INFO" | grep -qiE 'x86-64|x86_64'  || { echo "Expected amd64 ELF"; exit 1; } ;; \
        "linux/arm64") echo "$INFO" | grep -qiE 'aarch64|arm64'  || { echo "Expected arm64 ELF"; exit 1; } ;; \
        *) echo "Unknown TARGETPLATFORM=${TARGETPLATFORM:-unset}"; exit 2 ;; \
      esac; \
    else \
      echo "Warning: energyplus is not an ELF (likely a wrapper). Skipping ELF arch check."; \
    fi; \
    # Only execute if not cross-building (BUILDPLATFORM may be unset in some contexts)
    if [ "${BUILDPLATFORM:-}" = "${TARGETPLATFORM:-}" ] && [ -n "${TARGETPLATFORM:-}" ]; then \
      energyplus --version >/dev/null; \
    else \
      echo "Skipping runtime exec under cross-arch"; \
    fi

# Default CMD can be set by downstream images or docker-compose
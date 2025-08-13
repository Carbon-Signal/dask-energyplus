# Multi-arch, Ubuntu 24.04 base (glibc 2.39)
# Works for both linux/amd64 and linux/arm64

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ARG EPLUS_TAG=v25.1.0

# Base deps + Miniforge (for Python + Dask) + runtime libs for E+
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl bzip2 jq expect \
      libgomp1 libx11-6 file; \
    rm -rf /var/lib/apt/lists/*

# Install Miniforge and Dask (you can pin versions as needed)
ENV CONDA_DIR=/opt/conda
ENV PATH=$CONDA_DIR/bin:$PATH
RUN set -eux; \
    ARCH="$(case "$TARGETARCH" in amd64) echo x86_64 ;; arm64) echo aarch64 ;; *) echo "bad arch"; exit 1;; esac)"; \
    curl -fsSL "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${ARCH}.sh" -o /tmp/mf.sh; \
    bash /tmp/mf.sh -b -p "$CONDA_DIR"; rm -f /tmp/mf.sh; \
    conda install -y -c conda-forge python=3.11 dask distributed && conda clean -afy

# Resolve correct Linux installer for this arch (Ubuntu-first)
RUN set -eux; \
    ARCH_RE="$(case "$TARGETARCH" in amd64) echo '(x86_64|amd64)' ;; arm64) echo '(arm64|aarch64)' ;; *) exit 1 ;; esac)"; \
    API_URL="https://api.github.com/repos/NREL/EnergyPlus/releases/tags/${EPLUS_TAG}"; \
    echo "Assets for ${EPLUS_TAG}:"; \
    curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} "$API_URL" | jq -r '.assets[].name' | nl -ba; \
    ASSET_URL="$( \
      curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} "$API_URL" \
      | jq -r --arg arch "$ARCH_RE" ' \
          ( .assets[] | select(.name | test("^EnergyPlus-.*-Linux-Ubuntu(24\\.04|22\\.04|20\\.04)-" + $arch + "\\.sh$"; "i")) | .browser_download_url ) // ( .assets[] | select(.name | test("^EnergyPlus-.*-Linux-.*" + $arch + ".*\\.sh$"; "i")) | .browser_download_url ) ' | head -n1 \
    )"; \
    test -n "$ASSET_URL" || { echo "No Linux installer for tag=${EPLUS_TAG}, arch=${TARGETARCH}"; exit 9; }; \
    echo "Selected installer: $ASSET_URL"; \
    curl -fsSL "$ASSET_URL" -o /tmp/energyplus-installer.sh; \
    chmod +x /tmp/energyplus-installer.sh; \
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
    rm -f /tmp/install.exp /tmp/energyplus-installer.sh; \
    apt-get purge -y --auto-remove jq expect || true; \
    rm -rf /var/lib/apt/lists/*

# Non-executing sanity check (safe under cross-arch builds)
# --- Robust, arch-aware sanity check (no execution under cross-arch) ---
ARG TARGETARCH
ARG BUILDPLATFORM
ARG TARGETPLATFORM
RUN set -eux; \
    # Resolve to a real file (follow symlinks)
    WRAP="$(command -v energyplus)"; \
    BIN="$(readlink -f "$WRAP")"; \
    # If this isn't an ELF (some packages ship a wrapper), try the sibling 'energyplus' in the install dir
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
    # Only enforce arch check if we really found an ELF; otherwise just warn
    if echo "$INFO" | grep -qi 'ELF 64-bit'; then \
      case "$TARGETARCH" in \
        amd64)  echo "$INFO" | grep -qiE 'x86-64|x86_64'  || { echo "Expected amd64 ELF"; exit 1; } ;; \
        arm64)  echo "$INFO" | grep -qiE 'aarch64|arm64'  || { echo "Expected arm64 ELF"; exit 1; } ;; \
        *)      echo "Unknown TARGETARCH=$TARGETARCH"; exit 2 ;; \
      esac; \
    else \
      echo "Warning: energyplus is not an ELF (likely a wrapper). Skipping ELF arch check."; \
    fi; \
    # Only execute the binary if build and target match
    if [ "${BUILDPLATFORM:-}" = "${TARGETPLATFORM:-}" ]; then \
      energyplus --version >/dev/null; \
    else \
      echo "Skipping runtime exec under cross-arch"; \
    fi

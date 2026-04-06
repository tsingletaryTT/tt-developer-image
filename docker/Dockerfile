# Tenstorrent N150 Developer Image (Ubuntu 24.04)
#
# Goals:
# - Future-proof OS (24.04) with a pinned, battle-tested TT stack.
# - Full source builds of tt-metal, plus vLLM + Forge/XLA stacks.
# - Heavy comments so DX teams can tweak confidently.

FROM ubuntu:24.04

# Set noninteractive to avoid tzdata & friends prompting
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. Base OS + system dependencies
# ---------------------------------------------------------------------------

# We:
# - Refresh apt
# - Install fundamental build tools, Python, Clang, CMake, etc.
# - Include extra libs required by tt-metal, tt-mlir, tt-forge-onnx, tt-xla, vLLM

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    bash ca-certificates curl wget git sudo apt-transport-https gnupg lsb-release \
    # Build tools
    build-essential ninja-build cmake pkg-config \
    # Python 3.10 & 3.11 + venv (we avoid 3.12 for TT stack to stay in known-good territory)
    python3.10 python3.10-venv python3.10-dev \
    python3.11 python3.11-venv python3.11-dev \
    python3-pip \
    # Compilers
    clang-17 clang++-17 \
    # Common libs for tt-mlir / tt-forge-onnx / tt-xla
    protobuf-compiler libprotobuf-dev \
    libnuma-dev libhwloc-dev libboost-all-dev libnsl-dev \
    # For performance / CPU governor commands (parity with docs)
    cpufrequtils linux-tools-common linux-tools-generic \
    # Networking / misc
    iproute2 iputils-ping \
    # For Rust / uv installation (curl + SSL etc are already present)
    # Nothing extra, but keep comment for clarity
    # Clean up
 && rm -rf /var/lib/apt/lists/*

# Symlink clang-17 as default clang/clang++ for build scripts that use 'clang'
RUN ln -sf /usr/bin/clang-17 /usr/local/bin/clang && \
    ln -sf /usr/bin/clang++-17 /usr/local/bin/clang++

# ---------------------------------------------------------------------------
# 2. Create a 'developer' user (avoid running as root)
# ---------------------------------------------------------------------------

ARG DEV_USER=dev
ARG DEV_UID=1000
ARG DEV_GID=1000

RUN groupadd -g ${DEV_GID} ${DEV_USER} && \
    useradd -m -u ${DEV_UID} -g ${DEV_GID} -s /bin/bash ${DEV_USER} && \
    usermod -aG sudo ${DEV_USER} && \
    echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${DEV_USER}

USER ${DEV_USER}
WORKDIR /home/${DEV_USER}

# Ensure local bin is in PATH for pip/uv/rust/cargo installs
ENV PATH="/home/${DEV_USER}/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# 3. Optional: Install uv (Python toolchain manager) and Rust
# ---------------------------------------------------------------------------
# We don't strictly require them, but they are nice to have and some
# tooling (tt-mlir scripts, some dev flows) may rely on modern Rust.

# Install uv (astral) – safe to skip if you prefer plain pip
RUN curl -fsSL https://astral.sh/uv/install.sh | bash && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# Install Rust via rustup (for crates like maturin, pyluwen, etc.)
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y && \
    echo 'source "$HOME/.cargo/env"' >> ~/.bashrc

ENV PATH="/home/${DEV_USER}/.cargo/bin:${PATH}"

# ---------------------------------------------------------------------------
# 4. Python virtualenvs layout
# ---------------------------------------------------------------------------
# We create three venvs:
#   /opt/venv-metal  - tt-metal, TTNN, basic tools (Python 3.10)
#   /opt/venv-vllm   - vLLM + torch 2.5.0+cpu (Python 3.10)
#   /opt/venv-forge  - TT-Forge + TT-Forge-ONNX + TT-XLA (0.8.0, Python 3.11)

RUN python3.10 -m venv /opt/venv-metal && \
    python3.10 -m venv /opt/venv-vllm && \
    python3.11 -m venv /opt/venv-forge

# Upgrade pip in each venv
RUN /opt/venv-metal/bin/pip install --upgrade pip && \
    /opt/venv-vllm/bin/pip install --upgrade pip && \
    /opt/venv-forge/bin/pip install --upgrade pip

# ---------------------------------------------------------------------------
# 5. Clone tt-metal at pinned commit and build from source
# ---------------------------------------------------------------------------

# Pin to the tt-metal commit that matches a known-good vLLM stack (e.g. 555f240…).
# Adjust as needed if you want a different known-good combo.
ARG TT_METAL_REPO=https://github.com/tenstorrent/tt-metal.git
ARG TT_METAL_COMMIT=555f240b7dbfadd6634e958faedb516bfaf6f9c4

RUN git clone --recurse-submodules ${TT_METAL_REPO} /home/${DEV_USER}/tt-metal && \
    cd /home/${DEV_USER}/tt-metal && \
    git checkout ${TT_METAL_COMMIT} && \
    git submodule update --init --recursive

ENV TT_METAL_HOME=/home/${DEV_USER}/tt-metal

# Install tt-metal system dependencies (equivalent of install_dependencies.sh).
# NOTE: we run this inside the container for a "fat dev" image –
# it may overlap with earlier apt installs but keeps parity with docs.
RUN cd ${TT_METAL_HOME} && \
    sudo ./install_dependencies.sh || true

# Build tt-metal with full examples; this can be slow but is what you asked for.
# We:
#   - Build the C++ library and firmware
#   - Create Python venv bindings in /opt/venv-metal
#   - Install tt-metal into that venv (editable mode)
COPY scripts/build_tt_metal.sh /tmp/build_tt_metal.sh
RUN chmod +x /tmp/build_tt_metal.sh && \
    /tmp/build_tt_metal.sh

# ---------------------------------------------------------------------------
# 6. vLLM env: Tenstorrent fork, pinned torch 2.5.0+cpu
# ---------------------------------------------------------------------------

# Pin vLLM repo & commit to align with tt-inference-server 0.10.0 dev image.
# Replace VLLM_COMMIT if you have the exact hash from that release.
ARG VLLM_REPO=https://github.com/tenstorrent/vllm.git
ARG VLLM_BRANCH=dev
ARG VLLM_COMMIT=22be241 # placeholder; set to actual matching commit

RUN git clone ${VLLM_REPO} /home/${DEV_USER}/tt-vllm && \
    cd /home/${DEV_USER}/tt-vllm && \
    git checkout ${VLLM_BRANCH} && \
    ( [ "${VLLM_COMMIT}" = "22be241" ] || git checkout ${VLLM_COMMIT} || true )

# Install vLLM dependencies in /opt/venv-vllm:
#   - PyTorch 2.5.0+cpu
#   - other core deps (fairscale, termcolor, loguru, blobfile, fire, pytz, etc.)
COPY scripts/setup_envs.sh /tmp/setup_envs.sh
RUN chmod +x /tmp/setup_envs.sh && \
    /tmp/setup_envs.sh vllm

# ---------------------------------------------------------------------------
# 7. Forge / TT-Forge-ONNX / TT-XLA env (0.8.0)
# ---------------------------------------------------------------------------

# Install TT-Forge, TT-Forge-ONNX, TT-XLA 0.8.0 into /opt/venv-forge
RUN /tmp/setup_envs.sh forge

# ---------------------------------------------------------------------------
# 8. Environment wrapper scripts (for DX convenience)
# ---------------------------------------------------------------------------

# These small scripts make it easy to switch envs:
#   source /etc/profile.d/tt-env-metal.sh
#   source /etc/profile.d/tt-env-vllm.sh
#   source /etc/profile.d/tt-env-forge.sh

RUN echo 'unset TT_METAL_HOME TT_METAL_VERSION' >> /etc/profile && \
    printf '%s\n' \
      '#!/bin/bash' \
      'export TT_METAL_HOME=/home/'"${DEV_USER}"'/tt-metal' \
      'export PYTHONPATH=$TT_METAL_HOME:$PYTHONPATH' \
      'export LD_LIBRARY_PATH=/home/'"${DEV_USER}"'/tt-metal/build/lib:$LD_LIBRARY_PATH' \
      'source /opt/venv-metal/bin/activate' \
    | sudo tee /etc/profile.d/tt-env-metal.sh > /dev/null && \
    sudo chmod +x /etc/profile.d/tt-env-metal.sh && \
    printf '%s\n' \
      '#!/bin/bash' \
      'unset TT_METAL_VERSION' \
      'export TT_METAL_HOME=/home/'"${DEV_USER}"'/tt-metal' \
      'source /opt/venv-vllm/bin/activate' \
    | sudo tee /etc/profile.d/tt-env-vllm.sh > /dev/null && \
    sudo chmod +x /etc/profile.d/tt-env-vllm.sh && \
    printf '%s\n' \
      '#!/bin/bash' \
      'unset TT_METAL_VERSION' \
      'export TT_METAL_HOME=/home/'"${DEV_USER}"'/tt-metal' \
      'source /opt/venv-forge/bin/activate' \
    | sudo tee /etc/profile.d/tt-env-forge.sh > /dev/null && \
    sudo chmod +x /etc/profile.d/tt-env-forge.sh

# ---------------------------------------------------------------------------
# 9. code-server + tt-vscode-toolkit
# ---------------------------------------------------------------------------
# Mirrors the approach used in other Tenstorrent images (tt-vscode-toolkit,
# tt-code-server).  Gives developers a browser-based VS Code at port 8080
# pre-loaded with the TT extension.

# Install code-server using the official install script.
# No version pin here – consistent with other TT images.  If you need
# reproducibility, export VERSION=4.x.y before the curl or hard-code it:
#   RUN VERSION=4.x.y curl -fsSL https://code-server.dev/install.sh | sh
RUN sudo curl -fsSL https://code-server.dev/install.sh | sudo sh

# Fetch the latest tt-vscode-toolkit .vsix from GitHub Releases and install it.
# The GitHub API resolves the latest release so this tracks upstream automatically.
# To pin, replace the inner $(curl …) with a hard-coded release URL, e.g.:
#   https://github.com/tenstorrent/tt-vscode-toolkit/releases/download/v0.0.313/tt-vscode-toolkit-0.0.313.vsix
RUN curl -fsSL -o /tmp/tt-vscode-toolkit.vsix \
      "$(curl -fsSL https://api.github.com/repos/tenstorrent/tt-vscode-toolkit/releases/latest \
         | grep 'browser_download_url.*\.vsix"' \
         | cut -d '"' -f 4)" && \
    code-server --install-extension /tmp/tt-vscode-toolkit.vsix && \
    rm /tmp/tt-vscode-toolkit.vsix

# Verify the extension landed where expected
RUN ls /home/${DEV_USER}/.local/share/code-server/extensions/ \
    | grep -q "tenstorrent.tt-vscode-toolkit" \
    || (echo "ERROR: tt-vscode-toolkit extension not found" && exit 1)

# Write default user settings: Tenstorrent Dark theme, telemetry off,
# bash as the integrated terminal (with login shell so profile scripts work).
RUN mkdir -p /home/${DEV_USER}/.local/share/code-server/User && \
    printf '{\n  "workbench.colorTheme": "Tenstorrent Dark",\n  "workbench.tips.enabled": false,\n  "telemetry.telemetryLevel": "off",\n  "update.mode": "none",\n  "terminal.integrated.defaultProfile.linux": "bash",\n  "terminal.integrated.profiles.linux": {\n    "bash": {\n      "path": "bash",\n      "args": ["-l"],\n      "icon": "terminal-bash"\n    }\n  }\n}\n' \
    > /home/${DEV_USER}/.local/share/code-server/User/settings.json

# Default password – always override with -e PASSWORD=… at runtime.
ENV PASSWORD=tenstorrent

# code-server web UI port
EXPOSE 8080

# ---------------------------------------------------------------------------
# 10. Final touches
# ---------------------------------------------------------------------------

WORKDIR /home/${DEV_USER}
ENV DEBIAN_FRONTEND=dialog

# Default shell: no envs activated (must opt-in with profile scripts).
# To start code-server instead:
#   docker run -p 8080:8080 -e PASSWORD=... <image> \
#     code-server --bind-addr 0.0.0.0:8080 --auth password \
#                 --disable-telemetry --disable-update-check
CMD ["/bin/bash"]

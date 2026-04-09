# Tenstorrent N150 Developer Image (Ubuntu 24.04)
#
# Goals:
# - Future-proof OS (24.04) with a pinned, battle-tested TT stack.
# - Flexible tt-metal handling: fast checkout-only builds for CI/iteration,
#   full source compilation for production images that run on real hardware.
# - Heavy comments so DX teams can tweak confidently.
#
# tt-metal build modes (TT_METAL_BUILD build arg):
#
#   checkout  (DEFAULT)
#     git clone only — no compilation.  Suitable for CI, iterating on venv
#     layers, or shipping a source-present image where you'll build at runtime.
#     Build time: minutes.
#       docker build -t tenstorrent/dev-n150:checkout .
#
#   full
#     clone + install_dependencies.sh + complete C++ build + pip install.
#     Required to actually dispatch ops to the N150.  Suitable for production
#     images.  Build time: 30–90 min.
#       docker build --build-arg TT_METAL_BUILD=full -t tenstorrent/dev-n150:latest .
#
# Note: vLLM pip install (setup_envs.sh vllm) is skipped in checkout mode
# because the Tenstorrent vLLM fork depends on compiled tt-metal Python
# bindings.  In checkout mode a note is printed; run /tmp/setup_envs.sh vllm
# inside the container after you've built tt-metal.
#
# Multi-stage build note:
#   The tt-xla-slim stage provides pre-compiled PJRT plugin packages
#   (pjrt_plugin_tt, jax_plugin_tt, tt_jax, ttxla_tools) built against
#   JAX 0.7.1 and the TT-MLIR toolchain.  We COPY only the TT-specific
#   packages into venv-forge; this avoids a ~30-min TT-MLIR source build.

# ---------------------------------------------------------------------------
# Stage 0: tt-xla-slim source
#   Pull the Tenstorrent XLA slim image so we can COPY its pre-built
#   PJRT plugin packages into venv-forge in section 7.
#   This stage adds zero bytes to the final image — only COPY --from lines do.
# ---------------------------------------------------------------------------
FROM ghcr.io/tenstorrent/tt-xla-slim:latest AS tt-xla-slim

# ---------------------------------------------------------------------------
# Stage 1: main developer image
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

# Set noninteractive to avoid tzdata & friends prompting
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. Base OS + system dependencies
# ---------------------------------------------------------------------------

# Ubuntu 24.04 (Noble) only ships Python 3.12 in its default repos.
# The TT stack (tt-metal, vLLM) requires Python 3.10, so we add the
# deadsnakes PPA first.  This is a stable, well-known PPA maintained by the
# Python core team for older CPython builds on Ubuntu.
# Note: Python 3.12 (needed for venv-forge) is the Ubuntu 24.04 default and
# does NOT require deadsnakes.
# Splitting this into its own RUN layer means the PPA add is cached
# independently from the package list below — useful when tweaking packages.
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common \
 && add-apt-repository -y ppa:deadsnakes/ppa \
 && rm -rf /var/lib/apt/lists/*

# Main system dependencies.
# We:
# - Install fundamental build tools, Python 3.10 (deadsnakes), Python 3.12
#   (Ubuntu 24.04 default), Clang, CMake, etc.
# - Include extra libs required by tt-metal, tt-mlir, tt-forge-onnx, tt-xla, vLLM
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    bash ca-certificates curl wget git sudo apt-transport-https gnupg lsb-release \
    # Build tools
    build-essential ninja-build cmake pkg-config \
    # Python 3.10 + venv (from deadsnakes PPA): needed for venv-metal and venv-vllm.
    # We avoid 3.12 for the tt-metal/vLLM stack to stay in known-good territory.
    python3.10 python3.10-venv python3.10-dev \
    # Python 3.12 venv/dev support (Ubuntu 24.04 native — no deadsnakes needed).
    # Used for venv-forge: tt-forge-onnx wheels ship cp312-only.
    python3.12-venv python3.12-dev \
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

# Ubuntu 24.04 base images ship a pre-created 'ubuntu' user at UID/GID 1000.
# Remove it before creating our own dev user so groupadd -g 1000 doesn't
# fail with "GID not unique" (exit code 4).  The || true guards against older
# base images that don't have the ubuntu user.
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true && \
    groupadd -g ${DEV_GID} ${DEV_USER} && \
    useradd -m -u ${DEV_UID} -g ${DEV_GID} -s /bin/bash ${DEV_USER} && \
    usermod -aG sudo ${DEV_USER} && \
    echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${DEV_USER} && \
    # Pre-create the venv directories in /opt/ with dev user ownership.
    # The venv creation RUN later runs as DEV_USER, which cannot write to
    # /opt/ (root-owned 755).  Creating the target dirs here as root and
    # chown-ing them lets `python3.x -m venv /opt/venv-*` succeed.
    mkdir -p /opt/venv-metal /opt/venv-vllm /opt/venv-forge && \
    chown ${DEV_UID}:${DEV_GID} /opt/venv-metal /opt/venv-vllm /opt/venv-forge

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
#   /opt/venv-forge  - TT-Forge-ONNX + TT-XLA PJRT plugin (Python 3.12)
#
# venv-forge uses Python 3.12 because:
#   - tt-forge-onnx GitHub Release wheels ship cp312-only.
#   - pjrt_plugin_tt (from tt-xla-slim) was compiled against cp312.
#   - Python 3.12 is the Ubuntu 24.04 system default (no deadsnakes needed).

RUN python3.10 -m venv /opt/venv-metal && \
    python3.10 -m venv /opt/venv-vllm && \
    python3.12 -m venv /opt/venv-forge

# Upgrade pip in each venv
RUN /opt/venv-metal/bin/pip install --upgrade pip && \
    /opt/venv-vllm/bin/pip install --upgrade pip && \
    /opt/venv-forge/bin/pip install --upgrade pip

# ---------------------------------------------------------------------------
# 5. Clone tt-metal at pinned commit; optionally build from source
# ---------------------------------------------------------------------------

# Pin to the tt-metal commit that matches a known-good vLLM stack (e.g. 555f240…).
# Adjust as needed if you want a different known-good combo.
ARG TT_METAL_REPO=https://github.com/tenstorrent/tt-metal.git
ARG TT_METAL_COMMIT=555f240b7dbfadd6634e958faedb516bfaf6f9c4

# Controls whether we compile tt-metal inside the image.
# See the file header for a full description of each mode.
#   checkout  (default) — clone only, no build
#   full                — clone + install_dependencies.sh + build + pip install
ARG TT_METAL_BUILD=checkout

# Clone is always performed regardless of TT_METAL_BUILD mode.
# Having the source tree present lets developers build at runtime if needed
# and keeps the image useful for browsing / hacking on tt-metal code.
# --recurse-submodules is required; tt-metal has many third-party submodules.
RUN git clone --recurse-submodules ${TT_METAL_REPO} /home/${DEV_USER}/tt-metal && \
    cd /home/${DEV_USER}/tt-metal && \
    git checkout ${TT_METAL_COMMIT} && \
    git submodule update --init --recursive

ENV TT_METAL_HOME=/home/${DEV_USER}/tt-metal

# Install tt-metal system dependencies — only needed when we're about to build.
# Skipped in checkout mode to keep that path fast.
RUN if [ "${TT_METAL_BUILD}" = "full" ]; then \
      cd ${TT_METAL_HOME} && sudo ./install_dependencies.sh || true; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping install_dependencies.sh"; \
    fi

# Full C++ build + Python venv install.
# In checkout mode the script is still copied into the image so developers
# can trigger it manually inside the running container:
#   bash /tmp/build_tt_metal.sh
#
# Note: COPY always creates files owned by root (UID 0), so we invoke the
# scripts with `bash` instead of relying on the execute bit, which the dev
# user cannot set on root-owned files.
COPY scripts/build_tt_metal.sh /tmp/build_tt_metal.sh
RUN if [ "${TT_METAL_BUILD}" = "full" ]; then \
      bash /tmp/build_tt_metal.sh; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping tt-metal compilation."; \
      echo "To build later inside the container: bash /tmp/build_tt_metal.sh"; \
    fi

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
#
# Skipped in checkout mode: the Tenstorrent vLLM fork's setup.py links against
# compiled tt-metal Python extensions, so `pip install -e .` will fail without
# the build artifacts produced by build_tt_metal.sh.
# To complete the vLLM install after building tt-metal at runtime:
#   bash /tmp/setup_envs.sh vllm
COPY scripts/setup_envs.sh /tmp/setup_envs.sh
RUN if [ "${TT_METAL_BUILD}" = "full" ]; then \
      bash /tmp/setup_envs.sh vllm; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping vLLM pip install."; \
      echo "Run: bash /tmp/setup_envs.sh vllm after building tt-metal inside the container."; \
    fi

# ---------------------------------------------------------------------------
# 7. Forge / TT-Forge-ONNX / TT-XLA env (Python 3.12)
# ---------------------------------------------------------------------------
#
# The forge venv has two main components:
#
#   A) tt-forge-onnx  (tt_forge_onnx + tt_tvm wheels)
#      Source: GitHub Releases — https://github.com/tenstorrent/tt-forge-onnx
#      Wheels: cp312-only, nightly pre-releases.
#      setup_envs.sh fetches the latest release via the GitHub API at build time.
#
#   B) tt-xla PJRT plugin  (pjrt_plugin_tt + JAX layer)
#      Source: multi-stage COPY from ghcr.io/tenstorrent/tt-xla-slim:latest
#      The slim image ships the plugin pre-compiled against JAX 0.7.1 and
#      the TT-MLIR toolchain.  We transplant the TT-specific packages only;
#      JAX itself is installed via pip in setup_envs.sh to keep the layers
#      sensible.
#
# Step 7a: Copy TT-XLA packages from the slim image into venv-forge.
#   Must happen after venv creation (section 4) but before setup_envs.sh forge
#   so the smoke test in that script can verify pjrt_plugin_tt is importable.
#
# Packages copied:
#   pjrt_plugin_tt        — JAX PJRT backend; contains pjrt_plugin_tt.so and
#                           lib64/ with bundled libtt_metal.so, libTTMLIR*.so,
#                           _ttnn.so, etc.  lib64/ uses rpath so no extra
#                           LD_LIBRARY_PATH is needed.
#   pjrt_plugin_tt.libs   — manylinux-style auditwheel-bundled .so files.
#   pjrt_plugin_tt-*.dist-info — dist-info for `pip show` and JAX plugin
#                           auto-discovery via entry_points.
#   jax_plugin_tt         — registers pjrt_plugin_tt as a JAX backend.
#   tt_jax                — TT JAX utility helpers (tracing, op wrappers).
#   ttxla_tools           — XLA utility scripts.
#
# Note: COPY runs as root, landing these files root-owned in the venv.
# Python only needs read access to import packages, so this is fine.
COPY --from=tt-xla-slim \
    /usr/local/lib/python3.12/dist-packages/pjrt_plugin_tt \
    /opt/venv-forge/lib/python3.12/site-packages/pjrt_plugin_tt
COPY --from=tt-xla-slim \
    /usr/local/lib/python3.12/dist-packages/pjrt_plugin_tt.libs \
    /opt/venv-forge/lib/python3.12/site-packages/pjrt_plugin_tt.libs
COPY --from=tt-xla-slim \
    /usr/local/lib/python3.12/dist-packages/pjrt_plugin_tt-1.0.0.dist-info \
    /opt/venv-forge/lib/python3.12/site-packages/pjrt_plugin_tt-1.0.0.dist-info
COPY --from=tt-xla-slim \
    /usr/local/lib/python3.12/dist-packages/jax_plugin_tt \
    /opt/venv-forge/lib/python3.12/site-packages/jax_plugin_tt
COPY --from=tt-xla-slim \
    /usr/local/lib/python3.12/dist-packages/tt_jax \
    /opt/venv-forge/lib/python3.12/site-packages/tt_jax
COPY --from=tt-xla-slim \
    /usr/local/lib/python3.12/dist-packages/ttxla_tools \
    /opt/venv-forge/lib/python3.12/site-packages/ttxla_tools

# Step 7b: Install JAX 0.7.1 + tt-forge-onnx into venv-forge.
# setup_envs.sh forge:
#   1. Installs jax==0.7.1 + jaxlib==0.7.1 to match the version the
#      pjrt_plugin_tt was compiled against.
#   2. Fetches the latest tt-forge-onnx GitHub Release cp312 wheels via the
#      GitHub API and installs them (tt_forge_onnx + tt_tvm).
RUN bash /tmp/setup_envs.sh forge

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

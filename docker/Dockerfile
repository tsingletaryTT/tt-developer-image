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
# Forge env note:
#   tt-forge is installed from the Tenstorrent private PyPI index
#   (https://pypi.eng.aws.tenstorrent.com/), matching the approach used by
#   tt-code-server (git@github.com:tenstorrent/tt-code-server).
#   No multi-stage build is used — the tt-forge wheel bundles the PJRT plugin,
#   JAX layer, and TT-XLA tools.  tt-forge-install completes the setup.

# ---------------------------------------------------------------------------
# Stage 0: not used.
#   Forge is installed via pip from the Tenstorrent private PyPI
#   (https://pypi.eng.aws.tenstorrent.com/), the same approach used by
#   tt-code-server (git@github.com:tenstorrent/tt-code-server).
#   No multi-stage build or COPY --from is needed.
# ---------------------------------------------------------------------------

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
    # Common libs for tt-mlir / tt-forge / tt-xla
    protobuf-compiler libprotobuf-dev \
    libnuma-dev libhwloc-dev libboost-all-dev libnsl-dev \
    # libncurses6: required by tt-forge native libraries (_C.so) at runtime.
    # Ubuntu 24.04 ships libncurses6 but only as a transitive dep; explicit
    # installation ensures it is always present regardless of apt pruning.
    libncurses6 \
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
#   /opt/venv-forge  - tt-forge compiler + TT-XLA PJRT plugin (Python 3.12)
#
# venv-forge uses Python 3.12 because:
#   - tt-forge wheels from the Tenstorrent private PyPI are cp312-only.
#   - Python 3.12 is the Ubuntu 24.04 system default (no deadsnakes needed).

RUN python3.10 -m venv /opt/venv-metal && \
    python3.10 -m venv /opt/venv-vllm && \
    python3.12 -m venv /opt/venv-forge

# Upgrade pip in each venv
RUN /opt/venv-metal/bin/pip install --upgrade pip && \
    /opt/venv-vllm/bin/pip install --upgrade pip && \
    /opt/venv-forge/bin/pip install --upgrade pip

# Run tt-installer in container mode to install tt-smi and tt-flash into venv-metal.
#
# The QB2 pre-installed image uses tt-installer with --python-choice=new-venv to set
# up ~/.tenstorrent-venv.  We replicate that here using --python-choice=active-venv
# (venv-metal is already active) so we get the same package versions from the same
# PyPI sources that QB2 users have.
#
# --mode-container: explicitly designed for this use case — skips everything that
#   must live on the host kernel: KMD (tenstorrent-dkms), HugePages (tenstorrent-tools),
#   SFPI, container-runtime-inside-container. Never reboots.
# --python-choice=active-venv: installs tt-smi and tt-flash into the already-activated
#   venv-metal (VIRTUAL_ENV must be set, which `source .../activate` does).
# --update-firmware=off: skip firmware flashing — no hardware present during image build.
# --no-install-metalium-container/forge: skip OCI image pulls (Docker-in-Docker).
# --no-install-inference-server/studio: skip git clone steps not needed in this image.
#
# Side-effect: tt-installer also adds the Tenstorrent apt PPA (ppa.tenstorrent.com),
# so tenstorrent-tools and tenstorrent-dkms can be installed later with apt if needed.
RUN bash -c " \
    source /opt/venv-metal/bin/activate && \
    curl -fsSLO https://github.com/tenstorrent/tt-installer/releases/latest/download/install.sh && \
    chmod +x install.sh && \
    ./install.sh \
      --mode-container \
      --mode-non-interactive \
      --python-choice=active-venv \
      --no-install-metalium-container \
      --no-install-forge-container \
      --no-install-inference-server \
      --no-install-studio \
      --update-firmware=off && \
    rm -f install.sh"

# Install huggingface-hub (provides `hf` CLI for model downloads) into both venvs.
# huggingface-hub is not part of tt-installer's package list — install separately.
# Also install tt-smi into venv-vllm; tt-installer only ran for venv-metal above.
RUN /opt/venv-metal/bin/pip install --quiet huggingface-hub && \
    /opt/venv-vllm/bin/pip install --quiet huggingface-hub tt-smi

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

# Clone Tenstorrent vLLM fork at the HEAD of the dev branch.
# We track branch HEAD rather than pinning to a specific commit because the
# dev branch is the integration target for current tt-metal builds; a stale
# commit pin frequently drifts out of sync with the tt-metal commit above.
# If you need a reproducible build, pass --build-arg VLLM_BRANCH=<tag or sha>.
ARG VLLM_REPO=https://github.com/tenstorrent/vllm.git
ARG VLLM_BRANCH=dev

RUN git clone ${VLLM_REPO} /home/${DEV_USER}/tt-vllm && \
    cd /home/${DEV_USER}/tt-vllm && \
    git checkout ${VLLM_BRANCH}

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
# 7. Forge env — tt-forge from Tenstorrent private PyPI (Python 3.12)
# ---------------------------------------------------------------------------
#
# We follow the approach used in tt-code-server
# (git@github.com:tenstorrent/tt-code-server): install tt-forge directly
# from the Tenstorrent internal PyPI index, then run tt-forge-install to
# complete the post-install setup (native runtime libs, tt-metalium backend).
#
# Why this approach instead of the multi-stage COPY from tt-xla-slim:
#   - Single source of truth: the same PyPI wheels tt-code-server ships
#   - No multi-stage build complexity (Stage 0 is unused)
#   - tt-forge bundles the PJRT plugin, JAX layer, and TT-XLA tools in one package
#   - Daily nightly builds mean the index always has a fresh release
#
# Private PyPI index: https://pypi.eng.aws.tenstorrent.com/
#   Packages available: tt-forge, tt-forge-fe, tt-forge-onnx, pjrt-plugin-tt,
#                       torch-xla, tt-tvm, ttnn, vllm-tt, ttmlir, …
#
# tt-forge requires Python 3.12 (cp312-only wheels). venv-forge was created
# with python3.12 in section 4, so this installs into the correct interpreter.
#
# tt-forge-install: post-install helper shipped in the tt-forge package.
#   Downloads and configures the tt-metalium backend used by the forge compiler.
#   Must be run once after pip install — safe to re-run if needed.
RUN bash -c " \
    source /opt/venv-forge/bin/activate && \
    pip install --upgrade pip && \
    pip install tt-forge tt-forge-onnx tt-smi \
        --extra-index-url https://pypi.eng.aws.tenstorrent.com/ && \
    tt-forge-install"
# tt-forge      — TT-XLA stack: pjrt_plugin_tt, JAX 0.7.1, torch-xla
# tt-forge-onnx — forge.compile() API for PyTorch/ONNX → TT compilation
# tt-smi        — hardware monitor; available in all three envs for convenience

# ---------------------------------------------------------------------------
# 7b. Pre-clone tt-forge demo repository
# ---------------------------------------------------------------------------
# Cloning during the image build means the VSCode lesson's
# "Clone and Run TT-Forge Demos" button is instant (no git-clone progress bar
# mid-demo).  The repo contains validated GPT-2, ALBERT, OPT, and ResNet
# demos in demos/tt-xla/; pip install -r requirements.txt is still needed
# at runtime (handled by the lesson command).
# --depth 1: only the tip of main — keeps the layer small (~10 MB).
RUN git clone --depth 1 https://github.com/tenstorrent/tt-forge.git \
        /home/${DEV_USER}/tt-forge

# ---------------------------------------------------------------------------
# 8. Environment wrapper scripts (for DX convenience)
# ---------------------------------------------------------------------------

# These small scripts make it easy to switch envs:
#   source /etc/profile.d/tt-env-metal.sh
#   source /etc/profile.d/tt-env-vllm.sh
#   source /etc/profile.d/tt-env-forge.sh

RUN echo 'unset TT_METAL_HOME TT_METAL_VERSION' | sudo tee -a /etc/profile > /dev/null && \
    printf '%s\n' \
      '#!/bin/bash' \
      '# TT_METAL_ARCH_NAME — tell tt-metal which silicon architecture you are running on.' \
      '#   Wormhole (N150 / N300 / T3K / Galaxy):      wormhole_b0' \
      '#   Blackhole (P100 / P150 / P300c / QB2):      blackhole' \
      '#' \
      '# The value below is the default used when TT_METAL_ARCH_NAME is not already set' \
      '# in the environment.  To override, either:' \
      '#   export TT_METAL_ARCH_NAME=blackhole   # before sourcing this script' \
      '#   -or- pass  -e TT_METAL_ARCH_NAME=blackhole  to docker run.' \
      ': "${TT_METAL_ARCH_NAME:=wormhole_b0}"' \
      'export TT_METAL_ARCH_NAME' \
      'export TT_METAL_HOME=/home/'"${DEV_USER}"'/tt-metal' \
      'export PYTHONPATH=$TT_METAL_HOME:$PYTHONPATH' \
      'export LD_LIBRARY_PATH=/home/'"${DEV_USER}"'/tt-metal/build/lib:$LD_LIBRARY_PATH' \
      'source /opt/venv-metal/bin/activate' \
    | sudo tee /etc/profile.d/tt-env-metal.sh > /dev/null && \
    sudo chmod +x /etc/profile.d/tt-env-metal.sh && \
    printf '%s\n' \
      '#!/bin/bash' \
      '# TT_METAL_ARCH_NAME — wormhole_b0 (N150/N300/T3K) or blackhole (P100/P150/P300c/QB2).' \
      '# Override: export TT_METAL_ARCH_NAME=blackhole  or  docker run -e TT_METAL_ARCH_NAME=blackhole' \
      ': "${TT_METAL_ARCH_NAME:=wormhole_b0}"' \
      'export TT_METAL_ARCH_NAME' \
      'unset TT_METAL_VERSION' \
      'export TT_METAL_HOME=/home/'"${DEV_USER}"'/tt-metal' \
      'source /opt/venv-vllm/bin/activate' \
    | sudo tee /etc/profile.d/tt-env-vllm.sh > /dev/null && \
    sudo chmod +x /etc/profile.d/tt-env-vllm.sh && \
    printf '%s\n' \
      '#!/bin/bash' \
      '# TT_METAL_ARCH_NAME — wormhole_b0 (N150/N300/T3K) or blackhole (P100/P150/P300c/QB2).' \
      '# Override: export TT_METAL_ARCH_NAME=blackhole  or  docker run -e TT_METAL_ARCH_NAME=blackhole' \
      ': "${TT_METAL_ARCH_NAME:=wormhole_b0}"' \
      'export TT_METAL_ARCH_NAME' \
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

# ---------------------------------------------------------------------------
# Pre-create ~/tt-scratchpad/
# ---------------------------------------------------------------------------
# Extension commands write scripts here.  Creating it now means
# "ls ~/tt-scratchpad" works from minute one and scripts accumulate visibly.
RUN mkdir -p /home/${DEV_USER}/tt-scratchpad && \
    printf '# tt-scratchpad\n# Scripts created here by the Tenstorrent VSCode extension.\n# Add your own experiments freely — nothing here is precious.\n' \
    > /home/${DEV_USER}/tt-scratchpad/README.md

# ---------------------------------------------------------------------------
# Shell convenience functions: tt-metal | tt-vllm | tt-forge
# ---------------------------------------------------------------------------
# These let users switch Python environments by typing a short name instead
# of remembering the full path to each profile script.
#
#   tt-metal   → activates venv-metal (TTNN / direct API)
#   tt-vllm    → activates venv-vllm  (production serving)
#   tt-forge   → activates venv-forge (JAX / forge.compile)
#
# Implementation notes:
#   - bash function names may contain hyphens; they are called the same way.
#   - "deactivate 2>/dev/null || true" safely no-ops when no venv is active.
#   - "source" is used (not ".") for readability; both work in bash.
#   - The guard "grep -q" keeps the block idempotent if .bashrc is rebuilt.
RUN grep -q 'tt-metal()' /home/${DEV_USER}/.bashrc 2>/dev/null || \
    printf '\n# ── Tenstorrent environment switchers ───────────────────────\n# Usage: tt-metal  |  tt-vllm  |  tt-forge\ntt-metal() { deactivate 2>/dev/null || true; source /etc/profile.d/tt-env-metal.sh; }\ntt-vllm()  { deactivate 2>/dev/null || true; source /etc/profile.d/tt-env-vllm.sh;  }\ntt-forge() { deactivate 2>/dev/null || true; source /etc/profile.d/tt-env-forge.sh; }\n# ─────────────────────────────────────────────────────────────\n' \
    >> /home/${DEV_USER}/.bashrc

# Default shell: no envs activated (must opt-in with profile scripts or switchers).
# To start code-server instead:
#   docker run -p 8080:8080 -e PASSWORD=... <image> \
#     code-server --bind-addr 0.0.0.0:8080 --auth password \
#                 --disable-telemetry --disable-update-check
CMD ["/bin/bash"]

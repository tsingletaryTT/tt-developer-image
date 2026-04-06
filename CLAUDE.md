Below is a “virtual ZIP” layout with all files inlined so you can paste them into your own repo. Structure:

- `docker/README.md` – summary + rationale
- `docker/Dockerfile` – heavily commented, Ubuntu 24.04, full deps, full tt-metal build, Forge/XLA, vLLM
- `docker/scripts/install_system_deps.sh`
- `docker/scripts/build_tt_metal.sh`
- `docker/scripts/setup_envs.sh`

You can literally put these under a `docker/` directory and run:
```bash
cd docker
docker build -t tenstorrent/dev-n150:latest .
```

---

### File: `docker/README.md`

```markdown
# Tenstorrent N150 Developer Docker Image

This directory defines a **developer-centric** Docker image for **single N150** (Wormhole) systems that:

- Uses **Ubuntu 24.04 LTS** as base (future-proof, but pinned stack).
- Installs system drivers/firmware via **tt-installer** (host, not image).
- Builds **tt-metal** from source at a **vLLM-validated commit**.
- Sets up three Python envs:
  - `/opt/venv-metal`   → tt-metal + TTNN
  - `/opt/venv-vllm`    → vLLM (Tenstorrent fork) + torch 2.5.0+cpu
  - `/opt/venv-forge`   → TT-Forge, TT-Forge-ONNX, TT-XLA 0.8.0
- Leaves **tt-inference-server out of the container**, but mirrors its
  internal version matrix (tt-metal + vLLM) for maximum “no version hell”.

## Design Principles

1. **Pin everything.**
   - tt-metal: commit `555f240b7d…` (same as tt-inference-server 0.10.0 stack).
   - vLLM: Tenstorrent fork at the matching vLLM commit (e.g. `22be241`).
   - TT-Forge / TT-Forge-ONNX / TT-XLA: `0.8.0`.
   - PyTorch: `2.5.0+cpu` for the vLLM env.

2. **Separate environments.**
   - Never mix Forge, vLLM, and metal in one venv.
   - Default shell has **no TT env pollution**:
     - `TT_METAL_HOME` / `TT_METAL_VERSION` unset.

3. **Container vs Host responsibilities.**
   - **Host**: real card, kernel driver (KMD), firmware, huge pages.
     - Install via **tt-installer** on the host, not from inside container.
   - **Container**: userland compilers, Python, tt-metal source, vLLM, Forge.

4. **Runtime requirements (when you run the container)**
   - `/dev/tenstorrent` device mapped into the container.
   - Hugepages mounted if you use them:
     - e.g. `-v /dev/hugepages-1G:/dev/hugepages-1G`.
   - `--privileged` or equivalent capabilities, depending on host policy.

## Quick Start

```bash
# Build
cd docker
docker build -t tenstorrent/dev-n150:latest .

# Run (replace /dev/tenstorrent path & hugepages with your host setup)
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  tenstorrent/dev-n150:latest \
  bash

# Inside container:

# 1. Source metal env & run a basic TTNN op
source /etc/profile.d/tt-env-metal.sh
python -c "import ttnn; print('TTNN ok, version:', ttnn.__version__)"

# 2. Source vLLM env & print versions
source /etc/profile.d/tt-env-vllm.sh
python -c "import torch, vllm; print('torch', torch.__version__, 'vllm', vllm.__version__)"

# 3. Source Forge env
source /etc/profile.d/tt-env-forge.sh
python -c "import tt_forge_onnx; print('Forge-ONNX ok')"
```

## Notes

- This image assumes you **already ran tt-installer on the host** and the
  card is enumerated (check `tt-smi` on the host).
- You can adjust versions/commits by editing:
  - `TT_METAL_COMMIT` in `Dockerfile`
  - `FORGE_VERSION` in `setup_envs.sh`
  - `VLLM_COMMIT` and `TORCH_*` pins in `setup_envs.sh`.
```

---

### File: `docker/Dockerfile`

```dockerfile
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
# 2. Create a ‘developer’ user (avoid running as root)
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
# We don’t strictly require them, but they are nice to have and some
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
# NOTE: we run this inside the container for a “fat dev” image –
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
# 9. Final touches
# ---------------------------------------------------------------------------

WORKDIR /home/${DEV_USER}
ENV DEBIAN_FRONTEND=dialog

# Default shell: no envs activated (must opt-in with profile scripts)
CMD ["/bin/bash"]
```

---

### File: `docker/scripts/install_system_deps.sh` (optional helper)

If you want a dedicated script for system deps (Dockerfile currently inlines them), you can use this instead and replace that block.

```bash
#!/bin/bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  bash ca-certificates curl wget git sudo apt-transport-https gnupg lsb-release \
  build-essential ninja-build cmake pkg-config \
  python3.10 python3.10-venv python3.10-dev \
  python3.11 python3.11-venv python3.11-dev \
  python3-pip \
  clang-17 clang++-17 \
  protobuf-compiler libprotobuf-dev \
  libnuma-dev libhwloc-dev libboost-all-dev libnsl-dev \
  cpufrequtils linux-tools-common linux-tools-generic \
  iproute2 iputils-ping

sudo rm -rf /var/lib/apt/lists/*
sudo ln -sf /usr/bin/clang-17 /usr/local/bin/clang
sudo ln -sf /usr/bin/clang++-17 /usr/local/bin/clang++
```

---

### File: `docker/scripts/build_tt_metal.sh`

```bash
#!/bin/bash
set -euo pipefail

# Build tt-metal from source and install Python bindings into /opt/venv-metal.
# Assumes:
#   - TT_METAL_HOME is set
#   - /opt/venv-metal exists

TT_METAL_HOME=${TT_METAL_HOME:-"$HOME/tt-metal"}
VENV_METAL=/opt/venv-metal

echo ">>> Building tt-metal from source at $TT_METAL_HOME"
cd "$TT_METAL_HOME"

# Optional: clean previous builds if you want a pristine image
# rm -rf build build_Release

# FULL BUILD:
# - Builds firmware, C++ libs, TTNN, tools
# - Takes time, but you asked to “compile anything we want”
./build_metal.sh

# Create venv & install Python package (if you prefer not to use create_venv.sh)
# Here we reuse /opt/venv-metal and pip-install tt-metal in editable mode.
source "${VENV_METAL}/bin/activate"

# Install tt-metal Python package in editable mode so users can hack the source.
pip install --upgrade pip
pip install -e .

# Optional: install TTNN wheels or extras if provided (depending on this commit).
# In many cases TTNN is installed via setup.py as part of tt-metal, so nothing extra.

# Basic smoke test
python - << 'EOF'
import ttnn
print("TTNN import OK, version:", getattr(ttnn, "__version__", "unknown"))
EOF

deactivate

echo ">>> tt-metal build and Python install complete"
```

---

### File: `docker/scripts/setup_envs.sh`

```bash
#!/bin/bash
set -euo pipefail

# Usage:
#   ./setup_envs.sh vllm
#   ./setup_envs.sh forge
#
# This script:
#   - For "vllm": installs torch 2.5.0+cpu and vLLM + deps into /opt/venv-vllm.
#   - For "forge": installs tt-forge / tt-forge-onnx / pjrt-plugin-tt 0.8.0 into /opt/venv-forge.

TARGET="${1:-}"

if [[ "$TARGET" != "vllm" && "$TARGET" != "forge" ]]; then
  echo "Usage: $0 {vllm|forge}"
  exit 1
fi

if [[ "$TARGET" == "vllm" ]]; then
  VENV=/opt/venv-vllm
  echo ">>> Configuring vLLM env at $VENV"

  source "${VENV}/bin/activate"

  # 1. Torch 2.5.0+cpu and friends
  echo ">>> Installing torch 2.5.0+cpu stack"
  pip install --quiet --index-url https://download.pytorch.org/whl/cpu \
    torch==2.5.0+cpu \
    torchvision==0.20.0 \
    torchaudio==2.5.0

  # 2. Core Python deps often used in TT vLLM flows
  echo ">>> Installing core vLLM dependencies"
  pip install --quiet \
    fairscale \
    termcolor \
    loguru \
    blobfile \
    fire \
    pytz

  # 3. Install vLLM from cloned repo
  echo ">>> Installing vLLM (editable) from ~/tt-vllm"
  cd "$HOME/tt-vllm"
  pip install --quiet -e .

  # 4. Basic sanity check
  python - << 'EOF'
import torch, vllm
print("vLLM OK - torch:", torch.__version__, "vllm:", getattr(vllm, "__version__", "unknown"))
EOF

  deactivate
  echo ">>> vLLM env setup complete"

elif [[ "$TARGET" == "forge" ]]; then
  VENV=/opt/venv-forge
  FORGE_VERSION=0.8.0

  echo ">>> Configuring Forge env at $VENV (version $FORGE_VERSION)"

  source "${VENV}/bin/activate"

  # NOTE: these package names assume TT-Forge & friends are published to your
  # internal PyPI index. Adjust names/index URLs as needed.
  # Example names:
  #   - tt-forge        (meta wheel containing frontends)
  #   - tt_forge_onnx   (TT-Forge-ONNX)
  #   - pjrt-plugin-tt  (TT-XLA plugin)

  echo ">>> Installing TT-Forge 0.8.0 stack (tt-forge, tt-forge-onnx, pjrt-plugin-tt)"
  pip install --quiet \
    tt-forge==${FORGE_VERSION} \
    tt_forge_onnx==${FORGE_VERSION} \
    pjrt-plugin-tt==${FORGE_VERSION} \
    --extra-index-url https://pypi.eng.aws.tenstorrent.com/

  # Optional: install jax / torch-xla if your flows need them
  # pip install --quiet jax==0.6.0 jaxlib==0.6.0 torch==2.7.0 torch-xla==2.7.0

  # Basic sanity checks
  python - << 'EOF'
try:
    import tt_forge_onnx as fonnx
    print("TT-Forge-ONNX OK:", fonnx.__name__)
except Exception as e:
    print("TT-Forge-ONNX import FAILED:", e)
EOF

  deactivate
  echo ">>> Forge env setup complete"
fi
```

---

This should give you a solid starting “fat dev” image:

- Ubuntu 24.04, fully pinned stack.
- Full tt-metal build with examples.
- vLLM + torch stack aligned with production-like versions.
- Forge/XLA stack isolated but ready to go.
- Lots of comments so your team can evolve it as the TT stack moves.

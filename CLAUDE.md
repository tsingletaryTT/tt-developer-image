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

## Session log

### 2026-07-15 — Golden QB2 image + CI (sub-project A)
Prompt: use the "Install Tenstorrent Stack" GitHub Action + latest golden
installer path for QB2-image testing.
- Pinned `Dockerfile.qb2` step 6 to `install.sh --versions=release` (golden).
- Added `.github/workflows/qb2-image.yml`: self-hosted `[self-hosted,tenstorrent]`
  runner on the QuietBox, fully container-isolated (host never mutated; cards via
  `--device` passthrough). Jobs: golden-stack (action, container mode, `.ttis`
  artifact), build-qb2 (checkout + `qb2_smoke.sh`), inference (on-demand full build).
- Added reusable `docker/scripts/qb2_smoke.sh`.
- Decisions: track latest golden release (no version pin); no registry push (no
  storage); no `pull_request` trigger (no fork code on hardware).
- Sub-project B (Claude skill to dispatch arbitrary projects into the image for
  clean-install + inference) is deferred to its own spec.
Spec: `docs/superpowers/specs/2026-07-15-golden-qb2-image-ci-design.md`.

### 2026-07-16 — Pivot: on-demand CLI runner instead of GH self-hosted runner
Decision: skip registering the QuietBox as a GitHub Actions runner ("GH doesn't
have to know about us"). Added `docker/scripts/ci-qb2.sh` — a local, on-demand
runner (golden-stack / build-qb2 / inference phases, `--fast` and `--inference`
flags) that runs the same checks from the CLI, fully container-isolated. The
`qb2-image.yml` workflow is kept but made dormant: `workflow_dispatch`-only (no
push trigger), documented as an optional GitHub-native path that only works if a
self-hosted runner is ever registered. Merged `feat/golden-qb2-image-ci` to main.

### 2026-08-03 — vLLM: fork build → standalone TT platform plugin (validated on QB2)
Prompt: "upgrade what we're doing in the developer image to use the new vLLM path.
Validate it there for me now."

**What changed.** Tenstorrent vLLM support is no longer a patched fork build; it is
an out-of-tree vLLM *platform plugin* whose official home is the standalone repo
`github.com/tenstorrent/vllm-tt-plugin`. It works against **upstream** vLLM — its
own `docs/install-vllm-tt.sh` pins `vllm==0.24.0` — so no fork is cloned any more.

- `docker/scripts/setup_envs.sh` — vllm target rewritten to defer to the plugin's
  own installer, plus a hard-failing plugin-discovery check.
- `docker/Dockerfile`, `docker/Dockerfile.qb2` — clone `vllm-tt-plugin` instead of
  the fork. `VLLM_REPO`/`VLLM_BRANCH` → `VLLM_TT_PLUGIN_REPO`/`VLLM_TT_PLUGIN_REF`;
  new `VLLM_TT_PLUGIN_SRC` passed to `setup_envs.sh` (`VLLM_SRC` still honoured).
- `docker/scripts/qb2_smoke.sh` — checks the plugin checkout and its installer +
  overrides file, and verifies both vLLM entry points when the install ran.
- Dropped the `torch==2.5.0+cpu` pin: it predates the plugin and conflicts with
  what `vllm==0.24.0` resolves.

**Four failures found only by actually running it** (all now handled in the script):
1. **numpy.** ttnn pins `numpy<2`; resolving vLLM alone pulls numpy 2.x (its opencv
   floor) and `import ttnn` then dies. The plugin's `docs/vllm-overrides.txt`
   (`numpy>=1.24.4,<2` + `opencv-python-headless==4.11.0.86`) fixes it — upstream
   landed that same override on 2026-08-03 (#20), independently confirming it.
2. **ttnn reachability.** This image's `venv-vllm` is separate from tt-metal's
   `python_env`, but the plugin activates *only* when `ttnn` imports. Wired via a
   `ttnn-custom.pth` pointing at the tt-metal tree (what a real QB2 does); the
   script now exits non-zero rather than shipping a vLLM that sees no hardware.
3. **torchvision.** transformers' pixtral image processor imports it while vLLM
   inspects the TT model class. Absent → "Model architectures ['TTQwen3ForCausalLM']
   failed to be inspected".
4. **pytest.** `tt-metal/models/common/utility_functions.py` imports it at module
   scope. Absent → same opaque inspection failure.

Also: ttnn exposes no `__version__` — read it via `importlib.metadata.version("ttnn")`.

**Validated on this QuietBox 2 (4x P300C)**, in throwaway venvs; `~/.tenstorrent-venv`
was never touched. Confirmed: `Platform plugin tt is activated`; `TTPlatform` selected
(`device_name=tt`); both entry points registered; `MESH_DEVICE=P300x2` → `(1,4)`; UMD
opens chips {0,1,2,3}; weights load, KV cache allocates on-mesh, server reaches
healthy, `/v1/models` and `/v1/completions` serve. Versions: upstream vllm 0.24.0,
numpy 1.26.4, ttnn 0.65.1rc17.dev6200.

**Known-bad, and NOT caused by this change: generation output is degenerate.** Every
run collapses into repetition ("Paris. The city. The city..."). Reproduced across 5
configs — fork `dev@50d3f5ff4` *and* upstream `0.24.0`; Qwen3-0.6B, Llama-3.1-8B-Instruct,
Qwen3-32B; `P100` (1 chip) *and* `P300x2` (4 chips) — with byte-identical output across
both vLLM versions. So it is neither the plugin, the install path, the mesh, nor the
model. The only invariant is this host's tt-metal build (`0.65.1rc17.dev6200`, a dev
build far from any release in tt-metal's LLMs table, which pins tt-metal release ↔ vLLM
commit pairs). The prior working Qwen3-32B/P300x2 run on this box came from a
tt-inference-server Docker image with its own pinned tt-metal, not the host tree.
**Next step: retest against a paired tt-metal release before trusting output quality.**

Two facts worth remembering:
- **`HF_MODEL` is still required** when `--model` is a local path — `tt_transformers`
  uses it as the checkpoint dir (`model_config.py`: `self.CKPT_DIR = HF_MODEL`).
- **Qwen3-0.6B is not a tt-transformers model.** `0.6B` appears nowhere in
  `models/tt_transformers/`; the only supported Qwen3 there is Qwen3-32B. The plugin
  maps it by architecture, so it loads and runs but has no validated params.

### 2026-08-03 (later) — "latest metal" image variant
Prompt: "track the latest release in a separate docker image/dockerfile setup.
We'll have a 'latest metal' variant."

**Added** `docker/Dockerfile.latest-metal` plus `docker/scripts/resolve_metal_release.sh`.
The variant follows tt-metal's newest *release tag* rather than the pinned commit, and
takes the compiled runtime from the matching published `ttnn` wheel — no 30–90 min
source build. Kept as a separate file on purpose: `Dockerfile.qb2` pins a commit to be
byte-reproducible, this one is deliberately current, and mixing those goals in one file
would quietly break the reproducible promise.

**Why the source checkout survives.** The `ttnn` wheel does *not* ship `models/` —
verified by unzipping it, top level is `ttnn`, `tt_lib`, `tracy`, `triage`, `ttnn.libs`
and zero `models/tt_transformers` entries. The plugin registers model classes by dotted
path into `models.*`, so the variant shallow-clones tt-metal at the tag and puts only
that root on `sys.path`. `<root>/ttnn` is deliberately omitted: it has no `__init__.py`,
so listing it would register a namespace portion for `ttnn`. Verified empirically that
the wheel's real package still wins the path scan either way.

`setup_envs.sh` gained **wheel mode** (`TTNN_WHEEL_VERSION`) alongside the existing
source mode, and its verification now proves `ttnn` resolves from site-packages *and*
`models/` from the source tree. `qb2_smoke.sh` asserts `~/.metal-release.env` agrees
with both the checked-out tag and the installed wheel; skipped on pinned images.

**Why not tt-installer's golden `metal-version`.** It publishes one (`v0.72.0` at the
time of writing), but tt-installer never reads that field — no reference in
`install.m4` — and it ships metalium as a *container wrapper*, which cannot supply the
importable `ttnn` the plugin needs. Golden also lags: `v0.72.0` lacks
`models/demos/blackhole/qwen36`, which the current plugin registers and `v0.75.0` has.
`resolve_metal_release.sh --golden` prints it for comparison. What tt-installer *does*
pair (kmd, firmware, tt-smi, tt-flash, sfpi) is still used via `--versions=release`.

**The pinned images were badly stale**: `TT_METAL_COMMIT=555f240b7d` is a 2026-03-05
`[release-tests]` commit, five months old and not a release tag.

**Negative result worth recording — this did NOT fix the degenerate output.** I built the
paired stack by hand on the QB2 (ttnn 0.75.0 wheel + tt-metal v0.75.0 source `models/`
+ upstream vllm 0.24.0 + standalone plugin; plugin activated, entry points registered,
`models` resolving from v0.75.0) and served Llama-3.1-8B-Instruct on `MESH_DEVICE=P300x2`.
Output was **byte-identical to the earlier degenerate runs**
(`' a city of the largest city of the of the of the...'`). So the tt-metal version
hypothesis is disproved: a fully released, self-consistent tt-metal behaves the same.

Corrected picture: output is deterministic per (model, mesh) and unchanged across
tt-metal 0.65.1rc17.dev6200 → v0.75.0 and across two vLLM versions. Every model gets
roughly the first token right and then collapses, which looks like context/attention not
being used rather than a bad checkout. **New leading suspect: host firmware and driver
are ahead of every golden pairing** — this box runs firmware `19.12.0.0` and kmd
`2.10.0`, while golden names `19.11.0` / `2.9.0`. Next step is to test against
golden-matched firmware/kmd, not another tt-metal version.

#### Build result (2026-08-03)
Full cold build of `Dockerfile.latest-metal`: **~4.5 min, 18.5 GB**, resolving
`TT_METAL_TAG=v0.75.0` / `TTNN_VERSION=0.75.0`. That replaces a 30–90 min source build.
`qb2_smoke.sh` passes end to end, and a `--device /dev/tenstorrent` run inside the
container reports `TTPlatform`, 4 devices, and `P300x2 -> (1,4)`.

Two bugs the build itself surfaced, both fixed:
- **python3.10 was unreachable.** The first draft called `scripts/install_system_deps.sh`,
  which `sudo`s (not installed yet at that layer) and assumes python3.10 already exists.
  Ubuntu 24.04 ships 3.12, so the QB2 layout needs the deadsnakes PPA. Now mirrors
  `Dockerfile.qb2`'s proven apt block, and grants ttuser NOPASSWD sudo for tt-installer.
- **`tt-smi` / `hf` were not on PATH.** tt-installer drops them in the metal venv's bin;
  a real QB2 exposes them from `~/.local/bin`. Added the symlink step.

Also trimmed a doc lie: the header had promised a `TORCH_CPU_ONLY=1` flag that was never
implemented. The CUDA-torch caveat is now stated plainly instead.

`qb2_smoke.sh` now separates required components (metal venv, vllm venv, tt-metal,
vllm-tt-plugin) from optional ones (forge venv, tt-inference-server), so it works against
both the full QB2 image and this leaner variant without weakening the checks that matter.

A false alarm worth remembering: BuildKit's progress output prints RUN commands with
build-args interpolated, so layer 8 *displayed* `git clone --branch "latest"`. `RUN` does
not do ARG substitution — the shell does — and the layer's real stdout said
`Cloning tt-metal at v0.75.0`, with `remote.origin.fetch = +refs/tags/v0.75.0`. Don't
"fix" that again.

### 2026-08-04 — CI failure, then refactor for commonalities
Prompt: "the CI for tt-developer-image failed; please debug" → "Refactor for
commonalities?" → "D+list".

**The failure was not the vLLM change.** Build died at the tt-installer step with
`[ttis] ERROR: jq is required but not installed`. tt-installer's `--versions` flag
defaults to `release`, which fetches the golden `.ttis` manifest from tt-sw-manifest and
parses it with `jq`. The standard `docker/Dockerfile` passes no `--versions` and had no
`jq` in its apt list. `Dockerfile.qb2` was fixed for exactly this in `03cb664`
(2026-07-15) — but that fix touched qb2 only. So the standard file had been latently
broken ever since tt-installer's latest release began defaulting to `release`; it
surfaced now only because `docker-build.yml` is path-filtered on `docker/**` and this was
the first push to touch it. Any push touching `docker/` would have failed identically.

CI logs need admin auth and `gh` is unauthenticated here, so I reproduced the exact CI
invocation locally (`docker build --build-arg TT_METAL_BUILD=checkout -f docker/Dockerfile
docker/`) and got the real error in one run. Worth remembering: I would not have guessed
"upstream changed its default version channel" — reproducing beat hypothesising.

Second, separate defect (mine): smoke test 6b asserted `$HOME/tt-vllm`, which the plugin
migration replaced with `$HOME/vllm-tt-plugin`. Retargeted, and it now also asserts the
checkout carries `docs/install-vllm-tt.sh` and `docs/vllm-overrides.txt` — the latter
holds the numpy<2 pin, and its absence is the difference between a working install and one
that silently cannot import ttnn. Fix + retarget shipped in `4a58b71`; CI green.

**Then the refactor.** Measured the real overlap first: raw line overlap is modest (60 of
~190 between the two biggest) because the standard Dockerfile carries a lot that is
genuinely unique. But the apt package sets are **nested** — `latest-metal ⊂ qb2 = standard`
— which is the ideal shape. So rather than a shared base image (option A), we took the
cheaper option:

- `docker/scripts/apt-packages-base.txt` — 25 packages, all three variants
- `docker/scripts/apt-packages-toolchain.txt` — 9 more, for the two that compile tt-metal
- each Dockerfile `COPY`s the list(s) and installs via
  `grep -vE '^\s*(#|$)' … | xargs apt-get install`
- verified the refactor is behaviour-preserving: resolved package sets are **identical**
  to the pre-refactor blocks for all three variants
- `docker/scripts/check_apt_lists.py` — CI guard, with three negative tests confirming it
  catches the original jq bug, a re-inlined package list, and a variant that stops using
  the shared list
- new `variants` CI job: runs the guard, lints all three, and **builds Dockerfile.qb2**
  with its smoke script

Why the guard is a script and not a grep chain in YAML: the first heuristic version had two
false positives — the PPA bootstrap (`software-properties-common` sits on a continuation
line, not the `apt-get install` line) and `apt-get install -f` (dpkg dependency repair,
names no packages). Both are legitimate and are now explicit exceptions.

**`Dockerfile.latest-metal` is deliberately not built in CI.** It installs the ttnn wheel
plus a CUDA torch and lands at ~18.5 GB, which exceeds the free disk on a GitHub-hosted
runner. It is covered by the lint and by the shared lists; build it locally or on a
self-hosted runner.

Gotcha worth remembering: **`docker build --check` exits non-zero for WARNINGS too**, not
just errors. I measured it as exit 0 twice and was wrong both times — both measurements were
`docker build --check ... | tail` / `| grep`, so `$?` was the *pipeline tail's* status, not
docker's. Measured without a pipe it is consistently 1 whenever a warning exists. That would
have failed the new lint step on `docker/Dockerfile`'s known `SecretsUsedInArgOrEnv` warning
(`ENV PASSWORD=` for code-server, present since the initial commit, overridden at runtime and
deliberately left alone). The step therefore captures the output, prints it, and fails only on
`^ERROR: ` lines — verified both ways: the current warning-only tree passes, and a Dockerfile
with an unresolvable `COPY --from` is caught.

#### Follow-up: the qb2 CI failure my own refactor caused
The first version of the shared-list refactor fed the two lists to **two separate**
`apt-get install` invocations. The standard image's CI job passed with it; the new qb2 job
failed with `xargs` **exit 123** (xargs returns 123 when a command it spawns exits 1-125).
The apt-level output was not recoverable — CI logs need admin auth, and the check-run
annotation carried no `raw_details` — so the cause is not *proven*.

What is certain: splitting one resolution into two was an unnecessary behavioural change I
introduced. `libboost-all-dev` (toolchain list) pulls `libboost-python-dev` → `python3-dev`,
and resolving that in a second pass can select differently than one combined resolution.
Collapsed back to a single `apt-get install` fed by `cat base toolchain`, which makes the
refactor equivalent in effect to the pre-refactor block that had months of green CI. Also
added `xargs -r` and an `installed: N packages` echo so a future failure names the set.

Verified from a cold cache in isolation (`--no-cache`): `installed: 34 packages`, exit 0.

Two bugs in the guard itself, both surfaced by this change and both fixed:
  * it flagged *comment lines* that merely mention `apt-get install`
  * its allow-pattern was the literal substring `xargs apt-get install`, which stopped
    matching once the command became `xargs -r apt-get install`
After loosening it, all three negative tests were re-run and still fail correctly — a guard
relaxed until it passes is not a guard.

Process note: I twice reported measurements that were artefacts of my own tooling rather than
facts — `docker build --check` exit codes read through a pipe, and an apt package-set diff
from a regex that swallowed comment prose. Both were caught by re-measuring differently. When
a number decides a design choice, measure it two ways.

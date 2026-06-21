# Tenstorrent Developer Docker Image (Ubuntu 24.04)

Developer-centric Docker image for Tenstorrent hardware that supports both
**Wormhole** (N150 / N300 / T3K / Galaxy) and **Blackhole** (P100 / P150 / P300c / QB2):

- Ubuntu 24.04 LTS base with deadsnakes Python 3.10 for the TT stack
- tt-metal cloned at a pinned commit; optionally compiled (see build modes below)
- Three isolated Python virtualenvs:
  - `/opt/venv-metal`  → tt-metal + TTNN + `hf` CLI (Python 3.10)
  - `/opt/venv-vllm`   → Tenstorrent vLLM fork + torch 2.5.0+cpu + `hf` CLI (Python 3.10)
  - `/opt/venv-forge`  → TT-Forge-ONNX + pjrt_plugin_tt (TT-XLA) + JAX 0.7.1 (Python 3.12)
- code-server + tt-vscode-toolkit pre-installed (browser VS Code on port 8080)
- **No internal Tenstorrent network required** — all packages come from public GitHub
  Releases, GHCR, and PyPI

## Design Principles

1. **Separate environments** — never mix Forge, vLLM, and metal in one venv.
   The default shell has no TT env pollution (`TT_METAL_HOME` / `TT_METAL_VERSION` unset).

2. **Architecture is explicit** — every env script sets `TT_METAL_ARCH_NAME` from the
   environment, defaulting to `wormhole_b0`.  Blackhole users pass one flag and
   everything lines up.  See [Architecture flag](#architecture-flag) below.

3. **Container vs host responsibilities**
   - **Host**: real card, kernel driver (KMD), firmware, huge pages.
     Install via `tt-installer` on the host, not inside the container.
   - **Container**: compilers, Python, tt-metal source, vLLM, Forge.

4. **Build modes** (set via `--build-arg TT_METAL_BUILD=…`)
   - `checkout` (default) — clone only, no compilation.
     Fast; lets the CI / developer iterate on venv layers.
     Build time: minutes.
   - `full` — clone + `install_dependencies.sh` + C++ build + pip install.
     Required to dispatch real ops to hardware.
     Build time: 30–90 min (needs large-disk host).

## Two Dockerfiles

| File | Purpose |
|---|---|
| `Dockerfile` | General-purpose dev image; `/opt/venv-*` paths; `dev` user; code-server included |
| `Dockerfile.qb2` | Exact QB2 post-tt-installer environment; `~/tt-metal/python_env/` paths; `ttuser`; no code-server |

Use `Dockerfile.qb2` when you need QB2-identical paths — VHS terminal recording, testing scripts written for real QB2 users, or validating the QB2 guide content.

## Quick Start

### Wormhole (N150 / N300 / T3K)

```bash
# Build (checkout mode — fast, no compilation)
cd docker
docker build -t tenstorrent/dev:latest .

# Run
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  tenstorrent/dev:latest bash
```

### Blackhole / QB2 (P100 / P150 / P300c)

**For general dev work** — pass `TT_METAL_ARCH_NAME=blackhole` to `Dockerfile`:

```bash
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  -e TT_METAL_ARCH_NAME=blackhole \
  tenstorrent/dev:latest bash
```

**For QB2-exact environment** (VHS recordings, guide content, QB2-path testing) — use `Dockerfile.qb2`:

```bash
# Build
cd docker
docker build -f Dockerfile.qb2 -t tenstorrent/qb2-env:latest .

# Run with hardware access
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  tenstorrent/qb2-env:latest bash

# Run without hardware (path / alias verification only)
docker run -it tenstorrent/qb2-env:latest bash
```

`Dockerfile.qb2` hard-codes `TT_METAL_ARCH_NAME=blackhole` in `.bashrc` — no `-e` flag needed.

### Simulator (no hardware required)

Build once on QB2 (x86_64 Linux), then pull from GHCR anywhere:

```bash
# Pull pre-built image (once available on GHCR)
docker pull ghcr.io/tsingletary/tt-developer-image:sim-wh

# Or build locally on x86_64 Linux (~60–90 min)
docker build --build-arg TT_METAL_BUILD=sim \
             --build-arg TTSIM_VERSION=v1.7.0 \
             -t tt-sim:latest docker/

# Run (no /dev/tenstorrent needed)
docker run -it tt-sim:latest bash

# Inside the container:
tt-sim                        # activate Wormhole simulator
# or
tt-sim-bh                     # activate Blackhole simulator
python -c "import ttnn; print('TTNN ready')"

# Browser VS Code (port 8080)
docker run -d -p 8080:8080 -e PASSWORD=tenstorrent \
  tt-sim:latest \
  code-server --bind-addr 0.0.0.0:8080 --auth password \
              --disable-telemetry --disable-update-check
```

**What works in sim mode:**
- tt-metal / TTNN ops (slow dispatch mode, bit-exact results)
- TT-Lang kernels via ttlang-sim or ttsim
- TT-Forge compiler lessons (Forge uses its own backend, not ttsim)
- CS fundamentals lessons (Tensix visualizer, no hardware calls)
- `tt-toplike` in mock mode (monitoring UX without real hardware)

**What does not work in sim mode:**
- vLLM inference (requires fast dispatch, not yet supported by ttsim)
- QB2 multi-device lessons (require real PCI hardware)

**Known sim constraints (set automatically by `tt-sim`):**
- `TT_METAL_SLOW_DISPATCH_MODE=1` — required
- `TT_METAL_DISABLE_SFPLOADMACRO=1` — required
- `SIMULATOR_MODE=1` — picked up by tt-vscode-toolkit for status indicator

### Browser-based VS Code (code-server)

```bash
docker run -d \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  -e TT_METAL_ARCH_NAME=blackhole \   # omit or change for WH
  -p 8080:8080 \
  -e PASSWORD=your-password \
  tenstorrent/dev:latest \
  code-server --bind-addr 0.0.0.0:8080 --auth password \
              --disable-telemetry --disable-update-check
```

Open http://localhost:8080 and log in with your password.  The Tenstorrent
extension is pre-installed and applies the Tenstorrent Dark theme automatically.

## Architecture Flag

`TT_METAL_ARCH_NAME` tells tt-metal which silicon architecture is present:

| Hardware | Value |
|---|---|
| N150 / N300 / T3K / Galaxy | `wormhole_b0` (default) |
| P100 / P150 / P300c / QB2  | `blackhole` |

Set it **before** sourcing an env script or pass it via `docker run -e`.  The
env scripts use `: "${TT_METAL_ARCH_NAME:=wormhole_b0}"` — they never overwrite
a value that's already in the environment:

```bash
# Option A: set before sourcing (interactive use inside the container)
export TT_METAL_ARCH_NAME=blackhole
source /etc/profile.d/tt-env-metal.sh

# Option B: docker run -e (preferred for scripted / CI use)
docker run -e TT_METAL_ARCH_NAME=blackhole ...
```

## Inside the Container

```bash
# 1. Activate the metal env and verify TTNN
source /etc/profile.d/tt-env-metal.sh
echo "Arch: $TT_METAL_ARCH_NAME"
python -c "import ttnn; print('TTNN OK, version:', ttnn.__version__)"

# 2. HuggingFace model management (hf CLI available in metal + vllm envs)
hf auth login --token "$HF_TOKEN"
hf download Qwen/Qwen3-0.6B --local-dir ~/models/Qwen3-0.6B

# 3. Activate the vLLM env
source /etc/profile.d/tt-env-vllm.sh
python -c "import torch, vllm; print('torch', torch.__version__, 'vllm', vllm.__version__)"

# 4. Activate the Forge env
source /etc/profile.d/tt-env-forge.sh
python -c "import forge; print('Forge-ONNX ok')"
```

## Build-time Customisation

| Build arg | Default | Description |
|---|---|---|
| `TT_METAL_BUILD` | `checkout` | `checkout` (clone only), `full` (compile), or `sim` (compile + ttsim binaries) |
| `TTSIM_VERSION` | `latest` | ttsim release tag (`latest` or e.g. `v1.7.0`). Only used in `sim` mode |
| `TT_METAL_COMMIT` | pinned SHA | tt-metal commit to check out |
| `VLLM_BRANCH` | `dev` | Tenstorrent vLLM branch to track |
| `DEV_USER` | `dev` | Username inside the container |

Example — full build with a different tt-metal commit:

```bash
docker build \
  --build-arg TT_METAL_BUILD=full \
  --build-arg TT_METAL_COMMIT=<sha> \
  -t tenstorrent/dev:full \
  docker/
```

## Notes

- **code-server default password** is `tenstorrent`.  Always override with `-e PASSWORD=…`.
  The tt-vscode-toolkit extension is pre-installed; verify with
  `code-server --list-extensions` inside the container.
- **vLLM in checkout mode** — `pip install -e .` is skipped in checkout mode because
  the TT vLLM fork depends on compiled tt-metal Python extensions.  Run
  `bash /tmp/setup_envs.sh vllm` inside the container after building tt-metal.
- **Forge packages** — `tt_forge_onnx` is fetched from public GitHub Releases;
  `pjrt_plugin_tt` (TT-XLA PJRT backend) comes from `ghcr.io/tenstorrent/tt-xla-slim`
  via a multi-stage build.  No internal Tenstorrent network access needed.

## Publishing to GHCR (manual)

Build on QB2 and push with a GitHub PAT (`write:packages` scope):

```bash
# Build
cd docker
docker build --build-arg TT_METAL_BUILD=sim \
             --build-arg TTSIM_VERSION=v1.7.0 \
             -t ghcr.io/tsingletary/tt-developer-image:sim-wh .

# Login and push
echo $GH_PAT | docker login ghcr.io -u tsingletary --password-stdin
docker push ghcr.io/tsingletary/tt-developer-image:sim-wh

# Also push a bh-default tag (same image, communicates default arch)
docker tag ghcr.io/tsingletary/tt-developer-image:sim-wh \
           ghcr.io/tsingletary/tt-developer-image:sim-bh
docker push ghcr.io/tsingletary/tt-developer-image:sim-bh
```

To make the package public after pushing: GitHub → your profile → Packages → tt-developer-image → Package settings → Change visibility → Public.

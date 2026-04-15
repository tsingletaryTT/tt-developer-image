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

Pass `TT_METAL_ARCH_NAME=blackhole` at `docker run`.  Every env script reads this
and exports it, so all three venvs get the correct arch automatically.

```bash
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  -e TT_METAL_ARCH_NAME=blackhole \
  tenstorrent/dev:latest bash
```

For a QuietBox 2 with four P300c cards:

```bash
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  -e TT_METAL_ARCH_NAME=blackhole \
  -e MESH_DEVICE=P100 \
  tenstorrent/dev:latest bash
```

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
python -c "import tt_forge_onnx; print('Forge-ONNX ok')"
```

## Build-time Customisation

| Build arg | Default | Description |
|---|---|---|
| `TT_METAL_BUILD` | `checkout` | `checkout` (clone only) or `full` (compile) |
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

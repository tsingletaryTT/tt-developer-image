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
  internal version matrix (tt-metal + vLLM) for maximum "no version hell".

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

# Run – interactive shell (replace device/hugepages paths for your host)
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  tenstorrent/dev-n150:latest \
  bash

# Run – browser-based VS Code (code-server) at http://localhost:8080
docker run -d \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  -p 8080:8080 \
  -e PASSWORD=your-password \
  tenstorrent/dev-n150:latest \
  code-server --bind-addr 0.0.0.0:8080 --auth password \
              --disable-telemetry --disable-update-check

# Inside container (interactive shell):

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
- **code-server default password** is `tenstorrent`. Always override with
  `-e PASSWORD=…` in production. The tt-vscode-toolkit extension is
  pre-installed; verify with `code-server --list-extensions` inside the container.
- You can adjust versions/commits by editing:
  - `TT_METAL_COMMIT` in `Dockerfile`
  - `FORGE_VERSION` in `setup_envs.sh`
  - `VLLM_COMMIT` and `TORCH_*` pins in `setup_envs.sh`
  - To pin the tt-vscode-toolkit version, replace the GitHub API call in
    the Dockerfile with a hard-coded release URL (see inline comment).

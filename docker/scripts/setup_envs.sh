#!/bin/bash
# setup_envs.sh
#
# Configures either the vLLM or Forge Python virtualenv.
#
# Usage:
#   ./setup_envs.sh vllm    # installs torch 2.5.0+cpu + Tenstorrent vLLM
#   ./setup_envs.sh forge   # installs tt-forge from Tenstorrent private PyPI
#
# Called by the Dockerfile in two separate RUN steps so Docker can cache each
# env layer independently.
#
# Forge approach mirrors tt-code-server (github.com/tenstorrent/tt-code-server):
#   pip install tt-forge --extra-index-url https://pypi.eng.aws.tenstorrent.com/
#   tt-forge-install   # post-install: downloads metalium backend native libs

set -euo pipefail

TARGET="${1:-}"

if [[ "$TARGET" != "vllm" && "$TARGET" != "forge" ]]; then
  echo "Usage: $0 {vllm|forge}"
  exit 1
fi

# ---------------------------------------------------------------------------
# vLLM env: torch 2.5.0+cpu + Tenstorrent vLLM fork
# ---------------------------------------------------------------------------
if [[ "$TARGET" == "vllm" ]]; then
  VENV=/opt/venv-vllm
  echo ">>> Configuring vLLM env at $VENV"

  source "${VENV}/bin/activate"

  # 1. PyTorch 2.5.0 (CPU-only build) and matching torchvision / torchaudio.
  #    CPU-only keeps the image size manageable; tt-metal handles the actual
  #    device execution path independently of PyTorch's GPU backends.
  echo ">>> Installing torch 2.5.0+cpu stack"
  pip install --quiet --index-url https://download.pytorch.org/whl/cpu \
    torch==2.5.0+cpu \
    torchvision==0.20.0 \
    torchaudio==2.5.0

  # 2. Core Python packages that the Tenstorrent vLLM fork depends on.
  #    Pinning these prevents drift when pip resolves transitive deps.
  #    huggingface-hub is included here so `hf auth login` / `hf download`
  #    work from within the vLLM env for model management.
  echo ">>> Installing core vLLM dependencies"
  pip install --quiet \
    fairscale \
    termcolor \
    loguru \
    blobfile \
    fire \
    pytz \
    huggingface-hub

  # 3. Install the Tenstorrent vLLM fork from the cloned repo in editable
  #    mode so DX developers can iterate without reinstalling.
  echo ">>> Installing vLLM (editable) from ~/tt-vllm"
  cd "$HOME/tt-vllm"
  pip install --quiet -e .

  # 4. Smoke test
  python - << 'EOF'
import torch, vllm
print("vLLM OK - torch:", torch.__version__, "vllm:", getattr(vllm, "__version__", "unknown"))
EOF

  deactivate
  echo ">>> vLLM env setup complete"

# ---------------------------------------------------------------------------
# Forge env: tt-forge from Tenstorrent private PyPI (Python 3.12)
# ---------------------------------------------------------------------------
# Mirrors the approach used by tt-code-server (github.com/tenstorrent/tt-code-server):
#   1. pip install tt-forge from the Tenstorrent internal PyPI index.
#      The tt-forge wheel bundles the TT-Forge compiler, TT-XLA PJRT plugin,
#      and JAX/PyTorch integration layers — no separate JAX version-pinning needed.
#   2. Run tt-forge-install to complete post-install setup (downloads the
#      tt-metalium backend native libraries the compiler delegates to at runtime).
#
# Note: tt-installer handles forge differently — it creates a wrapper script
# that runs tt-xla-slim as a Docker container (container-in-container).
# For a developer image where forge should be a native Python environment,
# the pip install approach is the right choice.
elif [[ "$TARGET" == "forge" ]]; then
  VENV=/opt/venv-forge

  echo ">>> Configuring Forge env at $VENV (Python 3.12)"
  echo ">>> Installing tt-forge from Tenstorrent private PyPI"

  source "${VENV}/bin/activate"

  pip install --upgrade pip

  # Install tt-forge (cp312, nightly).  The private PyPI index ships daily builds;
  # pip resolves the latest compatible version automatically.
  pip install tt-forge \
    --extra-index-url https://pypi.eng.aws.tenstorrent.com/

  # Post-install helper: downloads and configures the tt-metalium backend that
  # the forge compiler uses at runtime.  Safe to re-run if the backend needs
  # refreshing.
  tt-forge-install

  # -------------------------------------------------------------------------
  # Smoke tests
  # tt-forge (private PyPI) = TT-XLA stack: pjrt_plugin_tt + JAX + torch-xla.
  # The importable modules are pjrt_plugin_tt (TT PJRT backend) and jax.
  # There is no top-level 'forge' module in this package — that would require
  # tt-forge-onnx (ONNX bridge) or tt-forge-fe (compiler frontend, cp311-only).
  echo ">>> Running forge smoke tests (pjrt_plugin_tt + JAX + torch-xla)"
  python3 -c "
import pjrt_plugin_tt
import jax
import torch_xla
print('pjrt_plugin_tt OK (TT PJRT backend)')
print('jax OK:', jax.__version__)
print('torch_xla OK:', torch_xla.__version__)
"

  deactivate
  echo ">>> Forge env setup complete"
fi

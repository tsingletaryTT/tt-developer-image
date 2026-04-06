#!/bin/bash
# setup_envs.sh
#
# Configures either the vLLM or Forge Python virtualenv.
#
# Usage:
#   ./setup_envs.sh vllm    # installs torch 2.5.0+cpu + Tenstorrent vLLM
#   ./setup_envs.sh forge   # installs tt-forge / tt-forge-onnx / pjrt-plugin-tt 0.8.0
#
# Called by the Dockerfile in two separate RUN steps so Docker can cache each
# env layer independently.

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
  echo ">>> Installing core vLLM dependencies"
  pip install --quiet \
    fairscale \
    termcolor \
    loguru \
    blobfile \
    fire \
    pytz

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
# Forge env: tt-forge + tt-forge-onnx + pjrt-plugin-tt 0.8.0
# ---------------------------------------------------------------------------
elif [[ "$TARGET" == "forge" ]]; then
  VENV=/opt/venv-forge
  # Pinned version for the entire Forge / XLA stack.
  # Bump this together with TT_METAL_COMMIT when upgrading.
  FORGE_VERSION=0.8.0

  echo ">>> Configuring Forge env at $VENV (version $FORGE_VERSION)"

  source "${VENV}/bin/activate"

  # Install the three Forge wheels from the Tenstorrent internal PyPI mirror.
  # Package names:
  #   tt-forge        – meta wheel + compiler frontends
  #   tt_forge_onnx   – ONNX → tt-forge bridge
  #   pjrt-plugin-tt  – JAX / XLA PJRT plugin for Tenstorrent hardware
  #
  # NOTE: If the internal index URL changes, update --extra-index-url here
  # and in any CI pipeline that rebuilds this image.
  echo ">>> Installing TT-Forge ${FORGE_VERSION} stack"
  pip install --quiet \
    tt-forge==${FORGE_VERSION} \
    tt_forge_onnx==${FORGE_VERSION} \
    pjrt-plugin-tt==${FORGE_VERSION} \
    --extra-index-url https://pypi.eng.aws.tenstorrent.com/

  # Optional: uncomment to add JAX + torch-xla if your workflows need them.
  # Pin versions carefully to avoid dependency conflicts with the TT XLA plugin.
  # pip install --quiet jax==0.6.0 jaxlib==0.6.0 torch==2.7.0 torch-xla==2.7.0

  # Smoke tests: check each wheel can be imported
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

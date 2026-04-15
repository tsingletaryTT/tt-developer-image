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
# Forge env: tt-forge-onnx (GitHub Releases) + JAX 0.7.1 (PyPI)
# ---------------------------------------------------------------------------
# pjrt_plugin_tt (the TT-XLA PJRT backend) is NOT installed here.
# It is injected by the Dockerfile via COPY --from=tt-xla-slim before this
# script runs, so it will already be present in the venv's site-packages.
# We install JAX here to match the version the plugin was compiled against.
elif [[ "$TARGET" == "forge" ]]; then
  VENV=/opt/venv-forge

  echo ">>> Configuring Forge env at $VENV (Python 3.12)"

  source "${VENV}/bin/activate"

  # -------------------------------------------------------------------------
  # 1. JAX 0.7.1 + jaxlib 0.7.1
  #    Must match the version bundled in ghcr.io/tenstorrent/tt-xla-slim:latest
  #    from which pjrt_plugin_tt was compiled.  Mismatched JAX/jaxlib versions
  #    will cause import errors or silent runtime failures.
  #    ml_dtypes and opt_einsum are required transitive deps of jax.
  echo ">>> Installing JAX 0.7.1 (matches tt-xla-slim)"
  pip install --quiet \
    jax==0.7.1 \
    jaxlib==0.7.1 \
    ml_dtypes \
    opt_einsum \
    loguru   # required by ttxla_tools.logging, which pjrt_plugin_tt imports at module level

  # Note on pjrt_plugin_tt deps:
  #   pjrt_plugin_tt-1.0.0.dist-info declares many runtime deps (torch, torch-xla,
  #   click, pandas, etc.) that pip's resolver will warn about as missing.
  #   These warnings are cosmetic here: pjrt_plugin_tt/__init__.py only imports
  #   `ttxla_tools.logging` at module level (no torch, no torch-xla), so
  #   `import pjrt_plugin_tt` works fine without them.  The full dep set is
  #   only needed when using the plugin with PyTorch/XLA at runtime.

  # -------------------------------------------------------------------------
  # 2. TT-Forge-ONNX wheels from GitHub Releases (cp312, latest nightly).
  #    The tt-forge-onnx repo ships two wheels per release:
  #      tt_forge_onnx  – ONNX → TT-Forge compiler bridge
  #      tt_tvm         – TVM runtime pinned to the forge release
  #
  #    We query the GitHub API for the latest release and install all .whl
  #    assets whose filename contains "cp312".  If the release structure
  #    changes, inspect:
  #      https://github.com/tenstorrent/tt-forge-onnx/releases/latest
  echo ">>> Fetching latest tt-forge-onnx release wheels (cp312)"

  # Note: do NOT use a heredoc (<<) here — inside $(...), a heredoc redirects
  # python3's stdin, which conflicts with the curl pipe and produces empty JSON.
  # Single-quoted -c '...' is the safe alternative.
  ONNX_WHEEL_URLS=$(curl -fsSL \
    https://api.github.com/repos/tenstorrent/tt-forge-onnx/releases/latest \
    | python3 -c '
import sys, json
data = json.load(sys.stdin)
assets = data.get("assets", [])
urls = [
    a["browser_download_url"]
    for a in assets
    if "cp312" in a["name"] and a["name"].endswith(".whl")
]
if not urls:
    print(
        "ERROR: no cp312 .whl assets found in latest tt-forge-onnx release.\n"
        "Check: https://github.com/tenstorrent/tt-forge-onnx/releases/latest",
        file=sys.stderr,
    )
    sys.exit(1)
print("\n".join(urls))
')

  echo ">>> Wheels to install:"
  echo "$ONNX_WHEEL_URLS"

  # Install each wheel URL on its own pip invocation to get clear error output
  # if one fails.  shellcheck disable=SC2086 is intentional: we want splitting.
  while IFS= read -r url; do
    pip install --quiet "$url"
  done <<< "$ONNX_WHEEL_URLS"

  # -------------------------------------------------------------------------
  # Smoke tests
  echo ">>> Running forge env smoke tests"

  # tt_forge_onnx: installed from GitHub Releases above.
  python3 -c "
import tt_forge_onnx as fonnx
print('TT-Forge-ONNX OK:', fonnx.__name__)
"

  # pjrt_plugin_tt: injected by Dockerfile COPY --from=tt-xla-slim.
  # If this fails, the COPY step likely didn't land correctly.
  python3 -c "
import pjrt_plugin_tt
print('pjrt_plugin_tt OK:', pjrt_plugin_tt.__name__)
"

  deactivate
  echo ">>> Forge env setup complete"
fi

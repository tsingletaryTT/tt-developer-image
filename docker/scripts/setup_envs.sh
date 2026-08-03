#!/bin/bash
# setup_envs.sh
#
# Configures either the vLLM or Forge Python virtualenv.
#
# Usage:
#   ./setup_envs.sh vllm    # installs base vLLM + the Tenstorrent vLLM plugin
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
# vLLM env: upstream vLLM + the Tenstorrent vLLM platform plugin
# ---------------------------------------------------------------------------
# Tenstorrent support is not a patched vLLM build. It is an out-of-tree vLLM
# *platform plugin*, and its official home is now the standalone repository:
#
#   https://github.com/tenstorrent/vllm-tt-plugin
#
# That plugin works against *upstream* vLLM — no Tenstorrent fork involved. Its
# own installer is the supported entry point, run from a checkout with a recent
# tt-metal python env active:
#
#   source docs/install-vllm-tt.sh
#
# which does:
#   VLLM_TARGET_DEVICE=empty uv pip install --no-binary vllm \
#       --override docs/vllm-overrides.txt vllm==0.24.0
#   uv pip uninstall torchaudio    # CUDA wheel; transformers>=5.12 imports it if present
#   uv pip install -e .
#
# Two details worth knowing, both load-bearing:
#   * VLLM_TARGET_DEVICE=empty — the `tt` platform is contributed at runtime by
#     the plugin, not compiled into vLLM, so the build target is "empty", never "tt".
#   * docs/vllm-overrides.txt holds numpy<2 + opencv-python-headless==4.11.0.86.
#     ttnn pins numpy<2 while vLLM's opencv floor wants numpy>=2; without the
#     override the install rewrites numpy and `import ttnn` then fails.
#
# The plugin registers two vLLM entry points and selects the TT platform only
# when `ttnn` is importable:
#
#   vllm.platform_plugins  tt                -> vllm_tt_plugin.entrypoints:platform_plugin
#   vllm.general_plugins   tt_model_registry -> vllm_tt_plugin.entrypoints:register
#
# That `ttnn` gate is the subtle part for this image. Upstream assumes you install
# into the tt-metal env itself; this image keeps a separate venv to mirror the QB2
# layout, so ttnn must be wired in explicitly. Without it the plugin installs
# cleanly and then silently never activates — vLLM starts and reports no TT
# hardware. We wire ttnn and *fail the build* if we cannot.
if [[ "$TARGET" == "vllm" ]]; then
  # Allow callers to override — Dockerfile.qb2 sets this to
  # ~/tt-metal/build/python_env_vllm/ to match the QB2 layout.
  VENV=${VENV_VLLM:-/opt/venv-vllm}
  # Standalone plugin checkout. VLLM_TT_PLUGIN_SRC is the current knob; VLLM_SRC
  # is still honoured so existing callers keep working.
  PLUGIN_SRC=${VLLM_TT_PLUGIN_SRC:-${VLLM_SRC:-$HOME/vllm-tt-plugin}}
  TT_METAL_ROOT=${TT_METAL_HOME:-$HOME/tt-metal}
  echo ">>> Configuring vLLM env at $VENV"
  echo ">>> TT vLLM plugin source: $PLUGIN_SRC"

  source "${VENV}/bin/activate"

  # 1. Tooling. uv is what upstream's installer uses, and it resolves this
  #    dependency set far more reliably than pip. huggingface-hub is here so
  #    `hf auth login` / `hf download` work from inside the vLLM env.
  echo ">>> Installing build tooling and huggingface-hub"
  pip install --quiet --upgrade pip setuptools wheel uv
  pip install --quiet huggingface-hub

  # 2. Make ttnn and the tt-metal model tree reachable. The plugin activates only
  #    when `ttnn` imports, and it registers its model classes by dotted path into
  #    `models.*` — so BOTH have to resolve. There are two ways to get there.
  #
  #    Wheel mode (TTNN_WHEEL_VERSION set — used by Dockerfile.latest-metal):
  #      Install the published `ttnn==<version>` wheel for the compiled runtime and
  #      put ONLY the tt-metal source root on sys.path for `models/`. The wheel does
  #      not ship `models/` (verified: its top level is ttnn, tt_lib, tracy, triage),
  #      so the source checkout is still required — but nothing has to be compiled.
  #
  #      The .pth deliberately omits <root>/ttnn. That directory has no __init__.py,
  #      so listing it would register a namespace portion for `ttnn`. Python still
  #      prefers a real package found later on the path, so the wheel wins either
  #      way — but leaving it out removes the ambiguity entirely.
  #
  #    Source mode (default): the tt-metal tree supplies ttnn as well, which is what
  #      a real QB2 does via its own ttnn-custom.pth. Requires a compiled tt-metal.
  SITE_PACKAGES=$(python -c "import sysconfig; print(sysconfig.get_paths()['purelib'])")

  if [[ -n "${TTNN_WHEEL_VERSION:-}" ]]; then
    echo ">>> Wheel mode: installing ttnn==${TTNN_WHEEL_VERSION}"
    pip install --quiet "ttnn==${TTNN_WHEEL_VERSION}"

    if [[ ! -d "$TT_METAL_ROOT/models" ]]; then
      echo "!!! $TT_METAL_ROOT/models is missing."
      echo "!!! The ttnn wheel does not ship the model implementations the plugin"
      echo "!!! registers, so a tt-metal source checkout at the matching tag is"
      echo "!!! still required. Check out tt-metal at the same release tag."
      exit 1
    fi
    echo ">>> Wiring $TT_METAL_ROOT (models only) via tt-metal-models.pth"
    printf '%s\n' "$TT_METAL_ROOT" > "${SITE_PACKAGES}/tt-metal-models.pth"

  elif ! python -c "import ttnn" >/dev/null 2>&1; then
    if [[ -d "$TT_METAL_ROOT/ttnn" ]]; then
      echo ">>> Source mode: wiring $TT_METAL_ROOT via ttnn-custom.pth"
      cat > "${SITE_PACKAGES}/ttnn-custom.pth" <<PTH
${TT_METAL_ROOT}
${TT_METAL_ROOT}/ttnn
${TT_METAL_ROOT}/tools
PTH
    else
      echo "!!! ttnn is not importable and $TT_METAL_ROOT/ttnn does not exist."
      echo "!!! The TT plugin activates only when ttnn imports, so vLLM would"
      echo "!!! start without TT hardware. Either build tt-metal"
      echo "!!! (TT_METAL_BUILD=full) or use wheel mode:"
      echo "!!!   TTNN_WHEEL_VERSION=<x.y.z> bash $0 vllm"
      exit 1
    fi
  fi

  # 3. Install upstream vLLM + the plugin, via the plugin's own installer.
  #
  #    torch is deliberately NOT pinned here. The old torch==2.5.0+cpu pin
  #    predates the plugin and conflicts with what vllm==0.24.0 resolves.
  if [[ ! -f "$PLUGIN_SRC/docs/install-vllm-tt.sh" ]]; then
    echo "!!! No installer at $PLUGIN_SRC/docs/install-vllm-tt.sh"
    echo "!!! Expected a checkout of https://github.com/tenstorrent/vllm-tt-plugin"
    echo "!!! Clone it, or point VLLM_TT_PLUGIN_SRC at an existing checkout:"
    echo "!!!   git clone https://github.com/tenstorrent/vllm-tt-plugin.git $PLUGIN_SRC"
    echo "!!!"
    echo "!!! Note: the old in-fork plugin under tenstorrent/vllm's dev branch at"
    echo "!!! plugins/vllm-tt-plugin is being retired in favour of this repo."
    exit 1
  fi

  cd "$PLUGIN_SRC"
  echo ">>> Installing via upstream docs/install-vllm-tt.sh"
  # shellcheck disable=SC1091
  source docs/install-vllm-tt.sh

  # ttnn and the tt-metal model tree need a few packages that neither upstream
  # vLLM nor the plugin declares. Upstream sidesteps this by installing into the
  # tt-metal env, which already has them; this image's separate venv does not.
  # All three failures below were hit for real during validation:
  #   pandas/seaborn/ml_dtypes/graphviz  ttnn's tracy tooling imports them, and a
  #                                      miss surfaces as an opaque
  #                                      "error while initializing the extension"
  #   torchvision                        transformers' pixtral image processor
  #                                      imports it while vLLM inspects the TT
  #                                      model class
  #   pytest                             models/common/utility_functions.py in
  #                                      tt-metal imports it at module scope
  echo ">>> Installing ttnn + tt-metal model-tree dependencies"
  uv pip install --override docs/vllm-overrides.txt \
    pandas seaborn ml_dtypes graphviz networkx click loguru pyyaml pytest
  uv pip install --override docs/vllm-overrides.txt \
    --extra-index-url https://download.pytorch.org/whl/cpu \
    --index-strategy unsafe-best-match torchvision

  # 4. Verify the plugin is actually discoverable. Import success alone is not
  #    enough — the entry points must be registered, or vLLM will never select
  #    the TT platform.
  echo ">>> Verifying plugin discovery"
  python - <<'EOF'
import sys
from importlib.metadata import entry_points

import numpy
import torch
import vllm
import ttnn
import vllm_tt_plugin

# The plugin registers model classes by dotted path into `models.*`. In wheel mode
# ttnn and models come from different places, so prove both resolve.
import models.tt_transformers.tt.generator_vllm as _gen

print("  numpy          ", numpy.__version__)
print("  torch          ", torch.__version__)
print("  vllm           ", getattr(vllm, "__version__", "unknown"))
# ttnn does not expose __version__; read it from installed distribution metadata.
try:
    from importlib.metadata import version as _dist_version
    _ttnn_ver = _dist_version("ttnn")
except Exception:
    _ttnn_ver = "unknown"
print("  ttnn           ", _ttnn_ver)
print("  vllm_tt_plugin ", vllm_tt_plugin.__file__)
print("  ttnn origin    ", ttnn.__file__)
print("  models origin  ", _gen.__file__)

# ttnn requires numpy<2; a 2.x resolve here means the override did not apply and
# ttnn would fail to import on some paths even if it happened to work above.
if int(numpy.__version__.split(".")[0]) >= 2:
    print("  numpy >= 2 but ttnn requires <2 -- override did not apply", file=sys.stderr)
    raise SystemExit(1)

expected = {
    ("vllm.platform_plugins", "tt"),
    ("vllm.general_plugins", "tt_model_registry"),
}
found = {
    (group, ep.name)
    for group in ("vllm.platform_plugins", "vllm.general_plugins")
    for ep in entry_points(group=group)
}
missing = expected - found
if missing:
    print("  MISSING entry points:", sorted(missing), file=sys.stderr)
    raise SystemExit(1)
for group, name in sorted(expected):
    print(f"  entry point OK  {group} -> {name}")
print("vLLM + TT plugin OK")
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
  # Allow callers to override — Dockerfile.qb2 sets this to ~/tt-forge-venv/
  # to match the QB2 post-tt-installer layout.
  VENV=${VENV_FORGE:-/opt/venv-forge}

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

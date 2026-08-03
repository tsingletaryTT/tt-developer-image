#!/usr/bin/env bash
# qb2_smoke.sh — assert a built QB2 image matches the post-tt-installer QB2
# layout. Checkout mode only (no compiled TTNN); does not need hardware.
#
# Usage: qb2_smoke.sh <image-tag>
set -euo pipefail

IMG="${1:?usage: qb2_smoke.sh <image-tag>}"

# Filesystem/identity checks run in a plain login shell.
run() { docker run --rm "$IMG" bash -lc "$1"; }
# Env checks that depend on ~/.bashrc need an interactive shell (Ubuntu's
# ~/.bashrc returns early for non-interactive shells; the QB2 arch export
# lives past that guard, so a real user only gets it interactively).
run_i() { docker run --rm "$IMG" bash -ic "$1" 2>/dev/null; }

echo "== user identity =="
run '[ "$(id -un)" = ttuser ] && [ "$(id -u)" = 1000 ] && echo "user ttuser/1000 OK"'

# metal + vllm venvs are required in every image. venv-forge is optional: the
# latest-metal variant is deliberately scoped to metal + vLLM and ships no Forge.
echo "== QB2 venv paths =="
run 'for p in "$HOME/tt-metal/python_env" "$HOME/tt-metal/build/python_env_vllm"; do
       test -d "$p" || { echo "MISSING required venv: $p"; exit 1; }
     done
     test -d "$HOME/tt-forge-venv" \
       && echo "venv paths OK (incl. forge)" \
       || echo "venv paths OK (no forge - expected on the latest-metal variant)"'

echo "== PATH symlinks (tt-smi, hf) =="
run 'test -L "$HOME/.local/bin/tt-smi" && test -L "$HOME/.local/bin/hf" && \
     "$HOME/.local/bin/tt-smi" --help >/dev/null 2>&1 && \
     "$HOME/.local/bin/hf" --version >/dev/null 2>&1 && echo "tt-smi + hf OK"'

echo "== arch var (blackhole) in interactive shell =="
[ "$(run_i 'printf %s "$TT_METAL_ARCH_NAME"')" = "blackhole" ] \
  && echo "TT_METAL_ARCH_NAME=blackhole OK" \
  || { echo "ERROR: TT_METAL_ARCH_NAME not blackhole"; exit 1; }

# tt-metal and the plugin are required. tt-inference-server is optional for the
# same reason as forge.
echo "== source trees present =="
run 'test -d "$HOME/tt-metal" || { echo "MISSING $HOME/tt-metal"; exit 1; }
     test -d "$HOME/vllm-tt-plugin" || { echo "MISSING $HOME/vllm-tt-plugin"; exit 1; }
     test -d "$HOME/.local/lib/tt-inference-server" \
       && echo "source trees OK (incl. tt-inference-server)" \
       || echo "source trees OK (no tt-inference-server - expected on the latest-metal variant)"'

# The standalone plugin checkout must be present and carry its installer. Its
# docs/vllm-overrides.txt is load-bearing: it holds numpy<2 (ttnn's requirement)
# against vLLM's opencv floor, and without it `import ttnn` breaks after install.
echo "== TT vLLM plugin checkout =="
run 'test -d "$HOME/vllm-tt-plugin" \
       || { echo "MISSING $HOME/vllm-tt-plugin (clone tenstorrent/vllm-tt-plugin)"; exit 1; }
     test -f "$HOME/vllm-tt-plugin/docs/install-vllm-tt.sh" \
       || { echo "MISSING docs/install-vllm-tt.sh in the plugin checkout"; exit 1; }
     test -f "$HOME/vllm-tt-plugin/docs/vllm-overrides.txt" \
       || echo "  note: docs/vllm-overrides.txt absent; check the numpy<2 pin still applies"
     echo "TT plugin checkout OK"'

# Checkout-mode images deliberately skip the pip install (no compiled ttnn), so a
# missing vllm_tt_plugin is expected there and only reported. When the install did
# run, both entry points must be registered or the TT platform is never selected.
echo "== vLLM plugin discovery (informational in checkout mode) =="
run 'V="$HOME/tt-metal/build/python_env_vllm"
     if "$V/bin/python" -c "import vllm_tt_plugin" >/dev/null 2>&1; then
       "$V/bin/python" - <<'"'"'PY'"'"'
import sys
from importlib.metadata import entry_points
expected = {("vllm.platform_plugins", "tt"),
            ("vllm.general_plugins", "tt_model_registry")}
found = {(g, e.name) for g in ("vllm.platform_plugins", "vllm.general_plugins")
         for e in entry_points(group=g)}
missing = expected - found
if missing:
    print("MISSING entry points:", sorted(missing)); sys.exit(1)
print("plugin entry points registered OK")
PY
     else
       echo "vllm_tt_plugin not installed (expected in checkout mode)"
     fi'

# The latest-metal variant records what it resolved to in ~/.metal-release.env.
# When present, assert the installed ttnn actually matches the tag the image says
# it built from — a wheel/source mismatch shows up as confusing model-level
# misbehaviour rather than a clean import error.
echo "== latest-metal variant: tag/ttnn agreement (skipped on pinned images) =="
run 'if [ -f "$HOME/.metal-release.env" ]; then
       . "$HOME/.metal-release.env"
       echo "  image resolved: $TT_METAL_TAG (ttnn $TTNN_VERSION)"
       SRC_TAG=$(git -C "$HOME/tt-metal" describe --tags 2>/dev/null || echo "")
       [ "$SRC_TAG" = "$TT_METAL_TAG" ] || { echo "MISMATCH: source tree $SRC_TAG != $TT_METAL_TAG"; exit 1; }
       V="$HOME/tt-metal/build/python_env_vllm"
       INSTALLED=$("$V/bin/pip" show ttnn 2>/dev/null | awk "/^Version:/{print \$2}")
       [ "$INSTALLED" = "$TTNN_VERSION" ] || { echo "MISMATCH: installed ttnn $INSTALLED != $TTNN_VERSION"; exit 1; }
       "$V/bin/python" -c "
import ttnn, models.tt_transformers.tt.generator_vllm as g
assert \"site-packages\" in ttnn.__file__, ttnn.__file__
assert \"tt-metal\" in g.__file__, g.__file__
print(\"  ttnn from wheel, models from source: OK\")
" || exit 1
       echo "latest-metal agreement OK"
     else
       echo "no ~/.metal-release.env (pinned image) - skipped"
     fi'

echo "ALL QB2 SMOKE CHECKS PASSED"

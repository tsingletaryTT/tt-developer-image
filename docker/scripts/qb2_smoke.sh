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

echo "== QB2 venv paths =="
run 'for p in "$HOME/tt-metal/python_env" "$HOME/tt-metal/build/python_env_vllm" "$HOME/tt-forge-venv"; do
       test -d "$p" || { echo "MISSING venv: $p"; exit 1; }
     done; echo "venv paths OK"'

echo "== PATH symlinks (tt-smi, hf) =="
run 'test -L "$HOME/.local/bin/tt-smi" && test -L "$HOME/.local/bin/hf" && \
     "$HOME/.local/bin/tt-smi" --help >/dev/null 2>&1 && \
     "$HOME/.local/bin/hf" --version >/dev/null 2>&1 && echo "tt-smi + hf OK"'

echo "== arch var (blackhole) in interactive shell =="
[ "$(run_i 'printf %s "$TT_METAL_ARCH_NAME"')" = "blackhole" ] \
  && echo "TT_METAL_ARCH_NAME=blackhole OK" \
  || { echo "ERROR: TT_METAL_ARCH_NAME not blackhole"; exit 1; }

echo "== source trees present =="
run 'test -d "$HOME/tt-metal" && test -d "$HOME/tt-vllm" && \
     test -d "$HOME/.local/lib/tt-inference-server" && echo "source trees OK"'

echo "ALL QB2 SMOKE CHECKS PASSED"

#!/bin/bash
# build_tt_metal.sh
#
# Build tt-metal from source and install Python bindings into /opt/venv-metal.
#
# Assumptions:
#   - TT_METAL_HOME is set (or defaults to ~/tt-metal)
#   - /opt/venv-metal already exists (created by Dockerfile venv setup step)
#   - Running as the dev user with sudo rights if needed

set -euo pipefail

TT_METAL_HOME=${TT_METAL_HOME:-"$HOME/tt-metal"}
VENV_METAL=/opt/venv-metal

echo ">>> Building tt-metal from source at $TT_METAL_HOME"
cd "$TT_METAL_HOME"

# Optional: clean previous builds for a pristine image layer
# Uncomment if you need a fully reproducible build from scratch:
# rm -rf build build_Release

# FULL BUILD:
# - Builds firmware, C++ libs, TTNN, and all tools
# - This is intentionally the full build; faster/partial builds can be
#   done by hand inside the container during development
./build_metal.sh

# Activate /opt/venv-metal and install tt-metal in editable mode so that
# developers can modify source files and have changes reflected immediately
# without re-installing the package.
source "${VENV_METAL}/bin/activate"

pip install --upgrade pip

# Editable install: changes to Python source in TT_METAL_HOME are live
pip install -e .

# Optional: install any extras from the tt-metal wheel or requirements files
# that may not be pulled in automatically (adjust as upstream evolves).
# pip install -r requirements.txt

# Smoke test: confirm TTNN can be imported before declaring success
python - << 'EOF'
import ttnn
print("TTNN import OK, version:", getattr(ttnn, "__version__", "unknown"))
EOF

deactivate

echo ">>> tt-metal build and Python install complete"

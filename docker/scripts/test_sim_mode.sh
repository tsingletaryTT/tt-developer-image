#!/bin/bash
# Smoke test for TT_METAL_BUILD=sim image.
# Run inside the container:
#   docker run --rm <image> bash /tmp/test_sim_mode.sh
#
# Exits 0 if all checks pass, non-zero if any check fails.
# All checks always run; see the summary at the end for a full picture.
set -euo pipefail

PASS=0
FAIL=0

check() {
    local label="$1"
    local cmd="$2"
    if eval "$cmd" > /dev/null 2>&1; then
        echo "  PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $label"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== tt-sim-image smoke tests ==="
echo ""

# --- Profile script exists and is executable
check "tt-env-sim.sh exists" "test -f /etc/profile.d/tt-env-sim.sh"
check "tt-env-sim.sh is executable" "test -x /etc/profile.d/tt-env-sim.sh"

# --- ttsim binaries
check "libttsim_wh.so exists" "test -f ~/sim/wh/libttsim_wh.so"
check "libttsim_bh.so exists" "test -f ~/sim/bh/libttsim_bh.so"
check "wh soc_descriptor.yaml exists" "test -f ~/sim/wh/soc_descriptor.yaml"
check "bh soc_descriptor.yaml exists" "test -f ~/sim/bh/soc_descriptor.yaml"
check "libttsim_wh.so is an ELF shared lib" "file ~/sim/wh/libttsim_wh.so | grep -q 'shared object'"
check "libttsim_bh.so is an ELF shared lib" "file ~/sim/bh/libttsim_bh.so | grep -q 'shared object'"

# --- Env vars set correctly after sourcing tt-env-sim.sh
if ! source /etc/profile.d/tt-env-sim.sh 2>/dev/null; then
    echo "  FAIL  source /etc/profile.d/tt-env-sim.sh (file missing or has errors)"
    FAIL=$((FAIL + 1))
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    echo "  (Remaining env-var and import checks skipped — profile script absent)"
    echo ""
    exit 1
fi
check "SIMULATOR_MODE=1" "test \"$SIMULATOR_MODE\" = '1'"
check "TT_METAL_SLOW_DISPATCH_MODE=1" "test \"$TT_METAL_SLOW_DISPATCH_MODE\" = '1'"
check "TT_METAL_DISABLE_SFPLOADMACRO=1" "test \"$TT_METAL_DISABLE_SFPLOADMACRO\" = '1'"
check "TT_METAL_SIMULATOR points to wh .so" "test \"$TT_METAL_SIMULATOR\" = \"$HOME/sim/wh/libttsim_wh.so\""
check "TT_METAL_HOME set" "test -n \"$TT_METAL_HOME\""
check "TT_SIM_ARCH defaults to wh" "test \"$TT_SIM_ARCH\" = 'wh'"
check "TT_METAL_ARCH_NAME=wormhole_b0 (default)" "test \"$TT_METAL_ARCH_NAME\" = 'wormhole_b0'"
check "LD_LIBRARY_PATH includes tt-metal build/lib" "echo \"\$LD_LIBRARY_PATH\" | tr ':' '\n' | grep -q 'tt-metal/build/lib'"
check "venv-metal activated" "python -c 'import sys; assert \"/opt/venv-metal\" in sys.prefix'"

# --- TTNN importable in sim env
check "ttnn importable" "python -c 'import ttnn'"

# --- tt-sim and tt-sim-bh functions defined in ~/.bashrc
check "tt-sim function in .bashrc" "grep -q 'tt-sim()' ~/.bashrc"
check "tt-sim-bh function in .bashrc" "grep -q 'tt-sim-bh()' ~/.bashrc"

# --- tt-toplike available
check "tt-toplike in PATH" "which tt-toplike"

# --- code-server extension installed
check "tt-vscode-toolkit extension" "ls ~/.local/share/code-server/extensions/ | grep -q 'tenstorrent'"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

[ "$FAIL" -eq 0 ] || exit 1

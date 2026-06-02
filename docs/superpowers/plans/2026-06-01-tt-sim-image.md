# tt-sim-image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `TT_METAL_BUILD=sim` mode to the existing Dockerfile that builds tt-metal from source, downloads ttsim binaries, and wires up a `tt-sim` environment switcher — producing a hardware-free learning image publishable to GHCR.

**Architecture:** `sim` is a superset of `full`: the three existing `if [ "${TT_METAL_BUILD}" = "full" ]` conditionals are widened to also match `sim`, then two new sim-only conditional blocks are appended — one downloads the ttsim `.so` files + SOC descriptors, the other writes `tt-env-sim.sh` and the `tt-sim`/`tt-sim-bh` shell switchers. Both WH and BH live in separate subdirectories (`~/sim/wh/`, `~/sim/bh/`) because ttsim requires the `.so` and `soc_descriptor.yaml` to share a directory.

**Tech Stack:** Bash, Docker, ttsim v1.7.0+ (Apache 2.0 binary releases from GitHub), tt-metal (full C++ build)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `docker/Dockerfile` | Modify | Add `TTSIM_VERSION` arg; widen `full` conditionals to `sim`; add sim download + env blocks |
| `docker/scripts/test_sim_mode.sh` | Create | Smoke-test script run inside a built sim image to verify ttsim wiring |
| `docker/README.md` | Modify | Add `sim` build mode docs, Quick Start, GHCR pull instructions |

---

## Task 1: Write the sim mode smoke-test script

This is the "test" that proves the implementation works. Write it first so success criteria are explicit before touching the Dockerfile.

**Files:**
- Create: `docker/scripts/test_sim_mode.sh`

- [ ] **Step 1: Create the test script**

```bash
cat > /home/ttuser/code/tt-developer-image/docker/scripts/test_sim_mode.sh << 'SCRIPT'
#!/bin/bash
# Smoke test for TT_METAL_BUILD=sim image.
# Run inside the container:
#   docker run --rm <image> bash /tmp/test_sim_mode.sh
#
# Exits 0 if all checks pass, 1 on first failure.
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
source /etc/profile.d/tt-env-sim.sh
check "SIMULATOR_MODE=1" "test \"$SIMULATOR_MODE\" = '1'"
check "TT_METAL_SLOW_DISPATCH_MODE=1" "test \"$TT_METAL_SLOW_DISPATCH_MODE\" = '1'"
check "TT_METAL_DISABLE_SFPLOADMACRO=1" "test \"$TT_METAL_DISABLE_SFPLOADMACRO\" = '1'"
check "TT_METAL_SIMULATOR points to wh .so" "test \"$TT_METAL_SIMULATOR\" = \"$HOME/sim/wh/libttsim_wh.so\""
check "TT_METAL_HOME set" "test -n \"$TT_METAL_HOME\""
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
SCRIPT
chmod +x /home/ttuser/code/tt-developer-image/docker/scripts/test_sim_mode.sh
```

- [ ] **Step 2: Verify the script is valid bash (dry-run parse)**

```bash
bash -n /home/ttuser/code/tt-developer-image/docker/scripts/test_sim_mode.sh && echo "Syntax OK"
```
Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
cd /home/ttuser/code/tt-developer-image
git add docker/scripts/test_sim_mode.sh
git commit -m "test: add sim mode smoke-test script"
```

---

## Task 2: Add TTSIM_VERSION arg and widen `full` conditionals to also match `sim`

Three places in the Dockerfile gate behind `TT_METAL_BUILD = "full"`. All three need to also fire for `sim`.

**Files:**
- Modify: `docker/Dockerfile`

- [ ] **Step 1: Add `TTSIM_VERSION` build arg** immediately after the `TT_METAL_BUILD` arg (around line 224):

Find this block:
```dockerfile
ARG TT_METAL_BUILD=checkout
```

Add below it:
```dockerfile
# ttsim version to download. Use "latest" to track latest release, or pin
# to a specific tag (e.g. "v1.7.0") for reproducible sim builds.
ARG TTSIM_VERSION=latest
```

- [ ] **Step 2: Widen the `install_dependencies.sh` conditional** (around line 239):

Old:
```dockerfile
RUN if [ "${TT_METAL_BUILD}" = "full" ]; then \
      cd ${TT_METAL_HOME} && sudo ./install_dependencies.sh || true; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping install_dependencies.sh"; \
    fi
```

New:
```dockerfile
RUN if [ "${TT_METAL_BUILD}" = "full" ] || [ "${TT_METAL_BUILD}" = "sim" ]; then \
      cd ${TT_METAL_HOME} && sudo ./install_dependencies.sh || true; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping install_dependencies.sh"; \
    fi
```

- [ ] **Step 3: Widen the `build_tt_metal.sh` conditional** (around line 254):

Old:
```dockerfile
RUN if [ "${TT_METAL_BUILD}" = "full" ]; then \
      bash /tmp/build_tt_metal.sh; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping tt-metal compilation."; \
      echo "To build later inside the container: bash /tmp/build_tt_metal.sh"; \
    fi
```

New:
```dockerfile
RUN if [ "${TT_METAL_BUILD}" = "full" ] || [ "${TT_METAL_BUILD}" = "sim" ]; then \
      bash /tmp/build_tt_metal.sh; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping tt-metal compilation."; \
      echo "To build later inside the container: bash /tmp/build_tt_metal.sh"; \
    fi
```

- [ ] **Step 4: Widen the vLLM pip install conditional** (around line 287):

Old:
```dockerfile
RUN if [ "${TT_METAL_BUILD}" = "full" ]; then \
      bash /tmp/setup_envs.sh vllm; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping vLLM pip install."; \
      echo "Run: bash /tmp/setup_envs.sh vllm after building tt-metal inside the container."; \
    fi
```

New:
```dockerfile
RUN if [ "${TT_METAL_BUILD}" = "full" ] || [ "${TT_METAL_BUILD}" = "sim" ]; then \
      bash /tmp/setup_envs.sh vllm; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping vLLM pip install."; \
      echo "Run: bash /tmp/setup_envs.sh vllm after building tt-metal inside the container."; \
    fi
```

- [ ] **Step 5: Verify the Dockerfile parses (no syntax error)**

Docker's `--check` flag (BuildKit) validates syntax without building:
```bash
cd /home/ttuser/code/tt-developer-image/docker
docker build --check . 2>&1 | head -20
```
Expected: no errors (BuildKit may print warnings about cache but no `ERROR` lines)

- [ ] **Step 6: Commit**

```bash
cd /home/ttuser/code/tt-developer-image
git add docker/Dockerfile
git commit -m "feat(sim): add TTSIM_VERSION arg; widen full conditionals to also match sim"
```

---

## Task 3: Add ttsim binary download layer

New sim-only RUN block after the Forge env section (section 7b) but before section 8 (env wrapper scripts). The block creates `~/sim/wh/` and `~/sim/bh/` subdirectories, downloads the `.so` files, and copies the SOC descriptor YAMLs.

ttsim requires the `.so` and a file named exactly `soc_descriptor.yaml` to share a directory. Using subdirectories (one per arch) cleanly handles both WH and BH in the same image.

**Files:**
- Modify: `docker/Dockerfile`

- [ ] **Step 1: Add the ttsim download block**

Insert after the `7b. Pre-clone tt-forge demo repository` section (after the `RUN git clone --depth 1 https://github.com/tenstorrent/tt-forge.git` block, before the section 8 comment):

```dockerfile
# ---------------------------------------------------------------------------
# 7c. ttsim — hardware simulator binaries (sim mode only)
# ---------------------------------------------------------------------------
# ttsim provides a virtual Wormhole or Blackhole device that runs on x86_64
# Linux with no Tenstorrent silicon required.
#
# Layout: each arch gets its own subdirectory so the .so and soc_descriptor.yaml
# can coexist (ttsim requires both files in the same directory).
#
#   ~/sim/wh/libttsim_wh.so   + soc_descriptor.yaml  → Wormhole sim
#   ~/sim/bh/libttsim_bh.so   + soc_descriptor.yaml  → Blackhole sim
#
# TTSIM_VERSION="latest" uses the GitHub /releases/latest/download/ redirect.
# Any tag (e.g. "v1.7.0") uses /releases/download/<tag>/ directly.
#
# Known sim constraints:
#   - Fast dispatch NOT supported: TT_METAL_SLOW_DISPATCH_MODE=1 required
#   - SFPLOADMACRO not supported: TT_METAL_DISABLE_SFPLOADMACRO=1 required
#   - vLLM inference will not work (needs fast dispatch)
RUN if [ "${TT_METAL_BUILD}" = "sim" ]; then \
      mkdir -p ~/sim/wh ~/sim/bh && \
      if [ "${TTSIM_VERSION}" = "latest" ]; then \
        BASE_URL="https://github.com/tenstorrent/ttsim/releases/latest/download"; \
      else \
        BASE_URL="https://github.com/tenstorrent/ttsim/releases/download/${TTSIM_VERSION}"; \
      fi && \
      echo ">>> Downloading ttsim from ${BASE_URL}" && \
      wget -q "${BASE_URL}/libttsim_wh.so" -O ~/sim/wh/libttsim_wh.so && \
      wget -q "${BASE_URL}/libttsim_bh.so" -O ~/sim/bh/libttsim_bh.so && \
      echo ">>> Copying SOC descriptor YAMLs" && \
      cp "${TT_METAL_HOME}/tt_metal/soc_descriptors/wormhole_b0_80_arch.yaml" \
         ~/sim/wh/soc_descriptor.yaml && \
      cp "${TT_METAL_HOME}/tt_metal/soc_descriptors/blackhole_140_arch.yaml" \
         ~/sim/bh/soc_descriptor.yaml && \
      echo ">>> ttsim binaries installed:" && \
      ls -lh ~/sim/wh/ ~/sim/bh/; \
    else \
      echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping ttsim download."; \
    fi
```

- [ ] **Step 2: Verify Dockerfile syntax**

```bash
cd /home/ttuser/code/tt-developer-image/docker
docker build --check . 2>&1 | head -20
```
Expected: no `ERROR` lines.

- [ ] **Step 3: Commit**

```bash
cd /home/ttuser/code/tt-developer-image
git add docker/Dockerfile
git commit -m "feat(sim): download ttsim wh/bh binaries and SOC descriptors in sim mode"
```

---

## Task 4: Add tt-env-sim.sh profile script

New sim-only conditional block that writes `/etc/profile.d/tt-env-sim.sh`, parallel to the existing `tt-env-metal.sh`. Must be placed inside the section 8 env wrapper RUN block (or appended as a new RUN immediately after it).

**Files:**
- Modify: `docker/Dockerfile`

- [ ] **Step 1: Append a new sim-mode env script RUN block** immediately after the existing section 8 block (after the `sudo chmod +x /etc/profile.d/tt-env-forge.sh` line, before the section 9 comment):

```dockerfile
# tt-env-sim.sh — simulator environment (sim build mode only).
# Activates venv-metal with ttsim backend variables set.
# TT_SIM_ARCH controls which simulator is active: "wh" (default) or "bh".
# Override at docker run: docker run -e TT_SIM_ARCH=bh ...
RUN if [ "${TT_METAL_BUILD}" = "sim" ]; then \
    printf '%s\n' \
      '#!/bin/bash' \
      '# tt-env-sim.sh — venv-metal + ttsim backend.' \
      '# TT_SIM_ARCH: "wh" (Wormhole, default) or "bh" (Blackhole).' \
      '# Override: docker run -e TT_SIM_ARCH=bh ...' \
      ': "${TT_SIM_ARCH:=wh}"' \
      'export TT_SIM_ARCH' \
      'export TT_METAL_HOME=/home/'"${DEV_USER}"'/tt-metal' \
      'export PYTHONPATH=$TT_METAL_HOME:$PYTHONPATH' \
      'export LD_LIBRARY_PATH=$TT_METAL_HOME/build/lib:$LD_LIBRARY_PATH' \
      'export TT_METAL_SIMULATOR="$HOME/sim/${TT_SIM_ARCH}/libttsim_${TT_SIM_ARCH}.so"' \
      'export TT_METAL_SLOW_DISPATCH_MODE=1' \
      'export TT_METAL_DISABLE_SFPLOADMACRO=1' \
      'export SIMULATOR_MODE=1' \
      'source /opt/venv-metal/bin/activate' \
    | sudo tee /etc/profile.d/tt-env-sim.sh > /dev/null && \
    sudo chmod +x /etc/profile.d/tt-env-sim.sh; \
  else \
    echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping tt-env-sim.sh"; \
  fi
```

- [ ] **Step 2: Verify Dockerfile syntax**

```bash
cd /home/ttuser/code/tt-developer-image/docker
docker build --check . 2>&1 | head -20
```
Expected: no `ERROR` lines.

- [ ] **Step 3: Commit**

```bash
cd /home/ttuser/code/tt-developer-image
git add docker/Dockerfile
git commit -m "feat(sim): add tt-env-sim.sh profile script with SIMULATOR_MODE=1"
```

---

## Task 5: Add tt-sim / tt-sim-bh shell switchers and welcome message

Extend `~/.bashrc` in sim mode with `tt-sim()` and `tt-sim-bh()` functions plus a welcome banner. Add as a new conditional RUN block after the existing shell switchers block.

**Files:**
- Modify: `docker/Dockerfile`

- [ ] **Step 1: Append sim switchers and welcome message** immediately after the existing shell switchers block (after the line that appends `tt-metal`, `tt-vllm`, `tt-forge` functions to `.bashrc`):

```dockerfile
# Sim-mode shell switchers and welcome banner (sim build mode only).
RUN if [ "${TT_METAL_BUILD}" = "sim" ]; then \
    printf '\n# ── Tenstorrent simulator switchers ─────────────────────────\n# Usage: tt-sim  |  tt-sim-bh\ntt-sim()    { deactivate 2>/dev/null || true; source /etc/profile.d/tt-env-sim.sh; }\ntt-sim-bh() { TT_SIM_ARCH=bh tt-sim; }\n# ─────────────────────────────────────────────────────────────\n' \
    >> /home/${DEV_USER}/.bashrc && \
    printf '\n# ── Simulator welcome ────────────────────────────────────────\necho ""\necho "  Tenstorrent Simulator Image"\necho "  No hardware required."\necho ""\necho "  tt-sim         activate Wormhole simulator environment"\necho "  tt-sim-bh      activate Blackhole simulator environment"\necho "  tt-toplike     hardware monitoring (mock mode)"\necho "  tt-metal       activate venv-metal (for non-sim use)"\necho ""\n# ─────────────────────────────────────────────────────────────\n' \
    >> /home/${DEV_USER}/.bashrc; \
  else \
    echo "TT_METAL_BUILD=${TT_METAL_BUILD}: skipping sim switchers."; \
  fi
```

- [ ] **Step 2: Verify Dockerfile syntax**

```bash
cd /home/ttuser/code/tt-developer-image/docker
docker build --check . 2>&1 | head -20
```
Expected: no `ERROR` lines.

- [ ] **Step 3: Commit**

```bash
cd /home/ttuser/code/tt-developer-image
git add docker/Dockerfile
git commit -m "feat(sim): add tt-sim/tt-sim-bh shell switchers and welcome banner"
```

---

## Task 6: Build the sim image on QB2 and run smoke tests

This is the integration verification step. All previous tasks were syntax-level; this proves the image actually works.

**Files:** None (build and test only)

- [ ] **Step 1: Build the sim image (QB2, ~60–90 min)**

```bash
cd ~/code/tt-developer-image/docker
docker build \
  --build-arg TT_METAL_BUILD=sim \
  --build-arg TTSIM_VERSION=v1.7.0 \
  --progress=plain \
  -t tt-sim-test:latest \
  . 2>&1 | tee /tmp/tt-sim-build.log
```

Expected: build completes without error. The final lines should resemble:
```
>>> ttsim binaries installed:
/home/dev/sim/wh/:
total 50M
-rw-r--r-- 1 dev dev  50M ... libttsim_wh.so
-rw-r--r-- 1 dev dev 3.2K ... soc_descriptor.yaml
...
Successfully built <image-id>
```

If the build fails, check `/tmp/tt-sim-build.log` for the first `ERROR` line.

- [ ] **Step 2: Copy the test script into the image and run it**

```bash
docker run --rm \
  -v /home/ttuser/code/tt-developer-image/docker/scripts/test_sim_mode.sh:/tmp/test_sim_mode.sh:ro \
  tt-sim-test:latest \
  bash /tmp/test_sim_mode.sh
```

Expected output ends with:
```
=== Results: 13 passed, 0 failed ===
```

If any test fails, diagnose from the `FAIL` line and fix the corresponding Dockerfile step. Re-build (Docker layer cache will skip unchanged steps).

- [ ] **Step 3: Manual sanity — run a real tt-metal example against the WH sim**

```bash
docker run --rm tt-sim-test:latest bash -lc "
  source /etc/profile.d/tt-env-sim.sh
  cd \$TT_METAL_HOME
  ./build/programming_examples/metal_example_add_2_integers_in_riscv
"
```

Expected: output includes something like `Finish program` or `PASS` with no assertion failures. If the binary doesn't exist at that path, check `ls $TT_METAL_HOME/build/programming_examples/` to find the correct name.

- [ ] **Step 4: Verify tt-toplike mock mode**

```bash
docker run --rm tt-sim-test:latest bash -c "
  timeout 3 tt-toplike --mock --mock 1 2>/dev/null; true
"
```

Expected: exits cleanly (timeout kills the TUI after 3 seconds, exit code 124 from timeout is acceptable). No `command not found` error.

- [ ] **Step 5: Commit (tag the verified image)**

```bash
cd ~/code/tt-developer-image
git add docker/Dockerfile  # no changes here — this is just a verification task
git tag sim-v1.7.0
git commit --allow-empty -m "chore: sim image verified against ttsim v1.7.0"
```

---

## Task 7: Update README.md

**Files:**
- Modify: `docker/README.md`

- [ ] **Step 1: Add `sim` to the build modes table**

Find the existing table:
```markdown
| `TT_METAL_BUILD` | Default | Description |
|---|---|---|
| `checkout` | ✓ | clone only, no compilation |
| `full` | | clone + compile + pip install |
```

Replace with:
```markdown
| `TT_METAL_BUILD` | Default | Description |
|---|---|---|
| `checkout` | ✓ | clone only, no compilation. Fast; for CI/iteration |
| `full` | | clone + compile + pip install. Required for real hardware |
| `sim` | | same as `full`, plus ttsim WH+BH binaries. Hardware-free learning |
```

- [ ] **Step 2: Add a Simulator Quick Start section** after the existing Blackhole Quick Start:

```markdown
### Simulator (no hardware required)

Build once on QB2 (x86_64 Linux), then pull from GHCR anywhere:

```bash
# Pull pre-built image (once available on GHCR)
docker pull ghcr.io/tsingletary/tt-developer-image:sim-wh

# Or build locally on x86_64 Linux (~60–90 min)
docker build --build-arg TT_METAL_BUILD=sim \
             --build-arg TTSIM_VERSION=v1.7.0 \
             -t tt-sim:latest docker/

# Run (no /dev/tenstorrent needed)
docker run -it tt-sim:latest bash

# Inside the container:
tt-sim                        # activate Wormhole simulator
# or
tt-sim-bh                     # activate Blackhole simulator
python -c "import ttnn; print('TTNN ready')"

# Browser VS Code (port 8080)
docker run -d -p 8080:8080 -e PASSWORD=tenstorrent \
  tt-sim:latest \
  code-server --bind-addr 0.0.0.0:8080 --auth password \
              --disable-telemetry --disable-update-check
```

**What works in sim mode:**
- tt-metal / TTNN ops (slow dispatch mode, bit-exact results)
- TT-Lang kernels via ttlang-sim or ttsim
- TT-Forge compiler lessons (Forge uses its own backend, not ttsim)
- CS fundamentals lessons (Tensix visualizer, no hardware calls)
- `tt-toplike` in mock mode (monitoring UX without real hardware)

**What does not work in sim mode:**
- vLLM inference (requires fast dispatch, not yet supported by ttsim)
- QB2 multi-device lessons (require real PCI hardware)

**Known sim constraints (set automatically by `tt-sim`):**
- `TT_METAL_SLOW_DISPATCH_MODE=1` — required
- `TT_METAL_DISABLE_SFPLOADMACRO=1` — required
- `SIMULATOR_MODE=1` — picked up by tt-vscode-toolkit for status indicator
```

- [ ] **Step 3: Add the build arg table entry for TTSIM_VERSION**

Find the existing build args table:
```markdown
| Build arg | Default | Description |
|---|---|---|
| `TT_METAL_BUILD` | `checkout` | ...
```

Add a row:
```markdown
| `TTSIM_VERSION` | `latest` | ttsim release tag to download (`latest` or e.g. `v1.7.0`) |
```

- [ ] **Step 4: Add GHCR manual push instructions** at the end of the README:

```markdown
## Publishing to GHCR (manual)

Build on QB2 and push with a GitHub PAT (`write:packages` scope):

```bash
# Build
cd docker
docker build --build-arg TT_METAL_BUILD=sim \
             --build-arg TTSIM_VERSION=v1.7.0 \
             -t ghcr.io/tsingletary/tt-developer-image:sim-wh .

# Login and push
echo $GH_PAT | docker login ghcr.io -u tsingletary --password-stdin
docker push ghcr.io/tsingletary/tt-developer-image:sim-wh

# Also push a bh-default tag (same image, communicates default arch)
docker tag ghcr.io/tsingletary/tt-developer-image:sim-wh \
           ghcr.io/tsingletary/tt-developer-image:sim-bh
docker push ghcr.io/tsingletary/tt-developer-image:sim-bh
```

To make the package public after pushing: GitHub → your profile → Packages → tt-developer-image → Package settings → Change visibility → Public.
```

- [ ] **Step 5: Commit**

```bash
cd /home/ttuser/code/tt-developer-image
git add docker/README.md
git commit -m "docs: add sim mode quick start, build args table, and GHCR push instructions"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Covered by |
|---|---|
| `TT_METAL_BUILD=sim` third build mode | Tasks 2, 3, 4, 5 |
| ttsim WH+BH binaries in `~/sim/wh/` and `~/sim/bh/` | Task 3 |
| `TT_SIM_ARCH` env var for arch selection | Task 4 |
| `tt-env-sim.sh` sets `SIMULATOR_MODE=1`, `SLOW_DISPATCH`, `DISABLE_SFPLOADMACRO` | Task 4 |
| `tt-sim` / `tt-sim-bh` shell switchers | Task 5 |
| Welcome banner | Task 5 |
| code-server + tt-vscode-toolkit present (inherited from existing image) | No task needed — already in Dockerfile |
| Build verification smoke tests | Tasks 1, 6 |
| README updated | Task 7 |
| GHCR push instructions | Task 7 |

All spec requirements covered. No gaps.

**Placeholder scan:** No TBDs, TODOs, or vague steps found.

**Type/name consistency:**
- `TT_SIM_ARCH` used consistently in Task 4 profile script and Task 5 switchers
- `~/sim/wh/libttsim_wh.so` path matches between Task 3 (download) and Task 4 (`TT_METAL_SIMULATOR` value)
- `tt-sim()` function name consistent across Tasks 5 and the test script in Task 1

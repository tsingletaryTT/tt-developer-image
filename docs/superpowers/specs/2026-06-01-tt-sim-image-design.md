# tt-sim-image Design
_2026-06-01 · Taylor Singletary_

## Context

Tenstorrent hardware is not always available — learners evaluate before purchase, devices
get tied up, and educational content benefits from a hardware-free path. The existing
`tt-developer-image` serves users with real silicon. This design adds a `TT_METAL_BUILD=sim`
mode that produces a standalone simulator image for hardware-less learning, with the goal
of getting through as many lessons as possible before hardware is required.

`ttsim` v1.7.0+ provides bit-exact Wormhole and Blackhole simulation as a single `.so` file
that tt-metal loads via `TT_METAL_SIMULATOR`. Fast dispatch is not yet supported; all sim
execution requires `TT_METAL_SLOW_DISPATCH_MODE=1`. aarch64 binaries now exist but the
full tt-metal C++ build is x86_64 Linux only — the image is built on QB2.

## Goals

1. Extend the existing Dockerfile with a `sim` build mode rather than creating a separate image
2. As much lesson parity as ttsim supports — tt-metal/TTNN ops, TT-Lang, TT-Forge, CS fundamentals
3. code-server + tt-vscode-toolkit pre-installed with a simulator status indicator
4. Manual build on QB2, push to GHCR manually — no CI needed initially
5. `tt-toplike` in mock mode gives learners the monitoring UX without real hardware

## Non-Goals

- vLLM / large model inference (requires fast dispatch — not yet supported by ttsim)
- QB2-specific multi-device lessons (hardware-only)
- aarch64 image builds (tt-metal full build is x86_64 only)
- Automated CI publishing

---

## Architecture

### Build Mode Extension

The existing `TT_METAL_BUILD` build arg gets a third value:

| `TT_METAL_BUILD` | What happens |
|---|---|
| `checkout` | Clone only, no compile (fast, for CI/iteration) |
| `full` | Clone + `install_dependencies.sh` + C++ build + pip install |
| `sim` | Same as `full`, then: download ttsim binaries + write sim env scripts |

`sim` mode is a superset of `full` — all the same layers, plus a ttsim-specific layer at the end. This keeps the Dockerfile as a single file with no code duplication.

### ttsim Binary Layout

Downloaded from `github.com/tenstorrent/ttsim/releases` during image build:

```
~/sim/
  libttsim_wh.so               ← Wormhole simulator
  libttsim_bh.so               ← Blackhole simulator
  soc_descriptor_wh.yaml       ← copied from $TT_METAL_HOME/tt_metal/soc_descriptors/wormhole_b0_80_arch.yaml
  soc_descriptor_bh.yaml       ← copied from $TT_METAL_HOME/tt_metal/soc_descriptors/blackhole_140_arch.yaml
```

`ARG TTSIM_VERSION=latest` — defaults to latest release, overridable for pinning.

GitHub supports `/releases/latest/download/<filename>` as a redirect URL, so the Dockerfile wget uses:
```
https://github.com/tenstorrent/ttsim/releases/latest/download/libttsim_wh.so
```
When `TTSIM_VERSION` is a pinned tag (e.g. `v1.7.0`), the URL becomes:
```
https://github.com/tenstorrent/ttsim/releases/download/v1.7.0/libttsim_wh.so
```
The Dockerfile RUN block uses a shell conditional to pick the correct URL pattern.

The ttsim `.so` files are Apache 2.0 licensed and ~50 MB each. Embedding them in the image is clean.

### New Profile Script: `tt-env-sim.sh`

`/etc/profile.d/tt-env-sim.sh` — parallel to the existing `tt-env-metal.sh`:

```bash
#!/bin/bash
# Activate venv-metal with ttsim backend
: "${TT_SIM_ARCH:=wh}"   # override with: docker run -e TT_SIM_ARCH=bh

export TT_METAL_HOME=/home/dev/tt-metal
export PYTHONPATH=$TT_METAL_HOME:$PYTHONPATH
export LD_LIBRARY_PATH=$TT_METAL_HOME/build/lib:$LD_LIBRARY_PATH

# ttsim-specific flags
export TT_METAL_SIMULATOR=~/sim/libttsim_${TT_SIM_ARCH}.so
export TT_METAL_SLOW_DISPATCH_MODE=1
export TT_METAL_DISABLE_SFPLOADMACRO=1

# Picked up by tt-vscode-toolkit for the simulator status banner
export SIMULATOR_MODE=1

source /opt/venv-metal/bin/activate
```

### Shell Switchers

Two new functions added to `~/.bashrc` in sim mode, alongside existing `tt-metal`/`tt-vllm`/`tt-forge`:

```bash
tt-sim()    { deactivate 2>/dev/null || true; source /etc/profile.d/tt-env-sim.sh; }
tt-sim-bh() { TT_SIM_ARCH=bh tt-sim; }
```

`TT_SIM_ARCH` env var at `docker run -e TT_SIM_ARCH=bh` selects Blackhole by default.
Default is `wh` (Wormhole) since that's the most common learning target.

### GHCR Tag Convention

```
ghcr.io/tsingletary/tt-developer-image:sim-wh   ← Wormhole default (primary)
ghcr.io/tsingletary/tt-developer-image:sim-bh   ← Blackhole default
ghcr.io/tsingletary/tt-developer-image:full     ← existing full mode, no sim
```

Both sim tags use the same image; the `-wh`/`-bh` suffix just communicates the default `TT_SIM_ARCH`. Either image can run either architecture via `docker run -e TT_SIM_ARCH=bh`.

### Manual Push Workflow (QB2)

```bash
# Build on QB2
cd ~/code/tt-developer-image/docker
docker build --build-arg TT_METAL_BUILD=sim \
             --build-arg TTSIM_VERSION=v1.7.0 \
             -t ghcr.io/tsingletary/tt-developer-image:sim-wh .

# Push (requires PAT with write:packages scope)
echo $GH_PAT | docker login ghcr.io -u tsingletary --password-stdin
docker push ghcr.io/tsingletary/tt-developer-image:sim-wh

# Tag and push BH variant (same image, different default arch communicated via tag)
docker tag ghcr.io/tsingletary/tt-developer-image:sim-wh \
           ghcr.io/tsingletary/tt-developer-image:sim-bh
docker push ghcr.io/tsingletary/tt-developer-image:sim-bh
```

---

## Extension Changes

Minimal: one `SIMULATOR_MODE` env check in `activate()`:

```typescript
const simMode = !!process.env.SIMULATOR_MODE;
if (simMode) {
  // Override status bar: "🔬 Simulator" instead of device name
  // Show notice banner on ttsim_incompatible lessons
}
```

**Status bar:** `🔬 Simulator` in teal when `SIMULATOR_MODE=1`. Replaces the "No device" fallback.

**Lesson notices:** Lessons with `ttsim_incompatible: true` in front matter show:
> ⚠️ This lesson requires real Tenstorrent hardware and cannot run in simulator mode.

No other behavioral changes — commands run normally against the sim backend.

---

## Lesson Coverage Matrix

| Category | Lessons | Sim coverage | Notes |
|---|---|---|---|
| Setup | tt-installer, build-tt-metal | ✅ Conceptual | No hardware ops needed |
| tt-metal / TTNN | explore-metalium, cookbook-* | ✅ Runs | `SLOW_DISPATCH_MODE=1` already set |
| TT-Lang | tt-lang-intro | ✅ Runs | ttlang-sim OR ttsim path |
| TT-Forge | forge-image-classification | ✅ Runs | Forge doesn't use ttsim at all |
| CS fundamentals | cs-fundamentals-01–07 | ✅ Runs | Tensix-viz only, no hardware |
| Custom training | ct-* series | ✅ Runs | CPU training path works |
| vLLM / inference | vllm-production, api-server | ❌ Incompatible | Fast dispatch required; show notice |
| QB2-specific | qb2-* lessons | ❌ Incompatible | Multi-device hardware required |

### tt-toplike in Sim Image

Pre-installed. Default mode with no hardware is `auto` which gracefully falls back to mock.
A welcome message in `~/.bashrc` suggests:

```bash
echo ""
echo "  🔬 Simulator mode active. No Tenstorrent hardware required."
echo "  tt-sim         → activate simulator environment"
echo "  tt-toplike     → hardware monitoring (mock mode, no hardware needed)"
echo ""
```

`tt-toplike` in mock mode teaches the monitoring UX — fleet health, per-chip utilization,
temperature/power displays — without needing PCI hardware. The hardware-constellation lesson
already handles mock mode gracefully.

### tt-smi in Sim Image

`tt-smi` reports no devices (no PCI hardware present in the container). The extension's
device detection already handles this — the "No device" path is overridden to
"🔬 Simulator" when `SIMULATOR_MODE=1` is set.

---

## Files to Change

### `docker/Dockerfile`
- Add `sim` branch to the `TT_METAL_BUILD` RUN conditional (after the existing `full` branch)
- Add `ARG TTSIM_VERSION=latest`
- New sim-mode layer: `wget` ttsim binaries, `cp` SOC descriptors, write `tt-env-sim.sh`
- Extend shell switchers block with `tt-sim` and `tt-sim-bh` functions (guard on `TT_METAL_BUILD=sim`)
- Add welcome message to `~/.bashrc` in sim mode

### `docker/README.md`
- Add `sim` to the build modes table
- Add sim-mode quick start section
- Add GHCR pull instructions for the pre-built sim image

### `docker/scripts/setup_envs.sh`
- No changes needed (sim uses venv-metal directly)

### `src/extension.ts` (tt-vscode-toolkit)
- Add `SIMULATOR_MODE` env check in `activate()`
- Override status bar item when sim mode detected
- Add lesson notice rendering for `ttsim_incompatible: true` front matter

### `content/lessons/*.md` (tt-vscode-toolkit)
- Add `ttsim_incompatible: true` to vllm-production, api-server, qb2-* lessons
- `ttsim_incompatible` is a new optional boolean front-matter field; it must be added to the
  lesson registry schema and the `validate-lesson-registry.js` script's known-field list
  (it is a markdown-owned field, not JSON-owned — add to the sync list in CLAUDE.md)

---

## Verification

```bash
# Build sim image (QB2, ~60 min)
docker build --build-arg TT_METAL_BUILD=sim -t tt-sim-test .

# Run and verify sim env
docker run --rm tt-sim-test bash -c "
  source /etc/profile.d/tt-env-sim.sh
  echo 'SIMULATOR: '$TT_METAL_SIMULATOR
  echo 'SLOW_DISPATCH: '$TT_METAL_SLOW_DISPATCH_MODE
  python -c \"import ttnn; print('TTNN OK')\"
"

# Run a basic tt-metal example against the sim
docker run --rm tt-sim-test bash -lc "
  tt-sim
  cd \$TT_METAL_HOME
  TT_METAL_SLOW_DISPATCH_MODE=1 ./build/programming_examples/metal_example_add_2_integers_in_riscv
"

# Verify tt-toplike mock mode
docker run --rm tt-sim-test bash -c "tt-toplike --mock --interval 100 &; sleep 2; kill %1"

# Verify code-server has the extension
docker run --rm tt-sim-test code-server --list-extensions | grep tenstorrent
```

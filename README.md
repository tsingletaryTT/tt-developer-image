# tt-developer-image

A Docker image for Tenstorrent hardware development — pre-loaded with the full TT software stack, browser-based VS Code, and an optional hardware simulator so you can learn and experiment without physical silicon.

---

## What This Is

`tt-developer-image` gives you a reproducible, self-contained environment for working with Tenstorrent hardware (Wormhole N150/N300/T3K, Blackhole P100/P150/P300c/QB2) or the [ttsim](https://github.com/tenstorrent/ttsim) hardware simulator. It is the canonical development environment for the [tt-vscode-toolkit](https://github.com/tenstorrent/tt-vscode-toolkit) interactive lessons.

One image, three ways to use it:

| Mode | Hardware required? | Build time | Use case |
|---|---|---|---|
| `checkout` | Yes (or sim) | Minutes | Iterate on venv/lesson layers; tt-metal source present but not compiled |
| `full` | **Yes** | 30–90 min | Run real ops on N150/N300/QB2 |
| `sim` | **No** | 60–90 min | Learn the TT programming model without Tenstorrent silicon |

---

## What's Inside

### Software stack

| Component | Location | Description |
|---|---|---|
| **tt-metal** | `~/tt-metal` | Core TT-Metalium stack, cloned at a pinned commit. Compiled in `full`/`sim` modes. |
| **TTNN** | inside venv-metal | High-level neural network op library built on tt-metal |
| **Tenstorrent vLLM** | `~/tt-vllm` | TT fork of vLLM for production LLM serving |
| **TT-Forge** | venv-forge | TT compiler stack: forge.compile(), TT-XLA PJRT plugin, JAX |
| **ttsim** | `~/sim/wh/`, `~/sim/bh/` | Hardware simulator `.so` files (sim mode only) |
| **tt-toplike** | `/usr/local/bin/tt-toplike` | htop-style real-time hardware monitor |
| **tt-smi** | venv-metal | Tenstorrent SMI — device health and utilization |
| **hf CLI** | venv-metal, venv-vllm | HuggingFace model management (`hf download`, `hf auth`) |
| **code-server** | `/usr/bin/code-server` | Browser-based VS Code (port 8080) |
| **tt-vscode-toolkit** | code-server extension | Interactive TT lessons, walkthroughs, and templates |
| **tt-forge demos** | `~/tt-forge/` | Pre-cloned TT-Forge example repo (GPT-2, ALBERT, ResNet) |
| **tt-scratchpad** | `~/tt-scratchpad/` | Extension-managed scratch dir for generated scripts |

### Python environments

Three isolated virtualenvs — never mix them:

```
/opt/venv-metal   Python 3.10 — tt-metal, TTNN, tt-smi, hf CLI
/opt/venv-vllm    Python 3.10 — Tenstorrent vLLM, torch 2.5.0+cpu, hf CLI
/opt/venv-forge   Python 3.12 — tt-forge, pjrt_plugin_tt, torch-xla, JAX, vllm_tt
```

**Note on venv-forge:** `tt-forge-onnx` (the ONNX frontend) is intentionally excluded. It
requires `torch==2.7.0` which directly conflicts with `pjrt-plugin-tt`'s `torch==2.10.0`.
The image ships the TT-XLA runtime stack (`pjrt_plugin_tt`, `jax`, `torch-xla`); the ONNX
frontend can be added to a separate venv if needed.

Switch between them with the shell aliases (available in all build modes):

```bash
tt-metal    # activate venv-metal (TTNN / direct API)
tt-vllm     # activate venv-vllm  (production inference)
tt-forge    # activate venv-forge (JAX / forge.compile)

# Simulator mode only:
tt-sim      # activate venv-metal + Wormhole simulator
tt-sim-bh   # activate venv-metal + Blackhole simulator
```

### What is NOT in this image

- **Kernel module / driver (KMD)** — must be installed on the host via `tt-installer`
- **Firmware** — host-side; `tt-flash` handles this before starting the container
- **HugePages** — configured on the host; mount into the container with `-v /dev/hugepages-1G:/dev/hugepages-1G`
- **Model weights** — too large to bundle; download via `hf download` at runtime
- **tt-installer itself** — the installer runs on the host to set up the card, not inside the container

---

## Relationship to tt-vscode-toolkit

[tt-vscode-toolkit](https://github.com/tenstorrent/tt-vscode-toolkit) is the VSCode extension that provides interactive lessons, walkthroughs, and templates for learning the TT stack. This image is its companion runtime:

```
┌─────────────────────────────────────────────────────┐
│  tt-developer-image (this repo)                     │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │  code-server (browser VS Code)              │   │
│  │                                             │   │
│  │  ┌───────────────────────────────────────┐  │   │
│  │  │  tt-vscode-toolkit extension          │  │   │
│  │  │  • Walkthroughs & lessons             │  │   │
│  │  │  • Terminal commands                  │  │   │
│  │  │  • Device status bar                  │  │   │
│  │  │  • Chat integration                   │  │   │
│  │  └───────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  venv-metal │ venv-vllm │ venv-forge               │
│  tt-metal   │ ttsim     │ tt-toplike                │
└─────────────────────────────────────────────────────┘
         │                        │
   real hardware              no hardware
  /dev/tenstorrent           TT_METAL_SIMULATOR
```

The extension is installed from the latest GitHub Release at image build time. When the image starts with `SIMULATOR_MODE=1` (set automatically by `tt-sim`), the extension shows a **🔬 Simulator** status badge and shows notices on lessons that require real hardware.

**Lesson compatibility in sim mode:**

| Lesson category | Works in sim? | Notes |
|---|---|---|
| Setup / installation | ✅ Conceptual | No hardware ops required |
| tt-metal / TTNN direct API | ✅ | Slow dispatch, bit-exact results |
| TT-Lang kernels | ✅ | via ttlang-sim or ttsim |
| TT-Forge compiler | ✅ | Forge uses its own backend, not ttsim |
| CS fundamentals | ✅ | Tensix visualizer, no hardware calls |
| Custom training (CPU path) | ✅ | CPU training works |
| vLLM / LLM inference | ❌ | Requires fast dispatch (not yet in ttsim) |
| QB2 multi-device | ❌ | Requires real PCI hardware |

---

## Relationship to ttsim

[ttsim](https://github.com/tenstorrent/ttsim) is a hardware simulator for Tenstorrent silicon — a single `.so` file that plugs into tt-metal via the `TT_METAL_SIMULATOR` environment variable. It provides **bit-exact** emulation of Wormhole and Blackhole chips on any Linux/x86_64 machine.

```
tt-metal / TTNN
      │
      │  normally                    in sim mode
      ▼                                   ▼
/dev/tenstorrent              TT_METAL_SIMULATOR=~/sim/wh/libttsim_wh.so
(real silicon)                (software emulation, no silicon needed)
```

### What ttsim can do (as of v1.7.0)

- Run tt-metal and TTNN programs in **slow dispatch mode** (`TT_METAL_SLOW_DISPATCH_MODE=1`)
- Bit-exact numerical results relative to silicon for all supported ops
- Wormhole (`libttsim_wh.so`) and Blackhole (`libttsim_bh.so`) chip emulation
- Linux x86_64 and aarch64 binaries available
- "Many" tt-metal, TTNN, and TT-Forge examples/tests

### What ttsim cannot do yet

- **Fast dispatch** — `TT_METAL_SLOW_DISPATCH_MODE=1` is required; vLLM inference and large model serving won't work
- SFPLOADMACRO (`TT_METAL_DISABLE_SFPLOADMACRO=1` required)
- Some advanced hardware features (see ttsim [Known Issues](https://github.com/tenstorrent/ttsim#known-issues))

### How this image configures ttsim

In `sim` build mode, the image:

1. Downloads `libttsim_wh.so` and `libttsim_bh.so` from the ttsim GitHub releases
2. Copies the matching SOC descriptor YAMLs from the built tt-metal tree
3. Places everything in `~/sim/wh/` and `~/sim/bh/` (ttsim requires the `.so` and `soc_descriptor.yaml` in the same directory)
4. Creates `/etc/profile.d/tt-env-sim.sh` that sets all required env vars

When you run `tt-sim` in the container, the following is set automatically:

```bash
TT_METAL_SIMULATOR=~/sim/wh/libttsim_wh.so
TT_METAL_SLOW_DISPATCH_MODE=1
TT_METAL_DISABLE_SFPLOADMACRO=1
TT_METAL_ARCH_NAME=wormhole_b0   # or blackhole for tt-sim-bh
SIMULATOR_MODE=1
```

---

## Quick Start

### Real hardware (Wormhole)

```bash
cd docker
docker build -t tenstorrent/dev:latest .

docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  tenstorrent/dev:latest bash

# Inside container:
tt-metal
python -c "import ttnn; print('TTNN ready')"
```

### Real hardware (Blackhole / QB2)

```bash
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  -e TT_METAL_ARCH_NAME=blackhole \
  tenstorrent/dev:latest bash
```

### Simulator (no hardware)

```bash
# Pull pre-built image
docker pull ghcr.io/tsingletary/tt-developer-image:sim-wh

# Or build locally on x86_64 Linux (60–90 min)
docker build --build-arg TT_METAL_BUILD=sim \
             --build-arg TTSIM_VERSION=v1.7.0 \
             -t tt-sim:latest docker/

# Run — no /dev/tenstorrent required
docker run -it tt-sim:latest bash

# Inside container:
tt-sim
python -c "import ttnn; print('TTNN ready (simulator)')"
tt-toplike   # monitoring UI in mock mode
```

### Browser-based VS Code (all modes)

```bash
# With real hardware:
docker run -d -p 8080:8080 \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  -e PASSWORD=your-password \
  tenstorrent/dev:latest \
  code-server --bind-addr 0.0.0.0:8080 --auth password \
              --disable-telemetry --disable-update-check

# With simulator:
docker run -d -p 8080:8080 \
  -e PASSWORD=your-password \
  tt-sim:latest \
  code-server --bind-addr 0.0.0.0:8080 --auth password \
              --disable-telemetry --disable-update-check
```

Open http://localhost:8080. Default password: `tenstorrent` — always override with `-e PASSWORD=…`.

---

## Build Modes

| `TT_METAL_BUILD` | Hardware required | Build time | What's compiled |
|---|---|---|---|
| `checkout` (default) | Yes, at runtime | ~5 min | Nothing — source present, not built |
| `full` | Yes | 30–90 min | tt-metal C++, TTNN, Python bindings, vLLM |
| `sim` | No | 60–90 min | Same as `full` + ttsim WH/BH binaries |

```bash
# Checkout (fast, for layer iteration)
docker build -t tenstorrent/dev:checkout docker/

# Full (real hardware)
docker build --build-arg TT_METAL_BUILD=full \
             -t tenstorrent/dev:full docker/

# Sim (hardware-free, build on x86_64 Linux)
docker build --build-arg TT_METAL_BUILD=sim \
             --build-arg TTSIM_VERSION=v1.7.0 \
             -t tt-sim:latest docker/
```

---

## Build-time Arguments

| Argument | Default | Description |
|---|---|---|
| `TT_METAL_BUILD` | `checkout` | Build mode: `checkout`, `full`, or `sim` |
| `TTSIM_VERSION` | `latest` | ttsim release tag. `latest` tracks HEAD; pin (e.g. `v1.7.0`) for reproducible builds. Sim mode only. |
| `TT_METAL_COMMIT` | pinned SHA | tt-metal commit to check out |
| `VLLM_BRANCH` | `dev` | Tenstorrent vLLM branch |
| `DEV_USER` | `dev` | Linux username inside the container |

---

## Runtime Environment Variables

| Variable | Set by | Description |
|---|---|---|
| `TT_METAL_ARCH_NAME` | `docker run -e` or env script | `wormhole_b0` or `blackhole`. Env scripts default to `wormhole_b0`. |
| `TT_SIM_ARCH` | `docker run -e` or `tt-sim-bh` | `wh` (default) or `bh`. Controls which simulator `.so` is loaded. |
| `SIMULATOR_MODE` | `tt-env-sim.sh` | Set to `1` in sim mode. Picked up by tt-vscode-toolkit. |
| `TT_METAL_SLOW_DISPATCH_MODE` | `tt-env-sim.sh` | Required for ttsim. Set to `1` automatically. |
| `PASSWORD` | `docker run -e` | code-server login password. Default: `tenstorrent`. Always override. |

---

## Container Directory Layout

What exists inside a running container and why each directory is where it is:

```
/home/dev/                          ← DEV_USER home (default: dev, UID 1000)
│
├── tt-metal/                       ← tt-metal cloned at pinned commit (555f240b)
│   ├── tt_metal/                   │  All three build modes clone this.
│   ├── models/                     │  full/sim modes compile it (~30-90 min).
│   └── build/                      │  Only present after compilation.
│       └── lib/                    │  LD_LIBRARY_PATH includes this.
│
├── tt-vllm/                        ← Tenstorrent vLLM fork, branch=dev
│   └── ...                         │  Cloned in all modes. pip install -e .
│                                   │  only runs in full/sim (needs compiled
│                                   │  tt-metal Python bindings).
│
├── tt-forge/                       ← TT-Forge demo repo (--depth 1)
│   └── demos/tt-xla/               │  Pre-cloned so lesson "Clone & Run" is
│                                   │  instant. pip install -r requirements.txt
│                                   │  still needed at runtime.
│
├── sim/                            ← ttsim binaries (sim mode only)
│   ├── wh/
│   │   ├── libttsim_wh.so          │  ttsim requires .so and soc_descriptor.yaml
│   │   └── soc_descriptor.yaml     │  to share the same directory — hence per-arch
│   └── bh/                        │  subdirectories instead of a flat layout.
│       ├── libttsim_bh.so
│       └── soc_descriptor.yaml
│
├── models/                         ← Model weights land here (hf download)
│   └── (empty until populated)     │  Not pre-populated — too large to bundle.
│
└── tt-scratchpad/                  ← Extension-generated scripts
    └── README.md

/opt/
├── venv-metal/                     ← Python 3.10 venv
│   └── lib/python3.10/             │  tt-metal (editable), TTNN, tt-smi, hf CLI
│                                   │  TTNN import only works after compilation.
├── venv-vllm/                      ← Python 3.10 venv
│   └── lib/python3.10/             │  vLLM (editable), torch 2.5.0+cpu, hf CLI
│                                   │  vLLM import only works after compilation.
└── venv-forge/                     ← Python 3.12 venv
    └── lib/python3.12/             │  tt-forge, pjrt_plugin_tt, torch 2.10.0+cpu,
                                    │  torch-xla 2.9.0, JAX 0.7.1, vllm_tt
                                    │  Always fully installed (no compilation needed).

/etc/profile.d/
├── tt-env-metal.sh                 ← source to activate venv-metal + set TT vars
├── tt-env-vllm.sh                  ← source to activate venv-vllm + set TT vars
├── tt-env-forge.sh                 ← source to activate venv-forge + set TT vars
└── tt-env-sim.sh                   ← source to activate venv-metal + ttsim vars
                                       (sim mode only; sets SIMULATOR_MODE=1,
                                        TT_METAL_SIMULATOR, SLOW_DISPATCH, etc.)

/tmp/                               ← Build helper scripts (always present)
├── build_tt_metal.sh               ← Compiles tt-metal from ~/tt-metal source
│                                      Run manually in checkout mode to compile.
├── setup_envs.sh                   ← Sets up venv-vllm or venv-forge
│                                      Usage: bash /tmp/setup_envs.sh vllm
└── forge-requirements.txt          ← URL-dep manifest for venv-forge install
                                       (already consumed during image build)
```

---

## What's Left to Compile After Entering

In `checkout` mode the image ships with all source trees present but nothing compiled. Here is exactly what each stack needs and how to trigger it:

### tt-metal + TTNN (venv-metal)

```bash
# Compile tt-metal C++ and install Python bindings into venv-metal
bash /tmp/build_tt_metal.sh

# Verify
tt-metal
python -c "import ttnn; print(ttnn.__version__)"
```

Takes 30–90 min. Requires a host with the TT kernel driver and at least 50 GB disk.

### vLLM (venv-vllm)

Must be done **after** `build_tt_metal.sh` — the TT vLLM fork links against compiled tt-metal Python extensions.

```bash
bash /tmp/setup_envs.sh vllm

# Verify
tt-vllm
python -c "import vllm; print(vllm.__version__)"
```

### TT-Forge (venv-forge)

Already fully installed at image build time — no compilation step needed. `tt-forge-install` was run during the build and downloaded the tt-metalium backend native libraries.

```bash
# Verify immediately (no build step)
tt-forge
python -c "import pjrt_plugin_tt; import jax; print('JAX', jax.__version__)"
```

### Model weights

```bash
tt-metal   # or tt-vllm, depending on the lesson
hf auth login --token "$HF_TOKEN"
hf download Qwen/Qwen3-0.6B --local-dir ~/models/Qwen3-0.6B
```

---

## Repo File Structure

```
docker/
  Dockerfile                  Main image definition (all three build modes)
  README.md                   Technical reference (build args, quick starts)
  scripts/
    build_tt_metal.sh         Compiles tt-metal; also copied to /tmp/ in image
    setup_envs.sh             Sets up venv-vllm and venv-forge; also in /tmp/
    forge-requirements.txt    URL-dep manifest for uv install of tt-forge stack
    test_sim_mode.sh          Smoke test — mount and run inside a sim container

docs/superpowers/
  specs/2026-06-01-tt-sim-image-design.md   Design doc for sim mode
  plans/2026-06-01-tt-sim-image.md          Implementation plan for sim mode
```

---

## Smoke Testing the Sim Image

After building a sim image, run the smoke test to verify all sim-mode wiring is correct:

```bash
docker run --rm \
  -v $(pwd)/docker/scripts/test_sim_mode.sh:/tmp/test_sim_mode.sh:ro \
  tt-sim:latest \
  bash /tmp/test_sim_mode.sh
```

Expected output:

```
=== tt-sim-image smoke tests ===

  PASS  tt-env-sim.sh exists
  PASS  tt-env-sim.sh is executable
  PASS  libttsim_wh.so exists
  PASS  libttsim_bh.so exists
  ...
  PASS  ttnn importable
  PASS  tt-sim function in .bashrc
  PASS  tt-toplike in PATH

=== Results: 15 passed, 0 failed ===
```

---

## Publishing to GHCR

Build on a QB2 (x86_64 Linux) and push manually with a GitHub PAT (`write:packages` scope):

```bash
# Build
cd docker
docker build --build-arg TT_METAL_BUILD=sim \
             --build-arg TTSIM_VERSION=v1.7.0 \
             -t ghcr.io/tsingletary/tt-developer-image:sim-wh .

# Push
echo $GH_PAT | docker login ghcr.io -u tsingletary --password-stdin
docker push ghcr.io/tsingletary/tt-developer-image:sim-wh

# Tag and push BH variant (same image, communicates default arch)
docker tag ghcr.io/tsingletary/tt-developer-image:sim-wh \
           ghcr.io/tsingletary/tt-developer-image:sim-bh
docker push ghcr.io/tsingletary/tt-developer-image:sim-bh
```

To make public: GitHub → your profile → Packages → `tt-developer-image` → Package settings → Change visibility → Public.

### GHCR tag convention

| Tag | Description |
|---|---|
| `:sim-wh` | Sim mode, Wormhole default (primary sim tag) |
| `:sim-bh` | Same image, Blackhole default communicated via tag |
| `:full` | Full build, real hardware only |
| `:latest` | Checkout mode (fast build, no compilation) |

---

## Related Projects

| Project | Description |
|---|---|
| [tt-vscode-toolkit](https://github.com/tenstorrent/tt-vscode-toolkit) | Interactive VSCode extension with lessons, walkthroughs, and templates |
| [ttsim](https://github.com/tenstorrent/ttsim) | Hardware simulator `.so` files (WH/BH/QSR, x86_64 + aarch64) |
| [tt-metal](https://github.com/tenstorrent/tt-metal) | Core TT-Metalium stack, TTNN, low-level kernel programming |
| [tt-installer](https://github.com/tenstorrent/tt-installer) | Host-side setup: KMD, firmware, HugePages, Python toolchain |
| [vllm (TT fork)](https://github.com/tenstorrent/vllm) | Production LLM serving on Tenstorrent hardware |
| [tt-forge](https://github.com/tenstorrent/tt-forge) | TT-Forge compiler + TT-XLA PJRT plugin for PyTorch/ONNX/JAX |
| [tt-toplike](https://github.com/tenstorrent/tt-toplike) | htop-style real-time hardware monitor |

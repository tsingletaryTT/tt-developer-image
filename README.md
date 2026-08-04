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
| **TT vLLM plugin** | `~/vllm-tt-plugin` | Tenstorrent vLLM platform plugin (works against upstream vLLM) |
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
/opt/venv-vllm    Python 3.10 — upstream vLLM 0.24.0 + TT plugin, hf CLI
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

**General dev work** — pass `TT_METAL_ARCH_NAME=blackhole` to the main image:

```bash
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  -e TT_METAL_ARCH_NAME=blackhole \
  tenstorrent/dev:latest bash
```

**QB2-exact environment** — use `Dockerfile.qb2` when you need paths that match a real QB2
post-tt-installer (VHS recordings, guide content, script validation):

```bash
cd docker
docker build -f Dockerfile.qb2 -t tenstorrent/qb2-env:latest .

# With hardware
docker run -it \
  --device /dev/tenstorrent \
  -v /dev/hugepages-1G:/dev/hugepages-1G \
  tenstorrent/qb2-env:latest bash

# Without hardware (path / alias verification only)
docker run -it tenstorrent/qb2-env:latest bash
```

`Dockerfile.qb2` uses `ttuser` (UID 1000), QB2 venv paths (`~/tt-metal/python_env/`, etc.),
bakes `TT_METAL_ARCH_NAME=blackhole` into `.bashrc`, and pre-clones `tt-inference-server`.
See [`docker/README.md`](docker/README.md) for the full two-Dockerfile comparison.

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

## The "latest metal" variant

`docker/Dockerfile.latest-metal` is a separate image that tracks tt-metal's newest
**release tag** instead of a pinned commit, and takes the compiled runtime from the
matching published `ttnn` wheel — so there is no 30–90 minute source build.

Built and verified on a TT-QuietBox 2 (2026-08-03): **~4.5 min cold build, 18.5 GB**,
resolving `v0.75.0` / `ttnn 0.75.0`. `qb2_smoke.sh` passes, and in-container the plugin
selects `TTPlatform`, sees all 4 Blackhole chips, and resolves `MESH_DEVICE=P300x2` to a
`(1,4)` mesh. Most of the image size is a CUDA torch wheel that upstream's installer
resolves; see the caveat at the top of the Dockerfile.

```bash
# newest tt-metal release, resolved at build time
docker build -f docker/Dockerfile.latest-metal \
  -t tenstorrent/dev-qb2:latest-metal docker/

# pin the release instead (still wheel-based)
docker build -f docker/Dockerfile.latest-metal \
  --build-arg TT_METAL_TAG=v0.74.0 \
  -t tenstorrent/dev-qb2:metal-v0.74.0 docker/
```

Why it is a separate file rather than a flag on `Dockerfile.qb2`: the two have
opposite goals. `Dockerfile.qb2` pins a commit so rebuilds are byte-identical. This
variant is deliberately *current*, so two builds a week apart may differ. Keeping
them apart keeps the reproducible image honestly reproducible.

**The source checkout is still required.** The `ttnn` wheel ships `ttnn`, `tt_lib`,
`tracy` and `triage` — but no `models/` tree, and the vLLM plugin registers its model
classes by dotted path into `models.*`. So the variant clones tt-metal at the tag
(shallow, for the working tree only) and puts just that root on `sys.path`; `ttnn`
itself comes from the wheel. `<root>/ttnn` is deliberately left off the path.

Which tt-metal did a given image actually get?

```bash
docker run --rm <image> cat /home/ttuser/.metal-release.env
# TT_METAL_TAG=v0.75.0
# TTNN_VERSION=0.75.0
```

`qb2_smoke.sh` asserts that file agrees with both the checked-out tag and the
installed wheel, and that `ttnn` resolves from site-packages while `models/` resolves
from the source tree. On the pinned images that check is skipped.

### Shared apt package lists

The three variants install system packages from two shared files rather than each
carrying its own copy:

| File | Used by |
|---|---|
| `docker/scripts/apt-packages-base.txt` | all three |
| `docker/scripts/apt-packages-toolchain.txt` | `Dockerfile`, `Dockerfile.qb2` (they compile tt-metal) |

`Dockerfile.latest-metal` takes base only — it never builds tt-metal, so the
compiler and protobuf/boost stack would be dead weight there.

Measured sizes, for reference: standard 23.5 GB, qb2 22.7 GB, latest-metal 18.5 GB.
CI builds the standard and qb2 variants on every push and latest-metal on demand
(`workflow_dispatch`) — the latter is the only one that installs vLLM, and building
`vllm==0.24.0` from its sdist is slow on a 2-core hosted runner.

This exists because of a real failure. `jq` was added to `Dockerfile.qb2` and not to
the standard `Dockerfile`, which then sat broken for three weeks: tt-installer defaults
to its `release` version channel, which parses the golden `.ttis` manifest with `jq`,
and the standard Dockerfile was the only variant CI built. Sharing the lists makes that
class of drift structurally impossible, and `check_apt_lists.py` (run in CI) fails if a
variant stops using them or starts inlining packages again.

Add packages to the list files, not to a Dockerfile.

### A note on tt-installer's golden versions

tt-installer pins a golden version set (`tt-sw-manifest`), and that manifest does
publish a `metal-version`. This variant does **not** follow it, for two reasons:

- tt-installer never reads that field — there is no reference to it in `install.m4`.
  It installs metalium as a *container wrapper*, which cannot provide the importable
  `ttnn` the vLLM plugin needs.
- The manifest lags. At the time of writing it named `v0.72.0`, which predates model
  modules the current plugin registers (`models/demos/blackhole/qwen36` is absent
  there and present in `v0.75.0`).

Print the golden value for comparison with:

```bash
bash docker/scripts/resolve_metal_release.sh --golden
```

What tt-installer *does* pair — driver, firmware, `tt-smi`, `tt-flash`, `sfpi` — is
still used, via the `--versions=release` invocation in every image.

---

## Build-time Arguments

| Argument | Default | Description |
|---|---|---|
| `TT_METAL_BUILD` | `checkout` | Build mode: `checkout`, `full`, or `sim` |
| `TTSIM_VERSION` | `latest` | ttsim release tag. `latest` tracks HEAD; pin (e.g. `v1.7.0`) for reproducible builds. Sim mode only. |
| `TT_METAL_COMMIT` | pinned SHA | tt-metal commit to check out (pinned images) |
| `TT_METAL_TAG` | `latest` | **latest-metal variant only.** tt-metal release tag; `latest` resolves the newest non-prerelease at build time. Also selects the matching `ttnn` wheel. |
| `VLLM_TT_PLUGIN_REF` | `main` | Ref of tenstorrent/vllm-tt-plugin to check out |
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
├── vllm-tt-plugin/                 ← tenstorrent/vllm-tt-plugin (no fork needed)
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
│   └── lib/python3.10/             │  upstream vLLM 0.24.0, vllm-tt-plugin (editable), hf CLI
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
├── apt-packages-base.txt           ← System packages every variant installs (shared, so they cannot drift)
├── apt-packages-toolchain.txt      ← Extra packages for variants that compile tt-metal (Dockerfile, Dockerfile.qb2)
├── check_apt_lists.py              ← CI guard: every variant sources the shared lists, nothing inlines packages
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

Must be done **after** `build_tt_metal.sh`. The plugin only activates when `ttnn` is importable, so it needs the compiled tt-metal Python extensions; `setup_envs.sh` fails loudly rather than leaving a vLLM that starts without TT hardware.

```bash
# VLLM_TT_PLUGIN_SRC defaults to ~/vllm-tt-plugin
bash /tmp/setup_envs.sh vllm

# Verify: the plugin must be importable AND its entry points registered.
# vLLM selects the TT platform only when `ttnn` imports, so an installed-but-
# undiscovered plugin looks like "vLLM works but sees no hardware".
tt-vllm
python -c "import vllm; print(vllm.__version__)"          # expect 0.24.0
python -c "import vllm_tt_plugin; print('plugin OK')"
python -c "import ttnn; print('ttnn OK')"
python -c "
from importlib.metadata import entry_points
for g in ('vllm.platform_plugins','vllm.general_plugins'):
    for e in entry_points(group=g): print(g, e.name, '->', e.value)
"
```

Starting a server logs `Platform plugin tt is activated` when discovery worked.

Multi-chip is selected with `MESH_DEVICE`, never `--tensor-parallel-size` (the TT
platform rejects tensor and pipeline parallelism). A TT-QuietBox 2 is
`MESH_DEVICE=P300x2`, which resolves to a `(1,4)` mesh over all four Blackhole chips.

> **`HF_MODEL` is required when `--model` is a local path.** tt-metal's
> `tt_transformers` uses `HF_MODEL` as its *checkpoint directory*
> (`model_config.py`: `self.CKPT_DIR = HF_MODEL`), so it must be either a
> HuggingFace `org/name` or the path to downloaded weights. Serving a local
> directory without it fails with "Please set HF_MODEL to a HuggingFace name".

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
  Dockerfile                  Main image definition (all three build modes; dev user; /opt/venv-* paths)
  Dockerfile.qb2              QB2-exact image — ttuser, QB2 venv paths, blackhole arch, tt-inference-server pre-cloned
  README.md                   Technical reference (build args, quick starts, two-Dockerfile guide)
  scripts/
    build_tt_metal.sh         Compiles tt-metal; also copied to /tmp/ in image (path-overridable via VENV_METAL)
    setup_envs.sh             Sets up venv-vllm and venv-forge; also in /tmp/ (paths overridable via VENV_VLLM/VENV_FORGE)
                              Wheel mode: set TTNN_WHEEL_VERSION to install a paired ttnn wheel instead of using a compiled tt-metal tree
    resolve_metal_release.sh  Resolves the tt-metal release tag + matching ttnn wheel version (--golden prints tt-installer's manifest value)
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

### QB2 image CI — on-demand from the CLI

`Dockerfile.qb2` is tested on the QuietBox itself with the on-demand runner
`docker/scripts/ci-qb2.sh` — **no GitHub runner, no registration; GitHub is not
involved.** Everything runs in Docker, so the host TT install is never modified;
cards are reached only via `--device /dev/tenstorrent` passthrough (inference
phase only).

```bash
docker/scripts/ci-qb2.sh              # golden-stack + checkout build + smoke  (default)
docker/scripts/ci-qb2.sh --fast       # checkout build + smoke only
docker/scripts/ci-qb2.sh --inference  # + full build & a real TTNN op on the cards (30–90 min)
docker/scripts/ci-qb2.sh --help
```

Phases (each mirrors a job in the optional workflow below):
- **golden-stack** — verifies the golden `release` version set installs clean on
  a bare `ubuntu:24.04` (throwaway container) and prints the resolved `.ttis`.
  This is the CLI equivalent of the [Install Tenstorrent Stack](https://github.com/marketplace/actions/install-tenstorrent-stack)
  action (the composite action only runs inside GitHub Actions).
- **build-qb2** — builds the image in checkout mode and runs
  `docker/scripts/qb2_smoke.sh` (user, venv paths, `tt-smi`/`hf` symlinks, arch
  var, source trees).
- **inference** — full build then a real TTNN op against the cards via
  passthrough. Opt-in (`--inference`) because the compile is 30–90 min.

**Optional GitHub-native path.** `.github/workflows/qb2-image.yml` runs the same
three jobs on a `[self-hosted, tenstorrent]` runner, but it is **dormant**:
`workflow_dispatch`-only (no push trigger) and it only executes if you later
register the QuietBox as a self-hosted runner. The CLI script above is the
supported path and needs none of that.

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

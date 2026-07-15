# Golden QB2 Image + CI — Design

**Date:** 2026-07-15
**Author:** Taylor Singletary
**Status:** Approved design, pending spec review

## Context

`docker/Dockerfile.qb2` reproduces a TT-QuietBox 2 (Blackhole) environment immediately
after first boot post-`tt-installer`: user `ttuser`, Ubuntu 24.04, the QB2 venv paths, and
`tt-inference-server` pre-cloned. It exists for VHS terminal recordings of the QB2 Guide and
for local testing that must mirror the QB2 user experience.

Two gaps motivate this work:

1. **The QB2 image has no CI.** The only workflow, `.github/workflows/docker-build.yml`,
   builds `docker/Dockerfile` (the general dev image) — never `Dockerfile.qb2`. Nothing
   catches a broken QB2 build.
2. **Tenstorrent shipped a first-class CI path for the installer.** The
   [Install Tenstorrent Stack](https://github.com/marketplace/actions/install-tenstorrent-stack)
   composite action (`tenstorrent/tt-installer`, latest release v3.4.0, 2026-07-13) installs
   the stack at a **golden** ("release" channel) version set and exports a `.ttis` state file.
   We want to use it to validate the same golden set the QB2 image bakes in.

This spec covers **Sub-project A** only. A follow-on **Sub-project B** (a Claude skill to
dispatch an arbitrary project into this image for clean-install + inference testing) is
explicitly out of scope here and will get its own spec once A is solid.

## Environment (verified 2026-07-15)

CI will run on the developer's own QuietBox 2, `tsingletaryTT-quietbox`:

- 4 Blackhole devices: `/dev/tenstorrent/0..3`
- Ubuntu 24.04.4, x86_64, 249 GB RAM, Docker 29.6.1
- Already installed: TT-KMD 2.10.0, tt-smi 5.2.0, pyluwen 0.8.1, tt-umd 0.9.5
- No self-hosted GitHub Actions runner registered yet (`total_count: 0`)

Because this is the developer's **working** machine, CI must not mutate the host.

## Decisions (settled during brainstorming)

- **CI model:** register this QB2 as a **self-hosted GitHub Actions runner** labeled
  `[self-hosted, tenstorrent]`. The new `qb2-image.yml` workflow runs here.
- **Host safety — container-isolated:** *every* CI step runs inside Docker. The host's
  KMD / firmware / HugePages / system packages are never modified. Real hardware reaches the
  cards via `--device /dev/tenstorrent` passthrough, not a host install. The
  `tenstorrent/tt-installer` action runs inside a throwaway job `container:` in
  `mode: container` (host-safe by construction).
- **Version strategy:** *track latest release* on the golden channel — `channel: release`
  for the action, `--versions=release` in the Dockerfile, and `tenstorrent/tt-installer@latest`
  for the action ref. No hard version pin.
- **No registry push.** No GHCR/storage for the QB2 image; images stay local to the runner.
  (Actions artifacts — used only for the tiny `.ttis` state file — are separate and kept.)
- **Installer stays inside the Docker build.** GitHub Actions cannot execute during
  `docker build`, so `Dockerfile.qb2` keeps invoking `install.sh` from a `RUN` layer. The
  action is used *alongside* the image build, in its own job.
- **Triggers:** `push` to `main` (on `docker/**` + workflow file) and `workflow_dispatch`.
  No `pull_request` trigger — avoids running workflow code on a self-hosted hardware box from
  fork PRs, and matches the approved preview.

## Goals

1. Update `Dockerfile.qb2`'s in-build `tt-installer` invocation to the current golden path
   (explicit `--versions=release`; flags refreshed against v3.4.0 `install.sh --help`).
2. Add a CI job that runs the `tenstorrent/tt-installer` action (container mode, golden
   channel) and publishes the resolved `.ttis` state file.
3. Add CI that builds `Dockerfile.qb2` and smoke-tests it, plus an on-demand real-inference
   job using device passthrough.

Non-goals: pinning to a specific installer version; the Sub-project B dispatch skill; changing
the dev-image workflow; pushing images to a registry; mutating the host TT install.

## Architecture

One new workflow file, `.github/workflows/qb2-image.yml`, all jobs
`runs-on: [self-hosted, tenstorrent]`.

### Triggers

```yaml
on:
  push:
    branches: [main]
    paths: ["docker/Dockerfile.qb2", "docker/scripts/**", "docker/debs/**", ".github/workflows/qb2-image.yml"]
  workflow_dispatch:
    inputs:
      run_inference: { description: "Full build + real inference on the cards", type: boolean, default: false }
```

### Job 1 — `golden-stack` (goal 2), host-safe

Runs the action inside a throwaway container so nothing touches the host.

```yaml
golden-stack:
  runs-on: [self-hosted, tenstorrent]
  container:
    image: ubuntu:24.04          # throwaway; host untouched
  steps:
    - uses: actions/checkout@v4
    - uses: tenstorrent/tt-installer@latest   # track latest release
      with:
        channel: release          # golden baseline
        mode: container           # skips KMD/HugePages/SFPI; no reboot
        update-firmware: off
        container-runtime: "no"   # ignored in container mode; explicit
        # export-schema-path defaults to $RUNNER_TEMP/tt-installer-state.ttis
        # upload-artifact defaults true → tiny .ttis published as an artifact
    - name: Record resolved golden versions
      run: cat "$RUNNER_TEMP"/tt-installer-state.ttis || true
```

The uploaded `.ttis` is the auditable record of exactly which golden versions resolved on this
run — the same set the QB2 image bakes in. (Device passthrough is not needed here; this job only
proves the golden set installs clean.)

### Job 2 — `build-qb2` (goals 1 + 3, fast path)

Builds the image in **checkout** mode and runs QB2 smoke tests. Runs on push and dispatch.

- Build `docker/Dockerfile.qb2` (`context: docker/`, `TT_METAL_BUILD=checkout`, local tag
  `qb2-env:ci`, no push). Use plain `docker build` on the runner (Buildx/GHA cache optional —
  local daemon cache is already warm on a self-hosted box).
- Smoke tests against the built image (checkout mode → no compiled TTNN):
  - **paths:** `~/tt-metal/python_env`, `~/tt-metal/build/python_env_vllm`, `~/tt-forge-venv`.
  - **PATH symlinks:** `~/.local/bin/tt-smi` and `~/.local/bin/hf` resolve and run
    (`tt-smi --help`, `hf --version`).
  - **arch var:** login shell has `TT_METAL_ARCH_NAME=blackhole`.
  - **source trees:** `~/tt-metal` at the pinned commit, `~/tt-vllm`,
    `~/.local/lib/tt-inference-server` all present.
  - **user identity:** running user is `ttuser` (UID 1000).

### Job 3 — `inference` (goal 3 real-hardware, on-demand)

Gated: `if: github.event_name == 'workflow_dispatch' && inputs.run_inference`. This is the heavy
path (full tt-metal compile is 30–90 min) so it is **not** on every push.

- Build `Dockerfile.qb2` with `TT_METAL_BUILD=full` (compiles TTNN).
- Run the built image with device passthrough and execute a minimal real op:
  ```bash
  docker run --rm --device /dev/tenstorrent \
    -v /dev/hugepages-1G:/dev/hugepages-1G \
    -e TT_METAL_ARCH_NAME=blackhole \
    qb2-env:ci-full bash -lc \
    'source ~/tt-metal/python_env/bin/activate && python -c "import ttnn; d=ttnn.open_device(device_id=0); print(ttnn.__version__); ttnn.close_device(d)"'
  ```
- Host is never modified; the cards are reached only through passthrough into the container.

> If the full build proves too slow to be useful as one job, the plan may split the build and
> the inference run, or cache the compiled `build/` — deferred to the plan.

## Dockerfile.qb2 change (goal 1)

In the existing step 6 `RUN` that runs `install.sh`, refresh the invocation:

- Add explicit `--versions=release` (currently relies on the default; make the golden intent
  visible and stable if the default ever changes).
- Keep the verified-present flags: `--mode-container`, `--mode-non-interactive`,
  `--python-choice=active-venv`, `--no-install-metalium-container`,
  `--no-install-forge-container`, `--no-install-inference-server`, `--no-install-studio`,
  `--update-firmware=off`. (All confirmed valid in latest `install.sh --help` on 2026-07-15.)
- Update the surrounding comment to state it installs the **golden ("release" channel)** set and
  that CI validates the same channel via the `tenstorrent/tt-installer` action.

No functional flag removals. The change is additive + documentation, because `--versions`
already defaults to `release`; CI is what newly guarantees this path keeps working.

## Runner registration (one-time setup)

Documented as a plan step (and in the workflow header comment), performed by the developer:

1. Repo → Settings → Actions → Runners → *New self-hosted runner* (Linux x64) to obtain the
   registration token.
2. Install under `~/actions-runner` on this QB2, configure with labels `self-hosted,tenstorrent`.
3. Run as a service (`svc.sh install && svc.sh start`) so CI survives logout.
4. The runner user must be in the `docker` group (device passthrough + build) — already true here.

## Testing strategy

- **CI is the test.** Job 2's smoke tests are the acceptance check for the Dockerfile change;
  Job 1 for the action integration; Job 3 (on demand) for real inference.
- **Local pre-flight:** build `Dockerfile.qb2` locally in checkout mode and run the smoke
  assertions before pushing, so CI isn't the first place the build is exercised.
- The `test-installer-in-qb2-container` skill targets a *different* repo's installer; not used
  here.

## Risks / open considerations

- `Dockerfile.qb2` has never been built in CI, so Job 2 may surface latent build breakage on a
  clean build (flag drift, network deps). Treat the first CI run as discovery, fix forward.
- **Self-hosted runner security:** the runner executes on the working QB2. Mitigated by
  container-isolation (no host mutation) and by omitting the `pull_request` trigger (no fork
  code runs). Only `push` to `main` and manual dispatch execute.
- `tenstorrent/tt-installer@latest` resolves the ref at run time; a new release could change
  behavior between runs. Accepted under "track latest"; the `.ttis` artifact makes any change
  auditable, and pinning the ref (`@v3.4.0`) is a one-line future mitigation.
- Full-build inference job is slow (30–90 min); kept manual/on-demand for that reason.
- Running the composite `tenstorrent/tt-installer` action inside a job `container:` may hit
  rough edges (the action `sudo`s and may assume a host-like environment). If it misbehaves in a
  container, the fallback is to run Job 1 directly on the runner but keep it host-safe with
  `mode: container` (it still skips KMD/HugePages/SFPI and never reboots) — decided in the plan
  after a first trial run.

## Out of scope → future

- **Sub-project B:** Claude skill to dispatch an arbitrary project into this image for clean
  install + inference. Separate spec, depends on A.
- Pinning to a fixed installer version / committed `.ttis` for byte-reproducible builds.
- Registry publication of the QB2 image (no storage today).

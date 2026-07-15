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

## Decisions (settled during brainstorming)

- **Structure:** a new dedicated workflow, `.github/workflows/qb2-image.yml`. The existing
  `docker-build.yml` (dev image) is left untouched.
- **Version strategy:** *track latest release* on the golden channel — i.e. keep using
  `releases/latest/download/install.sh` with `--versions=release`. No hard version pin.
- **Runners:** the repo has **zero self-hosted runners** registered today
  (`gh api repos/{owner}/{repo}/actions/runners` → `total_count: 0`). CI is therefore
  **hardware-less**: the action runs in `mode: container` on `ubuntu-latest`. A hardware
  inference job is scaffolded but dormant until a runner is registered.
- **Installer stays inside the Docker build.** GitHub Actions cannot execute during
  `docker build`, so the QB2 image keeps invoking `install.sh` from a `RUN` layer. The action
  is used *alongside* the image build (on the runner), not inside it.

## Goals

1. Update `Dockerfile.qb2`'s in-build `tt-installer` invocation to the current golden path
   (explicit `--versions=release`; flags refreshed against v3.4.0 `install.sh --help`).
2. Add a CI job that runs the `tenstorrent/tt-installer` action in container mode to validate
   the golden stack and publish the resolved `.ttis` state file.
3. Add CI that builds `Dockerfile.qb2` and smoke-tests it.

Non-goals: pinning to a specific installer version; the Sub-project B dispatch skill; changing
the dev-image workflow; running real inference in CI before a hardware runner exists.

## Architecture

One new workflow file, `.github/workflows/qb2-image.yml`, with three jobs.

### Triggers

```
on:
  push:        { branches: [main], paths: ["docker/Dockerfile.qb2", "docker/scripts/**", "docker/debs/**", ".github/workflows/qb2-image.yml"] }
  pull_request:{ branches: [main], paths: [ ...same... ] }
  workflow_dispatch: { inputs: { run_hardware: { type: boolean, default: false } } }
```

### Job 1 — `golden-stack` (goal 2)

Runs on `ubuntu-latest`. Validates that the golden version set installs clean on bare Ubuntu —
the same thing the QB2 image does inside its build, but observed independently and with a
machine-readable state file as output.

```yaml
- uses: tenstorrent/tt-installer@latest    # track latest release
  with:
    channel: release        # golden baseline
    mode: container         # hardware-less: skips KMD, HugePages, SFPI
    update-firmware: off
    container-runtime: "no" # ignored in container mode; explicit for clarity
    # export-schema-path defaults to $RUNNER_TEMP/tt-installer-state.ttis
    # upload-artifact defaults to true → .ttis appears as a workflow artifact
```

Post-install smoke checks on the runner: `tt-smi --version` (or equivalent), confirm the venv
the installer created exists, and print the `.ttis` for the log. The uploaded `.ttis` artifact
is the record of exactly which golden versions resolved on this run.

> Rationale for `tenstorrent/tt-installer@latest`: matches the "track latest release" decision.
> If reproducibility is later wanted, switch the ref to a tag (e.g. `@v3.4.0`) and/or feed a
> committed `.ttis` via `channel: path/to/file.ttis` — noted as a future option, not built now.

### Job 2 — `build-qb2` (goals 1 + 3)

Runs on `ubuntu-latest`. Mirrors the structure of the existing `docker-build.yml` build job.

- `docker/setup-buildx-action`, build `docker/Dockerfile.qb2` with `docker/build-push-action`
  (`context: docker/`, `TT_METAL_BUILD=checkout`, `load: true`, `push: false`, GHA cache).
- QB2-flavored smoke tests against the built image (all in checkout mode — no compiled TTNN):
  - **paths:** the QB2 venv paths exist — `~/tt-metal/python_env`,
    `~/tt-metal/build/python_env_vllm`, `~/tt-forge-venv`.
  - **symlinks on PATH:** `~/.local/bin/tt-smi` and `~/.local/bin/hf` resolve and run
    (`tt-smi --help`, `hf --version`).
  - **arch var:** `TT_METAL_ARCH_NAME=blackhole` is set in the login shell (QB2 default).
  - **source trees:** `~/tt-metal` at the pinned commit, `~/tt-vllm`,
    `~/.local/lib/tt-inference-server` all present.
  - **user identity:** running user is `ttuser` (UID 1000).
- Optional (nice-to-have, low risk): push `tenstorrent/qb2-env` to GHCR on `main` only, gated
  the same way `docker-build.yml` gates its push (`if: github.event_name != 'pull_request'`).
  Decision: **include the push**, tagged `qb2-latest` + `qb2-sha-<short>`, to keep parity with
  the dev image. Can be dropped in the plan if undesired.

### Job 3 — `hardware-inference` (goal-4 groundwork, dormant)

`runs-on: [self-hosted, tenstorrent]`, guarded by
`if: github.event_name == 'workflow_dispatch' && inputs.run_hardware`. With no self-hosted
runner registered it simply never gets a runner and stays queued/skipped, so it is harmless on
GitHub-hosted infra. When a QB2/Blackhole runner is later registered it will:

- run the `tenstorrent/tt-installer` action in `mode: hardware`, then
- run a minimal real inference / TTNN dispatch check against `/dev/tenstorrent`.

This job is scaffolded with clear comments but is **not expected to run** until a runner exists.
It is included now so the pattern is in place; the plan may split it into a follow-up if it
complicates review.

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

## Testing strategy

- **CI is the test.** Job 2's smoke tests are the acceptance check for the Dockerfile change;
  Job 1 is the acceptance check for the golden-stack action integration.
- **Local pre-flight:** build `Dockerfile.qb2` locally in checkout mode and run the same smoke
  assertions before pushing, so CI isn't the first place the build is exercised.
- The `test-installer-in-qb2-container` skill targets a *different* repo's installer and is not
  used here.

## Risks / open considerations

- `Dockerfile.qb2` has never been built in CI, so Job 2 may surface latent build breakage on a
  clean runner (missing build context, flag drift, network deps). That is the point — treat the
  first CI run as discovery and fix forward.
- `tenstorrent/tt-installer@latest` resolves the action ref at run time; a new installer release
  could change behavior between runs. Accepted under the "track latest" decision; the `.ttis`
  artifact makes any change auditable, and pinning the ref is a one-line future mitigation.
- GHCR push for the QB2 image is optional; if it causes tag confusion with the dev image it can
  be removed without affecting goals 1–3.

## Out of scope → future

- **Sub-project B:** Claude skill to dispatch an arbitrary project into this image for clean
  install + inference. Separate spec, depends on A.
- Pinning to a fixed installer version / committed `.ttis` for byte-reproducible builds.

# Golden QB2 Image + CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `docker/Dockerfile.qb2` a golden-channel installer path and real CI, run on the QuietBox 2 itself as a self-hosted, container-isolated runner.

**Architecture:** A new `.github/workflows/qb2-image.yml` runs three jobs on a `[self-hosted, tenstorrent]` runner (this QB2). Everything runs inside Docker — the host TT install is never mutated; cards reach CI only via `--device /dev/tenstorrent` passthrough. The `tenstorrent/tt-installer` action validates the golden set in a throwaway container; the image build bakes the same golden set via `install.sh --versions=release`; a reusable smoke script asserts the QB2 layout.

**Tech Stack:** Docker, GitHub Actions (self-hosted runner), `tenstorrent/tt-installer` composite action, Bash, tt-metal / TTNN.

## Global Constraints

- **Container-isolated — never mutate the host.** Every CI step runs in Docker; host KMD/firmware/HugePages/packages stay untouched. Hardware access is only via `--device /dev/tenstorrent` passthrough.
- **Golden channel, track latest.** Use `channel: release` (action), `--versions=release` (Dockerfile), and the `tenstorrent/tt-installer@latest` action ref. No version pin.
- **No registry push.** No GHCR/storage; images stay local to the runner. Only the tiny `.ttis` state file is an Actions artifact.
- **Runner label:** `self-hosted, tenstorrent`. **Repo:** `github.com/tsingletaryTT/tt-developer-image`.
- **No `pull_request` trigger** — never run fork code on the hardware box. Triggers are `push` to `main` + `workflow_dispatch` only.
- **Installer stays inside the Docker build** for the image (Actions can't run during `docker build`); the action is used only in its own CI job.

---

### Task 1: Dockerfile.qb2 — explicit golden channel

**Files:**
- Modify: `docker/Dockerfile.qb2` (comment block lines 137–145 and the `RUN` block lines 147–160)

**Interfaces:**
- Consumes: nothing.
- Produces: an image build that invokes `install.sh --versions=release` (golden). No new symbols.

- [ ] **Step 1: Verify the flag is valid in the current golden installer**

Run:
```bash
curl -fsSL https://github.com/tenstorrent/tt-installer/releases/latest/download/install.sh \
  | grep -m1 -- '--versions=\*'
```
Expected: a match line (confirms `--versions` is parsed). Already verified 2026-07-15; this guards against drift.

- [ ] **Step 2: Update the step-6 comment block**

Replace the comment block (lines 137–145, the `# 6.` header through the `VENV_METAL override…` paragraph) with:

```dockerfile
# ---------------------------------------------------------------------------
# 6. tt-installer (container mode, golden "release" channel)
# ---------------------------------------------------------------------------
# Run tt-installer with --mode-container so it populates venv-metal with
# tt-smi and hf CLI (same packages tt-installer puts there on a real QB2)
# and adds the Tenstorrent apt PPA (needed for tt-toplike in step 7).
#
# --versions=release pins the *golden* baseline: the tested version set baked
# into each tt-installer release. CI (.github/workflows/qb2-image.yml) validates
# this same channel independently via the tenstorrent/tt-installer action.
#
# Activating the venv before running makes --python-choice=active-venv target
# ~/tt-metal/python_env/ instead of tt-installer's own default path.
```

- [ ] **Step 3: Add `--versions=release` to the RUN block**

In the `./install.sh \` invocation, add the flag as the first option (right after `./install.sh \`):

```dockerfile
    ./install.sh \
      --versions=release \
      --mode-container \
      --mode-non-interactive \
      --python-choice=active-venv \
      --no-install-metalium-container \
      --no-install-forge-container \
      --no-install-inference-server \
      --no-install-studio \
      --update-firmware=off && \
    rm -f install.sh"
```

- [ ] **Step 4: Static verification**

Run:
```bash
grep -n -- '--versions=release' docker/Dockerfile.qb2
```
Expected: one match inside the step-6 `RUN` block.

- [ ] **Step 5: Commit**

```bash
git add docker/Dockerfile.qb2
git commit -m "feat(qb2): pin in-build tt-installer to golden 'release' channel"
```

---

### Task 2: Reusable QB2 smoke-test script + first real build

**Files:**
- Create: `docker/scripts/qb2_smoke.sh`
- Test: the script is its own test harness (run against a wrong image → fail, correct image → pass)

**Interfaces:**
- Consumes: a built image tag (positional arg `$1`), e.g. the `qb2-env:ci` image built in Step 3 from Task 1's Dockerfile.
- Produces: `docker/scripts/qb2_smoke.sh <image-tag>` — exits 0 and prints `ALL QB2 SMOKE CHECKS PASSED` iff the image matches the post-tt-installer QB2 layout. Used by `build-qb2` in Task 3.

- [ ] **Step 1: Write the smoke script**

Create `docker/scripts/qb2_smoke.sh`:

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x docker/scripts/qb2_smoke.sh
```

- [ ] **Step 3: Run against a wrong image to see it fail**

Run:
```bash
docker pull ubuntu:24.04
docker/scripts/qb2_smoke.sh ubuntu:24.04; echo "exit=$?"
```
Expected: fails on the first check (user is `root`, not `ttuser`), non-zero exit. Confirms the script actually asserts something.

- [ ] **Step 4: Build the QB2 image (checkout mode) — the real integration test**

Run (this clones tt-metal + submodules, tt-vllm, inference-server and installs the golden stack + forge venv; expect several minutes, needs Tenstorrent-network PyPI access which this QB2 has):
```bash
docker build -f docker/Dockerfile.qb2 --build-arg TT_METAL_BUILD=checkout -t qb2-env:ci docker/
```
Expected: build succeeds; the step-6 layer shows `install.sh` running with `--versions=release`.

- [ ] **Step 5: Run the smoke script against the built image**

Run:
```bash
docker/scripts/qb2_smoke.sh qb2-env:ci; echo "exit=$?"
```
Expected: every check prints `OK` and the final line is `ALL QB2 SMOKE CHECKS PASSED`, `exit=0`.

- [ ] **Step 6: Commit**

```bash
git add docker/scripts/qb2_smoke.sh
git commit -m "test(qb2): add reusable qb2_smoke.sh layout assertions"
```

---

### Task 3: The `qb2-image.yml` workflow

**Files:**
- Create: `.github/workflows/qb2-image.yml`

**Interfaces:**
- Consumes: `docker/Dockerfile.qb2` (Task 1), `docker/scripts/qb2_smoke.sh` (Task 2), a registered `[self-hosted, tenstorrent]` runner (Task 5).
- Produces: three jobs — `golden-stack`, `build-qb2`, `inference`.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/qb2-image.yml`:

```yaml
# .github/workflows/qb2-image.yml
#
# CI for the QB2-exact image (docker/Dockerfile.qb2). Runs on the QuietBox 2
# itself, registered as a self-hosted runner labelled [self-hosted, tenstorrent].
#
# HOST SAFETY: every step runs inside Docker. The host's KMD / firmware /
# HugePages / system packages are NEVER modified. Real cards reach CI only via
# --device /dev/tenstorrent passthrough. The tenstorrent/tt-installer action
# runs inside a throwaway container in mode: container.
#
# Runner registration (one-time, on the QB2) — see README "QB2 image CI".
#
# Triggers: push to main (docker/** or this file) + manual dispatch.
# NO pull_request trigger — never run fork code on the hardware box.

name: QB2 Image CI

on:
  push:
    branches: [main]
    paths:
      - "docker/Dockerfile.qb2"
      - "docker/scripts/**"
      - "docker/debs/**"
      - ".github/workflows/qb2-image.yml"
  workflow_dispatch:
    inputs:
      run_inference:
        description: "Full build + real inference on the cards (30-90 min)"
        type: boolean
        default: false

jobs:
  # -------------------------------------------------------------------------
  # Validate the golden version set installs clean, host-safe (throwaway
  # container). Publishes the resolved .ttis as an artifact.
  # -------------------------------------------------------------------------
  golden-stack:
    name: Golden stack via tt-installer action
    runs-on: [self-hosted, tenstorrent]
    container:
      image: ubuntu:24.04
    steps:
      - name: Install golden Tenstorrent stack (container mode)
        uses: tenstorrent/tt-installer@latest
        with:
          channel: release
          mode: container
          update-firmware: off
          container-runtime: "no"

      - name: Show resolved golden versions (.ttis)
        run: cat "${RUNNER_TEMP}/tt-installer-state.ttis" || echo "no .ttis found"

  # -------------------------------------------------------------------------
  # Build Dockerfile.qb2 (checkout) + smoke tests. Runs on every push.
  # -------------------------------------------------------------------------
  build-qb2:
    name: Build (checkout) + smoke tests
    runs-on: [self-hosted, tenstorrent]
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build image (checkout mode)
        run: |
          docker build \
            -f docker/Dockerfile.qb2 \
            --build-arg TT_METAL_BUILD=checkout \
            -t qb2-env:ci \
            docker/

      - name: Smoke test
        run: docker/scripts/qb2_smoke.sh qb2-env:ci

      - name: Clean up image
        if: always()
        run: docker rmi qb2-env:ci || true

  # -------------------------------------------------------------------------
  # Full build + real inference on the cards. On-demand only (30-90 min).
  # -------------------------------------------------------------------------
  inference:
    name: Full build + real inference (on demand)
    if: github.event_name == 'workflow_dispatch' && inputs.run_inference
    runs-on: [self-hosted, tenstorrent]
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build image (full mode — compiles TTNN)
        run: |
          docker build \
            -f docker/Dockerfile.qb2 \
            --build-arg TT_METAL_BUILD=full \
            -t qb2-env:ci-full \
            docker/

      - name: Real TTNN op on the cards (device passthrough)
        run: |
          docker run --rm \
            --device /dev/tenstorrent \
            -v /dev/hugepages-1G:/dev/hugepages-1G \
            -e TT_METAL_ARCH_NAME=blackhole \
            qb2-env:ci-full \
            bash -lc 'source "$HOME/tt-metal/python_env/bin/activate" && \
              python -c "import ttnn; d=ttnn.open_device(device_id=0); print(\"TTNN\", ttnn.__version__); ttnn.close_device(d)"'

      - name: Clean up image
        if: always()
        run: docker rmi qb2-env:ci-full || true
```

- [ ] **Step 2: Validate YAML parses**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/qb2-image.yml')); print('YAML OK')"
```
Expected: `YAML OK`.

- [ ] **Step 3: Lint with actionlint (dockerized — no host install)**

Run:
```bash
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest -color .github/workflows/qb2-image.yml
```
Expected: no errors (exit 0). If actionlint flags `inputs.run_inference` typing, confirm the `workflow_dispatch.inputs.run_inference` block is present — that is the fix, not an error.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/qb2-image.yml
git commit -m "ci(qb2): add self-hosted, container-isolated QB2 image workflow"
```

---

### Task 4: Documentation — README CI section + session log

**Files:**
- Modify: `README.md` (add a "QB2 image CI" subsection near the existing GHCR/push section around line 482)
- Modify: `CLAUDE.md` (append a short session log per the working-style rule)

**Interfaces:**
- Consumes: the workflow and runner label from Tasks 3 & 5.
- Produces: docs only.

- [ ] **Step 1: Add the README CI section**

Append this subsection to `README.md` (after the existing "Build on a QB2 … push manually" block near line 482):

```markdown
### QB2 image CI (self-hosted, container-isolated)

`.github/workflows/qb2-image.yml` tests `Dockerfile.qb2` on a real QuietBox 2
registered as a self-hosted GitHub Actions runner. **Every step runs in Docker —
the host TT install is never modified**; cards reach CI only via
`--device /dev/tenstorrent` passthrough.

Jobs:
- **golden-stack** — runs the [Install Tenstorrent Stack](https://github.com/marketplace/actions/install-tenstorrent-stack)
  action (`channel: release`, `mode: container`) in a throwaway container and
  publishes the resolved `.ttis` version set as an artifact.
- **build-qb2** — builds the image in checkout mode and runs
  `docker/scripts/qb2_smoke.sh` (paths, venvs, `tt-smi`/`hf` symlinks, arch var,
  source trees). Runs on every push to `main`.
- **inference** — on-demand only (`workflow_dispatch` → `run_inference: true`):
  full build (30–90 min) then a real TTNN op against the cards via passthrough.

**One-time runner registration** (on the QB2):

```bash
# Repo → Settings → Actions → Runners → New self-hosted runner (Linux x64)
# copy the registration TOKEN, then:
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o actions-runner.tar.gz -L \
  https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64.tar.gz
tar xzf actions-runner.tar.gz
./config.sh --url https://github.com/tsingletaryTT/tt-developer-image \
  --token <TOKEN> --labels self-hosted,tenstorrent --unattended
sudo ./svc.sh install && sudo ./svc.sh start   # run as a service
```

The runner user must be in the `docker` group (already true on this QB2).
```

- [ ] **Step 2: Verify the README edit**

Run:
```bash
grep -n "QB2 image CI (self-hosted" README.md
```
Expected: one match.

- [ ] **Step 3: Append a session log to CLAUDE.md**

Append to the end of `CLAUDE.md`:

```markdown

## Session log

### 2026-07-15 — Golden QB2 image + CI (sub-project A)
Prompt: use the "Install Tenstorrent Stack" GitHub Action + latest golden
installer path for QB2-image testing.
- Pinned `Dockerfile.qb2` step 6 to `install.sh --versions=release` (golden).
- Added `.github/workflows/qb2-image.yml`: self-hosted `[self-hosted,tenstorrent]`
  runner on the QuietBox, fully container-isolated (host never mutated; cards via
  `--device` passthrough). Jobs: golden-stack (action, container mode, `.ttis`
  artifact), build-qb2 (checkout + `qb2_smoke.sh`), inference (on-demand full build).
- Added reusable `docker/scripts/qb2_smoke.sh`.
- Decisions: track latest golden release (no version pin); no registry push (no
  storage); no `pull_request` trigger (no fork code on hardware).
- Sub-project B (Claude skill to dispatch arbitrary projects into the image for
  clean-install + inference) is deferred to its own spec.
Spec: `docs/superpowers/specs/2026-07-15-golden-qb2-image-ci-design.md`.
```

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs(qb2): document QB2 image CI and self-hosted runner setup"
```

---

### Task 5: Register the runner and validate end-to-end (requires user action)

**Files:** none (operational).

**Interfaces:**
- Consumes: the workflow (Task 3). Requires a GitHub runner registration token, which only the repo admin (the user) can mint from Settings → Actions → Runners.
- Produces: a live, green CI run proving the whole chain works.

- [ ] **Step 1: Register the runner**

Follow the README "One-time runner registration" block on this QB2 with a fresh token from
`https://github.com/tsingletaryTT/tt-developer-image/settings/actions/runners/new`.
This step needs the user (admin token); the agent should pause and ask the user to perform it or
paste the token via a `!`-prefixed command.

- [ ] **Step 2: Confirm the runner is online**

Run:
```bash
gh api repos/tsingletaryTT/tt-developer-image/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```
Expected: one runner, `"status": "online"`, labels include `self-hosted` and `tenstorrent`.

- [ ] **Step 3: Trigger the fast path (push already did, or dispatch)**

Run:
```bash
gh workflow run qb2-image.yml --ref main
gh run list --workflow qb2-image.yml -L 1
```
Expected: a run appears and picks up on the self-hosted runner.

- [ ] **Step 4: Watch it to green**

Run:
```bash
gh run watch "$(gh run list --workflow qb2-image.yml -L 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```
Expected: `golden-stack` and `build-qb2` succeed (the `inference` job is skipped — dispatch it separately with `-f run_inference=true` when you want the 30–90 min real-hardware run).

- [ ] **Step 5: Verify the `.ttis` artifact exists**

Run:
```bash
gh run view "$(gh run list --workflow qb2-image.yml -L 1 --json databaseId --jq '.[0].databaseId')" --json jobs \
  | python3 -c "import json,sys; print('golden-stack ran')"
gh api repos/tsingletaryTT/tt-developer-image/actions/artifacts --jq '.artifacts[].name' | head
```
Expected: an artifact from the `tenstorrent/tt-installer` action (the `.ttis` state file) is listed.

---

## Notes for the implementer

- **Order matters:** Task 2 Step 4 builds `qb2-env:ci` and is the real integration test for Task 1. If the build fails on flag drift, re-run Task 1 Step 1 and reconcile against `install.sh --help`.
- **Action-in-container fallback (from the spec):** if `golden-stack` misbehaves because the composite action dislikes running inside a job `container:`, drop the `container:` key and run it directly on the runner — it stays host-safe because `mode: container` skips KMD/HugePages/SFPI and never reboots. Decide this only after observing a real failure in Task 5.
- **Inference job cost:** the `full` build is 30–90 min; never wire it to `push`. It stays behind `workflow_dispatch` + `run_inference`.

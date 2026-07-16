#!/usr/bin/env bash
# ci-qb2.sh — on-demand, LOCAL CI for the QB2-exact image.
#
# Runs the same checks the .github/workflows/qb2-image.yml workflow would, but
# straight from the CLI on this QuietBox — GitHub is never involved, no runner
# registration needed. Use it whenever you want to validate a change to
# Dockerfile.qb2 / the scripts before (or instead of) pushing.
#
# HOST SAFETY: everything runs inside Docker. The host's KMD / firmware /
# HugePages / system packages are never modified. Real cards are reached only
# via --device /dev/tenstorrent passthrough (inference phase only).
#
# Phases (mirror the workflow's three jobs):
#   golden-stack  validate the golden "release" version set installs clean on a
#                 bare ubuntu:24.04 (throwaway container); prints the resolved
#                 .ttis. Runs install.sh directly — the composite GitHub Action
#                 only works inside Actions, this is its CLI equivalent.
#   build-qb2     build Dockerfile.qb2 (checkout) + run qb2_smoke.sh
#   inference     build Dockerfile.qb2 (full, compiles TTNN) + run a real TTNN
#                 op on the cards via passthrough. 30-90 min; opt-in only.
#
# Usage:
#   ci-qb2.sh                 golden-stack + build-qb2 + smoke   (default)
#   ci-qb2.sh --fast          build-qb2 + smoke only (skip golden-stack)
#   ci-qb2.sh --inference     the default phases, THEN full build + real inference
#   ci-qb2.sh --help
set -euo pipefail

# --- locate the repo's docker/ dir relative to this script (works from anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # docker/scripts/.. == docker/

RUN_GOLDEN=1
RUN_INFERENCE=0

usage() {
  cat <<'USAGE'
ci-qb2.sh — on-demand, LOCAL CI for the QB2-exact image (no GitHub involved).

Runs the same checks as .github/workflows/qb2-image.yml, from the CLI on this
QuietBox. Everything runs in Docker; the host is never modified. Cards are
reached only via --device passthrough (inference phase only).

Phases:
  golden-stack  golden "release" set installs clean on bare ubuntu:24.04
  build-qb2     build Dockerfile.qb2 (checkout) + run qb2_smoke.sh
  inference     full build (compiles TTNN) + real TTNN op on the cards

Usage:
  ci-qb2.sh                golden-stack + build-qb2 + smoke   (default)
  ci-qb2.sh --fast         build-qb2 + smoke only (skip golden-stack)
  ci-qb2.sh --inference    default phases, THEN full build + real inference
  ci-qb2.sh --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --fast)      RUN_GOLDEN=0 ;;
    --inference) RUN_INFERENCE=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $arg" >&2; usage; exit 2 ;;
  esac
done

banner() { printf '\n╔══════════════════════════════════════════\n║  %s\n╚══════════════════════════════════════════\n' "$1"; }

# ---------------------------------------------------------------------------
# Phase 1 — golden-stack: golden set installs clean on bare ubuntu (host-safe)
# ---------------------------------------------------------------------------
if [ "$RUN_GOLDEN" = 1 ]; then
  banner "golden-stack: validating golden 'release' set on bare ubuntu:24.04"
  docker run --rm ubuntu:24.04 bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
      sudo ca-certificates curl wget git jq python3 python3-venv python3-pip >/dev/null
    curl -fsSLO https://github.com/tenstorrent/tt-installer/releases/latest/download/install.sh
    chmod +x install.sh
    ./install.sh \
      --versions=release \
      --mode-container \
      --mode-non-interactive \
      --reboot-option=never \
      --update-firmware=off \
      --install-container-runtime=no \
      --export-schema /tmp/state.ttis
    echo "--- resolved golden versions (.ttis) ---"
    cat /tmp/state.ttis
  '
  echo "golden-stack OK"
fi

# ---------------------------------------------------------------------------
# Phase 2 — build-qb2: checkout build + smoke tests
# ---------------------------------------------------------------------------
banner "build-qb2: building Dockerfile.qb2 (checkout) + smoke tests"
docker build \
  -f "${DOCKER_DIR}/Dockerfile.qb2" \
  --build-arg TT_METAL_BUILD=checkout \
  -t qb2-env:ci \
  "${DOCKER_DIR}"
"${DOCKER_DIR}/scripts/qb2_smoke.sh" qb2-env:ci

# ---------------------------------------------------------------------------
# Phase 3 — inference: full build + real TTNN op on the cards (opt-in)
# ---------------------------------------------------------------------------
if [ "$RUN_INFERENCE" = 1 ]; then
  banner "inference: full build + real TTNN op on the cards (30-90 min)"
  docker build \
    -f "${DOCKER_DIR}/Dockerfile.qb2" \
    --build-arg TT_METAL_BUILD=full \
    -t qb2-env:ci-full \
    "${DOCKER_DIR}"
  docker run --rm \
    --device /dev/tenstorrent \
    -v /dev/hugepages-1G:/dev/hugepages-1G \
    -e TT_METAL_ARCH_NAME=blackhole \
    qb2-env:ci-full \
    bash -lc 'source "$HOME/tt-metal/python_env/bin/activate" && \
      python -c "import ttnn; d=ttnn.open_device(device_id=0); print(\"TTNN\", ttnn.__version__); ttnn.close_device(d)"'
  echo "inference OK"
fi

banner "ci-qb2 complete — all requested phases passed"

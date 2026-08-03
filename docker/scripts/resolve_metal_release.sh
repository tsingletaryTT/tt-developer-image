#!/usr/bin/env bash
# resolve_metal_release.sh — decide which tt-metal release the image should use.
#
# Prints two shell assignments on stdout, for `eval` by the caller:
#
#   TT_METAL_TAG=v0.75.0
#   TTNN_VERSION=0.75.0
#
# Why this exists
# ---------------
# The pinned image (Dockerfile / Dockerfile.qb2) tracks a specific tt-metal commit
# for reproducibility. The "latest metal" variant instead follows tt-metal's newest
# *release tag*, because a raw commit SHA drifts out of sync with everything that is
# version-paired against a release (vLLM plugin expectations, model implementations,
# firmware).
#
# Note on tt-installer: its golden manifest (tt-sw-manifest) does publish a
# `metal-version` field, but tt-installer itself never reads it — grep install.m4
# and you will find no reference. tt-installer delivers metalium as a *container*
# wrapper, which cannot provide the importable `ttnn` that the vLLM plugin needs.
# So the golden manifest is a useful cross-check, not a source we can install from.
# Use --golden to print it for comparison.
#
# Usage:
#   eval "$(resolve_metal_release.sh)"               # newest release
#   eval "$(resolve_metal_release.sh v0.75.0)"       # explicit pin (passthrough)
#   resolve_metal_release.sh --golden                # what tt-installer's manifest names
set -euo pipefail

GH_API="https://api.github.com/repos/tenstorrent/tt-metal"
# Kept in step with tt-installer's TTIS_GOLDEN_VERSIONS_TAG.
GOLDEN_TAG="${TTIS_GOLDEN_VERSIONS_TAG:-v2026.06.26}"
GOLDEN_URL="https://github.com/tenstorrent/tt-sw-manifest/releases/download/${GOLDEN_TAG}/golden.json"

die() { echo "resolve_metal_release: $*" >&2; exit 1; }

if [[ "${1:-}" == "--golden" ]]; then
    curl -fsSL "$GOLDEN_URL" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("metal-version","(absent)"))' \
        || die "could not fetch golden manifest ${GOLDEN_TAG}"
    exit 0
fi

TAG="${1:-}"

if [[ -z "$TAG" || "$TAG" == "latest" ]]; then
    # /releases/latest excludes prereleases, which is what we want: tt-metal cuts
    # many -rcN tags and those are not the release line we track.
    TAG=$(curl -fsSL "${GH_API}/releases/latest" \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])') \
        || die "could not resolve latest tt-metal release"
fi

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "unexpected tag format: $TAG"

# The ttnn wheel on PyPI is published without the leading "v".
TTNN_VERSION="${TAG#v}"

# Fail early and loudly if the paired wheel is missing, rather than at pip time
# deep inside a Docker layer.
curl -fsS -o /dev/null "https://pypi.org/pypi/ttnn/${TTNN_VERSION}/json" \
    || die "no ttnn wheel published for ${TTNN_VERSION} (tag ${TAG})"

echo "TT_METAL_TAG=${TAG}"
echo "TTNN_VERSION=${TTNN_VERSION}"

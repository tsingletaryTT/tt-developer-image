#!/bin/bash
# install_system_deps.sh
#
# Optional standalone script for system-level dependencies.
# The Dockerfile inlines these same steps; use this if you prefer
# to run system dep installation separately (e.g. on bare metal).
#
# Must be run as root or via sudo.

set -euo pipefail

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  bash ca-certificates curl wget git sudo apt-transport-https gnupg lsb-release \
  build-essential ninja-build cmake pkg-config \
  python3.10 python3.10-venv python3.10-dev \
  python3.11 python3.11-venv python3.11-dev \
  python3-pip \
  clang-17 clang++-17 \
  protobuf-compiler libprotobuf-dev \
  libnuma-dev libhwloc-dev libboost-all-dev libnsl-dev \
  cpufrequtils linux-tools-common linux-tools-generic \
  iproute2 iputils-ping

sudo rm -rf /var/lib/apt/lists/*

# Ensure 'clang' / 'clang++' resolve to clang-17 for build scripts
sudo ln -sf /usr/bin/clang-17 /usr/local/bin/clang
sudo ln -sf /usr/bin/clang++-17 /usr/local/bin/clang++

echo ">>> System deps installed"

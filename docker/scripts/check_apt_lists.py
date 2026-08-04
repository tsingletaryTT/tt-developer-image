#!/usr/bin/env python3
"""Guard against the image variants drifting apart on apt packages.

Why this exists: `jq` was added to Dockerfile.qb2 in 03cb664 but not to the
standard Dockerfile, which then sat broken for three weeks — tt-installer
defaults to its `release` version channel, which parses the golden .ttis
manifest with jq, and the standard Dockerfile was the only variant CI built.

Two invariants are checked:

  1. Every variant sources its packages from scripts/apt-packages-*.txt, so a
     package cannot be added to one variant and forgotten in another.
  2. Nothing installs a package list inline, which would reopen that hole.

Two apt patterns are legitimately not package lists and are allowed:

  * the PPA bootstrap — `apt-get install ... software-properties-common`, which
    has to run before the deadsnakes PPA exists and therefore before the lists
  * `apt-get install -f`, which repairs dpkg dependencies and names no packages

Usage:  check_apt_lists.py [docker_dir]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

VARIANTS = {
    "Dockerfile": {"base", "toolchain"},
    "Dockerfile.qb2": {"base", "toolchain"},
    # latest-metal never compiles tt-metal — it takes the ttnn wheel — so the
    # compiler/protobuf/boost stack would be dead weight in an ~18.5 GB image.
    "Dockerfile.latest-metal": {"base"},
}
LISTS = {"base": "apt-packages-base.txt", "toolchain": "apt-packages-toolchain.txt"}


def packages(path: Path) -> list[str]:
    """Package names in a list file, with comments and blank lines stripped."""
    out: list[str] = []
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        out.extend(line.split())
    return out


def inline_installs(text: str) -> list[tuple[int, str]]:
    """`apt-get install` sites that are neither list-driven nor an allowed exception."""
    offenders = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if "apt-get install" not in line:
            continue
        if "xargs apt-get install" in line:      # driven by a shared list
            continue
        if re.search(r"apt-get install\s+-f\b", line):  # dpkg dependency repair
            continue
        # The PPA bootstrap puts its single package on a continuation line.
        window = " ".join(lines[i : i + 3])
        if "software-properties-common" in window:
            continue
        offenders.append((i + 1, line.strip()))
    return offenders


def main() -> int:
    docker_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "docker")
    failures = 0

    for name, wanted in LISTS.items():
        path = docker_dir / "scripts" / wanted
        if not path.is_file():
            print(f"ERROR: missing {path}")
            failures += 1
            continue
        pkgs = packages(path)
        if not pkgs:
            print(f"ERROR: {path} resolved to zero packages")
            failures += 1
        print(f"  {wanted}: {len(pkgs)} packages")

    base_path = docker_dir / "scripts" / LISTS["base"]
    if base_path.is_file() and "jq" not in packages(base_path):
        print("ERROR: jq missing from the base list — tt-installer's release "
              "channel parses the golden manifest with it")
        failures += 1

    for variant, needed in VARIANTS.items():
        path = docker_dir / variant
        if not path.is_file():
            print(f"ERROR: missing {path}")
            failures += 1
            continue
        text = path.read_text()

        for kind in ("base", "toolchain"):
            uses = LISTS[kind] in text
            if kind in needed and not uses:
                print(f"ERROR: {variant} should use {LISTS[kind]} and does not")
                failures += 1
            if kind not in needed and uses:
                print(f"ERROR: {variant} uses {LISTS[kind]} but is not expected to")
                failures += 1

        for lineno, line in inline_installs(text):
            print(f"ERROR: {variant}:{lineno} installs packages inline; add them "
                  f"to scripts/apt-packages-*.txt instead\n         {line}")
            failures += 1

        print(f"  {variant}: uses {sorted(needed)}")

    print("apt list guard: OK" if not failures else f"apt list guard: {failures} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

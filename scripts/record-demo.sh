#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p assets
mise exec -- zig build -Doptimize=ReleaseFast
mise exec -- vhs demo/pts.tape

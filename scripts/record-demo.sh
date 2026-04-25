#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p assets
mise exec -- zig build
export PATH="$PWD/zig-out/bin:$PATH"
mise exec -- vhs demo/pts.tape

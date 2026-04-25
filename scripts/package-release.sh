#!/usr/bin/env bash
set -euo pipefail

target="${1:?target required}"
archive="${2:-tar.gz}"
name="pts-${target}"
root="dist/${name}"

rm -rf dist
mkdir -p "$root"

optimize="${OPTIMIZE:-ReleaseFast}"
zig build -Dtarget="$target" -Doptimize="$optimize"

bin="zig-out/bin/pts"
if [[ "$target" == *windows* ]]; then
  bin="zig-out/bin/pts.exe"
fi

cp "$bin" "$root/"
cp README.md LICENSE "$root/"

case "$archive" in
  tar.gz)
    tar -C dist -czf "dist/${name}.tar.gz" "$name"
    ;;
  zip)
    (cd dist && zip -qr "${name}.zip" "$name")
    ;;
  *)
    echo "unknown archive: $archive" >&2
    exit 2
    ;;
esac

rm -rf "$root"

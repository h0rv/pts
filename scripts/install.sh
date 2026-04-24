#!/usr/bin/env sh
set -eu

repo="h0rv/pts"
version="${PTS_VERSION:-latest}"
prefix="${PREFIX:-$HOME/.local}"
bin_dir="$prefix/bin"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"

case "$os" in
  linux) os="linux" ;;
  darwin) os="macos" ;;
  *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac

case "$arch" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac

asset="pts-${arch}-${os}.tar.gz"
if [ "$version" = "latest" ]; then
  url="https://github.com/$repo/releases/latest/download/$asset"
else
  url="https://github.com/$repo/releases/download/$version/$asset"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$bin_dir"
echo "downloading $url"
curl -fsSL "$url" -o "$tmp/pts.tar.gz"
tar -xzf "$tmp/pts.tar.gz" -C "$tmp"
install -m 0755 "$tmp/pts-${arch}-${os}/pts" "$bin_dir/pts"

echo "installed $bin_dir/pts"
echo "run: pts --help"

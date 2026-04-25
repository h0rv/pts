#!/usr/bin/env bash
set -euo pipefail

version="${1:?version required, e.g. v0.1.0}"
dist_dir="${2:-dist}"
repo="${PTS_REPO:-h0rv/pts}"
plain_version="${version#v}"

sha() {
  sha256sum "$dist_dir/$1" | awk '{print $1}'
}

linux_x86="pts-x86_64-linux.tar.gz"
linux_arm="pts-aarch64-linux.tar.gz"
mac_x86="pts-x86_64-macos.tar.gz"
mac_arm="pts-aarch64-macos.tar.gz"

cat <<EOF
class Pts < Formula
  desc "Sports scores CLI/TUI powered by Plain Text Sports"
  homepage "https://github.com/$repo"
  version "$plain_version"
  license "MIT"

  on_macos do
    on_intel do
      url "https://github.com/$repo/releases/download/$version/$mac_x86"
      sha256 "$(sha "$mac_x86")"
    end

    on_arm do
      url "https://github.com/$repo/releases/download/$version/$mac_arm"
      sha256 "$(sha "$mac_arm")"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/$repo/releases/download/$version/$linux_x86"
      sha256 "$(sha "$linux_x86")"
    end

    on_arm do
      url "https://github.com/$repo/releases/download/$version/$linux_arm"
      sha256 "$(sha "$linux_arm")"
    end
  end

  def install
    bin.install Dir["pts*/pts"].first
  end

  test do
    assert_match "pts #{version}", shell_output("#{bin}/pts --version")
  end
end
EOF

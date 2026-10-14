#!/bin/zsh
# Fetch official, checksum-pinned macOS binaries; no source patch or Go toolchain.
set -euo pipefail
project_dir="${PROJECT_DIR:-${0:A:h:h}}"
version="1.75.1"
cache_dir="$project_dir/.build/rclone-artifacts/v${version}"
mkdir -p "$cache_dir"
for runtime_arch in arm64 amd64; do
    case "$runtime_arch" in
        arm64) expected_sha="c61d7a371c62bcbbe882c3423aa4b8bf63485c248dd0f692997b8f0c3f6d0c6f" ;;
        amd64) expected_sha="29253d0288b8fbbac46baad6e5f6add6cb01d462c79f10805bbd4631c4cdf82c" ;;
    esac
    archive="$cache_dir/rclone-v${version}-osx-${runtime_arch}.zip"
    if [[ ! -f "$archive" ]]; then
        curl --fail --location --silent --show-error --max-time 180 \
            "https://downloads.rclone.org/v${version}/rclone-v${version}-osx-${runtime_arch}.zip" -o "$archive.tmp"
        mv "$archive.tmp" "$archive"
    fi
    [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$expected_sha" ]] || { print -u2 'Official rclone checksum mismatch'; exit 1; }
    unpack_dir="$cache_dir/unpacked-${runtime_arch}"
    unzip -oq "$archive" -d "$unpack_dir"
    install -m 0755 "$unpack_dir/rclone-v${version}-osx-${runtime_arch}/rclone" "$cache_dir/rclone-${runtime_arch}"
done
print "$cache_dir"

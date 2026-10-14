#!/bin/zsh
# Install the same checksum-pinned official runtime packaged with FreeMount.
set -euo pipefail
project_dir="${0:A:h:h}"
case "$(uname -m)" in
    arm64) runtime_arch="arm64" ;;
    x86_64) runtime_arch="amd64" ;;
    *) print -u2 "Unsupported macOS architecture"; exit 1 ;;
esac
artifact_dir="$("$project_dir/scripts/download-rclone-runtime.sh")"
runtime_dir="${FREEMOUNT_RUNTIME_DIR:-$HOME/Library/Application Support/FreeMount/bin}"
mkdir -p "$runtime_dir"
install -m 0755 "$artifact_dir/rclone-$runtime_arch" "$runtime_dir/rclone.tmp"
codesign --force --sign - "$runtime_dir/rclone.tmp"
[[ "$("$runtime_dir/rclone.tmp" version | head -n 1)" == "rclone v1.75.1" ]] || { print -u2 "Unexpected official runtime version"; exit 1; }
mv "$runtime_dir/rclone.tmp" "$runtime_dir/rclone"
print "Installed FreeMount official runtime at $runtime_dir/rclone"

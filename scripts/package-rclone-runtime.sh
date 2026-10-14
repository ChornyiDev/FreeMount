#!/bin/zsh

set -euo pipefail

version="1.75.1"
cache_dir="$("${PROJECT_DIR:?PROJECT_DIR is required}/scripts/download-rclone-runtime.sh")"
helpers_dir="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH is required}/Helpers"
license_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH is required}/Licenses"

mkdir -p "$cache_dir" "$helpers_dir" "$license_dir"
install -m 0644 "${PROJECT_DIR}/scripts/licenses/rclone-COPYING" "$license_dir/rclone-COPYING"

for arch in arm64 amd64; do
    destination="$helpers_dir/rclone-${arch}"
    install -m 0755 "$cache_dir/rclone-${arch}" "$destination"

    if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
        identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
        if [[ "$identity" == "-" ]]; then
            codesign --force --sign - "$destination"
        else
            codesign --force --sign "$identity" --options runtime "$destination"
        fi
    fi

    print "Packaged rclone v${version} ($arch) at $destination"
done

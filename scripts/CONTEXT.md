# Scripts Context

## Purpose
Download, embed and optionally install official rclone binaries.

## Architecture
`download-rclone-runtime.sh` verifies repository-pinned SHA-256 checksums for the
official v1.75.1 darwin arm64/amd64 archives and caches extracted binaries.
`package-rclone-runtime.sh` embeds both binaries and the upstream MIT notice, then
signs helpers with the Xcode identity. `install-rclone-runtime.sh` atomically
installs the host architecture binary with ad-hoc development signing.
`install-from-source.sh` builds the full app with the user's personal team and
installs /Applications/FreeMount.app (the supported distribution path; see
docs/install-from-source.md).

## Current State
Version v1.75.1; no custom patches, source compilation or Go bootstrap.
Automatic selection uses bundled or managed binaries rather than arbitrary PATH
executables. Explicit user-configured paths remain supported.

## Dependencies
zsh, curl, shasum, unzip, install and codesign. Initial downloads require network.

## Known Issues
Managed installation does not replace a running app's embedded helper. Release
signing/notarization and live Finder checks remain separate verification.

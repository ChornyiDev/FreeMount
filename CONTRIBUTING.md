# Contributing to FreeMount

Thanks for helping. FreeMount is intentionally small, so please read this first.

## Before you start

For anything beyond a small fix, open an issue and discuss it first. Be ready to
answer, as in [AGENTS.md](AGENTS.md):

1. **Need:** which real scenario or bug does this solve?
2. **Existing path:** can the current code be fixed instead of adding a new path?
3. **Smallest solution:** why is new code necessary?

## Setup

Building needs an Apple ID (a free one works), your own Team ID and, for Google
sign-in, your own OAuth client. See [docs/building.md](docs/building.md).

## Tests

- `swift test` must pass.
- Changes to the File Provider extension also need a signed Xcode build; SPM alone
  does not compile every extension path.
- Changes to filesystem behavior should be checked in Finder against disposable
  storage (browse, download, edit, rename, delete, offline).

## Code rules

- Swift Concurrency; `@Observable`, not `ObservableObject`.
- Concrete `Codable` types instead of untyped dictionaries or `Any`.
- Typed error enums per subsystem; never swallow errors.
- Secrets only in the Keychain. Never commit tokens, keys, `rclone.conf` or
  `Secrets.xcconfig`.
- Keep `docs/` in sync when behavior or ownership changes.

## What will not be accepted

FUSE-T, macFUSE, NFS mounts or `/Volumes` mount scripts. Finder integration uses
Apple File Provider only.

## New providers

Follow [docs/adding-a-provider.md](docs/adding-a-provider.md). A provider is not
enabled until it has a File Provider backend and end-to-end validation.

## Pull requests

Describe the problem, the solution and how you verified it. Keep PRs focused.
Do not include secrets in code, logs or screenshots.

## Reporting bugs

Use the bug report template. Include macOS version, FreeMount version, provider,
steps to reproduce and relevant log lines with **tokens, passwords, keys and server
names removed**. Report security issues privately, see [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE).

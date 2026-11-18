# Contributing to FreeMount

Thanks for helping. FreeMount is intentionally small, so please read this first.

## Before you start

For anything beyond a small fix, please open an issue to discuss it first. Note that this repository includes [AGENTS.md](AGENTS.md) for AI coding agent instructions.

### Branch & PR naming

Follow Conventional Commits conventions for branch names and pull request titles:

- **Bug fixes:**
  - Branch: `fix/<short-description>`
  - PR title: `fix: <summary>` (e.g. `fix: prevent timeout on large uploads`)
- **Features & enhancements:**
  - Branch: `feat/<short-description>`
  - PR title: `feat: <summary>` (e.g. `feat: support WebDAV digest auth`)
- **Documentation & maintenance:**
  - Branch: `docs/<short-description>` or `chore/<short-description>`
  - PR title: `docs: <summary>` or `chore: <summary>`

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

# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

**Do not open a public issue.** Report privately through GitHub:
**Security → Report a vulnerability** (private security advisory) on this repository.

Please include the affected version, macOS version, provider, steps to reproduce
and the impact. Remove any real tokens, passwords or keys from logs and screenshots.

You can expect an acknowledgement within 7 days. We will work with you on a fix and
agree on a disclosure date before anything is published.

## In scope

- Leaks of tokens, passwords or keys (Keychain, logs, descriptors, files on disk)
- Bypassing authentication of the local `rclone` daemon on `127.0.0.1`
- Tampering with the bundled rclone runtime
- Accessing paths outside a connection's root (path traversal)

## Out of scope

- No protection from concurrent external writers on Google Cloud Storage
  (documented limitation)
- Issues that require an already compromised macOS account or Keychain
- Findings in rclone itself: report those to the [rclone project](https://github.com/rclone/rclone)

## More

How FreeMount handles credentials is described in [docs/security.md](docs/security.md).

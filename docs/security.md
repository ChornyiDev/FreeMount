# Security

## Credentials

- Cloud tokens, passwords and keys live only in the **Data Protection Keychain**,
  shared by the signed host app and File Provider extension through one access
  group. Nothing sensitive is written to config files, logs or descriptors.
- There is no `rclone.conf`. Credentials are passed to rclone in memory as inline
  filesystem references through the authenticated RC client.
- Non-secret descriptors in the App Group hold only opaque Keychain account
  references.
- Legacy secrets migrate only when a modern item is absent; denied access or a
  missing entitlement fails closed. Failed updates keep the existing secret, and
  credential enumeration fails rather than returning a partial inventory.
- Error output is redacted; RC request inputs are never shown as diagnostics.

## Local rclone daemon

- `rclone rcd` listens on `127.0.0.1` only and requires authentication. The RC
  password stays in Keychain; only an htpasswd verifier is streamed to the
  daemon's stdin, so no plaintext password appears in argv, environment or files.
- An existing listener is adopted only if an anonymous probe returns `401`.
  Unauthenticated daemons are rejected.
- The runtime is an official rclone release pinned by checksum, signed with the
  app identity.

## Build-time secrets

OAuth client credentials and the Apple Team ID come from
`Configs/Secrets.xcconfig`, which is git-ignored. See [building.md](building.md).

## Distribution

The host app is unsandboxed (it supervises rclone); the extension is sandboxed
with loopback network access. FreeMount targets direct distribution with the
hardened runtime, not the Mac App Store. Release signing, notarization and
first-unlock behavior still need validation.

## Reporting a vulnerability

Please open a private security advisory on the repository rather than a public
issue.

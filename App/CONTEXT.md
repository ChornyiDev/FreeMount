# Application Source Context

## Purpose
Native macOS host application and its embedded Apple File Provider extension.

## Architecture
See [the maintained architecture](../docs/architecture.md) for ownership.
- `App/`, `ViewModels/`, `Views/`: host lifecycle, Observation state and native UI.
- `Core/`, `Services/`: typed authenticated RC, host daemon supervision, Keychain
  credentials and non-secret settings.
- `Providers/`: Drive and bucket-rooted GCS authentication/discovery and adapters.
- `FileProvider/`: canonical shared descriptor catalog, live policy resolution,
  items, complete inventories, snapshots and error mapping.
- `FileProviderExtension/`: Finder enumeration, hydration, mutation and offline actions.
- `Activity/`: host-session transfer progress/results in bounded memory; Finder
  owns mutation/cancellation and no Activity disk history is produced.

## Current State
Drive and GCS are implemented; GCS live Finder release sign-off remains pending.
SFTP, WebDAV and SMB forms/backends are registered; SMB live Finder validation is pending. S3 is unavailable. macOS owns downloaded content; no VFS cache controls or
alternative filesystem mount engine exist.

FreeMountApp creates one RcloneProcessSupervisor and injects it directly into
lifecycle, forms, settings and telemetry; no MountService forwarding actor remains.
The host starts and recovers one authenticated loopback daemon before registering
or signaling domains. Lifecycle owns bounded shutdown diagnostics; MainActor
AppState opens Finder, and the add form uses the existing RC client for Drive discovery. Providers use bounded authenticated client readiness and
never spawn a competing process. Registration and provider health are distinct;
publishing a catalog descriptor alone does not establish a mounted domain. Finder
locations come only from macOS; a connected status may temporarily have no URL.
Show in Finder resolves it afresh, and saved configuration omits predicted mount
paths while ignoring their legacy JSON key. Startup
and bounded recovery honor saved automatic-connection preferences; manual
connections remain manual, while existing connected domains remain accessible.

Host configuration is published atomically into one App Group descriptor file.
Valid empty catalogs are authoritative; corruption/publication errors propagate.
Only the host migrates historical descriptors before registration, preserving
IDs. Legacy preferences are retired only after successful publication.

Cloud secrets and local RPC credentials remain in Keychain. Production uses Data
Protection storage; explicit test fixtures use isolated legacy services or injected
RPC stores. A historical cloud secret migrates on absence, never after denied
modern access, and is retired only after successful modern publication.

Drive retains account deduplication, Shared Drives and read-only Shared with me.
GCS retains Google Account/Service Account authorization, immutable bucket roots,
exact name validation and best-effort metadata preflight with ordinary RC.
Directory moves copy and verify complete inventories before source deletion.
Atomic external-writer protection and revision-pinned hydration are outside scope.

Complete working-set inventories and confirmed-success cancellation handling remain
required. Unknown job outcomes retain staging and unresolved move intent.

## Dependencies
macOS 14+; SwiftUI/AppKit, Observation, FileProvider, Security and Swift Concurrency.
The signed host bundles checksum-pinned official v1.75.1 binaries for arm64/amd64.
The development installer downloads the same artifacts.

## Known Issues
- Live Google/Finder, release signing/notarization and reboot/first-unlock validation
  remain separate from unit tests and signed build checks.
- GCS multi-object operations are non-transactional. Ambiguous journals and unknown
  staging require manual reconciliation. The explicitly retired legacy move guard
  is absent; no new move journal or replay exists.
- Drive duplicate sibling names remain limited by path-addressed rclone operations.
- GCS ancestor/name checks and inventory reads add listing latency for deep/large trees.
- GCS listings omit unsupported or colliding names; connection-detail warnings and
  their App Group store were explicitly removed. Naming and unsafe folder-operation
  guards remain, with failures mapped to Finder errors.

WebDAV preflight checks an unauthenticated HEAD challenge before rclone listing
and rejects Digest-only servers. The earlier Apache endpoint required Digest; the current test endpoint accepts
Bearer, and the user confirmed WebDAV works after Bearer mode isolation.
Provider switching replaces forms without an animated crossfade.

SMB uses one share/subfolder root, username/password/domain settings, the existing
Keychain and GenericRcloneFileProviderBackend paths, and no new runtime dependency.
ConnectionTestSection is shared by SFTP, WebDAV and SMB. Real isolated SMB2 RC
file operations pass; live Finder validation on a Windows/NAS share remains pending.

SMB forms discover available shares through the existing typed RC list call with
`dirsOnly` enabled and no root. Results are discarded after parameter changes;
users select a share or enter a known name before testing and saving. Discovery
does not persist credentials. Router guest discovery was verified on 2026-10-04.

SMB authentication uses the existing segmented control pattern: Guest hides
account fields and supplies `guest` with no password and WORKGROUP; Username &
Password uses entered credentials. Mode changes invalidate discovery and
verification, and guest requests never reuse a retained account password.

FTP/FTPS is registered over the existing generic backend. Its form supports plain, explicit TLS and implicit TLS with account/anonymous login. Absolute FTP roots preserve their slash; live Finder validation remains pending.

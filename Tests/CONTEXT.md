# Tests Context

## Purpose
Verify shared logic and isolated transport/failure scenarios without real cloud data.

## Architecture
Swift XCTest suites live directly under `Tests/`. `Helpers/` contains per-session
HTTP routing and reusable synthetic MoveRC fixtures; in-memory preferences avoid
installed configuration writes. Runtime tests use standard authenticated RC against
disposable local directories; no synthetic custom GCS server is required.

## Current State
Coverage includes legacy mount-path decoding with preserved connection identity,
macOS-only Finder location resolution (including rename and unavailable URLs),
connected-state preservation on URL errors, direct supervisor startup/restart and
bounded clean shutdown, typed Shared Drive discovery, configuration compatibility, isolated Keychain lifecycle, RC
requests/authentication/jobs, domain lifecycle/catalog migration, current policy,
provider authorization/discovery/naming/metadata preflight, standard GCS jobs, complete
inventories, cancellation, session transfer telemetry and UI state. GCS naming
coverage keeps supported siblings visible and rejects ambiguous paths/hidden
folder descendants; warning-store-only tests were removed with that feature.
Security/data-integrity fault tests remain.
Each mocked session routes to its own locked HTTP fixture; missing handlers fail
requests instead of hanging. MoveRC is shared from `Helpers/MoveRC.swift`.

Catalog tests verify authoritative empty files, corrupt-file failures, publication
failure preserving legacy settings, stable-ID migration, exact identifiers and
extension read-only migration behavior. Keychain fixtures explicitly select unique
legacy test services; production never falls back after missing entitlement or
access denial. RPC fixtures use in-memory installation stores/disposable ports.

## Dependencies
XCTest and SwiftPM. Xcode builds the signed embedded extension separately; SwiftPM
excludes the extension entry point.

## Known Issues
Live Finder/Google behavior is outside the default suite. Slow local transfer
integration is opt-in with `FREEMOUNT_RCLONE_INTEGRATION=1` and an explicitly selected
`FREEMOUNT_TEST_RCLONE`; it uses a disposable authenticated daemon. Real-runtime
fixtures also accept the checksum-pinned official artifact; absent artifacts
skip those scenarios, never adopt installed application helpers. No unit-test
success establishes release/Finder sign-off. Signed Keychain migration requires
additional platform validation beyond the unsigned fixture runner.

SMB tests cover endpoint/share validation, root/persistence identity, matching
Keychain credential enforcement, NTLM failure classification and read-only writes.
ProviderRegistry expectations include SMB. Real SMB2 loopback RC operations were
checked separately; platform Finder/Windows/NAS sign-off remains outside the suite.

FTPConfigurationTests covers exclusive TLS modes, default ports, validation and absolute/home root preservation.

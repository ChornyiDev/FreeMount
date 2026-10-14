# Adding a Cloud Provider

FreeMount exposes cloud storage through Apple's File Provider framework. Each
supported integration is a **provider**.

## Provider boundary

Shared provider infrastructure lives in `App/Providers/Core/`:

- `ProviderID` is the stable persisted identifier. Use a unique lowercase raw
  value and never change it after release.
- `CloudProvider` describes display metadata, capabilities, icon resources,
  and the backend factory.
- `FileProviderBackend` is the filesystem contract consumed by the File
  Provider extension.
- `ProviderRegistry` is the single list of providers included in a build.

Provider-specific implementation belongs in
`App/Providers/<ProviderName>/`. Google Drive is the reference implementation.

## Implementation checklist

1. Add a provider-specific backend conforming to `FileProviderBackend`.
2. Keep secrets in the shared macOS Keychain access group. Persist only opaque
   Keychain account references in `FileProviderConnectionDescriptor`.
3. Define one `CloudProvider` registration with a stable `ProviderID`, accurate
   capabilities, a backend factory, and provider branding metadata.
4. Add the registration to `ProviderRegistry.shared`.
5. Add the source files to both the host app and File Provider extension Xcode
   targets when the extension needs them.
6. Add a licensed provider icon only when the provider is functional. Until
   then, use an SF Symbol fallback. Do not recolor or reshape third-party logos
   unless their brand policy explicitly permits it.
7. Add unit tests for registration, serialization compatibility, filesystem
   operations, error mapping, and credential isolation.
8. Verify hydration, upload/writeback, rename, move, delete, offline access,
   network reconnection, and simultaneous edit conflicts in Finder.

## Constraints

- `NSFileProviderReplicatedExtension` is the only supported Finder integration.
- Do not add FUSE, NFS, or `/Volumes` fallbacks.
- Use concrete `Codable` request and response models; do not introduce `Any`
  dictionaries at the provider boundary.
- Backend errors must reach File Provider and the host UI. Never silently mark
  a failing connection as active.
- A provider must not appear in the connection picker until its registration,
  backend, authentication, and required tests are complete.

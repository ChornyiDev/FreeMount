# Google Cloud Storage Connections

A connection exposes exactly one immutable bucket in Finder. Create another
connection to choose a different bucket.

## Authentication and Setup

The connection name comes first. Manual edits disable automatic name suggestions.
Authorization, Configuration, and Options follow; Save & Connect remains fixed
at the bottom and validates access before persisting the connection.

Google Account opens browser OAuth. Service Account imports a Google JSON key
with the native file picker and performs token exchange before showing the
account email as authorized. Keys stay in memory until save and are retained
only in shared macOS Keychain. The app never copies a JSON key to its config or
stores the imported source path. The original file remains where the user placed it.

Configuration discovers projects and buckets visible to the chosen principal.
For Service Accounts, Enter bucket manually supports principals whose access is
limited to one bucket. The imported key's project ID is a discovery default,
not a restriction or proof of bucket ownership.

## IAM

For read/write, grant the service-account email Storage Object User
(`roles/storage.objectUser`) on the selected bucket. For read-only, grant
Storage Object Viewer (`roles/storage.objectViewer`) and enable Read-only access.
Granting these roles on the bucket keeps IAM access limited to that resource.
Selecting a bucket in FreeMount alone does not narrow the principal's IAM rights.

Project dropdown discovery needs `resourcemanager.projects.get`; bucket dropdown
discovery needs `storage.buckets.list` on the project. Metadata checks need
`storage.buckets.get`. Object-only roles do not provide bucket metadata read
access. Direct entry tolerates a denied metadata request and still requires
objects.list/get plus create/delete for writable connections, tested through
Google IAM and an actual rclone bucket-root listing before save.

Requester Pays needs a billing project ID and the billing permissions required
by Google. Direct entry displays this as an optional field because bucket
billing metadata may be inaccessible. A missing required billing project will
prevent Save & Connect from completing.

## Key Replacement and Failures

Connection details show the Service Account email and Replace key. Replacement
validates token exchange, required bucket permissions, and root listing before
atomically updating the existing Keychain item. The connection and its bucket
remain the same. Revoked keys need replacement; IAM, API enablement, billing,
and network failures remain distinct from successful authorization.

Service Account setup does not use the app's OAuth consent screen or browser
sign-in client. Enable the Cloud Storage JSON API in the Google Cloud project
used for API requests; Cloud Resource Manager is needed for project discovery.

## Validation Status

Synthetic tests cover crypto, token exchange, IAM, Keychain persistence, and
secret redaction. A live Service Account Finder round trip with a real key is
pending before release sign-off.

## References

- [Google Service Account OAuth protocol](https://developers.google.com/identity/protocols/oauth2/service-account)
- [Cloud Storage IAM roles](https://docs.cloud.google.com/storage/docs/access-control/iam-roles)
- [Rclone GCS backend](https://rclone.org/googlecloudstorage/)

## Finder object names

FreeMount preserves supported object paths exactly. Repeated/leading/trailing
slashes, dot components and NUL are unsupported. Objects sharing one Finder name
(file versus folder, case differences or canonically equivalent Unicode) are all
hidden; other files remain available. Connection details do not display a separate
name-warning banner or persist warning records. Inspect and resolve unsupported
names in Google Cloud Console.
Moving or recursively deleting a folder containing hidden names is blocked before
changes begin. Folder deletion uses enumerated files and empty-folder checks.

## Standard RC behavior and limits

The bundled runtime is official rclone v1.75.1. Creation checks destination absence;
updates and deletes compare Finder metadata before issuing ordinary RC jobs. These
checks are best effort: an external writer can change an object between the check
and mutation. Hydration is not generation pinned; gzip objects use raw bytes
(`decompress=false`). Directory markers preserve empty folders.

Directory moves copy first, verify complete source/destination inventories, then
remove source items. Failures retain the source or remaining source items and any
partial destination; interrupted moves require manual reconciliation, not replay.
Case-equivalent file renames work. Equivalent folder renames and combined content
updates with equivalent renames must use a distinct intermediate name.

The user explicitly retired the stale legacy test journal and removed its guard;
no legacy journal replay/blocking remains.
Refresh cached Finder metadata after upgrading from older builds.

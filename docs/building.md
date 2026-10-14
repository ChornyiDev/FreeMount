# Building FreeMount

## Requirements

- macOS 14+, Xcode (Swift 5.10+), [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An Apple ID signed in to Xcode (Settings → Accounts). A **free** account is enough
  for local builds: Xcode creates a Personal Team and signs the app and the File
  Provider extension with it. Free provisioning profiles expire after 7 days;
  rebuild to renew.

## Configure

```bash
cp Configs/Secrets.xcconfig.example Configs/Secrets.xcconfig
```

Edit `Configs/Secrets.xcconfig` (git-ignored):

| Key | Where to get it |
|---|---|
| `DEVELOPMENT_TEAM` | Your Team ID: Xcode → Settings → Accounts → select your team |
| `FREEMOUNT_GOOGLE_CLIENT_ID` / `FREEMOUNT_GOOGLE_CLIENT_SECRET` | Google Cloud Console → APIs & Services → Credentials → OAuth client of type **Desktop app** |

Google Drive and GCS (Google Account sign-in) need your own OAuth client. SFTP,
WebDAV, SMB, FTP and GCS service-account connections do not.

## Build and test

```bash
xcodegen generate
xcodebuild -project FreeMount.xcodeproj -scheme FreeMount \
  -configuration Debug -allowProvisioningUpdates build
swift test
```

The Xcode build downloads checksum-pinned official rclone binaries (arm64 and
x86_64), caches them under `.build/rclone-artifacts/`, includes the upstream MIT
notice and signs them with the app identity. `swift test` covers shared logic only;
extension changes need the signed Xcode build.

The built app is `FM.app` with the File Provider extension embedded.

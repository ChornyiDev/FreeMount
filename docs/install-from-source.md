# Install FreeMount from source

FreeMount is free and MIT licensed, but there is no public download: Apple
only allows apps with App Groups, shared Keychain groups and a File Provider
extension to run when they are signed with a developer identity, and the
project has no paid Apple Developer account. You provide that identity
yourself with a **free Apple ID** in Xcode.

## One command

Install [Xcode](https://apps.apple.com/app/xcode/id497799835) (full app, not
just Command Line Tools), open it once and sign in with your Apple ID
(Xcode → Settings → Accounts), then:

```bash
git clone https://github.com/ChornyiDev/FreeMount.git
cd FreeMount
./scripts/install-from-source.sh
```

The installer detects your personal Team ID, configures the project, builds a
Release, signs it with your own Apple Development identity and installs
`/Applications/FreeMount.app`. Re-run the same command after `git pull` to
update.

## What the installer does manually

If you prefer to control each step:

```bash
cp Configs/Secrets.xcconfig.example Configs/Secrets.xcconfig
# put your Team ID into DEVELOPMENT_TEAM (Xcode → Settings → Accounts shows it)
brew install xcodegen
xcodegen generate
xcodebuild -project FreeMount.xcodeproj -scheme FreeMount \
  -configuration Release -destination 'platform=macOS' \
  -allowProvisioningUpdates build
# drag the built FM.app from DerivedData's Release folder to /Applications
```

## Google Drive / Google Cloud Storage sign-in

The repository ships default Google OAuth *desktop client* credentials.
Desktop client credentials are public by design; your tokens still go only to
your Keychain. Because the shared client is not verified by Google, the
consent screen may show an "unverified app" warning — it is expected and you
can proceed. To skip the warning (or for your own quota), create a free
"Desktop app" OAuth client in Google Cloud Console and replace the values in
`Configs/Secrets.xcconfig`. SFTP, WebDAV, SMB and FTP/FTPS need no OAuth at
all.

## Does a source build keep working?

Yes. Unlike iPhone development profiles, macOS does not re-check the weekly
provisioning window at launch: apps signed with your own Apple Development
identity run on your Mac for months (confirmed by the project author).
If a future macOS ever refuses to launch the app, re-running the installer
re-signs everything in one step.

## Limitations of this distribution track

- You are the builder: no notarized downloads, no auto-updates; updating is
  `git pull` + re-run the script.
- Each user needs their own Apple ID with Xcode; work Macs with locked-down
  Xcode policies may not allow personal team signing.
- The real product decision to change this is a paid Apple Developer ID plus
  notarization; the release pipeline for that already exists in
  `.github/workflows/release.yml`.

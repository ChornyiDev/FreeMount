#!/bin/zsh
# Build FreeMount from source with your own free Apple ID and install it into
# /Applications. No paid developer account required.
#
#   ./scripts/install-from-source.sh [--team <DEVELOPMENT_TEAM>]
#
# What it does: checks prerequisites, prepares Configs/Secrets.xcconfig
# (Google OAuth client defaults ship in the repo), detects or takes your
# personal team ID, builds Release, signs with your Apple Development
# identity and installs. Re-run the same command to update after `git pull`.

set -euo pipefail
cd "${0:A:h:h}"

team_override=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --team) team_override="$2"; shift 2 ;;
        *) print -u2 "Unknown option: $1"; exit 2 ;;
    esac
done

xcode-select -p >/dev/null || { print -u2 "Xcode is required (xcode-select --install or install Xcode)."; exit 1; }

# FreeMount.xcodeproj is committed in the repository. We only require XcodeGen
# if the project file is missing or if project.yml has newer local changes.
if [[ ! -d FreeMount.xcodeproj ]]; then
    if ! command -v xcodegen >/dev/null; then
        command -v brew >/dev/null || {
            print -u2 "FreeMount.xcodeproj is missing and neither XcodeGen nor Homebrew was found."
            print -u2 "Please install XcodeGen (brew install xcodegen) or restore FreeMount.xcodeproj from git."
            exit 1
        }
        print "Installing XcodeGen…"
        brew install xcodegen
    fi
    print "Generating Xcode project…"
    xcodegen generate
elif command -v xcodegen >/dev/null && [[ -f project.yml ]] && [[ project.yml -nt FreeMount.xcodeproj/project.pbxproj ]]; then
    print "project.yml has local changes; regenerating FreeMount.xcodeproj…"
    xcodegen generate
fi

if [[ ! -f Configs/Secrets.xcconfig ]]; then
    cp Configs/Secrets.xcconfig.example Configs/Secrets.xcconfig
    print "Created Configs/Secrets.xcconfig from bundled defaults."
fi

# Resolve personal/team identifier: explicit flag, then config file, then Keychain.
team="$team_override"
[[ -z "$team" ]] && team="$(awk -F'=' '/^DEVELOPMENT_TEAM/ {gsub(/[ \t]/,"",$2); print $2}' Configs/Secrets.xcconfig)"
if [[ -z "$team" ]]; then
    # Extract authentic Apple Developer Team ID (the OU field of the certificate)
    teams=($(python3 -c '
import subprocess, re
res = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"], capture_output=True, text=True)
certs = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", res.stdout, re.DOTALL)
seen = []
for c in certs:
    p = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=c, text=True, capture_output=True)
    m = re.search(r"OU\s*=\s*([A-Z0-9]{10})", p.stdout)
    if m and m.group(1) not in seen:
        seen.append(m.group(1))
print(" ".join(seen))
' 2>/dev/null || true))
    if (( ${#teams[@]} == 0 )); then
        print -u2 "No 'Apple Development' certificate found. Open Xcode → Settings → Accounts and sign in with your Apple ID once, then re-run."
        exit 1
    fi
    (( ${#teams[@]} > 1 )) && print "Multiple development teams found; using ${teams[1]}. Pass --team <ID> to choose another."
    team="${teams[1]}"
    sed -i '' "s/^DEVELOPMENT_TEAM = .*/DEVELOPMENT_TEAM = $team/" Configs/Secrets.xcconfig
    print "Auto-detected team $team and saved it to Configs/Secrets.xcconfig."
fi

print "Building Release (first run may take a few minutes; Xcode provisions your personal team automatically)…"
xcodebuild -project FreeMount.xcodeproj -scheme FreeMount \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath build/install-dd \
    DEVELOPMENT_TEAM="$team" \
    -allowProvisioningUpdates \
    build >/tmp/freemount-install-build.log 2>&1 || {
        tail -20 /tmp/freemount-install-build.log
        print -u2 "Build failed; full log: /tmp/freemount-install-build.log"
        exit 1
    }

APP="build/install-dd/Build/Products/Release/FM.app"
codesign --verify --deep --strict "$APP" || { print -u2 "Built bundle failed signature verification."; exit 1; }

# Record repository directory in user defaults so the app knows where to pull updates from
defaults write com.freemount.app FreeMountSourceRepositoryPath "$PWD"

pkill -x FM 2>/dev/null || true
if [[ -d /Applications/FreeMount.app ]]; then rm -rf /Applications/FreeMount.app; fi
cp -R "$APP" /Applications/FreeMount.app

print "Installed /Applications/FreeMount.app — launching."
open /Applications/FreeMount.app

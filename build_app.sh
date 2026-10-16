#!/bin/bash
# Builds the GitHub release of PasteLens (Developer ID, hardened runtime, not sandboxed)
# into .build/app/PasteLens.app, ready for ./notarize.sh and ./make_dmg.sh.
#
# The App Store build is archived from Xcode instead (scheme PasteLens, configuration
# AppStore, automatic signing): its iCloud container needs a provisioning profile.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate >/dev/null
rm -rf .build/xcode-release .build/app
# A clean build every time: Xcode's App Intents extraction fails on partial rebuilds.
xcodebuild -project PasteLens.xcodeproj -scheme PasteLens -configuration Release \
  -derivedDataPath .build/xcode-release build | grep -E "error:|warning: unre|BUILD" || true

APP=".build/xcode-release/Build/Products/Release/PasteLens.app"
[ -d "$APP" ] || { echo "Build failed." >&2; exit 1; }
[ -d "$APP/Contents/Resources/Metadata.appintents" ] || { echo "Shortcuts metadata missing from the build." >&2; exit 1; }
for f in MacOS/PasteLens Helpers/pastelens Helpers/pastelens-mcp; do
  lipo -archs "$APP/Contents/$f" | grep -q "x86_64 arm64\|arm64 x86_64" || { echo "$f isn't universal." >&2; exit 1; }
done

mkdir -p .build/app
ditto "$APP" .build/app/PasteLens.app
codesign --verify --deep --strict .build/app/PasteLens.app
codesign -dvv .build/app/PasteLens.app 2>&1 | grep -E "^Authority=Developer ID|^Timestamp=" 
echo "Built .build/app/PasteLens.app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' .build/app/PasteLens.app/Contents/Info.plist))"

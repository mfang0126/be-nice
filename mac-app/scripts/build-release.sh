#!/bin/sh
# Unsigned-by-Apple release build: ad-hoc signed "Be Nice.app" zipped for GitHub Releases.
# Needs no local certificate. Users right-click -> Open the first time.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
swift build -c release --product benice
DIST=.build/release-dist
rm -rf "$DIST"
APP="$DIST/Be Nice.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/benice "$APP/Contents/MacOS/benice"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --deep -s - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
ZIP="$PWD/$DIST/BeNice-$VERSION-macos.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
echo "Zip:    $ZIP"
echo "sha256: $(/usr/bin/shasum -a 256 "$ZIP" | cut -d' ' -f1)"

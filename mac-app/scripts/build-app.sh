#!/bin/sh
# Stable local development bundle; release-local is optimized, not distribution.
set -eu
cd "$(dirname "$0")/.."
MODE="${1:-debug}"
case "$MODE" in
    debug) CONFIG=debug ;;
    release-local) CONFIG=release ;;
    *) echo "usage: $0 [debug|release-local] [--install]; distribution signing is not configured" >&2; exit 2 ;;
esac
[ "$#" -le 2 ] && [ "${2:---install}" = --install ] || {
    echo "usage: $0 [debug|release-local] [--install]" >&2; exit 2;
}
CERT="$HOME/Library/Application Support/be-nice/dev-signing/certificate.pem"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
[ -f "$CERT" ] && [ ! -L "$CERT" ] || {
    echo "Stable development certificate missing. Review and run: sh mac-app/scripts/setup-dev-signing.sh --setup" >&2
    exit 1
}
HASH=$(/usr/bin/openssl x509 -in "$CERT" -noout -fingerprint -sha1 | tr -d ':' | cut -d= -f2)
printf '%s\n' "$HASH" | grep -Eq '^[0-9A-Fa-f]{40}$' || { echo "Invalid certificate fingerprint" >&2; exit 1; }
/usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "$HASH" || {
    echo "Stable development signing identity unavailable/expired. Unlock or repair the login keychain; no ad-hoc fallback." >&2
    exit 1
}
swift build -c "$CONFIG" --product benice
mkdir -p .build
STAGE=$(mktemp -d "$PWD/.build/dev-app.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
APP="$STAGE/be-nice Development.app"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/benice" "$APP/Contents/MacOS/benice"
cp Support/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.benice.menubar.development' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName be-nice Development' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName be-nice Development' "$APP/Contents/Info.plist"
# Explicit leaf pin keeps the requirement independent of binary content.
/usr/bin/codesign --force --sign "$HASH" --keychain "$KEYCHAIN" --timestamp=none \
    -r "=designated => identifier \"com.benice.menubar.development\" and certificate leaf = H\"$HASH\"" "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
/usr/bin/codesign -d -r- "$APP" 2> "$STAGE/designated-requirement.txt"
DEST="$PWD/.build/be-nice Development.app"
if [ "${2:-}" = --install ]; then
    DEST="$HOME/Applications/be-nice Development.app"
    if pgrep -f "$DEST/Contents/MacOS/benice" >/dev/null; then
        echo "Quit the installed development app before replacing it." >&2; exit 1
    fi
    mkdir -p "$HOME/Applications"
fi
[ ! -L "$DEST" ] || { echo "Refusing symlink destination: $DEST" >&2; exit 1; }
# Inspect an existing target before replacing it; keep a backup for recovery.
if [ -e "$DEST" ]; then
    EXISTING=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")
    [ "$EXISTING" = com.benice.menubar.development ] || { echo "Refusing unrelated destination: $DEST" >&2; exit 1; }
fi
PUBLISH=$(mktemp -d "$(dirname "$DEST")/.be-nice-install.XXXXXX")
/usr/bin/ditto "$APP" "$PUBLISH/be-nice Development.app"
/usr/bin/codesign --verify --strict "$PUBLISH/be-nice Development.app"
if [ -e "$DEST" ]; then mv "$DEST" "$PUBLISH/previous.app"; fi
if ! mv "$PUBLISH/be-nice Development.app" "$DEST"; then
    [ ! -e "$PUBLISH/previous.app" ] || mv "$PUBLISH/previous.app" "$DEST"
    exit 1
fi
cp "$STAGE/designated-requirement.txt" .build/development-designated-requirement.txt
if [ -e "$PUBLISH/previous.app" ]; then
    echo "Previous app retained: $PUBLISH/previous.app (remove after validation)"
else
    rmdir "$PUBLISH"
fi
echo "Built local development app: $DEST"
echo "Requirement record: $PWD/.build/development-designated-requirement.txt"
echo "Run: open \"$DEST\""

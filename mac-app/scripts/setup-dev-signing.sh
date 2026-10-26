#!/bin/sh
# Explicit machine setup: run only after reviewing this script.
set +x
set -eu
umask 077
[ "${1:-}" = "--setup" ] && [ "$#" = 1 ] || {
    echo "usage: $0 --setup (creates/reuses a local development identity)" >&2
    exit 2
}
DIR="$HOME/Library/Application Support/be-nice/dev-signing"
[ ! -L "$DIR" ] || { echo "Refusing symlink: $DIR" >&2; exit 1; }
mkdir -p "$DIR"
chmod 700 "$DIR"
KEY="$DIR/private-key.pem"
CERT="$DIR/certificate.pem"
[ ! -L "$KEY" ] && [ ! -L "$CERT" ] || { echo "Refusing symlink signing files" >&2; exit 1; }
mkdir "$DIR/setup.lock" 2>/dev/null || {
    echo "Setup already running or interrupted; inspect $DIR/setup.lock before retrying." >&2; exit 1
}
SMOKE=
cleanup() {
    [ -z "$SMOKE" ] || rm -rf "$SMOKE"
    rmdir "$DIR/setup.lock"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
NEW=false
# Never replace existing material, including after an interrupted setup.
if [ ! -e "$KEY" ] && [ ! -e "$CERT" ]; then
    NEW=true
    /usr/bin/openssl genrsa -out "$KEY" 3072
    /usr/bin/openssl req -new -x509 -key "$KEY" -sha256 -days 3650 -nodes \
        -subj '/CN=be-nice Local Development/' \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=critical,codeSigning' \
        -out "$CERT"
fi
[ -f "$CERT" ] && [ ! -L "$CERT" ] || {
    echo "Incomplete/unsafe signing files in $DIR; inspect manually, do not regenerate an established identity." >&2
    exit 1
}
chmod 600 "$CERT"
if [ -e "$KEY" ]; then
    [ -f "$KEY" ] || { echo "Unsafe private-key path; inspect $DIR" >&2; exit 1; }
    chmod 600 "$KEY"
fi
# Check OpenSSL itself: a pipeline would mask parse failure and yield an empty grep pattern.
FINGERPRINT=$(/usr/bin/openssl x509 -in "$CERT" -noout -fingerprint -sha1) || {
    echo "Invalid development certificate; inspect $CERT" >&2; exit 1
}
HASH=$(printf '%s\n' "$FINGERPRINT" | tr -d ':' | cut -d= -f2)
printf '%s\n' "$HASH" | grep -Eq '^[0-9A-Fa-f]{40}$' || {
    echo "Invalid certificate fingerprint" >&2; exit 1
}
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if ! /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "$HASH"; then
    [ "$NEW" = true ] || {
        echo "Established identity unavailable or setup incomplete; inspect $DIR and login keychain manually. No regeneration or automatic re-import." >&2
        exit 1
    }
    /usr/bin/security import "$KEY" -k "$KEYCHAIN" -t priv -f openssl -x -T /usr/bin/codesign
    # Self-signed root, trusted only for code signing in the current user domain.
    /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT"
fi
/usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$HASH" || {
    echo "Identity is not valid for code signing; inspect Keychain Access. No ad-hoc fallback." >&2
    exit 1
}
# Prove private-key access and signing before removing the transient recovery material.
SMOKE=$(mktemp -d "$DIR/signing-smoke.XXXXXX")
cp /bin/echo "$SMOKE/probe"
/usr/bin/codesign --force --sign "$HASH" --keychain "$KEYCHAIN" --timestamp=none "$SMOKE/probe"
/usr/bin/codesign --verify --strict "$SMOKE/probe"
[ ! -e "$KEY" ] || rm "$KEY"
echo "Development identity ready. Private key persists only in the login keychain; keep $CERT persistent."

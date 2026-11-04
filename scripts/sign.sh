#!/bin/sh
# Signs the app with the project's self-signed certificate, so every build has the same
# designated requirement and macOS keeps the Accessibility permission across updates.
# Without REMVEL_CERT_P12 (base64 .p12) the app stays ad-hoc signed.
# Usage: scripts/sign.sh path/to/Remvel.app
set -eu
APP=$1
if [ -z "${REMVEL_CERT_P12:-}" ]; then
    echo "REMVEL_CERT_P12 not set; leaving $APP ad-hoc signed"
    exit 0
fi

WORK=$(mktemp -d)
KEYCHAIN="$WORK/sign.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
trap 'security delete-keychain "$KEYCHAIN" 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "$REMVEL_CERT_P12" | base64 --decode > "$WORK/cert.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$REMVEL_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# The certificate is self-signed, so it is not "valid" for find-identity; pick it by hash.
IDENTITY=$(security find-certificate -c "Remvel Self-Signed" -Z "$KEYCHAIN" | awk '/SHA-1/ { print $3 }')
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier io.github.remvel.Remvel "$APP"
codesign --display --requirements - "$APP" 2>&1 | grep designated

#!/bin/sh
# Creates a permanent, local, self-signed code-signing identity for WinCycle.
#
# Why this exists: macOS ties the Accessibility permission to the app's code
# signature. If you sign ad-hoc (`codesign -s -`) on every rebuild, the
# signature changes with every edit, macOS treats the app as "new", and you
# have to re-grant Accessibility after every single change. A stable identity
# fixes that: sign with it once, and the signature — and therefore the
# permission — survives rebuilds.
#
# Run this once, before the first `build.sh`. It creates its own keychain
# (~/Library/Keychains/wincycle.keychain-db) so it doesn't touch your login
# keychain, and adds the certificate to your login keychain's trust store so
# `codesign` will actually accept it (no admin password required for that
# step — `security add-trusted-cert` on the login keychain doesn't need sudo).
#
# Notes on why the flags are what they are, since they weren't obvious:
#   - keyUsage=digitalSignature + extendedKeyUsage=codeSigning are both
#     required, or codesign rejects the identity with
#     "Invalid Key Usage for policy".
#   - The PKCS12 bundle must use the legacy PBE-SHA1-3DES / SHA1 MAC
#     algorithms; modern OpenSSL 3 defaults produce a .p12 that macOS's
#     `security import` silently fails to read ("MAC verification failed").

set -e
cd "$(dirname "$0")"

KEYCHAIN="$HOME/Library/Keychains/wincycle.keychain-db"
KEYCHAIN_PASSWORD="wincycle"
IDENTITY_NAME="WinCycle Local Signing"

mkdir -p signing
cd signing

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "Signing identity already set up. Nothing to do."
    exit 0
fi

echo "Generating a self-signed certificate..."
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 7300 -nodes \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export -out bundle.p12 -inkey key.pem -in cert.pem \
    -passout "pass:$KEYCHAIN_PASSWORD" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "Creating a dedicated keychain..."
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 100000 "$KEYCHAIN"
security import bundle.p12 -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# codesign needs the keychain to be in the search list, not just unlocked
security list-keychains -d user -s "$(security list-keychains -d user | tr -d ' "')" "$KEYCHAIN"

echo "Trusting the certificate for code signing..."
security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db cert.pem

echo
echo "Done. Identity found:"
security find-identity -v -p codesigning "$KEYCHAIN" | grep "$IDENTITY_NAME"

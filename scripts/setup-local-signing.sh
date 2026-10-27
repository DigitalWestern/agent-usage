#!/bin/bash
#
# Create the local, self-signed code signing identity this project expects
# ("Usage4Claude-CodeSigning"), so local builds keep one stable signature.
#
# Why this exists:
#   macOS Keychain items are protected by an ACL tied to the app's code
#   signature. An unsigned or ad-hoc signed app gets a new identity on every
#   build, so the Keychain treats each rebuild as a stranger and asks for your
#   password again. A self-signed certificate that stays in your login keychain
#   gives every build the same identity, and "Always Allow" then sticks.
#
# This is a personal build. Nothing here is suitable for distribution.
#
# Usage: ./scripts/setup-local-signing.sh
#
# Idempotent: exits without changes if the identity already exists.

set -euo pipefail

CERT_NAME="Usage4Claude-CodeSigning"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Identity '$CERT_NAME' already exists. Nothing to do."
    exit 0
fi

echo "Creating code signing identity '$CERT_NAME' in your login keychain."
echo "macOS may ask you to allow access to the keychain. That is this setup, once."
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 4096-bit RSA, code signing extended key usage, self-signed and long-lived.
openssl req -x509 -newkey rsa:4096 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=$CERT_NAME/O=Local Development" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

# macOS Security.framework cannot read modern PKCS#12 (AES-256 + SHA-256 MAC).
# Force the legacy algorithms it understands.
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:local-signing \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" \
    -P local-signing \
    -T /usr/bin/codesign \
    -A >/dev/null

# Trust it for code signing in the user domain so `codesign` considers the
# identity valid. No admin rights or system keychain involved.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Done. '$CERT_NAME' is now available to code signing."
    echo "Builds from this repo will sign with it automatically."
else
    echo "Import ran but no valid identity was found. Check Keychain Access >"
    echo "login > Certificates, and that '$CERT_NAME' is trusted for code signing."
    exit 1
fi

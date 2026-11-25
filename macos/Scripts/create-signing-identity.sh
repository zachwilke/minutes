#!/bin/bash
# Creates a stable self-signed code-signing identity for Minutes.
#
# Why this exists: macOS remembers a permission decision against an app's *code
# identity*. An ad-hoc signature is derived from the binary's hash, so it changes
# on every rebuild and TCC treats each build as a brand new app — forgetting the
# microphone and Audio Recording grants every time.
#
# You only need this if you have no Apple "Developer ID Application" certificate.
# build-app.sh prefers a Developer ID automatically, because its designated
# requirement is tied to the certificate's *name* rather than its hash, so the
# grants even survive a certificate renewal. A self-signed certificate is tied to
# its hash, so regenerating it resets permissions once more.
#
# This is interactive by necessity: macOS requires your password to add trust
# settings, and the keychain will ask before letting codesign use the new key.
# Approve those prompts, choosing "Always Allow" for the keychain one.
set -euo pipefail

IDENTITY_NAME="Minutes Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DAYS=3650

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "Identity already exists:"
  security find-identity -v -p codesigning | grep "$IDENTITY_NAME"
  echo
  echo "Nothing to do. Run ./Scripts/build-app.sh --install to sign with it."
  exit 0
fi

# LibreSSL (the system openssl) lacks -addext, and the code-signing extended key
# usage is mandatory — without it codesign will not accept the identity.
OPENSSL="$(command -v openssl || true)"
if [ -z "$OPENSSL" ] || ! "$OPENSSL" req -help 2>&1 | grep -q addext; then
  for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    [ -x "$candidate" ] && OPENSSL="$candidate" && break
  done
fi
if [ -z "$OPENSSL" ] || ! "$OPENSSL" req -help 2>&1 | grep -q addext; then
  echo "error: need an openssl that supports -addext (brew install openssl@3)." >&2
  exit 1
fi
echo "==> Using $OPENSSL"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating a 10-year self-signed code-signing certificate"
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days "$DAYS" -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY_NAME/O=Minutes/C=US" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -name "$IDENTITY_NAME" -passout pass:minutes 2>/dev/null

echo "==> Importing into the login keychain"
# -T grants codesign access to the key up front, which avoids a prompt on every
# single build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P minutes \
  -T /usr/bin/codesign >/dev/null

echo "==> Trusting it for code signing (macOS will ask for your password)"
if ! security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null; then
  echo "    warning: trust settings were not applied."
  echo "    Open Keychain Access, find \"$IDENTITY_NAME\", and set"
  echo "    Trust > Code Signing to \"Always Trust\"."
fi

# Without this, the keychain prompts on every build. It needs the login keychain
# password, so it is expected to ask.
echo "==> Allowing codesign to use the key without prompting"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -l "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1 \
  || echo "    skipped (you may get a keychain prompt on the first build — choose Always Allow)"

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "Done. Valid identity created:"
  security find-identity -v -p codesigning | grep "$IDENTITY_NAME"
else
  echo "The certificate was imported but is not yet a *valid* identity, which"
  echo "almost always means the trust setting did not stick. Set it manually in"
  echo "Keychain Access (Trust > Code Signing > Always Trust), then re-run this."
  exit 1
fi

echo
echo "Next: ./Scripts/build-app.sh --install"
echo "Permissions granted after that build will persist across future rebuilds."

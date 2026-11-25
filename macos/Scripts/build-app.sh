#!/bin/bash
# Builds Minutes.app.
#
# SwiftPM can't produce an .app bundle, and a bare executable can't hold the
# usage-description strings macOS requires before it will grant microphone and
# audio-capture permission. So we build the binary, then assemble the bundle
# around it by hand.
#
# Usage:
#   ./Scripts/build-app.sh            # build into ./build
#   ./Scripts/build-app.sh --install  # also copy to /Applications and launch
set -euo pipefail

# Captured before anything else: the icon loop below uses `set --`, which would
# otherwise clobber the positional parameters.
ACTION="${1:-}"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# macOS keys microphone and Audio Recording grants to the bundle identifier,
# and the library lives in a folder named after the app, so changing either
# resets every permission and orphans the library (the app migrates the library
# itself; the permissions have to be granted again).
APP_NAME="Minutes"
PRODUCT_NAME="Minutes"
BUNDLE_ID="com.minutesapp.Minutes"
VERSION="2.0.2"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

# SwiftUI's property wrappers are macros on macOS 26+, and the plugin that
# expands them ships only with full Xcode — Command Line Tools alone cannot
# build this. Find Xcode wherever it lives.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta*.app /Applications/Xcode*.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -d "$DEVELOPER_DIR" ]; then
  echo "error: full Xcode is required to build (the SwiftUI macro plugin is not in Command Line Tools)." >&2
  echo "       Install Xcode, or set DEVELOPER_DIR to an existing install." >&2
  exit 1
fi
echo "==> Using $DEVELOPER_DIR"

echo "==> Checking generated prompts"
# Fails the build if Prompts.swift no longer matches shared/prompts/*.json, so
# the two platforms cannot silently drift apart.
python3 "$ROOT/Scripts/generate-prompts.py" --check

echo "==> Building release binary"
swift build -c release

BINARY="$ROOT/.build/release/$PRODUCT_NAME"
[ -f "$BINARY" ] || { echo "error: binary not found at $BINARY" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>Minutes</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>27.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>MIT licensed. See LICENSE.</string>

    <!-- Recorded locally, transcribed on-device, summarized through your own
         Claude subscription. These strings are what the system shows in its
         permission prompts. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Minutes records your microphone so in-person meetings and your side of a call can be transcribed on this Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Minutes records the audio your Mac is playing so the other participants on a call can be transcribed on this Mac.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Minutes reads your calendar only to name recordings after the meeting you are in.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Minutes reads your calendar only to name recordings after the meeting you are in.</string>
</dict>
</plist>
PLIST

echo "==> Generating icon"
# MakeIcon renders every size natively; downscaling one large PNG with sips made
# the 16pt and 32pt icons muddy.
ICON_TMP="$(mktemp -d)"
if swiftc -target arm64-apple-macos26.0 -O "$ROOT/Scripts/MakeIcon.swift" \
        -o "$ICON_TMP/makeicon" 2>/dev/null \
   && "$ICON_TMP/makeicon" "$ICON_TMP" >/dev/null 2>&1 \
   && iconutil -c icns "$ICON_TMP/AppIcon.iconset" \
        -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  echo "    icon embedded"
  cp "$ICON_TMP/preview.png" "$BUILD_DIR/icon-preview.png" 2>/dev/null || true
else
  echo "    warning: icon generation failed; app will use the generic icon"
fi
rm -rf "$ICON_TMP"

# --- Signing ---------------------------------------------------------------
# macOS remembers a permission decision against the app's *code identity*. An
# ad-hoc signature is derived from the binary's hash, so it changes on every
# rebuild and TCC forgets the microphone and Audio Recording grants each time.
# Signing with a real certificate keeps that identity stable.
#
# Preference order:
#   1. $MINUTES_SIGN_IDENTITY, if you want to pin a specific one
#   2. a Developer ID Application certificate — best option: its designated
#      requirement names the certificate rather than hashing it, so grants
#      survive even a certificate renewal
#   3. the self-signed identity from Scripts/create-signing-identity.sh
#   4. ad-hoc, which works but forgets permissions on every rebuild
# Keeps its old name: the certificate already in the keychain is found by it,
# and a self-signed identity's designated requirement is its hash — a new one
# would reset permissions once.
SELF_SIGNED_NAME="Minutes Self-Signed"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGN_IDENTITY=""

if [ -n "${MINUTES_SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$MINUTES_SIGN_IDENTITY"
elif printf '%s' "$IDENTITIES" | grep -q "Developer ID Application"; then
  SIGN_IDENTITY="$(printf '%s' "$IDENTITIES" | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)".*/\1/')"
elif printf '%s' "$IDENTITIES" | grep -q "$SELF_SIGNED_NAME"; then
  SIGN_IDENTITY="$SELF_SIGNED_NAME"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing as: $SIGN_IDENTITY"

  # A certificate that expires mid-project fails the build with a confusing
  # error, so say so while there is still time to renew.
  EXPIRY="$(security find-certificate -c "$SIGN_IDENTITY" -p 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
  if [ -n "$EXPIRY" ]; then
    EXPIRY_EPOCH="$(date -j -f "%b %e %T %Y %Z" "$EXPIRY" +%s 2>/dev/null || echo 0)"
    NOW_EPOCH="$(date +%s)"
    if [ "$EXPIRY_EPOCH" -gt 0 ]; then
      DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
      echo "    certificate valid for $DAYS_LEFT more days (until $EXPIRY)"
      if [ "$DAYS_LEFT" -lt 45 ]; then
        echo "    warning: renew this certificate soon; signing fails once it expires"
      fi
    fi
  fi

  # --timestamp (a secure timestamp from Apple's server) is REQUIRED for
  # notarization — a build signed with --timestamp=none is rejected outright.
  # It needs network at signing time; if that ever fails offline, the build
  # still works locally but cannot be notarized.
  codesign --force --sign "$SIGN_IDENTITY" \
           --identifier "$BUNDLE_ID" \
           --entitlements "$ROOT/Scripts/Minutes.entitlements" \
           --options runtime --timestamp "$APP" 2>&1 | sed 's/^/    /'
else
  echo "==> Signing (ad-hoc — permissions will reset on every rebuild)"
  echo "    Run ./Scripts/create-signing-identity.sh for a stable identity."
  codesign --force --sign - \
           --identifier "$BUNDLE_ID" \
           --entitlements "$ROOT/Scripts/Minutes.entitlements" \
           --options runtime --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
fi

echo "==> Verifying signature"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "audio-input"; then
  echo "    audio-input entitlement present"
else
  echo "    warning: audio-input entitlement missing — microphone access will fail"
fi
codesign --verify --strict "$APP" 2>&1 | sed 's/^/    /' || echo "    warning: signature did not verify"
# The designated requirement is what TCC matches against. If this string is the
# same after a rebuild, granted permissions carry over.
echo "    designated requirement:"
codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => /      /p'

echo "==> Built $APP"

if [ "$ACTION" = "--install" ]; then
  echo "==> Installing to /Applications"
  # Quit a running copy first, or the copy will fail.
  osascript -e 'quit app "Minutes"' 2>/dev/null || true
  # The app was called Minutes before; quit and remove that copy too, or
  # both would sit in /Applications and both would answer to the same bundle
  # identifier.
  osascript -e 'quit app "Minutes"' 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/Minutes.app"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  echo "==> Launching"
  open "/Applications/$APP_NAME.app"
else
  echo
  echo "Run it with:   open \"$APP\""
  echo "Or install:    ./Scripts/build-app.sh --install"
fi

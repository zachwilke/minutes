#!/bin/bash
# Packages Minutes.app into a signed, compressed DMG for distribution.
#
# The DMG contains the app and an Applications alias — the standard drag-to-
# install layout. When notarization credentials exist the DMG is submitted to
# Apple's notary service and stapled, so a downloaded copy opens with no
# Gatekeeper ceremony. Without credentials the step is skipped loudly, and
# receivers must allow it once in System Settings > Privacy & Security.
#
# Credentials live in a keychain profile created by Scripts/setup-notary.sh.
# Set MINUTES_NOTARY_PROFILE to point at one stored under a different name.
set -euo pipefail

NOTARY_PROFILE="${MINUTES_NOTARY_PROFILE:-Minutes-Notary}"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Minutes"
VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' Scripts/build-app.sh | head -1)"
BUILD_DIR="$ROOT/build"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Building the app first"
./Scripts/build-app.sh >/dev/null

APP="$BUILD_DIR/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: $APP missing after build" >&2; exit 1; }

echo "==> Verifying the app's signature before shipping it"
codesign --verify --strict --deep "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "audio-input" \
  || { echo "error: audio-input entitlement missing — refusing to package" >&2; exit 1; }

# Notarize and staple the app itself before packaging it. A ticket stapled only
# to the DMG covers the download; once the app is dragged to Applications its
# first launch must fetch the ticket from Apple, which fails offline or behind a
# filtering proxy. Stapled into the bundle, it travels with the app.
HAVE_NOTARY=0
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  HAVE_NOTARY=1
  echo "==> Notarizing the app (so the ticket travels inside it)"
  APP_ZIP="$(mktemp -d)/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  if xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" \
       --wait 2>&1 | sed 's/^/    /' | tee "$BUILD_DIR/notary-app.log" \
     && grep -q "status: Accepted" "$BUILD_DIR/notary-app.log"; then
    xcrun stapler staple "$APP" | sed 's/^/    /'
    xcrun stapler validate "$APP" >/dev/null && echo "    app stapled"
  else
    echo "error: the app's notarization was not accepted — see $BUILD_DIR/notary-app.log" >&2
    exit 1
  fi
  rm -f "$APP_ZIP"
fi

echo "==> Staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

# Sign the DMG with the same identity, so the download itself verifies.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)".*/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  echo "==> Signing DMG as: $IDENTITY"
  codesign --force --sign "$IDENTITY" "$DMG"
else
  echo "==> No Developer ID found; DMG left unsigned"
fi

if [ "$HAVE_NOTARY" = "1" ]; then
  echo "==> Notarizing the DMG (Apple's service; typically one to five minutes)"
  if xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" \
       --wait 2>&1 | sed 's/^/    /' | tee "$BUILD_DIR/notary-dmg.log" \
     && grep -q "status: Accepted" "$BUILD_DIR/notary-dmg.log"; then
    echo "==> Stapling the ticket"
    xcrun stapler staple "$DMG" | sed 's/^/    /'
    xcrun stapler validate "$DMG" >/dev/null && echo "    stapled and validated"
    NOTARIZED=1
  else
    echo "error: notarization was not accepted — see the log above and" >&2
    echo "       'xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE'" >&2
    exit 1
  fi
else
  echo "==> Notarization SKIPPED — no credentials (run ./Scripts/setup-notary.sh once)"
  NOTARIZED=0
fi

echo "==> Done"
ls -lh "$DMG" | awk '{print "    " $9 "  " $5}'
echo
if [ "$NOTARIZED" = "1" ]; then
  echo "Notarized: downloaded copies open with no Gatekeeper prompt."
else
  echo "Receivers: first open needs System Settings > Privacy & Security > Open Anyway (unnotarized build)."
fi

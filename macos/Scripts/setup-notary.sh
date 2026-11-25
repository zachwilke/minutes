#!/bin/bash
# One-time: stores notarization credentials in your keychain so make-dmg.sh can
# notarize automatically. Run this yourself in a terminal — it asks for secrets
# that belong to your Apple account and stores them only in the local keychain.
#
# Two ways to get credentials; the app-specific password is usually quicker.
#
#   A) App-specific password (personal Apple ID on the team)
#      1. https://account.apple.com > Sign-In and Security > App-Specific Passwords
#      2. Generate one (name it "Minutes notarization")
#      3. Run this script and choose 1
#
#   B) App Store Connect API key (better for CI / shared use)
#      1. https://appstoreconnect.apple.com > Users and Access > Integrations
#         > Team Keys > generate with the Developer role
#      2. Download the .p8, note the Key ID and Issuer ID
#      3. Run this script and choose 2
set -euo pipefail

PROFILE="Minutes-Notary"
# Your Apple Developer Team ID — the 10-character string shown next to your team
# name at https://developer.apple.com/account. Set MINUTES_TEAM_ID to override.
TEAM_ID="${MINUTES_TEAM_ID:-}"

if [ -z "$TEAM_ID" ]; then
  printf "Apple Developer Team ID: "
  read -r TEAM_ID
fi

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "Credentials for profile '$PROFILE' already work. Nothing to do."
  exit 0
fi

echo "Storing notarization credentials as keychain profile '$PROFILE'."
echo
echo "  1) Apple ID + app-specific password"
echo "  2) App Store Connect API key (.p8)"
printf "Choose [1/2]: "
read -r choice

case "$choice" in
  1)
    printf "Apple ID email: "
    read -r apple_id
    # notarytool prompts for the password itself, hidden.
    xcrun notarytool store-credentials "$PROFILE" \
      --apple-id "$apple_id" \
      --team-id "$TEAM_ID"
    ;;
  2)
    printf "Path to the .p8 key file: "
    read -r key_path
    printf "Key ID: "
    read -r key_id
    printf "Issuer ID: "
    read -r issuer_id
    xcrun notarytool store-credentials "$PROFILE" \
      --key "$key_path" --key-id "$key_id" --issuer "$issuer_id"
    ;;
  *)
    echo "Nothing chosen; nothing stored." >&2
    exit 1
    ;;
esac

echo
echo "Verifying…"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null
echo "Working. From now on ./Scripts/make-dmg.sh notarizes and staples automatically."

#!/bin/zsh
# Notarizes and staples a Developer ID-signed .app or .dmg.
#   scripts/notarize.sh dist/NativeGranola.app
# Credentials, first match wins:
#   NOTARY_PROFILE                         keychain profile from `xcrun notarytool store-credentials`
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER   App Store Connect API key (.p8 path, key ID, issuer ID)
#   APPLE_ID, TEAM_ID, APP_PASSWORD        Apple ID with an app-specific password
set -euo pipefail
TARGET=${1:?usage: scripts/notarize.sh <app-or-dmg>}

if [[ -n ${NOTARY_PROFILE:-} ]]; then
  auth=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n ${NOTARY_KEY:-} ]]; then
  auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [[ -n ${APPLE_ID:-} ]]; then
  auth=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
else
  echo "error: set NOTARY_PROFILE, NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER or APPLE_ID/TEAM_ID/APP_PASSWORD" >&2
  exit 1
fi

# notarytool takes zips, DMGs and pkgs, not bare apps.
SUBMIT=$TARGET
if [[ $TARGET == *.app ]]; then
  SUBMIT=$(mktemp -d)/$(basename "$TARGET" .app).zip
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

result=$(xcrun notarytool submit "$SUBMIT" "${auth[@]}" --wait --output-format json)
echo "$result"
id=$(plutil -extract id raw - <<< "$result")
if [[ $(plutil -extract status raw - <<< "$result") != Accepted ]]; then
  xcrun notarytool log "$id" "${auth[@]}" >&2 || true
  exit 1
fi
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

#!/bin/zsh
# Release build into dist/: signed app, zip and DMG. Signs with DEVELOPER_ID when set (and
# notarizes if notary credentials are set, see scripts/notarize.sh); otherwise with the local
# identity or ad hoc, and the artifacts are named -unsigned.
#   scripts/release.sh            # version from Bundle/Info.plist
#   scripts/release.sh 0.2.0      # sets the version in the built bundle only
# Environment: BUILD_NUMBER (CFBundleVersion, default the version), SCRATCH_PATH, OUTPUT_DIR (default dist).
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION=${1:-$(plutil -extract CFBundleShortVersionString raw Bundle/Info.plist)}
export BUILD_NUMBER=${BUILD_NUMBER:-$VERSION}
export OUTPUT_DIR=${OUTPUT_DIR:-dist}
APP=$OUTPUT_DIR/NativeGranola.app

scripts/bundle.sh release

NAME=NativeGranola-$VERSION
if [[ -n ${DEVELOPER_ID:-} ]]; then
  if [[ -n ${NOTARY_PROFILE:-}${APPLE_ID:-}${NOTARY_KEY:-} ]]; then
    scripts/notarize.sh "$APP"
  else
    echo "warning: no notary credentials; the app is signed but not notarized" >&2
  fi
else
  NAME=$NAME-unsigned
fi

rm -f "$OUTPUT_DIR/$NAME.zip" "$OUTPUT_DIR/$NAME.dmg"
ditto -c -k --keepParent "$APP" "$OUTPUT_DIR/$NAME.zip"

STAGING=$(mktemp -d)
ditto "$APP" "$STAGING/NativeGranola.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Native Granola" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUTPUT_DIR/$NAME.dmg"
rm -rf "$STAGING"
if [[ -n ${DEVELOPER_ID:-} ]]; then
  keychain=(); [[ -n ${SIGN_KEYCHAIN:-} ]] && keychain=(--keychain "$SIGN_KEYCHAIN")
  codesign --force --sign "$DEVELOPER_ID" --timestamp "${keychain[@]}" "$OUTPUT_DIR/$NAME.dmg"
  [[ -n ${NOTARY_PROFILE:-}${APPLE_ID:-}${NOTARY_KEY:-} ]] && scripts/notarize.sh "$OUTPUT_DIR/$NAME.dmg"
fi

(cd "$OUTPUT_DIR" && shasum -a 256 "$NAME.zip" "$NAME.dmg" | tee SHA256SUMS)
echo "Release artifacts in $OUTPUT_DIR"

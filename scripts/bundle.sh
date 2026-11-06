#!/bin/zsh
# Builds build/NativeGranola.app with the hardened runtime and signs it with the identity from
# scripts/setup-signing.sh, which keeps macOS privacy permissions (mic, system audio) across
# rebuilds. Without it, the app is signed ad hoc and macOS asks for permissions again after every
# build. Set DEVELOPER_ID to sign for distribution instead.
#   scripts/bundle.sh            # debug build
#   scripts/bundle.sh release
# Environment:
#   SCRATCH_PATH   SwiftPM build directory (default .build)
#   OUTPUT_DIR     where NativeGranola.app goes (default build)
#   VERSION        sets CFBundleShortVersionString in the bundle; BUILD_NUMBER sets CFBundleVersion
#   DEVELOPER_ID   "Developer ID Application: ..." identity; SIGN_KEYCHAIN optionally names its keychain
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-debug}
SCRATCH_PATH=${SCRATCH_PATH:-.build}
OUTPUT_DIR=${OUTPUT_DIR:-build}
APP=$OUTPUT_DIR/NativeGranola.app
ENTITLEMENTS=Bundle/NativeGranola.entitlements
KEYCHAIN=$PWD/signing/dev.keychain-db

build=(swift build --disable-sandbox --scratch-path "$SCRATCH_PATH" -c "$CONFIG")
"${build[@]}" --product NativeGranola 2>&1 | grep -v -e "not accessible or not writable" -e "readonly database"
BIN_DIR=$("${build[@]}" --show-bin-path 2>/dev/null)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NativeGranola" "$APP/Contents/MacOS/NativeGranola"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
[[ -f Bundle/AppIcon.icns ]] && cp Bundle/AppIcon.icns "$APP/Contents/Resources/"
[[ -n ${VERSION:-} ]] && plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
[[ -n ${BUILD_NUMBER:-} ]] && plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

# Embed dynamically linked dependencies (e.g. dynamic binary frameworks from packages).
# FluidAudio 0.18 links statically, so today this finds nothing.
for dep in $(otool -L "$APP/Contents/MacOS/NativeGranola" | awk '$1 ~ /^@rpath\// {print $1}'); do
  name=${${dep#@rpath/}%%/*}
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$BIN_DIR/$name" "$APP/Contents/Frameworks/"
done
if [[ -d $APP/Contents/Frameworks ]]; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/NativeGranola"
fi

sign=(codesign --force --options runtime)
if [[ -n ${DEVELOPER_ID:-} ]]; then
  sign+=(--sign "$DEVELOPER_ID" --timestamp)
  [[ -n ${SIGN_KEYCHAIN:-} ]] && sign+=(--keychain "$SIGN_KEYCHAIN")
elif [[ -f signing/identity ]]; then
  security unlock-keychain -p nativegranola "$KEYCHAIN"
  sign+=(--sign "$(cat signing/identity)" --keychain "$KEYCHAIN")
else
  echo "warning: no signing identity (run scripts/setup-signing.sh); signing ad hoc" >&2
  sign+=(--sign -)
fi
# Inside out: embedded code first, then the app with its entitlements.
for item in "$APP"/Contents/Frameworks/*(N); do "${sign[@]}" "$item"; done
"${sign[@]}" --entitlements "$ENTITLEMENTS" --identifier com.nativegranola.app "$APP"
codesign --verify --deep --strict "$APP"
echo "Built and signed $APP"

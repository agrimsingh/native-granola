#!/bin/zsh
# Builds build/NativeGranola.app and signs it with the identity from scripts/setup-signing.sh,
# which keeps macOS privacy permissions (mic, system audio) across rebuilds. Without it, the app
# is signed ad hoc and macOS asks for permissions again after every build.
#   scripts/bundle.sh            # debug build
#   scripts/bundle.sh release
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-debug}
APP=build/NativeGranola.app
KEYCHAIN=$PWD/signing/dev.keychain-db

swift build --disable-sandbox -c "$CONFIG" --product NativeGranola 2>&1 \
  | grep -v -e "not accessible or not writable" -e "readonly database"
BIN=$(swift build --disable-sandbox -c "$CONFIG" --show-bin-path 2>/dev/null)/NativeGranola

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NativeGranola"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
[[ -f Bundle/AppIcon.icns ]] && cp Bundle/AppIcon.icns "$APP/Contents/Resources/"

if [[ -f signing/identity ]]; then
  security unlock-keychain -p nativegranola "$KEYCHAIN"
  codesign --force --sign "$(cat signing/identity)" --keychain "$KEYCHAIN" --identifier com.nativegranola.app "$APP"
else
  echo "warning: no signing identity (run scripts/setup-signing.sh); signing ad hoc" >&2
  codesign --force --sign - --identifier com.nativegranola.app "$APP"
fi
codesign --verify "$APP"
echo "Built and signed $APP"

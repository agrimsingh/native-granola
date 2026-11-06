#!/bin/zsh
# Runs the test suite with the Command Line Tools (no Xcode). Extra args go to `swift test`,
# e.g. scripts/test.sh --filter GranolaMCPTests
set -euo pipefail
cd "$(dirname "$0")/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@" 2>&1 | grep -v -e "not accessible or not writable" -e "readonly database" -e "cannot copy parseable Swift interface"

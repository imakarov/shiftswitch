#!/bin/bash
# Build ShiftSwitch.app (universal), sign it, optionally install to /Applications.
#   ./build.sh            build into build/ShiftSwitch.app
#   ./build.sh install    build, copy to /Applications, launch
# Signing identity: $SIGN_IDENTITY, else "Developer ID Application", else "Apple Development", else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ShiftSwitch.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -whole-module-optimization -target $arch-apple-macos13.0 Sources/main.swift -o build/$arch
done
lipo -create build/arm64 build/x86_64 -output "$APP/Contents/MacOS/ShiftSwitch"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
find_id() { security find-identity -v -p codesigning | awk -F'"' -v p="$1" '$2 ~ p {print $2; exit}'; }
IDENTITY="${SIGN_IDENTITY:-$(find_id "Developer ID Application")}"
IDENTITY="${IDENTITY:-$(find_id "Apple Development")}"
codesign --force --options runtime --timestamp --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
if [[ "${1:-}" == "install" ]]; then
  pkill -x ShiftSwitch || true
  rm -rf /Applications/ShiftSwitch.app && cp -R "$APP" /Applications/
  open /Applications/ShiftSwitch.app
  echo "Installed /Applications/ShiftSwitch.app"
fi

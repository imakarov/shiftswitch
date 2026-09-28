#!/bin/bash
# Build, package as DMG, notarize, staple. Output: dist/ShiftSwitch-<version>.dmg
# Needs a "Developer ID Application" identity and a notarytool keychain profile:
#   xcrun notarytool store-credentials shiftswitch --key AuthKey_XXX.p8 --key-id XXX --issuer <uuid>
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-shiftswitch}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "No Developer ID Application identity in keychain"; exit 1; }
./build.sh
DMG="dist/ShiftSwitch-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R build/ShiftSwitch.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist && rm -f "$DMG"
hdiutil create -volname "ShiftSwitch $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DMG"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG"

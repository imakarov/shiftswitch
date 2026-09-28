#!/bin/bash
# Build, package as DMG, notarize, staple → dist/ShiftSwitch.dmg (stable name: .../releases/latest/download/ShiftSwitch.dmg).
#   scripts/release.sh           build + notarize only
#   scripts/release.sh publish   also create GitHub release v<version> and bump the Homebrew cask in ../homebrew-tap
# Needs a "Developer ID Application" identity and a notarytool keychain profile:
#   xcrun notarytool store-credentials shiftswitch --key AuthKey_XXX.p8 --key-id XXX --issuer <uuid>
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-shiftswitch}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "No Developer ID Application identity in keychain"; exit 1; }
./build.sh
DMG="dist/ShiftSwitch.dmg"
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
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "sha256 $SHA"
[[ "${1:-}" == "publish" ]] || exit 0
gh release create "v$VERSION" "$DMG" --title "ShiftSwitch $VERSION" --generate-notes
TAP=../homebrew-tap
sed -i '' -E "s/version \"[^\"]+\"/version \"$VERSION\"/; s/sha256 \"[^\"]+\"/sha256 \"$SHA\"/" "$TAP/Casks/shiftswitch.rb"
git -C "$TAP" commit -am "Update shiftswitch to $VERSION" && git -C "$TAP" push

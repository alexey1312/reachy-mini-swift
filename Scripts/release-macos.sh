#!/bin/bash
# Archive the macOS app (Release, signed), export it with Developer ID,
# notarize, staple, and zip it for distribution.
#
#   mise run release:macos               # the whole pipeline
#   mise run release:macos -- --no-notarize  # stop after the signed export
#
# Needs a "Developer ID Application" certificate in the keychain
# (Xcode → Settings → Accounts → Manage Certificates) besides the ASC API key.
set -euo pipefail

# shellcheck source=Scripts/release-env.sh
. "$(dirname "$0")/release-env.sh"

notarize=true
require_asc_key
while [ $# -gt 0 ]; do
  case "$1" in
  --no-notarize) notarize=false ;;
  *)
    echo "usage: release-macos.sh [--no-notarize]" >&2
    exit 2
    ;;
  esac
  shift
done

BUILD_NUMBER="$(git rev-list --count HEAD)"
ARCHIVE=Apps/DerivedData/Archives/ReachyMini-macOS.xcarchive
EXPORT_DIR=Apps/DerivedData/Export/macOS

set -o pipefail
xcodebuild archive \
  -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyMini \
  -destination 'generic/platform=macOS' -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath Apps/DerivedData \
  DEVELOPMENT_TEAM="$REACHY_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates \
  -skipPackagePluginValidation -skipMacroValidation \
  2>&1 | xcsift

/bin/rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist Scripts/exportOptions/developer-id.plist \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  2>&1 | xcsift

APP="$EXPORT_DIR/ReachyMini.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$EXPORT_DIR/HeyReachy-$VERSION.zip"

ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$notarize" = true ]; then
  xcrun notarytool submit "$ZIP" \
    --key "$REACHY_ASC_KEY_PATH" \
    --key-id "$REACHY_ASC_KEY_ID" \
    --issuer "$REACHY_ASC_ISSUER_ID" \
    --wait
  xcrun stapler staple "$APP"
  # The staple changed the bundle, so the zip that ships is rebuilt from it.
  /bin/rm "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Notarized and stapled. Attach it to the tag's GitHub release with:"
else
  echo "Signed but NOT notarized (--no-notarize). For a real release rerun without the flag."
fi
echo "  gh release upload $VERSION $ZIP"

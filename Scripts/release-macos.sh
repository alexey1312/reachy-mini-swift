#!/bin/bash
# Archive the macOS app (Release, signed) and ship it through both distribution
# channels: the Mac App Store (TestFlight) and Developer ID (notarized zip).
#
#   mise run release:macos                             # both channels
#   mise run release:macos -- --channel appstore       # TestFlight only
#   mise run release:macos -- --channel developer-id   # notarized zip only
#   mise run release:macos -- --no-notarize            # developer-id: stop after signing
#   mise run release:macos -- --no-upload              # appstore: export a .pkg locally
#
# The last two flags each belong to one channel and are ignored by the other.
#
# One archive feeds both exports: it is not signed for a channel, `-exportArchive`
# re-signs it per method, so the two artifacts cannot differ in anything but the
# signature. Developer ID runs first deliberately — it is the artifact that always
# ships, and an App Store upload that fails should not also cost you the zip.
#
# Needs a "Developer ID Application" certificate in the keychain
# (Xcode → Settings → Accounts → Manage Certificates) besides the ASC API key.
set -euo pipefail

# shellcheck source=Scripts/release-env.sh
. "$(dirname "$0")/release-env.sh"

channel=both
notarize=true
upload=true
require_development_team
usage() {
  echo "usage: release-macos.sh [--channel appstore|developer-id|both] [--no-notarize] [--no-upload]" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
  --channel)
    shift
    case "${1:-}" in
    appstore | developer-id | both) channel="$1" ;;
    *) usage ;;
    esac
    ;;
  --no-notarize) notarize=false ;;
  --no-upload) upload=false ;;
  *) usage ;;
  esac
  shift
done

wants_appstore=false
wants_developer_id=false
# A case rather than two `[ … ] || [ … ] && flag=true` lines: that form returns
# non-zero when neither test matches, and `set -e` takes the whole list's status.
case "$channel" in
appstore) wants_appstore=true ;;
developer-id) wants_developer_id=true ;;
both)
  wants_appstore=true
  wants_developer_id=true
  ;;
esac

# Only notarization needs the key; the App Store channel signs through the Xcode
# account like the iOS one, for the reason release-env.sh documents.
if [ "$wants_developer_id" = true ] && [ "$notarize" = true ]; then
  require_asc_key
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
ARCHIVE=Apps/DerivedData/Archives/ReachyMini-macOS.xcarchive
EXPORT_DIR=Apps/DerivedData/Export/macOS

set -o pipefail
# COMPILATION_CACHE_ENABLE_CACHING=NO and the metadata check: same reasoning as
# release-ios.sh — a shipping archive compiles clean, and an archive whose
# Metadata.appintents came out empty ships an app with no actions in the
# Shortcuts app while the build stays green.
xcodebuild archive \
  -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyMini \
  -destination 'generic/platform=macOS' -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath Apps/DerivedData \
  DEVELOPMENT_TEAM="$REACHY_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  COMPILATION_CACHE_ENABLE_CACHING=NO \
  -allowProvisioningUpdates \
  -skipPackagePluginValidation -skipMacroValidation \
  2>&1 | xcsift

Scripts/check-appintents-metadata.sh "$ARCHIVE"

if [ "$wants_developer_id" = true ]; then
  /bin/rm -rf "$EXPORT_DIR/DeveloperID"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist Scripts/exportOptions/developer-id.plist \
    -exportPath "$EXPORT_DIR/DeveloperID" \
    -allowProvisioningUpdates \
    2>&1 | xcsift

  APP="$EXPORT_DIR/DeveloperID/ReachyMini.app"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  # The zip stays at the top of the export directory: it is the one artifact that
  # leaves this machine by hand, and docs/release.md names that path.
  ZIP="$EXPORT_DIR/HeyReachy-$VERSION.zip"

  /bin/rm -f "$ZIP"
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
fi

if [ "$wants_appstore" = true ]; then
  /bin/rm -rf "$EXPORT_DIR/AppStore"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$(appstore_export_options "$upload")" \
    -exportPath "$EXPORT_DIR/AppStore" \
    -allowProvisioningUpdates \
    2>&1 | xcsift

  if [ "$upload" = true ]; then
    echo "Uploaded macOS build $BUILD_NUMBER to App Store Connect. TestFlight shows it after processing (minutes)."
  else
    echo "Exported without uploading:"
    ls "$EXPORT_DIR/AppStore"/*.pkg
  fi
fi

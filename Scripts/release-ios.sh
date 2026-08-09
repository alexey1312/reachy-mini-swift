#!/bin/bash
# Archive the iOS app (Release, signed) and upload it to TestFlight.
#
#   mise run release:ios              # archive → upload to App Store Connect
#   mise run release:ios -- --no-upload   # archive → export an .ipa locally
#
# The build number is the commit count: monotonic, reproducible, and never
# stored in the repository — so releasing does not require a version-bump
# commit for anything but MARKETING_VERSION.
set -euo pipefail

# shellcheck source=Scripts/release-env.sh
. "$(dirname "$0")/release-env.sh"

upload=true
while [ $# -gt 0 ]; do
  case "$1" in
  --no-upload) upload=false ;;
  *)
    echo "usage: release-ios.sh [--no-upload]" >&2
    exit 2
    ;;
  esac
  shift
done

BUILD_NUMBER="$(git rev-list --count HEAD)"
ARCHIVE=Apps/DerivedData/Archives/ReachyMini-iOS.xcarchive

set -o pipefail
xcodebuild archive \
  -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyMini \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath Apps/DerivedData \
  DEVELOPMENT_TEAM="$REACHY_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$REACHY_ASC_KEY_PATH" \
  -authenticationKeyID "$REACHY_ASC_KEY_ID" \
  -authenticationKeyIssuerID "$REACHY_ASC_ISSUER_ID" \
  -skipPackagePluginValidation -skipMacroValidation \
  2>&1 | xcsift

EXPORT_OPTIONS=Scripts/exportOptions/appstore.plist
if [ "$upload" = false ]; then
  # Same options with the upload turned into a local export.
  EXPORT_OPTIONS="$(mktemp -t reachy-export-options).plist"
  plutil -convert xml1 -o "$EXPORT_OPTIONS" Scripts/exportOptions/appstore.plist
  plutil -replace destination -string export "$EXPORT_OPTIONS"
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath Apps/DerivedData/Export/iOS \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$REACHY_ASC_KEY_PATH" \
  -authenticationKeyID "$REACHY_ASC_KEY_ID" \
  -authenticationKeyIssuerID "$REACHY_ASC_ISSUER_ID" \
  2>&1 | xcsift

if [ "$upload" = true ]; then
  echo "Uploaded build $BUILD_NUMBER to App Store Connect. TestFlight shows it after processing (minutes)."
else
  echo "Exported without uploading:"
  ls Apps/DerivedData/Export/iOS/*.ipa
fi

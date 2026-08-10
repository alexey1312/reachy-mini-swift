#!/bin/bash
# Archive the iOS app (Release, signed) and upload it to TestFlight.
#
#   mise run release:ios              # archive → upload to App Store Connect
#   mise run release:ios -- --no-upload   # archive → export an .ipa locally
#
# Signing and uploading go through the Xcode account, not the App Store Connect
# API key — see release-env.sh for the measurement behind that.
#
# The build number is the commit count: monotonic, reproducible, and never
# stored in the repository — so releasing does not require a version-bump
# commit for anything but MARKETING_VERSION.
set -euo pipefail

# shellcheck source=Scripts/release-env.sh
. "$(dirname "$0")/release-env.sh"

upload=true
require_development_team
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
# COMPILATION_CACHE_ENABLE_CACHING=NO: the shipping artifact gets a clean,
# uncached compile. The cache went on by default the day before 0.1.1 was
# archived, and 0.1.1 is the build that installed from TestFlight with no
# Shortcuts actions at all — an archive is rare enough that replayed
# compilations buy nothing worth that variable. The metadata check below is
# what proves the archive either way, before anything is uploaded.
xcodebuild archive \
  -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyMini \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath Apps/DerivedData \
  DEVELOPMENT_TEAM="$REACHY_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  COMPILATION_CACHE_ENABLE_CACHING=NO \
  -allowProvisioningUpdates \
  -skipPackagePluginValidation -skipMacroValidation \
  2>&1 | xcsift

# An archive whose Metadata.appintents came out empty ships an app with no
# actions in the Shortcuts app, and nothing in the build reddens over it.
Scripts/check-appintents-metadata.sh "$ARCHIVE"

EXPORT_OPTIONS="$(appstore_export_options "$upload")"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath Apps/DerivedData/Export/iOS \
  -allowProvisioningUpdates \
  2>&1 | xcsift

if [ "$upload" = true ]; then
  echo "Uploaded build $BUILD_NUMBER to App Store Connect. TestFlight shows it after processing (minutes)."
else
  # The archive was already checked, but the .ipa is what actually ships, and
  # -exportArchive re-signs and repacks on the way — so prove the metadata
  # survived the export too. Only the --no-upload path leaves an .ipa behind;
  # `destination: upload` hands the artifact straight to App Store Connect.
  IPA="$(ls Apps/DerivedData/Export/iOS/*.ipa | head -1)"
  UNPACKED="$(mktemp -d -t reachy-ipa-check)"
  ditto -x -k "$IPA" "$UNPACKED"
  Scripts/check-appintents-metadata.sh "$UNPACKED"/Payload/*.app
  echo "Exported without uploading:"
  ls Apps/DerivedData/Export/iOS/*.ipa
fi

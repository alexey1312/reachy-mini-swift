#!/bin/bash
# Xcode Cloud clones a repository with no Xcode project in it — ours is
# generated. This runs right after the clone: install the pinned tools through
# the committed mise bootstrap, run the Prefire playbook + tuist generate
# (that is what `mise run project` is), and the workspace exists by the time
# Xcode Cloud goes looking for it.
#
# Setup quirks, once:
# - Create the workflow from a local Xcode with the generated workspace open
#   (Report navigator → Cloud tab), not from the App Store Connect wizard —
#   the wizard wants to see a project in the repo and there is none.
# - Set the workflow's start build number above the last locally-uploaded one
#   (App Store Connect rejects a number it has already seen for the version).
# - Git LFS is not supported on Xcode Cloud: the snapshot references arrive as
#   pointer stubs. Archiving the app never reads them; do not add the snapshot
#   scheme to an Xcode Cloud workflow.
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

# Swift macros and package plugins cannot answer a trust prompt headless.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

./bin/mise install --yes
./bin/mise run project

# App Store Connect wants ascending build numbers. CI_BUILD_NUMBER is Xcode
# Cloud's own counter; local releases use the commit count instead, which is
# why the workflow's start number has to be set above them once.
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
  /usr/bin/sed -i '' \
    "s/CURRENT_PROJECT_VERSION = 1;/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER;/g" \
    Apps/ReachyMiniApps.xcodeproj/project.pbxproj
fi

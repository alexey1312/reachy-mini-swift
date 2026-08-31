#!/bin/sh
# =============================================================================
# Keep SwiftPM off a beta Xcode's SDK — sourced, never executed
# =============================================================================
# The swift.org toolchain pinned in `.swift-version` cannot read every SDK a beta
# Xcode ships. Swift 6.3.0 against Xcode 27 beta's macOS 27 SDK puts the backing
# storage of a `@State private` property into the synthesised memberwise
# initialiser, which makes that initialiser private too. ReachyUI then refuses to
# compile at thirteen call sites:
#
#     error: 'LogConsoleView' initializer is inaccessible due to
#     'private' protection level
#
# The same source builds green under Xcode 27's own Swift 6.4 and on CI, whose
# `lint-test` job runs SwiftPM on an image with a release SDK. So this is the SDK,
# not the code, and the machine already carries a release SDK beside the beta one:
# the Command Line Tools ship theirs at a path of their own.
#
# Only while a beta Xcode is selected. The override removes itself the day the
# release arrives, and it does nothing on Linux, where `xcode-select` is absent.
case "$(xcode-select -p 2>/dev/null)" in
*Beta*)
	if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]; then
		SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
		export SDKROOT
	fi
	;;
esac

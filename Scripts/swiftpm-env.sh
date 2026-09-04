#!/bin/sh
# =============================================================================
# Keep SwiftPM off a beta Xcode's SDK — sourced, never executed
# =============================================================================
# The swift.org toolchain pinned in `.swift-version` cannot read every SDK a beta
# Xcode ships. Swift 6.3.0 against Xcode 27 beta's macOS 27 SDK puts the backing
# storage of a `@State private` property into the synthesised memberwise
# initialiser, which makes that initialiser private too. ReachyUI then refuses to
# compile at 401 call sites across ten types — this line first said thirteen, which
# was the count before anyone re-measured it (`docs/research/ios-27.md`):
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
# Case-folded: Apple ships `Xcode-beta.app` and Xcodes.app names the same build
# `Xcode-27.0.0-Beta.6.app`, so matching one spelling silently misses the other.
#
# **And only for a swift.org toolchain, which is what the paragraph above is about.**
# Xcode's own Swift reads the beta SDK perfectly well — `swift build` against Xcode 27
# beta 6's macOS 27 SDK completes in 32 s here, the same configuration `lint-test`
# builds in — so swapping the SDK out from under a machine with no swiftly installed
# bought nothing and cost the one thing #124 needed: a `Sources/` that names an iOS 27
# symbol cannot compile against a 26.5 SDK, so every local `mise run build` and
# `mise run test` would fail over declarations the four app jobs build happily.
#
# A swift.org toolchain keeps the swap, and now for a second reason as well as the
# first: it cannot build this package against either SDK any more — 27 symbols are
# absent from 26.5 — and "cannot find 'LongRunningIntent' in scope" is a far better
# thing to read than 401 inaccessible-initialiser errors across ten types.
#
# The version line is the measurement rather than a path guess: Xcode's toolchain
# stamps `swiftlang-6.4.0.33.1`, a swift.org build stamps `swift-6.3.3-RELEASE`.
case "$(xcode-select -p 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
*beta*)
	if [ -z "${SDKROOT:-}" ] &&
		[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ] &&
		! swift --version 2>/dev/null | grep -q 'swiftlang-'; then
		SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
		export SDKROOT
	fi
	;;
esac

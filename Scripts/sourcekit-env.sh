#!/bin/sh
# =============================================================================
# SourceKit for SwiftLint on Linux — sourced, never executed
# =============================================================================
# SwiftLint links SourceKitten, which dlopens `libsourcekitdInProc.so` before it
# reads a single rule. On macOS that library comes from Xcode and nothing has to be
# said about it. On Linux it comes from the swift.org toolchain and nothing puts it
# on the loader's path, so swiftlint dies with
#
#     SourceKittenFramework/library_wrapper.swift:58: Fatal error:
#     Loading libsourcekitdInProc.so failed
#
# — before any rule runs, which is why disabling the SourceKit-dependent rules (the
# `json_codec_only` custom rule and its `match_kinds`) does not help. A `--strict`
# warning is then unfindable off a Mac: swiftformat, dprint and check-catalogue all
# pass over a `function_body_length` violation happily, and CI is the only thing
# left that can see it.
#
# Sourced by the lint/format tasks in mise.toml. On macOS it does nothing at all,
# and on a Linux checkout with no toolchain it warns and returns — the lint task
# still has a catalogue check, actionlint and two lockstep checks to run, and none
# of them needs any of this.
#
# `Scripts/install-sourcekit.sh` is what puts the libraries where this finds them.
# =============================================================================

if [ "$(uname -s)" = "Linux" ]; then
    # First match wins. The override is first so a hand-unpacked toolchain can be
    # named without arguing with the search order.
    _reachy_sourcekit_lib=""
    for _candidate in \
        "${REACHY_SOURCEKIT_LIB:-}" \
        "${XDG_CACHE_HOME:-$HOME/.cache}/reachy-mini/sourcekit/usr/lib" \
        "$HOME/.local/share/swiftly/toolchains/$(cat "${MISE_PROJECT_ROOT:-.}/.swift-version" 2>/dev/null)/usr/lib" \
        "$(command -v swift >/dev/null 2>&1 && cd "$(dirname "$(command -v swift)")/../lib" 2>/dev/null && pwd)"; do
        if [ -n "$_candidate" ] && [ -f "$_candidate/libsourcekitdInProc.so" ]; then
            _reachy_sourcekit_lib="$_candidate"
            break
        fi
    done

    if [ -n "$_reachy_sourcekit_lib" ]; then
        # Both directories are needed: the compiler libraries under `swift/host/compiler`
        # find each other through a relative rpath, but `libsourcekitdInProc.so` itself and
        # the runtime under `swift/linux` do not.
        LD_LIBRARY_PATH="$_reachy_sourcekit_lib:$_reachy_sourcekit_lib/swift/linux${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export LD_LIBRARY_PATH
    else
        echo "NOTE: no libsourcekitdInProc.so found — swiftlint will not run on this checkout." >&2
        echo "      Install it with Scripts/install-sourcekit.sh (or point REACHY_SOURCEKIT_LIB" >&2
        echo "      at the usr/lib of a swift.org toolchain)." >&2
    fi

    unset _candidate _reachy_sourcekit_lib
fi

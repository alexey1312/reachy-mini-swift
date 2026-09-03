#!/bin/bash
# Assert a built app actually carries its App Intents metadata.
#
#   Scripts/check-appintents-metadata.sh <ReachyMini.app | ReachyMini-*.xcarchive>
#
# TestFlight 0.1.1 installed with no actions in the Shortcuts app at all. The
# intents live in a static SPM library (ReachyWidgetUI), so Shortcuts only ever
# sees what appintentsmetadataprocessor extracted into `Metadata.appintents` at
# build time — and extraction failing is a warning, never a build error, so the
# archive stays green over an app that ships without its actions. Reading the
# artifact is the one trustworthy signal; this is the same check
# Sources/ReachyWidgetUI/AGENTS.md describes doing by hand against Debug
# products, run against whatever bundle it is handed.
#
# Checked: every Shortcuts-facing intent and a non-empty `autoShortcuts`
# (the extracted ReachyShortcuts provider) in the app's own metadata, the four
# configuration intents in the appex's (iOS only — that metadata is what the
# widget's and the three configurable controls' Edit sheets are built from), and
# that no `extract.packagedata` exists anywhere — an AppIntentsPackage
# conformance emits one, and linkd rejects the bundle's entire metadata over it
# (aggregateMetadataIsEmpty).
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: check-appintents-metadata.sh <path-to-.app-or-.xcarchive>" >&2
  exit 2
fi

python3 - "$1" <<'PY'
import json
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
if not target.exists():
    sys.exit(f"check-appintents-metadata: {target} does not exist")

if target.suffix == ".xcarchive":
    apps = list((target / "Products" / "Applications").glob("*.app"))
    if len(apps) != 1:
        sys.exit(f"check-appintents-metadata: expected one app in {target}, found {apps}")
    target = apps[0]

REQUIRED_APP_ACTIONS = [
    "WakeRobotIntent",
    "SleepRobotIntent",
    "PowerOffRobotIntent",
    "StartRobotAppIntent",
    "StopRobotAppIntent",
    "ToggleRobotAppIntent",
    "PlayMoveIntent",
    "StopMoveIntent",
    "RobotAwakeIntent",
    "RunningAppIntent",
    # The two sound intents carry no App Shortcut phrase — ReachyShortcuts is at ten of
    # ten — but they are discoverable in the Shortcuts app, which is exactly what this
    # file decides. Extraction failing is a warning, so their absence here would ship
    # green.
    "PlaySoundIntent",
    "StopSoundIntent",
    # The two intents extracted from the app target's own sources rather than
    # from ReachyWidgetUI: both open the app, which errors in an appex, so
    # neither may move into the library the extension links. `CallRobotIntent`
    # says so itself; `SearchRobotAppsIntent` is handed `openAppWhenRun` by
    # `ShowInAppSearchResultsIntent`'s protocol extension and cannot decline it.
    "CallRobotIntent",
    # The app's first schema conformance (`.system.search`). A schema is
    # validated by the metadata processor rather than by the compiler, so a
    # parameter renamed out of shape fails extraction and nothing else — which
    # is exactly the silence this file exists to break.
    "SearchRobotAppsIntent",
    # `.system.open`, and iOS 27 / macOS 27 only. Listing it unconditionally is
    # safe and was checked rather than assumed: availability is a *field* in the
    # metadata, not an absence from it — a macOS 15 build extracts the action with
    # `availabilityAnnotations.LNPlatformNameMACOS.introducedVersion = "27.0"`
    # beside it. The same reading `isDiscoverable = false` gets two entries below.
    "OpenRobotAppIntent",
]

# Required of an iOS bundle and absent from a macOS one by construction.
#
# ActivityKit ships for iOS and Mac Catalyst, and this app's Mac target is native, so
# `StopRunningAppActivityIntent` is behind `#if os(iOS)` along with the rest of the
# Live Activity. Listing it unconditionally is what failed the macOS Release build on
# #118: the check is right that the action is missing, and the action is right to be
# missing. `isDiscoverable = false` keeps it out of the Shortcuts app but not out of
# this file — the flag is a field in the metadata, not an absence from it — and
# extraction failing would leave a card whose only control does nothing, silently.
REQUIRED_IOS_APP_ACTIONS = [
    "StopRunningAppActivityIntent",
]
REQUIRED_APPEX_ACTIONS = [
    "RobotAppsConfigurationIntent",
    # A control's Edit sheet is built from this metadata exactly as the widget's
    # is, so a configuration intent that stopped extracting costs the picker and
    # nothing goes red. Both are isDiscoverable = false and are recorded here
    # anyway — the flag is a field in the file, not an absence from it.
    "MoveControlConfigurationIntent",
    "RobotAppControlConfigurationIntent",
    "SoundControlConfigurationIntent",
]

# `size:` on a collection `@Parameter` is a *requirement* on the selection, and the
# way to get it wrong compiles, extracts and ships. `IntentCollectionSize` is
# `ExpressibleByIntegerLiteral` onto `init(exactly:)`, so `size: [.systemSmall: 2]`
# means min 2 *and* max 2 — a robot with one installed app can then never satisfy the
# configuration, and the only symptom is the widget sitting in WidgetKit's redacted
# placeholder for ever: no error, no crash, no Edit sheet that can be closed, and no
# buttons, because a placeholder has none. Sources/ReachyWidgetUI/AGENTS.md has the
# incident; it shipped once already, in #7.
#
# Nothing else in this repository can see it. The previews render
# `RobotAppsWidgetView` directly, so the snapshot suite never opens
# `Metadata.appintents`; and `AppIntentsTesting`, which was wanted for exactly this,
# exposes no parameter metadata and no `IntentCollectionSize` at all
# (docs/research/ios-27.md §3.1). The built file is the only witness, which is why the
# check is here and not in `swift test`.
#
# Two assertions, because there are two ways to be wrong and the first hides the
# second. The list below names the parameters that must carry sizes *at all*: deleting
# the `size:` argument leaves no tag behind, and a rule quantified over parameters that
# have one would pass over it in silence. The rule itself is then quantified over every
# parameter in the bundle rather than over that list, so the next `@Parameter(size:)`
# anywhere in this app is covered without anyone remembering to come back here.
#
# The rule is `min == 0` (and a `max` that can hold something), and 2 / 4 / 8 are
# deliberately *not* repeated here. Those are a grid decision — `RobotAppsWidgetContent`
# truncates with `prefix`, so growing the large widget changes them legitimately — and a
# guard that pinned them would go red for a design change and teach everyone to edit the
# guard. What may not change is the floor: an empty selection means "show the robot's
# own list", so zero is a state rather than a bound nobody reaches, and any other
# minimum is a widget that cannot render until the reader has picked that many.
#
# Read out of the *app* bundle rather than the appex, which is what makes one assertion
# cover both platforms: the entry is byte-identical in Release/ReachyMini.app/Contents/
# Resources/Metadata.appintents and Release-iphoneos/ReachyMini.app/Metadata.appintents,
# and a macOS bundle has no appex to look in. It also asserts, in passing, that the
# widget's configuration intent reaches the app's own metadata — it does, because the
# app links ReachyWidgetUI too.
COLLECTION_SIZE_TAG = "LNValueTypeMetadataKeyCollectionSizes"
REQUIRED_COLLECTION_SIZES = [("RobotAppsConfigurationIntent", "apps")]


def collection_sizes(parameter):
    """The `{family: {min, max}}` payload, or None where the parameter declares none.

    `typeSpecificMetadata` is a flat tag-then-payload array — `[tag, {...}, ...]` — and
    not an object, so this walks it in pairs. Reading index 1 happens to work today and
    would start reading the wrong dictionary, silently, the day a parameter carries a
    second kind of metadata ahead of this one.
    """
    entries = parameter.get("typeSpecificMetadata") or []
    for tag, payload in zip(entries[::2], entries[1::2]):
        if tag == COLLECTION_SIZE_TAG:
            sizes = (payload or {}).get("collectionSizes", {}).get("sizes")
            return sizes if isinstance(sizes, dict) else {}
    return None


metadata = list(target.rglob("extract.actionsdata"))
app_files = [p for p in metadata if not any(a.suffix == ".appex" for a in p.parents)]
appex_files = [p for p in metadata if p not in app_files]

failures = []
# Reported on success, so a green log says the check ran. A check nobody can see is one
# that gets deleted unnoticed.
checked_sizes = 0

if len(app_files) != 1:
    failures.append(
        f"expected exactly one Metadata.appintents/extract.actionsdata in the app "
        f"bundle, found {len(app_files)}: {[str(p) for p in app_files]}"
    )
else:
    data = json.loads(app_files[0].read_text())
    actions = data.get("actions") or {}
    # A macOS `.app` keeps its Info.plist under `Contents/`; an iOS one has it at the
    # root. That is the same distinction `mise run inspect:bundle` draws, and it is
    # the only one available from the artifact alone.
    is_macos = (target / "Contents" / "Info.plist").exists()
    required = REQUIRED_APP_ACTIONS + ([] if is_macos else REQUIRED_IOS_APP_ACTIONS)
    missing = [name for name in required if name not in actions]
    if missing:
        failures.append(f"app metadata is missing actions: {missing} (has {sorted(actions)})")
    if not data.get("autoShortcuts"):
        failures.append("app metadata has no autoShortcuts — ReachyShortcuts was not extracted")

    # Every parameter, not only the one named in REQUIRED_COLLECTION_SIZES: the rule is
    # about `@Parameter(size:)` and not about this one intent.
    for action_name, action in sorted(actions.items()):
        for parameter in action.get("parameters") or []:
            sizes = collection_sizes(parameter)
            if sizes is None:
                continue
            checked_sizes += 1
            for family, bounds in sorted(sizes.items()):
                minimum = (bounds or {}).get("min")
                maximum = (bounds or {}).get("max")
                if minimum != 0 or not isinstance(maximum, int) or maximum < 1:
                    failures.append(
                        f"{action_name}.{parameter.get('name')} declares {family} = "
                        f"{bounds}, but a collection @Parameter(size:) must range from 0 "
                        f"up to at least 1 — a bare integer literal is "
                        f"IntentCollectionSize(exactly:), so min == max, and that or a "
                        f"max of 0 leaves the widget in its placeholder for ever "
                        f"(Sources/ReachyWidgetUI/RobotAppsConfigurationIntent.swift)"
                    )

    for action_name, parameter_name in REQUIRED_COLLECTION_SIZES:
        parameters = (actions.get(action_name) or {}).get("parameters") or []
        parameter = next((p for p in parameters if p.get("name") == parameter_name), None)
        if parameter is None:
            failures.append(
                f"{action_name} has no parameter named {parameter_name!r} (has "
                f"{[p.get('name') for p in parameters]}) — the name in the metadata is "
                f"the Swift property's, so this is a rename or a dropped intent"
            )
        elif not collection_sizes(parameter):
            failures.append(
                f"{action_name}.{parameter_name} carries no {COLLECTION_SIZE_TAG}: the "
                f"@Parameter(size:) argument is gone, which leaves every family "
                f"unconstrained and is exactly as silent as getting the bounds wrong"
            )

# The widget extension is iOS-only; a macOS bundle legitimately has no appex.
for appex in appex_files:
    data = json.loads(appex.read_text())
    actions = data.get("actions") or {}
    missing = [name for name in REQUIRED_APPEX_ACTIONS if name not in actions]
    if missing:
        failures.append(f"{appex}: missing actions {missing} (has {sorted(actions)})")

if (target / "PlugIns").is_dir() and not appex_files:
    failures.append("the app embeds an appex but no extract.actionsdata was found inside it")

# An extract.packagedata names an AppIntentsPackage by mangled symbol, which
# linkd resolves against the executable — impossible for a statically linked
# SwiftPM module, so its presence alone makes linkd discard the bundle's whole
# metadata (aggregateMetadataIsEmpty): no Shortcuts section, no widget
# configuration. Sources/ReachyWidgetUI/AGENTS.md has the story.
for package in target.rglob("extract.packagedata"):
    failures.append(
        f"{package}: an AppIntentsPackage conformance is back — linkd rejects "
        "all metadata over it (see Sources/ReachyWidgetUI/AGENTS.md)"
    )

if failures:
    print(f"App Intents metadata check FAILED for {target}:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)

data = json.loads(app_files[0].read_text())
print(
    f"App Intents metadata OK: {len(data['actions'])} actions, "
    f"{len(data['autoShortcuts'])} app shortcuts, "
    f"{checked_sizes} sized collection parameter(s)"
    + (f", appex metadata present ({len(appex_files)})" if appex_files else "")
)
PY

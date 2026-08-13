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
# Checked: the eight Shortcuts-facing intents and a non-empty `autoShortcuts`
# (the extracted ReachyShortcuts provider) in the app's own metadata, the
# widget configuration intent in the appex's (iOS only — that metadata is what
# the widget's Edit sheet is built from), and that no `extract.packagedata`
# exists anywhere — an AppIntentsPackage conformance emits one, and linkd
# rejects the bundle's entire metadata over it (aggregateMetadataIsEmpty).
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
]
REQUIRED_APPEX_ACTIONS = ["RobotAppsConfigurationIntent"]

metadata = list(target.rglob("extract.actionsdata"))
app_files = [p for p in metadata if not any(a.suffix == ".appex" for a in p.parents)]
appex_files = [p for p in metadata if p not in app_files]

failures = []

if len(app_files) != 1:
    failures.append(
        f"expected exactly one Metadata.appintents/extract.actionsdata in the app "
        f"bundle, found {len(app_files)}: {[str(p) for p in app_files]}"
    )
else:
    data = json.loads(app_files[0].read_text())
    actions = data.get("actions") or {}
    missing = [name for name in REQUIRED_APP_ACTIONS if name not in actions]
    if missing:
        failures.append(f"app metadata is missing actions: {missing} (has {sorted(actions)})")
    if not data.get("autoShortcuts"):
        failures.append("app metadata has no autoShortcuts — ReachyShortcuts was not extracted")

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
    f"{len(data['autoShortcuts'])} app shortcuts"
    + (f", appex metadata present ({len(appex_files)})" if appex_files else "")
)
PY

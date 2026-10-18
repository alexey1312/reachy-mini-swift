"""Temporary edits that let a launch argument choose the screen. Never commit them.

    python3 screenshots/visionos/navigate.py      # apply, from the repository root
    git checkout -- Sources/ReachyUI/Shell        # revert

Only for a Mac whose screen is locked, where Device Hub draws no window and nothing
can tap the simulator. With the screen unlocked, tap through the app instead and
skip this file: the screens are the same either way, because these edits only
navigate. They read `REACHY_SHOT` and select a tab, or push the Controller screen
onto the Live tab's own navigation stack, or pick Discover in the Apps tab.

The edits match the source text exactly, so a change to either file can stop them
applying; the assertion then names the file.
"""

import os


def sub(path, old, new):
    with open(path) as file:
        text = file.read()
    assert old in text, f"{path}: the text these edits expect has changed"
    with open(path, "w") as file:
        file.write(text.replace(old, new, 1))


shell = os.path.join("Sources", "ReachyUI", "Shell")
sub(os.path.join(shell, "ReachyTabShell.swift"), """        .tabViewStyle(.sidebarAdaptable)
""", """        .tabViewStyle(.sidebarAdaptable)
        .task { // SCREENSHOT NAVIGATION, never committed
            switch ProcessInfo.processInfo.environment["REACHY_SHOT"] {
            case "live", "controller": router.tab = .live
            case "moves": router.tab = .moves
            case "apps": router.tab = .apps
            case "discover": router.tab = .apps; store.section = .discover
            case "settings": router.tab = .settings
            default: break
            }
        }
""")
sub(os.path.join(shell, "LiveTab.swift"), """    var body: some View {
        @Bindable var router = router""", """    @State private var shotController = ProcessInfo.processInfo.environment["REACHY_SHOT"] == "controller"

    var body: some View {
        @Bindable var router = router""")
sub(os.path.join(shell, "LiveTab.swift"), """                .navigationTitle(.reachy("Live"))
""", """                .navigationTitle(.reachy("Live"))
                .navigationDestination(isPresented: $shotController) {
                    ControllerScreen(session: session, standDown: presence.teleopStandDown(session: session))
                }
""")
print("navigation edits applied; revert them before any commit")

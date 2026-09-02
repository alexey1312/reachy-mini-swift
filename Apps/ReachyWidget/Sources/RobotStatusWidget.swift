import ReachyDesign
import ReachyKit
import ReachyWidgetUI
import SwiftUI
import WidgetKit

struct RobotStatusEntry: TimelineEntry {
    let date: Date
    let content: RobotWidgetContent
    let layout: RobotWidgetView.Layout
}

/// Reads the snapshot the app left in the shared group. It cannot do anything
/// else: this process is woken for a moment, and a robot is reached over a
/// WebSocket or a peer connection that could not be opened, let alone settled,
/// inside that.
struct RobotStatusProvider: TimelineProvider {
    /// The one place the family is read. Everything below it takes a `Layout`, so
    /// the view stays renderable outside a widget.
    ///
    /// **Exhaustive rather than a ternary, and that is the whole point of this
    /// edit.** It used to read `family == .systemSmall ? .compact : .wide`, so
    /// every family this widget did not support fell through to the wide layout —
    /// which meant adding one silently rendered a 338 pt row inside a 76 pt ring.
    /// `default` is still needed (`WidgetFamily` grows on its own schedule) and
    /// answers `.wide`, which is the safe end of that mistake rather than the
    /// silent one: a family nobody declared cannot be installed.
    private func layout(for family: WidgetFamily) -> RobotWidgetView.Layout {
        switch family {
        case .systemSmall: .compact
        // The three accessory families are `@available(macOS, unavailable)`, so
        // naming them at all fails the Mac build rather than falling through.
        #if os(iOS)
            case .accessoryCircular: .circular
            case .accessoryRectangular: .rectangular
            case .accessoryInline: .inline
        #endif
        default: .wide
        }
    }

    func placeholder(in context: Context) -> RobotStatusEntry {
        RobotStatusEntry(
            date: .now,
            content: RobotWidgetContent(state: .unknown),
            layout: layout(for: context.family)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (RobotStatusEntry) -> Void) {
        completion(entry(at: .now, layout: layout(for: context.family)))
    }

    /// More than one entry, so the widget corrects itself while the app is not
    /// running to correct it: a reading stops being trustworthy, a transition that
    /// never came back stops saying "Waking up…", and a crash stops being news.
    /// Every moment comes from `RobotWidgetContent.refreshDates`, and each entry is
    /// rebuilt from the stores at that date rather than from a state guessed here.
    func getTimeline(in context: Context, completion: @escaping (Timeline<RobotStatusEntry>) -> Void) {
        let now = Date.now
        let layout = layout(for: context.family)
        var entries = [entry(at: now, layout: layout)]
        for moment in RobotWidgetContent.refreshDates(
            snapshot: RobotSnapshotStore().state(at: now),
            power: RobotPowerTransitionStore().current,
            after: now
        ) {
            entries.append(entry(at: moment, layout: layout))
        }
        // The app reloads timelines when it learns something, and so do the power
        // and app intents — this is only the floor for a phone that never opens it.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 60))))
    }

    private func entry(at date: Date, layout: RobotWidgetView.Layout) -> RobotStatusEntry {
        RobotStatusEntry(
            date: date,
            content: RobotWidgetContent(
                state: RobotSnapshotStore().state(at: date),
                power: RobotPowerTransitionStore().current,
                // The same store the apps widget reads, so the two agree on what is
                // installed; absent until the app has listed the robot's apps once.
                apps: RobotIntentTarget.knownRobot.flatMap { RobotAppsCacheStore().current(for: $0.key) },
                at: date
            ),
            layout: layout
        )
    }
}

struct RobotStatusWidget: Widget {
    /// Built up rather than written as one literal, because `#if` is not legal
    /// inside a container literal — it fails as "expected expression in container
    /// literal", which reads as a typo rather than as a grammar rule.
    private static var supportedFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium]
        #if os(iOS)
            families += [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
        return families
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ReachyWidgetKind.status, provider: RobotStatusProvider()) { entry in
            RobotWidgetView(content: entry.content, layout: entry.layout)
                .reachyTheme(ThemeStore(defaults: KnownRobots.defaults).theme)
                .containerBackground(.fill.tertiary, for: .widget)
                // Every pixel the action button does not claim. A `Button` carves
                // its own tap target out of this, so the rest of the widget still
                // opens the app — which is where a robot the intent cannot reach
                // is actually dealt with.
                .widgetURL(ReachyDeepLink.robot.url)
        }
        // The brand rather than the robot's model name, and for two reasons that
        // both point the same way. The gallery's search matches a widget's own name,
        // so "Reachy Mini" left the word "Hey" absent from every string this
        // extension publishes — the app was findable there and its widgets were not.
        // And "Reachy Mini" is what Pollen's own app is called, which is the exact
        // ambiguity `INAlternativeAppNames` in `Project.swift` refuses for the same
        // reason: on a phone carrying both, this row named the other one.
        .configurationDisplayName("Hey Reachy Status")
        .description("Your robot's last known state.")
        // The three accessory families put the robot on the Lock Screen and in
        // StandBy, which is where a reading nobody has to unlock for belongs. The
        // Mac has neither surface and the SDK says so, so it gets the two system
        // families only.
        // Nothing here is under snapshot cover: previews render `RobotWidgetView`
        // directly, so this list is exercised by installing the widget and by
        // nothing else.
        .supportedFamilies(Self.supportedFamilies)
    }
}

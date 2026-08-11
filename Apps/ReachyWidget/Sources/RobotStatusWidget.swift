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
    private func layout(for family: WidgetFamily) -> RobotWidgetView.Layout {
        family == .systemSmall ? .compact : .wide
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
                at: date
            ),
            layout: layout
        )
    }
}

struct RobotStatusWidget: Widget {
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

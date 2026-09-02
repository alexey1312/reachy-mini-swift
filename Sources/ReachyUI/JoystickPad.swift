import ReachyDesign
import SwiftUI

/// 2D touch pad emitting a normalized deflection; snaps back to center on release.
///
/// The pad is banded rather than marked: the middle is head yaw, and the slice past
/// `mapping.rotationThreshold` on either side is where the body turns. That slice is
/// shaded whole — a push into its top or bottom corner turns the robot exactly as a
/// level one does — and it lights up, with a haptic tick, when the knob enters it. It
/// used to be a pair of short arcs at the left and right of the rim, which drew a
/// third of the area the zone actually covered and taught the reader to aim level.
/// The pad only reports where the knob is; turning that into head pose or body
/// rotation is `TeleopDriver`'s job.
struct JoystickPad: View {
    var mapping: JoystickMapping
    var onChange: (JoystickDeflection) -> Void

    @State private var deflection: JoystickDeflection
    /// Scaled with the reader's text: a knob that stays 56 pt under a larger caption
    /// is the one thing on the screen that did not grow.
    @ScaledMetric(relativeTo: .body) private var knob = Metrics.joystickKnob

    init(
        mapping: JoystickMapping = JoystickMapping(),
        deflection: JoystickDeflection = .zero,
        onChange: @escaping (JoystickDeflection) -> Void
    ) {
        self.mapping = mapping
        self.onChange = onChange
        _deflection = State(initialValue: deflection)
    }

    private var rotationSide: JoystickRotationSide? {
        mapping.rotationSide(deflection)
    }

    private static let arrowKeys: Set<KeyEquivalent> = [.leftArrow, .rightArrow, .upArrow, .downArrow]

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2
            pad(radius: radius)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Circle())
                .gesture(drag(radius: radius))
        }
        .aspectRatio(1, contentMode: .fit)
        .sensoryFeedback(.impact, trigger: rotationSide)
        .overlay { accessibilityProxies }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(.reachy("Head joystick"))
        .focusable()
        .onKeyPress(keys: Self.arrowKeys, phases: [.down, .up], action: handle)
    }

    private func pad(radius: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.quaternary.opacity(0.3))
            Circle()
                .strokeBorder(.tertiary, lineWidth: 1)
            rotationZone(.left)
            rotationZone(.right)
            Circle()
                .fill(.tint)
                .frame(width: knob, height: knob)
                .offset(x: CGFloat(deflection.x) * radius, y: CGFloat(deflection.y) * radius)
        }
    }

    private func drag(radius: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                deflection = JoystickDeflection(
                    x: Double(value.translation.width / radius).clamped(to: -1 ... 1),
                    y: Double(value.translation.height / radius).clamped(to: -1 ... 1)
                )
                onChange(deflection)
            }
            .onEnded { _ in recentre() }
    }

    // MARK: - Keyboard and VoiceOver

    /// An arrow key holds the pad at full deflection on its axis for as long as it
    /// is down — the keyboard's version of a thumb against the rim — and lets go on
    /// key-up, which is the same snap-back a finger gets. Repeats are not listened
    /// for: a held key is already at the rim.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let down = press.phase == .down
        var next = deflection
        switch press.key {
        case .leftArrow: next.x = down ? -1 : 0
        case .rightArrow: next.x = down ? 1 : 0
        case .upArrow: next.y = down ? -1 : 0
        case .downArrow: next.y = down ? 1 : 0
        default: return .ignored
        }
        move(to: next)
        return .handled
    }

    /// VoiceOver gets one adjustable element per axis. The pad itself is a container,
    /// so the two are found by swiping rather than by aiming at the knob, and each
    /// step is a tenth of the travel — coarse enough to hear, fine enough to aim.
    private var accessibilityProxies: some View {
        HStack(spacing: 0) {
            axisProxy(.horizontal, label: .reachy("Head yaw"), value: yawValue)
            axisProxy(.vertical, label: .reachy("Head pitch"), value: pitchValue)
        }
    }

    private func axisProxy(_ axis: Axis, label: LocalizedStringResource, value: String) -> some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAdjustableAction { direction in
                nudge(axis, by: direction == .increment ? 0.1 : -0.1)
            }
            .accessibilityAction(named: Text(.reachy("Reset to neutral"))) { recentre() }
    }

    /// The yaw the head is sent, and — past the threshold — that the body is
    /// turning, which the pad otherwise says only with a shaded slice.
    private var yawValue: String {
        let degrees = Self.degrees(mapping.headYaw(deflection))
        return switch rotationSide {
        case .left: String(localized: .reachy("\(degrees), turning left"))
        case .right: String(localized: .reachy("\(degrees), turning right"))
        case nil: degrees
        }
    }

    private var pitchValue: String {
        Self.degrees(mapping.headPitch(deflection))
    }

    private static func degrees(_ radians: Double) -> String {
        String(format: "%.0f°", radians * 180 / .pi)
    }

    private func nudge(_ axis: Axis, by delta: Double) {
        var next = deflection
        switch axis {
        case .horizontal: next.x = (next.x + delta).clamped(to: -1 ... 1)
        case .vertical: next.y = (next.y + delta).clamped(to: -1 ... 1)
        }
        move(to: next)
    }

    private func move(to next: JoystickDeflection) {
        if next == .zero {
            recentre()
        } else {
            deflection = next
            onChange(next)
        }
    }

    private func recentre() {
        withAnimation(.snappy) { deflection = .zero }
        onChange(.zero)
    }

    /// Where the body turns. Shaded at rest so its extent is legible before a finger
    /// is anywhere near it, lit while the knob is inside it. Drawn over the pad's own
    /// border, so the lit state reaches the rim.
    private func rotationZone(_ side: JoystickRotationSide) -> some View {
        let zone = RotationZone(side: side, threshold: mapping.rotationThreshold)
        let isActive = rotationSide == side
        return ZStack {
            zone
                .fill(isActive ? Tone.brand.style : AnyShapeStyle(.quaternary))
                .opacity(isActive ? 0.3 : 0.45)
            // The brand colour at rest too, faintly: a grey chord read as a
            // rendering seam rather than as the edge of a zone.
            zone
                .strokeBorder(Tone.brand.style, lineWidth: 1)
                .opacity(isActive ? 1 : 0.35)
        }
    }
}

/// The slice of the pad past the head zone: the disc, cut by the vertical chord at
/// `±threshold` of its radius, which is exactly where `JoystickMapping` starts turning
/// the body.
///
/// Built by intersecting the disc with a half-plane rather than by sweeping an arc:
/// `addArc` would have to be handed the right winding for a y-down space to cut off
/// the near side rather than the far one, and an intersection is correct by
/// construction — the shading cannot drift away from the mapping's boundary.
private struct RotationZone: InsettableShape {
    var side: JoystickRotationSide
    /// Where the chord sits, as a fraction of the pad's radius.
    var threshold: Double
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - inset
        guard radius > 0 else { return Path() }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let disc = Path(
            ellipseIn: CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        let direction: CGFloat = side == .right ? 1 : -1
        let chord = centre.x + direction * CGFloat(threshold.clamped(to: 0 ... 1)) * radius
        let halfPlane = CGRect(
            x: side == .right ? chord : chord - radius * 2,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        return disc.intersection(Path(halfPlane))
    }

    func inset(by amount: CGFloat) -> RotationZone {
        var copy = self
        copy.inset += amount
        return copy
    }
}

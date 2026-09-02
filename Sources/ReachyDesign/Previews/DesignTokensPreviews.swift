import ReachyDesign
import SwiftUI

// Every gallery is a component, not a screen, so each opts out of Prefire's
// default `.device` trait. `Motion` has no preview: an animation captured on its
// first frame is indistinguishable from no animation at all.

#Preview("Design — space", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "Space") {
        ForEach(DesignGallery.space) { token in
            TokenRow(name: token.name, value: "\(Int(token.value))") {
                Capsule()
                    .fill(Tone.brand.style)
                    .frame(width: token.value, height: 14)
            }
        }
    }
}

#Preview("Design — radius", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "Radius") {
        ForEach(DesignGallery.radius) { token in
            TokenRow(name: token.name, value: "\(Int(token.value))") {
                Radius.rect(token.value)
                    .fill(Tone.brand.style)
                    .frame(width: 72, height: 44)
            }
        }
        TokenRow(name: "tile(side:)", value: "side / 4.5") {
            HStack(spacing: Space.sm) {
                ForEach([Metrics.artworkCompact, Metrics.artwork], id: \.self) { side in
                    Radius.rect(Radius.tile(side: side))
                        .fill(Tone.brand.style)
                        .frame(width: side, height: side)
                }
            }
        }
    }
}

#Preview("Design — tone", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "Tone") {
        ForEach(Tone.allCases, id: \.self) { tone in
            TokenRow(name: DesignGallery.name(of: tone), value: "") {
                Capsule()
                    .fill(tone.style)
                    .frame(width: 96, height: 22)
            }
        }
    }
}

#Preview("Design — typography", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "Typography") {
        ForEach(DesignGallery.typography, id: \.name) { role in
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Text(role.name)
                    .font(Typography.consoleLine)
                    .foregroundStyle(Tone.quiet.style)
                    .frame(width: 120, alignment: .leading)
                Text("Reachy Mini")
                    .font(role.font)
                Spacer(minLength: Space.sm)
            }
        }
    }
}

#Preview("Design — metrics", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "Metrics") {
        ForEach(DesignGallery.metrics) { token in
            TokenRow(name: token.name, value: "\(Int(token.value))") {
                Radius.rect(Radius.xs)
                    .fill(Tone.quiet.style)
                    .frame(width: token.value, height: min(token.value, 28))
            }
        }
        TokenRow(name: "readableForm", value: "\(Int(Metrics.readableForm))") {
            Color.clear.frame(width: 1, height: 20)
        }
    }
}

#Preview("Design — status", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "StatusTone") {
        ForEach(StatusTone.allCases, id: \.self) { tone in
            TokenRow(name: DesignGallery.name(of: tone), value: "") {
                ReachyStatusLabel(text: DesignGallery.caption(for: tone), tone: tone)
            }
        }
        TokenRow(name: "statusCompact", value: "") {
            ReachyStatusLabel(text: "Failed", tone: .failed, font: Typography.statusCompact, lineLimit: 1)
        }
    }
}

// One caller today — the store's Update capsule — so the gallery varies the tone
// over that same word rather than inventing labels the app does not use. What the
// row shows is that the colour lives in the *text*: the capsule under it is the
// `.badge` surface, the same for every tone.
#Preview("Design — badge", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "ReachyBadge") {
        ForEach(Tone.allCases, id: \.self) { tone in
            TokenRow(name: DesignGallery.name(of: tone), value: "") {
                ReachyBadge("Update", tone: tone)
            }
        }
    }
}

// `reachyButton` had fourteen call sites and no capture at all until a third tier
// was added for the connection rail's decisions. The row carries one long label and
// one short one because that is what the tiers are for: `prominent` and `standard`
// draw a capsule around whatever they are given, so a long label makes them wide,
// while `quiet` carries no width of its own — which is the property that let three
// actions share a line instead of stacking into a ragged column.
#Preview("Design — buttons", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "ButtonEmphasis") {
        ForEach(ButtonEmphasis.allCases, id: \.self) { emphasis in
            TokenRow(name: DesignGallery.name(of: emphasis), value: "") {
                HStack(spacing: Space.sm) {
                    ReachyActionButton("Start robot backend", emphasis: emphasis) {}
                    ReachyActionButton("Cancel", emphasis: emphasis) {}
                }
            }
        }
        // The width goes on the label, which is the whole of what the helper adds
        // over `reachyButton`: the capsule fills the row instead of hugging its text.
        TokenRow(name: "prominent, fullWidth", value: "") {
            ReachyActionButton("Start robot backend", fullWidth: true) {}
        }
    }
}

// One failure row, with and without a way out. The text is `Typography.status`
// on purpose — the console role stays with tracebacks.
#Preview("Design — error row", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "ReachyErrorRow") {
        ReachyErrorRow("Could not connect to the server.") {}
        ReachyErrorRow("The robot did not say why.")
    }
}

// The effect layer is absent from this capture — neither glass nor a material
// renders headless. What it does prove is the rule that makes the rest of the
// suite worth having: each role's opaque fill covers the gradient behind it.
#Preview("Design — surfaces", traits: .sizeThatFitsLayout) {
    TokenGallery(title: "SurfaceRole") {
        ForEach(SurfaceRole.allCases, id: \.self) { role in
            Text(DesignGallery.name(of: role))
                .font(Typography.status)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .reachySurface(role, in: .capsule)
        }
    }
    .background { GalleryBackdrop() }
}

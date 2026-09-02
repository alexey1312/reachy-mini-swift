import HuggingFaceAuth
import ReachyDesign
import SwiftUI

/// The Hugging Face account, in the leading slot of the navigation bar.
///
/// It lived in Settings, which is a robot's screen — and the account is not a
/// robot's. It outlives every connection, and it is needed *before* one: signing
/// in is what makes the list of remote robots exist at all, so burying it behind
/// a robot that has not been reached yet put it exactly where it could not be
/// found.
struct HFAccountToolbarButton: View {
    /// **The avatar matches what a toolbar symbol measures, and that is the whole
    /// fix for the shape.** The signed-out state puts a bare `person.crop.circle`
    /// here and renders correctly, because a toolbar sizes its chrome around a
    /// symbol — measured at **15 × 15** at the default font. The avatar was 26,
    /// 73% larger, so signing in grew the item's glass into a shape neither round
    /// nor a capsule. Two attempts at the *shape* (`buttonBorderShape(.circle)`,
    /// then `buttonStyle(.plain)`) each moved it and neither settled it, because
    /// what disagrees is the content's size. A literal rather than a `Metrics`
    /// token: it is optical parity with a number the system chose, not a rhythm of
    /// ours, and it moves when Apple moves theirs.
    private static let glyphSize: CGFloat = 16

    let action: () -> Void

    /// Optional for the same reason `SettingsScreen` reads it that way: the
    /// non-optional form traps where nothing was injected, and a host without a
    /// Hugging Face session should simply not show the control.
    @Environment(HFAccount.self) private var account: HFAccount?

    var body: some View {
        if let account {
            Button(action: action) {
                label(for: account.state)
            }
            .accessibilityLabel(accessibilityLabel(for: account.state))
            .help(accessibilityLabel(for: account.state))
        }
    }

    @ViewBuilder
    private func label(for state: HFAccount.State) -> some View {
        switch state {
        case .signedOut, .failed:
            Label(.reachy("Account"), systemImage: "person.crop.circle")
        case .signingIn:
            ProgressView().controlSize(.small)
        case let .signedIn(username):
            HFAvatar(username: username, size: Self.glyphSize)
        case let .needsReauth(username):
            // The session lapsed and cannot be renewed silently, which is worth
            // seeing before the next thing that needs it fails.
            HFAvatar(username: username ?? "?", size: Self.glyphSize)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "exclamationmark.circle.fill")
                        // Optical: sized against the avatar it is pinned to, not against the text.
                        // swiftlint:disable:next raw_font
                        .font(.caption2)
                        .foregroundStyle(Tone.warning.style)
                        .background(.background, in: .circle)
                }
        }
    }

    private func accessibilityLabel(for state: HFAccount.State) -> String {
        switch state {
        case .signedOut, .failed: String(localized: .reachy("Sign in to Hugging Face"))
        case .signingIn: String(localized: .reachy("Signing in to Hugging Face"))
        case let .signedIn(username): String(localized: .reachy("Hugging Face account: \(username)"))
        case .needsReauth: String(localized: .reachy("Hugging Face session expired"))
        }
    }
}

extension View {
    /// Puts the account button in the leading slot of whatever navigation bar this
    /// view has.
    ///
    /// The placement is spelled out per platform because `.topBarLeading` is
    /// `@available(macOS, unavailable)`; `.navigation` is its counterpart there.
    /// Every other toolbar in this package leaves the placement to `.automatic`,
    /// which resolves trailing — that is where Settings already sits, and this has
    /// to be the other side of it.
    func hfAccountToolbar(isPresented: Binding<Bool>) -> some View {
        toolbar {
            #if os(macOS)
                ToolbarItem(placement: .navigation) {
                    HFAccountToolbarButton { isPresented.wrappedValue = true }
                }
            #else
                ToolbarItem(placement: .topBarLeading) {
                    HFAccountToolbarButton { isPresented.wrappedValue = true }
                }
            #endif
        }
    }
}

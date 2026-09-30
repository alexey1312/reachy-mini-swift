import SwiftUI

/// The way to a review that needs no prompt and spends no quota.
///
/// The system prompt appears when StoreKit allows it, at most three times a year,
/// and never on request; a row that is always here is what Apple suggests beside
/// it. It opens the product page with its review sheet already up.
struct RateAppSection: View {
    var body: some View {
        Section {
            Link(destination: ReviewPrompt.writeReviewURL) {
                Label(.reachy("Rate on the App Store"), systemImage: "star")
            }
        }
    }
}

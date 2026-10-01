import Foundation

/// A Hugging Face Space's own page, and the Hub's report form for it — the two
/// links both app catalogues hand a reader about somebody else's app
/// (App Review guideline 1.2; `docs/adr/0006-js-apps.md`, decision 4).
///
/// One builder for both catalogues: a Python app's card and a web app's entry name
/// the same kind of thing by the same `owner/name` id, and two copies of a URL are
/// two places to get rule 5 wrong.
public enum HubSpacePage {
    /// `https://huggingface.co/spaces/<owner>/<name>` — the README, the author and
    /// the community tab.
    public static func url(for spaceID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/spaces/\(spaceID)"
        return components.url
    }

    /// The same page with the Hub's report dialog open on arrival, which is what
    /// upstream's "Report this app" opens. The report goes to Hugging Face's own
    /// moderation; nothing of this app's is in the loop, and nothing needs to be.
    public static func reportURL(for spaceID: String) -> URL? {
        guard let page = url(for: spaceID),
              var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "report", value: "true")]
        return components.url
    }
}

public extension RobotApp {
    /// Nil for an installed app whose metadata the daemon lost: with no Space id
    /// there is no page to point at, and a guess from the entry point would point
    /// at somebody else's.
    var spaceURL: URL? {
        spaceID.flatMap(HubSpacePage.url(for:))
    }

    var reportURL: URL? {
        spaceID.flatMap(HubSpacePage.reportURL(for:))
    }
}

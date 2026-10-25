import ActivityKit
import Foundation

/// Shared by the app and the Live Activity extension. The extension never talks to the
/// server or reads the session file: everything it shows arrives in ContentState (spec §13.4).
struct NigeyoActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Layout: String, Codable, Hashable, Sendable {
            case protect, checks, tsunami
        }

        var layout: Layout
        var hazard: String
        var phase: String
        var stateRevision: Int
        /// Pictogram asset names (protect-head, check-surroundings, …), shared by every language.
        var pictograms: [String]
        /// Headline for protect/tsunami; one short label per pictogram for checks.
        var headline: String
        var labels: [String]
        var buttonTitle: String
        /// Localized training badge; nil for manual guidance.
        var badge: String?
        var compactLabel: String
        var appName: String
        /// False only for the onboarding test activity, where the button must not change state.
        var interactive: Bool
    }

    var sessionId: String
}

enum NigeyoDeepLink {
    static func evacuation(sessionId: String) -> URL {
        var c = URLComponents()
        c.scheme = "nigeyo"
        c.host = "evacuation"
        c.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]
        return c.url!
    }
}

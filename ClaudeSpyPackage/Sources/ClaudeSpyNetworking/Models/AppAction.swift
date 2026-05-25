import Foundation

// MARK: - App Action

/// Discrete Mac-side feature triggers a plugin sidecar wants to fire. Closed
/// enum of app-known actions; new actions are added as a coordinated app +
/// plugin change. AppActions are intentionally agent-blind.
///
/// Encoded on the wire as `{ "type": <case>, ...associated values }` with
/// snake_case discriminator values (`"open_file_suggestion"`,
/// `"dismiss_file_suggestions"`, `"close_pane_if_preference_allows"`).
public enum AppAction: Codable, Sendable, Equatable {
    /// Surface an "open this file?" suggestion in the pane's UI.
    /// Used by the existing markdown-write feature.
    case openFileSuggestion(sessionId: String, path: String, displayName: String, isPlan: Bool)

    /// Dismiss any outstanding file-open suggestions for this session.
    /// Emitted when the user submits a new prompt (suggestion is no longer
    /// relevant).
    case dismissFileSuggestions(sessionId: String)

    /// Close the tmux pane backing this session IF the user has the
    /// `closePaneOnSessionEnd` preference enabled. App reads the pref;
    /// sidecar just emits the intent. The sidecar emits this on session-end
    /// events; whether the close actually happens is the app's decision.
    case closePaneIfPreferenceAllows(sessionId: String)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case path
        case displayName
        case isPlan
    }

    private enum ActionType: String, Codable {
        case openFileSuggestion = "open_file_suggestion"
        case dismissFileSuggestions = "dismiss_file_suggestions"
        case closePaneIfPreferenceAllows = "close_pane_if_preference_allows"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ActionType.self, forKey: .type)

        switch type {
        case .openFileSuggestion:
            let sessionId = try container.decode(String.self, forKey: .sessionId)
            let path = try container.decode(String.self, forKey: .path)
            let displayName = try container.decode(String.self, forKey: .displayName)
            let isPlan = try container.decode(Bool.self, forKey: .isPlan)
            self = .openFileSuggestion(
                sessionId: sessionId,
                path: path,
                displayName: displayName,
                isPlan: isPlan
            )
        case .dismissFileSuggestions:
            let sessionId = try container.decode(String.self, forKey: .sessionId)
            self = .dismissFileSuggestions(sessionId: sessionId)
        case .closePaneIfPreferenceAllows:
            let sessionId = try container.decode(String.self, forKey: .sessionId)
            self = .closePaneIfPreferenceAllows(sessionId: sessionId)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .openFileSuggestion(sessionId, path, displayName, isPlan):
            try container.encode(ActionType.openFileSuggestion, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(path, forKey: .path)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(isPlan, forKey: .isPlan)
        case let .dismissFileSuggestions(sessionId):
            try container.encode(ActionType.dismissFileSuggestions, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
        case let .closePaneIfPreferenceAllows(sessionId):
            try container.encode(ActionType.closePaneIfPreferenceAllows, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
        }
    }
}

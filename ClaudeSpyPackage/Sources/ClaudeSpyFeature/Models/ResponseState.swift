import ClaudeSpyNetworking
import Foundation
import SwiftUI

/// Manages the state of an event response (permission request, prompt, etc.)
/// This allows response state to be shared between ClaudeSessionTerminalView and LiveTerminalView.
/// Responses are persisted to SessionStore so they survive navigation.
@MainActor
@Observable
final public class ResponseState {
    /// The event this response is for
    public let event: HookEvent

    /// Whether a command is currently being sent
    public var isSending = false

    /// Reference to the session store for persistence
    private weak var sessionStore: SessionStore?

    /// Flag to prevent didSet from persisting during initialization
    private var isInitialized = false

    /// The user's response, if they've responded.
    /// Setting this persists the response to SessionStore.
    public var response: ResponseType? {
        didSet {
            guard isInitialized else { return }
            sessionStore?.setResponse(response, for: event.id)
        }
    }

    public init(event: HookEvent, sessionStore: SessionStore? = nil) {
        self.event = event
        self.sessionStore = sessionStore
        // Restore any existing response from the store.
        // isInitialized is false, so didSet won't trigger @Observable mutations.
        self.response = sessionStore?.response(for: event.id)
        self.isInitialized = true
    }
}

/// Represents the type of response given
public enum ResponseType: Equatable {
    case accepted
    case acceptedWithSuggestion
    case rejected
    case customInstructions(String)
    /// Used when all questions have been answered
    case allQuestionsAnswered

    public var feedbackMessage: String {
        switch self {
        case .accepted:
            "Permission accepted"
        case .acceptedWithSuggestion:
            "Permission accepted with suggestion"
        case .rejected:
            "Permission rejected"
        case let .customInstructions(text):
            "Sent: \(text)"
        case .allQuestionsAnswered:
            "All questions answered"
        }
    }

    public var feedbackColor: Color {
        switch self {
        case .accepted,
             .acceptedWithSuggestion,
             .allQuestionsAnswered:
            .green
        case .rejected:
            .red
        case .customInstructions:
            .blue
        }
    }
}

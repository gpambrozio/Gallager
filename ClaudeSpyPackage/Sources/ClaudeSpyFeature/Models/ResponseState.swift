import ClaudeSpyNetworking
import Foundation
import SwiftUI

/// Manages the state of an event response (permission request, prompt, etc.)
/// This allows response state to be shared between SessionDetailView and TerminalSnapshotView.
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

    /// The user's response, if they've responded.
    /// Setting this persists the response to SessionStore.
    public var response: ResponseType? {
        didSet {
            sessionStore?.setResponse(response, for: event.id)
        }
    }

    public init(event: HookEvent, sessionStore: SessionStore? = nil) {
        self.event = event
        self.sessionStore = sessionStore
        // Restore any existing response from the store
        self.response = sessionStore?.response(for: event.id)
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

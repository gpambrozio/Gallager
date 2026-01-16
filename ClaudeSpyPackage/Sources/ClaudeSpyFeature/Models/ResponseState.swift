import ClaudeSpyNetworking
import Foundation
import SwiftUI

/// Manages the state of an event response (permission request, prompt, etc.)
/// This allows response state to be shared between SessionDetailView and TerminalSnapshotView
@MainActor
@Observable
final public class ResponseState {
    /// The event this response is for
    public let event: HookEvent

    /// Whether a command is currently being sent
    public var isSending = false

    /// The user's response, if they've responded
    public var response: ResponseType?

    public init(event: HookEvent) {
        self.event = event
    }
}

/// Represents the type of response given
public enum ResponseType {
    case accepted
    case acceptedWithSuggestion
    case rejected
    case customInstructions(String)
    /// Used when an answer has been submitted for one question in a multi-question sequence
    case questionAnswered(questionIndex: Int, selectedOptions: Set<Int>)
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
        case let .questionAnswered(index, _):
            "Answered question \(index + 1)"
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
        case .customInstructions,
             .questionAnswered:
            .blue
        }
    }
}

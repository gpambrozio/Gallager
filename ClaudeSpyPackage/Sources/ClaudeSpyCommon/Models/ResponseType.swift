import SwiftUI

/// Represents the type of response given to a Claude Code event
public enum ResponseType: Equatable {
    case accepted
    case acceptedWithSuggestion
    case rejected
    case customInstructions(String)
    /// Used when all questions have been answered
    case allQuestionsAnswered
    /// Used when a prompt message has been submitted
    case promptSubmitted

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
        case .promptSubmitted:
            "Prompt submitted"
        }
    }

    public var feedbackColor: Color {
        switch self {
        case .accepted,
             .acceptedWithSuggestion,
             .allQuestionsAnswered,
             .promptSubmitted:
            .green
        case .rejected:
            .red
        case .customInstructions:
            .blue
        }
    }
}

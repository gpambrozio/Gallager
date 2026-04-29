import ClaudeSpyNetworking
import SwiftUI

/// Visual indicator for a Claude session's current state:
/// - Needs attention: orange bell badge
/// - Working: spinning progress indicator
/// - Idle: gray moon
public struct SessionStatusIndicator: View {
    private enum DisplayState {
        case attention
        case working
        case idle
    }

    private let displayState: DisplayState
    private let label: String

    public init(session: ClaudeSession) {
        if session.needsAttention {
            self.displayState = .attention
        } else if session.isWorking {
            self.displayState = .working
        } else {
            self.displayState = .idle
        }
        self.label = session.statusLabel
    }

    public init(cliState: CLISessionState) {
        switch cliState {
        case .working: self.displayState = .working
        case .idle: self.displayState = .idle
        case .waiting: self.displayState = .attention
        }
        self.label = cliState.statusLabel
    }

    public var body: some View {
        Group {
            switch displayState {
            case .attention:
                Symbols.bellBadgeFill.image
                    .foregroundStyle(.orange)
            case .working:
                ProgressView()
                    .controlSize(.small)
            case .idle:
                Symbols.moonFill.image
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(label)
    }
}

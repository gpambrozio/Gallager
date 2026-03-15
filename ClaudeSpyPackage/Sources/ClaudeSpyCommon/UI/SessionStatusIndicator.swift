import ClaudeSpyNetworking
import SwiftUI

/// Visual indicator for a Claude session's current state:
/// - Needs attention: orange bell badge
/// - Working: spinning progress indicator
/// - Idle: gray moon
public struct SessionStatusIndicator: View {
    let session: ClaudeSession

    public init(session: ClaudeSession) {
        self.session = session
    }

    public var body: some View {
        Group {
            if session.needsAttention {
                Symbols.bellBadgeFill.image
                    .foregroundStyle(.orange)
            } else if session.isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Symbols.moonFill.image
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(session.statusLabel)
    }
}

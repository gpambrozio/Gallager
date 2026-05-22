import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Vertical status icon + emoji badge stack used at the leading edge of every
/// session sidebar row. The icon prioritises a CLI-driven state override, then
/// a Claude session indicator, then a plain terminal glyph for non-Claude
/// panes. The emoji badge appears underneath whenever the user has set one.
struct SessionStatusBadge: View {
    let cliSessionState: CLISessionState?
    let claudeSession: ClaudeSession?
    let customEmoji: String?

    var body: some View {
        VStack(spacing: 8) {
            if let cliSessionState {
                SessionStatusIndicator(cliState: cliSessionState)
                    .font(.system(size: 16))
            } else if let claudeSession {
                SessionStatusIndicator(session: claudeSession)
                    .font(.system(size: 16))
            } else {
                Symbols.terminal.image
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }

            if let customEmoji {
                SessionEmojiBadge(emoji: customEmoji)
                    .font(.system(size: 14))
            }
        }
        .frame(width: 20)
    }
}

/// Invisible AX overlay used by session sidebar rows. Exposes the session
/// status and project name as their own accessibility leaves so that even when
/// the surrounding `Button` collapses its children into a single
/// `AXBusyIndicator`/combined label (e.g. while a ProgressView is animating),
/// e2e tests and VoiceOver can still find them.
struct SessionAccessibilityOverlay: View {
    let status: String?
    let projectName: String?

    var body: some View {
        ZStack {
            if let status {
                Text(status)
                    .accessibilityLabel(status)
            }
            if let projectName {
                Text(projectName)
                    .accessibilityLabel(projectName)
            }
        }
        .font(.system(size: 1))
        .opacity(0)
    }
}

/// AX-only child injected via `.accessibilityChildren` on the session button.
/// When the button row contains a "Working" ProgressView, SwiftUI flips the
/// merged button to `AXBusyIndicator` and swallows the inner
/// `TerminalProgressBar`'s accessibility element. This sibling stays outside
/// that merge so `valueContains("60%")` queries (and VoiceOver) keep working.
struct SessionProgressAccessibilityProxy: View {
    let progress: TerminalProgressState?

    var body: some View {
        if let progress {
            Text("Terminal progress")
                .accessibilityLabel("Terminal progress")
                .accessibilityValue(progress.accessibilityValueString)
        }
    }
}

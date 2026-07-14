import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Identifies the local session whose info sheet is open. Wraps the agent
/// pane id so `.sheet(item:)` can drive presentation (and so the sheet always
/// re-reads the freshest `PaneState`).
struct SessionInfoSheetTarget: Identifiable {
    /// The agent pane id, used both as the sheet identity and the lookup key
    /// into `MirrorWindowManager.paneStates`.
    let id: String
}

/// The macOS "Session Info" sheet — the desktop counterpart to the iOS detail
/// popover. Right-clicking a local session and choosing "Session Info" presents
/// this; it renders the shared ``SessionInfoView`` (recap card, identity, OTEL
/// usage breakdown) with a title bar + Done button for the windowed context.
///
/// State is read live from `windowManager.paneStates[paneId]`, so tokens, cost,
/// and the recap keep updating while the sheet stays open. If the pane ends
/// while open, ``SessionInfoView`` falls back to its "Session Not Found" state.
struct LocalSessionInfoSheet: View {
    @Environment(MirrorWindowManager.self) private var windowManager

    let paneId: String
    let onDone: () -> Void

    private var paneState: PaneState? {
        windowManager.paneStates[paneId]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session Info")
                    .font(.headline)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            SessionInfoView(
                session: paneState?.agentSession,
                paneId: paneId,
                isPaneActive: paneState?.isActive ?? false,
                telemetry: paneState?.telemetry,
                permissionMode: paneState?.permissionMode,
                permissionModeTrigger: paneState?.permissionModeTrigger,
                recap: paneState?.recap
            )
        }
        .frame(width: 380, height: 480)
        .accessibilityIdentifier("session-info-sheet")
    }
}

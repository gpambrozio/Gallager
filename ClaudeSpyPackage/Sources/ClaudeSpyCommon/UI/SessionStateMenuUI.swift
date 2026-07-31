import ClaudeSpyNetworking
import SwiftUI

/// Context menu items for manually setting a session's state, plus an
/// "Automatic" action that clears the override.
///
/// Designed to live inside another `.contextMenu { }` (mirrors
/// ``ColorContextMenuButtons``); renders a "Set State" submenu listing the
/// selectable states with a checkmark next to the one currently shown on the
/// sidebar.
///
/// The chosen state is stored as a manual override that wins over the
/// agent-driven state on the sidebar, but any later plugin state update clears
/// it (see `MirrorWindowManager.applyState`) — so a live agent always overrides
/// the manual choice (issue #695).
public struct StateContextMenuButtons: View {
    /// The state currently shown on the sidebar (override, else agent-derived),
    /// used to check the matching item. `nil` = plain terminal (nothing checked).
    let currentState: CLISessionState?
    /// Whether a manual override is currently set — controls whether the
    /// "Automatic" (clear) action is offered, mirroring "Clear Color".
    let hasOverride: Bool
    let isDisabled: Bool
    let onSetState: (CLISessionState?) -> Void

    public init(
        currentState: CLISessionState?,
        hasOverride: Bool,
        isDisabled: Bool = false,
        onSetState: @escaping (CLISessionState?) -> Void
    ) {
        self.currentState = currentState
        self.hasOverride = hasOverride
        self.isDisabled = isDisabled
        self.onSetState = onSetState
    }

    public var body: some View {
        Menu {
            ForEach(CLISessionState.allCases, id: \.self) { state in
                Button {
                    onSetState(state)
                } label: {
                    if state == currentState {
                        Label(state.statusLabel, symbol: .checkmark)
                    } else {
                        Text(state.statusLabel)
                    }
                }
                .disabled(isDisabled)
            }

            if hasOverride {
                Divider()

                Button {
                    onSetState(nil)
                } label: {
                    Label("Automatic", symbol: .arrowClockwise)
                }
                .disabled(isDisabled)
            }
        } label: {
            Label("Set State", symbol: .circleLefthalfFilled)
        }
        .disabled(isDisabled)
    }
}

#Preview("Automatic (agent working)") {
    Form {
        StateContextMenuButtons(currentState: .working, hasOverride: false) { _ in }
    }
    .frame(width: 280, height: 120)
}

#Preview("Manual override set") {
    Form {
        StateContextMenuButtons(currentState: .waiting, hasOverride: true) { _ in }
    }
    .frame(width: 280, height: 160)
}

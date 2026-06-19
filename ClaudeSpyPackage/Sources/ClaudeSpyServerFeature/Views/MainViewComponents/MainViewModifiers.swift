import ClaudeSpyCommon
import SwiftUI

/// Bundles the global menu-driven notification observers used by the panes
/// scene (Cmd-N, Cmd-Shift-F, Cmd-Shift-[, Cmd-Shift-]) so the main `body`
/// chain stays under the Swift type checker's complexity threshold. Cmd-W
/// routes through the scene-scoped `closeCurrentTabAction` focused value
/// instead — see `MenuCommandFocusedValues.swift`.
struct MenuCommandsModifier: ViewModifier {
    let onOpenContentSearch: () -> Void
    let onSelectPreviousTab: () -> Void
    let onSelectNextTab: () -> Void
    let onNewLocalSession: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openContentSearch)) { _ in
                onOpenContentSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectPreviousTab)) { _ in
                onSelectPreviousTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectNextTab)) { _ in
                onSelectNextTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newLocalSession)) { _ in
                onNewLocalSession()
            }
    }
}

/// Re-runs `MainView.handleAutoResize` whenever the global auto-resize
/// preference flips or the currently-viewed session's split-view layout
/// changes (split toggled, divider dragged, right-pane terminal swapped).
///
/// The split-state changes don't move the detail-pane bounds, so the
/// `onGeometryChange` that already triggers auto-resize misses them — this
/// modifier fills that gap. Extracting these into a separate modifier keeps
/// the main `body` chain inside SwiftUI's type-checker budget.
struct AutoResizeObserversModifier<Signal: Equatable>: ViewModifier {
    let alwaysAutoResize: Bool
    let splitSignal: Signal?
    let onPreferenceChanged: () -> Void
    let onSplitChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: alwaysAutoResize) { _, _ in
                onPreferenceChanged()
            }
            .onChange(of: splitSignal) { _, _ in
                onSplitChanged()
            }
    }
}

/// Prunes right-side payloads from remote `SessionFileTabsState` whenever
/// the remote session store's pane count changes — covers windows that the
/// host removed (user typed `exit`, the X button, `kill-window`, etc.) so the
/// right pane doesn't strand the split with a dangling reference.
///
/// Hoisted into its own modifier so the main `body` chain stays inside
/// SwiftUI's type-checker budget.
struct RemoteSplitCleanupModifier: ViewModifier {
    let paneCount: Int
    let onPrune: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: paneCount) {
            onPrune()
        }
    }
}

/// Hosts the transient error alert and the close-confirmation alert. Editor
/// launch failures are routed through here as well so the two alert
/// affordances stay co-located.
struct AlertsModifier: ViewModifier {
    @Binding var attachError: String?
    @Binding var closeConfirmation: CloseConfirmation?
    let onPerformClose: (CloseConfirmation.Target) -> Void

    func body(content: Content) -> some View {
        content
            // Routed through here so editor-launch failures surface via the
            // same alert affordance as other transient errors. Defined inside
            // the existing alerts modifier (rather than as a new chained
            // `.onReceive` in `MainView.body`) to keep the body's modifier
            // chain inside SwiftUI's type-checker budget.
            .onReceive(NotificationCenter.default.publisher(for: .editorLaunchFailed)) { notification in
                if let message = notification.userInfo?[editorLaunchFailedMessageKey] as? String {
                    attachError = message
                }
            }
            .alert("Terminal Error", isPresented: .init(
                get: { attachError != nil },
                set: { if !$0 { attachError = nil } }
            )) {
                Button("OK") { attachError = nil }
            } message: {
                if let error = attachError {
                    Text(error)
                }
            }
            .alert(
                closeConfirmation?.title ?? "Close?",
                isPresented: .init(
                    get: { closeConfirmation != nil },
                    set: { if !$0 { closeConfirmation = nil } }
                )
            ) {
                if let confirmation = closeConfirmation {
                    Button("Close Anyway", role: .destructive) {
                        onPerformClose(confirmation.target)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Cancel", role: .cancel) { closeConfirmation = nil }
            } message: {
                if let confirmation = closeConfirmation {
                    Text(confirmation.message)
                }
            }
    }
}

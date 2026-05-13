import ClaudeSpyCommon
import Dependencies
import SwiftUI

/// Bundles the global menu-driven notification observers used by the panes
/// scene (Cmd-Shift-F, Cmd-Shift-[, Cmd-Shift-]) so the main `body` chain
/// stays under the Swift type checker's complexity threshold. Cmd-W routes
/// through the scene-scoped `closeCurrentTabAction` focused value instead —
/// see `MenuCommandFocusedValues.swift`.
struct MenuCommandsModifier: ViewModifier {
    let onOpenContentSearch: () -> Void
    let onSelectPreviousTab: () -> Void
    let onSelectNextTab: () -> Void

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
    }
}

/// Confirmation dialog driven by `editorPickerPath` that lists the user's
/// configured editors and forwards the selection to ``EditorClient``.
///
/// Lives in its own modifier so the SwiftUI view-builder for `MainView.body`
/// stays small enough for the type-checker to handle.
struct EditorPickerDialogModifier: ViewModifier {
    @Binding var editorPickerPath: String?
    let onCmdE: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    private var dialogIsPresented: Binding<Bool> {
        Binding(
            get: { editorPickerPath != nil },
            set: { newValue in
                if !newValue { editorPickerPath = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openCurrentTabInEditor)) { _ in
                onCmdE()
            }
            .confirmationDialog(
                "Open in Editor",
                isPresented: dialogIsPresented,
                titleVisibility: .visible,
                presenting: editorPickerPath,
                actions: dialogActions,
                message: dialogMessage
            )
    }

    @ViewBuilder
    private func dialogActions(path: String) -> some View {
        ForEach(settings.editors) { editor in
            Button(editor.displayName) {
                // Resolve the dependency inside the action so test overrides
                // installed via `withDependencies` are picked up correctly —
                // stored properties on a ViewModifier would re-resolve on every
                // body evaluation and side-step scoped overrides.
                @Dependency(EditorClient.self) var client
                let editorName = editor.displayName
                Task {
                    let launched = await client.openFile(editor, path)
                    if !launched {
                        postEditorLaunchFailed(editorName: editorName, path: path)
                    }
                }
                editorPickerPath = nil
            }
        }
        if settings.editors.isEmpty {
            Button("Configure Editors…") {
                settings.selectedSettingsTab = .editors
                openSettings()
                editorPickerPath = nil
            }
        }
        Button("Cancel", role: .cancel) {
            editorPickerPath = nil
        }
    }

    private func dialogMessage(path: String) -> some View {
        Text(URL(fileURLWithPath: path).lastPathComponent)
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

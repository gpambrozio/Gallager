import ClaudeSpyNetworking
import SwiftUI

/// Context menu buttons for adding, editing, and removing a window description.
public struct DescriptionContextMenuButtons: View {
    let currentDescription: String?
    let isDisabled: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void

    public init(
        currentDescription: String?,
        isDisabled: Bool,
        onEdit: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.currentDescription = currentDescription
        self.isDisabled = isDisabled
        self.onEdit = onEdit
        self.onRemove = onRemove
    }

    public var body: some View {
        Button {
            onEdit()
        } label: {
            if currentDescription != nil {
                Label("Edit Description", symbol: .pencil)
            } else {
                Label("Add Description", symbol: .pencil)
            }
        }
        .disabled(isDisabled)

        if currentDescription != nil {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove Description", symbol: .xmark)
            }
            .disabled(isDisabled)
        }
    }
}

/// View modifier that adds description editing context menu and alert to a view.
///
/// Both the context menu and the alert are attached at the same view level (per-row),
/// which ensures the alert's TextField receives focus correctly on macOS.
/// Used by both iOS (HostSessionsSection) and macOS (RemoteHostSidebarSection).
public struct DescriptionEditingModifier: ViewModifier {
    let paneId: String
    let currentDescription: String?
    let isHostConnected: Bool
    let sessionStore: SessionStore
    let onSetDescription: (String, String?) -> Void

    @State private var isEditingDescription = false
    @State private var editedDescription = ""

    public init(
        paneId: String,
        currentDescription: String?,
        isHostConnected: Bool,
        sessionStore: SessionStore,
        onSetDescription: @escaping (String, String?) -> Void
    ) {
        self.paneId = paneId
        self.currentDescription = currentDescription
        self.isHostConnected = isHostConnected
        self.sessionStore = sessionStore
        self.onSetDescription = onSetDescription
    }

    public func body(content: Content) -> some View {
        content
            .contextMenu {
                DescriptionContextMenuButtons(
                    currentDescription: currentDescription,
                    isDisabled: !isHostConnected,
                    onEdit: {
                        editedDescription = currentDescription ?? ""
                        isEditingDescription = true
                    },
                    onRemove: {
                        guard let state = sessionStore.paneState(for: paneId) else { return }
                        onSetDescription(state.windowId, nil)
                    }
                )
            }
            .alert("Window Description", isPresented: $isEditingDescription) {
                TextField("Description", text: $editedDescription)
                Button("Save") {
                    guard let state = sessionStore.paneState(for: paneId) else { return }
                    let trimmed = editedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSetDescription(state.windowId, trimmed.isEmpty ? nil : trimmed)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter a custom description for this session")
            }
    }
}

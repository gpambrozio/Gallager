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
///
/// Callers can supply additional context menu items via the `additionalMenu` parameter.
/// These items appear above the description editing buttons.
public struct DescriptionEditingModifier<AdditionalMenu: View>: ViewModifier {
    let windowId: String
    let currentDescription: String?
    let isDisabled: Bool
    let onSetDescription: (String, String?) -> Void
    let additionalMenu: AdditionalMenu

    @State private var isEditingDescription = false
    @State private var editedDescription = ""

    public init(
        windowId: String,
        currentDescription: String?,
        isDisabled: Bool = false,
        onSetDescription: @escaping (String, String?) -> Void,
        @ViewBuilder additionalMenu: () -> AdditionalMenu
    ) {
        self.windowId = windowId
        self.currentDescription = currentDescription
        self.isDisabled = isDisabled
        self.onSetDescription = onSetDescription
        self.additionalMenu = additionalMenu()
    }

    public func body(content: Content) -> some View {
        content
            .contextMenu {
                additionalMenu

                DescriptionContextMenuButtons(
                    currentDescription: currentDescription,
                    isDisabled: isDisabled,
                    onEdit: {
                        editedDescription = currentDescription ?? ""
                        isEditingDescription = true
                    },
                    onRemove: {
                        onSetDescription(windowId, nil)
                    }
                )
            }
            .alert("Window Description", isPresented: $isEditingDescription) {
                TextField("Description", text: $editedDescription)
                Button("Save") {
                    let trimmed = editedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSetDescription(windowId, trimmed.isEmpty ? nil : trimmed)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter a custom description for this session")
            }
    }
}

extension DescriptionEditingModifier where AdditionalMenu == EmptyView {
    public init(
        windowId: String,
        currentDescription: String?,
        isDisabled: Bool = false,
        onSetDescription: @escaping (String, String?) -> Void
    ) {
        self.init(
            windowId: windowId,
            currentDescription: currentDescription,
            isDisabled: isDisabled,
            onSetDescription: onSetDescription,
            additionalMenu: { EmptyView() }
        )
    }
}

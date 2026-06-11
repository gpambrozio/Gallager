import ClaudeSpyNetworking
import SwiftUI

/// View modifier that adds a "Rename Window" context menu and an alert for
/// editing the window name. Kept parallel to `DescriptionEditingModifier` so
/// tabs feel consistent with session description editing.
public struct WindowRenamingModifier<AdditionalMenu: View>: ViewModifier {
    let currentName: String
    let isDisabled: Bool
    let onRename: (_ newName: String) -> Void
    let additionalMenu: AdditionalMenu

    @State private var isEditingName = false
    @State private var editedName = ""

    public init(
        currentName: String,
        isDisabled: Bool = false,
        onRename: @escaping (_ newName: String) -> Void,
        @ViewBuilder additionalMenu: () -> AdditionalMenu
    ) {
        self.currentName = currentName
        self.isDisabled = isDisabled
        self.onRename = onRename
        self.additionalMenu = additionalMenu()
    }

    public func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    editedName = currentName
                    isEditingName = true
                } label: {
                    Label("Rename Window", symbol: .pencil)
                }
                .disabled(isDisabled)

                additionalMenu
            }
            .modifier(TextEntryPresentation(
                isPresented: $isEditingName,
                title: "Rename Window",
                message: "Enter a new name for this window",
                placeholder: "Window Name",
                text: $editedName,
                onSave: { raw in
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onRename(trimmed)
                }
            ))
    }
}

public extension WindowRenamingModifier where AdditionalMenu == EmptyView {
    init(
        currentName: String,
        isDisabled: Bool = false,
        onRename: @escaping (_ newName: String) -> Void
    ) {
        self.init(
            currentName: currentName,
            isDisabled: isDisabled,
            onRename: onRename,
            additionalMenu: { EmptyView() }
        )
    }
}

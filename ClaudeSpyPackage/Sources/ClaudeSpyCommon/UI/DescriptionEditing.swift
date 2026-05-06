import ClaudeSpyNetworking
import SwiftUI

#if canImport(AppKit)
    import AppKit
    import SwiftEmojiPicker
#endif

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

/// View modifier that adds description and emoji editing context menu items
/// (and their backing UI) to a view.
///
/// Both the context menu and the alerts/popovers are attached at the same view
/// level (per-row), which ensures the description alert's TextField gets focus
/// correctly on macOS and the emoji popover anchors to the right-clicked row.
///
/// On macOS, "Set/Edit Emoji" presents a `SwiftEmojiPicker` popover anchored to
/// the row. iOS still uses the alert + system keyboard until the iOS picker is
/// wired up.
///
/// Callers can supply additional context menu items via the `additionalMenu`
/// parameter. These items appear above the description editing buttons.
public struct DescriptionEditingModifier<AdditionalMenu: View>: ViewModifier {
    let sessionName: String
    let currentDescription: String?
    let currentEmoji: String?
    let isDisabled: Bool
    let onSetDescription: (String, String?) -> Void
    let onSetEmoji: (String, String?) -> Void
    let additionalMenu: AdditionalMenu

    @State private var isEditingDescription = false
    @State private var editedDescription = ""
    @State private var isEditingEmoji = false
    @State private var editedEmoji = ""

    public init(
        sessionName: String,
        currentDescription: String?,
        currentEmoji: String? = nil,
        isDisabled: Bool = false,
        onSetDescription: @escaping (String, String?) -> Void,
        onSetEmoji: @escaping (String, String?) -> Void = { _, _ in },
        @ViewBuilder additionalMenu: () -> AdditionalMenu
    ) {
        self.sessionName = sessionName
        self.currentDescription = currentDescription
        self.currentEmoji = currentEmoji
        self.isDisabled = isDisabled
        self.onSetDescription = onSetDescription
        self.onSetEmoji = onSetEmoji
        self.additionalMenu = additionalMenu()
    }

    public func body(content: Content) -> some View {
        content
            .contextMenu {
                DescriptionContextMenuButtons(
                    currentDescription: currentDescription,
                    isDisabled: isDisabled,
                    onEdit: {
                        editedDescription = currentDescription ?? ""
                        isEditingDescription = true
                    },
                    onRemove: {
                        onSetDescription(sessionName, nil)
                    }
                )

                EmojiContextMenuButtons(
                    currentEmoji: currentEmoji,
                    isDisabled: isDisabled,
                    onEdit: {
                        editedEmoji = currentEmoji ?? ""
                        isEditingEmoji = true
                    },
                    onRemove: {
                        onSetEmoji(sessionName, nil)
                    }
                )

                additionalMenu
            }
            .alert("Session Description", isPresented: $isEditingDescription) {
                TextField("Description", text: $editedDescription)
                Button("Save") {
                    let trimmed = editedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSetDescription(sessionName, trimmed.isEmpty ? nil : trimmed)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter a custom description for this session")
            }
            .modifier(EmojiEntryPresentation(
                isPresented: $isEditingEmoji,
                editedEmoji: $editedEmoji,
                sessionName: sessionName,
                onSetEmoji: onSetEmoji
            ))
    }
}

public extension DescriptionEditingModifier where AdditionalMenu == EmptyView {
    init(
        sessionName: String,
        currentDescription: String?,
        currentEmoji: String? = nil,
        isDisabled: Bool = false,
        onSetDescription: @escaping (String, String?) -> Void,
        onSetEmoji: @escaping (String, String?) -> Void = { _, _ in }
    ) {
        self.init(
            sessionName: sessionName,
            currentDescription: currentDescription,
            currentEmoji: currentEmoji,
            isDisabled: isDisabled,
            onSetDescription: onSetDescription,
            onSetEmoji: onSetEmoji,
            additionalMenu: { EmptyView() }
        )
    }
}

/// Presents the emoji-entry UI: a `SwiftEmojiPicker` popover anchored to the
/// row on macOS, an alert+TextField on iOS until the iOS picker is wired up.
private struct EmojiEntryPresentation: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var editedEmoji: String
    let sessionName: String
    let onSetEmoji: (String, String?) -> Void

    func body(content: Content) -> some View {
        #if canImport(AppKit)
            content.popover(isPresented: $isPresented, arrowEdge: .leading) {
                EmojiPickerView(selectedEmoji: pickerBinding)
                    .frame(width: 360, height: 380)
            }
        #else
            content.modifier(EmojiAlertModifier(
                isPresented: $isPresented,
                editedEmoji: $editedEmoji,
                sessionName: sessionName,
                onSetEmoji: onSetEmoji
            ))
        #endif
    }

    #if canImport(AppKit)
        /// The picker writes the chosen glyph through this binding. The setter is
        /// only called by the picker (not by our own `editedEmoji = …` assignments
        /// in the menu's onEdit), so a single user-initiated tap reliably commits
        /// and dismisses without echoing the seed value back.
        private var pickerBinding: Binding<String> {
            Binding<String>(
                get: { editedEmoji },
                set: { newValue in
                    editedEmoji = newValue
                    guard SessionEmoji.isValid(newValue) else { return }
                    isPresented = false
                    onSetEmoji(sessionName, newValue)
                }
            )
        }
    #endif
}

private struct EmojiAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var editedEmoji: String
    let sessionName: String
    let onSetEmoji: (String, String?) -> Void

    func body(content: Content) -> some View {
        content.alert("Session Emoji", isPresented: $isPresented) {
            TextField("Emoji", text: $editedEmoji)
            Button("Save") {
                let trimmed = editedEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    onSetEmoji(sessionName, nil)
                } else if SessionEmoji.isValid(trimmed) {
                    onSetEmoji(sessionName, trimmed)
                }
                // Silently drop invalid input so a paste of arbitrary
                // text doesn't get persisted to tmux and broadcast.
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter an emoji to display next to this session")
        }
    }
}

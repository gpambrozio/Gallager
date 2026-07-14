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

/// View modifier that adds description and emoji editing context menu items
/// (and their backing UI) to a view.
///
/// The description alert and the emoji popover are attached at the same view
/// level (per-row), which ensures the description alert's TextField gets focus
/// correctly on macOS and the emoji popover anchors to the right-clicked /
/// long-pressed row.
///
/// "Set/Edit Emoji" presents a ``GallagerEmojiPicker`` — anchored to the row as
/// a popover on macOS, as a half/large detent sheet on iOS (an anchored popover
/// is too cramped to be usable at iPhone screen widths).
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
            .modifier(TextEntryPresentation(
                isPresented: $isEditingDescription,
                title: "Session Description",
                message: "Enter a custom description for this session",
                placeholder: "Description",
                text: $editedDescription,
                onSave: { raw in
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSetDescription(sessionName, trimmed.isEmpty ? nil : trimmed)
                }
            ))
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

/// Presents the ``GallagerEmojiPicker`` view: an anchored popover on macOS
/// where it sits next to the right-clicked row at a fixed size, and a
/// half-height detent sheet on iOS where a tiny anchored popover would crop
/// the grid.
private struct EmojiEntryPresentation: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var editedEmoji: String
    let sessionName: String
    let onSetEmoji: (String, String?) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
            content.popover(isPresented: $isPresented, arrowEdge: .leading) {
                GallagerEmojiPicker(selectedEmoji: pickerBinding)
                    .frame(width: 360, height: 380)
            }
        #else
            content.sheet(isPresented: $isPresented) {
                GallagerEmojiPicker(selectedEmoji: pickerBinding)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        #endif
    }

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
}

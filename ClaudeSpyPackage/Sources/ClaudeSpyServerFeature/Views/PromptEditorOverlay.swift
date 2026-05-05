#if os(macOS)
    import ClaudeSpyCommon
    import SwiftUI

    /// Convenience wrapper that reads from `EditorSessionManager` and shows `PromptEditorOverlay`
    /// when an editor session is active for the given pane. Used by both `MirrorWindowView` and
    /// `WindowPaneLayoutView.PaneTileView`.
    struct PaneEditorOverlay: View {
        let paneId: String

        @Environment(EditorSessionManager.self) private var editorSessionManager

        var body: some View {
            if editorSessionManager.session(for: paneId) != nil {
                PromptEditorOverlay(
                    content: Binding(
                        get: { editorSessionManager.editedContents[paneId] ?? "" },
                        set: { editorSessionManager.editedContents[paneId] = $0 }
                    ),
                    onSubmit: { content in
                        editorSessionManager.submitSession(paneId: paneId, content: content)
                    },
                    onCancel: {
                        editorSessionManager.cancelSession(paneId: paneId)
                    }
                )
            }
        }
    }

    /// Overlay view for editing a Claude Code prompt triggered by Ctrl-G.
    ///
    /// Shown as a large overlay above the terminal when an editor session is active.
    /// Both host and viewer can edit; the first to submit wins.
    ///
    /// Content is provided via `Binding` so edits persist across SwiftUI view
    /// teardown/recreation (e.g., when switching tabs or sessions).
    struct PromptEditorOverlay: View {
        @Binding var content: String
        let onSubmit: (String) -> Void
        let onCancel: () -> Void

        @FocusState private var isEditorFocused: Bool

        var body: some View {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Label("Edit Prompt", symbol: .pencil)
                        .font(.headline)

                    Spacer()

                    Text("Cmd+Return to submit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                // Editor
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .focused($isEditorFocused)

                Divider()

                // Footer
                HStack {
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Cancel Editing")

                    Spacer()

                    Button {
                        onSubmit(content)
                    } label: {
                        Label("Submit", symbol: .paperplaneFill)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("Submit Edited Prompt")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .containerRelativeFrame(.horizontal) { width, _ in
                width * 0.8
            }
            .containerRelativeFrame(.vertical) { height, _ in
                height * 0.5
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task {
                isEditorFocused = true
            }
        }
    }

    #Preview {
        @Previewable @State var content = """
        Refactor the prompt editor overlay to use a custom syntax-highlighted
        editor instead of TextEditor. Make sure Cmd+Return still submits and
        Escape still cancels.
        """
        PromptEditorOverlay(
            content: $content,
            onSubmit: { _ in },
            onCancel: { }
        )
        .padding()
        .frame(width: 800, height: 600)
        .background(.black)
    }
#endif

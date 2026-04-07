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
            if let session = editorSessionManager.session(for: paneId) {
                PromptEditorOverlay(
                    originalContent: session.originalContent,
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
    struct PromptEditorOverlay: View {
        let originalContent: String
        let onSubmit: (String) -> Void
        let onCancel: () -> Void

        @State private var content: String
        @FocusState private var isEditorFocused: Bool

        init(originalContent: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.originalContent = originalContent
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            _content = State(initialValue: originalContent)
        }

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
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .padding(24)
            .task {
                isEditorFocused = true
            }
        }
    }
#endif

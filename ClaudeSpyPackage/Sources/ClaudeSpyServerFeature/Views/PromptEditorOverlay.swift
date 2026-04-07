#if os(macOS)
    import ClaudeSpyCommon
    import SwiftUI

    /// Overlay view for editing a Claude Code prompt triggered by Ctrl-G.
    ///
    /// Shown as a large overlay above the terminal when an editor session is active.
    /// Both host and viewer can edit; the first to submit wins.
    struct PromptEditorOverlay: View {
        let paneId: String
        let originalContent: String
        let onSubmit: (String) -> Void
        let onCancel: () -> Void

        @State private var content: String = ""
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

                    Spacer()

                    Button {
                        onSubmit(content)
                    } label: {
                        Label("Submit", symbol: .paperplaneFill)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .padding(24)
            .task {
                content = originalContent
                isEditorFocused = true
            }
        }
    }
#endif

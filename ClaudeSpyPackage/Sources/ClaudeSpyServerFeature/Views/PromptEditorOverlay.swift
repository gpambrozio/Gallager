#if os(macOS)
    import ClaudeSpyCommon
    import SwiftUI

    /// Convenience wrapper that reads from `EditorSessionManager` and shows `PromptEditorOverlay`
    /// when an editor session is active for the given pane. Used by
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
    /// The card starts at 80% × 50% of the pane and can be resized by dragging
    /// its bottom/trailing edges between half that size and the full pane.
    /// While typing, the card grows its height so new lines stay visible; once
    /// it reaches the pane's height the text scrolls as before.
    ///
    /// Content is provided via `Binding` so edits persist across SwiftUI view
    /// teardown/recreation (e.g., when switching tabs or sessions).
    struct PromptEditorOverlay: View {
        @Binding var content: String
        let onSubmit: (String) -> Void
        let onCancel: () -> Void

        @FocusState private var isEditorFocused: Bool

        /// Displayed card size as fractions of the parent pane. Fractions keep
        /// the card proportional when the pane itself is resized.
        @State private var widthFraction = PromptEditorSizing.defaultWidthFraction
        @State private var heightFraction = PromptEditorSizing.defaultHeightFraction
        /// Card size in points captured when a resize drag starts; nil while idle.
        @State private var dragStartSize: CGSize?
        /// Measured heights driving type-to-grow: full card, editor viewport,
        /// and the ideal (unclipped) height of the current text.
        @State private var cardHeight: CGFloat = 0
        @State private var editorHeight: CGFloat = 0
        @State private var textIdealHeight: CGFloat = 0

        /// Extra room beyond the measured text so the caret line never sits
        /// flush against the editor's edge (text-container insets + slack).
        private static let growSlack: CGFloat = 12

        var body: some View {
            GeometryReader { proxy in
                card(parent: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .task {
                isEditorFocused = true
            }
        }

        private func card(parent: CGSize) -> some View {
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

                editor(parent: parent)

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
            .overlay(alignment: .bottomTrailing) { resizeGrip }
            .overlay(alignment: .trailing) {
                resizeHandle(parent: parent, edges: .trailing)
            }
            .overlay(alignment: .bottom) {
                resizeHandle(parent: parent, edges: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                resizeHandle(parent: parent, edges: [.bottom, .trailing])
            }
            .frame(
                width: PromptEditorSizing.clampedWidthFraction(widthFraction) * parent.width,
                height: PromptEditorSizing.clampedHeightFraction(heightFraction) * parent.height
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                cardHeight = height
                growToFitContent(parent: parent)
            }
        }

        // MARK: - Editor + type-to-grow measurement

        private func editor(parent: CGSize) -> some View {
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .focused($isEditorFocused)
                .background { textMeasurer(parent: parent) }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    editorHeight = height
                    growToFitContent(parent: parent)
                }
                // The mirror only re-measures when the text's *height* changes,
                // so an edit that doesn't add a line (e.g. typing after a manual
                // shrink left the content overflowing) must re-run the check too.
                .onChange(of: content) {
                    growToFitContent(parent: parent)
                }
        }

        /// Hidden mirror of the editor's text, laid out at the same wrap width,
        /// used to learn the height the content actually needs. Measuring a
        /// `Text` avoids reaching into `TextEditor`'s NSTextView.
        private func textMeasurer(parent: CGSize) -> some View {
            // A trailing newline doesn't add a line to `Text`, but the editor
            // shows the caret on that empty line — pad it so it counts.
            let measured = content.hasSuffix("\n") ? content + " " : content
            return Text(measured.isEmpty ? " " : measured)
                .font(.system(.body, design: .monospaced))
                .padding(8) // same as the editor
                .padding(.horizontal, 5) // NSTextView line-fragment padding
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    textIdealHeight = height
                    growToFitContent(parent: parent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .hidden()
                .allowsHitTesting(false)
        }

        /// Raises the card height when the text no longer fits, capped at the
        /// full pane. Grow-only: the height never shrinks, and a manual resize
        /// below the content height sticks (the text scrolls) until the next
        /// edit re-runs the fit check.
        private func growToFitContent(parent: CGSize) {
            // The measurement callbacks fire in no guaranteed order on the
            // first layout pass; requiring every measurement (not just a
            // positive chrome) keeps a missing editorHeight from inflating
            // `required` and permanently over-growing the grow-only height.
            let chrome = cardHeight - editorHeight
            guard
                dragStartSize == nil, parent.height > 0, editorHeight > 0, chrome > 0,
                textIdealHeight > 0 else { return }
            let required = chrome + textIdealHeight + Self.growSlack
            let grown = PromptEditorSizing.heightFraction(
                growing: PromptEditorSizing.clampedHeightFraction(heightFraction),
                toFitRequiredHeight: required,
                parentHeight: parent.height
            )
            guard grown != heightFraction else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                heightFraction = grown
            }
        }

        // MARK: - Resizing

        /// Invisible strip along the card's edge(s) that drags to resize.
        private func resizeHandle(parent: CGSize, edges: Edge.Set) -> some View {
            let resizesWidth = edges.contains(.trailing)
            let resizesHeight = edges.contains(.bottom)
            // The corner gets a comfortably grabbable square; plain edges are
            // thin strips so they don't swallow clicks meant for the content.
            let isCorner = resizesWidth && resizesHeight
            return Color.clear
                .frame(
                    width: resizesWidth ? (isCorner ? 18 : 8) : nil,
                    height: resizesHeight ? (isCorner ? 18 : 8) : nil
                )
                .contentShape(Rectangle())
                .pointerStyle(.frameResize(position: resizePosition(edges: edges)))
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            guard parent.width > 0, parent.height > 0 else { return }
                            let start = dragStartSize ?? CGSize(
                                width: PromptEditorSizing.clampedWidthFraction(widthFraction) * parent.width,
                                height: PromptEditorSizing.clampedHeightFraction(heightFraction) * parent.height
                            )
                            dragStartSize = start
                            if resizesWidth {
                                widthFraction = PromptEditorSizing.widthFraction(
                                    afterDragging: value.translation.width,
                                    fromWidth: start.width,
                                    parentWidth: parent.width
                                )
                            }
                            if resizesHeight {
                                heightFraction = PromptEditorSizing.heightFraction(
                                    afterDragging: value.translation.height,
                                    fromHeight: start.height,
                                    parentHeight: parent.height
                                )
                            }
                        }
                        .onEnded { _ in
                            dragStartSize = nil
                        }
                )
                .accessibilityElement()
                .accessibilityLabel(resizeAccessibilityLabel(edges: edges))
        }

        private func resizePosition(edges: Edge.Set) -> FrameResizePosition {
            if edges.contains(.bottom), edges.contains(.trailing) {
                .bottomTrailing
            } else if edges.contains(.bottom) {
                .bottom
            } else {
                .trailing
            }
        }

        private func resizeAccessibilityLabel(edges: Edge.Set) -> String {
            if edges.contains(.bottom), edges.contains(.trailing) {
                "Resize Prompt Editor"
            } else if edges.contains(.bottom) {
                "Resize Prompt Editor Height"
            } else {
                "Resize Prompt Editor Width"
            }
        }

        /// Classic diagonal-lines grip hinting that the corner is draggable.
        private var resizeGrip: some View {
            Path { path in
                path.move(to: CGPoint(x: 11, y: 3))
                path.addLine(to: CGPoint(x: 3, y: 11))
                path.move(to: CGPoint(x: 11, y: 7))
                path.addLine(to: CGPoint(x: 7, y: 11))
            }
            .stroke(.tertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 14, height: 14)
            .padding(4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    #Preview("Short content (default size)") {
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

    #Preview("Long content (grown to fit)") {
        @Previewable @State var content = (1...20)
            .map { "Line \($0): the quick brown fox jumps over the lazy dog." }
            .joined(separator: "\n")
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

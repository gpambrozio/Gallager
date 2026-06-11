import SwiftUI

/// Presents a single-line text-entry UI for editing a name or description.
///
/// On **macOS** this is a `.sheet`, not a `.alert`, on purpose. A SwiftUI
/// `.alert` does not let us control the initial keyboard focus: when the user
/// has Full Keyboard Access enabled (`AppleKeyboardUIMode = 3`) the alert
/// focuses the *Cancel* button and the text field never becomes first
/// responder — so typing a value that contains a space activates Cancel and
/// the alert vanishes. (Confirmed on macOS 26: `.focused()` inside `.alert`
/// is ignored; first responder stays `_NSAlertButton`.) The sheet instead
/// claims first responder for the field via `@FocusState` + a `.task` tick,
/// which works regardless of Full Keyboard Access — mirroring the focus
/// pattern already used by `BrowserView`/`FileBrowserView`.
///
/// On **iOS** the native `.alert` already focuses the field correctly, so we
/// keep it to preserve the platform-standard look.
public struct TextEntryPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let placeholder: String
    @Binding var text: String
    let onSave: (String) -> Void

    public init(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        placeholder: String,
        text: Binding<String>,
        onSave: @escaping (String) -> Void
    ) {
        self._isPresented = isPresented
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self._text = text
        self.onSave = onSave
    }

    public func body(content: Content) -> some View {
        #if os(macOS)
            content.sheet(isPresented: $isPresented) {
                TextEntrySheet(
                    title: title,
                    message: message,
                    placeholder: placeholder,
                    text: $text,
                    onSave: onSave
                )
            }
        #else
            content.alert(title, isPresented: $isPresented) {
                TextField(placeholder, text: $text)
                Button("Save") { onSave(text) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(message)
            }
        #endif
    }
}

#if os(macOS)
    /// A small macOS sheet for single-line text entry that reliably gives the
    /// field initial keyboard focus. See `TextEntryPresentation` for why this
    /// exists instead of a `.alert`.
    private struct TextEntrySheet: View {
        let title: String
        let message: String
        let placeholder: String
        @Binding var text: String
        let onSave: (String) -> Void

        @Environment(\.dismiss) private var dismiss
        @FocusState private var fieldFocused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { save() }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 320)
            .task {
                // Give SwiftUI a tick to mount the freshly-presented TextField
                // into the responder chain before we ask it to become first
                // responder; otherwise the focus request is dropped.
                try? await Task.sleep(for: .milliseconds(80))
                fieldFocused = true
            }
        }

        private func save() {
            onSave(text)
            dismiss()
        }
    }
#endif

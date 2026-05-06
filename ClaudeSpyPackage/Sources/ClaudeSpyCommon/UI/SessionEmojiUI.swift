import ClaudeSpyNetworking
import SwiftUI

/// A small label rendering a session's custom emoji icon. Emits an
/// accessibility label of `"emoji <value>"` so e2e queries can locate the
/// rendered icon by attribute, mirroring how `SessionColorBar` exposes its
/// color.
public struct SessionEmojiBadge: View {
    public let emoji: String

    public init(emoji: String) {
        self.emoji = emoji
    }

    public var body: some View {
        Text(emoji)
            .accessibilityIdentifier("session-emoji-\(emoji)")
            .accessibilityLabel("emoji \(emoji)")
    }
}

/// Context menu items for adding, editing, and removing a session emoji.
///
/// Designed to live inside another `.contextMenu { }`; renders an
/// "Set Emoji" / "Emoji: <value>" entry that opens a text-input alert and a
/// "Clear Emoji" entry when one is currently set.
public struct EmojiContextMenuButtons: View {
    let currentEmoji: String?
    let isDisabled: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void

    public init(
        currentEmoji: String?,
        isDisabled: Bool = false,
        onEdit: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.currentEmoji = currentEmoji
        self.isDisabled = isDisabled
        self.onEdit = onEdit
        self.onRemove = onRemove
    }

    public var body: some View {
        Button {
            onEdit()
        } label: {
            if let currentEmoji {
                Label {
                    Text("Emoji: \(currentEmoji)")
                } icon: {
                    Symbols.faceSmiling.image
                }
            } else {
                Label("Set Emoji", symbol: .faceSmiling)
            }
        }
        .disabled(isDisabled)

        if currentEmoji != nil {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Clear Emoji", symbol: .xmark)
            }
            .disabled(isDisabled)
        }
    }
}

#Preview("No emoji set") {
    @Previewable @State var emoji: String?
    Form {
        EmojiContextMenuButtons(
            currentEmoji: emoji,
            onEdit: { emoji = "🚀" },
            onRemove: { emoji = nil }
        )
    }
    .frame(width: 280, height: 120)
}

#Preview("With emoji set") {
    @Previewable @State var emoji: String? = "🚀"
    Form {
        EmojiContextMenuButtons(
            currentEmoji: emoji,
            onEdit: { emoji = "🐛" },
            onRemove: { emoji = nil }
        )
    }
    .frame(width: 280, height: 160)
}

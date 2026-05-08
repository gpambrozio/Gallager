import Foundation

/// Validation helpers for the per-session emoji icon (`@gallager-emoji`).
///
/// Stored as a free-form string so any platform-supported emoji works, but
/// rejecting non-emoji input fast prevents arbitrary text from being persisted
/// to tmux and broadcast to viewers — mirroring how `SessionColor.parse`
/// guards the color field.
public enum SessionEmoji {
    /// Maximum number of grapheme clusters allowed in a session emoji icon.
    /// One emoji typically renders as a single cluster (multi-scalar emoji
    /// like flags or skin-toned variants included), so a small cap keeps the
    /// sidebar from absorbing arbitrarily long pasted strings.
    public static let maxLength = 8

    /// Whether `raw` looks like a valid session emoji icon: contains at least
    /// one emoji-bearing scalar and stays under the grapheme cluster cap.
    /// Whitespace-trimmed empty strings are rejected — callers that want to
    /// clear should pass `nil` to `setSessionEmoji` instead.
    public static func isValid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return false }
        return trimmed.unicodeScalars.contains { $0.properties.isEmoji }
    }
}

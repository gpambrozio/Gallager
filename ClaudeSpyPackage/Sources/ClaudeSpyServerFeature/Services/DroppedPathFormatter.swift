import Foundation

/// Formats Finder-dropped POSIX paths into a single shell-escaped string ready
/// to hand off to `tmux load-buffer`/`paste-buffer`.
///
/// The escaping matches what Terminal.app emits when you drop a file on it, so
/// CLI apps that already understand Terminal.app's drop format (Claude Code's
/// `stripBackslashEscapes` round-trips these) need no changes.
public enum DroppedPathFormatter {
    /// The bracketed-paste end marker. If a literal filename ever contained
    /// these bytes, the inner app would terminate the paste early and the rest
    /// of the path string would be interpreted as keystrokes — escape with
    /// `placeholderForBracketedPasteEnd` rather than passing it through.
    public static let bracketedPasteEnd = "\u{1B}[201~"

    /// Stand-in dropped in place of `bracketedPasteEnd` to keep the paste from
    /// breaking out of bracketed mode. The literal sequence is vanishingly
    /// rare in real filenames; the placeholder is intentionally noisy so the
    /// user notices and can rename the file.
    public static let placeholderForBracketedPasteEnd = "\u{FFFD}"

    /// The set of characters that require a backslash escape so the resulting
    /// string survives shell word-splitting and globbing. `~` is handled
    /// separately because it only needs escaping when it appears as the
    /// leading character of a path (otherwise it's just a regular char).
    /// `{` and `}` are escaped so brace expansion (`{a,b}`) doesn't fire on
    /// filenames that happen to contain them. Newline/CR are *not* in this
    /// set — backslash-escaping them doesn't keep them literal in most
    /// shells; we handle those by replacing them with the placeholder rune
    /// before escaping (see `format(urls:)`).
    private static let charactersNeedingEscape: Set<Character> = [
        " ", "\t", "(", ")", "'", "\"", "$", "\\", "`", "!", ";",
        "&", "|", "*", "?", "[", "]", "<", ">", "#", "{", "}",
    ]

    /// Bytes we refuse to pass through verbatim because the shell can't be
    /// fed them safely: the bracketed-paste end marker (would terminate the
    /// paste early), and embedded newlines / carriage returns (the shell
    /// would interpret them as command terminators).
    private static let illegalSequences: [String] = [
        bracketedPasteEnd,
        "\n",
        "\r",
    ]

    /// Escapes a single POSIX path the same way Terminal.app does for a drop.
    public static func escape(path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for (index, char) in path.enumerated() {
            if char == "~", index == 0 {
                out.append("\\~")
            } else if charactersNeedingEscape.contains(char) {
                out.append("\\")
                out.append(char)
            } else {
                out.append(char)
            }
        }
        return out
    }

    /// Joined, shell-escaped representation of the dropped paths, ready to
    /// hand to `tmux load-buffer`. Returns `nil` if `urls` is empty so callers
    /// can short-circuit.
    public static func format(urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        let parts = urls.map { url -> String in
            // `.path` on a `file://` URL gives the POSIX path. Replace any
            // illegal sequences (bracketed-paste end marker, newlines, CR)
            // before backslash-escaping shell metacharacters so the inner
            // app's paste mode and the shell's line discipline both stay
            // intact.
            var safePath = url.path
            for illegal in illegalSequences {
                safePath = safePath.replacingOccurrences(
                    of: illegal,
                    with: placeholderForBracketedPasteEnd
                )
            }
            return escape(path: safePath)
        }
        return parts.joined(separator: " ")
    }
}

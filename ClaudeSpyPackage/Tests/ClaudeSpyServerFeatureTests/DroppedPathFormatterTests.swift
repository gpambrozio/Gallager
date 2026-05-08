import Foundation
import Testing
@testable import ClaudeSpyServerFeature

@Suite("DroppedPathFormatter")
struct DroppedPathFormatterTests {
    @Test("Plain paths are passed through unchanged")
    func plainPaths() {
        #expect(DroppedPathFormatter.escape(path: "/tmp/file.txt") == "/tmp/file.txt")
        #expect(DroppedPathFormatter.escape(path: "/Users/me/dotfile") == "/Users/me/dotfile")
    }

    @Test("Spaces and tabs are backslash-escaped")
    func whitespaceEscaping() {
        #expect(DroppedPathFormatter.escape(path: "/tmp/Drop Me.txt") == "/tmp/Drop\\ Me.txt")
        #expect(DroppedPathFormatter.escape(path: "tab\there") == "tab\\\there")
    }

    @Test("Shell metacharacters are escaped")
    func shellMetacharacters() {
        #expect(DroppedPathFormatter.escape(path: "a(b)c") == "a\\(b\\)c")
        #expect(DroppedPathFormatter.escape(path: "$VAR") == "\\$VAR")
        #expect(DroppedPathFormatter.escape(path: "back\\slash") == "back\\\\slash")
        #expect(DroppedPathFormatter.escape(path: "back`tick") == "back\\`tick")
        #expect(DroppedPathFormatter.escape(path: "bang!") == "bang\\!")
        #expect(DroppedPathFormatter.escape(path: "semi;colon") == "semi\\;colon")
        #expect(DroppedPathFormatter.escape(path: "amp&er") == "amp\\&er")
        #expect(DroppedPathFormatter.escape(path: "pipe|d") == "pipe\\|d")
        #expect(DroppedPathFormatter.escape(path: "glob*?[]") == "glob\\*\\?\\[\\]")
        #expect(DroppedPathFormatter.escape(path: "redir<>") == "redir\\<\\>")
        #expect(DroppedPathFormatter.escape(path: "comment#") == "comment\\#")
        #expect(DroppedPathFormatter.escape(path: "quote'and\"") == "quote\\'and\\\"")
    }

    @Test("Tilde is escaped only at the start of a path")
    func tildeOnlyAtStart() {
        #expect(DroppedPathFormatter.escape(path: "~me") == "\\~me")
        #expect(DroppedPathFormatter.escape(path: "/tmp/~not-home") == "/tmp/~not-home")
    }

    @Test("Multiple URLs are joined by spaces")
    func joinsMultiplePaths() {
        let urls = [
            URL(fileURLWithPath: "/tmp/Drop Me.txt"),
            URL(fileURLWithPath: "/tmp/plain.txt"),
        ]
        #expect(
            DroppedPathFormatter.format(urls: urls) ==
                "/tmp/Drop\\ Me.txt /tmp/plain.txt"
        )
    }

    @Test("Empty list returns nil so callers can short-circuit")
    func emptyListIsNil() {
        #expect(DroppedPathFormatter.format(urls: []) == nil)
    }

    @Test("Bracketed-paste end markers are scrubbed before escaping")
    func scrubsBracketedPasteEnd() {
        // A filename with a literal `ESC[201~` in it would terminate the
        // tmux paste-buffer's bracketed-paste wrap early. The formatter
        // replaces it with the placeholder; the result must not contain
        // the literal sequence at all.
        let nasty = "/tmp/legit\u{1B}[201~exit"
        let url = URL(fileURLWithPath: nasty)
        guard let formatted = DroppedPathFormatter.format(urls: [url]) else {
            Issue.record("Format returned nil")
            return
        }
        #expect(!formatted.contains("\u{1B}[201~"))
        #expect(formatted.contains(DroppedPathFormatter.placeholderForBracketedPasteEnd))
    }

    @Test("Brace expansion characters are escaped")
    func bracesEscaped() {
        #expect(DroppedPathFormatter.escape(path: "/tmp/{a,b}.txt") == "/tmp/\\{a,b\\}.txt")
    }

    @Test("Embedded newline and CR are scrubbed before escaping")
    func newlinesScrubbed() {
        let url = URL(fileURLWithPath: "/tmp/has\nlinebreak\rfile.txt")
        guard let formatted = DroppedPathFormatter.format(urls: [url]) else {
            Issue.record("Format returned nil")
            return
        }
        #expect(!formatted.contains("\n"))
        #expect(!formatted.contains("\r"))
    }
}

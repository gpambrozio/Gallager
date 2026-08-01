import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyCommon

@Suite("TerminalOnlySession.displayTitle")
struct TerminalOnlySessionTitleTests {
    private func makeSession(
        description: String? = nil,
        path: String? = nil
    ) -> TerminalOnlySession {
        TerminalOnlySession(
            sessionName: "scratch",
            displayedState: nil,
            representativePaneId: "%1",
            customDescription: description,
            currentPath: path
        )
    }

    @Test("A session description wins, with no Terminal prefix")
    func descriptionWins() {
        let session = makeSession(description: "My scratch", path: "/Users/bob/Development")
        #expect(session.displayTitle(homeDirectory: "/Users/bob") == "My scratch")
    }

    @Test("Paths abbreviate against the given home directory: exact home and subfolders")
    func abbreviatesAgainstGivenHome() {
        #expect(makeSession(path: "/Users/bob").displayTitle(homeDirectory: "/Users/bob") == "Terminal: ~")
        #expect(
            makeSession(path: "/Users/bob/Development").displayTitle(homeDirectory: "/Users/bob")
                == "Terminal: ~/Development"
        )
    }

    @Test("A path outside the home directory shows unabbreviated")
    func outsideHomeUnchanged() {
        #expect(
            makeSession(path: "/opt/homebrew").displayTitle(homeDirectory: "/Users/bob")
                == "Terminal: /opt/homebrew"
        )
    }

    @Test("Nil home abbreviates against the local home; empty description and missing path fall back")
    func fallbacks() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(
            makeSession(path: home + "/Development").displayTitle(homeDirectory: nil)
                == "Terminal: ~/Development"
        )
        // An empty description is "not set", and with no reported path the
        // row falls back to the tmux session name.
        #expect(makeSession(description: "", path: "").displayTitle(homeDirectory: nil) == "scratch")
        #expect(makeSession().displayTitle(homeDirectory: nil) == "scratch")
    }
}

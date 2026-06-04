import Foundation
import Testing
@testable import ClaudeSpyCommon

#if os(macOS)
    @Suite("LoginShellPath")
    struct LoginShellPathTests {
        @Test("extractPath returns the substring after the marker, trimmed")
        func extractsAfterMarker() {
            let out = "compinit noise\n\(LoginShellPath.marker)/Users/x/.local/bin:/opt/homebrew/bin:/usr/bin"
            #expect(LoginShellPath.extractPath(fromMarkerOutput: out) == "/Users/x/.local/bin:/opt/homebrew/bin:/usr/bin")
        }

        @Test("extractPath is nil when the marker is absent")
        func nilWhenNoMarker() {
            #expect(LoginShellPath.extractPath(fromMarkerOutput: "no marker here") == nil)
        }

        @Test("extractPath is nil when nothing follows the marker")
        func nilWhenEmptyAfterMarker() {
            #expect(LoginShellPath.extractPath(fromMarkerOutput: "\(LoginShellPath.marker)   ") == nil)
        }

        @Test("resolveUserShell honors $SHELL when set")
        func usesShellEnv() {
            #expect(LoginShellPath.resolveUserShell(environment: ["SHELL": "/bin/zsh"]) == "/bin/zsh")
        }

        @Test("resolveUserShell falls back to a non-empty path when $SHELL is empty")
        func fallsBackWhenShellEmpty() {
            let resolved = LoginShellPath.resolveUserShell(environment: ["SHELL": ""])
            #expect(!resolved.isEmpty)
            #expect(resolved.hasPrefix("/"))
        }
    }
#endif

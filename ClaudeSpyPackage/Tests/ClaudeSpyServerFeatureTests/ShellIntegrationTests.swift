import Foundation
import Testing
@testable import ClaudeSpyServerFeature

struct ShellIntegrationTests {
    // MARK: - shellLaunchCommand

    @Test("zsh is launched through our ZDOTDIR so $VISUAL survives ~/.zshrc")
    func zshUsesZDOTDIR() {
        let cmd = TmuxService.shellLaunchCommand(
            shellPath: "/bin/zsh",
            zdotdir: "/tmp/gallager-shell-integration",
            bashRC: "/tmp/gallager-shell-integration/gallager.bash"
        )
        // Captures the user's existing ZDOTDIR (default $HOME) before pointing
        // ZDOTDIR at ours, then launches a normal login shell.
        #expect(
            cmd == "GALLAGER_USER_ZDOTDIR=\"${ZDOTDIR:-$HOME}\" "
                + "ZDOTDIR='/tmp/gallager-shell-integration' exec '/bin/zsh' -l"
        )
    }

    @Test("bash is launched with --rcfile (interactive, non-login)")
    func bashUsesRCFile() {
        let cmd = TmuxService.shellLaunchCommand(
            shellPath: "/opt/homebrew/bin/bash",
            zdotdir: "/tmp/gallager-shell-integration",
            bashRC: "/tmp/gallager-shell-integration/gallager.bash"
        )
        // --rcfile is only honored for interactive non-login shells, so `-l`
        // is dropped; the snippet replicates login startup itself.
        #expect(
            cmd == "exec '/opt/homebrew/bin/bash' "
                + "--rcfile '/tmp/gallager-shell-integration/gallager.bash' -i"
        )
    }

    @Test("Unknown shells keep the plain login launch")
    func otherShellFallsBack() {
        let cmd = TmuxService.shellLaunchCommand(
            shellPath: "/usr/local/bin/fish",
            zdotdir: "/tmp/gallager-shell-integration",
            bashRC: "/tmp/gallager-shell-integration/gallager.bash"
        )
        #expect(cmd == "exec '/usr/local/bin/fish' -l")
    }

    @Test("Without integration paths, zsh and bash keep the plain login launch")
    func nilPathsFallBack() {
        #expect(
            TmuxService.shellLaunchCommand(shellPath: "/bin/zsh", zdotdir: nil, bashRC: nil)
                == "exec '/bin/zsh' -l"
        )
        #expect(
            TmuxService.shellLaunchCommand(shellPath: "/bin/bash", zdotdir: nil, bashRC: nil)
                == "exec '/bin/bash' -l"
        )
    }

    @Test("Shell and integration paths with spaces are single-quoted")
    func quotesPathsWithSpaces() {
        let cmd = TmuxService.shellLaunchCommand(
            shellPath: "/Applications/My Shell/zsh",
            zdotdir: "/tmp/my dir",
            bashRC: nil
        )
        #expect(cmd.contains("ZDOTDIR='/tmp/my dir'"))
        #expect(cmd.contains("exec '/Applications/My Shell/zsh' -l"))
    }

    // MARK: - install

    @Test("install writes both snippets and returns their paths")
    func installWritesSnippets() throws {
        let tmp = NSTemporaryDirectory() + "shell-integration-test-\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let paths = try ShellIntegration.install(temporaryDirectory: tmp)

        // zsh integration: a .zshenv inside the returned ZDOTDIR.
        #expect(paths.zdotdir.hasSuffix("gallager-shell-integration"))
        let zshenvPath = paths.zdotdir + "/.zshenv"
        #expect(FileManager.default.fileExists(atPath: zshenvPath))

        // bash integration: the rc file path is returned and exists.
        #expect(paths.bashRC.hasSuffix("gallager-shell-integration/gallager.bash"))
        #expect(FileManager.default.fileExists(atPath: paths.bashRC))
    }

    @Test("install namespaces the directory under E2E")
    func installNamespacesE2E() throws {
        let tmp = NSTemporaryDirectory() + "shell-integration-test-\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let paths = try ShellIntegration.install(temporaryDirectory: tmp, isE2E: true)
        #expect(paths.zdotdir.hasSuffix("gallager-shell-integration-e2e"))
    }

    // MARK: - snippet content

    @Test("zsh snippet hands ZDOTDIR back and re-applies VISUAL via a precmd hook")
    func zshSnippetMechanics() {
        let snippet = ShellIntegration.zshenv
        // Captures our value before the user's rc can change it.
        #expect(snippet.contains("__gallager_visual=\"${VISUAL}\""))
        // Restores ZDOTDIR to the user's real config dir.
        #expect(snippet.contains("ZDOTDIR=\"${GALLAGER_USER_ZDOTDIR:-$HOME}\""))
        // Re-applies VISUAL after all rc files run, via precmd.
        #expect(snippet.contains("add-zsh-hook precmd __gallager_apply_visual"))
        #expect(snippet.contains("export VISUAL=\"${__gallager_visual}\""))
    }

    @Test("bash snippet replicates login startup then re-applies VISUAL last")
    func bashSnippetMechanics() {
        let snippet = ShellIntegration.bashRC
        #expect(snippet.contains("__gallager_visual=\"${VISUAL}\""))
        // Replicates `bash -l` startup order.
        #expect(snippet.contains(". /etc/profile"))
        #expect(snippet.contains("${HOME}/.bash_profile"))
        // The VISUAL re-assertion comes after the sourcing block.
        let visualAssign = "export VISUAL=\"${__gallager_visual}\""
        #expect(snippet.contains(visualAssign))
        if
            let profileRange = snippet.range(of: ". /etc/profile"),
            let visualRange = snippet.range(of: visualAssign) {
            #expect(profileRange.lowerBound < visualRange.lowerBound)
        }
    }
}

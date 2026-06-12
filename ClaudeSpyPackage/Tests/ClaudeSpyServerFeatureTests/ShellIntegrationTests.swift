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
        // ZDOTDIR at ours, then launches a normal login shell. Guarded on the
        // snippet still existing at pane-spawn time, falling back to a plain
        // login shell so a missing snippet can never strand the user's rc files.
        #expect(
            cmd == "if [ -r '/tmp/gallager-shell-integration/.zshenv' ]; then "
                + "GALLAGER_USER_ZDOTDIR=\"${ZDOTDIR:-$HOME}\" "
                + "ZDOTDIR='/tmp/gallager-shell-integration' exec '/bin/zsh' -l; "
                + "fi; exec '/bin/zsh' -l"
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
        // is dropped; the snippet replicates login startup itself. Guarded the
        // same way as zsh: `--rcfile <missing>` would read no rc at all.
        #expect(
            cmd == "if [ -r '/tmp/gallager-shell-integration/gallager.bash' ]; then "
                + "exec '/opt/homebrew/bin/bash' "
                + "--rcfile '/tmp/gallager-shell-integration/gallager.bash' -i; "
                + "fi; exec '/opt/homebrew/bin/bash' -l"
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
        #expect(cmd.contains("[ -r '/tmp/my dir/.zshenv' ]"))
        #expect(cmd.contains("ZDOTDIR='/tmp/my dir'"))
        #expect(cmd.contains("exec '/Applications/My Shell/zsh' -l"))
    }

    // MARK: - install

    @Test("install writes both snippets into the given directory")
    func installWritesSnippets() throws {
        // Nested non-existent path: install must create intermediate dirs too.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("shell-integration-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let paths = try ShellIntegration.install(into: dir)

        // zsh integration: a .zshenv inside the returned ZDOTDIR.
        #expect(paths.zdotdir == dir.path)
        #expect(FileManager.default.fileExists(atPath: paths.zdotdir + "/.zshenv"))

        // bash integration: the rc file path is returned and exists.
        #expect(paths.bashRC == dir.appendingPathComponent("gallager.bash").path)
        #expect(FileManager.default.fileExists(atPath: paths.bashRC))
    }

    // MARK: - spawn-time guard (real /bin/sh)

    /// Runs a launch command the way tmux runs `default-command`: `/bin/sh -c`.
    /// The environment is pinned so a developer's own ZDOTDIR can't leak into
    /// the fallback-branch assertions.
    private func runLaunchCommand(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes a fake shell that reports the env/args it was exec'd with.
    private func makeFakeShell(named name: String, in dir: URL) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho \"ZDOTDIR=[${ZDOTDIR}] ARGS=[$*]\"\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test("zsh trampolines through ZDOTDIR only while the snippet exists")
    func zshGuardFallsBackWhenSnippetMissing() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("shell-guard-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fakeZsh = try makeFakeShell(named: "zsh", in: base)
        let integrationDir = base.appendingPathComponent("shell-integration", isDirectory: true)
        // Baked once (like tmux's default-command), evaluated at every spawn.
        let cmd = TmuxService.shellLaunchCommand(
            shellPath: fakeZsh, zdotdir: integrationDir.path, bashRC: nil
        )

        // Snippet missing (reaped/deleted): plain login shell, no ZDOTDIR —
        // the user's own rc files stay in charge.
        #expect(try runLaunchCommand(cmd).contains("ZDOTDIR=[] ARGS=[-l]"))

        // Snippet present: trampoline through our ZDOTDIR.
        _ = try ShellIntegration.install(into: integrationDir)
        #expect(try runLaunchCommand(cmd).contains("ZDOTDIR=[\(integrationDir.path)] ARGS=[-l]"))
    }

    @Test("bash uses --rcfile only while the snippet exists")
    func bashGuardFallsBackWhenSnippetMissing() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("shell-guard-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fakeBash = try makeFakeShell(named: "bash", in: base)
        let integrationDir = base.appendingPathComponent("shell-integration", isDirectory: true)
        let rcPath = integrationDir.appendingPathComponent("gallager.bash").path
        let cmd = TmuxService.shellLaunchCommand(
            shellPath: fakeBash, zdotdir: nil, bashRC: rcPath
        )

        // Snippet missing: fall back to a login shell (NOT a bare --rcfile
        // launch, which would read no startup files at all).
        #expect(try runLaunchCommand(cmd).contains("ARGS=[-l]"))

        // Snippet present: interactive non-login shell through our rc file.
        _ = try ShellIntegration.install(into: integrationDir)
        #expect(try runLaunchCommand(cmd).contains("ARGS=[--rcfile \(rcPath) -i]"))
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

import ClaudeSpyCommon
import Dependencies
import SwiftUI

/// Consent dialog shown on the first session creation when the startup probe
/// found that the user's shell config clobbers the `$VISUAL` Gallager sets on
/// tmux panes (issue #591 §2–§3).
///
/// Three co-equal choices, plus "Decide later". The override is never applied
/// without the user picking it here (or in Settings) — Gallager's env is a
/// default, not a silent override.
struct EditorOverrideDialog: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(TmuxService.self) private var tmuxService

    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?

    /// The user's effective `$VISUAL` from the probe (nil = their rc unset it).
    private var conflictingValue: String? {
        coordinator.editorOverrideProbeResult?.conflictingValue
    }

    private var displayValue: String {
        conflictingValue ?? "(unset)"
    }

    /// The guarded rc line suggested by Option 1, with the user's own value
    /// substituted and the right syntax for their login shell.
    private var recommendedLine: String {
        EditorOverride.recommendedRcLine(
            visualValue: conflictingValue ?? "your-editor",
            shell: tmuxService.loginShellPath
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            option1Card

            optionButton(
                title: "Let Gallager override in its own sessions",
                detail: "Gallager types `export VISUAL=…` into its shell panes so Ctrl-G opens the in-app editor. The line is visible in the pane's scrollback, and it also affects `git commit` / `crontab` in those panes.",
                role: nil
            ) {
                coordinator.setEditorOverrideMode(.overrideInGallagerSessions)
                dismiss()
            }

            optionButton(
                title: "Keep my editor, stop asking",
                detail: "Ctrl-G opens your editor inside the terminal pane. From a remote iOS viewer the in-app editor won't be used (a GUI editor like `code --wait` would open on the Mac, not your phone).",
                role: nil
            ) {
                coordinator.setEditorOverrideMode(.useMyEditor)
                dismiss()
            }

            HStack {
                Spacer()
                Button("Decide later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your shell overrides Gallager's prompt editor")
                .font(.headline)

            // Markdown string literal: the backticks render `VISUAL=…` as inline
            // code without fragile Text concatenation.
            Text("Ctrl-G in Claude Code / Codex is meant to open Gallager's in-app prompt editor. Your shell config sets `VISUAL=\(displayValue)`, which runs *after* Gallager's setup in each session and overrides it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var option1Card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Fix it in your shell config")
                    .font(.subheadline.bold())
                Text("Recommended")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(.capsule)
            }

            Text("Keep your editor everywhere except Gallager's panes. Gallager exports `GALLAGER_SOCKET` before your rc files run, so guard your export with it:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            codeRow

            Text("Gallager re-checks on the next launch — once its editor survives, this dialog won't return. Your export keeps working in every other terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("I'll fix my config") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
    }

    private var codeRow: some View {
        HStack(alignment: .top) {
            Text(recommendedLine)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button {
                copyToClipboard(recommendedLine)
            } label: {
                Label(copied ? "Copied!" : "Copy", symbol: .docOnClipboard)
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(.rect(cornerRadius: 6))
    }

    private func optionButton(
        title: String,
        detail: LocalizedStringKey,
        role: ButtonRole?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(title, role: role, action: action)
            }
        }
    }

    // MARK: - Actions

    private func dismiss() {
        coordinator.isShowingEditorOverrideDialog = false
    }

    private func copyToClipboard(_ text: String) {
        @Dependency(ClipboardClient.self) var clipboard
        clipboard.setString(text)
        copied = true
        // Transient confirmation: revert to "Copy" after a beat. Cancel any
        // pending revert so a re-copy gets its full 2 seconds.
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

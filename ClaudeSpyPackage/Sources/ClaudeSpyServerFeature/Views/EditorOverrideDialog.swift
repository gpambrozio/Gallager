import ClaudeSpyCommon
import Dependencies
import SwiftUI

/// Consent dialog shown on the first session creation when the startup probe
/// found that the user's shell config clobbers the `$VISUAL` Gallager sets on
/// tmux panes (issue #591 §2–§3).
///
/// Redesign: a single decision presented as three radio choice cards
/// (recommended pre-selected). The "Fix in shell config" card expands to
/// reveal the guarded rc line; one "Continue" button commits the choice.
/// The override is never applied without the user picking it here (or in
/// Settings) — Gallager's env is a default, not a silent override.
struct EditorOverrideDialog: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(TmuxService.self) private var tmuxService

    /// The resolution the user has selected but not yet committed.
    private enum Choice: Hashable {
        case fixInConfig
        case overrideInGallagerSessions
        case useMyEditor
    }

    @State private var selection: Choice = .fixInConfig
    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?

    /// The user's effective `$VISUAL` from the probe (nil = their rc unset it).
    private var conflictingValue: String? {
        coordinator.editorOverrideProbeResult?.conflictingValue
    }

    private var displayValue: String {
        conflictingValue ?? "(unset)"
    }

    /// The guarded rc line suggested by the recommended fix, with the user's
    /// own value substituted and the right syntax for their login shell.
    private var recommendedLine: String {
        EditorOverride.recommendedRcLine(
            visualValue: conflictingValue ?? "your-editor",
            shell: tmuxService.loginShellPath
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 8) {
                fixCard
                choiceCard(
                    .overrideInGallagerSessions,
                    title: "Let Gallager override in its own sessions",
                    summary: "Gallager exports VISUAL into its panes — visible in scrollback."
                )
                choiceCard(
                    .useMyEditor,
                    title: "Keep my editor, stop asking",
                    summary: "Ctrl-G uses your editor. On a remote iOS viewer, a GUI editor opens on the Mac."
                )
            }

            HStack {
                Spacer()
                Button("Decide later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your shell overrides Gallager's prompt editor")
                .font(.headline)

            // Markdown string literal: backticks render `VISUAL=…` as inline code.
            Text("Ctrl-G should open Gallager's in-app editor, but your shell sets `VISUAL=\(displayValue)` after Gallager runs. Choose how to resolve it:")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Cards

    /// The recommended card. When selected it expands to reveal the rc line.
    private var fixCard: some View {
        cardShell(.fixInConfig) {
            VStack(alignment: .leading, spacing: 12) {
                cardRow(
                    .fixInConfig,
                    title: "Fix it in my shell config",
                    summary: "Keep my editor everywhere except Gallager's panes.",
                    recommended: true
                )

                if selection == .fixInConfig {
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Gallager exports `GALLAGER_SOCKET` before your rc loads. Guard your export so it skips Gallager's panes:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        codeRow
                        Text("Re-checked on next launch — once it survives, this dialog won't return.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func choiceCard(_ choice: Choice, title: String, summary: LocalizedStringKey) -> some View {
        cardShell(choice) {
            cardRow(choice, title: title, summary: summary, recommended: false)
        }
    }

    /// Tappable card container with selection ring + tint.
    private func cardShell<Content: View>(
        _ choice: Choice,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isSelected = selection == choice
        return content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)
            )
            .clipShape(.rect(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(.rect)
            .onTapGesture { selection = choice }
    }

    /// The radio + title + summary row shared by every card.
    private func cardRow(
        _ choice: Choice,
        title: String,
        summary: LocalizedStringKey,
        recommended: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            (selection == choice ? Symbols.largecircleFillCircle : Symbols.circle).image
                .foregroundStyle(selection == choice ? Color.accentColor : Color.secondary)
                .font(.system(size: 15))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    if recommended {
                        Text("Recommended")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(.capsule)
                    }
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
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

    // MARK: - Actions

    /// Apply the committed choice. The recommended "fix in config" path leaves
    /// the setting at *Ask* (the next-launch probe verifies) and just dismisses.
    private func commit() {
        switch selection {
        case .fixInConfig:
            break
        case .overrideInGallagerSessions:
            coordinator.setEditorOverrideMode(.overrideInGallagerSessions)
        case .useMyEditor:
            coordinator.setEditorOverrideMode(.useMyEditor)
        }
        dismiss()
    }

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

#if DEBUG
    /// Builds the dialog with a coordinator seeded into a given probe state, so
    /// the previews can exercise both conflict shapes without a live tmux probe.
    @MainActor
    private func editorOverrideDialogPreview(_ probe: VisualProbeResult) -> some View {
        let coordinator = AppCoordinator()
        coordinator.setEditorOverrideProbeResultForPreview(probe)
        return EditorOverrideDialog()
            .environment(coordinator)
            .environment(coordinator.tmuxService)
    }

    #Preview("Shell sets VISUAL=vim") {
        editorOverrideDialogPreview(.conflict(effectiveValue: "vim"))
    }

    #Preview("Shell unsets VISUAL") {
        editorOverrideDialogPreview(.conflict(effectiveValue: nil))
    }
#endif

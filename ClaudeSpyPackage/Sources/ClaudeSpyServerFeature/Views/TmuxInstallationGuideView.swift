#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import Dependencies
    import Foundation
    import SwiftUI

    /// Dialog shown at startup when tmux is not installed.
    ///
    /// Explains that tmux is required, detects available package managers, and
    /// presents the appropriate installation commands with copy-to-clipboard buttons.
    /// Polls every second for the tmux binary and auto-dismisses when it becomes available.
    public struct TmuxInstallationGuideView: View {
        @Environment(\.dismiss) private var dismiss
        @Dependency(TmuxBinaryLocator.self) private var tmuxLocator

        /// Whether Homebrew is available on this system
        @State private var hasHomebrew = false
        /// Whether MacPorts is available on this system
        @State private var hasMacPorts = false
        /// Which command was last copied (for "Copied!" feedback)
        @State private var copiedCommand: String?
        @State private var feedbackResetTrigger: UUID?

        /// Called when tmux is detected, with the path where it was found.
        private let onTmuxFound: @MainActor (String) -> Void

        public init(onTmuxFound: @escaping @MainActor (String) -> Void) {
            self.onTmuxFound = onTmuxFound
        }

        public var body: some View {
            VStack(spacing: 24) {
                headerSection
                Divider()
                ScrollView {
                    contentSection
                }
                .scrollBounceBehavior(.basedOnSize)

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for tmux to be installed\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Quit Gallager") {
                    // Force exit — NSApp.terminate gets blocked by
                    // interactiveDismissDisabled on the parent sheet.
                    exit(0)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            .padding(24)
            .frame(width: 520, height: 460)
            .interactiveDismissDisabled()
            .task {
                hasHomebrew = tmuxLocator.hasHomebrew()
                hasMacPorts = tmuxLocator.hasMacPorts()
            }
            .task {
                // Poll for tmux every second
                while !Task.isCancelled {
                    if let path = tmuxLocator.find() {
                        onTmuxFound(path)
                        dismiss()
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .task(id: feedbackResetTrigger) {
                guard feedbackResetTrigger != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                copiedCommand = nil
            }
        }

        // MARK: - Header

        @ViewBuilder
        private var headerSection: some View {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("tmux Required")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Gallager uses tmux to mirror terminal sessions.\nInstall tmux to get started.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }

        // MARK: - Content

        @ViewBuilder
        private var contentSection: some View {
            VStack(spacing: 16) {
                if hasHomebrew || hasMacPorts {
                    if hasHomebrew {
                        commandCard(
                            title: "Install with Homebrew",
                            command: "brew install tmux",
                            description: "Recommended — installs tmux using Homebrew."
                        )
                    }

                    if hasMacPorts {
                        commandCard(
                            title: "Install with MacPorts",
                            command: "sudo port install tmux",
                            description: "Installs tmux using MacPorts (requires administrator password)."
                        )
                    }
                } else {
                    Text(
                        "No package manager detected. Install Homebrew first, then use it to install tmux."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)

                    commandCard(
                        title: "Step 1 — Install Homebrew",
                        command:
                        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
                        description:
                        "Paste this into Terminal to install the Homebrew package manager."
                    )

                    commandCard(
                        title: "Step 2 — Install tmux",
                        command: "brew install tmux",
                        description: "After Homebrew finishes, run this to install tmux."
                    )
                }
            }
        }

        // MARK: - Command Card

        private func commandCard(title: String, command: String, description: String) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)

                HStack(alignment: .top) {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        copyToClipboard(command)
                    } label: {
                        Label(
                            copiedCommand == command ? "Copied!" : "Copy",
                            symbol: .docOnClipboard
                        )
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(.rect(cornerRadius: 6))

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }

        // MARK: - Helpers

        private func copyToClipboard(_ text: String) {
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setString(text)
            copiedCommand = text
            feedbackResetTrigger = UUID()
        }
    }

    // MARK: - Previews

    #Preview("Homebrew Available") {
        withDependencies {
            $0[TmuxBinaryLocator.self].hasHomebrew = { true }
            $0[TmuxBinaryLocator.self].hasMacPorts = { false }
        } operation: {
            TmuxInstallationGuideView { _ in }
        }
    }

    #Preview("Both Available") {
        withDependencies {
            $0[TmuxBinaryLocator.self].hasHomebrew = { true }
            $0[TmuxBinaryLocator.self].hasMacPorts = { true }
        } operation: {
            TmuxInstallationGuideView { _ in }
        }
    }

    #Preview("No Package Manager") {
        withDependencies {
            $0[TmuxBinaryLocator.self].hasHomebrew = { false }
            $0[TmuxBinaryLocator.self].hasMacPorts = { false }
        } operation: {
            TmuxInstallationGuideView { _ in }
        }
    }
#endif

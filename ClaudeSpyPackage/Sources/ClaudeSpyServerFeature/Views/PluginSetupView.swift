#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import SwiftUI

    /// First-launch setup view for plugin installation
    public struct PluginSetupView: View {
        @Environment(PluginService.self) private var pluginService
        @Environment(AppSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss

        @State private var showingInstructions = false
        @State private var showCopiedFeedback = false
        @State private var feedbackResetTrigger: UUID?

        public init() { }

        public var body: some View {
            VStack(spacing: 24) {
                // Header
                headerSection

                Divider()

                // Content based on state
                contentSection

                Spacer()

                // Footer actions
                footerSection
            }
            .padding(24)
            .frame(width: 500, height: 450)
            .task {
                await pluginService.checkInstallation()
            }
            .task(id: feedbackResetTrigger) {
                guard feedbackResetTrigger != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                showCopiedFeedback = false
            }
        }

        // MARK: - Header

        @ViewBuilder
        private var headerSection: some View {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("Welcome to ClaudeSpy")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("To monitor Claude Code sessions, a plugin must be installed.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }

        // MARK: - Content

        @ViewBuilder
        private var contentSection: some View {
            VStack(spacing: 20) {
                // Status indicator
                statusView

                // Installation output (if any)
                if !pluginService.installationOutput.isEmpty {
                    ScrollView {
                        Text(pluginService.installationOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(4)
                }

                // Manual instructions disclosure
                DisclosureGroup("Manual Installation", isExpanded: $showingInstructions) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pluginService.manualInstructions)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(4)

                        Button {
                            copyToClipboard(pluginService.manualInstructions)
                        } label: {
                            Label(showCopiedFeedback ? "Copied!" : "Copy Commands", symbol: .docOnClipboard)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
            }
        }

        @ViewBuilder
        private var statusView: some View {
            HStack(spacing: 16) {
                statusIcon
                    .font(.largeTitle)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.headline)

                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if shouldShowInstallButton {
                    Button {
                        Task {
                            await pluginService.installPlugin()
                        }
                    } label: {
                        Label("Install", symbol: .arrowDown)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pluginService.state == .installing)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
        }

        @ViewBuilder
        private var statusIcon: some View {
            switch pluginService.state {
            case .unknown,
                 .checking:
                ProgressView()
                    .controlSize(.regular)
            case .installed:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
            case .notInstalled:
                Symbols.puzzlepiece.image
                    .foregroundStyle(.orange)
            case .installing:
                ProgressView()
                    .controlSize(.regular)
            case .installationFailed:
                Symbols.xmarkCircleFill.image
                    .foregroundStyle(.red)
            }
        }

        private var statusTitle: String {
            switch pluginService.state {
            case .unknown,
                 .checking:
                "Checking plugin status..."
            case .installed:
                "Plugin Ready"
            case .notInstalled:
                "Plugin Not Installed"
            case .installing:
                "Installing Plugin..."
            case .installationFailed:
                "Installation Failed"
            }
        }

        private var statusSubtitle: String {
            switch pluginService.state {
            case .unknown,
                 .checking:
                "Please wait"
            case let .installed(version):
                "Version \(version) is installed and ready to use"
            case .notInstalled:
                "Click Install to set up the plugin automatically"
            case .installing:
                "This may take a moment"
            case let .installationFailed(error):
                error
            }
        }

        private var shouldShowInstallButton: Bool {
            switch pluginService.state {
            case .notInstalled,
                 .installationFailed:
                true
            default:
                false
            }
        }

        // MARK: - Footer

        @ViewBuilder
        private var footerSection: some View {
            HStack {
                Button("Skip for Now") {
                    settings.hasCompletedPluginSetup = true
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                if case .installed = pluginService.state {
                    Button("Get Started") {
                        settings.hasCompletedPluginSetup = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }

        // MARK: - Helpers

        private func copyToClipboard(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

            showCopiedFeedback = true
            feedbackResetTrigger = UUID()
        }
    }
#endif

#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import SwiftUI

    /// Settings view for managing the Claude Code plugin
    public struct PluginSettingsView: View {
        @Environment(PluginService.self) private var pluginService

        @State private var showingInstructions = false
        @State private var showCopiedFeedback = false
        @State private var feedbackResetTrigger: UUID?

        public init() { }

        public var body: some View {
            Form {
                // Plugin Status Section
                Section {
                    pluginStatusRow
                } header: {
                    Text("Plugin Status")
                } footer: {
                    Text("The gallager plugin enables real-time monitoring of Claude Code sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Installation Section
                if case .notInstalled = pluginService.state {
                    Section {
                        installationContent
                    } header: {
                        Text("Installation")
                    }
                }

                // Manual Instructions Section
                Section {
                    manualInstructionsContent
                } header: {
                    Text("Manual Installation")
                } footer: {
                    Text("Use these commands if automatic installation fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Installation Output (if any)
                if !pluginService.installationOutput.isEmpty {
                    Section {
                        ScrollView {
                            Text(pluginService.installationOutput)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    } header: {
                        Text("Installation Log")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 400, minHeight: 300)
            .navigationTitle("Plugin")
            .task {
                await pluginService.checkInstallation()
            }
            .task(id: feedbackResetTrigger) {
                guard feedbackResetTrigger != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                showCopiedFeedback = false
            }
        }

        // MARK: - Plugin Status Row

        @ViewBuilder
        private var pluginStatusRow: some View {
            HStack(spacing: 12) {
                statusIcon
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.headline)

                    if case let .installed(version) = pluginService.state {
                        Text("Version \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                statusActionButton
            }
            .padding(.vertical, 4)
        }

        @ViewBuilder
        private var statusIcon: some View {
            switch pluginService.state {
            case .unknown,
                 .checking:
                ProgressView()
                    .controlSize(.small)
            case .installed:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
            case .notInstalled:
                Symbols.exclamationmarkTriangle.image
                    .foregroundStyle(.orange)
            case .installing:
                ProgressView()
                    .controlSize(.small)
            case .installationFailed:
                Symbols.xmarkCircleFill.image
                    .foregroundStyle(.red)
            }
        }

        private var statusText: String {
            switch pluginService.state {
            case .unknown,
                 .checking:
                "Checking..."
            case .installed:
                "Plugin Installed"
            case .notInstalled:
                "Plugin Not Installed"
            case .installing:
                "Installing..."
            case let .installationFailed(error):
                "Installation Failed: \(error)"
            }
        }

        @ViewBuilder
        private var statusActionButton: some View {
            switch pluginService.state {
            case .installed:
                Button("Check for Updates") {
                    Task {
                        await pluginService.checkInstallation()
                    }
                }
            case .notInstalled,
                 .installationFailed:
                Button("Install Plugin") {
                    Task {
                        await pluginService.installPlugin()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pluginService.state == .installing)
            case .unknown,
                 .checking,
                 .installing:
                EmptyView()
            }
        }

        // MARK: - Installation Content

        @ViewBuilder
        private var installationContent: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("The plugin is required for Gallager to receive events from Claude Code sessions.")
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await pluginService.installPlugin()
                    }
                } label: {
                    Label("Install Automatically", symbol: .arrowDown)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pluginService.state == .installing)
            }
        }

        // MARK: - Manual Instructions

        @ViewBuilder
        private var manualInstructionsContent: some View {
            DisclosureGroup("Show Installation Commands") {
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

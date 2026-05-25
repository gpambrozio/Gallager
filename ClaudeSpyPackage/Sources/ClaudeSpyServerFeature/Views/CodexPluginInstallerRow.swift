#if os(macOS)
    import ClaudeSpyCommon
    import CodexPluginCore
    import Dependencies
    import SwiftUI

    /// Settings-pane row for installing or removing the codex-gallager plugin
    /// in Codex CLI.
    struct CodexPluginInstallerRow: View {
        @Bindable var settings: AppSettings

        @State private var status: Status = .checking
        @State private var inFlight = false
        @State private var showingError = false
        @State private var errorMessage = ""

        @Dependency(CodexInstaller.self) private var installer

        enum Status {
            case checking
            case installed
            case notInstalled
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                statusLabel
                Spacer()
                actionButton
            }
            // `.task` runs on @MainActor already, so we can mutate @State
            // directly inside `refresh()` without an extra hop.
            .task { await refresh() }
            .alert("Codex plugin install failed", isPresented: $showingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }

        @ViewBuilder
        private var statusLabel: some View {
            switch status {
            case .checking:
                Label("Checking Codex plugin status…", symbol: .ellipsisCircle)
                    .foregroundStyle(.secondary)
            case .installed:
                Label("codex-gallager plugin installed", symbol: .checkmarkCircle)
                    .foregroundStyle(.green)
            case .notInstalled:
                Label("codex-gallager plugin not installed", symbol: .exclamationmarkTriangle)
                    .foregroundStyle(.secondary)
            }
        }

        @ViewBuilder
        private var actionButton: some View {
            switch status {
            case .checking:
                EmptyView()
            case .installed:
                HStack(spacing: 8) {
                    Button("Reinstall") { Task { await install() } }
                        .disabled(inFlight)
                    Button("Uninstall", role: .destructive) { Task { await uninstall() } }
                        .disabled(inFlight)
                }
            case .notInstalled:
                Button("Install Codex Plugin") { Task { await install() } }
                    .disabled(inFlight)
                    .buttonStyle(.borderedProminent)
            }
        }

        @MainActor
        private func refresh() async {
            let installed = await installer.isInstalled(codexCommand: settings.codexCommandPath)
            status = installed ? .installed : .notInstalled
        }

        @MainActor
        private func install() async {
            inFlight = true
            defer { inFlight = false }
            do {
                try await installer.install(codexCommand: settings.codexCommandPath)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }

        @MainActor
        private func uninstall() async {
            inFlight = true
            defer { inFlight = false }
            do {
                try await installer.uninstall(codexCommand: settings.codexCommandPath)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

#endif

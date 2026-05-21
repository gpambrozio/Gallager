#if os(macOS)
    import ClaudeSpyCommon
    import Dependencies
    import SwiftUI

    /// Settings-pane row for installing or removing the global Codex CLI
    /// hooks that forward lifecycle events to ClaudeSpy.
    struct CodexHookInstallerRow: View {
        @State private var status: Status = .checking
        @State private var inFlight = false
        @State private var lastError: String?

        @Dependency(CodexHookInstaller.self) private var installer

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
            .task { await refresh() }
            .alert(
                "Codex hook install failed",
                isPresented: Binding(
                    get: { lastError != nil },
                    set: { if !$0 { lastError = nil } }
                ),
                presenting: lastError
            ) { _ in
                Button("OK", role: .cancel) { lastError = nil }
            } message: { message in
                Text(message)
            }
        }

        @ViewBuilder
        private var statusLabel: some View {
            switch status {
            case .checking:
                Label("Checking Codex hook status…", symbol: .ellipsisCircle)
                    .foregroundStyle(.secondary)
            case .installed:
                Label("Codex hooks installed", symbol: .checkmarkCircle)
                    .foregroundStyle(.green)
            case .notInstalled:
                Label("Codex hooks not installed", symbol: .exclamationmarkTriangle)
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
                Button("Install Codex Hooks") { Task { await install() } }
                    .disabled(inFlight)
                    .buttonStyle(.borderedProminent)
            }
        }

        private func refresh() async {
            let installed = await installer.isInstalled()
            await MainActor.run {
                status = installed ? .installed : .notInstalled
            }
        }

        private func install() async {
            inFlight = true
            defer { inFlight = false }
            do {
                try await installer.install()
                await refresh()
            } catch {
                await MainActor.run { lastError = error.localizedDescription }
            }
        }

        private func uninstall() async {
            inFlight = true
            defer { inFlight = false }
            do {
                try await installer.uninstall()
                await refresh()
            } catch {
                await MainActor.run { lastError = error.localizedDescription }
            }
        }
    }

#endif

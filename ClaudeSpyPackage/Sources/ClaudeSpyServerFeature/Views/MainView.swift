import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import SwiftUI

/// The main application view showing available tmux panes
public struct MainView: View {
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings
    @Environment(ExternalServerClient.self) private var serverClient
    @Environment(PairingManager.self) private var pairingManager
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

    /// Refresh interval in seconds
    private let refreshInterval: TimeInterval = 5

    public init() { }

    public var body: some View {
        PaneListView(
            panes: tmuxService.panes,
            isLoading: tmuxService.isRefreshing,
            error: tmuxService.lastError,
            onRefresh: { await refreshPanes() },
            onOpenMirror: { pane in
                windowManager.openMirror(for: pane)
            }
        )
        .navigationTitle("Available Panes")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                connectionStatusView
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await refreshPanes()
                    }
                } label: {
                    Symbols.arrowClockwise.image
                }
                .help("Refresh pane list")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(tmuxService.isRefreshing)
            }
        }
        .task {
            // Initial load
            await refreshPanes()

            // Auto-refresh every 5 seconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { break }
                await refreshPanes()
            }
        }
    }

    // MARK: - Connection Status View

    @ViewBuilder
    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            connectionStatusIcon
                .font(.caption)

            connectionActionButton
        }
    }

    @ViewBuilder
    private var connectionStatusIcon: some View {
        switch serverClient.state {
        case .disconnected:
            Symbols.wifiSlash.image
                .foregroundStyle(.secondary)
                .help("Disconnected from relay server")
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .help("Connecting...")
        case let .reconnecting(attempt):
            ProgressView()
                .controlSize(.small)
                .help("Reconnecting (attempt \(attempt))...")
        case .connected:
            Symbols.wifi.image
                .foregroundStyle(.green)
                .help(serverClient.isIOSConnected
                    ? "Connected - iOS device online"
                    : "Connected - waiting for iOS")
        case let .error(message):
            Symbols.exclamationmarkTriangle.image
                .foregroundStyle(.red)
                .help("Error: \(message)")
        }
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        if !settings.isPaired {
            // Not paired - show generate pair button
            Button("Generate Pair") {
                openSettingsToRemoteAccess()
            }
            .controlSize(.small)
            .help("Open Remote Access settings to pair with iOS")
        } else if serverClient.state.isConnected {
            // Connected - show disconnect button
            Button("Disconnect") {
                Task {
                    await serverClient.disconnect()
                }
            }
            .controlSize(.small)
            .help("Disconnect from relay server")
        } else if case .connecting = serverClient.state {
            // Connecting - no button
            EmptyView()
        } else if case .reconnecting = serverClient.state {
            // Reconnecting - show cancel button
            Button("Cancel") {
                Task {
                    await serverClient.disconnect()
                }
            }
            .controlSize(.small)
            .help("Cancel reconnection attempts")
        } else {
            // Disconnected but paired - show connect button
            Button("Connect") {
                Task {
                    await connectToServer()
                }
            }
            .controlSize(.small)
            .help("Connect to relay server for iOS monitoring")
        }
    }

    // MARK: - Actions

    private func refreshPanes() async {
        await tmuxService.refreshPanes()
    }

    private func connectToServer() async {
        guard
            let pairId = settings.pairId,
            let serverURL = URL(string: settings.externalServerURL),
            let e2eeService
        else {
            return
        }

        let keyInfo = pairingManager.publicKeyInfo
        await serverClient.connect(
            serverURL: serverURL,
            pairId: pairId,
            deviceId: settings.deviceId,
            deviceName: Host.current().localizedName ?? "Mac",
            publicKey: keyInfo.publicKey.base64EncodedString(),
            publicKeyId: keyInfo.keyId,
            e2eeService: e2eeService,
            partnerPublicKey: settings.partnerPublicKey,
            partnerPublicKeyId: settings.partnerPublicKeyId
        )
    }

    private func openSettingsToRemoteAccess() {
        // Set the tab to Remote Access before opening settings
        settings.selectedSettingsTab = .remoteAccess

        // Open the Settings window using macOS selector
        // Note: This uses a private selector that may change in future macOS versions
        let selector = Selector(("showSettingsWindow:"))
        if NSApp.responds(to: selector) {
            NSApp.sendAction(selector, to: nil, from: nil)
        }
    }
}

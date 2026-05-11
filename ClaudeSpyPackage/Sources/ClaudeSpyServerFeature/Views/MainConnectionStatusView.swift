import AppKit
import ClaudeSpyCommon
import SwiftUI

/// Toolbar item showing relay-server connection state plus a context-sensitive
/// action button (Generate Pair / Connect / Disconnect / Cancel).
struct MainConnectionStatusView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    @State private var showingDisconnectConfirmation = false

    var body: some View {
        HStack(spacing: 6) {
            connectionStatusIcon
                .font(.caption)

            connectionActionButton
        }
        .onChange(of: coordinator.connectedViewerManager?.combinedState) { _, _ in
            showingDisconnectConfirmation = false
        }
    }

    @ViewBuilder
    private var connectionStatusIcon: some View {
        let connectionManager = coordinator.connectedViewerManager
        let combinedState = connectionManager?.combinedState ?? .disconnected
        let anyViewerConnected = connectionManager?.anyViewerConnected ?? false

        switch combinedState {
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
                .help(
                    anyViewerConnected
                        ? "Connected - viewer online"
                        : "Connected - waiting for viewer"
                )
        case let .error(message):
            Symbols.exclamationmarkTriangle.image
                .foregroundStyle(.red)
                .help("Error: \(message)")
        }
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        let connectionManager = coordinator.connectedViewerManager
        let combinedState = connectionManager?.combinedState ?? .disconnected

        if !settings.isPaired {
            // Not paired - show generate pair button
            Button("Generate Pair") {
                openSettingsToRemoteAccess()
            }
            .controlSize(.small)
            .help("Open Remote Access settings to pair with iOS")
        } else if combinedState.isConnected {
            // Connected - show disconnect button with confirmation popover
            Button("Disconnect") {
                showingDisconnectConfirmation = true
            }
            .controlSize(.small)
            .help("Disconnect from relay server")
            .popover(isPresented: $showingDisconnectConfirmation, arrowEdge: .bottom) {
                disconnectConfirmationPopover(connectionManager: connectionManager)
            }
        } else if case .connecting = combinedState {
            // Connecting - no button
            EmptyView()
        } else if case .reconnecting = combinedState {
            // Reconnecting - show cancel button
            Button("Cancel") {
                Task {
                    await connectionManager?.disconnectAll()
                }
            }
            .controlSize(.small)
            .help("Cancel reconnection attempts")
        } else if case .error = combinedState {
            // Errored - show retry button (mirrors the disconnected "Connect" path
            // but labeled to reflect that a prior attempt failed)
            Button("Retry") {
                Task {
                    await connectionManager?.connectAll()
                }
            }
            .controlSize(.small)
            .help("Retry connecting to relay server")
        } else {
            // Disconnected but paired - show connect button
            Button("Connect") {
                Task {
                    await connectionManager?.connectAll()
                }
            }
            .controlSize(.small)
            .help("Connect to relay server for iOS monitoring")
        }
    }

    private func disconnectConfirmationPopover(connectionManager: ConnectedViewerManager?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Disconnect from relay server?")
                .font(.headline)
            Text("Paired iOS viewers will stop receiving updates until you reconnect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingDisconnectConfirmation = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Disconnect", role: .destructive) {
                    showingDisconnectConfirmation = false
                    Task {
                        await connectionManager?.disconnectAll()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func openSettingsToRemoteAccess() {
        // Set the tab to Remote Access before opening settings
        settings.selectedSettingsTab = .remoteAccess
        NSApp.setActivationPolicy(.regular)
        openSettings()
        MenuBarExtraView.bringAppToFront()
    }
}

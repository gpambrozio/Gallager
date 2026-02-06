#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftUI

    /// View displaying a remote Claude session from another Mac host.
    ///
    /// Shows session information and status. Terminal streaming will be
    /// added in a future update to enable live viewing of remote sessions.
    struct RemoteSessionView: View {
        let paneId: String
        let session: ClaudeSession
        let host: PairedMacHost

        @Environment(AppCoordinator.self) private var coordinator

        var body: some View {
            VStack(spacing: 24) {
                Spacer()

                // Host icon
                Symbols.desktopcomputer.image
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                // Session info
                VStack(spacing: 8) {
                    Text(session.displayName)
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("Remote session on \(host.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let event = session.latestEvent {
                        HStack(spacing: 6) {
                            Symbols.sparkles.image
                                .foregroundStyle(.purple)
                            Text(event.action.eventName)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if session.needsAttention {
                        Label("Needs attention", symbol: .bellFill)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // Connection status
                connectionStatus

                // Terminal streaming placeholder
                GroupBox {
                    VStack(spacing: 12) {
                        Symbols.terminal.image
                            .font(.title)
                            .foregroundStyle(.secondary)

                        Text("Terminal streaming")
                            .font(.headline)

                        Text("Live terminal view will be available in a future update.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 300)
                    .padding()
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Remote: \(session.displayName)")
        }

        @ViewBuilder
        private var connectionStatus: some View {
            let connection = coordinator.hostConnectionManager?.connection(for: host.id)

            if let connection {
                switch connection.state {
                case .connected where connection.isMacHostConnected:
                    Label("Connected to \(host.macName)", symbol: .checkmarkCircleFill)
                        .foregroundStyle(.green)
                case .connected:
                    Label("Waiting for Mac host", symbol: .wifiSlash)
                        .foregroundStyle(.secondary)
                case .connecting:
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting...")
                    }
                case .reconnecting:
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reconnecting...")
                    }
                case .disconnected:
                    Label("Disconnected", symbol: .wifiSlash)
                        .foregroundStyle(.secondary)
                case .extendedBackoff:
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reconnecting in 5 minutes...")
                    }
                case .error:
                    Label("Connection error", symbol: .exclamationmarkTriangle)
                        .foregroundStyle(.red)
                }
            } else {
                Label("Not connected", symbol: .wifiSlash)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Remote Pane View

    /// View displaying a remote terminal pane from another Mac host.
    struct RemotePaneView: View {
        let pane: PaneInfoMessage
        let host: PairedMacHost

        @Environment(AppCoordinator.self) private var coordinator

        var body: some View {
            VStack(spacing: 24) {
                Spacer()

                Symbols.terminal.image
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(pane.target)
                        .font(.title)
                        .fontWeight(.semibold)
                        .fontDesign(.monospaced)

                    Text("Remote terminal on \(host.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let command = pane.command {
                        Text(command)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let path = pane.currentPath {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text("\(pane.width)x\(pane.height)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                GroupBox {
                    VStack(spacing: 12) {
                        Symbols.keyboard.image
                            .font(.title)
                            .foregroundStyle(.secondary)

                        Text("Terminal streaming")
                            .font(.headline)

                        Text("Live terminal view will be available in a future update.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 300)
                    .padding()
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Remote: \(pane.target)")
        }
    }
#endif

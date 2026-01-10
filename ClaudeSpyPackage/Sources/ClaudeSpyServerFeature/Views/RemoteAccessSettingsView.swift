import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import SwiftUI

/// Settings view for configuring remote access via iOS
public struct RemoteAccessSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PairingManager.self) private var pairingManager
    @Environment(ExternalServerClient.self) private var serverClient
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

    @State private var showCopiedFeedback = false

    public init() { }

    public var body: some View {
        @Bindable var settings = settings

        Form {
            // Connection Status Section
            Section {
                connectionStatusRow
            } header: {
                Text("Connection Status")
            }

            // Pairing Section
            Section {
                pairingContent
            } header: {
                Text("Device Pairing")
            }

            // Server Configuration
            Section {
                TextField("Server URL", text: $settings.externalServerURL)
                    .textFieldStyle(.roundedBorder)

                Toggle("Auto-connect on launch", isOn: $settings.autoConnectToServer)
            } header: {
                Text("Server")
            } footer: {
                Text("The relay server URL (WSS for secure connection)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("Remote Access")
        .onChange(of: pairingManager.state) { oldState, newState in
            // Auto-connect when pairing completes
            if case .paired = newState, case .waitingForPairing = oldState {
                Task {
                    await connectToServer()
                }
            }
        }
    }

    // MARK: - Connection Status Row

    @ViewBuilder
    private var connectionStatusRow: some View {
        HStack(spacing: 12) {
            connectionStatusIcon
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(serverClient.state.statusText)
                    .font(.headline)

                if serverClient.isIOSConnected {
                    HStack(spacing: 4) {
                        Symbols.iphone.image
                            .font(.caption)
                        Text(serverClient.connectedIOSDeviceName ?? "iOS Device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            connectionActionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var connectionStatusIcon: some View {
        switch serverClient.state {
        case .disconnected:
            Symbols.wifiSlash.image
                .foregroundStyle(.secondary)
        case .connecting,
             .reconnecting:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Symbols.wifi.image
                .foregroundStyle(.green)
        case .error:
            Symbols.exclamationmarkTriangle.image
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        if serverClient.state.isConnected {
            Button("Disconnect") {
                Task {
                    await serverClient.disconnect()
                }
            }
        } else if case .connecting = serverClient.state {
            // No button while connecting
            EmptyView()
        } else if case .reconnecting = serverClient.state {
            Button("Cancel") {
                Task {
                    await serverClient.disconnect()
                }
            }
        } else if settings.isPaired {
            Button("Connect") {
                Task {
                    await connectToServer()
                }
            }
            .disabled(settings.pairId == nil)
        }
    }

    // MARK: - Pairing Content

    @ViewBuilder
    private var pairingContent: some View {
        switch pairingManager.state {
        case .unpaired:
            unpairedView

        case .generatingCode:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Generating pairing code...")
            }

        case let .waitingForPairing(code, expiresAt):
            pairingCodeView(code: code, expiresAt: expiresAt)

        case let .paired(_, deviceName):
            pairedView(deviceName: deviceName)

        case let .error(message):
            errorView(message: message)
        }
    }

    @ViewBuilder
    private var unpairedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair your iPhone to monitor Claude sessions remotely.")
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await pairingManager.generatePairingCode()
                }
            } label: {
                Label("Generate Pairing Code", symbol: .linkCircle)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func pairingCodeView(code: String, expiresAt: Date) -> some View {
        VStack(alignment: .center, spacing: 16) {
            Text("Enter this code on your iPhone:")
                .foregroundStyle(.secondary)

            // Large pairing code display
            HStack(spacing: 8) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, char in
                    Text(String(char))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .frame(width: 40, height: 50)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(8)
                }
            }

            // Copy button
            Button {
                copyToClipboard(code)
            } label: {
                Label(showCopiedFeedback ? "Copied!" : "Copy Code", symbol: .docOnClipboard)
            }
            .buttonStyle(.bordered)

            // Expiry countdown
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = expiresAt.timeIntervalSinceNow
                if remaining > 0 {
                    Text("Expires in \(formatTimeRemaining(remaining))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Code expired")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Button("Cancel") {
                pairingManager.cancelPairing()
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func pairedView(deviceName: String) -> some View {
        HStack(spacing: 12) {
            Symbols.checkmarkCircleFill.image
                .font(.title2)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Paired with iOS")
                    .font(.headline)
                Text(deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Unpair") {
                Task {
                    await pairingManager.unpair()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Symbols.exclamationmarkTriangle.image
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
            }

            Button("Try Again") {
                Task {
                    await pairingManager.generatePairingCode()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        showCopiedFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedFeedback = false
        }
    }

    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
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
}

// Preview disabled - E2EEService requires async initialization
// #Preview {
//     RemoteAccessSettingsView()
//         .environment(AppSettings())
//         .environment(PairingManager(settings: AppSettings(), e2eeService: ...))
//         .environment(ExternalServerClient())
// }

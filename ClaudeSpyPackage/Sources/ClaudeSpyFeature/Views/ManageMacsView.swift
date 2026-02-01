#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import SwiftUI

    /// View for managing paired Mac servers.
    ///
    /// Displays a list of paired Macs with connection status and allows
    /// adding new Macs or removing existing pairings.
    struct ManageMacsView: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(ConnectionManager.self) private var connectionManager

        @State private var showPairingSheet = false
        @State private var macToDelete: PairedMac?
        @State private var showDeleteConfirmation = false

        var body: some View {
            List {
                // Paired Macs section
                Section {
                    if settings.pairedMacs.isEmpty {
                        Text("No Macs paired")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.pairedMacs) { mac in
                            MacRowView(
                                mac: mac,
                                connection: connectionManager.connection(for: mac.id)
                            )
                        }
                        .onDelete { indexSet in
                            if let index = indexSet.first {
                                macToDelete = settings.pairedMacs[index]
                                showDeleteConfirmation = true
                            }
                        }
                    }
                } header: {
                    Text("Paired Macs")
                } footer: {
                    Text("Swipe left on a Mac to remove the pairing.")
                }

                // Add Mac section
                Section {
                    Button {
                        showPairingSheet = true
                    } label: {
                        Label("Add Mac", symbol: .plus)
                    }
                }
            }
            .navigationTitle("Manage Macs")
            .sheet(isPresented: $showPairingSheet) {
                AddMacSheet()
            }
            .confirmationDialog(
                "Remove Pairing",
                isPresented: $showDeleteConfirmation,
                presenting: macToDelete
            ) { mac in
                Button("Remove \(mac.displayName)", role: .destructive) {
                    Task {
                        await removeMac(mac)
                    }
                }
                Button("Cancel", role: .cancel) {
                    macToDelete = nil
                }
            } message: { mac in
                Text("This will remove the pairing with \(mac.displayName). You can pair again using a new code from the Mac app.")
            }
        }

        private func removeMac(_ mac: PairedMac) async {
            // Disconnect from this Mac
            await connectionManager.disconnect(from: mac.id)

            // Remove from settings
            settings.removePairing(id: mac.id)

            macToDelete = nil
        }
    }

    // MARK: - Mac Row View

    /// Row view displaying a paired Mac with connection status
    struct MacRowView: View {
        let mac: PairedMac
        let connection: MacConnection?

        var body: some View {
            HStack(spacing: 12) {
                // Mac icon with connection indicator
                ZStack(alignment: .bottomTrailing) {
                    Symbols.laptopcomputer.image
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(Color(.systemBackground), lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(mac.displayName)
                        .font(.headline)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Paired date
                Text(DateFormatters.relativeTime(for: mac.pairedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }

        private var statusColor: Color {
            guard let connection else { return .gray }

            if connection.isMacConnected {
                return .green
            } else if connection.isRelayConnected {
                return .yellow
            } else if case .reconnecting = connection.state {
                return .orange
            } else {
                return .red
            }
        }

        private var statusText: String {
            guard let connection else { return "Not connected" }

            if connection.isMacConnected {
                return "Online"
            } else if connection.isRelayConnected {
                return "Waiting for Mac..."
            } else {
                return connection.state.statusText
            }
        }
    }

    // MARK: - Add Mac Sheet

    /// Sheet for adding a new Mac pairing
    struct AddMacSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSSettings.self) private var settings
        @Environment(ConnectionManager.self) private var connectionManager

        var body: some View {
            NavigationStack {
                if let e2ee = connectionManager.pairingService {
                    PairingView { pairedMac in
                        // Add the new pairing
                        settings.addPairing(pairedMac)

                        // Connect to the new Mac
                        Task {
                            await connectionManager.connect(to: pairedMac, settings: settings)
                        }

                        dismiss()
                    }
                    .e2eeService(e2ee)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                dismiss()
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Encryption Error",
                        image: Symbols.lockTriangleBadgeExclamationmark.rawValue,
                        description: Text("Unable to initialize encryption.")
                    )
                }
            }
        }
    }
#endif

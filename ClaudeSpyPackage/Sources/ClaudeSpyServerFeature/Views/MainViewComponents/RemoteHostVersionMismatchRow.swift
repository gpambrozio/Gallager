import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Sidebar row shown in a remote host section when the host's peerHello handshake
/// failed version compatibility. Replaces the "Host offline" caption so the user
/// can see why this host cannot be reached.
struct RemoteHostVersionMismatchRow: View {
    let host: PairedHost
    let mismatch: VersionCompatibility.VersionMismatch
    let onRetry: () -> Void

    @State private var showingRetryPopover = false

    var body: some View {
        Button {
            showingRetryPopover = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Symbols.arrowUpCircleFill.image
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("host-version-mismatch-row")
        .popover(isPresented: $showingRetryPopover, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(popoverHeading)
                    .font(.headline)
                Text(popoverDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        showingRetryPopover = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button {
                        showingRetryPopover = false
                        onRetry()
                    } label: {
                        Label("Retry", symbol: .arrowClockwise)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 280)
        }
    }

    private var title: String {
        switch mismatch {
        case .weAreTooOld:
            "Update this app"
        case .partnerTooOld:
            "\(host.displayName) needs updating"
        }
    }

    private var detail: String {
        switch mismatch {
        case let .weAreTooOld(required):
            "\(host.displayName) requires version \(required) or later."
        case let .partnerTooOld(partnerVersion):
            partnerVersion.isEmpty
                ? "The host is running an older version and cannot connect."
                : "The host is running version \(partnerVersion) and cannot connect."
        }
    }

    private var popoverHeading: String {
        switch mismatch {
        case .weAreTooOld:
            "Update this app"
        case .partnerTooOld:
            "Retry connection?"
        }
    }

    private var popoverDetail: String {
        switch mismatch {
        case let .weAreTooOld(required):
            "\(host.displayName) requires version \(required) or later. Try again after updating this app."
        case .partnerTooOld:
            "Try connecting again. If \(host.displayName) was updated to a compatible version, the connection will succeed."
        }
    }
}

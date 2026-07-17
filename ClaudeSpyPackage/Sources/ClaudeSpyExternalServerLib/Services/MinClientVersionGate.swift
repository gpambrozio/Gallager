import ClaudeSpyNetworking
import Foundation

/// Optional relay-side minimum-client-version gate (issue #659).
///
/// The relay is normally a dumb E2EE router that never inspects versions — the
/// host and viewer negotiate compatibility peer-to-peer inside the encrypted
/// `peerHello`, which the relay cannot read. That handshake only force-upgrades
/// a client when its *peer* is new enough to tell it to; it can't rescue an
/// old-host + old-viewer pair, and it can't let the relay refuse a client
/// independently of its peer.
///
/// This gate closes that gap with a *server-visible* backstop: clients report
/// their marketing version in the WebSocket `clientVersion` query parameter
/// (part of the pre-E2EE upgrade request, readable by the relay), and the relay
/// independently refuses any client below `minVersion` — closing the socket with
/// a typed `CLIENT_TOO_OLD` error (`ErrorMessage.clientTooOld`).
///
/// `nil` from `fromEnvironment` means the gate is disabled, which is the default:
/// self-hosted relays leave `MIN_CLIENT_VERSION` unset and stay zero-config.
///
/// ## Known limitation
/// The relay can only enforce against clients new enough to *report* their
/// version. Builds predating the `clientVersion` field send nothing, and
/// `rejectUnknown` picks the policy for them:
/// - `false` (default) — let unknown-version clients through, so enabling the
///   gate doesn't break the entire pre-reporting fleet at once. Clean enforcement
///   then becomes available for the *next* wire break onward.
/// - `true` — refuse unknown-version clients too. Only safe once a
///   version-reporting build is universal.
struct MinClientVersionGate: Equatable {
    /// Minimum client marketing version accepted by the relay (e.g. "2.1").
    let minVersion: String

    /// Whether to refuse clients that don't report a version at all (see the
    /// type-level "Known limitation" note). Defaults to `false`.
    let rejectUnknown: Bool

    /// Builds a gate from the environment, or `nil` when `MIN_CLIENT_VERSION` is
    /// unset/blank (gate disabled). `MIN_CLIENT_VERSION_REJECT_UNKNOWN` opts into
    /// rejecting unknown-version clients (`1`/`true`/`yes`, case-insensitive).
    static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> MinClientVersionGate? {
        func trimmed(_ key: String) -> String? {
            guard
                let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty else { return nil }
            return raw
        }

        guard let minVersion = trimmed("MIN_CLIENT_VERSION") else { return nil }

        let rejectUnknown = trimmed("MIN_CLIENT_VERSION_REJECT_UNKNOWN")
            .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false

        return MinClientVersionGate(minVersion: minVersion, rejectUnknown: rejectUnknown)
    }

    /// Whether a client reporting `clientVersion` may connect. A `nil` or empty
    /// value means the client didn't report a version (an old build, or a query
    /// param that was absent/blank) and is decided by `rejectUnknown`; a reported
    /// version is compared numerically against `minVersion`.
    func allows(clientVersion: String?) -> Bool {
        guard let clientVersion, !clientVersion.isEmpty else {
            return !rejectUnknown
        }
        return VersionCompatibility.isCompatible(version: clientVersion, minimum: minVersion)
    }
}

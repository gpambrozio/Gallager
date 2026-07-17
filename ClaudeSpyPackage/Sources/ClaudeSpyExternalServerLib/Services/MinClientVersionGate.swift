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
///
/// Thrown at boot when `MIN_CLIENT_VERSION` is set but not a clean dot-separated
/// numeric version — fail-loud rather than silently running a gate that logs as
/// "enabled" while accepting almost every client (see the note on `fromEnvironment`).
enum MinClientVersionGateError: Error, CustomStringConvertible {
    case malformedVersion(String)

    var description: String {
        switch self {
        case let .malformedVersion(raw):
            "MIN_CLIENT_VERSION must be a dot-separated numeric version like \"2.1\" (got \"\(raw)\")"
        }
    }
}

struct MinClientVersionGate: Equatable {
    /// Minimum client marketing version accepted by the relay (e.g. "2.1").
    let minVersion: String

    /// Whether to refuse clients that don't report a version at all (see the
    /// type-level "Known limitation" note). Defaults to `false`.
    let rejectUnknown: Bool

    /// Builds a gate from the environment, or `nil` when `MIN_CLIENT_VERSION` is
    /// unset/blank (gate disabled). `MIN_CLIENT_VERSION_REJECT_UNKNOWN` opts into
    /// rejecting unknown-version clients (`1`/`true`/`yes`, case-insensitive).
    ///
    /// Throws `MinClientVersionGateError.malformedVersion` when `MIN_CLIENT_VERSION`
    /// is set but isn't a clean dot-separated numeric version. `VersionCompatibility`
    /// silently coerces non-numeric components to `0`, so a typo like `v2.1` would
    /// otherwise parse to `"0.1"` — leaving the gate logged as "enabled" while it
    /// accepts almost every client. Rejecting it at boot forces the operator to fix
    /// the value instead of unknowingly running an ineffective gate.
    static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MinClientVersionGate? {
        func trimmed(_ key: String) -> String? {
            guard
                let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty else { return nil }
            return raw
        }

        guard let minVersion = trimmed("MIN_CLIENT_VERSION") else { return nil }

        guard isWellFormedVersion(minVersion) else {
            throw MinClientVersionGateError.malformedVersion(minVersion)
        }

        let rejectUnknown = trimmed("MIN_CLIENT_VERSION_REJECT_UNKNOWN")
            .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false

        return MinClientVersionGate(minVersion: minVersion, rejectUnknown: rejectUnknown)
    }

    /// Whether `version` is a clean dot-separated numeric version (e.g. `2`, `2.1`,
    /// `2.1.0`). Every component must be a non-empty run of ASCII digits — exactly
    /// the shape `VersionCompatibility.compare` reads without silently zeroing a
    /// component, so `v2.1`, `2.x`, `2..1` and `2.` are all rejected.
    static func isWellFormedVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// Whether a client reporting `clientVersion` may connect. A `nil`, empty, or
    /// whitespace-only value means the client didn't report a version (an old build,
    /// or a query param that was absent/blank) and is decided by `rejectUnknown`; a
    /// reported version is compared numerically against `minVersion`. The reported
    /// version is trimmed first, mirroring the trimming `minVersion` gets in
    /// `fromEnvironment`.
    func allows(clientVersion: String?) -> Bool {
        let trimmed = clientVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return !rejectUnknown
        }
        return VersionCompatibility.isCompatible(version: trimmed, minimum: minVersion)
    }
}

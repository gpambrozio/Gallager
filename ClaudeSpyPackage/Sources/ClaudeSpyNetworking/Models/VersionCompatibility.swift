import Foundation

/// Version compatibility constants and helpers for host/viewer pairing.
///
/// Each side sends its own `appVersion` plus the minimum partner version it is
/// willing to talk to. When a mismatch is detected the side running the older
/// version disconnects without retrying and surfaces a "please update" message.
public enum VersionCompatibility {
    /// Default minimum viewer version accepted by a host running this build.
    ///
    /// Bump this when the host introduces a protocol change that older viewers
    /// cannot handle.
    ///
    /// Bumped 2026-05-24 (1.23 → 1.33) for the plugin-system flag-day release;
    /// v1.33+ peers refuse to pair with v1.32 or older.
    public static let defaultMinRequiredViewerVersion = "1.33"

    /// Default minimum host version accepted by a viewer running this build.
    ///
    /// Bump this when the viewer introduces a protocol change that older hosts
    /// cannot handle.
    ///
    /// Bumped 2026-05-24 (1.23 → 1.33) for the plugin-system flag-day release;
    /// v1.33+ peers refuse to pair with v1.32 or older.
    public static let defaultMinRequiredHostVersion = "1.33"

    /// Test-only overrides set from launch arguments during E2E scenarios.
    /// Regular production code should never set these.
    public nonisolated(unsafe) static var appVersionOverride: String?
    public nonisolated(unsafe) static var minRequiredPartnerVersionOverride: String?

    /// Minimum viewer version accepted by a host running this build.
    public static var minRequiredViewerVersion: String {
        minRequiredPartnerVersionOverride ?? defaultMinRequiredViewerVersion
    }

    /// Minimum host version accepted by a viewer running this build.
    public static var minRequiredHostVersion: String {
        minRequiredPartnerVersionOverride ?? defaultMinRequiredHostVersion
    }

    /// Current marketing version of this build, read from the main bundle.
    /// Falls back to an empty string when the info dictionary is unavailable.
    /// Can be overridden via `appVersionOverride` for E2E scenarios.
    public static var currentAppVersion: String {
        if let override = appVersionOverride { return override }
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// Returns `true` when `version` is greater than or equal to `minimum`.
    /// An empty `version` is always considered incompatible.
    public static func isCompatible(version: String, minimum: String) -> Bool {
        guard !version.isEmpty else { return false }
        return compare(version, minimum) != .orderedAscending
    }

    /// Compares two dot-separated numeric version strings (e.g. "1.23" vs "1.24").
    /// Non-numeric components are treated as zero.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsComponents = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsComponents = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhsComponents.count, rhsComponents.count)
        for index in 0..<count {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue < rhsValue { return .orderedAscending }
            if lhsValue > rhsValue { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Peer Compatibility

    /// Role of the partner being validated — determines which `minRequired*Version`
    /// constant to consult when checking whether the partner is too old.
    public enum PartnerRole: Sendable {
        case host
        case viewer
    }

    /// Result of a version compatibility check between this client and its peer.
    public enum VersionMismatch: Sendable, Equatable {
        /// Our version is below what the partner requires of us.
        case weAreTooOld(required: String)
        /// The partner's version is below what we require of it.
        case partnerTooOld(partnerVersion: String)
    }

    /// Check whether a peer with the given version info is compatible with this
    /// client. Returns `nil` when both sides are compatible; otherwise returns
    /// the specific mismatch so the caller can render an appropriate message.
    ///
    /// An empty `partnerAppVersion` is treated as incompatible via
    /// `isCompatible(version:minimum:)`, which rejects empty versions outright.
    /// An empty `partnerMinRequiredOurVersion` is treated as "partner places no
    /// requirement on us" and skips the `.weAreTooOld` branch.
    public static func checkCompatibility(
        partnerAppVersion: String,
        partnerMinRequiredOurVersion: String,
        partnerRole: PartnerRole
    ) -> VersionMismatch? {
        let ourVersion = currentAppVersion
        let ourMinRequired: String = switch partnerRole {
        case .host: minRequiredHostVersion
        case .viewer: minRequiredViewerVersion
        }

        if
            !partnerMinRequiredOurVersion.isEmpty,
            !isCompatible(version: ourVersion, minimum: partnerMinRequiredOurVersion) {
            return .weAreTooOld(required: partnerMinRequiredOurVersion)
        }

        if !isCompatible(version: partnerAppVersion, minimum: ourMinRequired) {
            return .partnerTooOld(partnerVersion: partnerAppVersion)
        }

        return nil
    }
}

import Foundation

/// App Group identifier shared between the iOS app and Notification Service Extension.
///
/// Must match the value declared in the `com.apple.security.application-groups`
/// entitlement of every target that needs access to the shared container.
public let sharedAppGroupIdentifier = "group.br.eng.gustavo.claudespy"

/// Mirrors a `pairId → display name` mapping into App Group `UserDefaults` so the
/// Notification Service Extension can label notifications by the host that sent them.
///
/// The extension cannot decrypt the payload when a notification fails to decrypt
/// (missing session key, version mismatch, etc.), so the host name has to be
/// available out-of-band. We write it from the iOS app whenever the paired host
/// list changes, and read it back from the extension. The mapping stays inside
/// the App Group container and never leaves the device.
public enum PairedHostNameStore {
    private static let storageKey = "pairedHostDisplayNames"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: sharedAppGroupIdentifier)
    }

    /// Replace the stored mapping with the provided one.
    public static func save(_ mapping: [String: String]) {
        defaults?.set(mapping, forKey: storageKey)
    }

    /// Look up the display name for the given pair ID, if previously saved.
    public static func displayName(for pairId: String) -> String? {
        let mapping = defaults?.dictionary(forKey: storageKey) as? [String: String]
        return mapping?[pairId]
    }
}

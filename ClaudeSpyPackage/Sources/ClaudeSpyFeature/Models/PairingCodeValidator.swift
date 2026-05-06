import Foundation

/// Validation helpers for pairing codes shown in the host app.
///
/// Lives outside any `#if os(iOS)` block so its logic can be unit-tested on
/// any platform — the actual clipboard reading is iOS-only and lives in
/// `PairingView`.
enum PairingCodeValidator {
    static let length = 6

    /// Returns a normalized pairing code if `raw` contains exactly six
    /// alphabetic characters (after trimming whitespace), otherwise nil.
    static func pairingCode(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == length, trimmed.allSatisfy(\.isLetter) else {
            return nil
        }
        return trimmed.uppercased()
    }
}

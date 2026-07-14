import Foundation

/// Thrown at boot for misconfigured licensing env — fail-loud rather than
/// silently running a production relay with enforcement half-configured.
enum LicensingConfigurationError: Error, CustomStringConvertible {
    case incomplete(String)

    var description: String {
        switch self {
        case let .incomplete(detail):
            "Licensing misconfigured: \(detail). Set BOTH LEMONSQUEEZY_STORE_ID and " +
                "LEMONSQUEEZY_PRODUCT_ID to integers, or neither."
        }
    }
}

/// Relay-side licensing configuration. `nil` from `fromEnvironment` means
/// licensing is disabled and every entitlement check short-circuits to allowed.
struct LicensingConfiguration: Sendable, Equatable {
    let storeId: Int
    let productId: Int
    let trialDays: Int
    let revalidateHours: Int
    let graceDays: Int
    let apiBaseURL: String

    static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LicensingConfiguration? {
        func trimmed(_ key: String) -> String? {
            guard
                let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty else { return nil }
            return raw
        }

        let storeRaw = trimmed("LEMONSQUEEZY_STORE_ID")
        let productRaw = trimmed("LEMONSQUEEZY_PRODUCT_ID")

        if storeRaw == nil, productRaw == nil { return nil }

        guard let storeRaw, let productRaw else {
            throw LicensingConfigurationError.incomplete("only one of the two ids is set")
        }
        guard let storeId = Int(storeRaw), let productId = Int(productRaw) else {
            throw LicensingConfigurationError.incomplete("ids must be integers")
        }

        return LicensingConfiguration(
            storeId: storeId,
            productId: productId,
            trialDays: trimmed("TRIAL_DAYS").flatMap(Int.init) ?? 7,
            revalidateHours: trimmed("LICENSE_REVALIDATE_HOURS").flatMap(Int.init) ?? 24,
            graceDays: trimmed("LICENSE_GRACE_DAYS").flatMap(Int.init) ?? 7,
            apiBaseURL: trimmed("LEMONSQUEEZY_API_BASE") ?? "https://api.lemonsqueezy.com"
        )
    }
}

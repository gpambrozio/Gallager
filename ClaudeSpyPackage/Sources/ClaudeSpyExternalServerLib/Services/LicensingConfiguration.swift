import Foundation

/// Thrown at boot for misconfigured licensing env — fail-loud rather than
/// silently running a production relay with enforcement half-configured.
enum LicensingConfigurationError: Error, CustomStringConvertible {
    case incomplete(String)

    var description: String {
        switch self {
        case let .incomplete(detail):
            "Licensing misconfigured: \(detail)"
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

        func intOrDefault(_ key: String, default defaultValue: Int) throws -> Int {
            guard let raw = trimmed(key) else { return defaultValue }
            guard let value = Int(raw) else {
                throw LicensingConfigurationError.incomplete("\(key) must be an integer (got \"\(raw)\")")
            }
            return value
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

        return try LicensingConfiguration(
            storeId: storeId,
            productId: productId,
            trialDays: intOrDefault("TRIAL_DAYS", default: 7),
            revalidateHours: intOrDefault("LICENSE_REVALIDATE_HOURS", default: 24),
            graceDays: intOrDefault("LICENSE_GRACE_DAYS", default: 7),
            apiBaseURL: trimmed("LEMONSQUEEZY_API_BASE") ?? "https://api.lemonsqueezy.com"
        )
    }
}

import Foundation

/// Errors from polling operations
public enum PollingError: Error, LocalizedError {
    case timedOut(description: String)

    public var errorDescription: String? {
        switch self {
        case let .timedOut(description):
            "Timed out waiting for: \(description)"
        }
    }
}

/// Generic polling helpers for waiting on conditions
public enum Polling {
    /// Wait until a condition returns a non-nil value
    public static func waitFor<T: Sendable>(
        description: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.5,
        condition: @Sendable () async throws -> T?
    ) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(timeout)

        while ContinuousClock.now < deadline {
            if let result = try await condition() {
                return result
            }
            try await Task.sleep(for: .milliseconds(Int(pollInterval * 1_000)))
        }

        throw PollingError.timedOut(description: description)
    }

    /// Wait until a boolean condition is true
    public static func waitUntil(
        description: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.5,
        condition: @Sendable () async throws -> Bool
    ) async throws {
        let _: Bool = try await waitFor(
            description: description,
            timeout: timeout,
            pollInterval: pollInterval
        ) {
            try await condition() ? true : nil
        }
    }
}

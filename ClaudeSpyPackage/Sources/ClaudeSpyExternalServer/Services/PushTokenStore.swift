import Foundation
import Logging

/// Stores push notification tokens associated with pair IDs
actor PushTokenStore {
    /// Tokens indexed by pairId
    private var tokens: [String: String] = [:]

    /// Directory where push-tokens.json is stored
    private let dataDirectory: URL

    private let logger = Logger(label: "push-token-store")

    /// File URL for push-tokens.json
    private var tokensFileURL: URL {
        dataDirectory.appendingPathComponent("push-tokens.json")
    }

    // MARK: - Initialization

    init(dataDirectory: URL? = nil) {
        // Use provided directory, or fall back to environment variable, or current directory
        let resolvedDirectory: URL
        if let dir = dataDirectory {
            resolvedDirectory = dir
        } else if let envPath = ProcessInfo.processInfo.environment["DATA_DIRECTORY"] {
            resolvedDirectory = URL(fileURLWithPath: envPath)
        } else {
            resolvedDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        self.dataDirectory = resolvedDirectory

        // Compute file URL before actor isolation kicks in
        let fileURL = resolvedDirectory.appendingPathComponent("push-tokens.json")

        // Load tokens synchronously during init
        self.tokens = Self.loadTokensSync(from: fileURL, logger: logger)
    }

    /// Synchronous load for use during init
    private static func loadTokensSync(from url: URL, logger: Logger) -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("No existing push tokens file found at \(url.path)")
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let tokens = try JSONDecoder().decode([String: String].self, from: data)
            logger.info("Loaded \(tokens.count) push tokens from disk")
            return tokens
        } catch {
            logger.error("Failed to load push tokens: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - Public API

    /// Register a push token for a pair
    func registerToken(_ token: String, for pairId: String) {
        tokens[pairId] = token
        saveTokens()
        logger.info("Registered push token for pair", metadata: ["pairId": "\(pairId)"])
    }

    /// Get the push token for a pair
    func getToken(for pairId: String) -> String? {
        tokens[pairId]
    }

    /// Remove the push token for a pair
    func removeToken(for pairId: String) {
        tokens.removeValue(forKey: pairId)
        saveTokens()
        logger.info("Removed push token for pair", metadata: ["pairId": "\(pairId)"])
    }

    /// Check if a pair has a registered push token
    func hasToken(for pairId: String) -> Bool {
        tokens[pairId] != nil
    }

    // MARK: - Private Helpers

    private func saveTokens() {
        do {
            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tokens)
            try data.write(to: tokensFileURL, options: .atomic)
            logger.debug("Saved \(tokens.count) push tokens to disk")
        } catch {
            logger.error("Failed to save push tokens: \(error.localizedDescription)")
        }
    }
}

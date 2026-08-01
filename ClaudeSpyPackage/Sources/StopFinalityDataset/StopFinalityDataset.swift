import Foundation

// MARK: - StopFinalityCase

/// One labeled stop-finality example: the `last_assistant_message` of a real
/// (or realistic) Claude Code `Stop` hook plus its ground-truth verdict.
public struct StopFinalityCase: Codable, Sendable, Equatable, Identifiable {
    public enum Expected: String, Codable, Sendable {
        case waiting
        case final
    }

    public enum Source: String, Codable, Sendable {
        /// Committed regression case (past field failures + tuned shapes).
        case seed
        /// Harvested from local session transcripts; never committed.
        case mined
    }

    public let id: String
    public let message: String
    public let expected: Expected
    public let source: Source
    public let notes: String?

    public init(
        id: String,
        message: String,
        expected: Expected,
        source: Source,
        notes: String? = nil
    ) {
        self.id = id
        self.message = message
        self.expected = expected
        self.source = source
        self.notes = notes
    }
}

// MARK: - StopFinalityDataset

/// Loads the two dataset halves: committed seeds (bundled resource) and the
/// local, never-committed mined set (spec 2026-07-30 — the repo is heading
/// public and mined messages are verbatim session excerpts).
public enum StopFinalityDataset {
    /// Absolute-path override for the mined dataset location.
    public static let minedPathEnvVar = "STOP_FINALITY_MINED_DATASET"

    public static var minedURL: URL {
        if let override = ProcessInfo.processInfo.environment[minedPathEnvVar] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gallager/eval/stop-finality-mined.json")
    }

    public static func seeds() throws -> [StopFinalityCase] {
        guard let url = Bundle.module.url(forResource: "seed-cases", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "seed-cases.json missing from StopFinalityDataset bundle",
            ])
        }
        return try JSONDecoder().decode([StopFinalityCase].self, from: Data(contentsOf: url))
    }

    /// `nil` when the mined file is absent — callers announce the skip loudly
    /// instead of silently scoring seeds only.
    public static func mined() throws -> [StopFinalityCase]? {
        let url = minedURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([StopFinalityCase].self, from: Data(contentsOf: url))
    }
}

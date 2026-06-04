#if os(macOS)
    import Foundation
    import GallagerPluginProtocol

    /// A per-plugin file log sink backing `PluginHost.log` (spec §15). Appends
    /// `LogLine`s to `<stateDir>/logs/sidecar.log`, rotating to `sidecar.log.1`
    /// once the live file crosses 5 MB.
    ///
    /// An `actor` so concurrent `log(_:)` calls from a core (and the dispatcher)
    /// serialize without locks. Every file operation is best-effort and trap-free:
    /// a logging failure must never bring down the runtime.
    public actor PluginLogSink {
        /// Rotate once the live file exceeds this size (spec §15).
        public static let maxBytes = 5 * 1_024 * 1_024

        private let logFileURL: URL
        private let logDirURL: URL
        private let maxBytes: Int
        private let fileManager = FileManager.default
        private let formatter: ISO8601DateFormatter

        /// - Parameters:
        ///   - logFileURL: The live log file (`.../logs/sidecar.log`).
        ///   - maxBytes: Rotation threshold; defaults to 5 MB.
        public init(logFileURL: URL, maxBytes: Int = PluginLogSink.maxBytes) {
            self.logFileURL = logFileURL
            self.logDirURL = logFileURL.deletingLastPathComponent()
            self.maxBytes = maxBytes
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            self.formatter = formatter
        }

        /// Append one structured line. Format: `<ISO8601> [<LEVEL>] <message>\n`.
        public func append(_ line: LogLine) {
            let formatted = "\(formatter.string(from: Date())) [\(line.level.rawValue.uppercased())] \(line.message)\n"
            let data = Data(formatted.utf8)
            ensureLogDirectory()
            rotateIfNeeded(addingBytes: data.count)
            write(data)
        }

        // MARK: - Private

        private func ensureLogDirectory() {
            guard !fileManager.fileExists(atPath: logDirURL.path) else { return }
            try? fileManager.createDirectory(at: logDirURL, withIntermediateDirectories: true)
        }

        /// Rotate `sidecar.log` → `sidecar.log.1` if appending `addingBytes` would
        /// push the live file past `maxBytes`. One generation is kept (the previous
        /// rotated file is overwritten).
        private func rotateIfNeeded(addingBytes: Int) {
            let currentSize = fileSize(logFileURL)
            guard currentSize + addingBytes > maxBytes, currentSize > 0 else { return }

            let rotatedURL = logFileURL.appendingPathExtension("1")
            // Best-effort: remove a stale rotated file, then move the live one.
            try? fileManager.removeItem(at: rotatedURL)
            do {
                try fileManager.moveItem(at: logFileURL, to: rotatedURL)
            } catch {
                // If the move fails (e.g. cross-volume), truncate the live file so
                // it cannot grow without bound. Best-effort; ignore failure.
                try? Data().write(to: logFileURL)
            }
        }

        private func write(_ data: Data) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                // File doesn't exist yet (or was just rotated away) — create it.
                try? data.write(to: logFileURL)
            }
        }

        private func fileSize(_ url: URL) -> Int {
            guard
                let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                let size = attrs[.size] as? Int
            else {
                return 0
            }
            return size
        }
    }
#endif

import Foundation
import Logging

// MARK: - SidecarLogFile

/// Per-plugin stderr capture, rotated by byte count.
///
/// One sidecar's stderr stream flows into `append(_:)` line by line; when the
/// active file grows past `maxBytesRetained` it's renamed to `sidecar.log.1`
/// (a previous `.1` is dropped) and a fresh file takes over. The failure
/// banner UI (Spec §12) calls `lastLines(_:)` to surface the trailing N lines
/// when a plugin gets auto-disabled.
///
/// Layout — both files live under the per-plugin logs directory passed in at
/// init time:
/// ```
/// <logsDir>/
///   sidecar.log
///   sidecar.log.1   ← previous file, kept until next rotation
/// ```
public actor SidecarLogFile {
    // MARK: - Configuration

    /// Directory containing `sidecar.log`. Created lazily on first append.
    public let logsDir: URL

    /// Plugin id — used for diagnostic logging only; not in the on-disk path.
    public let pluginID: String

    private let maxBytesRetained: Int
    private let logger: Logger

    // MARK: - State

    /// Currently open append handle, or `nil` if no append has happened yet.
    /// `append`/`rotateIfNeeded` lazily open it on first write.
    private var handle: FileHandle?

    /// Byte count of the active file. Cached so we don't `stat` on every
    /// append. Updated by every successful write and reset on rotation.
    private var currentBytes = 0

    /// Optional task draining a `Pipe.fileHandleForReading` into `append`.
    /// Held so we can cancel it during teardown.
    private var stderrTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        logsDir: URL,
        pluginID: String,
        maxBytesRetained: Int = 5 * 1_024 * 1_024,
        logger: Logger? = nil
    ) {
        self.logsDir = logsDir
        self.pluginID = pluginID
        self.maxBytesRetained = maxBytesRetained
        self.logger = logger ?? Logger(label: "gallager.plugin.log.\(pluginID)")
    }

    deinit {
        // We cannot await on the actor's isolated state from deinit. The
        // stderr task and handle are best-effort cleaned up via `close()`
        // before the actor is dropped.
    }

    // MARK: - Public API

    /// Append one line, newline-terminating it if missing. Triggers rotation
    /// if the file would exceed `maxBytesRetained`.
    public func append(_ line: String) async {
        let payload = line.hasSuffix("\n") ? line : line + "\n"
        let data = Data(payload.utf8)
        do {
            try writeData(data)
        } catch {
            logger.warning("sidecar log write failed: \(error)")
        }
    }

    /// Wire a `Pipe.fileHandleForReading` so every line of stderr ends up in
    /// this log. Safe to call once; calling again replaces the previous task.
    public func attachStderrPipe(_ pipe: Pipe) {
        stderrTask?.cancel()
        let reader = pipe.fileHandleForReading
        stderrTask = Task { [weak self] in
            do {
                for try await line in reader.bytes.lines {
                    guard !Task.isCancelled else { break }
                    await self?.append(line)
                }
            } catch {
                // `bytes.lines` throws on cancellation / file closed —
                // expected during teardown. Logged at debug level.
                await self?.logger.debug("stderr stream ended: \(error)")
            }
        }
    }

    /// Read the last `n` lines from the active log file. If the file is
    /// shorter than `n` lines, returns whatever's there. The rotated file
    /// (`.1`) is intentionally skipped — the banner only needs recent context.
    public func lastLines(_ n: Int) throws -> [String] {
        guard n > 0 else { return [] }
        let url = activeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        // Split on \n; a trailing newline gives an empty final element which
        // we drop so callers don't see a phantom blank line.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        if lines.count <= n { return lines }
        return Array(lines.suffix(n))
    }

    /// Flush, close, and stop the stderr draining task. Idempotent.
    public func close() {
        stderrTask?.cancel()
        stderrTask = nil
        if let handle {
            try? handle.synchronize()
            try? handle.close()
        }
        handle = nil
    }

    // MARK: - Internals

    private var activeURL: URL {
        logsDir.appendingPathComponent("sidecar.log")
    }

    private var rotatedURL: URL {
        logsDir.appendingPathComponent("sidecar.log.1")
    }

    /// Ensure the logs directory exists and the active handle is open.
    private func ensureHandle() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(
            at: logsDir,
            withIntermediateDirectories: true
        )
        let url = activeURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            currentBytes = 0
        } else {
            // Pick up where a previous run left off — the cached byte count
            // would be stale if the actor was re-created.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs?[.size] as? NSNumber {
                currentBytes = size.intValue
            }
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        return h
    }

    /// Write payload, rotating first if adding it would push past the cap.
    private func writeData(_ data: Data) throws {
        // Rotate BEFORE writing so the active file never exceeds the cap —
        // even by a few bytes. Matches the spec's "5 MB max retained" wording.
        if currentBytes + data.count > maxBytesRetained, currentBytes > 0 {
            try rotate()
        }
        let h = try ensureHandle()
        try h.write(contentsOf: data)
        currentBytes += data.count
    }

    /// Close the active handle, rename `sidecar.log` → `sidecar.log.1`
    /// (dropping any older `.1`), and reopen a fresh active file.
    private func rotate() throws {
        if let handle {
            try? handle.synchronize()
            try? handle.close()
        }
        handle = nil

        let active = activeURL
        let rotated = rotatedURL

        // Drop the older rotated copy if present — we retain only one
        // generation, per the spec.
        if FileManager.default.fileExists(atPath: rotated.path) {
            try FileManager.default.removeItem(at: rotated)
        }
        if FileManager.default.fileExists(atPath: active.path) {
            try FileManager.default.moveItem(at: active, to: rotated)
        }

        // Recreate the active file so the next `ensureHandle` finds it.
        FileManager.default.createFile(atPath: active.path, contents: nil)
        currentBytes = 0
    }
}

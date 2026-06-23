import Foundation
import Logging

/// Mirrors a child's stderr to `<logDir>/stderr.log`, rotating at 5 MB (one
/// generation), and keeps the last `tailCapacity` lines in memory for the
/// crash-loop banner (spec §5 step 4). An actor so the readabilityHandler's
/// appends serialize. Best-effort and trap-free.
public actor SidecarStderrLog {
    public static let maxBytes = 5 * 1_024 * 1_024
    private let fileURL: URL
    private let tailCapacity = 50
    private var tail: [String] = []
    private let fm = FileManager.default

    public init(logDir: URL) {
        self.fileURL = logDir.appendingPathComponent("stderr.log")
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        rotateIfNeeded(adding: data.count)
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
        for line in (String(bytes: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            tail.append(String(line))
            if tail.count > tailCapacity { tail.removeFirst(tail.count - tailCapacity) }
        }
    }

    public func lastLines() -> [String] {
        tail
    }

    private func rotateIfNeeded(adding: Int) {
        guard
            let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
            size + adding > Self.maxBytes,
            size > 0
        else { return }
        let rotated = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        do { try fm.moveItem(at: fileURL, to: rotated) } catch { try? Data().write(to: fileURL) }
    }
}

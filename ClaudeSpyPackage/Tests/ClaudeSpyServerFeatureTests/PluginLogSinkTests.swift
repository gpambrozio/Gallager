#if os(macOS)
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("PluginLogSink")
    struct PluginLogSinkTests {
        private func makeTempLogURL() -> URL {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-log-\(UUID().uuidString)")
                .appendingPathComponent("logs")
                .appendingPathComponent("sidecar.log")
        }

        @Test("append writes the line, creating the log directory on demand")
        func appendWritesLine() async throws {
            let logURL = makeTempLogURL()
            defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().deletingLastPathComponent()) }

            let sink = PluginLogSink(logFileURL: logURL)
            await sink.append(LogLine(level: .info, message: "hello world"))

            let contents = try String(contentsOf: logURL, encoding: .utf8)
            #expect(contents.contains("[INFO]"))
            #expect(contents.contains("hello world"))
            #expect(contents.hasSuffix("\n"))
        }

        @Test("multiple appends accumulate")
        func multipleAppends() async throws {
            let logURL = makeTempLogURL()
            defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().deletingLastPathComponent()) }

            let sink = PluginLogSink(logFileURL: logURL)
            await sink.append(LogLine(level: .debug, message: "one"))
            await sink.append(LogLine(level: .warn, message: "two"))

            let contents = try String(contentsOf: logURL, encoding: .utf8)
            let lines = contents.split(separator: "\n")
            #expect(lines.count == 2)
            #expect(contents.contains("[DEBUG]"))
            #expect(contents.contains("[WARN]"))
        }

        @Test("rotation at the size threshold moves the live file to .1")
        func rotatesAtThreshold() async throws {
            let logURL = makeTempLogURL()
            defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().deletingLastPathComponent()) }

            // Tiny threshold so a couple of lines trigger rotation.
            let sink = PluginLogSink(logFileURL: logURL, maxBytes: 64)

            // First line creates the file (below threshold).
            await sink.append(LogLine(level: .info, message: "first line that is reasonably long to fill space"))
            // Second line crosses the threshold → rotation should occur before this write.
            await sink.append(LogLine(level: .info, message: "second line crossing the limit now"))

            let rotatedURL = logURL.appendingPathExtension("1")
            #expect(FileManager.default.fileExists(atPath: rotatedURL.path))

            // The rotated file holds the first line; the live file holds the second.
            let rotated = try String(contentsOf: rotatedURL, encoding: .utf8)
            let live = try String(contentsOf: logURL, encoding: .utf8)
            #expect(rotated.contains("first line"))
            #expect(live.contains("second line"))
            #expect(!live.contains("first line"))
        }

        @Test("a brand-new small write does not rotate")
        func noRotationOnFirstSmallWrite() async {
            let logURL = makeTempLogURL()
            defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().deletingLastPathComponent()) }

            let sink = PluginLogSink(logFileURL: logURL, maxBytes: 64)
            await sink.append(LogLine(level: .info, message: "short"))

            #expect(!FileManager.default.fileExists(atPath: logURL.appendingPathExtension("1").path))
        }
    }
#endif

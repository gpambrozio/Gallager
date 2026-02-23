#if os(macOS)
    import AppKit
    import Foundation
    import Logging
    import UniformTypeIdentifiers

    // MARK: - Recording I/O Actor

    /// Handles all file I/O for session recording off the main actor.
    private actor RecordingFileWriter {
        private var fileHandle: FileHandle?
        private var tempFileURL: URL?
        private var startTime: ContinuousClock.Instant?
        private var accumulatedBytes = 0
        private let logger = Logger(label: "com.claudespy.sessionrecorder")

        deinit {
            try? fileHandle?.close()
            if let url = tempFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        struct RecordingHeader: Codable {
            let version: Int
            let width: Int
            let height: Int
            let timestamp: Int
            let target: String
            let env: [String: String]
        }

        /// Opens a temp file and writes the NDJSON header. Returns the initial file size.
        func open(
            paneId: String,
            target: String,
            width: Int,
            height: Int,
            initialContent: Data?
        ) throws -> URL {
            let sanitizedId = paneId.trimmingCharacters(in: CharacterSet(charactersIn: "%"))
            let tempDir = FileManager.default.temporaryDirectory
            let filename = "claudespy-recording-\(sanitizedId)-\(Int(Date().timeIntervalSince1970)).tmrec"
            let fileURL = tempDir.appendingPathComponent(filename)

            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: fileURL)

            // Write header
            let header = RecordingHeader(
                version: 2,
                width: width,
                height: height,
                timestamp: Int(Date().timeIntervalSince1970),
                target: target,
                env: ["TERM": "xterm-256color"]
            )
            let headerData = try JSONEncoder().encode(header)
            handle.write(headerData)
            handle.write(Data("\n".utf8))

            // Write initial content as time-zero event if provided
            if let initialContent, !initialContent.isEmpty {
                let encoded = initialContent.base64EncodedString()
                let line = "[0,\"\(encoded)\"]\n"
                handle.write(Data(line.utf8))
            }

            fileHandle = handle
            tempFileURL = fileURL
            startTime = ContinuousClock.now
            accumulatedBytes = 0

            logger.info("Recording started", metadata: [
                "target": "\(target)",
                "file": "\(fileURL.lastPathComponent)",
            ])

            return fileURL
        }

        /// Appends raw terminal data with elapsed timestamp.
        func appendData(_ data: Data) {
            guard let handle = fileHandle, let startTime else { return }

            let elapsed = ContinuousClock.now - startTime
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1E18

            let encoded = data.base64EncodedString()

            // Write [elapsed, base64_data] as JSON array
            // Use manual string construction to avoid JSONSerialization overhead on hot path
            let line = "[\(String(format: "%.6f", seconds)),\"\(encoded)\"]\n"
            let lineData = Data(line.utf8)
            handle.write(lineData)
            accumulatedBytes += lineData.count
        }

        /// Returns accumulated bytes written since recording started.
        func currentFileSize() -> Int {
            accumulatedBytes
        }

        /// Returns current elapsed duration, or 0 if not recording.
        func currentDuration() -> TimeInterval {
            guard let startTime else { return 0 }
            let elapsed = ContinuousClock.now - startTime
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1E18
        }

        /// Closes the file handle and returns the temp URL for export, or nil.
        func close() -> URL? {
            try? fileHandle?.close()
            fileHandle = nil
            startTime = nil
            accumulatedBytes = 0
            let url = tempFileURL
            tempFileURL = nil
            return url
        }

        /// Closes the file handle and removes the temp file.
        func closeAndDiscard() {
            try? fileHandle?.close()
            fileHandle = nil
            startTime = nil
            accumulatedBytes = 0
            if let url = tempFileURL {
                try? FileManager.default.removeItem(at: url)
            }
            tempFileURL = nil
            logger.info("Recording stopped and discarded")
        }

        /// Removes the temp file if it still exists.
        func cleanupTempFile(at url: URL) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Session Recorder

    /// Records raw terminal bytes with timing to a temp file in .tmrec NDJSON format.
    ///
    /// The format is compatible with the `tmux-rec.py` script in the `terminal-debug/` directory.
    /// Each recording contains a JSON header line followed by `[elapsed_seconds, base64_data]` lines.
    ///
    /// File I/O is performed on a background actor to avoid blocking the main thread.
    ///
    /// Usage:
    /// 1. Call `start(paneId:target:width:height:initialContent:)` to begin recording
    /// 2. Call `appendData(_:)` for each chunk of terminal data
    /// 3. Call `export(to:)` to save the recording, or `stop()` to discard it
    /// 4. Recording files are cleaned up automatically when the recorder is deallocated
    @Observable
    @MainActor
    final class SessionRecorder {
        /// Whether a recording is currently active
        private(set) var isRecording = false

        /// Duration of the current recording
        private(set) var duration: TimeInterval = 0

        /// Size in bytes of the current recording file
        private(set) var fileSize = 0

        /// The pane target being recorded
        private(set) var target: String?

        @ObservationIgnored
        private let writer = RecordingFileWriter()

        @ObservationIgnored
        private var durationUpdateTask: Task<Void, Never>?

        /// Serializes appendData calls so writes are guaranteed FIFO order.
        @ObservationIgnored
        private var pendingWriteTask: Task<Void, Never>?

        @ObservationIgnored
        private let logger = Logger(label: "com.claudespy.sessionrecorder")

        deinit {
            durationUpdateTask?.cancel()
            pendingWriteTask?.cancel()
        }

        // MARK: - Public API

        /// Starts recording terminal data for a pane.
        ///
        /// Creates a temp file and writes the NDJSON header. If initial content is provided,
        /// it is written as the first data event at time 0.
        ///
        /// - Parameters:
        ///   - paneId: The tmux pane ID (e.g., "%5")
        ///   - target: The pane target (e.g., "mysession:0.1")
        ///   - width: Terminal width in columns
        ///   - height: Terminal height in rows
        ///   - initialContent: Optional initial screen content to include at time 0
        func start(
            paneId: String,
            target: String,
            width: Int,
            height: Int,
            initialContent: Data? = nil
        ) async throws {
            guard !isRecording else {
                logger.warning("Recording already active for \(self.target ?? "unknown")")
                return
            }

            _ = try await writer.open(
                paneId: paneId,
                target: target,
                width: width,
                height: height,
                initialContent: initialContent
            )

            self.target = target
            isRecording = true
            duration = 0
            fileSize = 0

            // Start periodic duration/size updates
            startDurationUpdates()
        }

        /// Appends raw terminal data to the recording with a timestamp.
        ///
        /// Uses a serial task chain to guarantee writes are ordered (FIFO).
        /// All callers are already on MainActor, so no isolation hop is needed.
        ///
        /// - Parameter data: Raw terminal bytes to record
        func appendData(_ data: Data) {
            let previous = pendingWriteTask
            pendingWriteTask = Task {
                _ = await previous?.value
                await writer.appendData(data)
            }
        }

        /// Stops the current recording and discards the temp file.
        func stop() async {
            guard isRecording else { return }
            finishRecording()
            await writer.closeAndDiscard()
        }

        /// Exports the current recording to a user-chosen location.
        ///
        /// Stops the recording and presents an NSSavePanel for the user to choose a destination.
        /// The temp file is moved to the chosen location, or cleaned up if the user cancels.
        func export() async {
            guard isRecording else { return }

            let savedTarget = target
            finishRecording()

            guard let tempURL = await writer.close() else { return }

            // Present save panel
            let panel = NSSavePanel()
            if let tmrecType = UTType(filenameExtension: "tmrec") {
                panel.allowedContentTypes = [tmrecType]
            }
            panel.nameFieldStringValue = tempURL.lastPathComponent
            panel.title = "Export Session Recording"
            panel.prompt = "Export"

            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await panel.begin()
            }

            if response == .OK, let destinationURL = panel.url {
                do {
                    // Remove existing file at destination if present
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                    logger.info("Recording exported", metadata: [
                        "target": "\(savedTarget ?? "unknown")",
                        "destination": "\(destinationURL.path)",
                    ])
                } catch {
                    logger.error("Failed to export recording: \(error)")
                    await writer.cleanupTempFile(at: tempURL)
                }
            } else {
                // User cancelled - clean up temp file
                await writer.cleanupTempFile(at: tempURL)
                logger.info("Recording export cancelled, temp file cleaned up")
            }
        }

        // MARK: - Private

        /// Resets UI state (called before async writer cleanup)
        private func finishRecording() {
            durationUpdateTask?.cancel()
            durationUpdateTask = nil
            pendingWriteTask?.cancel()
            pendingWriteTask = nil
            isRecording = false
            target = nil
            duration = 0
            fileSize = 0
        }

        private func startDurationUpdates() {
            durationUpdateTask = Task { [weak self, writer] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { break }
                    guard let self, self.isRecording else { break }

                    self.duration = await writer.currentDuration()
                    self.fileSize = await writer.currentFileSize()
                }
            }
        }
    }
#endif

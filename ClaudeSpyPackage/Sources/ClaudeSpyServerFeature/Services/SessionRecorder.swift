#if os(macOS)
    import AppKit
    import Foundation
    import Logging
    import UniformTypeIdentifiers

    /// Records raw terminal bytes with timing to a temp file in .tmrec NDJSON format.
    ///
    /// The format is compatible with the `tmux-rec.py` script in the `terminal-debug/` directory.
    /// Each recording contains a JSON header line followed by `[elapsed_seconds, base64_data]` lines.
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
        private(set) var fileSize: Int = 0

        /// The pane target being recorded
        private(set) var target: String?

        @ObservationIgnored
        private var startTime: ContinuousClock.Instant?

        @ObservationIgnored
        private var fileHandle: FileHandle?

        @ObservationIgnored
        private var tempFileURL: URL?

        @ObservationIgnored
        private var durationUpdateTask: Task<Void, Never>?

        @ObservationIgnored
        private let logger = Logger(label: "com.claudespy.sessionrecorder")

        deinit {
            durationUpdateTask?.cancel()
            fileHandle?.closeFile()
            if let url = tempFileURL {
                try? FileManager.default.removeItem(at: url)
            }
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
        ) throws {
            guard !isRecording else {
                logger.warning("Recording already active for \(self.target ?? "unknown")")
                return
            }

            // Create temp file
            let tempDir = FileManager.default.temporaryDirectory
            let filename = "claudespy-recording-\(paneId)-\(Int(Date().timeIntervalSince1970)).tmrec"
            let fileURL = tempDir.appendingPathComponent(filename)

            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: fileURL)

            // Write header
            let header: [String: Any] = [
                "version": 2,
                "width": width,
                "height": height,
                "timestamp": Int(Date().timeIntervalSince1970),
                "target": target,
                "env": [
                    "TERM": "xterm-256color",
                ],
            ]
            let headerData = try JSONSerialization.data(withJSONObject: header)
            handle.write(headerData)
            handle.write(Data("\n".utf8))

            // Write initial content as time-zero event if provided
            if let initialContent, !initialContent.isEmpty {
                let encoded = initialContent.base64EncodedString()
                let event = try JSONSerialization.data(withJSONObject: [0.0, encoded])
                handle.write(event)
                handle.write(Data("\n".utf8))
            }

            self.fileHandle = handle
            self.tempFileURL = fileURL
            self.target = target
            self.startTime = ContinuousClock.now
            self.isRecording = true
            self.duration = 0
            self.fileSize = Int((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0)

            // Start periodic duration/size updates
            startDurationUpdates()

            logger.info("Recording started", metadata: [
                "target": "\(target)",
                "file": "\(fileURL.lastPathComponent)",
            ])
        }

        /// Appends raw terminal data to the recording with a timestamp.
        ///
        /// - Parameter data: Raw terminal bytes to record
        func appendData(_ data: Data) {
            guard isRecording, let handle = fileHandle, let startTime else { return }

            let elapsed = ContinuousClock.now - startTime
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

            let encoded = data.base64EncodedString()

            // Write [elapsed, base64_data] as JSON array
            // Use manual string construction to avoid JSONSerialization overhead on hot path
            let line = "[\(String(format: "%.6f", seconds)),\"\(encoded)\"]\n"
            handle.write(Data(line.utf8))
        }

        /// Stops the current recording and discards the temp file.
        func stop() {
            guard isRecording else { return }
            finishRecording()
            cleanupTempFile()
            logger.info("Recording stopped and discarded")
        }

        /// Exports the current recording to a user-chosen location.
        ///
        /// Stops the recording and presents an NSSavePanel for the user to choose a destination.
        /// The temp file is moved to the chosen location, or cleaned up if the user cancels.
        func export() async {
            guard isRecording, let tempURL = tempFileURL else { return }

            let savedTarget = target
            finishRecording()

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
                    tempFileURL = nil

                    logger.info("Recording exported", metadata: [
                        "target": "\(savedTarget ?? "unknown")",
                        "destination": "\(destinationURL.path)",
                    ])
                } catch {
                    logger.error("Failed to export recording: \(error)")
                    cleanupTempFile()
                }
            } else {
                // User cancelled - clean up temp file
                cleanupTempFile()
                logger.info("Recording export cancelled, temp file cleaned up")
            }
        }

        // MARK: - Private

        /// Shared cleanup between stop() and export()
        private func finishRecording() {
            durationUpdateTask?.cancel()
            durationUpdateTask = nil
            fileHandle?.closeFile()
            fileHandle = nil
            isRecording = false
            startTime = nil
            target = nil
            duration = 0
            fileSize = 0
        }

        private func startDurationUpdates() {
            durationUpdateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { break }
                    guard let self, let startTime = self.startTime else { break }

                    let elapsed = ContinuousClock.now - startTime
                    self.duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

                    if let url = self.tempFileURL {
                        self.fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    }
                }
            }
        }

        private func cleanupTempFile() {
            guard let url = tempFileURL else { return }
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }
#endif

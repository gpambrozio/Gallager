#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation

    /// Parses OSC 9 and OSC 777 terminal notification escape sequences from raw data.
    ///
    /// Terminal applications (like Claude Code) can send desktop notifications via
    /// OSC escape sequences:
    /// - **OSC 9**: `ESC ] 9 ; <message> BEL/ST` — Simple notification (iTerm2 style)
    /// - **OSC 777**: `ESC ] 777 ; notify ; <title> ; <body> BEL/ST` — Notification with title (rxvt-unicode style)
    ///
    /// The parser handles sequences split across multiple data chunks by buffering
    /// incomplete sequences. Detected notification sequences are stripped from the
    /// output data to prevent terminal emulators from displaying them as artifacts.
    ///
    /// Two modes are available:
    /// - **Full mode** (default): Builds filtered output data with notifications stripped.
    ///   Use when the data stream is being forwarded to a terminal emulator.
    /// - **Scan-only mode** (`scanOnly: true`): Only extracts notifications without
    ///   building the filtered output, returning empty `filteredData`. Use for
    ///   notification-only readers where the data stream is discarded anyway,
    ///   avoiding unnecessary `Data` allocations.
    struct TerminalNotificationParser: Sendable {
        /// Result of parsing a data chunk
        struct ParseResult: Sendable {
            /// Data with notification sequences stripped (empty in scan-only mode)
            let filteredData: Data
            /// Notifications found in the data
            let notifications: [TerminalStreamMessage.TerminalNotification]
        }

        /// Maximum OSC buffer size (8 KB) before discarding as pass-through data.
        /// Prevents unbounded growth from malformed sequences that never terminate.
        private static let maxBufferSize = 8_192

        /// When true, skips building filtered output data — only extracts notifications.
        let scanOnly: Bool

        /// Buffer for incomplete OSC sequences split across reads
        private var oscBuffer = Data()

        init(scanOnly: Bool = false) {
            self.scanOnly = scanOnly
        }

        /// Parse raw terminal data for OSC 9/777 notification sequences.
        ///
        /// Returns filtered data (with notifications stripped) and any notifications found.
        /// In scan-only mode, `filteredData` is always empty.
        /// Call this on each incoming data chunk — incomplete sequences are buffered
        /// automatically across calls.
        mutating func parse(_ data: Data) -> ParseResult {
            var result = scanOnly ? Data() : Data()
            var notifications: [TerminalStreamMessage.TerminalNotification] = []

            // Prepend any buffered incomplete sequence from previous read
            var dataToProcess = data
            if !oscBuffer.isEmpty {
                dataToProcess = oscBuffer + data
                oscBuffer = Data()
            }

            var i = dataToProcess.startIndex

            while i < dataToProcess.endIndex {
                guard dataToProcess[i] == 0x1B else { // ESC
                    if !scanOnly {
                        result.append(dataToProcess[i])
                    }
                    i = dataToProcess.index(after: i)
                    continue
                }

                // Need at least ESC ]
                guard i + 1 < dataToProcess.endIndex else {
                    // ESC at end of data — buffer for next chunk
                    oscBuffer = Data(dataToProcess[i...])
                    break
                }

                guard dataToProcess[i + 1] == 0x5D else { // ']'
                    // ESC followed by something other than ] — pass through
                    if !scanOnly {
                        result.append(dataToProcess[i])
                    }
                    i = dataToProcess.index(after: i)
                    continue
                }

                // We have ESC ] — potential OSC sequence
                // Find the terminator: BEL (0x07) or ST (ESC \)
                let oscStart = i
                let contentStart = dataToProcess.index(i, offsetBy: 2)

                guard contentStart < dataToProcess.endIndex else {
                    // Just ESC ] at end — buffer
                    oscBuffer = Data(dataToProcess[oscStart...])
                    break
                }

                // Scan for terminator
                var j = contentStart
                var foundTerminator = false
                var terminatorEnd = j

                while j < dataToProcess.endIndex {
                    if dataToProcess[j] == 0x07 { // BEL
                        foundTerminator = true
                        terminatorEnd = dataToProcess.index(after: j)
                        break
                    }
                    if dataToProcess[j] == 0x1B { // Potential ST (ESC \)
                        if j + 1 >= dataToProcess.endIndex {
                            // ESC at end inside OSC — buffer entire sequence
                            oscBuffer = Data(dataToProcess[oscStart...])
                            return ParseResult(filteredData: result, notifications: notifications)
                        }
                        if dataToProcess[j + 1] == 0x5C { // '\'
                            foundTerminator = true
                            terminatorEnd = dataToProcess.index(j, offsetBy: 2)
                            break
                        }
                    }
                    j = dataToProcess.index(after: j)
                }

                guard foundTerminator else {
                    // Reached end without terminator — buffer entire sequence
                    oscBuffer = Data(dataToProcess[oscStart...])
                    break
                }

                // Extract content between ESC ] and terminator
                let content = dataToProcess[contentStart..<j]

                // Check if this is a notification OSC sequence
                let (isNotificationSequence, notification) = parseNotificationContent(content)
                if isNotificationSequence {
                    // Strip notification sequences from output
                    if let notification {
                        notifications.append(notification)
                    }
                } else if !scanOnly {
                    // Not a notification — pass through the entire OSC sequence unchanged
                    result.append(contentsOf: dataToProcess[oscStart..<terminatorEnd])
                }

                i = terminatorEnd
            }

            // Flush oversized buffer as pass-through to prevent unbounded growth
            if oscBuffer.count > Self.maxBufferSize {
                if !scanOnly {
                    result.append(contentsOf: oscBuffer)
                }
                oscBuffer = Data()
            }

            return ParseResult(filteredData: result, notifications: notifications)
        }

        /// Attempt to parse OSC content as a notification.
        ///
        /// Returns a tuple: (isNotificationSequence, notification).
        /// `isNotificationSequence` is true if the sequence format matches OSC 9 or OSC 777
        /// (used for stripping). `notification` is non-nil only if a valid notification was parsed.
        ///
        /// - OSC 9: Content is `9;<message>`
        /// - OSC 777: Content is `777;notify;<title>;<body>`
        private func parseNotificationContent(
            _ content: Data
        ) -> (isNotificationSequence: Bool, notification: TerminalStreamMessage.TerminalNotification?) {
            guard let string = String(bytes: content, encoding: .utf8) else {
                return (false, nil)
            }

            // OSC 9: "9;<message>"
            if string.hasPrefix("9;") {
                let message = String(string.dropFirst(2))
                guard !message.isEmpty else { return (true, nil) }
                return (true, TerminalStreamMessage.TerminalNotification(body: message))
            }

            // OSC 777: "777;notify;<title>;<body>"
            if string.hasPrefix("777;notify;") {
                let payload = String(string.dropFirst(11)) // Drop "777;notify;"
                let parts = payload.split(separator: ";", maxSplits: 1)
                guard parts.count == 2 else {
                    // Malformed — treat entire payload as body
                    guard !payload.isEmpty else { return (true, nil) }
                    return (true, TerminalStreamMessage.TerminalNotification(body: payload))
                }
                let title = String(parts[0])
                let body = String(parts[1])
                guard !body.isEmpty else { return (true, nil) }
                return (true, TerminalStreamMessage.TerminalNotification(title: title, body: body))
            }

            // Not a notification sequence
            return (false, nil)
        }

        /// Resets the parser state, clearing any buffered incomplete sequences.
        mutating func reset() {
            oscBuffer = Data()
        }
    }
#endif

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
            /// Last terminal title change detected via OSC 0/2 (nil if none found)
            let titleChange: String?
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
            var lastTitleChange: String?

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
                            return ParseResult(filteredData: result, notifications: notifications, titleChange: lastTitleChange)
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

                // Check if this is a notification or title OSC sequence
                let (isNotificationSequence, notification) = parseNotificationContent(content)
                if isNotificationSequence {
                    // Strip notification sequences from output
                    if let notification {
                        notifications.append(notification)
                    }
                } else if let title = parseTitleContent(content) {
                    // OSC 0/2 title change — pass through to terminal but also capture
                    lastTitleChange = title
                    if !scanOnly {
                        result.append(contentsOf: dataToProcess[oscStart..<terminatorEnd])
                    }
                } else if !scanOnly {
                    // Not a notification or title — pass through the entire OSC sequence unchanged
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

            return ParseResult(filteredData: result, notifications: notifications, titleChange: lastTitleChange)
        }

        /// Attempt to parse OSC content as a terminal title change (OSC 0 or OSC 2).
        ///
        /// - OSC 0: Content is `0;<title>` (set window title and icon name)
        /// - OSC 2: Content is `2;<title>` (set window title)
        ///
        /// Returns the title string if this is a title sequence, nil otherwise.
        private func parseTitleContent(_ content: Data) -> String? {
            guard let string = String(bytes: content, encoding: .utf8) else {
                return nil
            }

            // OSC 0: "0;<title>" or OSC 2: "2;<title>"
            if string.hasPrefix("0;") || string.hasPrefix("2;") {
                let title = String(string.dropFirst(2))
                return title.isEmpty ? nil : title
            }

            return nil
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

                // Skip ConEmu-style OSC 9 sub-commands (e.g. "4;0;" for progress state,
                // "1;filename" for tab title). These have a numeric prefix before the first
                // semicolon, while real notifications start with readable text.
                if let semicolonIndex = message.firstIndex(of: ";"),
                    message[message.startIndex..<semicolonIndex].allSatisfy(\.isNumber)
                {
                    return (true, nil)
                }

                guard let sanitized = sanitizeNotificationText(message) else { return (true, nil) }
                if isIdlePromptNotification(body: sanitized) { return (true, nil) }
                return (true, TerminalStreamMessage.TerminalNotification(body: sanitized))
            }

            // OSC 777: "777;notify;<title>;<body>"
            if string.hasPrefix("777;notify;") {
                let payload = String(string.dropFirst(11)) // Drop "777;notify;"
                let parts = payload.split(separator: ";", maxSplits: 1)
                guard parts.count == 2 else {
                    // Malformed — treat entire payload as body
                    guard let sanitized = sanitizeNotificationText(payload) else { return (true, nil) }
                    if isIdlePromptNotification(body: sanitized) { return (true, nil) }
                    return (true, TerminalStreamMessage.TerminalNotification(body: sanitized))
                }
                let title = sanitizeNotificationText(String(parts[0]))
                let body = sanitizeNotificationText(String(parts[1]))
                guard let body else { return (true, nil) }
                if isIdlePromptNotification(body: body) { return (true, nil) }
                return (true, TerminalStreamMessage.TerminalNotification(title: title, body: body))
            }

            // Not a notification sequence
            return (false, nil)
        }

        /// Checks if a notification body matches a known idle prompt pattern.
        ///
        /// Claude Code sends an OSC 9 notification when idle (e.g., "Claude is waiting
        /// for your input"). These are noise — the idle state is already tracked via
        /// hook events — so we strip the sequence without emitting a notification.
        private func isIdlePromptNotification(body: String) -> Bool {
            body == "Claude is waiting for your input"
        }

        /// Sanitizes notification text by stripping control characters and escape sequences.
        ///
        /// Returns nil if the sanitized text is empty (i.e., the original was all control
        /// characters / escape sequences and not a real human-readable notification).
        private func sanitizeNotificationText(_ text: String) -> String? {
            guard !text.isEmpty else { return nil }

            // Strip ANSI escape sequences (CSI sequences like ESC[...m)
            // and any remaining ESC-prefixed sequences
            var result = ""
            var iterator = text.unicodeScalars.makeIterator()

            while let scalar = iterator.next() {
                if scalar == "\u{1B}" {
                    // ESC — skip the escape sequence
                    guard let next = iterator.next() else { break }
                    if next == "[" {
                        // CSI sequence: skip until we hit a letter (0x40-0x7E)
                        while let param = iterator.next() {
                            if param.value >= 0x40, param.value <= 0x7E { break }
                        }
                    } else if next == "]" {
                        // Nested OSC sequence: skip until BEL (0x07), ST (ESC \), or end
                        while let oscChar = iterator.next() {
                            if oscChar.value == 0x07 { break }
                            if oscChar == "\u{1B}" {
                                // Check for ST (ESC \)
                                if let after = iterator.next(), after == "\\" { break }
                            }
                        }
                    }
                    // For other ESC sequences (e.g. ESC > or ESC =), the next char
                    // was already consumed above.
                    // Note: some ESC sequences are 3 bytes (e.g. ESC ( B, ESC # 8) —
                    // the third byte may leak through, but these are rare in notification text.
                    continue
                }

                // Skip control characters (0x00-0x1F, 0x7F) except tab, newline, carriage return
                if (scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r") || scalar.value == 0x7F {
                    continue
                }

                result.append(Character(scalar))
            }

            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// Resets the parser state, clearing any buffered incomplete sequences.
        mutating func reset() {
            oscBuffer = Data()
        }
    }
#endif

import Foundation

// MARK: - Terminal Stream Message

/// Continuous terminal stream data from host to viewer.
///
/// This message type enables live terminal streaming, replacing the one-shot snapshot model.
/// The host sends an initial state followed by incremental data chunks as terminal output arrives.
public struct TerminalStreamMessage: Codable, Sendable, Identifiable {
    public let id: UUID
    public let paneId: String
    public let timestamp: Date
    public let updateType: StreamUpdateType

    public init(
        id: UUID = UUID(),
        paneId: String,
        timestamp: Date = Date(),
        updateType: StreamUpdateType
    ) {
        self.id = id
        self.paneId = paneId
        self.timestamp = timestamp
        self.updateType = updateType
    }

    // MARK: - Update Types

    /// The type of stream update being sent.
    public enum StreamUpdateType: Codable, Sendable, Equatable {
        /// Initial state containing the full terminal buffer at stream start.
        /// iOS uses this to initialize its terminal view.
        case initialState(InitialState)

        /// Incremental data chunk containing new terminal output.
        /// Fed directly to the terminal view.
        case dataChunk(DataChunk)

        /// Terminal dimensions have changed (pane resized).
        case dimensionChange(DimensionChange)

        /// Terminal title has changed (via OSC 0 or OSC 2 escape sequences).
        case titleChange(TitleChange)

        /// Terminal notification received (via OSC 9 or OSC 777 escape sequences).
        case notification(TerminalNotification)

        /// Stream has ended (pane closed, disconnected, etc.).
        case streamEnd
    }

    // MARK: - Payload Types

    /// Initial terminal state sent when streaming begins.
    public struct InitialState: Codable, Sendable, Equatable {
        /// Terminal width in character columns
        public let width: Int

        /// Terminal height in character rows
        public let height: Int

        /// Current terminal buffer content as Base64-encoded data (raw bytes with ANSI)
        public let contentBase64: String

        public init(width: Int, height: Int, content: Data) {
            self.width = width
            self.height = height
            self.contentBase64 = content.base64EncodedString()
        }

        /// Decodes the content from Base64
        public var content: Data? {
            Data(base64Encoded: contentBase64)
        }
    }

    /// Incremental data chunk for streaming updates.
    public struct DataChunk: Codable, Sendable, Equatable {
        /// Terminal data as Base64-encoded bytes (raw ANSI escape sequences)
        public let dataBase64: String

        public init(data: Data) {
            self.dataBase64 = data.base64EncodedString()
        }

        /// Decodes the data from Base64
        public var data: Data? {
            Data(base64Encoded: dataBase64)
        }
    }

    /// Terminal dimension change notification.
    public struct DimensionChange: Codable, Sendable, Equatable {
        /// New terminal width in character columns
        public let width: Int

        /// New terminal height in character rows
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// Terminal title change notification.
    public struct TitleChange: Codable, Sendable, Equatable {
        /// The new terminal title
        public let title: String

        public init(title: String) {
            self.title = title
        }
    }

    /// Terminal notification from OSC 9 or OSC 777 escape sequences.
    public struct TerminalNotification: Codable, Sendable, Equatable {
        /// Optional notification title (OSC 777 provides this, OSC 9 does not)
        public let title: String?

        /// Notification body/message
        public let body: String

        public init(title: String? = nil, body: String) {
            self.title = title
            self.body = body
        }
    }
}

// MARK: - Convenience Initializers

public extension TerminalStreamMessage {
    /// Create an initial state message.
    static func initialState(
        paneId: String,
        width: Int,
        height: Int,
        content: Data
    ) -> TerminalStreamMessage {
        TerminalStreamMessage(
            paneId: paneId,
            updateType: .initialState(InitialState(width: width, height: height, content: content))
        )
    }

    /// Create a data chunk message.
    static func dataChunk(paneId: String, data: Data) -> TerminalStreamMessage {
        TerminalStreamMessage(
            paneId: paneId,
            updateType: .dataChunk(DataChunk(data: data))
        )
    }

    /// Create a dimension change message.
    static func dimensionChange(paneId: String, width: Int, height: Int) -> TerminalStreamMessage {
        TerminalStreamMessage(
            paneId: paneId,
            updateType: .dimensionChange(DimensionChange(width: width, height: height))
        )
    }

    /// Create a title change message.
    static func titleChange(paneId: String, title: String) -> TerminalStreamMessage {
        TerminalStreamMessage(
            paneId: paneId,
            updateType: .titleChange(TitleChange(title: title))
        )
    }

    /// Create a notification message.
    static func notification(
        paneId: String,
        title: String? = nil,
        body: String
    ) -> TerminalStreamMessage {
        TerminalStreamMessage(
            paneId: paneId,
            updateType: .notification(TerminalNotification(title: title, body: body))
        )
    }

    /// Create a stream end message.
    static func streamEnd(paneId: String) -> TerminalStreamMessage {
        TerminalStreamMessage(
            paneId: paneId,
            updateType: .streamEnd
        )
    }
}

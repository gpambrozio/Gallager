import Foundation

/// Errors that can occur with FIFO operations
enum FIFOError: Error, LocalizedError {
    case creationFailed(path: String, error: String)
    case openFailed(path: String)
    case readFailed(error: String)
    case alreadyReading

    var errorDescription: String? {
        switch self {
        case let .creationFailed(path, error):
            return "Failed to create FIFO at \(path): \(error)"
        case let .openFailed(path):
            return "Failed to open FIFO at \(path)"
        case let .readFailed(error):
            return "Failed to read from FIFO: \(error)"
        case .alreadyReading:
            return "Already reading from this FIFO"
        }
    }
}

/// Reads data from a named pipe (FIFO)
actor FIFOReader {
    private let path: String
    private var fileHandle: FileHandle?
    private var isReading = false
    private var continuation: AsyncStream<Data>.Continuation?

    init(path: String) {
        self.path = path
    }

    deinit {
        // Clean up will be handled by stop()
    }

    /// Creates the FIFO if it doesn't exist
    func createFIFO() throws {
        let fileManager = FileManager.default

        // Remove existing file if present
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }

        // Create the FIFO using mkfifo
        let result = mkfifo(path, S_IRUSR | S_IWUSR)
        if result != 0 {
            let errorString = String(cString: strerror(errno))
            throw FIFOError.creationFailed(path: path, error: errorString)
        }
    }

    /// Starts reading from the FIFO and returns an async stream of data
    func startReading() throws -> AsyncStream<Data> {
        guard !isReading else {
            throw FIFOError.alreadyReading
        }

        isReading = true

        return AsyncStream { continuation in
            self.continuation = continuation

            // Open the FIFO in a background task to avoid blocking
            Task {
                self.openAndRead()
            }

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.stop()
                }
            }
        }
    }

    private func openAndRead() {
        // Open FIFO - this blocks until a writer opens the other end
        // We open in read-only, non-blocking mode to avoid hanging
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            continuation?.finish()
            return
        }

        fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        guard let handle = fileHandle else {
            close(fd)
            continuation?.finish()
            return
        }

        // Set up readability handler
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF - writer closed, but don't stop reading
                // tmux might reopen the pipe
                return
            }
            Task {
                await self?.emitData(data)
            }
        }
    }

    private func emitData(_ data: Data) {
        continuation?.yield(data)
    }

    /// Stops reading and cleans up
    func stop() {
        isReading = false

        fileHandle?.readabilityHandler = nil
        try? fileHandle?.close()
        fileHandle = nil

        continuation?.finish()
        continuation = nil

        // Remove the FIFO file
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The path to this FIFO
    var fifoPath: String {
        path
    }
}

import Foundation

// MARK: - FileHandle + AsyncStream<UInt8>

public extension FileHandle {
    /// Build a pipe-safe `AsyncStream<UInt8>` from this handle.
    ///
    /// `FileHandle.AsyncBytes` (the stdlib `.bytes` property) does not deliver
    /// any bytes on a pipe until the writer side either fills the OS buffer
    /// (~16 KiB on macOS) or closes the handle. That makes it unusable for an
    /// interactive JSON-RPC transport where each message is small and the
    /// writer keeps the pipe open across many requests — the reader would
    /// just sit there waiting forever.
    ///
    /// We instead use Foundation's `readabilityHandler`, which fires on the
    /// underlying dispatch queue every time bytes become available. Each
    /// chunk is yielded byte-by-byte into the stream so `JSONRPCFramer.read`
    /// (which reads byte-by-byte off its iterator) sees them promptly.
    ///
    /// The stream finishes when the handle reports an empty `availableData`
    /// (EOF, i.e. the writer closed). On consumer cancellation we clear the
    /// `readabilityHandler` so Foundation stops scheduling reads against a
    /// possibly-closed FD.
    func makeAsyncByteStream() -> AsyncStream<UInt8> {
        AsyncStream(UInt8.self, bufferingPolicy: .unbounded) { continuation in
            self.readabilityHandler = { handle in
                // `availableData` blocks the dispatch queue thread until the
                // kernel hands us bytes (or signals EOF). For pipes the call
                // returns whatever the writer just flushed, even if the
                // writer didn't close.
                let data = handle.availableData
                if data.isEmpty {
                    // EOF — peer closed its write end.
                    continuation.finish()
                    return
                }
                for byte in data {
                    continuation.yield(byte)
                }
            }

            continuation.onTermination = { [weak self] _ in
                // Detach the handler so Foundation stops trying to read from
                // a possibly-closed FD after the consumer walks away.
                self?.readabilityHandler = nil
            }
        }
    }
}

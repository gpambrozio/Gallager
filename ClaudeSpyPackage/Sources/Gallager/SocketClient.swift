import Foundation

/// Connects to the Gallager app's Unix domain socket and sends JSON-RPC requests.
enum SocketClient {
    /// Resolves the socket path from environment or default.
    static var socketPath: String {
        ProcessInfo.processInfo.environment["GALLAGER_SOCKET"]
            ?? NSTemporaryDirectory() + "gallager.sock"
    }

    /// Sends a JSON-RPC request and returns the response.
    /// For most commands this is a simple request-response.
    static func send(_ request: JSONRPCRequest, socketPath: String? = nil) throws -> JSONRPCResponse {
        let path = socketPath ?? self.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError.socketCreationFailed
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let raw = UnsafeMutableRawPointer(sunPath)
                raw.copyMemory(from: ptr, byteCount: path.utf8.count + 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }
        guard connected == 0 else {
            throw CLIError.connectionFailed
        }

        // Encode and send request
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(UInt8(ascii: "\n"))

        let written = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
        guard written == data.count else {
            throw CLIError.writeFailed
        }

        // Read response (newline-delimited JSON)
        var responseData = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            responseData.append(byte)
        }

        guard !responseData.isEmpty else {
            throw CLIError.emptyResponse
        }

        return try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
    }

    /// Sends a request and blocks until response (used by `edit` command which waits for user action).
    static func sendAndWait(_ request: JSONRPCRequest, socketPath: String? = nil) throws -> JSONRPCResponse {
        // Same as send() — the blocking behavior comes from the server not responding
        // until the user finishes editing. The socket read naturally blocks.
        try send(request, socketPath: socketPath)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case socketCreationFailed
    case connectionFailed
    case writeFailed
    case emptyResponse

    var description: String {
        switch self {
        case .socketCreationFailed: "Failed to create socket"
        case .connectionFailed: "Failed to connect to Gallager (is it running?)"
        case .writeFailed: "Failed to send request"
        case .emptyResponse: "Empty response from server"
        }
    }
}

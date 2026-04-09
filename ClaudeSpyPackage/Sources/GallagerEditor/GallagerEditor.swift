import Foundation

/// Lightweight CLI wrapper invoked by Claude Code via the `$VISUAL` environment variable.
///
/// When the user presses Ctrl-G in Claude Code, it writes the current prompt to a temp file
/// and runs `execSync("$VISUAL <tempfile>")`. This CLI:
/// 1. Reads the temp file path from the last command-line argument
/// 2. Reads `$TMUX_PANE` to identify which pane triggered the edit
/// 3. Connects to the Gallager app's Unix domain socket
/// 4. Sends the pane ID and file path
/// 5. Blocks until the app signals "done"
/// 6. Exits — Claude Code then reads the (possibly modified) file back
@main
struct GallagerEditor {
    static let socketPath = NSTemporaryDirectory() + "gallager-editor.sock"

    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: GallagerEditor <file>\n", stderr)
            exit(1)
        }

        let filePath = CommandLine.arguments[CommandLine.arguments.count - 1]
        let paneId = ProcessInfo.processInfo.environment["TMUX_PANE"] ?? ""

        guard !paneId.isEmpty else {
            fputs("TMUX_PANE not set\n", stderr)
            exit(1)
        }

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fputs("Failed to create socket\n", stderr)
            exit(1)
        }

        // Connect to the app's socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let raw = UnsafeMutableRawPointer(sunPath)
                raw.copyMemory(from: ptr, byteCount: socketPath.utf8.count + 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }

        guard connected == 0 else {
            fputs("Failed to connect to Gallager (is it running?)\n", stderr)
            close(fd)
            exit(1)
        }

        // Send pane ID and file path as tab-separated, newline-terminated message
        let message = "\(paneId)\t\(filePath)\n"
        message.withCString { ptr in
            let written = Darwin.write(fd, ptr, message.utf8.count)
            if written < 0 {
                fputs("Failed to send message\n", stderr)
                close(fd)
                exit(1)
            }
        }

        // Block until the app sends "done\n" (or the connection closes)
        var buf = [UInt8](repeating: 0, count: 64)
        _ = Darwin.read(fd, &buf, buf.count)

        close(fd)
        exit(0)
    }
}

#if canImport(AppKit)
    #if DEBUG
        import AppKit
        import Foundation
        import Network

        /// Minimal HTTP server for E2E test operations that require in-process access.
        ///
        /// Most UI interaction has moved to external Accessibility APIs (MacOSAccessibility).
        /// This server only handles:
        /// - `/set-sidebar-width` — NSSplitView.setPosition() requires in-process access
        /// - `/unpair` — Posts a NotificationCenter notification inside the app
        ///
        /// Only active when the app is launched with `--e2e-test`.
        @MainActor
        final public class TestAccessibilityServer {
            private var listener: NWListener?
            private static var instance: TestAccessibilityServer?

            /// Start the server if running in E2E test mode.
            /// Reads `--test-accessibility-port <port>` from launch arguments (default: 18081).
            public static func startIfNeeded() {
                guard CommandLine.arguments.contains("--e2e-test") else { return }

                var port: UInt16 = 18_081
                if
                    let idx = CommandLine.arguments.firstIndex(of: "--test-accessibility-port"),
                    idx + 1 < CommandLine.arguments.count,
                    let parsed = UInt16(CommandLine.arguments[idx + 1]) {
                    port = parsed
                }

                let server = TestAccessibilityServer()
                do {
                    try server.start(port: port)
                    instance = server
                } catch {
                    print("[TestAccessibilityServer-Mac] Failed to start: \(error)")
                }
            }

            private func start(port: UInt16 = 18_081) throws {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    print("[TestAccessibilityServer-Mac] Invalid port: \(port)")
                    return
                }
                listener = try NWListener(using: params, on: nwPort)
                listener?.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        print("[TestAccessibilityServer-Mac] Listener failed: \(error)")
                    }
                }
                listener?.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                listener?.start(queue: .main)
                print("[TestAccessibilityServer-Mac] Listening on port \(port)")
            }

            private nonisolated func handleConnection(_ connection: NWConnection) {
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.receiveRequest(connection)
                    case .failed:
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: .main)
            }

            private nonisolated func receiveRequest(_ connection: NWConnection) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, _ in
                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        connection.cancel()
                        return
                    }

                    if request.hasPrefix("POST /unpair") {
                        Task { @MainActor in
                            NotificationCenter.default.post(
                                name: .init("com.claudespy.e2e.unpairViewer"), object: nil
                            )
                            let response = Data(
                                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                                    .utf8)
                            connection.send(content: response, completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                        }
                    } else if request.hasPrefix("POST /set-sidebar-width") {
                        let widthStr = Self.extractQueryParam(from: request, key: "width")
                        Task { @MainActor [weak self] in
                            let width = Int(widthStr ?? "") ?? 0
                            var found = false
                            if width > 0 {
                                for window in NSApp.windows
                                    where window.isVisible && window.level == .normal {
                                    if
                                        let contentView = window.contentView,
                                        let splitView = self?.findSplitView(in: contentView) {
                                        splitView.setPosition(CGFloat(width), ofDividerAt: 0)
                                        found = true
                                        break
                                    }
                                }
                            }
                            let body = found ? "ok" : "not_found"
                            let response = Data(
                                "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
                                    .utf8)
                            connection.send(content: response, completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                        }
                    } else {
                        let response = Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8)
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                }
            }

            /// Extract a query parameter from a raw HTTP request line.
            /// e.g. "POST /set-sidebar-width?width=250 HTTP/1.1\r\n..." → "250"
            private nonisolated static func extractQueryParam(from request: String, key: String) -> String? {
                // Get the first line (request line)
                guard let requestLine = request.components(separatedBy: "\r\n").first else { return nil }
                // Find the query string after '?'
                guard let questionMark = requestLine.firstIndex(of: "?") else { return nil }
                let afterQuestion = requestLine[requestLine.index(after: questionMark)...]
                // Remove the " HTTP/1.1" suffix
                let queryString = afterQuestion.components(separatedBy: " ").first ?? String(afterQuestion)
                // Parse key=value pairs
                for pair in queryString.components(separatedBy: "&") {
                    let parts = pair.components(separatedBy: "=")
                    guard parts.count == 2, parts[0] == key else { continue }
                    // Decode URL encoding: + → space, then percent-decode
                    let decoded = parts[1]
                        .replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? parts[1]
                    return decoded
                }
                return nil
            }

            /// Recursively search the view hierarchy for an NSSplitView.
            private func findSplitView(in view: NSView) -> NSSplitView? {
                if let splitView = view as? NSSplitView {
                    return splitView
                }
                for subview in view.subviews {
                    if let found = findSplitView(in: subview) {
                        return found
                    }
                }
                return nil
            }
        }
    #endif
#endif

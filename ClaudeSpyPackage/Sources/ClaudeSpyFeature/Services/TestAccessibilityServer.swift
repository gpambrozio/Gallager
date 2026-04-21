#if os(iOS)
    #if DEBUG
        import ClaudeSpyNetworking
        import Foundation
        import Network

        /// Minimal HTTP server for iOS-side E2E test operations that require
        /// in-process access (mirror of the macOS `TestAccessibilityServer`).
        ///
        /// Currently only handles:
        /// - `/reconnect` — Updates optional `VersionCompatibility` overrides and
        ///   posts a NotificationCenter event so `ContentView` can kick a reconnect.
        ///
        /// Only active when the app is launched with `--e2e-test`.
        @MainActor
        final public class TestAccessibilityServer {
            private var listener: NWListener?
            private static var instance: TestAccessibilityServer?

            /// Start the server if running in E2E test mode.
            /// Reads `--test-accessibility-port <port>` from launch arguments (default: 18090).
            public static func startIfNeeded() {
                guard CommandLine.arguments.contains("--e2e-test") else { return }

                var port: UInt16 = 18_090
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
                    print("[TestAccessibilityServer-iOS] Failed to start: \(error)")
                }
            }

            private func start(port: UInt16) throws {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    print("[TestAccessibilityServer-iOS] Invalid port: \(port)")
                    return
                }
                listener = try NWListener(using: params, on: nwPort)
                listener?.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        print("[TestAccessibilityServer-iOS] Listener failed: \(error)")
                    }
                }
                listener?.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                listener?.start(queue: .main)
                print("[TestAccessibilityServer-iOS] Listening on port \(port)")
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

                    if request.hasPrefix("POST /reconnect") {
                        let appVersion = Self.extractQueryParam(from: request, key: "appVersion")
                        let minRequired = Self.extractQueryParam(
                            from: request, key: "minRequiredPartnerVersion"
                        )
                        Task { @MainActor in
                            if let appVersion {
                                VersionCompatibility.appVersionOverride = appVersion.isEmpty ? nil : appVersion
                            }
                            if let minRequired {
                                VersionCompatibility.minRequiredPartnerVersionOverride =
                                    minRequired.isEmpty ? nil : minRequired
                            }
                            NotificationCenter.default.post(
                                name: .init("com.claudespy.e2e.reconnectHosts"), object: nil
                            )
                            let response = Data(
                                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
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
            /// e.g. "POST /reconnect?appVersion=1.23 HTTP/1.1\r\n..." → "1.23"
            private nonisolated static func extractQueryParam(from request: String, key: String) -> String? {
                guard let requestLine = request.components(separatedBy: "\r\n").first else { return nil }
                guard let questionMark = requestLine.firstIndex(of: "?") else { return nil }
                let afterQuestion = requestLine[requestLine.index(after: questionMark)...]
                let queryString = afterQuestion.components(separatedBy: " ").first ?? String(afterQuestion)
                for pair in queryString.components(separatedBy: "&") {
                    let parts = pair.components(separatedBy: "=")
                    guard parts.count == 2, parts[0] == key else { continue }
                    let decoded = parts[1]
                        .replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? parts[1]
                    return decoded
                }
                return nil
            }
        }
    #endif
#endif

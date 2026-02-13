import Foundation

public extension String {
    /// Converts a WebSocket URL string to its HTTP equivalent.
    ///
    /// Replaces `wss://` with `https://` and `ws://` with `http://`,
    /// using `URLComponents` for safe scheme replacement.
    var httpURL: String {
        guard var components = URLComponents(string: self) else { return self }
        switch components.scheme {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        default: return self
        }
        return components.string ?? self
    }
}

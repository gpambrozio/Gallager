import Foundation

public extension URL {
    /// Creates a URL from a compile-time string literal.
    ///
    /// Fails fatally if the literal is not a valid URL — catching malformed
    /// URLs at development time rather than crashing at runtime behind an
    /// optional force-unwrap.
    init(staticString: StaticString) {
        guard let url = URL(string: "\(staticString)") else {
            preconditionFailure("Invalid static URL: \(staticString)")
        }
        self = url
    }
}

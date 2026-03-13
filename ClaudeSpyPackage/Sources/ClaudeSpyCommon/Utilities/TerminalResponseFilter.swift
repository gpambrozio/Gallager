import Foundation

/// Filters terminal query/response sequences to prevent feedback loops in mirrored terminals.
///
/// Two complementary filters:
/// - ``stripDAQueries(_:)`` removes DA *query* sequences from the feed data before SwiftTerm
///   processes them, preventing it from generating responses in the first place.
/// - ``isTerminalResponse(_:)`` catches any auto-generated *response* sequences in the
///   `send()` delegate as a defense-in-depth fallback.
public enum TerminalResponseFilter {
    // MARK: - Feed-level: strip DA queries

    /// Strips Device Attributes query sequences from terminal output data so that
    /// mirroring SwiftTerm instances never see them and never generate responses.
    ///
    /// Matched queries (all are short CSI sequences ending with `c`):
    /// - Primary DA:   `ESC [ c`  or  `ESC [ 0 c`
    /// - Secondary DA: `ESC [ > c` or `ESC [ > 0 c`
    /// - Tertiary DA:  `ESC [ = c` or `ESC [ = 0 c`
    ///
    /// Returns the data with all matching sequences removed. If no queries are found
    /// the original data is returned unchanged (no copy).
    public static func stripDAQueries(_ data: Data) -> Data {
        // Fast path: no ESC byte → nothing to strip
        guard data.contains(0x1B) else { return data }

        var result = Data()
        result.reserveCapacity(data.count)
        var i = data.startIndex

        while i < data.endIndex {
            // Look for ESC
            guard data[i] == 0x1B else {
                result.append(data[i])
                i = data.index(after: i)
                continue
            }

            // Need at least ESC [ c (3 bytes)
            let remaining = data.distance(from: i, to: data.endIndex)
            guard remaining >= 3, data[i + 1] == 0x5B else { // [
                result.append(data[i])
                i = data.index(after: i)
                continue
            }

            let third = data[i + 2]

            // ESC [ c — Primary DA (no params)
            if third == 0x63 {
                i += 3
                continue
            }

            // ESC [ 0 c — Primary DA (explicit zero param)
            if third == 0x30, remaining >= 4, data[i + 3] == 0x63 {
                i += 4
                continue
            }

            // ESC [ > ... and ESC [ = ...
            if third == 0x3E || third == 0x3D { // > or =
                // ESC [ > c or ESC [ = c (no params)
                if remaining >= 4, data[i + 3] == 0x63 {
                    i += 4
                    continue
                }
                // ESC [ > 0 c or ESC [ = 0 c (explicit zero param)
                if remaining >= 5, data[i + 3] == 0x30, data[i + 4] == 0x63 {
                    i += 5
                    continue
                }
            }

            // Not a DA query — pass through
            result.append(data[i])
            i = data.index(after: i)
        }

        // If nothing was stripped, return original to avoid unnecessary copy
        return result.count == data.count ? data : result
    }

    // MARK: - Send-level: detect terminal responses (defense-in-depth)

    /// Detects terminal auto-response sequences that SwiftTerm generates internally.
    /// Used as a fallback filter in the `send()` delegate path.
    public static func isTerminalResponse(_ data: ArraySlice<UInt8>) -> Bool {
        guard
            data.count >= 3,
            data[data.startIndex] == 0x1B, // ESC
            data[data.startIndex + 1] == 0x5B // [
        else { return false }

        let thirdByte = data[data.startIndex + 2]
        let lastByte = data[data.index(before: data.endIndex)]

        // Primary DA response: ESC [ ? ... c
        if thirdByte == 0x3F, lastByte == 0x63 { return true } // ?...c
        // Secondary DA response: ESC [ > ... c
        if thirdByte == 0x3E, lastByte == 0x63 { return true } // >...c
        // Cursor Position Report: ESC [ digits ; digits R
        if thirdByte >= 0x30, thirdByte <= 0x39, lastByte == 0x52 { return true } // digit...R
        // Terminal Parameter Report: ESC [ digits ... x
        if thirdByte >= 0x30, thirdByte <= 0x39, lastByte == 0x78 { return true } // digit...x

        return false
    }
}

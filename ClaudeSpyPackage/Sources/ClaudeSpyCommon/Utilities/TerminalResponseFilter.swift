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

    // MARK: - Feed-level: strip DSR queries

    /// Strips Device Status Report query sequences from terminal output data so that
    /// mirroring SwiftTerm instances never see them and never generate responses.
    ///
    /// Matched queries (all end with `n` and carry a digit parameter):
    /// - DSR-OS:        `ESC [ 5 n`
    /// - CPR:           `ESC [ 6 n`        → would respond `ESC [ row ; col R`
    /// - DECXCPR:       `ESC [ ? 6 n`      → would respond `ESC [ ? row ; col ; page R`
    /// - DEC private:   `ESC [ ? 15 n`, `ESC [ ? 25 n`, `ESC [ ? 26 n`, etc.
    ///
    /// Without this filter, SwiftTerm processes the query and forwards the response via
    /// its `send()` delegate; the response is then sent back to tmux as input and appears
    /// as typed garbage in the user's pane (e.g. `[?58;3;1R`).
    ///
    /// Returns the data with all matching sequences removed. If no queries are found
    /// the original data is returned unchanged (no copy).
    public static func stripDSRQueries(_ data: Data) -> Data {
        guard data.contains(0x1B) else { return data }

        var result = Data()
        result.reserveCapacity(data.count)
        var i = data.startIndex

        while i < data.endIndex {
            guard data[i] == 0x1B else {
                result.append(data[i])
                i = data.index(after: i)
                continue
            }

            // Need at least ESC [ digit n (4 bytes)
            let remaining = data.distance(from: i, to: data.endIndex)
            guard remaining >= 4, data[i + 1] == 0x5B else { // [
                result.append(data[i])
                i = data.index(after: i)
                continue
            }

            // Optional '?' prefix for DEC private DSR queries
            var j = i + 2
            if data[j] == 0x3F { // ?
                j += 1
            }

            // Scan parameter bytes (digits and semicolons). Require ≥1 digit
            // so we don't accidentally strip sequences like ESC[;;n (valid CSI
            // syntax but never emitted as a real DSR query by any program).
            var sawDigit = false
            while j < data.endIndex {
                let b = data[j]
                if b >= 0x30, b <= 0x39 {
                    sawDigit = true
                    j += 1
                } else if b == 0x3B { // ';'
                    j += 1
                } else {
                    break
                }
            }

            // Must have ≥1 digit and end with 'n' (0x6E)
            if sawDigit, j < data.endIndex, data[j] == 0x6E {
                i = j + 1
                continue
            }

            // Not a DSR query — pass ESC through
            result.append(data[i])
            i = data.index(after: i)
        }

        return result.count == data.count ? data : result
    }

    // MARK: - Feed-level: strip Kitty keyboard protocol sequences

    /// Strips Kitty keyboard protocol negotiation sequences from terminal output
    /// so that mirroring SwiftTerm instances never enter an unsupported keyboard mode.
    ///
    /// Matched sequences (all end with `u`):
    /// - Push mode:  `ESC [ > Ps u`   (enable progressive enhancement)
    /// - Pop mode:   `ESC [ < Ps u`   or `ESC [ < u`
    /// - Query mode: `ESC [ ? u`      (terminal responds with `ESC [ ? Ps u`)
    /// - Set flags:  `ESC [ = Ps ; Ps u`
    ///
    /// Returns the data with all matching sequences removed.
    public static func stripKittyKeyboardProtocol(_ data: Data) -> Data {
        guard data.contains(0x1B) else { return data }

        var result = Data()
        result.reserveCapacity(data.count)
        var i = data.startIndex

        while i < data.endIndex {
            guard data[i] == 0x1B else {
                result.append(data[i])
                i += 1
                continue
            }

            let remaining = data.distance(from: i, to: data.endIndex)
            // Need at least ESC [ X u (4 bytes)
            guard remaining >= 4, data[i + 1] == 0x5B else {
                result.append(data[i])
                i += 1
                continue
            }

            let third = data[i + 2]

            // Only match private-use parameter prefixes: > < ? =
            if third == 0x3E || third == 0x3C || third == 0x3F || third == 0x3D {
                // Scan forward for 'u' (0x75) as final byte.
                // Valid parameter bytes are digits (0x30-0x39) and semicolons (0x3B).
                var j = i + 3
                var foundTerminator = false

                while j < data.endIndex {
                    let b = data[j]
                    if b == 0x75 { // 'u'
                        foundTerminator = true
                        i = j + 1
                        break
                    } else if (b >= 0x30 && b <= 0x39) || b == 0x3B {
                        j += 1
                    } else {
                        break // Not a kitty keyboard sequence
                    }
                }

                if foundTerminator {
                    continue // i already advanced past the sequence
                }
            }

            // Not a kitty sequence — pass ESC byte through
            result.append(data[i])
            i += 1
        }

        return result.count == data.count ? data : result
    }

    // MARK: - Send-level: detect mouse escape sequences

    /// Detects mouse escape sequences generated by SwiftTerm when mouse mode is active.
    /// Used to route mouse events as raw bytes to tmux, bypassing TmuxKey conversion
    /// (the CSI parser can't handle private-use parameter prefixes like `<`).
    ///
    /// Matched formats:
    /// - SGR mouse:    `ESC [ < Cb ; Cx ; Cy M/m`  (press/motion or release)
    /// - X10/normal:   `ESC [ M Cb Cx Cy`           (3 raw bytes after M)
    public static func isMouseEscapeSequence(_ data: ArraySlice<UInt8>) -> Bool {
        guard
            data.count >= 3,
            data[data.startIndex] == 0x1B, // ESC
            data[data.startIndex + 1] == 0x5B // [
        else { return false }

        let third = data[data.startIndex + 2]

        // SGR mouse: ESC [ < Cb ; Cx ; Cy M/m  (minimum 10 bytes: \x1b[<0;1;1M)
        if third == 0x3C, data.count >= 10 { // '<'
            guard let last = data.last, last == 0x4D || last == 0x6D else { return false }
            // Validate body contains only digits and semicolons (Cb;Cx;Cy)
            for i in (data.startIndex + 3)..<(data.endIndex - 1) {
                let b = data[i]
                guard (b >= 0x30 && b <= 0x39) || b == 0x3B else { return false }
            }
            return true
        }

        // X10/normal mouse: ESC [ M followed by 3 bytes
        if third == 0x4D, data.count >= 6 { // 'M'
            return true
        }

        return false
    }

    /// Detects SGR mouse *motion* events (button flag has bit 5 set) which some
    /// apps misinterpret as clicks. Used to suppress motion events generated by
    /// SwiftTerm's own tracking areas that bypass the overlay.
    ///
    /// SGR motion format: `ESC [ < Cb ; Cx ; Cy M/m` where Cb has bit 5 (32) set.
    public static func isMouseMotionEvent(_ data: ArraySlice<UInt8>) -> Bool {
        // Must be a valid SGR mouse sequence: ESC [ < ... M/m
        guard
            data.count >= 10,
            data[data.startIndex] == 0x1B,
            data[data.startIndex + 1] == 0x5B,
            data[data.startIndex + 2] == 0x3C
        else { return false }

        guard let last = data.last, last == 0x4D || last == 0x6D else { return false }

        // Parse the button number (Cb) — digits between '<' and first ';'
        var button = 0
        var i = data.startIndex + 3
        while i < data.endIndex {
            let b = data[i]
            if b >= 0x30 && b <= 0x39 { // digit
                button = button * 10 + Int(b - 0x30)
            } else {
                break // hit ';' or something else
            }
            i += 1
        }

        // Bit 5 (value 32) indicates motion
        return button & 32 != 0
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
        // Extended Cursor Position Report (DECXCPR): ESC [ ? digits ; digits ; digits R
        if thirdByte == 0x3F, lastByte == 0x52 { return true } // ?...R
        // Terminal Parameter Report: ESC [ digits ... x
        if thirdByte >= 0x30, thirdByte <= 0x39, lastByte == 0x78 { return true } // digit...x
        // Kitty keyboard protocol response: ESC [ ? ... u
        if thirdByte == 0x3F, lastByte == 0x75 { return true } // ?...u

        return false
    }
}

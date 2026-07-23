import Foundation

/// Filters terminal query/response sequences to prevent feedback loops in mirrored terminals.
///
/// Two complementary layers:
/// - Feed-level strippers remove *query* sequences from the feed data before SwiftTerm
///   processes them, preventing it from generating responses in the first place:
///   ``stripDAQueries(_:)`` (Device Attributes), ``stripDSRQueries(_:)`` (Device Status
///   Report), ``stripDECRQMQueries(_:)`` (Request Mode), ``stripKittyKeyboardProtocol(_:)``,
///   and ``stripOSCColorQueries(_:)`` (background/foreground/cursor/palette probes).
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
        stripCSIQueries(data) { d, j in
            // Terminator: 'n' (0x6E)
            guard j < d.endIndex, d[j] == 0x6E else { return nil }
            return 1
        }
    }

    // MARK: - Feed-level: strip DECRQM (Request Mode) queries

    /// Strips DEC Request Mode query sequences from terminal output data so that
    /// mirroring SwiftTerm instances never see them and never generate `DECRPM`
    /// responses.
    ///
    /// Matched queries (CSI with `$` intermediate byte and final `p`):
    /// - Standard:    `ESC [ Pm $ p`
    /// - DEC private: `ESC [ ? Pm $ p`   (e.g. mode 2026 = synchronized output)
    ///
    /// Without this filter, SwiftTerm replies `ESC [ ? Pm ; Ps $ y` (DECRPM) via
    /// its `send()` delegate; the response is then forwarded to tmux as input and
    /// appears as visible text (e.g. `[?2026;2$y`).
    ///
    /// Returns the data with all matching sequences removed. If no queries are
    /// found the original data is returned unchanged (no copy).
    public static func stripDECRQMQueries(_ data: Data) -> Data {
        stripCSIQueries(data) { d, j in
            // Terminator: '$' (0x24) intermediate + 'p' (0x70) final
            guard
                j + 1 < d.endIndex,
                d[j] == 0x24,
                d[j + 1] == 0x70
            else { return nil }
            return 2
        }
    }

    // MARK: - Feed-level: shared CSI query stripper

    /// Strips CSI query sequences of the form `ESC [ (?)? digits;… <terminator>` from
    /// `data`. Used by ``stripDSRQueries(_:)`` and ``stripDECRQMQueries(_:)``.
    ///
    /// - Parameters:
    ///   - data: Raw bytes to scan.
    ///   - terminator: Closure that, given the data and the index immediately after
    ///     the parameter bytes, returns the number of bytes the terminator occupies
    ///     (or `nil` if no match). Lets each caller handle both single-byte
    ///     terminators (e.g. `n`) and intermediate+final pairs (e.g. `$p`).
    ///
    /// The parameter-byte scan requires ≥1 digit so valid-but-degenerate CSI
    /// sequences like `ESC[;;n` (semicolons only) are passed through unchanged —
    /// no real terminal program emits those as queries.
    private static func stripCSIQueries(
        _ data: Data,
        terminator: (Data, Data.Index) -> Int?
    ) -> Data {
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

            // Need at least ESC [ digit X (4 bytes)
            let remaining = data.distance(from: i, to: data.endIndex)
            guard remaining >= 4, data[i + 1] == 0x5B else { // [
                result.append(data[i])
                i = data.index(after: i)
                continue
            }

            // Optional '?' prefix for DEC private sequences
            var j = i + 2
            if data[j] == 0x3F { // ?
                j += 1
            }

            // Scan parameter bytes (digits and semicolons). Require ≥1 digit.
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

            // Must have ≥1 digit, then a matching terminator
            if sawDigit, let terminatorLength = terminator(data, j) {
                i = j + terminatorLength
                continue
            }

            // No match — pass ESC through
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

    // MARK: - Feed-level: strip OSC color queries

    /// OSC codes whose *query* form (`?` payload) makes SwiftTerm emit a color
    /// report back through its `send()` delegate:
    /// - `4`  — indexed palette color (`ESC ] 4 ; n ; ? …`)
    /// - `10` — foreground color     (`ESC ] 10 ; ? …`)
    /// - `11` — background color     (`ESC ] 11 ; ? …`)
    /// - `12` — cursor color         (`ESC ] 12 ; ? …`)
    ///
    /// Deliberately excludes OSC codes whose payload may legitimately contain a
    /// `?` (e.g. `8` hyperlinks with query strings, `0`/`1`/`2` titles).
    private static let oscColorQueryCodes: Set = [4, 10, 11, 12]

    /// Strips OSC color *query* sequences from terminal output data so that
    /// mirroring SwiftTerm instances never see them and never generate the
    /// corresponding color report.
    ///
    /// Modern TUIs (opencode's Charm/Bubble Tea stack, pi's Node stack, etc.)
    /// probe the terminal's background/foreground color on startup for light/dark
    /// theme detection, e.g. `ESC ] 11 ; ? BEL`. SwiftTerm answers with
    /// `ESC ] 11 ; rgb:RRRR/GGGG/BBBB ST` via its `send()` delegate; forwarded to
    /// tmux as input, that reply appears as typed garbage like `11;rgb:1c1c/…`
    /// at the start of an agent session (issue #669).
    ///
    /// Matched queries — OSC introducer, one of ``oscColorQueryCodes``, a payload
    /// that contains at least one `?`, terminated by BEL (`0x07`) or ST (`ESC \`):
    /// - `ESC ] 10 ; ? <BEL|ST>`   (also multi: `ESC ] 10 ; ? ; ? ; ? …`)
    /// - `ESC ] 11 ; ? <BEL|ST>`
    /// - `ESC ] 12 ; ? <BEL|ST>`
    /// - `ESC ] 4 ; n ; ? <BEL|ST>`
    ///
    /// Only the query form (`?` present) is stripped; color-*set* commands for the
    /// same codes carry a value (`rgb:…`, `#…`) and never a `?`, so they pass
    /// through untouched and the mirror still tracks the real colors. One caveat:
    /// a single OSC 4 that mixes set and query params (`ESC ] 4 ; 1 ; rgb:… ; 2 ; ?`)
    /// is stripped whole, set portion included — real TUIs query all-or-nothing.
    ///
    /// Like the other feed-level strippers, this matches within a single read
    /// chunk and does not buffer across reads: a query split across two chunks
    /// passes through and SwiftTerm completes it, but the resulting color report
    /// is then caught by the send-level ``isTerminalResponse(_:)`` backstop.
    ///
    /// Returns the data with all matching sequences removed. If no queries are
    /// found the original data is returned unchanged (no copy).
    public static func stripOSCColorQueries(_ data: Data) -> Data {
        // Fast path: no ESC byte → nothing to strip
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

            // Need at least ESC ] (2 bytes)
            let remaining = data.distance(from: i, to: data.endIndex)
            guard remaining >= 2, data[i + 1] == 0x5D else { // ]
                result.append(data[i])
                i = data.index(after: i)
                continue
            }

            // Parse the numeric OSC code (digits right after `ESC ]`).
            var j = i + 2
            var code = 0
            var sawCodeDigit = false
            while j < data.endIndex, data[j] >= 0x30, data[j] <= 0x39 {
                // Capped: pane bytes are untrusted and an unbounded digit run
                // would trap on Int overflow; a capped value can't match
                // oscColorQueryCodes anyway.
                code = min(code * 10 + Int(data[j] - 0x30), 10_000)
                sawCodeDigit = true
                j += 1
            }
            guard sawCodeDigit, oscColorQueryCodes.contains(code) else {
                result.append(data[i])
                i = data.index(after: i)
                continue
            }

            // Scan the payload for the terminator (BEL or ST), noting whether a
            // `?` (query marker) appears before it.
            var k = j
            var sawQuery = false
            var terminatorEnd: Data.Index?
            while k < data.endIndex {
                let b = data[k]
                if b == 0x07 { // BEL
                    terminatorEnd = k + 1
                    break
                }
                if b == 0x18 || b == 0x1A { // CAN / SUB abort the OSC (xterm)
                    break
                }
                if b == 0x1B { // possible ST: ESC \
                    if k + 1 < data.endIndex, data[k + 1] == 0x5C {
                        terminatorEnd = k + 2
                    }
                    // Either way the OSC ends here (a bare ESC aborts it).
                    break
                }
                if b == 0x3F { sawQuery = true } // ?
                k += 1
            }

            // Only strip a well-terminated *query*; anything else passes through
            // so SwiftTerm sees a set command / partial sequence intact.
            if let terminatorEnd, sawQuery {
                i = terminatorEnd
                continue
            }

            result.append(data[i])
            i = data.index(after: i)
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
    ///
    /// This is a best-effort *fallback*: the feed-level strippers are the primary
    /// defense (SwiftTerm never sees the query, never generates the response), and
    /// this only catches responses that slip through — e.g. a query split across
    /// two feed reads that the stripper couldn't match. It matches two families:
    /// - CSI (`ESC [ …`): the catch-all `ESC [ ? …` rule covers all DEC private
    ///   responses regardless of terminator (Primary DA `?…c`, DECXCPR `?…R`,
    ///   DECRPM `?…$y`, kitty `?…u`, etc.); individual non-`?` shapes are listed
    ///   explicitly.
    /// - OSC (`ESC ] …`): color reports for ``oscColorQueryCodes`` (`ESC ] 11 ; rgb:…`
    ///   etc.).
    ///
    /// A SwiftTerm-generated response is byte-for-byte indistinguishable at the
    /// send layer from a user *pasting* the same bytes (paste does flow through
    /// `send()`), so dropping these can in theory swallow a paste that begins with
    /// one of these sequences. That's an accepted trade-off — such a paste is
    /// vanishingly rare, and the pre-existing CSI `?` catch-all already makes the
    /// same call — kept tolerable because the feed-level strip means real
    /// responses rarely reach here in the first place.
    public static func isTerminalResponse(_ data: ArraySlice<UInt8>) -> Bool {
        guard
            data.count >= 3,
            data[data.startIndex] == 0x1B // ESC
        else { return false }

        let secondByte = data[data.startIndex + 1]

        // OSC color report: ESC ] <4|10|11|12> ; … — defense-in-depth for the
        // color queries stripped at the feed level by stripOSCColorQueries.
        // Also matches the raw *query* form (`ESC ] 11 ; ?`), so a pasted query
        // is swallowed — same accepted paste trade-off as the CSI `?` catch-all.
        if secondByte == 0x5D { return isOSCColorResponse(data) } // ]

        guard secondByte == 0x5B else { return false } // [

        let thirdByte = data[data.startIndex + 2]
        let lastByte = data[data.index(before: data.endIndex)]

        // Catch-all for DEC private responses: ESC [ ? … (any terminator)
        if thirdByte == 0x3F { return true }
        // Secondary DA response: ESC [ > ... c
        if thirdByte == 0x3E, lastByte == 0x63 { return true } // >...c
        // Cursor Position Report: ESC [ digits ; digits R
        if thirdByte >= 0x30, thirdByte <= 0x39, lastByte == 0x52 { return true } // digit...R
        // Terminal Parameter Report: ESC [ digits ... x
        if thirdByte >= 0x30, thirdByte <= 0x39, lastByte == 0x78 { return true } // digit...x
        // Standard DECRPM (Report Mode) response: ESC [ digits ; digits $ y
        if
            thirdByte >= 0x30, thirdByte <= 0x39, lastByte == 0x79, data.count >= 5,
            data[data.index(before: data.index(before: data.endIndex))] == 0x24 // '$'
        { return true } // digit...$y

        return false
    }

    /// Returns `true` if `data` begins with an OSC color report for one of
    /// ``oscColorQueryCodes`` (`ESC ] <code> ; …`). Assumes `data` starts with
    /// `ESC ]`.
    private static func isOSCColorResponse(_ data: ArraySlice<UInt8>) -> Bool {
        var j = data.startIndex + 2
        var code = 0
        var sawDigit = false
        while j < data.endIndex, data[j] >= 0x30, data[j] <= 0x39 {
            // Capped: reachable from paste, and an unbounded digit run would
            // trap on Int overflow; a capped value can't match
            // oscColorQueryCodes anyway.
            code = min(code * 10 + Int(data[j] - 0x30), 10_000)
            sawDigit = true
            j += 1
        }
        // A separator (`;`) must follow the code for a color report payload.
        guard sawDigit, j < data.endIndex, data[j] == 0x3B else { return false } // ;
        return oscColorQueryCodes.contains(code)
    }
}

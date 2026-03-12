import Foundation

/// Detects terminal auto-response sequences that SwiftTerm generates internally.
/// These include Device Attributes (DA1/DA2), Cursor Position Reports, and similar.
///
/// When the terminal emulator processes queries from the running program (e.g., DA queries
/// via `ESC[c`), it generates response sequences. These must NOT be forwarded back as
/// keystrokes — they'd appear as typed garbage in the pane.
public enum TerminalResponseFilter {
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

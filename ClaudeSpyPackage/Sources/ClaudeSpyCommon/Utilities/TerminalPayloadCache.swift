#if canImport(SwiftTerm)
    import SwiftTerm

    /// Owns the OSC 8 hyperlink payload cache for a single SwiftTerm terminal view.
    ///
    /// SwiftTerm sets each cell's `payload` (an OSC 8 hyperlink URL) when it
    /// processes the matching `OSC 8 ;` close sequence. SwiftTerm renders dashed
    /// underlines for those cells when the user hovers with a modifier — but
    /// ClaudeSpy draws its own highlights, so the per-cell payload is cleared
    /// after extraction to suppress double rendering, and the URL is mirrored
    /// here so URL detection still resolves clicks and hover.
    ///
    /// Each cached entry snapshots the cell's `getCharacter()` + `attribute` at
    /// cache time. On subsequent extraction passes, a cell whose current
    /// character or attribute no longer matches the snapshot is treated as
    /// overwritten and its cache entry is dropped — otherwise a click on a
    /// cell whose visible content has changed would still open the original
    /// link.
    ///
    /// The cache is keyed by **absolute** buffer row (`scroll-invariant`), so
    /// lookups remain correct as the terminal scrolls. Callers translate
    /// viewport rows to absolute rows by adding `terminal.buffer.yDisp` before
    /// calling `cellPayload(col:absoluteRow:)`.
    final public class TerminalPayloadCache {
        /// One entry per cached cell.
        public struct CachedPayload: Equatable {
            public let payload: String
            public let character: Character
            public let attribute: Attribute

            public init(payload: String, character: Character, attribute: Attribute) {
                self.payload = payload
                self.character = character
                self.attribute = attribute
            }
        }

        private var entries: [Int: [Int: CachedPayload]] = [:]

        public init() { }

        /// Payload at the given absolute buffer row and column, or `nil` if
        /// the cell has no cached OSC 8 entry.
        public func cellPayload(col: Int, absoluteRow: Int) -> String? {
            entries[absoluteRow]?[col]?.payload
        }

        /// Scans every visible buffer line, mirrors any live OSC 8 payloads
        /// into the cache (along with a character + attribute snapshot of the
        /// cell), and clears SwiftTerm's payload to suppress its own
        /// rendering. Cache entries whose snapshot no longer matches the
        /// current cell are dropped — that's how stale links from overwritten
        /// cells get invalidated.
        ///
        /// Call after every `feed(byteArray:)` on the terminal view so the
        /// cache reflects the latest buffer state.
        public func extractAndClear(from terminal: Terminal) {
            // TinyAtom.empty is internal, but TinyAtom is a single UInt16 struct —
            // empty has code 0 which makes CharData.hasPayload return false.
            assert(
                MemoryLayout<TinyAtom>.size == MemoryLayout<UInt16>.size,
                "TinyAtom layout changed — unsafeBitCast assumption is invalid"
            )
            let emptyAtom = unsafeBitCast(UInt16(0), to: TinyAtom.self)
            let cols = terminal.cols
            let totalLines = terminal.buffer.yDisp + terminal.rows

            for absoluteRow in 0..<totalLines {
                guard let line = terminal.getScrollInvariantLine(row: absoluteRow) else { continue }
                for col in 0..<cols {
                    var cd = line[col]
                    if cd.hasPayload {
                        if let payload = cd.getPayload() as? String, !payload.isEmpty {
                            if entries[absoluteRow] == nil {
                                entries[absoluteRow] = [:]
                            }
                            entries[absoluteRow]?[col] = CachedPayload(
                                payload: payload,
                                character: cd.getCharacter(),
                                attribute: cd.attribute
                            )
                        }
                        cd.setPayload(atom: emptyAtom)
                        line[col] = cd
                    } else if
                        let cached = entries[absoluteRow]?[col],
                        cached.character != cd.getCharacter() || cached.attribute != cd.attribute {
                        // Cell has no live payload and its character or
                        // attribute has changed since we cached — content was
                        // overwritten, so the cached link no longer describes
                        // what's on screen at this position.
                        entries[absoluteRow]?[col] = nil
                    }
                }
                if entries[absoluteRow]?.isEmpty == true {
                    entries.removeValue(forKey: absoluteRow)
                }
            }

            // Prune entries for lines that have been trimmed from the
            // circular buffer entirely (scrollback overflow).
            let minRow = entries.keys.min() ?? 0
            if minRow < totalLines {
                for row in minRow..<totalLines where entries[row] != nil {
                    if terminal.getScrollInvariantLine(row: row) == nil {
                        entries.removeValue(forKey: row)
                    } else {
                        // Lines are contiguous — once we find a valid one, the rest are valid.
                        break
                    }
                }
            }
        }
    }
#endif

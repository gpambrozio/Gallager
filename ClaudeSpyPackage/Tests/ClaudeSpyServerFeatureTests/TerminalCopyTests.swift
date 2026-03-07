#if os(macOS)
    import AppKit
    import Testing
    @testable import ClaudeSpyServerFeature
    @testable import SwiftTerm

    // MARK: - Type Aliases

    private typealias ITV = InteractiveTerminalView

    // MARK: - SGR Color Params Tests

    @Suite("sgrColorParams")
    @MainActor
    struct SGRColorParamsTests {
        // MARK: - Default Colors

        @Test("Default color returns empty params")
        func defaultColor() {
            #expect(ITV.sgrColorParams(.defaultColor, isFg: true) == [])
            #expect(ITV.sgrColorParams(.defaultColor, isFg: false) == [])
        }

        @Test("Default inverted color returns empty params")
        func defaultInvertedColor() {
            #expect(ITV.sgrColorParams(.defaultInvertedColor, isFg: true) == [])
            #expect(ITV.sgrColorParams(.defaultInvertedColor, isFg: false) == [])
        }

        // MARK: - Standard Colors (0-7)

        @Test(
            "Standard foreground colors produce codes 30-37",
            arguments: [
                (UInt8(0), "30"), (UInt8(1), "31"), (UInt8(2), "32"), (UInt8(3), "33"),
                (UInt8(4), "34"), (UInt8(5), "35"), (UInt8(6), "36"), (UInt8(7), "37"),
            ]
        )
        func standardFgColors(code: UInt8, expected: String) {
            #expect(ITV.sgrColorParams(.ansi256(code: code), isFg: true) == [expected])
        }

        @Test(
            "Standard background colors produce codes 40-47",
            arguments: [
                (UInt8(0), "40"), (UInt8(1), "41"), (UInt8(2), "42"), (UInt8(3), "43"),
                (UInt8(4), "44"), (UInt8(5), "45"), (UInt8(6), "46"), (UInt8(7), "47"),
            ]
        )
        func standardBgColors(code: UInt8, expected: String) {
            #expect(ITV.sgrColorParams(.ansi256(code: code), isFg: false) == [expected])
        }

        // MARK: - Bright Colors (8-15)

        @Test(
            "Bright foreground colors produce codes 90-97",
            arguments: [
                (UInt8(8), "90"), (UInt8(9), "91"), (UInt8(10), "92"), (UInt8(11), "93"),
                (UInt8(12), "94"), (UInt8(13), "95"), (UInt8(14), "96"), (UInt8(15), "97"),
            ]
        )
        func brightFgColors(code: UInt8, expected: String) {
            #expect(ITV.sgrColorParams(.ansi256(code: code), isFg: true) == [expected])
        }

        @Test(
            "Bright background colors produce codes 100-107",
            arguments: [
                (UInt8(8), "100"), (UInt8(9), "101"), (UInt8(10), "102"), (UInt8(11), "103"),
                (UInt8(12), "104"), (UInt8(13), "105"), (UInt8(14), "106"), (UInt8(15), "107"),
            ]
        )
        func brightBgColors(code: UInt8, expected: String) {
            #expect(ITV.sgrColorParams(.ansi256(code: code), isFg: false) == [expected])
        }

        // MARK: - Extended 256 Colors (16-255)

        @Test("Extended foreground color uses 38;5;N format")
        func extendedFg() {
            #expect(ITV.sgrColorParams(.ansi256(code: 16), isFg: true) == ["38", "5", "16"])
            #expect(ITV.sgrColorParams(.ansi256(code: 196), isFg: true) == ["38", "5", "196"])
            #expect(ITV.sgrColorParams(.ansi256(code: 255), isFg: true) == ["38", "5", "255"])
        }

        @Test("Extended background color uses 48;5;N format")
        func extendedBg() {
            #expect(ITV.sgrColorParams(.ansi256(code: 16), isFg: false) == ["48", "5", "16"])
            #expect(ITV.sgrColorParams(.ansi256(code: 232), isFg: false) == ["48", "5", "232"])
        }

        // MARK: - Boundary Values

        @Test("Code 7 is last standard color, code 8 is first bright")
        func standardBrightBoundary() {
            #expect(ITV.sgrColorParams(.ansi256(code: 7), isFg: true) == ["37"])
            #expect(ITV.sgrColorParams(.ansi256(code: 8), isFg: true) == ["90"])
        }

        @Test("Code 15 is last bright color, code 16 is first extended")
        func brightExtendedBoundary() {
            #expect(ITV.sgrColorParams(.ansi256(code: 15), isFg: true) == ["97"])
            #expect(ITV.sgrColorParams(.ansi256(code: 16), isFg: true) == ["38", "5", "16"])
        }

        // MARK: - True Color

        @Test("True color foreground uses 38;2;R;G;B format")
        func trueColorFg() {
            #expect(
                ITV.sgrColorParams(.trueColor(red: 255, green: 128, blue: 0), isFg: true)
                    == ["38", "2", "255", "128", "0"]
            )
        }

        @Test("True color background uses 48;2;R;G;B format")
        func trueColorBg() {
            #expect(
                ITV.sgrColorParams(.trueColor(red: 0, green: 0, blue: 0), isFg: false)
                    == ["48", "2", "0", "0", "0"]
            )
        }

        @Test("True color with max values")
        func trueColorMax() {
            #expect(
                ITV.sgrColorParams(.trueColor(red: 255, green: 255, blue: 255), isFg: true)
                    == ["38", "2", "255", "255", "255"]
            )
        }
    }

    // MARK: - SGR Sequence Tests

    @Suite("sgrSequence")
    @MainActor
    struct SGRSequenceTests {
        @Test("Default attribute produces reset-only sequence")
        func defaultAttribute() {
            let attr = Attribute.empty
            let result = ITV.sgrSequence(for: attr)
            #expect(result == "\u{1B}[0m")
        }

        @Test("Bold style appends code 1")
        func boldStyle() {
            let attr = Attribute(fg: .defaultColor, bg: .defaultInvertedColor, style: .bold)
            let result = ITV.sgrSequence(for: attr)
            #expect(result == "\u{1B}[0;1m")
        }

        @Test("Multiple styles produce correct codes in order")
        func multipleStyles() {
            let style: CharacterStyle = [.bold, .italic, .underline]
            let attr = Attribute(fg: .defaultColor, bg: .defaultInvertedColor, style: style)
            let result = ITV.sgrSequence(for: attr)
            #expect(result.contains(";1"))
            #expect(result.contains(";3"))
            #expect(result.contains(";4"))
        }

        @Test("All style flags produce correct SGR codes")
        func allStyles() {
            let style: CharacterStyle = [.bold, .dim, .italic, .underline, .blink, .inverse, .invisible, .crossedOut]
            let attr = Attribute(fg: .defaultColor, bg: .defaultInvertedColor, style: style)
            let result = ITV.sgrSequence(for: attr)
            for code in ["1", "2", "3", "4", "5", "7", "8", "9"] {
                #expect(result.contains(";\(code)"), "Missing style code \(code)")
            }
        }

        @Test("Foreground color is included in sequence")
        func fgColor() {
            let attr = Attribute(fg: .ansi256(code: 1), bg: .defaultInvertedColor, style: .none)
            let result = ITV.sgrSequence(for: attr)
            #expect(result == "\u{1B}[0;31m")
        }

        @Test("Background color is included in sequence")
        func bgColor() {
            let attr = Attribute(fg: .defaultColor, bg: .ansi256(code: 4), style: .none)
            let result = ITV.sgrSequence(for: attr)
            #expect(result == "\u{1B}[0;44m")
        }

        @Test("Both fg and bg colors in sequence")
        func fgAndBgColor() {
            let attr = Attribute(fg: .ansi256(code: 2), bg: .ansi256(code: 5), style: .none)
            let result = ITV.sgrSequence(for: attr)
            #expect(result == "\u{1B}[0;32;45m")
        }

        @Test("Bold with red foreground on blue background")
        func fullCombination() {
            let attr = Attribute(fg: .ansi256(code: 1), bg: .ansi256(code: 4), style: .bold)
            let result = ITV.sgrSequence(for: attr)
            #expect(result == "\u{1B}[0;1;31;44m")
        }

        @Test("True color foreground in sequence")
        func trueColorInSequence() {
            let attr = Attribute(fg: .trueColor(red: 135, green: 0, blue: 255), bg: .defaultInvertedColor, style: .none)
            let result = ITV.sgrSequence(for: attr)
            #expect(result == "\u{1B}[0;38;2;135;0;255m")
        }

        @Test("Underline color with ansi256")
        func underlineColorAnsi256() {
            let attr = Attribute(
                fg: .defaultColor, bg: .defaultInvertedColor, style: .underline,
                underlineColor: .ansi256(code: 196)
            )
            let result = ITV.sgrSequence(for: attr)
            #expect(result.contains(";58;5;196"))
        }

        @Test("Underline color with true color")
        func underlineColorTrueColor() {
            let attr = Attribute(
                fg: .defaultColor, bg: .defaultInvertedColor, style: .underline,
                underlineColor: .trueColor(red: 255, green: 0, blue: 0)
            )
            let result = ITV.sgrSequence(for: attr)
            #expect(result.contains(";58;2;255;0;0"))
        }
    }

    // MARK: - Trim Trailing Whitespace Per Line Tests

    @Suite("trimTrailingWhitespacePerLine")
    @MainActor
    struct TrimTrailingWhitespaceTests {
        @Test("Empty string returns empty")
        func emptyString() {
            #expect(ITV.trimTrailingWhitespacePerLine("") == "")
        }

        @Test("No trailing whitespace is unchanged")
        func noTrailingWhitespace() {
            #expect(ITV.trimTrailingWhitespacePerLine("hello") == "hello")
        }

        @Test("Trailing spaces are removed")
        func trailingSpaces() {
            #expect(ITV.trimTrailingWhitespacePerLine("hello   ") == "hello")
        }

        @Test("Trailing tabs are removed")
        func trailingTabs() {
            #expect(ITV.trimTrailingWhitespacePerLine("hello\t\t") == "hello")
        }

        @Test("Mixed trailing whitespace is removed")
        func mixedTrailingWhitespace() {
            #expect(ITV.trimTrailingWhitespacePerLine("hello \t ") == "hello")
        }

        @Test("Leading whitespace is preserved")
        func leadingWhitespacePreserved() {
            #expect(ITV.trimTrailingWhitespacePerLine("  hello") == "  hello")
        }

        @Test("Middle whitespace is preserved")
        func middleWhitespacePreserved() {
            #expect(ITV.trimTrailingWhitespacePerLine("hello  world") == "hello  world")
        }

        @Test("Multiple lines trimmed independently")
        func multipleLines() {
            let input = "hello   \nworld  \nfoo"
            let expected = "hello\nworld\nfoo"
            #expect(ITV.trimTrailingWhitespacePerLine(input) == expected)
        }

        @Test("Empty lines are preserved")
        func emptyLinesPreserved() {
            let input = "hello   \n\nworld  "
            let expected = "hello\n\nworld"
            #expect(ITV.trimTrailingWhitespacePerLine(input) == expected)
        }

        @Test("Whitespace-only lines become empty")
        func whitespaceOnlyLines() {
            let input = "hello\n   \nworld"
            let expected = "hello\n\nworld"
            #expect(ITV.trimTrailingWhitespacePerLine(input) == expected)
        }

        @Test("Single newline preserved")
        func singleNewline() {
            #expect(ITV.trimTrailingWhitespacePerLine("\n") == "\n")
        }

        @Test("Multiple empty lines preserved")
        func multipleEmptyLines() {
            #expect(ITV.trimTrailingWhitespacePerLine("\n\n\n") == "\n\n\n")
        }

        @Test("Line with only whitespace before newline")
        func whitespaceBeforeNewline() {
            let input = "   \n   \n"
            let expected = "\n\n"
            #expect(ITV.trimTrailingWhitespacePerLine(input) == expected)
        }

        @Test("ANSI escape sequences in text are not trimmed")
        func ansiEscapesPreserved() {
            let input = "\u{1B}[31mred\u{1B}[0m   "
            let expected = "\u{1B}[31mred\u{1B}[0m"
            #expect(ITV.trimTrailingWhitespacePerLine(input) == expected)
        }
    }

    // MARK: - Trim Trailing Whitespace From Attributed String Tests

    @Suite("trimTrailingWhitespaceFromAttributedString")
    @MainActor
    struct TrimAttributedStringWhitespaceTests {
        private func makeAttr(_ string: String) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }

        @Test("Empty attributed string returns empty")
        func emptyString() {
            let input = makeAttr("")
            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "")
        }

        @Test("No trailing whitespace is unchanged")
        func noTrailingWhitespace() {
            let input = makeAttr("hello")
            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "hello")
        }

        @Test("Trailing spaces removed from single line")
        func trailingSingleLine() {
            let input = makeAttr("hello   ")
            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "hello")
        }

        @Test("Multiple lines trimmed independently")
        func multipleLines() {
            let input = makeAttr("hello   \nworld  ")
            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "hello\nworld")
        }

        @Test("Preserves newlines between lines")
        func preservesNewlines() {
            let input = makeAttr("a \n b \n c ")
            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "a\n b\n c")
        }

        @Test("Empty lines preserved")
        func emptyLinesPreserved() {
            let input = makeAttr("hello\n\nworld")
            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "hello\n\nworld")
        }

        @Test("Whitespace-only lines become empty")
        func whitespaceOnlyLines() {
            let input = makeAttr("hello\n   \nworld")
            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "hello\n\nworld")
        }

        @Test("Tabs are trimmed")
        func tabsTrimmed() {
            let input = makeAttr("hello\t\t\nworld\t")
            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "hello\nworld")
        }

        @Test("Preserves attributes on non-whitespace content")
        func preservesAttributes() {
            let redAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.red,
                .font: NSFont.systemFont(ofSize: 12),
            ]
            let input = NSMutableAttributedString()
            input.append(NSAttributedString(string: "red", attributes: redAttrs))
            input.append(NSAttributedString(string: "   "))

            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "red")
            let color = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            #expect(color == NSColor.red)
        }

        @Test("Preserves newline attributes")
        func preservesNewlineAttributes() {
            let redAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.red,
                .font: NSFont.systemFont(ofSize: 14),
            ]
            let blueAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.blue,
                .font: NSFont.systemFont(ofSize: 14),
            ]
            let input = NSMutableAttributedString()
            input.append(NSAttributedString(string: "a", attributes: redAttrs))
            input.append(NSAttributedString(string: "\n", attributes: redAttrs))
            input.append(NSAttributedString(string: "b", attributes: blueAttrs))

            let result = ITV.trimTrailingWhitespaceFromAttributedString(input)
            #expect(result.string == "a\nb")
            let nlColor = result.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
            #expect(nlColor == NSColor.red)
        }
    }

    // MARK: - TerminalColorMapper Tests

    @Suite("TerminalColorMapper")
    struct TerminalColorMapperTests {
        let defaultFg = NSColor.white
        let defaultBg = NSColor.black

        private func makeMapper() -> TerminalColorMapper {
            TerminalColorMapper(defaultFg: defaultFg, defaultBg: defaultBg)
        }

        @Test("Default color returns fg/bg defaults")
        func defaultColor() {
            let mapper = makeMapper()
            #expect(mapper.mapColor(.defaultColor, isFg: true, isBold: false) == defaultFg)
            #expect(mapper.mapColor(.defaultColor, isFg: false, isBold: false) == defaultBg)
        }

        @Test("Default inverted color returns swapped fg/bg")
        func defaultInvertedColor() {
            let mapper = makeMapper()
            #expect(mapper.mapColor(.defaultInvertedColor, isFg: true, isBold: false) == defaultBg)
            #expect(mapper.mapColor(.defaultInvertedColor, isFg: false, isBold: false) == defaultFg)
        }

        @Test("Bold with standard color (0-7) uses bright variant (8-15)")
        func boldBrightShift() {
            let mapper = makeMapper()
            let normalColor = mapper.mapColor(.ansi256(code: 1), isFg: true, isBold: false)
            let boldColor = mapper.mapColor(.ansi256(code: 1), isFg: true, isBold: true)
            let brightColor = mapper.mapColor(.ansi256(code: 9), isFg: true, isBold: false)
            #expect(boldColor == brightColor)
            #expect(normalColor != boldColor)
        }

        @Test("Bold does NOT shift bright colors (8-15)")
        func boldNoShiftForBright() {
            let mapper = makeMapper()
            let normalBright = mapper.mapColor(.ansi256(code: 12), isFg: true, isBold: false)
            let boldBright = mapper.mapColor(.ansi256(code: 12), isFg: true, isBold: true)
            #expect(normalBright == boldBright)
        }

        @Test("Bold does NOT shift extended colors (16-255)")
        func boldNoShiftForExtended() {
            let mapper = makeMapper()
            let normal = mapper.mapColor(.ansi256(code: 196), isFg: true, isBold: false)
            let bold = mapper.mapColor(.ansi256(code: 196), isFg: true, isBold: true)
            #expect(normal == bold)
        }

        @Test("True color produces correct NSColor")
        func trueColor() {
            let mapper = makeMapper()
            let color = mapper.mapColor(.trueColor(red: 128, green: 64, blue: 32), isFg: true, isBold: false)
            let expected = NSColor(srgbRed: 128 / 255, green: 64 / 255, blue: 32 / 255, alpha: 1)
            #expect(color == expected)
        }

        @Test("True color black")
        func trueColorBlack() {
            let mapper = makeMapper()
            let color = mapper.mapColor(.trueColor(red: 0, green: 0, blue: 0), isFg: true, isBold: false)
            let expected = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            #expect(color == expected)
        }

        @Test("True color white")
        func trueColorWhite() {
            let mapper = makeMapper()
            let color = mapper.mapColor(.trueColor(red: 255, green: 255, blue: 255), isFg: true, isBold: false)
            let expected = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            #expect(color == expected)
        }

        @Test("256-color palette has correct count — all indices valid")
        func paletteCount() {
            let mapper = makeMapper()
            for i: UInt8 in 0...255 {
                _ = mapper.mapColor(.ansi256(code: i), isFg: true, isBold: false)
            }
        }

        @Test("Greyscale ramp colors are actually grey")
        func greyscaleRamp() {
            let mapper = makeMapper()
            for i: UInt8 in 232...255 {
                let color = mapper.mapColor(.ansi256(code: i), isFg: true, isBold: false)
                guard let srgb = color.usingColorSpace(.sRGB) else { continue }
                #expect(
                    abs(srgb.redComponent - srgb.greenComponent) < 0.001,
                    "Greyscale index \(i) red != green"
                )
                #expect(
                    abs(srgb.greenComponent - srgb.blueComponent) < 0.001,
                    "Greyscale index \(i) green != blue"
                )
            }
        }
    }

    // MARK: - TerminalFontMapper Tests

    @Suite("TerminalFontMapper")
    @MainActor
    struct TerminalFontMapperTests {
        @Test("Normal style returns base font")
        func normalFont() {
            let base = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let mapper = TerminalFontMapper(base: base)
            #expect(mapper.font(for: .none) == base)
        }

        @Test("Bold style returns bold font")
        func boldFont() {
            let base = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let mapper = TerminalFontMapper(base: base)
            let font = mapper.font(for: .bold)
            let fm = NSFontManager.shared
            #expect(fm.traits(of: font).contains(.boldFontMask))
        }

        @Test("Italic style returns italic font")
        func italicFont() {
            let base = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let mapper = TerminalFontMapper(base: base)
            let font = mapper.font(for: .italic)
            let fm = NSFontManager.shared
            #expect(fm.traits(of: font).contains(.italicFontMask))
        }

        @Test("Bold+italic returns combined font")
        func boldItalicFont() {
            let base = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let mapper = TerminalFontMapper(base: base)
            let style: CharacterStyle = [.bold, .italic]
            let font = mapper.font(for: style)
            let fm = NSFontManager.shared
            let traits = fm.traits(of: font)
            #expect(traits.contains(.boldFontMask))
        }

        @Test("Non-font styles return normal font")
        func nonFontStyles() {
            let base = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let mapper = TerminalFontMapper(base: base)
            #expect(mapper.font(for: .underline) == base)
            #expect(mapper.font(for: .inverse) == base)
            #expect(mapper.font(for: .crossedOut) == base)
        }
    }

    // MARK: - SGR Round-Trip Tests

    @Suite("SGR round-trip consistency")
    @MainActor
    struct SGRRoundTripTests {
        /// Feed an SGR sequence into a headless terminal and verify the attribute matches.
        private func feedAndCheck(
            _ sgrString: String,
            expectedFg: Attribute.Color? = nil,
            expectedBg: Attribute.Color? = nil,
            expectedStyle: CharacterStyle? = nil
        ) {
            let delegate = TestTerminalDelegate()
            let terminal = Terminal(delegate: delegate)
            terminal.resize(cols: 40, rows: 5)

            let data = Array("\(sgrString)X\u{1B}[0m".utf8)
            terminal.feed(byteArray: data)

            guard let line = terminal.getLine(row: 0) else {
                Issue.record("Failed to get line 0")
                return
            }
            let attr = line[0].attribute

            if let fg = expectedFg {
                #expect(attr.fg == fg, "Foreground mismatch for \(sgrString)")
            }
            if let bg = expectedBg {
                #expect(attr.bg == bg, "Background mismatch for \(sgrString)")
            }
            if let style = expectedStyle {
                #expect(attr.style == style, "Style mismatch for \(sgrString)")
            }
        }

        @Test("Standard foreground colors round-trip through terminal")
        func standardFgRoundTrip() {
            for code: UInt8 in 0..<8 {
                let attr = Attribute(fg: .ansi256(code: code), bg: .defaultInvertedColor, style: .none)
                let sgr = ITV.sgrSequence(for: attr)
                feedAndCheck(sgr, expectedFg: .ansi256(code: code))
            }
        }

        @Test("Bright foreground colors round-trip through terminal")
        func brightFgRoundTrip() {
            for code: UInt8 in 8..<16 {
                let attr = Attribute(fg: .ansi256(code: code), bg: .defaultInvertedColor, style: .none)
                let sgr = ITV.sgrSequence(for: attr)
                feedAndCheck(sgr, expectedFg: .ansi256(code: code))
            }
        }

        @Test("Standard background colors round-trip through terminal")
        func standardBgRoundTrip() {
            for code: UInt8 in 0..<8 {
                let attr = Attribute(fg: .defaultColor, bg: .ansi256(code: code), style: .none)
                let sgr = ITV.sgrSequence(for: attr)
                feedAndCheck(sgr, expectedBg: .ansi256(code: code))
            }
        }

        @Test("Extended 256-color round-trip")
        func extended256RoundTrip() {
            for code: UInt8 in stride(from: 16, to: 255, by: 17) {
                let attr = Attribute(fg: .ansi256(code: code), bg: .defaultInvertedColor, style: .none)
                let sgr = ITV.sgrSequence(for: attr)
                feedAndCheck(sgr, expectedFg: .ansi256(code: code))
            }
        }

        @Test("True color round-trip")
        func trueColorRoundTrip() {
            let attr = Attribute(
                fg: .trueColor(red: 135, green: 50, blue: 200),
                bg: .defaultInvertedColor,
                style: .none
            )
            let sgr = ITV.sgrSequence(for: attr)
            feedAndCheck(sgr, expectedFg: .trueColor(red: 135, green: 50, blue: 200))
        }

        @Test("Bold style round-trip")
        func boldRoundTrip() {
            let attr = Attribute(fg: .defaultColor, bg: .defaultInvertedColor, style: .bold)
            let sgr = ITV.sgrSequence(for: attr)
            feedAndCheck(sgr, expectedStyle: .bold)
        }

        @Test("Multiple styles round-trip")
        func multiStyleRoundTrip() {
            let style: CharacterStyle = [.bold, .underline, .italic]
            let attr = Attribute(fg: .defaultColor, bg: .defaultInvertedColor, style: style)
            let sgr = ITV.sgrSequence(for: attr)
            feedAndCheck(sgr, expectedStyle: style)
        }

        @Test("Bold red foreground on blue background round-trip")
        func fullAttributeRoundTrip() {
            let attr = Attribute(fg: .ansi256(code: 1), bg: .ansi256(code: 4), style: .bold)
            let sgr = ITV.sgrSequence(for: attr)
            feedAndCheck(sgr, expectedFg: .ansi256(code: 1), expectedBg: .ansi256(code: 4), expectedStyle: .bold)
        }
    }

    // MARK: - Test Helpers

    final private class TestTerminalDelegate: TerminalDelegate {
        func send(source _: Terminal, data _: ArraySlice<UInt8>) { }
        func showCursor(source _: Terminal) { }
        func hideCursor(source _: Terminal) { }
        func setTerminalTitle(source _: Terminal, title _: String) { }
        func setTerminalIconTitle(source _: Terminal, title _: String) { }
        func sizeChanged(source _: Terminal) { }
        func scrolled(source _: Terminal, yDisp _: Int) { }
        func hostCurrentDirectoryUpdated(source _: Terminal) { }
        func hostCurrentDocumentUpdated(source _: Terminal) { }
    }
#endif

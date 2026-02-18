//
//  ClaudeSpyServerTests.swift
//  ClaudeSpyServerTests
//
//  Created by Gustavo Ambrozio on 1/3/26.
//

import Foundation
import Testing

@testable import ClaudeSpyNetworking
@testable import ClaudeSpyServer

struct ClaudeSpyServerTests {
    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }
}

// MARK: - TmuxKey Byte Parsing Tests

struct TmuxKeyParsingTests {
    @Test func parsesPlainText() {
        let data = Data("hello".utf8)
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.text("hello")])
    }

    @Test func parsesEnterKey() {
        // Carriage return
        let crData = Data([0x0D])
        #expect(TmuxKey.from(bytes: crData) == [.enter])

        // Line feed
        let lfData = Data([0x0A])
        #expect(TmuxKey.from(bytes: lfData) == [.enter])
    }

    @Test func parsesBackspace() {
        let data = Data([0x7F])
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.backspace])
    }

    @Test func parsesTab() {
        let data = Data([0x09])
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.tab])
    }

    @Test func parsesEscape() {
        let data = Data([0x1B])
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.escape])
    }

    @Test func parsesSpace() {
        let data = Data([0x20])
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.space])
    }

    @Test func parsesControlCharacters() {
        // Ctrl+C (0x03)
        let ctrlC = Data([0x03])
        #expect(TmuxKey.from(bytes: ctrlC) == [.ctrl("c")])

        // Ctrl+A (0x01)
        let ctrlA = Data([0x01])
        #expect(TmuxKey.from(bytes: ctrlA) == [.ctrl("a")])

        // Ctrl+Z (0x1A)
        let ctrlZ = Data([0x1A])
        #expect(TmuxKey.from(bytes: ctrlZ) == [.ctrl("z")])
    }

    @Test func parsesArrowKeys() {
        // Up arrow: ESC [ A
        let up = Data([0x1B, 0x5B, 0x41])
        #expect(TmuxKey.from(bytes: up) == [.up])

        // Down arrow: ESC [ B
        let down = Data([0x1B, 0x5B, 0x42])
        #expect(TmuxKey.from(bytes: down) == [.down])

        // Right arrow: ESC [ C
        let right = Data([0x1B, 0x5B, 0x43])
        #expect(TmuxKey.from(bytes: right) == [.right])

        // Left arrow: ESC [ D
        let left = Data([0x1B, 0x5B, 0x44])
        #expect(TmuxKey.from(bytes: left) == [.left])
    }

    @Test func parsesHomeAndEnd() {
        // Home: ESC [ H
        let home = Data([0x1B, 0x5B, 0x48])
        #expect(TmuxKey.from(bytes: home) == [.home])

        // End: ESC [ F
        let end = Data([0x1B, 0x5B, 0x46])
        #expect(TmuxKey.from(bytes: end) == [.end])
    }

    @Test func parsesPageUpDown() {
        // Page Up: ESC [ 5 ~
        let pageUp = Data([0x1B, 0x5B, 0x35, 0x7E])
        #expect(TmuxKey.from(bytes: pageUp) == [.pageUp])

        // Page Down: ESC [ 6 ~
        let pageDown = Data([0x1B, 0x5B, 0x36, 0x7E])
        #expect(TmuxKey.from(bytes: pageDown) == [.pageDown])
    }

    @Test func parsesDelete() {
        // Delete: ESC [ 3 ~
        let delete = Data([0x1B, 0x5B, 0x33, 0x7E])
        #expect(TmuxKey.from(bytes: delete) == [.delete])
    }

    @Test func parsesMixedInput() {
        // "hi" + Enter
        var data = Data("hi".utf8)
        data.append(0x0D)
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.text("hi"), .enter])
    }

    @Test func parsesTextWithArrows() {
        // "a" + Left arrow + "b"
        var data = Data("a".utf8)
        data.append(contentsOf: [0x1B, 0x5B, 0x44]) // Left
        data.append(contentsOf: "b".utf8)
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.text("a"), .left, .text("b")])
    }

    @Test func parsesUnicodeText() {
        let data = Data("héllo 世界".utf8)
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.text("héllo"), .space, .text("世界")])
    }

    @Test func parsesTabNotAsCtrlI() {
        // 0x09 should be Tab, not Ctrl+I (even though Ctrl+I generates 0x09)
        // This is intentional: Tab is the more common interpretation
        let data = Data([0x09])
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.tab])
        #expect(keys != [.ctrl("i")])
    }

    @Test func parsesBacktab() {
        // Shift+Tab: ESC [ Z
        let data = Data([0x1B, 0x5B, 0x5A])
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.backtab])
        #expect(TmuxKey.backtab.tmuxKeyName == "BTab")
    }

    @Test func parsesTextWithBacktab() {
        // "hello" + Shift+Tab
        var data = Data("hello".utf8)
        data.append(contentsOf: [0x1B, 0x5B, 0x5A])
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.text("hello"), .backtab])
    }

    @Test func parsesAltMetaKeys() {
        // ESC + b = Meta-b (word backward, sent by Cmd+Left via SwiftTerm)
        let metaB = Data([0x1B, 0x62])
        #expect(TmuxKey.from(bytes: metaB) == [.alt("b")])

        // ESC + f = Meta-f (word forward, sent by Cmd+Right via SwiftTerm)
        let metaF = Data([0x1B, 0x66])
        #expect(TmuxKey.from(bytes: metaF) == [.alt("f")])

        // Meta-b should have tmuxKeyName "M-b"
        #expect(TmuxKey.alt("b").tmuxKeyName == "M-b")

        // Meta key should not use literal mode
        #expect(TmuxKey.alt("b").requiresLiteralMode == false)
    }

    @Test func parsesTextWithMetaKey() {
        // "hello" + Meta-b (word backward)
        var data = Data("hello".utf8)
        data.append(contentsOf: [0x1B, 0x62])
        let keys = TmuxKey.from(bytes: data)

        #expect(keys == [.text("hello"), .alt("b")])
    }

    @Test func parsesUnrecognizedCSISequence() {
        // Unrecognized CSI sequence like cursor position: ESC [ 1 ; 2 H
        // Should not hang the parser - consume and continue
        let data = Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x48, 0x61]) // ESC [ 1 ; 2 H a
        let keys = TmuxKey.from(bytes: data)

        // The unrecognized sequence should be consumed, followed by "a"
        // Exact behavior may vary, but it should not hang
        #expect(!keys.isEmpty)
    }
}

import Testing
@testable import ClaudeSpyCommon

/// Covers the permission-mode chip presentation (issue #597). A *known* mode —
/// including `default` — always yields a chip; only an unknown/unset mode is
/// suppressed, and `bypassPermissions` is the only elevated (loud) one.
@Suite("PermissionModePresentation")
struct PermissionModePresentationTests {
    @Test("nil and empty modes yield no chip (mode not yet known)")
    func unknownModesSuppressed() {
        #expect(PermissionModePresentation(mode: nil) == nil)
        #expect(PermissionModePresentation(mode: "") == nil)
    }

    @Test("default renders a calm, non-elevated chip")
    func defaultChip() {
        let presentation = PermissionModePresentation(mode: "default")
        #expect(presentation?.label == "Default")
        #expect(presentation?.symbol == .shield)
        #expect(presentation?.isElevated == false)
    }

    @Test("the supervision-relevant modes map to their labels; only bypass is elevated")
    func knownModes() {
        #expect(PermissionModePresentation(mode: "plan")?.label == "Plan")
        #expect(PermissionModePresentation(mode: "plan")?.isElevated == false)
        #expect(PermissionModePresentation(mode: "acceptEdits")?.label == "Accept Edits")
        #expect(PermissionModePresentation(mode: "auto")?.label == "Auto")

        let bypass = PermissionModePresentation(mode: "bypassPermissions")
        #expect(bypass?.label == "Bypass")
        #expect(bypass?.isElevated == true)
    }

    @Test("an unrecognized mode passes through as its own label, not suppressed")
    func unrecognizedModePassesThrough() {
        let presentation = PermissionModePresentation(mode: "futureMode")
        #expect(presentation?.label == "futureMode")
        #expect(presentation?.isElevated == false)
    }
}

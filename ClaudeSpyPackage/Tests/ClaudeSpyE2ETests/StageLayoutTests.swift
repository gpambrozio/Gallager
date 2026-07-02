import CoreGraphics
import Testing
@testable import ClaudeSpyE2ELib

@Suite("StageLayout")
struct StageLayoutTests {
    @Test("Instance 0 keeps the canonical origin")
    func instanceZero() {
        let layout = StageLayout(display: CGSize(width: 1_920, height: 1_080))
        #expect(layout.laneOrigin(instance: 0) == CGPoint(x: 10, y: 10))
        #expect(layout.translation(instance: 0) == .zero)
    }

    @Test("Wide display gives a full side-by-side lane to instance 1")
    func sideBySide() {
        let layout = StageLayout(display: CGSize(width: 2_600, height: 1_400))
        #expect(layout.laneOrigin(instance: 1) == CGPoint(x: 1_030, y: 10))
        #expect(layout.translation(instance: 1) == CGVector(dx: 1_020, dy: 0))
    }

    @Test("Narrow display staggers instance 1 diagonally, still fully on-screen")
    func staggered() {
        let layout = StageLayout(display: CGSize(width: 1_920, height: 1_080))
        let origin = layout.laneOrigin(instance: 1)
        // Not the canonical origin (that would fully occlude instance 0)...
        #expect(origin.x > 200)
        #expect(origin.y > 200)
        // ...and the 1000x600 window still fits on the display with margin.
        #expect(origin.x + 1_000 <= 1_920 - 10 + 0.5)
        #expect(origin.y + 600 <= 1_080 - 10 + 0.5)
    }

    @Test("Tiny display clamps to the margin instead of going off-screen")
    func tinyDisplayClamps() {
        let layout = StageLayout(display: CGSize(width: 1_024, height: 640))
        let origin = layout.laneOrigin(instance: 1)
        #expect(origin.x >= 10)
        #expect(origin.y >= 10)
        #expect(origin.x + 1_000 <= 1_024)
    }
}

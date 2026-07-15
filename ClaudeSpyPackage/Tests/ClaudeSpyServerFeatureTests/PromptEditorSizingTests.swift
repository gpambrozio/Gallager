import CoreGraphics
import Testing
@testable import ClaudeSpyServerFeature

@Suite("PromptEditorSizing")
struct PromptEditorSizingTests {
    @Test("Minimum size is half the default, maximum fills the parent")
    func sizeBounds() {
        #expect(PromptEditorSizing.minWidthFraction == PromptEditorSizing.defaultWidthFraction / 2)
        #expect(PromptEditorSizing.minHeightFraction == PromptEditorSizing.defaultHeightFraction / 2)
        #expect(PromptEditorSizing.maxFraction == 1)
    }

    @Test("Width fraction is clamped between half the default and the full parent")
    func widthClamping() {
        #expect(PromptEditorSizing.clampedWidthFraction(0.1) == PromptEditorSizing.minWidthFraction)
        #expect(PromptEditorSizing.clampedWidthFraction(0.9) == 0.9)
        #expect(PromptEditorSizing.clampedWidthFraction(1.2) == 1)
    }

    @Test("Height fraction is clamped between half the default and the full parent")
    func heightClamping() {
        #expect(PromptEditorSizing.clampedHeightFraction(0.1) == PromptEditorSizing.minHeightFraction)
        #expect(PromptEditorSizing.clampedHeightFraction(0.7) == 0.7)
        #expect(PromptEditorSizing.clampedHeightFraction(1.5) == 1)
    }

    @Test("Dragging a trailing handle doubles the pointer delta so the centered card's edge tracks the cursor")
    func widthDrag() {
        // 800pt card in a 1000pt parent; dragging +50pt widens by 100pt.
        #expect(PromptEditorSizing.widthFraction(
            afterDragging: 50, fromWidth: 800, parentWidth: 1_000
        ) == 0.9)
        // No movement keeps the starting width.
        #expect(PromptEditorSizing.widthFraction(
            afterDragging: 0, fromWidth: 800, parentWidth: 1_000
        ) == 0.8)
    }

    @Test("Width drags clamp at the minimum and the full parent width")
    func widthDragClamping() {
        #expect(PromptEditorSizing.widthFraction(
            afterDragging: 200, fromWidth: 800, parentWidth: 1_000
        ) == 1)
        #expect(PromptEditorSizing.widthFraction(
            afterDragging: -250, fromWidth: 800, parentWidth: 1_000
        ) == PromptEditorSizing.minWidthFraction)
    }

    @Test("Dragging a bottom handle moves the top-pinned card's bottom edge 1:1")
    func heightDrag() {
        // 300pt card in a 600pt parent; dragging +60pt grows to 360pt.
        #expect(PromptEditorSizing.heightFraction(
            afterDragging: 60, fromHeight: 300, parentHeight: 600
        ) == 0.6)
    }

    @Test("Height drags clamp at the minimum and the full parent height")
    func heightDragClamping() {
        #expect(PromptEditorSizing.heightFraction(
            afterDragging: 400, fromHeight: 300, parentHeight: 600
        ) == 1)
        #expect(PromptEditorSizing.heightFraction(
            afterDragging: -200, fromHeight: 300, parentHeight: 600
        ) == PromptEditorSizing.minHeightFraction)
    }

    @Test("Typing growth raises the height to fit the content")
    func growToFitContent() {
        let grown = PromptEditorSizing.heightFraction(
            growing: 0.5, toFitRequiredHeight: 400, parentHeight: 600
        )
        #expect(abs(grown - 400 / 600) < 0.0_001)
    }

    @Test("Typing growth never shrinks the overlay")
    func growNeverShrinks() {
        #expect(PromptEditorSizing.heightFraction(
            growing: 0.5, toFitRequiredHeight: 200, parentHeight: 600
        ) == 0.5)
    }

    @Test("Typing growth caps at the full parent height")
    func growCapsAtParent() {
        #expect(PromptEditorSizing.heightFraction(
            growing: 0.5, toFitRequiredHeight: 900, parentHeight: 600
        ) == 1)
    }

    @Test("Degenerate parent sizes leave the current size untouched")
    func degenerateParent() {
        #expect(PromptEditorSizing.widthFraction(
            afterDragging: 50, fromWidth: 800, parentWidth: 0
        ) == PromptEditorSizing.defaultWidthFraction)
        #expect(PromptEditorSizing.heightFraction(
            afterDragging: 50, fromHeight: 300, parentHeight: 0
        ) == PromptEditorSizing.defaultHeightFraction)
        #expect(PromptEditorSizing.heightFraction(
            growing: 0.6, toFitRequiredHeight: 400, parentHeight: 0
        ) == 0.6)
    }
}

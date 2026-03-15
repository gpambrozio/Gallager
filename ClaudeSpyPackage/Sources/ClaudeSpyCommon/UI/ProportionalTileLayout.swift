import SwiftUI

/// Custom `Layout` that tiles subviews using proportional rectangles.
///
/// Each subview is placed at its true layout position so that hit-testing
/// (clicks, focus) matches the visual placement. Shared across macOS and iOS.
public struct ProportionalTileLayout: Layout {
    public let rects: [CGRect]

    public init(rects: [CGRect]) {
        self.rects = rects
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            guard index < rects.count else { continue }
            let proportional = rects[index]
            let width = proportional.width * bounds.width
            let height = proportional.height * bounds.height
            let x = bounds.minX + proportional.origin.x * bounds.width
            let y = bounds.minY + proportional.origin.y * bounds.height
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }
}

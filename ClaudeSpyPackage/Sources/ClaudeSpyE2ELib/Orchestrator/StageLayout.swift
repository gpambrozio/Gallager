import CoreGraphics
import Foundation

/// Computes best-effort non-overlapping screen positions ("lanes") for the
/// windows visible in a recorded scenario, so a single full-display take
/// shows every mac instance with minimal occlusion (issue #621).
///
/// Pure geometry — no AX or CoreGraphics window calls — so it is unit-testable.
/// Coordinates are top-left-origin screen points, matching what
/// `macMoveWindow` / AX `kAXPositionAttribute` expect.
public struct StageLayout: Sendable {
    /// The display being recorded, in points.
    public let display: CGSize

    /// The window size scenarios standardize on (`Shortcut.openPanesWindow`).
    public static let defaultWindowSize = CGSize(width: 1_000, height: 600)
    /// The origin scenarios standardize on for instance 0.
    public static let defaultOrigin = CGPoint(x: 10, y: 10)
    /// Margin kept from display edges.
    static let margin: CGFloat = 10
    /// Horizontal gap between side-by-side lanes.
    static let gap: CGFloat = 20

    public init(display: CGSize) {
        self.display = display
    }

    /// Top-left origin for the given instance's window lane.
    ///
    /// Instance 0 keeps the canonical (10, 10) so its baselines and popover
    /// geometry are untouched. Instance N prefers a full side-by-side lane to
    /// the right; on displays too narrow for that it falls back to a
    /// staggered diagonal offset clamped fully on-screen — occlusion is
    /// minimized, not eliminated.
    public func laneOrigin(
        instance: Int,
        windowSize: CGSize = StageLayout.defaultWindowSize
    ) -> CGPoint {
        guard instance > 0 else { return Self.defaultOrigin }
        let n = CGFloat(instance)

        let sideBySideX = Self.defaultOrigin.x + n * (windowSize.width + Self.gap)
        if sideBySideX + windowSize.width + Self.margin <= display.width {
            return CGPoint(x: sideBySideX, y: Self.defaultOrigin.y)
        }

        let x = min(
            display.width - windowSize.width - Self.margin,
            Self.defaultOrigin.x + n * display.width * 0.42
        )
        let y = min(
            display.height - windowSize.height - Self.margin,
            Self.defaultOrigin.y + n * display.height * 0.42
        )
        return CGPoint(x: max(x, Self.margin), y: max(y, Self.margin))
    }

    /// Translation applied to a scenario's absolute coordinates (window
    /// moves, CG clicks, drags) for the given instance. Zero for instance 0,
    /// so unrecorded geometry is bit-identical.
    public func translation(
        instance: Int,
        windowSize: CGSize = StageLayout.defaultWindowSize
    ) -> CGVector {
        let origin = laneOrigin(instance: instance, windowSize: windowSize)
        return CGVector(
            dx: origin.x - Self.defaultOrigin.x,
            dy: origin.y - Self.defaultOrigin.y
        )
    }
}

import ClaudeSpyNetworking
import SwiftUI

/// Slim progress bar shown at the bottom of a session row when any of its
/// panes is emitting `OSC 9;4` progress. Used identically by the macOS host
/// sidebar, the macOS viewer's remote-host sidebar, and the iOS session list.
///
/// Visuals follow the OSC 9;4 state convention:
/// - `.normal(percent)`: blue bar filled to `percent%`.
/// - `.indeterminate`:   blue scanner bouncing left-right (Knight Rider).
/// - `.error`:           full red bar.
/// - `.warning`:         full yellow bar.
/// - `.removed`:         the parent decides not to render this view at all.
public struct TerminalProgressBar: View {
    public let state: TerminalProgressState

    private static let height: CGFloat = 3

    public init(state: TerminalProgressState) {
        self.state = state
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.clear
                fill(in: geo.size)
            }
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel("Terminal progress")
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private func fill(in size: CGSize) -> some View {
        switch state {
        case let .normal(percent):
            Capsule()
                .fill(.blue)
                .frame(width: size.width * CGFloat(percent) / 100)
                .animation(.easeOut(duration: 0.15), value: percent)
        case .error:
            Capsule().fill(.red)
        case .warning:
            Capsule().fill(.yellow)
        case .indeterminate:
            ScannerBar(width: size.width, height: Self.height)
        case .removed:
            EmptyView()
        }
    }

    private var accessibilityValue: String {
        switch state {
        case let .normal(percent): "\(percent)%"
        case .error: "error"
        case .warning: "warning"
        case .indeterminate: "in progress"
        case .removed: ""
        }
    }
}

/// Knight-Rider scanner: a 30%-width blue segment animating from the left
/// edge to the right edge and back, autoreversing forever. Driven by
/// `TimelineView` so a single `Date` tick sources the position — there's no
/// `@State` animation flag to forget to start, and SwiftUI tears it down
/// cleanly when the parent disappears (the bar removal flow).
private struct ScannerBar: View {
    let width: CGFloat
    let height: CGFloat

    /// Width of the moving segment as a fraction of the total bar width.
    private static let segmentFraction: CGFloat = 0.30
    /// One full sweep (left → right → left) duration in seconds.
    private static let cycleDuration = 1.6

    var body: some View {
        TimelineView(.animation) { context in
            let segmentWidth = width * Self.segmentFraction
            let travel = max(0, width - segmentWidth)
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.cycleDuration) / Self.cycleDuration
            // Triangle wave: 0 → 1 → 0 over the cycle.
            let progress = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            let x = travel * progress

            Capsule()
                .fill(.blue)
                .frame(width: segmentWidth, height: height)
                .offset(x: x)
        }
    }
}

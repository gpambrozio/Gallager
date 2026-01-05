import SFSymbolsMacro
import SwiftUI

/// This `enum` should contain all SFSymbols used in the project.
/// When using an SFSymbol that does not exist on this list add it,
/// making sure the list is always in alphabetical order.
/// To use an `enum` case as an image use `Symbols.gear.image` for example.
@SFSymbol
public enum Symbols: String {
    // swiftformat:sort:begin
    case arrowClockwise = "arrow.clockwise"
    case arrowDown = "arrow.down"
    case arrowRight = "arrow.right"
    case boltFill = "bolt.fill"
    case chevronLeft = "chevron.left"
    case exclamationmarkTriangle = "exclamationmark.triangle"
    case gearshape
    case lockFill = "lock.fill"
    case pause
    case play
    case playFill = "play.fill"
    case questionmark
    case sparkles
    case stopFill = "stop.fill"
    case terminal
    case wrenchAndScrewdriver = "wrench.and.screwdriver"
    case xmarkCircle = "xmark.circle"
    // swiftformat:sort:end
}

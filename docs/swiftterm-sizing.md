# SwiftTerm Terminal Sizing Analysis

This document details how SwiftTerm calculates terminal cell dimensions, view sizing, and internal padding. Understanding these calculations is critical for properly sizing mirror windows in ClaudeSpy.

> **SwiftTerm Version**: Commit [`0b8d99b`](https://github.com/migueldeicaza/SwiftTerm/tree/0b8d99bd19b694df44e1ccaa3891309719d34330)

## Cell Size Calculation

SwiftTerm calculates character cell dimensions in the `computeFontDimensions()` method.

**File**: [`AppleTerminalView.swift` (lines 142-167)](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Apple/AppleTerminalView.swift#L142-L167)

```swift
func computeFontDimensions() -> CellDimension {
    let lineAscent = CTFontGetAscent(fontSet.normal)
    let lineDescent = CTFontGetDescent(fontSet.normal)
    let lineLeading = CTFontGetLeading(fontSet.normal)
    let cellHeight = ceil(lineAscent + lineDescent + lineLeading)

    // macOS approach: use glyph advancement for "W"
    let glyph = fontSet.normal.glyph(withName: "W")
    let cellWidth = fontSet.normal.advancement(forGlyph: glyph).width

    return CellDimension(width: max(1, cellWidth), height: max(1, cellHeight))
}
```

### Key Points

| Dimension | Calculation | Notes |
|-----------|-------------|-------|
| **Width** | `font.advancement(forGlyph: "W").width` | Uses "W" glyph specifically |
| **Height** | `ceil(ascent + descent + leading)` | Includes all font metrics, rounded up |

Both values are clamped to a minimum of 1 pixel.

### ClaudeSpy Implementation

Our `FontMetrics.calculateCellSize()` exactly mirrors this calculation:

**File**: [`ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Utilities/FontMetrics.swift`](../ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Utilities/FontMetrics.swift)

## Terminal View Sizing

When the TerminalView's frame changes, SwiftTerm recalculates how many columns and rows fit.

**File**: [`AppleTerminalView.swift` (lines 73-89)](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Apple/AppleTerminalView.swift#L73-L89)

```swift
func processSizeChange(newSize: CGSize) -> Bool {
    let newRows = Int(newSize.height / cellDimension.height)
    let newCols = Int(getEffectiveWidth(size: newSize) / cellDimension.width)

    if newCols != terminal.cols || newRows != terminal.rows {
        terminal.resize(cols: newCols, rows: newRows)
        // ...
    }
}
```

**Critical**: The width calculation uses `getEffectiveWidth()`, not the raw frame width.

## The Internal Scroller (Source of Horizontal Padding)

SwiftTerm's macOS implementation (`MacTerminalView`) includes an internal `NSScroller` for scrollback navigation. This scroller reserves horizontal space.

### Effective Width Calculation

**File**: [`MacTerminalView.swift` (lines 348-351)](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Mac/MacTerminalView.swift#L348-L351)

```swift
func getEffectiveWidth(size: CGSize) -> CGFloat {
    return (size.width - scroller.frame.width)
}
```

Compare with iOS which has no scroller:

**File**: [`iOSTerminalView.swift` (lines 908-911)](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/iOS/iOSTerminalView.swift#L908-L911)

```swift
func getEffectiveWidth(size: CGSize) -> CGFloat {
    return size.width
}
```

### Scroller Setup

**File**: [`MacTerminalView.swift` (lines 304-320)](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Mac/MacTerminalView.swift#L304-L320)

```swift
func setupScroller() {
    let style: NSScroller.Style = .legacy
    let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
    let scrollerFrame = NSRect(
        x: bounds.maxX - scrollerWidth,
        y: 0,
        width: scrollerWidth,
        height: bounds.height
    )
    // ...
}
```

The legacy scroller style is approximately **15-16 pixels** wide on modern macOS.

## Why ClaudeSpy Needs a Horizontal Buffer

ClaudeSpy wraps `TerminalView` inside its own `NSScrollView` with overlay scrollers (which don't consume space). However, **SwiftTerm still reserves space for its internal scroller**.

This creates a mismatch:

```
┌─────────────────────────────────────────────────┐
│ ClaudeSpy NSScrollView (overlay scrollers)      │
│ ┌─────────────────────────────────────────────┐ │
│ │ SwiftTerm TerminalView                      │ │
│ │ ┌───────────────────────────────────┬─────┐ │ │
│ │ │ Effective content area            │Scrl │ │ │
│ │ │ (width - scrollerWidth)           │ 15px│ │ │
│ │ └───────────────────────────────────┴─────┘ │ │
│ └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

Without compensation, approximately **2 characters** get clipped on the right edge.

### Current Solution

We add a **20px horizontal buffer** to both the terminal frame and window content size:

**Terminal frame**: [`TerminalContainerView.swift` (lines 132-135)](../ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/TerminalContainerView.swift#L132-L135)

```swift
let horizontalBuffer: CGFloat = 20
let width = CGFloat(columns) * cellSize.width + horizontalBuffer
```

**Window size**: [`MirrorWindowManager.swift` (lines 45-48)](../ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift#L45-L48)

```swift
let horizontalBuffer: CGFloat = 20
let contentWidth = CGFloat(paneInfo.width) * cellSize.width + horizontalBuffer
```

### Buffer Breakdown

| Component | Pixels | Notes |
|-----------|--------|-------|
| NSScroller (legacy) | ~15px | `NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)` |
| Rounding buffer | ~5px | Accounts for font metric rounding differences |
| **Total** | **20px** | Current working value |

## Alternative Approaches

### 1. Dynamic Scroller Width Calculation

Instead of hardcoding 20px, calculate dynamically:

```swift
let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
let horizontalBuffer = scrollerWidth + 4 // rounding buffer
```

### 2. Disable SwiftTerm's Internal Scroller

Would require modifications to SwiftTerm or using a custom subclass. Not recommended unless contributing upstream.

### 3. Use SwiftTerm's Native Scrolling

Remove our NSScrollView wrapper and let SwiftTerm manage its own scrolling entirely. This would eliminate the double-scroller situation but reduce our control over scroll behavior.

## Vertical Sizing

Vertical sizing is simpler - no scroller interference:

```swift
let height = CGFloat(rows) * cellSize.height
```

The window adds **110px vertical padding** for:
- Title bar: ~28px
- Toolbar: ~38px
- Status bar: ~28px
- Buffer: ~16px

## References

### SwiftTerm Source Files

- [AppleTerminalView.swift](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Apple/AppleTerminalView.swift) - Shared Apple platform code
- [MacTerminalView.swift](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Mac/MacTerminalView.swift) - macOS-specific implementation
- [iOSTerminalView.swift](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/iOS/iOSTerminalView.swift) - iOS implementation (for comparison)

### ClaudeSpy Source Files

- [FontMetrics.swift](../ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Utilities/FontMetrics.swift) - Cell size calculation
- [TerminalContainerView.swift](../ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/TerminalContainerView.swift) - Terminal view wrapper
- [MirrorWindowManager.swift](../ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift) - Window sizing logic

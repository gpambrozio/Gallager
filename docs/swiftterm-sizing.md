# SwiftTerm Terminal Sizing Analysis

This document details how SwiftTerm calculates terminal cell dimensions, view sizing, and internal padding. Understanding these calculations is critical for properly sizing mirror windows in ClaudeSpy.

> **SwiftTerm Version**: v1.18.0, commit [`7691f85`](https://github.com/migueldeicaza/SwiftTerm/tree/7691f85b222a67a66b58499e1b2647443cf0dda7) (the exact pin in `Package.swift`).
> The Cell Size Calculation section below is verified against this revision. Later sections' code links still point at the older commit `0b8d99b` they were written against; re-verify line numbers there before relying on them.

## Cell Size Calculation

SwiftTerm calculates character cell dimensions in the `computeFontDimensions()` method.

**File**: [`AppleTerminalView.swift` (lines 377-407)](https://github.com/migueldeicaza/SwiftTerm/blob/7691f85b222a67a66b58499e1b2647443cf0dda7/Sources/SwiftTerm/Apple/AppleTerminalView.swift#L377-L407)

```swift
func computeFontDimensions () -> CellDimension
{
    let lineAscent = CTFontGetAscent (fontSet.normal)
    let lineDescent = CTFontGetDescent (fontSet.normal)
    let lineLeading = CTFontGetLeading (fontSet.normal)
    let cellHeight = ceil((lineAscent + lineDescent + lineLeading) * _lineSpacing)
    #if os(macOS)
    let glyph = fontSet.normal.glyph(withName: "W")
    let cellWidth = fontSet.normal.advancement(forGlyph: glyph).width
    #else
    let fontAttributes = [NSAttributedString.Key.font: fontSet.normal]
    let cellWidth = "W".size(withAttributes: fontAttributes).width
    #endif
    // Snap to pixel grid to avoid sub-pixel seams between adjacent cells
    let scale = backingScaleFactor()
    let snappedWidth = (cellWidth * scale).rounded() / scale
    let snappedHeight = ceil(cellHeight * scale) / scale
    return CellDimension(width: max(1, snappedWidth), height: max(min(snappedHeight, 8192), 1))
}
```

### Key Points

| Dimension | Calculation | Notes |
|-----------|-------------|-------|
| **Width** | macOS: `advancement(forGlyph: "W").width`; iOS: `"W".size(withAttributes:).width` — then `(width * scale).rounded() / scale` | Snapped to the pixel grid with `.rounded()` |
| **Height** | `ceil((ascent + descent + leading) * lineSpacing)`, then `ceil(height * scale) / scale` | `lineSpacing` defaults to 1.0; capped at 8192 |

Both values are clamped to a minimum of 1, and the pixel-grid snap uses the view's backing scale factor.

> **Version trap (width snap)**: SwiftTerm 1.15.0 snapped width with `ceil(cellWidth * scale) / scale`; **1.16.0 changed it to `(cellWidth * scale).rounded() / scale`**. `FontMetrics` must use the same formula as the pinned SwiftTerm version — if they disagree for the active font/scale, SwiftTerm derives a different column count than the host tmux pane and mirrored content misaligns. Re-check this snap on every SwiftTerm bump.

### ClaudeSpy Implementation

Our `FontMetrics.calculateCellSize()` exactly mirrors this calculation:

**File**: [`ClaudeSpyPackage/Sources/ClaudeSpyCommon/Utilities/FontMetrics.swift`](../ClaudeSpyPackage/Sources/ClaudeSpyCommon/Utilities/FontMetrics.swift)

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

### 1. Dynamic Scroller Width Calculation (Implemented)

Instead of hardcoding 20px, calculate dynamically:

```swift
let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
let horizontalBuffer = scrollerWidth + 4 // rounding buffer
```

This is the current implementation in `FontMetrics.horizontalBuffer`.

### 2. Disable SwiftTerm's Internal Scroller

Would require modifications to SwiftTerm or using a custom subclass. Not recommended unless contributing upstream.

### 3. Use SwiftTerm's Native Scrolling

Remove our NSScrollView wrapper and let SwiftTerm manage its own scrolling entirely. **See analysis below** - this is not feasible without modifying SwiftTerm.

## Feasibility Analysis: Removing the NSScrollView Wrapper

We investigated whether ClaudeSpy could remove its `NSScrollView` wrapper and use SwiftTerm's native scrolling directly. This would potentially eliminate the horizontal buffer hack entirely.

### Current ClaudeSpy Architecture

```
┌─────────────────────────────────────────────────────────┐
│ TerminalContainerView (NSViewRepresentable)             │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ NSScrollView (overlay scrollers)                    │ │
│ │ ┌─────────────────────────────────────────────────┐ │ │
│ │ │ FlippedClipView (isFlipped = true)              │ │ │
│ │ │ ┌─────────────────────────────────────────────┐ │ │ │
│ │ │ │ SwiftTerm TerminalView                      │ │ │ │
│ │ │ │ (with internal NSScroller)                  │ │ │ │
│ │ │ └─────────────────────────────────────────────┘ │ │ │
│ │ └─────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

| Component | Purpose |
|-----------|---------|
| `NSScrollView` | Container with overlay scrollers |
| `FlippedClipView` | Custom NSClipView with `isFlipped = true` for top-alignment |
| `TerminalView` | SwiftTerm's terminal (has its own internal scroller) |

### Why the Wrapper Exists

1. **Top Alignment**: SwiftTerm renders content bottom-up (standard AppKit). ClaudeSpy needs top-alignment.
2. **Overlay Scrollers**: Our NSScrollView uses overlay style (don't consume space).
3. **Fixed Sizing**: Precise control over terminal dimensions matching tmux pane.

### Blocking Issue #1: Bottom-Alignment is Hard-Coded

SwiftTerm's drawing code explicitly calculates Y coordinates from the bottom:

**File**: [`AppleTerminalView.swift` (line 603-604)](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Apple/AppleTerminalView.swift#L603-L604)

```swift
let lineOrigin = CGPoint(x: 0, y: frame.height - lineOffset)
```

**File**: [`MacTerminalView.swift` (line 895)](https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Mac/MacTerminalView.swift#L895) (mouse hit calculation)

```swift
let row = Int((frame.height - point.y) / cellDimension.height) + terminal.buffer.yDisp
```

**Impact**: Without our `FlippedClipView`, all content would render at the bottom of the window and fill upward - completely unusable for a terminal mirror.

There is **no configuration option** to change this behavior. It would require modifying SwiftTerm's source code.

### Blocking Issue #2: Internal Scroller Always Present

SwiftTerm's `MacTerminalView` always creates and reserves space for its internal `NSScroller`:

- Scroller uses `.legacy` style (~15-16px wide)
- `getEffectiveWidth()` always subtracts scroller width
- No API to disable or hide the scroller

Even without our wrapper, SwiftTerm would still reduce the effective content width.

### SwiftTerm's Scroll APIs

SwiftTerm does expose scroll functionality that works regardless of our wrapper:

| Method | Description |
|--------|-------------|
| `scroll(toPosition: Double)` | Set position (0.0 = top, 1.0 = bottom) |
| `scrollUp(lines: Int)` | Scroll up by line count |
| `scrollDown(lines: Int)` | Scroll down by line count |
| `scrollPosition` | Read current position |
| `canScroll` | Check if scrollable |

However, these don't help with the alignment or scroller space issues.

### Conclusion: Not Feasible

| Issue | Severity | Solution Required |
|-------|----------|-------------------|
| Bottom-alignment hard-coded | **Blocking** | Modify SwiftTerm source |
| Internal scroller always present | **Blocking** | Modify SwiftTerm source |
| Scroll state tracking | Medium | Refactor (doable) |

**Recommendation**: Keep the current architecture. The `NSScrollView` wrapper with `FlippedClipView` and dynamic horizontal buffer is the pragmatic solution given SwiftTerm's design constraints.

### Future Option: Contribute to SwiftTerm

To truly eliminate the wrapper, one could contribute upstream to SwiftTerm:

1. Add optional top-alignment mode (coordinate system flag)
2. Add option to disable/externalize the internal scroller
3. Expose scroller configuration

This would be significant effort for marginal benefit, given the current solution works correctly.

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

- [FontMetrics.swift](../ClaudeSpyPackage/Sources/ClaudeSpyCommon/Utilities/FontMetrics.swift) - Cell size calculation
- [TerminalContainerView.swift](../ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/TerminalContainerView.swift) - Terminal view wrapper
- [MirrorWindowManager.swift](../ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift) - Window sizing logic

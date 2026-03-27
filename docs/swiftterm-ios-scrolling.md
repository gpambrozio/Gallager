# SwiftTerm iOS Scrolling Architecture

This document details how SwiftTerm's `TerminalView` handles scrolling on iOS, the limitations discovered, and how ClaudeSpy works around them.

> **SwiftTerm Version**: 1.9.0 (from Package.swift dependency)

## Overview

SwiftTerm's iOS `TerminalView` is a `UIScrollView` subclass that handles terminal rendering and scrollback navigation. ClaudeSpy wraps it in an additional scroll view to support wide terminals (horizontal scrolling), creating a nested scroll view architecture.

## SwiftTerm Source Files

| File | Purpose |
|------|---------|
| `iOSTerminalView.swift` | iOS-specific TerminalView implementation |
| `AppleTerminalView.swift` | Shared rendering code (iOS + macOS) |

## Vertical Scrolling (Scrollback)

SwiftTerm fully supports vertical scrolling for terminal scrollback history.

### How It Works

1. **Content Size**: Set based on total buffer lines
   ```swift
   contentSize = CGSize(
       width: CGFloat(displayBuffer.cols) * cellDimension.width,
       height: CGFloat(displayBuffer.lines.count) * cellDimension.height
   )
   ```

2. **Scroll Position**: `contentOffset.y` determines which buffer lines are visible
   ```swift
   // In visibleRows calculation
   let topVisibleLine = contentOffset.y / cellDimension.height
   let bottomVisibleLine = topVisibleLine + frame.height / cellDimension.height - 1
   ```

3. **Rendering**: `drawTerminalContents()` uses `contentOffset.y` to determine which rows to render

### Scroll Methods

| Method | Description |
|--------|-------------|
| `scroll(toPosition: Double)` | Normalized position (0.0 = top, 1.0 = cursor position) |
| `scrollUp(lines: Int)` | Scroll up by N lines |
| `scrollDown(lines: Int)` | Scroll down by N lines |
| `scrollTo(row: Int)` | Jump to specific row |
| `pageUp()` / `pageDown()` | Scroll by one page |

### Important Note

`scroll(toPosition: 1)` scrolls to the **cursor position**, not necessarily the absolute bottom of content. The cursor is typically at the bottom, but this distinction matters.

## Horizontal Scrolling (NOT Supported)

**Critical Finding**: SwiftTerm does NOT support horizontal scrolling for wide terminals.

### Evidence

1. **contentOffset.x is hardcoded to 0** in `updateScroller()`:
   ```swift
   // iOSTerminalView.swift:992
   contentOffset = CGPoint(x: 0, y: CGFloat(displayBuffer.lines.count - displayBuffer.rows) * cellDimension.height)
   ```

2. **Rendering ignores contentOffset.x** - `lineOrigin.x` is always 0:
   ```swift
   // AppleTerminalView.swift:1209
   let lineOrigin = CGPoint(x: 0, y: frame.height - offset)
   ```

3. **No horizontal scroll gesture handling** - While `showsHorizontalScrollIndicator = true` is set, the terminal content won't pan horizontally.

### Impact

For wide terminals (more columns than fit on screen), the content is clipped on the right. There's no way to scroll horizontally to see clipped content using SwiftTerm alone.

## ClaudeSpy's Solution: Nested Scroll Views

ClaudeSpy wraps TerminalView in an outer UIScrollView to enable horizontal scrolling.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Outer UIScrollView (horizontal + vertical scrolling)         │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ InteractiveTerminalView (SwiftTerm subclass)            │ │
│ │ - Width: exact terminal width (cols × cellWidth)        │ │
│ │ - Height: max(screen height, rows × cellHeight)         │ │
│ │ - Handles scrollback via internal UIScrollView          │ │
│ │ - contentSize.height > frame.height for history         │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Why This Works

1. **TerminalView width = exact terminal width**: SwiftTerm renders all columns
2. **TerminalView height = available screen space**: Fits within viewport
3. **Outer scroll view**: Only scrolls horizontally for wide terminals
4. **SwiftTerm internal scroll**: Handles all vertical scrollback navigation

### The Problem: Unintended Vertical Scrolling

If the terminal frame height exceeds the available screen height, the outer scroll view would also become vertically scrollable. This creates a confusing dual-scroll UX:

- **Inner terminal**: Scrolls vertically through scrollback history
- **Outer scroll view**: Also scrolls vertically to show different parts of the terminal frame

Users would have to scroll TWO views to reach the bottom of content.

### The Fix: Flexible Height with Minimum Screen Fill

The terminal height uses two constraints: a required minimum equal to the screen height (so short terminals fill the screen), and a preferred height matching the exact terminal content height. When the host terminal has more rows than fit on screen, the terminal frame expands and the outer scroll view provides vertical scrolling:

```swift
NSLayoutConstraint.activate([
    // ... other constraints ...
    // Height: at least screen height (fills screen for short terminals)
    terminalView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
    // Height: prefers exact terminal content height (expands for tall terminals)
    heightConstraint, // equalToConstant, priority: .defaultHigh
])
```

This ensures:
- **Short terminals** (rows fit on screen): Terminal fills available space, SwiftTerm may expand rows (acceptable — no data loss)
- **Tall terminals** (rows exceed screen): Terminal frame matches content height, preventing SwiftTerm from auto-resizing and destroying bottom rows (e.g. DECSTBM footers)
- **Outer scroll view**: Scrolls both horizontally (wide terminals) and vertically (tall terminals)
- **Inner terminal (SwiftTerm)**: Handles scrollback navigation

**Note**: Earlier versions used `equalTo: scrollView.frameLayoutGuide.heightAnchor` which locked the terminal to screen height. This caused SwiftTerm's `processSizeChange` to shrink the buffer for tall terminals, destroying content (see GitHub issue #244).

## InteractiveTerminalView Subclass

ClaudeSpy extends SwiftTerm's `TerminalView` with `InteractiveTerminalView`:

### Features

1. **Keyboard Input Control**
   ```swift
   var inputEnabled = false
   override var canBecomeFirstResponder: Bool { inputEnabled }
   ```

2. **Scroll Preservation During Updates**
   ```swift
   var preserveUserScroll = false
   private var blockScrollChanges = false

   override var contentOffset: CGPoint {
       get { super.contentOffset }
       set {
           if blockScrollChanges { return }
           super.contentOffset = newValue
       }
   }
   ```

3. **Feed with Scroll Preservation**
   ```swift
   func feedPreservingScroll(_ bytes: ArraySlice<UInt8>) {
       if preserveUserScroll {
           let isAtBottom = contentOffset.y >= maxScrollY - 5
           blockScrollChanges = !isAtBottom
       }
       feed(byteArray: bytes)
       blockScrollChanges = false
   }
   ```

   This prevents new content from auto-scrolling when the user has scrolled up to read history.

## TerminalState Bridge

`TerminalState` is an `@Observable` class that bridges SwiftUI and UIKit:

| Property/Callback | Purpose |
|-------------------|---------|
| `onData` | Feed data to terminal |
| `onResize` | Handle dimension changes |
| `scrollToBottom` | Scroll terminal to bottom (callable from SwiftUI) |
| `onInitialContentLoaded` | Called once after initial content is fed |

### Scroll-to-Bottom Implementation

Both the inner terminal (scrollback) and outer scroll view (tall terminals) need scrolling:

```swift
terminalState.scrollToBottom = { [weak terminalView, weak scrollView] in
    guard let terminalView, let scrollView else { return }
    // Inner: scroll SwiftTerm to bottom of scrollback
    let innerMaxY = terminalView.contentSize.height - terminalView.bounds.height
    terminalView.setContentOffset(CGPoint(x: 0, y: max(0, innerMaxY)), animated: false)
    // Outer: scroll to bottom of terminal frame (for tall terminals)
    let outerMaxY = scrollView.contentSize.height - scrollView.bounds.height
    scrollView.setContentOffset(
        CGPoint(x: scrollView.contentOffset.x, y: max(0, outerMaxY)),
        animated: false
    )
}
```

Called on:
- Initial content load (after 100ms delay for layout)
- Keyboard show (after 350ms delay for animation)

## Key Constraints and Limitations

### SwiftTerm Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| No horizontal scrolling | Wide terminals clipped | Outer scroll view wrapper |
| contentOffset.x always 0 | Can't pan horizontally in terminal | Outer scroll view |
| Frame = terminal size expected | Can't make terminal smaller than buffer | Accept full-size frame |
| updateScroller() not overridable | Can't customize scroll behavior | Override contentOffset property |

### ClaudeSpy Constraints

| Constraint | Reason |
|------------|--------|
| Terminal dimensions from Mac | Must display exact same content |
| Need horizontal scroll | Mac terminals often wider than phone |
| Need scroll preservation | Don't lose place when content updates |
| Single-scroll UX | Users expect one scroll gesture |

## Future Improvements

### Option: Contribute to SwiftTerm

To enable native horizontal scrolling:

1. Modify `updateScroller()` to preserve `contentOffset.x`
2. Modify `drawTerminalContents()` to offset rendering by `contentOffset.x`
3. Add configuration for horizontal scroll behavior

This would allow eliminating the outer scroll view entirely.

### Current Status

The nested scroll view approach with locked vertical scrolling works correctly and provides a good UX. The complexity is contained within `TerminalStreamContainerView`.

## References

### SwiftTerm Source (from .build/checkouts/)

- `SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift`
- `SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift`

### ClaudeSpy Source

- `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Views/LiveTerminalView.swift` - Main terminal view
- `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Views/InteractiveTerminalView.swift` - SwiftTerm subclass

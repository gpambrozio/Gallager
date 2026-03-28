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

## ClaudeSpy's Solution: Outer Scroll View + Managed Terminal Size

ClaudeSpy wraps TerminalView in an outer UIScrollView to enable horizontal scrolling, and overrides SwiftTerm's auto-resize to preserve the host terminal's dimensions.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Outer UIScrollView (horizontal scrolling only)              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ InteractiveTerminalView (SwiftTerm subclass)            │ │
│ │ - Width: exact terminal width (cols × cellWidth)        │ │
│ │ - Height: locked to screen height (equalTo constraint)  │ │
│ │ - Terminal buffer: managed externally (may exceed view)  │ │
│ │ - Handles ALL vertical scrolling (scrollback + content) │ │
│ │ - contentSize.height > frame.height for tall terminals  │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Why This Works

1. **TerminalView width = exact terminal width**: SwiftTerm renders all columns
2. **TerminalView height = screen height**: Fits within viewport via `equalTo` constraint
3. **Outer scroll view**: Only scrolls horizontally for wide terminals
4. **SwiftTerm internal scroll**: Handles all vertical scrolling (both scrollback history and tall terminal content that extends beyond the view frame)

### The Problem: SwiftTerm Auto-Resize Destroys Content

SwiftTerm's `layoutSubviews` calls `processSizeChange(newSize: bounds.size)`, which computes `newRows = height / cellHeight` and resizes the terminal buffer to match. When the host terminal has more rows than fit on the iOS screen (e.g., a 65-row macOS terminal on a ~40-row iPhone), SwiftTerm shrinks the buffer, destroying bottom rows including DECSTBM scroll region footers (see GitHub issue #244).

### The Fix: Managed Terminal Size Override

`InteractiveTerminalView` uses a `managedTerminalSize` property to lock the terminal buffer dimensions. After SwiftTerm's `layoutSubviews` shrinks the buffer, our override immediately restores the correct dimensions:

```swift
var managedTerminalSize: (cols: Int, rows: Int)?

override func layoutSubviews() {
    super.layoutSubviews()
    // Restore externally-managed dimensions after SwiftTerm's auto-resize
    if let size = managedTerminalSize {
        let terminal = getTerminal()
        if terminal.cols != size.cols || terminal.rows != size.rows {
            terminal.resize(cols: size.cols, rows: size.rows)
        }
    }
}
```

This ensures:
- **Short terminals** (rows fit on screen): Terminal fills available space, SwiftTerm's own scrolling handles scrollback
- **Tall terminals** (rows exceed screen): Buffer keeps all rows (e.g., 65 rows), SwiftTerm's contentSize accommodates the full buffer, and its internal scrolling lets users reach the footer
- **Single scroll view**: No nested vertical scrolling — SwiftTerm handles everything
- **Auto-scroll on new content**: `feedPreservingScroll` snaps to the real bottom (`contentSize.height - bounds.height`) when the user is at the bottom, compensating for SwiftTerm's `updateScroller` which positions for `terminal.rows` instead of the actual view height

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
       let maxScrollY = max(0, contentSize.height - bounds.height)
       let isAtBottom = maxScrollY <= 0 || super.contentOffset.y >= maxScrollY - 5
       if preserveUserScroll {
           blockScrollChanges = !isAtBottom
       }
       feed(byteArray: bytes)
       blockScrollChanges = false
       // Snap to real bottom for managed-size terminals
       if isAtBottom, managedTerminalSize != nil {
           let newMaxY = max(0, contentSize.height - bounds.height)
           super.contentOffset.y = newMaxY
       }
   }
   ```

   This prevents new content from auto-scrolling when the user has scrolled up to read history. For tall terminals with `managedTerminalSize`, it also snaps to the correct bottom position after feeding.

## TerminalState Bridge

`TerminalState` is an `@Observable` class that bridges SwiftUI and UIKit:

| Property/Callback | Purpose |
|-------------------|---------|
| `onData` | Feed data to terminal |
| `onResize` | Handle dimension changes |
| `scrollToBottom` | Scroll terminal to bottom (callable from SwiftUI) |
| `onInitialContentLoaded` | Called once after initial content is fed |

### Scroll-to-Bottom Implementation

Only the inner terminal needs scrolling — the outer scroll view handles horizontal only:

```swift
terminalState.scrollToBottom = { [weak terminalView] in
    guard let terminalView else { return }
    let maxY = terminalView.contentSize.height - terminalView.bounds.height
    terminalView.setContentOffset(CGPoint(x: 0, y: max(0, maxY)), animated: false)
}
```

For tall terminals where `managedTerminalSize` is set, `feedPreservingScroll` also snaps to the real bottom after each feed (since SwiftTerm's `updateScroller` positions for `terminal.rows` instead of the actual view height).

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

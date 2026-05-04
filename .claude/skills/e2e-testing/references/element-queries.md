# Element Queries Reference

The `ElementQuery` enum (`ClaudeSpyE2ELib/Drivers/Simulator/ElementQuery.swift`) matches against the iOS accessibility tree provided by the XCUITest runner. The same enum is also accepted by `macWaitForElementQuery` / `macWaitForElementQueryToDisappear` for precise matching against the macOS accessibility tree.

## Query Types

### `.label(String)`
Exact match on the element's `AXLabel` attribute.

```swift
TestStep.iosTap(.label("New Session"))
TestStep.iosWaitForElement(.label("Delete"))
```

### `.labelContains(String)`
Case-insensitive substring match on `AXLabel`.

```swift
TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)
TestStep.iosTap(.labelContains("Settings"))
TestStep.iosTap(.labelContains("New Terminal"))
```

### `.role(String)`
Match on the element's `AXRole`. Role values use XCUIElement.ElementType names:
- `"Button"` - Buttons, toggles
- `"StaticText"` - Text labels
- `"TextField"` - Text input fields
- `"Image"` - Image views
- `"Window"` - Windows
- `"Alert"` - Alert dialogs
- `"Cell"` - Table/collection cells
- `"Switch"` - Toggle switches

```swift
TestStep.iosWaitForElement(.role("Alert"))
```

### `.identifier(String)`
Match on the element's `AXIdentifier` (set via `.accessibilityIdentifier()` in SwiftUI).

```swift
TestStep.iosSwipeLeft(.identifier("host-row"))
```

### `.roleAndLabelContains(role: String, label: String)`
Match both role AND label substring (case-insensitive). Essential for confirmation dialogs where the dialog title text matches the same label as the target button.

```swift
// Dialog title: "Remove Pairing"
// Button label: "Remove MacBook Pro"
// Without role filter, .labelContains("Remove") might match the dialog title
TestStep.iosTap(.roleAndLabelContains(role: "Button", label: "Remove"))
```

### `.valueContains(String)`
Case-insensitive substring match on the element's `AXValue`.

```swift
TestStep.iosWaitForElement(.valueContains("Connected"))
```

### `.help(String)`
Exact match on the element's `AXHelp` attribute. On macOS, SwiftUI's `.help("…")` modifier maps to `AXHelp`. Use this when you need to match a button by its tooltip rather than its visible label — particularly common for icon-only toolbar buttons that share a generic label.

```swift
// Match a toggle by both its help text and current value
TestStep.macWaitForElementQuery(.allOf([
    .help("Auto-resize tmux pane to fit mirror view"),
    .valueContains("1"),
]))
```

### `.anyTextMatches(String)`
Match when *any* of `title`, `label`, or `value` contains the substring (case-insensitive), or `help` exactly equals it. The "kitchen sink" matcher — useful when the element exposes the text you care about through one of several attributes and you don't want to care which.

```swift
// SwiftUI's ContentUnavailableView text shows up under different attributes
// depending on how the runtime rendered it; .anyTextMatches matches them all.
TestStep.macWaitForElementQuery(.anyTextMatches("Check the spelling"), timeout: 5)
```

### `.allOf([ElementQuery])`
Combine multiple queries — all must match the same element.

```swift
TestStep.iosTap(.allOf([.role("Button"), .labelContains("OK")]))
```

## Matching Behavior

- **Label matching**: `.label()` is exact, `.labelContains()` is case-insensitive substring
- **Tree search**: Queries search depth-first through the entire accessibility tree
- **Wait + tap**: `iosTap(_:)` internally waits for the element to appear before tapping
- **First match**: When multiple elements match, the first one found (depth-first) is used

## Best Practices

### Prefer Specificity
Use `.label()` (exact) over `.labelContains()` when the full label is known and stable.

### Use `.roleAndLabelContains` for Dialogs
Confirmation dialogs have both a title and buttons. The title text often contains the same words as the button label. Filter by role to avoid matching the wrong element.

### Use `.identifier()` for Swipe Targets
Swipe actions need to target a specific row. Set `.accessibilityIdentifier()` on the SwiftUI view and use `.identifier()` in the query.

### Debug with `iosLogUI`
When element queries don't match, add `TestStep.iosLogUI` before the failing step to dump the full accessibility tree and discover the correct labels, roles, and identifiers.

## Making SwiftUI Elements Discoverable

### iOS

```swift
// Label (for tapping/waiting)
Button { } label: { Image(systemName: "plus") }
    .accessibilityLabel("New Session")

// Identifier (for swipe targets, unique rows)
HStack { ... }
    .accessibilityIdentifier("host-row")
```

### macOS

The macOS test accessibility server (`TestAccessibilityServer` on port 18081) searches differently:

1. **Toolbar items** - Match by `label`
2. **Sidebar rows** - Walk NSView hierarchy for `NSOutlineView` rows, find `AXButton` inside
3. **Accessibility tree** - Recursive walk matching `title`, `label`, `value`, or `help`

```swift
// Toolbar: use .help() (Label titles aren't exposed in System Events)
Button { } label: { Label("Generate Code", symbol: .key) }
    .help("Generate Pairing Code")

// Sidebar: use Button (not onTapGesture) with .accessibilityLabel on the Button
Button { selectedPane = pane } label: { PaneSidebarRow(pane: pane) }
    .buttonStyle(.plain)
    .accessibilityLabel(pane.target)
```

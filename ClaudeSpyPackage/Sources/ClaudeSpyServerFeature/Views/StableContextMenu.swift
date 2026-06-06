import AppKit
import SwiftUI

/// Declarative description of an item in a right-click menu built by
/// ``View/stableContextMenu(_:)``.
enum ContextMenuItem {
    case button(
        title: String,
        image: NSImage? = nil,
        isEnabled: Bool = true,
        accessibilityLabel: String? = nil,
        action: @MainActor () -> Void
    )
    case submenu(
        title: String,
        image: NSImage? = nil,
        isEnabled: Bool = true,
        accessibilityLabel: String? = nil,
        items: [ContextMenuItem]
    )
    case divider
}

extension View {
    /// Right-click context menu using a native `NSMenu` whose lifecycle is
    /// decoupled from SwiftUI's view-body re-evaluations.
    ///
    /// Implemented as a transparent overlay backed by an `NSView` that only
    /// intercepts right-click / ctrl-click hit-tests and builds the menu
    /// lazily inside `NSView.menu(for:)`. SwiftUI never sees a `setMenu:`
    /// call on the underlying view, so an open submenu survives arbitrary
    /// `@Observable` mutations in ancestors. The catcher lets every other
    /// event (left-click, drag, hover, focus, accessibility traversal) pass
    /// straight through to the SwiftUI content below, so accessibility
    /// queries against the wrapped content keep working.
    func stableContextMenu(
        _ items: @escaping @MainActor () -> [ContextMenuItem]
    ) -> some View {
        overlay(StableContextMenuCatcher(items: items))
    }
}

private struct StableContextMenuCatcher: NSViewRepresentable {
    let items: @MainActor () -> [ContextMenuItem]

    func makeNSView(context: Context) -> StableContextMenuCatcherView {
        let view = StableContextMenuCatcherView()
        view.itemsBuilder = items
        return view
    }

    func updateNSView(_ nsView: StableContextMenuCatcherView, context: Context) {
        nsView.itemsBuilder = items
    }
}

/// Transparent `NSView` overlay that catches only right-click / ctrl-click
/// hit-tests. Everything else (left-click, drag, hover, accessibility)
/// falls through to the SwiftUI content below.
final private class StableContextMenuCatcherView: NSView {
    var itemsBuilder: (@MainActor () -> [ContextMenuItem])?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Stay invisible in the accessibility tree — this view is a pure
        // event catcher; the SwiftUI content below is what AX should see.
        setAccessibilityElement(false)
        setAccessibilityChildren([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown,
             .rightMouseUp:
            return self
        case .leftMouseDown,
             .leftMouseUp:
            return event.modifierFlags.contains(.control) ? self : nil
        default:
            return nil
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let itemsBuilder else { return nil }
        let items = itemsBuilder()
        guard !items.isEmpty else { return nil }
        return makeNSMenu(items: items)
    }
}

/// Holds action closures for a single `NSMenu` invocation. `NSMenuItem`
/// references this dispatcher as its `target`, but `NSMenuItem.target` is
/// a `weak` reference — so the dispatcher must be strongly retained by
/// the menu itself, which is what ``StableContextMenu`` (the menu
/// subclass) does.
///
/// `@MainActor` because AppKit fires `@objc` menu actions on the main
/// thread, and every caller (the `@MainActor` menu builder + the AppKit
/// action selector) is already main-isolated.
@MainActor
final private class ContextMenuActionDispatcher: NSObject {
    private var actions: [@MainActor () -> Void] = []

    func registerAction(_ action: @escaping @MainActor () -> Void) -> Int {
        let tag = actions.count
        actions.append(action)
        return tag
    }

    @objc
    func invoke(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        actions[sender.tag]()
    }
}

/// `NSMenu` subclass whose only purpose is to keep its
/// ``ContextMenuActionDispatcher`` alive for the lifetime of the menu.
/// Without this strong reference the dispatcher (referenced only via
/// each item's `weak target`) would deallocate as soon as
/// `StableContextMenuCatcherView.menu(for:)` returns, leaving every
/// click a no-op.
final private class StableContextMenu: NSMenu {
    private let dispatcher: ContextMenuActionDispatcher

    init(dispatcher: ContextMenuActionDispatcher) {
        self.dispatcher = dispatcher
        super.init(title: "")
        autoenablesItems = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Pops up the same native ``NSMenu`` that ``View/stableContextMenu(_:)``
/// builds as a contextual menu for `event` over `view`, via AppKit's own
/// `popUpContextMenu(_:with:for:)`.
///
/// Used where a host hook — not ClaudeSpy's own catcher view — reports the
/// right-click, e.g. the Git tab's Changes rows surfacing it through
/// GitWorkbench's `onChangesRightClick`. Routing through AppKit (rather than a
/// bare `NSMenu.popUp`) matters: it tracks the click's press/release correctly
/// (a bare pop-up gets dismissed by the trailing `rightMouseUp`) and exposes
/// the menu in the accessibility tree — the same path `menu(for:)` takes for
/// the File Explorer. The menu retains its action dispatcher for its lifetime
/// (see ``StableContextMenu``). No-op for an empty item list.
@MainActor
func presentStableContextMenu(items: [ContextMenuItem], with event: NSEvent, for view: NSView) {
    guard !items.isEmpty else { return }
    let menu = makeNSMenu(items: items)
    NSMenu.popUpContextMenu(menu, with: event, for: view)
}

@MainActor
private func makeNSMenu(items: [ContextMenuItem]) -> NSMenu {
    let dispatcher = ContextMenuActionDispatcher()
    let menu = StableContextMenu(dispatcher: dispatcher)
    for item in items {
        menu.addItem(makeNSMenuItem(from: item, dispatcher: dispatcher))
    }
    return menu
}

@MainActor
private func makeNSMenuItem(
    from item: ContextMenuItem,
    dispatcher: ContextMenuActionDispatcher
) -> NSMenuItem {
    switch item {
    case let .button(title, image, isEnabled, accessibilityLabel, action):
        let tag = dispatcher.registerAction(action)
        let nsItem = NSMenuItem(
            title: title,
            action: #selector(ContextMenuActionDispatcher.invoke(_:)),
            keyEquivalent: ""
        )
        nsItem.target = dispatcher
        nsItem.tag = tag
        nsItem.image = image
        nsItem.isEnabled = isEnabled
        if let label = accessibilityLabel {
            nsItem.setAccessibilityLabel(label)
        }
        return nsItem
    case let .submenu(title, image, isEnabled, accessibilityLabel, subitems):
        let nsItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        nsItem.image = image
        nsItem.isEnabled = isEnabled
        if let label = accessibilityLabel {
            nsItem.setAccessibilityLabel(label)
        }
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        for child in subitems {
            sub.addItem(makeNSMenuItem(from: child, dispatcher: dispatcher))
        }
        nsItem.submenu = sub
        return nsItem
    case .divider:
        return .separator()
    }
}

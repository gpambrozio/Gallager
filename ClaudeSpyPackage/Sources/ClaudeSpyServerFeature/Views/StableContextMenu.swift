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
    /// Unlike `.contextMenu { … }`, which AppKit can dismiss whenever the
    /// underlying view's `setMenu:` is called during a parent re-render,
    /// this builds the `NSMenu` lazily inside `NSView.menu(for:)` on
    /// right-click. Parent re-renders touch the hosting view's `rootView`
    /// but never re-attach a menu, so an open submenu (e.g. "Open in
    /// Editor") survives `@Observable` mutations in any ancestor.
    func stableContextMenu(
        _ items: @escaping @MainActor () -> [ContextMenuItem]
    ) -> some View {
        StableContextMenuContainer(content: self, items: items)
    }
}

private struct StableContextMenuContainer<Content: View>: NSViewRepresentable {
    let content: Content
    let items: @MainActor () -> [ContextMenuItem]

    func makeNSView(context: Context) -> StableContextMenuHostingView<Content> {
        let view = StableContextMenuHostingView(rootView: content)
        view.itemsBuilder = items
        return view
    }

    func updateNSView(_ nsView: StableContextMenuHostingView<Content>, context: Context) {
        nsView.rootView = content
        nsView.itemsBuilder = items
    }
}

/// `NSHostingView` subclass that intercepts right-clicks via `menu(for:)`
/// and returns a freshly-built `NSMenu`. The menu is never assigned to
/// `self.menu`, so SwiftUI's `updateNSView` path never triggers
/// `setMenu:` on AppKit — and `setMenu:` is the call that AppKit treats
/// as a reason to dismiss any currently-tracking menu.
final private class StableContextMenuHostingView<Content: View>: NSHostingView<Content> {
    var itemsBuilder: (@MainActor () -> [ContextMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let itemsBuilder else { return nil }
        let items = itemsBuilder()
        guard !items.isEmpty else { return nil }
        return makeNSMenu(items: items)
    }

    // `NSHostingView` declares `init(rootView:)` as `required`, and Swift
    // does not consider the superclass-defined init "inherited" through the
    // generic + stored-property layout here — the compiler errors with
    // "required initializer 'init(rootView:)' must be provided by subclass"
    // if this stub is removed.
    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor
    dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
/// `NSHostingView.menu(for:)` returns, leaving every click a no-op.
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

#if os(macOS)
    import Foundation

    /// A logical, serializable snapshot of a session's workbench layout — the
    /// open file tabs, open browser tabs, the split-view arrangement, and the
    /// file-tree chrome. Persisted per folder so a session can restore its
    /// layout across app restarts (see `docs/folder-layout-persistence-plan.md`).
    ///
    /// "Logical" because it cannot store the live runtime types verbatim:
    /// `TabDragPayload.window(String)` references a tmux window id that is
    /// session-name-scoped, and `BrowserTabState` wraps a `WKWebView` that can't
    /// be serialized. File/browser tab UUIDs *are* preserved (a freshly restored
    /// session has no tabs to collide with), so only window references need to be
    /// re-mapped — by tmux window *index* — at restore time.
    struct SavedFolderLayout: Codable, Sendable, Equatable {
        /// Bumped when the wire format changes incompatibly. Decode failures and
        /// version mismatches fall back to an empty workbench (best-effort).
        var schemaVersion: Int

        var fileTabs: [SavedFileTab]
        var browserTabs: [SavedBrowserTab]

        /// Unified tab-strip ordering, as logical references.
        var tabOrder: [SavedTabRef]
        /// Tab-strip entries that were moved to the right split pane.
        var rightSide: [SavedTabRef]
        /// Active tab in the left pane (`nil` → file tree / terminal).
        var selectedLeft: SavedTabRef?
        /// Active tab in the right pane.
        var selectedRight: SavedTabRef?
        /// Left-pane width fraction, clamped to `SplitLayout.minRatio…maxRatio`.
        var splitRatio: CGFloat

        /// File-tree chrome (sidebar width + expanded folders). `nil` when no
        /// file browser was materialized for the session.
        var fileTree: SavedFileTree?

        static let currentSchemaVersion = 1

        init(
            schemaVersion: Int = SavedFolderLayout.currentSchemaVersion,
            fileTabs: [SavedFileTab] = [],
            browserTabs: [SavedBrowserTab] = [],
            tabOrder: [SavedTabRef] = [],
            rightSide: [SavedTabRef] = [],
            selectedLeft: SavedTabRef? = nil,
            selectedRight: SavedTabRef? = nil,
            splitRatio: CGFloat = 0.5,
            fileTree: SavedFileTree? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.fileTabs = fileTabs
            self.browserTabs = browserTabs
            self.tabOrder = tabOrder
            self.rightSide = rightSide
            self.selectedLeft = selectedLeft
            self.selectedRight = selectedRight
            self.splitRatio = splitRatio
            self.fileTree = fileTree
        }

        /// True when there's nothing worth persisting or restoring. Used to avoid
        /// writing empty records and to short-circuit seeding.
        var isEmpty: Bool {
            fileTabs.isEmpty && browserTabs.isEmpty && tabOrder.isEmpty && rightSide.isEmpty
        }
    }

    /// An open file tab. `id` is preserved across restore so `SavedTabRef.file`
    /// references stay valid in the rebuilt session.
    struct SavedFileTab: Codable, Sendable, Equatable, Hashable {
        var id: UUID
        var path: String
        var directoryPath: String
    }

    /// An open browser tab. The live `WKWebView` is not stored — it is recreated
    /// from `url` at restore time. `id`/`parentId` are preserved so tab
    /// relationships and `SavedTabRef.browser` references survive.
    struct SavedBrowserTab: Codable, Sendable, Equatable, Hashable {
        var id: UUID
        var url: URL
        var displayTitle: String?
        var parentId: UUID?
    }

    /// File-tree chrome worth restoring. Scroll offsets and the search query are
    /// deliberately excluded — too ephemeral to be useful across restarts.
    struct SavedFileTree: Codable, Sendable, Equatable {
        var sidebarWidth: CGFloat
        var expandedPaths: [String]

        init(sidebarWidth: CGFloat, expandedPaths: [String] = []) {
            self.sidebarWidth = sidebarWidth
            self.expandedPaths = expandedPaths
        }
    }

    /// A logical reference to one tab-strip entry, decoupled from the runtime
    /// `TabDragPayload` so the persisted format doesn't depend on a UI enum's
    /// synthesized `Codable` shape.
    ///
    /// - `.window(index:)` is best-effort: it re-maps to whatever tmux window
    ///   occupies that index in the restored session, and is dropped if no such
    ///   window exists (terminal windows are live tmux state, not restorable).
    /// - `.file`/`.browser` reference a `SavedFileTab`/`SavedBrowserTab` by its
    ///   preserved `id`.
    enum SavedTabRef: Codable, Sendable, Equatable, Hashable {
        case window(index: Int)
        case fileExplorer
        case git
        case file(id: UUID)
        case browser(id: UUID)
    }
#endif

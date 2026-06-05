import Foundation
import Testing
@testable import ClaudeSpyServerFeature

/// Covers the unified tab-strip ordering that both the visible `WindowTabBar`
/// and the Cmd-Shift-[ / Cmd-Shift-] keyboard navigation (issue #566) derive
/// from. The reconciliation must keep the user's drag-reordered layout —
/// including a browser/file tab dragged *between* two terminal windows —
/// instead of regrouping by kind.
@Suite("TabDragPayload.reconciledOrder")
struct TabStripOrderTests {
    @Test("Empty stored order falls back to windows, file explorer, git, files, browsers")
    func defaultOrder() {
        let w1 = "win-1"
        let w2 = "win-2"
        let file = UUID()
        let browser = UUID()

        let order = TabDragPayload.reconciledOrder(
            windowIds: [w1, w2],
            fileTabIds: [file],
            browserTabIds: [browser],
            storedOrder: []
        )

        // The Git tab (issue #258) is a local-only singleton that slots in
        // immediately to the right of the file explorer.
        #expect(order == [
            .window(w1),
            .window(w2),
            .fileExplorer,
            .git,
            .file(file),
            .browser(browser),
        ])
    }

    @Test("A browser dragged between two windows keeps its interleaved position")
    func interleavedOrderIsPreserved() {
        // Reproduces issue #566: starting layout T1-T2-FileExplorer-Browser,
        // the user drags Browser to sit between T1 and T2.
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()

        let reordered: [TabDragPayload] = [
            .window(t1),
            .browser(browser),
            .window(t2),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: reordered
        )

        // The interleaved browser keeps its dragged spot; the Git tab the
        // stored order didn't yet know about slots in after the file explorer.
        #expect(order == reordered + [.git])
    }

    @Test("New windows slot in just before the file explorer")
    func newWindowSlotsInBeforeFileExplorer() {
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()

        // Stored order only knows about T1 + Browser (reordered); a new
        // window T2 has just appeared and is not yet in the stored order.
        let stored: [TabDragPayload] = [
            .window(t1),
            .browser(browser),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: stored
        )

        #expect(order == [
            .window(t1),
            .browser(browser),
            .window(t2),
            .fileExplorer,
            .git,
        ])
    }

    @Test("Entries whose underlying data is gone drop out of the order")
    func staleEntriesArePruned() {
        let t1 = "win-1"
        let goneWindow = "win-gone"
        let goneBrowser = UUID()

        let stored: [TabDragPayload] = [
            .window(t1),
            .window(goneWindow),
            .browser(goneBrowser),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1],
            fileTabIds: [],
            browserTabIds: [],
            storedOrder: stored
        )

        #expect(order == [.window(t1), .fileExplorer, .git])
    }

    @Test("Reconciliation is idempotent")
    func idempotent() {
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()
        let stored: [TabDragPayload] = [
            .window(t1),
            .browser(browser),
            .window(t2),
            .fileExplorer,
        ]

        let once = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: stored
        )
        let twice = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: once
        )

        #expect(once == twice)
    }

    @Test("Duplicate refs in the stored order collapse to a single entry")
    func duplicateRefsAreDeduped() {
        let t1 = "win-1"
        let browser = UUID()

        // A corrupt/legacy stored order containing the same refs twice.
        let stored: [TabDragPayload] = [
            .window(t1),
            .window(t1),
            .fileExplorer,
            .browser(browser),
            .browser(browser),
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: stored
        )

        #expect(order == [.window(t1), .fileExplorer, .git, .browser(browser)])
    }

    @Test("New windows append before an absent file explorer falls back to the end")
    func newWindowsFallBackToEndWhenNoFileExplorerStored() {
        let t1 = "win-1"
        let t2 = "win-2"

        // Stored order omits the file explorer entirely; both windows are
        // live, so the `insertAt ?? order.count` fallback drives placement.
        let stored: [TabDragPayload] = [.window(t1)]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [],
            storedOrder: stored
        )

        #expect(order == [.window(t1), .window(t2), .fileExplorer, .git])
    }

    @Test("Remote sessions omit the file explorer and git tab entirely")
    func remoteDefaultOrderHasNoFileExplorer() {
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: [],
            includeFileExplorer: false,
            includeGit: false
        )

        #expect(order == [.window(t1), .window(t2), .browser(browser)])
    }

    @Test("A new remote window slots in before the first browser tab")
    func remoteNewWindowSlotsInBeforeBrowser() {
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()

        // Stored order knows T1 + Browser; a new window T2 has just appeared.
        // The old inline remote cycler dropped it from Cmd-Shift-[/] cycling
        // (issue #566); the shared helper must slot it in.
        let stored: [TabDragPayload] = [
            .window(t1),
            .browser(browser),
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: stored,
            includeFileExplorer: false,
            includeGit: false
        )

        #expect(order == [.window(t1), .window(t2), .browser(browser)])
    }

    @Test("A dragged Git tab keeps its interleaved position")
    func gitTabInterleaveIsPreserved() {
        let t1 = "win-1"
        let t2 = "win-2"

        // The user dragged the Git tab to sit between the two terminals.
        let reordered: [TabDragPayload] = [
            .window(t1),
            .git,
            .window(t2),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [],
            storedOrder: reordered
        )

        #expect(order == reordered)
    }

    @Test("A new git entry slots in just after the file explorer")
    func newGitSlotsInAfterFileExplorer() {
        let t1 = "win-1"

        // Stored order predates the Git tab (issue #258) — only the window and
        // explorer are known; the synthetic git entry must land right after the
        // explorer rather than at the end.
        let stored: [TabDragPayload] = [
            .window(t1),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1],
            fileTabIds: [],
            browserTabIds: [],
            storedOrder: stored
        )

        #expect(order == [.window(t1), .fileExplorer, .git])
    }
}

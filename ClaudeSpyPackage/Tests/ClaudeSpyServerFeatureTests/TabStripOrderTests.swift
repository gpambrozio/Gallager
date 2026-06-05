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
    @Test("Empty stored order falls back to windows, file explorer, files, browsers")
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

        #expect(order == [
            .window(w1),
            .window(w2),
            .fileExplorer,
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

        #expect(order == reordered)
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

        #expect(order == [.window(t1), .fileExplorer])
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
}

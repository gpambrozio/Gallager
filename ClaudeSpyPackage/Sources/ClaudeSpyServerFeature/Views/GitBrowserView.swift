import GitWorkbench
import SwiftUI

/// The Git tab's content (issue #258): a thin wrapper around the third-party
/// ``GitWorkbenchView`` so the rest of the app deals with a ClaudeSpy-shaped
/// view and a single place to attach an accessibility identifier for E2E.
///
/// The ``GitWorkbenchStore`` is owned by ``MainView`` and cached per session, so
/// the git state (selected workspace view, file, diff) survives tab/session
/// switches — mirroring how `FileBrowserState` is retained. This view only
/// observes the store; it never creates it.
struct GitBrowserView: View {
    let store: GitWorkbenchStore

    var body: some View {
        GitWorkbenchView(store: store)
            .accessibilityIdentifier("git-workbench")
    }
}

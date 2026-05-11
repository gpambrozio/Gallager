import AppKit
import SwiftUI

extension View {
    /// Makes a file-explorer row draggable so the underlying file or
    /// folder can be dropped into other apps (Finder, Terminal, Mail,
    /// …) like a native file drag.
    ///
    /// `NSItemProvider(object: url as NSURL)` is what registers
    /// `public.file-url` on the drag pasteboard — Finder/Mail/Terminal
    /// look for that type to treat the payload as a real file copy
    /// rather than a plain URL string. `.draggable(URL)` would only
    /// expose `public.url` via URL's default `Transferable` proxy,
    /// which Finder ignores for file copies.
    ///
    /// `.onDrag` consumes the mouse-down on its hit region inside
    /// `List` + `NavigationLink` rows: clicks landing on the `Label`
    /// never reach the link, so the row stops registering selection
    /// clicks. Symptom: rows whose `Label` fills the row become
    /// unselectable, while shorter rows stay clickable because their
    /// empty trailing area sits outside the drag region. To restore
    /// selection we install a `simultaneousGesture(TapGesture)` that
    /// runs in parallel with the drag and routes a pure tap to
    /// `select`, which the caller wires to the same selection state
    /// `NavigationLink` would have set. Drags still work for actual
    /// drags; clicks still select on every row regardless of label
    /// width.
    ///
    /// No-op when `path` is nil, so the modifier can be applied
    /// unconditionally to rows whose stable-id lookup hasn't resolved
    /// a path yet (avoids initiating an empty drag).
    @ViewBuilder
    func draggableFile(path: String?, select: @escaping () -> Void) -> some View {
        if let path {
            onDrag {
                NSItemProvider(object: URL(filePath: path) as NSURL)
            }
            .simultaneousGesture(TapGesture().onEnded(select))
        } else {
            self
        }
    }
}

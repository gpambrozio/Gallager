import AppKit
import SwiftUI

extension View {
    /// Makes a file-explorer row draggable so the underlying file or folder
    /// can be dropped into other apps (Finder, Terminal, Mail, …) like a
    /// native file drag.
    ///
    /// `NSItemProvider(object: url as NSURL)` is what registers
    /// `public.file-url` on the drag pasteboard for file URLs — this is the
    /// type drop targets look for to treat the payload as a real file rather
    /// than a plain URL string. Using `.draggable(URL)` instead would only
    /// expose `public.url` via `URL`'s default `Transferable` representation,
    /// which Finder ignores for file copies.
    ///
    /// No-op when `path` is nil, so the modifier can be applied
    /// unconditionally to rows whose stable-id lookup hasn't resolved a path
    /// yet (avoids initiating an empty drag).
    @ViewBuilder
    func draggableFile(path: String?) -> some View {
        if let path {
            onDrag {
                NSItemProvider(object: URL(filePath: path) as NSURL)
            }
        } else {
            self
        }
    }
}

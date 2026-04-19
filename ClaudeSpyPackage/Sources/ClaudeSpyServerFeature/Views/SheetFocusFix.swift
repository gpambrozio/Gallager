#if os(macOS)
    import AppKit
    import SwiftUI

    extension View {
        /// Forces the hosting app/window to become active and key when a
        /// SwiftUI sheet appears.
        ///
        /// Menu-bar-extra apps (`LSUIElement`-style) sometimes present sheets
        /// whose buttons render in an inactive state — a `.borderedProminent`
        /// button, for example, may be drawn without its blue fill until the
        /// user clicks somewhere in the sheet. Activating `NSApp` and
        /// re-keying the sheet's window on appear gives AppKit the nudge it
        /// needs so controls render active immediately.
        func sheetFocusFix() -> some View {
            modifier(SheetFocusFixModifier())
        }
    }

    private struct SheetFocusFixModifier: ViewModifier {
        func body(content: Content) -> some View {
            content.background(SheetFocusFixBridge())
        }
    }

    /// Reaches into AppKit to find the hosting window once the sheet has
    /// attached, activates the app, and re-makes the window key.
    private struct SheetFocusFixBridge: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            DispatchQueue.main.async { [weak view] in
                NSApp.activate(ignoringOtherApps: true)
                view?.window?.makeKeyAndOrderFront(nil)
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) { }
    }
#endif

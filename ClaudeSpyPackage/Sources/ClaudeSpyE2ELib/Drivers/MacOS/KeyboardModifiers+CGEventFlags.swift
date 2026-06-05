#if os(macOS)
    import CoreGraphics

    extension KeyboardModifiers {
        /// Convert from the framework-neutral `KeyboardModifiers` declared in
        /// the DSL into the `CGEventFlags` value that `CGEvent.flags` accepts.
        var cgEventFlags: CGEventFlags {
            var flags: CGEventFlags = []
            if contains(.command) { flags.insert(.maskCommand) }
            if contains(.shift) { flags.insert(.maskShift) }
            if contains(.option) { flags.insert(.maskAlternate) }
            if contains(.control) { flags.insert(.maskControl) }
            return flags
        }
    }
#endif

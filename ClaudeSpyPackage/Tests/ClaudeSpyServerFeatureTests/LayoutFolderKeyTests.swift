#if os(macOS)
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Covers `LayoutFolderKey`: the local canonicalizer (resolve `~`/symlinks)
    /// and the remote, string-only normalizer that must NOT touch the viewer's
    /// disk. See `docs/folder-layout-persistence-plan.md` §4.6 and issue #608.
    struct LayoutFolderKeyTests {
        // MARK: - canonicalizeRemote

        @Test("remote: nil / empty inputs produce nil")
        func remoteNilEmpty() {
            #expect(LayoutFolderKey.canonicalizeRemote(nil) == nil)
            #expect(LayoutFolderKey.canonicalizeRemote("") == nil)
        }

        @Test("remote: strips a trailing slash but keeps the rest verbatim")
        func remoteTrailingSlash() {
            #expect(LayoutFolderKey.canonicalizeRemote("/home/user/project/") == "/home/user/project")
            #expect(LayoutFolderKey.canonicalizeRemote("/home/user/project") == "/home/user/project")
            #expect(LayoutFolderKey.canonicalizeRemote("/home/user/project///") == "/home/user/project")
        }

        @Test("remote: root path is preserved")
        func remoteRoot() {
            #expect(LayoutFolderKey.canonicalizeRemote("/") == "/")
        }

        @Test("remote: does NOT expand ~ (it belongs to the host, not the viewer)")
        func remoteLeavesTildeLiteral() {
            // The local canonicalizer would expand this against the viewer's
            // home dir; the remote one must leave it untouched.
            #expect(LayoutFolderKey.canonicalizeRemote("~/project") == "~/project")
        }

        @Test("remote: does NOT resolve symlinks or .. segments against local disk")
        func remoteLeavesPathLiteral() {
            // A path that means one thing on the host and (maybe) another on the
            // viewer must be kept as the host reported it.
            #expect(LayoutFolderKey.canonicalizeRemote("/var/host-only/../app") == "/var/host-only/../app")
        }

        @Test("remote: the same host path normalizes to one stable key")
        func remoteStableKey() {
            let a = LayoutFolderKey.canonicalizeRemote("/srv/code/app")
            let b = LayoutFolderKey.canonicalizeRemote("/srv/code/app/")
            #expect(a == b)
            #expect(a == "/srv/code/app")
        }
    }
#endif

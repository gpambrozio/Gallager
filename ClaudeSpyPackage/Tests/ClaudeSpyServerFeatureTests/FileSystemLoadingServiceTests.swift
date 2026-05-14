#if os(macOS)
    import Files
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("File browser refresh on disk changes")
    @MainActor
    struct FileSystemLoadingServiceTests {
        /// Reproduces issue #524 by exercising the exact watcher loop the
        /// production view runs in `.task`. The loop must surface a file
        /// dropped into a watched directory without the user manually
        /// poking a folder expansion.
        ///
        /// Routes through `FileBrowserState.runDirectoryWatcher(...)` so the
        /// test fails the moment a future change strips the on-attach
        /// reload and the watcher regresses to the buggy behaviour where a
        /// new file lands in the kqueue gap and stays invisible.
        @Test("watcher loop surfaces a file dropped into the watched directory")
        func watcherLoopRefreshesTreeOnNewFile() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeSpy-watcher-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try "seed".write(
                to: tempDir.appendingPathComponent("existing.txt"),
                atomically: true,
                encoding: .utf8
            )

            let service = FileSystemLoadingService.liveValue
            let state = FileBrowserState()

            // First reload populates `viewState`, just like the view's
            // initial `.task(id: directoryPath)` does on mount.
            await state.reloadTree(directoryPath: tempDir.path, service: service)
            #expect(rootChildNames(of: state) == ["existing.txt"])

            // Run the same watcher loop the view spins up in
            // `.task(id: state.loadedFolderPaths)`. Cancellation tears the
            // task down at the end of the test.
            let watcher = Task { @MainActor in
                await state.runDirectoryWatcher(rootDirectoryPath: tempDir.path, service: service)
            }

            // Give the kqueue source a moment to register before touching
            // the directory — `DispatchSource.resume()` returns immediately
            // but the kernel registration completes asynchronously.
            try await Task.sleep(for: .milliseconds(100))

            try "fresh".write(
                to: tempDir.appendingPathComponent("appears.txt"),
                atomically: true,
                encoding: .utf8
            )

            // Cap the wait so a regression fails fast (kqueue is real-time
            // OS work, not something a TestClock can replace).
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, !rootChildNames(of: state).contains("appears.txt") {
                try await Task.sleep(for: .milliseconds(50))
            }

            watcher.cancel()

            #expect(
                rootChildNames(of: state).contains("appears.txt"),
                "After a watcher event for a new file, the FileBrowserState's tree must contain it"
            )
        }

        /// Reproduces the exact failure mode of issue #524: when SwiftUI
        /// recreates the file-browser watcher (e.g. because
        /// `state.loadedFolderPaths` changed after a folder expansion)
        /// there's a brief window between the previous watcher being
        /// cancelled and the new one re-arming the kqueue sources. A file
        /// written in that gap fires no event for either watcher and never
        /// lands in the rebuilt tree — the user has to manually expand a
        /// subfolder before the file appears.
        ///
        /// `runDirectoryWatcher(...)` closes the gap by reloading the tree
        /// once on attach. The test simulates the scenario by writing a
        /// file *between* two watcher cycles and then asking the second
        /// watcher to surface it; without the on-attach reload this test
        /// times out and fails.
        @Test("watcher loop reloads on attach so files written during the gap appear")
        func watcherLoopClosesGapBetweenCycles() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeSpy-watcher-gap-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try "seed".write(
                to: tempDir.appendingPathComponent("existing.txt"),
                atomically: true,
                encoding: .utf8
            )

            let service = FileSystemLoadingService.liveValue
            let state = FileBrowserState()

            await state.reloadTree(directoryPath: tempDir.path, service: service)
            #expect(rootChildNames(of: state) == ["existing.txt"])

            // First watcher cycle, allowed to attach.
            let firstWatcher = Task { @MainActor in
                await state.runDirectoryWatcher(rootDirectoryPath: tempDir.path, service: service)
            }
            try await Task.sleep(for: .milliseconds(100))

            // Tear the first watcher down and immediately drop a file —
            // this is the bug's root condition. A new watcher in
            // production is recreated by SwiftUI when
            // `state.loadedFolderPaths` changes, and any disk write that
            // lands while neither old nor new sources are armed never
            // reaches the for-await loop.
            firstWatcher.cancel()
            try "gap".write(
                to: tempDir.appendingPathComponent("gap-file.txt"),
                atomically: true,
                encoding: .utf8
            )

            // Second watcher cycle. The on-attach reload inside
            // `runDirectoryWatcher(...)` is what surfaces the gap file —
            // no kqueue event will ever fire for it.
            let secondWatcher = Task { @MainActor in
                await state.runDirectoryWatcher(rootDirectoryPath: tempDir.path, service: service)
            }

            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, !rootChildNames(of: state).contains("gap-file.txt") {
                try await Task.sleep(for: .milliseconds(50))
            }
            secondWatcher.cancel()

            #expect(
                rootChildNames(of: state).contains("gap-file.txt"),
                "Files written between watcher cycles must be picked up by the next reload"
            )
        }

        /// Returns the names of the top-level children of the root folder
        /// in the order ProjectNavigator would render them. Returns an
        /// empty array if the state hasn't loaded a tree yet or the root
        /// isn't a folder.
        private func rootChildNames(of state: FileBrowserState) -> [String] {
            guard
                let root = state.viewState?.fileTree.root,
                case let .folder(folder) = root
            else { return [] }
            return Array(folder.children.keys)
        }
    }
#endif

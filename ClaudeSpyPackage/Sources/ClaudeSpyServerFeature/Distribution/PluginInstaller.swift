#if os(macOS)
    import Foundation
    import GallagerPluginProtocol

    /// Namespace for plugin distribution helpers: id sanitization and folder-drop discovery.
    ///
    /// URL download lands in a later task (Task 12/13). This file covers only the
    /// folder-drop path: enumerate `~/.gallager/plugins/`, validate each subdir,
    /// and return the manifests + roots that are safe to enable.
    public enum PluginInstaller {
        // MARK: - ID sanitization

        /// Return `id` iff it matches `^[a-z0-9][a-z0-9._-]*$`, contains no `..`,
        /// and is ≤ 128 characters; otherwise return `nil`.
        ///
        /// These checks guarantee that using the id as a filesystem path component
        /// can never escape the plugins directory via traversal sequences or
        /// absolute paths.
        public static func sanitize(id: String) -> String? {
            guard !id.isEmpty, id.count <= 128 else { return nil }
            guard !id.contains("..") else { return nil }
            // First character: lowercase letter or digit only.
            guard
                let first = id.unicodeScalars.first,
                isLower(first) || isDigit(first) else { return nil }
            // Remaining characters: lowercase letter, digit, dot, underscore, or hyphen.
            for scalar in id.unicodeScalars.dropFirst() {
                guard isLower(scalar) || isDigit(scalar) || scalar == "." || scalar == "_" || scalar == "-" else {
                    return nil
                }
            }
            return id
        }

        // MARK: - Folder-drop discovery

        /// Enumerate the immediate subdirectories of `pluginsDir`, load `plugin.json`
        /// from each, and return the valid sidecar plugins.
        ///
        /// A folder is kept only when all of these hold:
        /// 1. The manifest decodes successfully.
        /// 2. `manifest.runtime == .sidecar`.
        /// 3. `sanitize(id: manifest.id) != nil` AND the sanitized id equals the
        ///    directory name (so an id cannot point outside its own folder).
        /// 4. The executable declared in the manifest (or `bin/sidecar` when absent)
        ///    exists under the plugin root and has the executable bit set.
        ///
        /// Any folder that fails any check is silently skipped — discovery never crashes.
        /// Results are returned in directory-enumeration order (locale-sorted by the OS).
        public static func discoverFolderDropped(pluginsDir: URL) -> [(manifest: PluginManifest, root: URL)] {
            let fm = FileManager.default
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: pluginsDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                return []
            }

            var results: [(manifest: PluginManifest, root: URL)] = []

            for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // Must be a directory.
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }

                let dirName = entry.lastPathComponent

                // Load and decode the manifest; skip on any failure.
                guard let manifest = try? PluginManifest.load(fromPluginRoot: entry) else {
                    continue
                }

                // Must be a sidecar plugin.
                guard manifest.runtime == .sidecar else { continue }

                // Sanitize the manifest's id and verify it matches the directory name.
                guard let sanitizedID = sanitize(id: manifest.id), sanitizedID == dirName else {
                    continue
                }

                // Resolve the executable path: use the manifest's declared executable,
                // falling back to `bin/sidecar`.
                let executableRelativePath = manifest.sidecar?.executable ?? "bin/sidecar"
                let executableURL = entry.appendingPathComponent(executableRelativePath)

                // Executable must exist and have the executable bit set.
                guard fm.isExecutableFile(atPath: executableURL.path) else { continue }

                results.append((manifest: manifest, root: entry))
            }

            return results
        }

        // MARK: - Private helpers

        private static func isLower(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value >= 97 && scalar.value <= 122 // 'a'...'z'
        }

        private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value >= 48 && scalar.value <= 57 // '0'...'9'
        }
    }
#endif

import Foundation

public enum LibghosttyEmbeddedResourcesLocator {
    /// A place the emitted libghostty `share` tree can live, relative to a
    /// candidate root. The compiled terminfo entry is the sentinel proving
    /// the tree is a real resource bundle rather than a same-named directory.
    private struct Layout {
        let resources: [String]
        let terminfoSentinel: [String]

        init(prefix: [String]) {
            resources = prefix + ["ghostty"]
            terminfoSentinel = prefix + ["terminfo", "78", "xterm-ghostty"]
        }
    }

    private static let layouts = [
        // Repo-local staged bootstrap artifacts.
        Layout(prefix: [".build", "libghostty", "share"]),
        // Packaged Ghosthub.app bundle.
        Layout(prefix: ["Contents", "Resources"]),
    ]

    /// Points `GHOSTTY_RESOURCES_DIR` at Ghosthub's own resources.
    ///
    /// Ghostty exports this variable into every shell it runs, so launching
    /// Ghosthub from a Ghostty terminal otherwise inherits Ghostty.app's
    /// themes and shell integration — and a release libghostty trusts the
    /// variable ahead of its own executable-path discovery. Ghosthub's
    /// resources therefore override an inherited value, and an inherited
    /// value is used only when Ghosthub has no resources of its own.
    public static func configureEnvironmentIfNeeded(
        executablePath: String = ProcessInfo.processInfo.arguments.first ?? "",
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> URL? {
        guard let resourcesURL = effectiveResourcesDirectory(
            executablePath: executablePath,
            currentDirectoryPath: currentDirectoryPath,
            inheritedResourcesPath: ProcessInfo.processInfo
                .environment["GHOSTTY_RESOURCES_DIR"]
        ) else { return nil }

        setenv("GHOSTTY_RESOURCES_DIR", resourcesURL.path, 1)
        return resourcesURL
    }

    static func effectiveResourcesDirectory(
        executablePath: String,
        currentDirectoryPath: String,
        inheritedResourcesPath: String?
    ) -> URL? {
        if let resourcesURL = resolveResourcesDirectory(
            executablePath: executablePath,
            currentDirectoryPath: currentDirectoryPath
        ) {
            return resourcesURL
        }

        guard let inheritedResourcesPath, !inheritedResourcesPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: inheritedResourcesPath, isDirectory: true)
    }

    static func resolveResourcesDirectory(
        executablePath: String,
        currentDirectoryPath: String
    ) -> URL? {
        let roots = candidateRoots(
            executablePath: executablePath,
            currentDirectoryPath: currentDirectoryPath
        )

        for root in roots {
            for layout in layouts {
                let resourcesURL = root.appendingPathComponents(layout.resources)
                let terminfoURL = root.appendingPathComponents(layout.terminfoSentinel)
                guard FileManager.default.fileExists(atPath: resourcesURL.path),
                      FileManager.default.fileExists(atPath: terminfoURL.path)
                else { continue }
                return resourcesURL
            }
        }

        return nil
    }

    static func candidateRoots(
        executablePath: String,
        currentDirectoryPath: String
    ) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()

        func appendAncestors(of path: String) {
            guard !path.isEmpty else { return }

            var currentURL = URL(fileURLWithPath: path, isDirectory: true)
            if !path.hasSuffix("/") {
                currentURL.deleteLastPathComponent()
            }

            while true {
                let standardized = currentURL.standardizedFileURL.path
                if seen.insert(standardized).inserted {
                    roots.append(currentURL)
                }

                let parent = currentURL.deletingLastPathComponent()
                if parent.path == currentURL.path {
                    break
                }
                currentURL = parent
            }
        }

        appendAncestors(of: executablePath)
        appendAncestors(of: currentDirectoryPath + "/")

        return roots
    }
}

private extension URL {
    func appendingPathComponents(_ components: [String]) -> URL {
        components.reduce(self) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }
}

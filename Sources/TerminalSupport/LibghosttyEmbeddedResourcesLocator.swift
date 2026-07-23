import Foundation

public enum LibghosttyEmbeddedResourcesLocator {
    private static let relativeResourcePath = [
        ".build",
        "libghostty",
        "source",
        "zig-out",
        "share",
        "ghostty",
    ]

    private static let relativeTerminfoSentinel = [
        ".build",
        "libghostty",
        "source",
        "zig-out",
        "share",
        "terminfo",
        "78",
        "xterm-ghostty",
    ]

    public static func configureEnvironmentIfNeeded(
        executablePath: String = ProcessInfo.processInfo.arguments.first ?? "",
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> URL? {
        if let existing = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
           !existing.isEmpty {
            return URL(fileURLWithPath: existing, isDirectory: true)
        }

        guard let resourcesURL = resolveResourcesDirectory(
            executablePath: executablePath,
            currentDirectoryPath: currentDirectoryPath
        ) else {
            return nil
        }

        setenv("GHOSTTY_RESOURCES_DIR", resourcesURL.path, 1)
        return resourcesURL
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
            let resourcesURL = root.appendingPathComponents(relativeResourcePath)
            let terminfoURL = root.appendingPathComponents(relativeTerminfoSentinel)
            guard FileManager.default.fileExists(atPath: resourcesURL.path),
                  FileManager.default.fileExists(atPath: terminfoURL.path)
            else { continue }
            return resourcesURL
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

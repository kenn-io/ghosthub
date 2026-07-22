import Foundation
import GhosthubTmux

enum KwtBinaryLocator {
    static func bundledPath(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> String? {
        bundledPath(bundleURL: bundle.bundleURL, fileManager: fileManager)
    }

    static func bundledPath(
        bundleURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let candidate = bundleURL
            .appendingPathComponent("Contents/Helpers/kwt").path

        // A packaged Ghosthub must never drift to a separately installed kwt.
        // Return the exact bundle location even when packaging is damaged so the
        // attempted command fails closed instead of falling back to PATH.
        if bundleURL.pathExtension.lowercased() == "app" {
            return candidate
        }

        // Preserve PATH-based development and test execution outside an app
        // bundle unless an executable helper has explicitly been staged there.
        guard fileManager.isExecutableFile(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    static func commandPrelude(exactPath: String?) -> String {
        if let exactPath {
            return "ghosthub_kwt_path="
                + shellQuotedCommandArgument(exactPath)
                + "; "
        }
        return "ghosthub_kwt_path=$(command -v kwt) || exit 127; "
    }
}

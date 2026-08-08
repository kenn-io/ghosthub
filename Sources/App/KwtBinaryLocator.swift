import GhosthubTransport
import Foundation
import GhosthubTmux

enum KwtBinaryLocator {
    private static let remoteRevisionKey =
        "GhosthubRemoteKwtSourceRevision"

    enum WindowsArchitecture: String, Equatable, Sendable {
        case amd64
        case arm64

        init?(remoteValue: String) {
            switch remoteValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() {
            case "x64", "amd64", "x86_64":
                self = .amd64
            case "arm64", "aarch64":
                self = .arm64
            default:
                return nil
            }
        }
    }

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

    static func bundledRemoteRevision(
        bundle: Bundle = .main
    ) -> String? {
        validRevision(
            bundle.object(
                forInfoDictionaryKey: remoteRevisionKey
            ) as? String
        )
    }

    static func remoteManagedPath(revision: String) -> String? {
        guard let revision = validRevision(revision) else {
            return nil
        }
        return "$HOME/.ghosthub/helpers/kwt/\(revision)/kwt"
    }

    static func remoteCommandPrelude(revision: String?) -> String {
        guard let revision,
              let path = remoteManagedPath(revision: revision)
        else {
            return "printf 'Ghosthub: managed kwt is unavailable\\n' >&2; "
                + "exit 127; "
        }
        return "ghosthub_kwt_path=\"\(path)\"; "
            + "[ -x \"$ghosthub_kwt_path\" ] || exit 127; "
    }

    static func windowsRemoteManagedRelativePath(
        revision: String?
    ) -> String? {
        guard let revision = validRevision(revision) else {
            return nil
        }
        return #".ghosthub\helpers\kwt\"#
            + revision
            + #"\kwt.exe"#
    }

    static func windowsBundledPath(
        architecture: WindowsArchitecture,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> String {
        bundleURL
            .appendingPathComponent("Contents/Resources/KwtRemote")
            .appendingPathComponent("windows-\(architecture.rawValue)")
            .appendingPathComponent("kwt")
            .path
    }

    private static func validRevision(_ value: String?) -> String? {
        guard let value, value.count == 40,
              value.allSatisfy({ $0.isHexDigit })
        else {
            return nil
        }
        return value.lowercased()
    }
}

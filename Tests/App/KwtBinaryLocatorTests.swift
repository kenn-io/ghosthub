import Foundation
import Testing
@testable import GhosthubApp

@Suite("Bundled kwt selection")
struct KwtBinaryLocatorTests {
    @Test("packaged app always selects its exact helper path")
    func packagedAppFailsClosedWhenHelperIsMissing() {
        let appURL = URL(fileURLWithPath: "/Applications/Ghosthub.app")

        #expect(
            KwtBinaryLocator.bundledPath(bundleURL: appURL)
                == "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )
    }

    @Test("non-app development execution can fall back to PATH")
    func developmentExecutionCanFallBackToPath() {
        let executableURL = URL(fileURLWithPath: "/tmp/GhosthubApp")

        #expect(KwtBinaryLocator.bundledPath(bundleURL: executableURL) == nil)
        #expect(
            KwtBinaryLocator.commandPrelude(exactPath: nil)
                == "ghosthub_kwt_path=$(command -v kwt) || exit 127; "
        )
    }

    @Test("remote helper path is revision-pinned")
    func remoteHelperPathIsRevisionPinned() {
        let revision = String(repeating: "a", count: 40)

        #expect(
            KwtBinaryLocator.remoteCommandPrelude(revision: revision)
                == "ghosthub_kwt_path=\"$HOME/.ghosthub/helpers/kwt/"
                + "\(revision)/kwt\"; "
                + "[ -x \"$ghosthub_kwt_path\" ] || exit 127; "
        )
        #expect(
            KwtBinaryLocator.remoteCommandPrelude(revision: "unpinned")
                .contains("managed kwt is unavailable")
        )
    }

    @Test(
        "Windows helper paths preserve the remote architecture",
        arguments: [
            KwtBinaryLocator.WindowsArchitecture.amd64,
            KwtBinaryLocator.WindowsArchitecture.arm64,
        ]
    )
    func windowsHelperPath(
        architecture: KwtBinaryLocator.WindowsArchitecture
    ) {
        let path = KwtBinaryLocator.windowsBundledPath(
            architecture: architecture,
            bundleURL: URL(fileURLWithPath: "/Applications/Ghosthub.app")
        )

        #expect(
            path.hasSuffix(
                "/Contents/Resources/KwtRemote/windows-"
                    + "\(architecture.rawValue)/kwt"
            )
        )
    }

    @Test("Windows managed helper path is revision-pinned")
    func windowsManagedHelperPath() {
        let revision = String(repeating: "f", count: 40)

        #expect(
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: revision
            )
                == #".ghosthub\helpers\kwt\"#
                + revision
                + #"\kwt.exe"#
        )
        #expect(
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: "unpinned"
            ) == nil
        )
    }
}

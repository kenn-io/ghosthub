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
}

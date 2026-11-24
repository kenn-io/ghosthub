import Foundation
import GhosthubPersistence
import Testing
@testable import GhosthubApp

@Suite("Local host name")
struct LocalHostNameTests {
    @Test("prefers the Mac Sharing name without consulting fallbacks")
    func prefersComputerName() {
        var fallbackCalls = 0
        let resolved = LocalHostName.current(
            computerName: { "  Studio Mac  " },
            localHostName: {
                fallbackCalls += 1
                return "studio-mac"
            },
            kernelHostName: {
                fallbackCalls += 1
                return "studio-mac.local"
            }
        )

        #expect(resolved == "Studio Mac")
        #expect(fallbackCalls == 0)
    }

    @Test("falls back to local host name, kernel hostname, then This Mac")
    func fallsBackThroughSources() {
        #expect(
            LocalHostName.current(
                computerName: { "   " },
                localHostName: { "studio-mac" },
                kernelHostName: { "studio-mac.local" }
            ) == "studio-mac"
        )
        #expect(
            LocalHostName.current(
                computerName: { nil },
                localHostName: { "" },
                kernelHostName: { "studio-mac.local" }
            ) == "studio-mac.local"
        )
        #expect(
            LocalHostName.current(
                computerName: { nil },
                localHostName: { nil },
                kernelHostName: { "\n" }
            ) == "This Mac"
        )
    }

    @Test("default local host row uses LocalHostName instead of /etc/hosts aliases")
    @MainActor
    func sceneModelUsesLocalHostName() throws {
        let model = try WorkspaceSceneModel(
            database: .inMemory(),
            notificationService: NotificationServiceStub()
        )
        let localHost = try #require(
            model.snapshot.hosts.first(where: { $0.kind == .selfHost })
        )
        #expect(!localHost.name.isEmpty)
        #expect(localHost.name == LocalHostName.current())
    }
}

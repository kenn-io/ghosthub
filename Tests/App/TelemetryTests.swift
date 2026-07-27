import Foundation
import Testing
@testable import GhosthubApp

private actor TelemetryTestStateStore: TelemetryStateStoring {
    private var state: TelemetryState?

    func load() -> TelemetryState? {
        state
    }

    func save(_ state: TelemetryState) {
        self.state = state
    }
}

private actor TelemetryTestTransport: TelemetryTransport {
    private var capturedEvents: [TelemetryEvent] = []

    func capture(_ event: TelemetryEvent) {
        capturedEvents.append(event)
    }

    func events() -> [TelemetryEvent] {
        capturedEvents
    }
}

struct TelemetryTests {
    @Test("application activity is anonymous and sent once per UTC day")
    func applicationActivityIsAnonymousAndDaily() async throws {
        let stateStore = TelemetryTestStateStore()
        let transport = TelemetryTestTransport()
        let reporter = TelemetryReporter(
            configuration: TelemetryConfiguration(
                projectToken: "test-token",
                endpoint: try #require(
                    URL(string: "https://example.test/capture")
                ),
                version: "0.3.0",
                build: "42"
            ),
            stateStore: stateStore,
            transport: transport
        )
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)

        await reporter.applicationBecameActive(
            sharingEnabled: true,
            at: firstDate
        )
        await reporter.applicationBecameActive(
            sharingEnabled: true,
            at: firstDate.addingTimeInterval(60 * 60)
        )
        await reporter.applicationBecameActive(
            sharingEnabled: true,
            at: firstDate.addingTimeInterval(24 * 60 * 60)
        )

        let events = await transport.events()
        #expect(events.count == 2)
        let first = try #require(events.first)
        let second = try #require(events.last)
        #expect(first.name == "application active")
        #expect(first.distinctID == second.distinctID)
        #expect(UUID(uuidString: first.distinctID) != nil)
        #expect(!first.properties.processPersonProfile)
        #expect(first.properties.geoIPDisabled)
        #expect(first.properties.application == "ghosthub")
        #expect(first.properties.source == "native_app")
        #expect(first.properties.version == "0.3.0")
        #expect(first.properties.build == "42")
    }

    @Test("disabled sharing does not create identity or send")
    func disabledSharingDoesNotCapture() async {
        let stateStore = TelemetryTestStateStore()
        let transport = TelemetryTestTransport()
        let reporter = TelemetryReporter(
            configuration: TelemetryConfiguration(
                projectToken: "test-token",
                endpoint: URL(
                    string: "https://example.test/capture"
                )!,
                version: "test",
                build: "test"
            ),
            stateStore: stateStore,
            transport: transport
        )

        await reporter.applicationBecameActive(
            sharingEnabled: false
        )

        #expect(await transport.events().isEmpty)
        #expect(await stateStore.load() == nil)
    }

    @Test("environment kill switches disable telemetry")
    func environmentKillSwitchesDisableTelemetry() {
        #expect(
            TelemetryConfiguration.telemetryEnabled(in: [:])
        )
        #expect(
            !TelemetryConfiguration.telemetryEnabled(
                in: ["TELEMETRY_ENABLED": "0"]
            )
        )
        #expect(
            !TelemetryConfiguration.telemetryEnabled(
                in: ["GHOSTHUB_TELEMETRY_ENABLED": " 0 "]
            )
        )
    }
}

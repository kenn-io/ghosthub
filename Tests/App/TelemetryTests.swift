import Foundation
import Testing
@testable import GhosthubApp

private actor TelemetryTestStateStore: TelemetryStateStoring {
    private var state: TelemetryState?

    func claimActiveDay(_ day: String) -> UUID? {
        var state = state
            ?? TelemetryState(
                installationID: UUID(),
                lastActiveDay: nil
            )
        guard state.lastActiveDay != day else { return nil }
        state.lastActiveDay = day
        self.state = state
        return state.installationID
    }

    func currentState() -> TelemetryState? {
        state
    }
}

private actor TelemetryTestTransport: TelemetryTransport {
    enum TestError: Error {
        case rejected
    }

    private let rejectsEvents: Bool
    private var capturedEvents: [TelemetryEvent] = []

    init(rejectsEvents: Bool = false) {
        self.rejectsEvents = rejectsEvents
    }

    func capture(_ event: TelemetryEvent) throws {
        capturedEvents.append(event)
        if rejectsEvents {
            throw TestError.rejected
        }
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
        #expect(await stateStore.currentState() == nil)
    }

    @Test("a failed request is not retried on the same UTC day")
    func failedRequestIsNotRetriedOnSameDay() async {
        let stateStore = TelemetryTestStateStore()
        let transport = TelemetryTestTransport(
            rejectsEvents: true
        )
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
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        await reporter.applicationBecameActive(
            sharingEnabled: true,
            at: date
        )
        await reporter.applicationBecameActive(
            sharingEnabled: true,
            at: date.addingTimeInterval(60 * 60)
        )

        #expect(await transport.events().count == 1)
        #expect(
            await stateStore.currentState()?.lastActiveDay != nil
        )
    }

    @Test("concurrent reporters share one daily claim and identity")
    func concurrentReportersShareDailyClaim() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-telemetry-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let fileURL = directoryURL.appendingPathComponent(
            "telemetry.json"
        )
        let transport = TelemetryTestTransport()
        let configuration = TelemetryConfiguration(
            projectToken: "test-token",
            endpoint: URL(
                string: "https://example.test/capture"
            )!,
            version: "test",
            build: "test"
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    let reporter = TelemetryReporter(
                        configuration: configuration,
                        stateStore: FileTelemetryStateStore(
                            fileURL: fileURL
                        ),
                        transport: transport
                    )
                    await Task.yield()
                    await reporter.applicationBecameActive(
                        sharingEnabled: true,
                        at: date
                    )
                }
            }
        }

        let events = await transport.events()
        let event = try #require(events.first)
        let state = try JSONDecoder().decode(
            TelemetryState.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(events.count == 1)
        #expect(
            event.distinctID
                == state.installationID.uuidString.lowercased()
        )
    }

    @Test("single-event request follows PostHog's wire contract")
    func singleEventRequestFollowsPostHogContract() throws {
        let event = TelemetryEvent(
            projectToken: "test-token",
            name: TelemetryEvent.applicationActive,
            distinctID: "anonymous-installation-id",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            properties: TelemetryEvent.Properties(
                version: "test-version",
                build: "test-build"
            )
        )
        let transport = PostHogTelemetryTransport(
            endpoint: URL(
                string: "https://example.test/capture"
            )!
        )

        let request = try transport.request(for: event)
        let body = try #require(request.httpBody)
        let payload = try #require(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        let properties = try #require(
            payload["properties"] as? [String: Any]
        )

        #expect(
            payload["distinct_id"] as? String
                == "anonymous-installation-id"
        )
        #expect(properties["distinct_id"] == nil)
        #expect(
            properties["$process_person_profile"] as? Bool
                == false
        )
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

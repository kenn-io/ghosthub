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
        if let lastActiveDay = state.lastActiveDay {
            guard day > lastActiveDay else { return nil }
        }
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
    private var eventCountWaiters: [
        (minimum: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    init(rejectsEvents: Bool = false) {
        self.rejectsEvents = rejectsEvents
    }

    func capture(_ event: TelemetryEvent) throws {
        capturedEvents.append(event)
        resumeEventCountWaiters()
        if rejectsEvents {
            throw TestError.rejected
        }
    }

    func events() -> [TelemetryEvent] {
        capturedEvents
    }

    func waitUntilEventCount(_ minimum: Int) async {
        guard capturedEvents.count < minimum else { return }
        await withCheckedContinuation { continuation in
            eventCountWaiters.append((minimum, continuation))
        }
    }

    private func resumeEventCountWaiters() {
        let ready = eventCountWaiters.filter {
            capturedEvents.count >= $0.minimum
        }
        eventCountWaiters.removeAll {
            capturedEvents.count >= $0.minimum
        }
        ready.forEach { $0.continuation.resume() }
    }
}

private actor TelemetryTestSleeper {
    private var requestedDurations: [Duration] = []
    private var continuations: [
        CheckedContinuation<Void, Never>
    ] = []
    private var pendingCountWaiters: [
        (minimum: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func sleep(for duration: Duration) async {
        requestedDurations.append(duration)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            resumePendingCountWaiters()
        }
    }

    func pendingCount() -> Int {
        continuations.count
    }

    func durations() -> [Duration] {
        requestedDurations
    }

    func waitUntilPendingCount(_ minimum: Int) async {
        guard continuations.count < minimum else { return }
        await withCheckedContinuation { continuation in
            pendingCountWaiters.append((minimum, continuation))
        }
    }

    func resumeNext() {
        continuations.removeFirst().resume()
    }

    private func resumePendingCountWaiters() {
        let ready = pendingCountWaiters.filter {
            continuations.count >= $0.minimum
        }
        pendingCountWaiters.removeAll {
            continuations.count >= $0.minimum
        }
        ready.forEach { $0.continuation.resume() }
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

    @Test("daily claims never move backward")
    func dailyClaimsNeverMoveBackward() async throws {
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
        let store = FileTelemetryStateStore(fileURL: fileURL)

        let firstClaim = try await store.claimActiveDay(
            "2027-01-02"
        )
        let staleClaim = try await store.claimActiveDay(
            "2027-01-01"
        )
        let repeatedClaim = try await store.claimActiveDay(
            "2027-01-02"
        )

        #expect(firstClaim != nil)
        #expect(staleClaim == nil)
        #expect(repeatedClaim == nil)
    }

    @MainActor
    @Test("an active app reports again after UTC midnight")
    func activeAppReportsAfterUTCMidnight() async {
        let dayStart = floor(1_800_000_000 / 86_400) * 86_400
        var date = Date(
            timeIntervalSince1970: dayStart + 86_390
        )
        let stateStore = TelemetryTestStateStore()
        let transport = TelemetryTestTransport()
        let sleeper = TelemetryTestSleeper()
        var preferenceReads = 0
        let controller = TelemetryController(
            configuration: TelemetryConfiguration(
                projectToken: "test-token",
                endpoint: URL(
                    string: "https://example.test/capture"
                )!,
                version: "test",
                build: "test"
            ),
            stateStore: stateStore,
            transport: transport,
            sharingEnabled: {
                preferenceReads += 1
                return true
            },
            currentDate: {
                date
            },
            sleep: {
                await sleeper.sleep(for: $0)
            }
        )

        controller.applicationDidBecomeActive()
        await transport.waitUntilEventCount(1)
        await sleeper.waitUntilPendingCount(1)

        date = date.addingTimeInterval(20)
        await sleeper.resumeNext()
        await transport.waitUntilEventCount(2)
        await sleeper.waitUntilPendingCount(1)

        #expect(
            await sleeper.durations().first == .seconds(10)
        )
        #expect(preferenceReads == 2)

        controller.applicationWillResignActive()
        await sleeper.resumeNext()
    }

    @MainActor
    @Test("resigning active cancels the UTC rollover check")
    func resigningActiveCancelsRollover() async {
        let dayStart = floor(1_800_000_000 / 86_400) * 86_400
        var date = Date(
            timeIntervalSince1970: dayStart + 86_390
        )
        let stateStore = TelemetryTestStateStore()
        let transport = TelemetryTestTransport()
        let sleeper = TelemetryTestSleeper()
        var preferenceReads = 0
        let controller = TelemetryController(
            configuration: TelemetryConfiguration(
                projectToken: "test-token",
                endpoint: URL(
                    string: "https://example.test/capture"
                )!,
                version: "test",
                build: "test"
            ),
            stateStore: stateStore,
            transport: transport,
            sharingEnabled: {
                preferenceReads += 1
                return true
            },
            currentDate: {
                date
            },
            sleep: {
                await sleeper.sleep(for: $0)
            }
        )

        controller.applicationDidBecomeActive()
        await transport.waitUntilEventCount(1)
        await sleeper.waitUntilPendingCount(1)

        controller.applicationWillResignActive()
        date = date.addingTimeInterval(20)
        await sleeper.resumeNext()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(await transport.events().count == 1)
        #expect(preferenceReads == 1)
        #expect(await sleeper.pendingCount() == 0)
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

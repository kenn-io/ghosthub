import Darwin
import Foundation
import GhosthubSettings
import GhosthubWorkspace

struct TelemetryConfiguration: Sendable {
    static let postHogProjectToken =
        "phc_yqmReEse7NkCc4jceHfwFATb6VyryfB6aEnKuxan5fqv"
    static let postHogEndpoint = URL(
        string: "https://us.i.posthog.com/i/v0/e/"
    )!

    let projectToken: String
    let endpoint: URL
    let version: String
    let build: String

    static func live(
        bundle: Bundle = .main,
        environment: [String: String] =
            ProcessInfo.processInfo.environment
    ) -> TelemetryConfiguration? {
        guard bundle.bundleIdentifier == "com.ghosthub",
              telemetryEnabled(in: environment)
        else {
            return nil
        }

        return TelemetryConfiguration(
            projectToken: postHogProjectToken,
            endpoint: postHogEndpoint,
            version: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            build: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown"
        )
    }

    static func telemetryEnabled(
        in environment: [String: String]
    ) -> Bool {
        environment["TELEMETRY_ENABLED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) != "0"
            && environment["GHOSTHUB_TELEMETRY_ENABLED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }
}

struct TelemetryState: Codable, Equatable, Sendable {
    var installationID: UUID
    var lastActiveDay: String?
}

protocol TelemetryStateStoring: Sendable {
    func claimActiveDay(_ day: String) async throws -> UUID?
}

struct FileTelemetryStateStore: TelemetryStateStoring {
    private static let processLock = NSLock()

    let fileURL: URL

    init(
        fileURL: URL = StateHome.resolved()
            .appendingPathComponent("telemetry.json")
    ) {
        self.fileURL = fileURL
    }

    func claimActiveDay(_ day: String) async throws -> UUID? {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try withExclusiveLock {
            var state = try load()
                ?? TelemetryState(
                    installationID: UUID(),
                    lastActiveDay: nil
                )
            if let lastActiveDay = state.lastActiveDay {
                guard day > lastActiveDay else { return nil }
            }

            state.lastActiveDay = day
            try save(state)
            return state.installationID
        }
    }

    private func withExclusiveLock<T>(
        _ operation: () throws -> T
    ) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw Self.currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }

        var lock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        while Darwin.fcntl(descriptor, F_SETLKW, &lock) != 0 {
            guard errno == EINTR else {
                throw Self.currentPOSIXError()
            }
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        }

        return try operation()
    }

    private func load() throws -> TelemetryState? {
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(
            TelemetryState.self,
            from: data
        )
    }

    private func save(_ state: TelemetryState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct TelemetryEvent: Equatable, Sendable {
    static let applicationActive = "application active"

    struct Properties: Equatable, Sendable {
        let processPersonProfile = false
        let geoIPDisabled = true
        let application = "ghosthub"
        let source = "native_app"
        let version: String
        let build: String
    }

    let projectToken: String
    let name: String
    let distinctID: String
    let timestamp: Date
    let properties: Properties
}

protocol TelemetryTransport: Sendable {
    func capture(_ event: TelemetryEvent) async throws
}

struct PostHogTelemetryTransport: TelemetryTransport {
    enum TransportError: Error {
        case invalidResponse
        case rejected(statusCode: Int)
    }

    let endpoint: URL

    func capture(_ event: TelemetryEvent) async throws {
        let request = try request(for: event)

        let (_, response) = try await URLSession.shared.data(
            for: request
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransportError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw TransportError.rejected(
                statusCode: httpResponse.statusCode
            )
        }
    }

    func request(for event: TelemetryEvent) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(
            PostHogPayload(event: event)
        )
        return request
    }
}

private struct PostHogPayload: Encodable {
    struct Properties: Encodable {
        let processPersonProfile: Bool
        let geoIPDisabled: Bool
        let application: String
        let source: String
        let version: String
        let build: String

        enum CodingKeys: String, CodingKey {
            case processPersonProfile = "$process_person_profile"
            case geoIPDisabled = "$geoip_disable"
            case application
            case source
            case version
            case build
        }
    }

    let projectToken: String
    let event: String
    let distinctID: String
    let timestamp: Date
    let properties: Properties

    init(event: TelemetryEvent) {
        projectToken = event.projectToken
        self.event = event.name
        distinctID = event.distinctID
        timestamp = event.timestamp
        properties = Properties(
            processPersonProfile:
            event.properties.processPersonProfile,
            geoIPDisabled: event.properties.geoIPDisabled,
            application: event.properties.application,
            source: event.properties.source,
            version: event.properties.version,
            build: event.properties.build
        )
    }

    enum CodingKeys: String, CodingKey {
        case projectToken = "api_key"
        case event
        // PostHog's /i/v0/e single-event contract requires distinct_id
        // at the top level. The properties placement is a /batch option.
        case distinctID = "distinct_id"
        case timestamp
        case properties
    }
}

actor TelemetryReporter {
    private let configuration: TelemetryConfiguration
    private let stateStore: any TelemetryStateStoring
    private let transport: any TelemetryTransport

    init(
        configuration: TelemetryConfiguration,
        stateStore: any TelemetryStateStoring =
            FileTelemetryStateStore(),
        transport: (any TelemetryTransport)? = nil
    ) {
        self.configuration = configuration
        self.stateStore = stateStore
        self.transport = transport
            ?? PostHogTelemetryTransport(
                endpoint: configuration.endpoint
            )
    }

    func applicationBecameActive(
        sharingEnabled: Bool,
        at date: Date = Date()
    ) async {
        guard sharingEnabled else { return }

        do {
            let day = Self.utcDay(containing: date)
            guard let installationID =
                try await stateStore.claimActiveDay(day)
            else {
                return
            }

            try await transport.capture(
                TelemetryEvent(
                    projectToken: configuration.projectToken,
                    name: TelemetryEvent.applicationActive,
                    distinctID:
                    installationID.uuidString.lowercased(),
                    timestamp: date,
                    properties: TelemetryEvent.Properties(
                        version: configuration.version,
                        build: configuration.build
                    )
                )
            )
        } catch {
            AppLogger.shared.debug(
                "anonymous usage event was not sent: \(error)",
                context: "telemetry"
            )
        }
    }

    private static func utcDay(containing date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

@MainActor
final class TelemetryController {
    static let shared = TelemetryController()

    private let reporter: TelemetryReporter?
    private let sharingEnabled: @MainActor () -> Bool
    private let currentDate: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var rolloverTask: Task<Void, Never>?

    init(
        configuration: TelemetryConfiguration? = .live(),
        stateStore: (any TelemetryStateStoring)? = nil,
        transport: (any TelemetryTransport)? = nil,
        sharingEnabled: @escaping @MainActor () -> Bool = {
            SettingsStore.shared.refreshShareAnonymousUsageData()
        },
        currentDate: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        if let configuration {
            reporter = TelemetryReporter(
                configuration: configuration,
                stateStore: stateStore ?? FileTelemetryStateStore(),
                transport: transport
            )
        } else {
            reporter = nil
        }
        self.sharingEnabled = sharingEnabled
        self.currentDate = currentDate
        self.sleep = sleep
    }

    func applicationDidBecomeActive() {
        guard let reporter else { return }
        rolloverTask?.cancel()

        let date = currentDate()
        capture(with: reporter, at: date)
        scheduleRollover(after: date, reporter: reporter)
    }

    func applicationWillResignActive() {
        rolloverTask?.cancel()
        rolloverTask = nil
    }

    private func capture(
        with reporter: TelemetryReporter,
        at date: Date
    ) {
        let sharingEnabled = sharingEnabled
        Task(priority: .utility) {
            let enabled = sharingEnabled()
            await reporter.applicationBecameActive(
                sharingEnabled: enabled,
                at: date
            )
        }
    }

    private func scheduleRollover(
        after date: Date,
        reporter: TelemetryReporter
    ) {
        let boundary = Self.nextUTCBoundary(after: date)
        let delay = Duration.seconds(
            max(0, boundary.timeIntervalSince(date))
        )
        let sleep = sleep
        rolloverTask = Task(priority: .utility) { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }

            let currentDate = currentDate()
            capture(with: reporter, at: currentDate)
            scheduleRollover(
                after: currentDate,
                reporter: reporter
            )
        }
    }

    private static func nextUTCBoundary(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(
            byAdding: .day,
            value: 1,
            to: startOfDay
        ) ?? date.addingTimeInterval(24 * 60 * 60)
    }
}

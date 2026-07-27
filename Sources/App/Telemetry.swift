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
    func load() async throws -> TelemetryState?
    func save(_ state: TelemetryState) async throws
}

struct FileTelemetryStateStore: TelemetryStateStoring {
    let fileURL: URL

    init(
        fileURL: URL = StateHome.resolved()
            .appendingPathComponent("telemetry.json")
    ) {
        self.fileURL = fileURL
    }

    func load() async throws -> TelemetryState? {
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

    func save(_ state: TelemetryState) async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
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
            var state = try await stateStore.load()
                ?? TelemetryState(
                    installationID: UUID(),
                    lastActiveDay: nil
                )
            let day = Self.utcDay(containing: date)
            guard state.lastActiveDay != day else { return }

            if state.lastActiveDay == nil {
                try await stateStore.save(state)
            }

            try await transport.capture(
                TelemetryEvent(
                    projectToken: configuration.projectToken,
                    name: TelemetryEvent.applicationActive,
                    distinctID:
                    state.installationID.uuidString.lowercased(),
                    timestamp: date,
                    properties: TelemetryEvent.Properties(
                        version: configuration.version,
                        build: configuration.build
                    )
                )
            )

            state.lastActiveDay = day
            try await stateStore.save(state)
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

    init(
        configuration: TelemetryConfiguration? = .live()
    ) {
        if let configuration {
            reporter = TelemetryReporter(
                configuration: configuration
            )
        } else {
            reporter = nil
        }
    }

    func applicationBecameActive() {
        guard let reporter else { return }
        let sharingEnabled =
            SettingsStore.shared.shareAnonymousUsageData
        Task(priority: .utility) {
            await reporter.applicationBecameActive(
                sharingEnabled: sharingEnabled
            )
        }
    }
}

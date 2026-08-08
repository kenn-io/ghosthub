import GhosthubWorkspace
import Testing
@testable import GhosthubHerdr

@Suite("Herdr pane split capability")
struct HerdrPaneSplitCapabilityTests {
    @Test("semantic versions gate pane splitting", arguments: [
        ("herdr 0.7.9", false),
        ("herdr 0.8.0", true),
        ("herdr 0.8.1", true),
        ("herdr 1.0.0", true),
    ])
    func versionGate(output: String, supported: Bool) throws {
        let version = try #require(HerdrVersion(output: output))

        #expect((version >= .paneSplitting) == supported)
    }

    @Test("banner-framed output binds the exact running session socket")
    func runningSession() {
        let result = HerdrPaneSplitCapabilityProbe.parse(
            status: 0,
            stdout: """
            Welcome to the host
            GHOSTHUB_HERDR_VERSION
            herdr 0.8.0
            GHOSTHUB_HERDR_JSON
            {"sessions":[
              {"name":"other","default":false,"running":true,"session_dir":"/tmp/other","socket_path":"/tmp/other/herdr.sock"},
              {"name":"api","default":false,"running":true,"session_dir":"/tmp/api","socket_path":"/tmp/api/herdr.sock"}
            ]}
            """,
            stderr: "",
            sessionName: "api"
        )

        #expect(result == .success(HerdrPaneSplitCapability(
            version: HerdrVersion(major: 0, minor: 8, patch: 0),
            session: HerdrSessionRecord(
                name: "api",
                isDefault: false,
                state: .running,
                sessionDirectory: "/tmp/api",
                socketPath: "/tmp/api/herdr.sock"
            )
        )))
    }

    @Test("old versions and non-running records do not grant capability")
    func incapableRecords() {
        let inventory = """
        GHOSTHUB_HERDR_JSON
        {"sessions":[{"name":"api","default":false,"running":false,"session_dir":"/tmp/api","socket_path":"/tmp/api/herdr.sock"}]}
        """

        #expect(HerdrPaneSplitCapabilityProbe.parse(
            status: 0,
            stdout: "GHOSTHUB_HERDR_VERSION\nherdr 0.8.0\n" + inventory,
            stderr: "",
            sessionName: "api"
        ) == .success(nil))
        #expect(HerdrPaneSplitCapabilityProbe.parse(
            status: 0,
            stdout: "GHOSTHUB_HERDR_VERSION\nherdr 0.7.9\n"
                + inventory.replacingOccurrences(
                    of: "\"running\":false",
                    with: "\"running\":true"
                ),
            stderr: "",
            sessionName: "api"
        ) == .success(nil))
    }

    @Test("missing or malformed version framing is rejected")
    func malformedVersion() {
        let inventory = """
        GHOSTHUB_HERDR_JSON
        {"sessions":[]}
        """

        #expect(HerdrPaneSplitCapabilityProbe.parse(
            status: 0,
            stdout: inventory,
            stderr: "",
            sessionName: "api"
        ) == .failure(.missingMarker))
        #expect(HerdrPaneSplitCapabilityProbe.parse(
            status: 0,
            stdout: "GHOSTHUB_HERDR_VERSION\nnot-a-version\n" + inventory,
            stderr: "",
            sessionName: "api"
        ) == .failure(.malformedVersion))
    }

    @Test("probe uses the resolved executable for version and inventory")
    func command() {
        let command = HerdrPaneSplitCapabilityProbe.command(
            herdrPath: "/opt/Herdr Tools/herdr"
        )

        #expect(command.contains(HerdrPaneSplitCapabilityProbe.versionMarker))
        #expect(command.contains(HerdrSessionList.marker))
        #expect(command.contains("'/opt/Herdr Tools/herdr' '--version'"))
        #expect(command.contains(
            "'/opt/Herdr Tools/herdr' 'session' 'list' '--json'"
        ))
    }
}

import Foundation
import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Herdr session lifecycle client")
struct HerdrSessionLifecycleClientTests {
    @Test("stop revalidates the exact record before mutating")
    func stopRevalidates() {
        let recorder = LifecycleCommandRecorder(outputs: [
            executableOutput(),
            listOutput(running: true),
            lifecycleOutput(stopped: true),
        ])
        let client = HerdrSessionLifecycleClient(
            commandRunner: recorder.runner,
            connectionArgumentsProvider: { _ in [] }
        )
        let confirmed = record(state: .running)

        #expect(client.stop(confirmed, on: .local)
            == .success(record(state: .stopped)))
        #expect(recorder.commands.count == 3)
        #expect(recorder.commands[1].contains("'session' 'list' '--json'"))
        #expect(recorder.commands[2].contains("'session' 'stop' 'review' '--json'"))
    }

    @Test("changed state or location prevents mutation")
    func revalidationFailures() {
        let stateRecorder = LifecycleCommandRecorder(outputs: [
            executableOutput(),
            listOutput(running: false),
        ])
        let stateClient = HerdrSessionLifecycleClient(
            commandRunner: stateRecorder.runner,
            connectionArgumentsProvider: { _ in [] }
        )
        #expect(stateClient.stop(record(state: .running), on: .local)
            == .failure(.stateChanged(name: "review", expected: .running)))
        #expect(stateRecorder.commands.count == 2)

        let locationRecorder = LifecycleCommandRecorder(outputs: [
            executableOutput(),
            listOutput(running: true, directory: "/moved/review"),
        ])
        let locationClient = HerdrSessionLifecycleClient(
            commandRunner: locationRecorder.runner,
            connectionArgumentsProvider: { _ in [] }
        )
        #expect(locationClient.stop(record(state: .running), on: .local)
            == .failure(.locationChanged("review")))
        #expect(locationRecorder.commands.count == 2)
    }

    @Test("default deletion and Windows hosts are rejected without a process")
    func exclusions() {
        let recorder = LifecycleCommandRecorder(outputs: [])
        let client = HerdrSessionLifecycleClient(
            commandRunner: recorder.runner,
            connectionArgumentsProvider: { _ in [] }
        )
        var defaultRecord = record(state: .stopped)
        defaultRecord = HerdrSessionRecord(
            name: "default",
            isDefault: true,
            state: .stopped,
            sessionDirectory: "/tmp/herdr",
            socketPath: "/tmp/herdr/herdr.sock"
        )
        #expect(client.delete(defaultRecord, on: .local)
            == .failure(.defaultSessionCannotBeDeleted))
        #expect(client.record(
            named: "review",
            on: .ssh(SSHHostInfo(
                user: nil,
                hostname: "windows",
                port: nil,
                platform: .windows
            ))
        ) == .failure(.unsupportedPlatform))
        #expect(recorder.commands.isEmpty)
    }

    @Test("remote lookup uses the injected SSH route")
    func remoteLookup() {
        let recorder = LifecycleCommandRecorder(outputs: [
            executableOutput(),
            listOutput(running: true),
        ])
        let host = SSHHostInfo(
            user: "dev",
            hostname: "build.example",
            port: 2222
        )
        let client = HerdrSessionLifecycleClient(
            commandRunner: recorder.runner,
            connectionArgumentsProvider: { supplied in
                #expect(supplied == host)
                return ["-F", "/tmp/ghosthub ssh config"]
            }
        )

        #expect(client.record(named: "review", on: .ssh(host))
            == .success(record(state: .running)))
        #expect(recorder.commands.allSatisfy { command in
            command.contains("/usr/bin/ssh")
                && command.contains("/tmp/ghosthub ssh config")
        })
    }

    private func record(state: HerdrSessionState) -> HerdrSessionRecord {
        HerdrSessionRecord(
            name: "review",
            isDefault: false,
            state: state,
            sessionDirectory: "/tmp/review",
            socketPath: "/tmp/review/herdr.sock"
        )
    }
}

private final class LifecycleCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [AccountCommandOutput]
    private(set) var commands: [String] = []

    init(outputs: [AccountCommandOutput]) {
        self.outputs = outputs
    }

    var runner: AccountCommandRunner {
        AccountCommandRunner(
            processRunner: { [self] _, arguments, _, _ in
                lock.withLock {
                    commands.append(arguments.last ?? "")
                    return outputs.removeFirst()
                }
            },
            loginShellProvider: { "/bin/account-shell" }
        )
    }
}

private func executableOutput() -> AccountCommandOutput {
    AccountCommandOutput(
        status: 0,
        stdout: "GHOSTHUB_HERDR_PATH\n/opt/homebrew/bin/herdr\n",
        stderr: ""
    )
}

private func listOutput(
    running: Bool,
    directory: String = "/tmp/review"
) -> AccountCommandOutput {
    AccountCommandOutput(
        status: 0,
        stdout: """
        GHOSTHUB_HERDR_JSON
        {"sessions":[{"name":"review","default":false,"running":\(running),"session_dir":"\(
            directory
        )","socket_path":"/tmp/review/herdr.sock"}]}
        """,
        stderr: ""
    )
}

private func lifecycleOutput(stopped: Bool) -> AccountCommandOutput {
    AccountCommandOutput(
        status: 0,
        stdout: """
        GHOSTHUB_HERDR_SESSION_JSON
        {"session":{"name":"review","default":false,"running":false,"session_dir":"/tmp/review","socket_path":"/tmp/review/herdr.sock"},"stopped":\(
            stopped
        )}
        """,
        stderr: ""
    )
}

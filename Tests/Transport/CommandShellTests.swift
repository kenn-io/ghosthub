import Foundation
import Testing
@testable import GhosthubTransport

@Suite("Command shell transport")
struct CommandShellTests {
    @Test("single quotes survive POSIX argument quoting")
    func quotesSingleQuotes() {
        #expect(shellQuotedCommandArgument("a'b") == "'a'\\''b'")
    }

    @Test("account shell wrapping protects command substitutions")
    func accountShellWrapping() {
        let command = accountLoginShellCommand(
            "printf '%s' \"$PATH\"; printf '`literal`'"
        )

        #expect(command.hasPrefix("exec /bin/sh -c "))
        #expect(command.contains("\\$PATH"))
        #expect(command.contains("'`'"))
    }

    @Test("account login commands find package-manager tools missing from login PATH")
    func loginPathFallbackFindsTool() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let nixTool = try installProbe(in: home, at: ".nix-profile/bin")

        let output = try runAccountLogin(
            "command -v ghosthub-path-probe",
            home: home,
            loginPath: "/usr/bin:/bin"
        )

        #expect(output == nixTool.path)
    }

    @Test("account login PATH entries win over package-manager fallbacks")
    func loginPathFallbackKeepsAccountOrder() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try installProbe(in: home, at: ".nix-profile/bin")
        let profileTool = try installProbe(in: home, at: "profile-bin")

        let output = try runAccountLogin(
            "command -v ghosthub-path-probe",
            home: home,
            loginPath: home.appendingPathComponent("profile-bin").path
                + ":/usr/bin:/bin"
        )

        #expect(output == profileTool.path)
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true
        )
        return home.resolvingSymlinksInPath()
    }

    @discardableResult
    private func installExecutable(at url: URL, contents: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    private func installProbe(in home: URL, at directory: String) throws -> URL {
        try installExecutable(
            at: home.appendingPathComponent(directory)
                .appendingPathComponent("ghosthub-path-probe"),
            contents: "#!/bin/sh\n"
        )
    }

    /// Runs the wrapper the way SSH runs a remote command. The account shell
    /// stands in for a login shell whose startup files set exactly
    /// `loginPath`, so the test host's own startup files cannot change it.
    private func runAccountLogin(
        _ command: String,
        home: URL,
        loginPath: String
    ) throws -> String {
        let shell = try installExecutable(
            at: home.appendingPathComponent("account-shell"),
            contents: """
            #!/bin/sh
            [ "$1" = -lc ] || exit 64
            PATH=\(shellQuotedCommandArgument(loginPath)); export PATH
            exec /bin/sh -c "$2"

            """
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", accountLoginShellCommand(command)]
        process.environment = [
            "HOME": home.path,
            "SHELL": shell.path,
            "PATH": "/usr/bin:/bin",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("PowerShell arguments round-trip as UTF-8")
    func powerShellArgumentEncoding() throws {
        let value = "C:\\code\\review 'alpha'"
        let expression = powerShellEncodedArgument(value)
        let marker = "FromBase64String('"
        let encoded = try #require(
            expression.components(separatedBy: marker).last?
                .components(separatedBy: "'").first
        )
        let data = try #require(Data(base64Encoded: encoded))
        #expect(String(data: data, encoding: .utf8) == value)
    }

    @Test("PowerShell commands use UTF-16LE encoded command input")
    func powerShellCommandEncoding() throws {
        let source = "Write-Output 'hello'"
        let command = powerShellEncodedCommand(source)
        let encoded = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        #expect(String(data: data, encoding: .utf16LittleEndian) == source)
    }
}

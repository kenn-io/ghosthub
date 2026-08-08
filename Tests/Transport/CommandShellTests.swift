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

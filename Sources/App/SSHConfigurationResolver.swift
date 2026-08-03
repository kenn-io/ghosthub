import Foundation
import GhosthubTmux

struct EffectiveSSHConfiguration: Equatable {
    let user: String?
    let strictHostKeyChecking: String?
}

enum SSHConfigurationResolver {
    static func configuration(
        for host: SSHHostInfo
    ) -> EffectiveSSHConfiguration? {
        var arguments = ["-G"]
        arguments.append(contentsOf: tmuxSSHConnectionArguments())
        if let port = host.port, port != 22 {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        let target = host.user.map { "\($0)@\(host.hostname)" }
            ?? host.hostname
        arguments.append(contentsOf: ["--", target])
        let result = TmuxBinaryResolver.runProcessInLoginShell(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            timeout: 5,
            accountShell: TmuxBinaryResolver.loginShell()
        )
        guard result.status == 0 else { return nil }
        return parse(result.stdout)
    }

    static func parse(_ output: String) -> EffectiveSSHConfiguration {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(
                maxSplits: 1,
                whereSeparator: \Character.isWhitespace
            )
            guard fields.count == 2 else { continue }
            values[String(fields[0]).lowercased()] = String(fields[1])
        }
        return EffectiveSSHConfiguration(
            user: values["user"],
            strictHostKeyChecking: values["stricthostkeychecking"]?
                .lowercased()
        )
    }
}

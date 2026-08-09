import Foundation

public func demoSSHIsolationArguments(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    // The screenshot app is ad-hoc signed and runs against guarded scratch
    // state. Keep its SSH isolation explicit without changing normal clients.
    guard let scratch = environment["GHOSTHUB_DEMO_SCRATCH"],
          let directory = environment["GHOSTHUB_DEMO_SSH_DIR"],
          scratch.hasPrefix("/"), directory == "\(scratch)/ssh"
    else { return [] }

    return [
        "-F", "\(directory)/config",
        "-o", "UserKnownHostsFile=\(directory)/known_hosts",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ProxyCommand=none",
        "-o", "ProxyJump=none",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
    ]
}

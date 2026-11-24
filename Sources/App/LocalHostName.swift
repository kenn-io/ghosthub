import Darwin
import Foundation
import SystemConfiguration

/// Resolves the local Mac's display name without consulting `/etc/hosts` or DNS.
///
/// `ProcessInfo.processInfo.hostName` delegates to `Host.current().name`, which
/// gathers local interface and loopback aliases from `/etc/hosts` in an unordered
/// set. A loopback entry such as `127.0.0.2 some-vm.example` can then replace the
/// Mac's own name in the sidebar.
enum LocalHostName {
    static let fallback = "This Mac"

    static func current(
        computerName: () -> String? = systemComputerName,
        localHostName: () -> String? = systemLocalHostName,
        kernelHostName: () -> String? = systemKernelHostName
    ) -> String {
        if let name = normalized(computerName()) {
            return name
        }
        if let name = normalized(localHostName()) {
            return name
        }
        if let name = normalized(kernelHostName()) {
            return name
        }
        return fallback
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func systemComputerName() -> String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    private static func systemLocalHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }

    private static func systemKernelHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else {
            return nil
        }
        buffer[buffer.count - 1] = 0
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

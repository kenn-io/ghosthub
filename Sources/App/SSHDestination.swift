import GhosthubTransport

enum SSHDestination {
    static func render(_ host: SSHHostInfo) -> String {
        let hostname = host.hostname.contains(":")
            ? "[\(host.hostname)]"
            : host.hostname
        let destination = host.user.map { "\($0)@\(hostname)" } ?? hostname
        guard let port = host.port else { return destination }
        return "\(destination):\(port)"
    }

    static func demoRouteIdentity(_ host: SSHHostInfo) -> String {
        "demo:\(render(host))"
    }
}

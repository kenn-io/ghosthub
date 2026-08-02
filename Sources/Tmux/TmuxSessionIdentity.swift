public struct TmuxSessionIdentity: Equatable, Sendable {
    public let serverPID: String
    public let sessionID: String
    public let createdAt: String

    public init(
        serverPID: String,
        sessionID: String,
        createdAt: String
    ) {
        self.serverPID = serverPID
        self.sessionID = sessionID
        self.createdAt = createdAt
    }

    package var formatCondition: String {
        "#{&&:#{==:#{pid},\(serverPID)},"
            + "#{&&:#{==:#{session_id},\(sessionID)},"
            + "#{==:#{session_created},\(createdAt)}}}"
    }
}

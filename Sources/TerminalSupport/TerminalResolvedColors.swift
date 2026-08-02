public struct TerminalResolvedColors: Equatable, Sendable {
    public let foreground: String
    public let background: String

    public init(foreground: String, background: String) {
        self.foreground = foreground
        self.background = background
    }
}

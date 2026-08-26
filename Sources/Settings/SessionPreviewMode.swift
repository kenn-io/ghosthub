public enum SessionPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case efficient
    case live
    case alwaysLive = "always-live"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .off:
            "Off"
        case .efficient:
            "Efficient"
        case .live:
            "Live"
        case .alwaysLive:
            "Always Live"
        }
    }

    public var usesLiveRefresh: Bool {
        self == .live || self == .alwaysLive
    }

    public var expandsEverySession: Bool {
        self == .alwaysLive
    }
}

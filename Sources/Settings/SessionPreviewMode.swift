public enum SessionPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case efficient
    case live

    public var id: Self { self }

    public var title: String {
        switch self {
        case .off:
            "Off"
        case .efficient:
            "Efficient"
        case .live:
            "Live"
        }
    }
}

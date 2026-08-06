enum RendererStage: String, Equatable, Sendable {
    case idle
    case libraryReady = "library ready"
    case configReady = "config ready"
    case appReady = "app ready"
    case surfaceReady = "surface ready"
    case rendered
}

enum RendererStatus: Equatable, Sendable {
    case idle
    case libraryReady
    case configReady
    case appReady
    case surfaceReady
    case rendered
    case failed(stage: RendererStage, message: String)

    var title: String {
        switch self {
        case .idle:
            "Idle"
        case .libraryReady:
            "Library ready"
        case .configReady:
            "Configuration ready"
        case .appReady:
            "Application ready"
        case .surfaceReady:
            "Surface ready"
        case .rendered:
            "Rendered"
        case let .failed(stage, _):
            "Failed at \(stage.rawValue)"
        }
    }

    var failureMessage: String? {
        guard case let .failed(_, message) = self else { return nil }
        return message
    }

    var isFailure: Bool {
        failureMessage != nil
    }
}

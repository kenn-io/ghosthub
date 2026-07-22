import Combine
import Foundation

public enum GhosttyRuntimeActionEvent: Equatable, Sendable {
    case quit
    case openConfig
    case reloadConfig(soft: Bool)
    case ringBell
    case setTitle(String)
    case workingDirectory(String)
    case newSplit(GhosttySplitDirection)
    case gotoSplit(GhosttySplitDirection)
    case resizeSplit(GhosttySplitDirection, UInt16)
    case equalizeSplits
    case toggleSplitZoom
    case render
    case childExited(exitCode: UInt32, runtimeMS: UInt64)
    case unhandled(rawTag: Int32)
}

public struct GhosttyRuntimeSplitAction: Equatable, Sendable {
    public let action: GhosttyRuntimeActionEvent
    public let sourceSurfaceIdentity: UInt?

    public init(
        action: GhosttyRuntimeActionEvent,
        sourceSurfaceIdentity: UInt? = nil
    ) {
        self.action = action
        self.sourceSurfaceIdentity = sourceSurfaceIdentity
    }
}

public enum GhosttySplitDirection: String, Equatable, Sendable {
    case right
    case left
    case up
    case down
    case unknown
}

public struct GhosttySurfaceCloseEvent: Equatable, Sendable {
    public var processAlive: Bool

    public init(processAlive: Bool) {
        self.processAlive = processAlive
    }
}

public enum GhosttyClipboardLocation: Equatable, Sendable {
    case standard
    case selection
    case unknown(Int32)
}

public final class GhosttySurfaceRuntimeCallbacks {
    public typealias ReadClipboardHandler = (GhosttyClipboardLocation, UnsafeMutableRawPointer?)
        -> Void
    public typealias ConfirmReadClipboardHandler = (String, UnsafeMutableRawPointer?, Int32) -> Void
    public typealias WriteClipboardHandler = (String, GhosttyClipboardLocation, Bool) -> Void
    public typealias CloseSurfaceHandler = (Bool) -> Void

    public var readClipboard: ReadClipboardHandler?
    public var confirmReadClipboard: ConfirmReadClipboardHandler?
    public var writeClipboard: WriteClipboardHandler?
    public var closeSurface: CloseSurfaceHandler?

    public init(
        readClipboard: ReadClipboardHandler? = nil,
        confirmReadClipboard: ConfirmReadClipboardHandler? = nil,
        writeClipboard: WriteClipboardHandler? = nil,
        closeSurface: CloseSurfaceHandler? = nil
    ) {
        self.readClipboard = readClipboard
        self.confirmReadClipboard = confirmReadClipboard
        self.writeClipboard = writeClipboard
        self.closeSurface = closeSurface
    }
}

@MainActor
public final class GhosttyRuntimeState: ObservableObject {
    public private(set) var wakeupCount = 0
    @Published public private(set) var lastAction: GhosttyRuntimeActionEvent?
    @Published public private(set) var closeEvents: [GhosttySurfaceCloseEvent] = []

    public let splitActionSubject = PassthroughSubject<GhosttyRuntimeSplitAction, Never>()
    public let childExitSubject = PassthroughSubject<GhosttyRuntimeActionEvent, Never>()

    public init() {}

    public func recordWakeup() {
        wakeupCount += 1
    }

    public func recordAction(
        _ action: GhosttyRuntimeActionEvent,
        sourceSurfaceIdentity: UInt? = nil
    ) {
        lastAction = action
        switch action {
        case .newSplit, .gotoSplit, .resizeSplit, .equalizeSplits,
             .toggleSplitZoom:
            splitActionSubject.send(
                GhosttyRuntimeSplitAction(
                    action: action,
                    sourceSurfaceIdentity: sourceSurfaceIdentity
                )
            )
        case .childExited:
            childExitSubject.send(action)
        default:
            break
        }
    }

    public func recordClose(processAlive: Bool) {
        closeEvents.append(GhosttySurfaceCloseEvent(processAlive: processAlive))
    }
}

import Combine
import Foundation

public enum LibghosttyRuntimeActionEvent: Equatable, Sendable {
    case quit
    case openConfig
    case reloadConfig(soft: Bool)
    case ringBell
    case setTitle(String)
    case workingDirectory(String)
    case newSplit(LibghosttySplitDirection)
    case gotoSplit(LibghosttySplitDirection)
    case resizeSplit(LibghosttySplitDirection, UInt16)
    case equalizeSplits
    case toggleSplitZoom
    case render
    case childExited(exitCode: UInt32, runtimeMS: UInt64)
    case unhandled(rawTag: Int32)
}

public struct LibghosttyRuntimeSplitAction: Equatable, Sendable {
    public let action: LibghosttyRuntimeActionEvent
    public let sourceSurfaceIdentity: UInt?

    public init(
        action: LibghosttyRuntimeActionEvent,
        sourceSurfaceIdentity: UInt? = nil
    ) {
        self.action = action
        self.sourceSurfaceIdentity = sourceSurfaceIdentity
    }
}

public enum LibghosttySplitDirection: String, Equatable, Sendable {
    case right
    case left
    case up
    case down
    case unknown
}

public struct LibghosttySurfaceCloseEvent: Equatable, Sendable {
    public var processAlive: Bool

    public init(processAlive: Bool) {
        self.processAlive = processAlive
    }
}

public enum LibghosttyClipboardLocation: Equatable, Sendable {
    case standard
    case selection
    case unknown(Int32)
}

public final class LibghosttySurfaceRuntimeCallbacks {
    public typealias ReadClipboardHandler = (LibghosttyClipboardLocation, UnsafeMutableRawPointer?)
        -> Void
    public typealias ConfirmReadClipboardHandler = (String, UnsafeMutableRawPointer?, Int32) -> Void
    public typealias WriteClipboardHandler = (String, LibghosttyClipboardLocation, Bool) -> Void
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
public final class LibghosttyRuntimeState: ObservableObject {
    public private(set) var wakeupCount = 0
    @Published public private(set) var lastAction: LibghosttyRuntimeActionEvent?
    @Published public private(set) var closeEvents: [LibghosttySurfaceCloseEvent] = []

    public let splitActionSubject = PassthroughSubject<LibghosttyRuntimeSplitAction, Never>()
    public let childExitSubject = PassthroughSubject<LibghosttyRuntimeActionEvent, Never>()

    public init() {}

    public func recordWakeup() {
        wakeupCount += 1
    }

    public func recordAction(
        _ action: LibghosttyRuntimeActionEvent,
        sourceSurfaceIdentity: UInt? = nil
    ) {
        lastAction = action
        switch action {
        case .newSplit, .gotoSplit, .resizeSplit, .equalizeSplits,
             .toggleSplitZoom:
            splitActionSubject.send(
                LibghosttyRuntimeSplitAction(
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
        closeEvents.append(LibghosttySurfaceCloseEvent(processAlive: processAlive))
    }
}

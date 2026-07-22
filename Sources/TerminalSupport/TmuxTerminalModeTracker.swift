import Foundation

public struct TmuxTerminalMouseModes: Equatable, Sendable {
    public enum Tracking: Equatable, Sendable {
        case none
        case standard
        case button
        case all
    }

    public enum Encoding: Equatable, Sendable {
        case legacy
        case utf8
        case sgr
    }

    public var tracking = Tracking.none
    public var encoding = Encoding.legacy

    public var standard: Bool { tracking == .standard }
    public var button: Bool { tracking == .button }
    public var all: Bool { tracking == .all }
    public var utf8: Bool { encoding == .utf8 }
    public var sgr: Bool { encoding == .sgr }

    public init() {}
}

/// Tracks terminal modes that affect Ghosthub's tmux input encoding.
///
/// Both the rendered surface and the durable tmux session consume pane output.
/// Keeping the parser in TerminalSupport lets the session retain the current
/// mode even while a surface is absent or being replaced.
public struct TmuxTerminalModeTracker {
    private enum State {
        case ground
        case escape
        case csi([UInt8])
    }

    private var state = State.ground
    public private(set) var applicationCursorKeys = false
    public private(set) var mouseModes = TmuxTerminalMouseModes()
    public private(set) var hasMouseModeState = false

    public init() {}

    public mutating func setApplicationCursorKeys(_ enabled: Bool) {
        applicationCursorKeys = enabled
    }

    public mutating func consume(_ data: Data) {
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1b {
                    state = .escape
                }
            case .escape:
                if byte == 0x5b {
                    state = .csi([])
                } else if byte == 0x63 {
                    resetModes()
                    state = .ground
                } else {
                    state = byte == 0x1b ? .escape : .ground
                }
            case let .csi(bytes):
                if byte == 0x1b {
                    state = .escape
                    continue
                }
                var next = bytes
                next.append(byte)
                guard next.count <= 64 else {
                    state = .ground
                    continue
                }
                if (0x40 ... 0x7e).contains(byte) {
                    applyCSI(next)
                    state = .ground
                } else {
                    state = .csi(next)
                }
            }
        }
    }

    private mutating func applyCSI(_ bytes: [UInt8]) {
        guard let final = bytes.last else { return }
        if final == 0x70, bytes.dropLast().elementsEqual([0x21]) {
            // DECSTR (CSI ! p) restores DECCKM without issuing a full RIS.
            // Mouse tracking is retained until its own DECRST or a full reset.
            applicationCursorKeys = false
            return
        }
        guard final == 0x68 || final == 0x6c,
              bytes.first == 0x3f else { return }
        let parameters = bytes.dropFirst().dropLast().split(separator: 0x3b)
        let enabled = final == 0x68
        for parameter in parameters {
            switch decimalValue(parameter) {
            case 1:
                applicationCursorKeys = enabled
            case 1_000:
                hasMouseModeState = true
                mouseModes.tracking = enabled ? .standard : .none
            case 1_002:
                hasMouseModeState = true
                mouseModes.tracking = enabled ? .button : .none
            case 1_003:
                hasMouseModeState = true
                mouseModes.tracking = enabled ? .all : .none
            case 1_005:
                hasMouseModeState = true
                mouseModes.encoding = enabled ? .utf8 : .legacy
            case 1_006:
                hasMouseModeState = true
                mouseModes.encoding = enabled ? .sgr : .legacy
            default:
                break
            }
        }
    }

    private mutating func resetModes() {
        applicationCursorKeys = false
        mouseModes = TmuxTerminalMouseModes()
    }

    private func decimalValue(_ bytes: ArraySlice<UInt8>) -> Int? {
        var value = 0
        guard !bytes.isEmpty else { return nil }
        for byte in bytes {
            guard (0x30 ... 0x39).contains(byte) else { return nil }
            let (scaled, multiplyOverflow) = value.multipliedReportingOverflow(
                by: 10
            )
            let (next, addOverflow) = scaled.addingReportingOverflow(
                Int(byte - 0x30)
            )
            guard !multiplyOverflow, !addOverflow else { return nil }
            value = next
        }
        return value
    }
}

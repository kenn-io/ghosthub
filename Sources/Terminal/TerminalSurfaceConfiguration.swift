import AppKit
import GhosttyKit

public struct TerminalSurfaceConfiguration: Equatable, Sendable {
    public var workingDirectory: String?
    public var command: String?
    public var environmentVariables: [String: String] = [:]
    public var initialInput: String?
    public var fontSize: CGFloat?
    public var waitAfterCommand: Bool

    public init(
        workingDirectory: String? = nil,
        command: String? = nil,
        environmentVariables: [String: String] = [:],
        initialInput: String? = nil,
        fontSize: CGFloat? = nil,
        waitAfterCommand: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.environmentVariables = environmentVariables
        self.initialInput = initialInput
        self.fontSize = fontSize
        self.waitAfterCommand = waitAfterCommand
    }

    func withCValue<T>(
        view: TerminalSurfaceView,
        body: (inout ghostty_surface_config_s) throws -> T
    ) rethrows -> T {
        var config = ghostty_surface_config_new()
        // Hand libghostty the surface's unique callback token as `userdata`,
        // not the reusable view address, so callbacks route by identity.
        config.userdata = Unmanaged.passUnretained(view.callbackToken).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            )
        )
        config.scale_factor = Double(
            NSScreen.main?.backingScaleFactor ?? 2.0
        )
        config.font_size = Float(fontSize ?? 0)
        config.wait_after_command = waitAfterCommand

        return try workingDirectory.withOptionalCString { cWorkingDir in
            config.working_directory = cWorkingDir

            return try command.withOptionalCString { cCommand in
                config.command = cCommand

                return try initialInput.withOptionalCString { cInitialInput in
                    config.initial_input = cInitialInput

                    let keys = Array(environmentVariables.keys)
                    let values = Array(environmentVariables.values)

                    return try keys.withCStrings { keyCStrings in
                        return try values.withCStrings { valueCStrings in
                            var envVars: [ghostty_env_var_s] = []
                            envVars.reserveCapacity(environmentVariables.count)
                            for i in 0 ..< environmentVariables.count {
                                envVars.append(ghostty_env_var_s(
                                    key: keyCStrings[i],
                                    value: valueCStrings[i]
                                ))
                            }

                            return try envVars.withUnsafeMutableBufferPointer { buffer in
                                config.env_vars = buffer.baseAddress
                                config.env_var_count = environmentVariables.count
                                return try body(&config)
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension String? {
    func withOptionalCString<T>(
        _ body: (UnsafePointer<Int8>?) throws -> T
    ) rethrows -> T {
        if let string = self {
            return try string.withCString(body)
        } else {
            return try body(nil)
        }
    }
}

private extension [String] {
    func withCStrings<T>(
        _ body: ([UnsafePointer<Int8>?]) throws -> T
    ) rethrows -> T {
        if isEmpty {
            return try body([])
        }

        func helper(
            index: Int,
            accumulated: [UnsafePointer<Int8>?],
            body: ([UnsafePointer<Int8>?]) throws -> T
        ) rethrows -> T {
            if index == count {
                return try body(accumulated)
            }

            return try self[index].withCString { cStr in
                var next = accumulated
                next.append(cStr)
                return try helper(index: index + 1, accumulated: next, body: body)
            }
        }

        return try helper(index: 0, accumulated: [], body: body)
    }
}

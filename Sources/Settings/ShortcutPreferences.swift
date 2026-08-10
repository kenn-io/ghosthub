import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace

public struct ShortcutConfigurationIssue:
    Error, Equatable, LocalizedError, Sendable {
    public var action: ApplicationShortcutAction?
    public var message: String

    public init(
        action: ApplicationShortcutAction?,
        message: String
    ) {
        self.action = action
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct ShortcutPreferences: Equatable, Sendable {
    public var overrides:
        [ApplicationShortcutAction: ApplicationShortcutOverride]
    public var resolved: ResolvedApplicationShortcuts

    public init(
        overrides: [
            ApplicationShortcutAction: ApplicationShortcutOverride,
        ]
    ) throws {
        self.overrides = overrides
        resolved = try ApplicationShortcutCatalog.resolve(
            overrides: overrides
        )
    }

    public static let compiledDefaults = try! ShortcutPreferences(
        overrides: [:]
    )

    public static func load(
        from file: URL
    ) -> Result<Self, ShortcutConfigurationIssue> {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .success(.compiledDefaults)
        }
        do {
            return load(contents: try String(
                contentsOf: file,
                encoding: .utf8
            ))
        } catch {
            return .failure(.init(
                action: nil,
                message: "Could not read shortcut configuration: \(error.localizedDescription)"
            ))
        }
    }

    public static func load(
        contents: String
    ) -> Result<Self, ShortcutConfigurationIssue> {
        var overrides: [
            ApplicationShortcutAction: ApplicationShortcutOverride
        ] = [:]
        for assignment in TOMLConfigParser.appConfigAssignments(
            sectionName: "keyboard.shortcuts",
            in: contents
        ) {
            guard let action = ApplicationShortcutAction(
                rawValue: assignment.key
            ) else { continue }
            guard let value = strictString(assignment.value) else {
                return .failure(.init(
                    action: action,
                    message: "\(action.definition.title) must be a quoted string."
                ))
            }
            do {
                overrides[action] = try ApplicationShortcutOverride(
                    parsing: value
                )
            } catch {
                return .failure(.init(
                    action: action,
                    message: error.localizedDescription
                ))
            }
        }

        do {
            return .success(try Self(overrides: overrides))
        } catch let error as ApplicationShortcutResolutionError {
            return .failure(.init(
                action: error.affectedAction,
                message: error.localizedDescription
            ))
        } catch {
            return .failure(.init(
                action: nil,
                message: error.localizedDescription
            ))
        }
    }

    private static func strictString(_ raw: String) -> String? {
        guard raw.count >= 2,
              raw.first == "\"",
              raw.last == "\""
        else { return nil }
        return TOMLConfigParser.unquoteTOMLString(raw)
    }
}

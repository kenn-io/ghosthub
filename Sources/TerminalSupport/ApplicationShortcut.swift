import Foundation

public enum ApplicationShortcutAction: String, CaseIterable, Sendable {
    case nextSibling = "next-sibling"
    case previousSibling = "previous-sibling"
    case selectSibling1 = "select-sibling-1"
    case selectSibling2 = "select-sibling-2"
    case selectSibling3 = "select-sibling-3"
    case selectSibling4 = "select-sibling-4"
    case selectSibling5 = "select-sibling-5"
    case selectSibling6 = "select-sibling-6"
    case selectSibling7 = "select-sibling-7"
    case selectSibling8 = "select-sibling-8"
    case selectSibling9 = "select-sibling-9"
    case commandPalette = "command-palette"
    case toggleSidebar = "toggle-sidebar"
    case newWorktree = "new-worktree"
    case importPullRequest = "import-pull-request"
    case newTmuxSession = "new-tmux-session"
    case newHerdrSession = "new-herdr-session"
    case splitRight = "split-right"
    case splitDown = "split-down"
    case reloadConfiguration = "reload-configuration"
    case openApplicationLog = "open-application-log"

    public var siblingIndex: Int? {
        switch self {
        case .selectSibling1: 1
        case .selectSibling2: 2
        case .selectSibling3: 3
        case .selectSibling4: 4
        case .selectSibling5: 5
        case .selectSibling6: 6
        case .selectSibling7: 7
        case .selectSibling8: 8
        case .selectSibling9: 9
        default: nil
        }
    }
}

public struct ApplicationShortcutModifiers:
    OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)

    public static let nonShift: Self = [.command, .control, .option]
}

public enum ApplicationShortcutKey: Hashable, Sendable {
    case character(Character)
    case tab
    case `return`
    case escape
    case delete
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case function(Int)

    fileprivate var configValue: String {
        switch self {
        case let .character(character):
            character == "+" ? "plus" : String(character).lowercased()
        case .tab: "tab"
        case .return: "return"
        case .escape: "escape"
        case .delete: "delete"
        case .leftArrow: "left"
        case .rightArrow: "right"
        case .upArrow: "up"
        case .downArrow: "down"
        case let .function(number): "f\(number)"
        }
    }

    fileprivate var displayText: String {
        switch self {
        case let .character(character):
            String(character).uppercased()
        case .tab: "⇥"
        case .return: "↩"
        case .escape: "⎋"
        case .delete: "⌫"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case let .function(number): "F\(number)"
        }
    }
}

public enum ApplicationShortcutParseError: Error, Equatable, LocalizedError {
    case empty
    case missingKey
    case unknownToken(String)
    case duplicateModifier(String)
    case multipleKeys
    case unsafeWithoutModifier

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Shortcut is empty."
        case .missingKey:
            "Shortcut must include a key."
        case let .unknownToken(token):
            "Unknown shortcut token “\(token)”."
        case let .duplicateModifier(modifier):
            "Modifier “\(modifier)” appears more than once."
        case .multipleKeys:
            "Shortcut must contain exactly one key."
        case .unsafeWithoutModifier:
            "Add Command, Control, or Option to avoid intercepting terminal input."
        }
    }
}

public struct ApplicationKeyBinding: Hashable, Sendable {
    public var modifiers: ApplicationShortcutModifiers
    public var key: ApplicationShortcutKey

    public init(
        modifiers: ApplicationShortcutModifiers,
        key: ApplicationShortcutKey
    ) {
        self.modifiers = modifiers
        self.key = key
    }

    public init(parsing value: String) throws {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw ApplicationShortcutParseError.empty
        }

        let tokens = source.components(separatedBy: "+")
        guard !tokens.contains(where: { $0.isEmpty }) else {
            throw ApplicationShortcutParseError.unknownToken("")
        }

        var modifiers: ApplicationShortcutModifiers = []
        var parsedKey: ApplicationShortcutKey?
        for rawToken in tokens {
            let token = rawToken.lowercased()
            if let modifier = Self.modifier(for: token) {
                guard parsedKey == nil else {
                    throw ApplicationShortcutParseError.multipleKeys
                }
                guard !modifiers.contains(modifier) else {
                    throw ApplicationShortcutParseError.duplicateModifier(token)
                }
                modifiers.insert(modifier)
                continue
            }

            guard parsedKey == nil else {
                throw ApplicationShortcutParseError.multipleKeys
            }
            parsedKey = try Self.key(for: token)
        }

        guard let parsedKey else {
            throw ApplicationShortcutParseError.missingKey
        }
        guard !modifiers.intersection(.nonShift).isEmpty else {
            throw ApplicationShortcutParseError.unsafeWithoutModifier
        }
        self.init(modifiers: modifiers, key: parsedKey)
    }

    public var configValue: String {
        var tokens: [String] = []
        if modifiers.contains(.command) {
            tokens.append("cmd")
        }
        if modifiers.contains(.control) {
            tokens.append("ctrl")
        }
        if modifiers.contains(.option) {
            tokens.append("opt")
        }
        if modifiers.contains(.shift) {
            tokens.append("shift")
        }
        tokens.append(key.configValue)
        return tokens.joined(separator: "+")
    }

    public var displayText: String {
        var text = ""
        if modifiers.contains(.control) {
            text += "⌃"
        }
        if modifiers.contains(.option) {
            text += "⌥"
        }
        if modifiers.contains(.shift) {
            text += "⇧"
        }
        if modifiers.contains(.command) {
            text += "⌘"
        }
        return text + key.displayText
    }

    private static func modifier(
        for token: String
    ) -> ApplicationShortcutModifiers? {
        switch token {
        case "cmd", "command": .command
        case "ctrl", "control": .control
        case "opt", "option": .option
        case "shift": .shift
        default: nil
        }
    }

    private static func key(
        for token: String
    ) throws -> ApplicationShortcutKey {
        switch token {
        case "plus": return .character("+")
        case "tab": return .tab
        case "return": return .return
        case "escape": return .escape
        case "delete": return .delete
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        default:
            if token.hasPrefix("f"),
               let number = Int(token.dropFirst()),
               (1 ... 12).contains(number) {
                return .function(number)
            }
            guard token.count == 1,
                  let character = token.first,
                  character.isLetter || character.isNumber
                  || Self.allowedPunctuation.contains(character)
            else {
                throw ApplicationShortcutParseError.unknownToken(token)
            }
            return .character(character)
        }
    }

    private static let allowedPunctuation = Set<Character>(
        [",", ".", "/", ";", "'", "[", "]", "\\", "-", "=", "`"]
    )
}

public enum ApplicationShortcutOverride: Equatable, Sendable {
    case binding(ApplicationKeyBinding)
    case unbound

    public init(parsing value: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "none" {
            self = .unbound
        } else {
            self = .binding(try ApplicationKeyBinding(parsing: value))
        }
    }

    public var configValue: String {
        switch self {
        case let .binding(binding): binding.configValue
        case .unbound: "none"
        }
    }
}

public enum ApplicationShortcutSettingsGroup:
    String, CaseIterable, Sendable {
    case navigation = "Navigation"
    case application = "Application"
    case multiplexer = "Multiplexer"
}

public struct ApplicationShortcutDefinition: Equatable, Sendable {
    public let action: ApplicationShortcutAction
    public let title: String
    public let settingsGroup: ApplicationShortcutSettingsGroup
    public let defaultBinding: ApplicationKeyBinding?
    public let allowsKeyRepeat: Bool

    public var configKey: String { action.rawValue }
}

public struct ResolvedApplicationShortcuts: Equatable, Sendable {
    private let bindings: [ApplicationShortcutAction: ApplicationKeyBinding]
    private let actionsByBinding: [ApplicationKeyBinding: ApplicationShortcutAction]

    fileprivate init(
        bindings: [ApplicationShortcutAction: ApplicationKeyBinding]
    ) {
        self.bindings = bindings
        actionsByBinding = Dictionary(uniqueKeysWithValues: bindings.map {
            ($0.value, $0.key)
        })
    }

    public subscript(
        _ action: ApplicationShortcutAction
    ) -> ApplicationKeyBinding? {
        bindings[action]
    }

    public func action(
        for binding: ApplicationKeyBinding
    ) -> ApplicationShortcutAction? {
        actionsByBinding[binding]
    }

    public var commandModifiedBindings: Set<ApplicationKeyBinding> {
        Set(bindings.values.filter { $0.modifiers.contains(.command) })
    }
}

public enum ApplicationShortcutResolutionError:
    Error, Equatable, LocalizedError {
    case reserved(
        action: ApplicationShortcutAction,
        binding: ApplicationKeyBinding,
        owner: String
    )
    case duplicate(
        action: ApplicationShortcutAction,
        binding: ApplicationKeyBinding,
        other: ApplicationShortcutAction
    )
    case unsafe(
        action: ApplicationShortcutAction,
        binding: ApplicationKeyBinding
    )

    public var errorDescription: String? {
        switch self {
        case let .reserved(action, binding, owner):
            "\(action.definition.title) cannot use \(binding.displayText); it is reserved for \(owner)."
        case let .duplicate(action, binding, other):
            "\(action.definition.title) cannot use \(binding.displayText); it is already used by \(other.definition.title)."
        case let .unsafe(action, _):
            "\(action.definition.title) must include Command, Control, or Option."
        }
    }

    public var affectedAction: ApplicationShortcutAction {
        switch self {
        case let .reserved(action, _, _),
             let .duplicate(action, _, _),
             let .unsafe(action, _):
            action
        }
    }
}

public struct FixedApplicationShortcut: Equatable, Sendable {
    public let title: String
    public let binding: ApplicationKeyBinding
}

public enum ApplicationShortcutCatalog {
    public static let definitions: [ApplicationShortcutDefinition] = [
        definition(.nextSibling, "Next Sibling", .navigation, "ctrl+tab", repeats: true),
        definition(
            .previousSibling,
            "Previous Sibling",
            .navigation,
            "ctrl+shift+tab",
            repeats: true
        ),
        definition(.selectSibling1, "Select Sibling 1", .navigation, nil),
        definition(.selectSibling2, "Select Sibling 2", .navigation, nil),
        definition(.selectSibling3, "Select Sibling 3", .navigation, nil),
        definition(.selectSibling4, "Select Sibling 4", .navigation, nil),
        definition(.selectSibling5, "Select Sibling 5", .navigation, nil),
        definition(.selectSibling6, "Select Sibling 6", .navigation, nil),
        definition(.selectSibling7, "Select Sibling 7", .navigation, nil),
        definition(.selectSibling8, "Select Sibling 8", .navigation, nil),
        definition(.selectSibling9, "Select Sibling 9", .navigation, nil),
        definition(.commandPalette, "Command Palette", .application, "cmd+shift+p"),
        definition(.toggleSidebar, "Toggle Sidebar", .application, "cmd+b"),
        definition(.newWorktree, "New Worktree", .application, "cmd+shift+n"),
        definition(.importPullRequest, "Import Pull Request", .application, "cmd+shift+i"),
        definition(.newTmuxSession, "New tmux Session", .application, nil),
        definition(.newHerdrSession, "New Herdr Session", .application, nil),
        definition(.splitRight, "Split Right", .multiplexer, "cmd+d"),
        definition(.splitDown, "Split Down", .multiplexer, "cmd+shift+d"),
        definition(.reloadConfiguration, "Reload Configuration", .application, "cmd+shift+,"),
        definition(.openApplicationLog, "Open Application Log", .application, "cmd+opt+l"),
    ]

    public static let fixedShortcuts: [FixedApplicationShortcut] = [
        fixed("Previous Tab", "cmd+shift+["),
        fixed("Next Tab", "cmd+shift+]"),
        fixed("New Window", "cmd+n"),
        fixed("New Tab", "cmd+t"),
        fixed("Close", "cmd+w"),
        fixed("Close Window", "cmd+shift+w"),
        fixed("Settings", "cmd+,"),
        fixed("Quit Ghosthub", "cmd+q"),
        fixed("Cut", "cmd+x"),
        fixed("Copy", "cmd+c"),
        fixed("Paste", "cmd+v"),
        fixed("Select All", "cmd+a"),
    ]

    public static let compiledDefaults: ResolvedApplicationShortcuts = try! resolve(overrides: [:])

    public static func resolve(
        overrides: [ApplicationShortcutAction: ApplicationShortcutOverride]
    ) throws -> ResolvedApplicationShortcuts {
        var resolved: [ApplicationShortcutAction: ApplicationKeyBinding] = [:]
        var owners: [ApplicationKeyBinding: ApplicationShortcutAction] = [:]
        let fixedOwners = Dictionary(
            uniqueKeysWithValues: fixedShortcuts.map { ($0.binding, $0.title) }
        )

        for definition in definitions {
            let binding: ApplicationKeyBinding? = switch overrides[definition.action] {
            case let .binding(value): value
            case .unbound: nil
            case nil: definition.defaultBinding
            }
            guard let binding else { continue }
            guard !binding.modifiers.intersection(.nonShift).isEmpty else {
                throw ApplicationShortcutResolutionError.unsafe(
                    action: definition.action,
                    binding: binding
                )
            }
            if let owner = fixedOwners[binding] {
                throw ApplicationShortcutResolutionError.reserved(
                    action: definition.action,
                    binding: binding,
                    owner: owner
                )
            }
            if let other = owners[binding] {
                throw ApplicationShortcutResolutionError.duplicate(
                    action: definition.action,
                    binding: binding,
                    other: other
                )
            }
            resolved[definition.action] = binding
            owners[binding] = definition.action
        }
        return ResolvedApplicationShortcuts(bindings: resolved)
    }

    public static func definition(
        for action: ApplicationShortcutAction
    ) -> ApplicationShortcutDefinition {
        definitions.first { $0.action == action }!
    }

    public static func validationMessage(
        for binding: ApplicationKeyBinding,
        action: ApplicationShortcutAction,
        overrides: [ApplicationShortcutAction: ApplicationShortcutOverride]
    ) -> String? {
        guard !binding.modifiers.intersection(.nonShift).isEmpty else {
            return "Add Command, Control, or Option to avoid intercepting terminal input."
        }
        if let fixed = fixedShortcuts.first(where: {
            $0.binding == binding
        }) {
            return "Reserved for \(fixed.title)."
        }
        for definition in definitions where definition.action != action {
            let otherBinding: ApplicationKeyBinding? = switch overrides[
                definition.action
            ] {
            case let .binding(value): value
            case .unbound: nil
            case nil: definition.defaultBinding
            }
            if otherBinding == binding {
                return "Already used by \(definition.title)."
            }
        }
        return nil
    }

    private static func definition(
        _ action: ApplicationShortcutAction,
        _ title: String,
        _ group: ApplicationShortcutSettingsGroup,
        _ binding: String?,
        repeats: Bool = false
    ) -> ApplicationShortcutDefinition {
        ApplicationShortcutDefinition(
            action: action,
            title: title,
            settingsGroup: group,
            defaultBinding: binding.map { try! ApplicationKeyBinding(parsing: $0) },
            allowsKeyRepeat: repeats
        )
    }

    private static func fixed(
        _ title: String,
        _ binding: String
    ) -> FixedApplicationShortcut {
        FixedApplicationShortcut(
            title: title,
            binding: try! ApplicationKeyBinding(parsing: binding)
        )
    }
}

public extension ApplicationShortcutAction {
    var definition: ApplicationShortcutDefinition {
        ApplicationShortcutCatalog.definition(for: self)
    }
}

import AppKit
import Combine
import GhosthubTerminalSupport

@MainActor
final class NativeTabBadgeController {
    private weak var window: NSWindow?
    private weak var observedGroup: NSWindowTabGroup?
    private nonisolated(unsafe) var groupObservation: NSKeyValueObservation?
    private nonisolated(unsafe) var shortcutObservation: AnyCancellable?
    private var order: [ObjectIdentifier] = []
    private var availableShortcuts = Set(1 ... 9)
    private var attention: String?

    init(
        shortcuts: AnyPublisher<ResolvedApplicationShortcuts, Never>? = nil
    ) {
        shortcutObservation = shortcuts?.removeDuplicates().sink {
            [weak self] shortcuts in
            MainActor.assumeIsolated {
                self?.update(
                    availableShortcuts: NativeTabCommands
                        .availableShortcuts(claimedBy: shortcuts)
                )
            }
        }
    }

    func install(on window: NSWindow) {
        invalidate()
        self.window = window
        if let attention {
            NativeTabCommands.setAttention(attention, for: window)
        }
        refresh()
    }

    func refresh() {
        guard let window else { return }
        updateGroupObservation(window.tabGroup)
        let windows = WorkspaceWindowIdentity.group(containing: window)
        let newOrder = windows.map(ObjectIdentifier.init)
        guard newOrder != order else { return }
        order = newOrder
        NativeTabCommands.refreshBadges(
            in: windows,
            availableShortcuts: availableShortcuts
        )
    }

    /// Shows or clears the attention dot on this window's tab.
    func setAttention(_ label: String?) {
        guard attention != label else { return }
        attention = label
        guard let window else { return }
        NativeTabCommands.setAttention(label, for: window)
        order = []
        refresh()
    }

    func update(availableShortcuts: Set<Int>) {
        guard self.availableShortcuts != availableShortcuts else { return }
        self.availableShortcuts = availableShortcuts
        order = []
        refresh()
    }

    private func updateGroupObservation(_ group: NSWindowTabGroup?) {
        guard observedGroup !== group else { return }
        groupObservation?.invalidate()
        observedGroup = group
        groupObservation = group?.observe(
            \.windows,
            options: [.new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func invalidate() {
        if let window {
            NativeTabCommands.setAttention(nil, for: window)
        }
        groupObservation?.invalidate()
        groupObservation = nil
        observedGroup = nil
        window = nil
        order = []
    }

    deinit {
        groupObservation?.invalidate()
        shortcutObservation?.cancel()
    }
}

@MainActor
enum NativeTabCommands {
    private static let badgeIdentifier = NSUserInterfaceItemIdentifier(
        "native-tab-shortcut"
    )

    static let previousBinding = try! ApplicationKeyBinding(
        parsing: "cmd+shift+["
    )
    static let nextBinding = try! ApplicationKeyBinding(
        parsing: "cmd+shift+]"
    )

    static func selectPrevious() {
        NSApp.sendAction(
            #selector(NSWindow.selectPreviousTab(_:)),
            to: nil,
            from: nil
        )
    }

    static func selectNext() {
        NSApp.sendAction(
            #selector(NSWindow.selectNextTab(_:)),
            to: nil,
            from: nil
        )
    }

    static func select(_ shortcut: Int) {
        target(
            for: shortcut,
            candidate: NSApp.keyWindow ?? NSApp.mainWindow,
            isWorkspace: WorkspaceWindowIdentity.matches,
            hasAttachedSheet: { $0.attachedSheet != nil },
            group: WorkspaceWindowIdentity.group
        )?.makeKeyAndOrderFront(nil)
    }

    static func binding(
        for shortcut: Int,
        claimedBy shortcuts: ResolvedApplicationShortcuts
    ) -> ApplicationKeyBinding? {
        guard let binding = numberBindings[shortcut],
              shortcuts.action(for: binding) == nil
        else { return nil }
        return binding
    }

    static func availableShortcuts(
        claimedBy shortcuts: ResolvedApplicationShortcuts
    ) -> Set<Int> {
        Set(numberBindings.keys.filter {
            binding(for: $0, claimedBy: shortcuts) != nil
        })
    }

    static func target<Window: AnyObject>(
        for shortcut: Int,
        candidate: Window?,
        isWorkspace: (Window) -> Bool,
        hasAttachedSheet: (Window) -> Bool,
        group: (Window) -> [Window]
    ) -> Window? {
        guard (1 ... 9).contains(shortcut),
              let candidate,
              isWorkspace(candidate),
              !hasAttachedSheet(candidate)
        else { return nil }

        let windows = group(candidate).filter(isWorkspace)
        guard !windows.isEmpty else { return nil }
        let index = shortcut == 9
            ? windows.index(before: windows.endIndex)
            : min(shortcut - 1, windows.index(before: windows.endIndex))
        return windows[index]
    }

    /// Attention labels for workspace windows whose visible session has an
    /// agent waiting; set by each window's badge controller.
    private static var attentionLabels: [ObjectIdentifier: String] = [:]

    static func setAttention(_ label: String?, for window: NSWindow) {
        attentionLabels[ObjectIdentifier(window)] = label
    }

    static func refreshBadges(
        in windows: some Sequence<NSWindow>,
        availableShortcuts: Set<Int> = Set(1 ... 9)
    ) {
        let windows = Array(windows)
        for (index, window) in windows.enumerated() {
            let shortcut: Int? = if index < 8 {
                index + 1
            } else if index == windows.indices.last {
                9
            } else {
                nil
            }
            let shortcutText = shortcut.flatMap {
                availableShortcuts.contains($0) ? "⌘\($0)" : nil
            }
            let attention = attentionLabels[ObjectIdentifier(window)]
            guard shortcutText != nil || attention != nil else {
                if window.tab.accessoryView?.identifier == badgeIdentifier {
                    window.tab.accessoryView = nil
                }
                continue
            }

            let label: NSTextField
            if let existing = window.tab.accessoryView as? NSTextField,
               existing.identifier == badgeIdentifier {
                label = existing
            } else if window.tab.accessoryView == nil {
                label = NSTextField(labelWithString: "")
                label.identifier = badgeIdentifier
                label.setContentCompressionResistancePriority(
                    .windowSizeStayPut,
                    for: .horizontal
                )
                window.tab.accessoryView = label
            } else {
                continue
            }
            label.attributedStringValue = badgeText(
                shortcut: shortcutText,
                hasAttention: attention != nil
            )
            label.toolTip = attention
            label.setAccessibilityLabel(
                [attention, shortcutText].compactMap(\.self).joined(separator: ", ")
            )
        }
    }

    private static func badgeText(
        shortcut: String?,
        hasAttention: Bool
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString()
        if hasAttention {
            text.append(NSAttributedString(string: "●", attributes: [
                .font: font,
                .foregroundColor: NSColor.systemBlue,
            ]))
            if shortcut != nil {
                text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
        }
        if let shortcut {
            text.append(NSAttributedString(string: shortcut, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        return text
    }

    static func installBracketShortcuts(in menu: NSMenu? = NSApp.mainMenu) {
        guard let menu else { return }
        for item in menu.items {
            switch item.action {
            case #selector(NSWindow.selectPreviousTab(_:)):
                apply(previousBinding, to: item)
            case #selector(NSWindow.selectNextTab(_:)):
                apply(nextBinding, to: item)
            default:
                break
            }
            installBracketShortcuts(in: item.submenu)
        }
    }

    private static func apply(
        _ binding: ApplicationKeyBinding,
        to item: NSMenuItem
    ) {
        guard case let .character(character) = binding.key else { return }
        item.keyEquivalent = String(character)
        item.keyEquivalentModifierMask = binding.modifiers.appKit
    }

    private static let numberBindings = Dictionary(
        uniqueKeysWithValues: (1 ... 9).map { shortcut in
            (
                shortcut,
                try! ApplicationKeyBinding(parsing: "cmd+\(shortcut)")
            )
        }
    )
}

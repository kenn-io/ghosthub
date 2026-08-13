import AppKit
import GhosthubTerminalSupport

@MainActor
final class NativeTabBadgeController {
    private weak var window: NSWindow?
    private nonisolated(unsafe) var frameObservers: [NSObjectProtocol] = []
    private var order: [ObjectIdentifier] = []
    private let group: @MainActor (NSWindow) -> [NSWindow]

    init(
        group: @escaping @MainActor (NSWindow) -> [NSWindow] =
            WorkspaceWindowIdentity.group
    ) {
        self.group = group
    }

    func install(on window: NSWindow) {
        invalidate()
        self.window = window
        refresh()
    }

    func refresh() {
        guard let window else { return }
        let windows = group(window)
        let newOrder = windows.map(ObjectIdentifier.init)
        guard newOrder != order else { return }
        order = newOrder
        NativeTabCommands.refreshBadges(in: windows)
        updateFrameObservation(in: windows)
    }

    private func updateFrameObservation(in windows: [NSWindow]) {
        removeFrameObservers()
        guard windows.count > 1 else { return }
        frameObservers = windows.compactMap { window in
            guard let accessoryView = window.tab.accessoryView else {
                return nil
            }
            return NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: accessoryView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
    }

    private nonisolated func removeFrameObservers() {
        for observer in frameObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        frameObservers = []
    }

    func invalidate() {
        removeFrameObservers()
        window = nil
        order = []
    }

    deinit {
        removeFrameObservers()
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

    static func refreshBadges(
        in windows: some Sequence<NSWindow>
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
            guard let shortcut else {
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
                label.font = .systemFont(
                    ofSize: NSFont.smallSystemFontSize
                )
                label.textColor = .labelColor
                label.postsFrameChangedNotifications = true
                label.setContentCompressionResistancePriority(
                    .windowSizeStayPut,
                    for: .horizontal
                )
                window.tab.accessoryView = label
            } else {
                continue
            }
            label.stringValue = "⌘\(shortcut)"
        }
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
}

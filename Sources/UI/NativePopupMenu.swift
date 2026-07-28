import AppKit
import SwiftUI

struct NativePopupMenuAction {
    let title: String
    let role: ButtonRole?
    let isEnabled: Bool
    let action: @MainActor () -> Void

    init(
        _ title: String,
        role: ButtonRole? = nil,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
    }
}

struct NativePopupMenuButton<Label: View>: View {
    let groups: [[NativePopupMenuAction]]
    private let label: Label

    init(
        groups: [[NativePopupMenuAction]],
        @ViewBuilder label: () -> Label
    ) {
        self.groups = groups
        self.label = label()
    }

    var body: some View {
        Button {
            NativePopupMenuPresenter.present(groups)
        } label: {
            label
        }
    }
}

@MainActor
private enum NativePopupMenuPresenter {
    static func present(_ groups: [[NativePopupMenuAction]]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var targets: [NativePopupMenuActionTarget] = []

        for (groupIndex, group) in groups.enumerated() {
            if groupIndex > 0 {
                menu.addItem(.separator())
            }
            for action in group {
                let target = NativePopupMenuActionTarget(action: action.action)
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(
                        NativePopupMenuActionTarget.performAction
                    ),
                    keyEquivalent: ""
                )
                if action.role == .destructive {
                    item.attributedTitle = NSAttributedString(
                        string: action.title,
                        attributes: [.foregroundColor: NSColor.systemRed]
                    )
                }
                item.isEnabled = action.isEnabled
                item.target = target
                menu.addItem(item)
                targets.append(target)
            }
        }

        guard let view = NSApp.currentEvent?.window?.contentView
            ?? NSApp.keyWindow?.contentView
        else { return }

        let location = if let event = NSApp.currentEvent,
                          event.window === view.window {
            view.convert(event.locationInWindow, from: nil)
        } else {
            NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        menu.popUp(positioning: nil, at: location, in: view)
        withExtendedLifetime(targets) {}
    }
}

@MainActor
private final class NativePopupMenuActionTarget: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func performAction() {
        action()
    }
}

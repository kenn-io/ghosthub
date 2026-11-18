import AppKit

/// What a pane card shows below its header, such as a terminal surface.
@MainActor
public protocol TerminalSplitPaneContent: AnyObject {
    var view: NSView { get }
    /// Holds terminal resizing while a divider is dragged.
    func setResizeDeferred(_ deferred: Bool)
}

public enum TerminalSplitHeaderAction: CaseIterable, Equatable, Sendable {
    case splitRight
    case splitDown
    case zoom
    case close

    var title: String {
        switch self {
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .zoom: "Zoom Pane"
        case .close: "Close Pane"
        }
    }

    var symbol: String {
        switch self {
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        case .close: "xmark"
        }
    }
}

/// One pane's card: a one-line header over its content.
@MainActor
public final class TerminalSplitPaneView: NSView {
    public static let headerHeight: CGFloat = 24

    public let paneID: String
    public private(set) var content: (any TerminalSplitPaneContent)?
    var onAction: ((TerminalSplitHeaderAction) -> Void)?
    var onHeaderClick: (() -> Void)?
    var onReconnect: (() -> Void)?

    private let header = HeaderView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let buttons: [NSButton]
    private let overlayLabel = NSTextField(wrappingLabelWithString: "")
    let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            for button in buttons {
                button.isHidden = !isFocused
            }
            needsDisplay = true
        }
    }

    var overlayMessage: String? {
        didSet {
            overlayLabel.stringValue = overlayMessage ?? ""
            overlayLabel.isHidden = overlayMessage == nil
        }
    }

    var offersReconnect = false {
        didSet {
            reconnectButton.isHidden = !offersReconnect
            needsLayout = true
        }
    }

    public var buttonActions: [TerminalSplitHeaderAction] {
        buttons.filter { !$0.isHidden }.compactMap { TerminalSplitHeaderAction.allCases[$0.tag] }
    }

    init(paneID: String) {
        self.paneID = paneID
        buttons = TerminalSplitHeaderAction.allCases.enumerated().map { index, action in
            let image = NSImage(
                systemSymbolName: action.symbol,
                accessibilityDescription: action.title
            )
                ?? NSImage()
            let button = NSButton(image: image, target: nil, action: nil)
            button.tag = index
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = action.title
            button.setAccessibilityLabel(action.title)
            button.isHidden = true
            return button
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.cell?.truncatesLastVisibleLine = true
        header.addSubview(titleLabel)
        header.onClick = { [weak self] in self?.onHeaderClick?() }
        for button in buttons {
            button.target = self
            button.action = #selector(buttonPressed(_:))
            header.addSubview(button)
        }
        addSubview(header)

        overlayLabel.alignment = .center
        overlayLabel.textColor = .secondaryLabelColor
        overlayLabel.isHidden = true
        addSubview(overlayLabel)
        reconnectButton.bezelStyle = .push
        reconnectButton.controlSize = .small
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectPressed)
        reconnectButton.isHidden = true
        addSubview(reconnectButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool { true }
    override public var wantsUpdateLayer: Bool { true }

    override public func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = (isFocused
                ? NSColor.controlAccentColor.withAlphaComponent(0.6)
                : NSColor.separatorColor).cgColor
        }
    }

    func setContent(_ newContent: (any TerminalSplitPaneContent)?) {
        guard newContent !== content else { return }
        content?.view.removeFromSuperview()
        content = newContent
        if let view = newContent?.view {
            addSubview(view, positioned: .below, relativeTo: overlayLabel)
        }
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        let headerHeight = Self.headerHeight
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        let contentFrame = CGRect(
            x: 0, y: headerHeight,
            width: bounds.width, height: max(0, bounds.height - headerHeight)
        )
        content?.view.frame = contentFrame
        overlayLabel.frame = contentFrame.insetBy(dx: 12, dy: max(0, contentFrame.height / 2 - 20))
        let buttonSize = reconnectButton.fittingSize
        reconnectButton.frame = CGRect(
            x: (bounds.width - buttonSize.width) / 2, y: overlayLabel.frame.maxY + 4,
            width: buttonSize.width, height: buttonSize.height
        )

        var trailing = bounds.width - 6
        for button in buttons.reversed() where !button.isHidden {
            trailing -= 20
            button.frame = CGRect(x: trailing, y: 2, width: 20, height: 20)
        }
        titleLabel.frame = CGRect(
            x: 10, y: 4, width: max(0, trailing - 14), height: headerHeight - 8
        )
    }

    @objc private func reconnectPressed() {
        onReconnect?()
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        onAction?(TerminalSplitHeaderAction.allCases[sender.tag])
    }

    private final class HeaderView: NSView {
        var onClick: (() -> Void)?

        override var isFlipped: Bool { true }

        override func mouseDown(with _: NSEvent) {
            onClick?()
        }
    }
}

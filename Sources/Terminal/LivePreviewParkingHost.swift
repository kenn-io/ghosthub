import AppKit

public enum LivePreviewParkingError: Error, Equatable {
    case surfaceStillMounted
}

@MainActor
public final class LivePreviewParkingHost: NSView {
    private struct Geometry {
        let frame: NSRect
        let bounds: NSRect
    }

    private var geometryBySurface: [ObjectIdentifier: Geometry] = [:]

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var isFlipped: Bool { false }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override public func isAccessibilityElement() -> Bool {
        false
    }

    override public func accessibilityChildren() -> [Any]? {
        []
    }

    public func park(_ surface: TerminalSurfaceView) throws {
        if surface.superview === self {
            return
        }
        guard surface.superview == nil else {
            throw LivePreviewParkingError.surfaceStillMounted
        }

        let identifier = ObjectIdentifier(surface)
        let geometry = Geometry(
            frame: surface.frame,
            bounds: surface.bounds
        )
        surface.setParkedForPreview(true)
        addSubview(surface)
        surface.bounds = geometry.bounds
        surface.frame = geometry.frame
        geometryBySurface[identifier] = geometry
    }

    public func unpark(_ surface: TerminalSurfaceView) {
        guard surface.superview === self else {
            surface.setParkedForPreview(false)
            geometryBySurface.removeValue(
                forKey: ObjectIdentifier(surface)
            )
            return
        }
        let geometry = geometryBySurface.removeValue(
            forKey: ObjectIdentifier(surface)
        )
        surface.removeFromSuperview()
        if let geometry {
            surface.bounds = geometry.bounds
            surface.frame = geometry.frame
        }
        surface.setParkedForPreview(false)
    }

    public func unparkAll() {
        for surface in subviews.compactMap({
            $0 as? TerminalSurfaceView
        }) {
            unpark(surface)
        }
    }

    public func contains(_ surface: TerminalSurfaceView) -> Bool {
        surface.superview === self
    }

    private func configure() {
        wantsLayer = true
        setAccessibilityElement(false)
        setAccessibilityChildren([])
    }
}

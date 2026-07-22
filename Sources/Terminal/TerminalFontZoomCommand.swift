import CoreGraphics
import Foundation

enum TerminalFontZoomCommand: Equatable, Sendable {
    case increase
    case decrease
    case reset

    func bindingAction(
        overridePoints: CGFloat?
    ) -> String {
        switch self {
        case .increase:
            if let overridePoints {
                Self.setFontSizeAction(points: overridePoints)
            } else {
                "increase_font_size:1"
            }
        case .decrease:
            if let overridePoints {
                Self.setFontSizeAction(points: overridePoints)
            } else {
                "decrease_font_size:1"
            }
        case .reset:
            "reset_font_size"
        }
    }

    static func setFontSizeAction(
        points: CGFloat
    ) -> String {
        "set_font_size:\(Double(points))"
    }
}

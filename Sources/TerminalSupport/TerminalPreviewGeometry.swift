import Foundation

public enum TerminalPreviewGeometry {
    public static let minimumAspectRatio: CGFloat = 4 / 3
    public static let maximumAspectRatio: CGFloat = 2
    public static let placeholderAspectRatio: CGFloat = 16 / 10

    public static func aspectRatio(for size: CGSize?) -> CGFloat {
        guard let size,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else { return placeholderAspectRatio }
        return min(
            max(size.width / size.height, minimumAspectRatio),
            maximumAspectRatio
        )
    }

    public static func thumbnailSize(
        sourceSize: CGSize,
        outputWidth: CGFloat
    ) -> CGSize {
        let aspectRatio = aspectRatio(for: sourceSize)
        return CGSize(
            width: outputWidth,
            height: (outputWidth / aspectRatio).rounded()
        )
    }
}

import Foundation

public enum TerminalPreviewGeometry {
    public static let placeholderAspectRatio: CGFloat = 16 / 10
    private static let minimumCanvasDimension: CGFloat = 1
    private static let maximumCanvasDimension: CGFloat = 1_024

    public static func aspectRatio(for size: CGSize?) -> CGFloat {
        guard let size,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else { return placeholderAspectRatio }
        return size.width / size.height
    }

    public static func thumbnailSize(
        sourceSize: CGSize,
        outputWidth: CGFloat
    ) -> CGSize {
        let aspectRatio = aspectRatio(for: sourceSize)
        let width = min(
            max(outputWidth.rounded(), minimumCanvasDimension),
            maximumCanvasDimension
        )
        let height = min(
            max(
                (width / aspectRatio).rounded(),
                minimumCanvasDimension
            ),
            maximumCanvasDimension
        )
        return CGSize(
            width: width,
            height: height
        )
    }
}

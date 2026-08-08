import SwiftUI

struct NativePaneSplitErrorOverlay: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .padding(10)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding()
            .allowsHitTesting(false)
    }
}

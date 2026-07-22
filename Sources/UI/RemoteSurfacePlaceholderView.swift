import SwiftUI

public struct RemoteSurfacePlaceholderView: View {
    let title: String
    let message: String
    var isLoading = false
    var retry: (() -> Void)?

    public init(
        title: String,
        message: String,
        isLoading: Bool = false,
        retry: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.isLoading = isLoading
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: 14) {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.headline.weight(.semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let retry {
                Button("Retry") {
                    retry()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

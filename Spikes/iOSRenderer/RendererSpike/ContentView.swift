import SwiftUI

struct ContentView: View {
    @StateObject private var runtime = RendererRuntime()

    var body: some View {
        VStack(spacing: 16) {
            Text("Ghosthub iPad renderer spike")
                .font(.headline)

            Text(runtime.status.title)
                .font(.body.monospaced())
                .foregroundStyle(runtime.status.isFailure ? .red : .secondary)

            if let detail = runtime.status.failureMessage {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .onAppear {
            runtime.start()
        }
    }
}

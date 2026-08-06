import SwiftUI

struct ContentView: View {
    @StateObject private var runtime = RendererRuntime()
    @StateObject private var surfaceBridge = RendererSurfaceBridge()

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Ghosthub iPad renderer spike")
                    .font(.headline)
                Spacer()
                Text(runtime.status.title)
                    .font(.body.monospaced())
                    .foregroundStyle(runtime.status.isFailure ? .red : .secondary)
            }

            if let detail = runtime.status.failureMessage {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            RendererSurfaceHost(runtime: runtime, bridge: surfaceBridge)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if !runtime.lastChildWrite.isEmpty {
                Text("child_write: \(runtime.lastChildWriteDescription)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("Reset Surface") {
                surfaceBridge.reset()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear {
            runtime.start()
        }
        .onDisappear {
            surfaceBridge.destroy()
            runtime.shutdown()
        }
    }
}

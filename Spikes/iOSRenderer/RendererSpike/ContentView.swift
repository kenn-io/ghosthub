import SwiftUI

struct ContentView: View {
    @StateObject private var runtime = RendererRuntime()
    @StateObject private var surfaceBridge = RendererSurfaceBridge()
    @StateObject private var transport = RemoteTmuxTransport()

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var hostKey = ""
    @State private var sessionName = ""
    @State private var configurationError: String?
    @State private var showsConnectionFields = true

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Ghosthub iPad remote tmux spike")
                    .font(.headline)
                Spacer()
                Text(transport.state.title)
                    .font(.body.monospaced())
                    .foregroundStyle(statusColor)
            }

            DisclosureGroup("SSH connection", isExpanded: $showsConnectionFields) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Host")
                        TextField("host.example.com", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Port")
                        TextField("22", text: $port)
                            .keyboardType(.numberPad)
                            .frame(width: 72)
                    }
                    GridRow {
                        Text("User")
                        TextField("username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Session")
                        TextField("exact tmux name", text: $sessionName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    GridRow {
                        Text("Password")
                        SecureField("held in memory only", text: $password)
                            .textContentType(.password)
                        Text("")
                        Text("")
                    }
                    GridRow {
                        Text("Host key")
                        TextField(
                            "trusted known_hosts or OpenSSH public-key line",
                            text: $hostKey
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .gridCellColumns(3)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(transport.state.isActive)
                .padding(.top, 8)
            }

            if let detail = configurationError ?? transport.state.detail
                ?? runtime.status.failureMessage {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Text("Renderer: \(runtime.status.title)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if transport.state.isActive {
                    Button("Disconnect") {
                        transport.disconnect()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Connect") {
                        connect()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Reset Surface") {
                    surfaceBridge.reset()
                }
                .buttonStyle(.bordered)
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

        }
        .padding()
        .onAppear {
            runtime.start()
            surfaceBridge.configure(
                inputHandler: transport.send,
                resizeHandler: transport.resize
            )
            transport.outputHandler = surfaceBridge.inject
        }
        .onDisappear {
            transport.shutdown()
            surfaceBridge.destroy()
            runtime.shutdown()
        }
    }

    private var statusColor: Color {
        switch transport.state {
        case .connected:
            .green
        case .failed:
            .red
        default:
            .secondary
        }
    }

    private func connect() {
        do {
            let configuration = try RemoteTmuxConfiguration(
                host: host,
                port: port,
                username: username,
                password: password,
                trustedHostKey: hostKey,
                sessionName: sessionName
            )
            configurationError = nil
            surfaceBridge.clearForRemoteSession()
            showsConnectionFields = false
            transport.connect(configuration)
        } catch {
            configurationError = error.localizedDescription
        }
    }
}

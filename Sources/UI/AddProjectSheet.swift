import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

struct AddProjectSheet: View {
    let host: HostSummary
    let onAdd: (String) async -> Result<String, HostProbeError>
    let onCancel: () -> Void
    let onAdded: () -> Void

    @State private var projectPath = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @FocusState private var isPathFieldFocused: Bool

    private var normalizedPath: String {
        projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAbsolutePath: Bool {
        normalizedPath.hasPrefix("/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Project")
                    .font(.headline)
                Spacer()
                Label(
                    host.sidebarTitle,
                    systemImage: host.kind == .selfHost
                        ? "laptopcomputer" : "server.rack"
                )
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Enter the absolute path of an existing Git checkout."
                        + " Ghosthub delegates registration to kwt and does"
                        + " not scan the host."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TextField(
                    "/absolute/path/to/repository",
                    text: $projectPath
                )
                .textFieldStyle(.roundedBorder)
                .focused($isPathFieldFocused)
                .onSubmit(addProject)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !normalizedPath.isEmpty, !isAbsolutePath {
                    Text("Enter an absolute path beginning with /.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAdding)
                Button(isAdding ? "Adding…" : "Add Project") {
                    addProject()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAdding || !isAbsolutePath)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { isPathFieldFocused = true }
    }

    private func addProject() {
        guard isAbsolutePath, !isAdding else { return }
        errorMessage = nil
        isAdding = true
        Task {
            let result = await onAdd(normalizedPath)
            isAdding = false
            switch result {
            case .success:
                onAdded()
            case let .failure(error):
                errorMessage = error.displayMessage
            }
        }
    }
}

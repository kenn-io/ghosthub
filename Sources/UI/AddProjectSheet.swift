import AppKit
import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

struct AddProjectSheet: View {
    let host: HostSummary
    var recoveringProject: ProjectSummary?
    let onAdd: (String) async -> Result<String, HostProbeError>
    let onCancel: () -> Void
    let onAdded: () -> Void

    @State private var projectPath = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @FocusState private var isPathFieldFocused: Bool

    private var normalizedPath: String {
        recoveringProject == nil
            ? projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
            : projectPath
    }

    private var isValidProjectPath: Bool {
        ProjectPath.isValidUserInput(normalizedPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(recoveringProject == nil ? "Add Project" : "Locate Folder")
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
                Text(recoveringProject.map {
                    "The folder for \($0.name) is unavailable at \($0.rootPath). Enter the new location of its main checkout."
                } ?? (
                    "Enter the path of an existing Git checkout (starting with"
                        + " / or ~). Ghosthub delegates registration to kwt and"
                        + " does not scan the host."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TextField(
                    "/path/to/repository or ~/repository",
                    text: $projectPath
                )
                .textFieldStyle(.roundedBorder)
                .focused($isPathFieldFocused)
                .onSubmit(addProject)

                if recoveringProject != nil, host.kind == .selfHost {
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = false
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                projectPath = url.path
                            }
                        }
                    }
                    .disabled(isAdding)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !normalizedPath.isEmpty, !isValidProjectPath {
                    Text("Enter a path beginning with / or ~.")
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
                Button(recoveringProject == nil
                    ? (isAdding ? "Adding…" : "Add Project")
                    : (isAdding ? "Locating…" : "Use Folder")) {
                        addProject()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAdding || !isValidProjectPath)
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
        guard isValidProjectPath, !isAdding else { return }
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

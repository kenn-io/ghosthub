import AppKit
import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

struct AddProjectSheet: View {
    let host: HostSummary
    var recoveringProject: ProjectSummary?
    let onAdd: (String) async -> Result<String, HostProbeError>
    var onAddDirectory: ((String) async -> Result<String, HostProbeError>)?
    let onCancel: () -> Void
    let onAdded: () -> Void

    @State private var pathInput = ProjectPathInput()
    @State private var isDirectory = false
    @State private var isAdding = false
    @State private var errorMessage: String?
    @FocusState private var isPathFieldFocused: Bool

    private var normalizedPath: String {
        pathInput.submissionPath(recovering: recoveringProject != nil)
    }

    private var isValidPath: Bool {
        isDirectory ? normalizedPath.hasPrefix("/") : ProjectPath.isValidUserInput(normalizedPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(recoveringProject == nil ? (isDirectory ? "Add Directory" : "Add Project") :
                    "Locate Folder")
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
                if recoveringProject == nil, onAddDirectory != nil {
                    Picker("Add", selection: $isDirectory) {
                        Text("Git Project").tag(false)
                        Text("Directory").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isAdding)
                }
                Text(recoveringProject.map {
                    "The folder for \($0.name) is unavailable at \($0.rootPath). Enter the new location of its main checkout."
                } ?? (
                    isDirectory
                        ? "Open a terminal in the folder and browse its subfolders. To register a subfolder, use its … menu."
                        : "Enter the path of an existing Git checkout (starting with"
                        + " / or ~). Ghosthub delegates registration to kwt and"
                        + " does not scan the host."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TextField(
                    isDirectory ? "/path/to/directory" : "/path/to/repository or ~/repository",
                    text: $pathInput.text
                )
                .textFieldStyle(.roundedBorder)
                .focused($isPathFieldFocused)
                .onSubmit(addProject)

                if host.kind == .selfHost {
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = false
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                pathInput.selectFolder(url)
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
                } else if !normalizedPath.isEmpty, !isValidPath {
                    Text(isDirectory ? "Enter an absolute path beginning with /." :
                        "Enter a path beginning with / or ~.")
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
                    ? (isAdding ? "Adding…" : (isDirectory ? "Add Directory" : "Add Project"))
                    : (isAdding ? "Locating…" : "Use Folder")) {
                        addProject()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAdding || !isValidPath)
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
        guard isValidPath, !isAdding else { return }
        errorMessage = nil
        isAdding = true
        Task {
            let result = await (isDirectory ? (onAddDirectory ?? onAdd) : onAdd)(normalizedPath)
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

/// A picker selection is a filesystem identity, not whitespace-padded input.
struct ProjectPathInput {
    var text = ""
    private var pickedPath: String?

    mutating func selectFolder(_ url: URL) {
        text = url.path
        pickedPath = text
    }

    func submissionPath(recovering: Bool) -> String {
        if recovering || pickedPath.map({ Array($0.utf8) == Array(text.utf8) }) == true {
            return text
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation
import GhosthubTerminal
import GhosthubTransport
import GhosthubWorkspace

struct TmuxImagePasteFailure: Error, Equatable, LocalizedError, Sendable {
    let status: Int32
    let diagnostic: String

    var errorDescription: String? {
        var message = "Ghosthub could not paste the clipboard image into the remote session."
        if !diagnostic.isEmpty {
            message += " \(diagnostic)"
        }
        return message
    }
}

struct TmuxImagePaster: Sendable {
    typealias Runner = @Sendable (
        _ host: SSHHostInfo,
        _ connectionArguments: [String],
        _ remoteCommand: String,
        _ image: Data,
        _ timeout: TimeInterval
    ) async -> AccountCommandOutput

    private static let resultMarker = "GHOSTHUB_IMAGE_PASTE"
    private let runner: Runner
    private let fileNameProvider: @Sendable () -> String

    init(
        runner: @escaping Runner = Self.run,
        fileNameProvider: @escaping @Sendable () -> String = {
            "paste-\(UUID().uuidString.lowercased()).png"
        }
    ) {
        self.runner = runner
        self.fileNameProvider = fileNameProvider
    }

    func paste(
        _ image: TerminalClipboardImage,
        on host: SSHHostInfo,
        connectionArguments: [String]
    ) async -> Result<String, TmuxImagePasteFailure> {
        guard host.platform == .posix else {
            return .failure(.init(
                status: 64,
                diagnostic: "Image paste is unavailable on this host platform."
            ))
        }
        let fileName = fileNameProvider()
        let output = await runner(
            host,
            connectionArguments,
            Self.uploadCommand(fileName: fileName),
            image.pngData,
            Self.uploadTimeout(byteCount: image.pngData.count)
        )
        guard output.status == 0 else {
            return .failure(.init(
                status: output.status,
                diagnostic: Self.normalizedDiagnostic(
                    output.stderr.isEmpty ? output.stdout : output.stderr
                )
            ))
        }
        guard let path = Self.uploadedPath(
            from: output.stdout,
            fileName: fileName
        ) else {
            return .failure(.init(
                status: 65,
                diagnostic: "The remote host did not confirm the uploaded image path."
            ))
        }
        return .success(path)
    }

    static func uploadCommand(
        fileName: String,
        imageDirectory: String? = nil
    ) -> String {
        let quotedName = shellQuotedCommandArgument(fileName)
        let quotedDirectory = imageDirectory.map(shellQuotedCommandArgument)
            ?? #""$HOME/.ghosthub/paste-images""#
        return """
        umask 077
        ghosthub_image_dir=\(quotedDirectory)
        mkdir -p -- "$ghosthub_image_dir" || exit $?
        chmod 700 "$ghosthub_image_dir" || exit $?
        find "$ghosthub_image_dir" -type f -name 'paste-*.png' -mtime +7 -delete >/dev/null 2>&1 || :
        ghosthub_image_path="$ghosthub_image_dir"/\(quotedName)
        if cat > "$ghosthub_image_path"; then
          chmod 600 "$ghosthub_image_path" || exit $?
          printf '\n%s\t%s\n' \(shellQuotedCommandArgument(resultMarker)) "$ghosthub_image_path"
        else
          ghosthub_status=$?
          rm -f -- "$ghosthub_image_path"
          exit "$ghosthub_status"
        fi
        """
    }

    static func uploadedPath(
        from output: String,
        fileName: String
    ) -> String? {
        let prefix = resultMarker + "\t"
        guard let line = output.split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .last(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let path = String(line.dropFirst(prefix.count))
        guard path.first == "/",
              path.hasSuffix("/\(fileName)"),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else { return nil }
        return path
    }

    static func uploadTimeout(byteCount: Int) -> TimeInterval {
        let baseTimeout: TimeInterval = 30
        let transferAllowance = TimeInterval(max(0, byteCount)) / 65_536
        return min(600, baseTimeout + transferAllowance)
    }

    private static func normalizedDiagnostic(_ diagnostic: String) -> String {
        String(
            diagnostic
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
                .prefix(400)
        )
    }

    private static func run(
        host: SSHHostInfo,
        connectionArguments: [String],
        remoteCommand: String,
        image: Data,
        timeout: TimeInterval
    ) async -> AccountCommandOutput {
        await BlockingTask.run(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ghosthub-image-paste-\(UUID().uuidString)",
                    isDirectory: true
                )
            let localImage = directory.appendingPathComponent(
                "clipboard.png",
                isDirectory: false
            )
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                defer { try? FileManager.default.removeItem(at: directory) }
                try image.write(to: localImage, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: localImage.path
                )

                var arguments = [
                    "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                ]
                arguments += connectionArguments
                if let port = host.port {
                    arguments += ["-p", String(port)]
                }
                let destination = host.user.map { "\($0)@\(host.hostname)" }
                    ?? host.hostname
                arguments += [
                    "--",
                    destination,
                    AccountCommandRunner.remoteLoginCommand(
                        host: host,
                        command: remoteCommand
                    ),
                ]
                let invocation = (["/usr/bin/ssh"] + arguments)
                    .map(shellQuotedCommandArgument)
                    .joined(separator: " ")
                    + " < " + shellQuotedCommandArgument(localImage.path)
                return AccountCommandRunner().runLocalLoginShell(
                    command: invocation,
                    timeout: timeout
                )
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return AccountCommandOutput(
                    status: 74,
                    stdout: "",
                    stderr: error.localizedDescription
                )
            }
        }
    }
}

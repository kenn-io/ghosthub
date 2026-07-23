import CryptoKit
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let encodedSecret = String(data: input, encoding: .utf8),
      let secret = Data(base64Encoded: encodedSecret)
else {
    FileHandle.standardError.write(
        Data("Expected a base64-encoded Sparkle Ed25519 key.\n".utf8)
    )
    exit(1)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func validateLegacyKey(
    encodedSecret: String,
    publicKey: Data
) -> Bool {
    let signUpdatePath = ProcessInfo.processInfo.environment[
        "SPARKLE_SIGN_UPDATE"
    ] ?? ".build/artifacts/sparkle/Sparkle/bin/sign_update"
    let signUpdateURL = URL(
        fileURLWithPath: signUpdatePath,
        relativeTo: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ).standardizedFileURL

    guard FileManager.default.isExecutableFile(
        atPath: signUpdateURL.path
    ) else {
        fail("Sparkle sign_update is missing: \(signUpdateURL.path)")
    }

    let challenge = Data("ghosthub-sparkle-key-validation-v1".utf8)
    let challengeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    do {
        try challenge.write(to: challengeURL, options: .atomic)
    } catch {
        fail("Could not create the Sparkle key validation challenge.")
    }
    defer {
        try? FileManager.default.removeItem(at: challengeURL)
    }

    let standardInput = Pipe()
    let standardOutput = Pipe()
    let process = Process()
    process.executableURL = signUpdateURL
    process.arguments = [
        "--ed-key-file", "-",
        "-p",
        challengeURL.path,
    ]
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = Pipe()

    do {
        try process.run()
        standardInput.fileHandleForWriting.write(
            Data("\(encodedSecret)\n".utf8)
        )
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
    } catch {
        fail("Could not validate the legacy Sparkle key.")
    }

    guard process.terminationStatus == 0,
          let signatureString = String(
              data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
              encoding: .utf8
          )?.trimmingCharacters(in: .whitespacesAndNewlines),
          let signature = Data(base64Encoded: signatureString),
          signature.count == 64,
          let verifier = try? Curve25519.Signing.PublicKey(
              rawRepresentation: publicKey
          )
    else {
        return false
    }

    return verifier.isValidSignature(signature, for: challenge)
}

if secret.count == 32 {
    let privateKey = try Curve25519.Signing.PrivateKey(
        rawRepresentation: secret
    )
    print(
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    )
} else if secret.count == 96 {
    // Sparkle's legacy export is its 64-byte private representation followed
    // by the 32-byte public key. This mirrors decodePrivateAndPublicKeys in
    // Sparkle 2.9.4's common_cli/Secret.swift.
    let publicKey = Data(secret.suffix(32))
    guard validateLegacyKey(
        encodedSecret: encodedSecret,
        publicKey: publicKey
    ) else {
        fail("The legacy Sparkle private and public keys do not match.")
    }
    print(publicKey.base64EncodedString())
} else {
    fail("Expected a decoded Sparkle key of 32 or 96 bytes.")
}

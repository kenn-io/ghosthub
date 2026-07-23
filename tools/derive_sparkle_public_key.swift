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
    print(secret.suffix(32).base64EncodedString())
} else {
    FileHandle.standardError.write(
        Data("Expected a decoded Sparkle key of 32 or 96 bytes.\n".utf8)
    )
    exit(1)
}

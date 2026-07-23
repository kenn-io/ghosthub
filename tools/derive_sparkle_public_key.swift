import CryptoKit
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let encodedSeed = String(data: input, encoding: .utf8),
      let seed = Data(base64Encoded: encodedSeed),
      seed.count == 32
else {
    FileHandle.standardError.write(
        Data("Expected a base64-encoded 32-byte Ed25519 seed.\n".utf8)
    )
    exit(1)
}

do {
    let privateKey = try Curve25519.Signing.PrivateKey(
        rawRepresentation: seed
    )
    print(
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    )
} catch {
    FileHandle.standardError.write(
        Data("Could not derive the Ed25519 public key.\n".utf8)
    )
    exit(1)
}

#if canImport(AppKit)
import CryptoKit
import Darwin
import Foundation
import Sparkle

/// Probes Ghosthub's single-release feed without disturbing Sparkle's queued installer.
struct UpdateFeed {
    private let configuration: UpdateConfiguration

    init(configuration: UpdateConfiguration) {
        self.configuration = configuration
    }

    func latestVersion() async throws -> String? {
        guard configuration.isReady,
              let feedURL = configuration.feedURL,
              let publicKey = configuration.publicKey,
              let installedVersion = Bundle.main
              .object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else {
            throw FeedError.invalidConfiguration
        }

        let request = URLRequest(
            url: feedURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode)
        else {
            throw FeedError.invalidResponse
        }

        let system = ProcessInfo.processInfo.operatingSystemVersion
        var arm64: Int32 = 0
        var size = MemoryLayout.size(ofValue: arm64)
        let isAppleSilicon = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0
            && arm64 == 1
        return try Self.latestVersion(
            in: data,
            publicKey: publicKey,
            installedVersion: installedVersion,
            systemVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            isAppleSilicon: isAppleSilicon
        )
    }

    static func latestVersion(
        in data: Data,
        publicKey: Data,
        installedVersion: String,
        systemVersion: String,
        isAppleSilicon: Bool
    ) throws -> String? {
        // Sparkle signs exactly the bytes preceding this trailing comment.
        let marker = Data("<!-- sparkle-signatures:\n".utf8)
        guard let markerRange = data.range(of: marker, options: .backwards),
              let trailer = String(data: data[markerRange.upperBound...], encoding: .utf8)
        else {
            throw FeedError.invalidSignature
        }
        let lines = trailer.split(whereSeparator: \.isNewline)
        let content = data[..<markerRange.lowerBound]
        guard lines.count == 3,
              lines[0].hasPrefix("edSignature: "),
              lines[1].hasPrefix("length: "),
              lines[2] == "-->",
              let signature =
              Data(base64Encoded: String(lines[0].dropFirst("edSignature: ".count))),
              Int(lines[1].dropFirst("length: ".count)) == content.count,
              try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
              .isValidSignature(signature, for: content)
        else {
            throw FeedError.invalidSignature
        }

        // Our release tooling publishes one full enclosure and an item-level build version.
        // Leave Sparkle's existing queue alone if that feed contract changes.
        let document = try XMLDocument(data: content, options: .nodeLoadExternalEntitiesNever)
        let enclosures = try document.nodes(forXPath: "/rss/channel/item/enclosure")
        let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        guard enclosures.count == 1,
              let enclosure = enclosures[0] as? XMLElement,
              let item = enclosure.parent as? XMLElement,
              let rawURL = enclosure.attribute(forName: "url")?.stringValue,
              let archiveURL = URL(string: rawURL),
              archiveURL.scheme == "https", archiveURL.host != nil,
              let rawSignature = enclosure.attribute(forLocalName: "edSignature", uri: namespace)?
              .stringValue,
              let archiveSignature = Data(base64Encoded: rawSignature),
              archiveSignature.count == 64
        else {
            throw FeedError.unsupportedFeed
        }
        func value(_ name: String) -> String? {
            guard let raw = item.elements(forLocalName: name, uri: namespace).first?.stringValue
            else {
                return nil
            }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard let version = value("version") else {
            throw FeedError.unsupportedFeed
        }

        let comparator = SUStandardVersionComparator.default
        if let minimum = value("minimumSystemVersion"),
           comparator.compareVersion(systemVersion, toVersion: minimum) == .orderedAscending {
            return nil
        }
        if let maximum = value("maximumSystemVersion"),
           comparator.compareVersion(systemVersion, toVersion: maximum) == .orderedDescending {
            return nil
        }
        if let minimum = value("minimumUpdateVersion"),
           comparator.compareVersion(installedVersion, toVersion: minimum) == .orderedAscending {
            return nil
        }
        let hardware = value("hardwareRequirements")?.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ",")))
        if hardware?.contains("arm64") == true, !isAppleSilicon {
            return nil
        }
        return version
    }

    private enum FeedError: LocalizedError {
        case invalidConfiguration
        case invalidResponse
        case invalidSignature
        case unsupportedFeed

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                "The update feed isn’t configured."
            case .invalidResponse:
                "The update server didn’t return a release feed."
            case .invalidSignature:
                "The update feed could not be verified."
            case .unsupportedFeed:
                "The update feed doesn’t describe a usable release."
            }
        }
    }
}
#endif

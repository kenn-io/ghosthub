#if canImport(AppKit)
import Foundation
import Sparkle

final class NightlyUpdateVersionDisplay: NSObject, SUVersionDisplay, SPUStandardUserDriverDelegate {
    private let installedDate: String?

    init(infoDictionary: [String: Any]) {
        let developmentVersion = infoDictionary["GhosthubDevelopmentVersion"] as? String
        installedDate = developmentVersion?.components(separatedBy: " · ").dropFirst().first
        super.init()
    }

    func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        self
    }

    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem,
        andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<
            NSString
        >,
        withBundleVersion bundleVersion: String
    ) -> String {
        inOutBundleDisplayVersion.pointee = installedVersion(build: bundleVersion) as NSString
        return updateVersion(date: update.date, build: update.versionString)
    }

    func formatBundleDisplayVersion(
        _ bundleDisplayVersion: String,
        withBundleVersion bundleVersion: String,
        matchingUpdate: SUAppcastItem?
    ) -> String {
        installedVersion(build: bundleVersion)
    }

    func installedVersion(build: String) -> String {
        Self.label(date: installedDate, build: build)
    }

    func updateVersion(date: Date?, build: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return Self.label(date: date.map(formatter.string(from:)), build: build)
    }

    private static func label(date: String?, build: String) -> String {
        if let date {
            return "Nightly · \(date) · build \(build)"
        }
        return "Nightly · build \(build)"
    }
}
#endif

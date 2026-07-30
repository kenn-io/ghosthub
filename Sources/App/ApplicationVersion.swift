import Foundation

enum ApplicationVersion {
    private static let developmentVersionKey =
        "GhosthubDevelopmentVersion"

    static func aboutPanelVersion(
        infoDictionary: [String: Any] =
            Bundle.main.infoDictionary ?? [:]
    ) -> String? {
        let development = infoDictionary[developmentVersionKey] as? String
        if let development = development?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !development.isEmpty {
            return development
        }
        let release =
            infoDictionary["CFBundleShortVersionString"] as? String
        return release?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
